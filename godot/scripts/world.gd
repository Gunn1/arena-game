## The tile map: random fair generation, mining, and the zone that crumbles it from the edges in.
class_name World
extends RefCounted

# New types go at the end so the numbers (sent online, used by Cfg.MINE_TIME) never change.
enum { EMPTY, DIRT, STONE, PLACED, COPPER, CRYSTAL, SAND, ICE, SLIME, LAVA, TNT, STEEL, FAN_L, FAN_R, MAGNET, TURRET, BOUNCE }
# Special blocks players craft and place, with an effect around them. Kept in `devices`.
const DEVICES := [FAN_L, FAN_R, MAGNET, TURRET, BOUNCE]
const DROPS := {DIRT: "dirt", PLACED: "dirt", STONE: "stone", COPPER: "copper", CRYSTAL: "crystal",
	SAND: "dirt", ICE: "stone", SLIME: "dirt"}
const ORE_TILES := {"copper": COPPER, "crystal": CRYSTAL}
const COLS := Cfg.COLS
const ROWS := Cfg.ROWS

var grid := PackedByteArray()
var spawns: Array = []            # Vector2i(col, ground_row) per player, left to right
var spread := 0.0                 # how uneven the spawns are (0 = identical ground nearby)
var warnings := {}                # Vector2i -> seconds until it breaks
var elapsed := 0.0
var arena_left := 0               # the arena is the columns [arena_left, arena_right)
var arena_right := COLS
var zone_left := 0.0              # the zone's edges; everything outside crumbles
var zone_right := float(COLS)
var next_left := 0                # next column the left edge will crumble
var next_right := COLS - 1        # next column the right edge will crumble
var rng := RandomNumberGenerator.new()
var broken: Array = []            # [x, y, tile, cause] since the game last drained it (for debris)
var dirty: Array = []             # Vector2i tiles to redraw
var record := false               # host: log changes to send to clients
var changes: Array = []           # ["t", x, y, tile, cause] / ["w", x, y] warning
var version := 0                  # bumps every new map
var biome := "meadow"             # one of Cfg.BIOMES: colours and special blocks
var shape := "islands"            # one of Cfg.SHAPES: how the terrain is laid out
var actor := -1                   # player index breaking tiles right now (GameSim sets it), for TNT credit
var lit: Array = []               # [x, y, actor, cause] TNT set off since GameSim last drained it
var occupied := Callable()        # (x, y) -> bool: a player is in that tile (sand won't fall into it)
var sand_t := 0.0
var devices := {}                 # Vector2i -> tile, for every fan, magnet, turret and bounce pad
var owners := {}                  # host: Vector2i -> player index that placed a special block there
var _players := 2                 # while generating


func _init() -> void:
	grid.resize(COLS * ROWS)


func in_bounds(x: int, y: int) -> bool:
	return x >= 0 and x < COLS and y >= 0 and y < ROWS


func get_tile(x: int, y: int) -> int:
	return grid[y * COLS + x] if in_bounds(x, y) else EMPTY


## Lava is in the grid but isn't solid: you fall into it (and get thrown out).
func solid(x: int, y: int) -> bool:
	var t := get_tile(x, y)
	return t != EMPTY and t != LAVA


func set_tile(x: int, y: int, tile: int, cause := "mine") -> void:
	if not in_bounds(x, y):
		return
	var old := grid[y * COLS + x]
	if old == tile:
		return
	if old == LAVA and tile == EMPTY and cause in ["mine", "bomb"]:
		return                                       # lava can't be dug or blasted away (the zone still takes it)
	if old == STEEL and cause == "bomb":
		return                                       # steel is bombproof
	grid[y * COLS + x] = tile
	var pos := Vector2i(x, y)
	owners.erase(pos)
	if tile in DEVICES:
		devices[pos] = tile
	else:
		devices.erase(pos)
	if record:
		changes.append(["t", x, y, tile, cause])
	if tile != EMPTY and zone_started() and (x < next_left or x > next_right):
		warn(x, y)                                   # built outside the zone: it crumbles too
	if tile == EMPTY:
		if cause != "sand":                          # falling sand just moves: no debris
			broken.append([x, y, old, cause])
		warnings.erase(pos)
		if old == TNT:
			lit.append([x, y, actor, cause])
	dirty.append(pos)


## Mine a block out. Returns the tile that was there, or -1 if it was already empty.
func break_tile(x: int, y: int) -> int:
	var tile := get_tile(x, y)
	if tile == EMPTY:
		return -1
	set_tile(x, y, EMPTY, "mine")
	return tile


## After the whole grid is replaced: find every device again.
func rebuild_devices() -> void:
	devices.clear()
	owners.clear()
	for i in grid.size():
		if grid[i] in DEVICES:
			devices[Vector2i(i % COLS, i / COLS)] = grid[i]


func warn(x: int, y: int) -> void:
	warnings[Vector2i(x, y)] = Cfg.CRUMBLE_WARN
	dirty.append(Vector2i(x, y))
	if record:
		changes.append(["w", x, y])


func block_count() -> int:
	var n := 0
	for t in grid:
		if t != EMPTY:
			n += 1
	return n


# --- the zone -----------------------------------------------------------------------------

func zone_started() -> bool:
	return elapsed >= Cfg.ZONE_GRACE


## How far each edge has moved in, in columns. Starts slow, ends 3x faster, meets in the
## middle after ZONE_CLOSE_TIME seconds.
func zone_progress() -> float:
	var t := maxf(0.0, elapsed - Cfg.ZONE_GRACE)
	var half := (arena_right - arena_left) / 2.0
	var v0 := half / (2.0 * Cfg.ZONE_CLOSE_TIME)
	var accel := 2.0 * v0 / Cfg.ZONE_CLOSE_TIME
	return minf(half, v0 * t + 0.5 * accel * t * t)


func update(dt: float) -> void:
	actor = -1                                       # the zone and sand belong to nobody
	elapsed += dt
	for pos in warnings.keys():
		warnings[pos] -= dt
		if warnings[pos] <= 0.0:
			set_tile(pos.x, pos.y, EMPTY, "crumble")
	var s := zone_progress()
	zone_left = arena_left + s
	zone_right = arena_right - s
	# Each column the edge passes starts to crumble (with the usual shake warning first).
	while next_left < floori(zone_left) and next_left <= next_right:
		_warn_column(next_left)
		next_left += 1
	while next_right >= ceili(zone_right) and next_right >= next_left:
		_warn_column(next_right)
		next_right -= 1
	_update_sand(dt)


## Host: every SAND_FALL seconds, sand with air below drops one tile (whole columns together,
## since the scan goes bottom-up). Crumbling sand stays put; so does sand above a player.
func _update_sand(dt: float) -> void:
	sand_t += dt
	if sand_t < Cfg.SAND_FALL:
		return
	sand_t -= Cfg.SAND_FALL
	for y in range(ROWS - 2, -1, -1):
		for x in COLS:
			if grid[y * COLS + x] != SAND or grid[(y + 1) * COLS + x] != EMPTY or warnings.has(Vector2i(x, y)):
				continue
			if occupied.is_valid() and occupied.call(x, y + 1):
				continue
			set_tile(x, y, EMPTY, "sand")
			set_tile(x, y + 1, SAND, "sand")


func _warn_column(x: int) -> void:
	for y in ROWS:
		if grid[y * COLS + x] != EMPTY and not warnings.has(Vector2i(x, y)):
			warn(x, y)


# --- generation --------------------------------------------------------------------------

## force_biome / force_shape (tests) skip the random pick.
func generate(seed_value: int, players: int, force_biome := "", force_shape := "") -> void:
	rng.seed = seed_value
	biome = Cfg.BIOMES[rng.randi_range(0, Cfg.BIOMES.size() - 1)]
	shape = Cfg.SHAPES[rng.randi_range(0, Cfg.SHAPES.size() - 1)]
	if force_biome != "":
		biome = force_biome
	if force_shape != "":
		shape = force_shape
	_players = players
	var width := mini(COLS, Cfg.ARENA_BASE + Cfg.ARENA_PER_PLAYER * players)
	arena_left = (COLS - width) / 2
	arena_right = arena_left + width
	var best := []
	for attempt in 40:
		var g := _terrain()
		if _fill_ratio(g) < Cfg.MIN_FILL:
			continue
		var picked := _pick_spawns(g, players)
		if picked.is_empty():
			continue
		if best.is_empty() or picked[1] < best[2]:
			best = [g, picked[0], picked[1]]
		if best[2] <= Cfg.FAIR_SPREAD:
			break
	assert(not best.is_empty(), "could not generate a map")
	grid = best[0]
	spawns = best[1]
	spread = best[2]
	_assign_types(grid)
	_add_ores(grid)
	_even_out_ores(grid, spawns)
	_dress(grid)
	warnings.clear()
	lit.clear()
	rebuild_devices()
	sand_t = 0.0
	actor = -1
	broken.clear()
	changes.clear()
	dirty.clear()
	elapsed = 0.0
	zone_left = arena_left
	zone_right = arena_right
	next_left = 0                                    # columns outside the arena go as soon as the zone starts,
	next_right = COLS - 1                            # so blocks built out there don't survive
	version += 1


## Smooth random field: random values on a coarse grid, blended in between.
func _noise_field(cell: int) -> PackedFloat32Array:
	var gw := COLS / cell + 3
	var gh := ROWS / cell + 3
	var g := PackedFloat32Array()
	g.resize(gw * gh)
	for i in gw * gh:
		g[i] = rng.randf()
	var out := PackedFloat32Array()
	out.resize(COLS * ROWS)
	for y in ROWS:
		for x in COLS:
			var fx := float(x) / cell
			var fy := float(y) / cell
			var x0 := int(fx)
			var y0 := int(fy)
			var tx := smoothstep(0.0, 1.0, fx - x0)
			var ty := smoothstep(0.0, 1.0, fy - y0)
			var top := lerpf(g[y0 * gw + x0], g[y0 * gw + x0 + 1], tx)
			var bot := lerpf(g[(y0 + 1) * gw + x0], g[(y0 + 1) * gw + x0 + 1], tx)
			out[y * COLS + x] = lerpf(top, bot, ty)
	return out


func _terrain() -> PackedByteArray:
	match shape:
		"mountain":
			return _mountain()
		"towers":
			return _towers()
		"caves":
			return _caves()
	return _islands()


func _blank() -> PackedByteArray:
	var g := PackedByteArray()
	g.resize(COLS * ROWS)
	return g


## Column x seen in a mirror at the arena's centre (so a shape can be left/right symmetric).
func _mirror(x: int) -> int:
	return arena_left + arena_right - 1 - x


## The column player i spawns near (same formula as _pick_spawns).
func _slot(i: int) -> int:
	return arena_left + roundi((arena_right - arena_left) * (i + 1.0) / (_players + 1.0))


func _near_slot(x: int, r: int) -> bool:
	for i in _players:
		if absi(x - _slot(i)) <= r:
			return true
	return false


## Islands: floating blobs from two layers of noise.
func _islands() -> PackedByteArray:
	var big := _noise_field(7)
	var small := _noise_field(3)
	var g := PackedByteArray()
	g.resize(COLS * ROWS)
	for y in range(Cfg.TOP_ROW, ROWS - 2):
		for x in range(arena_left + 1, arena_right - 1):
			var depth := float(y - Cfg.TOP_ROW) / (ROWS - Cfg.TOP_ROW)
			if big[y * COLS + x] * 0.7 + small[y * COLS + x] * 0.3 + depth * 0.1 > 0.55:
				g[y * COLS + x] = DIRT
	g = _smooth(g)
	_remove_specks(g, 6)
	return g


## Mountain: one big symmetric mass, high in the middle, with a few tunnels wormed through it.
func _mountain() -> PackedByteArray:
	var g := _blank()
	var bumps := _noise_field(3)
	var cx := (arena_left + arena_right) / 2.0
	var half := (arena_right - arena_left) / 2.0 - 1.0
	var peak := rng.randf_range(11.0, 14.0)
	var foot := rng.randf_range(20.0, 23.0)
	var base := ROWS - 3.0 - rng.randf_range(0.0, 2.0)
	for x in range(arena_left + 1, arena_right - 1):
		var u := absf(x + 0.5 - cx) / half
		var nx := mini(x, _mirror(x))
		var top := lerpf(peak, foot, u * u) + (bumps[12 * COLS + nx] - 0.5) * 4.0
		var bottom := base - 6.0 * u * u + (bumps[28 * COLS + nx] - 0.5) * 3.0
		for y in range(maxi(Cfg.TOP_ROW, roundi(top)), mini(ROWS - 2, roundi(bottom) + 1)):
			g[y * COLS + x] = DIRT
	g = _smooth(g)
	# Each column's first and last solid row: tunnels keep 2 tiles of rock above and below them.
	var tops := PackedInt32Array()
	var bottoms := PackedInt32Array()
	tops.resize(COLS)
	bottoms.resize(COLS)
	for x in COLS:
		tops[x] = ROWS
		bottoms[x] = -1
		for y in ROWS:
			if g[y * COLS + x] != EMPTY:
				tops[x] = mini(tops[x], y)
				bottoms[x] = y
	for i in rng.randi_range(2, 4):
		var sx := rng.randf_range(cx - half * 0.7, cx + half * 0.7)
		var surf := tops[floori(sx)]
		_worm(g, sx, rng.randf_range(surf + 3.0, surf + 8.0), rng.randi_range(10, 20), tops, bottoms)
	_remove_specks(g, 6)
	return g


## Carve a mostly sideways tunnel, 3 tiles tall, by wandering from (x, y), leaving a 2-tile
## skin under tops and over bottoms (per column) so the mass isn't cut in two.
func _worm(g: PackedByteArray, x: float, y: float, length: int, tops: PackedInt32Array, bottoms: PackedInt32Array) -> void:
	var heading := 0.0 if rng.randf() < 0.5 else PI
	var a := heading
	for i in length:
		for dy in range(-1, 2):
			for dx in 2:
				var tx := floori(x) + dx
				var ty := floori(y) + dy
				if tx > arena_left and tx < arena_right - 1 and ty >= tops[tx] + 2 and ty <= bottoms[tx] - 2:
					g[ty * COLS + tx] = EMPTY
		a = heading + clampf(a - heading + rng.randf_range(-0.35, 0.35), -0.6, 0.6)
		x += cos(a)
		y += sin(a) * 0.7


## Towers: a pillar under every spawn slot (plus, for 2 players, sometimes a middle spire or two
## short outer pillars), joined by 1-tile bridges.
func _towers() -> PackedByteArray:
	var g := _blank()
	var width := rng.randi_range(7 if _players == 2 else 6, 8)
	var pillars: Array[Vector3i] = []                # left column, right column, top row
	for i in _players:
		var l := _slot(i) - width / 2
		pillars.append(Vector3i(l, l + width - 1, rng.randi_range(13, 18)))
	if _players == 2:
		var r := rng.randf()
		if r < 0.33:
			var mid := (arena_left + arena_right) / 2
			pillars.append(Vector3i(mid - 1, mid + 1, rng.randi_range(18, 22)))
		elif r < 0.66:
			var top := rng.randi_range(18, 23)
			pillars.append(Vector3i(arena_left + 2, arena_left + 5, top))
			pillars.append(Vector3i(_mirror(arena_left + 5), _mirror(arena_left + 2), top))
	pillars.sort_custom(func(a: Vector3i, b: Vector3i) -> bool: return a.x < b.x)
	for p: Vector3i in pillars:
		var jl := 0
		var jr := 0
		for y in range(p.z, ROWS - 2):
			if (y - p.z) % 3 == 0:
				jl = rng.randi_range(-1, 1) if y > p.z else 0
				jr = rng.randi_range(-1, 1) if y > p.z else 0
			var flare := 1 if y >= ROWS - 5 else 0
			for x in range(p.x + jl - flare, p.y + jr + flare + 1):
				if x > arena_left and x < arena_right - 1:
					g[y * COLS + x] = DIRT
	for k in pillars.size() - 1:
		var a: Vector3i = pillars[k]
		var b: Vector3i = pillars[k + 1]
		var row := maxi(a.z, b.z) + rng.randi_range(1, 4)
		var rows: Array[int] = [row]
		if rng.randf() < 0.5:
			rows.append(mini(ROWS - 6, row + rng.randi_range(4, 7)))
		for y: int in rows:
			for x in range(maxi(a.y - 1, arena_left + 1), mini(b.x + 2, arena_right - 1)):
				g[y * COLS + x] = DIRT                   # overlaps the pillars a bit: their edges are jagged
	_remove_specks(g, 6)
	return g


## Caves: a thick, mostly solid band with caves carved through it, and ceiling slabs hanging
## between the spawn slots (spawns always have open sky).
func _caves() -> PackedByteArray:
	var g := _blank()
	var bumps := _noise_field(3)
	var holes := _noise_field(4)
	var fine := _noise_field(2)
	var top0 := rng.randf_range(15.0, 18.0)
	var tops := PackedInt32Array()
	tops.resize(COLS)
	tops.fill(ROWS)
	for x in range(arena_left + 1, arena_right - 1):
		var top := roundi(top0 + (bumps[14 * COLS + mini(x, _mirror(x))] - 0.5) * 5.0)
		tops[x] = top
		for y in range(top, ROWS - 2):
			var i := y * COLS + x
			if y <= top + 1 or holes[i] * 0.75 + fine[i] * 0.25 < 0.58:
				g[i] = DIRT
	g = _smooth(g)
	var row := rng.randi_range(Cfg.TOP_ROW + 1, Cfg.TOP_ROW + 3)
	var x := arena_left + 2
	while x < arena_right - 2:
		if _near_slot(x, 3) or rng.randf() < 0.45:
			x += rng.randi_range(1, 2)
			continue
		var length := rng.randi_range(3, 7)
		for k in length:
			var cx := x + k
			if cx >= arena_right - 2 or _near_slot(cx, 3) or row + 6 > tops[cx]:
				break
			g[row * COLS + cx] = DIRT
			g[(row + 1) * COLS + cx] = DIRT
			if rng.randf() < 0.25:
				g[(row + 2) * COLS + cx] = DIRT          # a little stalactite
		x += length + rng.randi_range(2, 4)
	_remove_specks(g, 6)
	return g


func _neighbours(g: PackedByteArray, x: int, y: int) -> int:
	var n := 0
	for dy in [-1, 0, 1]:
		for dx in [-1, 0, 1]:
			if (dx or dy) and in_bounds(x + dx, y + dy) and g[(y + dy) * COLS + x + dx] != EMPTY:
				n += 1
	return n


## Fill tiles surrounded by blocks, clear tiles that are mostly alone.
func _smooth(g: PackedByteArray) -> PackedByteArray:
	var out := g.duplicate()
	for y in ROWS:
		for x in COLS:
			var n := _neighbours(g, x, y)
			if n >= 5:
				out[y * COLS + x] = DIRT
			elif n <= 2:
				out[y * COLS + x] = EMPTY
	return out


## Delete floating clumps smaller than min_size tiles.
func _remove_specks(g: PackedByteArray, min_size: int) -> void:
	var seen := PackedByteArray()
	seen.resize(COLS * ROWS)
	for start in COLS * ROWS:
		if g[start] == EMPTY or seen[start]:
			continue
		var stack := [start]
		var part := []
		seen[start] = 1
		while stack:
			var i: int = stack.pop_back()
			part.append(i)
			var x := i % COLS
			var y := i / COLS
			for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var nx: int = x + d.x
				var ny: int = y + d.y
				if in_bounds(nx, ny) and g[ny * COLS + nx] != EMPTY and not seen[ny * COLS + nx]:
					seen[ny * COLS + nx] = 1
					stack.append(ny * COLS + nx)
		if part.size() < min_size:
			for i in part:
				g[i] = EMPTY


func _fill_ratio(g: PackedByteArray) -> float:
	var n := 0
	for t in g:
		if t != EMPTY:
			n += 1
	return float(n) / ((arena_right - arena_left) * (ROWS - Cfg.TOP_ROW))


## Top 3 tiles of each column are dirt, deeper is stone.
func _assign_types(g: PackedByteArray) -> void:
	for x in COLS:
		var depth := 0
		for y in ROWS:
			if g[y * COLS + x] != EMPTY:
				g[y * COLS + x] = DIRT if depth < 3 else STONE
				depth += 1
			else:
				depth = 0


func _blocks_near(g: PackedByteArray, col: int, row: int) -> int:
	var n := 0
	for y in range(maxi(0, row - Cfg.FAIR_RADIUS), mini(ROWS, row + Cfg.FAIR_RADIUS + 1)):
		for x in range(maxi(0, col - Cfg.FAIR_RADIUS), mini(COLS, col + Cfg.FAIR_RADIUS + 1)):
			if g[y * COLS + x] != EMPTY:
				n += 1
	return n


func _shuffle(a: Array) -> void:
	for i in range(a.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var t = a[i]
		a[i] = a[j]
		a[j] = t


## One spawn near each evenly spaced slot across the arena (so the closing edges treat
## mirrored players the same), choosing the combination with the most even ground nearby.
## Returns [spawns, spread] or [] if impossible.
func _pick_spawns(g: PackedByteArray, players: int) -> Array:
	var width := arena_right - arena_left
	var candidates := []                             # per slot: spots within 2 columns of it
	for i in players:
		var slot := arena_left + roundi(width * (i + 1.0) / (players + 1.0))
		var spots := []
		for x in range(slot - 2, slot + 3):
			for y in ROWS:
				if g[y * COLS + x] != EMPTY:
					if y >= 2 and _blocks_near(g, x, y) >= Cfg.MIN_NEAR:
						spots.append(Vector2i(x, y))   # top block of the column, open sky above
					break
		if spots.is_empty():
			return []
		candidates.append(spots)
	var best := []
	var best_spread := 2.0
	for attempt in 200:
		var pick := []
		var lo := 1 << 30
		var hi := 0
		for spots in candidates:
			var s: Vector2i = spots[rng.randi_range(0, spots.size() - 1)]
			pick.append(s)
			var n := _blocks_near(g, s.x, s.y)
			lo = mini(lo, n)
			hi = maxi(hi, n)
		var spread_now := float(hi - lo) / hi
		if spread_now < best_spread:
			best = pick
			best_spread = spread_now
		if spread_now <= Cfg.FAIR_SPREAD / 3.0:
			break
	return [best, best_spread]


## Copper through the stone and buried dirt, crystal in the deeper stone.
func _add_ores(g: PackedByteArray) -> void:
	for y in ROWS:
		for x in COLS:
			var tile := g[y * COLS + x]
			var r := rng.randf()
			if tile == STONE:
				if r < 0.05:
					g[y * COLS + x] = COPPER
				elif r < 0.075 and y > ROWS * 0.55:
					g[y * COLS + x] = CRYSTAL
			elif tile == DIRT and _buried(g, x, y) and r < 0.02:
				g[y * COLS + x] = COPPER


## True if the tile has a solid tile directly above it (so it isn't the top of its column).
func _buried(g: PackedByteArray, x: int, y: int) -> bool:
	return y > 0 and g[(y - 1) * COLS + x] != EMPTY


## Give every spawn the same amount of each ore within that ore's radius (and at least its
## minimum) by turning stone or buried dirt into ore. Stops when nothing more can change.
func _even_out_ores(g: PackedByteArray, spots: Array) -> void:
	for ore_name: String in ORE_TILES:
		var tile: int = ORE_TILES[ore_name]
		var near: Dictionary = Cfg.ORE_NEAR[ore_name]
		var radius: int = near["radius"]
		var least: int = near["min"]
		var changed := true
		while changed:
			changed = false
			# Overlapping areas can push a neighbour past the target, so re-measure each pass.
			var target := least
			for s: Vector2i in spots:
				target = maxi(target, _count_near(g, s, radius, tile))
			for s: Vector2i in spots:
				var need := target - _count_near(g, s, radius, tile)
				if need <= 0:
					continue
				var free := _convertible_near(g, s, radius)
				_shuffle(free)
				for k in mini(need, free.size()):
					var i: int = free[k]
					g[i] = tile
					changed = true


func _count_near(g: PackedByteArray, s: Vector2i, radius: int, tile: int) -> int:
	var n := 0
	for i: int in _area(s, radius):
		if g[i] == tile:
			n += 1
	return n


## Tiles near a spawn that may become ore: stone, or dirt under another block. Never the
## tile the spawn stands on.
func _convertible_near(g: PackedByteArray, s: Vector2i, radius: int) -> Array:
	var out := []
	for i: int in _area(s, radius):
		var x := i % COLS
		var y := i / COLS
		if x == s.x and y == s.y:
			continue
		if g[i] == STONE or (g[i] == DIRT and _buried(g, x, y)):
			out.append(i)
	return out


func _area(s: Vector2i, radius: int) -> Array:
	var out := []
	for y in range(maxi(0, s.y - radius), mini(ROWS, s.y + radius + 1)):
		for x in range(maxi(0, s.x - radius), mini(COLS, s.x + radius + 1)):
			out.append(y * COLS + x)
	return out


# --- biome dressing (after ores, so ore counts and spawn ground stay fair) -------------

func _dress(g: PackedByteArray) -> void:
	match biome:
		"desert":
			_add_sand(g)
		"tundra":
			_add_ice(g)
		"mushroom":
			_add_slime(g)
		"volcano":
			_add_lava(g)
	_add_tnt(g)


func _open_above(g: PackedByteArray, x: int, y: int) -> bool:
	return y == 0 or g[(y - 1) * COLS + x] == EMPTY


## The top 2 dirt tiles of each surface become sand; sand that would fall at once stays packed (dirt).
func _add_sand(g: PackedByteArray) -> void:
	for i in COLS * ROWS:
		var y := i / COLS
		if g[i] == DIRT and (_open_above(g, i % COLS, y) or _open_above(g, i % COLS, y - 1)):
			g[i] = SAND
	for i in COLS * ROWS:
		if g[i] == SAND and (i / COLS == ROWS - 1 or g[i + COLS] == EMPTY):
			g[i] = DIRT


## Sheets of ice over patches of the surface.
func _add_ice(g: PackedByteArray) -> void:
	var patches := _noise_field(5)
	for i in COLS * ROWS:
		if g[i] == DIRT and _open_above(g, i % COLS, i / COLS) and patches[i] > 0.42:
			g[i] = ICE


## Surface tiles that may turn into something special: dirt or stone with air above, inside the
## arena, more than `safe` tiles (a square) from every spawn and never in a spawn's column.
func _surface_spots(g: PackedByteArray, safe: int) -> Array:
	var out := []
	for y in range(1, ROWS):
		for x in range(arena_left + 1, arena_right - 1):
			var t := g[y * COLS + x]
			if (t == DIRT or t == STONE) and _open_above(g, x, y) and _far_from_spawns(x, y, safe):
				out.append(Vector2i(x, y))
	return out


func _far_from_spawns(x: int, y: int, safe: int) -> bool:
	for s: Vector2i in spawns:
		if x == s.x or maxi(absi(x - s.x), absi(y - s.y)) <= safe:
			return false
	return true


## Bouncy pads, 1-3 tiles wide, on the surface (not right at a spawn).
func _add_slime(g: PackedByteArray) -> void:
	var spots := _surface_spots(g, 1)
	_shuffle(spots)
	var pads := rng.randi_range(5, 9)
	for s: Vector2i in spots:
		if pads == 0:
			break
		if g[s.y * COLS + s.x] != DIRT:
			continue
		pads -= 1
		var wide := rng.randi_range(1, 3)
		for k in wide:
			var x := s.x + k
			if g[s.y * COLS + x] == DIRT and _open_above(g, x, s.y) and _far_from_spawns(x, s.y, 1):
				g[s.y * COLS + x] = SLIME


## Lava pools sunk into the surface, never near a spawn or under one.
func _add_lava(g: PackedByteArray) -> void:
	var spots := _surface_spots(g, Cfg.LAVA_SAFE)
	_shuffle(spots)
	var ok := {}
	for s: Vector2i in spots:
		ok[s] = true
	var pools := rng.randi_range(3, 6)
	for s: Vector2i in spots:
		if pools == 0:
			break
		if g[s.y * COLS + s.x] == LAVA:
			continue
		pools -= 1
		g[s.y * COLS + s.x] = LAVA
		for dir: int in [-1, 1]:
			for k in range(1, rng.randi_range(1, 3) + 1):
				var p := Vector2i(s.x + dir * k, s.y)
				if not ok.has(p):
					break
				g[p.y * COLS + p.x] = LAVA


## A few TNT blocks hidden in the terrain, away from the spawns.
func _add_tnt(g: PackedByteArray) -> void:
	var spots := []
	for y in ROWS:
		for x in range(arena_left + 1, arena_right - 1):
			var t := g[y * COLS + x]
			if (t == DIRT or t == STONE) and _far_from_spawns(x, y, Cfg.TNT_SAFE):
				spots.append(y * COLS + x)
	_shuffle(spots)
	for k in mini(rng.randi_range(1, 3), spots.size()):
		var i: int = spots[k]
		g[i] = TNT

## The tile map: random fair generation, mining, and the zone that crumbles it from the edges in.
class_name World
extends RefCounted

enum { EMPTY, DIRT, STONE, PLACED, COPPER, CRYSTAL }
const HARD := [STONE, COPPER, CRYSTAL]          # take two hits to mine
const DROPS := {DIRT: "dirt", PLACED: "dirt", STONE: "stone", COPPER: "copper", CRYSTAL: "crystal"}
const ORE_TILES := {"copper": COPPER, "crystal": CRYSTAL}
const COLS := Cfg.COLS
const ROWS := Cfg.ROWS

var grid := PackedByteArray()
var spawns: Array = []            # Vector2i(col, ground_row) per player, left to right
var spread := 0.0                 # how uneven the spawns are (0 = identical ground nearby)
var cracked := {}                 # Vector2i -> true
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
var changes: Array = []           # ["t", x, y, tile, cause] / ["c", x, y] crack / ["w", x, y] warning
var version := 0                  # bumps every new map


func _init() -> void:
	grid.resize(COLS * ROWS)


func in_bounds(x: int, y: int) -> bool:
	return x >= 0 and x < COLS and y >= 0 and y < ROWS


func get_tile(x: int, y: int) -> int:
	return grid[y * COLS + x] if in_bounds(x, y) else EMPTY


func solid(x: int, y: int) -> bool:
	return get_tile(x, y) != EMPTY


func set_tile(x: int, y: int, tile: int, cause := "mine") -> void:
	if not in_bounds(x, y):
		return
	var old := grid[y * COLS + x]
	grid[y * COLS + x] = tile
	if old == tile:
		return
	var pos := Vector2i(x, y)
	if record:
		changes.append(["t", x, y, tile, cause])
	if tile != EMPTY and zone_started() and (x < next_left or x > next_right):
		warn(x, y)                                   # built outside the zone: it crumbles too
	if tile == EMPTY:
		broken.append([x, y, old, cause])
		cracked.erase(pos)
		warnings.erase(pos)
	dirty.append(pos)


## Mine a block. Returns the tile type if it broke, or -1 (nothing there, or a hard block just cracked).
func hit(x: int, y: int) -> int:
	var tile := get_tile(x, y)
	if tile == EMPTY:
		return -1
	var pos := Vector2i(x, y)
	if tile in HARD and not cracked.has(pos):
		crack(x, y)
		return -1
	set_tile(x, y, EMPTY)
	return tile


func crack(x: int, y: int) -> void:
	cracked[Vector2i(x, y)] = true
	dirty.append(Vector2i(x, y))
	if record:
		changes.append(["c", x, y])


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


func _warn_column(x: int) -> void:
	for y in ROWS:
		if grid[y * COLS + x] != EMPTY and not warnings.has(Vector2i(x, y)):
			warn(x, y)


# --- generation --------------------------------------------------------------------------

func generate(seed_value: int, players: int) -> void:
	rng.seed = seed_value
	var width := mini(COLS, Cfg.ARENA_BASE + Cfg.ARENA_PER_PLAYER * players)
	arena_left = (COLS - width) / 2
	arena_right = arena_left + width
	var best := []
	for attempt in 40:
		var g := _random_terrain()
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
	cracked.clear()
	warnings.clear()
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


func _random_terrain() -> PackedByteArray:
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

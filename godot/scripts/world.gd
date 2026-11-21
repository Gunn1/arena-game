## The tile map: random fair generation, mining, and crumbling.
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
var crumble_timer := 0.0
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


# --- crumbling --------------------------------------------------------------------------

func crumble_interval() -> float:
	var t := clampf((elapsed - Cfg.CRUMBLE_GRACE) / Cfg.CRUMBLE_RAMP, 0.0, 1.0)
	return Cfg.CRUMBLE_START + (Cfg.CRUMBLE_END - Cfg.CRUMBLE_START) * t


func update(dt: float) -> void:
	elapsed += dt
	for pos in warnings.keys():
		warnings[pos] -= dt
		if warnings[pos] <= 0.0:
			set_tile(pos.x, pos.y, EMPTY, "crumble")
	if elapsed < Cfg.CRUMBLE_GRACE:
		return
	crumble_timer -= dt
	while crumble_timer <= 0.0:
		start_crumble()
		crumble_timer += crumble_interval()


func start_crumble() -> void:
	var choices := []
	for y in ROWS:
		for x in COLS:
			if grid[y * COLS + x] != EMPTY and not warnings.has(Vector2i(x, y)):
				choices.append(Vector2i(x, y))
	if choices:
		var pick: Vector2i = choices[rng.randi_range(0, choices.size() - 1)]
		warn(pick.x, pick.y)


# --- generation --------------------------------------------------------------------------

func generate(seed_value: int, players: int) -> void:
	rng.seed = seed_value
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
	crumble_timer = Cfg.CRUMBLE_START
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
		for x in range(2, COLS - 2):
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
	return float(n) / (COLS * (ROWS - Cfg.TOP_ROW))


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


## Choose spawns that are spread out and have about the same ground around them.
## Returns [spawns, spread] or [] if impossible.
func _pick_spawns(g: PackedByteArray, players: int) -> Array:
	var spots := []
	for x in range(3, COLS - 3):                     # stay off the deadly side edges
		for y in ROWS:
			if g[y * COLS + x] != EMPTY:
				if y >= 2 and _blocks_near(g, x, y) >= Cfg.MIN_NEAR:
					spots.append(Vector2i(x, y))     # top block of the column, open sky above
				break
	var near := {}
	for s in spots:
		near[s] = _blocks_near(g, s.x, s.y)
	var min_gap := COLS / (players + 1)
	var best := []
	var best_spread := 2.0
	for attempt in 400:
		var order := spots.duplicate()
		_shuffle(order)
		var pick := []
		for s in order:
			var ok := true
			for o in pick:
				if absi(s.x - o.x) < min_gap:
					ok = false
					break
			if ok:
				pick.append(s)
				if pick.size() == players:
					break
		if pick.size() < players:
			continue
		var lo := 1 << 30
		var hi := 0
		for s in pick:
			lo = mini(lo, near[s])
			hi = maxi(hi, near[s])
		var s_spread := float(hi - lo) / hi
		if s_spread < best_spread:
			pick.sort_custom(func(a, b): return a.x < b.x)
			best = pick
			best_spread = s_spread
		if s_spread <= Cfg.FAIR_SPREAD / 3.0:
			break
	return [] if best.is_empty() else [best, best_spread]


## Copper through the stone, crystal in the deeper stone.
func _add_ores(g: PackedByteArray) -> void:
	for y in ROWS:
		for x in COLS:
			if g[y * COLS + x] != STONE:
				continue
			var r := rng.randf()
			if r < 0.035:
				g[y * COLS + x] = COPPER
			elif r < 0.055 and y > ROWS * 0.6:
				g[y * COLS + x] = CRYSTAL


## Give every spawn the same amount of each ore nearby (turning stone into ore).
func _even_out_ores(g: PackedByteArray, spots: Array) -> void:
	for ore_name in ORE_TILES:
		var tile: int = ORE_TILES[ore_name]
		var counts := []
		for s in spots:
			counts.append(_area(s).filter(func(i): return g[i] == tile).size())
		var target: int = maxi(counts.max(), Cfg.ORE_MIN[ore_name])
		for k in spots.size():
			var stones := _area(spots[k]).filter(func(i): return g[i] == STONE)
			_shuffle(stones)
			for i in mini(target - counts[k], stones.size()):
				g[stones[i]] = tile


func _area(s: Vector2i) -> Array:
	var out := []
	var r := Cfg.ORE_RADIUS
	for y in range(maxi(0, s.y - r), mini(ROWS, s.y + r + 1)):
		for x in range(maxi(0, s.x - r), mini(COLS, s.x + r + 1)):
			out.append(y * COLS + x)
	return out

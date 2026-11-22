## Headless rules tests:  godot --headless --path . -s tests/test_sim.gd
extends SceneTree

var failures := 0
const IDLE := {"left": false, "right": false, "up": false, "down": false, "jump": false, "mine": false,
	"place": false, "item1": false, "item2": false, "item3": false, "craft": false}


func check(ok: bool, what: String) -> void:
	if not ok:
		failures += 1
		push_error("FAIL: " + what)
		print("FAIL: " + what)


func with(extra: Dictionary) -> Dictionary:
	var d := IDLE.duplicate()
	d.merge(extra, true)
	return d


func _init() -> void:
	test_maps()
	test_biomes()
	test_wall_jump()
	test_mouse_aim()
	test_movement()
	test_mining()
	test_crafting()
	test_items()
	test_fighting()
	test_hitstop()
	test_rewind()
	test_zone()
	test_matches()
	print("all good" if failures == 0 else "%d FAILURES" % failures)
	quit(0 if failures == 0 else 1)


func test_maps() -> void:
	var w := World.new()
	for players: int in [2, 3, 4]:
		var fair := 0
		var worst := 0.0
		var start := Time.get_ticks_msec()
		var uneven := {}
		for ore: String in Cfg.ORE_NEAR:
			uneven[ore] = 0
		var width: int = mini(Cfg.COLS, Cfg.ARENA_BASE + Cfg.ARENA_PER_PLAYER * players)
		for seed_value in range(1, 61):
			w.generate(seed_value, players)
			check(w.arena_right - w.arena_left == width, "%dp arena is %d wide" % [players, width])
			check(w.spawns.size() == players, "spawn count")
			for i in w.spawns.size():
				var s: Vector2i = w.spawns[i]
				var slot: int = w.arena_left + roundi(width * (i + 1.0) / (players + 1.0))
				check(s.x >= w.arena_left + 1 and s.x <= w.arena_right - 2, "spawn inside the arena")
				check(absi(s.x - slot) <= 2, "spawn near its slot")
				if i > 0:
					var prev: Vector2i = w.spawns[i - 1]
					check(s.x > prev.x, "spawns left to right")
				check(w.solid(s.x, s.y) and not w.solid(s.x, s.y - 1) and not w.solid(s.x, s.y - 2), "spawn on ground with headroom")
			# Every spawn gets the same count of each ore within its radius, and at least its min.
			for ore: String in Cfg.ORE_NEAR:
				var rule: Dictionary = Cfg.ORE_NEAR[ore]
				var counts: Array[int] = []
				for s: Vector2i in w.spawns:
					counts.append(ore_near(w, s, ore, rule["radius"]))
				var fewest: int = counts.min()
				var most: int = counts.max()
				check(fewest >= int(rule["min"]), "%dp seed %d: minimum %s near every spawn %s" % [players, seed_value, ore, str(counts)])
				if fewest != most:
					uneven[ore] += 1
			if w.spread <= Cfg.FAIR_SPREAD:
				fair += 1
			worst = maxf(worst, w.spread)
		print("maps %dp: %d wide, %d%% within %d%%, worst %d%%, %d ms per map" % [players, width, fair * 100 / 60,
			int(Cfg.FAIR_SPREAD * 100), int(worst * 100), (Time.get_ticks_msec() - start) / 60])
		var parts := PackedStringArray()
		for ore: String in uneven:
			parts.append("%s %d/60" % [ore, uneven[ore]])
		print("ores %dp: maps where spawns got unequal ore counts: %s" % [players, ", ".join(parts)])


## How many tiles of an ore lie in the square of the given radius around a spawn.
func ore_near(w: World, s: Vector2i, ore: String, r: int) -> int:
	var tile: int = World.ORE_TILES[ore]
	var n := 0
	for y in range(s.y - r, s.y + r + 1):
		for x in range(s.x - r, s.x + r + 1):
			if w.get_tile(x, y) == tile:
				n += 1
	return n


# --- biomes, shapes and their special blocks ---------------------------------------------

func test_biomes() -> void:
	# Random picks: every biome and shape shows up.
	var w := World.new()
	var seen := {}
	for seed_value in range(1, 101):
		w.generate(seed_value, 2)
		seen[w.biome] = true
		seen[w.shape] = true
	for name: String in Cfg.BIOMES + Cfg.SHAPES:
		check(seen.has(name), "%s appears in 100 random maps" % name)

	# Every biome x shape x player count keeps the map guarantees.
	var maps := 0
	var start := Time.get_ticks_msec()
	var specials := {"desert": World.SAND, "tundra": World.ICE, "mushroom": World.SLIME, "volcano": World.LAVA}
	var special_maps := {}
	var tnt_maps := 0
	for biome: String in Cfg.BIOMES:
		for shape: String in Cfg.SHAPES:
			for players: int in [2, 3, 4]:
				for seed_value in range(1, 4):
					w.generate(seed_value * 7 + players, players, biome, shape)
					maps += 1
					var tag := "%s %s %dp seed %d" % [biome, shape, players, seed_value]
					check_guarantees(w, players, tag)
					var counts := {}
					for t in w.grid:
						counts[t] = counts.get(t, 0) + 1
					if specials.has(biome) and counts.get(specials[biome], 0) > 0:
						special_maps[biome] = special_maps.get(biome, 0) + 1
					for tile: int in specials.values():
						if tile != specials.get(biome, -1):
							check(counts.get(tile, 0) == 0, "%s: no %d outside its biome" % [tag, tile])
					if counts.get(World.TNT, 0) > 0:
						tnt_maps += 1
	var ms := float(Time.get_ticks_msec() - start) / maps
	check(ms < 60.0, "maps generate in under 60 ms (%.1f)" % ms)
	for biome: String in specials:
		check(special_maps.get(biome, 0) >= 30, "%s has its special block in most maps (%d/36)" % [biome, special_maps.get(biome, 0)])
	check(tnt_maps > maps / 2, "TNT shows up in most maps (%d/%d)" % [tnt_maps, maps])

	# Sand: falls one tile per SAND_FALL into air, lands on the floor, and stops above a player.
	w = World.new()
	w.grid.fill(0)
	w.set_tile(10, 30, World.STONE)
	w.set_tile(10, 10, World.SAND)
	w.set_tile(10, 9, World.SAND)
	w.record = true
	var t := 0.0
	while t < 0.5:
		w.update(Cfg.DT)
		t += Cfg.DT
	var low := -1
	for y in Cfg.ROWS:
		if w.get_tile(10, y) == World.SAND:
			low = y
	check(low >= 12 and low <= 15, "sand falls about one tile per %.2f s (lowest at row %d after 0.5 s)" % [Cfg.SAND_FALL, low])
	check(w.changes.size() > 0 and w.broken.is_empty(), "falling sand is synced as tile changes and leaves no debris")
	while t < 4.0:
		w.update(Cfg.DT)
		t += Cfg.DT
	check(w.get_tile(10, 29) == World.SAND and w.get_tile(10, 28) == World.SAND, "sand piles up on the floor")
	var sim := floor_sim()
	var p: Player = sim.players[0]
	sim.world.set_tile(15, 14, World.SAND)
	run(sim, 90)
	var head := floori(p.y)
	check(sim.world.get_tile(15, head - 1) == World.SAND, "sand stops on top of a player (sand at row %d, head %d)" % [_sand_row(sim.world, 15), head])

	# Ice: let go of walking and you slide much farther than on stone.
	var slide := {}
	for tile: int in [World.STONE, World.ICE]:
		sim = floor_sim()
		for x in range(10, 50):
			sim.world.grid[20 * Cfg.COLS + x] = tile
		p = sim.players[0]
		run(sim, 5)
		run(sim, 60, [with({"right": true}), IDLE])
		var from := p.x
		run(sim, 90)
		slide[tile] = p.x - from
	check(slide[World.ICE] > slide[World.STONE] * 2.5, "ice slides farther than stone (%.2f vs %.2f tiles)" % [slide[World.ICE], slide[World.STONE]])

	# Slime: a hard landing bounces back up at SLIME_BOUNCE of the speed; standing on it is fine.
	sim = floor_sim()
	for x in range(10, 50):
		sim.world.grid[20 * Cfg.COLS + x] = World.SLIME
	p = sim.players[0]
	run(sim, 5)
	check(p.on_ground, "you can stand on slime")
	p.y -= 6.0
	var ratio := 0.0
	for f in 120:
		var before := p.vy
		run(sim, 1)
		if before > 0 and p.vy < 0:
			ratio = -p.vy / before
			break
	check(ratio > 0.75 and ratio < 0.95, "slime bounces at ~%.2f of the landing speed (%.2f)" % [Cfg.SLIME_BOUNCE, ratio])

	# Lava: not solid; touching it throws you up and burns LAVA_DAMAGE, at most every LAVA_COOLDOWN.
	sim = floor_sim()
	p = sim.players[0]
	run(sim, 5)
	var stand_y := p.y
	sim.world.set_tile(15, 19, World.LAVA)
	check(not sim.world.solid(15, 19), "lava isn't solid")
	run(sim, 1)
	var first_vy := p.vy
	check(p.damage == Cfg.LAVA_DAMAGE, "lava burns %d%% (%.1f)" % [int(Cfg.LAVA_DAMAGE), p.damage])
	run(sim, 10)
	check(first_vy < -Cfg.LAVA_LAUNCH * 0.9 and p.y < stand_y - 0.8, "lava throws you up (vy %.1f, rose %.2f)" % [first_vy, stand_y - p.y])
	p.y = stand_y                                   # dropped straight back in: still cooling down
	p.vy = 0.0
	run(sim, 1)
	check(p.damage == Cfg.LAVA_DAMAGE, "lava burns at most once per %.1f s (%.1f)" % [Cfg.LAVA_COOLDOWN, p.damage])
	check(p.last_hit_by == -1, "lava gives nobody KO credit")
	var sim2 := floor_sim()
	sim2.world.set_tile(16, 19, World.LAVA)          # right beside P1, not touching
	run(sim2, 30, [with({"mine": true}), IDLE])
	run(sim2, 30, [with({"mine": true, "mouse": Vector2(16.5, 19.5)}), IDLE])
	check(sim2.world.get_tile(16, 19) == World.LAVA and sim2.players[0].damage == 0.0, "lava can't be mined (%d)" % sim2.world.get_tile(16, 19))
	# The client's prediction (no GameSim) moves the same way.
	var g := FakeGame.new()
	g.world.grid = sim.world.grid.duplicate()
	var q := Player.new(0)
	q.spawn(15, 20)
	q.update(Cfg.DT, IDLE, g)
	check(q.damage == Cfg.LAVA_DAMAGE and q.vy < -Cfg.LAVA_LAUNCH * 0.9, "lava without GameSim: burn %.1f, vy %.1f" % [q.damage, q.vy])

	# TNT: mining it lights it; ~TNT_FUSE later it blows up like a bomb, credited to the miner.
	sim = floor_sim()
	var miner: Player = sim.players[0]
	var victim: Player = sim.players[1]
	victim.spawn(18, 20)
	sim.world.set_tile(16, 19, World.TNT)
	var n := hold_mine(sim, Vector2i(16, 19), {}, 60)
	check(n > 0 and sim.bombs.size() == 1 and int(sim.bombs[0]["owner"]) == 0, "mined TNT is lit, owned by the miner")
	var frames := 0
	while sim.bombs.size() > 0 and frames < 200:
		run(sim, 1)
		frames += 1
	check(absf(frames * Cfg.DT - Cfg.TNT_FUSE) < 0.15, "TNT goes off ~%.1f s after it's lit (%.2f s)" % [Cfg.TNT_FUSE, frames * Cfg.DT])
	check(victim.damage > 0 and victim.last_hit_by == 0, "the blast hits nearby players, credited to the miner (%.1f%%, by %d)" % [victim.damage, victim.last_hit_by])
	check(not sim.world.solid(17, 20) and not sim.world.solid(16, 20), "the blast breaks blocks")
	# A bomb that blasts TNT lights it for the bomb's owner.
	sim = floor_sim()
	sim.world.set_tile(30, 19, World.TNT)
	sim.bombs.append({"x": 31.5, "y": 19.5, "vx": 0.0, "vy": 0.0, "fuse": 0.01, "owner": 1})
	run(sim, 2)
	check(sim.bombs.size() == 1 and int(sim.bombs[0]["owner"]) == 1, "a bomb sets off TNT for its owner")
	print("biomes: all %d biomes and %d shapes appear; %d maps keep the guarantees, %.1f ms per map; sand, ice (%.1f vs %.1f tiles), slime (x%.2f), lava, TNT OK"
		% [Cfg.BIOMES.size(), Cfg.SHAPES.size(), maps, ms, slide[World.ICE], slide[World.STONE], ratio])


func _sand_row(w: World, x: int) -> int:
	for y in Cfg.ROWS:
		if w.get_tile(x, y) == World.SAND:
			return y
	return -1


## Everything a generated map promises, whatever the biome and shape.
func check_guarantees(w: World, players: int, tag: String) -> void:
	var width: int = mini(Cfg.COLS, Cfg.ARENA_BASE + Cfg.ARENA_PER_PLAYER * players)
	check(w.arena_right - w.arena_left == width and w.spawns.size() == players, "%s: arena and spawn count" % tag)
	var solid := 0
	for i in w.grid.size():
		if w.solid(i % Cfg.COLS, i / Cfg.COLS):
			solid += 1
	check(float(solid) / (width * (Cfg.ROWS - Cfg.TOP_ROW)) >= Cfg.MIN_FILL, "%s: at least MIN_FILL solid" % tag)
	check(w.spread <= Cfg.FAIR_SPREAD + 1e-6, "%s: spawns within FAIR_SPREAD (%.2f)" % [tag, w.spread])
	for i in w.spawns.size():
		var s: Vector2i = w.spawns[i]
		var slot: int = w.arena_left + roundi(width * (i + 1.0) / (players + 1.0))
		check(absi(s.x - slot) <= 2, "%s: spawn %d near its slot" % [tag, i])
		check(w.solid(s.x, s.y) and w.get_tile(s.x, s.y - 1) == World.EMPTY and w.get_tile(s.x, s.y - 2) == World.EMPTY,
			"%s: spawn %d on ground with headroom" % [tag, i])
		check(w._blocks_near(w.grid, s.x, s.y) >= Cfg.MIN_NEAR, "%s: spawn %d has MIN_NEAR blocks around" % [tag, i])
	for ore: String in Cfg.ORE_NEAR:
		var rule: Dictionary = Cfg.ORE_NEAR[ore]
		var counts: Array[int] = []
		for s: Vector2i in w.spawns:
			counts.append(ore_near(w, s, ore, rule["radius"]))
		check(counts.min() >= int(rule["min"]) and counts.min() == counts.max(), "%s: equal %s near spawns %s" % [tag, ore, str(counts)])
	for y in Cfg.ROWS:
		for x in Cfg.COLS:
			var tile := w.get_tile(x, y)
			if tile == World.LAVA or tile == World.TNT:
				var safe: int = Cfg.LAVA_SAFE if tile == World.LAVA else Cfg.TNT_SAFE
				for s: Vector2i in w.spawns:
					check(maxi(absi(x - s.x), absi(y - s.y)) > safe, "%s: %d at %d,%d too close to spawn %s" % [tag, tile, x, y, str(s)])
					check(tile != World.LAVA or x != s.x, "%s: lava under a spawn" % tag)
			if tile == World.SAND:
				check(w.get_tile(x, y + 1) != World.EMPTY, "%s: no loose sand at the start (%d,%d)" % [tag, x, y])


class FakeGame:
	var world := World.new()
	var players: Array = []
	func sound(_n, _g := 0.0) -> void: pass
	func burst(_a, _b, _c, _d, _e := 0.0, _f := 0, _g := 0.0) -> void: pass
	func player_in_tile(_x, _y) -> bool: return false
	func use_item(_p, _k) -> bool: return false
	func swing_targets(_p) -> Array: return []
	func melee(_p, _v) -> void: pass


func wall_game() -> FakeGame:
	var g := FakeGame.new()
	g.world.grid.fill(0)
	for y in range(5, 34):
		g.world.grid[y * Cfg.COLS + 30] = World.STONE
	return g


func test_wall_jump() -> void:
	var g := wall_game()
	var p := Player.new(0)
	p.x = 30 - Cfg.PLAYER_W
	p.y = 15.0
	p.vy = 5.0
	p.update(Cfg.DT, with({"right": true}), g)
	check(p.vy <= Cfg.WALL_SLIDE_SPEED + 0.001, "wall slide caps fall speed")
	p.update(Cfg.DT, with({"right": true, "jump": true}), g)
	check(p.vy < 0, "wall jump launches up")
	var start := p.x
	for i in 10:
		p.update(Cfg.DT, with({"right": true}), g)
	check(start - p.x > 0.3, "wall jump kicks away from the wall (%.2f tiles)" % (start - p.x))

	# Climbing: jump stays held (so JUMP_CUT doesn't kill each jump), re-pressed only at a wall.
	p.spawn(0, 0)
	p.x = 30 - Cfg.PLAYER_W
	p.y = 25.0
	var highest := p.y
	for f in 240:
		p.update(Cfg.DT, with({"right": true, "jump": climb_jump(g.world, p, f)}), g)
		highest = minf(highest, p.y)
	check(highest > 25.0 - 4, "a single wall can't be climbed")

	for y in range(5, 34):
		g.world.grid[y * Cfg.COLS + 27] = World.STONE
	p.spawn(0, 0)
	p.x = 30 - Cfg.PLAYER_W
	p.y = 25.0
	highest = p.y
	for f in 240:
		p.update(Cfg.DT, with({("right" if p.facing > 0 else "left"): true, "jump": climb_jump(g.world, p, f)}), g)
		highest = minf(highest, p.y)
	check(highest < 20, "a two-wall chimney can be climbed (reached row %.1f)" % highest)
	print("wall jump: slide, kick, no single-wall climb, chimney climb OK (chimney reached row %.1f)" % highest)


## True if a block is right beside p, on either side, level with its middle.
func touching_wall(w: World, p: Player) -> bool:
	var row := floori(p.centre().y)
	return w.solid(floori(p.x - 0.05), row) or w.solid(floori(p.x + Cfg.PLAYER_W + 0.05), row)


## Climbing input for jump: held in the air, toggled while at a wall so each wall gets a fresh press.
func climb_jump(w: World, p: Player, f: int) -> bool:
	return not (touching_wall(w, p) and f % 2 == 1)


func test_mouse_aim() -> void:
	var g := wall_game()
	var p := Player.new(0)
	p.x = 10.0
	p.y = 10.0
	var c := p.centre()
	var cases := [[Vector2(5, 0), Vector2i(1, 0)], [Vector2(4, -4), Vector2i(1, -1)], [Vector2(0, 3), Vector2i(0, 1)],
		[Vector2(-6, 1), Vector2i(-1, 0)], [Vector2(-3, -3.5), Vector2i(-1, -1)]]
	for k in cases:
		p.update(0.0, with({"mouse": c + k[0], "right": true}), g)
		check(p.aim == k[1], "mouse aim %s" % str(k[1]))
		if k[1].x != 0:
			check(p.facing == k[1].x, "face the mouse")
	print("mouse aim: 8-way snapping and facing OK")


func floor_sim() -> GameSim:
	var sim := GameSim.new()
	sim.players = [Player.new(0), Player.new(1)]
	sim.world.grid.fill(0)
	for x in range(10, 50):
		sim.world.grid[20 * Cfg.COLS + x] = World.STONE
	sim.players[0].spawn(15, 20)
	sim.players[1].spawn(40, 20)
	sim.state = "play"
	return sim


func run(sim: GameSim, frames: int, inputs := []) -> void:
	for i in frames:
		sim.update(Cfg.DT, inputs if inputs else [IDLE, IDLE])


## Did this frame's events include the named sound?
func has_sound(sim: GameSim, snd: String) -> bool:
	for e: Array in sim.events:
		if e[0] == "snd" and e[1] == snd:
			return true
	return false


## Jump from the test floor, holding jump for `hold` frames.
## Returns [rise in tiles, frames going up, frames coming back down].
func jump_arc(hold: int) -> Array:
	var sim := floor_sim()
	var p: Player = sim.players[0]
	run(sim, 5)
	var ground := p.y
	var top := ground
	var top_f := 0
	var land_f := -1
	for f in 90:
		sim.update(Cfg.DT, [with({"jump": f < hold}), IDLE])
		if p.y < top:
			top = p.y
			top_f = f
		elif top < ground and p.on_ground:
			land_f = f
			break
	return [ground - top, top_f + 1, land_f - top_f]


func test_movement() -> void:
	# Walking ramps up to MOVE_SPEED, and ground friction brings it back to 0.
	var sim := floor_sim()
	var p: Player = sim.players[0]
	run(sim, 5)
	check(p.on_ground, "settled on the test floor")
	sim.update(Cfg.DT, [with({"right": true}), IDLE])
	var first: float = p.walk_v
	check(first > 0.0 and first < Cfg.MOVE_SPEED / 2.0, "walking starts slow (walk_v %.2f after 1 frame)" % first)
	var up := 1
	while p.walk_v < Cfg.MOVE_SPEED - 0.01 and up < 60:
		sim.update(Cfg.DT, [with({"right": true}), IDLE])
		up += 1
	check(up * Cfg.DT <= 0.2, "reaches MOVE_SPEED within 0.2 s (%d frames)" % up)
	check(p.walk_v <= Cfg.MOVE_SPEED + 0.01, "walk_v doesn't overshoot MOVE_SPEED (%.2f)" % p.walk_v)
	var down := 0
	while absf(p.walk_v) > 0.01 and down < 60:
		run(sim, 1)
		down += 1
	check(down > 1 and down * Cfg.DT <= 0.15, "ground friction stops you within 0.15 s, not instantly (%d frames)" % down)

	# Variable jump: tapping jump goes clearly lower than holding it. Falling is faster than rising.
	var held: Array = jump_arc(90)
	var tap: Array = jump_arc(1)
	var held_rise: float = held[0]
	var tap_rise: float = tap[0]
	check(held_rise > 2.0, "held jump rises about 2.5 tiles (%.2f)" % held_rise)
	check(tap_rise > 0.1 and tap_rise < 0.6 * held_rise, "tapped jump is lower (%.2f vs %.2f)" % [tap_rise, held_rise])
	var up_f: int = held[1]
	var down_f: int = held[2]
	check(down_f > 0 and down_f < up_f, "falling is faster than rising (%d frames up, %d down)" % [up_f, down_f])

	# Jump buffer: one press just before landing still jumps once you land.
	sim = floor_sim()
	p = sim.players[0]
	run(sim, 5)
	var floor_y := p.y
	p.y = floor_y - 3.0
	var press_f := -1
	var rebound := false
	for f in 90:
		var late := press_f == -1 and p.vy > 0.0 and p.y > floor_y - 0.6
		if late:
			press_f = f
		sim.update(Cfg.DT, [with({"jump": late}), IDLE])
		if press_f >= 0 and f > press_f and p.vy < -5.0:
			rebound = true
			break
	check(press_f >= 0 and rebound, "jump pressed just before landing jumps on landing (pressed frame %d)" % press_f)

	# Hard landing sets land_t and plays "land"; a press long before landing isn't buffered.
	sim = floor_sim()
	p = sim.players[0]
	run(sim, 5)
	floor_y = p.y
	p.y = floor_y - 6.0
	var landed_t := -1.0
	var land_snd := false
	var went_up := false
	for f in 90:
		sim.events.clear()
		sim.update(Cfg.DT, [with({"jump": f == 10}), IDLE])
		went_up = went_up or p.vy < -1.0
		if landed_t < 0.0 and f > 0 and p.on_ground:
			landed_t = p.land_t
			land_snd = has_sound(sim, "land")
	check(landed_t > 0.0, "a hard landing sets land_t (%.2f)" % landed_t)
	check(land_snd, "a hard landing plays \"land\"")
	check(not went_up, "a jump pressed ~0.25 s before landing is not buffered")
	print("movement: accel %d frames, friction %d frames, jump rise held %.2f / tap %.2f, buffer, landing OK"
		% [up, down, held_rise, tap_rise])


## Hold mine (plus `extra` input) until the tile at `at` breaks. Returns the frames it took, or -1.
func hold_mine(sim: GameSim, at: Vector2i, extra: Dictionary, max_frames: int) -> int:
	var inp := with(extra)
	inp["mine"] = true
	for f in max_frames:
		sim.update(Cfg.DT, [inp, IDLE])
		if not sim.world.solid(at.x, at.y):
			return f + 1
	return -1


func test_mining() -> void:
	# Hold to mine the block in front: it breaks after MINE_TIME[tile] and is collected.
	var sim: GameSim
	var p: Player
	var took := {}
	for tile: int in [World.DIRT, World.STONE]:
		sim = floor_sim()
		p = sim.players[0]
		sim.world.grid[19 * Cfg.COLS + 16] = tile
		var need: float = Cfg.MINE_TIME[tile]
		var n := hold_mine(sim, Vector2i(16, 19), {}, 120)
		took[tile] = n
		check(n > 0 and n * Cfg.DT >= need - 0.05 and n * Cfg.DT <= need + 0.05,
			"tile %d breaks after %.2f s of holding mine (took %d frames)" % [tile, need, n])
		var m: String = World.DROPS[tile]
		check(p.inv[m] == 1, "mined %s is collected (%s)" % [m, str(p.inv)])
	check(took[World.STONE] > took[World.DIRT], "stone takes longer than dirt (%s)" % str(took))

	# Letting go resets progress: pressing again starts from zero.
	sim = floor_sim()
	p = sim.players[0]
	sim.world.grid[19 * Cfg.COLS + 16] = World.DIRT
	run(sim, 8, [with({"mine": true}), IDLE])
	var part: float = p.mine_progress
	check(part > 0.2 and sim.world.solid(16, 19), "progress builds while holding mine (%.2f)" % part)
	run(sim, 1)
	check(p.mine_progress == 0.0 and sim.world.solid(16, 19), "releasing mine resets progress")
	var dirt_time: float = Cfg.MINE_TIME[World.DIRT]
	var again := hold_mine(sim, Vector2i(16, 19), {}, 120)
	check(again * Cfg.DT >= dirt_time - 0.05, "mining again starts from zero (%d frames)" % again)

	# Mouse in reach: the tile under it breaks, not the 8-way target. (17,20) is down-right on the
	# floor; 8-way aim would pick (16,20).
	sim = floor_sim()
	p = sim.players[0]
	var before := sim.world.block_count()
	var n2 := hold_mine(sim, Vector2i(17, 20), {"mouse": Vector2(17.5, 20.5)}, 60)
	check(n2 > 0, "mouse-aimed mining breaks the tile under the mouse")
	check(sim.world.solid(16, 20) and sim.world.block_count() == before - 1, "...and only that tile")

	# Mouse far away: whatever gets mined is within reach, along the line toward the mouse.
	sim = floor_sim()
	p = sim.players[0]
	var c := p.centre()
	var grid_before := sim.world.grid.duplicate()
	var inp := with({"mine": true, "mouse": c + Vector2(6, 3)})
	before = sim.world.block_count()
	for f in 60:
		sim.update(Cfg.DT, [inp, IDLE])
		if sim.world.block_count() < before:
			break
	var gone: Array[Vector2i] = []
	for i in grid_before.size():
		if grid_before[i] != sim.world.grid[i]:
			gone.append(Vector2i(i % Cfg.COLS, i / Cfg.COLS))
	check(gone.size() == 1, "far mouse: exactly one tile mined (%d)" % gone.size())
	var dist := -1.0
	if gone.size() == 1:
		dist = (Vector2(gone[0]) + Vector2(0.5, 0.5)).distance_to(c)
		check(dist <= Cfg.REACH + 0.75, "far mouse mines within reach (%.2f tiles away)" % dist)
	print("mining: dirt %s frames, stone %s, release resets, mouse exact tile, far mouse %.2f tiles OK"
		% [str(took[World.DIRT]), str(took[World.STONE]), dist])


## A full inventory (all four materials) with the given amounts, the rest 0.
func inv_of(extra: Dictionary) -> Dictionary:
	var d := {"dirt": 0, "stone": 0, "copper": 0, "crystal": 0}
	d.merge(extra, true)
	return d


func test_crafting() -> void:
	var sim := floor_sim()
	var p: Player = sim.players[0]
	check(not p.craft("push"), "no materials, no craft")
	p.inv = {"dirt": 9, "stone": 9, "copper": 9, "crystal": 9}
	check(p.craft("push") and p.inv["dirt"] == 6 and p.slots[0]["charges"] == 3, "craft push")
	check(p.craft("push") and p.slots[0]["charges"] == 6, "same item stacks")
	p.craft("boost")
	p.craft("laser")
	p.craft("grapple")
	check(p.slots[2]["item"] == "grapple", "full slots: replaces fewest charges")

	# Values: material value dirt 1, stone 1, copper 3, crystal 5.
	var values := {"push": 3, "boost": 4, "platform": 7, "grapple": 5, "bomb": 9, "laser": 7}
	for key: String in values:
		var v: int = Items.item_value(key)
		check(v == int(values[key]), "%s is worth %d (got %d)" % [key, values[key], v])

	# Quick craft picks the most valuable affordable recipe ("" if none).
	# Note: platform and laser tie at 7, but anything that affords both also affords bomb (9),
	# so the later-in-RECIPES tie-break can't show up with the current recipes.
	var picks := [
		[{}, ""],
		[{"stone": 9}, ""],                                              # every non-dirt recipe needs copper or crystal
		[{"dirt": 3}, "push"],
		[{"dirt": 9}, "push"],                                           # platform still needs copper
		[{"stone": 1, "copper": 1}, "boost"],
		[{"stone": 3, "copper": 2}, "grapple"],                          # grapple 5 beats boost 4
		[{"dirt": 4, "copper": 1}, "platform"],                          # platform 7 beats push 3
		[{"stone": 2, "crystal": 1}, "laser"],
		[{"dirt": 4, "stone": 2, "copper": 1}, "platform"],              # platform 7 beats grapple 5, boost 4, push 3
		[{"stone": 2, "crystal": 1, "dirt": 4, "copper": 1}, "bomb"],    # affords platform and laser (7) but bomb is 9
		[{"dirt": 4, "stone": 3, "copper": 2, "crystal": 1}, "bomb"],
	]
	for c: Array in picks:
		var inv: Dictionary = inv_of(c[0])
		var want: String = c[1]
		var got: String = Items.best_affordable(inv)
		check(got == want, "best_affordable %s -> \"%s\" (got \"%s\")" % [str(c[0]), want, got])
		if want != "":
			check(Items.can_afford(want, inv), "can_afford %s with %s" % [want, str(c[0])])
	check(not Items.can_afford("bomb", inv_of({"stone": 3, "copper": 2})), "can't afford bomb without crystal")

	var miss: String = Items.missing_text("boost", inv_of({"stone": 1}))
	check(miss == "need 1 copper", "missing_text boost: \"%s\"" % miss)
	miss = Items.missing_text("grapple", inv_of({}))
	check(miss == "need 2 stone, 1 copper", "missing_text grapple: \"%s\"" % miss)
	miss = Items.missing_text("push", inv_of({"dirt": 3}))
	check(miss == "", "missing_text is empty when affordable: \"%s\"" % miss)

	# Next goal = fewest missing units; ties go to the lower value, then earlier in RECIPES.
	# Empty: push 3, boost 2, platform 5, grapple 3, bomb 3, laser 3 -> boost.
	var goals := [
		[{}, "boost"],
		[{"stone": 2}, "boost"],                   # boost, grapple, laser all miss 1; boost is cheapest
		[{"dirt": 2}, "push"],                     # push misses 1, boost 2
		[{"crystal": 1}, "boost"],                 # boost 2, laser 2, bomb 2; boost is cheapest
	]
	for c: Array in goals:
		var want: String = c[1]
		var got: String = Items.next_goal(inv_of(c[0]))
		check(got == want, "next_goal %s -> \"%s\" (got \"%s\")" % [str(c[0]), want, got])

	# Through the sim: one press crafts the best affordable recipe; holding doesn't repeat it.
	sim = floor_sim()
	p = sim.players[0]
	p.inv = inv_of({"stone": 3, "copper": 2})
	sim.update(Cfg.DT, [with({"craft": true}), IDLE])
	check(p.slots[0] != null and p.slots[0]["item"] == "grapple", "press craft crafts grapple (best affordable)")
	check(p.last_crafted == "grapple", "last_crafted is grapple (got \"%s\")" % p.last_crafted)
	check(p.craft_t > 0.0, "craft_t set after crafting")
	check(p.inv["stone"] == 1 and p.inv["copper"] == 1, "grapple cost paid: %s" % str(p.inv))
	for i in 3:
		sim.update(Cfg.DT, [with({"craft": true}), IDLE])
	check(p.slots[1] == null and p.inv["stone"] == 1 and p.inv["copper"] == 1, "holding craft doesn't craft again")
	sim.update(Cfg.DT, [IDLE, IDLE])
	sim.update(Cfg.DT, [with({"craft": true}), IDLE])
	check(p.slots[1] != null and p.slots[1]["item"] == "boost", "second press crafts the next best (boost) into slot 2")
	check(p.last_crafted == "boost" and p.inv["stone"] == 0 and p.inv["copper"] == 0, "boost cost paid, last_crafted boost")
	sim.update(Cfg.DT, [IDLE, IDLE])
	sim.update(Cfg.DT, [with({"item2": true}), IDLE])
	check(p.vy < -10 and p.slots[1] != null and p.slots[1]["charges"] == 2, "item2 uses the crafted boost")

	# Holding craft no longer steers a menu: left/right walk as normal.
	sim = floor_sim()
	p = sim.players[0]
	p.inv = inv_of({"stone": 3, "copper": 2})
	var start := p.x
	for i in 20:
		sim.update(Cfg.DT, [with({"craft": true, "right": true}), IDLE])
	check(p.x > start + 1.0, "craft + right walks right (moved %.2f)" % (p.x - start))

	# Nothing affordable: nothing changes.
	sim = floor_sim()
	p = sim.players[0]
	var before_crafted: String = p.last_crafted
	sim.update(Cfg.DT, [with({"craft": true}), IDLE])
	sim.update(Cfg.DT, [IDLE, IDLE])
	check(p.slots.count(null) == Cfg.SLOTS, "empty inventory crafts nothing")
	check(p.inv == inv_of({}), "empty inventory stays empty")
	check(p.last_crafted == before_crafted and p.craft_t == 0.0, "no last_crafted / craft_t without a craft")
	print("crafting: costs, stacking, replacement, values, best_affordable, missing_text, next_goal, quick craft OK")


func test_items() -> void:
	var sim := floor_sim()
	var p: Player = sim.players[0]
	sim.world.grid[19 * Cfg.COLS + 16] = World.COPPER
	# Copper takes MINE_TIME[copper] (0.55 s, ~34 frames) of holding mine.
	for i in 45:
		sim.update(Cfg.DT, [with({"mine": true}), IDLE])
	check(p.inv["copper"] == 1 and not sim.world.solid(16, 19), "holding mine on ore breaks it and gives copper")

	sim = floor_sim()
	p = sim.players[0]
	check(sim.use_item(p, "boost") and p.vy < -10, "boost")

	sim = floor_sim()
	p = sim.players[0]
	p.y -= 3
	check(sim.use_item(p, "platform"), "platform used")
	var row := floori(p.y + Cfg.PLAYER_H - 0.01) + 1
	var n := 0
	for x in range(10, 25):
		if sim.world.get_tile(x, row) == World.PLACED:
			n += 1
	check(n == 5, "platform places 5 blocks")

	sim = floor_sim()
	p = sim.players[0]
	sim.world.grid[11 * Cfg.COLS + 23] = World.STONE
	p.aim = Vector2i(1, -1)
	var target := Vector2(23.5, 11.5)
	var d0 := p.centre().distance_to(target)
	check(sim.use_item(p, "grapple") and p.grapple != null, "grapple hooks")
	run(sim, 30)
	check(p.centre().distance_to(target) < d0 - 4, "grapple pulls you in")
	sim = floor_sim()
	p = sim.players[0]
	p.aim = Vector2i(0, -1)
	check(not sim.use_item(p, "grapple"), "grapple into the sky spends nothing")

	sim = floor_sim()
	p = sim.players[0]
	var q: Player = sim.players[1]
	q.x = p.x + 2.5
	var qx := q.x
	p.facing = 1
	sim.use_item(p, "push")
	run(sim, 40)
	check(q.x > qx + 2.5, "push knocks the other player away")

	sim = floor_sim()
	p = sim.players[0]
	var before := sim.world.block_count()
	p.aim = Vector2i(0, 1)
	sim.use_item(p, "laser")
	check(sim.world.block_count() < before, "laser cuts blocks")

	sim = floor_sim()
	p = sim.players[0]
	q = sim.players[1]
	q.x = p.x + 2
	before = sim.world.block_count()
	p.aim = Vector2i(0, 1)
	sim.use_item(p, "bomb")
	run(sim, int(Cfg.BOMB_FUSE * 60) + 5)
	check(sim.world.block_count() <= before - 4, "bomb blows a hole")
	check(absf(q.kvx) > 1 or q.y < 18, "bomb flings nearby players")
	print("items: mining ore, boost, platform, grapple hit+miss, push, laser, bomb OK")


## Two players side by side on the test floor, p (player 0) at x facing right, q right next to it.
func fight_sim(q_damage: float, at: float) -> GameSim:
	var sim := floor_sim()
	var p: Player = sim.players[0]
	var q: Player = sim.players[1]
	p.x = at
	q.x = at + 1.0
	q.y = p.y
	q.damage = q_damage
	p.facing = 1
	p.aim = Vector2i(1, 0)
	return sim


func feed_has(sim: GameSim, text: String) -> bool:
	for e: Array in sim.feed:
		if str(e[0]).contains(text):
			return true
	return false


func run_until_dead(sim: GameSim, who: Player, max_frames: int) -> void:
	for f in max_frames:
		if not who.alive:
			return
		sim.update(Cfg.DT, [IDLE, IDLE])


func test_fighting() -> void:
	# One swing: damage, knockback, stun, credit, and no mining that frame.
	var sim := fight_sim(0.0, 15.1)
	var p: Player = sim.players[0]
	var q: Player = sim.players[1]
	var blocks_before := sim.world.block_count()
	var x0 := q.x
	sim.update(Cfg.DT, [with({"mine": true}), IDLE])
	check(q.damage == Cfg.SWING_DAMAGE, "a swing adds SWING_DAMAGE")
	check(q.kvx > 0, "a swing knocks the victim away")
	check(q.stun > 0, "a swing stuns")
	check(q.last_hit_by == 0, "the victim remembers who hit it")
	check(p.dealt == Cfg.SWING_DAMAGE, "the hitter's damage dealt is counted")
	check(sim.world.block_count() == blocks_before and p.mine_progress == 0.0, "a swing that hits doesn't also mine")
	var near_kvx := q.kvx
	run(sim, 90)
	var near := q.x - x0

	# Same, with a solid tile as the mining target: a down swing at q aims at the floor under p.
	var spike := fight_sim(0.0, 15.1)
	var sp: Player = spike.players[0]
	var sq: Player = spike.players[1]
	spike.update(Cfg.DT, [with({"mine": true, "down": true}), IDLE])
	check(sq.last_hit_by == 0, "a down swing hits the player beside you")
	check(sp.mine_progress == 0.0 and spike.world.solid(15, 20), "a down swing that hits doesn't mine the floor (%.2f)"
		% sp.mine_progress)

	# Knockback grows with damage %.
	sim = fight_sim(112.0, 15.1)
	q = sim.players[1]
	x0 = q.x
	sim.update(Cfg.DT, [with({"mine": true}), IDLE])
	var far_kvx := q.kvx
	run(sim, 90)
	var far := q.x - x0
	check(q.alive, "the far knock test stays on the floor")
	check(far > 2.0 * near, "knockback grows with damage (%.1f vs %.1f tiles)" % [far, near])
	var ratio: float = far_kvx / near_kvx if near_kvx != 0.0 else 0.0
	var expected := (1.0 + 120.0 / Cfg.KNOCK_GROWTH) / (1.0 + Cfg.SWING_DAMAGE / Cfg.KNOCK_GROWTH)
	check(absf(ratio - expected) < 0.05, "knock ratio %.2f, expected %.2f" % [ratio, expected])

	# Knocked off the edge: the hitter gets the KO.
	sim = fight_sim(150.0, 46.0)
	p = sim.players[0]
	q = sim.players[1]
	sim.update(Cfg.DT, [with({"mine": true}), IDLE])
	check(q.last_hit_by == 0, "edge hit lands")
	run_until_dead(sim, q, 300)
	check(not q.alive, "a heavy hit at the edge kills")
	check(p.kos == 1 and q.falls == 0, "KO goes to the hitter, not a fall")
	check(feed_has(sim, "knocked out"), "feed shows the KO")

	# Walking off with nobody's help is a plain fall.
	sim = floor_sim()
	p = sim.players[0]
	q = sim.players[1]
	q.x = 52.0
	q.y = 15.0
	run_until_dead(sim, q, 300)
	check(not q.alive, "falling off the map kills")
	check(q.falls == 1 and p.kos == 0, "no hit, no KO: it's a fall")
	check(feed_has(sim, "fell"), "feed shows the fall")
	print("fighting: swing damage/knock/stun/credit, no mine on hit, %.1fx farther at 112%% (kvx x%.2f), KO credit, plain fall OK"
		% [far / near if near != 0.0 else 0.0, ratio])


func test_hitstop() -> void:
	# A hit freezes the whole sim for a moment; nothing moves until hitstop runs out.
	var sim := fight_sim(0.0, 15.1)
	var q: Player = sim.players[1]
	sim.update(Cfg.DT, [with({"mine": true}), IDLE])
	var light: float = sim.hitstop
	check(q.last_hit_by == 0, "hitstop test: the swing lands")
	check(light > 0.0, "a hit starts hitstop (%.3f)" % light)
	var qx := q.x
	var qy := q.y
	run(sim, 2)
	check(q.x == qx and q.y == qy, "nothing moves during hitstop")
	var frozen := 2
	while sim.hitstop > 0.0 and frozen < 30:
		run(sim, 1)
		frozen += 1
	check(sim.hitstop <= 0.0, "hitstop runs out (%d frames)" % frozen)
	run(sim, 3)
	check(q.x > qx + 0.05, "after hitstop the victim flies (moved %.2f)" % (q.x - qx))

	# Harder hits freeze longer, up to the cap.
	sim = fight_sim(112.0, 15.1)
	sim.update(Cfg.DT, [with({"mine": true}), IDLE])
	var heavy: float = sim.hitstop
	check(heavy > light and heavy <= 0.14 + 0.001, "heavier hit, longer hitstop (%.3f vs %.3f, max 0.14)" % [heavy, light])
	print("hitstop: %.3f s light, %.3f s heavy, %d frames frozen, freeze then fly OK" % [light, heavy, frozen])

	# Online (freeze_on_hit off): nothing freezes and every input is applied; the hit only
	# sets hit_flash for the impact look, which is in the snapshot and fades out.
	sim = fight_sim(0.0, 15.1)
	sim.freeze_on_hit = false
	var p: Player = sim.players[0]
	q = sim.players[1]
	sim.update(Cfg.DT, [with({"mine": true}), IDLE])
	check(q.last_hit_by == 0, "online: the swing lands")
	check(sim.hitstop == 0.0, "online: a hit doesn't start hitstop (%.3f)" % sim.hitstop)
	check(sim.hit_flash > 0.0 and sim.impact(), "online: a hit starts the hit flash (%.3f)" % sim.hit_flash)
	var client := GameSim.new()
	client.apply_snapshot(sim.snapshot())
	check(client.hit_flash == sim.hit_flash and client.impact(), "online: the hit flash is in the snapshot")
	qx = q.x
	var px := p.x
	var moved_every_frame := true
	var flash_frames := 0
	for f in 12:
		var before := p.x
		sim.update(Cfg.DT, [with({"left": true}), IDLE])
		moved_every_frame = moved_every_frame and p.x < before
		if sim.hit_flash > 0.0:
			flash_frames += 1
	check(q.x > qx + 0.05, "online: the victim flies straight away (moved %.2f)" % (q.x - qx))
	check(moved_every_frame and p.x < px, "online: the attacker's input is applied every frame of the flash")
	check(sim.hit_flash == 0.0 and not sim.impact(), "online: the hit flash fades (%d frames)" % flash_frames)
	print("hitstop online: no freeze, flash %.3f s (%d frames), victim moved %.2f, no inputs dropped OK"
		% [light, flash_frames, q.x - qx])


## Lag compensation: a remote swing (its input carries "view", the tick the attacker was seeing
## the others at) is tested against where the target was then. q stands next to p for the first
## `near` ticks, then is 3+ tiles away (out of reach). view_ago -1: no view (a local swing).
func rewind_swing(view_ago: int, frames: int, near: int) -> bool:
	var sim := fight_sim(0.0, 15.1)
	sim.freeze_on_hit = false
	var q: Player = sim.players[1]
	var x0 := q.x
	for f in frames:
		q.x = x0 if f < near else x0 + 3.0 + f * 0.05
		sim.update(Cfg.DT, [IDLE, IDLE])
	var inp := with({"mine": true})
	if view_ago != -1:
		inp["view"] = float(sim.tick - view_ago)
	sim.update(Cfg.DT, [inp, IDLE])
	return q.last_hit_by == 0


func test_rewind() -> void:
	# The target was in reach 12 ticks (200 ms) ago and has moved out of reach since.
	var rewound := rewind_swing(11, 12, 2)
	var current := rewind_swing(-1, 12, 2)
	check(rewound, "a swing aimed at where the target was (view 200 ms back) hits")
	check(not current, "without the rewind the same swing misses (the target has moved away)")
	# In reach only 30 ticks (500 ms) ago: the rewind stops at 300 ms, so it misses.
	var too_old := rewind_swing(29, 30, 2)
	check(not too_old, "no rewinding more than 300 ms")
	# A view in the future (or garbage) is clamped to now.
	var future := rewind_swing(-20, 12, 2)
	check(not future, "a view newer than now uses current positions")
	print("rewind: 200 ms back hits %s, no rewind hits %s, 500 ms back hits %s OK" % [rewound, current, too_old])


func test_zone() -> void:
	var w := World.new()
	w.generate(1, 2)
	var mid: int = (w.arena_left + w.arena_right) / 2
	if not w.solid(mid, 25):
		w.set_tile(mid, 25, World.STONE)           # make sure the middle has something to survive
	var start_blocks := w.block_count()
	var half := Cfg.ZONE_GRACE + Cfg.ZONE_CLOSE_TIME / 2.0
	while w.elapsed < half:
		w.update(Cfg.DT)
	var edge := 0
	var middle := 0
	for y in Cfg.ROWS:
		for k in 4:
			if w.solid(w.arena_left + k, y) or w.solid(w.arena_right - 1 - k, y):
				edge += 1
		for x in range(mid - 3, mid + 3):
			if w.solid(x, y):
				middle += 1
	check(edge == 0, "edge columns gone at half time")
	check(middle > 0, "middle still standing at half time")
	check(w.zone_left > w.arena_left and w.zone_right < w.arena_right, "zone edges moved in")
	var spot := Vector2i(w.arena_left + 1, 15)
	w.set_tile(spot.x, spot.y, World.PLACED)
	check(w.warnings.has(spot), "a block built outside the zone starts crumbling")
	var zl := w.zone_left
	var zr := w.zone_right
	var done_at := Cfg.ZONE_GRACE + Cfg.ZONE_CLOSE_TIME + Cfg.CRUMBLE_WARN + 0.5
	while w.elapsed < done_at:
		w.update(Cfg.DT)
	check(w.block_count() == 0, "everything crumbles once the zone closes (%d left)" % w.block_count())
	print("zone: %d blocks; at %.0fs edges gone, middle has %d, zone %.1f..%.1f; empty by %.1fs; building outside warns OK"
		% [start_blocks, half, middle, zl, zr, done_at])


func test_matches() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var limit := Cfg.ROUND_INTRO + Cfg.ZONE_GRACE + Cfg.ZONE_CLOSE_TIME + Cfg.CRUMBLE_WARN + 3.0
	for count in [2, 3, 4]:
		var sim := GameSim.new()
		sim.start_match(count)
		var held := []
		for i in count:
			held.append(IDLE.duplicate())
		var frames := 0
		var rounds := {}
		var round_start := 0
		var last_round := sim.round_no
		var last_state := sim.state
		var lengths: Array[float] = []
		while sim.state != "match_over" and frames < 60 * 60 * 15:
			for h in held:
				for k in h:
					if rng.randf() < 0.08:
						h[k] = not h[k]
			var frozen: bool = sim.hitstop > 0.0
			sim.update(Cfg.DT, held.map(func(h): return h.duplicate()))
			sim.events.clear()
			rounds[sim.round_no] = true
			frames += 1
			if frozen:
				round_start += 1                   # hit freezes pause the zone clock; don't count them
			if sim.state == "outro" and last_state == "play":
				lengths.append((frames - round_start) / 60.0)
			if sim.round_no != last_round:
				round_start = frames
				last_round = sim.round_no
			last_state = sim.state
		check(sim.state == "match_over", "%dp match finishes" % count)
		var total := 0.0
		var longest := 0.0
		for l in lengths:
			total += l
			longest = maxf(longest, l)
		check(longest <= limit, "%dp rounds end within %.1fs (longest %.1fs)" % [count, limit, longest])
		var avg := total / maxi(1, lengths.size())
		print("match %dp: over after %d rounds, %ds, rounds avg %.1fs longest %.1fs -> %s" % [count, rounds.size(),
			frames / 60, avg, longest, sim.message])

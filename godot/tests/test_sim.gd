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

	# Falling with the floor just below a wall, jump waits for the landing: a normal jump, no kick.
	g = wall_game()
	for x in range(20, 30):
		g.world.grid[30 * Cfg.COLS + x] = World.STONE
	p.spawn(0, 0)
	p.x = 30 - Cfg.PLAYER_W
	p.y = 30 - Cfg.PLAYER_H - 0.3
	p.vy = 6.0
	p.update(Cfg.DT, with({"jump": true}), g)
	check(p.kvx == 0.0 and p.last_wall == 0, "no wall jump just above the floor")
	var jumped := false
	for i in 6:
		p.update(Cfg.DT, with({"jump": true}), g)
		jumped = jumped or p.vy < -Cfg.WALL_JUMP_SPEED
	check(jumped and p.kvx == 0.0, "the buffered press becomes a full ground jump")

	# A ledge lip beside your feet isn't a wall.
	g = wall_game()
	g.world.grid.fill(0)
	g.world.grid[20 * Cfg.COLS + 30] = World.STONE
	p.spawn(0, 0)
	p.x = 30 - Cfg.PLAYER_W
	p.y = 20.0 - Cfg.PLAYER_H + 0.3                 # the block covers the bottom 0.3 of the body
	check(p.wall_side(g.world) == 0, "a block beside your feet is not a wall")
	p.y = 20.2
	check(p.wall_side(g.world) == 1, "a block beside your head is a wall")
	print("wall jump: slide, kick, no single-wall climb, ground first, ledge lips, chimney climb OK (chimney reached row %.1f)" % highest)


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
	check(not p.craft("fan"), "no materials, no craft")
	p.inv = {"dirt": 9, "stone": 9, "copper": 9, "crystal": 9}
	check(p.craft("fan") and p.inv["dirt"] == 6 and p.slots[0]["charges"] == 2, "craft fan")
	check(p.craft("fan") and p.slots[0]["charges"] == 4, "same item stacks")
	p.craft("steel")
	p.craft("bounce")
	p.craft("turret")
	check(p.slots[2]["item"] == "turret", "full slots: replaces fewest charges")

	# Values: material value dirt 1, stone 1, copper 3, crystal 5.
	var values := {"ladder": 2, "ice": 2, "fake": 3, "fan": 3, "glue": 5, "bounce": 5, "trapdoor": 5, "steel": 6,
		"magnet": 7, "spikes": 7, "bumper": 8, "heal": 8, "mine": 9, "turret": 10}
	check(values.size() == Items.RECIPES.size(), "every recipe has a value check")
	for key: String in values:
		var v: int = Items.item_value(key)
		check(v == int(values[key]), "%s is worth %d (got %d)" % [key, values[key], v])

	# Quick craft picks the most valuable affordable recipe (ties: later in RECIPES; "" if none).
	var picks := [
		[{}, ""],
		[{"stone": 9}, ""],                                  # stone alone buys nothing
		[{"dirt": 2}, "ladder"],
		[{"dirt": 3}, "fan"],
		[{"dirt": 2, "stone": 1}, "fake"],                   # fake 3 beats ladder and ice (2)
		[{"dirt": 2, "copper": 1}, "bounce"],                # glue and bounce tie at 5: the later one
		[{"stone": 3, "copper": 1}, "steel"],
		[{"stone": 3, "copper": 2}, "bumper"],               # bumper 8 beats magnet 7, steel 6
		[{"copper": 1, "crystal": 1}, "heal"],
		[{"stone": 1, "copper": 1, "crystal": 1}, "mine"],   # mine 9 beats heal 8
		[{"stone": 2, "copper": 1, "crystal": 1}, "turret"],
	]
	for c: Array in picks:
		var inv: Dictionary = inv_of(c[0])
		var want: String = c[1]
		var got: String = Items.best_affordable(inv)
		check(got == want, "best_affordable %s -> \"%s\" (got \"%s\")" % [str(c[0]), want, got])
		if want != "":
			check(Items.can_afford(want, inv), "can_afford %s with %s" % [want, str(c[0])])
	check(not Items.can_afford("mine", inv_of({"stone": 3, "copper": 2})), "can't afford a mine without crystal")

	var miss: String = Items.missing_text("bounce", inv_of({"dirt": 2}))
	check(miss == "need 1 copper", "missing_text bounce: \"%s\"" % miss)
	miss = Items.missing_text("steel", inv_of({}))
	check(miss == "need 3 stone, 1 copper", "missing_text steel: \"%s\"" % miss)
	miss = Items.missing_text("fan", inv_of({"dirt": 3}))
	check(miss == "", "missing_text is empty when affordable: \"%s\"" % miss)

	# Next goal = fewest missing units; ties go to the lower value, then earlier in RECIPES.
	var goals := [
		[{}, "ladder"],                            # ladder, ice and heal miss 2; ladder is cheapest and first
		[{"crystal": 1}, "heal"],                  # heal misses 1
		[{"stone": 2}, "ice"],                     # ice, trapdoor, spikes miss 1; ice is cheapest
		[{"stone": 2, "copper": 1}, "trapdoor"],   # affordable: nothing missing
	]
	for c: Array in goals:
		var want: String = c[1]
		var got: String = Items.next_goal(inv_of(c[0]))
		check(got == want, "next_goal %s -> \"%s\" (got \"%s\")" % [str(c[0]), want, got])

	# Tap craft (press and let go): the best affordable recipe, made when you let go.
	sim = floor_sim()
	p = sim.players[0]
	p.inv = inv_of({"stone": 4, "copper": 3})
	sim.update(Cfg.DT, [with({"craft": true}), IDLE])
	check(p.slots[0] == null, "nothing is made while craft is still down")
	sim.update(Cfg.DT, [IDLE, IDLE])
	check(p.slots[0] != null and p.slots[0]["item"] == "bumper", "a tap crafts bumper (best affordable)")
	check(p.last_crafted == "bumper" and p.craft_t > 0.0, "last_crafted and popup set")
	check(p.inv["stone"] == 2 and p.inv["copper"] == 1, "bumper cost paid: %s" % str(p.inv))
	check(not p.crafting, "a tap never opens the menu")
	sim.update(Cfg.DT, [with({"craft": true}), IDLE])
	sim.update(Cfg.DT, [IDLE, IDLE])
	check(p.slots[1] != null and p.slots[1]["item"] == "trapdoor", "second tap crafts the next best (trapdoor)")
	sim.update(Cfg.DT, [with({"item2": true}), IDLE])
	check(sim.world.get_tile(16, 19) == World.TRAPDOOR and p.slots[1]["charges"] == 2, "item2 places the trapdoor in front")

	# Holding craft opens the menu on the best affordable pick; left/right change it (and don't walk);
	# letting go crafts the pick.
	sim = floor_sim()
	p = sim.players[0]
	p.inv = inv_of({"dirt": 5, "stone": 4, "copper": 3})
	var held_frames := ceili(Cfg.MENU_DELAY / Cfg.DT) + 1
	run(sim, held_frames, [with({"craft": true}), IDLE])
	check(p.crafting and Items.RECIPES[p.recipe] == "bumper", "holding opens the menu on the best pick (%s)" % Items.RECIPES[p.recipe])
	var x_menu := p.x
	sim.update(Cfg.DT, [with({"craft": true, "left": true}), IDLE])
	check(Items.RECIPES[p.recipe] == "spikes", "left picks the previous recipe")
	sim.update(Cfg.DT, [with({"craft": true}), IDLE])
	sim.update(Cfg.DT, [with({"craft": true, "left": true}), IDLE])
	check(Items.RECIPES[p.recipe] == "magnet", "left again: magnet")
	run(sim, 10, [with({"craft": true, "left": true}), IDLE])
	check(absf(p.x - x_menu) < 0.01, "with the menu open (no mouse), left/right don't walk")
	check(Items.RECIPES[p.recipe] == "magnet", "holding left doesn't keep scrolling")
	sim.update(Cfg.DT, [IDLE, IDLE])
	check(not p.crafting and p.slots[0] != null and p.slots[0]["item"] == "magnet", "letting go crafts the pick")
	# Wheel and mouse hover pick too; an unaffordable pick crafts nothing.
	run(sim, held_frames, [with({"craft": true}), IDLE])
	check(Items.RECIPES[p.recipe] == "steel", "reopened on the new best pick (steel)")
	sim.update(Cfg.DT, [with({"craft": true, "wheel": 1}), IDLE])
	check(Items.RECIPES[p.recipe] == "magnet", "the wheel moves the pick")
	var r: Rect2 = GameSim.menu_layout(p)[1][Items.RECIPES.find("turret")]
	var mouse_tiles := Vector2(r.get_center().x / Cfg.CELL, (r.get_center().y - Cfg.HUD_H) / Cfg.CELL)
	sim.update(Cfg.DT, [with({"craft": true, "mouse": mouse_tiles}), IDLE])
	check(Items.RECIPES[p.recipe] == "turret", "the mouse picks the recipe under it (%s)" % Items.RECIPES[p.recipe])
	var inv_before: Dictionary = p.inv.duplicate()
	sim.update(Cfg.DT, [IDLE, IDLE])
	check(p.inv == inv_before, "letting go on something you can't afford crafts nothing")

	# Tap craft + right still walks.
	sim = floor_sim()
	p = sim.players[0]
	p.inv = inv_of({"stone": 3, "copper": 2})
	var start := p.x
	for i in 8:
		sim.update(Cfg.DT, [with({"craft": i < 3, "right": true}), IDLE])
	check(p.x > start + 0.2, "tap craft + right walks right (moved %.2f)" % (p.x - start))

	# Nothing affordable: nothing changes.
	sim = floor_sim()
	p = sim.players[0]
	var before_crafted: String = p.last_crafted
	sim.update(Cfg.DT, [with({"craft": true}), IDLE])
	sim.update(Cfg.DT, [IDLE, IDLE])
	sim.update(Cfg.DT, [IDLE, IDLE])
	check(p.slots.count(null) == Cfg.SLOTS, "empty inventory crafts nothing")
	check(p.inv == inv_of({}), "empty inventory stays empty")
	check(p.last_crafted == before_crafted and p.craft_t == 0.0, "no last_crafted / craft_t without a craft")
	print("crafting: costs, stacking, replacement, values, best_affordable, missing_text, next_goal, tap craft, menu (keys, wheel, mouse) OK")


func test_items() -> void:
	var sim := floor_sim()
	var p: Player = sim.players[0]
	sim.world.grid[19 * Cfg.COLS + 16] = World.COPPER
	# Copper takes MINE_TIME[copper] (0.55 s, ~34 frames) of holding mine.
	for i in 45:
		sim.update(Cfg.DT, [with({"mine": true}), IDLE])
	check(p.inv["copper"] == 1 and not sim.world.solid(16, 19), "holding mine on ore breaks it and gives copper")

	# Placing: at your target, owned by you; no room = nothing spent.
	sim = floor_sim()
	p = sim.players[0]
	check(sim.use_item(p, "steel") and sim.world.get_tile(16, 19) == World.STEEL, "steel goes in front of you")
	check(sim.world.owners.get(Vector2i(16, 19), -1) == 0, "placed blocks remember who placed them")
	sim.world.set_tile(16, 18, World.STONE)
	p.aim = Vector2i(1, 0)
	check(not sim.use_item(p, "steel"), "no room: nothing placed")

	# Special blocks reach further than plain blocks.
	sim = floor_sim()
	p = sim.players[0]
	p.mouse = p.centre() + Vector2(4.0, 0.3)
	var far := p.target(sim.world, true, Cfg.BLOCK_REACH)
	check(p.target(sim.world, true) != far, "plain placing can't reach 4 tiles")
	check(sim.use_item(p, "steel") and sim.world.get_tile(far.x, far.y) == World.STEEL, "special blocks reach 4 tiles")

	# Steel: slow to mine and bombproof.
	sim = floor_sim()
	sim.world.set_tile(30, 19, World.STEEL)
	sim.bombs.append({"x": 31.5, "y": 19.5, "vx": 0.0, "vy": 0.0, "fuse": 0.01, "owner": -1})
	run(sim, 2)
	check(sim.world.get_tile(30, 19) == World.STEEL and sim.world.get_tile(31, 20) == World.EMPTY, "steel survives a blast that digs stone")
	check(Cfg.MINE_TIME[World.STEEL] > Cfg.MINE_TIME[World.STONE] * 3, "steel is slow to mine")

	# Fan: placed right of you it blows right, along its row, and not through blocks.
	sim = floor_sim()
	p = sim.players[0]
	var q: Player = sim.players[1]
	p.mouse = Vector2(17.5, 19.5)
	check(sim.use_item(p, "fan") and sim.world.get_tile(17, 19) == World.FAN_R, "a fan placed to your right blows right")
	q.x = 20.0
	var px := p.x
	run(sim, 30)
	check(q.x > 22.0, "the fan blows a player in its row away (moved %.2f)" % (q.x - 20.0))
	check(absf(p.x - px) < 0.05, "a fan doesn't blow behind itself")
	sim = floor_sim()
	q = sim.players[1]
	sim.world.set_tile(17, 19, World.FAN_R)
	sim.world.set_tile(19, 19, World.STONE)
	q.x = 21.0
	run(sim, 30)
	check(absf(q.x - 21.0) < 0.05, "a block stops the wind")

	# Magnet: pulls players within range toward it, not ones farther away.
	sim = floor_sim()
	q = sim.players[1]
	sim.world.set_tile(36, 19, World.MAGNET)
	var p0x: float = sim.players[0].x
	run(sim, 40)
	check(q.x < 39.5, "a magnet pulls a nearby player in (q.x %.2f)" % q.x)
	check(absf(sim.players[0].x - p0x) < 0.05, "a magnet far away does nothing")

	# Bounce pad: stepping on it launches you high.
	sim = floor_sim()
	q = sim.players[1]
	sim.world.set_tile(40, 20, World.BOUNCE)
	var top := q.y
	for i in 40:
		sim.update(Cfg.DT, [IDLE, IDLE])
		top = minf(top, q.y)
	check(top < 18.4 - 4.0, "a bounce pad launches you over 4 tiles (rose %.2f)" % (18.4 - top))

	# Mine: placed TNT goes off when an enemy gets close, credited to whoever placed it.
	sim = floor_sim()
	p = sim.players[0]
	q = sim.players[1]
	check(sim.use_item(p, "mine") and sim.world.get_tile(16, 19) == World.TNT, "mine placed")
	run(sim, 10)
	check(sim.world.get_tile(16, 19) == World.TNT and sim.bombs.is_empty(), "your own mine ignores you")
	q.x = 17.6
	run(sim, 1)
	check(sim.bombs.size() == 1 and int(sim.bombs[0]["owner"]) == 0, "an enemy near the mine sets it off, for the owner")
	run(sim, int(Cfg.MINE_FUSE * 60) + 3)
	check(q.damage > 0 and sim.bombs.is_empty(), "the mine blows up and hurts the enemy")

	# Turret: shoots at enemies in range (never its owner) and hits them.
	sim = floor_sim()
	p = sim.players[0]
	q = sim.players[1]
	check(sim.use_item(p, "turret"), "turret placed")
	run(sim, 90)
	check(sim.projectiles.is_empty() and p.damage == 0, "a turret doesn't shoot its owner")
	q.x = 24.0
	var hit := false
	for i in 120:
		sim.update(Cfg.DT, [IDLE, IDLE])
		hit = hit or q.damage > 0
	check(hit, "a turret shoots an enemy in range")
	# Updraft: a fan placed in your own column blows up and lifts players above it.
	sim = floor_sim()
	p = sim.players[0]
	sim.world.set_tile(15, 20, World.EMPTY)
	p.mouse = Vector2(floori(p.centre().x) + 0.5, 21.5)
	check(sim.use_item(p, "fan") and sim.world.get_tile(floori(p.centre().x), 21) == World.FAN_U, "a fan placed below you is an updraft")
	sim = floor_sim()
	q = sim.players[1]
	var col := floori(q.centre().x)
	sim.world.set_tile(col, 20, World.FAN_U)
	var y0 := q.y
	run(sim, 40)
	check(q.y < y0 - 2.0, "an updraft lifts the player above it (rose %.2f)" % (y0 - q.y))

	# Ladder: not solid; up climbs, nothing holds on (no falling), and it's placeable in the air.
	sim = floor_sim()
	q = sim.players[1]
	col = floori(q.centre().x)
	for ty in range(12, 20):
		sim.world.set_tile(col, ty, World.LADDER)
	check(not sim.world.solid(col, 15), "ladders aren't solid")
	y0 = q.y
	run(sim, 40, [IDLE, with({"up": true})])
	check(q.y < y0 - 3.0, "up climbs a ladder (rose %.2f)" % (y0 - q.y))
	var hang := q.y
	run(sim, 20)
	check(absf(q.y - hang) < 0.01, "letting go holds you on the ladder")

	# Spikes: touching them hurts and throws you up, credited to whoever placed them.
	sim = floor_sim()
	p = sim.players[0]
	q = sim.players[1]
	sim.world.set_tile(floori(q.centre().x), 20, World.SPIKES)
	sim.world.owners[Vector2i(floori(q.centre().x), 20)] = 0
	run(sim, 2)
	check(q.damage == Cfg.SPIKE_DAMAGE and q.vy < 0 and q.last_hit_by == 0, "spikes hurt (%.0f%%), launch, and credit the placer" % q.damage)

	# Bumper: running into one flings you back.
	sim = floor_sim()
	q = sim.players[1]
	sim.world.set_tile(floori(q.x + Cfg.PLAYER_W) + 1, 19, World.BUMPER)
	var x1 := q.x
	run(sim, 20, [IDLE, with({"right": true})])
	run(sim, 15)
	check(q.x < x1 - 1.5, "a bumper flings you back (%.2f tiles)" % (x1 - q.x))

	# Glue: slow walking and weak jumps.
	sim = floor_sim()
	q = sim.players[1]
	for x in range(30, 50):
		sim.world.set_tile(x, 20, World.GLUE)
	x1 = q.x
	run(sim, 30, [IDLE, with({"left": true})])
	var glued_walk := x1 - q.x
	sim = floor_sim()
	q = sim.players[1]
	x1 = q.x
	run(sim, 30, [IDLE, with({"left": true})])
	check(glued_walk < (x1 - q.x) * 0.5, "glue slows walking (%.2f vs %.2f)" % [glued_walk, x1 - q.x])

	# Trapdoor: drops away under an enemy, not under its owner.
	sim = floor_sim()
	p = sim.players[0]
	q = sim.players[1]
	var under_p := Vector2i(floori(p.centre().x), 20)
	var under_q := Vector2i(floori(q.centre().x), 20)
	for t: Vector2i in [under_p, under_q]:
		sim.world.set_tile(t.x, t.y, World.TRAPDOOR)
		sim.world.owners[t] = 0
	run(sim, int(Cfg.TRAP_DROP * 60) + 5)
	check(sim.world.get_tile(under_q.x, under_q.y) == World.EMPTY, "a trapdoor drops under an enemy")
	check(sim.world.get_tile(under_p.x, under_p.y) == World.TRAPDOOR, "a trapdoor holds its owner")

	# Healing spring: heals anyone close, until used up.
	sim = floor_sim()
	q = sim.players[1]
	q.damage = 80.0
	var spring := Vector2i(floori(q.centre().x) + 1, 19)
	sim.world.set_tile(spring.x, spring.y, World.HEAL)
	run(sim, 60)
	check(q.damage < 80.0 - Cfg.HEAL_RATE * 0.9, "a healing spring heals (%.1f%% left)" % q.damage)
	run(sim, 60 * 8)
	check(q.damage <= 80.0 - Cfg.HEAL_TOTAL + 0.01 and sim.world.get_tile(spring.x, spring.y) == World.EMPTY,
		"it heals HEAL_TOTAL then is used up (%.1f%%)" % q.damage)

	# Fake block: looks like dirt, but you fall through it.
	sim = floor_sim()
	q = sim.players[1]
	for x in range(36, 45):
		sim.world.set_tile(x, 20, World.FAKE)
	run(sim, 30)
	check(q.y > 20.0, "you fall through a fake block")
	print("items: ore, placing + reach, steel, fan, updraft, magnet, bounce pad, ladder, spikes, bumper, glue, trapdoor, heal, fake, mine, turret OK")


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
	spike.update(Cfg.DT, [with({"mine": true, "down": true, "right": true}), IDLE])
	check(sq.last_hit_by == 0, "a down-right swing hits the player beside you (aim assist)")
	check(sp.mine_progress == 0.0 and spike.world.solid(16, 20), "a down-right swing that hits doesn't mine the floor (%.2f)"
		% sp.mine_progress)

	# A hit at 0% is an arc, not a slide along the floor.
	sim = fight_sim(0.0, 15.1)
	q = sim.players[1]
	var floor_y := q.y
	var peak := q.y
	sim.update(Cfg.DT, [with({"mine": true}), IDLE])
	for i in 30:
		sim.update(Cfg.DT, [IDLE, IDLE])
		peak = minf(peak, q.y)
	check(floor_y - peak > 0.4, "a 0%% hit lifts the victim (%.2f tiles)" % (floor_y - peak))

	# A click at nobody still swings (a visible miss), and doesn't swing again while held.
	sim = floor_sim()
	p = sim.players[0]
	sim.update(Cfg.DT, [with({"mine": true, "down": true}), IDLE])
	check(p.swing_t > 0 and p.swing_cd > 0, "a click at air swings")
	run(sim, 20, [with({"mine": true, "down": true}), IDLE])
	check(p.swing_t == 0.0, "holding at air doesn't keep swinging (it mines)")
	check(p.mine_progress > 0 or sim.world.block_count() < 40, "holding mines the block you aim at")

	# A click just before the cooldown ends still swings when it does (no lost clicks).
	sim = floor_sim()
	p = sim.players[0]
	sim.update(Cfg.DT, [with({"mine": true, "down": true}), IDLE])
	var cd_frames := ceili(Cfg.SWING_COOLDOWN / Cfg.DT)
	run(sim, cd_frames - 4)
	sim.update(Cfg.DT, [with({"mine": true, "down": true}), IDLE])
	check(p.swing_t < Cfg.SWING_SHOW - 0.001, "a click during cooldown doesn't swing yet")
	run(sim, 5)
	check(p.swing_t > 0, "...but swings as soon as the cooldown ends")

	# Hit back: just after a hit there's a short lock, then the victim can swing even mid-flight.
	sim = fight_sim(0.0, 15.1)
	p = sim.players[0]
	q = sim.players[1]
	q.damage = 90.0                              # long stun: well over the attacker's cooldown
	q.facing = -1
	sim.update(Cfg.DT, [with({"mine": true}), IDLE])
	check(q.stun > Cfg.SWING_COOLDOWN, "a 90%% victim is stunned longer than a swing cooldown (%.2f s)" % q.stun)
	sim.update(Cfg.DT, [IDLE, IDLE])
	sim.update(Cfg.DT, [IDLE, with({"mine": true, "left": true})])
	check(q.swing_t == 0.0, "no swing right after being hit (a click during the hit-stop freeze)")
	var back := false
	for i in ceili((Cfg.HIT_LOCK + Cfg.HITSTOP_MAX) / Cfg.DT) + 2:
		sim.update(Cfg.DT, [IDLE, with({"mine": i == 0, "left": true})])
		back = back or q.swing_t > 0
	check(back and q.stun > 0, "the click is kept and swings once the lock ends, while still stunned")

	# Aim assist: a wide cone around the aim, not everywhere, and not past SWING_RADIUS.
	var c := Vector2(10, 10)
	var body := Vector2(Cfg.PLAYER_W, Cfg.PLAYER_H)
	check(GameSim.swing_reaches(c, Vector2(1, 0), c + Vector2(0.6, -0.8)), "aimed right: hits someone right beside you")
	check(GameSim.swing_reaches(c, Vector2(1, -1).normalized(), c + Vector2(0.6, -0.8)), "aimed up-right: still hits them (assist)")
	check(GameSim.swing_reaches(c, Vector2(0, -1), c + Vector2(0.6, -2.0)), "aimed up: hits someone above and a bit to the side")
	check(not GameSim.swing_reaches(c, Vector2(-1, 0), c + Vector2(0.6, -0.8)), "aimed left: misses someone on your right")
	check(not GameSim.swing_reaches(c, Vector2(1, 0), c + Vector2(1.8, -0.8)), "too far: misses")
	check(GameSim.swing_reaches(c, Vector2(-1, 0), c - body / 2.0), "someone overlapping you is always hit")

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
	print("fighting: swing damage/knock/stun/credit, no mine on hit, arc, whiff, hold mines, stunned can't swing, %.1fx farther at 112%% (kvx x%.2f), KO credit, plain fall OK"
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

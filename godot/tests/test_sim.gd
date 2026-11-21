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
	test_wall_jump()
	test_mouse_aim()
	test_crafting()
	test_items()
	test_matches()
	print("all good" if failures == 0 else "%d FAILURES" % failures)
	quit(0 if failures == 0 else 1)


func test_maps() -> void:
	var w := World.new()
	for players in [2, 3, 4]:
		var fair := 0
		var worst := 0.0
		var start := Time.get_ticks_msec()
		for seed_value in range(1, 61):
			w.generate(seed_value, players)
			check(w.spawns.size() == players, "spawn count")
			for k in range(1, w.spawns.size()):
				check(w.spawns[k].x - w.spawns[k - 1].x >= Cfg.COLS / (players + 1), "spawns spread out")
			for s in w.spawns:
				check(w.solid(s.x, s.y) and not w.solid(s.x, s.y - 1) and not w.solid(s.x, s.y - 2), "spawn on ground with headroom")
				for ore in World.ORE_TILES:
					var n := 0
					for y in range(s.y - Cfg.ORE_RADIUS, s.y + Cfg.ORE_RADIUS + 1):
						for x in range(s.x - Cfg.ORE_RADIUS, s.x + Cfg.ORE_RADIUS + 1):
							if w.get_tile(x, y) == World.ORE_TILES[ore]:
								n += 1
					check(n >= Cfg.ORE_MIN[ore], "minimum %s near spawn" % ore)
			if w.spread <= Cfg.FAIR_SPREAD:
				fair += 1
			worst = maxf(worst, w.spread)
		print("maps %dp: %d%% within %d%%, worst %d%%, %d ms per map" % [players, fair * 100 / 60,
			int(Cfg.FAIR_SPREAD * 100), int(worst * 100), (Time.get_ticks_msec() - start) / 60])


class FakeGame:
	var world := World.new()
	var players: Array = []
	func sound(_n, _g := 0.0) -> void: pass
	func burst(_a, _b, _c, _d, _e := 0.0, _f := 0, _g := 0.0) -> void: pass
	func player_in_tile(_x, _y) -> bool: return false
	func menu_hover(_p, _m) -> int: return -1
	func use_item(_p, _k) -> bool: return false


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
	check(start - p.x > 0.5, "wall jump kicks away from the wall")

	p.spawn(0, 0)
	p.x = 30 - Cfg.PLAYER_W
	p.y = 25.0
	var highest := p.y
	for f in 240:
		p.update(Cfg.DT, with({"right": true, "jump": f % 2 == 0}), g)
		highest = minf(highest, p.y)
	check(highest > 25.0 - 4, "a single wall can't be climbed")

	for y in range(5, 34):
		g.world.grid[y * Cfg.COLS + 27] = World.STONE
	p.spawn(0, 0)
	p.x = 30 - Cfg.PLAYER_W
	p.y = 25.0
	highest = p.y
	for f in 240:
		p.update(Cfg.DT, with({("right" if p.facing > 0 else "left"): true, "jump": f % 2 == 0}), g)
		highest = minf(highest, p.y)
	check(highest < 20, "a two-wall chimney can be climbed")
	print("wall jump: slide, kick, no single-wall climb, chimney climb OK (chimney reached row %.1f)" % highest)


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

	sim = floor_sim()
	p = sim.players[0]
	p.inv = {"dirt": 0, "stone": 3, "copper": 2, "crystal": 0}
	p.recipe = 0
	var start := p.x
	var hold := with({"craft": true})
	var seq := [hold]
	for i in Items.RECIPES.find("boost"):
		seq.append(with({"craft": true, "right": true}))
		seq.append(hold)
	seq.append(IDLE)
	for inp in seq:
		sim.update(Cfg.DT, [inp, IDLE])
	check(p.slots[0] != null and p.slots[0]["item"] == "boost", "hold, pick, release crafts boost")
	check(absf(p.x - start) < 0.01, "left/right steer the menu, not the player")
	sim.update(Cfg.DT, [with({"item1": true}), IDLE])
	check(p.vy < -10 and p.slots[0]["charges"] == 2, "Q uses slot 1")

	sim = floor_sim()
	p = sim.players[0]
	p.inv["dirt"] = 5
	var r: Rect2 = GameSim.menu_layout(p)[1][Items.RECIPES.find("push")]
	var mouse := Vector2(r.get_center().x / Cfg.CELL, (r.get_center().y - Cfg.HUD_H) / Cfg.CELL)
	p.recipe = 3
	sim.update(Cfg.DT, [with({"craft": true, "mouse": mouse}), IDLE])
	sim.update(Cfg.DT, [with({"mouse": mouse}), IDLE])
	check(p.slots[0] != null and p.slots[0]["item"] == "push", "mouse hover + release crafts")
	print("crafting: costs, stacking, replacement, keys, mouse OK")


func test_items() -> void:
	var sim := floor_sim()
	var p: Player = sim.players[0]
	sim.world.grid[19 * Cfg.COLS + 16] = World.COPPER
	for i in 40:
		sim.update(Cfg.DT, [with({"mine": true}), IDLE])
	check(p.inv["copper"] == 1, "mining ore (two hits) gives copper")

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


func test_matches() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	for count in [2, 3, 4]:
		var sim := GameSim.new()
		sim.start_match(count)
		var held := []
		for i in count:
			held.append(IDLE.duplicate())
		var frames := 0
		var rounds := {}
		while sim.state != "match_over" and frames < 60 * 60 * 15:
			for h in held:
				for k in h:
					if rng.randf() < 0.08:
						h[k] = not h[k]
			sim.update(Cfg.DT, held.map(func(h): return h.duplicate()))
			sim.events.clear()
			rounds[sim.round_no] = true
			frames += 1
		check(sim.state == "match_over", "%dp match finishes" % count)
		print("match %dp: over after %d rounds, %ds -> %s" % [count, rounds.size(), frames / 60, sim.message])

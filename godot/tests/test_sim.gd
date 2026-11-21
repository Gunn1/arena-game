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
	test_fighting()
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
		print("maps %dp: %d wide, %d%% within %d%%, worst %d%%, %d ms per map" % [players, width, fair * 100 / 60,
			int(Cfg.FAIR_SPREAD * 100), int(worst * 100), (Time.get_ticks_msec() - start) / 60])


class FakeGame:
	var world := World.new()
	var players: Array = []
	func sound(_n, _g := 0.0) -> void: pass
	func burst(_a, _b, _c, _d, _e := 0.0, _f := 0, _g := 0.0) -> void: pass
	func player_in_tile(_x, _y) -> bool: return false
	func menu_hover(_p, _m) -> int: return -1
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
	check(sim.world.block_count() == blocks_before and sim.world.cracked.is_empty() and p.mine_cd > Cfg.MINE_COOLDOWN,
		"a swing that hits doesn't also mine")
	var near_kvx := q.kvx
	run(sim, 90)
	var near := q.x - x0

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
			sim.update(Cfg.DT, held.map(func(h): return h.duplicate()))
			sim.events.clear()
			rounds[sim.round_no] = true
			frames += 1
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

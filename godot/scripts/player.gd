## One player: movement, wall jumps, mining, placing, crafting and item slots.
## Inputs come in as a Dictionary: left right up down jump mine place item1 item2 item3 craft,
## plus optional "mouse" (Vector2, in tiles) and "stick_aim" (Vector2).
class_name Player
extends RefCounted

# Aim angle -> 8 directions, 45 degrees apart, starting at "right" (y points down).
const OCTANTS := [Vector2i(1, 0), Vector2i(1, 1), Vector2i(0, 1), Vector2i(-1, 1),
	Vector2i(-1, 0), Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1)]
const W := Cfg.PLAYER_W
const H := Cfg.PLAYER_H

var index := 0
var color := Color.WHITE
var wins := 0
var x := 0.0                      # top-left corner, in tiles
var y := 0.0
var vy := 0.0
var walk_v := 0.0                 # sideways speed from walking (accelerates toward the input)
var kvx := 0.0                    # sideways speed from knockback, wall kicks and the grapple
var vel_x := 0.0                  # walk_v + kvx, for visuals and snapshots
var on_ground := false
var land_t := 0.0                 # > 0 after a hard landing (squash)
var coyote := 0.0
var jump_buffer := 0.0            # > 0: jump was pressed recently and still wants to happen
var jump_cut_ready := false       # letting go of jump now cuts the jump short (once per jump)
var wall_coyote := 0.0
var wall_dir := 0                 # -1 wall on the left, 1 on the right
var last_wall := 0                # side of the last wall jump; can't repeat it until landing
var wall_lock := 0.0
var facing := 1
var aim := Vector2i(1, 0)
var inv := {}
var slots: Array = []             # null or {"item": key, "charges": n}
var craft_t := 0.0                # > 0 while the "+Item" popup shows
var last_crafted := ""            # item key of the last craft, for that popup
var grapple = null                # Vector3(x, y, time left) while being pulled
var mouse = null                  # Vector2 in tiles, or null (keyboard / controller)
var mine_target := Vector2i(-1, -1)
var mine_progress := 0.0          # 0..1 of breaking mine_target
var place_cd := 0.0
var item_cd := 0.0
var held := {}                    # last frame's input, for "just pressed"
var smooth := Vector2.ZERO        # online client, own player: drawn offset after a correction (eases to 0)
var alive := true
# Fighting
var damage := 0.0                 # Smash-style %: more damage = hits launch you farther
var stun := 0.0                   # can't walk while > 0 (you're flying from a hit)
var swing_cd := 0.0
var swing_t := 0.0                # > 0 while the swing is drawn
var hurt_t := 0.0                 # > 0 while the hit flash is drawn
var last_hit_by := -1             # player index, for KO credit
var last_hit_at := -100.0         # round time of that hit
# Match stats (kept across rounds)
var kos := 0
var falls := 0
var dealt := 0.0


func _init(i: int) -> void:
	index = i
	color = Cfg.PLAYER_COLORS[i]
	spawn(0, 0)


func spawn(col: int, ground_row: int) -> void:
	x = col + 0.5 - W / 2.0
	y = ground_row - H
	vy = 0.0
	walk_v = 0.0
	kvx = 0.0
	vel_x = 0.0
	on_ground = false
	land_t = 0.0
	coyote = 0.0
	jump_buffer = 0.0
	jump_cut_ready = false
	wall_coyote = 0.0
	wall_dir = 0
	last_wall = 0
	wall_lock = 0.0
	facing = 1 if col < Cfg.COLS / 2 else -1
	aim = Vector2i(facing, 0)
	inv = {"dirt": 0, "stone": 0, "copper": 0, "crystal": 0}
	slots = []
	for i in Cfg.SLOTS:
		slots.append(null)
	craft_t = 0.0
	last_crafted = ""
	grapple = null
	mouse = null
	mine_target = Vector2i(-1, -1)
	mine_progress = 0.0
	place_cd = 0.0
	item_cd = 0.0
	held = {}
	alive = true
	damage = 0.0
	stun = 0.0
	swing_cd = 0.0
	swing_t = 0.0
	hurt_t = 0.0
	last_hit_by = -1
	last_hit_at = -100.0


func pressed(inp: Dictionary, action: String) -> bool:
	return inp.get(action, false) and not held.get(action, false)


# --- inventory and crafting ----------------------------------------------------------

func blocks() -> int:
	return inp_count("dirt") + inp_count("stone")


func inp_count(m: String) -> int:
	return int(inv.get(m, 0))


func collect(tile: int) -> void:
	var m: String = World.DROPS.get(tile, "")
	if m == "dirt" or m == "stone":
		if blocks() < Cfg.CARRY_LIMIT:
			inv[m] += 1
	elif m != "":
		inv[m] = mini(Cfg.ORE_LIMIT, inv[m] + 1)


func can_afford(key: String) -> bool:
	return Items.can_afford(key, inv)


## Pay and put the item in a slot: stacks onto the same item, else the first empty slot,
## else replaces the slot with the fewest charges.
func craft(key: String) -> bool:
	if not can_afford(key):
		return false
	var cost: Dictionary = Items.ITEMS[key]["cost"]
	for m in cost:
		inv[m] -= cost[m]
	var charges: int = Items.ITEMS[key]["charges"]
	for s in slots:
		if s != null and s["item"] == key:
			s["charges"] += charges
			return true
	var target := slots.find(null)
	if target == -1:
		target = 0
		for i in slots.size():
			if slots[i]["charges"] < slots[target]["charges"]:
				target = i
	slots[target] = {"item": key, "charges": charges}
	return true


# --- geometry ------------------------------------------------------------------------

func tiles() -> Array:
	var out := []
	for tx in range(floori(x), floori(x + W - 1e-6) + 1):
		for ty in range(floori(y), floori(y + H - 1e-6) + 1):
			out.append(Vector2i(tx, ty))
	return out


func overlaps_tile(tx: int, ty: int) -> bool:
	return x < tx + 1 and x + W > tx and y < ty + 1 and y + H > ty


func centre() -> Vector2:
	return Vector2(x + W / 2.0, y + H / 2.0)


func wall_side(world: World) -> int:
	var top := floori(y + 0.1)
	var bottom := floori(y + H - 0.1)
	for ty in range(top, bottom + 1):
		if world.solid(floori(x - 0.05), ty):
			return -1
	for ty in range(top, bottom + 1):
		if world.solid(floori(x + W + 0.05), ty):
			return 1
	return 0


## The tile being aimed at. With a mouse: the tile under it if within REACH, else the best
## tile along the line toward it. Otherwise: beside, above, below, or diagonal from the player.
func target(world: World, placing: bool) -> Vector2i:
	if mouse != null:
		return _mouse_target(world, placing)
	var col := floori(x + W / 2.0)
	var feet := floori(y + H - 0.01)
	var head := floori(y + 0.01)
	if aim.x == 0:
		return Vector2i(col, feet + 1) if aim.y > 0 else Vector2i(col, head - 1)
	# First column past our right/left edge, whether or not we're touching it.
	var side := floori(x + W - 1e-6) + 1 if aim.x > 0 else floori(x + 1e-6) - 1
	if aim.y > 0:
		return Vector2i(side, feet + 1)
	if aim.y < 0:
		return Vector2i(side, head - 1)
	if placing or world.solid(side, feet):
		return Vector2i(side, feet)
	return Vector2i(side, head)


func _mouse_target(world: World, placing: bool) -> Vector2i:
	var m: Vector2 = mouse
	var c := centre()
	var t := Vector2i(floori(m.x), floori(m.y))
	if (Vector2(t) + Vector2(0.5, 0.5)).distance_to(c) <= Cfg.REACH:
		return t
	# Out of reach: walk from the centre toward the mouse. Mining takes the first block on the
	# way; placing takes the last empty tile before a block (or the reach limit).
	var u := (m - c).normalized()
	var best := Vector2i(floori(c.x), floori(c.y))
	for i in int(Cfg.REACH / 0.25) + 1:
		var pt := c + u * (i * 0.25)
		var tt := Vector2i(floori(pt.x), floori(pt.y))
		if (Vector2(tt) + Vector2(0.5, 0.5)).distance_to(c) > Cfg.REACH:
			continue
		if world.solid(tt.x, tt.y):
			if not placing:
				return tt
			break
		best = tt
	return best


# --- per frame -----------------------------------------------------------------------

func update(dt: float, inp: Dictionary, game) -> void:
	_step_body(dt, inp, game)
	_use_hands(dt, inp, game)
	held = inp.duplicate()

	# Falling out the bottom or off either side is death.
	if y > Cfg.ROWS + 1 or x + W < -0.5 or x > Cfg.COLS + 0.5:
		alive = false


## Online client: just the movement half of update(), to predict your own player between snapshots.
## No mining, placing, items or swings (the host decides those) and no death check.
func predict_step(dt: float, inp: Dictionary, game) -> void:
	_step_body(dt, inp, game)
	held = inp.duplicate()


## Everything movement needs to replay inputs exactly from this point.
func net_state() -> Array:
	return [x, y, vy, kvx, walk_v, on_ground, coyote, wall_coyote, wall_dir, last_wall, wall_lock,
		jump_buffer, jump_cut_ready, stun, grapple, facing, aim, land_t, bool(held.get("jump", false))]


func set_net_state(a: Array) -> void:
	x = float(a[0]); y = float(a[1]); vy = float(a[2]); kvx = float(a[3]); walk_v = float(a[4])
	on_ground = bool(a[5]); coyote = float(a[6]); wall_coyote = float(a[7]); wall_dir = int(a[8])
	last_wall = int(a[9]); wall_lock = float(a[10]); jump_buffer = float(a[11]); jump_cut_ready = bool(a[12])
	stun = float(a[13]); grapple = a[14]; facing = int(a[15]); aim = a[16]; land_t = float(a[17])
	held = {"jump": bool(a[18])}
	vel_x = walk_v + kvx


## Timers, aim and facing, then the body moves.
func _step_body(dt: float, inp: Dictionary, game) -> void:
	place_cd = maxf(0.0, place_cd - dt)
	item_cd = maxf(0.0, item_cd - dt)
	swing_cd = maxf(0.0, swing_cd - dt)
	swing_t = maxf(0.0, swing_t - dt)
	hurt_t = maxf(0.0, hurt_t - dt)
	craft_t = maxf(0.0, craft_t - dt)
	land_t = maxf(0.0, land_t - dt)

	mouse = inp.get("mouse")
	var dx := int(inp.get("right", false)) - int(inp.get("left", false))
	var dy := int(inp.get("down", false)) - int(inp.get("up", false))
	if dx:
		facing = dx
	aim = Vector2i(dx, dy) if (dx or dy) else Vector2i(facing, 0)

	# Mouse or right stick: aim at it, snapped to 8 directions.
	var pointer = null
	if mouse != null:
		pointer = mouse - centre()
	elif inp.get("stick_aim") != null:
		pointer = inp["stick_aim"]
	if pointer != null and pointer.length() > (0.6 if mouse != null else 0.5):
		aim = OCTANTS[posmod(roundi(atan2(pointer.y, pointer.x) / (PI / 4.0)), 8)]
		if aim.x:
			facing = aim.x                       # face where you aim, even walking backwards

	_move_body(dt, dx, inp, game)
	vel_x = walk_v + kvx


func _move_body(dt: float, dx: int, inp: Dictionary, game) -> void:
	var world: World = game.world
	stun = maxf(0.0, stun - dt)
	kvx *= exp(-(Cfg.STUN_DECAY if stun > 0 else Cfg.KNOCK_DECAY) * dt)
	if absf(kvx) < 0.1:
		kvx = 0.0
	coyote = Cfg.COYOTE if on_ground else maxf(0.0, coyote - dt)
	wall_lock = maxf(0.0, wall_lock - dt)
	jump_buffer = maxf(0.0, jump_buffer - dt)
	if pressed(inp, "jump"):
		jump_buffer = Cfg.JUMP_BUFFER
	if on_ground:
		last_wall = 0

	if grapple != null and _pull(dt, world):
		return
	vy = minf(vy + Cfg.GRAVITY * (Cfg.FALL_GRAVITY if vy > 0 else 1.0) * dt, Cfg.MAX_FALL)

	# Wall slide: holding into a wall while falling slows the fall.
	var wall := 0 if on_ground else wall_side(world)
	if wall:
		wall_coyote = Cfg.WALL_COYOTE
		wall_dir = wall
		if dx == wall and vy > Cfg.WALL_SLIDE_SPEED:
			vy = Cfg.WALL_SLIDE_SPEED
	else:
		wall_coyote = maxf(0.0, wall_coyote - dt)

	if jump_buffer > 0:
		if on_ground or coyote > 0:
			vy = -Cfg.JUMP_SPEED
			coyote = 0.0
			jump_buffer = 0.0
			jump_cut_ready = true
			game.sound("jump")
		elif wall_coyote > 0 and wall_dir != last_wall:
			# Wall jump: up, and kicked away from the wall.
			vy = -Cfg.WALL_JUMP_SPEED
			kvx = -wall_dir * Cfg.WALL_KICK
			facing = -wall_dir
			wall_coyote = 0.0
			last_wall = wall_dir
			wall_lock = Cfg.WALL_LOCK
			jump_buffer = 0.0
			jump_cut_ready = true
			game.sound("jump")
			var side_x := x if wall_dir < 0 else x + W
			game.burst(Vector2(side_x, y + H * 0.7), Color(0.78, 0.78, 0.86), 8, 4.0, 0.3, 3)

	# Variable jump height: letting go while still rising cuts the jump short.
	if vy >= 0:
		jump_cut_ready = false
	elif jump_cut_ready and not inp.get("jump", false):
		vy *= Cfg.JUMP_CUT
		jump_cut_ready = false

	# Walking speed eases toward the input instead of snapping to it.
	if wall_lock > 0 or stun > 0:
		walk_v = move_toward(walk_v, 0.0, Cfg.ACCEL_AIR * 0.5 * dt)
	elif dx != 0:
		walk_v = move_toward(walk_v, dx * Cfg.MOVE_SPEED, (Cfg.ACCEL_GROUND if on_ground else Cfg.ACCEL_AIR) * dt)
	else:
		walk_v = move_toward(walk_v, 0.0, (Cfg.FRICTION if on_ground else Cfg.ACCEL_AIR * 0.5) * dt)

	move(world, (walk_v + kvx) * dt, 0.0)
	on_ground = false
	var fall_speed := vy
	move(world, 0.0, vy * dt)
	if on_ground and fall_speed > Cfg.LAND_SPEED:
		land_t = 0.12
		game.sound("land")


## Grapple: fly straight at the hook point. Returns true while still being pulled.
func _pull(dt: float, world: World) -> bool:
	var hook := Vector2(grapple.x, grapple.y)
	var c := centre()
	var dist := c.distance_to(hook)
	var hooked := world.solid(floori(hook.x), floori(hook.y))
	if dist < 1.0 or grapple.z <= 0 or not hooked:
		grapple = null
		kvx *= 0.4
		vy = minf(vy, -4.0)                       # a little hop at the end
		return false
	grapple = Vector3(hook.x, hook.y, grapple.z - dt)
	walk_v = 0.0
	jump_cut_ready = false
	var u := (hook - c) / dist
	kvx = u.x * Cfg.GRAPPLE_SPEED
	vy = u.y * Cfg.GRAPPLE_SPEED
	var before := Vector2(x, y)
	move(world, kvx * dt, 0.0)
	on_ground = false
	move(world, 0.0, vy * dt)
	if Vector2(x, y).distance_to(before) < 0.01:
		grapple = null                            # stuck on something: let go
	return true


func _use_hands(dt: float, inp: Dictionary, game) -> void:
	var world: World = game.world
	# Quick craft: one press makes the most valuable item you can afford.
	if pressed(inp, "craft"):
		var key := Items.best_affordable(inv)
		if key != "":
			craft(key)
			last_crafted = key
			craft_t = 0.8
			game.sound("craft")
		else:
			game.sound("nope")

	# Items: each slot has its own button.
	for i in Cfg.SLOTS:
		var slot = slots[i]
		if pressed(inp, "item%d" % (i + 1)) and slot != null and item_cd == 0.0 and game.use_item(self, slot["item"]):
			item_cd = Items.ITEMS[slot["item"]]["cooldown"]
			slot["charges"] -= 1
			if slot["charges"] <= 0:
				slots[i] = null

	# One button: swing at a player in front of you, or hold to mine the block you're aiming at.
	if inp.get("mine", false):
		var swung := false
		if swing_cd == 0.0:
			var victims: Array = game.swing_targets(self)
			if victims:
				game.melee(self, victims)
				swing_cd = Cfg.SWING_COOLDOWN
				swung = true
		if not swung:
			_mine(dt, world, game)
	else:
		_stop_mining()
	if inp.get("place", false) and place_cd == 0.0 and blocks() > 0:
		var t := target(world, true)
		if world.in_bounds(t.x, t.y) and not world.solid(t.x, t.y) and not game.player_in_tile(t.x, t.y):
			world.set_tile(t.x, t.y, World.PLACED)
			inv["dirt" if inv["dirt"] > 0 else "stone"] -= 1
			place_cd = Cfg.PLACE_COOLDOWN
			game.sound("place")


func _mine(dt: float, world: World, game) -> void:
	var t := target(world, false)
	var tile := world.get_tile(t.x, t.y)
	if tile == World.EMPTY:
		_stop_mining()
		return
	if t != mine_target:
		mine_target = t
		mine_progress = 0.0
	var time: float = Cfg.MINE_TIME.get(tile, 0.3)
	mine_progress += dt / time
	game.sound("mine_tick", 0.11)
	if mine_progress >= 1.0:
		var broke := world.break_tile(t.x, t.y)
		if broke != -1:
			collect(broke)
			game.sound("mine")
		_stop_mining()


func _stop_mining() -> void:
	mine_target = Vector2i(-1, -1)
	mine_progress = 0.0


## Move along one axis, then push back out of any block we ran into.
func move(world: World, mx: float, my: float) -> void:
	x += mx
	y += my
	var hits := []
	for t in tiles():
		if world.solid(t.x, t.y):
			hits.append(t)
	if hits.is_empty():
		return
	if mx > 0:
		x = hits.map(func(t): return t.x).min() - W
	elif mx < 0:
		x = hits.map(func(t): return t.x).max() + 1
	if mx != 0:
		kvx = 0.0
		walk_v = 0.0
	if my > 0:
		y = hits.map(func(t): return t.y).min() - H
		vy = 0.0
		on_ground = true
	elif my < 0:
		y = hits.map(func(t): return t.y).max() + 1
		vy = 0.0

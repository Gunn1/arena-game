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
var kvx := 0.0                    # sideways speed from knockback, wall kicks and fans
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
var aim_vec := Vector2(1, 0)      # unit aim, not snapped (mouse / stick, else aim): the swing goes this way
var inv := {}
var slots: Array = []             # null or {"item": key, "charges": n}
var craft_t := 0.0                # > 0 while the "+Item" popup shows
var crafting := false             # crafting menu open (craft held longer than MENU_DELAY)
var craft_hold := 0.0             # how long craft has been held
var recipe := 0                   # index into Items.RECIPES picked in the menu
var craft_released := false       # this frame craft was let go...
var menu_was_open := false        # ...and whether the menu was open (else it was a tap: quick craft)
var last_crafted := ""            # item key of the last craft, for that popup
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
var swing_dir := Vector2(1, 0)    # which way the last swing went (toward who it hit), for drawing
var swing_buffer := 0.0           # > 0: a click is waiting to swing
var hit_lock := 0.0               # > 0: just got hit, can't swing yet
var hurt_t := 0.0                 # > 0 while the hit flash is drawn
var last_hit_by := -1             # player index, for KO credit
var last_hit_at := -100.0         # round time of that hit
var lava_cd := 0.0                # > 0: lava or spikes already hurt you just now
var bumped := false               # this frame's move ran into a bumper (for its sound)
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
	aim_vec = Vector2(aim)
	inv = {"dirt": 0, "stone": 0, "copper": 0, "crystal": 0}
	slots = []
	for i in Cfg.SLOTS:
		slots.append(null)
	craft_t = 0.0
	last_crafted = ""
	crafting = false
	craft_hold = 0.0
	craft_released = false
	menu_was_open = false
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
	swing_buffer = 0.0
	hit_lock = 0.0
	hurt_t = 0.0
	last_hit_by = -1
	last_hit_at = -100.0
	lava_cd = 0.0


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


## A wall beside the top half of the body: -1 left, 1 right, 0 none. A ledge lip at your feet
## doesn't count, so jumping past one doesn't turn the next jump into a wall jump.
func wall_side(world: World) -> int:
	var top := floori(y + 0.1)
	var bottom := floori(y + H * 0.5)
	for ty in range(top, bottom + 1):
		if world.solid(floori(x - 0.05), ty):
			return -1
	for ty in range(top, bottom + 1):
		if world.solid(floori(x + W + 0.05), ty):
			return 1
	return 0


## Falling with ground just below: a jump press should wait for the landing, not wall jump.
func _ground_below(world: World) -> bool:
	if vy < 0:
		return false
	for ty in range(floori(y + H + 0.01), floori(y + H + Cfg.WALL_GROUND_GAP) + 1):
		for tx in range(floori(x), floori(x + W - 1e-6) + 1):
			if world.solid(tx, ty):
				return true
	return false


## Fans and magnets nearby push and pull (everyone, including whoever placed them).
## Part of movement, so an online client predicts it exactly like the host.
func _fields(dt: float, world: World) -> void:
	if world.devices.is_empty():
		return
	var c := centre()
	for pos: Vector2i in world.devices:
		var tile: int = world.devices[pos]
		if tile == World.FAN_L or tile == World.FAN_R:
			var dir := -1 if tile == World.FAN_L else 1
			if not (y < pos.y + 1 and y + H > pos.y):
				continue                             # not in the fan's row
			var off := c.x - (pos.x + 0.5)
			if off * dir <= 0 or absf(off) > Cfg.FAN_RANGE:
				continue
			var blocked := false
			for tx in range(pos.x + dir, floori(c.x), dir):
				if world.solid(tx, pos.y):
					blocked = true
					break
			if blocked:
				continue
			var goal := dir * Cfg.FAN_SPEED * (1.0 - absf(off) / (Cfg.FAN_RANGE + 1.0))
			if (goal - kvx) * dir > 0:
				kvx = move_toward(kvx, goal, Cfg.FAN_ACCEL * dt)
		elif tile == World.FAN_U:
			if not (x < pos.x + 1 and x + W > pos.x):
				continue                             # not in the fan's column
			var up := (pos.y + 0.5) - c.y
			if up <= 0 or up > Cfg.FAN_RANGE:
				continue
			var clear := true
			for ty in range(pos.y - 1, floori(y + H - 0.01), -1):
				if world.solid(pos.x, ty):
					clear = false
					break
			if not clear:
				continue
			var lift := -Cfg.UPDRAFT_SPEED * (1.0 - up / (Cfg.FAN_RANGE + 1.0))
			if vy > lift:
				vy = move_toward(vy, lift, Cfg.UPDRAFT_ACCEL * dt)
		elif tile == World.MAGNET:
			var to := Vector2(pos) + Vector2(0.5, 0.5) - c
			var d := to.length()
			if d < 0.8 or d > Cfg.MAGNET_RANGE:
				continue
			var a := Cfg.MAGNET_PULL * (1.0 - d / Cfg.MAGNET_RANGE)
			kvx += to.x / d * a * dt
			vy += to.y / d * a * dt


## The tile being aimed at. With a mouse: the tile under it if within REACH, else the best
## tile along the line toward it. Otherwise: beside, above, below, or diagonal from the player.
func target(world: World, placing: bool, reach := Cfg.REACH) -> Vector2i:
	if mouse != null:
		return _mouse_target(world, placing, reach)
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


func _mouse_target(world: World, placing: bool, reach: float) -> Vector2i:
	var m: Vector2 = mouse
	var c := centre()
	var t := Vector2i(floori(m.x), floori(m.y))
	if (Vector2(t) + Vector2(0.5, 0.5)).distance_to(c) <= reach:
		return t
	# Out of reach: walk from the centre toward the mouse. Mining takes the first block on the
	# way; placing takes the last empty tile before a block (or the reach limit).
	var u := (m - c).normalized()
	var best := Vector2i(floori(c.x), floori(c.y))
	for i in int(reach / 0.25) + 1:
		var pt := c + u * (i * 0.25)
		var tt := Vector2i(floori(pt.x), floori(pt.y))
		if (Vector2(tt) + Vector2(0.5, 0.5)).distance_to(c) > reach:
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
		jump_buffer, jump_cut_ready, stun, facing, aim, land_t, bool(held.get("jump", false)), lava_cd,
		crafting, craft_hold, recipe, bool(held.get("craft", false))]


func set_net_state(a: Array) -> void:
	x = float(a[0]); y = float(a[1]); vy = float(a[2]); kvx = float(a[3]); walk_v = float(a[4])
	on_ground = bool(a[5]); coyote = float(a[6]); wall_coyote = float(a[7]); wall_dir = int(a[8])
	last_wall = int(a[9]); wall_lock = float(a[10]); jump_buffer = float(a[11]); jump_cut_ready = bool(a[12])
	stun = float(a[13]); facing = int(a[14]); aim = a[15]; land_t = float(a[16])
	held = {"jump": bool(a[17]), "craft": bool(a[22])}
	lava_cd = float(a[18])
	crafting = bool(a[19]); craft_hold = float(a[20]); recipe = int(a[21])
	vel_x = walk_v + kvx


## Timers, aim and facing, then the body moves.
func _step_body(dt: float, inp: Dictionary, game) -> void:
	place_cd = maxf(0.0, place_cd - dt)
	item_cd = maxf(0.0, item_cd - dt)
	swing_cd = maxf(0.0, swing_cd - dt)
	hit_lock = maxf(0.0, hit_lock - dt)
	swing_t = maxf(0.0, swing_t - dt)
	hurt_t = maxf(0.0, hurt_t - dt)
	craft_t = maxf(0.0, craft_t - dt)
	land_t = maxf(0.0, land_t - dt)

	mouse = inp.get("mouse")
	_menu(dt, inp)
	# With the menu open and no mouse, left/right pick a recipe instead of walking.
	var dx := 0 if crafting and mouse == null else int(inp.get("right", false)) - int(inp.get("left", false))
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
	aim_vec = Vector2(aim).normalized()
	if pointer != null and pointer.length() > (0.6 if mouse != null else 0.5):
		aim = OCTANTS[posmod(roundi(atan2(pointer.y, pointer.x) / (PI / 4.0)), 8)]
		aim_vec = (pointer as Vector2).normalized()
		if aim.x:
			facing = aim.x                       # face where you aim, even walking backwards

	_move_body(dt, dx, inp, game)
	vel_x = walk_v + kvx


## Crafting menu: hold craft to open it (after MENU_DELAY), pick with the mouse, the wheel, or
## left/right; letting go crafts the pick. A quick tap sets craft_released without the menu.
func _menu(dt: float, inp: Dictionary) -> void:
	craft_released = false
	var n := Items.RECIPES.size()
	if inp.get("craft", false):
		craft_hold += dt
		if not crafting and craft_hold >= Cfg.MENU_DELAY:
			crafting = true
			var best := Items.best_affordable(inv)
			if best != "":
				recipe = Items.RECIPES.find(best)
		if crafting:
			var wheel := int(inp.get("wheel", 0))
			if wheel:
				recipe = posmod(recipe + signi(wheel), n)
			if mouse != null:
				var hover := GameSim.menu_hover(self, mouse)
				if hover != -1:
					recipe = hover
			else:
				if pressed(inp, "right"):
					recipe = posmod(recipe + 1, n)
				if pressed(inp, "left"):
					recipe = posmod(recipe - 1, n)
	else:
		if held.get("craft", false):
			craft_released = true
			menu_was_open = crafting
		crafting = false
		craft_hold = 0.0


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
	lava_cd = maxf(0.0, lava_cd - dt)
	if lava_cd == 0.0 and touching(world, World.LAVA):
		_burn(game)

	var spike := _touching_edge(world, World.SPIKES)
	if lava_cd == 0.0 and spike.x != -1:
		_spiked(game, spike)

	var climbing := stun == 0.0 and touching(world, World.LADDER)
	if climbing:
		# Ladder: up (or jump) climbs, down slides, nothing holds on. Jumping off is walking off.
		var up: bool = inp.get("up", false) or inp.get("jump", false)
		vy = -Cfg.CLIMB_SPEED if up else (Cfg.CLIMB_SPEED if inp.get("down", false) else 0.0)
		jump_buffer = 0.0
		jump_cut_ready = false
		coyote = Cfg.COYOTE                          # step off the top and you can still jump
	else:
		vy = minf(vy + Cfg.GRAVITY * (Cfg.FALL_GRAVITY if vy > 0 else 1.0) * dt, Cfg.MAX_FALL)
	_fields(dt, world)
	var glued := on_ground and _standing_on(world, World.GLUE)

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
			vy = -Cfg.JUMP_SPEED * (Cfg.GLUE_JUMP if glued else 1.0)
			coyote = 0.0
			jump_buffer = 0.0
			jump_cut_ready = true
			game.sound("jump")
		elif wall_coyote > 0 and wall_dir != last_wall and not _ground_below(world):
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

	# Walking speed eases toward the input instead of snapping to it (slowly both ways on ice).
	var grip := _grip(world) if on_ground else 1.0
	if stun > 0:
		# Flying from a hit: a little steering, so a launch isn't a total loss of control.
		walk_v = move_toward(walk_v, dx * Cfg.MOVE_SPEED * 0.5, Cfg.ACCEL_AIR * Cfg.STUN_DRIFT * dt)
	elif wall_lock > 0 and dx == last_wall:   # just after a wall jump you can't walk back into it
		walk_v = move_toward(walk_v, 0.0, Cfg.ACCEL_AIR * 0.5 * dt)
	elif dx != 0:
		var speed := Cfg.MOVE_SPEED * (Cfg.GLUE_SLOW if glued else 1.0)
		walk_v = move_toward(walk_v, dx * speed, (Cfg.ACCEL_GROUND * grip if on_ground else Cfg.ACCEL_AIR) * dt)
	else:
		walk_v = move_toward(walk_v, 0.0, (Cfg.FRICTION * grip if on_ground else Cfg.ACCEL_AIR * 0.5) * dt)

	bumped = false
	move(world, (walk_v + kvx) * dt, 0.0)
	on_ground = false
	var fall_speed := vy
	move(world, 0.0, vy * dt)
	if bumped:
		game.sound("push")
		game.burst(centre(), Items.block_color(World.BUMPER), 10, 6.0, 0.3, 4)
	if on_ground and fall_speed > Cfg.LAND_SPEED:
		land_t = 0.12
		game.sound("land")
	elif fall_speed > 0 and vy <= -Cfg.BOUNCE_LAUNCH:
		game.sound("boost")                          # launched by a bounce pad
		game.burst(Vector2(x + W / 2.0, y + H), Items.block_color(World.BOUNCE), 10, 6.0, 0.4, 4)
	elif fall_speed > 0 and vy < 0:
		game.sound("jump")                           # bounced off slime


## Friction under your feet: ICE_GRIP if you stand only on ice, else 1.
func _grip(world: World) -> float:
	var row := floori(y + H + 0.05)
	var icy := false
	for tx in range(floori(x), floori(x + W - 1e-6) + 1):
		var t := world.get_tile(tx, row)
		if t == World.ICE:
			icy = true
		elif world.solid(tx, row):
			return 1.0
	return Cfg.ICE_GRIP if icy else 1.0


func touching(world: World, tile: int) -> bool:
	for t: Vector2i in tiles():
		if world.get_tile(t.x, t.y) == tile:
			return true
	return false


## Lava: thrown straight up and burned.
func _burn(game) -> void:
	_hurt(game, null, Cfg.LAVA_DAMAGE, Vector2(0, -Cfg.LAVA_LAUNCH))
	game.burst(Vector2(x + W / 2.0, y + H), Color(1.0, 0.5, 0.12), 14, 7.0, 0.5, 4, 5.0)


## Spikes: thrown up and away from the spike, hurt, credited to whoever placed it.
func _spiked(game, at: Vector2i) -> void:
	var away := 1.0 if centre().x >= at.x + 0.5 else -1.0
	var by = null
	var owner: int = game.world.owners.get(at, -1)
	if owner >= 0 and "players" in game and owner < game.players.size():
		by = game.players[owner]
	_hurt(game, by, Cfg.SPIKE_DAMAGE, Vector2(away * 0.6, -0.8) * Cfg.SPIKE_LAUNCH)
	game.burst(centre(), Color(0.85, 0.85, 0.9), 10, 6.0, 0.3, 3)


## Damage plus a fixed launch (no knockback growth). The launch is movement, so online prediction
## matches; the damage goes through GameSim.hit_player when there is one.
func _hurt(game, by, dmg: float, launch: Vector2) -> void:
	lava_cd = Cfg.LAVA_COOLDOWN
	if game.has_method("hit_player"):
		game.hit_player(self, by, Vector2(0, -1), dmg, 0.0)
	else:
		# What hit_player does with no knockback, so a predicting client moves the same way.
		damage = minf(Cfg.MAX_DAMAGE, damage + dmg)
		stun = Cfg.STUN_BASE
		hurt_t = 0.15
	kvx = launch.x
	vy = launch.y
	on_ground = false
	jump_cut_ready = false


## A tile of this type touching the body (or just beside it), or (-1, -1).
func _touching_edge(world: World, tile: int) -> Vector2i:
	for ty in range(floori(y - 0.05), floori(y + H + 0.05) + 1):
		for tx in range(floori(x - 0.05), floori(x + W + 0.05) + 1):
			if world.get_tile(tx, ty) == tile:
				return Vector2i(tx, ty)
	return Vector2i(-1, -1)


## Standing on at least one tile of this type.
func _standing_on(world: World, tile: int) -> bool:
	var row := floori(y + H + 0.05)
	for tx in range(floori(x), floori(x + W - 1e-6) + 1):
		if world.get_tile(tx, row) == tile:
			return true
	return false


func _use_hands(dt: float, inp: Dictionary, game) -> void:
	var world: World = game.world
	# Letting go of craft: the menu's pick, or after a quick tap the most valuable you can afford.
	if craft_released:
		var key: String = Items.RECIPES[recipe] if menu_was_open else Items.best_affordable(inv)
		if key != "" and can_afford(key):
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
			item_cd = Cfg.BLOCK_COOLDOWN
			slot["charges"] -= 1
			if slot["charges"] <= 0:
				slots[i] = null

	# One button. A press always swings (a hit, or a visible miss); holding mines the block you
	# aim at, swinging again whenever someone is in front of you. Just after being hit, a short lock.
	swing_buffer = maxf(0.0, swing_buffer - dt)
	if pressed(inp, "mine"):
		swing_buffer = Cfg.SWING_BUFFER
	var holding: bool = inp.get("mine", false)
	var swung := false
	if (holding or swing_buffer > 0) and swing_cd == 0.0 and hit_lock == 0.0:
		var victims: Array = game.swing_targets(self)
		if victims or swing_buffer > 0:
			game.melee(self, victims)
			swing_cd = Cfg.SWING_COOLDOWN
			swing_buffer = 0.0
			swung = true
	if holding and not swung:
		_mine(dt, world, game)
	elif not holding:
		_stop_mining()
	if inp.get("place", false) and place_cd == 0.0 and blocks() > 0:
		var t := target(world, true)
		if world.in_bounds(t.x, t.y) and world.get_tile(t.x, t.y) == World.EMPTY and not game.player_in_tile(t.x, t.y):
			world.set_tile(t.x, t.y, World.PLACED)
			inv["dirt" if inv["dirt"] > 0 else "stone"] -= 1
			place_cd = Cfg.PLACE_COOLDOWN
			game.sound("place")


func _mine(dt: float, world: World, game) -> void:
	var t := target(world, false)
	var tile := world.get_tile(t.x, t.y)
	if tile == World.EMPTY or tile == World.LAVA:
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
	var bump := false
	for t: Vector2i in hits:
		bump = bump or world.get_tile(t.x, t.y) == World.BUMPER
	if mx > 0:
		x = hits.map(func(t): return t.x).min() - W
	elif mx < 0:
		x = hits.map(func(t): return t.x).max() + 1
	if mx != 0:
		kvx = 0.0
		walk_v = 0.0
		if bump:
			kvx = -signf(mx) * Cfg.BUMPER_KNOCK      # a bumper flings you back the way you came
			vy = minf(vy, -6.0)
			stun = maxf(stun, 0.2)
			bumped = true
	if my > 0:
		var floor_row: int = hits.map(func(t): return t.y).min()
		y = floor_row - H
		var bouncy := false
		var pad := false
		for t: Vector2i in hits:
			bouncy = bouncy or (t.y == floor_row and world.get_tile(t.x, t.y) == World.SLIME)
			pad = pad or (t.y == floor_row and world.get_tile(t.x, t.y) == World.BOUNCE)
		if pad:
			vy = -Cfg.BOUNCE_LAUNCH                    # a bounce pad launches you, even just stepping on it
			jump_cut_ready = false
		elif bump:
			vy = -Cfg.BUMPER_KNOCK * 0.8               # landing on a bumper pops you back up
			jump_cut_ready = false
			bumped = true
		elif bouncy and vy > Cfg.SLIME_MIN:
			vy = -vy * Cfg.SLIME_BOUNCE                # slime throws you back up instead of landing
		else:
			vy = 0.0
			on_ground = true
	elif my < 0:
		y = hits.map(func(t): return t.y).max() + 1
		vy = 6.0 if bump else 0.0
		bumped = bumped or bump

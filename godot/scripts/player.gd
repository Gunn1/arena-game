## One player: movement, wall jumps, mining, placing, crafting and item slots.
## Inputs come in as a Dictionary: left right up down jump mine place item1 item2 item3 craft,
## plus optional "mouse" (Vector2, in tiles), "stick_aim" (Vector2) and "wheel" (int).
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
var kvx := 0.0                    # sideways speed from knockback, wall kicks and the grapple
var on_ground := false
var coyote := 0.0
var wall_coyote := 0.0
var wall_dir := 0                 # -1 wall on the left, 1 on the right
var last_wall := 0                # side of the last wall jump; can't repeat it until landing
var wall_lock := 0.0
var facing := 1
var aim := Vector2i(1, 0)
var inv := {}
var slots: Array = []             # null or {"item": key, "charges": n}
var crafting := false             # crafting menu open (while craft is held)
var recipe := 0
var grapple = null                # Vector3(x, y, time left) while being pulled
var mine_cd := 0.0
var place_cd := 0.0
var item_cd := 0.0
var held := {}                    # last frame's input, for "just pressed"
var alive := true


func _init(i: int) -> void:
	index = i
	color = Cfg.PLAYER_COLORS[i]
	spawn(0, 0)


func spawn(col: int, ground_row: int) -> void:
	x = col + 0.5 - W / 2.0
	y = ground_row - H
	vy = 0.0
	kvx = 0.0
	on_ground = false
	coyote = 0.0
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
	crafting = false
	grapple = null
	mine_cd = 0.0
	place_cd = 0.0
	item_cd = 0.0
	held = {}
	alive = true


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
	var cost: Dictionary = Items.ITEMS[key]["cost"]
	for m in cost:
		if inv[m] < cost[m]:
			return false
	return true


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


func cycle_recipe(step: int) -> void:
	recipe = posmod(recipe + step, Items.RECIPES.size())


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


## The tile being aimed at: beside, above, below, or diagonal from the player.
func target(world: World, placing: bool) -> Vector2i:
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


# --- per frame -----------------------------------------------------------------------

func update(dt: float, inp: Dictionary, game) -> void:
	mine_cd = maxf(0.0, mine_cd - dt)
	place_cd = maxf(0.0, place_cd - dt)
	item_cd = maxf(0.0, item_cd - dt)

	var mouse = inp.get("mouse")
	# Holding craft opens the menu. Without a mouse, left/right pick the recipe, so you stop walking.
	crafting = inp.get("craft", false)
	var menu_steering: bool = crafting and mouse == null
	var dx := 0 if menu_steering else int(inp.get("right", false)) - int(inp.get("left", false))
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
	_use_hands(inp, game)
	held = inp.duplicate()

	# Falling out the bottom or off either side is death.
	if y > Cfg.ROWS + 1 or x + W < -0.5 or x > Cfg.COLS + 0.5:
		alive = false


func _move_body(dt: float, dx: int, inp: Dictionary, game) -> void:
	var world: World = game.world
	kvx *= exp(-Cfg.KNOCK_DECAY * dt)
	if absf(kvx) < 0.1:
		kvx = 0.0
	coyote = Cfg.COYOTE if on_ground else maxf(0.0, coyote - dt)
	wall_lock = maxf(0.0, wall_lock - dt)
	if on_ground:
		last_wall = 0

	if grapple != null and _pull(dt, world):
		return
	vy = minf(vy + Cfg.GRAVITY * dt, Cfg.MAX_FALL)

	# Wall slide: holding into a wall while falling slows the fall.
	var wall := 0 if on_ground else wall_side(world)
	if wall:
		wall_coyote = Cfg.WALL_COYOTE
		wall_dir = wall
		if dx == wall and vy > Cfg.WALL_SLIDE_SPEED:
			vy = Cfg.WALL_SLIDE_SPEED
	else:
		wall_coyote = maxf(0.0, wall_coyote - dt)

	if pressed(inp, "jump"):
		if coyote > 0:
			vy = -Cfg.JUMP_SPEED
			coyote = 0.0
			game.sound("jump")
		elif wall_coyote > 0 and wall_dir != last_wall:
			# Wall jump: up, and kicked away from the wall.
			vy = -Cfg.WALL_JUMP_SPEED
			kvx = -wall_dir * Cfg.WALL_KICK
			facing = -wall_dir
			wall_coyote = 0.0
			last_wall = wall_dir
			wall_lock = Cfg.WALL_LOCK
			game.sound("jump")
			var side_x := x if wall_dir < 0 else x + W
			game.burst(Vector2(side_x, y + H * 0.7), Color(0.78, 0.78, 0.86), 8, 4.0, 0.3, 3)

	var walk := 0 if wall_lock > 0 else dx
	move(world, (walk * Cfg.MOVE_SPEED + kvx) * dt, 0.0)
	on_ground = false
	move(world, 0.0, vy * dt)


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


func _use_hands(inp: Dictionary, game) -> void:
	var world: World = game.world
	# Crafting: hold craft, pick a recipe, let go to craft it.
	if crafting:
		if inp.get("wheel", 0):
			cycle_recipe(1 if inp["wheel"] > 0 else -1)
		if inp.get("mouse") != null:
			var hover: int = game.menu_hover(self, inp["mouse"])
			if hover != -1:
				recipe = hover
		else:
			if pressed(inp, "right"):
				cycle_recipe(1)
			if pressed(inp, "left"):
				cycle_recipe(-1)
	elif held.get("craft", false):                # craft button just released
		game.sound("craft" if craft(Items.RECIPES[recipe]) else "nope")

	# Items: each slot has its own button.
	for i in Cfg.SLOTS:
		var slot = slots[i]
		if pressed(inp, "item%d" % (i + 1)) and slot != null and item_cd == 0.0 and game.use_item(self, slot["item"]):
			item_cd = Items.ITEMS[slot["item"]]["cooldown"]
			slot["charges"] -= 1
			if slot["charges"] <= 0:
				slots[i] = null

	if inp.get("mine", false) and mine_cd == 0.0:
		var t := target(world, false)
		if world.solid(t.x, t.y):
			mine_cd = Cfg.MINE_COOLDOWN
			var broke := world.hit(t.x, t.y)
			if broke != -1:
				collect(broke)
				game.sound("mine")
			else:
				game.sound("crack")
	if inp.get("place", false) and place_cd == 0.0 and blocks() > 0:
		var t := target(world, true)
		if world.in_bounds(t.x, t.y) and not world.solid(t.x, t.y) and not game.player_in_tile(t.x, t.y):
			world.set_tile(t.x, t.y, World.PLACED)
			inv["dirt" if inv["dirt"] > 0 else "stone"] -= 1
			place_cd = Cfg.PLACE_COOLDOWN
			game.sound("place")


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
	if my > 0:
		y = hits.map(func(t): return t.y).min() - H
		vy = 0.0
		on_ground = true
	elif my < 0:
		y = hits.map(func(t): return t.y).max() + 1
		vy = 0.0

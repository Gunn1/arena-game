## Screens, input, drawing, sound and networking around the GameSim.
##
## Modes:  local  - everyone on this PC (keyboard, mouse, controllers)
##         host   - you play and host; friends join over WebSockets
##         server - headless dedicated server (godot --headless -- --server), nobody plays on it
##         client - you joined someone; the host runs the game and sends snapshots
extends Node2D

const CELL := Cfg.CELL
const HUD_H := Cfg.HUD_H
const WIDTH := Cfg.WIDTH
const HEIGHT := Cfg.HEIGHT
const DANGER := Color(1.0, 0.3, 0.37)
const INK := Color(0.93, 0.94, 1.0)
const DIM := Color(0.66, 0.68, 0.84)
const PANEL := Color(0.08, 0.09, 0.18)
const SLOT_BG := Color(0.13, 0.15, 0.28)
const GRASS := Color(0.36, 0.76, 0.29)
const GRASS_LIGHT := Color(0.55, 0.89, 0.44)
const TILE_COLORS := {World.DIRT: Color(0.54, 0.35, 0.2), World.STONE: Color(0.43, 0.44, 0.53),
	World.PLACED: Color(0.69, 0.52, 0.33), World.COPPER: Color(0.43, 0.44, 0.53), World.CRYSTAL: Color(0.43, 0.44, 0.53)}
const ORE_COLORS := {World.COPPER: Color(0.9, 0.55, 0.24), World.CRYSTAL: Color(0.35, 0.88, 0.94)}
const HILL_COLORS := [Color(0.085, 0.095, 0.24), Color(0.055, 0.06, 0.16)]
const PICK_HANDLE := Color(0.55, 0.38, 0.22)
const PICK_HEAD := Color(0.78, 0.8, 0.88)
# Mining cracks, in pixels inside a tile: each stage adds these segments (pairs of points).
const CRACKS := [
	[Vector2(10, 10), Vector2(6, 6), Vector2(10, 10), Vector2(14, 13)],
	[Vector2(6, 6), Vector2(3, 2), Vector2(14, 13), Vector2(13, 18), Vector2(10, 10), Vector2(16, 7)],
	[Vector2(16, 7), Vector2(19, 3), Vector2(10, 10), Vector2(5, 13), Vector2(13, 18), Vector2(17, 19)],
	[Vector2(5, 13), Vector2(1, 16), Vector2(16, 7), Vector2(17, 12), Vector2(6, 6), Vector2(8, 1), Vector2(3, 2), Vector2(1, 5)],
]

# Keyboard layouts. Online, everyone uses p1_mouse on their own PC.
const LAYOUTS := {
	"p1_mouse": {"left": [KEY_A], "right": [KEY_D], "up": [KEY_W], "down": [KEY_S], "jump": [KEY_W, KEY_SPACE],
		"mine": [], "place": [], "item1": [KEY_Q], "item2": [KEY_E], "item3": [KEY_R], "craft": [KEY_F, KEY_TAB]},
	"p2_keys": {"left": [KEY_J], "right": [KEY_L], "up": [KEY_I], "down": [KEY_K], "jump": [KEY_I],
		"mine": [KEY_U], "place": [KEY_O], "item1": [KEY_7], "item2": [KEY_8], "item3": [KEY_9], "craft": [KEY_H]},
}
const SLOT_LABELS := {"p1_mouse": ["Q", "E", "R"], "p2_keys": ["7", "8", "9"], "pad": ["X", "Y", "B"]}
const CRAFT_LABELS := {"p1_mouse": "F", "p2_keys": "H", "pad": "RB"}

var sim := GameSim.new()
var sfx: Sfx
var font: Font
var world_root: Node2D
var tiles: TileMapLayer
var overlay: Node2D
var hud: Node2D
var address_edit: LineEdit
var screen := "title"             # title, join, lobby, game
var mode := "local"
var notice := ""
var time := 0.0
var particles: Array = []         # [pos, vel, life, color, size, gravity]; fade out over the last 0.25 s
var run_phase := {}               # player index -> run-cycle phase in radians (local only)
var prev_land := {}               # player index -> last frame's land_t, to spot new landings
var hills: Array[PackedVector2Array] = []   # background silhouettes, far to near
var shown_version := -1
var wheel := 0
var local_sources: Array = []     # local mode: per player "p1_mouse", "p2_keys" or a joypad id
var match_size := 2

# Networking
var peer: WebSocketMultiplayerPeer
var lobby_peers: Array = []       # host/server: peer ids, in join order
var peer_index := {}              # peer id -> player index in the current match
var remote := {}                  # peer id -> {"queue": Prediction.ServerQueue, "wheel": 0}
var my_index := 0                 # client: which player I am
var lobby_size := 0
var dedicated := false            # client: the host is a dedicated server
var sent_version := -1
var predictor := Prediction.Client.new()   # client: predicts my own player between snapshots
var trails := {}                  # client: other players' index -> [[receive time, Vector2 pos], ...]
const INTERP_DELAY := 0.1         # client: other players are drawn this far in the past, between snapshots

# Test hooks (command line)
var bot := false
var quit_after := 0.0
var print_hash := false
var autostart := 0
var lag := 0.0                    # client: --lag MS, extra delay each way (seconds)
var lag_out: Array = []           # [due msec, input] waiting to be sent
var lag_in: Array = []            # [due msec, "snap"/"grid", Dictionary] waiting to be applied


func _ready() -> void:
	font = ThemeDB.fallback_font
	var hill_rng := RandomNumberGenerator.new()
	hill_rng.seed = 11
	hills = [_make_hills(hill_rng, HUD_H + Cfg.ROWS * CELL * 0.4, 45.0),
		_make_hills(hill_rng, HUD_H + Cfg.ROWS * CELL * 0.55, 32.0)]
	sfx = Sfx.new()
	add_child(sfx)
	world_root = Node2D.new()
	world_root.position = Vector2(0, HUD_H)
	add_child(world_root)
	tiles = TileMapLayer.new()
	tiles.tile_set = _build_tileset()
	world_root.add_child(tiles)
	overlay = Node2D.new()
	overlay.draw.connect(_draw_overlay)
	world_root.add_child(overlay)
	hud = Node2D.new()
	hud.draw.connect(_draw_hud)
	add_child(hud)
	address_edit = LineEdit.new()
	address_edit.placeholder_text = "100.101.102.103"
	address_edit.position = Vector2(WIDTH / 2.0 - 260, 300)
	address_edit.size = Vector2(520, 56)
	address_edit.add_theme_font_size_override("font_size", 26)
	address_edit.visible = false
	address_edit.text_submitted.connect(func(t): join_game(t))
	add_child(address_edit)

	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(func(): notice = "")
	multiplayer.connection_failed.connect(func(): leave_online("Couldn't connect"))
	multiplayer.server_disconnected.connect(func(): leave_online("The host left"))

	var args := OS.get_cmdline_user_args()
	bot = "--bot" in args
	print_hash = "--print-hash" in args
	var port := int(_arg(args, "--port", str(Cfg.NET_PORT)))
	quit_after = float(_arg(args, "--quit-after", "0"))
	autostart = int(_arg(args, "--autostart", "0"))
	lag = float(_arg(args, "--lag", "0")) / 1000.0
	if "--server" in args:
		host_game(true, port)
		print("Dedicated server listening on port %d" % port)
	elif "--join" in args:
		join_game(_arg(args, "--join", "127.0.0.1"))


func _arg(args: PackedStringArray, flag: String, fallback: String) -> String:
	var i := args.find(flag)
	return args[i + 1] if i != -1 and i + 1 < args.size() else fallback


# --- tiles -----------------------------------------------------------------------------

# Atlas layout: one row per tile type; columns are (air mask * VARIANTS + noise variant).
# The mask says which of the 4 neighbours are air, so edges can be shaded per tile.
const TILE_TYPES := [World.DIRT, World.STONE, World.PLACED, World.COPPER, World.CRYSTAL]
const VARIANTS := 3
const M_TOP := 1
const M_RIGHT := 2
const M_BOTTOM := 4
const M_LEFT := 8
const SELF_AND_NEIGHBOURS := [Vector2i(0, 0), Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]

var atlas: ImageTexture


func _build_tileset() -> TileSet:
	var img := Image.create_empty(CELL * VARIANTS * 16, CELL * TILE_TYPES.size(), false, Image.FORMAT_RGBA8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261121
	for r in TILE_TYPES.size():
		var tile: int = TILE_TYPES[r]
		for v in VARIANTS:
			var base := _paint_base(tile, rng)
			for mask in 16:
				var ox := (mask * VARIANTS + v) * CELL
				var oy := r * CELL
				img.blit_rect(base, Rect2i(0, 0, CELL, CELL), Vector2i(ox, oy))
				_paint_edges(img, ox, oy, tile, mask, rng)
	atlas = ImageTexture.create_from_image(img)
	var src := TileSetAtlasSource.new()
	src.texture = atlas
	src.texture_region_size = Vector2i(CELL, CELL)
	for r in TILE_TYPES.size():
		for c in VARIANTS * 16:
			src.create_tile(Vector2i(c, r))
	var ts := TileSet.new()
	ts.tile_size = Vector2i(CELL, CELL)
	ts.add_source(src, 0)
	return ts


## One tile's texture with no edge shading: a few shades of 2x2 noise plus per-type details.
func _paint_base(tile: int, rng: RandomNumberGenerator) -> Image:
	var img := Image.create_empty(CELL, CELL, false, Image.FORMAT_RGBA8)
	var base: Color = TILE_COLORS[tile]
	if tile == World.PLACED:
		_paint_planks(img, base, rng)
		return img
	for cy in CELL / 2:
		for cx in CELL / 2:
			var roll := rng.randf()
			var c := base
			if roll < 0.15:
				c = base.darkened(0.16)
			elif roll < 0.4:
				c = base.darkened(0.07)
			elif roll > 0.82:
				c = base.lightened(0.06)
			img.fill_rect(Rect2i(cx * 2, cy * 2, 2, 2), c)
	if tile == World.DIRT:
		# Pebbles and darker clods.
		for i in 3:
			var px := rng.randi_range(2, CELL - 5)
			var py := rng.randi_range(3, CELL - 4)
			img.fill_rect(Rect2i(px, py, 2, 2), Color(0.63, 0.53, 0.43))
			img.set_pixel(px, py, Color(0.74, 0.65, 0.55))
		for i in 2:
			img.fill_rect(Rect2i(rng.randi_range(2, CELL - 6), rng.randi_range(3, CELL - 4), 3, 2), base.darkened(0.28))
	else:
		# Stone: flat lighter patches and short dark crevices.
		for i in 2:
			img.fill_rect(Rect2i(rng.randi_range(2, CELL - 7), rng.randi_range(2, CELL - 5), 4, 2), base.lightened(0.1))
		for i in 2:
			var cx := rng.randi_range(3, CELL - 7)
			var cy := rng.randi_range(5, CELL - 6)
			var dir := 1 if rng.randf() < 0.5 else -1
			for k in 4:
				img.set_pixel(cx + k, cy + floori(k / 2.0) * dir, base.darkened(0.32))
	if ORE_COLORS.has(tile):
		var ore: Color = ORE_COLORS[tile]
		for i in rng.randi_range(3, 4):
			var nx := rng.randi_range(3, CELL - 7)
			var ny := rng.randi_range(3, CELL - 7)
			img.fill_rect(Rect2i(nx + 1, ny + 1, 3, 3), ore.darkened(0.5))
			img.fill_rect(Rect2i(nx, ny, 3, 3), ore)
			img.set_pixel(nx, ny, ore.lightened(0.55))
	return img


## Placed blocks: two planks with grain, joints, and a bevel.
func _paint_planks(img: Image, base: Color, rng: RandomNumberGenerator) -> void:
	img.fill(base)
	for i in 7:
		var gx := rng.randi_range(0, CELL - 6)
		img.fill_rect(Rect2i(gx, rng.randi_range(1, CELL - 2), rng.randi_range(3, 6), 1), base.darkened(0.13))
	var edge := base.darkened(0.32)
	img.fill_rect(Rect2i(0, CELL / 2 - 1, CELL, 1), edge)
	img.fill_rect(Rect2i(rng.randi_range(5, CELL - 6), 0, 1, CELL / 2 - 1), edge)
	img.fill_rect(Rect2i(rng.randi_range(5, CELL - 6), CELL / 2, 1, CELL / 2), edge)
	img.fill_rect(Rect2i(0, 0, CELL, 1), base.lightened(0.14))
	img.fill_rect(Rect2i(0, 0, 1, CELL), base.lightened(0.07))
	img.fill_rect(Rect2i(0, CELL - 1, CELL, 1), edge)
	img.fill_rect(Rect2i(CELL - 1, 0, 1, CELL), edge)


## Shading where the tile touches air: lit top (grass on dirt), dark bottom, darker sides,
## and the corners rounded off where two open sides meet.
func _paint_edges(img: Image, ox: int, oy: int, tile: int, mask: int, rng: RandomNumberGenerator) -> void:
	if mask & M_TOP:
		if tile == World.DIRT:
			for x in CELL:
				var depth := rng.randi_range(4, 6)
				for y in depth:
					var g := GRASS_LIGHT if y < 2 else (GRASS.darkened(0.25) if y == depth - 1 else GRASS)
					img.set_pixel(ox + x, oy + y, g)
		else:
			_shade(img, Rect2i(ox, oy, CELL, 1), 0.22)
			_shade(img, Rect2i(ox, oy + 1, CELL, 1), 0.1)
	if mask & M_BOTTOM:
		_shade(img, Rect2i(ox, oy + CELL - 1, CELL, 1), -0.35)
		_shade(img, Rect2i(ox, oy + CELL - 2, CELL, 1), -0.18)
	if mask & M_LEFT:
		_shade(img, Rect2i(ox, oy, 1, CELL), -0.2)
		_shade(img, Rect2i(ox + 1, oy, 1, CELL), -0.08)
	if mask & M_RIGHT:
		_shade(img, Rect2i(ox + CELL - 1, oy, 1, CELL), -0.2)
		_shade(img, Rect2i(ox + CELL - 2, oy, 1, CELL), -0.08)
	var clear := Color(0, 0, 0, 0)
	var e := CELL - 1
	if (mask & M_TOP) and (mask & M_LEFT):
		for d: Vector2i in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1)]:
			img.set_pixel(ox + d.x, oy + d.y, clear)
	if (mask & M_TOP) and (mask & M_RIGHT):
		for d: Vector2i in [Vector2i(e, 0), Vector2i(e - 1, 0), Vector2i(e, 1)]:
			img.set_pixel(ox + d.x, oy + d.y, clear)
	if (mask & M_BOTTOM) and (mask & M_LEFT):
		for d: Vector2i in [Vector2i(0, e), Vector2i(1, e), Vector2i(0, e - 1)]:
			img.set_pixel(ox + d.x, oy + d.y, clear)
	if (mask & M_BOTTOM) and (mask & M_RIGHT):
		for d: Vector2i in [Vector2i(e, e), Vector2i(e - 1, e), Vector2i(e, e - 1)]:
			img.set_pixel(ox + d.x, oy + d.y, clear)


## Lighten (amount > 0) or darken (amount < 0) every pixel in r.
func _shade(img: Image, r: Rect2i, amount: float) -> void:
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			var c := img.get_pixel(x, y)
			img.set_pixel(x, y, c.lightened(amount) if amount > 0 else c.darkened(-amount))


## Atlas coords for the tile at (x, y), or (-1, -1) if it's empty.
func _tile_coords(x: int, y: int) -> Vector2i:
	var w := sim.world
	var row := TILE_TYPES.find(w.get_tile(x, y))
	if row == -1:
		return Vector2i(-1, -1)
	var mask := 0
	if not w.solid(x, y - 1):
		mask |= M_TOP
	if not w.solid(x + 1, y):
		mask |= M_RIGHT
	if not w.solid(x, y + 1):
		mask |= M_BOTTOM
	if not w.solid(x - 1, y):
		mask |= M_LEFT
	var variant := (x * 73856093 ^ y * 19349663) % VARIANTS
	return Vector2i(mask * VARIANTS + variant, row)


func _set_cell(x: int, y: int) -> void:
	if not sim.world.in_bounds(x, y):
		return
	var cell := Vector2i(x, y)
	var coords := _tile_coords(x, y)
	if coords.x == -1 or sim.world.warnings.has(cell):
		tiles.erase_cell(cell)                     # warned tiles are drawn shaking by the overlay
	else:
		tiles.set_cell(cell, 0, coords)


## Only redraw tiles that changed, plus their 4 neighbours (whose edges depend on them).
func _refresh_tiles() -> void:
	var w := sim.world
	if w.version != shown_version:
		shown_version = w.version
		tiles.clear()
		for y in Cfg.ROWS:
			for x in Cfg.COLS:
				_set_cell(x, y)
	else:
		for pos: Vector2i in w.dirty:
			for d: Vector2i in SELF_AND_NEIGHBOURS:
				_set_cell(pos.x + d.x, pos.y + d.y)
	w.dirty.clear()


# --- input -----------------------------------------------------------------------------

func _read_keys(layout: String) -> Dictionary:
	var d := {}
	var keys: Dictionary = LAYOUTS[layout]
	for action in keys:
		d[action] = keys[action].any(func(k): return Input.is_physical_key_pressed(k))
	if layout == "p1_mouse":
		var m := get_global_mouse_position()
		d["mouse"] = Vector2(m.x / CELL, (m.y - HUD_H) / CELL)
		d["mine"] = Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
		d["place"] = Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)
		d["wheel"] = wheel
		wheel = 0
	return d


func _read_pad(dev: int) -> Dictionary:
	var stick := Vector2(Input.get_joy_axis(dev, JOY_AXIS_LEFT_X), Input.get_joy_axis(dev, JOY_AXIS_LEFT_Y))
	var dpad := Vector2(int(Input.is_joy_button_pressed(dev, JOY_BUTTON_DPAD_RIGHT)) - int(Input.is_joy_button_pressed(dev, JOY_BUTTON_DPAD_LEFT)),
		int(Input.is_joy_button_pressed(dev, JOY_BUTTON_DPAD_DOWN)) - int(Input.is_joy_button_pressed(dev, JOY_BUTTON_DPAD_UP)))
	if dpad != Vector2.ZERO:
		stick = dpad
	var right := Vector2(Input.get_joy_axis(dev, JOY_AXIS_RIGHT_X), Input.get_joy_axis(dev, JOY_AXIS_RIGHT_Y))
	var d := {"left": stick.x < -0.45, "right": stick.x > 0.45, "up": stick.y < -0.45, "down": stick.y > 0.45,
		"jump": Input.is_joy_button_pressed(dev, JOY_BUTTON_A), "item1": Input.is_joy_button_pressed(dev, JOY_BUTTON_X),
		"item2": Input.is_joy_button_pressed(dev, JOY_BUTTON_Y), "item3": Input.is_joy_button_pressed(dev, JOY_BUTTON_B),
		"craft": Input.is_joy_button_pressed(dev, JOY_BUTTON_RIGHT_SHOULDER),
		"mine": Input.get_joy_axis(dev, JOY_AXIS_TRIGGER_RIGHT) > 0.3, "place": Input.get_joy_axis(dev, JOY_AXIS_TRIGGER_LEFT) > 0.3}
	if right.length() > 0.5:
		d["stick_aim"] = right
	return d


## Online, your own input: keyboard + mouse, plus the first controller if one is plugged in.
func _my_input() -> Dictionary:
	if bot:
		return _bot_input()
	var d := _read_keys("p1_mouse")
	var pads := Input.get_connected_joypads()
	if pads:
		var p := _read_pad(pads[0])
		for k in p:
			if k == "stick_aim":
				d.erase("mouse")
				d["stick_aim"] = p[k]
			elif p[k]:
				d[k] = true
	return d


func _local_input(i: int) -> Dictionary:
	var src = local_sources[i]
	return _read_pad(src) if src is int else (_my_input() if src == "p1_mouse" else _read_keys(src))


## One queued input per tick (the queue merges bursts and repeats the last input when empty).
func _remote_input(peer_id: int) -> Dictionary:
	var r: Dictionary = remote.get(peer_id, {})
	if r.is_empty():
		return {}
	var q: Prediction.ServerQueue = r["queue"]
	var out := q.next()
	out["wheel"] = r["wheel"]
	r["wheel"] = 0
	return out


func _bot_input() -> Dictionary:
	# Test client: walk right for a second, dig straight down while standing still (the block under
	# your feet is always solid, so the map always changes), walk left, jump now and then.
	var t := sim.tick % 240
	var still := (t >= 60 and t < 120) or t >= 180
	return {"right": t < 60, "left": t >= 120 and t < 180, "jump": t % 50 == 0, "mine": true,
		"up": false, "down": still, "place": false, "item1": false, "item2": false, "item3": false, "craft": false}


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			wheel -= 1
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			wheel += 1
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	var key: int = event.physical_keycode
	if key == KEY_M:
		sfx.muted = not sfx.muted
	match screen:
		"title":
			if key == KEY_H and not OS.has_feature("web"):
				host_game(false, Cfg.NET_PORT)
			elif key == KEY_J:
				screen = "join"
				notice = ""
				address_edit.visible = true
				address_edit.grab_focus()
			elif key in [KEY_2, KEY_3, KEY_4]:
				start_local({KEY_2: 2, KEY_3: 3, KEY_4: 4}[key])
		"lobby":
			if key == KEY_ENTER or key == KEY_KP_ENTER:
				_try_start()
		"game":
			if sim.state == "match_over" and (key == KEY_ENTER or key == KEY_KP_ENTER):
				_try_start()


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		if screen == "title":
			if not OS.has_feature("web"):
				get_tree().quit()
		elif mode != "local":
			leave_online("")
		else:
			_to_title("")


func _to_title(msg: String) -> void:
	screen = "title"
	notice = msg
	address_edit.visible = false
	address_edit.release_focus()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


# --- local ----------------------------------------------------------------------------

func start_local(count: int) -> void:
	var pads := Input.get_connected_joypads()
	var sources := ["p1_mouse"]
	if pads.size() < count - 1:
		sources.append("p2_keys")
	for p in pads:
		if sources.size() < count:
			sources.append(p)
	if sources.size() < count:
		notice = "%d players needs %d controller(s) plugged in" % [count, count - 2]
		return
	local_sources = sources
	match_size = count
	mode = "local"
	sim.world.record = false
	sim.start_match(count)
	screen = "game"


# --- online ---------------------------------------------------------------------------

func host_game(as_server: bool, port: int) -> void:
	peer = WebSocketMultiplayerPeer.new()
	var err := peer.create_server(port)
	if err != OK:
		notice = "Can't host on port %d (error %d). Is another copy already hosting?" % [port, err]
		peer = null
		return
	multiplayer.multiplayer_peer = peer
	mode = "server" if as_server else "host"
	screen = "lobby"
	notice = ""
	lobby_peers = []
	remote = {}


func join_game(address: String) -> void:
	address = address.strip_edges()
	if address == "":
		return
	peer = WebSocketMultiplayerPeer.new()
	var url := _url_for(address)
	var err := peer.create_client(url)
	if err != OK:
		notice = "Couldn't connect to %s (error %d)" % [url, err]
		peer = null
		return
	multiplayer.multiplayer_peer = peer
	mode = "client"
	screen = "lobby"
	predictor = Prediction.Client.new()
	trails = {}
	notice = "Connecting to %s ..." % url
	lobby_size = 0
	address_edit.visible = false
	address_edit.release_focus()


## What the player typed -> a WebSocket URL.
##   "wss://..." / "ws://..."      used as is
##   "100.101.102.103" (an IP)     ws://IP:7777 (a friend hosting over Tailscale / LAN)
##   "arena.tylergunn.me" (a name) wss://name (a public server behind TLS, e.g. a Cloudflare Tunnel)
##   anything with ":port"         ws://host:port (wss from an https page, which can't use ws)
func _url_for(address: String) -> String:
	if "://" in address:
		return address
	var secure_page := OS.has_feature("web") and str(JavaScriptBridge.eval("location.protocol")) == "https:"
	if ":" in address:
		return ("wss://" if secure_page else "ws://") + address
	if address.is_valid_ip_address() or address == "localhost":
		return ("wss://" if secure_page else "ws://") + address + ":%d" % Cfg.NET_PORT
	return "wss://" + address


func leave_online(msg: String) -> void:
	if peer:
		peer.close()
	peer = null
	multiplayer.multiplayer_peer = null
	mode = "local"
	lobby_peers = []
	remote = {}
	predictor = Prediction.Client.new()
	trails = {}
	lag_out.clear()
	lag_in.clear()
	sim = GameSim.new()
	shown_version = -1
	particles.clear()
	_to_title(msg)
	if bot or quit_after > 0:
		print("LEFT: %s" % msg)
		get_tree().quit()


func _hosting() -> bool:
	return mode == "host" or mode == "server"


func _offset() -> int:
	return 1 if mode == "host" else 0            # host plays as P1


func _on_peer_connected(id: int) -> void:
	if not _hosting():
		return
	if screen != "lobby" or lobby_peers.size() + _offset() >= Cfg.MAX_PLAYERS:
		peer.disconnect_peer(id)
		return
	lobby_peers.append(id)
	remote[id] = {"queue": Prediction.ServerQueue.new(), "wheel": 0}
	_send_lobby()
	if autostart and lobby_peers.size() >= autostart:
		start_online_match()


func _on_peer_disconnected(id: int) -> void:
	if not _hosting():
		return
	lobby_peers.erase(id)
	remote.erase(id)
	if peer_index.has(id) and screen == "game":
		sim.players[peer_index[id]].alive = false   # left mid-match: counts as out
	peer_index.erase(id)
	if screen == "lobby":
		_send_lobby()


func _send_lobby() -> void:
	for k in lobby_peers.size():
		rpc_lobby.rpc_id(lobby_peers[k], k + _offset(), lobby_peers.size() + _offset(), mode == "server")


func _try_start() -> void:
	if mode == "client":
		rpc_request_start.rpc_id(1)
	elif _hosting():
		start_online_match()
	elif mode == "local" and screen == "game":
		start_local(match_size)


func start_online_match() -> void:
	var total := lobby_peers.size() + _offset()
	if total < 2:
		notice = "Need at least 2 players"
		return
	peer_index = {}
	for k in lobby_peers.size():
		peer_index[lobby_peers[k]] = k + _offset()
	sim.world.record = true
	sim.start_match(total)
	sent_version = -1
	screen = "game"
	notice = ""


@rpc("any_peer", "call_remote", "reliable")
func rpc_request_start() -> void:
	if _hosting() and (screen == "lobby" or sim.state == "match_over"):
		start_online_match()


@rpc("any_peer", "call_remote", "reliable")
func rpc_input(state: Dictionary) -> void:
	var id := multiplayer.get_remote_sender_id()
	if remote.has(id):
		remote[id]["queue"].push(state)
		remote[id]["wheel"] += int(state.get("wheel", 0))


@rpc("authority", "call_remote", "reliable")
func rpc_lobby(you: int, count: int, is_dedicated: bool) -> void:
	my_index = you
	lobby_size = count
	dedicated = is_dedicated
	notice = ""


@rpc("authority", "call_remote", "reliable")
func rpc_grid(d: Dictionary) -> void:
	if lag > 0:
		lag_in.append([Time.get_ticks_msec() + int(lag * 1000), "grid", d])
	else:
		_on_grid(d)


@rpc("authority", "call_remote", "reliable")
func rpc_snap(d: Dictionary) -> void:
	if lag > 0:
		lag_in.append([Time.get_ticks_msec() + int(lag * 1000), "snap", d])
	else:
		_on_snap(d)


func _on_grid(d: Dictionary) -> void:
	sim.apply_grid(d)
	particles.clear()


## Client: take the host's state, except my own player, which restarts from the host's state for
## the last input it applied and replays the ones it hasn't seen yet.
func _on_snap(d: Dictionary) -> void:
	screen = "game"
	var count := sim.players.size()
	var had := my_index < count
	var was_alive: bool = had and sim.players[my_index].alive
	var predicted_x: float = sim.players[my_index].x if had else 0.0
	var mouse = sim.players[my_index].mouse if had else null
	var round_before := sim.round_no
	_play_events(sim.apply_snapshot(d, my_index))
	_record_trails()
	var me := _my_player()
	if me and my_index < d["ns"].size():
		var ns: Array = d["ns"][my_index]
		if had and count == sim.players.size() and was_alive and me.alive and sim.round_no == round_before \
				and sim.state in ["play", "outro"]:
			predictor.reconcile(me, ns, int(d["ack"][my_index]), sim.world)
			me.mouse = mouse                         # my latest aim, not the host's older copy
		else:
			# Died, respawned or between rounds: nothing to predict, just take the host's state.
			me.set_net_state(ns)
			me.smooth = Vector2.ZERO
			predictor.history.clear()
		if print_hash and sim.tick % 60 == 30:
			print("PRED %d %.4f %.4f" % [sim.tick, predicted_x, float(ns[0])])
	if print_hash and sim.tick % 60 == 0:
		print("HASH %d %s" % [sim.tick, sim.world.grid.hex_encode().md5_text()])


## Client: remember where the other players were at each snapshot, to draw them between snapshots.
func _record_trails() -> void:
	var now := _now()
	for p: Player in sim.players:
		if p.index == my_index:
			continue
		var pos := Vector2(p.x, p.y)
		var tr: Array = trails.get(p.index, [])
		if tr and (tr[-1][1] as Vector2).distance_to(pos) > 3.0:
			tr.clear()                               # respawned: don't slide across the map
		tr.append([now, pos])
		while tr.size() > 2 and tr[1][0] < now - 0.5:
			tr.pop_front()
		trails[p.index] = tr


func _now() -> float:
	return Time.get_ticks_usec() / 1000000.0


## Where to draw a player (top-left, in tiles). Client: my own player is predicted, plus the easing
## left from the last correction; others are interpolated INTERP_DELAY behind. Otherwise: as simulated.
func draw_pos(p: Player) -> Vector2:
	if mode != "client":
		return Vector2(p.x, p.y)
	if p.index == my_index:
		return Vector2(p.x, p.y) + p.smooth
	var tr: Array = trails.get(p.index, [])
	if tr.is_empty():
		return Vector2(p.x, p.y)
	var t := _now() - INTERP_DELAY
	if t <= tr[0][0]:
		return tr[0][1]
	for i in range(1, tr.size()):
		var b: Array = tr[i]
		if t <= b[0]:
			var a: Array = tr[i - 1]
			var span: float = b[0] - a[0]
			var k: float = 0.0 if span <= 0.0 else (t - a[0]) / span
			return (a[1] as Vector2).lerp(b[1], k)
	return tr[-1][1]


func _draw_centre(p: Player) -> Vector2:
	return draw_pos(p) + Vector2(Cfg.PLAYER_W, Cfg.PLAYER_H) / 2.0


## Client: inputs and snapshots held back by --lag until they're due.
func _flush_lag() -> void:
	var now := Time.get_ticks_msec()
	var connected := peer != null and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED
	while lag_out and lag_out[0][0] <= now:
		var sent: Dictionary = lag_out.pop_front()[1]
		if connected:
			rpc_input.rpc_id(1, sent)
	while lag_in and lag_in[0][0] <= now and mode == "client":
		var m: Array = lag_in.pop_front()
		if m[1] == "grid":
			_on_grid(m[2])
		else:
			_on_snap(m[2])


func _send_input(sent: Dictionary) -> void:
	if lag > 0:
		lag_out.append([Time.get_ticks_msec() + int(lag * 1000), sent])
	else:
		rpc_input.rpc_id(1, sent)


# --- frame loop -----------------------------------------------------------------------

func _physics_process(_delta: float) -> void:
	if quit_after > 0 and time > quit_after:
		get_tree().quit()
	if mode == "client":
		_flush_lag()
		if screen == "game" and sim.state in ["intro", "play", "outro"] and peer \
				and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
			var input := _my_input()
			_send_input(predictor.record(input))
			var me := _my_player()
			# Move my own player now instead of waiting a round trip (the host freezes everyone
			# between rounds and during hitstop, so don't predict then either).
			if me and me.alive and sim.state in ["play", "outro"] and sim.hitstop <= 0:
				predictor.predict(me, sim.world, input)
		for pos in sim.world.warnings:           # tick warnings for the shake effect only
			sim.world.warnings[pos] = maxf(0.01, sim.world.warnings[pos] - Cfg.DT)
		return
	if screen != "game":
		return
	var inputs := []
	for i in sim.players.size():
		match mode:
			"local": inputs.append(_local_input(i))
			"host": inputs.append(_my_input() if i == 0 else _remote_input(peer_index.find_key(i) if peer_index.find_key(i) != null else -1))
			"server": inputs.append(_remote_input(peer_index.find_key(i) if peer_index.find_key(i) != null else -1))
	sim.update(Cfg.DT, inputs)
	_play_events(sim.events)
	if _hosting():
		if sim.world.version != sent_version:
			sent_version = sim.world.version
			rpc_grid.rpc(sim.grid_message())
		sim.acks = []
		for i in sim.players.size():
			var id = peer_index.find_key(i)
			sim.acks.append(remote[id]["queue"].acked if id != null and remote.has(id) else 0)
		rpc_snap.rpc(sim.snapshot())
		if print_hash and sim.tick % 60 == 0:
			print("HASH %d %s" % [sim.tick, sim.world.grid.hex_encode().md5_text()])
	sim.events.clear()
	sim.world.changes.clear()


func _process(delta: float) -> void:
	time += delta
	if screen == "game" and not (mode == "server"):
		_refresh_tiles()
		_drain_debris()
		_update_juice(delta)
		var me := _my_player()
		if mode == "client" and me:
			me.smooth *= exp(-delta * 15.0)          # ease out the last prediction correction
		for p in particles:
			p[0] += p[1] * delta
			p[1].y += p[5] * delta
			p[2] -= delta
		particles = particles.filter(func(p): return p[2] > 0)
		var power := int(10 * sim.shake)
		world_root.position = Vector2(randi_range(-power, power), HUD_H + randi_range(-power, power))
		var hide := mode != "server" and _my_player() != null
		Input.mouse_mode = Input.MOUSE_MODE_HIDDEN if hide and sim.state != "match_over" else Input.MOUSE_MODE_VISIBLE
	tiles.visible = screen == "game"
	overlay.queue_redraw()
	hud.queue_redraw()
	queue_redraw()


func _my_player() -> Player:
	var i := 0
	if mode == "client":
		i = my_index
	elif mode == "local" and not "p1_mouse" in local_sources:
		return null
	return sim.players[i] if i < sim.players.size() else null


func _play_events(events: Array) -> void:
	for e in events:
		if e[0] == "snd":
			sfx.play(e[1], e[2])
		elif e[0] == "pt":
			_burst(e[1], e[2], e[3], e[4], e[5], e[6], e[7])


func _burst(pos: Vector2, color: Color, count: int, speed: float, life: float, size: int, up: float) -> void:
	for i in count:
		var a := randf() * TAU
		var s := randf_range(0.3, 1.0) * speed
		particles.append([pos, Vector2(cos(a) * s, sin(a) * s - up), randf_range(0.5, 1.0) * life, color, size, 30.0])


func _drain_debris() -> void:
	var crumbled := false
	for b in sim.world.broken:
		var color: Color = ORE_COLORS.get(b[2], TILE_COLORS.get(b[2], Color.WHITE))
		for i in 5:
			particles.append([Vector2(b[0] + randf_range(0.2, 0.8), b[1] + randf_range(0.2, 0.8)),
				Vector2(randf_range(-3, 3), randf_range(-7, -2)), randf_range(0.3, 0.6), color, [3, 4, 5].pick_random(), 30.0])
		crumbled = crumbled or b[3] == "crumble"
	sim.world.broken.clear()
	if crumbled:
		sfx.play("crumble", 0.06)


## Client-side effects worked out from synced state only: run cycle and footsteps,
## landing dust, and the knockback trail.
func _update_juice(delta: float) -> void:
	var frozen: bool = sim.hitstop > 0
	for p: Player in sim.players:
		if not p.alive:
			prev_land[p.index] = 0.0
			continue
		var at := draw_pos(p)
		var feet := Vector2(at.x + Cfg.PLAYER_W / 2.0, at.y + Cfg.PLAYER_H)
		# A foot comes down every half turn of the run cycle.
		var phase: float = run_phase.get(p.index, 0.0)
		if not frozen and p.on_ground and absf(p.vel_x) > 0.5:
			var next := phase + delta * absf(p.vel_x) * 1.8
			if floori(next / PI) != floori(phase / PI) and _on_screen(feet):
				sfx.play("step", 0.18)
			phase = next
		run_phase[p.index] = phase
		var was: float = prev_land.get(p.index, 0.0)
		if p.land_t > 0 and was <= 0:
			for i in 10:
				var side := -1.0 if i % 2 == 0 else 1.0
				particles.append([feet + Vector2(side * randf_range(0.0, 0.3), -0.05),
					Vector2(side * randf_range(1.5, 5.0), randf_range(-2.5, -0.5)), randf_range(0.25, 0.45),
					Color(0.86, 0.82, 0.74, 0.8), [2, 3, 3, 4].pick_random(), 4.0])
		prev_land[p.index] = p.land_t
		if not frozen and p.stun > 0 and Vector2(p.vel_x, p.vy).length() > 10.0:
			particles.append([_draw_centre(p) + Vector2(randf_range(-0.25, 0.25), randf_range(-0.4, 0.4)), Vector2.ZERO,
				randf_range(0.2, 0.35), Color(p.color, 0.7), [3, 4, 5].pick_random(), 0.0])


func _on_screen(v: Vector2) -> bool:
	return v.x >= 0.0 and v.x <= Cfg.COLS and v.y >= 0.0 and v.y <= Cfg.ROWS


# --- drawing --------------------------------------------------------------------------

func _draw() -> void:
	# Night sky behind everything.
	var steps := 24
	for i in steps:
		var t := float(i) / steps
		var c := Color(0.16, 0.18, 0.42).lerp(Color(0.09, 0.1, 0.23), t / 0.7) if t < 0.7 else Color(0.09, 0.1, 0.23).lerp(Color(0.03, 0.03, 0.06), (t - 0.7) / 0.3)
		draw_rect(Rect2(0, HEIGHT * t, WIDTH, HEIGHT / float(steps) + 1), c)
	var r := RandomNumberGenerator.new()
	r.seed = 7
	for i in 90:
		var shade := r.randf_range(0.35, 0.86)
		draw_rect(Rect2(r.randi_range(0, WIDTH), HUD_H + r.randi_range(0, Cfg.ROWS * CELL / 3), 2, 2), Color(shade, shade, shade))
	# Distant hills, far layer first.
	for i in hills.size():
		draw_colored_polygon(hills[i], HILL_COLORS[i])


## A hill silhouette: a few summed sine waves along the top, closed off at the screen bottom.
func _make_hills(rng: RandomNumberGenerator, base_y: float, amp: float) -> PackedVector2Array:
	var waves: Array[Vector3] = []                # amplitude, cycles per screen, phase
	for i in 3:
		waves.append(Vector3(rng.randf_range(0.6, 1.0) / (i + 1), rng.randf_range(1.0, 2.5) * (i + 1), rng.randf() * TAU))
	var pts := PackedVector2Array()
	for x in range(0, WIDTH + 1, 12):
		var y := base_y
		for wv: Vector3 in waves:
			y -= amp * wv.x * sin(x / float(WIDTH) * TAU * wv.y + wv.z)
		pts.append(Vector2(x, y))
	pts.append(Vector2(WIDTH, HEIGHT))
	pts.append(Vector2(0, HEIGHT))
	return pts


func text(ci: CanvasItem, s: String, pos: Vector2, size: int, color: Color, centered := false) -> void:
	if centered:
		ci.draw_string(font, Vector2(pos.x - 1000, pos.y), s, HORIZONTAL_ALIGNMENT_CENTER, 2000, size, color)
	else:
		ci.draw_string(font, pos, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)


func _draw_overlay() -> void:
	if screen != "game":
		return
	var w := sim.world
	# Warned tiles shake and flash before they break.
	for pos in w.warnings:
		var coords := _tile_coords(pos.x, pos.y)
		if coords.x == -1:
			continue
		var left: float = w.warnings[pos] / Cfg.CRUMBLE_WARN
		var j := 2 if left < 0.6 else 1
		var flash := 0.5 + 0.5 * sin(time * 30.0)
		var dst := Rect2(pos.x * CELL + randi_range(-j, j), pos.y * CELL, CELL, CELL)
		overlay.draw_texture_rect_region(atlas, dst, Rect2(coords.x * CELL, coords.y * CELL, CELL, CELL))
		overlay.draw_rect(dst, Color(DANGER, 0.2 + 0.45 * (1.0 - left) * flash))
	_draw_zone()
	for p: Player in sim.players:
		if p.alive:
			_draw_mining(p)
	for p: Player in sim.players:
		if p.alive and p.grapple != null:
			overlay.draw_line(_draw_centre(p) * CELL, Vector2(p.grapple.x, p.grapple.y) * CELL, Color(0.86, 0.86, 0.9), 2.0)
	for p: Player in sim.players:
		if p.alive:
			_draw_player(p)
	for pr in sim.projectiles:
		var pos := Vector2(pr["x"], pr["y"]) * CELL
		overlay.draw_circle(pos, 7.0, sim.players[pr["owner"]].color)
		overlay.draw_circle(pos, 3.0, Color.WHITE)
	for b in sim.bombs:
		var pos := Vector2(b["x"], b["y"]) * CELL
		overlay.draw_circle(pos, 7.0, Color(0.12, 0.12, 0.16))
		overlay.draw_arc(pos, 7.0, 0, TAU, 16, sim.players[b["owner"]].color, 2.0)
		if int(b["fuse"] * (12 if b["fuse"] < 0.5 else 5)) % 2:
			overlay.draw_circle(pos + Vector2(5, -6), 3.0, Color(1.0, 0.86, 0.35))
	for b in sim.beams:
		var col: Color = sim.players[b["owner"]].color
		overlay.draw_line(b["from"] * CELL, b["to"] * CELL, col, 8.0)
		overlay.draw_line(b["from"] * CELL, b["to"] * CELL, Color.WHITE, 3.0)
	for p in particles:
		var fade := clampf(p[2] / 0.25, 0.0, 1.0)
		var col: Color = p[3]
		col.a *= fade
		var size := float(p[4]) * (0.5 + 0.5 * fade)
		overlay.draw_rect(Rect2(p[0] * CELL - Vector2(size, size) / 2.0, Vector2(size, size)), col)
	# Death edges: bottom, left, right.
	overlay.draw_rect(Rect2(0, Cfg.ROWS * CELL - 3, WIDTH, 3), DANGER)
	overlay.draw_rect(Rect2(0, 0, 3, Cfg.ROWS * CELL), DANGER)
	overlay.draw_rect(Rect2(WIDTH - 3, 0, 3, Cfg.ROWS * CELL), DANGER)


## Outside the arena is dark; between the arena edge and the zone edge is crumbling (red).
func _draw_zone() -> void:
	var w := sim.world
	var map_h := Cfg.ROWS * CELL
	var al := w.arena_left * CELL
	var ar := w.arena_right * CELL
	var shade := Color(0, 0, 0, 0.35)
	if al > 0:
		overlay.draw_rect(Rect2(0, 0, al, map_h), shade)
	if ar < WIDTH:
		overlay.draw_rect(Rect2(ar, 0, WIDTH - ar, map_h), shade)
	var zl := w.zone_left * CELL
	var zr := w.zone_right * CELL
	var started := w.zone_started()
	if started:
		var red := Color(DANGER, 0.18)
		if zl > al:
			overlay.draw_rect(Rect2(al, 0, zl - al, map_h), red)
		if zr < ar:
			overlay.draw_rect(Rect2(zr, 0, ar - zr, map_h), red)
	var line := Color(DANGER, 0.6 + 0.4 * sin(time * 8.0)) if started else Color(DANGER, 0.35)
	overlay.draw_rect(Rect2(zl - 1.5, 0, 3, map_h), line)
	overlay.draw_rect(Rect2(zr - 1.5, 0, 3, map_h), line)


## White at 0%, yellow at 60%, red at 120% and up.
func damage_color(d: float) -> Color:
	var yellow := Color(1.0, 0.85, 0.25)
	if d < 60.0:
		return Color.WHITE.lerp(yellow, clampf(d / 60.0, 0.0, 1.0))
	return yellow.lerp(DANGER, clampf((d - 60.0) / 60.0, 0.0, 1.0))


func _draw_player(p: Player) -> void:
	var at := draw_pos(p)
	var t := _target_at(p, at)
	if sim.world.solid(t.x, t.y) or p.blocks() > 0:
		overlay.draw_rect(Rect2(t.x * CELL, t.y * CELL, CELL, CELL), p.color, false, 2.0)
	var pos := at * CELL
	var w := Cfg.PLAYER_W * CELL
	_draw_character(p, at)
	if p.swing_t > 0:
		var c := _draw_centre(p) * CELL
		var a := Vector2(p.aim).angle()
		var alpha := clampf(p.swing_t / 0.12, 0.0, 1.0)
		var r := 1.3 * CELL
		overlay.draw_arc(c, r, a - 0.9, a + 0.9, 16, Color(Color.WHITE, alpha), 4.0)
		overlay.draw_arc(c, r - 3.0, a - 0.9, a + 0.9, 16, Color(p.color, alpha), 2.0)
	var tag := "P%d " % (p.index + 1)
	var pct := "%d%%" % int(p.damage)
	var tag_w := font.get_string_size(tag, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
	var pct_w := font.get_string_size(pct, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
	var sx := pos.x + w / 2.0 - (tag_w + pct_w) / 2.0
	text(overlay, tag, Vector2(sx, pos.y - 5), 14, p.color)
	text(overlay, pct, Vector2(sx + tag_w, pos.y - 5), 14, damage_color(p.damage))
	# "+Bomb" rising and fading above the tag for 0.8 s after a craft.
	if p.craft_t > 0 and Items.ITEMS.has(p.last_crafted):
		var rise := 20.0 * (1.0 - clampf(p.craft_t / 0.8, 0.0, 1.0))
		var alpha := clampf(p.craft_t / 0.4, 0.0, 1.0)
		var made: String = Items.ITEMS[p.last_crafted]["name"]
		text(overlay, "+" + made, Vector2(pos.x + w / 2.0, pos.y - 22 - rise), 16, Color(p.color, alpha), true)


## The block p targets as if standing at `at` (where it's drawn).
func _target_at(p: Player, at: Vector2) -> Vector2i:
	var real := Vector2(p.x, p.y)
	p.x = at.x
	p.y = at.y
	var t := p.target(sim.world, false)
	p.x = real.x
	p.y = real.y
	return t


## The little guy, drawn around his feet so squash and stretch keep him on the ground.
## Local coords: x right, y up is negative, (0, 0) between the feet. at: top-left, in tiles.
func _draw_character(p: Player, at: Vector2) -> void:
	var w := Cfg.PLAYER_W * CELL
	var h := Cfg.PLAYER_H * CELL
	var running: bool = p.on_ground and absf(p.vel_x) > 0.5
	var sx := 1.0
	var sy := 1.0
	if p.land_t > 0:
		var k := clampf(p.land_t / 0.12, 0.0, 1.0)
		sx += 0.3 * k
		sy -= 0.25 * k
	elif p.vy < -6.0:
		var k := clampf((-p.vy - 6.0) / 10.0, 0.0, 1.0)
		sx -= 0.15 * k
		sy += 0.15 * k
	var angle := 0.0
	if p.stun > 0:
		angle = clampf(p.vel_x * 0.03, -0.6, 0.6) + sin(time * 30.0) * 0.12 * clampf(p.stun * 3.0, 0.0, 1.0)
	elif running:
		angle = clampf(p.vel_x * 0.012, -0.1, 0.1)
	var grow := 1.18 if sim.hitstop > 0 and p.hurt_t > 0 else 1.0
	# Rotate about the middle of the body, scale from the feet.
	var centre := Vector2(at.x * CELL + w / 2.0, at.y * CELL + h / 2.0)
	overlay.draw_set_transform(centre + Vector2(0, h / 2.0).rotated(angle), angle, Vector2(sx, sy) * grow)

	var body := Color.WHITE if p.hurt_t > 0 else p.color
	var dark := body.darkened(0.35)
	var ph: float = run_phase.get(p.index, 0.0)
	var gait := sin(ph) if running else 0.0
	var bob := absf(gait) * 1.5
	var stride := cos(ph) * 2.5 * p.facing if running else 0.0
	overlay.draw_rect(Rect2(-7.0 + stride, -4.0 - maxf(0.0, gait) * 3.0, 6, 4), dark)
	overlay.draw_rect(Rect2(1.0 - stride, -4.0 - maxf(0.0, -gait) * 3.0, 6, 4), dark)

	var top := -h + 1.0 - bob
	var body_rect := Rect2(-w / 2.0, top, w, h - 4.0)
	_round_rect(body_rect, 5.0, dark)
	_round_rect(Rect2(body_rect.position, body_rect.size - Vector2(0, 3)), 5.0, body)
	overlay.draw_rect(Rect2(-w / 2.0 + 3.0, top + 3.0, 3, 2), body.lightened(0.45))

	# Eyes on the facing side, pupils toward the aim.
	var look := Vector2(p.aim).normalized()
	var ey := top + 7.0
	for ex: float in [p.facing * 2.5 - 3.5, p.facing * 2.5 + 3.5]:
		overlay.draw_rect(Rect2(ex - 2.0, ey, 4, 5), Color.WHITE)
		overlay.draw_rect(Rect2(ex - 1.0 + look.x, ey + 1.0 + look.y * 1.2, 2, 3), Color.BLACK)

	# Pickaxe in the facing hand.
	var hand := Vector2(p.facing * 7.0, -14.0 - bob)
	var a := _pick_angle(p, centre + Vector2(p.facing * 7.0, 2.0))
	var dir := Vector2(cos(a) * p.facing, sin(a))
	var perp := Vector2(-dir.y, dir.x)
	var tip := hand + dir * 11.0
	overlay.draw_line(hand - dir * 2.0, tip, PICK_HANDLE, 2.0)
	var head := PackedVector2Array([tip + perp * 6.0 - dir * 2.5, tip + perp * 2.5, tip - perp * 2.5, tip - perp * 6.0 - dir * 2.5])
	overlay.draw_polyline(head, PICK_HEAD.darkened(0.45), 4.0)
	overlay.draw_polyline(head, PICK_HEAD, 2.0)
	overlay.draw_circle(hand, 2.5, dark)
	overlay.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## Pickaxe angle as if facing right (0 = forward, -PI/2 = up): a fast arc while swinging,
## chopping at the mine target while mining, otherwise held up and ready.
func _pick_angle(p: Player, hand: Vector2) -> float:
	if p.swing_t > 0:
		var k := 1.0 - clampf(p.swing_t / 0.12, 0.0, 1.0)
		var aim_a := atan2(float(p.aim.y), absf(p.aim.x))
		return aim_a - 1.8 + 2.4 * k
	var mt: Vector2i = p.mine_target
	if p.mine_progress > 0 and mt.x >= 0:
		var rel := (Vector2(mt) + Vector2(0.5, 0.5)) * CELL - hand
		var ta := atan2(rel.y, absf(rel.x))
		return ta - 0.15 - 0.85 * (0.5 + 0.5 * sin(time * 22.0))
	return -1.0 + sin(time * 2.5 + p.index) * 0.06


func _round_rect(r: Rect2, rad: float, c: Color) -> void:
	overlay.draw_rect(r.grow_individual(-rad, 0, -rad, 0), c)
	overlay.draw_rect(r.grow_individual(0, -rad, 0, -rad), c)
	for corner: Vector2 in [r.position + Vector2(rad, rad), Vector2(r.end.x - rad, r.position.y + rad),
			Vector2(r.position.x + rad, r.end.y - rad), r.end - Vector2(rad, rad)]:
		overlay.draw_circle(corner, rad, c)


## Cracks that grow in stages over the block being mined, and a progress bar under it.
func _draw_mining(p: Player) -> void:
	var mt: Vector2i = p.mine_target
	var progress: float = clampf(p.mine_progress, 0.0, 1.0)
	if progress <= 0.0 or mt.x < 0 or not sim.world.solid(mt.x, mt.y):
		return
	var o := Vector2(mt) * CELL
	var stages := clampi(ceili(progress * CRACKS.size()), 1, CRACKS.size())
	var pts := PackedVector2Array()
	for s in stages:
		for pt: Vector2 in CRACKS[s]:
			pts.append(o + pt)
	overlay.draw_rect(Rect2(o, Vector2(CELL, CELL)), Color(0, 0, 0, 0.06 * stages))
	overlay.draw_multiline(pts, Color(0.08, 0.06, 0.1, 0.9), 2.0)
	var bar := Rect2(o.x + 2.0, o.y + CELL + 2.0, CELL - 4.0, 3.0)
	overlay.draw_rect(bar.grow(1.0), Color(0, 0, 0, 0.6))
	overlay.draw_rect(Rect2(bar.position, Vector2(bar.size.x * progress, bar.size.y)), p.color)


func _draw_hud() -> void:
	match screen:
		"title": _draw_title()
		"join": _draw_join()
		"lobby": _draw_lobby()
		"game": _draw_game_hud()


func _labels_for(i: int) -> Array:
	if mode == "local" and i < local_sources.size():
		var src = local_sources[i]
		var key: String = "pad" if src is int else src
		return [SLOT_LABELS[key], CRAFT_LABELS[key]]
	return [SLOT_LABELS["p1_mouse"], CRAFT_LABELS["p1_mouse"]]


func _draw_game_hud() -> void:
	hud.draw_rect(Rect2(0, 0, WIDTH, HUD_H), PANEL)
	var slot_w := WIDTH / maxi(4, sim.players.size())
	for p: Player in sim.players:
		var x: int = 10 + p.index * slot_w
		var you: bool = (mode == "client" and p.index == my_index) or (mode == "host" and p.index == 0)
		# Name, with "you"/"out" under it so the damage % fits beside it.
		text(hud, "P%d" % (p.index + 1), Vector2(x, 26), 20, p.color if p.alive else DIM)
		if not p.alive:
			text(hud, "out", Vector2(x + 2, 44), 14, DIM)
		elif you:
			text(hud, "you", Vector2(x + 2, 44), 12, DIM)
		text(hud, "%d%%" % int(p.damage), Vector2(x + 30, 27), 22, damage_color(p.damage) if p.alive else DIM)
		if p.kos > 0:
			text(hud, "KO %d" % p.kos, Vector2(x + 32, 44), 12, INK)
		for r in Cfg.ROUNDS_TO_WIN:
			var c := Vector2(x + 7 + r * 15, 54)
			if r < p.wins:
				hud.draw_circle(c, 5.0, p.color)
			else:
				hud.draw_arc(c, 5.0, 0, TAU, 12, p.color, 2.0)
		var col: int = x + 88
		var full: bool = p.blocks() >= Cfg.CARRY_LIMIT
		for n in Items.MATERIALS.size():
			var m: String = Items.MATERIALS[n]
			var mx: int = col + n * 46
			hud.draw_rect(Rect2(mx, 9, 12, 12), Items.MATERIAL_COLORS[m])
			text(hud, str(p.inv[m]), Vector2(mx + 16, 20), 15, DANGER if full and (m == "dirt" or m == "stone") else INK)
		var labels := _labels_for(p.index)
		for s in Cfg.SLOTS:
			var r := Rect2(col + s * 36, 28, 32, 32)
			hud.draw_rect(r, SLOT_BG)
			var item = p.slots[s]
			if item != null:
				Items.draw_icon(hud, item["item"], r.grow(-5).grow_individual(-2, -2, 2, 2), p.color)
				text(hud, str(item["charges"]), Vector2(r.end.x - 9, r.end.y - 3), 13, INK)
				if p.item_cd > 0:
					hud.draw_rect(r, Color(0, 0, 0, 0.55))
				hud.draw_rect(r, p.color, false, 1.0)
			text(hud, labels[0][s], Vector2(r.position.x + 3, r.position.y + 11), 11, DIM)
		var hx: int = col + Cfg.SLOTS * 36 + 4
		_draw_craft_hint(p, str(labels[1]), hx, x + slot_w - 6 - hx)

	# Kill feed, newest last.
	for i in sim.feed.size():
		var line: Array = sim.feed[i]
		var ttl: float = line[1]
		text(hud, str(line[0]), Vector2(WIDTH / 2.0, HUD_H + 26 + i * 24), 18, Color(INK, clampf(ttl, 0.0, 1.0)), true)

	var me := _my_player()
	if me and sim.state in ["intro", "play", "outro"] and Input.mouse_mode == Input.MOUSE_MODE_HIDDEN:
		var m := get_global_mouse_position()
		hud.draw_arc(m, 9.0, 0, TAU, 20, Color.BLACK, 3.0)
		hud.draw_arc(m, 8.0, 0, TAU, 20, me.color, 2.0)
		for d in [Vector2.RIGHT, Vector2.LEFT, Vector2.UP, Vector2.DOWN]:
			hud.draw_line(m + d * 4, m + d * 12, me.color, 2.0)

	if sim.hitstop > 0:
		hud.draw_rect(Rect2(0, 0, WIDTH, HEIGHT), Color(1, 1, 1, 0.08))

	match sim.state:
		"intro": _banner("Round %d" % sim.round_no, "Hit players to raise their %. Higher % = they fly farther. Knock them out!")
		"outro": _banner(sim.message, "   ".join(sim.players.map(func(p): return "P%d: %d" % [p.index + 1, p.wins])) + "   (first to %d)" % Cfg.ROUNDS_TO_WIN)
		"match_over":
			var sub := "Enter = rematch    Esc = menu"
			if mode == "client" and not dedicated:
				sub = "Waiting for the host    Esc = leave"
			var stats: Array = []
			for p: Player in sim.players:
				var s := "P%d   %d KO%s   %d fall%s   %d%% dealt" % [p.index + 1, p.kos, "" if p.kos == 1 else "s",
					p.falls, "" if p.falls == 1 else "s", int(p.dealt)]
				stats.append([s, p.color])
			_banner(sim.message, sub, stats)


## lines: [text, color] pairs shown between the title and the subtitle.
func _banner(title: String, sub: String, lines: Array = []) -> void:
	var extra := lines.size() * 30 + (10 if lines.size() > 0 else 0)
	var top := HEIGHT / 2.0 - 80 - extra / 2.0
	hud.draw_rect(Rect2(0, top, WIDTH, 160 + extra), Color(0, 0, 0, 0.6))
	text(hud, title, Vector2(WIDTH / 2.0, top + 85), 60, INK, true)
	for i in lines.size():
		var line: Array = lines[i]
		var c: Color = line[1]
		text(hud, str(line[0]), Vector2(WIDTH / 2.0, top + 128 + i * 30), 20, c, true)
	text(hud, sub, Vector2(WIDTH / 2.0, top + 130 + extra), 20, DIM, true)


func _text_w(s: String, size: int) -> float:
	return font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x


## Shortens s with ".." until it is at most max_w pixels wide.
func _clip(s: String, size: int, max_w: float) -> String:
	if _text_w(s, size) <= max_w:
		return s
	var cut := s
	while cut.length() > 1 and _text_w(cut + "..", size) > max_w:
		cut = cut.left(cut.length() - 1)
	return cut.strip_edges() + ".."


## What one press of the craft key makes, squeezed into max_w pixels right of the item slots.
func _draw_craft_hint(p: Player, key_label: String, hx: int, max_w: int) -> void:
	var lead := key_label + ": "
	var lead_w := _text_w(lead, 13)
	var best: String = Items.best_affordable(p.inv)
	if best != "":
		var item_name: String = Items.ITEMS[best]["name"]
		text(hud, lead, Vector2(hx, 50), 13, DIM)
		if lead_w + 18 + _text_w(item_name, 13) <= max_w:
			Items.draw_icon(hud, best, Rect2(hx + lead_w, 37, 16, 16), p.color)
			text(hud, item_name, Vector2(hx + lead_w + 18, 50), 13, p.color)
		else:
			text(hud, _clip(item_name, 13, max_w - lead_w), Vector2(hx + lead_w, 50), 13, p.color)
		return
	var goal: String = Items.next_goal(p.inv)
	if goal == "":
		text(hud, _clip(lead + "craft", 13, max_w), Vector2(hx, 50), 13, DIM)
		return
	var goal_name: String = Items.ITEMS[goal]["name"]
	var missing: String = Items.missing_text(goal, p.inv)
	var one_line := "%s%s - %s" % [lead, goal_name, missing]
	if _text_w(one_line, 13) <= max_w:
		text(hud, one_line, Vector2(hx, 50), 13, DIM)
		return
	# Too wide for one line: item on top, what's missing under it (smaller, "need " dropped if that helps).
	text(hud, _clip(lead + goal_name, 13, max_w), Vector2(hx, 42), 13, DIM)
	if _text_w(missing, 11) > max_w and missing.begins_with("need "):
		missing = missing.substr(5)
	text(hud, _clip(missing, 11, max_w), Vector2(hx, 57), 11, DIM)


func _draw_title() -> void:
	var cx := WIDTH / 2.0
	text(hud, "ARENA (working title)", Vector2(cx, 100), 64, INK, true)
	text(hud, "Mine blocks and ore, craft items, and don't fall out of the map.", Vector2(cx, 145), 22, DIM, true)
	text(hud, "Hits raise damage %: the higher it is, the farther you fly. The edges crumble inward.", Vector2(cx, 175), 22, DIM, true)
	var options := "J = join an online game     2 / 3 / 4 = local players on this device"
	if not OS.has_feature("web"):
		options = "H = host an online game     " + options
	text(hud, options, Vector2(cx, 235), 22, INK, true)
	var lines := [
		"Controls:  A/D move   W or Space jump   hold left-click: mine / click a player: hit   right-click place",
		"Q/E/R items   F craft   the mouse picks the block within reach",
		"Local P2:  J/L move   I jump   K aim down   hold U: mine / hit   O place   7/8/9 items   H craft",
		"Controller:  stick move   A jump   right stick aim   hold RT: mine / hit   LT place   X/Y/B items   RB craft",
		"Craft: one press makes the best item you can afford (shown on your HUD).   M = mute",
	]
	for i in lines.size():
		text(hud, lines[i], Vector2(cx, 280 + i * 24), 15, DIM, true)
	for i in Items.RECIPES.size():
		var key: String = Items.RECIPES[i]
		var item: Dictionary = Items.ITEMS[key]
		var rx := cx - 320
		var ry := 410 + i * 34
		var r := Rect2(rx, ry, 28, 28)
		hud.draw_rect(r, SLOT_BG)
		Items.draw_icon(hud, key, r.grow(-3), INK)
		var uses := "%d use%s" % [item["charges"], "" if item["charges"] == 1 else "s"]
		text(hud, item["name"], Vector2(rx + 38, ry + 20), 16, INK)
		text(hud, "%s (%s)" % [item["help"], uses], Vector2(rx + 160, ry + 20), 16, DIM)
		text(hud, Items.cost_text(key), Vector2(rx + 460, ry + 20), 16, DIM)
	if notice:
		text(hud, notice, Vector2(cx, HEIGHT - 40), 20, DANGER, true)


func _draw_join() -> void:
	var cx := WIDTH / 2.0
	text(hud, "Join a game", Vector2(cx, 200), 56, INK, true)
	text(hud, "Type a friend's IP (Tailscale works best) or a server name like arena.tylergunn.me, then Enter.", Vector2(cx, 250), 20, DIM, true)
	text(hud, "Example: 100.101.102.103  (port %d is added for you)     Esc = back" % Cfg.NET_PORT, Vector2(cx, 400), 16, DIM, true)
	if notice:
		text(hud, notice, Vector2(cx, 460), 20, DANGER, true)


func _draw_lobby() -> void:
	var cx := WIDTH / 2.0
	var count := 0
	var me := -1
	if _hosting():
		count = lobby_peers.size() + _offset()
		me = 0 if mode == "host" else -1
		text(hud, "Hosting" if mode == "host" else "Dedicated server", Vector2(cx, 120), 56, INK, true)
		text(hud, "Friends press J and type your address (port %d). Tailscale works best." % Cfg.NET_PORT, Vector2(cx, 165), 20, DIM, true)
		var ips := Array(IP.get_local_addresses()).filter(func(a): return "." in a and not a.begins_with("127.") and not a.begins_with("169.254"))
		text(hud, "Your addresses:  " + "   ".join(ips), Vector2(cx, 195), 18, INK, true)
	else:
		count = lobby_size
		me = my_index
		text(hud, "Connected" if lobby_size else "Connecting...", Vector2(cx, 120), 56, INK, true)
		if lobby_size:
			text(hud, "You are P%d" % (my_index + 1), Vector2(cx, 165), 20, DIM, true)
	for i in count:
		var r := Rect2(cx - 150, 230 + i * 44, 300, 36)
		var color: Color = Cfg.PLAYER_COLORS[i]
		hud.draw_rect(r, PANEL)
		hud.draw_rect(r, color, false, 2.0)
		var who := "you" if i == me else ("host" if i == 0 and (mode == "host" or (mode == "client" and not dedicated)) else "joined")
		text(hud, "P%d  %s" % [i + 1, who], Vector2(r.position.x + 14, r.position.y + 25), 20, color)
	var hint := "Esc = leave"
	if mode == "host":
		hint = "Enter = start   Esc = stop hosting"
	elif mode == "client" and dedicated:
		hint = "Enter = start (needs 2+)   Esc = leave"
	elif mode == "client":
		hint = "Waiting for the host to start   Esc = leave"
	text(hud, hint, Vector2(cx, 430), 22, INK, true)
	if notice:
		text(hud, notice, Vector2(cx, 480), 20, DANGER, true)

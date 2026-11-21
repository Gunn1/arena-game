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
var particles: Array = []         # [pos, vel, life, color, size]
var shown_version := -1
var wheel := 0
var local_sources: Array = []     # local mode: per player "p1_mouse", "p2_keys" or a joypad id
var match_size := 2

# Networking
var peer: WebSocketMultiplayerPeer
var lobby_peers: Array = []       # host/server: peer ids, in join order
var peer_index := {}              # peer id -> player index in the current match
var remote := {}                  # peer id -> {"state": {}, "pending": [], "wheel": 0}
var my_index := 0                 # client: which player I am
var lobby_size := 0
var dedicated := false            # client: the host is a dedicated server
var sent_version := -1

# Test hooks (command line)
var bot := false
var quit_after := 0.0
var print_hash := false
var autostart := 0


func _ready() -> void:
	font = ThemeDB.fallback_font
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
	if "--server" in args:
		host_game(true, port)
		print("Dedicated server listening on port %d" % port)
	elif "--join" in args:
		join_game(_arg(args, "--join", "127.0.0.1"))


func _arg(args: PackedStringArray, flag: String, fallback: String) -> String:
	var i := args.find(flag)
	return args[i + 1] if i != -1 and i + 1 < args.size() else fallback


# --- tiles -----------------------------------------------------------------------------

# Atlas rows (each has 4 speck variants as columns).
enum { R_DIRT, R_GRASS, R_STONE, R_STONE_CRACK, R_PLACED, R_COPPER, R_COPPER_CRACK, R_CRYSTAL, R_CRYSTAL_CRACK }


func _build_tileset() -> TileSet:
	var rows := [[World.DIRT, false, false], [World.DIRT, true, false], [World.STONE, false, false],
		[World.STONE, false, true], [World.PLACED, false, false], [World.COPPER, false, false],
		[World.COPPER, false, true], [World.CRYSTAL, false, false], [World.CRYSTAL, false, true]]
	var img := Image.create_empty(CELL * 4, CELL * rows.size(), false, Image.FORMAT_RGBA8)
	for r in rows.size():
		for speck in 4:
			_paint_tile(img, speck * CELL, r * CELL, rows[r][0], speck, rows[r][1], rows[r][2])
	var src := TileSetAtlasSource.new()
	src.texture = ImageTexture.create_from_image(img)
	src.texture_region_size = Vector2i(CELL, CELL)
	for r in rows.size():
		for c in 4:
			src.create_tile(Vector2i(c, r))
	var ts := TileSet.new()
	ts.tile_size = Vector2i(CELL, CELL)
	ts.add_source(src, 0)
	return ts


func _paint_tile(img: Image, ox: int, oy: int, tile: int, speck: int, grass: bool, cracked: bool) -> void:
	var base: Color = TILE_COLORS[tile]
	img.fill_rect(Rect2i(ox, oy, CELL, CELL), base)
	img.fill_rect(Rect2i(ox + speck * 4 + 2, oy + ((speck * 7) % 4) * 4 + 2, 4, 4), base.darkened(0.2))
	if ORE_COLORS.has(tile):
		var ore: Color = ORE_COLORS[tile]
		for p in [Vector2i(4, 5), Vector2i(12, 3), Vector2i(9, 12), Vector2i(14, 14)]:
			img.fill_rect(Rect2i(ox + p.x, oy + p.y, 4, 4), ore)
		img.fill_rect(Rect2i(ox + 12, oy + 3, 2, 2), ore.lightened(0.5))
	elif tile == World.PLACED:
		var edge := base.darkened(0.35)
		img.fill_rect(Rect2i(ox, oy, CELL, 2), edge)
		img.fill_rect(Rect2i(ox, oy + CELL - 2, CELL, 2), edge)
		img.fill_rect(Rect2i(ox, oy, 2, CELL), edge)
		img.fill_rect(Rect2i(ox + CELL - 2, oy, 2, CELL), edge)
		img.fill_rect(Rect2i(ox, oy + CELL / 2, CELL, 1), edge)
	if grass:
		img.fill_rect(Rect2i(ox, oy, CELL, 6), GRASS)
		img.fill_rect(Rect2i(ox, oy, CELL, 2), GRASS_LIGHT)
	if cracked:
		var dark := Color(0.2, 0.2, 0.25)
		for seg in [[Vector2(4, 3), Vector2(9, 9)], [Vector2(9, 9), Vector2(7, 14)], [Vector2(7, 14), Vector2(13, 18)], [Vector2(9, 9), Vector2(16, 6)]]:
			for k in 9:
				var p: Vector2 = seg[0].lerp(seg[1], k / 8.0)
				img.fill_rect(Rect2i(ox + int(p.x), oy + int(p.y), 2, 2), dark)


func _atlas_row(x: int, y: int) -> int:
	var w := sim.world
	var t := w.get_tile(x, y)
	if t == World.EMPTY or w.warnings.has(Vector2i(x, y)):
		return -1                                  # warned tiles are drawn shaking by the overlay
	var cracked := w.cracked.has(Vector2i(x, y))
	match t:
		World.DIRT: return R_DIRT if w.solid(x, y - 1) else R_GRASS
		World.STONE: return R_STONE_CRACK if cracked else R_STONE
		World.PLACED: return R_PLACED
		World.COPPER: return R_COPPER_CRACK if cracked else R_COPPER
		World.CRYSTAL: return R_CRYSTAL_CRACK if cracked else R_CRYSTAL
	return -1


func _set_cell(x: int, y: int) -> void:
	if not sim.world.in_bounds(x, y):
		return
	var row := _atlas_row(x, y)
	if row == -1:
		tiles.erase_cell(Vector2i(x, y))
	else:
		tiles.set_cell(Vector2i(x, y), 0, Vector2i((x * 73856093 ^ y * 19349663) & 3, row))


## Only redraw tiles that changed (plus the tile below, whose grass depends on it).
func _refresh_tiles() -> void:
	var w := sim.world
	if w.version != shown_version:
		shown_version = w.version
		tiles.clear()
		for y in Cfg.ROWS:
			for x in Cfg.COLS:
				_set_cell(x, y)
	else:
		for pos in w.dirty:
			_set_cell(pos.x, pos.y)
			_set_cell(pos.x, pos.y + 1)
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


func _remote_input(peer_id: int) -> Dictionary:
	var r: Dictionary = remote.get(peer_id, {})
	if r.is_empty():
		return {}
	var out: Dictionary = r["state"].duplicate()
	if r["pending"]:
		r["state"] = r["pending"][-1]
		out = r["state"].duplicate()
		# Several input frames can arrive between two of ours: keep any button pressed in one of them.
		for s in r["pending"]:
			for k in s:
				if s[k] is bool and s[k]:
					out[k] = true
		r["pending"] = []
	out["wheel"] = r["wheel"]
	r["wheel"] = 0
	return out


func _bot_input() -> Dictionary:
	# Test client: walk right for a second, then hold left, jumping now and then, mining as it goes.
	var t := sim.tick % 240
	return {"right": t < 60, "left": t >= 120 and t < 180, "jump": t % 50 == 0, "mine": true,
		"up": false, "down": false, "place": false, "item1": false, "item2": false, "item3": false, "craft": false}


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
	notice = "Connecting to %s ..." % url
	lobby_size = 0
	address_edit.visible = false
	address_edit.release_focus()


func _url_for(address: String) -> String:
	if "://" in address:
		return address
	if not ":" in address:
		address += ":%d" % Cfg.NET_PORT
	var secure := OS.has_feature("web") and str(JavaScriptBridge.eval("location.protocol")) == "https:"
	return ("wss://" if secure else "ws://") + address


func leave_online(msg: String) -> void:
	if peer:
		peer.close()
	peer = null
	multiplayer.multiplayer_peer = null
	mode = "local"
	lobby_peers = []
	remote = {}
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
	remote[id] = {"state": {}, "pending": [], "wheel": 0}
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
		remote[id]["pending"].append(state)
		remote[id]["wheel"] += int(state.get("wheel", 0))


@rpc("authority", "call_remote", "reliable")
func rpc_lobby(you: int, count: int, is_dedicated: bool) -> void:
	my_index = you
	lobby_size = count
	dedicated = is_dedicated
	notice = ""


@rpc("authority", "call_remote", "reliable")
func rpc_grid(d: Dictionary) -> void:
	sim.apply_grid(d)
	particles.clear()


@rpc("authority", "call_remote", "reliable")
func rpc_snap(d: Dictionary) -> void:
	screen = "game"
	_play_events(sim.apply_snapshot(d))
	if print_hash and sim.tick % 60 == 0:
		print("HASH %d %s" % [sim.tick, sim.world.grid.hex_encode().md5_text()])


# --- frame loop -----------------------------------------------------------------------

func _physics_process(_delta: float) -> void:
	if quit_after > 0 and time > quit_after:
		get_tree().quit()
	if mode == "client":
		if screen == "game" and sim.state in ["intro", "play", "outro"] and peer \
				and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
			rpc_input.rpc_id(1, _my_input())
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
		for p in particles:
			p[0] += p[1] * delta
			p[1].y += 30.0 * delta
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
		particles.append([pos, Vector2(cos(a) * s, sin(a) * s - up), randf_range(0.5, 1.0) * life, color, size])


func _drain_debris() -> void:
	var crumbled := false
	for b in sim.world.broken:
		var color: Color = ORE_COLORS.get(b[2], TILE_COLORS.get(b[2], Color.WHITE))
		for i in 5:
			particles.append([Vector2(b[0] + randf_range(0.2, 0.8), b[1] + randf_range(0.2, 0.8)),
				Vector2(randf_range(-3, 3), randf_range(-7, -2)), randf_range(0.3, 0.6), color, [3, 4, 5].pick_random()])
		crumbled = crumbled or b[3] == "crumble"
	sim.world.broken.clear()
	if crumbled:
		sfx.play("crumble", 0.06)


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
		var t := w.get_tile(pos.x, pos.y)
		if t == World.EMPTY:
			continue
		var left: float = w.warnings[pos] / Cfg.CRUMBLE_WARN
		var j := 2 if left < 0.6 else 1
		var flash := 0.5 + 0.5 * sin(time * 30.0)
		var c: Color = TILE_COLORS[t].lerp(DANGER, 0.25 + 0.5 * (1.0 - left) * flash)
		overlay.draw_rect(Rect2(pos.x * CELL + randi_range(-j, j), pos.y * CELL, CELL, CELL), c)
	_draw_zone()
	for p: Player in sim.players:
		if p.alive and p.grapple != null:
			overlay.draw_line(p.centre() * CELL, Vector2(p.grapple.x, p.grapple.y) * CELL, Color(0.86, 0.86, 0.9), 2.0)
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
		overlay.draw_rect(Rect2(p[0] * CELL - Vector2(p[4], p[4]) / 2.0, Vector2(p[4], p[4])), p[3])
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
	var t := p.target(sim.world, false)
	if sim.world.solid(t.x, t.y) or p.blocks() > 0:
		overlay.draw_rect(Rect2(t.x * CELL, t.y * CELL, CELL, CELL), p.color, false, 2.0)
	var pos := Vector2(p.x, p.y) * CELL
	var w := Cfg.PLAYER_W * CELL
	var h := Cfg.PLAYER_H * CELL
	var body := Color.WHITE if p.hurt_t > 0 else p.color
	overlay.draw_rect(Rect2(pos + Vector2(0, 3), Vector2(w, h - 3)), body.darkened(0.35))
	overlay.draw_rect(Rect2(pos, Vector2(w, h - 4)), body)
	var eye_x := pos.x + w / 2.0 + p.facing * 3
	for ex in [eye_x - 4, eye_x + 3]:
		overlay.draw_rect(Rect2(ex - 2, pos.y + 6, 4, 6), Color.WHITE)
		overlay.draw_rect(Rect2(ex - 1 + p.facing, pos.y + 8, 2, 3), Color.BLACK)
	if p.swing_t > 0:
		var c := p.centre() * CELL
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
		"Controls:  A/D move   W or Space jump   mouse aims   left-click hit / mine   right-click place   Q/E/R items   F craft",
		"Local P2:  J/L move   I jump   K aim down   U hit/mine   O place   7/8/9 items   H craft",
		"Controller:  stick move   A jump   right stick aim   RT hit/mine   LT place   X/Y/B items   RB craft",
		"Craft: one press makes the best item you can afford (shown on your HUD).   M = mute",
	]
	for i in lines.size():
		text(hud, lines[i], Vector2(cx, 290 + i * 26), 15, DIM, true)
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
	text(hud, "Type the host's address (their Tailscale IP, or a server address), then press Enter.", Vector2(cx, 250), 20, DIM, true)
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

## The game rules: rounds, items, projectiles and bombs. No drawing, sound or input here:
## sounds and particle bursts are queued in `events` for whoever is showing the game.
## The host (or a local game) runs this; online clients only apply snapshots of it.
class_name GameSim
extends RefCounted

var world := World.new()
var players: Array = []           # Player
var projectiles: Array = []       # {x, y, dir, dist, owner}
var bombs: Array = []             # {x, y, vx, vy, fuse, owner}
var beams: Array = []             # {from, to, owner, time}
var events: Array = []            # ["snd", name, min_gap] / ["pt", pos, color, count, speed, life, size, up]
var state := "intro"              # intro, play, outro, match_over
var timer := 0.0
var round_no := 0
var message := ""
var shake := 0.0
var tick := 0
var round_time := 0.0             # seconds since this round's "go" (for KO credit)
var feed: Array = []              # [text, ttl] kill feed lines
var hitstop := 0.0                # > 0: the whole game is frozen for a moment after a hit
# Online the sim must never freeze: clients predict through it and queued inputs would be lost.
# With freeze_on_hit off, a hit sets hit_flash instead: the same impact look, nothing stops.
var freeze_on_hit := true
var hit_flash := 0.0              # > 0: draw the impact (hit player enlarged, white flash); decays
var rng := RandomNumberGenerator.new()
# Lag compensation (host): where everyone was over the last REWIND_KEEP ticks, so a remote
# player's swing is tested against what they saw. view = the tick the input being applied was
# drawn at (-1: no rewind, e.g. local players and the host's own).
const REWIND_KEEP := 60
const REWIND_MAX := 18            # never rewind more than 300 ms
var past: Array = []              # [tick, [Vector2 top-left per player]], oldest first
var view := -1.0
var acks: Array = []              # host: per player, seq of the last input applied (sent in snapshots)


func _init() -> void:
	rng.randomize()
	world.occupied = player_in_tile               # falling sand stops above players


func sound(name: String, min_gap := 0.0) -> void:
	events.append(["snd", name, min_gap])


func burst(pos: Vector2, color: Color, count: int, speed: float, life := 0.6, size := 4, up := 0.0) -> void:
	events.append(["pt", pos, color, count, speed, life, size, up])


func add_feed(text: String) -> void:
	feed.append([text, 3.0])


# --- match flow ----------------------------------------------------------------------

func start_match(count: int) -> void:
	players = []
	for i in count:
		players.append(Player.new(i))
	round_no = 0
	feed.clear()
	hitstop = 0.0
	hit_flash = 0.0
	new_round()


func new_round() -> void:
	round_no += 1
	var g0 := Time.get_ticks_usec()
	world.generate(rng.randi(), players.size())
	var g_ms := (Time.get_ticks_usec() - g0) / 1000
	if g_ms > 30:
		print("[perf] map generation took %d ms" % g_ms)
	for i in players.size():
		players[i].spawn(world.spawns[i].x, world.spawns[i].y)
	projectiles.clear()
	bombs.clear()
	beams.clear()
	past.clear()                                 # everyone respawned: no rewinding into last round
	round_time = 0.0
	state = "intro"
	timer = Cfg.ROUND_INTRO


func alive_count() -> int:
	return players.filter(func(p): return p.alive).size()


func end_round() -> void:
	var alive := players.filter(func(p): return p.alive)
	if alive:
		alive[0].wins += 1
		message = "P%d wins the round" % (alive[0].index + 1)
		sound("round")
	else:
		message = "Draw: nobody scores"
	state = "outro"
	timer = Cfg.ROUND_OUTRO


## One fixed step. inputs[i] is player i's input Dictionary.
func update(dt: float, inputs: Array) -> void:
	tick += 1
	shake = maxf(0.0, shake - dt)
	for line in feed:
		line[1] -= dt
	feed = feed.filter(func(line): return line[1] > 0)
	hit_flash = maxf(0.0, hit_flash - dt)
	if hitstop > 0:
		hitstop -= dt
		return
	if state == "intro":
		timer -= dt
		if timer <= 0:
			state = "play"
			sound("go")
		return
	if state != "play" and state != "outro":
		return
	round_time += dt

	world.update(dt)
	for i in players.size():
		var p: Player = players[i]
		if p.alive:
			var inp: Dictionary = inputs[i] if i < inputs.size() else {}
			view = float(inp.get("view", -1.0))
			world.actor = i                          # TNT this player sets off is theirs
			p.update(dt, inp, self)
			view = -1.0
			if not p.alive:
				_on_death(p)
	_log_positions()
	_update_projectiles(dt)
	_update_bombs(dt)
	_light_tnt()
	for b in beams:
		b["time"] -= dt
	beams = beams.filter(func(b): return b["time"] > 0)

	if state == "play" and alive_count() <= 1:
		end_round()
	elif state == "outro":
		timer -= dt
		if timer <= 0:
			var best: Player = players[0]
			for p: Player in players:
				if p.wins > best.wins:
					best = p
			if best.wins >= Cfg.ROUNDS_TO_WIN:
				state = "match_over"
				message = "P%d wins the match!" % (best.index + 1)
			else:
				new_round()


func _on_death(p: Player) -> void:
	if p.last_hit_by >= 0 and round_time - p.last_hit_at <= Cfg.KILL_CREDIT:
		var killer: Player = players[p.last_hit_by]
		killer.kos += 1
		add_feed("P%d knocked out P%d" % [killer.index + 1, p.index + 1])
	else:
		p.falls += 1
		add_feed("P%d fell" % (p.index + 1))
	var c := p.centre()
	c.x = clampf(c.x, 0.5, Cfg.COLS - 0.5)
	c.y = minf(c.y, Cfg.ROWS - 0.5)
	burst(c, p.color, 40, 14.0, 0.9, 6, 6.0)
	burst(c, Color.WHITE, 12, 8.0, 0.5, 3, 4.0)
	sound("death")
	shake = 0.35


func player_in_tile(tx: int, ty: int) -> bool:
	for p: Player in players:
		if p.alive and p.overlaps_tile(tx, ty):
			return true
	return false


# --- fighting ------------------------------------------------------------------------

## Alive players (not p) inside the swing box in front of p, along the exact (unsnapped) aim.
## While a remote player's input is applied (view >= 0), the others are where that player saw them.
func swing_targets(p: Player) -> Array:
	var c := p.centre() + p.aim_vec * Cfg.SWING_REACH
	var box := Rect2(c - Cfg.SWING_BOX / 2.0, Cfg.SWING_BOX)
	var out := []
	for o: Player in players:
		var at := Vector2(o.x, o.y) if view < 0.0 else pos_at(o.index, view)
		if o.alive and o != p and box.intersects(Rect2(at, Vector2(Cfg.PLAYER_W, Cfg.PLAYER_H))):
			out.append(o)
	return out


## Host: remember where everyone is this tick, for rewinding remote swings.
func _log_positions() -> void:
	past.append([tick, players.map(func(o: Player) -> Vector2: return Vector2(o.x, o.y))])
	if past.size() > REWIND_KEEP:
		past = past.slice(past.size() - REWIND_KEEP)


## Player i's top-left at tick `at` (fractions blend neighbouring ticks), clamped to what's
## remembered and to REWIND_MAX ticks back. Newer than the last log: where they are now.
func pos_at(i: int, at: float) -> Vector2:
	var now := Vector2(players[i].x, players[i].y)
	at = clampf(at, tick - REWIND_MAX, tick)
	if past.is_empty() or at >= float(past[-1][0]):
		return now
	if at <= float(past[0][0]):
		return past[0][1][i]
	for k in range(past.size() - 1, 0, -1):
		var a: Array = past[k - 1]
		if float(a[0]) <= at:
			var b: Array = past[k]
			var span := float(b[0]) - float(a[0])
			return (a[1][i] as Vector2).lerp(b[1][i], 0.0 if span <= 0.0 else (at - float(a[0])) / span)
	return now


## Launch direction for a swing aimed at `aim`: down spikes, sideways hits lift a bit.
static func knock_dir(aim: Vector2) -> Vector2:
	if aim.y > 0:
		return aim.normalized()
	if aim.x == 0:
		return Vector2(0, -1)
	return Vector2(aim.x, minf(aim.y, 0.0) - 0.4).normalized()


func melee(p: Player, victims: Array) -> void:
	var dir := knock_dir(Vector2(p.aim))
	for v: Player in victims:
		hit_player(v, p, dir, Cfg.SWING_DAMAGE, Cfg.SWING_KNOCK)
	p.swing_t = 0.12
	sound("swing")


## Add damage %, then launch the target; knockback grows with its damage. attacker may be null.
func hit_player(target: Player, attacker: Player, dir: Vector2, dmg: float, base_knock: float) -> void:
	target.damage = minf(Cfg.MAX_DAMAGE, target.damage + dmg)
	var knock := base_knock * (1.0 + target.damage / Cfg.KNOCK_GROWTH)
	target.kvx = dir.x * knock
	target.vy = dir.y * knock
	target.grapple = null
	target.on_ground = false
	target.stun = Cfg.STUN_BASE + knock * Cfg.STUN_PER_KNOCK
	target.hurt_t = 0.15
	target.jump_cut_ready = false             # a launch upward isn't a jump to cut short
	if attacker != null and attacker != target:
		target.last_hit_by = attacker.index
		target.last_hit_at = round_time
		attacker.dealt += dmg
	var col: Color = attacker.color if attacker != null else Color.WHITE
	burst(target.centre(), col, clampi(int(knock), 6, 30), 6.0 + knock * 0.3, 0.4, 4)
	shake = maxf(shake, clampf(knock / 100.0, 0.06, 0.3))
	var impact_time := minf(Cfg.HITSTOP_MAX, Cfg.HITSTOP_BASE + knock * Cfg.HITSTOP_PER_KNOCK)
	if freeze_on_hit:
		hitstop = maxf(hitstop, impact_time)
	else:
		hit_flash = maxf(hit_flash, impact_time)
	sound("hit_heavy" if knock >= 20 else "hit")


## Draw the hit impact now (enlarged hit player, white flash): during hitstop, or hit_flash online.
func impact() -> bool:
	return hitstop > 0.0 or hit_flash > 0.0


# --- items ---------------------------------------------------------------------------

## Run an item's effect. Returns false if it couldn't be used (no charge spent).
func use_item(p: Player, key: String) -> bool:
	var c := p.centre()
	var u := Vector2(p.aim).normalized()
	match key:
		"push":
			projectiles.append({"x": c.x + p.facing * 0.5, "y": c.y, "dir": p.facing, "dist": 0.0, "owner": p.index})
			sound("push")
		"laser":
			for i in range(1, Cfg.LASER_LENGTH + 1):
				var t := c + u * i
				world.set_tile(floori(t.x), floori(t.y), World.EMPTY, "laser")
			beams.append({"from": c, "to": c + u * Cfg.LASER_LENGTH, "owner": p.index, "time": Cfg.LASER_SHOW})
			sound("laser")
			shake = maxf(shake, 0.1)
		"boost":
			p.grapple = null
			p.vy = -Cfg.BOOST_SPEED
			p.jump_cut_ready = false
			for i in 3:
				burst(Vector2(c.x, p.y + Cfg.PLAYER_H), Color(1.0, 0.67, 0.24), 6, 6.0, 0.4, 4)
			sound("boost")
		"platform":
			var row := floori(p.y + Cfg.PLAYER_H - 0.01) + 1
			var col := floori(c.x)
			var placed := 0
			for tx in range(col - Cfg.PLATFORM_WIDTH / 2, col + Cfg.PLATFORM_WIDTH / 2 + 1):
				if world.in_bounds(tx, row) and not world.solid(tx, row) and not player_in_tile(tx, row):
					world.set_tile(tx, row, World.PLACED)
					placed += 1
			if placed == 0:
				return false
			p.vy = minf(p.vy, 0.0)
			sound("place")
		"grapple":
			for i in range(1, Cfg.GRAPPLE_RANGE * 5 + 1):
				var h := c + u * (i * 0.2)
				if world.solid(floori(h.x), floori(h.y)):
					p.grapple = Vector3(h.x, h.y, Cfg.GRAPPLE_TIME)
					sound("grapple")
					return true
			sound("nope")
			return false
		"bomb":
			var v := u * Cfg.BOMB_THROW
			if u.y <= 0:
				v.y -= 4.0
			bombs.append({"x": c.x, "y": c.y, "vx": v.x, "vy": v.y, "fuse": Cfg.BOMB_FUSE, "owner": p.index})
			sound("push")
	return true


func _update_projectiles(dt: float) -> void:
	var keep := []
	for pr in projectiles:
		var step := Cfg.PUSH_SPEED * dt
		pr["x"] += pr["dir"] * step
		pr["dist"] += step
		var owner: Player = players[pr["owner"]]
		if world.solid(floori(pr["x"]), floori(pr["y"])) or pr["dist"] > Cfg.PUSH_RANGE:
			burst(Vector2(pr["x"], pr["y"]), owner.color, 6, 4.0, 0.3, 3)
			continue
		var hit: Player = null
		for p: Player in players:
			if p.alive and p != owner and p.x - 0.2 < pr["x"] and pr["x"] < p.x + Cfg.PLAYER_W + 0.2 \
					and p.y - 0.2 < pr["y"] and pr["y"] < p.y + Cfg.PLAYER_H + 0.2:
				hit = p
				break
		if hit:
			var pdir: float = pr["dir"]
			hit_player(hit, owner, Vector2(pdir, -0.45).normalized(), Cfg.PUSH_DAMAGE, Cfg.PUSH_KNOCK)
			continue
		keep.append(pr)
	projectiles = keep


func _update_bombs(dt: float) -> void:
	var keep := []
	for b in bombs:
		b["fuse"] -= dt
		if b["fuse"] <= 0:
			_explode(b)
			continue
		if b["vx"] != 0.0 or b["vy"] != 0.0:
			b["vy"] += 30.0 * dt
			var nx: float = b["x"] + b["vx"] * dt
			var ny: float = b["y"] + b["vy"] * dt
			if world.solid(floori(nx), floori(ny)):
				b["vx"] = 0.0                    # sticks to whatever it hits
				b["vy"] = 0.0
			else:
				b["x"] = nx
				b["y"] = ny
		if b["y"] > Cfg.ROWS + 2:
			continue                             # fell out of the map: a dud
		keep.append(b)
	bombs = keep


## TNT that was mined, blasted or crumbled becomes a bomb stuck in place with a short fuse,
## credited to whoever set it off (owner -1: nobody, e.g. the zone).
func _light_tnt() -> void:
	for l: Array in world.lit:
		bombs.append({"x": l[0] + 0.5, "y": l[1] + 0.5, "vx": 0.0, "vy": 0.0, "fuse": Cfg.TNT_FUSE, "owner": l[2]})
		sound("push")
	world.lit.clear()


func _explode(b: Dictionary) -> void:
	var at := Vector2(b["x"], b["y"])
	var r := ceili(Cfg.BOMB_RADIUS)
	world.actor = b["owner"]                     # TNT caught in the blast goes off for the same player
	for ty in range(floori(at.y) - r, floori(at.y) + r + 1):
		for tx in range(floori(at.x) - r, floori(at.x) + r + 1):
			if Vector2(tx + 0.5, ty + 0.5).distance_to(at) <= Cfg.BOMB_RADIUS:
				world.set_tile(tx, ty, World.EMPTY, "bomb")
	for p: Player in players:
		if not p.alive:
			continue
		var d := p.centre().distance_to(at)
		if d < Cfg.BOMB_BLAST:
			var f := 1.0 - d / Cfg.BOMB_BLAST
			var dir := (p.centre() - at) / d if d > 0.01 else Vector2(0, -1)
			var owner: Player = players[b["owner"]] if int(b["owner"]) >= 0 else null
			hit_player(p, owner, dir, Cfg.BOMB_DAMAGE * f, Cfg.BOMB_KNOCK * f)
	burst(at, Color(1.0, 0.78, 0.31), 30, 14.0, 0.6, 5)
	burst(at, Color.WHITE, 12, 8.0, 0.3, 3)
	sound("boom")
	shake = maxf(shake, 0.3)


# --- online: what the host sends, and how a client applies it -------------------------

## ack_list (or `acks` if empty): per player, the last input seq applied, for client reconciliation.
func snapshot(ack_list: Array = []) -> Dictionary:
	var ak: Array = ack_list if ack_list else acks
	var ns := []
	var ack := []
	for i in players.size():
		ns.append(players[i].net_state())
		ack.append(int(ak[i]) if i < ak.size() else 0)
	var ps := []
	for p: Player in players:
		ps.append([p.x, p.y, p.facing, p.aim, p.alive, p.craft_t, p.last_crafted, p.inv.duplicate(),
			p.slots.map(func(s): return null if s == null else [s["item"], s["charges"]]),
			p.item_cd, p.wins, p.grapple,
			p.damage, p.swing_t, p.hurt_t, p.kos, p.falls, p.dealt, p.stun,
			p.vel_x, p.vy, p.on_ground, p.mine_target, p.mine_progress, p.mouse, p.land_t, p.aim_vec])
	return {"tick": tick, "st": state, "tm": timer, "rd": round_no, "msg": message, "sh": shake, "hs": hitstop, "hf": hit_flash,
		"p": ps, "ch": world.changes.duplicate(), "pr": projectiles.map(func(x): return [x["x"], x["y"], x["owner"]]),
		"bo": bombs.map(func(x): return [x["x"], x["y"], x["fuse"], x["owner"]]),
		"be": beams.map(func(x): return [x["from"], x["to"], x["owner"], x["time"]]),
		"ev": events.duplicate(),
		"zl": world.zone_left, "zr": world.zone_right, "al": world.arena_left, "ar": world.arena_right,
		"fd": feed.duplicate(true), "rt": round_time, "ns": ns, "ack": ack}


func grid_message() -> Dictionary:
	return {"g": world.grid, "v": world.version, "wa": world.warnings.duplicate(),
		"al": world.arena_left, "ar": world.arena_right, "bi": world.biome, "sp": world.shape}


func apply_grid(d: Dictionary) -> void:
	world.grid = d["g"]
	world.warnings = d["wa"]
	world.arena_left = d["al"]
	world.arena_right = d["ar"]
	world.biome = d.get("bi", "meadow")
	world.shape = d.get("sp", "islands")
	world.lit.clear()                            # only the host lights TNT
	world.broken.clear()
	world.dirty.clear()
	world.version += 1


## Client: copy the host's state. Returns the host's queued sounds and bursts to replay.
## Player skip_index (your predicted player) keeps its own x, y, vy, vel_x, on_ground, land_t, facing, aim.
func apply_snapshot(d: Dictionary, skip_index := -1) -> Array:
	var ps: Array = d["p"]
	if players.size() != ps.size():
		players = []
		for i in ps.size():
			players.append(Player.new(i))
	tick = d["tick"]
	state = d["st"]
	timer = d["tm"]
	round_no = d["rd"]
	message = d["msg"]
	shake = d["sh"]                              # the host fades shake out; copy it (max() here never decayed)
	hitstop = d["hs"]
	hit_flash = d["hf"]
	round_time = d["rt"]
	feed = d["fd"]
	world.zone_left = d["zl"]
	world.zone_right = d["zr"]
	world.arena_left = d["al"]
	world.arena_right = d["ar"]
	for i in ps.size():
		var p: Player = players[i]
		var s: Array = ps[i]
		if i != skip_index:
			p.x = s[0]; p.y = s[1]; p.facing = s[2]; p.aim = s[3]
			p.vel_x = s[19]; p.vy = s[20]; p.on_ground = s[21]; p.land_t = s[25]; p.aim_vec = s[26]
		p.alive = s[4]; p.craft_t = s[5]
		p.last_crafted = s[6]; p.inv = s[7]; p.item_cd = s[9]; p.wins = s[10]; p.grapple = s[11]
		p.damage = s[12]; p.swing_t = s[13]; p.hurt_t = s[14]; p.kos = s[15]; p.falls = s[16]
		p.dealt = s[17]; p.stun = s[18]
		p.mine_target = s[22]; p.mine_progress = s[23]; p.mouse = s[24]
		p.slots = s[8].map(func(sl): return null if sl == null else {"item": sl[0], "charges": sl[1]})
	for c in d["ch"]:
		match c[0]:
			"t": world.set_tile(c[1], c[2], c[3], c[4])
			"w": world.warn(c[1], c[2])
	projectiles = d["pr"].map(func(a): return {"x": a[0], "y": a[1], "owner": a[2]})
	bombs = d["bo"].map(func(a): return {"x": a[0], "y": a[1], "fuse": a[2], "owner": a[3]})
	beams = d["be"].map(func(a): return {"from": a[0], "to": a[1], "owner": a[2], "time": a[3]})
	return d["ev"]

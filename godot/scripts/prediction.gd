## Online movement without feeling your ping.
##   ServerQueue (host): one per remote player. Inputs arrive numbered ("seq"); the host applies one
##     per tick and tells the client the last one it applied ("ack" in the snapshot).
##   Client (client): moves your own player the moment you press a key, keeps the inputs the host
##     hasn't applied yet, and when a snapshot comes in, restarts from the host's state and replays them.
class_name Prediction
extends RefCounted

const MAX_QUEUE := 4              # more than this waiting: merge down to KEEP_QUEUE
const KEEP_QUEUE := 2
const MAX_HISTORY := 240          # 4 s of unacknowledged inputs; older ones are dropped
const MAX_SMOOTH := 8.0           # corrections bigger than this many tiles (a respawn) snap instead of easing
const MAX_STAND_IN := 8           # a late client gets this many ticks of stand-in inputs, then the host just waits
const EDGE_ACTIONS := ["jump", "item1", "item2", "item3", "craft"]   # act on the press, not the hold


class ServerQueue:
	var acked := 0                    # seq of the last input next() returned (or stood in for)
	var queue: Array = []             # Dictionary inputs, oldest first
	var last := {}
	var stood_in := {}                # the input repeated for a seq that hadn't arrived yet
	var stand_ins := 0                # stand-ins in a row
	var carry := {}                   # presses from late inputs, added to the next input applied

	func push(state: Dictionary) -> void:
		queue.append(state)

	## The input to apply this tick.
	## Empty queue (the client's input is late): repeat the last one as if it were the next seq, so the
	##   host doesn't fall a step behind what the client predicted. When the real one turns up it's
	##   dropped, but a press in it (jump, items, craft) that the stand-in lacked is carried forward.
	## Too many waiting (a burst, or the client running ahead): merge the oldest so 2 are left.
	func next() -> Dictionary:
		while not queue.is_empty() and int(queue[0].get("seq", acked + 1)) <= acked:
			var late: Dictionary = queue.pop_front()
			for k: String in EDGE_ACTIONS:
				if late.get(k, false) and not stood_in.get(k, false):
					carry[k] = true
		if queue.is_empty():
			if last.is_empty() or stand_ins >= MAX_STAND_IN:
				return last.duplicate()      # nothing yet, or a long stall: wait (ack doesn't move)
			stand_ins += 1
			acked += 1
			var rep := _with_carry(last.duplicate())
			rep["seq"] = acked
			stood_in = rep
			return rep.duplicate()
		stand_ins = 0
		var take := 1
		if queue.size() > MAX_QUEUE:
			take = queue.size() - KEEP_QUEUE
		var merged: Dictionary = queue[take - 1].duplicate()
		for i in take - 1:
			var s: Dictionary = queue[i]
			for k in s:
				if s[k] is bool and s[k]:
					merged[k] = true
		queue = queue.slice(take)
		merged = _with_carry(merged)
		last = merged
		acked = int(merged.get("seq", acked))
		return merged.duplicate()

	func _with_carry(inp: Dictionary) -> Dictionary:
		for k in carry:
			inp[k] = true
		carry.clear()
		return inp


## Stands in for GameSim while predicting: movement only needs the map; sounds and bursts come
## from the host's snapshot instead.
class GameStub:
	var world: World

	func sound(_name: String, _min_gap := 0.0) -> void:
		pass

	func burst(_pos: Vector2, _color: Color, _count: int, _speed: float, _life := 0.6, _size := 4, _up := 0.0) -> void:
		pass


class Client:
	var seq := 0
	var history: Array = []           # [seq, input] the host hasn't applied yet
	var stub := GameStub.new()
	var corrections := 0              # debug: reconciles that moved the predicted player > 0.5 tiles
	var worst := 0.0                  # debug: biggest such move
	var snaps := 0                    # debug: corrections > 0.5 tiles that snapped instead of easing

	## Number this frame's input and remember it. Returns what to send.
	func record(input: Dictionary) -> Dictionary:
		seq += 1
		history.append([seq, input.duplicate()])
		if history.size() > MAX_HISTORY:
			history = history.slice(history.size() - MAX_HISTORY)
		var sent := input.duplicate()
		sent["seq"] = seq
		return sent

	func predict(p: Player, world: World, input: Dictionary) -> void:
		stub.world = world
		p.predict_step(Cfg.DT, input, stub)

	## Restart from the host's state for input `acked`, replay the newer inputs, and ease the
	## visible position from where it was to the corrected one.
	func reconcile(p: Player, server_state: Array, acked: int, world: World) -> void:
		var before := Vector2(p.x, p.y)
		p.set_net_state(server_state)
		history = history.filter(func(h: Array) -> bool: return int(h[0]) > acked)
		for h: Array in history:
			predict(p, world, h[1])
		var moved := before.distance_to(Vector2(p.x, p.y))
		if moved > 0.5:
			corrections += 1
		worst = maxf(worst, moved)
		var eased := p.smooth + before - Vector2(p.x, p.y)
		p.smooth = Vector2.ZERO if eased.length() > MAX_SMOOTH else eased
		if moved > 0.5 and eased.length() > MAX_SMOOTH:
			snaps += 1

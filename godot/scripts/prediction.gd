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
const MAX_SMOOTH := 2.0           # corrections bigger than this many tiles snap instead of easing


class ServerQueue:
	var acked := 0                    # seq of the last input next() returned
	var queue: Array = []             # Dictionary inputs, oldest first
	var last := {}

	func push(state: Dictionary) -> void:
		queue.append(state)

	## The input to apply this tick. Empty queue: repeat the last one (ack doesn't move).
	## Too many waiting (a burst, or the client running ahead): merge the oldest so 2 are left.
	func next() -> Dictionary:
		if queue.is_empty():
			return last.duplicate()
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
		last = merged
		acked = int(merged.get("seq", acked))
		return merged.duplicate()


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
		var eased := p.smooth + before - Vector2(p.x, p.y)
		p.smooth = Vector2.ZERO if eased.length() > MAX_SMOOTH else eased

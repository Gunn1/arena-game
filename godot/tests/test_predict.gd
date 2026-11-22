## Client prediction + server reconciliation, with the network simulated in-process:
##   godot --headless --path . -s tests/test_predict.gd
extends SceneTree

const Pred := preload("res://scripts/prediction.gd")
const LAG := 6                    # frames each way (~100 ms at 60 fps)

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
	test_responsiveness()
	test_convergence()
	test_correction()
	test_server_queue()
	test_hit_online()
	test_shake_fades()
	print("all good" if failures == 0 else "%d FAILURES" % failures)
	quit(0 if failures == 0 else 1)


func floor_sim(p1_col := 15) -> GameSim:
	var sim := GameSim.new()
	sim.players = [Player.new(0), Player.new(1)]
	sim.world.grid.fill(0)
	for x in range(10, 50):
		sim.world.grid[20 * Cfg.COLS + x] = World.STONE
	sim.players[0].spawn(p1_col, 20)
	sim.players[1].spawn(40, 20)
	sim.state = "play"
	return sim


## A server sim and a client predicting P1, joined by queues of [deliver_frame, payload].
class Net:
	var sim: GameSim
	var queue: Pred.ServerQueue
	var client: Pred.Client
	var world := World.new()          # the client's copy of the map
	var me: Player                    # the client's predicted P1
	var frame := 0
	var to_server: Array = []         # [deliver_frame, input]
	var to_client: Array = []         # [deliver_frame, {"state", "ack"}]
	var max_smooth := 0.0             # biggest |me.smooth| seen right after a reconcile
	var max_jump := 0.0               # biggest position change a reconcile caused
	var total_jump := 0.0             # all of them added up
	var idle: Dictionary

	func _init(s: GameSim, idle_input: Dictionary) -> void:
		sim = s
		idle = idle_input
		queue = Pred.ServerQueue.new()
		client = Pred.Client.new()
		world.grid = sim.world.grid.duplicate()
		me = Player.new(0)
		me.set_net_state(sim.players[0].net_state())

	func server_p() -> Player:
		return sim.players[0]

	## One frame on both ends. `before_server` runs on the server just before its sim.update.
	func step(inp: Dictionary, before_server := Callable()) -> void:
		# Client: apply snapshots that have arrived, then predict this frame's input.
		var keep := []
		for m: Array in to_client:
			if m[0] <= frame:
				var d: Dictionary = m[1]
				var before := Vector2(me.x, me.y)
				client.reconcile(me, d["state"], d["ack"], world)
				max_jump = maxf(max_jump, before.distance_to(Vector2(me.x, me.y)))
				total_jump += before.distance_to(Vector2(me.x, me.y))
				max_smooth = maxf(max_smooth, me.smooth.length())
			else:
				keep.append(m)
		to_client = keep
		var sent: Dictionary = client.record(inp)
		to_server.append([frame + LAG, sent])
		client.predict(me, world, sent)

		# Server: take delivered inputs, step, send a snapshot back.
		keep = []
		for m: Array in to_server:
			if m[0] <= frame:
				queue.push(m[1])
			else:
				keep.append(m)
		to_server = keep
		var srv_inp: Dictionary = queue.next()
		if before_server.is_valid():
			before_server.call()
		sim.update(Cfg.DT, [srv_inp, idle.duplicate()])
		to_client.append([frame + LAG, {"state": server_p().net_state(), "ack": queue.acked}])
		frame += 1

	func error() -> Vector2:
		return Vector2(absf(me.x - server_p().x), absf(me.y - server_p().y))


## Server settles on the floor first so both ends start from a resting P1.
func make_net(p1_col := 15) -> Net:
	var sim := floor_sim(p1_col)
	for i in 5:
		sim.update(Cfg.DT, [IDLE.duplicate(), IDLE.duplicate()])
	return Net.new(sim, IDLE)


func test_responsiveness() -> void:
	var net := make_net()
	var cx0 := net.me.x
	var sx0 := net.server_p().x
	net.step(with({"right": true}))
	check(net.me.x > cx0, "predicted P1 moves on the first frame (%.4f -> %.4f)" % [cx0, net.me.x])
	check(net.server_p().x == sx0, "server P1 hasn't moved yet (%.4f -> %.4f)" % [sx0, net.server_p().x])
	print("responsiveness: client moved %.4f tiles on frame 1, server moved %.4f OK"
		% [net.me.x - cx0, net.server_p().x - sx0])


func test_convergence() -> void:
	var net := make_net()
	var x0 := net.me.x
	for f in 40:
		net.step(with({"right": true}))
	for f in 8:
		net.step(with({"right": true, "jump": true}))
	for f in 60:
		net.step(with({}))
	var e := net.error()
	check(e.x < 0.01 and e.y < 0.01, "client and server P1 agree after idling (dx %.4f, dy %.4f)" % [e.x, e.y])
	check(net.me.x > x0 + 3.0, "P1 actually walked (%.2f tiles)" % (net.me.x - x0))
	check(net.client.history.size() <= 13, "history stays short (%d pending)" % net.client.history.size())
	print("convergence: walked %.2f tiles + jump, error dx %.5f dy %.5f, %d inputs pending, biggest snap %.3f OK"
		% [net.me.x - x0, e.x, e.y, net.client.history.size(), net.max_jump])


func test_correction() -> void:
	# Start further right so the knockback (~18 tiles left) stays over the floor.
	var net := make_net(36)
	net.sim.freeze_on_hit = false                # as online
	var hit_frame := 20
	var hit := func() -> void:
		if net.frame == hit_frame:
			net.sim.hit_player(net.sim.players[0], net.sim.players[1], Vector2(-1, -0.4).normalized(), 50.0, 20.0)
	for f in 60:
		net.step(with({"right": true}), hit)
	for f in 150:
		net.step(with({}))
	var e := net.error()
	check(net.server_p().alive and net.me.alive, "P1 survives the knockback on both ends")
	check(e.x < 0.05 and e.y < 0.05, "client ends up where the server put P1 (dx %.4f, dy %.4f)" % [e.x, e.y])
	# A knockback correction (several tiles) is eased, not snapped: only > MAX_SMOOTH (a respawn) snaps.
	check(net.max_jump > 2.0 and net.max_smooth >= net.max_jump - 0.01 and net.max_jump < Pred.MAX_SMOOTH,
		"the %.2f tile knockback correction was eased (max smooth %.3f)" % [net.max_jump, net.max_smooth])
	print("correction: server x %.2f, client x %.2f, max smooth %.3f, biggest snap %.3f, error dx %.5f dy %.5f OK"
		% [net.server_p().x, net.me.x, net.max_smooth, net.max_jump, e.x, e.y])


func queued(seq: int, extra := {}) -> Dictionary:
	var d := with(extra)
	d["seq"] = seq
	return d


func test_server_queue() -> void:
	var q := Pred.ServerQueue.new()
	check(q.next().is_empty() and q.acked == 0, "nothing received yet: empty input, nothing acked")
	for s in range(1, 4):
		q.push(queued(s, {"right": true}))
	for s in range(1, 4):
		var got: Dictionary = q.next()
		check(int(got["seq"]) == s and q.acked == s, "next() #%d returns seq %d, acked %d" % [s, int(got["seq"]), q.acked])

	# Seq 4 is late: the host stands in with a repeat of 3 AS seq 4, so acked advances.
	var again: Dictionary = q.next()
	check(int(again["seq"]) == 4 and q.acked == 4 and again["right"], "empty queue repeats the last input as seq 4 (seq %d, acked %d)"
		% [int(again["seq"]), q.acked])
	# The real seq 4 turns up with a fresh jump press, and seq 5 without it (a one-frame tap).
	# Seq 4 is dropped (already stood in for), but its jump press is carried into seq 5.
	q.push(queued(4, {"right": true, "jump": true}))
	q.push(queued(5, {"right": true}))
	var five: Dictionary = q.next()
	check(int(five["seq"]) == 5 and q.acked == 5, "the late seq 4 is dropped: next is seq 5 (seq %d, acked %d)" % [int(five["seq"]), q.acked])
	check(bool(five.get("jump", false)), "the late input's jump press survives in the next input applied")
	check(q.queue.is_empty(), "nothing left queued")
	# A late input with no new press is just dropped, and nothing extra is carried.
	q.next()                                     # stands in for 6
	q.push(queued(6, {"right": true}))
	q.push(queued(7, {"right": true}))
	var seven: Dictionary = q.next()
	check(int(seven["seq"]) == 7 and not bool(seven.get("jump", false)), "a late input without a press carries nothing")

	# A burst of 7: one call should leave at most 2 queued, so acked hits 14 within 2 more calls.
	# item1 is only true in seq 9, which is a likely merge victim.
	for s in range(8, 15):
		q.push(queued(s, {"item1": s == 9}))
	var results: Array[Dictionary] = []
	var acks: Array[int] = []
	for i in 4:
		results.append(q.next())
		acks.append(q.acked)
	check(acks[0] > 8, "first call after a burst merges (acked jumped to %d)" % acks[0])
	check(acks[2] == 14, "<= 2 left after one call: acked reaches 14 by the third call (%s)" % str(acks))
	check(acks[3] == 15, "once empty, the repeat stands in for seq 15 (%s)" % str(acks))
	var item_seen := false
	for r in results:
		item_seen = item_seen or bool(r.get("item1", false))
	check(item_seen, "an action pressed only in a merged-away input survives the merge")

	# A long stall (the client stopped sending): stand-ins stop after MAX_STAND_IN, so the host
	# doesn't run ahead of the client forever.
	for i in 30:
		q.next()
	check(q.acked == 14 + Pred.MAX_STAND_IN, "stand-ins stop after %d (acked %d)" % [Pred.MAX_STAND_IN, q.acked])
	q.push(queued(q.acked + 1))
	check(int(q.next()["seq"]) == q.acked and q.acked == 15 + Pred.MAX_STAND_IN, "inputs after a stall are applied again")
	print("server queue: FIFO 1..3, late seq stood in + dropped with its jump kept, burst of 7 acked %s, merged item1 kept %s, stall capped OK"
		% [str(acks), str(item_seen)])


## Online the host must not freeze on a hit: it used to skip the sim during hitstop while still
## taking each remote player's next input, so those inputs (here: a jump) were never applied and
## the client, which predicted them, got snapped back to the ground.
func hit_during_jump(freeze: bool) -> Net:
	var net := make_net()
	net.sim.freeze_on_hit = freeze
	var hit := func() -> void:
		if net.frame == 20:
			net.sim.hit_player(net.sim.players[1], null, Vector2(1, -0.4).normalized(), 0.0, 9.0)
	for f in 30:
		net.step(with({"jump": f >= 15 and f <= 24}), hit)  # the press reaches the host in the freeze
	for f in 60:
		net.step(with({}))
	return net


func test_hit_online() -> void:
	var online := hit_during_jump(false)
	var e := online.error()
	check(online.sim.hitstop == 0.0, "online: no hitstop")
	check(online.total_jump < 0.01, "online: a hit elsewhere doesn't correct my jump (%.3f tiles in all)" % online.total_jump)
	check(e.x < 0.01 and e.y < 0.01, "online: client and server agree (dx %.4f, dy %.4f)" % [e.x, e.y])
	var frozen := hit_during_jump(true)
	check(frozen.total_jump > 0.3, "with the old freeze the jump inputs are lost and the client gets corrected (%.3f tiles in all)" % frozen.total_jump)
	print("hit online: no freeze, corrections %.4f tiles in all (with the freeze: %.2f) OK" % [online.total_jump, frozen.total_jump])


## Regression: online clients kept the max shake ever received, so the screen shook forever.
func test_shake_fades() -> void:
	var host := GameSim.new()
	host.start_match(2)
	host.state = "play"
	var client := GameSim.new()
	host.hit_player(host.players[1], host.players[0], Vector2(1, -0.4).normalized(), 50.0, 20.0)
	client.apply_snapshot(host.snapshot())
	var peak := client.shake
	# The hit player may also fall out (random map), which shakes again; it must still fade to 0.
	var idle := [{}, {}]
	var frames := 0
	while frames < 600 and (frames < 30 or client.shake > 0.0):
		host.update(Cfg.DT, idle)
		host.events.clear()
		host.world.changes.clear()
		client.apply_snapshot(host.snapshot())
		frames += 1
	check(peak > 0.0, "client got the shake")
	check(client.shake == 0.0, "client shake fades back to 0 (was %.2f after %d frames)" % [client.shake, frames])
	print("shake: client peak %.2f, back to 0 after %.1f s OK" % [peak, frames / 60.0])

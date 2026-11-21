## Sound effects synthesized in code (no audio files), played from a small pool of players.
class_name Sfx
extends Node

const RATE := 22050

var muted := false
var streams := {}
var pool: Array = []
var last_played := {}


func _ready() -> void:
	streams = {
		"jump": tone(300, 620, 0.08, 0.12),
		"mine": tone(180, 110, 0.06, 0.25, "tri", 0.6),
		"crack": tone(420, 300, 0.05, 0.2, "tri", 0.5),
		"place": tone(170, 110, 0.07, 0.35, "sine"),
		"push": tone(520, 180, 0.18, 0.3, "sine", 0.7),
		"hit": tone(220, 90, 0.12, 0.3, "square", 0.4),
		"laser": tone(1300, 180, 0.25, 0.16),
		"crumble": tone(120, 60, 0.12, 0.12, "tri", 0.9),
		"death": tone(640, 70, 0.5, 0.22),
		"round": chain([[523, 0.09], [659, 0.09], [784, 0.09], [1047, 0.2]], 0.18),
		"go": tone(880, 880, 0.12, 0.15, "tri"),
		"craft": chain([[660, 0.06], [990, 0.1]], 0.15),
		"nope": tone(140, 120, 0.12, 0.15),
		"boost": tone(200, 700, 0.2, 0.18, "sine", 0.5),
		"grapple": tone(900, 1500, 0.1, 0.12, "tri"),
		"boom": tone(110, 35, 0.6, 0.4, "tri", 0.8),
	}
	for i in 12:
		var p := AudioStreamPlayer.new()
		add_child(p)
		pool.append(p)


func play(name: String, min_gap := 0.0) -> void:
	if muted or not streams.has(name):
		return
	var now := Time.get_ticks_msec() / 1000.0
	if now - last_played.get(name, -1.0) < min_gap:
		return
	last_played[name] = now
	for p in pool:
		if not p.playing:
			p.stream = streams[name]
			p.play()
			return


func tone(f0: float, f1: float, dur: float, vol: float, wave := "square", noise := 0.0) -> AudioStreamWAV:
	return _stream(_samples(f0, f1, dur, vol, wave, noise))


func chain(notes: Array, vol: float) -> AudioStreamWAV:
	var all := PackedFloat32Array()
	for n in notes:
		all.append_array(_samples(n[0], n[0], n[1], vol, "square", 0.0))
	return _stream(all)


func _samples(f0: float, f1: float, dur: float, vol: float, wave: String, noise: float) -> PackedFloat32Array:
	var n := int(RATE * dur)
	var out := PackedFloat32Array()
	out.resize(n)
	var phase := 0.0
	for i in n:
		var t := float(i) / n
		phase += lerpf(f0, f1, t) / RATE
		var frac := fposmod(phase, 1.0)
		var v: float
		match wave:
			"square": v = 1.0 if frac < 0.5 else -1.0
			"tri": v = 4.0 * absf(frac - 0.5) - 1.0
			_: v = sin(TAU * phase)
		if noise > 0.0:
			v = v * (1.0 - noise) + randf_range(-1.0, 1.0) * noise
		var env := minf(1.0, i / (RATE * 0.004)) * pow(1.0 - t, 2.0)   # tiny attack, quick decay
		out[i] = v * env * vol
	return out


func _stream(samples: PackedFloat32Array) -> AudioStreamWAV:
	var data := PackedByteArray()
	data.resize(samples.size() * 2)
	for i in samples.size():
		data.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32767))
	var s := AudioStreamWAV.new()
	s.format = AudioStreamWAV.FORMAT_16_BITS
	s.mix_rate = RATE
	s.stereo = false
	s.data = data
	return s

## Sound effects synthesized in code (no audio files), played from a pool of players.
## Each sound is a mix of layers (oscillators, filtered noise, gravel "grit") written into
## a scratch buffer, then normalized and baked into a 16-bit mono AudioStreamWAV at startup.
class_name Sfx
extends Node

const RATE := 22050
const POOL_SIZE := 16
const WAVES := ["sine", "square", "tri", "saw"]

var muted := false
var streams := {}          # name -> AudioStreamWAV
var info := {}             # name -> [volume_db, pitch_lo, pitch_hi]
var pool: Array[AudioStreamPlayer] = []
var started: Array[float] = []
var last_played := {}

var _b := PackedFloat32Array()        # scratch buffer for the sound being built
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.seed = 7041   # fixed seed: same sounds every run; own RNG so the global one is untouched
	_build()
	_rng.randomize()
	for i in POOL_SIZE:
		var p := AudioStreamPlayer.new()
		add_child(p)
		pool.append(p)
		started.append(-1000.0)


func play(name: String, min_gap := 0.0) -> void:
	if muted or not streams.has(name):
		return
	var now := Time.get_ticks_msec() / 1000.0
	var last: float = last_played.get(name, -1000.0)
	if now - last < min_gap:
		return
	last_played[name] = now
	if pool.is_empty():
		return
	# First idle player, else steal the one that started longest ago.
	var idx := -1
	var oldest := 0
	for i in pool.size():
		if not pool[i].playing:
			idx = i
			break
		if started[i] < started[oldest]:
			oldest = i
	if idx < 0:
		idx = oldest
	var p := pool[idx]
	var cfg: Array = info[name]
	p.stop()
	p.stream = streams[name]
	p.volume_db = cfg[0]
	p.pitch_scale = _rng.randf_range(cfg[1], cfg[2])
	p.play()
	started[idx] = now


# --- sound design ------------------------------------------------------------------------
# _osc(wave, f0, f1, start, dur, amp, atk, tau)   pitch sweeps exponentially f0 -> f1
# _noise(start, dur, amp, lp0, lp1, hp, atk, tau) low-pass sweeps lp0 -> lp1, optional high-pass
# _grit(start, dur, amp, density, lp, atk, tau)   sparse random clicks (gravel / crunch)
# tau > 0: exponential decay with that time constant (s); tau = 0: smooth (1-t)^2 decay.
# _add(name, volume_db, pitch_lo, pitch_hi, drive) normalizes, saturates, stores.

func _build() -> void:
	_begin(0.1)   # short upward chirp
	_osc("tri", 280, 760, 0.0, 0.1, 1.0, 0.003, 0.045)
	_osc("square", 560, 1520, 0.0, 0.05, 0.12, 0.003, 0.02)
	_noise(0.0, 0.04, 0.25, 3500, 2000, 700, 0.001, 0.012)
	_add("jump", -9.0, 0.92, 1.08)

	_begin(0.1)   # soft low thud
	_osc("sine", 140, 55, 0.0, 0.1, 1.0, 0.002, 0.03)
	_noise(0.0, 0.08, 0.8, 450, 150, 0.0, 0.002, 0.022)
	_add("land", -10.0, 0.88, 1.12)

	_begin(0.045)   # quiet scuff
	_noise(0.0, 0.04, 1.0, 2600, 900, 300, 0.001, 0.008)
	_osc("sine", 190, 110, 0.0, 0.03, 0.35, 0.001, 0.01)
	_add("step", -23.0, 0.8, 1.25)

	_begin(0.05)   # dry pick tick
	_noise(0.0, 0.02, 1.0, 7000, 5000, 2000, 0.0005, 0.004)
	_osc("tri", 1500, 950, 0.0, 0.035, 0.35, 0.0005, 0.007)
	_add("mine_tick", -18.0, 0.8, 1.2)

	_begin(0.2)   # block breaks: crunch + thump
	_grit(0.0, 0.18, 1.0, 900, 3500, 0.001, 0.05)
	_noise(0.0, 0.15, 0.6, 1800, 500, 0.0, 0.001, 0.04)
	_osc("sine", 120, 55, 0.0, 0.14, 0.9, 0.001, 0.04)
	_add("mine", -7.0, 0.9, 1.1, 1.6)

	_begin(0.08)   # small brittle crack (legacy)
	_noise(0.0, 0.06, 1.0, 6000, 3000, 1500, 0.0005, 0.015)
	_osc("tri", 420, 300, 0.0, 0.06, 0.4, 0.001, 0.02)
	_add("crack", -11.0)

	_begin(0.1)   # wooden knock
	_osc("sine", 540, 480, 0.0, 0.1, 0.8, 0.001, 0.018)
	_osc("sine", 1260, 1220, 0.0, 0.04, 0.3, 0.0005, 0.007)
	_osc("sine", 190, 160, 0.0, 0.1, 0.6, 0.001, 0.03)
	_noise(0.0, 0.015, 0.5, 2500, 2500, 200, 0.0005, 0.003)
	_add("place", -8.0)

	_begin(0.12)   # air whoosh
	_noise(0.0, 0.12, 1.0, 600, 4200, 400, 0.045, 0.0)
	_add("swing", -13.0, 0.85, 1.15)

	_begin(0.16)   # punchy impact
	_osc("sine", 165, 48, 0.0, 0.16, 1.0, 0.001, 0.05)
	_noise(0.0, 0.06, 0.9, 5500, 1200, 150, 0.0005, 0.012)
	_osc("square", 220, 90, 0.0, 0.06, 0.18, 0.001, 0.02)
	_add("hit", -4.0, 0.92, 1.08, 2.0)

	_begin(0.28)   # bigger, deeper, with ring
	_osc("sine", 115, 34, 0.0, 0.28, 1.0, 0.001, 0.085)
	_noise(0.0, 0.12, 1.0, 4500, 600, 100, 0.0005, 0.025)
	_grit(0.0, 0.08, 0.4, 1500, 3000, 0.0005, 0.02)
	_osc("sine", 330, 318, 0.0, 0.28, 0.22, 0.005, 0.1)
	_osc("sine", 497, 490, 0.0, 0.22, 0.1, 0.005, 0.07)
	_add("hit_heavy", -2.0, 0.95, 1.05, 2.5)

	_begin(0.16)   # gravelly rumble
	_grit(0.0, 0.16, 1.0, 450, 1300, 0.02, 0.0)
	_noise(0.0, 0.16, 0.5, 320, 220, 0.0, 0.02, 0.0)
	_add("crumble", -16.0, 0.8, 1.2)

	_begin(0.42)   # falling whistle + low boom
	_osc("sine", 1400, 190, 0.0, 0.28, 0.6, 0.005, 0.25)
	_osc("sine", 90, 34, 0.24, 0.18, 1.0, 0.001, 0.06)
	_noise(0.24, 0.18, 0.9, 800, 150, 0.0, 0.001, 0.05)
	_add("death", -5.0, 0.96, 1.04, 1.5)

	_begin(0.2)   # wand: airy whoosh with a tone
	_noise(0.0, 0.2, 1.0, 900, 3200, 300, 0.03, 0.0)
	_osc("sine", 300, 640, 0.0, 0.18, 0.4, 0.02, 0.07)
	_add("push", -9.0)

	_begin(0.16)   # zap
	_osc("saw", 1800, 220, 0.0, 0.16, 0.6, 0.001, 0.06)
	_osc("square", 1815, 224, 0.0, 0.14, 0.22, 0.001, 0.05)
	_noise(0.0, 0.03, 0.25, 9000, 9000, 3000, 0.0005, 0.006)
	_add("laser", -12.0)

	_begin(0.22)   # rocket hiss rising
	_noise(0.0, 0.22, 1.0, 800, 5000, 500, 0.02, 0.0)
	_osc("sine", 180, 540, 0.0, 0.2, 0.35, 0.01, 0.14)
	_add("boost", -10.0)

	_begin(0.14)   # metallic zip
	_osc("square", 700, 2200, 0.0, 0.12, 0.35, 0.001, 0.05)
	_osc("sine", 2900, 3300, 0.0, 0.14, 0.3, 0.001, 0.04)
	_osc("sine", 4130, 4300, 0.0, 0.1, 0.15, 0.001, 0.03)
	_noise(0.0, 0.1, 0.4, 8000, 8000, 2500, 0.001, 0.035)
	_add("grapple", -12.0)

	_begin(0.5)   # explosion
	_noise(0.0, 0.5, 1.0, 1600, 120, 0.0, 0.002, 0.15)
	_osc("sine", 75, 28, 0.0, 0.38, 1.0, 0.002, 0.1)
	_grit(0.0, 0.3, 0.5, 600, 2000, 0.002, 0.08)
	_add("boom", -2.0, 0.9, 1.1, 2.0)

	_begin(0.24)   # bright two-note chime
	_chime(880, 0.0, 0.1, 0.8, 0.05)
	_chime(1320, 0.07, 0.17, 1.0, 0.07)
	_add("craft", -10.0, 0.97, 1.03)

	_begin(0.12)   # short low buzz
	_osc("square", 130, 112, 0.0, 0.12, 0.5, 0.003, 0.0)
	_osc("saw", 133, 115, 0.0, 0.12, 0.4, 0.003, 0.0)
	_add("nope", -13.0, 0.97, 1.03)

	_begin(0.14)   # start beep
	_osc("square", 880, 880, 0.0, 0.14, 0.4, 0.003, 0.07)
	_osc("sine", 1760, 1760, 0.0, 0.12, 0.3, 0.003, 0.05)
	_add("go", -10.0, 1.0, 1.0)

	_begin(0.4)   # 4-note fanfare (C E G C)
	var notes := [523.25, 659.25, 783.99, 1046.5]
	for k in notes.size():
		var f: float = notes[k]
		var st := 0.085 * k
		var last := k == notes.size() - 1
		var d := 0.4 - st if last else 0.11
		var tau := 0.1 if last else 0.05
		_osc("tri", f, f, st, d, 0.8, 0.003, tau)
		_osc("square", f * 2.0, f * 2.0, st, d, 0.1, 0.003, tau * 0.6)
	_add("round", -9.0, 1.0, 1.0)


func _chime(f: float, start: float, dur: float, amp: float, tau: float) -> void:
	_osc("sine", f, f, start, dur, amp, 0.002, tau)
	_osc("sine", f * 2.0, f * 2.0, start, dur, amp * 0.3, 0.002, tau * 0.6)
	_osc("sine", f * 2.76, f * 2.76, start, dur, amp * 0.12, 0.002, tau * 0.4)


# --- synthesis helpers -------------------------------------------------------------------

func _begin(dur: float) -> void:
	_b = PackedFloat32Array()
	_b.resize(int(dur * RATE))
	_b.fill(0.0)


## Attack ramp, then exponential (tau > 0) or (1-t)^2 decay. Short fade at the end so nothing clicks.
func _env(i: int, n: int, atk: float, tau: float) -> float:
	var e := minf(1.0, float(i) / maxf(1.0, atk * RATE))
	if tau > 0.0:
		e *= exp(-float(i) / (tau * RATE)) * minf(1.0, float(n - i) / (0.006 * RATE))
	else:
		var r := 1.0 - float(i) / n
		e *= r * r
	return e


func _osc(wave: String, f0: float, f1: float, start: float, dur: float, amp: float, atk := 0.002, tau := 0.0) -> void:
	var w := WAVES.find(wave)
	var s0 := int(start * RATE)
	var n := int(dur * RATE)
	var ratio := f1 / f0
	var phase := 0.0
	for i in n:
		var j := s0 + i
		if j >= _b.size():
			break
		var t := float(i) / n
		phase = fposmod(phase + f0 * pow(ratio, t) / RATE, 1.0)
		var v: float
		if w == 1:
			v = 1.0 if phase < 0.5 else -1.0
		elif w == 2:
			v = 4.0 * absf(phase - 0.5) - 1.0
		elif w == 3:
			v = 2.0 * phase - 1.0
		else:
			v = sin(TAU * phase)
		_b[j] += v * amp * _env(i, n, atk, tau)


## White noise through a one-pole low-pass (cutoff sweeps lp0 -> lp1), then an optional
## one-pole high-pass at hp. Gain-compensated so the layer level doesn't depend much on cutoff.
func _noise(start: float, dur: float, amp: float, lp0: float, lp1: float, hp := 0.0, atk := 0.002, tau := 0.0) -> void:
	var s0 := int(start * RATE)
	var n := int(dur * RATE)
	lp0 = clampf(lp0, 20.0, 10000.0)
	lp1 = clampf(lp1, 20.0, 10000.0)
	var ratio := lp1 / lp0
	var hpa := 1.0 - exp(-TAU * hp / RATE) if hp > 0.0 else 0.0
	var y := 0.0
	var hs := 0.0
	for i in n:
		var j := s0 + i
		if j >= _b.size():
			break
		var t := float(i) / n
		var a := 1.0 - exp(-TAU * lp0 * pow(ratio, t) / RATE)
		y += (_rng.randf_range(-1.0, 1.0) - y) * a
		var v := y * sqrt((2.0 - a) / a) * 0.6
		if hp > 0.0:
			hs += (v - hs) * hpa
			v -= hs
		_b[j] += v * amp * _env(i, n, atk, tau)


## Sparse random clicks (density per second), each a tiny decaying impulse, low-passed at lp.
func _grit(start: float, dur: float, amp: float, density: float, lp: float, atk := 0.002, tau := 0.0) -> void:
	var s0 := int(start * RATE)
	var n := int(dur * RATE)
	var a := 1.0 - exp(-TAU * clampf(lp, 20.0, 10000.0) / RATE)
	var comp := sqrt((2.0 - a) / a) * 1.5
	var p := density / RATE
	var imp := 0.0
	var y := 0.0
	for i in n:
		var j := s0 + i
		if j >= _b.size():
			break
		if _rng.randf() < p:
			imp = _rng.randf_range(-1.0, 1.0)
		imp *= 0.75
		y += (imp - y) * a
		_b[j] += y * comp * amp * _env(i, n, atk, tau)


## Normalize to full scale, optionally saturate (drive > 1 = more punch), scale to a safe peak,
## and store the stream with its playback settings.
func _add(name: String, volume_db: float, pitch_lo := 0.93, pitch_hi := 1.07, drive := 1.0) -> void:
	var m := 0.0
	for v in _b:
		m = maxf(m, absf(v))
	var g := 1.0 / m if m > 0.0 else 0.0
	var norm := 1.0 / tanh(drive) if drive > 1.0 else 1.0
	var data := PackedByteArray()
	data.resize(_b.size() * 2)
	for i in _b.size():
		var v := _b[i] * g
		if drive > 1.0:
			v = tanh(v * drive) * norm
		data.encode_s16(i * 2, int(clampf(v * 0.89, -1.0, 1.0) * 32767.0))
	var s := AudioStreamWAV.new()
	s.format = AudioStreamWAV.FORMAT_16_BITS
	s.mix_rate = RATE
	s.stereo = false
	s.data = data
	streams[name] = s
	info[name] = [volume_db, pitch_lo, pitch_hi]

## Background music composed and synthesized in code (no audio files): a calm "menu" loop and a
## driving chiptune "battle" loop with a second "hype" layer that fades in as the zone closes.
##
## Tracks are rendered a slice per frame (~2 ms) so the single-threaded web build never stalls.
## Each distinct note is synthesized once (cached) and added into a float bus wherever it plays;
## buses that repeat (drums, chords) are rendered for one period and tiled. Note tails past the loop end wrap around to the start and the echo reads
## the loop circularly, so the loop is seamless. Then the buses are mixed (echo, kick side-chain
## ducking, soft clip) into 16-bit and wrapped in a looping AudioStreamWAV.
class_name Music
extends Node

const RATE := 22050
const VOLUME_DB := -12.0
const FADE_TIME := 0.8          # crossfade between tracks (s)
const BUDGET_USEC := 2000       # render time per frame
const SLICE := 1024             # max samples per render step
const ORDER := ["menu", "battle"]

# Voice kinds and waveforms
const TONE := 0
const KICK := 1
const SNARE := 2
const HAT := 3
const SAW := 0
const SQUARE := 1
const TRI := 2
const SINE := 3

## Tone voice parameters. Envelope: linear attack, exponential decay to sustain, exponential
## release after the gate. Two-pole low-pass whose cutoff glides c0 -> c1 (time constant ct).
## Optional second oscillator (SAW or SINE at f * det), sine sub-octave, delayed vibrato.
const TONE_DEFAULT := {"v": TONE, "id": "", "w": SAW, "w2": SAW, "det": 1.0, "mix2": 0.0, "sub": 0.0, "pw": 0.5,
	"atk": 0.003, "dec": 0.2, "sus": 0.6, "rel": 0.05, "c0": 9000.0, "c1": 9000.0, "ct": 0.1,
	"vib": 0.0, "vr": 5.0, "vd": 0.2}

const BATTLE_ROOTS := [45, 41, 48, 43, 45, 41, 38, 40]              # A F C G A F D E
const BATTLE_CHORDS := [[57, 60, 64], [57, 60, 65], [55, 60, 64], [55, 59, 62],
	[57, 60, 64], [57, 60, 65], [57, 62, 65], [56, 59, 64]]
const MENU_ROOTS := [41, 45, 38, 46]                                 # Fmaj7 Am7 Dm7 Bbmaj9
const MENU_CHORDS := [[53, 57, 60, 64], [55, 57, 60, 64], [53, 57, 60, 62], [50, 53, 57, 60]]
const ARP_PATTERNS := [
	[0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3],
	[0, 1, 2, 3, 2, 1, 0, 1, 2, 3, 2, 1, 0, 1, 2, 1],
	[0, 2, 1, 3, 0, 2, 1, 3, 0, 2, 1, 3, 2, 3, 1, 2],
	[0, -1, 2, 3, -1, 2, 1, -1, 0, -1, 2, 3, 3, 2, 1, 0],
	[3, 2, 1, 0, 3, 2, 1, 0, 3, 2, 1, 0, 1, 2, 3, 2],
]
const RHYTHMS := [[1.0, 0.5, 0.5, 1.0, 1.0], [0.5, 0.5, 1.0, 0.5, 0.5, 1.0], [1.5, 0.5, 1.0, 1.0],
	[2.0, 1.0, 1.0], [1.0, 1.0, 2.0], [0.75, 0.75, 0.5, 1.0, 1.0]]


class Track:
	var name := ""
	var n := 0                       # loop length in samples
	var spb := 0.0                   # samples per beat
	var bus_names: Array[String] = []
	var period := {}                 # bus name -> samples it is rendered over before tiling to n
	var buses := {}                  # bus name -> PackedFloat32Array
	var layers := 1                  # output layers (battle: base + hype)
	var notes: Array[Dictionary] = []
	var cache := {}                  # note key -> PackedFloat32Array, the note rendered at amp 1
	var phase := 0                   # 0 alloc, 1 notes, 2 tile, 3 mix, 4 streams, 5 done
	var note_i := 0
	var note_pos := 0                # samples of the current note added to its bus
	var synth_pos := -1              # >= 0 while the current note's cache entry is being rendered
	var tile_i := 0
	var mix_pos := 0
	var out: Array[PackedByteArray] = []
	var streams: Array[AudioStreamWAV] = []
	var ready := false
	var player: AudioStreamPlayer
	var sync: AudioStreamSynchronized   # battle: base + hype layers, sample-locked
	var gain := 0.0


var enabled := true
var muted := false
var render_usec := 0                 # total CPU spent rendering (profiling)

var _tracks := {}                    # name -> Track
var _want := ""                      # requested track ("" = silence)
var _cur := ""                       # track actually faded in (the requested one once it's rendered)
var _intensity := 0.0
var _hype := 0.0                     # smoothed intensity


func _ready() -> void:
	_compose()


func _compose() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 140084                 # same music every launch
	_tracks["menu"] = _compose_menu(rng)
	_tracks["battle"] = _compose_battle(rng)


## "menu", "battle", or "" to stop. Crossfades; a track that is still rendering starts when ready.
func play(track: String) -> void:
	_want = track


## 0..1: how close the round is to its end. Fades in the battle track's hype layer.
func set_intensity(x: float) -> void:
	_intensity = clampf(x, 0.0, 1.0)


func set_muted(m: bool) -> void:
	muted = m


func is_ready(track: String) -> bool:
	return _tracks.has(track) and (_tracks[track] as Track).ready


func _process(delta: float) -> void:
	# Until the menu track exists we're on the title screen with nothing to play: render faster
	# (~8 ms/frame) so music starts within a second or two instead of ~5 s.
	render(BUDGET_USEC if is_ready("menu") else BUDGET_USEC * 4)
	if _want == "" or is_ready(_want):
		_cur = _want
	_hype = move_toward(_hype, _intensity, delta * 0.5)
	for name: String in _tracks:
		var tr: Track = _tracks[name]
		if not tr.ready:
			continue
		var p := tr.player
		p.stream_paused = muted
		if muted:
			continue
		var target := 1.0 if enabled and name == _cur else 0.0
		if target > 0.0 and not p.playing:
			tr.gain = 0.0
			p.play()
		tr.gain = move_toward(tr.gain, target, delta / FADE_TIME)
		if tr.gain <= 0.0:
			if p.playing:
				p.stop()
			continue
		p.volume_db = VOLUME_DB + linear_to_db(tr.gain)
		if tr.sync:
			tr.sync.set_sync_stream_volume(1, linear_to_db(maxf(0.001, clampf(_hype / 0.6, 0.0, 1.0))))


## Spend up to budget_usec rendering; the requested track first. Returns false once all are done.
func render(budget_usec: int) -> bool:
	var t0 := Time.get_ticks_usec()
	if _tracks.is_empty():
		_compose()
	var more := true
	while Time.get_ticks_usec() - t0 < budget_usec:
		var tr := _next_track()
		if tr == null:
			more = false
			break
		_step(tr)
	render_usec += Time.get_ticks_usec() - t0
	return more


func _next_track() -> Track:
	if _tracks.has(_want) and not (_tracks[_want] as Track).ready:
		return _tracks[_want]
	for name: String in ORDER:
		if not (_tracks[name] as Track).ready:
			return _tracks[name]
	return null


## One bounded unit of work (well under a millisecond): allocate a bus, render or add a slice of
## a note, tile a bus, mix a slice, or build a stream.
func _step(tr: Track) -> void:
	match tr.phase:
		0:
			var bn := tr.bus_names[tr.buses.size()]
			var b := PackedFloat32Array()
			b.resize(tr.period[bn])
			b.fill(0.0)
			tr.buses[bn] = b
			if tr.buses.size() == tr.bus_names.size():
				tr.phase = 1
		1:
			_step_note(tr)
			if tr.note_i >= tr.notes.size():
				tr.notes.clear()
				tr.cache.clear()
				tr.phase = 2
		2:
			if tr.tile_i < tr.bus_names.size():
				var bn := tr.bus_names[tr.tile_i]
				var b: PackedFloat32Array = tr.buses[bn]
				if b.size() < tr.n:
					b.append_array(b.slice(0, tr.period[bn]))
					tr.buses[bn] = b
				else:
					tr.tile_i += 1
			elif tr.out.size() < tr.layers:
				var o := PackedByteArray()
				o.resize(tr.n * 2)
				tr.out.append(o)
			else:
				tr.phase = 3
		3:
			var to := mini(tr.n, tr.mix_pos + SLICE)
			if tr.name == "battle":
				_mix_battle(tr, tr.mix_pos, to)
			else:
				_mix_menu(tr, tr.mix_pos, to)
			tr.mix_pos = to
			if to >= tr.n:
				tr.buses.clear()
				tr.phase = 4
		4:
			if tr.streams.size() < tr.out.size():
				tr.streams.append(_wav(tr.out[tr.streams.size()], tr.n))
			else:
				_finish(tr)
				tr.phase = 5


## Render the current note into the cache if it's new (a slice per step), else add a slice of the
## cached copy into its bus at the note's amplitude, wrapping past the bus end.
func _step_note(tr: Track) -> void:
	var nd := tr.notes[tr.note_i]
	var key: String = nd["key"]
	var total: int = nd["len"]
	if not tr.cache.has(key):
		var c := PackedFloat32Array()
		c.resize(total)
		c.fill(0.0)
		tr.cache[key] = c
		tr.synth_pos = 0
	var src: PackedFloat32Array = tr.cache[key]
	if tr.synth_pos >= 0:
		var end := mini(total, tr.synth_pos + SLICE)
		if nd["v"] == TONE:
			_render_tone(src, nd, tr.synth_pos, end)
		else:
			_render_drum(src, nd, tr.synth_pos, end)
		tr.synth_pos = end if end < total else -1
		return
	var buf: PackedFloat32Array = tr.buses[nd["bus"]]
	var size := buf.size()
	var from := tr.note_pos
	var to := mini(total, from + SLICE * 4)
	var j: int = (int(nd["s"]) + from) % size
	var amp: float = nd["amp"]
	if nd["v"] == KICK:   # also write the side-chain envelope that ducks pads and bass
		var side: PackedFloat32Array = tr.buses["side"]
		for k in range(from, to):
			buf[j] += src[k] * amp
			var e := minf(1.0, k / 110.0) * exp(-k / (0.12 * RATE))
			if e > side[j]:
				side[j] = e
			j += 1
			if j >= size:
				j = 0
	else:
		for k in range(from, to):
			buf[j] += src[k] * amp
			j += 1
			if j >= size:
				j = 0
	tr.note_pos = to
	if to >= total:
		tr.note_i += 1
		tr.note_pos = 0


func _finish(tr: Track) -> void:
	tr.player = AudioStreamPlayer.new()
	tr.player.volume_db = -80.0
	if tr.out.size() == 2:
		tr.sync = AudioStreamSynchronized.new()
		tr.sync.stream_count = 2
		tr.sync.set_sync_stream(0, tr.streams[0])
		tr.sync.set_sync_stream(1, tr.streams[1])
		tr.sync.set_sync_stream_volume(1, -60.0)
		tr.player.stream = tr.sync
	else:
		tr.player.stream = tr.streams[0]
	tr.out.clear()
	tr.streams.clear()
	add_child(tr.player)
	tr.ready = true


func _wav(data: PackedByteArray, n: int) -> AudioStreamWAV:
	var s := AudioStreamWAV.new()
	s.format = AudioStreamWAV.FORMAT_16_BITS
	s.mix_rate = RATE
	s.stereo = false
	s.data = data
	s.loop_mode = AudioStreamWAV.LOOP_FORWARD
	s.loop_begin = 0
	s.loop_end = n
	return s


# --- composition ---------------------------------------------------------------------------

func _new_track(name: String, bpm: float, bars: int) -> Track:
	var tr := Track.new()
	tr.name = name
	tr.spb = RATE * 60.0 / bpm
	tr.n = roundi(bars * 4 * tr.spb)
	return tr


func _bus(tr: Track, name: String, bars: int) -> void:
	tr.bus_names.append(name)
	tr.period[name] = roundi(bars * 4 * tr.spb)


func _mf(midi: float) -> float:
	return 440.0 * pow(2.0, (midi - 69.0) / 12.0)


## A tone at `beat` (from loop start), gate `beats` long, using preset p (merged over TONE_DEFAULT).
func _note(tr: Track, bus: String, beat: float, beats: float, midi: float, amp: float, p: Dictionary, rng: RandomNumberGenerator) -> void:
	var nd := TONE_DEFAULT.merged(p, true)
	var size: int = tr.period[bus]
	var gate := maxi(1, roundi(beats * tr.spb))
	nd["bus"] = bus
	nd["s"] = roundi(beat * tr.spb) % size
	nd["gate"] = gate
	nd["len"] = mini(size, gate + int(float(nd["rel"]) * 4.0 * RATE))
	nd["key"] = "%s|%d|%d" % [nd["id"], roundi(midi * 100.0), gate]
	nd["f"] = _mf(midi)
	nd["amp"] = amp
	nd["st"] = PackedFloat32Array([0.0, rng.randf(), 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
	tr.notes.append(nd)


func _drum(tr: Track, bus: String, beat: float, kind: int, amp: float, tau: float, rng: RandomNumberGenerator) -> void:
	var size: int = tr.period[bus]
	var dur := {KICK: 0.38, SNARE: tau * 5.0, HAT: tau * 6.0 + 0.004}[kind] as float
	tr.notes.append({"v": kind, "bus": bus, "s": roundi(beat * tr.spb) % size, "len": int(dur * RATE),
		"amp": amp, "tau": tau, "key": "d%d|%d" % [kind, roundi(tau * 1000.0)], "st": [rng.randi(), 0.0, 0.0, 0.0]})


func _compose_menu(rng: RandomNumberGenerator) -> Track:
	var tr := _new_track("menu", 84.0, 8)
	_bus(tr, "pad", 4)
	_bus(tr, "sub", 4)
	_bus(tr, "arp", 8)
	var pad := {"id": "mpad", "w": SAW, "w2": SAW, "det": 1.0058, "mix2": 0.9, "atk": 0.7, "dec": 1.5, "sus": 0.75,
		"rel": 0.5, "c0": 450.0, "c1": 1500.0, "ct": 1.2, "vib": 0.0015, "vr": 4.3, "vd": 0.0}
	var sub := {"id": "msub", "w": SINE, "atk": 0.25, "dec": 2.0, "sus": 0.8, "rel": 0.4}
	var bell := {"id": "mbell", "w": TRI, "w2": SINE, "det": 2.0, "mix2": 0.3, "atk": 0.004, "dec": 0.35, "sus": 0.0,
		"rel": 0.2, "c0": 4500.0, "c1": 1600.0, "ct": 0.12, "vib": 0.003, "vr": 5.0, "vd": 0.12}
	var air := {"id": "mair", "w": SINE, "w2": SINE, "det": 2.0, "mix2": 0.12, "atk": 0.35, "dec": 1.0, "sus": 0.7,
		"rel": 0.5, "vib": 0.005, "vr": 4.8, "vd": 0.4}
	for bar in 4:
		var chord: Array = MENU_CHORDS[bar]
		for m: int in chord:
			_note(tr, "pad", bar * 4.0, 3.9, m, 0.06, pad, rng)
		_note(tr, "sub", bar * 4.0, 3.8, MENU_ROOTS[bar], 0.13, sub, rng)
	for bar in 8:
		var chord: Array = MENU_CHORDS[bar % 4]
		var tones := [chord[0] + 12, chord[1] + 12, chord[2] + 12, chord[3] + 12]
		var pat: Array = ARP_PATTERNS[rng.randi_range(0, 2) if bar < 4 else rng.randi_range(1, 4)]
		for k in 8:
			var idx: int = pat[k * 2]
			if idx < 0 or (bar >= 4 and k == 7 and rng.randf() < 0.5):
				continue
			var m: int = tones[idx] + (12 if bar >= 4 and k % 4 == 2 else 0)
			_note(tr, "arp", bar * 4.0 + k * 0.5, 0.3, m, 0.16 if k % 2 == 0 else 0.11, bell, rng)
		if bar >= 4:   # a slow high line over the second half
			for h in 2:
				_note(tr, "arp", bar * 4.0 + h * 2.0, 1.8, chord[rng.randi_range(1, 3)] + 24, 0.07, air, rng)
	return tr


func _compose_battle(rng: RandomNumberGenerator) -> Track:
	var tr := _new_track("battle", 140.0, 16)
	tr.layers = 2
	_bus(tr, "drums", 2)
	_bus(tr, "side", 2)
	_bus(tr, "hit", 16)
	_bus(tr, "bass", 8)
	_bus(tr, "pad", 8)
	_bus(tr, "lead", 16)
	_bus(tr, "hats2", 1)
	_bus(tr, "counter", 8)
	var bass := {"id": "bbass", "w": SAW, "sub": 0.6, "atk": 0.002, "dec": 0.12, "sus": 0.5, "rel": 0.03,
		"c0": 2600.0, "c1": 380.0, "ct": 0.05}
	var pad := {"id": "bpad", "w": SAW, "w2": SAW, "det": 1.007, "mix2": 0.9, "atk": 0.04, "dec": 0.6, "sus": 0.7,
		"rel": 0.15, "c0": 800.0, "c1": 2000.0, "ct": 0.5}
	var arp := {"id": "barp", "w": SQUARE, "pw": 0.25, "atk": 0.002, "dec": 0.07, "sus": 0.35, "rel": 0.04,
		"c0": 6500.0, "c1": 2600.0, "ct": 0.05}
	var lead := {"id": "blead", "w": SQUARE, "pw": 0.5, "w2": SINE, "det": 1.0, "mix2": 0.5, "atk": 0.01, "dec": 0.3,
		"sus": 0.7, "rel": 0.06, "c0": 3800.0, "c1": 2400.0, "ct": 0.2, "vib": 0.006, "vr": 5.5, "vd": 0.18}

	# Drums: a 2-bar loop, plus crashes and snare fills across the whole 16 bars.
	for bar in 2:
		for s in 16:
			var beat := bar * 4.0 + s * 0.25
			if s % 4 == 0 or (bar == 1 and s == 14):
				_drum(tr, "drums", beat, KICK, 0.9, 0.2, rng)
			if s == 4 or s == 12:
				_drum(tr, "drums", beat, SNARE, 0.7, 0.09, rng)
			if bar == 1 and s == 15:
				_drum(tr, "drums", beat, SNARE, 0.18, 0.05, rng)
			if s % 4 == 2:
				_drum(tr, "drums", beat, HAT, 0.45 if s != 14 or bar == 0 else 0.4, 0.02 if s != 14 or bar == 0 else 0.11, rng)
	for bar: int in [0, 8]:
		_drum(tr, "hit", bar * 4.0, HAT, 0.5, 0.45, rng)
	for bar: int in [7, 15]:
		var steps := [14, 15] if bar == 7 else [8, 10, 12, 13, 14, 15]
		for k in steps.size():
			_drum(tr, "hit", bar * 4.0 + steps[k] * 0.25, SNARE, 0.25 + 0.35 * k / steps.size(), 0.07, rng)

	# Bass (8ths, octave bounce with walk-ups into the next chord) and pads: an 8-bar loop.
	for bar in 8:
		var root: int = BATTLE_ROOTS[bar]
		var line := [0, 12, 0, 12, 0, 12, 0, 12]
		if bar == 3:
			line = [0, 12, 0, 12, 0, 12, 0, 2]
		elif bar == 7:
			line = [0, 12, 0, 12, 0, 12, 3, 4]
		for k in 8:
			_note(tr, "bass", bar * 4.0 + k * 0.5, 0.38, root + line[k], 0.5 if k % 2 == 0 else 0.42, bass, rng)
		var chord: Array = BATTLE_CHORDS[bar]
		for m: int in chord:
			_note(tr, "pad", bar * 4.0, 3.85, m, 0.07, pad, rng)

	# Arpeggio lead (16ths over chord tones), new patterns each 2 bars, up an octave for bars 13-16.
	var pat: Array = ARP_PATTERNS[0]
	for bar in 16:
		var chord: Array = BATTLE_CHORDS[bar % 8]
		var tones := [chord[0] + 12, chord[1] + 12, chord[2] + 12, chord[0] + 24]
		if bar % 2 == 0:
			pat = ARP_PATTERNS[rng.randi_range(0, 2) if bar < 8 else rng.randi_range(1, 4)]
		var up := 12 if bar >= 12 else 0
		for s in 16:
			var idx: int = pat[s]
			if idx < 0:
				continue
			_note(tr, "lead", bar * 4.0 + s * 0.25, 0.16, tones[idx] + up, 0.2 if s % 4 == 0 else 0.14, arp, rng)

	# Hype layer: 16th hats + quarter "ride" (1-bar loop), and a counter-melody (8-bar loop).
	for s in 16:
		if s % 2 == 1:
			_drum(tr, "hats2", s * 0.25, HAT, 0.3 if s % 4 == 3 else 0.22, 0.014, rng)
		if s % 4 == 0:
			_drum(tr, "hats2", s * 0.25, HAT, 0.16, 0.1, rng)
	var minor := [9, 11, 0, 2, 4, 5, 7]
	var harmonic := [9, 11, 0, 2, 4, 5, 8]
	var cur := 72
	for bar in 8:
		var pcs: Array = harmonic if bar == 7 else minor
		var scale: Array[int] = []
		for m in range(64, 86):
			if (m % 12) in pcs:
				scale.append(m)
		var chord_pcs: Array[int] = []
		for m: int in BATTLE_CHORDS[bar]:
			chord_pcs.append(m % 12)
		var rhythm: Array = RHYTHMS[rng.randi_range(0, RHYTHMS.size() - 1)]
		var beat := 0.0
		for k in rhythm.size():
			var d: float = rhythm[k]
			var i := scale.find(cur)
			if i < 0:
				i = scale.size() / 2
			if k == 0:   # downbeat: nearest chord tone
				var best := i
				for o in [0, 1, -1, 2, -2, 3, -3]:
					var c: int = clampi(i + o, 0, scale.size() - 1)
					if (scale[c] % 12) in chord_pcs:
						best = c
						break
				i = best
			else:
				var steps: Array[int] = [-2, -1, -1, 1, 1, 2]
				i = clampi(i + steps[rng.randi_range(0, 5)], 2, scale.size() - 3)
			cur = scale[i]
			_note(tr, "counter", bar * 4.0 + beat, d * 0.85, cur, 0.17, lead, rng)
			beat += d
	return tr


# --- synthesis -----------------------------------------------------------------------------

## Render samples [from, to) of a tone note (at amp 1) into buf; oscillator/filter state lives in nd["st"].
func _render_tone(buf: PackedFloat32Array, nd: Dictionary, from: int, to: int) -> void:
	var f: float = nd["f"]
	var w: int = nd["w"]
	var w2: int = nd["w2"]
	var det: float = nd["det"]
	var mix2: float = nd["mix2"]
	var sub: float = nd["sub"]
	var pw: float = nd["pw"]
	var gate: int = nd["gate"]
	var total: int = nd["len"]
	var c0: float = nd["c0"]
	var c1: float = nd["c1"]
	var ct := maxf(0.001, float(nd["ct"]))
	var vib: float = nd["vib"]
	var vr: float = nd["vr"]
	var vd: float = nd["vd"]
	var sus: float = nd["sus"]
	var atk_n := maxf(1.0, float(nd["atk"]) * RATE)
	var kd := exp(-1.0 / maxf(1.0, float(nd["dec"]) * RATE))
	var kr := exp(-1.0 / maxf(1.0, float(nd["rel"]) * RATE))
	var fade_at := total - 64
	var st: PackedFloat32Array = nd["st"]
	var p1 := st[0]
	var p2 := st[1]
	var ps := st[2]
	var y1 := st[3]
	var y2 := st[4]
	var env := st[5]
	var dt1 := st[6]
	var dt2 := st[7]
	var a := st[8]
	for i in range(from, to):
		if (i & 15) == 0:   # control rate: vibrato and filter sweep
			var tt := float(i) / RATE
			var fm := 1.0
			if vib > 0.0 and tt > vd:
				fm += vib * minf(1.0, (tt - vd) * 3.0) * sin(TAU * vr * tt)
			dt1 = f * fm / RATE
			dt2 = dt1 * det
			var c := c1 + (c0 - c1) * exp(-tt / ct)
			a = 1.0 - exp(-TAU * minf(c, 9500.0) / RATE)
		if i < atk_n:
			env = float(i + 1) / atk_n
		elif i < gate:
			env = sus + (env - sus) * kd
		else:
			env *= kr
		p1 += dt1
		if p1 >= 1.0:
			p1 -= 1.0
		var v := 0.0
		var x := 0.0
		if w == SAW:   # band-limited (polyBLEP) saw
			v = 2.0 * p1 - 1.0
			if p1 < dt1:
				x = p1 / dt1
				v -= x + x - x * x - 1.0
			elif p1 > 1.0 - dt1:
				x = (p1 - 1.0) / dt1
				v -= x * x + x + x + 1.0
		elif w == SQUARE:   # band-limited pulse, width pw
			v = 1.0 if p1 < pw else -1.0
			if p1 < dt1:
				x = p1 / dt1
				v += x + x - x * x - 1.0
			elif p1 > 1.0 - dt1:
				x = (p1 - 1.0) / dt1
				v += x * x + x + x + 1.0
			var q := p1 - pw
			if q < 0.0:
				q += 1.0
			if q < dt1:
				x = q / dt1
				v -= x + x - x * x - 1.0
			elif q > 1.0 - dt1:
				x = (q - 1.0) / dt1
				v -= x * x + x + x + 1.0
		elif w == TRI:
			v = 4.0 * absf(p1 - 0.5) - 1.0
		else:
			v = sin(TAU * p1)
		if mix2 > 0.0:
			p2 += dt2
			if p2 >= 1.0:
				p2 -= 1.0
			if w2 == SAW:
				var v2 := 2.0 * p2 - 1.0
				if p2 < dt2:
					x = p2 / dt2
					v2 -= x + x - x * x - 1.0
				elif p2 > 1.0 - dt2:
					x = (p2 - 1.0) / dt2
					v2 -= x * x + x + x + 1.0
				v += v2 * mix2
			else:
				v += sin(TAU * p2) * mix2
		if sub > 0.0:
			ps += dt1 * 0.5
			if ps >= 1.0:
				ps -= 1.0
			v += sin(TAU * ps) * sub
		y1 += (v - y1) * a
		y2 += (y1 - y2) * a
		var out := y2 * env
		if i > fade_at:
			out *= float(total - i) / 64.0
		buf[i] = out
	st[0] = p1
	st[1] = p2
	st[2] = ps
	st[3] = y1
	st[4] = y2
	st[5] = env
	st[6] = dt1
	st[7] = dt2
	st[8] = a


## Kick (pitch-swept sine + click), snare (band-passed noise + tone) and hat (high-passed noise),
## rendered at amp 1 into buf. Noise is an inline LCG; state lives in nd["st"].
func _render_drum(buf: PackedFloat32Array, nd: Dictionary, from: int, to: int) -> void:
	var kind: int = nd["v"]
	var tau: float = float(nd["tau"]) * RATE
	var total: int = nd["len"]
	var st: Array = nd["st"]
	var x: int = st[0]
	var lp: float = st[1]
	var hp: float = st[2]
	var ph: float = st[3]
	if kind == KICK:
		for i in range(from, to):
			var t := float(i)
			ph += (44.0 + 125.0 * exp(-t / (0.028 * RATE))) / RATE
			if ph >= 1.0:
				ph -= 1.0
			var v := clampf(sin(TAU * ph) * exp(-t / tau) * minf(1.0, t / 25.0) * 1.3, -1.0, 1.0)
			v = v * (1.5 - 0.5 * v * v)
			if i < 120:
				x = (x * 1664525 + 1013904223) & 0xffffffff
				v += (float(x) / 2147483648.0 - 1.0) * 0.35 * (1.0 - t / 120.0)
			if i > total - 64:
				v *= float(total - i) / 64.0
			buf[i] = v
	elif kind == SNARE:
		var a_lp := 1.0 - exp(-TAU * 6500.0 / RATE)
		var a_hp := 1.0 - exp(-TAU * 1000.0 / RATE)
		for i in range(from, to):
			var t := float(i)
			x = (x * 1664525 + 1013904223) & 0xffffffff
			lp += (float(x) / 2147483648.0 - 1.0 - lp) * a_lp
			hp += (lp - hp) * a_hp
			var v := (lp - hp) * 1.8 * exp(-t / tau) * minf(1.0, t / 10.0)
			ph += 180.0 * (1.0 + 0.5 * exp(-t / 200.0)) / RATE
			if ph >= 1.0:
				ph -= 1.0
			v += (4.0 * absf(ph - 0.5) - 1.0) * 0.55 * exp(-t / (0.04 * RATE))
			if i > total - 64:
				v *= float(total - i) / 64.0
			buf[i] = v
	else:
		for i in range(from, to):   # first difference of white noise: bright, no low end
			var t := float(i)
			x = (x * 1664525 + 1013904223) & 0xffffffff
			var n := float(x) / 2147483648.0 - 1.0
			var v := (n - lp) * 0.5 * exp(-t / tau) * minf(1.0, t / 8.0)
			lp = n
			if i > total - 64:
				v *= float(total - i) / 64.0
			buf[i] = v
	st[0] = x
	st[1] = lp
	st[2] = hp
	st[3] = ph


# Soft clip (inlined in the mixers): v - (4/27) v^3 on [-1.5, 1.5], topping out at exactly 1.0.

func _mix_menu(tr: Track, from: int, to: int) -> void:
	var pad: PackedFloat32Array = tr.buses["pad"]
	var sub: PackedFloat32Array = tr.buses["sub"]
	var arp: PackedFloat32Array = tr.buses["arp"]
	var o: PackedByteArray = tr.out[0]
	var n := tr.n
	var d := roundi(tr.spb * 0.75)    # dotted-8th echo, read circularly so the tail wraps
	for i in range(from, to):
		var k1 := i - d
		if k1 < 0:
			k1 += n
		var k2 := k1 - d
		if k2 < 0:
			k2 += n
		var k3 := k2 - d
		if k3 < 0:
			k3 += n
		var k4 := k3 - d
		if k4 < 0:
			k4 += n
		var e := arp[i] + 0.42 * arp[k1] + 0.18 * arp[k2] + 0.075 * arp[k3] + 0.03 * arp[k4]
		var v := clampf(pad[i] * 1.4 + sub[i] + e * 1.4, -1.5, 1.5)
		o.encode_s16(i * 2, int((v - 0.148148 * v * v * v) * 29000.0))


func _mix_battle(tr: Track, from: int, to: int) -> void:
	var drums: PackedFloat32Array = tr.buses["drums"]
	var side: PackedFloat32Array = tr.buses["side"]
	var hit: PackedFloat32Array = tr.buses["hit"]
	var bass: PackedFloat32Array = tr.buses["bass"]
	var pad: PackedFloat32Array = tr.buses["pad"]
	var lead: PackedFloat32Array = tr.buses["lead"]
	var hats2: PackedFloat32Array = tr.buses["hats2"]
	var counter: PackedFloat32Array = tr.buses["counter"]
	var o0: PackedByteArray = tr.out[0]
	var o1: PackedByteArray = tr.out[1]
	var n := tr.n
	var d := roundi(tr.spb * 0.75)
	for i in range(from, to):
		var k1 := i - d
		if k1 < 0:
			k1 += n
		var k2 := k1 - d
		if k2 < 0:
			k2 += n
		var k3 := k2 - d
		if k3 < 0:
			k3 += n
		var sd := side[i]
		var ld := lead[i] + 0.35 * lead[k1] + 0.12 * lead[k2] + 0.04 * lead[k3]
		var v := drums[i] * 0.45 + hit[i] * 0.6 + bass[i] * (0.75 - 0.25 * sd) + pad[i] * (1.0 - 0.7 * sd) + ld * 0.8
		v = clampf(v, -1.5, 1.5)
		o0.encode_s16(i * 2, int((v - 0.148148 * v * v * v) * 29000.0))
		var h := clampf(hats2[i] * 0.6 + (counter[i] + 0.3 * counter[k1] + 0.09 * counter[k2]) * 0.8, -1.5, 1.5)
		o1.encode_s16(i * 2, int((h - 0.148148 * h * h * h) * 29000.0))

extends Node
## Procedural sound and adaptive music. No audio files: every sample is computed here and
## pushed into an AudioStreamGenerator.
##
## Sound effects are short "voices" (a frequency glide + an envelope + optional noise).
## The music is a 112 BPM loop in A minor with four layers. Their volume follows how well the
## Shadow is currently predicting you (`game.acc_top1`):
##   bass pulse  always      hats       > ~20 %
##   arpeggio    > ~33 %     dissonant pad  > ~48 %
## So the better it reads you, the more tense the music gets.
## Audio only; it never touches the simulation.

const RATE := 22050.0
const STEP := 60.0 / 112.0 / 4.0    # one 16th note in seconds
const MASTER := 0.55

# Voice kinds
const WINDUP := 0
const THUD := 1
const HIT := 2
const WHOOSH := 3
const CHIME := 4
const RUMBLE := 5
const DRONE := 6
const DEATH := 7
const BLIP := 8

const BASS_NOTES := [55.0, 55.0, 43.65, 49.0]            # A1 A1 F1 G1, one per bar
const CHORDS := [[220.0, 261.63, 329.63], [220.0, 261.63, 329.63],
		[174.61, 220.0, 261.63], [196.0, 246.94, 293.66]]  # Am Am F G

var game                            # main.gd
var muted := false

var _pb: AudioStreamGeneratorPlayback
var _voices: Array = []             # [kind, t, dur, f0, f1, vol, phase, lowpass]
var _rng := RandomNumberGenerator.new()

# Music state
var _gains := [0.0, 0.0, 0.0, 0.0]
var _music_on := 0.0                # fades music in/out as a whole
var _step_t := 0.0
var _step := 0
var _bass_f := 55.0
var _bass_ph := 0.0
var _bass_env := 0.0
var _hat_env := 0.0
var _arp_f := 220.0
var _arp_ph := 0.0
var _arp_env := 0.0
var _pad_ph := [0.0, 0.0, 0.0]
var _pad_t := 0.0

var _bass_k := exp(-1.0 / (RATE * 0.22))
var _hat_k := exp(-1.0 / (RATE * 0.025))
var _arp_k := exp(-1.0 / (RATE * 0.10))


func _ready() -> void:
	_rng.randomize()
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = RATE
	gen.buffer_length = 0.12
	var player := AudioStreamPlayer.new()
	player.stream = gen
	add_child(player)
	player.play()
	_pb = player.get_stream_playback()


# --- Sound effect API ----------------------------------------------------------

## Rising tone during an attack's wind-up, so you can dodge by ear.
func windup(seconds: float) -> void:
	_add(WINDUP, seconds, 300.0 * _rng.randf_range(0.95, 1.05), 900.0, 0.07)


func thud() -> void:
	_add(THUD, 0.3, 95.0, 38.0, 0.55)


func hit() -> void:
	_add(HIT, 0.35, 190.0, 70.0, 0.32)


func whoosh() -> void:
	_add(WHOOSH, 0.2, 0.0, 0.0, 0.22)


func chime() -> void:
	_add(CHIME, 0.7, 880.0, 880.0, 0.12)


func rumble() -> void:
	_add(RUMBLE, 0.7, 0.0, 0.0, 0.3)


func drone() -> void:
	_add(DRONE, 2.2, 55.0, 41.2, 0.3)


func death() -> void:
	_add(DEATH, 1.4, 220.0, 45.0, 0.4)


## One syllable of the Shadow's voice: a short, low, slightly random square chirp.
func blip() -> void:
	var f := _rng.randf_range(140.0, 200.0)
	_add(BLIP, 0.045, f, f * 0.8, 0.09)


func _add(kind: int, dur: float, f0: float, f1: float, vol: float) -> void:
	if _voices.size() > 24:
		_voices.pop_front()
	_voices.append([kind, 0.0, dur, f0, f1, vol, 0.0, 0.0])


# --- Mixing ----------------------------------------------------------------------

func _process(delta: float) -> void:
	if _pb == null:
		return
	_update_music_targets(delta)
	var n := _pb.get_frames_available()
	if n <= 0:
		return
	var dt := 1.0 / RATE
	for i in n:
		var s := 0.0
		for v in _voices:
			s += _voice(v, dt)
		s += _music(dt)
		s = s * MASTER
		s = s / (1.0 + absf(s))         # soft clip
		if muted:
			s = 0.0
		_pb.push_frame(Vector2(s, s))
	var alive: Array = []
	for v in _voices:
		if float(v[1]) < float(v[2]):
			alive.append(v)
	_voices = alive


func _voice(v: Array, dt: float) -> float:
	var t: float = v[1]
	var dur: float = v[2]
	if t >= dur:
		return 0.0
	v[1] = t + dt
	var u := t / dur
	var f0: float = v[3]
	var f1: float = v[4]
	var vol: float = v[5]
	var f := f0 * pow(f1 / f0, u) if f0 > 0.0 else 0.0
	v[6] = float(v[6]) + f * dt
	var ph: float = v[6]
	match int(v[0]):
		WINDUP:
			var env := minf(1.0, t / 0.05) * (0.4 + 0.6 * u) * (1.0 - smoothstep(0.92, 1.0, u))
			var trem := 0.75 + 0.25 * sin(TAU * t * (6.0 + 20.0 * u))
			return sin(TAU * ph) * env * trem * vol
		THUD:
			var env := exp(-t * 14.0)
			var click := _rng.randf_range(-1.0, 1.0) * exp(-t * 90.0) * 0.5
			return (sin(TAU * ph) + click) * env * vol
		HIT:
			var env := exp(-t * 9.0)
			var sq := 1.0 if fmod(ph, 1.0) < 0.5 else -1.0
			return (sq * 0.6 + _rng.randf_range(-1.0, 1.0) * 0.4) * env * vol
		WHOOSH, RUMBLE:
			# Low-passed noise; the cutoff sweeps up then down for a whoosh, stays low for rumble.
			var cut := 0.05 + 0.35 * sin(PI * u) if int(v[0]) == WHOOSH else 0.02
			v[7] = float(v[7]) + cut * (_rng.randf_range(-1.0, 1.0) - float(v[7]))
			var env := sin(PI * u) if int(v[0]) == WHOOSH else (1.0 - u) * minf(1.0, t / 0.05)
			return float(v[7]) * env * vol * 3.0
		CHIME:
			var env := exp(-t * 5.0)
			return (sin(TAU * ph) + 0.5 * sin(TAU * ph * 1.5)) * env * vol
		DRONE:
			var env := sin(PI * u)
			return (sin(TAU * ph) + sin(TAU * ph * 1.013) + 0.3 * sin(TAU * ph * 3.0)) * env * vol * 0.5
		BLIP:
			var env := minf(1.0, t / 0.004) * (1.0 - u)
			var sq := 1.0 if fmod(ph, 1.0) < 0.35 else -1.0
			return (sq * 0.5 + sin(TAU * ph * 2.0) * 0.5) * env * vol
		DEATH:
			var env := (1.0 - u) * minf(1.0, t / 0.02)
			return (sin(TAU * ph) * 0.8 + _rng.randf_range(-1.0, 1.0) * 0.2 * (1.0 - u)) * env * vol
	return 0.0


# --- Music -------------------------------------------------------------------------

func _update_music_targets(delta: float) -> void:
	var playing: bool = game != null and not game.is_over
	var acc: float = game.acc_top1 if game != null else 0.0
	# 10 % is a random guess; map 10 %..60 % onto 0..1 intensity.
	var x := clampf((acc - 0.1) / 0.5, 0.0, 1.0)
	var targets := [0.8, smoothstep(0.15, 0.35, x), smoothstep(0.35, 0.55, x), smoothstep(0.6, 0.85, x)]
	var k := 1.0 - exp(-delta * 1.5)
	for i in 4:
		_gains[i] = lerpf(float(_gains[i]), float(targets[i]), k)
	_music_on = lerpf(_music_on, 1.0 if playing else 0.0, 1.0 - exp(-delta * (2.0 if playing else 0.8)))


func _music(dt: float) -> float:
	if _music_on < 0.001:
		return 0.0
	_step_t += dt
	if _step_t >= STEP:
		_step_t -= STEP
		_on_step()
	var s := 0.0
	# Bass: sine + a little 2nd harmonic.
	_bass_ph += _bass_f * dt
	s += (sin(TAU * _bass_ph) + 0.3 * sin(TAU * _bass_ph * 2.0)) * _bass_env * 0.35 * float(_gains[0])
	_bass_env *= _bass_k
	# Hats: noise blips.
	s += _rng.randf_range(-1.0, 1.0) * _hat_env * 0.08 * float(_gains[1])
	_hat_env *= _hat_k
	# Arpeggio: soft square.
	_arp_ph += _arp_f * dt
	var sq := 1.0 if fmod(_arp_ph, 1.0) < 0.5 else -1.0
	s += (sq * 0.3 + sin(TAU * _arp_ph) * 0.7) * _arp_env * 0.07 * float(_gains[2])
	_arp_env *= _arp_k
	# Pad: chord root + tritone + detuned fifth, slowly swelling. Uneasy on purpose.
	var pg := float(_gains[3])
	if pg > 0.001:
		_pad_t += dt
		var root: float = CHORDS[floori(_step / 16.0) % 4][0] * 0.5
		var fs := [root, root * 1.4142, root * 1.5 * 1.006]
		var pad := 0.0
		for j in 3:
			_pad_ph[j] = float(_pad_ph[j]) + float(fs[j]) * dt
			pad += sin(TAU * float(_pad_ph[j]))
		s += pad * (0.6 + 0.4 * sin(TAU * _pad_t * 0.25)) * 0.035 * pg
	return s * _music_on


func _on_step() -> void:
	_step += 1
	var bar := floori(_step / 16.0) % 4
	var in_bar := _step % 16
	if in_bar % 4 == 0:
		_bass_f = BASS_NOTES[bar]
		_bass_env = 1.0
	_hat_env = 1.0 if in_bar % 2 == 1 else 0.45
	var chord: Array = CHORDS[bar]
	var pattern := [0, 1, 2, 1]
	var oct := 2.0 if in_bar >= 8 else 1.0
	_arp_f = float(chord[pattern[in_bar % 4]]) * oct
	_arp_env = 1.0

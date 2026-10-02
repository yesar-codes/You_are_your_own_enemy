extends Node2D
## Juice: particles and screen shake. Purely visual. It has its own RNG and never touches the
## simulation, so replays stay exact. Particles freeze during hit-stop along with the world.
##
## Shake uses the "trauma" model: hits add trauma (0..1), it decays over time, and the camera
## offset is trauma squared times a random direction. Squaring makes small bumps subtle and
## big hits violent.

const MAX_SHAKE := 14.0             # pixels at trauma 1
const TRAUMA_DECAY := 1.8           # per second
const MAX_PARTICLES := 600

var game                            # main.gd, for the hit-stop flag
var camera: Camera2D

var _trauma := 0.0
var _parts: Array = []              # [pos, vel, life, max_life, color, size]
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.randomize()


func shake(amount: float) -> void:
	_trauma = minf(1.0, _trauma + amount)


## Radial burst of `n` sparks.
func burst(at: Vector2, n: int, col: Color, speed: float = 260.0, life: float = 0.45, size: float = 2.5) -> void:
	for i in n:
		if _parts.size() >= MAX_PARTICLES:
			_parts.pop_front()
		var dir := Vector2.RIGHT.rotated(_rng.randf() * TAU)
		var v := dir * speed * _rng.randf_range(0.35, 1.0)
		var l := life * _rng.randf_range(0.6, 1.0)
		_parts.append([at, v, l, l, col, size * _rng.randf_range(0.6, 1.3)])


## A thin expanding ring made of sparks, used for strikes.
func ring(at: Vector2, radius: float, n: int, col: Color) -> void:
	for i in n:
		var dir := Vector2.RIGHT.rotated(TAU * float(i) / float(n) + _rng.randf() * 0.2)
		var l := _rng.randf_range(0.25, 0.4)
		_parts.append([at + dir * radius, dir * _rng.randf_range(60.0, 140.0), l, l, col, 2.0])


func clear() -> void:
	_parts.clear()
	_trauma = 0.0


func _process(delta: float) -> void:
	var frozen: bool = game != null and game.in_hitstop()
	if not frozen:
		var keep: Array = []
		for p in _parts:
			p[2] -= delta
			if p[2] <= 0.0:
				continue
			p[0] += p[1] * delta
			p[1] *= exp(-4.0 * delta)          # drag
			keep.append(p)
		_parts = keep
	_trauma = maxf(0.0, _trauma - TRAUMA_DECAY * delta)
	if camera != null:
		var s := _trauma * _trauma * MAX_SHAKE
		camera.offset = Vector2(_rng.randf_range(-1.0, 1.0), _rng.randf_range(-1.0, 1.0)) * s
	queue_redraw()


func _draw() -> void:
	for p in _parts:
		var t: float = p[2] / p[3]
		var c: Color = p[4]
		var pos: Vector2 = p[0]
		var vel: Vector2 = p[1]
		# Streaks: draw along the velocity so fast sparks look like motion lines.
		draw_line(pos, pos - vel * 0.03, Color(c, t), p[5])
		draw_circle(pos, p[5] * 0.6 * t, Color(c, t))

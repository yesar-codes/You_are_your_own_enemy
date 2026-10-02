extends Node2D
## The human-controlled circle. WASD / arrows to move, Space to dash.
## It never reads the keyboard itself: main.gd writes `frame_bits` every physics frame, either
## from the keyboard or from a recorded replay. That single input path is what makes replays
## (and the Ghost Shadow, which is this same script) exact.
## The game samples `move_input` / `consume_dash()` at 10 Hz.

const Cfg = preload("res://scripts/game_config.gd")
const InputBits = preload("res://scripts/input_bits.gd")

signal died
signal hurt                         # a hit that cost a heart (for screen shake, sound, hit-stop)
signal dashed

var hp: int = Cfg.PLAYER_HP
var alive := true
var frame_bits := 0                 # InputBits for this physics frame, set by main
var move_input := Vector2.ZERO      # decoded input this physics frame
var facing := Vector2.RIGHT
var dash_dir := Vector2.RIGHT       # direction of the latest dash

var _dash_left := 0.0
var _dash_cd := 0.0
var _invuln := 0.0
var _dash_latch := false            # set when a dash starts, cleared by consume_dash()
var _space_was_down := false
var _afterimages: Array = []        # [world position, age]; visual only, never read by the sim


func reset(at: Vector2) -> void:
	position = at
	hp = Cfg.PLAYER_HP
	alive = true
	frame_bits = 0
	move_input = Vector2.ZERO
	facing = Vector2.RIGHT
	dash_dir = Vector2.RIGHT
	_dash_left = 0.0
	_dash_cd = 0.0
	_invuln = 0.0
	_dash_latch = false
	_space_was_down = false
	_afterimages.clear()
	queue_redraw()


## True once per dash; the sampler calls this so a dash between ticks is never missed.
func consume_dash() -> bool:
	var d := _dash_latch
	_dash_latch = false
	return d


func take_hit() -> void:
	if not alive or _invuln > 0.0:
		return
	hp -= 1
	_invuln = 1.0
	hurt.emit()
	if hp <= 0:
		alive = false
		died.emit()


func _physics_process(delta: float) -> void:
	if not alive:
		return
	move_input = InputBits.to_vector(frame_bits)
	if move_input != Vector2.ZERO:
		facing = move_input

	_dash_cd = maxf(0.0, _dash_cd - delta)
	_invuln = maxf(0.0, _invuln - delta)

	var space_down := InputBits.dash_held(frame_bits)
	if space_down and not _space_was_down and _dash_cd <= 0.0:
		_dash_left = Cfg.DASH_TIME
		_dash_cd = Cfg.DASH_COOLDOWN
		dash_dir = facing.normalized()
		_dash_latch = true
		dashed.emit()
	_space_was_down = space_down

	var vel := move_input * Cfg.PLAYER_SPEED
	var dashing := _dash_left > 0.0
	if dashing:
		_dash_left -= delta
		vel = dash_dir * Cfg.DASH_SPEED
	position = Cfg.clamp_to_arena(position + vel * delta)
	_update_afterimages(delta, dashing)
	queue_redraw()


func _update_afterimages(delta: float, dashing: bool) -> void:
	for img in _afterimages:
		img[1] += delta
	while not _afterimages.is_empty() and float(_afterimages[0][1]) > 0.25:
		_afterimages.pop_front()
	if dashing:
		_afterimages.append([position, 0.0])


func _draw() -> void:
	for img in _afterimages:
		var fade := 1.0 - float(img[1]) / 0.25
		var p: Vector2 = img[0]
		draw_circle(p - position, Cfg.PLAYER_RADIUS * (0.6 + 0.4 * fade), Color(0.35, 0.85, 1.0, 0.35 * fade))
	var blink := _invuln > 0.0 and int(_invuln * 12.0) % 2 == 0
	var col := Color(0.35, 0.85, 1.0, 0.35 if blink else 1.0)
	draw_circle(Vector2.ZERO, Cfg.PLAYER_RADIUS, col)
	draw_line(Vector2.ZERO, facing.normalized() * (Cfg.PLAYER_RADIUS + 6.0), Color.WHITE, 2.0)
	if _dash_cd > 0.0:
		var frac := 1.0 - _dash_cd / Cfg.DASH_COOLDOWN
		draw_arc(Vector2.ZERO, Cfg.PLAYER_RADIUS + 5.0, -PI / 2.0, -PI / 2.0 + TAU * frac,
				24, Color(1, 1, 1, 0.5), 2.0)

extends Node2D
## The human-controlled circle. WASD / arrows to move, Space to dash.
## It only exposes state; the game (main.gd) samples `move_input` / `consume_dash()` at 10 Hz.

const Cfg = preload("res://scripts/game_config.gd")

signal died

var hp: int = Cfg.PLAYER_HP
var alive := true
var move_input := Vector2.ZERO      # raw input this physics frame
var facing := Vector2.RIGHT

var _dash_left := 0.0
var _dash_dir := Vector2.RIGHT
var _dash_cd := 0.0
var _invuln := 0.0
var _dash_latch := false            # set when a dash starts, cleared by consume_dash()
var _space_was_down := false


func reset(at: Vector2) -> void:
	position = at
	hp = Cfg.PLAYER_HP
	alive = true
	move_input = Vector2.ZERO
	facing = Vector2.RIGHT
	_dash_left = 0.0
	_dash_cd = 0.0
	_invuln = 0.0
	_dash_latch = false
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
	if hp <= 0:
		alive = false
		died.emit()


func _physics_process(delta: float) -> void:
	if not alive:
		return
	move_input = _read_input()
	if move_input != Vector2.ZERO:
		facing = move_input

	_dash_cd = maxf(0.0, _dash_cd - delta)
	_invuln = maxf(0.0, _invuln - delta)

	var space_down := Input.is_key_pressed(KEY_SPACE)
	if space_down and not _space_was_down and _dash_cd <= 0.0:
		_dash_left = Cfg.DASH_TIME
		_dash_cd = Cfg.DASH_COOLDOWN
		_dash_dir = facing.normalized()
		_dash_latch = true
	_space_was_down = space_down

	var vel := move_input * Cfg.PLAYER_SPEED
	if _dash_left > 0.0:
		_dash_left -= delta
		vel = _dash_dir * Cfg.DASH_SPEED
	position = Cfg.clamp_to_arena(position + vel * delta)
	queue_redraw()


func _read_input() -> Vector2:
	var v := Vector2.ZERO
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		v.y -= 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		v.y += 1.0
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		v.x -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		v.x += 1.0
	return v.normalized()


func _draw() -> void:
	var blink := _invuln > 0.0 and int(_invuln * 12.0) % 2 == 0
	var col := Color(0.35, 0.85, 1.0, 0.35 if blink else 1.0)
	draw_circle(Vector2.ZERO, Cfg.PLAYER_RADIUS, col)
	draw_line(Vector2.ZERO, facing.normalized() * (Cfg.PLAYER_RADIUS + 6.0), Color.WHITE, 2.0)
	if _dash_cd > 0.0:
		var frac := 1.0 - _dash_cd / Cfg.DASH_COOLDOWN
		draw_arc(Vector2.ZERO, Cfg.PLAYER_RADIUS + 5.0, -PI / 2.0, -PI / 2.0 + TAU * frac,
				24, Color(1, 1, 1, 0.5), 2.0)

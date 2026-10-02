extends Node2D
## The enemy's body. It circles the player and asks the game to fire a volley on a timer.
## All the intelligence lives in MarkovPredictor + AttackPlanner; this node is just the
## visible actor and the cooldown clock.

const Cfg = preload("res://scripts/game_config.gd")

signal fire_requested

var target                  # the player node
var interval := 2.2         # seconds between volleys (the game shortens it each round)
var active := true

var _cd := 1.2
var _orbit := 0.0
var _flash := 0.0


func reset(at: Vector2) -> void:
	position = at
	_cd = 1.2
	_orbit = 0.0
	_flash = 0.0
	active = true
	queue_redraw()


func _physics_process(delta: float) -> void:
	if not active or target == null:
		return
	_orbit += delta * 0.6
	var want: Vector2 = target.position + Vector2.RIGHT.rotated(_orbit) * 280.0
	want = Cfg.clamp_to_arena(want)
	position = position.lerp(want, 1.0 - exp(-2.5 * delta))

	_flash = maxf(0.0, _flash - delta)
	_cd -= delta
	if _cd <= 0.0:
		_cd = interval
		_flash = 0.3
		fire_requested.emit()
	queue_redraw()


func _draw() -> void:
	var glow := 0.25 + _flash * 2.0
	draw_circle(Vector2.ZERO, 20.0 + _flash * 18.0, Color(0.6, 0.15, 0.85, 0.18 * glow))
	draw_circle(Vector2.ZERO, 14.0, Color(0.16, 0.05, 0.28))
	draw_arc(Vector2.ZERO, 14.0, 0.0, TAU, 32, Color(0.7, 0.3, 1.0), 2.0)
	draw_circle(Vector2(-4.5, -2.0), 2.2, Color(1.0, 0.4, 0.9))
	draw_circle(Vector2(4.5, -2.0), 2.2, Color(1.0, 0.4, 0.9))

extends Node2D
## One telegraphed strike: a visible wind-up (the player's chance to react), then a brief
## damaging flash. Red = aimed by the model, blue = exploration shot.
##
## Fairness rule: the Shadow never hits instantly; the whole wind-up is visible.

const Cfg = preload("res://scripts/game_config.gd")

signal resolved(on_target: bool)   # emitted once, at the moment the strike lands
signal finished

var radius := Cfg.ATTACK_RADIUS
var windup := Cfg.WINDUP_START
var explored := false
var player                          # any node with `position`, `alive` and `take_hit()`

var _age := 0.0
var _striking := false


func is_telegraphing() -> bool:
	return not _striking


func _physics_process(delta: float) -> void:
	_age += delta
	if not _striking and _age >= windup:
		_striking = true
		resolved.emit(_inside())
	if _striking:
		if _inside() and player.alive:
			player.take_hit()
		if _age >= windup + Cfg.STRIKE_TIME:
			finished.emit()
			queue_free()
	queue_redraw()


func _inside() -> bool:
	return player.position.distance_to(position) <= radius + Cfg.PLAYER_RADIUS * 0.6


func _draw() -> void:
	var base := Color(0.35, 0.6, 1.0) if explored else Color(1.0, 0.25, 0.3)
	if not _striking:
		var p := clampf(_age / windup, 0.0, 1.0)
		draw_circle(Vector2.ZERO, radius, Color(base, 0.06 + 0.22 * p))
		draw_arc(Vector2.ZERO, radius, 0.0, TAU, 48, Color(base, 0.9), 2.0)
		draw_arc(Vector2.ZERO, radius * (1.0 - p), 0.0, TAU, 48, Color(base, 0.6), 1.5)
	else:
		draw_circle(Vector2.ZERO, radius, Color(1.0, 0.95, 0.9, 0.9))

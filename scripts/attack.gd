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
var arena = null                    # ArenaShaper; a charged blind spot shelters the player

var _age := 0.0
var _striking := false


func _ready() -> void:
	# Additive blending makes the halo below read as a glow on the dark arena.
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	material = mat


func is_telegraphing() -> bool:
	return not _striking


func is_striking() -> bool:
	return _striking


func covers_player() -> bool:
	return _inside()


func _physics_process(delta: float) -> void:
	_age += delta
	if not _striking and _age >= windup:
		_striking = true
		resolved.emit(_inside())
	if _striking:
		if _inside() and player.alive and not (arena != null and arena.shelters(player.position)):
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
		# Glow: soft rings outside the edge, brighter and faster-pulsing near the strike.
		var pulse := 0.5 + 0.5 * sin(_age * (8.0 + 30.0 * p))
		for i in 5:
			var g := float(i + 1)
			draw_arc(Vector2.ZERO, radius + g * 3.0, 0.0, TAU, 48,
					Color(base, (0.10 + 0.18 * p * pulse) / g), 3.0)
		draw_circle(Vector2.ZERO, radius, Color(base, 0.05 + 0.18 * p))
		draw_arc(Vector2.ZERO, radius, 0.0, TAU, 48, Color(base, 0.9), 2.0)
		draw_arc(Vector2.ZERO, radius * (1.0 - p), 0.0, TAU, 48, Color(base, 0.6), 1.5)
	else:
		var k := clampf((_age - windup) / Cfg.STRIKE_TIME, 0.0, 1.0)
		draw_circle(Vector2.ZERO, radius * (1.0 + 0.15 * k), Color(1.0, 0.95, 0.9, 0.9 * (1.0 - 0.6 * k)))
		for i in 4:
			draw_arc(Vector2.ZERO, radius + float(i + 1) * 5.0 * (1.0 + k), 0.0, TAU, 48,
					Color(base, 0.35 * (1.0 - k) / float(i + 1)), 4.0)

extends "res://scripts/player.gd"
## Ghost Shadow, the final boss: your best earlier run, replayed input by input.
##
## It is the player script with a different body. main.gd feeds it the recorded InputBits of
## the best run, so it walks, turns and dashes exactly as you did back then, starting from the
## same spawn point. Touching it costs a heart. It cannot be hit.

var harmless := 0.0                 # seconds left before it can hurt (spawn grace)

var _trail: Array = []              # recent world positions, newest last


func spawn(at: Vector2) -> void:
	reset(at)
	harmless = Cfg.GHOST_GRACE
	_trail.clear()
	visible = true


## Stop moving but stay visible (used when the run ends while the ghost is out).
func freeze() -> void:
	alive = false


func vanish() -> void:
	alive = false
	visible = false
	_trail.clear()


func take_hit() -> void:
	pass


func _physics_process(delta: float) -> void:
	if not alive:
		return
	harmless = maxf(0.0, harmless - delta)
	super(delta)
	_trail.append(position)
	if _trail.size() > 14:
		_trail.pop_front()


func _draw() -> void:
	var a := 0.35 if harmless > 0.0 and int(harmless * 10.0) % 2 == 0 else 0.85
	for i in _trail.size():
		var t := float(i + 1) / float(_trail.size() + 1)
		var p: Vector2 = _trail[i]
		draw_circle(p - position, Cfg.PLAYER_RADIUS * t, Color(0.75, 0.4, 1.0, 0.12 * t))
	draw_circle(Vector2.ZERO, Cfg.PLAYER_RADIUS + 6.0, Color(0.75, 0.4, 1.0, 0.15 * a))
	draw_circle(Vector2.ZERO, Cfg.PLAYER_RADIUS, Color(0.55, 0.25, 0.85, a))
	draw_arc(Vector2.ZERO, Cfg.PLAYER_RADIUS, 0.0, TAU, 24, Color(0.9, 0.7, 1.0, a), 1.5)
	draw_line(Vector2.ZERO, facing.normalized() * (Cfg.PLAYER_RADIUS + 6.0), Color(1, 1, 1, a), 2.0)

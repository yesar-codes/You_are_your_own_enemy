extends Node2D
## Draws the learning arena under the actors: the heat map (when model internals are shown),
## growing / grown thorns, and the blind spot. Read-only view over main.gd's ArenaShaper.

const Cfg = preload("res://scripts/game_config.gd")

const C_THORN := Color(0.85, 0.2, 0.25)
const C_POCKET := Color(0.35, 0.95, 0.75)

var game                                # main.gd instance, set by main
var _clock := 0.0


func _process(delta: float) -> void:
	_clock += delta
	queue_redraw()


func _draw() -> void:
	if game == null:
		return
	var shaper = game.arena
	if game.show_ml:
		_draw_heat(shaper)
	for c in shaper.withering:
		var a := clampf(float(shaper.withering[c]) / Cfg.ARENA_WITHER_TIME, 0.0, 1.0)
		_draw_thorn_cell(shaper.cell_rect(c), 0.6 * a)
	for c in shaper.thorns:
		var r: Rect2 = shaper.cell_rect(c)
		if shaper.is_growing(c):
			var p := clampf(float(shaper.thorns[c]) / Cfg.ARENA_GROW_TIME, 0.0, 1.0)
			var blink := 0.5 + 0.5 * sin(_clock * 18.0)
			draw_rect(r.grow(-3.0), Color(C_THORN, 0.08 + 0.2 * p), true)
			draw_rect(r.grow(-3.0), Color(C_THORN, 0.4 + 0.5 * blink), false, 2.0)
			_draw_spikes(r, p)
		else:
			_draw_thorn_cell(r, 1.0)
	if shaper.pocket >= 0:
		_draw_pocket(shaper)


func _draw_heat(shaper) -> void:
	var m: float = shaper.max_heat()
	if m <= 0.0:
		return
	for i in shaper.heat.size():
		var v: float = shaper.heat[i] / m
		if v > 0.05:
			draw_rect(shaper.cell_rect(i), Color(1.0, 0.55, 0.15, 0.16 * v), true)


func _draw_thorn_cell(r: Rect2, a: float) -> void:
	draw_rect(r.grow(-2.0), Color(0.25, 0.04, 0.07, 0.85 * a), true)
	draw_rect(r.grow(-2.0), Color(C_THORN, 0.9 * a), false, 1.5)
	_draw_spikes(r, a)


## A 3x3 field of little triangles; `p` scales them in while the thorns grow.
func _draw_spikes(r: Rect2, p: float) -> void:
	var s := minf(r.size.x, r.size.y) * 0.16 * p
	if s < 0.5:
		return
	for gx in 3:
		for gy in 3:
			var c := r.position + Vector2((gx + 0.5) * r.size.x / 3.0, (gy + 0.5) * r.size.y / 3.0)
			var tri := PackedVector2Array([c + Vector2(0, -s), c + Vector2(s * 0.8, s * 0.6), c + Vector2(-s * 0.8, s * 0.6)])
			draw_colored_polygon(tri, Color(1.0, 0.45, 0.45, 0.9 * p))


func _draw_pocket(shaper) -> void:
	var r: Rect2 = shaper.cell_rect(shaper.pocket)
	var c := r.get_center()
	var rad := minf(r.size.x, r.size.y) * 0.5
	var frac: float = shaper.pocket_charge / Cfg.POCKET_SHELTER
	if frac <= 0.0:
		draw_arc(c, rad - 4.0, 0.0, TAU, 32, Color(C_POCKET, 0.2), 1.0)
		return
	var pulse := 0.5 + 0.5 * sin(_clock * 3.0)
	draw_circle(c, rad - 4.0, Color(C_POCKET, 0.07 + 0.06 * pulse))
	draw_arc(c, rad - 4.0, -PI / 2.0, -PI / 2.0 + TAU * frac, 32, Color(C_POCKET, 0.85), 2.0)
	var font: Font = ThemeDB.fallback_font
	draw_string(font, Vector2(r.position.x, c.y + 4.0), "blind spot", HORIZONTAL_ALIGNMENT_CENTER,
			r.size.x, 11, Color(C_POCKET, 0.8))

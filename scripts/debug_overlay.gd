extends Node2D
## HUD + "model internals" panel. Read-only view over the game state (main.gd).
## F1 hides the ML section; Z cycles the context mode.

const Cfg = preload("res://scripts/game_config.gd")
const ActionSpace = preload("res://scripts/action_space.gd")

const PANEL := Rect2(880, 20, 380, 680)
const C_TEXT := Color(0.85, 0.88, 0.95)
const C_DIM := Color(0.55, 0.6, 0.72)
const C_ACCENT := Color(0.45, 0.85, 1.0)
const C_WARN := Color(1.0, 0.45, 0.5)

var game                                # main.gd instance, set by main
var _font: Font = ThemeDB.fallback_font


func _process(_delta: float) -> void:
	queue_redraw()


func _txt(s: String, pos: Vector2, size: int = 15, col: Color = C_TEXT) -> void:
	draw_string(_font, pos, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)


func _draw() -> void:
	if game == null:
		return
	if game.show_ml:
		_draw_zone_lines()
		_draw_plan()
	_draw_panel()
	if game.run_time < 4.0 and not game.is_over:
		_center("Survive.  The Shadow is studying how you move.", 60.0, 22, C_TEXT)
	if game.is_over:
		_draw_game_over()


# --- In-arena overlays ------------------------------------------------------------

func _draw_zone_lines() -> void:
	if game.model.context_mode != Cfg.MODE_ZONE:
		return
	var a := Cfg.ARENA
	for i in range(1, 3):
		var fx := a.position.x + a.size.x * float(i) / 3.0
		var fy := a.position.y + a.size.y * float(i) / 3.0
		draw_line(Vector2(fx, a.position.y), Vector2(fx, a.end.y), Color(0.45, 0.85, 1.0, 0.18), 1.0)
		draw_line(Vector2(a.position.x, fy), Vector2(a.end.x, fy), Color(0.45, 0.85, 1.0, 0.18), 1.0)


## The path the Shadow believed you would take for its most recent volley.
func _draw_plan() -> void:
	var age: float = game.last_plan_age
	if age > 1.6:
		return
	var fade := 1.0 - age / 1.6
	for item in game.last_plan:
		var col := Color(0.35, 0.6, 1.0, 0.8 * fade) if item["explored"] else Color(1.0, 0.85, 0.3, 0.8 * fade)
		var path: Array = item["path"]
		if path.size() >= 2:
			draw_polyline(PackedVector2Array(path), col, 2.0)
		draw_circle(item["target"], 5.0, col)


# --- Side panel -------------------------------------------------------------------

func _draw_panel() -> void:
	draw_rect(PANEL, Color(0.07, 0.08, 0.12))
	draw_rect(PANEL, Color(0.25, 0.3, 0.42), false, 1.5)
	var x := PANEL.position.x + 16.0
	var y := PANEL.position.y + 30.0

	_txt("SHADOW LEARNER", Vector2(x, y), 22, C_ACCENT)
	y += 30.0
	_txt("Time %5.1fs     Round %d" % [game.run_time, game.round_no], Vector2(x, y))
	y += 22.0
	_txt("Best %5.1fs     Runs %d" % [game.best_time, game.runs], Vector2(x, y), 15, C_DIM)
	y += 22.0
	var hearts := ""
	for i in Cfg.PLAYER_HP:
		hearts += "O " if i < game.player.hp else "x "
	_txt("HP  " + hearts, Vector2(x, y), 15, C_WARN)
	y += 22.0
	_txt("Strikes on target (last 20): %d%%" % roundi(game.atk_rate * 100.0), Vector2(x, y))
	y += 18.0
	_txt("red = aimed by model   blue = exploration", Vector2(x, y), 12, C_DIM)
	y += 26.0

	if not game.show_ml:
		_txt("[F1] show model internals", Vector2(x, y), 14, C_DIM)
		_draw_controls(x)
		return

	_txt("MODEL", Vector2(x, y), 16, C_ACCENT)
	y += 22.0
	var dist: PackedFloat64Array = game.last_pred
	var ent := ActionSpace.entropy_norm(dist) if not dist.is_empty() else 1.0
	_txt("context: %s   [Z]" % Cfg.MODE_NAMES[game.model.context_mode], Vector2(x, y), 13)
	y += 18.0
	_txt("trained on %d ticks, %d contexts" % [game.model.total_updates, game.model.context_count()], Vector2(x, y), 13)
	y += 18.0
	_txt("prediction used: %s" % game.pred_order, Vector2(x, y), 13)
	y += 18.0
	_txt("epsilon (explore) %.2f   unpredictability %d%%" % [game.planner.epsilon, roundi(ent * 100.0)], Vector2(x, y), 13)
	y += 26.0

	_txt("Predicted next action", Vector2(x, y), 14, C_ACCENT)
	y += 18.0
	var best := ActionSpace.argmax(dist) if not dist.is_empty() else -1
	for i in ActionSpace.N_ACTIONS:
		var p: float = dist[i] if not dist.is_empty() else 0.0
		var col := C_ACCENT if i == best else C_DIM
		_txt(ActionSpace.NAMES[i], Vector2(x, y), 12, col)
		draw_rect(Rect2(x + 44.0, y - 10.0, 250.0 * p, 11.0), Color(col, 0.85))
		_txt("%d%%" % roundi(p * 100.0), Vector2(x + 302.0, y), 12, col)
		y += 16.0
	y += 8.0

	var names: Array = []
	for a in game.history:
		names.append(ActionSpace.NAMES[int(a)])
	_txt("Recent: " + " > ".join(names), Vector2(x, y), 12, C_DIM)
	y += 24.0

	_txt("Prediction accuracy (rolling %d ticks)" % Cfg.ACC_WINDOW, Vector2(x, y), 14, C_ACCENT)
	y += 18.0
	_txt("top-1 %d%%    top-3 %d%%    (random: 10%% / 30%%)" % [roundi(game.acc_top1 * 100.0), roundi(game.acc_top3 * 100.0)], Vector2(x, y), 13)
	y += 8.0
	_draw_graph(Rect2(x, y, 348.0, 80.0))
	y += 92.0
	if game.last_run_acc >= 0.0:
		_txt("last run avg top-1: %d%%" % roundi(game.last_run_acc * 100.0), Vector2(x, y), 12, C_DIM)

	_draw_controls(x)


func _draw_graph(r: Rect2) -> void:
	draw_rect(r, Color(0.04, 0.05, 0.08))
	draw_rect(r, Color(0.25, 0.3, 0.42), false, 1.0)
	var chance_y := r.end.y - r.size.y * 0.1
	draw_line(Vector2(r.position.x, chance_y), Vector2(r.end.x, chance_y), Color(1, 1, 1, 0.15), 1.0)
	var series: Array = game.acc_series
	if series.size() < 2:
		return
	var pts := PackedVector2Array()
	for i in series.size():
		var px := r.position.x + r.size.x * float(i) / 180.0
		var py := r.end.y - r.size.y * clampf(float(series[i]), 0.0, 1.0)
		pts.append(Vector2(px, py))
	draw_polyline(pts, C_ACCENT, 2.0)


func _draw_controls(x: float) -> void:
	var y := PANEL.end.y - 84.0
	_txt("WASD / arrows  move      Space  dash", Vector2(x, y), 12, C_DIM)
	_txt("Z  cycle context mode    F1  hide/show internals", Vector2(x, y + 16.0), 12, C_DIM)
	_txt("R  restart run (model kept)", Vector2(x, y + 32.0), 12, C_DIM)
	_txt("N  new model (wipes learning)", Vector2(x, y + 48.0), 12, C_DIM)


func _center(s: String, y: float, size: int, col: Color) -> void:
	draw_string(_font, Vector2(Cfg.ARENA.position.x, y), s, HORIZONTAL_ALIGNMENT_CENTER,
			Cfg.ARENA.size.x, size, col)


func _draw_game_over() -> void:
	draw_rect(Cfg.ARENA, Color(0, 0, 0, 0.6))
	var cy := Cfg.ARENA.get_center().y
	_center("CAUGHT BY YOUR OWN HABITS", cy - 50.0, 34, C_WARN)
	_center("You survived %.1f seconds" % game.run_time, cy - 6.0, 20, C_TEXT)
	if game.last_run_acc >= 0.0:
		_center("The Shadow guessed your next move %d%% of the time (random = 10%%)" % roundi(game.last_run_acc * 100.0), cy + 24.0, 16, C_DIM)
	_center("R: play again (it remembers you)      N: wipe its memory", cy + 64.0, 16, C_ACCENT)

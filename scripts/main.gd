extends Node2D
## Game controller. Wires everything together and runs the learning loop:
##
##   every TICK (10 Hz):
##     1. read what the player actually did            -> `action`
##     2. score the previous prediction against it     -> rolling accuracy
##     3. model.update(history, situation, action)     -> learn
##     4. predict the next action                      -> shown in the debug panel
##   every time the Shadow fires:
##     planner.plan_volley(...)  -> roll the player forward, aim where they will be

const Cfg = preload("res://scripts/game_config.gd")
const ActionSpace = preload("res://scripts/action_space.gd")
const MarkovPredictor = preload("res://scripts/markov_predictor.gd")
const AttackPlanner = preload("res://scripts/attack_planner.gd")
const SaveManager = preload("res://scripts/save_manager.gd")
const PlayerScript = preload("res://scripts/player.gd")
const ShadowScript = preload("res://scripts/shadow.gd")
const AttackScript = preload("res://scripts/attack.gd")
const OverlayScript = preload("res://scripts/debug_overlay.gd")

# --- State read by the overlay ---------------------------------------------
var model: MarkovPredictor
var planner: AttackPlanner
var player: PlayerScript
var shadow: ShadowScript

var history: Array = []                 # last `max_order` actions
var last_pred := PackedFloat64Array()   # distribution over the player's NEXT action
var pred_order := "none"
var is_over := false
var run_time := 0.0
var round_no := 1
var best_time := 0.0
var runs := 0
var show_ml := true

var acc_top1 := 0.0                     # rolling accuracy of the model's guesses (0..1)
var acc_top3 := 0.0
var acc_series: Array = []              # top-1 accuracy sampled once per second
var last_run_acc := -1.0
var atk_rate := 0.0                     # fraction of recent strikes that landed on the player
var last_plan: Array = []
var last_plan_age := 99.0

# --- Internals ----------------------------------------------------------------
var _overlay: OverlayScript
var _attacks_root: Node2D
var _live_attacks: Array = []
var _threats: Array = []                # centres of attacks that are still telegraphing
var _situation := 0                     # situation id the current prediction was made in
var _tick_acc := 0.0
var _series_timer := 0.0
var _w1: Array = []
var _w3: Array = []
var _w_atk: Array = []
var _run_hits1 := 0
var _run_ticks := 0


func _ready() -> void:
	model = MarkovPredictor.new()
	model.context_mode = Cfg.MODE_THREAT
	planner = AttackPlanner.new()
	_load_state()

	_attacks_root = Node2D.new()
	add_child(_attacks_root)

	shadow = ShadowScript.new()
	add_child(shadow)

	player = PlayerScript.new()
	add_child(player)

	_overlay = OverlayScript.new()
	_overlay.game = self
	_overlay.z_index = 20
	add_child(_overlay)

	shadow.target = player
	shadow.fire_requested.connect(_on_fire)
	player.died.connect(_on_player_died)
	_start_run()


func _start_run() -> void:
	is_over = false
	run_time = 0.0
	round_no = 1
	_tick_acc = 0.0
	_series_timer = 0.0
	history.clear()
	last_pred = PackedFloat64Array()
	pred_order = "none"
	_situation = 0
	_w1.clear()
	_w3.clear()
	_w_atk.clear()
	_run_hits1 = 0
	_run_ticks = 0
	acc_top1 = 0.0
	acc_top3 = 0.0
	acc_series.clear()
	atk_rate = 0.0
	last_plan = []
	last_plan_age = 99.0
	_threats.clear()
	_live_attacks.clear()
	for c in _attacks_root.get_children():
		c.queue_free()
	var center := Cfg.ARENA.get_center()
	player.reset(center)
	shadow.reset(center + Vector2(280.0, 0.0))
	shadow.interval = _interval_for(round_no)


func _physics_process(delta: float) -> void:
	if is_over:
		return
	run_time += delta
	var new_round := 1 + int(run_time / Cfg.ROUND_SECONDS)
	if new_round != round_no:
		round_no = new_round
		shadow.interval = _interval_for(round_no)
		_save_state()

	_tick_acc += delta
	while _tick_acc >= Cfg.TICK:
		_tick_acc -= Cfg.TICK
		_on_tick()

	last_plan_age += delta
	_series_timer += delta
	if _series_timer >= 1.0:
		_series_timer = 0.0
		acc_series.append(acc_top1)
		if acc_series.size() > 180:
			acc_series.pop_front()


## The 10 Hz observe -> score -> learn -> predict step.
func _on_tick() -> void:
	var action := ActionSpace.IDLE
	if player.consume_dash():
		action = ActionSpace.DASH
	else:
		action = ActionSpace.from_vector(player.move_input)

	# 1) How good was the guess we made one tick ago?
	if not last_pred.is_empty():
		var order := ActionSpace.ranked(last_pred)
		var hit1: bool = int(order[0]) == action
		var hit3: bool = order.slice(0, 3).has(action)
		_push(_w1, 1 if hit1 else 0, Cfg.ACC_WINDOW)
		_push(_w3, 1 if hit3 else 0, Cfg.ACC_WINDOW)
		_run_ticks += 1
		if hit1:
			_run_hits1 += 1

	# 2) Learn: `action` followed `history` in `_situation`.
	model.update(history, _situation, action)
	history.append(action)
	if history.size() > model.max_order:
		history.pop_front()

	# 3) Predict the next action from the new context.
	_refresh_prediction()
	acc_top1 = _rate(_w1)
	acc_top3 = _rate(_w3)


func _refresh_prediction() -> void:
	_threats = _collect_threats()
	_situation = Cfg.situation_of(model.context_mode, player.position, _threats)
	last_pred = model.predict(history, _situation)
	pred_order = model.last_order_used


func _collect_threats() -> Array:
	var out: Array = []
	for a in _live_attacks:
		if is_instance_valid(a) and a.is_telegraphing():
			out.append(a.position)
	return out


func _on_fire() -> void:
	if is_over:
		return
	var count := mini(Cfg.MAX_VOLLEY, 1 + floori((round_no - 1) / 2.0))
	var windup := maxf(Cfg.WINDUP_MIN, Cfg.WINDUP_START - 0.05 * float(round_no - 1))
	var plans := planner.plan_volley(model, history, player.position, player.facing,
			count, windup, _threats)
	for p in plans:
		var a := AttackScript.new()
		a.position = p["target"]
		a.windup = windup
		a.explored = p["explored"]
		a.player = player
		a.resolved.connect(_on_attack_resolved)
		a.finished.connect(_on_attack_finished.bind(a))
		_attacks_root.add_child(a)
		_live_attacks.append(a)
	last_plan = plans
	last_plan_age = 0.0


func _on_attack_resolved(on_target: bool) -> void:
	if is_over:
		return
	_push(_w_atk, 1 if on_target else 0, 20)
	atk_rate = _rate(_w_atk)


func _on_attack_finished(a: Node) -> void:
	_live_attacks.erase(a)


func _on_player_died() -> void:
	is_over = true
	shadow.active = false
	runs += 1
	last_run_acc = float(_run_hits1) / float(maxi(1, _run_ticks))
	best_time = maxf(best_time, run_time)
	_save_state()


func _interval_for(r: int) -> float:
	return maxf(0.9, 2.2 - 0.15 * float(r - 1))


# --- Input --------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	match k.keycode:
		KEY_R:
			if not is_over:
				_save_state()
			_start_run()
		KEY_N:
			SaveManager.wipe()
			model.reset()
			planner.epsilon = Cfg.EPS_START
			best_time = 0.0
			runs = 0
			last_run_acc = -1.0
			_start_run()
		KEY_Z:
			model.context_mode = (model.context_mode + 1) % Cfg.MODE_NAMES.size()
			_refresh_prediction()
		KEY_F1:
			show_ml = not show_ml


# --- Persistence ----------------------------------------------------------------

func _load_state() -> void:
	var s := SaveManager.load_state()
	if s.is_empty():
		return
	if s.get("model") is Dictionary:
		model.from_dict(s["model"])
	best_time = float(s.get("best_time", 0.0))
	runs = int(s.get("runs", 0))
	planner.epsilon = clampf(float(s.get("epsilon", Cfg.EPS_START)), Cfg.EPS_MIN, 1.0)
	model.context_mode = clampi(int(s.get("context_mode", Cfg.MODE_THREAT)), 0, Cfg.MODE_NAMES.size() - 1)


func _save_state() -> void:
	SaveManager.save_state({
		"model": model.to_dict(),
		"best_time": best_time,
		"runs": runs,
		"epsilon": planner.epsilon,
		"context_mode": model.context_mode,
	})


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_save_state()


# --- Helpers ----------------------------------------------------------------------

func _push(window: Array, v: int, size: int) -> void:
	window.append(v)
	if window.size() > size:
		window.pop_front()


func _rate(window: Array) -> float:
	if window.is_empty():
		return 0.0
	var s := 0
	for v in window:
		s += int(v)
	return float(s) / float(window.size())


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, Vector2(1280.0, 720.0)), Color(0.04, 0.04, 0.07))
	draw_rect(Cfg.ARENA, Color(0.08, 0.09, 0.13))
	var x := Cfg.ARENA.position.x + 60.0
	while x < Cfg.ARENA.end.x:
		draw_line(Vector2(x, Cfg.ARENA.position.y), Vector2(x, Cfg.ARENA.end.y), Color(1, 1, 1, 0.03))
		x += 60.0
	var y := Cfg.ARENA.position.y + 60.0
	while y < Cfg.ARENA.end.y:
		draw_line(Vector2(Cfg.ARENA.position.x, y), Vector2(Cfg.ARENA.end.x, y), Color(1, 1, 1, 0.03))
		y += 60.0
	draw_rect(Cfg.ARENA, Color(0.3, 0.35, 0.5), false, 2.0)

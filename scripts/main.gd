extends Node2D
## Game controller. Wires everything together and runs the learning loop:
##
##   every physics frame (fixed 60 Hz):
##     read input bits (keyboard, or a recording when replaying) -> record them -> player
##   every TICK (10 Hz):
##     1. read what the player actually did            -> `action`
##     2. score the previous prediction against it     -> rolling accuracy
##     3. model.update(history, situation, action)     -> learn
##     4. predict the next action                      -> shown in the debug panel
##   every time the Shadow fires:
##     planner.plan_volley(...)  -> roll the player forward, aim where they will be
##
## Replays: a run is its starting state + one input value per frame (see run_recording.gd).
## A replay swaps in a fresh model/planner rebuilt from that state, so the live model is
## untouched. The Ghost Shadow boss is the input stream of your best run fed to a second body.

const Cfg = preload("res://scripts/game_config.gd")
const ActionSpace = preload("res://scripts/action_space.gd")
const InputBits = preload("res://scripts/input_bits.gd")
const MarkovPredictor = preload("res://scripts/markov_predictor.gd")
const AttackPlanner = preload("res://scripts/attack_planner.gd")
const RunRecording = preload("res://scripts/run_recording.gd")
const ProfileStats = preload("res://scripts/profile_stats.gd")
const SaveManager = preload("res://scripts/save_manager.gd")
const PlayerScript = preload("res://scripts/player.gd")
const GhostScript = preload("res://scripts/ghost.gd")
const ShadowScript = preload("res://scripts/shadow.gd")
const AttackScript = preload("res://scripts/attack.gd")
const OverlayScript = preload("res://scripts/debug_overlay.gd")

# --- State read by the overlay ---------------------------------------------
var model: MarkovPredictor
var planner: AttackPlanner
var player: PlayerScript
var ghost: GhostScript
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

var replaying := false
var replay_label := ""                  # "last run" / "best run"
var replay_status := ""                 # "" while playing, then "finished" or "diverged"
var frame := 0                          # physics frames since the run started
var replay_length := 0
var notice := ""                        # short message shown in the arena
var notice_age := 99.0

var ghost_state := Cfg.GHOST_UNAVAILABLE
var ghost_result := ""                  # how the ghost fight ended, for the game-over screen
var ghost_time := 0.0                   # seconds the ghost has been out
var best_ghost_time := 0.0              # length of the recorded best run

var profile: ProfileStats
var profile_lines: Array = []

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

var _live_model: MarkovPredictor
var _live_planner: AttackPlanner
var _rec: RunRecording                  # the live run being recorded
var _best_ghost := PackedByteArray()    # inputs of the best recorded run
var _ghost_frames := PackedByteArray()  # inputs the ghost uses this run
var _ghost_i := 0
var _replay: RunRecording
var _event_i := 0
var _pending_mode := -1                 # Z press waiting for the next physics frame

# Context the current prediction was made in, as plain features for the profile card.
var _prof_bearing := 8
var _prof_near := 0
var _prof_zone := 4


func _ready() -> void:
	_live_model = MarkovPredictor.new()
	_live_model.context_mode = Cfg.MODE_THREAT
	_live_planner = AttackPlanner.new()
	model = _live_model
	planner = _live_planner
	profile = ProfileStats.new()
	_load_state()

	_attacks_root = Node2D.new()
	add_child(_attacks_root)

	shadow = ShadowScript.new()
	add_child(shadow)

	player = PlayerScript.new()
	add_child(player)

	ghost = GhostScript.new()
	add_child(ghost)
	ghost.vanish()

	_overlay = OverlayScript.new()
	_overlay.game = self
	_overlay.z_index = 20
	add_child(_overlay)

	shadow.target = player
	shadow.fire_requested.connect(_on_fire)
	player.died.connect(_on_player_died)
	_start_run()


## Starts a live run, or a replay of `rec` when given.
func _start_run(rec: RunRecording = null) -> void:
	replaying = rec != null
	_replay = rec
	_event_i = 0
	_pending_mode = -1
	replay_status = ""
	if replaying:
		model = MarkovPredictor.new()
		model.from_dict(rec.model)
		model.context_mode = rec.context_mode
		planner = AttackPlanner.new()
		planner.epsilon = rec.epsilon
		planner.rng.seed = rec.rng_seed
		_ghost_frames = rec.ghost_frames
		replay_length = rec.frames.size()
		_rec = null
	else:
		model = _live_model
		planner = _live_planner
		_rec = RunRecording.new()
		_rec.rng_seed = randi()
		_rec.tick_rate = Engine.physics_ticks_per_second
		_rec.context_mode = model.context_mode
		_rec.epsilon = planner.epsilon
		# to_dict() also normalises the live model, so the snapshot equals its exact state.
		_rec.model = model.to_dict()
		planner.rng.seed = _rec.rng_seed
		_ghost_frames = _best_ghost
		_rec.ghost_frames = _ghost_frames

	is_over = false
	run_time = 0.0
	round_no = 1
	frame = 0
	_tick_acc = 0.0
	_series_timer = 0.0
	history.clear()
	last_pred = PackedFloat64Array()
	pred_order = "none"
	_situation = 0
	_prof_bearing = 8
	_prof_near = 0
	_prof_zone = Cfg.zone_of(Cfg.ARENA.get_center())
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
	notice = ""
	notice_age = 99.0
	profile.reset()
	profile_lines = []
	_threats.clear()
	_live_attacks.clear()
	# Detach right away: a queued-but-still-attached attack would get one more physics frame.
	for c in _attacks_root.get_children():
		_attacks_root.remove_child(c)
		c.queue_free()

	ghost.vanish()
	ghost_state = Cfg.GHOST_UNAVAILABLE if _ghost_frames.is_empty() else Cfg.GHOST_WAITING
	ghost_result = ""
	ghost_time = 0.0
	_ghost_i = 0

	var center := Cfg.ARENA.get_center()
	player.reset(center)
	shadow.reset(center + Vector2(280.0, 0.0))
	_refresh_interval()


func _physics_process(delta: float) -> void:
	notice_age += delta
	if is_over:
		return

	var bits := 0
	if replaying:
		_apply_replay_events()
		if frame >= _replay.frames.size():
			_end_replay("diverged")
			return
		bits = _replay.frames[frame]
	else:
		if _pending_mode >= 0:
			_set_mode(_pending_mode)
			_rec.add_mode_event(frame, _pending_mode)
			_pending_mode = -1
		bits = InputBits.read_keyboard()
		_rec.record(bits)
	player.frame_bits = bits
	frame += 1

	run_time += delta
	var new_round := 1 + int(run_time / Cfg.ROUND_SECONDS)
	if new_round != round_no:
		round_no = new_round
		_refresh_interval()
		model.normalize()     # same point in live runs and replays
		if not replaying:
			_save_state()

	_update_ghost(delta)
	if is_over:
		return

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
	var dash_dir := ActionSpace.from_vector(player.dash_dir) if action == ActionSpace.DASH else -1
	profile.record(action, _prof_bearing, _prof_near, _prof_zone, dash_dir)
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
	_prof_bearing = Cfg.threat_bearing(player.position, _threats)
	_prof_zone = Cfg.zone_of(player.position)
	_prof_near = 0
	for t in _threats:
		if player.position.distance_to(t) <= Cfg.THREAT_RANGE:
			_prof_near += 1


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
	if ghost_state == Cfg.GHOST_ACTIVE:
		ghost.freeze()
		ghost_result = "Your past self was still out there."
	last_run_acc = float(_run_hits1) / float(maxi(1, _run_ticks))
	profile_lines = profile.lines()
	if replaying:
		replay_status = "finished"
		return

	runs += 1
	_rec.duration = run_time
	var data := _rec.to_dict()
	SaveManager.save_replay("last", data)
	# Also take the first recorded run as "best" if an older save has a best time but no replay.
	if run_time > best_time or _best_ghost.is_empty():
		SaveManager.save_replay("best", data)
		_best_ghost = _rec.frames
		best_ghost_time = run_time
	best_time = maxf(best_time, run_time)
	_save_state()


func _interval_for(r: int) -> float:
	return maxf(0.9, 2.2 - 0.15 * float(r - 1))


func _refresh_interval() -> void:
	var slow := Cfg.GHOST_FIRE_SLOWDOWN if ghost_state == Cfg.GHOST_ACTIVE else 1.0
	shadow.interval = _interval_for(round_no) * slow


func _set_mode(m: int) -> void:
	model.context_mode = m
	_refresh_prediction()


func _say(text: String) -> void:
	notice = text
	notice_age = 0.0


# --- Ghost Shadow -------------------------------------------------------------

func _update_ghost(delta: float) -> void:
	if ghost_state == Cfg.GHOST_WAITING:
		if round_no >= Cfg.GHOST_ROUND:
			ghost_state = Cfg.GHOST_ACTIVE
			ghost.spawn(Cfg.ARENA.get_center())
			_refresh_interval()
			_say("YOUR BEST RUN HAS COME BACK FOR YOU")
	elif ghost_state == Cfg.GHOST_ACTIVE:
		if _ghost_i >= _ghost_frames.size():
			_finish_ghost("Your past self died here. You outlived it.")
		elif ghost_time >= Cfg.GHOST_MAX_SECONDS:
			_finish_ghost("You outlasted your past self.")
		else:
			ghost.frame_bits = _ghost_frames[_ghost_i]
			_ghost_i += 1
			ghost_time += delta
			if ghost.harmless <= 0.0 and player.alive \
					and player.position.distance_to(ghost.position) < Cfg.GHOST_HIT_DIST:
				player.take_hit()
				if not player.alive:
					ghost_result = "Your past self caught you."


func _finish_ghost(text: String) -> void:
	ghost_state = Cfg.GHOST_DONE
	ghost.vanish()
	ghost_result = text
	_refresh_interval()
	_say(text.to_upper())


# --- Replays --------------------------------------------------------------------

func _play_replay(slot: String) -> void:
	var rec := RunRecording.from_dict(SaveManager.load_replay(slot)) as RunRecording
	if rec == null or rec.frames.is_empty():
		_say("No %s run recorded yet" % slot)
		return
	if rec.tick_rate != Engine.physics_ticks_per_second:
		push_warning("Replay was recorded at %d Hz, running at %d Hz; it may diverge."
				% [rec.tick_rate, Engine.physics_ticks_per_second])
	replay_label = slot + " run"
	_start_run(rec)


func _apply_replay_events() -> void:
	while _event_i < _replay.events.size() and int(_replay.events[_event_i][0]) <= frame:
		_set_mode(int(_replay.events[_event_i][1]))
		_event_i += 1


## Recorded inputs ran out before the recorded death: the simulation is not deterministic.
func _end_replay(status: String) -> void:
	is_over = true
	shadow.active = false
	ghost.freeze()
	replay_status = status
	last_run_acc = float(_run_hits1) / float(maxi(1, _run_ticks))
	profile_lines = profile.lines()


func _back_to_live() -> void:
	replaying = false
	_start_run()


# --- Input --------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	if replaying:
		match k.keycode:
			KEY_P, KEY_R, KEY_ESCAPE:
				_back_to_live()
			KEY_F1:
				show_ml = not show_ml
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
			_best_ghost = PackedByteArray()
			best_ghost_time = 0.0
			_start_run()
		KEY_P:
			if is_over:
				_play_replay("last")
		KEY_B:
			if is_over:
				_play_replay("best")
		KEY_Z:
			var m := (model.context_mode + 1) % Cfg.MODE_NAMES.size()
			if is_over:
				_set_mode(m)
			else:
				_pending_mode = m       # applied (and recorded) on the next physics frame
		KEY_F1:
			show_ml = not show_ml


# --- Persistence ----------------------------------------------------------------

func _load_state() -> void:
	var s := SaveManager.load_state()
	if not s.is_empty():
		if s.get("model") is Dictionary:
			model.from_dict(s["model"])
		best_time = float(s.get("best_time", 0.0))
		runs = int(s.get("runs", 0))
		planner.epsilon = clampf(float(s.get("epsilon", Cfg.EPS_START)), Cfg.EPS_MIN, 1.0)
		model.context_mode = clampi(int(s.get("context_mode", Cfg.MODE_THREAT)), 0, Cfg.MODE_NAMES.size() - 1)
	var best := RunRecording.from_dict(SaveManager.load_replay("best")) as RunRecording
	if best != null:
		_best_ghost = best.frames
		best_ghost_time = best.duration


func _save_state() -> void:
	SaveManager.save_state({
		"model": _live_model.to_dict(),
		"best_time": best_time,
		"runs": runs,
		"epsilon": _live_planner.epsilon,
		"context_mode": _live_model.context_mode,
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

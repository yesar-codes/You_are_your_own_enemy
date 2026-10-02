extends SceneTree
## Headless tests for the learning code (no scenes needed). Run from the project folder:
##
##   godot --headless --path . --script res://tests/test_predictor.gd
##
## Exit code 0 = all passed.

const ActionSpace = preload("res://scripts/action_space.gd")
const MarkovPredictor = preload("res://scripts/markov_predictor.gd")
const AttackPlanner = preload("res://scripts/attack_planner.gd")
const Cfg = preload("res://scripts/game_config.gd")

var _failed := 0


func _check(cond: bool, label: String) -> void:
	if cond:
		print("  ok    ", label)
	else:
		print("  FAIL  ", label)
		_failed += 1


## Feed `pattern` repeated `reps` times through update(), keeping a rolling history.
func _train(m: MarkovPredictor, pattern: Array, reps: int, situation: int = 0) -> void:
	var hist: Array = []
	for r in reps:
		for a in pattern:
			m.update(hist, situation, int(a))
			hist.append(int(a))
			if hist.size() > m.max_order:
				hist.pop_front()


func _sum(d: PackedFloat64Array) -> float:
	var s := 0.0
	for v in d:
		s += v
	return s


func _init() -> void:
	print("cold start")
	var m := MarkovPredictor.new()
	var d := m.predict([], 0)
	_check(m.last_order_used == "none", "reports no evidence")
	_check(absf(d[0] - 0.1) < 1e-9 and absf(_sum(d) - 1.0) < 1e-9, "uniform distribution")

	print("learns a periodic pattern")
	m = MarkovPredictor.new()
	_train(m, [0, 2, 4, 2], 100)
	_check(ActionSpace.argmax(m.predict([0, 2, 4], 0)) == 2, "[N,E,S] -> E")
	_check(ActionSpace.argmax(m.predict([2, 4, 2], 0)) == 0, "[E,S,E] -> N")
	_check(ActionSpace.argmax(m.predict([4, 2, 0], 0)) == 2, "[S,E,N] -> E")
	_check(ActionSpace.argmax(m.predict([2, 0, 2], 0)) == 4, "[E,N,E] -> S")
	_check(m.last_order_used == "order 3", "used the order-3 context")
	_check(absf(_sum(m.predict([0, 2, 4], 0)) - 1.0) < 1e-9, "distribution sums to 1")

	print("backoff")
	d = m.predict([5, 5, 5, 5], 0)
	_check(m.last_order_used == "order 0", "unseen context falls back to the global prior")
	_check(absf(_sum(d) - 1.0) < 1e-9, "backoff distribution sums to 1")

	print("forgetting (concept drift)")
	m = MarkovPredictor.new()
	m.max_order = 1
	m.decay = 0.97
	_train(m, [0, 1], 200)
	_check(ActionSpace.argmax(m.predict([0], 0)) == 1, "learned 0 -> 1")
	_train(m, [0, 3], 200)
	_check(ActionSpace.argmax(m.predict([0], 0)) == 3, "adapted to 0 -> 3")

	print("weight renormalisation")
	m = MarkovPredictor.new()
	m.max_order = 1
	m.decay = 0.9
	_train(m, [6], 700)
	d = m.predict([6], 0)
	_check(ActionSpace.argmax(d) == 6 and absf(_sum(d) - 1.0) < 1e-9, "stays valid after many decays")

	print("situation conditioning")
	m = MarkovPredictor.new()
	m.context_mode = Cfg.MODE_THREAT
	var hist := [3]
	for i in 200:
		var sit := i % 2
		m.update(hist, sit, 1 if sit == 0 else 5)
	_check(ActionSpace.argmax(m.predict(hist, 0)) == 1, "situation 0 -> action 1")
	_check(ActionSpace.argmax(m.predict(hist, 1)) == 5, "situation 1 -> action 5")
	_check(m.last_order_used.ends_with("situation"), "reports situation-conditioned context")

	print("serialisation round trip")
	m = MarkovPredictor.new()
	_train(m, [0, 2, 4, 2, 7], 60)
	var parsed: Variant = JSON.parse_string(JSON.stringify(m.to_dict()))
	var m2 := MarkovPredictor.new()
	_check(parsed is Dictionary and m2.from_dict(parsed), "loads what it saved")
	var same := true
	for h in [[0, 2, 4], [2, 4, 2], [7], [4, 2, 7, 0]]:
		var a := m.predict(h, 0)
		var b := m2.predict(h, 0)
		for i in ActionSpace.N_ACTIONS:
			if absf(a[i] - b[i]) > 1e-6:
				same = false
	_check(same, "identical predictions after reload")

	print("action space")
	var ok := true
	for a in 8:
		if ActionSpace.from_vector(ActionSpace.to_vector(a)) != a:
			ok = false
	_check(ok, "vector <-> action round trip")
	_check(ActionSpace.from_vector(Vector2.ZERO) == ActionSpace.IDLE, "zero vector is IDLE")

	print("attack planner")
	m = MarkovPredictor.new()
	for i in 100:
		m.update([2, 2, 2, 2], 0, 2)    # the player always keeps going East
	var planner := AttackPlanner.new()
	planner.rng.seed = 1
	var start := Vector2(300, 300)
	var r := planner.rollout(m, [2, 2, 2, 2], start, Vector2.RIGHT, 6)
	var expect := start + Vector2(Cfg.PLAYER_SPEED * Cfg.TICK * 6.0, 0.0)
	_check((r["target"] as Vector2).distance_to(expect) < 0.01, "leads an east-moving player by 6 ticks")
	planner.epsilon = 0.0
	var plans := planner.plan_volley(m, [2, 2, 2, 2], start, Vector2.RIGHT, 3, 0.6)
	_check(plans.size() == 3, "volley has the requested number of shots")
	_check(not plans[0]["explored"], "epsilon 0 never explores")
	_check(planner.epsilon == Cfg.EPS_MIN, "epsilon decays toward its floor")
	planner.epsilon = 1.0
	plans = planner.plan_volley(m, [2, 2, 2, 2], start, Vector2.RIGHT, 2, 0.6)
	_check(plans[0]["explored"] and plans[1]["explored"], "epsilon 1 always explores")

	print("")
	if _failed == 0:
		print("ALL TESTS PASSED")
	else:
		print("%d TEST(S) FAILED" % _failed)
	quit(1 if _failed > 0 else 0)

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
const InputBits = preload("res://scripts/input_bits.gd")
const RunRecording = preload("res://scripts/run_recording.gd")
const ProfileStats = preload("res://scripts/profile_stats.gd")
const ArenaShaper = preload("res://scripts/arena_shaper.gd")
const ShadowVoice = preload("res://scripts/shadow_voice.gd")
const Ensemble = preload("res://scripts/ensemble_predictor.gd")

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

	print("input bits")
	_check(InputBits.to_vector(InputBits.UP | InputBits.RIGHT).is_equal_approx(Vector2(1, -1).normalized()), "up+right decodes diagonally")
	_check(InputBits.to_vector(InputBits.LEFT | InputBits.RIGHT) == Vector2.ZERO, "opposite keys cancel")
	_check(InputBits.dash_held(InputBits.DASH | InputBits.DOWN) and not InputBits.dash_held(InputBits.DOWN), "dash bit")

	print("run recording")
	var frames := PackedByteArray([0, 0, 0, 1, 1, 9, 16, 16, 16, 16, 0])
	var rle := RunRecording.encode_rle(frames)
	_check(rle.size() == 10, "run-length encodes repeated frames")
	_check(RunRecording.decode_rle(rle) == frames, "RLE round trip")
	m = MarkovPredictor.new()
	m.context_mode = Cfg.MODE_THREAT
	_train(m, [0, 2, 4, 2, 7, 9], 40, 3)
	var rec := RunRecording.new()
	rec.rng_seed = 12345
	rec.context_mode = m.context_mode
	rec.epsilon = 0.3
	rec.model = m.to_dict()
	rec.frames = frames
	rec.ghost_frames = PackedByteArray([4, 4, 8])
	rec.add_mode_event(3, 1)
	# Same path the game uses: full-precision JSON on disk.
	parsed = JSON.parse_string(JSON.stringify(rec.to_dict(), "", false, true))
	var rec2 := RunRecording.from_dict(parsed) as RunRecording
	_check(rec2 != null, "recording loads")
	_check(rec2.frames == frames and rec2.ghost_frames == rec.ghost_frames, "frames and ghost frames survive")
	_check(rec2.rng_seed == 12345 and rec2.events.size() == 1 and int(rec2.events[0][1]) == 1, "seed and events survive")
	_check(RunRecording.from_dict({"version": 99}) == null, "rejects unknown versions")

	print("replay determinism (model + seeded planner)")
	var live := MarkovPredictor.new()
	live.from_dict(rec.model)
	live.context_mode = rec.context_mode
	var replay := MarkovPredictor.new()
	replay.from_dict(rec2.model)
	replay.context_mode = rec2.context_mode
	var p1 := AttackPlanner.new()
	var p2 := AttackPlanner.new()
	p1.rng.seed = rec.rng_seed
	p2.rng.seed = rec2.rng_seed
	p1.epsilon = rec.epsilon
	p2.epsilon = rec2.epsilon
	var identical := true
	var ctx: Array = [0, 2, 4]
	for i in 30:
		var a1 := p1.plan_volley(live, ctx, start, Vector2.RIGHT, 3, 0.7, [start + Vector2(40, 0)])
		var a2 := p2.plan_volley(replay, ctx, start, Vector2.RIGHT, 3, 0.7, [start + Vector2(40, 0)])
		for j in a1.size():
			if a1[j]["target"] != a2[j]["target"] or a1[j]["explored"] != a2[j]["explored"]:
				identical = false
		live.update(ctx, 3, i % 10)
		replay.update(ctx, 3, i % 10)
	_check(identical, "rebuilt model + same seed plan identical volleys")

	print("profile card")
	var prof := ProfileStats.new()
	_check(prof.lines().is_empty(), "no habits without data")
	for i in 20:
		prof.record(6, 2, 1, 4)                    # threat to the right (E) -> move W
	for i in 5:
		prof.record(ActionSpace.DASH, 8, 0, 4, 0)  # dash North
		prof.record(ActionSpace.IDLE, 8, 0, 4)
	var lines := prof.lines()
	var found_flee := false
	var found_dash := false
	for l in lines:
		if str(l).contains("to your right, you move left 100%"):
			found_flee = true
		if str(l).contains("100% of your dashes go up"):
			found_dash = true
	_check(found_flee, "finds: flees left from a threat on the right")
	_check(found_dash, "finds: favourite dash direction")
	_check(lines.size() <= 4, "card is capped")
	_check(absf(prof.zone_share(4) - 1.0) < 1e-9, "zone share")

	print("expert ensemble (Hedge)")
	var ens := Ensemble.new()
	ens.context_mode = Cfg.MODE_NONE
	var eh: Array = []
	for i in 300:                      # zig-zag every tick: "repeat last" is always wrong
		var act := 0 if i % 2 == 0 else 4
		ens.update(eh, 0, act, 8)
		eh.append(act)
		if eh.size() > ens.max_order:
			eh.pop_front()
	_check(ens.trusted() == 0, "zig-zag: trusts the n-gram expert")
	_check(ens.weights[1] < 0.1, "zig-zag: 'repeat last' loses its vote")
	var wsum := 0.0
	var wmin := 1.0
	for w in ens.weights:
		wsum += w
		wmin = minf(wmin, w)
	_check(absf(wsum - 1.0) < 1e-9, "weights sum to 1")
	_check(wmin >= Ensemble.SHARE / Ensemble.K * 0.99, "fixed share keeps every expert alive")
	_check(ActionSpace.argmax(ens.predict(eh, 0, 8)) == (0 if int(eh.back()) == 4 else 4), "blend predicts the zig-zag")

	ens = Ensemble.new()
	ens.context_mode = Cfg.MODE_NONE   # the n-gram can't see threats in this mode
	var trng := RandomNumberGenerator.new()
	trng.seed = 3
	eh = []
	for i in 400:                      # flee directly away from a random threat direction
		var b := trng.randi_range(0, 7)
		var act := (b + 4) % 8
		ens.update(eh, 0, act, b)
		eh.append(act)
		if eh.size() > ens.max_order:
			eh.pop_front()
	_check(ens.trusted() == 2, "random threats + fleeing: trusts the threat reflex")
	_check(ActionSpace.argmax(ens.predict(eh, 0, 2)) == 6, "threat to the east -> predicts west")

	var ens2 := Ensemble.new()
	ens2.context_mode = Cfg.MODE_NONE
	_check(ens2.from_dict(JSON.parse_string(JSON.stringify(ens.to_dict(), "", false, true))), "ensemble loads what it saved")
	var same_e := true
	for b in 8:
		var pa := ens.predict(eh, 0, b)
		var pb := ens2.predict(eh, 0, b)
		for a in ActionSpace.N_ACTIONS:
			if absf(pa[a] - pb[a]) > 1e-12:
				same_e = false
	_check(same_e, "identical blended predictions after reload")
	var legacy := MarkovPredictor.new()
	_train(legacy, [0, 2, 4, 2], 50)
	var ens3 := Ensemble.new()
	_check(ens3.from_dict(legacy.to_dict()) and ens3.total_updates == legacy.total_updates, "loads an old n-gram-only save")
	_check(ActionSpace.argmax(ens3.ngram.predict([0, 2, 4], 0)) == 2, "old n-gram knowledge survives")

	print("shadow voice")
	var hb := prof.habits()
	_check(not hb.is_empty() and hb[0].has("kind") and hb[0].has("score"), "profile exposes structured habits")
	var voice := ShadowVoice.new()
	voice.reset(0)
	_check(voice.is_talking() and voice.line != "", "greets at run start")
	var taunt := voice.habit_taunt(hb)
	_check(taunt.contains("left") or taunt.contains("up"), "habit taunt is about the player's habit: " + taunt)
	var taunt2 := voice.habit_taunt(hb)
	_check(taunt2 != "" and taunt2 != taunt, "next taunt picks a different habit")
	voice.reset(0)
	voice.age = 1.5
	_check(voice.say("hit_aimed"), "a high-priority event interrupts the greeting")
	_check(not voice.say("seen_this", ShadowVoice.LOW), "a low-priority line doesn't interrupt")
	voice.reset(0)
	voice.age = 99.0
	voice.update(0.1, prof, 0.0, false, false)
	voice.on_dash(6)
	voice.on_dash(6)
	_check(not voice.line.to_lower().contains("left"), "two same dashes: no comment yet")
	voice.on_dash(6)
	_check(voice.line.to_lower().contains("left"), "three dashes left: 'Left again?'")
	_check(ShadowVoice._cap("standing still") == "Standing still", "capitalises only the first letter")

	print("learning arena")
	var ar := ArenaShaper.new()
	ar.reset(PackedFloat64Array(), 7)
	var corner := Cfg.ARENA.position + Vector2(30, 30)
	for i in 120:
		ar.observe(corner)
	ar.reshape(corner)
	var hot := ar.cell_of(corner)
	_check(ar.thorns.has(hot) and ar.is_growing(hot), "thorns start growing on the hottest cell")
	_check(not ar.is_thorn_at(corner), "growing thorns don't hurt yet")
	ar.step(Cfg.ARENA_GROW_TIME + 0.01, corner)
	_check(ar.is_thorn_at(ar.cell_rect(hot).get_center()), "grown thorns hurt")
	_check(ar.first_target == hot, "remembers the first target for the profile card")
	_check(ar.pocket >= 0 and not ar.thorns.has(ar.pocket), "a blind spot opens on a free cell")
	var spot := ar.cell_rect(ar.pocket).get_center()
	_check(spot.distance_to(corner) >= Cfg.POCKET_MIN_DIST, "blind spot is far from the player")
	_check(ar.shelters(spot), "blind spot shelters while charged")
	ar.step(Cfg.POCKET_SHELTER + 0.1, spot)
	_check(not ar.shelters(spot), "blind spot runs out")
	var mid := Cfg.ARENA.get_center()
	for i in 400:
		ar.observe(mid)
	ar.reshape(mid)
	_check(ar.thorns.has(ar.cell_of(mid)), "thorns follow the player's new habit")
	var sh := ar.shares()
	var total := 0.0
	for v in sh:
		total += float(v)
	_check(sh.size() == ArenaShaper.CELLS and absf(total - 1.0) < 1e-9, "memory shares sum to 1")
	var ar2 := ArenaShaper.new()
	ar2.reset(PackedFloat64Array(), 7)
	for i in 120:
		ar2.observe(corner)
	ar2.reshape(corner)
	var ar3 := ArenaShaper.new()
	ar3.reset(PackedFloat64Array(), 7)
	for i in 120:
		ar3.observe(corner)
	ar3.reshape(corner)
	_check(ar2.pocket == ar3.pocket and ar2.thorns.keys() == ar3.thorns.keys(), "same seed and inputs, same arena")

	print("")
	if _failed == 0:
		print("ALL TESTS PASSED")
	else:
		print("%d TEST(S) FAILED" % _failed)
	quit(1 if _failed > 0 else 0)

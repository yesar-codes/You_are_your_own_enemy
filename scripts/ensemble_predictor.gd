extends RefCounted
## Several predictors that vote, weighted by how well each has predicted you lately.
##
## Experts:
##   0  n-gram patterns   the variable-order Markov model (markov_predictor.gd)
##   1  repeat last move  "you'll keep doing what you're doing"
##   2  threat reflex     P(action | direction of the nearest telegraph), ignores history
##
## Weighting is the Hedge algorithm (multiplicative weights): after every tick each expert
## pays a loss for the probability it gave to what you actually did, and its weight is
## multiplied by exp(-ETA * loss). A small "fixed share" mixes a bit of uniform weight back in
## every step, so an expert that was bad an hour ago can regain trust within seconds when it
## becomes right (tracking the best *recent* expert, not the best overall).
##
## The blended prediction is sum_i weight_i * p_i. Same interface as MarkovPredictor, plus an
## optional `bearing` argument (Cfg.threat_bearing) used by the threat expert.

const ActionSpace = preload("res://scripts/action_space.gd")
const MarkovPredictor = preload("res://scripts/markov_predictor.gd")

const N := ActionSpace.N_ACTIONS
const K := 3
const NAMES := ["n-gram patterns", "repeat last move", "threat reflex"]
const KEYS := ["ngram", "repeat", "threat"]

const ETA := 0.6                    # learning rate of the weights
const SHARE := 0.01                 # fixed-share mixing per update
const REPEAT_EPS := 0.15            # probability mass "repeat" spreads over other actions
const THREAT_DECAY := 0.995
const THREAT_ALPHA := 0.5           # additive smoothing of the threat table
const BEARINGS := 10                # Cfg.threat_bearing: 0..7 dirs, 8 none, 9 on top
const ACC_WINDOW := 100
const LOG_FLOOR := 0.001            # loss = -ln(max(p, floor)) / -ln(floor), so 0..1

var ngram := MarkovPredictor.new()
var weights := PackedFloat64Array()
var expert_acc := PackedFloat64Array()      # rolling top-1 accuracy per expert (display)
var last_expert_preds: Array = []           # each expert's distribution from the last predict()
var last_order_used: String = "none"

var context_mode: int:
	get:
		return ngram.context_mode
	set(v):
		ngram.context_mode = v
var max_order: int:
	get:
		return ngram.max_order
	set(v):
		ngram.max_order = v
var total_updates: int:
	get:
		return ngram.total_updates

var _threat: Array = []             # [bearing][action] decayed counts
var _hits: Array = []               # per expert, last ACC_WINDOW hits (0/1)


func _init() -> void:
	reset()


func reset() -> void:
	ngram.reset()
	_reset_others()


## Everything except the n-gram expert.
func _reset_others() -> void:
	weights = PackedFloat64Array([1.0 / K, 1.0 / K, 1.0 / K])
	expert_acc = PackedFloat64Array([0.0, 0.0, 0.0])
	last_expert_preds = []
	last_order_used = "none"
	_reset_threat()
	_hits = [[], [], []]


func context_count() -> int:
	return ngram.context_count()


func normalize() -> void:
	ngram.normalize()


## Index of the expert with the highest weight.
func trusted() -> int:
	var best := 0
	for i in range(1, K):
		if weights[i] > weights[best]:
			best = i
	return best


func predict(history: Array, situation: int, bearing: int = 8) -> PackedFloat64Array:
	var ps := _expert_preds(history, situation, bearing)
	last_order_used = ngram.last_order_used
	last_expert_preds = ps
	var dist := PackedFloat64Array()
	dist.resize(N)
	for i in K:
		var p: PackedFloat64Array = ps[i]
		for a in N:
			dist[a] += weights[i] * p[a]
	return dist


## Score every expert on `action` (taken after `history` in this situation), reweight, learn.
func update(history: Array, situation: int, action: int, bearing: int = 8) -> void:
	var ps := _expert_preds(history, situation, bearing)
	var total := 0.0
	for i in K:
		var p: PackedFloat64Array = ps[i]
		var loss := -log(maxf(p[action], LOG_FLOOR)) / -log(LOG_FLOOR)
		weights[i] *= exp(-ETA * loss)
		total += weights[i]
		var w: Array = _hits[i]
		w.append(1 if ActionSpace.argmax(p) == action else 0)
		if w.size() > ACC_WINDOW:
			w.pop_front()
		var s := 0
		for v in w:
			s += int(v)
		expert_acc[i] = float(s) / float(w.size())
	for i in K:
		weights[i] = (1.0 - SHARE) * weights[i] / total + SHARE / K

	ngram.update(history, situation, action)
	var b := clampi(bearing, 0, BEARINGS - 1)
	for bb in BEARINGS:
		var row: Array = _threat[bb]
		for a in N:
			row[a] = float(row[a]) * THREAT_DECAY
	_threat[b][action] = float(_threat[b][action]) + 1.0


# --- Persistence ------------------------------------------------------------

func to_dict() -> Dictionary:
	return {"version": 2, "kind": "ensemble", "ngram": ngram.to_dict(),
			"weights": Array(weights), "threat": _threat.duplicate(true)}


## Also accepts a plain MarkovPredictor dict (older saves): the n-gram expert gets it,
## the others start fresh.
func from_dict(d: Dictionary) -> bool:
	if not d.has("ngram"):
		_reset_others()
		return ngram.from_dict(d)
	if not (d["ngram"] is Dictionary) or not ngram.from_dict(d["ngram"]):
		return false
	var w: Variant = d.get("weights")
	if w is Array and w.size() == K:
		var total := 0.0
		for i in K:
			weights[i] = maxf(0.0, float(w[i]))
			total += weights[i]
		for i in K:
			weights[i] = weights[i] / total if total > 0.0 else 1.0 / K
	var t: Variant = d.get("threat")
	if t is Array and t.size() == BEARINGS:
		_reset_threat()
		for bb in BEARINGS:
			var row: Variant = t[bb]
			if row is Array and row.size() == N:
				for a in N:
					_threat[bb][a] = float(row[a])
	return true


# --- Experts ------------------------------------------------------------------

func _expert_preds(history: Array, situation: int, bearing: int) -> Array:
	return [ngram.predict(history, situation), _repeat_pred(history), _threat_pred(bearing)]


func _repeat_pred(history: Array) -> PackedFloat64Array:
	var dist := PackedFloat64Array()
	dist.resize(N)
	if history.is_empty():
		dist.fill(1.0 / N)
		return dist
	var last := int(history.back())
	# A dash lasts one tick; "repeat" means going back to what you did before it.
	if last == ActionSpace.DASH and history.size() >= 2:
		last = int(history[history.size() - 2])
	dist.fill(REPEAT_EPS / (N - 1))
	dist[last] = 1.0 - REPEAT_EPS
	return dist


func _threat_pred(bearing: int) -> PackedFloat64Array:
	var row: Array = _threat[clampi(bearing, 0, BEARINGS - 1)]
	var dist := PackedFloat64Array()
	dist.resize(N)
	var total := 0.0
	for a in N:
		total += float(row[a]) + THREAT_ALPHA
	for a in N:
		dist[a] = (float(row[a]) + THREAT_ALPHA) / total
	return dist


func _reset_threat() -> void:
	_threat = []
	for bb in BEARINGS:
		var row: Array = []
		row.resize(N)
		row.fill(0.0)
		_threat.append(row)

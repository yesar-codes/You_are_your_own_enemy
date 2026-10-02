extends RefCounted
## Variable-order Markov (n-gram) model of the player's behaviour.
##
## It learns  P(next action | last k actions [, situation])  for k = 0..max_order and
## answers predictions by *backoff*: use the most specific context that has been seen
## often enough, otherwise fall back to a shorter one, finally to the global prior.
##
## Pure data + math. No Node dependencies, so it is unit-testable and serialisable.
##
## Forgetting: instead of multiplying every count by `decay` on each update (O(#contexts)),
## we make every *new* observation worth more than the last (weight *= 1/decay). Ratios are
## identical, the cost is O(1), and we renormalise once the weight gets huge.

const ActionSpace = preload("res://scripts/action_space.gd")

const N := ActionSpace.N_ACTIONS

var max_order: int = 4
var min_evidence: float = 3.0     # effective observations needed before a context is trusted
var alpha: float = 0.3            # Laplace/additive smoothing (in effective observations)
var decay: float = 0.997          # per-update memory; 1.0 = never forget
var context_mode: int = 0         # 0 = history only, otherwise also condition on a "situation"

var total_updates: int = 0
var last_order_used: String = "none"   # which context the latest predict() relied on

var _counts: Dictionary = {}      # String key -> PackedFloat64Array(N)
var _weight: float = 1.0          # weight of the newest observation


func reset() -> void:
	_counts.clear()
	_weight = 1.0
	total_updates = 0
	last_order_used = "none"


func context_count() -> int:
	return _counts.size()


## Record that `action` was taken after `history` (the actions *before* it)
## in `situation` (ignored unless context_mode != 0).
func update(history: Array, situation: int, action: int) -> void:
	_weight /= decay
	if _weight > 1.0e9:
		_rescale()
	for key in _chain(history, situation, context_mode != 0):
		var arr: PackedFloat64Array = _counts.get(key, PackedFloat64Array())
		if arr.is_empty():
			arr.resize(N)
		arr[action] += _weight
		_counts[key] = arr
	total_updates += 1


## Probability distribution over the next action. Sets `last_order_used`.
func predict(history: Array, situation: int) -> PackedFloat64Array:
	var dist := PackedFloat64Array()
	dist.resize(N)
	var chosen := PackedFloat64Array()
	last_order_used = "none"
	for key in _chain(history, situation, context_mode != 0):
		if not _counts.has(key):
			continue
		var arr: PackedFloat64Array = _counts[key]
		if key == "" or _sum(arr) / _weight >= min_evidence:
			chosen = arr
			last_order_used = _describe(key)
			break
	if chosen.is_empty():
		dist.fill(1.0 / N)   # cold start: no data at all
		return dist
	var a := alpha * _weight
	var norm := _sum(chosen) + a * N
	for i in N:
		dist[i] = (chosen[i] + a) / norm
	return dist


# --- Persistence ------------------------------------------------------------

func to_dict() -> Dictionary:
	_rescale()
	var counts := {}
	for key in _counts:
		var arr: PackedFloat64Array = _counts[key]
		counts[key] = Array(arr)
	return {"version": 1, "max_order": max_order, "updates": total_updates, "counts": counts}


func from_dict(d: Dictionary) -> bool:
	if int(d.get("version", 0)) != 1 or not (d.get("counts") is Dictionary):
		return false
	reset()
	max_order = int(d.get("max_order", max_order))
	total_updates = int(d.get("updates", 0))
	var counts: Dictionary = d["counts"]
	for key in counts:
		var src: Array = counts[key]
		if src.size() != N:
			continue
		var arr := PackedFloat64Array()
		arr.resize(N)
		for i in N:
			arr[i] = float(src[i])
		_counts[key] = arr
	return true


# --- Internals --------------------------------------------------------------

## Context keys from most to least specific:
##   [situation + last k actions] (k = top..1), [last k actions] (k = top..1),
##   [situation only], [] (global prior)
func _chain(history: Array, situation: int, use_situation: bool) -> Array[String]:
	var chain: Array[String] = []
	var top := mini(max_order, history.size())
	var sp := "s%d:%d|" % [context_mode, situation]
	if use_situation:
		for k in range(top, 0, -1):
			chain.append(sp + _ctx(history, k))
	for k in range(top, 0, -1):
		chain.append(_ctx(history, k))
	if use_situation:
		chain.append(sp)
	chain.append("")
	return chain


func _ctx(history: Array, k: int) -> String:
	var s := ""
	for i in range(history.size() - k, history.size()):
		s += char(65 + int(history[i]))
	return s


func _describe(key: String) -> String:
	var bar := key.find("|")
	var order := key.length() if bar < 0 else key.length() - bar - 1
	return "order %d%s" % [order, " + situation" if bar >= 0 else ""]


func _rescale() -> void:
	if _weight == 1.0:
		return
	for key in _counts:
		var arr: PackedFloat64Array = _counts[key]
		for i in N:
			arr[i] /= _weight
		_counts[key] = arr
	_weight = 1.0


func _sum(arr: PackedFloat64Array) -> float:
	var s := 0.0
	for v in arr:
		s += v
	return s

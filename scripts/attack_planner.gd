extends RefCounted
## Turns the model's predictions into attack targets.
##
## Key idea: an attack takes `windup` seconds to land, so the Shadow must aim where the
## player WILL be. We roll the player forward tick by tick, each time asking the model for
## the most likely next action ("autoregressive rollout"), and aim at the end point.
##
## Exploration (epsilon-greedy): with probability epsilon a shot starts from a random action
## instead of the predicted one. This stops the Shadow from becoming exploitable itself and
## lets it keep sampling behaviour it currently believes is unlikely.

const Cfg = preload("res://scripts/game_config.gd")
const ActionSpace = preload("res://scripts/action_space.gd")

var epsilon: float = Cfg.EPS_START
var rng := RandomNumberGenerator.new()


func _init() -> void:
	rng.randomize()


## Returns an Array of {target: Vector2, path: Array[Vector2], explored: bool, rank: int}.
## Shot #j starts from the j-th most likely next action, so volleys "hedge" across the
## model's top guesses instead of stacking on one spot.
## `model` is a MarkovPredictor or an EnsemblePredictor (same interface).
func plan_volley(model, history: Array, pos: Vector2, facing: Vector2,
		count: int, windup: float, threats: Array = []) -> Array:
	var steps := maxi(1, roundi(windup / Cfg.TICK))
	var sit: int = Cfg.situation_of(model.context_mode, pos, threats)
	var dist: PackedFloat64Array = model.predict(history, sit, Cfg.threat_bearing(pos, threats))
	var cold: bool = model.last_order_used == "none"
	var order := ActionSpace.ranked(dist)
	var plans: Array = []
	for j in count:
		var first := int(order[j % order.size()])
		if cold:
			# No data yet: fall back to "keeps doing what it just did" (constant velocity).
			first = int(history.back()) if not history.is_empty() else ActionSpace.IDLE
		var explored := rng.randf() < epsilon
		if explored:
			first = rng.randi_range(0, ActionSpace.N_ACTIONS - 1)
		var r := rollout(model, history, pos, facing, steps, first, threats)
		plans.append({"target": r["target"], "path": r["path"], "explored": explored, "rank": j})
	epsilon = maxf(Cfg.EPS_MIN, epsilon * Cfg.EPS_DECAY)
	return plans


## Simulate the player for `steps` ticks. If `first_action` >= 0 it is forced as the first
## simulated action; every later action is the model's argmax given the simulated history.
func rollout(model, history: Array, pos: Vector2, facing: Vector2,
		steps: int, first_action: int = -1, threats: Array = []) -> Dictionary:
	var h: Array = history.duplicate()
	var p := pos
	var f := facing
	var path: Array = [p]
	for i in steps:
		var a: int
		if i == 0 and first_action >= 0:
			a = first_action
		else:
			var sit: int = Cfg.situation_of(model.context_mode, p, threats)
			var dist: PackedFloat64Array = model.predict(h, sit, Cfg.threat_bearing(p, threats))
			if model.last_order_used == "none":
				a = int(h.back()) if not h.is_empty() else ActionSpace.IDLE
			else:
				a = ActionSpace.argmax(dist)
		h.append(a)
		if h.size() > model.max_order:
			h.pop_front()
		if a == ActionSpace.DASH:
			p += f * Cfg.DASH_DISTANCE
		elif a != ActionSpace.IDLE:
			f = ActionSpace.to_vector(a)
			p += f * Cfg.PLAYER_SPEED * Cfg.TICK
		p = Cfg.clamp_to_arena(p)
		path.append(p)
	return {"target": p, "path": path}

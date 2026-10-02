extends RefCounted
## The discrete "alphabet" the Shadow uses to describe what the player does.
##
## 0..7 = the eight compass directions (clockwise from North), 8 = IDLE, 9 = DASH.
## Continuous input is quantised into this alphabet once per game tick (10 Hz),
## which is what turns "player behaviour" into a sequence a Markov model can learn.

const N_ACTIONS := 10
const IDLE := 8
const DASH := 9

const NAMES := ["N", "NE", "E", "SE", "S", "SW", "W", "NW", "IDLE", "DASH"]

const DIRS := [
	Vector2(0.0, -1.0),
	Vector2(0.7071068, -0.7071068),
	Vector2(1.0, 0.0),
	Vector2(0.7071068, 0.7071068),
	Vector2(0.0, 1.0),
	Vector2(-0.7071068, 0.7071068),
	Vector2(-1.0, 0.0),
	Vector2(-0.7071068, -0.7071068),
]


## Quantise a movement vector into one of the 9 movement actions (8 dirs + IDLE).
static func from_vector(v: Vector2) -> int:
	if v.length_squared() < 0.01:
		return IDLE
	var angle := atan2(v.x, -v.y)  # 0 = North, clockwise positive
	return posmod(roundi(angle / (TAU / 8.0)), 8)


static func to_vector(action: int) -> Vector2:
	if action < 0 or action > 7:
		return Vector2.ZERO
	return DIRS[action]


static func argmax(dist: PackedFloat64Array) -> int:
	var best := 0
	for i in range(1, dist.size()):
		if dist[i] > dist[best]:
			best = i
	return best


## Action indices sorted by probability, most likely first (ties -> lower index).
static func ranked(dist: PackedFloat64Array) -> Array:
	var idx: Array = range(dist.size())
	idx.sort_custom(func(a: int, b: int) -> bool:
		if dist[a] == dist[b]:
			return a < b
		return dist[a] > dist[b])
	return idx


## Shannon entropy of a distribution, normalised to 0..1 (1 = totally unpredictable).
static func entropy_norm(dist: PackedFloat64Array) -> float:
	if dist.size() < 2:
		return 0.0
	var h := 0.0
	for p: float in dist:
		if p > 1.0e-12:
			h -= p * log(p)
	return h / log(float(dist.size()))

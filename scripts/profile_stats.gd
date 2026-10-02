extends RefCounted
## Per-run behaviour statistics, turned into plain-language "habits" for the game-over
## profile card ("you move left 71% of the time when a circle appears to your right").
##
## It counts the same 10 Hz actions the model learns from, but grouped by situations a human
## understands. Each candidate habit is scored by how far it beats a uniform guess, so the card
## shows what is most *predictable* about you, not just what happened most often.
## Pure data, no Node dependencies.

const ActionSpace = preload("res://scripts/action_space.gd")

const N := ActionSpace.N_ACTIONS
const MIN_SAMPLES := 6
const MIN_SCORE := 0.15

const BEARING_TEXT := ["above you", "to your upper right", "to your right", "to your lower right",
		"below you", "to your lower left", "to your left", "to your upper left"]
const ACTION_TEXT := ["move up", "move up-right", "move right", "move down-right", "move down",
		"move down-left", "move left", "move up-left", "freeze", "dash"]
const DIR_TEXT := ["up", "up-right", "right", "down-right", "down", "down-left", "left", "up-left"]
const ZONE_TEXT := ["top-left corner", "top edge", "top-right corner", "left edge", "centre",
		"right edge", "bottom-left corner", "bottom edge", "bottom-right corner"]

var ticks := 0

var _threat: Array = []        # [bearing 0..7][action] counts while a telegraph is in range
var _crowded: Array = []       # [action] counts while 2+ telegraphs are in range
var _dash_dirs: Array = []     # [dir 0..7] counts
var _zones: Array = []         # [zone 0..8] ticks spent
var _turns: Array = []         # [from action][to action] counts, only when the action changes
var _last := -1


func _init() -> void:
	reset()


func reset() -> void:
	ticks = 0
	_threat = []
	for b in 8:
		_threat.append(_zeros(N))
	_crowded = _zeros(N)
	_dash_dirs = _zeros(8)
	_zones = _zeros(9)
	_turns = []
	for a in N:
		_turns.append(_zeros(N))
	_last = -1


## `bearing`: Cfg.threat_bearing() of the situation the action was taken in (only 0..7 count).
## `near`: number of telegraphs in threat range. `dash_dir`: 0..7 when `action` is DASH.
func record(action: int, bearing: int, near: int, zone: int, dash_dir: int = -1) -> void:
	ticks += 1
	if bearing >= 0 and bearing < 8:
		_threat[bearing][action] += 1
	if near >= 2:
		_crowded[action] += 1
	if action == ActionSpace.DASH and dash_dir >= 0 and dash_dir < 8:
		_dash_dirs[dash_dir] += 1
	if zone >= 0 and zone < 9:
		_zones[zone] += 1
	if _last >= 0 and action != _last:
		_turns[_last][action] += 1
	_last = action


## Up to `max_lines` habit sentences, most predictable first. Empty if the run was too short.
func lines(max_lines: int = 4) -> Array:
	var cands: Array = []   # [score, text]

	for b in 8:
		var top := _top(_threat[b])
		if top[2] >= MIN_SAMPLES:
			cands.append([_score(top[1], N), "When a circle appears %s, you %s %d%% of the time."
					% [BEARING_TEXT[b], ACTION_TEXT[top[0]], _pct(top[1])]])

	var crowd := _top(_crowded)
	if crowd[2] >= MIN_SAMPLES:
		cands.append([_score(crowd[1], N), "When two or more circles are close, you %s %d%% of the time."
				% [ACTION_TEXT[crowd[0]], _pct(crowd[1])]])

	var dash := _top(_dash_dirs)
	if dash[2] >= 4:
		cands.append([_score(dash[1], 8), "%d%% of your dashes go %s." % [_pct(dash[1]), DIR_TEXT[dash[0]]]])

	var zone := _top(_zones)
	if zone[2] >= 50:
		cands.append([_score(zone[1], 9), "You spend %d%% of your time near the %s."
				% [_pct(zone[1]), ZONE_TEXT[zone[0]]]])

	for a in N:
		var t := _top(_turns[a])
		if t[2] < MIN_SAMPLES:
			continue
		var from: String = "a dash" if a == ActionSpace.DASH else ("standing still" if a == ActionSpace.IDLE else "moving " + DIR_TEXT[a])
		var to: String = "start moving " + DIR_TEXT[t[0]] if a == ActionSpace.IDLE and t[0] < 8 else ACTION_TEXT[t[0]]
		cands.append([_score(t[1], N - 1), "After %s, you %s next %d%% of the time." % [from, to, _pct(t[1])]])

	cands.sort_custom(func(x: Array, y: Array) -> bool: return x[0] > y[0])
	var out: Array = []
	for c in cands:
		if out.size() >= max_lines or c[0] < MIN_SCORE:
			break
		out.append(c[1])
	return out


# --- Helpers ----------------------------------------------------------------

## [argmax index, share of total, total]
func _top(counts: Array) -> Array:
	var total := 0
	var best := 0
	for i in counts.size():
		total += int(counts[i])
		if counts[i] > counts[best]:
			best = i
	var share := float(counts[best]) / float(total) if total > 0 else 0.0
	return [best, share, total]


## How much better than a uniform guess over `options` choices (0 = no habit, 1 = always).
func _score(share: float, options: int) -> float:
	var base := 1.0 / float(options)
	return (share - base) / (1.0 - base)


func _pct(share: float) -> int:
	return roundi(share * 100.0)


func _zeros(n: int) -> Array:
	var a: Array = []
	a.resize(n)
	a.fill(0)
	return a

extends RefCounted
## The Shadow talks to you.
##
## Two sources of lines:
##   - events the game reports (a hit, a dash, the ghost, a blind spot, ...), via say() / on_dash();
##   - every HABIT_EVERY seconds, a taunt built from your strongest habit in ProfileStats
##     ("A circle to your right? You'll go left."), so the lines are about you specifically.
## Priorities and a minimum gap keep it from talking over itself.
##
## Presentation only: it has its own RNG and the simulation never reads it, so replays are
## unaffected (the lines in a replay may differ, the run does not).

const ProfileStats = preload("res://scripts/profile_stats.gd")

const SHOW_TIME := 3.4              # seconds a line stays up
const MIN_GAP := 2.5                # quiet time after a line before a low-priority one
const HABIT_EVERY := 9.0            # seconds between habit taunts (randomised a little)
const HABIT_MIN_SCORE := 0.35

const LOW := 0                      # habit taunts, "I've seen this"
const MID := 1                      # dash repeats, accuracy changes
const HIGH := 2                     # hits, ghost, thorns: may interrupt

const BEARING_SHORT := ["above you", "to your upper right", "to your right", "to your lower right",
		"below you", "to your lower left", "to your left", "to your upper left"]
const DO := ["go up", "go up-right", "go right", "go down-right", "go down", "go down-left",
		"go left", "go up-left", "freeze", "dash"]
const DIR := ["up", "up-right", "right", "down-right", "down", "down-left", "left", "up-left"]

const EVENTS := {
	"start_new": ["Show me how you move.", "Let's see what you do.", "Move. I'm watching."],
	"start_back": ["Welcome back. I remember you.", "Again? I remember everything.",
			"Run {run}. I know you better now."],
	"hit_aimed": ["I saw that coming.", "Too easy.", "Exactly where I aimed.", "I've seen this before.",
			"You walked right into it."],
	"hit_explore": ["Lucky guess. Or was it?", "Even my guesses find you."],
	"hit_thorns": ["Your favourite spot. Not any more.", "You keep coming back here."],
	"hit_ghost": ["Even your past self is faster.", "You ran into yourself."],
	"shelter": ["Hiding? I'll remember this spot.", "Enjoy it while it lasts."],
	"ghost_spawn": ["Remember yourself?", "Your best run is back. Beat it.", "Meet the old you."],
	"ghost_done": ["You outran yourself. I'm still learning.", "Fine. You changed. So will I."],
	"reshape": ["I'm rearranging your favourite places.", "Let's move the furniture."],
	"seen_this": ["I've seen this before.", "I know this pattern.", "This again?"],
	"acc_up1": ["I'm starting to understand you.", "Getting clearer."],
	"acc_up2": ["I know you.", "You're an open book."],
	"acc_down": ["...you're changing.", "Interesting. That's new.", "Where did that come from?"],
}

const HABIT_TEMPLATES := {
	"threat": ["A circle {bearing}? You'll {do}.", "When I strike {bearing}, you {do}. {pct}%.",
			"Threat {bearing}... and you {do}. Always."],
	"crowd": ["Two circles and you {do}. Every time.", "Crowded? You always {do}."],
	"dash": ["Another dash {dir}?", "{pct}% of your dashes go {dir}.", "Dash {dir} again. I'll be there."],
	"zone": ["Back to the {zone} again?", "You love the {zone}.", "{pct}% of your time near the {zone}."],
	"turn": ["After {from}, you {to}. I know.", "{From}... then you {to}. Predictable."],
}

var line := ""                      # current line ("" = silent)
var age := 99.0                     # seconds since `line` started
var priority := LOW

var _quiet := 0.0                   # time since the last line ended
var _habit_timer := HABIT_EVERY
var _last_key := ""
var _last_text := ""
var _dashes: Array = []             # recent dash directions
var _acc_level := 0                 # 0 / 1 / 2 with hysteresis
var _seen_cd := 0.0
var _rng := RandomNumberGenerator.new()


func _init() -> void:
	_rng.randomize()


func reset(runs: int) -> void:
	line = ""
	age = 99.0
	priority = LOW
	_quiet = 0.0
	_habit_timer = HABIT_EVERY
	_last_key = ""
	_dashes.clear()
	_acc_level = 0
	_seen_cd = 8.0
	if runs > 0:
		say("start_back", MID, {"run": runs + 1})
	else:
		say("start_new", MID)


func is_talking() -> bool:
	return line != "" and age < SHOW_TIME


## Speak an event line. Returns true if it was spoken.
func say(event: String, prio: int = HIGH, args: Dictionary = {}) -> bool:
	if not EVENTS.has(event):
		return false
	return _speak(_pick(EVENTS[event]).format(args), prio)


## "Left again?" when the last three dashes went the same way.
func on_dash(dir: int) -> void:
	if dir < 0 or dir > 7:
		return
	_dashes.append(dir)
	if _dashes.size() > 3:
		_dashes.pop_front()
	if _dashes.size() == 3 and _dashes.count(dir) == 3:
		var d: String = DIR[dir]
		var text := _pick(["{D} again?", "{D}. Again.", "Always {d}, huh?"]).format({"D": _cap(d), "d": d})
		if _speak(text, MID):
			_dashes.clear()


## Called every frame. `acc`: rolling top-1 accuracy; `acc_ready`: enough samples to trust it;
## `confident`: the model is using a long context and puts > 60% on one action.
func update(dt: float, profile: ProfileStats, acc: float, acc_ready: bool, confident: bool) -> void:
	age += dt
	if not is_talking():
		_quiet += dt
	_seen_cd -= dt

	if acc_ready:
		if _acc_level < 2 and acc > 0.6:
			_acc_level = 2
			say("acc_up2", MID)
		elif _acc_level < 1 and acc > 0.42:
			_acc_level = 1
			say("acc_up1", MID)
		elif _acc_level > 0 and acc < 0.25:
			_acc_level = 0
			say("acc_down", MID)

	if confident and _seen_cd <= 0.0 and say("seen_this", LOW):
		_seen_cd = 20.0

	_habit_timer -= dt
	if _habit_timer <= 0.0:
		_habit_timer = HABIT_EVERY + _rng.randf_range(-2.0, 3.0)
		var taunt := habit_taunt(profile.habits())
		if taunt != "":
			_speak(taunt, LOW)


## The strongest habit, phrased as a taunt; skips the habit used last time. "" if none.
func habit_taunt(habits: Array) -> String:
	for h in habits:
		if float(h["score"]) < HABIT_MIN_SCORE:
			break
		if h["key"] == _last_key or not HABIT_TEMPLATES.has(h["kind"]):
			continue
		_last_key = h["key"]
		return _pick(HABIT_TEMPLATES[h["kind"]]).format(_fields(h))
	return ""


# --- Internals --------------------------------------------------------------

func _speak(text: String, prio: int) -> bool:
	if is_talking():
		# Only a more important line may interrupt, and not in its first second.
		if prio <= priority or age < 1.0:
			return false
	elif prio == LOW and _quiet < MIN_GAP:
		return false
	line = text
	age = 0.0
	priority = prio
	_quiet = 0.0
	_last_text = text
	return true


func _pick(options: Array) -> String:
	var s: String = options[_rng.randi_range(0, options.size() - 1)]
	if options.size() > 1 and s == _last_text:
		s = options[(options.find(s) + 1) % options.size()]
	return s


func _fields(h: Dictionary) -> Dictionary:
	var f := {"pct": h.get("pct", 0)}
	match String(h["kind"]):
		"threat":
			f["bearing"] = BEARING_SHORT[int(h["bearing"])]
			f["do"] = DO[int(h["action"])]
		"crowd":
			f["do"] = DO[int(h["action"])]
		"dash":
			f["dir"] = DIR[int(h["dir"])]
		"zone":
			f["zone"] = ProfileStats.ZONE_TEXT[int(h["zone"])]
		"turn":
			var from := ProfileStats.from_text(int(h["from"]))
			f["from"] = from
			f["From"] = _cap(from)
			f["to"] = ProfileStats.to_text(int(h["from"]), int(h["to"])).replace("move ", "go ")
	return f


## Upper-case only the first letter ("standing still" -> "Standing still").
static func _cap(s: String) -> String:
	return s if s.is_empty() else s[0].to_upper() + s.substr(1)

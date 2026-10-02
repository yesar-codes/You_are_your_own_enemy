extends RefCounted
## Shared tunables and small pure helpers. Other scripts preload this as `Cfg`.

const ActionSpace = preload("res://scripts/action_space.gd")

# --- Arena / timing -------------------------------------------------------
const ARENA := Rect2(20, 20, 840, 680)
const TICK := 0.1                       # model sampling period (10 Hz)
const ROUND_SECONDS := 25.0

# --- Player ---------------------------------------------------------------
const PLAYER_SPEED := 260.0
const PLAYER_RADIUS := 12.0
const PLAYER_HP := 3
const DASH_SPEED := 900.0
const DASH_TIME := 0.15
const DASH_COOLDOWN := 1.2
const DASH_DISTANCE := DASH_SPEED * DASH_TIME   # 135 px

# --- Shadow / attacks -----------------------------------------------------
const ATTACK_RADIUS := 62.0
const STRIKE_TIME := 0.15
const WINDUP_START := 0.9               # seconds the player gets to react
const WINDUP_MIN := 0.5
const MAX_VOLLEY := 3
const THREAT_RANGE := 300.0             # how far away a telegraph still counts as a "threat"

# --- Exploration (epsilon-greedy over shots) ------------------------------
const EPS_START := 0.35
const EPS_MIN := 0.08
const EPS_DECAY := 0.96                 # multiplied in after every volley

# --- Context modes (what extra "situation" the model conditions on) -------
const MODE_NONE := 0
const MODE_ZONE := 1
const MODE_THREAT := 2
const MODE_NAMES := ["history only", "arena zone", "threat bearing"]

const ACC_WINDOW := 150                 # rolling window (ticks) for accuracy stats

# --- Ghost Shadow (final boss: your best run, replayed) --------------------
const GHOST_ROUND := 3                  # the ghost arrives when this round starts
const GHOST_GRACE := 1.5                # seconds after spawning before it can hurt
const GHOST_MAX_SECONDS := ROUND_SECONDS
const GHOST_FIRE_SLOWDOWN := 1.35       # Shadow volley interval multiplier while it is out
const GHOST_HIT_DIST := PLAYER_RADIUS * 1.7

# --- Learning arena (thorns on your favourite cells, blind spots on cold ones) ---
const ARENA_RESHAPE_EVERY := 12.0       # seconds between reshapes (first one at 12 s)
const ARENA_HEAT_DECAY := 0.998         # per 10 Hz tick; half-life about 35 s
const ARENA_MEMORY_MASS := 150.0        # long-term heat carried into a run, in ticks
const ARENA_HOT_FACTOR := 1.5           # a cell needs this many times the mean heat for thorns
const ARENA_MAX_THORNS := 8
const ARENA_GROW_TIME := 1.5            # warning before thorns hurt
const ARENA_WITHER_TIME := 1.0
const POCKET_MIN_DIST := 220.0          # a blind spot opens at least this far from you
const POCKET_SHELTER := 4.0             # seconds of strike immunity it holds

const GHOST_UNAVAILABLE := 0           # no recorded best run yet
const GHOST_WAITING := 1
const GHOST_ACTIVE := 2
const GHOST_DONE := 3


static func clamp_to_arena(p: Vector2) -> Vector2:
	var m := Vector2(PLAYER_RADIUS, PLAYER_RADIUS)
	return p.clamp(ARENA.position + m, ARENA.end - m)


## 3x3 grid cell of the arena, 0..8.
static func zone_of(p: Vector2) -> int:
	var cx := clampi(int((p.x - ARENA.position.x) / ARENA.size.x * 3.0), 0, 2)
	var cy := clampi(int((p.y - ARENA.position.y) / ARENA.size.y * 3.0), 0, 2)
	return cy * 3 + cx


## Direction (0..7) from `p` towards the nearest active telegraph;
## 8 = no threat in range, 9 = standing right on top of one.
static func threat_bearing(p: Vector2, threats: Array) -> int:
	var best := INF
	var to := Vector2.ZERO
	for t in threats:
		var tv: Vector2 = t
		var d := p.distance_to(tv)
		if d < best:
			best = d
			to = tv - p
	if best > THREAT_RANGE:
		return 8
	if best < 8.0:
		return 9
	return ActionSpace.from_vector(to)


static func situation_of(mode: int, p: Vector2, threats: Array) -> int:
	match mode:
		MODE_ZONE:
			return zone_of(p)
		MODE_THREAT:
			return threat_bearing(p, threats)
	return 0

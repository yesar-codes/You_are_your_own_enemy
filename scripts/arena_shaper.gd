extends RefCounted
## The arena learns too.
##
## It keeps a heat map of where the player stands (a 12x10 grid, sampled at 10 Hz, slowly
## forgetting, and carried over between runs). Every RESHAPE_EVERY seconds it reshapes:
##   - thorns grow on the hottest cells (telegraphed first, then they hurt to stand on);
##   - one "blind spot" opens on a cold cell far away. Inside it the Shadow's strikes cannot
##     hit you, but only for a few seconds, and standing there heats the cell up.
## So the map pushes you out of your habits, and hiding in a new spot becomes a habit it sees.
##
## Pure data + math, no Node dependencies. All choices come from the heat map and a seeded
## RNG, so replays reproduce the same arena.

const Cfg = preload("res://scripts/game_config.gd")

const COLS := 12
const ROWS := 10
const CELLS := COLS * ROWS

var heat := PackedFloat64Array()        # per cell
var thorns: Dictionary = {}             # cell -> age in seconds (harmless while < GROW_TIME)
var withering: Dictionary = {}          # cell -> seconds left of the fade-out
var pocket := -1                        # blind-spot cell, -1 = none
var pocket_charge := 0.0                # seconds of shelter left
var reshapes := 0
var first_target := -1                  # hottest cell of the first reshape (profile card)
var rng := RandomNumberGenerator.new()


## `initial_heat` is the long-term memory scaled to tick units (may be empty).
func reset(initial_heat: PackedFloat64Array, seed_value: int) -> void:
	heat = PackedFloat64Array()
	heat.resize(CELLS)
	if initial_heat.size() == CELLS:
		heat = initial_heat.duplicate()
	thorns.clear()
	withering.clear()
	pocket = -1
	pocket_charge = 0.0
	reshapes = 0
	first_target = -1
	rng.seed = seed_value


func cell_of(p: Vector2) -> int:
	var cx := clampi(int((p.x - Cfg.ARENA.position.x) / Cfg.ARENA.size.x * COLS), 0, COLS - 1)
	var cy := clampi(int((p.y - Cfg.ARENA.position.y) / Cfg.ARENA.size.y * ROWS), 0, ROWS - 1)
	return cy * COLS + cx


func cell_rect(i: int) -> Rect2:
	var size := Vector2(Cfg.ARENA.size.x / COLS, Cfg.ARENA.size.y / ROWS)
	return Rect2(Cfg.ARENA.position + Vector2(i % COLS, floori(i / float(COLS))) * size, size)


## 10 Hz: remember where the player is.
func observe(p: Vector2) -> void:
	for i in CELLS:
		heat[i] *= Cfg.ARENA_HEAT_DECAY
	heat[cell_of(p)] += 1.0


## Every physics frame: age thorns, fade withering ones, drain the blind spot while used.
func step(delta: float, player_pos: Vector2) -> void:
	for c in thorns.keys():
		thorns[c] = float(thorns[c]) + delta
	for c in withering.keys():
		var left := float(withering[c]) - delta
		if left <= 0.0:
			withering.erase(c)
		else:
			withering[c] = left
	if pocket >= 0 and cell_of(player_pos) == pocket:
		pocket_charge = maxf(0.0, pocket_charge - delta)


func reshape(player_pos: Vector2) -> void:
	reshapes += 1
	var order := _cells_by_heat()
	var mean := _total() / float(CELLS)

	# Thorns: the K hottest cells that are clearly above average.
	var want := {}
	var k := mini(Cfg.ARENA_MAX_THORNS, reshapes + 1)
	for c in order:
		if want.size() >= k or heat[c] < mean * Cfg.ARENA_HOT_FACTOR or heat[c] <= 0.0:
			break
		want[c] = true
	if first_target < 0 and not want.is_empty():
		first_target = int(order[0])
	for c in thorns.keys():
		if not want.has(c):
			thorns.erase(c)
			withering[c] = Cfg.ARENA_WITHER_TIME
	for c in want:
		if not thorns.has(c):
			thorns[c] = 0.0
			withering.erase(c)

	# Blind spot: one of the coldest free cells far enough away that reaching it is a choice.
	var cold: Array = []
	for i in range(order.size() - 1, -1, -1):
		var c: int = order[i]
		if thorns.has(c) or cell_rect(c).get_center().distance_to(player_pos) < Cfg.POCKET_MIN_DIST:
			continue
		cold.append(c)
		if cold.size() >= 6:
			break
	if cold.is_empty():
		pocket = -1
		pocket_charge = 0.0
	else:
		pocket = int(cold[rng.randi_range(0, cold.size() - 1)])
		pocket_charge = Cfg.POCKET_SHELTER


func is_thorn_at(p: Vector2) -> bool:
	var c := cell_of(p)
	if not thorns.has(c) or float(thorns[c]) < Cfg.ARENA_GROW_TIME:
		return false
	# A little forgiveness at the edges of the cell.
	return cell_rect(c).grow(-Cfg.PLAYER_RADIUS * 0.4).has_point(p)


func is_growing(c: int) -> bool:
	return thorns.has(c) and float(thorns[c]) < Cfg.ARENA_GROW_TIME


## True while the player stands in a blind spot that still has charge.
func shelters(p: Vector2) -> bool:
	return pocket >= 0 and pocket_charge > 0.0 and cell_of(p) == pocket


func max_heat() -> float:
	var m := 0.0
	for v in heat:
		m = maxf(m, v)
	return m


## Heat as shares summing to 1 (the long-term memory saved between runs).
func shares() -> Array:
	var t := _total()
	var out: Array = []
	for v in heat:
		out.append(v / t if t > 0.0 else 0.0)
	return out


# --- Internals --------------------------------------------------------------

func _total() -> float:
	var t := 0.0
	for v in heat:
		t += v
	return t


## Hottest first; ties broken by cell index so the order is deterministic.
func _cells_by_heat() -> Array:
	var idx: Array = range(CELLS)
	idx.sort_custom(func(a: int, b: int) -> bool:
		if heat[a] == heat[b]:
			return a < b
		return heat[a] > heat[b])
	return idx

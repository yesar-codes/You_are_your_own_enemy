extends RefCounted
## One physics frame of player input packed into 5 bits.
##
## This is the unit the replay system records. Because the simulation runs on Godot's fixed
## physics step and every random number comes from a seeded RNG, the same stream of these
## integers always reproduces the same run.

const UP := 1
const DOWN := 2
const LEFT := 4
const RIGHT := 8
const DASH := 16


static func read_keyboard() -> int:
	var b := 0
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		b |= UP
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		b |= DOWN
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		b |= LEFT
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		b |= RIGHT
	if Input.is_key_pressed(KEY_SPACE):
		b |= DASH
	return b


## Normalised movement direction encoded in `bits` (opposite keys cancel).
static func to_vector(bits: int) -> Vector2:
	var v := Vector2.ZERO
	if bits & UP:
		v.y -= 1.0
	if bits & DOWN:
		v.y += 1.0
	if bits & LEFT:
		v.x -= 1.0
	if bits & RIGHT:
		v.x += 1.0
	return v.normalized()


static func dash_held(bits: int) -> bool:
	return bits & DASH != 0

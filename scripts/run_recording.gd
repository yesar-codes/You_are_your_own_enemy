extends RefCounted
## One run stored as *inputs only*.
##
## We never record positions. We record the starting state (the model's counts, the planner's
## RNG seed and epsilon, the context mode) plus one InputBits value per physics frame. Godot's
## physics step is fixed, so feeding the same inputs into the same starting state replays the
## run exactly: same predictions, same volleys, same hits. Rollback netcode relies on the same
## property.
##
## Frames are run-length encoded for saving because input rarely changes between frames.

const VERSION := 1

var rng_seed := 0
var tick_rate := 60
var context_mode := 0
var epsilon := 0.0
var model: Dictionary = {}                  # MarkovPredictor.to_dict() at frame 0
var ghost_frames := PackedByteArray()       # inputs of the Ghost Shadow this run faced
var duration := 0.0
var events: Array = []                      # [frame, context_mode] for each Z press
var frames := PackedByteArray()             # InputBits per physics frame


func record(bits: int) -> void:
	frames.append(bits)


func add_mode_event(frame: int, mode: int) -> void:
	events.append([frame, mode])


func to_dict() -> Dictionary:
	return {
		"version": VERSION,
		"seed": rng_seed,
		"tick_rate": tick_rate,
		"context_mode": context_mode,
		"epsilon": epsilon,
		"model": model,
		"duration": duration,
		"events": events,
		"frames": encode_rle(frames),
		"ghost_frames": encode_rle(ghost_frames),
	}


## Returns null if `d` is not a recording this version understands.
static func from_dict(d: Dictionary) -> RefCounted:
	if int(d.get("version", 0)) != VERSION:
		return null
	if not (d.get("frames") is Array) or not (d.get("model") is Dictionary):
		return null
	var r = load("res://scripts/run_recording.gd").new()
	r.rng_seed = int(d.get("seed", 0))
	r.tick_rate = int(d.get("tick_rate", 60))
	r.context_mode = int(d.get("context_mode", 0))
	r.epsilon = float(d.get("epsilon", 0.0))
	r.model = d["model"]
	r.duration = float(d.get("duration", 0.0))
	for e in d.get("events", []):
		if e is Array and e.size() == 2:
			r.events.append([int(e[0]), int(e[1])])
	r.frames = decode_rle(d["frames"])
	if d.get("ghost_frames") is Array:
		r.ghost_frames = decode_rle(d["ghost_frames"])
	return r


## [value, count, value, count, ...]
static func encode_rle(data: PackedByteArray) -> Array:
	var out: Array = []
	var i := 0
	while i < data.size():
		var v := data[i]
		var n := 1
		while i + n < data.size() and data[i + n] == v:
			n += 1
		out.append(v)
		out.append(n)
		i += n
	return out


static func decode_rle(rle: Array) -> PackedByteArray:
	var out := PackedByteArray()
	for i in range(0, rle.size() - 1, 2):
		var v := int(rle[i])
		for k in int(rle[i + 1]):
			out.append(v)
	return out

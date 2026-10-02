extends RefCounted
## Persists the learned model (and a little metadata) as JSON under user://.
## Replays live next to it in user://replays/ ("last" and "best" run).
## Everything stays on the local machine. Delete the files or press N in-game to wipe them.

const PATH := "user://shadow_model.json"
const REPLAY_DIR := "user://replays/"


static func save_state(state: Dictionary) -> void:
	_write(PATH, JSON.stringify(state))


static func load_state() -> Dictionary:
	return _read(PATH)


## Full float precision: a replay must restart from the model's exact counts.
static func save_replay(slot: String, data: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(REPLAY_DIR))
	_write(REPLAY_DIR + slot + ".json", JSON.stringify(data, "", false, true))


static func load_replay(slot: String) -> Dictionary:
	return _read(REPLAY_DIR + slot + ".json")


static func wipe() -> void:
	for p in [PATH, REPLAY_DIR + "last.json", REPLAY_DIR + "best.json"]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))


static func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("Could not write %s (error %d)" % [path, FileAccess.get_open_error()])
		return
	f.store_string(text)


static func _read(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if parsed is Dictionary:
		return parsed
	return {}

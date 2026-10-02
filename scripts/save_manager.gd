extends RefCounted
## Persists the learned model (and a little metadata) as JSON under user://.
## Everything stays on the local machine. Delete the file or press N in-game to wipe it.

const PATH := "user://shadow_model.json"


static func save_state(state: Dictionary) -> void:
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	if f == null:
		push_warning("Could not write %s (error %d)" % [PATH, FileAccess.get_open_error()])
		return
	f.store_string(JSON.stringify(state))


static func load_state() -> Dictionary:
	if not FileAccess.file_exists(PATH):
		return {}
	var f := FileAccess.open(PATH, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if parsed is Dictionary:
		return parsed
	return {}


static func wipe() -> void:
	if FileAccess.file_exists(PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))

extends Node2D
## Draws the Shadow's current line (shadow_voice.gd) as a speech bubble above it, typed out
## letter by letter with a little voice blip. Lives on the HUD layer so the game-over dimming
## doesn't hide it and screen shake doesn't blur it.

const Cfg = preload("res://scripts/game_config.gd")
const ShadowVoice = preload("res://scripts/shadow_voice.gd")

const CHARS_PER_SEC := 38.0
const FONT_SIZE := 15
const PAD := Vector2(10.0, 7.0)
const C_BG := Color(0.12, 0.04, 0.2, 0.92)
const C_EDGE := Color(0.75, 0.35, 1.0, 0.9)
const C_TEXT := Color(1.0, 0.82, 1.0)

var game                            # main.gd
var _font: Font = ThemeDB.fallback_font
var _shown := 0                     # characters revealed so far
var _for_line := ""


func _process(_delta: float) -> void:
	var v = game.voice if game != null else null
	if v == null:
		return
	if v.line != _for_line:
		_for_line = v.line
		_shown = 0
	var target := mini(_for_line.length(), int(v.age * CHARS_PER_SEC))
	while _shown < target:
		_shown += 1
		# Blip on every other letter, skipping spaces, like old RPG dialogue.
		if _shown % 2 == 0 and _for_line[_shown - 1] != " ":
			game.synth.blip()
	queue_redraw()


func _draw() -> void:
	if game == null or game.voice == null or not game.voice.is_talking():
		return
	var text := _for_line.substr(0, _shown)
	var full := _font.get_string_size(_for_line, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE)
	var size := full + PAD * 2.0
	var age: float = game.voice.age
	var fade := clampf((ShadowVoice.SHOW_TIME - age) / 0.4, 0.0, 1.0)

	var anchor: Vector2 = game.shadow_screen_pos()
	var pos := anchor + Vector2(-size.x * 0.5, -size.y - 30.0)
	if pos.y < Cfg.ARENA.position.y + 4.0:          # no room above: show it below the Shadow
		pos.y = anchor.y + 30.0
	pos.x = clampf(pos.x, Cfg.ARENA.position.x + 4.0, Cfg.ARENA.end.x - size.x - 4.0)
	var box := Rect2(pos, size)

	# Tail pointing at the Shadow.
	var tip := anchor + Vector2(0.0, -18.0 if pos.y < anchor.y else 18.0)
	var bx := clampf(anchor.x, box.position.x + 12.0, box.end.x - 12.0)
	var by := box.end.y if pos.y < anchor.y else box.position.y
	draw_colored_polygon(PackedVector2Array([Vector2(bx - 7.0, by), Vector2(bx + 7.0, by), tip]),
			Color(C_BG, C_BG.a * fade))
	draw_rect(box, Color(C_BG, C_BG.a * fade), true)
	draw_rect(box, Color(C_EDGE, C_EDGE.a * fade), false, 1.5)
	draw_string(_font, pos + Vector2(PAD.x, PAD.y + FONT_SIZE - 2.0), text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, Color(C_TEXT, fade))

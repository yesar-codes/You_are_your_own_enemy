extends CanvasLayer
## Full-screen post effect layer (above the world, below the HUD): chromatic aberration and a
## red vignette that flash when you get hit. Visual only.

const SHADER = preload("res://shaders/hit_aberration.gdshader")
const DECAY := 2.2                  # amount per second

var _rect: ColorRect
var _mat: ShaderMaterial
var _amount := 0.0


func _ready() -> void:
	layer = 5
	_mat = ShaderMaterial.new()
	_mat.shader = SHADER
	_rect = ColorRect.new()
	_rect.material = _mat
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_rect.visible = false
	add_child(_rect)


func kick(amount: float) -> void:
	_amount = minf(1.0, _amount + amount)


func _process(delta: float) -> void:
	_amount = maxf(0.0, _amount - DECAY * delta)
	_rect.visible = _amount > 0.01
	_mat.set_shader_parameter("amount", _amount)

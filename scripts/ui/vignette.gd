# scripts/ui/vignette.gd
# 方向 A 全局氛围顶层：暗角 vignette + 受击红边脉冲（世界之上、HUD 之下）。
class_name Vignette
extends CanvasLayer

var _rect: ColorRect = null
var _mat: ShaderMaterial = null

const HURT_DECAY := 0.45                      # 受击红边衰减时长 s
const LAYER_ORDER := 8                       # 世界(0) < 本层 < HUD(10)

var _hurt_left: float = 0.0
var _hurt_strength: float = 0.0


func _ready() -> void:
	layer = LAYER_ORDER
	_rect = ColorRect.new()
	_rect.name = "VignetteRect"
	_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mat = _shader_material()
	_rect.material = _mat
	add_child(_rect)
	EventBus.player_hit.connect(_on_player_hit)


func tick(p_raw_delta: float) -> void:
	# 受击红边衰减（raw 通道；由 GameLoop ⑧ UI 阶段驱动）
	if _hurt_left > 0.0:
		_hurt_left = maxf(_hurt_left - p_raw_delta, 0.0)
		_hurt_strength = _hurt_left / HURT_DECAY
		_mat.set_shader_parameter(&"hurt", _hurt_strength)


func _on_player_hit(_p_damage: float, _p_source_uid: int) -> void:
	_hurt_left = HURT_DECAY
	_hurt_strength = 1.0
	_mat.set_shader_parameter(&"hurt", _hurt_strength)


static func _shader_material() -> ShaderMaterial:
	var shader := Shader.new()
	shader.code = "\
shader_type canvas_item;\n\
uniform float hurt : hint_range(0.0, 1.0) = 0.0;\n\
void fragment() {\n\
\tvec2 d = SCREEN_UV - vec2(0.5);\n\
\td.x *= 0.5625;                           // 竖屏比例修正（720/1280）\n\
\tfloat v = smoothstep(0.38, 0.95, length(d));\n\
\tvec3 col = vec3(0.0);\n\
\tfloat a = v * 0.55;                      // 常驻暗角（克制）\n\
\tfloat edge = smoothstep(0.55, 1.05, length(d));\n\
\tcol += vec3(1.0, 0.18, 0.16) * edge * hurt * 0.8;\n\
\ta += edge * hurt * 0.35;\n\
\tCOLOR = vec4(col, a);\n\
}\n"
	var mat := ShaderMaterial.new()
	mat.shader = shader
	return mat

# scripts/ui/starfield.gd
# 方向 A 全局氛围底层：深空星空（双层视差星点 + 缓慢星云噪声 + 微网格），单 canvas_item
# shader 一次绘制。Menu 与战斗共用（CanvasLayer layer=-10 恒在底层，状态切换不重建）。
# 全屏 ColorRect + shader；drift 由 TIME 驱动（无逐帧逻辑开销）。
class_name Starfield
extends CanvasLayer

var _rect: ColorRect = null

const VIEW := Vector2(720.0, 1280.0)


func _ready() -> void:
	layer = -10
	_rect = ColorRect.new()
	_rect.name = "StarRect"
	_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rect.material = _shader_material()
	_rect.color = Palette.BG_DEEP
	add_child(_rect)


static func _shader_material() -> ShaderMaterial:
	# 共享静态材质（类级单 shader 单 material）
	var shader := Shader.new()
	# 双层视差星点：hash 网格抖动；星云：2 octave value-noise；微网格：细线低透明。
	shader.code = "\
shader_type canvas_item;\n\
uniform vec3 base_color = vec3(0.043, 0.055, 0.102);\n\
uniform vec2 view = vec2(720.0, 1280.0);\n\
\n\
float hash21(vec2 p) {\n\
\tp = fract(p * vec2(234.34, 435.345));\n\
\tp += dot(p, p + 34.23);\n\
\treturn fract(p.x * p.y);\n\
}\n\
float vnoise(vec2 p) {\n\
\tvec2 i = floor(p);\n\
\tvec2 f = fract(p);\n\
\tf = f * f * (3.0 - 2.0 * f);\n\
\tfloat a = hash21(i);\n\
\tfloat b = hash21(i + vec2(1.0, 0.0));\n\
\tfloat c = hash21(i + vec2(0.0, 1.0));\n\
\tfloat d = hash21(i + vec2(1.0, 1.0));\n\
\treturn mix(mix(a, b, f.x), mix(c, d, f.x), f.y);\n\
}\n\
float star_layer(vec2 uv, float density, float speed, float twinkle_t) {\n\
\tvec2 gv = uv * density;\n\
\tgv.y += twinkle_t * speed;\n\
\tvec2 id = floor(gv);\n\
\tvec2 f = fract(gv) - 0.5;\n\
\tfloat h = hash21(id);\n\
\tfloat star = smoothstep(0.06 + 0.05 * h, 0.0, length(f));\n\
\tfloat tw = 0.6 + 0.4 * sin(twinkle_t * (1.0 + h * 3.0) + h * 40.0);\n\
\treturn star * step(0.82, h) * tw;\n\
}\n\
void fragment() {\n\
\tvec2 uv = UV;\n\
\tfloat t = TIME;\n\
\t// 星云（极暗，缓慢漂移）\n\
\tfloat neb = vnoise(uv * 3.0 + vec2(t * 0.008, -t * 0.005));\n\
\tneb = pow(neb, 2.6);\n\
\tvec3 col = base_color + vec3(0.10, 0.16, 0.30) * neb * 0.75;\n\
\tcol += vec3(0.16, 0.05, 0.14) * pow(vnoise(uv * 2.2 - vec2(t * 0.004, t * 0.006)), 3.0) * 0.65;\n\
\t// 双层视差星点\n\
\tfloat s1 = star_layer(uv, 26.0, 0.010, t);\n\
\tfloat s2 = star_layer(uv + 13.7, 52.0, 0.022, t * 1.3);\n\
\tcol += vec3(0.75, 0.88, 1.0) * s1 * 0.9;\n\
\tcol += vec3(0.55, 0.70, 0.95) * s2 * 0.55;\n\
\t// 微网格（低透明青灰，氧起航图质感）\n\
\tvec2 g = abs(fract(uv * view / 96.0) - 0.5);\n\
\tfloat grid = smoothstep(0.48, 0.5, max(g.x, g.y));\n\
\tcol += vec3(0.10, 0.16, 0.24) * grid * 0.10;\n\
\tCOLOR = vec4(col, 1.0);\n\
}\n"
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter(&"base_color",
		Vector3(Palette.BG_DEEP.r, Palette.BG_DEEP.g, Palette.BG_DEEP.b))
	mat.set_shader_parameter(&"view", VIEW)
	return mat

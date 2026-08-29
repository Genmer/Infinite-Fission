# scripts/ui/crt_overlay.gd
# CRT 全局氛围层（方向 B 交付 ①+⑤）：扫描线 + 轻微色差 + 暗角 + 开机淡入，
# 合并为【单张全屏 shader 单 pass】（性能红线：禁止逐实体跑屏后 shader）。
# 签名瞬间（同 shader 内 uniform 驱动，不加第二 pass）：
#   · Boss 死亡 = CRT 信号干扰（横向撕裂 glitch 0.3s + 磷光余辉绿抬升）
#   · 波次切换 = 屏幕轻闪 + 刷新线自上而下扫过
# 事件订阅（Node 派生 ✓ E-12）：enemy_killed（读 tags 判 Boss）/ wave_started。
class_name CRTOverlay
extends CanvasLayer

const BOOT_FADE_S := 1.1                      # 开机式淡入（全黑 → 透出）
const GLITCH_S := 0.30                        # Boss 死亡干扰时长
const SWEEP_S := 0.38                         # 刷新线扫过时长
const FLASH_S := 0.14                         # 波次轻闪时长
const LAYER := 90                             # UI 层之上（HUD=默认 1）

var _rect: ColorRect = null
var _mat: ShaderMaterial = null
var _fade_left: float = BOOT_FADE_S
var _glitch_left: float = 0.0
var _sweep_left: float = 0.0
var _flash_left: float = 0.0
var _seed: float = 0.0


func _ready() -> void:
	layer = LAYER
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()
	EventBus.enemy_killed.connect(_on_enemy_killed)
	EventBus.wave_started.connect(_on_wave_started)


func _process(p_delta: float) -> void:
	# uniform 动画推进（raw 通道自驱；顿帧/暂停期氛围照常——Q-14 同口径）
	var fade := 0.0
	if _fade_left > 0.0:
		_fade_left = maxf(_fade_left - p_delta, 0.0)
		fade = _fade_left / BOOT_FADE_S
	var glitch := 0.0
	if _glitch_left > 0.0:
		_glitch_left = maxf(_glitch_left - p_delta, 0.0)
		glitch = clampf(_glitch_left / GLITCH_S, 0.0, 1.0)
		_seed = float(Time.get_ticks_msec() % 997) / 997.0
	var sweep_y := -1.0
	if _sweep_left > 0.0:
		_sweep_left = maxf(_sweep_left - p_delta, 0.0)
		sweep_y = 1.0 - _sweep_left / SWEEP_S
	var flash := 0.0
	if _flash_left > 0.0:
		_flash_left = maxf(_flash_left - p_delta, 0.0)
		flash = clampf(_flash_left / FLASH_S, 0.0, 1.0)
	_push(fade, glitch, sweep_y, flash)


func trigger_glitch(p_duration_s: float = GLITCH_S) -> void:
	# 签名瞬间入口（Boss 死亡；外部可复用）
	_glitch_left = maxf(_glitch_left, p_duration_s)


# ── 事件 ──────────────────────────────────────────────────────────
func _on_enemy_killed(p_enemy: Node2D) -> void:
	var tags_v: Variant = p_enemy.get("tags") if p_enemy != null else null
	var tags := int(tags_v) if tags_v != null else 0
	if (tags & GameConst.TAG_BOSS) != 0:
		trigger_glitch(GLITCH_S)                 # CRT 信号干扰 + 磷光余辉


func _on_wave_started(_p_wave: int) -> void:
	_sweep_left = SWEEP_S                     # 刷新线扫过
	_flash_left = FLASH_S                     # 屏幕轻闪


# ── 内部：单 pass shader 组装 ─────────────────────────────────────
func _build() -> void:
	_rect = ColorRect.new()
	_rect.name = "CRTScreen"
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_rect.color = Color.WHITE
	var shader := Shader.new()
	shader.code = "\
shader_type canvas_item;\n\
uniform sampler2D screen_tex : hint_screen_texture, filter_linear;\n\
uniform float scan_intensity : hint_range(0.0, 0.3) = 0.09;\n\
uniform float ca_intensity : hint_range(0.0, 0.01) = 0.0012;\n\
uniform float vignette_strength : hint_range(0.0, 1.0) = 0.38;\n\
uniform float fade : hint_range(0.0, 1.0) = 1.0;\n\
uniform float glitch : hint_range(0.0, 1.0) = 0.0;\n\
uniform float glitch_seed = 0.0;\n\
uniform float sweep_y = -1.0;\n\
uniform float flash_amount : hint_range(0.0, 1.0) = 0.0;\n\
uniform vec3 phosphor = vec3(0.486, 1.0, 0.42);\n\
\n\
float hash(float n) { return fract(sin(n) * 43758.5453); }\n\
\n\
void fragment() {\n\
\tvec2 uv = SCREEN_UV;\n\
\t// CRT 信号干扰：横向撕裂（带状 x 偏移，Boss 死亡签名瞬间）\n\
\tif (glitch > 0.001) {\n\
\t\tfloat band = floor(uv.y * 42.0 + glitch_seed * 91.0);\n\
\t\tfloat h = hash(band + glitch_seed * 17.0);\n\
\t\tfloat tear = step(0.74, h) * (h - 0.74) * 0.10 * glitch;\n\
\t\tuv.x = fract(uv.x + tear * sign(h - 0.87));\n\
\t}\n\
\t// 轻微色差（RGB 径向偏移 ≤1px；glitch 期放大）\n\
\tvec2 dir = uv - vec2(0.5);\n\
\tvec2 off = dir * ca_intensity * (1.0 + glitch * 6.0);\n\
\tvec3 col = vec3(texture(screen_tex, uv + off).r, texture(screen_tex, uv).g, texture(screen_tex, uv - off).b);\n\
\t// 磷光余辉（glitch 期绿抬升）\n\
\tcol += phosphor * 0.16 * glitch;\n\
\t// 扫描线（3px 周期，克制不干扰弹幕）\n\
\tfloat py = uv.y / SCREEN_PIXEL_SIZE.y;\n\
\tfloat scan = 0.5 + 0.5 * cos(py * 2.0943951);\n\
\tcol *= 1.0 - scan_intensity * scan;\n\
\t// 刷新线扫过（波次切换）\n\
\tif (sweep_y >= 0.0) {\n\
\t\tfloat d = abs(uv.y - sweep_y);\n\
\t\tcol += phosphor * exp(-d * 90.0) * 0.55;\n\
\t}\n\
\t// 波次轻闪\n\
\tcol += phosphor * flash_amount * 0.08;\n\
\t// CRT 暗角（边缘暗晕，不做真曲率畸变）\n\
\tfloat vig = smoothstep(1.14, 0.38, length(dir * vec2(1.12, 1.0)) * 1.4142);\n\
\tcol *= mix(1.0, vig, vignette_strength);\n\
\t// 开机式淡入（fade=1 全黑）\n\
\tcol *= (1.0 - fade);\n\
\tCOLOR = vec4(col, 1.0);\n\
}\n"
	_mat = ShaderMaterial.new()
	_mat.shader = shader
	_rect.material = _mat
	add_child(_rect)


func _push(p_fade: float, p_glitch: float, p_sweep_y: float, p_flash: float) -> void:
	if _mat == null:
		return
	_mat.set_shader_parameter(&"fade", p_fade)
	_mat.set_shader_parameter(&"glitch", p_glitch)
	_mat.set_shader_parameter(&"glitch_seed", _seed)
	_mat.set_shader_parameter(&"sweep_y", p_sweep_y)
	_mat.set_shader_parameter(&"flash_amount", p_flash)

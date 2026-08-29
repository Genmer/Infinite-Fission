# scripts/ui/menu_screen.gd
# 方向 A 主菜单屏：渐变大标题「INFINITE FISSION」+ 副题「∞ 链式裂变」+ tagline
# + 剧情三行（Lore 单源）+「启动协议」按钮。星空背景由全局 Starfield 承担（本屏只做
# 上下渐变压暗 + 内容层）。GameLoop 状态机（迁移矩阵冻结）MENU → PLAYING 唯一入口
# start_run()——本屏仅申请：start_requested 信号 → GameLoop.start_run（仲裁权在 GameLoop）。
# 可见性绑定 state_changed（仅 MENU 显示）。process_mode = ALWAYS（Q-14）。
class_name MenuScreen
extends CanvasLayer

signal start_requested()                      # → GameLoop.start_run()（MENU → PLAYING）

var _root: Control = null
var _start_btn: Button = null

const LAYER_ORDER := 20
const BTN_SIZE := Vector2(260.0, 64.0)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = LAYER_ORDER
	_build_ui()
	_root.visible = false
	EventBus.state_changed.connect(_on_state_changed)


func _on_state_changed(p_state: int) -> void:
	# 仅 MENU 态显示（PLAYING/LEVEL_UP/PAUSED/GAME_OVER 均隐藏）
	_root.visible = p_state == GameConst.GameStatus.MENU


func _build_ui() -> void:
	_root = Control.new()
	_root.name = "MenuRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UITheme.apply_theme(_root)
	add_child(_root)
	# 上下渐变压暗（星空之上、内容之下——聚焦中央标题群）
	var grad_top := _gradient_rect(Color(0.0, 0.0, 0.0, 0.55), Color(0.0, 0.0, 0.0, 0.0))
	grad_top.name = "GradTop"
	_root.add_child(grad_top)
	var grad_bottom := _gradient_rect(Color(0.0, 0.0, 0.0, 0.0), Color(0.02, 0.03, 0.08, 0.85))
	grad_bottom.name = "GradBottom"
	grad_bottom.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	grad_bottom.offset_top = -560.0
	_root.add_child(grad_bottom)
	# 渐变大标题（青白 → 深青 UV 渐变；SystemFont 加重）
	var title := Label.new()
	title.name = "Title"
	title.text = Lore.TITLE
	title.add_theme_font_override("font", UITheme.font_title())
	title.add_theme_font_size_override("font_size", Palette.FONT_HERO)
	title.add_theme_color_override("font_color", Color.WHITE)
	title.material = _title_gradient_material()
	title.set_anchors_preset(Control.PRESET_TOP_WIDE)
	title.position = Vector2(0.0, 396.0)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root.add_child(title)
	# 副题 + tagline
	var subtitle := UITheme.make_label(Lore.SUBTITLE, 22, Palette.CYAN)
	subtitle.name = "Subtitle"
	subtitle.set_anchors_preset(Control.PRESET_TOP_WIDE)
	subtitle.position = Vector2(0.0, 478.0)
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root.add_child(subtitle)
	var tagline := UITheme.make_label("DEEP-SPACE FISSION DEFENSE // SENTINEL-9", Palette.FONT_CAPTION,
		Palette.TEXT_DIM, true)
	tagline.name = "Tagline"
	tagline.set_anchors_preset(Control.PRESET_TOP_WIDE)
	tagline.position = Vector2(0.0, 516.0)
	tagline.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root.add_child(tagline)
	# 分隔线（微光）
	var divider := ColorRect.new()
	divider.name = "Divider"
	divider.color = Color(Palette.CYAN, 0.35)
	divider.position = Vector2(220.0, 560.0)
	divider.size = Vector2(280.0, 1.0)
	divider.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(divider)
	# 剧情 lore 三行（弱化色，行距 30）
	for i in range(Lore.MENU_LORE.size()):
		var line := UITheme.make_label(Lore.MENU_LORE[i], Palette.FONT_BODY, Palette.TEXT_DIM)
		line.name = "LoreLine%d" % i
		line.set_anchors_preset(Control.PRESET_TOP_WIDE)
		line.position = Vector2(0.0, 592.0 + 30.0 * float(i))
		line.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_root.add_child(line)
	# 启动协议按钮（主题四态 + 青色 focus 观感由 theme 承担）
	_start_btn = Button.new()
	_start_btn.name = "StartButton"
	_start_btn.text = Lore.MENU_START
	_start_btn.add_theme_font_size_override("font_size", 20)
	_start_btn.position = Vector2(360.0 - BTN_SIZE.x * 0.5, 740.0)
	_start_btn.size = BTN_SIZE
	_start_btn.pressed.connect(_on_start_pressed)
	_root.add_child(_start_btn)
	# 底部注释
	var hint := UITheme.make_label("2087 · 深空裂变堆「普罗米修斯-9」", Palette.FONT_CAPTION,
		Color(Palette.TEXT_DIM, 0.7))
	hint.name = "BottomHint"
	hint.set_anchors_preset(Control.PRESET_TOP_WIDE)
	hint.position = Vector2(0.0, 1196.0)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root.add_child(hint)


func _on_start_pressed() -> void:
	start_requested.emit()


func is_menu_visible() -> bool:
	# 测试观测口
	return _root != null and _root.visible


# ── 组装支撑 ─────────────────────────────────────────────────────
func _gradient_rect(p_top: Color, p_bottom: Color) -> TextureRect:
	# 竖向渐变矩形（GradientTexture2D 程序化；顶部全宽 560 高）
	var rect := TextureRect.new()
	var grad := Gradient.new()
	grad.colors = PackedColorArray([p_top, p_bottom])
	grad.offsets = PackedFloat32Array([0.0, 1.0])
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill_from = Vector2(0.0, 0.0)
	tex.fill_to = Vector2(0.0, 1.0)
	rect.texture = tex
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.set_anchors_preset(Control.PRESET_TOP_WIDE)
	rect.offset_bottom = 560.0
	return rect


static func _title_gradient_material() -> ShaderMaterial:
	# 标题 UV 纵向渐变（乘字体 alpha——霓虹双色标题）
	var shader := Shader.new()
	shader.code = "\
shader_type canvas_item;\n\
uniform vec4 top_color : source_color = vec4(0.95, 1.0, 1.0, 1.0);\n\
uniform vec4 bottom_color : source_color = vec4(0.10, 0.55, 0.80, 1.0);\n\
void fragment() {\n\
\tvec4 tex = COLOR;\n\
\ttex.rgb = mix(top_color.rgb, bottom_color.rgb, UV.y);\n\
\tCOLOR = tex;\n\
}\n"
	var mat := ShaderMaterial.new()
	mat.shader = shader
	return mat

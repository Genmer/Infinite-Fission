# scripts/ui/theme.gd
# 终端风 Theme 工厂（方向 B：直角/2px 圆角、1px 描边框、无渐变；等宽正文 + 宽字重标题）。
# 全部静态惰性构建 + 缓存；无外部资源（SystemFont 走系统等宽族，headless 安全）。
class_name TerminalTheme
extends RefCounted

static var _mono: SystemFont = null
static var _theme: Theme = null

# 字号阶梯（终端层级）
const SIZE_HEADER := 40                       # 标题（SENTINEL-9）
const SIZE_SECTION := 24                      # 区块标题/按钮
const SIZE_BODY := 15                         # 正文
const SIZE_LOG := 14                          # 启动日志/注脚
const SIZE_MONSTER := 13                      # 弱化注脚


static func mono_font() -> SystemFont:
	# 等宽族（防御终端感）；macOS/win/linux 常见等宽族依次回退
	if _mono == null:
		_mono = SystemFont.new()
		_mono.font_names = ["Menlo", "Consolas", "DejaVu Sans Mono", "Courier New", "monospace"]
	return _mono


static func theme() -> Theme:
	# 终端 Theme 单例：默认等宽字体 + 磷光正文色 + [方括号]按钮三态
	if _theme != null:
		return _theme
	var t := Theme.new()
	t.default_font = mono_font()
	t.default_font_size = SIZE_BODY
	# Label：正文磷光绿
	t.set_color(&"font_color", &"Label", Palette.TEXT_BODY)
	# Button：直角描边框三态（无渐变）
	t.set_stylebox(&"normal", &"Button", button_box(Palette.PHOS, 0.9, Palette.BG, false))
	t.set_stylebox(&"hover", &"Button", button_box(Palette.AMBER, 1.0, Color(0.04, 0.10, 0.04), false))
	t.set_stylebox(&"pressed", &"Button", button_box(Palette.PHOS, 1.0, Palette.PHOS.darkened(0.72), true))
	t.set_stylebox(&"disabled", &"Button", button_box(Palette.TEXT_DIM, 0.5, Palette.BG, false))
	t.set_stylebox(&"focus", &"Button", StyleBoxEmpty.new())
	t.set_color(&"font_color", &"Button", Palette.PHOS)
	t.set_color(&"font_hover_color", &"Button", Palette.AMBER)
	t.set_color(&"font_pressed_color", &"Button", Palette.PHOS)
	t.set_color(&"font_disabled_color", &"Button", Palette.TEXT_DIM)
	t.set_font_size(&"font_size", &"Button", SIZE_SECTION)
	_theme = t
	return _theme


static func button_box(p_border: Color, p_border_alpha: float, p_bg: Color, p_inverted: bool) -> StyleBoxFlat:
	# 描边框（1px；pressed 反白填充）——直角终端风
	var box := StyleBoxFlat.new()
	box.bg_color = p_bg
	box.border_color = Color(p_border.r, p_border.g, p_border.b, p_border_alpha)
	box.set_border_width_all(1)
	box.set_corner_radius_all(2)                 # 直角或 2px 圆角（派发单 §UI 重设计）
	box.content_margin_left = 18.0
	box.content_margin_right = 18.0
	box.content_margin_top = 10.0
	box.content_margin_bottom = 10.0
	if p_inverted:
		box.bg_color = p_border.darkened(0.55)
	return box


static func panel_box(p_border: Color, p_bg: Color = Color(0.016, 0.032, 0.016, 0.88)) -> StyleBoxFlat:
	# 终端面板框（卡片/结算面板用）
	var box := StyleBoxFlat.new()
	box.bg_color = p_bg
	box.border_color = p_border
	box.set_border_width_all(1)
	box.set_corner_radius_all(2)
	box.content_margin_left = 14.0
	box.content_margin_right = 14.0
	box.content_margin_top = 10.0
	box.content_margin_bottom = 10.0
	return box


static func bracket(p_text: String) -> String:
	# [ 方括号风格 ] 按钮文案包装
	return "[ %s ]" % p_text

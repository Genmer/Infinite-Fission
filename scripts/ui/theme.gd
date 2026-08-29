# scripts/ui/theme.gd
# 终端风 Theme 工厂（方向 B：直角/2px 圆角、1px 描边框、无渐变；等宽正文 + 宽字重标题）。
# 全部静态惰性构建 + 缓存；无外部资源（SystemFont 走系统等宽族，headless 安全）。
# 可读性 pass（试玩反馈「字体太细看不清」）：SystemFont 显式 font_weight（正文 700/标题 800）
# + 字号下限（正文/数值≥17、注脚≥14、标题≥30）+ Label 默认深色描边把字从扫描线上顶出来
# + 磷光微辉（shadow 当 bloom 用，CRT 氛围层已让位到 UI 层之下，UI 靠此保持终端质感）。
class_name TerminalTheme
extends RefCounted

static var _mono: SystemFont = null
static var _mono_title: SystemFont = null
static var _theme: Theme = null

# UI CanvasLayer 层号：CRT 氛围层（LAYER=4，世界之上）之下不压 UI；BootErrorScreen(100) 之下
const UI_LAYER := 10

# 字号阶梯（终端层级；可读性下限：正文/数值≥17px、注脚≥14px、标题≥30px）
const SIZE_HEADER := 40                       # 标题（SENTINEL-9）
const SIZE_SECTION := 24                      # 区块标题/按钮
const SIZE_KEY := 30                          # 关键时刻行（波次 toast/选卡标题/Boss 预警）
const SIZE_STATE := 34                        # 全屏状态提示（LEVEL UP/PAUSED/GAME OVER）
const SIZE_BODY := 18                         # 正文/数值
const SIZE_LOG := 15                          # 启动日志/注脚
const SIZE_MONSTER := 14                      # 弱化注脚（真正次要信息专用）
const OUTLINE_BODY := 4                       # 正文描边粗细（深色近黑）
const OUTLINE_KEY := 6                        # 关键时刻描边粗细


static func mono_font() -> SystemFont:
	# 等宽族（防御终端感）；macOS/win/linux 常见等宽族依次回退
	# font_weight=700：细字重 × 扫描线是「看不清」根因，全项目正文锁粗一档
	if _mono == null:
		_mono = SystemFont.new()
		_mono.font_names = ["Menlo", "Consolas", "DejaVu Sans Mono", "Courier New", "monospace"]
		_mono.font_weight = 700
	return _mono


static func title_font() -> SystemFont:
	# 标题族（同族再重一档 800，仅 ≥30px 的标题/状态提示用）
	if _mono_title == null:
		_mono_title = SystemFont.new()
		_mono_title.font_names = ["Menlo", "Consolas", "DejaVu Sans Mono", "Courier New", "monospace"]
		_mono_title.font_weight = 800
	return _mono_title


static func theme() -> Theme:
	# 终端 Theme 单例：默认等宽粗体 + 磷光正文色 + 深色描边/磷光微辉 + [方括号]按钮三态
	if _theme != null:
		return _theme
	var t := Theme.new()
	t.default_font = mono_font()
	t.default_font_size = SIZE_BODY
	# Label：正文磷光绿 + 近黑描边（扫描线上顶出文字）+ 磷光微辉（shadow 零偏移当 bloom）
	t.set_color(&"font_color", &"Label", Palette.TEXT_BODY)
	t.set_color(&"font_outline_color", &"Label", Palette.BG)
	t.set_constant(&"outline_size", &"Label", OUTLINE_BODY)
	t.set_color(&"font_shadow_color", &"Label", Color(Palette.PHOS.r, Palette.PHOS.g, Palette.PHOS.b, 0.16))
	t.set_constant(&"shadow_offset_x", &"Label", 0)
	t.set_constant(&"shadow_offset_y", &"Label", 0)
	t.set_constant(&"shadow_outline_size", &"Label", 4)
	# Button：直角描边框三态（无渐变）+ 文字同款近黑描边
	t.set_stylebox(&"normal", &"Button", button_box(Palette.PHOS, 0.9, Palette.BG, false))
	t.set_stylebox(&"hover", &"Button", button_box(Palette.AMBER, 1.0, Color(0.04, 0.10, 0.04), false))
	t.set_stylebox(&"pressed", &"Button", button_box(Palette.PHOS, 1.0, Palette.PHOS.darkened(0.72), true))
	t.set_stylebox(&"disabled", &"Button", button_box(Palette.TEXT_DIM, 0.5, Palette.BG, false))
	t.set_stylebox(&"focus", &"Button", StyleBoxEmpty.new())
	t.set_color(&"font_color", &"Button", Palette.PHOS)
	t.set_color(&"font_hover_color", &"Button", Palette.AMBER)
	t.set_color(&"font_pressed_color", &"Button", Palette.PHOS)
	t.set_color(&"font_disabled_color", &"Button", Palette.TEXT_DIM)
	t.set_color(&"font_outline_color", &"Button", Palette.BG)
	t.set_constant(&"outline_size", &"Button", OUTLINE_BODY)
	t.set_font_size(&"font_size", &"Button", SIZE_SECTION)
	_theme = t
	return _theme


static func style_key_label(p_label: Label) -> void:
	# 关键时刻文字加强（状态提示/toast/预警/Boss 名/标题）：再粗再大一圈描边
	p_label.add_theme_font_override("font", title_font())
	p_label.add_theme_constant_override("outline_size", OUTLINE_KEY)


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

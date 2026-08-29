# scripts/ui/theme.gd
# 方向 A 程序化 UI 主题（深空霓虹）：SystemFont 中文黑体 + StyleBoxFlat 玻璃面板/按钮/
# 进度条全复用。单实例静态缓存——全部界面共享同一 Theme（运行期零构建）。
# 字号/圆角/描边取色一律走 Palette（色彩单源）。class_name 用 UITheme 避让内建 Theme。
class_name UITheme
extends RefCounted

const CORNER_RADIUS := 12                     # 面板圆角（视觉单）
const BTN_CORNER := 10
const BTN_MIN_SIZE := Vector2(220.0, 56.0)

static var _theme: Theme = null               # 单实例
static var _font_body: SystemFont = null      # 中文黑体（正文）
static var _font_mono: SystemFont = null      # 等宽（数值）
static var _font_title: SystemFont = null     # 黑体加重（大标题/横幅）


# ── 字体 ─────────────────────────────────────────────────────────
# 硬性要求（方向 B 实测教训）：全项目 font_weight ≥ 600、标题 800——细字不可读。
static func font_body() -> SystemFont:
	# 系统中文黑体（跨平台名链兜底；headless 构建安全——无渲染依赖）
	if _font_body == null:
		_font_body = SystemFont.new()
		_font_body.font_names = ["PingFang SC", "Hiragino Sans GB", "Heiti SC",
			"Microsoft YaHei", "Noto Sans CJK SC", "sans-serif"]
		_font_body.font_weight = 600
	return _font_body


static func font_mono() -> SystemFont:
	# 等宽数值字体（同字重底线）
	if _font_mono == null:
		_font_mono = SystemFont.new()
		_font_mono.font_names = ["SF Mono", "Menlo", "Monaco", "Consolas", "monospace"]
		_font_mono.font_weight = 600
	return _font_mono


static func font_title() -> SystemFont:
	# 标题加重字重（大标题/横幅/跳字宿主）
	if _font_title == null:
		_font_title = SystemFont.new()
		_font_title.font_names = font_body().font_names
		_font_title.font_weight = 800
	return _font_title


# ── 主题（单实例） ───────────────────────────────────────────────
static func theme() -> Theme:
	if _theme != null:
		return _theme
	var t := Theme.new()
	t.default_font = font_body()
	t.default_font_size = Palette.FONT_BODY
	# Button 四态
	t.set_stylebox("normal", "Button", _btn_style(Palette.PANEL_GLASS, Palette.PANEL_EDGE, 1.0))
	t.set_stylebox("hover", "Button", _btn_style(Palette.PANEL_GLASS.lightened(0.06), Palette.CYAN, 1.4))
	t.set_stylebox("pressed", "Button", _btn_style(Palette.PANEL_GLASS.darkened(0.15), Palette.CYAN, 2.0))
	t.set_stylebox("disabled", "Button", _btn_style(Color(Palette.PANEL_GLASS, 0.5), Palette.PANEL_EDGE, 1.0))
	t.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	t.set_color("font_color", "Button", Palette.TEXT_MAIN)
	t.set_color("font_hover_color", "Button", Palette.CYAN)
	t.set_color("font_pressed_color", "Button", Palette.CYAN)
	t.set_color("font_disabled_color", "Button", Palette.TEXT_DIM)
	t.set_font_size("font_size", "Button", Palette.FONT_BODY)
	# Panel（玻璃面板复用件）
	t.set_stylebox("panel", "Panel", panel_style())
	# Label 默认
	t.set_color("font_color", "Label", Palette.TEXT_MAIN)
	t.set_font_size("font_size", "Label", Palette.FONT_BODY)
	# ProgressBar（主题兜底；主 HUD 用 TextureProgressBar 自绘）
	t.set_stylebox("background", "ProgressBar", _glass_style(Color(Palette.PANEL_GLASS, 0.9)))
	t.set_stylebox("fill", "ProgressBar", _glass_style(Palette.CYAN.darkened(0.2)))
	_theme = t
	return _theme


# ── StyleBox 工厂（复用件） ──────────────────────────────────────
static func panel_style() -> StyleBoxFlat:
	# 玻璃面板：深底 + 描边 + 圆角 12 + 微阴影
	var sb := _glass_style(Palette.PANEL_GLASS)
	sb.border_color = Palette.PANEL_EDGE
	return sb


static func panel_accent_style(p_accent: Color) -> StyleBoxFlat:
	# 强调面板：描边换语义色（稀有度框/警报）
	var sb := _glass_style(Palette.PANEL_GLASS.lightened(0.03))
	sb.border_color = p_accent
	sb.set_border_width_all(2)
	sb.shadow_color = Color(p_accent, 0.25)
	sb.shadow_size = 6
	return sb


static func _btn_style(p_bg: Color, p_border: Color, p_border_w: float) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = p_bg
	sb.set_corner_radius_all(BTN_CORNER)
	sb.set_border_width_all(int(ceilf(p_border_w)))
	sb.border_color = p_border
	sb.content_margin_left = 24.0
	sb.content_margin_right = 24.0
	sb.content_margin_top = 12.0
	sb.content_margin_bottom = 12.0
	return sb


static func _glass_style(p_bg: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = p_bg
	sb.set_corner_radius_all(CORNER_RADIUS)
	sb.set_border_width_all(1)
	sb.shadow_color = Palette.PANEL_SHADOW
	sb.shadow_size = 4
	return sb


# ── 快捷组装件 ───────────────────────────────────────────────────
static func apply_theme(p_control: Control) -> void:
	# 根控件挂主题（子树全继承）
	p_control.theme = theme()


static func make_label(p_text: String, p_size: int, p_color: Color = Palette.TEXT_MAIN,
		p_mono: bool = false, p_outline: bool = true) -> Label:
	# 统一 Label 组装（字号/色/等宽开关；默认深色描边——游戏内文字可读性硬性要求）
	var label := Label.new()
	label.text = p_text
	label.add_theme_font_size_override("font_size", p_size)
	label.add_theme_color_override("font_color", p_color)
	if p_mono:
		label.add_theme_font_override("font", font_mono())
	if p_outline:
		label.add_theme_color_override("font_outline_color", Palette.OUTLINE_COLOR)
		label.add_theme_constant_override("outline_size", Palette.OUTLINE_SIZE)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


static func make_glass_panel(p_accent: Color = Palette.PANEL_EDGE) -> Panel:
	var panel := Panel.new()
	panel.add_theme_stylebox_override("panel", panel_accent_style(p_accent))
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return panel

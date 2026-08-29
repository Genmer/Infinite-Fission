# scripts/ui/theme.gd
# 方向 C「晴空糖果」贴纸风主题（美术派发单）：
# 白圆角面板（纯白 + 藏青描边 3px + 底部厚投影）+ 按下下沉变暗 + SystemFont 中文黑体。
# 附果冻感工具（squash & stretch 出现 / 脉动 / 下沉 punch）——重要 UI 元素出现时统一入口。
# 全静态：Theme/字体/StyleBox 惰性缓存共享；Tween 由调用方节点持有（生命周期随节点）。
class_name StickerTheme
extends RefCounted

static var _theme: Theme = null
static var _font: SystemFont = null
static var _font_bold: SystemFont = null
static var _btn_styles: Dictionary = {}       # name -> StyleBoxFlat（按钮四态）


# ── 字体 ──────────────────────────────────────────────────────────
static func font() -> SystemFont:
	# 系统中文黑体（圆角感；字重 700——用户实测反馈：亮底风格禁细字，全局粗体基调）
	if _font == null:
		_font = SystemFont.new()
		_font.font_names = PackedStringArray(["PingFang SC", "Hiragino Sans GB",
			"Microsoft YaHei", "Source Han Sans SC", "Noto Sans CJK SC", "sans-serif"])
		_font.font_weight = 700
	return _font


static func font_bold() -> SystemFont:
	# 标题特重档（≥700 基调上的再加重意图——与 font() 同为 700，语义位区分保留）
	if _font_bold == null:
		_font_bold = SystemFont.new()
		_font_bold.font_names = font().font_names
		_font_bold.font_weight = 700
	return _font_bold


# ── Theme（CanvasLayer 根 Control 挂载，子控件继承） ────────────────
static func theme() -> Theme:
	if _theme != null:
		return _theme
	var t := Theme.new()
	t.default_font = font()
	t.default_font_size = 18                   # 正文下限（用户实测：粗且大）
	for style_name in ["normal", "hover", "pressed", "disabled"]:
		t.set_stylebox(style_name, "Button", button_style(style_name))
	t.set_color("font_color", "Button", PopPalette.INK)
	t.set_color("font_hover_color", "Button", PopPalette.INK)
	t.set_color("font_pressed_color", "Button", PopPalette.INK)
	t.set_color("font_disabled_color", "Button", PopPalette.INK_SOFT)
	t.set_color("font_color", "Label", PopPalette.INK)
	t.set_constant("outline_size", "Label", 0)
	_theme = t
	return _theme


static func button_style(p_state: String) -> StyleBoxFlat:
	# 贴纸按钮四态：normal/hover 白底厚投影；pressed 下沉变暗（投影收起）；disabled 灰化
	if _btn_styles.has(p_state):
		return _btn_styles[p_state] as StyleBoxFlat
	var sb := StyleBoxFlat.new()
	sb.bg_color = PopPalette.PANEL
	sb.border_color = PopPalette.OUTLINE
	sb.set_border_width_all(3)
	sb.set_corner_radius_all(20)
	sb.content_margin_left = 18.0
	sb.content_margin_right = 18.0
	sb.content_margin_top = 10.0
	sb.content_margin_bottom = 12.0
	match p_state:
		"hover":
			sb.shadow_color = Color(PopPalette.OUTLINE.r, PopPalette.OUTLINE.g, PopPalette.OUTLINE.b, 0.38)
			sb.shadow_size = 8
			sb.shadow_offset = Vector2(0.0, 5.0)
		"pressed":
			sb.bg_color = PopPalette.PANEL_PRESS
			sb.shadow_color = Color(PopPalette.OUTLINE.r, PopPalette.OUTLINE.g, PopPalette.OUTLINE.b, 0.18)
			sb.shadow_size = 2
			sb.shadow_offset = Vector2(0.0, 1.0)
			sb.content_margin_top = 12.0
			sb.content_margin_bottom = 10.0
		"disabled":
			sb.bg_color = Color(0.96, 0.97, 1.0)
			sb.border_color = PopPalette.INK_SOFT
			sb.shadow_size = 0
		_:
			sb.shadow_color = Color(PopPalette.OUTLINE.r, PopPalette.OUTLINE.g, PopPalette.OUTLINE.b, 0.32)
			sb.shadow_size = 7
			sb.shadow_offset = Vector2(0.0, 4.0)
	_btn_styles[p_state] = sb
	return sb


static func panel_style(p_radius: float = 20.0, p_border: int = 3, p_shadow: bool = true) -> StyleBoxFlat:
	# 贴纸面板：白底 + 藏青描边 + 底部厚投影（每次新实例——调用方独占改色/改角）
	var sb := StyleBoxFlat.new()
	sb.bg_color = PopPalette.PANEL
	sb.border_color = PopPalette.OUTLINE
	sb.set_border_width_all(p_border)
	sb.set_corner_radius_all(int(p_radius))
	if p_shadow:
		sb.shadow_color = Color(PopPalette.OUTLINE.r, PopPalette.OUTLINE.g, PopPalette.OUTLINE.b, 0.3)
		sb.shadow_size = 8
		sb.shadow_offset = Vector2(0.0, 5.0)
	return sb


# ── 果冻感工具（squash & stretch 全局口径） ────────────────────────
static func squash_pop(p_node: Control, p_delay: float = 0.0) -> void:
	# 出现：横向先胖后收的果冻弹跳（0.34s，TRANS_BACK 回弹）
	if p_node == null:
		return
	p_node.pivot_offset = p_node.size * 0.5
	p_node.scale = Vector2(0.4, 0.25)
	var tw := p_node.create_tween()
	if p_delay > 0.0:
		tw.tween_interval(p_delay)
		p_node.modulate.a = 0.0
		tw.parallel().tween_property(p_node, "modulate:a", 1.0, 0.12)
	tw.tween_property(p_node, "scale", Vector2(1.12, 0.86), 0.14) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(p_node, "scale", Vector2(0.95, 1.05), 0.09)
	tw.tween_property(p_node, "scale", Vector2.ONE, 0.11)


static func pulse(p_node: Control, p_period: float = 1.1, p_amount: float = 0.05) -> Tween:
	# 果冻脉动循环（出发！按钮；返回 Tween 供宿主管理）
	if p_node == null:
		return null
	p_node.pivot_offset = p_node.size * 0.5
	var tw := p_node.create_tween().set_loops()
	tw.tween_property(p_node, "scale", Vector2(1.0 + p_amount, 1.0 - p_amount * 0.6), p_period * 0.5) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.tween_property(p_node, "scale", Vector2(1.0 - p_amount * 0.5, 1.0 + p_amount * 0.4), p_period * 0.5) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	return tw


static func press_punch(p_node: Control) -> void:
	# 按下 punch（下沉弹回；按钮 pressed 反馈的补充动效）
	if p_node == null:
		return
	p_node.pivot_offset = p_node.size * 0.5
	var tw := p_node.create_tween()
	tw.tween_property(p_node, "scale", Vector2(0.9, 0.94), 0.05)
	tw.tween_property(p_node, "scale", Vector2.ONE, 0.16) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


static func label_sticker(p_label: Label, p_size: int, p_fill: Color = PopPalette.INK,
		p_outline: int = 0, p_outline_color: Color = Color.WHITE, p_bold: bool = false) -> Label:
	# 贴纸文字统一装配（字号/描边/字色/字重——跳字、标题、徽章共用口径）
	if p_label == null:
		return p_label
	p_label.add_theme_font_override("font", font_bold() if p_bold else font())
	p_label.add_theme_font_size_override("font_size", p_size)
	p_label.add_theme_color_override("font_color", p_fill)
	if p_outline > 0:
		p_label.add_theme_constant_override("outline_size", p_outline)
		p_label.add_theme_color_override("font_outline_color", p_outline_color)
	p_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return p_label

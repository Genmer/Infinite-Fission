# scripts/cards/card_select_ui.gd
# M-17 CardSelectUI（架构 §2.16）：选卡界面。
# 方向 A 重做：稀有度色框（玻璃面板 + 语义色描边）+ 微光呼吸 + 程序化类型图标
# （ADD 菱形 / MULT 三角 / MECH 六边 / ELEM 圆环；MASTERY 三角 / RELIC 圆环）
# + 稀有度层级点 + 按压缩放消失过渡（仅按钮路径；choose() 直调零延迟——测试口径不变）。
# process_mode = ALWAYS（tree.paused 冻结战斗时界面可用，AC-16.2）；仅 LEVEL_UP 状态可见。
# open()：GameLoop 仲裁后调用（E-16：死亡优先，GameOver 丢弃升级请求）；choice_made →
# CardGenerator.apply_choice → EventBus.emit_card_chosen → close() 请求恢复 → GameLoop 回 PLAYING。
class_name CardSelectUI
extends CanvasLayer

signal choice_made(card: Dictionary)          # → CardGenerator.apply_choice → card_chosen 事件

var is_open: bool = false                     # 界面可见状态（GameLoop 状态联动）

var _root: Control = null
var _buttons: Array[Button] = []
var _cards: Array[Dictionary] = []            # 当前货架（open 注入）
var _title: Label = null
var _glows: Array[ColorRect] = []             # 微光呼吸条（逐卡）

const LAYER_ORDER := 30
const CARD_SIZE := Vector2(600.0, 160.0)
const CARD_X := 60.0
const CARD_Y0 := 372.0
const CARD_STEP := 184.0
const PICK_TWEEN_S := 0.16

# PoolClass → 图标形（ADD 菱形 / MULT 三角 / LOCAL 菱形 / MECH 六边 / ELEM 圆环）
const POOL_ICONS := {0: 0, 1: 1, 2: 0, 3: 3, 4: 2}   # icon 形枚举见 IconCanvas.Shape


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = LAYER_ORDER
	_build_ui()
	_root.visible = false                     # 初始隐藏（仅 LEVEL_UP 态 open() 显示）


func open(p_candidates: Array[Dictionary]) -> void:
	# 展示三选一货架（candidates 由 CardGenerator.generate_candidates 产出）
	_cards = p_candidates
	for i in range(_buttons.size()):
		var card: Dictionary = _cards[i] if i < _cards.size() else {}
		_setup_button(_buttons[i], _glows[i], card)
		# REL_GAMBLER 四选一：按钮 4 仅在货架 ≥4 张时可见（三选一时隐藏占位）
		_buttons[i].visible = i < _cards.size()
		_glows[i].visible = i < _cards.size()
		_reset_card_transform(_buttons[i])
	_root.visible = true
	is_open = true


func close() -> void:
	# 选卡完成收起（GameLoop 切回 PLAYING 时调用）
	_root.visible = false
	is_open = false
	_cards = []


func choose(p_index: int) -> void:
	# 选择入口（按钮 pressed / 测试直调）；无效索引忽略
	if not is_open or p_index < 0 or p_index >= _cards.size():
		return
	var card := _cards[p_index]
	choice_made.emit(card)


func candidate_count() -> int:
	# 测试观测口
	return _cards.size()


func _on_pressed(p_index: int) -> void:
	# 按钮路径：缩放消失过渡（PROCESS 通道——tree.paused 期间照常）→ choose
	if not is_open or p_index < 0 or p_index >= _buttons.size():
		return
	var btn := _buttons[p_index]
	var tween := btn.create_tween()
	tween.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	tween.tween_property(btn, "scale", Vector2(1.05, 1.05), PICK_TWEEN_S * 0.4) \
		.set_trans(Tween.TRANS_SINE)
	tween.tween_property(btn, "scale", Vector2(0.9, 0.9), PICK_TWEEN_S * 0.6) \
		.set_trans(Tween.TRANS_SINE)
	tween.parallel().tween_property(btn, "modulate:a", 0.25, PICK_TWEEN_S * 0.6)
	tween.tween_callback(choose.bind(p_index))


func _setup_button(p_btn: Button, p_glow: ColorRect, p_card: Dictionary) -> void:
	# 卡面（稀有度色框 + 图标 + 名称/描述/层级点）——子控件在 _build_ui 预建，此处刷新
	if p_card.is_empty():
		p_btn.text = "-"
		p_btn.disabled = true
		return
	p_btn.disabled = false
	var kind := int(p_card.get("kind", 3))
	var rarity := int(p_card.get("rarity", 0))
	var accent := Palette.rarity_color(rarity)
	# 稀有度色框（normal/hover/pressed 三态同 accent，强度递进）
	p_btn.add_theme_stylebox_override("normal", UITheme.panel_accent_style(accent))
	var hover := UITheme.panel_accent_style(accent)
	hover.bg_color = Palette.PANEL_GLASS.lightened(0.08)
	p_btn.add_theme_stylebox_override("hover", hover)
	var pressed := UITheme.panel_accent_style(accent)
	pressed.bg_color = Palette.PANEL_GLASS.darkened(0.12)
	p_btn.add_theme_stylebox_override("pressed", pressed)
	# 微光呼吸条（稀有度 accent；_process 驱动）
	p_glow.color = Color(accent, 0.18)
	# 文本（名称/类别行/描述）
	var kind_name: String = ["精通", "词条", "遗物", "保底"][clampi(kind, 0, 3)]
	var title: Label = p_btn.get_node_or_null("Title") as Label
	var kindline: Label = p_btn.get_node_or_null("KindLine") as Label
	var desc: Label = p_btn.get_node_or_null("Desc") as Label
	var icon: IconCanvas = p_btn.get_node_or_null("Icon") as IconCanvas
	var pips: IconCanvas = p_btn.get_node_or_null("Pips") as IconCanvas
	if title != null:
		title.text = String(p_card.get("display_name", ""))
		title.add_theme_color_override("font_color", accent)
	if kindline != null:
		kindline.text = "[%s]" % kind_name
	if desc != null:
		desc.text = String(p_card.get("description", ""))
	if icon != null:
		icon.setup(_icon_shape_for(p_card), accent)
	if pips != null:
		pips.setup(IconCanvas.Shape.PIPS, accent, clampi(rarity + 1, 1, 4))


func _icon_shape_for(p_card: Dictionary) -> int:
	# 类型图标映射：词条按 PoolClass（ADD 菱形/MULT 三角/MECH 六边/ELEM 圆环）；
	# 非词条卡复用形状语义（精通=三角 / 遗物=圆环 / 保底=菱形）
	var kind := int(p_card.get("kind", 3))
	match kind:
		0:
			return IconCanvas.Shape.TRIANGLE    # 精通（升级三角）
		2:
			return IconCanvas.Shape.RING        # 遗物
		3:
			return IconCanvas.Shape.DIAMOND     # 保底
		_:
			var data: Variant = p_card.get("data", null)
			var pool := -1
			if data != null and (data as Object).get("pool") != null:
				pool = int((data as Object).get("pool"))
			return int(POOL_ICONS.get(pool, IconCanvas.Shape.DIAMOND))


func _reset_card_transform(p_btn: Button) -> void:
	# 过渡复位（重开货架/翻卡态清理）
	p_btn.scale = Vector2.ONE
	p_btn.modulate.a = 1.0
	p_btn.pivot_offset = CARD_SIZE * 0.5


func _build_ui() -> void:
	# 程序化卡面组装（720×1280 竖屏中带）
	_root = Control.new()
	_root.name = "CardSelectRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UITheme.apply_theme(_root)
	add_child(_root)
	var dim := ColorRect.new()
	dim.name = "Dim"
	dim.color = Color(0.02, 0.03, 0.07, 0.88)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(dim)
	_title = UITheme.make_label("升级协议 · 选择一项强化", Palette.FONT_TITLE, Palette.CYAN)
	_title.name = "Title"
	_title.add_theme_font_override("font", UITheme.font_title())
	_title.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_title.position = Vector2(0.0, 308.0)
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root.add_child(_title)
	# 4 卡槽位（REL_GAMBLER 四选一上限；open() 按货架数显隐——三选一时第 4 槽隐藏）
	for i in range(4):
		var y := CARD_Y0 + CARD_STEP * float(i)
		# 微光呼吸条（卡后层，略大——accent 微光）
		var glow := ColorRect.new()
		glow.name = "Glow%d" % i
		glow.position = Vector2(CARD_X - 6.0, y - 6.0)
		glow.size = CARD_SIZE + Vector2(12.0, 12.0)
		glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
		glow.material = TextureFactory.mat_add_pulse()
		_root.add_child(glow)
		_glows.append(glow)
		var btn := Button.new()
		btn.name = "Card%d" % i
		btn.position = Vector2(CARD_X, y)
		btn.size = CARD_SIZE
		btn.pivot_offset = CARD_SIZE * 0.5
		btn.pressed.connect(_on_pressed.bind(i))
		_root.add_child(btn)
		_buttons.append(btn)
		# 卡面子控件（图标 + 名称 + 类别 + 描述 + 层级点）
		var icon := IconCanvas.new()
		icon.name = "Icon"
		icon.position = Vector2(24.0, 44.0)
		icon.size = Vector2(72.0, 72.0)
		btn.add_child(icon)
		var title := UITheme.make_label("", 20, Palette.TEXT_MAIN)
		title.name = "Title"
		title.position = Vector2(112.0, 20.0)
		title.size = Vector2(400.0, 32.0)
		btn.add_child(title)
		var kindline := UITheme.make_label("", Palette.FONT_CAPTION, Palette.TEXT_DIM, true)
		kindline.name = "KindLine"
		kindline.position = Vector2(112.0, 56.0)
		kindline.size = Vector2(200.0, 20.0)
		btn.add_child(kindline)
		var desc := UITheme.make_label("", Palette.FONT_BODY, Palette.TEXT_DIM)
		desc.name = "Desc"
		desc.position = Vector2(112.0, 80.0)
		desc.size = Vector2(460.0, 72.0)
		desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		btn.add_child(desc)
		var pips := IconCanvas.new()
		pips.name = "Pips"
		pips.position = Vector2(536.0, 26.0)
		pips.size = Vector2(48.0, 16.0)
		btn.add_child(pips)


func _process(_p_delta: float) -> void:
	# 微光呼吸（accent 条 alpha 脉动——PROCESS 通道，LEVEL_UP 暂停期照常）
	var t := Time.get_ticks_msec() / 1000.0
	for glow in _glows:
		if glow.visible:
			var base := glow.color
			base.a = 0.10 + 0.10 * (0.5 + 0.5 * sin(t * 2.6))
			glow.color = base


# 程序化类型图标（矢量描边 + 半透明填充——霓虹统一语言；层级点复用画布）
class IconCanvas:
	extends Control

	enum Shape { DIAMOND, TRIANGLE, HEX, RING, PIPS }

	var _shape: int = Shape.DIAMOND
	var _color: Color = Palette.CYAN
	var _count: int = 1                          # PIPS 用（稀有度层级点数）

	func setup(p_shape: int, p_color: Color, p_count: int = 1) -> void:
		_shape = p_shape
		_color = p_color
		_count = maxi(p_count, 1)
		queue_redraw()

	func _draw() -> void:
		var c := size * 0.5
		var r := minf(size.x, size.y) * 0.42
		var fill := Color(_color, 0.20)
		match _shape:
			Shape.DIAMOND:
				var pts := PackedVector2Array([
					Vector2(c.x, c.y - r), Vector2(c.x + r, c.y),
					Vector2(c.x, c.y + r), Vector2(c.x - r, c.y),
				])
				draw_colored_polygon(pts, fill)
				draw_polyline(pts + PackedVector2Array([pts[0]]), _color, 2.0, true)
			Shape.TRIANGLE:
				var pts := _ngon(3, r, -PI / 2.0)
				draw_colored_polygon(pts, fill)
				draw_polyline(pts + PackedVector2Array([pts[0]]), _color, 2.0, true)
			Shape.HEX:
				var pts := _ngon(6, r, PI / 6.0)
				draw_colored_polygon(pts, fill)
				draw_polyline(pts + PackedVector2Array([pts[0]]), _color, 2.0, true)
			Shape.RING:
				draw_arc(c, r, 0.0, TAU, 40, _color, 2.4, true)
				draw_arc(c, r * 0.55, 0.0, TAU, 32, Color(_color, 0.55), 1.6, true)
			Shape.PIPS:
				# 稀有度层级点（右上一排小方点，accent 色）
				for i in range(clampi(_count, 1, 4)):
					var p := Vector2(6.0 + 12.0 * float(i), size.y * 0.5)
					draw_rect(Rect2(p, Vector2(7.0, 7.0)),
						_color if i < _count else Color(_color, 0.25))

	func _ngon(p_sides: int, p_r: float, p_phase: float) -> PackedVector2Array:
		var pts := PackedVector2Array()
		for i in range(p_sides):
			pts.append(Vector2.from_angle(p_phase + TAU * float(i) / float(p_sides)) * p_r
				+ Vector2(size.x * 0.5, size.y * 0.5))
		return pts

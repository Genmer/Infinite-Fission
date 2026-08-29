# scripts/cards/card_select_ui.gd
# M-17 CardSelectUI（架构 §2.16）：选卡界面。
# process_mode = ALWAYS（tree.paused 冻结战斗时界面可用，AC-16.2）；仅 LEVEL_UP 状态可见。
# open()：GameLoop 仲裁后调用（E-16：死亡优先，GameOver 丢弃升级请求）；choice_made →
# CardGenerator.apply_choice → EventBus.emit_card_chosen → close() 请求恢复 → GameLoop 回 PLAYING。
# 方向 C「晴空糖果」贴纸卡牌：白卡 + 稀有度色顶带 + 类型圆章（ADD 菱/MULT 三角/LOCAL 方/
# MECH 六边/ELEM 圆环）+ 稀有度层级圆点 + 出场果冻弹跳（错峰）。
class_name CardSelectUI
extends CanvasLayer

signal choice_made(card: Dictionary)          # → CardGenerator.apply_choice → card_chosen 事件

var is_open: bool = false                     # 界面可见状态（GameLoop 状态联动）

var _root: Control = null
var _buttons: Array[Button] = []              # 卡牌宿主按钮（点击域；卡面为子节点贴纸装）
var _cards: Array[Dictionary] = []            # 当前货架（open 注入）
var _title: Label = null
var _card_faces: Array[Dictionary] = []       # 卡面子件 {band, stamp, kind, name, desc, dots}

const KIND_NAMES: Array[String] = ["精通", "词条", "遗物", "保底", "新武器"]
const CARD_SIZE := Vector2(600.0, 180.0)
const CARD_X := 60.0
const CARD_TOP := 264.0                       # 首卡 y（错峰果冻出场基准）
const CARD_STEP := 196.0                      # 卡距（含 16px 间隙）


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()


func open(p_candidates: Array[Dictionary]) -> void:
	# 展示三选一货架（candidates 由 CardGenerator.generate_candidates 产出）+ 果冻错峰出场
	_cards = p_candidates
	for i in range(_buttons.size()):
		var card: Dictionary = _cards[i] if i < _cards.size() else {}
		_setup_button(_buttons[i], card)
		# REL_GAMBLER 四选一：按钮 4 仅在货架 ≥4 张时可见（三选一时隐藏占位）
		_buttons[i].visible = i < _cards.size()
	_root.visible = true
	is_open = true
	for i in range(mini(_cards.size(), _buttons.size())):
		StickerTheme.squash_pop(_buttons[i], 0.07 * float(i))


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
	choose(p_index)


func _setup_button(p_btn: Button, p_card: Dictionary) -> void:
	# 卡面装配（贴纸装：稀有度顶带 + 类型圆章 + 类别行 + 名称 + 描述 + 层级圆点）
	var idx := _buttons.find(p_btn)
	var face: Dictionary = _card_faces[idx] if idx >= 0 and idx < _card_faces.size() else {}
	if p_card.is_empty():
		p_btn.disabled = true
		return
	p_btn.disabled = false
	var kind: int = int(p_card.get("kind", 0))
	var rarity: int = int(p_card.get("rarity", 0))
	var rarity_color := PopPalette.rarity_color(rarity)
	# 顶带 = 稀有度色
	var band: Panel = face["band"]
	var band_style: StyleBoxFlat = band.get_theme_stylebox("panel").duplicate() as StyleBoxFlat
	band_style.bg_color = rarity_color
	band.add_theme_stylebox_override("panel", band_style)
	# 类型圆章
	var stamp: TextureRect = face["stamp"]
	var pool := -1
	if kind == CardGenerator.CardKind.TRAIT and p_card.get("data") != null:
		pool = int((p_card.get("data") as Object).get("pool"))
	stamp.texture = TextureFactory.type_icon(kind, pool)
	# 类别行（类别 · 稀有度名，稀有度色加深可读）
	var kind_label: Label = face["kind"]
	kind_label.text = "%s · %s" % [KIND_NAMES[clampi(kind, 0, KIND_NAMES.size() - 1)],
		PopPalette.rarity_name(rarity)]
	kind_label.add_theme_color_override("font_color", rarity_color)
	# 名称 + 描述（高稀有度数值强化 → 描述内已重写真实数值；尾行标注品质倍率作为解释）
	var name_label: Label = face["name"]
	name_label.text = String(p_card.get("display_name", ""))
	var desc_label: Label = face["desc"]
	var desc_text := String(p_card.get("description", ""))
	var value_scale := float(p_card.get("value_scale", 1.0))
	if value_scale > 1.0:
		desc_text += "\n品质加成：该词条效果 ×%.1f（已计入上行数字）" % value_scale
	desc_label.text = desc_text
	# 层级圆点（rarity+1 枚稀有度色圆珠）
	var dots: HBoxContainer = face["dots"]
	for child_v: Variant in dots.get_children():
		(child_v as Node).queue_free()
	for d in range(rarity + 1):
		var dot := TextureRect.new()
		dot.texture = TextureFactory.bead(rarity_color, 22, false)
		dot.custom_minimum_size = Vector2(14.0, 14.0)
		dot.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		dot.stretch_mode = TextureRect.STRETCH_SCALE
		dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		dots.add_child(dot)


func _build_ui() -> void:
	# 程序化贴纸卡牌竖排（720×1280 竖屏中带；4 槽 = REL_GAMBLER 四选一上限）
	_root = Control.new()
	_root.name = "CardSelectRoot"
	_root.theme = StickerTheme.theme()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.visible = false
	add_child(_root)
	var dim := ColorRect.new()
	dim.color = PopPalette.DIM
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(dim)
	_title = StickerTheme.label_sticker(Label.new(), 34, PopPalette.INK, 12, Color.WHITE, true)
	_title.text = "升级！选择一项"
	_title.position = Vector2(0.0, 148.0)
	_title.size = Vector2(720.0, 46.0)
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root.add_child(_title)
	# 4 卡槽位（open() 按货架数显隐——三选一时第 4 槽隐藏）
	for i in range(4):
		var btn := Button.new()
		btn.name = "Card%d" % i
		btn.focus_mode = Control.FOCUS_NONE
		btn.position = Vector2(CARD_X, CARD_TOP + CARD_STEP * float(i))
		btn.size = CARD_SIZE
		btn.pressed.connect(_on_pressed.bind(i))
		btn.button_down.connect(func() -> void: StickerTheme.press_punch(btn))
		_root.add_child(btn)
		_buttons.append(btn)
		_card_faces.append(_build_card_face(btn))


func _build_card_face(p_btn: Button) -> Dictionary:
	# 卡面子件组装（一次装配，open 期仅换色/换文/换点——零重建）
	var band := Panel.new()
	var band_style := StyleBoxFlat.new()
	band_style.bg_color = PopPalette.RARITY_NORMAL
	band_style.set_corner_radius_all(20)
	band_style.corner_radius_bottom_left = 0
	band_style.corner_radius_bottom_right = 0
	band.add_theme_stylebox_override("panel", band_style)
	band.position = Vector2(4.0, 4.0)
	band.size = Vector2(CARD_SIZE.x - 8.0, 14.0)
	band.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p_btn.add_child(band)
	var kind_label := StickerTheme.label_sticker(Label.new(), 15, PopPalette.RARITY_NORMAL)
	kind_label.name = "KindChip"
	kind_label.position = Vector2(24.0, 26.0)
	kind_label.size = Vector2(300.0, 20.0)
	p_btn.add_child(kind_label)
	var stamp := TextureRect.new()
	stamp.name = "TypeStamp"
	stamp.position = Vector2(CARD_SIZE.x - 76.0, 28.0)
	stamp.custom_minimum_size = Vector2(52.0, 52.0)
	stamp.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	stamp.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	stamp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p_btn.add_child(stamp)
	var name_label := StickerTheme.label_sticker(Label.new(), 22, PopPalette.INK, 0, Color.WHITE, true)
	name_label.name = "CardName"
	name_label.position = Vector2(24.0, 50.0)
	name_label.size = Vector2(CARD_SIZE.x - 110.0, 30.0)
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	p_btn.add_child(name_label)
	var desc_label := StickerTheme.label_sticker(Label.new(), 18, PopPalette.INK_SOFT)
	desc_label.name = "CardDesc"
	desc_label.position = Vector2(24.0, 88.0)
	desc_label.size = Vector2(CARD_SIZE.x - 48.0, 58.0)
	desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc_label.clip_text = true
	p_btn.add_child(desc_label)
	var dots := HBoxContainer.new()
	dots.name = "RarityDots"
	dots.position = Vector2(24.0, 150.0)
	dots.size = Vector2(160.0, 16.0)
	dots.add_theme_constant_override("separation", 6)
	dots.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p_btn.add_child(dots)
	return {"band": band, "stamp": stamp, "kind": kind_label,
		"name": name_label, "desc": desc_label, "dots": dots}

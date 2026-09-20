# scripts/cards/card_select_ui.gd
# M-17 CardSelectUI（架构 §2.16）：选卡界面。
# process_mode = ALWAYS（tree.paused 冻结战斗时界面可用，AC-16.2）；仅 LEVEL_UP 状态可见。
# open()：GameLoop 仲裁后调用（E-16：死亡优先，GameOver 丢弃升级请求）；choice_made →
# CardGenerator.apply_choice → EventBus.emit_card_chosen → close() 请求恢复 → GameLoop 回 PLAYING。
# 方向 C「晴空糖果」贴纸卡牌：白卡 + 稀有度色顶带 + 类型圆章（ADD 菱/MULT 三角/LOCAL 方/
# MECH 六边/ELEM 圆环）+ 稀有度层级圆点 + 出场果冻弹跳（错峰）。
class_name CardSelectUI
extends CanvasLayer

signal choice_made(cards: Array)              # → GameLoop 逐张 apply_choice（R72 成对：同行两张；普通=单元素）
signal reroll_requested()                     # → GameLoop 仲裁（消耗刷新次数 + 重新发牌，2026-08-31）

var is_open: bool = false                     # 界面可见状态（GameLoop 状态联动）

var _root: Control = null
var _buttons: Array[Button] = []              # 卡牌宿主按钮（点击域；卡面为子节点贴纸装）
var _cards: Array[Dictionary] = []            # 当前货架（open 注入）
var _title: Label = null
var _card_faces: Array[Dictionary] = []       # 卡面子件 {band, stamp, kind, name, desc, dots}
var _reroll_btn: Button = null                # 换一批按钮（刷新机制；次数由 GameLoop 注入）

const KIND_NAMES: Array[String] = ["精通", "词条", "遗物", "保底", "新武器", "扩容"]
const CARD_SIZE := Vector2(600.0, 180.0)
const CARD_X := 60.0
const CARD_TOP := 264.0                       # 首卡 y（错峰果冻出场基准）
const CARD_STEP := 196.0                      # 卡距（含 16px 间隙）
# R72 成对抉择（地狱/困难 5%）：2 列 ×3 行 6 卡，点任一张 = 带走同行两张
const DUAL_CARD_SIZE := Vector2(324.0, 176.0)
const DUAL_X := [24.0, 372.0]                 # 双列 x
const DUAL_TOP := 300.0
const DUAL_STEP := 196.0

var _dual: bool = false                       # 当前货架是否成对模式


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()


func open(p_candidates: Array[Dictionary], p_dual: bool = false) -> void:
	# 展示货架（candidates 由 CardGenerator.generate_candidates 产出）+ 果冻错峰出场。
	# R72 p_dual = 成对模式：双列 6 卡（槽 4~9），点任一张带走同行两张；普通模式槽 0~3
	_dual = p_dual
	_cards = p_candidates
	var slot_base := 4 if _dual else 0
	var slot_cap := 10 if _dual else 4
	for s in range(_buttons.size()):
		var in_mode: bool = s >= slot_base and s < slot_cap
		var idx := s - slot_base
		var card: Dictionary = _cards[idx] if in_mode and idx < _cards.size() else {}
		_setup_button(_buttons[s], card)
		_buttons[s].visible = in_mode and idx < _cards.size()
	_title.text = "成对抉择！带走同一行的两张" if _dual else "升级！选择一项"
	_root.visible = true
	is_open = true
	for i in range(mini(_cards.size(), slot_cap - slot_base)):
		StickerTheme.squash_pop(_buttons[slot_base + i], 0.07 * float(i))


func close() -> void:
	# 选卡完成收起（GameLoop 切回 PLAYING 时调用）
	_root.visible = false
	is_open = false
	_cards = []


func choose(p_index: int) -> void:
	# 选择入口（按钮 pressed / 测试直调）；无效索引忽略。
	# R72 成对模式：p_index = 槽位（4~9），映射到行（同行两张一起 emit）；普通单张
	if not is_open:
		return
	if _dual:
		var local := p_index - 4                 # 槽 4~9 → 0~5
		if local < 0 or local >= _cards.size():
			return
		var row := local / 2                     # 同行两张 = [row*2, row*2+1]
		var pair: Array = []
		for k in range(2):
			if row * 2 + k < _cards.size():
				pair.append(_cards[row * 2 + k])
		if pair.is_empty():
			return
		choice_made.emit(pair)
		return
	if p_index < 0 or p_index >= _cards.size():
		return
	choice_made.emit([_cards[p_index]])


func candidate_count() -> int:
	# 测试观测口
	return _cards.size()


func _on_pressed(p_index: int) -> void:
	choose(p_index)


func update_reroll(p_charges: int, p_free_left: bool = false) -> void:
	# 换一批按钮态刷新（GameLoop 注入）：免费态（本局首次）优先显示；0 次 + 无免费 →
	# 置灰仍可见——刷新机制的可发现性口径
	if _reroll_btn == null:
		return
	if p_free_left:
		_reroll_btn.text = "换一批（本局首次免费）"
		_reroll_btn.disabled = false
	elif p_charges > 0:
		_reroll_btn.text = "换一批 ×%d" % p_charges
		_reroll_btn.disabled = false
	else:
		_reroll_btn.text = "换一批 ×0"
		_reroll_btn.disabled = true


func _on_reroll_pressed() -> void:
	# 刷新申请（仲裁在 GameLoop：次数/免费位扣减 + 重新发牌 + 重开本界面）
	if is_open:
		reroll_requested.emit()


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
	# 满层质变卡（2026-08-31）：名称金色高亮（「到什么程度会质变」卡面预览）
	if bool(p_card.get("milestone", false)):
		name_label.add_theme_color_override("font_color", PopPalette.GOLD)
	var desc_label: Label = face["desc"]
	var desc_text := String(p_card.get("description", ""))
	var value_scale := float(p_card.get("value_scale", 1.0))
	if value_scale > 1.0:
		desc_text += "\n品质加成：该词条效果 ×%.1f（已计入上行数字）" % value_scale
	# F3 成对抉择行内提示（self-evolution）：窄卡空间小——组合语义就地说明
	#（标题有全局说明，但首见玩家视线落在卡上）
	if _dual:
		desc_text += "\n⇄ 点这张会同时带走同一行另一张"
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
	# 换一批按钮（刷新机制，2026-08-31 用户反馈「新增 buff 刷新机制」）：标题与首卡间右侧；
	# 次数/免费态由 GameLoop 注入（update_reroll），0 次 + 无免费 → 置灰仍可见（机制可发现）
	_reroll_btn = Button.new()
	_reroll_btn.name = "RerollButton"
	_reroll_btn.text = "换一批"
	_reroll_btn.add_theme_font_size_override("font_size", 19)
	_reroll_btn.add_theme_font_override("font", StickerTheme.font_bold())
	_reroll_btn.position = Vector2(452.0, 198.0)
	_reroll_btn.size = Vector2(208.0, 56.0)
	_reroll_btn.pivot_offset = _reroll_btn.size * 0.5
	_reroll_btn.focus_mode = Control.FOCUS_NONE
	_reroll_btn.pressed.connect(_on_reroll_pressed)
	_reroll_btn.button_down.connect(func() -> void: StickerTheme.press_punch(_reroll_btn))
	_root.add_child(_reroll_btn)
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
	# R72 成对模式 6 槽（4~9：双列三行；初始隐藏，open(…, true) 启用）
	for d in range(6):
		var dbtn := Button.new()
		dbtn.name = "DualCard%d" % d
		dbtn.focus_mode = Control.FOCUS_NONE
		dbtn.position = Vector2(DUAL_X[d % 2], DUAL_TOP + DUAL_STEP * float(d / 2))
		dbtn.size = DUAL_CARD_SIZE
		dbtn.visible = false
		dbtn.pressed.connect(_on_pressed.bind(4 + d))
		dbtn.button_down.connect(func() -> void: StickerTheme.press_punch(dbtn))
		_root.add_child(dbtn)
		_buttons.append(dbtn)
		_card_faces.append(_build_card_face(dbtn, true))


func _build_card_face(p_btn: Button, p_compact: bool = false) -> Dictionary:
	# 卡面子件组装（一次装配，open 期仅换色/换文/换点——零重建）。
	# p_compact = 成对窄卡（324 宽）：子件尺寸跟随按钮实际宽度，字号收缩
	var cw := p_btn.size.x
	var band := Panel.new()
	var band_style := StyleBoxFlat.new()
	band_style.bg_color = PopPalette.RARITY_NORMAL
	band_style.set_corner_radius_all(20)
	band_style.corner_radius_bottom_left = 0
	band_style.corner_radius_bottom_right = 0
	band.add_theme_stylebox_override("panel", band_style)
	band.position = Vector2(4.0, 4.0)
	band.size = Vector2(cw - 8.0, 14.0)
	band.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p_btn.add_child(band)
	var kind_label := StickerTheme.label_sticker(Label.new(), 15, PopPalette.RARITY_NORMAL)
	kind_label.name = "KindChip"
	kind_label.position = Vector2(18.0, 26.0)
	kind_label.size = Vector2(cw - 120.0, 20.0)
	if p_compact:
		kind_label.add_theme_font_size_override("font_size", 12)
	p_btn.add_child(kind_label)
	var stamp := TextureRect.new()
	stamp.name = "TypeStamp"
	stamp.position = Vector2(cw - 66.0, 26.0)
	stamp.custom_minimum_size = Vector2(46.0, 46.0) if p_compact else Vector2(52.0, 52.0)
	stamp.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	stamp.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	stamp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p_btn.add_child(stamp)
	var name_label := StickerTheme.label_sticker(Label.new(), 22, PopPalette.INK, 0, Color.WHITE, true)
	name_label.name = "CardName"
	name_label.position = Vector2(18.0, 50.0)
	name_label.size = Vector2(cw - 90.0, 30.0)
	if p_compact:
		name_label.add_theme_font_size_override("font_size", 18)
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	p_btn.add_child(name_label)
	var desc_label := StickerTheme.label_sticker(Label.new(), 18, PopPalette.INK_SOFT)
	desc_label.name = "CardDesc"
	desc_label.position = Vector2(18.0, 88.0)
	desc_label.size = Vector2(cw - 36.0, 58.0)
	if p_compact:
		desc_label.add_theme_font_size_override("font_size", 14)
	desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc_label.clip_text = true
	p_btn.add_child(desc_label)
	var dots := HBoxContainer.new()
	dots.name = "RarityDots"
	dots.position = Vector2(18.0, 150.0)
	dots.size = Vector2(160.0, 16.0)
	dots.add_theme_constant_override("separation", 6)
	dots.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p_btn.add_child(dots)
	return {"band": band, "stamp": stamp, "kind": kind_label,
		"name": name_label, "desc": desc_label, "dots": dots}

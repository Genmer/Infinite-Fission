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

const KIND_NAMES: Array[String] = ["精通", "词条", "遗物", "保底", "新武器", "槽位"]
const CARD_SIZE := Vector2(600.0, 180.0)
const CARD_X := 60.0
const CARD_TOP := 264.0                       # 首卡 y（错峰果冻出场基准）
const CARD_STEP := 196.0                      # 卡距（含 16px 间隙）
# R72 成对抉择（地狱/困难 5%）：2 列 ×3 行 6 卡，点任一张 = 带走同行两张
const DUAL_CARD_SIZE := Vector2(324.0, 176.0)
const DUAL_X := [24.0, 372.0]                 # 双列 x
const DUAL_TOP := 300.0
const DUAL_STEP := 196.0
# R199(P05/P06/F15) 描述区自适应扩容的几何帽与栈重排参数（只改几何，零交互改动）：
# 卡体可随描述扩高，上限保证 4 卡栈 / 3 行双列在最坏全扩高时经间隙压缩仍落 720×1280 内
const CARD_H_MAX := 250.0                     # 普通卡高帽（4 卡栈 264..1272 红线内）
const DUAL_H_MAX := 310.0                     # 成对卡高帽（3 行 300..1272 红线内）
const STACK_GAP := 16.0                       # 卡距间隙（= CARD_STEP − CARD_SIZE.y 基准）
const DUAL_STACK_GAP := 20.0                  # 成对行距间隙（= DUAL_STEP − DUAL_CARD_SIZE.y）
const STACK_BOTTOM_MAX := 1272.0              # 卡栈下缘红线（1280 − 8px 余量）

var _dual: bool = false                       # 当前货架是否成对模式
var _highlight_slots: Array[int] = []         # R188-3 挂机预选描金槽位（highlight_candidate 落值；close 清除）


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	# R195 适配：安全区接入（底座组 SafeAreaHelper 单点引用，不复写）。守卫外
	# （桌面窗口化/headless）insets 恒零 → offset 写 0 = 默认窗逐位恒等；真机延迟
	# ≥1 帧重读兜首帧 transform 未定型，size_changed/重获焦点由 helper 重放回调。
	_apply_safe_area()
	if SafeAreaHelper.enabled(get_window()):          # 守卫外恒零→零协程悬挂（headless 全绿面）
		_apply_safe_area_deferred()                # 真值环境延迟重读（SafeAreaHelper 契约）
	SafeAreaHelper.bind_reread(get_window(), _apply_safe_area)


func _apply_safe_area() -> void:
	# R195 安全区应用（消费式契约=SafeAreaHelper.insets 注释）：根 FULL_RECT
	# offset 左/上取正、右/下取负；dim FULL_RECT 子件随根，标题/卡栈锚组随根域。
	# 仅 realize/size_changed/焦点事件驱动，非每帧路径（R188 纪律）。
	var ins := SafeAreaHelper.insets(get_window())
	_root.offset_left = ins.position.x
	_root.offset_top = ins.position.y
	_root.offset_right = -ins.size.x
	_root.offset_bottom = -ins.size.y


func _apply_safe_area_deferred() -> void:
	# realize 后延迟 ≥1 帧重读（首帧查询为未 realize 真值——SafeAreaHelper 契约）；
	# 协程即发即续，不阻塞 _ready（调用方已守卫 enabled 才进来；二次应用幂等）
	await SafeAreaHelper.read_deferred(get_window())
	_apply_safe_area()


func open(p_candidates: Array[Dictionary], p_dual: bool = false) -> void:
	# 展示货架（candidates 由 CardGenerator.generate_candidates 产出）+ 果冻错峰出场。
	# R72 p_dual = 成对模式：双列 6 卡（槽 4~9），点任一张带走同行两张；普通模式槽 0~3
	_dual = p_dual
	_cards = p_candidates
	_highlight_slots.clear()                     # 新货架重开：上一局描金态作废（open 重上色机制兜底还原）
	var slot_base := 4 if _dual else 0
	var slot_cap := 10 if _dual else 4
	for s in range(_buttons.size()):
		var in_mode: bool = s >= slot_base and s < slot_cap
		var idx := s - slot_base
		var card: Dictionary = _cards[idx] if in_mode and idx < _cards.size() else {}
		_setup_button(_buttons[s], card)
		_buttons[s].visible = in_mode and idx < _cards.size()
	_reflow_stack()                              # R199：变高卡栈防重叠重排（纯几何）
	_title.text = "成对抉择！带走同一行的两张" if _dual else "升级！选择一项"
	_root.visible = true
	is_open = true
	for i in range(mini(_cards.size(), slot_cap - slot_base)):
		StickerTheme.squash_pop(_buttons[slot_base + i], 0.07 * float(i))


func close() -> void:
	# 选卡完成收起（GameLoop 切回 PLAYING 时调用）；描金预选随收起清除（还原稀有度色）
	_clear_highlight()
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


func highlight_candidate(p_index: int) -> void:
	# R188-3 挂机自动选择预选描金：欲选卡顶带改金色（复用 open 期 _apply_band_color
	# 重上色机制——duplicate StyleBoxFlat 后改 bg，不落共享态）；成对模式 p_index 为
	# 槽位（4~9），同行两张同亮（整行 = 一次选择语义）；未开店/越界忽略；再次调用
	# 先还原上一次描金（单预选口）。close() 清除还原。
	if not is_open or p_index < 0:
		return
	_clear_highlight()
	var slots: Array[int] = []
	if _dual:
		var local := p_index - 4                 # 槽 4~9 → 卡 0~5（choose 同映射）
		if local < 0 or local >= _cards.size():
			return
		var row := local / 2
		for k in range(2):
			if row * 2 + k < _cards.size():
				slots.append(4 + row * 2 + k)
	else:
		if p_index >= _cards.size():
			return
		slots.append(p_index)
	for s in slots:
		_apply_band_color(s, PopPalette.GOLD)
		_highlight_slots.append(s)


func highlighted_slots() -> Array[int]:
	# 测试观测口：当前描金槽位快照
	return _highlight_slots.duplicate()


func _clear_highlight() -> void:
	# 描金还原（_highlight_slots 逐槽按卡面稀有度色重上色后清表；open/close 双入口）
	for s in _highlight_slots:
		var card_idx := s - (4 if _dual else 0)
		if s < 0 or s >= _buttons.size() or card_idx < 0 or card_idx >= _cards.size():
			continue
		var card: Dictionary = _cards[card_idx]
		if card.is_empty():
			continue                             # 已售出/空槽：open 重上色时自然归位
		_apply_band_color(s, PopPalette.rarity_color(int(card.get("rarity", 0))))
	_highlight_slots.clear()


func _apply_band_color(p_slot: int, p_color: Color) -> void:
	# 顶带重上色唯一通道（原 _setup_button :136-138 机制收口）：duplicate 当前
	# StyleBoxFlat → 改 bg_color → override。稀有度色与描金高亮共用。
	if p_slot < 0 or p_slot >= _card_faces.size():
		return
	var band: Panel = _card_faces[p_slot]["band"]
	var band_style: StyleBoxFlat = band.get_theme_stylebox("panel").duplicate() as StyleBoxFlat
	band_style.bg_color = p_color
	band.add_theme_stylebox_override("panel", band_style)


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
	# 顶带 = 稀有度色（重上色走 _apply_band_color 唯一通道——描金高亮共用同一机制）
	_apply_band_color(idx, rarity_color)
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
	# R199(P05/P06/F15) 描述区自适应扩容：58px 定高+clip 改为按 StickerTheme 实测行高
	# 适配——字号梯从大到小取首个装得下的档，框高=实测需求高（含行距），卡体随描述
	# 扩高（≤设计帽），层级圆点让位下移；超长描述（元素族全反应列举）在梯底钳帽由
	# clip_text 兜底。体检实测 18pt≈54px 宿主相关（禁拍值）；文案内容零改动
	# （源在 tres/GameConst）
	var is_compact := _dual
	var fit := _fit_desc(desc_text, p_btn.size.x, is_compact,
		float(desc_label.get_theme_constant("line_spacing")))
	desc_label.add_theme_font_size_override("font_size", int(fit["fs"]))
	var desc_need := float(fit["need"])
	desc_label.size = Vector2(p_btn.size.x - 36.0, maxf(58.0, desc_need))
	var h_base: float = DUAL_CARD_SIZE.y if is_compact else CARD_SIZE.y
	var dots_y := maxf(150.0, 88.0 + desc_need + 4.0)
	var h_new: float = minf(maxf(h_base, dots_y + h_base - 150.0),
		DUAL_H_MAX if is_compact else CARD_H_MAX)
	p_btn.size = Vector2(p_btn.size.x, h_new)
	# 层级圆点（rarity+1 枚稀有度色圆珠）
	var dots: HBoxContainer = face["dots"]
	dots.position = Vector2(18.0, minf(dots_y, h_new - 30.0))
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
	# R195 适配分区：标题全宽拉伸锚（anchor_l=0/anchor_r=1、y 不变；(0,148)720×46
	# 720 宽恒等，宽视口下满宽居中）
	_title = StickerTheme.label_sticker(Label.new(), 34, PopPalette.INK, 12, Color.WHITE, true)
	_title.text = "升级！选择一项"
	_title.anchor_right = 1.0
	_title.offset_left = 0.0
	_title.offset_right = 0.0
	_title.offset_top = 148.0
	_title.offset_bottom = 194.0
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
	# R195 适配分区：reroll 钮同卡栈整体居中锚（offset=现值−设计中心(360,640)——
	# 与卡栈同组随视口居中移动，栈内相对位恒等）
	_reroll_btn.anchor_left = 0.5
	_reroll_btn.anchor_right = 0.5
	_reroll_btn.anchor_top = 0.5
	_reroll_btn.anchor_bottom = 0.5
	_reroll_btn.offset_left = 92.0
	_reroll_btn.offset_right = 300.0
	_reroll_btn.offset_top = -442.0
	_reroll_btn.offset_bottom = -386.0
	_reroll_btn.pivot_offset = _reroll_btn.size * 0.5
	_reroll_btn.focus_mode = Control.FOCUS_NONE
	_reroll_btn.pressed.connect(_on_reroll_pressed)
	_reroll_btn.button_down.connect(func() -> void: StickerTheme.press_punch(_reroll_btn))
	_root.add_child(_reroll_btn)
	# 4 卡槽位（open() 按货架数显隐——三选一时第 4 槽隐藏）
	# R195 适配分区：卡栈整体居中锚——各卡 offset=设计位−设计中心(360,640)（等效包一层
	# 居中容器，免重挂父子），CARD_TOP/CARD_STEP/DUAL_* 设计位公式原样父相对恒等；
	# 720×1280 逐位恒等，宽/高视口下整栈随中心随动
	for i in range(4):
		var btn := Button.new()
		btn.name = "Card%d" % i
		btn.focus_mode = Control.FOCUS_NONE
		var card_pos := Vector2(CARD_X, CARD_TOP + CARD_STEP * float(i))
		btn.anchor_left = 0.5
		btn.anchor_right = 0.5
		btn.anchor_top = 0.5
		btn.anchor_bottom = 0.5
		btn.offset_left = card_pos.x - 360.0
		btn.offset_right = card_pos.x + CARD_SIZE.x - 360.0
		btn.offset_top = card_pos.y - 640.0
		btn.offset_bottom = card_pos.y + CARD_SIZE.y - 640.0
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
		var dual_pos := Vector2(DUAL_X[d % 2], DUAL_TOP + DUAL_STEP * float(d / 2))
		dbtn.anchor_left = 0.5
		dbtn.anchor_right = 0.5
		dbtn.anchor_top = 0.5
		dbtn.anchor_bottom = 0.5
		dbtn.offset_left = dual_pos.x - 360.0
		dbtn.offset_right = dual_pos.x + DUAL_CARD_SIZE.x - 360.0
		dbtn.offset_top = dual_pos.y - 640.0
		dbtn.offset_bottom = dual_pos.y + DUAL_CARD_SIZE.y - 640.0
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


func _fit_desc(p_text: String, p_cw: float, p_compact: bool, p_line_spacing: float) -> Dictionary:
	# R199(P05/P06/F15) 描述框自适应量测：按 StickerTheme 实测行高排版测高（体检实测
	# 18pt≈54px 宿主相关——禁拍值，get_multiline_string_size 同参口径），字号梯从大到
	# 小取首个「需求高 ≤ 框帽」的档；梯底仍超 → 梯底字号 + 需求钳帽（clip_text 兜底）。
	# 实测高不含 Label 行距——按行数补 (n−1)×line_spacing（行数 = 需求高 ÷ 实测行高，
	# get_multiline_string_size 高 = n×get_height 整除口径）。框帽 = 卡高帽 − 基准卡高
	# + 54（描述顶 88 + 圆点/底距 34 的反解，与 _setup_button 落位公式同源）。
	# 返回 {fs: 字号, need: 实测需求高含行距（已钳帽）}。
	var ladder: Array = [14, 13, 12, 11, 10] if p_compact \
		else [18, 16, 14, 13, 12, 11, 10]
	var h_cap: float = DUAL_H_MAX if p_compact else CARD_H_MAX
	var h_base: float = DUAL_CARD_SIZE.y if p_compact else CARD_SIZE.y
	var max_h := h_cap - h_base + 54.0
	var width := p_cw - 36.0
	var font: Font = StickerTheme.font()
	var best: int = int(ladder[ladder.size() - 1])
	var need := _measured_desc_h(font, p_text, width, best, p_line_spacing)
	for fs_v: Variant in ladder:
		var fs := int(fs_v)
		var h := _measured_desc_h(font, p_text, width, fs, p_line_spacing)
		if h <= max_h:
			best = fs
			need = h
			break
	return {"fs": best, "need": minf(need, max_h)}


func _measured_desc_h(p_font: Font, p_text: String, p_width: float, p_fs: int,
		p_line_spacing: float) -> float:
	# 实测描述排版高：wrap 需求高（= n×行高）+ 行间行距 (n−1)×line_spacing
	var raw: float = p_font.get_multiline_string_size(p_text,
		HORIZONTAL_ALIGNMENT_LEFT, p_width, p_fs, -1, 7).y
	var line_h := maxf(p_font.get_height(p_fs), 1.0)
	var lines := maxi(1, roundi(raw / line_h))
	return raw + float(lines - 1) * p_line_spacing


func _reflow_stack() -> void:
	# R199(P05/P06/F15) 变高卡栈防重叠重排（纯几何，open 期一次）：普通模式逐卡、成对
	# 模式逐行（同行顶对齐，行距取行内最高卡）；基准间隙 = STEP − SIZE.y（16/20），
	# 无卡扩高时落位与 CARD_TOP/CARD_STEP/DUAL_* 设计位逐位恒等；栈底越红线
	# （STACK_BOTTOM_MAX）则压缩间隙重排一遍（下限 4px，再越线属极限超帽接受裁切）。
	var gap := DUAL_STACK_GAP if _dual else STACK_GAP
	var top := DUAL_TOP if _dual else CARD_TOP
	for pass_i in range(2):
		var y := top
		var placed := 0
		if _dual:
			for r in range(3):
				var row_h := 0.0
				var any_visible := false
				for k in range(2):
					var b := _buttons[4 + r * 2 + k]
					if b.visible:
						b.position.y = y
						any_visible = true
						row_h = maxf(row_h, b.size.y)
				if any_visible:
					y += row_h + gap
					placed += 1
		else:
			for i in range(4):
				var b := _buttons[i]
				if b.visible:
					b.position.y = y
					y += b.size.y + gap
					placed += 1
		var bottom := y - gap
		if placed < 2 or bottom <= STACK_BOTTOM_MAX:
			return
		gap = maxf(4.0, gap - (bottom - STACK_BOTTOM_MAX) / float(placed - 1))

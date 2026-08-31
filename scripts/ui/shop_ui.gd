# scripts/ui/shop_ui.gd
# v0.6.0 ShopUI（A4 §1/§2）→ v0.7.0 全量重排 720×1280 坐标表（A6 §4）：
#   标题 y96（TOP_WIDE 居中 font28）/ 卡架 0-2 (60,160)/(60,266)/(60,372) 600x96 /
#   武器架 (60,478) 600x88 / 芯片架 0-1 (60,584)/(368,584) 292x96 font14 /
#   utility×3 (60,696)/(260,696)/(460,696) 180x84 / 芯片槽位面板 (60,796) 600x168
#  （底板+标题+3 槽盒 188x120 @(8,36)/(206,36)/(404,36)）/ 离开 (60,980) 600x80。
#   全部相邻间隙 ≥10px；layout_rects() 断言两两无交集。
# 货架（A4 §2 定价真源 + A6 §4 芯片梯度）：明码卡 3 张（白40/蓝70/紫120/金220；黑市金卡 260）
# + 武器架 1 张（100，无可用武器则空架 disabled）+ 芯片架 2 张（price_for_rarity 同卡架梯度）
# + utility 三项（重随券 30 每店限 1 / 回复 30%max_hp 50 / max_hp+10 80 每店限 1）+ 离开按钮。
# 每项单次购买（购后 disabled+"（已购）"）；余额不足 disabled（refresh_gold 自刷重算）。
# 信号 → GameLoop 仲裁（先验证→apply→扣款，任一失败静默拒绝不扣款）。
class_name ShopUI
extends CanvasLayer

signal purchase_requested(index: int)         # 0~2 卡架 / 3 武器架 / 4~5 芯片架（GameLoop 仲裁）
signal utility_requested(util: StringName)    # &"reroll" / &"heal" / &"maxhp"
signal close_requested()                      # 离开商店

# 定价真源（A4 §2；键 = rarity）
const CARD_PRICES := {0: 40, 1: 70, 2: 120, 3: 220}
const CARD_PRICE_BLACK_GOLD := 260            # 黑市金卡（rarity==3）
const WEAPON_PRICE := 100
const REROLL_PRICE := 30
const HEAL_PRICE := 50
const MAXHP_PRICE := 80
const OUTLINE_COLOR := Color(0.0, 0.0, 0.0, 0.9)
const OUTLINE_SIZE := 4
# v0.7.0 A6 §4 布局坐标表（720×1280）
const TITLE_POS := Vector2(0.0, 96.0)
const CARD_SIZE := Vector2(600.0, 96.0)
const CARD_POSITIONS: Array[Vector2] = [Vector2(60.0, 160.0), Vector2(60.0, 266.0), Vector2(60.0, 372.0)]
const WEAPON_POS := Vector2(60.0, 478.0)
const WEAPON_SIZE := Vector2(600.0, 88.0)
const CHIP_SIZE := Vector2(292.0, 96.0)
const CHIP_POSITIONS: Array[Vector2] = [Vector2(60.0, 584.0), Vector2(368.0, 584.0)]
const UTIL_SIZE := Vector2(180.0, 84.0)
const UTIL_POSITIONS: Array[Vector2] = [Vector2(60.0, 696.0), Vector2(260.0, 696.0), Vector2(460.0, 696.0)]
const CHIP_PANEL_POS := Vector2(60.0, 796.0)
const CHIP_PANEL_SIZE := Vector2(600.0, 168.0)
const SLOT_SIZE := Vector2(188.0, 120.0)
const SLOT_POSITIONS: Array[Vector2] = [Vector2(8.0, 36.0), Vector2(206.0, 36.0), Vector2(404.0, 36.0)]
const LEAVE_POS := Vector2(60.0, 980.0)
const LEAVE_SIZE := Vector2(600.0, 80.0)
const RARITY_NAMES: Array[String] = ["白", "蓝", "紫", "金"]

var is_open: bool = false                     # 界面可见状态（GameLoop 状态联动）

var _root: Control = null
var _title: Label = null
var _card_buttons: Array[Button] = []         # 卡架 3 + 武器架 1（index 0~3）
var _chip_buttons: Array[Button] = []         # 芯片架 2（index 4~5，v0.7.0）
var _util_buttons: Dictionary = {}            # StringName(util) -> Button
var _slot_labels: Array[Label] = []           # 芯片槽位面板 3 标签（v0.7.0）
var _cards: Array[Dictionary] = []            # 当前卡架（open/update_cards 注入）
var _weapon_card: Dictionary = {}             # 当前武器架（空 = 空架 disabled）
var _chip_offers: Array[Dictionary] = []      # 当前芯片架（set_chip_shelf 注入；v0.7.0）
var _chip_free_slots: int = 0                 # 芯片空槽数（set_chip_shelf 注入；≤0 → 槽满禁购）
var _chip_slots: Array[Dictionary] = []       # 槽位面板快照（set_chip_slots 注入；v0.7.0）
var _purchased: Array[bool] = [false, false, false, false, false, false]   # v0.7.0 扩 0~5
var _reroll_used: bool = false                # 重随券每店限 1
var _maxhp_used: bool = false                 # max_hp+10 每店限 1
var _black_market: bool = false
var _wave: int = 0
var _gold: int = 0                            # 最近一次余额（refresh_gold 同步）
var _player_full_hp: bool = false             # v0.7.0 U7：满血 heal 预禁用（open/heal 后回写）


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	EventBus.gold_changed.connect(refresh_gold)          # 余额自刷 + 可购性重算
	EventBus.state_changed.connect(_on_state_changed)    # GAME_OVER/MENU 强制收起


func open(p_wave: int, p_black_market: bool, p_cards: Array[Dictionary],
		p_weapon: Dictionary, p_gold: int) -> void:
	# 开店（GameLoop._open_shop_flow 仲裁后调用）：注入货架 + 余额；每店限购位复位。
	# ★ 五参签名不变（pkg6_extra 兼容）；芯片架/槽位面板由 set_chip_shelf/set_chip_slots 注入。
	_wave = p_wave
	_black_market = p_black_market
	_cards = p_cards
	_weapon_card = p_weapon
	_gold = p_gold
	_purchased = [false, false, false, false, false, false]
	_reroll_used = false
	_maxhp_used = false
	_chip_offers = []
	_chip_free_slots = 0
	_root.visible = true
	is_open = true
	_refresh_title()
	_refresh_shelf()


func close() -> void:
	# 闭店（GameLoop._close_shop / GAME_OVER/MENU 强制收起）
	_root.visible = false
	is_open = false
	_cards = []
	_weapon_card = {}
	_chip_offers = []


func update_cards(p_cards: Array[Dictionary]) -> void:
	# 重随货架（GameLoop 消费 reroll 申请后调用）
	_cards = p_cards
	_refresh_shelf()


func refresh_gold(p_total: int) -> void:
	# 余额刷新（gold_changed 订阅；标题 + 可购性重算）
	_gold = p_total
	_refresh_title()
	_refresh_shelf()


func set_chip_shelf(p_offers: Array[Dictionary], p_free_slots: int) -> void:
	# v0.7.0 U7：芯片货架注入（每项 {chip_id, rarity, price}+显示装饰键）。
	# 新货架 = 新购买位（重随后已购芯片位复位）；free_slots ≤0 → 整架禁购（后缀"（槽满）"）。
	_chip_offers = p_offers.duplicate()
	_chip_free_slots = p_free_slots
	_purchased[4] = false
	_purchased[5] = false
	_refresh_shelf()


func set_chip_slots(p_slots: Array[Dictionary]) -> void:
	# v0.7.0 U7：槽位面板注入（ChipHandler.slot_snapshot；空槽 {} → "空槽"占位）
	_chip_slots = p_slots.duplicate()
	_refresh_slots()


func set_player_full_hp(p_full: bool) -> void:
	# v0.7.0 U7：heal 预禁用回写（open 后与 heal 购买成功后由 GameLoop 调用）
	_player_full_hp = p_full
	_refresh_shelf()


func shelf_state() -> Dictionary:
	# 测试观测口（当前货架/已购位/限购位/黑市标记/波号/余额 + v0.7.0 芯片段）
	var purchased_copy: Array[bool] = []
	for p in _purchased:
		purchased_copy.append(p)
	var chip_purchased: Array[bool] = []
	for i in range(_chip_buttons.size()):
		chip_purchased.append(_purchased[4 + i])
	return {
		"wave": _wave,
		"black_market": _black_market,
		"cards": _cards.duplicate(),
		"weapon": _weapon_card,
		"purchased": purchased_copy,
		"reroll_used": _reroll_used,
		"maxhp_used": _maxhp_used,
		"gold": _gold,
		"chips": _chip_offers.duplicate(),
		"chip_purchased": chip_purchased,
		"chip_free_slots": _chip_free_slots,
	}


func mark_purchased(p_index: int) -> void:
	# GameLoop 购买成功后调用：单次购买位（v0.7.0 扩 0~5）+ 按钮态刷新
	if p_index < 0 or p_index >= _purchased.size():
		return
	_purchased[p_index] = true
	_refresh_shelf()


func mark_utility_used(p_util: StringName) -> void:
	# GameLoop utility 成功后调用（重随/maxhp 每店限 1）
	if p_util == &"reroll":
		_reroll_used = true
	elif p_util == &"maxhp":
		_maxhp_used = true
	_refresh_shelf()


func price_for(p_index: int) -> int:
	# 定价（A4 §2 + A6 §4）：0~2 明码卡按 rarity（黑市且 rarity==3 → 260）；3 武器架 100；
	# 4~5 芯片架按 offer.price（空架 → -1 不可购）
	if p_index == 3:
		return WEAPON_PRICE
	if p_index >= 4:
		var offer: Dictionary = _chip_offers[p_index - 4] if p_index - 4 < _chip_offers.size() else {}
		return int(offer.get("price", -1)) if not offer.is_empty() else -1
	var card: Dictionary = _cards[p_index] if p_index < _cards.size() else {}
	if card.is_empty():
		return -1                                # 空架不可购
	var rarity := int(card.get("rarity", 0))
	if _black_market and rarity == 3:
		return CARD_PRICE_BLACK_GOLD
	return int(CARD_PRICES.get(rarity, 0))


func layout_rects() -> Array[Rect2]:
	# v0.7.0 布局契约断言口：货架/utility/面板/离开占位矩形（两两 intersects()==false；
	# 相邻间隙 ≥10px）。标题为 TOP_WIDE 覆盖层不入列（同 HUD 横幅口径）；
	# 槽盒嵌套于面板矩形内不入列（同 HUD HP 文本口径）。
	var out: Array[Rect2] = []
	for pos in CARD_POSITIONS:
		out.append(Rect2(pos, CARD_SIZE))
	out.append(Rect2(WEAPON_POS, WEAPON_SIZE))
	for pos in CHIP_POSITIONS:
		out.append(Rect2(pos, CHIP_SIZE))
	for pos in UTIL_POSITIONS:
		out.append(Rect2(pos, UTIL_SIZE))
	out.append(Rect2(CHIP_PANEL_POS, CHIP_PANEL_SIZE))
	out.append(Rect2(LEAVE_POS, LEAVE_SIZE))
	return out


func _on_state_changed(p_state: int) -> void:
	# GAME_OVER/MENU 强制收起（死亡结算/回菜单不留商店浮层）
	if p_state == GameConst.GameStatus.GAME_OVER or p_state == GameConst.GameStatus.MENU:
		close()


# ── 内部：货架文本/可购性刷新 ─────────────────────────────────────
func _refresh_title() -> void:
	_title.text = "商店（金币 G%d）" % _gold


func _refresh_shelf() -> void:
	# 卡架/武器架/芯片架逐项：文本 + disabled（已购 / 余额不足 / 空架 / 槽满）
	for i in range(_card_buttons.size()):
		var btn := _card_buttons[i]
		var purchased := _purchased[i]
		var is_weapon := i == 3
		var card: Dictionary = _weapon_card if is_weapon \
			else (_cards[i] if i < _cards.size() else {})
		if purchased:
			btn.disabled = true
			btn.text = _shelf_text(card, is_weapon, price_for(i)) + "（已购）"
			continue
		if card.is_empty():
			btn.disabled = true
			btn.text = "空架" if is_weapon else "-"
			continue
		var price := price_for(i)
		btn.disabled = _gold < price
		btn.text = _shelf_text(card, is_weapon, price)
	# 芯片架（v0.7.0：已购 / 空架 / 余额不足 / 槽满 四态）
	for i in range(_chip_buttons.size()):
		var chip_btn := _chip_buttons[i]
		var idx := 4 + i
		var offer: Dictionary = _chip_offers[i] if i < _chip_offers.size() else {}
		var suffix := ""
		if _purchased[idx]:
			chip_btn.disabled = true
			chip_btn.text = _chip_text(offer, price_for(idx)) + "（已购）"
			continue
		if offer.is_empty():
			chip_btn.disabled = true
			chip_btn.text = "空架"
			continue
		var chip_price := price_for(idx)
		chip_btn.disabled = _gold < chip_price or _chip_free_slots <= 0
		if _chip_free_slots <= 0:
			suffix = "（槽满）"
		chip_btn.text = _chip_text(offer, chip_price) + suffix
	# utility：限购位 disabled + heal 满血预禁用（v0.7.0 U7）
	var reroll_btn: Button = _util_buttons[&"reroll"]
	var heal_btn: Button = _util_buttons[&"heal"]
	var maxhp_btn: Button = _util_buttons[&"maxhp"]
	reroll_btn.disabled = _reroll_used or _gold < REROLL_PRICE
	_util_text(reroll_btn, &"reroll", REROLL_PRICE, "（已购）" if _reroll_used else "")
	heal_btn.disabled = _gold < HEAL_PRICE or _player_full_hp
	_util_text(heal_btn, &"heal", HEAL_PRICE, "（满血）" if _player_full_hp else "")
	maxhp_btn.disabled = _maxhp_used or _gold < MAXHP_PRICE
	_util_text(maxhp_btn, &"maxhp", MAXHP_PRICE, "（已购）" if _maxhp_used else "")


func _refresh_slots() -> void:
	# 槽位面板 3 标签：已装备 "[金] 名称 value"；空槽 "空槽" 占位
	for i in range(_slot_labels.size()):
		var label := _slot_labels[i]
		var slot: Dictionary = _chip_slots[i] if i < _chip_slots.size() else {}
		if slot.is_empty():
			label.text = "空槽"
			label.self_modulate = Color(0.6, 0.6, 0.65)
			continue
		var rarity := clampi(int(slot.get("rarity", 0)), 0, 3)
		label.text = "[%s] %s\n%s" % [RARITY_NAMES[rarity],
			String(slot.get("display_name", "")), String(slot.get("value_text", ""))]
		label.self_modulate = Color(0.95, 0.95, 0.95)


func _shelf_text(p_card: Dictionary, p_weapon: bool, p_price: int) -> String:
	# 货架项文本：[类别] 名称 / 描述 / 价格（kind 单源 GameConst.card_kind_name，U14）
	var kind_name: String = "武器" if p_weapon \
		else GameConst.card_kind_name(int(p_card.get("kind", 0)))
	return "[%s] %s\n%s\n价格：%d 金币" % [kind_name, String(p_card.get("display_name", "")),
		String(p_card.get("description", "")), p_price]


func _chip_text(p_offer: Dictionary, p_price: int) -> String:
	# 芯片货架项文本：[芯片·档] 名称 value / 价格
	var rarity := clampi(int(p_offer.get("rarity", 0)), 0, 3)
	return "[芯片·%s] %s %s\n\n价格：%d 金币" % [RARITY_NAMES[rarity],
		String(p_offer.get("display_name", String(p_offer.get("chip_id", "")))),
		String(p_offer.get("value_text", "")), p_price]


func _util_text(p_btn: Button, p_util: StringName, p_price: int, p_suffix: String) -> void:
	var label := ""
	match p_util:
		&"reroll":
			label = "重随卡架"
		&"heal":
			label = "回复 30% HP"
		&"maxhp":
			label = "max_hp +10"
	p_btn.text = "%s：%d 金币%s" % [label, p_price, p_suffix]


# ── 程序化 UI 组装（v0.7.0 720×1280 全量坐标表，见类头） ──────────
func _build_ui() -> void:
	_root = Control.new()
	_root.name = "ShopRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.visible = false
	add_child(_root)
	var dim := ColorRect.new()
	dim.color = Color(0.04, 0.04, 0.09, 0.86)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(dim)
	_title = _add_label(_root, TITLE_POS, "商店（金币 G0）", 28)
	_title.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# 卡架 3（600x96 @ y=160/266/372，index 0~2）
	for i in range(CARD_POSITIONS.size()):
		var btn := _add_button("Card%d" % i, CARD_POSITIONS[i], CARD_SIZE, 14)
		btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		var card_index := i
		btn.pressed.connect(func() -> void: purchase_requested.emit(card_index))
		_card_buttons.append(btn)
	# 武器架（600x88 @ y=478，index 3）
	var weapon_btn := _add_button("Weapon", WEAPON_POS, WEAPON_SIZE, 14)
	weapon_btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	weapon_btn.pressed.connect(func() -> void: purchase_requested.emit(3))
	_card_buttons.append(weapon_btn)
	# 芯片架 2（292x96 @ y=584，index 4~5，font14）
	for i in range(CHIP_POSITIONS.size()):
		var chip_btn := _add_button("Chip%d" % i, CHIP_POSITIONS[i], CHIP_SIZE, 14)
		chip_btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		var chip_index := 4 + i
		chip_btn.pressed.connect(func() -> void: purchase_requested.emit(chip_index))
		_chip_buttons.append(chip_btn)
	# utility 三按钮（180x84 @ y=696 横排）
	var utils: Array = [[&"reroll", 0], [&"heal", 1], [&"maxhp", 2]]
	for u in utils:
		var btn := _add_button(String(u[0]), UTIL_POSITIONS[u[1]], UTIL_SIZE, 14)
		btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		var util: StringName = u[0]
		btn.pressed.connect(func() -> void: utility_requested.emit(util))
		_util_buttons[util] = btn
	# 芯片槽位面板（600x168 @ y=796：底板 + 标题 + 3 槽盒 188x120）
	var panel := Panel.new()
	panel.name = "ChipPanel"
	panel.position = CHIP_PANEL_POS
	panel.size = CHIP_PANEL_SIZE
	_root.add_child(panel)
	var panel_title := _add_label(panel, Vector2(8.0, 6.0), "芯片槽位", 14)
	panel_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for i in range(SLOT_POSITIONS.size()):
		var slot_box := Panel.new()
		slot_box.name = "Slot%d" % i
		slot_box.position = SLOT_POSITIONS[i]
		slot_box.size = SLOT_SIZE
		panel.add_child(slot_box)
		var slot_label := _add_label(slot_box, Vector2(8.0, 8.0), "空槽", 13)
		slot_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		slot_label.self_modulate = Color(0.6, 0.6, 0.65)
		_slot_labels.append(slot_label)
	# 离开按钮（600x80 @ y=980）
	var leave := _add_button("Leave", LEAVE_POS, LEAVE_SIZE, 16)
	leave.text = "离开商店"
	leave.pressed.connect(func() -> void: close_requested.emit())


func _add_button(p_name: String, p_pos: Vector2, p_size: Vector2, p_font: int) -> Button:
	# 程序化 Button（描边口径与全架一致）
	var btn := Button.new()
	btn.name = p_name
	btn.add_theme_font_size_override("font_size", p_font)
	btn.add_theme_color_override("font_outline_color", OUTLINE_COLOR)
	btn.add_theme_constant_override("outline_size", OUTLINE_SIZE)
	btn.position = p_pos
	btn.size = p_size
	_root.add_child(btn)
	return btn


func _add_label(p_parent: Control, p_pos: Vector2, p_text: String, p_size: int) -> Label:
	# 程序化 Label（描边口径与 HUD 一致）
	var label := Label.new()
	label.position = p_pos
	label.text = p_text
	label.add_theme_font_size_override("font_size", p_size)
	label.add_theme_color_override("font_outline_color", OUTLINE_COLOR)
	label.add_theme_constant_override("outline_size", OUTLINE_SIZE)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p_parent.add_child(label)
	return label

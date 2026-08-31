# scripts/ui/shop_ui.gd
# v0.6.0 ShopUI（A4 §1/§2）：Boss 前商店界面（CanvasLayer，process_mode=ALWAYS——SHOP 态
# tree.paused 冻结战斗时可用，同 CardSelectUI 口径）。
# 货架（A4 §2 定价真源）：明码卡 3 张（白40/蓝70/紫120/金220；黑市金卡 260）+ 武器架 1 张
#（100，无可用武器则空架 disabled）+ utility 三项（重随券 30 每店限 1 / 回复 30%max_hp 50 /
# max_hp+10 80 每店限 1）+ 离开按钮。每项单次购买（购后 disabled+"（已购）"）；
# 余额不足 disabled（refresh_gold 自刷重算——EventBus.gold_changed 订阅）。
# 信号 → GameLoop 仲裁（先验证→apply→扣款，任一失败静默拒绝不扣款）。
# 布局（720×1280）：全屏 dim 0.86 + 标题 y=180 + 卡架 3 按钮 (60,320/440/560,600x110) +
# 武器架 (60,680,600x100) + utility y=820 横排 + 离开 (60,1000)。文本加描边。
class_name ShopUI
extends CanvasLayer

signal purchase_requested(index: int)         # 0~2 卡架 / 3 武器架（GameLoop 仲裁）
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

var is_open: bool = false                     # 界面可见状态（GameLoop 状态联动）

var _root: Control = null
var _title: Label = null
var _card_buttons: Array[Button] = []         # 卡架 3 + 武器架 1（index 0~3）
var _util_buttons: Dictionary = {}            # StringName(util) -> Button
var _cards: Array[Dictionary] = []            # 当前卡架（open/update_cards 注入）
var _weapon_card: Dictionary = {}             # 当前武器架（空 = 空架 disabled）
var _purchased: Array[bool] = [false, false, false, false]
var _reroll_used: bool = false                # 重随券每店限 1
var _maxhp_used: bool = false                 # max_hp+10 每店限 1
var _black_market: bool = false
var _wave: int = 0
var _gold: int = 0                            # 最近一次余额（refresh_gold 同步）


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	EventBus.gold_changed.connect(refresh_gold)          # 余额自刷 + 可购性重算
	EventBus.state_changed.connect(_on_state_changed)    # GAME_OVER/MENU 强制收起


func open(p_wave: int, p_black_market: bool, p_cards: Array[Dictionary],
		p_weapon: Dictionary, p_gold: int) -> void:
	# 开店（GameLoop._open_shop_flow 仲裁后调用）：注入货架 + 余额；每店限购位复位
	_wave = p_wave
	_black_market = p_black_market
	_cards = p_cards
	_weapon_card = p_weapon
	_gold = p_gold
	_purchased = [false, false, false, false]
	_reroll_used = false
	_maxhp_used = false
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


func update_cards(p_cards: Array[Dictionary]) -> void:
	# 重随货架（GameLoop 消费 reroll 申请后调用）
	_cards = p_cards
	_refresh_shelf()


func refresh_gold(p_total: int) -> void:
	# 余额刷新（gold_changed 订阅；标题 + 可购性重算）
	_gold = p_total
	_refresh_title()
	_refresh_shelf()


func shelf_state() -> Dictionary:
	# 测试观测口（当前货架/已购位/限购位/黑市标记/波号/余额）
	var purchased_copy: Array[bool] = []
	for p in _purchased:
		purchased_copy.append(p)
	return {
		"wave": _wave,
		"black_market": _black_market,
		"cards": _cards.duplicate(),
		"weapon": _weapon_card,
		"purchased": purchased_copy,
		"reroll_used": _reroll_used,
		"maxhp_used": _maxhp_used,
		"gold": _gold,
	}


func mark_purchased(p_index: int) -> void:
	# GameLoop 购买成功后调用：单次购买位 + 按钮态刷新
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
	# 定价（A4 §2）：0~2 明码卡按 rarity（黑市且 rarity==3 → 260）；3 武器架 100
	if p_index == 3:
		return WEAPON_PRICE
	var card: Dictionary = _cards[p_index] if p_index < _cards.size() else {}
	if card.is_empty():
		return -1                                # 空架不可购
	var rarity := int(card.get("rarity", 0))
	if _black_market and rarity == 3:
		return CARD_PRICE_BLACK_GOLD
	return int(CARD_PRICES.get(rarity, 0))


func _on_state_changed(p_state: int) -> void:
	# GAME_OVER/MENU 强制收起（死亡结算/回菜单不留商店浮层）
	if p_state == GameConst.GameStatus.GAME_OVER or p_state == GameConst.GameStatus.MENU:
		close()


# ── 内部：货架文本/可购性刷新 ─────────────────────────────────────
func _refresh_title() -> void:
	_title.text = "商店（金币 G%d）" % _gold


func _refresh_shelf() -> void:
	# 卡架/武器架逐项：文本 + disabled（已购 / 余额不足 / 空架）
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
	# utility：限购位 disabled
	var reroll_btn: Button = _util_buttons[&"reroll"]
	var heal_btn: Button = _util_buttons[&"heal"]
	var maxhp_btn: Button = _util_buttons[&"maxhp"]
	reroll_btn.disabled = _reroll_used or _gold < REROLL_PRICE
	_util_text(reroll_btn, &"reroll", REROLL_PRICE, "（已购）" if _reroll_used else "")
	heal_btn.disabled = _gold < HEAL_PRICE
	_util_text(heal_btn, &"heal", HEAL_PRICE, "")
	maxhp_btn.disabled = _maxhp_used or _gold < MAXHP_PRICE
	_util_text(maxhp_btn, &"maxhp", MAXHP_PRICE, "（已购）" if _maxhp_used else "")


func _shelf_text(p_card: Dictionary, p_weapon: bool, p_price: int) -> String:
	# 货架项文本：[类别] 名称 / 描述 / 价格
	var kind_name: String = "武器" if p_weapon \
		else String(["精通", "词条", "遗物", "保底", "武器"][clampi(int(p_card.get("kind", 0)), 0, 4)])
	return "[%s] %s\n%s\n价格：%d 金币" % [kind_name, String(p_card.get("display_name", "")),
		String(p_card.get("description", "")), p_price]


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


# ── 程序化 UI 组装 ────────────────────────────────────────────────
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
	_title = _add_label(_root, Vector2(0.0, 180.0), "商店（金币 G0）", 30)
	_title.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# 卡架 3（600x110 @ y=320/440/560）
	for i in range(3):
		var btn := Button.new()
		btn.name = "Card%d" % i
		btn.add_theme_font_size_override("font_size", 16)
		btn.add_theme_color_override("font_outline_color", OUTLINE_COLOR)
		btn.add_theme_constant_override("outline_size", OUTLINE_SIZE)
		btn.position = Vector2(60.0, 320.0 + 120.0 * float(i))
		btn.size = Vector2(600.0, 110.0)
		btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		btn.pressed.connect(func() -> void: purchase_requested.emit(i))
		_root.add_child(btn)
		_card_buttons.append(btn)
	# 武器架（60,680,600x100）
	var weapon_btn := Button.new()
	weapon_btn.name = "Weapon"
	weapon_btn.add_theme_font_size_override("font_size", 16)
	weapon_btn.add_theme_color_override("font_outline_color", OUTLINE_COLOR)
	weapon_btn.add_theme_constant_override("outline_size", OUTLINE_SIZE)
	weapon_btn.position = Vector2(60.0, 680.0)
	weapon_btn.size = Vector2(600.0, 100.0)
	weapon_btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	weapon_btn.pressed.connect(func() -> void: purchase_requested.emit(3))
	_root.add_child(weapon_btn)
	_card_buttons.append(weapon_btn)
	# utility 三按钮（y=820 横排）
	var utils: Array = [[&"reroll", 60.0], [&"heal", 260.0], [&"maxhp", 460.0]]
	for u in utils:
		var btn := Button.new()
		btn.name = String(u[0])
		btn.add_theme_font_size_override("font_size", 14)
		btn.add_theme_color_override("font_outline_color", OUTLINE_COLOR)
		btn.add_theme_constant_override("outline_size", OUTLINE_SIZE)
		btn.position = Vector2(float(u[1]), 820.0)
		btn.size = Vector2(180.0, 90.0)
		btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		var util: StringName = u[0]
		btn.pressed.connect(func() -> void: utility_requested.emit(util))
		_root.add_child(btn)
		_util_buttons[util] = btn
	# 离开按钮（60,1000）
	var leave := Button.new()
	leave.name = "Leave"
	leave.add_theme_font_size_override("font_size", 16)
	leave.add_theme_color_override("font_outline_color", OUTLINE_COLOR)
	leave.add_theme_constant_override("outline_size", OUTLINE_SIZE)
	leave.text = "离开商店"
	leave.position = Vector2(60.0, 1000.0)
	leave.size = Vector2(600.0, 90.0)
	leave.pressed.connect(func() -> void: close_requested.emit())
	_root.add_child(leave)


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

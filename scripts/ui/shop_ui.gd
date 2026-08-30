# scripts/ui/shop_ui.gd
# M-20 战地黑市（META_ROADMAP M7 股市商店一期落地，用户反馈「股市设定」）：
# SHOP 波事件 → GameLoop 切 LEVEL_UP 态（复用弹卡仲裁/E-16 同源）→ 本面板上架。
# 行情定价：价格 = 基价 × 品质倍率 × 行情系数（0.7~1.3，波次+槽位确定性漂移——
# ▲ 抬价避开 / ▼ 抄底）。货架 = 词条 ×2（稀有度 roll + 数值缩放与卡池同源）+
# 治疗包 + 未持有遗物（可缺）；刷新花费金币重掷。金币 = 击杀 gold_drop 掉账。
class_name ShopUi
extends CanvasLayer

signal closed()                                # → GameLoop.request_resume（LEVEL_UP → PLAYING）

var card_generator: CardGenerator = null       # 注入（词条/遗物走 apply_choice 同链路）
var _player: Node = null
var _wave: int = 0
var _root: Control = null
var _list: VBoxContainer = null
var _gold_label: Label = null
var _wares: Array[Dictionary] = []


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	_root.visible = false


func is_shop_visible() -> bool:
	# 测试观测口
	return _root != null and _root.visible


func open(p_player: Node, p_wave: int) -> void:
	_player = p_player
	_wave = p_wave
	_reroll_wares(false)
	_root.visible = true
	_refresh()


func close() -> void:
	_root.visible = false
	closed.emit()


# ── 行情与货架 ────────────────────────────────────────────────────
func market_mult(p_wave: int, p_slot: int) -> float:
	# 行情系数（确定性漂移；0.7~1.3 = ±30%，A3 §6.1 同风格收敛）
	return 1.0 + 0.3 * sin(float(p_wave * 17 + p_slot * 31))


func _reroll_wares(p_paid: bool) -> void:
	_wares.clear()
	if card_generator == null or _player == null:
		return
	var slot := 0
	for category in ["ADD", "MULT", "MECH", "ELEM"]:
		var pool := card_generator._trait_candidates(category, _player, [])
		if pool.is_empty():
			continue
		var tid: StringName = pool[randi() % pool.size()]
		var t := card_generator.registry.get_trait(tid)
		if t == null:
			continue
		var target_w := card_generator._random_owned_weapon(_player)
		var rarity := card_generator._roll_rarity(_wave)
		var scale := float(CardGenerator.RARITY_VALUE_SCALE[clampi(rarity, 0, 3)])
		var data := t.duplicate() as TraitData
		if scale > 1.0:
			data.value = t.value * scale
			data.description = card_generator._scaled_description(t.description, scale, rarity)
		_wares.append({
			"kind": "trait", "data": data, "rarity": rarity, "target": target_w,
			"base": 40.0 * float(CardGenerator.RARITY_VALUE_SCALE[clampi(rarity, 0, 3)]),
			"mult": market_mult(_wave, slot),
		})
		slot += 1
	_wares.append({
		"kind": "heal", "data": null, "rarity": 0,
		"base": 30.0, "mult": market_mult(_wave, 4),
	})
	var relics := card_generator._unowned_relic_ids()
	if not relics.is_empty():
		_wares.append({
			"kind": "relic", "data": card_generator.registry.get_relic(
				relics[randi() % relics.size()]),
			"rarity": 2, "base": 90.0, "mult": market_mult(_wave, 5),
		})


func _price(p_ware: Dictionary) -> int:
	return int(ceil(float(p_ware["base"]) * float(p_ware["mult"])))


# ── 购买 ──────────────────────────────────────────────────────────
func _buy(p_index: int) -> void:
	if p_index >= _wares.size() or _player == null:
		return
	var ware: Dictionary = _wares[p_index]
	var price := _price(ware)
	if int(_player.get("gold")) < price:
		return
	_player.set("gold", int(_player.get("gold")) - price)
	match String(ware["kind"]):
		"trait", "relic":
			var card := {
				"kind": CardGenerator.CardKind.TRAIT if String(ware["kind"]) == "trait"
					else CardGenerator.CardKind.RELIC,
				"id": ware["data"].id, "rarity": int(ware["rarity"]),
				"data": ware["data"], "value_scale": 1.0,
				"display_name": ware["data"].display_name,
				"description": ware["data"].description,
			}
			card_generator.apply_choice(card, _player)
		"heal":
			_player.set("hp", minf(float(_player.get("hp")) + float(_player.get("max_hp")) * 0.4,
				float(_player.get("max_hp"))))
	_wares[p_index] = {}                          # 售出下架
	_refresh()


func _on_refresh_pressed() -> void:
	var cost := int(ceil(15.0 * market_mult(_wave, 9)))
	if _player != null and int(_player.get("gold")) >= cost:
		_player.set("gold", int(_player.get("gold")) - cost)
		_reroll_wares(true)
		_refresh()


func _on_leave_pressed() -> void:
	close()


# ── UI 组装 ───────────────────────────────────────────────────────
func _build_ui() -> void:
	_root = Control.new()
	_root.name = "ShopRoot"
	_root.theme = StickerTheme.theme()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)
	var dim := ColorRect.new()
	dim.color = PopPalette.DIM
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(dim)
	var card := Panel.new()
	card.name = "ShopCard"
	card.add_theme_stylebox_override("panel", StickerTheme.panel_style(24.0, 4, true))
	card.position = Vector2(44.0, 150.0)
	card.size = Vector2(632.0, 950.0)
	card.pivot_offset = card.size * 0.5
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(card)
	var title := Label.new()
	StickerTheme.label_sticker(title, 30, PopPalette.INK, 0, Color.WHITE, true)
	title.text = "战地黑市"
	title.position = Vector2(0.0, 30.0)
	title.size = Vector2(632.0, 40.0)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	card.add_child(title)
	_gold_label = Label.new()
	StickerTheme.label_sticker(_gold_label, 19, PopPalette.XP, 0, Color.WHITE, true)
	_gold_label.text = "金币 0"
	_gold_label.position = Vector2(0.0, 74.0)
	_gold_label.size = Vector2(632.0, 26.0)
	_gold_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	card.add_child(_gold_label)
	var scroll := ScrollContainer.new()
	scroll.position = Vector2(28.0, 116.0)
	scroll.size = Vector2(576.0, 700.0)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	card.add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 10)
	scroll.add_child(_list)
	var refresh_btn := Button.new()
	refresh_btn.name = "ShopRefreshButton"
	refresh_btn.add_theme_font_size_override("font_size", 17)
	refresh_btn.add_theme_font_override("font", StickerTheme.font_bold())
	refresh_btn.position = Vector2(211.0, 838.0)
	refresh_btn.size = Vector2(210.0, 48.0)
	refresh_btn.pressed.connect(_on_refresh_pressed)
	refresh_btn.button_down.connect(func() -> void: StickerTheme.press_punch(refresh_btn))
	card.add_child(refresh_btn)
	var leave_btn := Button.new()
	leave_btn.name = "ShopLeaveButton"
	leave_btn.text = "出击！"
	leave_btn.add_theme_font_size_override("font_size", 20)
	leave_btn.add_theme_font_override("font", StickerTheme.font_bold())
	leave_btn.position = Vector2(211.0, 872.0)
	leave_btn.size = Vector2(210.0, 60.0)
	leave_btn.pressed.connect(_on_leave_pressed)
	leave_btn.button_down.connect(func() -> void: StickerTheme.press_punch(leave_btn))
	card.add_child(leave_btn)


func _refresh() -> void:
	_gold_label.text = "金币 %d　·　第 %d 波行情" % [int(_player.get("gold")) if _player != null else 0, _wave]
	for c in _list.get_children():
		(c as Node).queue_free()
	var idx := 0
	for ware in _wares:
		if ware.is_empty():
			idx += 1
			continue
		_list.add_child(_make_ware_row(idx, ware))
		idx += 1
	var refresh_btn := _root.get_node("ShopCard/ShopRefreshButton") as Button
	refresh_btn.text = "刷新货架 (%d)" % int(ceil(15.0 * market_mult(_wave, 9)))


func _make_ware_row(p_index: int, p_ware: Dictionary) -> Control:
	var kind := String(p_ware["kind"])
	var rarity := int(p_ware["rarity"])
	var price := _price(p_ware)
	var affordable: bool = _player != null and int(_player.get("gold")) >= price
	var row := Panel.new()
	row.add_theme_stylebox_override("panel", StickerTheme.panel_style(12.0, 2, false))
	row.custom_minimum_size = Vector2(576.0, 86.0)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var name_l := Label.new()
	StickerTheme.label_sticker(name_l, 17, PopPalette.rarity_color(rarity)
		if kind == "trait" else PopPalette.INK, 0, Color.WHITE, true)
	var display := ""
	var desc := ""
	match kind:
		"trait":
			var td: TraitData = p_ware["data"]
			var tw: Object = p_ware.get("target")
			var wtag := ("【%s】" % card_generator._weapon_short_name(tw)) if tw != null else ""
			display = wtag + String(td.display_name)
			desc = String(td.description)
		"relic":
			var rd: RelicData = p_ware["data"]
			display = String(rd.display_name) if rd != null else "遗物"
			desc = String(rd.description) if rd != null else ""
		"heal":
			display = "维修包"
			desc = "回复 40% 最大生命"
	var trend := "—"
	if float(p_ware["mult"]) > 1.08:
		trend = "▲ 行情高"
	elif float(p_ware["mult"]) < 0.92:
		trend = "▼ 行情低（抄底）"
	name_l.text = display + "　" + trend
	name_l.position = Vector2(16.0, 10.0)
	name_l.size = Vector2(400.0, 26.0)
	name_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(name_l)
	var desc_l := Label.new()
	StickerTheme.label_sticker(desc_l, 13, PopPalette.INK_SOFT)
	desc_l.text = desc
	desc_l.position = Vector2(16.0, 38.0)
	desc_l.size = Vector2(400.0, 34.0)
	desc_l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(desc_l)
	var buy := Button.new()
	buy.text = "%d 金币" % price
	buy.add_theme_font_size_override("font_size", 15)
	buy.add_theme_font_override("font", StickerTheme.font_bold())
	buy.position = Vector2(440.0, 22.0)
	buy.size = Vector2(120.0, 44.0)
	buy.focus_mode = Control.FOCUS_NONE
	buy.disabled = not affordable
	buy.pressed.connect(_buy.bind(p_index))
	buy.button_down.connect(func() -> void: StickerTheme.press_punch(buy))
	row.add_child(buy)
	return row

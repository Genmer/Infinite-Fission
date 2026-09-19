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
var _pre_boss: bool = false                    # 战前补给态（R5.12-P1：标题换「战前补给」）
var _title: Label = null
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


var _refresh_count: int = 0                    # 本次开店已刷新次数（R7：价格倍数递增）

func open(p_player: Node, p_wave: int, p_pre_boss: bool = false) -> void:
	_player = p_player
	_wave = p_wave
	_pre_boss = p_pre_boss
	if _title != null:
		_title.text = "战前补给" if p_pre_boss else "战地黑市"
	_refresh_count = 0
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
		# R37（用户反馈「黑市还有武器+经验获取这种异常 buff」）：玩家侧池词条
		# （经验/金币/磁吸/技能急速/血量上限）全局生效——混进黑市配武器前缀就是
		# 「【手枪】经验获取」错乱货。过滤：黑市只卖武器侧词条（玩家侧词条保留
		# 在升级卡池的【通用】语境）
		var clean: Array[StringName] = []
		for tid in pool:
			var td: TraitData = card_generator.registry.get_trait(tid)
			if td != null and not (td.pool_id in CardGenerator.PLAYER_SIDE_POOLS):
				clean.append(tid)
		if clean.is_empty():
			continue
		var tid2: StringName = clean[randi() % clean.size()]
		var t := card_generator.registry.get_trait(tid2)
		if t == null:
			continue
		var target_w := card_generator._random_owned_weapon(_player)
		var rarity := card_generator._roll_rarity(_wave)
		var scale := float(CardGenerator.RARITY_VALUE_SCALE[clampi(rarity, 0, 3)])
		var data := t.duplicate() as TraitData
		data.rarity = rarity                      # R38 品级字段一致化（白品不再带源金字段）
		if scale > 1.0:
			data.value = t.value * scale
			data.description = card_generator._scaled_description(t.description, scale, rarity)
		_wares.append({
			"kind": "trait", "data": data, "rarity": rarity, "target": target_w,
			"base": 40.0 * float(CardGenerator.RARITY_VALUE_SCALE[clampi(rarity, 0, 3)]),
			"mult": market_mult(_wave, slot),
		})
		slot += 1
	# R71 货架兜底（用户反馈「后期刷新黑市，没刷出东西」）：后期词条全叠满
	# stack_max → 四类别候选全空 → 货架只剩治疗包。词条槽不足 4 时补「武器强化」货
	#（未满级随机武器 level_up，Lv%d→%d）——有未满级武器则货架永远有货可刷；
	# 全武器满级才让位给治疗包/遗物
	while _wares.size() < 4:
		var up_w := _random_upgradable_weapon()
		if up_w == null:
			break                               # 全满级（真·终局）——不再补位
		var lv_now := int(up_w.get("level"))
		_wares.append({
			"kind": "weapon_up", "data": null, "rarity": 2, "target": up_w,
			"level_from": lv_now, "level_to": mini(lv_now + 1, WeaponBase.MAX_LEVEL),
			"base": 55.0, "mult": market_mult(_wave, 6 + _wares.size()),
		})
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


func _random_upgradable_weapon() -> WeaponBase:
	# 未满级武器随机取一（R71 货架兜底数据源；全满级返回 null）
	if _player == null:
		return null
	var slots: Array = _player.get("weapon_slots")
	var pool: Array[WeaponBase] = []
	for w in slots:
		if w != null and is_instance_valid(w) and (w as WeaponBase).data != null \
				and int((w as WeaponBase).get("level")) < WeaponBase.MAX_LEVEL:
			pool.append(w)
	if pool.is_empty():
		return null
	return pool[randi() % pool.size()]


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
		"weapon_up":
			# R71 兜底货：直接升 1 级（WeaponBase.level_up 封顶在 MAX_LEVEL 内）
			var up_target: Variant = ware.get("target")
			if up_target != null and is_instance_valid(up_target) \
					and up_target.has_method(&"level_up"):
				up_target.call(&"level_up")
	_wares[p_index] = {}                          # 售出下架
	_refresh()


func refresh_cost() -> int:
	# 刷新价 = 15 × 行情系数 × 1.5^已刷新次数（R7 用户反馈「应倍数提升，不该固定 15」：
	# 同一次开店内累进 15→23→34→51…，关店重置）
	return int(ceil(15.0 * market_mult(_wave, 9) * pow(1.5, float(_refresh_count))))


func _on_refresh_pressed() -> void:
	var cost := refresh_cost()
	if _player != null and int(_player.get("gold")) >= cost:
		_player.set("gold", int(_player.get("gold")) - cost)
		_refresh_count += 1
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
	_title = title
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
	refresh_btn.position = Vector2(211.0, 806.0)   # R14：原 838 与出击钮(872)重叠 14px
	refresh_btn.size = Vector2(210.0, 48.0)
	refresh_btn.pressed.connect(_on_refresh_pressed)
	refresh_btn.button_down.connect(func() -> void: StickerTheme.press_punch(refresh_btn))
	card.add_child(refresh_btn)
	var leave_btn := Button.new()
	leave_btn.name = "ShopLeaveButton"
	leave_btn.text = "出击！"
	leave_btn.add_theme_font_size_override("font_size", 20)
	leave_btn.add_theme_font_override("font", StickerTheme.font_bold())
	leave_btn.position = Vector2(211.0, 868.0)
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
	refresh_btn.text = "刷新货架 (%d)" % refresh_cost()
	# R71（用户反馈「刷新黑市没刷出东西」的另一半：金币不足时按钮静默无效——点了
	# 没有任何反馈）。与购买按钮同口径：买不起就置灰禁点（刷新价 15×1.5ⁿ 后期轻松
	# 上百金，置灰比静默吞点击诚实）
	refresh_btn.disabled = _player == null \
		or int(_player.get("gold")) < refresh_cost()


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
		"weapon_up":
			# R71 兜底货：后期词条池枯竭时的常青货（武器永远可升到 MAX_LEVEL）
			var uw := p_ware.get("target") as WeaponBase
			var uname := card_generator._weapon_short_name(uw)
			display = "武器强化【%s】" % uname
			desc = "Lv%d→Lv%d：按升级表成长（攻击/弹速等）" % [
				int(p_ware.get("level_from", 0)), int(p_ware.get("level_to", 0))]
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
	# 夜间R6：满血禁购维修包（此前满血仍可买=白花金币，无提示）
	if kind == "heal" and _player != null 			and float(_player.get("hp")) >= float(_player.get("max_hp")) - 0.5:
		buy.disabled = true
		buy.text = "已满血"
	buy.pressed.connect(_buy.bind(p_index))
	buy.button_down.connect(func() -> void: StickerTheme.press_punch(buy))
	row.add_child(buy)
	return row

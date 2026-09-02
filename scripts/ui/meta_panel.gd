# scripts/ui/meta_panel.gd
# v1.0.0 MetaPanel（A9 结晶强化面板；MENU 态宿主——不占状态机迁移，与 MenuScreen 互斥实现 =
# 全屏 dim MOUSE_FILTER_STOP 遮挡开始钮，本面板 add_child 晚于 menu_screen → 同层绘制在上）。
# GameLoop 仲裁：_on_meta_requested（仅 MENU+存档层就绪）open / 购买经 purchase_requested
# → GameLoop._on_meta_purchase（MetaStore.purchase 仲裁）成功后 refresh；清档经 wipe_requested
# （两击确认流）→ GameLoop._on_meta_wipe；state_changed 非 MENU → 强制 close。
# v1.4.0（A13 Meta 二期）：三 tab 化（0 强化 / 1 图鉴 / 2 成就）+ 图鉴三册（0 芯片 / 1 遗物 /
# 2 反应）+ 成就页 + 清档两击流。registry 经 setup 注入（图鉴 display_name/description 数据源）。
# 布局（720×1280 坐标表冻结）：
#   标题 y96 f28 TOP_WIDE 居中（文案随 tab：结晶强化/图鉴/成就）
#   余额行 (60,152) f18 左对齐（全 tab 可见；覆盖层不入 layout_rects）
#   tab 栏 3 钮 (396/486/576,146) 84x44（选中 disabled + self_modulate 高亮）
#   强化页 5 行钮 ROW_YS=[200,320,440,560,680] 600x110（仅 tab0；行序 = MetaStore.UPGRADES 表序）
#   清档钮 (60,985) 600x60（仅 tab0；「清除存档」/ armed「确认清除？」）
#   图鉴册选 3 钮 (60/265/470,206) 190x48（仅 tab1；文本含收录计数「芯片 n/12」）
#   芯片格 ×12 x=60/264/468 y=266/466/666/866 192x188（3 列×4 行；序 = registry.chips 键 String 升序；
#     seen → 名 f15 + 描述 f12 autowrap 叠层 Label；unseen 或 registry 缺失 → 「？？？/未收录」）
#   遗物格 ×11 同网格前 11 格（序 = registry.relics 键升序）
#   反应行 ×13 x60 w600 h54 y=266+i×60（序 = MetaStore.REACTIONS 表序；balance 就绪附数值段）
#   成就行 ×10 x60 w600 h74 y=210+i×82（序 = MetaStore.ACHIEVEMENTS 表序；已达成/未达成）
#   返回钮 (60,1084) 600x80（全 tab 可见）。dim ColorRect(0.06,0.07,0.12,0.96) STOP。
# layout_rects() 新口径（v1.4.0）：3 tab + 返回 + 当前页控件——tab0=10（5 行+清档）/
# tab1 芯片册=19 / 遗物册=18 / 反应册=20 / tab2=14（隐藏页控件不入列；两两无交集，
# pkg10 M22 + pkg14 C20 断言口）。is_open 语义：_opened 私有字段 + is_open() 观测口。
class_name MetaPanel
extends CanvasLayer

signal purchase_requested(p_id: StringName)   # 行钮点击（GameLoop._on_meta_purchase 仲裁）
signal close_requested()                      # 返回钮（GameLoop._close_meta_panel）
signal wipe_requested()                       # v1.4.0 清档二击（GameLoop._on_meta_wipe 仲裁）

const OUTLINE_COLOR := Color(0.0, 0.0, 0.0, 0.9)
const OUTLINE_SIZE := 4
const TITLE_POS := Vector2(0.0, 96.0)
const BALANCE_POS := Vector2(60.0, 152.0)     # v1.4.0：左对齐 x60（原 TOP_WIDE 居中）
const TAB_TITLES: Array[String] = ["结晶强化", "图鉴", "成就"]
const TAB_POSITIONS: Array[Vector2] = [Vector2(396.0, 146.0), Vector2(486.0, 146.0),
	Vector2(576.0, 146.0)]
const TAB_SIZE := Vector2(84.0, 44.0)
const ROW_SIZE := Vector2(600.0, 110.0)
const ROW_YS: Array[float] = [200.0, 320.0, 440.0, 560.0, 680.0]
const WIPE_POS := Vector2(60.0, 985.0)
const WIPE_SIZE := Vector2(600.0, 60.0)
const BOOK_LABELS: Array[String] = ["芯片", "遗物", "反应"]
const BOOK_POSITIONS: Array[Vector2] = [Vector2(60.0, 206.0), Vector2(265.0, 206.0),
	Vector2(470.0, 206.0)]
const BOOK_SIZE := Vector2(190.0, 48.0)
const CELL_COUNT := 12                        # 网格 3 列×4 行（芯片册全用；遗物册前 11 格）
const CELL_SIZE := Vector2(192.0, 188.0)
const CELL_ORIGIN := Vector2(60.0, 266.0)
const CELL_STEP := Vector2(204.0, 200.0)
const RXN_ROW_SIZE := Vector2(600.0, 54.0)
const RXN_ROW_ORIGIN_Y := 266.0
const RXN_ROW_STEP := 60.0
const ACH_ROW_SIZE := Vector2(600.0, 74.0)
const ACH_ROW_ORIGIN_Y := 210.0
const ACH_ROW_STEP := 82.0
const BACK_POS := Vector2(60.0, 1084.0)
const BACK_SIZE := Vector2(600.0, 80.0)
const DIM_COLOR := Color(0.06, 0.07, 0.12, 0.96)
const DISABLED_COLOR := Color(0.55, 0.55, 0.6)
const SELECTED_COLOR := Color(1.0, 1.0, 0.55) # v1.4.0：tab/册选中高亮（self_modulate）
const UNSEEN_TEXT := "？？？\n未收录"          # 图鉴格未收录两态文案（C21 断言锚）

var _opened: bool = false                     # 界面可见状态（is_open() 观测口）
var _store: MetaStore = null                  # open 注入（MetaStore 引用，refresh/行渲染数据源）
var _registry: DataRegistry = null            # v1.4.0 setup 注入（图鉴资源数据源）
var _tab_index: int = 0                       # 0 强化 / 1 图鉴 / 2 成就
var _book_index: int = 0                      # 图鉴册：0 芯片 / 1 遗物 / 2 反应
var _wipe_armed: bool = false                 # 清档两击确认态

var _root: Control = null
var _title_label: Label = null
var _balance_label: Label = null
var _tab_buttons: Array[Button] = []          # 3 tab 钮
var _row_buttons: Array[Button] = []          # 5 行钮（index 与 UPGRADES.keys() 表序对齐）
var _wipe_button: Button = null
var _book_buttons: Array[Button] = []         # 3 册选钮
var _cell_buttons: Array[Button] = []         # 12 图鉴格钮（名/描述叠层 Label 平行数组）
var _cell_name_labels: Array[Label] = []
var _cell_desc_labels: Array[Label] = []
var _rxn_rows: Array[Button] = []             # 13 反应行
var _ach_rows: Array[Button] = []             # 10 成就行


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	_root.visible = false
	EventBus.state_changed.connect(_on_state_changed)


func is_open() -> bool:
	# 界面开启观测口（GameLoop 购买仲裁 / 测试消费）
	return _opened


func setup(p_registry: DataRegistry) -> void:
	# v1.4.0（A13）：图鉴数据源注入（GameLoop._boot_build_presentation boot 期一次）
	_registry = p_registry


func open(p_store: MetaStore) -> void:
	# 开面板（GameLoop._on_meta_requested 仲裁后调用）：持引用 + 重置 tab/册 + 全量刷新 + 显示
	_store = p_store
	_tab_index = 0                               # v1.4.0：入口重置强化 tab
	_book_index = 0                              # v1.4.0：入口重置芯片册
	_root.visible = true
	_opened = true
	refresh()


func close() -> void:
	# 收起（返回钮 / GameLoop / state_changed 非 MENU 强制收起）+ 清档确认态复位
	_root.visible = false
	_opened = false
	_wipe_armed = false


func refresh() -> void:
	# 全量重刷（v1.4.0）：armed 复位 + 余额行 + 当前 tab 页渲染
	_wipe_armed = false
	if _store == null:
		if _balance_label != null:
			_balance_label.text = "结晶：0"
		return
	_balance_label.text = "结晶：%d" % _store.crystal
	_render_tab()


# ── 观测口（v1.4.0，pkg14 C20~C22 消费） ──────────────────────────
func current_tab() -> int:
	return _tab_index


func select_tab(p_index: int) -> void:
	# tab 切换（界内守卫；armed 复位 + 全量重渲）
	if p_index < 0 or p_index >= TAB_TITLES.size():
		return
	_tab_index = p_index
	_wipe_armed = false
	_render_tab()


func current_book() -> int:
	return _book_index


func select_book(p_index: int) -> void:
	# 册切换（界内守卫；图鉴页打开时才重渲可见性/内容）
	if p_index < 0 or p_index >= BOOK_LABELS.size():
		return
	_book_index = p_index
	if _tab_index == 1:
		_render_tab()


func cell_text(p_book: int, p_index: int) -> String:
	# 图鉴格文本观测口（p_book 0 芯片 / 1 遗物 / 2 反应行）——渲染与观测共用数据源计算
	if p_book == 2:
		return _reaction_row_text(p_index)
	return _cell_text_for(p_book, p_index)


func achievement_row_text(p_index: int) -> String:
	return _achievement_row_text(p_index)


func wipe_button_text() -> String:
	return "确认清除？" if _wipe_armed else "清除存档"


func layout_rects() -> Array[Rect2]:
	# v1.4.0 断言口：3 tab + 返回 + 当前页控件（隐藏页不入列；标题/余额为覆盖层不入列）——
	# tab0=10 / tab1 芯片册=19 / 遗物册=18 / 反应册=20 / tab2=14，两两无交集
	var out: Array[Rect2] = []
	for pos in TAB_POSITIONS:
		out.append(Rect2(pos, TAB_SIZE))
	out.append(Rect2(BACK_POS, BACK_SIZE))
	if _tab_index == 0:
		for y in ROW_YS:
			out.append(Rect2(Vector2(60.0, y), ROW_SIZE))
		out.append(Rect2(WIPE_POS, WIPE_SIZE))
	elif _tab_index == 1:
		for pos in BOOK_POSITIONS:
			out.append(Rect2(pos, BOOK_SIZE))
		if _book_index == 0:
			for i in range(CELL_COUNT):
				out.append(_cell_rect(i))
		elif _book_index == 1:
			for i in range(CELL_COUNT - 1):
				out.append(_cell_rect(i))
		else:
			for i in range(_rxn_rows.size()):
				out.append(Rect2(Vector2(60.0, RXN_ROW_ORIGIN_Y + RXN_ROW_STEP * float(i)),
					RXN_ROW_SIZE))
	else:
		for i in range(_ach_rows.size()):
			out.append(Rect2(Vector2(60.0, ACH_ROW_ORIGIN_Y + ACH_ROW_STEP * float(i)),
				ACH_ROW_SIZE))
	return out


func _on_state_changed(p_state: int) -> void:
	# 非 MENU 强制收起（开局/死亡/商店/暂停等任何状态切换不留浮层）
	if p_state != GameConst.GameStatus.MENU:
		close()


# ── 渲染（当前页） ────────────────────────────────────────────────
func _render_tab() -> void:
	if _tab_index >= 0 and _tab_index < TAB_TITLES.size():
		_title_label.text = TAB_TITLES[_tab_index]
	for i in range(_tab_buttons.size()):
		var selected := i == _tab_index
		_tab_buttons[i].disabled = selected
		_tab_buttons[i].self_modulate = SELECTED_COLOR if selected else Color(1.0, 1.0, 1.0)
	# tab0 强化页（5 行 + 清档）
	var upgrade := _tab_index == 0
	for btn in _row_buttons:
		btn.visible = upgrade
	_wipe_button.visible = upgrade
	_wipe_button.text = wipe_button_text()
	if upgrade:
		_render_upgrade_rows()
	# tab1 图鉴页（册选 + 格/行可见性与内容）
	var book := _tab_index == 1
	for btn in _book_buttons:
		btn.visible = book
	for i in range(_cell_buttons.size()):
		var active := book and (_book_index == 0 or (_book_index == 1 and i < CELL_COUNT - 1))
		_cell_buttons[i].visible = active
		_cell_name_labels[i].visible = active
		_cell_desc_labels[i].visible = active
	for btn in _rxn_rows:
		btn.visible = book and _book_index == 2
	if book:
		_render_book()
	# tab2 成就页
	var ach := _tab_index == 2
	for btn in _ach_rows:
		btn.visible = ach
	if ach:
		_render_achievements()


func _render_upgrade_rows() -> void:
	# 强化页 5 行（v1.0.0 冻结渲染：满级/余额不足 → disabled）
	var ids: Array = MetaStore.UPGRADES.keys()
	for i in range(_row_buttons.size()):
		var btn := _row_buttons[i]
		if i >= ids.size():
			btn.disabled = true
			btn.text = "-"
			continue
		var id: StringName = ids[i]
		var entry: Dictionary = MetaStore.UPGRADES[id]
		var lv := _store.level(id)
		var max_level := int(entry.get("max_level", 0))
		if _store.is_maxed(id):
			btn.disabled = true
			btn.text = "%s  Lv%d/%d\n已满级" % [String(entry.get("display", "")), lv, max_level]
			btn.self_modulate = DISABLED_COLOR
			continue
		btn.disabled = _store.crystal < _store.price(id)
		btn.text = "%s  Lv%d/%d\n%s  ·  价格 %d" % [String(entry.get("display", "")), lv,
			max_level, String(entry.get("effect_text", "")), _store.price(id)]
		btn.self_modulate = DISABLED_COLOR if btn.disabled else Color(1.0, 1.0, 1.0)


func _render_book() -> void:
	# 图鉴页：册选钮计数/高亮 + 格与反应行内容（渲染与观测口共用 _cell_text_for 等数据源计算）
	for i in range(_book_buttons.size()):
		var selected := i == _book_index
		_book_buttons[i].disabled = selected
		_book_buttons[i].self_modulate = SELECTED_COLOR if selected else Color(1.0, 1.0, 1.0)
		_book_buttons[i].text = _book_button_text(i)
	for i in range(_cell_buttons.size()):
		var lines := _cell_text_for(_book_index, i).split("\n")
		_cell_name_labels[i].text = lines[0] if lines.size() > 0 else ""
		_cell_desc_labels[i].text = lines[1] if lines.size() > 1 else ""
	for i in range(_rxn_rows.size()):
		_rxn_rows[i].text = _reaction_row_text(i)


func _render_achievements() -> void:
	for i in range(_ach_rows.size()):
		_ach_rows[i].text = _achievement_row_text(i)


# ── 文本数据源（渲染与观测口共用） ────────────────────────────────
func _cell_rect(p_index: int) -> Rect2:
	return Rect2(CELL_ORIGIN + Vector2(CELL_STEP.x * float(p_index % 3),
		CELL_STEP.y * float(int(p_index / 3.0))), CELL_SIZE)


func _cell_id(p_book: int, p_index: int) -> StringName:
	# 格 index → 资源 id（序 = 键 String 升序；界外 / registry 缺失 → &""）
	if _registry == null or p_index < 0:
		return &""
	var source: Dictionary = _registry.chips if p_book == 0 else _registry.relics
	var names: Array[String] = []
	for k in source:
		names.append(String(k))
	names.sort()
	if p_index >= names.size():
		return &""
	return StringName(names[p_index])


func _cell_text_for(p_book: int, p_index: int) -> String:
	# 格两态：seen → "display_name\ndescription"（运行时读 registry 资源）；
	# unseen / registry 缺失 / 悬空 seen 键 → UNSEEN_TEXT（A13 冻结）
	var id := _cell_id(p_book, p_index)
	if id == &"" or _store == null or _registry == null:
		return UNSEEN_TEXT
	var seen := _store.chip_seen(id) if p_book == 0 else _store.relic_seen(id)
	if not seen:
		return UNSEEN_TEXT
	var data: Object = null
	if p_book == 0:
		data = _registry.get_chip(id)
	else:
		data = _registry.get_relic(id)
	if data == null:
		return UNSEEN_TEXT
	return "%s\n%s" % [data.get("display_name"), data.get("description")]


func _book_button_text(p_book: int) -> String:
	# 册选钮计数：「芯片 n/12」/「遗物 n/11」/「反应 n/13」（registry 缺失 → 0/0）
	var label := BOOK_LABELS[p_book] if p_book >= 0 and p_book < BOOK_LABELS.size() else "?"
	var total := 0
	var seen := 0
	if p_book == 2:
		total = MetaStore.REACTIONS.size()
		if _store != null:
			for key in MetaStore.REACTIONS:
				if _store.reaction_seen(String(key)):
					seen += 1
	else:
		if _registry != null:
			var source: Dictionary = _registry.chips if p_book == 0 else _registry.relics
			total = source.size()
			if _store != null:
				for k in source:
					var id := StringName(String(k))
					var hit := _store.chip_seen(id) if p_book == 0 else _store.relic_seen(id)
					if hit:
						seen += 1
	return "%s %d/%d" % [label, seen, total]


func _reaction_row_text(p_index: int) -> String:
	# 反应行：「【group】display · pair」+ 数值段（balance 就绪才附，A13 H1）
	var ids: Array = MetaStore.REACTIONS.keys()
	if p_index < 0 or p_index >= ids.size():
		return "-"
	var id: StringName = ids[p_index]
	var entry: Dictionary = MetaStore.REACTIONS[id]
	var text := "【%s】%s · %s" % [String(entry.get("group", "")),
		String(entry.get("display", "")), String(entry.get("pair", ""))]
	var numeric := _reaction_numeric(String(id), String(entry.get("group", "")))
	if numeric != "":
		text += "  %s" % numeric
	return text


func _reaction_numeric(p_id: String, p_group: String) -> String:
	# 数值段（A13 H1 统一闸：balance 未就绪 → 不附数值、无字面量兜底）：
	# 剧变 = reaction_table 规则键投影（×coef/抗/时长/破碎/半径/CD）；增幅 = amp_*_factor；
	# 共鸣 = ElementalSystem 模块常量
	if GameConfig.balance == null:
		return ""
	var parts: Array[String] = []
	if p_group == "剧变":
		var rule: Dictionary = GameConfig.balance.reaction_table.get(
			"RXN_" + p_id.trim_prefix("rxn_").to_upper(), {})
		if rule.is_empty():
			return ""
		if rule.has("coef"):
			parts.append("×%.1f" % float(rule.get("coef")))
		if rule.has("resist_delta"):
			parts.append("抗%+.0f%%" % (float(rule.get("resist_delta")) * 100.0))
		if rule.has("duration"):
			parts.append("%.1fs" % float(rule.get("duration")))
		if rule.has("shatter_coef"):
			parts.append("破碎%.0f%%" % (float(rule.get("shatter_coef")) * 100.0))
		if rule.has("radius"):
			parts.append("半径%.0f" % float(rule.get("radius")))
		if rule.has("cd"):
			parts.append("CD%.0fs" % float(rule.get("cd")))
	elif p_group == "增幅":
		var factor: Variant = GameConfig.balance.get("amp_%s_factor" % p_id.trim_prefix("amp_"))
		if factor != null:
			parts.append("×%.1f" % float(factor))
	else:
		parts.append("2把+附着×%.2f/3把+反应×%.2f" % [ElementalSystem.RESONANCE_ATTACH_MULT,
			ElementalSystem.RESONANCE_REACTION_MULT])
	return " ".join(parts)


func _achievement_row_text(p_index: int) -> String:
	# 成就行：「『title』desc — 已达成/未达成」（序 = ACHIEVEMENTS 表序）
	var ids: Array = MetaStore.ACHIEVEMENTS.keys()
	if p_index < 0 or p_index >= ids.size():
		return "-"
	var id: StringName = ids[p_index]
	var entry: Dictionary = MetaStore.ACHIEVEMENTS[id]
	var done := _store != null and _store.has_achievement(id)
	return "『%s』%s — %s" % [String(entry.get("title", "")), String(entry.get("desc", "")),
		"已达成" if done else "未达成"]


# ── 点击回调 ──────────────────────────────────────────────────────
func _on_row_pressed(p_index: int) -> void:
	# 行钮 → purchase_requested（id 由 UPGRADES 固定表序映射；购买仲裁权在 GameLoop）
	var ids: Array = MetaStore.UPGRADES.keys()
	if p_index < 0 or p_index >= ids.size():
		return
	purchase_requested.emit(ids[p_index])


func _on_wipe_pressed() -> void:
	# v1.4.0 清档两击流：首击 armed + 文案；二击复位 + emit（仲裁权在 GameLoop._on_meta_wipe）
	_wipe_armed = not _wipe_armed
	_wipe_button.text = wipe_button_text()
	if not _wipe_armed:
		wipe_requested.emit()


# ── 程序化 UI 组装（blessing_ui.gd 模板同构） ──────────────────────
func _build_ui() -> void:
	_root = Control.new()
	_root.name = "MetaRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.visible = false
	add_child(_root)
	var dim := ColorRect.new()
	dim.name = "MetaDim"
	dim.color = DIM_COLOR
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP   # 遮挡 MenuScreen 开始钮（互斥实现）
	_root.add_child(dim)
	_title_label = _add_label(_root, TITLE_POS, TAB_TITLES[0], 28)
	_title_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# v1.4.0：余额行左对齐 x60（全 tab 可见）
	_balance_label = _add_label(_root, BALANCE_POS, "结晶：0", 18)
	for i in range(TAB_POSITIONS.size()):
		var tab_btn := _add_button("Tab%d" % i, TAB_POSITIONS[i], TAB_SIZE, 14)
		tab_btn.text = TAB_TITLES[i]
		var tab_index := i
		tab_btn.pressed.connect(func() -> void: select_tab(tab_index))
		_tab_buttons.append(tab_btn)
	for i in range(ROW_YS.size()):
		var btn := _add_button("Row%d" % i, Vector2(60.0, ROW_YS[i]), ROW_SIZE, 15)
		btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		var row_index := i
		btn.pressed.connect(func() -> void: _on_row_pressed(row_index))
		_row_buttons.append(btn)
	_wipe_button = _add_button("Wipe", WIPE_POS, WIPE_SIZE, 15)
	_wipe_button.text = wipe_button_text()
	_wipe_button.pressed.connect(_on_wipe_pressed)
	for i in range(BOOK_POSITIONS.size()):
		var book_btn := _add_button("Book%d" % i, BOOK_POSITIONS[i], BOOK_SIZE, 14)
		book_btn.text = BOOK_LABELS[i]
		var book_index := i
		book_btn.pressed.connect(func() -> void: select_book(book_index))
		_book_buttons.append(book_btn)
	for i in range(CELL_COUNT):
		# 图鉴格：钮（无文本）+ 名 f15 / 描述 f12 autowrap 叠层 Label（后加绘于上）
		var pos := CELL_ORIGIN + Vector2(CELL_STEP.x * float(i % 3),
			CELL_STEP.y * float(int(i / 3.0)))
		var cell_btn := _add_button("Cell%d" % i, pos, CELL_SIZE, 12)
		var name_label := _add_label(_root, pos + Vector2(8.0, 8.0), "", 15)
		name_label.size = Vector2(176.0, 40.0)
		var desc_label := _add_label(_root, pos + Vector2(8.0, 52.0), "", 12)
		desc_label.size = Vector2(176.0, 128.0)
		desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_cell_buttons.append(cell_btn)
		_cell_name_labels.append(name_label)
		_cell_desc_labels.append(desc_label)
	for i in range(MetaStore.REACTIONS.size()):
		var rxn_btn := _add_button("ReactionRow%d" % i,
			Vector2(60.0, RXN_ROW_ORIGIN_Y + RXN_ROW_STEP * float(i)), RXN_ROW_SIZE, 13)
		rxn_btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_rxn_rows.append(rxn_btn)
	for i in range(MetaStore.ACHIEVEMENTS.size()):
		var ach_btn := _add_button("AchRow%d" % i,
			Vector2(60.0, ACH_ROW_ORIGIN_Y + ACH_ROW_STEP * float(i)), ACH_ROW_SIZE, 13)
		ach_btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_ach_rows.append(ach_btn)
	var back_btn := _add_button("Back", BACK_POS, BACK_SIZE, 16)
	back_btn.text = "返回"
	back_btn.pressed.connect(func() -> void: close_requested.emit())


func _add_button(p_name: String, p_pos: Vector2, p_size: Vector2, p_font: int) -> Button:
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
	var label := Label.new()
	label.position = p_pos
	label.text = p_text
	label.add_theme_font_size_override("font_size", p_size)
	label.add_theme_color_override("font_outline_color", OUTLINE_COLOR)
	label.add_theme_constant_override("outline_size", OUTLINE_SIZE)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p_parent.add_child(label)
	return label

# scripts/ui/meta_panel.gd
# v1.0.0 MetaPanel（A9 结晶强化面板；MENU 态宿主——不占状态机迁移，与 MenuScreen 互斥实现 =
# 全屏 dim MOUSE_FILTER_STOP 遮挡开始钮，本面板 add_child 晚于 menu_screen → 同层绘制在上）。
# GameLoop 仲裁：_on_meta_requested（仅 MENU+存档层就绪）open / 购买经 purchase_requested
# → GameLoop._on_meta_purchase（MetaStore.purchase 仲裁）成功后 refresh；state_changed 非
# MENU → 强制 close（重开/死亡/开局不留浮层）。
# 布局（720×1280）：标题 TOP_WIDE y96 f28「结晶强化」/ 余额行 y152 f18「结晶：N」/
# 5 行钮 ROW_YS=[200,320,440,560,680]（行序 = MetaStore.UPGRADES 封闭表序）(60,y) 600x110 /
# 返回钮 (60,1084) 600x80。dim ColorRect(0.06,0.07,0.12,0.96) STOP；
# layout_rects = 6 项（5 行 + 返回）两两无交集（标题/余额为覆盖层不入列）。
# is_open 语义：_opened 私有字段 + is_open() 观测口（全文件一致）。
class_name MetaPanel
extends CanvasLayer

signal purchase_requested(p_id: StringName)   # 行钮点击（GameLoop._on_meta_purchase 仲裁）
signal close_requested()                      # 返回钮（GameLoop._close_meta_panel）

const OUTLINE_COLOR := Color(0.0, 0.0, 0.0, 0.9)
const OUTLINE_SIZE := 4
const TITLE_POS := Vector2(0.0, 96.0)
const TITLE_TEXT := "结晶强化"
const BALANCE_POS := Vector2(0.0, 152.0)
const ROW_SIZE := Vector2(600.0, 110.0)
const ROW_YS: Array[float] = [200.0, 320.0, 440.0, 560.0, 680.0]
const BACK_POS := Vector2(60.0, 1084.0)
const BACK_SIZE := Vector2(600.0, 80.0)
const DIM_COLOR := Color(0.06, 0.07, 0.12, 0.96)
const DISABLED_COLOR := Color(0.55, 0.55, 0.6)

var _opened: bool = false                     # 界面可见状态（is_open() 观测口）
var _store: MetaStore = null                  # open 注入（MetaStore 引用，refresh/行渲染数据源）

var _root: Control = null
var _balance_label: Label = null
var _row_buttons: Array[Button] = []          # 5 行钮（index 与 UPGRADES.keys() 表序对齐）


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	_root.visible = false
	EventBus.state_changed.connect(_on_state_changed)


func is_open() -> bool:
	# 界面开启观测口（GameLoop 购买仲裁 / 测试消费）
	return _opened


func open(p_store: MetaStore) -> void:
	# 开面板（GameLoop._on_meta_requested 仲裁后调用）：持引用 + 全量刷新 + 显示
	_store = p_store
	_root.visible = true
	_opened = true
	refresh()


func close() -> void:
	# 收起（返回钮 / GameLoop / state_changed 非 MENU 强制收起）
	_root.visible = false
	_opened = false


func refresh() -> void:
	# 全量重刷：余额行 + 5 行文本/禁用态（满级或结晶不足 → disabled）
	if _store == null:
		if _balance_label != null:
			_balance_label.text = "结晶：0"
		return
	_balance_label.text = "结晶：%d" % _store.crystal
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


func layout_rects() -> Array[Rect2]:
	# 布局契约断言口：5 行 + 返回（6 项两两无交集；标题/余额为覆盖层不入列）
	var out: Array[Rect2] = []
	for y in ROW_YS:
		out.append(Rect2(Vector2(60.0, y), ROW_SIZE))
	out.append(Rect2(BACK_POS, BACK_SIZE))
	return out


func _on_state_changed(p_state: int) -> void:
	# 非 MENU 强制收起（开局/死亡/商店/暂停等任何状态切换不留浮层）
	if p_state != GameConst.GameStatus.MENU:
		close()


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
	var title := _add_label(_root, TITLE_POS, TITLE_TEXT, 28)
	title.set_anchors_preset(Control.PRESET_TOP_WIDE)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_balance_label = _add_label(_root, BALANCE_POS, "结晶：0", 18)
	_balance_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_balance_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	for i in range(ROW_YS.size()):
		var btn := _add_button("Row%d" % i, Vector2(60.0, ROW_YS[i]), ROW_SIZE, 15)
		btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		var row_index := i
		btn.pressed.connect(func() -> void: _on_row_pressed(row_index))
		_row_buttons.append(btn)
	var back_btn := _add_button("Back", BACK_POS, BACK_SIZE, 16)
	back_btn.text = "返回"
	back_btn.pressed.connect(func() -> void: close_requested.emit())


func _on_row_pressed(p_index: int) -> void:
	# 行钮 → purchase_requested（id 由 UPGRADES 固定表序映射；购买仲裁权在 GameLoop）
	var ids: Array = MetaStore.UPGRADES.keys()
	if p_index < 0 or p_index >= ids.size():
		return
	purchase_requested.emit(ids[p_index])


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

# scripts/ui/blessing_ui.gd
# v0.9.0 BlessingUI（A8 §1 波次赐福三选一；复用 SHOP 态——TRANSITIONS 零改动，与 ShopUI/EventUI
# 互斥由 GameLoop 单点保证：_open_blessing_flow 仅在 PLAYING 且商店/事件/赐福均关闭时开门，
# 序列化排空——冻结序 升级→赐福→商店→事件）。
# 布局（720×1280）：标题 TOP_WIDE y300 f26「波次赐福」/ 描述 (60,360) 600x48 f14
# 「选择一项赐福（跳过得 15 金币·基础值）」/ 选项 (60,440)/(60,564)/(60,688) 600x110 / 跳过 (60,820) 600x70。
# dim ColorRect 0.86 mouse_filter=STOP（挡 HUD 冲刺键）；标题/描述不占交互矩形
# （layout_rects 仅 4 项：三选项 + 跳过，两两无交集）。
# 空 option 防御 disabled + "-"；state_changed GAME_OVER/MENU 强制收起；
# process_mode = ALWAYS（与 ShopUI/EventUI 同口径）。
class_name BlessingUI
extends CanvasLayer

signal option_chosen(option_index: int)        # 选项点击（GameLoop 仲裁）
signal skip_requested()                        # 跳过（v1.3.0 起补偿 15 金币基础值——GameLoop 仲裁）

const OUTLINE_COLOR := Color(0.0, 0.0, 0.0, 0.9)
const OUTLINE_SIZE := 4
const TITLE_POS := Vector2(0.0, 300.0)
const TITLE_TEXT := "波次赐福"
const DESC_POS := Vector2(60.0, 360.0)
const DESC_SIZE := Vector2(600.0, 48.0)
const DESC_TEXT := "选择一项赐福（跳过得 15 金币·基础值）"
const OPTION_SIZE := Vector2(600.0, 110.0)
const OPTION_POSITIONS: Array[Vector2] = [Vector2(60.0, 440.0), Vector2(60.0, 564.0), Vector2(60.0, 688.0)]
const SKIP_POS := Vector2(60.0, 820.0)
const SKIP_SIZE := Vector2(600.0, 70.0)

var is_open: bool = false                      # 界面可见状态（GameLoop 状态联动）

var _root: Control = null
var _title: Label = null
var _desc: Label = null
var _option_buttons: Array[Button] = []        # 三选项（index 0~2）
var _skip_btn: Button = null
var _options: Array[Dictionary] = []           # 当前选项（open 注入；GameLoop 仲裁读取）


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	EventBus.state_changed.connect(_on_state_changed)


func open(p_options: Array[Dictionary]) -> void:
	# 开赐福（GameLoop._open_blessing_flow 仲裁后调用）：注入选项 + 刷按钮态
	_options = p_options.duplicate()
	_root.visible = true
	is_open = true
	_refresh()


func close() -> void:
	# 收起（GameLoop._close_blessing / GAME_OVER/MENU 强制收起）
	_root.visible = false
	is_open = false
	_options = []


func current_options() -> Array[Dictionary]:
	# 测试/仲裁观测口（当前选项结构；关闭态 → []）
	return _options.duplicate(true)


func layout_rects() -> Array[Rect2]:
	# 布局契约断言口：三选项 + 跳过（4 项两两无交集；标题/描述为覆盖层不入列）
	var out: Array[Rect2] = []
	for pos in OPTION_POSITIONS:
		out.append(Rect2(pos, OPTION_SIZE))
	out.append(Rect2(SKIP_POS, SKIP_SIZE))
	return out


func _refresh() -> void:
	# 选项文本 "%s\n%s"（label/detail）+ 空 option 防御 disabled+"-"
	for i in range(_option_buttons.size()):
		var btn := _option_buttons[i]
		var option: Dictionary = _options[i] if i < _options.size() else {}
		if option.is_empty():
			btn.disabled = true
			btn.text = "-"
			btn.self_modulate = Color(0.6, 0.6, 0.65)
			continue
		btn.disabled = false
		btn.text = "%s\n%s" % [String(option.get("label", "")), String(option.get("detail", ""))]
		btn.self_modulate = Color(1.0, 1.0, 1.0)


func _on_state_changed(p_state: int) -> void:
	# GAME_OVER/MENU 强制收起（死亡结算/回菜单不留赐福浮层）
	if p_state == GameConst.GameStatus.GAME_OVER or p_state == GameConst.GameStatus.MENU:
		close()


# ── 程序化 UI 组装（event_ui.gd 模板同构） ────────────────────────
func _build_ui() -> void:
	_root = Control.new()
	_root.name = "BlessingRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.visible = false
	add_child(_root)
	var dim := ColorRect.new()
	dim.name = "BlessingDim"
	dim.color = Color(0.05, 0.03, 0.08, 0.86)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP   # 挡 HUD 冲刺键（同 ShopUI/EventUI 口径）
	_root.add_child(dim)
	_title = _add_label(_root, TITLE_POS, TITLE_TEXT, 26)
	_title.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_desc = _add_label(_root, DESC_POS, DESC_TEXT, 14)
	_desc.size = DESC_SIZE
	for i in range(OPTION_POSITIONS.size()):
		var btn := _add_button("Option%d" % i, OPTION_POSITIONS[i], OPTION_SIZE, 15)
		btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		var option_index := i
		btn.pressed.connect(func() -> void: option_chosen.emit(option_index))
		_option_buttons.append(btn)
	_skip_btn = _add_button("Skip", SKIP_POS, SKIP_SIZE, 15)
	_skip_btn.text = "跳过（+15 金币）"
	_skip_btn.pressed.connect(func() -> void: skip_requested.emit())


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

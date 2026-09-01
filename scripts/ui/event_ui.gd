# scripts/ui/event_ui.gd
# v0.8.0 EventUI（A7 §V2 事件界面；复用 SHOP 态——TRANSITIONS 零改动，EventUI 与 ShopUI
# 互斥由 GameLoop 单点保证：_open_event_flow 仅在 PLAYING 且商店关闭时开门，序列化排空）。
# 布局（720×1280）：标题 TOP_WIDE y300 f26 / 描述 y360 f16 autowrap /
# 选项A (60,520) 600x110 / 选项B (60,650) 600x110 / 离开 (60,800) 600x70。
# dim ColorRect 0.86 mouse_filter=STOP（挡 HUD 冲刺键）；标题/描述不占交互矩形
# （layout_rects 仅 3 项：两选项 + 离开，两两无交集）。
# available=false 选项 disabled + 灰显；state_changed GAME_OVER/MENU 强制收起；
# process_mode = ALWAYS（与 ShopUI 同口径）。
class_name EventUI
extends CanvasLayer

signal option_chosen(option_index: int)        # 选项点击（GameLoop 仲裁）
signal leave_requested()                       # 离开事件

const OUTLINE_COLOR := Color(0.0, 0.0, 0.0, 0.9)
const OUTLINE_SIZE := 4
const TITLE_POS := Vector2(0.0, 300.0)
const DESC_POS := Vector2(60.0, 360.0)
const DESC_SIZE := Vector2(600.0, 140.0)
const OPTION_SIZE := Vector2(600.0, 110.0)
const OPTION_POSITIONS: Array[Vector2] = [Vector2(60.0, 520.0), Vector2(60.0, 650.0)]
const LEAVE_POS := Vector2(60.0, 800.0)
const LEAVE_SIZE := Vector2(600.0, 70.0)

var is_open: bool = false                      # 界面可见状态（GameLoop 状态联动）

var _root: Control = null
var _title: Label = null
var _desc: Label = null
var _option_buttons: Array[Button] = []        # 选项 A/B（index 0/1）
var _leave_btn: Button = null
var _event: Dictionary = {}                    # 当前事件（open 注入；GameLoop.current_event 观测）


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	EventBus.state_changed.connect(_on_state_changed)


func open(p_event: Dictionary) -> void:
	# 开事件（GameLoop._open_event_flow 仲裁后调用）：注入事件结构 + 刷按钮态
	_event = p_event
	_root.visible = true
	is_open = true
	_refresh()


func close() -> void:
	# 收起（GameLoop._close_event / GAME_OVER/MENU 强制收起）
	_root.visible = false
	is_open = false
	_event = {}


func current_event() -> Dictionary:
	# 测试观测口（当前事件结构；关闭态 → {}）
	return _event.duplicate(true)


func layout_rects() -> Array[Rect2]:
	# 布局契约断言口：两选项 + 离开（3 项两两无交集；标题/描述为覆盖层不入列）
	var out: Array[Rect2] = []
	for pos in OPTION_POSITIONS:
		out.append(Rect2(pos, OPTION_SIZE))
	out.append(Rect2(LEAVE_POS, LEAVE_SIZE))
	return out


func _refresh() -> void:
	# 标题/描述/按钮文本 + available 灰显（options[].available == false → disabled）
	_title.text = String(_event.get("title", ""))
	_desc.text = String(_event.get("desc", ""))
	var options: Array = _event.get("options", [])
	for i in range(_option_buttons.size()):
		var btn := _option_buttons[i]
		var option: Dictionary = options[i] if i < options.size() else {}
		if option.is_empty():
			btn.disabled = true
			btn.text = "-"
			btn.self_modulate = Color(0.6, 0.6, 0.65)
			continue
		btn.text = "%s\n%s" % [String(option.get("label", "")),
			String(option.get("detail", ""))]
		var available := bool(option.get("available", true))
		btn.disabled = not available
		btn.self_modulate = Color(1.0, 1.0, 1.0) if available else Color(0.45, 0.45, 0.5)


func _on_state_changed(p_state: int) -> void:
	# GAME_OVER/MENU 强制收起（死亡结算/回菜单不留事件浮层）
	if p_state == GameConst.GameStatus.GAME_OVER or p_state == GameConst.GameStatus.MENU:
		close()


# ── 程序化 UI 组装 ────────────────────────────────────────────────
func _build_ui() -> void:
	_root = Control.new()
	_root.name = "EventRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.visible = false
	add_child(_root)
	var dim := ColorRect.new()
	dim.name = "EventDim"
	dim.color = Color(0.05, 0.03, 0.08, 0.86)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP   # 挡 HUD 冲刺键（同 ShopUI v0.8.0 口径）
	_root.add_child(dim)
	_title = _add_label(_root, TITLE_POS, "", 26)
	_title.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_desc = _add_label(_root, DESC_POS, "", 16)
	_desc.size = DESC_SIZE
	_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	for i in range(OPTION_POSITIONS.size()):
		var btn := _add_button("Option%d" % i, OPTION_POSITIONS[i], OPTION_SIZE, 15)
		btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		var option_index := i
		btn.pressed.connect(func() -> void: option_chosen.emit(option_index))
		_option_buttons.append(btn)
	_leave_btn = _add_button("Leave", LEAVE_POS, LEAVE_SIZE, 15)
	_leave_btn.text = "离开"
	_leave_btn.pressed.connect(func() -> void: leave_requested.emit())


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

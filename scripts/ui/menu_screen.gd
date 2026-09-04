# scripts/ui/menu_screen.gd
# 集成包 A：主菜单屏（MENU 状态宿主；程序化占位美术）→ v0.8.0 选角（A7 §V18）。
# GameLoop 状态机（迁移矩阵冻结）MENU → PLAYING 唯一入口 start_run()——本屏仅申请：
# start_requested() 信号（无参签名冻结：pkg5:110 / perf:71 / soak:62 无参 emit 兼容）
# → GameLoop.start_run(&"")（仲裁权在 GameLoop，E-16 同源；菜单选中由 GameLoop 侧读取）。
# 选角：setup(registry) 注入角色表 → 角色卡×3 (48,340)/(264,340)/(480,340) 192x240
#（名 f20 + 描述 autowrap f13；registry.characters 空 → 单「默认」卡 selected=&""）；
# 点击 = set_selection（选中高亮）；selected_character_id() = 当前选中（id 排序首为默认）。
# 布局：标题 y200 / 副标题 y260 / 开始按钮 (280,640) 文案「开始出击」。
# v1.0.0（A9）：局外战绩统计行 (0,712) f14 + 结晶强化入口钮 (280,752) 160x56
#「结晶强化」→ meta_requested（GameLoop 仅 MENU 态仲裁开 MetaPanel）。
# 可见性绑定 state_changed（仅 MENU 显示）；process_mode = ALWAYS（Q-14）。
class_name MenuScreen
extends CanvasLayer

signal start_requested()                      # → GameLoop.start_run()（MENU → PLAYING）
signal meta_requested()                       # v1.0.0：结晶强化面板申请（A9，GameLoop 仲裁）

const OUTLINE_COLOR := Color(0.0, 0.0, 0.0, 0.9)
const OUTLINE_SIZE := 4
const CARD_SIZE := Vector2(192.0, 240.0)
const CARD_POSITIONS: Array[Vector2] = [
	Vector2(48.0, 340.0), Vector2(264.0, 340.0), Vector2(480.0, 340.0),
]
const SELECT_COLOR := Color(0.35, 0.9, 1.0)
const IDLE_COLOR := Color(0.62, 0.62, 0.68)

var _registry: DataRegistry = null            # setup 注入（角色 id → CharacterData）
var _root: Control = null
var _start_btn: Button = null
var _stats_label: Label = null                # v1.0.0：局外战绩统计行（set_meta_summary 回写）
var _meta_btn: Button = null                  # v1.0.0：结晶强化入口钮
var _card_buttons: Array[Button] = []         # 角色卡（index 与 _ids 对齐）
var _ids: Array[StringName] = []              # 卡序（registry.characters 按 id 排序；空表 → [&""]）
var _selected: int = 0                        # 当前选中卡 index


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	_root.visible = false
	EventBus.state_changed.connect(_on_state_changed)


func setup(p_registry: DataRegistry) -> void:
	# v0.8.0：角色表注入（GameLoop._boot_build_presentation 调用；重建角色卡）
	_registry = p_registry
	_ids.clear()
	if _registry != null and not _registry.characters.is_empty():
		var sorted: Array[StringName] = []
		for id in _registry.characters:
			sorted.append(id)
		# ★ StringName 直排按内部指针序不稳定——按字符串字典序（id 排序首 = 默认选中）
		sorted.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))
		_ids = sorted
	else:
		_ids.append(&"")                        # registry 空 → 单「默认」卡（&"" 兜底口径）
	_selected = 0
	_rebuild_cards()


func selected_character_id() -> StringName:
	# 当前选中角色 id（空表/默认卡 → &""；GameLoop.start_run 空参读此值）
	if _selected < 0 or _selected >= _ids.size():
		return &""
	return _ids[_selected]


func set_selection(p_index: int) -> void:
	# 选角（点击卡回调；越界钳制）
	_selected = clampi(p_index, 0, maxi(_ids.size() - 1, 0))
	_refresh_cards()


func set_meta_summary(p_best_wave: int, p_total_runs: int, p_total_kills: int, p_crystal: int) -> void:
	# v1.0.0（A9）：局外统计行回写（GameLoop._refresh_menu_meta 消费；四段文本契约）
	_stats_label.text = "最佳波次 %d · 总局数 %d · 累计击杀 %d · 结晶 %d" \
		% [p_best_wave, p_total_runs, p_total_kills, p_crystal]


func _on_state_changed(p_state: int) -> void:
	# 仅 MENU 态显示（PLAYING/LEVEL_UP/PAUSED/GAME_OVER 均隐藏）
	_root.visible = p_state == GameConst.GameStatus.MENU


func _build_ui() -> void:
	# 程序化占位：标题 + 副标题 + 角色卡容器 + 开始按钮
	_root = Control.new()
	_root.name = "MenuRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)
	var bg := ColorRect.new()
	bg.name = "MenuBg"
	bg.color = Color(0.06, 0.07, 0.12, 0.96)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(bg)
	var title := Label.new()
	title.text = "INFINITE FISSION"
	title.add_theme_font_size_override("font_size", 40)
	title.set_anchors_preset(Control.PRESET_TOP_WIDE)
	title.position = Vector2(0.0, 200.0)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root.add_child(title)
	var subtitle := Label.new()
	subtitle.text = "弹幕防御 · Roguelike"
	subtitle.add_theme_font_size_override("font_size", 18)
	subtitle.set_anchors_preset(Control.PRESET_TOP_WIDE)
	subtitle.position = Vector2(0.0, 260.0)
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root.add_child(subtitle)
	_start_btn = Button.new()
	_start_btn.text = "开始出击"
	_start_btn.add_theme_font_size_override("font_size", 24)
	_start_btn.position = Vector2(280.0, 640.0)
	_start_btn.size = Vector2(160.0, 60.0)
	_start_btn.pressed.connect(_on_start_pressed)
	_root.add_child(_start_btn)
	# v1.0.0（A9）：局外战绩统计行（开始钮 640~700 下方）+ 结晶强化入口钮
	_stats_label = Label.new()
	_stats_label.text = "最佳波次 %d · 总局数 %d · 累计击杀 %d · 结晶 %d" % [0, 0, 0, 0]
	_stats_label.add_theme_font_size_override("font_size", 14)
	_stats_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_stats_label.position = Vector2(0.0, 712.0)
	_stats_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_stats_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_stats_label)
	_meta_btn = Button.new()
	_meta_btn.text = "结晶强化"
	_meta_btn.add_theme_font_size_override("font_size", 16)
	_meta_btn.position = Vector2(280.0, 752.0)
	_meta_btn.size = Vector2(160.0, 56.0)
	_meta_btn.pressed.connect(func() -> void: meta_requested.emit())
	_root.add_child(_meta_btn)


func _rebuild_cards() -> void:
	# 角色卡重建（setup 时调用；旧卡清除）。卡 = Button（交互宿主）+ 名 Label(f20) +
	# 描述 Label(f13 autowrap)——占位美术：名/描述为子标签，Button 本体无文本。
	for btn in _card_buttons:
		if is_instance_valid(btn):
			btn.queue_free()
	_card_buttons.clear()
	for i in range(mini(_ids.size(), CARD_POSITIONS.size())):
		var btn := Button.new()
		btn.name = "CharCard%d" % i
		btn.position = CARD_POSITIONS[i]
		btn.size = CARD_SIZE
		var card_index := i
		btn.pressed.connect(func() -> void: set_selection(card_index))
		_root.add_child(btn)
		var data := _registry.get_character(_ids[i]) if _registry != null else null
		var name_label := Label.new()
		name_label.text = String(data.display_name) if data != null else "默认"
		name_label.add_theme_font_size_override("font_size", 20)
		name_label.add_theme_color_override("font_outline_color", OUTLINE_COLOR)
		name_label.add_theme_constant_override("outline_size", OUTLINE_SIZE)
		name_label.position = Vector2(12.0, 14.0)
		name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		btn.add_child(name_label)
		var desc_label := Label.new()
		desc_label.text = String(data.description) if data != null else "标准配置"
		desc_label.add_theme_font_size_override("font_size", 13)
		desc_label.position = Vector2(12.0, 52.0)
		desc_label.size = Vector2(CARD_SIZE.x - 24.0, CARD_SIZE.y - 64.0)
		desc_label.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
		desc_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		btn.add_child(desc_label)
		_card_buttons.append(btn)
	_refresh_cards()


func _refresh_cards() -> void:
	# 选中高亮（自绘调制色，占位美术口径）
	for i in range(_card_buttons.size()):
		(_card_buttons[i] as Button).self_modulate = \
			SELECT_COLOR if i == _selected else IDLE_COLOR


func _on_start_pressed() -> void:
	start_requested.emit()


func is_menu_visible() -> bool:
	# 测试观测口
	return _root != null and _root.visible

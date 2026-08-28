# scripts/cards/card_select_ui.gd
# M-17 CardSelectUI（架构 §2.16）：选卡界面。
# process_mode = ALWAYS（tree.paused 冻结战斗时界面可用，AC-16.2）；仅 LEVEL_UP 状态可见。
# open()：GameLoop 仲裁后调用（E-16：死亡优先，GameOver 丢弃升级请求）；choice_made →
# CardGenerator.apply_choice → EventBus.emit_card_chosen → close() 请求恢复 → GameLoop 回 PLAYING。
# 程序化占位美术（Button + Label；正式美术后续迭代）。
class_name CardSelectUI
extends CanvasLayer

signal choice_made(card: Dictionary)          # → CardGenerator.apply_choice → card_chosen 事件

var is_open: bool = false                     # 界面可见状态（GameLoop 状态联动）

var _root: Control = null
var _buttons: Array[Button] = []
var _cards: Array[Dictionary] = []            # 当前货架（open 注入）
var _title: Label = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()


func open(p_candidates: Array[Dictionary]) -> void:
	# 展示三选一货架（candidates 由 CardGenerator.generate_candidates 产出）
	_cards = p_candidates
	for i in range(_buttons.size()):
		var card: Dictionary = _cards[i] if i < _cards.size() else {}
		_setup_button(_buttons[i], card)
	_root.visible = true
	is_open = true


func close() -> void:
	# 选卡完成收起（GameLoop 切回 PLAYING 时调用）
	_root.visible = false
	is_open = false
	_cards = []


func choose(p_index: int) -> void:
	# 选择入口（按钮 pressed / 测试直调）；无效索引忽略
	if not is_open or p_index < 0 or p_index >= _cards.size():
		return
	var card := _cards[p_index]
	choice_made.emit(card)


func candidate_count() -> int:
	# 测试观测口
	return _cards.size()


func _on_pressed(p_index: int) -> void:
	choose(p_index)


func _setup_button(p_btn: Button, p_card: Dictionary) -> void:
	# 卡面文本（名称 + 描述 + 类别行）
	if p_card.is_empty():
		p_btn.text = "-"
		p_btn.disabled = true
		return
	p_btn.disabled = false
	var kind_name: String = ["精通", "词条", "遗物", "保底"][clampi(int(p_card.get("kind", 0)), 0, 3)]
	p_btn.text = "[%s] %s\n%s" % [kind_name, String(p_card.get("display_name", "")), String(p_card.get("description", ""))]


func _build_ui() -> void:
	# 程序化三卡竖排（720×1280 竖屏中带）
	_root = Control.new()
	_root.name = "CardSelectRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.visible = false
	add_child(_root)
	var dim := ColorRect.new()
	dim.color = Color(0.04, 0.04, 0.09, 0.86)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(dim)
	_title = Label.new()
	_title.text = "升级！选择一项"
	_title.add_theme_font_size_override("font_size", 26)
	_title.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_title.position = Vector2(0.0, 300.0)
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root.add_child(_title)
	for i in range(3):
		var btn := Button.new()
		btn.name = "Card%d" % i
		btn.add_theme_font_size_override("font_size", 16)
		btn.position = Vector2(60.0, 380.0 + 200.0 * float(i))
		btn.size = Vector2(600.0, 176.0)
		btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		btn.pressed.connect(_on_pressed.bind(i))
		_root.add_child(btn)
		_buttons.append(btn)

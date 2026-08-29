# scripts/cards/card_select_ui.gd
# M-17 CardSelectUI（架构 §2.16）：选卡界面。方向 B 重设计 = 终端文件列表：
# 标题「> SELECT UPGRADE MODULE」；卡片 = 描边框（稀有度磷光亮度着色）+ 类型代号
# [ADD]/[MULT]/[MECH]/[ELEM]（词条池类）与 [WPN]/[REL]/[BASE]（形态特例）。
# process_mode = ALWAYS（tree.paused 冻结战斗时界面可用，AC-16.2）；仅 LEVEL_UP 状态可见。
# open()：GameLoop 仲裁后调用（E-16：死亡优先，GameOver 丢弃升级请求）；choice_made →
# CardGenerator.apply_choice → EventBus.emit_card_chosen → close() 请求恢复 → GameLoop 回 PLAYING。
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
	layer = TerminalTheme.UI_LAYER               # CRT 氛围层(4)之上——扫描线不压选卡文字
	_build_ui()


func open(p_candidates: Array[Dictionary]) -> void:
	# 展示三选一货架（candidates 由 CardGenerator.generate_candidates 产出）
	_cards = p_candidates
	for i in range(_buttons.size()):
		var card: Dictionary = _cards[i] if i < _cards.size() else {}
		_setup_button(_buttons[i], card)
		# REL_GAMBLER 四选一：按钮 4 仅在货架 ≥4 张时可见（三选一时隐藏占位）
		_buttons[i].visible = i < _cards.size()
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
	# 卡面文本（类型代号 + 名称 + 描述）+ 稀有度磷光描边
	if p_card.is_empty():
		p_btn.text = "-"
		p_btn.disabled = true
		return
	p_btn.disabled = false
	var kind: int = int(p_card.get("kind", 0))
	var code := _type_code(p_card)
	p_btn.text = "%s %s\n%s" % [code, String(p_card.get("display_name", "")), String(p_card.get("description", ""))]
	var rarity: int = int(p_card.get("rarity", 0))
	var edge := Palette.rarity_color(rarity)
	p_btn.add_theme_stylebox_override("normal", TerminalTheme.panel_box(edge))
	p_btn.add_theme_stylebox_override("hover", TerminalTheme.panel_box(Palette.AMBER))
	p_btn.add_theme_stylebox_override("pressed", TerminalTheme.panel_box(edge, Color(edge.r, edge.g, edge.b, 0.14)))
	p_btn.add_theme_color_override("font_color", Palette.TEXT_BODY)
	p_btn.add_theme_color_override("font_hover_color", Palette.AMBER)
	p_btn.add_theme_color_override("font_pressed_color", Palette.PHOS)


func _type_code(p_card: Dictionary) -> String:
	# 类型代号：词条按池类（ADD/MULT/MECH/ELEM）；形态特例 WPN/REL/BASE
	var kind: int = int(p_card.get("kind", 0))
	match kind:
		0:
			return Lore.CODE_MASTERY
		2:
			return Lore.CODE_RELIC
		3:
			return Lore.CODE_FALLBACK
		_:
			var data_v: Variant = p_card.get("data", null)
			if data_v is TraitData:
				match (data_v as TraitData).pool:
					GameConst.PoolClass.ADD:
						return "[ADD]"
					GameConst.PoolClass.MULT:
						return "[MULT]"
					GameConst.PoolClass.MECH:
						return "[MECH]"
					GameConst.PoolClass.ELEM:
						return "[ELEM]"
					_:
						return "[LOCAL]"
			return "[MULT]"


func _build_ui() -> void:
	# 终端文件列表：暗底 + 提示行 + 4 卡槽位（REL_GAMBLER 四选一上限；open() 按货架数显隐）
	_root = Control.new()
	_root.name = "CardSelectRoot"
	_root.theme = TerminalTheme.theme()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.visible = false
	add_child(_root)
	var dim := ColorRect.new()
	dim.color = Color(Palette.BG.r, Palette.BG.g, Palette.BG.b, 0.90)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(dim)
	_title = Label.new()
	_title.text = Lore.CARD_TITLE
	_title.add_theme_font_size_override("font_size", TerminalTheme.SIZE_KEY)
	TerminalTheme.style_key_label(_title)        # 选卡标题：字重 800 + 6px 描边
	_title.add_theme_color_override("font_color", Palette.PHOS)
	_title.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_title.position = Vector2(0.0, 300.0)
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root.add_child(_title)
	# 4 卡槽位（REL_GAMBLER 四选一上限；open() 按货架数显隐——三选一时第 4 槽隐藏）
	# 卡面字号 = 正文档 18px（描述可读下限）；描边走 Theme Button 默认（近黑 4px）
	for i in range(4):
		var btn := Button.new()
		btn.name = "Card%d" % i
		btn.add_theme_font_size_override("font_size", TerminalTheme.SIZE_BODY)
		btn.position = Vector2(60.0, 370.0 + 190.0 * float(i))
		btn.size = Vector2(600.0, 170.0)
		btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		btn.pressed.connect(_on_pressed.bind(i))
		_root.add_child(btn)
		_buttons.append(btn)

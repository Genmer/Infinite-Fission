# scripts/ui/game_over_screen.gd
# M-16 GameOverScreen（架构 §1.4/§2.1）：结算界面（本局统计：击杀数/波次/造成的总伤害）。
# 方向 B 重设计 =「// SESSION TERMINATED」终端战报：链式反应未被阻止 + 战报行
#（summary_text() 含「击杀」——pkg5 断言锚点，不改）+ 随机引言 + [ 重启协议 ]。
# 订阅 state_changed → GAME_OVER 显示；数据源 HUD 统计（注入）。
# 重开申请：GameLoop.restart_run()（GAME_OVER → MENU/PLAYING，迁移矩阵仲裁）。
class_name GameOverScreen
extends CanvasLayer

signal restart_requested()                    # → GameLoop 重开申请（迁移矩阵仲裁）

var stats_source: Node = null                 # 注入（HUD：kills/wave/total_damage）

var _root: Control = null
var _summary_label: Label = null
var _quote_label: Label = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	EventBus.state_changed.connect(_on_state_changed)


func setup(p_stats_source: Node) -> void:
	# 数据源注入（HUD）
	stats_source = p_stats_source


func show_summary() -> void:
	# 显示结算（击杀/波次/总伤害；AC-16.1）+ 随机结语引言（Lore 单源）
	if stats_source != null and is_instance_valid(stats_source):
		var kills: int = stats_source.get("kills")
		var wave: int = stats_source.get("wave")
		var dmg: float = stats_source.get("total_damage")
		_summary_label.text = Lore.battle_report(wave, kills, dmg)
	else:
		_summary_label.text = Lore.battle_report(0, 0, 0.0)
	_quote_label.text = "> " + Lore.random_quote()
	_root.visible = true


func hide_screen() -> void:
	_root.visible = false


func summary_text() -> String:
	# 测试观测口（含「击杀」锚点）
	return _summary_label.text


func request_restart() -> void:
	# 重开按钮回调（程序化 Button pressed）
	restart_requested.emit()


func _on_state_changed(p_state: int) -> void:
	if p_state == GameConst.GameStatus.GAME_OVER:
		show_summary()
	else:
		hide_screen()


func _build_ui() -> void:
	# 终端战报：暗底 + 标题 + 战报行 + 引言 + [ 重启协议 ]
	_root = Control.new()
	_root.name = "GameOverRoot"
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
	var title := Label.new()
	title.text = Lore.GAME_OVER_TITLE
	title.add_theme_font_size_override("font_size", TerminalTheme.SIZE_SECTION + 12)
	title.add_theme_color_override("font_color", Palette.HOT_RED)
	title.set_anchors_preset(Control.PRESET_TOP_WIDE)
	title.position = Vector2(0.0, 400.0)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root.add_child(title)
	var line := Label.new()
	line.text = Lore.GAME_OVER_LINE
	line.add_theme_font_size_override("font_size", TerminalTheme.SIZE_BODY + 2)
	line.add_theme_color_override("font_color", Palette.TEXT_BODY)
	line.set_anchors_preset(Control.PRESET_TOP_WIDE)
	line.position = Vector2(0.0, 462.0)
	line.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root.add_child(line)
	_summary_label = Label.new()
	_summary_label.text = ""
	_summary_label.add_theme_font_size_override("font_size", TerminalTheme.SIZE_BODY + 1)
	_summary_label.add_theme_color_override("font_color", Palette.PHOS)
	_summary_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_summary_label.position = Vector2(0.0, 500.0)
	_summary_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root.add_child(_summary_label)
	_quote_label = Label.new()
	_quote_label.text = ""
	_quote_label.add_theme_font_size_override("font_size", TerminalTheme.SIZE_LOG + 1)
	_quote_label.add_theme_color_override("font_color", Palette.TEXT_DIM)
	_quote_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_quote_label.position = Vector2(0.0, 536.0)
	_quote_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root.add_child(_quote_label)
	var btn := Button.new()
	btn.text = Lore.RESTART_BUTTON
	btn.position = Vector2(280.0, 600.0)
	btn.size = Vector2(160.0, 54.0)
	btn.pressed.connect(request_restart)
	_root.add_child(btn)

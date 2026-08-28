# scripts/ui/game_over_screen.gd
# M-16 GameOverScreen（架构 §1.4/§2.1）：结算界面（本局统计：击杀数/波次/造成的总伤害）。
# 订阅 state_changed → GAME_OVER 显示；数据源 HUD 统计（注入）。程序化占位美术。
# 重开申请：GameLoop.restart_run()（GAME_OVER → MENU/PLAYING，迁移矩阵仲裁）。
class_name GameOverScreen
extends CanvasLayer

signal restart_requested()                    # → GameLoop 重开申请（迁移矩阵仲裁）

var stats_source: Node = null                 # 注入（HUD：kills/wave/total_damage）

var _root: Control = null
var _summary_label: Label = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	EventBus.state_changed.connect(_on_state_changed)


func setup(p_stats_source: Node) -> void:
	# 数据源注入（HUD）
	stats_source = p_stats_source


func show_summary() -> void:
	# 显示结算（击杀/波次/总伤害；AC-16.1）
	if stats_source != null and is_instance_valid(stats_source):
		var kills: int = stats_source.get("kills")
		var wave: int = stats_source.get("wave")
		var dmg: float = stats_source.get("total_damage")
		_summary_label.text = "击杀 %d　波次 %d　总伤害 %d" % [kills, wave, int(dmg)]
	else:
		_summary_label.text = "击杀 -　波次 -　总伤害 -"
	_root.visible = true


func hide_screen() -> void:
	_root.visible = false


func summary_text() -> String:
	# 测试观测口
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
	_root = Control.new()
	_root.name = "GameOverRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.visible = false
	add_child(_root)
	var dim := ColorRect.new()
	dim.color = Color(0.05, 0.05, 0.08, 0.82)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(dim)
	var title := Label.new()
	title.text = "GAME OVER"
	title.add_theme_font_size_override("font_size", 34)
	title.set_anchors_preset(Control.PRESET_TOP_WIDE)
	title.position = Vector2(0.0, 420.0)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root.add_child(title)
	_summary_label = Label.new()
	_summary_label.text = ""
	_summary_label.add_theme_font_size_override("font_size", 17)
	_summary_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_summary_label.position = Vector2(0.0, 490.0)
	_summary_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root.add_child(_summary_label)
	var btn := Button.new()
	btn.text = "重新开始"
	btn.add_theme_font_size_override("font_size", 18)
	btn.position = Vector2(280.0, 560.0)
	btn.size = Vector2(160.0, 52.0)
	btn.pressed.connect(request_restart)
	_root.add_child(btn)

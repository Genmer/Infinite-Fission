# scripts/ui/game_over_screen.gd
# M-16 GameOverScreen（架构 §1.4/§2.1）：结算界面（本局统计：击杀数/波次/造成的总伤害）。
# 方向 A 重做：深空压暗层 + 警报标题「链式反应未被阻止。」+ 随机引言（Lore 单源轮换）
# + 等宽统计卡 +「重启协议」按钮。订阅 state_changed → GAME_OVER 显示；数据源 HUD 注入。
# 重开申请：GameLoop.restart_run()（GAME_OVER → MENU/PLAYING，迁移矩阵仲裁）。
class_name GameOverScreen
extends CanvasLayer

signal restart_requested()                    # → GameLoop 重开申请（迁移矩阵仲裁）

var stats_source: Node = null                 # 注入（HUD：kills/wave/total_damage）

var _root: Control = null
var _summary_label: Label = null
var _quote_label: Label = null
var _quote_index: int = 0                     # 引言轮换（结算次数递增——稳定取行）

const LAYER_ORDER := 40


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = LAYER_ORDER
	_build_ui()
	_root.visible = false                     # 初始隐藏（仅 GAME_OVER 态显示）
	EventBus.state_changed.connect(_on_state_changed)


func setup(p_stats_source: Node) -> void:
	# 数据源注入（HUD）
	stats_source = p_stats_source


func show_summary() -> void:
	# 显示结算（击杀/波次/总伤害；AC-16.1）+ 引言轮换
	if stats_source != null and is_instance_valid(stats_source):
		var kills: int = stats_source.get("kills")
		var wave: int = stats_source.get("wave")
		var dmg: float = stats_source.get("total_damage")
		_summary_label.text = "击杀 %d　波次 %d　总伤害 %d" % [kills, wave, int(dmg)]
	else:
		_summary_label.text = "击杀 -　波次 -　总伤害 -"
	_quote_label.text = Lore.gameover_quote(_quote_index)
	_quote_index += 1
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
	UITheme.apply_theme(_root)
	add_child(_root)
	# 深空压暗层（红移底部——堆芯失守氛围）
	var dim := ColorRect.new()
	dim.color = Color(0.03, 0.02, 0.05, 0.86)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(dim)
	var dim_bottom := ColorRect.new()
	dim_bottom.color = Color(Palette.RED, 0.07)
	dim_bottom.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	dim_bottom.offset_top = -420.0
	dim_bottom.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(dim_bottom)
	# 中央统计卡（玻璃面板）
	var card := UITheme.make_glass_panel(Palette.RED)
	card.name = "SummaryCard"
	card.position = Vector2(90.0, 430.0)
	card.size = Vector2(540.0, 300.0)
	_root.add_child(card)
	# 标题（链式反应未被阻止。）
	var title := UITheme.make_label(Lore.GAMEOVER_TITLE, Palette.FONT_TITLE, Palette.RED)
	title.name = "Title"
	title.add_theme_font_override("font", UITheme.font_title())
	title.set_anchors_preset(Control.PRESET_TOP_WIDE)
	title.position = Vector2(0.0, 480.0)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root.add_child(title)
	# 引言（轮换）
	_quote_label = UITheme.make_label("", Palette.FONT_BODY, Palette.TEXT_DIM)
	_quote_label.name = "Quote"
	_quote_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_quote_label.position = Vector2(0.0, 530.0)
	_quote_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root.add_child(_quote_label)
	# 分隔线
	var divider := ColorRect.new()
	divider.color = Color(Palette.RED, 0.35)
	divider.position = Vector2(260.0, 566.0)
	divider.size = Vector2(200.0, 1.0)
	divider.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(divider)
	# 统计（等宽；文本含「击杀」为测试锁定口径）
	_summary_label = UITheme.make_label("", Palette.FONT_NUM, Palette.TEXT_MAIN, true)
	_summary_label.name = "Summary"
	_summary_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_summary_label.position = Vector2(0.0, 600.0)
	_summary_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root.add_child(_summary_label)
	# 重启协议按钮
	var btn := Button.new()
	btn.name = "RestartButton"
	btn.text = Lore.GAMEOVER_RESTART
	btn.add_theme_font_size_override("font_size", 18)
	btn.position = Vector2(360.0 - 130.0, 660.0)
	btn.size = Vector2(260.0, 56.0)
	btn.pressed.connect(request_restart)
	_root.add_child(btn)

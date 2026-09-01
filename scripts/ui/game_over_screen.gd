# scripts/ui/game_over_screen.gd
# M-16 GameOverScreen（架构 §1.4/§2.1）：结算界面（本局统计：击杀数/波次/造成的总伤害）。
# 订阅 state_changed → GAME_OVER 显示；数据源 HUD 统计（注入）。程序化占位美术。
# 重开申请：GameLoop.restart_run()（GAME_OVER → MENU/PLAYING，迁移矩阵仲裁）。
class_name GameOverScreen
extends CanvasLayer

signal restart_requested()                    # → GameLoop 重开申请（迁移矩阵仲裁）
signal menu_requested()                       # v0.8.0：返回选角申请（GAME_OVER → MENU，迁移矩阵仲裁）

var stats_source: Node = null                 # 注入（HUD：kills/wave/total_damage）

var _root: Control = null
var _summary_label: Label = null
var _reaction_label: Label = null             # v0.7.0 U10：反应统计行


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	EventBus.state_changed.connect(_on_state_changed)


func setup(p_stats_source: Node) -> void:
	# 数据源注入（HUD）
	stats_source = p_stats_source


func show_summary() -> void:
	# 显示结算（击杀/波次/总伤害；AC-16.1）+ 反应统计行（v0.7.0 U10）
	if stats_source != null and is_instance_valid(stats_source):
		var kills: int = stats_source.get("kills")
		var wave: int = stats_source.get("wave")
		var dmg: float = stats_source.get("total_damage")
		_summary_label.text = "击杀 %d　波次 %d　总伤害 %d" % [kills, wave, int(dmg)]
		_refresh_reaction_label()
	else:
		_summary_label.text = "击杀 -　波次 -　总伤害 -"
		_reaction_label.text = "碎裂 0/0(0%) · 过载 0/0(0%) · 超导 0/0(0%)"
	_root.visible = true


func _refresh_reaction_label() -> void:
	# v0.7.0 U10：反应结算行——"碎裂 n/dmg(p%) · 过载 … · 超导 …"；
	# p = 反应承载伤害 / total_damage（0 保护）；无元素战斗零值占位
	var counts: Array = stats_source.get("reaction_counts")
	var damages: Array = stats_source.get("reaction_damage")
	var total: float = stats_source.get("total_damage")
	var names: Array[String] = ["碎裂", "过载", "超导"]
	var parts: Array[String] = []
	for i in range(3):
		var n := int(counts[i]) if i < counts.size() else 0
		var d := float(damages[i]) if i < damages.size() else 0.0
		var p := 0.0 if total <= 0.0 else d / total
		parts.append("%s %d/%d(%d%%)" % [names[i], n, int(round(d)), int(round(p * 100.0))])
	_reaction_label.text = " · ".join(parts)


func hide_screen() -> void:
	_root.visible = false


func summary_text() -> String:
	# 测试观测口
	return _summary_label.text


func reaction_text() -> String:
	# v0.7.0 U10 测试观测口
	return _reaction_label.text


func request_restart() -> void:
	# 重开按钮回调（程序化 Button pressed）
	restart_requested.emit()


func request_menu() -> void:
	# v0.8.0：返回选角按钮回调（GameLoop.goto_menu 仲裁）
	menu_requested.emit()


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
	# v0.7.0 U10：反应统计行（y=522 font15 居中；与按钮 (280,560) 不相交）
	_reaction_label = Label.new()
	_reaction_label.text = "碎裂 0/0(0%) · 过载 0/0(0%) · 超导 0/0(0%)"
	_reaction_label.add_theme_font_size_override("font_size", 15)
	_reaction_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_reaction_label.position = Vector2(0.0, 522.0)
	_reaction_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root.add_child(_reaction_label)
	# v0.8.0：双按钮（A7 §V19）——「再次出击」(100,560) 220x52 /「返回选角」(400,560) 220x52。
	# ★「再次出击」语义 = restart_run（pkg4:114/pkg5:200,544,827/pkg6:268/pkg6_extra:258 冻结断言
	# 兼容——restart_run 数值重置口径零改动）
	var btn_again := Button.new()
	btn_again.text = "再次出击"
	btn_again.add_theme_font_size_override("font_size", 18)
	btn_again.position = Vector2(100.0, 560.0)
	btn_again.size = Vector2(220.0, 52.0)
	btn_again.pressed.connect(request_restart)
	_root.add_child(btn_again)
	var btn_menu := Button.new()
	btn_menu.text = "返回选角"
	btn_menu.add_theme_font_size_override("font_size", 18)
	btn_menu.position = Vector2(400.0, 560.0)
	btn_menu.size = Vector2(220.0, 52.0)
	btn_menu.pressed.connect(request_menu)
	_root.add_child(btn_menu)

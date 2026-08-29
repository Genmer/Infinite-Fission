# scripts/ui/game_over_screen.gd
# M-16 GameOverScreen（架构 §1.4/§2.1）：结算界面（本局统计：击杀数/波次/造成的总伤害）。
# 方向 C：圆角白卡战报（贴纸面板 + 哨兵-9 小脸标）+ 随机引言 + 「再来一局！」果冻按钮。
# 订阅 state_changed → GAME_OVER 显示；数据源 HUD 统计（注入）。
# 重开申请：GameLoop.restart_run()（GAME_OVER → MENU/PLAYING，迁移矩阵仲裁）。
class_name GameOverScreen
extends CanvasLayer

signal restart_requested()                    # → GameLoop 重开申请（迁移矩阵仲裁）

var stats_source: Node = null                 # 注入（HUD：kills/wave/total_damage）

var _root: Control = null
var _card: Panel = null                       # 战报白卡（出现时果冻 pop）
var _summary_label: Label = null              # 战报行（测试锁定：summary_text 含「击杀」）
var _quote_label: Label = null                # 随机引言


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	EventBus.state_changed.connect(_on_state_changed)


func setup(p_stats_source: Node) -> void:
	# 数据源注入（HUD）
	stats_source = p_stats_source


func show_summary() -> void:
	# 显示结算（击杀/波次/总伤害；AC-16.1）+ 随机引言 + 果冻出场
	if stats_source != null and is_instance_valid(stats_source):
		var kills: int = stats_source.get("kills")
		var wave: int = stats_source.get("wave")
		var dmg: float = stats_source.get("total_damage")
		_summary_label.text = "击杀 %d　波次 %d　总伤害 %d" % [kills, wave, int(dmg)]
	else:
		_summary_label.text = "击杀 -　波次 -　总伤害 -"
	_quote_label.text = Lore.game_over_quote()
	_root.visible = true
	StickerTheme.squash_pop(_card)


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
	_root.theme = StickerTheme.theme()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.visible = false
	add_child(_root)
	var dim := ColorRect.new()
	dim.color = PopPalette.DIM
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(dim)

	# 战报白卡（贴纸面板：圆角 24 + 藏青描边 + 底部厚投影）
	_card = Panel.new()
	_card.name = "ReportCard"
	_card.add_theme_stylebox_override("panel", StickerTheme.panel_style(24.0, 4, true))
	_card.position = Vector2(70.0, 404.0)
	_card.size = Vector2(580.0, 470.0)
	_card.pivot_offset = _card.size * 0.5
	_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_card)

	# 卡顶哨兵-9 小脸标（压在卡沿上——贴纸叠贴感）
	var face := TextureRect.new()
	face.texture = TextureFactory.ship()
	face.position = Vector2(262.0, -44.0)
	face.custom_minimum_size = Vector2(88.0, 88.0)
	face.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	face.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	face.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card.add_child(face)

	var title := Label.new()
	StickerTheme.label_sticker(title, 32, PopPalette.INK, 0, Color.WHITE, true)
	title.text = Lore.GAME_OVER_TITLE
	title.position = Vector2(0.0, 64.0)
	title.size = Vector2(580.0, 36.0)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_card.add_child(title)

	_summary_label = Label.new()
	StickerTheme.label_sticker(_summary_label, 20, PopPalette.INK, 0, Color.WHITE, true)
	_summary_label.text = ""
	_summary_label.position = Vector2(0.0, 148.0)
	_summary_label.size = Vector2(580.0, 30.0)
	_summary_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_card.add_child(_summary_label)

	# 战报装饰分隔（柠檬星行）
	var stars := Label.new()
	StickerTheme.label_sticker(stars, 18, PopPalette.XP, 0, Color.WHITE, true)
	stars.text = "★ ★ ★"
	stars.position = Vector2(0.0, 208.0)
	stars.size = Vector2(580.0, 26.0)
	stars.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_card.add_child(stars)

	_quote_label = Label.new()
	StickerTheme.label_sticker(_quote_label, 18, PopPalette.INK_SOFT)
	_quote_label.text = ""
	_quote_label.position = Vector2(0.0, 262.0)
	_quote_label.size = Vector2(580.0, 26.0)
	_quote_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_card.add_child(_quote_label)

	var btn := Button.new()
	btn.name = "RestartButton"
	btn.text = Lore.GAME_OVER_BUTTON
	btn.add_theme_font_size_override("font_size", 22)
	btn.add_theme_font_override("font", StickerTheme.font_bold())
	btn.position = Vector2(190.0, 330.0)
	btn.size = Vector2(200.0, 72.0)
	btn.pivot_offset = Vector2(100.0, 36.0)
	btn.pressed.connect(request_restart)
	btn.button_down.connect(func() -> void: StickerTheme.press_punch(btn))
	_card.add_child(btn)

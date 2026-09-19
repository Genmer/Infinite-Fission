# scripts/ui/game_over_screen.gd
# M-16 GameOverScreen（架构 §1.4/§2.1）：结算界面（本局统计：击杀数/波次/造成的总伤害）。
# 方向 C：圆角白卡战报（贴纸面板 + 哨兵-9 小脸标）+ 随机引言 + 「再来一局！」果冻按钮。
# 订阅 state_changed → GAME_OVER 显示；数据源 HUD 统计（注入）。
# 重开申请：GameLoop.restart_run()（GAME_OVER → MENU/PLAYING，迁移矩阵仲裁）。
class_name GameOverScreen
extends CanvasLayer

var _title_label: Label = null
signal restart_requested()                    # → GameLoop 重开申请（迁移矩阵仲裁）
signal menu_requested()                       # → GameLoop.quit_to_menu（R13 结算屏回主菜单）
signal endless_continue_requested()           # R62 → GameLoop 无尽继续（通关屏专属出口）

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


var _victory: bool = false                     # 胜利模式（R10：通关即结算——标题/引言换胜利口径）
var _endless_allowed: bool = false             # R62：本局通关屏是否提供「继续挑战·无尽」出口
var _endless_btn: Button = null                # R62：无尽继续按钮（与重开按钮同槽位互换）
var _restart_btn: Button = null


func show_summary() -> void:
	# 显示结算（击杀/波次/总伤害；AC-16.1）+ 随机引言 + 果冻出场
	_victory = false
	_endless_allowed = false
	_refresh_title()
	_refresh_exit_buttons()
	if stats_source != null and is_instance_valid(stats_source):
		var kills: int = stats_source.get("kills")
		var wave: int = stats_source.get("wave")
		var dmg: float = stats_source.get("total_damage")
		var peak: int = maxi(int(stats_source.get("combo_peak") if stats_source != null and stats_source.get("combo_peak") != null else 0), 0)
		var combo_part := "　最高连杀 ×%d" % peak if peak >= 5 else ""
		_summary_label.text = "击杀 %d　波次 %d　总伤害 %d%s" % [kills, wave, int(dmg), combo_part]
	else:
		_summary_label.text = "击杀 -　波次 -　总伤害 -"
	_quote_label.text = Lore.game_over_quote()
	_root.visible = true
	StickerTheme.squash_pop(_card)


func show_victory(p_allow_endless: bool = true) -> void:
	# 通关结算（R10：清完 final Boss 波 → 关卡胜利——波次不再无限叠加）
	# R62：非每日局默认提供「继续挑战·无尽」出口（p_allow_endless=false → 每日局不出）
	_victory = true
	_endless_allowed = p_allow_endless
	_refresh_title()
	_refresh_exit_buttons()
	_quote_label.text = Lore.game_over_quote()
	_root.visible = true
	StickerTheme.squash_pop(_card)


func _refresh_exit_buttons() -> void:
	# R62 出口互换：胜利且无尽可用 → 无尽按钮占主槽（重开隐藏）；否则重开占主槽
	if _endless_btn == null or _restart_btn == null:
		return
	var endless_visible := _victory and _endless_allowed
	_endless_btn.visible = endless_visible
	_restart_btn.visible = not endless_visible


func _refresh_title() -> void:
	if _title_label == null:
		return
	if _victory:
		_title_label.text = "★ 关卡通关！"
		_title_label.add_theme_color_override("font_color", PopPalette.SUCCESS)
	else:
		_title_label.text = Lore.GAME_OVER_TITLE
		_title_label.add_theme_color_override("font_color", PopPalette.INK)


func hide_screen() -> void:
	_root.visible = false


func summary_text() -> String:
	# 测试观测口
	return _summary_label.text


func is_endless_offer_visible() -> bool:
	# R62 测试观测口：通关屏「继续挑战·无尽」出口当前是否可见
	return _endless_btn != null and _endless_btn.visible


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

	_title_label = Label.new()
	StickerTheme.label_sticker(_title_label, 32, PopPalette.INK, 0, Color.WHITE, true)
	_title_label.text = Lore.GAME_OVER_TITLE
	_title_label.position = Vector2(0.0, 64.0)
	_title_label.size = Vector2(580.0, 36.0)
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_card.add_child(_title_label)

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
	btn.position = Vector2(150.0, 322.0)
	btn.size = Vector2(280.0, 64.0)
	btn.pivot_offset = btn.size * 0.5
	btn.pressed.connect(request_restart)
	btn.button_down.connect(func() -> void: StickerTheme.press_punch(btn))
	_card.add_child(btn)
	_restart_btn = btn
	# R62 无尽继续（通关屏主出口——与重开同槽位互换；胜利 + 非每日局才可见）
	var endless := Button.new()
	endless.name = "EndlessContinueButton"
	endless.text = "▶ 继续挑战 · 无尽"
	endless.add_theme_font_size_override("font_size", 22)
	endless.add_theme_font_override("font", StickerTheme.font_bold())
	endless.add_theme_color_override("font_color", PopPalette.SUCCESS)
	endless.add_theme_color_override("font_pressed_color", PopPalette.SUCCESS)
	endless.add_theme_color_override("font_hover_color", PopPalette.SUCCESS)
	endless.position = Vector2(150.0, 322.0)
	endless.size = Vector2(280.0, 64.0)
	endless.pivot_offset = endless.size * 0.5
	endless.visible = false
	endless.pressed.connect(func() -> void: endless_continue_requested.emit())
	endless.button_down.connect(func() -> void: StickerTheme.press_punch(endless))
	_card.add_child(endless)
	_endless_btn = endless
	# 回主菜单（R13：通关/死亡结算第二出口——回大厅解锁链/换构筑）
	var menu_btn := Button.new()
	menu_btn.name = "MenuButton"
	menu_btn.text = "回主菜单"
	menu_btn.add_theme_font_size_override("font_size", 18)
	menu_btn.add_theme_font_override("font", StickerTheme.font_bold())
	menu_btn.position = Vector2(150.0, 400.0)
	menu_btn.size = Vector2(280.0, 56.0)
	menu_btn.pivot_offset = menu_btn.size * 0.5
	menu_btn.pressed.connect(func() -> void: menu_requested.emit())
	menu_btn.button_down.connect(func() -> void: StickerTheme.press_punch(menu_btn))
	_card.add_child(menu_btn)

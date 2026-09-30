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
# R188-3 挂机重开倒计时（idle）：HUD _toast_label 在 GAME_OVER 被状态覆盖期强制收起，
# 倒计时文案须自有落位——卡面内 Label（MenuButton 下方 y≈470）。GameLoop 每帧
# set_auto_countdown 注入剩余秒数；任一既有出口（重开/无尽/回菜单）按下即取消。
var _countdown_label: Label = null            # 「N 秒后自动再来一局 · 点按取消」
var _auto_countdown_active: bool = false      # 倒计时挂起态（cancel 置 false）
var _auto_countdown_left: float = 0.0         # 剩余秒（观测口）


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	# R195 适配：安全区接入（底座组 SafeAreaHelper 单点引用，不复写）。守卫外
	# （桌面窗口化/headless）insets 恒零 → offset 写 0 = 默认窗逐位恒等；真机延迟
	# ≥1 帧重读兜首帧 transform 未定型，size_changed/重获焦点由 helper 重放回调。
	_apply_safe_area()
	if SafeAreaHelper.enabled(get_window()):          # 守卫外恒零→零协程悬挂（headless 全绿面）
		_apply_safe_area_deferred()                # 真值环境延迟重读（SafeAreaHelper 契约）
	SafeAreaHelper.bind_reread(get_window(), _apply_safe_area)
	EventBus.state_changed.connect(_on_state_changed)


func _apply_safe_area() -> void:
	# R195 安全区应用（消费式契约=SafeAreaHelper.insets 注释）：根 FULL_RECT
	# offset 左/上取正、右/下取负；dim FULL_RECT 子件随根，结算卡居中锚随根域居中。
	# 仅 realize/size_changed/焦点事件驱动，非每帧路径（R188 纪律）。
	var ins := SafeAreaHelper.insets(get_window())
	_root.offset_left = ins.position.x
	_root.offset_top = ins.position.y
	_root.offset_right = -ins.size.x
	_root.offset_bottom = -ins.size.y


func _apply_safe_area_deferred() -> void:
	# realize 后延迟 ≥1 帧重读（首帧查询为未 realize 真值——SafeAreaHelper 契约）；
	# 协程即发即续，不阻塞 _ready（调用方已守卫 enabled 才进来；二次应用幂等）
	await SafeAreaHelper.read_deferred(get_window())
	_apply_safe_area()


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
	cancel_auto_countdown()                       # 新结算起步：上一局倒计时态不残留（GameLoop 随后逐帧重注）
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
	cancel_auto_countdown()                       # 同 show_summary：结算起步清残留
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
	cancel_auto_countdown()                       # 离开 GAME_OVER：倒计时随收起取消（GameLoop 侧停注后兜底）
	_root.visible = false


func summary_text() -> String:
	# 测试观测口
	return _summary_label.text


func is_endless_offer_visible() -> bool:
	# R62 测试观测口：通关屏「继续挑战·无尽」出口当前是否可见
	return _endless_btn != null and _endless_btn.visible


func request_restart() -> void:
	# 重开按钮回调（程序化 Button pressed）：玩家接管 → 挂机倒计时即取消
	cancel_auto_countdown()
	restart_requested.emit()


# ── R188-3 挂机重开倒计时（idle） ──────────────────────────────────
func set_auto_countdown(p_seconds_left: float) -> void:
	# GameLoop 每帧注入挂机重开剩余秒数（文案秒数 = ceil 取整）；≤0 视为取消。
	# 文案锁定（验收口径）：「N 秒后自动再来一局 · 点按取消」
	if p_seconds_left <= 0.0:
		cancel_auto_countdown()
		return
	_auto_countdown_active = true
	_auto_countdown_left = p_seconds_left
	if _countdown_label != null:
		_countdown_label.text = "%d 秒后自动再来一局 · 点按取消" % int(ceilf(p_seconds_left))
		_countdown_label.visible = _root.visible


func cancel_auto_countdown() -> void:
	# 取消挂机倒计时（三出口按钮 pressed / 离开 GAME_OVER / GameLoop 主动调用）
	_auto_countdown_active = false
	_auto_countdown_left = 0.0
	if _countdown_label != null:
		_countdown_label.visible = false


func is_auto_countdown_active() -> bool:
	# 测试观测口：挂机倒计时当前是否挂起
	return _auto_countdown_active


func auto_countdown_left() -> float:
	# 测试观测口：剩余秒数
	return _auto_countdown_left


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
	# R195 适配分区：整体居中锚（PRESET_CENTER，offset=卡位−设计中心(360,640)：
	# (70,404)580×470 → ±290/−236+234——卡心 y=639 恒等保持现位；任意视口下居中，
	# 卡内父相对零改动）
	_card = Panel.new()
	_card.name = "ReportCard"
	_card.add_theme_stylebox_override("panel", StickerTheme.panel_style(24.0, 4, true))
	_card.anchor_left = 0.5
	_card.anchor_right = 0.5
	_card.anchor_top = 0.5
	_card.anchor_bottom = 0.5
	_card.offset_left = -290.0
	_card.offset_right = 290.0
	_card.offset_top = -236.0
	_card.offset_bottom = 234.0
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
	endless.pressed.connect(func() -> void:
		cancel_auto_countdown()               # 玩家接管：三出口任一按下即取消挂机倒计时
		endless_continue_requested.emit())
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
	menu_btn.pressed.connect(func() -> void:
		cancel_auto_countdown()               # 玩家接管：三出口任一按下即取消挂机倒计时
		menu_requested.emit())
	menu_btn.button_down.connect(func() -> void: StickerTheme.press_punch(menu_btn))
	_card.add_child(menu_btn)

	# R188-3 挂机重开倒计时（idle）：卡面内 Label，MenuButton（y400+56=456）下方 y≈470。
	# 文案「N 秒后自动再来一局 · 点按取消」——任一出口按钮按下即取消（三信号通知取消），
	# GameLoop 每帧 set_auto_countdown 刷新秒数，离开 GAME_OVER 随 hide_screen 收起。
	_countdown_label = StickerTheme.label_sticker(Label.new(), 15, PopPalette.GOLD, 0, Color.WHITE, true)
	_countdown_label.name = "AutoCountdownLabel"
	_countdown_label.text = ""
	_countdown_label.position = Vector2(0.0, 470.0)
	_countdown_label.size = Vector2(580.0, 26.0)
	_countdown_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_countdown_label.visible = false
	_countdown_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card.add_child(_countdown_label)

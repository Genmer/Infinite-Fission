# scripts/ui/pause_overlay.gd
# 方向 C 暂停遮罩面板（用户反馈 2026-08-29「没有暂停的地方」）：全屏压暗 + 「暂停中」
# 大标题白卡 + 三按钮（继续 / 重新开始 / 回主菜单）。仅 PAUSED 态显示（state_changed 绑定）。
# process_mode = ALWAYS（tree.paused 期间 UI 照常，Q-14 口径）；申请经信号 → GameLoop
# 仲裁（迁移矩阵唯一裁决位，E-16 同源）：resume→PLAYING / restart→restart_run /
# menu→quit_to_menu（PAUSED→MENU 合法迁移，pkg4 非法迁移枚举不含此对，证据见交付报告）。
class_name PauseOverlay
extends CanvasLayer

signal resume_requested()                     # → GameLoop.request_resume()（PAUSED → PLAYING）
signal restart_requested()                    # → GameLoop.restart_run()（PAUSED → PLAYING 重开）
signal menu_requested()                       # → GameLoop.quit_to_menu()（PAUSED → MENU）

var _root: Control = null
var _card: Panel = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	_root.visible = false
	EventBus.state_changed.connect(_on_state_changed)


func is_pause_visible() -> bool:
	# 测试观测口
	return _root != null and _root.visible


func _on_state_changed(p_state: int) -> void:
	var show := p_state == GameConst.GameStatus.PAUSED
	_root.visible = show
	if show:
		StickerTheme.squash_pop(_card)


func _build_ui() -> void:
	_root = Control.new()
	_root.name = "PauseRoot"
	_root.theme = StickerTheme.theme()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	# 全屏压暗（藏青半透——战斗画面隐约可见，暂停观感）
	var dim := ColorRect.new()
	dim.name = "PauseDim"
	dim.color = PopPalette.DIM
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(dim)

	# 暂停白卡（贴纸面板：圆角 24 + 藏青描边 + 底部厚投影）
	_card = Panel.new()
	_card.name = "PauseCard"
	_card.add_theme_stylebox_override("panel", StickerTheme.panel_style(24.0, 4, true))
	_card.position = Vector2(120.0, 428.0)
	_card.size = Vector2(480.0, 424.0)
	_card.pivot_offset = _card.size * 0.5
	_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_card)

	# 卡顶 ▶ 小徽标（压在卡沿上——贴纸叠贴感，与暂停按钮同源图形）
	var glyph := TextureRect.new()
	glyph.name = "PauseGlyph"
	glyph.texture = TextureFactory.ui_glyph(1)
	glyph.position = Vector2(208.0, -46.0)
	glyph.custom_minimum_size = Vector2(84.0, 84.0)
	glyph.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	glyph.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	glyph.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card.add_child(glyph)

	var title := Label.new()
	StickerTheme.label_sticker(title, 40, PopPalette.INK, 0, Color.WHITE, true)
	title.text = "暂停中"
	title.position = Vector2(0.0, 56.0)
	title.size = Vector2(480.0, 48.0)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_card.add_child(title)

	var hint := Label.new()
	StickerTheme.label_sticker(hint, 15, PopPalette.INK_SOFT)
	hint.text = "Esc / P 也可继续战斗"
	hint.position = Vector2(0.0, 116.0)
	hint.size = Vector2(480.0, 20.0)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_card.add_child(hint)

	_add_card_button("ResumeButton", "继续", Vector2(140.0, 156.0), _on_resume_pressed)
	_add_card_button("RestartButton", "重新开始", Vector2(140.0, 246.0), _on_restart_pressed)
	_add_card_button("MenuButton", "回主菜单", Vector2(140.0, 336.0), _on_menu_pressed)


func _add_card_button(p_name: String, p_text: String, p_pos: Vector2, p_handler: Callable) -> void:
	# 卡内贴纸按钮（四态由 Theme 承担 + 按下 punch）
	var btn := Button.new()
	btn.name = p_name
	btn.text = p_text
	btn.add_theme_font_size_override("font_size", 22)
	btn.add_theme_font_override("font", StickerTheme.font_bold())
	btn.position = p_pos
	btn.size = Vector2(200.0, 72.0)
	btn.pivot_offset = btn.size * 0.5
	btn.pressed.connect(p_handler)
	btn.button_down.connect(func() -> void: StickerTheme.press_punch(btn))
	_card.add_child(btn)


func _on_resume_pressed() -> void:
	resume_requested.emit()


func _on_restart_pressed() -> void:
	restart_requested.emit()


func _on_menu_pressed() -> void:
	menu_requested.emit()

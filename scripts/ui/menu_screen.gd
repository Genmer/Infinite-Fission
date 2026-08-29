# scripts/ui/menu_screen.gd
# 集成包 A：主菜单屏（MENU 状态宿主）—— 方向 C「晴空糖果」贴纸风重设计。
# 淡云天空底 + 「INFINITE FISSION」双色字母大 logo + 副题「∞ 链式裂变乐园」+ 哨兵-9
# 圆舰吉祥物漂浮 idle + 「出发！」果冻脉动按钮 + lore 引导文案。
# GameLoop 状态机（迁移矩阵冻结）MENU → PLAYING 唯一入口 start_run()——本屏仅申请：
# start_requested 信号 → GameLoop.start_run（仲裁权在 GameLoop，E-16 同源）。
# 可见性绑定 state_changed（仅 MENU 显示）。process_mode = ALWAYS（Q-14 口径）。
class_name MenuScreen
extends CanvasLayer

signal start_requested()                      # → GameLoop.start_run()（MENU → PLAYING）

var _root: Control = null
var _start_btn: Button = null
var _pulse_tween: Tween = null                # 出发按钮果冻脉动（隐藏时暂停）
var _mascot: TextureRect = null
var _bob_tween: Tween = null                  # 吉祥物漂浮 idle


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	_root.visible = false
	EventBus.state_changed.connect(_on_state_changed)


func _on_state_changed(p_state: int) -> void:
	# 仅 MENU 态显示（PLAYING/LEVEL_UP/PAUSED/GAME_OVER 均隐藏）；动效随可见性启停
	var show := p_state == GameConst.GameStatus.MENU
	_root.visible = show
	if _pulse_tween != null:
		if show:
			_pulse_tween.play()
		else:
			_pulse_tween.pause()
	if _bob_tween != null:
		if show:
			_bob_tween.play()
		else:
			_bob_tween.pause()


func _build_ui() -> void:
	_root = Control.new()
	_root.name = "MenuRoot"
	_root.theme = StickerTheme.theme()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	# 淡云天空底（不透明 #EEF3FF，盖住战场）+ 漂移云层
	var bg := ColorRect.new()
	bg.name = "MenuBg"
	bg.color = PopPalette.BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(bg)
	var clouds := CloudBackdrop.new()
	clouds.name = "MenuClouds"
	clouds.base_z = 0                            # 菜单内：云层盖住底色（世界层则沉底）
	_root.add_child(clouds)

	# 大 logo：字母双色交替（天空蓝/珊瑚红）+ 白描边贴纸字
	var logo := HBoxContainer.new()
	logo.name = "Logo"
	logo.add_theme_constant_override("separation", 2)
	logo.position = Vector2(0.0, 258.0)
	logo.size = Vector2(720.0, 64.0)
	logo.alignment = BoxContainer.ALIGNMENT_CENTER
	logo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(logo)
	for i in range(Lore.LOGO.length()):
		var ch := Lore.LOGO[i]
		if ch == " ":
			var gap := Control.new()
			gap.custom_minimum_size = Vector2(14.0, 10.0)
			gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
			logo.add_child(gap)
			continue
		var letter := Label.new()
		var fill := PopPalette.PLAYER if i % 2 == 0 else PopPalette.ENEMY
		StickerTheme.label_sticker(letter, 50, fill, 8, Color.WHITE, true)
		letter.text = ch
		logo.add_child(letter)

	# 副题 + lore 引导文案
	var subtitle := Label.new()
	StickerTheme.label_sticker(subtitle, 24, PopPalette.INK, 0, Color.WHITE, true)
	subtitle.text = Lore.SUBTITLE
	subtitle.position = Vector2(0.0, 342.0)
	subtitle.size = Vector2(720.0, 34.0)
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root.add_child(subtitle)
	for i in range(Lore.MENU_LINES.size()):
		var line := Label.new()
		StickerTheme.label_sticker(line, 16, PopPalette.INK_SOFT)
		line.text = Lore.MENU_LINES[i]
		line.position = Vector2(0.0, 660.0 + 26.0 * float(i))
		line.size = Vector2(720.0, 22.0)
		line.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_root.add_child(line)

	# 哨兵-9 圆舰吉祥物（漂浮 idle：上下浮动 + 轻微摇摆）
	_mascot = TextureRect.new()
	_mascot.name = "Sentinel9"
	_mascot.texture = TextureFactory.ship()
	_mascot.position = Vector2(310.0, 452.0)
	_mascot.custom_minimum_size = Vector2(100.0, 100.0)
	_mascot.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_mascot.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_mascot.pivot_offset = Vector2(50.0, 50.0)
	_mascot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_mascot)
	var name_tag := Label.new()
	StickerTheme.label_sticker(name_tag, 15, PopPalette.PLAYER, 0, Color.WHITE, true)
	name_tag.text = "防御机器人 · 哨兵-9"
	name_tag.position = Vector2(0.0, 566.0)
	name_tag.size = Vector2(720.0, 20.0)
	name_tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root.add_child(name_tag)

	# 出发！按钮（果冻脉动；贴纸四态由 Theme 承担）
	_start_btn = Button.new()
	_start_btn.name = "StartButton"
	_start_btn.text = Lore.START_BUTTON
	_start_btn.add_theme_font_size_override("font_size", 30)
	_start_btn.add_theme_font_override("font", StickerTheme.font_bold())
	_start_btn.position = Vector2(260.0, 790.0)
	_start_btn.size = Vector2(200.0, 84.0)
	_start_btn.pivot_offset = Vector2(100.0, 42.0)
	_start_btn.pressed.connect(_on_start_pressed)
	_start_btn.button_down.connect(func() -> void: StickerTheme.press_punch(_start_btn))
	_root.add_child(_start_btn)
	_pulse_tween = StickerTheme.pulse(_start_btn, 1.15, 0.045)

	# 吉祥物漂浮 idle（正弦 bob + 摇摆）
	_bob_tween = _mascot.create_tween().set_loops()
	_bob_tween.tween_property(_mascot, "position:y", 440.0, 1.4) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_bob_tween.parallel().tween_property(_mascot, "rotation", 0.06, 1.4) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_bob_tween.tween_property(_mascot, "position:y", 464.0, 1.4) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_bob_tween.parallel().tween_property(_mascot, "rotation", -0.06, 1.4) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

	# 版本脚注
	var footer := Label.new()
	StickerTheme.label_sticker(footer, 13, PopPalette.INK_SOFT)
	footer.text = "竖屏弹幕防御 · Roguelike"
	footer.position = Vector2(0.0, 1216.0)
	footer.size = Vector2(720.0, 20.0)
	footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root.add_child(footer)


func _on_start_pressed() -> void:
	start_requested.emit()


func is_menu_visible() -> bool:
	# 测试观测口
	return _root != null and _root.visible

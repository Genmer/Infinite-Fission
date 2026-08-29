# scripts/ui/menu_screen.gd
# 集成包 A：主菜单屏（MENU 状态宿主）。方向 B 重设计 = 终端启动序列：
# 逐行打字机输出 lore（Lore.BOOT_LINES 单源）→ 标题「SENTINEL-9」浮现 → 启动按钮。
# GameLoop 状态机（迁移矩阵冻结）MENU → PLAYING 唯一入口 start_run()——本屏仅申请：
# start_requested 信号 → GameLoop.start_run（仲裁权在 GameLoop，E-16 同源）。
# 可见性绑定 state_changed（仅 MENU 显示）；is_menu_visible() 观测口不变。
# process_mode = ALWAYS（与 HUD/UI 层同口径，Q-14）。
class_name MenuScreen
extends CanvasLayer

signal start_requested()                      # → GameLoop.start_run()（MENU → PLAYING）

const TYPE_CPS := 52.0                        # 打字机速度（字符/s，raw 通道）
const TITLE_FADE_S := 0.6                     # 标题浮现时长 s
const CURSOR_BLINK_HZ := 2.4                  # 光标闪烁频率

var _root: Control = null
var _start_btn: Button = null
var _log_label: Label = null
var _title_label: Label = null
var _suffix_label: Label = null
var _subtitle_label: Label = null

var _type_left: float = 0.0                   # 剩余打字时长（raw 通道倒计时）
var _total_type: float = 0.0                  # 全文打完所需时长
var _title_fade_left: float = 0.0             # 标题淡入剩余（0 = 完成）
var _t: float = 0.0                           # 光标闪烁时钟


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = TerminalTheme.UI_LAYER               # CRT 氛围层(4)之上——扫描线不压菜单文字
	_build_ui()
	_root.visible = false
	EventBus.state_changed.connect(_on_state_changed)


func _process(p_delta: float) -> void:
	# 打字机推进（仅菜单可见期；raw 通道自驱）
	if _root == null or not _root.visible:
		return
	_t += p_delta
	if _type_left > 0.0:
		_type_left = maxf(_type_left - p_delta, 0.0)
		_log_label.text = _typed_text()
		if _type_left <= 0.0:
			_title_fade_left = TITLE_FADE_S
	elif _title_fade_left > 0.0:
		_title_fade_left = maxf(_title_fade_left - p_delta, 0.0)
		var a := 1.0 - _title_fade_left / TITLE_FADE_S
		_title_label.modulate.a = a
		_suffix_label.modulate.a = a
		_subtitle_label.modulate.a = a


func _on_state_changed(p_state: int) -> void:
	# 仅 MENU 态显示（PLAYING/LEVEL_UP/PAUSED/GAME_OVER 均隐藏）；重进菜单重放启动序列
	var show := p_state == GameConst.GameStatus.MENU
	_root.visible = show
	if show:
		_restart_boot_sequence()


func _restart_boot_sequence() -> void:
	_total_type = float(_full_text().length()) / TYPE_CPS
	_type_left = _total_type
	_title_fade_left = 0.0
	_t = 0.0
	_log_label.text = ""
	_title_label.modulate.a = 0.0
	_suffix_label.modulate.a = 0.0
	_subtitle_label.modulate.a = 0.0


func _full_text() -> String:
	return "\n".join(Lore.BOOT_LINES)


func _typed_text() -> String:
	# 按剩余时长截取已输出字符；尾部光标「_」闪烁（等待操作员指令）
	var done := 1.0 - _type_left / maxf(_total_type, 0.0001)
	var count := int(round(clampf(done, 0.0, 1.0) * float(_full_text().length())))
	var text := _full_text().substr(0, count)
	if count < _full_text().length():
		return text + ("_" if fmod(_t, 1.0 / CURSOR_BLINK_HZ) < 0.5 * (1.0 / CURSOR_BLINK_HZ) else "")
	return text


func _build_ui() -> void:
	# 终端启动序列（屏幕近黑底 + 等宽日志 + 磷光标题 + [ 方括号 ] 按钮）
	_root = Control.new()
	_root.name = "MenuRoot"
	_root.theme = TerminalTheme.theme()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)
	var bg := ColorRect.new()
	bg.name = "MenuBg"
	bg.color = Color(Palette.BG.r, Palette.BG.g, Palette.BG.b, 0.97)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(bg)
	_log_label = Label.new()
	_log_label.text = ""
	_log_label.position = Vector2(60.0, 130.0)
	_log_label.size = Vector2(600.0, 300.0)
	_log_label.add_theme_font_size_override("font_size", TerminalTheme.SIZE_BODY)
	_log_label.add_theme_color_override("font_color", Palette.TEXT_BODY)
	_log_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_log_label)
	_title_label = Label.new()
	_title_label.text = Lore.TITLE
	_title_label.add_theme_font_size_override("font_size", TerminalTheme.SIZE_HEADER + 8)
	TerminalTheme.style_key_label(_title_label)  # 标题：字重 800 + 6px 描边
	_title_label.add_theme_color_override("font_color", Palette.PHOS)
	_title_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_title_label.position = Vector2(0.0, 420.0)
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root.add_child(_title_label)
	_suffix_label = Label.new()
	_suffix_label.text = Lore.TITLE_SUFFIX
	_suffix_label.add_theme_font_size_override("font_size", TerminalTheme.SIZE_SECTION)
	_suffix_label.add_theme_color_override("font_color", Palette.AMBER)
	_suffix_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_suffix_label.position = Vector2(0.0, 486.0)
	_suffix_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root.add_child(_suffix_label)
	_subtitle_label = Label.new()
	_subtitle_label.text = Lore.SUBTITLE
	_subtitle_label.add_theme_font_size_override("font_size", TerminalTheme.SIZE_LOG + 1)
	_subtitle_label.add_theme_color_override("font_color", Palette.TEXT_DIM)
	_subtitle_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_subtitle_label.position = Vector2(0.0, 530.0)
	_subtitle_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root.add_child(_subtitle_label)
	_start_btn = Button.new()
	_start_btn.text = Lore.START_BUTTON
	_start_btn.position = Vector2(270.0, 640.0)
	_start_btn.size = Vector2(180.0, 60.0)
	_start_btn.pressed.connect(_on_start_pressed)
	_root.add_child(_start_btn)


func _on_start_pressed() -> void:
	start_requested.emit()


func is_menu_visible() -> bool:
	# 测试观测口
	return _root != null and _root.visible

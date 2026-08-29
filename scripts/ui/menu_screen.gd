# scripts/ui/menu_screen.gd
# 集成包 A：主菜单屏（MENU 状态宿主；程序化占位美术）。
# GameLoop 状态机（迁移矩阵冻结）MENU → PLAYING 唯一入口 start_run()——本屏仅申请：
# start_requested 信号 → GameLoop.start_run（仲裁权在 GameLoop，E-16 同源）。
# 可见性绑定 state_changed（仅 MENU 显示；GAME_OVER 结算屏由 GameOverScreen 承担）。
# process_mode = ALWAYS（与 HUD/UI 层同口径，Q-14）。
class_name MenuScreen
extends CanvasLayer

signal start_requested()                      # → GameLoop.start_run()（MENU → PLAYING）

var _root: Control = null
var _start_btn: Button = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	_root.visible = false
	EventBus.state_changed.connect(_on_state_changed)


func _on_state_changed(p_state: int) -> void:
	# 仅 MENU 态显示（PLAYING/LEVEL_UP/PAUSED/GAME_OVER 均隐藏）
	_root.visible = p_state == GameConst.GameStatus.MENU


func _build_ui() -> void:
	# 程序化占位：标题 + 开始按钮（正式美术后续迭代）
	_root = Control.new()
	_root.name = "MenuRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)
	var bg := ColorRect.new()
	bg.name = "MenuBg"
	bg.color = Color(0.06, 0.07, 0.12, 0.96)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(bg)
	var title := Label.new()
	title.text = "INFINITE FISSION"
	title.add_theme_font_size_override("font_size", 40)
	title.set_anchors_preset(Control.PRESET_TOP_WIDE)
	title.position = Vector2(0.0, 420.0)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root.add_child(title)
	var subtitle := Label.new()
	subtitle.text = "弹幕防御 · Roguelike"
	subtitle.add_theme_font_size_override("font_size", 18)
	subtitle.set_anchors_preset(Control.PRESET_TOP_WIDE)
	subtitle.position = Vector2(0.0, 490.0)
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root.add_child(subtitle)
	_start_btn = Button.new()
	_start_btn.text = "开 始"
	_start_btn.add_theme_font_size_override("font_size", 24)
	_start_btn.position = Vector2(280.0, 640.0)
	_start_btn.size = Vector2(160.0, 60.0)
	_start_btn.pressed.connect(_on_start_pressed)
	_root.add_child(_start_btn)


func _on_start_pressed() -> void:
	start_requested.emit()


func is_menu_visible() -> bool:
	# 测试观测口
	return _root != null and _root.visible

# tests/probe_fps_band_body.gd
# G4 探针体（R202 帧率显示落位依据）：boot 真游戏 → PLAYING 态倾倒 HUD 全部 Control 的
# global_rect + 可见性，实测「空带」定 FPS Label 落位（规格：避开左上 HP/XP 簇
# r195_layout_cases.gd:351-355 与 _r187_readout(368,30) hud.gd:1152）。
# 运行时 load 编译（autoload 已就绪）。非 test_ 前缀（不入电池 glob）。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"


func run(p_tree: SceneTree) -> void:
	_normalize_window_for_boot(p_tree)
	var scene: PackedScene = load(MAIN_SCENE)
	var gl: GameLoop = scene.instantiate() as GameLoop
	gl.name = "ProbeFpsBandGameLoop"
	p_tree.get_root().add_child(gl)
	gl.state = GameConst.GameStatus.MENU            # 冻结波次刷怪（r198 口径）
	gl.current_map_id = MapTable.FIRST_MAP_ID
	gl.start_run()
	await p_tree.process_frame
	await p_tree.process_frame
	print("vis=%s" % str(p_tree.root.get_visible_rect()))
	print("panel_pos=%s show_fps=%s" % [str(Meta.settings("panel_pos")),
		str(Meta.settings("show_fps"))])
	print("── HUD Root 子树（递归 rect+visible） ──")
	_dump(gl.hud._hud_root, 0)
	print("── HUD CanvasLayer 直挂子件 ──")
	for kid in gl.hud.get_children():
		if kid is Control:
			var c := kid as Control
			print("HUD-direct/%s rect=%s visible=%s" % [String(c.name),
				str(c.get_global_rect()), str(c.visible)])
	print("── BossBar 直挂子件 ──")
	for kid in gl.boss_bar.get_children():
		if kid is Control:
			var b := kid as Control
			print("BossBar/%s rect=%s visible=%s" % [String(b.name),
				str(b.get_global_rect()), str(b.visible)])
	p_tree.paused = false
	RunSave.clear()
	gl.free()


func _dump(p_node: Node, p_depth: int) -> void:
	for kid in p_node.get_children():
		if kid is Control:
			var c := kid as Control
			var pad := "  ".repeat(p_depth)
			print("%s%s rect=%s visible=%s" % [pad, String(c.name),
				str(c.get_global_rect()), str(c.visible)])
			_dump(kid, p_depth + 1)
		else:
			_dump(kid, p_depth + 1)


func _normalize_window_for_boot(p_tree: SceneTree) -> void:
	# r194/r195/r198 同款：-s 脚本模式根窗口归一（canvas 域恒等 720×1280）
	var win: Window = p_tree.root
	win.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	match String(ProjectSettings.get_setting("display/window/stretch/aspect", "keep")):
		"keep_width":
			win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP_WIDTH
		"keep_height":
			win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP_HEIGHT
		"expand":
			win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
		"ignore":
			win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_IGNORE
		_:
			win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
	win.size = Vector2i(
		int(ProjectSettings.get_setting("display/window/size/window_width_override", 540)),
		int(ProjectSettings.get_setting("display/window/size/window_height_override", 960)))

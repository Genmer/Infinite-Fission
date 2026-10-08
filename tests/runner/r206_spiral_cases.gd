# tests/runner/r206_spiral_cases.gd
# R206 掐螺旋与尖峰取证·用例体（由 test_r206_spiral.gd 入口在 autoload 就绪后运行时加载）。
# 真机 vc13 日志定案：掉帧=单物理帧逻辑 15-35ms × 8 连补追赶螺旋；本轮掐帽 2 +
# 跳字 mobile 半频 + 峰值取证升级。headless 验收：mobile 门零扰动桌面口径 + 新机制单测。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_boot_game_loop()
	await tree.process_frame
	await tree.process_frame
	_test_1_spiral_cap_gate()
	await _test_2_peak_tracking()
	_test_3_peak_marker_and_reset()
	_test_4_header_fix()
	_test_5_popup_halfrate_gate()
	_teardown_game_loop()
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)
	print("验收汇总：%d/%d 通过" % [_pass, _pass + _fail])


func fail_count() -> int:
	return _fail


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("  PASS | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s（%s）" % [p_name, p_detail])
		print("  FAIL | %s（%s）" % [p_name, p_detail])


func _boot_game_loop() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "R206GameLoopUnderTest"
	tree.get_root().add_child(_gl)
	_gl.state = GameConst.GameStatus.MENU
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	_gl.start_run()


func _teardown_game_loop() -> void:
	tree.paused = false
	RunSave.clear()
	if _gl != null:
		_gl.free()
		_gl = null


# ── ① 追赶帽：mobile 门内=1（R218 刀B 2→1）；桌面/headless 运行时缺省 8 不动 ──
func _test_1_spiral_cap_gate() -> void:
	print("── ① 物理追赶帽 ──")
	var src: String = FileAccess.get_file_as_string("res://scripts/meta/meta_manager.gd")
	# R218 有意契约变更（vc25 定案二j #1/#3）：帽 2→1——fps≥60 时帽 1 无操作（120Hz 渲染
	# 有 2 倍步进余量），只在 fps<60 螺旋段生效（每渲染帧逻辑成本即刻减半；敌<80 螺旋
	# 尾段同样覆盖）
	_check("mobile 门内掐帽 1（源级锚，R218 刀B 2→1）",
		src.contains("Engine.max_physics_steps_per_frame = 1"),
		"meta_manager 缺掐帽行")
	_check("headless 运行时缺省 8 不动（桌面基准零扰动）",
		Engine.max_physics_steps_per_frame == 8,
		"actual=%d" % Engine.max_physics_steps_per_frame)


# ── ② 峰值采样：PLAYING 帧填充五段；清零钩 ──
func _test_2_peak_tracking() -> void:
	print("── ② 峰值采样 ──")
	_gl.stage_probe_enabled = true
	for i in range(8):
		await tree.physics_frame
	var keys_ok := true
	# R207 拆段后七键（原 feel_ui 三分为 feel/fx/ui）
	for key in [&"player", &"grid_projectile", &"enemy", &"wave", &"feel", &"fx", &"ui"]:
		if not _gl.stage_probe_us_peak.has(key):
			keys_ok = false
	_check("峰值字典七段齐（秒内尖峰可见）", keys_ok,
		"peaks=%s" % str(_gl.stage_probe_us_peak.keys()))
	var all_pos := true
	for key in _gl.stage_probe_us_peak:
		if int(_gl.stage_probe_us_peak[key]) < 0:
			all_pos = false
	_check("峰值非负", all_pos, str(_gl.stage_probe_us_peak))
	_gl.diag_reset_stage_peaks()
	_check("清零钩生效（诊断采样后复位）", _gl.stage_probe_us_peak.is_empty(),
		"peaks=%s" % str(_gl.stage_probe_us_peak))


# ── ③ 诊断行尖峰标记：>25ms 追加「尖峰Xnnms」；≤25ms 不标；读后清零 ──
func _test_3_peak_marker_and_reset() -> void:
	print("── ③ 尖峰标记 ──")
	_gl.stage_probe_us_peak[&"ui"] = 40000
	var line: String = DebugStats._diag_format_line(DebugStats._diag_find_game_loop(), Time.get_ticks_msec())
	_check(">25ms 峰值标注「尖峰UI40ms」", line.contains("尖峰UI40ms"), "line=%s" % line)
	_check("采样读取后峰值清零", _gl.stage_probe_us_peak.is_empty(),
		"peaks=%s" % str(_gl.stage_probe_us_peak))
	_gl.stage_probe_us_peak[&"enemy"] = 10000
	var line2: String = DebugStats._diag_format_line(DebugStats._diag_find_game_loop(), Time.get_ticks_msec())
	_check("≤25ms 峰值不标注（防行噪音）", not line2.contains("尖峰"), "line=%s" % line2)


# ── ④ 日志头：渲染键修正（真值非 ?）+ 追赶帽行 ──
func _test_4_header_fix() -> void:
	print("── ④ 日志头修正 ──")
	var res: Dictionary = DebugStats.diag_export()
	var text: String = str(res["text"])
	_check("渲染后端读真值（forward_plus，非 ?）",
		text.contains("渲染: forward_plus"), "缺真值渲染行")
	_check("mobile 覆写键在位（gl_compatibility）",
		text.contains("gl_compatibility"), "缺 mobile 覆写值")
	_check("追赶帽数值入头（下轮日志可验帽 1 生效——R218 刀B）",
		text.contains("追赶帽 %d" % Engine.max_physics_steps_per_frame), "缺追赶帽行")
	# 清理导出文件
	var dir := DirAccess.open("user://")
	if dir != null and FileAccess.file_exists(str(res["path"])):
		dir.remove(str(res["path"]).trim_prefix("user://"))


# ── ⑤ 跳字半频：mobile 门源级锚 + 桌面路径不受扰 ──
func _test_5_popup_halfrate_gate() -> void:
	print("── ⑤ 跳字半频门 ──")
	var src: String = FileAccess.get_file_as_string("res://scripts/loop/game_loop.gd")
	_check("mobile 隔帧驱动 2δ 源级锚",
		src.contains("popup_manager.tick(p_raw_delta * 2.0)"),
		"game_loop 缺半频驱动行")
	_check("相位计数器在位（_ui_subtick_left）",
		src.contains("_ui_subtick_left") and src.contains("OS.has_feature(\"mobile\")"),
		"缺相位/门结构")

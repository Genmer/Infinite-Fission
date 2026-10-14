# tests/runner/r205_diag_log_cases.gd
# R205 真机诊断日志四件套·用例体（由 test_r205_diag_log.gd 入口在 autoload 就绪后
# 运行时加载编译）。
# 背景：vc12 真机战斗恒 10fps 而 dc 仅 300-500（天玑9400+ 旗舰）——肉眼抄数字效率低，
# 用户点名主页面日志导出（带版本号）。四件套=GameLoop mobile 探针 + DebugStats 1Hz
# 环形缓冲/导出 + menu_screen 按钮 + 版本烤链（export_apk_versioned.py→project.godot）。
# 纪律：headless 测试档自动隔离；导出的 user:// 诊断文件用例收尾清理。
# R212 翻案：环形容量 const DIAG_CAPACITY=900 → 设置驱动（diag_log_len 档
# 60/120/240/360 默认 240，_diag_capacity() 动态读口）——② 组改按读口自洽断言；
# LEVEL_UP 选卡期不采样对 ② 节拍段无影响（用例 GL 在 PLAYING 态直调）。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null
var _exported_paths: Array[String] = []          # 用例产出文件（teardown 清理）


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_boot_game_loop()
	await tree.process_frame
	await tree.process_frame
	_test_1_version_string()
	_test_2_ring_buffer()
	_test_3_format_line_no_gl()
	await _test_4_probe_and_counts()
	_test_5_format_line_with_gl()
	_test_6_export()
	_test_7_menu_button_and_dialog()
	_test_8_storm_throttle_counter()
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


# ── 引导/拆除（同 r196 骨架；无需武器夹具——探针零怪零弹期即可验） ──
func _boot_game_loop() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "R205GameLoopUnderTest"
	tree.get_root().add_child(_gl)
	_gl.state = GameConst.GameStatus.MENU
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	_gl.start_run()


func _teardown_game_loop() -> void:
	# R212：diag_log_len 复位默认 240 并写即存落盘（② 以 60 档驱动——同进程后续用例
	# 与下一套件进程读 meta_save_test.cfg 均不再吃到窄容量档）
	Meta.set_setting("diag_log_len", 240)
	tree.paused = false
	RunSave.clear()
	if _gl != null:
		_gl.free()
		_gl = null
	var dir := DirAccess.open("user://")
	if dir != null:
		for p in _exported_paths:
			var fname := p.trim_prefix("user://")
			if FileAccess.file_exists(p):
				dir.remove(fname)


# ── ① 版本真源：project.godot config/version ↔ ProjectSettings ↔ 占位分支 ──
func _test_1_version_string() -> void:
	print("── ① 版本真源 ──")
	var v: String = DebugStats.version_string()
	var proj_src: String = FileAccess.get_file_as_string("res://project.godot")
	var idx: int = proj_src.find("config/version=\"")
	if idx >= 0:
		var end_q: int = proj_src.find("\"", idx + 16)
		var baked: String = proj_src.substr(idx + 16, end_q - idx - 16)
		_check("运行时版本==project.godot 烤入值", v == baked, "v=%s baked=%s" % [v, baked])
		_check("版本格式 v0.1.x_vcNN（带 vc 防老数据混流）",
			v.begins_with("v") and v.contains("_vc"), "v=%s" % v)
	else:
		_check("project.godot 已烤入 config/version", false, "找不到 config/version 行")
	# 占位分支：清内存设置 → 显式占位（桌面裸跑可辨）→ 还原
	var saved: Variant = ProjectSettings.get_setting("application/config/version", "")
	ProjectSettings.set_setting("application/config/version", "")
	_check("空值退化为占位（dev裸跑未打包）",
		DebugStats.version_string() == "(dev裸跑未打包)", DebugStats.version_string())
	ProjectSettings.set_setting("application/config/version", saved)


# ── ② 环形缓冲：固定容量覆盖写（真机长局不无界增长） ──
# R212 翻案：原 const DIAG_CAPACITY=900 删除，容量改设置驱动（diag_log_len 档
# 60/120/240/360，默认 240——DebugStats._diag_capacity() 动态读口）。本组以 60 档
# 驱动（推满一轮用时最短），容量断言按读口自洽不锁具体值；diag_log_len 收尾由
# _teardown_game_loop 复位 240（防 meta_save_test.cfg 跨套件污染）。
func _test_2_ring_buffer() -> void:
	print("── ② 1Hz 环形缓冲（容量设置驱动） ──")
	Meta.set_setting("diag_log_len", 60)
	var cap: int = DebugStats._diag_capacity()
	_check("容量读口随档位（set 60 → _diag_capacity()==60）", cap == 60, "cap=%d" % cap)
	DebugStats._diag_lines.clear()
	DebugStats._diag_cursor = 0
	for i in range(cap + 37):
		DebugStats._diag_push("line %d" % i)
	_check("容量封顶不增长（档 60 驱动）", DebugStats._diag_lines.size() == cap,
		"size=%d cap=%d" % [DebugStats._diag_lines.size(), cap])
	_check("最旧槽=游标位（覆盖写语义）",
		DebugStats._diag_lines[DebugStats._diag_cursor] == "line 37",
		"cursor=%d slot=%s" % [DebugStats._diag_cursor, DebugStats._diag_lines[DebugStats._diag_cursor]])
	# 1Hz 节拍：节拍窗外首采一行，窗内重复调用不二采
	DebugStats._diag_lines.clear()
	DebugStats._diag_cursor = 0
	DebugStats._diag_last_ms = Time.get_ticks_msec() - 1001
	DebugStats._diag_maybe_sample()
	DebugStats._diag_maybe_sample()
	_check("1Hz 节拍窗内不重复采样", DebugStats._diag_lines.size() == 1,
		"size=%d" % DebugStats._diag_lines.size())


# ── ③ 行格式（无 GameLoop：headless 早期/菜单前安全退化） ──
func _test_3_format_line_no_gl() -> void:
	print("── ③ 行格式·无 GameLoop ──")
	var line: String = DebugStats._diag_format_line(null, 123456)
	_check("时间戳+未启动态字 [2:03 -]", line.begins_with("[2:03 -] fps"), "line=%s" % line)
	_check("dc/o 字段安全退化（headless 渲染信息=0）", line.contains("dc0 o0"), "line=%s" % line)


# ── ④ mobile 探针开关 + diag_counts（PLAYING 帧填充） ──
func _test_4_probe_and_counts() -> void:
	print("── ④ 探针与计数数据源 ──")
	# headless 非移动门：缺省关（桌面基准零扰动口径）
	_check("桌面/headless 探针缺省关", _gl.stage_probe_enabled == false,
		"enabled=%s" % str(_gl.stage_probe_enabled))
	_gl.stage_probe_enabled = true
	for i in range(8):
		await tree.physics_frame
	# R207 拆段后七键（feel_ui → feel/fx/ui 三分——定位粒度升级，恒等验收口径）
	for key in [&"player", &"grid_projectile", &"enemy", &"wave", &"feel", &"fx", &"ui"]:
		_check("探针阶段填充：%s" % key, _gl.stage_probe_us.has(key),
			"keys=%s" % str(_gl.stage_probe_us.keys()))
	var counts: Dictionary = _gl.diag_counts()
	_check("diag_counts 键齐（敌/弹）", counts.has(&"enemies") and counts.has(&"projectiles"),
		"counts=%s" % str(counts))
	# headless 快进下首波可能已开刷（墙钟驱动物理帧）——只锁类型与非负，不锁 0
	_check("敌/弹计数非负整数", int(counts.get(&"enemies", -1)) >= 0
		and int(counts.get(&"projectiles", -1)) >= 0,
		"enemies=%s projectiles=%s" % [str(counts.get(&"enemies", "?")), str(counts.get(&"projectiles", "?"))])


# ── ⑤ 行格式（真 GameLoop：六段+引擎剩余+敌弹数+风暴差分+物理 Hz） ──
func _test_5_format_line_with_gl() -> void:
	print("── ⑤ 行格式·接 GameLoop ──")
	var gl: Node = DebugStats._diag_find_game_loop()
	_check("按 diag_counts 特征解析到测试实例", gl == _gl, "gl=%s" % str(gl))
	var line: String = DebugStats._diag_format_line(gl, Time.get_ticks_msec())
	_check("战斗段七标签齐（玩/弹/敌/波/感/特/UI）",
		line.contains("玩") and line.contains("弹") and line.contains("敌")
			and line.contains("波") and line.contains("感") and line.contains("特")
			and line.contains("UI"), "line=%s" % line)
	_check("引擎剩余「余」字段在位", line.contains("余"), "line=%s" % line)
	_check("敌/弹计数+风暴差分+物理 Hz 尾段", line.contains(" st+") and line.contains(" p"),
		"line=%s" % line)
	_check("headless 物理口径 120Hz（mobile 门不扰动基准）", line.contains(" p120"),
		"line=%s" % line)


# ── ⑥ 导出：user:// 文件 + 版本头 + 环境/渲染/物理元信息 ──
func _test_6_export() -> void:
	print("── ⑥ 导出 ──")
	var res: Dictionary = DebugStats.diag_export()
	var path: String = str(res["path"])
	_exported_paths.append(path)
	var ver_sanitized: String = DebugStats.version_string().replace(".", "_").replace("/", "_")
	_check("文件名带版本（防老数据混流）", path.contains(ver_sanitized), "path=%s ver=%s" % [path, ver_sanitized])
	_check("落盘 user://diag_*.txt", path.begins_with("user://diag_") and FileAccess.file_exists(path),
		"path=%s" % path)
	var text: String = str(res["text"])
	_check("头=标题行", text.begins_with("=== Infinite Fission 真机诊断日志 ==="), "head=%s" % text.substr(0, 40))
	_check("头含版本（与 version_string 同源）", text.contains("版本: %s" % DebugStats.version_string()),
		"ver=%s" % DebugStats.version_string())
	_check("头含 Godot 版本与设备名", text.contains("Godot") and text.contains(OS.get_name()),
		"缺 Godot/OS 行")
	_check("头含渲染后端与物理 Hz", text.contains("渲染:") and text.contains("physics %dHz" % Engine.physics_ticks_per_second),
		"缺渲染/物理行")
	_check("globalize 路径可示（dialog 展示）", DebugStats.diag_last_export_path != "",
		"last=%s" % DebugStats.diag_last_export_path)
	_check("剪贴板 headless 门（静默 false 不炸）", DebugStats.diag_copy_to_clipboard("x") == false,
		"headless 应 false")


# ── ⑦ 主菜单「导出日志」按钮 + 对话框链路 ──
func _test_7_menu_button_and_dialog() -> void:
	print("── ⑦ 主菜单导出按钮 ──")
	var menu: MenuScreen = _gl.menu_screen
	var btn: Button = menu.find_child("ExportLogButton", true, false) as Button
	_check("按钮存在且文案正确", btn != null and btn.text == "导出日志",
		"btn=%s" % str(btn))
	if btn == null:
		return
	_check("左下角落位（下锚负偏移）", btn.anchor_top == 1.0 and btn.anchor_bottom == 1.0
		and btn.offset_top < 0.0 and btn.offset_left >= 0.0,
		"anchor=(%f,%f) off=(%f,%f)" % [btn.anchor_left, btn.anchor_top, btn.offset_left, btn.offset_top])
	_check("版本脚注行在位（真源同 DebugStats）",
		menu.find_child("VersionFooter", true, false) != null
			or _menu_has_version_text(menu), "无版本行")
	# 对话框链路：按下 → 写文件 + AcceptDialog 弹出（headless 剪贴板 false 分支亦不炸）
	menu._on_export_log_pressed()
	if DebugStats.diag_last_export_path != "":
		_exported_paths.append("user://" + DebugStats.diag_last_export_path.get_file())
	var dlg: AcceptDialog = menu.find_child("DiagExportDialog", true, false) as AcceptDialog
	_check("导出后弹出预览对话框", dlg != null, "无 DiagExportDialog 子节点")
	if dlg != null:
		var inner: Label = dlg.find_child("DiagPreviewLabel", true, false) as Label
		_check("对话框带预览正文（头部说明+尾行）", inner != null and str(inner.text).contains("剪贴板"),
			"preview=%s" % (str(inner.text).substr(0, 40) if inner != null else "无"))
		dlg.visible = false
		dlg.queue_free()


func _menu_has_version_text(p_menu: Node) -> bool:
	# 版本行 Label 文本含 vc 段即认（节点名未固化——按内容兜底）
	var queue: Array[Node] = [p_menu]
	while not queue.is_empty():
		var n: Node = queue.pop_front()
		if n is Label and str((n as Label).text).contains("_vc"):
			return true
		for c in n.get_children():
			queue.append(c)
	return false


# ── ⑧ EventBus 风暴告警节流：计数口径不变（pkg0 契约）+ 节流游标在位 ──
func _test_8_storm_throttle_counter() -> void:
	print("── ⑧ 风暴告警节流 ──")
	var before: int = EventBus.storm_warnings
	for i in range(EventBus.STORM_WARN_THRESHOLD):
		EventBus.emit_mirror_formed("t")
	_check("阈值命中计数 +1（节流不吞计数）", EventBus.storm_warnings == before + 1,
		"delta=%d" % (EventBus.storm_warnings - before))
	_check("节流游标已置位（5s 窗内日志层静默）", EventBus._storm_warn_last_ms > 0,
		"last_ms=%d" % EventBus._storm_warn_last_ms)
	EventBus.end_frame()
	for i in range(8):
		EventBus.emit_mirror_formed("t")
	_check("阈值内不再计数（每帧每事件一次）", EventBus.storm_warnings == before + 1,
		"delta=%d" % (EventBus.storm_warnings - before))
	EventBus.end_frame()

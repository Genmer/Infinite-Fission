# tests/runner/r211_diagtoggle_cases.gd
# R211 诊断日志采样开关·用例体（由 test_r211_diagtoggle.gd 入口在 autoload 就绪后
# 运行时加载编译）。
# 背景：用户点名「诊断日志可选择是否记录」——加开关默认 true（现状不突变），关=每秒
# 不再采样写入（已存 _diag_lines 环形缓冲保留，导出/清空按钮不受影响），重开=下一拍
# 立即恢复。实施：Meta 双注册（SETTINGS_DEFAULTS + bool 归一分支，fx_opacity 同构）
# + DebugStats._diag_maybe_sample 首行采样门 + menu_screen 第三枚「记录日志」✓/✗ 按钮。
# 纪律：本套件关掉的 diag_log 收尾必须复位 true 并落盘（同进程后续用例 + 跨套件
# meta_save_test.cfg 持久污染双重防护——r205 ② 直调 _diag_maybe_sample 依赖默认开）。
# R212 翻案：主菜单底带第三枚「记录日志」按钮已迁入设置页（settings_panel
# 「记录日志」开关行 + 「日志长度」档位行）——⑦ 组改写为迁移断言：设置页两新行
# ✓/✗ 态/pressed 链路/档位 cycle + 菜单侧按钮已不存在；teardown 增补 diag_log_len
# 复位 240（⑦ 组 cycle 推档不留痕）。
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
	_test_1_default_on_no_regression()
	_test_2_double_registration()
	_test_3_gate_stops_sampling()
	_test_4_buffer_kept_and_reopen()
	_test_5_export_clear_unaffected()
	_test_6_persistence()
	_test_7_menu_button()
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


# ── 引导/拆除（同 r205 骨架；无需武器夹具——纯采样门与设置链验收） ──
func _boot_game_loop() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "R211GameLoopUnderTest"
	tree.get_root().add_child(_gl)
	_gl.state = GameConst.GameStatus.MENU
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	_gl.start_run()


func _teardown_game_loop() -> void:
	# 复位 true 并写即存落盘（r205 ② 直调 _diag_maybe_sample 依赖默认开——同进程后续
	# 用例与下一套件进程读 meta_save_test.cfg 均不再吃到关态）；R212：⑦ 组 cycle 推过
	# diag_log_len 档位——一并复位默认 240（防跨套件窄容量档污染）
	Meta.set_setting("diag_log", true)
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


# ── ① 默认开不突变：旧档缺键回退 true + 1Hz 节拍原口径不回归 ──
func _test_1_default_on_no_regression() -> void:
	print("── ① 默认开不突变 ──")
	Meta._settings.erase("diag_log")            # 模拟旧档无此键（读口默认表回退，零迁移）
	_check("缺键回退默认 true（现状不突变）", bool(Meta.settings("diag_log")) == true,
		"val=%s" % str(Meta.settings("diag_log")))
	DebugStats._diag_lines.clear()
	DebugStats._diag_cursor = 0
	DebugStats._diag_last_ms = Time.get_ticks_msec() - 1001
	DebugStats._diag_maybe_sample()
	DebugStats._diag_maybe_sample()
	_check("1Hz 节拍窗内不重复采样（r205 ② 口径不回归）", DebugStats._diag_lines.size() == 1,
		"size=%d" % DebugStats._diag_lines.size())


# ── ② 双注册命中：默认表 + bool 归一分支缺一不可 ──
func _test_2_double_registration() -> void:
	print("── ② 双注册命中 ──")
	Meta.set_setting("diag_log", false)
	_check("写口归一生效（非静默丢弃）", bool(Meta.settings("diag_log")) == false,
		"val=%s" % str(Meta.settings("diag_log")))
	Meta.set_setting("diag_log", 1)             # bool() 归一：int 1 → true（String 入参
	_check("int 入参归一强转", bool(Meta.settings("diag_log")) == true,  # 非法构造——本仓
		"val=%s" % str(Meta.settings("diag_log")))   # 写口从 UI 只传 bool，不在此例）
	Meta.set_setting("r211_not_a_real_key", true)   # 未知键写口仍拒（防脏写穿档不破）
	_check("未知键仍被拒（防御不破）", not Meta._settings.has("r211_not_a_real_key"),
		"keys=%s" % str(Meta._settings.keys()))


# ── ③ 采样门：关=每秒不再采样写入 ──
func _test_3_gate_stops_sampling() -> void:
	print("── ③ 关=停采 ──")
	Meta.set_setting("diag_log", false)
	DebugStats._diag_lines.clear()
	DebugStats._diag_cursor = 0
	DebugStats._diag_last_ms = Time.get_ticks_msec() - 1001
	for _i in range(5):
		DebugStats._diag_maybe_sample()
	_check("关后连调多次零写入", DebugStats._diag_lines.size() == 0,
		"size=%d" % DebugStats._diag_lines.size())


# ── ④ 已存缓冲保留（关不清账）+ 重开下一拍恢复 ──
func _test_4_buffer_kept_and_reopen() -> void:
	print("── ④ 缓冲保留+重开恢复 ──")
	Meta.set_setting("diag_log", true)
	DebugStats._diag_lines.clear()
	DebugStats._diag_cursor = 0
	DebugStats._diag_last_ms = Time.get_ticks_msec() - 1001
	DebugStats._diag_maybe_sample()
	var kept: int = DebugStats._diag_lines.size()
	_check("开态先采 1 行", kept == 1, "size=%d" % kept)
	var kept_line: String = DebugStats._diag_lines[0]
	Meta.set_setting("diag_log", false)          # 关：已存行不动
	DebugStats._diag_last_ms = Time.get_ticks_msec() - 1001
	DebugStats._diag_maybe_sample()
	_check("关后已存缓冲保留（size 不减）", DebugStats._diag_lines.size() == kept,
		"size=%d kept=%d" % [DebugStats._diag_lines.size(), kept])
	var res: Dictionary = DebugStats.diag_export()
	_exported_paths.append(str(res["path"]))
	_check("关态导出正文仍含已存行", str(res["text"]).contains(kept_line),
		"text 尾 40=%s" % str(res["text"]).substr(str(res["text"]).length() - 40, 40))
	Meta.set_setting("diag_log", true)           # 重开：节拍已过期即首采
	DebugStats._diag_last_ms = Time.get_ticks_msec() - 1001
	DebugStats._diag_maybe_sample()
	_check("重开下一拍恢复采样（size +1）", DebugStats._diag_lines.size() == kept + 1,
		"size=%d" % DebugStats._diag_lines.size())


# ── ⑤ 导出/清空按钮不受影响（关状态下照常工作） ──
func _test_5_export_clear_unaffected() -> void:
	print("── ⑤ 导出/清空不受影响 ──")
	Meta.set_setting("diag_log", false)
	var cleared: int = DebugStats.diag_clear()   # ④ 收尾留 2 行（同步段无引擎帧掺入）
	_check("关态清空返回清掉行数", cleared == 2, "cleared=%d" % cleared)
	_check("清空后缓冲归零", DebugStats._diag_lines.size() == 0,
		"size=%d" % DebugStats._diag_lines.size())
	var res: Dictionary = DebugStats.diag_export()
	_exported_paths.append(str(res["path"]))
	var text: String = str(res["text"])
	_check("空缓冲导出仅头不炸（无采样行）",
		text.begins_with("=== Infinite Fission 真机诊断日志 ===") and not text.contains("] fps"),
		"head=%s" % text.substr(0, 30))
	_check("再次清空返回 0（空缓冲）", DebugStats.diag_clear() == 0, "应 0")
	# 导出对话框链路（r205 ⑦ 同口径）：关状态点「导出日志」仍弹 DiagExportDialog
	var menu: MenuScreen = _gl.menu_screen
	menu._on_export_log_pressed()
	if DebugStats.diag_last_export_path != "":
		_exported_paths.append("user://" + DebugStats.diag_last_export_path.get_file())
	var dlg: AcceptDialog = menu.find_child("DiagExportDialog", true, false) as AcceptDialog
	_check("关态「导出日志」仍弹预览对话框", dlg != null, "无 DiagExportDialog 子节点")
	if dlg != null:
		dlg.visible = false
		dlg.queue_free()


# ── ⑥ 持久化：写即存落盘 + _load 重读（同链归一）+ 缺键回退 ──
func _test_6_persistence() -> void:
	print("── ⑥ 持久化 ──")
	Meta.set_setting("diag_log", false)          # 写即存（_save → settings/values）
	var cfg := ConfigFile.new()
	var loaded_ok: bool = cfg.load(Meta.save_path()) == OK
	var vals: Dictionary = cfg.get_value("settings", "values", {}) if loaded_ok else {}
	_check("存档 settings/values 含 diag_log=false", vals.get("diag_log", null) == false,
		"vals.diag_log=%s path=%s" % [str(vals.get("diag_log", "?")), Meta.save_path()])
	Meta._load()                                 # 模拟重启重读（settings 段整段重建）
	_check("_load 重读回 false（归一同链）", bool(Meta.settings("diag_log")) == false,
		"val=%s" % str(Meta.settings("diag_log")))
	Meta._settings.erase("diag_log")             # 再模拟旧档缺键 → 回退默认
	_check("重读后缺键回退 true", bool(Meta.settings("diag_log")) == true,
		"val=%s" % str(Meta.settings("diag_log")))


# ── ⑦ R212 迁移断言：开关入设置页（两新行）+ 主菜单底带按钮移除 ──
# 原断言锁 menu_screen 第三枚 DiagLogToggleButton（落位 246/文案/pressed 链路）——
# R212 迁移后该按钮不存在（菜单只在 _ready 构建一次会显过期 ✓/✗ 态，且设置页大厅/
# 暂停卡双入口局中局外均可达），改锁 settings_panel 两新行 + 菜单侧不存在。
func _test_7_menu_button() -> void:
	print("── ⑦ 迁移：菜单按钮 → 设置页两行 ──")
	var menu: MenuScreen = _gl.menu_screen
	_check("主菜单底带「记录日志」按钮已移除（find_child == null）",
		menu.find_child("DiagLogToggleButton", true, false) == null,
		"btn=%s" % str(menu.find_child("DiagLogToggleButton", true, false)))
	var sp: SettingsPanel = _gl.settings_panel
	var tbtn: Button = sp.find_child("DiagLogToggleButton", true, false) as Button
	var lbtn: Button = sp.find_child("DiagLenButton", true, false) as Button
	_check("设置页「记录日志」开关行在位（DiagLogToggleButton）", tbtn != null,
		"btn=%s" % str(tbtn))
	_check("设置页「日志长度」档位行在位（DiagLenButton）", lbtn != null,
		"btn=%s" % str(lbtn))
	if tbtn == null or lbtn == null:
		return
	# ✓/✗ 态随 Meta 翻转（同设置页其余开关口径）
	Meta.set_setting("diag_log", false)
	sp._refresh_toggles()
	_check("关态文案「✗ 关」", tbtn.text == "✗ 关", "text=%s" % tbtn.text)
	Meta.set_setting("diag_log", true)
	sp._refresh_toggles()
	_check("开态文案「✓ 开」", tbtn.text == "✓ 开", "text=%s" % tbtn.text)
	# pressed 链路：信号 → Meta 写口翻转 → 文案即时刷 → 采样行为即时翻转
	DebugStats._diag_lines.clear()
	DebugStats._diag_cursor = 0
	DebugStats._diag_last_ms = Time.get_ticks_msec() - 1001
	tbtn.pressed.emit()
	_check("pressed 后值翻转 false", bool(Meta.settings("diag_log")) == false,
		"val=%s" % str(Meta.settings("diag_log")))
	_check("pressed 后文案即时刷新", tbtn.text == "✗ 关", "text=%s" % tbtn.text)
	for _i in range(3):
		DebugStats._diag_maybe_sample()
	_check("翻转关后采样立停（size 保持 0）", DebugStats._diag_lines.size() == 0,
		"size=%d" % DebugStats._diag_lines.size())
	tbtn.pressed.emit()
	_check("再 pressed 翻回 true", bool(Meta.settings("diag_log")) == true,
		"val=%s" % str(Meta.settings("diag_log")))
	DebugStats._diag_maybe_sample()
	_check("翻回开即恢复采样（size 1）", DebugStats._diag_lines.size() == 1,
		"size=%d" % DebugStats._diag_lines.size())
	# 档位 cycle：240 → 360 → 60 → 120 → 240（find 不到的脏档一轮归位 240）
	Meta.set_setting("diag_log_len", 240)
	sp._refresh_toggles()
	_check("档位文案「✓ 240 行」", lbtn.text == "✓ 240 行", "text=%s" % lbtn.text)
	lbtn.pressed.emit()
	_check("cycle 一档 240→360", int(Meta.settings("diag_log_len")) == 360
		and lbtn.text == "✓ 360 行",
		"val=%s text=%s" % [str(Meta.settings("diag_log_len")), lbtn.text])
	for _i in range(3):
		lbtn.pressed.emit()
	_check("cycle 满一圈回 240", int(Meta.settings("diag_log_len")) == 240
		and lbtn.text == "✓ 240 行",
		"val=%s text=%s" % [str(Meta.settings("diag_log_len")), lbtn.text])
	Meta.set_setting("diag_log_len", 333)       # 脏档连续值（clampi 60~360 内直存）
	sp._refresh_toggles()
	lbtn.pressed.emit()
	_check("脏档 cycle 一轮归位 240", int(Meta.settings("diag_log_len")) == 240,
		"val=%s" % str(Meta.settings("diag_log_len")))

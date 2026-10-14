# tests/runner/r212_diaglog2_cases.gd
# R212 诊断日志升级·用例体（由 test_r212_diaglog2.gd 入口在 autoload 就绪后
# 运行时加载编译）。
# 用户三诉求落地验收：
# ①「记录日志」开关迁入设置页（原 R211 主菜单底带第三枚按钮移除）+「日志长度」
#   档位行 60/120/240/360 默认 240——Meta 双注册（默认表 + int 归一分支）；
# ② LEVEL_UP 选卡期不采样（选 buff 的帧率不计入日志）——节拍不消费（退出选卡回
#   PLAYING 首拍立即补采）、已存行保留；
# ③ 日志记录长度循环可选——容量设置驱动：缩容保留最新 N 条（旧条丢弃、游标语义
#   自洽）、持续 push 封顶不增长、扩容转正续写、导出头「采样 1Hz × N 行环形」动态化。
# 纪律：headless 测试档自动隔离（meta_save_test.cfg）；teardown 复位
# diag_log=true / diag_log_len=240 并落盘（防同进程后续用例与跨套件读档污染）；
# 导出的 user:// 诊断文件收尾清理。
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
	_test_1_key_contract()
	_test_2_capacity_switch()
	_test_3_level_up_gate()
	await _test_4_settings_rows_migration()
	_test_5_export_header_dynamic()
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


# ── 引导/拆除（同 r205/r211 骨架；无需武器夹具——纯采样门/设置链/容量语义验收） ──
func _boot_game_loop() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "R212GameLoopUnderTest"
	tree.get_root().add_child(_gl)
	_gl.state = GameConst.GameStatus.MENU
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	_gl.start_run()


func _teardown_game_loop() -> void:
	# R212 复位并写即存落盘：diag_log=true / diag_log_len=240（④⑤ 组改过两键——
	# 同进程后续用例与下一套件进程读 meta_save_test.cfg 均回默认口径）
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


# ── ① 键契约：双注册 + 默认 240 + int 归一 + 持久化回路 ──
func _test_1_key_contract() -> void:
	print("── ① 键契约（双注册/默认 240/归一） ──")
	_check("默认表注册（SETTINGS_DEFAULTS 含 diag_log_len=240）",
		Meta.SETTINGS_DEFAULTS.has("diag_log_len")
			and int(Meta.SETTINGS_DEFAULTS["diag_log_len"]) == 240,
		"val=%s" % str(Meta.SETTINGS_DEFAULTS.get("diag_log_len")))
	Meta._settings.erase("diag_log_len")            # 模拟旧档无此键（r211 ① 手法）
	_check("旧档缺键读口回默认 240（零迁移）", int(Meta.settings("diag_log_len")) == 240,
		"val=%s" % str(Meta.settings("diag_log_len")))
	_check("容量读口同回默认（_diag_capacity()==240）", DebugStats._diag_capacity() == 240,
		"cap=%d" % DebugStats._diag_capacity())
	# 归一分支：int 连续值 clampi(60,360)（{60,120,240,360} 档位集合由 UI cycle 保证，
	# 脏档连续值无害——环形缓冲任意容量可工作；UI find 不到时归位 240）
	Meta.set_setting("diag_log_len", 999)
	_check("写口归一上钳 999→360", int(Meta.settings("diag_log_len")) == 360,
		"val=%s" % str(Meta.settings("diag_log_len")))
	Meta.set_setting("diag_log_len", 1)
	_check("写口归一下钳 1→60", int(Meta.settings("diag_log_len")) == 60,
		"val=%s" % str(Meta.settings("diag_log_len")))
	Meta.set_setting("diag_log_len", 120)
	_check("档内值直写（120）+ 读口随档", int(Meta.settings("diag_log_len")) == 120
		and DebugStats._diag_capacity() == 120,
		"val=%s cap=%d" % [str(Meta.settings("diag_log_len")), DebugStats._diag_capacity()])
	# 未知键拒写（防脏写穿档不破——白名单归一口径）
	Meta.set_setting("r212_not_a_real_key", 240)
	_check("未知键仍被拒（白名单外静默丢弃）",
		not Meta._settings.has("r212_not_a_real_key"), "keys=%s" % str(Meta._settings.keys()))
	# 持久化回路：写即存落盘 + _load 归一同链重读 + 缺键回退
	var cfg := ConfigFile.new()
	var loaded_ok: bool = cfg.load(Meta.save_path()) == OK
	var vals: Dictionary = cfg.get_value("settings", "values", {}) if loaded_ok else {}
	_check("写即存落盘（settings/values.diag_log_len==120）",
		int(vals.get("diag_log_len", 0)) == 120, "vals=%s" % str(vals.get("diag_log_len", "?")))
	Meta._load()                                 # 模拟重启重读（settings 段整段重建）
	_check("_load 重读归一同链（120 过磁盘回路）", int(Meta.settings("diag_log_len")) == 120,
		"val=%s" % str(Meta.settings("diag_log_len")))
	Meta._settings.erase("diag_log_len")
	_check("重读后缺键回退 240", int(Meta.settings("diag_log_len")) == 240,
		"val=%s" % str(Meta.settings("diag_log_len")))


# ── ② 容量档切换：缩容保留最新 N 条 + 封顶不增长 + 扩容转正续写 ──
func _test_2_capacity_switch() -> void:
	print("── ② 容量档切换（缩容裁旧/封顶/扩容转正） ──")
	Meta.set_setting("diag_log_len", 360)
	DebugStats._diag_lines.clear()
	DebugStats._diag_cursor = 0
	for i in range(300):
		DebugStats._diag_push("line %d" % i)
	_check("预填 300 行 @360 档全部在缓冲", DebugStats._diag_lines.size() == 300,
		"size=%d" % DebugStats._diag_lines.size())
	# 缩容 360→120：档变化后首笔 push 触发重整（裁最旧只留最新 N 条），本行落最旧槽 0
	Meta.set_setting("diag_log_len", 120)
	_check("读口随档（_diag_capacity()==120）", DebugStats._diag_capacity() == 120,
		"cap=%d" % DebugStats._diag_capacity())
	DebugStats._diag_push("line 300")
	_check("缩容后缓冲封顶 120（只留最新 N 条）", DebugStats._diag_lines.size() == 120,
		"size=%d" % DebugStats._diag_lines.size())
	_check("新行落最旧槽 0（环形覆盖语义，[0]=line 300）",
		DebugStats._diag_lines[0] == "line 300", "[0]=%s" % DebugStats._diag_lines[0])
	_check("保留窗=旧数据最新 119 条（[1]=line 181 / [119]=line 299）",
		DebugStats._diag_lines[1] == "line 181" and DebugStats._diag_lines[119] == "line 299",
		"[1]=%s [119]=%s" % [DebugStats._diag_lines[1], DebugStats._diag_lines[119]])
	_check("最旧被裁（line 179/180 均不在）",
		not DebugStats._diag_lines.has("line 179") and not DebugStats._diag_lines.has("line 180"),
		"旧条残留")
	_check("游标前进一（裁剪归零后 cursor==1）", DebugStats._diag_cursor == 1,
		"cursor=%d" % DebugStats._diag_cursor)
	# 持续 push：容量封顶不增长 + 满环游标位=最旧
	for i in range(301, 351):
		DebugStats._diag_push("line %d" % i)
	_check("持续 push 容量封顶不增长", DebugStats._diag_lines.size() == 120,
		"size=%d" % DebugStats._diag_lines.size())
	_check("满环游标位=最旧槽（[cursor]=line 231）",
		DebugStats._diag_lines[DebugStats._diag_cursor] == "line 231",
		"cursor=%d slot=%s" % [DebugStats._diag_cursor,
			DebugStats._diag_lines[DebugStats._diag_cursor]])
	# 扩容 120→360：满环旋转序先转正（物理序回复时间序）再续写尾端，游标对齐 size
	Meta.set_setting("diag_log_len", 360)
	DebugStats._diag_push("line 351")
	_check("扩容后续写（size 121）", DebugStats._diag_lines.size() == 121,
		"size=%d" % DebugStats._diag_lines.size())
	var mono_ok := true
	for i in range(DebugStats._diag_lines.size()):
		if DebugStats._diag_lines[i] != "line %d" % (231 + i):
			mono_ok = false
			break
	_check("扩容转正后物理序=时间序（0..120 恰为 line 231..351 单调无缺）", mono_ok,
		"[0]=%s [1]=%s [120]=%s" % [DebugStats._diag_lines[0], DebugStats._diag_lines[1],
			DebugStats._diag_lines[120]])
	_check("扩容游标对齐（cursor==121==size）", DebugStats._diag_cursor == 121,
		"cursor=%d" % DebugStats._diag_cursor)
	Meta.set_setting("diag_log_len", 240)


# ── ③ LEVEL_UP 选卡期不采样：零新行 + 节拍不消费 + 已存行保留 + 退出补采 ──
func _test_3_level_up_gate() -> void:
	print("── ③ LEVEL_UP 选卡期不采样 ──")
	Meta.set_setting("diag_log", true)           # 显式回开（防磁盘档残留关态）
	DebugStats._diag_lines.clear()
	DebugStats._diag_cursor = 0
	DebugStats._diag_last_ms = Time.get_ticks_msec() - 1001
	DebugStats._diag_maybe_sample()
	var kept: int = DebugStats._diag_lines.size()
	_check("PLAYING 态节拍到点采样 1 行（基线）", kept == 1, "size=%d" % kept)
	var prev_state: int = _gl.state
	_gl.state = GameConst.GameStatus.LEVEL_UP
	DebugStats._diag_last_ms = Time.get_ticks_msec() - 1001
	var stale_ms: int = DebugStats._diag_last_ms
	for _i in range(3):
		DebugStats._diag_maybe_sample()
	_check("LEVEL_UP 期连调 3 次零新行（已存行保留）",
		DebugStats._diag_lines.size() == kept, "size=%d kept=%d" % [DebugStats._diag_lines.size(), kept])
	_check("节拍未消费（_diag_last_ms 不刷新——选卡期不清零）",
		DebugStats._diag_last_ms == stale_ms,
		"last=%d stale=%d" % [DebugStats._diag_last_ms, stale_ms])
	_gl.state = prev_state
	DebugStats._diag_maybe_sample()
	_check("回 PLAYING 首拍即补采（size +1，选卡结束恢复 1Hz）",
		DebugStats._diag_lines.size() == kept + 1, "size=%d" % DebugStats._diag_lines.size())


# ── ④ 迁移断言：设置页两新行 + 主菜单底带按钮移除 + 布局契约 ──
func _test_4_settings_rows_migration() -> void:
	print("── ④ 迁移：开关入设置页 ──")
	var menu: MenuScreen = _gl.menu_screen
	_check("主菜单底带「记录日志」按钮已移除（find_child == null）",
		menu.find_child("DiagLogToggleButton", true, false) == null, "仍存在 DiagLogToggleButton")
	_check("底带导出/清空两按钮原位不误伤",
		menu.find_child("ExportLogButton", true, false) != null
			and menu.find_child("ClearLogButton", true, false) != null, "缺导出/清空按钮")
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
	_check("pressed 翻转 false + 文案即时刷", bool(Meta.settings("diag_log")) == false
		and tbtn.text == "✗ 关",
		"val=%s text=%s" % [str(Meta.settings("diag_log")), tbtn.text])
	for _i in range(3):
		DebugStats._diag_maybe_sample()
	_check("翻转关后采样立停（size 保持 0）", DebugStats._diag_lines.size() == 0,
		"size=%d" % DebugStats._diag_lines.size())
	tbtn.pressed.emit()
	DebugStats._diag_maybe_sample()
	_check("再 pressed 翻回 true 即恢复采样（size 1）",
		bool(Meta.settings("diag_log")) == true and DebugStats._diag_lines.size() == 1,
		"val=%s size=%d" % [str(Meta.settings("diag_log")), DebugStats._diag_lines.size()])
	# 档位文案随 set_setting 翻转 + cycle 推进（360 → 环回 60）
	for v in [60, 120, 240, 360]:
		Meta.set_setting("diag_log_len", v)
		sp._refresh_toggles()
		_check("档位文案随 Meta 翻转（%d → 「✓ %d 行」）" % [v, v],
			lbtn.text == "✓ %d 行" % v, "text=%s" % lbtn.text)
	lbtn.pressed.emit()
	_check("cycle 推进 360→60（环回）", int(Meta.settings("diag_log_len")) == 60,
		"val=%s" % str(Meta.settings("diag_log_len")))
	# 布局契约（R202 S 口径续锁 + 两新行并入）：九行两两不重叠、末行底 ≤ hint 顶 824、
	# 卡高 968 不扩（行距 66→52、钮高 58→48 塞入——R202 只锁旧七行，本组锁全九行）
	sp.open()
	await tree.process_frame
	var btns: Array = [sp._fx_btn, sp._fps_btn, sp._shake_btn, sp._dmg_btn,
		sp._show_fps_btn, sp._diag_log_btn, sp._diag_len_btn, sp._pos_btn, sp._codex_reset_btn]
	var all_present := true
	for b in btns:
		if b == null:
			all_present = false
	var pair_overlap: Array[String] = []
	if all_present:
		for i in range(btns.size()):
			for j in range(i + 1, btns.size()):
				var ba := btns[i] as Control
				var bb := btns[j] as Control
				if ba.get_rect().intersects(bb.get_rect()):
					pair_overlap.append("%s∩%s" % [ba.name, bb.name])
	_check("九开关行按钮互不重叠（行距 52 / 钮高 48）",
		all_present and pair_overlap.is_empty(), str(pair_overlap))
	var last_btn: Control = btns[8] as Control if btns.size() == 9 else null
	var last_bottom: float = last_btn.position.y + last_btn.size.y if last_btn != null else 9999.0
	_check("末行按钮底 ≤ hint 顶 824（卡内不溢）", last_bottom <= 824.0 + 0.01,
		"bottom=%s" % str(last_bottom))
	_check("卡高不扩（offset_bottom==618 ∧ 卡高 968 钉死）",
		sp._card.offset_bottom == 618.0 and absf(sp._card.size.y - 968.0) < 0.01,
		"b=%s h=%s" % [str(sp._card.offset_bottom), str(sp._card.size.y)])
	sp.close()


# ── ⑤ 导出头动态化：「采样 1Hz × N 行环形」随档刷新 ──
func _test_5_export_header_dynamic() -> void:
	print("── ⑤ 导出头容量动态化 ──")
	Meta.set_setting("diag_log_len", 60)
	DebugStats._diag_lines.clear()
	DebugStats._diag_cursor = 0
	DebugStats._diag_push("r212 导出头探针行")
	var res: Dictionary = DebugStats.diag_export()
	_exported_paths.append(str(res["path"]))
	_check("头含「采样 1Hz × 60 行环形」（档 60）",
		str(res["text"]).contains("采样 1Hz × 60 行环形"), "头未随档 60 刷新")
	Meta.set_setting("diag_log_len", 240)
	res = DebugStats.diag_export()
	_exported_paths.append(str(res["path"]))
	_check("头含「采样 1Hz × 240 行环形」（默认档）",
		str(res["text"]).contains("采样 1Hz × 240 行环形"), "头未随档 240 刷新")
	_check("正文含已存探针行（容量切换不清账）",
		str(res["text"]).contains("r212 导出头探针行"), "探针行丢失")

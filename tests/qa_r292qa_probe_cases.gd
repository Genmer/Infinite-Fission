# tests/qa_r292qa_probe_cases.gd
# R292 QA 独立探针用例体（独立验收，不与开发套件共用断言路径）。
# 契约来源 = R292 验收点 1-7：
#   点1 按下当帧：覆盖层挂树可见+进度条 5%+文案「正在组装日志」+按钮禁用+锁置位；
#       遮罩全屏锚定 MOUSE_FILTER_STOP 且真实拦截底层点击（真输入注入对拍）。
#   点2 分段推进：进度单调不减；首段=组装、后续含剪贴板段；三段阶值 5/45/85 均被观测。
#   点3 收敛：DiagExportDialog 弹出（剪贴板状态行+尾部 24 行说明+标题带版本）、
#       覆盖层撤除、按钮恢复、锁复位。
#   点4 重入：同帧二连击与跨帧导出中再按均无操作（仅一覆盖层/不重置阶段/仅一对话框）。
#   点5 产物不变：diag_last_export_path 非空且 user:// 文件在盘+内容头口径（R205）。
#   点6 关闭对话框走 visibility_changed→queue_free 释放路径。
#   点7 边界探针：菜单态外（PLAYING 链）导出不炸；导出中 _root 释放/整棵 GameLoop
#       释放的悬挂安全；连续两次完整导出文件互不覆盖；diag_export 直调契约。
# 纪律：夹具不写 Meta boost 键，但收尾仍走 R270 毒配方（duplicate 还原+显式 erase+
# _save）；diag_*.txt 产物用完即删；真输入注入带正向对照（对照失败降级直调并如实标注）。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const CONV_FRAMES := 90                    # 收敛帧帽

var tree: SceneTree
var _gl: Node = null
var _menu: MenuScreen = null
var _btn: Button = null
var _clear_btn: Button = null
var _clear_fired: Dictionary = {"n": 0}     # 清空按钮 pressed 计数（点击拦截观测口）
var _input_ok: bool = false                 # 真输入注入链路是否生效（P1 前哨对照）
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _saved_settings: Dictionary = {}
var _saved_first_met: Dictionary = {}
var _saved_codex_weapons: Dictionary = {}
var _exported: Array[String] = []           # 本套件产出 diag 文件名（收尾删除）


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


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(292292)
	_saved_settings = Meta._settings.duplicate()
	_saved_first_met = Meta.codex_first_met.duplicate()
	_saved_codex_weapons = Meta.codex_weapons.duplicate()
	await _boot()
	_menu = _gl.menu_screen
	if _menu == null:
		_check("boot 后 menu_screen 在位", false, "menu_screen 为空")
		await _cleanup()
		return
	_btn = _menu.find_child("ExportLogButton", true, false) as Button
	_clear_btn = _menu.find_child("ClearLogButton", true, false) as Button
	_check("Z0 导出/清空按钮在位", _btn != null and _clear_btn != null,
		"btn=%s clear=%s" % [str(_btn), str(_clear_btn)])
	if _clear_btn != null:
		_clear_btn.pressed.connect(func() -> void: _clear_fired["n"] = int(_clear_fired["n"]) + 1)
	# ── 点1+2+3：真输入按下当帧 → 帧泵收敛 ──
	_p1_press_frame()
	await _p2_p3_staged_converge()
	await _p4_reentry()
	await _p7c_back_to_back_files()
	_p5_artifact()
	await _p6_dialog_release()
	# ── 点7a：菜单态外（真实 change_state 链 PLAYING）导出 ──
	await _p7a_outside_menu()
	# ── 点7b-1：导出中 _root 释放（守卫路径覆盖） ──
	await _p7b1_root_freed_midexport()
	await _teardown_gl()
	# ── boot #2：点7b-2 导出中整棵 GameLoop 释放（场景切换悬挂安全） ──
	await _boot()
	if _gl == null or _gl.menu_screen == null:
		_check("boot#2 成功", false, "二次引导失败")
	else:
		_menu = _gl.menu_screen
		_btn = _menu.find_child("ExportLogButton", true, false) as Button
		await _p7b2_gl_freed_midexport()
	# ── 点7d：diag_export 直调契约（多套件直调口径不变） ──
	_p7d_direct_contract()
	await _cleanup()


func _boot() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate()
	_gl.name = "R292QAProbe"
	tree.root.add_child(_gl)
	await tree.process_frame
	await tree.process_frame
	if not bool(_gl.get("boot_ready")):
		_check("boot 成功（main.tscn 真链）", false, str(_gl.get("boot_fatal")))
		_gl = null
		return
	_check("boot 成功（main.tscn 真链）", true, "")
	var menu_root: Control = null
	if _gl.menu_screen != null:
		menu_root = _gl.menu_screen.get("_root") as Control
	_check("boot 落 MENU（菜单根可见）", menu_root != null and menu_root.visible,
		str(menu_root != null and menu_root.visible))


# ── 真输入注入（Window.push_input 同步全链——r196 先例；720×1280 视口=canvas 域 1:1） ──
func _click_at(p_control: Control) -> void:
	var pos: Vector2 = p_control.get_global_rect().get_center()
	var dn := InputEventMouseButton.new()
	dn.button_index = MOUSE_BUTTON_LEFT
	dn.pressed = true
	dn.position = pos
	tree.root.push_input(dn, true)
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = pos
	tree.root.push_input(up, true)


# ── 点1：按下当帧的即时反馈 ──
func _p1_press_frame() -> void:
	print("── 点1 按下当帧（真输入注入优先，直调降级兜底） ──")
	# 前哨正向对照：无覆盖层时注入点击清空按钮必须生效（证明 harness 能点到 GUI）
	_click_at(_clear_btn)
	_input_ok = int(_clear_fired["n"]) == 1 and _clear_btn.text.begins_with("已清空")
	_check("1a 注入点击链路正向对照（清空按钮可被点到）", _input_ok,
		"fired=%s text=%s" % [str(_clear_fired["n"]), _clear_btn.text])
	# 按下导出（真输入；对照失败降级直调并如实标注）
	if _input_ok:
		_click_at(_btn)
	else:
		print("  HARNESS | 注入点击未生效——点1b 起降级直调 _on_export_log_pressed()（点击拦截探针将标注未执行）")
		_menu._on_export_log_pressed()
	var pressed_now: bool = _menu._exporting
	_check("1b 按下当帧即置锁（pressed 处理器已同步起跑）", pressed_now, str(pressed_now))
	var ov: Control = _menu._export_overlay
	_check("1c 当帧覆盖层挂树且可见", ov != null and is_instance_valid(ov)
		and ov.is_inside_tree() and ov.is_visible_in_tree(), str(ov))
	if ov != null:
		_check("1c2 覆盖层全屏锚定", ov.anchor_left == 0.0 and ov.anchor_right == 1.0
			and ov.anchor_top == 0.0 and ov.anchor_bottom == 1.0, "")
	var bar: ProgressBar = _menu._export_bar
	_check("1d 进度条在位 0-100 且起步 5%", bar != null and is_instance_valid(bar)
		and bar.min_value == 0.0 and bar.max_value == 100.0
		and is_equal_approx(bar.value, 5.0),
		"val=%s" % str(bar.value if bar != null else -1.0))
	var stage: Label = _menu._export_stage_lbl
	_check("1e 阶段文案=正在组装日志", stage != null and stage.text.contains("正在组装日志"),
		stage.text if stage != null else "无")
	var title_lbl: Label = null
	if ov != null:
		title_lbl = ov.find_child("DiagExportTitleLabel", true, false) as Label
	_check("1e2 覆盖层标题=正在导出日志", title_lbl != null
		and title_lbl.text == "正在导出日志", title_lbl.text if title_lbl != null else "无")
	var dim: ColorRect = null
	if ov != null:
		dim = ov.find_child("DiagExportDim", true, false) as ColorRect
	_check("1f 遮罩全屏锚定且 MOUSE_FILTER_STOP", dim != null
		and dim.mouse_filter == Control.MOUSE_FILTER_STOP
		and dim.anchor_left == 0.0 and dim.anchor_right == 1.0
		and dim.anchor_top == 0.0 and dim.anchor_bottom == 1.0, str(dim))
	_check("1g 按钮禁用+锁置位", _btn != null and _btn.disabled and _menu._exporting,
		"disabled=%s exporting=%s" % [str(_btn != null and _btn.disabled), str(_menu._exporting)])
	# 点击拦截负向探针：覆盖层期对清空按钮注入点击——应被遮罩吃掉（计数不涨）
	if _input_ok:
		var before: int = int(_clear_fired["n"])
		_click_at(_clear_btn)
		await_free_check(before)


func await_free_check(p_before: int) -> void:
	# 独立小函数避免同步函数里 await（点击同步生效，直接读即可）
	_check("1h 遮罩真实拦截底层点击（清空按钮计数不涨）",
		int(_clear_fired["n"]) == p_before,
		"before=%d after=%s" % [p_before, str(_clear_fired["n"])])


# ── 点2+3：帧泵收敛 ──
func _p2_p3_staged_converge() -> void:
	print("── 点2/3 分段推进与收敛 ──")
	var r := await _pump_until_settled()
	var samples: Array = r["samples"]
	var stages: Array = r["stages"]
	var mono: bool = samples.size() >= 2
	for i in range(1, samples.size()):
		if float(samples[i]) < float(samples[i - 1]):
			mono = false
	_check("2a 进度单调不减（逐帧采样）", mono, str(samples))
	var has_5: bool = samples.has(5.0)
	var has_45: bool = samples.has(45.0)
	var has_85: bool = samples.has(85.0)
	_check("2b 三段阶值 5/45/85 均被观测（真分段非一跳）", has_5 and has_45 and has_85,
		"samples=%s" % str(samples))
	var first_asm: bool = stages.size() >= 1 and String(stages[0]).contains("正在组装日志")
	var has_clip: bool = false
	for s in stages:
		if String(s).contains("剪贴板"):
			has_clip = true
	_check("2c 阶段文案按序（首=组装，含剪贴板段）", first_asm and has_clip, str(stages))
	var dlg: AcceptDialog = r["dlg"]
	_check("3a 预览对话框弹出且可见（收敛帧数=%d）" % int(r["frames"]),
		dlg != null and dlg.visible, str(r["frames"]))
	if dlg != null:
		_check("3b 对话框唯一", _count_named(_menu, "DiagExportDialog") == 1,
			"count=%d" % _count_named(_menu, "DiagExportDialog"))
		var inner: Label = dlg.find_child("DiagPreviewLabel", true, false) as Label
		_check("3c 正文口径：剪贴板状态行+尾部 24 行说明", inner != null
			and inner.text.contains("剪贴板") and inner.text.contains("尾部 24 行"),
			inner.text.substr(0, 40) if inner != null else "无")
		_check("3d 标题=诊断日志 · 版本（R205 同源）",
			dlg.title.begins_with("诊断日志 · ")
				and dlg.title.contains(DebugStats.version_string()), dlg.title)
		_check("3e 确认键文案=关闭", dlg.ok_button_text == "关闭", dlg.ok_button_text)
	_check("3f 收敛复位：覆盖层撤除+按钮恢复+锁复位",
		_menu._export_overlay == null and _btn != null and not _btn.disabled
			and not _menu._exporting,
		"ov=%s disabled=%s exporting=%s" % [str(_menu._export_overlay),
			str(_btn != null and _btn.disabled), str(_menu._exporting)])
	_record_exported()
	await _close_dialog()


# ── 点4：重入（同帧二连击 + 导出中跨帧再按） ──
func _p4_reentry() -> void:
	print("── 点4 重入锁 ──")
	# 4a 同帧二连击
	_menu._on_export_log_pressed()
	_menu._on_export_log_pressed()
	var ov_count: int = _count_named(_menu_root(), "DiagExportProgressOverlay")
	_check("4a 同帧二连击仅一覆盖层", ov_count == 1, "count=%d" % ov_count)
	_check("4a2 二连击不重置阶段（锁内直返）",
		_menu._export_stage_lbl != null and _menu._export_stage_lbl.text.contains("正在组装日志"),
		_menu._export_stage_lbl.text if _menu._export_stage_lbl != null else "无")
	var ra := await _pump_until_settled()
	_check("4b 二连击收敛后仅一对话框", ra["dlg"] != null
		and _count_named(_menu, "DiagExportDialog") == 1,
		"dlg=%s count=%d" % [str(ra["dlg"] != null), _count_named(_menu, "DiagExportDialog")])
	_record_exported()
	await _close_dialog()
	# 4c 导出中跨帧再按（阶段推进到 45 时二按）
	_menu._on_export_log_pressed()
	await tree.process_frame                     # 导出协程先醒：此刻应到 45 段
	var mid_val: float = _menu._export_bar.value if _menu._export_bar != null else -1.0
	_check("4c 前置：一帧后阶段=45（导出进行中）", is_equal_approx(mid_val, 45.0),
		"val=%s" % str(mid_val))
	_menu._on_export_log_pressed()               # 导出中再按
	var ov2: int = _count_named(_menu_root(), "DiagExportProgressOverlay")
	var val_after: float = _menu._export_bar.value if _menu._export_bar != null else -1.0
	_check("4d 导出中再按=无操作（仍一覆盖层且进度不重置）",
		ov2 == 1 and is_equal_approx(val_after, 45.0),
		"ov=%d val=%s" % [ov2, str(val_after)])
	var rb := await _pump_until_settled()
	_check("4e 该轮收敛后仍仅一对话框", rb["dlg"] != null
		and _count_named(_menu, "DiagExportDialog") == 1,
		"dlg=%s count=%d" % [str(rb["dlg"] != null), _count_named(_menu, "DiagExportDialog")])
	_record_exported()
	await _close_dialog()


# ── 点7c：连续两次完整导出文件互不覆盖 ──
func _p7c_back_to_back_files() -> void:
	print("── 点7c 连续两次完整导出的文件互不覆盖 ──")
	_menu._on_export_log_pressed()
	var ra := await _pump_until_settled()
	_record_exported()
	var path_a: String = DebugStats.diag_last_export_path
	await _close_dialog()
	_menu._on_export_log_pressed()
	var rb := await _pump_until_settled()
	_record_exported()
	var path_b: String = DebugStats.diag_last_export_path
	_check("7c 两次导出文件路径互不相同（不覆盖）", path_a != path_b,
		"A=%s B=%s" % [path_a, path_b])
	if path_a == path_b:
		print("  EVIDENCE | 同秒连导文件名冲突（HHMMSS 粒度）：A=B=%s" % path_a)
	await _close_dialog()


# ── 点5：产物不变 ──
func _p5_artifact() -> void:
	print("── 点5 导出产物 ──")
	var last: String = DebugStats.diag_last_export_path
	var fname: String = last.get_file()
	var on_disk: bool = last != "" and FileAccess.file_exists("user://" + fname)
	_check("5a 导出路径非空且 user:// 文件在盘", on_disk, last)
	if on_disk:
		var content: String = FileAccess.get_file_as_string("user://" + fname)
		_check("5b 文件内容头口径（R205：诊断日志头+版本行）",
			content.contains("=== Infinite Fission 真机诊断日志 ===")
				and content.contains("版本: "), content.substr(0, 40))


# ── 点6：关闭对话框走既有释放路径 ──
func _p6_dialog_release() -> void:
	print("── 点6 对话框关闭释放 ──")
	_menu._on_export_log_pressed()               # 自跑一轮完整导出（不依赖前序残留）
	var r := await _pump_until_settled()
	_check("6a 待关对话框在位", r["dlg"] != null, str(r["frames"]))
	if r["dlg"] != null:
		r["dlg"].visible = false
	await tree.process_frame
	await tree.process_frame
	_check("6b 关后帧泵即无残留（visibility_changed→queue_free）",
		_menu.find_child("DiagExportDialog", true, false) == null, "")
	_record_exported()


# ── 点7a：菜单态外（PLAYING 链）导出 ──
func _p7a_outside_menu() -> void:
	print("── 点7a 菜单态外（真实 PLAYING 迁移）导出 ──")
	var ok1: bool = _gl.change_state(GameConst.GameStatus.PLAYING)
	var root_hidden: bool = not (_menu.get("_root") as Control).visible
	_check("7a 前置：真实迁移 PLAYING 且菜单根隐藏", ok1 and root_hidden,
		"ok=%s hidden=%s" % [str(ok1), str(root_hidden)])
	_menu._on_export_log_pressed()
	var r := await _pump_until_settled()
	_check("7a PLAYING 态导出不炸且收敛（对话框弹出）", r["dlg"] != null, str(r["frames"]))
	_check("7a2 收敛后锁复位（无悬挂导出态）", not _menu._exporting
		and _menu._export_overlay == null,
		"exporting=%s ov=%s" % [str(_menu._exporting), str(_menu._export_overlay)])
	_record_exported()
	await _close_dialog()
	# 回 MENU（迁移矩阵 PLAYING→GAME_OVER→MENU）恢复现场
	_gl.change_state(GameConst.GameStatus.GAME_OVER)
	_gl.change_state(GameConst.GameStatus.MENU)
	_check("7a3 现场恢复：回 MENU 菜单根可见",
		(_menu.get("_root") as Control) != null and (_menu.get("_root") as Control).visible, "")


# ── 点7b-1：导出中 _root 释放（协程守卫路径覆盖） ──
func _p7b1_root_freed_midexport() -> void:
	print("── 点7b-1 导出中 _root 释放悬挂安全 ──")
	_menu._on_export_log_pressed()
	await tree.process_frame                     # 到 45 段（覆盖层/进度条在树）
	var menu_root: Control = _menu.get("_root") as Control
	menu_root.queue_free()
	# R292-M1 修轮适配：最小展示时长 300ms 为墙钟语义——帧帽改墙钟死线（2.5s）
	var frames := 0
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 2500:
		await tree.process_frame
		frames += 1
		if not _menu._exporting and _menu._export_overlay == null:
			break
	_check("7b1 _root 释放后协程仍收敛（锁复位无悬挂）", not _menu._exporting,
		"frames=%d exporting=%s" % [frames, str(_menu._exporting)])
	var dlg: AcceptDialog = _menu.find_child("DiagExportDialog", true, false) as AcceptDialog
	_check("7b1-2 对话框仍弹出（挂在 CanvasLayer 不随 _root 亡）", dlg != null, "")
	_record_exported()
	await _close_dialog()


func _teardown_gl() -> void:
	if _gl != null and is_instance_valid(_gl):
		_gl.free()
	_gl = null
	_menu = null
	_btn = null
	_clear_btn = null
	_clear_fired["n"] = 0
	await tree.process_frame


# ── 点7b-2：导出中整棵 GameLoop 释放（场景切换当量） ──
func _p7b2_gl_freed_midexport() -> void:
	print("── 点7b-2 导出中整棵 GameLoop 释放悬挂安全 ──")
	_menu._on_export_log_pressed()
	await tree.process_frame                     # 45 段悬挂中
	_gl.free()                                   # 同步释放整树（协程宿主亡）
	var alive := true
	for i in range(8):
		await tree.process_frame
	_check("7b2 场景释放后进程存活无致命错（帧泵继续）", alive, "")
	var residue: int = _count_named(tree.root, "DiagExportProgressOverlay")
	_check("7b2-2 树上无覆盖层残留（随宿主释放）", residue == 0, "count=%d" % residue)
	_gl = null
	_menu = null


# ── 点7d：diag_export 直调契约回归 ──
func _p7d_direct_contract() -> void:
	print("── 点7d DebugStats.diag_export 直调契约 ──")
	for i in range(2):
		var res: Dictionary = DebugStats.diag_export()
		var keys_ok: bool = res.has("path") and res.has("text") and str(res["path"]) != ""
		var fexists: bool = keys_ok and FileAccess.file_exists("user://" + str(res["path"]).get_file())
		_check("7d 直调#%d 返回 {path,text} 且文件在盘" % (i + 1), keys_ok and fexists,
			"path=%s" % str(res.get("path", "")))
		var text_ok: bool = str(res["text"]).contains("=== Infinite Fission 真机诊断日志 ===")
		_check("7d-2 直调#%d 正文含诊断头（口径不变）" % (i + 1), text_ok,
			str(res["text"]).substr(0, 30))
		if keys_ok:
			var fn := str(res["path"]).get_file()
			if not _exported.has(fn):
				_exported.append(fn)


# ── 辅助 ──
func _pump_until_settled() -> Dictionary:
	var samples: Array = []
	var stages: Array = []
	var frames: int = 0
	var dlg: AcceptDialog = null
	# R292-M1 修轮适配：覆盖层最小展示时长 300ms 为墙钟语义（headless 帧率无上界，
	# 帧帽会先行耗尽）——收敛口改墙钟死线（5s）。
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 5000:
		frames += 1
		var bar: ProgressBar = _menu._export_bar
		if bar != null and is_instance_valid(bar):
			samples.append(bar.value)      # 逐帧原始值（非去重——单调性诚实采样）
			var st: Label = _menu._export_stage_lbl
			if st != null and is_instance_valid(st) and not stages.has(st.text):
				stages.append(st.text)
		dlg = _menu.find_child("DiagExportDialog", true, false) as AcceptDialog
		if dlg != null and _menu._export_overlay == null:
			break
		await tree.process_frame
	return {"dlg": dlg, "samples": samples, "stages": stages, "frames": frames}


func _close_dialog() -> void:
	var dlg: AcceptDialog = _menu.find_child("DiagExportDialog", true, false) as AcceptDialog
	if dlg != null:
		dlg.visible = false
	await tree.process_frame
	await tree.process_frame


func _count_named(p_node: Node, p_name: String) -> int:
	var n: int = 0
	if p_node == null:
		return 0
	if p_node.name == p_name:
		n += 1
	for c in p_node.get_children():
		n += _count_named(c, p_name)
	return n


func _menu_root() -> Control:
	if _menu == null:
		return null
	return _menu.get("_root") as Control


func _record_exported() -> void:
	var last: String = DebugStats.diag_last_export_path
	if last != "":
		var fname := last.get_file()
		if not _exported.has(fname):
			_exported.append(fname)


func _cleanup() -> void:
	print("── 收尾（GL/对话框/产物文件/Meta 还原） ──")
	if _gl != null and is_instance_valid(_gl):
		_gl.free()
	var dir := DirAccess.open("user://")
	if dir != null:
		for fname in _exported:
			if dir.file_exists(fname):
				dir.remove(fname)
	# R270 盘档毒配方：还原快照后显式 erase 本套件可能写过的键再落盘
	Meta.codex_first_met = _saved_first_met.duplicate()
	Meta.codex_weapons = _saved_codex_weapons.duplicate()
	Meta._settings = _saved_settings.duplicate()
	Meta._settings.erase("perf_boost")
	Meta._settings.erase("boost_res")
	Meta._save()
	await tree.process_frame
	print("探针汇总：%d/%d 通过" % [_pass, _pass + _fail])
	if _fail > 0:
		for f in _failures:
			print("  FAIL 项：%s" % f)

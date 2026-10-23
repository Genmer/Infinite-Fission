# tests/qa_r292_export_progress_cases.gd
# R292 独立验收用例体。契约来源 = 验收点 1-6（导出日志分段进度反馈）：
#   点1 按下当帧：进度覆盖层挂树可见（DiagExportProgressOverlay：全屏遮罩 STOP+
#       进度条 0-100 起步 5%+阶段文案「正在组装日志」），按钮禁用，重入锁置位。
#   点2 分段推进：进度采样单调不减；阶段文案首段=组装、后续含剪贴板段。
#   点3 收敛：DiagExportDialog 弹出（预览正文含剪贴板状态行+尾部 24 行说明+版本
#       标题——R205 既有口径），覆盖层撤除，按钮恢复，锁复位。
#   点4 重入：导出中同帧二连击=无操作（仅一覆盖层；收敛后仅一对话框）。
#   点5 产物不变：diag_last_export_path 非空且 user:// 文件在盘。
#   点6 关闭对话框走既有 visibility_changed 释放路径（关后帧泵即无残留）。
# 夹具：main.tscn 真链 boot（落 MENU——菜单根可见），不切状态不冻结进程
#（真实帧泵驱动协程收敛）；收尾还原 Meta（含 R270 盘档毒显式 erase 配方）并清
# 本套件产出的 diag 文件。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const CONV_DEADLINE_MS := 5000              # 收敛墙钟死线（R292-M1 最小展示时长后弹框）

var tree: SceneTree
var _gl: Node = null
var _menu: MenuScreen = null
var _btn: Button = null
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _saved_settings: Dictionary = {}
var _saved_first_met: Dictionary = {}
var _saved_codex_weapons: Dictionary = {}
var _exported: Array[String] = []          # 本套件产出 diag 文件名（收尾删除）


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
	seed(292)
	_saved_settings = Meta._settings.duplicate()
	_saved_first_met = Meta.codex_first_met.duplicate()
	_saved_codex_weapons = Meta.codex_weapons.duplicate()
	await _boot()
	_menu = _gl.menu_screen
	if _menu == null:
		_check("menu_screen 在位", false, "boot 后 menu_screen 为空")
		await _cleanup()
		return
	_check("menu_screen 在位", true, "")
	_btn = _menu.find_child("ExportLogButton", true, false) as Button
	_p1_immediate_feedback()
	await _p2_p3_staged_converge()
	await _p4_reentry_guard()
	_p5_artifact()
	await _p6_dialog_release()
	await _cleanup()


func _boot() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate()
	_gl.name = "R292ExportProgress"
	tree.root.add_child(_gl)
	await tree.process_frame
	await tree.process_frame
	if not bool(_gl.get("boot_ready")):
		_check("boot 成功（main.tscn 真链）", false, str(_gl.get("boot_fatal")))
	else:
		_check("boot 成功（main.tscn 真链）", true, "")
	# boot 落 MENU（菜单根可见——覆盖层树内可见断言的前提；此时 _menu 尚未赋值，
	# 直取 _gl.menu_screen）
	var menu_root: Control = null
	if _gl.menu_screen != null:
		menu_root = _gl.menu_screen.get("_root") as Control
	_check("boot 落 MENU（菜单根可见）", menu_root != null and menu_root.visible,
		str(menu_root != null and menu_root.visible))


# ── 点1：按下当帧的即时反馈（不 await——断言协程首个 await 挂起前的状态） ──
func _p1_immediate_feedback() -> void:
	print("── 点1 按下当帧：覆盖层/进度条/禁用/锁 ──")
	_check("1a 导出按钮在位", _btn != null and _btn.text == "导出日志",
		"btn=%s" % str(_btn))
	_menu._on_export_log_pressed()          # 不 await：当帧态
	var ov: Control = _menu._export_overlay
	_check("1b 当帧覆盖层已挂树", ov != null and is_instance_valid(ov), str(ov))
	var bar: ProgressBar = _menu._export_bar
	var bar_ok: bool = bar != null and is_instance_valid(bar) and is_equal_approx(bar.value, 5.0)
	_check("1c 进度条在位且起步 5%", bar_ok,
		"val=%s" % str(bar.value if bar != null else -1.0))
	var stage: Label = _menu._export_stage_lbl
	_check("1d 阶段文案=正在组装日志", stage != null and stage.text.contains("正在组装日志"),
		stage.text if stage != null else "无")
	_check("1e 覆盖层树内可见", ov != null and ov.visible and ov.is_visible_in_tree(), "")
	var dim: ColorRect = null
	if ov != null:
		dim = ov.find_child("DiagExportDim", true, false) as ColorRect
	_check("1f 遮罩全屏锚定且挡点击（STOP）", dim != null
		and dim.mouse_filter == Control.MOUSE_FILTER_STOP
		and dim.anchor_left == 0.0 and dim.anchor_right == 1.0
		and dim.anchor_top == 0.0 and dim.anchor_bottom == 1.0, str(dim))
	_check("1g 按钮禁用+重入锁置位", _btn != null and _btn.disabled and _menu._exporting,
		"disabled=%s exporting=%s" % [str(_btn != null and _btn.disabled), str(_menu._exporting)])


# ── 点2+3：帧泵收敛——分段推进/单调性/对话框弹出/收尾复位 ──
func _p2_p3_staged_converge() -> void:
	print("── 点2/3 分段推进与收敛 ──")
	var r := await _pump_until_dialog()
	var samples: Array = r["samples"]
	var stages: Array = r["stages"]
	var mono: bool = samples.size() >= 2
	for i in range(1, samples.size()):
		if float(samples[i]) < float(samples[i - 1]):
			mono = false
	_check("2a 进度单调不减（≥2 采样）", mono, str(samples))
	var first_asm: bool = stages.size() >= 1 and String(stages[0]).contains("正在组装日志")
	var has_clip: bool = false
	for s in stages:
		if String(s).contains("剪贴板"):
			has_clip = true
	_check("2b 阶段文案按序（首=组装，含剪贴板段）", first_asm and has_clip, str(stages))
	var dlg: AcceptDialog = r["dlg"]
	_check("3a 预览对话框弹出（收敛帧数=%d）" % int(r["frames"]), dlg != null, str(r["frames"]))
	if dlg != null:
		var inner: Label = dlg.find_child("DiagPreviewLabel", true, false) as Label
		_check("3b 对话框口径不变（剪贴板行+尾部 24 行说明）", inner != null
			and inner.text.contains("剪贴板") and inner.text.contains("尾部 24 行"),
			inner.text.substr(0, 40) if inner != null else "无")
		_check("3c 标题带版本（R205 同源）", dlg.title.contains(DebugStats.version_string()),
			dlg.title)
	_check("3d 覆盖层撤除+按钮恢复+锁复位",
		_menu._export_overlay == null and _btn != null and not _btn.disabled
			and not _menu._exporting,
		"ov=%s disabled=%s exporting=%s" % [str(_menu._export_overlay),
			str(_btn != null and _btn.disabled), str(_menu._exporting)])
	_record_exported()


# ── 点4：导出中同帧二连击=无操作 ──
func _p4_reentry_guard() -> void:
	print("── 点4 重入锁（二连击） ──")
	# 先释放上一轮对话框（关→visibility_changed→queue_free；帧泵两帧落定）
	var dlg0: AcceptDialog = _menu.find_child("DiagExportDialog", true, false) as AcceptDialog
	if dlg0 != null:
		dlg0.visible = false
		await tree.process_frame
		await tree.process_frame
	_check("4a 前轮对话框已释放", _menu.find_child("DiagExportDialog", true, false) == null, "")
	_menu._on_export_log_pressed()
	_menu._on_export_log_pressed()          # 同帧二连击——应被锁挡下
	var ov_count: int = _count_named(_menu_root(), "DiagExportProgressOverlay")
	_check("4b 二连击仅一覆盖层", ov_count == 1, "count=%d" % ov_count)
	_check("4c 二连击不重置阶段（锁内直返）",
		_menu._export_stage_lbl != null and _menu._export_stage_lbl.text.contains("正在组装日志"),
		_menu._export_stage_lbl.text if _menu._export_stage_lbl != null else "无")
	var r := await _pump_until_dialog()
	_check("4d 收敛后仅一对话框", r["dlg"] != null
		and _count_named(_menu, "DiagExportDialog") == 1,
		"dlg=%s count=%d" % [str(r["dlg"] != null), _count_named(_menu, "DiagExportDialog")])
	_record_exported()


# ── 点5：产物不变（diag_export 原口径） ──
func _p5_artifact() -> void:
	print("── 点5 导出产物 ──")
	var last: String = DebugStats.diag_last_export_path
	_check("5a 导出路径非空且文件在盘", last != ""
		and FileAccess.file_exists("user://" + last.get_file()), last)


# ── 点6：关闭对话框走既有释放路径 ──
func _p6_dialog_release() -> void:
	print("── 点6 对话框关闭释放 ──")
	var dlg: AcceptDialog = _menu.find_child("DiagExportDialog", true, false) as AcceptDialog
	_check("6a 待关对话框在位", dlg != null, "")
	if dlg != null:
		dlg.visible = false
	await tree.process_frame
	await tree.process_frame
	_check("6b 关后帧泵即无残留（visibility_changed→queue_free）",
		_menu.find_child("DiagExportDialog", true, false) == null, "")


func _pump_until_dialog() -> Dictionary:
	# 帧泵至 DiagExportDialog 出现且覆盖层撤除，或超墙钟死线；逐帧采样进度值与阶段文案。
	# R292-M1 修轮：覆盖层最小展示时长 300ms 是墙钟语义——headless 帧率无上界，
	# 纯帧帽会被先行耗尽，收敛口改墙钟死线（5s）。
	var samples: Array = []
	var stages: Array = []
	var frames: int = 0
	var dlg: AcceptDialog = null
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < CONV_DEADLINE_MS:
		frames += 1
		var bar: ProgressBar = _menu._export_bar
		if bar != null and is_instance_valid(bar):
			samples.append(bar.value)
			var st: Label = _menu._export_stage_lbl
			if st != null and is_instance_valid(st) and not stages.has(st.text):
				stages.append(st.text)
		dlg = _menu.find_child("DiagExportDialog", true, false) as AcceptDialog
		if dlg != null and _menu._export_overlay == null:
			break
		await tree.process_frame
	return {"dlg": dlg, "samples": samples, "stages": stages, "frames": frames}


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
	print("── 收尾（对话框/产物文件/Meta 还原） ──")
	if _menu != null:
		var dlg: AcceptDialog = _menu.find_child("DiagExportDialog", true, false) as AcceptDialog
		if dlg != null:
			dlg.queue_free()
	var dir := DirAccess.open("user://")
	if dir != null:
		for fname in _exported:
			if dir.file_exists(fname):
				dir.remove(fname)
	# R270 盘档毒配方：本套件写过的键显式 erase 再落盘（防跨进程毒后续套件）
	Meta.codex_first_met = _saved_first_met.duplicate()
	Meta.codex_weapons = _saved_codex_weapons.duplicate()
	Meta._settings = _saved_settings.duplicate()
	Meta._settings.erase("perf_boost")
	Meta._settings.erase("boost_res")
	Meta._save()
	_gl.queue_free()
	await tree.process_frame
	print("验收汇总：%d/%d 通过" % [_pass, _pass + _fail])
	if _fail > 0:
		for f in _failures:
			print("  FAIL 项：%s" % f)

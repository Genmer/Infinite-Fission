# tests/qa288_continue_probe_cases.gd（QA288 探针用例体——运行时加载）
# 取证三事：
#   P1-P4 continue_run 恢复构筑后 DebugStats._diag_build_lines 仍为旧快照（不刷新）。
#   P5 强制选卡回窗刷新后 遗物行=0件 而 relic_handler.owned 实为 1（owned_relics 双源分歧）。
#   P6 daily 局快照打印大厅祝福记忆（未购）而该词条在 daily 守卫下从未挂载。
# 纪律：Meta 祝福记忆变量直改不落盘（收尾还原）；RunSave 用毕 clear；不触被测代码。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const RELIC_ID := &"REL_ATTACK_CDR"

var tree: SceneTree
var _gl: Node = null
var _pass: int = 0
var _fail: int = 0
var _saved_blessing := ""


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	_boot()
	PerfGovernor.set_process(false)
	PerfGovernor.mode_override = -1
	PerfGovernor.tier_override = 3
	PerfGovernor.boost_override = -1
	RunSave.clear()
	_p1_to_p5_continue_gap()
	_p6_daily_blessing_line()
	_cleanup()


func fail_count() -> int:
	return _fail


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("  PASS | %s" % p_name)
	else:
		_fail += 1
		print("  FAIL | %s（%s）" % [p_name, p_detail])


func _boot() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate()
	_gl.name = "QA288ContinueProbe"
	tree.root.add_child(_gl)
	if not (_gl.get("boot_ready") and _gl.state == GameConst.GameStatus.MENU):
		push_error("[qa288] Boot 失败")
		_fail += 1


func _snapshot_join() -> String:
	return "\n".join(DebugStats._diag_build_lines)


func _p1_to_p5_continue_gap() -> void:
	print("── P1-P5 continue_run 快照缺口 ──")
	_check("P1 start_run 成功", bool(_gl.start_run()), "")
	var w0: WeaponBase = _gl.player.weapon_slots[0]
	_check("P1 开局快照在位（含 [武器] 槽0）", _snapshot_join().contains("[武器] 槽0"), "")
	_check("P1 开局快照为 Lv1", _snapshot_join().contains("Lv1"), _snapshot_join())
	# 构筑演化：武器 Lv1→5 + 激活 1 遗物（serialize 真源=relic_handler.owned）
	for i in 4:
		w0.level_up()
	var relic_ok: bool = _gl.relic_handler.activate(RELIC_ID)
	_check("P2 遗物激活成功（serialize 真源）", relic_ok, "")
	RunSave.save_run(_gl.serialize_run())
	_check("P2 存档武器 Lv5", int(RunSave.load_run().get("weapons", [{}])[0].get("level", 1)) == 5, "")
	# 回菜单（需 PAUSED 入口）→ 继续档
	_check("P3 P→PAUSED", bool(_gl.change_state(GameConst.GameStatus.PAUSED)), "")
	_check("P3 quit_to_menu", bool(_gl.quit_to_menu()), "")
	var lines_before := _snapshot_join()
	_check("P3 菜单态快照保留旧局（quit 不清快照）", lines_before != "", "")
	_check("P4 continue_run 成功", bool(_gl.continue_run()), "")
	var w0c: WeaponBase = _gl.player.weapon_slots[0]
	_check("P4 恢复后实武器 Lv5", w0c != null and w0c.level == 5, "lv=%s" % str(w0c.level if w0c != null else -1))
	_check("P4 恢复后实遗物 1 件（relic_handler.owned）", _gl.relic_handler.owned.size() == 1,
		"owned=%d" % _gl.relic_handler.owned.size())
	var snap_after := _snapshot_join()
	_check("P4 ★快照未刷新：仍含 Lv1 不含 Lv5（continue 后导出=旧构筑误导）",
		snap_after.contains("Lv1") and not snap_after.contains("Lv5"), snap_after)
	_check("P4 快照与继续前逐字节相同", snap_after == lines_before, "")
	# 强制走一次选卡回窗（LEVEL_UP→PLAYING 钩）→ 快照刷新但遗物行双源分歧
	_check("P5 P→LEVEL_UP", bool(_gl.change_state(GameConst.GameStatus.LEVEL_UP)), "")
	_check("P5 LEVEL_UP→P", bool(_gl.change_state(GameConst.GameStatus.PLAYING)), "")
	var snap_refreshed := _snapshot_join()
	_check("P5 刷新后快照含 Lv5（武器面追平）", snap_refreshed.contains("Lv5"), snap_refreshed)
	_check("P5 ★刷新后快照遗物=0件 而 实际激活 1 件（owned_relics 双源分歧→归因漏报）",
		snap_refreshed.contains("遗物0件") and _gl.relic_handler.owned.size() == 1, snap_refreshed)


func _p6_daily_blessing_line() -> void:
	print("── P6 daily 局祝福行 ──")
	_saved_blessing = String(Meta.blessing_trait_id)
	Meta.blessing_trait_id = "AFF_ATK_UP"          # 直改变量（不落盘——收尾还原）
	_check("P6 回菜单", bool(_gl.change_state(GameConst.GameStatus.PAUSED)) and bool(_gl.quit_to_menu()), "")
	_check("P6 start_run(daily) 成功", bool(_gl.start_run(20261017)), "")
	_check("P6 daily 态确认", bool(Meta.is_run_daily()), "")
	var snap := _snapshot_join()
	_check("P6 ★快照打印大厅祝福记忆(未购) 而该词条 daily 守卫下从未挂载",
		snap.contains("祝福AFF_ATK_UP(未购)") and not _blessing_mounted(), snap)
	_check("P6 当日 bless 词缀（实际生效面）不出现在快照",
		not (snap.contains("bless_")), snap)


func _blessing_mounted() -> bool:
	for w in _gl.player.weapon_slots:
		if w == null or w.trait_stack == null:
			continue
		for tb in w.trait_stack.traits:
			if tb.data != null and String(tb.data.id) == "AFF_ATK_UP":
				return true
	return false


func _cleanup() -> void:
	Meta.blessing_trait_id = _saved_blessing
	if _gl != null and _gl.state == GameConst.GameStatus.PLAYING:
		_gl.change_state(GameConst.GameStatus.PAUSED)
		_gl.quit_to_menu()
	RunSave.clear()
	print("探针汇总：%d/%d 通过" % [_pass, _pass + _fail])

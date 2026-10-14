# R267 刀P4 面板关闭脏标记落盘用例体（qa_r267_meta_dirty 入口 load）
# 口径（设计 §1.4）：
#   a) 零写口面板会话 end 不触发 _save/_check_achievements（diag_save_calls/
#      diag_ach_full_scans 观测口计数断言）；
#   b) 有写口（buy_upgrade）批内抑制 → 收口恰各执行一次并清位；
#   c) cancel_persist_defer 无条件结清；结算路径 _save 直调 + map_records_changed 照发；
#   d) 链路：面板内购买→关面板→盘上 ConfigFile 可读回（防漏置位=数据丢失）；
#   µs) 面板关链（begin/end 零写口对）≤150µs（桌面基线 879µs：扫178+盘673+角标118）。
# 纪律：headless 自动隔离 meta_save_test.cfg；套件首尾快照/还原 Meta 全量（r198 先例）。
extends RefCounted

const CLOSE_GATE_US := 150.0     # 设计 §1.4 微基准门
const BASE_CLOSE_US := 879.0     # 改前桌面基线（设计 §1.4 证据段实测）

var _tree: SceneTree = null
var _fails: int = 0
var _passes: int = 0
var _snap: Dictionary = {}


func _check(p_name: String, p_ok: bool, p_detail: String = "") -> void:
	if p_ok:
		_passes += 1
		print("PASS | " + p_name)
	else:
		_fails += 1
		print("FAIL | " + p_name + ("" if p_detail.is_empty() else "  [got: " + p_detail + "]"))


func _snapshot() -> void:
	_snap = {
		"crystals": Meta.crystals,
		"stardust": Meta.stardust,
		"upgrades": Meta.upgrades.duplicate(true),
		"records": Meta.records.duplicate(true),
		"map_records": Meta.map_records.duplicate(true),
		"maps_cleared": Meta.maps_cleared.duplicate(true),
		"achievements_done": Meta.achievements_done.duplicate(true),
		"daily_records": Meta.daily_records.duplicate(true),
	}


func _restore() -> void:
	Meta.crystals = int(_snap["crystals"])
	Meta.stardust = int(_snap["stardust"])
	Meta.upgrades = _snap["upgrades"]
	Meta.records = _snap["records"]
	Meta.map_records = _snap["map_records"]
	Meta.maps_cleared = _snap["maps_cleared"]
	Meta.achievements_done = _snap["achievements_done"]
	Meta.daily_records = _snap["daily_records"]
	Meta._save()


func run_all(p_tree: SceneTree) -> int:
	_tree = p_tree
	_snapshot()
	_test_clean_session_no_save()
	_test_dirty_session_saves_once()
	_test_cancel_and_settle_paths()
	_test_disk_roundtrip()
	_bench_close_chain()
	_restore()
	print("R267 刀P4 落盘脏标记汇总：PASS %d / FAIL %d（共 %d 项）" % [_passes, _fails, _passes + _fails])
	print("验收汇总：PASS %d / FAIL %d" % [_passes, _fails])
	return _fails


# ── a) 零写口面板会话：end 零落盘零全表扫 ──
func _test_clean_session_no_save() -> void:
	print("── a) 零写口面板会话（纯读开合） ──")
	# 前置：脏位清零（前序任何写点遗留清掉——直接落盘即清）
	Meta._save()
	_check("a 前置：脏位已清（_persist_dirty=false）", not bool(Meta.get("_persist_dirty")))
	var s0: int = Meta.diag_save_calls
	var c0: int = Meta.diag_ach_full_scans
	Meta.begin_persist_defer()
	# 面板会话体：纯读（records/daily/upgrades 只读——零写口）
	var _peek := int(Meta.records["total_kills"]) + int(Meta.crystals) + int(Meta.stardust)
	Meta.end_persist_defer()
	var ds: int = Meta.diag_save_calls - s0
	var dc: int = Meta.diag_ach_full_scans - c0
	_check("a 零写口 end：_save 零执行（Δ=%d）" % ds, ds == 0, "Δsave=%d" % ds)
	_check("a 零写口 end：_check_achievements 零执行（Δ=%d）" % dc, dc == 0, "Δscan=%d" % dc)
	_check("a 脏位保持 false", not bool(Meta.get("_persist_dirty")))


# ── b) 有写口（buy_upgrade）：批内抑制 → 收口恰一次结清并清位 ──
func _test_dirty_session_saves_once() -> void:
	print("── b) 有写口面板会话（buy_upgrade） ──")
	Meta.crystals = 10000
	Meta.upgrades["atk"] = 0
	Meta._save()
	var s0: int = Meta.diag_save_calls
	Meta.begin_persist_defer()
	var ok: bool = Meta.buy_upgrade(&"atk")
	var in_batch_saves: int = Meta.diag_save_calls - s0
	_check("b 批内买升级成功且 _save 被抑制（Δ=%d）" % in_batch_saves,
		ok and in_batch_saves == 0, "ok=%s Δ=%d" % [str(ok), in_batch_saves])
	_check("b 批内脏位置位", bool(Meta.get("_persist_dirty")))
	var c0: int = Meta.diag_ach_full_scans
	Meta.end_persist_defer()
	var ds: int = Meta.diag_save_calls - s0
	var dc: int = Meta.diag_ach_full_scans - c0
	_check("b 收口恰 1 次落盘（Δ=%d）" % ds, ds == 1, "Δsave=%d" % ds)
	_check("b 收口 ≥1 次全表扫（Δ=%d）" % dc, dc >= 1, "Δscan=%d" % dc)
	_check("b 收口后脏位清零", not bool(Meta.get("_persist_dirty")))
	_check("b 升级落值在内存（atk=1）", int(Meta.upgrades["atk"]) == 1)
	# 回归侧：dirty 会话收口后再开一局零写口会话——不再重复落盘
	var s1: int = Meta.diag_save_calls
	Meta.begin_persist_defer()
	Meta.end_persist_defer()
	_check("b 结清后二次零写口会话仍零落盘（Δ=%d）" % (Meta.diag_save_calls - s1),
		Meta.diag_save_calls - s1 == 0)


# ── c) cancel 无条件结清 + 结算路径行为不变 ──
func _test_cancel_and_settle_paths() -> void:
	print("── c) cancel / settle 路径 ──")
	# cancel：即使零写口（脏位 false）也强制结清（无条件语义不变）
	Meta._save()
	var s0: int = Meta.diag_save_calls
	Meta.begin_persist_defer()
	Meta.cancel_persist_defer()
	var ds: int = Meta.diag_save_calls - s0
	_check("c cancel_persist_defer 无条件落盘（Δ=%d ≥1）" % ds, ds >= 1, "Δ=%d" % ds)
	_check("c cancel 后深度归零", int(Meta.get("_persist_defer_depth")) == 0)
	# 结算：_save 直调 + map_records_changed 照发（P3 指纹/R259 选关缓存依赖面）
	var fired := {"map": false}
	var callable := func() -> void: fired["map"] = true
	Meta.map_records_changed.connect(callable)
	Meta.set_run_map(&"world_grass")
	Meta.set_run_difficulty(0)
	Meta._run_max_wave = 3
	Meta._run_kills = 5
	Meta._run_max_level = 2
	var s1: int = Meta.diag_save_calls
	Meta._settle_run_result()
	Meta.map_records_changed.disconnect(callable)
	_check("c 结算 _save 直调执行（Δ=%d ≥1）" % (Meta.diag_save_calls - s1),
		Meta.diag_save_calls - s1 >= 1)
	_check("c 结算 map_records_changed 照发", bool(fired["map"]))
	_check("c 结算写分图记录（world_grass.best_wave=3）",
		int(Meta.map_records.get("world_grass", {}).get("best_wave", 0)) >= 3)


# ── d) 链路：面板内购买→关面板→盘上可读回 ──
func _test_disk_roundtrip() -> void:
	print("── d) 购买→关面板→盘上回读 ──")
	Meta.crystals = 10000
	Meta.upgrades["life"] = 0
	Meta._save()
	Meta.begin_persist_defer()
	Meta.buy_upgrade(&"life")
	Meta.end_persist_defer()
	var cfg := ConfigFile.new()
	var err: int = cfg.load(Meta.save_path())
	var on_disk: int = -1
	if err == OK:
		var ups: Variant = cfg.get_value("meta", "upgrades", {})
		if ups is Dictionary:
			on_disk = int((ups as Dictionary).get("life", -1))
	_check("d 关面板后盘上 upgrades.life==1（漏置位=数据丢失防护）",
		on_disk == 1, "disk=%d err=%d" % [on_disk, err])


# ── µs) 面板关链微基准（begin/end 零写口对；改前基线 879µs 含扫+盘+角标） ──
func _bench_close_chain() -> void:
	print("── µs) 面板关链（零写口 begin/end 对） ──")
	Meta._save()
	# 预热 1 次排首建抖动
	Meta.begin_persist_defer()
	Meta.end_persist_defer()
	var t0 := Time.get_ticks_usec()
	var iters := 200
	for i in range(iters):
		Meta.begin_persist_defer()
		Meta.end_persist_defer()
	var us := float(Time.get_ticks_usec() - t0) / float(iters)
	print("    零写口面板关链 = %.1f µs/次（改前基线 %.0fµs：扫178+盘673+角标118）" % [us, BASE_CLOSE_US])
	_check("µs 面板关链 ≤%.0fµs（实测 %.1fµs）" % [CLOSE_GATE_US, us], us <= CLOSE_GATE_US)

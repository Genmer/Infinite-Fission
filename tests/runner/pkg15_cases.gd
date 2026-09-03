# tests/runner/pkg15_cases.gd
# v1.5.0 自测用例体（由 test_pkg15.gd 入口在 autoload 就绪后运行时加载编译）。
# 覆盖冻结方案 pkg15 用例组 P1~P20（A14_v1.5.0_design.md §7；每恰 1 断言）。
# 纪律：pkg15 P20 源码守卫（五文件零 diff——grep 冻结禁词）+ 零新 EventBus 信号；
#       P12 锚点固化只读 SimBaseline.FRAME_BASELINE（K8 实测冻结后生效）；
#       P14 自检翻红注入 hp_growth 1.13 → 断言不等 + detect 敏感 → 还原 1.12。
extends RefCounted

const TEST_K7_PATH := "user://pkg15_k7_test.cfg"
const FIVE_GUARDED := [
	"res://scripts/core/damage/damage_pipeline.gd",
	"res://scripts/combat/elemental/elemental_system.gd",
	"res://scripts/combat/elemental/elemental_state.gd",
	"res://scripts/combat/weapon/weapon_base.gd",
	"res://scripts/combat/projectile/projectile_base.gd",
]
const SIM_MARKERS: Array[String] = ["SimEnv", "SimEngine", "SimBatch", "SimTemplate",
	"SimAlign", "SimBaseline", "SimEnemy", "sim_batch", "run_sim", "TTK", "ttk"]

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _env: SimEnv = null
var _align_result: Dictionary = {}            # P6 首跑缓存（P7~P9 消费，不重跑）


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_env = SimEnv.build(42)
	_test_p1_env()                              # P1 环境
	_test_p2_templates()                        # P2 模板装配
	_test_p3_kinds()                            # P3 五敌种
	_test_p4_closed_cell()                      # P4 单敌封闭
	_test_p5_boss_mapping()                     # P5 Boss 波映射
	_test_p6_align_pkg1()                       # P6 对齐门 pkg1
	_test_p7_align_pkg3()                       # P7 对齐门 pkg3
	_test_p8_align_pkg11()                      # P8 对齐门 pkg11
	_test_p9_align_pkg12()                      # P9 对齐门 pkg12
	_test_p10_determinism()                     # P10 确定性双跑
	_test_p11_seed_split()                      # P11 异 seed
	_test_p12_baseline()                        # P12 锚点固化
	_test_p13_shield()                          # P13 盾口径
	_test_p14_drift_flip()                      # P14 自检翻红
	_test_p15_ntk_cap()                         # P15 NTK 帽
	_test_p16_k7_single_write()                 # P16 K7 单写盘
	_test_p17_smoke_budget()                    # P17 墙钟 smoke
	_test_p18_csv_cleanup()                     # P18 CSV 产出清理
	_test_p19_version()                         # P19 版本守卫
	_test_p20_zero_signal()                     # P20 零信号+五文件守卫
	_env.dispose()
	_summary()


func fail_count() -> int:
	return _fail


# ── 支撑 ──────────────────────────────────────────────────────────
func _check(p_desc: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("  PASS %s" % p_desc)
	else:
		_fail += 1
		_failures.append(p_desc)
		print("  FAIL %s | %s" % [p_desc, p_detail])


func _summary() -> void:
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)
	print("════════════════════════════════════════")


func _read_source(p_path: String) -> String:
	var f := FileAccess.open(p_path, FileAccess.READ)
	if f == null:
		return ""
	return f.get_as_text()


func _run_cell(p_tid: String, p_wave: int, p_kind: String, p_seed: int = 42) -> Dictionary:
	var weapons := SimTemplate.build(_env, p_tid, p_wave)
	return SimEngine.run_cell(_env, weapons, p_wave, p_kind, p_seed)


func _run_cell_fresh(p_tid: String, p_wave: int, p_kind: String, p_seed: int = 42) -> Dictionary:
	# 新鲜 env 口径（=SimBatch 每模板独立 env 的首格语义）：基线校验专用——共享 env 的
	# 暴击/盾敏感格值依赖运行历史（跨格单调漂移，A14 §1 口径限制留痕），不可作绝对锚
	var env: SimEnv = SimEnv.build(p_seed)
	var weapons := SimTemplate.build(env, p_tid, p_wave)
	var r: Dictionary = SimEngine.run_cell(env, weapons, p_wave, p_kind, p_seed)
	env.dispose()
	return r


# ══ P1 环境 ═══════════════════════════════════════════════════════
func _test_p1_env() -> void:
	print("── P1 SimEnv 环境 ──")
	var registry_ok: bool = _env.registry.weapons.size() >= 9 \
		and _env.registry.enemies.size() == 8 and _env.registry.chips.size() >= 12
	var pipeline_ok: bool = _env.pipeline is DamagePipeline \
		and _env.elemental.pipeline == _env.pipeline
	var pool_ok: bool = _env.enemy_pool.stats()["capacity"] == 8 \
		and int(_env.enemy_pool.stats()["free"]) == 8
	var chip_ok: bool = _env.chip._events_bound == false \
		and _env.chip.player == _env.player
	var player_ok: bool = _env.player.get_hp_pct() > 0.99 \
		and _env.elemental.meta_store == null and _env.elemental.achievement_tracker == null
	_check("P1 SimEnv：registry 9W/8E/12C 齐备 + 真件 DamagePipeline（不走工厂）+ EnemyPool(8) 满闲 + ChipHandler 未 bind + 元素系统 meta/tracker null",
		registry_ok and pipeline_ok and pool_ok and chip_ok and player_ok)


# ══ P2 模板装配 ═══════════════════════════════════════════════════
func _test_p2_templates() -> void:
	print("── P2 模板装配 ──")
	var expect_slots := {"T1": 1, "T2": 3, "T3": 2, "T4": 4, "T5": 3, "T6": 3, "T7a": 1, "T7b": 1}
	var ok := true
	var detail := ""
	for tid in SimTemplate.IDS:
		var weapons := SimTemplate.build(_env, tid, 10)
		var filled := 0
		var all_lv5 := true
		for w in weapons:
			if w != null and is_instance_valid(w):
				filled += 1
				if (w as WeaponBase).level != WeaponBase.MAX_LEVEL:
					all_lv5 = false
		if filled != int(expect_slots[tid]) or not all_lv5:
			ok = false
			detail += "%s(%d/L5=%s) " % [tid, filled, str(all_lv5)]
	# T5：六芯片金档在槽
	var t5 := SimTemplate.build(_env, "T5", 10)
	var chip_ok: bool = _env.chip.equipped.size() == 6
	for entry in _env.chip.equipped:
		chip_ok = chip_ok and int(entry.get("rarity", -1)) == 3
	# T7a：期望臂 blessing atk = n×0.04×0.25（w10 → n9 → 0.09）且 chip 段每 build 重置
	var t7a := SimTemplate.build(_env, "T7a", 10)
	var atk: float = float(_env.chip.blessing_stats.get(&"atk_pct", 0.0))
	var t7_ok: bool = is_equal_approx(atk, 0.09)
	_check("P2 模板装配：8 模板武器数 {1,3,2,4,3,3,1,1} 全 L5 + T5 六金芯片在槽 + T7a 期望臂 blessing_atk=0.09（每 build chip 重置）",
		ok and chip_ok and t7_ok, detail + "chip=%s atk=%s" % [str(chip_ok), str(atk)])


# ══ P3 五敌种 ═════════════════════════════════════════════════════
func _test_p3_kinds() -> void:
	print("── P3 五敌种装配 ──")
	var ok := true
	for kind in SimEnemy.KINDS:
		var e := SimEnemy.spawn(_env, kind, 10)
		if e == null:
			ok = false
			continue
		var base_hp: float = e.max_hp
		match kind:
			"E1":
				ok = ok and base_hp > 0.0 and not e.is_elite() and not e.shield_active()
			"E5":
				ok = ok and e.is_elite() and e.shield_active()
			"E5_ns":
				ok = ok and e.is_elite() and not e.shield_active()
			"E6":
				ok = ok and e.is_boss() and e.data.id == &"E6_boss1" \
					and (e.data.boss.get("bullet_patterns", {}) as Dictionary).is_empty() \
					and e.data.boss.has("phases") and not e.shield_active()
			"E6_ns":
				ok = ok and e.is_boss() and not e.shield_active() \
					and e.data.boss.has("phase2_resist")
		if e.position != SimEnv.ENEMY_POS or e.speed != 0.0:
			ok = false
		SimEnemy.release(_env, e)
	_check("P3 五敌种：E1 平民/E5 精英带盾/E5_ns 剥盾/E6→w10 boss1 无盾（K4 复核修正；弹幕召唤清空+phases 留）/E6_ns 剥盾；锚点 (360,300)+spd=0",
		ok)


# ══ P4 单敌封闭 ═══════════════════════════════════════════════════
func _test_p4_closed_cell() -> void:
	print("── P4 单敌封闭 ──")
	var r := _run_cell_fresh("T1", 1, "E1")
	_check("P4 单敌封闭：T1|1|E1 = 46 帧（3×24=72 首帧起 21.8 帧节拍）/ hp_total 72 / 3 结算 0 暴击",
		int(r["ttk_frames"]) == 46 and is_equal_approx(float(r["hp_total"]), 72.0)
		and int(r["n_hits"]) == 3 and int(r["n_crit"]) == 0,
		str(r))


# ══ P5 Boss 波映射 ════════════════════════════════════════════════
func _test_p5_boss_mapping() -> void:
	print("── P5 Boss 波映射 ──")
	var map_ok: bool = SimEnemy.boss_id_for_wave(1) == &"E6_boss1" \
		and SimEnemy.boss_id_for_wave(9) == &"E6_boss1" \
		and SimEnemy.boss_id_for_wave(10) == &"E6_boss1" \
		and SimEnemy.boss_id_for_wave(19) == &"E6_boss1" \
		and SimEnemy.boss_id_for_wave(20) == &"E6_boss2" \
		and SimEnemy.boss_id_for_wave(29) == &"E6_boss2" \
		and SimEnemy.boss_id_for_wave(30) == &"E6_boss3" \
		and SimEnemy.boss_id_for_wave(40) == &"E6_boss1"
	var e := SimEnemy.spawn(_env, "E6", 1)
	var spawn_ok: bool = e != null and e.data.id == &"E6_boss1" and e.is_boss()
	SimEnemy.release(_env, e)
	_check("P5 Boss 波映射：slot=(w/10−1)%3（w10→b1/w20→b2/w30→b3/w40→b1 轮换，K4 复核修正）+ E6@w1 实装 boss1",
		map_ok and spawn_ok)


# ══ P6~P9 对齐门四组 ══════════════════════════════════════════════
func _ensure_align() -> void:
	if _align_result.is_empty():
		_align_result = SimAlign.run(_env)


func _test_p6_align_pkg1() -> void:
	print("── P6 对齐门 pkg1 ──")
	_ensure_align()
	var g: Dictionary = _align_result["pkg1"]
	_check("P6 对齐门 pkg1：≥22 条全过且零失败（公式 336/150 去重/δ 族/护栏/Local/目标侧/暴击/R_alarm/反应快照）",
		int(g["pass"]) >= 22 and int(g["total"]) >= 22
		and int(g["pass"]) == int(g["total"]) and (_align_result["failures"] as Array).is_empty(),
		"%s" % str(g))


func _test_p7_align_pkg3() -> void:
	print("── P7 对齐门 pkg3 ──")
	_ensure_align()
	var g: Dictionary = _align_result["pkg3"]
	_check("P7 对齐门 pkg3：≥20 条全过且零失败（碎裂/过载扩散/超导/CD 序/优先级/连锁/DOT/三 ELE 字面/加特林冷热/W1 L5 单发/λ/寒滞/点燃/射速帽）",
		int(g["pass"]) >= 20 and int(g["pass"]) == int(g["total"]), "%s" % str(g))


func _test_p8_align_pkg11() -> void:
	print("── P8 对齐门 pkg11 ──")
	_ensure_align()
	var g: Dictionary = _align_result["pkg11"]
	_check("P8 对齐门 pkg11：≥6 条全过且零失败（精通 ×2/×3/封顶/第 4 层拒绝/step 镜像/VOID 恒等 1.8）",
		int(g["pass"]) >= 6 and int(g["pass"]) == int(g["total"]), "%s" % str(g))


func _test_p9_align_pkg12() -> void:
	print("── P9 对齐门 pkg12 ──")
	_ensure_align()
	var g: Dictionary = _align_result["pkg12"]
	_check("P9 对齐门 pkg12：≥8 条全过且零失败（冻结 2.5/克环表/盾克制 250→50/破盾无溢出/WAT-LTG ×2/REACTION 豁免/λ 三处/legacy 1.2s）",
		int(g["pass"]) >= 8 and int(g["pass"]) == int(g["total"]), "%s" % str(g))


# ══ P10 确定性双跑 ════════════════════════════════════════════════
func _test_p10_determinism() -> void:
	print("── P10 确定性双跑 ──")
	var sample := [["T1", 1, "E1"], ["T2", 10, "E1"], ["T3", 10, "E6_ns"], ["T4", 10, "E1"],
		["T7b", 40, "E1"], ["T1", 10, "E5"], ["T2", 20, "E6"], ["T5", 30, "E1"]]
	var ok := true
	var detail := ""
	for cell in sample:
		var a := _run_cell(cell[0], cell[1], cell[2])
		var b := _run_cell(cell[0], cell[1], cell[2])
		var same: bool = int(a["ttk_frames"]) == int(b["ttk_frames"]) \
			and int(a["n_hits"]) == int(b["n_hits"]) and int(a["n_crit"]) == int(b["n_crit"]) \
			and int(a["shield_break_frames"]) == int(b["shield_break_frames"])
		if not same:
			ok = false
			detail += "%s|%s A=%s B=%s " % [cell[0], cell[2], str(a["ttk_frames"]), str(b["ttk_frames"])]
	_check("P10 确定性：8 格双跑逐格 ttk/hits/crits/盾破帧逐位一致（含 NTK 格）", ok, detail)


# ══ P11 异 seed 可区分 ════════════════════════════════════════════
func _test_p11_seed_split() -> void:
	print("── P11 异 seed ──")
	var ttks: Array[int] = []
	for sd in [42, 137, 999]:
		var r := _run_cell("T1", 1, "E6_ns", sd)
		ttks.append(int(r["ttk_frames"]))
	_check("P11 异 seed 可区分：T1|1|E6_ns 三 seed ≥2 种 ttk（暴击序列真实生效）",
		ttks[0] != ttks[1] or ttks[1] != ttks[2] or ttks[0] != ttks[2], str(ttks))


# ══ P12 锚点固化 ══════════════════════════════════════════════════
func _test_p12_baseline() -> void:
	print("── P12 锚点固化 ──")
	var frozen: bool = not SimBaseline.FRAME_BASELINE.is_empty()
	var complete := true
	for key in SimBaseline.ANCHOR_CELLS:
		if not SimBaseline.FRAME_BASELINE.has(key):
			complete = false
	var ok := frozen and complete
	var detail := ""
	if ok:
		for key in SimBaseline.ANCHOR_CELLS:
			var parts := String(key).split("|")
			var r := _run_cell_fresh(parts[0], int(parts[1]), parts[2])
			if int(r["ttk_frames"]) != int(SimBaseline.FRAME_BASELINE[key]):
				ok = false
				detail += "%s: %s≠%s " % [key, str(r["ttk_frames"]),
					str(SimBaseline.FRAME_BASELINE[key])]
	_check("P12 锚点固化：FRAME_BASELINE 12 格实测冻结非空 + 逐格复跑 == 冻结帧", ok, detail)


# ══ P13 盾口径 ════════════════════════════════════════════════════
func _test_p13_shield() -> void:
	print("── P13 盾口径 ──")
	var r5 := _run_cell("T1", 10, "E5")
	var r5n := _run_cell("T1", 10, "E5_ns")
	var shield_in_range: bool = int(r5["shield_break_frames"]) > 0 \
		and int(r5["shield_break_frames"]) < int(r5["ttk_frames"])
	var hp_total5: float = float(r5["hp_total"])
	# E5@w10：max_hp = 72×1.12^9×4.2；hp_total = max_hp×1.25（盾 0.25）
	var expect_total: float = 72.0 * pow(1.12, 9.0) * 4.2 * 1.25
	var ns_ok: bool = int(r5n["shield_break_frames"]) == -1 \
		and is_equal_approx(float(r5n["hp_total"]), 72.0 * pow(1.12, 9.0) * 4.2)
	_check("P13 盾口径：E5 盾破帧 ∈ (0, ttk) + hp_total = max_hp×1.25 + E5_ns 无盾无破帧（EHP = max_hp）",
		shield_in_range and is_equal_approx(hp_total5, expect_total) and ns_ok,
		"break=%s ttk=%s total=%s expect=%s" % [str(r5["shield_break_frames"]),
		str(r5["ttk_frames"]), str(hp_total5), str(expect_total)])


# ══ P14 自检翻红 ══════════════════════════════════════════════════
func _test_p14_drift_flip() -> void:
	print("── P14 自检翻红 ──")
	var bal: BalanceTables = GameConfig.balance
	var orig: float = bal.hp_growth_per_wave
	var key := SimBaseline.key("T1", 40, "E1")
	var base_ttk: int = int(SimBaseline.FRAME_BASELINE.get(key, -999))
	# 注入 hp_growth 1.13
	bal.hp_growth_per_wave = 1.13
	var r_hot := _run_cell_fresh("T1", 40, "E1")
	var flipped: bool = base_ttk > 0 and int(r_hot["ttk_frames"]) != base_ttk
	# detect 敏感度：1.13 网格斜率 > 1.12 网格（双口径各采 w1/w40 两行）
	bal.hp_growth_per_wave = orig
	var rows_a: Array[Dictionary] = []
	var rows_b: Array[Dictionary] = []
	for w in [1, 40]:
		var ra := _run_cell_fresh("T1", w, "E1")
		rows_a.append({"template": "T1", "wave": w, "kind": "E1", "seed": 42,
			"ttk_frames": int(ra["ttk_frames"]), "shield_break_frames": -1,
			"hp_total": float(ra["hp_total"]), "dps": float(ra["dps"]),
			"t_clear_est": float(ra["t_clear_est"]), "n_hits": 0, "n_crit": 0})
	bal.hp_growth_per_wave = 1.13
	for w in [1, 40]:
		var rb := _run_cell_fresh("T1", w, "E1")
		rows_b.append({"template": "T1", "wave": w, "kind": "E1", "seed": 42,
			"ttk_frames": int(rb["ttk_frames"]), "shield_break_frames": -1,
			"hp_total": float(rb["hp_total"]), "dps": float(rb["dps"]),
			"t_clear_est": float(rb["t_clear_est"]), "n_hits": 0, "n_crit": 0})
	bal.hp_growth_per_wave = orig               # ★还原
	var det_a: Dictionary = SimBatch.detect(rows_a)
	var det_b: Dictionary = SimBatch.detect(rows_b)
	var slope_a: float = float((det_a["p3_drift_slope"]["per_template"][0] as Dictionary)["slope"])
	var slope_b: float = float((det_b["p3_drift_slope"]["per_template"][0] as Dictionary)["slope"])
	# 还原口验：锚点格复跑 == 冻结
	var r_restore := _run_cell_fresh("T1", 40, "E1")
	var restored: bool = base_ttk > 0 and int(r_restore["ttk_frames"]) == base_ttk
	_check("P14 自检翻红：hp_growth 1.13 注入 → 锚点帧≠冻结 + detect 斜率敏感上移 → 还原后逐位回锚",
		flipped and slope_b > slope_a and restored,
		"flipped=%s slope12=%.4f slope13=%.4f restored=%s" % [str(flipped), slope_a, slope_b, str(restored)])


# ══ P15 NTK 帽 ════════════════════════════════════════════════════
func _test_p15_ntk_cap() -> void:
	print("── P15 NTK 帽 ──")
	var r := _run_cell("T1", 40, "E6_ns")
	_check("P15 NTK 帽：T1|40|E6_ns → ttk_frames=-1 / t_clear_est=-1 / dps=0 / hits=0（早退结果形）",
		int(r["ttk_frames"]) == -1 and is_equal_approx(float(r["t_clear_est"]), -1.0)
		and is_equal_approx(float(r["dps"]), 0.0) and int(r["n_hits"]) == 0, str(r))


# ══ P16 K7 单写盘 ═════════════════════════════════════════════════
func _test_p16_k7_single_write() -> void:
	print("── P16 K7 单写盘 ──")
	var stores: Array[MetaStore] = []
	var s := MetaStore.new()
	s.name = "Pkg15K7A"
	tree.get_root().add_child(s)
	s.set_save_path(TEST_K7_PATH)
	s.wipe()
	stores.append(s)
	# defer=true：内存置位不写盘
	var ok_defer: bool = s.unlock_achievement(&"ach_boss1", true) \
		and s.has_achievement(&"ach_boss1")
	var s2 := MetaStore.new()
	s2.name = "Pkg15K7B"
	tree.get_root().add_child(s2)
	s2.set_save_path(TEST_K7_PATH)
	s2.load_save()
	stores.append(s2)
	var not_persisted: bool = not s2.has_achievement(&"ach_boss1")
	s.save()                                      # 显式单点落盘
	var s3 := MetaStore.new()
	s3.name = "Pkg15K7C"
	tree.get_root().add_child(s3)
	s3.set_save_path(TEST_K7_PATH)
	s3.load_save()
	stores.append(s3)
	var persisted: bool = s3.has_achievement(&"ach_boss1")
	for st in stores:
		st.wipe()
		st.free()
	stores.clear()
	var cfg := ConfigFile.new()
	if cfg.load(TEST_K7_PATH) == OK:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_K7_PATH))
	_check("P16 K7 单写盘：unlock(defer=true) 内存置位 + 新实例读档未解锁（未写盘）+ 显式 save 后读档解锁（结算期唯一写盘语义）",
		ok_defer and not_persisted and persisted,
		"defer=%s not_persisted=%s persisted=%s" % [str(ok_defer), str(not_persisted), str(persisted)])


# ══ P17 墙钟 smoke ════════════════════════════════════════════════
func _test_p17_smoke_budget() -> void:
	print("── P17 墙钟 smoke ──")
	var t0 := Time.get_ticks_usec()
	var rows := SimBatch.run_smoke()
	var elapsed := float(Time.get_ticks_usec() - t0) / 1000000.0
	_check("P17 墙钟：run_smoke 18 格 ≤30s（NTK 早退守卫生效）",
		rows.size() == 18 and elapsed <= 30.0, "elapsed=%.1fs" % elapsed)


# ══ P18 CSV 产出清理 ══════════════════════════════════════════════
func _test_p18_csv_cleanup() -> void:
	print("── P18 CSV 产出清理 ──")
	var rows: Array[Dictionary] = [{"template": "T1", "wave": 1, "kind": "E1", "seed": 42,
		"ttk_frames": 46, "shield_break_frames": -1, "hp_total": 72.0,
		"dps": 187.8, "t_clear_est": 0.383, "n_hits": 3, "n_crit": 0}]
	var det: Dictionary = {"p1_small_center": {"point": "p1", "verdict": "OK", "p50_s": 1.2}}
	var dir := SimBatch.write_csv(rows, rows, det)
	var made := true
	for name in ["cells.csv", "p50.csv", "detect.json"]:
		made = made and FileAccess.file_exists(dir + "/" + name)
	SimBatch.clean_user_out()
	var cleaned: bool = not DirAccess.dir_exists_absolute(
		ProjectSettings.globalize_path(SimBatch.OUT_ROOT))
	_check("P18 CSV：write_csv 三件落盘（user://sim_batch/<ts>/）+ clean_user_out 整目录清空",
		made and cleaned, "made=%s cleaned=%s dir=%s" % [str(made), str(cleaned), dir])


# ══ P19 版本守卫 ══════════════════════════════════════════════════
func _test_p19_version() -> void:
	print("── P19 版本守卫 ──")
	var version: String = ProjectSettings.get_setting("application/config/version", "")
	var progress := _read_source("res://PROGRESS.md")
	var a14 := _read_source("res://docs/analysis/A14_v1.5.0_design.md")
	_check("P19 版本守卫：version=1.5.0 + PROGRESS v1.5.0 对账段 + A14 设计留痕（含提案表节）",
		version == "1.5.0" and progress.contains("v1.5.0")
		and not a14.is_empty() and a14.contains("提案表"),
		"version=%s progress=%s a14=%s" % [version, str(not progress.is_empty()),
		str(a14.length())])


# ══ P20 零信号+五文件守卫 ═════════════════════════════════════════
func _test_p20_zero_signal() -> void:
	print("── P20 零信号+五文件守卫 ──")
	var signals_ok: bool = DataValidator.EVENT_NAMES.size() == 23
	for ev in DataValidator.EVENT_NAMES:
		signals_ok = signals_ok and EventBus.has_signal(ev)
	var files_ok := true
	var hit := ""
	for path in FIVE_GUARDED:
		var src := _read_source(path)
		if src.is_empty():
			files_ok = false
			hit += path + "(空) "
			continue
		for marker in SIM_MARKERS:
			if src.contains(marker):
				files_ok = false
				hit += "%s←%s " % [path, marker]
	_check("P20 零信号+五文件源码守卫：EVENT_NAMES 23 且 EventBus 全注册 + damage_pipeline/elemental_system/elemental_state/weapon_base/projectile_base 零 sim 字样（本版零触碰）",
		signals_ok and files_ok, hit)

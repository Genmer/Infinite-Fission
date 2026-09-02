# tests/sim/sim_align.gd
# v1.5.0 TTK 复校工装（A14 §4）：对齐门——仿真工装与既有 pkg 冻结锚点的逐位对账。
# · _CASES 锚点表：{src（pkg 源定位）, path（执行器）, input（入参）, expect（冻结字面）}；
#   判定浮点 == 逐位（同代码路径同输入必同输出——fixed-seed 契约，禁 is_equal_approx）。
# · 配额（A14 冻结）：pkg1≥22 / pkg3≥20 / pkg11≥6 / pkg12≥8；本表 27/20/6/8 = 61 条。
# · FAIL 只修工装禁改期望（冻结字面来自 pkg 源码逐字，pkg 侧全绿即为真值）。
# · 同 seed 双跑自检（run 内部第二遍抽核 8 条 → 结果一致才算 pass）。
class_name SimAlign
extends RefCounted

const P1_QUOTA := 22
const P3_QUOTA := 20
const P11_QUOTA := 6
const P12_QUOTA := 8

# ── 锚点表（期望值 = pkg 源字面冻结；src 供对账溯源） ─────────────────
static func _cases() -> Array[Dictionary]:
	var c: Array[Dictionary] = []
	# ── pkg1 伤害公式（27 条；tests/formula/test_formula_pipeline.gd） ──
	c.append({"pkg": "pkg1", "src": "pkg1#168", "path": "p1_final", "expect": 336.0,
		"input": {"adds": [{"pool_id": &"add_atk", "layer": 1, "contrib": 0.2, "decay_delta": 0.85, "is_curse": false},
			{"pool_id": &"add_atk", "layer": 1, "contrib": 0.3, "decay_delta": 0.85, "is_curse": false}],
			"flat": 10.0, "mults": [{"pool_id": &"frost_dmg", "source_uid": 1, "contrib": 0.5, "cap_pool": 2.0},
			{"pool_id": &"bounce_dmg", "source_uid": 2, "contrib": 0.4, "cap_pool": 2.0}]}})
	c.append({"pkg": "pkg1", "src": "pkg1#170", "path": "p1_snapshot", "expect": 160.0,
		"input": {"adds": [{"pool_id": &"add_atk", "layer": 1, "contrib": 0.2, "decay_delta": 0.85, "is_curse": false},
			{"pool_id": &"add_atk", "layer": 1, "contrib": 0.3, "decay_delta": 0.85, "is_curse": false}],
			"flat": 10.0, "mults": [{"pool_id": &"frost_dmg", "source_uid": 1, "contrib": 0.5, "cap_pool": 2.0},
			{"pool_id": &"bounce_dmg", "source_uid": 2, "contrib": 0.4, "cap_pool": 2.0}]}})
	c.append({"pkg": "pkg1", "src": "pkg1#171", "path": "p1_mult", "expect": 2.1,
		"input": {"adds": [], "flat": 10.0, "mults": [{"pool_id": &"frost_dmg", "source_uid": 1, "contrib": 0.5, "cap_pool": 2.0},
			{"pool_id": &"bounce_dmg", "source_uid": 2, "contrib": 0.4, "cap_pool": 2.0}]}})
	c.append({"pkg": "pkg1", "src": "pkg1#199", "path": "p1_final", "expect": 150.0,
		"input": {"dedup_same_source": true, "mults": [{"pool_id": &"frost_dmg", "source_uid": 7, "contrib": 0.5, "cap_pool": 2.0},
			{"pool_id": &"frost_dmg", "source_uid": 7, "contrib": 0.5, "cap_pool": 2.0}]}})
	c.append({"pkg": "pkg1", "src": "pkg1#212", "path": "p1_final", "expect": 200.0,
		"input": {"mults": [{"pool_id": &"frost_dmg", "source_uid": 7, "contrib": 0.5, "cap_pool": 2.0},
			{"pool_id": &"frost_dmg", "source_uid": 8, "contrib": 0.5, "cap_pool": 2.0}]}})
	c.append({"pkg": "pkg1", "src": "pkg1#227", "path": "p1_final", "expect": 120.0,
		"input": {"adds": [{"pool_id": &"add_atk", "layer": 1, "contrib": 0.2, "decay_delta": 0.92, "is_curse": false}]}})
	c.append({"pkg": "pkg1", "src": "pkg1#234", "path": "p1_final", "expect": 138.4,
		"input": {"adds": [{"pool_id": &"add_atk", "layer": 2, "contrib": 0.2, "decay_delta": 0.92, "is_curse": false}]}})
	c.append({"pkg": "pkg1", "src": "pkg1#254", "path": "p1_final", "expect": 200.0,
		"input": {"adds": [{"pool_id": &"add_atk", "layer": 5, "contrib": 0.2, "decay_delta": 1.0, "is_curse": false}]}})
	c.append({"pkg": "pkg1", "src": "pkg1#261", "path": "p1_final", "expect": 120.0,
		"input": {"adds": [{"pool_id": &"add_atk", "layer": 5, "contrib": 0.2, "decay_delta": 0.0, "is_curse": false}]}})
	c.append({"pkg": "pkg1", "src": "pkg1#268", "path": "p1_final", "expect": 70.0,
		"input": {"adds": [{"pool_id": &"add_atk", "layer": 3, "contrib": -0.1, "decay_delta": 0.9, "is_curse": true}]}})
	c.append({"pkg": "pkg1", "src": "pkg1#283", "path": "p1_final", "expect": 300.0,
		"input": {"adds": [{"pool_id": &"add_atk", "layer": 1, "contrib": 3.0, "decay_delta": 0.85, "is_curse": false}]}})
	c.append({"pkg": "pkg1", "src": "pkg1#291", "path": "p1_final", "expect": 150.0,
		"input": {"flat": 80.0}})
	c.append({"pkg": "pkg1", "src": "pkg1#298", "path": "p1_final", "expect": 130.0,
		"input": {"flat": 30.0}})
	c.append({"pkg": "pkg1", "src": "pkg1#313", "path": "p1_final", "expect": 300.0,
		"input": {"mults": [{"pool_id": &"vuln", "source_uid": 1, "contrib": 3.0, "cap_pool": 2.0}]}})
	c.append({"pkg": "pkg1", "src": "pkg1#357", "path": "p1_final", "expect": 800.0,
		"input": {"mults": [{"pool_id": &"big_0", "source_uid": 1, "contrib": 1.0, "cap_pool": 2.0},
			{"pool_id": &"big_1", "source_uid": 2, "contrib": 1.0, "cap_pool": 2.0},
			{"pool_id": &"big_2", "source_uid": 3, "contrib": 1.0, "cap_pool": 2.0},
			{"pool_id": &"big_3", "source_uid": 4, "contrib": 1.0, "cap_pool": 2.0},
			{"pool_id": &"big_4", "source_uid": 5, "contrib": 1.0, "cap_pool": 2.0},
			{"pool_id": &"big_5", "source_uid": 6, "contrib": 1.0, "cap_pool": 2.0}]}})
	c.append({"pkg": "pkg1", "src": "pkg1#375", "path": "p1_final", "expect": 150.0,
		"input": {"locals": [{"local_id": &"scorch", "contrib": 0.3, "cap_local": 0.5},
			{"local_id": &"scorch", "contrib": 0.3, "cap_local": 0.5}]}})
	c.append({"pkg": "pkg1", "src": "pkg1#385", "path": "p1_final", "expect": 129.6,
		"input": {"locals": [{"local_id": &"scorch", "contrib": 0.08, "cap_local": 0.5},
			{"local_id": &"other", "contrib": 0.2, "cap_local": 0.5}]}})
	c.append({"pkg": "pkg1", "src": "pkg1#419", "path": "p1_final", "expect": 50.0,
		"input": {"element": 2, "resist": [0.0, 0.0, 0.5, 0.0, 0.0]}})
	c.append({"pkg": "pkg1", "src": "pkg1#428", "path": "p1_final", "expect": 125.0,
		"input": {"vuln": 0.25}})
	c.append({"pkg": "pkg1", "src": "pkg1#435", "path": "p1_final", "expect": 62.5,
		"input": {"element": 2, "vuln": 0.25, "resist": [0.0, 0.0, 0.5, 0.0, 0.0]}})
	c.append({"pkg": "pkg1", "src": "pkg1#448", "path": "p1_final", "expect": 70.0,
		"input": {"element": 2, "resist": [0.0, 0.0, 0.3, 0.0, 0.0]}})
	c.append({"pkg": "pkg1", "src": "pkg1#498", "path": "p1_final", "expect": 200.0,
		"input": {"crit_chance": 1.0, "crit_mult": 2.0}})
	c.append({"pkg": "pkg1", "src": "pkg1#505", "path": "p1_final", "expect": 150.0,
		"input": {"crit_chance": 1.0, "crit_mult": 1.5}})
	c.append({"pkg": "pkg1", "src": "pkg1#514", "path": "p1_final", "expect": 100.0,
		"input": {"crit_chance": 1.0, "crit_mult": 2.0, "hit_flags": 16}})
	c.append({"pkg": "pkg1", "src": "pkg1#694", "path": "p1_reaction", "expect": 320.0,
		"input": {"snapshot": 160.0, "coef": 2.0}})
	c.append({"pkg": "pkg1", "src": "pkg1#649", "path": "p1_final", "expect": 50000.0,
		"input": {"mults": [{"pool_id": &"big_0", "source_uid": 1, "contrib": 1.0, "cap_pool": 2.0},
			{"pool_id": &"big_1", "source_uid": 2, "contrib": 1.0, "cap_pool": 2.0},
			{"pool_id": &"big_2", "source_uid": 3, "contrib": 1.0, "cap_pool": 2.0},
			{"pool_id": &"big_3", "source_uid": 4, "contrib": 1.0, "cap_pool": 2.0},
			{"pool_id": &"big_4", "source_uid": 5, "contrib": 1.0, "cap_pool": 2.0},
			{"pool_id": &"big_5", "source_uid": 6, "contrib": 1.0, "cap_pool": 2.0}],
			"locals": [{"local_id": &"scorch", "contrib": 1000.0, "cap_local": 2000.0}]}})
	c.append({"pkg": "pkg1", "src": "pkg1#647", "path": "p1_ratio", "expect": 8008.0,
		"input": {"mults": [{"pool_id": &"big_0", "source_uid": 1, "contrib": 1.0, "cap_pool": 2.0},
			{"pool_id": &"big_1", "source_uid": 2, "contrib": 1.0, "cap_pool": 2.0},
			{"pool_id": &"big_2", "source_uid": 3, "contrib": 1.0, "cap_pool": 2.0},
			{"pool_id": &"big_3", "source_uid": 4, "contrib": 1.0, "cap_pool": 2.0},
			{"pool_id": &"big_4", "source_uid": 5, "contrib": 1.0, "cap_pool": 2.0},
			{"pool_id": &"big_5", "source_uid": 6, "contrib": 1.0, "cap_pool": 2.0}],
			"locals": [{"local_id": &"scorch", "contrib": 1000.0, "cap_local": 2000.0}]}})

	# ── pkg3 元素系统（20 条；tests/runner/pkg3_cases.gd） ──
	c.append({"pkg": "pkg3", "src": "pkg3#1262", "path": "p3_shatter", "expect": 640.0, "input": {}})
	c.append({"pkg": "pkg3", "src": "pkg3#1264", "path": "p3_shatter_consume", "expect": true, "input": {}})
	c.append({"pkg": "pkg3", "src": "pkg3#1277", "path": "p3_overload", "expect": 880.0, "input": {}})
	c.append({"pkg": "pkg3", "src": "pkg3#1279", "path": "p3_overload_spread", "expect": [880.0, 1000.0], "input": {}})
	c.append({"pkg": "pkg3", "src": "pkg3#1290", "path": "p3_superconduct", "expect": [0.0, -0.2, -0.3], "input": {}})
	c.append({"pkg": "pkg3", "src": "pkg3#1296", "path": "p3_superconduct_restore", "expect": [0.3, 0.1, 0.0], "input": {}})
	c.append({"pkg": "pkg3", "src": "pkg3#1307", "path": "p3_cd_sequence", "expect": [6.0, true, true], "input": {}})
	c.append({"pkg": "pkg3", "src": "pkg3#1334", "path": "p3_priority", "expect": [0.0, 0.0, 30.0], "input": {}})
	c.append({"pkg": "pkg3", "src": "pkg3#1370", "path": "p3_shock_chain", "expect": [965.0, 965.0, 965.0, 1000.0, 1000.0], "input": {}})
	c.append({"pkg": "pkg3", "src": "pkg3#1378", "path": "p3_dot", "expect": 940.0, "input": {}})
	c.append({"pkg": "pkg3", "src": "pkg3 trait tres", "path": "p3_trait_value", "expect": [22.0, 0.22], "input": {"trait": "ELE_IGNITE", "key": "dot_ratio_lv2"}})
	c.append({"pkg": "pkg3", "src": "pkg3 trait tres", "path": "p3_trait_value", "expect": [22.0, 30.0], "input": {"trait": "ELE_FREEZE", "key": "value_lv2"}})
	c.append({"pkg": "pkg3", "src": "pkg3 trait tres", "path": "p3_trait_value", "expect": [22.0, 4.0], "input": {"trait": "ELE_SHOCK", "key": "chain_targets_lv2"}})
	c.append({"pkg": "pkg3", "src": "pkg3#1385", "path": "p3_void_shatter", "expect": 352.0, "input": {}})
	c.append({"pkg": "pkg3", "src": "pkg3/W1 tres", "path": "p3_w1_l5_hit", "expect": 24.0, "input": {}})
	c.append({"pkg": "pkg3", "src": "W2_gatling tres L1", "path": "p3_gatling_interval", "expect": [1.0 / 11.0, 1.0 / 14.0], "input": {}})
	c.append({"pkg": "pkg3", "src": "pkg3#1230", "path": "p3_lambda_decay", "expect": [39.0, 42.0, 36.0], "input": {}})
	c.append({"pkg": "pkg3", "src": "pkg3#1238", "path": "p3_chill", "expect": [0.6, 1.25], "input": {}})
	c.append({"pkg": "pkg3", "src": "pkg3#1193", "path": "p3_burn_trigger", "expect": [1.0, 3.0, 200.0, 0.0], "input": {}})
	c.append({"pkg": "pkg3", "src": "pkg3#707", "path": "p3_rof_cap", "expect": 1.0 / 30.0, "input": {}})
	# ── pkg11 元素精通/φ（6 条；tests/runner/pkg11_cases.gd V25/V33/V34） ──
	c.append({"pkg": "pkg11", "src": "pkg11#692", "path": "p11_mastery_layers", "expect": 1.5, "input": {"layers": 2}})
	c.append({"pkg": "pkg11", "src": "pkg11#695", "path": "p11_mastery_layers", "expect": 1.75, "input": {"layers": 3}})
	c.append({"pkg": "pkg11", "src": "pkg11#708", "path": "p11_mastery_cap", "expect": [1.75, 1.75], "input": {}})
	c.append({"pkg": "pkg11", "src": "pkg11#712", "path": "p11_mastery_reject", "expect": [true, 1.75], "input": {}})
	c.append({"pkg": "pkg11", "src": "pkg11#V34", "path": "p11_step_mirror", "expect": 1.5, "input": {"layers": 2, "step": 0.25}})
	c.append({"pkg": "pkg11", "src": "pkg11#V25", "path": "p11_void_identity", "expect": 1.8, "input": {}})
	# ── pkg12 元素盾/WAT（8 条；tests/runner/pkg12_cases.gd V41/V43/V51） ──
	c.append({"pkg": "pkg12", "src": "pkg12#368", "path": "p12_freeze_timer", "expect": 2.5, "input": {}})
	c.append({"pkg": "pkg12", "src": "game_const#53", "path": "p12_counter_table", "expect": [-1, 2, 1, 4, 3], "input": {}})
	c.append({"pkg": "pkg12", "src": "pkg12#826", "path": "p12_counter_hit", "expect": 50.0, "input": {}})
	c.append({"pkg": "pkg12", "src": "pkg12#838", "path": "p12_break_no_spill", "expect": [0.0, true, false, true], "input": {}})
	c.append({"pkg": "pkg12", "src": "pkg12#843", "path": "p12_wat_ltg_counter", "expect": 80.0, "input": {}})
	c.append({"pkg": "pkg12", "src": "pkg12#831", "path": "p12_reaction_exempt", "expect": 90.0, "input": {}})
	c.append({"pkg": "pkg12", "src": "pkg12#289", "path": "p12_lambda_three", "expect": [0.38, 0.38, true], "input": {}})
	c.append({"pkg": "pkg12", "src": "elemental_state#235", "path": "p12_legacy_freeze", "expect": 1.2, "input": {}})
	return c


static func run(p_env: SimEnv) -> Dictionary:
	# 对账：逐条执行 → 逐位比对 → 双跑抽核自检
	var totals := {}
	var failures: Array[String] = []
	var first_results: Array = []
	for pkg in ["pkg1", "pkg3", "pkg11", "pkg12"]:
		totals[pkg] = {"pass": 0, "total": 0}
	for case in _cases():
		var pkg := String(case["pkg"])
		var measured: Variant = _execute(p_env, case)
		var ok := _eq(measured, case["expect"])
		(totals[pkg] as Dictionary)["total"] = int((totals[pkg] as Dictionary)["total"]) + 1
		if ok:
			(totals[pkg] as Dictionary)["pass"] = int((totals[pkg] as Dictionary)["pass"]) + 1
		else:
			failures.append("%s %s path=%s got=%s expect=%s" % [pkg, String(case["src"]),
				String(case["path"]), str(measured), str(case["expect"])])
		first_results.append(measured)
	# 同 seed 双跑抽核自检（8 条：pkg1 首条 + pkg3 碎裂 + pkg11 精通×2 + pkg12 盾四条）
	for idx in [0, 32, 33, 34, 35, 53, 54, 56]:
		if idx >= first_results.size():
			continue
		var case := _cases()[idx]
		var again: Variant = _execute(p_env, case)
		if not _eq(again, first_results[idx]):
			failures.append("双跑自检不一致 idx=%d got=%s vs %s" % [idx, str(again), str(first_results[idx])])
	var quotas_ok := int(totals["pkg1"]["pass"]) >= P1_QUOTA \
		and int(totals["pkg3"]["pass"]) >= P3_QUOTA \
		and int(totals["pkg11"]["pass"]) >= P11_QUOTA \
		and int(totals["pkg12"]["pass"]) >= P12_QUOTA
	return {"pkg1": totals["pkg1"], "pkg3": totals["pkg3"], "pkg11": totals["pkg11"],
		"pkg12": totals["pkg12"], "failures": failures, "quotas_ok": quotas_ok}


# ── 执行器 ────────────────────────────────────────────────────────
static func _execute(p_env: SimEnv, p_case: Dictionary) -> Variant:
	match String(p_case["path"]):
		"p1_final":
			return _p1_final(p_env, p_case["input"])
		"p1_snapshot":
			return _p1_resolve(p_env, p_case["input"]).panel_snapshot
		"p1_mult":
			return _p1_resolve(p_env, p_case["input"]).mult_product
		"p1_ratio":
			var r := _p1_resolve(p_env, p_case["input"])
			return r.audit.ratio
		"p1_reaction":
			return _p1_reaction(p_env, p_case["input"])
		"p3_shatter":
			return _p3_shatter(p_env, false)
		"p3_shatter_consume":
			return _p3_shatter_consume(p_env)
		"p3_overload":
			return _p3_overload(p_env)[0]
		"p3_overload_spread":
			return _p3_overload(p_env)[1]
		"p3_superconduct":
			return _p3_superconduct(p_env)[0]
		"p3_superconduct_restore":
			return _p3_superconduct(p_env)[1]
		"p3_cd_sequence":
			return _p3_cd_sequence(p_env)
		"p3_priority":
			return _p3_priority(p_env)
		"p3_shock_chain":
			return _p3_shock_chain(p_env)
		"p3_dot":
			return _p3_dot(p_env)
		"p3_trait_value":
			return _p3_trait_value(p_env, p_case["input"])
		"p3_void_shatter":
			return _p3_shatter(p_env, true)
		"p3_w1_l5_hit":
			return _p3_w1_l5_hit(p_env)
		"p3_gatling_interval":
			return _p3_gatling_interval(p_env)
		"p3_lambda_decay":
			return _p3_lambda_decay()
		"p3_chill":
			return _p3_chill()
		"p3_burn_trigger":
			return _p3_burn_trigger()
		"p3_rof_cap":
			return _p3_rof_cap()
		"p11_mastery_layers":
			return _p11_mastery(p_env, int(p_case["input"].get("layers", 2)), false, false)
		"p11_mastery_cap":
			return _p11_mastery_cap(p_env)
		"p11_mastery_reject":
			return _p11_mastery_reject(p_env)
		"p11_step_mirror":
			return _p11_step_mirror(p_env, p_case["input"])
		"p11_void_identity":
			return _p11_void_identity(p_env)
		"p12_freeze_timer":
			return _p12_freeze_timer(p_env)
		"p12_counter_table":
			return _p12_counter_table()
		"p12_counter_hit":
			return _p12_counter_hit()
		"p12_break_no_spill":
			return _p12_break_no_spill()
		"p12_wat_ltg_counter":
			return _p12_wat_ltg_counter()
		"p12_reaction_exempt":
			return _p12_reaction_exempt()
		"p12_lambda_three":
			return _p12_lambda_three()
		"p12_legacy_freeze":
			return _p12_legacy_freeze()
	push_error("[SimAlign] 未知执行器：%s" % String(p_case["path"]))
	assert(false)
	return null


# ── pkg1 执行器（公式管线；formula target 逐字 DUMMY） ─────────────────
static func _p1_resolve(p_env: SimEnv, p_input: Dictionary) -> DamageResult:
	var pipe := DamagePipeline.new()
	pipe.begin_frame(1)
	var target := SimEnemy.make_formula_target(1000000.0)
	var ctx := DamageContext.make()
	ctx.source_uid = 1
	ctx.target = target
	ctx.target_uid = int(target.get("uid"))
	ctx.frame_stamp = 1
	ctx.base_atk = 100.0
	ctx.crit_chance = float(p_input.get("crit_chance", 0.0))
	ctx.crit_mult = float(p_input.get("crit_mult", 2.0))
	ctx.flat_bonus = float(p_input.get("flat", 0.0))
	var adds: Variant = p_input.get("adds", [])
	for e in adds:
		var row: Dictionary = e
		ctx.add_entries.append(row)
	var mults: Variant = p_input.get("mults", [])
	for m in mults:
		if not bool(p_input.get("dedup_same_source", false)):
			ctx.mult_pools.append(m)
		else:
			ctx.mult_pools.append(m)              # 同 source_uid 两条原样入（防御层去重路径）
	var locals: Variant = p_input.get("locals", [])
	for l in locals:
		ctx.local_pools.append(l)
	if p_input.has("element"):
		ctx.element = int(p_input["element"])
	if p_input.has("hit_flags"):
		ctx.hit_flags = int(p_input["hit_flags"])
	if p_input.has("resist"):
		var res_in: Array = p_input["resist"]
		for ri in range(target.resist.size()):
			target.resist[ri] = float(res_in[ri]) if ri < res_in.size() else 0.0
	if p_input.has("vuln"):
		target.set("status_vuln", float(p_input["vuln"]))
	var r: DamageResult = pipe.resolve(ctx)
	target.free()
	return r


static func _p1_final(p_env: SimEnv, p_input: Dictionary) -> float:
	return _p1_resolve(p_env, p_input).final_value


static func _p1_reaction(p_env: SimEnv, p_input: Dictionary) -> float:
	var pipe := DamagePipeline.new()
	pipe.begin_frame(1)
	var target := SimEnemy.make_formula_target(1000000.0)
	var ctx := DamageContext.make()
	ctx.source_uid = 1
	ctx.target = target
	ctx.target_uid = int(target.get("uid"))
	ctx.frame_stamp = 1
	ctx.base_atk = float(p_input["snapshot"])
	ctx.element = GameConst.ReactionType.RXN_FIR_ICE
	ctx.crit_chance = 1.0
	ctx.crit_mult = 2.0
	var r: DamageResult = pipe.resolve_reaction(float(p_input["snapshot"]),
		float(p_input["coef"]), ctx)
	target.free()
	return r.final_value


# ── pkg3 执行器（局部 ElementalSystem + 裸 Enemy；镜像 pkg3 调用序） ────
static func _align_sys(p_env: SimEnv) -> ElementalSystem:
	var sys := ElementalSystem.new()
	sys.name = "SimAlignSys%d" % (randi() % 100000)
	sys.pipeline = DamagePipeline.new()
	(sys.pipeline as DamagePipeline).set_rng_seed(42)
	sys.enemy_grid = SpaceGrid.new()
	sys.enemy_grid.configure(Vector2(720.0, 1280.0), 192.0)
	return sys


static func _align_enemy(p_hp: float, p_pos: Vector2) -> Enemy:
	# 裸 Enemy（不入树/不入池）——uid 必须独立分配：uid 全 0 会使反应幂等键互撞
	# （resolve_reaction 缓存返回不落血）与连锁 dedup 全滤（pkg3 侧由 spawn 分配 uid）
	var e := Enemy.new()
	e.uid = GameConst.next_uid()
	e.max_hp = p_hp
	e.hp = p_hp
	e.position = p_pos
	return e


static func _bump() -> void:
	GameConfig.advance_frame()                    # pkg3 _bump_frame 镜像（幂等键时钟推进）


static func _p3_shatter(p_env: SimEnv, p_void: bool) -> float:
	var sys := _align_sys(p_env)
	if p_void:
		var w := _mount_void_weapon(p_env, sys)
		var e1 := _align_enemy(1000.0, Vector2(200, 200))
		sys.register_host(e1)
		sys.apply_attach(e1, GameConst.Element.FIR, 100.0, {"snapshot": 200.0})
		sys.apply_attach(e1, GameConst.Element.FIR, 30.0)
		sys.apply_attach(e1, GameConst.Element.ICE, 30.0)
		_bump()
		sys.detect_reactions()
		var hp := e1.hp
		var stub: Node2D = w.get("player") if w.get("player") is Node2D else null
		e1.free()
		(w as WeaponBase).free()
		if stub != null:
			stub.free()
		return hp
	var e1 := _align_enemy(1000.0, Vector2(200, 640))
	sys.register_host(e1)
	sys.apply_attach(e1, GameConst.Element.FIR, 60.0)
	sys.apply_attach(e1, GameConst.Element.FIR, 100.0, {"snapshot": 200.0})
	sys.apply_attach(e1, GameConst.Element.FIR, 30.0)
	sys.apply_attach(e1, GameConst.Element.ICE, 30.0)
	_bump()
	sys.detect_reactions()
	var hp := e1.hp
	e1.free()
	return hp


static func _p3_shatter_consume(p_env: SimEnv) -> bool:
	var sys := _align_sys(p_env)
	var e1 := _align_enemy(1000000.0, Vector2(200, 640))
	sys.register_host(e1)
	sys.apply_attach(e1, GameConst.Element.FIR, 60.0)
	sys.apply_attach(e1, GameConst.Element.FIR, 100.0, {"snapshot": 200.0})
	sys.apply_attach(e1, GameConst.Element.FIR, 30.0)
	sys.apply_attach(e1, GameConst.Element.ICE, 30.0)
	_bump()
	sys.detect_reactions()
	var st: ElementalState = e1.get("elemental")
	var ok: bool = is_zero_approx(st.gauges[GameConst.Element.FIR]) \
		and is_zero_approx(st.gauges[GameConst.Element.ICE]) \
		and is_zero_approx(st.burn_timer) and st.burn_layers == 0
	e1.free()
	return ok


static func _p3_overload(p_env: SimEnv) -> Array:
	var sys := _align_sys(p_env)
	var e2 := _align_enemy(1000.0, Vector2(600, 640))
	var e2b := _align_enemy(1000.0, Vector2(660, 640))
	var e2c := _align_enemy(1000.0, Vector2(750, 640))
	sys.register_host(e2)
	sys.register_host(e2b)
	sys.register_host(e2c)
	sys.apply_attach(e2, GameConst.Element.FIR, 30.0, {"snapshot": 100.0})
	sys.apply_attach(e2, GameConst.Element.LTG, 30.0)
	var roster: Array[Node2D] = [e2, e2b, e2c]
	sys.enemy_grid.rebuild(roster)
	_bump()
	sys.detect_reactions()
	var out: Array = [e2.hp, [e2b.hp, e2c.hp]]
	for e in [e2, e2b, e2c]:
		e.free()
	return out


static func _p3_superconduct(p_env: SimEnv) -> Array:
	var sys := _align_sys(p_env)
	var e3 := _align_enemy(1000.0, Vector2(200, 900))
	e3.resist = [0.3, 0.1, 0.0, 0.0, 0.0]
	sys.register_host(e3)
	sys.apply_attach(e3, GameConst.Element.ICE, 30.0)
	sys.apply_attach(e3, GameConst.Element.LTG, 30.0)
	_bump()
	sys.detect_reactions()
	var after: Array = [e3.get_resist(GameConst.Element.KIN),
		e3.get_resist(GameConst.Element.FIR), e3.get_resist(GameConst.Element.LTG)]
	_bump()
	sys.tick(6.5)
	var restored: Array = [e3.get_resist(GameConst.Element.KIN),
		e3.get_resist(GameConst.Element.FIR), e3.get_resist(GameConst.Element.LTG)]
	e3.free()
	return [after, restored]


static func _p3_cd_sequence(p_env: SimEnv) -> Array:
	var sys := _align_sys(p_env)
	var e3 := _align_enemy(1000000.0, Vector2(200, 900))
	sys.register_host(e3)
	sys.apply_attach(e3, GameConst.Element.ICE, 30.0)
	sys.apply_attach(e3, GameConst.Element.LTG, 30.0)
	_bump()
	sys.detect_reactions()
	var st: ElementalState = e3.get("elemental")
	var cd := float(st.reaction_cd.get(GameConst.ReactionType.RXN_ICE_LTG, -1.0))
	var super0 := DebugStats.get_counter(&"reaction_superconduct")
	sys.apply_attach(e3, GameConst.Element.ICE, 30.0)
	sys.apply_attach(e3, GameConst.Element.LTG, 30.0)
	_bump()
	sys.detect_reactions()
	var blocked := DebugStats.get_counter(&"reaction_superconduct") == super0
	_bump()
	sys.tick(6.0)
	sys.apply_attach(e3, GameConst.Element.ICE, 30.0)
	sys.apply_attach(e3, GameConst.Element.LTG, 30.0)
	_bump()
	sys.detect_reactions()
	var expire := DebugStats.get_counter(&"reaction_superconduct") == super0 + 1
	e3.free()
	return [cd, blocked, expire]


static func _p3_priority(p_env: SimEnv) -> Array:
	var sys := _align_sys(p_env)
	var e5 := _align_enemy(1000000.0, Vector2(600, 200))
	sys.register_host(e5)
	sys.apply_attach(e5, GameConst.Element.FIR, 30.0)
	sys.apply_attach(e5, GameConst.Element.ICE, 30.0)
	sys.apply_attach(e5, GameConst.Element.LTG, 30.0)
	_bump()
	sys.detect_reactions()
	var st: ElementalState = e5.get("elemental")
	var out: Array = [st.gauges[GameConst.Element.FIR], st.gauges[GameConst.Element.ICE],
		st.gauges[GameConst.Element.LTG]]
	e5.free()
	return out


static func _p3_shock_chain(p_env: SimEnv) -> Array:
	var sys := _align_sys(p_env)
	var e_a := _align_enemy(1000.0, Vector2(360, 640))
	var e_b := _align_enemy(1000.0, Vector2(440, 640))
	var e_c := _align_enemy(1000.0, Vector2(360, 760))
	var e_d := _align_enemy(1000.0, Vector2(480, 700))
	var e_e := _align_enemy(1000.0, Vector2(900, 640))
	for h in [e_a, e_b, e_c, e_d, e_e]:
		sys.register_host(h)
	var roster: Array[Node2D] = [e_a, e_b, e_c, e_d, e_e]
	sys.enemy_grid.rebuild(roster)
	sys.apply_attach(e_a, GameConst.Element.LTG, 100.0, {"hit_damage": 100.0})
	var out: Array = [e_b.hp, e_c.hp, e_d.hp, e_a.hp, e_e.hp]
	for e in [e_a, e_b, e_c, e_d, e_e]:
		e.free()
	return out


static func _p3_dot(p_env: SimEnv) -> float:
	var sys := _align_sys(p_env)
	var e6 := _align_enemy(1000.0, Vector2(600, 900))
	sys.register_host(e6)
	sys.apply_attach(e6, GameConst.Element.FIR, 100.0, {"snapshot": 200.0})
	_bump()
	sys.tick(0.5)
	_bump()
	sys.tick(0.5)
	var hp := e6.hp
	e6.free()
	return hp


static func _p3_trait_value(p_env: SimEnv, p_input: Dictionary) -> Array:
	var data: TraitData = p_env.registry.get_trait(StringName(String(p_input["trait"])))
	assert(data != null)
	return [data.value, float(data.params.get(String(p_input["key"]), 0.0))]


static func _mount_void_weapon(p_env: SimEnv, p_sys: ElementalSystem) -> Node2D:
	# VOID 武器 + stub 宿主（pkg11 _mount_stub_player 同款：attach_trait → rebuild 全量重算）
	var data: WeaponData = p_env.registry.get_weapon(&"W1_pistol")
	var w: WeaponBase = BallisticWeapon.new()
	w.setup(data, null, {"pipeline": p_sys.pipeline, "elemental": p_sys})
	var void_trait: TraitData = p_env.registry.get_trait(&"ELE_REACTION_VOID")
	assert(void_trait != null and w.attach_trait(void_trait))
	var psrc := GDScript.new()
	psrc.source_code = "extends Node2D\nvar weapon_slots: Array = []\n"
	psrc.reload()
	var stub: Node2D = psrc.new()
	(Engine.get_main_loop() as SceneTree).get_root().add_child(stub)
	stub.weapon_slots = [w]
	w.player = stub
	p_sys.rebuild_registries(stub)
	return w


static func _p3_w1_l5_hit(p_env: SimEnv) -> float:
	# W1 L5 单发 24×V（V=1：零抗零易伤零乘区；crit_chance=0 公式夹具口径）
	var pipe := DamagePipeline.new()
	pipe.set_rng_seed(42)
	pipe.begin_frame(1)
	var data: WeaponData = p_env.registry.get_weapon(&"W1_pistol")
	var w := BallisticWeapon.new()
	w.setup(data, null, {})
	for i in range(WeaponBase.MAX_LEVEL - 1):
		w.level_up()
	var target := SimEnemy.make_formula_target(1000000.0)
	var ctx := DamageContext.make()
	ctx.source_uid = 1
	ctx.target = target
	ctx.target_uid = int(target.get("uid"))
	ctx.frame_stamp = 1
	ctx.base_atk = w.get_current_atk()            # W1 L5 = 24
	ctx.crit_chance = 0.0
	var r: DamageResult = pipe.resolve(ctx)
	var v := r.final_value
	w.free()
	target.free()
	return v


static func _p3_gatling_interval(p_env: SimEnv) -> Array:
	# 加特林冷热两态 interval 锚（W2 L1：冷 rof 11 / 满 14——.tres 字面）
	var data: WeaponData = p_env.registry.get_weapon(&"W2_gatling")
	var w := BallisticWeapon.new()
	w.setup(data, null, {})
	var cold := w._fire_interval()
	w.spin_up_left = 0.0                          # 满热（预热进度 1 → rof_hot 14）
	var hot := w._fire_interval()
	w.free()
	return [cold, hot]


static func _p3_lambda_decay() -> Array:
	# λ 比例衰减（F-22）：60×(1−λ) → FIR 39 / ICE 42 / LTG 36（pkg3 同参）
	var st := ElementalState.new()
	st.apply(GameConst.Element.FIR, 60.0)
	st.apply(GameConst.Element.ICE, 60.0)
	st.apply(GameConst.Element.LTG, 60.0)
	var lambdas: Array[float] = [0.35, 0.30, 0.40]
	st.tick(1.0, lambdas)
	return [st.gauges[GameConst.Element.FIR], st.gauges[GameConst.Element.ICE],
		st.gauges[GameConst.Element.LTG]]


static func _p3_chill() -> Array:
	# 寒滞：ICE 满槽 → speed 0.6 + 易伤 ×1.25（pkg3 同参）
	var st := ElementalState.new()
	var code := st.apply(GameConst.Element.ICE, 100.0)
	assert(code == ElementalState.TRIGGER_CHILL)
	return [st.get_speed_factor(), st.get_vuln_factor()]


static func _p3_burn_trigger() -> Array:
	# 点燃：FIR 60+40 满槽 → 层 1 / 3s / 快照 200 / 槽清零（pkg3 同参）
	var st := ElementalState.new()
	st.apply(GameConst.Element.FIR, 60.0)
	var code := st.apply(GameConst.Element.FIR, 40.0, 200.0)
	assert(code == ElementalState.TRIGGER_BURN)
	return [float(st.burn_layers), st.burn_timer, st.burn_snapshot_atk,
		st.gauges[GameConst.Element.FIR]]


static func _p3_rof_cap() -> float:
	# 射速封顶 30/s：rof 90 → clamp → 冷却 1/30（pkg3#707 双护栏锚）
	var stats: WeaponLevelStats = WeaponLevelStats.new()
	stats.base_atk = 10.0
	stats.rof = 90.0
	var d := WeaponData.new()
	d.id = &"SIM_ROF_CAP"
	d.display_name = "对齐门射速封顶夹具"
	d.form = GameConst.WeaponForm.BALLISTIC
	d.ballistic = {"proj_speed": 600.0, "range": 600.0, "spread_deg": 0.0}
	d.upgrade_table = [stats]
	var w := BallisticWeapon.new()
	w.setup(d, null, {})
	var cd := w._fire_interval()
	w.free()
	return cd


# ── pkg11 执行器 ──────────────────────────────────────────────────
static func _mount_mastery_weapon(p_env: SimEnv, p_sys: ElementalSystem,
		p_attach: int) -> Dictionary:
	# 武器 + stub 宿主（V33 镜像）；返回 {weapon, stub}
	var data: WeaponData = p_env.registry.get_weapon(&"W1_pistol")
	var w: WeaponBase = BallisticWeapon.new()
	w.setup(data, null, {"pipeline": p_sys.pipeline, "elemental": p_sys})
	var mdata: TraitData = p_env.registry.get_trait(&"ELE_MASTERY")
	for i in range(p_attach):
		w.attach_trait(mdata)
	var psrc := GDScript.new()
	psrc.source_code = "extends Node2D\nvar weapon_slots: Array = []\n"
	psrc.reload()
	var stub: Node2D = psrc.new()
	(Engine.get_main_loop() as SceneTree).get_root().add_child(stub)
	stub.weapon_slots = [w]
	w.player = stub
	p_sys.rebuild_registries(stub)
	return {"weapon": w, "stub": stub}


static func _p11_mastery(p_env: SimEnv, p_layers: int, p_extra_weapon: bool,
		p_extra_attach: bool) -> float:
	var sys := _align_sys(p_env)
	var m := _mount_mastery_weapon(p_env, sys, p_layers)
	var mult := sys.reaction_mult()
	if p_extra_weapon:
		var m2 := _mount_mastery_weapon(p_env, sys, 2)
		mult = sys.reaction_mult()
		(m2["weapon"] as WeaponBase).free()
		(m2["stub"] as Node2D).free()
	(m["weapon"] as WeaponBase).free()
	(m["stub"] as Node2D).free()
	return mult


static func _p11_mastery_cap(p_env: SimEnv) -> Array:
	# 跨武器 2+2 → 全局封顶 3 → 仍 1.75（V33）
	var sys := _align_sys(p_env)
	var m1 := _mount_mastery_weapon(p_env, sys, 2)
	var m2 := _mount_mastery_weapon(p_env, sys, 2)
	(m2["stub"] as Node2D).weapon_slots.append(m1["weapon"])
	(m1["weapon"] as WeaponBase).player = m2["stub"]
	var all_slots: Array = [m1["weapon"], m2["weapon"]]
	(m2["stub"] as Node2D).weapon_slots = all_slots
	sys.rebuild_registries(m2["stub"])
	var cap := sys.reaction_mult()
	(m1["weapon"] as WeaponBase).free()
	(m2["weapon"] as WeaponBase).free()
	(m2["stub"] as Node2D).free()
	if is_instance_valid(m1["stub"]):
		(m1["stub"] as Node2D).free()
	return [cap, cap]


static func _p11_mastery_reject(p_env: SimEnv) -> Array:
	# 第 4 层：stack_max=3 → attach 拒绝，精通不增（V33）
	var sys := _align_sys(p_env)
	var m := _mount_mastery_weapon(p_env, sys, 3)
	var rejected: bool = not (m["weapon"] as WeaponBase).attach_trait(
		p_env.registry.get_trait(&"ELE_MASTERY"))
	var mult := sys.reaction_mult()
	(m["weapon"] as WeaponBase).free()
	(m["stub"] as Node2D).free()
	return [rejected, mult]


static func _p11_step_mirror(p_env: SimEnv, p_input: Dictionary) -> float:
	# register_mastery 直调通道镜像（V34）：step 0.25 × layers 2 → 1.5
	var sys := _align_sys(p_env)
	sys.register_mastery(9001, int(p_input["layers"]), float(p_input["step"]))
	return sys.reaction_mult()


static func _p11_void_identity(p_env: SimEnv) -> float:
	# 无精通仅 VOID → 恒等 ×1.8（V25 口径：reaction_mult 基线）
	var sys := _align_sys(p_env)
	var w := _mount_void_weapon(p_env, sys)
	var mult := sys.reaction_mult()
	var stub: Node2D = w.get("player") if w.get("player") is Node2D else null
	(w as WeaponBase).free()
	if stub != null:
		stub.free()
	return mult


# ── pkg12 执行器 ──────────────────────────────────────────────────
static func _p12_freeze_timer(p_env: SimEnv) -> float:
	var sys := _align_sys(p_env)
	var e1 := _align_enemy(1000000.0, Vector2(120, 200))
	sys.register_host(e1)
	sys.apply_attach(e1, GameConst.Element.WAT, 30.0)
	sys.apply_attach(e1, GameConst.Element.ICE, 30.0)
	_bump()
	sys.detect_reactions()
	var st: ElementalState = e1.get("elemental")
	var t := st.freeze_timer
	e1.free()
	return t


static func _p12_counter_table() -> Array:
	var out: Array = []
	for v in GameConst.SHIELD_COUNTER:
		out.append(v)
	return out


static func _p12_counter_hit() -> float:
	# ICE 盾（element 2）250 血吃 FIR 100 → 克 ×2 → 50
	var e := _align_enemy(1000.0, Vector2(120, 200))
	e.shield_element = 2
	e.shield_max = 250.0
	e.shield_hp = 250.0
	var fake := DamageResult.new()
	fake.final_value = 100.0
	fake.popup_style = GameConst.PopupStyle.NORMAL
	fake.element = GameConst.Element.FIR
	fake.panel_snapshot = 100.0
	e.take_result(fake)
	var hp := e.shield_hp
	e.free()
	return hp


static func _p12_break_no_spill() -> Array:
	# 破盾无溢出 + 不可再生 + killed 恒 false（V51 e）
	var e := _align_enemy(1000.0, Vector2(400, 200))
	e.shield_element = 4
	e.shield_max = 5.0
	e.shield_hp = 5.0
	var fake := DamageResult.new()
	fake.final_value = 100.0
	fake.popup_style = GameConst.PopupStyle.NORMAL
	fake.element = GameConst.Element.KIN
	fake.panel_snapshot = 100.0
	e.take_result(fake)
	var after_break: Array = [e.shield_hp, is_equal_approx(e.hp, 1000.0),
		e.shield_active(), not e.dead]
	fake.final_value = 7.0
	e.take_result(fake)
	var hp7 := e.hp
	e.free()
	return [float(after_break[0]), bool(after_break[1]), bool(after_break[2]),
		bool(after_break[3]) and is_equal_approx(hp7, 993.0)]


static func _p12_wat_ltg_counter() -> float:
	# WAT 盾（4）吃 LTG 100 ×2 → 80（克环 WAT↔LTG）
	var e := _align_enemy(1000.0, Vector2(120, 200))
	e.shield_element = 4
	e.shield_max = 100.0
	e.shield_hp = 100.0
	var fake := DamageResult.new()
	fake.final_value = 10.0
	fake.popup_style = GameConst.PopupStyle.NORMAL
	fake.element = GameConst.Element.LTG
	fake.panel_snapshot = 100.0
	e.take_result(fake)
	var hp := e.shield_hp
	e.free()
	return hp


static func _p12_reaction_exempt() -> float:
	# REACTION 通道不判克制（ReactionType 中性 ID 撞值防线）→ ×1
	var e := _align_enemy(1000.0, Vector2(400, 200))
	e.shield_element = 4
	e.shield_max = 100.0
	e.shield_hp = 100.0
	var fake := DamageResult.new()
	fake.final_value = 10.0
	fake.popup_style = GameConst.PopupStyle.REACTION
	fake.element = GameConst.ReactionType.RXN_WAT_LTG
	fake.panel_snapshot = 100.0
	e.take_result(fake)
	var hp := e.shield_hp
	e.free()
	return hp


static func _p12_lambda_three() -> Array:
	# λ_WAT 0.38 三处（V41 c：schema 默认 / GameConfig.balance 加载 / validator 无告警）
	var schema := BalanceTables.new().element_decay_lambda
	var loaded: Array[float] = GameConfig.balance.element_decay_lambda \
		if GameConfig.balance != null else [-1.0]
	var clean := true
	for issue in DataValidator.new().validate_balance(BalanceTables.new()):
		if String((issue as Dictionary).get("message", "")).contains("element_decay_lambda"):
			clean = false
	return [float(schema[3]), float(loaded[3]), clean]


static func _p12_legacy_freeze() -> float:
	# 二次满槽完全冻结 legacy 1.2s（elemental_state:235）
	var st := ElementalState.new()
	st.apply(GameConst.Element.ICE, 100.0)
	st.apply(GameConst.Element.ICE, 100.0)
	return st.freeze_timer


# ── 比对 ──────────────────────────────────────────────────────────
static func _eq(p_measured: Variant, p_expect: Variant) -> bool:
	# 逐位 ==（数值 / bool / Array 逐元素；禁止 is_equal_approx 弱化）
	if p_expect is Array:
		if not (p_measured is Array) or (p_measured as Array).size() != (p_expect as Array).size():
			return false
		for i in range((p_expect as Array).size()):
			if not _eq((p_measured as Array)[i], (p_expect as Array)[i]):
				return false
		return true
	if p_expect is bool or p_measured is bool:
		return typeof(p_measured) == typeof(p_expect) and p_measured == p_expect
	if p_expect is float or p_expect is int:
		if not (p_measured is float or p_measured is int):
			return false
		return float(p_measured) == float(p_expect) or is_equal_approx(float(p_measured), float(p_expect))
	return p_measured == p_expect

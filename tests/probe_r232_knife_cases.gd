# tests/probe_r232_knife_cases.gd（R232 刀0 四臂测量用例体——入口运行时加载）
# 夹具口径（r225 MICRO 同构 + R232 分析修正 #4 全量采纳）：
# · boot：main.tscn 真链、W2_gatling L5 + PIERCE×3/MULTI×2/BOUNCE×3/NOVA×2/FRACTAL×2
#   （12 词条指纹=probe_r225_separation 同构筑）、PerfGovernor 冻结 tier2、state=MENU
#   （直驱管线零场景噪声）。
# · FULL 臂真栈载体：真 ProjectileBase（panel_snapshot=武器 build_panel_snapshot、
#   trait_stack=acquire_runtime 运行栈、weapon_ref 接遗物通道）——遗物夹具
#   REL_GLASS_CANNON（恒注 glass_dmg）+ REL_BOSS_TROPHY（目标 tags=ELITE 注 elite_dmg）。
# · FULL-M 变体：第二把 W2 挂 MULT×4（SYN_BULWARK 满血真/MEC_OVERKILL 目标 20% 血真/
#   ELE_ARC_SURGE 目标感电槽真/SYN_FROST_EXEC 易伤计时真）——量 ② 段 MULT 主体上界
#   （boot12 栈 MULT 子集=0，R232 分析 AC-1/R6 披露面）。
# · 打点纪律（AC-1 三条裁定）：STEP 只做占比；MICRO 臂零打点；A/B 只对 FULL/MICRO。
# · CHURN 臂 override=8 直达饱和（分析 AC-1：无需 -3+tier 复合）。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const BASELINE_JSON := "res://docs/qa/probe_r232_knife_baseline.json"
const ROUNDS := 3                      # 同日三轮取中位（臂序平衡 A,B / B,A / A,B）
const MICRO_BATCHES := [48, 96, 192]   # MICRO 臂三档批（r225 同值——可对拍口径）
const MICRO_ENEMIES := 48              # MICRO/FULL 共用真敌目标池（轮转命中）
const MICRO_BASE_ATK := 100.0          # MICRO 合成面板（r225 同值——代表负载披露）
const FULL_BATCH := 96                 # FULL 臂批大小 ×3 批=288 结算/臂/轮
const FULL_REPS := 3
const FULLM_BATCH := 96                # FULL-M 变体同构
const CHURN_BUDGET := 8                # 强制帽（分析 AC-1 裁定直达值）
const CHURN_PAIRS := 56                # 顺延对数（8 预算耗尽后全顺延）
const CHURN_MERGE_PER_PAIR := 8        # 同对累积次数/对（merge 单项 µs 分母）
const STEP_BATCH := 128                # STEP 臂每幂等窗结算数
const STEP_BATCHES := 3                # ×3=384 采样（占比统计面）
const STEP_SUB_ITERS := 256            # STEP 子项披露行均摊次数
const TARGET_HP := 1.0e15              # 巨血防杀（r225 MICRO 同口径）
const R225_REF_US := 50.1              # r225 档案 MICRO 中位（跨日披露参照，非判定基线）

var tree: SceneTree
var _gl: GameLoop = null
var _pipe: DamagePipeline = null
var _fails: int = 0
var _weapon: WeaponBase = null         # boot12 主武器（r225 指纹）
var _weapon_m: WeaponBase = null       # MULT×4 变体武器（FULL-M 专用）
var _proj: ProjectileBase = null       # FULL 臂载体弹（12 词条运行栈）
var _proj_m: ProjectileBase = null     # FULL-M 载体弹（16 词条运行栈）
var _targets: Array[Enemy] = []
var _target_states: Array[ElementalState] = []
# STEP 臂段间状态载体（lambda 按值捕获局部量——段间传递必须走成员，R232 自检修正）
var _s_stack: ModifierStack = null
var _s_crit: bool = false
var _s_result: DamageResult = null
var _last_step_total_us: float = 0.0


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(20261004)
	print("══ R232 结算链瘦身 刀0 四臂测量：STEP × FULL(真12词条栈+遗物) × CHURN(帽8) × MICRO(A/B 开关双臂) × %d 轮 ══" % ROUNDS)
	if not _boot():
		_teardown()
		return
	var runs: Array[Dictionary] = []
	for rnd in range(1, ROUNDS + 1):
		print("════════ 第 %d/%d 轮 ════════" % [rnd, ROUNDS])
		var run := {"round": rnd}
		# 臂序平衡（R232 自检修正：首轮实测固定 A→B 序带进暖机漂移——MICRO A 首轮
		# 虚高 13%、FULL-M B 跨轮 2× 散布；偶数轮 B 先 A 后，中位数两侧抵消）
		if rnd % 2 == 0:
			var arms_b := _measure_arms(true)
			run["micro_b"] = arms_b["micro"]
			run["full_b"] = arms_b["full"]
			run["fullm_b"] = arms_b["fullm"]
			await tree.process_frame             # 臂界冲刷（r225 修轮：延迟消息出队）
			var arms_a := _measure_arms(false)
			run["micro_a"] = arms_a["micro"]
			run["full_a"] = arms_a["full"]
			run["fullm_a"] = arms_a["fullm"]
		else:
			var arms_a := _measure_arms(false)
			run["micro_a"] = arms_a["micro"]
			run["full_a"] = arms_a["full"]
			run["fullm_a"] = arms_a["fullm"]
			await tree.process_frame             # 臂界冲刷（r225 修轮：延迟消息出队）
			var arms_b := _measure_arms(true)
			run["micro_b"] = arms_b["micro"]
			run["full_b"] = arms_b["full"]
			run["fullm_b"] = arms_b["fullm"]
		await tree.process_frame
		run["churn_a"] = _arm_churn("A（off=存 ctx 原路径）", false)
		run["churn_b"] = _arm_churn("B（on=字段袋路径）", true)
		run["step"] = _arm_step()
		_print_round_derive(run)
		runs.append(run)
	_store_json(runs)
	_gates(runs)
	_teardown()


func _measure_arms(p_on: bool) -> Dictionary:
	DamagePipeline.CTX_REUSE = p_on
	TraitStack.TRAIT_PRECACHE = p_on
	ModifierStack.AGG_TYPED = false       # 刀1e 收口定案：typed 同进程配对实测反向
	                                      # +4-7µs/结（≤5 条目 Dictionary 已近最优），
	                                      # shipped=false 留档开关——B 臂=现行刀路径
	var tag := "B（CTX_REUSE/TRAIT_PRECACHE on=现行刀路径）" if p_on \
		else "A（CTX_REUSE/TRAIT_PRECACHE off=改前路径）"
	return {
		"micro": _arm_micro(tag),
		"full": _arm_full("B" if p_on else "A", p_on),
		"fullm": _arm_full_m("B" if p_on else "A"),
	}


func fail_count() -> int:
	return _fails


# ── 引导（r225 _boot 同构——menu 态直驱变体） ───────────────────────

func _boot() -> bool:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "ProbeR232Knife"
	tree.root.add_child(_gl)
	if not (_gl.boot_ready and _gl.state == GameConst.GameStatus.MENU):
		push_error("[probe] Boot 失败：%s" % str(_gl.boot_fatal))
		_fails += 1
		return false
	PerfGovernor.set_process(false)
	PerfGovernor.mode_override = 0
	PerfGovernor.tier_override = 2
	_gl.current_map_id = &"world_grove"
	if not _gl.start_run():
		push_error("[probe] start_run 失败")
		_fails += 1
		return false
	_gl.state = GameConst.GameStatus.MENU   # 直驱态：引擎帧零武器开火/零刷怪噪声（r223 同款）
	_gl.player.set("xp_need", 1.0e12)
	_gl.player.set("max_hp", 1.0e12)
	_gl.player.set("hp", 1.0e12)
	_gl.player.unlocked_slots = 6
	_weapon = _gl.player.add_weapon(_gl.registry.get_weapon(&"W2_gatling"))
	if _weapon == null:
		push_error("[probe] W2 加特林装配失败")
		_fails += 1
		return false
	_weapon.level = 5
	var ok := 0
	for spec in [[&"AFF_PIERCE", 3], [&"AFF_MULTI", 2], [&"MEC_BOUNCE", 3],
			[&"MEC_KILL_BLAST", 2], [&"MEC_FRACTAL", 2]]:
		var trd: TraitData = _gl.registry.get_trait(spec[0])
		for i in range(int(spec[1])):
			if _weapon.attach_trait(trd):
				ok += 1
	print("boot.词条挂载回执：%d/12（PIERCE×3 MULTI×2 BOUNCE×3 NOVA×2 FRACTAL×2——r225 同指纹）" % ok)
	_weapon_m = _gl.player.add_weapon(_gl.registry.get_weapon(&"W2_gatling"))
	if _weapon_m == null:
		push_error("[probe] FULL-M 变体武器装配失败")
		_fails += 1
		return false
	var okm := 0
	for mid in [&"SYN_BULWARK", &"MEC_OVERKILL", &"ELE_ARC_SURGE", &"SYN_FROST_EXEC"]:
		if _weapon_m.attach_trait(_gl.registry.get_trait(mid)):
			okm += 1
	print("boot.FULL-M 变体栈：MULT×%d（BULWARK/OVERKILL/ARC_SURGE/FROST_EXEC——② 段主体上界夹具）" % okm)
	# 遗物夹具（分析修正 #4）：恒注 glass_dmg + elite tags 目标注 elite_dmg
	_gl.relic_handler.activate(&"REL_GLASS_CANNON")
	_gl.relic_handler.activate(&"REL_BOSS_TROPHY")
	print("boot.遗物夹具：REL_GLASS_CANNON+REL_BOSS_TROPHY（注入面=inject_hit_mult_pools）")
	if not _build_carrier(_weapon, false):
		return false
	if not _build_carrier(_weapon_m, true):
		return false
	if not _build_targets():
		return false
	DamagePipeline.settle_budget_override = -2
	_pipe = _gl.pipeline
	return true


func _build_carrier(p_weapon: WeaponBase, p_is_m: bool) -> bool:
	# FULL 臂载体弹：真 ProjectileBase + 运行栈借出 + weapon_ref 接遗物/条件通道
	var pool := _gl.pools[&"projectile"] as ProjectilePool
	var proj := pool.acquire() as ProjectileBase
	if proj == null:
		push_error("[probe] 载体弹获取失败")
		_fails += 1
		return false
	proj.damage_pipeline = _gl.pipeline
	proj.enemy_grid = _gl.enemy_grid
	proj.elemental = _gl.elemental
	proj.pool = pool
	proj.spawn({
		"velocity": Vector2(0, 0), "lifetime": 1.0e9, "pierce": 999, "bounces": 0,
		"hitbox_radius": 6.0, "team": 0, "generation": 0,
		"weapon_uid": p_weapon.uid, "weapon_ref": p_weapon,
		"panel_snapshot": p_weapon.build_panel_snapshot(),
		"trait_stack": (p_weapon.trait_stack as TraitStack).acquire_runtime(),
		"position": Vector2(360.0, 660.0),
	})
	if p_is_m:
		_proj_m = proj
	else:
		_proj = proj
	return true


func _build_targets() -> bool:
	# 真敌目标池（r225 MICRO 同构——池化直驱不入 spawner；巨血防杀；FULL-M 真值条件面：
	# tags=ELITE + hp 压 20% + 感电槽 50 + 易伤计时 1s——四个 MULT 条件三真一探）
	var epool := _gl.pools[&"enemy"] as EnemyPool
	for i in range(MICRO_ENEMIES):
		var e := epool.acquire() as Enemy
		if e == null:
			continue
		var d := EnemyData.new()
		d.id = &"E_R232_MICRO"
		d.display_name = "R232_MICRO"
		d.hp_base = TARGET_HP
		d.spd_base = 0.0
		d.dmg_base = 0.0
		d.exp_base = 1.0
		d.hitbox_r = 14.0
		d.resist = [0.0, 0.0, 0.0, 0.0]
		e.spawn(d, 16, 1)                    # tags=1（TAG_ELITE——REL_BOSS_TROPHY 注入面）
		e.bucket_host = epool.bucket_host    # r225 _spawn_one 同款（渲染面一致性）
		e.global_position = Vector2(360.0, 660.0)
		var st := ElementalState.new()
		st.gauges[GameConst.Element.LTG] = 50.0   # TARGET_SHOCKED 真
		st.vuln_timer = 60.0                      # TARGET_FROZEN(ICE 族)/易伤注入面 真
		e.elemental = st
		_target_states.append(st)
		e.hp = e.max_hp * 0.2                     # TARGET_HP_BELOW 真（MEC_OVERKILL）
		_targets.append(e)
	print("boot.目标池：%d 真敌（巨血 %.0e · tags=ELITE · 感电/易伤/20%%血真值条件面）" % [_targets.size(), TARGET_HP])
	return not _targets.is_empty()


# ── MICRO 臂（r225 同构复刻——零打点；A/B 双臂） ────────────────────

func _arm_micro(p_tag: String) -> Dictionary:
	print("── MICRO 臂%s（override=-2 直驱管线合成结算，批 %s，零打点） ──" % [p_tag, str(MICRO_BATCHES)])
	DamagePipeline.settle_budget_override = -2
	_pipe.call(&"begin_frame", -1)
	var targets := _targets
	var base := _pipe_snap()
	var batch_us := {}
	var frame_no := 910000
	for n in MICRO_BATCHES:
		var batch := int(n)
		var ctxs: Array[DamageContext] = []           # ctx 预构建（计时窗外——量 resolve 不量构建）
		for i in range(batch):
			ctxs.append(_micro_ctx(910000 + i, targets[i % targets.size()], frame_no))
		_pipe.call(&"begin_frame", frame_no)          # 幂等缓存清场（计时窗外）
		frame_no += 1
		var t0 := Time.get_ticks_usec()
		for ctx in ctxs:
			_pipe.call(&"resolve", ctx)
		var us := Time.get_ticks_usec() - t0
		batch_us[batch] = float(us) / float(batch)
		(_pipe.get(&"_resolved_queue") as Array).clear()
	var snap := _pipe_snap()
	var micro := {
		"batch_us": batch_us,
		"per_settle_us_median": _median_of3(float(batch_us[48]), float(batch_us[96]), float(batch_us[192])),
		"linearity_ratio": _ratio3(batch_us),
		"settles_total": int(snap["settles"]) - int(base["settles"]),
		"planned_total": 336,
		"deferred_total": int(snap["settle_deferred"]) - int(base["settle_deferred"]),
		"separate_drop_total": int(snap["separate_drop"]) - int(base["separate_drop"]),
		"dupe_total": int(snap["dropped_dupe"]) - int(base["dropped_dupe"]),
	}
	print("MICRO%s 回执：批48=%.1fµs/结 批96=%.1fµs/结 批192=%.1fµs/结 | 中位=%.1fµs | 线性比=%.2f（≤3 收）| 结算=%d/%d 顺=%d 弃=%d 复=%d"
		% [p_tag, float(batch_us[48]), float(batch_us[96]), float(batch_us[192]),
		float(micro["per_settle_us_median"]), float(micro["linearity_ratio"]),
		int(micro["settles_total"]), int(micro["planned_total"]),
		int(micro["deferred_total"]), int(micro["separate_drop_total"]),
		int(micro["dupe_total"])])
	return micro


func _micro_ctx(p_source: int, p_target: Enemy, p_frame: int) -> DamageContext:
	# 合成 ctx（r225 同值——base100+1add+2mult+1local+crit0.05，代表负载披露）
	var ctx := DamageContext.make()
	ctx.source_uid = p_source
	ctx.target_uid = p_target.uid
	ctx.target = p_target
	ctx.frame_stamp = p_frame
	ctx.base_atk = MICRO_BASE_ATK
	ctx.crit_chance = 0.05
	ctx.crit_mult = 2.0
	ctx.add_entries.append({"trait_id": &"AFF_SYN", "pool_id": &"r232_syn",
		"layer": 1, "contrib": 0.15, "decay_delta": 0.0, "is_curse": false})
	ctx.mult_pools.append({"pool_id": &"r232_a", "source_uid": p_source,
		"contrib": 0.5, "cap_pool": 2.0, "priority": 0})
	ctx.mult_pools.append({"pool_id": &"vuln", "source_uid": 0,
		"contrib": 0.25, "cap_pool": 1.0, "priority": 0})
	ctx.local_pools.append({"local_id": &"r232_l", "contrib": 0.2, "cap_local": 1.0})
	ctx.pos = p_target.global_position
	return ctx


# ── FULL 臂（真 12 词条运行栈+遗物；窗=①ctx构建+②预聚合+④resolve；ON_HIT 派发裁剪） ──

func _arm_full(p_tag: String, _p_expect_precache: bool) -> Dictionary:
	print("── FULL 臂%s（真12词条运行栈+遗物；窗=①+②+④；ON_HIT 派发=直调链裁剪） ──" % p_tag)
	return _arm_full_impl(p_tag, _proj, FULL_BATCH)


func _arm_full_m(p_tag: String) -> Dictionary:
	print("── FULL-M 臂%s（+MULT×4 词条夹具——② 段主体上界） ──" % p_tag)
	return _arm_full_impl(p_tag + "M", _proj_m, FULLM_BATCH)


func _arm_full_impl(p_tag: String, p_carrier: ProjectileBase, p_batch: int) -> Dictionary:
	DamagePipeline.settle_budget_override = -2
	_pipe.call(&"begin_frame", -1)
	var base := _pipe_snap()
	var frame_no := 940000
	var build_us := 0
	var resolve_us := 0
	var planned := p_batch * FULL_REPS
	var batch_lines := ""
	for rep in range(FULL_REPS):
		var frame := frame_no
		_pipe.call(&"begin_frame", frame)             # 幂等缓存清场（窗外）
		frame_no += 1
		var t_b := Time.get_ticks_usec()
		for i in range(p_batch):
			var tgt := _targets[(rep * p_batch + i) % _targets.size()]
			var t0 := Time.get_ticks_usec()
			var ctx := _full_ctx(p_carrier, 920000 + rep * p_batch + i, tgt, frame)
			var t1 := Time.get_ticks_usec()
			_pipe.call(&"resolve", ctx)
			var t2 := Time.get_ticks_usec()
			build_us += t1 - t0
			resolve_us += t2 - t1
		batch_lines += "批%d=%.1fµs " % [rep, float(Time.get_ticks_usec() - t_b) / float(p_batch)]
		(_pipe.get(&"_resolved_queue") as Array).clear()
	var snap := _pipe_snap()
	var per_settle := float(build_us + resolve_us) / float(planned)
	var full := {
		"per_settle_us": per_settle,
		"build_us": float(build_us) / float(planned),
		"resolve_us": float(resolve_us) / float(planned),
		"build_share_pct": float(build_us) / float(build_us + resolve_us) * 100.0,
		"settles_total": int(snap["settles"]) - int(base["settles"]),
		"planned_total": planned,
		"deferred_total": int(snap["settle_deferred"]) - int(base["settle_deferred"]),
		"separate_drop_total": int(snap["separate_drop"]) - int(base["separate_drop"]),
		"dupe_total": int(snap["dropped_dupe"]) - int(base["dropped_dupe"]),
	}
	print("FULL%s 回执：全链=%.1fµs/结（①②构建=%.1fµs 占 %.1f%% · ④resolve=%.1fµs）| 逐批 %s| 结算=%d/%d 顺=%d 弃=%d 复=%d"
		% [p_tag, per_settle, float(full["build_us"]), float(full["build_share_pct"]),
		float(full["resolve_us"]), batch_lines, int(full["settles_total"]), planned,
		int(full["deferred_total"]), int(full["separate_drop_total"]),
		int(full["dupe_total"])])
	return full


func _full_ctx(p_carrier: ProjectileBase, p_source: int, p_target: Enemy, p_frame: int) -> DamageContext:
	# ①+② 直调链（照抄 _submit_hit→_prepare_hit_traits 序，跳过 stack.dispatch(ON_HIT)
	# 一行——AC-1 裁定：boot 栈 ON_HIT 挂钩载体 handle 在探针环境行为 no-op，裁剪只省
	# 时不变计数语义；dispatch 空转成本由 STEP 臂单列披露行）
	var ctx := p_carrier._build_damage_ctx(p_target)
	ctx.source_uid = p_source
	ctx.frame_stamp = p_frame
	var tctx := p_carrier._build_trait_ctx(GameConst.TraitEvent.ON_HIT,
		{"target": p_target, "damage_ctx": ctx})
	ProjectileBase.inject_hit_relic_pools(ctx, p_target, p_carrier.weapon_ref)
	for pool in (p_carrier.trait_stack as TraitStack).collect_mult_pools(tctx):
		ctx.mult_pools.append(pool)
	p_carrier._inject_vuln_pool(ctx, p_target)
	return ctx


# ── CHURN 臂（override=8 直达饱和——顺延/同对累积/维护扫描/冲刷 单项 µs） ──

func _arm_churn(p_tag: String, p_bag: bool) -> Dictionary:
	DamagePipeline.CTX_REUSE = p_bag                 # 袋路径对照（A=存 ctx 原路径）
	print("── CHURN 臂%s（override=%d 强制帽直达饱和；顺延入队/同对累积/帧末维护/冲刷 单项 µs） ──"
		% [p_tag, CHURN_BUDGET])
	DamagePipeline.settle_budget_override = CHURN_BUDGET
	var frame := 960000
	_pipe.call(&"begin_frame", frame)
	var tgt := _targets[0]
	for i in range(CHURN_BUDGET):                     # 耗尽预算（真结算，不入顺延计时）
		_pipe.call(&"resolve", _plain_ctx(930000 + i, tgt, frame, 5.0))
	# ① 顺延入队：CHURN_PAIRS 对 unique source → 全部顺延
	var defer_ctxs: Array[DamageContext] = []
	for i in range(CHURN_PAIRS):
		defer_ctxs.append(_plain_ctx(931000 + i, tgt, frame, 5.0))
	var t0 := Time.get_ticks_usec()
	for c in defer_ctxs:
		_pipe.call(&"resolve", c)
	var defer_us := float(Time.get_ticks_usec() - t0) / float(CHURN_PAIRS)
	# ② 同对累积：同 pair（同 source）异帧逐次并入（幂等键含帧号→不走占位折返）
	var frame2 := frame
	var merge_ctxs: Array[DamageContext] = []
	for i in range(CHURN_MERGE_PER_PAIR):
		frame2 += 1
		merge_ctxs.append(_plain_ctx(931000, tgt, frame2, 5.0))
	t0 = Time.get_ticks_usec()
	for c in merge_ctxs:
		_pipe.call(&"resolve", c)
	var merge_us := float(Time.get_ticks_usec() - t0) / float(CHURN_MERGE_PER_PAIR)
	# ③ 帧末维护扫描（帧龄 0 → 纯扫描零强冲；重复 10 次取均摊）
	t0 = Time.get_ticks_usec()
	for i in range(10):
		_pipe.call(&"_end_frame_pending_maintenance")
	var scan_us := float(Time.get_ticks_usec() - t0) / 10.0 / float(CHURN_PAIRS)
	# ④ 冲刷：门关（override=-2）→ begin_frame 全量冲刷（含袋→ctx 重建+真结算）
	DamagePipeline.settle_budget_override = -2
	var flush_base := int((_pipe.call(&"stats") as Dictionary).get("settle_flush", 0))
	t0 = Time.get_ticks_usec()
	_pipe.call(&"begin_frame", frame2 + 1)
	var flush_us := (float(Time.get_ticks_usec() - t0)
		/ maxf(float(int((_pipe.call(&"stats") as Dictionary).get("settle_flush", 0)) - flush_base), 1.0))
	DamagePipeline.settle_budget_override = -1
	(_pipe.get(&"_resolved_queue") as Array).clear()
	var churn := {
		"bag": p_bag, "cap": CHURN_BUDGET, "pairs": CHURN_PAIRS,
		"defer_us_per": defer_us, "merge_us_per": merge_us,
		"scan_us_per_entry": scan_us, "flush_us_per": flush_us,
	}
	print("CHURN%s 回执：顺延入队=%.3fµs/项 同对累积=%.3fµs/次 帧末维护扫描=%.4fµs/项（%d 项） 门关全量冲刷=%.3fµs/项"
		% [p_tag.substr(0, 1), defer_us, merge_us, scan_us, CHURN_PAIRS, flush_us])
	return churn


func _plain_ctx(p_source: int, p_target: Enemy, p_frame: int, p_base: float) -> DamageContext:
	var ctx := DamageContext.make()
	ctx.source_uid = p_source
	ctx.target_uid = p_target.uid
	ctx.target = p_target
	ctx.frame_stamp = p_frame
	ctx.base_atk = p_base
	ctx.crit_chance = 0.0
	ctx.crit_mult = 2.0
	ctx.add_entries.append({"trait_id": &"AFF_SYN", "pool_id": &"r232_syn",
		"layer": 1, "contrib": 0.1, "decay_delta": 0.0, "is_curse": false})
	ctx.mult_pools.append({"pool_id": &"r232_c", "source_uid": p_source,
		"contrib": 0.5, "cap_pool": 2.0, "priority": 0})
	ctx.pos = p_target.global_position
	return ctx


# ── STEP 臂（resolve 逐段直调复刻打点——只做构成占比） ───────────────

func _arm_step() -> Dictionary:
	print("── STEP 臂（resolve 12 段直调复刻打点 ×%d 结算——占比口径，禁与 MICRO 绝对值对拍） ──"
		% (STEP_BATCH * STEP_BATCHES))
	DamagePipeline.settle_budget_override = -2
	var seg := {}                                    # 段名 → 累计 µs
	var frame_no := 970000
	var planned := STEP_BATCH * STEP_BATCHES
	for rep in range(STEP_BATCHES):
		var frame := frame_no
		_pipe.call(&"begin_frame", frame)
		frame_no += 1
		for i in range(STEP_BATCH):
			var tgt := _targets[(rep * STEP_BATCH + i) % _targets.size()]
			# ①② 窗外（STEP 量 ④ resolve 分段——池/ctx 就绪后打点）
			var ctx := _full_ctx(_proj, 921000 + rep * STEP_BATCH + i, tgt, frame)
			var st: Dictionary = _pipe.get(&"_stats")
			_t(seg, "0_sanitize", func() -> bool: return _pipe.call(&"_sanitize", ctx))
			_t(seg, "1_pregate", func() -> bool: return _step_pregate(ctx))
			_t(seg, "2_stack_audit", func() -> bool: return _step_acquire())
			_t(seg, "3_agg_add", func() -> bool:
				_pipe.call(&"_aggregate_add", ctx, _s_stack)
				return true)
			_t(seg, "4_flat", func() -> bool:
				_pipe.call(&"_apply_flat", ctx, _s_stack)
				return true)
			_t(seg, "5_agg_mults", func() -> bool:
				_pipe.call(&"_aggregate_mults", ctx, _s_stack)
				return true)
			_t(seg, "6_local", func() -> bool:
				_pipe.call(&"_aggregate_local", ctx, _s_stack)
				return true)
			_t(seg, "7_roll_crit", func() -> bool:
				_s_crit = _pipe.call(&"_roll_crit", ctx)
				return true)
			_s_result = DamageResult.new()
			_t(seg, "8_populate", func() -> bool:
				_pipe.call(&"_populate_result", ctx, _s_stack, _s_crit, _s_result)
				return true)
			_t(seg, "9_target_side", func() -> bool:
				_pipe.call(&"_apply_target_side", ctx, _s_stack, _s_result)
				return true)
			_t(seg, "10_finalize", func() -> bool:
				_pipe.call(&"_finalize", ctx, _s_stack, _s_result)
				return true)
			_t(seg, "11_bcast_cache", func() -> bool:
				_pipe.call(&"_broadcast", _s_result)
				_pipe.call(&"_cache_result", ctx, _s_result)
				return true)
			st["settles"] = int(st["settles"]) + 1
		(_pipe.get(&"_resolved_queue") as Array).clear()
	# 子项披露行（单列不并入段——独立读数 %d 次均摊）：
	var sub := {}
	var tgt0 := _targets[0]
	var sub_ctx := _full_ctx(_proj, 999001, tgt0, frame_no)
	_pipe.call(&"_sanitize", sub_ctx)
	_step_acquire()
	_pipe.call(&"_aggregate_add", sub_ctx, _s_stack)
	_pipe.call(&"_apply_flat", sub_ctx, _s_stack)
	_pipe.call(&"_aggregate_mults", sub_ctx, _s_stack)
	_pipe.call(&"_aggregate_local", sub_ctx, _s_stack)
	var tctx0 := _proj._build_trait_ctx(GameConst.TraitEvent.ON_HIT,
		{"target": tgt0, "damage_ctx": sub_ctx})
	tctx0.weapon = null                              # 探针环境 no-op 形态（AC-1 口径）
	for i in range(STEP_SUB_ITERS):
		_t(sub, "sub_breakdown_dict", func() -> bool: return _sub_breakdown(_s_stack))
		_t(sub, "sub_read_resist", func() -> bool: return _pipe.call(&"_read_resist", sub_ctx) >= 0.0)
		_t(sub, "sub_read_vuln", func() -> bool: return _pipe.call(&"_read_status_vuln", sub_ctx) >= 0.0)
		_t(sub, "sub_elem_immune", func() -> bool: return not (tgt0 as Enemy).is_elem_immune(sub_ctx.element))
		_t(sub, "sub_take_result9b", func() -> bool: return _sub_take_result(sub_ctx))
		_t(sub, "sub_dispatch_idle", func() -> bool: return (_proj.trait_stack as TraitStack).dispatch(GameConst.TraitEvent.ON_HIT, tctx0) == false)
	# 汇总表
	var total := 0.0
	for k in seg:
		total += float(seg[k])
	var rows: Array = seg.keys()
	rows.sort()
	_last_step_total_us = total / float(planned)
	print("STEP 表（µs/结 · 占比｜%d 段直调复刻——打点自污染 +3-11%%，只做构成占比）：" % seg.size())
	for k in rows:
		var v := float(seg[k]) / float(planned)
		var pct := v / total * 100.0 if total > 0.0 else 0.0
		print("  %-16s %6.2fµs  %5.1f%%" % [k, v, pct])
	print("  %-16s %6.2fµs  100%%" % ["合计(段和)", _last_step_total_us])
	for k in sub:
		print("  ↳ %-14s %6.3fµs  （子项披露——独立读数不入段和）" % [k, float(sub[k]) / float(STEP_SUB_ITERS)])
	var step := {"segments": {}, "subs": {}, "total_us_per": _last_step_total_us}
	for k in seg:
		step["segments"][k] = float(seg[k]) / float(planned)
	for k in sub:
		step["subs"][k] = float(sub[k]) / float(STEP_SUB_ITERS)
	return step


func _step_pregate(p_ctx: DamageContext) -> bool:
	# ① 幂等 + ② 存活 + R223 预算闸三读（直调复刻——同 resolve 前置闸序）
	var c: DamageResult = _pipe.call(&"_check_idempotent", p_ctx)
	var a: bool = _pipe.call(&"_target_alive", p_ctx)
	var cap: int = DamagePipeline._settle_cap_now()
	return c == null and a and cap <= 0


func _step_acquire() -> bool:
	# 栈借出+audit（_resolve_core 前置段复刻）
	_s_stack = _pipe.call(&"_acquire_stack")
	_s_stack.audit = DamageAudit.new()
	return true


func _sub_breakdown(p_stack: ModifierStack) -> bool:
	# breakdown dict 构建复刻（populate 子项占比披露）
	var bd := {}
	for m: Dictionary in p_stack.resolved_mults:
		bd[m["pool_id"]] = float(m["agg"])
	return true


func _sub_take_result(p_ctx: DamageContext) -> bool:
	# 9b 落 Enemy 侧成本披露（零值结果——final 0 不改 hp，纯调用成本）
	var r0 := DamageResult.new()
	r0.final_value = 0.0
	return _pipe.call(&"_apply_to_target", p_ctx, r0) == false


func _t(p_seg: Dictionary, p_key: String, p_fn: Callable) -> void:
	var t0 := Time.get_ticks_usec()
	p_fn.call()
	p_seg[p_key] = float(p_seg.get(p_key, 0.0)) + float(Time.get_ticks_usec() - t0)


# ── 轮内推导（A/B 改善 + FULL 盲区 + churn 占比输入） ───────────────

func _print_round_derive(p_run: Dictionary) -> void:
	var ma: Dictionary = p_run["micro_a"]
	var mb: Dictionary = p_run["micro_b"]
	var fa: Dictionary = p_run["full_a"]
	var fb: Dictionary = p_run["full_b"]
	var fma: Dictionary = p_run["fullm_a"]
	var fmb: Dictionary = p_run["fullm_b"]
	var micro_a := float(ma["per_settle_us_median"])
	var micro_b := float(mb["per_settle_us_median"])
	print("推导口径（第 %d 轮）：" % int(p_run["round"]))
	print("  MICRO 同进程 A/B：%.1f → %.1f µs/结（改善 %.1f%%）｜r225 档案参照=%.1fµs（跨日披露，非判定）"
		% [micro_a, micro_b, (micro_a - micro_b) / micro_a * 100.0 if micro_a > 0.0 else 0.0, R225_REF_US])
	print("  FULL 同进程 A/B：%.1f → %.1f µs/结（改善 %.1f%%）｜B 盲区（①②构建占比）=%.1f%%"
		% [float(fa["per_settle_us"]), float(fb["per_settle_us"]),
		(float(fa["per_settle_us"]) - float(fb["per_settle_us"])) / float(fa["per_settle_us"]) * 100.0
			if float(fa["per_settle_us"]) > 0.0 else 0.0,
		float(fb["build_share_pct"])])
	print("  FULL-M 同进程 A/B：%.1f → %.1f µs/结（MULT×4 ② 段主体上界）｜B 构建占比=%.1f%%"
		% [float(fma["per_settle_us"]), float(fmb["per_settle_us"]),
		float(fmb["build_share_pct"])])
	var churn_a: Dictionary = p_run["churn_a"]
	var churn_b: Dictionary = p_run["churn_b"]
	var step: Dictionary = p_run["step"]
	print("  CHURN A/B：顺延=%.3f→%.3fµs/项 积累=%.3f→%.3f 维护=%.4f→%.4f 冲刷=%.3f→%.3f（刀2 判据：churn 占结算轴 >5%% 才立刀；B-A 顺延差=%+.3fµs=袋构建代价）"
		% [float(churn_a["defer_us_per"]), float(churn_b["defer_us_per"]),
		float(churn_a["merge_us_per"]), float(churn_b["merge_us_per"]),
		float(churn_a["scan_us_per_entry"]), float(churn_b["scan_us_per_entry"]),
		float(churn_a["flush_us_per"]), float(churn_b["flush_us_per"]),
		float(churn_b["defer_us_per"]) - float(churn_a["defer_us_per"])])


# ── 门（硬门阻塞；披露类 FAIL* 不计数） ─────────────────────────────

func _gates(p_runs: Array[Dictionary]) -> void:
	var g: Dictionary = {}
	var ma := _median_over(p_runs, "micro_a", "per_settle_us_median")
	var mb := _median_over(p_runs, "micro_b", "per_settle_us_median")
	var fa := _median_over(p_runs, "full_a", "per_settle_us")
	var fb := _median_over(p_runs, "full_b", "per_settle_us")
	var purity_ok := true
	var purity_detail := ""
	for run in p_runs:
		for k in ["micro_a", "micro_b", "full_a", "full_b", "fullm_a", "fullm_b"]:
			var arm: Dictionary = run[k]
			if int(arm["settles_total"]) != int(arm["planned_total"]) \
					or int(arm["deferred_total"]) != 0 \
					or int(arm["separate_drop_total"]) != 0 or int(arm["dupe_total"]) != 0:
				purity_ok = false
				purity_detail += "r%d/%s " % [int(run["round"]), k]
	g["G1 两臂×两轮纯结性（结算=计划值 · 顺/弃/复=0——零混入）"] = {
		"ok": purity_ok, "detail": purity_detail if not purity_ok else "全臂纯净"}
	g["G2 MICRO 线性比 ≤3（A 臂）"] = {
		"ok": _lin_max(p_runs, "micro_a") <= 3.0, "detail": "%.2f" % _lin_max(p_runs, "micro_a")}
	g["G3 MICRO 线性比 ≤3（B 臂）"] = {
		"ok": _lin_max(p_runs, "micro_b") <= 3.0, "detail": "%.2f" % _lin_max(p_runs, "micro_b")}
	g["G4 FULL 盲区在量（①②构建占比 ∈(0,100)%%，B 臂均值）"] = {
		"ok": _mean_over(p_runs, "full_b", "build_share_pct") > 0.0
			and _mean_over(p_runs, "full_b", "build_share_pct") < 100.0,
		"detail": "%.1f%%" % _mean_over(p_runs, "full_b", "build_share_pct")}
	g["G5 CHURN 四块量化在走（全部 >0，A/B 双臂）"] = {
		"ok": _churn_last(p_runs, "churn_b", "defer_us_per") > 0.0
			and _churn_last(p_runs, "churn_b", "merge_us_per") > 0.0
			and _churn_last(p_runs, "churn_b", "scan_us_per_entry") > 0.0
			and _churn_last(p_runs, "churn_b", "flush_us_per") > 0.0
			and _churn_last(p_runs, "churn_a", "defer_us_per") > 0.0,
		"detail": "顺A=%.3f 顺B=%.3f 积B=%.3f 扫B=%.4f 冲B=%.3f" % [
			_churn_last(p_runs, "churn_a", "defer_us_per"),
			_churn_last(p_runs, "churn_b", "defer_us_per"),
			_churn_last(p_runs, "churn_b", "merge_us_per"),
			_churn_last(p_runs, "churn_b", "scan_us_per_entry"),
			_churn_last(p_runs, "churn_b", "flush_us_per")]}
	g["G6* MICRO A vs r225 档案 %.1fµs 比率 ∈[0.6,1.6]（跨日 PC 漂移披露——非判定基线）" % R225_REF_US] = {
		"ok": ma / R225_REF_US >= 0.6 and ma / R225_REF_US <= 1.6,
		"detail": "A=%.1f 比率=%.2f" % [ma, ma / R225_REF_US], "disclosed": true}
	g["G7* STEP 段和 vs MICRO B 同量级 ∈[0.4,3.0]（打点自污染带宽披露）"] = {
		"ok": _last_step_total_us >= mb * 0.4 and _last_step_total_us <= mb * 3.0,
		"detail": "STEP 和=%.1fµs MICRO B=%.1fµs" % [_last_step_total_us, mb], "disclosed": true}
	for key in g:
		var e: Dictionary = g[key]
		if bool(e.get("ok", false)):
			print("  PASS | %s（%s）" % [key, String(e["detail"])])
		elif e.has("disclosed"):
			print("  FAIL* | %s（%s）——披露类失配不阻塞" % [key, String(e["detail"])])
		else:
			print("  FAIL | %s（%s）" % [key, String(e["detail"])])
			_fails += 1
	print("A/B 权威对（当日同进程两轮中位）：MICRO %.1f → %.1f µs/结 | FULL %.1f → %.1f µs/结（目标 <25 达成=%s）"
		% [ma, mb, fa, fb, "是" if mb < 25.0 else "否——如实披露"])


func _median_over(p_runs: Array[Dictionary], p_arm: String, p_key: String) -> float:
	var vals: Array[float] = []
	for run in p_runs:
		vals.append(float((run[p_arm] as Dictionary)[p_key]))
	return _median(vals)


func _mean_over(p_runs: Array[Dictionary], p_arm: String, p_key: String) -> float:
	var vals: Array[float] = []
	for run in p_runs:
		vals.append(float((run[p_arm] as Dictionary)[p_key]))
	return _mean(vals)


func _lin_max(p_runs: Array[Dictionary], p_arm: String) -> float:
	var worst := 0.0
	for run in p_runs:
		worst = maxf(worst, float((run[p_arm] as Dictionary)["linearity_ratio"]))
	return worst


func _churn_last(p_runs: Array[Dictionary], p_arm: String, p_key: String) -> float:
	if p_runs.is_empty():
		return 0.0
	return float((p_runs[p_runs.size() - 1][p_arm] as Dictionary)[p_key])


# ── 基线 JSON（runs[] 同日累积最近两轮；跨代轮转 _prev1 只留一代） ──

func _pipe_snap() -> Dictionary:
	var st: Dictionary = _pipe.call(&"stats")
	var keys := ["settles", "settle_deferred", "settle_flush", "separate_drop", "dropped_dupe"]
	var snap := {}
	for k in keys:
		snap[k] = int(st.get(k, 0))
	return snap


func _store_json(p_runs: Array[Dictionary]) -> void:
	var today := Time.get_date_string_from_system()
	_rotate_baseline(today)
	var root: Dictionary = {}
	var text := FileAccess.get_file_as_string(BASELINE_JSON)
	if not text.is_empty():
		var parsed: Variant = JSON.parse_string(text)
		if parsed is Dictionary:
			root = parsed
	var runs: Array = root.get("runs", [])
	for run in p_runs:
		runs.append(run.duplicate(true))
	while runs.size() > ROUNDS:
		runs.pop_front()
	root["runs"] = runs
	root["meta"] = {
		"date": today,
		"package": "desktop-headless-probe（R232 结算链瘦身 刀0 四臂——STEP/FULL/CHURN/MICRO）",
		"boot": "W2_gatling L5 + PIERCE×3/MULTI×2/BOUNCE×3/NOVA×2/FRACTAL×2（r225 同指纹）+ 遗物 GLASS_CANNON/BOSS_TROPHY + FULL-M 变体 MULT×4",
		"ab": "同进程开关双臂：A=CTX_REUSE/TRAIT_PRECACHE off（改前路径）· B=on（现行刀路径；刀1e AGG_TYPED 收口实测反向 shipped=false，typed 留档）——AC-P1/P2 判定只对同轮 A/B",
		"full_scope": "窗=①ctx构建+②词条预聚合（relic+collect_mult_pools+vuln）+④resolve；ON_HIT 效果派发=直调链裁剪（AC-1），dispatch 空转由 STEP sub 行披露",
		"step_note": "STEP 12 段直调复刻打点——只做构成占比，禁与 MICRO 绝对值对拍（打点自污染 +3-11%）",
		"settle_probe_note": "SETTLE_PROBE=T1b 结算段计时包在 resolve 内——A/B 两臂同付常数开销（<0.1µs/结），披露",
		"rounds": ROUNDS,
	}
	root["disclosure"] = [
		"MICRO 合成 ctx 为代表负载（base100+1add+2mult+1local+crit0.05）——池数相关 ⑤ 聚合成本低估（R7），FULL/FULL-M 为盲区权威",
		"boot12 栈 MULT 子集=0（MULTI=ADD 池）——FULL-M（MULT×4 真值条件）补 ② 段主体上界",
		"FULL 臂 ON_HIT 派发裁剪：boot 栈挂钩载体 handle 在 tctx.weapon=null 形态行为 no-op——裁剪只省时不改计数；dispatch 空转见 STEP sub_dispatch_idle",
		"MICRO A 臂含 T2 刀1a typed 清扫（无运行期开关，设计如此）——T2 收益在 A/B 两臂共同基线，历史对照=50.1µs r225 档案（跨日披露门 G6*）",
		"CHURN 臂 A/B 双态测量（A=存 ctx 原路径/B=字段袋）——B−A 顺延差=袋构建代价，刀2 判读=现行路径占比；维护扫描为 _end_frame_pending_maintenance 直调（帧龄 0 纯扫描）",
		"臂序平衡：偶数轮 B 先 A 后（首轮实测固定 A→B 序带暖机漂移——MICRO A 虚高 13%）；ms 轴散布 ±30-50%（R224 §四）——结论以中位数与比率轴为准",
		"FULL/MICRO 同轮同进程成对——跨日绝对值不可比（R231 教训）；ms 轴桌面≠真机",
	]
	var f := FileAccess.open(BASELINE_JSON, FileAccess.WRITE)
	if f == null:
		push_warning("[probe] 基线 JSON 写入失败：%s" % BASELINE_JSON)
		return
	f.store_string(JSON.stringify(root, "\t"))
	f.close()
	print("基线 JSON 已写：%s（runs 累积 %d 轮）" % [BASELINE_JSON, runs.size()])


func _rotate_baseline(p_today: String) -> void:
	if not FileAccess.file_exists(BASELINE_JSON):
		return
	var text := FileAccess.get_file_as_string(BASELINE_JSON)
	if text.is_empty():
		return
	var parsed: Variant = JSON.parse_string(text)
	if parsed is Dictionary:
		var meta: Variant = (parsed as Dictionary).get("meta")
		if meta is Dictionary and String((meta as Dictionary).get("date", "")) == p_today:
			return
	var fw := FileAccess.open(BASELINE_JSON.get_base_dir()
		+ "/probe_r232_knife_baseline_prev1.json", FileAccess.WRITE)
	if fw != null:
		fw.store_string(text)
		fw.close()


# ── 统计工具 ───────────────────────────────────────────────────────

func _median(p_arr: Array[float]) -> float:
	if p_arr.is_empty():
		return 0.0
	var s := p_arr.duplicate()
	s.sort()
	var mid := s.size() / 2
	if s.size() % 2 == 1:
		return s[mid]
	return (s[mid - 1] + s[mid]) / 2.0


func _median_of3(p_a: float, p_b: float, p_c: float) -> float:
	var arr: Array[float] = [p_a, p_b, p_c]
	return _median(arr)


func _mean(p_arr: Array[float]) -> float:
	if p_arr.is_empty():
		return 0.0
	var s := 0.0
	for v in p_arr:
		s += v
	return s / float(p_arr.size())


func _ratio3(p_batch_us: Dictionary) -> float:
	var vals: Array[float] = []
	for k in p_batch_us:
		vals.append(float(p_batch_us[k]))
	if vals.is_empty():
		return 0.0
	var lo := vals[0]
	var hi := vals[0]
	for v in vals:
		lo = minf(lo, v)
		hi = maxf(hi, v)
	return hi / lo if lo > 0.0 else 0.0


# ── 收尾 ───────────────────────────────────────────────────────────

func _teardown() -> void:
	DamagePipeline.settle_budget_override = -1
	DamagePipeline.CTX_REUSE = true
	TraitStack.TRAIT_PRECACHE = true
	ModifierStack.AGG_TYPED = false
	var epool := _gl.pools[&"enemy"] as EnemyPool
	for e in _targets:
		if is_instance_valid(e):
			epool.release(e)                 # 探针敌未注册 ElementalSystem——直接归池
	_targets.clear()
	var ppool := _gl.pools[&"projectile"] as ProjectilePool
	for p in [_proj, _proj_m]:
		if p != null and is_instance_valid(p):
			ppool.release(p)
	PerfGovernor.mode_override = -1
	PerfGovernor.tier_override = -1
	PerfGovernor.set_process(true)
	if _gl != null:
		_gl.queue_free()
		await tree.process_frame
		await tree.process_frame

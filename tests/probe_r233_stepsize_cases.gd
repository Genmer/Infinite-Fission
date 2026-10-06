# tests/probe_r233_stepsize_cases.gd（R233 T8 步长 A/B 配对探针用例体——入口运行时加载）
# 夹具口径（probe_r224_deepload_cases 同构——深载复现基准全量沿用，差异逐条声明）：
# · 构筑/场景：world_grove 波表 index==16 平铺池、敌 120 驻场（HOLD 顶 MAX_ONSCREEN 闸）、
#   W2_gatling L5 + 五词条满叠（PIERCE×3/MULTI×2/BOUNCE×3/NOVA×2/FRACTAL×2，无棱镜）、
#   敌血 ×0.3 定标复本、xp_need/max_hp 1e12 防开窗保命、玩家风筝（慢速小环）。
#   种子 20261003（r224 同口径）；每臂重播种=两臂出生位轨迹成对（RNG 流跨臂不共享）。
# · A/B 双臂（同进程当日，性能结论同进程纪律）：
#   A 臂 dt=1/60（现状步长）×（300 预热+3600 测量=60s sim），override=-3 哨兵
#     （tier_override=2 帧率优先 → 帽 96=现状 tier2）；
#   B 臂 dt=1/30（目标步长）×（150 预热+1800 测量=60s sim），override=192 强制帽
#     （帽重标目标态 tier2=192；T3 选表未实施——settle_budget_override≥0 现网可测口
#     注入，const 帽 48/96 未动）。headless 手动驱动 _physics_process(dt)，零依赖
#     Engine.physics_ticks_per_second（电池口径零扰动；引擎物理/Area2D 侧差分不在窗内）。
# · C(/D) 臂（中载段界定标——AC-1 拆段段界依据，追加任务）：敌 60（/90 条件二分）
#   驻场，其余全同 B 臂（dt=1/30 帽192/种子/60s sim/稳态窗剔前 20s/补位 16/步）。
#   判读：C p95≤34ms → 补 D=敌90 二分（≤34=段界 90-120；>34=段界 60-90）；
#   C p95>34 → 段界在敌 60 以下不跑 D。结论口径=「敌≤N 时 30Hz 模拟满频（桌面
#   口径），真机按 1.2-2.2 系数对账」。
# · 每模拟秒流程语义对齐（两臂同流程的关键换算）：
#   - 风筝角速度按模拟秒驱动（ang=sim_t×0.35——r224 frame×0.35/60 的时基化）；
#   - 补位节流按步长放大（A=8/步、B=16/步——8×60=16×30=480/s 上限同款节流语义）；
#   - 其余全部 dt 驱动（波次/分离/吸收/武器冷却），每模拟秒工作量天然对齐。
# · 测量窗：整步墙钟=单次 _physics_process(dt) 调用耗时（含全部管线段；风筝/补位/
#   计时读数在窗外）；结算轴=pipeline.settle_us_total() 逐步差分（R232 T1b 累计口，
#   R233 T0 已修双消费）；弹段=stage_probe grid_projectile（结算轴含于其内——
#   弹段净=grid_projectile−结算轴）；每秒差分=结N/提交量（结+顺+弃）/顺N/弃N/
#   派发顺延/派发丢弃/敌/弹/跳字/快N。稳态窗=测量窗剔除前 20s sim（预热尾流清干净）。
# · 已知失配披露（B 臂帧数语义参数未随 30Hz 联动——T3 未实施，探针只读不注入）：
#   ① SETTLE_STALE_FRAME=12 帧@30Hz=0.4s sim（目标态 6 帧=0.2s）——非饱和态顺延少，
#     触发面窄；② DISPATCH_FRAME_CAP=48/步@30Hz=1440/s（目标态 96/步=2880/s）——
#     B 臂派发钳制使 ui/跳字轴步耗低于目标态（判读方向：B 步耗偏乐观，量化见
#     dispatch_deferred/stale_drop 每秒读数）；③ 引擎物理侧 30Hz 换算（Area2D 同步/
#     物理服务器）headless 手动驱动不可测——归 vc38 真机（分析 Q2 边界声明）。
# · 判读口径：B 臂步耗 vs A 臂 ×2（等时工作量对比——30Hz 每步做两倍模拟量）：
#   B≈2A=管线对 dt 线性、预算贴边定案；B<2A=固定开销摊薄有富余；B>2A=非线性恶化
#   须下修帽值。门禁：B 臂稳态窗整步墙钟 p95 ≤ 34ms（分析 Q2/AC-1 步耗条款）——
#   只产数据不拍板，帽值由主控按门禁+分析 Q4 表定案。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const GROVE_TABLE := "res://resources/maps/wave_table_grove.tres"
const SEED := 20261003                  # r224 同种子同口径
const DT60 := 1.0 / 60.0
const DT30 := 1.0 / 30.0
const HOLD := 120                       # 驻场敌数（vc29/vc30 深载段常驻值）
const WARMUP_A := 300                   # 5s：加特林 spin_up 2s + 弹/结算/死亡稳态
const MEASURE_A := 3600                 # 60s@60Hz（任务下限 ≥60s/臂）
const WARMUP_B := 150                   # 5s sim（同 WARMUP_A 时长）
const MEASURE_B := 1800                 # 60s@30Hz
const TOPUP_A := 8                      # SPAWN_PER_FRAME 同款补位节流（480/s 上限）
const TOPUP_B := 16                     # 步长放大换算（每模拟秒节流语义对齐）
const STEADY_SKIP_A := 1200             # 稳态窗=测量窗剔除前 20s sim
const STEADY_SKIP_B := 600
const PLAYER_HOME := Vector2(360.0, 900.0)
const ENEMY_HP_SCALE := 0.3             # r224 同款击杀率×密度联合定标旋钮
const CAP_A := -3                       # -3 哨兵=tier_override2 帧率优先 → 帽96（现状）
const CAP_B := 192                      # 目标态帽（override≥0 现网可测口强制注入）
const BUDGET_MS := 34.0                 # 门禁：B 臂稳态窗整步墙钟 p95（分析 Q2）
const FLUSH_EVERY := 300                # 引擎冲刷点间隔（步）——MessageQueue 防打满（头注）
# C/D 臂（中载段界定标——AC-1 拆段段界依据）：敌 60/90 驻场、其余全同 B 臂
# （dt=1/30 帽192 / 种子 / 60s sim / 稳态窗剔前 20s / 补位 16/步）。
# 判读：C 臂 p95≤34ms → 段界在 60-120（可补敌 90 二分）；>34ms → 段界在 60 以下。
const HOLD_C := 60
const HOLD_D := 90
const WARMUP_C := 150                   # 5s sim（同 B 臂）
const MEASURE_C := 1800                 # 60s@30Hz
const STEADY_SKIP_C := 600
const TOPUP_C := 16
const JSON_PATH := "res://docs/qa/probe_r233_stepsize_2026-10-05.json"

var tree: SceneTree
var _gl: GameLoop = null
var _pipe: DamagePipeline = null
var _fails: int = 0
var _comp: Array[Dictionary] = []       # 平铺构成池 {data: EnemyData, tags: int}
var _cursor: int = 0
var _spawned_total: int = 0
var _alive_at_reset: int = 0
var _hold: int = HOLD                   # 本臂驻场敌数（A/B=120；C=60；D=90——臂内参数化）
var _gate_results: Dictionary = {}      # 门读数（入 JSON——档案可复核）
# 每秒差分基线（臂内逐秒推进——差分口径与 game_loop diag 同语义）
var _sec_base_pipe: int = 0
var _sec_base_stats: Dictionary = {}
var _sec_base_dd: int = 0
var _sec_base_ds: int = 0


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(SEED)
	_gate_results.clear()
	print("══ R233 T8 步长 A/B/C(/D) 配对探针：A=dt1/60 帽96 敌120 vs B=dt1/30 帽192 敌120 vs C=dt1/30 帽192 敌60（+D=敌90 条件二分）× 各 60s sim ══")
	if not _boot():
		_teardown()
		return
	var arm_a := await _arm_core("A", DT60, WARMUP_A, MEASURE_A, TOPUP_A, CAP_A, STEADY_SKIP_A, 96, HOLD)
	_clear_field()
	var arm_b := await _arm_core("B", DT30, WARMUP_B, MEASURE_B, TOPUP_B, CAP_B, STEADY_SKIP_B, CAP_B, HOLD)
	_clear_field()
	var arm_c := await _arm_core("C", DT30, WARMUP_C, MEASURE_C, TOPUP_C, CAP_B, STEADY_SKIP_C, CAP_B, HOLD_C)
	# 段界二分（任务书：C p95≤34 → 补敌 90 快速二分；>34 → 段界在 60 以下不跑 D）
	var arm_d: Dictionary = {}
	var c_p95 := float((arm_c["wall_steady"] as Dictionary)["p95"])
	if c_p95 <= BUDGET_MS:
		_clear_field()
		arm_d = await _arm_core("D", DT30, WARMUP_C, MEASURE_C, TOPUP_C, CAP_B, STEADY_SKIP_C, CAP_B, HOLD_D)
	var run := {"arm_a": arm_a, "arm_b": arm_b, "arm_c": arm_c}
	if not arm_d.is_empty():
		run["arm_d"] = arm_d
	_cross_reading(arm_a, arm_b)          # B vs 2A 线性判读（补写 linear_ratio 字段）
	_boundary_reading(arm_c, arm_d)
	_gates(arm_a, arm_b, arm_c, arm_d)
	_store_json(run)
	_teardown()


func fail_count() -> int:
	return _fails


# ── 引导（r224 _boot 同构）─────────────────────────────────────────

func _boot() -> bool:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "ProbeR233Stepsize"
	tree.root.add_child(_gl)
	if not (_gl.boot_ready and _gl.state == GameConst.GameStatus.MENU):
		push_error("[probe] Boot 失败：%s" % str(_gl.boot_fatal))
		_fails += 1
		return false
	# 调速器冻结：采样停 + 档位注入钉 tier2 帧率优先（r224 同款）
	PerfGovernor.set_process(false)
	PerfGovernor.mode_override = 0
	PerfGovernor.tier_override = 2
	_gl.current_map_id = &"world_grove"
	if not _gl.start_run():
		push_error("[probe] start_run 失败")
		_fails += 1
		return false
	_gl.player.set("xp_need", 1.0e12)
	_gl.player.set("max_hp", 1.0e12)
	_gl.player.set("hp", 1.0e12)
	_gl.player.unlocked_slots = 6
	_gl.player.global_position = PLAYER_HOME
	var gatling: WeaponBase = _gl.player.add_weapon(_gl.registry.get_weapon(&"W2_gatling"))
	if gatling == null:
		push_error("[probe] W2 加特林装配失败")
		_fails += 1
		return false
	gatling.level = 5
	var ok := 0
	for spec in [[&"AFF_PIERCE", 3], [&"AFF_MULTI", 2], [&"MEC_BOUNCE", 3],
			[&"MEC_KILL_BLAST", 2], [&"MEC_FRACTAL", 2]]:
		var trd: TraitData = _gl.registry.get_trait(spec[0])
		for i in range(int(spec[1])):
			if gatling.attach_trait(trd):
				ok += 1
	print("boot.词条挂载回执：%d/12（PIERCE×3 MULTI×2 BOUNCE×3 NOVA×2 FRACTAL×2——r224 同指纹）" % ok)
	if _gl.player.mirror_count() != 0:
		push_error("[probe] 镜面数 %d ≠ 0（夹具异常）" % _gl.player.mirror_count())
		_fails += 1
		return false
	_gl.stage_probe_enabled = true
	_pipe = _gl.pipeline
	if not _load_composition():
		return false
	print("boot：grove w16 构成 %d 敌种池压血×%.2f；构筑=W2 L5 五词条（无棱镜）+ 风筝；种子=%d（每臂重播种）"
		% [_comp.size(), ENEMY_HP_SCALE, SEED])
	return true


func _load_composition() -> bool:
	var tbl: Resource = load(GROVE_TABLE)
	if tbl == null or not ("entries" in tbl):
		push_error("[probe] 波表加载失败：%s" % GROVE_TABLE)
		_fails += 1
		return false
	var entry: Resource = null
	for e in tbl.get("entries"):
		if int(e.get("index")) == 16:
			entry = e
			break
	if entry == null:
		push_error("[probe] grove 波表无 index==16 条目")
		_fails += 1
		return false
	for c in entry.get("composition"):
		var src: EnemyData = _gl.registry.get_enemy(StringName(c.get("enemy_id")))
		if src == null:
			push_error("[probe] 敌数据缺失：%s" % str(c.get("enemy_id")))
			_fails += 1
			return false
		var data: EnemyData = src.duplicate()
		data.hp_base = data.hp_base * ENEMY_HP_SCALE
		var tags := int(c.get("tags", 0))
		for i in range(int(c.get("count", 1))):
			_comp.append({"data": data, "tags": tags})
	_comp.shuffle()
	return true


# ── 驻场补位/风筝（时基化——每模拟秒语义两臂对齐）──────────────────

func _kite_t(p_sim_t: float) -> void:
	# r224 风筝轨迹的时基化：ang=sim_t×0.35（原 frame×0.35/60 在 60Hz 等价）
	var ang := p_sim_t * 0.35
	_gl.player.global_position = Vector2(360.0 + cos(ang) * 140.0,
		660.0 + sin(ang) * 200.0)


func _spawn_one() -> void:
	var c: Dictionary = _comp[_cursor % _comp.size()]
	_cursor += 1
	var e := (_gl.pools[&"enemy"] as EnemyPool).acquire() as Enemy
	if e == null:
		return
	e.bucket_host = (_gl.pools[&"enemy"] as EnemyPool).bucket_host
	e.spawn(c["data"], 16, int(c["tags"]))
	e.global_position = Vector2(randf() * 680.0 + 20.0, randf() * 1180.0 + 40.0)
	_gl.spawner.active.append(e)
	_spawned_total += 1


func _topup(p_per_step: int) -> void:
	var alive: int = _gl.spawner.active.size()
	var want: int = mini(p_per_step, _hold - alive)
	for i in range(want):
		_spawn_one()


func _kill_count() -> int:
	return _spawned_total + _alive_at_reset - _gl.spawner.active.size()


# ── 单臂测量 ───────────────────────────────────────────────────────

func _arm_core(p_id: String, p_dt: float, p_warmup: int, p_measure: int,
		p_topup: int, p_override: int, p_steady_skip: int, p_cap_note: int,
		p_hold: int) -> Dictionary:
	_hold = p_hold
	print("── %s 臂 dt=1/%d 帽%d（override=%d）敌%d 驻场：%d 预热+%d 测量（%ds sim）──"
		% [p_id, int(round(1.0 / p_dt)), p_cap_note, p_override, p_hold, p_warmup, p_measure,
		int(round(float(p_measure) * p_dt))])
	DamagePipeline.settle_budget_override = p_override
	seed(SEED)                              # 每臂重播种：出生位轨迹两臂成对
	_cursor = 0
	_spawned_total = 0
	_alive_at_reset = 0
	for i in range(_hold):
		_spawn_one()
	var sim_t := 0.0
	for i in range(p_warmup):
		_kite_t(sim_t)
		_gl._physics_process(p_dt)
		_topup(p_topup)
		sim_t += p_dt
	_alive_at_reset = _gl.spawner.active.size()
	_spawned_total = 0
	# 差分基线立位（测量窗每秒读数纯净——首拉返 0 的口径不进测量数据）
	_sec_base_pipe = int(_pipe.settle_us_total())
	_sec_base_stats = _stats_snap()
	_sec_base_dd = DebugStats.get_counter(&"dispatch_deferred")
	_sec_base_ds = DebugStats.get_counter(&"dispatch_stale_drop")
	var base_diag: Dictionary = _gl.diag_counts()          # 丢弃值——仅立 diag 差分基线
	var wall_ms: Array[float] = []          # 整步墙钟 ms/步
	var settle_ms: Array[float] = []        # 结算轴 ms/步（settle_us_total 逐步差分）
	var stage: Dictionary = {}              # String 段名 → Array[float] ms/步
	var per_sec: Array[Dictionary] = []
	var sec_len := int(round(1.0 / p_dt))
	var frame := 0
	while frame < p_measure:
		_kite_t(sim_t)
		var su0: int = int(_pipe.settle_us_total())
		var t0 := Time.get_ticks_usec()
		_gl._physics_process(p_dt)
		var wall_us := Time.get_ticks_usec() - t0
		var settle_us := int(_pipe.settle_us_total()) - su0
		_topup(p_topup)
		wall_ms.append(float(wall_us) / 1000.0)
		settle_ms.append(float(settle_us) / 1000.0)
		for k in _gl.stage_probe_us:
			var ks := String(k)
			if not stage.has(ks):
				stage[ks] = [] as Array[float]
			(stage[ks] as Array[float]).append(float(_gl.stage_probe_us[k]) / 1000.0)
		sim_t += p_dt
		frame += 1
		if frame % sec_len == 0:
			per_sec.append(_sec_sample(sec_len))
		# 引擎冲刷点（每 300 步≈5s sim——紧循环无引擎迭代时 MessageQueue 无限累积，
		# 首跑实证 8192 页打满→自动 flush 撞已释放对象回调→signal 11；await 在计时
		# 窗外，逐步墙钟口径不受污染。代价=引擎迭代自驱 ≤8 步 dt=1/120（headless
		# physics_ticks_per_second=120 + max_physics_steps_per_frame=8 帽）≈+1/15s
		# sim/次——两臂同付、量级披露）
		if frame % FLUSH_EVERY == 0:
			print("  …%s 臂 %d/%d 步（sim_t=%.0fs，最近步 %.1fms）" % [p_id, frame,
				p_measure, sim_t, float(wall_us) / 1000.0])
			await tree.process_frame
	var arm := {
		"id": p_id,
		"dt": p_dt,
		"hold_enemies": p_hold,
		"warmup_frames": p_warmup,
		"measure_frames": p_measure,
		"sim_seconds": float(p_measure) * p_dt,
		"settle_override": p_override,
		"cap_effective": p_cap_note,
		"topup_per_step": p_topup,
		"steady_skip_frames": p_steady_skip,
		"wall_full": _series_stats(wall_ms, 0),
		"wall_steady": _series_stats(wall_ms, p_steady_skip),
		"settle_axis_full": _series_stats(settle_ms, 0),
		"settle_axis_steady": _series_stats(settle_ms, p_steady_skip),
		"segments_steady_ms": _stage_stats(stage, p_steady_skip),
		"per_sec": per_sec,
		"killed_in_window": _kill_count(),
	}
	# 丢弃 per_sec 尾部快照进摘要（全量留 per_sec 键）
	var tail: Array = per_sec.slice(maxi(0, per_sec.size() - 5))
	arm["per_sec_tail"] = tail
	_report(arm, base_diag)
	return arm


func _stats_snap() -> Dictionary:
	var st: Dictionary = _pipe.call(&"stats")
	var keys := ["settles", "settle_deferred", "settle_flush", "settle_flush_dead",
		"settle_flush_reuse", "settle_overload_drop", "settle_stale_flush", "separate_drop"]
	var snap := {}
	for k in keys:
		snap[k] = int(st.get(k, 0))
	return snap


func _sec_sample(p_steps_s: int) -> Dictionary:
	# 每模拟秒一拉（差分自基线→拉完基线前移——同 r224 per_sec 口径）
	var d: Dictionary = _gl.diag_counts()
	var ps := _stats_snap()
	var settle_us_s := int(_pipe.settle_us_total()) - _sec_base_pipe
	var dd := DebugStats.get_counter(&"dispatch_deferred") - _sec_base_dd
	var ds := DebugStats.get_counter(&"dispatch_stale_drop") - _sec_base_ds
	var stale_flush := int(ps["settle_stale_flush"]) - int(_sec_base_stats["settle_stale_flush"])
	var settle_n := int(d[&"settles"])
	var defer_n := int(d[&"settles_deferred"])
	var drop_n := int(d[&"settles_dropped"])
	var s := {
		"settles": settle_n,
		"submissions": settle_n + defer_n + drop_n,
		"deferred": defer_n,
		"dropped": drop_n,
		"flushed": int(d[&"settles_flushed"]),
		"settle_axis_ms_per_step": float(settle_us_s) / 1000.0 / float(p_steps_s),
		"settle_us_per": int(d[&"settle_us_per"]),
		"settle_stale_flush": stale_flush,
		"dispatch_deferred": dd,
		"dispatch_stale_drop": ds,
		"projectiles": int(d[&"projectiles"]),
		"enemies": int(d[&"enemies"]),
		"popups": int(d[&"popups"]),
		"pfast_live": int(d[&"pfast_live"]),
	}
	_sec_base_pipe = int(_pipe.settle_us_total())
	_sec_base_stats = ps
	_sec_base_dd += dd
	_sec_base_ds += ds
	return s


# ── 单臂报告 ───────────────────────────────────────────────────────

func _report(p_arm: Dictionary, _p_base_diag: Dictionary) -> void:
	var wfull: Dictionary = p_arm["wall_full"]
	var wstd: Dictionary = p_arm["wall_steady"]
	var sstd: Dictionary = p_arm["settle_axis_steady"]
	print("%s 臂整步墙钟 ms：全窗 p50=%.2f p95=%.2f p99=%.2f | 稳态窗 p50=%.2f p95=%.2f p99=%.2f（样本 %d）"
		% [p_arm["id"], float(wfull["p50"]), float(wfull["p95"]), float(wfull["p99"]),
		float(wstd["p50"]), float(wstd["p95"]), float(wstd["p99"]), int(wstd["n"])])
	print("%s 臂结算轴 ms/步：稳态窗 p50=%.2f p95=%.2f（占步耗 p50 %.1f%%）"
		% [p_arm["id"], float(sstd["p50"]), float(sstd["p95"]),
		float(sstd["p50"]) / maxf(float(wstd["p50"]), 0.001) * 100.0])
	var segs: Dictionary = p_arm["segments_steady_ms"]
	var proj: Dictionary = segs.get("grid_projectile", {"mean": 0.0, "p95": 0.0})
	var net := float(proj["mean"]) - float(sstd["mean"])
	print("%s 臂弹段 grid_projectile 稳态窗 均值=%.2fms p95=%.2fms | 弹段净（−结算轴均值）≈%.2fms"
		% [p_arm["id"], float(proj["mean"]), float(proj["p95"]), net])
	var keys: Array = segs.keys()
	keys.sort()
	var line := ""
	for k in keys:
		var seg: Dictionary = segs[k]
		line += "%s=%.2f/%.2f " % [String(k), float(seg["mean"]), float(seg["p95"])]
	print("%s 臂稳态段 均值/P95 ms：%s" % [p_arm["id"], line])
	_sec_report(p_arm)


func _sec_report(p_arm: Dictionary) -> void:
	var per_sec: Array = p_arm["per_sec"]
	if per_sec.is_empty():
		return
	var subs := _sec_col(per_sec, "submissions")
	var settles := _sec_col(per_sec, "settles")
	var defers := _sec_col(per_sec, "deferred")
	var drops := _sec_col(per_sec, "dropped")
	var ddef := _sec_col(per_sec, "dispatch_deferred")
	var ddrop := _sec_col(per_sec, "dispatch_stale_drop")
	var projs := _sec_col(per_sec, "projectiles")
	var enemies := _sec_col(per_sec, "enemies")
	var popups := _sec_col(per_sec, "popups")
	print("%s 臂每秒轴 p50：结N=%.0f 提交=%.0f 顺=%.0f 弃=%.0f（弃max=%.0f）｜派发顺延=%.0f 派发丢弃=%.0f｜敌=%.0f 弹=%.0f 跳字=%.0f 快N=%.0f｜击杀（测量窗）=%d"
		% [p_arm["id"], _p50(settles), _p50(subs), _p50(defers), _p50(drops), _mx(drops),
		_p50(ddef), _p50(ddrop), _p50(enemies), _p50(projs), _p50(popups),
		_p50(_sec_col(per_sec, "pfast_live")), int(p_arm["killed_in_window"])])


func _sec_col(p_per_sec: Array, p_key: String) -> Array[float]:
	var out: Array[float] = []
	for d in p_per_sec:
		out.append(float(int((d as Dictionary)[p_key])))
	out.sort()
	return out


func _p50(p_sorted: Array[float]) -> float:
	return _pct(p_sorted, 0.50)


func _mx(p_sorted: Array[float]) -> float:
	return p_sorted[p_sorted.size() - 1] if not p_sorted.is_empty() else 0.0


# ── 跨臂判读（B vs 2A 线性判定——只产数据不拍板）──────────────────

func _cross_reading(p_a: Dictionary, p_b: Dictionary) -> void:
	var wa: Dictionary = p_a["wall_steady"]
	var wb: Dictionary = p_b["wall_steady"]
	var a_p50 := float(wa["p50"])
	var b_p50 := float(wb["p50"])
	var ratio := b_p50 / maxf(a_p50, 0.001)
	var interp := "B≈2A=管线对 dt 线性、预算贴边定案"
	if ratio < 1.8:
		interp = "B<2A=固定开销摊薄、有富余"
	elif ratio > 2.2:
		interp = "B>2A=非线性恶化、帽值须下修"
	print("判读：B 稳态 p50=%.2fms vs A×2=%.2fms → 比率 B/A=%.2f（%s）"
		% [b_p50, a_p50 * 2.0, ratio, interp])
	var sa: Dictionary = p_a["settle_axis_steady"]
	var sb: Dictionary = p_b["settle_axis_steady"]
	print("结算轴（帽值敏感性主项）：A 稳态 p50=%.2fms（帽96 档）→ B=%.2fms（cap192 档，占步耗 %.1f%%）；结µs均值 A=%.0f B=%.0f"
		% [float(sa["p50"]), float(sb["p50"]),
		float(sb["p50"]) / maxf(float((p_b["wall_steady"] as Dictionary)["p50"]), 0.001) * 100.0,
		_sec_us_mean(p_a), _sec_us_mean(p_b)])
	p_a["linear_ratio_b_over_a"] = ratio
	p_b["linear_ratio_b_over_a"] = ratio
	p_b["linear_reading"] = interp


func _sec_us_mean(p_arm: Dictionary) -> int:
	var per_sec: Array = p_arm["per_sec"]
	var vals := _sec_col(per_sec, "settle_us_per")
	var nz: Array[float] = []
	for v in vals:
		if v > 0.0:
			nz.append(v)
	if nz.is_empty():
		return 0
	return int(_p50(nz))


# ── 中载段界判读（C=敌60，D=敌90 条件二分——AC-1 拆段段界依据）──────

func _boundary_reading(p_c: Dictionary, p_d: Dictionary) -> void:
	var wc: Dictionary = p_c["wall_steady"]
	var c_p50 := float(wc["p50"])
	var c_p95 := float(wc["p95"])
	var c_p99 := float(wc["p99"])
	print("C 臂（敌60 帽192）稳态窗：p50=%.2f p95=%.2f p99=%.2f ms vs 33.3ms 步长预算（门禁带 34ms）"
		% [c_p50, c_p95, c_p99])
	var per_sec_c: Array = p_c["per_sec"]
	print("C 臂每秒轴 p50：结N=%.0f 提交=%.0f 顺=%.0f 弃=%.0f｜敌=%.0f 弹=%.0f 跳字=%.0f｜击杀（测量窗）=%d"
		% [_p50(_sec_col(per_sec_c, "settles")), _p50(_sec_col(per_sec_c, "submissions")),
		_p50(_sec_col(per_sec_c, "deferred")), _p50(_sec_col(per_sec_c, "dropped")),
		_p50(_sec_col(per_sec_c, "enemies")), _p50(_sec_col(per_sec_c, "projectiles")),
		_p50(_sec_col(per_sec_c, "popups")), int(p_c["killed_in_window"])])
	p_c["budget_33ms_pass"] = c_p95 <= 33.3
	if c_p95 > BUDGET_MS:
		p_c["boundary_conclusion"] = "段界在敌 60 以下（敌60 已超 34ms 桌面口径，未跑 D 臂）"
	elif p_d.is_empty():
		p_c["boundary_conclusion"] = "敌≤60 时 30Hz 模拟满频（桌面口径），段界在敌 60-120 之间"
	else:
		var wd: Dictionary = p_d["wall_steady"]
		var d_p50 := float(wd["p50"])
		var d_p95 := float(wd["p95"])
		var d_p99 := float(wd["p99"])
		print("D 臂（敌90 帽192，二分）稳态窗：p50=%.2f p95=%.2f p99=%.2f ms vs 33.3ms（门禁带 34ms）"
			% [d_p50, d_p95, d_p99])
		var per_sec_d: Array = p_d["per_sec"]
		print("D 臂每秒轴 p50：结N=%.0f 提交=%.0f 顺=%.0f 弃=%.0f｜敌=%.0f 弹=%.0f 跳字=%.0f｜击杀（测量窗）=%d"
			% [_p50(_sec_col(per_sec_d, "settles")), _p50(_sec_col(per_sec_d, "submissions")),
			_p50(_sec_col(per_sec_d, "deferred")), _p50(_sec_col(per_sec_d, "dropped")),
			_p50(_sec_col(per_sec_d, "enemies")), _p50(_sec_col(per_sec_d, "projectiles")),
			_p50(_sec_col(per_sec_d, "popups")), int(p_d["killed_in_window"])])
		p_d["budget_33ms_pass"] = d_p95 <= 33.3
		if d_p95 <= BUDGET_MS:
			p_c["boundary_conclusion"] = "敌≤90 时 30Hz 模拟满频（桌面口径），段界在敌 90-120 之间"
		else:
			p_c["boundary_conclusion"] = "敌≤60 时 30Hz 模拟满频（桌面口径），段界在敌 60-90 之间"
	print("段界结论：%s；真机按 1.2-2.2 系数对账（R224 桌面≠真机声明）" % String(p_c["boundary_conclusion"]))


# ── 门（硬门阻塞；披露类 FAIL* 不计数）────────────────────────────

func _gates(p_a: Dictionary, p_b: Dictionary, p_c: Dictionary, p_d: Dictionary) -> void:
	var wb: Dictionary = p_b["wall_steady"]
	var b_p95 := float(wb["p95"])
	var per_sec_b: Array = p_b["per_sec"]
	var subs_b := _p50(_sec_col(per_sec_b, "submissions"))
	var enemies_b := _p50(_sec_col(per_sec_b, "enemies"))
	var wa: Dictionary = p_a["wall_steady"]
	_gate("G1 门禁：B 臂稳态窗整步墙钟 p95 ≤ 34ms（分析 Q2/AC-1 步耗条款）",
		b_p95 <= BUDGET_MS, "%.2f ms" % b_p95)
	_gate("G2 夹具校准：B 臂提交需求 p50 ∈ [2000,6400]/s（vc30 深载带）",
		subs_b >= 2000.0 and subs_b <= 6400.0, "%.0f/s" % subs_b)
	_gate("G3 夹具校准：B 臂敌驻场 p50 ≥ 118（敌120 常驻）", enemies_b >= 118.0,
		"%.0f" % enemies_b)
	_gate("G4 样本齐全：A/B/C 测量窗步数 %d/%d/%d"
		% [int(p_a["measure_frames"]), int(p_b["measure_frames"]), int(p_c["measure_frames"])],
		int((p_a["wall_full"] as Dictionary)["n"]) == int(p_a["measure_frames"])
		and int((p_b["wall_full"] as Dictionary)["n"]) == int(p_b["measure_frames"])
		and int((p_c["wall_full"] as Dictionary)["n"]) == int(p_c["measure_frames"]),
		"A=%d B=%d C=%d" % [int((p_a["wall_full"] as Dictionary)["n"]),
		int((p_b["wall_full"] as Dictionary)["n"]),
		int((p_c["wall_full"] as Dictionary)["n"])])
	_gate("G4b C 臂敌驻场 p50 ≥ 58（敌60 顶闸）",
		_p50(_sec_col(p_c["per_sec"], "enemies")) >= 58.0,
		"%.0f" % _p50(_sec_col(p_c["per_sec"], "enemies")))
	var ratio := float(p_b["linear_ratio_b_over_a"])
	_gate_disclosed("G5* 线性比 B/A=%.2f（2.0=线性；<1.8 摊薄有富余 / >2.2 非线性须下修——判读非门禁）" % ratio,
		ratio >= 1.8 and ratio <= 2.2, "%.2f（%s）" % [ratio, String(p_b["linear_reading"])])
	var ddef_b := _p50(_sec_col(per_sec_b, "dispatch_deferred"))
	_gate_disclosed("G6* B 臂派发帽未联动披露：DISPATCH_FRAME_CAP=48/步@30Hz=1440/s（目标态 96/步）——派发顺延 p50>0 即 ui/跳字轴步耗低于目标态（B 偏乐观方向）",
		ddef_b <= 0.0, "派发顺延 p50=%.0f/s 丢弃 p50=%.0f/s" % [ddef_b,
		_p50(_sec_col(per_sec_b, "dispatch_stale_drop"))])
	var wc: Dictionary = p_c["wall_steady"]
	var c_p95 := float(wc["p95"])
	_gate_disclosed("G7* 段界判读：C 臂（敌60）稳态窗 p95 ≤ 34ms（≤=段界上移 60-120；>=段界在 60 以下——判读非门禁）",
		c_p95 <= BUDGET_MS, "%.2f ms（%s）" % [c_p95, String(p_c["boundary_conclusion"])])
	if not p_d.is_empty():
		var wd: Dictionary = p_d["wall_steady"]
		var d_p95 := float(wd["p95"])
		_gate_disclosed("G8* 段界二分：D 臂（敌90）稳态窗 p95 ≤ 34ms（≤=段界上移 90-120；>=段界在 60-90）",
			d_p95 <= BUDGET_MS, "%.2f ms（%s）" % [d_p95, String(p_c["boundary_conclusion"])])
	_gate("G9 夹具校准：C 臂提交需求 p50 ≤ 3400/s（敌60 中载=约 B 臂一半需求上界，无下带——低需求属被测定义）",
		_p50(_sec_col(p_c["per_sec"], "submissions")) <= 3400.0,
		"%.0f/s" % _p50(_sec_col(p_c["per_sec"], "submissions")))
	print("门禁判定行：B 臂步耗 p95=%.2f ms vs 34ms → %s（帽值由主控按门禁+分析 Q4 表定案，本探针只产数据）"
		% [b_p95, "PASS" if b_p95 <= BUDGET_MS else "FAIL"])
	print("段界判定行：C 臂（敌60）p95=%.2f ms vs 34ms → %s"
		% [c_p95, "满频" if c_p95 <= BUDGET_MS else "超预算"])
	print("对照：A 臂稳态 p95=%.2f ms（60Hz 现状——预算 16.67ms 本就超载=深载复现态，桌面≈真机 ×0.5-2）"
		% float(wa["p95"]))


func _gate(p_label: String, p_ok: bool, p_detail: String) -> void:
	if p_ok:
		print("  PASS | %s（%s）" % [p_label, p_detail])
	else:
		print("  FAIL | %s（%s）" % [p_label, p_detail])
		_fails += 1
	_gate_results[p_label] = {"ok": p_ok, "detail": p_detail}


func _gate_disclosed(p_label: String, p_ok: bool, p_detail: String) -> void:
	if p_ok:
		print("  PASS | %s（%s）" % [p_label, p_detail])
	else:
		print("  FAIL* | %s（%s）——披露类失配不阻塞（详见用例体头注）" % [p_label, p_detail])
	_gate_results[p_label] = {"ok": p_ok, "detail": p_detail, "disclosed": true}


# ── 序列统计 ───────────────────────────────────────────────────────

func _series_stats(p_arr: Array[float], p_skip: int) -> Dictionary:
	var s := p_arr.duplicate()
	s.sort()
	var out := {
		"n": s.size(),
		"p50": _pct(s, 0.50), "p95": _pct(s, 0.95), "p99": _pct(s, 0.99),
		"mean": _mean_st(s), "max": _mx(s),
	}
	if p_skip > 0 and p_skip < s.size():
		var tail := s.slice(p_skip)
		tail.sort()
		out = {
			"n": tail.size(), "skip": p_skip,
			"p50": _pct(tail, 0.50), "p95": _pct(tail, 0.95), "p99": _pct(tail, 0.99),
			"mean": _mean_st(tail), "max": _mx(tail),
		}
	return out


func _stage_stats(p_stage: Dictionary, p_skip: int) -> Dictionary:
	var out := {}
	for k in p_stage:
		var arr: Array[float] = p_stage[k]
		var s := arr.duplicate()
		s.sort()
		if p_skip > 0 and p_skip < s.size():
			s = s.slice(p_skip)
		out[String(k)] = {"mean": _mean_st(s), "p50": _pct(s, 0.50), "p95": _pct(s, 0.95)}
	return out


func _pct(p_sorted: Array[float], p_p: float) -> float:
	if p_sorted.is_empty():
		return 0.0
	var i := clampi(int(float(p_sorted.size()) * p_p), 0, p_sorted.size() - 1)
	return p_sorted[i]


func _mean_st(p_arr: Array[float]) -> float:
	if p_arr.is_empty():
		return 0.0
	var s := 0.0
	for v in p_arr:
		s += v
	return s / float(p_arr.size())


# ── JSON 落档（runs[] 同日累积最近两轮；跨日轮转 _prev1）────────────

func _store_json(p_run: Dictionary) -> void:
	var today := Time.get_date_string_from_system()
	_rotate_if_stale(today)
	var root: Dictionary = {}
	var text := FileAccess.get_file_as_string(JSON_PATH)
	if not text.is_empty():
		var parsed: Variant = JSON.parse_string(text)
		if parsed is Dictionary:
			root = parsed
	var runs: Array = root.get("runs", [])
	runs.append(p_run.duplicate(true))
	while runs.size() > 2:
		runs.pop_front()
	root["runs"] = runs
	root["meta"] = {
		"date": today,
		"package": "desktop-headless-probe（R233 T8 步长 A/B 配对 + C(/D) 中载段界定标——帽值与段界门禁数据）",
		"seed": SEED,
		"map": "world_grove w16（敌血 ×0.3 定标复本）",
		"build": "W2_gatling L5 + AFF_PIERCE×3/AFF_MULTI×2/MEC_BOUNCE×3/MEC_KILL_BLAST×2/MEC_FRACTAL×2（无棱镜/无自导——r224 同指纹）",
		"governor": "frozen, mode=frame_priority, tier_override=2",
		"hold": "A/B=120（深载复现）；C=60、D=90（中载段界二分——其余配置全同 B 臂）",
		"drive": "headless 手动 _physics_process(dt)；不依赖 Engine.physics_ticks_per_second（电池口径零扰动）",
		"flush_points": "每 %d 步一次 await process_frame（计时窗外）——紧循环 MessageQueue 防打满（首跑 8192 页→signal 11 实证）；代价=引擎迭代自驱 ≤8 步 dt=1/120（headless 120Hz+步帽8）≈+1/15s sim/次，各臂同付" % FLUSH_EVERY,
		"arm_a": "dt=1/60 现状步长 ×（300 预热+3600 测量=60s sim）敌120；override=-3 哨兵→帽96（现状 tier2）",
		"arm_b": "dt=1/30 目标步长 ×（150 预热+1800 测量=60s sim）敌120；override=192 强制帽（T3 选表未实施——settle_budget_override≥0 现网可测口；帽 const 48/96 未动）",
		"arm_c": "dt=1/30 帽192 敌60 驻场 ×（150 预热+1800 测量=60s sim）——中载段界定标，其余全同 B 臂",
		"arm_d": "dt=1/30 帽192 敌90 驻场——条件二分臂（仅当 C 臂 p95≤34ms 时跑；缺失=C 未过 34ms 段界在 60 以下）",
		"gate": "B 臂稳态窗（剔前 20s sim）整步墙钟 p95 ≤ 34ms；C/D 臂=段界判读行（≤34ms=该敌数档 30Hz 满频·桌面口径）",
		"settle_axis": "结算轴=pipeline.settle_us_total() 逐步差分（R232 T1b 口，R233 T0 双消费已修）；弹段=stage_probe grid_projectile（结算轴含于内——弹段净=grid_projectile−结算轴）",
		"sim_flow_align": "每模拟秒流程语义各臂对齐：风筝时基化（ang=sim_t×0.35）+ 补位节流步长放大（60Hz=8/步、30Hz=16/步，480/s 上限同款）；每臂重播种 20261003",
		"same_process_note": "本 runs[-1] 轮 A/B/C(/D) 同进程同日跑（性能结论同进程纪律）；runs[0]=同日先行进程的 A/B 轮（首跑留档）——跨进程对读注意进程间漂移（同日披露）",
		"verdict_note": "只产数据不拍板——帽值由主控按门禁+分析 Q4 表（144/192/240 触发条件）定案；段界结论=AC-1 拆段段界依据（桌面口径，真机按 1.2-2.2 系数对账）",
	}
	root["gates"] = _gate_results.duplicate()
	runs = root["runs"]
	var last: Dictionary = runs[runs.size() - 1]
	var b_arm: Dictionary = last["arm_b"]
	var a_arm: Dictionary = last["arm_a"]
	var c_arm: Dictionary = last["arm_c"]
	root["verdict"] = {
		"b_wall_p95_ms": float((b_arm["wall_steady"] as Dictionary)["p95"]),
		"b_wall_p50_ms": float((b_arm["wall_steady"] as Dictionary)["p50"]),
		"b_wall_p99_ms": float((b_arm["wall_steady"] as Dictionary)["p99"]),
		"a_wall_p95_ms": float((a_arm["wall_steady"] as Dictionary)["p95"]),
		"a_wall_p50_ms": float((a_arm["wall_steady"] as Dictionary)["p50"]),
		"a_wall_p99_ms": float((a_arm["wall_steady"] as Dictionary)["p99"]),
		"budget_ms": BUDGET_MS,
		"gate_pass": float((b_arm["wall_steady"] as Dictionary)["p95"]) <= BUDGET_MS,
		"linear_ratio_b_over_a": float(b_arm["linear_ratio_b_over_a"]),
		"linear_reading": String(b_arm["linear_reading"]),
		"settle_axis_share_b_pct": float((b_arm["settle_axis_steady"] as Dictionary)["p50"])
			/ maxf(float((b_arm["wall_steady"] as Dictionary)["p50"]), 0.001) * 100.0,
		"settle_axis_share_a_pct": float((a_arm["settle_axis_steady"] as Dictionary)["p50"])
			/ maxf(float((a_arm["wall_steady"] as Dictionary)["p50"]), 0.001) * 100.0,
		"c_wall_p50_ms": float((c_arm["wall_steady"] as Dictionary)["p50"]),
		"c_wall_p95_ms": float((c_arm["wall_steady"] as Dictionary)["p95"]),
		"c_wall_p99_ms": float((c_arm["wall_steady"] as Dictionary)["p99"]),
		"c_hold_enemies": int(c_arm["hold_enemies"]),
		"c_budget33_pass": bool(c_arm["budget_33ms_pass"]),
		"boundary_conclusion": String(c_arm["boundary_conclusion"]),
	}
	if last.has("arm_d"):
		var d_arm: Dictionary = last["arm_d"]
		root["verdict"]["d_wall_p50_ms"] = float((d_arm["wall_steady"] as Dictionary)["p50"])
		root["verdict"]["d_wall_p95_ms"] = float((d_arm["wall_steady"] as Dictionary)["p95"])
		root["verdict"]["d_wall_p99_ms"] = float((d_arm["wall_steady"] as Dictionary)["p99"])
		root["verdict"]["d_hold_enemies"] = int(d_arm["hold_enemies"])
		root["verdict"]["d_budget33_pass"] = bool(d_arm["budget_33ms_pass"])
	root["disclosure"] = [
		"B 臂帽=192 经 settle_budget_override≥0 强制口注入（T3 帽选表未实施——const 48/96 未动，目标态重标的现网可测口）；A 臂 -3 哨兵=帽96。深载臂（B）帽实测不绑定（需求 < 供给 5760/s，见 per_sec 提交轴）；C/D 臂（敌60/90）需求更低更不绑定",
		"帧数语义参数未随 30Hz 联动（T3 未实施，探针只读不注入）：①SETTLE_STALE_FRAME=12 帧@30Hz=0.4s sim（目标态 6 帧=0.2s，非饱和态触发面窄）；②DISPATCH_FRAME_CAP=48/步=1440/s（目标态 96/步=2880/s）——B(/C/D) 臂派发钳制使 ui/跳字轴步耗低于目标态（判读方向：步耗偏乐观；量化=派发顺延/丢弃每秒读数）",
		"引擎物理侧（Engine.physics_ticks_per_second 30Hz 下的 Area2D 同步/物理服务器成本）headless 手动驱动不在窗内——分析 Q2 引擎补充臂未跑，方向性归 vc38 真机",
		"桌面≠真机 ×0.5-2（R224 声明）：绝对 ms 只做桌面相对比较与门禁粗判，真机终判=vc38 导出日志；段界结论同为桌面口径，真机按 1.2-2.2 系数对账",
		"RNG 分歧披露（r224 同款）：跨臂统计 ±2-10%——击杀/需求轴非严格确定性；每臂重播种使出生轨迹成对但不消弹道 RNG 分歧",
		"30Hz 臂（B/C/D）隧穿未修（T5 swept 未实施）：每步位移 ×2 点检测可漏（最坏 32.6px vs reach 18px 阈 36px）——命中集差异属被测对象本身（dt/敌数敏感性的一部分），并使 30Hz 臂需求偏低（B 臂实测比 A 臂低 ~25%——步耗读数偏乐观方向）",
		"C/D 臂需求校准门为单边上界（≤3400/s）：敌数减半需求自然下降属被测定义本身，不设下带",
		"runs[0]=同日先行进程 A/B 轮（首跑留档）；runs[-1]=本轮 A/B/C(/D) 同进程齐全轮（权威）——同进程纪律只约束本轮内 A/B/C/D 相对判读，跨进程绝对值对读注意进程间漂移",
	]
	var f := FileAccess.open(JSON_PATH, FileAccess.WRITE)
	if f == null:
		push_warning("[probe] JSON 写入失败（docs/qa/ 目录）：%s" % JSON_PATH)
		return
	f.store_string(JSON.stringify(root, "\t"))
	f.close()
	print("JSON 已写：%s（runs 累积 %d 轮）" % [JSON_PATH, runs.size()])


func _rotate_if_stale(p_today: String) -> void:
	if not FileAccess.file_exists(JSON_PATH):
		return
	var text := FileAccess.get_file_as_string(JSON_PATH)
	if text.is_empty():
		return
	var parsed: Variant = JSON.parse_string(text)
	if parsed is Dictionary:
		var meta: Variant = (parsed as Dictionary).get("meta")
		if meta is Dictionary and String((meta as Dictionary).get("date", "")) == p_today:
			return
	var fw := FileAccess.open(JSON_PATH.get_base_dir()
		+ "/probe_r233_stepsize_2026-10-05_prev1.json", FileAccess.WRITE)
	if fw != null:
		fw.store_string(text)
		fw.close()


# ── 清场/收尾（r224 _clear_field 同构）────────────────────────────

func _clear_field() -> void:
	for e in _gl.spawner.active.duplicate():
		_gl.elemental.unregister_host(e)
		(_gl.pools[&"enemy"] as EnemyPool).release(e)
	_gl.spawner.active.clear()
	_gl.spawner.spawn_queue.clear()
	for p in (_gl.pools[&"projectile"] as ProjectilePool).active_projectiles().duplicate():
		(_gl.pools[&"projectile"] as ObjectPool).release(p)
	for s in (_gl.active_shards as Array).duplicate():
		(_gl.pools[&"xp"] as XPPool).release(s)
	_gl.active_shards.clear()


func _teardown() -> void:
	DamagePipeline.settle_budget_override = -1
	PerfGovernor.mode_override = -1
	PerfGovernor.tier_override = -1
	PerfGovernor.set_process(true)
	if _gl != null:
		_gl.queue_free()
		await tree.process_frame
		await tree.process_frame

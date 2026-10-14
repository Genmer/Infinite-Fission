# tests/probe_r225_separation_cases.gd（R225 分离测量用例体——入口运行时加载）
# 复现口径（r224_deepload_cases 同构夹具——S1 配置原样，判读对照其头注）：
# · 场景/构成/构筑/调速：world_grove w16 平铺池、敌 120 驻场补位 ≤8/帧、敌血 ×0.3、
#   W2_gatling L5 + PIERCE×3/MULTI×2/BOUNCE×3/NOVA×2/FRACTAL×2（无棱镜/无自导）、
#   玩家 hp/xp 1e12 封顶 + 慢速小环风筝、PerfGovernor 冻结 + tier2 帧率优先、
#   300 帧预热 + 1800 帧测量（30s@60Hz）、seed(20261004)。
# · 三臂：
#   RES 臂（override=-3，帽96@60Hz）= r224 S1 同配置——结算臂：弹段(grid_projectile)
#     p50/均值 + 结/步 p50（结算真付）。
#   TICK 臂（override=-4 全弃档）= 纯 tick 对照——全部提交丢弃计数 separate_drop、
#     零真结算（硬门）；弹段差集≈结算成本。对账回执：separate_drop/s ≈ RES 结/步×fps。
#   MICRO 臂（override=-2 帽0 直驱管线）= 绕开投射物，对真敌实例构建合成 ctx 直接
#     resolve，批 48/96/192 三档各测 µs/结算——每结算 µs 权威（线性度回执：三档同数量级）。
# · 已知偏差（如实披露，详 JSON disclosure）：TICK 臂零伤害→敌零死亡→死亡新星级联需求
#   缺失+敌群无死亡缺口，弹群动态与 RES 臂不同构（对账比带放宽 [1/3,3] 且为披露类门）；
#   ms 轴跨运行散布 ±30-50%（R224 §四）——结论以同日两轮中位数与比率轴为准。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const GROVE_TABLE := "res://resources/maps/wave_table_grove.tres"
const DT60 := 1.0 / 60.0
const HOLD := 120                      # 驻场敌数（r224 S1 同值）
const WARMUP_FRAMES := 300             # 5s：加特林 spin_up + 弹/结算稳态
const MEASURE_FRAMES := 1800           # 30s@60Hz（r224 S1 同窗——可比口径）
const TOPUP_PER_FRAME := 8             # SPAWN_PER_FRAME 同款补位节流
const PLAYER_HOME := Vector2(360.0, 900.0)
const ENEMY_HP_SCALE := 0.3            # r224 定标旋钮原值（S1 同构成）
const ROUNDS := 2                      # 同日连跑 ≥2 轮取中位数（两轮读数都入 JSON）
const MICRO_BATCHES := [48, 96, 192]   # MICRO 臂三档批大小（线性度回执）
const MICRO_ENEMIES := 48              # MICRO 真敌目标池（轮转命中）
const MICRO_BASE_ATK := 100.0          # 合成结算面板（代表负载——披露非全词条栈）
const BASELINE_JSON := "res://docs/qa/probe_r225_separation_baseline.json"
# R225 把关：reaction_settles 入键——-4 哨兵只闸 resolve 主链（resolve_reaction 无 -4
# 分支，damage_pipeline.gd:126-172），旧九键使 G3 零判据对反应通道结构性失明；入键后
# 反应窗增量可测（详见 _gates G3 注）。测量面收口，产品码零改动。
const PIPE_KEYS := ["settles", "reaction_settles", "settle_deferred", "settle_flush",
	"settle_stale_flush", "settle_flush_dead", "settle_flush_reuse", "settle_overload_drop",
	"separate_drop", "dropped_dupe"]

var tree: SceneTree
var _gl: GameLoop = null
var _fails: int = 0
var _comp: Array[Dictionary] = []      # 平铺构成池 {data: EnemyData, tags: int}（r224 同款）
var _cursor: int = 0
var _spawned_total: int = 0
var _alive_at_reset: int = 0
var _pipe_base: Dictionary = {}        # 管线计数差分基线（测量窗起——diag 无 separate_drop 键，
                                       # R225 探针侧直读 stats() 差分，不改 game_loop.gd）


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(20261004)
	print("══ R225 弹段双组成分离测量：RES(-3 结算臂) × TICK(-4 全弃臂) × MICRO(直驱合成臂) × %d 轮 ══" % ROUNDS)
	if not _boot():
		_teardown()
		return
	for rnd in range(1, ROUNDS + 1):
		print("════════ 第 %d/%d 轮 ════════" % [rnd, ROUNDS])
		var res := await _measure_arm("RES 臂（override=-3 帽96@60Hz——r224 S1 同配置，结算臂）", -3)
		var tick := await _measure_arm("TICK 臂（override=-4 全弃——纯 tick 对照，separate_drop 计数）", -4)
		await tree.process_frame             # R225 修轮：臂间 MessageQueue 冲刷——同步帧
		                                     # 循环不回主循环，延迟消息（CanvasItem 重绘等）
		                                     # 跨臂累积 33MB 队列溢出实证（首轮 run1 crash
		                                     # signal 11——臂界冲刷后单段 ≤2100 帧 ≤ 首轮
		                                     # 已验证的 4400 帧安全余量）
		var micro := _arm_micro()
		var derived := _derive(res, tick, micro)
		var gates := _gates(res, tick, derived, micro)
		_print_derived(rnd, res, tick, derived, gates)
		_store_json(rnd, res, tick, micro, derived, gates)
		_clear_field()                       # 轮间清场（下轮 RES 臂重新铺场）
	_teardown()


func fail_count() -> int:
	return _fails


# ── 引导（r224_deepload_cases._boot 同构——S1 同构成，轮次注释从简） ──

func _boot() -> bool:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "ProbeR225Separation"
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
	print("boot.词条挂载回执：%d/12（PIERCE×3 MULTI×2 BOUNCE×3 NOVA×2 FRACTAL×2——r224 S1 同构筑）" % ok)
	if _gl.player.mirror_count() != 0:
		push_error("[probe] 镜面数 %d ≠ 0（夹具异常）" % _gl.player.mirror_count())
		_fails += 1
		return false
	_gl.stage_probe_enabled = true
	if not _load_composition():
		return false
	print("boot：grove w16 构成 %d 敌种池压血×%.2f（r224 S1 同构成）" % [_comp.size(), ENEMY_HP_SCALE])
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


# ── 驻场补位/风筝（r224 同款） ─────────────────────────────────────

func _kite(p_frame: int) -> void:
	var ang := float(p_frame) * 0.35 / 60.0
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


func _topup() -> void:
	var alive: int = _gl.spawner.active.size()
	var want: int = mini(TOPUP_PER_FRAME, HOLD - alive)
	for i in range(want):
		_spawn_one()


func _kill_count() -> int:
	return _spawned_total + _alive_at_reset - _gl.spawner.active.size()


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


# ── 管线计数差分（R225 探针侧直读 stats()——diag_counts 无 separate_drop 键） ──

func _pipe_snap() -> Dictionary:
	var st: Dictionary = _gl.pipeline.call(&"stats")
	var snap := {}
	for k in PIPE_KEYS:
		snap[k] = int(st.get(k, 0))
	return snap


func _sec_diff() -> Dictionary:
	var snap := _pipe_snap()
	var d := {}
	for k in PIPE_KEYS:
		d[k] = maxi(int(snap[k]) - int(_pipe_base.get(k, 0)), 0)
		_pipe_base[k] = snap[k]
	d["enemies"] = _gl.spawner.active.size()
	d["projectiles"] = (_gl.pools[&"projectile"] as ProjectilePool).active_projectiles().size()
	d["popups"] = int(((_gl.pools[&"popup"] as ObjectPool).stats())["live"])
	return d


# ── 臂测量（RES/TICK 共用骨架——r224 _scenario 同构） ──────────────

func _measure_arm(p_label: String, p_override: int) -> Dictionary:
	print("── %s ──" % p_label)
	await tree.process_frame             # R225 修轮：臂入口冲刷（同步循环前置消息出队）
	_clear_field()                       # 冲刷帧内引擎物理可能驱动 _gl 自然刷怪（await 期
	                                     # 主循环恢复迭代）——臂入口先清场再定量铺场
	DamagePipeline.settle_budget_override = -2
	_gl.pipeline.call(&"begin_frame", -1)   # 门关一帧：前臂顺延积压全量冲刷（落账落前臂，
	DamagePipeline.settle_budget_override = p_override  #  不污染本臂测量窗——r224 情景间清场同思路）
	_spawned_total = 0
	_alive_at_reset = 0
	var deficit := HOLD - _gl.spawner.active.size()   # 清场后残量自适应（冲刷帧引擎自然
	for i in range(maxi(deficit, 0)):                 #   刷怪少量敌时不超铺——驻场带钉 120）
		_spawn_one()
	for i in range(WARMUP_FRAMES):
		_kite(i - WARMUP_FRAMES)
		_gl._physics_process(DT60)
		_topup()
	_alive_at_reset = _gl.spawner.active.size()
	_spawned_total = 0
	_pipe_base = _pipe_snap()               # 差分基线（测量窗起——预热期计数不入窗）
	var totals: Array[float] = []
	var stage: Dictionary = {}
	var per_sec: Array[Dictionary] = []
	var frame_i := 0
	while frame_i < MEASURE_FRAMES:
		_kite(frame_i)
		var t0 := Time.get_ticks_usec()
		_gl._physics_process(DT60)
		var wall_us := Time.get_ticks_usec() - t0
		_topup()
		totals.append(float(wall_us) / 1000.0)
		for k in _gl.stage_probe_us:
			if not stage.has(k):
				stage[k] = [] as Array[float]
			(stage[k] as Array[float]).append(float(_gl.stage_probe_us[k]) / 1000.0)
		frame_i += 1
		if frame_i % 60 == 0:
			per_sec.append(_sec_diff())
	var arm := _arm_readings(p_label, p_override, totals, stage, per_sec)
	_report_arm(arm)
	await tree.process_frame             # R225 修轮：臂出口冲刷（本臂累积延迟消息出队，
	_clear_field()                       #   下臂从空队列起步）
	return arm


func _arm_readings(p_label: String, p_override: int, p_totals: Array[float],
		p_stage: Dictionary, p_per_sec: Array[Dictionary]) -> Dictionary:
	var proj_arr: Array[float] = p_stage.get(&"grid_projectile", [] as Array[float])
	var proj_sorted := proj_arr.duplicate()
	proj_sorted.sort()
	var win := _window_diff(p_per_sec)
	var proj_live: Array[float] = _series(p_per_sec, "projectiles", false)   # 未排序（均值口径）
	var proj_sorted_live := proj_live.duplicate()
	proj_sorted_live.sort()
	return {
		"label": p_label, "override": p_override,
		"wall_p50_ms": _pct(_sorted(p_totals), 0.50),
		"wall_p95_ms": _pct(_sorted(p_totals), 0.95),
		"proj_seg_mean_ms": _mean(proj_arr),
		"proj_seg_p50_ms": _pct(proj_sorted, 0.50),
		"proj_seg_p95_ms": _pct(proj_sorted, 0.95),
		"settle_per_step_p50": _pct(_series(p_per_sec, "settles", true), 0.50),
		"settle_per_s_p50": _pct(_series(p_per_sec, "settles", false), 0.50),
		"subs_per_step_p50": _pct(_series(p_per_sec, "submissions", true), 0.50),
		"deferred_per_step_p50": _pct(_series(p_per_sec, "settle_deferred", true), 0.50),
		"dropped_per_step_p50": _pct(_series(p_per_sec, "dropped", true), 0.50),
		"separate_drop_per_s": _pct(_series(p_per_sec, "separate_drop", false), 0.50),
		"settle_window": int(win["settles"]),
		"flush_window": int(win["settle_flush"]) + int(win["settle_stale_flush"])
			+ int(win["settle_overload_drop"]),
		"deferred_window": int(win["settle_deferred"]),
		"reaction_window": int(win["reaction_settles"]),   # R225 把关：反应窗增量入读数（G3 判据）
		"separate_drop_window": int(win["separate_drop"]),
		"enemy_p50": _pct(_series(p_per_sec, "enemies", false), 0.50),
		"proj_p50": _pct(proj_sorted_live, 0.50),
		"proj_mean": _mean(proj_live),
		"proj_max": _max_of(proj_sorted_live),
		"popup_p50": _pct(_series(p_per_sec, "popups", false), 0.50),
		"killed_in_window": _kill_count(),
		"stage_mean_ms": _stage_means(p_stage),
	}


func _window_diff(p_per_sec: Array[Dictionary]) -> Dictionary:
	# 测量窗累计 = 每秒差分求和（同键口径；避免再拉一次 stats 与帧序错位）
	var win := {}
	for k in PIPE_KEYS:
		var s := 0
		for d in p_per_sec:
			s += int(d.get(k, 0))
		win[k] = s
	return win


func _series(p_per_sec: Array[Dictionary], p_key: String, p_per_step: bool) -> Array[float]:
	# 管线计数=每秒差分（per_step=true 再 ÷60 折每步）；驻场计数=直接读数。
	# submissions=提交需求（r224 口径：结+顺+弃）；dropped=诚实丢弃（亡+复用+超载——
	# r224 diag settles_dropped 同口径，由原始计数键现算）。
	var out: Array[float] = []
	for d in p_per_sec:
		var v := 0.0
		if p_key == "submissions":
			v = float(int(d.get("settles", 0)) + int(d.get("settle_deferred", 0)) \
				+ int(d.get("settle_flush_dead", 0)) + int(d.get("settle_flush_reuse", 0)) \
				+ int(d.get("settle_overload_drop", 0)))
		elif p_key == "dropped":
			v = float(int(d.get("settle_flush_dead", 0)) + int(d.get("settle_flush_reuse", 0)) \
				+ int(d.get("settle_overload_drop", 0)))
		else:
			v = float(int(d.get(p_key, 0)))
		out.append(v / 60.0 if p_per_step else v)
	out.sort()
	return out


func _stage_means(p_stage: Dictionary) -> Dictionary:
	var out := {}
	for k in p_stage:
		out[String(k)] = _mean(p_stage[k])
	return out


func _report_arm(p_arm: Dictionary) -> void:
	print("整帧墙钟 ms：p50=%.3f p95=%.3f（override=%d）"
		% [float(p_arm["wall_p50_ms"]), float(p_arm["wall_p95_ms"]), int(p_arm["override"])])
	var keys: Array = (p_arm["stage_mean_ms"] as Dictionary).keys()
	keys.sort()
	var stage_line := ""
	for k in keys:
		stage_line += "%s=%.2f " % [k, float((p_arm["stage_mean_ms"] as Dictionary)[k])]
	print("稳态段均值 ms：%s" % stage_line)
	print("弹段(grid_projectile) 均值/p50/p95 ms：%.2f / %.2f / %.2f"
		% [float(p_arm["proj_seg_mean_ms"]), float(p_arm["proj_seg_p50_ms"]),
			float(p_arm["proj_seg_p95_ms"])])
	print("结算轴：结/步 p50=%.1f（≈%.0f /s）| 顺/步 p50=%.1f | 弃/步 p50=%.1f | separate_drop/s=%.0f（窗内累计 %d）"
		% [float(p_arm["settle_per_step_p50"]), float(p_arm["settle_per_s_p50"]),
			float(p_arm["deferred_per_step_p50"]), float(p_arm["dropped_per_step_p50"]),
			float(p_arm["separate_drop_per_s"]), int(p_arm["separate_drop_window"])])
	print("回执行（%s）：结算窗增量=%d 冲刷窗增量=%d 顺延窗增量=%d 反应窗增量=%d | 敌 p50=%.0f | 弹 p50=%.0f max=%.0f | 跳字 p50=%.0f | 击杀=%d"
		% [String(p_arm["label"]).substr(0, 4), int(p_arm["settle_window"]),
			int(p_arm["flush_window"]), int(p_arm["deferred_window"]),
			int(p_arm["reaction_window"]),
			float(p_arm["enemy_p50"]), float(p_arm["proj_p50"]), float(p_arm["proj_max"]),
			float(p_arm["popup_p50"]), int(p_arm["killed_in_window"])])


# ── MICRO 臂（直驱管线合成结算——绕开投射物） ──────────────────────

func _arm_micro() -> Dictionary:
	print("── MICRO 臂（override=-2 直驱管线合成结算，批 %s） ──" % str(MICRO_BATCHES))
	DamagePipeline.settle_budget_override = -2              # 帽 0：每发真结算无预算臂
	_gl.pipeline.call(&"begin_frame", -1)
	var pool := _gl.pools[&"enemy"] as EnemyPool
	var targets: Array[Enemy] = []
	for i in range(MICRO_ENEMIES):
		var e := pool.acquire() as Enemy
		if e == null:
			continue
		e.spawn(_micro_enemy_data(), 16, 0)                 # 池化直驱：不入 spawner.active
		e.global_position = Vector2(360.0, 660.0)           # （无 loop 步进零 tick 干扰；巨血防杀）
		targets.append(e)
	var base := _pipe_snap()
	var batch_us := {}
	var frame_no := 900000
	for n in MICRO_BATCHES:
		var batch := int(n)
		var ctxs: Array[DamageContext] = []                 # ctx 预构建（计时窗外——量 resolve 不量构建）
		for i in range(batch):
			ctxs.append(_micro_ctx(910000 + i, targets[i % targets.size()], frame_no))
		_gl.pipeline.call(&"begin_frame", frame_no)         # 幂等缓存清场（计时窗外）
		frame_no += 1
		var t0 := Time.get_ticks_usec()
		for ctx in ctxs:
			_gl.pipeline.call(&"resolve", ctx)
		var us := Time.get_ticks_usec() - t0
		batch_us[batch] = float(us) / float(batch)
		(_gl.pipeline.get(&"_resolved_queue") as Array).clear()   # 批间清队（不入 UI 段——批化队列本套件无派发者）
	var snap := _pipe_snap()
	var micro := {
		"batches": str(MICRO_BATCHES),
		"batch_us": batch_us,
		"per_settle_us_median": _median_of3(float(batch_us[48]), float(batch_us[96]), float(batch_us[192])),
		"linearity_ratio": _ratio3(batch_us),
		"settles_total": int(snap["settles"]) - int(base["settles"]),
		"planned_total": 336,
		"deferred_total": int(snap["settle_deferred"]) - int(base["settle_deferred"]),
		"separate_drop_total": int(snap["separate_drop"]) - int(base["separate_drop"]),
		"dupe_total": int(snap["dropped_dupe"]) - int(base["dropped_dupe"]),
	}
	print("MICRO 回执：批48=%.1fµs/结 批96=%.1fµs/结 批192=%.1fµs/结 | 中位=%.1fµs | 线性比=%.2f（≤3 收）| 结算=%d/%d 顺=%d 弃=%d 复=%d"
		% [float(batch_us[48]), float(batch_us[96]), float(batch_us[192]),
			float(micro["per_settle_us_median"]), float(micro["linearity_ratio"]),
			int(micro["settles_total"]), int(micro["planned_total"]),
			int(micro["deferred_total"]), int(micro["separate_drop_total"]),
			int(micro["dupe_total"])])
	for t in targets:
		pool.release(t)
	targets.clear()
	return micro


func _micro_enemy_data() -> EnemyData:
	# MICRO 真敌夹具（r223_settlebudget_cases._fixture_enemy 同款——巨血防杀）
	var d := EnemyData.new()
	d.id = &"E_R225_MICRO"
	d.display_name = "R225_MICRO"
	d.hp_base = 1.0e15
	d.spd_base = 0.0
	d.dmg_base = 0.0
	d.exp_base = 1.0
	d.hitbox_r = 14.0
	d.resist = [0.0, 0.0, 0.0, 0.0]
	return d


func _micro_ctx(p_source: int, p_target: Enemy, p_frame: int) -> DamageContext:
	# 合成 ctx（对真敌实例）：代表负载披露——base 100 + 1 add + 2 mult（含 vuln）+ 1 local
	# + crit 0.05（非全词条栈复刻——µs/结算为代表值，见 JSON disclosure）
	var ctx := DamageContext.make()
	ctx.source_uid = p_source
	ctx.target_uid = p_target.uid
	ctx.target = p_target
	ctx.frame_stamp = p_frame
	ctx.base_atk = MICRO_BASE_ATK
	ctx.crit_chance = 0.05
	ctx.crit_mult = 2.0
	ctx.add_entries.append({"trait_id": &"AFF_SYN", "pool_id": &"r225_syn",
		"layer": 1, "contrib": 0.15, "decay_delta": 0.0, "is_curse": false})
	ctx.mult_pools.append({"pool_id": &"r225_a", "source_uid": p_source,
		"contrib": 0.5, "cap_pool": 2.0, "priority": 0})
	ctx.mult_pools.append({"pool_id": &"vuln", "source_uid": 0,
		"contrib": 0.25, "cap_pool": 1.0, "priority": 0})
	ctx.local_pools.append({"local_id": &"r225_l", "contrib": 0.2, "cap_local": 1.0})
	ctx.pos = p_target.global_position
	return ctx


# ── 推导口径 + 门（硬门阻塞退出码；披露类 FAIL* 不计数） ───────────

func _derive(p_res: Dictionary, p_tick: Dictionary, p_micro: Dictionary) -> Dictionary:
	var res_mean := float(p_res["proj_seg_mean_ms"])
	var tick_mean := float(p_tick["proj_seg_mean_ms"])
	var res_p50 := float(p_res["proj_seg_p50_ms"])
	var tick_p50 := float(p_tick["proj_seg_p50_ms"])
	var res_step := float(p_res["settle_per_step_p50"])
	var tick_drop_s := float(p_tick["separate_drop_per_s"])
	var tick_proj := float(p_tick["proj_p50"])
	var per_settle := float(p_micro["per_settle_us_median"])
	var share_mean := 0.0
	if res_mean > 0.0:
		share_mean = (res_mean - tick_mean) / res_mean * 100.0
	var share_p50 := 0.0
	if res_p50 > 0.0:
		share_p50 = (res_p50 - tick_p50) / res_p50 * 100.0
	var upper_us := 0.0
	if res_step > 0.0:
		upper_us = res_mean * 1000.0 / res_step
	var per_tick := 0.0
	if tick_proj > 0.0:
		per_tick = tick_mean * 1000.0 / tick_proj
	var tick_proj_mean := float(p_tick["proj_mean"])
	var per_tick_mean := 0.0
	if tick_proj_mean > 0.0:
		per_tick_mean = tick_mean * 1000.0 / tick_proj_mean
	var ratio := 0.0
	if res_step > 0.0:
		ratio = tick_drop_s / (res_step * 60.0)
	return {
		"settle_share_pct_mean": share_mean,
		"settle_share_pct_p50": share_p50,
		"per_settle_us_micro": per_settle,
		"upper_bound_us_res": upper_us,
		"per_proj_tick_us": per_tick,
		"per_proj_tick_us_mean": per_tick_mean,
		"reconcile_ratio": ratio,
		"tick_over_res_seg": tick_mean / res_mean if res_mean > 0.0 else 0.0,
		# 交叉引用原值（推导输入——JSON 复核用）
		"res_seg_mean_ms": res_mean, "tick_seg_mean_ms": tick_mean,
		"res_settle_step": res_step, "tick_drop_s": tick_drop_s,
		"tick_proj_p50": tick_proj, "tick_proj_mean": tick_proj_mean,
	}


func _gates(p_res: Dictionary, p_tick: Dictionary, p_d: Dictionary,
		p_micro: Dictionary) -> Dictionary:
	var g: Dictionary = {}
	# 硬门（阻塞退出码）
	g["G1 RES 敌带 p50≥118（负载在位）"] = {"ok": float(p_res["enemy_p50"]) >= 118.0,
		"detail": "%.0f" % float(p_res["enemy_p50"])}
	g["G2 RES 弹带 p50≥60（弹群在位；上沿披露不设门）"] = {"ok": float(p_res["proj_p50"]) >= 60.0,
		"detail": "%.0f" % float(p_res["proj_p50"])}
	# R225 把关（契约变更）：G3 零判据并入反应窗增量——-4 哨兵只闸 resolve 主链
	# （damage_pipeline.gd:76-80；resolve_reaction :126-172 无 -4 分支，注释明示豁免系
	# 有意设计），旧三窗判据下反应附着语义回归会静默混入反应结算成本。现四窗全零才过；
	# 当前夹具 W2 无元素卡=结构性零反应（基线反应窗=0），不误伤。
	g["G3 TICK 零结算（结算窗增量=0 且 冲刷窗增量=0 且 顺延窗增量=0 且 反应窗增量=0）"] = {
		"ok": int(p_tick["settle_window"]) == 0 and int(p_tick["flush_window"]) == 0
			and int(p_tick["deferred_window"]) == 0 and int(p_tick["reaction_window"]) == 0,
		"detail": "结=%d 冲=%d 顺=%d 反=%d" % [int(p_tick["settle_window"]),
			int(p_tick["flush_window"]), int(p_tick["deferred_window"]),
			int(p_tick["reaction_window"])]}
	g["G4 TICK 弃计数在走（separate_drop 窗内>0）"] = {"ok": int(p_tick["separate_drop_window"]) > 0,
		"detail": "%d" % int(p_tick["separate_drop_window"])}
	g["G5 MICRO 线性度（三档 µs/结算 max/min ≤3=同数量级）"] = {
		"ok": float(p_micro["linearity_ratio"]) <= 3.0,
		"detail": "%.2f" % float(p_micro["linearity_ratio"])}
	g["G6 MICRO 纯净（结算=336 · 顺/弃/复=0——零混入）"] = {
		"ok": int(p_micro["settles_total"]) == 336 and int(p_micro["deferred_total"]) == 0
			and int(p_micro["separate_drop_total"]) == 0 and int(p_micro["dupe_total"]) == 0,
		"detail": "结=%d 顺=%d 弃=%d 复=%d" % [int(p_micro["settles_total"]),
			int(p_micro["deferred_total"]), int(p_micro["separate_drop_total"]),
			int(p_micro["dupe_total"])]}
	# 披露类门（FAIL* 不阻塞——偏差来源已声明）
	g["G7* 对账比 separate_drop/s ÷（RES 结/步×60）∈[1/3,3]（TICK 臂敌不死→新星级联需求缺失=结构性偏差）"] = {
		"ok": float(p_d["reconcile_ratio"]) >= 1.0 / 3.0 and float(p_d["reconcile_ratio"]) <= 3.0,
		"detail": "%.2f" % float(p_d["reconcile_ratio"]), "disclosed": true}
	g["G8* TICK/RES 弹段比 ∈[0.2,2.0]（双臂动态同量级）"] = {
		"ok": float(p_d["tick_over_res_seg"]) >= 0.2 and float(p_d["tick_over_res_seg"]) <= 2.0,
		"detail": "%.2f" % float(p_d["tick_over_res_seg"]), "disclosed": true}
	g["G9* 结算份额 ∈[0,100]%（负值=噪声淹没，两轮中位数判）"] = {
		"ok": float(p_d["settle_share_pct_p50"]) >= 0.0 and float(p_d["settle_share_pct_p50"]) <= 100.0,
		"detail": "%.1f%%" % float(p_d["settle_share_pct_p50"]), "disclosed": true}
	for key in g:
		var e: Dictionary = g[key]
		if bool(e.get("ok", false)):
			print("  PASS | %s（%s）" % [key, String(e["detail"])])
		elif e.has("disclosed"):
			print("  FAIL* | %s（%s）——披露类失配不阻塞（偏差来源见 JSON disclosure）" % [key, String(e["detail"])])
		else:
			print("  FAIL | %s（%s）" % [key, String(e["detail"])])
			_fails += 1
	return g


func _print_derived(p_rnd: int, p_res: Dictionary, p_tick: Dictionary,
		p_d: Dictionary, p_gates: Dictionary) -> void:
	print("推导口径（第 %d 轮）：" % p_rnd)
	print("  结算归属弹段占比 =（RES 弹段 %.2fms − TICK 弹段 %.2fms）/ RES 弹段 ×100 = %.1f%%（p50 口径 %.1f%%）"
		% [float(p_res["proj_seg_mean_ms"]), float(p_tick["proj_seg_mean_ms"]),
			float(p_d["settle_share_pct_mean"]), float(p_d["settle_share_pct_p50"])])
	print("  每结算 µs（MICRO 权威）= %.1f µs | r224 上界口径对照（RES 弹段÷结/步）= %.1f µs"
		% [float(p_d["per_settle_us_micro"]), float(p_d["upper_bound_us_res"])])
	print("  每弹 tick µs = TICK 弹段 ÷ 活弹 p50(%.0f) = %.3f µs（活弹均值分母 %.1f → %.3f µs——TICK 臂活弹分布双峰时 p50 口径退化，均值口径为准，披露见 JSON）"
		% [float(p_tick["proj_p50"]), float(p_d["per_proj_tick_us"]),
			float(p_tick["proj_mean"]), float(p_d["per_proj_tick_us_mean"])])
	print("  对账比 = TICK separate_drop/s(%.0f) ÷（RES 结/步 %.1f ×60）= %.2f"
		% [float(p_tick["separate_drop_per_s"]), float(p_res["settle_per_step_p50"]),
			float(p_d["reconcile_ratio"])])
	var hard_ok := true
	for key in p_gates:
		if not bool((p_gates[key] as Dictionary).get("ok", false)) \
				and not (p_gates[key] as Dictionary).has("disclosed"):
			hard_ok = false
	print("第 %d 轮门：硬门 %s（FAIL* 披露类 %d 项不计数；明细见上行）"
		% [p_rnd, "全过" if hard_ok else "有未过", _disclosed_fail_count(p_gates)])


func _disclosed_fail_count(p_gates: Dictionary) -> int:
	var n := 0
	for key in p_gates:
		var e: Dictionary = p_gates[key]
		if not bool(e.get("ok", false)) and e.has("disclosed"):
			n += 1
	return n


# ── 基线 JSON（runs[] 同日累积最近两轮；跨代轮转 _prev1 只留一代） ──

func _store_json(p_rnd: int, p_res: Dictionary, p_tick: Dictionary, p_micro: Dictionary,
		p_derived: Dictionary, p_gates: Dictionary) -> void:
	var today := Time.get_date_string_from_system()
	_rotate_baseline(today)
	var root: Dictionary = {}
	var text := FileAccess.get_file_as_string(BASELINE_JSON)
	if not text.is_empty():
		var parsed: Variant = JSON.parse_string(text)
		if parsed is Dictionary:
			root = parsed
	var res_pub: Dictionary = p_res.duplicate()
	res_pub.erase("stage_mean_ms")       # 全段均值体量大——已在上行打印，JSON 留弹段三读数
	var tick_pub: Dictionary = p_tick.duplicate()
	tick_pub.erase("stage_mean_ms")
	var run := {
		"round": p_rnd, "date": today,
		"res": res_pub, "tick": tick_pub, "micro": p_micro.duplicate(),
		"derived": p_derived.duplicate(), "gates": p_gates.duplicate(),
	}
	var runs: Array = root.get("runs", [])
	runs.append(run)
	while runs.size() > 2:               # 同日只保最近两轮（中位数口径=两轮中位）
		runs.pop_front()
	root["runs"] = runs
	root["median"] = _median_block(runs)
	root["meta"] = {
		"date": today,
		"package": "desktop-headless-probe（R225 分离测量——R224 §四读数二遗留收口）",
		"map": "world_grove w16（敌血 ×0.3 定标复本，r224 S1 同构夹具）",
		"hold": HOLD, "dt": DT60, "measure_frames": MEASURE_FRAMES, "rounds": ROUNDS,
		"build": "W2_gatling L5 + AFF_PIERCE×3/AFF_MULTI×2/MEC_BOUNCE×3/MEC_KILL_BLAST×2/MEC_FRACTAL×2（无棱镜/无自导——r224 同构筑）",
		"governor": "frozen, mode=frame_priority, tier_override=2",
		"arms": "RES=override -3 帽96@60Hz（r224 S1 同配置）/ TICK=override -4 全弃（separate_drop 计数、零结算）/ MICRO=override -2 直驱管线合成结算（批 48/96/192，对真敌实例构建 ctx）",
		"formulas": "结算归属弹段占比=(RES弹段-TICK弹段)/RES弹段×100；每结算µs 以 MICRO 臂为准；每弹tickµs=TICK弹段÷TICK活弹p50；对账比=TICK separate_drop/s ÷（RES 结/步×60）；r224 上界口径对照=RES弹段÷结/步",
		"median_note": "两轮中位=排序中值（偶数取两中项均值）；ms 轴散布大（R224 §四 ±30-50%）——结论以中位数与比率轴为准",
		"note": "desktop headless；绝对 ms 桌面≠真机（R224 修正带 ×0.5-2）；渲染面不可复现；跨代轮转 _prev1 只留一代",
	}
	root["disclosure"] = [
		"TICK 臂零伤害→敌零死亡：MEC_KILL_BLAST 死亡新星级联需求缺失（r224 实证=需求主引擎）+敌群无死亡缺口补位——弹群动态与 RES 臂不同构，对账比 G7* 为披露类门（带 [1/3,3]）",
		"TICK 臂活弹分布双峰（敌密集成团→弹即中即耗穿透即时回收，无长命跳弹驻留；首轮实测 p50=0/max=221）——每弹tickµs 的 p50 分母口径退化时以均值分母口径为准（两口径都落 JSON）",
		"R225 修轮：臂间 MessageQueue 冲刷（同步帧循环不回主循环，延迟消息跨臂累积 33MB 队列溢出=首轮 crash signal 11 实证）——冲刷点在臂界/轮界，测量窗内零 await 不污染计时",
		"MICRO 臂合成 ctx 为代表负载（base100+1add+2mult+1local+crit0.05），非全词条栈复刻——每结算 µs 为代表值",
		"MICRO 目标=48 真敌实例轮转（非 120 敌现场分布）——缓存局部性略优于真实",
		"RES/TICK 双臂 ms 轴跨运行散布 ±30-50%（R224 §四）——分离结论以同日两轮中位数与比率轴为准",
		"占位命中跳过元素附着（R223 评审#2 语义）——TICK 臂零附着零反应（与 r224 夹具感0 基线一致）",
	]
	var f := FileAccess.open(BASELINE_JSON, FileAccess.WRITE)
	if f == null:
		push_warning("[probe] 基线 JSON 写入失败（docs/qa/ 目录）：%s" % BASELINE_JSON)
		return
	f.store_string(JSON.stringify(root, "\t"))
	f.close()
	print("基线 JSON 已写：%s（round %d；runs 累积 %d 轮）" % [BASELINE_JSON, p_rnd, runs.size()])


func _rotate_baseline(p_today: String) -> void:
	# 跨代轮转：现存档 meta.date 非今日 → 整档移 _prev1（只留一代），今日档重新累积
	if not FileAccess.file_exists(BASELINE_JSON):
		return
	var text := FileAccess.get_file_as_string(BASELINE_JSON)
	if text.is_empty():
		return
	var parsed: Variant = JSON.parse_string(text)
	if parsed is Dictionary:
		var meta: Variant = (parsed as Dictionary).get("meta")
		if meta is Dictionary and String((meta as Dictionary).get("date", "")) == p_today:
			return                        # 同日档：runs 累积，不轮转
	var fw := FileAccess.open(BASELINE_JSON.get_base_dir()
		+ "/probe_r225_separation_baseline_prev1.json", FileAccess.WRITE)
	if fw != null:
		fw.store_string(text)
		fw.close()


func _median_block(p_runs: Array) -> Dictionary:
	# 关键读数跨轮中位数（runs 1-2 个：1 个=原值；2 个=两中项均值）
	var paths := [
		["res", "proj_seg_mean_ms"], ["res", "proj_seg_p50_ms"], ["res", "settle_per_step_p50"],
		["tick", "proj_seg_mean_ms"], ["tick", "proj_seg_p50_ms"], ["tick", "separate_drop_per_s"],
		["micro", "per_settle_us_median"], ["derived", "settle_share_pct_mean"],
		["derived", "settle_share_pct_p50"], ["derived", "per_proj_tick_us"],
		["derived", "per_proj_tick_us_mean"],
		["derived", "reconcile_ratio"], ["derived", "upper_bound_us_res"],
	]
	var out := {}
	for path in paths:
		var vals: Array[float] = []
		for r in p_runs:
			var node: Dictionary = r
			var ok := true
			for i in range(path.size() - 1):
				var nxt: Variant = node.get(path[i])
				if nxt is Dictionary:
					node = nxt
				else:
					ok = false
					break
			if ok and node.has(path[path.size() - 1]):
				vals.append(float(node[path[path.size() - 1]]))
		out["_".join(PackedStringArray(path))] = _median(vals)
	return out


# ── 统计工具 ───────────────────────────────────────────────────────

func _sorted(p_arr: Array[float]) -> Array[float]:
	var s := p_arr.duplicate()
	s.sort()
	return s


func _pct(p_sorted: Array[float], p_p: float) -> float:
	if p_sorted.is_empty():
		return 0.0
	return p_sorted[clampi(int(float(p_sorted.size()) * p_p), 0, p_sorted.size() - 1)]


func _mean(p_arr: Array[float]) -> float:
	if p_arr.is_empty():
		return 0.0
	var s := 0.0
	for v in p_arr:
		s += v
	return s / float(p_arr.size())


func _max_of(p_arr: Array[float]) -> float:
	var m := 0.0
	for v in p_arr:
		m = maxf(m, v)
	return m


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
	PerfGovernor.mode_override = -1
	PerfGovernor.tier_override = -1
	PerfGovernor.set_process(true)
	if _gl != null:
		_gl.queue_free()
		await tree.process_frame
		await tree.process_frame

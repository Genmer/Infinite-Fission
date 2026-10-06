# tests/runner/r236_agg_cases.gd
# R236 A 案用例体（入口 test_r236_agg.gd 运行时 load——cases 禁 test_ 前缀防电池 glob 误收）。
# 覆盖：
# ① 关态零扰动：OVERKILL_AGGREGATE=false → agg_* 计数恒 0、resolve 即时结算（提交数==事件数）
# ② 开态组守恒（crit0 定量）：3 发跨源同目标同帧 → dispatch 后恰 1 结算事件、hp 减量==3×单发、
#    agg_merged=2/agg_flush=1；首发返回 deferred_merge 占位（final=0）
# ③ 跨源异 base 合并：10+4 → 总减量 14（首发参数代表组——crit0 同乘区域）
# ④ 幂等口径：同 (source,target,frame) 重复提交 → ① 幂等闸折返 dropped_dupe，不并入组不双计
# ⑤ 冲刷死亡复检：组建后敌亡 → dispatch 冲刷走 settle_flush_dead、零结算事件零落血
# ⑥ 多目标分组：2 目标×2 发 → 2 组 2 事件、各自减量独立正确
# ⑦ 跨帧分组：帧1 冲刷后帧2 同目标新组 → 两事件（begin_frame 清缓存+组表帧界）
# ⑧ 超帽回潮闸：帽=1 + 3 组 → dispatch 冲 1 组、2 组并入 R223 顺延（agg_overflow_defer=2）→
#    下帧 begin_frame 帧头冲刷余组落地
# ⑨ end_frame 兜底：提交后不 dispatch 直接 end_frame → 残组并入顺延 FIFO 零丢失（下帧冲刷）
# ⑩ crit 期望守恒（统计带）：crit0.5 双臂对拍（agg vs 非 agg 同种子同轮数）总伤害比值 ∈[0.9,1.1]
# ⑪ 套件总项数断言（R231 假绿教训）
# 本套件纯 headless 无窗口；开关静态注入，teardown 复位 false（vc40 随包关态=默认）。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const DT := 1.0 / 60.0
const EXPECTED_TOTAL := 16

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null
var _spy: Array[Dictionary] = []
var _cb: Callable = Callable()


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(20261006)
	await _boot_game_loop()
	await tree.process_frame
	await tree.process_frame
	_gl.state = GameConst.GameStatus.MENU             # 静止环境（r230 先例）
	PerfGovernor.set_process(false)
	GameLoop.SIM_30HZ_ENABLED = false
	GameLoop.sim30_override = -1
	# headless 预算门默认关（cap_now=0——组冲刷会走 R223 门关顺延路径）；-3=模拟
	# 真机门（r223 ⑦/r233 tiers 同款注入）——组冲刷主路径可达。
	DamagePipeline.settle_budget_override = -3
	PerfGovernor.mode_override = 0                  # 帧率优先（r223 ⑦ 同款——门内 tier 映射可达）
	PerfGovernor.tier_override = 1
	_cb = func(r: DamageResult) -> void: _spy.append(
		{"uid": int(r.target_uid), "v": float(r.final_value)})
	EventBus.damage_resolved.connect(_cb)
	_test_1_off_zero_perturbation()
	_test_2_on_merge_conservation()
	_test_3_cross_source_base()
	_test_4_idempotent_dupe()
	_test_5_flush_dead_recheck()
	_test_6_multi_target_groups()
	_test_7_cross_frame_groups()
	_test_8_overflow_to_defer()
	_test_9_endframe_residual()
	await _test_10_crit_expectation()
	await _cleanup()
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


func _boot_game_loop() -> void:
	var main: Node = load(MAIN_SCENE).instantiate()
	tree.root.add_child(main)
	await tree.process_frame
	_gl = tree.root.get_node_or_null("Main") as GameLoop
	if _gl == null:
		for c in tree.root.get_children():
			if c is GameLoop:
				_gl = c
				break


func _cleanup() -> void:
	EventBus.damage_resolved.disconnect(_cb)
	DamagePipeline.OVERKILL_AGGREGATE = false           # 复位=源默认关态（翻开试验被开态电池 28 红否决，见 docs/qa 证据）
	DamagePipeline.settle_budget_override = -1
	PerfGovernor.mode_override = -1
	PerfGovernor.tier_override = -1
	_release_field()
	if _gl != null:
		_gl.queue_free()
		await tree.process_frame
		await tree.process_frame


func _release_field() -> void:
	if _gl == null:
		return
	for e in _gl.spawner.active.duplicate():
		if is_instance_valid(e):
			(_gl.pools[&"enemy"] as EnemyPool).release(e)
	_gl.spawner.active.clear()
	var pool := _gl.pools[&"projectile"] as ProjectilePool
	for n in pool.active_projectiles().duplicate():
		if is_instance_valid(n):
			pool.release(n)


func _empty_items() -> Array[Node2D]:
	var out: Array[Node2D] = []
	return out


func _statsi(p_key: String) -> int:
	return int(_gl.pipeline._stats.get(p_key, 0))


# ── 夹具（r235 同构） ─────────────────────────────────────────────

func _fixture_enemy_data(p_id: StringName, p_hp: float) -> EnemyData:
	var d := EnemyData.new()
	d.id = p_id
	d.display_name = String(p_id)
	d.hp_base = p_hp
	d.spd_base = 0.0
	d.dmg_base = 0.0
	d.exp_base = 1.0
	d.hitbox_r = 14.0
	d.resist = [0.0, 0.0, 0.0, 0.0]
	return d


func _spawn_enemy(p_hp: float, p_pos: Vector2) -> Enemy:
	var pool := _gl.pools[&"enemy"] as EnemyPool
	var e := pool.acquire() as Enemy
	e.bucket_host = pool.bucket_host
	e.spawn(_fixture_enemy_data(&"r236_agg", p_hp), 1, 0)
	e._fade_left = 0.0
	e.modulate.a = 1.0
	e.global_position = p_pos
	_gl.spawner.active.append(e)
	return e


func _spawn_bullet(p_pos: Vector2, p_atk: float = 10.0, p_crit: float = 0.0) -> ProjectileBase:
	var params := {
		"velocity": Vector2(0.0, -500.0), "lifetime": 9.0, "pierce": 3, "team": 0,
		"hitbox_radius": 8.0, "range": 900.0,
		"trait_stack": TraitStack.new(),
		"panel_snapshot": {"base_atk": p_atk, "flat_bonus": 0.0,
			"crit_rate": p_crit, "crit_mult": 2.0, "add_entries": []},
		"position": p_pos,
	}
	var pool := _gl.pools[&"projectile"] as ProjectilePool
	var proj := pool.acquire()
	proj.damage_pipeline = _gl.pipeline
	proj.enemy_grid = _gl.enemy_grid
	proj.pool = pool
	proj.spawn(params)
	return proj


func _frame(p_combat: bool = true, p_frame: int = 1) -> void:
	# 帧序驱动（直构口径）：begin_frame（清幂等缓存+战斗武装）→ …提交… → dispatch → end_frame
	_gl.pipeline.begin_frame(p_frame, p_combat)


func _dispatch() -> void:
	_gl.pipeline.call(&"dispatch_resolved_frame")


func _endframe() -> void:
	_gl.pipeline.call(&"end_frame")


# ── ① 关态零扰动 ─────────────────────────────────────────────────

func _test_1_off_zero_perturbation() -> void:
	print("── ① 关态零扰动 ──")
	_release_field()
	_gl.enemy_grid.rebuild(_empty_items())
	DamagePipeline.OVERKILL_AGGREGATE = false
	(_gl.pipeline.get("_resolved_queue") as Array).clear()
	_frame(true, 1)
	var e := _spawn_enemy(1.0e9, Vector2(360.0, 600.0))
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	var b := _spawn_bullet(Vector2(360.0, 600.0))
	b._tick_fast_player(DT)                         # 命中提交（关态=即时结算路径）
	var qn: int = (_gl.pipeline.get("_resolved_queue") as Array).size()
	_dispatch()
	_check("关态即时结算（tick 期已入派发队——未聚合持有）", qn == 1, str(qn))
	_check("关态 agg_* 计数恒 0（零扰动）",
		_statsi("agg_merged") == 0 and _statsi("agg_flush") == 0
			and _statsi("agg_overflow_defer") == 0,
		"m=%d f=%d o=%d" % [_statsi("agg_merged"), _statsi("agg_flush"),
			_statsi("agg_overflow_defer")])
	(b.pool as ProjectilePool).release(b)
	_endframe()


# ── ② 开态组守恒（crit0 定量） ────────────────────────────────────

func _test_2_on_merge_conservation() -> void:
	print("── ② 开态组守恒 ──")
	_release_field()
	_gl.enemy_grid.rebuild(_empty_items())
	DamagePipeline.OVERKILL_AGGREGATE = true
	var m0 := _statsi("agg_merged")
	var f0 := _statsi("agg_flush")
	_frame(true, 2)
	var e := _spawn_enemy(1.0e9, Vector2(360.0, 600.0))
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	var hp0: float = e.hp
	var n0 := _spy.size()
	var ph_first: DamageResult = null
	for i in 3:
		var b := _spawn_bullet(Vector2(360.0, 600.0))
		b._tick_fast_player(DT)
		if i == 0:
			var agg0: Dictionary = _gl.pipeline._frame_agg.get(
				int(e.uid) & GameConst.UID_MAX, {})
			ph_first = agg0.get("placeholder") if not agg0.is_empty() else null
	_check("首发返回 deferred_merge 占位（final=0）",
		ph_first != null and ph_first.deferred_merge and ph_first.final_value == 0.0,
		"ph=%s" % str(ph_first))
	_check("冲刷前零结算事件（聚合持有）", _spy.size() == n0, str(_spy.size() - n0))
	_dispatch()
	_check("dispatch 后恰 1 结算事件（组口径）", _spy.size() - n0 == 1, str(_spy.size() - n0))
	_check("hp 减量==3×单发（守恒 crit0：10×3=30）",
		absf(hp0 - e.hp - 30.0) < 0.0001, "%f" % (hp0 - e.hp))
	_check("agg_merged=2 / agg_flush=1（组员并入+组真结算）",
		_statsi("agg_merged") - m0 == 2 and _statsi("agg_flush") - f0 == 1,
		"m=%d f=%d" % [_statsi("agg_merged") - m0, _statsi("agg_flush") - f0])
	_endframe()


# ── ③ 跨源异 base 合并 ────────────────────────────────────────────

func _test_3_cross_source_base() -> void:
	print("── ③ 跨源异 base ──")
	_release_field()
	_gl.enemy_grid.rebuild(_empty_items())
	DamagePipeline.OVERKILL_AGGREGATE = true
	_frame(true, 3)
	var e := _spawn_enemy(1.0e9, Vector2(360.0, 600.0))
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	var hp0: float = e.hp
	var b1 := _spawn_bullet(Vector2(360.0, 600.0), 10.0)
	b1._tick_fast_player(DT)
	var b2 := _spawn_bullet(Vector2(360.0, 600.0), 4.0)
	b2._tick_fast_player(DT)
	_dispatch()
	_check("跨源异 base 合并（10+4=14 落地）",
		absf(hp0 - e.hp - 14.0) < 0.0001, "%f" % (hp0 - e.hp))
	_endframe()


# ── ④ 幂等口径 ────────────────────────────────────────────────────

func _test_4_idempotent_dupe() -> void:
	print("── ④ 幂等口径 ──")
	_release_field()
	_gl.enemy_grid.rebuild(_empty_items())
	DamagePipeline.OVERKILL_AGGREGATE = true
	_frame(true, 4)
	var e := _spawn_enemy(1.0e9, Vector2(360.0, 600.0))
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	var hp0: float = e.hp
	var b := _spawn_bullet(Vector2(360.0, 600.0))
	b._tick_fast_player(DT)
	var agg0: Dictionary = _gl.pipeline._frame_agg.get(
		int(e.uid) & GameConst.UID_MAX, {})
	var r1: DamageResult = agg0.get("placeholder") if not agg0.is_empty() else null
	# 弹侧直调 resolve 二次（绕过 E-03 帧去重——幂等闸口径验证）
	var ctx2 := b._build_damage_ctx(e)
	var r2: DamageResult = _gl.pipeline.resolve(ctx2)
	_dispatch()
	_check("同 (source,target,frame) 重复提交走幂等闸不双计",
		r2 == r1 and absf(hp0 - e.hp - 10.0) < 0.0001,
		"same=%s dhp=%f" % [str(r2 == r1), hp0 - e.hp])
	_endframe()


# ── ⑤ 冲刷死亡复检 ────────────────────────────────────────────────

func _test_5_flush_dead_recheck() -> void:
	print("── ⑤ 冲刷死亡复检 ──")
	_release_field()
	_gl.enemy_grid.rebuild(_empty_items())
	DamagePipeline.OVERKILL_AGGREGATE = true
	var fd0 := _statsi("settle_flush_dead")
	_frame(true, 5)
	var e := _spawn_enemy(50.0, Vector2(360.0, 600.0))
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	var b := _spawn_bullet(Vector2(360.0, 600.0))
	b._tick_fast_player(DT)
	# 组已建；冲刷前敌亡（池 release——dead 置位+出 active，uid 不变=死亡复检臂）
	(_gl.pools[&"enemy"] as EnemyPool).release(e)
	_dispatch()
	_check("冲刷死亡复检（settle_flush_dead+1）",
		_statsi("settle_flush_dead") - fd0 == 1,
		"d=%d" % [_statsi("settle_flush_dead") - fd0])
	_endframe()


# ── ⑥ 多目标分组 ──────────────────────────────────────────────────

func _test_6_multi_target_groups() -> void:
	print("── ⑥ 多目标分组 ──")
	_release_field()
	_gl.enemy_grid.rebuild(_empty_items())
	DamagePipeline.OVERKILL_AGGREGATE = true
	_frame(true, 6)
	var e1 := _spawn_enemy(1.0e9, Vector2(300.0, 600.0))
	var e2 := _spawn_enemy(1.0e9, Vector2(420.0, 600.0))
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	var hp1: float = e1.hp
	var hp2: float = e2.hp
	for i in 2:
		var b1 := _spawn_bullet(Vector2(300.0, 600.0))
		b1._tick_fast_player(DT)
		var b2 := _spawn_bullet(Vector2(420.0, 600.0))
		b2._tick_fast_player(DT)
	_dispatch()
	_check("多目标分组（2 组各自独立守恒 10×2）",
		absf(hp1 - e1.hp - 20.0) < 0.0001 and absf(hp2 - e2.hp - 20.0) < 0.0001,
		"d1=%f d2=%f" % [hp1 - e1.hp, hp2 - e2.hp])
	_endframe()


# ── ⑦ 跨帧分组 ────────────────────────────────────────────────────

func _test_7_cross_frame_groups() -> void:
	print("── ⑦ 跨帧分组 ──")
	_release_field()
	_gl.enemy_grid.rebuild(_empty_items())
	DamagePipeline.OVERKILL_AGGREGATE = true
	var f0 := _statsi("agg_flush")
	_frame(true, 7)
	var e := _spawn_enemy(1.0e9, Vector2(360.0, 600.0))
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	var b := _spawn_bullet(Vector2(360.0, 600.0))
	b._tick_fast_player(DT)
	_dispatch()
	_endframe()
	_frame(true, 8)                                  # 新帧：幂等缓存清空+组表帧界
	var b2 := _spawn_bullet(Vector2(360.0, 600.0))
	b2._tick_fast_player(DT)
	_dispatch()
	_check("跨帧分组（两帧两事件——帧界不粘连）",
		_statsi("agg_flush") - f0 == 2, str(_statsi("agg_flush") - f0))
	_endframe()


# ── ⑧ 超帽回潮闸 ──────────────────────────────────────────────────

func _test_8_overflow_to_defer() -> void:
	print("── ⑧ 超帽回潮闸 ──")
	_release_field()
	_gl.enemy_grid.rebuild(_empty_items())
	DamagePipeline.OVERKILL_AGGREGATE = true
	DamagePipeline.settle_budget_override = 1         # 强制帽=1（r223 套件同款注入）
	var o0 := _statsi("agg_overflow_defer")
	_frame(true, 9)
	for i in 3:
		var e := _spawn_enemy(1.0e9, Vector2(200.0 + 120.0 * i, 600.0))
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	for i in 3:
		var b := _spawn_bullet(Vector2(200.0 + 120.0 * i, 600.0))
		b._tick_fast_player(DT)
	_dispatch()
	_check("组数超帽并入 R223 顺延（agg_overflow_defer=2）",
		_statsi("agg_overflow_defer") - o0 == 2, str(_statsi("agg_overflow_defer") - o0))
	_endframe()
	DamagePipeline.settle_budget_override = -3       # 复位帽（套件真机门口径）——帧头冲刷余组
	_frame(true, 10)                                 # 帧头冲刷余组
	var flushed: int = 0
	for e in _gl.spawner.active:
		if e.hp < 1.0e9:
			flushed += 1
	_check("下帧帧头冲刷余组落地（3 敌皆承伤）", flushed == 3, str(flushed))
	_dispatch()
	_endframe()


# ── ⑨ end_frame 兜底 ─────────────────────────────────────────────

func _test_9_endframe_residual() -> void:
	print("── ⑨ end_frame 兜底 ──")
	_release_field()
	_gl.enemy_grid.rebuild(_empty_items())
	DamagePipeline.OVERKILL_AGGREGATE = true
	_frame(true, 11)
	var e := _spawn_enemy(1.0e9, Vector2(360.0, 600.0))
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	var hp0: float = e.hp
	var b := _spawn_bullet(Vector2(360.0, 600.0))
	b._tick_fast_player(DT)
	_endframe()                                      # 不 dispatch——残组并入顺延
	_frame(true, 12)                                 # 帧头冲刷
	_dispatch()
	_check("end_frame 兜底零丢失（残组并入顺延后帧头冲刷落地）",
		absf(hp0 - e.hp - 10.0) < 0.0001, "%f" % (hp0 - e.hp))
	_endframe()


# ── ⑩ crit 期望守恒（统计带） ─────────────────────────────────────

func _test_10_crit_expectation() -> void:
	print("── ⑩ crit 期望守恒 ──")
	_release_field()
	_gl.enemy_grid.rebuild(_empty_items())
	var rounds := 240
	var totals := {"agg": 0.0, "plain": 0.0}
	for arm in ["agg", "plain"]:
		DamagePipeline.OVERKILL_AGGREGATE = arm == "agg"
		for i in rounds:
			_frame(true, 1000 + i)
			var e := _spawn_enemy(1.0e9, Vector2(360.0, 600.0))
			_gl.enemy_grid.rebuild(_gl.spawner.active)
			var hp0: float = e.hp
			# 双发 crit0.5 组（组均 2.46 的代表形态）
			for k in 2:
				var b := _spawn_bullet(Vector2(360.0, 600.0), 10.0, 0.5)
				b._tick_fast_player(DT)
			_dispatch()
			totals[arm] += hp0 - e.hp
			_endframe()
			_release_field()
			_gl.enemy_grid.rebuild(_empty_items())
	_check("crit0.5 双臂总伤害比值 ∈[0.9,1.1]（期望守恒统计带，%d 组/臂）" % rounds,
		totals["plain"] > 0.0 and absf(totals["agg"] / totals["plain"] - 1.0) <= 0.1,
		"agg=%f plain=%f ratio=%f" % [totals["agg"], totals["plain"],
			totals["agg"] / maxf(totals["plain"], 0.0001)])
	_check("套件总项数（EXPECTED=%d——R231 假绿教训：总项数也要断言）" % EXPECTED_TOTAL,
		_pass + _fail == EXPECTED_TOTAL, "实=%d" % (_pass + _fail))

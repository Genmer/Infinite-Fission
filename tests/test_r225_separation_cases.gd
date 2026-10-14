# tests/test_r225_separation_cases.gd
# R225 -4 全弃哨兵契约用例体（入口 test_r225_separation.gd 运行时 load——-s 编译期
# 禁引工程类名纪律，test_r223_settlebudget_cases 同构夹具）。覆盖：
# ① -4 全弃语义：通过三闸的提交全部丢弃并计数 separate_drop——零真结算（settles 不增/
#    零落血/不入派发队/无积压），返回零值占位（deferred_merge=true，调用方穿透消费面
#    同 -3 顺延占位）；
# ② separate_drop 计数口径：同帧同键重复命中折返 dropped_dupe（QA-2 先例——占位入幂
#    等缓存），不入 separate_drop；跨帧新提交各自弃各计（无积压合并）；
# ③ -1/-2/-3/≥0 既有语义零回归最小用例：headless 默认帽 0 真结算 / -2 强制关真结算 /
#    -3 tier 映射（2→96 / 3→0）+ 帽内真结算 / ≥0 强制帽超帽顺延（settle_deferred）。
# 锁机制契约（哨兵值→管线行为），不锁实现细节；夹具=r223_settlebudget_cases 同款
# （池化敌直驱管线、真武器零开火 MENU 态、全用例同步段零 await）。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null
var _released: Array[Enemy] = []


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(4225)
	_boot_game_loop()
	await tree.process_frame
	await tree.process_frame
	PerfGovernor.set_process(false)          # 引擎侧停走——用例手动直驱管线（确定性）
	_gl.state = GameConst.GameStatus.MENU    # 真武器零开火（结算直驱管线）
	_test_1_full_drop_basics()
	_test_2_drop_counting()
	_test_3_cross_frame_no_merge()
	_test_4_legacy_semantics_intact()
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
	_gl = tree.root.get_node_or_null("Main") as GameLoop
	if _gl == null:
		for c in tree.root.get_children():
			if c is GameLoop:
				_gl = c
				break


# ── 夹具（r223_settlebudget_cases 同款） ──────────────────────────

func _fixture_enemy(p_id: StringName, p_hp: float) -> EnemyData:
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


func _spawn_enemy(p_id: StringName, p_hp: float = 100000.0) -> Enemy:
	var pool := _gl.pools[&"enemy"] as EnemyPool
	var e := pool.acquire() as Enemy
	e.spawn(_fixture_enemy(p_id, p_hp), 1, 0)
	e._fade_left = 0.0
	e.modulate.a = 1.0
	_released.append(e)
	return e


func _release_all() -> void:
	var pool := _gl.pools[&"enemy"] as EnemyPool
	for e in _released:
		if is_instance_valid(e) and not e.dead:
			pool.release(e)
	_released.clear()


func _mk_ctx(p_source: int, p_target: Enemy, p_base: float, p_frame: int) -> DamageContext:
	var ctx := DamageContext.make()
	ctx.source_uid = p_source
	ctx.target_uid = p_target.uid
	ctx.target = p_target
	ctx.frame_stamp = p_frame
	ctx.base_atk = p_base
	ctx.crit_chance = 0.0
	ctx.crit_mult = 2.0
	ctx.pos = p_target.global_position
	return ctx


func _resolve(p_ctx: DamageContext) -> DamageResult:
	return _gl.pipeline.call(&"resolve", p_ctx) as DamageResult


func _stat(p_key: String) -> int:
	return int((_gl.pipeline.call(&"stats") as Dictionary).get(p_key, 0))


func _fifo_size() -> int:
	return (_gl.pipeline.get(&"_pending_fifo") as Array).size()


func _queue_size() -> int:
	return (_gl.pipeline.get(&"_resolved_queue") as Array).size()


func _reset_pipe_state() -> void:
	_gl.pipeline.get(&"_pending_pair").clear()
	(_gl.pipeline.get(&"_pending_fifo") as Array).clear()
	(_gl.pipeline.get(&"_resolved_queue") as Array).clear()


# ── ① -4 全弃语义 ─────────────────────────────────────────────────

func _test_1_full_drop_basics() -> void:
	print("── ① -4 全弃语义 ──")
	var e := _spawn_enemy(&"E_R225_A")
	var hp0 := e.hp
	DamagePipeline.settle_budget_override = -4
	var set0 := _stat("settles")
	var drop0 := _stat("separate_drop")
	var def0 := _stat("settle_deferred")
	_gl.pipeline.call(&"begin_frame", 1100)
	var results: Array[DamageResult] = []
	for i in 5:
		results.append(_resolve(_mk_ctx(8100 + i, e, 10.0, 1100)))
	var all_ph := true
	for r in results:
		if r == null or r.final_value != 0.0 or not r.deferred_merge or r.killed:
			all_ph = false
	_check("①五发全弃零值占位（final=0 · deferred_merge · killed=false）",
		all_ph, "")
	_check("①零真结算（settles 不增）", _stat("settles") == set0,
		"settles+%d" % (_stat("settles") - set0))
	_check("①零顺延（settle_deferred 不增——全弃≠顺延）",
		_stat("settle_deferred") == def0,
		"deferred+%d" % (_stat("settle_deferred") - def0))
	_check("①separate_drop 计数 +5", _stat("separate_drop") == drop0 + 5,
		"separate_drop=%d（期望 %d）" % [_stat("separate_drop"), drop0 + 5])
	_check("①占位不落血（hp 不变）", e.hp == hp0, "hp=%.1f（期望 %.1f）" % [e.hp, hp0])
	_check("①占位不入派发队（队列空）", _queue_size() == 0, "queue=%d" % _queue_size())
	_check("①无积压（FIFO 空）", _fifo_size() == 0, "fifo=%d" % _fifo_size())
	_gl.pipeline.call(&"end_frame")          # -4 帧末维护走通（-4 下积压恒空零扰动）
	DamagePipeline.settle_budget_override = -1
	_reset_pipe_state()


# ── ② separate_drop 计数口径（幂等折返不入计数） ──────────────────

func _test_2_drop_counting() -> void:
	print("── ② separate_drop 计数口径 ──")
	var e := _spawn_enemy(&"E_R225_B")
	DamagePipeline.settle_budget_override = -4
	var drop0 := _stat("separate_drop")
	var dupe0 := _stat("dropped_dupe")
	_gl.pipeline.call(&"begin_frame", 1200)
	var ra := _resolve(_mk_ctx(8200, e, 10.0, 1200))
	var rb := _resolve(_mk_ctx(8200, e, 10.0, 1200))   # 同帧同键重复：幂等折返占位
	_check("②占位入幂等缓存（折返同一占位实例——QA-2 同构）",
		ra != null and rb == ra and rb.deferred_merge, "")
	_check("②折返计 dupe 不计 drop（ra 新提交 drop+1 · rb 折返只计 dupe+1）",
		_stat("dropped_dupe") == dupe0 + 1 and _stat("separate_drop") == drop0 + 1,
		"dupe+%d drop=%d（期望 %d）" % [_stat("dropped_dupe") - dupe0,
			_stat("separate_drop"), drop0 + 1])
	_gl.pipeline.call(&"end_frame")
	DamagePipeline.settle_budget_override = -1
	_reset_pipe_state()


# ── ③ -4 跨帧无积压合并（每条提交各计） ───────────────────────────

func _test_3_cross_frame_no_merge() -> void:
	print("── ③ -4 跨帧无积压合并 ──")
	var e := _spawn_enemy(&"E_R225_C")
	DamagePipeline.settle_budget_override = -4
	var drop0 := _stat("separate_drop")
	_gl.pipeline.call(&"begin_frame", 1300)
	_resolve(_mk_ctx(8300, e, 10.0, 1300))
	_gl.pipeline.call(&"end_frame")
	_gl.pipeline.call(&"begin_frame", 1301)
	_resolve(_mk_ctx(8300, e, 15.0, 1301))   # 跨帧同对再中：新键（帧元变）→ 再弃再计
	_check("③跨帧新提交再弃再计（separate_drop +2 · 无积压合并 FIFO=0）",
		_stat("separate_drop") == drop0 + 2 and _fifo_size() == 0,
		"drop=%d（期望 %d）fifo=%d" % [_stat("separate_drop"), drop0 + 2, _fifo_size()])
	_gl.pipeline.call(&"end_frame")
	DamagePipeline.settle_budget_override = -1
	_reset_pipe_state()


# ── ④ -1/-2/-3/≥0 既有语义零回归（最小用例） ──────────────────────

func _test_4_legacy_semantics_intact() -> void:
	print("── ④ 既有语义零回归 ──")
	var e := _spawn_enemy(&"E_R225_D")
	# -1 headless 默认：帽 0 → 全真结算
	DamagePipeline.settle_budget_override = -1
	var set0 := _stat("settles")
	var hp0 := e.hp
	_gl.pipeline.call(&"begin_frame", 1400)
	var r1 := _resolve(_mk_ctx(8400, e, 10.0, 1400))
	_check("④-1 默认门帽 0 → 真结算（final>0 · 非占位 · 落血 10）",
		r1 != null and r1.final_value > 0.0 and not r1.deferred_merge
			and absf(e.hp - (hp0 - 10.0)) < 0.001 and _stat("settles") == set0 + 1,
		"hp=%.1f settles+%d" % [e.hp, _stat("settles") - set0])
	_gl.pipeline.call(&"end_frame")
	# -2 强制关：同语义
	DamagePipeline.settle_budget_override = -2
	_gl.pipeline.call(&"begin_frame", 1401)
	var r2 := _resolve(_mk_ctx(8401, e, 10.0, 1401))
	_check("④-2 强制关 → 真结算（final>0 · 落血）",
		r2 != null and r2.final_value > 0.0 and not r2.deferred_merge
			and e.hp < hp0 - 10.0, "hp=%.1f" % e.hp)
	_gl.pipeline.call(&"end_frame")
	# -3 模拟真机门：tier 映射 + 帽内真结算
	# R256 翻案：tier3 → 帽 0 是 R225 原口径——二cv#8 帧率决策已把 tier3 并入 tier2
	# 同帽 96（damage_pipeline.gd:463 注块「深载恰是削峰器最需要在场时」）；本套件
	# 根级手动档，并档批未同步此断言=静默过期（storm 断言① 同型第三现场）
	DamagePipeline.settle_budget_override = -3
	PerfGovernor.mode_override = 0
	PerfGovernor.tier_override = 3
	_check("④-3 tier3 → 帽 96（二cv#8 并档）", DamagePipeline._settle_cap_now() == 96, "")
	PerfGovernor.tier_override = 2
	_check("④-3 tier2 → 帽 96", DamagePipeline._settle_cap_now() == 96, "")
	_gl.pipeline.call(&"begin_frame", 1402)
	var r3 := _resolve(_mk_ctx(8402, e, 10.0, 1402))
	_check("④-3 帽内真结算照常（final>0 · 非占位）",
		r3 != null and r3.final_value > 0.0 and not r3.deferred_merge, "")
	_gl.pipeline.call(&"end_frame")
	PerfGovernor.mode_override = -1
	PerfGovernor.tier_override = -1
	# ≥0 强制帽：超帽顺延既有语义
	DamagePipeline.settle_budget_override = 1
	var def0 := _stat("settle_deferred")
	_gl.pipeline.call(&"begin_frame", 1403)
	_resolve(_mk_ctx(8403, e, 10.0, 1403))            # 帽内真结算（预算耗尽）
	var r4 := _resolve(_mk_ctx(8404, e, 10.0, 1403))  # 超帽：顺延占位
	_check("④≥0 强制帽超帽顺延（deferred_merge · settle_deferred+1 · FIFO=1）",
		r4 != null and r4.deferred_merge and _stat("settle_deferred") == def0 + 1
			and _fifo_size() == 1,
		"deferred+%d fifo=%d" % [_stat("settle_deferred") - def0, _fifo_size()])
	_gl.pipeline.call(&"end_frame")
	DamagePipeline.settle_budget_override = -1
	_reset_pipe_state()
	_check("④恢复默认后帽回 0（headless）", DamagePipeline._settle_cap_now() == 0, "")


func _cleanup() -> void:
	DamagePipeline.settle_budget_override = -1
	_reset_pipe_state()
	PerfGovernor.mode_override = -1
	PerfGovernor.tier_override = -1
	PerfGovernor.set_process(true)
	tree.paused = false
	_release_all()
	if _gl != null:
		_gl.queue_free()
		await tree.process_frame

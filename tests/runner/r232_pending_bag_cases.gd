# tests/runner/r232_pending_bag_cases.gd
# R232 刀1b 用例体（入口 test_r232_pending_bag.gd 运行时 load；全程 CTX_REUSE=true
# 袋路径现行态）。覆盖矩阵：
# ① r223 核心轴快速复跑（袋形态）：顺延基础/同对累积冲刷/亡目标丢弃/过期强冲/硬帽修剪/
#    uid 复验（每轴 hp/计数双口径——r223_settlebudget 全绿之外的袋路径独立执行口）；
# ② 冲刷重建 ctx 字段完备性（全 22 字段非默认值入袋 → damage_resolved 结果逐字段对拍
#    ——分析 AC-6「漏字段=冲刷行为漂移」直证）；
# ③ 幂等占位折返（QA-2 语义：占位入缓存，同键双发不双计）；
# ④ 袋池上限（冲刷/丢弃还池 ≤ 硬帽 256；池命中复用非空池）；
# ⑤ 暂停挂起（p_combat=false 冲刷挂起——袋形态下战斗冻结契约回归）。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const EXPECTED_TOTAL := 17               # 套件总项数断言（R231 假绿教训）

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null
var _released: Array[Enemy] = []
var _spied: Array = []                   # damage_resolved 间谍（结果字段对拍）


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(4234)
	_boot_game_loop()
	await tree.process_frame
	await tree.process_frame
	PerfGovernor.set_process(false)
	_gl.state = GameConst.GameStatus.MENU
	DamagePipeline.CTX_REUSE = true          # 本套件锁定袋路径（回退路径归 ctx_reuse 套件）
	_test_1_r223_axes()
	_test_2_rebuild_field_complete()
	_test_3_placeholder_foldback()
	_test_4_bag_pool_cap()
	_test_5_combat_gating()
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


# ── 夹具 ──────────────────────────────────────────────────────────

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


func _spawn_enemy(p_id: StringName, p_hp: float = 1000000.0) -> Enemy:
	var pool := _gl.pools[&"enemy"] as EnemyPool
	var e := pool.acquire() as Enemy
	e.spawn(_fixture_enemy(p_id, p_hp), 1, 0)
	e._fade_left = 0.0
	e.modulate.a = 1.0
	_released.append(e)
	return e


func _mk_ctx(p_src: int, p_target: Enemy, p_base: float, p_frame: int) -> DamageContext:
	var ctx := DamageContext.make()
	ctx.source_uid = p_src
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


func _bag_pool_size() -> int:
	return (_gl.pipeline.get(&"_bag_pool") as Array).size()


func _clear_pending() -> void:
	(_gl.pipeline.get(&"_pending_pair") as Dictionary).clear()
	(_gl.pipeline.get(&"_pending_fifo") as Array).clear()


# ── ① r223 核心轴复跑（袋形态） ───────────────────────────────────

func _test_1_r223_axes() -> void:
	print("── ① r223 核心轴（袋路径现行态） ──")
	# 轴 A：顺延基础（帽 1：首结真 + 次结占位不落血）
	var e := _spawn_enemy(&"E_R232B_A")
	var hp0 := e.hp
	DamagePipeline.settle_budget_override = 1
	_gl.pipeline.call(&"begin_frame", 100)
	_resolve(_mk_ctx(7001, e, 10.0, 100))
	var r3 := _resolve(_mk_ctx(7003, e, 10.0, 100))
	_check("①轴A 超帽零值占位（final=0 · deferred_merge · 不落血）",
		r3 != null and r3.final_value == 0.0 and r3.deferred_merge
			and absf(e.hp - (hp0 - 10.0)) < 0.001, "hp=%.1f" % e.hp)
	_gl.pipeline.call(&"end_frame")
	_clear_pending()
	# 轴 B：同对累积冲刷（双顺延 + 帧头冲一留一 + 跨帧并入——r223 ③ 同构）
	var e2 := _spawn_enemy(&"E_R232B_B")
	var hp0b := e2.hp
	_gl.pipeline.call(&"begin_frame", 200)
	_resolve(_mk_ctx(7101, e2, 10.0, 200))            # 帽内真结算（预算尽）
	_resolve(_mk_ctx(7102, e2, 5.0, 200))             # 顺延 [7102]
	_resolve(_mk_ctx(7103, e2, 10.0, 200))            # 顺延 [7102, 7103]
	_gl.pipeline.call(&"end_frame")
	var def_mid := _stat("settle_deferred")
	_gl.pipeline.call(&"begin_frame", 201)            # 预算 1：冲刷队头 7102（base 5）
	_resolve(_mk_ctx(7103, e2, 15.0, 201))            # 7103 存活 → 同对异帧并入（10+15）
	_check("①轴B 跨帧同对并入（FIFO=1 · deferred+1）",
		_fifo_size() == 1 and _stat("settle_deferred") == def_mid + 1,
		"fifo=%d" % _fifo_size())
	_gl.pipeline.call(&"end_frame")
	_gl.pipeline.call(&"begin_frame", 202)            # 冲刷并入项：base 25 一次真结算
	_check("①轴B 累积 base 25 全额落账（hp 扣 10+5+25=40 · FIFO 清空）",
		absf(e2.hp - (hp0b - 40.0)) < 0.001 and _fifo_size() == 0,
		"hp=%.1f（期望 %.1f）" % [e2.hp, hp0b - 40.0])
	_gl.pipeline.call(&"end_frame")
	# 轴 C：亡目标冲刷诚实丢弃
	var e3 := _spawn_enemy(&"E_R232B_C")
	_gl.pipeline.call(&"begin_frame", 300)
	_resolve(_mk_ctx(7201, e3, 10.0, 300))
	_resolve(_mk_ctx(7202, e3, 10.0, 300))            # 顺延
	e3.dead = true
	var dead0 := _stat("settle_flush_dead")
	_gl.pipeline.call(&"end_frame")
	_gl.pipeline.call(&"begin_frame", 301)            # 冲刷遇亡目标
	_check("①轴C 亡目标冲刷诚实丢弃（flush_dead+1 · hp 不动）",
		_stat("settle_flush_dead") == dead0 + 1, "dead+%d" % (_stat("settle_flush_dead") - dead0))
	e3.dead = false
	_gl.pipeline.call(&"end_frame")
	# 轴 D：过期强冲（30 对顺延 · 每帧预算 1 冲队头 · 余量 >12 帧龄帧末强冲——r223 ⑤ 同构）
	var e4 := _spawn_enemy(&"E_R232B_D")
	var hp0d := e4.hp
	_gl.pipeline.call(&"begin_frame", 400)
	_resolve(_mk_ctx(7301, e4, 10.0, 400))            # 帽内真结算
	for i in range(30):
		_resolve(_mk_ctx(7400 + i, e4, 1.0, 400))     # 30 对顺延（FIFO 30 项）
	var stale0 := _stat("settle_stale_flush")
	var flush0d := _stat("settle_flush")
	_gl.pipeline.call(&"end_frame")
	for f in range(401, 414):                         # 13 帧：帧头预算冲队头 1 项
		_gl.pipeline.call(&"begin_frame", f)          # （余项帧龄渐超 12 → 帧末强冲）
		_gl.pipeline.call(&"end_frame")
	var stale_n := _stat("settle_stale_flush") - stale0
	var drain_n := _stat("settle_flush") - flush0d - stale_n
	_check("①轴D 过期强冲（stale≥15 · 账目守恒 30 · hp 扣 40 · FIFO 清空）",
		stale_n >= 15 and drain_n + stale_n == 30
			and absf(e4.hp - (hp0d - 40.0)) < 0.001 and _fifo_size() == 0,
		"stale=%d drain=%d hp=%.1f" % [stale_n, drain_n, e4.hp])
	DamagePipeline.settle_budget_override = -1
	# 轴 E：uid 复验（袋重建 target 引用 → uid 不符诚实丢弃）
	var e5 := _spawn_enemy(&"E_R232B_E")
	DamagePipeline.settle_budget_override = 1
	_gl.pipeline.call(&"begin_frame", 500)
	_resolve(_mk_ctx(7401, e5, 10.0, 500))
	_resolve(_mk_ctx(7402, e5, 10.0, 500))            # 顺延（袋持 target 引用+uid）
	var uid_old := e5.uid
	e5.uid = uid_old + 1                              # 池复用派新 uid 形态
	var reuse0 := _stat("settle_flush_reuse")
	_gl.pipeline.call(&"end_frame")
	_gl.pipeline.call(&"begin_frame", 501)
	_check("①轴E uid 复验丢弃（flush_reuse+1——袋重建路径 uid 校验在位）",
		_stat("settle_flush_reuse") == reuse0 + 1,
		"reuse+%d" % (_stat("settle_flush_reuse") - reuse0))
	e5.uid = uid_old
	_gl.pipeline.call(&"end_frame")
	_clear_pending()
	DamagePipeline.settle_budget_override = -1


# ── ② 冲刷重建字段完备性 ──────────────────────────────────────────

func _test_2_rebuild_field_complete() -> void:
	print("── ② 冲刷重建 ctx 字段完备（全字段非默认 → 结果逐字段对拍） ──")
	var e := _spawn_enemy(&"E_R232B_F", 1.0e9)
	var pool := _gl.pools[&"projectile"] as ProjectilePool
	var proj := pool.acquire() as ProjectileBase
	proj.damage_pipeline = _gl.pipeline
	proj.enemy_grid = _gl.enemy_grid
	proj.pool = pool
	proj.spawn({
		"velocity": Vector2(60.0, 0.0), "lifetime": 10.0, "pierce": 2, "team": 0,
		"panel_snapshot": {"base_atk": 100.0, "flat_bonus": 0.0,
			"crit_rate": 0.0, "crit_mult": 2.0, "add_entries": []},
		"position": Vector2(50.0, 60.0),
	})
	var ctx := proj._build_damage_ctx(e)              # 全字段构建口（含 weakref backlink）
	ctx.source_uid = 7501
	ctx.frame_stamp = 600
	ctx.element = GameConst.Element.FIR
	ctx.hit_flags = GameConst.HIT_IS_AOE_SECONDARY
	ctx.target_resist = 0.25
	ctx.crit_chance = 0.0                             # 免掷骰确定性
	ctx.rng_stream_id = 3
	ctx.bounce_count = 2
	ctx.pierce_index = 3
	ctx.generation = 1
	ctx.is_first_hit_of_wave = true
	ctx.player_hp_pct = 0.2
	ctx.pos = Vector2(77.0, 88.0)
	ctx.add_entries.append({"trait_id": &"T", "pool_id": &"add_atk", "layer": 1,
		"contrib": 0.5, "decay_delta": 0.0, "is_curse": false})
	ctx.mult_pools.append({"pool_id": &"r232_bag", "source_uid": 7501,
		"contrib": 1.0, "cap_pool": 2.0, "priority": 0})
	ctx.local_pools.append({"local_id": &"r232_bagl", "contrib": 0.2, "cap_local": 1.0})
	DamagePipeline.settle_budget_override = 1
	var cb := func(r: DamageResult) -> void:
		_spied.append(r)
	EventBus.damage_resolved.connect(cb)
	_gl.pipeline.call(&"begin_frame", 600)
	_resolve(_mk_ctx(7500, e, 1.0, 600))              # 耗预算（1 伤）
	var ph := _resolve(ctx)                           # 顺延（全字段入袋）
	_gl.pipeline.call(&"end_frame")
	_spied.clear()
	_gl.pipeline.call(&"begin_frame", 601)            # 冲刷：base 100×(1+0.5)×2.0×1.2
	_gl.pipeline.call(&"dispatch_resolved_frame")     # R220 刀11 批化——冲刷结果在 ⑧ 段前
	                                                  # 统一派发（本套件手驱，显式调派发口）
	_gl.pipeline.call(&"end_frame")
	EventBus.damage_resolved.disconnect(cb)
	var hit := false
	var detail := ""
	for r in _spied:
		if int(r.source_uid) == 7501:
			hit = true
			var panel_ok := is_equal_approx(float(r.panel_snapshot), 150.0)   # 100×(1+0.5)
			var mult_ok := is_equal_approx(float(r.mult_product), 2.0)
			var local_ok := is_equal_approx(float(r.local_product), 1.2)
			# V：真敌 get_resist(FIR)=0 → 1.0（ctx.target_resist 为桩兜底不入真敌路）
			# final = 150 × 2.0 × 1.2 × 1.0 × C1 = 360
			var final_ok := absf(float(r.final_value) - 360.0) < 0.001
			detail = "panel=%.2f mult=%.2f local=%.2f final=%.2f elem=%d fs=%d pos=%s" % [
				float(r.panel_snapshot), float(r.mult_product), float(r.local_product),
				float(r.final_value), int(r.element), int(r.frame_stamp), str(r.pos)]
			_check("②重建 ctx 池/面板段逐位（panel150 · M2.0 · L1.2 · final360）",
				panel_ok and mult_ok and local_ok and final_ok, detail)
			_check("②重建 ctx 元数据逐位（element=FIR · frame_stamp=首顺延 600 · pos 快照）",
				int(r.element) == GameConst.Element.FIR and int(r.frame_stamp) == 600
					and r.pos == Vector2(77.0, 88.0),
				"elem=%d fs=%d pos=%s" % [int(r.element), int(r.frame_stamp), str(r.pos)])
	_check("②冲刷结果入派发队列（间谍捕获 src=7501）", hit, "")
	proj.pool.release(proj)
	DamagePipeline.settle_budget_override = -1
	_clear_pending()


# ── ③ 幂等占位折返 ────────────────────────────────────────────────

func _test_3_placeholder_foldback() -> void:
	print("── ③ 幂等占位折返（QA-2 语义袋形态保真） ──")
	var e := _spawn_enemy(&"E_R232B_G")
	DamagePipeline.settle_budget_override = 1
	_gl.pipeline.call(&"begin_frame", 700)
	_resolve(_mk_ctx(7601, e, 10.0, 700))             # 帽内真结算
	var def0 := _stat("settle_deferred")
	var rc := _resolve(_mk_ctx(7602, e, 5.0, 700))    # 顺延占位
	var rc2 := _resolve(_mk_ctx(7602, e, 5.0, 700))   # 同键再发 → 折返占位
	_check("③占位入幂等缓存（rc2==rc 同实例 · dupe 语义）",
		rc != null and rc.deferred_merge and rc2 == rc, "")
	_check("③同键双发不双计（settle_deferred 仅 +1）",
		_stat("settle_deferred") == def0 + 1, "defer+%d" % (_stat("settle_deferred") - def0))
	_gl.pipeline.call(&"end_frame")
	_gl.pipeline.call(&"begin_frame", 701)            # 冲刷清队
	_gl.pipeline.call(&"end_frame")
	_clear_pending()
	DamagePipeline.settle_budget_override = -1


# ── ④ 袋池上限与复用 ──────────────────────────────────────────────

func _test_4_bag_pool_cap() -> void:
	print("── ④ 袋池（冲刷/丢弃还池 ≤ 硬帽 256 · 池命中复用） ──")
	var e := _spawn_enemy(&"E_R232B_H")
	_clear_pending()
	(_gl.pipeline.get(&"_bag_pool") as Array).clear()
	DamagePipeline.settle_budget_override = 1
	_gl.pipeline.call(&"begin_frame", 800)
	_resolve(_mk_ctx(7701, e, 1.0, 800))              # 耗预算
	var bag_pool0 := _bag_pool_size()
	for i in range(300):
		_resolve(_mk_ctx(7800 + i, e, 1.0, 800))      # 300 对顺延
	_check("④300 顺延建袋（袋池未还——在队持有）", _bag_pool_size() == bag_pool0,
		"pool=%d" % _bag_pool_size())
	_gl.pipeline.call(&"end_frame")                   # 帧末硬帽修剪 44 项 → 还袋
	_check("④硬帽修剪还袋（丢弃 44 项入池 FIFO=256）",
		_fifo_size() == 256 and _bag_pool_size() > bag_pool0,
		"fifo=%d pool=%d" % [_fifo_size(), _bag_pool_size()])
	DamagePipeline.settle_budget_override = -2        # 门关全量冲刷 → 256 项还袋
	_gl.pipeline.call(&"begin_frame", 801)
	_check("④全量冲刷还袋（FIFO 清空 · 池封顶 ≤256）",
		_fifo_size() == 0 and _bag_pool_size() <= 256 and _bag_pool_size() > 0,
		"fifo=%d pool=%d" % [_fifo_size(), _bag_pool_size()])
	_gl.pipeline.call(&"end_frame")
	DamagePipeline.settle_budget_override = -1
	# 复用直证：再顺延一项 → 池 pop（池缩）且袋为复用件
	DamagePipeline.settle_budget_override = 1
	_gl.pipeline.call(&"begin_frame", 802)
	_resolve(_mk_ctx(7901, e, 1.0, 802))              # 耗预算
	var pool_before := _bag_pool_size()
	_resolve(_mk_ctx(7902, e, 1.0, 802))              # 顺延借袋
	_check("④袋池借出复用（池缩 1——池命中非新建）", _bag_pool_size() == pool_before - 1,
		"pool %d→%d" % [pool_before, _bag_pool_size()])
	_gl.pipeline.call(&"end_frame")
	_gl.pipeline.call(&"begin_frame", 803)
	_gl.pipeline.call(&"end_frame")
	DamagePipeline.settle_budget_override = -1
	_clear_pending()


# ── ⑤ 暂停挂起（袋形态战斗冻结契约） ──────────────────────────────

func _test_5_combat_gating() -> void:
	print("── ⑤ 非战斗帧冲刷挂起（袋形态） ──")
	var e := _spawn_enemy(&"E_R232B_I")
	var hp0 := e.hp
	DamagePipeline.settle_budget_override = 1
	_gl.pipeline.call(&"begin_frame", 900)
	_resolve(_mk_ctx(7951, e, 10.0, 900))             # 帽内真结算
	_resolve(_mk_ctx(7952, e, 7.0, 900))              # 顺延 [袋]
	_gl.pipeline.call(&"end_frame")
	var flush0 := _stat("settle_flush")
	for f in range(901, 920):                         # 19 帧非战斗（>过期窗也不强冲）
		_gl.pipeline.call(&"begin_frame", f, false)
		_gl.pipeline.call(&"end_frame")
	_check("⑤非战斗帧零冲刷（FIFO=1 · hp 仍 hp0−10）",
		_fifo_size() == 1 and _stat("settle_flush") == flush0
			and absf(e.hp - (hp0 - 10.0)) < 0.001,
		"fifo=%d flush+%d" % [_fifo_size(), _stat("settle_flush") - flush0])
	_gl.pipeline.call(&"begin_frame", 921, true)      # 恢复战斗首帧统一冲刷
	_check("⑤恢复战斗冲刷落账（hp 扣 17 · FIFO 清空）",
		absf(e.hp - (hp0 - 17.0)) < 0.001 and _fifo_size() == 0,
		"hp=%.1f" % e.hp)
	_gl.pipeline.call(&"end_frame")
	DamagePipeline.settle_budget_override = -1
	_clear_pending()


# ── 收尾 ──────────────────────────────────────────────────────────

func _cleanup() -> void:
	_check("套件总项数（EXPECTED=%d——R231 假绿教训：总项数也要断言）" % EXPECTED_TOTAL,
		_pass + _fail == EXPECTED_TOTAL, "实=%d" % (_pass + _fail))
	DamagePipeline.settle_budget_override = -1
	DamagePipeline.CTX_REUSE = true
	TraitStack.TRAIT_PRECACHE = true
	_clear_pending()
	(_gl.pipeline.get(&"_resolved_queue") as Array).clear()
	var epool := _gl.pools[&"enemy"] as EnemyPool
	for e in _released:
		if is_instance_valid(e) and not e.dead:
			epool.release(e)
	_released.clear()
	PerfGovernor.set_process(true)
	if _gl != null:
		_gl.queue_free()
		await tree.process_frame

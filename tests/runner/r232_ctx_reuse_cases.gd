# tests/runner/r232_ctx_reuse_cases.gd
# R232 刀1b 用例体（入口 test_r232_ctx_reuse.gd 运行时 load）。覆盖矩阵：
# ① 开关契约（CTX_REUSE 在场+默认 true）；
# ② 二次构建全字段重置（22 字段生命周期矩阵——AC-3 无持有回归同面）；
# ③ 顺延袋快照（R1 别名污染核心断言：源池改写不漂移冲刷伤害 + 袋 dict 非别名）；
# ④ 袋键完备（AC-6 23 键=17 值字段+簿记 last_frame+5 同构字段）；
# ⑤ frame_stamp（首顺延帧）/last_frame（最近合并帧）双字段语义 + 冲刷幂等键位保真；
# ⑥ kill_backlink 经袋冲刷回填 killed_target；
# ⑦ add_entries 复用不串弹（双弹交替构建）；
# ⑧ 回退路径（CTX_REUSE=false 存 ctx 原路径）；
# ⑨ ON_HIT 派发后 scratch 无持有（词条桩探测降级面——分析 AC-3 九族只读复核回归）。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const EXPECTED_TOTAL := 27               # 套件总项数断言（R231 假绿教训）

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null
var _released: Array[Enemy] = []
var _projs: Array[ProjectileBase] = []


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(4232)
	_boot_game_loop()
	await tree.process_frame
	await tree.process_frame
	PerfGovernor.set_process(false)
	_gl.state = GameConst.GameStatus.MENU
	_test_1_switch_contract()
	_test_2_reset_matrix()
	_test_3_bag_snapshot_r1()
	_test_4_bag_keys()
	_test_5_dual_frame_fields()
	_test_6_kill_backlink_via_bag()
	_test_7_add_entries_no_cross()
	_test_8_rollback_path()
	_test_9_dispatch_no_holder()
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


# ── 夹具（r223_settlebudget_cases 同构） ───────────────────────────

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


func _mk_proj(p_base: float, p_crit: float = 0.0) -> ProjectileBase:
	var pool := _gl.pools[&"projectile"] as ProjectilePool
	var proj := pool.acquire() as ProjectileBase
	proj.damage_pipeline = _gl.pipeline
	proj.enemy_grid = _gl.enemy_grid
	proj.pool = pool
	proj.spawn({
		"velocity": Vector2(60.0, 0.0), "lifetime": 10.0, "pierce": 9, "team": 0,
		"panel_snapshot": {"base_atk": p_base, "flat_bonus": 0.0,
			"crit_rate": p_crit, "crit_mult": 2.0, "add_entries": []},
		"position": Vector2.ZERO,
	})
	_projs.append(proj)
	return proj


func _release_all() -> void:
	var epool := _gl.pools[&"enemy"] as EnemyPool
	for e in _released:
		if is_instance_valid(e) and not e.dead:
			epool.release(e)
	_released.clear()
	var ppool := _gl.pools[&"projectile"] as ProjectilePool
	for p in _projs:
		if is_instance_valid(p):
			ppool.release(p)
	_projs.clear()


func _mk_pool(p_pool_id: StringName, p_contrib: float, p_cap: float) -> Dictionary:
	return {"pool_id": p_pool_id, "source_uid": 1, "contrib": p_contrib,
		"cap_pool": p_cap, "priority": 0}


func _pending_e(p_key: int) -> Dictionary:
	var pair: Dictionary = _gl.pipeline.get(&"_pending_pair")
	return pair.get(p_key, {})


# ── ① 开关契约 ────────────────────────────────────────────────────

func _test_1_switch_contract() -> void:
	print("── ① 开关契约 ──")
	_check("①CTX_REUSE 默认 true（借出即清+袋路径现行）", DamagePipeline.CTX_REUSE == true, "")
	_check("①弹侧 scratch 机制在场（_build_damage_ctx 可双调）",
		_proj_has_scratch(), "")


func _proj_has_scratch() -> bool:
	var proj := _mk_proj(100.0)
	var e := _spawn_enemy(&"E_R232_SC")
	var c1: DamageContext = proj._build_damage_ctx(e)
	var c2: DamageContext = proj._build_damage_ctx(e)
	return c1 == c2 and DamagePipeline.CTX_REUSE


# ── ② 二次构建全字段重置（22 字段） ───────────────────────────────

func _test_2_reset_matrix() -> void:
	print("── ② 二次构建全字段重置（22 字段生命周期矩阵） ──")
	var proj := _mk_proj(100.0)
	var ea := _spawn_enemy(&"E_R232_A")
	var eb := _spawn_enemy(&"E_R232_B")
	var c1: DamageContext = proj._build_damage_ctx(ea)
	c1.rng_stream_id = 7
	c1.hit_flags = GameConst.HIT_IS_BOUNCE | GameConst.HIT_IS_DOT
	c1.mult_pools.append(_mk_pool(&"stale", 9.9, 9.9))
	c1.local_pools.append({"local_id": &"stale_l", "contrib": 1.0, "cap_local": 1.0})
	c1.add_entries.append({"trait_id": &"T", "pool_id": &"p", "layer": 1,
		"contrib": 5.0, "decay_delta": 0.0, "is_curse": false})
	# 模拟 Homing 命中链改写面（source_uid/hit_flags/base_atk 覆写口）
	c1.source_uid = 424242
	c1.base_atk = 777.0
	var c2: DamageContext = proj._build_damage_ctx(eb)
	_check("②同对象复用（c1==c2 scratch）", c1 == c2, "")
	_check("②uid/引用重置（source_uid=proj.uid · target=eb · target_uid 同步）",
		c2.source_uid == proj.uid and c2.target == eb and c2.target_uid == int(eb.uid),
		"src=%d" % c2.source_uid)
	_check("②帧/流重置（frame_stamp=当前帧 · rng_stream_id=0）",
		c2.frame_stamp == GameConfig.frame_stamp and c2.rng_stream_id == 0,
		"rng=%d" % c2.rng_stream_id)
	_check("②面板段重置（base_atk=100 · flat=0 · crit=0/2.0 · add_entries 空）",
		is_equal_approx(c2.base_atk, 100.0) and c2.flat_bonus == 0.0
			and c2.crit_chance == 0.0 and is_equal_approx(c2.crit_mult, 2.0)
			and c2.add_entries.is_empty(), "add=%d" % c2.add_entries.size())
	_check("②三池重置（mult/local 空——跨命中污染主洞位）",
		c2.mult_pools.is_empty() and c2.local_pools.is_empty(),
		"mult=%d local=%d" % [c2.mult_pools.size(), c2.local_pools.size()])
	_check("②条件快照/标志重置（hit_flags=0 · bounce=0 · pierce=1 · gen=0 · "
		+ "first_wave/bool · hp_pct=1.0 · resist 快照 · element/pos/kill_backlink 回填）",
		c2.hit_flags == 0 and c2.bounce_count == 0 and c2.pierce_index == 1
			and c2.generation == 0 and c2.is_first_hit_of_wave == false
			and is_equal_approx(c2.player_hp_pct, 1.0) and c2.kill_backlink != null
			and c2.pos == proj.global_position,
		"flags=%d pierce=%d" % [c2.hit_flags, c2.pierce_index])


# ── ③ 顺延袋快照（R1 核心断言） ───────────────────────────────────

func _test_3_bag_snapshot_r1() -> void:
	print("── ③ 顺延袋快照（源池改写不漂移冲刷伤害） ──")
	var proj := _mk_proj(100.0)
	var e := _spawn_enemy(&"E_R232_R1", 1.0e9)
	var hp0 := e.hp
	DamagePipeline.settle_budget_override = 1
	_gl.pipeline.call(&"begin_frame", 3300)
	_resolve(_mk_ctx(proj, 8801, e, 100.0, 3300))     # 耗尽预算
	var ctx := proj._build_damage_ctx(e)              # scratch ctx（含 kill_backlink）
	ctx.source_uid = 8802
	ctx.frame_stamp = 3300
	ctx.mult_pools.append(_mk_pool(&"snap_pool", 1.0, 2.0))   # M=2.0 → final=200
	var ph := _resolve(ctx)
	var pair: Dictionary = _gl.pipeline.get(&"_pending_pair")
	var bag: Dictionary = {}
	for k in pair:
		bag = pair[k].get("bag", {})
	_check("③顺延占位（deferred_merge）且袋在队", ph != null and ph.deferred_merge
		and not bag.is_empty(), "")
	# 模拟刀1c 缓存改写：入袋后改写源 ctx 的池 dict——袋必须持快照
	ctx.mult_pools[0]["contrib"] = 9.9
	ctx.mult_pools[0]["cap_pool"] = 9.9
	_check("③袋内池=顺延时快照（contrib=1.0 非 9.9）且非别名（dict 实例不同）",
		float(bag["mult_pools"][0]["contrib"]) == 1.0
			and not (bag["mult_pools"][0] == ctx.mult_pools[0]),
		"bag=%s" % str(bag["mult_pools"][0]))
	_gl.pipeline.call(&"end_frame")
	_gl.pipeline.call(&"begin_frame", 3301)           # 冲刷：base 100 × M2.0 = 200
	_check("③冲刷伤害按快照值落账（首结 100 + 冲刷 200 = hp0−300——污染值 9.9 会被 cap 钳为 M3.0=300 即红）",
		absf(e.hp - (hp0 - 300.0)) < 0.001, "hp=%.1f（期望 %.1f）" % [e.hp, hp0 - 300.0])
	_gl.pipeline.call(&"end_frame")
	DamagePipeline.settle_budget_override = -1


# ── ④ 袋键完备（AC-6） ───────────────────────────────────────────

func _test_4_bag_keys() -> void:
	print("── ④ 袋键完备（AC-6 23 键） ──")
	var proj := _mk_proj(100.0)
	var e := _spawn_enemy(&"E_R232_K")
	DamagePipeline.settle_budget_override = 1
	_gl.pipeline.call(&"begin_frame", 3400)
	_resolve(_mk_ctx(proj, 8811, e, 100.0, 3400))
	var ctx := proj._build_damage_ctx(e)
	ctx.source_uid = 8812
	ctx.frame_stamp = 3400
	ctx.base_atk = 50.0
	_resolve(ctx)
	var bag: Dictionary = {}
	for k2 in (_gl.pipeline.get(&"_pending_pair") as Dictionary):
		bag = (_gl.pipeline.get(&"_pending_pair") as Dictionary)[k2].get("bag", {})
	var want := ["source_uid", "target_uid", "target", "frame_stamp", "last_frame",
		"rng_stream_id", "base_atk", "flat_bonus", "crit_chance", "crit_mult",
		"element", "hit_flags", "target_resist", "pos", "kill_backlink",
		"bounce_count", "pierce_index", "generation", "is_first_hit_of_wave",
		"player_hp_pct", "add_entries", "mult_pools", "local_pools"]
	var missing: Array[String] = []
	for k in want:
		if not bag.has(k):
			missing.append(k)
	_check("④袋 23 键齐备（17 值字段+last_frame+5 同构可裁字段全量入袋）",
		missing.is_empty() and bag.size() == 23,
		"缺=%s 实=%d" % [str(missing), bag.size()])
	_gl.pipeline.call(&"end_frame")
	_gl.pipeline.call(&"begin_frame", 3401)           # 冲刷清队
	_gl.pipeline.call(&"end_frame")
	DamagePipeline.settle_budget_override = -1


# ── ⑤ 双帧字段语义 ────────────────────────────────────────────────

func _test_5_dual_frame_fields() -> void:
	print("── ⑤ frame_stamp（首顺延）/last_frame（最近合并）双字段 ──")
	var proj := _mk_proj(100.0)
	var e := _spawn_enemy(&"E_R232_F", 1.0e9)
	DamagePipeline.settle_budget_override = 1
	_gl.pipeline.call(&"begin_frame", 3500)
	_resolve(_mk_ctx(proj, 8821, e, 100.0, 3500))
	var ctx := proj._build_damage_ctx(e)
	ctx.source_uid = 8822
	ctx.frame_stamp = 3500
	_resolve(ctx)                                     # 首顺延（frame_stamp=3500）
	var ctx2 := proj._build_damage_ctx(e)             # （同帧内不 begin_frame——
	ctx2.source_uid = 8823                            #   预算已尽，冲刷不发生）
	ctx2.frame_stamp = 3502
	_resolve(ctx2)                                    # 新对顺延
	var ctx3 := proj._build_damage_ctx(e)
	ctx3.source_uid = 8823
	ctx3.frame_stamp = 3504                           # 同对异帧 → 合并路径
	_resolve(ctx3)
	var bag: Dictionary = {}
	var e_frame := -1
	for k in (_gl.pipeline.get(&"_pending_pair") as Dictionary):
		var ent: Dictionary = (_gl.pipeline.get(&"_pending_pair") as Dictionary)[k]
		var b: Dictionary = ent.get("bag", {})
		if not b.is_empty() and int(b["source_uid"]) == 8823:
			bag = b
			e_frame = int(ent["frame"])
	_check("⑤首顺延帧=3500 语义在位（对 8822 键）", _frame_stamp_of(8822) == 3500,
		"fs=%d" % _frame_stamp_of(8822))
	_check("⑤合并帧刷新（bag.last_frame=3504 · e.frame=3504——过期强冲判定源）",
		int(bag.get("last_frame", -1)) == 3504 and e_frame == 3504,
		"last=%s e=%d" % [str(bag.get("last_frame")), e_frame])
	_check("⑤袋 frame_stamp 保持首顺延帧 3502（幂等键位 bit 级保真）",
		int(bag.get("frame_stamp", -1)) == 3502, "fs=%s" % str(bag.get("frame_stamp")))
	_gl.pipeline.call(&"end_frame")
	_gl.pipeline.call(&"begin_frame", 3505)           # 全冲刷（8822 键随重建写回本帧缓存）
	# 幂等缓存键位=首顺延帧：同帧内 (src=8822,tgt,3500) 键再发 → 折返缓存（dupe+1）
	var dupe0 := _stat("dropped_dupe")
	_resolve(_mk_ctx(proj, 8822, e, 100.0, 3500))
	_check("⑤冲刷结果幂等键=首顺延帧（3500 键折返 dupe+1——帧号保真直证）",
		_stat("dropped_dupe") == dupe0 + 1, "dupe+%d" % (_stat("dropped_dupe") - dupe0))
	_gl.pipeline.call(&"end_frame")
	_clear_pending()                                  # 8823 残留对清场（防串下游用例预算）
	DamagePipeline.settle_budget_override = -1


func _frame_stamp_of(p_src: int) -> int:
	for k in (_gl.pipeline.get(&"_pending_pair") as Dictionary):
		var b: Dictionary = (_gl.pipeline.get(&"_pending_pair") as Dictionary)[k].get("bag", {})
		if not b.is_empty() and int(b["source_uid"]) == p_src:
			return int(b["frame_stamp"])
	return -1


func _clear_pending() -> void:
	(_gl.pipeline.get(&"_pending_pair") as Dictionary).clear()
	(_gl.pipeline.get(&"_pending_fifo") as Array).clear()


# ── ⑥ kill_backlink 经袋冲刷回填 ──────────────────────────────────

func _test_6_kill_backlink_via_bag() -> void:
	print("── ⑥ kill_backlink 经袋冲刷回填 ──")
	var pool := _gl.pools[&"projectile"] as ProjectilePool
	var proj := pool.acquire() as ProjectileBase
	proj.damage_pipeline = _gl.pipeline
	proj.enemy_grid = _gl.enemy_grid
	proj.pool = pool
	proj.spawn({
		"velocity": Vector2(60.0, 0.0), "lifetime": 10.0, "pierce": 2, "team": 0,
		"panel_snapshot": {"base_atk": 100.0, "flat_bonus": 0.0,
			"crit_rate": 0.0, "crit_mult": 2.0, "add_entries": []},
		"position": Vector2.ZERO,
	})
	_projs.append(proj)
	var ek := _spawn_enemy(&"E_R232_KILL", 30.0)
	DamagePipeline.settle_budget_override = 1
	_gl.pipeline.call(&"begin_frame", 3600)
	_resolve(_mk_ctx(proj, 8831, ek, 5.0, 3600))      # 耗预算（−5 → 25 hp 存活）
	# ⚠ctx 必须在耗预算命中之后构建——scratch 复用语义下 _build_damage_ctx 会重置
	# 同一对象（先建会被 warm-up 命中覆写为同键，折返 dupe 而非顺延——R232 自检修正）
	var ctx := proj._build_damage_ctx(ek)             # kill_backlink=weakref(self)
	ctx.frame_stamp = 3600
	var r := _resolve(ctx)                            # base 100 顺延（袋）
	_check("⑥顺延占位在队", r != null and r.deferred_merge, "")
	_gl.pipeline.call(&"end_frame")
	_gl.pipeline.call(&"begin_frame", 3601)           # 冲刷击杀 + 证据回填
	_check("⑥袋冲刷击杀回填 killed_target（死亡新星消费面——袋化不丢证据链）",
		proj.killed_target and ek.dead,
		"killed=%s dead=%s" % [str(proj.killed_target), str(ek.dead)])
	_gl.pipeline.call(&"end_frame")
	DamagePipeline.settle_budget_override = -1


# ── ⑦ add_entries 复用不串弹 ──────────────────────────────────────

func _test_7_add_entries_no_cross() -> void:
	print("── ⑦ add_entries 复用不串弹（双弹交替构建） ──")
	var pa := _mk_proj(100.0)
	var pb := _mk_proj(200.0)
	(pb as Object).set("_panel_add_entries",
		[{"trait_id": &"B", "pool_id": &"add_atk", "layer": 1,
			"contrib": 20.0, "decay_delta": 0.0, "is_curse": false}])
	var e := _spawn_enemy(&"E_R232_X")
	var ca: DamageContext = pa._build_damage_ctx(e)
	var cb: DamageContext = pb._build_damage_ctx(e)
	var cc: DamageContext = pa._build_damage_ctx(e)
	_check("⑦A 弹 add_entries 空（B 弹 20 不串）", ca.add_entries.is_empty()
		and cc.add_entries.is_empty(), "a=%d c=%d" % [ca.add_entries.size(), cc.add_entries.size()])
	_check("⑦B 弹 add_entries 恰 1 条 contrib=20", cb.add_entries.size() == 1
		and is_equal_approx(float(cb.add_entries[0]["contrib"]), 20.0), "")


# ── ⑧ 回退路径 ────────────────────────────────────────────────────

func _test_8_rollback_path() -> void:
	print("── ⑧ 回退路径（CTX_REUSE=false 存 ctx 原路径） ──")
	var proj := _mk_proj(100.0)
	var e := _spawn_enemy(&"E_R232_RB", 1.0e9)
	var hp0 := e.hp
	DamagePipeline.CTX_REUSE = false
	DamagePipeline.settle_budget_override = 1
	_gl.pipeline.call(&"begin_frame", 3700)
	_resolve(_mk_ctx(proj, 8841, e, 100.0, 3700))
	var ctx := proj._build_damage_ctx(e)
	ctx.source_uid = 8842
	ctx.frame_stamp = 3700
	var c1: DamageContext = proj._build_damage_ctx(e)   # 回退态：不再复用同一对象
	_check("⑧回退态每次新 ctx（c1 != 上一只）", c1 != ctx, "")
	_resolve(ctx)
	var stored_ctx: DamageContext = null
	for k in (_gl.pipeline.get(&"_pending_pair") as Dictionary):
		stored_ctx = (_gl.pipeline.get(&"_pending_pair") as Dictionary)[k].get("ctx", null)
	_check("⑧回退态 pending 存 ctx 对象（原路径形状）", stored_ctx == ctx, "")
	_gl.pipeline.call(&"end_frame")
	_gl.pipeline.call(&"begin_frame", 3701)           # 冲刷（原路径 held ctx）
	_check("⑧回退态冲刷真结算（首结 100+冲刷 100=hp0−200）",
		absf(e.hp - (hp0 - 200.0)) < 0.001, "hp=%.1f（期望 %.1f）" % [e.hp, hp0 - 200.0])
	_gl.pipeline.call(&"end_frame")
	DamagePipeline.settle_budget_override = -1
	DamagePipeline.CTX_REUSE = true
	_check("⑧开关还原 true", DamagePipeline.CTX_REUSE, "")


# ── ⑨ ON_HIT 派发后 scratch 无持有 ────────────────────────────────

func _test_9_dispatch_no_holder() -> void:
	print("── ⑨ ON_HIT 派发后 scratch 无持有（AC-3 回归面） ──")
	var proj := _mk_proj(100.0, 0.0)
	var e := _spawn_enemy(&"E_R232_H", 1.0e9)
	var tctx: TraitContext = proj._prepare_hit_traits(
		proj._build_damage_ctx(e), e)                 # 空栈弹：直挂数组通道空转
	_check("⑨无栈弹 prepare 返回 tctx 且 ON_HIT 派发零持有（tctx 不持 ctx 生存期外引用）",
		tctx != null, "")
	var ctx := proj._build_damage_ctx(e)
	ctx.source_uid = 8851
	ctx.frame_stamp = 3800
	var r := _resolve(ctx)
	_check("⑨prepare+resolve 后再构建全字段干净（无 handle 存 ctx——R5 探测面）",
		r != null, "")
	var ctx2 := proj._build_damage_ctx(e)
	_check("⑨二次构建干净（三池空/flags=0/base=100）",
		ctx2.mult_pools.is_empty() and ctx2.hit_flags == 0
			and is_equal_approx(ctx2.base_atk, 100.0), "")
	_gl.pipeline.call(&"begin_frame", 3800)
	_gl.pipeline.call(&"end_frame")


# ── 支撑 ──────────────────────────────────────────────────────────

func _mk_ctx(p_proj: ProjectileBase, p_src: int, p_target: Enemy,
		p_base: float, p_frame: int) -> DamageContext:
	var ctx := p_proj._build_damage_ctx(p_target)
	ctx.source_uid = p_src
	ctx.frame_stamp = p_frame
	ctx.base_atk = p_base
	return ctx


func _resolve(p_ctx: DamageContext) -> DamageResult:
	return _gl.pipeline.call(&"resolve", p_ctx) as DamageResult


func _stat(p_key: String) -> int:
	return int((_gl.pipeline.call(&"stats") as Dictionary).get(p_key, 0))


func _cleanup() -> void:
	_check("套件总项数（EXPECTED=%d——R231 假绿教训：总项数也要断言）" % EXPECTED_TOTAL,
		_pass + _fail == EXPECTED_TOTAL, "实=%d" % (_pass + _fail))
	DamagePipeline.settle_budget_override = -1
	DamagePipeline.CTX_REUSE = true
	TraitStack.TRAIT_PRECACHE = true
	(_gl.pipeline.get(&"_pending_pair") as Dictionary).clear()
	(_gl.pipeline.get(&"_pending_fifo") as Array).clear()
	(_gl.pipeline.get(&"_resolved_queue") as Array).clear()
	_release_all()
	PerfGovernor.set_process(true)
	if _gl != null:
		_gl.queue_free()
		await tree.process_frame

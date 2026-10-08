# tests/runner/qa_r220_simchain_cases.gd
# QA-R220 独立探针用例体（不依赖实施者 r220_simchain_cases 的断言路径，独立取证）。
# ⓪ 契约源锚：十六段序/开关常量/R220_COUNTER_KEYS/日志头口径串/sfx λ 第五订阅者。
# ① 刀3①：W1 面板 crit<0.35 + 弹累计反弹≥阈值 → bank_shot_gold 达线置 ctx.crit=1.0，
#    EF_CRIT_SHARD 直发段触发不降（bank-shot 保真专项）+ 阈值-1 边界不触发 + 无声明武器闸拦截。
# ② 刀8③：audit 跨命中无污染——主通道 resolve 连续三命中（ModifierStack 复用件），
#    首结果 audit 快照（实例/ratio）不被后续命中改写。
# ③ 刀8④：erase O(1) 后倒序遍历回收契约——tick 内它弹回收 + 同帧复用件（LIFO 池）出生帧
#    tick 语义 + force_recycle_oldest 插入序取最老 + 索引一致性。
# ④ 刀9：敌弹快路径与原路径逐位等价——判据矩阵 8 项/寿命同帧同原因/位置逐位/出界/撞玩家。
# ⑤ 刀11：完整 _physics_process 帧端到端——⑧段前派发（跳字当帧可读）+ HUD 累计==派发总额。
# ⑥ 刀1：模N=物理帧差分÷墙钟窗 + 跨窗 `*` 标记 + LEVEL_UP 节拍不消费（采样序端到端）。
# ⑦ 刀1：结N PLAYING 期>0（弹段结算链端到端）/ 自导N 池联动。
# ⑧ 刀4：r210 双轨桩运行时——非 Enemy 桩走 else Variant 路径全链（get_resist/dead/
#    try_reflect/take_result）存活。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const DT := 1.0 / 60.0
const EPS := 0.000001

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null
var _spy_hits: Array[Vector2] = []              # EventBus.damage_resolved spy（x=source_uid,y=final_value）
var _spy_cb: Callable


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_boot_game_loop()
	await tree.process_frame
	await tree.process_frame
	_spy_cb = func(r: DamageResult) -> void: _spy_hits.append(Vector2(float(r.source_uid), r.final_value))
	EventBus.damage_resolved.connect(_spy_cb)
	_test_0_contract_anchors()
	_test_1_bank_shot_fidelity()
	_test_2_audit_no_pollution()
	_test_3_snapshot_recycle_contract()
	_test_4_fast_path_equivalence()
	_test_5_full_frame_batched()
	_test_6_sim_hz_sampling()
	_test_7_settles_homing()
	_test_8_stub_dual_track()
	EventBus.damage_resolved.disconnect(_spy_cb)
	_teardown_game_loop()
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


func _teardown_game_loop() -> void:
	if _gl != null:
		_gl.queue_free()
		await tree.process_frame


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


func _spawn_enemy(p_id: StringName, p_hp: float = 100000.0) -> Enemy:
	var pool := _gl.pools[&"enemy"] as EnemyPool
	var e := pool.acquire() as Enemy
	e.spawn(_fixture_enemy(p_id, p_hp), 1, 0)
	e._fade_left = 0.0
	e.modulate.a = 1.0
	return e


func _release_enemy(p_e: Enemy) -> void:
	(_gl.pools[&"enemy"] as EnemyPool).release(p_e)


func _w1() -> WeaponBase:
	return _gl.player.weapon_slots[0] as WeaponBase


func _proj_pool() -> ProjectilePool:
	return _gl.pools[&"projectile"] as ProjectilePool


func _spawn_player_bullet(p_weapon: WeaponBase, p_crit: float, p_pos: Vector2,
		p_velocity: Vector2 = Vector2(60.0, 0.0)) -> ProjectileBase:
	var pool := _proj_pool()
	var proj := pool.acquire()
	proj.damage_pipeline = _gl.pipeline
	proj.enemy_grid = _gl.enemy_grid
	proj.pool = pool
	proj.spawn({
		"velocity": p_velocity, "lifetime": 10.0, "pierce": 1, "team": 0,
		"weapon_ref": p_weapon,
		"panel_snapshot": {
			"base_atk": 10.0, "flat_bonus": 0.0,
			"crit_rate": p_crit, "crit_mult": 2.0, "add_entries": [],
		},
		"position": p_pos,
	})
	return proj


func _spawn_enemy_bullet(p_pos: Vector2, p_vel: Vector2, p_lifetime: float,
		p_base_atk: float, p_extra: Dictionary = {}) -> ProjectileBase:
	# 敌弹夹具（team=1；p_extra 覆盖域外参数用于判据矩阵——PR 检查单回归面）
	var pool := _proj_pool()
	var proj := pool.acquire()
	proj.damage_pipeline = _gl.pipeline
	proj.enemy_grid = _gl.enemy_grid
	proj.pool = pool
	var params: Dictionary = {
		"velocity": p_vel, "lifetime": p_lifetime, "pierce": 1, "team": 1,
		"panel_snapshot": {"base_atk": p_base_atk}, "position": p_pos,
	}
	params.merge(p_extra, true)
	proj.spawn(params)
	return proj


func _release_bullet(p_b: ProjectileBase) -> void:
	# is_clean 守卫：命中链内已被 _recycle 归还的弹不再二次 release（池拦截噪声）
	if p_b != null and is_instance_valid(p_b) and not p_b.is_clean:
		_proj_pool().release(p_b)


func _clear_projectiles() -> void:
	var pool := _proj_pool()
	for n in pool.active_projectiles().duplicate():
		if is_instance_valid(n):
			pool.release(n)


func _make_ctx(p_source: int, p_target: Node2D, p_base: float, p_crit: float,
		p_contrib: float = 0.0) -> DamageContext:
	var ctx := DamageContext.make()
	ctx.source_uid = p_source
	ctx.target_uid = int(p_target.get("uid"))
	ctx.target = p_target
	ctx.frame_stamp = GameConfig.frame_stamp
	ctx.base_atk = p_base
	ctx.crit_chance = p_crit
	ctx.crit_mult = 2.0
	ctx.pos = p_target.global_position
	if p_contrib > 0.0:
		ctx.mult_pools.append({
			"pool_id": &"qa_r220_mult", "source_uid": p_source,
			"contrib": p_contrib, "cap_pool": p_contrib, "priority": 0,
		})
	return ctx


func _pool_index_consistent(p_pool: ProjectilePool) -> bool:
	var idx_map: Dictionary = p_pool.get("_active_index")
	var act := p_pool.active_projectiles()
	for i in act.size():
		if int(idx_map.get(act[i], -1)) != i:
			return false
	return idx_map.size() == act.size()


# ── ⓪ 契约源锚 ────────────────────────────────────────────────────

func _test_0_contract_anchors() -> void:
	print("── ⓪ 契约源锚 ──")
	var order_expect: Array[StringName] = [
		&"player", &"player_mv", &"player_wp", &"shard", &"grid_rebuild", &"grid_projectile",
		&"enemy", &"wave", &"feel_shard", &"feel", &"fx", &"popup", &"ui",
		&"card_open", &"card_drain", &"other",
	]
	_check("⓪十六段冻结序（独立构造比对）+ size==16",
		DebugStats.DIAG_STAGE_ORDER == order_expect and DebugStats.DIAG_STAGE_ORDER.size() == 16,
		str(DebugStats.DIAG_STAGE_ORDER))
	_check("⓪TAGS：开/消/他 三标签在位（card 键已拆）",
		str(DebugStats.DIAG_STAGE_TAGS.get(&"card_open", "")) == "开"
			and str(DebugStats.DIAG_STAGE_TAGS.get(&"card_drain", "")) == "消"
			and str(DebugStats.DIAG_STAGE_TAGS.get(&"other", "")) == "他"
			and not DebugStats.DIAG_STAGE_TAGS.has(&"card"),
		str(DebugStats.DIAG_STAGE_TAGS))
	var keys_expect: Array[StringName] = [&"fit_desc_measures", &"quota_deferred", &"quota_dropped"]
	_check("⓪R220_COUNTER_KEYS 审计块三键（主控冻结名单）",
		DebugStats.R220_COUNTER_KEYS == keys_expect, str(DebugStats.R220_COUNTER_KEYS))
	var src_gl: String = FileAccess.get_file_as_string("res://scripts/loop/game_loop.gd")
	var src_dp: String = FileAccess.get_file_as_string("res://scripts/core/damage/damage_pipeline.gd")
	_check("⓪三开关常量在位且 true（刀5/9/11 回滚口）",
		src_gl.contains("const ENEMY_BULLET_FAST_PATH := true")
			and src_dp.contains("const DAMAGE_RESOLVED_BATCHED := true")
			and src_dp.contains("const REUSE_MODIFIER_STACK := true"), "")
	var src_ds: String = FileAccess.get_file_as_string("res://autoload/debug_stats.gd")
	_check("⓪日志头：『采样 1Hz × %d 行环形』子串保持（r212_diaglog2 锁）",
		src_ds.contains("采样 1Hz × %d 行环形"), "")
	_check("⓪日志头：十六段/模N 新口径/`*` 标记/⑧段前派发 四声明在位",
		src_ds.contains("段序=十六段") and src_ds.contains("模N=物理帧差分×1000÷实际采样墙钟窗")
			and src_ds.contains("模值带 * 供判读剔除") and src_ds.contains("派发时点=⑧ UI 段前统一保序批化"), "")
	_check("⓪sfx λ 第五订阅者在 game_loop（§8 裁定#4——不在 sfx_bank）",
		src_gl.contains("EventBus.damage_resolved.connect(func"), "")
	_check("⓪行尾段格式源锚：` 结%d 自%d 调%d`（追加在 ri 之后——既有子串逐位保持）",
		src_ds.contains("\" 结%d 自%d 调%d\""), "")


# ── ① 刀3①：bank-shot 保真专项 ───────────────────────────────────

func _test_1_bank_shot_fidelity() -> void:
	print("── ① bank-shot 保真 ──")
	var w1 := _w1()
	var th_bank: Dictionary = w1.get_threshold(&"TH_BANK_SHOT")
	var th_crit: Dictionary = w1.get_threshold(&"TH_CRIT_SHARD")
	var bank_th: float = float(th_bank.get("threshold", 12.0))
	var shard_th: float = float(th_crit.get("threshold", 0.6))
	_check("①前置：W1 双声明在位（bank 阈值=%.0f / crit 阈值=%.2f）" % [bank_th, shard_th],
		not th_bank.is_empty() and not th_crit.is_empty(),
		"bank=%s crit=%s" % [str(th_bank.is_empty()), str(th_crit.is_empty())])
	var e_main := _spawn_enemy(&"E_QA220_BANK_MAIN")
	e_main.position = Vector2(500, 600)
	var e_near := _spawn_enemy(&"E_QA220_BANK_NEAR")
	e_near.position = Vector2(560, 600)
	_gl.spawner.active.append(e_main)
	_gl.spawner.active.append(e_near)
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	# a) 阈值-1 边界：达线前一击不升格不弹片
	var b_a := _spawn_player_bullet(w1, 0.1, Vector2(500, 600))
	var gold0 := DebugStats.get_counter(&"bank_shot_gold")
	var shard0 := DebugStats.get_counter(&"crit_shard_triggered")
	b_a._bounces_done = int(bank_th) - 1
	b_a._submit_hit(e_main)
	_check("①边界·前：反弹=阈值-1 → bank 未达线（gold 零增）+ 弹片零增",
		DebugStats.get_counter(&"bank_shot_gold") == gold0
			and DebugStats.get_counter(&"crit_shard_triggered") == shard0,
		"goldΔ=%d shardΔ=%d" % [DebugStats.get_counter(&"bank_shot_gold") - gold0,
			DebugStats.get_counter(&"crit_shard_triggered") - shard0])
	_release_bullet(b_a)
	# b) 保真主断言：面板 crit=0.1（<0.35 阈值口径）+ 反弹≥阈值 → 必触发
	var near_hp0 := e_near.hp
	var b_b := _spawn_player_bullet(w1, 0.1, Vector2(500, 600))
	_check("①armed 并入 TH_BANK_SHOT：W1 弹面板 crit=0.1 仍 armed=true（spawn 期算一次）",
		b_b._crit_shard_armed, "")
	var gold1 := DebugStats.get_counter(&"bank_shot_gold")
	var shard1 := DebugStats.get_counter(&"crit_shard_triggered")
	b_b._bounces_done = int(bank_th)
	b_b._submit_hit(e_main)
	var shard_delta := DebugStats.get_counter(&"crit_shard_triggered") - shard1
	_check("①保真主断言：crit=0.1+反弹≥%.0f → 达线置 ctx.crit=1.0 过 %.2f 闸 → 弹片触发 +1" % [bank_th, shard_th],
		DebugStats.get_counter(&"bank_shot_gold") == gold1 + 1 and shard_delta == 1,
		"goldΔ=%d shardΔ=%d" % [DebugStats.get_counter(&"bank_shot_gold") - gold1, shard_delta])
	_check("①弹片真结算：邻近目标（60px<120px 半径）落血（0.5×暴伤=10×2×0.5）",
		e_near.hp < near_hp0 and is_equal_approx(near_hp0 - e_near.hp, 10.0),
		"hp %.1f→%.1f" % [near_hp0, e_near.hp])
	_release_bullet(b_b)
	# c) 无声明武器：armed=false 整段跳过（闸拦截——省扫描不误触发）
	var wf := WeaponBase.new()
	var b_c := _spawn_player_bullet(wf, 0.1, Vector2(500, 600))
	_check("①闸拦截：无声明武器（data=null）+ crit=0.1 → armed=false",
		not b_c._crit_shard_armed, "")
	var shard2 := DebugStats.get_counter(&"crit_shard_triggered")
	b_c._bounces_done = int(bank_th)
	b_c._submit_hit(e_main)
	_check("①闸语义：armed=false 命中（弹片半径内有邻目标）→ 直发段零调用",
		DebugStats.get_counter(&"crit_shard_triggered") == shard2,
		"Δ=%d" % (DebugStats.get_counter(&"crit_shard_triggered") - shard2))
	_release_bullet(b_c)
	wf.free()
	_gl.pipeline.call(&"end_frame")               # 清批队列（弹片次级结算不外泄到后续用例）
	_gl.spawner.active.erase(e_main)
	_gl.spawner.active.erase(e_near)
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	_release_enemy(e_main)
	_release_enemy(e_near)


# ── ② 刀8③：audit 跨命中无污染（主通道 ModifierStack 复用） ───────

func _test_2_audit_no_pollution() -> void:
	print("── ② audit 无污染 ──")
	var ea := _spawn_enemy(&"E_QA220_AUD_A")
	var eb := _spawn_enemy(&"E_QA220_AUD_B")
	var ec := _spawn_enemy(&"E_QA220_AUD_C")
	# 三连命中同一帧（ModifierStack 复用件单例借出→重置→再借出）；contrib 构造可区分 ratio
	var rA: DamageResult = _gl.pipeline.call(&"resolve", _make_ctx(8101, ea, 10.0, 0.0, 0.5))
	var rB: DamageResult = _gl.pipeline.call(&"resolve", _make_ctx(8102, eb, 10.0, 0.0, 2.5))
	var rC: DamageResult = _gl.pipeline.call(&"resolve", _make_ctx(8103, ec, 10.0, 0.0, 1.0))
	_check("②前置：三命中全结算（resist=0 → ratio=S×M/base=1+contrib）",
		rA != null and rB != null and rC != null, "")
	if rA == null or rB == null or rC == null:
		_release_audit_targets(ea, eb, ec)
		return
	_check("②audit 实例独立：三次命中 audit 两两不同（每命中 new——不复用）",
		rA.audit != null and rB.audit != null and rC.audit != null
			and rA.audit != rB.audit and rA.audit != rC.audit and rB.audit != rC.audit, "")
	_check("②audit 快照不变·主断言：首结果 ratio=1.5 不被第二/三命中改写（跨命中无污染）",
		is_equal_approx(rA.audit.ratio, 1.5) and is_equal_approx(rB.audit.ratio, 3.5)
			and is_equal_approx(rC.audit.ratio, 2.0),
		"rA=%.3f rB=%.3f rC=%.3f" % [rA.audit.ratio, rB.audit.ratio, rC.audit.ratio])
	_check("②pool_breakdown 快照独立：三命中乘区明细各自落袋（agg=contrib 合计，不随后续命中变）",
		is_equal_approx(float(rA.pool_breakdown.get(&"qa_r220_mult", 0.0)), 0.5)
			and is_equal_approx(float(rB.pool_breakdown.get(&"qa_r220_mult", 0.0)), 2.5)
			and is_equal_approx(float(rC.pool_breakdown.get(&"qa_r220_mult", 0.0)), 1.0),
		"A=%s B=%s C=%s" % [str(rA.pool_breakdown.get(&"qa_r220_mult")),
			str(rB.pool_breakdown.get(&"qa_r220_mult")), str(rC.pool_breakdown.get(&"qa_r220_mult"))])
	_gl.pipeline.call(&"end_frame")
	_release_audit_targets(ea, eb, ec)


func _release_audit_targets(p_a: Enemy, p_b: Enemy, p_c: Enemy) -> void:
	_gl.spawner.active.erase(p_a)
	_gl.spawner.active.erase(p_b)
	_gl.spawner.active.erase(p_c)
	_release_enemy(p_a)
	_release_enemy(p_b)
	_release_enemy(p_c)


# ── ③ 刀8④：快照遍历回收契约 ─────────────────────────────────────

func _test_3_snapshot_recycle_contract() -> void:
	print("── ③ 快照遍历/回收契约 ──")
	_clear_projectiles()
	var pool := _proj_pool()
	# 3a-1：契约主通道——tick 内 spawn 新弹（取预热空闲件，非同帧归还件）→ 出生帧不 tick
	var m0 := _spawn_player_bullet(_w1(), 0.0, Vector2(100, 100))
	var m2 := _spawn_player_bullet(_w1(), 0.0, Vector2(300, 100))
	var hook := TickHook.new()
	var spawned: Array[ProjectileBase] = []
	hook.action = func() -> void:
		var r := _proj_pool().acquire()                     # 预热空闲件（本帧无归还 → 非 LIFO 复用）
		r.damage_pipeline = _gl.pipeline
		r.enemy_grid = _gl.enemy_grid
		r.pool = _proj_pool()
		r.spawn({
			"velocity": Vector2(60.0, 0.0), "lifetime": 10.0, "pierce": 1, "team": 0,
			"panel_snapshot": {"base_atk": 1.0, "crit_rate": 0.0, "crit_mult": 2.0, "add_entries": []},
			"position": Vector2(500, 500),
		})
		spawned.append(r)
	m2.set("trait_stack", null)                             # 直挂通道（非 TraitStack）
	m2.set("_traits_cache", [hook])
	_gl._tick_one_pool(pool, DT)
	var act := pool.active_projectiles()
	var fresh: ProjectileBase = spawned[0] if spawned.size() > 0 else null
	_check("③a 出生帧不 tick·主通道：tick 内新 spawn 弹（非同帧归还件）位置==出生位 500",
		fresh != null and is_equal_approx(fresh.position.x, 500.0) and act.has(fresh),
		"x=%.3f" % (fresh.position.x if fresh != null else -1.0))
	_check("③a 恰一次：m0/m2 位移各恰 +1px（v=60×DT；快照遍历不双 tick 不漏 tick）",
		is_equal_approx(m0.position.x, 101.0) and is_equal_approx(m2.position.x, 301.0),
		"m0=%.3f m2=%.3f" % [m0.position.x, m2.position.x])
	_check("③a tick 副作用恰一次：TickHook 触发 1 次（ON_TICK 单拍）",
		hook.fired == 1, "fired=%d" % hook.fired)
	_check("③a 索引一致（tick 内 spawn 后）", _pool_index_consistent(pool), "")
	_release_bullet(m0)
	_release_bullet(m2)
	_release_bullet(fresh)
	# 3a-2：边缘取证——tick 内回收未遍历弹 + 同帧 LIFO 复用（分裂链现实场景）
	#   ⚠取证断言（缺陷上报 qa-D1，不锁死此行为）：复用件本帧被多 tick 一步（x=501≠500），
	#   违反 game_loop._tick_one_pool 头注「tick 期内新 spawn 只追加 active 表不入快照 →
	#   出生帧不 tick（原倒序遍历语义保持）」——原 O(n) erase 倒序语义下复用件 append 尾部
	#   不被访问；快照缓冲含帧首活跃引用，LIFO 复用使引用复活。
	_clear_projectiles()
	var n0 := _spawn_player_bullet(_w1(), 0.0, Vector2(100, 100))
	var n1 := _spawn_player_bullet(_w1(), 0.0, Vector2(200, 100))
	var n2 := _spawn_player_bullet(_w1(), 0.0, Vector2(300, 100))
	var hook2 := TickHook.new()
	var spawned2: Array[ProjectileBase] = []
	hook2.action = func() -> void:
		n1._recycle(GameConst.RecycleReason.NULLIFIED)      # tick 内回收未遍历弹（倒序后段）
		var r := _proj_pool().acquire()                     # LIFO → 复用刚归还的 n1 实例
		r.damage_pipeline = _gl.pipeline
		r.enemy_grid = _gl.enemy_grid
		r.pool = _proj_pool()
		r.spawn({
			"velocity": Vector2(60.0, 0.0), "lifetime": 10.0, "pierce": 1, "team": 0,
			"panel_snapshot": {"base_atk": 1.0, "crit_rate": 0.0, "crit_mult": 2.0, "add_entries": []},
			"position": Vector2(500, 500),
		})
		spawned2.append(r)
	n2.set("trait_stack", null)
	n2.set("_traits_cache", [hook2])
	_gl._tick_one_pool(pool, DT)
	var act2 := pool.active_projectiles()
	var r0: ProjectileBase = spawned2[0] if spawned2.size() > 0 else null
	_check("③a LIFO 复现：新弹==n1 归还件（同帧回收→同帧借出同实例）——边缘前提成立",
		r0 != null and r0 == n1, "spawned=%d" % spawned2.size())
	_check("③a [取证·缺陷qa-D1] 同帧回收→复用件被多 tick 一步（x==501 现状；契约应为 500）",
		r0 != null and is_equal_approx(r0.position.x, 501.0),
		"x=%.3f（500=契约达成；501=一步偏差已上报）" % (r0.position.x if r0 != null else -1.0))
	_check("③a 回收+复用不扰动遍历：n0/n2 位移恰一次 + 复用件在表存活",
		is_equal_approx(n0.position.x, 101.0) and is_equal_approx(n2.position.x, 301.0)
			and act2.has(r0) and not act2.has(null),
		"n0=%.3f n2=%.3f" % [n0.position.x, n2.position.x])
	_check("③a 索引一致（tick 内回收+复用后）", _pool_index_consistent(pool), "")
	_release_bullet(n0)
	_release_bullet(n2)
	_release_bullet(r0)
	# 3b：force_recycle_oldest 插入序取最老（swap-remove 后 _live_order 语义保持）
	_clear_projectiles()
	var x1 := pool.acquire()
	var x2 := pool.acquire()
	var x3 := pool.acquire()
	var x4 := pool.acquire()
	var x5 := pool.acquire()
	pool.release(x2)                                        # swap：x5→idx1 → [x1,x5,x3,x4]
	var actb := pool.active_projectiles()
	_check("③b swap 结构：release(x2) → [x1,x5,x3,x4]",
		actb.size() == 4 and actb[0] == x1 and actb[1] == x5 and actb[2] == x3 and actb[3] == x4,
		str(actb.size()))
	pool.force_recycle_oldest()
	var act3 := pool.active_projectiles()
	_check("③b 取最老：force 回收 _live_order 首键 x1（插入序语义不随 swap 漂移）",
		not act3.has(x1) and act3.has(x3) and act3.has(x4) and act3.has(x5), "")
	_check("③b 索引一致（force 路径后）", _pool_index_consistent(pool), "")
	pool.release(x3)
	pool.release(x4)
	pool.release(x5)
	_check("③b 清场：active 空", pool.active_projectiles().is_empty(), "")


# ── ④ 刀9：敌弹快慢路径逐位等价 ───────────────────────────────────

func _test_4_fast_path_equivalence() -> void:
	print("── ④ 敌弹等价 ──")
	_clear_projectiles()
	var pool := _proj_pool()
	# 4a 判据矩阵（PR 检查单回归面：域外参数逐项回落慢路径）
	_check("④a 判据·基础：enemy.gd 同域最小参数 → _fast_path=true",
		_spawn_enemy_bullet(Vector2(300, 300), Vector2(60, 0), 5.0, 5.0)._fast_path, "")
	_check("④a 判据·lateral_offset（converge steer 通道）→ false",
		not _spawn_enemy_bullet(Vector2(300, 300), Vector2(60, 0), 5.0, 5.0,
			{"lateral_offset": 50.0})._fast_path, "")
	_check("④a 判据·bounces>0（edge bounce 双调域）→ false",
		not _spawn_enemy_bullet(Vector2(300, 300), Vector2(60, 0), 5.0, 5.0,
			{"bounces": 2})._fast_path, "")
	_check("④a 判据·boomerang（回旋运动）→ false",
		not _spawn_enemy_bullet(Vector2(300, 300), Vector2(60, 0), 5.0, 5.0,
			{"boomerang": true})._fast_path, "")
	_check("④a 判据·直挂词条（ON_TICK 闸域）→ false",
		not _spawn_enemy_bullet(Vector2(300, 300), Vector2(60, 0), 5.0, 5.0,
			{"traits": [TickHook.new()]})._fast_path, "")
	_check("④a 判据·LTG（电花自旋表现域）→ false",
		not _spawn_enemy_bullet(Vector2(300, 300), Vector2(60, 0), 5.0, 5.0,
			{"element": GameConst.Element.LTG})._fast_path, "")
	_check("④a 判据·accel（Ballistic 加速域）→ false",
		not _spawn_enemy_bullet(Vector2(300, 300), Vector2(60, 0), 5.0, 5.0,
			{"accel": 100.0})._fast_path, "")
	_check("④a 判据·range（射程判定域）→ false",
		not _spawn_enemy_bullet(Vector2(300, 300), Vector2(60, 0), 5.0, 5.0,
			{"range": 300.0})._fast_path, "")
	_clear_projectiles()
	# 4b 寿命：双胞胎同帧回收、同原因计数
	var reason_exp := StringName("recycle_reason_%d" % int(GameConst.RecycleReason.EXPIRED))
	var exp0 := DebugStats.get_counter(reason_exp)
	var l_fast := _spawn_enemy_bullet(Vector2(300, 300), Vector2(60, 0), DT, 5.0)
	var l_slow := _spawn_enemy_bullet(Vector2(300, 300), Vector2(60, 0), DT, 5.0)
	l_slow._fast_path = false
	_gl._tick_one_pool(pool, DT)
	_check("④b 寿命同帧同因：lifetime=DT 快/慢同帧 EXPIRED（计数 +2）",
		not pool.active_projectiles().has(l_fast) and not pool.active_projectiles().has(l_slow)
			and DebugStats.get_counter(reason_exp) == exp0 + 2,
		"expΔ=%d" % (DebugStats.get_counter(reason_exp) - exp0))
	# 4c 位置逐位：斜向速度 10 帧累积
	var p_fast := _spawn_enemy_bullet(Vector2(100, 200), Vector2(37, 59), 5.0, 5.0)
	var p_slow := _spawn_enemy_bullet(Vector2(100, 200), Vector2(37, 59), 5.0, 5.0)
	p_slow._fast_path = false
	for i in 10:
		_gl._tick_one_pool(pool, DT)
	var expect := Vector2(100.0 + 37.0 * DT * 10.0, 200.0 + 59.0 * DT * 10.0)
	_check("④c 位置逐位等价：10 帧后快/慢位置差 <1e-6（互差是等价主断言）",
		p_fast.position.distance_to(p_slow.position) < EPS,
		"fast=%s slow=%s" % [str(p_fast.position), str(p_slow.position)])
	_check("④c 解析期望：快路径 10 步累积==v×dt×10（浮点累加舍宽容差 1e-4）",
		p_fast.position.distance_to(expect) < 0.0001,
		"fast=%s expect=%s" % [str(p_fast.position), str(expect)])
	_release_bullet(p_fast)
	_release_bullet(p_slow)
	# 4d 出界：高速弹同帧出表（EXPIRED）
	var exp1 := DebugStats.get_counter(reason_exp)
	var o_fast := _spawn_enemy_bullet(Vector2(700, 300), Vector2(9999, 0), 5.0, 5.0)
	var o_slow := _spawn_enemy_bullet(Vector2(700, 300), Vector2(9999, 0), 5.0, 5.0)
	o_slow._fast_path = false
	_gl._tick_one_pool(pool, DT)
	_check("④d 出界同帧同因：飞出屏+余量 快/慢同帧 EXPIRED（计数 +2）",
		not pool.active_projectiles().has(o_fast) and not pool.active_projectiles().has(o_slow)
			and DebugStats.get_counter(reason_exp) == exp1 + 2,
		"expΔ=%d" % (DebugStats.get_counter(reason_exp) - exp1))
	# 4e 撞玩家：伤害同源、同帧回收（PIERCE_DEPLETED）
	var reason_pd := StringName("recycle_reason_%d" % int(GameConst.RecycleReason.PIERCE_DEPLETED))
	var pd0 := DebugStats.get_counter(reason_pd)
	var pl := _gl.player as Player
	pl.invuln_left = 0.0
	var hp0 := pl.hp
	var c_fast := _spawn_enemy_bullet(pl.global_position, Vector2.ZERO, 5.0, 5.0)
	_gl._tick_one_pool(pool, DT)
	_check("④e 快路径撞玩家：本帧回收 + take_contact_damage(base_atk=5)",
		not pool.active_projectiles().has(c_fast) and is_equal_approx(pl.hp, hp0 - 5.0),
		"hp %.1f→%.1f" % [hp0, pl.hp])
	pl.invuln_left = 0.0
	var hp1 := pl.hp
	var c_slow := _spawn_enemy_bullet(pl.global_position, Vector2.ZERO, 5.0, 5.0)
	c_slow._fast_path = false
	_gl._tick_one_pool(pool, DT)
	_check("④e 慢路径撞玩家：同帧回收 + 同伤害（读字典通道）",
		not pool.active_projectiles().has(c_slow) and is_equal_approx(pl.hp, hp1 - 5.0),
		"hp %.1f→%.1f" % [hp1, pl.hp])
	_check("④e 回收原因对齐：两轮撞玩家 PIERCE_DEPLETED 计数 +2",
		DebugStats.get_counter(reason_pd) == pd0 + 2,
		"pdΔ=%d" % (DebugStats.get_counter(reason_pd) - pd0))
	# 4f 半径缓存：spawn 快照==effective_radius
	var r_b := _spawn_enemy_bullet(Vector2(300, 300), Vector2(60, 0), 5.0, 5.0,
		{"hitbox_radius": 9.0})
	_check("④f 半径缓存：_fast_radius==effective_radius()==9（spawn 快照）",
		is_equal_approx(r_b._fast_radius, 9.0) and is_equal_approx(r_b.effective_radius(), 9.0),
		"fast_r=%.2f eff=%.2f" % [r_b._fast_radius, r_b.effective_radius()])
	_release_bullet(r_b)
	_clear_projectiles()


# ── ⑤ 刀11：完整帧批化端到端 ──────────────────────────────────────

func _test_5_full_frame_batched() -> void:
	print("── ⑤ 完整帧批化 ──")
	_clear_projectiles()
	var e_hit := _spawn_enemy(&"E_QA220_FRAME")
	e_hit.position = Vector2(400, 600)
	_gl.spawner.active.append(e_hit)
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	var wf := WeaponBase.new()                     # 无阈值声明（防 bank/shard 次级噪声）
	var probe := _spawn_player_bullet(wf, 0.0, Vector2(400, 600), Vector2.ZERO)
	var probe_uid := probe.uid
	_gl.state = GameConst.GameStatus.PLAYING
	var hud := _gl.hud as HUD
	var pm: PopupManager = _gl.popup_manager
	var total0 := hud.total_damage
	var act0 := pm._active_list.size()
	_spy_hits.clear()
	_gl._physics_process(DT)                      # 完整帧：④弹段结算入队 → ⑧段前派发 → ⑧跳字 tick
	var spy_sum := 0.0
	var spy_has_probe := false
	for v in _spy_hits:
		spy_sum += v.y
		if int(v.x) == probe_uid:
			spy_has_probe = true
	_check("⑤⑧段前派发：帧末 spy 已含本帧弹命中（probe uid=%d 到达）" % probe_uid,
		spy_has_probe, "spy=%s" % str(_spy_hits))
	var host_hit := false
	for n in pm._active_list:
		var dp := n as DamagePopup
		if dp != null and dp.target_uid == e_hit.uid:
			host_hit = true
	_check("⑤跳字同帧起跳：⑧段前派发 → 本帧 _tick_ui 内起字（target_uid 敌在跳）",
		pm._active_list.size() > act0 and host_hit,
		"act %d→%d host=%s" % [act0, pm._active_list.size(), str(host_hit)])
	_check("⑤HUD 累计正确：total_damage 增量==派发批全额（headless 直消费通道）",
		is_equal_approx(hud.total_damage - total0, spy_sum),
		"Δ=%.2f spy_sum=%.2f" % [hud.total_damage - total0, spy_sum])
	pm.clear_all()
	wf.free()
	_gl.pipeline.call(&"end_frame")
	_clear_projectiles()
	_gl.spawner.active.erase(e_hit)
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	_release_enemy(e_hit)


# ── ⑥ 刀1：模N 采样序端到端 ───────────────────────────────────────

func _test_6_sim_hz_sampling() -> void:
	print("── ⑥ 模N 采样序 ──")
	var state_prev := _gl.state
	var ds2: Node = (load("res://autoload/debug_stats.gd") as GDScript).new()
	tree.root.add_child(ds2)                       # 同步块内驱动（不入自动 _process 采样窗）
	ds2.set("_diag_last_ms", -1000001)             # 远古基线（必过节拍门）
	ds2.set("_diag_lines", [])
	_gl.state = GameConst.GameStatus.LEVEL_UP
	ds2.call(&"_diag_maybe_sample")
	var lines_lu: Array = ds2.get("_diag_lines")
	var last_ms_lu: int = ds2.get("_diag_last_ms")
	_check("⑥LEVEL_UP 节拍不消费：选卡期零采样、_diag_last_ms 冻结（R212 门保持）",
		lines_lu.is_empty() and last_ms_lu == -1000001, "lines=%d last_ms=%d" % [lines_lu.size(), last_ms_lu])
	_gl.state = GameConst.GameStatus.PLAYING
	ds2.call(&"_diag_maybe_sample")
	var lines_p: Array = ds2.get("_diag_lines")
	var last_ms_p: int = ds2.get("_diag_last_ms")
	_check("⑥退出选卡首拍立即补采：PLAYING 首采 1 行 + 节拍基线刷新",
		lines_p.size() == 1 and last_ms_p >= 0, "lines=%d last_ms=%d" % [lines_p.size(), last_ms_p])
	_check("⑥首采哨兵：_diag_last_phys=-1 → 模0 不带星（不出脏值）",
		(lines_p[0] as String).contains("模0") and not (lines_p[0] as String).contains("模0*"),
		(lines_p[0] as String).right(90))
	ds2.call(&"_diag_maybe_sample")
	_check("⑥1Hz 节拍门：1s 内再调零新行（节拍消费语义）",
		(ds2.get("_diag_lines") as Array).size() == 1, "")
	ds2.queue_free()
	await tree.process_frame
	_gl.state = state_prev
	# 直调拼行：跨窗星标 + 正常窗值域（物理帧差分真实读数）
	var ds3: RefCounted = (load("res://autoload/debug_stats.gd") as GDScript).new()
	var now := Time.get_ticks_msec()
	var phys := Engine.get_physics_frames()
	ds3.set("_diag_last_ms", now - 2500)
	ds3.set("_diag_last_phys", phys - 60)
	var line_cross: String = ds3.call(&"_diag_format_line", _gl, now)
	_check("⑥跨窗标记：差分60÷墙钟2500ms → 模24*（判读剔除口径）",
		line_cross.contains("模24*"), line_cross.right(80))
	ds3.set("_diag_last_ms", now - 1000)
	var line_ok: String = ds3.call(&"_diag_format_line", _gl, now)
	_check("⑥正常窗：差分60÷1000ms → 模60 无星（PLAYING 连续行值域）",
		line_ok.contains("模60") and not line_ok.contains("模60*"), line_ok.right(80))
	ds3.free()


# ── ⑦ 刀1：结N / 自导N ────────────────────────────────────────────

func _test_7_settles_homing() -> void:
	print("── ⑦ 结N/自导N ──")
	# 结N：PLAYING 期弹段结算链端到端（⑤ 场景重演——resolve 由弹内 _submit_hit 驱动）
	_clear_projectiles()
	var e7 := _spawn_enemy(&"E_QA220_SETTLE")
	e7.position = Vector2(450, 620)
	_gl.spawner.active.append(e7)
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	var wf := WeaponBase.new()
	var pb := _spawn_player_bullet(wf, 0.0, Vector2(450, 620), Vector2.ZERO)
	_gl.state = GameConst.GameStatus.PLAYING
	var c_base: Dictionary = _gl.diag_counts()     # 立结N 差分基线
	var s0 := int(c_base.get(&"settles", -1))
	_gl._physics_process(DT)
	var c_after: Dictionary = _gl.diag_counts()
	_check("⑦结N PLAYING 期>0：弹段内 _submit_hit→resolve → settles 差分 ≥1（真件管线计数）",
		int(c_after.get(&"settles", 0)) >= 1,
		"base=%d after=%d" % [s0, int(c_after.get(&"settles", 0))])
	_check("⑦结N 差分不虚计：重复拉取零增量（基线推进语义）",
		int((_gl.diag_counts()).get(&"settles", -1)) == 0, "")
	# 自导N：池联动
	var hpool: ProjectilePool = _gl._homing_pool as ProjectilePool
	var h0 := int((_gl.diag_counts()).get(&"homing_projectiles", -1))
	var hp := hpool.acquire()
	hp.spawn({"velocity": Vector2(60, 0), "lifetime": 5.0, "pierce": 1, "target_uid": e7.uid})
	_check("⑦自导N 联动：homing acquire+spawn → 在场 +1",
		int((_gl.diag_counts()).get(&"homing_projectiles", 0)) == h0 + 1, "")
	hpool.release(hp)
	_check("⑦自导N 归还回落：release → 在场回基线",
		int((_gl.diag_counts()).get(&"homing_projectiles", -1)) == h0, "")
	wf.free()
	_gl.pipeline.call(&"end_frame")
	_clear_projectiles()
	_gl.spawner.active.erase(e7)
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	_release_enemy(e7)


# ── ⑧ 刀4：r210 双轨桩运行时 ──────────────────────────────────────

func _test_8_stub_dual_track() -> void:
	print("── ⑧ 桩双轨 ──")
	# 前置事实：DamageContext.target: Enemy 强类型（damage_context.gd:11）——非 Enemy 桩
	# 不可达 ctx 构建/管线侧分支（pipeline else has_method 为形态保留）；可达桩路径在
	# projectile_base 参数侧（p_target: Node2D）：_in_reach hitbox_r / dead / try_reflect / 撞玩家半径。
	var wf := WeaponBase.new()
	var stub := StubTarget.new()
	stub.uid = 8801
	stub.hitbox_r = 14.0
	var sb := _spawn_player_bullet(wf, 0.0, Vector2(300, 300), Vector2(100.0, 0.0))
	sb.global_position = Vector2(300, 300)
	stub.position = Vector2(310, 300)                 # 距弹 10px
	_check("⑧_in_reach 桩路径：非 Enemy 走 Variant get(hitbox_r)（r210 双轨）——10+14 reach 内命中",
		sb._in_reach(stub, 10.0), "")
	stub.hitbox_r = 0.0
	stub.position = Vector2(325, 300)                 # 距弹 25px > reach 10
	_check("⑧_in_reach 桩路径：半径 0 且距离 25 > reach 10 → 不命中",
		not sb._in_reach(stub, 10.0), "")
	# 反射 else 分支：try_reflect=true → 命中取消（不耗穿透/不落血/弹存活）
	stub.hitbox_r = 14.0
	stub.reflect_on = true
	sb._submit_hit(stub)
	_check("⑧反射桩路径：非 Enemy has_method(call) 分支 → 命中取消（弹存活、穿透未耗）",
		sb._live and sb.pierce_left == 1, "live=%s pierce=%d" % [str(sb._live), sb.pierce_left])
	# 死亡短路 else 分支（E-06）：dead=true → 直接 return（同帧不落血不耗穿透）
	stub.reflect_on = false
	stub.dead = true
	sb.hits_this_frame.clear()
	sb._hit_uids.clear()
	sb._submit_hit(stub)
	_check("⑧桩死亡短路：dead=true（else get 分支）→ 命中丢弃（弹存活穿透未耗）",
		sb._live and sb.pierce_left == 1, "live=%s pierce=%d" % [str(sb._live), sb.pierce_left])
	_release_bullet(sb)
	wf.free()
	stub.free()
	var src_dp: String = FileAccess.get_file_as_string("res://scripts/core/damage/damage_pipeline.gd")
	_check("⑧源锚：_read_resist/_apply_to_target else has_method 桩路径形态保留（R210 双轨）",
		src_dp.contains("if p_ctx.target.has_method(\"get_resist\")")
			and src_dp.contains("if t.has_method(\"take_result\")"), "")
	var src_dc: String = FileAccess.get_file_as_string("res://scripts/core/damage/damage_context.gd")
	_check("⑧类型墙源锚：ctx.target: Enemy 强类型（pipeline else 桩分支不可达的根因）",
		src_dc.contains("var target: Enemy = null"), "")


# ── 测试钩子（ON_TICK 直挂词条——非 TraitStack 通道） ────────────────

class TickHook extends RefCounted:
	var fired: int = 0
	var action: Callable = Callable()

	func on_event(p_event: int, p_ctx: TraitContext) -> void:
		if p_event == GameConst.TraitEvent.ON_TICK:
			fired += 1
			if action.is_valid():
				action.call()


# ── 桩目标（刀4 else 双轨；Node2D duck-type——仅 projectile_base 参数侧可达） ──

class StubTarget extends Node2D:
	var uid := 0
	var dead := false
	var hitbox_r := 14.0
	var reflect_on := false

	func try_reflect_projectile(p_proj: Node2D) -> bool:
		return reflect_on

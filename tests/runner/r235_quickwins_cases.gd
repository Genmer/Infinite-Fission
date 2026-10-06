# tests/runner/r235_quickwins_cases.gd
# R235 快项组合用例体（入口 test_r235_quickwins.gd 运行时 load——cases 禁 test_ 前缀防
# 电池 glob 误收）。覆盖：
# ① 4a 跳弹臂快路径行为：fast 跳弹贴边回落 _check_edge_bounce 本体——反射/夹位/视觉刷新/
#    bullet_bounced 广播/不出界误回收；
# ② 快慢孪生逐位等价：同参数跳弹弹一直驱 _tick_fast_player / 一直驱 tick()，60 步含反弹帧
#    位置+速度逐帧全等（r231 T9 同款确定性锚；空网格=4b 预检空直通零误调同证）；
# ③ BOUNCE_DEPLETED 孪生同因：bounces=1 两次贴边，快慢臂回收原因/计数一致；
# ④ 4b 双查询合并等价：桩敌在场 fast（预检直填 _candidates+skip_query）/slow（全查）命中
#    结算流（damage_resolved 条数+hp 减量）全等；
# ⑤ 4c 关态快照直返：生产关（override=-1+ENABLED=false）_ip_curr 冻结；-2 注入/-3 开态
#    快照仍跑（原 T7 语义保真）；
# ⑥ 搭车①配对收窄：敌 _hit_area.collision_mask==2 ∧ player.collision_layer==3（实例读）；
# ⑦ 套件总项数断言（R231 假绿教训）。
# 本套件纯 headless 无窗口；开关/哨兵静态注入，teardown 复位（ENABLED=false=vc39 起新默认）。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const DT := 1.0 / 60.0
const EXPECTED_TOTAL := 20                     # 总项数自检前的检查项数（自检项不计入自身）

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(20261006)
	await _boot_game_loop()
	await tree.process_frame
	await tree.process_frame
	_gl.state = GameConst.GameStatus.MENU             # 静止环境（r230 先例）
	PerfGovernor.set_process(false)
	GameLoop.SIM_30HZ_ENABLED = false                 # 生产关基线（vc39 新默认）
	GameLoop.sim30_override = -1
	_test_1_bounce_fast_behavior()
	_test_2_twin_bit_equivalence()
	_test_3_bounce_depleted_parity()
	_test_4_merge_query_equivalence()
	_test_5_snapshot_skip_semantics()
	_test_6_mask_pairing()
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
	GameLoop.SIM_30HZ_ENABLED = false                 # 复位=vc39 起新默认（二ch 回退）
	GameLoop.sim30_override = -1
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


# ── 夹具（r231_pfast 同构） ────────────────────────────────────────

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
	e.spawn(_fixture_enemy_data(&"r235_qw", p_hp), 1, 0)
	e._fade_left = 0.0
	e.modulate.a = 1.0
	e.global_position = p_pos
	_gl.spawner.active.append(e)
	return e


func _spawn_bullet(p_pos: Vector2, p_overrides: Dictionary = {}) -> ProjectileBase:
	var params := {
		"velocity": Vector2(0.0, -500.0), "lifetime": 9.0, "pierce": 3, "team": 0,
		"hitbox_radius": 8.0, "range": 900.0,
		"trait_stack": TraitStack.new(),
		"panel_snapshot": {"base_atk": 10.0, "flat_bonus": 0.0,
			"crit_rate": 0.0, "crit_mult": 2.0, "add_entries": []},
		"position": p_pos,
	}
	for k in p_overrides:
		params[k] = p_overrides[k]
	var pool := _gl.pools[&"projectile"] as ProjectilePool
	var proj := pool.acquire()
	proj.damage_pipeline = _gl.pipeline
	proj.enemy_grid = _gl.enemy_grid
	proj.pool = pool
	proj.spawn(params)
	return proj


func _reason_delta(p_reason: int, p_last: Dictionary) -> int:
	var key := StringName("recycle_reason_%d" % p_reason)
	var cur := DebugStats.get_counter(key)
	var last: int = int(p_last.get(key, 0))
	p_last[key] = cur
	return cur - last


func _reason_snapshot() -> Dictionary:
	var snap: Dictionary = {}
	for i in 5:
		snap[StringName("recycle_reason_%d" % i)] = DebugStats.get_counter(
			StringName("recycle_reason_%d" % i))
	return snap


# ── ① 4a 跳弹臂快路径行为 ─────────────────────────────────────────

func _test_1_bounce_fast_behavior() -> void:
	print("── ① 4a 跳弹臂快路径行为 ──")
	_release_field()
	_gl.enemy_grid.rebuild(_empty_items())            # 空网格（隔离本测——预检零候选）
	var bounced: Array[int] = []                      # lambda 捕贝坑：计数用数组引用（int 捕获+=不回写）
	var cb := func(_pos: Vector2) -> void: bounced.append(1)
	EventBus.bullet_bounced.connect(cb)
	var b := _spawn_bullet(Vector2(360.0, 40.0), {"bounces": 2})
	_check("4a 前置：bounces=2 跳弹判 fast", b._pfast, str(b._pfast))
	var v0: Vector2 = b.velocity
	for i in 60:
		if not b._live:
			break
		b._tick_fast_player(DT)
	_check("4a 反射生效：bounces_left 2→1", b.bounces_left == 1, str(b.bounces_left))
	_check("4a 速度镜像：vy 翻正（原 %f）" % v0.y, b.velocity.y > 0.0, str(b.velocity))
	_check("4a 位置夹回带内：y≈r", absf(b.global_position.y - 8.0) < 0.01 or b.global_position.y > 8.0,
		str(b.global_position.y))
	_check("4a 反射帧视觉刷新：_vis_variant>=0", b._vis_variant >= 0, str(b._vis_variant))
	_check("4a bullet_bounced 广播恰一次", bounced.size() == 1, str(bounced.size()))
	_check("4a 未被出界误回收（仍活）", b._live, str(b._live))
	EventBus.bullet_bounced.disconnect(cb)
	(b.pool as ProjectilePool).release(b)


# ── ② 快慢孪生逐位等价（60 步含反弹帧） ───────────────────────────

func _test_2_twin_bit_equivalence() -> void:
	print("── ② 快慢孪生逐位 ──")
	_release_field()
	_gl.enemy_grid.rebuild(_empty_items())            # 空网格：孪生纯运动学对拍+4b 空直通
	var fa := _spawn_bullet(Vector2(360.0, 40.0), {"bounces": 2})
	var sl := _spawn_bullet(Vector2(360.0, 40.0), {"bounces": 2})
	var max_d := 0.0
	var v_eq := true
	var live_eq := true
	for i in 60:
		if fa._live:
			fa._tick_fast_player(DT)
		if sl._live:
			sl.tick(DT)
		max_d = maxf(max_d, fa.global_position.distance_to(sl.global_position))
		v_eq = v_eq and fa.velocity.distance_to(sl.velocity) < 0.0001
		live_eq = live_eq and (fa._live == sl._live)
	_check("孪生 60 步位置逐帧全等（含反弹帧，max_d<0.0001）", max_d < 0.0001, str(max_d))
	_check("孪生速度全等（反弹镜像同值）", v_eq, str(v_eq))
	_check("孪生活态一致（双活——空网格下 4b 预检空直通零误调）",
		live_eq and fa._live and sl._live,
		"live_eq=%s fa=%s sl=%s" % [str(live_eq), str(fa._live), str(sl._live)])
	(fa.pool as ProjectilePool).release(fa)
	(sl.pool as ProjectilePool).release(sl)


# ── ③ BOUNCE_DEPLETED 孪生同因 ────────────────────────────────────

func _test_3_bounce_depleted_parity() -> void:
	print("── ③ BOUNCE_DEPLETED 孪生 ──")
	_release_field()
	_gl.enemy_grid.rebuild(_empty_items())
	var br := GameConst.RecycleReason.BOUNCE_DEPLETED
	var snap_a := _reason_snapshot()
	# range=0（无射程上限——否则 900px 先于底边耗尽，BOUNCE_DEPLETED 不可达）
	var fa := _spawn_bullet(Vector2(360.0, 40.0), {"bounces": 1, "range": 0.0})
	for i in 420:
		if not fa._live:
			break
		fa._tick_fast_player(DT)
	var d_fast := _reason_delta(br, snap_a)
	_check("fast 臂 BOUNCE_DEPLETED 恰一次", d_fast == 1, str(d_fast))
	var snap_b := _reason_snapshot()
	var sl := _spawn_bullet(Vector2(360.0, 40.0), {"bounces": 1, "range": 0.0})
	for i in 420:
		if not sl._live:
			break
		sl.tick(DT)
	var d_slow := _reason_delta(br, snap_b)
	_check("slow 孪生同因同计数（BOUNCE_DEPLETED=1）", d_slow == 1, str(d_slow))


# ── ④ 4b 双查询合并等价（桩敌命中结算流） ─────────────────────────

func _test_4_merge_query_equivalence() -> void:
	print("── ④ 4b 合并查询等价 ──")
	_release_field()
	var spy: Array[int] = []
	var cb := func(r: DamageResult) -> void: spy.append(int(r.target_uid))
	EventBus.damage_resolved.connect(cb)
	(_gl.pipeline.get("_resolved_queue") as Array).clear()
	var e := _spawn_enemy(1.0e9, Vector2(360.0, 600.0))
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	var hp0: float = e.hp
	var fa := _spawn_bullet(Vector2(360.0, 600.0), {"pierce": 2})
	fa._tick_fast_player(DT)
	_gl.pipeline.call(&"dispatch_resolved_frame")
	var n_fast := spy.count(int(e.uid))
	var d_fast_hp: float = hp0 - e.hp
	_check("fast 臂（预检直填+skip_query）一 tick 即结算", n_fast == 1,
		"n=%d" % n_fast)
	var sl := _spawn_bullet(Vector2(360.0, 600.0), {"pierce": 2})
	var hp1: float = e.hp
	sl.tick(DT)
	_gl.pipeline.call(&"dispatch_resolved_frame")
	var n_slow := spy.count(int(e.uid)) - n_fast
	var d_slow_hp: float = hp1 - e.hp
	_check("slow 臂全查同计数同伤害（合并口径=全查口径）",
		n_slow == 1 and absf(d_fast_hp - d_slow_hp) < 0.0001,
		"n=%d dhp=%f vs %f" % [n_slow, d_fast_hp, d_slow_hp])
	# 空网格直通：清敌后 fast 驱动零新结算（预检空不误调 _check_collision）
	_release_field()
	_gl.enemy_grid.rebuild(_empty_items())
	var base_n: int = spy.size()
	var fe := _spawn_bullet(Vector2(360.0, 600.0))
	fe._tick_fast_player(DT)
	_gl.pipeline.call(&"dispatch_resolved_frame")
	_check("空网格 fast 驱动零新结算", spy.size() == base_n, "%d→%d" % [base_n, spy.size()])
	(fe.pool as ProjectilePool).release(fe)
	EventBus.damage_resolved.disconnect(cb)


# ── ⑤ 4c 关态快照直返语义 ─────────────────────────────────────────

func _test_5_snapshot_skip_semantics() -> void:
	print("── ⑤ 4c 关态快照直返 ──")
	_release_field()
	var e := _spawn_enemy(1.0e9, Vector2(100.0, 200.0))
	e._ip_prev = Vector2(5.0, 5.0)
	e._ip_curr = Vector2(5.0, 5.0)
	# 生产关（vc39 默认）：override==-1 ∧ 谓词关 → 直返（缓冲冻结）
	GameLoop.SIM_30HZ_ENABLED = false
	GameLoop.sim30_override = -1
	_gl._ip_snapshot_pass()
	_check("生产关态直返：_ip_curr 冻结", e._ip_curr == Vector2(5.0, 5.0), str(e._ip_curr))
	# -2 注入态：谓词关但有注入 → 原 T7 无条件快照语义
	GameLoop.sim30_override = -2
	_gl._ip_snapshot_pass()
	_check("-2 注入态快照仍跑（_ip_curr 追位）",
		e._ip_curr.distance_to(e.global_position) < 0.01,
		"%s vs %s" % [str(e._ip_curr), str(e.global_position)])
	# -3 开态（开关 true）：谓词真 → 快照照跑
	GameLoop.SIM_30HZ_ENABLED = true
	GameLoop.sim30_override = -3
	e._ip_curr = Vector2(5.0, 5.0)
	_gl._ip_snapshot_pass()
	_check("-3 开态快照照跑", e._ip_curr.distance_to(e.global_position) < 0.01,
		str(e._ip_curr))
	GameLoop.SIM_30HZ_ENABLED = false
	GameLoop.sim30_override = -1


# ── ⑥ 搭车①配对收窄 ──────────────────────────────────────────────

func _test_6_mask_pairing() -> void:
	print("── ⑥ 搭车① mask 配对 ──")
	_release_field()
	var e := _spawn_enemy(1.0e9, Vector2(100.0, 200.0))
	_check("敌 _hit_area.collision_mask==2（敌-敌 pair 消除）",
		e._hit_area != null and e._hit_area.collision_mask == 2,
		str(e._hit_area.collision_mask if e._hit_area != null else -1))
	var pl := _gl.player
	_check("player.collision_layer==3（bit1 保留+bit2 配对位）",
		pl != null and is_instance_valid(pl) and pl.collision_layer == 3,
		str(pl.collision_layer if pl != null and is_instance_valid(pl) else -1))
	_check("套件总项数（EXPECTED=%d——R231 假绿教训：总项数也要断言）" % EXPECTED_TOTAL,
		_pass + _fail == EXPECTED_TOTAL, "实=%d" % (_pass + _fail))

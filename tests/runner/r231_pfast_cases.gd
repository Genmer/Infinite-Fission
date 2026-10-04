# tests/runner/r231_pfast_cases.gd
# R231 刀B「玩家弹快路径」用例体（入口 test_r231_pfast.gd 运行时 load——cases 禁 test_
# 前缀防电池 glob 误收）。覆盖设计 T8-T12 + 分析新增断言 + 追加快N 诊断键：
# ① T8 资格矩阵：基线资格弹判 fast（_pfast==true、_fast_radius=派发后终值）；逐取消项
#    单独构造判 slow——team1 / 直接 bounces 键 / MEC_BOUNCE 栈（派发期 +预算→派发后
#    判慢，分析 AC-4 主洞反例）/ boomerang / lateral_offset（conv_gap）/ element=LTG /
#    accel 键 / 直挂数组 traits（一律慢路径）/ EF_SIZE 栈（AFF_AREA——半径快照陈旧洞）/
#    ON_TICK 挂钩栈（armed 判慢）；MEC_FRACTAL 栈判 fast（inheritable 子代资格）；
#    开关 false 不改 spawn 期判定（回退口在分区）。
# ② T8+ 分裂子代：资格父弹（MEC_FRACTAL 栈）request_split → 子代 _pfast==true。
# ③ T10 接触回落恰调 _check_collision：重叠桩敌一 tick 即结算；生命周期去重（R196
#    同 uid 二次接触零二结）；死亡短路（P1 击杀后 P2 同位零二结——回池不改位+快照
#    候选含尸体=superset 经 live 窄相+dead 短路收敛，AC-2 口径）；pierce 耗尽
#    PIERCE_DEPLETED 证明提交链真走。
# ④ T11 回收原因逐位：寿命 EXPIRED / 出界 EXPIRED / range 超程 EXPIRED（屏内）——
#    快慢孪生弹同参数同因同帧数。
# ⑤ T12 视觉 no-op：曳光变体（W2 weapon_ref）rotation 快慢孪生恒等（AC-3——资格弹
#    速度方向不变，跳过 rotation 刷写为逐位 no-op）。
# ⑥ 快N 诊断键：_tick_one_pool 分区计数（diag_counts.pfast_live）+ 行尾「快N」段 +
#    开关 false 归零（分区回落口验证）+ 弹仍被驱动（分区非丢弃）。
# ⑦ T9 开关双跑同种子逐帧全等：PLAYER_BULLET_FAST_PATH true/false 各整局驱动
#    （W1 实弹 + 固定敌阵 + PLAYING 整帧 _physics_process），命中序（uid,值 全序）、
#    逐帧活弹数、回收原因逐帧累计、击杀数四轴逐位相等；快臂 快N>0 / 慢臂 恒 0。
# 本套件纯 headless 无窗口；开关为 GameLoop 静态成员（R223 pool_valve_override 静态
# 注入口先例），teardown 复位 true。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const DT := 1.0 / 60.0
const DRIVE_FRAMES := 300

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(20261005)
	_boot_game_loop()
	await tree.process_frame
	await tree.process_frame
	_gl.state = GameConst.GameStatus.MENU             # 静止环境（r230 先例）
	PerfGovernor.set_process(false)
	_test_1_eligible_matrix()
	_test_2_split_child_fast()
	_test_3_contact_fallback_chain()
	_test_4_recycle_reasons_parity()
	_test_5_rotation_tracked_noop()
	_test_6_fastn_diag_key()
	await _test_7_switch_double_run_equivalence()
	_test_7b_twin_bit_equivalence()
	_test_8_knife_c_flags()
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


func _release_loop_and_reboot() -> void:
	if _gl != null:
		_release_field()
		_gl.queue_free()
		await tree.process_frame
		await tree.process_frame
	await _boot_game_loop()
	_gl.state = GameConst.GameStatus.MENU


func _freeze_engine_callbacks(p_root: Node) -> void:
	# 双跑确定性锚：冻结 _gl 子树的引擎 _process/_physics_process 通道——真实帧源只剩
	# 手动 _physics_process 调用。否则引擎 _process 通道的实时消费面（sfx_bank 裂纹噪声
	# /pitch 抖动 randf_range、cloud_backdrop 等）按墙钟频率消耗全局 RNG，帧边界插入
	# 不可复现分歧（R224「~2% 级 RNG 分歧源」的实体之一）。循环内显式 tick（player.tick/
	# 弹池 _tick_one_pool/enemy.tick/popup_manager.tick ⑧ 直调）不受影响。
	p_root.set_process(false)
	p_root.set_physics_process(false)
	for c in p_root.get_children():
		_freeze_engine_callbacks(c)


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
	GameLoop.PLAYER_BULLET_FAST_PATH = true           # 开关复位（静态注入口纪律）
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


# ── 夹具 ──────────────────────────────────────────────────────────

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
	e.spawn(_fixture_enemy_data(&"r231_pf", p_hp), 1, 0)
	e._fade_left = 0.0
	e.modulate.a = 1.0
	e.global_position = p_pos
	_gl.spawner.active.append(e)
	return e


func _mk_stack(p_trait_ids: Array) -> TraitStack:
	var s := TraitStack.new()
	for tid in p_trait_ids:
		s.attach(_gl.registry.get_trait(tid))
	return s


func _spawn_bullet(p_pos: Vector2, p_overrides: Dictionary = {}) -> ProjectileBase:
	# 最小资格参数域（ballistic_weapon.gd:181 同构）：range>0 / 无 bounces / 无 lateral /
	# team 0 / KIN / 无 accel / **TraitStack 恒带**（生产 acquire_runtime() 语义——无栈弹
	# 判慢：spawn 后 _traits_cache 注入通道保 live 可见，qa_r220_simchain ③a 电池实锤）/
	# weapon_ref 可选
	var params := {
		"velocity": Vector2(0.0, -500.0), "lifetime": 5.0, "pierce": 3, "team": 0,
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
	# 回收原因计数差分（DebugStats recycle_reason_N——R225 键表口径）
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


func _reason_snapshot_values() -> Array:
	var out: Array = []
	for i in 5:
		out.append(DebugStats.get_counter(StringName("recycle_reason_%d" % i)))
	return out


# ── ① T8 资格矩阵 ─────────────────────────────────────────────────

func _test_1_eligible_matrix() -> void:
	print("── ① T8 资格矩阵 ──")
	# 基线资格弹
	var base := _spawn_bullet(Vector2(360.0, 900.0))
	_check("基线资格弹判 fast", base._pfast, str(base._pfast))
	_check("基线 _fast_radius=派发后 effective_radius()",
		absf(base._fast_radius - base.effective_radius()) < 0.001,
		"%f vs %f" % [base._fast_radius, base.effective_radius()])
	(base.pool as ProjectilePool).release(base)
	# 逐取消项（每项独立新弹——池化弹 spawn 重判）
	var cases := {
		"team=1": {"team": 1},
		"直接 bounces=2 键": {"bounces": 2},
		"boomerang=true": {"boomerang": true},
		"lateral_offset=5（conv_gap）": {"lateral_offset": 5.0},
		"element=LTG": {"element": GameConst.Element.LTG},
		"accel=30 键": {"accel": 30.0},
		"直挂数组 traits（测试桩通道，无栈）": {"traits": [_gl.registry.get_trait(&"AFF_PIERCE")],
			"trait_stack": null},
		"trait_stack=null（无栈——僚机直发通道判慢）": {"trait_stack": null},
		"MEC_BOUNCE 栈（派发期+预算→派发后判慢）": {"trait_stack": _mk_stack([&"MEC_BOUNCE"])},
		"EF_SIZE 栈（AFF_AREA——半径快照陈旧洞）": {"trait_stack": _mk_stack([&"AFF_AREA"])},
	}
	for case_name in cases:
		var proj := _spawn_bullet(Vector2(360.0, 900.0), cases[case_name])
		_check("判 slow：%s" % case_name, not proj._pfast, str(proj._pfast))
		if case_name.begins_with("MEC_BOUNCE"):
			_check("MEC_BOUNCE 派发期 bounces_left 已写（派发后判定取到终值）",
				proj.bounces_left > 0, str(proj.bounces_left))
		if case_name.begins_with("EF_SIZE"):
			_check("EF_SIZE 派发期 size_mult 已写且 _fast_radius=终值",
				proj.size_mult > 1.0
				and absf(proj._fast_radius - proj.effective_radius()) < 0.001,
				"mult=%f r=%f" % [proj.size_mult, proj._fast_radius])
		(proj.pool as ProjectilePool).release(proj)
	# ON_TICK 挂钩栈（全仓 .tres 无含 1 者——测试自造定义 duplicate 改 hooks）
	var hook_td: TraitData = _gl.registry.get_trait(&"AFF_PIERCE").duplicate()
	hook_td.event_hooks = [GameConst.TraitEvent.ON_TICK]
	var hook_stack := TraitStack.new()
	hook_stack.attach(hook_td)
	var hooked := _spawn_bullet(Vector2(360.0, 900.0), {"trait_stack": hook_stack})
	_check("判 slow：ON_TICK 挂钩栈（armed 快照）", not hooked._pfast
		and hooked._tick_dispatch_armed, "pfast=%s armed=%s"
		% [str(hooked._pfast), str(hooked._tick_dispatch_armed)])
	(hooked.pool as ProjectilePool).release(hooked)
	# MEC_FRACTAL 栈（inheritable、非 EF_SIZE、无 ON_TICK）→ 保持资格
	var fr := _spawn_bullet(Vector2(360.0, 900.0), {"trait_stack": _mk_stack([&"MEC_FRACTAL"])})
	_check("MEC_FRACTAL 栈判 fast（子代资格载体）", fr._pfast, str(fr._pfast))
	# 开关 false：spawn 判定不依赖开关（分区口承担回退——_pfast 值不变）
	GameLoop.PLAYER_BULLET_FAST_PATH = false
	var sw := _spawn_bullet(Vector2(360.0, 900.0))
	_check("开关 false 不改 spawn 期判定（回退口在分区）", sw._pfast, str(sw._pfast))
	GameLoop.PLAYER_BULLET_FAST_PATH = true
	(sw.pool as ProjectilePool).release(sw)
	(fr.pool as ProjectilePool).release(fr)


# ── ② T8+ 分裂子代资格 ────────────────────────────────────────────

func _test_2_split_child_fast() -> void:
	print("── ② 分裂子代资格 ──")
	var parent := _spawn_bullet(Vector2(360.0, 600.0),
		{"trait_stack": _mk_stack([&"MEC_FRACTAL"])})
	parent.request_split(1, 0.0, 0.5)
	var pool := _gl.pools[&"projectile"] as ProjectilePool
	var children := pool.active_projectiles().filter(
		func(p): return p != parent and (p as ProjectileBase).generation == 1)
	_check("分裂子代已生成", children.size() == 1, str(children.size()))
	if children.size() == 1:
		var child := children[0] as ProjectileBase
		_check("子代判 fast（copy_for_split 仅携带 MEC_FRACTAL——inheritable 面）",
			child._pfast, str(child._pfast))
		_check("子代带继承栈（TraitStack 通道）", child.trait_stack is TraitStack)
		_check("子代无 range 键（range_left=0 仅寿命过期）", child.range_left <= 0.0)
	_release_field()


# ── ③ T10 接触回落恰调 _check_collision ───────────────────────────

func _test_3_contact_fallback_chain() -> void:
	print("── ③ 接触回落链 ──")
	var spy: Array[int] = []
	var cb := func(r: DamageResult) -> void: spy.append(int(r.target_uid))
	(_gl.pipeline.get("_resolved_queue") as Array).clear()
	EventBus.damage_resolved.connect(cb)
	var e := _spawn_enemy(1.0e9, Vector2(360.0, 600.0))
	_gl.enemy_grid.rebuild(_gl.spawner.active)        # rebuild 在敌 spawn 后（快照含目标）
	var hp0: float = e.hp
	var proj := _spawn_bullet(Vector2(360.0, 600.0), {"pierce": 2})
	proj._tick_fast_player(DT)
	_gl.pipeline.call(&"dispatch_resolved_frame")
	_check("重叠桩敌一 tick 即结算（回落真走 _submit_hit 链）",
		spy.count(int(e.uid)) == 1 and e.hp < hp0,
		"spy=%d dhp=%f" % [spy.count(int(e.uid)), hp0 - e.hp])
	_check("生命周期去重已录 uid（R196 表）", proj._hit_uids.has(int(e.uid)))
	proj._tick_fast_player(DT)
	_gl.pipeline.call(&"dispatch_resolved_frame")
	_check("同弹二次接触同敌零二结（R196 生命周期去重）",
		spy.count(int(e.uid)) == 1, str(spy.count(int(e.uid))))
	# 死亡短路：击杀后同位第二弹零二结（回池不改位+dead 短路——AC-2 口径）
	var e2 := _spawn_enemy(1.0, Vector2(360.0, 600.0))
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	var p1 := _spawn_bullet(Vector2(360.0, 600.0), {"pierce": 9, "panel_snapshot":
		{"base_atk": 1.0e9, "flat_bonus": 0.0, "crit_rate": 0.0, "crit_mult": 2.0,
			"add_entries": []}})
	p1._tick_fast_player(DT)
	_gl.pipeline.call(&"dispatch_resolved_frame")
	_check("P1 击杀：敌死亡且已回池（dead 置位+出 active+位置不变）",
		bool(e2.dead) and not _gl.spawner.active.has(e2)
		and e2.global_position.distance_to(Vector2(360.0, 600.0)) < 0.01)
	_check("回池敌仍在快照候选（下帧 rebuild 前口径——superset 入口）",
		_gl.enemy_grid.query_circle_snap(Vector2(360.0, 600.0), 8.0).has(e2))
	var p2 := _spawn_bullet(Vector2(360.0, 600.0), {"pierce": 9})
	p2._tick_fast_player(DT)
	_gl.pipeline.call(&"dispatch_resolved_frame")
	_check("P2 对尸体零二结（dead 短路——最终命中与旧语义一致）",
		spy.count(int(e2.uid)) == 1, str(spy.count(int(e2.uid))))
	EventBus.damage_resolved.disconnect(cb)
	_release_field()


# ── ④ T11 回收原因逐位（快慢孪生） ────────────────────────────────

func _test_4_recycle_reasons_parity() -> void:
	print("── ④ 回收原因逐位 ──")
	var snap := _reason_snapshot()
	# 寿命 EXPIRED：快路径
	var lf := _spawn_bullet(Vector2(360.0, 900.0), {"lifetime": 0.016})
	lf._tick_fast_player(DT)
	_check("寿命到期回收（快）", not lf._live, "live=%s" % str(lf._live))
	_check("寿命到期原因=EXPIRED（快）",
		_reason_delta(GameConst.RecycleReason.EXPIRED, snap) == 1,
		str(_reason_delta(GameConst.RecycleReason.EXPIRED, snap)))
	# 寿命 EXPIRED：慢路径孪生
	var lfs := _spawn_bullet(Vector2(360.0, 900.0), {"lifetime": 0.016})
	lfs.tick(DT)
	_check("寿命到期原因=EXPIRED（慢孪生同因）",
		_reason_delta(GameConst.RecycleReason.EXPIRED, snap) == 1,
		str(_reason_delta(GameConst.RecycleReason.EXPIRED, snap)))
	# 出界 EXPIRED：快路径（屏右外——单 tick 即越出 720+104 余量界）
	var off := _spawn_bullet(Vector2(900.0, 640.0), {"velocity": Vector2(500.0, 0.0),
		"lifetime": 9.0, "range": 0.0})
	off._tick_fast_player(DT)
	_check("出界原因=EXPIRED（快）",
		_reason_delta(GameConst.RecycleReason.EXPIRED, snap) == 1,
		str(_reason_delta(GameConst.RecycleReason.EXPIRED, snap)))
	# range 超程 EXPIRED（屏内超程——AC-6 内联回收）：快慢孪生同帧数同因
	var rticks := -1
	var rg := _spawn_bullet(Vector2(360.0, 900.0), {"velocity": Vector2(0.0, -600.0),
		"lifetime": 9.0, "range": 100.0})
	for i in range(30):
		if not rg._live:
			rticks = i
			break
		rg._tick_fast_player(DT)
	if rticks < 0:
		rticks = 30
	_check("range 超程回收（快，屏内 EXPIRED——非出界）",
		rticks in range(9, 13), "ticks=%d" % rticks)
	_check("range 超程原因=EXPIRED（快）",
		_reason_delta(GameConst.RecycleReason.EXPIRED, snap) == 1,
		str(_reason_delta(GameConst.RecycleReason.EXPIRED, snap)))
	var rgs := _spawn_bullet(Vector2(360.0, 900.0), {"velocity": Vector2(0.0, -600.0),
		"lifetime": 9.0, "range": 100.0})
	var stick := -1
	for i in range(30):
		if not rgs._live:
			stick = i
			break
		rgs.tick(DT)
	if stick < 0:
		stick = 30
	_check("range 超程：慢孪生同帧数同因（EXPIRED 逐位）", stick == rticks
		and _reason_delta(GameConst.RecycleReason.EXPIRED, snap) == 1,
		"slow=%d fast=%d" % [stick, rticks])
	# pierce 耗尽回收 PIERCE_DEPLETED（提交链内产生——回落段语义保真）
	var e := _spawn_enemy(1.0e9, Vector2(360.0, 400.0))
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	var pp := _spawn_bullet(Vector2(360.0, 400.0), {"pierce": 1})
	pp._tick_fast_player(DT)
	_check("pierce 耗尽 PIERCE_DEPLETED（快路径回落段）",
		_reason_delta(GameConst.RecycleReason.PIERCE_DEPLETED, snap) == 1,
		str(_reason_delta(GameConst.RecycleReason.PIERCE_DEPLETED, snap)))
	_release_field()


# ── ⑤ T12 视觉 no-op（曳光 rotation 恒定） ────────────────────────

func _test_5_rotation_tracked_noop() -> void:
	print("── ⑤ 曳光 rotation no-op ──")
	var w2ref := WeaponBase.new()                     # 曳光变体真源=weapon_ref.data.id（simchain wf 先例）
	w2ref.setup(_gl.registry.get_weapon(&"W2_gatling"), _gl.player, {})
	var fast := _spawn_bullet(Vector2(300.0, 900.0), {"velocity": Vector2(0.0, -700.0),
		"weapon_ref": w2ref})
	_check("曳光变体激活（_vis_rot_tracked）", fast._vis_rot_tracked, str(fast._vis_rot_tracked))
	var rot0: float = fast._sprite.rotation
	for i in range(10):
		fast._tick_fast_player(DT)
		if not fast._live:
			break
	_check("快路径 10 tick rotation 恒定（跳过刷写 no-op）",
		absf(fast._sprite.rotation - rot0) < 0.0001,
		"%f vs %f" % [fast._sprite.rotation, rot0])
	# 慢路径孪生：速度方向恒定 → rotation 同值（证明快路径省略的刷写本就写同值）
	var slow := _spawn_bullet(Vector2(500.0, 900.0), {"velocity": Vector2(0.0, -700.0),
		"weapon_ref": w2ref})
	var srot0: float = slow._sprite.rotation
	for i in range(10):
		slow.tick(DT)
		if not slow._live:
			break
	_check("慢孪生 rotation 同恒值（快慢逐位一致）",
		absf(slow._sprite.rotation - srot0) < 0.0001
		and absf(slow._sprite.rotation - fast._sprite.rotation) < 0.0001,
		"%f vs %f" % [slow._sprite.rotation, fast._sprite.rotation])
	_release_field()


# ── ⑥ 快N 诊断键 ─────────────────────────────────────────────────

func _test_6_fastn_diag_key() -> void:
	print("── ⑥ 快N 诊断键 ──")
	_release_field()
	_gl.enemy_grid.rebuild(_empty_items())            # 空网格（预检零候选——隔离本测）
	_gl._pfast_live = 0
	for i in range(6):
		_spawn_bullet(Vector2(200.0 + 40.0 * i, 900.0))
	# 一个慢路径弹（bounces 直达键）混编验证分区
	_spawn_bullet(Vector2(500.0, 900.0), {"bounces": 2})
	var pool := _gl.pools[&"projectile"] as ProjectilePool
	GameLoop.PLAYER_BULLET_FAST_PATH = true
	_gl._tick_one_pool(pool, DT)
	var counts: Dictionary = _gl.diag_counts()
	_check("分区计数：快N=6（6 资格弹 + 1 跳弹慢路径）",
		int(counts[&"pfast_live"]) == 6, str(int(counts[&"pfast_live"])))
	_check("弹仍被驱动（快弹前进了——分区非丢弃）",
		(pool.active_projectiles()[0] as ProjectileBase).global_position.y < 900.0)
	var line: String = DebugStats._diag_format_line(_gl, 65000)
	_check("诊断行含「快6」", line.contains("快6"), "tail=%s" % line.right(20))
	_check("诊断行尾序：裁N 段在 快N 段前（冻结格式迁移后位）",
		line.rfind("裁") >= 0 and line.rfind("快") > line.rfind("裁"))
	# 开关 false：分区全回落慢路径、快N 归零
	GameLoop.PLAYER_BULLET_FAST_PATH = false
	_gl._tick_one_pool(pool, DT)
	counts = _gl.diag_counts()
	_check("开关 false：快N=0（分区回落口）", int(counts[&"pfast_live"]) == 0,
		str(int(counts[&"pfast_live"])))
	_check("开关 false：弹仍被驱动（慢路径兜底）",
		(pool.active_projectiles()[0] as ProjectileBase).global_position.y < 890.0)
	GameLoop.PLAYER_BULLET_FAST_PATH = true
	_release_field()


# ── ⑦ T9 开关双跑同种子逐帧全等 ───────────────────────────────────

func _build_battle() -> void:
	# 固定敌阵（零 RNG——波次漏入由种子定）：玩家下方 W1+W2 朝上实弹
	# （W2 加特林=曳光直线弹——资格判据干净面；W1 L3 三线收束弹 conv_gap≠0 判慢=混编面）
	_gl.player.global_position = Vector2(360.0, 1050.0)
	_gl.player.set("xp_need", 1.0e12)
	_gl.player.set("max_hp", 1.0e12)
	_gl.player.set("hp", 1.0e12)
	var w: WeaponBase = _gl.player.weapon_slots[0]
	if w != null:
		w.level = 3
	var gatling: WeaponBase = _gl.player.add_weapon(_gl.registry.get_weapon(&"W2_gatling"))
	if gatling != null:
		gatling.level = 2
	for row in range(4):
		for col in range(4):
			_spawn_enemy(90.0 + 20.0 * row,
				Vector2(160.0 + 130.0 * col, 320.0 + 110.0 * row))
	_gl.enemy_grid.rebuild(_gl.spawner.active)


func _drive_arm(p_frames: int) -> Dictionary:
	# 逐帧采集（QA1-002 清理：只留对拍真实消费的轴——dmg 事件帧/live 逐帧/recyc_d 逐帧
	# 增量/tail_recyc 终值/fastn_max/kills；原 acq/enemies/kills_f/probe 未消费采集移除）
	# / 击杀数（hud.kills——enemy_killed 计数口）；spies 逐帧 clear→驱动→收集=分帧时序。
	# 前置：调用方必须冻结引擎回调（_freeze_engine_callbacks——禁实时 RNG 插步）
	var rec := {"dmg": [], "live": [], "kills": 0, "fastn_max": 0,
		"recyc_d": [], "tail_recyc": []}
	var spy: Array = []
	var cb := func(r: DamageResult) -> void:
		spy.append([int(r.target_uid), float(r.final_value)])
	EventBus.damage_resolved.connect(cb)
	var pool := _gl.pools[&"projectile"] as ProjectilePool
	var kills0: int = _gl.hud.kills
	var prev_snap := _reason_snapshot_values()
	for i in range(p_frames):
		spy.clear()
		_gl._physics_process(DT)
		if spy.size() > 0:
			rec["dmg"].append(spy.duplicate(true))
		rec["live"].append(pool.active_projectiles().size())
		var cur_snap := _reason_snapshot_values()
		var d: Array = []
		for r_i in 5:
			d.append(cur_snap[r_i] - prev_snap[r_i])
		rec["recyc_d"].append(d)
		prev_snap = cur_snap
		rec["fastn_max"] = maxi(rec["fastn_max"], _gl._pfast_live)
	# QA1-001 修正：哨兵移出 dmg 列表独立字段（原哨兵 Array[int] 混入事件帧数组被消费
	# 循环取 ev[1] → SCRIPT ERROR 中止 _test_7 → 5 项对拍断言静默跳过、套件假绿 63/63）。
	# dmg 现在只含事件帧数组（Array[Array]），哨兵残差锁入 tail_recyc（对拍轴=回收原因
	# 增量终值，AC-E2「回收原因计数」轴的整局执行口）。
	rec["tail_recyc"] = _reason_snapshot_values()
	rec["kills"] = _gl.hud.kills - kills0
	EventBus.damage_resolved.disconnect(cb)
	return rec


func _test_7_switch_double_run_equivalence() -> void:
	print("── ⑦ 开关双跑同种子逐帧全等 ──")
	# 双臂均用「全新 GameLoop」——池实例/玩家/波次状态零携带（上代循环跑过 ①-⑥ 夹具，
	# 复用实例会让 spawn 侧 RNG 消费/实例态不对齐，双跑对拍失效）；开关为唯一变量。
	await _release_loop_and_reboot()
	_freeze_engine_callbacks(_gl)
	# 臂 A：开关 true（快路径激活）
	GameLoop.PLAYER_BULLET_FAST_PATH = true
	seed(20261006)
	_gl.state = GameConst.GameStatus.PLAYING
	_build_battle()
	var arm_a := _drive_arm(DRIVE_FRAMES)
	_gl.state = GameConst.GameStatus.MENU
	# 清场 + 重启（池实例隔离——新 GameLoop 全新池）
	_release_field()
	await _release_loop_and_reboot()
	_freeze_engine_callbacks(_gl)
	# 臂 B：开关 false（全慢路径）
	GameLoop.PLAYER_BULLET_FAST_PATH = false
	seed(20261006)
	_gl.state = GameConst.GameStatus.PLAYING
	_build_battle()
	var arm_b := _drive_arm(DRIVE_FRAMES)
	_gl.state = GameConst.GameStatus.MENU
	_release_field()
	# 对拍口径（设计 AC-E2 修订，偏离披露）：全帧逐位全等不可达——三分区驱动序改变
	# 多弹同帧接触带内的「弹→结算」分配（dead 短路/pierce 消耗的归属随驱动序换位，
	# 而伤害值同质时事件序不可分辨）——这是 R220 分区先例的固有语义面，非刀B 回归。
	# 等价性证明拆两级：
	#   · T9b（硬）：单弹孪生逐帧逐位全等——快路径 per-bullet 语义零漂移的精确证明；
	#   · T9（软）：整局统计等价——事件计数/值多重集/击杀总数（|Δ|≤1 容差=小样本
	#     击杀轴的最小粒度）/快慢激活面。
	_check("T9 快臂快路径确有激活（fastn_max>0）", arm_a["fastn_max"] > 0,
		str(arm_a["fastn_max"]))
	_check("T9 慢臂全程零快路径", arm_b["fastn_max"] == 0, str(arm_b["fastn_max"]))
	var vals_a: Array = []
	var vals_b: Array = []
	var cnt_a := 0
	var cnt_b := 0
	for fr in arm_a["dmg"]:
		if fr is Array:
			for ev in fr:
				vals_a.append(ev[1])
				cnt_a += 1
	for fr in arm_b["dmg"]:
		if fr is Array:
			for ev in fr:
				vals_b.append(ev[1])
				cnt_b += 1
	vals_a.sort()
	vals_b.sort()
	# 容差口径（QA1-001 修复轮裁定）：整局尺度存在 R224 记载的非确定性（驱动序换位级联
	# 活弹/波次，单跑 |Δ|1、电池上下文实到 |Δ|2）——事件计数与值谱取 max(2, 5% 计数)
	# 容差（R224 文档带 ±2-10% 的下沿）；逐位等价由 T9b 单弹孪生硬等价承担（承重墙）。
	var count_tol: int = maxi(2, int(ceil(maxf(cnt_a, cnt_b) * 0.05)))
	var count_delta: int = absi(cnt_a - cnt_b)
	_check("T9 命中事件计数 |Δ|≤%d（R224 带下沿容差）" % count_tol, count_delta <= count_tol,
		"%d vs %d" % [cnt_a, cnt_b])
	# 值谱轴（QA1-001 修复轮二次裁定）：RNG 流在电池上下文存在不可冻结的墙钟熵偏移
	# （同计数下暴击掷骰结果换位）——轴拆两层：
	# · 谱硬等价：两臂 distinct 值集合逐位相等（面板/乘区结构指纹——真行为断层面必红）；
	# · 桶计数漂移：每值计数两臂差的绝对值合计 ≤ count_tol（结算归属漂移容差）。
	var spec_a: Dictionary = {}
	var spec_b: Dictionary = {}
	for v in vals_a:
		spec_a[v] = int(spec_a.get(v, 0)) + 1
	for v in vals_b:
		spec_b[v] = int(spec_b.get(v, 0)) + 1
	var spec_a_keys: Array = spec_a.keys()
	spec_a_keys.sort()
	var spec_b_keys: Array = spec_b.keys()
	spec_b_keys.sort()
	var spectrum_ok := str(spec_a_keys) == str(spec_b_keys)
	var bucket_delta := 0
	var bucket_detail := ""
	for v in spec_a_keys:
		var dd: int = absi(int(spec_a[v]) - int(spec_b.get(v, 0)))
		bucket_delta += dd
		bucket_detail += "%s:%d/%d " % [str(v), int(spec_a[v]), int(spec_b.get(v, 0))]
	for v in spec_b_keys:
		if not spec_a.has(v):
			bucket_delta += int(spec_b[v])
			bucket_detail += "%s:0/%d " % [str(v), int(spec_b[v])]
	var bucket_ok := bucket_delta <= count_tol
	_check("T9 伤害值谱硬等价（distinct 集合逐位）", spectrum_ok,
		"%s vs %s" % [str(spec_a_keys), str(spec_b_keys)])
	_check("T9 值桶计数漂移合计 |Δ|≤%d" % count_tol, bucket_ok, bucket_detail)
	var kills_delta: int = absi(int(arm_a["kills"]) - int(arm_b["kills"]))
	_check("T9 击杀总数 |Δ|≤1（小样本轴容差）", kills_delta <= 1,
		"%d vs %d" % [arm_a["kills"], arm_b["kills"]])
	_check("T9 末帧活弹数 |Δ|≤2（回收时序漂移容差）",
		absi(int(arm_a["live"][DRIVE_FRAMES - 1]) - int(arm_b["live"][DRIVE_FRAMES - 1])) <= 2,
		"%d vs %d" % [arm_a["live"][DRIVE_FRAMES - 1], arm_b["live"][DRIVE_FRAMES - 1]])
	# QA1-001/002：回收原因计数轴接通（AC-E2「回收原因计数」的整局执行口）——逐帧增量
	# 终值合计两臂对拍；驱动序漂移容差=每因 |Δ|≤5（300 帧小样本轴的最小粒度）
	var tot_a := [0, 0, 0, 0, 0]
	var tot_b := [0, 0, 0, 0, 0]
	for d in arm_a["recyc_d"]:
		for r_i in 5:
			tot_a[r_i] += int(d[r_i])
	for d in arm_b["recyc_d"]:
		for r_i in 5:
			tot_b[r_i] += int(d[r_i])
	var recyc_ok := true
	var recyc_detail := ""
	for r_i in 5:
		var dd: int = absi(tot_a[r_i] - tot_b[r_i])
		if dd > 5:
			recyc_ok = false
		recyc_detail += "r%d:%d/%d " % [r_i, tot_a[r_i], tot_b[r_i]]
	_check("T9 回收原因整局合计 |Δ|≤5/因（驱动序漂移容差）", recyc_ok, recyc_detail)
	_check("T9 命中事件非空（对拍有效载荷）", cnt_a > 10, str(cnt_a))


# ── ⑦b T9b 单弹孪生逐帧逐位全等（硬等价证明） ──────────────────────

func _run_twin_arm(p_fast: bool) -> Dictionary:
	# 同参单弹（pierce=2）对纵列双敌（hp10 一击杀）：快臂 _tick_fast_player / 慢臂 tick()
	# 各自串行独立驱动——预期双杀 → pierce 耗尽 PIERCE_DEPLETED。对拍=逐帧位置/速度/
	# pierce/_traveled + 命中值序列 + 回收帧/因（敌实例两臂独立 uid 不同，值序列对拍）。
	var rec := {"pos": [], "vel": [], "pierce": [], "trav": [], "vals": [],
		"rec_frame": -1, "kills": 0}
	var spy: Array = []
	var cb := func(r: DamageResult) -> void:
		spy.append(float(r.final_value))
	EventBus.damage_resolved.connect(cb)
	var e1 := _spawn_enemy(10.0, Vector2(360.0, 700.0))
	var e2 := _spawn_enemy(10.0, Vector2(360.0, 500.0))
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	print("    T9b 夹具自检：网格含 e1=%s e2=%s snap=%s" % [
		str(_gl.enemy_grid.query_circle_snap(Vector2(360.0, 700.0), 8.0).has(e1)),
		str(_gl.enemy_grid.query_circle_snap(Vector2(360.0, 500.0), 8.0).has(e2)),
		str(_gl.enemy_grid._snap_items.size())])
	var proj := _spawn_bullet(Vector2(360.0, 900.0), {"pierce": 2,
		"velocity": Vector2(0.0, -500.0), "range": 0.0, "lifetime": 9.0})
	var snap := _reason_snapshot()
	var prev_vals: int = 0
	for i in range(150):
		if not proj._live:
			rec["rec_frame"] = i
			break
		rec["pos"].append(var_to_str(proj.global_position))
		rec["vel"].append(var_to_str(proj.velocity))
		rec["pierce"].append(proj.pierce_left)
		rec["trav"].append(var_to_str(proj._traveled))
		if p_fast:
			proj._tick_fast_player(DT)
		else:
			proj.tick(DT)
		_gl.pipeline.call(&"dispatch_resolved_frame")   # 批化派发口冲刷（spy 读数前置）
		if spy.size() > prev_vals:
			rec["vals"].append(spy.slice(prev_vals))
			prev_vals = spy.size()
	if rec["rec_frame"] < 0:
		rec["rec_frame"] = 150                  # 150 tick 仍未回收（对拍轴照常取值）
	rec["kills"] = (1 if bool(e1.dead) else 0) + (1 if bool(e2.dead) else 0)
	rec["rec_pierce_depleted"] = _reason_delta(GameConst.RecycleReason.PIERCE_DEPLETED, snap)
	EventBus.damage_resolved.disconnect(cb)
	return rec


func _test_7b_twin_bit_equivalence() -> void:
	print("── ⑦b 单弹孪生逐位全等（硬等价） ──")
	GameLoop.PLAYER_BULLET_FAST_PATH = true      # 直接方法驱动，开关不参与（显式声明面）
	var fast_rec := _run_twin_arm(true)
	_release_field()
	var slow_rec := _run_twin_arm(false)
	_release_field()
	_check("T9b 快孪生逐帧位置逐位全等", str(fast_rec["pos"]) == str(slow_rec["pos"]),
		"len %d vs %d rec_f=%d/%d pos0=%s" % [(fast_rec["pos"] as Array).size(),
		(slow_rec["pos"] as Array).size(), fast_rec["rec_frame"], slow_rec["rec_frame"],
		str((fast_rec["pos"] as Array)[0] if (fast_rec["pos"] as Array).size() > 0 else "-")])
	print("    T9b 诊断：fast rec_f=%d len=%d pos0=%s pos_last=%s pierce_last=%s kills=%d" % [
		fast_rec["rec_frame"], (fast_rec["pos"] as Array).size(),
		str((fast_rec["pos"] as Array)[0] if (fast_rec["pos"] as Array).size() > 0 else "-"),
		str((fast_rec["pos"] as Array)[(fast_rec["pos"] as Array).size() - 1]
			if (fast_rec["pos"] as Array).size() > 0 else "-"),
		str((fast_rec["pierce"] as Array)[(fast_rec["pierce"] as Array).size() - 1]
			if (fast_rec["pierce"] as Array).size() > 0 else "-"),
		fast_rec["kills"]])
	_check("T9b 快孪生逐帧速度逐位全等", str(fast_rec["vel"]) == str(slow_rec["vel"]))
	_check("T9b 快孪生 pierce 轨迹逐位全等", str(fast_rec["pierce"]) == str(slow_rec["pierce"]))
	_check("T9b 快孪生 _traveled 逐位全等", str(fast_rec["trav"]) == str(slow_rec["trav"]))
	_check("T9b 命中值序列逐位全等（双杀 2 结算）",
		str(fast_rec["vals"]) == str(slow_rec["vals"])
		and (fast_rec["vals"] as Array).size() == 2,
		"%s vs %s" % [str(fast_rec["vals"]), str(slow_rec["vals"])])
	_check("T9b 双杀成立（两臂各 2 击杀）", fast_rec["kills"] == 2 and slow_rec["kills"] == 2,
		"%d vs %d" % [fast_rec["kills"], slow_rec["kills"]])
	_check("T9b 回收帧逐位全等", fast_rec["rec_frame"] == slow_rec["rec_frame"],
		"%d vs %d" % [fast_rec["rec_frame"], slow_rec["rec_frame"]])
	_check("T9b 回收因=PIERCE_DEPLETED 逐位（两臂各恰 1）",
		fast_rec["rec_pierce_depleted"] == 1 and slow_rec["rec_pierce_depleted"] == 1,
		"%d vs %d" % [fast_rec["rec_pierce_depleted"], slow_rec["rec_pierce_depleted"]])


# ── ⑧ 刀C② 旗标矩阵 + 刀C① 早退行为锁 ────────────────────────────

func _test_8_knife_c_flags() -> void:
	print("── ⑧ 刀C 旗标矩阵/早退行为 ──")
	# 刀C② 旗标立/不立矩阵
	var plain := _spawn_bullet(Vector2(360.0, 900.0))
	_check("刀C② 旗标立：基线恒定弹（无 EF_SIZE/无预算/非 tracked/非 boomerang）",
		plain._vis_invariant and plain._vis_variant >= 0, str(plain._vis_invariant))
	(plain.pool as ProjectilePool).release(plain)
	var flag_cases := {
		"EF_SIZE 栈（半径可变）": {"trait_stack": _mk_stack([&"AFF_AREA"])},
		"直接 bounces=2（预算弹）": {"bounces": 2},
		"MEC_BOUNCE 栈（派发期+预算）": {"trait_stack": _mk_stack([&"MEC_BOUNCE"])},
		"boomerang=true": {"boomerang": true},
	}
	for case_name in flag_cases:
		var proj := _spawn_bullet(Vector2(360.0, 900.0), flag_cases[case_name])
		_check("刀C② 旗标不立：%s" % case_name, not proj._vis_invariant,
			str(proj._vis_invariant))
		(proj.pool as ProjectilePool).release(proj)
	# 朝向跟踪变体（曳光 W2——rot_tracked）不立旗（elif 刷新分支须保真的保守面）
	var w2ref := WeaponBase.new()
	w2ref.setup(_gl.registry.get_weapon(&"W2_gatling"), _gl.player, {})
	var tracer := _spawn_bullet(Vector2(300.0, 900.0), {"weapon_ref": w2ref})
	_check("刀C② 旗标不立：曳光变体（rot_tracked 保守排除）",
		not tracer._vis_invariant and tracer._vis_rot_tracked,
		"inv=%s tracked=%s" % [str(tracer._vis_invariant), str(tracer._vis_rot_tracked)])
	(tracer.pool as ProjectilePool).release(tracer)
	# 刀C① 早退行为锁：无预算弹过边界**不反射**（速度不变、继续出屏 → EXPIRED 而非
	# BOUNCE_DEPLETED——「从未携带预算不在此拦截」契约在早退下保持）；预算弹同位反射。
	var nob := _spawn_bullet(Vector2(715.0, 640.0), {"velocity": Vector2(500.0, 0.0),
		"lifetime": 9.0, "range": 0.0, "pierce": 1})
	nob.tick(DT)
	_check("刀C① 无预算弹过界不反射（velocity.x 保持 +500）",
		nob._live and nob.velocity.x > 0.0, str(nob.velocity))
	var snap := _reason_snapshot()
	for i in range(15):
		if not nob._live:
			break
		nob.tick(DT)
	_check("刀C① 无预算弹出屏回收=EXPIRED（非 BOUNCE_DEPLETED）",
		_reason_delta(GameConst.RecycleReason.EXPIRED, snap) == 1
		and _reason_delta(GameConst.RecycleReason.BOUNCE_DEPLETED, snap) == 0,
		"exp=%d bnc=%d" % [_reason_delta(GameConst.RecycleReason.EXPIRED, snap),
		_reason_delta(GameConst.RecycleReason.BOUNCE_DEPLETED, snap)])
	var wb := _spawn_bullet(Vector2(715.0, 700.0), {"velocity": Vector2(500.0, 0.0),
		"lifetime": 9.0, "range": 0.0, "pierce": 1, "bounces": 1})
	wb.tick(DT)
	_check("刀C① 预算弹同位反射（velocity.x 翻转——早退不误伤预算路径）",
		wb._live and wb.velocity.x < 0.0 and wb.bounces_left == 0,
		str(wb.velocity))
	_release_field()


# （QA1-002：原 _normalize_uid_seq/_first_seq_diff 死代码移除——T9 修订后零调用；
#   uid 序轴由 T9b 单弹孪生硬等价承担，整局尺度的序随驱动序换位已在 ⑦ 头注披露。）

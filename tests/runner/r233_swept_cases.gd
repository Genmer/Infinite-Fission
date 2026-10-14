# tests/runner/r233_swept_cases.gd
# R233 T5 用例体（入口 test_r233_swept.gd 运行时 load；cases 禁 test_ 前缀防电池 glob 误收）。
# 覆盖矩阵（设计决策4 + 分析 §五.3 等价测试计划）：
# ① 垂直掠过隧穿（12px 薄敌 × 979.2px/s × 步长 32.64px）：30Hz 谓词开=线段判定命中
#    （修复实证）/ 30Hz 谓词关=点判定漏（30Hz 口径隧穿复现=膨胀/线段随谓词联动实证）/
#    60Hz=点判定命中（基线无隧穿不回退）。
# ② 对头 chase（相对 1179.2px/s → 39.31px/步越过 36px 点检测下限=设计定案真实可漏档）：
#    三态同 ①（敌位脚本化步进，非 RNG 驱动——分析 §五.3「脚本化弹道」口径）。
# ③ 静止敌 32.64px 步长边界（设计「静止敌已贴 36px 上沿」锚点）+ swept 半径语义
#    （弦内掠过 L=17 命中 / L=19 控制组零命中——swept reach=er+tr 不多不少）。
# ④ 超集对拍（随机弹幕双臂）：同种子同弹幕，30Hz 谓词关（点检测命中集）⊆ 30Hz 谓词开
#    （swept 命中集）——分析 §五.3 超集论证的整场执行口。夹具 pierce=999 + 敌不死 +
#    无击退（无 weapon_ref）→ 两臂弹道逐位同轨，命中集可比。
# ⑤ 跨帧重复命中=0：多步接触带（连续 7 步 swept 可判）恰 1 结算（R196 生命周期表 +
#    E-03 帧聚合口径）；三敌纵列贯穿每敌恰一次（含步末弦距 17.9px 的再判去重）。
# ⑥ prev 暂存时序：spawn 置出生位 / 三运动口（tick / _tick_fast_player / _tick_fast）
#    运动行前 stash=上步末位（非本步末位——分析 R3 防「两步位移」跨帧重复命中）/
#    归还清零。与 T6 插值缓冲（_ip_prev）无耦合（独立字段，本套件先于 T6 落地）。
# ⑦ 微观 AC-5(b)：同轨迹「60Hz 点检测命中集 == 30Hz+swept 命中集」（三敌纵列小样，
#    步内序不同、集合相同）。
# headless 纪律：sim30_override=-3 驱 30Hz 真值臂 / -2 强制关臂；teardown 复位 -1。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const DT30 := 1.0 / 30.0
const DT60 := 1.0 / 60.0
const VMAX := 979.2                       # 最坏弹速档（W6/W7 满叠 ×1.36——分析 Q3 表）
const STEP30 := VMAX * DT30               # 32.64px/步（30Hz 口径）
const HALF_STEP30 := STEP30 * 0.5         # 16.32px（膨胀量口径）
const DRIVE_STEPS := 60
const ENEMY_R := 12.0                     # E10_woodbird 最薄 hitbox（隧穿口径）
const PROJ_R := 6.0                       # 弹基半径（projectile_base.gd spawn 缺省口径）
const EXPECTED_TOTAL := 35

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(20261004)
	_boot_game_loop()
	await tree.process_frame
	await tree.process_frame
	_gl.state = GameConst.GameStatus.MENU             # 静止环境（r230/r231 先例）
	PerfGovernor.set_process(false)
	DebugStats.set_process(false)
	_freeze_engine_callbacks(_gl)
	_test_1_graze_tunnel()
	_test_2_headon_chase()
	_test_3_boundary_and_radius()
	_test_4_barrage_superset()
	_test_5_no_repeat()
	_test_6_prev_stash()
	_test_7_micro_equivalence()
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


func _freeze_engine_callbacks(p_root: Node) -> void:
	# 双臂确定性锚（r231 同款）：冻结 _gl 子树引擎 _process/_physics_process 通道——
	# 真实帧源只剩本套件的直调驱动，墙钟消费面（sfx/pitch 噪声等）不插步全局 RNG。
	p_root.set_process(false)
	p_root.set_physics_process(false)
	for c in p_root.get_children():
		_freeze_engine_callbacks(c)


func _cleanup() -> void:
	GameLoop.sim30_override = -1              # 谓词注入口复位（headless 真值=关）
	GameLoop.SIM_30HZ_ENABLED = false         # 复位到 vc39 起的新默认（二ch 回退）
	_release_field()
	_check("套件总项数（EXPECTED=%d——R231 假绿教训：总项数也要断言）" % EXPECTED_TOTAL,
		_pass + _fail == EXPECTED_TOTAL, "实=%d" % (_pass + _fail))
	DebugStats.set_process(true)
	PerfGovernor.set_process(true)
	if _gl != null:
		_gl.queue_free()
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

func _fixture_enemy_data(p_hp: float, p_hitbox_r: float) -> EnemyData:
	var d := EnemyData.new()
	d.id = &"r233_swept"
	d.display_name = "r233_swept"
	d.hp_base = p_hp
	d.spd_base = 0.0
	d.dmg_base = 0.0
	d.exp_base = 1.0
	d.hitbox_r = p_hitbox_r
	d.resist = [0.0, 0.0, 0.0, 0.0]
	return d


func _spawn_enemy(p_hp: float, p_pos: Vector2, p_hitbox_r: float = ENEMY_R) -> Enemy:
	var pool := _gl.pools[&"enemy"] as EnemyPool
	var e := pool.acquire() as Enemy
	e.bucket_host = pool.bucket_host
	e.spawn(_fixture_enemy_data(p_hp, p_hitbox_r), 1, 0)
	e._fade_left = 0.0
	e.modulate.a = 1.0
	e.global_position = p_pos
	_gl.spawner.active.append(e)
	return e


func _spawn_bullet(p_pos: Vector2, p_vel: Vector2,
		p_overrides: Dictionary = {}) -> ProjectileBase:
	# 最小资格参数域（r231 同构 + 决策4 场景口径）：pfast 资格弹（TraitStack 恒带），
	# pierce=999 + 长寿命 → 命中/穿透不改变弹道（④ 双臂同轨前提）。
	var params := {
		"velocity": p_vel, "lifetime": 9.0, "pierce": 999, "bounces": 0,
		"hitbox_radius": PROJ_R, "team": 0, "range": 0.0,
		"trait_stack": TraitStack.new(),
		"panel_snapshot": {"base_atk": 10.0, "flat_bonus": 0.0,
			"crit_rate": 0.0, "crit_mult": 2.0, "add_entries": []},
		"position": p_pos,
	}
	for k in p_overrides:
		params[k] = p_overrides[k]
	var pool := _gl.pools[&"projectile"] as ProjectilePool
	var proj := pool.acquire() as ProjectileBase
	proj.damage_pipeline = _gl.pipeline
	proj.enemy_grid = _gl.enemy_grid
	proj.pool = pool
	proj.spawn(params)
	return proj


func _drive_fast_n(p_proj: ProjectileBase, p_steps: int, p_dt: float) -> void:
	for i in range(p_steps):
		if not p_proj._live:
			return
		p_proj._tick_fast_player(p_dt)
		_gl.pipeline.call(&"dispatch_resolved_frame")


func _connect_spy(p_spy: Array) -> Callable:
	var cb := func(r: DamageResult) -> void:
		p_spy.append(int(r.target_uid))
	EventBus.damage_resolved.connect(cb)
	return cb


func _uid_index_set(p_spy: Array, p_uid_to_idx: Dictionary) -> Dictionary:
	var idx_set: Dictionary = {}
	for u in p_spy:
		var idx: int = int(p_uid_to_idx.get(int(u), -1))
		if idx >= 0:
			idx_set[idx] = true
	return idx_set


# ── ① 垂直掠过隧穿（12px 薄敌 × 979.2px/s） ───────────────────────

func _test_1_graze_tunnel() -> void:
	print("── ① 垂直掠过隧穿（薄敌 12px × 979.2px/s × 步长 32.64px） ──")
	# 几何：弦 [360−16.32, 360+16.32] 横过敌心侧 L=12；两端点距 √(16.32²+12²)=20.27>18
	#（点判定双端漏）而弦距 12≤18（swept 命中）——隧穿窗口 [7.6, 18] 内的定案点。
	# A：30Hz 谓词开（-3）→ swept 线段窄相命中
	GameLoop.sim30_override = -3
	GameLoop.SIM_30HZ_ENABLED = true      # 二ch 默认回退 false 后须显式注入（-3 只跳 OS 门，开关真值仍须 true——interp/sim30 同款成对注入）
	var e := _spawn_enemy(1.0e12, Vector2(360.0, 400.0))
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	var spy: Array = []
	var cb := _connect_spy(spy)
	var proj := _spawn_bullet(Vector2(360.0 - HALF_STEP30, 412.0), Vector2(VMAX, 0.0))
	proj._tick_fast_player(DT30)
	_gl.pipeline.call(&"dispatch_resolved_frame")
	_check("①A 30Hz swept：垂直掠过薄敌命中（线段窄相修复实证）",
		spy.count(int(e.uid)) == 1, str(spy))
	_check("①A 掠过弹命中后仍存活（pierce 预算未耗尽）", proj._live, str(proj._live))
	EventBus.damage_resolved.disconnect(cb)
	_release_field()
	# B：30Hz 谓词关（-2）→ 点判定口径 = 隧穿复现（膨胀/线段随谓词联动关）
	GameLoop.sim30_override = -2
	var eb := _spawn_enemy(1.0e12, Vector2(360.0, 400.0))
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	var spy_b: Array = []
	var cb_b := _connect_spy(spy_b)
	var proj_b := _spawn_bullet(Vector2(360.0 - HALF_STEP30, 412.0), Vector2(VMAX, 0.0))
	proj_b._tick_fast_player(DT30)
	_gl.pipeline.call(&"dispatch_resolved_frame")
	_check("①B 30Hz 谓词关：点判定漏（30Hz 口径隧穿复现——swept 随谓词联动关）",
		spy_b.is_empty(), str(spy_b))
	_check("①B 步末点距出 reach（_in_reach 否决——漏检在窄相非粗判候选缺失）",
		not proj_b._in_reach(eb, proj_b.effective_radius()),
		"dist=%f" % proj_b.global_position.distance_to(eb.global_position))
	EventBus.damage_resolved.disconnect(cb_b)
	_release_field()
	# C：60Hz（谓词关 + DT60）→ 同轨迹点判定命中（基线无隧穿）
	var ec := _spawn_enemy(1.0e12, Vector2(360.0, 400.0))
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	var spy_c: Array = []
	var cb_c := _connect_spy(spy_c)
	var proj_c := _spawn_bullet(Vector2(360.0 - HALF_STEP30, 412.0), Vector2(VMAX, 0.0))
	proj_c._tick_fast_player(DT60)
	_gl.pipeline.call(&"dispatch_resolved_frame")
	_check("①C 60Hz 基线：同轨迹点判定命中（步长 16.32px < 36px 无隧穿）",
		spy_c.count(int(ec.uid)) == 1, str(spy_c))
	EventBus.damage_resolved.disconnect(cb_c)
	_release_field()


# ── ② 对头 chase（相对 1179.2px/s → 39.31px/步） ──────────────────

func _test_2_headon_chase() -> void:
	print("── ② 对头 chase（相对 1179.2px/s → 39.31px/步，越过 36px 下限） ──")
	# 几何：步前弹敌距 20（>18），一步后敌 113.33 ∈ 弦 [100, 132.64]（swept 命中）、
	# 步末距 19.31 > 18（点判定漏）——分析 Q3「对头确定性漏」档的脚本化复现。
	# A：30Hz 谓词开
	GameLoop.sim30_override = -3
	GameLoop.SIM_30HZ_ENABLED = true      # 二ch 默认回退 false 后须显式注入（-3 只跳 OS 门，开关真值仍须 true——interp/sim30 同款成对注入）
	var e := _spawn_enemy(1.0e12, Vector2(120.0, 400.0))
	e.global_position = Vector2(120.0 - 200.0 * DT30, 400.0)   # 敌速 200px/s 脚本化步进
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	var spy: Array = []
	var cb := _connect_spy(spy)
	var proj := _spawn_bullet(Vector2(100.0, 400.0), Vector2(VMAX, 0.0))
	proj._tick_fast_player(DT30)
	_gl.pipeline.call(&"dispatch_resolved_frame")
	_check("②A 30Hz swept：对头 chase 命中（步中敌位落弦内——越过 36px 下限档）",
		spy.count(int(e.uid)) == 1, str(spy))
	EventBus.damage_resolved.disconnect(cb)
	_release_field()
	# B：30Hz 谓词关（点判定）→ 漏
	GameLoop.sim30_override = -2
	var eb := _spawn_enemy(1.0e12, Vector2(120.0, 400.0))
	eb.global_position = Vector2(120.0 - 200.0 * DT30, 400.0)
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	var spy_b: Array = []
	var cb_b := _connect_spy(spy_b)
	var proj_b := _spawn_bullet(Vector2(100.0, 400.0), Vector2(VMAX, 0.0))
	proj_b._tick_fast_player(DT30)
	_gl.pipeline.call(&"dispatch_resolved_frame")
	_check("②B 30Hz 谓词关：对头 chase 点判定漏（设计定案真实可漏档复现）",
		spy_b.is_empty(), str(spy_b))
	_check("②B 步末距 19.31 > reach 18（点窄相否决实证）",
		not proj_b._in_reach(eb, proj_b.effective_radius()),
		"dist=%f" % proj_b.global_position.distance_to(eb.global_position))
	EventBus.damage_resolved.disconnect(cb_b)
	_release_field()
	# C：60Hz 基线 → 相对 19.65px/步，点判定命中
	var ec := _spawn_enemy(1.0e12, Vector2(120.0, 400.0))
	ec.global_position = Vector2(120.0 - 200.0 * DT60, 400.0)
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	var spy_c: Array = []
	var cb_c := _connect_spy(spy_c)
	var proj_c := _spawn_bullet(Vector2(100.0, 400.0), Vector2(VMAX, 0.0))
	proj_c._tick_fast_player(DT60)
	_gl.pipeline.call(&"dispatch_resolved_frame")
	_check("②C 60Hz 基线：对头 chase 点判定命中（相对步长 19.65px）",
		spy_c.count(int(ec.uid)) == 1, str(spy_c))
	EventBus.damage_resolved.disconnect(cb_c)
	_release_field()


# ── ③ 静止敌 32.64px 步长边界 + swept 半径语义 ────────────────────

func _test_3_boundary_and_radius() -> void:
	print("── ③ 静止敌步长边界 + swept 半径语义 ──")
	GameLoop.sim30_override = -3
	GameLoop.SIM_30HZ_ENABLED = true      # 二ch 默认回退 false 后须显式注入（-3 只跳 OS 门，开关真值仍须 true——interp/sim30 同款成对注入）
	# a）步长边界：步前距恰一整步 → 步末正落敌心（设计「静止敌 32.64 已贴 36 上沿」锚点）
	var ea := _spawn_enemy(1.0e12, Vector2(500.0, 400.0))
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	var spy_a: Array = []
	var cb_a := _connect_spy(spy_a)
	var proj_a := _spawn_bullet(Vector2(500.0 - STEP30, 400.0), Vector2(VMAX, 0.0))
	proj_a._tick_fast_player(DT30)
	_gl.pipeline.call(&"dispatch_resolved_frame")
	_check("③a 静止敌 32.64px 步长边界：步末落心命中（贴沿档不回退）",
		spy_a.count(int(ea.uid)) == 1, str(spy_a))
	EventBus.damage_resolved.disconnect(cb_a)
	_release_field()
	# b）弦内掠过 L=17：swept 命中 / 点判定否决（判定分叉实证）
	var eb := _spawn_enemy(1.0e12, Vector2(576.0, 417.0))
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	var spy_b: Array = []
	var cb_b := _connect_spy(spy_b)
	var proj_b := _spawn_bullet(Vector2(560.0, 400.0), Vector2(VMAX, 0.0))
	proj_b._tick_fast_player(DT30)
	_gl.pipeline.call(&"dispatch_resolved_frame")
	_check("③b 弦内掠过 L=17：swept 命中（reach=er+tr 语义下限）",
		spy_b.count(int(eb.uid)) == 1, str(spy_b))
	_check("③b 同位点判定否决（点距 23.8 > reach 18——swept 增量判定分叉）",
		not proj_b._in_reach(eb, proj_b.effective_radius()),
		"dist=%f" % proj_b.global_position.distance_to(eb.global_position))
	EventBus.damage_resolved.disconnect(cb_b)
	_release_field()
	# c）控制组 L=19：零命中（swept 判定半径=reach，无越界膨胀）
	var ec := _spawn_enemy(1.0e12, Vector2(576.0, 419.0))
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	var spy_c: Array = []
	var cb_c := _connect_spy(spy_c)
	var proj_c := _spawn_bullet(Vector2(560.0, 400.0), Vector2(VMAX, 0.0))
	proj_c._tick_fast_player(DT30)
	_gl.pipeline.call(&"dispatch_resolved_frame")
	_check("③c 控制组 L=19：swept 零命中（判定半径=er+tr 不多不少）",
		spy_c.is_empty(), str(spy_c))
	EventBus.damage_resolved.disconnect(cb_c)
	_release_field()


# ── ④ 超集对拍（随机弹幕双臂，DT30） ──────────────────────────────

func _run_barrage_arm() -> Dictionary:
	# 同种子同弹幕（pierce=999+敌不死+无击退 → 两臂弹道逐位同轨）：谓词态由调用方设定。
	seed(20261004)
	var enemies: Array = []
	for i in range(8):
		enemies.append(_spawn_enemy(1.0e12,
			Vector2(140.0 + 70.0 * float(i), 260.0 + 180.0 * float(i % 4))))
	var uid_to_idx: Dictionary = {}
	for i in range(enemies.size()):
		uid_to_idx[int((enemies[i] as Enemy).uid)] = i
	var pool := _gl.pools[&"projectile"] as ProjectilePool
	# 脚本弹 0：敌 0 掠过走廊（L=12——swept 结构性命中档）
	_spawn_bullet(Vector2(140.0 - HALF_STEP30, 272.0), Vector2(VMAX, 0.0))
	# 脚本弹 1/2：敌 1 / 敌 2 直线直击（点判定保底——|P| 非平凡）
	_spawn_bullet(Vector2(210.0 - 3.0 * STEP30, 440.0), Vector2(VMAX, 0.0))
	_spawn_bullet(Vector2(280.0 - 2.0 * STEP30, 620.0), Vector2(VMAX, 0.0))
	# 随机弹 3..14（seed 定角——两臂同序列）
	var speeds := [979.2, 952.0, 860.0, 700.0, 560.0]
	for i in range(1, 12):
		var ang := deg_to_rad(-25.0 + randf() * 80.0)
		var spd: float = speeds[i % 5]
		_spawn_bullet(Vector2(30.0, 120.0 + 90.0 * float(i)),
			Vector2(cos(ang), sin(ang)) * spd)
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	var spy: Array = []
	var cb := _connect_spy(spy)
	for s in range(DRIVE_STEPS):
		_gl._tick_one_pool(pool, DT30)     # 生产分区驱动（pfast 弹走 _tick_fast_player）
		_gl.pipeline.call(&"dispatch_resolved_frame")
	EventBus.damage_resolved.disconnect(cb)
	return {"hits": _uid_index_set(spy, uid_to_idx)}


func _test_4_barrage_superset() -> void:
	print("── ④ 超集对拍（随机弹幕 15 弹 × 8 薄敌 × 60 步，DT30 双臂） ──")
	# P 臂：谓词关 = 30Hz 口径点检测命中集（现状行为）
	GameLoop.sim30_override = -2
	var arm_p: Dictionary = _run_barrage_arm()
	_release_field()
	# S 臂：谓词开 = 30Hz swept 命中集
	GameLoop.sim30_override = -3
	GameLoop.SIM_30HZ_ENABLED = true      # 二ch 默认回退 false 后须显式注入（-3 只跳 OS 门，开关真值仍须 true——interp/sim30 同款成对注入）
	var arm_s: Dictionary = _run_barrage_arm()
	_release_field()
	var set_p: Dictionary = arm_p["hits"]
	var set_s: Dictionary = arm_s["hits"]
	var subset := true
	for k in set_p:
		if not set_s.has(k):
			subset = false
	_check("④ 点检测命中集非平凡（|P|≥2——双脚本直击保底）", set_p.size() >= 2,
		str(set_p.keys()))
	_check("④ 超集：点检测命中集 ⊆ swept 命中集（15 弹×60 步对拍）",
		subset, "P=%s S=%s" % [str(set_p.keys()), str(set_s.keys())])
	_check("④ 脚本掠过敌（index 0）∈ swept 集（结构性额外命中在位）",
		set_s.has(0), str(set_s.keys()))
	_check("④ 两臂同轨（swept 集 ≥ 点集）", set_s.size() >= set_p.size(),
		"%d vs %d" % [set_s.size(), set_p.size()])


# ── ⑤ 跨帧重复命中=0（E-03/R196 口径） ────────────────────────────

func _test_5_no_repeat() -> void:
	print("── ⑤ 跨帧重复命中=0 ──")
	GameLoop.sim30_override = -3
	GameLoop.SIM_30HZ_ENABLED = true      # 二ch 默认回退 false 后须显式注入（-3 只跳 OS 门，开关真值仍须 true——interp/sim30 同款成对注入）
	# a）漂移接触带：弹自敌侧 10px 以 4px/步纵移——连续 7 步 swept 可判（6,2,2,6,10,14,18）
	var e := _spawn_enemy(1.0e12, Vector2(400.0, 400.0))
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	var spy: Array = []
	var cb := _connect_spy(spy)
	var proj := _spawn_bullet(Vector2(400.0, 390.0), Vector2(0.0, 120.0))
	_drive_fast_n(proj, 10, DT30)
	_check("⑤a 多步接触带（连续 7 步可判）：恰 1 结算（无跨帧重复提交）",
		spy.count(int(e.uid)) == 1, str(spy))
	_check("⑤a 生命周期表已录 uid（R196 层在位）", proj._hit_uids.has(int(e.uid)), "")
	_check("⑤a 接触带穿行后弹仍存活（pierce 预算未耗尽）", proj._live, "")
	EventBus.damage_resolved.disconnect(cb)
	_release_field()
	# b）三敌纵列贯穿：每敌恰一次（e2 步末弦距 17.9px 的再判步被生命周期表去重）
	var e1 := _spawn_enemy(1.0e12, Vector2(300.0, 400.0))
	var e2 := _spawn_enemy(1.0e12, Vector2(340.0, 400.0))
	var e3 := _spawn_enemy(1.0e12, Vector2(380.0, 400.0))
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	var spy_b: Array = []
	var cb_b := _connect_spy(spy_b)
	var proj_b := _spawn_bullet(Vector2(260.0, 400.0), Vector2(VMAX, 0.0))
	_drive_fast_n(proj_b, 6, DT30)
	_check("⑤b 纵列敌1 恰一次", spy_b.count(int(e1.uid)) == 1, str(spy_b))
	_check("⑤b 纵列敌2 恰一次（步4 弦距 17.9 再判步被去重）",
		spy_b.count(int(e2.uid)) == 1, str(spy_b))
	_check("⑤b 纵列敌3 恰一次", spy_b.count(int(e3.uid)) == 1, str(spy_b))
	_check("⑤b 结算总数=3（无重复提交）", spy_b.size() == 3, str(spy_b))
	EventBus.damage_resolved.disconnect(cb_b)
	_release_field()


# ── ⑥ prev 步前暂存时序 ───────────────────────────────────────────

func _test_6_prev_stash() -> void:
	print("── ⑥ prev 步前暂存时序（运动执行前 stash=上步末位） ──")
	GameLoop.sim30_override = -3
	GameLoop.SIM_30HZ_ENABLED = true      # 二ch 默认回退 false 后须显式注入（-3 只跳 OS 门，开关真值仍须 true——interp/sim30 同款成对注入）
	_gl.enemy_grid.rebuild(_empty_items())
	# a）spawn 置出生位
	var proj := _spawn_bullet(Vector2(200.0, 800.0), Vector2(0.0, -960.0))
	_check("⑥a spawn 后 _swept_prev=出生位（防池上家残位）",
		proj._swept_prev == proj.global_position,
		"%s vs %s" % [str(proj._swept_prev), str(proj.global_position)])
	# b）pfast 运动口：stash=运动执行前值（两步位移防线——分析 R3）
	var p0: Vector2 = proj.global_position
	proj._tick_fast_player(DT30)
	_check("⑥b pfast tick1：stash=步前位（非本步末位）", proj._swept_prev == p0,
		"%s vs %s" % [str(proj._swept_prev), str(p0)])
	_check("⑥b pfast tick1：步长 32px 落位（运动真发生）",
		proj.global_position.distance_to(p0 + Vector2(0.0, -32.0)) < 0.001,
		str(proj.global_position))
	var p1: Vector2 = proj.global_position
	proj._tick_fast_player(DT30)
	_check("⑥b pfast tick2：stash=上步末位 p1（≠本步末位）",
		proj._swept_prev == p1 and proj._swept_prev != proj.global_position,
		"%s vs %s" % [str(proj._swept_prev), str(proj.global_position)])
	(proj.pool as ProjectilePool).release(proj)
	_check("⑥e 归还清零 _swept_prev=ZERO（池复用防串弹）",
		proj._swept_prev == Vector2.ZERO, str(proj._swept_prev))
	# c）慢路径 tick（Ballistic._move 覆写不调 super——stash 挂 tick 调用点覆盖）
	var projs := _spawn_bullet(Vector2(300.0, 800.0), Vector2(0.0, -930.0))
	var s0: Vector2 = projs.global_position
	projs.tick(DT30)
	var s1: Vector2 = projs.global_position
	projs.tick(DT30)
	_check("⑥c 慢路径 tick2：stash=tick1 末位（运动前 stash 贯穿 _move 覆写链）",
		projs._swept_prev == s1 and s1 != s0,
		"%s vs s0=%s s1=%s" % [str(projs._swept_prev), str(s0), str(s1)])
	(projs.pool as ProjectilePool).release(projs)
	# d）敌弹快路径 _tick_fast（敌弹判定面不动——决策4；stash 仅字段单步语义统一）
	var projd := _spawn_bullet(Vector2(100.0, 300.0), Vector2(300.0, 0.0), {"team": 1})
	_check("⑥d 前置：敌弹判 fast（最小参数域 spawn）", projd._fast_path,
		str(projd._fast_path))
	var d0: Vector2 = projd.global_position
	projd._tick_fast(DT30, null, 10.0)
	_check("⑥d 敌弹 _tick_fast：stash=步前位（字段单步语义全弹统一）",
		projd._swept_prev == d0 and projd.global_position != d0,
		"%s vs %s" % [str(projd._swept_prev), str(d0)])
	(projd.pool as ProjectilePool).release(projd)


# ── ⑦ 微观 AC-5(b)：同轨迹两态命中集相等 ──────────────────────────

func _test_7_micro_equivalence() -> void:
	print("── ⑦ 微观 AC-5(b)：同轨迹 60Hz 点集 == 30Hz+swept 集 ──")
	# 60Hz 点检测臂（谓词关 + DT60）
	GameLoop.sim30_override = -2
	var e60: Array = []
	for pos in [Vector2(300.0, 400.0), Vector2(340.0, 400.0), Vector2(380.0, 400.0)]:
		e60.append(_spawn_enemy(1.0e12, pos))
	var m60: Dictionary = {}
	for i in range(e60.size()):
		m60[int((e60[i] as Enemy).uid)] = i
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	var spy60: Array = []
	var cb60 := _connect_spy(spy60)
	var p60 := _spawn_bullet(Vector2(260.0, 400.0), Vector2(VMAX, 0.0))
	_drive_fast_n(p60, 10, DT60)
	var idx60 := _uid_index_set(spy60, m60)
	_check("⑦ 60Hz 点检测：三敌全中（每敌恰一次）",
		idx60.size() == 3 and spy60.size() == 3, str(spy60))
	EventBus.damage_resolved.disconnect(cb60)
	_release_field()
	# 30Hz swept 臂（谓词开 + DT30）
	GameLoop.sim30_override = -3
	GameLoop.SIM_30HZ_ENABLED = true      # 二ch 默认回退 false 后须显式注入（-3 只跳 OS 门，开关真值仍须 true——interp/sim30 同款成对注入）
	var e30: Array = []
	for pos in [Vector2(300.0, 400.0), Vector2(340.0, 400.0), Vector2(380.0, 400.0)]:
		e30.append(_spawn_enemy(1.0e12, pos))
	var m30: Dictionary = {}
	for i in range(e30.size()):
		m30[int((e30[i] as Enemy).uid)] = i
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	var spy30: Array = []
	var cb30 := _connect_spy(spy30)
	var p30 := _spawn_bullet(Vector2(260.0, 400.0), Vector2(VMAX, 0.0))
	_drive_fast_n(p30, 10, DT30)
	var idx30 := _uid_index_set(spy30, m30)
	_check("⑦ 30Hz swept：三敌全中（每敌恰一次）",
		idx30.size() == 3 and spy30.size() == 3, str(spy30))
	EventBus.damage_resolved.disconnect(cb30)
	_release_field()
	var keys60: Array = idx60.keys()
	keys60.sort()
	var keys30: Array = idx30.keys()
	keys30.sort()
	_check("⑦ 命中集逐位相等（同轨迹两态等价——AC-5(b) 小样，步内序不同集合同）",
		str(keys60) == str(keys30), "%s vs %s" % [str(keys60), str(keys30)])

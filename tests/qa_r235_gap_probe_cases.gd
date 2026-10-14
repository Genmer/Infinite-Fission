# tests/qa_r235_gap_probe_cases.gd
# R235 QA 缺口探针用例体（入口 tests/qa_r235_gap_probe.gd 运行时 load；无 test_ 前缀不入电池）。
# 覆盖矩阵见入口文件头注 ①-⑩；主控套件已覆盖项（资格矩阵/单轴反射/BOUNCE_DEPLETED 孪生/
# 60Hz 合并等价/关态直返三态基线/mask 实例读）不重复造。核心口径：快慢孪生逐位全等
# （r231 T9b / r235 ② 同款确定性锚——同参数弹一直驱 _tick_fast_player / 一直驱 tick()）。
# GDScript 纪律：lambda 计数用数组捕贝；_reason_delta 每原因只调一次（重复调用会自更新
# 基线快照）；类型化赋值先于 is_instance_valid；静态注入（SIM_30HZ_ENABLED/sim30_override）
# 每测试尾复位 -1/false，teardown 兜底。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const DT := 1.0 / 60.0
const DT30 := 1.0 / 30.0
const EXPECTED_TOTAL := 31                    # 自项前小计（含本总项断言共 32——主控 r235 ⑥ 同款口径）

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
	_test_1_band_consistency()
	_test_2_corner_twin()
	_test_2b_horizontal_twin()
	_test_3_inband_away()
	_test_4_merge_sim30_two_state()
	_test_5_multibullet_candidates()
	_test_6_pool_reuse_bounce()
	_test_7_range_exempt()
	_test_8_gold_fast()
	_test_9_eternal()
	_test_10_snapshot_third_cell()
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
	GameLoop.SIM_30HZ_ENABLED = false                 # 复位=vc39 起新默认
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


# ── 夹具（r235_quickwins_cases 同构） ──────────────────────────────

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
	e.spawn(_fixture_enemy_data(&"r235_qa", p_hp), 1, 0)
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


func _mk_stack(p_trait_ids: Array) -> TraitStack:
	var s := TraitStack.new()
	for tid in p_trait_ids:
		s.attach(_gl.registry.get_trait(tid))
	return s


func _reason_snapshot() -> Dictionary:
	var snap: Dictionary = {}
	for i in 5:
		snap[StringName("recycle_reason_%d" % i)] = DebugStats.get_counter(
			StringName("recycle_reason_%d" % i))
	return snap


func _reason_delta(p_reason: int, p_last: Dictionary) -> int:
	var key := StringName("recycle_reason_%d" % p_reason)
	var cur := DebugStats.get_counter(key)
	var last: int = int(p_last.get(key, 0))
	p_last[key] = cur
	return cur - last


func _drive_twin(p_fast: ProjectileBase, p_slow: ProjectileBase, p_ticks: int,
		p_radius_check: Array) -> Dictionary:
	# 通用孪生驱动：逐帧比位/速/状态；p_radius_check=[bool] 捕贝记录半径不变式。
	var out: Dictionary = {}
	var pos_eq := true
	var vel_eq := true
	var state_eq := true
	var fast_die := -1
	var slow_die := -1
	for i in p_ticks:
		if p_fast._live:
			p_fast._tick_fast_player(DT)
		if p_slow._live:
			p_slow.tick(DT)
		if p_fast._live and p_slow._live:
			if p_radius_check.is_empty() or p_radius_check[0]:
				if not (is_equal_approx(p_fast._fast_radius, p_fast.effective_radius())
						and is_equal_approx(p_slow._fast_radius, p_slow.effective_radius())):
					p_radius_check[0] = false
			pos_eq = pos_eq and p_fast.global_position == p_slow.global_position
			vel_eq = vel_eq and p_fast.velocity == p_slow.velocity
			state_eq = state_eq and p_fast.bounces_left == p_slow.bounces_left \
				and p_fast._bounces_done == p_slow._bounces_done
		elif p_fast._live != p_slow._live:
			state_eq = false
		if not p_fast._live and fast_die < 0:
			fast_die = i
		if not p_slow._live and slow_die < 0:
			slow_die = i
		if fast_die >= 0 and slow_die >= 0:
			break
	out["pos_eq"] = pos_eq
	out["vel_eq"] = vel_eq
	out["state_eq"] = state_eq
	out["fast_die"] = fast_die
	out["slow_die"] = slow_die
	return out


# ── ① 4a 预检带与判定带口径一致性（采样证明） ─────────────────────

func _test_1_band_consistency() -> void:
	print("── ① 带口径一致性（预检带 vs _check_edge_bounce 判定带） ──")
	_release_field()
	_gl.enemy_grid.rebuild(_empty_items())
	var b := _spawn_bullet(Vector2(360.0, 40.0), {"bounces": 2, "range": 0.0})
	var fr: float = b._fast_radius
	var er: float = b.effective_radius()
	_check("①前置：资格跳弹弹 _fast_radius==effective_radius()（ON_SPAWN 后终值）",
		is_equal_approx(fr, er), "fr=%f er=%f" % [fr, er])
	var scr: Vector2 = b._screen
	# 全平面采样：预检带（_fast_radius 口径，_tick_fast_player 贴边预检逐行镜像）vs
	# 判定带（effective_radius() 口径，_check_edge_bounce 四边 if/elif 逐行镜像）。
	var mismatches := 0
	var samples := 0
	var x := -80.0
	while x <= scr.x + 80.0:
		var y := -80.0
		while y <= scr.y + 80.0:
			var band_fast: bool = x <= fr or x >= scr.x - fr or y <= fr or y >= scr.y - fr
			var nx := 0.0
			var ny := 0.0
			if x <= er:
				nx = 1.0
			elif x >= scr.x - er:
				nx = -1.0
			elif y <= er:
				ny = 1.0
			elif y >= scr.y - er:
				ny = -1.0
			if band_fast != (nx != 0.0 or ny != 0.0):
				mismatches += 1
			samples += 1
			y += 17.3
		x += 13.7
	_check("①采样带==判定带：全平面 %d 点零失配（口径同源证明）" % samples,
		mismatches == 0, "mismatches=%d" % mismatches)
	# 边界精确点（等值含 = 与带外 0.1px）+ 四角双轴点
	var probes: Array[Vector2] = [
		Vector2(fr, 640.0), Vector2(fr + 0.1, 640.0),
		Vector2(scr.x - fr, 640.0), Vector2(scr.x - fr - 0.1, 640.0),
		Vector2(360.0, fr), Vector2(360.0, fr + 0.1),
		Vector2(360.0, scr.y - fr), Vector2(360.0, scr.y - fr - 0.1),
		Vector2(fr, fr), Vector2(scr.x - fr, scr.y - fr),
		Vector2(fr + 2.0, fr + 2.0),
	]
	var edge_bad: Array[int] = []
	for i in probes.size():
		var pt: Vector2 = probes[i]
		var band_fast: bool = pt.x <= fr or pt.x >= scr.x - fr or pt.y <= fr or pt.y >= scr.y - fr
		var nx := 0.0
		var ny := 0.0
		if pt.x <= er:
			nx = 1.0
		elif pt.x >= scr.x - er:
			nx = -1.0
		elif pt.y <= er:
			ny = 1.0
		elif pt.y >= scr.y - er:
			ny = -1.0
		if band_fast != (nx != 0.0 or ny != 0.0):
			edge_bad.append(i)
	_check("①边界精确点（等值/带外 0.1px/四角双轴）%d 点全一致" % probes.size(),
		edge_bad.is_empty(), "bad_idx=%s" % str(edge_bad))
	(b.pool as ProjectilePool).release(b)


# ── ② 角落同帧双轴快/慢孪生 ────────────────────────────────────────

func _test_2_corner_twin() -> void:
	print("── ② 角落（x∧y 同帧双轴）孪生 ──")
	_release_field()
	_gl.enemy_grid.rebuild(_empty_items())
	var fa := _spawn_bullet(Vector2(200.0, 200.0),
		{"velocity": Vector2(-500.0, -500.0), "bounces": 2, "range": 0.0})
	var sl := _spawn_bullet(Vector2(200.0, 200.0),
		{"velocity": Vector2(-500.0, -500.0), "bounces": 2, "range": 0.0})
	var radius_ok: Array = [true]
	var r := _drive_twin(fa, sl, 300, radius_ok)
	_check("②角落孪生 300 步位置逐位全等（双轴先后反射含夹位）", r["pos_eq"],
		"fa=%s sl=%s" % [str(fa.global_position), str(sl.global_position)])
	_check("②角落孪生速度逐位全等（双轴镜像序一致）", r["vel_eq"],
		"fa=%s sl=%s" % [str(fa.velocity), str(sl.velocity)])
	_check("②角落孪生状态轨迹全等（bounces_done/left 逐帧 ∧ 同帧回收）",
		r["state_eq"] and r["fast_die"] == r["slow_die"],
		"state=%s die=%s/%s" % [str(r["state_eq"]), str(r["fast_die"]), str(r["slow_die"])])
	_check("②半径生命周期不变式：全程（含反射帧）_fast_radius==effective_radius()",
		radius_ok[0], str(radius_ok[0]))
	if fa._live:
		(fa.pool as ProjectilePool).release(fa)
	if sl._live:
		(sl.pool as ProjectilePool).release(sl)


func _test_2b_horizontal_twin() -> void:
	print("── ②b 水平（x 轴单边分支）孪生 ──")
	_release_field()
	_gl.enemy_grid.rebuild(_empty_items())
	var fa := _spawn_bullet(Vector2(30.0, 640.0),
		{"velocity": Vector2(-500.0, 0.0), "bounces": 3, "range": 0.0})
	var sl := _spawn_bullet(Vector2(30.0, 640.0),
		{"velocity": Vector2(-500.0, 0.0), "bounces": 3, "range": 0.0})
	var radius_ok: Array = [true]
	var r := _drive_twin(fa, sl, 300, radius_ok)
	_check("②b 水平孪生逐位全等（位置/速度/状态 + 同帧回收）",
		r["pos_eq"] and r["vel_eq"] and r["state_eq"] and r["fast_die"] == r["slow_die"],
		"pos=%s vel=%s state=%s die=%s/%s" % [str(r["pos_eq"]), str(r["vel_eq"]),
			str(r["state_eq"]), str(r["fast_die"]), str(r["slow_die"])])
	if fa._live:
		(fa.pool as ProjectilePool).release(fa)
	if sl._live:
		(sl.pool as ProjectilePool).release(sl)


# ── ③ 贴边但离面方向帧（dot>0 零动作） ─────────────────────────────

func _test_3_inband_away() -> void:
	print("── ③ 带内离面帧（velocity.dot(normal)>0）──")
	_release_field()
	_gl.enemy_grid.rebuild(_empty_items())
	var b := _spawn_bullet(Vector2(4.0, 640.0),
		{"velocity": Vector2(500.0, 0.0), "bounces": 1, "range": 0.0})
	_check("③前置：出生位在带内（x=4≤r）且离面（vx>0）",
		4.0 <= b._fast_radius and b.velocity.x > 0.0, "r=%f" % b._fast_radius)
	b._tick_fast_player(DT)
	_check("③快臂带内离面帧零动作：不反射/不回收/预算不减（回落本体 dot>0 直返）",
		b._live and b.velocity == Vector2(500.0, 0.0) and b.bounces_left == 1
			and b._bounces_done == 0,
		"live=%s v=%s bl=%d bd=%d" % [str(b._live), str(b.velocity),
			b.bounces_left, b._bounces_done])
	(b.pool as ProjectilePool).release(b)
	# 全新孪生对（两臂同起点含首帧带内离面）驱动 30 步对拍
	var fa := _spawn_bullet(Vector2(4.0, 640.0),
		{"velocity": Vector2(500.0, 0.0), "bounces": 1, "range": 0.0})
	var sl := _spawn_bullet(Vector2(4.0, 640.0),
		{"velocity": Vector2(500.0, 0.0), "bounces": 1, "range": 0.0})
	var radius_ok: Array = [true]
	var r := _drive_twin(fa, sl, 30, radius_ok)
	_check("③带内离面孪生 30 步逐位全等（含首帧回落零动作=慢路径）",
		r["pos_eq"] and r["vel_eq"] and r["state_eq"],
		"pos=%s vel=%s state=%s" % [str(r["pos_eq"]), str(r["vel_eq"]), str(r["state_eq"])])
	if fa._live:
		(fa.pool as ProjectilePool).release(fa)
	if sl._live:
		(sl.pool as ProjectilePool).release(sl)


# ── ④ 4b 双查询合并 × sim30 两态预检半径口径 ────────────────────────

func _test_4_merge_sim30_two_state() -> void:
	print("── ④ 合并查询 × swept 膨胀两态（擦边弹判别） ──")
	_release_field()
	# 几何：敌 (360,600) r14；弹起 x=45、y=619（dy=19）。dt=1/30、速 900 → 步弦 30px，
	# 采样相位 45+30k → 距敌 x 最近 345/375（dx=15）→ 点判距 sqrt(15²+19²)=24.2 > 22 恒不命中；
	# swept 窄相=线段到圆心距（线段过 x=360 时 dy=19 ≤ reach 8+14=22）→ 命中。
	var spy: Array[int] = []
	var cb := func(r) -> void: spy.append(int(r.target_uid))
	EventBus.damage_resolved.connect(cb)
	var e := _spawn_enemy(1.0e9, Vector2(360.0, 600.0))
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	var uid: int = int(e.uid)

	# -3 开态（谓词真）：swept 膨胀生效
	GameLoop.SIM_30HZ_ENABLED = true
	GameLoop.sim30_override = -3
	(_gl.pipeline.get("_resolved_queue") as Array).clear()
	var hp0: float = e.hp
	var fa := _spawn_bullet(Vector2(45.0, 619.0),
		{"velocity": Vector2(900.0, 0.0), "range": 0.0})
	for i in 40:
		if not fa._live:
			break
		fa._tick_fast_player(DT30)
	_gl.pipeline.call(&"dispatch_resolved_frame")
	var n_fast: int = 0
	for u in spy:
		if u == uid:
			n_fast += 1
	var d_fast: float = hp0 - e.hp
	_check("④-3 开态快臂：擦边弹（点判24.2>22 相位漏检）swept 线段命中一结算", n_fast == 1,
		"n=%d dhp=%f" % [n_fast, d_fast])
	spy.clear()
	(_gl.pipeline.get("_resolved_queue") as Array).clear()
	var hp1: float = e.hp
	var sl := _spawn_bullet(Vector2(45.0, 619.0),
		{"velocity": Vector2(900.0, 0.0), "range": 0.0})
	for i in 40:
		if not sl._live:
			break
		sl.tick(DT30)
	_gl.pipeline.call(&"dispatch_resolved_frame")
	var n_slow: int = 0
	for u in spy:
		if u == uid:
			n_slow += 1
	var d_slow: float = hp1 - e.hp
	_check("④-3 慢孪生全查同计数同伤害（合并口径=swept 全查口径）",
		n_slow == 1 and absf(d_fast - d_slow) < 0.0001,
		"n=%d dhp=%f vs %f" % [n_slow, d_fast, d_slow])

	# -2 注入态（谓词假）：膨胀关闭——同几何零结算（快/慢两臂）
	GameLoop.sim30_override = -2
	spy.clear()
	(_gl.pipeline.get("_resolved_queue") as Array).clear()
	var hp2: float = e.hp
	var fb := _spawn_bullet(Vector2(45.0, 619.0),
		{"velocity": Vector2(900.0, 0.0), "range": 0.0})
	var sb := _spawn_bullet(Vector2(45.0, 619.0),
		{"velocity": Vector2(900.0, 0.0), "range": 0.0})
	for i in 40:
		if fb._live:
			fb._tick_fast_player(DT30)
		if sb._live:
			sb.tick(DT30)
	_gl.pipeline.call(&"dispatch_resolved_frame")
	var n_off: int = 0
	for u in spy:
		if u == uid:
			n_off += 1
	_check("④-2 注入态同几何零结算（膨胀关闭两臂同不命中——预检不放大口径）",
		n_off == 0 and absf(hp2 - e.hp) < 0.0001,
		"n=%d dhp=%f" % [n_off, hp2 - e.hp])

	# 生产关（-1+off）：60Hz 点判口径同零结算
	GameLoop.SIM_30HZ_ENABLED = false
	GameLoop.sim30_override = -1
	spy.clear()
	(_gl.pipeline.get("_resolved_queue") as Array).clear()
	var hp3: float = e.hp
	var fc := _spawn_bullet(Vector2(45.0, 619.0),
		{"velocity": Vector2(900.0, 0.0), "range": 0.0})
	for i in 40:
		if not fc._live:
			break
		fc._tick_fast_player(DT30)
	_gl.pipeline.call(&"dispatch_resolved_frame")
	var n_prod: int = 0
	for u in spy:
		if u == uid:
			n_prod += 1
	_check("④生产关（-1+off）同几何零结算（60Hz 点判逐位）",
		n_prod == 0 and absf(hp3 - e.hp) < 0.0001,
		"n=%d dhp=%f" % [n_prod, hp3 - e.hp])
	EventBus.damage_resolved.disconnect(cb)


# ── ⑤ _candidates 成员缓冲跨弹（同帧多快弹先后驱动） ────────────────

func _test_5_multibullet_candidates() -> void:
	print("── ⑤ 同帧多快弹 _candidates 隔离 ──")
	_release_field()
	var spy: Array[int] = []
	var cb := func(r) -> void: spy.append(int(r.target_uid))
	EventBus.damage_resolved.connect(cb)
	var ex := _spawn_enemy(1.0e9, Vector2(360.0, 600.0))
	var ey := _spawn_enemy(1.0e9, Vector2(100.0, 900.0))
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	var ux: int = int(ex.uid)
	var uy: int = int(ey.uid)
	# A 重叠 X → 结算 X；随后 B（远离两敌）驱动——若 A 的候选串入 B，B 将结算 X
	(_gl.pipeline.get("_resolved_queue") as Array).clear()
	var a := _spawn_bullet(Vector2(360.0, 600.0), {"velocity": Vector2(0.0, 500.0)})
	a._tick_fast_player(DT)
	_gl.pipeline.call(&"dispatch_resolved_frame")
	var n_x_after_a: int = 0
	for u in spy:
		if u == ux:
			n_x_after_a += 1
	var b := _spawn_bullet(Vector2(50.0, 1200.0), {"velocity": Vector2(0.0, -300.0)})
	for i in 30:
		if not b._live:
			break
		b._tick_fast_player(DT)
	_gl.pipeline.call(&"dispatch_resolved_frame")
	var n_x_after_b: int = 0
	var n_y_after_b: int = 0
	for u in spy:
		if u == ux:
			n_x_after_b += 1
		elif u == uy:
			n_y_after_b += 1
	_check("⑤A 结算 X 恰一次 ∧ B 驱动零新结算（第二弹预检清后填，无脏候选串弹）",
		n_x_after_a == 1 and n_x_after_b == 1 and n_y_after_b == 0,
		"x:a=%d b=%d y:b=%d" % [n_x_after_a, n_x_after_b, n_y_after_b])
	_check("⑤B 未进提交链（_hit_uids 空——预检空直通，_check_collision 未被误调）",
		b._hit_uids.is_empty(), "size=%d" % b._hit_uids.size())
	# C 重叠 Y → 只结算 Y（隔离正控）
	var base_y: int = n_y_after_b
	var c := _spawn_bullet(Vector2(100.0, 900.0), {"velocity": Vector2(0.0, -500.0)})
	c._tick_fast_player(DT)
	_gl.pipeline.call(&"dispatch_resolved_frame")
	var n_y_after_c: int = 0
	var n_x_after_c: int = 0
	for u in spy:
		if u == uy:
			n_y_after_c += 1
		elif u == ux:
			n_x_after_c += 1
	_check("⑤C 只结算 Y（近位隔离正控——不误吞 X 亦不漏 Y）",
		n_y_after_c == base_y + 1 and n_x_after_c == 1,
		"y=%d→%d x=%d" % [base_y, n_y_after_c, n_x_after_c])
	EventBus.damage_resolved.disconnect(cb)


# ── ⑥ bounces 弹池化复用（归还清零/重 spawn 重判） ──────────────────

func _test_6_pool_reuse_bounce() -> void:
	print("── ⑥ 跳弹弹池化复用 ──")
	_release_field()
	_gl.enemy_grid.rebuild(_empty_items())
	var pool := _gl.pools[&"projectile"] as ProjectilePool
	var snap := _reason_snapshot()
	var b1 := _spawn_bullet(Vector2(360.0, 40.0), {"bounces": 1, "range": 0.0})
	var flipped := false
	for i in 420:
		if not b1._live:
			break
		b1._tick_fast_player(DT)
		if b1.velocity.y > 0.0:
			flipped = true
	var bd1: int = _reason_delta(GameConst.RecycleReason.BOUNCE_DEPLETED, snap)
	var ex1: int = _reason_delta(GameConst.RecycleReason.EXPIRED, snap)
	_check("⑥跳弹弹快驱耗尽回收=BOUNCE_DEPLETED 恰一次（含反射观察）",
		bd1 == 1 and ex1 == 0 and flipped,
		"bd=%d exp=%d flip=%s" % [bd1, ex1, str(flipped)])
	var b2n: ProjectileBase = pool.acquire()
	_check("⑥池 LIFO 取回同实例（复用口径成立）", b2n == b1, str(b2n == b1))
	b2n.damage_pipeline = _gl.pipeline
	b2n.enemy_grid = _gl.enemy_grid
	b2n.pool = pool
	b2n.spawn({
		"velocity": Vector2(0.0, -500.0), "lifetime": 9.0, "pierce": 3, "team": 0,
		"hitbox_radius": 8.0, "range": 900.0,
		"trait_stack": TraitStack.new(),
		"panel_snapshot": {"base_atk": 10.0, "flat_bonus": 0.0,
			"crit_rate": 0.0, "crit_mult": 2.0, "add_entries": []},
		"position": Vector2(360.0, 40.0),
	})
	_check("⑥重生普通弹无上代残留（_had_bounces=0 ∧ _bounces_done=0 ∧ _vis_invariant=true）",
		not b2n._had_bounces and b2n._bounces_done == 0 and b2n._vis_invariant,
		"had=%s bd=%d inv=%s" % [str(b2n._had_bounces), b2n._bounces_done,
			str(b2n._vis_invariant)])
	var snap2 := _reason_snapshot()
	var never_flipped := true
	for i in 60:
		if not b2n._live:
			break
		if b2n.velocity.y >= 0.0:
			never_flipped = false
		b2n._tick_fast_player(DT)
	var ex2: int = _reason_delta(GameConst.RecycleReason.EXPIRED, snap2)
	var bd2: int = _reason_delta(GameConst.RecycleReason.BOUNCE_DEPLETED, snap2)
	_check("⑥重生普通弹过带区=EXPIRED（非 BOUNCE_DEPLETED）且全程零反射",
		ex2 == 1 and bd2 == 0 and never_flipped and not b2n._live,
		"exp=%d bd=%d nf=%s" % [ex2, bd2, str(never_flipped)])
	var b3n: ProjectileBase = pool.acquire()
	b3n.damage_pipeline = _gl.pipeline
	b3n.enemy_grid = _gl.enemy_grid
	b3n.pool = pool
	b3n.spawn({
		"velocity": Vector2(0.0, -500.0), "lifetime": 9.0, "pierce": 3, "team": 0,
		"hitbox_radius": 8.0, "bounces": 1, "range": 0.0,
		"trait_stack": TraitStack.new(),
		"panel_snapshot": {"base_atk": 10.0, "flat_bonus": 0.0,
			"crit_rate": 0.0, "crit_mult": 2.0, "add_entries": []},
		"position": Vector2(360.0, 40.0),
	})
	var flipped3 := false
	for i in 420:
		if not b3n._live:
			break
		b3n._tick_fast_player(DT)
		if b3n.velocity.y > 0.0:
			flipped3 = true
	_check("⑥再重生跳弹弹反射仍生效（快路径物理无残留吞噬）", flipped3, str(flipped3))


# ── ⑦ bounces>0 弹 range 豁免 ──────────────────────────────────────

func _test_7_range_exempt() -> void:
	print("── ⑦ range 豁免（bounces>0 不因超程回收） ──")
	_release_field()
	_gl.enemy_grid.rebuild(_empty_items())
	var fa := _spawn_bullet(Vector2(360.0, 640.0),
		{"velocity": Vector2(0.0, -500.0), "bounces": 2, "range": 100.0})
	var sl := _spawn_bullet(Vector2(360.0, 640.0),
		{"velocity": Vector2(0.0, -500.0), "bounces": 2, "range": 100.0})
	var radius_ok: Array = [true]
	var r := _drive_twin(fa, sl, 30, radius_ok)
	_check("⑦bounces>0 弹 traveled≫range 仍活且孪生逐位全等（豁免语义快慢一致）",
		r["pos_eq"] and r["vel_eq"] and fa._live and sl._live and fa._traveled > 200.0,
		"pos=%s live=%s/%s trav=%f" % [str(r["pos_eq"]), str(fa._live), str(sl._live),
			fa._traveled])
	if fa._live:
		(fa.pool as ProjectilePool).release(fa)
	if sl._live:
		(sl.pool as ProjectilePool).release(sl)


# ── ⑧ TH_BANK_SHOT 金染升格走快路径 ────────────────────────────────

func _test_8_gold_fast() -> void:
	print("── ⑧ 金染升格（TH_BANK_SHOT ≥12 反弹 GOLD） ──")
	_release_field()
	_gl.enemy_grid.rebuild(_empty_items())
	var w1 := WeaponBase.new()
	w1.setup(_gl.registry.get_weapon(&"W1_pistol"), _gl.player, {})
	var fa := _spawn_bullet(Vector2(30.0, 640.0), {
		"velocity": Vector2(1500.0, 0.0), "bounces": 14, "range": 0.0,
		"lifetime": 60.0, "weapon_ref": w1})
	var gold := false
	var flag_off := true
	for i in 2000:
		if not fa._live:
			break
		fa._tick_fast_player(DT)
		if fa._vis_invariant:
			flag_off = false
		if fa._bounces_done >= 12 and fa._vis_variant == 6:
			gold = true
	_check("⑧快臂金染升格（≥12 反弹 _vis_variant=GOLD(6)——反射补 _sync_visual 钩）∧ 旗不立",
		gold and flag_off,
		"gold=%s flag_off=%s variant=%d done=%d" % [str(gold), str(flag_off),
			fa._vis_variant, fa._bounces_done])
	var sl := _spawn_bullet(Vector2(30.0, 640.0), {
		"velocity": Vector2(1500.0, 0.0), "bounces": 14, "range": 0.0,
		"lifetime": 60.0, "weapon_ref": w1})
	var gold_s := false
	for i in 2000:
		if not sl._live:
			break
		sl.tick(DT)
		if sl._bounces_done >= 12 and sl._vis_variant == 6:
			gold_s = true
	_check("⑧慢孪生同升格同回收（视觉面快慢等价）", gold_s and not sl._live and not fa._live,
		"gold_s=%s fa_live=%s sl_live=%s" % [str(gold_s), str(fa._live), str(sl._live)])


# ── ⑨ TH_BOUNCE_ETERNAL 永存走快路径 ───────────────────────────────

func _test_9_eternal() -> void:
	print("── ⑨ 永存（TH_BOUNCE_ETERNAL ≥5 反弹延寿） ──")
	_release_field()
	_gl.enemy_grid.rebuild(_empty_items())
	var w1 := WeaponBase.new()
	w1.setup(_gl.registry.get_weapon(&"W1_pistol"), _gl.player, {})
	var fa := _spawn_bullet(Vector2(30.0, 640.0), {
		"velocity": Vector2(1500.0, 0.0), "bounces": 4, "range": 0.0,
		"lifetime": 9.0, "weapon_ref": w1,
		"trait_stack": _mk_stack([&"MEC_BOUNCE"])})
	_check("⑨前置：直接 4+MEC_BOUNCE 派发期 +2 → bounces_left==6 且判 fast",
		fa.bounces_left == 6 and fa._pfast, "bl=%d pfast=%s" % [fa.bounces_left, str(fa._pfast)])
	# 帧序锚：生产每 _physics_process 推进 GameConfig.advance_frame（E-03 帧闸按
	# frame_stamp 重置 frame_triggered）——手动驱动须同样推进，否则 ON_BOUNCE 派发被
	# 帧闸拦截（探针口径对齐生产，两臂同拍推进保孪生）。
	var cnt0: int = DebugStats.get_counter(&"bounce_eternal_triggered")
	var max_life := 0.0
	var die_f := -1
	for i in 2000:
		if not fa._live:
			die_f = i
			break
		GameConfig.advance_frame()
		fa._tick_fast_player(DT)
		max_life = maxf(max_life, fa.lifetime_left)
	var cnt_f: int = DebugStats.get_counter(&"bounce_eternal_triggered") - cnt0
	_check("⑨快臂 ON_BOUNCE 派发生效（eternal 计数 ≥1——done≥5 每次反弹各计一次 ∧ lifetime 跳 >900）",
		cnt_f >= 1 and max_life > 900.0,
		"cnt=%d max_life=%f" % [cnt_f, max_life])
	var sl := _spawn_bullet(Vector2(30.0, 640.0), {
		"velocity": Vector2(1500.0, 0.0), "bounces": 4, "range": 0.0,
		"lifetime": 9.0, "weapon_ref": w1,
		"trait_stack": _mk_stack([&"MEC_BOUNCE"])})
	var die_s := -1
	for i in 2000:
		if not sl._live:
			die_s = i
			break
		GameConfig.advance_frame()
		sl.tick(DT)
	_check("⑨慢孪生同帧回收（快慢消费派发期写者逐位等价）",
		die_f >= 0 and die_f == die_s, "die=%d/%d" % [die_f, die_s])


# ── ⑩ 4c 真值臂第三态 + 注入翻转保鲜 ───────────────────────────────

func _test_10_snapshot_third_cell() -> void:
	print("── ⑩ 关态快照三态补位 ──")
	_release_field()
	var e := _spawn_enemy(1.0e9, Vector2(100.0, 200.0))
	e._ip_prev = Vector2(5.0, 5.0)
	e._ip_curr = Vector2(5.0, 5.0)
	GameLoop.SIM_30HZ_ENABLED = true
	GameLoop.sim30_override = -1                # 真值臂：桌面 OS 门 → 谓词假
	var pred: bool = GameLoop.sim30_effective()
	_gl._ip_snapshot_pass()
	_check("⑩真值臂 -1+ENABLED=true（桌面 OS 门）直返冻结（谓词假前提成立）",
		(not pred) and e._ip_curr == Vector2(5.0, 5.0),
		"pred=%s curr=%s" % [str(pred), str(e._ip_curr)])
	var frozen_curr: Vector2 = e._ip_curr
	GameLoop.sim30_override = -3                # 注入翻转：-3 开态快照须捕获当前位
	_gl._ip_snapshot_pass()
	_check("⑩保鲜语义：跳过段后翻 -3 快照捕获当前位（prev=跳过前 curr、curr=当前位）",
		e._ip_curr.distance_to(e.global_position) < 0.01
			and e._ip_prev == frozen_curr,
		"curr=%s gp=%s prev=%s" % [str(e._ip_curr), str(e.global_position), str(e._ip_prev)])
	GameLoop.SIM_30HZ_ENABLED = false
	GameLoop.sim30_override = -1
	_check("⑩套件总项数（EXPECTED=%d——R231 假绿教训）" % EXPECTED_TOTAL,
		_pass + _fail == EXPECTED_TOTAL, "实=%d" % (_pass + _fail))

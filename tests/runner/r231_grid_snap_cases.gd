# tests/runner/r231_grid_snap_cases.gd
# R231 刀A「SpaceGrid 读路径快照化」用例体（入口 test_r231_grid_snap.gd 运行时 load——
# cases 文件禁 test_ 前缀防电池 glob 误收，R230 教训）。覆盖设计 ③ T1-T7（分析
# AC-1/AC-2/AC-5 销账口径为断言真源）：
# T1 三查询方法（query_circle/query_nearest/query_arc，live 口径）+ query_circle_snap
#    vs 暴力参考逐集合相等（随机布局/树内外混合/远出网格钳制收缩）；
# T2 _radii 删除等价：insert 任意半径→精判口径仍常量 max_entity_radius()（双向：
#    小半径不缩 reach、大半径不扩 reach）；重复 insert 双候选契约保留；
#    pkg0:509 同构边界余量锁定（自定义半径 insert 后超集不增员）；
#    max_entity_radius() 只读口随 configure 生效（不硬编码 64）；
# T3 快照语义双口径：rebuild 后移动敌节点——snap 查询用旧位、live 方法用新位，
#    各自断言（含 query_nearest/query_arc live 新位）；
# T4 _check_collision 走 snap 后命中集与暴力参考一致（含粗判带内窄相排除、
#    distance²==reach² 边界恰等含入）；
# T5 ④ 内死亡-回池：回池不改位（AC-2：reparent keep_global_transform+原点桶）+
#    dead 短路（projectile _submit_hit）→ 后续弹最终命中与旧语义一致；
# T6 enemy_bullet_grid 消弹 query_arc live 口径不变（移动后按新位角度裁定）；
# T7 纪戳/清桶/跨帧复用不串桶（rebuild 全清、波内补插生命周期、缓冲不串查）。
# 本套件纯 headless 无窗口（不测渲染面），不需要 APPDATA 沙箱。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null
var _host: Node2D = null                      # 树内测试节点宿主（收尾释放）
var _keep: Array[Node] = []                   # 树外构造节点（收尾 free）


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(20261004)
	_boot_game_loop()
	await tree.process_frame
	await tree.process_frame
	_gl.state = GameConst.GameStatus.MENU       # 静止环境（r230 先例：真武器零开火零自然事件）
	PerfGovernor.set_process(false)
	_host = Node2D.new()
	_host.name = "R231GridHost"
	tree.get_root().add_child(_host)
	_test_1_snap_vs_bruteforce()
	_test_2_radii_removed_constant_caliber()
	_test_3_snapshot_dual_caliber()
	_test_4_check_collision_matches_bruteforce()
	await _test_5_death_repool_semantics()
	_test_6_bullet_grid_arc_live()
	_test_7_stamp_clear_reuse()
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
	_release_field()
	if _host != null and is_instance_valid(_host):
		_host.queue_free()
	for n in _keep:
		if n != null and is_instance_valid(n):
			n.free()
	_keep.clear()
	if _gl != null:
		_gl.queue_free()
		await tree.process_frame
		await tree.process_frame


func _release_field() -> void:
	# T4/T5 战场清场（敌/弹归还池——快照迭代防 release 重入）
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


# ── 夹具 ──────────────────────────────────────────────────────────

func _mk_node(p_pos: Vector2, p_in_tree: bool) -> Node2D:
	var n := Node2D.new()
	if p_in_tree:
		_host.add_child(n)
		n.global_position = p_pos
	else:
		n.position = p_pos
		_keep.append(n)
	return n


func _live_pos(p_n: Node2D) -> Vector2:
	# 与 SpaceGrid._pos_of 同口径（树内 global_position / 树外回退 position）
	if p_n.is_inside_tree():
		return p_n.global_position
	return p_n.position


func _new_grid() -> SpaceGrid:
	var g := SpaceGrid.new()
	g.configure(Vector2(720.0, 1280.0), 192.0, 64.0)
	return g


func _same_set(p_res, p_ref: Array) -> bool:
	# 集合相等（忽略桶序）：尺寸一致 + 逐成员归属
	if p_res.size() != p_ref.size():
		return false
	for v in p_res:
		if not p_ref.has(v):
			return false
	return true


func _set_str(p_res) -> String:
	var parts: Array[String] = []
	for v in p_res:
		parts.append(str((v as Node2D).get_instance_id()))
	return "[" + ",".join(parts) + "]"


func _brute_snap(p_items: Array, p_snap: Dictionary, p_pos: Vector2, p_radius: float) -> Array:
	# query_circle_snap 暴力参考：快照位 + 常量保守半径（r+64 圆含入）
	var out: Array = []
	var reach := maxf(p_radius, 0.0) + 64.0
	for n in p_items:
		if (p_snap[n] as Vector2).distance_squared_to(p_pos) <= reach * reach:
			out.append(n)
	return out


func _brute_live(p_items: Array, p_pos: Vector2, p_radius: float) -> Array:
	# query_circle 暴力参考：live 位（_pos_of 口径）+ 常量保守半径
	var out: Array = []
	var reach := maxf(p_radius, 0.0) + 64.0
	for n in p_items:
		if _live_pos(n).distance_squared_to(p_pos) <= reach * reach:
			out.append(n)
	return out


func _brute_nearest(p_items: Array, p_pos: Vector2, p_radius: float,
		p_exclude: Node2D, p_live: bool, p_snap: Dictionary) -> Node2D:
	var best: Node2D = null
	var best_d := INF
	var reach := maxf(p_radius, 0.0) + 64.0
	for n in p_items:
		if n == p_exclude:
			continue
		var np: Vector2 = _live_pos(n) if p_live else (p_snap[n] as Vector2)
		var d := np.distance_squared_to(p_pos)
		if d <= reach * reach and d < best_d:
			best_d = d
			best = n
	return best


func _brute_arc(p_items: Array, p_pos: Vector2, p_radius: float, p_dir: float,
		p_half: float, p_live: bool, p_snap: Dictionary) -> Array:
	# query_arc 暴力参考（与 space_grid 实现同序同判）
	var out: Array = []
	var reach := maxf(p_radius, 0.0) + 64.0
	for n in p_items:
		var np: Vector2 = _live_pos(n) if p_live else (p_snap[n] as Vector2)
		var d := np.distance_squared_to(p_pos)
		if d > reach * reach:
			continue
		if d > 0.0001:
			var rel := wrapf((np - p_pos).angle() - p_dir, -PI, PI)
			if absf(rel) > p_half:
				continue
		out.append(n)
	return out


# ── T1 三查询方法 vs 暴力参考（随机布局/树内外混合/边界恰等/远出钳制）──

func _test_1_snap_vs_bruteforce() -> void:
	print("── T1 三查询 + snap vs 暴力参考 ──")
	var g := _new_grid()
	var items: Array = []
	var snap: Dictionary = {}
	for i in range(36):
		var n := _mk_node(Vector2(randf_range(-250.0, 950.0), randf_range(-250.0, 1350.0)), i % 2 == 0)
		items.append(n)
		snap[n] = _live_pos(n)
	# 远出网格两点（钳制收缩路径）：右外 / 左外
	var far_r := _mk_node(Vector2(5000.0, 640.0), true)
	var far_l := _mk_node(Vector2(-1500.0, 1500.0), false)
	items.append(far_r)
	snap[far_r] = far_r.global_position
	items.append(far_l)
	snap[far_l] = far_l.position
	var typed: Array[Node2D] = []
	for n in items:
		typed.append(n)
	g.rebuild(typed)
	# 随机查询点 × 档位半径：snap/live/nearest/arc 逐集合对暴力参考
	var radii := [0.0, 10.0, 40.0, 120.0, 400.0]
	var mismatches: int = 0
	for qi in range(40):
		var qpos := Vector2(randf_range(-300.0, 1000.0), randf_range(-300.0, 1400.0))
		var r: float = radii[qi % radii.size()]
		var dir := randf() * TAU
		var half := randf_range(0.2, PI)
		var excl: Node2D = items[qi % items.size()]
		if not _same_set(g.query_circle_snap(qpos, r), _brute_snap(items, snap, qpos, r)):
			mismatches += 1
		if not _same_set(g.query_circle(qpos, r), _brute_live(items, qpos, r)):
			mismatches += 1
		if g.query_nearest(qpos, r, excl) != _brute_nearest(items, qpos, r, excl, true, snap):
			mismatches += 1
		if not _same_set(g.query_arc(qpos, r, dir, half),
				_brute_arc(items, qpos, r, dir, half, true, snap)):
			mismatches += 1
	_check("T1 随机布局 40 查询点×4 方法 vs 暴力参考全等", mismatches == 0,
		"失配 %d 处" % mismatches)
	# 边界恰等：distance² == reach² 含入（snap 与 live 同判）
	var bpos := Vector2(400.0, 300.0)
	var reach := 8.0 + 64.0
	var nb := _mk_node(bpos + Vector2(reach, 0.0), true)
	items.append(nb)
	snap[nb] = nb.global_position
	g.rebuild(_as_typed(items))
	var res := g.query_circle_snap(bpos, 8.0)
	_check("T1 边界恰等（d²==reach²）：snap 含入", res.has(nb), _set_str(res))
	_check("T1 边界恰等：live 同判含入", g.query_circle(bpos, 8.0).has(nb))
	# 远出网格钳制收缩：查询点远出屏 → 收缩到边缘桶，恰好命中钳制入桶的远点
	var res_far := g.query_circle_snap(Vector2(5000.0, 640.0), 0.0)
	_check("T1 远出网格钳制：右外远点可查（snap）", res_far.has(far_r), _set_str(res_far))
	_check("T1 远出网格钳制：live 同判", g.query_circle(Vector2(5000.0, 640.0), 0.0).has(far_r))
	_check("T1 远出网格钳制：查询点更远处空结果（无越界串桶）",
		g.query_circle_snap(Vector2(20000.0, 20000.0), 50.0).is_empty())


func _as_typed(p_items: Array) -> Array[Node2D]:
	var typed: Array[Node2D] = []
	for n in p_items:
		typed.append(n)
	return typed


# ── T2 _radii 删除等价（常量口径/双候选契约/边界余量/只读口）──────────

func _test_2_radii_removed_constant_caliber() -> void:
	print("── T2 _radii 删除等价 ──")
	var g := _new_grid()
	g.rebuild([])
	# 任意小半径 insert → 精判口径仍常量 64（旧语义 reach=5 会 miss 的 30px 点现命中）
	var n1 := _mk_node(Vector2(400.0, 400.0), false)
	g.insert(n1, 5.0)
	_check("T2 insert 小半径不缩口径：d=30 命中（旧 r=5 语义必 miss）",
		g.query_circle_snap(Vector2(430.0, 400.0), 0.0).has(n1))
	_check("T2 同上：live 查询同口径", g.query_circle(Vector2(430.0, 400.0), 0.0).has(n1))
	# 任意大半径 insert → 口径不扩（旧语义 reach=500 会命中 100px 点，现 miss）
	var n_big := _mk_node(Vector2(400.0, 400.0), false)
	g.rebuild([])
	g.insert(n_big, 500.0)
	_check("T2 insert 大半径不扩口径：d=100 不命中（旧 r=500 语义必 hit）",
		not g.query_circle_snap(Vector2(500.0, 400.0), 0.0).has(n_big))
	_check("T2 max_entity_radius 只读口 = configure 值", g.max_entity_radius() == 64.0,
		str(g.max_entity_radius()))
	# 重复 insert 双候选契约（文档契约保留：重复插入产生重复候选）
	g.rebuild([])
	g.insert(n1, 64.0)
	g.insert(n1, 64.0)
	_check("T2 重复 insert：snap 双候选契约", g.query_circle_snap(Vector2(400.0, 400.0), 0.0).size() == 2,
		str(g.query_circle_snap(Vector2(400.0, 400.0), 0.0).size()))
	_check("T2 重复 insert：live 双候选契约同保留",
		g.query_circle(Vector2(400.0, 400.0), 0.0).size() == 2)
	# pkg0:509 同构边界余量：自定义半径 insert 后超集不增员（分析 AC-5 锁定）
	var g2 := _new_grid()
	var n_edge := _mk_node(Vector2(-180.0, -180.0), false)
	var n_near := _mk_node(Vector2(-180.0 + 1000.0, -180.0), false)
	g2.insert(n_edge, 10.0)
	g2.insert(n_near, 10.0)
	var res := g2.query_circle(Vector2(-180.0, -180.0), 20.0)
	_check("T2 边界余量锁定：查询点自身命中", res.has(n_edge), _set_str(res))
	_check("T2 边界余量锁定：d=1000 邻点不被 84 口径误收（超集不增员）",
		res.size() == 1, _set_str(res))
	var res_s := g2.query_circle_snap(Vector2(-180.0, -180.0), 20.0)
	_check("T2 边界余量锁定：snap 同判", res_s.has(n_edge) and res_s.size() == 1, _set_str(res_s))
	# configure 自定义保守半径 → 只读口生效、粗判随行（不硬编码 64）
	var g3 := SpaceGrid.new()
	g3.configure(Vector2(720.0, 1280.0), 192.0, 90.0)
	var n90 := _mk_node(Vector2(400.0, 400.0), false)
	g3.rebuild([n90])
	_check("T2 自定义保守半径 90：只读口生效", g3.max_entity_radius() == 90.0)
	_check("T2 自定义保守半径：d=70 命中（64 口径必 miss）",
		g3.query_circle_snap(Vector2(470.0, 400.0), 0.0).has(n90))


# ── T3 快照语义双口径（snap 旧位 / live 新位）────────────────────────

func _test_3_snapshot_dual_caliber() -> void:
	print("── T3 快照语义双口径 ──")
	var g := _new_grid()
	var n := _mk_node(Vector2(400.0, 400.0), true)
	g.rebuild([n])
	n.global_position = Vector2(540.0, 400.0)       # rebuild 后移动 140px（>64 保守半径）
	var q_a := Vector2(400.0, 400.0)
	var q_b := Vector2(540.0, 400.0)
	_check("T3 snap 用旧位：A 点命中", g.query_circle_snap(q_a, 0.0).has(n))
	_check("T3 snap 用旧位：B 点不命中（快照仍在 A，d=140>64）",
		not g.query_circle_snap(q_b, 0.0).has(n))
	_check("T3 live 用新位：A 点不命中", not g.query_circle(q_a, 0.0).has(n))
	# r=70：reach=134 覆盖含旧桶格（col4）——live d=0 命中 / snap d=140 排除，同覆盖纯口径判
	_check("T3 live 用新位：B 点命中（r=70 覆盖旧桶格）", g.query_circle(q_b, 70.0).has(n))
	_check("T3 同覆盖对照：snap 同参不命中（d=140>134）",
		not g.query_circle_snap(q_b, 70.0).has(n))
	_check("T3 query_nearest live 新位：A 点 null", g.query_nearest(q_a, 0.0, null) == null)
	_check("T3 query_nearest live 新位：B 点 = n（r=70 覆盖旧桶格）",
		g.query_nearest(q_b, 70.0, null) == n)
	_check("T3 query_arc live 新位：B 点半圆含入（r=70 覆盖旧桶格）",
		g.query_arc(q_b, 70.0, 0.0, PI).has(n))
	_check("T3 query_arc live 新位：A 点不含（若误快照化则 140px d 判旧位 A 命中）",
		not g.query_arc(q_a, 0.0, 0.0, PI).has(n))


# ── T4 _check_collision 走 snap 后命中集与暴力参考一致 ────────────────

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


func _spawn_enemy(p_id: StringName, p_hp: float, p_pos: Vector2) -> Enemy:
	var pool := _gl.pools[&"enemy"] as EnemyPool
	var e := pool.acquire() as Enemy
	e.bucket_host = pool.bucket_host
	e.spawn(_fixture_enemy_data(p_id, p_hp), 1, 0)
	e._fade_left = 0.0
	e.modulate.a = 1.0
	e.global_position = p_pos
	_gl.spawner.active.append(e)
	return e


func _spawn_player_bullet(p_pos: Vector2, p_pierce: int, p_atk: float) -> ProjectileBase:
	var pool := _gl.pools[&"projectile"] as ProjectilePool
	var proj := pool.acquire()
	proj.damage_pipeline = _gl.pipeline
	proj.enemy_grid = _gl.enemy_grid
	proj.pool = pool
	proj.spawn({
		"velocity": Vector2(60.0, 0.0), "lifetime": 10.0, "pierce": p_pierce, "team": 0,
		"weapon_ref": _gl.player.weapon_slots[0], "hitbox_radius": 8.0,
		"panel_snapshot": {"base_atk": p_atk, "flat_bonus": 0.0,
			"crit_rate": 0.0, "crit_mult": 2.0, "add_entries": []},
		"position": p_pos,
	})
	return proj


func _test_4_check_collision_matches_bruteforce() -> void:
	print("── T4 _check_collision 命中集 vs 暴力参考 ──")
	var p_pos := Vector2(480.0, 640.0)
	# 相对弹位的判定带：窄相 reach = 8+14 = 22；粗判 reach = 8+64 = 72
	var e1 := _spawn_enemy(&"r231_a", 1.0e9, p_pos + Vector2(20.0, 0.0))    # 窄相内 → 命中
	var e2 := _spawn_enemy(&"r231_b", 1.0e9, p_pos + Vector2(30.0, 0.0))    # 粗判带内窄相外 → 仅候选
	var e3 := _spawn_enemy(&"r231_c", 1.0e9, p_pos + Vector2(80.0, 0.0))    # 粗判外 → 不可见
	var e4 := _spawn_enemy(&"r231_d", 1.0e9, p_pos + Vector2(22.0, 0.0))    # 窄相边界恰等 → 命中
	var e5 := _spawn_enemy(&"r231_e", 1.0e9, p_pos + Vector2(71.0, 0.0))    # 粗判带内窄相外
	var e6 := _spawn_enemy(&"r231_f", 1.0e9, p_pos + Vector2(72.0, 0.0))    # 粗判边界恰等 → 仅候选
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	# 粗判超集直查（snap 口径）：E2/E5/E6 候选、E3 不可见
	var cand := _gl.enemy_grid.query_circle_snap(p_pos, 8.0)
	_check("T4 粗判超集含窄相带内三敌", cand.has(e2) and cand.has(e5) and cand.has(e6),
		_set_str(cand))
	_check("T4 粗判排除粗判外敌", not cand.has(e3))
	# _check_collision 全链：命中集 = 暴力窄相参考 {E1, E4}
	# （R220 刀11 批化：结算入 _resolved_queue，测试直调派发口冲刷后读 spy——simchain ⑩ 同款）
	var spy: Array[int] = []
	var cb := func(r: DamageResult) -> void: spy.append(int(r.target_uid))
	(_gl.pipeline.get("_resolved_queue") as Array).clear()
	EventBus.damage_resolved.connect(cb)
	var proj := _spawn_player_bullet(p_pos, 99, 10.0)
	proj._check_collision()
	_gl.pipeline.call(&"dispatch_resolved_frame")
	EventBus.damage_resolved.disconnect(cb)
	var expect: Array = [int(e1.uid), int(e4.uid)]
	var got: Array = []
	for u in spy:
		if not got.has(u):
			got.append(u)
	_check("T4 命中集与暴力窄相参考一致（{E1,E4}，边界恰等含入）",
		_same_set(got, expect), "got=%s expect=%s" % [str(got), str(expect)])
	for e in [e2, e3, e5, e6]:
		_check("T4 窄相外敌零伤：%s" % String(e.data.id), float(e.hp) >= 1.0e9 - 1.0,
			str(e.hp))
	_release_field()


# ── T5 ④ 内死亡-回池（回池不改位 + dead 短路）→ 后续弹命中与旧语义一致 ──

func _test_5_death_repool_semantics() -> void:
	print("── T5 ④ 内死亡-回池语义 ──")
	var p_pos := Vector2(480.0, 640.0)
	var e_die := _spawn_enemy(&"r231_die", 10.0, p_pos)                      # P1 击杀
	var e_surv := _spawn_enemy(&"r231_surv", 1.0e12, p_pos + Vector2(20.0, 0.0))  # 双弹命中（1e12=两发 1e9 伤害不死——hp 恰卡线会被 P1 击杀变 dead 短路）
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	var spy: Array[int] = []
	var cb := func(r: DamageResult) -> void: spy.append(int(r.target_uid))
	(_gl.pipeline.get("_resolved_queue") as Array).clear()
	EventBus.damage_resolved.connect(cb)
	# P1：击杀 E_die（死亡链同步完成：active.erase + pool.release + dead 置位）
	var p1 := _spawn_player_bullet(p_pos, 99, 1.0e9)
	p1._check_collision()
	_gl.pipeline.call(&"dispatch_resolved_frame")
	_check("T5 死亡敌已出 active", not _gl.spawner.active.has(e_die))
	_check("T5 死亡敌 dead 置位", bool(e_die.dead))
	_check("T5 回池不改位（AC-2：reparent keep_global+原点桶）",
		e_die.global_position.distance_to(p_pos) < 0.01,
		str(e_die.global_position))
	_check("T5 回池敌仍在网格快照（下帧 rebuild 前口径）",
		_gl.enemy_grid.query_circle_snap(p_pos, 8.0).has(e_die))
	# P2：同位再查——快照候选含尸体 → live 窄相仍在 reach → dead 短路 → 零二次结算
	var p2 := _spawn_player_bullet(p_pos, 99, 1.0e9)
	p2._check_collision()
	_gl.pipeline.call(&"dispatch_resolved_frame")
	EventBus.damage_resolved.disconnect(cb)
	var die_hits: int = spy.count(int(e_die.uid))
	var surv_hits: int = spy.count(int(e_surv.uid))
	_check("T5 死亡敌恰一次结算（P1；P2 dead 短路）", die_hits == 1, str(die_hits))
	_check("T5 活敌两弹各结算一次（后续弹最终命中与旧语义一致）", surv_hits == 2, str(surv_hits))
	_release_field()


# ── T6 enemy_bullet_grid 消弹 query_arc live 口径不变 ─────────────────

func _test_6_bullet_grid_arc_live() -> void:
	print("── T6 消弹 query_arc live 口径 ──")
	var g := _gl.enemy_bullet_grid
	var c := Vector2(400.0, 400.0)
	# b：rebuild 时 18.4°（扇内）→ 移动后 63.4°（扇外）：live 口径应排除、快照口径误收
	var b := _mk_node(c + Vector2(300.0, 100.0), true)
	g.rebuild([b])
	b.global_position = c + Vector2(200.0, 400.0)
	_check("T6 live 口径：移动出扇（63°>45°）后不消弹",
		g.query_arc(c, 450.0, 0.0, PI * 0.25).is_empty())
	b.global_position = c + Vector2(300.0, 100.0)
	# b/b2/b3 角度分带 + b4/b5 距离恰等
	var b2 := _mk_node(c + Vector2(cos(0.6981), sin(0.6981)) * 350.0, true)   # 40° 扇内
	var b3 := _mk_node(c + Vector2(cos(0.8727), sin(0.8727)) * 350.0, true)   # 50° 扇外
	var b4 := _mk_node(c + Vector2(514.0, 0.0), true)                          # d=reach 恰等
	var b5 := _mk_node(c + Vector2(515.0, 0.0), true)                          # d=reach+1 排除
	g.rebuild([b, b2, b3, b4, b5])
	var res := g.query_arc(c, 450.0, 0.0, PI * 0.25)
	_check("T6 扇内两弹命中（18.4°/40°）", res.has(b) and res.has(b2), _set_str(res))
	_check("T6 扇外弹排除（50°）", not res.has(b3))
	_check("T6 距离恰等 d²==reach² 含入（450+64=514）", res.has(b4))
	_check("T6 距离超界排除（515）", not res.has(b5))


# ── T7 纪戳/清桶/跨帧复用不串桶 ──────────────────────────────────────

func _test_7_stamp_clear_reuse() -> void:
	print("── T7 纪戳/清桶/跨帧复用 ──")
	var g := _new_grid()
	var a := _mk_node(Vector2(100.0, 100.0), true)
	var b := _mk_node(Vector2(500.0, 700.0), false)
	var c := _mk_node(Vector2(650.0, 1200.0), true)
	var c2 := _mk_node(Vector2(104.0, 100.0), false)
	var d := _mk_node(Vector2(400.0, 400.0), true)
	g.rebuild([a, b])
	_check("T7 rebuild 全量可见", g.query_circle_snap(Vector2(100.0, 100.0), 30.0).has(a)
		and g.query_circle_snap(Vector2(500.0, 700.0), 30.0).has(b))
	g.rebuild([c])
	_check("T7 清桶：旧条目随 rebuild 消失（A 位空）",
		g.query_circle_snap(Vector2(100.0, 100.0), 30.0).is_empty())
	_check("T7 清桶：新条目可见", g.query_circle_snap(Vector2(650.0, 1200.0), 30.0).has(c))
	# 波内补插：rebuild 后 insert 当帧可见
	g.insert(c2, 64.0)
	_check("T7 波内补插当帧可见", g.query_circle_snap(Vector2(104.0, 100.0), 10.0).has(c2))
	# 跨帧：下帧 rebuild 后补插清干净
	g.rebuild([d])
	_check("T7 跨帧补插清干净", g.query_circle_snap(Vector2(104.0, 100.0), 10.0).is_empty())
	# 连续同参 rebuild（纪戳递增）后 insert 不串纪戳
	g.rebuild([d])
	g.rebuild([d])
	g.insert(c2, 64.0)
	_check("T7 连续 rebuild 后补插恰一候选",
		g.query_circle_snap(Vector2(104.0, 100.0), 10.0).size() == 1)
	# 查询缓冲不串查：返回值为内部复用缓冲（跨查询持有必须复制——生产 _check_collision
	# append_array 同契约），复制件不受后续查询覆写
	var r1_snap: Array = g.query_circle_snap(Vector2(400.0, 400.0), 5.0).duplicate()
	var r2 := g.query_circle_snap(Vector2(650.0, 1200.0), 5.0)
	_check("T7 缓冲不串查：已复制的前查不被后续 snap 查询覆写",
		r1_snap.has(d) and r2.is_empty(), _set_str(r2))
	var r3 := g.query_circle(Vector2(400.0, 400.0), 5.0)
	_check("T7 缓冲不串查：snap 后 live 查询独立", r3.has(d) and r3.size() == 1, _set_str(r3))
	# 双实例隔离（enemy_grid 与临时网格互不污染）
	var g2 := _new_grid()
	var x := _mk_node(Vector2(400.0, 400.0), false)
	g2.rebuild([x])
	_check("T7 双实例隔离：临时网格查自身", g2.query_circle_snap(Vector2(400.0, 400.0), 5.0).has(x))
	_check("T7 双实例隔离：enemy_grid 查同位仍只 own 成员",
		g.query_circle_snap(Vector2(400.0, 400.0), 5.0).size() == 1)
	# R231 刀A 修正回归：virgin-grid（未 rebuild 过）insert 必须注册占用（纪戳初值 −1
	# 口径）——否则小 rebuild 清不到旧桶，int 索引悬挂 OOB（w1_volley 电池 7.7 万条
	# SCRIPT ERROR 实锤序列）/Node2D 桶时代为幽灵候选
	var gv := SpaceGrid.new()
	gv.configure(Vector2(720.0, 1280.0), 192.0, 64.0)
	var v1 := _mk_node(Vector2(200.0, 200.0), false)
	var v2 := _mk_node(Vector2(600.0, 1000.0), false)
	gv.insert(v1, 64.0)
	gv.insert(v2, 64.0)
	gv.rebuild([])                               # 空 rebuild：已注册桶必须清干净
	_check("T7 virgin-insert 回归：空 rebuild 后查询空（无悬挂索引/幽灵候选）",
		gv.query_circle_snap(Vector2(200.0, 200.0), 30.0).is_empty()
		and gv.query_circle_snap(Vector2(600.0, 1000.0), 30.0).is_empty())
	var v3 := _mk_node(Vector2(400.0, 400.0), false)
	gv.rebuild([v3])
	_check("T7 virgin-insert 回归：收缩 rebuild 后仅新员可见（快照索引不越界）",
		_same_set(gv.query_circle_snap(Vector2(400.0, 400.0), 5.0), [v3])
		and gv.query_circle_snap(Vector2(200.0, 200.0), 30.0).is_empty()
		and gv.query_circle(Vector2(600.0, 1000.0), 30.0).is_empty())

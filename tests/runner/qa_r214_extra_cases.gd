# tests/runner/qa_r214_extra_cases.gd
# QA R214 补充探针用例体（独立于 r214_bucket_cases，只增测不重复）：
#   A. _META_IN_POOL 跨 reparent 保留 + 双重归还拦截
#   B. 弹 place/unplace 往返 global_position 恒等 + 同桶幂等零操作
#   C. is_clean 闸：acquire 未 spawn 的闲置弹 _sync_visual 不落桶
#   D. 出生风暴：单帧 128 敌 + 300 弹 place 无断言/无错，池计数守恒
#   E. 帽冻片：冻结片在场不消失不位移，下帧恢复吸收，面值守恒
#   F. E7 敌弹可见性根因：桶化后 pool.get_children() 扫描失效（stale test 归因）
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const PLAYER_HOME := Vector2(360.0, 900.0)
const DT := 1.0 / 60.0

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(214)
	_boot_game_loop()
	await tree.process_frame
	await tree.process_frame
	_enter_run_frozen()
	_test_a_meta_across_reparent()
	_test_b_position_identity()
	_test_c_is_clean_gate()
	await _test_d_spawn_storm()
	_test_e_freeze_resume()
	_test_f_e7_bullet_root_cause()
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
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "QAR214ExtraGameLoop"
	tree.get_root().add_child(_gl)


func _enter_run_frozen() -> void:
	_gl.state = GameConst.GameStatus.MENU
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	_gl.start_run()
	_gl.state = GameConst.GameStatus.MENU
	_gl.player.global_position = PLAYER_HOME


func _teardown_game_loop() -> void:
	tree.paused = false
	RunSave.clear()
	if _gl != null:
		_gl.free()
		_gl = null


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


# ── A. 池标记 meta 跨 reparent 保留 ──────────────────────────────
func _test_a_meta_across_reparent() -> void:
	print("── A. meta 跨 reparent ──")
	var pool := _gl.pools[&"enemy"] as EnemyPool
	var host: Node = pool.bucket_host
	var e := pool.acquire() as Enemy
	e.bucket_host = host
	e.spawn(_fixture_enemy(&"E_QA214_A", 100.0), 1, 0)
	_check("A1 落桶后 _META_IN_POOL == false（meta 跨 reparent 保留）",
		host.is_ancestor_of(e) and not bool(e.get_meta(&"_object_pool_in_free_list", true)),
		"meta=%s parent=%s" % [str(e.get_meta(&"_object_pool_in_free_list", true)), str(e.get_parent())])
	var rej0: int = int(pool.stats()["rejected_releases"])
	pool.release(e)
	_check("A2 release 后 meta 恢复 true 且归位池根",
		e.get_parent() == pool and bool(e.get_meta(&"_object_pool_in_free_list", false)),
		"meta=%s parent=%s" % [str(e.get_meta(&"_object_pool_in_free_list", false)), str(e.get_parent())])
	var free0: int = int(pool.stats()["free"])
	pool.release(e)                                # 二次归还必须被拦
	var st := pool.stats()
	_check("A3 二次归还被拒（rejected+1，free 不变）",
		int(st["rejected_releases"]) == rej0 + 1 and int(st["free"]) == free0,
		"rej=%d free=%d" % [int(st["rejected_releases"]), int(st["free"])])


# ── B. 弹 place/unplace 往返 global 恒等 + 幂等 ──────────────────
func _test_b_position_identity() -> void:
	print("── B. 弹位姿恒等/幂等 ──")
	var pool := _gl.pools[&"projectile"] as ProjectilePool
	var host: Node = pool.bucket_host
	var b := pool.acquire() as ProjectileBase
	b.pool = pool
	b.spawn({"velocity": Vector2.ZERO, "lifetime": 5.0, "team": 0})
	b.position = Vector2(500.0, 300.0)
	var g0: Vector2 = b.global_position
	host.unplace(b)                                # 桶 → 池根
	_check("B1 unplace 后 global 恒等且归池根",
		b.get_parent() == pool and b.global_position == g0,
		"parent=%s g=%s" % [str(b.get_parent()), str(b.global_position)])
	host.place(b, b.get("_sprite").texture)        # 池根 → 桶
	_check("B2 再 place 后 global 恒等且回桶",
		b.get_parent() != pool and host.is_ancestor_of(b) and b.global_position == g0,
		"g=%s" % str(b.global_position))
	var p_before: Node = b.get_parent()
	host.place(b, b.get("_sprite").texture)        # 同桶再 place：幂等零操作
	_check("B3 同桶重复 place 零操作（父不变、不抖动）",
		b.get_parent() == p_before, "parent=%s" % str(b.get_parent()))
	pool.release(b)


# ── C. is_clean 闸：闲置弹不落桶 ────────────────────────────────
func _test_c_is_clean_gate() -> void:
	print("── C. is_clean 闸 ──")
	var pool := _gl.pools[&"projectile"] as ProjectilePool
	var host: Node = pool.bucket_host
	var b := pool.acquire() as ProjectileBase
	b.pool = pool                                  # 未 spawn（is_clean 保持 true）
	b.call(&"_sync_visual")                        # 直接触发视觉同步——闸应挡住落桶
	_check("C1 acquire 未 spawn 的弹 _sync_visual 不落桶（仍挂池根）",
		b.get_parent() == pool and not host.is_ancestor_of(b),
		"parent=%s is_clean=%s" % [str(b.get_parent()), str(b.get("is_clean"))])
	pool.release(b)
	# release 链后（_reset_state 已跑）再触发也不落桶
	b.call(&"_sync_visual")
	_check("C2 归还后 _sync_visual 不落桶（is_clean=true 闸持续有效）",
		b.get_parent() == pool, "parent=%s" % str(b.get_parent()))


# ── D. 出生风暴：单帧大量 place 无错 + 池计数守恒 ────────────────
func _test_d_spawn_storm() -> void:
	print("── D. 出生风暴 ──")
	await tree.process_frame
	var epool := _gl.pools[&"enemy"] as EnemyPool
	var ehost: Node = epool.bucket_host
	var enemies: Array = []
	var kinds: Array[StringName] = [&"E_QA214_D1", &"E_QA214_D2", &"E_QA214_D3"]
	for i in range(128):
		var e := epool.acquire() as Enemy
		if e == null:
			break
		e.bucket_host = ehost
		e.spawn(_fixture_enemy(kinds[i % 3], 100.0), 1, 0)
		e.position = Vector2(40.0 + float(i % 32) * 20.0, 200.0 + float(i / 32) * 150.0)
		enemies.append(e)
	var all_ok := true
	for e in enemies:
		if not is_instance_valid(e) or not ehost.is_ancestor_of(e):
			all_ok = false
			break
	_check("D1 单帧 128 敌 place 全部落桶、无断言中断", all_ok and enemies.size() == 128,
		"count=%d all_ok=%s" % [enemies.size(), str(all_ok)])
	var rej0: int = int(epool.stats()["rejected_releases"])
	for e in enemies:
		epool.release(e)
	var st := epool.stats()
	_check("D2 风暴全量归还：free==capacity、零拒收",
		int(st["free"]) == int(st["capacity"]) and int(st["rejected_releases"]) == rej0,
		"free=%d cap=%d" % [int(st["free"]), int(st["capacity"])])
	# 弹风暴：300 发（< 软帽 1500 < 容量 820？——820 容量内全命中）
	var ppool := _gl.pools[&"projectile"] as ProjectilePool
	var phost: Node = ppool.bucket_host
	var bullets: Array = []
	for i in range(300):
		var b := ppool.acquire() as ProjectileBase
		if b == null:
			break
		b.pool = ppool
		b.spawn({"velocity": Vector2(60.0, 0.0).rotated(TAU * float(i) / 300.0),
			"lifetime": 5.0, "team": i % 2})
		b.position = Vector2(100.0 + float(i % 50) * 10.0, 300.0 + float(i / 50) * 60.0)
		bullets.append(b)
	var b_ok := true
	for b in bullets:
		if not is_instance_valid(b) or not phost.is_ancestor_of(b):
			b_ok = false
			break
	_check("D3 单帧 300 弹 place 全部落桶（敌我两阵营）", b_ok and bullets.size() == 300,
		"count=%d ok=%s" % [bullets.size(), str(b_ok)])
	var prej0: int = int(ppool.stats()["rejected_releases"])
	for b in bullets:
		ppool.release(b)
	var pst := ppool.stats()
	_check("D4 弹风暴归还：rejected 零增、live 归零",
		int(pst["rejected_releases"]) == prej0 and int(pst["live"]) == 0,
		"rej=%d live=%d" % [int(pst["rejected_releases"]), int(pst["live"])])
	await tree.process_frame


# ── E. 帽冻片：冻结在场不消失不位移，下帧恢复 ────────────────────
func _test_e_freeze_resume() -> void:
	print("── E. 帽冻片恢复 ──")
	var pool := _gl.pools[&"xp"] as XPPool
	var shards: Array = _gl.get("active_shards")
	shards.clear()
	var ppos: Vector2 = _gl.player.global_position
	for i in range(100):
		var s := pool.acquire() as XpShard
		if s == null:
			break
		s.position = ppos + Vector2(10.0, 0.0).rotated(TAU * float(i) / 100.0)
		s.activate(1.0, 1.0)
		s.force_magnet()
		shards.append(s)
	var gained := [0.0]
	var on_xp := func(p_amount: float) -> void: gained[0] += p_amount
	EventBus.xp_gained.connect(on_xp)
	_gl.call(&"_tick_magnetized_shards", DT)       # 帧1：收 24 冻 76
	var left1: int = shards.size()
	var frozen: XpShard = shards[0] as XpShard
	var f_pos: Vector2 = frozen.global_position
	_check("E1 帧1 吸收 24（剩 %d）" % left1, left1 == 76, "left=%d" % left1)
	_gl.call(&"_tick_magnetized_shards", DT)       # 帧2：冻片恢复吸收
	_check("E2 冻结片帧间在场：valid+visible+仍磁吸+零位移",
		is_instance_valid(frozen) and frozen.visible and frozen.is_magnet()
			and frozen.global_position == f_pos,
		"valid=%s vis=%s moved=%s" % [str(is_instance_valid(frozen)), str(frozen.visible),
			str(frozen.global_position - f_pos)])
	_check("E3 帧2 再收 24（剩 52）", shards.size() == 52, "left=%d" % shards.size())
	for f in range(20):
		_gl.call(&"_tick_magnetized_shards", DT)
	EventBus.xp_gained.disconnect(on_xp)
	_check("E4 全部吸收且面值守恒（100×1.0）",
		shards.is_empty() and is_equal_approx(gained[0], 100.0),
		"left=%d gained=%f" % [shards.size(), gained[0]])


# ── F. E7 敌弹可见性根因（verify_feedback FAIL 归因） ─────────────
func _test_f_e7_bullet_root_cause() -> void:
	print("── F. E7 敌弹可见性根因 ──")
	var e7: EnemyData = _gl.registry.get_enemy(&"E7_spitter")
	if e7 == null:
		_check("F0 E7_spitter 注册表加载", false, "null")
		return
	var epool := _gl.pools[&"enemy"] as EnemyPool
	var enemy := epool.acquire() as Enemy
	enemy.spawn(e7, 6, 0)                          # 复刻 verify_feedback：不注入 enemy.bucket_host
	enemy.projectile_pool = _gl.pools[&"projectile"]
	enemy.position = (_gl.player as Node2D).global_position + Vector2(220.0, 0.0)
	var free0: int = int(_gl.pools[&"projectile"].stats()["free"])
	enemy.set("fire_cd_left", 0.0)
	for i in range(3):
		enemy.tick(DT)
	var free1: int = int(_gl.pools[&"projectile"].stats()["free"])
	# 口径1（stale 测试口径）：pool 直接子节点里找可见弹
	var found_in_pool: Node2D = null
	for n in _gl.pools[&"projectile"].get_children():
		if n is Node2D and (n as Node2D).visible:
			found_in_pool = n
			break
	# 口径2（真口径）：桶 host 子树里找可见敌弹
	var phost: Node = (_gl.pools[&"projectile"] as ObjectPool).bucket_host
	var found_in_bucket: Node2D = null
	if phost != null:
		var stack: Array[Node] = [phost]
		while not stack.is_empty():
			var n: Node = stack.pop_back()
			for c in n.get_children():
				stack.append(c)
			if n == phost or not (n is Node2D):
				continue
			var b2d := n as Node2D
			var team_v: Variant = b2d.get(&"team")
			if b2d.visible and team_v != null and int(team_v) == 1:
				found_in_bucket = b2d
				break
	_check("F1 复刻成功：敌弹已开火（free -1）", free1 == free0 - 1, "free0=%d free1=%d" % [free0, free1])
	_check("F2 stale 口径：pool.get_children() 找不到可见弹（FAIL 根因复现）",
		found_in_pool == null, "found=%s" % str(found_in_pool))
	_check("F3 真口径：敌弹在桶内且 visible==true（实体本身可见——非产品 bug）",
		found_in_bucket != null and found_in_bucket.visible,
		"bullet=%s parent=%s" % [str(found_in_bucket),
			str(found_in_bucket.get_parent() if found_in_bucket != null else null)])
	if found_in_bucket != null:
		print("    [归因] 敌弹 parent=%s（TexBucket 子桶），pool 直子扫描失效" % str(found_in_bucket.get_parent()))
	(_gl.pools[&"projectile"] as ProjectilePool).release(found_in_bucket)
	epool.release(enemy)

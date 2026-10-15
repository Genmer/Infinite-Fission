# tests/qa_r272_qa_indep_cases.gd
# R272 V-C2 QA 独立挖掘用例体（独立于开发套件 qa_r272_enemylazy_cases——不共用断言面）。
# 测试点（从 V-C2 语义提取，非开发套已锁的装配/直连池行为）：
#   q1 产品路径死亡归还链：spawner.enqueue+tick 真实出队（:101 host 注入）→ 敌 _on_died
#      → EventBus.enemy_killed → spawner.on_enemy_killed（:214）→ pool.release 统一口
#      lazy 分派——留桶+活跃表移除+池计数守恒+零污染。
#   q2 尸体看门狗口：game_loop._reap_corpses_soon（:1499）异常态敌（dead∧visible）强制
#      归还——同口 lazy 覆盖，无绕过。
#   q3 MM 镜像注册/注销幂等：mm 资格敌 spawn 注册 → release（unplace_lazy 镜像注销）→
#      再激活同贴图重注册 + 零 reparent；从未落位件 release 不炸不登记。
#   q4 boost 开真实战斗 soak（非直连池）：进 RUN 带武器打 ~6s——敌死亡-重生链真实流量，
#      全池零污染/零拒绝/零运行期实例化，镜像注册表无幽灵（在册 owner 全在活跃表）。
#   q5 trim_free_to 与留桶件交互：boost 开留桶空闲件被 trim queue_free——父节点无关性
#      行为核验（object_pool.gd:98-117 注释口径「空闲件已在池根下」已过时，验行为不破）。
# 夹具纪律：boost 用 PerfGovernor.boost_override（静态口，零盘档副作用）；Meta._settings
# 入口快照 + cleanup 还原落盘（R270 盘档毒口径）；池件勿二次 release。
extends RefCounted


const MAIN_SCENE := "res://scenes/main.tscn"
const GROVE_TABLE := "res://resources/maps/wave_table_grove.tres"
const PLAYER_HOME := Vector2(360.0, 660.0)
const DT := 1.0 / 60.0
const SOAK_SECONDS := 6                       # q4：死亡-重生链流量足够（非深载面）
const SOAK_HOLD := 30
const SOAK_BULLETS := 120

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null
var _saved_settings: Dictionary = {}
var _added: int = 0
var _removed: int = 0
var _comp: Array = []
var _cursor: int = 0
var _frame_i: int = 0
var _saw_parked: bool = false
var _parked_bad_visible: bool = false        # 留桶件可见性违例采样（q4.7）


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(20261015)
	_saved_settings = Meta._settings.duplicate(true)
	_boot_game_loop()
	await tree.process_frame
	await tree.process_frame
	PerfGovernor.set_process(false)
	PerfGovernor.boost_override = 1            # boost 开（静态口——零盘档副作用）
	tree.node_added.connect(_on_node_added)
	tree.node_removed.connect(_on_node_removed)
	_q1_product_death_path()
	_q2_corpse_watchdog()
	_q3_mm_mirror_idempotent()
	await _q4_real_combat_soak()
	_q6_fullload_release_fix_adjudication()
	_q5_trim_interacts_parked()                # 压轴：trim_free_to(0) 永久清零本实例敌池容量
	await _cleanup()
	tree.node_added.disconnect(_on_node_added)
	tree.node_removed.disconnect(_on_node_removed)
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


func _on_node_added(_n: Node) -> void:
	_added += 1


func _on_node_removed(_n: Node) -> void:
	_removed += 1


func _boot_game_loop() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "R272QAIndep"
	tree.get_root().add_child(_gl)


func _enter_run() -> bool:
	_gl.current_map_id = &"world_grove"
	if not _gl.start_run():
		_check("q 前置：start_run 成功", false, "start_run 返回 false")
		return false
	_gl.player.set("xp_need", 1.0e12)
	_gl.player.set("max_hp", 1.0e12)
	_gl.player.set("hp", 1.0e12)
	_gl.player.global_position = PLAYER_HOME
	return true


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


# ── q1 产品路径死亡归还链（spawner 统一口 lazy 覆盖） ────────────────
func _q1_product_death_path() -> void:
	print("── q1 产品路径死亡归还链 ──")
	if not _enter_run():
		return
	var pool: EnemyPool = _gl.pools[&"enemy"] as EnemyPool
	var host: Node = pool.bucket_host
	var st0: Dictionary = pool.stats()
	_gl.spawner.enqueue({"data": _fixture_enemy(&"E_R272_QA_A", 50.0), "wave": 1,
		"tags": 0, "pos": Vector2(200.0, 300.0)})
	var mine: Enemy = null
	for i in range(40):                        # 出队 4-8 只/帧（自然波序先投）——循环 tick 到本件出场
		_gl.spawner.tick(DT, _gl.enemy_grid)   # 产品出队口：acquire+host 注入+spawn+active
		for e in _gl.spawner.active:
			if e is Enemy and (e as Enemy).data != null and (e as Enemy).data.id == &"E_R272_QA_A":
				mine = e as Enemy
				break
		if mine != null:
			break
	_check("q1.1 spawner 产品路径出队（active 含夹具敌）", mine != null,
		"active=%d" % _gl.spawner.active.size())
	if mine == null:
		return
	_check("q1.2 产品路径落桶（spawner:101 host 注入 → _place_in_bucket）",
		host.is_ancestor_of(mine) and mine.get_parent() != pool,
		"parent=%s" % str(mine.get_parent()))
	var st1: Dictionary = pool.stats()
	_check("q1.3 出队后池计数守恒（free+live==capacity）",
		int(st1["free"]) + int(st1["live"]) == int(st1["capacity"]),
		"free=%d live=%d cap=%d" % [int(st1["free"]), int(st1["live"]), int(st1["capacity"])])
	mine._on_died()                            # 真实死亡链：emit_enemy_killed → spawner 订阅
	_check("q1.4 死亡链经 on_enemy_killed 归还（active 移除）",
		not _gl.spawner.active.has(mine), "仍在 active")
	_check("q1.5 boost 开产品路径归还留桶（V-C2 核心语义——unplace_lazy 零 reparent）",
		is_instance_valid(mine) and mine.get_parent() != pool and host.is_ancestor_of(mine),
		"parent=%s" % str(mine.get_parent() if is_instance_valid(mine) else "<freed>"))
	_check("q1.6 归还件机械清理（visible=false——桶下不绘）",
		is_instance_valid(mine) and not (mine as CanvasItem).visible,
		"visible=%s" % str((mine as CanvasItem).visible if is_instance_valid(mine) else "?"))
	var st2: Dictionary = pool.stats()
	_check("q1.7 归还后池计数守恒", int(st2["free"]) + int(st2["live"]) == int(st2["capacity"]),
		"free=%d live=%d cap=%d" % [int(st2["free"]), int(st2["live"]), int(st2["capacity"])])
	_check("q1.8 产品路径归还零污染零拒绝（pollution/rejected 基线差==0）",
		int(st2["pollution"]) == int(st0["pollution"])
			and int(st2["rejected_releases"]) == int(st0["rejected_releases"]),
		"pol=%d→%d rej=%d→%d" % [int(st0["pollution"]), int(st2["pollution"]),
			int(st0["rejected_releases"]), int(st2["rejected_releases"])])


# ── q2 尸体看门狗口（game_loop._reap_corpses_soon:1499 同口） ────────
func _q2_corpse_watchdog() -> void:
	print("── q2 尸体看门狗口 ──")
	var pool: EnemyPool = _gl.pools[&"enemy"] as EnemyPool
	var host: Node = pool.bucket_host
	var st0: Dictionary = pool.stats()
	var e := pool.acquire() as Enemy
	e.bucket_host = host
	e.spawn(_fixture_enemy(&"E_R272_QA_WD", 100.0), 1, 0)
	e.position = Vector2(120.0, 200.0)
	_gl.spawner.active.append(e)
	e.dead = true                               # 异常态：dead ∧ visible（绕过 _on_died 模拟尸体滞留）
	_gl._reap_corpses_soon(2.0)                 # 跳过 1s 降频门
	_check("q2.1 看门狗归还（active 移除）", not _gl.spawner.active.has(e), "仍在 active")
	_check("q2.2 看门狗归还同口 lazy（留桶非池根——:1499 → pool.release 统一分派）",
		is_instance_valid(e) and e.get_parent() != pool and host.is_ancestor_of(e),
		"parent=%s" % str(e.get_parent() if is_instance_valid(e) else "<freed>"))
	var st1: Dictionary = pool.stats()
	_check("q2.3 看门狗归还零污染零拒绝",
		int(st1["pollution"]) == int(st0["pollution"])
			and int(st1["rejected_releases"]) == int(st0["rejected_releases"]),
		"pol=%d rej=%d" % [int(st1["pollution"]), int(st1["rejected_releases"])])


# ── q3 MM 镜像注册/注销幂等 + 再激活链 ───────────────────────────────
func _q3_mm_mirror_idempotent() -> void:
	print("── q3 MM 镜像幂等与再激活 ──")
	var pool: EnemyPool = _gl.pools[&"enemy"] as EnemyPool
	var host: TexBucketHost = pool.bucket_host as TexBucketHost
	var mc0: int = host.mirror_count()
	var e := pool.acquire() as Enemy
	e.bucket_host = host
	e.spawn(_fixture_enemy(&"E_R272_QA_MM", 100.0), 1, 0)   # 未知 kind → 非排除面（mm 资格）
	var reg_tex: Texture2D = host.mirror_tex_of(e)
	_check("q3.1 mm 资格敌 spawn 后镜像注册（mirror_tex_of 非空）",
		reg_tex != null, "tex=%s mm_eligible=%s" % [str(reg_tex), str(e.call(&"_mm_eligible"))])
	_check("q3.2 注册后 mirror_count +1", host.mirror_count() == mc0 + 1,
		"mc %d→%d" % [mc0, host.mirror_count()])
	_check("q3.3 敌侧 _mm_on 在册", bool(e.get("_mm_on")), "mm_on=false")
	pool.release(e)                             # boost 开 → unplace_lazy（镜像注销）
	_check("q3.4 release 镜像注销（mirror_tex_of 空——防幽灵实例绘制）",
		host.mirror_tex_of(e) == null, "tex=%s" % str(host.mirror_tex_of(e)))
	_check("q3.5 注销后 mirror_count 回落", host.mirror_count() == mc0,
		"mc=%d 期望 %d" % [host.mirror_count(), mc0])
	_check("q3.6 _reset_state 清 _mm_on", not bool(e.get("_mm_on")), "mm_on=true")
	# 再激活链：同贴图复用 → 重注册 + 零 reparent
	_added = 0
	_removed = 0
	var e2 := pool.acquire() as Enemy
	e2.bucket_host = host
	e2.spawn(_fixture_enemy(&"E_R272_QA_MM", 100.0), 1, 0)
	_check("q3.7 再激活取回同一件（LIFO）", e2 == e, "e2!=e")
	_check("q3.8 再激活镜像重注册（同贴图回同键）",
		host.mirror_tex_of(e2) == reg_tex, "tex=%s 期望 %s" % [str(host.mirror_tex_of(e2)), str(reg_tex)])
	_check("q3.9 再激活零树进出（node_added==0 且 node_removed==0——留桶件复用）",
		_added == 0 and _removed == 0, "added=%d removed=%d" % [_added, _removed])
	pool.release(e2)
	# 从未落位/从未注册件：release 不炸、不登记镜像、原位不动（池根）
	var mc1: int = host.mirror_count()
	# 不注入 host、不 spawn——栈顶可能是历史留桶件（q2 看门狗归还的 LIFO），翻栈找
	# 真正从未落位的池根件再验（本断言锁的是 unplace_lazy 对从未落位件零搬动）
	var bare: Enemy = null
	var popped: Array[Enemy] = []                # 翻栈暂存（release 会压回栈顶——边翻边还=同件死循环）
	for i in range(24):
		var cand := pool.acquire() as Enemy
		if cand.get_parent() == pool:
			bare = cand                          # 命中：从未落位件
			break
		popped.append(cand)                      # 留桶翻出件：暂存，命中后统一归还
	if bare == null and not popped.is_empty():
		bare = popped.pop_back()                 # 兜底：全留桶（极端周转态）——用末件验（详注 parent）
	for c in popped:
		pool.release(c)                          # 未用翻出件归还（各自至多一次——无二次 release）
	_check("q3.11a 前置：取到从未落位件（池根）", bare != null and bare.get_parent() == pool,
		"parent=%s" % str(bare.get_parent() if bare != null else "<null>"))
	pool.release(bare)
	_check("q3.10 未落位件 release 零镜像残留（mirror_count 不变）",
		host.mirror_count() == mc1, "mc %d→%d" % [mc1, host.mirror_count()])
	_check("q3.11 未落位件 release 原位（池根——unplace_lazy 不搬从未落位件）",
		is_instance_valid(bare) and bare.get_parent() == pool,
		"parent=%s" % str(bare.get_parent() if is_instance_valid(bare) else "<freed>"))


# ── q4 boost 开真实战斗 soak（非直连池） ────────────────────────────
func _q4_real_combat_soak() -> void:
	print("── q4 真实战斗 soak（%ds） ──" % SOAK_SECONDS)
	var gatling: Node = _gl.player.add_weapon(_gl.registry.get_weapon(&"W2_gatling"))
	if gatling == null:
		_check("q4 前置：武器挂载", false, "W2_gatling 取空")
		return
	gatling.level = 3
	_gl.wave_director.set("_hard_cap_left", 9999.0)
	if _comp.is_empty() and not _load_composition():
		return
	var epool: EnemyPool = _gl.pools[&"enemy"] as EnemyPool
	var xpool: ObjectPool = _gl.pools[&"projectile"] as ObjectPool
	var ehits0: int = int((epool.stats())["hits"])
	var frame_releases := [0]                  # 敌死亡链观测（enemy_killed 计数）
	_saw_parked = false                        # soak 全程采样（末点采样会被 LIFO 复用吃掉——留桶件恰是被复用件）
	var on_kill := func(_p: Node2D) -> void: frame_releases[0] += 1
	EventBus.enemy_killed.connect(on_kill)
	_frame_i = 0
	var cb := Callable(self, "_on_soak_frame")
	tree.physics_frame.connect(cb)
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < SOAK_SECONDS * 1000:
		await tree.physics_frame
	tree.physics_frame.disconnect(cb)
	EventBus.enemy_killed.disconnect(on_kill)
	var est: Dictionary = epool.stats()
	var pst: Dictionary = xpool.stats()
	var xst: Dictionary = (_gl.pools[&"xp"] as ObjectPool).stats()
	_check("q4.1 soak 期真实敌死亡链流量（enemy_killed ≥ 5 次）", frame_releases[0] >= 5,
		"killed=%d" % frame_releases[0])
	_check("q4.2 敌池零污染零拒绝（真实死亡-重生链）",
		int(est["pollution"]) == 0 and int(est["rejected_releases"]) == 0,
		"pol=%d rej=%d" % [int(est["pollution"]), int(est["rejected_releases"])])
	_check("q4.3 弹/xp 池零污染零拒绝",
		int(pst["pollution"]) == 0 and int(pst["rejected_releases"]) == 0
			and int(xst["pollution"]) == 0 and int(xst["rejected_releases"]) == 0,
		"p(pol=%d rej=%d) x(pol=%d rej=%d)" % [int(pst["pollution"]), int(pst["rejected_releases"]),
			int(xst["pollution"]), int(xst["rejected_releases"])])
	_check("q4.4 敌池零运行期实例化（容量内周转）",
		int(est["runtime_instantiates"]) == 0, "ri=%d" % int(est["runtime_instantiates"]))
	_check("q4.5 敌池真实周转（hits 增量 > 0）",
		int(est["hits"]) > ehits0, "hits %d→%d" % [ehits0, int(est["hits"])])
	# lazy 口真实流量证明：soak 全程任一帧空闲栈存在留桶件（boost 开 release 真走了
	# unplace_lazy；末点独采样无效——LIFO 下留桶件恰是优先被复用的件）
	_check("q4.6 敌池空闲栈存在留桶件（soak 全程采样——lazy 归位真实生效）", _saw_parked,
		"saw_parked=false")
	_check("q4.7 留桶空闲件全程不可见（不绘不断批）", not _parked_bad_visible,
		"bad_visible=true")
	# 幽灵镜像检查：在册 owner 全部仍在活跃表（释放件已注销，无幽灵注册）
	var host: TexBucketHost = epool.bucket_host as TexBucketHost
	var ghost := 0
	var owners: Dictionary = host.get("_mm_owner_tex")
	for o in owners.keys():
		if not is_instance_valid(o) or not _gl.spawner.active.has(o):
			ghost += 1
	_check("q4.8 镜像注册表无幽灵（在册 owner 全在活跃表）", ghost == 0, "ghost=%d" % ghost)
	_check("q4.9 soak 末仍在 PLAYING（会话保活）",
		int(_gl.state) == GameConst.GameStatus.PLAYING, "state=%d" % int(_gl.state))


func _on_soak_frame() -> void:
	_frame_i += 1
	if not _saw_parked or not _parked_bad_visible:   # 见违例才继续扫（首见留桶后仅扫可见性）
		for n in (_gl.pools[&"enemy"] as EnemyPool).get("_free_list"):
			var nd: Node2D = n as Node2D
			if nd != null and nd.get_parent() != _gl.pools[&"enemy"]:
				_saw_parked = true
				if nd.visible:
					_parked_bad_visible = true
	var ang := float(_frame_i) * 0.35 / 60.0
	_gl.player.global_position = Vector2(360.0 + cos(ang) * 140.0,
		660.0 + sin(ang) * 200.0)
	var alive: int = _gl.spawner.active.size()
	var want := mini(6, SOAK_HOLD - alive)
	for i in range(want):
		_spawn_one()
	var pool: ProjectilePool = _gl.pools[&"projectile"] as ProjectilePool
	var bwant := mini(SOAK_BULLETS - pool.total_active(), 6)
	for i in range(bwant):
		_inject_filler_bullet()


func _spawn_one() -> void:
	if _comp.is_empty():
		return
	var c: Dictionary = _comp[_cursor % _comp.size()]
	_cursor += 1
	var e := (_gl.pools[&"enemy"] as EnemyPool).acquire() as Enemy
	if e == null:
		return
	e.bucket_host = (_gl.pools[&"enemy"] as EnemyPool).bucket_host
	e.spawn(c["data"], 16, int(c["tags"]))
	var pp: Vector2 = _gl.player.global_position
	e.global_position = Vector2(clampf(pp.x + randf_range(-320.0, 320.0), 16.0, 704.0),
		clampf(pp.y + randf_range(-320.0, 320.0), 16.0, 1264.0))
	_gl.spawner.active.append(e)


func _inject_filler_bullet() -> void:
	var pool: ProjectilePool = _gl.pools[&"projectile"] as ProjectilePool
	var pb: ProjectileBase = pool.acquire(0)
	if pb == null:
		return
	pb.damage_pipeline = _gl.pipeline
	pb.enemy_grid = _gl.enemy_grid
	pb.pool = pool
	pb.elemental = _gl.elemental
	var ang := randf() * TAU
	var r := randf_range(200.0, 380.0)
	pb.spawn({
		"position": Vector2(clampf(360.0 + cos(ang) * r, 16.0, 704.0),
			clampf(660.0 + sin(ang) * r, 16.0, 1264.0)),
		"velocity": Vector2.from_angle(randf() * TAU) * randf_range(2.0, 12.0),
		"lifetime": 9.0, "pierce": 24, "bounces": 0,
		"hitbox_radius": 2.0, "team": 0,
	})


func _load_composition() -> bool:
	var tbl: Resource = load(GROVE_TABLE)
	if tbl == null or not ("entries" in tbl):
		_check("q4 前置：波表加载", false, GROVE_TABLE)
		return false
	var entry: Resource = null
	for e in tbl.get("entries"):
		if int(e.get("index")) == 16:
			entry = e
			break
	if entry == null:
		_check("q4 前置：波 16 条目", false, "index 16 缺")
		return false
	for c in entry.get("composition"):
		var src: EnemyData = _gl.registry.get_enemy(StringName(c.get("enemy_id")))
		if src == null:
			_check("q4 前置：敌数据", false, String(c.get("enemy_id")))
			return false
		var data: EnemyData = src.duplicate()
		data.hp_base = data.hp_base * 0.05
		var tags := int(c.get("tags", 0))
		for i in range(int(c.get("count", 1))):
			_comp.append({"data": data, "tags": tags})
	_comp.shuffle()
	return true


# ── q5 trim_free_to 与留桶件交互（object_pool.gd:98-117 行为核验） ────
func _q5_trim_interacts_parked() -> void:
	print("── q5 trim_free_to 留桶交互 ──")
	var pool: EnemyPool = _gl.pools[&"enemy"] as EnemyPool
	var host: TexBucketHost = pool.bucket_host as TexBucketHost
	var parked_nodes: Array[Node2D] = []
	for i in range(3):                          # 3 件留桶（boost 开 release）
		var e := pool.acquire() as Enemy
		e.bucket_host = host
		e.spawn(_fixture_enemy(&"E_R272_QA_T%d" % i, 100.0), 1, 0)
		pool.release(e)
		parked_nodes.append(e)
	var all_parked := true
	for e in parked_nodes:
		if e.get_parent() == pool or not host.is_ancestor_of(e):
			all_parked = false
	_check("q5.1 前置：3 件归还全留桶", all_parked, "")
	var bucket_child0 := 0
	for b in host.get_children():
		bucket_child0 += (b as Node).get_child_count()
	var st0: Dictionary = pool.stats()
	var mc0: int = host.mirror_count()
	var trimmed: int = pool.trim_free_to(0)     # 裁到 0（capacity=live=0）
	await tree.process_frame                  # queue_free 落地
	await tree.process_frame
	_check("q5.2 trim 返回裁掉数==free（含留桶件）", trimmed == int(st0["free"]),
		"trimmed=%d free0=%d" % [trimmed, int(st0["free"])])
	var freed_ok := true
	for e in parked_nodes:
		if is_instance_valid(e):
			freed_ok = false
	_check("q5.3 留桶空闲件 queue_free 落地（父节点无关性——桶下件照常释放）",
		freed_ok, "有留桶件未释放")
	var bucket_child1 := 0
	for b in host.get_children():
		bucket_child1 += (b as Node).get_child_count()
	_check("q5.4 桶下子件数回落（≥3——被裁件已离桶）", bucket_child0 - bucket_child1 >= 3,
		"child %d→%d" % [bucket_child0, bucket_child1])
	var fl: Array = pool.get("_free_list")
	_check("q5.5 裁后空闲栈空（不持已释放节点）", fl.is_empty(), "free=%d" % fl.size())
	_check("q5.6 trim 后镜像注册表无残留（mirror_count 不变）",
		host.mirror_count() == mc0, "mc %d→%d" % [mc0, host.mirror_count()])
	var st1: Dictionary = pool.stats()
	_check("q5.7 trim 后 acquire=满池 null（容量 0——不复活已释放件）",
		pool.acquire() == null, "acquire 非 null")
	_check("q5.8 trim 后池计数守恒（free+live==capacity==0）",
		int(st1["free"]) + int(st1["live"]) == int(st1["capacity"]),
		"free=%d live=%d cap=%d" % [int(st1["free"]), int(st1["live"]), int(st1["capacity"])])
	_check("q5.9 trim 路径零拒绝计数（误 release 防御口未误触）",
		int(st1["rejected_releases"]) == int(st0["rejected_releases"]),
		"rej %d→%d" % [int(st0["rejected_releases"]), int(st1["rejected_releases"])])


# ── q6 满载档释放门修复复核（评审#1/#2 dead 门——独立裁决臂，含带闪死亡臂） ──
func _q6_fullload_release_fix_adjudication() -> void:
	print("── q6 满载档释放门（评审#1 修复独立复核） ──")
	var pool: EnemyPool = _gl.pools[&"enemy"] as EnemyPool
	var host: TexBucketHost = pool.bucket_host as TexBucketHost
	Enemy.fullload_override = 1                 # 真机满载档（headless 无 mobile feature 的覆写口）
	# 臂A 带闪死亡（评审#3 点名缺口——grunt 死于闪白窗内）：
	var ea := pool.acquire() as Enemy
	ea.bucket_host = host
	ea.spawn(_fixture_enemy(&"E_R272_QA_FLG", 100.0), 1, 0)
	var body_bucket_a: Node = ea.get_parent()
	ea.call(&"_apply_flash", 1.0)               # 闪白起：白变体贴图+换闪桶（活跃路径）
	var flash_bucket_a: Node = ea.get_parent()
	_check("q6.1 前置：满载闪白换桶（活跃路径不受本刀影响）",
		flash_bucket_a != body_bucket_a and host.is_ancestor_of(ea),
		"body=%s flash=%s" % [str(body_bucket_a), str(flash_bucket_a)])
	_added = 0
	_removed = 0
	ea._on_died()                               # 带闪死亡：真实链 → spawner → release（lazy）
	_check("q6.2 带闪死亡释放零树进出（dead 门挡回桶——修复前=复位贴图回桶 reparent）",
		_added == 0 and _removed == 0, "added=%d removed=%d" % [_added, _removed])
	_check("q6.3 带闪死亡释放镜像不回册（修复前=重注册违 :2217 不变量）",
		host.mirror_tex_of(ea) == null and ea.get(&"_mm_on") == false,
		"mirror=%s mm_on=%s" % [str(host.mirror_tex_of(ea)), str(ea.get(&"_mm_on"))])
	_check("q6.4 带闪死亡释放留原（闪）桶零搬动",
		is_instance_valid(ea) and ea.get_parent() == flash_bucket_a,
		"parent=%s 期望闪桶" % str(ea.get_parent() if is_instance_valid(ea) else "<freed>"))
	# 臂B 非 grunt 平样释放（满载 _restore_flash_tex 无条件路）：
	var eb := pool.acquire() as Enemy
	eb.bucket_host = host
	eb.spawn(_fixture_enemy(&"E2_R272_QA_FLB", 100.0), 1, 0)   # E2 前缀 → 非 grunt 分型
	var kind_b: StringName = eb.get(&"_kind")
	var bucket_b: Node = eb.get_parent()
	_added = 0
	_removed = 0
	eb._on_died()
	_check("q6.5 非 grunt（kind=%s）释放零树进出（修复前=回 grunt 桶 reparent）" % str(kind_b),
		_added == 0 and _removed == 0, "added=%d removed=%d" % [_added, _removed])
	_check("q6.6 非 grunt 释放留原桶（不并 grunt 桶）",
		is_instance_valid(eb) and eb.get_parent() == bucket_b,
		"parent=%s 期望原桶" % str(eb.get_parent() if is_instance_valid(eb) else "<freed>"))
	_check("q6.7 非 grunt 释放镜像不回册", host.mirror_tex_of(eb) == null, "")
	# 臂C 活跃期闪毕（守卫活侧逐位不变——dead==false 照旧回桶+回册）：
	var ec := pool.acquire() as Enemy
	ec.bucket_host = host
	ec.spawn(_fixture_enemy(&"E_R272_QA_FLC", 100.0), 1, 0)
	var body_bucket_c: Node = ec.get_parent()
	ec.call(&"_apply_flash", 1.0)
	ec.call(&"_apply_flash", 0.0)               # 活跃期闪毕（未死）→ 复位贴图+回原桶
	_check("q6.8 活跃期闪毕回原桶（守卫活侧不变——dead 门只挡归还路）",
		ec.get_parent() == body_bucket_c, "parent=%s 期望本体桶" % str(ec.get_parent()))
	_check("q6.9 活跃期闪毕镜像在册（活敌照常注册）",
		host.mirror_tex_of(ec) != null, "mirror=%s" % str(host.mirror_tex_of(ec)))
	pool.release(ec)
	Enemy.fullload_override = -1                # 复位覆写口
	var st: Dictionary = pool.stats()
	_check("q6.10 满载臂后池计数守恒+零污染零拒绝",
		int(st["free"]) + int(st["live"]) == int(st["capacity"])
			and int(st["pollution"]) == 0 and int(st["rejected_releases"]) == 0,
		"free=%d live=%d pol=%d rej=%d" % [int(st["free"]), int(st["live"]),
			int(st["pollution"]), int(st["rejected_releases"])])


func _cleanup() -> void:
	PerfGovernor.boost_override = -1
	PerfGovernor.set_process(true)
	Meta._settings = _saved_settings
	Meta._save()
	RunSave.clear()
	tree.paused = false
	if _gl != null:
		_gl.free()
		_gl = null

# tests/runner/r212_poolwarm_cases.gd
# R212 用例体：池预热满容回归（「池扩容尖峰」疑点销案固化）。
# 背景：vc18 真机敌段 44-68ms / 弹段 32-39ms 尖峰疑「acquire 池空瞬时 instantiate」——
#   代码+探针双重证伪：boot 期 prewarm(容量)（game_loop.gd:1506-1512、spawner.prewarm
#   enemy_spawner.gd:35-38）把每池空闲栈填满到 ==capacity，于是 acquire 懒增长条件
#   `_free_list.size() + _live_count < _capacity`（object_pool.gd:58）运行期恒不可达。
# 本套件把探针（工作区根 probe_pool_pregrow.gd）断言固化为回归红线：谁把 prewarm
#   改成欠预热（prewarm < capacity），懒增长口子即被打开，①当场红。
# 三条红线（与探索方案一致，本套件零产品码改动）：
#   ① 池语义不变——容量绑定/容量内懒增长/满池 null 降级三口径由 ⑤ 自建池锚定；
#   ② 预热时机不动——boot 期同步全量 prewarm 维持原值（敌 128/弹 820，不抬不欠）；
#   ③ 运行期稳态 instantiate 必须 == 0（object_pool.gd:23 架构红线注释）。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const SCENE_PROJ := "res://scenes/combat/projectiles/ballistic_projectile.tscn"
const PLAYER_HOME := Vector2(360.0, 900.0)
# 七池键（game_loop.gd:1496 pools 字典同款；homing 容量 24 为硬编码口径 game_loop.gd:1507）
const POOL_KEYS: Array[StringName] = [
	&"projectile", &"homing", &"enemy", &"popup", &"particle", &"laser", &"xp",
]
# 容量真源对账（data/balance/balance_tables.tres:23 pool_prewarm 原值——R212 明确不改）
const CAP_TRUTH: Dictionary = {
	&"projectile": 820, &"enemy": 128, &"popup": 80, &"particle": 64, &"laser": 12,
	&"xp": 160, &"homing": 24,
}

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null
var _enemy_nodes: Array[Node] = []             # ②取出的敌件（④释放用）
var _proj_nodes: Array[Node] = []              # ②取出的弹件（④释放用）


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_boot_game_loop()
	await tree.process_frame
	await tree.process_frame
	_test_1_boot_prewarm_full()
	_enter_run_frozen()
	_test_2_acquire_over_capacity()
	_test_3_release_restore()
	_test_4_lazy_grow_semantics_intact()
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
	_gl.name = "R212GameLoopUnderTest"
	tree.get_root().add_child(_gl)   # _ready → boot（_boot_build_pools 七池全量 prewarm 同步完成）


func _enter_run_frozen() -> void:
	# r210 同构：start_run 后置回 MENU 冻结波次（②③④静止环境；无 await 物理帧不插入）
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


# ── ① boot 后七池 free==capacity（懒增长分支不可达·反向防回归核心） ──
func _test_1_boot_prewarm_full() -> void:
	print("── ① boot 预热满容 ──")
	var pools: Dictionary = _gl.pools
	_check("七池键齐全（projectile/homing/enemy/popup/particle/laser/xp）",
		pools.size() == POOL_KEYS.size() and POOL_KEYS.all(func(k: StringName) -> bool:
			return pools.has(k)), "size=%d" % pools.size())
	for key in POOL_KEYS:
		var pool := pools[key] as ObjectPool
		var st: Dictionary = pool.stats()
		_check("[%s] free==capacity（prewarm 填满→懒增长 free+live<cap 恒假）"
			% String(key), int(st["free"]) == int(st["capacity"]),
			"free=%d cap=%d" % [int(st["free"]), int(st["capacity"])])
		_check("[%s] boot 后 live==0（静止满容，非借出态填满）" % String(key),
			int(st["live"]) == 0, "live=%d" % int(st["live"]))
		_check("[%s] runtime_instantiates==0（预热实例化不计运行期）" % String(key),
			int(st["runtime_instantiates"]) == 0,
			"runtime_inst=%d" % int(st["runtime_instantiates"]))
		_check("[%s] 容量真源对账 ==%d（balance_tables.tres 原值）"
			% [String(key), int(CAP_TRUTH[key])], int(st["capacity"]) == int(CAP_TRUTH[key]),
			"cap=%d" % int(st["capacity"]))
	var enemy_pool := pools[&"enemy"] as ObjectPool
	_check("敌池容量 128 ≥ MAX_ONSCREEN 120（满载段不触池顶）",
		int(enemy_pool.stats()["capacity"]) >= EnemySpawner.MAX_ONSCREEN,
		"cap=%d MAX_ONSCREEN=%d" % [int(enemy_pool.stats()["capacity"]), EnemySpawner.MAX_ONSCREEN])
	print("  参考 | boot 全预热耗时 %s ms（机器相关，仅记录不断言）"
		% str(_gl.get("_boot_elapsed_ms")))


# ── ② 连取超容（敌130/弹850）：null 降级 + 零运行期实例化（探针 B 断言固化） ──
func _test_2_acquire_over_capacity() -> void:
	print("── ② 连取超容 ──")
	var enemy_pool := _gl.pools[&"enemy"] as EnemyPool
	var miss_e0: int = int(enemy_pool.stats()["misses"])
	var null_e: int = 0
	for i in range(130):                          # 容量 128 / MAX_ONSCREEN 120
		var e := enemy_pool.acquire()
		if e == null:
			null_e += 1
		else:
			_enemy_nodes.append(e)
	_check("敌池连取 130 发：128 命中 + 2 null（满池降级不实例化不阻塞）",
		_enemy_nodes.size() == 128 and null_e == 2,
		"got=%d null=%d" % [_enemy_nodes.size(), null_e])
	_check("敌池 runtime_inst 仍 ==0（超容走 null 降级而非懒增长）",
		enemy_pool.runtime_instantiate_count == 0,
		"runtime_inst=%d" % enemy_pool.runtime_instantiate_count)
	_check("敌池超容 2 发全部计 miss（misses +2，丢弃可观测）",
		int(enemy_pool.stats()["misses"]) - miss_e0 == 2,
		"miss 增量=%d" % (int(enemy_pool.stats()["misses"]) - miss_e0))

	var proj_pool := _gl.pools[&"projectile"] as ProjectilePool
	_check("弹池前置静止（start_run 未借出件）",
		int(proj_pool.stats()["free"]) == int(CAP_TRUTH[&"projectile"]),
		"free=%d" % int(proj_pool.stats()["free"]))
	var miss_p0: int = int(proj_pool.stats()["misses"])
	var miss_at_cap: int = 0
	var null_p: int = 0
	for i in range(850):                          # 容量 820 ≫ 真机观测 live 峰 181
		var p := proj_pool.acquire()
		if p == null:
			null_p += 1
		else:
			_proj_nodes.append(p)
		if i == 819:
			miss_at_cap = int(proj_pool.stats()["misses"])
	_check("弹池连取 850 发：820 命中 + 30 null（容量内全命中）",
		_proj_nodes.size() == 820 and null_p == 30,
		"got=%d null=%d" % [_proj_nodes.size(), null_p])
	_check("弹池前 820 发 miss 增量 ==0（容量内零丢弃——真机 live 峰 181≪820 口径）",
		miss_at_cap - miss_p0 == 0, "增量=%d" % (miss_at_cap - miss_p0))
	_check("弹池超容 30 发全部计 miss（misses +30，弹量上探不静默丢弃）",
		int(proj_pool.stats()["misses"]) - miss_at_cap == 30,
		"miss 增量=%d" % (int(proj_pool.stats()["misses"]) - miss_at_cap))
	_check("弹池 runtime_inst 仍 ==0",
		proj_pool.runtime_instantiate_count == 0,
		"runtime_inst=%d" % proj_pool.runtime_instantiate_count)
	# 全池合计聚合（= game_loop.diag_counts 未来 &"runtime_inst" 键同构口径，
	# 1Hz 诊断行「ri%d」的真机销案断言在此预锁）
	var ri_sum: int = 0
	for key in _gl.pools:
		ri_sum += int((_gl.pools[key] as ObjectPool).runtime_instantiate_count)
	_check("全池 runtime_inst 合计 ==0（vc19 真机 1Hz 行 ri 应恒 0 的同构断言）",
		ri_sum == 0, "ri_sum=%d" % ri_sum)
	_check("命中件均为池树内成员（parent==池节点，无池外 instantiate 补偿）",
		_enemy_nodes[0].get_parent() == enemy_pool
			and _enemy_nodes[_enemy_nodes.size() - 1].get_parent() == enemy_pool
			and _proj_nodes[0].get_parent() == proj_pool
			and _proj_nodes[_proj_nodes.size() - 1].get_parent() == proj_pool, "")


# ── ③ 释放恢复 + 池归还语义（勿二次 release 红线由拒绝计数锚定） ──
func _test_3_release_restore() -> void:
	print("── ③ 释放恢复 ──")
	var enemy_pool := _gl.pools[&"enemy"] as EnemyPool
	var proj_pool := _gl.pools[&"projectile"] as ProjectilePool
	for e in _enemy_nodes:
		enemy_pool.release(e)
	for p in _proj_nodes:
		proj_pool.release(p)
	var st_e: Dictionary = enemy_pool.stats()
	var st_p: Dictionary = proj_pool.stats()
	_check("敌 128 件全归还：free 回 128 / live 0 / 拒还 0",
		int(st_e["free"]) == 128 and int(st_e["live"]) == 0
			and int(st_e["rejected_releases"]) == 0,
		"free=%d live=%d rej=%d" % [int(st_e["free"]), int(st_e["live"]), int(st_e["rejected_releases"])])
	_check("弹 820 件全归还：free 回 820 / live 0 / 活跃表清空",
		int(st_p["free"]) == 820 and int(st_p["live"]) == 0
			and proj_pool.active_projectiles().size() == 0,
		"free=%d live=%d active=%d" % [int(st_p["free"]), int(st_p["live"]),
			proj_pool.active_projectiles().size()])
	_check("归还后两池 runtime_inst 仍 ==0（循环复用零实例化）",
		enemy_pool.runtime_instantiate_count == 0
			and proj_pool.runtime_instantiate_count == 0, "")
	# 二次归还拦截（预期触发一次 push_error——本用例故意违例验证拒绝计数，非污染）
	var dup: Node = _enemy_nodes[0]
	var rej0: int = int(enemy_pool.stats()["rejected_releases"])
	enemy_pool.release(dup)
	_check("重复归还被拒（rejected_releases +1——池成员标记防御原样）",
		int(enemy_pool.stats()["rejected_releases"]) == rej0 + 1,
		"rej %d→%d" % [rej0, int(enemy_pool.stats()["rejected_releases"])])
	_enemy_nodes.clear()
	_proj_nodes.clear()


# ── ④ 自建欠预热池：懒增长/满池降级语义不变（红线①锚——防本套件被误读为「删懒增长」） ──
func _test_4_lazy_grow_semantics_intact() -> void:
	print("── ④ 池语义不变 ──")
	var pool := ObjectPool.new()
	pool.name = "R212LazyGrowProbe"              # 纪律：显式 name（find 口径）
	tree.get_root().add_child(pool)
	pool.setup(&"r212_probe", load(SCENE_PROJ), 4)
	var live: Array[Node] = []
	for i in range(4):
		live.append(pool.acquire())
	_check("欠预热池容量内懒增长可达（4/4 命中，runtime_inst==4——语义未被改死）",
		live.all(func(n: Node) -> bool: return n != null)
			and pool.runtime_instantiate_count == 4,
		"runtime_inst=%d" % pool.runtime_instantiate_count)
	_check("第 5 发 null 降级 + misses==1（满池丢弃计数语义原样）",
		pool.acquire() == null and int(pool.stats()["misses"]) == 1, "")
	pool.release(live[0])
	var reused: Node = pool.acquire()
	_check("归还后复用不实例化（runtime_inst 仍 4——空闲栈弹出语义原样）",
		reused != null and pool.runtime_instantiate_count == 4, "")
	for n in live:
		if is_instance_valid(n):
			pool.release(n)                      # live[0] 复取在外，此处为有效归还
	_check("探针池收尾干净（free==4 / live==0）",
		int(pool.stats()["free"]) == 4 and int(pool.stats()["live"]) == 0,
		"free=%d live=%d" % [int(pool.stats()["free"]), int(pool.stats()["live"])])
	pool.free()

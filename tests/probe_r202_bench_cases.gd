# tests/probe_r202_bench_cases.gd
# R202 基准探针用例体（由 probe_r202_bench.gd 入口在 autoload 就绪后运行时加载编译；
# 不带 test_ 前缀——不进电池 glob）。boot 模式仿 mirror_muzzle_cases.gd 的
# _boot_game_loop/_spawn_fixtures。
# 口径（如实登记）：
# · start_run 后置回 MENU 冻结波次刷怪（夹具敌自管——mirror 同先例）；玩家固定
#   PLAYER_HOME（E-15 活动区钳制带内合法位）。
# · 计时区间 = 生产帧序（架构 §2.17）战斗切片 ②player.tick → ④grid rebuild + 弹 tick
#   → ⑤敌 tick（DT=1/60，300 帧）。命中压力真实发生：W2 加特林 L1 默认参数持续开火
#   （rof 11/s 冷 → 14/s 热，spin_up 2.0s——预热 150 帧后测量窗全热档；pierce 1），
#   弹飞行 → 网格查询 → 伤害管线结算 → 跳字/粒子全部真路径。
# · 维持动作（跳字衰减 popup_manager.tick / game_feel.tick 粒子寿命回收）在计时
#   区间外驱动——先例 perf_500p100e_cases.gd:8-9「补给动作在帧计时区间外——恒定
#   满载稳态口径」。
# · 不含项（测量值是下界口径）：elemental.tick/detect_reactions（无元素附魔零负载）、
#   敌间分离力（_apply_enemy_separation 按 spawner.active 迭代——夹具敌不在册且铺位
#   不重叠，分离语义 N/A）、波次/遗物/尸体看门狗（MENU 冻结）、敌弹网格（无敌射手）。
# · 敌池扩容：prewarm 128（balance_tables.tres）< 300，经 ObjectPool.setup 重绑容量后
#   容量内懒增长（object_pool.gd §5.1 认可路径）；探针完整体 _gl.free() 不残留。
# 输出契约：逐行 `BENCH N=<n> AVG=<x.xx>ms`（N=50/100/200/300 四行），全部打印且
# 夹具齐员则 fail_count()==0（入口退出码 0）。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const DT60 := 1.0 / 60.0
const WARMUP_FRAMES := 150                    # 2.5s：加特林 spin_up 2.0s 后测量窗全热档
const MEASURE_FRAMES := 300                   # 契约帧数（1/60 步长）
const NS: Array[int] = [50, 100, 200, 300]
const PLAYER_HOME := Vector2(360.0, 900.0)    # mirror_muzzle_cases 同位（钳制带内）
const GRID_STEP := 44.0                       # 夹具铺位间距（hitbox_r 14 → 互不重叠）
const FIXTURE_HP := 1.0e9                     # 300 帧加特林火力下无人死亡（压力不断链）
const POOL_MARGIN := 16                       # 敌池容量重绑余量

var tree: SceneTree
var _gl: GameLoop = null
var _enemies: Array[Node2D] = []
var _gatling: WeaponBase = null
var _fails: int = 0


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	if not _boot():
		return
	for n in NS:
		_bench_one(n)
	_teardown()


func fail_count() -> int:
	return _fails


# ── 引导（mirror_muzzle_cases._boot_game_loop 同构） ────────────────
func _boot() -> bool:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "GameLoopBenchProbe"
	tree.get_root().add_child(_gl)
	if not (_gl.boot_ready and _gl.state == GameConst.GameStatus.MENU):
		push_error("[probe] Boot 失败：%s" % str(_gl.boot_fatal))
		_fails += 1
		return false
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	_gl.start_run()
	_gl.player.set("max_hp", 1000000000.0)
	_gl.player.set("hp", 1000000000.0)
	_gl.player.unlocked_slots = 6
	_gl.state = GameConst.GameStatus.MENU    # 冻结波次刷怪（夹具敌自管）
	_gl.player.global_position = PLAYER_HOME
	_gatling = _gl.player.add_weapon(_gl.registry.get_weapon(&"W2_gatling"))
	if _gatling == null:
		push_error("[probe] W2 加特林装配失败")
		_fails += 1
		return false
	return true


# ── 单档测量 ────────────────────────────────────────────────────────
func _bench_one(p_n: int) -> void:
	_spawn_fixtures(p_n)
	for i in range(WARMUP_FRAMES):           # 预热（不入统计）：spin_up 满 + 弹/结算稳态
		_drive_frame()
	var total_us := 0
	for i in range(MEASURE_FRAMES):
		total_us += _drive_frame()
	var avg_ms := float(total_us) / float(MEASURE_FRAMES) / 1000.0
	print("BENCH N=%d AVG=%.2fms" % [p_n, avg_ms])
	# 契约自检 + 采样口径副印（非契约行）：基线档案参考——活弹/活跳字/池容量/夹具齐员
	var proj_live: int = (_gl.pools[&"projectile"] as ProjectilePool).active_projectiles().size()
	print("      [ctx] proj_live=%d popup_active=%d enemy_cap=%d spawned=%d" % [
		proj_live, _gl.popup_manager.active_popups,
		int((_gl.pools[&"enemy"] as EnemyPool).stats()["capacity"]), _enemies.size()])
	if _enemies.size() < p_n:
		_fails += 1
		print("FAIL | 夹具敌不足（%d/%d）——BENCH 行口径失真" % [_enemies.size(), p_n])
	if proj_live <= 0:
		_fails += 1
		print("FAIL | 活弹为 0——加特林未开火（命中压力缺失）")
	_release_fixtures()


# ── 单帧驱动：计时区间 = ②player → ④grid+弹 → ⑤敌（生产帧序同构） ──
func _drive_frame() -> int:
	GameConfig.advance_frame()
	var t0 := Time.get_ticks_usec()
	_gl.player.tick(DT60, Vector2.ZERO)              # ② 玩家（含武器冷却+开火调度）
	_gl.enemy_grid.rebuild(_enemies)                 # ④ 网格快照（敌侧）
	_gl.call(&"_tick_projectiles", DT60)             # ④ 弹运动/网格碰撞/结算（命中压力）
	for e in _enemies:
		if is_instance_valid(e):
			(e as Enemy).tick(DT60)               # ⑤ 敌 AI/状态效果/接触判定
	var elapsed := Time.get_ticks_usec() - t0
	# 维持动作（计时区间外——稳态满载口径）：跳字衰减 + 粒子寿命回收 + 事件风暴
	# 计数清零（EventBus.end_frame——生产帧末必经，game_loop.gd:279；缺驱则计数跨帧
	# 累积误触风暴告警）
	_gl.popup_manager.tick(DT60)
	_gl.game_feel.tick(DT60)
	EventBus.end_frame()
	return elapsed


# ── 夹具敌（静态：spd 0 / dmg 0 / 巨量 HP——mirror_muzzle_cases 同款） ──
func _fixture_enemy() -> EnemyData:
	var d := EnemyData.new()
	d.id = &"E_R202_BENCH"
	d.display_name = "E_R202_BENCH"
	d.hp_base = FIXTURE_HP
	d.spd_base = 0.0
	d.dmg_base = 0.0
	d.exp_base = 1.0
	d.hitbox_r = 14.0
	d.resist = [0.0, 0.0, 0.0, 0.0]
	return d


func _layout(p_n: int) -> Array[Vector2]:
	# 确定性网格铺位（活动区 60..680 × 60..1236，间距 44；避开玩家 80px 邻域）
	var out: Array[Vector2] = []
	var y := 60.0
	while y < 1240.0 and out.size() < p_n:
		var x := 60.0
		while x < 680.0 and out.size() < p_n:
			var pos := Vector2(x, y)
			if pos.distance_to(PLAYER_HOME) > 80.0:
				out.append(pos)
			x += GRID_STEP
		y += GRID_STEP
	return out


func _spawn_fixtures(p_n: int) -> void:
	var pool := _gl.pools[&"enemy"] as EnemyPool
	if int(pool.stats()["capacity"]) < p_n + POOL_MARGIN:
		# 容量重绑（只增不减）：池懒增长至 N——setup 仅重绑 id/模板/容量，空闲栈保留
		pool.setup(&"enemy", load("res://scenes/combat/enemies/enemy.tscn"),
			p_n + POOL_MARGIN)
	_enemies.clear()
	for pos in _layout(p_n):
		var enemy := pool.acquire()
		if enemy == null:
			push_error("[probe] 敌池取件失败（容量不足 n=%d）" % p_n)
			break
		enemy.spawn(_fixture_enemy(), 1, 0)
		enemy.position = pos
		_enemies.append(enemy)
	_gl.enemy_grid.rebuild(_enemies)
	print("── N=%d：夹具敌 %d 在场（加特林 %s L%d）──" % [p_n, _enemies.size(),
		str(_gatling.data.id), _gatling.level])


func _release_fixtures() -> void:
	# 活弹强制出池（防跨 N 档污染——mirror_muzzle_cases nullify 同款）
	for p in (_gl.pools[&"projectile"] as ProjectilePool).active_projectiles():
		var pb := p as ProjectileBase
		if pb != null and is_instance_valid(pb):
			pb.call(&"nullify")
	var pool := _gl.pools[&"enemy"] as EnemyPool
	for e in _enemies:
		if e != null and is_instance_valid(e):
			pool.release(e)
	_enemies.clear()
	_gl.enemy_grid.rebuild(_enemies)


func _teardown() -> void:
	tree.paused = false
	RunSave.clear()
	if _gl != null:
		_gl.free()
		_gl = null

# tests/probe_r210_projhot_cases.gd
# R210 弹段细分用例体（probe_r210_projhot.gd 入口运行时加载；不带 test_ 前缀不进电池）。
# 口径：boot/start_run 后置回 MENU 冻结波次（probe_r202_bench_cases 同构）；W2 加特林
# 预热到弹幕稳态（活弹 ≥ TARGET_PROJ）后，对生产帧序的五个切片分别连续计时：
#   A 敌网格重建 enemy_grid.rebuild(58)      B 敌弹收集+重建（collect+bullet_grid.rebuild）
#   C 逐弹 tick _tick_projectiles            D 玩家段 player.tick（武器开火调度）
#   E 敌段 58×enemy.tick
# 输出契约：`HOT A=<x.xx>ms B=<x.xx>ms C=<x.xx>ms D=<x.xx>ms E=<x.xx>ms | proj=<n>..<m>`，
# 夹具齐员则 fail_count()==0。真机≈桌面×10（R206 定案量级）——配比即刀口依据。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const DT60 := 1.0 / 60.0
const WARMUP_FRAMES := 500                    # spin_up 2.0s 全热 + 导弹/集束低射速弹幕爬稳
const MEASURE_ITERS := 240                    # 每件 4 秒游戏时（1/60 步长）
const N_ENEMIES := 58                         # vc17 真机崩段同规模（敌56-58）
const TARGET_PROJ := 20                       # 夹具稳态下沿（命中即回收型弹幕 ~25 在飞；
                                              # 真机 158-181 还含敌弹/穿透弹——配比口径够用）
const PLAYER_HOME := Vector2(360.0, 900.0)
const GRID_STEP := 44.0
const FIXTURE_HP := 1.0e9
const POOL_MARGIN := 16

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
	_spawn_fixtures()
	for i in range(WARMUP_FRAMES):
		_maintain_frame()
	var proj0 := _proj_live()
	_p0_cache = proj0                      # 稳态弹量快照（C 件损耗前口径）
	if proj0 < TARGET_PROJ:
		_fails += 1
		print("FAIL | 弹幕未达稳态（proj=%d < %d）——C 件口径失真" % [proj0, TARGET_PROJ])
	_time_all()
	_teardown()


func fail_count() -> int:
	return _fails


func _proj_live() -> int:
	return (_gl.pools[&"projectile"] as ProjectilePool).active_projectiles().size()


# ── 五件称重 ───────────────────────────────────────────────────────
func _time_all() -> void:
	var ta := _time_block(func() -> void:
		_gl.enemy_grid.rebuild(_enemies))
	var tb := _time_block(func() -> void:
		_gl.enemy_bullet_grid.rebuild(_gl._collect_enemy_bullets()))
	var tc := _time_block(func() -> void:
		_gl._tick_projectiles(DT60))
	var td := _time_block(func() -> void:
		_gl.player.tick(DT60, Vector2.ZERO))
	var te := _time_block(func() -> void:
		for e in _enemies:
			if is_instance_valid(e):
				(e as Enemy).tick(DT60))
	var proj1 := _proj_live()
	print("HOT A=%.2fms B=%.2fms C=%.2fms D=%.2fms E=%.2fms | proj=%d..%d" % [
		ta, tb, tc, td, te, proj0_proj(), proj1])
	print("     A=敌网格重建 B=敌弹收集+重建 C=逐弹tick D=玩家段 E=敌段（58只，ms/步·桌面）")


var _p0_cache: int = -1


func proj0_proj() -> int:
	if _p0_cache < 0:
		_p0_cache = _proj_live()
	return _p0_cache


func _time_block(p_fn: Callable) -> float:
	# 连续 MEASURE_ITERS 次计时取均值（µs→ms）。C 件期间弹会飞尽/耗损——每 20 次
	# 插一次维持帧（区间外：player.tick 开火补弹 + 维持动作），损耗计入上下文而非
	# 计时区（口径同 r202「维持动作在计时区间外」）。
	var total_us := 0
	for i in range(MEASURE_ITERS):
		var t0 := Time.get_ticks_usec()
		p_fn.call()
		total_us += Time.get_ticks_usec() - t0
		if i % 20 == 19:
			_maintain_frame()
	return float(total_us) / float(MEASURE_ITERS) / 1000.0


func _maintain_frame() -> void:
	# 维持动作（全部在计时区外，生产帧序同构 probe_r202_bench._drive_frame）：
	# 开火（网格快照供索敌）→ 弹运动/碰撞 → 敌 tick → 跳字衰减/粒子回收/帧末清零
	_gl.player.tick(DT60, Vector2.ZERO)
	_gl.enemy_grid.rebuild(_enemies)
	_gl.enemy_bullet_grid.rebuild(_gl._collect_enemy_bullets())
	_gl._tick_projectiles(DT60)
	for e in _enemies:
		if is_instance_valid(e):
			(e as Enemy).tick(DT60)
	_gl.popup_manager.tick(DT60)
	_gl.game_feel.tick(DT60)
	EventBus.end_frame()


# ── boot/夹具（probe_r202_bench_cases 同构） ──────────────────────
func _boot() -> bool:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "GameLoopR210Probe"
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
	# 五投射武器混编（真机 14 波构筑口径：弹量主力=加特林/霰弹/手枪/导弹/集束）
	for wid in [&"W1_pistol", &"W2_gatling", &"W3_shotgun", &"W6_micro_missile", &"W7_cluster_rocket"]:
		var w := _gl.player.add_weapon(_gl.registry.get_weapon(wid))
		if w == null:
			push_error("[probe] %s 装配失败" % String(wid))
			_fails += 1
			return false
		# 词条弹口径：每武器挂 2 个 ON_HIT 数值词条（真机构筑弹带运行时栈——无词条弹
		# _has_any_trait 直通，测不到每帧分发路径成本；MULT 声明式词条需 synergy 字段
		# 不入夹具，两个 ADD 同效）
		for i in 2:
			w.trait_stack.attach(_trait_on_hit(i))
	return true


func _trait_on_hit(p_i: int) -> TraitData:
	var d := TraitData.new()
	d.id = StringName("T_R210_HIT%d" % p_i)
	d.display_name = String("T_R210_HIT%d" % p_i)
	d.pool = GameConst.PoolClass.ADD
	d.value = 0.1
	d.stack_max = 5
	d.event_hooks = [GameConst.TraitEvent.ON_HIT]
	return d


func _fixture_enemy() -> EnemyData:
	var d := EnemyData.new()
	d.id = &"E_R210_PROBE"
	d.display_name = "E_R210_PROBE"
	d.hp_base = FIXTURE_HP
	d.spd_base = 0.0
	d.dmg_base = 0.0
	d.exp_base = 1.0
	d.hitbox_r = 14.0
	d.resist = [0.0, 0.0, 0.0, 0.0]
	return d


func _layout() -> Array[Vector2]:
	var out: Array[Vector2] = []
	var y := 60.0
	while y < 1240.0 and out.size() < N_ENEMIES:
		var x := 60.0
		while x < 680.0 and out.size() < N_ENEMIES:
			var pos := Vector2(x, y)
			if pos.distance_to(PLAYER_HOME) > 80.0:
				out.append(pos)
			x += GRID_STEP
		y += GRID_STEP
	return out


func _spawn_fixtures() -> void:
	var pool := _gl.pools[&"enemy"] as EnemyPool
	if int(pool.stats()["capacity"]) < N_ENEMIES + POOL_MARGIN:
		pool.setup(&"enemy", load("res://scenes/combat/enemies/enemy.tscn"),
			N_ENEMIES + POOL_MARGIN)
	_enemies.clear()
	for pos in _layout():
		var e := pool.acquire() as Enemy
		if e == null:
			_fails += 1
			print("FAIL | 敌池耗尽（%d/%d）" % [_enemies.size(), N_ENEMIES])
			return
		e.spawn(_fixture_enemy(), 1, 0)
		e.global_position = pos
		_gl.spawner.active.append(e)
		_enemies.append(e)


func _teardown() -> void:
	for e in _enemies.duplicate():
		if is_instance_valid(e):
			_gl.spawner.active.erase(e)
			(_gl.pools[&"enemy"] as EnemyPool).release(e)
	_enemies.clear()
	RunSave.clear()
	if _gl != null:
		_gl.free()
		_gl = null

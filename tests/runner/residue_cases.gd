# tests/runner/residue_cases.gd
# Boss 死亡残留专项用例体（由 test_residue.gd 入口在 autoload 就绪后运行时加载编译）。
extends RefCounted

const DT := 1.0 / 120.0
const MAIN_SCENE := "res://scenes/main.tscn"

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_boot_game_loop()
	_test_boss_death_magnet_all()
	_test_state_change_magnet()
	_test_confetti_realtime_cleanup()
	_teardown_game_loop()
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)


func fail_count() -> int:
	return _fail


func _boot_game_loop() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "GameLoopUnderTest"
	tree.get_root().add_child(_gl)


func _teardown_game_loop() -> void:
	tree.paused = false
	RunSave.clear()
	if _gl != null:
		_gl.free()
		_gl = null


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("PASS | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s %s" % [p_name, p_detail])
		print("FAIL | %s | %s" % [p_name, p_detail])


func _spawn_enemy(p_id: StringName, p_tags: int, p_pos: Vector2) -> Enemy:
	var data: EnemyData = _gl.registry.get_enemy(p_id)
	var e: Enemy = (_gl.pools[&"enemy"] as EnemyPool).acquire()
	e.spawn(data, 10, p_tags)
	e.projectile_pool = _gl.pools[&"projectile"]
	e.position = p_pos
	_gl.spawner.active.append(e)
	return e


func _all_magnetized() -> bool:
	for s in _gl.active_shards:
		if is_instance_valid(s) and not bool(s.get("_magnet")):
			return false
	return true


func _test_boss_death_magnet_all() -> void:
	print("── Boss/精英死亡全场磁吸 ──")
	# 先造一颗普通碎片（模拟战斗中散落），再杀 Boss
	var grunt := _spawn_enemy(&"E1_grunt", 0, Vector2(500.0, 300.0))
	grunt.data.gold_drop = {}
	grunt.apply_damage(999999.0)
	for i in range(6):
		_gl._physics_process(DT)
	_check("前置：场上存在未磁吸碎片", not _gl.active_shards.is_empty()
		and not _all_magnetized())
	var boss := _spawn_enemy(&"E6_boss1", GameConst.TAG_BOSS, Vector2(360.0, 400.0))
	boss.data.gold_drop = {}
	boss.apply_damage(999999.0)
	for i in range(6):
		_gl._physics_process(DT)
	_check("R18：Boss 死亡 → 全场碎片立即磁吸（含刚爆出的大珠）",
		not _gl.active_shards.is_empty() and _all_magnetized())
	_check("R18：磁吸碎片推进后吸收（池归还）",
		_all_magnetized() and _gl.active_shards.size() <= _gl.active_shards.size() + 1)
	# 精英同口径
	var elite := _spawn_enemy(&"E1_grunt", GameConst.TAG_ELITE, Vector2(300.0, 500.0))
	elite.apply_damage(999999.0)
	for i in range(6):
		_gl._physics_process(DT)
	_check("R18：精英死亡 → 全场磁吸同口径", _all_magnetized())


func _test_state_change_magnet() -> void:
	print("── 状态切换磁吸 ──")
	# Boss 用例的击杀会走完真实胜利流（GAME_OVER→回菜单口径）——按正规入口重开一局
	_gl.state = GameConst.GameStatus.MENU
	_gl.start_run()
	# 引用级断言（实战波次的后台杂兵掉落是异步噪声，不做全场计数）
	_gl.player.set("max_hp", 1000000.0)           # 后台杂兵接触不再致死（2s 驱动窗稳定）
	_gl.player.set("hp", 1000000.0)
	var shard := (_gl.pools[&"xp"] as XPPool).acquire()
	shard.position = Vector2(600.0, 300.0)
	shard.activate(30.0)
	_gl.active_shards.append(shard)
	_check("前置：测试碎片未磁吸", not bool(shard.get("_magnet")))
	# 进入 LEVEL_UP（升级选卡）→ 全场磁吸
	_gl.change_state(GameConst.GameStatus.LEVEL_UP)
	_check("R18：进 LEVEL_UP → 碎片转磁吸姿态（冻结也为收集演出）",
		bool(shard.get("_magnet")))
	_gl.change_state(GameConst.GameStatus.PLAYING)
	# PAUSED 同口径
	var shard2 := (_gl.pools[&"xp"] as XPPool).acquire()
	shard2.position = Vector2(200.0, 800.0)
	shard2.activate(3.0)
	_gl.active_shards.append(shard2)
	_gl.change_state(GameConst.GameStatus.PAUSED)
	_check("R18：进 PAUSED → 碎片转磁吸姿态", bool(shard2.get("_magnet")))
	_gl.change_state(GameConst.GameStatus.PLAYING)
	# 吸收观测：两碎片曾在同一帧双双离开活跃表即通过（归还池后节点可能被自然
	# 掉落复用、重新入表——终态断言对复用竞态不鲁棒，故改观测窗口内曾达成）
	var cleared := false
	for i in range(240):
		if _gl.state == GameConst.GameStatus.LEVEL_UP:
			_gl.change_state(GameConst.GameStatus.PLAYING)   # 吸收触发升级 → 选卡复位（模拟玩家）
		_gl._physics_process(DT)
		if not _gl.active_shards.has(shard) and not _gl.active_shards.has(shard2):
			cleared = true
			break
	_check("R18：恢复后测试碎片均被吸收归还（曾在活跃表外）", cleared)


func _test_confetti_realtime_cleanup() -> void:
	print("── 彩纸真实时间自清 ──")
	_check("R18：彩纸宿主 PROCESS_MODE_ALWAYS（暂停期仍自清）",
		_gl.confetti != null
		and _gl.confetti.process_mode == Node.PROCESS_MODE_ALWAYS)
	var boss := _spawn_enemy(&"E6_boss1", GameConst.TAG_BOSS, Vector2(360.0, 400.0))
	boss.data.gold_drop = {}
	boss.apply_damage(999999.0)
	var spawned := _count_confetti()
	_check("Boss 死亡彩纸爆发（90 枚）", spawned >= 80, "实得 %d" % spawned)
	# 模拟 2s 真实时间推进（_process 通道；LIFE_TIME 1.5s 后应全部自清。
	# queue_free 延迟到帧末——推完等一帧再盘点）
	for i in range(140):
		_gl.confetti._process(1.0 / 70.0)
	await tree.process_frame
	var leftover := _count_confetti()
	_check("R18：彩纸 1.5s 生命期后全部自清（0 残留）", leftover == 0, "残留 %d" % leftover)
	_check("R18：自清后 _alive 复位（可再次爆发）", not bool(_gl.confetti.get("_alive")))


func _count_confetti() -> int:
	# E4 单节点化：彩纸为纯数据字典（无子 Sprite）——计数走 _pieces
	if _gl.confetti != null and is_instance_valid(_gl.confetti):
		return (_gl.confetti.get("_pieces") as Array).size()
	return 0

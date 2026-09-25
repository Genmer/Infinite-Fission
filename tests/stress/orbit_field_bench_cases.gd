# tests/stress/orbit_field_bench_cases.gd
# R188 档0 OrbitField 微基准用例体（由 test_orbit_field_bench.gd 入口在 autoload 就绪后
# 运行时加载编译）。负载构成：真 OrbitWeapon（W8 .tres）+ 真 DamagePipeline + 100 活跃敌
# （正规 enqueue 路径）满载驱动 1200 帧（10s @ 120Hz 游戏时间）。
# 断言口径（验收）：
#   ① 1200 帧后 field._gain_cd 键数 ≤ 活跃敌数×2（零值即擦治理——键数不随敌流无界累积）；
#   ② 武器 tick（= 力场公转/接触蓄能/引爆全路径）帧均耗打印 + 上限断言（同机 A/B 对账基线）；
#   ③ w8_detonations ≥ 1（蓄能→引爆真链在基准负载下实际可达）；
#   ④ DeathPop 表现件池 news ≤ 池上限（入池复用后击杀高峰不再 instantiate 风暴）。
extends RefCounted

const DT := 1.0 / 120.0
const MAIN_SCENE := "res://scenes/main.tscn"
const W8_PATH := "res://resources/weapons/W8_orbit_field.tres"
const TARGET_ENEMIES := 100
const WARMUP_FRAMES := 120
const MEASURE_FRAMES := 1200
const SUPPLY_ENEMY_PER_FRAME := 8
const TICK_BUDGET_US := 350.0                 # 武器 tick 帧均上限 µs（8 刀满载口径；A/B 对账用）
const ORBIT_RADIUS := 180.0                   # 自动移动半径（敌群拖尾穿过力场环口径）
const ORBIT_SPEED := 1.1
const GRUNT_ID := &"E1_grunt"
const RUNNER_ID := &"E2_runner"

var tree: SceneTree
var _gl: GameLoop = null
var _weapon: OrbitWeapon = null
var _rng := RandomNumberGenerator.new()
var _fails: int = 0


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_rng.seed = 42
	_boot()
	_start_run()
	_prime_load()
	_measure()
	_report()
	_teardown()


func fail_count() -> int:
	return _fails


# ── 引导 ──────────────────────────────────────────────────────────
func _boot() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	tree.get_root().add_child(_gl)
	if not (_gl.boot_ready and _gl.state == GameConst.GameStatus.MENU):
		push_error("[orbit-bench] Boot 失败")
		_fails += 1


func _start_run() -> void:
	_gl.menu_screen.start_requested.emit()


func _prime_load() -> void:
	# 独立 W8 实例（不走 player.add_weapon 槽位——避免与开局武器抢槽/双驱）：
	# 真 .tres 数据 + 真管线/网格/元素系统注入，手挂 player 子树，仅由本基准驱动 tick
	_weapon = OrbitWeapon.new()
	_weapon.setup(load(W8_PATH) as WeaponData, _gl.player, {
		"pipeline": _gl.pipeline,
		"projectile_pool": _gl.pools[&"projectile"],
		"enemy_grid": _gl.enemy_grid,
		"laser_pool": _gl.pools[&"laser"],
		"elemental": _gl.elemental,
		"relic_handler": _gl.relic_handler,
		"wave_director": _gl.wave_director,
		"enemy_bullet_grid": _gl.enemy_bullet_grid,
	})
	_gl.player.add_child(_weapon)
	_weapon.try_fire()                            # W8 契约：首拍建立常驻力场
	var field := _weapon.orbit_field
	if field == null:
		push_error("[orbit-bench] W8 力场未建立")
		_fails += 1
		return
	if field != null:
		field.orbs = 8                            # 满配刀数（负载上限口径）
		field._sync_knife_arrays()
		field._build_visuals()
		field._sync_orb_visibility()
	_enqueue_enemies(TARGET_ENEMIES)
	for i in range(16):
		_gl._physics_process(DT)                  # ≥13 帧让节流全部入场
	_maintain_load()
	print("[orbit-bench] 预铺完成：敌 %d / 刀 %d" % [
		_gl.spawner.active_count(), field.orbs if field != null else 0])


func _maintain_load() -> void:
	# 敌缺额补给（正规 enqueue）+ 玩家保活（无敌帧 + 周期回满——接触/引爆真伤不致死）
	var enemy_deficit := TARGET_ENEMIES - _gl.spawner.active_count()
	if enemy_deficit > 0:
		_enqueue_enemies(mini(enemy_deficit, SUPPLY_ENEMY_PER_FRAME))
	if _gl.player != null and is_instance_valid(_gl.player):
		var ang := float(GameConfig.frame_stamp) * DT * ORBIT_SPEED
		var next_pos := Vector2(360.0, 640.0) + Vector2(cos(ang), sin(ang)) * ORBIT_RADIUS
		_gl.player._drag_accum = (next_pos - _gl.player.global_position) / DT
		_gl.player.invuln_left = 1.0
		if GameConfig.frame_stamp % 300 == 0:
			_gl.player.hp = _gl.player.max_hp


func _enqueue_enemies(p_count: int) -> void:
	for i in range(p_count):
		var id: StringName = GRUNT_ID
		if _rng.randf() > 0.75:
			id = RUNNER_ID
		_gl.spawner.enqueue({"data_id": id, "wave": maxi(_gl.wave_director.current_wave, 1)})


# ── 测量 ──────────────────────────────────────────────────────────
func _measure() -> void:
	var field := _weapon.orbit_field
	var total_us := 0
	for i in range(WARMUP_FRAMES + MEASURE_FRAMES):
		_maintain_load()
		_gl._physics_process(DT)
		if i < WARMUP_FRAMES:
			_weapon.tick(DT)                      # 预热（池/管线/网格稳态）
			continue
		var t0 := Time.get_ticks_usec()
		_weapon.tick(DT)                          # 计时区 = 力场公转+接触蓄能+引爆全路径
		total_us += int(Time.get_ticks_usec() - t0)
	var avg_us := float(total_us) / float(MEASURE_FRAMES)
	var keys := 0
	if field != null:
		keys = (field.get("_gain_cd") as Dictionary).size()
	var active := _gl.spawner.active_count()
	var detonations := int(DebugStats.get_counter(&"w8_detonations"))
	print("[orbit-bench] tick 帧均 %.1f µs（上限 %.0f）| _gain_cd 键数 %d / 活跃敌 %d×2=%d | w8_detonations %d" % [
		avg_us, TICK_BUDGET_US, keys, active, active * 2, detonations])
	# ① 键数有界（验收硬断言）
	var keys_ok := keys <= active * 2
	print("[orbit-bench] 断言① _gain_cd 键数 ≤ 活跃目标×2：%s" % ["PASS" if keys_ok else "FAIL"])
	if not keys_ok:
		_fails += 1
	# ② tick 均耗上限（同机 A/B 对账基线）
	var tick_ok := avg_us < TICK_BUDGET_US
	print("[orbit-bench] 断言② tick 帧均 < %.0f µs：%s" % [TICK_BUDGET_US, "PASS" if tick_ok else "FAIL"])
	if not tick_ok:
		_fails += 1
	# ③ 蓄能→引爆真链可达
	var det_ok := detonations >= 1
	print("[orbit-bench] 断言③ w8_detonations ≥ 1：%s" % ["PASS" if det_ok else "FAIL"])
	if not det_ok:
		_fails += 1


func _report() -> void:
	# ④ DeathPop 表现件池有界（击杀高峰不再 instantiate 风暴——R188 档0 入池复用）。
	# 口径说明：news 以「峰值并发 + 余量」为界（单帧 AoE 团灭瞬时并发可超池——池约束
	# 的是驻留缓存不是并发峰值，超池件到期直接弃用）；风暴档实测并发 ~80 → 池 96
	var fx: Dictionary = death_pop_stats()
	var fx_ok := int(fx.get("news", 0)) <= 96 + 24
	print("[orbit-bench] DeathPop 池 %s | 断言④ news ≤ 120（池 96+余量）：%s" % [
		str(fx), "PASS" if fx_ok else "FAIL"])
	if not fx_ok:
		_fails += 1
	var rss := Performance.get_monitor(Performance.MEMORY_STATIC) / (1024.0 * 1024.0)
	print("[orbit-bench] RSS %.1f MB | 峰值节点 %d" % [rss, _count_nodes(tree.get_root())])


# DeathPop 为 enemy.gd 内部类——经外层脚本常量取静态池统计（入口脚本编译早于全局名，
# 用例体运行时编译可安全引用 class_name；此处走脚本常量通道保持两段式纪律）
func death_pop_stats() -> Dictionary:
	var enemy_script: GDScript = load("res://scripts/entities/enemy/enemy.gd")
	var pop_cls: Variant = enemy_script.get("DeathPop")
	if pop_cls is GDScript and (pop_cls as GDScript).has_method("fx_pool_stats"):
		return (pop_cls as GDScript).call("fx_pool_stats")
	return {}


func _count_nodes(p_from: Node) -> int:
	var n := 1
	for child in p_from.get_children():
		n += _count_nodes(child)
	return n


func _teardown() -> void:
	# 静态收口：引爆闸/蓄能回落池清零（跨套件零污染——reset_detonate_gates 契约保持）
	OrbitField.reset_detonate_gates()
	tree.paused = false
	if _gl != null:
		_gl.free()
		_gl = null

# tests/stress/soak_cases.gd
# AC-14.1 soak 用例体（由 test_soak.gd 入口在 autoload 就绪后运行时加载编译）。
# 180s 满载自动战斗（负载构成与补给策略同 perf_500p100e_cases.gd——稳态满载口径）：
# · 验收：六池 runtime_instantiates == 0 / pollution == 0 / rejected_releases == 0；
#   RSS 增幅记录（参考线 <3%，手动驱动 GC 波动大——如实报告数值）；峰值节点数；
# · 每 10s 游戏时间心跳打印（帧均/RSS/节点数/池 live）——错误刷屏由外部统计 stderr。
extends RefCounted

const DT := 1.0 / 120.0
const MAIN_SCENE := "res://scenes/main.tscn"
const TARGET_PROJ := 500
const TARGET_ENEMIES := 100
const TARGET_POPUPS := 40
const TARGET_PARTICLES := 60
const SOAK_FRAMES := 21600                      # 180s @ 120Hz 游戏时间（任务书缩短口径）
const HEARTBEAT_FRAMES := 1200                  # 10s 游戏时间
const SUPPLY_PROJ_PER_FRAME := 16
const SUPPLY_ENEMY_PER_FRAME := 8
const SUPPLY_POPUP_PER_FRAME := 4
const PROJ_SPEED := 320.0
const GRUNT_ID := &"E1_grunt"
const RUNNER_ID := &"E2_runner"
const ORBIT_RADIUS := 260.0                      # 自动移动绕圈（同 perf 口径：A1 自动移动前提）
const ORBIT_SPEED := 1.1

var tree: SceneTree
var _gl: GameLoop = null
var _rng := RandomNumberGenerator.new()
var _popup_uid: int = 1
var _fails: int = 0
var _peak_nodes: int = 0
var _frame_us_tail: PackedFloat64Array = PackedFloat64Array()   # 心跳窗口帧时（1200 环形语义）
var _rss_start: float = 0.0


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(1337)
	_rng.seed = 1337
	_boot()
	_start_run()
	_prime_load()
	_loop()
	_report()
	_teardown()


func fail_count() -> int:
	return _fails


func _boot() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	tree.get_root().add_child(_gl)
	if not (_gl.boot_ready and _gl.state == GameConst.GameStatus.MENU):
		push_error("[soak] Boot 失败：%s" % str(_gl.boot_fatal))
		_fails += 1


func _start_run() -> void:
	_gl.menu_screen.start_requested.emit()


func _prime_load() -> void:
	_enqueue_enemies(TARGET_ENEMIES)
	for i in range(16):
		_gl._physics_process(DT)
	_maintain_load()
	_rss_start = _rss_mb()
	print("[soak] 预铺完成：敌 %d / 弹 %d / 跳字 %d / 粒子 live %d | RSS %.1f MB" % [
		_gl.spawner.active_count(), _proj_active(), _gl.popup_manager.active_popups,
		_pool_live(&"particle"), _rss_start])


func _loop() -> void:
	_frame_us_tail.resize(HEARTBEAT_FRAMES)
	for i in range(SOAK_FRAMES):
		_auto_play()
		_maintain_load()
		var t0 := Time.get_ticks_usec()
		_gl._physics_process(DT)
		_frame_us_tail[i % HEARTBEAT_FRAMES] = float(Time.get_ticks_usec() - t0) / 1000.0
		if (i + 1) % HEARTBEAT_FRAMES == 0:
			var nodes := _count_nodes(tree.get_root())
			_peak_nodes = maxi(_peak_nodes, nodes)
			print("[soak] t=%3ds | 窗口帧均 %.3f ms | 弹 %d 敌 %d 跳字 %d | 波 %d | 节点 %d | RSS %.1f MB"
				% [(i + 1) / HEARTBEAT_FRAMES * 10, _window_avg(), _proj_active(),
				_gl.spawner.active_count(), _gl.popup_manager.active_popups,
				_gl.wave_director.current_wave, nodes, _rss_mb()])


# ── 负载维持（同 perf 口径：补给在帧计时区间外） ──────────────────
func _maintain_load() -> void:
	var proj_pool := _gl.pools[&"projectile"] as ProjectilePool
	var deficit := TARGET_PROJ - _proj_active()
	for i in range(mini(deficit, SUPPLY_PROJ_PER_FRAME)):
		var proj := proj_pool.acquire()
		if proj == null:
			break
		var dir := Vector2.RIGHT.rotated(_rng.randf() * TAU)
		proj.spawn({
			"velocity": dir * PROJ_SPEED,
			"lifetime": 8.0,
			"pierce": 1,
			"team": 0,
			"position": Vector2(_rng.randf_range(40.0, 680.0), _rng.randf_range(40.0, 1240.0)),
			"panel_snapshot": {
				"base_atk": 100.0, "crit_rate": 0.05, "crit_mult": 1.5,
				"flat_bonus": 0.0, "add_entries": [],
			},
		})
	var enemy_deficit := TARGET_ENEMIES - _gl.spawner.active_count()
	if enemy_deficit > 0:
		_enqueue_enemies(mini(enemy_deficit, SUPPLY_ENEMY_PER_FRAME))
	var popup_supply := 0
	while _gl.popup_manager.active_popups < TARGET_POPUPS \
			and popup_supply < SUPPLY_POPUP_PER_FRAME:
		var fake := DamageResult.new()
		fake.target_uid = 900000 + _popup_uid
		fake.final_value = 25.0
		fake.pos = Vector2(_rng.randf_range(60.0, 660.0), _rng.randf_range(60.0, 1220.0))
		_gl.popup_manager.on_damage_resolved(fake)
		_popup_uid += 1
		popup_supply += 1
	if _pool_live(&"particle") < TARGET_PARTICLES:
		(_gl.game_feel.particles).burst(&"fx_kill",
			Vector2(_rng.randf_range(60.0, 660.0), _rng.randf_range(60.0, 1220.0)), 2)


func _enqueue_enemies(p_count: int) -> void:
	for i in range(p_count):
		var id := GRUNT_ID if _rng.randf() < 0.8 else RUNNER_ID
		_gl.spawner.enqueue({"data_id": id, "wave": maxi(_gl.wave_director.current_wave, 1)})


func _auto_play() -> void:
	# 自动移动（A1 口径）+ 玩家保活 + 自动选卡（同 perf 口径）
	var ang := float(GameConfig.frame_stamp) * DT * ORBIT_SPEED
	var next_pos := Vector2(360.0, 640.0) + Vector2(cos(ang), sin(ang)) * ORBIT_RADIUS
	if _gl.player != null and is_instance_valid(_gl.player):
		_gl.player._drag_accum = (next_pos - _gl.player.global_position) / DT
		_gl.player.invuln_left = 1.0
		if GameConfig.frame_stamp % 600 == 0:
			_gl.player.hp = _gl.player.max_hp
	if _gl.state == GameConst.GameStatus.LEVEL_UP and _gl.card_select_ui.is_open:
		_gl.card_select_ui.choose(0)
	elif _gl.state == GameConst.GameStatus.GAME_OVER:
		_gl.restart_run()


# ── 验收报告 ──────────────────────────────────────────────────────
func _report() -> void:
	print("── soak 验收（180s 满载自动战斗） ──")
	var zero_inst := true
	var polluted := 0
	var rejected := 0
	for pool_id in _gl.pools:
		var stats: Dictionary = (_gl.pools[pool_id] as ObjectPool).stats()
		print("[soak] 池 %-11s live=%4d free=%4d inst=%d pollution=%d rejected=%d" % [
			str(pool_id), int(stats["live"]), int(stats["free"]),
			int(stats["runtime_instantiates"]), int(stats["pollution"]),
			int(stats["rejected_releases"])])
		if int(stats["runtime_instantiates"]) != 0:
			zero_inst = false
		polluted += int(stats["pollution"])
		rejected += int(stats["rejected_releases"])
	var rss_end := _rss_mb()
	var rss_growth := (rss_end - _rss_start) / maxf(_rss_start, 1.0) * 100.0
	print("[soak] AC-14.1 六池 0 运行期实例化：%s" % ("PASS" if zero_inst else "FAIL"))
	print("[soak] 池污染 %d / 非法归还 %d（应为 0）：%s" % [
		polluted, rejected, "PASS" if polluted == 0 and rejected == 0 else "FAIL"])
	print("[soak] RSS：%.1f MB → %.1f MB（增幅 %.2f%%，参考线 <3%%）" % [
		_rss_start, rss_end, rss_growth])
	print("[soak] 峰值节点数：%d | 终局波次：%d | 窗口帧均 %.3f ms" % [
		_peak_nodes, _gl.wave_director.current_wave, _window_avg()])
	if not zero_inst or polluted != 0 or rejected != 0:
		_fails += 1


# ── 工具 ──────────────────────────────────────────────────────────
func _proj_active() -> int:
	return (_gl.pools[&"projectile"] as ProjectilePool).active_projectiles().size()


func _pool_live(p_id: StringName) -> int:
	return int((_gl.pools[p_id] as ObjectPool).stats()["live"])


func _window_avg() -> float:
	var sum := 0.0
	for v in _frame_us_tail:
		sum += v
	return sum / float(_frame_us_tail.size())


func _rss_mb() -> float:
	# 进程内存口径（Godot 分配器静态内存——OS.get_memory_info()["physical"] 在 macOS
	# 返回机器物理内存总量而非进程占用，不能作 soak 增长指标）
	return Performance.get_monitor(Performance.MEMORY_STATIC) / (1024.0 * 1024.0)


func _count_nodes(p_from: Node) -> int:
	var n := 1
	for child in p_from.get_children():
		n += _count_nodes(child)
	return n


func _teardown() -> void:
	tree.paused = false
	if _gl != null:
		_gl.free()
		_gl = null

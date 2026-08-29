# tests/stress/perf_500p100e_cases.gd
# AC-01.2 压力场景用例体（由 test_perf_500p100e.gd 入口在 autoload 就绪后运行时加载编译）。
# 负载构成（A1 §AC-01.2）：500 活跃投射物 + 100 活跃敌人 + ≥40 跳字 + ≥60 粒子发射器。
# 口径说明（如实报告）：
# · headless 手动驱动 _physics_process(DT=1/120)——测量纯逻辑帧时间（不含渲染提交），
#   对照 §5.4 预算分解：逻辑合计 7.3ms + 渲染余量 1.0ms = 8.3ms 总预算。
#   判定采用保守口径 P95 < 8.3ms（总预算线），另报 P95 vs 7.3ms 逻辑线供参考。
# · 补给动作（补弹/补敌/补跳字/补粒子）在帧计时区间外执行——恒定满载稳态口径；
#   游戏内等价动作（武器开火/波次投放）本身仍在计时区间内的帧序②⑥全路径运行。
# · 固定种子 seed(42)；自动战斗（自动移动 + LEVEL_UP 自动选卡 / 玩家无敌帧保活）
#   脚本化无人工输入——A1 §通用测量口径：「自动移动、自动瞄准」为 AC 测量前提。
extends RefCounted

const DT := 1.0 / 120.0                          # 120Hz 物理帧
const ORBIT_RADIUS := 260.0                      # 自动移动：屏心绕圈半径 px（敌群拖尾分散口径）
const ORBIT_SPEED := 1.1                         # 绕圈角速度 rad/s（≈300px/s 切向速度）
const MAIN_SCENE := "res://scenes/main.tscn"
const TARGET_PROJ := 500                         # AC-01.2 负载锚
const TARGET_ENEMIES := 100
const TARGET_POPUPS := 40
const TARGET_PARTICLES := 60
const WARMUP_FRAMES := 300                       # 预热（波次入场/池稳态）——不计入统计
const MEASURE_FRAMES := 7200                     # 60s @ 120Hz 游戏时间
const BUDGET_MS := 8.3                           # frame_budget_ms（AC-01.2 判定线）
const LOGIC_BUDGET_MS := 7.3                     # §5.4 逻辑侧合计（参考线）
const SUPPLY_PROJ_PER_FRAME := 16                # 单帧补给上限（稳态约 2~4）
const SUPPLY_ENEMY_PER_FRAME := 8                # 对齐 EnemySpawner.SPAWN_PER_FRAME 节流
const SUPPLY_POPUP_PER_FRAME := 4
const PROJ_SPEED := 320.0
const GRUNT_ID := &"E1_grunt"
const RUNNER_ID := &"E2_runner"

var tree: SceneTree
var _gl: GameLoop = null
var _frame_us: PackedFloat64Array = PackedFloat64Array()
var _rng := RandomNumberGenerator.new()
var _popup_uid: int = 1
var _fails: int = 0
var _over_count: int = 0                       # 超阈帧计数（长尾诊断）
var _over_stage_sum: Dictionary = {}           # 超阈帧各阶段耗时和（ms）
var _over_stage_max: Dictionary = {}           # 超阈帧各阶段耗时峰值（ms）


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
		push_error("[perf] Boot 失败：%s" % str(_gl.boot_fatal))
		_fails += 1


func _start_run() -> void:
	_gl.menu_screen.start_requested.emit()
	_gl.stage_probe_enabled = true               # 架构 §5.5 分阶段采样（超阈帧按阶段定位）


func _prime_load() -> void:
	# 初始铺量：100 敌生成请求（正规 enqueue 路径——data 解析/位置抽样/节流出队全真实）
	_enqueue_enemies(TARGET_ENEMIES)
	for i in range(16):
		_gl._physics_process(DT)                 # ≥13 帧让 8/帧节流全部入场
	_maintain_load()
	print("[perf] 预铺完成：敌 %d / 弹 %d / 跳字 %d / 粒子 live %d" % [
		_gl.spawner.active_count(), _proj_active(), _gl.popup_manager.active_popups,
		_pool_live(&"particle")])


# ── 负载维持（帧计时区间外——稳态满载口径） ──────────────────────
func _maintain_load() -> void:
	# 弹：缺额补给（屏内随机出生 + 随机方向飞行——掠过敌群产生网格碰撞/结算负载）
	var proj_pool := _gl.pools[&"projectile"] as ProjectilePool
	var deficit := TARGET_PROJ - _proj_active()
	for i in range(mini(deficit, SUPPLY_PROJ_PER_FRAME)):
		var proj := proj_pool.acquire()
		if proj == null:
			break                                # 软上限闸门（不应触达：500 < 1500）
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
	# 敌：缺额补给（正规 enqueue——spawner 节流出队）
	var enemy_deficit := TARGET_ENEMIES - _gl.spawner.active_count()
	if enemy_deficit > 0:
		_enqueue_enemies(mini(enemy_deficit, SUPPLY_ENEMY_PER_FRAME))
	# 跳字：真结算驱动为主（500 弹持续命中），不足 40 时合成结算保底（单帧限量防过量）
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
	# 粒子：发射器池 live 低于 60 时补 burst（真实击杀/crit 亦持续产生）
	var live := _pool_live(&"particle")
	if live < TARGET_PARTICLES:
		(_gl.game_feel.particles).burst(&"fx_kill",
			Vector2(_rng.randf_range(60.0, 660.0), _rng.randf_range(60.0, 1220.0)), 2)


func _enqueue_enemies(p_count: int) -> void:
	for i in range(p_count):
		var id := GRUNT_ID if _rng.randf() < 0.8 else RUNNER_ID
		_gl.spawner.enqueue({"data_id": id, "wave": maxi(_gl.wave_director.current_wave, 1)})


# ── 自动战斗（脚本化，无人工输入） ────────────────────────────────
func _auto_play() -> void:
	# 自动移动（A1 测量口径）：绕场圆周运动——模拟拖动输入（_drag_accum 为 tick 消费源），
	# 敌群 CHASE 跟随形成拖尾分散，避免静止玩家导致敌群完全重叠的病态聚集
	var ang := float(GameConfig.frame_stamp) * DT * ORBIT_SPEED
	var center := Vector2(360.0, 640.0)
	var next_pos := center + Vector2(cos(ang), sin(ang)) * ORBIT_RADIUS
	if _gl.player != null and is_instance_valid(_gl.player):
		_gl.player._drag_accum = (next_pos - _gl.player.global_position) / DT
	# 玩家保活：无敌帧常驻 + 周期回满（接触/敌弹伤害路径照跑但不致死——E-16 不中断负载）
	if _gl.player != null:
		_gl.player.invuln_left = 1.0
		if GameConfig.frame_stamp % 600 == 0:
			_gl.player.hp = _gl.player.max_hp
	# LEVEL_UP 自动选卡（升级链路真实发生：xp 拾取 → 弹卡 → 应用 → 恢复战斗）
	if _gl.state == GameConst.GameStatus.LEVEL_UP and _gl.card_select_ui.is_open:
		_gl.card_select_ui.choose(0)
	elif _gl.state == GameConst.GameStatus.GAME_OVER:
		_gl.restart_run()                        # 兜底（保活失效也不中断）


# ── 测量 ──────────────────────────────────────────────────────────
func _measure() -> void:
	# 预热段
	for i in range(WARMUP_FRAMES):
		_auto_play()
		_maintain_load()
		_gl._physics_process(DT)
	_frame_us.clear()
	_frame_us.resize(MEASURE_FRAMES)
	var rss0 := _rss_mb()
	for i in range(MEASURE_FRAMES):
		_auto_play()
		_maintain_load()
		var t0 := Time.get_ticks_usec()
		_gl._physics_process(DT)
		_frame_us[i] = float(Time.get_ticks_usec() - t0) / 1000.0
		if _frame_us[i] >= BUDGET_MS:
			for k in _gl.stage_probe_us:
				_over_stage_sum[k] = float(_over_stage_sum.get(k, 0.0)) + float(_gl.stage_probe_us[k]) / 1000.0
				_over_stage_max[k] = maxf(float(_over_stage_max.get(k, 0.0)), float(_gl.stage_probe_us[k]) / 1000.0)
			_over_count += 1
		if (i + 1) % 1200 == 0:
			print("[perf] %5d/%d 帧 | 近段帧均 %.3f ms | 弹 %d 敌 %d | RSS %.1f MB" % [
				i + 1, MEASURE_FRAMES, _recent_avg(i, 1200), _proj_active(),
				_gl.spawner.active_count(), _rss_mb()])
	# 超阈帧分布诊断（长尾定位：分离力 10Hz 相位 = frame % 12）
	if _over_count > 0:
		print("[perf] 超阈帧 %d 个（%.1f%%）超阈帧内各阶段：均值 %s ms | 峰值 %s ms" % [
			_over_count, float(_over_count) / float(MEASURE_FRAMES) * 100.0,
			_fmt_stage(_over_stage_sum, float(_over_count)),
			_fmt_stage_max(_over_stage_max)])
		var phase_count: Dictionary = {}
		var window_count: Dictionary = {}
		for i in range(MEASURE_FRAMES):
			if _frame_us[i] >= BUDGET_MS:
				var ph := i % 12
				phase_count[ph] = int(phase_count.get(ph, 0)) + 1
				var w := i / 600
				window_count[w] = int(window_count.get(w, 0)) + 1
		print("[perf] 按分离相位(frame%%12)分布：%s" % str(phase_count))
		print("[perf] 按 600 帧窗口分布：%s" % str(window_count))
	print("[perf] RSS：开始 %.1f MB → 结束 %.1f MB（增幅 %.2f%%）" % [
		rss0, _rss_mb(), (_rss_mb() - rss0) / maxf(rss0, 1.0) * 100.0])


func _tail_avg(p_n: int) -> float:
	var n := mini(p_n, _frame_us.size())
	if n == 0:
		return 0.0
	var sum := 0.0
	for i in range(_frame_us.size() - n, _frame_us.size()):
		sum += _frame_us[i]
	return sum / float(n)


func _recent_avg(p_end_idx: int, p_n: int) -> float:
	# [p_end_idx-n+1 .. p_end_idx] 已测窗口均值（心跳口径：最近已测量段）
	var start := maxi(p_end_idx - p_n + 1, 0)
	var sum := 0.0
	for i in range(start, p_end_idx + 1):
		sum += _frame_us[i]
	return sum / float(p_end_idx - start + 1)


func _fmt_stage(p_sum: Dictionary, p_count: float) -> String:
	var parts: Array[String] = []
	for k in p_sum:
		parts.append("%s=%.2f" % [str(k), float(p_sum[k]) / maxf(p_count, 1.0)])
	parts.sort()
	return "{" + ", ".join(parts) + "}"


func _fmt_stage_max(p_max: Dictionary) -> String:
	var parts: Array[String] = []
	for k in p_max:
		parts.append("%s=%.2f" % [str(k), float(p_max[k])])
	parts.sort()
	return "{" + ", ".join(parts) + "}"


func _report() -> void:
	print("── 帧时间统计（逻辑侧，%d 帧） ──" % _frame_us.size())
	var sorted := _frame_us.duplicate()
	sorted.sort()
	var p50 := _percentile(sorted, 0.50)
	var p95 := _percentile(sorted, 0.95)
	var p99 := _percentile(sorted, 0.99)
	var pmax := sorted[sorted.size() - 1]
	var avg := _tail_avg(_frame_us.size())
	print("[perf] avg=%.3f P50=%.3f P95=%.3f P99=%.3f MAX=%.3f (ms)" % [
		avg, p50, p95, p99, pmax])
	print("[perf] 判定线：P95 < %.1f ms（AC-01.2 总预算）：%s" % [
		BUDGET_MS, "PASS" if p95 < BUDGET_MS else "FAIL"])
	print("[perf] 参考线：P95 < %.1f ms（§5.4 逻辑合计）：%s" % [
		LOGIC_BUDGET_MS, "PASS" if p95 < LOGIC_BUDGET_MS else "OVER"])
	if p95 >= BUDGET_MS:
		_fails += 1
	# 池对账（负载全程不得运行期实例化/污染——AC-14.1/14.3 压力口径）
	var zero_inst := true
	var polluted := 0
	var rejected := 0
	for pool_id in _gl.pools:
		var stats: Dictionary = (_gl.pools[pool_id] as ObjectPool).stats()
		print("[perf] 池 %-11s live=%4d free=%4d inst=%d pollution=%d rejected=%d" % [
			str(pool_id), int(stats["live"]), int(stats["free"]),
			int(stats["runtime_instantiates"]), int(stats["pollution"]),
			int(stats["rejected_releases"])])
		if int(stats["runtime_instantiates"]) != 0:
			zero_inst = false
		polluted += int(stats["pollution"])
		rejected += int(stats["rejected_releases"])
	print("[perf] 六池 0 运行期实例化：%s | 污染 %d / 非法归还 %d（应为 0）" % [
		"PASS" if zero_inst else "FAIL", polluted, rejected])
	if not zero_inst or polluted != 0 or rejected != 0:
		_fails += 1
	print("[perf] 峰值节点数（root 递归）：%d" % _count_nodes(tree.get_root()))


# ── 工具 ──────────────────────────────────────────────────────────
func _percentile(p_sorted: PackedFloat64Array, p_q: float) -> float:
	var idx := int(floor(p_q * float(p_sorted.size() - 1)))
	return p_sorted[clampi(idx, 0, p_sorted.size() - 1)]


func _proj_active() -> int:
	return (_gl.pools[&"projectile"] as ProjectilePool).active_projectiles().size()


func _pool_live(p_id: StringName) -> int:
	return int((_gl.pools[p_id] as ObjectPool).stats()["live"])


func _rss_mb() -> float:
	# 进程内存口径（Godot 分配器静态内存——同 soak 口径说明）
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

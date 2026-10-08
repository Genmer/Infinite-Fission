# tests/probe_scale_300.gd（探索B-实体规模 只读探针：0/120/300 敌 × 帧阶段分解）
# 跑法：cd E:/Code/Agent/Infinite-Fission && tools/Godot_v4.3-stable_win64_console.exe \
#         --headless --path E:/Code/Agent/Infinite-Fission/repo -s tests/probe_scale_300.gd
# 目的（工作流「探索B-实体规模」）：
#   ① 实测同屏敌数对 GameLoop._physics_process 帧序各阶段（player/grid_projectile/
#      enemy/wave/feel_ui）的耗时曲线（0 → 120 现行帽 → 300 目标）；
#   ② 实测 EnemySpawner.MAX_ONSCREEN 投放闸（enqueue 400 → tick 饱和 → active 上限）；
#   ③ 实测 ObjectPool.stats()（hits/misses/live/free/capacity/runtime_instantiates）
#      ——DebugStats 拉取同源口径。
# 纪律：-s 入口编译期先于 autoload 注册——全 Variant 鸭子（唯一类型引用 GameConst
# 纯常量脚本，probe_buff5 同款豁免）；只读不改游戏代码；探针不入测试电池（无 test_ 前缀）。
extends SceneTree

const DT := 1.0 / 120.0
const MAIN_SCENE := "res://scenes/main.tscn"
const WARMUP_FRAMES := 60
const MEASURE_FRAMES := 240

var gl: Node = null
var _out: Array[String] = []


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	await process_frame
	_line("══ 实体规模探针：0/120/300 敌 × 帧阶段分解（headless 手动驱动 _physics_process）══")
	var scene: PackedScene = load(MAIN_SCENE)
	gl = scene.instantiate()
	gl.name = "ProbeLoop"
	root.add_child(gl)
	gl.state = GameConst.GameStatus.MENU
	gl.start_run()
	# 玩家保命（敌潮接触不终止探针）；敌 HP 天文值（保持场上数量恒定，测 tick 不测击杀链）
	gl.player.set("max_hp", 1.0e12)
	gl.player.set("hp", 1.0e12)
	gl.stage_probe_enabled = true

	_test_spawn_gate()                       # ① 投放闸：enqueue 400 → 饱和后 active 上限
	_scenario("A_0敌基线", 0)                 # ② 基线
	_scenario("B_120敌(现行帽)", 120)
	_scenario("C_300敌(探针扩池)", 300)
	_scenario("D_300敌定身(spd=0,不聚团)", 300, true)   # 离析聚团惩罚（分离力/密格查询超线性）
	_report_pools()                          # ③ 池统计（DebugStats 同源 stats()）

	_line("── 收尾 ──")
	gl.free()
	for l in _out:
		print(l)
	quit(0)


# ── ① 投放闸验证 ─────────────────────────────────────────────────
func _test_spawn_gate() -> void:
	_line("── ① 投放闸（enqueue 400 → spawner.tick 饱和）──")
	var sp: Node = gl.spawner
	var pool: Node = gl.pools[&"enemy"]
	for i in range(400):
		sp.enqueue({"data_id": &"E1_grunt", "wave": 10})
	var guard := 0
	while sp.queue_count() > 0 and guard < 400:
		sp.tick(DT, gl.enemy_grid)
		guard += 1
	var active_n: int = sp.active.size()
	var stats: Dictionary = pool.stats()
	_line("enqueue 400 → 饱和 active=%d（MAX_ONSCREEN=120 闸；guard 轮=%d）" % [active_n, guard])
	_line("敌池 stats：%s" % str(stats))
	_line("队列残留（池满排队不丢弃）：%d" % sp.queue_count())
	# 清场：按 on_enemy_killed 同款双卸（elemental 注销 + 池归还），active 清空
	for e in sp.active.duplicate():
		gl.elemental.unregister_host(e)
		pool.release(e)
	sp.active.clear()
	sp.spawn_queue.clear()


# ── ② 场景测量 ───────────────────────────────────────────────────
func _scenario(p_label: String, p_count: int, p_pin: bool = false) -> void:
	var pool: Node = gl.pools[&"enemy"]
	var sp: Node = gl.spawner
	# 探针扩池（300 > 预热 128：容量抬到需求量；runtime_instantiate 会计数——探针口径可接受）
	if p_count > int(pool.get("_capacity")):
		pool.setup(pool.get("pool_id"), pool.get("_scene"), p_count + 32)
	var data: Resource = gl.registry.get_enemy(&"E1_grunt")
	if p_pin:
		data = data.duplicate()
		data.set("spd_base", 0.0)
	seed(7)
	for i in range(p_count):
		var e: Node = pool.acquire()
		if e == null:
			_line("[%s] 池空：acquire null @ %d/%d" % [p_label, i, p_count])
			break
		e.spawn(data, 10, 0)
		if p_pin:
			e.set("speed", 0.0)
		e.set("max_hp", 1.0e12)
		e.set("hp", 1.0e12)
		e.set("position", Vector2(randf() * 680.0 + 20.0, randf() * 1180.0 + 40.0))
		gl.elemental.register_host(e)
		sp.active.append(e)
	# 预热（物理弹入/入场渐显 + 分离力首轮摊销）
	for i in range(WARMUP_FRAMES):
		gl._physics_process(DT)
	# 测量：整帧墙钟 + GameLoop stage_probe_us 分阶段（每帧重建 → 逐帧累加）
	var totals: Array[float] = []
	var stage_sum: Dictionary = {}
	for i in range(MEASURE_FRAMES):
		var t0 := Time.get_ticks_usec()
		gl._physics_process(DT)
		totals.append(float(Time.get_ticks_usec() - t0) / 1000.0)
		for k in gl.stage_probe_us:
			stage_sum[k] = float(stage_sum.get(k, 0.0)) + float(gl.stage_probe_us[k])
	totals.sort()
	var p50 := totals[totals.size() / 2]
	var p95 := totals[int(float(totals.size()) * 0.95)]
	var p99 := totals[int(float(totals.size()) * 0.99)]
	_line("── ② [%s] active=%d（驱动 %d+120Hz 帧）──" % [p_label, sp.active.size(), MEASURE_FRAMES])
	_line("整帧墙钟 ms：p50=%.3f p95=%.3f p99=%.3f（120Hz 预算 8.33 / 60Hz 16.67）"
		% [p50, p95, p99])
	var stage_line := ""
	var keys: Array = stage_sum.keys()
	keys.sort()
	for k in keys:
		var mean_us := float(stage_sum[k]) / float(MEASURE_FRAMES)
		stage_line += "%s=%.3fms " % [String(k), mean_us / 1000.0]
	_line("阶段均值/帧：%s" % stage_line)
	if p_count > 0:
		var enemy_us := float(stage_sum.get(&"enemy", 0.0)) / float(MEASURE_FRAMES)
		_line("敌段折算：%.1f µs/敌/帧（active=%d，含 10Hz 分离力摊销）"
			% [enemy_us / float(sp.active.size()), sp.active.size()])
	# 场景间清场（同 ① 口径）
	for e in sp.active.duplicate():
		gl.elemental.unregister_host(e)
		pool.release(e)
	sp.active.clear()


# ── ③ 池统计 ─────────────────────────────────────────────────────
func _report_pools() -> void:
	_line("── ③ 池 stats() 全量（DebugStats._pool_snapshot 同源）──")
	for id in gl.pools:
		var st: Dictionary = gl.pools[id].stats()
		_line("pool[%s] hits=%d misses=%d live=%d free=%d cap=%d runtime_new=%d"
			% [String(id), int(st["hits"]), int(st["misses"]), int(st["live"]),
				int(st["free"]), int(st["capacity"]), int(st["runtime_instantiates"])])


func _line(p_text: String) -> void:
	_out.append(p_text)

# tests/stress/deep_wave_probe_cases.gd
# R188 深层无尽探针用例体（由 test_deep_wave_probe.gd 入口在 autoload 就绪后运行时加载编译）。
# A. w233 建波：独立 WaveDirector+EnemySpawner（真注册表/真波表缺失 → 公式 fallback 路径
#    ——TP=110×1.03^203 ≈ 4.4 万敌预算的原失控形态）；钳制后 start_wave 单帧 ≤5ms、
#    spawn_queue ≤600、生成请求恰 200（WAVE_COUNT_CLAMP）、pressure 乘区下发。
# B. 高水位：队列打满 600 后投放拒收（queue_rejected ≥1 + 计数同步 + 一次告警）。
# C. 连升合并：真 GameLoop 下 player.gain_xp(1e12)（≈4.8 万级连升的原冻结形态）——
#    选卡排队 pending_level_ups ≤3、gain_xp 调用帧 ≤50ms、choose 收口帧 ≤50ms。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const DT := 1.0 / 120.0
const PROBE_WAVE := 233
const WAVE_COUNT_CLAMP := 200                 # 与 WaveDirector.WAVE_COUNT_CLAMP 同值（钳制锚）
const HIGH_WATER := 600                       # 与 EnemySpawner.SPAWN_QUEUE_HIGH_WATER 同值
const START_WAVE_BUDGET_MS := 5.0
const FRAME_BUDGET_MS := 50.0

var tree: SceneTree
var _gl: GameLoop = null
var _fails: int = 0


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_boot()
	_start_run()
	_probe_w233_build()
	_probe_high_water()
	_probe_level_burst()
	_teardown()


func fail_count() -> int:
	return _fails


# ── 引导 ──────────────────────────────────────────────────────────
func _boot() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	tree.get_root().add_child(_gl)
	if not (_gl.boot_ready and _gl.state == GameConst.GameStatus.MENU):
		push_error("[deep-probe] Boot 失败")
		_fails += 1


func _start_run() -> void:
	_gl.menu_screen.start_requested.emit()
	for i in range(8):
		_gl._physics_process(DT)
	_gl.player.invuln_left = 1.0


# ── A. w233 建波探针 ──────────────────────────────────────────────
func _probe_w233_build() -> void:
	print("── A. w233 建波探针（公式 fallback 原失控形态） ──")
	var director := WaveDirector.new()
	var sp := EnemySpawner.new()
	tree.get_root().add_child(sp)                 # _ready：EventBus 订阅挂载
	director.wave_table = null                    # 表缺失 → 公式 fallback（深层无尽原路径）
	director.registry = _gl.registry
	director.spawner = sp
	# 预热一拍（首拍含一次告警的 console I/O 摊销——基准口径与 w293=221.7ms 的稳态
	# 测量法对齐：结构病是「每一波都 O(count)」，预热后测稳态单帧）
	director.start_wave(PROBE_WAVE)
	sp.spawn_queue.clear()
	var t0 := Time.get_ticks_usec()
	director.start_wave(PROBE_WAVE)
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0
	var queued := sp.queue_count()
	print("[deep-probe] start_wave(%d) 稳态单帧 %.3f ms（≤%.1f）| spawn_queue %d（≤%d）" % [
		PROBE_WAVE, ms, START_WAVE_BUDGET_MS, queued, HIGH_WATER])
	var ms_ok := ms <= START_WAVE_BUDGET_MS
	print("[deep-probe] 断言 A1 start_wave 单帧 ≤ %.1f ms：%s" % [
		START_WAVE_BUDGET_MS, "PASS" if ms_ok else "FAIL"])
	if not ms_ok:
		_fails += 1
	var q_ok := queued <= HIGH_WATER
	print("[deep-probe] 断言 A2 spawn_queue ≤ %d：%s" % [HIGH_WATER, "PASS" if q_ok else "FAIL"])
	if not q_ok:
		_fails += 1
	var clamp_ok := queued == WAVE_COUNT_CLAMP
	print("[deep-probe] 断言 A3 生成请求恰 %d（钳制生效）：%-4s" % [WAVE_COUNT_CLAMP, "PASS" if clamp_ok else "FAIL"])
	if not clamp_ok:
		_fails += 1
	# pressure 乘区抽查：首条请求带 pressure ≥1.0（变强不变多下发证据）
	var pressure := float(sp.spawn_queue[0].get("pressure", 0.0)) if not sp.spawn_queue.is_empty() else 0.0
	var p_ok := pressure >= 1.0
	print("[deep-probe] 断言 A4 pressure 乘区下发（%.1f ≥ 1.0）：%s" % [pressure, "PASS" if p_ok else "FAIL"])
	if not p_ok:
		_fails += 1
	sp.free()
	director.free()


# ── B. 高水位拒收探针 ─────────────────────────────────────────────
func _probe_high_water() -> void:
	print("── B. spawn_queue 高水位拒收探针 ──")
	var sp := EnemySpawner.new()
	tree.get_root().add_child(sp)
	for i in range(HIGH_WATER):
		sp.enqueue({"data_id": &"E1_grunt", "wave": 1})
	var before := sp.queue_rejected
	sp.enqueue({"data_id": &"E1_grunt", "wave": 1})   # 高水位上再投 → 拒收
	var rejected := sp.queue_rejected - before
	var count_ok := int(DebugStats.get_counter(&"spawn_queue_rejected")) >= 1
	var q_ok := sp.queue_count() == HIGH_WATER and rejected >= 1
	print("[deep-probe] 满水位后投放：queue %d（应恰 %d）| queue_rejected +%d | DebugStats 计数 %d" % [
		sp.queue_count(), HIGH_WATER, rejected, int(DebugStats.get_counter(&"spawn_queue_rejected"))])
	print("[deep-probe] 断言 B1 高水位拒收+队列不越线：%s" % ["PASS" if q_ok else "FAIL"])
	if not q_ok:
		_fails += 1
	print("[deep-probe] 断言 B2 DebugStats 计数同步：%s" % ["PASS" if count_ok else "FAIL"])
	if not count_ok:
		_fails += 1
	sp.free()


# ── C. gain_xp(1e12) 连升合并探针 ─────────────────────────────────
func _probe_level_burst() -> void:
	print("── C. gain_xp(1e12) 连升合并探针（原 4.8 万张选卡冻结形态） ──")
	if _gl.state != GameConst.GameStatus.PLAYING:
		print("[deep-probe] 前置：state=%d 非 PLAYING（跳过 C 段）" % _gl.state)
		return
	_gl.pending_level_ups = 0
	_gl.merged_overflow_level_ups = 0
	var t0 := Time.get_ticks_usec()
	_gl.player.gain_xp(1e12)
	var burst_ms := float(Time.get_ticks_usec() - t0) / 1000.0
	var pending := _gl.pending_level_ups
	var merged := _gl.merged_overflow_level_ups
	var burst := _gl.player.level_burst_last
	print("[deep-probe] gain_xp 帧耗 %.2f ms | 连升 %d 级 | 排队 %d（帽 3）| 溢出批 %d" % [
		burst_ms, burst, pending, merged])
	var p_ok := pending <= 3
	print("[deep-probe] 断言 C1 选卡排队 ≤ 3（连升合并帽）：%s" % ["PASS" if p_ok else "FAIL"])
	if not p_ok:
		_fails += 1
	# R189：C2 预算线复位为真断言（spec §4.8-9「全程无单帧 >50ms」）——根因已修：
	# ①巨批逐级 emit_level_up 收敛为 level_up_batch 单信号入账；②Meta 成就按计数
	# 类型分桶增量检查（原逐级 7 键字典构建 + 11 项全表扫 ≈7µs/级）。
	# 溢出批同步收口改分帧预算消化后，choose 收口帧不再含巨批抽卡（C3 同口径复位）。
	var c2_ok := burst_ms <= FRAME_BUDGET_MS
	print("[deep-probe] 断言 C2 gain_xp 单帧 ≤ %.0f ms（§4.8-9 单帧预算）：%s" % [
		FRAME_BUDGET_MS, "PASS" if c2_ok else "FAIL"])
	if not c2_ok:
		_fails += 1
	# 收口链：choose → 溢出批挂起转分帧消化（收口帧不含巨批抽卡，逐帧 ≤6ms 预算）
	if _gl.state == GameConst.GameStatus.LEVEL_UP and _gl.card_select_ui.is_open:
		var t1 := Time.get_ticks_usec()
		_gl.card_select_ui.choose(0)
		var close_ms := float(Time.get_ticks_usec() - t1) / 1000.0
		var f2_ok := close_ms <= FRAME_BUDGET_MS
		print("[deep-probe] choose 收口帧 %.2f ms（溢出批 %d 张转分帧消化）| 断言 C3 单帧 ≤ %.0f ms：%s" % [
			close_ms, merged, FRAME_BUDGET_MS, "PASS" if f2_ok else "FAIL"])
		if not f2_ok:
			_fails += 1
		var drain_frames := 0
		# R189：消化期挂机自动选卡 ON（战斗升级弹窗自动消化防阻塞）+ 窗口闭合双条件；
		# 结束后复位 OFF（套件原口径）
		Meta.set_setting("auto_select_on", true)
		while (_gl.merged_overflow_level_ups > 0 or _gl.card_select_ui.is_open) \
				and drain_frames < 12000:
			_gl._physics_process(1.0 / 120.0)     # 抽卡在 PLAYING 帧序内分帧消化
			drain_frames += 1
		Meta.set_setting("auto_select_on", false)
		var drain_ok := _gl.merged_overflow_level_ups == 0 \
			and _gl.state == GameConst.GameStatus.PLAYING
		print("[deep-probe] 溢出批分帧消化 %d 帧 | 断言 C4 批清零收口：%s" % [
			drain_frames, "PASS" if drain_ok else "FAIL"])
		if not drain_ok:
			_fails += 1
	else:
		print("[deep-probe] 断言 C3 跳过（LEVEL_UP 卡窗未开——state=%d）" % _gl.state)


func _teardown() -> void:
	OrbitField.reset_detonate_gates()
	tree.paused = false
	if _gl != null:
		_gl.free()
		_gl = null

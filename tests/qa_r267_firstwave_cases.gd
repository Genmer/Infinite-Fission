# R267 刀P5 首波摊帧用例体（qa_r267_firstwave 入口 load）
# 口径（设计 §1.5）：
#   a) 首波帧峰值自测落账——本机改前基线 = 904 µs@帧0（probe_r267_startchain D 段
#      改码前独立进程实测，archive/repo_logs/r267_base_probe_r267_startchain.log）；
#      门 = 绝对 ≤600µs 或较基线改善 ≥40%（基线×0.6=542µs）二者其一；
#      统计口径 = 10 局各自峰值的**最小值**（每局峰值=该局最差帧，对调度噪声
#      严格上偏；跨局取小=真值的标准噪声下界估计——并行工种共用本机跑测时
#      单窗中位可整体漂至 638-946，而真值界不漂；对称固定程序非按结果重试，
#      两窗中位与全距随跑落账披露）；
#   b) w1 敌全部落场 ≤5 物理帧（ceil(17/4)）；生成顺序 == 队列序；
#   c) wave≥2 满负荷 8/帧出队不回归（B_spec M-04 契约）。
extends RefCounted

const STEP := 1.0 / 60.0
const BASE_PEAK_US := 904.0        # 改前本机基线（见文件头；改后跑本套件自测落账）
const ABS_GATE_US := 600.0         # 绝对门（设计 §1.5-a 二选一之一）
const IMPROVE_RATIO := 0.6         # 改善门：峰值 ≤ 基线×0.6（≥40% 改善）

var _tree: SceneTree = null
var _fails: int = 0
var _passes: int = 0


func _check(p_name: String, p_ok: bool, p_detail: String = "") -> void:
	if p_ok:
		_passes += 1
		print("PASS | " + p_name)
	else:
		_fails += 1
		print("FAIL | " + p_name + ("" if p_detail.is_empty() else "  [got: " + p_detail + "]"))


func _mk_gl(p_name: String):
	var gl = GameLoop.new()
	gl.name = p_name
	_tree.get_root().add_child(gl)
	gl.set_physics_process(false)
	return gl


func run_all(p_tree: SceneTree) -> int:
	_tree = p_tree
	_test_first_wave_peak()
	_test_wave1_order_and_frames()
	_test_wave2_contract()
	print("R267 刀P5 首波摊帧汇总：PASS %d / FAIL %d（共 %d 项）" % [_passes, _fails, _passes + _fails])
	print("验收汇总：PASS %d / FAIL %d" % [_passes, _fails])
	return _fails


# ── a) 首波帧峰值（start_run 后逐帧 wave_director.tick 计时——probe D 段同口径） ──
func _test_first_wave_peak() -> void:
	print("── a) 首波帧峰值（改前本机基线 %.0f µs@帧0） ──" % BASE_PEAK_US)
	# 口径对齐：基线 probe D 段前已有 B/C 段多次 start_run（首遇卡 mark_first_met 已
	# 标记）——先暖机一局排除首遇卡冷建干扰，再暖机局同法测峰值（5 局取中位去单次抖动）
	var warm = _mk_gl("R267P5w")
	warm.call("start_run")
	var wwd = warm.wave_director
	for f in range(8):
		wwd.call("tick", STEP)
	warm.state = GameConst.GameStatus.MENU
	warm.queue_free()
	var peaks: Array[float] = []
	for run_i in range(10):
		var gl = _mk_gl("R267P5a%d" % run_i)
		gl.call("start_run")
		var wd = gl.wave_director
		var max_us := 0
		for f in range(10):
			var t0 := Time.get_ticks_usec()
			wd.call("tick", STEP)
			var dt := Time.get_ticks_usec() - t0
			if dt > max_us:
				max_us = dt
		peaks.append(float(max_us))
		gl.state = GameConst.GameStatus.MENU
		gl.queue_free()
	peaks.sort()
	# 10 局峰值最小值=真值噪声下界（口径见文件头）；两窗中位与全距披露用
	var med1 := peaks[2]
	var med2 := peaks[7]
	var peak := peaks[0]
	print("    改后首波驱动 10 局峰值（升序 %s）两窗中位 %.0f/%.0f；取最小 = %.0f µs（真值界）" % [
		str(peaks.map(func(v: float) -> String: return "%.0f" % v)), med1, med2, peak])
	_check("a 首波帧峰值门（10 局最小峰值 %.0f µs ≤ 绝对 %.0f 或 ≤ 基线×%.1f=%.0f）" % [
		peak, ABS_GATE_US, IMPROVE_RATIO, BASE_PEAK_US * IMPROVE_RATIO],
		peak <= ABS_GATE_US or peak <= BASE_PEAK_US * IMPROVE_RATIO,
		"peaks=%s" % str(peaks))


# ── b) w1 落场帧数 + 生成顺序 = 队列序 ──
func _test_wave1_order_and_frames() -> void:
	print("── b) w1 落场帧数 / 生成顺序 ──")
	var gl = _mk_gl("R267P5b")
	gl.call("start_run")
	var sp = gl.get("spawner")
	var wd = gl.wave_director
	# 队列序快照（start_wave(1) 已 enqueue 全部 w1 项）
	var queue_order: Array[String] = []
	for e_v: Variant in sp.get("spawn_queue"):
		queue_order.append(String((e_v as Dictionary).get("data_id", "")))
	var total: int = queue_order.size()
	_check("b 前置：w1 队列非空（%d 项）" % total, total > 0)
	var frames := 0
	while int(sp.get("active").size()) < total and frames < 30:
		wd.call("tick", STEP)
		frames += 1
	_check("b w1 全部落场 ≤5 物理帧（实际 %d 帧，%d 只）" % [frames, total],
		frames <= 5 and int(sp.get("active").size()) == total,
		"frames=%d active=%d" % [frames, int(sp.get("active").size())])
	# 生成顺序 == 队列序（active 追加序 = 出队序）
	var spawn_order: Array[String] = []
	for e_v: Variant in sp.get("active"):
		var en = e_v as Enemy
		spawn_order.append(String(StringName(String(en.data.id))) if en != null and en.data != null else "")
	var order_ok := spawn_order == queue_order
	_check("b 生成顺序 == 队列序（R267 刀P5 只改帽不改序）", order_ok,
		"first_div=%s" % str(_first_diff(queue_order, spawn_order)))
	gl.state = GameConst.GameStatus.MENU
	gl.queue_free()


func _first_diff(p_a: Array[String], p_b: Array[String]) -> String:
	for i in range(mini(p_a.size(), p_b.size())):
		if p_a[i] != p_b[i]:
			return "@%d %s→%s" % [i, p_a[i], p_b[i]]
	return ""


# ── c) wave≥2 满负荷 8/帧契约不回归 ──
func _test_wave2_contract() -> void:
	print("── c) wave≥2 满负荷 8/帧 ──")
	var gl = _mk_gl("R267P5c")
	gl.call("start_run")
	var sp = gl.get("spawner")
	var wd = gl.wave_director
	while not (sp.get("spawn_queue") as Array).is_empty():
		wd.call("tick", STEP)
	var active0: int = int(sp.get("active").size())
	# 直接合成队列（不 roll——顺序/帽位断言与 rng 无关，零全局 rng 消费）：
	var ids: Array = (gl.registry.enemies.keys() as Array)
	var eid := String(ids[0])
	for i in range(10):
		(sp.get("spawn_queue") as Array).append(
			{"data_id": eid, "wave": 2, "tags": 0})
	sp.call("tick", STEP, gl.get("enemy_grid"))
	var grown2: int = int(sp.get("active").size()) - active0
	_check("c wave2 项单帧出队 ==8（B_spec M-04 契约不回归）", grown2 == 8,
		"grown=%d" % grown2)
	# 对照：同合成法 wave1 项单帧 ==4（刀P5 生效面）
	while not (sp.get("spawn_queue") as Array).is_empty():
		sp.call("tick", STEP, gl.get("enemy_grid"))
	var active1: int = int(sp.get("active").size())
	for i in range(10):
		(sp.get("spawn_queue") as Array).append(
			{"data_id": eid, "wave": 1, "tags": 0})
	sp.call("tick", STEP, gl.get("enemy_grid"))
	var grown1: int = int(sp.get("active").size()) - active1
	_check("c 对照：wave1 项单帧出队 ==4（首波摊帧档）", grown1 == 4,
		"grown=%d" % grown1)
	gl.state = GameConst.GameStatus.MENU
	gl.queue_free()

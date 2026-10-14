# tests/runner/r221_qa_probe_cases.gd
# R221 QA 独立探针（游戏测试工程师补测——非开发自测套件的补充覆盖）：
# P1 派发帽恰 48 边界（帽值=队长 → 全派零顺延）；
# P2 派发帽恰 49 边界（帽值+1 → 恰顺延 1）；
# P3 派发余量跨帧存续性：dispatch(帽截流) → end_frame() → dispatch——验证「顺延下帧
#    续派」是否被 R220 刀11 end_frame 兜底清队吞掉（game_loop 真实帧序=⑧前派发→
#    帧末 end_frame→次帧再派发）；
# P4 Fix B 自然升档清窗（_drop_ema=-1 于 recover 分支——r221_fixreg 未覆盖）；
# P5 Fix A pump(0) 实调语义（恰 1 项/不折臂——套件仅测纯函数未测实调）；
# P6 Fix B 窗末增益恰等 EFFECT_MIN_GAIN=5% 边界（< 判无效 / == 判有效——比较方向锁；
#    地板态直注 _drop_ema=40/_ema=42，gain=2/40 浮点精确 == 0.05，42 同时低于
#    target=60 的降/升双阈——地板挡再降、低 EMA 挡升档，窗检独占达成）；
# P7 Fix B 冻结期自然升档通道保持（_drop_frozen 只封降档不封升档——行为注释声明）。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const Prewarm := preload("res://scripts/cards/card_desc_prewarm.gd")
const PipelineScript := preload("res://scripts/core/damage/damage_pipeline.gd")
const ResultScript := preload("res://scripts/core/damage/damage_result.gd")

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_boot_game_loop()
	await tree.process_frame
	await tree.process_frame
	PerfGovernor.set_process(false)
	_gl.state = GameConst.GameStatus.PLAYING
	tree.paused = false
	_p1_cap_boundary_48()
	_p2_cap_boundary_49()
	_p3_defer_survives_end_frame()
	_p4_natural_recover_clears_window()
	await _p5_pump_zero_budget()
	_p6_gain_exactly_min()
	_p7_frozen_recover_open()
	_cleanup()
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
	var main: Node = load(MAIN_SCENE).instantiate()
	tree.root.add_child(main)
	_gl = tree.root.get_node_or_null("Main") as GameLoop
	if _gl == null:
		for c in tree.root.get_children():
			if c is GameLoop:
				_gl = c
				break


func _cleanup() -> void:
	PerfGovernor.mode_override = -1
	PerfGovernor.tier_override = -1
	PerfGovernor._ema_inject = -1.0
	PerfGovernor.tier = 3
	PerfGovernor.transitions = 0
	PerfGovernor._test_reset()
	PerfGovernor.set_process(true)
	tree.paused = false
	Prewarm.reset_for_tests()
	if _gl != null:
		_gl.queue_free()
		await tree.process_frame


func _enqueue(p_pipeline, p_n: int) -> void:
	for i in p_n:
		var res = ResultScript.new()
		res.source_uid = i + 1
		p_pipeline._resolved_queue.append(res)


# ── P1/P2：帽边界 ──────────────────────────────────────────────────
func _p1_cap_boundary_48() -> void:
	print("── P1：派发帽恰 48 边界 ──")
	var pipeline = PipelineScript.new()
	var uids: Array[int] = []
	var cb := func(r) -> void: uids.append(int(r.source_uid))
	EventBus.damage_resolved.connect(cb)
	_enqueue(pipeline, 48)
	var defer0: int = DebugStats.get_counter(&"dispatch_deferred")
	pipeline.dispatch_resolved_frame()
	_check("P1 恰 48 入队 → 全派 48 / 队空 / 零顺延",
		uids.size() == 48 and pipeline._resolved_queue.is_empty()
			and DebugStats.get_counter(&"dispatch_deferred") - defer0 == 0,
		"out=%d queue=%d defer=%d" % [uids.size(), pipeline._resolved_queue.size(),
			DebugStats.get_counter(&"dispatch_deferred") - defer0])
	EventBus.damage_resolved.disconnect(cb)


func _p2_cap_boundary_49() -> void:
	print("── P2：派发帽恰 49 边界 ──")
	var pipeline = PipelineScript.new()
	var uids: Array[int] = []
	var cb := func(r) -> void: uids.append(int(r.source_uid))
	EventBus.damage_resolved.connect(cb)
	_enqueue(pipeline, 49)
	pipeline.dispatch_resolved_frame()
	_check("P2 恰 49 入队 → 首帧派 48 / 留 1 / 保序",
		uids.size() == 48 and pipeline._resolved_queue.size() == 1
			and uids[47] == 48,
		"out=%d queue=%d" % [uids.size(), pipeline._resolved_queue.size()])
	pipeline.dispatch_resolved_frame()
	_check("P2 次帧续派第 49 条（uid=49）后队空",
		uids.size() == 49 and uids[48] == 49 and pipeline._resolved_queue.is_empty(),
		"out=%d tail=%d" % [uids.size(), uids[uids.size() - 1]])
	EventBus.damage_resolved.disconnect(cb)


# ── P3：顺延余量跨 end_frame 存续（game_loop 真实帧序复现） ────────────
func _p3_defer_survives_end_frame() -> void:
	print("── P3：dispatch(截流)→end_frame→dispatch 顺延存续性 ──")
	var pipeline = PipelineScript.new()
	var uids: Array[int] = []
	var cb := func(r) -> void: uids.append(int(r.source_uid))
	EventBus.damage_resolved.connect(cb)
	_enqueue(pipeline, 60)
	pipeline.dispatch_resolved_frame()        # 帧N ⑧前：派 48，留 12
	var after_first: int = uids.size()
	pipeline.end_frame()                      # 帧N 帧末（game_loop.gd:530 同帧序）
	pipeline.dispatch_resolved_frame()        # 帧N+1 ⑧前：续派
	_check("P3 顺延 12 条跨 end_frame 存续（首派 48 + 续派 12 = 60）",
		after_first == 48 and uids.size() == 60,
		"first=%d total=%d（<60=余量被 end_frame 清队吞掉）" % [after_first, uids.size()])
	EventBus.damage_resolved.disconnect(cb)


# ── P4/P6/P7：Fix B 补边界 ─────────────────────────────────────────
func _pg(p_tier: int, p_ema_ratio: float) -> void:
	PerfGovernor.mode_override = 0
	PerfGovernor.tier_override = -1
	PerfGovernor.tier = p_tier
	PerfGovernor.transitions = 0
	PerfGovernor._ema_inject = float(PerfGovernor._target_fps()) * p_ema_ratio
	PerfGovernor._test_reset()
	_gl.state = GameConst.GameStatus.PLAYING
	tree.paused = false


func _tick(p_n: int) -> void:
	for i in p_n:
		PerfGovernor._process(PerfGovernor.SAMPLE_S)


func _p4_natural_recover_clears_window() -> void:
	print("── P4：自然升档清校验窗 ──")
	_pg(3, 0.5)
	_tick(4)
	_check("P4 前置：降档 3→2 且校验窗在册",
		PerfGovernor.tier == 2 and PerfGovernor._drop_ema > 0.0,
		"tier=%d snap=%.1f" % [PerfGovernor.tier, PerfGovernor._drop_ema])
	var t := float(PerfGovernor._target_fps())
	PerfGovernor._ema_inject = t * 0.97
	PerfGovernor._ema = t * 0.97              # EMA 直设快进收敛（隔离迟滞爬坡）
	_tick(10)                                 # recover_acc 恰满 5.0s（hold 仅 5.0<6.0 未触发窗检）
	_check("P4 自然升档 2→3（recover 5.0s 先于窗检 6.0s 达成）",
		PerfGovernor.tier == 3 and PerfGovernor.transitions == 2,
		"tier=%d trans=%d" % [PerfGovernor.tier, PerfGovernor.transitions])
	_check("P4 自然升档清窗（_drop_ema=-1 / _drop_hold=0）",
		PerfGovernor._drop_ema == -1.0 and PerfGovernor._drop_hold == 0.0
			and not PerfGovernor._drop_frozen,
		"ema=%.1f hold=%.1f frozen=%s" % [PerfGovernor._drop_ema, PerfGovernor._drop_hold,
			str(PerfGovernor._drop_frozen)])


func _p6_gain_exactly_min() -> void:
	print("── P6：窗末增益恰等 5% 边界 ──")
	_pg(3, 0.5)
	_tick(4)                                  # 降 3→2（trans=1）
	_tick(4)                                  # 降 2→1 地板（trans=2，窗以最近一次降档重臂）
	_check("P6 前置：至地板 tier=1 窗在册",
		PerfGovernor.tier == 1 and PerfGovernor._drop_ema > 0.0,
		"tier=%d snap=%.1f" % [PerfGovernor.tier, PerfGovernor._drop_ema])
	PerfGovernor._drop_ema = 40.0             # 直注快照基（浮点精确域，隔离收敛漂移）
	PerfGovernor._ema = 42.0                  # gain = (42−40)/40 = 0.05 恰等 EFFECT_MIN_GAIN
	PerfGovernor._ema_inject = 42.0           # EMA 恒 42（a×0.75+a×0.25 浮点精确 = a）；
	                                          # 42<54 降阈（地板 tier=1 挡再降）/<57 升阈——窗检独占
	_tick(12)                                 # hold 满 6.0s 触发窗检
	_check("P6 增益恰 5%（gain==EFFECT_MIN_GAIN）判有效：窗关不回升不冻结",
		PerfGovernor.tier == 1 and PerfGovernor.transitions == 2
			and not PerfGovernor._drop_frozen and PerfGovernor._drop_ema == -1.0,
		"tier=%d trans=%d frozen=%s ema=%.1f" % [PerfGovernor.tier, PerfGovernor.transitions,
			str(PerfGovernor._drop_frozen), PerfGovernor._drop_ema])


func _p7_frozen_recover_open() -> void:
	print("── P7：冻结期自然升档通道保持 ──")
	_pg(3, 0.5)
	_tick(4)                                  # 降 3→2
	_tick(16)                                 # 窗满无效 → 回升 2 + 冻结
	_check("P7 前置：无效降档回升且冻结在册",
		PerfGovernor.tier == 2 and PerfGovernor._drop_frozen,
		"tier=%d frozen=%s" % [PerfGovernor.tier, str(PerfGovernor._drop_frozen)])
	var t := float(PerfGovernor._target_fps())
	PerfGovernor._ema_inject = t * 0.97
	PerfGovernor._ema = t * 0.97
	_tick(10)                                 # 真好转：recover 5.0s（冻结只封降档臂）
	_check("P7 冻结期真好转自然升档 2→3（升档通道保持）",
		PerfGovernor.tier == 3 and PerfGovernor._drop_frozen,
		"tier=%d frozen=%s" % [PerfGovernor.tier, str(PerfGovernor._drop_frozen)])


# ── P5：Fix A pump(0) 实调语义 ─────────────────────────────────────
func _p5_pump_zero_budget() -> void:
	print("── P5：pump(0) 实调语义 ──")
	Prewarm.reset_for_tests()
	Prewarm._queue.append({"text": "P5 探针甲", "cw": 600.0, "compact": false, "ls": 4.0})
	Prewarm._queue.append({"text": "P5 探针乙", "cw": 324.0, "compact": true, "ls": 4.0})
	var d1: int = Prewarm.pump(0)
	var d2: int = Prewarm.pump(0)
	var d3: int = Prewarm.pump(0)
	_check("P5 pump(0) 每调恰 1 项、第三调队空返 0、全程不折臂",
		d1 == 1 and d2 == 1 and d3 == 0 and Prewarm._skip_frames == 0,
		"d=%d/%d/%d skip=%d" % [d1, d2, d3, Prewarm._skip_frames])

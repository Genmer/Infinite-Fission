# tests/runner/r221_fixreg_cases.gd
# R221 vc27 回归修复用例体（入口 test_r221_fixreg.gd 运行时 load——-s 编译期禁引工程类名纪律）。
# 覆盖（tracker 二n #1/#2/#3）：
# ① Fix A：预热成本自适应跳帧——skip_frames_for 纯函数折算 + pump 跳帧还账递减 +
#    桌面单项预算内不折臂 + reset 清臂；
# ② Fix B：调速器有效性反馈——无效降档（EMA 无改善）6s 窗末回升一档并冻结后续降档 /
#    有效降档（改善 ≥5%）窗关不回升不冻结 / 模式切换清冻结后特效优先可再降 /
#    冻结常量契约；
# ③ Fix C：派发帽——60 条入队首帧恰派 48（保序）/ 余量 12 顺延下帧续派 /
#    dispatch_deferred 计数 / 空队第三派零派发；
# ④ Fix C：新起跳字首排版并入 tick 限批通道——show_popup 后脏标记置位且无残留文字 /
#    tick 一次排版到位 / merge→tick 累计值刷新 / 常量 DISPATCH_FRAME_CAP。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const Prewarm := preload("res://scripts/cards/card_desc_prewarm.gd")

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
	PerfGovernor.set_process(false)          # 引擎侧停走——用例手动 _process 确定性步进
	_gl.state = GameConst.GameStatus.PLAYING
	tree.paused = false
	_test_1_skip_frames_for()
	_test_2_pump_skip_accounting()
	_test_3_governor_ineffective_drop()
	_test_4_governor_effective_drop()
	_test_5_dispatch_cap()
	await _test_6_popup_first_layout_defer()
	_test_7_dispatch_survives_end_frame()
	_test_8_battle_entry_resets_frozen()
	await _test_9_dirty_age_force_refresh()
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


func _teardown_game_loop() -> void:
	if _gl != null:
		_gl.queue_free()
		await tree.process_frame


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
	await _teardown_game_loop()


# ── ① Fix A：跳帧折算纯函数 ────────────────────────────────────────
func _test_1_skip_frames_for() -> void:
	print("── ① Fix A：skip_frames_for 纯函数 ──")
	_check("①预算内不折臂（5µs/12ms → 0）",
		Prewarm.skip_frames_for(5, 12000) == 0, "")
	_check("①恰等预算不折臂（12000/12000 → 0）",
		Prewarm.skip_frames_for(12000, 12000) == 0, "")
	_check("①微超折 1 帧（12001/12000 → 1）",
		Prewarm.skip_frames_for(12001, 12000) == 1, "")
	_check("①两倍恰折 1 帧（24000/12000 → 1）",
		Prewarm.skip_frames_for(24000, 12000) == 1, "")
	_check("①两倍微超折 2 帧（24001/12000 → 2）",
		Prewarm.skip_frames_for(24001, 12000) == 2, "")
	_check("①真机量级（47ms/12ms → 3）",
		Prewarm.skip_frames_for(47000, 12000) == 3, "")
	_check("①零预算不折臂（pump(0) 语义）",
		Prewarm.skip_frames_for(47000, 0) == 0, "")


# ── ② Fix A：pump 跳帧还账 + 桌面不折臂 + reset 清臂 ───────────────
func _test_2_pump_skip_accounting() -> void:
	print("── ② Fix A：pump 跳帧还账记账 ──")
	Prewarm.reset_for_tests()
	Prewarm._queue.append({"text": "R221 探针甲", "cw": 600.0, "compact": false, "ls": 4.0})
	Prewarm._queue.append({"text": "R221 探针乙", "cw": 324.0, "compact": true, "ls": 4.0})
	Prewarm._skip_frames = 2
	var d0: int = Prewarm.pump()
	_check("②跳帧余额期泵零成本直返（done=0 且队不减）",
		d0 == 0 and Prewarm.remaining() == 2 and Prewarm._skip_frames == 1,
		"done=%d rem=%d skip=%d" % [d0, Prewarm.remaining(), Prewarm._skip_frames])
	var d1: int = Prewarm.pump()
	_check("②余额递减至 0（第二泵仍直返）",
		d1 == 0 and Prewarm._skip_frames == 0 and Prewarm.remaining() == 2, "")
	var d2: int = Prewarm.pump()
	_check("②余额尽后恢复消化（≥1 项）", d2 >= 1 and Prewarm.remaining() == 0,
		"done=%d rem=%d" % [d2, Prewarm.remaining()])
	_check("②桌面单项预算内不折臂（skip 回 0）",
		Prewarm._skip_frames == 0, "skip=%d" % Prewarm._skip_frames)
	# 真路径回归：ensure_built 建队 + 名义预算首泵正常消化且不折臂
	Prewarm.reset_for_tests()
	CardSelectUI._fit_desc_cache.clear()
	Prewarm.ensure_built(_gl.registry)
	var d3: int = Prewarm.pump(12000)
	_check("②真路径首泵消化 ≥1（Fix A 不破坏正常口径）",
		d3 >= 1 and Prewarm.remaining() < Prewarm.total_built(),
		"done=%d rem=%d total=%d" % [d3, Prewarm.remaining(), Prewarm.total_built()])
	_check("②真路径桌面不折臂（_skip_frames==0）", Prewarm._skip_frames == 0, "")
	Prewarm._skip_frames = 5
	Prewarm._last_item_us = 47000
	Prewarm.reset_for_tests()
	_check("②reset 清臂与成本观测口（skip=0/last=0）",
		Prewarm._skip_frames == 0 and Prewarm._last_item_us == 0, "")


# ── ③ Fix B：无效降档 → 回升 + 冻结 ────────────────────────────────
func _pg(p_tier: int, p_transitions: int, p_ema: float, p_mode_override: int) -> void:
	PerfGovernor.mode_override = p_mode_override
	PerfGovernor.tier_override = -1
	PerfGovernor.tier = p_tier
	PerfGovernor.transitions = p_transitions
	PerfGovernor._ema_inject = p_ema
	PerfGovernor._test_reset()
	_gl.state = GameConst.GameStatus.PLAYING
	tree.paused = false


func _tick(p_n: int) -> void:
	for i in p_n:
		PerfGovernor._process(PerfGovernor.SAMPLE_S)


func _test_3_governor_ineffective_drop() -> void:
	print("── ③ Fix B：无效降档回升 + 冻结 ──")
	_check("③冻结常量契约（EFFECT_CHECK_S=6.0 / EFFECT_MIN_GAIN=0.05）",
		PerfGovernor.EFFECT_CHECK_S == 6.0 and PerfGovernor.EFFECT_MIN_GAIN == 0.05, "")
	var t := float(PerfGovernor._target_fps())
	_pg(3, 0, t * 0.5, 0)                   # 深载 EMA=0.5×target 持续注入
	_tick(4)
	_check("③满 2.0s 降档 3→2（既有行为保持）",
		PerfGovernor.tier == 2 and PerfGovernor.transitions == 1,
		"tier=%d trans=%d" % [PerfGovernor.tier, PerfGovernor.transitions])
	_tick(4)
	_check("③再降 2→1 + 降档快照重臂（vc27 场景复现）",
		PerfGovernor.tier == 1 and PerfGovernor.transitions == 2,
		"tier=%d trans=%d" % [PerfGovernor.tier, PerfGovernor.transitions])
	_tick(8)                                  # 自最近降档起 4.0s（拍算：4+4+8=16）
	_check("③校验窗 6.0s 未满不动（4.0s 无变化）",
		PerfGovernor.tier == 1 and PerfGovernor.transitions == 2,
		"tier=%d trans=%d" % [PerfGovernor.tier, PerfGovernor.transitions])
	_tick(4)                                  # 累计 6.0s（总 20 拍），EMA 零改善
	_check("③无效降档回升 1→2（transitions=3）且冻结置位",
		PerfGovernor.tier == 2 and PerfGovernor.transitions == 3
			and PerfGovernor._drop_frozen,
		"tier=%d trans=%d frozen=%s" % [PerfGovernor.tier, PerfGovernor.transitions,
			str(PerfGovernor._drop_frozen)])
	_check("③校验后窗口关闭（_drop_ema=-1）",
		PerfGovernor._drop_ema == -1.0, "")
	_tick(8)                                  # 冻结期深降再累计 4.0s（总 24 拍）
	_check("③冻结期深降不再降档（tier 保持 2 / transitions 3）",
		PerfGovernor.tier == 2 and PerfGovernor.transitions == 3,
		"tier=%d trans=%d" % [PerfGovernor.tier, PerfGovernor.transitions])
	# 模式切换清冻结：_process 一拍（< SAMPLE_S 不触发采样）走模式观测口
	PerfGovernor.mode_override = 1
	PerfGovernor._process(0.016)
	_check("③模式切换清冻结（新阈值体系重计）", not PerfGovernor._drop_frozen, "")
	# 特效优先可再降（0.5×target < 0.70×target 阈）+ 地板 2 保持
	PerfGovernor.tier = 3
	PerfGovernor._ema_inject = t * 0.5
	PerfGovernor._test_reset()
	_tick(4)
	_check("③清冻结后特效优先满 2.0s 降档 3→2",
		PerfGovernor.tier == 2 and PerfGovernor.transitions == 4,
		"tier=%d trans=%d" % [PerfGovernor.tier, PerfGovernor.transitions])
	_tick(4)
	_check("③特效优先地板 2（8 拍不再降且校验窗 2.0s 未满）",
		PerfGovernor.tier == 2 and PerfGovernor.transitions == 4,
		"tier=%d trans=%d" % [PerfGovernor.tier, PerfGovernor.transitions])


# ── ④ Fix B：有效降档 → 窗关不回升不冻结 ──────────────────────────
func _test_4_governor_effective_drop() -> void:
	print("── ④ Fix B：有效降档不回升 ──")
	var t := float(PerfGovernor._target_fps())
	_pg(3, 0, t * 0.5, 0)
	_tick(4)
	_check("④降档 3→2 后快照在册（_drop_ema>0）",
		PerfGovernor.tier == 2 and PerfGovernor._drop_ema > 0.0,
		"tier=%d snap=%.1f" % [PerfGovernor.tier, PerfGovernor._drop_ema])
	PerfGovernor._ema_inject = t * 0.93      # 帧率回暖至迟滞带内（≥0.90 不降 / ≤0.95
	PerfGovernor._ema = t * 0.93             #   不升——隔离校验窗路径，EMA 直设快进收敛）
	_tick(12)                                 # 窗末增益 86% 远超 5%
	_check("④有效降档：窗关（_drop_ema=-1）不回升不冻结（tier 2 / transitions 1）",
		PerfGovernor.tier == 2 and PerfGovernor.transitions == 1
			and not PerfGovernor._drop_frozen and PerfGovernor._drop_ema == -1.0,
		"tier=%d trans=%d frozen=%s" % [PerfGovernor.tier, PerfGovernor.transitions,
			str(PerfGovernor._drop_frozen)])


# ── ⑤ Fix C：派发帽 ────────────────────────────────────────────────
func _test_5_dispatch_cap() -> void:
	print("── ⑤ Fix C：派发帽 ──")
	_check("⑤派发帽常量契约（DISPATCH_FRAME_CAP=48）",
		DamagePipeline.DISPATCH_FRAME_CAP == 48, "")
	var pipeline := DamagePipeline.new()
	var uids: Array[int] = []
	var cb := func(r: DamageResult) -> void: uids.append(int(r.source_uid))
	EventBus.damage_resolved.connect(cb)
	for i in range(60):
		var res := DamageResult.new()
		res.source_uid = i + 1
		res.final_value = float(i + 1)
		pipeline._resolved_queue.append(res)
	var defer0: int = DebugStats.get_counter(&"dispatch_deferred")
	pipeline.dispatch_resolved_frame()
	_check("⑤60 条入队首帧恰派 48（帽生效）",
		uids.size() == 48, "got=%d" % uids.size())
	_check("⑤保序（1..48 逐位）",
		uids[0] == 1 and uids[47] == 48, "head=%d tail=%d" % [uids[0], uids[47]])
	_check("⑤余量 12 留队", pipeline._resolved_queue.size() == 12,
		"size=%d" % pipeline._resolved_queue.size())
	_check("⑤顺延计数 dispatch_deferred +12",
		DebugStats.get_counter(&"dispatch_deferred") - defer0 == 12,
		"delta=%d" % (DebugStats.get_counter(&"dispatch_deferred") - defer0))
	pipeline.dispatch_resolved_frame()
	_check("⑤第二帧续派 12 条（49..60 保序、队清空、零顺延）",
		uids.size() == 60 and uids[48] == 49 and uids[59] == 60
			and pipeline._resolved_queue.is_empty(),
		"got=%d" % uids.size())
	pipeline.dispatch_resolved_frame()
	_check("⑤空队第三派零派发", uids.size() == 60, "got=%d" % uids.size())
	EventBus.damage_resolved.disconnect(cb)


# ── ⑥ Fix C：新起跳字首排版按平台分流 ─────────────────────────────
func _test_6_popup_first_layout_defer() -> void:
	print("── ⑥ Fix C：新起跳字首排版按平台分流 ──")
	var popup := DamagePopup.new()
	tree.root.add_child(popup)
	await tree.process_frame                    # _ready 组装 _label
	var calls0: int = DamagePopup.refresh_label_calls
	# 桌面分支（默认）：立即排版——与既有口径字节级一致（存量套件零扰动）
	popup.show_popup(Vector2(100.0, 200.0), 123.0, GameConst.PopupStyle.NORMAL, 7, 2)
	_check("⑥桌面分支：show_popup 立即排版（脏标记清 + 数值入字）",
		not popup._label_dirty and popup._label.text.contains("123"),
		"dirty=%s text=%s" % [str(popup._label_dirty), popup._label.text])
	_check("⑥桌面分支：排版恰 +1 次",
		DamagePopup.refresh_label_calls == calls0 + 1,
		"delta=%d" % (DamagePopup.refresh_label_calls - calls0))
	# mobile 分支（注入强制延迟）：首排版让渡 tick 限批通道
	DamagePopup.defer_first_layout = 1
	var popup2 := DamagePopup.new()
	tree.root.add_child(popup2)
	await tree.process_frame
	popup2._label.text = "999"                  # 模拟池复用上一命残留
	var calls1: int = DamagePopup.refresh_label_calls
	popup2.show_popup(Vector2(100.0, 200.0), 456.0, GameConst.PopupStyle.NORMAL, 8, 1)
	_check("⑥mobile 分支：show_popup 后脏标记置位且零排版",
		popup2._label_dirty and DamagePopup.refresh_label_calls == calls1,
		"dirty=%s delta=%d" % [str(popup2._label_dirty),
			DamagePopup.refresh_label_calls - calls1])
	_check("⑥mobile 分支：残留文字已清（不闪上一命数值）",
		popup2._label.text == "", "text=%s" % popup2._label.text)
	popup2.tick(0.016)
	_check("⑥mobile 分支：tick 一次排版到位（数值入字 + 脏标记清）",
		not popup2._label_dirty and popup2._label.text.contains("456"),
		"dirty=%s text=%s" % [str(popup2._label_dirty), popup2._label.text])
	_check("⑥mobile 分支：排版恰 +1 次",
		DamagePopup.refresh_label_calls == calls1 + 1,
		"delta=%d" % (DamagePopup.refresh_label_calls - calls1))
	popup2.merge(7.0)
	_check("⑥merge 重置脏标记（累计值排版仍走 tick）", popup2._label_dirty, "")
	popup2.tick(0.016)
	_check("⑥merge 累计值 463 入字", popup2._label.text.contains("463"),
		"text=%s" % popup2._label.text)
	DamagePopup.defer_first_layout = -1         # 覆写复位（防串后续套件）
	popup.free()
	popup2.free()


# ── ⑦ 修轮 D1：顺延余量跨 end_frame 存续 + 过期丢弃 ────────────────
func _test_7_dispatch_survives_end_frame() -> void:
	print("── ⑦ 修轮 D1：顺延跨帧存续/过期丢弃 ──")
	var pipeline := DamagePipeline.new()
	var uids: Array[int] = []
	var cb := func(r: DamageResult) -> void: uids.append(int(r.source_uid))
	EventBus.damage_resolved.connect(cb)
	pipeline.begin_frame(1000)                # 带帧号（game_loop 真实口径——过期守卫开）
	for i in range(60):
		var res := DamageResult.new()
		res.source_uid = i + 1
		res.frame_stamp = 1000
		pipeline._resolved_queue.append(res)
	pipeline.dispatch_resolved_frame()
	pipeline.end_frame()                      # 帧末兜底口（D1 前：此处清队吞余量）
	_check("⑦end_frame 不再吞顺延余量（12 条留队）",
		pipeline._resolved_queue.size() == 12, "size=%d" % pipeline._resolved_queue.size())
	pipeline.begin_frame(1001)
	pipeline.dispatch_resolved_frame()
	_check("⑦次帧续派全数到达（60/60 保序）",
		uids.size() == 60 and uids[48] == 49 and uids[59] == 60,
		"got=%d" % uids.size())
	# 过期丢弃：前 3 条窗口外（stamp 900/950/960 < 1000-30）+ 后 2 条新鲜
	var stale0: int = DebugStats.get_counter(&"dispatch_stale_drop")
	for stamp in [900, 950, 960, 1000, 999]:
		var res := DamageResult.new()
		res.source_uid = stamp
		res.frame_stamp = stamp
		pipeline._resolved_queue.append(res)
	pipeline.dispatch_resolved_frame()
	_check("⑦过期前缀丢弃（窗口 30 帧外 3 条）+ 新鲜 2 条照派",
		uids.size() == 62 and uids[60] == 1000 and uids[61] == 999
			and pipeline._resolved_queue.is_empty(),
		"got=%d" % uids.size())
	_check("⑦过期计数 dispatch_stale_drop +3",
		DebugStats.get_counter(&"dispatch_stale_drop") - stale0 == 3,
		"delta=%d" % (DebugStats.get_counter(&"dispatch_stale_drop") - stale0))
	EventBus.damage_resolved.disconnect(cb)


# ── ⑧ Fix B+G：冻结生命周期（局中窗保持 / 新局重臂） ────────────────
func _test_8_battle_entry_resets_frozen() -> void:
	print("── ⑧ Fix B+G：冻结生命周期 ──")
	var t := float(PerfGovernor._target_fps())
	_pg(3, 0, t * 0.5, 0)
	_tick(20)                                  # ③ 同款全程：3→2→1→无效回升冻结（总 20 拍）
	_check("⑧前置：无效降档冻结在位", PerfGovernor._drop_frozen and PerfGovernor.tier == 2,
		"tier=%d frozen=%s" % [PerfGovernor.tier, str(PerfGovernor._drop_frozen)])
	_gl.state = GameConst.GameStatus.LEVEL_UP
	PerfGovernor._process(0.016)               # 出局观测（选卡窗）
	_check("⑧LEVEL_UP 局中窗：冻结保持", PerfGovernor._drop_frozen, "")
	_gl.state = GameConst.GameStatus.PLAYING
	PerfGovernor._process(0.016)               # 回战斗沿——局中窗不重臂（R222 Fix G 契约）
	_check("⑧选卡收口回 PLAYING：不重臂（冻结保持 + tier 2）",
		PerfGovernor._drop_frozen and PerfGovernor.tier == 2,
		"tier=%d frozen=%s" % [PerfGovernor.tier, str(PerfGovernor._drop_frozen)])
	_tick(4)                                   # 冻结期：深降通道关
	_check("⑧局中冻结期不降档（tier 2 / transitions 3）",
		PerfGovernor.tier == 2 and PerfGovernor.transitions == 3,
		"tier=%d trans=%d" % [PerfGovernor.tier, PerfGovernor.transitions])
	# 新局重臂（R222 Fix G：正信号 notify_new_run——r222_runrearm ① 承接完整矩阵）


# ── ⑨ 修轮 M5：脏龄保底绕帽强制排版 ────────────────────────────────
func _test_9_dirty_age_force_refresh() -> void:
	print("── ⑨ 修轮 M5：脏龄保底 ──")
	var pm: PopupManager = _gl.popup_manager
	pm.tick(5.0)                              # 清场：⑤ 派发测试经 EventBus 喂入的跳字
	                                          # 一次性到期归还（寿命 ≤0.6s，5s 步进必清）
	pm.label_refresh_cap_override = 1          # 极限帽 1/帧构造饥饿
	# 3 张桌面跳字（起手即排版）→ 持续合并风暴每帧全员重脏：帽 1/帧下自尾向头只有
	# 最后一张永远抢到排版位，前两张脏龄持续增长（寿命被 merge 反复重置也不影响）
	var results: Array[DamageResult] = []
	for uid in [901, 902, 903]:
		var r := DamageResult.new()
		r.source_uid = uid
		r.target_uid = uid
		r.final_value = 10.0
		r.pos = Vector2(200.0, 200.0)
		results.append(r)
		pm.on_damage_resolved(r)
	var actives: Array = pm._active_list
	_check("⑨前置：3 张跳字在场", actives.size() == 3, "n=%d" % actives.size())
	var all_clean := false
	var starved_seen := false
	for i in range(18):                        # 18 帧 ≈0.30s > 0.25s 脏龄阈
		for p in actives:
			p.merge(1.0)                       # 风暴：全员每帧重脏（寿命重置 0.35）
		pm.tick(1.0 / 60.0)
		var dirty_n := 0
		for p in actives:
			if p._label_dirty:
				dirty_n += 1
		if dirty_n >= 2:
			starved_seen = true                # 帽内期：≥2 张被让渡（饥饿形态先出现）
		if dirty_n == 0:
			all_clean = true
			break
	_check("⑨饥饿形态出现（帽 1/帧下 ≥2 张让渡过）", starved_seen, "")
	_check("⑨脏龄 0.25s 后全员强制排版（无终身旧值/空白）", all_clean, "")
	pm.label_refresh_cap_override = -1         # 覆写复位

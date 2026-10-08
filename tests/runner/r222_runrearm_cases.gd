# tests/runner/r222_runrearm_cases.gd
# R222 用例体（vc28 日志驱动——tracker 二o #3/#5）：
# ① Fix G：PerfGovernor 新局 tier 重臂状态矩阵——GAME_OVER→PLAYING / MENU→PLAYING
#    沿重臂 tier=3+清冻结/校验窗/双侧计时（transitions 不计）；LEVEL_UP/PAUSED 局中
#    窗不置局间闩不重臂；重臂后降档通道即开（深载 4 拍 3→2）；
# ② Fix P：R215 贴图预热成本自适应跳帧——余额期零成本直返（队不减）/余额尽恢复消化/
#    boss 挂机门 gate break 不折臂/预算 0 恰 1 项语义保持。
extends RefCounted

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
	await tree.process_frame
	await tree.process_frame
	PerfGovernor.set_process(false)          # 引擎侧停走——用例手动 _process 确定性步进
	tree.paused = false
	_test_1_run_rearm_matrix()
	_test_2_tex_prewarm_skip()
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
	_gl._tex_prewarm_skip = 0
	if _gl != null:
		_gl.queue_free()
		await tree.process_frame


func _pg(p_tier: int, p_transitions: int, p_ema: float) -> void:
	PerfGovernor.mode_override = 0
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


# ── ① Fix G：新局重臂（正信号）状态矩阵 ──────────────────────────
func _test_1_run_rearm_matrix() -> void:
	print("── ① Fix G：新局重臂（正信号） ──")
	var t := float(PerfGovernor._target_fps())
	# 场景复现（vc28）：上一局深载降到 tier1 + 冻结遗留
	_pg(1, 2, t * 0.5)
	PerfGovernor._drop_frozen = true          # 直接注入「上一局遗留冻结」态
	PerfGovernor._drop_ema = t * 0.5
	PerfGovernor._drop_hold = 3.0
	var ema0: float = PerfGovernor._ema       # EMA 保持契约观测基线
	# 局中窗（LEVEL_UP/选卡收口）无信号不重臂
	_gl.state = GameConst.GameStatus.LEVEL_UP
	PerfGovernor._process(0.016)
	_gl.state = GameConst.GameStatus.PLAYING
	PerfGovernor._process(0.016)
	_check("①局中窗（LEVEL_UP→PLAYING）不重臂：tier 仍 1 + 冻结保持",
		PerfGovernor.tier == 1 and PerfGovernor._drop_frozen,
		"tier=%d frozen=%s" % [PerfGovernor.tier, str(PerfGovernor._drop_frozen)])
	# PAUSED（tree.paused，state=PLAYING）恢复无信号不重臂
	PerfGovernor.tier = 1
	PerfGovernor._drop_frozen = true
	tree.paused = true
	PerfGovernor._process(0.016)
	tree.paused = false
	PerfGovernor._process(0.016)
	_check("①暂停恢复（PAUSED→PLAYING）不重臂：tier 1 + 冻结保持",
		PerfGovernor.tier == 1 and PerfGovernor._drop_frozen,
		"tier=%d frozen=%s" % [PerfGovernor.tier, str(PerfGovernor._drop_frozen)])
	# GAME_OVER→PLAYING 无信号不重臂（=无尽继续 continue_endless 路径：同局延续）
	_gl.state = GameConst.GameStatus.GAME_OVER
	PerfGovernor._process(0.016)
	_gl.state = GameConst.GameStatus.PLAYING
	PerfGovernor._process(0.016)
	_check("①无尽继续路径（GAME_OVER→PLAYING 无信号）不重臂：tier 1 保持",
		PerfGovernor.tier == 1,
		"tier=%d" % PerfGovernor.tier)
	# 正信号：新局重臂
	PerfGovernor.notify_new_run()
	_check("①notify_new_run 重臂：tier 1→3 + 冻结/校验窗/双侧计时清",
		PerfGovernor.tier == 3 and not PerfGovernor._drop_frozen
			and PerfGovernor._drop_ema == -1.0 and PerfGovernor._drop_hold == 0.0
			and PerfGovernor._drop_acc == 0.0 and PerfGovernor._recover_acc == 0.0,
		"tier=%d frozen=%s" % [PerfGovernor.tier, str(PerfGovernor._drop_frozen)])
	_check("①重臂不计 transitions（非真采样档变）", PerfGovernor.transitions == 2,
		"trans=%d" % PerfGovernor.transitions)
	_check("①EMA 跨重臂保持（契约：只动 tier/冻结/计时）",
		absf(PerfGovernor._ema - ema0) < 0.0001 or ema0 < 0.0,
		"ema0=%.1f ema=%.1f" % [ema0, PerfGovernor._ema])
	_tick(4)
	_check("①重臂后深载 4 拍降档 3→2（transitions=3）",
		PerfGovernor.tier == 2 and PerfGovernor.transitions == 3,
		"tier=%d trans=%d" % [PerfGovernor.tier, PerfGovernor.transitions])
	# 真链：暂停面板「重新开始」（评审 high 修轮主路径）——restart_run 直迁含正信号
	PerfGovernor.tier = 1
	PerfGovernor._drop_frozen = true
	PerfGovernor._ema_inject = -1.0
	PerfGovernor._test_reset()
	_gl.state = GameConst.GameStatus.PAUSED
	tree.paused = false
	var ok: bool = _gl.restart_run()
	_check("①真链 restart_run（PAUSED→PLAYING 重开）成功且重臂 tier 3 + 冻结清",
		ok and _gl.state == GameConst.GameStatus.PLAYING
			and PerfGovernor.tier == 3 and not PerfGovernor._drop_frozen,
		"ok=%s state=%d tier=%d frozen=%s" % [str(ok), _gl.state, PerfGovernor.tier,
			str(PerfGovernor._drop_frozen)])


# ── ② Fix P：贴图预热占空跳帧 ─────────────────────────────────────
func _test_2_tex_prewarm_skip() -> void:
	print("── ② Fix P：贴图预热占空 ──")
	var gl: GameLoop = _gl
	# 清队建两枚轻项（桌面 cached/廉价生成——成本必 <12ms 不折臂）
	gl._tex_prewarm_queue.clear()
	gl._tex_prewarm_skip = 0
	gl._menu_dwell_s = 99.0                    # boss 挂机门开（不 gate）
	gl._tex_prewarm_queue.append({&"op": 4})
	gl._tex_prewarm_queue.append({&"op": 4})
	gl._process_tex_prewarm(12000)
	_check("②轻项批量消化（预算内 2 项全清 + 不折臂）",
		gl._tex_prewarm_queue.is_empty() and gl._tex_prewarm_skip == 0,
		"rem=%d skip=%d" % [gl._tex_prewarm_queue.size(), gl._tex_prewarm_skip])
	# 余额跳帧：手动注臂（真机重项在桌面不可复现——锁行为不锁成本）
	gl._tex_prewarm_queue.append({&"op": 4})
	gl._tex_prewarm_skip = 2
	gl._process_tex_prewarm(12000)
	_check("②余额期零成本直返（队不减 / 余额 2→1）",
		gl._tex_prewarm_queue.size() == 1 and gl._tex_prewarm_skip == 1,
		"rem=%d skip=%d" % [gl._tex_prewarm_queue.size(), gl._tex_prewarm_skip])
	gl._process_tex_prewarm(12000)
	_check("②余额递减第二拍（1→0 队仍不减）",
		gl._tex_prewarm_queue.size() == 1 and gl._tex_prewarm_skip == 0,
		"rem=%d skip=%d" % [gl._tex_prewarm_queue.size(), gl._tex_prewarm_skip])
	gl._process_tex_prewarm(12000)
	_check("②余额尽恢复消化（队清 + 桌面轻项不再折臂）",
		gl._tex_prewarm_queue.is_empty() and gl._tex_prewarm_skip == 0,
		"rem=%d skip=%d" % [gl._tex_prewarm_queue.size(), gl._tex_prewarm_skip])
	# boss 挂机门 gate break：不折臂不消耗
	gl._tex_prewarm_queue.append({&"op": 0, &"kind": &"boss3", &"angry": true})
	gl._menu_dwell_s = 0.0                    # 门未开
	gl._process_tex_prewarm(12000)
	_check("②boss 挂机门未开：队首暂停（不消耗不折臂）",
		gl._tex_prewarm_queue.size() == 1 and gl._tex_prewarm_skip == 0,
		"rem=%d skip=%d" % [gl._tex_prewarm_queue.size(), gl._tex_prewarm_skip])
	# 预算 0 恰 1 项语义（与 R215/cardprewarm 同口径）
	gl._menu_dwell_s = 99.0
	gl._tex_prewarm_queue.append({&"op": 4})
	gl._process_tex_prewarm(0)
	_check("②预算 0 恰 1 项（最小粒度不饿死）+ 不折臂（budget≤0 免折）",
		gl._tex_prewarm_queue.size() == 1 and gl._tex_prewarm_skip == 0,
		"rem=%d skip=%d" % [gl._tex_prewarm_queue.size(), gl._tex_prewarm_skip])
	gl._tex_prewarm_queue.clear()
	gl._tex_prewarm_skip = 0

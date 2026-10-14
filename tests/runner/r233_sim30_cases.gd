# tests/runner/r233_sim30_cases.gd
# R233 T1+T2 用例体（入口 test_r233_sim30.gd 运行时 load）。覆盖矩阵：
# ① 谓词门（A 组）：GameLoop.sim30_effective() 哨兵序（-1 真值/-2 强制关/-3 模拟 mobile
#    ——pool_valve_override 同款可测性）；headless 真值门恒 false=桌面/headless 零扰动前提。
# ② 选择器（B 组）：sim_hz_target() 60Hz 档返回原值 60（回退档全等）/ 30Hz 档 30
#    （决策6 *_30HZ 后缀常量在位——T3 帽值选表同款铺路）。
# ③ 挂点零写（C 组）：headless 下 Meta._apply_fps_cap() 早退零写（Engine 三键快照对拍
#    ——meta_manager mobile 门 :513-514 零写点不破坏）；源级挂点断言（r194 project.godot
#    源级断言同款）：写点表达式恰一处且走选择器、无 60/30 字面量残留——「谓词 true 时
#    写 30」由 写点=选择器 ∧ B2 选择器 30Hz 档 复合锁定。
# ④ headless 电池口径零扰动 + T1 插µs 键（D 组）：谓词全开注入态（-3+ENABLED=true 最
#    激进）手动驱动 _physics_process 不读不写 Engine 设置；插µs 键关态恒 0（决策7 诊断
#    先于行为刀——T6 插值层未实施期累计器恒 0 基线）+ 重复拉取增量=0 + 1Hz 行尾追加位
#    （结µs 之后）在位。
#    R233 修轮补（D7-D9）：插模拟µs 键（模拟侧恢复+快照两遍历秒差分——MED-3/QA LOW-1）
#    在位/同窗自洽 + 派deferred/派drop 段上行（HIGH-1）。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const META_SOURCE := "res://scripts/meta/meta_manager.gd"
const EXPECTED_TOTAL := 23               # 套件总项数断言（收尾总项数检查之前的用例数——
                                         # r233_settleus 同口径；R231 假绿教训；R233 修轮
                                         # +D7/D8/D9）
const HEADLESS_PHYS_HZ := 120            # project.godot 全局物理时钟（headless 缺省——r194 源级护栏）

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_boot_game_loop()
	DebugStats.set_process(false)          # 冻结 1Hz 采样——诊断差分窗口测试独占
	PerfGovernor.set_process(false)        # 冻结调速器档变（r232 套件同款纪律）
	await tree.process_frame
	await tree.process_frame
	_test_a_predicate_gate()
	_test_b_hz_selector()
	await _test_c_hook_zero_write()
	await _test_d_headless_clean_and_ip_key()
	await _cleanup()
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


# ── ① 谓词门（-3 哨兵同款可测性） ─────────────────────────────────

func _test_a_predicate_gate() -> void:
	print("── ① 谓词门（哨兵序 -1/-2/-3） ──")
	GameLoop.sim30_override = -1
	GameLoop.SIM_30HZ_ENABLED = true
	_check("A1 真值门 headless（override=-1 非 mobile）→ 谓词 false（桌面/headless 恒关）",
		not GameLoop.sim30_effective(), "")
	GameLoop.sim30_override = -2
	_check("A2 哨兵 -2 强制关 → 谓词 false（即使开关 true）",
		not GameLoop.sim30_effective(), "")
	GameLoop.sim30_override = -3
	_check("A3 哨兵 -3 模拟 mobile + 开关 true → 谓词 true（headless 可驱真值臂）",
		GameLoop.sim30_effective(), "")
	GameLoop.SIM_30HZ_ENABLED = false
	_check("A4 哨兵 -3 + 开关注入 false → 谓词 false（开关单点可回退）",
		not GameLoop.sim30_effective(), "")
	GameLoop.SIM_30HZ_ENABLED = true
	GameLoop.sim30_override = -1
	_check("A5 复位后 headless 真值恢复 false（注入无泄漏）",
		not GameLoop.sim30_effective(), "")


# ── ② 选择器（60Hz 档原值 / 30Hz 档——决策6 *_30HZ 后缀方案 T3 铺路） ──

func _test_b_hz_selector() -> void:
	print("── ② 物理频率选表 sim_hz_target ──")
	GameLoop.sim30_override = -2
	_check("B1 谓词 false → 选表=60（R204 原值逐位——回退档全等）",
		GameLoop.sim_hz_target() == 60, "hz=%d" % GameLoop.sim_hz_target())
	GameLoop.sim30_override = -3
	GameLoop.SIM_30HZ_ENABLED = true
	_check("B2 谓词 true（-3 注入）→ 选表=30（决策1 方案A 写值）",
		GameLoop.sim_hz_target() == 30, "hz=%d" % GameLoop.sim_hz_target())
	_check("B3 档位常量在位（SIM_HZ_60=60 ∧ SIM_HZ_30HZ=30——决策6 *_30HZ 后缀方案，T3 选表同款铺路）",
		GameLoop.SIM_HZ_60 == 60 and GameLoop.SIM_HZ_30HZ == 30,
		"%d/%d" % [GameLoop.SIM_HZ_60, GameLoop.SIM_HZ_30HZ])
	GameLoop.sim30_override = -1


# ── ③ 挂点零写（headless 早退路径） + 源级挂点断言 ─────────────────

func _test_c_hook_zero_write() -> void:
	print("── ③ meta_manager 挂点：headless 零写 + 源级断言 ──")
	var hz0 := Engine.physics_ticks_per_second
	var fps0 := Engine.max_fps
	var steps0 := Engine.max_physics_steps_per_frame
	Meta._apply_fps_cap()                  # headless 直调（真链 boot/settings_changed 同入口）
	_check("C1 headless 直调 _apply_fps_cap → physics_ticks_per_second 零写（%d 保持）" % hz0,
		Engine.physics_ticks_per_second == hz0, "now=%d" % Engine.physics_ticks_per_second)
	_check("C2 headless 直调 → max_fps 零写（0 保持——r194 键契约同口径）",
		Engine.max_fps == fps0, "now=%d" % Engine.max_fps)
	_check("C3 headless 直调 → max_physics_steps_per_frame 零写（%d 保持）" % steps0,
		Engine.max_physics_steps_per_frame == steps0, "now=%d" % Engine.max_physics_steps_per_frame)
	var fa := FileAccess.open(META_SOURCE, FileAccess.READ)
	_check("C4 源级断言前置：meta_manager.gd 可读（res:// 源文本——r194 project.godot 同款）",
		fa != null, "")
	if fa == null:
		return
	var src := fa.get_as_text()
	fa.close()
	var hook := "Engine.physics_ticks_per_second = GameLoop.sim_hz_target()"
	var hook_count := src.count(hook)
	_check("C5 挂点写点恰一处且走选择器（「%s」×%d）" % [hook, hook_count],
		hook_count == 1, "count=%d" % hook_count)
	_check("C6 无字面量写点残留（「physics_ticks_per_second = 60」「= 30」均 0 处——写值只出选择器，谓词 true 时写 30 由 C5∧B2 复合锁定）",
		src.count("physics_ticks_per_second = 60") == 0
		and src.count("physics_ticks_per_second = 30") == 0, "")


# ── ④ headless 电池口径零扰动 + T1 插µs 键 ────────────────────────

func _test_d_headless_clean_and_ip_key() -> void:
	print("── ④ 谓词全开注入态手动驱动 + 插µs 键关态基线 ──")
	GameLoop.sim30_override = -3           # 最激进注入：谓词全开（headless 语义下）
	GameLoop.SIM_30HZ_ENABLED = true
	var hz0 := Engine.physics_ticks_per_second
	var stamp0: int = _gl.frame_stamp
	for i in range(10):
		_gl._physics_process(1.0 / 60.0)   # 手动驱动（电池同款——不读 Engine 设置）
	_check("D1 谓词全开手动驱动 ×10 → physics_ticks_per_second 零写（%d 保持——本逻辑无 Engine 写点）" % hz0,
		Engine.physics_ticks_per_second == hz0, "now=%d" % Engine.physics_ticks_per_second)
	_check("D2 驱动后模拟链路零异常（frame_stamp 前进=%d 且 state 保持）" % (_gl.frame_stamp - stamp0),
		_gl.frame_stamp > stamp0 and _gl.state == GameConst.GameStatus.MENU,
		"stamp=%d state=%d" % [_gl.frame_stamp, _gl.state])
	var pull1: Dictionary = _gl.diag_counts()
	_check("D3 插µs 键在位且首拉=0（T6 插值层未实施期累计器恒 0=关态基线——AC-9 关=0）",
		pull1.has(&"ip_us_per") and int(pull1.get(&"ip_us_per", -1)) == 0,
		"ip_us_per=%s" % str(pull1.get(&"ip_us_per", "?")))
	var pull2: Dictionary = _gl.diag_counts()
	_check("D4 重复拉取增量=0（结µs/帽N 同款闩语义）",
		int(pull2.get(&"ip_us_per", -1)) == 0, "ip_us_per=%s" % str(pull2.get(&"ip_us_per", "?")))
	var line: String = String(DebugStats.call("_diag_format_line", _gl, 65000))
	_check("D5 1Hz 行含「插µs0」段（关态基线直读）",
		line.contains("插µs0"), "tail=%s" % line.right(24))
	_check("D6 行尾追加位=结µs 之后（行内序 结µs < 插µs——行尾结构在位不破尾锚）",
		line.find("结µs") >= 0 and line.find("结µs") < line.find("插µs"),
		"idx=%d/%d" % [line.find("结µs"), line.find("插µs")])
	# R233 修轮（HIGH-1/MED-3+QA LOW-1）：新行尾键回归——插模拟µs（模拟侧两遍历秒差分）
	# + 派deferred/派drop（派发计数上行）。DebugStats 已冻结（run 头）→ 拉取间只本组手动驱动。
	var pull_i1: Dictionary = _gl.diag_counts()
	_check("D7 插模拟µs 键在位且零窗读 0（上一拉取后同步零帧——差分闩语义同 插µs）",
		pull_i1.has(&"ip_sim_us") and int(pull_i1.get(&"ip_sim_us", -1)) == 0,
		"ip_sim_us=%s" % str(pull_i1.get(&"ip_sim_us", "?")))
	var raw_a: int = _gl.ip_sim_us_total
	for i in range(20):
		_gl._physics_process(1.0 / 60.0)   # 谓词开态：恢复+快照双遍历（快照 T7 无条件）→ 计量单调增
	var pull_i2: Dictionary = _gl.diag_counts()
	var raw_b: int = _gl.ip_sim_us_total
	_check("D8 插模拟µs 秒差分自洽（行键 == 原始累计差分 %d——同窗对拍，同步块零插帧）" % maxi(raw_b - raw_a, 0),
		int(pull_i2.get(&"ip_sim_us", -1)) == raw_b - raw_a,
		"pull=%s rawΔ=%d" % [str(pull_i2.get(&"ip_sim_us", "?")), raw_b - raw_a])
	var line2: String = String(DebugStats.call("_diag_format_line", _gl, 65001))
	_check("D9 1Hz 行含「派deferred0 派drop0」段（MENU 无战斗派发 → 确定零；HIGH-1 真机取证通道上行在位）",
		line2.contains("派deferred0 派drop0"), "tail=%s" % line2.right(36))
	GameLoop.sim30_override = -1


# ── 收尾 ──────────────────────────────────────────────────────────

func _cleanup() -> void:
	GameLoop.SIM_30HZ_ENABLED = true       # 注入态复位（前置防呆——用例内已各自复位）
	GameLoop.sim30_override = -1
	_check("套件总项数（EXPECTED=%d——R231 假绿教训：总项数也要断言）" % EXPECTED_TOTAL,
		_pass + _fail == EXPECTED_TOTAL, "实=%d" % (_pass + _fail))
	_gl.state = GameConst.GameStatus.MENU
	DebugStats.set_process(true)
	PerfGovernor.set_process(true)
	if _gl != null:
		_gl.queue_free()
		await tree.process_frame

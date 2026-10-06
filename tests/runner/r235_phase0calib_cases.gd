# tests/runner/r235_phase0calib_cases.gd（R235 搭车④ 用例体——入口运行时加载）
# 覆盖矩阵：
# ① A 组·源级挂点（r194/C5 源级断言先例）：派µs 分键（game_loop dispatch 段键值写+peak
#    写各恰一处）/ 菜单挂载点恰 1 定义+1 调用 / debug_stats 行尾三键拼装恰 1 处 /
#    波键已含 spawner tick（wave_director.gd 内调——「含则不动」口径的源级锁定）/
#    校准件零文件系统写点（FileAccess/DirAccess——C 盘红线）。
# ② B 组·菜单态自动触发一次（真帧驱动）：force 注入 + delay 调小加速 → 挂载（MENU 态
#    + 实例闩）/ 完成（自拆 + 环形日志恰 1 行「校准」）/ 不再触发（mount_count 与
#    校准行数双口径 240 帧复读不变）。
# ③ C 组·一次性「校准」行内容：六臂读数键齐且 >0 / 比A/B、比E/F >1.0（合理带下界，
#    不设上界）/ 规模口径自描述 / 行头 [m:ss 校准] 戳。
# ④ D 组·二次运行幂等：直挂第二实例自拆（会话完成闩）/ 不重复占日志 / 双闩在位。
# ⑤ E 组·搭车③行尾三键在位（任务1 同套回归：物步µs/派µs/渲ms 键在位+行尾序+格式）。
# 纪律：DebugStats 采样冻结（环形日志判读干净——校准行是唯一进日志的事件）；
# 静态注入（force/delay）收尾复位（r229 _reset_static_overrides 同款纪律）。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const GL_SOURCE := "res://scripts/loop/game_loop.gd"
const DS_SOURCE := "res://autoload/debug_stats.gd"
const WD_SOURCE := "res://scripts/entities/wave/wave_director.gd"
const CALIB_SOURCE := "res://scripts/diag/phase0_calib.gd"
const CALIB_SRC := preload("res://scripts/diag/phase0_calib.gd")
const EXPECTED_TOTAL := 19               # 收尾总项数检查之前的用例数（r233 同口径；R231 假绿教训）

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_boot_game_loop()
	DebugStats.set_process(false)          # 冻结 1Hz 采样（r233 套件同款纪律）
	await tree.process_frame
	await tree.process_frame
	_test_a_source_hooks()
	await _test_b_menu_auto_trigger()
	_test_c_calib_line()
	await _test_d_idempotent()
	_test_e_tail_keys()
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


func _read_source(p_path: String) -> String:
	var fa := FileAccess.open(p_path, FileAccess.READ)
	if fa == null:
		return ""
	var src := fa.get_as_text()
	fa.close()
	return src


func _calib_line_count() -> int:
	# 环形日志中「校准」行计数（diag_push_calib 通道唯一写源）
	var lines: Array = DebugStats.get("_diag_lines")
	var n := 0
	for l in lines:
		if String(l).contains("校准"):
			n += 1
	return n


func _find_calib_line() -> String:
	var lines: Array = DebugStats.get("_diag_lines")
	for l in lines:
		if String(l).contains("校准"):
			return String(l)
	return ""


# ── ① A 组：源级挂点断言 ───────────────────────────────────────────

func _test_a_source_hooks() -> void:
	print("── ① 源级挂点（派µs 分键/菜单挂载/行尾三键/波键含 spawner/零写盘） ──")
	var gl_src := _read_source(GL_SOURCE)
	_check("A1 game_loop 派发分键在位：stage_probe_us[&\"dispatch\"] 值写+peak 写各恰一处（R235 搭车③——原混入 UI 段；maxi 读回同款不计——fx 段同形状）",
		gl_src.count("stage_probe_us[&\"dispatch\"] =") == 1
			and gl_src.count("stage_probe_us_peak[&\"dispatch\"] =") == 1,
		"val=%d peak=%d" % [gl_src.count("stage_probe_us[&\"dispatch\"] ="),
			gl_src.count("stage_probe_us_peak[&\"dispatch\"] =")])
	_check("A2 game_loop 菜单挂载点恰一处（func 定义+MENU 臂调用各一——_maybe_start_phase0_calib）",
		gl_src.count("_maybe_start_phase0_calib(") == 2,
		"n=%d" % gl_src.count("_maybe_start_phase0_calib("))
	var ds_src := _read_source(DS_SOURCE)
	_check("A3 debug_stats 行尾三键拼装恰一处（「物步µs%d 派µs%d 渲ms%.1f」——物步µs/派µs/渲ms）",
		ds_src.count("物步µs%d 派µs%d 渲ms%.1f") == 1, "n=%d" % ds_src.count("物步µs%d 派µs%d 渲ms%.1f"))
	var wd_src := _read_source(WD_SOURCE)
	_check("A4 波键已含 spawner tick（wave_director.gd 内 spawner.tick 调用在位——game_loop 波段 wave_director.tick 全包，「含则不动」口径源级锁定）",
		wd_src.contains("spawner.tick("), "")
	var calib_src := _read_source(CALIB_SOURCE)
	_check("A5 校准件零文件系统写点（FileAccess/DirAccess 均 0 处——C 盘红线：只进内存环形日志行）",
		calib_src.count("FileAccess") == 0 and calib_src.count("DirAccess") == 0,
		"fa=%d dir=%d" % [calib_src.count("FileAccess"), calib_src.count("DirAccess")])


# ── ② B 组：菜单态自动触发一次（真帧驱动） ─────────────────────────

func _test_b_menu_auto_trigger() -> void:
	print("── ② 菜单态自动触发一次（force 注入 + delay 0.05s 加速） ──")
	GameLoop.phase0_calib_force = true
	GameLoop.phase0_calib_delay_s = 0.05
	var mounted := false
	var mount_state_menu := false
	for i in range(400):                   # dwell 0.05s @120Hz 物理 ≈ 6 tick——真帧驱动上限冗余
		await tree.process_frame
		if _gl.get_node_or_null("Phase0Calib") != null:
			mounted = true
			mount_state_menu = _gl.state == GameConst.GameStatus.MENU
			break
	_check("B1 菜单停留门后挂载（≤400 真帧；MENU 态挂载 + 实例闩置位 + 挂载计数 ==1）",
		mounted and mount_state_menu and _gl._phase0_calib_latch
			and CALIB_SRC.mount_count() == 1,
		"mounted=%s state_menu=%s latch=%s mounts=%d" % [str(mounted), str(mount_state_menu),
			str(_gl._phase0_calib_latch), CALIB_SRC.mount_count()])
	var done := false
	for i in range(4000):                  # 六臂×2轮×48迭代+构建/拆 ≈ 590 帧——上限冗余
		await tree.process_frame
		if _gl.get_node_or_null("Phase0Calib") == null:
			done = true
			break
	_check("B2 校准件自拆完成（≤4000 真帧）+ 环形日志恰 1 行「校准」（diag_push_calib 通道）",
		done and _calib_line_count() == 1,
		"done=%s lines=%d" % [str(done), _calib_line_count()])
	var mounts_before := CALIB_SRC.mount_count()
	for i in range(240):                   # 再驱动 240 帧（dwell 持续累计）——闩复读
		await tree.process_frame
	_check("B3 触发一次后不再触发（240 帧复读：挂载计数不变 + 校准行数不变）",
		CALIB_SRC.mount_count() == mounts_before and _calib_line_count() == 1,
		"mounts=%d→%d lines=%d" % [mounts_before, CALIB_SRC.mount_count(), _calib_line_count()])
	GameLoop.phase0_calib_force = false
	GameLoop.phase0_calib_delay_s = 4.0


# ── ③ C 组：一次性「校准」行内容 ───────────────────────────────────

func _test_c_calib_line() -> void:
	print("── ③ 校准行内容（六臂键 + 比值带） ──")
	var line := _find_calib_line()
	var rx_arms := RegEx.new()
	rx_arms.compile("臂A(\\d+) 臂B(\\d+) 臂C(\\d+) 臂D(\\d+) 臂E(\\d+) 臂F(\\d+)")
	var m := rx_arms.search(line)
	var arms_ok := false
	if m != null:
		arms_ok = true
		for i in range(1, 7):              # 捕获组 1-6：六臂读数全 >0（µs/帧——headless 亦 µs 级）
			if int(m.strings[i]) <= 0:
				arms_ok = false
	_check("C1 六臂读数键齐且 >0（臂A/B/C/D/E/F——N%d×%d帧×%d轮 p50 小轮 µs）" % [3000, 40, 2],
		arms_ok, "line=%s" % line.right(96))
	var ratio_ab := _parse_ratio(line, "比A/B=")
	_check("C2 比A/B=%.1f（属性轴 vs 数组轴——合理带下界 >1.0，不设上界）" % ratio_ab,
		ratio_ab > 1.0, "ratio=%s" % str(ratio_ab))
	var ratio_ef := _parse_ratio(line, "比E/F=")
	_check("C3 比E/F=%.1f（方法调用形态 vs 批处理形态——合理带下界 >1.0，不设上界）" % ratio_ef,
		ratio_ef > 1.0, "ratio=%s" % str(ratio_ef))
	_check("C4 规模口径自描述在行（「N3000×40帧×2轮」——真机读数判读口径随行）",
		line.contains("N3000×40帧×2轮"), "line=%s" % line.right(64))
	var rx_head := RegEx.new()
	rx_head.compile("^\\[\\d+:\\d\\d 校准\\] ")
	_check("C5 行头 [m:ss 校准] 戳在位（环形日志内与 1Hz 行同构可读）",
		rx_head.search(line) != null, "head=%s" % line.left(24))


func _parse_ratio(p_line: String, p_key: String) -> float:
	# 「比A/B=15.8」型比值解析（缺段/无数字返 -1——断言判 >1.0 即 FAIL）
	var rx := RegEx.new()
	rx.compile("%s([0-9.]+)" % p_key.replace("/", "\\/"))
	var m := rx.search(p_line)
	if m == null:
		return -1.0
	return float(m.strings[1])


# ── ④ D 组：二次运行幂等 ───────────────────────────────────────────

func _test_d_idempotent() -> void:
	print("── ④ 二次运行幂等（会话完成闩） ──")
	var again: Node = CALIB_SRC.new()
	tree.root.add_child(again)             # 独立挂载（无 GameLoop 宿主特征——菜单门不拦）
	await tree.process_frame
	await tree.process_frame
	_check("D1 直挂第二实例自拆（会话完成闩——完成后二次挂载不占日志不重跑）",
		not is_instance_valid(again), "alive=%s" % str(is_instance_valid(again)))
	_check("D2 校准行数仍 ==1（幂等——不重复占环形日志）",
		_calib_line_count() == 1, "lines=%d" % _calib_line_count())
	_check("D3 会话双闩在位（session_started ∧ session_done——game_loop 挂载门/自拆门读源）",
		CALIB_SRC.session_started() and CALIB_SRC.session_done(),
		"started=%s done=%s" % [str(CALIB_SRC.session_started()), str(CALIB_SRC.session_done())])


# ── ⑤ E 组：搭车③行尾三键在位（任务1 同套回归） ────────────────────

func _test_e_tail_keys() -> void:
	print("── ⑤ 行尾三键（物步µs/派µs/渲ms——搭车③长尾分键） ──")
	var line: String = DebugStats._diag_format_line(_gl, 65000)
	_check("E1 1Hz 行含行尾三键（物步µsN 派µsN 渲msN.N——物理服务器步/派发段/渲染轴）",
		line.contains("物步µs") and line.contains("派µs") and line.contains("渲ms"),
		"tail=%s" % line.right(40))
	_check("E2 行尾序：派deferred/派drop 之后 物步µs < 派µs < 渲ms（追加位冻结——尾锚迁移后位）",
		line.find("派drop") >= 0 and line.find("派drop") < line.find("物步µs")
			and line.find("物步µs") < line.find("派µs") and line.find("派µs") < line.find("渲ms"),
		"tail=%s" % line.right(56))
	var rx := RegEx.new()
	rx.compile("渲ms\\d+\\.\\d")
	_check("E3 渲ms 均值口径一位小数（秒窗均值 ms）+ 派µs0（MENU 探针关=0 确定值——末帧直读）",
		rx.search(line) != null and line.contains("派µs0"), "tail=%s" % line.right(40))


# ── 收尾 ──────────────────────────────────────────────────────────

func _cleanup() -> void:
	GameLoop.phase0_calib_force = false    # 注入态复位（前置防呆——用例内已各自复位）
	GameLoop.phase0_calib_delay_s = 4.0
	_check("套件总项数（EXPECTED=%d——R231 假绿教训：总项数也要断言）" % EXPECTED_TOTAL,
		_pass + _fail == EXPECTED_TOTAL, "实=%d" % (_pass + _fail))
	_gl.state = GameConst.GameStatus.MENU
	DebugStats.set_process(true)
	if _gl != null:
		_gl.queue_free()
		await tree.process_frame

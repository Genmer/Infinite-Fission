# tests/runner/r233_settleus_cases.gd
# R233 T0 用例体（入口 test_r233_settleus.gd 运行时 load）。覆盖矩阵：
# ① 桩管线定数回归（bug 直接复现面）：注入带 stats()/settle_us_total() 计数器的桩，
#    已知增量序列逐拉对拍——settles 键=共享基线差分语义不变；settle_us_per=独立基线
#    每结算均值（修前分母退化 1 → 输出=每秒累计 µs，本组 A3/A4/A6 全红）；同帧两键
#    同源（per × settles == µs 窗口总量）；重复拉取增量=0 语义对两键同锁。
# ② 真件管线端到端（数量级 + 自洽 + 同窗）：真实主循环夹具（W2_gatling × 低速敌墙），
#    手动驱动 _physics_process 构造已知结算窗——diag 拉取对与管线原始计数差分同窗
#    逐位对拍（分母窗口=结N 键窗口=原始差分）；per<窗口总量（n≥2 时 bug 直接判别面）；
#    per×settles≈窗口总量（截断容差）；量级合理；弹N/弃N/快N 三个既有代表键不漂移；
#    1Hz 行尾「结µsN」段=同窗真值（用户可见症状修复直读）。
#    R233 修轮补（B9/B10）：插模拟µs 秒差分同窗自洽（模拟侧恢复+快照两遍历——MED-3/
#    QA LOW-1）+ 派deferred0/派drop0 段上行在位（HIGH-1）。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const EXPECTED_TOTAL := 18               # 套件总项数断言（收尾总项数检查之前的用例数——
                                         # r232_precache 同口径；R231 假绿教训；R233 修轮
                                         # +B9/B10）
const PER_MAGNITUDE_CAP := 1000000       # 每结均值量级上界（µs——真件单结远低于此）


class StubPipeline:
	var n: int = 0
	var us: int = 0
	func stats() -> Dictionary:
		return {"settles": n, "settle_deferred": 0, "settle_flush": 0,
			"settle_flush_dead": 0, "settle_flush_reuse": 0, "settle_overload_drop": 0}
	func settle_us_total() -> int:
		return us


var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null
var _real_pipeline: RefCounted = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	_boot_game_loop()
	DebugStats.set_process(false)          # 冻结 1Hz 采样——诊断差分窗口测试独占
	PerfGovernor.set_process(false)        # 冻结调速器档变（r232 套件同款纪律）
	await tree.process_frame
	await tree.process_frame
	_test_a_stub_fixed_math()
	await _test_b_real_pipeline_window()
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


# ── ① 桩管线定数回归（独立基线数学面） ────────────────────────────

func _test_a_stub_fixed_math() -> void:
	print("── ① 桩管线定数回归（修前本组 per 键=累计 µs 全红） ──")
	var stub := StubPipeline.new()
	_real_pipeline = _gl.pipeline
	_gl.pipeline = stub
	var pull1: Dictionary = _gl.diag_counts()
	_check("A1 首拉立基线（settles=0 且 settle_us_per=0）",
		int(pull1.get(&"settles", -1)) == 0 and int(pull1.get(&"settle_us_per", -1)) == 0,
		"settles=%s per=%s" % [str(pull1.get(&"settles")), str(pull1.get(&"settle_us_per"))])
	stub.n = 10
	stub.us = 5000
	var pull2: Dictionary = _gl.diag_counts()
	_check("A2 结N 键语义不变（窗口差分=10）", int(pull2.get(&"settles", -1)) == 10,
		"settles=%s" % str(pull2.get(&"settles")))
	_check("A3 settle_us_per=每结均值 5000÷10=500（修前=5000 累计 µs）",
		int(pull2.get(&"settle_us_per", -1)) == 500,
		"per=%s" % str(pull2.get(&"settle_us_per")))
	_check("A4 同帧两键同源（per×settles=5000=µs 窗口总量）",
		int(pull2.get(&"settle_us_per", -1)) * int(pull2.get(&"settles", -1)) == 5000,
		"积=%s" % str(int(pull2.get(&"settle_us_per", -1)) * int(pull2.get(&"settles", -1))))
	stub.n += 2
	stub.us += 900
	var pull3: Dictionary = _gl.diag_counts()
	_check("A5 第二窗逐位（settles=2 且 per=900÷2=450）",
		int(pull3.get(&"settles", -1)) == 2 and int(pull3.get(&"settle_us_per", -1)) == 450,
		"settles=%s per=%s" % [str(pull3.get(&"settles")), str(pull3.get(&"settle_us_per"))])
	_check("A6 第二窗同源自洽（per×settles=900=µs 窗口总量）",
		int(pull3.get(&"settle_us_per", -1)) * int(pull3.get(&"settles", -1)) == 900,
		"积=%s" % str(int(pull3.get(&"settle_us_per", -1)) * int(pull3.get(&"settles", -1))))
	var pull4: Dictionary = _gl.diag_counts()
	_check("A7 无增量重复拉取增量=0（两键同锁 R220 闩语义）",
		int(pull4.get(&"settles", -1)) == 0 and int(pull4.get(&"settle_us_per", -1)) == 0,
		"settles=%s per=%s" % [str(pull4.get(&"settles")), str(pull4.get(&"settle_us_per"))])
	_gl.pipeline = _real_pipeline


# ── ② 真件管线端到端（同窗对拍 + 数量级 + 既有键不漂移） ──────────

func _test_b_real_pipeline_window() -> void:
	print("── ② 真件管线端到端（手动驱动 _physics_process 已知结算窗） ──")
	var fixture_ok := _fixture_combat()
	_check("B0 夹具就绪（真件管线+gatling 挂载+敌墙在场）", fixture_ok, "")
	if not fixture_ok:
		return
	await _wait_wall(800)                  # 暖机：自然帧跑战斗（敌墙接火）
	var pull1: Dictionary = _gl.diag_counts()
	var n_a := _raw_n()
	var us_a := _raw_us()
	_drive_ticks(600, 30, n_a)             # 手动驱动至窗口内 ≥30 结算（帽 600 帧=10s 模拟）
	var n_b := _raw_n()
	var us_b := _raw_us()
	var n_win := n_b - n_a
	var us_win := us_b - us_a
	var pull2: Dictionary = _gl.diag_counts()
	_check("B1 窗口结算数充足（n=%d ≥30——夹具有效性前置）" % n_win, n_win >= 30, "n_win=%d" % n_win)
	var per2 := int(pull2.get(&"settle_us_per", -1))
	_check("B2 分母窗口一致（pull.settles=%d == 原始差分 n_b-n_a）" % int(pull2.get(&"settles", -1)),
		int(pull2.get(&"settles", -1)) == n_win, "pull=%s raw=%d" % [str(pull2.get(&"settles")), n_win])
	_check("B3 分子分母同窗逐位（per=%d == %d÷%d=%d）" % [per2, us_win, n_win, int(float(us_win) / float(maxi(n_win, 1)))],
		per2 == int(float(us_win) / float(maxi(n_win, 1))), "per=%d 期望=%d" % [per2, int(float(us_win) / float(maxi(n_win, 1)))])
	_check("B4 每结均值<窗口总量（per=%d < %d——修前 per==累计 µs 恒红）" % [per2, us_win],
		n_win >= 2 and per2 > 0 and per2 < us_win, "per=%d us_win=%d" % [per2, us_win])
	_check("B5 自洽 per×settles≈µs 窗口（截断容差 <per）",
		per2 * n_win <= us_win and us_win - per2 * n_win < maxi(per2, 1),
		"积=%d us_win=%d" % [per2 * n_win, us_win])
	_check("B6 量级合理（0 < per=%d < %d µs）" % [per2, PER_MAGNITUDE_CAP],
		per2 > 0 and per2 < PER_MAGNITUDE_CAP, "per=%d" % per2)
	var legacy_ok := pull2.has(&"projectiles") and pull2.has(&"settles_dropped") \
		and pull2.has(&"pfast_live") and int(pull2[&"projectiles"]) >= 0 \
		and int(pull2[&"settles_dropped"]) >= 0 and int(pull2[&"pfast_live"]) >= 0
	_check("B7 既有代表键不漂移（弹N projectiles/弃N settles_dropped/快N pfast_live 在场且 ≥0）",
		legacy_ok, "")
	# 第二窗：格式化行尾「结µsN」段 = 同窗真值（1Hz 行用户可见症状修复直读）
	_drive_ticks(600, 30, n_b)
	var n_c := _raw_n()
	var us_c := _raw_us()
	var line: String = String(DebugStats.call("_diag_format_line", _gl, Time.get_ticks_msec()))
	var tok := _tail_token(line, "结µs")
	var expect_per := int(float(us_c - us_b) / float(maxi(n_c - n_b, 1)))
	_check("B8 1Hz 行尾「结µsN」=同窗真值 %d（行读 %s——修前=累计 µs 伪读数）" % [expect_per, tok if tok != "" else "缺段"],
		tok != "" and int(tok) == expect_per and int(tok) > 0,
		"行读=%s 期望=%d" % [tok, expect_per])
	# R233 修轮回归（HIGH-1/MED-3）：新行尾键——插模拟µs 同窗自洽 + 派deferred/派drop 段上行
	var raw_ip_a: int = _gl.ip_sim_us_total
	_drive_ticks(60, 1, n_c)               # 同步驱动 ≤60 帧（窗口=快照遍历计量面；headless 谓词关恢复不计）
	var raw_ip_b: int = _gl.ip_sim_us_total
	var line_b: String = String(DebugStats.call("_diag_format_line", _gl, Time.get_ticks_msec()))
	var tok_sim := _tail_token(line_b, "插模拟µs")
	_check("B9 插模拟µs 秒差分自洽（行读 %s == 原始累计差分 %d——同窗对拍；关态读数=快照遍历成本直读）" % [tok_sim if tok_sim != "" else "缺段", raw_ip_b - raw_ip_a],
		tok_sim != "" and int(tok_sim) == raw_ip_b - raw_ip_a,
		"行读=%s rawΔ=%d" % [tok_sim, raw_ip_b - raw_ip_a])
	_check("B10 1Hz 行尾含「派deferred0 派drop0」段（桌面 headless 帽 48/步非瓶颈 → 确定零；HIGH-1 真机取证通道上行在位）",
		line_b.contains("派deferred0 派drop0"), "tail=%s" % line_b.right(36))


# ── 夹具 ──────────────────────────────────────────────────────────

func _fixture_combat() -> bool:
	_gl.state = GameConst.GameStatus.PLAYING
	var player: Node2D = _gl.get("player")
	player.set("xp_need", 1.0e12)          # 防升级开窗（选卡窗冻结结算）
	player.set("max_hp", 1.0e12)
	player.set("hp", 1.0e12)
	player.global_position = Vector2(360.0, 1050.0)
	var registry = _gl.get("registry")
	var gatling = player.call("add_weapon", registry.call("get_weapon", &"W2_gatling"))
	var epool = _gl.get("pools").get(&"enemy")
	var spawner = _gl.get("spawner")
	_spawn_wave(epool, spawner, 32, 1500.0)   # 高血敌墙——窗内不死光、持续接弹持续结算
	var pipeline_ok: bool = _gl.pipeline != null and _gl.pipeline.has_method(&"settle_us_total")
	return gatling != null and pipeline_ok and (spawner.get("active") as Array).size() >= 32


func _spawn_wave(p_epool, p_spawner, p_n: int, p_hp: float) -> void:
	var data_script: GDScript = load("res://scripts/core/data/resources/enemy_data.gd")
	for i in range(p_n):
		var e: Node2D = p_epool.call("acquire")
		var d: Resource = data_script.new()
		d.set("id", &"E_R233_SETTLEUS")
		d.set("display_name", "R233_SETTLEUS")
		d.set("hp_base", p_hp)
		d.set("spd_base", 0.0)
		d.set("dmg_base", 0.0)
		d.set("exp_base", 1.0)
		d.set("hitbox_r", 14.0)
		d.set("resist", [0.0, 0.0, 0.0, 0.0])
		e.call("spawn", d, 1, 0)
		e.set("_fade_left", 0.0)
		e.global_position = Vector2(120.0 + 40.0 * (i % 8), 300.0 + 55.0 * (i / 8))
		p_spawner.get("active").append(e)
	_gl.get("enemy_grid").call("rebuild", p_spawner.get("active"))


func _raw_n() -> int:
	# 结N 原始真源直读（不经 diag 基线——外部对拍锚）
	return int((_gl.pipeline.call(&"stats") as Dictionary).get("settles", 0))


func _raw_us() -> int:
	return int(_gl.pipeline.call(&"settle_us_total"))


func _drive_ticks(p_max: int, p_need_settles: int, p_base_n: int) -> int:
	# 手动驱动 _physics_process（1/60 定步）至窗口新增结算数达标（同步循环——
	# 引擎不会插帧，diag 基线窗口与原始计数窗口严格同区间）
	var ticks := 0
	while ticks < p_max and _raw_n() - p_base_n < p_need_settles:
		_gl._physics_process(1.0 / 60.0)
		ticks += 1
	return ticks


func _wait_wall(p_ms: int) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < p_ms:
		await tree.process_frame


func _tail_token(p_line: String, p_key: String) -> String:
	# 行内 p_key 后连续数字段（「 结µs39」→ "39"；QA1 探针同款解析）
	var j := p_line.find(p_key)
	if j < 0:
		return ""
	var k := j + p_key.length()
	while k < p_line.length():
		var c := p_line.unicode_at(k)
		if c < 48 or c > 57:
			break
		k += 1
	return p_line.substr(j + p_key.length(), k - j - p_key.length())


# ── 收尾 ──────────────────────────────────────────────────────────

func _cleanup() -> void:
	_check("套件总项数（EXPECTED=%d——R231 假绿教训：总项数也要断言）" % EXPECTED_TOTAL,
		_pass + _fail == EXPECTED_TOTAL, "实=%d" % (_pass + _fail))
	if _real_pipeline != null:
		_gl.pipeline = _real_pipeline
	_gl.state = GameConst.GameStatus.MENU
	DebugStats.set_process(true)
	PerfGovernor.set_process(true)
	if _gl != null:
		_gl.queue_free()
		await tree.process_frame

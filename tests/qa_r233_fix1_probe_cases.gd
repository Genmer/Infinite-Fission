# tests/qa_r233_fix1_probe_cases.gd
# R233 修复轮 QA 探针用例体（qa_r233_fix1_probe.gd 运行时 load）。
# 复核面：
#   ① HIGH-1：1Hz 行尾「派deferredN 派dropN」真实拼装（计数器注入 → 行读=注入值）、
#      重复拉取增量=0（闩）、两键互不共享基线、与 帽N（_deathpop_capped_delta 本类侧
#      先例）及 GameLoop 侧键互不干扰（计数器全仓唯一消费口=_diag_dispatch_delta）。
#   ② MED-3：关态（sim30_override=-2 强制关）下 插模拟µs=快照遍历实际成本直读——
#      同窗对拍（diag_counts 键 == ip_sim_us_total 原始差分）、量级合理（每帧 0-2000µs
#      量级带）、重复拉取增量=0；恢复遍历谓词关不计（挂点 if sim30_effective() 门内）。
#   ③ 真实 1Hz 采样器行（非直调拼行）：等墙钟窗后读 _diag_lines 末行，验证行尾六段
#      次序（裁N 快N 结µsN 插µsN 插模拟µsN 派deferredN 派dropN）与关态
#      插模拟µs 真实非零读数（MENU 期快照遍历 T7 无条件 → 有实体即有成本）。
# 探针纪律：夹具敌墙保留至收尾整树释放（池生命周期正道——不外部 queue_free 单体，
# 首版探针曾因外部释放触发 diag_counts 空转读 is_instance_valid 缺失面的噪音，与本刀无关）。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const EXPECTED_TOTAL := 12               # 套件总项数断言（R231 假绿教训——不含本项自身）

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	_boot_game_loop()
	DebugStats.set_process(false)          # 冻结 1Hz 采样——差分窗口测试独占（r233 套件同款纪律）
	PerfGovernor.set_process(false)
	await tree.process_frame
	await tree.process_frame
	_test_high1_dispatch_line()
	await _test_med3_off_state()
	await _test_real_sampler_line()
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


# ── ① HIGH-1：派deferred/派drop 行拼装 + 闩 + 独立基线 ──────────────

func _test_high1_dispatch_line() -> void:
	print("── ① HIGH-1 派发两键行拼装（计数器注入 → 行读真值） ──")
	var line1: String = String(DebugStats.call("_diag_format_line", _gl, Time.get_ticks_msec()))
	_check("H1 首拉立基线（行尾 派deferred0 派drop0）",
		line1.contains("派deferred0 派drop0"), "tail=%s" % line1.right(40))
	DebugStats.count(&"dispatch_deferred", 37)
	DebugStats.count(&"dispatch_stale_drop", 5)
	var line2: String = String(DebugStats.call("_diag_format_line", _gl, Time.get_ticks_msec()))
	_check("H2 行拼装真值（注入 37/5 → 行读 派deferred37 派drop5）",
		line2.contains("派deferred37 派drop5"), "tail=%s" % line2.right(44))
	var line3: String = String(DebugStats.call("_diag_format_line", _gl, Time.get_ticks_msec()))
	_check("H3 重复拉取增量=0（零注入第二拉 → 派deferred0 派drop0——闩语义）",
		line3.contains("派deferred0 派drop0"), "tail=%s" % line3.right(40))
	DebugStats.count(&"dispatch_deferred", 11)
	var line4: String = String(DebugStats.call("_diag_format_line", _gl, Time.get_ticks_msec()))
	_check("H4 两键独立基线（单键注入 11 → 派deferred11 派drop0，无交叉消费）",
		line4.contains("派deferred11 派drop0"), "tail=%s" % line4.right(40))
	DebugStats.count(&"dispatch_deferred", 7)
	DebugStats.count(&"deathpop_capped", 3)
	var line5: String = String(DebugStats.call("_diag_format_line", _gl, Time.get_ticks_msec()))
	_check("H5 与帽N 独立（帽3 与 派deferred7 同行各自真值——本类侧两差分口基线分立）",
		line5.contains("帽3") and line5.contains("派deferred7 派drop0"), "tail=%s" % line5.right(56))


# ── ② MED-3：关态插模拟µs=快照遍历成本直读 ─────────────────────────

func _test_med3_off_state() -> void:
	print("── ② MED-3 关态（sim30_override=-2）插模拟µs 读数 ──")
	GameLoop.sim30_override = -2           # 强制关（谓词关=恢复遍历零执行，快照 T7 无条件）
	var fixture_ok := _fixture_combat()
	_check("M1 夹具就绪（关态敌墙 48 在场）", fixture_ok, "")
	if fixture_ok:
		var pull_x: Dictionary = _gl.diag_counts()   # 立差分基线（首拉窗丢弃）
		var raw_a: int = _gl.ip_sim_us_total
		for i in range(120):
			_gl._physics_process(1.0 / 60.0)
		var raw_b: int = _gl.ip_sim_us_total
		var pull_y: Dictionary = _gl.diag_counts()
		var delta_key := int(pull_y.get(&"ip_sim_us", -1))
		var per_frame := float(raw_b - raw_a) / 120.0
		_check("M2 同窗自洽（键值 %d == 原始累计差分 %d——120 驱动帧同步窗）" % [delta_key, raw_b - raw_a],
			delta_key == raw_b - raw_a,
			"key=%d rawΔ=%d" % [delta_key, raw_b - raw_a])
		_check("M3 关态读数量级合理（每帧 %d.%02dµs ∈ (0, 2000)——快照遍历实际成本直读，恢复遍历谓词关不计）"
			% [int(per_frame), int(fmod(per_frame, 1.0) * 100.0)],
			per_frame > 0.0 and per_frame < 2000.0,
			"per_frame=%.2f rawΔ=%d" % [per_frame, raw_b - raw_a])
		var pull_z: Dictionary = _gl.diag_counts()
		_check("M4 重复拉取增量=0（闩语义——零驱动第二拉）",
			int(pull_z.get(&"ip_sim_us", -1)) == 0, "val=%s" % str(pull_z.get(&"ip_sim_us", "?")))
	GameLoop.sim30_override = -1
	_gl.state = GameConst.GameStatus.MENU   # 夹具保留（池生命周期正道）——③ 组 MENU 窗用


# ── ③ 真实 1Hz 采样器行（非直调） ───────────────────────────────────

func _test_real_sampler_line() -> void:
	print("── ③ 真实 1Hz 采样器行（等墙钟窗读 _diag_lines 末行） ──")
	DebugStats.set_process(true)           # 解冻采样器——走真实 _diag_maybe_sample 通道
	await _wait_wall(2300)                 # ≥2 个采样窗（首采 + 1s 节拍——末行必为新窗）
	var lines: Array = DebugStats.get("_diag_lines")
	var last: String = ""
	if not lines.is_empty():
		last = String(lines[lines.size() - 1])
	var order_ok: bool = last.find("裁") >= 0 and last.find("裁") < last.find("快") \
		and last.find("快") < last.find("结µs") and last.find("结µs") < last.find("插µs") \
		and last.find("插µs") < last.find("插模拟µs") \
		and last.find("插模拟µs") < last.find("派deferred") \
		and last.find("派deferred") < last.find("派drop")
	_check("R1 真实采样行行尾六段次序（裁N 快N 结µsN 插µsN 插模拟µsN 派deferredN 派dropN）",
		order_ok, "tail=%s" % last.right(64))
	_check("R2 真实采样行含 派deferred0 派drop0（零注入窗——闩语义在真实通道同样成立）",
		last.contains("派deferred0 派drop0"), "tail=%s" % last.right(44))
	var sim_tok := _tail_token(last, "插模拟µs")
	_check("R3 真实采样行 插模拟µs 关态读数非零（MENU 期 48 敌快照遍历 T7 无条件成本，"
			+ "读数=%s——量级记录供报告）" % sim_tok,
		sim_tok != "" and sim_tok.is_valid_int() and int(sim_tok) > 0, "tok=%s" % sim_tok)


# ── 夹具 ──────────────────────────────────────────────────────────

func _fixture_combat() -> bool:
	_gl.state = GameConst.GameStatus.PLAYING
	var player: Node2D = _gl.get("player")
	player.set("xp_need", 1.0e12)
	player.set("max_hp", 1.0e12)
	player.set("hp", 1.0e12)
	var epool = _gl.get("pools").get(&"enemy")
	var spawner = _gl.get("spawner")
	var data_script: GDScript = load("res://scripts/core/data/resources/enemy_data.gd")
	for i in range(48):
		var e: Node2D = epool.call("acquire")
		var d: Resource = data_script.new()
		d.set("id", &"E_R233_FIX1")
		d.set("display_name", "R233_FIX1")
		d.set("hp_base", 1.0e9)
		d.set("spd_base", 0.0)
		d.set("dmg_base", 0.0)
		d.set("exp_base", 1.0)
		d.set("hitbox_r", 14.0)
		d.set("resist", [0.0, 0.0, 0.0, 0.0])
		e.call("spawn", d, 1, 0)
		e.set("_fade_left", 0.0)
		e.global_position = Vector2(120.0 + 40.0 * (i % 8), 300.0 + 55.0 * (i / 8))
		spawner.get("active").append(e)
	_gl.get("enemy_grid").call("rebuild", spawner.get("active"))
	return (spawner.get("active") as Array).size() >= 48


func _wait_wall(p_ms: int) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < p_ms:
		await tree.process_frame


func _tail_token(p_line: String, p_key: String) -> String:
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
	GameLoop.sim30_override = -1
	_gl.state = GameConst.GameStatus.MENU
	DebugStats.set_process(true)
	PerfGovernor.set_process(true)
	if _gl != null:
		_gl.queue_free()
		await tree.process_frame

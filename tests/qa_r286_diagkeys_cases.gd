# tests/qa_r286_diagkeys_cases.gd（R286 用例体——入口运行时加载）
# 覆盖（R285 设计修订 v3 p0c 移交项收口 + R286 新增）：
#   k1 行格式冻结：R286 九键（命µs/提µs/灭µs/回µs/ipµs/段和µs/弹段µs/网段µs/敌段µs）
#      子串逐位在场，位在 渲峰ms 之后、尖峰段之前/行尾；既有 R271 子串不动（前缀保持）。
#   k2 五桶记账链路：手动 begin/end 夹 ≥2ms → 窗读数 ≥1000µs（桶器往返——真机/台架
#      >0 语义由 deeprepro G1 生效检查与真机行承担，此处锁链路活）。
#   k3 段窗和往返：stage_probe_enabled=true + PLAYING 直驱 _physics_process×N →
#      段和µs>0 ∧ 段和 ≥ 弹段+网段+敌段（各自 ≥0）∧ diag_reset_stage_win_sums 归零。
#   k4 S9 出厂态：GameLoop.shortcircuit_proj_stage 默认 false（产品行为逐位——真短路
#      生效面由 deeprepro S9 臂承担）。
# 纪律：不写 Meta._settings（零污染）；1Hz 采样窗经 _diag_last_ms 推界防中途复位
#（直读私有累计器先例：qa_r271_stepacct_cases）。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const DRIVE_STEPS := 30

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: Node = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	await _boot()
	_k1_line_format()
	_k2_bucket_roundtrip()
	await _k3_stage_window_sums()
	_k4_s9_factory_state()
	_teardown()


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


func _push_sample_gate() -> void:
	# 1Hz 采样界推离（测试窗 < 1s——防 _diag_maybe_sample 中途复位累计器）
	DebugStats._diag_last_ms = Time.get_ticks_msec()


func _boot() -> void:
	print("── boot（main.tscn 真链 → MENU 冻结） ──")
	var main: Node = load(MAIN_SCENE).instantiate()
	tree.root.add_child(main)
	_gl = tree.root.get_node_or_null("Main")
	if _gl == null:
		for c in tree.root.get_children():
			if c != null and c.has_method("diag_counts"):
				_gl = c
				break
	_gl.state = GameConst.GameStatus.MENU
	await tree.process_frame
	await tree.process_frame


# ── k1：行格式冻结 ──────────────────────────────────────────────────

func _k1_line_format() -> void:
	print("── k1 行格式冻结（R286 九键上墙） ──")
	_push_sample_gate()
	var line := DebugStats._diag_format_line(_gl, Time.get_ticks_msec())
	var ok286 := true
	for k in ["命µs", "提µs", "灭µs", "回µs", "ipµs", "段和µs", "弹段µs", "网段µs", "敌段µs"]:
		if not line.contains(" %s" % k):
			ok286 = false
	_check("k1 R286 九键子串逐位在场", ok286, line.right(120))
	# 既有 R271 子串保持（前缀不动——渲峰ms 仍在九键之前）
	var ok271 := true
	for k in ["步µs", "隙µs", "延早µs", "延渲µs", "延峰µs", "渲帧", "呈帧", "渲峰ms"]:
		if not line.contains(k):
			ok271 = false
	_check("k1 R271 键子串保持在场", ok271, line.right(110))
	var i_peak271 := line.find(" 渲峰ms")
	var i_ming := line.find(" 命µs")
	var i_peak_spike := line.find(" 尖峰")
	_check("k1 九键位在 渲峰ms 之后、尖峰段之前/行尾",
		i_peak271 >= 0 and i_ming > i_peak271 and (i_peak_spike < 0 or i_ming < i_peak_spike),
		"渲峰ms@%d 命µs@%d 尖峰@%d" % [i_peak271, i_ming, i_peak_spike])
	# 键序冻结（九键内部相对序）
	var order := [" 命µs", " 提µs", " 灭µs", " 回µs", " ipµs", " 段和µs", " 弹段µs", " 网段µs", " 敌段µs"]
	var ok_order := true
	for i in range(order.size() - 1):
		if line.find(order[i]) < 0 or line.find(order[i + 1]) < 0 \
				or line.find(order[i]) > line.find(order[i + 1]):
			ok_order = false
	_check("k1 九键内部键序冻结（命提灭回ip 段和 弹网敌）", ok_order, line.right(120))


# ── k2：五桶记账链路 ────────────────────────────────────────────────

func _k2_bucket_roundtrip() -> void:
	print("── k2 五桶记账链路（begin/end → 窗读数） ──")
	_push_sample_gate()
	DebugStats._diag_reset_window_acc()
	for key in [&"hit_collect", &"hit_flush", &"death_flush", &"recycle", &"ip_pass"]:
		DebugStats.bucket_begin(key)
		OS.delay_msec(2)
		DebugStats.bucket_end(key)
	var ok_all := true
	var detail := ""
	for key in [&"hit_collect", &"hit_flush", &"death_flush", &"recycle", &"ip_pass"]:
		var v := int(DebugStats.diag_bucket_window_us(key))
		if v < 1000:
			ok_all = false
		detail += "%s=%d " % [String(key), v]
	_check("k2 五桶 begin/end 夹 2ms → 窗读数 ≥1000µs（链路活）", ok_all, detail)


# ── k3：段窗和往返 ──────────────────────────────────────────────────

func _k3_stage_window_sums() -> void:
	print("── k3 段窗和（探针开 + PLAYING 直驱 %d 步） ──" % DRIVE_STEPS)
	_push_sample_gate()
	DebugStats._diag_reset_window_acc()
	_gl.diag_reset_stage_win_sums()
	_check("k3 复位口存在（diag_reset_stage_win_sums）",
		_gl.has_method("diag_reset_stage_win_sums"), "")
	if not _gl.start_run():
		_check("k3 start_run 进场（PLAYING 真链——deeprepro 同款）", false, "start_run 失败")
		return
	_gl.stage_probe_enabled = true
	for i in range(DRIVE_STEPS):
		_gl._physics_process(1.0 / 60.0)
		await tree.process_frame
	var sum_us := int(_gl.get("_stage_win_sum_us"))
	var proj_us := int(_gl.get("_stage_win_proj_us"))
	var grid_us := int(_gl.get("_stage_win_grid_us"))
	var enemy_us := int(_gl.get("_stage_win_enemy_us"))
	_check("k3 段和µs > 0（PLAYING 段表累计）", sum_us > 0,
		"段和=%d 弹段=%d 网段=%d 敌段=%d" % [sum_us, proj_us, grid_us, enemy_us])
	_check("k3 段和 ≥ 弹段+网段+敌段（全段包含三段分键）",
		sum_us >= proj_us + grid_us + enemy_us,
		"和=%d 三段和=%d" % [sum_us, proj_us + grid_us + enemy_us])
	_gl.state = GameConst.GameStatus.MENU
	_gl.stage_probe_enabled = false
	_gl.diag_reset_stage_win_sums()
	_check("k3 复位归零（四累计器清零）",
		int(_gl.get("_stage_win_sum_us")) == 0 and int(_gl.get("_stage_win_proj_us")) == 0
			and int(_gl.get("_stage_win_grid_us")) == 0 and int(_gl.get("_stage_win_enemy_us")) == 0,
		"复位后=%d/%d/%d/%d" % [int(_gl.get("_stage_win_sum_us")),
			int(_gl.get("_stage_win_proj_us")), int(_gl.get("_stage_win_grid_us")),
			int(_gl.get("_stage_win_enemy_us"))])


# ── k4：S9 出厂态 ───────────────────────────────────────────────────

func _k4_s9_factory_state() -> void:
	print("── k4 S9 出厂态 ──")
	_check("k4 GameLoop.shortcircuit_proj_stage 出厂 false（产品行为逐位）",
		not GameLoop.shortcircuit_proj_stage, "值=%s" % str(GameLoop.shortcircuit_proj_stage))


func _teardown() -> void:
	tree.paused = false
	RunSave.clear()
	if _gl != null:
		_gl.free()
		_gl = null
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)
	print("验收汇总：%d/%d 通过" % [_pass, _pass + _fail])

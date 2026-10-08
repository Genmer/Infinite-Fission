# tests/runner/r209_wave_left_cases.gd
# R209 用例体：HUD 波次徽章「余 N」副行——结构/计数口径/出生不跳变/击杀掉号/
# 1Hz 兜底/wave_started 事件链/清零隐现/组兜底。口径 = spawn_queue + active
#（≤8/帧出生节流下含队列才单调递减——只数 active 会随出生跳变）。
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
	_test_1_structure()
	_test_2_birth_no_jump()
	await _test_3_kill_decrement()
	_test_4_stats_fallback()
	_test_5_wave_started_chain()
	_test_6_zero_hidden()
	_test_7_group_fallback()
	_teardown_game_loop()
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
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "R209GameLoopUnderTest"
	tree.get_root().add_child(_gl)
	_gl.state = GameConst.GameStatus.MENU
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	_gl.start_run()


func _teardown_game_loop() -> void:
	tree.paused = false
	RunSave.clear()
	if _gl != null:
		_gl.free()
		_gl = null


func _hud() -> HUD:
	return _gl.hud


func _sum() -> int:
	# 口径真值：待出生队列 + 场上活跃
	return _gl.spawner.spawn_queue.size() + _gl.spawner.active.size()


func _left_n() -> int:
	# 从副行文本反解数字（「余 N」）
	var t: String = _hud()._wave_left_label.text
	return int(t.trim_prefix("余 ").to_int()) if t.begins_with("余 ") else -1


# ── ① 结构：在位/几何/字号 ──
func _test_1_structure() -> void:
	print("── ① 副行结构 ──")
	var hud: HUD = _hud()
	var lbl: Label = hud._wave_left_label
	_check("在位且命名 WaveLeftText（find_child 可达）",
		lbl != null and hud.find_child("WaveLeftText", true, false) == lbl,
		"lbl=%s" % str(lbl))
	if lbl == null:
		return
	_check("与波次文本同容器（徽章圆面板内）",
		lbl.get_parent() == hud._wave_label.get_parent(),
		"p=%s" % str(lbl.get_parent()))
	_check("几何：y78/x0 居中带宽 106，行高随字体自然钳制（13pt≈23px）且底边 ≤102 入圆",
		absf(lbl.position.y - 78.0) < 0.01 and absf(lbl.position.x) < 0.01
			and absf(lbl.size.x - 106.0) < 0.01
			and lbl.size.y >= 18.0 and lbl.position.y + lbl.size.y <= 102.0,
		"pos=%s size=%s" % [str(lbl.position), str(lbl.size)])
	_check("样式：13pt 居中（同 WAVE 帽行规格）",
		lbl.get_theme_font_size(&"font_size") == 13
			and lbl.horizontal_alignment == HORIZONTAL_ALIGNMENT_CENTER,
		"fs=%d al=%d" % [lbl.get_theme_font_size(&"font_size"), lbl.horizontal_alignment])
	hud._refresh_wave_left()
	_check("文本格式「余 N」且与口径真值一致（入队+活跃之和）",
		_hud()._wave_left_label.text == "余 %d" % _sum()
			and _left_n() == _sum(),
		"text=%s sum=%d" % [_hud()._wave_left_label.text, _sum()])


# ── ② 出生不跳变：队列→活跃总和恒定 ──
func _test_2_birth_no_jump() -> void:
	print("── ② 出生节流不跳变 ──")
	var hud: HUD = _hud()
	var n0: int = _sum()
	_gl.spawner.enqueue({"data_id": "E1_grunt", "wave": _gl.wave_director.current_wave, "tags": 0})
	hud._refresh_wave_left()
	_check("入队 +1 立即可见（余敌含未出生）",
		_left_n() == n0 + 1, "text=%s 期望 %d" % [_hud()._wave_left_label.text, n0 + 1])
	var q_before: int = _gl.spawner.spawn_queue.size()
	_gl.spawner.tick(0.016, _gl.enemy_grid)
	_gl.spawner.tick(0.016, _gl.enemy_grid)
	var moved: bool = _gl.spawner.spawn_queue.size() < q_before \
		and _gl.spawner.active.size() > 0
	_check("节流出队确实发生（队列减、场上增——否则用例空转）", moved,
		"q %d→%d a=%d" % [q_before, _gl.spawner.spawn_queue.size(), _gl.spawner.active.size()])
	hud._refresh_wave_left()
	_check("出生后数字不动（队列→活跃平移，总和不变=不随 ≤8/帧节流跳变）",
		_left_n() == n0 + 1, "text=%s 期望 %d" % [_hud()._wave_left_label.text, n0 + 1])


# ── ③ 击杀掉号：真实死亡链（_on_died → enemy_killed → 双订阅方） ──
func _test_3_kill_decrement() -> void:
	print("── ③ 击杀掉号 ──")
	await tree.process_frame          # 出世渐显等帧内状态落定再杀
	var hud: HUD = _hud()
	hud._refresh_wave_left()
	var n1: int = _sum()
	_check("场上确有可杀目标（前置）", _gl.spawner.active.size() > 0 and n1 > 0,
		"active=%d sum=%d" % [_gl.spawner.active.size(), n1])
	var victim: Node2D = _gl.spawner.active.back()
	victim._on_died()
	_check("杀一只立即掉一号（enemy_killed 事件驱动；HUD 订阅晚于 spawner 归还）",
		_left_n() == n1 - 1,
		"text=%s 期望 %d" % [_hud()._wave_left_label.text, n1 - 1])
	_check("与口径真值同步（无残差）", _left_n() == _sum(),
		"text=%d sum=%d" % [_left_n(), _sum()])


# ── ④ 1Hz 兜底：非击杀增量走 refresh_stats ──
func _test_4_stats_fallback() -> void:
	print("── ④ 1Hz 兜底 ──")
	var hud: HUD = _hud()
	var n: int = _sum()
	_gl.spawner.enqueue({"data_id": "E1_grunt", "wave": _gl.wave_director.current_wave, "tags": 0})
	hud.refresh_stats()
	_check("refresh_stats 兜底刷新（伴生/硬上限叠波等非击杀增量 ≤1s 内可见）",
		_left_n() == n + 1, "text=%s 期望 %d" % [_hud()._wave_left_label.text, n + 1])


# ── ⑤ wave_started 事件链：start_wave → enqueue → 发射 → 副行整队可见 ──
func _test_5_wave_started_chain() -> void:
	print("── ⑤ wave_started 链 ──")
	var nxt: int = _gl.wave_director.current_wave + 1
	_gl.wave_director.start_wave(nxt)
	_check("开波即显示整队余敌（发射在 enqueue 后——不用等 1Hz）",
		_left_n() == _sum() and _sum() > 0,
		"text=%s sum=%d" % [_hud()._wave_left_label.text, _sum()])
	_check("波次主行不受影响（仍 第N波/无尽N 形态）",
		_hud()._wave_label.text.begins_with("第 ") or _hud()._wave_label.text.begins_with("无尽 "),
		"text=%s" % _hud()._wave_label.text)


# ── ⑥ 清零隐现 ──
func _test_6_zero_hidden() -> void:
	print("── ⑥ 清零隐现 ──")
	var hud: HUD = _hud()
	_gl.spawner.spawn_queue.clear()
	for e in _gl.spawner.active.duplicate():
		_gl.spawner.on_enemy_killed(e)
	hud._refresh_wave_left()
	_check("余 0 时副行隐藏（波间空窗不占徽章下缘）",
		_sum() == 0 and _hud()._wave_left_label.text == "余 0"
			and not _hud()._wave_left_label.visible,
		"sum=%d text=%s vis=%s" % [_sum(), _hud()._wave_left_label.text,
			str(_hud()._wave_left_label.visible)])
	_gl.spawner.enqueue({"data_id": "E1_grunt", "wave": _gl.wave_director.current_wave, "tags": 0})
	hud._refresh_wave_left()
	_check("余 >0 恢复显示", _hud()._wave_left_label.visible and _left_n() == 1,
		"text=%s vis=%s" % [_hud()._wave_left_label.text, str(_hud()._wave_left_label.visible)])


# ── ⑦ 组兜底：setup 注入缺失 ──
func _test_7_group_fallback() -> void:
	print("── ⑦ 组兜底 ──")
	var hud: HUD = _hud()
	var saved: Node = hud._spawner
	_gl.spawner.enqueue({"data_id": "E1_grunt", "wave": _gl.wave_director.current_wave, "tags": 0})
	hud._spawner = null
	hud._refresh_wave_left()
	_check("注入缺失走 enemy_spawner 组兜底（仍读到队列增量）",
		_left_n() == _sum() and _sum() > 0,
		"text=%s sum=%d" % [_hud()._wave_left_label.text, _sum()])
	hud._spawner = saved
	hud._refresh_wave_left()
	_check("恢复注入后口径不漂", _left_n() == _sum(),
		"text=%d sum=%d" % [_left_n(), _sum()])

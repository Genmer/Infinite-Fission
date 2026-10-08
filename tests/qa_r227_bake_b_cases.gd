# tests/qa_r227_bake_b_cases.gd
# QA-R227 探针 B 用例体。冷进程 static 顺序敏感：boot 后零 await 先拍队列 → 零烤链。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const GLYPH_N := 12

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_boot_game_loop()
	_test_1_queue_order()
	await _test_2_start_run_no_bake()
	await _test_3_playing_frames_no_bake()
	await _test_4_continue_endless_no_bake()
	await _test_5_restart_run_bakes_and_idempotent()
	_teardown()
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
	_gl.name = "QA_R227_B_GameLoop"
	tree.get_root().add_child(_gl)


# ── ① 队列序独立复测（boot 建队满态、零 await 未泵） ────────────────
func _test_1_queue_order() -> void:
	print("── ① 字形 cell 队首前移（独立复测） ──")
	var q: Array = _gl._tex_prewarm_queue
	var head_ok := q.size() >= GLYPH_N
	for i in range(GLYPH_N):
		if int(q[i].get(&"op", -1)) != 6 or int(q[i].get(&"cell", -1)) != i:
			head_ok = false
			break
	_check("①a 前 12 项 = op:6 cell 0..11（队首前移）", head_ok,
		"head2=%s" % str(q.slice(0, 2)))
	_check("①b 第 13 项起才是贴图域 op:2（共享域紧随）",
		q.size() > GLYPH_N and int(q[GLYPH_N].get(&"op", -1)) == 2
			and q[GLYPH_N].has(&"fill"),
		"item13=%s" % str(q[GLYPH_N]))
	_check("①c 冷图集（built=0 未 ready——后续零烤链前提）",
		PopupGlyphAtlas.built_count() == 0 and not PopupGlyphAtlas.ready())


# ── ② override=0 强制不补：start_run 真链不开烤 ────────────────────
func _test_2_start_run_no_bake() -> void:
	print("── ② start_run（override=0 强制不补） ──")
	PopupGlyphAtlas.runstart_bake_override = 0
	_gl.state = GameConst.GameStatus.MENU
	var ok: bool = _gl.start_run()
	_check("②a start_run 成功且零烤制（built=0）",
		ok and _gl.state == GameConst.GameStatus.PLAYING
			and PopupGlyphAtlas.built_count() == 0,
		"ok=%s built=%d" % [str(ok), PopupGlyphAtlas.built_count()])


# ── ③ PLAYING 帧无烤制路径（门开 override=1 仍零烤——B 红线运行时证据） ──
func _test_3_playing_frames_no_bake() -> void:
	print("── ③ PLAYING 帧零烤制（门开仍不烤） ──")
	PopupGlyphAtlas.runstart_bake_override = 1   # 门全开：PLAYING 帧若漏烤必被抓住
	var q_before: int = _gl._tex_prewarm_queue.size()
	for i in range(5):
		await tree.process_frame
	_check("③a PLAYING 5 帧后零烤制（built=0、未 ready）",
		PopupGlyphAtlas.built_count() == 0 and not PopupGlyphAtlas.ready(),
		"built=%d" % PopupGlyphAtlas.built_count())
	_check("③b PLAYING 帧不消化预热队列（队长不变=%d——op:6 只在 MENU 泵）" % q_before,
		_gl._tex_prewarm_queue.size() == q_before)


# ── ④ continue_endless 不挂补烤（F：非新局口径） ────────────────────
func _test_4_continue_endless_no_bake() -> void:
	print("── ④ continue_endless（GAME_OVER→PLAYING 无尽续打）零补烤 ──")
	_gl.change_state(GameConst.GameStatus.GAME_OVER)
	var ok: bool = _gl.continue_endless()
	_check("④a continue_endless 成功（GAME_OVER→PLAYING 无尽态）",
		ok and _gl.state == GameConst.GameStatus.PLAYING and _gl._endless_mode,
		"ok=%s state=%d" % [str(ok), _gl.state])
	_check("④b 无尽续打口零补烤（built 仍 0、未 ready——门开着也没烤）",
		PopupGlyphAtlas.built_count() == 0 and not PopupGlyphAtlas.ready(),
		"built=%d" % PopupGlyphAtlas.built_count())


# ── ⑤ restart_run 真链补烤 + 多次重开幂等（A/F） ────────────────────
func _test_5_restart_run_bakes_and_idempotent() -> void:
	print("── ⑤ restart_run 真链补烤 / 幂等 ──")
	var pre_us: int = DebugStats.get_counter(&"bitmap_bake_us")
	_gl.change_state(GameConst.GameStatus.PAUSED)
	var ok: bool = _gl.restart_run()
	var bake_us: int = DebugStats.get_counter(&"bitmap_bake_us") - pre_us
	_check("⑤a restart_run 成功且补烤执行（built 0→%d、ready）" % GLYPH_N,
		ok and _gl.state == GameConst.GameStatus.PLAYING
			and PopupGlyphAtlas.built_count() == GLYPH_N and PopupGlyphAtlas.ready(),
		"ok=%s built=%d" % [str(ok), PopupGlyphAtlas.built_count()])
	_check("⑤b 补N 计数入账（Δµs>0，实测 %dµs≈%.1fms）" % [bake_us, float(bake_us) / 1000.0],
		bake_us > 0, "Δus=%d" % bake_us)
	# 多次重开幂等：再走一轮 PAUSED→restart_run，就绪后零增量
	var pre_us2: int = DebugStats.get_counter(&"bitmap_bake_us")
	_gl.change_state(GameConst.GameStatus.PAUSED)
	var ok2: bool = _gl.restart_run()
	var delta_us2: int = DebugStats.get_counter(&"bitmap_bake_us") - pre_us2
	_check("⑤c 二次重开幂等（built 恒 %d、零烤制增量）" % GLYPH_N,
		ok2 and PopupGlyphAtlas.built_count() == GLYPH_N and delta_us2 == 0,
		"ok=%s Δus=%d" % [str(ok2), delta_us2])


func _teardown() -> void:
	PopupGlyphAtlas.runstart_bake_override = -1
	tree.paused = false
	RunSave.clear()
	if _gl != null:
		_gl.free()
		_gl = null

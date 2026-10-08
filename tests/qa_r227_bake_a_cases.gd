# tests/qa_r227_bake_a_cases.gd
# QA-R227 探针 A 用例体。冷进程 static 顺序敏感：门矩阵 → continue_run 真链 → 短路。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const GLYPH_N := 12
const COST_BOUND_US := 60000   # 验收 C：≤~60ms 量级（dev 桌面实测 ~42ms）

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_test_1_cold_gate_desktop()
	_boot_game_loop()
	await _test_2_continue_run_real_chain()
	await _test_3_shortcircuit_and_restart()
	_test_4_diag_chain()
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
	_gl.name = "QA_R227_A_GameLoop"
	tree.get_root().add_child(_gl)


# ── ① 冷进程桌面自动门（headless 非 mobile → 不补，零扰动） ─────────
func _test_1_cold_gate_desktop() -> void:
	print("── ① 冷进程桌面自动门 ──")
	_check("①a override 默认 -1 且 gate=false（headless 桌面）",
		PopupGlyphAtlas.runstart_bake_override == -1
			and not PopupGlyphAtlas.runstart_gate())
	_check("①b ensure 短路返 false 且零烤制",
		not PopupGlyphAtlas.ensure_runstart_bake()
			and PopupGlyphAtlas.built_count() == 0
			and not PopupGlyphAtlas.ready())


# ── ② continue_run 真链（override=1 模拟 mobile，冷图集） ───────────
func _test_2_continue_run_real_chain() -> void:
	print("── ② continue_run 真链补烤（三新局口之一——dev 套件未覆盖口） ──")
	_gl.state = GameConst.GameStatus.MENU
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	RunSave.save_run(_gl.serialize_run())
	_check("②a 测试档落盘（headless 走 run_save_test.cfg）", RunSave.exists())
	PopupGlyphAtlas.runstart_bake_override = 1
	var pre_us: int = DebugStats.get_counter(&"bitmap_bake_us")
	var t0 := Time.get_ticks_usec()
	var ok: bool = _gl.continue_run()
	var wall_us := Time.get_ticks_usec() - t0
	var bake_us: int = DebugStats.get_counter(&"bitmap_bake_us") - pre_us
	_check("②b continue_run 成功（MENU→PLAYING）",
		ok and _gl.state == GameConst.GameStatus.PLAYING,
		"ok=%s state=%d" % [str(ok), _gl.state])
	_check("②c 新局口补烤执行（built 0→%d）" % GLYPH_N,
		PopupGlyphAtlas.built_count() == GLYPH_N and PopupGlyphAtlas.ready(),
		"built=%d" % PopupGlyphAtlas.built_count())
	_check("②d 补烤成本 ≤60ms（bitmap_bake_us=%dµs，continue 全口墙钟 %dµs）" % [bake_us, wall_us],
		bake_us > 0 and bake_us <= COST_BOUND_US, "bake_us=%d" % bake_us)
	# continue_run 档波次恢复：serialize 快照 wave=1（boot 未开战）——续档应从波 1 起
	_check("②e 续档后状态健康（波次源已起）",
		_gl.wave_director != null and _gl.spawner != null)
	print("      [info] 实测补烤=%dµs（%.1fms）" % [bake_us, float(bake_us) / 1000.0])


# ── ③ 就绪后短路零成本 + restart_run 口幂等 ────────────────────────
func _test_3_shortcircuit_and_restart() -> void:
	print("── ③ 就绪短路零成本 / restart 口幂等 ──")
	var pre_us: int = DebugStats.get_counter(&"bitmap_bake_us")
	_check("③a 已就绪 ensure 短路返 false",
		not PopupGlyphAtlas.ensure_runstart_bake())
	_gl.change_state(GameConst.GameStatus.PAUSED)
	var ok: bool = _gl.restart_run()
	var delta_us: int = DebugStats.get_counter(&"bitmap_bake_us") - pre_us
	_check("③b restart_run 成功（PAUSED→PLAYING）", ok
		and _gl.state == GameConst.GameStatus.PLAYING, "ok=%s" % str(ok))
	_check("③c 重启新局幂等（built 恒 %d、ready 保持、bitmap_bake_us 零增量——零成本短路）"
		% GLYPH_N,
		PopupGlyphAtlas.built_count() == GLYPH_N and PopupGlyphAtlas.ready()
			and delta_us == 0, "Δus=%d" % delta_us)


# ── ④ diag 三段贯通（计数→差分→行尾补N + 头部口径） ─────────────────
func _test_4_diag_chain() -> void:
	print("── ④ diag 链路（bitmap_bake_us→diag_counts→debug_stats 行） ──")
	var counts: Dictionary = _gl.diag_counts()
	var first: int = int(counts.get(&"bitmap_bake_ms_delta", -1))
	_check("④a diag_counts 出键 bitmap_bake_ms_delta（首拉立基线）",
		counts.has(&"bitmap_bake_ms_delta") and first >= 0, "val=%d" % first)
	DebugStats.count(&"bitmap_bake_us", 5000)
	var second: int = int(_gl.diag_counts().get(&"bitmap_bake_ms_delta", -1))
	_check("④b 差分 +5000µs → +5ms", second - first == 5, "Δ=%d" % (second - first))
	_check("④c 位图R=1（就绪读数）",
		int(_gl.diag_counts().get(&"bitmap_ready", 0)) == 1)
	var line: String = DebugStats._diag_format_line(_gl, Time.get_ticks_msec())
	var rx := RegEx.new()
	rx.compile(" 位图\\d+ 翻\\d+ 补\\d+")
	_check("④d debug_stats 行尾含「 位图N 翻N 补N」（格式串无语法错）",
		rx.search(line) != null, "tail=%s" % line.right(64))
	_check("④e 行内 位图=1 就绪读数", line.contains(" 位图1 "), line.right(64))
	var export: Dictionary = DebugStats.diag_export()
	var text := String(export.get("text", ""))
	_check("④f 头部口径声明含补N 定义（R227）", text.contains("补N（R227）"))


func _teardown() -> void:
	PopupGlyphAtlas.runstart_bake_override = -1
	tree.paused = false
	RunSave.clear()
	if _gl != null:
		_gl.free()
		_gl = null

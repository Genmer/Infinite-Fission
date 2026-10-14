# tests/runner/r227_bakegate_cases.gd
# R227 用例体：位图激活路径——字形 cell 队首前移 + 新局入口补烤兜底 + 补N 仪表。
# 背景（vc32 真机定案，FEEDBACK_TRACKER 二t）：全 240 行 位图R=0——字形 cell 原排
# 预热队列中段（共享域+敌贴图 ~40 项后）且仅 MENU 态 12ms/帧消化，菜单停留 ~2s 的
# 真实玩家永远排不到 → 整局 Label 回退 = R225 渲染首刀从未激活。整套 12 cell 实测
# ~42ms。修法：①队列前移（菜单 ~0.3s 即就绪）②start_run/restart_run/continue_run
# 三新局口 ensure_runstart_bake 兜底（mobile 门+覆写口）③diag 补N 归因键。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const GLYPH_N := 12          # PopupGlyphAtlas.glyph_count()（0-9+免疫——防漂移硬锚）

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	# 顺序敏感（进程内 static 共享）：门矩阵必须先于任何烤制；真链 start_run 兜底
	# 在 boot 后立即执行（不 await——避免 MENU 帧先消费队列稀释判别力）
	_test_1_gate_matrix()
	_boot_game_loop()
	_test_2_queue_order()
	_test_3_runstart_bake_real_chain()
	await _test_4_menu_pump_consumes_front()
	_test_5_diag_key()
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
	_gl.name = "R227GameLoopUnderTest"
	tree.get_root().add_child(_gl)


# ── ① 门矩阵（atlas 未触——进程静态干净态） ─────────────────────
func _test_1_gate_matrix() -> void:
	print("── ① 新局补烤门（auto=mobile / override 三态） ──")
	var built0: int = PopupGlyphAtlas.built_count()
	_check("①a 桌面自动门不补（headless 非 mobile——桌面零扰动）",
		PopupGlyphAtlas.runstart_bake_override == -1
			and not PopupGlyphAtlas.ensure_runstart_bake()
			and PopupGlyphAtlas.built_count() == built0,
		"built=%d" % PopupGlyphAtlas.built_count())
	PopupGlyphAtlas.runstart_bake_override = 0
	_check("①b override=0 强制不补",
		not PopupGlyphAtlas.ensure_runstart_bake()
			and PopupGlyphAtlas.built_count() == built0,
		"built=%d" % PopupGlyphAtlas.built_count())
	PopupGlyphAtlas.runstart_bake_override = -1
	var gate_auto: bool = PopupGlyphAtlas.runstart_gate()
	PopupGlyphAtlas.runstart_bake_override = 1
	var gate_on: bool = PopupGlyphAtlas.runstart_gate()
	PopupGlyphAtlas.runstart_bake_override = -1
	_check("①c runstart_gate 真源（override 优先/平台自动）",
		not gate_auto and gate_on,
		"auto=%s on=%s" % [str(gate_auto), str(gate_on)])


# ── ② 队列序（boot 后未泵帧——队列满态） ────────────────────────
func _test_2_queue_order() -> void:
	print("── ② 字形 cell 队首前移（boot 建队即验） ──")
	var q: Array = _gl._tex_prewarm_queue
	_check("②a 队列非空且总项数 ≥ 字形数", q.size() >= GLYPH_N, "size=%d" % q.size())
	var glyph_head := true
	for i in range(GLYPH_N):
		var job: Dictionary = q[i]
		if int(job.get(&"op", -1)) != 6 or int(job.get(&"cell", -1)) != i:
			glyph_head = false
			break
	_check("②b 前 12 项= op:6 cell 0..11（R227 队首前移）", glyph_head,
		"head=%s" % str(q.slice(0, 2)))
	var next_op := -1
	if q.size() > GLYPH_N:
		next_op = int(q[GLYPH_N].get(&"op", -1))
	_check("②c 字形之后才是贴图域（op:2 起）", next_op == 2, "next_op=%d" % next_op)


# ── ③ 真链：start_run 新局口兜底（override=1 模拟 mobile） ──────
func _test_3_runstart_bake_real_chain() -> void:
	print("── ③ 真链 start_run → 补烤兜底 → 就绪 ──")
	PopupGlyphAtlas.runstart_bake_override = 1
	var pre_counter: int = DebugStats.get_counter(&"bitmap_bake_us")
	var pre_calls: int = DebugStats.get_counter(&"bitmap_ensure_calls")
	var pre_built: int = PopupGlyphAtlas.built_count()
	_gl.state = GameConst.GameStatus.MENU
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	var ok: bool = _gl.start_run()
	var counter_delta: int = DebugStats.get_counter(&"bitmap_bake_us") - pre_counter
	_check("③a start_run 成功（MENU→PLAYING）", ok and _gl.state == GameConst.GameStatus.PLAYING,
		"ok=%s state=%d" % [str(ok), _gl.state])
	_check("③b 新局口补烤执行（built 0→12）",
		pre_built == 0 and PopupGlyphAtlas.built_count() == GLYPH_N,
		"pre=%d now=%d" % [pre_built, PopupGlyphAtlas.built_count()])
	_check("③c ready() 就绪（位图门激活）", PopupGlyphAtlas.ready())
	_check("③d 补N 计数入账（bitmap_bake_us 增量 >0）", counter_delta > 0, "Δ=%d" % counter_delta)
	_check("③e 挂点覆盖计数（评审 L3）：start_run 使 bitmap_ensure_calls 恰 +1",
		DebugStats.get_counter(&"bitmap_ensure_calls") - pre_calls == 1,
		"Δ=%d" % (DebugStats.get_counter(&"bitmap_ensure_calls") - pre_calls))
	_check("③f 幂等：就绪后 ensure 短路返 false",
		not PopupGlyphAtlas.ensure_runstart_bake())
	PopupGlyphAtlas.runstart_bake_override = -1


# ── ④ 菜单泵消化队首（已就绪时 op:6 幂等零成本出队） ────────────
func _test_4_menu_pump_consumes_front() -> void:
	print("── ④ MENU 泵消化（op:6 幂等出队） ──")
	_gl.state = GameConst.GameStatus.MENU
	await tree.process_frame
	var remain := 0
	var q: Array = _gl._tex_prewarm_queue
	for j in q:
		if int(j.get(&"op", -1)) == 6:
			remain += 1
	_check("④ 一帧 MENU 泵后 op:6 全部出队（队首优先兑现）",
		remain == 0 and PopupGlyphAtlas.ready(), "remain=%d" % remain)


# ── ⑤ diag 补N 键（差分管道） ─────────────────────────────────
func _test_5_diag_key() -> void:
	print("── ⑤ diag_counts 补N（R227 归因键） ──")
	var counts: Dictionary = _gl.diag_counts()
	var first: int = int(counts.get(&"bitmap_bake_ms_delta", -1))
	_check("⑤a 补N 键在且 ≥0（首拉立基线=0 合法）",
		counts.has(&"bitmap_bake_ms_delta") and first >= 0, "val=%d" % first)
	DebugStats.count(&"bitmap_bake_us", 5000)
	var counts2: Dictionary = _gl.diag_counts()
	var second: int = int(counts2.get(&"bitmap_bake_ms_delta", -1))
	_check("⑤b 补N 差分：+5000µs → +5ms", second - first == 5, "Δ=%d" % (second - first))
	_check("⑤c 位图R 键随就绪翻 1", int(counts2.get(&"bitmap_ready", 0)) == 1)


func _teardown() -> void:
	PopupGlyphAtlas.runstart_bake_override = -1
	tree.paused = false
	RunSave.clear()
	if _gl != null:
		_gl.free()
		_gl = null

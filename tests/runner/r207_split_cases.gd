# tests/runner/r207_split_cases.gd
# R207 UI 拆段与三刀·用例体（由 test_r207_split.gd 入口运行时加载）。
# vc14 真机日志：UI 混段持续 10-20ms/尖峰 25-49ms、波次尖峰 81ms——本轮拆段定位
# + 元素特效半频 + HUD hover mobile 门 + 敌出生形状复用。headless 验收桌面零扰动+新机制。
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
	await _test_1_probe_split()
	_test_2_shape_reuse()
	_test_3_hover_gate()
	_test_4_fx_halfrate_gate()
	_test_5_stage_tags()
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
	_gl.name = "R207GameLoopUnderTest"
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


# ── ① 探针拆段：PLAYING 帧后 feel/fx/ui 三键独立在位 ──
func _test_1_probe_split() -> void:
	print("── ① 探针拆段 ──")
	_gl.stage_probe_enabled = true
	for i in range(8):
		await tree.physics_frame
	var src: String = FileAccess.get_file_as_string("res://scripts/loop/game_loop.gd")
	_check("feel 段键在位（选卡消化/磁吸/game_feel）", _gl.stage_probe_us.has(&"feel"),
		"keys=%s" % str(_gl.stage_probe_us.keys()))
	_check("fx 段键在位（元素特效层）", _gl.stage_probe_us.has(&"fx"),
		"keys=%s" % str(_gl.stage_probe_us.keys()))
	_check("ui 段键在位（跳字/HUD/Boss/震屏）", _gl.stage_probe_us.has(&"ui"),
		"keys=%s" % str(_gl.stage_probe_us.keys()))
	_check("feel_ui 混段键已退役", not _gl.stage_probe_us.has(&"feel_ui"),
		"keys=%s" % str(_gl.stage_probe_us.keys()))
	_check("frame_order 帧序契约不动（feel/ui 两标签原位）",
		src.contains('frame_order.append(&"feel")') and src.contains('frame_order.append(&"ui")'),
		"缺帧序标签")


# ── ② 敌出生形状复用：同半径同实例、异半径分键 ──
func _test_2_shape_reuse() -> void:
	print("── ② 敌形状复用 ──")
	var a: CircleShape2D = Enemy._hit_circle(12.0)
	var b: CircleShape2D = Enemy._hit_circle(12.0)
	var c: CircleShape2D = Enemy._hit_circle(30.0)
	_check("同半径复用同实例（零出生分配）", a == b and a != null,
		"a=%s b=%s" % [str(a.get_instance_id()), str(b.get_instance_id())])
	_check("异半径分键（半径语义不变）", a != c and is_equal_approx(c.radius, 30.0),
		"c.radius=%s" % str(c.radius))
	_check("复用形状半径正确", is_equal_approx(a.radius, 12.0), "a.radius=%s" % str(a.radius))


# ── ③ HUD hover：mobile 门源级锚（触屏无 hover）──
func _test_3_hover_gate() -> void:
	print("── ③ HUD hover 门 ──")
	var src: String = FileAccess.get_file_as_string("res://scripts/ui/hud.gd")
	# R220 同步注：仓内文件行尾为 CRLF（全仓一致），锚点断言对 \r\n/\n 双容错——
	# 单 LF 模式在 CRLF 读入下恒 false（存量环境红，非行为回归）
	var gate_lf := 'if not OS.has_feature("mobile"):\n\t\t_tick_hover()'
	var gate_crlf := 'if not OS.has_feature("mobile"):\r\n\t\t_tick_hover()'
	_check("hover 调用裹 mobile 否定门", src.contains(gate_lf) or src.contains(gate_crlf),
		"缺门结构")


# ── ④ 元素特效层半频：mobile 门源级锚 ──
func _test_4_fx_halfrate_gate() -> void:
	print("── ④ 元素特效半频门 ──")
	var src: String = FileAccess.get_file_as_string("res://scripts/loop/game_loop.gd")
	_check("fx 半频 2δ 驱动源级锚", src.contains("elemental_fx.tick(p_raw_delta * 2.0)"),
		"缺半频驱动行")
	_check("相位计数器在位（_fx_subtick_left）", src.contains("_fx_subtick_left"),
		"缺相位计数器")


# ── ⑤ 诊断标签表：段序 + 感/特 中文标签 ──
func _test_5_stage_tags() -> void:
	print("── ⑤ 标签表 ──")
	# R213 有意契约变更（r195_adapt_cases.gd:73-84 先例）：七段→九段——新增
	# grid_rebuild「网」（120 敌满载 rebuild 与弹 tick 分开读，vc20 开局弹段 203ms
	# 尖峰归因）+ feel_shard「磁」（选卡窗磁吸碎片→gain_xp 链独立计，感段跨窗尖峰
	# 129ms 归因）。旧七键语义除 grid_projectile（网格重建拆出后=仅弹 tick）外不变。
	# R216 有意契约变更（同先例）：九段→十一段——新增 shard「碎」（vc23 玩段残余
	# 145ms：player 本体 vs 碎片段归因）+ card「卡」（R215 延迟开窗级联与 UI 分离）。
	# R217/R218 有意契约变更（同先例）：十一段→十三段→十五段——移/火 + 跳/他
	# 「火」（vc24 尖峰玩117ms：player.tick 内部增益+移动 vs 四组武器调度归因）。
	# R220 刀1 有意契约变更（拆解契约 §3.1/§4.1 同步）：十五段→十六段——原 card 同键
	# 混合拆 card_open「开」/card_drain「消」两子键（开窗级联 vs 溢出批消化归因分离）。
	_check("十六段顺序齐", DebugStats.DIAG_STAGE_ORDER.size() == 16,
		"size=%d" % DebugStats.DIAG_STAGE_ORDER.size())
	_check("感/特标签映射在位",
		str(DebugStats.DIAG_STAGE_TAGS.get(&"feel", "")) == "感"
			and str(DebugStats.DIAG_STAGE_TAGS.get(&"fx", "")) == "特"
			and str(DebugStats.DIAG_STAGE_TAGS.get(&"ui", "")) == "UI",
		"tags=%s" % str(DebugStats.DIAG_STAGE_TAGS))

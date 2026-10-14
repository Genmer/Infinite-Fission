# tests/runner/r244_flushbucket_cases.gd
# R244「物理相冲刷桶批」用例体（入口 test_r244_flushbucket.gd 运行时 load——
# -s 编译期禁引工程类名纪律）。验收锚：
# 修 A（预热迁渲染轴）：
#  ① A1 源码锚：_process_tex_prewarm(12000) 消费点唯一且在 _process 内（物理分支迁出）。
#  ② A2 MENU 物理帧零消化（物理窗零预热成本——vc53 菜单 45-77ms 反向锁）。
#  ③ A3 MENU 渲染帧预算消化（轻项 op:4 全清）。
#  ④ A4 PLAYING 渲染帧零消化（state 门）。
#  ⑤ A5 boss 挂机门在渲染轴仍生效（dwell<3 扣队首 / dwell≥3 放行——读同一 dwell 变量）。
#  ⑥ A6 dwell 计时仍在物理侧（MENU 物理帧 +δ；渲染帧不累计）。
# 修 B（entry 段键）：
#  ⑦ B1 源码锚：game_loop 写键 + debug_stats 两处段和显式加（gd_us/stages_ms 同 dispatch 先例）。
#  ⑧ B2 运行时：PLAYING 探针帧后 stage_probe_us/peak 含 entry 且 ≥0。
#  ⑨ B3 行格式冻结：entry 不印行（不入 DIAG_STAGE_ORDER），「他」段位仍在（DiagStub 桩）。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const DT := 1.0 / 60.0
const GL_SRC := "res://scripts/loop/game_loop.gd"
const DIAG_SRC := "res://autoload/debug_stats.gd"

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null


class DiagStub extends Node:
	# 诊断行最小桩（_diag_format_line 鸭式消费面：diag_counts + 双 probe 字典 + state）
	var state: int = 0                           # GameConst.GameStatus.BOOT（_diag_state 读 int）
	var stage_probe_us: Dictionary = {}
	var stage_probe_us_peak: Dictionary = {}

	func diag_counts() -> Dictionary:
		return {}

	func diag_reset_stage_peaks() -> void:
		pass


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_boot_game_loop()
	await tree.process_frame
	await tree.process_frame
	_test_a_prewarm_axis()
	_test_b_entry_key()
	print("验收汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL | %s" % f)


func fail_count() -> int:
	return _fail


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("  ok | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s %s" % [p_name, p_detail])
		print("  FAIL | %s %s" % [p_name, p_detail])


func _boot_game_loop() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "R244GameLoopUnderTest"
	tree.get_root().add_child(_gl)              # _ready → boot（池预热/事件链全环）


# ── 修 A：预热迁渲染轴 ────────────────────────────────────────────
func _test_a_prewarm_axis() -> void:
	print("── 修 A：MENU 贴图预热迁渲染轴（vc53 菜单物步µs 45-77ms） ──")
	var gl_src: String = FileAccess.get_file_as_string(GL_SRC)
	# R252D P5：字面 12000→4000（预算合并——与 card_desc 泵合计 8ms/帧 < 16.6ms）
	var consume_at: int = gl_src.count("_process_tex_prewarm(4000)")
	_check("A1 [R252 迁移] 源码锚：消费点唯一且在 _process 内（物理 MENU 分支已迁出）",
		consume_at == 1
			and gl_src.find("_process_tex_prewarm(4000)") > gl_src.find("func _process(")
			and gl_src.find("_process_tex_prewarm(4000)") < gl_src.find("func _physics_process("),
		"count=%d" % consume_at)
	# 轻项夹具：op:4（shadow_ellipse 桌面廉价缓存）两项——行为锁不锁成本
	_gl.state = GameConst.GameStatus.MENU
	_gl._tex_prewarm_queue.clear()
	_gl.set("_tex_prewarm_skip", 0)
	_gl.set("_menu_dwell_s", 99.0)
	_gl._tex_prewarm_queue.append({&"op": 4})
	_gl._tex_prewarm_queue.append({&"op": 4})
	var size0: int = _gl._tex_prewarm_queue.size()
	_gl._physics_process(DT)
	_check("A2 MENU 物理帧零消化（物理窗零预热成本——反向锁）",
		_gl._tex_prewarm_queue.size() == size0,
		"%d → %d" % [size0, _gl._tex_prewarm_queue.size()])
	var dwell_before: float = float(_gl.get("_menu_dwell_s"))
	_gl._process(DT)
	_check("A3 MENU 渲染帧预算消化（轻项全清）+ 渲染帧不累计 dwell",
		_gl._tex_prewarm_queue.is_empty()
			and float(_gl.get("_menu_dwell_s")) == dwell_before,
		"rem=%d dwell %.4f→%.4f" % [_gl._tex_prewarm_queue.size(), dwell_before,
			float(_gl.get("_menu_dwell_s"))])
	_gl.state = GameConst.GameStatus.PLAYING
	_gl._tex_prewarm_queue.append({&"op": 4})
	var size_play: int = _gl._tex_prewarm_queue.size()
	_gl._process(DT)
	_check("A4 PLAYING 渲染帧零消化（state 门）",
		_gl._tex_prewarm_queue.size() == size_play,
		"%d → %d" % [size_play, _gl._tex_prewarm_queue.size()])
	_gl._tex_prewarm_queue.clear()
	# A5：boss 挂机门在渲染轴（dwell 同一变量读法）
	_gl.state = GameConst.GameStatus.MENU
	_gl._tex_prewarm_queue.append({&"op": 0, &"kind": &"boss1", &"angry": false})
	_gl.set("_tex_prewarm_skip", 0)
	_gl.set("_menu_dwell_s", 0.0)
	_gl._process(DT)
	var held: bool = _gl._tex_prewarm_queue.size() == 1
	_check("A5a 门武装：渲染轴 dwell<3 帧 boss 项不出队", held, "rem=%d" % _gl._tex_prewarm_queue.size())
	_gl.set("_menu_dwell_s", 99.0)
	_gl.set("_tex_prewarm_skip", 0)
	_gl._process(DT)
	_check("A5b 放行：渲染轴 dwell≥3 帧 boss 项出队",
		_gl._tex_prewarm_queue.size() == 0, "rem=%d" % _gl._tex_prewarm_queue.size())
	# A6：dwell 计时留物理侧（MENU 物理帧 +δ）
	_gl.set("_menu_dwell_s", 0.0)
	_gl._physics_process(DT)
	var d1: float = float(_gl.get("_menu_dwell_s"))
	_check("A6 dwell 计时留物理侧（MENU 物理帧 0→+δ，boss 门读法不变）",
		d1 > 0.0 and d1 < 1.0, "%.4f" % d1)


# ── 修 B：entry 段键（他/物步µs 归因纯化） ────────────────────────
func _test_b_entry_key() -> void:
	print("── 修 B：帧入口 glue 下洞 entry 段键 ──")
	var gl_src: String = FileAccess.get_file_as_string(GL_SRC)
	var diag_src: String = FileAccess.get_file_as_string(DIAG_SRC)
	_check("B1a 源码锚：game_loop PLAYING 探针帧写 entry 键（= _probe_t0 − _phys_t0）",
		gl_src.contains("stage_probe_us[&\"entry\"] = _probe_t0 - _phys_t0"),
		"len=%d" % gl_src.length())
	_check("B1b 源码锚：debug_stats 段和显式加 entry 恰两处（gd_us 累计 + stages_ms）",
		diag_src.count("probe.get(&\"entry\", 0)") == 2,
		"count=%d" % diag_src.count("probe.get(&\"entry\", 0)"))
	# B1c：DIAG_STAGE_ORDER 常量块（到下一 const/func 前）不含 entry——行格式零改动
	var order_at: int = diag_src.find("const DIAG_STAGE_ORDER")
	var order_block: String = diag_src.substr(order_at,
		diag_src.find("\nconst ", order_at + 10) - order_at) if order_at >= 0 else ""
	_check("B1c 源码锚：DIAG_STAGE_ORDER 常量块不含 entry（行格式零改动）",
		order_at >= 0 and order_block.length() > 10
			and not order_block.contains("entry") and order_block.contains("other"),
		"block_len=%d" % order_block.length())
	# B2：PLAYING 探针帧运行时键存在
	_gl.state = GameConst.GameStatus.PLAYING
	_gl.stage_probe_enabled = true
	_gl._physics_process(DT)
	var probe: Dictionary = _gl.stage_probe_us
	_check("B2 PLAYING 探针帧 entry 键存在且非负 + peak 通道同记",
		probe.has(&"entry") and int(probe[&"entry"]) >= 0
			and _gl.stage_probe_us_peak.has(&"entry"),
		"entry=%s" % str(probe.get(&"entry", "无")))
	_gl.stage_probe_enabled = false
	# B3：行格式冻结——DiagStub 桩喂 entry 键，行不含「入」段且「他」段位仍在
	var stub := DiagStub.new()
	stub.stage_probe_us = {&"entry": 700, &"player": 300, &"other": 200}
	stub.stage_probe_us_peak = {}
	var line: String = DebugStats._diag_format_line(stub, 65000)
	_check("B3 行格式冻结：entry 不印行（无「入」段）+「他」段位仍在",
		not line.contains("入") and line.contains("他"),
		"line=%s" % line)
	stub.free()

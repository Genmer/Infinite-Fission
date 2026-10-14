# tests/runner/r245_diag_gate_cases.gd
# R245「MENU 行物步µs 伪影修复」用例体（入口 test_r245_diag_gate.gd 运行时 load——
# -s 编译期禁引工程类名纪律）。夹具：DiagStub 桩（r244_flushbucket DiagStub 同式——
# _diag_format_line/_diag_accumulate_window 的鸭子消费面）+ DebugStats 缓存口直指桩
# （_diag_gl_cached 树扫旁路）。多帧累计 = 逐次 await physics_frame（物理帧判重口径）。
extends RefCounted

const DIAG_SRC := "res://autoload/debug_stats.gd"
const DT := 1.0 / 60.0

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _stub: Node = null


class DiagStub extends Node:
	# 诊断行/秒窗累计最小桩（state + 双 probe 字典 + diag_counts——DebugStats 鸭式消费面）
	var state: int = 0                           # GameConst.GameStatus.BOOT
	var stage_probe_us: Dictionary = {}
	var stage_probe_us_peak: Dictionary = {}

	func diag_counts() -> Dictionary:
		return {}

	func diag_reset_stage_peaks() -> void:
		pass


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(245)
	_setup_stub()
	_test_g_source_anchors()
	await _test_a_non_playing_gate()            # A（MENU/GAME_OVER/PAUSED 三态）
	await _test_b_playing_accumulates()         # B
	_test_c_menu_line_zero()                    # C（M 行拼装 + r229 尾锚正则）
	await _test_d_state_changed_reset()         # D
	_test_e_export_header()                     # E
	_teardown()
	print("────────────────────────────────────────")
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


func _setup_stub() -> void:
	_stub = DiagStub.new()
	_stub.name = "R245DiagGateStub"
	tree.get_root().add_child(_stub)
	# 缓存口直指桩（旁路 _diag_gl_cached 树扫/1s 节流——本套无 GameLoop 实例）
	DebugStats.set("_diag_gl_cache", _stub)
	DebugStats.set("_diag_gl_scan_after_ms", 0)


func _teardown() -> void:
	DebugStats.set("_diag_gl_cache", null)       # 缓存失效（后续套件/帧重扫不受桩残留影响）
	DebugStats.set("_diag_gl_scan_after_ms", 0)
	DebugStats._diag_reset_window_acc()
	if _stub != null:
		_stub.free()
		_stub = null


func _acc_frames(p_n: int) -> void:
	# 多帧累计：每物理帧一次 accumulate（判重口径——pf 变更才过门）。
	# 每次迭代刷新 1Hz 采样节拍基线（_diag_last_ms）——防 _diag_maybe_sample 途中介入
	# reset 秒窗累计器打散断言（headless 快进下真实墙钟仍会跨秒界）。
	for i in range(p_n):
		DebugStats.set("_diag_last_ms", Time.get_ticks_msec())
		DebugStats._diag_accumulate_window(DT)
		await tree.physics_frame
		await tree.process_frame


# ── G 组：源码锚（主修状态门 + 辅修复位 + 头串词条在源） ──────────
func _test_g_source_anchors() -> void:
	print("── G 组：源码锚 ──")
	var src := FileAccess.get_file_as_string(DIAG_SRC)
	_check("G1 源码锚：物理侧状态门在 _diag_accumulate_window（仅 PLAYING 累计）",
		src.contains("if gl == null or int(gl.get(\"state\")) != GameConst.GameStatus.PLAYING:"))
	# 渲轴两累计器在状态门之前=全态累计（菜单 fps/渲ms 诊断力保留——设计 §2.2）
	var render_at: int = src.find("_diag_render_ms_sum += p_delta * 1000.0")
	var gate_at: int = src.find("int(gl.get(\"state\")) != GameConst.GameStatus.PLAYING")
	_check("G2 源码锚：渲轴累计先行全态（render 累计在状态门之前）",
		render_at >= 0 and gate_at > render_at,
		"render@%d gate@%d" % [render_at, gate_at])
	_check("G3 源码锚：state_changed 订阅 → 秒窗复位（辅修·切态重开秒窗）",
		src.contains("EventBus.state_changed.connect(_on_state_changed_diag_window)")
			and src.contains("func _on_state_changed_diag_window"))
	_check("G4 源码锚：_diag_maybe_sample LEVEL_UP 跳采样不复位逻辑保持照旧",
		src.contains("int(gl.get(\"state\")) == GameConst.GameStatus.LEVEL_UP:"))
	_check("G5 源码锚：导出头串含 R245 口径词条（R244 修B 先例同位追加）",
		src.contains("R245 起物理侧仅 PLAYING 态采样"))
	_check("G6 源码锚：行格式零改动（物步µs 键仍在 _diag_format_line 拼装）",
		src.contains("物步µs%d 派µs%d 渲ms%.1f"))


# ── A 组：非 PLAYING 态物理侧零累计 ───────────────────────────────
func _test_a_non_playing_gate() -> void:
	print("── A 组：MENU/GAME_OVER/PAUSED 态物理侧三累计器零累计 ──")
	for st_name in [["MENU", GameConst.GameStatus.MENU],
			["GAME_OVER", GameConst.GameStatus.GAME_OVER],
			["PAUSED", GameConst.GameStatus.PAUSED]]:
		var sname: String = st_name[0]
		var sval: int = st_name[1]
		_stub.state = sval
		DebugStats._diag_reset_window_acc()
		await _acc_frames(6)
		_check("A1 %s 态多帧累计后 _diag_phys_samples==0（离场深载尾样本/冻结期跨界携带根除）"
			% sname,
			int(DebugStats.get("_diag_phys_samples")) == 0,
			"samples=%d" % int(DebugStats.get("_diag_phys_samples")))
		_check("A2 %s 态渲轴照常全态累计（render_frames>0——菜单 fps/渲ms 诊断力保留）"
			% sname,
			int(DebugStats.get("_diag_render_frames")) > 0,
			"frames=%d" % int(DebugStats.get("_diag_render_frames")))
	# 离场首帧即门住：PLAYING 累计后切 MENU，单帧也不回吐（冻结期跨界携带不复现）
	_stub.state = GameConst.GameStatus.PLAYING
	DebugStats._diag_reset_window_acc()
	await _acc_frames(3)
	var had_samples: int = int(DebugStats.get("_diag_phys_samples"))
	_stub.state = GameConst.GameStatus.MENU
	await _acc_frames(2)
	_check("A3 离场切 MENU 后样本不回吐（samples 保持 %d 不增）" % had_samples,
		int(DebugStats.get("_diag_phys_samples")) == had_samples,
		"samples=%d（前=%d）" % [int(DebugStats.get("_diag_phys_samples")), had_samples])


# ── B 组：PLAYING 态照常累计 ──────────────────────────────────────
func _test_b_playing_accumulates() -> void:
	print("── B 组：PLAYING 态物理侧照常累计 ──")
	_stub.state = GameConst.GameStatus.PLAYING
	_stub.stage_probe_us = {&"entry": 100, &"player": 200, &"other": 50, &"dispatch": 30}
	DebugStats._diag_reset_window_acc()
	await _acc_frames(4)
	var samples: int = int(DebugStats.get("_diag_phys_samples"))
	var mon_us: int = int(DebugStats.get("_diag_phys_mon_us"))
	var gd_us: int = int(DebugStats.get("_diag_phys_gd_us"))
	_check("B1 PLAYING 态照常累计（samples>0）", samples > 0, "samples=%d" % samples)
	_check("B2 monitor/段和累计非负且段和含 entry 键（R244 修B 口径不回退）",
		mon_us >= 0 and gd_us >= samples * 180,
		"mon=%d gd=%d（期望 gd ≥ samples×180）" % [mon_us, gd_us])


# ── C 组：M 行拼装 物步µs==0 + r229 尾锚正则仍匹配 ────────────────
func _test_c_menu_line_zero() -> void:
	print("── C 组：M 行拼装（物步µs==0·键在格式不变）──")
	_stub.state = GameConst.GameStatus.MENU
	DebugStats._diag_reset_window_acc()
	DebugStats._diag_accumulate_window(DT)       # 单帧渲染累计（渲ms 有值）+物理侧 0
	var line: String = DebugStats._diag_format_line(_stub, Time.get_ticks_msec())
	_check("C1 M 行拼装 物步µs==0（无样本守卫天然出 0——非读数）",
		line.contains("物步µs0"), "line=%s" % line)
	_check("C2 M 行状态字 M（拼装走 stub state）", line.contains(" M] "), "line=%s" % line)
	# r229 尾锚正则（r229_pool_valve_cases.gd:274 同式）——键仍在、值 0，\d+ 仍匹配
	# 〔R271 追认声明式迁移〕尾锚自「( 挡\d+)?$」过期（R269 八键/R271 十一键先后追加在
	# 挡 后、尖峰段前，`$` 终锚恒失配——非行为破坏，锚形状未随行尾增长同步）。按 §0.2
	# 冻结正则协议迁移到现行行尾：挡 后补 R269 八可选组（死µs…促）+ R271 十一可选组
	#（步µs 隙µs 延早µs 延渲µs 延峰µs 加N 摘N 绘µs 渲帧N 呈帧N 渲峰ms）——qa_r228_
	# diagfreeze_cases.gd / r229_pool_valve / r230_k2 / qa_r269_bucketprobe 同批同款；
	# 锚仍证「行结构冻结」原意（M 桩行秒窗键天然 0/时序读数 \d+ 不断言值）。
	var rx := RegEx.new()
	rx.compile(" 裁\\d+ 快\\d+ 结µs\\d+ 插µs\\d+ 插模拟µs\\d+ 派deferred\\d+ 派drop\\d+ 物步µs\\d+ 派µs\\d+ 渲ms\\d+\\.\\d( 挡\\d+)?( 死µs\\d+)?( 警µs\\d+)?( 桶µs\\d+)?( 延µs\\d+)?( 释\\d+)?( 敌弹\\d+)?( 拒\\d+)?( 促\\d+)?( 步µs\\d+)?( 隙µs\\d+)?( 延早µs\\d+)?( 延渲µs\\d+)?( 延峰µs\\d+)?( 加\\d+)?( 摘\\d+)?( 绘µs\\d+)?( 渲帧\\d+)?( 呈帧\\d+)?( 渲峰ms\\d+\\.\\d+)?$")
	var m := rx.search(line)
	_check("C3 r229 尾锚正则仍匹配（R269/R271 行尾增长迁移后——行结构冻结原意保持，物步µs%d）"
		% int(DebugStats.get("_diag_phys_samples")),
		m != null, "line=%s" % line)


# ── D 组：state_changed 后秒窗累计器归零 ──────────────────────────
func _test_d_state_changed_reset() -> void:
	print("── D 组：切态重开秒窗 ──")
	_stub.state = GameConst.GameStatus.PLAYING
	DebugStats._diag_reset_window_acc()
	await _acc_frames(3)
	var pre_samples: int = int(DebugStats.get("_diag_phys_samples"))
	var pre_frames: int = int(DebugStats.get("_diag_render_frames"))
	_check("D 前置：PLAYING 窗内有样本（samples=%d frames=%d）" % [pre_samples, pre_frames],
		pre_samples > 0 and pre_frames > 0)
	EventBus.emit_state_changed(GameConst.GameStatus.MENU)
	_check("D state_changed 后秒窗五累计器归零（渲ms/帧/mon/gd/samples）",
		float(DebugStats.get("_diag_render_ms_sum")) == 0.0
			and int(DebugStats.get("_diag_render_frames")) == 0
			and int(DebugStats.get("_diag_phys_mon_us")) == 0
			and int(DebugStats.get("_diag_phys_gd_us")) == 0
			and int(DebugStats.get("_diag_phys_samples")) == 0,
		"ms=%s frames=%d mon=%d gd=%d s=%d" % [str(DebugStats.get("_diag_render_ms_sum")),
			int(DebugStats.get("_diag_render_frames")), int(DebugStats.get("_diag_phys_mon_us")),
			int(DebugStats.get("_diag_phys_gd_us")), int(DebugStats.get("_diag_phys_samples"))])


# ── E 组：导出头串 R245 词条 ─────────────────────────────────────
func _test_e_export_header() -> void:
	print("── E 组：导出头串 R245 口径词条 ──")
	var res: Dictionary = DebugStats.diag_export()
	var text: String = str(res["text"])
	_check("E1 导出头串含「R245 起物理侧仅 PLAYING 态采样」词条",
		text.contains("R245 起物理侧仅 PLAYING 态采样"), "head40=%s" % text.substr(0, 40))
	_check("E2 词条全文在位（恒 0=无样本·不可对拍·伪影根除）",
		text.contains("M/D/B 行物步µs 恒 0（=无样本，非读数），与 R244 前菜单行读数不可对拍；跨态伪影根除"))
	_check("E3 R244 修B 先例词条仍在（递进口径共存）",
		text.contains("R244 修B：减项另含 entry 键"))

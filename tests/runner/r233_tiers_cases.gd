# tests/runner/r233_tiers_cases.gd
# R233 T3+T4 用例体（入口 test_r233_tiers.gd 运行时 load——-s 编译期禁引工程类名纪律）。
# 覆盖矩阵：
# ① A 组 AC-6 五参数两态对拍（选择器直读——GameLoop.sim30_effective() 为唯一变量）：
#    60Hz 态（headless 真值）= 原档逐位（48/96/12/48/30/24）；30Hz 态（-3 哨兵注入）=
#    新档逐位（96/192/6/96/15/48）；原六 const 两态均不改写（决策6 const 断言保护策略
#    的套件级锁定——r223 直断言 48/96/12、r221 直断言 48/30、r225 字面量 24 全兼容）；
#    override ≥0 仍最高优先否决（r223 既有口径不破）；回退档（-3+ENABLED=false）五参数
#    全回原值（单开关全联动防半回退态）；收尾复位无泄漏。
# ② B 组 30Hz 档位常量值锁定（新 const 逐位——防手滑改值）。
# ③ C 组 AC-8 四点短路：源级断言（三处 `mobile ∧ not sim30_effective()` 守卫 + orbit
#    `sim30_effective() or _redraw_ctr % 2 == 0`）+ orbit 两态行为对拍（60Hz 态隔帧
#    阈值逐位 / 30Hz 态每 tick 直驱）+ headless 两态直驱相位计数器零递减（OS 门先于
#    谓词——桌面/headless 口径两态零扰动）+ label_ctr 披露项未动 + 磁吸帽源级接线。
# ④ D 组 派发行为两态对拍（DamagePipeline 直构——r221 Fix C 同构）：帽 48/96 派延对拍
#    + 过期窗 30/15 边界对拍（stale_drop 计数）。
# ⑤ E 组 结算顺延过期强冲两态对拍（真件管线 + 敌夹具——r223 ⑤ 同构）：12 帧 vs 6 帧
#    强冲边界（settle_stale_flush 计数 + FIFO 清空）。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const GL_SOURCE := "res://scripts/loop/game_loop.gd"
const ORBIT_SOURCE := "res://scripts/combat/weapon/melee/orbit_field.gd"
const EXPECTED_TOTAL := 52               # 收尾项前用例总数（r233_sim30 同口径——总项数断言
                                         # 读 _pass+_fail 于收尾项入账前；连收尾共 53 项）
const DT := 1.0 / 60.0

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null
var _released: Array[Enemy] = []


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_boot_game_loop()
	PerfGovernor.set_process(false)        # 冻结调速器档变（r232/r223 套件同款纪律）
	await tree.process_frame
	await tree.process_frame
	_test_a_five_params_two_state()
	_test_b_tier_consts()
	_test_c_ac8_short_circuit()
	_test_d_dispatch_behavior()
	_test_e_settle_stale_behavior()
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


# ── ① A 组：AC-6 五参数两态对拍（选择器直读） ─────────────────────

func _test_a_five_params_two_state() -> void:
	print("── ① AC-6 五参数两态对拍（结算帽×2 + 强冲窗 + 派发帽/窗 + 磁吸帽） ──")
	PerfGovernor.mode_override = 0         # 帧率优先（r223 ⑦ 同款——门内 tier 映射可达）
	PerfGovernor.tier_override = 1
	DamagePipeline.settle_budget_override = -3   # 模拟真机门（r223 ⑦ 同款——tier 映射分支可达）
	GameLoop.sim30_override = -1
	GameLoop.SIM_30HZ_ENABLED = true
	_check("A1 60Hz 态谓词 false（headless 真值门）", not GameLoop.sim30_effective(), "")
	_check("A2 60Hz tier1 帽 48（原档逐位）", DamagePipeline._settle_cap_now() == 48,
		"cap=%d" % DamagePipeline._settle_cap_now())
	PerfGovernor.tier_override = 2
	_check("A3 60Hz tier2 帽 96（原档逐位）", DamagePipeline._settle_cap_now() == 96,
		"cap=%d" % DamagePipeline._settle_cap_now())
	_check("A4 60Hz SETTLE_STALE 12（原档逐位）", DamagePipeline.settle_stale_frame_now() == 12,
		"v=%d" % DamagePipeline.settle_stale_frame_now())
	_check("A5 60Hz DISPATCH 48（原档逐位——r221 口径）", DamagePipeline.dispatch_frame_cap_now() == 48,
		"v=%d" % DamagePipeline.dispatch_frame_cap_now())
	_check("A6 60Hz WINDOW 30（原档逐位）", DamagePipeline.stale_frame_window_now() == 30,
		"v=%d" % DamagePipeline.stale_frame_window_now())
	_check("A7 60Hz MAGNET 24（原档逐位——r225 口径）", GameLoop.magnet_absorb_cap_now() == 24,
		"v=%d" % GameLoop.magnet_absorb_cap_now())
	_check("A8 60Hz 态原六 const 锁定（const 断言保护——值不改写）",
		DamagePipeline.SETTLE_BUDGET_T1 == 48 and DamagePipeline.SETTLE_BUDGET_T2 == 96
			and DamagePipeline.SETTLE_STALE_FRAME == 12
			and DamagePipeline.DISPATCH_FRAME_CAP == 48
			and DamagePipeline.STALE_FRAME_WINDOW == 30
			and GameLoop.MAGNET_ABSORB_PER_FRAME == 24, "")
	GameLoop.sim30_override = -3           # -3 哨兵：模拟 mobile（headless 驱真值臂）
	_check("A9 30Hz 态谓词 true（-3 注入）", GameLoop.sim30_effective(), "")
	PerfGovernor.tier_override = 1
	_check("A10 30Hz tier1 帽 96（决策6 档）", DamagePipeline._settle_cap_now() == 96,
		"cap=%d" % DamagePipeline._settle_cap_now())
	PerfGovernor.tier_override = 2
	_check("A11 30Hz tier2 帽 192（决策6 定案值）", DamagePipeline._settle_cap_now() == 192,
		"cap=%d" % DamagePipeline._settle_cap_now())
	_check("A12 30Hz SETTLE_STALE 6（0.2s 时间语义守恒）", DamagePipeline.settle_stale_frame_now() == 6,
		"v=%d" % DamagePipeline.settle_stale_frame_now())
	_check("A13 30Hz DISPATCH 96（比例平价 ≈2880/s）", DamagePipeline.dispatch_frame_cap_now() == 96,
		"v=%d" % DamagePipeline.dispatch_frame_cap_now())
	_check("A14 30Hz WINDOW 15（0.5s 时间语义守恒）", DamagePipeline.stale_frame_window_now() == 15,
		"v=%d" % DamagePipeline.stale_frame_window_now())
	_check("A15 30Hz MAGNET 48（≈1440/s 对齐）", GameLoop.magnet_absorb_cap_now() == 48,
		"v=%d" % GameLoop.magnet_absorb_cap_now())
	_check("A16 30Hz 态原六 const 仍锁定（两态均不改写——套件级锁定条款）",
		DamagePipeline.SETTLE_BUDGET_T1 == 48 and DamagePipeline.SETTLE_BUDGET_T2 == 96
			and DamagePipeline.SETTLE_STALE_FRAME == 12
			and DamagePipeline.DISPATCH_FRAME_CAP == 48
			and DamagePipeline.STALE_FRAME_WINDOW == 30
			and GameLoop.MAGNET_ABSORB_PER_FRAME == 24, "")
	DamagePipeline.settle_budget_override = 7
	_check("A17 override≥0 否决（30Hz 态注入下仍最高优先——r223 口径不破）",
		DamagePipeline._settle_cap_now() == 7,
		"cap=%d" % DamagePipeline._settle_cap_now())
	DamagePipeline.settle_budget_override = -3
	GameLoop.SIM_30HZ_ENABLED = false      # 回退档：-3 哨兵保持 + 开关注入 false
	_check("A18 回退档谓词 false（单开关全联动）", not GameLoop.sim30_effective(), "")
	PerfGovernor.tier_override = 1
	_check("A19 回退 tier1 帽 48（回退档全等）", DamagePipeline._settle_cap_now() == 48, "")
	PerfGovernor.tier_override = 2
	_check("A20 回退 tier2 帽 96（回退档全等）", DamagePipeline._settle_cap_now() == 96, "")
	_check("A21 回退 SETTLE_STALE 12", DamagePipeline.settle_stale_frame_now() == 12, "")
	_check("A22 回退 DISPATCH 48", DamagePipeline.dispatch_frame_cap_now() == 48, "")
	_check("A23 回退 WINDOW 30", DamagePipeline.stale_frame_window_now() == 30, "")
	_check("A24 回退 MAGNET 24", GameLoop.magnet_absorb_cap_now() == 24, "")
	GameLoop.SIM_30HZ_ENABLED = true
	GameLoop.sim30_override = -1
	DamagePipeline.settle_budget_override = -1
	PerfGovernor.mode_override = -1
	PerfGovernor.tier_override = -1
	_check("A25 复位后 headless 谓词 false（注入无泄漏）", not GameLoop.sim30_effective(), "")


# ── ② B 组：30Hz 档位常量值锁定 ───────────────────────────────────

func _test_b_tier_consts() -> void:
	print("── ② 30Hz 档位常量值锁定（新 const 逐位） ──")
	_check("B1 结算档（T1_30HZ=96 ∧ T2_30HZ=192 ∧ STALE_30HZ=6——决策6 供给算术）",
		DamagePipeline.SETTLE_BUDGET_T1_30HZ == 96
			and DamagePipeline.SETTLE_BUDGET_T2_30HZ == 192
			and DamagePipeline.SETTLE_STALE_FRAME_30HZ == 6,
		"%d/%d/%d" % [DamagePipeline.SETTLE_BUDGET_T1_30HZ,
			DamagePipeline.SETTLE_BUDGET_T2_30HZ, DamagePipeline.SETTLE_STALE_FRAME_30HZ])
	_check("B2 派发档（DISPATCH_30HZ=96 ∧ WINDOW_30HZ=15）",
		DamagePipeline.DISPATCH_FRAME_CAP_30HZ == 96
			and DamagePipeline.STALE_FRAME_WINDOW_30HZ == 15,
		"%d/%d" % [DamagePipeline.DISPATCH_FRAME_CAP_30HZ, DamagePipeline.STALE_FRAME_WINDOW_30HZ])
	_check("B3 磁吸档（MAGNET_30HZ=48）", GameLoop.MAGNET_ABSORB_PER_FRAME_30HZ == 48,
		"v=%d" % GameLoop.MAGNET_ABSORB_PER_FRAME_30HZ)


# ── ③ C 组：AC-8 四点半频相位短路 ─────────────────────────────────

func _needle_line_count(p_lines: PackedStringArray, p_needle: String) -> int:
	# 行级子串计数（PackedStringArray.count 是整行等值计数——子串须手扫）
	var n := 0
	for l in p_lines:
		if l.contains(p_needle):
			n += 1
	return n


func _prev_line_guarded(p_lines: PackedStringArray, p_needle: String) -> bool:
	# 源级行守卫检查：p_needle 恰一次出现且其前一行带 sim30 短路守卫
	if _needle_line_count(p_lines, p_needle) != 1:
		return false
	for i in range(1, p_lines.size()):
		if p_lines[i].contains(p_needle):
			return p_lines[i - 1].contains("and not sim30_effective()")
	return false


func _test_c_ac8_short_circuit() -> void:
	print("── ③ AC-8 四点短路（_ui/_fx/_shard 相位 + orbit 重绘节流） ──")
	var gl_fa := FileAccess.open(GL_SOURCE, FileAccess.READ)
	var orbit_fa := FileAccess.open(ORBIT_SOURCE, FileAccess.READ)
	_check("C0 源级断言前置：game_loop/orbit 源可读", gl_fa != null and orbit_fa != null, "")
	if gl_fa == null or orbit_fa == null:
		return
	var gl_src := gl_fa.get_as_text()
	gl_fa.close()
	var gl_lines := gl_src.split("\n")
	var orbit_src := orbit_fa.get_as_text()
	orbit_fa.close()
	# ①②③ 三处 game_loop 相位：守卫文本恰 3 处 + 各成员减量恰一次且前行带守卫
	_check("C1 三处相位守卫文本恰 3 处（mobile ∧ not sim30_effective）",
		gl_src.count("if OS.has_feature(\"mobile\") and not sim30_effective():") == 3,
		"n=%d" % gl_src.count("if OS.has_feature(\"mobile\") and not sim30_effective():"))
	_check("C2 三处相位成员各恰一次减量且前行带守卫（_ui/_fx/_shard）",
		_prev_line_guarded(gl_lines, "_ui_subtick_left -= 1")
		and _prev_line_guarded(gl_lines, "_fx_subtick_left -= 1")
		and _prev_line_guarded(gl_lines, "_shard_subtick_left -= 1"), "")
	# ④ orbit 重绘节流：谓词短路表达式恰一处
	_check("C3 orbit 短路表达式恰一处（sim30_effective() or _redraw_ctr % 2 == 0）",
		orbit_src.count("if GameLoop.sim30_effective() or _redraw_ctr % 2 == 0:") == 1,
		"n=%d" % orbit_src.count("if GameLoop.sim30_effective() or _redraw_ctr % 2 == 0:"))
	# orbit 两态行为对拍（不入树实例——_init 仅 uid，_request_redraw 零树依赖；
	# 逐次调用后读同一谓词+计数器即产线分支逐字复评——C3 源级锁定表达式文本）
	var orbit := OrbitField.new()
	GameLoop.sim30_override = -1
	GameLoop.SIM_30HZ_ENABLED = true
	var fired := 0
	for i in range(8):
		orbit._request_redraw()
		if GameLoop.sim30_effective() or (orbit._redraw_ctr % 2 == 0):
			fired += 1
	_check("C4 orbit 60Hz 态：8 次调用重绘恰 4 次（隔帧阈值逐位不变）且计数器 +8",
		fired == 4 and orbit._redraw_ctr == 8, "fired=%d ctr=%d" % [fired, orbit._redraw_ctr])
	GameLoop.sim30_override = -3
	fired = 0
	for i in range(8):
		orbit._request_redraw()
		if GameLoop.sim30_effective() or (orbit._redraw_ctr % 2 == 0):
			fired += 1
	_check("C5 orbit 30Hz 态：8 次调用重绘 8 次（每 tick 直驱——短路生效）且计数器 +8",
		fired == 8 and orbit._redraw_ctr == 16, "fired=%d ctr=%d" % [fired, orbit._redraw_ctr])
	orbit.free()
	GameLoop.sim30_override = -1
	# headless 两态直驱：OS 门先于谓词——三相位计数器零递减（桌面/headless 口径两态一致；
	# _fx 相位点在 _physics_process PLAYING 分支内联，headless OS 门下两态同走直驱臂，
	# 计数器恒 1 即证；mobile 臂短路由 C1/C2 源级锁定）
	GameLoop.sim30_override = -1
	for i in range(4):
		_gl.call(&"_tick_ui", DT)
	_gl.call(&"_tick_magnetized_shards", DT)
	_gl.call(&"_tick_magnetized_shards", DT)
	_check("C6 60Hz 态 headless 直驱：三相位计数器恒 1（OS 门先于谓词——现状口径零扰动）",
		int(_gl.get("_ui_subtick_left")) == 1 and int(_gl.get("_fx_subtick_left")) == 1
			and int(_gl.get("_shard_subtick_left")) == 1,
		"ui=%s fx=%s shard=%s" % [str(_gl.get("_ui_subtick_left")),
			str(_gl.get("_fx_subtick_left")), str(_gl.get("_shard_subtick_left"))])
	GameLoop.sim30_override = -3
	GameLoop.SIM_30HZ_ENABLED = true
	for i in range(4):
		_gl.call(&"_tick_ui", DT)
	_gl.call(&"_tick_magnetized_shards", DT)
	_gl.call(&"_tick_magnetized_shards", DT)
	_check("C7 30Hz 态 headless 直驱：三相位计数器仍恒 1（两态逐位一致）",
		int(_gl.get("_ui_subtick_left")) == 1 and int(_gl.get("_fx_subtick_left")) == 1
			and int(_gl.get("_shard_subtick_left")) == 1, "")
	GameLoop.sim30_override = -1
	# 披露项：_label_ctr 读数节流（%12/%4 纯表现低危）不在四处清单——设计决策2 未列入，
	# 本断言锁定其未被动过（防顺手改动越出清单）
	_check("C8 label_ctr 披露项未动（%12/%4 各恰一处——决策2 清单外不扩刀）",
		orbit_src.count("_label_ctr % 12") == 1 and orbit_src.count("_label_ctr % 4") == 1,
		"n12=%d n4=%d" % [orbit_src.count("_label_ctr % 12"), orbit_src.count("_label_ctr % 4")])
	_check("C9 磁吸帽源级接线（②⑦ cap := 选择器 ×2 + 满载开帽 ×1）",
		gl_src.count("cap := magnet_absorb_cap_now()") == 2
			and gl_src.count("_fullload_absorb_left = magnet_absorb_cap_now()") == 1,
		"cap=%d open=%d" % [gl_src.count("cap := magnet_absorb_cap_now()"),
			gl_src.count("_fullload_absorb_left = magnet_absorb_cap_now()")])


# ── ④ D 组：派发行为两态对拍（r221 Fix C 同构直构管线） ───────────

func _mk_result(p_uid: int, p_stamp: int = 0) -> DamageResult:
	var r := DamageResult.new()
	r.source_uid = p_uid
	r.final_value = 1.0
	r.frame_stamp = p_stamp
	return r


func _dispatch_capture(p: DamagePipeline) -> Array[int]:
	# 派发捕获（每次新建 uids+lambda——GDScript lambda 按值捕获，复用会钉死旧数组）
	var got: Array[int] = []
	var cb := func(r: DamageResult) -> void: got.append(int(r.source_uid))
	EventBus.damage_resolved.connect(cb)
	p.dispatch_resolved_frame()
	EventBus.damage_resolved.disconnect(cb)
	return got


func _test_d_dispatch_behavior() -> void:
	print("── ④ 派发帽/过期窗两态行为对拍 ──")
	# 60Hz 态：60 条入队首帧恰派 48（r221 Fix C 原口径逐位）
	GameLoop.sim30_override = -1
	GameLoop.SIM_30HZ_ENABLED = true
	var p := DamagePipeline.new()
	for i in range(60):
		p._resolved_queue.append(_mk_result(i + 1))
	var defer0: int = DebugStats.get_counter(&"dispatch_deferred")
	var uids: Array[int] = _dispatch_capture(p)
	_check("D1 60Hz 态 60 条首帧恰派 48（原档帽逐位）", uids.size() == 48,
		"got=%d" % uids.size())
	_check("D2 60Hz 态余 12 留队顺延（deferred +12）",
		p._resolved_queue.size() == 12
			and DebugStats.get_counter(&"dispatch_deferred") - defer0 == 12,
		"q=%d d+%d" % [p._resolved_queue.size(),
			DebugStats.get_counter(&"dispatch_deferred") - defer0])
	_check("D3 60Hz 态保序（队头 1 · 队尾 48）", uids[0] == 1 and uids[47] == 48, "")
	# 30Hz 态：60 条全派（60 ≤ 96）；100 条恰派 96 延 4
	GameLoop.sim30_override = -3
	var p2 := DamagePipeline.new()
	for i in range(60):
		p2._resolved_queue.append(_mk_result(i + 1))
	defer0 = DebugStats.get_counter(&"dispatch_deferred")
	uids = _dispatch_capture(p2)
	_check("D4 30Hz 态 60 条全派（60 ≤ 96——比例平价帽）", uids.size() == 60
		and p2._resolved_queue.is_empty(), "got=%d q=%d" % [uids.size(), p2._resolved_queue.size()])
	_check("D5 30Hz 态顺延零增", DebugStats.get_counter(&"dispatch_deferred") - defer0 == 0,
		"d+%d" % (DebugStats.get_counter(&"dispatch_deferred") - defer0))
	var p3 := DamagePipeline.new()
	for i in range(100):
		p3._resolved_queue.append(_mk_result(i + 1))
	defer0 = DebugStats.get_counter(&"dispatch_deferred")
	uids = _dispatch_capture(p3)
	_check("D6 30Hz 态 100 条恰派 96 延 4（新档帽边界）", uids.size() == 96
		and p3._resolved_queue.size() == 4
		and DebugStats.get_counter(&"dispatch_deferred") - defer0 == 4,
		"got=%d q=%d" % [uids.size(), p3._resolved_queue.size()])
	# 过期窗边界（双向距离判）：30Hz 档 15 帧——距 15 留 / 距 16 丢
	var keep := DamagePipeline.new()
	keep._cur_frame_stamp = 1015
	keep._resolved_queue.append(_mk_result(1, 1000))
	var drop0: int = DebugStats.get_counter(&"dispatch_stale_drop")
	uids = _dispatch_capture(keep)
	_check("D7 30Hz 态窗距 15 留（恰边界——0.5s 语义）", uids.size() == 1
		and DebugStats.get_counter(&"dispatch_stale_drop") == drop0,
		"got=%d drop+%d" % [uids.size(), DebugStats.get_counter(&"dispatch_stale_drop") - drop0])
	var drop_p := DamagePipeline.new()
	drop_p._cur_frame_stamp = 1016
	drop_p._resolved_queue.append(_mk_result(1, 1000))
	uids = _dispatch_capture(drop_p)
	_check("D8 30Hz 态窗距 16 丢（stale_drop +1——有界卸载）", uids.is_empty()
		and DebugStats.get_counter(&"dispatch_stale_drop") - drop0 == 1,
		"got=%d drop+%d" % [uids.size(), DebugStats.get_counter(&"dispatch_stale_drop") - drop0])
	# 60Hz 档窗 30 帧原口径：距 30 留 / 距 31 丢（重取 stale_drop 基线——D8 已 +1）
	GameLoop.sim30_override = -1
	var drop60: int = DebugStats.get_counter(&"dispatch_stale_drop")
	var keep60 := DamagePipeline.new()
	keep60._cur_frame_stamp = 1030
	keep60._resolved_queue.append(_mk_result(1, 1000))
	uids = _dispatch_capture(keep60)
	_check("D9 60Hz 态窗距 30 留（原档边界逐位）", uids.size() == 1
		and DebugStats.get_counter(&"dispatch_stale_drop") == drop60,
		"got=%d" % uids.size())
	var drop60p := DamagePipeline.new()
	drop60p._cur_frame_stamp = 1031
	drop60p._resolved_queue.append(_mk_result(1, 1000))
	uids = _dispatch_capture(drop60p)
	_check("D10 60Hz 态窗距 31 丢（原档边界逐位）", uids.is_empty()
		and DebugStats.get_counter(&"dispatch_stale_drop") - drop60 == 1, "")
	GameLoop.sim30_override = -1


# ── ⑤ E 组：结算顺延过期强冲两态对拍（r223 ⑤ 同构真件管线） ───────

func _fixture_enemy(p_id: StringName, p_hp: float) -> EnemyData:
	var d := EnemyData.new()
	d.id = p_id
	d.display_name = String(p_id)
	d.hp_base = p_hp
	d.spd_base = 0.0
	d.dmg_base = 0.0
	d.exp_base = 1.0
	d.hitbox_r = 14.0
	d.resist = [0.0, 0.0, 0.0, 0.0]
	return d


func _spawn_enemy(p_id: StringName, p_hp: float = 100000.0) -> Enemy:
	var pool := _gl.pools[&"enemy"] as EnemyPool
	var e := pool.acquire() as Enemy
	e.spawn(_fixture_enemy(p_id, p_hp), 1, 0)
	e._fade_left = 0.0
	e.modulate.a = 1.0
	_released.append(e)
	return e


func _release_all() -> void:
	var pool := _gl.pools[&"enemy"] as EnemyPool
	for e in _released:
		if is_instance_valid(e) and not e.dead:
			pool.release(e)
	_released.clear()


func _mk_ctx(p_source: int, p_target: Enemy, p_base: float, p_frame: int) -> DamageContext:
	var ctx := DamageContext.make()
	ctx.source_uid = p_source
	ctx.target_uid = p_target.uid
	ctx.target = p_target
	ctx.frame_stamp = p_frame
	ctx.base_atk = p_base
	ctx.crit_chance = 0.0
	ctx.crit_mult = 2.0
	ctx.pos = p_target.global_position
	return ctx


func _fifo_size() -> int:
	return (_gl.pipeline.get(&"_pending_fifo") as Array).size()


func _stat(p_key: String) -> int:
	return int((_gl.pipeline.call(&"stats") as Dictionary).get(p_key, 0))


func _stale_probe(p_frame: int) -> void:
	# 过期强冲探针：一对 begin/end——帧头按预算冲 + 帧末维护扫 SETTLE_STALE 窗
	# （r223 ⑤ 同构：预算 1/帧 持续欠账 → 积压整批老化越窗后一次性强冲）
	_gl.pipeline.call(&"begin_frame", p_frame)
	_gl.pipeline.call(&"end_frame")


func _test_e_settle_stale_behavior() -> void:
	print("── ⑤ 结算顺延过期强冲两态对拍（12 帧 vs 6 帧） ──")
	# 60Hz 档（12 帧窗原口径）：override=1 → 30 发中 1 真结算 + 29 顺延 @F；
	# F+1..F+12 每帧预算冲 1（stale 零增——老化未越 12 帧窗）→ F+13 帧头再冲 1
	# + 帧末强冲余 16（1+13+16=30 守恒；settle_flush 含强冲=13+16=29）。
	GameLoop.sim30_override = -1
	GameLoop.SIM_30HZ_ENABLED = true
	DamagePipeline.settle_budget_override = 1
	var e := _spawn_enemy(&"E_R233_T1")
	_gl.pipeline.call(&"begin_frame", 2000)
	for i in range(30):
		_gl.pipeline.call(&"resolve", _mk_ctx(7900 + i, e, 10.0, 2000))
	_gl.pipeline.call(&"end_frame")
	var fl0 := _stat("settle_flush")
	var st0 := _stat("settle_stale_flush")
	for k in range(1, 13):
		_stale_probe(2000 + k)
	_check("E1 60Hz 态 12 探针帧 stale 零增（12 帧窗原口径）∧ 预算冲 12 ∧ FIFO 17",
		_stat("settle_stale_flush") == st0 and _stat("settle_flush") - fl0 == 12
			and _fifo_size() == 17,
		"stale+%d drain+%d fifo=%d" % [_stat("settle_stale_flush") - st0,
			_stat("settle_flush") - fl0, _fifo_size()])
	_stale_probe(2013)
	_check("E2 60Hz 态 F+13 强冲 16（预算冲合计 13 + stale 16 = 29 守恒 · FIFO 清空）",
		_stat("settle_stale_flush") - st0 == 16 and _stat("settle_flush") - fl0 == 29
			and _fifo_size() == 0,
		"stale+%d drain+%d fifo=%d" % [_stat("settle_stale_flush") - st0,
			_stat("settle_flush") - fl0, _fifo_size()])
	DamagePipeline.settle_budget_override = -1
	_gl.pipeline.get(&"_pending_pair").clear()
	(_gl.pipeline.get(&"_pending_fifo") as Array).clear()
	# 30Hz 档（6 帧窗——0.2s 时间语义守恒）：F+1..F+6 stale 零增 → F+7 帧头冲 1
	# + 帧末强冲余 22（1+7+22=30 守恒）。
	GameLoop.sim30_override = -3
	DamagePipeline.settle_budget_override = 1
	var e2 := _spawn_enemy(&"E_R233_T2")
	_gl.pipeline.call(&"begin_frame", 3000)
	for i in range(30):
		_gl.pipeline.call(&"resolve", _mk_ctx(8900 + i, e2, 10.0, 3000))
	_gl.pipeline.call(&"end_frame")
	fl0 = _stat("settle_flush")
	st0 = _stat("settle_stale_flush")
	for k in range(1, 7):
		_stale_probe(3000 + k)
	_check("E3 30Hz 态 6 探针帧 stale 零增（恰 6 帧窗边界——0.2s 语义）∧ 预算冲 6 ∧ FIFO 23",
		_stat("settle_stale_flush") == st0 and _stat("settle_flush") - fl0 == 6
			and _fifo_size() == 23,
		"stale+%d drain+%d fifo=%d" % [_stat("settle_stale_flush") - st0,
			_stat("settle_flush") - fl0, _fifo_size()])
	_stale_probe(3007)
	_check("E4 30Hz 态 F+7 强冲 22（预算冲合计 7 + stale 22 = 29 守恒 · FIFO 清空——击杀后移体感不翻倍）",
		_stat("settle_stale_flush") - st0 == 22 and _stat("settle_flush") - fl0 == 29
			and _fifo_size() == 0,
		"stale+%d drain+%d fifo=%d" % [_stat("settle_stale_flush") - st0,
			_stat("settle_flush") - fl0, _fifo_size()])
	DamagePipeline.settle_budget_override = -1
	_gl.pipeline.get(&"_pending_pair").clear()
	(_gl.pipeline.get(&"_pending_fifo") as Array).clear()
	GameLoop.sim30_override = -1


# ── 收尾 ──────────────────────────────────────────────────────────

func _cleanup() -> void:
	GameLoop.SIM_30HZ_ENABLED = true       # 注入态复位（前置防呆——用例内已各自复位）
	GameLoop.sim30_override = -1
	PerfGovernor.mode_override = -1
	PerfGovernor.tier_override = -1
	_release_all()
	_check("套件总项数（EXPECTED=%d——R231 假绿教训：总项数也要断言）" % EXPECTED_TOTAL,
		_pass + _fail == EXPECTED_TOTAL, "实=%d" % (_pass + _fail))
	_gl.state = GameConst.GameStatus.MENU
	PerfGovernor.set_process(true)
	if _gl != null:
		_gl.queue_free()
		await tree.process_frame

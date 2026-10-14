# tests/qa_r268_physphase_cases.gd — R268 物理相四性能刀用例体（入口 qa_r268_physphase.gd 运行时 load）。
# 夹具先例：DiagStub+缓存口直指（tests/runner/r245_diag_gate_cases.gd）/ GameLoop boot
# （tests/runner/qa_r218_probe_cases.gd）/ 升格限批断言（tests/runner/r212_carddigest_cases.gd ⑦）。
# 零全局 rng（全确定性注入）；覆写口用毕复位（trail_halffreq_override/label_refresh_cap_override/
# fx_quality/fullload_override/_diag_gl_cache）。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const GAME_LOOP_SRC := "res://scripts/loop/game_loop.gd"
const DIAG_SRC := "res://autoload/debug_stats.gd"
const PROJ_SRC := "res://scripts/combat/projectile/projectile_base.gd"
const DT := 1.0 / 60.0
const RXN_ID := GameConst.ReactionType.RXN_FIR_ICE   # 反应中性 ID（枚举序 0，game_const.gd:433 真源）

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null


class DiagStub extends Node:
	# 诊断秒窗累计最小桩（state + 双 probe 字典 + diag_counts——DebugStats 鸭式消费面；
	# r245_diag_gate_cases.gd DiagStub 同式）
	var state: int = 0
	var stage_probe_us: Dictionary = {}
	var stage_probe_us_peak: Dictionary = {}

	func diag_counts() -> Dictionary:
		return {}

	func diag_reset_stage_peaks() -> void:
		pass


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	_boot()
	await _test_p2_physphase_accounting()       # P2 先修口径（stub 直指缓存；含 await 协程）
	_test_p1_upgrade_arm()                      # P1 升格臂绕帽
	_test_p3_trail()                            # P3 拖尾半频门+长度档位
	_test_p4_prewarm_gate()                     # P4 预热深载门四象限
	_teardown()
	print("────────────────────────────────────────")
	print("验收汇总：PASS %d / FAIL %d" % [_pass, _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)


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


func _boot() -> void:
	# GameLoop 实例 boot（qa_r218_probe_cases.gd _boot 同式——MENU 静场，帧手动驱动）
	var scene: PackedScene = load(MAIN_SCENE)
	var gl: GameLoop = scene.instantiate() as GameLoop
	gl.name = "R268PhysphaseGL"
	tree.get_root().add_child(gl)
	_gl = gl
	gl.state = GameConst.GameStatus.MENU
	gl.current_map_id = MapTable.FIRST_MAP_ID
	gl.start_run()
	gl.state = GameConst.GameStatus.MENU
	gl.player.global_position = Vector2(360.0, 900.0)


func _teardown() -> void:
	tree.paused = false
	Enemy.fullload_override = -1
	ProjectileBase.trail_halffreq_override = -1     # R268 P3 注入口复位（套件纪律）
	DebugStats.set("_diag_gl_cache", null)          # 缓存失效（r245 teardown 同式）
	DebugStats.set("_diag_gl_scan_after_ms", 0)
	DebugStats._diag_reset_window_acc()
	if _gl != null:
		if _gl.popup_manager != null:
			_gl.popup_manager.label_refresh_cap_override = -1
			_gl.popup_manager.clear_all()
		_gl.stage_probe_enabled = false
		_gl.free()
		_gl = null
	RunSave.clear()


# ── P2 记账洞三表（popup 出排除表——物步减项/余值段和/他键段和三处同步） ──
func _test_p2_physphase_accounting() -> void:
	print("── P2 记账洞三表 ──")
	# P2a 物步口径：合成 probe_raw 注入（r245 B 组同式）——减项含 popup
	var stub: DiagStub = DiagStub.new()
	stub.name = "R268PhysphaseStub"
	tree.get_root().add_child(stub)
	DebugStats.set("_diag_gl_cache", stub)          # 缓存口直指桩（旁路树扫/1s 节流）
	DebugStats.set("_diag_gl_scan_after_ms", 0)
	DebugStats.set("_diag_phys_acc_last", -1)
	stub.state = GameConst.GameStatus.PLAYING
	stub.stage_probe_us = {&"dispatch": 30, &"entry": 100, &"player": 200,
		&"player_mv": 50, &"player_wp": 60, &"popup": 5000}
	DebugStats._diag_reset_window_acc()
	for i in range(4):                              # 多帧累计（物理帧判重口径——r245 _acc_frames 同式）
		DebugStats.set("_diag_last_ms", Time.get_ticks_msec())
		DebugStats._diag_accumulate_window(DT)
		await tree.physics_frame
		await tree.process_frame
	var samples: int = int(DebugStats.get("_diag_phys_samples"))
	var gd_us: int = int(DebugStats.get("_diag_phys_gd_us"))
	# 每样本减项 = dispatch30+entry100+player200+popup5000=5330（移50/火60 仍排除）——
	# 旧口径每样本 330；等式成立即 popup 5000µs 已入减项（样本数不钉死：autoload 侧
	# _process 并发累计同式加值，比值不变）
	_check("P2a 物步减项含 popup：gd_us==样本数×5330（popup 5000µs 入减项、移/火仍排除）",
		samples >= 1 and gd_us == samples * 5330,
		"samples=%d gd=%d（期望 ×5330）" % [samples, gd_us])
	stub.queue_free()
	DebugStats.set("_diag_gl_cache", null)
	DebugStats.set("_diag_gl_scan_after_ms", 0)
	DebugStats._diag_reset_window_acc()
	# P2b 「他」口径：game_loop 帧尾段和——无独立函数面（inline 于 _physics_process 尾），
	# 取 源锚（排除表仅 移/火）+ 真帧共存（popup 段实测>0 与 他 键在位）
	var gl_src := FileAccess.get_file_as_string(GAME_LOOP_SRC)
	_check("P2b 源锚：game_loop.gd 段和排除表仅 移/火（popup 已出表）",
		not gl_src.contains("and key != &\"popup\""), "")
	_gl.state = GameConst.GameStatus.PLAYING
	_gl.stage_probe_enabled = true
	var pm: PopupManager = _gl.popup_manager
	pm.label_refresh_cap_override = 0
	for i in range(40):                             # 40 张直击小字（r212 ⑦ 同式）
		var r := DamageResult.new()
		r.final_value = 7.0
		r.target_uid = 29000 + i
		r.pos = Vector2(360.0, 400.0)
		r.popup_style = GameConst.PopupStyle.NORMAL
		pm.on_damage_resolved(r)
	for i in range(40):                             # 二次结算并入 → 40 张全脏
		var r2 := DamageResult.new()
		r2.final_value = 3.0
		r2.target_uid = 29000 + i
		r2.pos = Vector2(360.0, 400.0)
		r2.popup_style = GameConst.PopupStyle.NORMAL
		pm.on_damage_resolved(r2)
	_gl._physics_process(DT)                        # 真帧：⑧段 popup tick 排版批 → 段实测
	var probe: Dictionary = _gl.stage_probe_us
	_check("P2b 真帧共存：popup 段实测>0 且 他 键在位 ≥0（popup 入段和后他键不背跳字成本）",
		int(probe.get(&"popup", -1)) > 0 and probe.has(&"other")
			and int(probe.get(&"other", -1)) >= 0,
		"popup=%d other=%s" % [int(probe.get(&"popup", -1)), str(probe.get(&"other", -1))])
	_gl.stage_probe_enabled = false
	pm.clear_all()
	pm.label_refresh_cap_override = -1
	_gl.state = GameConst.GameStatus.MENU
	# P2c 余值口径：合成帧函数级（qa_r218 ⑥c 同式——独立 DebugStats 实例拼行）
	var ds: Node = (load(DIAG_SRC) as GDScript).new()
	_gl.stage_probe_us = {&"player": 1000, &"player_mv": 100000, &"player_wp": 100000,
		&"popup": 5000, &"ui": 2000, &"other": 3000}
	var line_with: String = String(ds.call(&"_diag_format_line", _gl, Time.get_ticks_msec()))
	var fps_with := maxi(_extract_int(line_with, "fps"), 1)
	# 含 popup 段和 = 1+5+2+3=11ms（移/火各 100ms 仍排除）；对照 popup=0 → 6ms
	var expect_with := maxi(int(round(1000.0 / float(fps_with) - 11.0)), 0)
	var actual_with := _extract_int(line_with, "余")
	_check("P2cpre 行内 fps 口径非退化（fps≤90，帧预算>11ms 断言才有效）", fps_with <= 90,
		"fps=%d" % fps_with)
	_check("P2c 余值含 popup：余==帧预算−11ms（popup 5ms 入段和）",
		actual_with == expect_with,
		"actual=%d expect=%d fps=%d" % [actual_with, expect_with, fps_with])
	_gl.stage_probe_us[&"popup"] = 0
	var line_without: String = String(ds.call(&"_diag_format_line", _gl, Time.get_ticks_msec()))
	var fps_wo := maxi(_extract_int(line_without, "fps"), 1)
	var expect_without := maxi(int(round(1000.0 / float(fps_wo) - 6.0)), 0)
	var actual_without := _extract_int(line_without, "余")
	_check("P2c 对照：popup=0 时余==帧预算−6ms（其余口径零漂移）",
		actual_without == expect_without,
		"actual=%d expect=%d fps=%d" % [actual_without, expect_without, fps_wo])
	_gl.stage_probe_us = {}
	ds.free()


# ── P1 升格臂绕帽（upgrade_to_reaction 置脏走 tick 限批，与 merge 通道同契约） ──
func _test_p1_upgrade_arm() -> void:
	print("── P1 升格臂绕帽 ──")
	var pm: PopupManager = _gl.popup_manager
	pm.label_refresh_cap_override = 0
	var pops: Array[DamagePopup] = []
	for i in range(12):
		var r := DamageResult.new()
		r.final_value = 10.0
		r.target_uid = 28000 + i
		r.pos = Vector2(360.0, 400.0)
		r.popup_style = GameConst.PopupStyle.NORMAL
		pm.on_damage_resolved(r)
	for p in pm._active_list:
		pops.append(p)
	_check("P1pre 12 张直击小字在册（升格宿主就位）", pops.size() == 12,
		"n=%d" % pops.size())
	# P1a 升格不即时排版
	var p0: DamagePopup = pops[0]
	var calls0: int = DamagePopup.refresh_label_calls
	p0.upgrade_to_reaction(50.0, RXN_ID)
	var calls1: int = DamagePopup.refresh_label_calls
	_check("P1a 升格不即时排版（refresh_label_calls 不即时 +1）", calls1 == calls0,
		"before=%d after=%d" % [calls0, calls1])
	_check("P1a 升格置脏（_label_dirty==true，merge 通道同契约）", p0._label_dirty, "")
	_check("P1a merged_value 已含并入值（10+50=60）", absf(p0.merged_value - 60.0) < 0.001,
		"merged=%s" % str(p0.merged_value))
	_check("P1a style==REACTION 且 tier==0",
		p0.style == GameConst.PopupStyle.REACTION and p0.tier == 0,
		"style=%d tier=%d" % [p0.style, p0.tier])
	# P1b tick 限批收敛（cap=6 注入，r212 ⑦ 同款覆写路径）
	pm.label_refresh_cap_override = 6
	for i in range(1, 12):
		pops[i].upgrade_to_reaction(50.0, RXN_ID)   # 其余 11 张升格置脏
	var dirty_all := 0
	for p in pm._active_list:
		if p._label_dirty:
			dirty_all += 1
	_check("P1bpre 12 张全部置脏", dirty_all == 12, "dirty=%d" % dirty_all)
	DamagePopup.refresh_label_calls = 0
	pm.tick(DT)
	var batch1: int = DamagePopup.refresh_label_calls
	_check("P1b 单帧排版 ≤6（限批生效）", batch1 <= 6, "batch=%d" % batch1)
	var frames := 1
	while _dirty_count(pm) > 0 and frames < 12:
		pm.tick(DT)
		frames += 1
	_check("P1b 12 条升格脏字 ceil(12/6)=2 帧内全部收敛",
		_dirty_count(pm) == 0 and frames <= 2,
		"frames=%d dirty=%d" % [frames, _dirty_count(pm)])
	var all_rxn := true
	for p in pops:
		if not is_instance_valid(p) or p.style != GameConst.PopupStyle.REACTION:
			all_rxn = false
	_check("P1b 收敛后全部 REACTION 样式", all_rxn, "")
	var lbl := p0.get_node_or_null("Value") as Label
	_check("P1b 反应臂数值刷新到位（文本含 60）",
		lbl != null and lbl.text.contains("60"),
		"text=%s" % (lbl.text if lbl != null else "<null>"))
	# P1b2 超龄强制臂（脏龄 ≥LABEL_STALE_FORCE_S=0.25s 注入 → 绕帽刷新不饿死）
	for i in range(8):
		pops[i].merge(5.0)                          # 重新置脏 8 张
	pops[0]._dirty_age = 0.3                        # ≥0.25s（强制臂阈值）
	pops[1]._dirty_age = 0.3
	DamagePopup.refresh_label_calls = 0
	pm.tick(DT)
	_check("P1b2 超龄脏字绕帽强制刷新（cap6 下 6+2 超龄全刷=8）",
		DamagePopup.refresh_label_calls == 8,
		"calls=%d" % DamagePopup.refresh_label_calls)
	# P1c 桌面零扰动（cap=0 不限批——升格后首个 tick 即全量刷新，与现状同帧）
	pm.label_refresh_cap_override = 0
	for p in pops:
		p.upgrade_to_reaction(1.0, RXN_ID)          # 重置脏（升格臂同通道）
	DamagePopup.refresh_label_calls = 0
	pm.tick(DT)
	_check("P1c 桌面口径一帧 12 张全量刷新（cap=0 与现状同帧）",
		DamagePopup.refresh_label_calls == 12,
		"calls=%d" % DamagePopup.refresh_label_calls)
	pm.clear_all()
	pm.label_refresh_cap_override = -1


# ── P3 拖尾重绘半频门 + 刺击拖尾长度档位（projectile_base） ──────────
func _test_p3_trail() -> void:
	print("── P3 拖尾半频门 + 长度档位 ──")
	var proj: ProjectileBase = (load(PROJ_SRC) as GDScript).new()
	# P3a 半频门（mobile 注入口）：dt=1/60 ×60 → 恰 30 次真（±1 容差）
	ProjectileBase.trail_halffreq_override = 1
	var truths := 0
	for i in range(60):
		if proj._trail_redraw_due(DT):
			truths += 1
	_check("P3a dt=1/60 一秒恰 ≈30 次真（±1）", truths >= 29 and truths <= 31,
		"truths=%d" % truths)
	var lowfps_all := true
	for i in range(30):                             # dt=1/30 序列恒真（低帧率不降级）
		if not proj._trail_redraw_due(1.0 / 30.0):
			lowfps_all = false
	_check("P3a dt=1/30 序列恒真（掉帧不减半语义）", lowfps_all, "")
	ProjectileBase.trail_halffreq_override = 0      # 桌面注入口：逐帧恒真（现状零变化）
	var desk_all := true
	for i in range(10):
		if not proj._trail_redraw_due(DT):
			desk_all = false
	_check("P3a 桌面口径恒真（逐帧重绘零变化）", desk_all, "")
	ProjectileBase.trail_halffreq_override = -1     # 复位（套件纪律）
	# P3b 长度档位表单源断言（tier1==半额 / tier2、desktop==原值）
	var tbl: Array = ProjectileBase.SWORD_TRAIL_LEN_BY_FXQ
	var t0: float = tbl[0]
	var t1: float = tbl[1]
	var t2: float = tbl[2]
	_check("P3b tier1(q0) 拖尾段长 == SWORD_TRAIL_LEN*0.5",
		absf(t0 - ProjectileBase.SWORD_TRAIL_LEN * 0.5) < 0.001, "t0=%s" % str(t0))
	_check("P3b tier2/desktop(q1/q2) == SWORD_TRAIL_LEN 原值",
		t1 == ProjectileBase.SWORD_TRAIL_LEN and t2 == ProjectileBase.SWORD_TRAIL_LEN,
		"t1=%s t2=%s" % [str(t1), str(t2)])
	# 函数接线：Meta 注入 q0→半额 / q2→原值（用毕还原）
	var meta := tree.get_root().get_node_or_null("Meta")
	var q_env: int = int(meta.call(&"settings", "fx_quality"))
	meta.call(&"set_setting", "fx_quality", 0)
	var len_q0: float = proj._sword_trail_len()
	meta.call(&"set_setting", "fx_quality", 2)
	var len_q2: float = proj._sword_trail_len()
	meta.call(&"set_setting", "fx_quality", q_env)
	_check("P3b fx_quality=0 → _sword_trail_len()==半额（接线正确）",
		absf(len_q0 - ProjectileBase.SWORD_TRAIL_LEN * 0.5) < 0.001,
		"len=%s" % str(len_q0))
	_check("P3b fx_quality=2 → _sword_trail_len()==原值（接线正确）",
		absf(len_q2 - ProjectileBase.SWORD_TRAIL_LEN) < 0.001,
		"len=%s" % str(len_q2))
	proj.free()


# ── P4 预热泵深载门（_playing_prewarm_budget 四象限 + 调用点接线） ────
func _test_p4_prewarm_gate() -> void:
	print("── P4 预热深载门 ──")
	var desktop: Vector2i = _gl._playing_prewarm_budget(false, 1, true)
	_check("P4 desktop（tier1+满载）== (2000,4000)", desktop == Vector2i(2000, 4000),
		str(desktop))
	var deep: Vector2i = _gl._playing_prewarm_budget(true, 1, true)
	_check("P4 mobile+tier1+满载 == (500,1000)", deep == Vector2i(500, 1000), str(deep))
	var t3: Vector2i = _gl._playing_prewarm_budget(true, 3, true)
	_check("P4 mobile+tier3（满载）== (2000,4000)", t3 == Vector2i(2000, 4000), str(t3))
	var t2_nofull: Vector2i = _gl._playing_prewarm_budget(true, 2, false)
	_check("P4 mobile+tier2+非满载 == (2000,4000)", t2_nofull == Vector2i(2000, 4000),
		str(t2_nofull))
	var t2_full: Vector2i = _gl._playing_prewarm_budget(true, 2, true)
	_check("P4 mobile+tier2+满载 == (500,1000)（tier≤2 全带收缩）",
		t2_full == Vector2i(500, 1000), str(t2_full))
	var src := FileAccess.get_file_as_string(GAME_LOOP_SRC)
	_check("P4 调用点接线：DescPrewarm.pump(_pw_budget.x) + _process_tex_prewarm(_pw_budget.y, true)",
		src.contains("DescPrewarm.pump(_pw_budget.x)")
			and src.contains("_process_tex_prewarm(_pw_budget.y, true)"), "")


# ── 共用小件 ──────────────────────────────────────────────────────
func _dirty_count(p_pm: PopupManager) -> int:
	# 脏弹字计数（r212 _dirty_count 同式）
	var n := 0
	for p in p_pm._active_list:
		if p._label_dirty:
			n += 1
	return n


func _extract_int(p_line: String, p_key: String) -> int:
	# 行内「键N」取值（qa_r218 ⑥c2 同款读取式）
	var rx := RegEx.new()
	rx.compile("%s(-?\\d+)" % p_key)
	var m := rx.search(p_line)
	return int(m.get_string(1)) if m != null else -1

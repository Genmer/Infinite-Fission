# tests/runner/r220_governor_cases.gd
# R220 模式地基用例体（入口 test_r220_governor.gd 运行时 load——-s 编译期禁引工程类名纪律）。
# 覆盖（R220 拆解契约 §5.1 + 主控验收单①-⑤）：
# ① perf_mode 双注册（默认 0 / clampi 0,1 / 未知键静默丢弃 / 写盘重读还原）
# ② 设置面板「优先模式」行（帧率上限行后插行 / 两态循环 / 十行重排几何钉死 / 写口即翻转）
# ③ PerfGovernor 帧率优先转换序（<0.90 降档至地板 1 / >0.95 升档帽 3 / 双侧迟滞带 /
#    transitions 与档变一一对应）
# ④ 特效优先（<0.70 地板 2 / 0.85 升档阈值同值对照 / 模式切换计时清零 tier 保持）
# ⑤ paused / LEVEL_UP 期转换计时挂起（冻结不清零、不清 EMA）
# ⑥ 读序（mode_override > settings）+ tier_override 直驱（不跑转换不计数）
# ⑦ Enemy._fx_q 映射写点（默认零扰动 + override 档变联动 + 源级锚）
# ⑧ 注册序（PerfGovernor 晚于 Meta）/ PROCESS_MODE_ALWAYS / 冻结常量 / 计数器审计块
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const DT := 1.0 / 60.0
const EPS := 0.0001

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	PerfGovernor.mode_override = -1          # 注入面复位（缺省真值通道）
	PerfGovernor.tier_override = -1
	PerfGovernor._ema_inject = -1.0
	_test_1_key_contract()
	await _boot_game_loop()                 # 协程收口（add_child 后过一帧再取 Main——r218 同款）
	await _test_2_panel_row()
	PerfGovernor.set_process(false)          # 引擎侧停走——用例手动 _process 确定性步进（cleanup 复位）
	_test_3_frame_mode_transitions()
	_test_4_fx_mode_transitions()
	_test_5_suspend()
	_test_6_read_order_and_override()
	_test_7_enemy_fx_mapping()
	_test_8_registration_order()
	_cleanup()
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
	await tree.process_frame
	_gl = tree.root.get_node_or_null("Main") as GameLoop
	if _gl == null:
		for c in tree.root.get_children():
			if c is GameLoop:
				_gl = c
				break


func _teardown_game_loop() -> void:
	if _gl != null:
		_gl.queue_free()
		await tree.process_frame


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


# ── 调速器阶段复位/步进（_test_reset 只清实例侧——EMA 清空 → 首采直赋注入值） ──
func _pg_setup(p_tier: int, p_transitions: int, p_ema: float, p_mode_override: int) -> void:
	PerfGovernor.mode_override = p_mode_override
	PerfGovernor.tier_override = -1
	PerfGovernor.tier = p_tier
	PerfGovernor.transitions = p_transitions
	PerfGovernor._ema_inject = p_ema
	PerfGovernor._test_reset()
	_gl.state = GameConst.GameStatus.PLAYING
	tree.paused = false


func _tick(p_n: int) -> void:
	for i in p_n:
		PerfGovernor._process(PerfGovernor.SAMPLE_S)


# ── ① perf_mode 键契约（双注册——缺一半静默失效，照 r202_perf 域K 模式） ──
func _test_1_key_contract() -> void:
	print("── ① perf_mode 键契约（双注册/钳制/持久化） ──")
	_check("①SETTINGS_DEFAULTS 含 perf_mode（读侧注册）且默认 0",
		Meta.SETTINGS_DEFAULTS.has("perf_mode") and int(Meta.SETTINGS_DEFAULTS.get("perf_mode")) == 0,
		"val=%s" % str(Meta.SETTINGS_DEFAULTS.get("perf_mode")))
	Meta.set_setting("perf_mode", 0)
	Meta.set_setting("perf_mode", 5)
	_check("①写口钳制：set 5 → 1（clampi int 0,1）",
		int(Meta.settings("perf_mode")) == 1, "val=%s" % str(Meta.settings("perf_mode")))
	Meta.set_setting("perf_mode", -3)
	_check("①写口钳制：set -3 → 0",
		int(Meta.settings("perf_mode")) == 0, "val=%s" % str(Meta.settings("perf_mode")))
	Meta.set_setting("r220_unknown_key", 1)
	_check("①未知键静默丢弃（不写不落盘——脏写穿档防口不回归）",
		Meta.settings("r220_unknown_key") == null and not Meta._settings.has("r220_unknown_key"),
		"val=%s" % str(Meta.settings("r220_unknown_key")))
	Meta.set_setting("perf_mode", 1)
	Meta._load()
	_check("①持久化：写 1 落盘 → _load 重读还原 1（写 settings 重读还原）",
		int(Meta.settings("perf_mode")) == 1, "val=%s" % str(Meta.settings("perf_mode")))
	Meta.set_setting("perf_mode", 0)
	_check("①复位 0（写即存）+ frame_priority() 缺省通道 true",
		int(Meta.settings("perf_mode")) == 0 and PerfGovernor.frame_priority() == true,
		"val=%s fp=%s" % [str(Meta.settings("perf_mode")), str(PerfGovernor.frame_priority())])


# ── ② 设置面板「优先模式」行 ────────────────────────────────────────
func _test_2_panel_row() -> void:
	print("── ② 设置面板「优先模式」行（插行/两态循环/几何重排） ──")
	Meta.set_setting("perf_mode", 0)
	var sp: SettingsPanel = _gl.settings_panel
	sp.open()
	await tree.process_frame
	var row_label: Label = null
	for kid in sp._card.get_children():
		var l := kid as Label
		if l != null and l.text == "优先模式":
			row_label = l
	_check("②行文案「优先模式」在卡（左标签）", row_label != null)
	_check("②按钮在卡（PerfModeButton）且首态 ✓ 帧率优先",
		sp._perf_mode_btn != null and sp._perf_mode_btn.text == "✓ 帧率优先",
		"text=%s" % (sp._perf_mode_btn.text if sp._perf_mode_btn != null else "null"))
	_check("②插行位置：「帧率上限」行之后、「震屏」行之前",
		sp._fps_btn != null and sp._perf_mode_btn != null and sp._shake_btn != null
			and sp._fps_btn.position.y < sp._perf_mode_btn.position.y
			and sp._perf_mode_btn.position.y < sp._shake_btn.position.y,
		"fps=%s perf=%s shake=%s" % [str(sp._fps_btn.position.y if sp._fps_btn != null else -1.0),
			str(sp._perf_mode_btn.position.y if sp._perf_mode_btn != null else -1.0),
			str(sp._shake_btn.position.y if sp._shake_btn != null else -1.0)])
	# 几何底线：十开关行互不重叠 / 行距 46 钉死 / 末行钮底 812 ≤ hint 顶 824−6px / 卡高 968 不扩
	var btns: Array = [sp._fx_btn, sp._fps_btn, sp._perf_mode_btn, sp._shake_btn, sp._dmg_btn,
		sp._show_fps_btn, sp._diag_log_btn, sp._diag_len_btn, sp._pos_btn, sp._codex_reset_btn]
	var all_present := true
	for b in btns:
		if b == null:
			all_present = false
	var pair_overlap: Array[String] = []
	var ys: Array[float] = []
	if all_present:
		for b in btns:
			ys.append((b as Control).position.y)
		ys.sort()
		for i in range(btns.size()):
			for j in range(i + 1, btns.size()):
				var ba := btns[i] as Control
				var bb := btns[j] as Control
				if ba.get_rect().intersects(bb.get_rect()):
					pair_overlap.append("%s∩%s" % [ba.name, bb.name])
	_check("②十开关行按钮互不重叠（行距 52→46 / 钮高 48→44 重排零重叠）",
		all_present and pair_overlap.is_empty(), str(pair_overlap))
	var height_ok := true
	for b in btns:
		if b != null and absf((b as Control).size.y - 44.0) > 0.01:
			height_ok = false
	_check("②钮高 44（= R194 触控目标下限——塞卡不扩高）", all_present and height_ok, "")
	var spacing_ok := ys.size() == 10 and absf(ys[0] - 354.0) < 0.01 and absf(ys[9] - 768.0) < 0.01
	for i in range(1, ys.size()):
		if absf(ys[i] - ys[i - 1] - 46.0) > 0.01:
			spacing_ok = false
	_check("②十行 354..768、行距 46（重排钉死——不扩卡高塞入）",
		spacing_ok, "ys=%s" % str(ys))
	var last_btn: Control = btns[9] as Control if btns.size() == 10 else null
	var last_bottom: float = last_btn.position.y + last_btn.size.y if last_btn != null else 9999.0
	_check("②末行钮底 812 ≤ hint 顶 824−6px（卡内不溢）",
		absf(last_bottom - 812.0) < 0.01 and last_bottom <= 824.0 - 6.0 + 0.01,
		"bottom=%s" % str(last_bottom))
	_check("②卡高不扩（offset_bottom==618 ∧ 卡高 968 钉死）",
		sp._card.offset_bottom == 618.0 and absf(sp._card.size.y - 968.0) < 0.01,
		"b=%s h=%s" % [str(sp._card.offset_bottom), str(sp._card.size.y)])
	var hint: Label = null
	for kid in sp._card.get_children():
		var l2 := kid as Label
		if l2 != null and l2.text.begins_with("设置即存"):
			hint = l2
	var close_btn: Button = sp._root.find_child("SettingsCloseButton", true, false) as Button
	_check("②hint y824 / 关闭钮 y872 原位不动（收尾件零位移）",
		hint != null and close_btn != null and absf(hint.position.y - 824.0) < 0.01
			and absf(close_btn.position.y - 872.0) < 0.01,
		"hint_y=%s close_y=%s" % [str(hint.position.y if hint != null else -1.0),
			str(close_btn.position.y if close_btn != null else -1.0)])
	# 两态循环（写即存）+ frame_priority() 立即翻转
	PerfGovernor.mode_override = -1
	sp._perf_mode_btn.pressed.emit()
	_check("②点击 → perf_mode=1 + 文案 ◉ 特效优先（写即存）",
		int(Meta.settings("perf_mode")) == 1 and sp._perf_mode_btn.text == "◉ 特效优先",
		"val=%s text=%s" % [str(Meta.settings("perf_mode")), sp._perf_mode_btn.text])
	_check("②frame_priority() 立即翻转（写口后首读 = false）",
		PerfGovernor.frame_priority() == false, "fp=%s" % str(PerfGovernor.frame_priority()))
	sp._perf_mode_btn.pressed.emit()
	_check("②再点循环回 0 + ✓ 帧率优先 + frame_priority()==true（两态循环闭合）",
		int(Meta.settings("perf_mode")) == 0 and sp._perf_mode_btn.text == "✓ 帧率优先"
			and PerfGovernor.frame_priority() == true,
		"val=%s text=%s fp=%s" % [str(Meta.settings("perf_mode")), sp._perf_mode_btn.text,
			str(PerfGovernor.frame_priority())])
	sp.close()


# ── ③ 帧率优先转换序 ────────────────────────────────────────────────
func _test_3_frame_mode_transitions() -> void:
	print("── ③ 帧率优先转换序（降档地板1/升档帽3/迟滞带） ──")
	var t := float(PerfGovernor._target_fps())
	_pg_setup(3, 0, t * 0.5, 0)               # mode_override=0 帧率优先；EMA=0.5t < 0.90t
	_tick(3)
	_check("③持续门槛：1.5s < 2.0s 不降档（tier 仍 3）",
		PerfGovernor.tier == 3, "tier=%d" % PerfGovernor.tier)
	_tick(1)
	_check("③满 2.0s 降档 3→2（transitions=1）",
		PerfGovernor.tier == 2 and PerfGovernor.transitions == 1,
		"tier=%d trans=%d" % [PerfGovernor.tier, PerfGovernor.transitions])
	_tick(4)
	_check("③再满 2.0s 降档 2→1（transitions=2）",
		PerfGovernor.tier == 1 and PerfGovernor.transitions == 2,
		"tier=%d trans=%d" % [PerfGovernor.tier, PerfGovernor.transitions])
	_tick(4)
	_check("③地板 1：深降 EMA 持续不再降（transitions 仍 2）",
		PerfGovernor.tier == 1 and PerfGovernor.transitions == 2,
		"tier=%d trans=%d" % [PerfGovernor.tier, PerfGovernor.transitions])
	# 升档：EMA 清空重注 target（首采直赋）→ 5.0s 恰升一档
	PerfGovernor._ema_inject = t
	PerfGovernor._test_reset()
	_tick(9)
	_check("③升档迟滞：4.5s < 5.0s 不升（tier 仍 1）",
		PerfGovernor.tier == 1, "tier=%d" % PerfGovernor.tier)
	_tick(1)
	_check("③满 5.0s 升档 1→2（transitions=3）",
		PerfGovernor.tier == 2 and PerfGovernor.transitions == 3,
		"tier=%d trans=%d" % [PerfGovernor.tier, PerfGovernor.transitions])
	_tick(10)
	_check("③再满 5.0s 升档 2→3（transitions=4）",
		PerfGovernor.tier == 3 and PerfGovernor.transitions == 4,
		"tier=%d trans=%d" % [PerfGovernor.tier, PerfGovernor.transitions])
	_tick(10)
	_check("③帽 3：高 EMA 持续不再升（transitions 仍 4）",
		PerfGovernor.tier == 3 and PerfGovernor.transitions == 4,
		"tier=%d trans=%d" % [PerfGovernor.tier, PerfGovernor.transitions])
	# 双侧迟滞带（严格比较边界值）：0.95×t 恰界不升、0.90×t 恰界不降
	PerfGovernor._ema_inject = t * PerfGovernor.FRAME_RECOVER_RATIO
	PerfGovernor._test_reset()
	PerfGovernor.tier = 2                    # 帽下可升位：带内必不动才有区分力
	PerfGovernor.transitions = 4
	_tick(12)
	_check("③带内 0.95×target 恰界：不升（严格 >，EMA==阈值不动）",
		PerfGovernor.tier == 2 and PerfGovernor.transitions == 4,
		"tier=%d trans=%d" % [PerfGovernor.tier, PerfGovernor.transitions])
	PerfGovernor._ema_inject = t * PerfGovernor.FRAME_DROP_RATIO
	PerfGovernor._test_reset()
	PerfGovernor.tier = 2                    # 地板上可降位：带内必不动才有区分力
	_tick(12)
	_check("③带内 0.90×target 恰界：不降（严格 <）",
		PerfGovernor.tier == 2 and PerfGovernor.transitions == 4,
		"tier=%d trans=%d" % [PerfGovernor.tier, PerfGovernor.transitions])
	_check("③transitions 与档变一一对应（本域 4 计数 ↔ 3→2→1→2→3）",
		PerfGovernor.transitions == 4, "trans=%d" % PerfGovernor.transitions)


# ── ④ 特效优先转换序 ────────────────────────────────────────────────
func _test_4_fx_mode_transitions() -> void:
	print("── ④ 特效优先转换序（地板2/0.85 阈值/模式切换清零） ──")
	var t := float(PerfGovernor._target_fps())
	_pg_setup(3, 0, t * 0.2, 1)               # mode_override=1 特效优先；EMA=0.2t < 0.70t
	_tick(4)
	_check("④<0.70×target 满 2.0s 降档 3→2（transitions=1）",
		PerfGovernor.tier == 2 and PerfGovernor.transitions == 1,
		"tier=%d trans=%d" % [PerfGovernor.tier, PerfGovernor.transitions])
	_tick(8)
	_check("④地板 2：深降 EMA 持续不再降（tier 仍 2 / transitions 仍 1）",
		PerfGovernor.tier == 2 and PerfGovernor.transitions == 1,
		"tier=%d trans=%d" % [PerfGovernor.tier, PerfGovernor.transitions])
	# 0.92×t 同值 A/B：帧率优先带内（0.90~0.95）12 拍不动；特效优先 0.92>0.85 满 5s 升档
	PerfGovernor.mode_override = 0
	PerfGovernor.tier = 2
	PerfGovernor.transitions = 1
	PerfGovernor._ema_inject = t * 0.92
	PerfGovernor._test_reset()
	_tick(12)
	_check("④同值对照：0.92×target 帧率优先带内 12 拍不动（不升不降）",
		PerfGovernor.tier == 2 and PerfGovernor.transitions == 1,
		"tier=%d trans=%d" % [PerfGovernor.tier, PerfGovernor.transitions])
	PerfGovernor.mode_override = 1
	PerfGovernor.tier = 2
	PerfGovernor.transitions = 1
	PerfGovernor._ema_inject = t * 0.92
	PerfGovernor._test_reset()
	_tick(9)
	_check("④0.92>0.85：特效优先 4.5s 不升（迟滞）",
		PerfGovernor.tier == 2, "tier=%d" % PerfGovernor.tier)
	_tick(1)
	_check("④满 5.0s 升档 2→3（0.85 阈值生效——帧率优先同值不动）",
		PerfGovernor.tier == 3 and PerfGovernor.transitions == 2,
		"tier=%d trans=%d" % [PerfGovernor.tier, PerfGovernor.transitions])
	# 模式切换：双侧计时清零重累计、tier 保持（防切换瞬间假触发）
	_pg_setup(3, 0, t * 0.5, 0)
	_tick(3)                                   # 帧率优先累计 1.5s（未满 2.0s）
	_check("④切换前 1.5s 未降（tier 3）",
		PerfGovernor.tier == 3, "tier=%d" % PerfGovernor.tier)
	PerfGovernor.mode_override = 1             # 切特效优先——计时清零（EMA/ tier 保持）
	_check("④切换瞬间 tier 保持（3）",
		PerfGovernor.tier == 3, "tier=%d" % PerfGovernor.tier)
	_tick(3)
	_check("④模式切换计时清零：切后再 1.5s 仍未降（未清零则第 1 拍即降）",
		PerfGovernor.tier == 3, "tier=%d" % PerfGovernor.tier)
	_tick(1)
	_check("④切换后满 2.0s 降档 3→2（清零后重累计满额）",
		PerfGovernor.tier == 2 and PerfGovernor.transitions == 1,
		"tier=%d trans=%d" % [PerfGovernor.tier, PerfGovernor.transitions])


# ── ⑤ 非战斗态挂起 ──────────────────────────────────────────────────
func _test_5_suspend() -> void:
	print("── ⑤ paused / LEVEL_UP 期转换计时挂起 ──")
	var t := float(PerfGovernor._target_fps())
	# LEVEL_UP：计时冻结不清零、不清 EMA
	_pg_setup(3, 0, t * 0.5, 0)
	_tick(3)
	_gl.state = GameConst.GameStatus.LEVEL_UP
	_tick(8)
	_check("⑤LEVEL_UP 期 8 拍不降档（选卡期挂起）",
		PerfGovernor.tier == 3 and PerfGovernor.transitions == 0,
		"tier=%d trans=%d" % [PerfGovernor.tier, PerfGovernor.transitions])
	_check("⑤LEVEL_UP 期 EMA 不清（采样照走——值保持注入位）",
		absf(PerfGovernor._ema - t * 0.5) < EPS,
		"ema=%s want=%s" % [str(PerfGovernor._ema), str(t * 0.5)])
	_gl.state = GameConst.GameStatus.PLAYING
	_tick(1)
	_check("⑤回 PLAYING 1 拍即降档（冻结的 1.5s 续账至 2.0s——非清零）",
		PerfGovernor.tier == 2 and PerfGovernor.transitions == 1,
		"tier=%d trans=%d" % [PerfGovernor.tier, PerfGovernor.transitions])
	# paused：同口径
	_pg_setup(3, 0, t * 0.5, 0)
	_tick(3)
	tree.paused = true
	_tick(8)
	_check("⑤paused 期 8 拍不降档（挂起）",
		PerfGovernor.tier == 3 and PerfGovernor.transitions == 0,
		"tier=%d trans=%d" % [PerfGovernor.tier, PerfGovernor.transitions])
	tree.paused = false
	_tick(1)
	_check("⑤解除 paused 1 拍即降档（冻结续账）",
		PerfGovernor.tier == 2 and PerfGovernor.transitions == 1,
		"tier=%d trans=%d" % [PerfGovernor.tier, PerfGovernor.transitions])


# ── ⑥ 读序 + tier_override 直驱 ─────────────────────────────────────
func _test_6_read_order_and_override() -> void:
	print("── ⑥ 读序（mode_override > settings）+ tier_override 直驱 ──")
	PerfGovernor.tier_override = -1
	Meta.set_setting("perf_mode", 1)
	PerfGovernor.mode_override = 0
	_check("⑥读序：mode_override=0 压过 settings=1 → 帧率优先",
		PerfGovernor.frame_priority() == true, "fp=%s" % str(PerfGovernor.frame_priority()))
	PerfGovernor.mode_override = 1
	_check("⑥读序：mode_override=1 → 特效优先",
		PerfGovernor.frame_priority() == false, "fp=%s" % str(PerfGovernor.frame_priority()))
	PerfGovernor.mode_override = -1
	_check("⑥读序：无注入回落 settings=1 → 特效优先",
		PerfGovernor.frame_priority() == false, "fp=%s" % str(PerfGovernor.frame_priority()))
	Meta.set_setting("perf_mode", 0)
	_check("⑥读序：settings=0 → 帧率优先（缺省通道）",
		PerfGovernor.frame_priority() == true, "fp=%s" % str(PerfGovernor.frame_priority()))
	# tier_override 直驱：tier 取注入值、不跑转换、不计数
	var t := float(PerfGovernor._target_fps())
	_pg_setup(3, 0, t * 0.5, 0)
	PerfGovernor.tier_override = 1
	_check("⑥直驱：override=1 → effective_tier=1 / fx_quality_cap=0 / 真值 tier 不动（3）",
		PerfGovernor.effective_tier() == 1 and PerfGovernor.fx_quality_cap() == 0
			and PerfGovernor.tier == 3,
		"eff=%d cap=%d tier=%d" % [PerfGovernor.effective_tier(),
			PerfGovernor.fx_quality_cap(), PerfGovernor.tier])
	_tick(8)
	_check("⑥直驱不跑转换：PLAYING 8 拍深降 EMA → tier 仍 3、transitions 仍 0",
		PerfGovernor.tier == 3 and PerfGovernor.transitions == 0,
		"tier=%d trans=%d" % [PerfGovernor.tier, PerfGovernor.transitions])
	PerfGovernor.tier_override = 3
	var cap_at_3 := PerfGovernor.fx_quality_cap()
	PerfGovernor.tier_override = 2
	var cap_at_2 := PerfGovernor.fx_quality_cap()
	_check("⑥直驱映射：override=3 → cap=2 / override=2 → cap=1（tier→帽 3→2/2→1/1→0）",
		cap_at_3 == 2 and cap_at_2 == 1,
		"cap3=%d cap2=%d" % [cap_at_3, cap_at_2])
	PerfGovernor.tier_override = -1
	_check("⑥直驱释放：headless 非 mobile 无注入 → cap 恒 2（零扰动承重墙）",
		PerfGovernor.fx_quality_cap() == 2, "cap=%d" % PerfGovernor.fx_quality_cap())


# ── ⑦ Enemy._fx_q 映射写点 ──────────────────────────────────────────
func _test_7_enemy_fx_mapping() -> void:
	print("── ⑦ Enemy._fx_q 映射写点（默认零扰动 + 档变联动） ──")
	var e := (_gl.pools[&"enemy"] as EnemyPool).acquire() as Enemy
	e.spawn(_fixture_enemy(&"E_R220_FX", 100.0), 1, 0)
	PerfGovernor.tier_override = -1           # headless 非 mobile 无注入 → 帽恒 2
	for q in 3:
		Meta.set_setting("fx_quality", q)
		_check("⑦零扰动：fx_quality=%d → _fx_q()==%d（默认档帽 2 合成后不变）" % [q, q],
			Enemy._fx_q() == q, "q=%d got=%d" % [q, Enemy._fx_q()])
	Meta.set_setting("fx_quality", 2)
	PerfGovernor.tier_override = 3
	_check("⑦override=3（帽 2）+ fx=2 → _fx_q()==2（帽不咬合）",
		Enemy._fx_q() == 2, "got=%d" % Enemy._fx_q())
	PerfGovernor.tier_override = 2
	_check("⑦override=2（帽 1）+ fx=2 → _fx_q()==1（合成取小）",
		Enemy._fx_q() == 1, "got=%d" % Enemy._fx_q())
	PerfGovernor.tier_override = 1
	_check("⑦override=1（帽 0）+ fx=2 → _fx_q()==0（合成取小）",
		Enemy._fx_q() == 0, "got=%d" % Enemy._fx_q())
	Meta.set_setting("fx_quality", 0)
	_check("⑦override=1 + fx=0 → _fx_q()==0（两侧同小）",
		Enemy._fx_q() == 0, "got=%d" % Enemy._fx_q())
	# 档变联动：fx=2 固定，override 3→2→1 → 写点输出 2→1→0（档变即被调用）
	Meta.set_setting("fx_quality", 2)
	var seq_ok := true
	var got: Array[int] = []
	for ov in [3, 2, 1]:
		PerfGovernor.tier_override = ov
		got.append(Enemy._fx_q())
	if got.size() != 3 or got[0] != 2 or got[1] != 1 or got[2] != 0:
		seq_ok = false
	_check("⑦档变联动：override 3→2→1 → _fx_q() 输出 2→1→0（写点随档变被调用）",
		seq_ok, "got=%s" % str(got))
	var src := FileAccess.get_file_as_string("res://scripts/entities/enemy/enemy.gd")
	_check("⑦源级锚：_fx_q 双分支接 PerfGovernor.fx_quality_cap()（mobile 门合成取小）",
		src.contains("return mini(mini(_fx_quality_cache, 1), PerfGovernor.fx_quality_cap())")
			and src.contains("return mini(_fx_quality_cache, PerfGovernor.fx_quality_cap())")
			and src.count("PerfGovernor.fx_quality_cap()") >= 2,
		"count=%d" % src.count("PerfGovernor.fx_quality_cap()"))
	PerfGovernor.tier_override = -1
	Meta.set_setting("fx_quality", 2)
	(_gl.pools[&"enemy"] as EnemyPool).release(e)


# ── ⑧ 注册序 / 常量冻结 / 计数器审计块 ───────────────────────────────
func _test_8_registration_order() -> void:
	print("── ⑧ 注册序（Meta < PerfGovernor）/ 常量冻结 / 计数器块 ──")
	var pg: Node = tree.root.get_node_or_null("/root/PerfGovernor")
	var meta_n: Node = tree.root.get_node_or_null("/root/Meta")
	_check("⑧PerfGovernor 在树且晚于 Meta（读口就绪序——序错首帧读空）",
		pg != null and meta_n != null and meta_n.get_index() < pg.get_index(),
		"meta_idx=%s pg_idx=%s" % [str(meta_n.get_index() if meta_n != null else -1),
			str(pg.get_index() if pg != null else -1)])
	_check("⑧PROCESS_MODE_ALWAYS（暂停/选卡期采样不停）",
		pg != null and pg.process_mode == Node.PROCESS_MODE_ALWAYS,
		"mode=%s" % str(pg.process_mode if pg != null else -1))
	_check("⑧冻结常量九项逐位（契约 §2.1 照抄）",
		PerfGovernor.FRAME_DROP_RATIO == 0.90 and PerfGovernor.FRAME_RECOVER_RATIO == 0.95
			and PerfGovernor.FX_DROP_RATIO == 0.70 and PerfGovernor.FX_RECOVER_RATIO == 0.85
			and PerfGovernor.DROP_SUSTAIN_S == 2.0 and PerfGovernor.RECOVER_SUSTAIN_S == 5.0
			and PerfGovernor.FX_FLOOR_TIER == 2 and PerfGovernor.EMA_ALPHA == 0.25
			and PerfGovernor.SAMPLE_S == 0.5, "")
	var proj := FileAccess.get_file_as_string("res://project.godot")
	var i_meta := proj.find("Meta=\"*res://scripts/meta/meta_manager.gd\"")
	var i_pg := proj.find("PerfGovernor=\"*res://autoload/perf_governor.gd\"")
	_check("⑧project.godot 注册行序：Meta 行 < PerfGovernor 行",
		i_meta >= 0 and i_pg >= 0 and i_meta < i_pg,
		"meta=%d pg=%d" % [i_meta, i_pg])
	_check("⑧DebugStats R220_COUNTER_KEYS 三键冻结（决策#3 审计块）",
		DebugStats.R220_COUNTER_KEYS.size() == 3
			and DebugStats.R220_COUNTER_KEYS[0] == &"fit_desc_measures"
			and DebugStats.R220_COUNTER_KEYS[1] == &"quota_deferred"
			and DebugStats.R220_COUNTER_KEYS[2] == &"quota_dropped",
		"keys=%s" % str(DebugStats.R220_COUNTER_KEYS))
	DebugStats.count(&"fit_desc_measures")
	DebugStats.count(&"quota_deferred")
	DebugStats.count(&"quota_dropped", 2)
	_check("⑧计数通道可写可读（count 通用字典——后续包写点直用）",
		DebugStats.get_counter(&"fit_desc_measures") >= 1
			and DebugStats.get_counter(&"quota_deferred") >= 1
			and DebugStats.get_counter(&"quota_dropped") >= 2,
		"fit=%d def=%d drop=%d" % [DebugStats.get_counter(&"fit_desc_measures"),
			DebugStats.get_counter(&"quota_deferred"), DebugStats.get_counter(&"quota_dropped")])


func _cleanup() -> void:
	# 全局态复位（注入面/设置/暂停位/引擎侧 process——防串后续套件）
	PerfGovernor.mode_override = -1
	PerfGovernor.tier_override = -1
	PerfGovernor._ema_inject = -1.0
	PerfGovernor.tier = 3
	PerfGovernor.transitions = 0
	PerfGovernor._test_reset()
	PerfGovernor.set_process(true)
	tree.paused = false
	Meta.set_setting("perf_mode", 0)
	Meta.set_setting("fx_quality", 2)
	_teardown_game_loop()

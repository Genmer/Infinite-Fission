# tests/qa_r288_buildagg_cases.gd（R288 用例体——入口运行时加载）
# 覆盖（刀A 构筑快照 / 刀B boost 门逐跳字关+秒窗聚合）：
#   b1 开局快照：start_run 后 DebugStats._diag_build_lines 非空——首行 [构筑] 含
#      难度/波次1/促0/武器面 + 槽0 武器行在位（用户点名归因口的最小完备面）。
#   b2 选卡回 P 刷新：P→LEVEL_UP→P 迁移对后快照反映构筑变化（Lv7）；PAUSED 回环
#      （P→PAUSED→P）不刷新（快照仍 Lv7 不含 Lv9——选卡回窗是唯一刷新点）。
#   b3 武器行形状：槽0 行含 名称(id) / Lv / 词条N: 三要素（trait 计数单源 trait_stack）。
#   b4 刀B 门杀起字：boost 开 on_damage_resolved×3 → active_popups 不涨、秒窗值=和、
#      跳数=3、Label 未建（懒建——首窗落值才建）。
#   b5 秒窗落值：回拨窗起点 1100ms + tick → Label 建立且文本格式合法可见；零伤窗
#      ×3 后隐藏（AGG_IDLE_HIDE_WINDOWS）；窗值/跳数复位。
#   b6 关态正对照：boost 关 on_damage_resolved → 照常起字（active_popups==1）；
#      再 tick → Label 隐藏且聚合态复位（逐跳字路径接管——pkg4 位保同口径）。
#   b7 S5 台架臂复刻：boost 开 ∧ shortcircuit_spawn → spawn_reject_count+1 且秒窗值
#      不动；boost 关 ∧ shortcircuit → 原短路位计数+1（两臂同源）。
#   b8 _agg_format：12345→"1.2万/秒" / 999994→"100万/秒" / 999.4→"999/秒" /
#      0→"0/秒"，文本无 "%" 字符（% 格式坑防线）。
#   b9 导出段：diag_push_build 后 diag_export 文本含构筑快照段头+内容行+口径头 R288
#      句；_diag_lines/_diag_ev_lines 双环行数零触碰（既有口径承重墙）。
# 夹具纪律（r287 同款）：Meta 设置入口快照整字典还原 + _save 落盘；boost_override/
# shortcircuit_spawn 用毕复位；pm.clear_all() 清活字；盘档自清（RunSave.clear）。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const DT := 1.0 / 60.0

var tree: SceneTree
var _gl: Node = null
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _saved_settings: Dictionary = {}


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_saved_settings = Meta._settings.duplicate()      # 入口快照（收尾还原——磁盘不留测试痕）
	_boot()
	PerfGovernor.set_process(false)
	PerfGovernor.mode_override = -1
	PerfGovernor.tier_override = 3
	PerfGovernor.boost_override = -1
	Meta.set_setting("fx_quality", 2)           # r230 先例：钉高防跨套件 user:// 残留漂门
	Meta.set_setting("damage_numbers_on", true)
	Meta.set_setting("perf_boost", 0)           # b1 促0 锚确定性（user:// 残留免疫——收尾还原）
	_b1_run_start_snapshot()
	_b2_levelup_refresh()
	_b3_weapon_line_shape()
	_b4_boost_gate_kills_spawns()
	_b5_agg_tick_label()
	_b6_boost_off_positive_control()
	_b7_s5_shortcircuit_replica()
	_b8_agg_format()
	_b13_daily_blessing_line()
	_b10_continue_run_refresh()
	_b12_paused_modal_hide()
	_b11_gameover_agg_reset()
	_b14_overflow_source_anchor()
	await _cleanup_and_export()


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
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate()
	_gl.name = "R288BuildAgg"
	tree.root.add_child(_gl)
	if not (_gl.get("boot_ready") and _gl.state == GameConst.GameStatus.MENU):
		push_error("[r288] Boot 失败：%s" % str(_gl.get("boot_fatal")))
		_fail += 1


func _slot0_line() -> String:
	for l in DebugStats._diag_build_lines:
		if String(l).begins_with("[武器] 槽0 "):
			return String(l)
	return ""


func _mk_result(p_uid: int, p_value: float) -> DamageResult:
	var r := DamageResult.new()
	r.final_value = p_value
	r.target_uid = p_uid
	r.pos = Vector2(360.0, 400.0)               # 视口内（boost 裁剪门内）
	r.popup_style = GameConst.PopupStyle.NORMAL
	return r


# ── b1 开局快照 ────────────────────────────────────────────────────

func _b1_run_start_snapshot() -> void:
	print("── b1 开局构筑快照（start_run 尾捕获） ──")
	var ok: bool = _gl.start_run()
	_check("b1 start_run 成功且进 PLAYING",
		ok and _gl.state == GameConst.GameStatus.PLAYING,
		"ok=%s state=%d" % [str(ok), int(_gl.state)])
	var lines: Array[String] = DebugStats._diag_build_lines
	_check("b1 快照非空且首行 [构筑] 头", lines.size() >= 1 and lines[0].begins_with("[构筑]"),
		"n=%d head=%s" % [lines.size(), lines[0] if lines.size() > 0 else ""])
	_check("b1 首行含 难度/波次1/促0/武器面（归因最小完备）",
		lines.size() > 0 and lines[0].contains("难度") and lines[0].contains("波次1")
			and lines[0].contains("促0") and lines[0].contains("武器")
			and lines[0].contains("祝福") and lines[0].contains("遗物"),
		"line=%s" % (lines[0] if lines.size() > 0 else ""))
	_check("b1 槽0 武器行在位（默认武装入快照）", not _slot0_line().is_empty(),
		"slot0=%s" % _slot0_line())
	var rx_wc := RegEx.new()
	rx_wc.compile("武器(\\d+)件")
	var m_wc := rx_wc.search(lines[0] if lines.size() > 0 else "")
	var head_wcount := int(m_wc.get_string(1)) if m_wc != null else -1
	var live_wcount := 0
	for wv in _gl.player.weapon_slots:
		if wv != null and (wv as WeaponBase).data != null:
			live_wcount += 1
	_check("b1 头行武器件数=实件数（QA R288R-1 修——槽容量 null 位不计）",
		head_wcount == live_wcount, "head=%d live=%d" % [head_wcount, live_wcount])


# ── b2 选卡回 P 刷新 / PAUSED 回环不刷 ────────────────────────────

func _b2_levelup_refresh() -> void:
	print("── b2 LEVEL_UP→P 刷新 ∧ PAUSED 回环不刷 ──")
	var w0: WeaponBase = _gl.player.weapon_slots[0]
	w0.level = 7
	_check("b2 P→LEVEL_UP 迁移合法", _gl.change_state(GameConst.GameStatus.LEVEL_UP), "")
	_check("b2 LEVEL_UP→P 迁移合法", _gl.change_state(GameConst.GameStatus.PLAYING), "")
	_check("b2 回 P 后快照含 Lv7（选卡回窗刷新）",
		_slot0_line().contains("Lv7"), "line=%s" % _slot0_line())
	w0.level = 9
	_check("b2 P→PAUSED 迁移合法", _gl.change_state(GameConst.GameStatus.PAUSED), "")
	_check("b2 PAUSED→P 迁移合法", _gl.change_state(GameConst.GameStatus.PLAYING), "")
	_check("b2 PAUSED 回环不刷新（快照仍 Lv7 不含 Lv9）",
		_slot0_line().contains("Lv7") and not _slot0_line().contains("Lv9"),
		"line=%s" % _slot0_line())


# ── b3 武器行形状 ──────────────────────────────────────────────────

func _b3_weapon_line_shape() -> void:
	print("── b3 武器行三要素 ──")
	var l := _slot0_line()
	_check("b3 槽0 行含 名称(id) 形状", l.contains("(") and l.contains(")"), "line=%s" % l)
	_check("b3 槽0 行含 Lv 与 词条 计数面", l.contains("Lv7") and l.contains("词条"),
		"line=%s" % l)


# ── b4 刀B 门杀起字 ────────────────────────────────────────────────

func _b4_boost_gate_kills_spawns() -> void:
	print("── b4 boost 门内逐跳字关（秒窗聚合直返） ──")
	var pm: PopupManager = _gl.popup_manager
	pm.clear_all()
	PerfGovernor.boost_override = 1
	var live0: int = pm.active_popups
	for i in 3:
		pm.on_damage_resolved(_mk_result(41000 + i, 10.0 + float(i)))
	_check("b4 boost 开 ×3 结算：active_popups 不涨（起字全跳）",
		pm.active_popups == live0,
		"live=%d→%d" % [live0, pm.active_popups])
	_check("b4 秒窗值=33.0（10+11+12 聚合无丢）",
		is_equal_approx(pm._agg_window_value, 33.0), "v=%f" % pm._agg_window_value)
	_check("b4 秒窗跳数=3", pm._agg_window_hits == 3, "hits=%d" % pm._agg_window_hits)
	_check("b4 窗起点已开（首伤开窗）", pm._agg_window_start_ms >= 0, "")
	_check("b4 Label 未建（懒建——首窗落值才建）", pm._agg_label == null, "")


# ── b5 秒窗落值 / 零伤静默隐藏 ─────────────────────────────────────

func _b5_agg_tick_label() -> void:
	print("── b5 秒窗 1Hz 落值 + 静默隐藏 ──")
	var pm: PopupManager = _gl.popup_manager
	pm._agg_window_start_ms = Time.get_ticks_msec() - 1100   # 回拨窗起点（免真等 1s）
	pm.tick(DT)
	_check("b5 落值后 Label 建立", pm._agg_label != null, "")
	if pm._agg_label == null:
		return                                 # 后续断言全依赖 Label——早退保汇总
	_check("b5 Label 文本格式合法（/秒 尾）", pm._agg_label.text.ends_with("/秒"),
		"text=%s" % pm._agg_label.text)
	_check("b5 落值窗文本≈30/秒（33 伤害/1.1s 归一容差 20%）",
		absf(float(pm._agg_label.text.trim_suffix("/秒").to_float()) - 30.0) < 6.0,
		"text=%s" % pm._agg_label.text)
	_check("b5 落值后窗复位（值/跳数清零、窗起点续 now）",
		pm._agg_window_value == 0.0 and pm._agg_window_hits == 0
			and pm._agg_window_start_ms >= 0, "")
	_check("b5 有伤窗 Label 可见", pm._agg_label.visible, "")
	# 零伤窗 ×3 → 第 3 窗关闭时隐藏（AGG_IDLE_HIDE_WINDOWS=3）
	var visible_after: Array[bool] = []
	for i in 3:
		pm._agg_window_start_ms = Time.get_ticks_msec() - 1100
		pm.tick(DT)
		visible_after.append(pm._agg_label.visible)
	_check("b5 零伤 3 窗后隐藏（前 2 窗仍显、第 3 窗隐）",
		visible_after[0] and visible_after[1] and not visible_after[2],
		"vis=%s" % str(visible_after))


# ── b6 关态正对照 ──────────────────────────────────────────────────

func _b6_boost_off_positive_control() -> void:
	print("── b6 boost 关：起字照常 + Label 隐藏复位 ──")
	var pm: PopupManager = _gl.popup_manager
	PerfGovernor.boost_override = 0
	pm.on_damage_resolved(_mk_result(42000, 25.0))
	_check("b6 boost 关 on_damage_resolved → 照常起字（active_popups==1）",
		pm.active_popups == 1, "live=%d" % pm.active_popups)
	pm.tick(DT)
	_check("b6 boost 关 tick → Label 隐藏（逐跳字路径接管）",
		pm._agg_label != null and not pm._agg_label.visible, "")
	_check("b6 boost 关 tick → 聚合态复位（窗未开）",
		pm._agg_window_start_ms == -1 and pm._agg_window_value == 0.0, "")
	pm.clear_all()
	PerfGovernor.boost_override = -1


# ── b7 S5 台架臂复刻 ───────────────────────────────────────────────

func _b7_s5_shortcircuit_replica() -> void:
	print("── b7 S5 短路臂计数复刻（deeprepro r2 锚） ──")
	var pm: PopupManager = _gl.popup_manager
	PerfGovernor.boost_override = 1
	PopupManager.shortcircuit_spawn = true
	var rej0: int = PopupManager.spawn_reject_count
	var agg0: float = pm._agg_window_value
	pm.on_damage_resolved(_mk_result(43000, 50.0))
	_check("b7 boost 开 ∧ 短路臂 → spawn_reject_count+1（计数复刻不丢）",
		PopupManager.spawn_reject_count == rej0 + 1,
		"rej=%d→%d" % [rej0, PopupManager.spawn_reject_count])
	_check("b7 短路臂不进聚合（秒窗值不动）",
		is_equal_approx(pm._agg_window_value, agg0), "v=%f" % pm._agg_window_value)
	PopupManager.shortcircuit_spawn = false
	PerfGovernor.boost_override = 0
	PopupManager.shortcircuit_spawn = true
	var rej1: int = PopupManager.spawn_reject_count
	pm.on_damage_resolved(_mk_result(43001, 50.0))
	_check("b7 boost 关 ∧ 短路臂 → 原短路位计数+1（两臂同源）",
		PopupManager.spawn_reject_count == rej1 + 1
			and pm.active_popups == 0,
		"rej=%d live=%d" % [PopupManager.spawn_reject_count, pm.active_popups])
	PopupManager.shortcircuit_spawn = false
	PerfGovernor.boost_override = -1


# ── b8 _agg_format ────────────────────────────────────────────────

func _b8_agg_format() -> void:
	print("── b8 聚合格式（无 % 字符） ──")
	_check("b8 12345 → 1.2万/秒", PopupManager._agg_format(12345.0) == "1.2万/秒",
		"got=%s" % PopupManager._agg_format(12345.0))
	_check("b8 999994 → 100万/秒（snappedf 进位）",
		PopupManager._agg_format(999994.0) == "100万/秒",
		"got=%s" % PopupManager._agg_format(999994.0))
	_check("b8 999.4 → 999/秒（万下取整）",
		PopupManager._agg_format(999.4) == "999/秒",
		"got=%s" % PopupManager._agg_format(999.4))
	_check("b8 0 → 0/秒（零伤窗不空文本）",
		PopupManager._agg_format(0.0) == "0/秒",
		"got=%s" % PopupManager._agg_format(0.0))
	var all := PopupManager._agg_format(12345.0) + PopupManager._agg_format(999.4)
	_check("b8 输出无 %% 字符（% 格式坑防线）", not all.contains("%"), "all=%s" % all)


# ── b13 daily 局祝福行自洽（QA288-3 修） ──────────────────────────

func _b13_daily_blessing_line() -> void:
	print("── b13 daily 局祝福行=每日词缀口径 ──")
	_check("b13 P→PAUSED 退出前置", _gl.change_state(GameConst.GameStatus.PAUSED), "")
	_check("b13 quit_to_menu", _gl.quit_to_menu(), "")
	_check("b13 start_run(daily)", _gl.start_run(20261017), "")
	var head := DebugStats._diag_build_lines[0] if DebugStats._diag_build_lines.size() > 0 else ""
	_check("b13 daily 局祝福行=每日词缀（大厅记忆不参与——防归因到未挂载面）",
		head.contains("每日词缀") and head.contains("大厅记忆不参与"), "head=%s" % head)
	# 评审 R1：冷启动续 daily 存档（_active_daily_seed 不恢复）仍须走每日分支——
	# 选择器 Meta.is_run_daily()（continue_run 从存档恢复置位）
	_check("b13 daily 局 P→PAUSED", _gl.change_state(GameConst.GameStatus.PAUSED), "")
	_check("b13 daily 局 quit_to_menu（落档）", _gl.quit_to_menu(), "")
	_check("b13 daily 局 continue_run", _gl.continue_run(), "")
	var head2 := DebugStats._diag_build_lines[0] if DebugStats._diag_build_lines.size() > 0 else ""
	_check("b13 续档 daily 局仍走每日词缀分支（R1 修——修复前误入大厅记忆分支）",
		head2.contains("每日词缀") and head2.contains("大厅记忆不参与"), "head=%s" % head2)


# ── b10 continue_run 快照刷新（QA288-1/2 修）+ b15 事件环构筑史 ──

func _b10_continue_run_refresh() -> void:
	print("── b10 continue_run 快照刷新 + 遗物真源 + 事件环构筑史 ──")
	_check("b10 回菜单", _gl.change_state(GameConst.GameStatus.PAUSED)
		and _gl.quit_to_menu(), "")
	_check("b10 start_run()（清 daily）", _gl.start_run(), "")
	var w0: WeaponBase = _gl.player.weapon_slots[0]
	w0.level = 5
	_check("b10 P→PAUSED", _gl.change_state(GameConst.GameStatus.PAUSED), "")
	_check("b10 quit_to_menu（落档）", _gl.quit_to_menu(), "")
	_check("b10 continue_run（MENU→P 直迁）", _gl.continue_run(), "")
	_check("b10 继续后快照反映 Lv5（QA288-1 修——旧局构筑不再残留）",
		_slot0_line().contains("Lv5"), "line=%s" % _slot0_line())
	var head := DebugStats._diag_build_lines[0] if DebugStats._diag_build_lines.size() > 0 else ""
	var rx := RegEx.new()
	rx.compile("遗物(\\d+)件")
	var m := rx.search(head)
	var snap_relics := int(m.get_string(1)) if m != null else -1
	_check("b10 快照遗物计数=relic_handler 真源（QA288-2 修——continue 路径不再恒 0）",
		snap_relics == _gl.relic_handler.owned_count(),
		"snap=%d live=%d" % [snap_relics, _gl.relic_handler.owned_count()])
	var ev_has := false
	for l in DebugStats._diag_ev_lines:
		if String(l).contains("[构筑] 波"):
			ev_has = true
	_check("b15 事件环构筑史行在位（P3 修——[ev] 墙钟时间轴构筑演变）", ev_has, "")


# ── b12 冻结模态期 Label 让位（QA288-4 修） ──────────────────────

func _b12_paused_modal_hide() -> void:
	print("── b12 paused tick → Label 隐藏让位模态 ──")
	var pm: PopupManager = _gl.popup_manager
	PerfGovernor.boost_override = 1
	pm.on_damage_resolved(_mk_result(45000, 40.0))
	pm._agg_window_start_ms = Time.get_ticks_msec() - 1100
	pm.tick(DT)                               # PLAYING 态（未 paused）→ 落值可见
	_check("b12 前置：PLAYING 落值 Label 可见",
		pm._agg_label != null and pm._agg_label.visible, "")
	_check("b12 P→PAUSED（tree.paused 置位）", _gl.change_state(GameConst.GameStatus.PAUSED), "")
	pm.tick(DT)
	_check("b12 paused tick → Label 隐藏（同层模态让位唯一确定序）",
		pm._agg_label != null and not pm._agg_label.visible, "")
	_check("b12 paused tick → 窗起点弃置（暂停时长不进秒窗归一）",
		pm._agg_window_start_ms == -1, "")
	_gl.change_state(GameConst.GameStatus.PLAYING)
	PerfGovernor.boost_override = -1


# ── b11 出战斗态聚合复位（P4 修） ────────────────────────────────

func _b11_gameover_agg_reset() -> void:
	print("── b11 GAME_OVER → reset_agg ──")
	var pm: PopupManager = _gl.popup_manager
	PerfGovernor.boost_override = 1
	pm.on_damage_resolved(_mk_result(46000, 40.0))
	pm._agg_window_start_ms = Time.get_ticks_msec() - 1100
	pm.tick(DT)
	_check("b11 前置：Label 建立可见", pm._agg_label != null and pm._agg_label.visible, "")
	pm.on_damage_resolved(_mk_result(46001, 30.0))   # 新窗在途值
	_check("b11 前置：新窗值 30（在途）", is_equal_approx(pm._agg_window_value, 30.0),
		"v=%f" % pm._agg_window_value)
	_check("b11 P→GAME_OVER 迁移", _gl.change_state(GameConst.GameStatus.GAME_OVER), "")
	_check("b11 GAME_OVER → reset_agg（Label 隐 + 窗四字段复位——防结算屏冻结大字）",
		not pm._agg_label.visible and pm._agg_window_start_ms == -1
			and pm._agg_window_value == 0.0 and pm._agg_window_hits == 0,
		"vis=%s start=%d v=%f hits=%d" % [str(pm._agg_label.visible),
			pm._agg_window_start_ms, pm._agg_window_value, pm._agg_window_hits])
	PerfGovernor.boost_override = -1


# ── b14 溢出批消化末快照刷新（QA288-5 源锚） ─────────────────────

func _b14_overflow_source_anchor() -> void:
	print("── b14 溢出批结清点快照刷新（源锚——连升自动选卡无卡窗迁移路径） ──")
	var src := FileAccess.get_file_as_string("res://scripts/loop/game_loop.gd")
	var i := src.find("func _tick_merged_overflow")
	var seg := src.substr(i, 2600)
	_check("b14 _tick_merged_overflow 结清点含 _capture_build_snapshot（QA288-5 修）",
		i >= 0 and seg.contains("_capture_build_snapshot"), "found=%d" % i)


# ── b9 导出段 + 收尾 ──────────────────────────────────────────────

func _cleanup_and_export() -> void:
	print("── b9 导出前置段（事件环之前）+ 双环口径零触碰 + 收尾 ──")
	var ring0: int = DebugStats._diag_lines.size()
	var ev0: int = DebugStats._diag_ev_lines.size()
	DebugStats.diag_push_build(["[构筑] TESTLINE_R288"])
	var txt := String(DebugStats.diag_export().get("text", ""))
	_check("b9 导出含构筑快照段头", txt.contains("构筑快照（R288"), "len=%d" % txt.length())
	_check("b9 导出含快照内容行", txt.contains("TESTLINE_R288"), "")
	_check("b9 导出含口径头 R288 句（刀B 预期态披露）",
		txt.contains("R288（构筑快照+刀B）") and txt.contains("跳段µs 坍缩"), "")
	_check("b9 双环行数零触碰（既有口径承重墙）",
		DebugStats._diag_lines.size() == ring0 and DebugStats._diag_ev_lines.size() == ev0,
		"ring %d→%d ev %d→%d" % [ring0, DebugStats._diag_lines.size(),
			ev0, DebugStats._diag_ev_lines.size()])
	# 收尾：测试痕自清
	var pm: PopupManager = _gl.popup_manager
	pm.clear_all()
	PerfGovernor.boost_override = -1
	PerfGovernor.mode_override = -1
	PerfGovernor.tier_override = -1
	PopupManager.shortcircuit_spawn = false
	RunSave.clear()
	Meta._settings = _saved_settings.duplicate()     # 入口快照还原（含 fx_quality/damage_numbers_on）
	Meta._save()
	_gl.queue_free()
	await tree.process_frame
	print("验收汇总：%d/%d 通过" % [_pass, _pass + _fail])
	if _fail > 0:
		for f in _failures:
			print("  FAIL 项：%s" % f)

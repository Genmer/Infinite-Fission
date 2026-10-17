# tests/qa288v2_continue_probe_cases.gd（修轮复核用例体——运行时加载）
# 断言=修复后语义（对 qa288_continue_probe 的缺陷断言取反）：
#   V1 continue_run 后快照新鲜（Lv5）+ 遗物真源（1件/[遗物] 行/owned_count 一致）
#   V2 continue 后强制 LEVEL_UP→P：遗物仍按真源 1 件（旧双源分歧恒 0 消失）
#   V3 daily 局祝福行=每日词缀 + 大厅记忆不出现（AFF_ATK_UP 反证）
#   V4 冷启动续 daily 存档（_active_daily_seed=-1 + Meta daily 假复位）仍走每日分支（R1）
#   V5 事件环构筑史行（P3：每次捕获一行 [构筑] 波…）
#   V6 paused 模态隐藏（QA288-4 动态：可见→PAUSED tick→隐+窗弃置）
#   V7 GAME_OVER reset_agg（QA288-4 动态：可见+在途值→GAME_OVER→隐+四字段复位）
# 纪律：Meta 祝福记忆变量直改不落盘（收尾还原）；RunSave 用毕 clear；不触被测代码。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const RELIC_ID := &"REL_ATTACK_CDR"
const DT := 1.0 / 60.0

var tree: SceneTree
var _gl: Node = null
var _pass: int = 0
var _fail: int = 0
var _saved_blessing := ""


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	_boot()
	PerfGovernor.set_process(false)
	PerfGovernor.mode_override = -1
	PerfGovernor.tier_override = 3
	PerfGovernor.boost_override = -1
	Meta.set_setting("damage_numbers_on", true)
	RunSave.clear()
	_v1_continue_refresh()
	_v2_refresh_true_source()
	_v3_daily_line()
	_v4_daily_cold_continue()
	_v5_event_hist()
	_v6_paused_hide()
	_v7_gameover_reset()
	_cleanup()


func fail_count() -> int:
	return _fail


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("  PASS | %s" % p_name)
	else:
		_fail += 1
		print("  FAIL | %s（%s）" % [p_name, p_detail])


func _info(p_name: String, p_detail: String) -> void:
	print("  INFO | %s（%s）" % [p_name, p_detail])


func _boot() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate()
	_gl.name = "QA288v2ContinueProbe"
	tree.root.add_child(_gl)
	if not (_gl.get("boot_ready") and _gl.state == GameConst.GameStatus.MENU):
		push_error("[qa288v2] Boot 失败")
		_fail += 1


func _snap() -> String:
	return "\n".join(DebugStats._diag_build_lines)


func _slot0_line() -> String:
	for l in DebugStats._diag_build_lines:
		if String(l).begins_with("[武器] 槽0 "):
			return String(l)
	return ""


func _mk_result(p_uid: int, p_value: float) -> DamageResult:
	var r := DamageResult.new()
	r.final_value = p_value
	r.target_uid = p_uid
	r.pos = Vector2(360.0, 400.0)
	r.popup_style = GameConst.PopupStyle.NORMAL
	return r


func _v1_continue_refresh() -> void:
	print("── V1 continue_run 快照刷新 + 遗物真源 ──")
	_check("V1 start_run 成功", bool(_gl.start_run()), "")
	var w0: WeaponBase = _gl.player.weapon_slots[0]
	_check("V1 基线快照 Lv1", _slot0_line().contains("Lv1"), _slot0_line())
	for i in 4:
		w0.level_up()
	_check("V1 遗物激活", bool(_gl.relic_handler.activate(RELIC_ID)), "")
	RunSave.save_run(_gl.serialize_run())
	var lines_before := _snap()
	_check("V1 P→PAUSED", bool(_gl.change_state(GameConst.GameStatus.PAUSED)), "")
	_check("V1 quit_to_menu（落档）", bool(_gl.quit_to_menu()), "")
	_check("V1 continue_run", bool(_gl.continue_run()), "")
	_check("V1 实武器 Lv5", _gl.player.weapon_slots[0] != null
		and _gl.player.weapon_slots[0].level == 5, "")
	var snap := _snap()
	_check("V1 ★快照新鲜：槽0 含 Lv5（修前=仍 Lv1）", _slot0_line().contains("Lv5"), _slot0_line())
	_check("V1 快照与继续前不同（确已重捕获）", snap != lines_before, "")
	_check("V1 ★遗物真源：头行 遗物1件（修前=旧局/0件）", snap.contains("遗物1件"), snap)
	_check("V1 [遗物] 行含 REL_ATTACK_CDR", snap.contains("REL_ATTACK_CDR"), snap)
	_check("V1 计数==owned_count（真源一致）", _gl.relic_handler.owned_count() == 1
		and snap.contains("遗物%d件" % _gl.relic_handler.owned_count()), "")
	# INFO 残留：容量口径 vs 实际件数
	var row_n := 0
	for l in DebugStats._diag_build_lines:
		if String(l).begins_with("[武器] "):
			row_n += 1
	var hdr := String(DebugStats._diag_build_lines[0]) if DebugStats._diag_build_lines.size() > 0 else ""
	_info("武器件数口径", "行首=%s | 实际武器行=%d（weapon_slots 容量=7）" % [hdr, row_n])


func _v2_refresh_true_source() -> void:
	print("── V2 强制选卡回窗后遗物真源保持 ──")
	_check("V2 P→LEVEL_UP", bool(_gl.change_state(GameConst.GameStatus.LEVEL_UP)), "")
	_check("V2 LEVEL_UP→P", bool(_gl.change_state(GameConst.GameStatus.PLAYING)), "")
	var snap := _snap()
	_check("V2 ★刷新后遗物仍 1 件（修前=0件假读）", snap.contains("遗物1件"), snap)
	_check("V2 [遗物] 行仍在（真源非 owned_relics）", snap.contains("REL_ATTACK_CDR")
		and _gl.card_generator.owned_relics.is_empty(), "owned_relics=%d" % _gl.card_generator.owned_relics.size())


func _v3_daily_line() -> void:
	print("── V3 daily 局祝福行 ──")
	_saved_blessing = String(Meta.blessing_trait_id)
	Meta.blessing_trait_id = "AFF_ATK_UP"          # 直改（不落盘）
	_check("V3 回菜单", bool(_gl.change_state(GameConst.GameStatus.PAUSED))
		and bool(_gl.quit_to_menu()), "")
	_check("V3 start_run(daily)", bool(_gl.start_run(20261017)), "")
	var snap := _snap()
	var daily_bless := String(Meta.daily_affixes(Meta.daily_date_key()).get("bless", ""))
	_check("V3 ★祝福行=每日词缀:%s（实际生效面）" % daily_bless,
		daily_bless != "" and snap.contains("祝福每日词缀:%s" % daily_bless), snap)
	_check("V3 ★大厅记忆 AFF_ATK_UP 不出现在快照（修前=误导向未挂载面）",
		not snap.contains("AFF_ATK_UP") and not snap.contains("大厅记忆参与"), snap)
	_check("V3 行文含「大厅记忆不参与」披露", snap.contains("大厅记忆不参与"), snap)


func _v4_daily_cold_continue() -> void:
	print("── V4 冷启动续 daily 存档（R1 修复点） ──")
	_check("V4 daily 局激活遗物（续档真源面）", bool(_gl.relic_handler.activate(RELIC_ID)), "")
	_check("V4 daily P→PAUSED", bool(_gl.change_state(GameConst.GameStatus.PAUSED)), "")
	_check("V4 daily quit_to_menu（落档）", bool(_gl.quit_to_menu()), "")
	_gl.set("_active_daily_seed", -1)              # 冷启动等价：变量未赋值
	Meta.set_run_daily(false)                      # 冷启动等价：Meta 未置位
	_check("V4 continue_run", bool(_gl.continue_run()), "")
	_check("V4 续档后 run_daily=true（存档恢复）", bool(Meta.is_run_daily()), "")
	var snap := _snap()
	_check("V4 ★冷启动续 daily 仍走每日词缀分支（修前=误入大厅记忆分支）",
		snap.contains("祝福每日词缀:") and snap.contains("大厅记忆不参与"), snap)
	_check("V4 续档快照遗物真源（1件）", snap.contains("遗物1件"), snap)


func _v5_event_hist() -> void:
	print("── V5 事件环构筑史（P3） ──")
	var ev := "\n".join(DebugStats._diag_ev_lines)
	_check("V5 事件环含 [构筑] 波… 行（每次捕获一行）", ev.contains("[构筑] 波"), ev.right(400))
	_check("V5 构筑史行含遗物计数面（遗1）", ev.contains("遗1"), "")


func _v6_paused_hide() -> void:
	print("── V6 paused 模态隐藏（QA288-4 动态） ──")
	var pm: PopupManager = _gl.popup_manager
	PerfGovernor.boost_override = 1
	pm.on_damage_resolved(_mk_result(45000, 40.0))
	pm._agg_window_start_ms = Time.get_ticks_msec() - 1100
	pm.tick(DT)
	_check("V6 前置：PLAYING 落值 Label 可见", pm._agg_label != null and pm._agg_label.visible, "")
	_check("V6 层显式 1（与 HUD 同层——模态让位走隐藏）", pm._agg_layer != null and pm._agg_layer.layer == 1, "")
	_check("V6 P→PAUSED", bool(_gl.change_state(GameConst.GameStatus.PAUSED)), "")
	pm.tick(DT)
	_check("V6 ★paused tick → Label 隐藏（选卡/暂停/商店模态不被盖）",
		pm._agg_label != null and not pm._agg_label.visible, "")
	_check("V6 ★paused tick → 窗起点弃置（暂停时长不进秒窗）", pm._agg_window_start_ms == -1, "")
	_gl.change_state(GameConst.GameStatus.PLAYING)


func _v7_gameover_reset() -> void:
	print("── V7 GAME_OVER 聚合复位（QA288-4 动态） ──")
	var pm: PopupManager = _gl.popup_manager
	pm.on_damage_resolved(_mk_result(46000, 40.0))
	pm._agg_window_start_ms = Time.get_ticks_msec() - 1100
	pm.tick(DT)
	_check("V7 前置：Label 可见", pm._agg_label != null and pm._agg_label.visible, "")
	pm.on_damage_resolved(_mk_result(46001, 30.0))
	_check("V7 前置：在途窗值 30", is_equal_approx(pm._agg_window_value, 30.0),
		"v=%f" % pm._agg_window_value)
	_check("V7 P→GAME_OVER", bool(_gl.change_state(GameConst.GameStatus.GAME_OVER)), "")
	_check("V7 ★GAME_OVER → reset_agg（Label 隐 + 四字段复位——结算屏不冻结大字）",
		not pm._agg_label.visible and pm._agg_window_start_ms == -1
			and pm._agg_window_value == 0.0 and pm._agg_window_hits == 0,
		"vis=%s start=%d v=%f hits=%d" % [str(pm._agg_label.visible),
			pm._agg_window_start_ms, pm._agg_window_value, pm._agg_window_hits])
	PerfGovernor.boost_override = -1


func _cleanup() -> void:
	Meta.blessing_trait_id = _saved_blessing
	RunSave.clear()
	print("探针汇总：%d/%d 通过" % [_pass, _pass + _fail])

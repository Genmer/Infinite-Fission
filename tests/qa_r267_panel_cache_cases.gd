# R267 刀P3 三面板行缓存用例体（qa_r267_panel_cache 入口 load）
# 口径（设计 §1.3）：
#   a) 重开直挂门 ≤1500µs/次（绝对）且 ≤ 首开构建×0.5（相对——直挂必须显著低于
#      构建；改前全量重建实测参考：记录 5668µs / 养成 11782µs / 每日 3233µs，
#      会话记录值未存档日志，故门取自相对锚 + 绝对锚双保险）；
#      首开构建门 ≤ 改前参考×1.4（构建路径代码不变，宽门只拦回归）；
#   b) 购买轻刷新 ≤1500µs：行实例恒等 + Lv/货币文案即时更新 + 禁用态重算 +
#      购后再关开面板仍直挂（fp 尾段重算）；
#   c) 指纹语义：total_kills 变→记录面板重建且文案更新；stardust 变→养成面板
#      重建且星尘文案更新；daily_best 变→每日面板重建且最佳行更新；无变→同实例。
# 纪律：headless 自动隔离 meta_save_test.cfg；首尾快照/还原 Meta 全量（r198 先例）。
extends RefCounted

const REOPEN_GATE_US := 1500.0     # 设计 §1.3 重开门（绝对）
const REOPEN_RATIO := 0.5         # 重开 ≤ 首开×0.5（相对锚）
const FIRST_REF := {"records": 5668.0, "upgrade": 11782.0, "daily": 3233.0}  # 改前参考（会话记录值）
const FIRST_TOL := 1.4            # 首开 ≤ 参考×1.4（构建路径不变，宽门拦回归）

var _tree: SceneTree = null
var _fails: int = 0
var _passes: int = 0
var _snap: Dictionary = {}
var _menu: MenuScreen = null


func _check(p_name: String, p_ok: bool, p_detail: String = "") -> void:
	if p_ok:
		_passes += 1
		print("PASS | " + p_name)
	else:
		_fails += 1
		print("FAIL | " + p_name + ("" if p_detail.is_empty() else "  [got: " + p_detail + "]"))


func _snapshot() -> void:
	_snap = {
		"crystals": Meta.crystals,
		"stardust": Meta.stardust,
		"upgrades": Meta.upgrades.duplicate(true),
		"records": Meta.records.duplicate(true),
		"map_records": Meta.map_records.duplicate(true),
		"maps_cleared": Meta.maps_cleared.duplicate(true),
		"daily_records": Meta.daily_records.duplicate(true),
	}


func _restore() -> void:
	Meta.crystals = int(_snap["crystals"])
	Meta.stardust = int(_snap["stardust"])
	Meta.upgrades = _snap["upgrades"]
	Meta.records = _snap["records"]
	Meta.map_records = _snap["map_records"]
	Meta.maps_cleared = _snap["maps_cleared"]
	Meta.daily_records = _snap["daily_records"]
	Meta._save()


func fail_count() -> int:
	return _fails


func _press(p_kind: String) -> int:
	# 面板开（真用户路径计时——含回收口/直挂/压弹动触发）
	var t0 := Time.get_ticks_usec()
	_menu._on_lobby_pressed(p_kind)
	return Time.get_ticks_usec() - t0


func _press_cold_build(p_kind: String, p_cache_member: String) -> int:
	# 暖后构建计时：先开一次暖贴图/字体/词条表（与改前基线口径对齐——基线探针跑在
	# 多面板暖机后），再弃缓存组重开 = 纯构建路径成本
	_menu._on_lobby_pressed(p_kind)
	var cache: Array = _menu.get(p_cache_member)
	_menu._free_cached_rows(cache)
	_menu.set(p_cache_member, [])
	return _press(p_kind)


func _bench_close_reopen(p_n: int, p_kind: String) -> float:
	# 关→开循环均值（真用户「回大厅再进面板」重开口径——含面板收口/重开整链）
	var t0 := Time.get_ticks_usec()
	for i in range(p_n):
		_menu._on_panel_close()
		_menu._on_lobby_pressed(p_kind)
	return float(Time.get_ticks_usec() - t0) / float(p_n)


func run(p_tree: SceneTree) -> void:
	_tree = p_tree
	_snapshot()
	var gl: GameLoop = GameLoop.new()
	gl.name = "R267P3Panel"
	_tree.get_root().add_child(gl)
	gl.set_physics_process(false)
	var waited := 0
	while not gl.boot_ready and waited < 600:
		await _tree.process_frame
		waited += 1
	_menu = gl.menu_screen
	_check("boot：菜单就绪", _menu != null and gl.boot_ready)

	_test_records_panel()
	_test_upgrades_panel()
	_test_daily_panel()
	_test_buy_light_refresh()

	# 还原 + 清场
	_restore()
	_menu._on_panel_close()
	gl.queue_free()
	print("R267 刀P3 三面板行缓存汇总：PASS %d / FAIL %d（共 %d 项）" % [_passes, _fails, _passes + _fails])
	print("验收汇总：PASS %d / FAIL %d" % [_passes, _fails])


# ── a) 记录面板：暖构建 / 关→开重开 / 指纹失效重建 ──
func _test_records_panel() -> void:
	print("── a) 记录面板 ──")
	var first_us := _press_cold_build("records", "_rec_rows_cache")
	var rows0 := _menu._panel_list.get_child_count()
	_check("a 记录：面板 12 行（全局5+分图标题1+5图+进度1——显示面不变）",
		rows0 == 12, "rows=%d" % rows0)
	_check("a 记录：暖构建 ≤ 改前参考×%.1f（%dµs ≤ %.0fµs）" % [
		FIRST_TOL, first_us, FIRST_REF["records"] * FIRST_TOL],
		float(first_us) <= FIRST_REF["records"] * FIRST_TOL, "%dµs" % first_us)
	var reopen_us := _bench_close_reopen(8, "records")
	_check("a 记录：关→开重开 ≤%.0fµs（%.0fµs/次）" % [REOPEN_GATE_US, reopen_us],
		reopen_us <= REOPEN_GATE_US, "%.0fµs" % reopen_us)
	_check("a 记录：重开 ≤ 构建×%.1f（%.0f ≤ %.0f）" % [
		REOPEN_RATIO, reopen_us, float(first_us) * REOPEN_RATIO],
		reopen_us <= float(first_us) * REOPEN_RATIO,
		"build=%dµs reopen=%.0fµs" % [first_us, reopen_us])
	# 同态重开：行实例恒等（直挂复用）
	var id_a := _menu._panel_list.get_child(0).get_instance_id()
	_press("records")
	var id_b := _menu._panel_list.get_child(0).get_instance_id()
	_check("a 记录：同态重开首行同实例（直挂不重建）", id_a == id_b)
	# 指纹失效：total_kills 变 → 重建新实例 + 文案更新（累计击杀行 = 第5行 val_l）
	var tk0: int = int(Meta.records["total_kills"])
	Meta.records["total_kills"] = tk0 + 1
	_press("records")
	var id_c := _menu._panel_list.get_child(0).get_instance_id()
	var kills_txt := str(_menu._panel_list.get_child(4).get_child(1).text)
	_check("a 记录：total_kills 变→重建（新实例）且文案更新（累计击杀 %d）" % (tk0 + 1),
		id_c != id_b and kills_txt == str(tk0 + 1),
		"id_same=%s text=%s" % [str(id_c == id_b), kills_txt])
	Meta.records["total_kills"] = tk0


# ── a′) 养成面板：暖构建 / 关→开重开 / 星尘指纹 ──
func _test_upgrades_panel() -> void:
	print("── a′) 养成面板 ──")
	var first_us := _press_cold_build("upgrade", "_upg_rows_cache")
	var rows0 := _menu._panel_list.get_child_count()
	var n_upg: int = Meta.UPGRADES.size()
	_check("a′ 养成：行数 = 头+星尘+%d升级行+注（显示面不变）" % n_upg,
		rows0 == n_upg + 3, "rows=%d" % rows0)
	_check("a′ 养成：暖构建 ≤ 改前参考×%.1f（%dµs ≤ %.0fµs）" % [
		FIRST_TOL, first_us, FIRST_REF["upgrade"] * FIRST_TOL],
		float(first_us) <= FIRST_REF["upgrade"] * FIRST_TOL, "%dµs" % first_us)
	var reopen_us := _bench_close_reopen(8, "upgrade")
	_check("a′ 养成：关→开重开 ≤%.0fµs（%.0fµs/次）" % [REOPEN_GATE_US, reopen_us],
		reopen_us <= REOPEN_GATE_US, "%.0fµs" % reopen_us)
	_check("a′ 养成：重开 ≤ 构建×%.1f（%.0f ≤ %.0f）" % [
		REOPEN_RATIO, reopen_us, float(first_us) * REOPEN_RATIO],
		reopen_us <= float(first_us) * REOPEN_RATIO,
		"build=%dµs reopen=%.0fµs" % [first_us, reopen_us])
	# 指纹失效：stardust 变 → 重建 + 星尘文案更新（星尘行 = 第2行第2子 Label）
	var sd0: int = Meta.stardust
	var id_a := _menu._panel_list.get_child(2).get_instance_id()
	Meta.stardust = sd0 + 1
	_press("upgrade")
	var id_b := _menu._panel_list.get_child(2).get_instance_id()
	var sd_txt := str(_menu._panel_list.get_child(1).get_child(1).text)
	_check("a′ 养成：stardust 变→重建且星尘文案更新（含 %d）" % (sd0 + 1),
		id_b != id_a and sd_txt.contains(str(sd0 + 1)),
		"id_same=%s sd=%s" % [str(id_b == id_a), sd_txt])
	Meta.stardust = sd0
	_press("upgrade")                     # 回旧值重建，还原显示基态


# ── a″) 每日面板：暖构建 / 关→开重开 / daily_best 指纹 + 语义名锚 ──
func _test_daily_panel() -> void:
	print("── a″) 每日面板 ──")
	var first_us := _press_cold_build("daily", "_dly_rows_cache")
	var rows0 := _menu._panel_list.get_child_count()
	_check("a″ 每日：行数 = 诅×2+兆+最佳+注+出发钮（显示面不变）",
		rows0 == 6, "rows=%d" % rows0)
	_check("a″ 每日：出发钮语义名保持（verify_feedback 可达性锚）",
		_menu._panel_list.find_child("DailyStartButton", true, false) != null)
	_check("a″ 每日：暖构建 ≤ 改前参考×%.1f（%dµs ≤ %.0fµs）" % [
		FIRST_TOL, first_us, FIRST_REF["daily"] * FIRST_TOL],
		float(first_us) <= FIRST_REF["daily"] * FIRST_TOL, "%dµs" % first_us)
	var reopen_us := _bench_close_reopen(8, "daily")
	_check("a″ 每日：关→开重开 ≤%.0fµs（%.0fµs/次）" % [REOPEN_GATE_US, reopen_us],
		reopen_us <= REOPEN_GATE_US, "%.0fµs" % reopen_us)
	_check("a″ 每日：重开 ≤ 构建×%.1f（%.0f ≤ %.0f）" % [
		REOPEN_RATIO, reopen_us, float(first_us) * REOPEN_RATIO],
		reopen_us <= float(first_us) * REOPEN_RATIO,
		"build=%dµs reopen=%.0fµs" % [first_us, reopen_us])
	# 同态重开：行实例恒等
	var id_a := _menu._panel_list.get_child(0).get_instance_id()
	_press("daily")
	var id_b := _menu._panel_list.get_child(0).get_instance_id()
	_check("a″ 每日：同态重开首行同实例（直挂不重建）", id_a == id_b)
	# 指纹失效：daily_best 变 → 重建 + 最佳行更新（最佳行 = 第4行文本 Label）
	var key := Meta.daily_date_key()
	Meta.daily_records[key] = {"best_wave": 99, "best_kills": 88}
	_press("daily")
	var id_c := _menu._panel_list.get_child(0).get_instance_id()
	var best_txt := str(_menu._panel_list.get_child(3).get_child(1).text)
	_check("a″ 每日：daily_best 变→重建且最佳行更新（波次 99）",
		id_c != id_b and best_txt.contains("99"),
		"id_same=%s best=%s" % [str(id_c == id_b), best_txt])


# ── b) 购买轻刷新：同实例 + 文案/货币更新 + 计时 + 购后关开仍直挂 ──
func _test_buy_light_refresh() -> void:
	print("── b) 购买轻刷新 ──")
	Meta.crystals = 999999                     # 购买力保障（快照还原）
	var u0: Dictionary = Meta.UPGRADES[0]
	var uid: StringName = u0.id
	var lv0: int = Meta.upgrade_level(uid)
	var cost0: int = Meta.upgrade_cost(uid)
	_press("upgrade")
	var head0_txt := str(_menu._panel_list.get_child(0).text)
	var name_l := _menu._panel_list.get_child(2).get_child(0)
	var buy_btn: Button = _menu._panel_list.get_child(2).get_child(2)
	var name0_txt := str(name_l.text)
	var btn0_txt := str(buy_btn.text)
	var row_id0: int = _menu._panel_list.get_child(2).get_instance_id()
	var btn_id0: int = buy_btn.get_instance_id()
	var t0 := Time.get_ticks_usec()
	_menu._on_buy_upgrade(uid)
	var dt := Time.get_ticks_usec() - t0
	var head1_txt := str(_menu._panel_list.get_child(0).text)
	var name1_txt := str(name_l.text)
	var btn1_txt := str(buy_btn.text)
	_check("b 购买成功（%s Lv%d→%d，花费 %d）" % [String(uid), lv0, lv0 + 1, cost0],
		Meta.upgrade_level(uid) == lv0 + 1)
	_check("b 轻刷新 ≤%.0fµs（%dµs，对照改前全量重建参考 %.0fµs）" % [
		REOPEN_GATE_US, dt, FIRST_REF["upgrade"]],
		float(dt) <= REOPEN_GATE_US, "%dµs" % dt)
	_check("b 行/钮实例恒等（不重建）", row_id0 == _menu._panel_list.get_child(2).get_instance_id()
		and btn_id0 == buy_btn.get_instance_id())
	_check("b 结晶角标更新（Lv 文案 %s → %s）" % [name0_txt, name1_txt],
		head1_txt != head0_txt and name1_txt.contains("Lv%d" % (lv0 + 1))
			and name1_txt != name0_txt,
		"head=%s name=%s→%s" % [head1_txt, name0_txt, name1_txt])
	_check("b 按钮文案更新（%s → %s）" % [btn0_txt, btn1_txt], btn1_txt != btn0_txt)
	# 购后关→开：fp 已尾段重算 → 直挂（同实例）
	_menu._on_panel_close()                    # 收口落盘（buy 的 _save 抑制在此结清）
	var id_a := _menu._panel_list
	_press("upgrade")
	var id_b2 := _menu._panel_list
	var row_id1: int = _menu._panel_list.get_child(2).get_instance_id()
	var btn_id1: int = _menu._panel_list.get_child(2).get_child(2).get_instance_id()
	_check("b 购后关开仍直挂（行/钮同实例）",
		id_a == id_b2 and row_id1 == row_id0 and btn_id1 == btn_id0,
		"row %d→%d btn %d→%d" % [row_id0, row_id1, btn_id0, btn_id1])
	_check("b 购后关开文案保持新态（Lv%d）" % (lv0 + 1),
		str(_menu._panel_list.get_child(2).get_child(0).text).contains("Lv%d" % (lv0 + 1)))
	# 还原购买（快照兜底，此处双保险回 lvl + 存盘）
	Meta.upgrades[String(uid)] = lv0
	Meta._save()

# tests/runner/r245_diff_star_cases.gd
# R245「选关星标分档」用例体（由 test_r245_diff_star.gd 入口在 autoload 就绪后运行时加载）。
# 覆盖 G1~G5 五组（分组见套件头注）；文案断言一律对 MapTable final_wave 真值派生，
# 禁止硬抄波数。夹具：MenuScreen 裸实例 + DataRegistry 裸载（r198_menu_meta 同式）——
# 本套件零战斗零 GameLoop（选关面板/难度行/星标均在 MENU 域自足）。
# 纪律：headless 测试档自动隔离（meta_save_test.cfg）；首尾快照/还原 Meta 全量运行态
# 防跨套件污染（r198 F17 同式）；窗口尺寸改后必还原。
extends RefCounted

const MANIFEST_PATH := "res://data/manifest.cfg"   # game_loop.MANIFEST_PATH 同值

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _menu: MenuScreen = null
var _registry: DataRegistry = null
var _bk: Dictionary = {}
var _win_size0 := Vector2i(540, 960)


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(245)
	_snapshot_meta()
	_boot_menu()
	await tree.process_frame
	await tree.process_frame
	_test_g1_cleared_at()               # G1 分档查询口（纯 Meta 域）
	await _test_g2_star_follows_diff()  # G2 星标随难度联动（核心回归——用户现象）
	await _test_g3_diff_only()          # G3 仅高难度有记录的对称
	_test_g4_r88_gate()                 # G4 难度解锁门回归
	await _test_g5_zero_records()       # G5 零记录边缘
	await _test_g6_records_panel()      # G6 记录面板星标分档（QA D1/评审 P2 残留同修）
	await _test_g7_diff_unlock_chain()  # G7 难度解锁链分档（二cs：每难度独立一关关过）
	_restore_meta()
	_teardown_menu()
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
		print("PASS | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s %s" % [p_name, p_detail])
		print("FAIL | %s | %s" % [p_name, p_detail])


# ── 环境（r198_menu_meta_cases 同式） ───────────────────────────
func _snapshot_meta() -> void:
	_bk = {
		"records": Meta.records.duplicate(true),
		"map_records": Meta.map_records.duplicate(true),
		"maps_cleared": Meta.maps_cleared.duplicate(true),
		"daily_records": Meta.daily_records.duplicate(true),
		"achievements_done": Meta.achievements_done.duplicate(true),
		"codex_kills": Meta.codex_kills.duplicate(true),
		"codex_weapons": Meta.codex_weapons.duplicate(true),
		"codex_traits": Meta.codex_traits.duplicate(true),
		"unlocked_characters": Meta.unlocked_characters.duplicate(true),
		"upgrades": Meta.upgrades.duplicate(true),
		"crystals": Meta.crystals,
		"character_id": Meta.character_id,
		"custom_weapon_id": Meta.custom_weapon_id,
	}


func _restore_meta() -> void:
	Meta.records = _bk["records"]
	Meta.map_records = _bk["map_records"]
	Meta.maps_cleared = _bk["maps_cleared"]
	Meta.daily_records = _bk["daily_records"]
	Meta.achievements_done = _bk["achievements_done"]
	Meta.codex_kills = _bk["codex_kills"]
	Meta.codex_weapons = _bk["codex_weapons"]
	Meta.codex_traits = _bk["codex_traits"]
	Meta.unlocked_characters = _bk["unlocked_characters"]
	Meta.upgrades = _bk["upgrades"]
	Meta.crystals = int(_bk["crystals"])
	Meta.character_id = _bk["character_id"]
	Meta.custom_weapon_id = String(_bk["custom_weapon_id"])
	Meta.set_run_map(MapTable.FIRST_MAP_ID)
	Meta.set_run_difficulty(GameConst.Difficulty.NORMAL)
	Meta.set_run_daily(false)
	Meta._save()


func _normalize_window_for_boot() -> void:
	# 同 r194/r195/r196/r197/r198：-s 脚本模式根窗口归一（canvas 域恒等 720×1280）
	var win: Window = tree.root
	win.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	match String(ProjectSettings.get_setting("display/window/stretch/aspect", "keep")):
		"keep_width":
			win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP_WIDTH
		"keep_height":
			win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP_HEIGHT
		"expand":
			win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
		"ignore":
			win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_IGNORE
		_:
			win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
	_win_size0 = Vector2i(
		int(ProjectSettings.get_setting("display/window/size/window_width_override", 540)),
		int(ProjectSettings.get_setting("display/window/size/window_height_override", 960)))
	win.size = _win_size0


func _boot_menu() -> void:
	# MenuScreen 裸实例 + DataRegistry 裸载（game_loop._boot_load_data 同式）
	_normalize_window_for_boot()
	_registry = DataRegistry.new()
	_registry.load_all(MANIFEST_PATH)
	_menu = MenuScreen.new()
	_menu.name = "R245MenuScreenUnderTest"
	_menu.registry = _registry
	tree.get_root().add_child(_menu)               # _ready：建 UI + 挂 Meta 信号
	_check("前置：MenuScreen/registry 就绪",
		_menu != null and _menu.registry != null
		and _menu.registry.enemies.size() > 0)


func _teardown_menu() -> void:
	tree.paused = false
	RunSave.clear()
	var win: Window = tree.root
	win.size = _win_size0                          # 窗口尺寸还原
	if _menu != null:
		_menu.free()
		_menu = null


# ── 夹具口 ─────────────────────────────────────────────────────
func _first_map() -> Dictionary:
	return MapTable.MAPS[0]


func _first_final_wave() -> int:
	return int(_first_map().get("final_wave", 1 << 30))


func _inject_record(p_key: String, p_best_wave: int) -> void:
	# 直写分档记录（# 后缀键 = _settle_run_result 同构；不动 maps_cleared——分账）
	if not Meta.map_records.has(p_key):
		Meta.map_records[p_key] = {"best_wave": 0, "best_kills": 0, "best_level": 1}
	Meta.map_records[p_key]["best_wave"] = p_best_wave
	Meta.map_records_changed.emit()   # R259-D1：产品写点两处均 emit（失效选关行缓存）——夹具同口径，直挂旧行=陈旧星标假红


func _map_row_name_text(p_index: int) -> String:
	# 选关面板第 p_index 张地图行名 Label 文本（行结构：idx_l(0)/name_l(1)/…；
	# DifficultyRow 名行跳过；remove_child 重建保证同帧无残留旧行）
	var rows: Array[Panel] = []
	for c in _menu._panel_list.get_children():
		if c is Panel and String(c.name) != "DifficultyRow":
			rows.append(c as Panel)
	if p_index < 0 or p_index >= rows.size():
		return "<no row %d>" % p_index
	var l := rows[p_index].get_child(1) as Label
	return String(l.text) if l != null else "<no label>"


func _reset_star_fixture() -> void:
	# 每组用例前清零地图记录域（maps_cleared/map_records）——组间互不渗。
	# R259-D1 同族第二处：clear 同样 emit 失效选关行缓存（否则 G5 命中 G3/G4 带数据旧缓存=陈旧星标）
	Meta.maps_cleared.clear()
	Meta.map_records.clear()
	Meta.map_records_changed.emit()
	if _menu._sel_difficulty != 0:
		_menu._sel_difficulty = 0


# ══ G1：is_map_cleared_at 分档口径（纯 Meta 域） ══
func _test_g1_cleared_at() -> void:
	print("── G1：is_map_cleared_at 分档口径（普/困/狱各查分档键） ──")
	_reset_star_fixture()
	var mid: StringName = _first_map().id
	var fw := _first_final_wave()
	# 普通通关态：分档记录达线 + 解锁链置位（mark_map_cleared 后置）
	_inject_record(String(mid), fw)
	Meta.maps_cleared[String(mid)] = true
	_check("G1a 仅普通通关：is_map_cleared_at 普=true 困=狱=false",
		Meta.is_map_cleared_at(mid, 0) and not Meta.is_map_cleared_at(mid, 1)
		and not Meta.is_map_cleared_at(mid, 2),
		"普=%s 困=%s 狱=%s" % [Meta.is_map_cleared_at(mid, 0),
			Meta.is_map_cleared_at(mid, 1), Meta.is_map_cleared_at(mid, 2)])
	_check("G1b 旧口 is_map_cleared（解锁链）不受分档影响仍 true",
		Meta.is_map_cleared(mid))
	# 困难补录：#1 达线 → 困 true、普通口径不变
	_inject_record(String(mid) + "#1", fw)
	_check("G1c 困难补录：困=true 普=地狱不变",
		Meta.is_map_cleared_at(mid, 1) and Meta.is_map_cleared_at(mid, 0)
		and not Meta.is_map_cleared_at(mid, 2))
	# 未达线：#2 记录 < final_wave → false
	_inject_record(String(mid) + "#2", fw - 1)
	_check("G1d 地狱未达线（best=final-1）：false",
		not Meta.is_map_cleared_at(mid, 2))


# ══ G2：星标随所选难度联动（核心回归——用户现象「普通通了困/狱全通」） ══
func _test_g2_star_follows_diff() -> void:
	print("── G2：选关星标随难度联动（普通通关→切困/狱星标熄灭） ──")
	_reset_star_fixture()
	var mid: StringName = _first_map().id
	_inject_record(String(mid), _first_final_wave())   # 仅普通通关
	Meta.maps_cleared[String(mid)] = true              # 解锁链（困难通关同置——口径含高难度）
	_menu._sel_difficulty = 0
	_menu._open_map_select()
	await tree.process_frame                           # squash_pop/布局同帧安全余量
	var t0 := _map_row_name_text(0)
	_check("G2a 普通档：首图「已通关 ★」",
		t0.contains("已通关 ★"), "row0=%s" % t0)
	_menu._on_difficulty_pick(1)                       # 切困难——R245 重建地图行
	await tree.process_frame
	var t1 := _map_row_name_text(0)
	_check("G2b 困难档：星标熄灭→「可挑战」（修复点）",
		(not t1.contains("已通关 ★")) and t1.contains("可挑战"), "row0=%s" % t1)
	_menu._on_difficulty_pick(2)                       # 切地狱
	await tree.process_frame
	var t2 := _map_row_name_text(0)
	_check("G2c 地狱档：星标熄灭→「可挑战」",
		(not t2.contains("已通关 ★")) and t2.contains("可挑战"), "row0=%s" % t2)
	_menu._on_difficulty_pick(0)                       # 切回普通
	await tree.process_frame
	var t0b := _map_row_name_text(0)
	_check("G2d 切回普通：星标恢复",
		t0b.contains("已通关 ★"), "row0=%s" % t0b)
	_check("G2e 三次切档后难度按钮非空且普通选中",
		_menu._diff_btns.size() == 3 and _menu._sel_difficulty == 0)
	# 未通关的第二图在普通档恒「可挑战」（首图通关解锁第二图——解锁链文本另计）
	var t_second := _map_row_name_text(1)
	_check("G2f 第二图（未通）普通档「可挑战」无星",
		(not t_second.contains("已通关")) and t_second.contains("可挑战"),
		"row1=%s" % t_second)


# ══ G3：多档混合记录（真实验证态：普+困已通、狱未通） ══
func _test_g3_diff_only() -> void:
	print("── G3：普+困已通/狱未通 → 困亮星、地狱「可挑战」 ──")
	_reset_star_fixture()
	var mid: StringName = _first_map().id
	var fw := _first_final_wave()
	_inject_record(String(mid), fw)                  # 普通通关（R88 门开）
	_inject_record(String(mid) + "#1", fw)           # 困难亦通（真实可达：先普通后困难）
	Meta.maps_cleared[String(mid)] = true
	_menu._sel_difficulty = 1
	_menu._open_map_select()
	await tree.process_frame
	var t_hard := _map_row_name_text(0)
	_check("G3a 困难档（#1 达线）：亮星",
		t_hard.contains("已通关 ★"), "row0=%s" % t_hard)
	_check("G3b 困难按钮开放（普通已通，R88 门不回归）",
		_menu._diff_btns.size() == 3 and not _menu._diff_btns[1].disabled)
	_menu._on_difficulty_pick(2)                     # 切地狱（#2 无记录）
	await tree.process_frame
	var t_hell := _map_row_name_text(0)
	_check("G3c 地狱档（#2 无记录）：不亮星→「可挑战」（对称口径）",
		(not t_hell.contains("已通关 ★")) and t_hell.contains("可挑战"),
		"row0=%s" % t_hell)
	_check("G3d 普通档第二图解锁（普通图 1 已通——二cs 分档链）",
		Meta.is_map_unlocked(MapTable.MAPS[1].id, 0)
		and Meta.is_map_unlocked(MapTable.MAPS[1].id, 1))
	# G3e R88 回落保护回归：仅 #1 在册（普通未通，测试直写的不可达态）→ 面板
	# 选档被锁回落普通，星标按普通档（无记录）渲染——R245 重建链上回落仍生效
	_reset_star_fixture()
	_inject_record(String(mid) + "#1", fw)
	Meta.maps_cleared[String(mid)] = true
	_menu._sel_difficulty = 1
	_menu._open_map_select()
	await tree.process_frame
	var t_fallback := _map_row_name_text(0)
	_check("G3e 仅困在册（不可达态）：选档回落普通且不亮星",
		_menu._sel_difficulty == 0 and not t_fallback.contains("已通关 ★"),
		"sel=%s row0=%s" % [_menu._sel_difficulty, t_fallback])


# ══ G4：R88 难度解锁门回归（普通通关才开放困/狱） ══
func _test_g4_r88_gate() -> void:
	print("── G4：R88 难度门回归（普通通关 → 困/狱按钮开放） ──")
	_reset_star_fixture()
	var mid: StringName = _first_map().id
	_inject_record(String(mid), _first_final_wave())   # 普通通关（normal_cleared 达线）
	_menu._sel_difficulty = 0
	_menu._open_map_select()
	_check("G4a 普通已通关：困难/地狱按钮开放",
		_menu._diff_btns.size() == 3
		and not _menu._diff_btns[1].disabled
		and not _menu._diff_btns[2].disabled,
		"困 disabled=%s 狱 disabled=%s" % [
			str(_menu._diff_btns[1].disabled if _menu._diff_btns.size() > 1 else "n/a"),
			str(_menu._diff_btns[2].disabled if _menu._diff_btns.size() > 2 else "n/a")])
	_check("G4b normal_cleared 口径同步（分档记录驱动）",
		Meta.normal_cleared())


# ══ G5：零记录边缘（新档/清档——三档全「可挑战」） ══
func _test_g5_zero_records() -> void:
	print("── G5：零记录边缘（无任何通关记录 → 三档全「可挑战」） ──")
	_reset_star_fixture()
	_menu._sel_difficulty = 0
	_menu._open_map_select()
	await tree.process_frame
	var all_ok := true
	var detail := ""
	for d in range(3):
		_menu._on_difficulty_pick(d)
		await tree.process_frame
		var t := _map_row_name_text(0)
		if t.contains("已通关") or not t.contains("可挑战"):
			all_ok = false
			detail = "d%d row0=%s" % [d, t]
	_check("G5a 三档全「可挑战」无误亮", all_ok, detail)
	_check("G5b 零记录时困/狱按钮置灰（R88 门未过）",
		_menu._diff_btns[1].disabled and _menu._diff_btns[2].disabled)


# ══ G6：记录面板星标分档（QA D1/评审 P2——同族第二处，普/困/狱各挂各的星） ══
func _test_g6_records_panel() -> void:
	print("── G6：记录面板「普/困/狱」三列星标分档 ──")
	_reset_star_fixture()
	var mid: StringName = _first_map().id
	var fw := _first_final_wave()
	# 场景①：普通未达线 + 困难达线（旧口径会把任意难度通关错挂到普通列）
	_inject_record(String(mid), 3)
	_inject_record(String(mid) + "#1", fw)
	Meta.maps_cleared[String(mid)] = true          # 困难通关置位（解锁链）——旧口径即由此错亮
	_menu._rebuild_records()
	await tree.process_frame
	var v3 := _records_value_text(0)
	_check("G6a 三列行：普通(3波)无星 / 困难达线挂星 / 地狱无记录",
		v3 == "%d / %d★ / 0" % [3, fw], "val=%s（期望 '%d / %d★ / 0'）" % [v3, 3, fw])
	# 场景②：仅普通达线（单列分支，无 #1/#2 记录）
	_reset_star_fixture()
	_inject_record(String(mid), fw)
	_menu._rebuild_records()
	await tree.process_frame
	var v1 := _records_value_text(0)
	_check("G6b 单列行：普通达线挂「 ★」",
		v1 == "%d ★" % fw, "val=%s（期望 '%d ★'）" % [v1, fw])
	# 场景③：三档全通（地狱亦达线）——三列全星
	_reset_star_fixture()
	_inject_record(String(mid), fw)
	_inject_record(String(mid) + "#1", fw)
	_inject_record(String(mid) + "#2", fw)
	_menu._rebuild_records()
	await tree.process_frame
	var v_all := _records_value_text(0)
	_check("G6c 三档全通：三列全星",
		v_all == "%d★ / %d★ / %d★" % [fw, fw, fw], "val=%s" % v_all)


func _records_value_text(p_map_idx: int) -> String:
	# 记录面板第 p_map_idx 张图的数值列文本（行结构 name_l(0)+val_l(1)；
	# 按图名前缀定位，避位序脆性）
	var mname := String(MapTable.MAPS[p_map_idx].name)
	for c in _menu._panel_list.get_children():
		if c is Panel and c.get_child_count() >= 2:
			var nl := c.get_child(0) as Label
			if nl != null and String(nl.text).begins_with(mname):
				return String((c.get_child(1) as Label).text)
	return "<not found>"


# ══ G7：难度解锁链分档（二cs——用户「普通-困难-地狱每个小关都要一关关过」） ══
func _test_g7_diff_unlock_chain() -> void:
	print("── G7：解锁链分难度（仅普通通关 → 困/狱下一关仍锁） ──")
	_reset_star_fixture()
	var m0: StringName = MapTable.MAPS[0].id
	var m1: StringName = MapTable.MAPS[1].id
	# 场景①：仅普通通图 1（mark_map_cleared 默认普通档——即时分档落账口径）
	Meta.mark_map_cleared(m0)
	_check("G7a mark 即时落账：普通键 best_wave=final（分档链单源）",
		Meta.is_map_cleared_at(m0, 0) and not Meta.is_map_cleared_at(m0, 1))
	_check("G7b 仅普通通关：图 2 普通解锁 / 困难·地狱仍锁",
		Meta.is_map_unlocked(m1, 0) and not Meta.is_map_unlocked(m1, 1)
		and not Meta.is_map_unlocked(m1, 2))
	_check("G7c 图 1 三档恒解锁（各自起点）",
		Meta.is_map_unlocked(m0, 0) and Meta.is_map_unlocked(m0, 1)
		and Meta.is_map_unlocked(m0, 2))
	# UI 联动：切困难 → 图 2 行「通关上一关解锁」且无出发按钮
	_menu._sel_difficulty = 0
	_menu._open_map_select()
	await tree.process_frame
	_menu._on_difficulty_pick(1)
	await tree.process_frame
	var row1_hard := _map_row_text_and_button(1)
	_check("G7d 困难档图 2：锁定文案 + 无出发按钮（UI 联动）",
		row1_hard.text.contains("通关上一关解锁") and not row1_hard.has_play,
		"row1=%s has_play=%s" % [row1_hard.text, str(row1_hard.has_play)])
	# 场景②：困难图 1 也通 → 图 2 困难解锁、地狱仍锁
	Meta.mark_map_cleared(m0, 1)
	_check("G7e 困难图 1 通关：图 2 困难解锁 / 地狱仍锁",
		Meta.is_map_unlocked(m1, 1) and not Meta.is_map_unlocked(m1, 2))
	# 场景③：结算路径不回退（mark 即时落账后结算 maxi 幂等——直查键值不降）
	Meta._on_wave_cleared(int(MapTable.get_map(m0).get("final_wave", 1 << 30)))
	_check("G7f wave_cleared 复达线：记录不降不重（幂等）",
		Meta.is_map_cleared_at(m0, 0) and Meta.is_map_cleared_at(m0, 1))
	# 场景④：每日局通关（二cq#4 c5-③）——_on_wave_cleared 只喂 maps_cleared 不喂
	# 分档键（防「每日达线→普通档星标误亮+下一图普通档直开」回归；结算侧 :868 每日
	# 早退分流同源）。先清分档域取干净基线（夹具零新基建）；注入口径 = 真实局路径
	#（set_run_map/set_run_difficulty/set_run_daily 均为 GameLoop.start_run 注入口）
	_reset_star_fixture()
	Meta.set_run_map(m0)
	Meta.set_run_difficulty(0)
	Meta.set_run_daily(true)
	Meta._on_wave_cleared(int(MapTable.get_map(m0).get("final_wave", 1 << 30)))
	_check("G7g 每日局通关：分档键不喂（普/困均无星）",
		not Meta.is_map_cleared_at(m0, 0) and not Meta.is_map_cleared_at(m0, 1),
		"普=%s 困=%s" % [Meta.is_map_cleared_at(m0, 0), Meta.is_map_cleared_at(m0, 1)])
	_check("G7h 每日局通关：maps_cleared 仍置位（解锁链/成就口径不回退）",
		Meta.maps_cleared.has(String(m0)))
	Meta.set_run_daily(false)                       # 还原（_restore_meta :95 同款兜底，防后续组渗）


func _map_row_text_and_button(p_index: int) -> Dictionary:
	# 选关面板第 p_index 行：名 Label 文本 + 是否存在出发按钮（子树 Button 扫描）
	var rows: Array[Panel] = []
	for c in _menu._panel_list.get_children():
		if c is Panel and String(c.name) != "DifficultyRow":
			rows.append(c as Panel)
	if p_index < 0 or p_index >= rows.size():
		return { "text": "<no row>", "has_play": false }
	var row := rows[p_index]
	var l := row.get_child(1) as Label
	var has_play := false
	for ch in row.get_children():
		if ch is Button:
			has_play = true
	return { "text": String(l.text) if l != null else "", "has_play": has_play }

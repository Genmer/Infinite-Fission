extends RefCounted
# R259 专项深挖① cases：面板缓存命中 + 底层数据变化 → 显示正确性（陈旧数据面），
# 另含 map_records_changed 信号面（结算路径/通关喂入路径直证）。
# 纪律：全程 headless 测试档（save_path 自动指向 meta_save_test.cfg）；
# 进场快照 Meta 全部可变面，退场恢复 + _save，测试档零残留。

var _pass := 0
var _fail := 0
var _failures: Array[String] = []

# 面板行类别页签归类（menu_screen ACH_TYPE_CATEGORY 同源副本——探针侧断言用）
const CAT_COLLECT := ["run_weapons_drawn", "run_traits_drawn", "codex_weapons",
	"codex_traits", "maps_cleared", "codex_relics"]


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


func _map_row_title(p_row: Node) -> String:
	# MapRow 标题 Label 未设名标（仅选人/成就行有 NameL）——按「N 波 ·」文本特征扫描
	if p_row == null:
		return ""
	for l in p_row.find_children("*", "Label", true, false):
		var t := String((l as Label).text)
		if t.contains(" 波 ·"):
			return t
	return ""


func _ach_row_by_id(p_menu: Object, p_ach_id: String) -> Node:
	for c in (p_menu._panel_list as Node).get_children():
		if String(c.name).begins_with("AchRow_"):
			var a: Dictionary = (c as Node).get_meta("ach", {})
			if String(a.get("id", &"")) == p_ach_id:
				return c
	return null


func _char_row_button(p_row: Node, p_prefix: String) -> Button:
	if p_row == null:
		return null
	for b in p_row.find_children("*", "Button", true, false):
		if String((b as Button).text).begins_with(p_prefix):
			return b as Button
	return null


func _snapshot() -> Dictionary:
	return {
		"records": Meta.records.duplicate(true),
		"map_records": Meta.map_records.duplicate(true),
		"maps_cleared": Meta.maps_cleared.duplicate(),
		"achievements_done": Meta.achievements_done.duplicate(),
		"codex_weapons": Meta.codex_weapons.duplicate(),
		"unlocked_characters": Meta.unlocked_characters.duplicate(),
		"crystals": Meta.crystals,
		"character_id": Meta.character_id,
		"custom_weapon_id": Meta.custom_weapon_id,
	}


func _restore(p_snap: Dictionary) -> void:
	Meta.records = p_snap["records"].duplicate(true)
	Meta.map_records = p_snap["map_records"].duplicate(true)
	Meta.maps_cleared = p_snap["maps_cleared"].duplicate()
	Meta.achievements_done = p_snap["achievements_done"].duplicate()
	Meta.codex_weapons = p_snap["codex_weapons"].duplicate()
	Meta.unlocked_characters = p_snap["unlocked_characters"].duplicate()
	Meta.crystals = int(p_snap["crystals"])
	Meta.character_id = p_snap["character_id"]
	Meta.custom_weapon_id = p_snap["custom_weapon_id"]
	Meta._save()


func run(p_tree: SceneTree) -> void:
	var snap := _snapshot()
	var gl_script: GDScript = load("res://scripts/loop/game_loop.gd")
	var gl = gl_script.new()
	gl.name = "GameLoopForR259Stale"
	p_tree.get_root().add_child(gl)
	gl.set_physics_process(false)
	var waited := 0
	while not gl.boot_ready and waited < 600:
		await p_tree.process_frame
		waited += 1
	var menu = gl.menu_screen
	_check("boot：菜单就绪", menu != null and gl.boot_ready)

	var m0_id: StringName = MapTable.MAPS[0].id
	var m1_id: StringName = MapTable.MAPS[1].id
	var m1_final := int(MapTable.get_map(m1_id).get("final_wave", 30))

	# ══ S1 选关锁定态基线（第二图未解锁）══
	Meta.map_records.erase(String(m0_id))     # 清普通档分档键 → 第二图锁定（含测试档
	Meta.map_records.erase(String(m1_id))     # 残留：前轮探针落盘的 m1 星标一并清）
	Meta.maps_cleared.erase(String(m0_id))
	menu._on_difficulty_pick(0)
	menu._open_map_select()
	await p_tree.process_frame
	var map_row1_a: Node = menu._panel_list.get_node_or_null("MapRow_1")
	var row1_txt_a := _map_row_title(map_row1_a)
	var row1_locked_has_btn := false
	if map_row1_a != null:
		row1_locked_has_btn = not map_row1_a.find_children("*", "Button", true, false).is_empty()
	_check("S1 选关基线：第二图呈锁定文案", map_row1_a != null and row1_txt_a.contains("通关上一关解锁"),
		"txt=%s" % row1_txt_a)
	_check("S1 选关基线：锁定行无出发钮", map_row1_a != null and not row1_locked_has_btn)

	# ══ S2 陈旧数据面·通关喂入写点（mark_map_cleared 真实路径）══
	# 面板已开（行已缓存）→ 底层记录变 → 失效口必须接住（R254-D1 教训）
	Meta.mark_map_cleared(m0_id, 0, true)
	_check("S2 喂入路径：map_records_changed 已发→选关缓存弃置",
		menu._map_rows_cache.is_empty(), "cache_size=%d" % menu._map_rows_cache.size())
	menu._open_map_select()
	await p_tree.process_frame
	var map_row0_b: Node = menu._panel_list.get_node_or_null("MapRow_0")
	var map_row1_b: Node = menu._panel_list.get_node_or_null("MapRow_1")
	var row0_txt_b := _map_row_title(map_row0_b)
	var row1_txt_b := _map_row_title(map_row1_b)
	_check("S2 陈旧修复：第一图星标「已通关 ★」", row0_txt_b.contains("已通关"), "txt=%s" % row0_txt_b)
	_check("S2 陈旧修复：第二图解锁「可挑战」+出发钮",
		row1_txt_b.contains("可挑战") and map_row1_b != null
			and not map_row1_b.find_children("*", "Button", true, false).is_empty(),
		"txt=%s" % row1_txt_b)
	_check("S2 重建=新行实例（旧行不复用）", map_row1_b != map_row1_a)

	# ══ S3 信号面·结算路径（_settle_run_result 直调=GAME_OVER 同函数）══
	var emit_box := {"n": 0}
	var sink: Callable = func() -> void: emit_box["n"] = int(emit_box["n"]) + 1
	Meta.map_records_changed.connect(sink)
	menu._on_panel_close()                    # 关面板（结清 persist_defer 包络）
	Meta._run_daily = false
	Meta._run_map = m1_id
	Meta._run_difficulty = 0
	Meta._run_max_wave = m1_final
	Meta._run_kills = 5
	Meta._run_max_level = 2
	Meta._settle_run_result()
	Meta.map_records_changed.disconnect(sink)
	_check("S3 结算路径：map_records_changed 恰发（写点 :1069）", int(emit_box["n"]) == 1,
		"cnt=%d" % int(emit_box["n"]))
	_check("S3 结算路径：第二图分档星标落账", Meta.is_map_cleared_at(m1_id, 0))
	_check("S3 结算路径：菜单侧缓存失效（_ready 连线端到端）",
		menu._map_rows_cache.is_empty())
	menu._open_map_select()
	await p_tree.process_frame
	var map_row1_c: Node = menu._panel_list.get_node_or_null("MapRow_1")
	var row1_txt_c := _map_row_title(map_row1_c)
	_check("S3 陈旧修复：结算后重开第二图呈星标", row1_txt_c.contains("已通关"), "txt=%s" % row1_txt_c)
	menu._on_panel_close()

	# ══ S4 成就：进度轻刷（缓存命中）+ 完成翻转（sig 重建）══
	Meta.records["total_kills"] = 10
	Meta.achievements_done.erase("kill_500")
	menu._on_lobby_pressed("ach")
	await p_tree.process_frame
	var kill_row_a: Node = _ach_row_by_id(menu, "kill_500")
	var kill_desc_a := ""
	if kill_row_a != null and kill_row_a.get_node_or_null("DescL") != null:
		kill_desc_a = String((kill_row_a.get_node_or_null("DescL") as Label).text)
	_check("S4 成就基线：kill_500 行进度 10/500",
		kill_row_a != null and kill_desc_a.contains("10/500"), "desc=%s" % kill_desc_a)
	Meta.records["total_kills"] = 123         # 无信号直改（done 位图不变 → sig 同）
	menu._on_lobby_pressed("codex")
	menu._on_lobby_pressed("ach")
	await p_tree.process_frame
	var kill_row_b: Node = _ach_row_by_id(menu, "kill_500")
	var kill_desc_b := ""
	if kill_row_b != null and kill_row_b.get_node_or_null("DescL") != null:
		kill_desc_b = String((kill_row_b.get_node_or_null("DescL") as Label).text)
	_check("S4 轻刷：命中同实例（零重建）", kill_row_b == kill_row_a and kill_row_b != null)
	_check("S4 轻刷：进度文本实时 123/500", kill_desc_b.contains("123/500"), "desc=%s" % kill_desc_b)
	menu._on_panel_close()                    # 结清包络（_check_achievements 抑制防御）
	Meta.records["total_kills"] = 600
	Meta._check_achievements()
	menu._on_lobby_pressed("ach")
	await p_tree.process_frame
	var kill_row_c: Node = _ach_row_by_id(menu, "kill_500")
	var kill_mark_c := ""
	var kill_desc_c := ""
	if kill_row_c != null:
		kill_mark_c = String((kill_row_c.get_node_or_null("Mark") as Label).text)
		kill_desc_c = String((kill_row_c.get_node_or_null("DescL") as Label).text)
	_check("S4 完成翻转：done 位图变=sig 重建（✓+已完成）",
		kill_row_c != null and kill_row_c != kill_row_b
			and kill_mark_c == "✓" and kill_desc_c.contains("已完成"),
		"mark=%s desc=%s" % [kill_mark_c, kill_desc_c])

	# ══ S5 成就：类别页签往返（sig 不含页签 → 位图长度区分，防串页直证）══
	menu._on_ach_tab("收集")
	await p_tree.process_frame
	var col_first: Dictionary = {}
	for c in (menu._panel_list as Node).get_children():
		if String(c.name) == "AchRow_0":
			col_first = (c as Node).get_meta("ach", {})
			break
	_check("S5 收集页签首行=收集族成就", CAT_COLLECT.has(String(col_first.get("type", ""))),
		"type=%s" % String(col_first.get("type", "")))
	menu._on_ach_tab("全部")
	await p_tree.process_frame
	var all_first: Dictionary = {}
	for c in (menu._panel_list as Node).get_children():
		if String(c.name) == "AchRow_0":
			all_first = (c as Node).get_meta("ach", {})
			break
	_check("S5 回「全部」首行=全表首条（first_blood）",
		String(all_first.get("id", "")) == "first_blood",
		"id=%s" % String(all_first.get("id", "")))
	menu._on_ach_tab("收集")
	await p_tree.process_frame
	var col_first2: Dictionary = {}
	for c in (menu._panel_list as Node).get_children():
		if String(c.name) == "AchRow_0":
			col_first2 = (c as Node).get_meta("ach", {})
			break
	_check("S5 二次入「收集」首行仍正确（无跨签残留）",
		String(col_first2.get("id", "")) == String(col_first.get("id", "")),
		"id=%s" % String(col_first2.get("id", "")))
	menu._on_panel_close()

	# ══ S6 选人：结晶/购买/自定义武器/图鉴计数逐项 sig 输入 ══
	var price_idx := -1
	for i in range(CharacterTable.count()):
		var d: Dictionary = CharacterTable.CHARACTERS[i]
		if int(d.get("unlock_price", 0)) > 0:
			price_idx = i
			break
	if price_idx >= 0:
		var pid: StringName = CharacterTable.CHARACTERS[price_idx].id
		Meta.unlocked_characters.erase(String(pid))   # 强制锁定态（退场快照恢复）
		Meta.crystals = 0
		menu._on_lobby_pressed("char")
		await p_tree.process_frame
		var prow_a: Node = menu._panel_list.get_node_or_null("CharRow_%d" % price_idx)
		var buy_a: Button = _char_row_button(prow_a, "解锁")
		_check("S6 购买力位：结晶不足=解锁钮置灰",
			prow_a != null and buy_a != null and buy_a.disabled,
			"row=%s btn=%s" % [str(prow_a != null), str(buy_a != null)])
		Meta.crystals = 99999
		menu._on_lobby_pressed("codex")
		menu._on_lobby_pressed("char")
		await p_tree.process_frame
		var prow_b: Node = menu._panel_list.get_node_or_null("CharRow_%d" % price_idx)
		var buy_b: Button = _char_row_button(prow_b, "解锁")
		_check("S6 购买力位：结晶足=sig 重建+钮可点",
			prow_b != null and buy_b != null and not buy_b.disabled and prow_b != prow_a)
		menu._on_char_buy(pid)                 # 购买（真实写口）
		menu._on_lobby_pressed("codex")
		menu._on_lobby_pressed("char")
		await p_tree.process_frame
		var prow_c: Node = menu._panel_list.get_node_or_null("CharRow_%d" % price_idx)
		var buy_c: Button = _char_row_button(prow_c, "解锁")
		var name_c := ""
		if prow_c != null and prow_c.get_node_or_null("NameL") != null:
			name_c = String((prow_c.get_node_or_null("NameL") as Label).text)
		_check("S6 购买后：解锁钮消失+锁定句清除",
			Meta.is_character_unlocked(pid) and buy_c == null and not name_c.contains("解锁"),
			"unlocked=%s name=%s" % [str(Meta.is_character_unlocked(pid)), name_c])
	else:
		print("  -- | S6 购买段跳过：无 unlock_price 角色")
	menu._on_panel_close()

	# 自定义武器循环（fission 行）+ 图鉴计数联动
	var fission_idx := -1
	for i in range(CharacterTable.count()):
		if not CharacterTable.has_skill(CharacterTable.CHARACTERS[i].id):
			fission_idx = i
			break
	var extra_w: StringName = &""
	var extra_w2: StringName = &""
	if menu.registry != null:
		for wid_v in (menu.registry.weapons as Dictionary).keys():
			var sid := StringName(String(wid_v))
			if sid == &"W1_pistol" or Meta.codex_weapons.has(String(sid)):
				continue
			if MechanicGate.weapon_difficulty_min(sid) > 0:
				continue
			if extra_w == &"":
				extra_w = sid
			elif extra_w2 == &"":
				extra_w2 = sid
				break
	if fission_idx >= 0 and extra_w != &"":
		Meta.codex_weapons[String(extra_w)] = true     # 候选 ≥2（退场快照恢复）
		var wdisp := ""
		if menu.registry.get_weapon(extra_w) != null:
			wdisp = String(menu.registry.get_weapon(extra_w).display_name)
		menu._on_difficulty_pick(0)
		menu._on_lobby_pressed("char")
		await p_tree.process_frame
		var frow_a: Node = menu._panel_list.get_node_or_null("CharRow_%d" % fission_idx)
		var wbtn_a: Button = _char_row_button(frow_a, "初始武器")
		var wtxt_a := String(wbtn_a.text) if wbtn_a != null else ""
		var codex_a := ""
		if frow_a != null:
			for l in frow_a.find_children("*", "Label", true, false):
				if String((l as Label).text).begins_with("图鉴 "):
					codex_a = String((l as Label).text)
					break
		# 空键首循环回首候选（手枪）→ 后续按候选序推进；断言锚定「当前写口值」
		for k in 3:
			menu._on_custom_weapon_cycle()
			await p_tree.process_frame
		var frow_b: Node = menu._panel_list.get_node_or_null("CharRow_%d" % fission_idx)
		var wbtn_b: Button = _char_row_button(frow_b, "初始武器")
		var wtxt_b := String(wbtn_b.text) if wbtn_b != null else ""
		var cw_now := String(Meta.custom_weapon())
		var cw_disp := ""
		if cw_now != "" and menu.registry.get_weapon(StringName(cw_now)) != null:
			cw_disp = String(menu.registry.get_weapon(StringName(cw_now)).display_name)
		_check("S6 武器循环：循环后写口推进（状态真值）",
			cw_now != "" and cw_now != String(snap["custom_weapon_id"]),
			"cw=%s snap_cw=%s" % [cw_now, String(snap["custom_weapon_id"])])
		_check("S6 武器循环：按钮文本即时换（sig 重建）",
			wtxt_b != "" and wtxt_b != wtxt_a and wtxt_b.contains(cw_disp),
			"a=%s b=%s disp=%s" % [wtxt_a, wtxt_b, cw_disp])
		menu._on_custom_weapon_cycle()        # 再循环回手枪（第二轮重建对拍）
		await p_tree.process_frame
		if extra_w2 != &"":
			Meta.codex_weapons[String(extra_w2)] = true
			menu._on_lobby_pressed("codex")
			menu._on_lobby_pressed("char")
			await p_tree.process_frame
			var frow_c: Node = menu._panel_list.get_node_or_null("CharRow_%d" % fission_idx)
			var codex_c := ""
			if frow_c != null:
				for l in frow_c.find_children("*", "Label", true, false):
					if String((l as Label).text).begins_with("图鉴 "):
						codex_c = String((l as Label).text)
						break
			var n_a := codex_a.split("/")[0].trim_prefix("图鉴 ").to_int() if codex_a != "" else -1
			var n_c := codex_c.split("/")[0].trim_prefix("图鉴 ").to_int() if codex_c != "" else -1
			_check("S6 图鉴计数：收录+1=行内计数刷新（sig 重建）",
				n_c == n_a + 1, "a=%s(%d) c=%s(%d)" % [codex_a, n_a, codex_c, n_c])
		else:
			print("  -- | S6 图鉴计数联动跳过：无第二把普档武器")
	else:
		print("  -- | S6 武器循环跳过：fission=%d extra_w=%s" % [fission_idx, String(extra_w)])
	menu._on_panel_close()

	# ══ S7 图鉴↔成就↔选人↔选关互切（行不串面板 + 子数稳定）══
	var char_counts: Array[int] = []
	var s7_bad := false
	for k in 3:
		menu._on_lobby_pressed("codex")
		await p_tree.process_frame
		for c in (menu._panel_list as Node).get_children():
			var nm := String(c.name)
			if nm.begins_with("AchRow_") or nm.begins_with("CharRow_") or nm.begins_with("MapRow_"):
				_check("S7 互切：图鉴开=三面板行全回收（第%d轮）" % (k + 1), false, "外行=%s" % nm)
				s7_bad = true
		menu._on_lobby_pressed("ach")
		await p_tree.process_frame
		var has_ach := false
		for c in (menu._panel_list as Node).get_children():
			var nm := String(c.name)
			if nm.begins_with("AchRow_"):
				has_ach = true
			elif nm.begins_with("CodexRow_") or nm.begins_with("RxnRow_") \
					or nm.begins_with("CharRow_") or nm.begins_with("MapRow_"):
				_check("S7 互切：成就开=成就行在场且无外行（第%d轮）" % (k + 1), false, "外行=%s" % nm)
				s7_bad = true
		if not has_ach:
			_check("S7 互切：成就开=成就行在场（第%d轮）" % (k + 1), false)
			s7_bad = true
		menu._on_lobby_pressed("char")
		await p_tree.process_frame
		var has_char := false
		for c in (menu._panel_list as Node).get_children():
			var nm := String(c.name)
			if nm.begins_with("CharRow_"):
				has_char = true
			elif nm.begins_with("AchRow_") or nm.begins_with("MapRow_") or nm.begins_with("CodexRow_"):
				_check("S7 互切：选人开=选人行在场且无外行（第%d轮）" % (k + 1), false, "外行=%s" % nm)
				s7_bad = true
		if not has_char:
			_check("S7 互切：选人开=选人行在场（第%d轮）" % (k + 1), false)
			s7_bad = true
		char_counts.append((menu._panel_list as Node).get_child_count())
		menu._open_map_select()
		await p_tree.process_frame
		var has_map := menu._panel_list.get_node_or_null("DifficultyRow") != null
		for c in (menu._panel_list as Node).get_children():
			var nm := String(c.name)
			if nm.begins_with("AchRow_") or nm.begins_with("CharRow_") or nm.begins_with("CodexRow_"):
				_check("S7 互切：选关开=难度行在场且无外行（第%d轮）" % (k + 1), false, "外行=%s" % nm)
				s7_bad = true
		if not has_map:
			_check("S7 互切：选关开=难度行在场（第%d轮）" % (k + 1), false)
			s7_bad = true
	if not s7_bad:
		_check("S7 互切：图鉴/成就/选人/选关三轮零串行", true)
	_check("S7 互切：选人面板子数三轮稳定（%s）" % str(char_counts),
		char_counts.size() == 3 and char_counts[0] == char_counts[1] and char_counts[1] == char_counts[2])
	menu._on_panel_close()

	# 退场恢复（测试档零残留）
	_restore(snap)
	gl.free()
	print("验收汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	for f in _failures:
		print("  FAIL | %s" % f)

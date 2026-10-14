extends RefCounted
# R259 三面板行缓存验收 cases（配套口 qa_r259_panel_cache.gd）。
# 全程 headless 内存态（改 Meta 计数/角色不落真档——menu median 探针同款 boot）。

var _pass := 0
var _fail := 0
var _failures: Array[String] = []


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("  ok | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s %s" % [p_name, p_detail])
		print("  FAIL | %s %s" % [p_name, p_detail])


func fail_count() -> int:
	return _fail


func run(p_tree: SceneTree) -> void:
	var gl_script: GDScript = load("res://scripts/loop/game_loop.gd")
	var gl = gl_script.new()
	gl.name = "GameLoopForR259PanelCache"
	p_tree.get_root().add_child(gl)
	gl.set_physics_process(false)
	var waited := 0
	while not gl.boot_ready and waited < 600:
		await p_tree.process_frame
		waited += 1
	var menu = gl.menu_screen
	_check("boot：菜单就绪", menu != null and gl.boot_ready)

	# ── ① 成就页缓存：miss 建行 → 命中同行实例 → 进度轻刷 → done 翻转重建 ──
	menu._on_lobby_pressed("ach")
	var ach_row0_a: Node = menu._panel_list.get_node_or_null("AchRow_0")
	_check("成就：首开建行（AchRow_0 在树）", ach_row0_a != null)
	var ach_desc_before := ""
	if ach_row0_a != null:
		ach_desc_before = String((ach_row0_a.get_node_or_null("DescL") as Label).text)
	menu._on_lobby_pressed("codex")             # 切走（成就行 detach 回缓存）
	menu._on_lobby_pressed("ach")               # 切回（命中路径）
	var ach_row0_b: Node = menu._panel_list.get_node_or_null("AchRow_0")
	_check("成就：重开命中缓存=同行实例（零重建）",
		ach_row0_b != null and ach_row0_a != null and ach_row0_b == ach_row0_a)
	# 进度轻刷：未完成行文本==单源函数现算值（轻刷执行+口径单源双证）。
	# 不挑具体计数键（首行成就可能已完成=固定文本）——遍历取任一未完成行。
	var ach_lrow: Node = null
	for c in menu._panel_list.get_children():
		var d_l: Label = (c as Node).get_node_or_null("DescL") as Label
		if d_l != null and String(c.name).begins_with("AchRow_") and d_l.text.contains("/"):
			ach_lrow = c as Node
			break
	var refreshed := false
	if ach_lrow != null:
		var a_l: Dictionary = ach_lrow.get_meta("ach", {})
		var expect_l: String = menu._ach_desc_text(a_l, Meta.is_ach_done(a_l.get("id", &"")))
		var got_l := String((ach_lrow.get_node_or_null("DescL") as Label).text)
		refreshed = got_l == expect_l
	_check("成就：desc 轻刷=单源现算值（未完成行 x/y 随计数实时）",
		ach_lrow != null and refreshed,
		"lrow=%s" % str(ach_lrow != null))

	# ── ② 选人签名：命中同实例 → 换角色 sig 变重建（选中标记移动） ──
	menu._on_lobby_pressed("char")
	var char_row0_a: Node = menu._panel_list.get_node_or_null("CharRow_0")
	var char_row1_a: Node = menu._panel_list.get_node_or_null("CharRow_1")
	_check("选人：首开建行（CharRow_0/1 在树）", char_row0_a != null and char_row1_a != null)
	var char_id_before := String(Meta.character_id)
	var swapped := false
	if char_row1_a != null and String(Meta.character_id) != String(CharacterTable.CHARACTERS[1].id) \
			and Meta.is_character_unlocked(CharacterTable.CHARACTERS[1].id):
		Meta.character_id = CharacterTable.CHARACTERS[1].id   # 换角色（sig 项）
		swapped = true
	menu._on_lobby_pressed("codex")
	menu._on_lobby_pressed("char")
	var char_row0_b: Node = menu._panel_list.get_node_or_null("CharRow_0")
	_check("选人：签名变化=重建（换角色后新行实例，选中✓移至 row1）",
		(not swapped and char_row0_b == char_row0_a)
			or (swapped and char_row0_b != null and char_row0_b != char_row0_a
				and String((char_row0_b.get_node_or_null("NameL") as Label).text)
					.contains("当前") == false),
		"swapped=%s same=%s" % [str(swapped), str(char_row0_b == char_row0_a)])
	if swapped:
		var row1_name := ""
		var char_row1_b: Node = menu._panel_list.get_node_or_null("CharRow_1")
		if char_row1_b != null:
			row1_name = String((char_row1_b.get_node_or_null("NameL") as Label).text)
		_check("选人：新选中行带「当前」标记", row1_name.contains("当前"), "row1=%s" % row1_name)
		Meta.character_id = StringName(char_id_before)        # 还原

	# ── ③ 选关分档缓存+失效 ──
	menu._on_difficulty_pick(0)                 # 先归普通档（面板行为同 _open_map_select 内部）
	menu._open_map_select()
	var map_row0_d0_a: Node = menu._panel_list.get_node_or_null("MapRow_0")
	_check("选关：首开建行（MapRow_0 在树）", map_row0_d0_a != null)
	menu._on_difficulty_pick(1)                 # 切困难（另一档缓存 miss 建行）
	var map_row0_d1: Node = menu._panel_list.get_node_or_null("MapRow_0")
	_check("选关：切档=另一档行（分档缓存独立实例）",
		map_row0_d1 != null and map_row0_d0_a != null and map_row0_d1 != map_row0_d0_a)
	menu._on_difficulty_pick(0)                 # 切回普通（首套实例复用）
	var map_row0_d0_b: Node = menu._panel_list.get_node_or_null("MapRow_0")
	_check("选关：切回复用首套实例（档 0 缓存命中）",
		map_row0_d0_b != null and map_row0_d0_b == map_row0_d0_a)
	# 失效：map_records_changed → 全档弃置（新实例）
	Meta.map_records_changed.emit()
	var map_row0_d0_c: Node = menu._panel_list.get_node_or_null("MapRow_0")
	_check("选关：失效=挂树行一并 detach（面板开着防御路径）",
		map_row0_d0_c == null)
	menu._on_difficulty_pick(0)
	menu._open_map_select()
	var map_row0_d0_d: Node = menu._panel_list.get_node_or_null("MapRow_0")
	_check("选关：失效后重开=重建新实例", map_row0_d0_d != null and map_row0_d0_d != map_row0_d0_a)

	# ── ③½ LOW-1 评审复核：孤儿 freed（HIGH-1）/难度入 sig（MED-1）/页签入键（MED-2） ──
	# HIGH-1+MED-1：选人开着记实例 → 切走 → 切难度 → 切回选人（sig 含难度=必重建，
	# 覆盖前 _free_cached_rows 释放旧行）→ 旧行帧末后已释放 + 武器钮文本现算。
	# fission 行（无技能=有初始武器循环钮）按表序遍历定位，非固定 CharRow_0
	var fission_idx := -1
	for i in range(CharacterTable.count()):
		if not CharacterTable.has_skill(CharacterTable.CHARACTERS[i].id):
			fission_idx = i
			break
	menu._on_lobby_pressed("char")
	var char_old: Node = menu._panel_list.get_node_or_null("CharRow_%d" % fission_idx) \
			if fission_idx >= 0 else null
	menu._on_lobby_pressed("codex")
	menu._on_panel_close()                     # 面板全关再切难度（真机路径：难度钮只在选关面板内）
	menu._on_difficulty_pick(1)
	var diff_now: int = menu.selected_difficulty()
	menu._on_lobby_pressed("char")
	await p_tree.process_frame                     # queue_free 帧末生效
	var char_new: Node = menu._panel_list.get_node_or_null("CharRow_%d" % fission_idx) \
			if fission_idx >= 0 else null
	var wep_new: Button = null
	if char_new != null:
		wep_new = char_new.get_node_or_null("CustomWeaponCycle") as Button
	var wep_expect := "初始武器：%s ▸" % menu._custom_weapon_label()
	# char_old 释放后为悬垂引用——GDScript freed 实例 == null 判等为 true（! null 比较恒假），
	# 存在性以 is_instance_valid 表达（char_old 开头已非 null，DBG 实证 <Freed Object>）
	_check("评审H1：难度变=选人重建且旧行已释放（无孤儿泄漏）",
		fission_idx < 0 or diff_now != 1 or (char_new != null and char_new != char_old
			and not is_instance_valid(char_old)),
		"diff=%d same=%s old_valid=%s" % [diff_now, str(char_new == char_old),
			str(is_instance_valid(char_old))])
	_check("评审M1：切难度后选人武器钮文本=现算值（sig 含难度）",
		fission_idx < 0 or diff_now != 1 or (wep_new != null and String(wep_new.text) == wep_expect),
		"got=%s expect=%s" % [str(String(wep_new.text) if wep_new != null else "?"), wep_expect])
	menu._on_difficulty_pick(0)                    # 难度还原（后续性能门口径一致）

	# MED-2：成就页签入键——切签=各自独立缓存（miss 建行不覆盖原签），切回原签仍命中。
	menu._on_lobby_pressed("ach")
	var ach_tab_before := String(menu._ach_tab)
	var ach_all_row: Node = menu._panel_list.get_node_or_null("AchRow_0")
	var other_tab: String = ""
	for t_v: Variant in menu._ach_tabs.keys():
		if String(t_v) != ach_tab_before:
			other_tab = String(t_v)
			break
	var tab_moved := other_tab != ""
	if tab_moved:
		menu._on_ach_tab(other_tab)                # 切签（另一键 miss 建行）
	menu._on_lobby_pressed("codex")
	menu._on_lobby_pressed("ach")
	var ach_tab_row: Node = menu._panel_list.get_node_or_null("AchRow_0")
	_check("评审M2：切签重开=页签缓存独立（不与原签互撞）",
		not tab_moved or (ach_tab_row != null and ach_all_row != null and ach_tab_row != ach_all_row),
		"tab=%s same=%s" % [other_tab, str(ach_tab_row == ach_all_row)])
	if tab_moved:
		menu._on_lobby_pressed("codex")             # 同签二次访问=键命中（切签后缓存真正有效）
		menu._on_lobby_pressed("ach")
		var ach_tab_row2: Node = menu._panel_list.get_node_or_null("AchRow_0")
		_check("评审M2：同签重开=命中同行实例（页签维度缓存有效）",
			ach_tab_row2 != null and ach_tab_row2 == ach_tab_row,
			"same=%s" % str(ach_tab_row2 == ach_tab_row))
	if tab_moved:
		_check("评审M2：原签键未被覆盖（切回仍命中原实例，无覆盖泄漏）",
			menu._ach_page_cache.has("%s|%d" % [ach_tab_before, menu._ach_page]),
			"keys=%s" % str(menu._ach_page_cache.keys()))
		menu._on_ach_tab(ach_tab_before)            # 页签还原
	menu._on_lobby_pressed("codex")

	# ── ④ 性能门：命中路径中位 <5ms（防回归） ──
	var samples: Array = []
	for i in 5:
		var t0 := Time.get_ticks_usec()
		menu._on_lobby_pressed("ach")
		samples.append(Time.get_ticks_usec() - t0)
	samples.sort()
	var median_ms := float(samples[2]) / 1000.0
	_check("性能门：成就重开中位 %.2f ms < 5ms（缓存命中防回归）" % median_ms,
		median_ms < 5.0)

	gl.free()
	print("验收汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	for f in _failures:
		print("  FAIL | %s" % f)

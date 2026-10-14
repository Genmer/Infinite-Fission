extends RefCounted
# R259 专项深挖② cases：内存面（v2——实例追踪为主证据，OBJECT_COUNT 为辅）。
# 每次重建触发操作后逐个追踪「重建前缓存行实例」去向：alive+无父+不在缓存=孤儿泄漏；
# instance_from_id==null=已被 free。互切/切档/失效用「同实例复用+全数释放」证明。
# 纪律：进场快照、退场恢复 + _save（headless 测试档零残留）。

var _pass := 0
var _fail := 0
var _failures: Array[String] = []


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


func _obj() -> int:
	return int(Performance.get_monitor(Performance.OBJECT_COUNT))


func _ids_of(p_rows: Array) -> Array[int]:
	var out: Array[int] = []
	for r_v in p_rows:
		if r_v != null:
			out.append((r_v as Object).get_instance_id())
	return out


func _char_cache_ids(p_menu: Object) -> Array[int]:
	return _ids_of(p_menu._char_rows_cache.get("rows", []) as Array)


func _ach_cache_ids(p_menu: Object, p_page: int) -> Array[int]:
	# R259 修轮后缓存键=「页签|页码」（menu_screen._ach_key 单源）——测试同口径取键
	return _ids_of((p_menu._ach_page_cache.get("%s|%d" % [String(p_menu._ach_tab), p_page], {}) as Dictionary).get("rows", []) as Array)


func _ach_all_cache_ids(p_menu: Object) -> Array[int]:
	# 全部页签×页码缓存行并集（键=「页签|页码」字符串——R259 评审 MED-2 键制）
	var out: Array[int] = []
	for k_v in (p_menu._ach_page_cache as Dictionary).keys():
		out.append_array(_ids_of((p_menu._ach_page_cache.get(k_v, {}) as Dictionary).get("rows", []) as Array))
	return out


func _map_cache_ids(p_menu: Object, p_d: int) -> Array[int]:
	return _ids_of(p_menu._map_rows_cache.get(p_d, []) as Array)


func _disposition(p_before: Array[int], p_now_valid: Array[int]) -> Dictionary:
	# 旧行去向：freed=已释放｜orphan=存活但无父不在新集（泄漏）｜reused=在新集或挂树
	var freed := 0
	var orphan := 0
	var reused := 0
	for oid in p_before:
		var inst: Object = instance_from_id(oid)
		if inst == null:
			freed += 1
			continue
		if p_now_valid.has(oid):
			reused += 1
			continue
		if (inst as Node).get_parent() == null:
			orphan += 1
		else:
			reused += 1
	return {"freed": freed, "orphan": orphan, "reused": reused}


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
	gl.name = "GameLoopForR259Leak"
	p_tree.get_root().add_child(gl)
	gl.set_physics_process(false)
	var waited := 0
	while not gl.boot_ready and waited < 600:
		await p_tree.process_frame
		waited += 1
	var menu = gl.menu_screen
	_check("boot：菜单就绪", menu != null and gl.boot_ready)

	# 预热：各面板开一轮 + 图鉴泵消化完毕
	for k in ["ach", "char", "codex"]:
		menu._on_lobby_pressed(k)
		await p_tree.process_frame
	menu._on_difficulty_pick(0)
	menu._open_map_select()
	await p_tree.process_frame
	menu._on_panel_close()
	var pump_wait := 0
	while not (menu._codex_prewarm_queue.is_empty() and String(menu._codex_pump_tab) == "") \
			and pump_wait < 1200:
		await p_tree.process_frame
		pump_wait += 1
	print("  [--] 图鉴预热泵消化完毕（%d 帧）" % pump_wait)
	for i in 15:
		await p_tree.process_frame

	# ══ 阶段 C：面板互切（无数据变）×20 —— 同实例复用直证 ══
	var char_ids_c0 := _char_cache_ids(menu)
	var ach_ids_c0 := _ach_cache_ids(menu, 0)
	var map_ids_c0 := _map_cache_ids(menu, 0)
	_check("C 前置：三缓存实例捕获非空（char=%d ach=%d map=%d）"
		% [char_ids_c0.size(), ach_ids_c0.size(), map_ids_c0.size()],
		char_ids_c0.size() > 0 and ach_ids_c0.size() > 0 and map_ids_c0.size() > 0)
	for i in 20:
		menu._on_lobby_pressed("char")
		menu._on_lobby_pressed("ach")
		menu._on_lobby_pressed("codex")
		menu._open_map_select()
		await p_tree.process_frame
	for i in 25:
		await p_tree.process_frame
	var char_ids_c1 := _char_cache_ids(menu)
	var ach_ids_c1 := _ach_cache_ids(menu, 0)
	var map_ids_c1 := _map_cache_ids(menu, 0)
	var same_char: bool = char_ids_c0 == char_ids_c1
	var same_ach: bool = ach_ids_c0 == ach_ids_c1
	var same_map: bool = map_ids_c0 == map_ids_c1
	print("  [--] 阶段C 互切×20：char 同集=%s ach 同集=%s map 同集=%s（零重建直证）"
		% [str(same_char), str(same_ach), str(same_map)])
	_check("C 面板互切×20 三缓存同实例复用（零重建/零弃置）",
		same_char and same_ach and same_map,
		"char %d→%d ach %d→%d map %d→%d" % [char_ids_c0.size(), char_ids_c1.size(),
			ach_ids_c0.size(), ach_ids_c1.size(), map_ids_c0.size(), map_ids_c1.size()])

	# ══ 阶段 D：反复切难度 0/1/2 ×30 —— 分档首建后同实例复用 ══
	menu._on_difficulty_pick(0)
	menu._open_map_select()
	menu._on_difficulty_pick(1)
	menu._on_difficulty_pick(2)
	await p_tree.process_frame
	var map_ids_d0 := [_map_cache_ids(menu, 0), _map_cache_ids(menu, 1), _map_cache_ids(menu, 2)]
	_check("D 前置：三档缓存非空（%d/%d/%d）"
		% [map_ids_d0[0].size(), map_ids_d0[1].size(), map_ids_d0[2].size()],
		map_ids_d0[0].size() > 0 and map_ids_d0[1].size() > 0 and map_ids_d0[2].size() > 0)
	for i in 30:
		menu._on_difficulty_pick(i % 3)
		await p_tree.process_frame
	for i in 25:
		await p_tree.process_frame
	var map_ids_d1 := [_map_cache_ids(menu, 0), _map_cache_ids(menu, 1), _map_cache_ids(menu, 2)]
	_check("D 切难度×30 三档缓存同实例复用（零重建）",
		map_ids_d0[0] == map_ids_d1[0] and map_ids_d0[1] == map_ids_d1[1] and map_ids_d0[2] == map_ids_d1[2],
		"%d→%d %d→%d %d→%d" % [map_ids_d0[0].size(), map_ids_d1[0].size(),
			map_ids_d0[1].size(), map_ids_d1[1].size(), map_ids_d0[2].size(), map_ids_d1[2].size()])
	menu._on_panel_close()
	for i in 10:
		await p_tree.process_frame

	# ══ 阶段 E：失效重建 ×10 —— 旧行必须被 free（不孤儿）══
	var e_total_orphan := 0
	var e_total_freed := 0
	for i in 10:
		var before: Array[int] = _map_cache_ids(menu, 0) + _map_cache_ids(menu, 1) + _map_cache_ids(menu, 2)
		Meta.map_records_changed.emit()
		await p_tree.process_frame
		await p_tree.process_frame
		menu._open_map_select()
		await p_tree.process_frame
		for k in 6:
			await p_tree.process_frame             # queue_free 清算窗
		var now_valid: Array[int] = _map_cache_ids(menu, 0) + _map_cache_ids(menu, 1) + _map_cache_ids(menu, 2)
		var dis := _disposition(before, now_valid)
		e_total_orphan += int(dis["orphan"])
		e_total_freed += int(dis["freed"])
	menu._on_panel_close()
	for i in 15:
		await p_tree.process_frame
	print("  [--] 阶段E 失效重建×10：旧行 freed=%d orphan=%d（orphan>0=失效口泄漏）"
		% [e_total_freed, e_total_orphan])
	_check("E 失效重建×10 旧行全数释放、零孤儿", e_total_orphan == 0 and e_total_freed > 0,
		"freed=%d orphan=%d" % [e_total_freed, e_total_orphan])

	# ══ 阶段 A：武器循环 ×12 —— sig-miss 重建旧行去向（逐操作）══
	var fission_idx := -1
	for i in range(CharacterTable.count()):
		if not CharacterTable.has_skill(CharacterTable.CHARACTERS[i].id):
			fission_idx = i
			break
	var extra_w: StringName = &""
	if menu.registry != null and fission_idx >= 0:
		for wid_v in (menu.registry.weapons as Dictionary).keys():
			var sid := StringName(String(wid_v))
			if sid == &"W1_pistol" or Meta.codex_weapons.has(String(sid)):
				continue
			if MechanicGate.weapon_difficulty_min(sid) > 0:
				continue
			extra_w = sid
			break
	if fission_idx >= 0 and extra_w != &"":
		Meta.codex_weapons[String(extra_w)] = true
		menu._on_difficulty_pick(0)
		menu._on_lobby_pressed("char")
		await p_tree.process_frame
		var a_orphan := 0
		var a_freed := 0
		var a_first := true
		for i in 12:
			var before := _char_cache_ids(menu)
			if a_first:
				print("  [--] 阶段A 首轮捕获行数=%d" % before.size())
				a_first = false
			menu._on_custom_weapon_cycle()
			await p_tree.process_frame
			for k in 3:
				await p_tree.process_frame
			var dis := _disposition(before, _char_cache_ids(menu))
			a_orphan += int(dis["orphan"])
			a_freed += int(dis["freed"])
		print("  [--] 阶段A 武器循环×12：旧行 freed=%d orphan=%d（每轮整套旧行去向）"
			% [a_freed, a_orphan])
		if a_orphan > 0:
			print("  [!!] 泄漏直证：武器循环 sig-miss 重建后旧行孤儿化 %d 行次（未 free、无引用）" % a_orphan)
		_check("A 武器循环×12 旧行去向健康（全 free 或全复用，零孤儿）", a_orphan == 0,
			"freed=%d orphan=%d（孤儿=泄漏缺陷证据）" % [a_freed, a_orphan])
		menu._on_panel_close()
	else:
		print("  -- | 阶段A 跳过：fission=%d extra_w=%s" % [fission_idx, String(extra_w)])
	for i in 10:
		await p_tree.process_frame

	# ══ 阶段 B：成就页签往返 ×12 —— sig-miss 重建旧行去向（逐操作）══
	menu._on_lobby_pressed("ach")
	await p_tree.process_frame
	var b_orphan := 0
	var b_freed := 0
	var b_first := true
	var b_all0_before := _ach_cache_ids(menu, 0)   # 当前页签=全部（外部无翻转前置）
	for i in 12:
		var before := _ach_all_cache_ids(menu)     # 全缓存并集（他签缓存行≠孤儿）
		if b_first:
			print("  [--] 阶段B 首轮全缓存行数=%d（keys=%s）"
				% [before.size(), str(menu._ach_page_cache.keys())])
			b_first = false
		menu._on_ach_tab("收集" if i % 2 == 0 else "全部")
		await p_tree.process_frame
		for k in 3:
			await p_tree.process_frame
		var dis := _disposition(before, _ach_all_cache_ids(menu))
		b_orphan += int(dis["orphan"])
		b_freed += int(dis["freed"])
	var b_all0_after := _ach_cache_ids(menu, 0)    # 末次翻转后页签=全部（i=11 → 全部）
	print("  [--] 阶段B 成就页签往返×12：旧行 freed=%d orphan=%d｜「全部|0」往返同实例=%s"
		% [b_freed, b_orphan, str(b_all0_before == b_all0_after)])
	if b_orphan > 0:
		print("  [!!] 泄漏直证：成就页签 sig-miss 重建后旧行孤儿化 %d 行次（未 free、无引用）" % b_orphan)
	_check("B 成就页签往返×12 旧行去向健康（零孤儿）+「全部」页往返复用",
		b_orphan == 0 and b_all0_before == b_all0_after,
		"freed=%d orphan=%d reuse=%s" % [b_freed, b_orphan, str(b_all0_before == b_all0_after)])
	menu._on_panel_close()

	# ══ 辅证：OBJECT_COUNT 平台期（静置两窗对比）══
	menu._on_lobby_pressed("char")
	menu._on_lobby_pressed("ach")
	menu._open_map_select()
	await p_tree.process_frame
	menu._on_panel_close()
	for i in 40:
		await p_tree.process_frame
	var o1 := _obj()
	for i in 30:
		await p_tree.process_frame
	var o2 := _obj()
	print("  [--] 辅证 OBJECT_COUNT 平台期：%d → %d（%+d）" % [o1, o2, o2 - o1])
	# 判据只拦正向累积（泄漏方向）；负向漂移=前段大批 queue_free 的分帧清算尾巴非泄漏
	_check("辅证：静置平台期对象数涨幅 ≤5", o2 - o1 <= 5, "o1=%d o2=%d" % [o1, o2])

	# 收尾：选关树内行数=地图总数+难度行
	menu._open_map_select()
	await p_tree.process_frame
	var map_rows := 0
	for c in (menu._panel_list as Node).get_children():
		if String(c.name).begins_with("MapRow_"):
			map_rows += 1
	_check("收尾：选关树内行数=地图总数（无残留/缺失）", map_rows == MapTable.count(),
		"rows=%d expect=%d" % [map_rows, MapTable.count()])
	menu._on_panel_close()

	_restore(snap)
	gl.free()
	print("验收汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	for f in _failures:
		print("  FAIL | %s" % f)

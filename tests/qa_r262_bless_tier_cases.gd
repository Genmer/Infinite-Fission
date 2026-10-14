extends RefCounted
# R262 祝福全档开放批 cases（配套口 qa_r262_bless_tier.gd；R263 送武/收费后口径）。
# T1 池扩（全池 62={白6,蓝24,紫26,金6}+池净度+确定性——R263 送武 24 项全在池）
# T2 首发适配门三态（W1 手枪臂：AFF_CDR/AFF_RANGE 仍缺席+MEC_PARALLEL_CAL 在池
#    +武器绑定五项经送武上池+分档探针==rarity 子集+fission custom W13 臂）
# T3 默认签=当前难度档  T4 默认档缺席回退  T5 品级签切换+同值早退
# T6 预选跨档跳签  T7 记忆键适配拒挂（R263 载靶 AFF_CDR·对照正常挂载）  T8 跨档记忆生效
# T9 池空退化  T10 行色随行品级  T11 副标题  T12 每日隔离回归
# R263 星尘 fixture：挂载/预选用例预置余额（快照还原）——收费面余额不足即拒挂/不预选。
# 静态期望值注释「W1 首发静态推算，实跑校准」——偏差以实跑为准回填，禁止凑值放宽。

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


func _goto_menu(p_gl) -> void:
	# 清场回菜单（r252 同款口径）：词条随 quit_to_menu/_reset_run_state 清场，
	# 直改 state 绕过清场会让上一局挂载残留进下一局计数
	if p_gl.state == GameConst.GameStatus.MENU:
		return
	p_gl.state = GameConst.GameStatus.PAUSED
	p_gl.quit_to_menu()


func _trait_layers_total(p_gl, p_tid: StringName) -> int:
	var n := 0
	for w_v: Variant in p_gl.player.weapon_slots:
		var w := w_v as WeaponBase
		if w == null or not is_instance_valid(w) or w.trait_stack == null:
			continue
		for m in w.trait_stack.traits:
			if m.data != null and m.data.id == p_tid:
				n += int(m.layers)
	return n


func _start_normal_run(p_gl) -> void:
	_goto_menu(p_gl)
	p_gl._difficulty = 0
	p_gl.current_map_id = MapTable.FIRST_MAP_ID
	p_gl.start_run()


func run(p_tree: SceneTree) -> void:
	var gl_script: GDScript = load("res://scripts/loop/game_loop.gd")
	var gl = gl_script.new()
	gl.name = "GameLoopForR262BlessTier"
	p_tree.get_root().add_child(gl)
	gl.set_physics_process(false)
	var waited := 0
	while not gl.boot_ready and waited < 600:
		await p_tree.process_frame
		waited += 1
	var ui = gl.blessing_pick_ui
	_check("boot：菜单就绪", gl.boot_ready and ui != null)

	# ── 快照（收尾精确还原；R263 星尘入快照+fixture）──
	var codex_snapshot: Dictionary = Meta.codex_traits.duplicate()
	var mem_saved: String = Meta.blessing_trait_id
	var char_saved: StringName = Meta.character_id
	var cw_saved: String = Meta.custom_weapon_id
	var sd_saved: int = Meta.stardust
	var sdt_saved: int = Meta.stardust_total
	var diff_saved: int = gl._difficulty
	Meta.stardust = 1000                            # R263 fixture：挂载（T7 对照/T8）与预选（T6）按价收费

	# ══ T1 池扩：全解锁手枪首发全池 ==62={白6,蓝24,紫26,金6} ══
	for tid_v: Variant in gl.registry.traits.keys():
		Meta.codex_traits[String(tid_v)] = true
	var pool_all: Array[StringName] = gl._blessing_pool()
	var n_r0 := 0
	var n_r1 := 0
	var n_r2 := 0
	var n_r3 := 0
	for tid in pool_all:
		var td: TraitData = gl.registry.get_trait(tid)
		if td == null:
			continue
		match int(td.rarity):
			0: n_r0 += 1
			1: n_r1 += 1
			2: n_r2 += 1
			3: n_r3 += 1
	_check("T1 池扩：全池==62 且四档各至少 1（静态 {6,24,26,6} 实跑校准）",
		pool_all.size() == 62 and n_r0 >= 1 and n_r1 >= 1 and n_r2 >= 1 and n_r3 >= 1,
		"size=%d %d/%d/%d/%d" % [pool_all.size(), n_r0, n_r1, n_r2, n_r3])
	var no_bad := true
	for tid_v2: Variant in gl.registry.traits.keys():
		var tid_s := String(tid_v2)
		var td_b: TraitData = gl.registry.get_trait(StringName(tid_s))
		if td_b == null:
			continue
		var in_pool := pool_all.has(StringName(tid_s))
		var locked := not bool(Meta.codex_traits.get(tid_s, false))
		if in_pool and (bool(td_b.params.get("threshold_only", false))
				or String(td_b.params.get("requires_trait", "")) != "" or locked):
			no_bad = false
	_check("T1 池净度：无 TH_*、无 requires_trait、无未解锁项", no_bad)
	var pool_again: Array[StringName] = gl._blessing_pool()
	var keys_all: Array[String] = []
	for t in pool_all:
		keys_all.append(String(t))
	var keys_sorted: Array[String] = keys_all.duplicate()
	keys_sorted.sort()
	_check("T1 确定性：两次调用逐位相等+id 字典序", pool_all == pool_again and keys_all == keys_sorted)

	# ══ T2 首发适配门三态（W1 手枪 form=0）══
	# R263 迁移：武器绑定项（巨刃/环绕斧/弹反刀意）不适配但送得出 → 经附赠通道上池；
	# 纯形态失配哨兵 AFF_CDR/AFF_RANGE 维持缺席。
	var absent_ids: Array[StringName] = [&"AFF_CDR", &"AFF_RANGE"]
	var absent_ok := true
	for bad in absent_ids:
		if pool_all.has(bad):
			absent_ok = false
	_check("T2 适配门：池不含纯形态失配 AFF_CDR/AFF_RANGE（三态第三态哨兵）",
		absent_ok, "hit=%s" % str(absent_ids.filter(func(x: StringName) -> bool: return pool_all.has(x))))
	var gift_ids: Array[StringName] = [&"MEC_GIANT_BLADE", &"MEC_ORBIT_AXE", &"MEC_BULLET_PARRY"]
	var gift_ok := true
	for gid in gift_ids:
		if not pool_all.has(gid):
			gift_ok = false
	_check("T2 送武通道：巨刃/环绕斧/弹反刀意经附赠通道上池",
		gift_ok, "miss=%s" % str(gift_ids.filter(func(x: StringName) -> bool: return not pool_all.has(x))))
	_check("T2 适配门：含 MEC_PARALLEL_CAL（W1_pistol.tres:82 lateral_gap_levels 实有）",
		pool_all.has(&"MEC_PARALLEL_CAL"))
	var probe_ok := true
	for tier in range(4):
		var probe: Array[StringName] = gl._blessing_pool(tier)
		var sub: Array[StringName] = []
		for tid_p in pool_all:
			var td_p: TraitData = gl.registry.get_trait(tid_p)
			if td_p != null and int(td_p.rarity) == tier:
				sub.append(tid_p)
		if probe != sub:
			probe_ok = false
	_check("T2 分档探针：_blessing_pool(t)==全池 rarity t 子集（t=0..3 逐项）", probe_ok)
	# fission custom 臂：_difficulty=2（W13 难度门=2 地狱起，game_loop._starting_weapon_id
	# 门过回落不触发）→ character_id=fission + custom_weapon=W13_great_sword
	gl._difficulty = 2
	Meta.character_id = &"fission"
	Meta.custom_weapon_id = "W13_great_sword"
	var pool_fission: Array[StringName] = gl._blessing_pool()
	var bind_ids: Array[StringName] = [&"MEC_MIRROR_SPLIT", &"MEC_MIRROR_LOCK", &"MEC_MIRROR_TEMPO",
		&"MEC_MIRROR_WEIGHT", &"MEC_FUSE_COAT", &"MEC_HIVE_RACK", &"MEC_FUSE_DETONATE", &"MEC_THROW_RANGE"]
	var bind_ok := true
	for bid in bind_ids:
		if not pool_fission.has(bid):
			bind_ok = false
	_check("T2-fission custom 臂：W13 阔剑首发（地狱门过）→ 池含 MEC_GIANT_BLADE（直接适配）",
		pool_fission.has(&"MEC_GIANT_BLADE"))
	# R263 迁移：W13 首发下 W5/W6/W7/W10 绑定项不适配但送得出 → 送武上池
	#（原「缺席」断言随三态化反转——池算术 62=38 适配+24 送武；2 形态出局同源）
	_check("T2-fission custom 臂：W5/W6/W7/W10 绑定八项经送武通道上池", bind_ok,
		"miss=%s" % str(bind_ids.filter(func(x: StringName) -> bool: return not pool_fission.has(x))))
	# fission 臂还原
	Meta.character_id = char_saved
	Meta.custom_weapon_id = cw_saved
	gl._difficulty = diff_saved

	# ══ T3 默认签=当前难度档 ══
	ui.open(pool_all, "", 2)
	await p_tree.process_frame
	_check("T3 默认签：difficulty2 → _filter_rarity==3（金）", ui._filter_rarity == 3,
		"filter=%d" % ui._filter_rarity)
	var rows_gold_ok := true
	for c in ui._list_box.get_children():
		var td_g: TraitData = gl.registry.get_trait(
			StringName(String((c as Button).get_meta(&"trait_id"))))
		if td_g == null or int(td_g.rarity) != 3:
			rows_gold_ok = false
	_check("T3 默认签：当页行全金档（行数=%d·金档 6 项单页）" % ui._list_box.get_child_count(),
		rows_gold_ok and ui._list_box.get_child_count() == 6,
		"rows=%d" % ui._list_box.get_child_count())
	ui.close()
	ui.open(pool_all, "", 0)
	await p_tree.process_frame
	_check("T3 默认签：difficulty0 → _filter_rarity==1（蓝）", ui._filter_rarity == 1,
		"filter=%d" % ui._filter_rarity)

	# ══ T4 默认档缺席回退 ══
	var pool_no_gold: Array[StringName] = []
	for tid_ng in pool_all:
		var td_ng: TraitData = gl.registry.get_trait(tid_ng)
		if td_ng != null and int(td_ng.rarity) != 3:
			pool_no_gold.append(tid_ng)
	ui.close()
	ui.open(pool_no_gold, "", 2)
	await p_tree.process_frame
	_check("T4 默认档缺席回退：无金档子池×difficulty2 → 回退全部（-1）+列表非空",
		ui._filter_rarity == -1 and ui._list_box.get_child_count() > 0,
		"filter=%d rows=%d" % [ui._filter_rarity, ui._list_box.get_child_count()])

	# ══ T5 品级签切换 + 同值早退 ══
	ui.close()
	ui.open(pool_all, "", 0)                       # 默认蓝签
	await p_tree.process_frame
	ui._on_filter_pick(0)                          # 白签（6 项单页）
	await p_tree.process_frame
	var rows_white_ok := true
	for cw in ui._list_box.get_children():
		var td_w: TraitData = gl.registry.get_trait(
			StringName(String((cw as Button).get_meta(&"trait_id"))))
		if td_w == null or int(td_w.rarity) != 0:
			rows_white_ok = false
	var white_row0: Node = ui._list_box.get_child(0)
	ui._on_filter_pick(0)                          # 同值早退（同步零重建）
	_check("T5 品级签：白签行全白档+页回 0+同值早退零重建",
		rows_white_ok and ui._page == 0 and ui._list_box.get_child(0) == white_row0,
		"all_white=%s page=%d same=%s" % [str(rows_white_ok), ui._page,
			str(ui._list_box.get_child(0) == white_row0)])
	ui._on_filter_pick(2)                          # 紫签（26 项 4 页）
	await p_tree.process_frame
	var rows_purple_ok := true
	for cp in ui._list_box.get_children():
		var td_pu: TraitData = gl.registry.get_trait(
			StringName(String((cp as Button).get_meta(&"trait_id"))))
		if td_pu == null or int(td_pu.rarity) != 2:
			rows_purple_ok = false
	_check("T5 品级签：紫签行全紫档", rows_purple_ok)

	# ══ T6 预选跨档跳签 ══
	var purple_id := ""
	for tid_pu2 in pool_all:
		var td_pu2: TraitData = gl.registry.get_trait(tid_pu2)
		if td_pu2 != null and int(td_pu2.rarity) == 2:
			purple_id = String(tid_pu2)            # 紫档字典序首项 AFF_MULTI（实查）
			break
	ui.close()
	ui.open(pool_all, purple_id, 0)                # 默认蓝签 + 预选紫项
	await p_tree.process_frame
	var sel_btn: Button = ui._row_by_id(purple_id)
	_check("T6 预选跨档跳签：默认蓝签+预选紫项 → 跳紫签+页+选中可见",
		ui._filter_rarity == 2 and sel_btn != null and sel_btn.button_pressed,
		"filter=%d page=%d sel=%s" % [ui._filter_rarity, ui._page, str(sel_btn != null)])
	_check("T6 摘要行：含「已选：」感知锚", ui._sel_summary.text.contains("已选："),
		"summary=%s" % ui._sel_summary.text)

	# ══ T10 行色随行品级 ══
	ui.close()
	ui.open(pool_all, "", 0)
	await p_tree.process_frame
	var row_blue: Button = ui._list_box.get_child(0)
	_check("T10 行色：蓝签行 font_pressed_color==rarity_color(1)",
		(row_blue.get_theme_color("font_pressed_color")).is_equal_approx(PopPalette.rarity_color(1)))
	ui._on_filter_pick(0)
	await p_tree.process_frame
	var row_white: Button = ui._list_box.get_child(0)
	_check("T10 行色：白签行 font_pressed_color==rarity_color(0)",
		(row_white.get_theme_color("font_pressed_color")).is_equal_approx(PopPalette.rarity_color(0)))
	ui.close()

	# ══ T11 副标题 ══
	ui.open(pool_all, "", 2)
	await p_tree.process_frame
	var sub11: String = ui._subtitle.text
	_check("T11 副标题：含难度名+「全档可选」、不含「跨难度出战不生效」",
		sub11.contains(GameConst.difficulty_name(2)) and sub11.contains("全档可选")
			and not sub11.contains("跨难度出战不生效"), sub11)
	ui.close()

	# ══ T7 记忆键适配拒挂（R263 载靶迁移：AFF_CDR × 手枪局）══
	# 原靶 MEC_GIANT_BLADE（绑 W8-W13）走送武通道会送 W8 挂载成功——拒挂语义反转
	#（送武成功断言移入 qa_r263_gift G10）；改靶 AFF_CDR（纯形态失配·三态第三态哨兵）。
	Meta.set_blessing_trait(&"AFF_CDR")
	_start_normal_run(gl)
	var layers_giant := _trait_layers_total(gl, &"AFF_CDR")
	_check("T7 适配拒挂：AFF_CDR 记忆×手枪局=零挂载", layers_giant == 0, "layers=%d" % layers_giant)
	_check("T7 拒挂披露：横幅含「与当前首发武器不适配」",
		"".join(gl._run_intro_lines).contains("与当前首发武器不适配"),
		str(gl._run_intro_lines))
	# 对照：AFF_CRIT_DMG 正常挂载恰 1 层（R263 fixture 余额下照扣 20）
	var sd_t7: int = Meta.stardust
	Meta.set_blessing_trait(&"AFF_CRIT_DMG")
	_start_normal_run(gl)
	var layers_crit := _trait_layers_total(gl, &"AFF_CRIT_DMG")
	_check("T7 对照：AFF_CRIT_DMG×手枪局=正常挂载恰 1 层+扣费 -20（R263 收费面）",
		layers_crit == 1 and Meta.stardust == sd_t7 - 20,
		"layers=%d sd=%d→%d" % [layers_crit, sd_t7, Meta.stardust])

	# ══ T8 跨档记忆生效（SYN_FIRST_STRIKE 金档 × 普通局）══
	var sd_t8: int = Meta.stardust
	Meta.set_blessing_trait(&"SYN_FIRST_STRIKE")
	_start_normal_run(gl)
	var layers_syn := _trait_layers_total(gl, &"SYN_FIRST_STRIKE")
	_check("T8 跨档记忆生效：金档 SYN_FIRST_STRIKE×普通局=挂载恰 1 层+扣费 -50（R263）",
		layers_syn == 1 and Meta.stardust == sd_t8 - 50,
		"layers=%d sd=%d→%d" % [layers_syn, sd_t8, Meta.stardust])

	# ══ T12 每日隔离回归 ══
	Meta.set_blessing_trait(&"AFF_CRIT_DMG")
	_goto_menu(gl)
	gl._difficulty = 0
	gl.current_map_id = MapTable.FIRST_MAP_ID
	gl.start_run(20261012)                          # 每日种子（挂载层守卫 _active_daily_seed>=0 自拒）
	var layers_daily := _trait_layers_total(gl, &"AFF_CRIT_DMG")
	_check("T12 每日隔离：start_run(20261012)=零挂载", layers_daily == 0, "layers=%d" % layers_daily)

	# ══ T9 池空退化（空图鉴）══
	_goto_menu(gl)
	Meta.blessing_trait_id = ""
	Meta.codex_traits.clear()
	var pool_empty: Array[StringName] = gl._blessing_pool()
	var opened_empty: bool = gl._try_open_blessing_pick()
	_check("T9 池空退化：空图鉴全池空+面板不弹直达战斗",
		pool_empty.is_empty() and opened_empty == false and not ui.is_open(),
		"pool=%d opened=%s" % [pool_empty.size(), str(opened_empty)])

	# ── 收尾精确还原 ──
	Meta.codex_traits.clear()
	for k_v: Variant in codex_snapshot.keys():
		Meta.codex_traits[String(k_v)] = true
	Meta.blessing_trait_id = mem_saved
	Meta.character_id = char_saved
	Meta.custom_weapon_id = cw_saved
	Meta.stardust = sd_saved                     # R263：星尘 fixture 还原
	Meta.stardust_total = sdt_saved
	gl._difficulty = diff_saved
	Meta._save()
	ui.close()
	gl.free()
	print("验收汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	for f in _failures:
		print("  FAIL | %s" % f)


func fail_count() -> int:
	return _fail

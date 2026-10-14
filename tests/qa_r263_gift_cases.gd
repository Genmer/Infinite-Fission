extends RefCounted
# R263 祝福送武器批 cases（配套口 qa_r263_gift.gd；设计 §6 G1-G12）。
# G1 池构成 62={6,24,26,6}  G2 映射规则 24 行（解析器单源零改动）
# G3 装备链（slot1 送武+横幅）  G4 首发恰=绑定武器（不送只挂照扣）
# G5 fits 优先  G6 重开重送不重复扣费  G7 每日四场景零送零挂零扣
# G8 图鉴首送入册+幂等+不增抽卡计数  G9 serialize→continue 恢复无二次扣
# G10 双门开例+局内门对照  G11 echo 无槽拒送/有槽落 slot2
# G12 RNG 纪律（全局流+双局部流）
# 测试卫生：开套件快照内存+档字节，收尾原样还原（r252 惯例）；套件恒置电池末位。
var _pass := 0
var _fail := 0
var _failures: Array[String] = []

# Meta 快照（套件隔离）
var _snap_codex_traits: Dictionary = {}
var _snap_codex_weapons: Dictionary = {}
var _snap_unlocked_chars: Dictionary = {}
var _snap_blessing: String = ""
var _snap_character: StringName = &""
var _snap_custom_weapon: String = ""
var _snap_stardust: int = 0
var _snap_stardust_total: int = 0
var _snap_difficulty: int = 0
var _had_save: bool = false
var _save_text: String = ""


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("  ok | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s %s" % [p_name, p_detail])
		print("  FAIL | %s %s" % [p_name, p_detail])


func _goto_menu(p_gl) -> void:
	# 清场回菜单（r252 同款口径）：词条随 quit_to_menu/_reset_run_state 清场
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


func _slot_wid(p_gl, p_i: int) -> StringName:
	if p_i >= p_gl.player.weapon_slots.size():
		return StringName("")
	var w: WeaponBase = p_gl.player.weapon_slots[p_i] if p_i < p_gl.player.weapon_slots.size() else null
	if w == null or not is_instance_valid(w) or w.data == null:
		return StringName("")
	return StringName(String(w.data.id))


func _count_weapon(p_gl, p_wid: StringName) -> int:
	var n := 0
	for w_v: Variant in p_gl.player.weapon_slots:
		var w := w_v as WeaponBase
		if w != null and is_instance_valid(w) and w.data != null \
				and StringName(String(w.data.id)) == p_wid:
			n += 1
	return n


func _start_normal(p_gl, p_difficulty: int = 0) -> void:
	_goto_menu(p_gl)
	p_gl._difficulty = p_difficulty
	p_gl.current_map_id = MapTable.FIRST_MAP_ID
	p_gl.start_run()


func run(p_tree: SceneTree) -> void:
	var gl_script: GDScript = load("res://scripts/loop/game_loop.gd")
	var gl = gl_script.new()
	gl.name = "GameLoopForR263Gift"
	p_tree.get_root().add_child(gl)
	gl.set_physics_process(false)
	var waited := 0
	while not gl.boot_ready and waited < 600:
		await p_tree.process_frame
		waited += 1
	_check("boot：菜单就绪", gl.boot_ready)
	if not gl.boot_ready:
		_summary()
		return
	_snap()
	_unlock_all_traits(gl)

	# ══ G1 池构成：62={白6,蓝24,紫26,金6} ══
	Meta.character_id = &"sentinel"
	Meta.custom_weapon_id = ""
	gl._difficulty = 0
	var pool_all: Array[StringName] = gl._blessing_pool()
	var tiers := [0, 0, 0, 0]
	for tid in pool_all:
		var td: TraitData = gl.registry.get_trait(tid)
		if td != null:
			tiers[int(td.rarity)] += 1
	_check("G1 池构成：全池==62 且分档 {6,24,26,6}",
		pool_all.size() == 62 and tiers[0] == 6 and tiers[1] == 24 and tiers[2] == 26 and tiers[3] == 6,
		"size=%d %d/%d/%d/%d" % [pool_all.size(), tiers[0], tiers[1], tiers[2], tiers[3]])
	# 24 条武器绑定词条（required_weapon/required_class）全部经附赠通道上池
	#（含近战队 9 条——难度门/大关门对送通道开例）；收集仍数据驱动零硬编码。
	var bound: Array[StringName] = []
	for tid_v: Variant in gl.registry.traits.keys():
		var td_b: TraitData = gl.registry.get_trait(StringName(String(tid_v)))
		if td_b == null:
			continue
		if td_b.params.has("required_weapon") or td_b.params.has("required_class"):
			bound.append(StringName(String(tid_v)))
	var bound_miss: Array[String] = []
	for bid in bound:
		if not pool_all.has(bid):
			bound_miss.append(String(bid))
	_check("G1 武器绑定全上池：24 条 required_weapon/required_class 词条均在池",
		bound.size() == 24 and bound_miss.is_empty(),
		"bound=%d miss=%s" % [bound.size(), str(bound_miss)])
	# 三态第三态哨兵：纯形态失配（无绑定键）维持出局；TH_*/requires_trait 同滤
	var sentinels: Array[StringName] = [&"AFF_RANGE", &"AFF_CDR"]
	var sent_out := true
	for sid in sentinels:
		if pool_all.has(sid):
			sent_out = false
	_check("G1 形态类出局：AFF_RANGE/AFF_CDR（纯 required_forms 失配无绑定键）不上池",
		sent_out and not pool_all.has(&"MEC_RICOCHET_HALL") and not pool_all.has(&"SYN_BOUNCE_SPEC"))

	# ══ G2 映射规则（blessing_gift_weapon 单源·24 行确定性） ══
	var mapping: Array = [
		[&"MEC_GIANT_BLADE", &"W8_orbit_field"], [&"MEC_ORBIT_LINK", &"W8_orbit_field"],
		[&"MEC_CHAIN_DETONATE", &"W8_orbit_field"], [&"MEC_CRITICAL_MASS", &"W8_orbit_field"],
		[&"MEC_ORBIT_AXE", &"W8_orbit_field"], [&"MEC_ORBIT_BOLT", &"W8_orbit_field"],
		[&"MEC_ORBIT_SWORD", &"W8_orbit_field"], [&"MEC_BULLET_PARRY", &"W8_orbit_field"],
		[&"MEC_SLASH_TEMPO", &"W9_arc_slash"],
		[&"MEC_BEAM_COFOCUS", &"W4_pulse_beam"], [&"MEC_BEAM_FAN", &"W4_pulse_beam"],
		[&"MEC_BEAM_LAG", &"W4_pulse_beam"], [&"MEC_BEAM_SPECTRA", &"W4_pulse_beam"],
		[&"MEC_BEAM_TRACK", &"W4_pulse_beam"], [&"MEC_PHASE_SYNC", &"W4_pulse_beam"],
		[&"MEC_SPLIT_PRISM", &"W4_pulse_beam"],
		[&"MEC_MIRROR_LOCK", &"W5_prism"], [&"MEC_MIRROR_SPLIT", &"W5_prism"],
		[&"MEC_MIRROR_TEMPO", &"W5_prism"], [&"MEC_MIRROR_WEIGHT", &"W5_prism"],
		[&"MEC_FUSE_COAT", &"W6_micro_missile"], [&"MEC_HIVE_RACK", &"W6_micro_missile"],
		[&"MEC_FUSE_DETONATE", &"W7_cluster_rocket"],
		[&"MEC_THROW_RANGE", &"W10_boomerang"],
	]
	var map_ok := true
	var map_detail := ""
	for row in mapping:
		var td_m: TraitData = gl.registry.get_trait(row[0])
		var got := MechanicGate.blessing_gift_weapon(td_m, gl.registry.weapons)
		if got != row[1]:
			map_ok = false
			map_detail = "%s→%s（期望 %s）" % [String(row[0]), String(got), String(row[1])]
			break
	_check("G2 映射规则：24 行逐条（难度门最小→大关最早→id 字典序；环绕族/巨刃/弹反→W8）",
		map_ok, map_detail)
	var td_determ: TraitData = gl.registry.get_trait(&"MEC_GIANT_BLADE")
	var det1 := MechanicGate.blessing_gift_weapon(td_determ, gl.registry.weapons)
	var det2 := MechanicGate.blessing_gift_weapon(td_determ, gl.registry.weapons)
	var td_none: TraitData = gl.registry.get_trait(&"AFF_CDR")
	_check("G2 确定性+纯形态空串：同词条两次同果；AFF_CDR 送不出（空）",
		det1 == det2 and det1 == &"W8_orbit_field"
			and MechanicGate.blessing_gift_weapon(td_none, gl.registry.weapons) == StringName(""))

	# ══ G3 装备链：环绕·裂空剑（紫 30·绑 W8）记忆×普通第 1 关 → slot1 送 W8 ══
	Meta.stardust = 200
	Meta.set_blessing_trait(&"MEC_ORBIT_SWORD")
	Meta.codex_weapons.erase("W8_orbit_field")            # G8 前置：W8 图鉴未入册
	var drawn0: int = int(Meta.get("_run_weapons_drawn"))
	var sd0: int = Meta.stardust
	_start_normal(gl, 0)
	_check("G3 装备链：slot0=手枪不动 + slot1=W8（附赠）",
		_slot_wid(gl, 0) == &"W1_pistol" and _slot_wid(gl, 1) == &"W8_orbit_field",
		"s0=%s s1=%s" % [String(_slot_wid(gl, 0)), String(_slot_wid(gl, 1))])
	_check("G3 挂载：W8 上词条恰 1 份（全槽合计 1）", _trait_layers_total(gl, &"MEC_ORBIT_SWORD") == 1,
		"layers=%d" % _trait_layers_total(gl, &"MEC_ORBIT_SWORD"))
	var g3_banner := "".join(gl._run_intro_lines)
	_check("G3 横幅：含「附赠」+武器名+「-30 星尘」",
		g3_banner.contains("附赠") and g3_banner.contains("天狼刀") and g3_banner.contains("-30 星尘"),
		str(gl._run_intro_lines))
	_check("G3 扣费：余额 200-30=170", Meta.stardust == sd0 - 30, "%d→%d" % [sd0, Meta.stardust])

	# ══ G8 图鉴：首送入册 + 抽卡计数不增（白拿口径） ══
	_check("G8 图鉴：W8 首送入册（mark_weapon_codex）", Meta.codex_weapons.has("W8_orbit_field"))
	_check("G8 白拿口径：_run_weapons_drawn 不增（军火大亨不受扰）",
		int(Meta.get("_run_weapons_drawn")) == drawn0,
		"%d → %d" % [drawn0, int(Meta.get("_run_weapons_drawn"))])

	# ══ G10 双门开例 + 局内门对照（普通第 1 关×巨刃）══
	var sd_g10: int = Meta.stardust
	Meta.set_blessing_trait(&"MEC_GIANT_BLADE")
	_start_normal(gl, 0)
	_check("G10 双门开例：巨刃×普通第 1 关送 W8（大关 3/难度 1 双门均开例）",
		_slot_wid(gl, 1) == &"W8_orbit_field" and _count_weapon(gl, &"W8_orbit_field") == 1,
		"s1=%s" % String(_slot_wid(gl, 1)))
	_check("G10 局内门对照：同局 weapon_allowed(W8)==false（卡池/echo 门零改动）",
		not MechanicGate.weapon_allowed(&"W8_orbit_field"))
	_check("G10 扣费：巨刃紫档 -30", Meta.stardust == sd_g10 - 30,
		"%d→%d" % [sd_g10, Meta.stardust])

	# ══ G6 重开：重送重挂不重复扣费 ══
	Meta.set_blessing_trait(&"MEC_ORBIT_SWORD")           # 同 G3 主靶
	_start_normal(gl, 0)
	var sd_pre_restart: int = Meta.stardust
	var drawn_pre: int = int(Meta.get("_run_weapons_drawn"))
	gl.state = GameConst.GameStatus.GAME_OVER
	var reopened: bool = gl.restart_run()
	_check("G6 重开：slot1 重装 W8 + 词条恰 1 份（无双叠）",
		reopened and _slot_wid(gl, 1) == &"W8_orbit_field"
			and _trait_layers_total(gl, &"MEC_ORBIT_SWORD") == 1,
		"reopened=%s s1=%s layers=%d" % [str(reopened), String(_slot_wid(gl, 1)),
			_trait_layers_total(gl, &"MEC_ORBIT_SWORD")])
	_check("G6 不重复扣费：重开余额不变", Meta.stardust == sd_pre_restart,
		"%d→%d" % [sd_pre_restart, Meta.stardust])
	_check("G6 图鉴幂等：重开 codex_weapons 尺寸不变（mark 二次 false）",
		Meta.codex_weapons.has("W8_orbit_field")
			and int(Meta.get("_run_weapons_drawn")) == drawn_pre)

	# ══ G9 存档：serialize→continue 恢复无二次扣 ══
	var sd_pre_cont: int = Meta.stardust
	RunSave.save_run(gl.serialize_run())
	_goto_menu(gl)
	var resumed: bool = gl.continue_run()
	_check("G9 续局：槽/词条恢复（slot1=W8 恰 1 份）+ 余额无二次扣减",
		resumed and _slot_wid(gl, 1) == &"W8_orbit_field"
			and _trait_layers_total(gl, &"MEC_ORBIT_SWORD") == 1
			and Meta.stardust == sd_pre_cont,
		"resumed=%s s1=%s sd=%d→%d" % [str(resumed), String(_slot_wid(gl, 1)), sd_pre_cont, Meta.stardust])

	# ══ G9b 跨进程：新实例 continue→死亡重开——已购位随档恢复（修轮评审-1）══
	# 复现链：购买局（paid=true）→ 暂停退出落档（serialize 含 blessing_paid 键）→
	# 「杀进程重进」=新建 GameLoop 实例（_run_blessing_paid 起点 false）→ 继续 →
	# 死亡重开：paid 随档恢复 true → 附赠武器+词条重挂 + 不重复扣费（修前=静默蒸发）。
	RunSave.save_run(gl.serialize_run())
	var gl2 = gl_script.new()
	gl2.name = "GameLoopForR263CrossProc"
	p_tree.get_root().add_child(gl2)
	gl2.set_physics_process(false)
	var g9b_wait := 0
	while not gl2.boot_ready and g9b_wait < 600:
		await p_tree.process_frame
		g9b_wait += 1
	var sd_xproc: int = Meta.stardust
	var resumed2: bool = gl2.continue_run()
	gl2.state = GameConst.GameStatus.GAME_OVER
	var xrestart: bool = gl2.restart_run()
	_check("G9b 跨进程：新实例 continue→重开=重送 W8+重挂词条+零重复扣费（已购位随档）",
		resumed2 and xrestart and gl2.boot_ready
			and _slot_wid(gl2, 1) == &"W8_orbit_field"
			and _trait_layers_total(gl2, &"MEC_ORBIT_SWORD") == 1
			and Meta.stardust == sd_xproc,
		"resumed=%s restart=%s s1=%s sd=%d→%d" % [str(resumed2), str(xrestart),
			String(_slot_wid(gl2, 1)), sd_xproc, Meta.stardust])
	RunSave.clear()
	gl2.free()

	# ══ G4 首发恰=绑定武器：fission 自定义 W8（困难）→ 不送只挂照扣 ══
	Meta.character_id = &"fission"
	Meta.custom_weapon_id = "W8_orbit_field"
	Meta.set_blessing_trait(&"MEC_ORBIT_SWORD")
	var sd_g4: int = Meta.stardust
	_start_normal(gl, 1)
	_check("G4 首发即绑定：槽内 W8 恰 1 把（不送重复）+ slot0 挂载",
		_count_weapon(gl, &"W8_orbit_field") == 1 and _slot_wid(gl, 0) == &"W8_orbit_field"
			and _trait_layers_total(gl, &"MEC_ORBIT_SWORD") == 1,
		"w8=%d s0=%s" % [_count_weapon(gl, &"W8_orbit_field"), String(_slot_wid(gl, 0))])
	_check("G4 照扣费：紫档 -30（不送也收费——挂载即商品）", Meta.stardust == sd_g4 - 30,
		"%d→%d" % [sd_g4, Meta.stardust])
	_check("G4 横幅无附赠段：走挂载路径",
		not "".join(gl._run_intro_lines).contains("附赠"), str(gl._run_intro_lines))

	# ══ G5 fits 优先：激光词条+fission 首发W4 → 不进送武分支 ══
	Meta.custom_weapon_id = "W4_pulse_beam"
	Meta.set_blessing_trait(&"MEC_BEAM_FAN")            # 紫 30·required_weapon=W4
	var sd_g5: int = Meta.stardust
	_start_normal(gl, 0)
	var g5_wcount := 0
	for w_v: Variant in gl.player.weapon_slots:
		if w_v != null and is_instance_valid(w_v):
			g5_wcount += 1
	_check("G5 fits 优先：W4 首发适配 → 武器数不增（无附赠）+ slot0 挂载 + 照扣 30",
		g5_wcount == 1 and _trait_layers_total(gl, &"MEC_BEAM_FAN") == 1
			and Meta.stardust == sd_g5 - 30,
		"w=%d layers=%d sd=%d→%d" % [g5_wcount, _trait_layers_total(gl, &"MEC_BEAM_FAN"), sd_g5, Meta.stardust])
	Meta.character_id = &"sentinel"
	Meta.custom_weapon_id = ""

	# ══ G7 每日四场景：零送零挂零扣 ══
	Meta.set_blessing_trait(&"MEC_ORBIT_SWORD")
	var sd_g7: int = Meta.stardust
	_goto_menu(gl)
	gl._difficulty = 0
	gl.current_map_id = MapTable.FIRST_MAP_ID
	gl.start_run(20261012)                               # b) 直调种子
	var g7_layers := _trait_layers_total(gl, &"MEC_ORBIT_SWORD")
	gl.state = GameConst.GameStatus.GAME_OVER
	gl.restart_run()                                     # c) 每日死亡重开
	_check("G7 每日隔离：直调种子/重开全程零挂载零扣费",
		g7_layers == 0 and _trait_layers_total(gl, &"MEC_ORBIT_SWORD") == 0
			and _count_weapon(gl, &"W8_orbit_field") == 0
			and Meta.stardust == sd_g7,
		"layers=%d sd=%d→%d" % [g7_layers, sd_g7, Meta.stardust])

	# ══ G11 echo：普通无槽拒送 / 困难落 slot2 ══
	# 前置：echo 解锁 = hard_cleared()（map_records 困难分档通关派生——写一条即过；
	# 探针 probe_r263_echo_slot 定罪：未解锁 set_character 静默回落 sentinel 双武装不发生）
	var snap_map_records: Dictionary = Meta.map_records.duplicate()
	Meta.map_records["world_grass#1"] = {"best_wave": 12, "best_kills": 0, "best_level": 1}
	Meta.character_id = &"echo"
	Meta.set_blessing_trait(&"MEC_ORBIT_LINK")             # 蓝 20·绑 W8-W13（echo 两臂；
	                                                     # 第 1 关双武装池=W2/W3 门内集——恒无适配宿主）
	var sd_g11: int = Meta.stardust
	_start_normal(gl, 0)
	_check("G11 echo×普通：无空槽拒送拒挂（2 槽被双武装占满）+ 横幅披露 + 不扣费",
		_trait_layers_total(gl, &"MEC_ORBIT_LINK") == 0
			and _count_weapon(gl, &"W8_orbit_field") == 0
			and "".join(gl._run_intro_lines).contains("武器槽已满")
			and Meta.stardust == sd_g11,
		"lines=%s sd=%d→%d" % [str(gl._run_intro_lines), sd_g11, Meta.stardust])
	var sd_g11h: int = Meta.stardust
	_start_normal(gl, 1)                                 # 困难：3 槽（双武装 0/1 + 空槽 2）
	var dual_has_fit := false                            # 双武装含 W8/W9（ORBIT_LINK 绑 W8-W13 可挂）→ 走挂载
	for i in range(2):
		var wid := _slot_wid(gl, i)
		if wid == &"W8_orbit_field" or wid == &"W9_arc_slash":
			dual_has_fit = true
	var hard_ok := _trait_layers_total(gl, &"MEC_ORBIT_LINK") == 1 \
		and Meta.stardust == sd_g11h - 20                # 两条路径都恰扣一次 20
	if not dual_has_fit:
		hard_ok = hard_ok and _slot_wid(gl, 2) == &"W8_orbit_field"   # 送武分支恒落 slot2
	_check("G11 echo×困难：生效恰 1 份（双武装含 W8/W9 走挂载；否则送武落 slot2）",
		hard_ok, "fit=%s s2=%s sd=%d→%d" % [str(dual_has_fit), String(_slot_wid(gl, 2)), sd_g11h, Meta.stardust])
	Meta.character_id = &"sentinel"
	Meta.map_records = snap_map_records

	# ══ G12 RNG 纪律：送武链零全局 rng（seed 逐位）+ 双局部流（B9 口径） ══
	Meta.set_blessing_trait(&"MEC_ORBIT_SWORD")
	Meta.stardust = 200
	seed(42)
	_start_normal(gl, 0)                                 # 送武+扣费全链（同帧同步）
	var probe1: Array[int] = []
	for _k in range(4):
		probe1.append(randi())
	Meta.blessing_trait_id = ""                          # 对照臂：无祝福
	seed(42)
	_start_normal(gl, 0)
	var probe2: Array[int] = []
	for _k in range(4):
		probe2.append(randi())
	_check("G12 全局流零位移：seed(42) 带送武祝福 vs 不带 → randi 序列逐位相同",
		probe1 == probe2, "%s vs %s" % [str(probe1), str(probe2)])
	Meta.set_blessing_trait(&"MEC_ORBIT_SWORD")          # B9 双局部流（每日种子确定性口径）
	_goto_menu(gl)
	gl._difficulty = 0
	gl.start_run(424242)
	var card_state: int = gl.card_generator.rng.state
	var spawn_state: int = gl.spawner.rng.state
	Meta.blessing_trait_id = ""
	_goto_menu(gl)
	gl._difficulty = 0
	gl.start_run(424242)
	_check("G12 局部流零位移：card_generator/spawner rng.state 逐位相同（B9 口径保持）",
		card_state == gl.card_generator.rng.state and spawn_state == gl.spawner.rng.state,
		"%d vs %d" % [card_state, gl.card_generator.rng.state])

	_restore()
	RunSave.clear()
	gl.free()
	_summary()


func _unlock_all_traits(p_gl) -> void:
	for tid_v: Variant in p_gl.registry.traits.keys():
		Meta.codex_traits[String(tid_v)] = true


func _snap() -> void:
	_snap_codex_traits = Meta.codex_traits.duplicate()
	_snap_codex_weapons = Meta.codex_weapons.duplicate()
	_snap_unlocked_chars = Meta.unlocked_characters.duplicate()
	_snap_blessing = Meta.blessing_trait_id
	_snap_character = Meta.character_id
	_snap_custom_weapon = Meta.custom_weapon_id
	_snap_stardust = Meta.stardust
	_snap_stardust_total = Meta.stardust_total
	var sp := Meta.save_path()
	_had_save = FileAccess.file_exists(sp)
	if _had_save:
		_save_text = FileAccess.get_file_as_string(sp)


func _restore() -> void:
	Meta.codex_traits = _snap_codex_traits
	Meta.codex_weapons = _snap_codex_weapons
	Meta.unlocked_characters = _snap_unlocked_chars
	Meta.blessing_trait_id = _snap_blessing
	Meta.character_id = _snap_character
	Meta.custom_weapon_id = _snap_custom_weapon
	Meta.stardust = _snap_stardust
	Meta.stardust_total = _snap_stardust_total
	var sp := Meta.save_path()
	if _had_save:
		var f := FileAccess.open(sp, FileAccess.WRITE)
		if f != null:
			f.store_string(_save_text)
			f.close()
		Meta._load()
	else:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(sp))


func _summary() -> void:
	print("验收汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	for f in _failures:
		print("  FAIL | %s" % f)


func fail_count() -> int:
	return _fail

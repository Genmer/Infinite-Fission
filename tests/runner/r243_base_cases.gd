# tests/runner/r243_base_cases.gd
# R243 类别地基（w1-base）用例体（入口运行时 load——cases 禁 test_ 前缀防电池 glob 误收）。
# 覆盖（设计 §9.1 test_r243_class ①~⑧ + w1 基建 smoke）：
# ① 五武器在册且 form==3
# ② 类别键读回（weapon_class/mode/block_chance/shock_radius/数值表）+ W9 死阈值清理
#    + transcend 占位五表 + display_name 改名
# ③ mode 键缺省回落（nullify→slash 否则 orbit；显式 mode 优先）
# ④ 工厂分派映射（swords/axe/cleave 归属 + w2 脚本未交付 load 守卫回落 OrbitWeapon）
# ⑤ required_class 门三向 + 零门早退同批扩（只带 required_class 不被早退放行）
# ⑥ validator 越界（block_chance/mode/shock_radius/transcend 结构）+ add_block/
#    add_boom_range 入 ADD_POOL_IDS 第 17/18 员（追加不重排）+ 全量 rejected==0
# ⑦ MechanicGate：W11/W12 map3、W13 map4 + MAP_INTROS[3]/[4] 文案
# ⑧ weapon_note 三新非空 + WEAPON_CLASS_NAMES 单源
# ⑦口/⑧/⑨/⑩/⑪ 基建 smoke：bullet_block_chance / blend_element_color /
#    TraitContext 新字段 / projectile 形态键读回与斧抵达 / 图标委托与 _t2 缓存键 /
#    化身刃白名单
# ⑫ 套件总项数断言（R231 假绿教训）
extends RefCounted

const EXPECTED_TOTAL := 46                    # +5 弹体视觉变体 + ⑩ 拆双断言（委托真身/质变差分——R231 假绿教训）

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _reg: DataRegistry = null
var _stubs: Array = []                       # 收尾 free（Node 桩）


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(20261008)
	_reg = DataRegistry.new()
	_reg.load_all("res://data/manifest.cfg")
	await tree.process_frame
	_case1_data()
	_case2_mode_fallback()
	_case3_dispatch()
	_case4_class_gate()
	_case5_validator()
	_case6_mech_gate()
	_case7_notes()
	_case8_common()
	_cleanup()
	_check("⑫ 套件总项数（EXPECTED=%d——R231 假绿教训）" % EXPECTED_TOTAL,
		_pass + _fail + 1 == EXPECTED_TOTAL, "实得 %d" % (_pass + _fail + 1))
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)
	print("验收汇总：%d/%d 通过" % [_pass, _pass + _fail])


func fail_count() -> int:
	return _fail


func _icon_pixels_eq(p_a: ImageTexture, p_b: ImageTexture) -> bool:
	# 委托真身像素级比对（weapon_icon_tex 直调产新贴图——与工厂缓存对象不同实例，
	# 必须逐字节比对 get_data()；占位骨架与委托真身几何/缀饰互异 → 回落态必不相等）
	if p_a == null or p_b == null:
		return false
	return p_a.get_image().get_data() == p_b.get_image().get_data()


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("  PASS | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s（%s）" % [p_name, p_detail])
		print("  FAIL | %s（%s）" % [p_name, p_detail])


func _cleanup() -> void:
	for s in _stubs:
		if s != null and s is Node and is_instance_valid(s):
			(s as Node).free()
	_stubs.clear()


# ── 桩工厂 ────────────────────────────────────────────────────────
func _mk_stub(p_wd: WeaponData) -> WeaponBase:
	var w := WeaponBase.new()
	w.data = p_wd
	_stubs.append(w)
	return w


func _mk_melee_wd(p_melee: Dictionary, p_id: StringName = &"TST_R243") -> WeaponData:
	var wd := WeaponData.new()
	wd.id = p_id
	wd.display_name = "TST"
	wd.form = GameConst.WeaponForm.MELEE
	for i in range(5):
		var lv := WeaponLevelStats.new()
		lv.base_atk = 10.0
		lv.rof = 1.0
		lv.cd = 1.0
		wd.upgrade_table.append(lv)
	wd.melee = p_melee
	return wd


func _has_field(p_out: Array, p_field: String) -> bool:
	for v in p_out:
		if v is Dictionary and String((v as Dictionary).get("field", "")) == p_field:
			return true
	return false


func _attach_add(p_w: WeaponBase, p_pool: StringName, p_value: float) -> void:
	var t := TraitData.new()
	t.id = StringName("TST_" + String(p_pool))
	t.display_name = "TST"
	t.pool = GameConst.PoolClass.ADD
	t.pool_id = p_pool
	t.effect_id = &"EF_STAT"
	t.value = p_value
	t.stack_max = 3
	t.decay_delta = 0.85
	if p_w.trait_stack == null:
		p_w.trait_stack = TraitStack.new()
	p_w.trait_stack.attach(t)


func _attach_elem(p_w: WeaponBase, p_element: int) -> void:
	var t := TraitData.new()
	t.id = StringName("TST_ELE_%d" % p_element)
	t.display_name = "TST"
	t.pool = GameConst.PoolClass.ELEM
	t.effect_id = &"EF_ELEMENTAL"
	t.value = 1.0
	t.params = {"element": p_element}
	if p_w.trait_stack == null:
		p_w.trait_stack = TraitStack.new()
	p_w.trait_stack.attach(t)


# ── ①② 类别键读回 + 全量校验 ─────────────────────────────────────
func _case1_data() -> void:
	print("── ①② 五武器表落库与类别键读回 ──")
	var ids: Array[StringName] = [&"W8_orbit_field", &"W9_arc_slash",
		&"W11_spirit_sword", &"W12_ground_axe", &"W13_great_sword"]
	var all_melee := true
	for wid in ids:
		var wd := _reg.get_weapon(wid)
		if wd == null or int(wd.form) != GameConst.WeaponForm.MELEE:
			all_melee = false
	_check("①五武器在册且 form==3（id 不变纪律）", all_melee,
		str(ids.map(func(wid): return _reg.get_weapon(wid) != null)))
	var w8 := _reg.get_weapon(&"W8_orbit_field")
	var w9 := _reg.get_weapon(&"W9_arc_slash")
	var w11 := _reg.get_weapon(&"W11_spirit_sword")
	var w12 := _reg.get_weapon(&"W12_ground_axe")
	var w13 := _reg.get_weapon(&"W13_great_sword")
	_check("②display_name 五连改名（§1.3）",
		w8.display_name == "近战·天狼刀" and w9.display_name == "法器·旋风刀"
		and w11.display_name == "法器·灵剑" and w12.display_name == "法器·裂地斧"
		and w13.display_name == "近战·阔剑",
		"%s/%s/%s/%s/%s" % [w8.display_name, w9.display_name, w11.display_name,
		w12.display_name, w13.display_name])
	_check("②W8 读回：melee/orbit/block 0.30（数值表不动——蓄能键组仍在）",
		String(w8.melee.get("weapon_class")) == "melee"
		and String(w8.melee.get("mode")) == "orbit"
		and is_equal_approx(float(w8.melee.get("block_chance")), 0.30)
		and int(w8.melee.get("charge_max")) == 5
		and is_equal_approx(float(w8.melee.get("detonate_mult")), 5.0),
		str(w8.melee.get("weapon_class")) + "/" + str(w8.melee.get("mode")))
	_check("②W9 读回：talisman/slash/nullify true + 死阈值已删（TH_SIZE_NOVA/TH_BOUNCE_ETERNAL）保留双阈",
		String(w9.melee.get("weapon_class")) == "talisman"
		and String(w9.melee.get("mode")) == "slash"
		and bool(w9.melee.get("nullify"))
		and w9.threshold_traits.size() == 2
		and not _has_threshold(w9, &"TH_SIZE_NOVA")
		and not _has_threshold(w9, &"TH_BOUNCE_ETERNAL")
		and _has_threshold(w9, &"TH_CRIT_SHARD")
		and _has_threshold(w9, &"TH_FRACTAL_ECHO"),
		str(w9.threshold_traits.size()))
	_check("②W11 读回：talisman/swords/nullify true + pierce 1 + hitbox_r 9.0 + atk/cd 表",
		String(w11.melee.get("weapon_class")) == "talisman"
		and String(w11.melee.get("mode")) == "swords"
		and bool(w11.melee.get("nullify"))
		and int(w11.melee.get("pierce")) == 1
		and is_equal_approx(float(w11.hitbox_r), 9.0)
		and _atk_cd_table(w11, [24.0, 28.0, 28.0, 34.0, 42.0],
			[0.55, 0.55, 0.50, 0.50, 0.42]),
		"hitbox_r=%s" % str(w11.hitbox_r))
	_check("②W12 读回：talisman/axe/nullify true + shock_radius 表 [96,104,104,112,128] + 掷速 640 + hitbox_r 12",
		String(w12.melee.get("weapon_class")) == "talisman"
		and String(w12.melee.get("mode")) == "axe"
		and bool(w12.melee.get("nullify"))
		and w12.melee.get("shock_radius_levels") == [96.0, 104.0, 104.0, 112.0, 128.0]
		and is_equal_approx(float(w12.melee.get("throw_speed")), 640.0)
		and is_equal_approx(float(w12.hitbox_r), 12.0)
		and _atk_cd_table(w12, [56.0, 56.0, 70.0, 84.0, 96.0],
			[3.6, 3.6, 3.6, 3.6, 2.8]),
		str(w12.melee.get("shock_radius_levels")))
	_check("②W13 读回：melee/cleave/block 0.30 + 斩表/弧表 + max_targets 10 + knockback 100",
		String(w13.melee.get("weapon_class")) == "melee"
		and String(w13.melee.get("mode")) == "cleave"
		and not bool(w13.melee.get("nullify"))
		and is_equal_approx(float(w13.melee.get("block_chance")), 0.30)
		and w13.melee.get("slash_radius_levels") == [130.0, 140.0, 155.0, 170.0, 190.0]   # R245 表值迁移（§3.2 下压）
		and w13.melee.get("arc_deg_levels") == [140.0, 140.0, 140.0, 160.0, 180.0]
		and int(w13.melee.get("max_targets")) == 10
		and is_equal_approx(float(w13.melee.get("knockback")), 100.0)
		and _atk_cd_table(w13, [64.0, 76.0, 76.0, 92.0, 105.0],
			[2.9, 2.9, 2.7, 2.7, 2.4]),
		str(w13.melee.get("slash_radius_levels")))
	var tc_ok := true
	for pair in [[w8, "苍狼啸月", "orbs_bonus", 2.0], [w9, "碧涛旋舞", "arc_bonus_deg", 40.0],
		[w11, "万剑诀", "volley", 3.0], [w12, "崩山击", "radius_mult", 1.25],
		[w13, "裂地斩", "atk_mult", 1.2]]:
		var wd: WeaponData = pair[0]
		var tc: Variant = wd.melee.get("transcend")
		if not (tc is Dictionary) or String((tc as Dictionary).get("name", "")) != String(pair[1]) \
				or not is_equal_approx(float((tc as Dictionary).get(String(pair[2]), 0.0)), float(pair[3])):
			tc_ok = false
	_check("②transcend 占位五表（name 非空 + 代表键读回）", tc_ok, "键集见设计 §7.2")
	var rejected_n := int(_reg.report.get("rejected", -1))
	_check("⑥全量校验 rejected==0（三新表入库全绿）", rejected_n == 0,
		"rejected=%d total=%d" % [rejected_n, int(_reg.report.get("total", 0))])


func _has_threshold(p_w: WeaponData, p_id: StringName) -> bool:
	for th in p_w.threshold_traits:
		if StringName(str((th as Dictionary).get("threshold_id", ""))) == p_id:
			return true
	return false


func _atk_cd_table(p_w: WeaponData, p_atk: Array, p_cd: Array) -> bool:
	var atk_ok := true
	var cd_ok := true
	for i in range(5):
		if not is_equal_approx(float(p_w.upgrade_table[i].base_atk), float(p_atk[i])):
			atk_ok = false
		if not is_equal_approx(float(p_w.upgrade_table[i].cd), float(p_cd[i])):
			cd_ok = false
	return atk_ok and cd_ok


# ── ③ mode 缺省回落 ──────────────────────────────────────────────
func _case2_mode_fallback() -> void:
	print("── ③ mode 键缺省回落（§1.2 单源 WeaponBase.melee_mode_of） ──")
	_check("③缺省 {} → orbit（nullify=false 旧口径）",
		WeaponBase.melee_mode_of({}) == "orbit")
	_check("③nullify=true → slash（测试桩夹具兼容回落）",
		WeaponBase.melee_mode_of({"nullify": true}) == "slash")
	_check("③显式 mode 优先（axe 不被回落覆写）",
		WeaponBase.melee_mode_of({"mode": "axe", "nullify": false}) == "axe")


# ── ④ 工厂分派映射 ───────────────────────────────────────────────
func _case3_dispatch() -> void:
	print("── ④ player._instantiate_weapon MELEE mode 分派 ──")
	var player_stub := Player.new()
	_stubs.append(player_stub)
	var w8i := player_stub._instantiate_weapon(_reg.get_weapon(&"W8_orbit_field"))
	var w9i := player_stub._instantiate_weapon(_reg.get_weapon(&"W9_arc_slash"))
	var w13i := player_stub._instantiate_weapon(_reg.get_weapon(&"W13_great_sword"))
	_stubs.append(w8i)
	_stubs.append(w9i)
	_stubs.append(w13i)
	_check("④W8/W9/W13 → OrbitWeapon（orbit/slash/cleave 三模式同载体）",
		w8i is OrbitWeapon and w9i is OrbitWeapon and w13i is OrbitWeapon)
	var w11i := player_stub._instantiate_weapon(_reg.get_weapon(&"W11_spirit_sword"))
	var w12i := player_stub._instantiate_weapon(_reg.get_weapon(&"W12_ground_axe"))
	_stubs.append(w11i)
	_stubs.append(w12i)
	# R243 迁移：w2 真实脚本已交付，w1 波次「load 守卫回落 OrbitWeapon」守卫语义完成使命——
	# 改断言工厂真实分派类型（swords→FlyingSwordWeapon / axe→GroundAxeWeapon）
	_check("④W11/W12 工厂真实分派（FlyingSwordWeapon / GroundAxeWeapon——R243 迁移：w2 脚本已交付）",
		w11i is FlyingSwordWeapon and w12i is GroundAxeWeapon)
	_check("④mode 映射五连（W8 orbit / W9 slash / W11 swords / W12 axe / W13 cleave）",
		WeaponBase.melee_mode_of(_reg.get_weapon(&"W8_orbit_field").melee) == "orbit"
		and WeaponBase.melee_mode_of(_reg.get_weapon(&"W9_arc_slash").melee) == "slash"
		and WeaponBase.melee_mode_of(_reg.get_weapon(&"W11_spirit_sword").melee) == "swords"
		and WeaponBase.melee_mode_of(_reg.get_weapon(&"W12_ground_axe").melee) == "axe"
		and WeaponBase.melee_mode_of(_reg.get_weapon(&"W13_great_sword").melee) == "cleave")


# ── ⑤ required_class 挂载门三向 ──────────────────────────────────
func _case4_class_gate() -> void:
	print("── ⑤ card_generator.mount_gate_allows required_class 门 ──")
	var t_talisman := TraitData.new()
	t_talisman.id = &"TST_TALISMAN_ONLY"
	t_talisman.params = {"required_class": ["talisman"]}
	var t_melee := TraitData.new()
	t_melee.id = &"TST_MELEE_ONLY"
	t_melee.params = {"required_class": ["melee"]}
	var w9_target := _mk_stub(_reg.get_weapon(&"W9_arc_slash"))       # talisman/form3
	var w8_target := _mk_stub(_reg.get_weapon(&"W8_orbit_field"))     # melee/form3
	var w0 := WeaponData.new()
	w0.id = &"TST_BALLISTIC"
	w0.form = GameConst.WeaponForm.BALLISTIC
	var w0_target := _mk_stub(w0)                                     # form0
	_check("⑤talisman 卡 vs W9（talisman/form3）→ true", CardGenerator.mount_gate_allows(t_talisman, w9_target))
	_check("⑤talisman 卡 vs W8（melee/form3）→ false（同 form 异类）",
		not CardGenerator.mount_gate_allows(t_talisman, w8_target))
	_check("⑤talisman 卡 vs form0 → false（非 form 3 恒 false）",
		not CardGenerator.mount_gate_allows(t_talisman, w0_target))
	_check("⑤melee 卡 vs W13 桩 → true / vs W9 → false",
		CardGenerator.mount_gate_allows(t_melee, _mk_stub(_reg.get_weapon(&"W13_great_sword")))
		and not CardGenerator.mount_gate_allows(t_melee, w9_target))
	_check("⑤零门早退同批扩：只带 required_class 的卡无目标 → false（未被早退放行）",
		not CardGenerator.mount_gate_allows(t_talisman, null))


# ── ⑥ validator 越界与新池登记 ───────────────────────────────────
func _case5_validator() -> void:
	print("── ⑥ data_validator 新键域 + ADD_POOL_IDS 第 17/18 员 ──")
	var v := DataValidator.new()
	var base := {"orbs": 2, "arc_deg": 120.0, "nullify": false}
	var bad_block := _mk_melee_wd({"orbs": 2, "arc_deg": 120.0, "block_chance": 1.5})
	_check("⑥block_chance 1.5 出 [0,1] → 报错", _has_field(v.validate_weapon(bad_block), "melee.block_chance"))
	var bad_mode := _mk_melee_wd({"orbs": 2, "arc_deg": 120.0, "mode": "spin"})
	_check("⑥mode 非法（spin）→ 报错", _has_field(v.validate_weapon(bad_mode), "melee.mode"))
	var bad_shock := _mk_melee_wd({"orbs": 2, "arc_deg": 120.0, "shock_radius": 200.0})
	_check("⑥shock_radius 200 出 (0,128] → 报错", _has_field(v.validate_weapon(bad_shock), "melee.shock_radius"))
	var bad_tc_type := _mk_melee_wd({"orbs": 2, "arc_deg": 120.0, "transcend": "nope"})
	_check("⑥transcend 非 Dictionary → 报错", _has_field(v.validate_weapon(bad_tc_type), "melee.transcend"))
	var bad_tc_name := _mk_melee_wd({"orbs": 2, "arc_deg": 120.0, "transcend": {"atk_mult": 1.0}})
	_check("⑥transcend 缺 name → 报错", _has_field(v.validate_weapon(bad_tc_name), "melee.transcend.name"))
	var good := _mk_melee_wd({"orbs": 2, "arc_deg": 120.0, "weapon_class": "talisman",
		"mode": "slash", "block_chance": 0.3, "shock_radius": 96.0,
		"transcend": {"name": "测试质变", "atk_mult": 1.0}})
	var good_out := v.validate_weapon(good)
	_check("⑥合法新键全绿（weapon_class/mode/block/shock_radius/transcend 在域零报错）",
		good_out.is_empty(), str(good_out))
	var pools: Array[StringName] = DataValidator.ADD_POOL_IDS
	_check("⑥add_block/add_boom_range 入 ADD_POOL_IDS 第 17/18 员（追加不重排——前 16 位不动）",
		pools.size() == 18 and pools[15] == &"add_range"
		and pools[16] == &"add_block" and pools[17] == &"add_boom_range",
		"size=%d" % pools.size())


# ── ⑦ MechanicGate 登记 ──────────────────────────────────────────
func _case6_mech_gate() -> void:
	print("── ⑦ WEAPON_UNLOCK_MAPS + MAP_INTROS ──")
	_check("⑦W11→3 / W12→3 / W13→4（W10==4 既有不动）",
		MechanicGate.weapon_unlock_map_index(&"W11_spirit_sword") == 3
		and MechanicGate.weapon_unlock_map_index(&"W12_ground_axe") == 3
		and MechanicGate.weapon_unlock_map_index(&"W13_great_sword") == 4
		and MechanicGate.weapon_unlock_map_index(&"W10_boomerang") == 4)
	_check("⑦MAP_INTROS[3] 含 天狼刀/旋风刀/灵剑/裂地斧；[4] 含 阔剑/回旋刃",
		MechanicGate.intro_for_map(3).contains("天狼刀")
		and MechanicGate.intro_for_map(3).contains("旋风刀")
		and MechanicGate.intro_for_map(3).contains("灵剑")
		and MechanicGate.intro_for_map(3).contains("裂地斧")
		and MechanicGate.intro_for_map(4).contains("阔剑")
		and MechanicGate.intro_for_map(4).contains("回旋刃"))


# ── ⑧ weapon_note ────────────────────────────────────────────────
func _case7_notes() -> void:
	print("── ⑧ weapon_note 三新非空 + WEAPON_CLASS_NAMES 单源 ──")
	_check("⑧W11/W12/W13 weapon_note 非空 + WEAPON_CLASS_NAMES={melee:近战, talisman:法器}",
		GameConst.weapon_note("W11_spirit_sword") != ""
		and GameConst.weapon_note("W12_ground_axe") != ""
		and GameConst.weapon_note("W13_great_sword") != ""
		and String(GameConst.WEAPON_CLASS_NAMES.get("melee", "")) == "近战"
		and String(GameConst.WEAPON_CLASS_NAMES.get("talisman", "")) == "法器")


# ── 公共口 / 基建 smoke ──────────────────────────────────────────
func _case8_common() -> void:
	print("── ⑦口/⑧/⑨/⑩/⑪ 基建 smoke ──")
	var w8_stub := _mk_stub(_reg.get_weapon(&"W8_orbit_field"))
	var w9_stub := _mk_stub(_reg.get_weapon(&"W9_arc_slash"))
	var b0 := WeaponData.new()
	b0.id = &"TST_BALLISTIC2"
	b0.form = GameConst.WeaponForm.BALLISTIC
	var b0_stub := _mk_stub(b0)
	_check("口 bullet_block_chance：W8=0.30 / W9(nullify)=1.0 / form0=0.0",
		is_equal_approx(w8_stub.bullet_block_chance(), 0.30)
		and is_equal_approx(w9_stub.bullet_block_chance(), 1.0)
		and is_equal_approx(b0_stub.bullet_block_chance(), 0.0))
	_attach_add(w8_stub, &"add_block", 0.08)
	var w8c := _mk_stub(_reg.get_weapon(&"W8_orbit_field"))
	_attach_add(w8c, &"add_block", 0.5)
	var w8_full := _mk_stub(_mk_melee_wd({"orbs": 2, "arc_deg": 120.0,
		"nullify": false, "block_chance": 1.0}))
	_attach_add(w8_full, &"add_block", 0.5)
	_check("口 add_block 池聚合（0.30+0.08=0.38）+ clamp [0,1]（1.0+0.5→1.0）",
		is_equal_approx(w8_stub.bullet_block_chance(), 0.38)
		and is_equal_approx(w8c.bullet_block_chance(), 0.80)
		and is_equal_approx(w8_full.bullet_block_chance(), 1.0))
	var ble_empty := _mk_stub(_reg.get_weapon(&"W8_orbit_field"))
	var ble_one := _mk_stub(_reg.get_weapon(&"W8_orbit_field"))
	_attach_elem(ble_one, GameConst.Element.FIR)
	var ble_two := _mk_stub(_reg.get_weapon(&"W8_orbit_field"))
	_attach_elem(ble_two, GameConst.Element.FIR)
	_attach_elem(ble_two, GameConst.Element.ICE)
	var ble_tri := _mk_stub(_reg.get_weapon(&"W8_orbit_field"))
	_attach_elem(ble_tri, GameConst.Element.FIR)
	_attach_elem(ble_tri, GameConst.Element.ICE)
	_attach_elem(ble_tri, GameConst.Element.LTG)
	var fir_col: Color = PopPalette.ELEMENT_COLORS[GameConst.Element.FIR]
	var ice_col: Color = PopPalette.ELEMENT_COLORS[GameConst.Element.ICE]
	var got_mix := ble_two.blend_element_color()
	var got_tri := ble_tri.blend_element_color()
	var got_one := ble_one.blend_element_color()
	var dom_col: Color = PopPalette.ELEMENT_COLORS[ble_one.dominant_element()]
	# R243 迁移/发现修复：HSV 色相插值替代 RGB 均值（3+ 元素洗灰回归）——断言改属性化：
	# 双元素饱和保真（≥成员最大 sat）+ 明度=成员均值；三元素饱和保底 ≥0.6（火+冰+雷
	# 原 RGB 均值 s≈0.2 洗灰紫）
	_check("口 blend_element_color（HSV 色相插值）：空池=白 / 单元素=dominant 色 / "
		+ "双元素饱和保真+明度均值 / 三元素饱和保底 ≥0.6",
		ble_empty.blend_element_color().is_equal_approx(Color.WHITE)
		and absf(got_one.r - dom_col.r) < 1e-3 and absf(got_one.g - dom_col.g) < 1e-3 \
			and absf(got_one.b - dom_col.b) < 1e-3
		and got_mix.s >= maxf(fir_col.s, ice_col.s) - 1e-3
		and absf(got_mix.v - (fir_col.v + ice_col.v) * 0.5) < 1e-3
		and got_tri.s >= 0.6 - 1e-3,
		"mix=%s tri=%s" % [str(got_mix), str(got_tri)])
	var tc := TraitContext.new()
	_check("⑨TraitContext 新字段缺省（attach_requests/host_elements 空、melee_split_request 空字典；旧单槽并存）",
		tc.attach_requests.is_empty() and tc.host_elements.is_empty()
		and tc.melee_split_request.is_empty()
		and tc.attach_request.is_empty() and tc.split_request.is_empty())
	var proj := ProjectileBase.new()
	_stubs.append(proj)
	proj.spawn({
		"position": Vector2(100.0, 100.0), "velocity": Vector2(0.0, -200.0),
		"lifetime": 3.0, "pierce": 1, "hitbox_radius": 12.0, "team": 0,
		"flight_axe": true, "target_point": Vector2(100.0, 240.0),
		"shock_scale": 0.4, "attach_elements": [1, 2],
		"panel_snapshot": {"base_atk": 100.0},
	})
	var proj_ctx := proj._build_trait_ctx(GameConst.TraitEvent.ON_SPAWN)
	_check("⑧projectile spawn 键读回（flight_axe/target_point/shock_scale/attach_elements）+ host_elements 接线",
		bool(proj.get("_flight_axe")) and proj.get("_target_point") == Vector2(100.0, 240.0)
		and is_equal_approx(float(proj.get("_shock_scale")), 0.4)
		and proj.attach_elements == [1, 2]
		and proj_ctx.host_elements == [1, 2])
	var sword_p := ProjectileBase.new()
	_stubs.append(sword_p)
	sword_p.spawn({
		"position": Vector2.ZERO, "velocity": Vector2(0.0, -100.0),
		"lifetime": 1.0, "pierce": 1, "team": 0, "flight_sword": true,
	})
	var plain_p := ProjectileBase.new()
	_stubs.append(plain_p)
	plain_p.spawn({
		"position": Vector2.ZERO, "velocity": Vector2(0.0, -100.0),
		"lifetime": 1.0, "pierce": 1, "team": 0,
	})
	var landed: bool = proj._axe_step(1.0)      # 一步可跨（速度 200、距 140）→ 落地回收
	_check("⑧flight_sword 键读回 + 缺省关闭（旧弹零影响）+ 斧抵达→on_axe_land 守卫（无宿主不崩）FORCED 回收",
		bool(sword_p.get("_flight_sword")) and not bool(sword_p.get("_flight_axe"))
		and not bool(plain_p.get("_flight_sword")) and not bool(plain_p.get("_flight_axe"))
		and landed and not bool(proj.get("_live")) and bool(proj.get("is_clean")))
	# ── R243 弹体视觉变体（高优修复②：_VIS_SWORD/_VIS_AXE——不再全落 _VIS_PLAIN 圆珠） ──
	# 桩弹不入树 → _sprite 缺位，手动 _ready() 组装后 _sync_visual 解析变体（与 spawn 期
	# 首帧解析同函数同口径）。贴图同实例判定 = 武器脚本 static 缓存直读（委托真身不可伪）。
	var sword_w := _mk_stub(_reg.get_weapon(&"W11_spirit_sword"))
	var sword_v := ProjectileBase.new()
	_stubs.append(sword_v)
	sword_v.spawn({
		"position": Vector2.ZERO, "velocity": Vector2(0.0, -860.0),
		"lifetime": 1.0, "pierce": 1, "hitbox_radius": 9.0, "team": 0,
		"flight_sword": true, "weapon_ref": sword_w,
	})
	sword_v._ready()
	sword_v._sync_visual()
	_check("⑧飞剑弹变体解析 = _VIS_SWORD（形态键优先——不再落 _VIS_PLAIN 圆珠）+ 无键 plain 弹仍 _VIS_PLAIN",
		int(sword_v._resolve_visual_variant()) == sword_v._VIS_SWORD
		and int(plain_p._resolve_visual_variant()) == plain_p._VIS_PLAIN,
		"sword=%d plain=%d" % [int(sword_v._resolve_visual_variant()),
		int(plain_p._resolve_visual_variant())])
	_check("⑧飞剑贴图 = FlyingSwordWeapon.flight_tex(false)（剑形贴图同实例——非 64px 圆珠骨架）",
		sword_v._sprite != null and sword_v._sprite.texture != null
		and sword_v._sprite.texture == FlyingSwordWeapon.flight_tex(false),
		str(sword_v._sprite != null and sword_v._sprite.texture != null))
	_check("⑧飞剑顺速度朝向（向上飞行 rotation≈0——画布 -Y 剑尖迎速，导弹 angle+PI/2 同式）",
		sword_v._sprite != null and is_equal_approx(sword_v._sprite.rotation, 0.0),
		str(sword_v._sprite.rotation if sword_v._sprite != null else -999.0))
	var axe_w := _mk_stub(_reg.get_weapon(&"W12_ground_axe"))
	var axe_v := ProjectileBase.new()
	_stubs.append(axe_v)
	axe_v.spawn({
		"position": Vector2.ZERO, "velocity": Vector2(640.0, 0.0),
		"lifetime": 3.0, "pierce": 1, "hitbox_radius": 12.0, "team": 0,
		"flight_axe": true, "target_point": Vector2(300.0, 0.0),
		"shock_scale": 1.0, "weapon_ref": axe_w,
		"panel_snapshot": {"base_atk": 56.0},
	})
	axe_v._ready()
	axe_v._sync_visual()
	_check("⑧掷斧弹变体 = _VIS_AXE + 贴图 = GroundAxeWeapon.flight_tex(false) + 顺速度朝向（向右飞 rotation≈+PI/2）",
		int(axe_v._resolve_visual_variant()) == axe_v._VIS_AXE
		and axe_v._sprite.texture == GroundAxeWeapon.flight_tex(false)
		and absf(axe_v._sprite.rotation - PI * 0.5) < 1e-3,
		"axe=%d rot=%s" % [int(axe_v._resolve_visual_variant()),
		str(axe_v._sprite.rotation)])
	sword_w.set("transcended", true)            # §7.1 w4 已交付 WeaponBase.transcended——质变染体切换
	var sword_t := ProjectileBase.new()
	_stubs.append(sword_t)
	sword_t.spawn({
		"position": Vector2.ZERO, "velocity": Vector2(0.0, -860.0),
		"lifetime": 1.0, "pierce": 1, "hitbox_radius": 9.0, "team": 0,
		"flight_sword": true, "weapon_ref": sword_w,
	})
	sword_t._ready()
	sword_t._sync_visual()
	_check("⑧飞剑质变染体（宿主 transcended → 鎏金剑体贴图，≠ 默认银蓝——§7.2 两态贴图差）",
		sword_t._sprite != null
		and sword_t._sprite.texture == FlyingSwordWeapon.flight_tex(true)
		and FlyingSwordWeapon.flight_tex(true) != FlyingSwordWeapon.flight_tex(false),
		str(sword_t._sprite != null
		and sword_t._sprite.texture == FlyingSwordWeapon.flight_tex(true)))
	var icon_w8 := TextureFactory.weapon_icon(&"W8_orbit_field")
	var icon_w9 := TextureFactory.weapon_icon(&"W9_arc_slash")
	var icon_w11 := TextureFactory.weapon_icon(&"W11_spirit_sword")
	var icon_w12 := TextureFactory.weapon_icon(&"W12_ground_axe")
	var icon_w11_t2 := TextureFactory.weapon_icon_t2(&"W11_spirit_sword")
	var icon_t2 := TextureFactory.weapon_icon_t2(&"W8_orbit_field")
	# R243 评审修复同步强化（消除「委托失败回落占位 / 委托成功」两态皆过的遮蔽——修复前
	# :1549 has_static_method 报错下本断言必挂）：委托真身 = 工厂图标像素逐字节 == 各武器
	# 脚本 static weapon_icon_tex 直调产物（weapon_icon_tex 内部无缓存 → 两次调用对象不同
	# 实例，必须像素比对；占位骨架与委托真身几何/缀饰互异 → 回落态必不相等）。
	var icon_w11_real: ImageTexture = FlyingSwordWeapon.weapon_icon_tex(false)
	var icon_w11_real_t2: ImageTexture = FlyingSwordWeapon.weapon_icon_tex(true)
	var icon_w12_real: ImageTexture = GroundAxeWeapon.weapon_icon_tex(false)
	var icon_w8_t2 := TextureFactory.weapon_icon_t2(&"W8_orbit_field")
	var icon_w9_t2 := TextureFactory.weapon_icon_t2(&"W9_arc_slash")
	var same_tex := _icon_pixels_eq(icon_w11, icon_w11_real) \
		and _icon_pixels_eq(icon_w11_t2, icon_w11_real_t2) \
		and _icon_pixels_eq(icon_w12, icon_w12_real)
	_check("⑩texture_factory 委托真身：W11/W12 图标像素 == 各武器 static weapon_icon_tex(false) 产物（非占位骨架）",
		icon_w8 != null and icon_w9 != null
		and _icon_pixels_eq(icon_w11, icon_w11_real)
		and _icon_pixels_eq(icon_w12, icon_w12_real),
		"w8=%s w9=%s w11_px=%s w12_px=%s" % [str(icon_w8 != null), str(icon_w9 != null),
		str(_icon_pixels_eq(icon_w11, icon_w11_real)),
		str(_icon_pixels_eq(icon_w12, icon_w12_real))])
	_check("⑩<id>_t2 质变差分（R243 迁移/发现修复——W8/W9 质变委托已注册，撤「未交付回落」旧口径）："
		+ "W11/W8/W9 _t2 == 各自 weapon_icon_tex(true) 且 ≠ 基图（质变贴图差）+ 缓存键分立",
		same_tex
		and not _icon_pixels_eq(icon_w11_t2, icon_w11)
		and icon_t2 != null and _icon_pixels_eq(icon_t2, OrbitField.weapon_icon_tex(true))
		and not _icon_pixels_eq(icon_t2, icon_w8)
		and icon_w8_t2 != null and _icon_pixels_eq(icon_w8_t2, OrbitField.weapon_icon_tex(true))
		and icon_w9_t2 != null and _icon_pixels_eq(icon_w9_t2, ArcSlash.weapon_icon_tex(true))
		and not _icon_pixels_eq(icon_w9_t2, icon_w9)
		and TextureFactory._cache.has("weapon_icon_W8_orbit_field")
		and TextureFactory._cache.has("weapon_icon_W8_orbit_field_t2")
		and TextureFactory._cache.has("weapon_icon_W11_spirit_sword_t2"),
		"w11t2_px=%s w11t2_neq_base=%s w8t2_px=%s w9t2_px=%s" % [
		str(same_tex),
		str(not _icon_pixels_eq(icon_w11_t2, icon_w11)),
		str(icon_w8_t2 != null and _icon_pixels_eq(icon_w8_t2, OrbitField.weapon_icon_tex(true))),
		str(icon_w9_t2 != null and _icon_pixels_eq(icon_w9_t2, ArcSlash.weapon_icon_tex(true)))])
	var avatars := WeaponOrbitAvatars.new()
	_stubs.append(avatars)
	var bw1 := _mk_stub(_reg.get_weapon(&"W1_pistol"))
	_check("⑪_is_blade_weapon 白名单（W9 前缀/W11/W12/W13 true；W1/W8 false）",
		avatars._is_blade_weapon(_mk_stub(_reg.get_weapon(&"W9_arc_slash")))
		and avatars._is_blade_weapon(_mk_stub(_reg.get_weapon(&"W11_spirit_sword")))
		and avatars._is_blade_weapon(_mk_stub(_reg.get_weapon(&"W12_ground_axe")))
		and avatars._is_blade_weapon(_mk_stub(_reg.get_weapon(&"W13_great_sword")))
		and not avatars._is_blade_weapon(bw1)
		and not avatars._is_blade_weapon(w8_stub))
	var gen := CardGenerator.new()
	var card9: Dictionary = gen._make_weapon_card(_reg.get_weapon(&"W9_arc_slash"))
	var card13: Dictionary = gen._make_weapon_card(_reg.get_weapon(&"W13_great_sword"))
	var card1: Dictionary = gen._make_weapon_card(_reg.get_weapon(&"W1_pistol"))
	_check("④卡面类别文案（WEAPON_CLASS_NAMES 合成：W9 法器 / W13 近战 / W1 弹道不变）",
		String(card9.get("description", "")).begins_with("法器")
		and String(card13.get("description", "")).begins_with("近战")
		and String(card1.get("description", "")).begins_with("弹道"),
		str(card9.get("description", "")) + "/" + str(card13.get("description", "")))

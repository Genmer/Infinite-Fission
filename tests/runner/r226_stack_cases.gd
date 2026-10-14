# tests/runner/r226_stack_cases.gd
# R226 用例体：无限叠层+属性拆帽回归——用户拍板「肉鸽别搞上限，就是给人爽叠的」。
# 产品契约（R226 有意契约变更，trait_stack.gd/player.gd/modifier_stack.gd 同轮）：
#   ① 玩家属性池拆帽：add_xp（原 +300% 帽）/add_gold（原 +400%）/add_pickup（原 +200%）
#      /add_skillcdr（原 -60%）四池超帽层数全额生效（getter 反映超帽值）；
#   ② 技能急速消费地板：add_skillcdr 无帽后 (1−池) 因子保 0.1 数学地板——
#      skill_cd_base 恒 >0 且 ≥ base×0.1×(1−养成CDR)×遗物乘区（CD 不归零，技能仍有节拍）；
#   ③ 结晶晶盾 DR 储存无帽（原 0.8 储存钳拆——消费端 take_damage 仍钳 [0,0.8]
#      为数学边际区，两条口径独立）；
#   ④ 磁吸半径反映超帽 add_pickup（refresh_pickup_radius 全额合成）；
#   ⑤ diag 仪表两键：bitmap_ready∈{0,1}（R225 位图门直读）、fullload_flips_delta≥0
#      （门翻转秒差分）——vc31 读数缺口的补码；
#   ⑥ 黑市可挂复验：同 ID 超 stack_max 恒可挂（_can_mount_trait 拆帽侧）。
# 坑位纪律：夹具不走击杀链（无 xp_need 封顶需求）；Meta 养成值环境耦合 → 断言用
# 「实时 Meta 值代入期望」而非硬编码；武器夹具 queue_free 回收；run_map 前后还原。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_boot_game_loop()
	await tree.process_frame
	await tree.process_frame
	_test_1_player_pool_caps_removed()
	_test_2_skill_cd_floor()
	_test_3_dr_storage_uncapped()
	_test_4_pickup_radius_uncapped()
	_test_5_diag_keys()
	_test_6_shop_mount_uncapped()
	_test_7_hp_milestone_three_way_consistency()
	_teardown_game_loop()
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
		print("  PASS | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s %s" % [p_name, p_detail])
		print("  FAIL | %s %s" % [p_name, p_detail])


func _boot_game_loop() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "R226GameLoopUnderTest"
	tree.get_root().add_child(_gl)
	_gl.state = GameConst.GameStatus.MENU
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	_gl.start_run()
	_gl.state = GameConst.GameStatus.MENU
	Meta.set_run_map(&"")                     # 第 1 关门（质变门关，数值口径纯净）


func _teardown_game_loop() -> void:
	Enemy.fullload_override = -1              # 覆写口复位（防跨套件泄漏）
	tree.paused = false
	RunSave.clear()
	Meta.set_run_map(&"")
	if _gl != null:
		_gl.free()
		_gl = null


func _attach_n(p_weapon: WeaponBase, p_t: TraitData, p_n: int) -> void:
	for i in range(p_n):
		p_weapon.attach_trait(p_t)


# ── ① 玩家属性池拆帽：超帽层数全额生效 ──────────────────────────
func _test_1_player_pool_caps_removed() -> void:
	print("── ① 玩家属性池拆帽（xp/gold/pickup/skillcdr 超帽全额） ──")
	# 玩家侧 getter 只汇总 player.weapon_slots 槽内武器——夹具走 add_weapon 正规入槽
	var w: WeaponBase = _gl.player.add_weapon(_gl.registry.get_weapon(&"W1_pistol"))
	var t_xp: TraitData = _gl.registry.get_trait(&"AFF_XP_GAIN")       # add_xp（原帽 2.0）
	var t_gold: TraitData = _gl.registry.get_trait(&"AFF_GOLD")        # add_gold（原帽 3.0）
	var t_pk: TraitData = _gl.registry.get_trait(&"AFF_PICKUP")        # add_pickup（原帽 2.0）
	var t_cd: TraitData = _gl.registry.get_trait(&"AFF_SKILL_HASTE")   # add_skillcdr（原帽 0.6）
	_check("①夹具：四池词条在册且武器入槽",
		t_xp != null and t_gold != null and t_pk != null and t_cd != null and w != null)
	if t_xp == null or t_gold == null or t_pk == null or t_cd == null or w == null:
		return
	# 各挂 10 层（value=白卡基值；和 = 10×value——超原帽即证无帽）
	_attach_n(w, t_xp, 10)
	_attach_n(w, t_gold, 10)
	_attach_n(w, t_pk, 10)
	_attach_n(w, t_cd, 10)
	var xp_sum := float(w.trait_stack.aggregate_panel().get("add_xp", 0.0))
	var gold_sum := float(w.trait_stack.aggregate_panel().get("add_gold", 0.0))
	var pk_sum := float(w.trait_stack.aggregate_panel().get("add_pickup", 0.0))
	var cd_sum := float(w.trait_stack.aggregate_panel().get("add_skillcdr", 0.0))
	_check("①聚合：四池 10 层全额（xp 和=%.2f > 原帽 2.0 / gold=%.2f > 3.0 / pickup=%.2f > 2.0 / cdr=%.2f > 0.6）"
		% [xp_sum, gold_sum, pk_sum, cd_sum],
		xp_sum > 2.0 + 1e-9 and gold_sum > 3.0 + 1e-9
		and pk_sum > 2.0 + 1e-9 and cd_sum > 0.6 + 1e-9)
	# getter 端（消费真源）同 reflect 超帽值（xp_gain_pct = (1+养成)×地图×(1+Σ池)−1，
	# 夹具无地图祝福/养成 → 恰等于 Σ池值；gold/haste 直返池和）
	var xp_pct: float = _gl.player.call(&"xp_gain_pct")
	var gold_pct: float = _gl.player.call(&"gold_find_pct")
	var haste: float = _gl.player.call(&"skill_haste_pct")
	_check("①getter：xp_gain_pct=%.3f ≥ Σ池 %.2f / gold_find_pct=%.3f > 3.0 / skill_haste_pct=%.3f > 0.6"
		% [xp_pct, xp_sum, gold_pct, haste],
		xp_pct >= xp_sum - 1e-6 and gold_pct > 3.0 + 1e-9 and haste > 0.6 + 1e-9)
	# 清场：槽位摘除（player 无 remove_weapon——按 verify 惯例直清槽位防跨用例污染）
	for si in range(_gl.player.weapon_slots.size()):
		if _gl.player.weapon_slots[si] == w:
			_gl.player.weapon_slots[si] = null
	w.queue_free()


# ── ② 技能急速消费地板：CD 不归零 ───────────────────────────────
func _test_2_skill_cd_floor() -> void:
	print("── ② 技能 CD 地板（add_skillcdr 无帽后 (1−池) ≥ 0.1） ──")
	var w: WeaponBase = _gl.player.add_weapon(_gl.registry.get_weapon(&"W1_pistol"))
	var t_cd: TraitData = _gl.registry.get_trait(&"AFF_SKILL_HASTE")
	var base: float = float(CharacterTable.get_character(_gl.player.character_id).get("cd", 120.0))
	_attach_n(w, t_cd, 40)                    # 深叠（40 层远超原 0.6 帽）
	_gl.player.call(&"refresh_skill_cd")
	var got_base: float = float(_gl.player.get("skill_cd_base"))
	var expect_floor: float = base * maxf(1.0 - float(Meta.skill_cdr_pct()), 0.0) \
		* 0.1 * float(_gl.player.get("skill_cd_relic_mult"))
	_check("②地板：skill_cd_base=%.2f 恒 >0 且 ≥ 理论地板 %.2f（base×(1−养成)×0.1×遗物）"
		% [got_base, expect_floor],
		got_base > 0.0 and got_base >= expect_floor - 1e-6,
		"base=%.2f got=%.2f floor=%.2f" % [base, got_base, expect_floor])
	_check("②缩 CD：仍显著短于角色基线（急速生效）", got_base < base,
		"got=%.2f base=%.2f" % [got_base, base])
	# 清场：摘除夹具武器（槽位回归——后续用例的玩家 getter 不被 40 层急速污染）
	for si in range(_gl.player.weapon_slots.size()):
		if _gl.player.weapon_slots[si] == w:
			_gl.player.weapon_slots[si] = null
	w.queue_free()


# ── ③ 结晶晶盾 DR 储存无帽 ─────────────────────────────────────
func _test_3_dr_storage_uncapped() -> void:
	print("── ③ DR 储存无帽（原 0.8 储存钳拆；消费端钳独立保留） ──")
	var hp0: float = float(_gl.player.get("hp"))
	_gl.player.call(&"grant_crystal_shield", 5.0, 1.0)
	var dr: float = float(_gl.player.get("dr_value"))
	_check("③储存：grant_crystal_shield(5.0) → dr_value==5.0 原样存（原钳 0.8 拆）",
		absf(dr - 5.0) < 1e-9, "dr=%.2f" % dr)
	_gl.player.call(&"clear_crystal_shield")
	_gl.player.set("hp", hp0)


# ── ④ 磁吸半径全额合成 ─────────────────────────────────────────
func _test_4_pickup_radius_uncapped() -> void:
	print("── ④ 磁吸半径（add_pickup 超帽全额进 refresh_pickup_radius） ──")
	var bal := GameConfig.balance
	var base_r: float = float(bal.pickup_radius) if bal != null else 120.0
	var w: WeaponBase = _gl.player.add_weapon(_gl.registry.get_weapon(&"W1_pistol"))
	var t_pk: TraitData = _gl.registry.get_trait(&"AFF_PICKUP")
	_attach_n(w, t_pk, 10)
	_gl.player.call(&"refresh_pickup_radius")
	var got_r: float = float(_gl.player.get("pickup_radius"))
	var expect: float = base_r * (1.0 + float(Meta.magnet_pct())
		+ maxf(float(w.trait_stack.aggregate_panel().get("add_pickup", 0.0)), 0.0))
	_check("④半径：pickup_radius=%.0f == 基准×(1+养成+10 层池值)=%.0f（原 +200%% 帽拆）"
		% [got_r, expect],
		absf(got_r - expect) < 0.5 and got_r > base_r * 3.0,
		"got=%.1f expect=%.1f" % [got_r, expect])
	for si in range(_gl.player.weapon_slots.size()):
		if _gl.player.weapon_slots[si] == w:
			_gl.player.weapon_slots[si] = null
	w.queue_free()


# ── ⑤ diag 仪表两键 ────────────────────────────────────────────
func _test_5_diag_keys() -> void:
	print("── ⑤ diag_counts 新键（位图R/翻N——vc31 归因缺口补码） ──")
	var counts: Dictionary = _gl.diag_counts()
	var has_bitmap: bool = counts.has(&"bitmap_ready")
	var bitmap_val: int = int(counts.get(&"bitmap_ready", -1))
	var flips: int = int(counts.get(&"fullload_flips_delta", -1))
	_check("⑤位图R：键在且 ∈{0,1}（headless 无渲染预热→0 合法；菜单态烤制→1 合法）",
		has_bitmap and (bitmap_val == 0 or bitmap_val == 1), "val=%d" % bitmap_val)
	_check("⑤翻N：键在且 ≥0（秒差分，重复拉取增量=0 合法）", flips >= 0, "val=%d" % flips)


# ── ⑥ 黑市可挂复验：同 ID 超 stack_max 恒可挂 ───────────────────
func _test_6_shop_mount_uncapped() -> void:
	print("── ⑥ 黑市 _can_mount_trait 拆帽侧（同 ID 恒可挂） ──")
	var shop: Variant = _gl.shop_ui
	if shop == null:
		# shop_ui 惰性创建的场合：退而断言 TraitStack 侧无限（真源已由 r196 ② 覆盖）
		var s := TraitStack.new()
		var t: TraitData = _gl.registry.get_trait(&"AFF_ATK_UP")
		var ok := true
		for i in range(20):
			ok = ok and s.attach(t)
		_check("⑥（无 shop_ui 句柄退化口）：TraitStack 20 层连挂全成功", ok and s.traits[0].layers == 20)
		return
	var w := BallisticWeapon.new()
	tree.root.add_child(w)
	w.setup(_gl.registry.get_weapon(&"W1_pistol"), null, {})
	var t2: TraitData = _gl.registry.get_trait(&"AFF_PIERCE")   # ADD 池 stack_max=2
	_attach_n(w, t2, 16)                                        # 远超原 2+5 帽
	var can: bool = bool(shop.call(&"_can_mount_trait", t2, w))
	_check("⑥同 ID 16 层（超原帽 7）仍可挂（R226 无限供给）", can, "can=%s" % str(can))
	w.queue_free()


# ── ⑦ add_hp 满层质变三口径一致性（评审 M1 回归锁） ─────────────
func _test_7_hp_milestone_three_way_consistency() -> void:
	print("── ⑦ AFF_HP_UP 满层质变：血条=面板聚合=卡面承诺（×1.6 同步三口径） ──")
	var map_save: StringName = Meta.run_map_id()
	Meta.set_run_map(&"world_grove")          # 第 4 关门开（MechanicGate idx≥3 质变口径）
	var w: WeaponBase = _gl.player.add_weapon(_gl.registry.get_weapon(&"W1_pistol"))
	var t_hp: TraitData = _gl.registry.get_trait(&"AFF_HP_UP")   # ADD 池 stack_max=4 value=25
	_check("⑦夹具：AFF_HP_UP 在册且武器入槽", t_hp != null and w != null)
	if t_hp == null or w == null:
		Meta.set_run_map(map_save)
		return
	var hp0: float = float(_gl.player.get("max_hp"))
	for i in range(4):
		w.attach_trait(t_hp)                  # 第 4 层恰触发满层质变（×1.6 全层追溯）
	var hp_gain: float = float(_gl.player.get("max_hp")) - hp0
	var panel: float = float(w.trait_stack.aggregate_panel().get("add_hp", 0.0))
	var mult := 1.0
	for tb in w.trait_stack.traits:
		if tb.data.id == &"AFF_HP_UP":
			mult = float(tb.value_mult)
	_check("⑦一致性：血条 +%.1f == 面板 +%.1f == 4×25×1.6=160（M1 修复：直挂同乘 value_mult）"
		% [hp_gain, panel],
		absf(hp_gain - 160.0) < 1e-6 and absf(panel - 160.0) < 1e-6,
		"hp=%.2f panel=%.2f mult=%.2f" % [hp_gain, panel, mult])
	_check("⑦质变恰触发一次：value_mult==1.6（幂等守卫）", absf(mult - 1.6) < 1e-9,
		"mult=%.3f" % mult)
	# 清场：血量锚还原 + 槽位摘除
	_gl.player.set("max_hp", hp0)
	_gl.player.set("hp", hp0)
	for si in range(_gl.player.weapon_slots.size()):
		if _gl.player.weapon_slots[si] == w:
			_gl.player.weapon_slots[si] = null
	w.queue_free()
	Meta.set_run_map(map_save)

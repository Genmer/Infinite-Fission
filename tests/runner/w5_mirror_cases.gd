# tests/runner/w5_mirror_cases.gd
# R187 W5「万镜回廊」棱镜镜面军团用例体（由 test_w5_mirror.gd 入口加载）。
# 真源：R187_WEAPON_REWORK §2.2 五方向定案（验收 1-9 映射 + 数据真删/激光镜帽/
# 会话态语义）。共享侧契约：player._mirror_images 容器/make_mirror_image 白板构造/
# register_mirror 绝对帽 5/mirror_capacity 镜数/deterministic_source_pick 确定性重推导/
# clear_mirrors 重开全清——本套件按已落地共享 API 断言（集成对账）。
extends RefCounted

const DT := 1.0 / 120.0
const DT60 := 1.0 / 60.0
const MAIN_SCENE := "res://scenes/main.tscn"
const RATIO_EPS := 0.0001

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_boot_game_loop()
	_test_data_contract()            # A. .tres 真删 refract 五键 + mirror 四键 + 阈值换装
	_test_whiteboard_inversion()     # 验收 1 白板反向
	_test_prism_buff_conduction()    # 验收 3 吃棱镜 buff 逐层一致 + 满层质变 ×1.6
	_test_mirror_capacity_cap()      # 验收 5 数量帽（L5=3 / MEC_MIRROR_SPLIT×2 → 5 钳）
	_test_refresh_conduction()       # 验收 6 攻速传导 + TEMPO 专精 + rof 钳 + 发射预算
	_test_pointer_axis()             # 验收 7 指向轴（确定性重推导 / WEIGHT / LOCK）
	_test_laser_mirror_cap()         # 激光镜 ≤2 池满降级（mirror_laser_cap）
	_test_r183_mutual_exclusion()    # 验收 8 R183 互斥（复制池排除 W5_prism）
	_test_permanent_inversion()      # 验收 2 永久反向（11s 在场 + _reset 不清）
	_test_ele_single_source()        # 验收 4 ELE 单源防泄漏（驱动 120s 不增长）
	_test_session_state_semantics()  # 会话态（clear_mirrors 全清 + 重推导重建）
	_test_production_wiring()        # 生产接线（add_weapon 分派 → MirrorWeapon 自驱成军）
	_test_w4_source_mirror()         # R191 W4 源镜面（束入池/tick_atk 面板式/缓存失效/束卡锁 W4/束染）
	_teardown_game_loop()
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)


func fail_count() -> int:
	return _fail


# ── 环境装配 ──────────────────────────────────────────────────────
func _boot_game_loop() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "GameLoopUnderTest"
	tree.get_root().add_child(_gl)
	_gl.state = GameConst.GameStatus.MENU
	_gl.current_map_id = &"world_grove"      # map_index 3 ≥ 3 → 满层质变门开（验收 3 ×1.6 可达）
	_gl.start_run()
	_gl.player.set("max_hp", 1000000.0)
	_gl.player.set("hp", 1000000.0)
	_gl.player.unlocked_slots = 6
	_gl.state = GameConst.GameStatus.MENU    # 冻结波次刷怪（用例自管夹具敌）


func _teardown_game_loop() -> void:
	tree.paused = false
	RunSave.clear()
	if _gl != null:
		_gl.free()
		_gl = null


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
	else:
		_fail += 1
		_failures.append("%s（%s）" % [p_name, p_detail])


func _wipe_weapons() -> void:
	# 用例隔离：镜面全清 + 武器槽清空（保留槽位解锁）+ 指向锁/反应注册表复位
	_gl.player.clear_mirrors()
	_gl.player.call(&"set_mirror_locked", false)
	_gl.elemental.clear_reaction_mults()
	var slots: Array = _gl.player.get("weapon_slots")
	for i in range(slots.size()):
		var w: Variant = slots[i]
		if w != null and is_instance_valid(w):
			slots[i] = null
			(w as Node).queue_free()
	_gl.player.unlocked_slots = 6


func _make_prism(p_level: int = 1) -> MirrorWeapon:
	# 棱镜装配（真件 MirrorWeapon——R187 生产形态；注入包透传 player._deps）
	var prism := MirrorWeapon.new()
	prism.setup(_gl.registry.get_weapon(&"W5_prism"), _gl.player, _gl.player.get("_deps"))
	prism.meta_atk_pct = 0.0
	if not _gl.player.equip_weapon(prism):
		prism.free()
		return null
	if p_level > 1:
		prism.level = p_level                # 直置等级（level_up 横幅降噪；曲线同源读取）
	prism.sync_mirrors(true)
	return prism


func _add_source(p_id: StringName) -> WeaponBase:
	return _gl.player.add_weapon(_gl.registry.get_weapon(p_id))


func _drive(p_frames: int, p_dt: float = DT) -> void:
	for i in range(p_frames):
		GameConfig.advance_frame()
		_gl.player.call(&"tick", p_dt, Vector2.ZERO)


func _fixture_enemy(p_id: StringName, p_hp: float) -> EnemyData:
	var d := EnemyData.new()
	d.id = p_id
	d.display_name = String(p_id)
	d.hp_base = p_hp
	d.spd_base = 0.0
	d.dmg_base = 0.0
	d.exp_base = 1.0
	d.hitbox_r = 14.0
	d.resist = [0.0, 0.0, 0.0, 0.0]
	return d


func _spawn_fixtures(p_positions: Array[Vector2]) -> Array[Node2D]:
	# 夹具敌（索敌/开火驱动；静态不移动——玩家侧 tick 手动驱动不经过敌 AI 帧）
	var out: Array[Node2D] = []
	for pos in p_positions:
		var enemy := (_gl.pools[&"enemy"] as EnemyPool).acquire()
		enemy.spawn(_fixture_enemy(&"E_W5_FIXTURE", 100000.0), 1, 0)
		enemy.position = pos
		out.append(enemy)
	_gl.enemy_grid.rebuild(out)
	return out


func _release_fixtures(p_enemies: Array[Node2D]) -> void:
	for e in p_enemies:
		if e != null and is_instance_valid(e):
			(_gl.pools[&"enemy"] as EnemyPool).release(e)
	_gl.enemy_grid.rebuild([] as Array[Node2D])


func _mirror_sources(p_prism: MirrorWeapon) -> Array[StringName]:
	var ids: Array[StringName] = []
	for m in p_prism.mirrors:
		ids.append(m.source_id())
	return ids


# ── A. 数据契约（.tres 真删 refract 五键 + mirror 四键 + 阈值换装） ──────
func _test_data_contract() -> void:
	print("── A. W5 数据契约（折射退役 / 万镜回廊四键 / 阈值换装） ──")
	var data: WeaponData = _gl.registry.get_weapon(&"W5_prism")
	_check("注册表：W5_prism 在册（0 rejected 口径）", data != null and data.form == 1)
	if data == null:
		return
	var laser: Dictionary = data.laser
	_check("真删：refract 五键全部离场（refract_beams）", not laser.has("refract_beams"))
	_check("真删：refract_ratio 离场", not laser.has("refract_ratio"))
	_check("真删：refract_depth 离场", not laser.has("refract_depth"))
	_check("真删：refract_beams_levels 离场", not laser.has("refract_beams_levels"))
	_check("真删：refract_ratio_levels 离场", not laser.has("refract_ratio_levels"))
	_check("新键：mirrors_count_levels = [1,1,2,2,3]",
		laser.has("mirrors_count_levels") and (laser["mirrors_count_levels"] as Array) \
			== [1.0, 1.0, 2.0, 2.0, 3.0], str(laser.get("mirrors_count_levels", {})))
	_check("新键：mirror_ratio_levels = [0.4,0.45,0.5,0.55,0.6]",
		laser.has("mirror_ratio_levels") and (laser["mirror_ratio_levels"] as Array) \
			== [0.4, 0.45, 0.5, 0.55, 0.6], str(laser.get("mirror_ratio_levels", {})))
	_check("新键：mirror_budget_per_s = 600（镜面组发射预算落 W5 数据不落全局表）",
		is_equal_approx(float(laser.get("mirror_budget_per_s", 0.0)), 600.0))
	_check("新键：mirror_laser_cap = 2（激光镜 ≤2 面）",
		int(laser.get("mirror_laser_cap", -1)) == 2)
	# 锚束不动（校准锚：tick_atk 7/9/11/14/15 × 5 跳/s）
	var atks: Array[float] = []
	for lv in data.upgrade_table:
		atks.append(float(lv.base_atk))
	_check("锚束：tick_atk 曲线 7/9/11/14/15 不动（rof 5×5 跳/s）",
		atks == [7.0, 9.0, 11.0, 14.0, 15.0] and float(data.upgrade_table[0].rof) == 5.0,
		str(atks))
	# 阈值换装：删 3 条弹道死声明 → TH_MIRROR_CHOIR + TH_CRIT_SHARD 0.35
	var ids: Array[StringName] = []
	for tt in data.threshold_traits:
		ids.append(StringName(str(tt.get("threshold_id", ""))))
	_check("阈值：TH_MIRROR_CHOIR 在册（mirror_count ≥ 3）",
		ids.has(&"TH_MIRROR_CHOIR") and _threshold_of(data, &"TH_MIRROR_CHOIR") == 3.0)
	_check("阈值：TH_CRIT_SHARD 0.6 → 0.35",
		ids.has(&"TH_CRIT_SHARD") and _threshold_of(data, &"TH_CRIT_SHARD") == 0.35)
	_check("阈值：弹道死三声明退役（SIZE_NOVA/FRACTAL_ECHO/BOUNCE_ETERNAL）",
		not ids.has(&"TH_SIZE_NOVA") and not ids.has(&"TH_FRACTAL_ECHO")
		and not ids.has(&"TH_BOUNCE_ETERNAL"), str(ids))
	# DataValidator 全量零 error（W5 删 refract 后零告警口径）
	var verdicts: Array = DataValidator.new().validate_weapon(data)
	var errors: Array = []
	for v in verdicts:
		if String(v.get("severity", "error")) == "error":
			errors.append(v)
	_check("校验：validate_weapon 零 error（新键过域 + 真删零告警）", errors.is_empty(),
		str(errors))
	# 读感退役：文案禁「折射/分光」且含「镜」
	var note := GameConst.weapon_note("W5_prism")
	_check("读感：weapon_note 含「镜」且不含「折射/分光」",
		note.contains("镜") and not note.contains("折射") and not note.contains("分光"), note)
	_check("读感：display_name 去「折射」",
		not data.display_name.contains("折射"), data.display_name)


func _threshold_of(p_data: WeaponData, p_id: StringName) -> float:
	for tt in p_data.threshold_traits:
		if StringName(str(tt.get("threshold_id", ""))) == p_id:
			return float(tt.get("threshold", -1.0))
	return -1.0


# ── 验收 1. 白板反向（R183 反义：镜面栈=棱镜栈，与源栈零交集） ────────────
func _test_whiteboard_inversion() -> void:
	print("── 验收 1. 白板反向（源挂 buff 零拷贝 / 镜面栈=棱镜栈） ──")
	_wipe_weapons()
	var pistol := _add_source(&"W1_pistol")
	var atk_trait: TraitData = _gl.registry.get_trait(&"AFF_ATK_UP")
	var ign_trait: TraitData = _gl.registry.get_trait(&"ELE_IGNITE")
	var rof_trait: TraitData = _gl.registry.get_trait(&"AFF_ROF_UP")
	_check("前置：源词条在册",
		pistol != null and atk_trait != null and ign_trait != null and rof_trait != null)
	if pistol == null or atk_trait == null or ign_trait == null or rof_trait == null:
		return
	pistol.attach_trait(atk_trait)               # 源武器挂玻璃炮系词条（×2 层）
	pistol.attach_trait(atk_trait)
	pistol.attach_trait(ign_trait)               # ELE 附魔（源侧注册——镜面零交集断言锚）
	var prism := _make_prism(1)
	if prism == null:
		_check("棱镜装配", false)
		return
	prism.attach_trait(rof_trait)                # 棱镜自身挂卡（镜面栈非空——逐层一致非平凡断言）
	var img: MirrorImage = null if prism.mirrors.is_empty() else prism.mirrors[0]
	_check("棱镜装配（真件 MirrorWeapon + 1 镜位 L1）", img != null,
		str(prism.mirrors.size()))
	if img == null:
		return
	var stack: TraitStack = img.trait_stack
	_check("白板：镜面栈 == 棱镜栈逐层一致（含挂卡后重拷——层数/逐层品级数值）",
		_stack_matches(stack, prism.trait_stack)
		and stack.size() == 1
		and String((stack.traits[0] as TraitBase).data.id) == &"AFF_ROF_UP", "")
	_check("白板：镜面栈与源武器栈零交集（源词条零拷贝）",
		_stack_disjoint_from(stack, pistol.trait_stack), "")
	_check("白板：镜面等级 = 源等级", int(img.level) == int(pistol.level))
	var expected_meta := (1.0 + float(pistol.meta_atk_pct)) * 0.4 - 1.0
	_check("强度：镜面面板 = 源面板 × mirror_ratio(0.40)",
		absf(float(img.meta_atk_pct) - expected_meta) <= RATIO_EPS
		and absf(float(img.build_panel_snapshot().get("base_atk", 0.0))
			- float(pistol.build_panel_snapshot().get("base_atk", 0.0)) * 0.4) <= RATIO_EPS,
		"%.4f vs %.4f" % [float(img.meta_atk_pct), expected_meta])
	_check("ELE 单源：镜面 uid 不在反应乘区注册表（只继承元素色）",
		not _reaction_sources().has(int(img.uid)))
	_wipe_weapons()


func _stack_matches(p_a: TraitStack, p_b: TraitStack) -> bool:
	if p_a.size() != p_b.size():
		return false
	for i in range(p_a.traits.size()):
		var ta: TraitBase = p_a.traits[i]
		var tb: TraitBase = p_b.traits[i]
		if ta.data == null or tb.data == null or ta.data.id != tb.data.id:
			return false
		if ta.layers != tb.layers or ta.layer_values.size() != tb.layer_values.size():
			return false
		if not is_equal_approx(float(ta.value_mult), float(tb.value_mult)):
			return false
		for k in range(ta.layer_values.size()):
			if not is_equal_approx(ta.layer_values[k], tb.layer_values[k]):
				return false
	return true


func _stack_disjoint_from(p_a: TraitStack, p_b: TraitStack) -> bool:
	for ta in p_a.traits:
		for tb in p_b.traits:
			if ta.data != null and tb.data != null and ta.data.id == tb.data.id:
				return false
	return true


func _reaction_sources() -> Array:
	var reg: Variant = _gl.elemental.get("_reaction_mults")
	return (reg as Dictionary).keys() if reg is Dictionary else []


# ── 验收 3. 吃棱镜 buff 逐层一致 + 满层质变 ×1.6 ─────────────────────────
func _test_prism_buff_conduction() -> void:
	print("── 验收 3. 吃棱镜 buff（逐层一致 + 满层质变 ×1.6） ──")
	_wipe_weapons()
	_add_source(&"W1_pistol")
	var prism := _make_prism(1)
	var atk_trait: TraitData = _gl.registry.get_trait(&"AFF_ATK_UP")
	if prism == null or atk_trait == null:
		_check("前置：AFF_ATK_UP 在册", atk_trait != null)
		return
	prism.attach_trait(atk_trait)
	prism.attach_trait(atk_trait)
	prism.attach_trait(atk_trait)                # stack_max=3 → 满层质变 ×1.6（grove 门开）
	_check("前置：棱镜栈 AFF_ATK_UP 满 3 层", prism.trait_stack.size() == 1
		and int((prism.trait_stack.traits[0] as TraitBase).layers) == 3)
	if prism.mirrors.is_empty():
		_check("镜面在场", false)
		return
	var img: MirrorImage = prism.mirrors[0]
	_check("传导：镜面栈同 id 同层（attach 即全镜生效）",
		_stack_matches(img.trait_stack, prism.trait_stack), "")
	var m_tb: TraitBase = img.trait_stack.traits[0]
	_check("质变：镜面继承满层质变 ×1.6（value_mult）",
		is_equal_approx(float(m_tb.value_mult), WeaponBase.MILESTONE_VALUE_MULT),
		str(m_tb.value_mult))
	_check("面板：镜面 add_atk 聚合 == 棱镜聚合（逐层品级 R12c 口径）",
		absf(float(img.trait_stack.aggregate_panel().get("add_atk", 0.0))
			- float(prism.trait_stack.aggregate_panel().get("add_atk", 0.0))) <= RATIO_EPS)
	_wipe_weapons()


# ── 验收 5. 数量帽（L5 基线 3 / MEC_MIRROR_SPLIT×2 → 5 钳 / 槽位零污染） ───
func _test_mirror_capacity_cap() -> void:
	print("── 验收 5. 数量帽（等级曲线 + MEC_MIRROR_SPLIT，绝对帽 5） ──")
	_wipe_weapons()
	_add_source(&"W1_pistol")
	var prism := _make_prism(5)
	_check("L5 基线：_mirror_images.size() == 3（等级曲线 [1,1,2,2,3]）",
		prism != null and _gl.player.mirror_count() == 3,
		str(_gl.player.mirror_count()))
	var split: TraitData = _gl.registry.get_trait(&"MEC_MIRROR_SPLIT")
	_check("新词条：MEC_MIRROR_SPLIT 已上架（required_weapon=[W5_prism]）",
		split != null and (split.params.get("required_weapon", []) as Array).has(&"W5_prism"))
	if prism == null or split == null:
		return
	prism.attach_trait(split)
	prism.attach_trait(split)
	_check("数量帽：MEC_MIRROR_SPLIT×2 → _mirror_images.size() == 5（3+2）",
		_gl.player.mirror_count() == 5 and prism.mirrors.size() == 5,
		str(_gl.player.mirror_count()))
	_check("数量帽：第 3 张 MEC_MIRROR_SPLIT 被 stack_max=2 拒绝",
		not prism.attach_trait(split))
	_check("数量帽：再挂钳制在 5（绝对帽）", _gl.player.mirror_count() == 5)
	var spare := BallisticWeapon.new()
	spare.setup(_gl.registry.get_weapon(&"W1_pistol"), _gl.player, _gl.player.get("_deps"))
	_check("数量帽：register_mirror 超帽拒绝 + mirror_rejected 计数（第 6 面不入册）",
		not _gl.player.register_mirror(spare, 5)
		and DebugStats.get_counter(&"mirror_rejected") > 0
		and _gl.player.mirror_count() == 5)
	spare.free()
	var slots: Array = _gl.player.get("weapon_slots")
	var polluted := false
	for w in slots:
		if w != null and (w is MirrorImage or (w as WeaponBase).get("is_mirror_image")):
			polluted = true
	_check("隔离：镜面 ∉ weapon_slots（卡候选集/选卡目标零污染）", not polluted)
	_wipe_weapons()


# ── 验收 6. 攻速传导 + 镜面奏鸣 + rof 钳 + 发射预算 ───────────────────────
func _test_refresh_conduction() -> void:
	print("── 验收 6. 攻速传导 / 镜面奏鸣 / rof 钳 30/s / 发射预算 600 发/s ──")
	_wipe_weapons()
	_gl.player.rof_mult = 1.0
	_add_source(&"W2_gatling")
	var prism := _make_prism(1)
	if prism == null or prism.mirrors.is_empty():
		_check("前置：镜面在场", false)
		return
	var img: MirrorImage = prism.mirrors[0]
	# ① refresh 同倍率传导（AFF_ROF/过载咆哮——player.refresh_weapon_intervals 扩扫镜面）
	var i0 := float(img._fire_interval())
	var p0 := float(prism._fire_interval())
	_gl.player.rof_mult = 2.0
	_gl.player.refresh_weapon_intervals()
	var i1 := float(img._fire_interval())
	var p1 := float(prism._fire_interval())
	_check("传导：refresh 后镜面 _fire_interval 与本体同倍率更新（×0.5）",
		absf(i1 - i0 * 0.5) <= i0 * 0.02 and absf(p1 - p0 * 0.5) <= p0 * 0.02,
		"%.4f→%.4f / %.4f→%.4f" % [i0, i1, p0, p1])
	_gl.player.rof_mult = 1.0
	_gl.player.refresh_weapon_intervals()
	# ② MEC_MIRROR_TEMPO：仅镜面攻速 +15%/层 ×2（本体不加成）
	var tempo: TraitData = _gl.registry.get_trait(&"MEC_MIRROR_TEMPO")
	_check("新词条：MEC_MIRROR_TEMPO 已上架", tempo != null)
	if tempo != null:
		var p_base := float(prism._fire_interval())
		prism.attach_trait(tempo)
		prism.attach_trait(tempo)                # ×2 层（stack_max=2 → +30%）
		_check("奏鸣：镜面攻速 +15%×2（_tempo_mult 1.30）",
			is_equal_approx(float(img._tempo_mult), 1.30), str(img._tempo_mult))
		_check("奏鸣：本体节拍不受 TEMPO 影响（仅镜面分叉）",
			is_equal_approx(float(prism._fire_interval()), p_base))
	# ③ rof 钳 30/s（单镜射速帽——满奏鸣/满 ROF 构筑不越性能护栏）
	_gl.player.rof_mult = 10.0
	_gl.player.refresh_weapon_intervals()
	_check("护栏：镜面 rof 钳 30/s（interval ≥ 1/30）",
		float(img._fire_interval()) >= 1.0 / 30.0 - 0.0001,
		"%.4f" % float(img._fire_interval()))
	_gl.player.rof_mult = 1.0
	_gl.player.refresh_weapon_intervals()
	# ④ 发射预算：超预算该拍静默跳过 → 窗翻转恢复（真实开火计费断言；节拍窗口
	# 0.5s/0.25s/0.5s 均避开 1.0s 翻转边界——翻转点只在恢复段内确定性发生）
	_gl.player.position = Vector2(360.0, 900.0)
	var fixtures := _spawn_fixtures([Vector2(360.0, 700.0)] as Array[Vector2])
	_drive(60)                                   # 0.5s：镜面照加特林节拍开火（预算内）
	_check("预算：预算内正常开火（fired_shots_total > 0 且组计费 ≤ 600）",
		img.fired_shots_total > 0.0 and float(prism.get("_budget_spent")) <= 600.0,
		"%.1f / %.1f" % [img.fired_shots_total, float(prism.get("_budget_spent"))])
	prism.budget_spend(600.0)                    # 手动灌满预算窗（600 发/s 护栏触发位）
	var frozen := float(img.fired_shots_total)
	_drive(30)                                   # 0.25s：预算耗尽 → 静默跳过（窗口 0.75 < 1 不翻转）
	_check("预算：超预算该拍静默跳过（发射冻结 + mirror_budget_skipped 计数）",
		is_equal_approx(img.fired_shots_total, frozen)
		and DebugStats.get_counter(&"mirror_budget_skipped") > 0,
		"%.1f vs %.1f / skipped %d" % [img.fired_shots_total, frozen,
			DebugStats.get_counter(&"mirror_budget_skipped")])
	_drive(60)                                   # 0.5s：滚动窗翻转（1.25s 处）→ 预算恢复
	_check("预算：窗翻转预算恢复（恢复连射）", img.fired_shots_total > frozen
		and bool(prism.budget_available()))
	_release_fixtures(fixtures)
	_wipe_weapons()


# ── 验收 7. 指向轴（确定性重推导 / WEIGHT 最肥镜像 / LOCK 锁定） ──────────
func _test_pointer_axis() -> void:
	print("── 验收 7. 指向轴（确定性 / MEC_MIRROR_WEIGHT / MEC_MIRROR_LOCK） ──")
	_wipe_weapons()
	_add_source(&"W1_pistol")
	_add_source(&"W2_gatling")
	_add_source(&"W3_shotgun")
	var prism := _make_prism(5)                  # L5 → 3 镜位
	_check("前置：3 镜位在场", prism != null and prism.mirrors.size() == 3)
	if prism == null:
		return
	var picks_a := _mirror_sources(prism)
	# ① 确定性重推：同组合重放（棱镜重建 → 同 seed 逐项一致）
	_gl.player.clear_mirrors()
	prism.queue_free()
	var slots: Array = _gl.player.get("weapon_slots")
	for i in range(slots.size()):
		if slots[i] != null and (slots[i] as WeaponBase).data.id == &"W5_prism":
			slots[i] = null
	var prism2 := _make_prism(5)
	var picks_b := _mirror_sources(prism2)
	_check("指向：同组合重放逐项一致（武器槽序+固定哈希确定性流）", picks_a == picks_b,
		"%s vs %s" % [str(picks_a), str(picks_b)])
	# ② WEIGHT：镜面恒指向面板 DPS 最高武器
	var weight: TraitData = _gl.registry.get_trait(&"MEC_MIRROR_WEIGHT")
	_check("新词条：MEC_MIRROR_WEIGHT 已上架（exclusive_group=prism_pointer）",
		weight != null and String(weight.params.get("exclusive_group", "")) == "prism_pointer")
	if weight != null:
		prism2.attach_trait(weight)
		var expected := _max_dps_id()
		var all_hit := not prism2.mirrors.is_empty()
		for m in prism2.mirrors:
			if m.source_id() != expected:
				all_hit = false
		_check("指向：MEC_MIRROR_WEIGHT 生效（全镜 → 面板 DPS 最高武器 %s）" % expected,
			all_hit and expected != StringName(&""), str(_mirror_sources(prism2)))
	# ③ LOCK：既有指向固化（获新武器不重掷）——独立净场（WEIGHT 互斥组语义不共存）
	var lock: TraitData = _gl.registry.get_trait(&"MEC_MIRROR_LOCK")
	_check("新词条：MEC_MIRROR_LOCK 已上架", lock != null)
	if lock == null:
		_wipe_weapons()
		return
	_gl.player.clear_mirrors()
	for i in range(slots.size()):
		var w_v: Variant = slots[i]
		if w_v != null and is_instance_valid(w_v) \
				and (w_v as WeaponBase).data.id == &"W5_prism":
			slots[i] = null
			(w_v as Node).queue_free()
	var prism3 := _make_prism(5)
	if prism3 == null:
		_check("LOCK：棱镜重建", false)
		_wipe_weapons()
		return
	prism3.attach_trait(lock)
	var locked_picks := _mirror_sources(prism3)
	_check("指向：LOCK 挂载态同步（player._mirror_locked）",
		bool(_gl.player.get("_mirror_locked")))
	_add_source(&"W6_micro_missile")             # 获新武器 → 组合签名变化
	prism3.sync_mirrors(true)
	_check("指向：LOCK 后不重掷（既有镜位指向不变）",
		_mirror_sources(prism3).size() >= locked_picks.size()
		and _prefix_equals(_mirror_sources(prism3), locked_picks),
		"%s vs %s" % [str(_mirror_sources(prism3)), str(locked_picks)])
	_wipe_weapons()


func _max_dps_id() -> StringName:
	var best := StringName(&"")
	var best_dps := -1.0
	for w in (_gl.player.get("weapon_slots") as Array):
		if w == null or not is_instance_valid(w) or (w as WeaponBase).data == null:
			continue
		var wb := w as WeaponBase
		if String(wb.data.id) == "W5_prism":
			continue
		var atk := float(wb.build_panel_snapshot().get("base_atk", 0.0))
		var dps := atk * float(wb.get_stat(&"rof")) \
			if wb.data.form == GameConst.WeaponForm.BALLISTIC \
			else atk / maxf(float(wb.get_stat(&"cd")), 0.01)
		if dps > best_dps:
			best_dps = dps
			best = wb.data.id
	return best


func _prefix_equals(p_full: Array[StringName], p_prefix: Array[StringName]) -> bool:
	if p_full.size() < p_prefix.size():
		return false
	for i in range(p_prefix.size()):
		if p_full[i] != p_prefix[i]:
			return false
	return true


# ── 激光镜帽（mirror_laser_cap=2：共享 laser 池护栏 + 静默降级） ──────────
func _test_laser_mirror_cap() -> void:
	print("── 激光镜帽（mirror_laser_cap ≤2 / 池满静默降级） ──")
	_wipe_weapons()
	_add_source(&"W4_pulse_beam")
	_add_source(&"W4_pulse_beam")
	_add_source(&"W4_pulse_beam")                # 3 个激光形态源（> 帽 2）
	var rejected_before := DebugStats.get_counter(&"mirror_rejected")
	var prism := _make_prism(5)
	_check("激光镜帽：3 激光源 → 镜面数 == 2（第 3 面休眠 + mirror_rejected）",
		prism != null and prism.mirrors.size() == 2
		and DebugStats.get_counter(&"mirror_rejected") > rejected_before,
		"%d 面 / 拒 %d" % [prism.mirrors.size() if prism else -1,
			DebugStats.get_counter(&"mirror_rejected") - rejected_before])
	_wipe_weapons()
	_add_source(&"W4_pulse_beam")
	_add_source(&"W4_pulse_beam")
	_add_source(&"W1_pistol")                    # 激光×2 + 非激光替补候选
	prism = _make_prism(5)
	var laser_mirrors := 0
	if prism != null:
		for m in prism.mirrors:
			if m.data != null and m.data.form == GameConst.WeaponForm.LASER:
				laser_mirrors += 1
	_check("激光镜帽：非激光候选在册 → 镜面数保持 3 且激光镜 ≤ 2",
		prism != null and prism.mirrors.size() == 3 and laser_mirrors <= 2,
		"%d 面（激光 %d）" % [prism.mirrors.size() if prism else -1, laser_mirrors])
	_wipe_weapons()


# ── 验收 8. R183 互斥（复制池排除 W5_prism / 镜面与复制体互不包含） ────────
func _test_r183_mutual_exclusion() -> void:
	print("── 验收 8. R183 互斥（临时件永不产出永久件） ──")
	_wipe_weapons()
	_add_source(&"W1_pistol")
	var prism := _make_prism(1)
	_check("前置：镜面在场", prism != null and _gl.player.mirror_count() == 1)
	if prism == null:
		return
	Meta.character_id = &"noah"
	Meta.achievements_done["wave_20"] = true     # 诺亚解锁门（成就「深入敌阵」——测试环境直授）
	_gl.player.set_character(&"noah")
	_gl.player.set("max_hp", 1000000.0)
	_gl.player.set("hp", 1000000.0)
	_gl.player.set("skill_cd_left", 0.0)
	_check("互斥：诺亚技能施放（镜面在场）", bool(_gl.player.call(&"activate_skill")))
	var copies: Array = _gl.player.get("_summon_copies")
	var no_prism_copy := true
	for c in copies:
		if c != null and is_instance_valid(c) \
				and String((c as WeaponBase).data.id) == "W5_prism":
			no_prism_copy = false
	_check("互斥：复制池排除 W5_prism（复制体无一为棱镜）", no_prism_copy,
		str(copies.size()))
	_check("互斥：_mirror_images 与 _summon_copies 互不包含",
		_mirror_disjoint(copies))
	_check("互斥：施放后镜面原样（永久件不受临时件影响）",
		_gl.player.mirror_count() == 1)
	_drive(1260)                                 # 10.5s @120Hz（> 10s 僚机持续期）
	_check("互斥：复制体到期回收而镜面仍在（0.17× vs 永续 0.40~0.60 对照）",
		(_gl.player.get("_summon_copies") as Array).is_empty()
		and _gl.player.mirror_count() == 1)
	_wipe_weapons()


func _mirror_disjoint(p_copies: Array) -> bool:
	for prism in (_gl.player.get("weapon_slots") as Array):
		if prism == null or not is_instance_valid(prism) or not (prism is MirrorWeapon):
			continue
		for img in (prism as MirrorWeapon).mirrors:
			for c in p_copies:
				if c == img or c == (img as MirrorImage).inner:
					return false
	return true


# ── 验收 2. 永久反向（11s 在场指向不变 + _reset_skill_temp_state 不清） ───
func _test_permanent_inversion() -> void:
	print("── 验收 2. 永久反向（>SUMMON_DURATION 在场 / 临时态收口不含镜面） ──")
	_wipe_weapons()
	_add_source(&"W1_pistol")
	var prism := _make_prism(1)
	if prism == null or prism.mirrors.is_empty():
		_check("前置：镜面在场", false)
		return
	var img: MirrorImage = prism.mirrors[0]
	var src_before := img.source_id()
	_drive(1320)                                 # 11s @120Hz（> 10s 僚机持续期）
	_check("永久：驱动 11s 镜面仍在场", _gl.player.mirror_count() == 1
		and is_instance_valid(img))
	_check("永久：指向不变（无重掷——组合签名未变）", img.source_id() == src_before)
	_check("永久：镜面不在 _summon_copies",
		(_gl.player.get("_summon_copies") as Array).find(img) < 0
		and (img.get_parent() == _gl.player))
	_gl.player.call(&"_reset_skill_temp_state")
	_check("永久：_reset_skill_temp_state 后 _summon_copies 空而 _mirror_images 原样",
		(_gl.player.get("_summon_copies") as Array).is_empty()
		and _gl.player.mirror_count() == 1 and is_instance_valid(img))
	_wipe_weapons()


# ── 验收 4. ELE 单源防泄漏（注册源数 == 1；驱动 120s 不增长） ─────────────
func _test_ele_single_source() -> void:
	print("── 验收 4. ELE 单源（棱镜 uid 单源注册 / 120s 雪球锁死） ──")
	_wipe_weapons()
	_add_source(&"W1_pistol")
	var prism := _make_prism(5)                  # 3 镜
	if prism == null or prism.mirrors.size() != 3:
		_check("前置：3 镜在场", false)
		return
	var rxn: TraitData = _gl.registry.get_trait(&"ELE_REACTION_VOID")
	_check("前置：ELE_REACTION_VOID（reaction_mult）在册",
		rxn != null and rxn.params.has("reaction_mult"))
	if rxn == null:
		return
	_check("前置：棱镜挂卡前注册表为空", _reaction_sources().is_empty())
	prism.attach_trait(rxn)                      # 金 ELE 反应卡挂棱镜 → 本体 uid 单源
	var sources := _reaction_sources()
	_check("单源：反应乘区注册源数 == 1（仅棱镜 uid）", sources.size() == 1
		and int(sources[0]) == int(prism.uid), str(sources))
	var leaked := false
	for img in prism.mirrors:                    # 逐镜 uid 断言（对照 R183 逐副本注册）
		if _reaction_sources().has(int(img.uid)) \
				or (img.inner != null and _reaction_sources().has(int(img.inner.uid))):
			leaked = true
	_check("单源：3 镜均零注册（ELE 只继承元素色）", not leaked)
	for i in range(7200):                        # 驱动 120s @ 60Hz（重同步/重拍全程）
		GameConfig.advance_frame()
		_gl.player.call(&"tick", DT60, Vector2.ZERO)
		if i % 600 == 0:
			prism.sync_mirrors(true)             # 周期性重掷编排（读档/波首模拟）
	_check("单源：驱动 120s（含周期重排）注册源数仍 == 1（不增长）",
		_reaction_sources().size() == 1, str(_reaction_sources()))
	_wipe_weapons()


# ── 会话态语义（clear_mirrors 重开全清 + 重开重建确定性重推导） ───────────
func _test_session_state_semantics() -> void:
	print("── 会话态语义（重开全清 / 读档重推导 / 存档层冻结） ──")
	_wipe_weapons()
	_add_source(&"W1_pistol")
	_add_source(&"W2_gatling")
	var prism := _make_prism(5)
	_check("前置：3 镜在场", prism != null and _gl.player.mirror_count() == 3)
	if prism == null:
		return
	var picks := _mirror_sources(prism)
	var img_before: MirrorImage = prism.mirrors[0]
	_gl.player.clear_mirrors()
	_check("会话态：clear_mirrors 全清玩家容器（重开口）",
		_gl.player.mirror_count() == 0
		and (is_instance_valid(img_before) and img_before.is_queued_for_deletion()))
	prism.sync_mirrors(true)                     # 读档重建口径：编排门感知外部清空 → 确定性重推导
	_check("会话态：重推导逐项一致（固定哈希——不依赖任何存档键）",
		_mirror_sources(prism) == picks and _gl.player.mirror_count() == 3
		and prism.mirrors[0] != img_before, "")
	_check("会话态：RunSave 口径零新增键（user:// 层未触碰）",
		not RunSave.exists() or RunSave.load_run().is_empty()
		or not RunSave.load_run().has("mirrors"))
	_wipe_weapons()


# ── 生产接线（_instantiate_weapon 按 id 分派 W5 → MirrorWeapon） ──────────
func _test_production_wiring() -> void:
	print("── 生产接线（add_weapon 形态分派 → MirrorWeapon 自驱编排） ──")
	_wipe_weapons()
	var prism_v: Variant = _gl.player.add_weapon(_gl.registry.get_weapon(&"W5_prism"))
	_check("生产接线：add_weapon(W5_prism) 实例化 MirrorWeapon（非裸 LaserWeapon）",
		prism_v is MirrorWeapon)
	if not (prism_v is MirrorWeapon):
		_wipe_weapons()
		return
	var prism := prism_v as MirrorWeapon
	_add_source(&"W1_pistol")
	_drive(10)                                   # 玩家同拍驱动 → 棱镜编排自驱（无显式 sync）
	_check("生产接线：玩家 tick 自驱成军（镜面自动入册）",
		_gl.player.mirror_count() == 1 and prism.mirrors.size() == 1,
		str(_gl.player.mirror_count()))
	_wipe_weapons()


# ── R191 W4 源镜面（束入共享池 / tick_atk 面板式 / apply_state 缓存失效 /
#    直挂 SPLIT_PRISM 束段指纹==1 / 七束卡 mount 门锁 W4 / copy_tint 灰染传导） ──
func _test_w4_source_mirror() -> void:
	print("── R191 W4 源镜面（tick_atk 面板式 / 缓存失效 / 束卡锁 W4 / 灰染传导） ──")
	_wipe_weapons()
	_gl.player.rof_mult = 1.0
	var w4 := _add_source(&"W4_pulse_beam")      # 源武器（L1 base_atk 6，meta=0 夹具）
	if w4 != null:
		w4.meta_atk_pct = 0.0
		w4.cooldown_left = 9999.0                # 源静默（池账 +1 断言隔离）
	var prism := _make_prism(1)                  # L1 → mirror_ratio 0.40
	if prism != null:
		prism.cooldown_left = 9999.0             # 棱镜锚束静默（同上）
	_check("前置：W4 源 + 棱镜装配且 1 镜位指向 W4",
		w4 != null and prism != null and prism.mirrors.size() == 1
		and prism.mirrors[0].source_id() == &"W4_pulse_beam",
		"%s" % str(_mirror_sources(prism) if prism != null else []))
	if w4 == null or prism == null or prism.mirrors.is_empty():
		_wipe_weapons()
		return
	var img: MirrorImage = prism.mirrors[0]
	var inner := img.inner
	# ① 束染构造口：make_mirror_image 产物 copy_tint == true（bool——此前写 Color 被
	# LaserWeapon 类型化 bool 字段静默丢弃，镜面 W4 束恒玩家蓝的缺陷修复锚）
	_check("束染：inner.copy_tint == true（bool 类型，非 Color）",
		inner != null and typeof(inner.get("copy_tint")) == TYPE_BOOL
		and bool(inner.get("copy_tint")),
		str(typeof(inner.get("copy_tint")) if inner != null else -1))
	if inner == null:
		_wipe_weapons()
		return
	# ② 镜面出束：夹具敌 + 玩家驱动 → inner 主束入共享 laser 池（源/棱镜均已静默）
	var pool := _gl.pools[&"laser"] as LaserBeamPool
	var live0: int = int(pool.stats()["live"])
	_gl.player.position = Vector2(360.0, 900.0)
	var fixtures := _spawn_fixtures([Vector2(360.0, 700.0)] as Array[Vector2])
	_drive(60)                                   # 0.5s @120Hz：镜面首拍即开火
	var live1: int = int(pool.stats()["live"])
	_check("束入池：镜面开火后共享 laser 池活束数 +1（源/棱镜静默隔离）",
		live1 == live0 + 1, "%d→%d" % [live0, live1])
	# ③ tick_atk 面板式：源 base_atk × mirror_ratio 0.40（meta=0 夹具；此前 _spawn_beam
	# 裸 get_current_atk() 使 meta_atk_pct 在激光路径零消费——镜面恒 100% 源强度的缺陷锚）
	var mbeam: LaserBeam = null
	for b in pool.get_children():
		if b is LaserBeam and (b as LaserBeam).is_live() and (b as LaserBeam).weapon == inner:
			mbeam = b
	var expect_atk := float(w4.get_stat(&"base_atk")) * 0.40
	_check("束锚：镜面束 tick_atk == 源 base_atk×0.40 ±1e-6（6×0.40=2.4）",
		mbeam != null and absf(mbeam.tick_atk - expect_atk) <= 0.000001,
		"%.6f vs %.6f" % [mbeam.tick_atk if mbeam != null else -1.0, expect_atk])
	_check("束染：镜面束 gray_tint == true（R183 灰染通道传导）",
		mbeam != null and mbeam.gray_tint)
	_release_fixtures(fixtures)
	# ④ apply_state 面板缓存失效：开火已烧 inner 旧栈缓存 → 棱镜挂 crit/atk 卡 +
	# sync_mirrors(true) 重铺 → 快照随新栈聚合（非旧值；失效点此前漏 apply_state）
	var crit_old_snap: Dictionary = inner.build_panel_snapshot()
	var outer_old_snap: Dictionary = img.build_panel_snapshot()
	var crit := _gl.registry.get_trait(&"AFF_CRIT_RATE")
	var atk := _gl.registry.get_trait(&"AFF_ATK_UP")
	_check("前置：AFF_CRIT_RATE(add_crit)/AFF_ATK_UP(add_atk) 在册",
		crit != null and String(crit.pool_id) == "add_crit"
		and atk != null and String(atk.pool_id) == "add_atk")
	if crit == null or atk == null:
		_wipe_weapons()
		return
	prism.attach_trait(crit)
	prism.attach_trait(atk)
	prism.sync_mirrors(true)                     # 复用镜位 apply_state 重铺（新栈 copy_full）
	var agg: Dictionary = inner.trait_stack.aggregate_panel()
	var crit_cap := 1.0
	if GameConfig.balance != null:
		crit_cap = GameConfig.balance.cap_crit_rate
	var expect_crit := clampf(float(w4.data.crit_rate) + float(agg.get("add_crit", 0.0)),
		0.0, crit_cap)
	var snap: Dictionary = inner.build_panel_snapshot()
	_check("缓存失效：inner 面板 crit_rate == 新栈聚合值（非旧值）",
		absf(float(snap.get("crit_rate", -1.0)) - expect_crit) <= 0.000001
		and absf(float(snap.get("crit_rate", -1.0))
			- float(crit_old_snap.get("crit_rate", -2.0))) > 0.000001,
		"new %.4f / old %.4f / expect %.4f" % [float(snap.get("crit_rate", -1.0)),
			float(crit_old_snap.get("crit_rate", -2.0)), expect_crit])
	var entries: Array = snap.get("add_entries", []) as Array
	_check("缓存失效：inner 面板 add_entries 随新栈（AFF_ATK_UP 条目入场，非旧空表）",
		entries.size() == (inner.trait_stack.aggregate_add_entries() as Array).size()
		and not entries.is_empty(), str(entries.size()))
	var outer_snap: Dictionary = img.build_panel_snapshot()
	_check("缓存失效：外壳身份壳面板同步失效（crit_rate 同新栈）",
		absf(float(outer_snap.get("crit_rate", -1.0)) - expect_crit) <= 0.000001
		and absf(float(outer_snap.get("crit_rate", -1.0))
			- float(outer_old_snap.get("crit_rate", -2.0))) > 0.000001,
		"new %.4f / old %.4f" % [float(outer_snap.get("crit_rate", -1.0)),
			float(outer_old_snap.get("crit_rate", -2.0))])
	# ⑤ 直挂 SPLIT_PRISM：引擎侧硬保证 sub_beams_override==0 → 棱镜束段指纹==1
	#（七束卡 required_weapon 数据侧锁 W4；直挂 attach_trait 不经门由此兜底）
	var split := _gl.registry.get_trait(&"MEC_SPLIT_PRISM")
	_check("前置：MEC_SPLIT_PRISM 在册", split != null)
	if split != null:
		prism.attach_trait(split)
		prism.try_fire()
		_check("束段指纹：直挂 SPLIT_PRISM 后棱镜活束==1（sub_beams_override==0 硬保证）",
			int(prism.get("sub_beams_override")) == 0 and _live_beams(prism).size() == 1,
			"override=%d beams=%d" % [int(prism.get("sub_beams_override")),
				_live_beams(prism).size()])
	# ⑥ 数据门：七张束卡 mount_gate_allows 对 W5_prism 全 false / 对 W4_pulse_beam 全 true
	var beam_cards: Array[StringName] = [&"MEC_SPLIT_PRISM", &"MEC_BEAM_TRACK",
		&"MEC_BEAM_FAN", &"MEC_BEAM_COFOCUS", &"MEC_BEAM_LAG", &"MEC_BEAM_SPECTRA",
		&"MEC_PHASE_SYNC"]
	var gate_ok := true
	var gate_detail: Array[String] = []
	for cid in beam_cards:
		var td: TraitData = _gl.registry.get_trait(cid)
		if td == null:
			gate_ok = false
			gate_detail.append("%s:missing" % String(cid))
			continue
		var on_w5 := CardGenerator.mount_gate_allows(td, prism)
		var on_w4 := CardGenerator.mount_gate_allows(td, w4)
		if on_w5 or not on_w4:
			gate_ok = false
			gate_detail.append("%s:w5=%s/w4=%s" % [String(cid), str(on_w5), str(on_w4)])
	_check("数据门：七张束卡 mount_gate 对 W5_prism 全 false / 对 W4_pulse_beam 全 true",
		gate_ok, str(gate_detail))
	# ⑦ 数据断言：七张 .tres params 均含 required_weapon=[&"W4_pulse_beam"]（原键保留）
	var tres_ok := true
	for cid2 in beam_cards:
		var td2: TraitData = _gl.registry.get_trait(cid2)
		if td2 == null or not ((td2.params.get("required_weapon", []) as Array).has(&"W4_pulse_beam")) \
				or not (td2.params.get("required_forms", []) as Array).has(1):
			tres_ok = false
	_check("数据断言：七张束卡 params 均含 required_weapon=[W4_pulse_beam] 且 required_forms 保留",
		tres_ok)
	_wipe_weapons()


func _live_beams(p_w: WeaponBase) -> Array:
	# 活束集（r187_rework_cases 同款助手——本套件自持一份避免跨套件依赖）
	var out: Array = []
	var beams_v: Variant = p_w.get("active_beams")
	if not (beams_v is Array):
		return out
	for b in (beams_v as Array):
		if b != null and is_instance_valid(b) and b.is_live():
			out.append(b)
	return out

# tests/runner/rxn_channel_cases.gd
# 元素通道用例体（由 test_rxn_channel.gd 入口在 autoload 就绪后运行时加载编译）。
# 覆盖（2026-09 R191 用户反馈「选了火和电没反应 / 只有超导生效 / 普通难度没开？」）：
#   · 通道单元：双元素栈 ON_HIT 按当发宿主元素放行 attach_request（FIR 进 FIR 出——
#     修复前挂载序末位覆写）；单元素栈 {element, value, overrides} 逐字节不变；
#     KIN 宿主放行（直挂通道）；E-03 同帧闸门（第二发须推帧）
#   · ON_SPAWN 守卫：spawn 参数元素不被词条覆写（KIN 中性弹保留附魔染色）
#   · 武器级实弹：双 ELE 卡交替（_shot_element 每发随机 → 实弹真交替，
#     buff_audit 60 采样的实弹通道端）
#   · 端到端：真件 ElementalSystem 双槽成对 → RXN_FIR_LTG 过载触发
#     （E-03 帧闸推进 + 120%ATK 落血 + 双槽清空 + reaction CD 2s）
#   · 数据断言：registry 三附着卡 required_forms=[0,1,2]（近战死卡下架）/ VOID 与
#     ARC_SURGE 无键（全形态保留）；mount_gate_allows 形态门四向；解锁节奏
#     火冰第 2 关 / 感电第 3 关（G1 图鉴反应页条件/解锁句口径）。
#   · R192 反应矩阵（docs/design/R192_ELEMENT_MATRIX.md §4/§13.1）：M0 超导账本修复
#     （持续期重触只刷新·到期按记录 delta 恢复一次=净 0）+ 新 7 类反应行为用例
#     （蒸发 χ1.5×φ 双槽清空不掷暴击 / 冻结 1.2s+IMMUNE_FREEZE 不定身 / 感电链跳>0
#     +shock_chain_cd>0 / 燃烧 burn_layers==5·3.0s / 激化 vuln_timer==3.0 / 绽放 1.5s
#     延迟 r120 副目标落血·主目标双槽已清 / 扩散主目标 χ0.8+至多 3 敌满槽转移（新元素
#     钳制不清零）+ 结晶玩家减伤 ×0.85）+ CD 到期 erase（字典 size 回落）+ 多槽共存
#     按序仅一反应 + 同帧幂等缓存吸收；既有 3 反应数值锁（过载 120%/CD 2s）原文保留。
# 确定性：固定种子 + 固定坐标（pkg3 范式）；E-03 帧闸经 GameConfig.frame_stamp 手动推进。
extends RefCounted

const BALLISTIC_SCENE := "res://scenes/combat/projectiles/ballistic_projectile.tscn"
const ENEMY_SCENE := "res://scenes/combat/enemies/enemy.tscn"
const DT := 1.0 / 120.0

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []

var _proj_pool: ProjectilePool
var _enemy_pool: EnemyPool
var _grid: SpaceGrid
var _pipeline: DamagePipelineStub
var _real_pipeline: DamagePipeline          # 真件（ElementalSystem 反应结算通道）
var _sys: ElementalSystem
var _alive_enemies: Array[Node2D] = []


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(20260926)                             # 全局 RNG 固定种子（实弹采样确定性）
	_ensure_autoloads()
	_test_registry_data()
	_test_mount_gate_forms()
	_test_unlock_rhythm()
	_setup_world()
	_test_channel_unit()
	_test_spawn_guard()
	_test_weapon_alternation()
	_test_reaction_end_to_end()
	_test_matrix_reactions()                   # R192：M0 账本 + 7 类新反应 + CD erase/多槽/幂等
	_teardown_world()
	_summary()


func fail_count() -> int:
	return _fail


# ── 支撑 ──────────────────────────────────────────────────────────
func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("PASS | %s" % p_name)
	else:
		_fail += 1
		_failures.append(p_name)
		print("FAIL | %s | %s" % [p_name, p_detail])


func _summary() -> void:
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  失败项：%s" % f)
	print("════════════════════════════════════════")


func _approx(p_a: float, p_b: float, p_tol: float = 0.001) -> bool:
	return absf(p_a - p_b) <= p_tol


func _bump_frame() -> void:
	GameConfig.frame_stamp += 1                # E-03 帧闸门推进（GameLoop 帧序的测试侧替身）


func _ensure_autoloads() -> void:
	if tree.get_root().get_node_or_null("EventBus") == null:
		_install_autoload("EventBus", "res://autoload/event_bus.gd")
	if tree.get_root().get_node_or_null("GameConfig") == null:
		_install_autoload("GameConfig", "res://autoload/game_config.gd")
	if tree.get_root().get_node_or_null("DebugStats") == null:
		_install_autoload("DebugStats", "res://autoload/debug_stats.gd")


func _install_autoload(p_name: String, p_path: String) -> void:
	var script: GDScript = load(p_path)
	var node: Node = script.new()
	node.name = p_name
	tree.get_root().add_child(node)


func _ele(p_id: StringName) -> TraitData:
	return load("res://resources/traits/%s.tres" % String(p_id)) as TraitData


# ── 1. registry 数据断言（required_forms 键位 / 门不误伤 / 描述口径） ──
func _test_registry_data() -> void:
	print("── registry 数据断言 ──")
	var registry := DataRegistry.new()
	registry.load_all("res://data/manifest.cfg")   # 生产同路径（含 DataValidator 全量校验）
	for id: StringName in [&"ELE_IGNITE", &"ELE_SHOCK", &"ELE_FREEZE"]:
		var t := registry.get_trait(id)
		var forms: Variant = t.params.get("required_forms", null) if t != null else null
		_check("registry：%s 在册且 params.required_forms == [0, 1, 2]（近战死卡下架）" % id,
			t != null and forms is Array and (forms as Array) == [0, 1, 2], str(forms))
	for id: StringName in [&"ELE_REACTION_VOID", &"ELE_ARC_SURGE"]:
		var t2 := registry.get_trait(id)
		_check("registry：%s 无 required_forms 键（全形态保留，不设门）" % id,
			t2 != null and not (t2 as TraitData).params.has("required_forms"))
	var arc := registry.get_trait(&"ELE_ARC_SURGE")
	_check("registry：ELE_ARC_SURGE 描述含「（不附着雷元素）」（防误当电元素卡）",
		arc != null and String(arc.description).contains("（不附着雷元素）"),
		arc.description if arc != null else "<null>")
	var ignite := registry.get_trait(&"ELE_IGNITE")
	var freeze := registry.get_trait(&"ELE_FREEZE")
	var shock := registry.get_trait(&"ELE_SHOCK")
	_check("registry：元素键位锚（IGNITE=FIR / FREEZE=ICE / SHOCK=LTG）",
		int(ignite.params.get("element", -1)) == GameConst.Element.FIR
		and int(freeze.params.get("element", -1)) == GameConst.Element.ICE
		and int(shock.params.get("element", -1)) == GameConst.Element.LTG)


# ── 2. 挂载形态门四向（mount_gate_allows 静态直调） ───────────────
# p_target 形参锁定 WeaponBase——夹具用真件武器（pkg3 _make_weapon 同构映射），
# 仅 setup 不开火（四形态 setup 均只做 super + 字段复位，无池依赖）。
func _form_weapon(p_form: int) -> WeaponBase:
	var d := WeaponData.new()
	d.id = StringName("W_RXN_FORM_%d" % p_form)
	d.form = p_form
	var w: WeaponBase
	match p_form:
		GameConst.WeaponForm.BALLISTIC:
			w = BallisticWeapon.new()
		GameConst.WeaponForm.HOMING:
			w = HomingWeapon.new()
		GameConst.WeaponForm.LASER:
			w = LaserWeapon.new()
		_:
			w = OrbitWeapon.new()
	tree.get_root().add_child(w)
	w.setup(d, null, {})
	return w


func _test_mount_gate_forms() -> void:
	print("── 挂载形态门四向（required_forms = [0, 1, 2]） ──")
	for id: StringName in [&"ELE_IGNITE", &"ELE_SHOCK", &"ELE_FREEZE"]:
		var t := _ele(id)
		var gate_ok := true
		for form: int in [GameConst.WeaponForm.BALLISTIC, GameConst.WeaponForm.LASER,
				GameConst.WeaponForm.HOMING]:
			var w := _form_weapon(form)
			gate_ok = gate_ok and CardGenerator.mount_gate_allows(t, w)
			w.free()
		_check("形态门：%s 投射物三形态（弹道/激光/自导）全放行" % id, gate_ok)
		var melee := _form_weapon(GameConst.WeaponForm.MELEE)
		_check("形态门：%s 近战（W8 有意拆除 ELE 通道）拒绝上架" % id,
			not CardGenerator.mount_gate_allows(t, melee))
		melee.free()


# ── 3. 解锁节奏口径（G1 图鉴反应页条件/解锁句真源；无难度门） ─────
func _test_unlock_rhythm() -> void:
	print("── 解锁节奏（火冰第 2 关 / 感电第 3 关；无难度门） ──")
	Meta.set_run_map(&"")                      # 无局口径注入（_run_map 默认 FIRST_MAP_ID，非空）
	_check("无难度门：无局口径全开（map_index = -1，结算核零难度分支）",
		MechanicGate.map_index() == -1 and MechanicGate.elements_basic_unlocked()
		and MechanicGate.shock_unlocked())
	Meta.set_run_map(MapTable.MAPS[1].id)      # 第 2 关冰原
	_check("第 2 关：火/冰开放；感电未解锁（雷第 3 关起）",
		MechanicGate.elements_basic_unlocked() and not MechanicGate.shock_unlocked())
	Meta.set_run_map(MapTable.MAPS[2].id)      # 第 3 关魔域
	_check("第 3 关：感电开放（过载/超导随之可发生）", MechanicGate.shock_unlocked())
	Meta.set_run_map(&"")                      # 还原无局口径（防跨套件污染）


# ── 世界夹具（pkg3 范式：透传桩弹道 + 真件管线元素结算） ──────────
func _setup_world() -> void:
	_proj_pool = ProjectilePool.new()
	_proj_pool.name = "RxnProjPool"
	tree.get_root().add_child(_proj_pool)
	_proj_pool.setup(&"rxn_test", load(BALLISTIC_SCENE), 64)
	var ep := EnemyPool.new()
	ep.name = "RxnEnemyPool"
	tree.get_root().add_child(ep)
	# 容量 24：全文件 18 处 _spawn_enemy 不归还（几何须存活到 teardown）——R192 反应矩阵
	# 用例扩容后 16 槽耗尽，_cd_erase_and_multi_slot 第 17/18 取出得 null（spawn on Nil）
	ep.setup(&"rxn_enemy", load(ENEMY_SCENE), 24)
	_enemy_pool = ep
	_grid = SpaceGrid.new()
	_grid.configure(Vector2(720, 1280), 192.0)
	_pipeline = DamagePipelineStub.new()
	_real_pipeline = DamagePipeline.new()      # 真件：反应结算内部落血（9b）
	_real_pipeline.set_rng_seed(42)
	_sys = ElementalSystem.new()
	_sys.name = "RxnElementalSystem"
	tree.get_root().add_child(_sys)
	_sys.pipeline = _real_pipeline
	_sys.enemy_grid = _grid
	_alive_enemies.clear()


func _teardown_world() -> void:
	_alive_enemies.clear()
	if _sys != null:
		_sys.free()
		_sys = null
	_real_pipeline = null
	if _proj_pool != null:
		_proj_pool.free()
		_proj_pool = null
	if _enemy_pool != null:
		_enemy_pool.free()
		_enemy_pool = null
	_grid = null
	_pipeline = null


func _make_enemy_data(p_id: String, p_hp: float = 1000.0) -> EnemyData:
	var d := EnemyData.new()
	d.id = StringName(p_id)
	d.display_name = p_id
	d.hp_base = p_hp
	d.spd_base = 0.0                           # 静止敌（几何确定性）
	d.dmg_base = 8.0
	d.exp_base = 3.0
	d.tp_cost = 1.0
	d.hitbox_r = 14.0
	return d


func _spawn_enemy(p_data: EnemyData, p_pos: Vector2) -> Enemy:
	var e := _enemy_pool.acquire() as Enemy
	e.spawn(p_data, 1, 0)
	e.position = p_pos
	_alive_enemies.append(e)
	_grid.rebuild(_alive_enemies)
	return e


func _spawn_proj(p_params: Dictionary) -> ProjectileBase:
	var proj := _proj_pool.acquire() as ProjectileBase
	proj.damage_pipeline = _pipeline
	proj.enemy_grid = _grid
	proj.pool = _proj_pool
	proj.elemental = _sys
	proj.spawn(p_params.duplicate())
	return proj


func _make_ballistic_data() -> WeaponData:
	var d := WeaponData.new()
	d.id = &"W_RXN_PROBE"
	d.display_name = "Rxn 通道探针"
	d.form = GameConst.WeaponForm.BALLISTIC
	d.crit_rate = 0.0
	d.crit_dmg = 2.0
	d.hitbox_r = 6.0
	for i in range(5):
		var ls := WeaponLevelStats.new()
		ls.base_atk = 100.0                        # 面板 100 → 过载 100×1.2 = 120（整数好算）
		ls.rof = 5.0
		ls.cd = 0.5
		ls.pierce = 1
		ls.pellets = 1
		d.upgrade_table.append(ls)
	d.ballistic = {"proj_speed": 100.0, "range": 600.0, "spread_deg": 0.0}
	return d


func _make_weapon(p_data: WeaponData, p_pos: Vector2) -> BallisticWeapon:
	var w := BallisticWeapon.new()
	w.name = "RxnProbeWeapon"
	tree.get_root().add_child(w)
	w.position = p_pos
	w.setup(p_data, null, {
		"pipeline": _pipeline,
		"projectile_pool": _proj_pool,
		"enemy_grid": _grid,
		"laser_pool": null,
		"elemental": _sys,
	})
	return w


func _dual_stack() -> TraitStack:
	# 双元素栈（挂载序：IGNITE(FIR) → SHOCK(LTG)——生产卡架挂载序即派发序）
	var stack := TraitStack.new()
	stack.attach(_ele(&"ELE_IGNITE"))
	stack.attach(_ele(&"ELE_SHOCK"))
	return stack


func _kill_live_projs() -> void:
	for node in _proj_pool.active_projectiles():
		(node as ProjectileBase).nullify()


# ── 4. 通道单元（TraitStack 派发级：attach_request 放行/拦截/E-03） ──
func _test_channel_unit() -> void:
	print("── 通道单元：ON_HIT 按当发宿主元素放行 ──")
	var stack := _dual_stack()
	# FIR 宿主（当发随机元素 = FIR）：FIR 词条放行，LTG 词条被宿主守卫拦下
	var p_fir := _spawn_proj({"position": Vector2(150, 150), "velocity": Vector2.ZERO,
		"lifetime": 10.0, "pierce": 1, "hitbox_radius": 6.0,
		"element": GameConst.Element.FIR, "attach_value": 0.0, "team": 0})
	var ctx_fir := TraitContext.new()
	ctx_fir.event = GameConst.TraitEvent.ON_HIT
	ctx_fir.projectile = p_fir
	stack.dispatch(GameConst.TraitEvent.ON_HIT, ctx_fir)
	_check("通道：FIR 宿主 → attach_request.element == FIR（修复前被末位覆写为 LTG）",
		int(ctx_fir.attach_request.get("element", -1)) == GameConst.Element.FIR,
		str(ctx_fir.attach_request))
	_check("通道：FIR 宿主请求 {element, value:22, overrides:{}} 完整",
		ctx_fir.attach_request == {"element": GameConst.Element.FIR,
			"value": 22.0, "overrides": {}}, str(ctx_fir.attach_request))
	# LTG 宿主：LTG 词条放行
	var p_ltg := _spawn_proj({"position": Vector2(150, 150), "velocity": Vector2.ZERO,
		"lifetime": 10.0, "pierce": 1, "hitbox_radius": 6.0,
		"element": GameConst.Element.LTG, "attach_value": 0.0, "team": 0})
	_bump_frame()                              # 同栈第二派发须推帧（E-03 本帧已触发）
	var ctx_ltg := TraitContext.new()
	ctx_ltg.event = GameConst.TraitEvent.ON_HIT
	ctx_ltg.projectile = p_ltg
	stack.dispatch(GameConst.TraitEvent.ON_HIT, ctx_ltg)
	_check("通道：LTG 宿主 → attach_request.element == LTG（交替发各附当发元素）",
		int(ctx_ltg.attach_request.get("element", -1)) == GameConst.Element.LTG,
		str(ctx_ltg.attach_request))
	# E-03：同帧二次派发被词条帧闸拦下（端到端须 _bump_frame 推进的原因）
	var ctx_e03 := TraitContext.new()
	ctx_e03.event = GameConst.TraitEvent.ON_HIT
	ctx_e03.projectile = p_fir
	stack.dispatch(GameConst.TraitEvent.ON_HIT, ctx_e03)
	_check("E-03 帧闸：同帧同栈二次派发零输出（attach_request 保持空）",
		ctx_e03.attach_request.is_empty(), str(ctx_e03.attach_request))
	# 单元素栈回归：{element, value, overrides} 逐字节不变
	var single := TraitStack.new()
	single.attach(_ele(&"ELE_IGNITE"))
	var ctx_s := TraitContext.new()
	ctx_s.event = GameConst.TraitEvent.ON_HIT
	ctx_s.projectile = p_fir
	single.dispatch(GameConst.TraitEvent.ON_HIT, ctx_s)
	_check("单元素回归：FIR 宿主 attach_request 逐字节 == {FIR, 22.0, {}}",
		ctx_s.attach_request == {"element": GameConst.Element.FIR,
			"value": 22.0, "overrides": {}}, str(ctx_s.attach_request))
	var ctx_kin := TraitContext.new()
	ctx_kin.event = GameConst.TraitEvent.ON_HIT
	ctx_kin.projectile = p_kin_host()
	_bump_frame()                              # E-03：单栈上一派发已占帧，KIN 派发须推帧
	single.dispatch(GameConst.TraitEvent.ON_HIT, ctx_kin)
	_check("KIN 宿主放行：无附魔弹（直挂/兼容通道）attach_request 照旧输出",
		ctx_kin.attach_request == {"element": GameConst.Element.FIR,
			"value": 22.0, "overrides": {}}, str(ctx_kin.attach_request))
	_kill_live_projs()


func p_kin_host() -> ProjectileBase:
	# KIN 宿主弹（无附魔弹——直挂/兼容通道守卫放行分支）
	return _spawn_proj({"position": Vector2(150, 150), "velocity": Vector2.ZERO,
		"lifetime": 10.0, "pierce": 1, "hitbox_radius": 6.0,
		"element": GameConst.Element.KIN, "attach_value": 0.0, "team": 0})


# ── 5. ON_SPAWN 守卫（spawn 参数元素不被覆写） ────────────────────
func _test_spawn_guard() -> void:
	print("── ON_SPAWN 守卫：FIR 进 FIR 出 ──")
	var stack := _dual_stack()
	var p1 := _spawn_proj({"position": Vector2(150, 150), "velocity": Vector2.ZERO,
		"lifetime": 10.0, "pierce": 1, "hitbox_radius": 6.0,
		"element": GameConst.Element.FIR, "attach_value": 0.0, "team": 0,
		"trait_stack": stack.copy_runtime()})
	_check("ON_SPAWN：spawn 参数 FIR 保持 FIR（修复后整写覆写为末位 LTG）",
		int(p1.element) == GameConst.Element.FIR, "element=%d" % int(p1.element))
	var p2 := _spawn_proj({"position": Vector2(150, 150), "velocity": Vector2.ZERO,
		"lifetime": 10.0, "pierce": 1, "hitbox_radius": 6.0,
		"element": GameConst.Element.LTG, "attach_value": 0.0, "team": 0,
		"trait_stack": stack.copy_runtime()})
	_check("ON_SPAWN：spawn 参数 LTG 保持 LTG", int(p2.element) == GameConst.Element.LTG,
		"element=%d" % int(p2.element))
	var p3 := _spawn_proj({"position": Vector2(150, 150), "velocity": Vector2.ZERO,
		"lifetime": 10.0, "pierce": 1, "hitbox_radius": 6.0,
		"element": GameConst.Element.KIN, "attach_value": 0.0, "team": 0,
		"trait_stack": stack.copy_runtime()})
	_check("ON_SPAWN：KIN 中性弹保留附魔染色（放行分支→首挂词条元素）",
		int(p3.element) == GameConst.Element.FIR, "element=%d" % int(p3.element))
	_kill_live_projs()


# ── 6. 武器级实弹：双 ELE 卡交替（_shot_element 每发随机不被覆写） ──
func _test_weapon_alternation() -> void:
	print("── 武器级实弹：双元素交替 ──")
	var w := _make_weapon(_make_ballistic_data(), Vector2(360, 1100))
	w.attach_trait(_ele(&"ELE_IGNITE"))
	w.attach_trait(_ele(&"ELE_SHOCK"))
	var seen := {}
	for i in range(16):
		_bump_frame()
		w.try_fire()
	for node in _proj_pool.active_projectiles():
		var proj := node as ProjectileBase
		seen[int(proj.element)] = true
	_check("双元素实弹：FIR/LTG 均出现（每发随机取一，不再恒为挂载序末位）",
		seen.has(GameConst.Element.FIR) and seen.has(GameConst.Element.LTG),
		str(seen.keys()))
	_check("双元素实弹：无 KIN / 无杂色（16 发全部 ∈ 附魔集合）",
		seen.size() == 2, str(seen.keys()))
	_kill_live_projs()
	w.free()


# ── 7. 端到端：双槽成对 → RXN_FIR_LTG 过载（真件 ElementalSystem） ──
func _test_reaction_end_to_end() -> void:
	print("── 端到端：双槽成对 → 过载触发（E-03 + CD 2s） ──")
	var enemy := _spawn_enemy(_make_enemy_data("E_RXN"), Vector2(365, 640))
	_sys.register_host(enemy)
	var stack := _dual_stack()
	# 第 1 发：当发随机元素 = FIR（模拟 _shot_element 抽中火）
	var p1 := _spawn_proj({"position": Vector2(360, 640), "velocity": Vector2(100, 0),
		"lifetime": 10.0, "pierce": 1, "hitbox_radius": 6.0,
		"element": GameConst.Element.FIR, "attach_value": 0.0, "team": 0,
		"panel_snapshot": {"base_atk": 100.0}, "trait_stack": stack.copy_runtime()})
	_check("端到端：第 1 发 ON_SPAWN 后 element == FIR", int(p1.element) == GameConst.Element.FIR)
	_bump_frame()                              # E-03：spawn 期已派发 ON_SPAWN，命中须推帧
	p1.tick(DT)
	var st := enemy.get("elemental") as ElementalState
	_check("端到端：第 1 发命中 → FIR 槽 +22（当发元素附着）",
		st != null and _approx(st.gauges[GameConst.Element.FIR], 22.0),
		"fir=%s" % str(st.gauges[GameConst.Element.FIR] if st != null else -1.0))
	_check("端到端：LTG 槽未被错元素串写（恒 0）",
		st == null or _approx(st.gauges[GameConst.Element.LTG], 0.0))
	# 第 2 发：当发随机元素 = LTG（交替）
	var p2 := _spawn_proj({"position": Vector2(360, 640), "velocity": Vector2(100, 0),
		"lifetime": 10.0, "pierce": 1, "hitbox_radius": 6.0,
		"element": GameConst.Element.LTG, "attach_value": 0.0, "team": 0,
		"panel_snapshot": {"base_atk": 100.0}, "trait_stack": stack.copy_runtime()})
	_bump_frame()
	p2.tick(DT)
	_check("端到端：第 2 发命中 → 双槽成对（FIR=22 且 LTG=22）",
		st != null and _approx(st.gauges[GameConst.Element.FIR], 22.0)
			and _approx(st.gauges[GameConst.Element.LTG], 22.0),
		"fir=%s ltg=%s" % [str(st.gauges[GameConst.Element.FIR]),
			str(st.gauges[GameConst.Element.LTG])])
	# 帧末统一检测（E-07）：过载 RXN_FIR_LTG = 120%ATK × 快照 100
	var rxn0: int = DebugStats.get_counter(&"reaction_triggered")
	_bump_frame()
	_sys.detect_reactions()
	_check("过载触发：reaction_triggered 计数 +1",
		DebugStats.get_counter(&"reaction_triggered") == rxn0 + 1,
		"%d → %d" % [rxn0, DebugStats.get_counter(&"reaction_triggered")])
	_check("过载消耗：双槽清空",
		_approx(st.gauges[GameConst.Element.FIR], 0.0)
			and _approx(st.gauges[GameConst.Element.LTG], 0.0))
	_check("过载 CD：reaction_cd[RXN_FIR_LTG] = 2s",
		_approx(float(st.reaction_cd.get(GameConst.ReactionType.RXN_FIR_LTG, 0.0)), 2.0, 0.01))
	_check("过载结算：120%ATK 落血（1000 − 100×2 弹体 − 120 = 680）",
		_approx(enemy.hp, 680.0, 0.01), "hp=%s" % str(enemy.hp))
	# CD 期内重附双槽 → 不触发
	_sys.apply_attach(enemy, GameConst.Element.FIR, 22.0, {"snapshot": 100.0})
	_sys.apply_attach(enemy, GameConst.Element.LTG, 22.0)
	_bump_frame()
	_sys.detect_reactions()
	_check("反应 CD：2s 内重附双槽不触发",
		DebugStats.get_counter(&"reaction_triggered") == rxn0 + 1)
	# CD 过期（sys.tick 推进 reaction_cd）→ 再触发
	_sys.tick(2.0)
	_sys.apply_attach(enemy, GameConst.Element.FIR, 22.0, {"snapshot": 100.0})
	_sys.apply_attach(enemy, GameConst.Element.LTG, 22.0)
	_bump_frame()
	_sys.detect_reactions()
	_check("反应 CD：cd_rxn=2s 过期后可再次触发（+1）",
		DebugStats.get_counter(&"reaction_triggered") == rxn0 + 2)
	_sys.unregister_host(enemy)


# ── 8. R192 反应矩阵（真件 ElementalSystem + 真件管线；坐标逐簇隔离防连锁串扰） ──
func _test_matrix_reactions() -> void:
	print("── R192 反应矩阵：M0 超导账本 + 7 类新反应 + CD erase/多槽/幂等 ──")
	_m0_superconduct_ledger()
	_r_vaporize()
	_r_freeze()
	_r_shock_chain()
	_r_burn()
	_r_quicken()
	_r_bloom()
	_r_spread()
	_r_crystal()
	_cd_erase_and_multi_slot()


func _m0_superconduct_ledger() -> void:
	# M0 还账（R192 §6.1）：apply_superconduct 记 delta、激活期重触只刷新、到期按记录
	# delta 恢复一次——持续期重触 2 次 → 到期净恢复 0（旧症：重触 −0.3×N 到期仅 +0.3）。
	print("── M0 超导账本：重触只刷新 · 到期净恢复 0 ──")
	var ed := _make_enemy_data("E_M0", 100000.0)
	ed.resist = [0.3, 0.1, 0.0, 0.0]
	var e := _spawn_enemy(ed, Vector2(80, 100))
	_sys.register_host(e)
	_sys.apply_attach(e, GameConst.Element.ICE, 30.0)
	_sys.apply_attach(e, GameConst.Element.LTG, 30.0)
	_bump_frame()
	_sys.detect_reactions()
	_check("M0 首触：全抗 −0.3（0.3→0.0 / 0.1→−0.2 / 0→−0.3）",
		_approx(e.get_resist(GameConst.Element.KIN), 0.0, 0.0001)
			and _approx(e.get_resist(GameConst.Element.FIR), -0.2, 0.0001)
			and _approx(e.get_resist(GameConst.Element.LTG), -0.3, 0.0001))
	for i in range(2):                         # 持续期重触 ×2（各越 2s CD 窗）
		_sys.tick(2.5)
		_sys.apply_attach(e, GameConst.Element.ICE, 30.0)
		_sys.apply_attach(e, GameConst.Element.LTG, 30.0)
		_bump_frame()
		_sys.detect_reactions()
	_check("M0 持续期重触 ×2：削抗不重扣（仍 0.0/−0.2/−0.3——账本不对称修复）",
		_approx(e.get_resist(GameConst.Element.KIN), 0.0, 0.0001)
			and _approx(e.get_resist(GameConst.Element.FIR), -0.2, 0.0001)
			and _approx(e.get_resist(GameConst.Element.LTG), -0.3, 0.0001))
	_sys.tick(6.5)                             # 越过刷新后 6s 窗 → 到期按记录 delta 恢复一次
	_check("M0 到期净恢复 0：回到 0.3/0.1/0.0",
		_approx(e.get_resist(GameConst.Element.KIN), 0.3, 0.0001)
			and _approx(e.get_resist(GameConst.Element.FIR), 0.1, 0.0001)
			and _approx(e.get_resist(GameConst.Element.LTG), 0.0, 0.0001))
	_sys.unregister_host(e)


func _r_vaporize() -> void:
	# 蒸发 RXN_FIR_HYD：即时快照 χ1.5×S_snap×φ（φ=1 无 VOID）→ 100×1.5=150 落血；
	# 双槽清空；不掷暴击（resolve_reaction 强制 HIT_IS_REACTION——落血精确即证）。
	print("── 蒸发（火+水）：χ1.5 快照结算 ──")
	var e := _spawn_enemy(_make_enemy_data("E_VAP"), Vector2(80, 400))
	_sys.register_host(e)
	_sys.apply_attach(e, GameConst.Element.FIR, 30.0, {"snapshot": 100.0})
	_sys.apply_attach(e, GameConst.Element.HYD, 30.0)
	_bump_frame()
	_sys.detect_reactions()
	var st := e.get("elemental") as ElementalState
	_check("蒸发：落血 == S_snap×1.5×φ（1000−150=850）",
		_approx(e.hp, 850.0, 0.01), "hp=%s" % str(e.hp))
	_check("蒸发：双槽清空", st != null and _approx(st.gauges[GameConst.Element.FIR], 0.0)
		and _approx(st.gauges[GameConst.Element.HYD], 0.0))
	_sys.unregister_host(e)


func _r_freeze() -> void:
	# 冻结 RXN_ICE_HYD：复用既有 freeze/chill/vuln 字段（1.2s/2.5s/3.0s）；
	# IMMUNE_FREEZE 敌不定身（freeze 不写），双槽照常清空。
	print("── 冻结（冰+水）：硬控 1.2s + 免疫定身豁免 ──")
	var e := _spawn_enemy(_make_enemy_data("E_FRZ"), Vector2(80, 620))
	_sys.register_host(e)
	_sys.apply_attach(e, GameConst.Element.ICE, 30.0)
	_sys.apply_attach(e, GameConst.Element.HYD, 30.0)
	_bump_frame()
	_sys.detect_reactions()
	var st := e.get("elemental") as ElementalState
	_check("冻结：freeze_timer==1.2 · chill_timer==2.5 · vuln_timer==3.0",
		st != null and _approx(st.freeze_timer, 1.2, 0.001)
			and _approx(st.chill_timer, 2.5, 0.001)
			and _approx(st.vuln_timer, 3.0, 0.001),
		"freeze=%s chill=%s vuln=%s" % [str(st.freeze_timer), str(st.chill_timer),
			str(st.vuln_timer)])
	_check("冻结：双槽清空", st != null and _approx(st.gauges[GameConst.Element.ICE], 0.0)
		and _approx(st.gauges[GameConst.Element.HYD], 0.0))
	_sys.unregister_host(e)
	var e2 := _spawn_enemy(_make_enemy_data("E_FRZ_I"), Vector2(240, 620))
	e2.set("immune_mask", GameConst.IMMUNE_FREEZE)
	_sys.register_host(e2)
	_sys.apply_attach(e2, GameConst.Element.ICE, 30.0)
	_sys.apply_attach(e2, GameConst.Element.HYD, 30.0)
	_bump_frame()
	_sys.detect_reactions()
	var st2 := e2.get("elemental") as ElementalState
	_check("冻结：IMMUNE_FREEZE 不定身（freeze_timer==0）且双槽清空",
		st2 != null and _approx(st2.freeze_timer, 0.0, 0.001)
			and _approx(st2.gauges[GameConst.Element.ICE], 0.0)
			and _approx(st2.gauges[GameConst.Element.HYD], 0.0))
	_sys.unregister_host(e2)


func _r_shock_chain() -> void:
	# 感电 RXN_LTG_HYD：读 element_states.shock 全套（3 目标/160px/35%/深 2）连锁跳伤
	# + shock_chain_cd=1.0 护栏（零新字段）。
	print("── 感电（雷+水）：连锁跳伤 + 护栏 ──")
	var e := _spawn_enemy(_make_enemy_data("E_SCH"), Vector2(400, 100))
	var nb1 := _spawn_enemy(_make_enemy_data("E_SCH_N1"), Vector2(480, 100))   # 80px < 160
	var nb2 := _spawn_enemy(_make_enemy_data("E_SCH_N2"), Vector2(400, 220))   # 120px < 160
	_sys.register_host(e)
	_sys.apply_attach(e, GameConst.Element.LTG, 30.0, {"snapshot": 100.0})
	_sys.apply_attach(e, GameConst.Element.HYD, 30.0)
	_bump_frame()
	_sys.detect_reactions()
	var st := e.get("elemental") as ElementalState
	_check("感电：连锁跳伤 >0（80/120px 邻居落血——35%×快照首跳）",
		nb1.hp < 1000.0 - 0.001 and nb2.hp < 1000.0 - 0.001,
		"nb1=%s nb2=%s" % [str(nb1.hp), str(nb2.hp)])
	_check("感电：shock_chain_cd >0（护栏落闸）",
		st != null and st.shock_chain_cd > 0.0,
		"cd=%s" % str(st.shock_chain_cd if st != null else -1.0))
	_sys.unregister_host(e)


func _r_burn() -> void:
	# 燃烧 RXN_FIR_DEN：立即满层点燃 burn_layers=5 / burn_timer=3.0（快照继承）；
	# 无 χ 不进管线（不落血——表键无 coef）。
	print("── 燃烧（火+草）：立即满层点燃 ──")
	var e := _spawn_enemy(_make_enemy_data("E_BRN"), Vector2(640, 100))
	_sys.register_host(e)
	_sys.apply_attach(e, GameConst.Element.FIR, 30.0, {"snapshot": 100.0})
	_sys.apply_attach(e, GameConst.Element.DEN, 30.0)
	_bump_frame()
	_sys.detect_reactions()
	var st := e.get("elemental") as ElementalState
	_check("燃烧：burn_layers==5 · burn_timer==3.0（立即满层）",
		st != null and st.burn_layers == 5 and _approx(st.burn_timer, 3.0, 0.001),
		"layers=%s timer=%s" % [str(st.burn_layers if st != null else -1),
			str(st.burn_timer if st != null else -1.0)])
	_check("燃烧：双槽清空 + 无 χ 不落血（hp 仍 1000）",
		st != null and _approx(st.gauges[GameConst.Element.FIR], 0.0)
			and _approx(st.gauges[GameConst.Element.DEN], 0.0)
			and _approx(e.hp, 1000.0, 0.01))
	_sys.unregister_host(e)


func _r_quicken() -> void:
	# 激化 RXN_LTG_DEN：纯减益 vuln×1.25·3s（复用 vuln 池刷新，无 χ）。
	print("── 激化（雷+草）：易伤减益 ──")
	var e := _spawn_enemy(_make_enemy_data("E_QCK"), Vector2(640, 300))
	_sys.register_host(e)
	_sys.apply_attach(e, GameConst.Element.LTG, 30.0)
	_sys.apply_attach(e, GameConst.Element.DEN, 30.0)
	_bump_frame()
	_sys.detect_reactions()
	var st := e.get("elemental") as ElementalState
	_check("激化：vuln_timer==3.0 · vuln_mult≈1.25 · 双槽清空",
		st != null and _approx(st.vuln_timer, 3.0, 0.001)
			and _approx(st.get_vuln_factor(), 1.25, 0.001)
			and _approx(st.gauges[GameConst.Element.LTG], 0.0)
			and _approx(st.gauges[GameConst.Element.DEN], 0.0),
		"vuln=%s" % str(st.vuln_timer if st != null else -1.0))
	_sys.unregister_host(e)


func _r_bloom() -> void:
	# 绽放 RXN_HYD_DEN：延迟 AoE——detect 后 bloom_timer≈0.75 起爆挂账 + 主目标双槽已清；
	# tick 1.6s 到期爆发 → r120 内副目标落血（χ1.5×S_snap=150）。
	# R198 契约变更：绽放 delay 1.5→0.75（R192-low6 双源同批调参）——挂账窗断言同步改写。
	print("── 绽放（水+草）：0.75s 延迟 AoE（R198 契约变更 1.5→0.75） ──")
	var e := _spawn_enemy(_make_enemy_data("E_BLM"), Vector2(640, 620))
	var nb := _spawn_enemy(_make_enemy_data("E_BLM_N"), Vector2(700, 620))     # 60px < 120
	_sys.register_host(e)
	_sys.apply_attach(e, GameConst.Element.HYD, 30.0, {"snapshot": 100.0})
	_sys.apply_attach(e, GameConst.Element.DEN, 30.0)
	_bump_frame()
	_sys.detect_reactions()
	var st := e.get("elemental") as ElementalState
	var bloom_left: Variant = st.get("bloom_timer") if st != null else null
	_check("绽放：主目标双槽已清 + bloom 挂账（bloom_timer≈0.75，R198 契约变更）",
		st != null and bloom_left != null and float(bloom_left) > 0.5
			and float(bloom_left) <= 0.75 + 0.001
			and _approx(st.gauges[GameConst.Element.HYD], 0.0)
			and _approx(st.gauges[GameConst.Element.DEN], 0.0)
			and _approx(nb.hp, 1000.0, 0.01),
		"bloom=%s" % str(bloom_left))
	_sys.tick(1.6)                             # 到期消费（照 consume_superconduct_expired 模式）
	_check("绽放：0.75s 到期爆发 → r120 副目标落血（1000−150=850）",
		_approx(nb.hp, 850.0, 0.01), "hp=%s" % str(nb.hp))
	_sys.unregister_host(e)


func _r_spread() -> void:
	# 扩散 RXN_HYD_ANE（风+水）：主目标直伤 χ0.8×S_snap=80 + 半径 120 内至多 3 敌满槽
	# 转移被扩元素 HYD——新元素满槽钳制 GAUGE_MAX 不清零（M2 满槽语义），候选 append_array
	# 拷贝（网格查询拷贝纪律）。
	print("── 扩散（风+水）：直伤 + 满槽转移 ──")
	var e := _spawn_enemy(_make_enemy_data("E_SPR"), Vector2(360, 380))
	var c1 := _spawn_enemy(_make_enemy_data("E_SPR_C1"), Vector2(430, 380))    # 70px < 120
	var c2 := _spawn_enemy(_make_enemy_data("E_SPR_C2"), Vector2(360, 450))    # 70px < 120
	_sys.register_host(e)
	_sys.register_host(c1)                     # 生产口径：全体敌出生即挂载状态容器（spawner）
	_sys.register_host(c2)
	_sys.apply_attach(e, GameConst.Element.ANE, 30.0, {"snapshot": 100.0})
	_sys.apply_attach(e, GameConst.Element.HYD, 30.0)
	_bump_frame()
	_sys.detect_reactions()
	var st := e.get("elemental") as ElementalState
	_check("扩散：主目标直伤 χ0.8×S_snap（1000−80=920）+ 双槽清空",
		_approx(e.hp, 920.0, 0.01) and st != null
			and _approx(st.gauges[GameConst.Element.ANE], 0.0)
			and _approx(st.gauges[GameConst.Element.HYD], 0.0),
		"hp=%s" % str(e.hp))
	var st1 := c1.get("elemental") as ElementalState
	var st2 := c2.get("elemental") as ElementalState
	_check("扩散：至多 3 敌满槽转移 HYD（gauges==GAUGE_MAX 钳制不清零）",
		st1 != null and st2 != null
			and _approx(st1.gauges[GameConst.Element.HYD], ElementalState.GAUGE_MAX, 0.001)
			and _approx(st2.gauges[GameConst.Element.HYD], ElementalState.GAUGE_MAX, 0.001),
		"c1=%s c2=%s" % [str(st1.gauges[GameConst.Element.HYD] if st1 != null else -1.0),
			str(st2.gauges[GameConst.Element.HYD] if st2 != null else -1.0)])
	_sys.unregister_host(e)
	_sys.unregister_host(c1)
	_sys.unregister_host(c2)


func _r_crystal() -> void:
	# 结晶 RXN_FIR_GEO（岩+火）：crystal_shield_request → 玩家 15% 减伤 6s（刷新不叠加）；
	# 接触伤害经唯一漏斗 ×0.85 折减（无敌帧/格挡闸后 HP 直减前插闸）。
	print("── 结晶（岩+火）：玩家晶盾 ×0.85 ──")
	var player = load("res://scripts/entities/player/player.gd").new()   # 真件 Player（结结晶减伤闸唯一漏斗）
	player.name = "RxnCrystalProbe"
	tree.get_root().add_child(player)
	player.set("max_hp", 1000000.0)
	player.set("hp", 1000000.0)
	var e := _spawn_enemy(_make_enemy_data("E_CRY"), Vector2(80, 1000))
	_sys.register_host(e)
	_sys.apply_attach(e, GameConst.Element.GEO, 30.0)
	_sys.apply_attach(e, GameConst.Element.FIR, 30.0)
	_bump_frame()
	_sys.detect_reactions()
	var st := e.get("elemental") as ElementalState
	var dr_left: Variant = player.get("dr_left")
	var dr_value: Variant = player.get("dr_value")
	_check("结晶：双槽清空 + 玩家晶盾到账（dr_value≈0.15 / dr_left≈6.0）",
		st != null and _approx(st.gauges[GameConst.Element.GEO], 0.0)
			and _approx(st.gauges[GameConst.Element.FIR], 0.0)
			and dr_left != null and dr_value != null
			and _approx(float(dr_value), 0.15, 0.001)
			and _approx(float(dr_left), 6.0, 0.001),
		"dr_left=%s dr_value=%s" % [str(dr_left), str(dr_value)])
	player.take_contact_damage(100.0)
	_check("结晶：接触伤害 ×0.85 折减（1000000−85）",
		_approx(float(player.hp), 1000000.0 - 85.0, 0.01),
		"hp=%s" % str(player.hp))
	player.queue_free()
	_sys.unregister_host(e)


func _cd_erase_and_multi_slot() -> void:
	# CD 到期 erase（M0 同批：reaction_cd 只减不删 → 21 反应长局膨胀口）+ 多槽共存按序
	# 仅一反应 + 同帧幂等缓存吸收（_uid_reaction 幂等键）。
	print("── CD erase + 多槽共存 + 幂等吸收 ──")
	var e := _spawn_enemy(_make_enemy_data("E_CD"), Vector2(700, 1240))
	_sys.register_host(e)
	var st := e.get("elemental") as ElementalState
	_sys.apply_attach(e, GameConst.Element.FIR, 30.0, {"snapshot": 100.0})
	_sys.apply_attach(e, GameConst.Element.HYD, 30.0)
	_bump_frame()
	_sys.detect_reactions()
	_check("CD 写入：reaction_cd[RXN_FIR_HYD] = 2.0",
		_approx(float(st.reaction_cd.get(GameConst.ReactionType.RXN_FIR_HYD, 0.0)), 2.0, 0.01))
	var cd_size0: int = st.reaction_cd.size()
	_sys.tick(2.5)
	_check("CD 到期 erase：键被删（字典 size 回落 %d→%d）" % [cd_size0, st.reaction_cd.size()],
		not st.reaction_cd.has(GameConst.ReactionType.RXN_FIR_HYD)
		and st.reaction_cd.size() < cd_size0)
	_sys.unregister_host(e)
	# 多槽共存：FIR+ICE+HYD → 优先级序仅碎裂结算（一帧一反应），HYD 槽不动
	var e2 := _spawn_enemy(_make_enemy_data("E_MUL"), Vector2(700, 1000))
	_sys.register_host(e2)
	var st2 := e2.get("elemental") as ElementalState
	var rxn0: int = DebugStats.get_counter(&"reaction_triggered")
	_sys.apply_attach(e2, GameConst.Element.FIR, 30.0)
	_sys.apply_attach(e2, GameConst.Element.ICE, 30.0)
	_sys.apply_attach(e2, GameConst.Element.HYD, 30.0)
	_bump_frame()
	_sys.detect_reactions()
	_check("多槽共存：FIR+ICE+HYD 按序仅碎裂结算（计数 +1 · FIR/ICE 清 · HYD 存续）",
		DebugStats.get_counter(&"reaction_triggered") == rxn0 + 1
			and _approx(st2.gauges[GameConst.Element.FIR], 0.0)
			and _approx(st2.gauges[GameConst.Element.ICE], 0.0)
			and _approx(st2.gauges[GameConst.Element.HYD], 30.0, 0.001))
	_bump_frame()
	_sys.detect_reactions()
	_check("多槽共存：单槽残余（HYD）不成对 → 不再触发", 
		DebugStats.get_counter(&"reaction_triggered") == rxn0 + 1)
	# 幂等吸收：同帧同源同目标二次结算被管线 _uid_reaction 幂等键吸收（恰落一次 150）。
	# 注：基线时本段因敌池 16 槽耗尽崩溃从未执行（符号笔误 hp1−hp0 为负）——池修复后
	# 首次可执行，按断言题旨「恰落 −150」修正为伤害量 hp0−hp1==150（非放宽，语义同题）
	var hp0: float = e2.hp
	_sys._settle_reaction(e2, 100.0, 1.5, GameConst.ReactionType.RXN_FIR_HYD)
	var hp1: float = e2.hp
	_sys._settle_reaction(e2, 100.0, 1.5, GameConst.ReactionType.RXN_FIR_HYD)
	_check("幂等吸收：同帧二次结算恰落一次（−150 而非 −300）",
		_approx(hp0 - hp1, 150.0, 0.01) and _approx(e2.hp, hp1, 0.001),
		"hp0=%s hp1=%s hp=%s" % [str(hp0), str(hp1), str(e2.hp)])
	_sys.unregister_host(e2)

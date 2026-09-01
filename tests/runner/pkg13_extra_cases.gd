# tests/runner/pkg13_extra_cases.gd
# v1.3.0 tester 补漏用例体（由 test_pkg13_extra.gd 入口在 autoload 就绪后运行时加载编译）。
# 定位：pkg13 V57~V78 之外的【独立复算 4 项 + 验收缺口补测】——不复读 pkg13 断言，
#       全部手算锚自推（面板 100 零暴击零加算、seed 42 管线、seed 1001 probe 镜像）。
# 混合夹具：X1~X3/X5~X7/X10 = pkg13 式微夹具（真件管线 + 局部 ElementalSystem）；
#           X11 = 裸 WaveDirector 双遍采集；X9 = 独立 MetaStore 注入存档路径；
#           X4/X8 = pkg6 式 GameLoop 完整 Boot（X4 先建局，X8 复用重开后 PLAYING 态）。
# 执行序纪律：微夹具纯净面先行 → WaveDirector → MetaStore → GameLoop 段（X4→X8）→ X12 源扫描收尾。
extends RefCounted

const BALLISTIC_SCENE := "res://scenes/combat/projectiles/ballistic_projectile.tscn"
const ENEMY_SCENE := "res://scenes/combat/enemies/enemy.tscn"
const DT := 1.0 / 120.0
const TRAIT_FIR := "res://resources/traits/ELE_IGNITE.tres"
const TRAIT_ICE := "res://resources/traits/ELE_FREEZE.tres"
const TRAIT_WAT := "res://resources/traits/ELE_TIDE.tres"
const TRAIT_VOID := "res://resources/traits/ELE_REACTION_VOID.tres"
const META_TEST_PATH := "user://pkg13_extra_meta_test.cfg"

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []

# ── 微夹具（pkg13 同款） ──
var _proj_pool: ProjectilePool
var _enemy_pool: EnemyPool
var _grid: SpaceGrid
var _pipeline: DamagePipeline
var _sys: ElementalSystem                       # 微世界共享系统（零共鸣基线）
var _alive_enemies: Array[Node2D] = []
var _captured: Array[DamageResult] = []
var _micro_weapons: Array[WeaponBase] = []
var _micro_stubs: Array[Node2D] = []
var _micro_systems: Array[ElementalSystem] = []
var _wd_counter: int = 0

# ── GameLoop 夹具（pkg6 模式） ──
var _gl: GameLoop = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_ensure_autoloads()
	_setup_micro()
	_test_x1_resonance_attach_e2e()               # X1 独立复算①
	_test_x2_crystal_fir_e2e()                    # X2 独立复算②
	_test_x10_enemy_proj_passthrough()            # X10 敌弹穿过无副作用
	_test_x3_strip_void_closure()                 # X3 独立复算③
	_test_x5_scanner_gaps()                       # X5 最高层胜 + VOID/MASTERY 不参与
	_test_x6_four_equals_three()                  # X6 4 把=3 把档
	_test_x7_vapor_double_resonance()             # X7 汽爆 1.15²
	_test_x13_reset_run_clears_resonance()        # X13 审查 Important 回归
	_teardown_micro()
	_test_x11_reseed_same_pos()                   # X11 seed1001 两次重播种同 pos
	_test_x9_int_or_type_guard()                  # X9 类型守卫四键
	_boot_game_loop()
	_test_x4_crystal_cross_run()                  # X4 独立复算④ + GAME_OVER 不清
	_test_x8_skip_gold_k05()                      # X8 K_gold=0.5 跳过 +23
	_teardown_game_loop()
	_test_x12_trigger_surface_veto()              # X12 水晶触发面 veto
	_summary()


func fail_count() -> int:
	return _fail


# ── 支撑（pkg13 同款） ─────────────────────────────────────────────
func _approx(p_a: float, p_b: float, p_tol: float = 0.001) -> bool:
	return absf(p_a - p_b) <= p_tol


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
		print("失败项：")
		for f in _failures:
			print("  - %s" % f)
	print("════════════════════════════════════════")


func _bump() -> void:
	GameConfig.frame_stamp += 1                   # E-03 帧闸门推进（测试侧替身）


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


func _setup_micro() -> void:
	_proj_pool = ProjectilePool.new()
	_proj_pool.name = "Pkg13XProjPool"
	tree.get_root().add_child(_proj_pool)
	_proj_pool.setup(&"pkg13x_test", load(BALLISTIC_SCENE), 64)
	var ep := EnemyPool.new()
	ep.name = "Pkg13XEnemyPool"
	tree.get_root().add_child(ep)
	ep.setup(&"pkg13x_enemy", load(ENEMY_SCENE), 48)
	_enemy_pool = ep
	_grid = SpaceGrid.new()
	_grid.configure(Vector2(720, 1280), 192.0)
	_alive_enemies.clear()
	_captured.clear()
	_pipeline = DamagePipeline.new()
	_pipeline.set_rng_seed(42)
	_sys = ElementalSystem.new()
	_sys.name = "Pkg13XElementalSystem"
	tree.get_root().add_child(_sys)
	_sys.pipeline = _pipeline
	_sys.enemy_grid = _grid
	EventBus.damage_resolved.connect(_on_damage_resolved)


func _teardown_micro() -> void:
	if EventBus.damage_resolved.is_connected(_on_damage_resolved):
		EventBus.damage_resolved.disconnect(_on_damage_resolved)
	_purge_crystals()
	_purge_enemies()
	for w in _micro_weapons:
		if is_instance_valid(w):
			w.free()
	_micro_weapons.clear()
	for stub in _micro_stubs:
		if is_instance_valid(stub):
			stub.free()
	_micro_stubs.clear()
	for sys in _micro_systems:
		if is_instance_valid(sys):
			sys.free()
	_micro_systems.clear()
	_captured.clear()
	if _sys != null:
		_sys.free()
		_sys = null
	_pipeline = null
	if _proj_pool != null:
		_proj_pool.free()
		_proj_pool = null
	if _enemy_pool != null:
		_enemy_pool.free()
		_enemy_pool = null
	_grid = null


func _on_damage_resolved(p_result: DamageResult) -> void:
	_captured.append(p_result)


func _make_enemy_data(p_id: String, p_hp: float = 1000.0) -> EnemyData:
	var d := EnemyData.new()
	d.id = StringName(p_id)
	d.display_name = p_id
	d.hp_base = p_hp
	d.spd_base = 0.0                              # 静止敌（几何确定性）
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


func _purge_enemies() -> void:
	for e in _alive_enemies:
		_sys.unregister_host(e)
		for sys in _micro_systems:
			sys.unregister_host(e)
		_enemy_pool.release(e)
	_alive_enemies.clear()
	_grid.rebuild(_alive_enemies)


func _purge_crystals() -> void:
	var c := Crystal.active
	if c != null and is_instance_valid(c):
		c.dissolve()


func _panel() -> Dictionary:
	# 零暴击零加算面板（手算锚：final = base_atk × ∏M，resist 0）
	return {
		"base_atk": 100.0, "crit_rate": 0.0, "crit_mult": 2.0,
		"flat_bonus": 0.0, "add_entries": [], "chip_atk_pct": 0.0,
	}


func _spawn_proj(p_element: int, p_pos: Vector2, p_attach: float = 0.0, p_pierce: int = 1,
		p_weapon: WeaponBase = null, p_last_damage: float = -1.0,
		p_sys: ElementalSystem = null, p_team: int = 0) -> ProjectileBase:
	var proj := _proj_pool.acquire() as ProjectileBase
	proj.damage_pipeline = _pipeline
	proj.enemy_grid = _grid
	proj.pool = _proj_pool
	proj.elemental = p_sys if p_sys != null else _sys
	var params := {
		"velocity": Vector2.ZERO,
		"lifetime": 1.0,
		"pierce": p_pierce,
		"bounces": 0,
		"hitbox_radius": 6.0,
		"element": p_element,
		"attach_value": p_attach,
		"generation": 0,
		"weapon_uid": 0,
		"panel_snapshot": _panel(),
		"team": p_team,
		"position": p_pos,
	}
	if p_weapon != null:
		params["weapon_ref"] = p_weapon
	proj.spawn(params)
	if p_last_damage >= 0.0:
		proj.last_hit_damage = p_last_damage
	return proj


func _fire_at(p_proj: ProjectileBase) -> void:
	_captured.clear()
	_bump()
	_pipeline.begin_frame()
	p_proj.tick(DT)


func _gauge_on(p_sys: ElementalSystem, p_enemy: Node2D, p_element: int, p_value: float) -> void:
	# 局部系统版预置附着（snapshot 100 供剧变快照通道）
	p_sys.apply_attach(p_enemy, p_element, p_value, {"snapshot": 100.0})


func _read_source(p_path: String) -> String:
	var f := FileAccess.open(p_path, FileAccess.READ)
	if f == null:
		return ""
	return f.get_as_text()


# ── 共鸣微夹具（真实 WeaponBase + stub 宿主；attach_trait 走生产 rebuild 通道） ──
func _make_micro_weapon_data() -> WeaponData:
	_wd_counter += 1
	var d := WeaponData.new()
	d.id = StringName("W_PKG13X_%d" % _wd_counter)
	d.display_name = "Pkg13X 测试武器 %d" % _wd_counter
	d.form = GameConst.WeaponForm.BALLISTIC
	d.crit_rate = 0.0
	d.crit_dmg = 2.0
	d.hitbox_r = 6.0
	for i in range(5):
		var ls := WeaponLevelStats.new()
		ls.base_atk = 10.0
		ls.rof = 5.0
		ls.cd = 0.5
		ls.pierce = 1
		ls.pellets = 1
		d.upgrade_table.append(ls)
	return d


func _make_micro_weapon(p_sys: ElementalSystem, p_pos: Vector2) -> WeaponBase:
	var w: WeaponBase = BallisticWeapon.new()
	w.name = "Pkg13XWeapon_%d" % _wd_counter
	tree.get_root().add_child(w)
	w.position = p_pos
	w.setup(_make_micro_weapon_data(), null, {
		"pipeline": _pipeline,
		"projectile_pool": _proj_pool,
		"enemy_grid": _grid,
		"laser_pool": null,
		"elemental": p_sys,
	})
	_micro_weapons.append(w)
	return w


func _make_stub_player(p_weapons: Array) -> Node2D:
	var psrc := GDScript.new()
	psrc.source_code = "extends Node2D\nvar weapon_slots: Array = []\n"
	psrc.reload()
	var stub: Node2D = psrc.new()
	tree.get_root().add_child(stub)
	stub.weapon_slots = p_weapons
	_micro_stubs.append(stub)
	for w in p_weapons:
		if w is WeaponBase:
			(w as WeaponBase).player = stub
	return stub


func _make_resonance_sys(p_name: String, p_trait_paths: Array) -> ElementalSystem:
	# 逐武器挂 p_trait_paths[i] 词条（attach_trait → rebuild_registries 生产通道）
	var sys := ElementalSystem.new()
	sys.name = p_name
	tree.get_root().add_child(sys)
	sys.pipeline = _pipeline
	sys.enemy_grid = _grid
	_micro_systems.append(sys)
	var weapons: Array = []
	for i in range(p_trait_paths.size()):
		weapons.append(_make_micro_weapon(sys, Vector2(100.0 + 40.0 * float(i), 40.0)))
	var stub := _make_stub_player(weapons)
	for i in range(weapons.size()):
		var tdata: TraitData = load(p_trait_paths[i])
		(weapons[i] as WeaponBase).attach_trait(tdata)
	return sys


func _spawn_crystal(p_pos: Vector2) -> Crystal:
	var c := Crystal.new()
	c.name = "Pkg13XCrystal"
	tree.get_root().add_child(c)
	c.position = p_pos
	c.activate(_sys, _grid)
	return c


func _make_mastery_data() -> TraitData:
	# ELE_MASTERY 镜像定义（与 .tres 同值：step 0.25 / stack_max 3 / hooks 空）
	var d := TraitData.new()
	d.id = &"ELE_MASTERY"
	d.display_name = "元素精通"
	d.pool = GameConst.PoolClass.ELEM
	d.pool_id = &""
	d.effect_id = &"EF_ELEMENTAL"
	d.value = 0.25
	d.params = {"mastery_step": 0.25}
	d.stack_max = 3
	d.proc_chance = 1.0
	return d


# ── X1 独立复算①：共鸣 attach 端到端（弹载体真件命中） ──────────────
func _test_x1_resonance_attach_e2e() -> void:
	print("── X1 共鸣 attach 端到端 ──")
	_purge_enemies()
	# 2 把 FIR 武器（生产 rebuild 通道建立共鸣）→ ELE_IGNITE 弹（FIR，attach 22）真件命中
	var sys := _make_resonance_sys("Pkg13XX1", [TRAIT_FIR, TRAIT_FIR])
	var e := _spawn_enemy(_make_enemy_data("X1_E", 2000.0), Vector2(120, 200))
	sys.register_host(e)
	_fire_at(_spawn_proj(GameConst.Element.FIR, e.global_position, 22.0, 1, null, -1.0, sys))
	var st: ElementalState = e.get("elemental")
	# 手算：apply_attach 入口 → chip 缺省 ×1.0 → 共鸣 ×1.25 → 22×1.25 = 27.5（位级 ==）
	var gauge: float = st.gauges[GameConst.Element.FIR] if st != null else -1.0
	_check("X1：独立复算①——2 FIR 共鸣 + ELE_IGNITE 弹命中（attach 22）→ 敌 FIR gauge == 27.5（22×1.25 位级）",
		gauge == 27.5, "gauge=%s" % str(gauge))


# ── X2 独立复算②：水晶 FIR 臂端到端手算 ─────────────────────────────
func _test_x2_crystal_fir_e2e() -> void:
	print("── X2 水晶 FIR 端到端 ──")
	_purge_enemies()
	_purge_crystals()
	var weapon := _make_micro_weapon(_sys, Vector2(300, 660))
	var near := _spawn_enemy(_make_enemy_data("X2_N", 1000.0), Vector2(330, 600))
	var far := _spawn_enemy(_make_enemy_data("X2_F", 1000.0), Vector2(520, 600))
	var c := _spawn_crystal(Vector2(300, 600))
	_fire_at(_spawn_proj(GameConst.Element.FIR, Vector2(300, 600), 0.0, 1, weapon))
	# 手算：panel 100 → FIR 臂 0.8×100 = 80，半径 90（近敌距 30+14 ≤ 90 吃；远敌 220 不吃）
	var hp_ok := _approx(near.hp, 920.0, 0.01) and _approx(far.hp, 1000.0, 0.01)
	# 结算核验：captured 中近敌恰有 final==80 的次级 AOE 结算（真件管线落血口径）
	var fin_ok := false
	for r in _captured:
		if int(r.target_uid) == int(near.get("uid")) and _approx(r.final_value, 80.0, 0.01):
			fin_ok = true
	var dissolved: bool = not c.alive and Crystal.active == null
	_check("X2：独立复算②——面板 100 → 敌 HP -80（0.8×100，r90 内吃/外不吃）+ 结算 final==80 落血 + 结算尾消散",
		hp_ok and fin_ok and dissolved,
		"hp=%s fin=%s dissolved=%s" % [str(near.hp), str(fin_ok), str(dissolved)])


# ── X10 敌弹穿过水晶无副作用（H3：team1 早返不进水晶碰撞） ────────────
func _test_x10_enemy_proj_passthrough() -> void:
	print("── X10 敌弹穿过 ──")
	_purge_enemies()
	_purge_crystals()
	var c := _spawn_crystal(Vector2(400, 300))
	var proj := _spawn_proj(GameConst.Element.KIN, Vector2(400, 300), 0.0, 1,
		null, -1.0, _sys, 1)                       # team=1 敌弹，正叠水晶
	_fire_at(proj)
	var intact: bool = c.alive and Crystal.active == c and proj._live
	_check("X10：敌弹（team1）穿过水晶——晶不碎（alive/active 原样）+ 弹不受水晶判定副作用",
		intact, "alive=%s active_is_c=%s proj_live=%s"
			% [str(c.alive), str(Crystal.active == c), str(proj._live)])
	_purge_crystals()


# ── X3 独立复算③：strip VOID 收口（rebuild 幂等重建） ────────────────
func _test_x3_strip_void_closure() -> void:
	print("── X3 strip VOID 收口 ──")
	var sys := _make_resonance_sys("Pkg13XX3", [])
	var w1 := _make_micro_weapon(sys, Vector2(100, 120))
	var stub := _make_stub_player([w1])
	var void_t: TraitData = load(TRAIT_VOID)
	var ok := true
	var detail := ""
	# 挂 VOID → attach_trait 生产通道自动 rebuild → 1.8
	if not (w1.attach_trait(void_t) and sys.reaction_mult() == 1.8):
		ok = false
		detail = "挂 VOID 后 mult=%s" % str(sys.reaction_mult())
	if ok:
		# strip（摘层语义）→ rebuild 收口 → 旧债消失 1.0（位级）
		w1.trait_stack.detach_last(true)
		sys.rebuild_registries(stub)
		if sys.reaction_mult() != 1.0:
			ok = false
			detail = "strip 后 mult=%s（应为 1.0）" % str(sys.reaction_mult())
	if ok:
		# 再挂 → rebuild 幂等重建 → 恰 1.8（位级，非累积残留）
		w1.attach_trait(void_t)
		sys.rebuild_registries(stub)
		if sys.reaction_mult() != 1.8:
			ok = false
			detail = "再挂后 mult=%s（应为 1.8）" % str(sys.reaction_mult())
	if ok:
		# rebuild 二连：幂等（同输入同输出，不二次放大）
		sys.rebuild_registries(stub)
		if sys.reaction_mult() != 1.8:
			ok = false
			detail = "rebuild 二连后 mult=%s" % str(sys.reaction_mult())
	_check("X3：独立复算③——strip VOID 收口：挂 1.8 → strip → rebuild 恰 1.0（旧债残留消失）→ 再挂 → rebuild 恰 1.8（幂等重建 + 二连同值）",
		ok, detail)


# ── X5 扫描器补漏：同武器最高层胜 + VOID/MASTERY 不参与 ───────────────
func _test_x5_scanner_gaps() -> void:
	print("── X5 扫描器补漏 ──")
	var sys := _make_resonance_sys("Pkg13XX5", [])
	# 武器甲：IGNITE×2 + FREEZE×1 → 最高层胜（FIR）
	var wa := _make_micro_weapon(sys, Vector2(100, 160))
	var stub_a := _make_stub_player([wa])
	var ignite: TraitData = load(TRAIT_FIR)
	var freeze: TraitData = load(TRAIT_ICE)
	wa.attach_trait(ignite)
	wa.attach_trait(ignite)
	wa.attach_trait(freeze)
	var la := ElementalSystem.weapon_element_counts(stub_a)
	var la_ok: bool = la[GameConst.Element.FIR] == 1 and la[GameConst.Element.KIN] == 0 \
		and la[GameConst.Element.ICE] == 0
	# 武器乙：VOID + MASTERY×2（无 element 键词条）→ 不参与计数，全 0
	var wb := _make_micro_weapon(sys, Vector2(140, 160))
	var void_t: TraitData = load(TRAIT_VOID)
	wb.attach_trait(void_t)
	wb.attach_trait(_make_mastery_data())
	wb.attach_trait(_make_mastery_data())
	var stub_b := _make_stub_player([wb])
	var lb := ElementalSystem.weapon_element_counts(stub_b)
	var sys_b := ElementalSystem.new()
	sys_b.name = "Pkg13XX5B"
	tree.get_root().add_child(sys_b)
	sys_b.pipeline = _pipeline
	sys_b.enemy_grid = _grid
	_micro_systems.append(sys_b)
	sys_b.rebuild_registries(stub_b)
	var factors_ok: bool = sys_b.resonance_attach_factor(GameConst.Element.FIR) == 1.0 \
		and sys_b.resonance_reaction_factor(GameConst.Element.FIR) == 1.0
	_check("X5：扫描器补漏——IGNITE2+FREEZE1 → 最高层胜 FIR（counts[FIR]==1）；VOID/MASTERY 词条不参与（全 0 + 共鸣因子恒 1.0）",
		la_ok and lb == [0, 0, 0, 0, 0] and factors_ok,
		"la=%s lb=%s factors=%s" % [str(la), str(lb), str(factors_ok)])


# ── X6 4 把=3 把档（阈值 ≥3 封档，不随 4+ 增益） ──────────────────────
func _test_x6_four_equals_three() -> void:
	print("── X6 4把=3把档 ──")
	var sys4 := _make_resonance_sys("Pkg13XX6A",
		[TRAIT_FIR, TRAIT_FIR, TRAIT_FIR, TRAIT_FIR])
	var four: bool = sys4.resonance_attach_factor(GameConst.Element.FIR) == 1.25 \
		and sys4.resonance_reaction_factor(GameConst.Element.FIR) == 1.15
	var sys3 := _make_resonance_sys("Pkg13XX6B", [TRAIT_FIR, TRAIT_FIR, TRAIT_FIR])
	var three: bool = sys3.resonance_attach_factor(GameConst.Element.FIR) == 1.25 \
		and sys3.resonance_reaction_factor(GameConst.Element.FIR) == 1.15
	var sys1 := _make_resonance_sys("Pkg13XX6C", [TRAIT_FIR])
	var one: bool = sys1.resonance_attach_factor(GameConst.Element.FIR) == 1.0 \
		and sys1.resonance_reaction_factor(GameConst.Element.FIR) == 1.0
	_check("X6：4 把=3 把档——4 FIR 与 3 FIR 因子完全同值（attach 1.25 / reaction 1.15）；1 把恒 1.0",
		four and three and one, "four=%s three=%s one=%s" % [str(four), str(three), str(one)])


# ── X7 汽爆双元素共鸣 1.15²（H2 连乘口径独立复算） ────────────────────
func _test_x7_vapor_double_resonance() -> void:
	print("── X7 汽爆 1.15² ──")
	_purge_enemies()
	# 3 WAT + 3 FIR：汽爆 (WAT,FIR) 双元素臂 res(WAT)×res(FIR) = 1.15×1.15
	var sys := _make_resonance_sys("Pkg13XX7",
		[TRAIT_WAT, TRAIT_WAT, TRAIT_WAT, TRAIT_FIR, TRAIT_FIR, TRAIT_FIR])
	var e := _spawn_enemy(_make_enemy_data("X7_E", 4000.0), Vector2(100, 200))
	sys.register_host(e)
	_gauge_on(sys, e, GameConst.Element.WAT, 30.0)
	_gauge_on(sys, e, GameConst.Element.FIR, 30.0)
	_captured.clear()
	_bump()
	_pipeline.begin_frame()
	sys.detect_reactions()
	var blast := -1.0
	for r in _captured:
		if r.popup_style == GameConst.PopupStyle.REACTION \
				and r.element == GameConst.ReactionType.RXN_WAT_FIR \
				and r.target_uid == int(e.get("uid")):
			blast = r.final_value
	# 手算：snapshot 100 × coef 0.6 × 1.15 × 1.15 = 79.35（IEEE 积，0.001 容差）
	_check("X7：汽爆双元素 1.15²——3 WAT+3 FIR → 100×0.6×1.15×1.15 = 79.35（H2 连乘）",
		_approx(blast, 79.35), "blast=%s" % str(blast))


# ── X11 seed1001 两次重播种同 pos（确定性契约） ───────────────────────
var _wd_captured: Array[Vector2] = []           # WaveDirector 信号采集（方法 Callable 保证可断连）


func _on_wd_crystal(pos: Vector2) -> void:
	_wd_captured.append(pos)


func _test_x11_reseed_same_pos() -> void:
	print("── X11 重播种同 pos ──")
	var wd := WaveDirector.new()
	wd.name = "Pkg13XWaveDirector"
	tree.get_root().add_child(wd)
	var pass1: Array = []
	var pass2: Array = []
	var capped := true
	for w in range(1, 32):
		_wd_captured.clear()
		wd.crystal_spawn_requested.connect(_on_wd_crystal)
		wd.start_wave(w)
		wd.crystal_spawn_requested.disconnect(_on_wd_crystal)
		pass1.append(_wd_captured.duplicate())
		if _wd_captured.size() > 1:
			capped = false
	wd.reset_event_state()                        # 重播种 seed 1001
	for w in range(1, 32):
		_wd_captured.clear()
		wd.crystal_spawn_requested.connect(_on_wd_crystal)
		wd.start_wave(w)
		wd.crystal_spawn_requested.disconnect(_on_wd_crystal)
		pass2.append(_wd_captured.duplicate())
	wd.free()
	var same: bool = pass1 == pass2
	var has_hit := false
	for entry in pass1:
		if not (entry as Array).is_empty():
			has_hit = true
			break
	_check("X11：seed1001 两次重播种同 pos——双遍 w1~31 逐波采集序列全等 + 每波至多 1 次请求 + 序列非空",
		same and capped and has_hit,
		"same=%s capped=%s has_hit=%s" % [str(same), str(capped), str(has_hit)])


# ── X9 类型守卫 _int_or（R4）四键脏值 ─────────────────────────────────
func _test_x9_int_or_type_guard() -> void:
	print("── X9 类型守卫 ──")
	# 直测：INT 直用 / FLOAT 整数值收整 / 非整 FLOAT / 字符串 / 数组 / 超安全域 FLOAT → 默认
	var direct_ok: bool = MetaStore._int_or(5, 0, "k") == 5 \
		and MetaStore._int_or(3.0, 0, "k") == 3 \
		and MetaStore._int_or(22.5, 9, "k") == 9 \
		and MetaStore._int_or("abc", 7, "k") == 7 \
		and MetaStore._int_or([1], 4, "k") == 4 \
		and MetaStore._int_or(1.0e17, 2, "k") == 2
	# 存档级：四键各喂脏值，单键回退不整档作废 + 其余键保留 + 不写回
	var store := MetaStore.new()
	store.set_save_path(META_TEST_PATH)
	store.wipe()
	var cfg := ConfigFile.new()
	cfg.set_value("meta", "save_version", "abc")   # 键①脏：按 v1 继续（不整档拒绝）
	cfg.set_value("meta", "crystal", 12)           # 键②净：保留
	cfg.set_value("levels", "hpg", "abc")          # 键③脏：单键回 0
	cfg.set_value("levels", "atk", 2)              # 其余 levels 键保留
	cfg.set_value("stats", "total_kills", "abc")   # 键④脏：单键回 0
	cfg.set_value("stats", "total_runs", 7)        # 其余 stats 键保留
	cfg.set_value("stats", "best_wave", 3)
	cfg.save(META_TEST_PATH)
	store.load_save()
	var mixed_ok: bool = store.crystal == 12 \
		and store.level(&"hpg") == 0 and store.level(&"atk") == 2 \
		and store.total_kills == 0 and store.total_runs == 7 and store.best_wave == 3
	# 不写回：load 后重读文件，脏值原样（「全回退不写回」口径）
	var cfg2 := ConfigFile.new()
	cfg2.load(META_TEST_PATH)
	var no_writeback: bool = str(cfg2.get_value("meta", "save_version", "")) == "abc" \
		and str(cfg2.get_value("levels", "hpg", "")) == "abc"
	# FLOAT 整数值收整走存档通道：crystal = 3.0 → 3
	var cfg3 := ConfigFile.new()
	cfg3.set_value("meta", "save_version", 1)
	cfg3.set_value("meta", "crystal", 3.0)
	cfg3.save(META_TEST_PATH)
	store.load_save()
	var float_ok: bool = store.crystal == 3
	store.wipe()
	store.free()
	_check("X9：类型守卫——_int_or 直测（int/3.0→3/22.5/\"abc\"/[]/1e17→默认）+ 存档四键脏值单键回退（其余键保留）+ 不写回 + crystal 3.0→3",
		direct_ok and mixed_ok and no_writeback and float_ok,
		"direct=%s mixed=%s no_wb=%s float=%s" % [str(direct_ok), str(mixed_ok),
			str(no_writeback), str(float_ok)])


# ════════════════ GameLoop 段（pkg6 夹具模式） ════════════════════
func _boot_game_loop() -> void:
	_gl = GameLoop.new()
	_gl.name = "GameLoopXUnderTest"
	tree.get_root().add_child(_gl)
	if not (_gl.boot_ready and _gl.state == GameConst.GameStatus.MENU):
		push_error("[pkg13_extra] GameLoop Boot 异常（后续 GameLoop 段用例级联失败）")


func _teardown_game_loop() -> void:
	tree.paused = false
	if _gl != null:
		_gl.free()
		_gl = null


# ── X4 独立复算④：水晶跨局残留 + GAME_OVER 不清（H3 链路） ───────────
func _test_x4_crystal_cross_run() -> void:
	print("── X4 水晶跨局残留 ──")
	var start_ok: bool = _gl.start_run() and _gl.state == GameConst.GameStatus.PLAYING
	_gl._on_crystal_spawn_requested(Vector2(300, 400))
	var c := _gl.active_crystal
	var spawned: bool = c != null and Crystal.active == c and c.alive
	# GAME_OVER：水晶不清（结算屏后台残留无副作用——A12 H3）
	_gl.change_state(GameConst.GameStatus.GAME_OVER)
	var survive: bool = c.alive and Crystal.active == c and _gl.active_crystal == c
	# 重开：_reset_run_state → _clear_battlefield 统一收 → 双源归 null；start_wave(1) 前已清
	var restart_ok: bool = _gl.restart_run() \
		and _gl.state == GameConst.GameStatus.PLAYING \
		and _gl.active_crystal == null and Crystal.active == null
	_check("X4：独立复算④——带水晶局 → GAME_OVER 不清（晶存活）→ restart_run → active 双源 null（下局 start_wave 前清链路）",
		start_ok and spawned and survive and restart_ok,
		"start=%s spawned=%s survive=%s restart=%s"
			% [str(start_ok), str(spawned), str(survive), str(restart_ok)])


# ── X8 K_gold=0.5 跳过补偿 + granted 不派发 ───────────────────────────
func _test_x8_skip_gold_k05() -> void:
	print("── X8 K_gold=0.5 跳过 ──")
	_gl.chip_handler.blessing_stats[&"gold_gain"] = 0.5   # K_gold = 0.5（blessing 段加和）
	var gold0: int = _gl.gold
	var skipped0: int = _gl.blessing_handler.blessings_skipped
	var granted_box := {"n": 0}                   # 引用型计数盒（lambda 按引用捕获）
	var probe := func(_k: StringName, _w: int) -> void: granted_box["n"] += 1
	EventBus.blessing_granted.connect(probe)
	_gl._on_wave_cleared_blessing(6)              # w>=2 直驱开门（复用 X4 重开后的 PLAYING 态）
	var opened: bool = _gl.state == GameConst.GameStatus.SHOP and _gl.blessing_ui.is_open
	_gl.blessing_ui.skip_requested.emit()
	EventBus.blessing_granted.disconnect(probe)
	# 手算：15 × (1+0.5) = 22.5 → int(round(22.5)) = 23
	var gold_ok: bool = _gl.gold == gold0 + 23
	var back_ok: bool = _gl.state == GameConst.GameStatus.PLAYING \
		and _gl.blessing_handler.blessings_skipped == skipped0 + 1
	_check("X8：跳过补偿 K_gold=0.5——skip → gold 恰 +23（15×1.5 round）+ skipped 遥测 +1 + blessing_granted 零派发 + 回 PLAYING",
		opened and gold_ok and back_ok and int(granted_box["n"]) == 0,
		"opened=%s gold %d→%d back=%s granted=%d"
			% [str(opened), gold0, _gl.gold, str(back_ok), int(granted_box["n"])])


# ── X12 水晶触发面 veto（激光/近战不触发：仅 ProjectileBase 通道） ────
func _test_x12_trigger_surface_veto() -> void:
	print("── X12 触发面 veto ──")
	# 全 scripts/ 递归扫描：_check_crystal_hit() 调用语法仅 projectile_base.gd
	#（crystal.gd 头注释的文档引用无 () 不计；激光/近战/其余零触发面）
	var hits: Array[String] = []
	_scan_dir("res://scripts", hits)
	var veto_ok: bool = hits.size() == 1 \
		and hits[0] == "res://scripts/combat/projectile/projectile_base.gd"
	_check("X12：水晶触发面 veto——_check_crystal_hit() 调用全 scripts 仅 projectile_base.gd（激光/近战 AOE 与敌弹均无触发面）",
		veto_ok, "hits=%s" % str(hits))


func _scan_dir(p_dir_path: String, p_hits: Array[String]) -> void:
	var dir := DirAccess.open(p_dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		var full := p_dir_path + "/" + name
		if dir.current_is_dir():
			if not name.begins_with("."):
				_scan_dir(full, p_hits)
		elif name.ends_with(".gd"):
			if _read_source(full).contains("_check_crystal_hit()"):
				p_hits.append(full)
		name = dir.get_next()
	dir.list_dir_end()


func _test_x13_reset_run_clears_resonance() -> void:
	print("── X13 reset_run 单独调用清共鸣表 ──")
	# v1.3.0 审查 Important 回归：reset_run 必须清 _resonance_counts（漏清时绕过
	# rebuild 直调 reset 会留共鸣计数残留——XE1 同族）；rm/精通表同口径复查
	var sys := _make_resonance_sys("Pkg13XResetSys", [
		"res://resources/traits/ELE_IGNITE.tres",
		"res://resources/traits/ELE_IGNITE.tres",
	])
	var pre: bool = sys.resonance_attach_factor(GameConst.Element.FIR) > 1.2
	sys.reset_run()
	var counts_zero: bool = sys.resonance_attach_factor(GameConst.Element.FIR) == 1.0 \
		and sys.resonance_reaction_factor(GameConst.Element.FIR) == 1.0 \
		and sys.reaction_mult() == 1.0 and sys.mastery_layers() == 0
	_check("X13：reset_run 单独调用后三表全清（含 _resonance_counts）",
		pre and counts_zero,
		"pre=%s attach=%s reaction=%s rm=%s mastery=%s" % [str(pre),
			str(sys.resonance_attach_factor(GameConst.Element.FIR)),
			str(sys.resonance_reaction_factor(GameConst.Element.FIR)),
			str(sys.reaction_mult()), str(sys.mastery_layers())])

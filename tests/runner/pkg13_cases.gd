# tests/runner/pkg13_cases.gd
# v1.3.0 自测用例体（由 test_pkg13.gd 入口在 autoload 就绪后运行时加载编译）。
# 覆盖冻结方案 pkg13 用例组 V57~V78（A12_v1.3.0_design.md §7；每恰 1 断言）。
# 混合夹具：V57~V66/V70~V74 = pkg12 式微夹具（真件管线 seed 42 + 局部 ElementalSystem）；
#           V67 = 裸 WaveDirector（probe rng 镜像 seed 1001）；
#           V68/V69/V75~V78 = pkg6 式 GameLoop 完整 Boot。
# 执行序纪律：微夹具纯净面（V57~V66）先行 → V67 → V70~V74（微水晶，共享 _sys 恒零共鸣）→
#             拆微世界 → GameLoop 段 V68/V69/V77/V75/V76/V78（V77 先建局、V75 复用 PLAYING 态）。
# 确定性：真件 DamagePipeline（seed 42）+ crit_rate=0 + 固定坐标/面板 + seed 1001 probe 镜像。
extends RefCounted

const BALLISTIC_SCENE := "res://scenes/combat/projectiles/ballistic_projectile.tscn"
const ENEMY_SCENE := "res://scenes/combat/enemies/enemy.tscn"
const DT := 1.0 / 120.0
const TRAIT_FIR := "res://resources/traits/ELE_IGNITE.tres"
const TRAIT_ICE := "res://resources/traits/ELE_FREEZE.tres"
const TRAIT_LTG := "res://resources/traits/ELE_SHOCK.tres"
const TRAIT_WAT := "res://resources/traits/ELE_TIDE.tres"

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []

# ── 微夹具（pkg12 模式） ──
var _proj_pool: ProjectilePool
var _enemy_pool: EnemyPool
var _grid: SpaceGrid
var _pipeline: DamagePipeline
var _sys: ElementalSystem                       # 微世界共享系统（零共鸣基线锚）
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
	_test_v57_scanner()                            # V57
	_test_v58_suffix()                             # V58
	_test_v59_attach_resonance()                   # V59
	_test_v60_threshold_split()                    # V60
	_test_v61_reaction_arms()                      # V61
	_test_v62_shatter_resonance()                  # V62
	_test_v63_amplify_resonance()                  # V63
	_test_v64_rebuild_closure()                    # V64
	_test_v65_identity_anchor()                    # V65
	_test_v66_hud_suffix()                         # V66
	_test_v67_roll_sequence()                      # V67
	_test_v70_proj_crystal_collision()             # V70
	_test_v71_fir_arm()                            # V71
	_test_v72_ice_wat_arms()                       # V72
	_test_v73_ltg_arm()                            # V73
	_test_v74_kin_arm()                            # V74
	_teardown_micro()
	_boot_game_loop()
	_test_v68_spawn_replace()                      # V68
	_test_v69_dissolve_exits()                     # V69
	_test_v77_production_rebuild()                 # V77（先建局）
	_test_v75_skip_gold()                          # V75（复用 PLAYING 态）
	_test_v76_skip_surface()                       # V76
	_test_v78_closure()                            # V78
	_teardown_game_loop()
	_summary()


func fail_count() -> int:
	return _fail


# ── 支撑（pkg12 同款） ─────────────────────────────────────────────
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
	_proj_pool.name = "Pkg13ProjPool"
	tree.get_root().add_child(_proj_pool)
	_proj_pool.setup(&"pkg13_test", load(BALLISTIC_SCENE), 64)
	var ep := EnemyPool.new()
	ep.name = "Pkg13EnemyPool"
	tree.get_root().add_child(ep)
	ep.setup(&"pkg13_enemy", load(ENEMY_SCENE), 48)
	_enemy_pool = ep
	_grid = SpaceGrid.new()
	_grid.configure(Vector2(720, 1280), 192.0)
	_alive_enemies.clear()
	_captured.clear()
	_pipeline = DamagePipeline.new()
	_pipeline.set_rng_seed(42)
	_sys = ElementalSystem.new()
	_sys.name = "Pkg13ElementalSystem"
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


func _last_result() -> DamageResult:
	if _captured.is_empty():
		return null
	return _captured[_captured.size() - 1]


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
	# 用例间隔离：全部宿主系统注销 + 归还（池化复用 spawn 全量重置）
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
		c.dissolve()                              # 同屏至多 1 颗——单点消散即净


func _panel() -> Dictionary:
	# 零暴击零加算面板（伤害手算锚：final = base_atk × ∏M，resist 0）
	return {
		"base_atk": 100.0, "crit_rate": 0.0, "crit_mult": 2.0,
		"flat_bonus": 0.0, "add_entries": [], "chip_atk_pct": 0.0,
	}


func _spawn_proj(p_element: int, p_pos: Vector2, p_attach: float = 0.0, p_pierce: int = 1,
		p_weapon: WeaponBase = null, p_last_damage: float = -1.0,
		p_sys: ElementalSystem = null) -> ProjectileBase:
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
		"team": 0,
		"position": p_pos,
	}
	if p_weapon != null:
		params["weapon_ref"] = p_weapon
	proj.spawn(params)
	if p_last_damage >= 0.0:
		proj.last_hit_damage = p_last_damage      # 水晶 LTG 臂基数预置
	return proj


func _fire_at(p_proj: ProjectileBase) -> void:
	_captured.clear()
	_bump()
	_pipeline.begin_frame()
	p_proj.tick(DT)


func _gauge(p_enemy: Node2D, p_element: int, p_value: float) -> void:
	# 共享 _sys 非满槽预置附着（无状态触发）；snapshot 100 供剧变快照通道
	_sys.apply_attach(p_enemy, p_element, p_value, {"snapshot": 100.0})


func _gauge_on(p_sys: ElementalSystem, p_enemy: Node2D, p_element: int, p_value: float) -> void:
	# 局部系统版预置附着（V61~V63 共鸣源隔离）
	p_sys.apply_attach(p_enemy, p_element, p_value, {"snapshot": 100.0})


func _detect_on(p_sys: ElementalSystem) -> void:
	_captured.clear()
	_bump()
	_pipeline.begin_frame()
	p_sys.detect_reactions()


func _read_source(p_path: String) -> String:
	var f := FileAccess.open(p_path, FileAccess.READ)
	if f == null:
		return ""
	return f.get_as_text()


# ── 共鸣微夹具（真实 WeaponBase + stub 宿主；attach_trait 走生产 rebuild 通道） ──
func _make_micro_weapon_data() -> WeaponData:
	_wd_counter += 1
	var d := WeaponData.new()
	d.id = StringName("W_PKG13_%d" % _wd_counter)
	d.display_name = "Pkg13 测试武器 %d" % _wd_counter
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
	w.name = "Pkg13Weapon_%d" % _wd_counter
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
	# 逐武器挂 p_trait_paths[i] 词条（attach_trait → rebuild_registries 生产通道；
	# stub 宿主承载 weapon_slots——null player 只清空，不产共鸣）
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
	c.name = "Pkg13Crystal"
	tree.get_root().add_child(c)
	c.position = p_pos
	c.activate(_sys, _grid)
	return c


# ── V57 扫描器 ────────────────────────────────────────────────────
func _test_v57_scanner() -> void:
	print("── V57 扫描器 ──")
	var sys := _make_resonance_sys("Pkg13V57", [])
	var w1 := _make_micro_weapon(sys, Vector2(100, 40))
	var w2 := _make_micro_weapon(sys, Vector2(140, 40))
	var w3 := _make_micro_weapon(sys, Vector2(180, 40))
	var stub := _make_stub_player([w1, w2, w3])
	var ignite: TraitData = load(TRAIT_FIR)
	var freeze: TraitData = load(TRAIT_ICE)
	var tide: TraitData = load(TRAIT_WAT)
	w1.attach_trait(ignite)
	w1.attach_trait(ignite)                       # 层 2（仍恰计 1 元素）
	w2.attach_trait(ignite)
	w2.attach_trait(freeze)                       # 平层 tie → 后挂胜（ICE）
	w3.attach_trait(tide)
	var counts := ElementalSystem.weapon_element_counts(stub)
	var expected: Array[int] = [0, 1, 1, 0, 1]
	var counts_ok := counts.size() == 5 and counts == expected
	var null_ok := ElementalSystem.weapon_element_counts(null) == [0, 0, 0, 0, 0]
	_check("V57：扫描器——三武器恰计 [FIR1,ICE1,WAT1]（每武器恰 1 元素/tie 后挂胜/层数不叠加）；null 全 0",
		counts_ok and null_ok,
		"counts=%s null=%s" % [str(counts), str(ElementalSystem.weapon_element_counts(null))])


# ── V58 后缀 ──────────────────────────────────────────────────────
func _test_v58_suffix() -> void:
	print("── V58 后缀 ──")
	var sys := _make_resonance_sys("Pkg13V58", [])
	var ignite: TraitData = load(TRAIT_FIR)
	var freeze: TraitData = load(TRAIT_ICE)
	# stubA：双火 → 「 共鸣:火×2」
	var wa1 := _make_micro_weapon(sys, Vector2(100, 80))
	var wa2 := _make_micro_weapon(sys, Vector2(140, 80))
	var stub_a := _make_stub_player([wa1, wa2])
	wa1.attach_trait(ignite)
	wa2.attach_trait(ignite)
	var two := ElementalSystem.resonance_suffix(stub_a)
	# stubB：双火 + 双冰 → FIR..WAT 序「 共鸣:火×2·冰×2」
	var wb1 := _make_micro_weapon(sys, Vector2(180, 80))
	var wb2 := _make_micro_weapon(sys, Vector2(220, 80))
	var wb3 := _make_micro_weapon(sys, Vector2(260, 80))
	var wb4 := _make_micro_weapon(sys, Vector2(300, 80))
	var stub_b := _make_stub_player([wb1, wb2, wb3, wb4])
	wb1.attach_trait(ignite)
	wb2.attach_trait(ignite)
	wb3.attach_trait(freeze)
	wb4.attach_trait(freeze)
	var both := ElementalSystem.resonance_suffix(stub_b)
	# stubC：单火单冰（平层后挂胜 → 单 ICE）→ 无共鸣 ""
	var wc1 := _make_micro_weapon(sys, Vector2(340, 80))
	var wc2 := _make_micro_weapon(sys, Vector2(380, 80))
	var stub_c := _make_stub_player([wc1, wc2])
	wc1.attach_trait(ignite)
	wc2.attach_trait(freeze)
	var none := ElementalSystem.resonance_suffix(stub_c)
	var empty := ElementalSystem.resonance_suffix(null)
	_check("V58：后缀——双火「 共鸣:火×2」/ 双火双冰「 共鸣:火×2·冰×2」（FIR..WAT 序 · 连接）/ 无共鸣 \"\"/ null \"\"",
		two == " 共鸣:火×2" and both == " 共鸣:火×2·冰×2" and none == "" and empty == "",
		"two=%s both=%s none=%s empty=%s" % [two, both, none, empty])


# ── V59 附着共鸣 ──────────────────────────────────────────────────
func _test_v59_attach_resonance() -> void:
	print("── V59 附着共鸣 ──")
	var sys := _make_resonance_sys("Pkg13V59", [TRAIT_FIR, TRAIT_FIR])
	var counts_ok: bool = sys._resonance_counts[GameConst.Element.FIR] == 2
	var e := _spawn_enemy(_make_enemy_data("V59_A"), Vector2(120, 200))
	sys.register_host(e)
	sys.apply_attach(e, GameConst.Element.FIR, 22.0)
	var st: ElementalState = e.get("elemental")
	var fir_ok: bool = st != null and st.gauges[GameConst.Element.FIR] == 27.5   # 22×1.25 位级
	var e2 := _spawn_enemy(_make_enemy_data("V59_B"), Vector2(400, 200))
	sys.register_host(e2)
	sys.apply_attach(e2, GameConst.Element.ICE, 22.0)
	var st2: ElementalState = e2.get("elemental")
	var ice_ok: bool = st2 != null and st2.gauges[GameConst.Element.ICE] == 22.0   # 异元素 ×1.0
	_check("V59：附着共鸣——FIR×2 → 22×1.25=27.5（位级）；ICE 不吃火共鸣 22.0；扫描计数 2",
		counts_ok and fir_ok and ice_ok,
		"counts=%s fir=%s ice=%s" % [str(sys._resonance_counts),
			str(st.gauges[GameConst.Element.FIR] if st != null else -1.0),
			str(st2.gauges[GameConst.Element.ICE] if st2 != null else -1.0)])


# ── V60 阈值分立 ──────────────────────────────────────────────────
func _test_v60_threshold_split() -> void:
	print("── V60 阈值分立 ──")
	var sys3 := _make_resonance_sys("Pkg13V60A", [TRAIT_FIR, TRAIT_FIR, TRAIT_FIR])
	var three_ok: bool = sys3.resonance_reaction_factor(GameConst.Element.FIR) \
			== ElementalSystem.RESONANCE_REACTION_MULT \
		and sys3.resonance_attach_factor(GameConst.Element.FIR) \
			== ElementalSystem.RESONANCE_ATTACH_MULT
	var sys2 := _make_resonance_sys("Pkg13V60B", [TRAIT_FIR, TRAIT_FIR])
	var two_ok: bool = sys2.resonance_reaction_factor(GameConst.Element.FIR) == 1.0 \
		and sys2.resonance_attach_factor(GameConst.Element.FIR) \
			== ElementalSystem.RESONANCE_ATTACH_MULT
	var kin_ok: bool = sys3.resonance_reaction_factor(GameConst.Element.KIN) == 1.0 \
		and sys3.resonance_attach_factor(-1) == 1.0
	_check("V60：阈值分立——≥3 反应 1.15 + 附着仍 1.25；≥2 反应 1.0；KIN/越界恒 1.0",
		three_ok and two_ok and kin_ok,
		"three=%s two=%s kin=%s" % [str(three_ok), str(two_ok), str(kin_ok)])


# ── V61 反应臂 ────────────────────────────────────────────────────
func _test_v61_reaction_arms() -> void:
	print("── V61 反应臂 ──")
	_purge_enemies()
	var sys := _make_resonance_sys("Pkg13V61", [TRAIT_WAT, TRAIT_WAT, TRAIT_WAT])
	var v := _spawn_enemy(_make_enemy_data("V61_V", 4000.0), Vector2(100, 200))
	sys.register_host(v)
	_gauge_on(sys, v, GameConst.Element.WAT, 30.0)
	_gauge_on(sys, v, GameConst.Element.FIR, 30.0)
	var c2 := _spawn_enemy(_make_enemy_data("V61_C", 4000.0), Vector2(500, 200))
	sys.register_host(c2)
	_gauge_on(sys, c2, GameConst.Element.WAT, 30.0)
	_gauge_on(sys, c2, GameConst.Element.LTG, 30.0)
	_detect_on(sys)                               # 一帧双敌各一反应（汽爆 + 导电）
	var blast := -1.0
	var conduct := -1.0
	for r in _captured:
		if r.popup_style == GameConst.PopupStyle.REACTION \
				and r.element == GameConst.ReactionType.RXN_WAT_FIR \
				and r.target_uid == int(v.get("uid")):
			blast = r.final_value
		if r.popup_style == GameConst.PopupStyle.REACTION \
				and r.element == GameConst.ReactionType.RXN_WAT_LTG \
				and r.target_uid == int(c2.get("uid")):
			conduct = r.final_value
	var arms_ok := _approx(blast, 69.0) and _approx(conduct, 103.5)   # 60×1.15 / 90×1.15
	_check("V61：反应臂（WAT≥3 双元素连乘 1.15×1.0）——汽爆主 60×1.15=69 / 导电主 0.9×1.15=103.5",
		arms_ok, "blast=%s conduct=%s" % [str(blast), str(conduct)])


# ── V62 破碎共鸣 ──────────────────────────────────────────────────
func _test_v62_shatter_resonance() -> void:
	print("── V62 破碎共鸣 ──")
	_purge_enemies()
	var sys := _make_resonance_sys("Pkg13V62", [TRAIT_WAT, TRAIT_WAT, TRAIT_WAT])
	var e := _spawn_enemy(_make_enemy_data("V62", 2000.0), Vector2(120, 800))
	sys.register_host(e)
	_gauge_on(sys, e, GameConst.Element.WAT, 30.0)
	_gauge_on(sys, e, GameConst.Element.ICE, 30.0)
	_detect_on(sys)                               # 冻结（WAT+ICE）
	var hp0: float = e.hp
	for i in range(3):
		_fire_at(_spawn_proj(GameConst.Element.KIN, e.global_position))
	_captured.clear()
	sys.tick(DT)                                  # 帧末破碎：0.4×100×1.0×(1.15×1.0)=46
	var settle := -1.0
	for r in _captured:
		if r.element == GameConst.ReactionType.RXN_WAT_ICE \
				and r.popup_style == GameConst.PopupStyle.REACTION:
			settle = r.final_value
	_check("V62：破碎共鸣——(WAT,ICE) 臂 0.4×100×1.15=46 落血",
		_approx(settle, 46.0) and _approx(e.hp, hp0 - 300.0 - 46.0, 0.01),
		"settle=%s hp=%s" % [str(settle), str(e.hp)])


# ── V63 增幅共鸣 ──────────────────────────────────────────────────
func _test_v63_amplify_resonance() -> void:
	print("── V63 增幅共鸣 ──")
	_purge_enemies()
	var sys := _make_resonance_sys("Pkg13V63", [TRAIT_FIR, TRAIT_FIR, TRAIT_FIR])
	var e := _spawn_enemy(_make_enemy_data("V63", 2000.0), Vector2(120, 400))
	sys.register_host(e)
	_gauge_on(sys, e, GameConst.Element.ICE, 30.0)
	_fire_at(_spawn_proj(GameConst.Element.FIR, e.global_position, 30.0, 1, null, -1.0, sys))
	var r := _last_result()
	var melt_ok: bool = r != null \
		and _approx(float(r.pool_breakdown.get(&"amplify", -1.0)), 0.725) \
		and _approx(r.final_value, 172.5)           # 100×1.5×1.15
	var st: ElementalState = e.get("elemental")
	var consumed: bool = st != null and _approx(st.gauges[GameConst.Element.ICE], 0.0)
	_check("V63：增幅共鸣——火直击融化吃火共鸣 1.5×1.15=1.725（contrib 0.725 / final 172.5 / ICE 清）",
		melt_ok and consumed,
		"brk=%s fin=%s" % [str(r.pool_breakdown if r != null else {}),
			str(r.final_value if r != null else -1.0)])


# ── V64 rebuild 收口 ──────────────────────────────────────────────
func _test_v64_rebuild_closure() -> void:
	print("── V64 rebuild 收口 ──")
	var sys := _make_resonance_sys("Pkg13V64", [])
	var w1 := _make_micro_weapon(sys, Vector2(100, 120))
	var stub := _make_stub_player([w1])
	var void_t: TraitData = load("res://resources/traits/ELE_REACTION_VOID.tres")
	var mastery := _make_mastery_data()
	var ok := true
	var detail := ""
	if not (w1.attach_trait(void_t) and _approx(sys.reaction_mult(), 1.8)):
		ok = false
		detail = "VOID 注册失败 mult=%s" % str(sys.reaction_mult())
	if ok and not (w1.attach_trait(mastery) and w1.attach_trait(mastery)
			and _approx(sys.reaction_mult(), 2.7)):                       # 1.8×1.5
		ok = false
		detail = "精通叠加失败 mult=%s" % str(sys.reaction_mult())
	if ok:
		w1.trait_stack.detach_last(true)          # 摘 1 层精通（生产 strip 摘层语义）
		sys.rebuild_registries(stub)              # strip 收口重算
		if not _approx(sys.reaction_mult(), 2.25):                            # 1.8×1.25
			ok = false
			detail = "摘层重算失败 mult=%s" % str(sys.reaction_mult())
	if ok:
		w1.trait_stack.detach_last(true)          # 摘 VOID
		w1.trait_stack.detach_last(true)          # 摘末层精通
		sys.rebuild_registries(stub)
		if not _approx(sys.reaction_mult(), 1.0):
			ok = false
			detail = "清空重算失败 mult=%s" % str(sys.reaction_mult())
	if ok:
		sys.register_mastery(31337, 2, 0.25)      # ★直调通道原样保留（冻结夹具依赖）
		if not _approx(sys.reaction_mult(), 1.5):
			ok = false
			detail = "register_* 直调通道失效 mult=%s" % str(sys.reaction_mult())
	_check("V64：rebuild 收口——挂载重算 1.8→2.7 / 摘层重算 2.25 / 全摘回 1.0 / register_mastery 直调通道保留",
		ok, detail)


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


# ── V65 ★无共鸣逐位恒等锚 ────────────────────────────────────────
func _test_v65_identity_anchor() -> void:
	print("── V65 恒等锚 ──")
	_purge_enemies()
	# 共享 _sys 零共鸣（无武器注册）：attach 22 位级 / melt 150 / vapor 200
	var e := _spawn_enemy(_make_enemy_data("V65_A", 2000.0), Vector2(120, 600))
	_sys.register_host(e)
	_sys.apply_attach(e, GameConst.Element.FIR, 22.0)
	var st: ElementalState = e.get("elemental")
	var attach_bit_exact: bool = st != null and st.gauges[GameConst.Element.FIR] == 22.0
	_gauge(e, GameConst.Element.ICE, 30.0)
	_fire_at(_spawn_proj(GameConst.Element.FIR, e.global_position))
	var r1 := _last_result()
	var melt_ok: bool = r1 != null and is_equal_approx(r1.final_value, 150.0) \
		and is_equal_approx(float(r1.pool_breakdown.get(&"amplify", -1.0)), 0.5)
	var e2 := _spawn_enemy(_make_enemy_data("V65_B", 2000.0), Vector2(400, 600))
	_sys.register_host(e2)
	_gauge(e2, GameConst.Element.FIR, 30.0)
	_fire_at(_spawn_proj(GameConst.Element.ICE, e2.global_position))
	var r2 := _last_result()
	var vapor_ok: bool = r2 != null and is_equal_approx(r2.final_value, 200.0)
	_check("V65：★无共鸣逐位恒等——attach 22.0 位级 / melt 150×1.0×1.0 / vapor 200×1.0×1.0（IEEE ×1.0 恒等）",
		attach_bit_exact and melt_ok and vapor_ok,
		"attach=%s melt=%s vapor=%s" % [str(attach_bit_exact),
			str(r1.final_value if r1 != null else -1.0),
			str(r2.final_value if r2 != null else -1.0)])


# ── V66 HUD 后缀 ──────────────────────────────────────────────────
func _test_v66_hud_suffix() -> void:
	print("── V66 HUD 后缀 ──")
	var hud := HUD.new()
	hud.name = "Pkg13Hud"
	tree.get_root().add_child(hud)
	var sys := _make_resonance_sys("Pkg13V66", [])
	var ignite: TraitData = load(TRAIT_FIR)
	var w1 := _make_micro_weapon(sys, Vector2(100, 160))
	var w2 := _make_micro_weapon(sys, Vector2(140, 160))
	var stub := _make_stub_player([w1, w2])
	w1.attach_trait(ignite)
	w2.attach_trait(ignite)
	hud.player = stub
	var with_res: String = hud._build_summary()
	w2.trait_stack.detach_last(true)              # 摘层 → 单火 → 无共鸣
	var without_res: String = hud._build_summary()
	hud.free()
	_check("V66：HUD Build 行——双火尾追「 共鸣:火×2」；无共鸣串与 v1.2.0 逐位恒等",
		with_res == "Build  W:2 T:2 MP:0 共鸣:火×2" and without_res == "Build  W:2 T:1 MP:0",
		"with=%s without=%s" % [with_res, without_res])


# ── V67 roll 序列（裸 WaveDirector + probe 镜像） ─────────────────
func _test_v67_roll_sequence() -> void:
	print("── V67 roll 序列 ──")
	var wd := WaveDirector.new()
	wd.name = "Pkg13WaveDirector"
	tree.get_root().add_child(wd)
	var captured: Array[Vector2] = []
	wd.crystal_spawn_requested.connect(func(pos: Vector2) -> void: captured.append(pos))
	var probe := RandomNumberGenerator.new()
	probe.seed = WaveDirector.CRYSTAL_RNG_SEED
	var ok := true
	var detail := ""
	var hits := 0
	for w in range(1, 32):
		captured.clear()
		wd.start_wave(w)
		if w < WaveDirector.CRYSTAL_START_WAVE or w % 10 == 0:
			if not captured.is_empty():
				ok = false
				detail = "w%d 不应出现（早返不消耗）" % w
				break
			continue                                # 早返：probe 不推进
		if probe.randf() < WaveDirector.CRYSTAL_CHANCE:
			var expect := Vector2(
				probe.randf_range(WaveDirector.CRYSTAL_MARGIN_X,
					720.0 - WaveDirector.CRYSTAL_MARGIN_X),
				probe.randf_range(WaveDirector.CRYSTAL_Y_MIN, WaveDirector.CRYSTAL_Y_MAX))
			if captured.size() != 1 or not captured[0].is_equal_approx(expect):
				ok = false
				detail = "w%d 落点失配 %s vs %s" % [w, str(captured), str(expect)]
				break
			hits += 1
		elif not captured.is_empty():
			ok = false
			detail = "w%d 未中却出现" % w
			break
	wd.free()
	_check("V67：roll 序列——w1~31 start_wave 逐波对账 seed1001 probe（w<8/Boss 早返不消耗；未中消耗一次 draw；命中落点域内）",
		ok and hits > 0, "%s hits=%d" % [detail, hits])


# ── V70 弹-晶碰撞 ─────────────────────────────────────────────────
func _test_v70_proj_crystal_collision() -> void:
	print("── V70 弹-晶碰撞 ──")
	var c := _spawn_crystal(Vector2(400, 300))
	var uid_ok: bool = c.alive and Crystal.active == c and c.uid > 0
	var proj := _spawn_proj(GameConst.Element.KIN, Vector2(400, 300), 0.0, 2)
	_fire_at(proj)                                # 命中水晶 → shatter（KIN 无武器守卫跳过 AOE）
	var shattered: bool = not c.alive and Crystal.active == null
	var proj_alive: bool = proj._live and proj.pierce_left == 2 \
		and proj.hits_this_frame.has(c.uid)       # ★弹不耗穿透继续飞 + 一帧一晶一条
	_check("V70：弹-晶碰撞——命中碎晶（active 摘除）+ 弹不耗穿透继续飞（pierce 2 不变）+ 帧聚合去重键",
		uid_ok and shattered and proj_alive,
		"uid=%s shattered=%s alive=%s pierce=%d" % [str(uid_ok), str(shattered),
			str(proj._live), proj.pierce_left])


# ── V71 FIR 臂 ────────────────────────────────────────────────────
func _test_v71_fir_arm() -> void:
	print("── V71 FIR 臂 ──")
	_purge_enemies()
	var weapon := _make_micro_weapon(_sys, Vector2(300, 660))
	var near := _spawn_enemy(_make_enemy_data("V71_N", 1000.0), Vector2(350, 600))
	var far := _spawn_enemy(_make_enemy_data("V71_F", 1000.0), Vector2(500, 600))
	var c := _spawn_crystal(Vector2(300, 600))
	_fire_at(_spawn_proj(GameConst.Element.FIR, Vector2(300, 600), 0.0, 1, weapon))
	# FIR 臂：weapon.settle_aoe(晶位, 90, 100×0.8=80, secondary) → 近敌 -80 / 远敌(200px) 不吃
	var aoe_ok := _approx(near.hp, 920.0, 0.01) and _approx(far.hp, 1000.0, 0.01)
	var dissolved: bool = not c.alive and Crystal.active == null
	_check("V71：FIR 臂——90px AOE 0.8×panel=80（近吃远不吃 secondary 通道）+ 结算尾消散",
		aoe_ok and dissolved,
		"near=%s far=%s dissolved=%s" % [str(near.hp), str(far.hp), str(dissolved)])


# ── V72 ICE/WAT 臂 ────────────────────────────────────────────────
func _test_v72_ice_wat_arms() -> void:
	print("── V72 ICE/WAT 臂 ──")
	_purge_enemies()
	var near := _spawn_enemy(_make_enemy_data("V72_N", 2000.0), Vector2(350, 600))
	var far := _spawn_enemy(_make_enemy_data("V72_F", 2000.0), Vector2(520, 600))
	_sys.register_host(near)                      # 附着宿主（apply_attach 状态容器前提）
	_sys.register_host(far)
	var ci := _spawn_crystal(Vector2(300, 600))
	_fire_at(_spawn_proj(GameConst.Element.ICE, Vector2(300, 600)))
	var st_n: ElementalState = near.get("elemental")
	var st_f: ElementalState = far.get("elemental")
	var ice_ok := st_n != null and st_f != null \
		and _approx(st_n.gauges[GameConst.Element.ICE], 50.0) \
		and _approx(st_f.gauges[GameConst.Element.ICE], 0.0)
	var cw := _spawn_crystal(Vector2(300, 700))
	_fire_at(_spawn_proj(GameConst.Element.WAT, Vector2(300, 700)))
	var wat_ok := st_n != null and _approx(st_n.gauges[GameConst.Element.WAT], 50.0)
	_check("V72：ICE/WAT 臂——100px 半径附着 50（窄相外不吃；经 apply_attach 入口 ×1.0 无共鸣）",
		ice_ok and wat_ok, "ice=%s wat=%s" % [str(ice_ok), str(wat_ok)])


# ── V73 LTG 臂 ────────────────────────────────────────────────────
func _test_v73_ltg_arm() -> void:
	print("── V73 LTG 臂 ──")
	_purge_enemies()
	var a1 := _spawn_enemy(_make_enemy_data("V73_A", 4000.0), Vector2(420, 600))
	var a2 := _spawn_enemy(_make_enemy_data("V73_B", 4000.0), Vector2(560, 600))
	_spawn_crystal(Vector2(300, 600))
	_fire_at(_spawn_proj(GameConst.Element.LTG, Vector2(300, 600), 0.0, 1, null, 200.0))
	# base = last_hit_damage 200 → hop1 35%×200=70（120px 内）/ hop2 70×0.6=42（链内 140px）
	var hit_ok := _approx(a1.hp, 3930.0, 0.01) and _approx(a2.hp, 3958.0, 0.01)
	_purge_enemies()
	var b1 := _spawn_enemy(_make_enemy_data("V73_C", 4000.0), Vector2(420, 600))
	_spawn_crystal(Vector2(300, 600))
	_fire_at(_spawn_proj(GameConst.Element.LTG, Vector2(300, 600)))   # last_hit_damage=0
	var fallback_ok := _approx(b1.hp, 3965.0, 0.01)                   # 回退 panel 100 → 35
	_check("V73：LTG 臂（H1）——base=last_hit_damage 200 → 70/42 链；缺省回退 panel 100 → 35",
		hit_ok and fallback_ok,
		"hit=%s fallback=%s a1=%s a2=%s b1=%s" % [str(hit_ok), str(fallback_ok),
			str(a1.hp), str(a2.hp), str(b1.hp)])


# ── V74 KIN 臂 ────────────────────────────────────────────────────
func _test_v74_kin_arm() -> void:
	print("── V74 KIN 臂 ──")
	_purge_enemies()
	var weapon := _make_micro_weapon(_sys, Vector2(300, 660))
	var near := _spawn_enemy(_make_enemy_data("V74_N", 1000.0), Vector2(350, 600))
	var c := _spawn_crystal(Vector2(300, 600))
	_fire_at(_spawn_proj(GameConst.Element.KIN, Vector2(300, 600), 0.0, 1, weapon))
	# KIN 臂：weapon.settle_aoe(晶位, 90, 100×0.4=40, secondary)
	var aoe_ok := _approx(near.hp, 960.0, 0.01)
	var dissolved: bool = not c.alive
	_check("V74：KIN 臂——90px 弱 AOE 0.4×panel=40 + 结算尾消散",
		aoe_ok and dissolved, "near=%s dissolved=%s" % [str(near.hp), str(dissolved)])


# ════════════════ GameLoop 段（pkg6 夹具模式） ════════════════════
func _boot_game_loop() -> void:
	_gl = GameLoop.new()
	_gl.name = "GameLoopUnderTest"
	tree.get_root().add_child(_gl)
	if not (_gl.boot_ready and _gl.state == GameConst.GameStatus.MENU):
		push_error("[pkg13] GameLoop Boot 异常（后续 GameLoop 段用例级联失败）")


func _teardown_game_loop() -> void:
	tree.paused = false
	if _gl != null:
		_gl.free()
		_gl = null


# ── V68 生成 / 顶替 ───────────────────────────────────────────────
func _test_v68_spawn_replace() -> void:
	print("── V68 生成顶替 ──")
	_gl._on_crystal_spawn_requested(Vector2(300, 400))
	var c1 := _gl.active_crystal
	var spawn_ok: bool = c1 != null and Crystal.active == c1 and c1.alive \
		and c1.position == Vector2(300, 400) and c1.z_index == 3 \
		and c1.elemental == _gl.elemental and c1.enemy_grid == _gl.enemy_grid
	_gl._on_crystal_spawn_requested(Vector2(200, 200))
	var c2 := _gl.active_crystal
	var replace_ok: bool = c2 != null and c2 != c1 and not c1.alive \
		and Crystal.active == c2 and c2.position == Vector2(200, 200)
	_check("V68：生成/顶替——active 双源一致 + 注入接线 + z3；二次请求旧晶消散同屏至多 1",
		spawn_ok and replace_ok,
		"spawn=%s replace=%s" % [str(spawn_ok), str(replace_ok)])


# ── V69 消散三出口 ────────────────────────────────────────────────
func _test_v69_dissolve_exits() -> void:
	print("── V69 消散出口 ──")
	# 出口①：波末 wave_cleared（w1 不触发赐福——态不变）
	_gl._on_crystal_spawn_requested(Vector2(300, 400))
	EventBus.emit_wave_cleared(1)
	var wave_ok: bool = _gl.active_crystal == null and Crystal.active == null
	# 出口②：清场（_clear_battlefield 尾）
	_gl._on_crystal_spawn_requested(Vector2(300, 400))
	_gl._clear_battlefield()
	var clear_ok: bool = _gl.active_crystal == null and Crystal.active == null
	# 出口③：击破尾 dissolve()（水晶侧真源：Crystal.active 摘除 + alive 翻 false；
	# GameLoop.active_crystal 陈旧引用由下一轮 _dissolve_crystal 的 valid 守卫收口——A12 §3.4）
	_gl._on_crystal_spawn_requested(Vector2(300, 400))
	var c := _gl.active_crystal
	c.dissolve()
	var direct_ok: bool = Crystal.active == null and not c.alive
	_check("V69：消散三出口——wave_cleared / _clear_battlefield / dissolve() 全部摘除 active 双源",
		wave_ok and clear_ok and direct_ok,
		"wave=%s clear=%s direct=%s" % [str(wave_ok), str(clear_ok), str(direct_ok)])


# ── V77 生产重算收口（先于 V75 建局） ─────────────────────────────
func _test_v77_production_rebuild() -> void:
	print("── V77 生产重算 ──")
	var start_ok: bool = _gl.start_run() and _gl.state == GameConst.GameStatus.PLAYING
	var primary: WeaponBase = _gl.player.weapon_slots[0]
	var ignite: TraitData = load(TRAIT_FIR)
	var attach1: bool = primary.attach_trait(ignite) \
		and _gl.elemental._resonance_counts[GameConst.Element.FIR] == 1
	_gl.player.unlock_slot(2)
	var w2 := _gl.player.add_weapon(_gl.registry.get_weapon(&"W2_gatling"))
	var attach2: bool = w2 != null and w2.attach_trait(ignite) \
		and _gl.elemental._resonance_counts[GameConst.Element.FIR] == 2 \
		and _gl.elemental.resonance_attach_factor(GameConst.Element.FIR) == 1.25
	var hud_text: String = _gl.hud._build_summary()
	var hud_ok: bool = hud_text.contains(" 共鸣:火×2")
	_gl._reset_run_state()
	var reset_ok: bool = _gl.elemental._resonance_counts == [0, 0, 0, 0, 0] \
		and not _gl.hud._build_summary().contains("共鸣")
	_check("V77：生产重算收口——start_run 后挂载/跨武器装机共鸣计数 1→2 + HUD 后缀；_reset_run_state 三表归零",
		start_ok and attach1 and attach2 and hud_ok and reset_ok,
		"start=%s a1=%s a2=%s hud=%s(%s) reset=%s" % [str(start_ok), str(attach1),
			str(attach2), str(hud_ok), hud_text, str(reset_ok)])


# ── V75 跳过补偿 ──────────────────────────────────────────────────
func _test_v75_skip_gold() -> void:
	print("── V75 跳过补偿 ──")
	var gold0: int = _gl.gold
	var skipped0: int = _gl.blessing_handler.blessings_skipped
	_gl._on_wave_cleared_blessing(5)              # w>=2 直驱开门（复用 V77 的 PLAYING 态）
	var opened: bool = _gl.state == GameConst.GameStatus.SHOP and _gl.blessing_ui.is_open
	_gl.blessing_ui.skip_requested.emit()
	var gold_ok: bool = _gl.gold == gold0 + 15    # K_gold=0 → 基础值恰 +15
	var back_ok: bool = _gl.state == GameConst.GameStatus.PLAYING \
		and not _gl.blessing_ui.is_open \
		and _gl.blessing_handler.blessings_skipped == skipped0 + 1
	_check("V75：跳过补偿——skip → gold 恰 +15（BLESSING_SKIP_GOLD 基础值）+ skipped 遥测 +1 + 回 PLAYING",
		opened and gold_ok and back_ok,
		"opened=%s gold %d→%d back=%s" % [str(opened), gold0, _gl.gold, str(back_ok)])


# ── V76 跳过面 ────────────────────────────────────────────────────
func _test_v76_skip_surface() -> void:
	print("── V76 跳过面 ──")
	var const_ok: bool = GameLoop.BLESSING_SKIP_GOLD == 15
	var desc_ok: bool = BlessingUI.DESC_TEXT == "选择一项赐福（跳过得 15 金币·基础值）"
	var btn_ok: bool = _gl.blessing_ui._skip_btn.text == "跳过（+15 金币）"
	_check("V76：跳过面——常量 15 + DESC 新文案 + 跳过按钮新文案",
		const_ok and desc_ok and btn_ok,
		"const=%s desc=%s btn=%s" % [str(const_ok), str(desc_ok),
			str(_gl.blessing_ui._skip_btn.text)])


# ── V78 收尾 + 管线 veto ──────────────────────────────────────────
func _test_v78_closure() -> void:
	print("── V78 收尾 ──")
	var version: String = ProjectSettings.get_setting("application/config/version", "")
	var version_ok := version == "1.5.0"          # v1.4.0 授权更新：version 随版本推进
	var progress := _read_source("res://PROGRESS.md")
	var progress_ok := (not progress.is_empty()) and progress.contains("1494") \
		and progress.contains("pkg13 22") and progress.contains("v1.3.0 增量")
	var a12 := _read_source("res://docs/analysis/A12_v1.3.0_design.md")
	var a12_ok := (not a12.is_empty()) and a12.contains("H1") and a12.contains("H2") \
		and a12.contains("H3") and a12.contains("RESONANCE_ATTACH_MULT")
	var pipe := _read_source(
		"res://scripts/core/damage/damage_pipeline.gd").to_lower()
	var veto_ok := (not pipe.is_empty()) and not pipe.contains("resonance") \
		and not pipe.contains("crystal")
	_check("V78：收尾——version=1.3.0 + PROGRESS 对账（1494/pkg13 22/v1.3.0 增量）+ A12 留痕含 H1~H3 + ★damage_pipeline.gd veto（不含 resonance/crystal）",
		version_ok and progress_ok and a12_ok and veto_ok,
		"version=%s progress=%s a12=%s veto=%s" % [version, str(progress_ok), str(a12_ok),
			str(veto_ok)])

# tests/runner/pkg11_cases.gd
# v1.1.0 自测用例体（由 test_pkg11.gd 入口在 autoload 就绪后运行时加载编译）。
# 覆盖冻结方案 pkg11 用例组 V25~V40（A10_v1.1.0_design.md；每恰 1 断言）：
#   V25 恒等护栏 / V26 融化 / V27 蒸发 / V28 排除面 / V29 穿透独立 / V30 管线 veto
#   V31 top-8 截断 / V32 联合钳 / V33 精通注册（E3）/ V34 φ 聚合（E3）/ V35 CD 分立
#   V36 遥测分键（E7）/ V37 popup 后缀（E7）/ V38 HUD MP（E3）/ V39 拼写回归 / V40 gauge 残留
# 执行序纪律：V32（注册 VOID 反应强化）与 V33/V34（注册精通）会污染 _sys 聚合状态——
# 纯净面用例（V25~V29/V40/V31）先行，污染源用例置末；V35/V39 与反应强化乘区无关。
# 确定性：真件 DamagePipeline（seed 42）+ crit_rate=0（不掷骰）+ 固定坐标/面板；
#         帧闸门经 GameConfig.frame_stamp 手动推进 + begin_frame 清幂等缓存。
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
var _pipeline: DamagePipeline
var _sys: ElementalSystem
var _alive_enemies: Array[Node2D] = []
var _captured: Array[DamageResult] = []        # damage_resolved 捕获（每次 _fire_at 清空）


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_ensure_autoloads()
	_setup_world()
	_test_v25_identity_guard()                    # V25
	_test_v26_melt()                              # V26
	_test_v27_vaporize()                          # V27
	_test_v28_exclusions()                        # V28
	_test_v29_pierce_independent()                # V29
	_test_v30_pipeline_veto()                     # V30
	_test_v40_gauge_residue()                     # V40（纯净面：melt/vapor 贡献不受 VOID 污染）
	_test_v31_top8()                              # V31
	_test_v35_cd_split()                          # V35（CD 与反应强化乘区无关）
	_test_v39_spelling()                          # V39
	_test_v32_joint_clamp()                       # V32（末位：注册 VOID ×1.8 污染源置末）
	_test_v33_mastery_register()                  # V33（局部 sys 隔离，不污染共享 _sys）
	_test_v34_phi_aggregate()                     # V34（局部 sys 隔离）
	_test_v38_hud_mastery()                       # V38
	_test_v36_telemetry_keys()                    # V36
	_test_v37_popup_suffix()                      # V37
	_teardown_world()
	_summary()


func fail_count() -> int:
	return _fail


# ── 支撑 ──────────────────────────────────────────────────────────
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


func _setup_world() -> void:
	_proj_pool = ProjectilePool.new()
	_proj_pool.name = "Pkg11ProjPool"
	tree.get_root().add_child(_proj_pool)
	_proj_pool.setup(&"pkg11_test", load(BALLISTIC_SCENE), 64)
	var ep := EnemyPool.new()
	ep.name = "Pkg11EnemyPool"
	tree.get_root().add_child(ep)
	ep.setup(&"pkg11_enemy", load(ENEMY_SCENE), 32)
	_enemy_pool = ep
	_grid = SpaceGrid.new()
	_grid.configure(Vector2(720, 1280), 192.0)
	_alive_enemies.clear()
	_captured.clear()
	_pipeline = DamagePipeline.new()
	_pipeline.set_rng_seed(42)
	_sys = ElementalSystem.new()
	_sys.name = "Pkg11ElementalSystem"
	tree.get_root().add_child(_sys)
	_sys.pipeline = _pipeline
	_sys.enemy_grid = _grid
	EventBus.damage_resolved.connect(_on_damage_resolved)


func _teardown_world() -> void:
	if EventBus.damage_resolved.is_connected(_on_damage_resolved):
		EventBus.damage_resolved.disconnect(_on_damage_resolved)
	_alive_enemies.clear()
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


func _panel() -> Dictionary:
	# 零暴击零加算面板（伤害手算锚：final = base_atk × ∏M，resist 0）
	return {
		"base_atk": 100.0, "crit_rate": 0.0, "crit_mult": 2.0,
		"flat_bonus": 0.0, "add_entries": [], "chip_atk_pct": 0.0,
	}


func _spawn_proj(p_element: int, p_pos: Vector2, p_attach: float = 30.0, p_pierce: int = 1,
		p_stack: TraitStack = null, p_elemental: ElementalSystem = null) -> ProjectileBase:
	var proj := _proj_pool.acquire() as ProjectileBase
	proj.damage_pipeline = _pipeline
	proj.enemy_grid = _grid
	proj.pool = _proj_pool
	proj.elemental = p_elemental if p_elemental != null else _sys
	proj.spawn({
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
		"trait_stack": p_stack,
	})
	return proj


func _fire_at(p_proj: ProjectileBase) -> void:
	# 单帧推进：清捕获 + 帧号推进 + 幂等缓存清空（GameLoop 帧序的测试侧替身）+ 一 tick
	_captured.clear()
	_bump()
	_pipeline.begin_frame()
	p_proj.tick(DT)


func _gauge(p_enemy: Node2D, p_element: int, p_value: float,
		p_sys: ElementalSystem = null) -> void:
	var sys := p_sys if p_sys != null else _sys
	sys.apply_attach(p_enemy, p_element, p_value)    # 非满槽预置附着（无状态触发）


func _make_fake_pool_stack(p_ids: Array, p_value: float) -> TraitStack:
	# 假乘区池宿主（MULT 直挂：ConditionId.NONE 无条件常驻，contrib = value）
	var stack := TraitStack.new()
	for pid in p_ids:
		var d := TraitData.new()
		d.id = StringName(String(pid))
		d.display_name = String(pid)
		d.pool = GameConst.PoolClass.MULT
		d.pool_id = StringName(String(pid))
		d.effect_id = &"EF_STAT"
		d.value = p_value
		d.cap_pool_p = 0.0
		stack.attach(d)
	return stack


func _read_source(p_path: String) -> String:
	var f := FileAccess.open(p_path, FileAccess.READ)
	if f == null:
		return ""
	return f.get_as_text()


# ── 武器夹具（pkg3 模式；E3 精通注册通道用） ──────────────────────
var _wd_counter: int = 0                       # WeaponData id 确定性计数器


func _merge_dict(p_base: Dictionary, p_over: Dictionary) -> Dictionary:
	var out := p_base.duplicate(true)
	for key in p_over:
		out[key] = p_over[key]
	return out


func _make_weapon_data(p_form: int, p_table: Dictionary = {}, p_segment: Dictionary = {}) -> WeaponData:
	_wd_counter += 1
	var d := WeaponData.new()
	d.id = StringName("W_PKG11_%d" % _wd_counter)
	d.display_name = "Pkg11 测试武器 %d" % _wd_counter
	d.form = p_form
	d.crit_rate = 0.0
	d.crit_dmg = 2.0
	d.hitbox_r = 6.0
	for i in range(5):
		var ls := WeaponLevelStats.new()
		ls.base_atk = float(p_table.get("base_atk", 10.0))
		ls.rof = float(p_table.get("rof", 5.0))
		ls.cd = float(p_table.get("cd", 0.5))
		ls.pierce = int(p_table.get("pierce", 1))
		ls.pellets = int(p_table.get("pellets", 1))
		d.upgrade_table.append(ls)
	match p_form:
		GameConst.WeaponForm.BALLISTIC:
			d.ballistic = _merge_dict(d.ballistic, p_segment)
		GameConst.WeaponForm.LASER:
			d.laser = _merge_dict(d.laser, p_segment)
		GameConst.WeaponForm.HOMING:
			d.homing = _merge_dict(d.homing, p_segment)
		_:
			d.melee = _merge_dict(d.melee, p_segment)
	return d


func _make_weapon(p_form: int, p_data: WeaponData, p_pos: Vector2,
		p_elemental: ElementalSystem) -> WeaponBase:
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
	w.name = "Pkg11Weapon_%d" % _wd_counter
	tree.get_root().add_child(w)
	w.position = p_pos
	w.setup(p_data, null, {
		"pipeline": _pipeline,
		"projectile_pool": _proj_pool,
		"enemy_grid": _grid,
		"laser_pool": null,
		"homing_pool": null,
		"elemental": p_elemental,
	})
	return w


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


func _first_live_proj_element(p_pool: ProjectilePool) -> int:
	var live: Variant = p_pool.get("_live_order")
	if live is Dictionary and not (live as Dictionary).is_empty():
		var node: Variant = (live as Dictionary).keys()[0]
		if node is ProjectileBase:
			return (node as ProjectileBase).element
	return -1


func _mount_stub_player(p_weapons: Array) -> Node2D:
	# v1.3.0 适配（A12 R1）：attach_trait 注册通道改为 rebuild_registries 全量重算
	#（扫 player.weapon_slots）——为持 ELEM 词条的测试武器挂 stub 宿主，
	# 使注册语义与生产路径一致（原夹具 weapon.player = null 仅清空）
	var psrc := GDScript.new()
	psrc.source_code = "extends Node2D\nvar weapon_slots: Array = []\n"
	psrc.reload()
	var stub: Node2D = psrc.new()
	tree.get_root().add_child(stub)
	stub.weapon_slots = p_weapons
	for w in p_weapons:
		if w is WeaponBase:
			(w as WeaponBase).player = stub
	return stub


# ── V25 恒等护栏 ──────────────────────────────────────────────────
func _test_v25_identity_guard() -> void:
	print("── V25 恒等护栏 ──")
	# 三情形：KIN 直击带 ICE gauge / FIR 直击无 gauge / ICE 直击同向 gauge
	# → 无 amplify 池、factor 1.0、伤害与无 gauge 基线逐位恒等
	var hit_els: Array[int] = [GameConst.Element.KIN, GameConst.Element.FIR, GameConst.Element.ICE]
	var gauge_els: Array[int] = [GameConst.Element.ICE, -1, GameConst.Element.ICE]
	var ok := true
	var detail := ""
	for i in range(3):
		var baseline := _spawn_enemy(_make_enemy_data("V25_B%d" % i),
			Vector2(100.0 + 60.0 * float(i), 100.0))
		var target := _spawn_enemy(_make_enemy_data("V25_T%d" % i),
			Vector2(400.0 + 60.0 * float(i), 100.0))
		_sys.register_host(baseline)
		_sys.register_host(target)
		if gauge_els[i] >= 0:
			_gauge(target, gauge_els[i], 30.0)
		_fire_at(_spawn_proj(hit_els[i], baseline.global_position))
		var r_base := _last_result()
		_fire_at(_spawn_proj(hit_els[i], target.global_position))
		var r_hit := _last_result()
		if r_base == null or r_hit == null:
			ok = false
			detail = "结算缺失 i=%d" % i
			break
		if r_hit.pool_breakdown.has(&"amplify") \
				or not is_equal_approx(r_base.final_value, r_hit.final_value) \
				or not is_equal_approx(r_hit.mult_product, 1.0):
			ok = false
			detail = "i=%d base=%s hit=%s mult=%s brk=%s" % [i, str(r_base.final_value),
				str(r_hit.final_value), str(r_hit.mult_product), str(r_hit.pool_breakdown)]
			break
	_check("V25：KIN 带 gauge / FIR 无 gauge / ICE 同向 gauge 三情形——无 amplify 池、factor 1.0、伤害与基线恒等",
		ok, detail)


# ── V26 融化 ──────────────────────────────────────────────────────
func _test_v26_melt() -> void:
	print("── V26 融化 ──")
	var e := _spawn_enemy(_make_enemy_data("V26"), Vector2(360, 300))
	_sys.register_host(e)
	_gauge(e, GameConst.Element.ICE, 30.0)
	var rxn0: int = DebugStats.get_counter(&"reaction_triggered")
	_fire_at(_spawn_proj(GameConst.Element.FIR, e.global_position))
	var r := _last_result()
	var st: ElementalState = e.get("elemental")
	var consumed := r != null and st != null \
		and is_equal_approx(float(r.pool_breakdown.get(&"amplify", -1.0)), 0.5) \
		and is_equal_approx(r.final_value, 150.0) \
		and is_equal_approx(st.gauges[GameConst.Element.ICE], 0.0) \
		and st.gauges[GameConst.Element.FIR] > 0.0
	_bump()
	_sys.detect_reactions()
	var no_double: bool = DebugStats.get_counter(&"reaction_triggered") == rxn0
	_check("V26：融化（FIR 直击 + ICE gauge）→ amplify contrib 0.5；结算后 ICE 全清 + FIR 附着>0；帧末 reaction_triggered 不增（防双吃）",
		consumed and no_double,
		"consumed=%s no_double=%s brk=%s" % [str(consumed), str(no_double),
			str(r.pool_breakdown if r != null else {})])


# ── V27 蒸发 ──────────────────────────────────────────────────────
func _test_v27_vaporize() -> void:
	print("── V27 蒸发 ──")
	var e := _spawn_enemy(_make_enemy_data("V27"), Vector2(360, 400))
	_sys.register_host(e)
	_gauge(e, GameConst.Element.FIR, 30.0)
	_fire_at(_spawn_proj(GameConst.Element.ICE, e.global_position))
	var r := _last_result()
	var st: ElementalState = e.get("elemental")
	_check("V27：蒸发（ICE 直击 + FIR gauge）→ amplify contrib 1.0（×2.0）落血 200；FIR 全清",
		r != null and st != null
			and is_equal_approx(float(r.pool_breakdown.get(&"amplify", -1.0)), 1.0)
			and is_equal_approx(r.final_value, 200.0)
			and is_equal_approx(st.gauges[GameConst.Element.FIR], 0.0),
		"brk=%s fin=%s" % [str(r.pool_breakdown if r != null else {}),
			str(r.final_value if r != null else -1.0)])


# ── V28 排除面 ────────────────────────────────────────────────────
func _test_v28_exclusions() -> void:
	print("── V28 排除面 ──")
	# ① DOT：点燃跳伤（HIT_IS_DOT 通道，不经 _build_damage_ctx）
	var e1 := _spawn_enemy(_make_enemy_data("V28_DOT"), Vector2(360, 500))
	_sys.register_host(e1)
	_sys.apply_attach(e1, GameConst.Element.FIR, 100.0, {"snapshot": 100.0})   # 满槽 → 点燃
	_bump()
	_captured.clear()
	_sys.tick(0.5)
	var dot_ok := false
	for r in _captured:
		if r.element == GameConst.Element.FIR and r.popup_style == GameConst.PopupStyle.DOT:
			dot_ok = not r.pool_breakdown.has(&"amplify")
	# ② 连锁跳：感电 BFS 跳伤（LTG 通道）
	var e2 := _spawn_enemy(_make_enemy_data("V28_SRC"), Vector2(360, 700))
	var e2b := _spawn_enemy(_make_enemy_data("V28_DST"), Vector2(440, 700))
	_sys.register_host(e2)
	_sys.register_host(e2b)
	_captured.clear()
	_sys.apply_attach(e2, GameConst.Element.LTG, 100.0, {"hit_damage": 100.0}) # 满槽 → 连锁
	var chain_ok := false
	for r in _captured:
		if r.element == GameConst.Element.LTG and r.target_uid == int(e2b.get("uid")):
			chain_ok = not r.pool_breakdown.has(&"amplify")
	# ③ KIN 直击（元素白名单门控排除；目标带反向 gauge 也不触发）
	var e3 := _spawn_enemy(_make_enemy_data("V28_KIN"), Vector2(600, 700))
	_sys.register_host(e3)
	_gauge(e3, GameConst.Element.ICE, 30.0)
	_fire_at(_spawn_proj(GameConst.Element.KIN, e3.global_position))
	var r3 := _last_result()
	var kin_ok: bool = r3 != null and not r3.pool_breakdown.has(&"amplify")
	# ④ 光束：ctx 自建不走 _build_damage_ctx 注入门——源码结构排除（无 amplify 注入位）
	var beam_src := _read_source("res://scripts/combat/weapon/laser_beam.gd")
	var beam_ok := (not beam_src.is_empty()) and not beam_src.contains("amplify")
	_check("V28：DOT / 连锁跳 / KIN 直击 / 光束（源码结构）四路 breakdown 均无 amplify",
		dot_ok and chain_ok and kin_ok and beam_ok,
		"dot=%s chain=%s kin=%s beam=%s" % [str(dot_ok), str(chain_ok), str(kin_ok), str(beam_ok)])


# ── V29 穿透独立 ──────────────────────────────────────────────────
func _test_v29_pierce_independent() -> void:
	print("── V29 穿透独立 ──")
	var ea := _spawn_enemy(_make_enemy_data("V29_A"), Vector2(344, 900))
	var eb := _spawn_enemy(_make_enemy_data("V29_B"), Vector2(376, 900))
	_sys.register_host(ea)
	_sys.register_host(eb)
	_gauge(ea, GameConst.Element.ICE, 30.0)       # A 有反向 gauge；B 无
	var proj := _spawn_proj(GameConst.Element.FIR, Vector2(360, 900), 30.0, 2)
	_fire_at(proj)
	var ra: DamageResult = null
	var rb: DamageResult = null
	for r in _captured:
		if r.target_uid == int(ea.get("uid")):
			ra = r
		elif r.target_uid == int(eb.get("uid")):
			rb = r
	var st_a: ElementalState = ea.get("elemental")
	var ok: bool = ra != null and rb != null and st_a != null \
		and is_equal_approx(float(ra.pool_breakdown.get(&"amplify", -1.0)), 0.5) \
		and is_equal_approx(ra.final_value, 150.0) \
		and is_equal_approx(st_a.gauges[GameConst.Element.ICE], 0.0) \
		and not rb.pool_breakdown.has(&"amplify") \
		and is_equal_approx(rb.final_value, 100.0)
	_check("V29：穿透链双敌一有一无——各自独立判定（A 融化 150 + ICE 清零；B 恒等 100 无 amplify）",
		ok, "ra=%s rb=%s" % [str(ra.final_value if ra != null else -1.0),
			str(rb.final_value if rb != null else -1.0)])


# ── V30 管线 veto ─────────────────────────────────────────────────
func _test_v30_pipeline_veto() -> void:
	print("── V30 管线 veto ──")
	var src := _read_source("res://scripts/core/damage/damage_pipeline.gd")
	_check("V30：damage_pipeline.gd 零代码改动守卫——源码不含 amplify 字样（v1.1.0 唯一授权 diff 为注释行）",
		(not src.is_empty()) and not src.contains("amplify"))


# ── V31 top-8 截断 ────────────────────────────────────────────────
func _test_v31_top8() -> void:
	print("── V31 top-8 截断 ──")
	# a) 8 假池（contrib 6.0 > 5.3，M=7.0）+ amplify（M=1.5）→ 假池占满 8 名额，amplify 出账
	var e1 := _spawn_enemy(_make_enemy_data("V31_A"), Vector2(360, 1000))
	_sys.register_host(e1)
	_gauge(e1, GameConst.Element.ICE, 30.0)
	var ids8: Array = [&"m1", &"m2", &"m3", &"m4", &"m5", &"m6", &"m7", &"m8"]
	_fire_at(_spawn_proj(GameConst.Element.FIR, e1.global_position, 30.0, 1,
		_make_fake_pool_stack(ids8, 6.0)))
	var r1 := _last_result()
	var a_ok: bool = r1 != null and not r1.pool_breakdown.has(&"amplify") \
		and r1.audit != null and r1.audit.truncated_mults.has(&"amplify")
	# b) 7 假池 + amplify → 8 名额全容，amplify 在账（agg 0.5）
	var e2 := _spawn_enemy(_make_enemy_data("V31_B"), Vector2(520, 1000))
	_sys.register_host(e2)
	_gauge(e2, GameConst.Element.ICE, 30.0)
	var ids7: Array = [&"m1", &"m2", &"m3", &"m4", &"m5", &"m6", &"m7"]
	_fire_at(_spawn_proj(GameConst.Element.FIR, e2.global_position, 30.0, 1,
		_make_fake_pool_stack(ids7, 6.0)))
	var r2 := _last_result()
	var b_ok: bool = r2 != null \
		and is_equal_approx(float(r2.pool_breakdown.get(&"amplify", -1.0)), 0.5)
	# c) 同值决胜稳定：8 假池 contrib 0.5（M 与 amplify 同值）→ pool_id 字典序定序
	#    （aaa* < amplify）→ amplify 稳定截断（确定性，非随机）
	var e3 := _spawn_enemy(_make_enemy_data("V31_C"), Vector2(680, 1000))
	_sys.register_host(e3)
	_gauge(e3, GameConst.Element.ICE, 30.0)
	var ids_tie: Array = [&"aaa1", &"aaa2", &"aaa3", &"aaa4", &"aaa5", &"aaa6", &"aaa7", &"aaa8"]
	_fire_at(_spawn_proj(GameConst.Element.FIR, e3.global_position, 30.0, 1,
		_make_fake_pool_stack(ids_tie, 0.5)))
	var r3 := _last_result()
	var c_ok: bool = r3 != null and not r3.pool_breakdown.has(&"amplify") \
		and r3.audit != null and r3.audit.truncated_mults.has(&"amplify")
	_check("V31：top-8 截断——8 假池(>5.3)挤出 amplify / 7 假池 amplify 在账 / 同值按 pool_id 字典序稳定截断",
		a_ok and b_ok and c_ok, "a=%s b=%s c=%s" % [str(a_ok), str(b_ok), str(c_ok)])


# ── V32 联合钳（末位执行：注册 VOID 反应强化为污染源） ────────────
func _test_v32_joint_clamp() -> void:
	print("── V32 联合钳 ──")
	_sys.register_reaction_mult(999901, 1.8)      # VOID 同源聚合：融化 factor = 1.5×1.8 = 2.7
	var e := _spawn_enemy(_make_enemy_data("V32"), Vector2(360, 1100))
	_sys.register_host(e)
	_gauge(e, GameConst.Element.ICE, 30.0)
	var ids: Array = [&"big1"]
	_fire_at(_spawn_proj(GameConst.Element.FIR, e.global_position, 30.0, 1,
		_make_fake_pool_stack(ids, 5.3)))
	var r := _last_result()
	# amplify M=2.7 × 假池 M=6.3 = 17.01 > cap_prod=8 → 整体钳 8.0 + audit.compressed
	_check("V32：amplify×大假池联合钳——mult_product 钳 8.0 + audit.compressed + amplify 在账 1.7",
		r != null and is_equal_approx(r.mult_product, 8.0) \
			and r.audit != null and r.audit.compressed \
			and is_equal_approx(float(r.pool_breakdown.get(&"amplify", -1.0)), 1.7),
		"mult=%s brk=%s" % [str(r.mult_product if r != null else -1.0),
			str(r.pool_breakdown if r != null else {})])


# ── V35 CD 分立 ───────────────────────────────────────────────────
func _test_v35_cd_split() -> void:
	print("── V35 CD 分立 ──")
	# a) 三 rule reaction_cd 快照 = 2 / 3 / 6（schema 默认与 .tres 双源同值）
	var e1 := _spawn_enemy(_make_enemy_data("V35_A"), Vector2(120, 200))
	_sys.register_host(e1)
	_gauge(e1, GameConst.Element.FIR, 30.0)
	_gauge(e1, GameConst.Element.ICE, 30.0)
	_bump()
	_sys.detect_reactions()
	var st1: ElementalState = e1.get("elemental")
	var cd_melt := float(st1.reaction_cd.get(GameConst.ReactionType.RXN_FIR_ICE, -1.0))
	var e2 := _spawn_enemy(_make_enemy_data("V35_B"), Vector2(300, 200))
	_sys.register_host(e2)
	_gauge(e2, GameConst.Element.FIR, 30.0)
	_gauge(e2, GameConst.Element.LTG, 30.0)
	_bump()
	_sys.detect_reactions()
	var st2: ElementalState = e2.get("elemental")
	var cd_over := float(st2.reaction_cd.get(GameConst.ReactionType.RXN_FIR_LTG, -1.0))
	var e3 := _spawn_enemy(_make_enemy_data("V35_C"), Vector2(480, 200))
	_sys.register_host(e3)
	_gauge(e3, GameConst.Element.ICE, 30.0)
	_gauge(e3, GameConst.Element.LTG, 30.0)
	_bump()
	_sys.detect_reactions()
	var st3: ElementalState = e3.get("elemental")
	var cd_super := float(st3.reaction_cd.get(GameConst.ReactionType.RXN_ICE_LTG, -1.0))
	var a_ok := is_equal_approx(cd_melt, 2.0) and is_equal_approx(cd_over, 3.0) \
		and is_equal_approx(cd_super, 6.0)
	# b) 去 cd 键 → 回退 cd_rxn（GameConfig.balance.cd_rxn = 2.0）
	var table: Dictionary = GameConfig.balance.reaction_table
	var rule: Dictionary = table.get("RXN_FIR_ICE", {})
	var saved_cd: Variant = rule.get("cd", null)
	rule.erase("cd")
	var e4 := _spawn_enemy(_make_enemy_data("V35_D"), Vector2(660, 200))
	_sys.register_host(e4)
	_gauge(e4, GameConst.Element.FIR, 30.0)
	_gauge(e4, GameConst.Element.ICE, 30.0)
	_bump()
	_sys.detect_reactions()
	var st4: ElementalState = e4.get("elemental")
	var cd_fallback := float(st4.reaction_cd.get(GameConst.ReactionType.RXN_FIR_ICE, -1.0))
	if saved_cd != null:
		rule["cd"] = saved_cd                     # 无条件还原（双源镜像不被测试污染）
	# c) validator：rule cd ≤ 0 → 非致命告警（v1.1.0 CD 分立校验）
	var bt := BalanceTables.new()
	var bad_rule: Dictionary = bt.reaction_table["RXN_FIR_ICE"]
	bad_rule["cd"] = 0.0
	var issues: Array = DataValidator.new().validate_balance(bt)
	var cd_warn := false
	for issue in issues:
		var row: Dictionary = issue
		if String(row.get("message", "")).contains("cd 键若存在必须 > 0"):
			cd_warn = true
	_check("V35：CD 分立——三 rule 快照 2/3/6；去 cd 键回退 cd_rxn=2.0；validator cd≤0 告警",
		a_ok and is_equal_approx(cd_fallback, 2.0) and cd_warn,
		"a=%s fb=%s warn=%s" % [str(a_ok), str(cd_fallback), str(cd_warn)])


# ── V39 拼写回归 ──────────────────────────────────────────────────
func _test_v39_spelling() -> void:
	print("── V39 拼写回归 ──")
	var e := _spawn_enemy(_make_enemy_data("V39"), Vector2(360, 1200))
	_sys.register_host(e)
	_gauge(e, GameConst.Element.ICE, 30.0)
	_gauge(e, GameConst.Element.LTG, 30.0)
	var super0: int = DebugStats.get_counter(&"reaction_superconduct")
	_bump()
	_sys.detect_reactions()
	var triggered: bool = DebugStats.get_counter(&"reaction_superconduct") == super0 + 1
	var src := _read_source("res://scripts/combat/elemental/elemental_system.gd")
	var fixed_src := (not src.is_empty()) and src.contains("reaction_superconduct") \
		and not src.contains("supercoduct")
	_check("V39：拼写回归——reaction_superconduct 遥测 +1 且源码无 supercoduct 残留",
		triggered and fixed_src, "triggered=%s fixed_src=%s" % [str(triggered), str(fixed_src)])


# ── V40 gauge 残留 ────────────────────────────────────────────────
func _test_v40_gauge_residue() -> void:
	print("── V40 gauge 残留 ──")
	var e := _spawn_enemy(_make_enemy_data("V40"), Vector2(360, 1240))
	_sys.register_host(e)
	_gauge(e, GameConst.Element.ICE, 0.001)       # 残量附着
	_fire_at(_spawn_proj(GameConst.Element.FIR, e.global_position))   # 融化（>0 仍触发）
	var r1 := _last_result()
	var st: ElementalState = e.get("elemental")
	var melt_ok: bool = r1 != null and st != null and r1.pool_breakdown.has(&"amplify") \
		and is_equal_approx(st.gauges[GameConst.Element.ICE], 0.0) \
		and st.gauges[GameConst.Element.FIR] > 0.0
	_fire_at(_spawn_proj(GameConst.Element.ICE, e.global_position))   # 同帧连段：融后蒸
	var r2 := _last_result()
	var vapor_ok: bool = r2 != null \
		and is_equal_approx(float(r2.pool_breakdown.get(&"amplify", -1.0)), 1.0) \
		and is_equal_approx(st.gauges[GameConst.Element.FIR], 0.0) \
		and st.gauges[GameConst.Element.ICE] > 0.0
	_check("V40：gauge 残量 0.001 仍触发融化全清；融后蒸同帧连段合法（FIR 清 / ICE 附着>0）",
		melt_ok and vapor_ok, "melt=%s vapor=%s" % [str(melt_ok), str(vapor_ok)])


# ── V33 精通注册（局部 ElementalSystem 隔离） ─────────────────────
func _test_v33_mastery_register() -> void:
	print("── V33 精通注册 ──")
	var sys := ElementalSystem.new()
	sys.name = "Pkg11MasterySys"
	tree.get_root().add_child(sys)
	var w1 := _make_weapon(GameConst.WeaponForm.BALLISTIC,
		_make_weapon_data(GameConst.WeaponForm.BALLISTIC), Vector2(100, 100), sys)
	var host_stub := _mount_stub_player([w1])   # v1.3.0 适配：注册通道 = rebuild 扫 weapon_slots
	var mdata := _make_mastery_data()
	var ok := true
	var detail := ""
	if not (w1.attach_trait(mdata) and w1.attach_trait(mdata)):
		ok = false
		detail = "×2 attach 失败"
	if ok and not is_equal_approx(sys.reaction_mult(), 1.5):
		ok = false
		detail = "×2 层 mult=%s" % str(sys.reaction_mult())
	if ok and not (w1.attach_trait(mdata) and is_equal_approx(sys.reaction_mult(), 1.75)):
		ok = false
		detail = "×3 层 mult=%s" % str(sys.reaction_mult())
	# 第 4 层：stack_max=3 → attach 拒绝，精通不增
	if ok and (w1.attach_trait(mdata) or not is_equal_approx(sys.reaction_mult(), 1.75)):
		ok = false
		detail = "第 4 层未被拒绝 mult=%s" % str(sys.reaction_mult())
	# 跨武器 2+2 → 合计 4 → 全局封顶 3 → 仍 1.75
	var w2 := _make_weapon(GameConst.WeaponForm.BALLISTIC,
		_make_weapon_data(GameConst.WeaponForm.BALLISTIC), Vector2(200, 100), sys)
	host_stub.weapon_slots.append(w2)           # v1.3.0 适配：w2 入 stub 槽位
	w2.player = host_stub
	if ok and not (w2.attach_trait(mdata) and w2.attach_trait(mdata)):
		ok = false
		detail = "跨武器 attach 失败"
	if ok and not is_equal_approx(sys.reaction_mult(), 1.75):
		ok = false
		detail = "跨武器封顶 mult=%s" % str(sys.reaction_mult())
	# 同挂 ELE_IGNITE：弹元素仍 FIR（精通 hooks 空 → 不派发不覆写弹元素）
	if ok:
		var ignite: TraitData = load("res://resources/traits/ELE_IGNITE.tres") as TraitData
		if ignite == null or not w1.attach_trait(ignite):
			ok = false
			detail = "ELE_IGNITE attach 失败"
		elif not w1.try_fire():
			ok = false
			detail = "try_fire 失败"
		else:
			var el := _first_live_proj_element(_proj_pool)
			if el != GameConst.Element.FIR:
				ok = false
				detail = "弹元素=%d（期望 FIR=1）" % el
	w1.free()
	w2.free()
	host_stub.free()
	sys.free()
	_check("V33：精通注册——×2 层 1.5 / ×3 层 1.75 / 跨武器 2+2 仍 1.75 封顶 / 第 4 层拒绝 / 与 ELE_IGNITE 同挂弹元素仍 FIR",
		ok, detail)


# ── V34 φ 聚合（局部 ElementalSystem 隔离） ───────────────────────
func _test_v34_phi_aggregate() -> void:
	print("── V34 φ 聚合 ──")
	var sys := ElementalSystem.new()
	sys.name = "Pkg11PhiSys"
	tree.get_root().add_child(sys)
	sys.pipeline = _pipeline
	sys.enemy_grid = _grid
	sys.register_reaction_mult(888801, 1.8)       # VOID ×1.8
	sys.register_mastery(888802, 3, 0.25)         # 精通 L3 → ×1.75
	var phi_ok := is_equal_approx(sys.reaction_mult(), 3.15)
	# 增幅 factor = 2.0 × 3.15 = 6.3：FIR gauge + ICE 直击 → contrib 5.3 落血 630
	var e1 := _spawn_enemy(_make_enemy_data("V34_A"), Vector2(120, 1100))
	sys.register_host(e1)
	_gauge(e1, GameConst.Element.FIR, 30.0, sys)
	_fire_at(_spawn_proj(GameConst.Element.ICE, e1.global_position, 30.0, 1, null, sys))
	var r1 := _last_result()
	var amp_ok: bool = r1 != null \
		and is_equal_approx(float(r1.pool_breakdown.get(&"amplify", -1.0)), 5.3) \
		and is_equal_approx(r1.final_value, 630.0)
	# 碎裂 coef = 2.0 × 3.15 = 6.3 × 剩余 DOT 180（0.15×200×1 层×6 跳）= 1134 落血（hp 866）
	var e2 := _spawn_enemy(_make_enemy_data("V34_B", 2000.0), Vector2(400, 1100))
	sys.register_host(e2)
	sys.apply_attach(e2, GameConst.Element.FIR, 100.0, {"snapshot": 200.0})   # 满槽点燃
	_gauge(e2, GameConst.Element.FIR, 30.0, sys)
	_gauge(e2, GameConst.Element.ICE, 30.0, sys)
	_bump()
	sys.detect_reactions()
	var melt_ok := _approx(e2.hp, 866.0, 0.01)
	sys.free()
	_check("V34：φ 聚合——VOID+L3 → 3.15；增幅 2.0×3.15=6.3（contrib 5.3 落血 630）；碎裂 2.0×3.15×180=1134（hp 866）",
		phi_ok and amp_ok and melt_ok,
		"phi=%s amp=%s melt=%s" % [str(phi_ok), str(amp_ok), str(melt_ok)])


# ── V38 HUD 精通层显示 ────────────────────────────────────────────
func _test_v38_hud_mastery() -> void:
	print("── V38 HUD MP ──")
	var hud := HUD.new()
	hud.name = "Pkg11Hud"
	tree.get_root().add_child(hud)
	# 伪玩家/伪武器（带 HUD 探针所需属性；GDScript 运行时构造——Node2D 无自定义属性可 set）
	var wsrc := GDScript.new()
	wsrc.source_code = "extends RefCounted\nvar trait_stack: TraitStack = null\n"
	wsrc.reload()
	var psrc := GDScript.new()
	psrc.source_code = "extends Node2D\nvar weapon_slots: Array = []\n"
	psrc.reload()
	var player_stub: Node2D = psrc.new()
	tree.get_root().add_child(player_stub)
	var mdata := _make_mastery_data()
	var other := TraitData.new()
	other.id = &"ADD_ATK_V38"
	other.display_name = "V38 占位"
	other.pool = GameConst.PoolClass.ADD
	other.pool_id = &"add_atk"
	other.effect_id = &"EF_STAT"
	other.value = 0.1
	var s1 := TraitStack.new()
	s1.attach(mdata)
	s1.attach(mdata)                              # 层数 2
	var s2 := TraitStack.new()
	s2.attach(mdata)
	s2.attach(mdata)                              # 层数 2（跨武器合计 4）
	s2.attach(other)
	var w1: RefCounted = wsrc.new()
	w1.trait_stack = s1
	var w2: RefCounted = wsrc.new()
	w2.trait_stack = s2
	player_stub.weapon_slots = [w1, w2]
	hud.player = player_stub
	var text := hud._build_summary()
	var capped := text == "Build  W:2 T:3 MP:3"   # 2+2 层 → 全局封顶 3
	var s0 := TraitStack.new()
	s0.attach(other)
	w1.trait_stack = s0
	w2.trait_stack = TraitStack.new()             # 无精通 → MP:0 恒显
	var text0 := hud._build_summary()
	var zero_ok := text0 == "Build  W:2 T:1 MP:0"
	var rects := hud.layout_rects()
	var layout_ok := rects.size() == 11           # 布局契约不变
	hud.free()
	player_stub.free()
	_check("V38：HUD Build 串——跨武器 2+2 封顶 MP:3 / 无精通 MP:0 恒显 / layout_rects 仍 11 项",
		capped and zero_ok and layout_ok,
		"t1=%s t0=%s rects=%d" % [text, text0, rects.size()])


# ── V36 遥测分键 ──────────────────────────────────────────────────
func _test_v36_telemetry_keys() -> void:
	print("── V36 遥测分键 ──")
	var m0: int = DebugStats.get_counter(&"amplify_melt")
	var v0: int = DebugStats.get_counter(&"amplify_vapor")
	var e1 := _spawn_enemy(_make_enemy_data("V36_A"), Vector2(120, 1160))
	_sys.register_host(e1)
	_gauge(e1, GameConst.Element.ICE, 30.0)
	_fire_at(_spawn_proj(GameConst.Element.FIR, e1.global_position))   # 融化消耗
	var e2 := _spawn_enemy(_make_enemy_data("V36_B"), Vector2(400, 1160))
	_sys.register_host(e2)
	_gauge(e2, GameConst.Element.FIR, 30.0)
	_fire_at(_spawn_proj(GameConst.Element.ICE, e2.global_position))   # 蒸发消耗
	var m1: int = DebugStats.get_counter(&"amplify_melt")
	var v1: int = DebugStats.get_counter(&"amplify_vapor")
	_check("V36：遥测分键——amplify_melt / amplify_vapor 各自恰 +1（consume_amplify 内计）",
		m1 == m0 + 1 and v1 == v0 + 1,
		"melt %d→%d vapor %d→%d" % [m0, m1, v0, v1])


# ── V37 popup 后缀 ────────────────────────────────────────────────
func _test_v37_popup_suffix() -> void:
	print("── V37 popup 后缀 ──")
	# a) DamagePopup 直测：第 6 参后缀 + merge 重渲染保留 + 文本模式不变
	var p1 := DamagePopup.new()
	tree.get_root().add_child(p1)
	p1.show_popup(Vector2(100, 100), 150.0, GameConst.PopupStyle.NORMAL, 7, "", "‼")
	var with_suffix: String = p1._label.text
	p1.merge(50.0)
	var merged_text: String = p1._label.text
	p1.show_popup(Vector2(100, 100), 0.0, GameConst.PopupStyle.NORMAL, 0, "+20 金币", "‼")
	var text_mode: String = p1._label.text
	p1.free()
	# b) PopupManager 集成：仅 breakdown 含 amplify 的新跳字加后缀
	var pool := PopupPool.new()
	pool.name = "Pkg11PopupPool"
	tree.get_root().add_child(pool)
	pool.setup(&"pkg11_popup", load("res://scenes/ui/damage_popup.tscn"), 16)
	var mgr := PopupManager.new()
	mgr.name = "Pkg11PopupMgr"
	tree.get_root().add_child(mgr)
	mgr.setup(pool)                               # 订阅 damage_resolved（free 随节点断开）
	var r1 := DamageResult.new()
	r1.pos = Vector2(200, 200)
	r1.final_value = 150.0
	r1.popup_style = GameConst.PopupStyle.NORMAL
	r1.target_uid = 41
	r1.pool_breakdown = {&"amplify": 0.5}
	mgr.on_damage_resolved(r1)
	var t_amp := _popup_text(mgr, 41)
	var r2 := DamageResult.new()
	r2.pos = Vector2(300, 200)
	r2.final_value = 100.0
	r2.popup_style = GameConst.PopupStyle.NORMAL
	r2.target_uid = 42
	r2.pool_breakdown = {}
	mgr.on_damage_resolved(r2)
	var t_plain := _popup_text(mgr, 42)
	mgr.clear_all()
	mgr.free()
	pool.free()
	var ok := with_suffix == "150‼" and merged_text == "200‼" \
		and text_mode == "+20 金币" \
		and t_amp.ends_with("‼") and not t_plain.ends_with("‼")
	_check("V37：popup 后缀——数值模式 ‼ 结尾且 merge 保留 / 文本模式不变 / 仅 breakdown 含 amplify 加后缀",
		ok, "%s|%s|%s|%s|%s" % [with_suffix, merged_text, text_mode, t_amp, t_plain])


func _popup_text(p_mgr: PopupManager, p_uid: int) -> String:
	var entry: Dictionary = p_mgr._merge_registry.get(p_uid, {})
	if entry.is_empty():
		return ""
	var popup: DamagePopup = entry["popup"]
	return popup._label.text

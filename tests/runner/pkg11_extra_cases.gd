# tests/runner/pkg11_extra_cases.gd
# v1.1.0 验收补漏用例体（由 test_pkg11_extra.gd 入口在 autoload 就绪后运行时加载编译）。
# tester 独立验收视角：pkg11 V25~V40 已覆盖项不重复；本文件只补 pkg11 未覆盖的验收口径——
#   XE1 ★重开残留（A10 §7 E-AMP-1 跨局盲区：restart_run 释放旧武器但 ElementalSystem
#       为 boot 期单例，_mastery_reg 无清理通道——按验收期望行为断言，失败即业务 bug 证据）
#   XE2 免疫目标增幅照常（_amplify_snapshot 不查 immune_mask 的契约面）
#   XE3 精通 1 层 φ=1.25（V33 仅断 2/3 层，1 层缺直接锚）
#   XE4 融化×精通 L3 端到端手算（factor = 1.5×1.75 = 2.625 → contrib 1.625 → final 262.5）
#   XE5 碎裂 2s 触发节奏（期内不触发 / 过期可再触发——V35 仅断快照值）
#   XE6 过载 3s 触发节奏（同上）
#   XE7 CD 三方同值（balance_tables.gd schema 默认 vs balance_tables.tres vs
#       GameConfig.balance runtime——文件级对照，V35 仅断 runtime 快照）
# 执行序纪律：XE5/XE6 用局部 ElementalSystem（污染源隔离，与 V33/V34 同手法）；
# 纯净面先行，XE7 纯配置对照不依赖 sys。
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
var _captured: Array[DamageResult] = []


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_ensure_autoloads()
	_setup_world()
	_test_xe5_shatter_cd_rhythm()                 # XE5（局部 sys，纯净面先行）
	_test_xe6_overload_cd_rhythm()                # XE6（局部 sys）
	_test_xe3_mastery_one_layer()                 # XE3（局部 sys）
	_test_xe4_melt_mastery_e2e()                  # XE4（局部 sys）
	_test_xe1_restart_residue()                   # XE1 ★（局部 sys）
	_test_xe2_immune_amplify()                    # XE2（共享 _sys：免疫面不注册任何乘区）
	_test_xe7_cd_three_way()                      # XE7（纯配置对照）
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
	_proj_pool.name = "Pkg11xProjPool"
	tree.get_root().add_child(_proj_pool)
	_proj_pool.setup(&"pkg11x_test", load(BALLISTIC_SCENE), 64)
	var ep := EnemyPool.new()
	ep.name = "Pkg11xEnemyPool"
	tree.get_root().add_child(ep)
	ep.setup(&"pkg11x_enemy", load(ENEMY_SCENE), 32)
	_enemy_pool = ep
	_grid = SpaceGrid.new()
	_grid.configure(Vector2(720, 1280), 192.0)
	_alive_enemies.clear()
	_captured.clear()
	_pipeline = DamagePipeline.new()
	_pipeline.set_rng_seed(42)
	_sys = ElementalSystem.new()
	_sys.name = "Pkg11xElementalSystem"
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


func _make_local_sys(p_name: String) -> ElementalSystem:
	var sys := ElementalSystem.new()
	sys.name = p_name
	tree.get_root().add_child(sys)
	sys.pipeline = _pipeline
	sys.enemy_grid = _grid
	return sys


func _make_weapon_data() -> WeaponData:
	var d := WeaponData.new()
	d.id = &"W_PKG11X"
	d.display_name = "Pkg11x 测试武器"
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


func _make_weapon(p_pos: Vector2, p_elemental: ElementalSystem) -> WeaponBase:
	var w: WeaponBase = BallisticWeapon.new()
	w.name = "Pkg11xWeapon_%d" % (p_pos.x as int)
	tree.get_root().add_child(w)
	w.position = p_pos
	w.setup(_make_weapon_data(), null, {
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


func _panel() -> Dictionary:
	# 零暴击零加算面板（伤害手算锚：final = base_atk × ∏M，resist 0）
	return {
		"base_atk": 100.0, "crit_rate": 0.0, "crit_mult": 2.0,
		"flat_bonus": 0.0, "add_entries": [], "chip_atk_pct": 0.0,
	}


func _spawn_proj(p_element: int, p_pos: Vector2, p_attach: float = 30.0,
		p_elemental: ElementalSystem = null) -> ProjectileBase:
	var proj := _proj_pool.acquire() as ProjectileBase
	proj.damage_pipeline = _pipeline
	proj.enemy_grid = _grid
	proj.pool = _proj_pool
	proj.elemental = p_elemental if p_elemental != null else _sys
	proj.spawn({
		"velocity": Vector2.ZERO,
		"lifetime": 1.0,
		"pierce": 1,
		"bounces": 0,
		"hitbox_radius": 6.0,
		"element": p_element,
		"attach_value": p_attach,
		"generation": 0,
		"weapon_uid": 0,
		"panel_snapshot": _panel(),
		"team": 0,
		"position": p_pos,
		"trait_stack": null,
	})
	return proj


func _fire_at(p_proj: ProjectileBase) -> void:
	# 单帧推进：清捕获 + 帧号推进 + 幂等缓存清空（GameLoop 帧序的测试侧替身）+ 一 tick
	_captured.clear()
	GameConfig.frame_stamp += 1
	_pipeline.begin_frame()
	p_proj.tick(DT)


func _on_damage_resolved(p_result: DamageResult) -> void:
	_captured.append(p_result)


func _last_result() -> DamageResult:
	if _captured.is_empty():
		return null
	return _captured[_captured.size() - 1]


func _gauge(p_enemy: Node2D, p_element: int, p_value: float,
		p_sys: ElementalSystem = null) -> void:
	var sys := p_sys if p_sys != null else _sys
	sys.apply_attach(p_enemy, p_element, p_value)    # 非满槽预置附着（无状态触发）


# ── XE5 碎裂 2s 触发节奏（局部 sys） ──────────────────────────────
func _test_xe5_shatter_cd_rhythm() -> void:
	print("── XE5 碎裂 2s 节奏 ──")
	var sys := _make_local_sys("Pkg11xShatterSys")
	var e := _spawn_enemy(_make_enemy_data("XE5", 2400.0), Vector2(120, 60))
	sys.register_host(e)
	var st: ElementalState = e.get("elemental")
	# ① 首触发：满槽点燃 + 双槽条件 → 碎裂触发，cd 落 2.0
	sys.apply_attach(e, GameConst.Element.FIR, 100.0, {"snapshot": 200.0})
	sys.apply_attach(e, GameConst.Element.FIR, 30.0)
	sys.apply_attach(e, GameConst.Element.ICE, 30.0)
	_bump()
	var t0: int = DebugStats.get_counter(&"reaction_triggered")
	sys.detect_reactions()
	var first_ok: bool = DebugStats.get_counter(&"reaction_triggered") == t0 + 1 \
		and _approx(float(st.reaction_cd.get(GameConst.ReactionType.RXN_FIR_ICE, -1.0)), 2.0)
	# ② 2s 期内重附双槽 → 不触发（cd 闸门先于条件判定）
	sys.apply_attach(e, GameConst.Element.FIR, 30.0)
	sys.apply_attach(e, GameConst.Element.ICE, 30.0)
	_bump()
	sys.detect_reactions()
	var in_cd_ok: bool = DebugStats.get_counter(&"reaction_triggered") == t0 + 1
	# ③ tick(2.0) 过期 → 重附可再触发（cd 回 2.0）
	sys.tick(2.0)
	sys.apply_attach(e, GameConst.Element.FIR, 100.0, {"snapshot": 200.0})
	sys.apply_attach(e, GameConst.Element.FIR, 30.0)
	sys.apply_attach(e, GameConst.Element.ICE, 30.0)
	_bump()
	sys.detect_reactions()
	var after_ok: bool = DebugStats.get_counter(&"reaction_triggered") == t0 + 2 \
		and _approx(float(st.reaction_cd.get(GameConst.ReactionType.RXN_FIR_ICE, -1.0)), 2.0)
	sys.free()
	_check("XE5：碎裂 rule.cd=2.0 触发节奏——首触发落 cd 2.0；期内重附不触发；tick(2.0) 过期后可再触发",
		first_ok and in_cd_ok and after_ok,
		"first=%s in_cd=%s after=%s" % [str(first_ok), str(in_cd_ok), str(after_ok)])


# ── XE6 过载 3s 触发节奏（局部 sys） ──────────────────────────────
func _test_xe6_overload_cd_rhythm() -> void:
	print("── XE6 过载 3s 节奏 ──")
	var sys := _make_local_sys("Pkg11xOverloadSys")
	var e := _spawn_enemy(_make_enemy_data("XE6", 2000.0), Vector2(500, 60))
	sys.register_host(e)
	var st: ElementalState = e.get("elemental")
	# ① 首触发：FIR+LTG 双槽 → 过载触发，cd 落 3.0
	sys.apply_attach(e, GameConst.Element.FIR, 30.0, {"snapshot": 100.0})
	sys.apply_attach(e, GameConst.Element.LTG, 30.0)
	_bump()
	var t0: int = DebugStats.get_counter(&"reaction_triggered")
	sys.detect_reactions()
	var first_ok: bool = DebugStats.get_counter(&"reaction_triggered") == t0 + 1 \
		and _approx(float(st.reaction_cd.get(GameConst.ReactionType.RXN_FIR_LTG, -1.0)), 3.0)
	# ② 3s 期内重附双槽 → 不触发
	sys.apply_attach(e, GameConst.Element.FIR, 30.0)
	sys.apply_attach(e, GameConst.Element.LTG, 30.0)
	_bump()
	sys.detect_reactions()
	var in_cd_ok: bool = DebugStats.get_counter(&"reaction_triggered") == t0 + 1
	# ③ tick(3.0) 过期 → 重附可再触发（cd 回 3.0）
	sys.tick(3.0)
	sys.apply_attach(e, GameConst.Element.FIR, 30.0)
	sys.apply_attach(e, GameConst.Element.LTG, 30.0)
	_bump()
	sys.detect_reactions()
	var after_ok: bool = DebugStats.get_counter(&"reaction_triggered") == t0 + 2 \
		and _approx(float(st.reaction_cd.get(GameConst.ReactionType.RXN_FIR_LTG, -1.0)), 3.0)
	sys.free()
	_check("XE6：过载 rule.cd=3.0 触发节奏——首触发落 cd 3.0；期内重附不触发；tick(3.0) 过期后可再触发",
		first_ok and in_cd_ok and after_ok,
		"first=%s in_cd=%s after=%s" % [str(first_ok), str(in_cd_ok), str(after_ok)])


# ── XE3 精通 1 层 φ=1.25（局部 sys） ──────────────────────────────
func _test_xe3_mastery_one_layer() -> void:
	print("── XE3 精通 1 层 ──")
	var sys := _make_local_sys("Pkg11xM1Sys")
	var w1 := _make_weapon(Vector2(100, 100), sys)
	var mdata := _make_mastery_data()
	var attach_ok: bool = w1.attach_trait(mdata)
	var mult := sys.reaction_mult()
	var layers: int = sys.mastery_layers()
	w1.free()
	sys.free()
	_check("XE3：精通 1 层——reaction_mult φ = 1 + 0.25×1 = 1.25（mastery_layers=1；V33 仅断 2/3 层的缺口补锚）",
		attach_ok and layers == 1 and _approx(mult, 1.25),
		"attach=%s layers=%d mult=%s" % [str(attach_ok), layers, str(mult)])


# ── XE4 融化 × 精通 L3 端到端手算（局部 sys） ─────────────────────
func _test_xe4_melt_mastery_e2e() -> void:
	print("── XE4 融化×精通端到端 ──")
	var sys := _make_local_sys("Pkg11xE2eSys")
	sys.register_mastery(777001, 3, 0.25)         # L3 → φ=1.75（纯精通，无 VOID）
	var e := _spawn_enemy(_make_enemy_data("XE4"), Vector2(360, 160))
	sys.register_host(e)
	_gauge(e, GameConst.Element.ICE, 30.0, sys)
	_fire_at(_spawn_proj(GameConst.Element.FIR, e.global_position, 30.0, sys))
	var r := _last_result()
	# factor = 1.5 × 1.75 = 2.625 → contrib 1.625 → final = 100 × 2.625 = 262.5
	var e2e_ok: bool = r != null \
		and is_equal_approx(float(r.pool_breakdown.get(&"amplify", -1.0)), 1.625) \
		and is_equal_approx(r.final_value, 262.5)
	sys.free()
	_check("XE4：融化×精通 L3 端到端手算——factor 同构乘算 1.5×1.75=2.625（amplify contrib 1.625，final 262.5）",
		e2e_ok, "brk=%s fin=%s" % [str(r.pool_breakdown if r != null else {}),
			str(r.final_value if r != null else -1.0)])


# ── XE1 ★重开残留（局部 sys；按验收期望行为断言） ─────────────────
func _test_xe1_restart_residue() -> void:
	print("── XE1 ★重开残留 ──")
	var sys := _make_local_sys("Pkg11xRestartSys")
	# 局内：武器 1 挂精通 ×2 → φ=1.5（前置锚）
	var w1 := _make_weapon(Vector2(100, 200), sys)
	var mdata := _make_mastery_data()
	var pre_ok: bool = w1.attach_trait(mdata) and w1.attach_trait(mdata) \
		and is_equal_approx(sys.reaction_mult(), 1.5)
	# 重开链复现：旧武器销毁（game_loop._reset_run_state 的 queue_free 等效）→
	# ★修复责任位：_reset_run_state 现调用 elemental.reset_run()（v1.1.0 审查 Critical
	# 修复）——清零责任在重开链而非武器析构，此处模拟该调用 → 新武器新 uid 且不挂精通
	var uid1: int = w1.uid
	w1.free()
	sys.reset_run()
	var w2 := _make_weapon(Vector2(200, 200), sys)
	var uid_ok: bool = w2.uid != uid1              # 新局武器 uid 必然不同
	# 验收期望：重开一局后 mastery_layers 归零、reaction_mult 回 1.0（无虚高）
	var layers_after: int = sys.mastery_layers()
	var mult_after := sys.reaction_mult()
	var clean: bool = layers_after == 0 and is_equal_approx(mult_after, 1.0)
	# HUD 对照：新武器无精通 → Build 串 MP:0（显示面干净——与 reaction_mult 是否一致）
	var wsrc := GDScript.new()
	wsrc.source_code = "extends RefCounted\nvar trait_stack: TraitStack = null\n"
	wsrc.reload()
	var psrc := GDScript.new()
	psrc.source_code = "extends Node2D\nvar weapon_slots: Array = []\n"
	psrc.reload()
	var stub_w: RefCounted = wsrc.new()
	stub_w.trait_stack = TraitStack.new()          # 空栈（新武器未挂精通）
	var stub_player: Node2D = psrc.new()
	tree.get_root().add_child(stub_player)
	stub_player.weapon_slots = [stub_w]
	var hud := HUD.new()
	hud.name = "Pkg11xHud"
	tree.get_root().add_child(hud)
	hud.player = stub_player
	var hud_text := hud._build_summary()
	var hud_ok: bool = hud_text.contains("MP:0")
	hud.free()
	stub_player.free()
	w2.free()
	sys.free()
	_check("XE1：★重开链——武器销毁重建（新 uid）后 mastery_layers 归零、reaction_mult 回 1.0；HUD MP:0 与实际一致",
		pre_ok and uid_ok and clean and hud_ok,
		"pre=%s uid_ok=%s layers_after=%d mult_after=%s hud=%s"
			% [str(pre_ok), str(uid_ok), layers_after, str(mult_after), hud_text])


# ── XE2 免疫目标增幅照常（共享 _sys；不注册任何乘区） ──────────────
func _test_xe2_immune_amplify() -> void:
	print("── XE2 免疫增幅 ──")
	var e := _spawn_enemy(_make_enemy_data("XE2"), Vector2(640, 160))
	_sys.register_host(e)
	var st: ElementalState = e.get("elemental")
	st.immune_mask = GameConst.IMMUNE_FREEZE | GameConst.IMMUNE_CHILL \
		| GameConst.IMMUNE_BURN | GameConst.IMMUNE_SHOCK   # 全屏蔽位（F-17 面）
	_gauge(e, GameConst.Element.ICE, 30.0)
	var gauge_landed: bool = st.gauges[GameConst.Element.ICE] > 0.0
	_fire_at(_spawn_proj(GameConst.Element.FIR, e.global_position))
	var r := _last_result()
	var amp_ok: bool = r != null \
		and is_equal_approx(float(r.pool_breakdown.get(&"amplify", -1.0)), 0.5) \
		and is_equal_approx(r.final_value, 150.0)
	_check("XE2：免疫目标（immune_mask 全屏蔽）增幅照常——ICE 附着计量不受免疫影响，FIR 直击融化 contrib 0.5 落血 150",
		gauge_landed and amp_ok,
		"gauge=%s brk=%s fin=%s" % [str(gauge_landed),
			str(r.pool_breakdown if r != null else {}),
			str(r.final_value if r != null else -1.0)])


# ── XE7 CD 三方同值（schema 默认 vs .tres vs runtime） ────────────
func _test_xe7_cd_three_way() -> void:
	print("── XE7 CD 三方同值 ──")
	var schema_bt := BalanceTables.new()           # balance_tables.gd @export 默认（schema 面）
	var tres_bt := load("res://data/balance/balance_tables.tres") as BalanceTables
	var runtime_bt: BalanceTables = GameConfig.balance
	var keys: Array = ["RXN_FIR_ICE", "RXN_FIR_LTG", "RXN_ICE_LTG"]
	var cds: Array = [2.0, 3.0, 6.0]
	var ok := true
	var detail := ""
	for i in range(keys.size()):
		var k: String = keys[i]
		var r_schema: Dictionary = schema_bt.reaction_table.get(k, {})
		var r_tres: Dictionary = tres_bt.reaction_table.get(k, {})
		var r_runtime: Dictionary = runtime_bt.reaction_table.get(k, {})
		var cd_ok: bool = _approx(float(r_schema.get("cd", -1.0)), float(cds[i])) \
			and _approx(float(r_tres.get("cd", -1.0)), float(cds[i])) \
			and _approx(float(r_runtime.get("cd", -1.0)), float(cds[i]))
		var rule_same: bool = _rule_equal(r_schema, r_tres) and _rule_equal(r_tres, r_runtime)
		if not (cd_ok and rule_same):
			ok = false
			detail = "%s cd schema=%s tres=%s runtime=%s same=%s" % [k,
				str(r_schema.get("cd")), str(r_tres.get("cd")),
				str(r_runtime.get("cd")), str(rule_same)]
			break
	var cd_rxn_ok: bool = _approx(schema_bt.cd_rxn, 2.0) \
		and _approx(tres_bt.cd_rxn, 2.0) and _approx(runtime_bt.cd_rxn, 2.0)
	_check("XE7：CD 三方同值（文件级对照）——schema 默认 / balance_tables.tres / GameConfig.runtime 三方 rule 全等（碎裂 2.0 / 过载 3.0 / 超导 6.0）且 cd_rxn=2.0 兜底一致",
		ok and cd_rxn_ok, detail)


func _rule_equal(p_a: Dictionary, p_b: Dictionary) -> bool:
	if p_a.size() != p_b.size():
		return false
	for key in p_a:
		if not p_b.has(key):
			return false
		var va: Variant = p_a[key]
		var vb: Variant = p_b[key]
		if va is float and vb is float:
			if not is_equal_approx(va, vb):
				return false
		elif va != vb:
			return false
	return true

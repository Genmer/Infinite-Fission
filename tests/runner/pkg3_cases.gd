# tests/runner/pkg3_cases.gd
# 包 3 自测用例体（由 test_pkg3.gd 入口在 autoload 就绪后运行时加载编译）。
# 覆盖（PROGRESS §4 要点 1~10）：
#   要点1  四形态武器开火参数重写（ballistic 散射锥/加算重写/射速双护栏、homing 八键+集束子弹头、
#          laser 主束参数+深度硬闸、melee-orbit 力场参数+谐振轨道通道）
#   要点2  TraitStack 挂载叠层/上限/copy_runtime/copy_for_split（含 ECHO 乘区扩展）
#   要点3  六大生命周期事件派发顺序 = 挂载顺序（TraitStack 真件通道）
#   要点4  链式深度上限 3 熔断 + 同事件重入拦截
#   要点5  体积极限质变阈值（≥3.0× 触发 TH_SIZE_NOVA 冲击波）
#   要点6  分裂三重闸门（代数≤3 / 单次≤8 / 全场软上限）+ ON_EXPIRE 分裂继承
#   要点7  反弹增伤乘区（AFTER_BOUNCE → ×1.4）
#   要点8  点燃/冰冻/感电附着-衰减-反应（碎裂×2.0 / 过载 120%ATK / 超导全抗−30%、反应 CD 2s）
#   要点9  激光灼焦叠层（1 层/0.25s、+8%/层、cap）与折射分叉深度 2
#   要点10 环绕武器周期判定 / 弧斩消弹格挡（NULLIFIED 统一收束）
# 确定性：全部用例固定坐标/固定参数（唯一 randf_range(-0,0) 退化为 0，E-03 帧闸门经
#         GameConfig.frame_stamp 手动推进）；元素结算注入包 1 真件 DamagePipeline
#         （反应/DOT 在管线步骤 9b 内部落血），武器/投射物路径沿用 pkg2 透传桩。
extends RefCounted

const BALLISTIC_SCENE := "res://scenes/combat/projectiles/ballistic_projectile.tscn"
const HOMING_SCENE := "res://scenes/combat/projectiles/homing_projectile.tscn"
const LASER_SCENE := "res://scenes/combat/lasers/laser_beam.tscn"
const ENEMY_SCENE := "res://scenes/combat/enemies/enemy.tscn"
const DT := 1.0 / 120.0

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _fused_events: Array = []                  # chain_fused 事件记录 [[depth, trait_id], …]

# 共享夹具（按组重建）
var _proj_pool: ProjectilePool
var _homing_pool: ProjectilePool
var _laser_pool: LaserBeamPool
var _enemy_pool: EnemyPool
var _grid: SpaceGrid
var _bullet_grid: SpaceGrid
var _pipeline: DamagePipelineStub
var _real_pipeline: DamagePipeline             # 包 1 真件（元素系统结算通道）
var _sys: ElementalSystem
var _alive_enemies: Array[Node2D] = []
var _rec_effect: TraitEffect                   # EF_PKG3_RECORD 单例（记录序）
var _chain_effect: TraitEffect                 # EF_PKG3_CHAIN 单例（链式熔断）
var _wd_counter: int = 0                       # WeaponData id 确定性计数器


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)                                       # 全局 RNG 固定种子（散射抖动确定性）
	_ensure_autoloads()
	_setup_test_effects()
	EventBus.chain_fused.connect(_on_chain_fused)
	_test_trait_stack_core()                      # 要点 2
	_test_dispatch_order_and_chain()              # 要点 3 / 4
	_setup_world()
	_test_projectile_lifecycle_via_stack()        # 要点 3（投射物真件通道）
	_teardown_world()
	_setup_world()
	_test_ballistic_weapon()                      # 要点 1-A
	_teardown_world()
	_setup_world()
	_test_homing_weapon()                         # 要点 1-B
	_teardown_world()
	_setup_world()
	_test_laser_spawn_and_depth_gate()            # 要点 1-C
	_test_laser_scorch_layers()                   # 要点 9-A
	_test_laser_refraction()                      # 要点 9-B
	_teardown_world()
	_setup_world()
	_test_size_nova_unit()                        # 要点 5（效果单元语义）
	_teardown_world()
	_setup_world()
	_test_size_nova_engine()                      # 要点 5（引擎路径验收）
	_teardown_world()
	_setup_world()
	_test_split_gates()                           # 要点 6
	_teardown_world()
	_setup_world()
	_test_bounce_mult()                           # 要点 7
	_teardown_world()
	_test_elemental_state()                       # 要点 8-A（状态单元）
	_setup_elem_world()
	_test_elemental_system()                      # 要点 8-B（系统编排）
	_teardown_elem_world()
	_setup_world()
	_test_orbit_weapon()                          # 要点 10-A
	_teardown_world()
	_setup_world()
	_test_arc_slash()                             # 要点 10-B
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


func _on_chain_fused(p_depth: int, p_trait_id: StringName) -> void:
	_fused_events.append([p_depth, p_trait_id])


func _has_fused_event(p_depth: int, p_trait_id: StringName) -> bool:
	for ev in _fused_events:
		var row: Array = ev as Array
		if int(row[0]) == p_depth and StringName(str(row[1])) == p_trait_id:
			return true
	return false


func _bump_frame() -> void:
	GameConfig.frame_stamp += 1                    # E-03 帧闸门推进（GameLoop 帧序的测试侧替身）


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


func _setup_test_effects() -> void:
	# 记录序效果（EF_PKG3_RECORD）：shared 序列 = "trait_id:event"（派发序断言真源）
	var rec := GDScript.new()
	rec.source_code = "extends TraitEffect\n" \
		+ "var shared: Array = []\n" \
		+ "func handle(p_trait, p_ctx) -> void:\n" \
		+ "\tshared.append(String(p_trait.data.id) + \":\" + str(p_ctx.event))\n"
	rec.reload()
	_rec_effect = rec.new() as TraitEffect
	TraitEffect.register_custom(&"EF_PKG3_RECORD", _rec_effect)
	# 链式效果（EF_PKG3_CHAIN）：handle 后按 chain_from 构造新 ctx 继续派发（构造跨层链）
	var chain := GDScript.new()
	chain.source_code = "extends TraitEffect\n" \
		+ "var stack = null\n" \
		+ "var chain_from: Dictionary = {}\n" \
		+ "var runs: Array = []\n" \
		+ "func handle(p_trait, p_ctx) -> void:\n" \
		+ "\truns.append(int(p_ctx.event))\n" \
		+ "\tif stack != null and chain_from.has(p_ctx.event):\n" \
		+ "\t\tvar next_ev: int = int(chain_from[p_ctx.event])\n" \
		+ "\t\tvar sub: TraitContext = TraitContext.new()\n" \
		+ "\t\tsub.event = next_ev\n" \
		+ "\t\tstack.dispatch(next_ev, sub)\n"
	chain.reload()
	_chain_effect = chain.new() as TraitEffect
	TraitEffect.register_custom(&"EF_PKG3_CHAIN", _chain_effect)


func _make_trait_data(p_id: String, p_pool: int, p_pool_id: StringName, p_effect: StringName,
		p_value: float, p_hooks: Array = []) -> TraitData:
	var d := TraitData.new()
	d.id = StringName(p_id)
	d.display_name = p_id
	d.pool = p_pool
	d.pool_id = p_pool_id
	d.effect_id = p_effect
	d.value = p_value
	for h in p_hooks:
		d.event_hooks.append(int(h))
	d.stack_max = 1
	d.decay_delta = 0.0
	d.proc_chance = 1.0
	d.inheritable = false
	return d


func _merge_dict(p_base: Dictionary, p_over: Dictionary) -> Dictionary:
	var out := p_base.duplicate(true)
	for key in p_over:
		out[key] = p_over[key]
	return out


func _make_weapon_data(p_form: int, p_table: Dictionary = {}, p_segment: Dictionary = {},
		p_thresholds: Array = []) -> WeaponData:
	_wd_counter += 1
	var d := WeaponData.new()
	d.id = StringName("W_PKG3_%d" % _wd_counter)
	d.display_name = "Pkg3 测试武器 %d" % _wd_counter
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
	for th in p_thresholds:
		d.threshold_traits.append(th)
	return d


func _make_weapon(p_form: int, p_data: WeaponData, p_pos: Vector2,
		p_elemental: ElementalSystem = null) -> WeaponBase:
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
	w.name = "Pkg3Weapon_%d" % _wd_counter
	tree.get_root().add_child(w)
	w.position = p_pos
	w.setup(p_data, null, {
		"pipeline": _pipeline,
		"projectile_pool": _proj_pool,
		"enemy_grid": _grid,
		"laser_pool": _laser_pool,
		"homing_pool": _homing_pool,
		"elemental": p_elemental,
	})
	return w


func _make_enemy_data(p_id: String, p_hp: float = 1000.0, p_hitbox_r: float = 14.0) -> EnemyData:
	var d := EnemyData.new()
	d.id = StringName(p_id)
	d.display_name = p_id
	d.hp_base = p_hp
	d.spd_base = 0.0                               # 静止敌（几何确定性）
	d.dmg_base = 8.0
	d.exp_base = 3.0
	d.tp_cost = 1.0
	d.hitbox_r = p_hitbox_r
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
	proj.spawn(p_params.duplicate())
	return proj


func _live_proj_pool_nodes() -> Array:
	return _proj_pool._live_order.keys()


func _nullify_all_proj_pool() -> void:
	for node in _live_proj_pool_nodes():
		(node as ProjectileBase).nullify()


func _nullify_all_homing_pool() -> void:
	for node in _homing_pool._live_order.keys():
		(node as ProjectileBase).nullify()


func _setup_world() -> void:
	_proj_pool = ProjectilePool.new()
	_proj_pool.name = "Pkg3ProjPool"
	tree.get_root().add_child(_proj_pool)
	_proj_pool.setup(&"pkg3_test", load(BALLISTIC_SCENE), 64)
	_homing_pool = ProjectilePool.new()
	_homing_pool.name = "Pkg3HomingPool"
	tree.get_root().add_child(_homing_pool)
	_homing_pool.setup(&"pkg3_homing", load(HOMING_SCENE), 16)
	_laser_pool = LaserBeamPool.new()
	_laser_pool.name = "Pkg3LaserPool"
	tree.get_root().add_child(_laser_pool)
	_laser_pool.setup(&"pkg3_laser", load(LASER_SCENE), 16)
	var ep := EnemyPool.new()
	ep.name = "Pkg3EnemyPool"
	tree.get_root().add_child(ep)
	ep.setup(&"pkg3_enemy", load(ENEMY_SCENE), 32)
	_enemy_pool = ep
	_grid = SpaceGrid.new()
	_grid.configure(Vector2(720, 1280), 192.0)
	_bullet_grid = SpaceGrid.new()
	_bullet_grid.configure(Vector2(720, 1280), 192.0)
	_pipeline = DamagePipelineStub.new()
	_alive_enemies.clear()


func _teardown_world() -> void:
	_alive_enemies.clear()
	if _proj_pool != null:
		_proj_pool.free()
		_proj_pool = null
	if _homing_pool != null:
		_homing_pool.free()
		_homing_pool = null
	if _laser_pool != null:
		_laser_pool.free()
		_laser_pool = null
	if _enemy_pool != null:
		_enemy_pool.free()
		_enemy_pool = null
	_grid = null
	_bullet_grid = null
	_pipeline = null


func _setup_elem_world() -> void:
	var ep := EnemyPool.new()
	ep.name = "Pkg3ElemEnemyPool"
	tree.get_root().add_child(ep)
	ep.setup(&"pkg3_elem_enemy", load(ENEMY_SCENE), 16)
	_enemy_pool = ep
	_grid = SpaceGrid.new()
	_grid.configure(Vector2(720, 1280), 192.0)
	_alive_enemies.clear()
	_real_pipeline = DamagePipeline.new()          # 包 1 真件：步骤 9b 内部 take_result 落血
	_real_pipeline.set_rng_seed(42)
	_sys = ElementalSystem.new()
	_sys.name = "Pkg3ElementalSystem"
	tree.get_root().add_child(_sys)
	_sys.pipeline = _real_pipeline
	_sys.enemy_grid = _grid


func _teardown_elem_world() -> void:
	_alive_enemies.clear()
	if _sys != null:
		_sys.free()
		_sys = null
	_real_pipeline = null
	if _enemy_pool != null:
		_enemy_pool.free()
		_enemy_pool = null
	_grid = null


# ── 1. TraitStack：挂载/叠层/复制/分裂继承（要点 2） ───────────────
func _test_trait_stack_core() -> void:
	print("── TraitStack 核心 ──")
	# 同 ID 叠层（stack_max 内）
	var d1 := _make_trait_data("TRAIT_STACKED", GameConst.PoolClass.ADD, &"add_atk",
		&"EF_STAT", 0.15, [])
	d1.stack_max = 3
	d1.decay_delta = 0.85
	var s1 := TraitStack.new()
	_check("挂载：同 ID 第 1 次成功", s1.attach(d1))
	_check("挂载：同 ID 第 2 次叠层成功（layers=2）",
		s1.attach(d1) and (s1.size() == 1 and s1.traits[0].layers == 2))
	var rej_stack: int = DebugStats.get_counter(&"trait_attach_rejected_stack")
	_check("挂载：stack_max=3 内第 3 次仍成功（layers=3），第 4 次拒绝 + 计数",
		s1.attach(d1) and (s1.traits[0].layers == 3
			and ((not s1.attach(d1))
				and DebugStats.get_counter(&"trait_attach_rejected_stack") == rej_stack + 1)))
	# 单栈上限 12
	var s2 := TraitStack.new()
	var all_ok := true
	for i in range(12):
		all_ok = (all_ok and s2.attach(_make_trait_data("TRAIT_MAX_%d" % i,
			GameConst.PoolClass.ADD, &"add_atk", &"EF_STAT", 0.01, [])))
	var rej_max: int = DebugStats.get_counter(&"trait_attach_rejected_max")
	_check("挂载：12 词条可挂满，第 13 条拒绝（MAX_TRAITS）",
		all_ok and (s2.size() == 12
			and (not s2.attach(_make_trait_data("TRAIT_OVER", GameConst.PoolClass.ADD,
				&"add_atk", &"EF_STAT", 0.01, [])))
			and DebugStats.get_counter(&"trait_attach_rejected_max") == rej_max + 1))
	# F3 衰减聚合（静态真源）
	_check("F3 衰减：decay_sum(10, 3, 0.85) = 25.725",
		_approx(TraitStack.decay_sum(10.0, 3, 0.85), 25.725, 0.001))
	# 面板聚合：add_atk ×2 层 δ0.85 → 18.5；add_entries 单项 layer 2
	var s3 := TraitStack.new()
	var d_atk := _make_trait_data("TRAIT_ATK", GameConst.PoolClass.ADD, &"add_atk",
		&"EF_STAT", 10.0, [])
	d_atk.stack_max = 3
	d_atk.decay_delta = 0.85
	s3.attach(d_atk)
	s3.attach(d_atk)
	var panel: Dictionary = s3.aggregate_panel()
	var entries: Array[Dictionary] = s3.aggregate_add_entries()
	_check("面板聚合：add_atk 2 层 F3 = 18.5 + add_entries 单项 layer 2",
		_approx(float(panel.get("add_atk", 0.0)), 18.5, 0.001)
			and (entries.size() == 1 and int(entries[0]["layer"]) == 2))
	# 整数线性池：add_pierce ×2 层 = 2.0（不走 F3）
	var d_pierce := _make_trait_data("TRAIT_PIERCE", GameConst.PoolClass.ADD, &"add_pierce",
		&"EF_STAT", 1.0, [])
	d_pierce.stack_max = 3
	var s4 := TraitStack.new()
	s4.attach(d_pierce)
	s4.attach(d_pierce)
	var panel4: Dictionary = s4.aggregate_panel()
	_check("整数线性池：add_pierce 2 层 = 2.0（线性全额）",
		_approx(float(panel4.get("add_pierce", 0.0)), 2.0, 0.0001))
	# 冷却推进
	s4.traits[0].cooldown_left = 0.5
	s4.advance_cooldowns(0.2)
	_check("冷却推进：advance_cooldowns 0.2 → 0.3",
		_approx(s4.traits[0].cooldown_left, 0.3, 0.0001))
	# copy_runtime：全定义复制（E-13 引用共享）+ 层数保留 + 运行时重置
	var rt: TraitStack = s3.copy_runtime()
	_check("copy_runtime：实例独立 + 词条数一致 + 定义引用共享（E-13）",
		rt != s3 and (rt.size() == s3.size() and rt.traits[0].data == s3.traits[0].data))
	s3.traits[0].cooldown_left = 1.5
	s3.traits[0].frame_triggered = true
	var rt2: TraitStack = s3.copy_runtime()
	_check("copy_runtime：运行时状态重置（cooldown=0 / frame 标记清零）+ 层数保留",
		_approx(rt2.traits[0].cooldown_left, 0.0) and (not rt2.traits[0].frame_triggered
			and rt2.traits[0].layers == 2))
	# copy_for_split：默认只继承 inheritable（E-01 分裂词条自身不继承）
	var sp := TraitStack.new()
	var d_inh_add := _make_trait_data("TRAIT_INH_ADD", GameConst.PoolClass.ADD, &"add_spd",
		&"EF_STAT", 0.18, [])
	d_inh_add.inheritable = true
	var d_noin_add := _make_trait_data("TRAIT_NOIN_ADD", GameConst.PoolClass.ADD, &"add_atk",
		&"EF_STAT", 0.10, [])
	var d_noin_mult := _make_trait_data("TRAIT_NOIN_MULT", GameConst.PoolClass.MULT,
		&"syn_x", &"EF_BOUNCE", 1.4, [])
	d_noin_mult.cap_pool_p = 1.8
	d_noin_mult.condition = {"condition_id": GameConst.ConditionId.NONE, "params": {}}
	var d_inh_mult := _make_trait_data("TRAIT_INH_MULT", GameConst.PoolClass.MULT,
		&"syn_y", &"EF_BOUNCE", 1.2, [])
	d_inh_mult.inheritable = true
	d_inh_mult.cap_pool_p = 1.5
	d_inh_mult.condition = {"condition_id": GameConst.ConditionId.NONE, "params": {}}
	sp.attach(d_inh_add)
	sp.attach(d_noin_add)
	sp.attach(d_noin_mult)
	sp.attach(d_inh_mult)
	var child1: TraitStack = sp.copy_for_split(1, false)
	_check("copy_for_split：默认仅继承 inheritable 词条（含可继承乘区）",
		child1.size() == 2 and (child1.traits[0].data.id == &"TRAIT_INH_ADD"
			and child1.traits[1].data.id == &"TRAIT_INH_MULT"))
	var child2: TraitStack = sp.copy_for_split(1, true)
	_check("copy_for_split：ECHO 扩展至乘区词条（TH_FRACTAL_ECHO，定义复制子代自评）",
		child2.size() == 3 and child2.traits[1].data.id == &"TRAIT_NOIN_MULT")


# ── 2. 六事件派发序 = 挂载序 + 链式深度熔断（要点 3 / 4） ─────────
func _test_dispatch_order_and_chain() -> void:
	print("── 派发序 / 链式熔断 ──")
	(_rec_effect as Object).set("shared", [])
	var stack := TraitStack.new()
	for id in ["A", "B", "C"]:
		stack.attach(_make_trait_data(id, GameConst.PoolClass.ADD, &"add_atk",
			&"EF_PKG3_RECORD", 0.0, [0, 1, 2, 3, 4, 5]))
	var expected: Array = []
	for ev in range(6):
		_bump_frame()
		var tctx := TraitContext.new()
		tctx.event = ev
		stack.dispatch(ev, tctx)
		for id in ["A", "B", "C"]:
			expected.append("%s:%d" % [id, ev])
	var shared: Array = (_rec_effect as Object).get("shared")
	_check("六事件派发顺序 = 挂载序（真件栈全序列 A→B→C × 6 事件）", shared == expected,
		"got %s" % str(shared))
	# 链式深度 3 熔断：SPAWN→TICK→HIT 三层合法，第 4 层（PIERCE）熔断
	(_chain_effect as Object).set("runs", [])
	(_chain_effect as Object).set("chain_from", {
		GameConst.TraitEvent.ON_SPAWN: GameConst.TraitEvent.ON_TICK,
		GameConst.TraitEvent.ON_TICK: GameConst.TraitEvent.ON_HIT,
		GameConst.TraitEvent.ON_HIT: GameConst.TraitEvent.ON_PIERCE,
	})
	var cstack := TraitStack.new()
	var hooks: Array = [[GameConst.TraitEvent.ON_SPAWN], [GameConst.TraitEvent.ON_TICK],
		[GameConst.TraitEvent.ON_HIT], [GameConst.TraitEvent.ON_PIERCE]]
	for i in range(4):
		cstack.attach(_make_trait_data("CHAIN_%d" % i, GameConst.PoolClass.MECH, &"",
			&"EF_PKG3_CHAIN", 0.0, hooks[i]))
	(_chain_effect as Object).set("stack", cstack)
	var fused0: int = DebugStats.get_counter(&"trait_chain_fused")
	var tctx0 := TraitContext.new()
	tctx0.event = GameConst.TraitEvent.ON_SPAWN
	_bump_frame()
	cstack.dispatch(GameConst.TraitEvent.ON_SPAWN, tctx0)
	var runs: Array = (_chain_effect as Object).get("runs")
	_check("链式：深度 3 内逐层链式执行（SPAWN→TICK→HIT）", runs == [0, 1, 2],
		"got %s" % str(runs))
	_check("链式深度熔断：第 4 层（深度 4 > 3）未执行 + 熔断计数 +1",
		cstack.fused_count() == 1
			and DebugStats.get_counter(&"trait_chain_fused") == fused0 + 1)
	_check("chain_fused 事件派发：depth=4", _has_fused_event(4, &""))
	# 熔断后深度恢复：清链后可正常派发
	(_chain_effect as Object).set("chain_from", {})
	_bump_frame()
	tctx0.event = GameConst.TraitEvent.ON_TICK
	var ok_after: bool = cstack.dispatch(GameConst.TraitEvent.ON_TICK, tctx0)
	_check("熔断后链深恢复：再次派发正常执行且不叠加熔断",
		ok_after and ((_chain_effect as Object).get("runs") == [0, 1, 2, 1]
			and cstack.fused_count() == 1))
	# 同事件重入拦截（E-03 重入保护：无递归、无熔断）
	(_chain_effect as Object).set("chain_from",
		{GameConst.TraitEvent.ON_TICK: GameConst.TraitEvent.ON_TICK})
	(_chain_effect as Object).set("runs", [])
	_bump_frame()
	var rej0: int = DebugStats.get_counter(&"trait_reentry_blocked")
	cstack.dispatch(GameConst.TraitEvent.ON_TICK, tctx0)
	_check("同事件重入拦截：递归派发被拦（runs 不增长）+ 无熔断",
		((_chain_effect as Object).get("runs") == [1] and cstack.fused_count() == 1)
			and DebugStats.get_counter(&"trait_reentry_blocked") == rej0 + 1)
	(_chain_effect as Object).set("stack", null)


# ── 3. 投射物六事件经 TraitStack 真件通道（要点 3） ───────────────
func _test_projectile_lifecycle_via_stack() -> void:
	print("── 投射物真件事件通道 ──")
	(_rec_effect as Object).set("shared", [])
	var ed := _make_enemy_data("E_ORDER3")
	var enemy := _spawn_enemy(ed, Vector2(365, 640))
	var stack := TraitStack.new()
	for id in ["A", "B", "C"]:
		stack.attach(_make_trait_data(id, GameConst.PoolClass.ADD, &"add_atk",
			&"EF_PKG3_RECORD", 0.0, [0, 1, 2, 3, 4, 5]))
	var proj := _spawn_proj({
		"position": Vector2(360, 640),
		"velocity": Vector2(100, 0),
		"lifetime": 10.0,
		"pierce": 1,
		"hitbox_radius": 6.0,
		"panel_snapshot": {"base_atk": 10.0},
		"trait_stack": stack,
		"team": 0,
	})
	# spawn 期 ON_SPAWN（当前帧）→ 推帧后 tick：ON_TICK 触发；ON_HIT/ON_EXPIRE 同帧被 E-03 闸门拦下
	var expected: Array = ["A:0", "B:0", "C:0", "A:1", "B:1", "C:1"]
	_bump_frame()
	proj.tick(DT)
	var shared: Array = (_rec_effect as Object).get("shared")
	_check("投射物路径：ON_SPAWN→ON_TICK 经真件栈按挂载序派发", shared == expected,
		"got %s" % str(shared))
	_check("E-03 词条帧闸门：同帧内 ON_HIT/ON_EXPIRE 不重复触发（无 :2/:5 条目）",
		(not _array_contains_suffix(shared, ":2")) and (not _array_contains_suffix(shared, ":5")))
	_check("词条闸门不拦截结算：敌人命中扣血 10", _approx(enemy.hp, 990.0),
		"hp %s" % str(enemy.hp))
	_check("穿透耗尽回收：pierce 1→0（PIERCE_DEPLETED）",
		proj.pierce_left == 0 and not proj.visible)


func _array_contains_suffix(p_arr: Array, p_suffix: String) -> bool:
	for item in p_arr:
		if String(item).ends_with(p_suffix):
			return true
	return false


# ── 4. 四形态武器开火参数重写（要点 1） ───────────────────────────
func _test_ballistic_weapon() -> void:
	print("── BallisticWeapon 开火参数 ──")
	# 基线：单丸直射（无目标 → UP；spread 0）
	var data1: WeaponData = _make_weapon_data(GameConst.WeaponForm.BALLISTIC,
		{"base_atk": 10.0, "rof": 5.0, "pierce": 2, "pellets": 1},
		{"proj_speed": 600.0, "range": 600.0, "spread_deg": 0.0})
	var w1 := _make_weapon(GameConst.WeaponForm.BALLISTIC, data1, Vector2(360, 640))
	var d_tr := _make_trait_data("TRAIT_ATK_W", GameConst.PoolClass.ADD, &"add_atk",
		&"EF_STAT", 0.15, [])
	w1.attach_trait(d_tr)
	_check("开火：try_fire 成功且发出 1 丸",
		w1.try_fire() and _live_proj_pool_nodes().size() == 1)
	var proj := _live_proj_pool_nodes()[0] as ProjectileBase
	_check("spawn 参数重写：velocity = UP×600（aim 回退 + 速度口径）",
		proj.velocity.is_equal_approx(Vector2(0, -600)), "v=%s" % str(proj.velocity))
	_check("spawn 参数重写：lifetime = range/speed×1.5 = 1.5",
		_approx(proj.lifetime_left, 1.5, 0.001))
	_check("spawn 参数重写：pierce=2（表值）/ bounces=0 / generation=0 / team=0",
		proj.pierce_left == 2 and (proj.bounces_left == 0
			and (proj.generation == 0 and proj.team == 0)))
	_check("spawn 参数重写：hitbox=6 / element=KIN / weapon_uid 绑定",
		_approx(proj.hitbox_radius, 6.0) and (proj.element == GameConst.Element.KIN
			and proj.weapon_uid == w1.uid))
	_check("spawn 参数重写：panel_snapshot（base_atk=10 / crit_rate=0）",
		_approx(float(proj.panel_snapshot.get("base_atk", 0.0)), 10.0)
			and _approx(float(proj.panel_snapshot.get("crit_rate", -1.0)), 0.0))
	var p_stack := proj.trait_stack
	_check("运行时栈注入：TraitStack 真件、实例独立、定义引用共享（E-13）",
		p_stack is TraitStack and (p_stack != w1.trait_stack
			and (p_stack.size() == 1 and p_stack.traits[0].data == d_tr)))
	_nullify_all_proj_pool()
	w1.free()
	# 加算重写：Add_Spd/Add_Pierce/Add_Pellets（要点 1：参数侧聚合）
	var data2: WeaponData = _make_weapon_data(GameConst.WeaponForm.BALLISTIC,
		{"base_atk": 10.0, "rof": 5.0, "pierce": 2, "pellets": 1},
		{"proj_speed": 600.0, "range": 600.0, "spread_deg": 0.0})
	var w2 := _make_weapon(GameConst.WeaponForm.BALLISTIC, data2, Vector2(360, 640))
	var d_spd := _make_trait_data("TRAIT_SPD_W", GameConst.PoolClass.ADD, &"add_spd",
		&"EF_STAT", 0.18, [])
	var d_pierce := _make_trait_data("TRAIT_PIERCE_W", GameConst.PoolClass.ADD, &"add_pierce",
		&"EF_STAT", 1.0, [])
	d_pierce.stack_max = 3
	var d_pellets := _make_trait_data("TRAIT_PELLETS_W", GameConst.PoolClass.ADD, &"add_pellets",
		&"EF_STAT", 2.0, [])
	d_pellets.stack_max = 3
	w2.attach_trait(d_spd)
	w2.attach_trait(d_pierce)
	w2.attach_trait(d_pellets)
	_check("加算重写：Add_Pellets +2 → 3 丸（共享散射锥）",
		w2.try_fire() and _live_proj_pool_nodes().size() == 3)
	var speed_ok := true
	var pierce_ok := true
	var life_ok := true
	for node in _live_proj_pool_nodes():
		var p := node as ProjectileBase
		speed_ok = (speed_ok and _approx(p.velocity.length(), 600.0 * 1.18, 0.001))
		pierce_ok = (pierce_ok and p.pierce_left == 3)
		life_ok = (life_ok and _approx(p.lifetime_left, 600.0 / 708.0 * 1.5, 0.001))
	_check("加算重写：Add_Spd +18% → 弹速 708", speed_ok)
	_check("加算重写：Add_Pierce +1 → pierce 3（线性层）", pierce_ok)
	_check("加算重写：射程不变 → lifetime = 600/708×1.5", life_ok)
	_nullify_all_proj_pool()
	w2.free()
	# 散射锥均匀分布（spread 26° × 3 丸 → −26°/0°/+26°）
	var data3: WeaponData = _make_weapon_data(GameConst.WeaponForm.BALLISTIC,
		{"base_atk": 10.0, "rof": 5.0, "pierce": 1, "pellets": 3},
		{"proj_speed": 600.0, "range": 600.0, "spread_deg": 26.0})
	var w3 := _make_weapon(GameConst.WeaponForm.BALLISTIC, data3, Vector2(360, 640))
	w3.try_fire()
	var angles: Array = []
	for node in _live_proj_pool_nodes():
		angles.append(snappedf((node as ProjectileBase).velocity.angle_to(Vector2.UP), 0.0001))
	angles.sort()
	_check("散射锥：3 丸均匀分布 −26°/0°/+26°（spread_deg 半锥角）",
		angles.size() == 3 and (_approx(float(angles[0]), -deg_to_rad(26.0), 0.001)
			and (_approx(float(angles[1]), 0.0, 0.001)
				and _approx(float(angles[2]), deg_to_rad(26.0), 0.001))),
		"angles=%s" % str(angles))
	_nullify_all_proj_pool()
	w3.free()
	# 射速节拍（rof 5 → 0.2s/发；118 tick = 0.983s → 恰 5 发：t=0/0.2/0.4/0.6/0.8）
	var data4: WeaponData = _make_weapon_data(GameConst.WeaponForm.BALLISTIC,
		{"base_atk": 10.0, "rof": 5.0, "pierce": 1, "pellets": 1},
		{"proj_speed": 600.0, "range": 600.0, "spread_deg": 0.0})
	var w4 := _make_weapon(GameConst.WeaponForm.BALLISTIC, data4, Vector2(360, 640))
	for i in range(118):
		w4.tick(DT)
	_check("射速节拍：rof=5 → 118 tick（0.983s）恰 5 发",
		_live_proj_pool_nodes().size() == 5, "fired=%d" % _live_proj_pool_nodes().size())
	w4.free()
	# 射速封顶 30/s（双护栏）
	var data5: WeaponData = _make_weapon_data(GameConst.WeaponForm.BALLISTIC,
		{"base_atk": 10.0, "rof": 90.0, "pierce": 1, "pellets": 1},
		{"proj_speed": 600.0, "range": 600.0, "spread_deg": 0.0})
	var w5 := _make_weapon(GameConst.WeaponForm.BALLISTIC, data5, Vector2(360, 640))
	w5.tick(DT)
	_check("射速封顶：rof=90 → clamp 30 → 冷却 1/30（性能双护栏）",
		_approx(w5.cooldown_left, 1.0 / 30.0, 0.0005), "cd=%s" % str(w5.cooldown_left))
	_nullify_all_proj_pool()
	w5.free()


func _test_homing_weapon() -> void:
	print("── HomingWeapon 开火参数 ──")
	# 无目标：不开火、不消耗节拍
	var data0: WeaponData = _make_weapon_data(GameConst.WeaponForm.HOMING, {"base_atk": 10.0}, {})
	var w0 := _make_weapon(GameConst.WeaponForm.HOMING, data0, Vector2(360, 900))
	w0.tick(DT)
	_check("无目标：try_fire 拒绝且不消耗节拍（冷却保持 0）+ 池空",
		(not w0.try_fire()) and (_approx(w0.cooldown_left, 0.0)
			and _homing_pool._live_order.is_empty()))
	w0.free()
	# 八键全量注入（spawn 参数字典 Homing 段契约）
	var data1: WeaponData = _make_weapon_data(GameConst.WeaponForm.HOMING,
		{"base_atk": 10.0, "cd": 0.5},
		{"proj_speed_init": 240.0, "proj_speed_max": 720.0, "accel": 900.0,
		"turn_rate": 480.0, "arm_delay": 0.15, "blast_r": 45.0, "blast_falloff": 0.6,
		"sub_count": 2, "sub_delay": 0.4})
	var w1 := _make_weapon(GameConst.WeaponForm.HOMING, data1, Vector2(360, 900))
	var enemy := _spawn_enemy(_make_enemy_data("E_HOM_T"), Vector2(600, 300))
	_check("有目标：try_fire 成功发出 1 弹",
		w1.try_fire() and _homing_pool._live_order.size() == 1)
	var missile: HomingProjectile = null
	for node in _homing_pool._live_order.keys():
		missile = node as HomingProjectile
	if missile == null:
		_check("Homing 导弹实例存在", false)
		w1.free()
		return
	var dir := (enemy.global_position - Vector2(360, 900)).normalized()
	_check("八键注入：target_uid 锁定 + 初速 = 朝向×speed_init",
		missile.target_uid == enemy.uid and missile.velocity.is_equal_approx(dir * 240.0))
	_check(
		"八键注入：turn_rate/speed_max/accel/arm_delay/blast/falloff 全量落参",
		_approx(missile.turn_rate, 480.0)
			and _approx(missile.speed_max, 720.0)
			and _approx(missile.accel, 900.0)
			and _approx(missile.arm_delay, 0.15)
			and _approx(missile.blast_radius, 45.0)
			and _approx(missile.blast_falloff, 0.6))
	_check("集束回调：sub_count>0 → impact_hook 挂接（包 3 收口）",
		missile.impact_hook.is_valid() and missile.impact_hook.get_object() == w1)
	# 子弹头调度（A3 §3.7：初速 180 / 加速 600 / 延时 sub_delay）
	w1._on_missile_impact(Vector2(500, 500), 45.0)
	var subs: Array = []
	for node in _homing_pool._live_order.keys():
		var p := node as HomingProjectile
		if p.generation == 1:
			subs.append(p)
	_check("子弹头：sub_count=2 → 2 枚 generation=1 寻的弹", subs.size() == 2)
	var sub_ok := true
	var vx_set: Array = []
	for s in subs:
		var sub := s as HomingProjectile
		sub_ok = (sub_ok and (sub.target_uid == 0 and _approx(sub.speed_init, 180.0)
			and (_approx(sub.accel, 600.0) and (_approx(sub.arm_delay, 0.4)
				and sub.global_position.is_equal_approx(Vector2(500, 500))))))
		vx_set.append(snappedf(sub.velocity.x, 0.0001))
	vx_set.sort()
	_check("子弹头：初速 180 / 加速 600 / 延时 0.4 / 出生点=爆点 / 均匀散射 ±180°",
		sub_ok and (_approx(float(vx_set[0]), -180.0, 0.001)
			and _approx(float(vx_set[1]), 180.0, 0.001)), "vx=%s" % str(vx_set))
	_check("子弹头：单次调度（sub_warheads_left 清零）", w1.sub_warheads_left == 0)
	var live_before: int = _homing_pool._live_order.size()
	w1._on_missile_impact(Vector2(500, 500), 45.0)
	_check("子弹头：回调幂等（池存活数不变）", _homing_pool._live_order.size() == live_before)
	w1.free()
	_nullify_all_homing_pool()
	# W6 无集束变体：hook 不挂接
	var data2: WeaponData = _make_weapon_data(GameConst.WeaponForm.HOMING,
		{"base_atk": 10.0}, {"sub_count": 0})
	var w2 := _make_weapon(GameConst.WeaponForm.HOMING, data2, Vector2(360, 900))
	w2.try_fire()
	var m2: HomingProjectile = null
	for node in _homing_pool._live_order.keys():
		var p2 := node as HomingProjectile
		if p2.impact_hook.is_valid():
			m2 = p2
	_check("W6 微型导弹：sub_count=0 → impact_hook 不挂接", m2 == null)
	w2.free()


func _test_laser_spawn_and_depth_gate() -> void:
	print("── LaserWeapon 主束与深度硬闸 ──")
	var data1: WeaponData = _make_weapon_data(GameConst.WeaponForm.LASER,
		{"base_atk": 10.0, "rof": 8.0},
		{"refract_beams": 1, "refract_ratio": 0.6, "refract_depth": 2})
	var w1 := _make_weapon(GameConst.WeaponForm.LASER, data1, Vector2(100, 640)) as LaserWeapon
	_check("主束：try_fire 维持常驻光束",
		w1.try_fire() and (w1.active_beams.size() == 1
			and int(_laser_pool.stats()["live"]) == 1))
	var beam := w1.active_beams[0]
	_check("主束参数：depth=0 / dmg_mult=1 / tick_atk=10 / tick_rate=8（rof 口径）",
		beam.depth == 0 and (_approx(beam.dmg_mult, 1.0) and (_approx(beam.tick_atk, 10.0)
			and _approx(beam.tick_rate, 8.0))))
	_check("主束参数：灼焦 5 层 cap / 8% 每层 / 折射 1 束 ×0.6 ×深度 2",
		beam.scorch_max_layers == 5 and (_approx(beam.scorch_per_layer, 0.08)
			and (beam.refract_beams == 1 and (_approx(beam.refract_ratio, 0.6)
				and beam.refract_depth == 2))))
	# 深度硬闸：depth 3 拒绝（引擎侧 MAX_REFRACT_DEPTH=2）
	var rej0: int = DebugStats.get_counter(&"laser_refract_rejected")
	var beam3 := w1._spawn_beam(Vector2.ZERO, Vector2.UP, 3, 1.0, 0)
	_check("深度硬闸：depth 3 → 拒绝返回 null + 计数 + chain_fused(3, laser_refract)",
		beam3 == null and (DebugStats.get_counter(&"laser_refract_rejected") == rej0 + 1
			and _has_fused_event(3, &"laser_refract")))
	# 数据声明 refract_depth=3（W5 L5 溢出声明）仍被引擎硬闸拒绝
	data1.laser["refract_depth"] = 3
	var beam3b := w1._spawn_beam(Vector2.ZERO, Vector2.UP, 3, 1.0, 0)
	_check("深度硬闸优先：数据 refract_depth=3 仍被引擎 MAX=2 拒绝",
		beam3b == null and DebugStats.get_counter(&"laser_refract_rejected") == rej0 + 2)
	w1.free()


func _test_laser_scorch_layers() -> void:
	print("── LaserBeam 灼焦叠层 ──")
	var data1: WeaponData = _make_weapon_data(GameConst.WeaponForm.LASER,
		{"base_atk": 10.0, "rof": 8.0}, {"refract_beams": 0})
	var w1 := _make_weapon(GameConst.WeaponForm.LASER, data1, Vector2(160, 640)) as LaserWeapon
	var enemy := _spawn_enemy(_make_enemy_data("E_SCORCH"), Vector2(360, 640))
	w1.try_fire()
	var beam := w1.active_beams[0]
	var uid := enemy.uid
	# tick(0.26)：叠层先行（_on_hit_target）后结算——每 tick 恰 2 跳（0.26 > 2×0.125）
	beam.tick(0.26)
	var layers1: int = int(beam.scorch_layers.get(uid, 0))
	_check("灼焦叠层：持续照射 0.26s → 1 层（1 层/0.25s）", layers1 == 1, "layers=%d" % layers1)
	_check("灼焦跳伤：1 层 Local 池 ×1.08 → 2 跳共 21.6",
		_approx(enemy.hp, 978.4, 0.01), "hp=%s" % str(enemy.hp))
	beam.tick(0.26)
	var layers2: int = int(beam.scorch_layers.get(uid, 0))
	_check("灼焦叠层：0.52s → 2 层", layers2 == 2, "layers=%d" % layers2)
	_check("灼焦跳伤：2 层 ×1.16 → 2 跳共 23.2（累计 44.8）",
		_approx(enemy.hp, 955.2, 0.01), "hp=%s" % str(enemy.hp))
	# 继续照射至 5 层 cap，再验证 cap 层伤害与节拍/节流计数
	for i in range(6):
		beam.tick(0.26)
	var layers_cap: int = int(beam.scorch_layers.get(uid, 0))
	_check("灼焦叠层：cap 于 scorch_max_layers=5", layers_cap == 5, "layers=%d" % layers_cap)
	_check("灼焦跳伤：层序 [1,2,3,4,5,5,5,5] ×2 跳 → 8 tick 累计 208（5 层后 14/跳）",
		_approx(enemy.hp, 792.0, 0.05), "hp=%s" % str(enemy.hp))
	_check("结算节拍：8 跳/s × 8 tick × 2 跳 = settle_count 16", beam.settle_count == 16,
		"settles=%d" % beam.settle_count)
	_check("跳字节流：≤15Hz/目标 → 8 tick 内至多 8 条放行（AC-04.2）",
		beam.popup_count == 8 and beam.popup_count <= beam.settle_count,
		"popups=%d" % beam.popup_count)
	w1.free()


func _test_laser_refraction() -> void:
	print("── LaserBeam 折射分叉（深度 ≤2） ──")
	var data1: WeaponData = _make_weapon_data(GameConst.WeaponForm.LASER,
		{"base_atk": 10.0, "rof": 8.0},
		{"refract_beams": 1, "refract_ratio": 0.6, "refract_depth": 2})
	var w1 := _make_weapon(GameConst.WeaponForm.LASER, data1, Vector2(100, 640)) as LaserWeapon
	var e1 := _spawn_enemy(_make_enemy_data("E_R1"), Vector2(300, 640))    # 主束路径（最近）
	var e2 := _spawn_enemy(_make_enemy_data("E_R2"), Vector2(300, 560))    # 折射目标 1（250px 内）
	var e3 := _spawn_enemy(_make_enemy_data("E_R3"), Vector2(260, 480))    # 折射目标 2
	w1.try_fire()
	var main := w1.active_beams[0]
	# 主束首触 E1 → 生成 depth1 子束（最近未命中目标 E2）
	main.tick(DT)
	_check("折射：主束首触 → 1 条 depth=1 子束",
		w1.active_beams.size() == 2 and w1.active_beams[1].depth == 1)
	var child := w1.active_beams[1]
	_check("折射乘区：子束 dmg_mult = 父×ratio = 0.6", _approx(child.dmg_mult, 0.6, 0.0001))
	# 子束首触 E2 → 生成 depth2 孙束（锁 E3）
	child.tick(DT)
	var has_grand := w1.active_beams.size() >= 3
	_check("折射：子束首触 → 应生成 depth=2 孙束（深度 2 ≤ 上限）",
		has_grand and w1.active_beams[2].depth == 2,
		("beams=%d（业务 bug：子束生成时排除集已含自身锁定目标 → 首触不触发再折射，"
			+ "链式折射深度 2 不可达——见报告）") % w1.active_beams.size())
	if has_grand:
		var grand := w1.active_beams[2]
		_check("折射乘区：孙束 dmg_mult = ratio² = 0.36（二段伤害口径）",
			_approx(grand.dmg_mult, 0.36, 0.0001))
		# 孙束首触 E3 → 请求 depth3 → 引擎硬闸拒绝
		var rej0: int = DebugStats.get_counter(&"laser_refract_rejected")
		grand.tick(DT)
		_check("折射深度熔断：孙束再折射（depth 3 > 2）被拒 + chain_fused + 无第 4 束",
			w1.active_beams.size() == 3
				and (DebugStats.get_counter(&"laser_refract_rejected") == rej0 + 1
					and _has_fused_event(3, &"laser_refract")))
	# 各束独立节拍结算：主 10 / 子 6（×0.6）/ 孙 3.6（×0.36）；16 tick ≥ 跳间隔 0.125s 恰 1 跳
	for i in range(15):
		main.tick(DT)
	for i in range(15):
		child.tick(DT)
	_check("折射伤害：主束全额 10/跳", _approx(e1.hp, 990.0, 0.01), "hp=%s" % str(e1.hp))
	_check("折射伤害：子束 ×0.6 = 6/跳", _approx(e2.hp, 994.0, 0.01), "hp=%s" % str(e2.hp))
	if has_grand:
		var grand2 := w1.active_beams[2]
		for i in range(15):
			grand2.tick(DT)
		_check("折射伤害：孙束 ×0.36 = 3.6/跳", _approx(e3.hp, 996.4, 0.01),
			"hp=%s" % str(e3.hp))
	w1.free()


# ── 5. 体积极限质变（要点 5） ─────────────────────────────────────
func _size_threshold_data() -> WeaponData:
	return _make_weapon_data(GameConst.WeaponForm.BALLISTIC,
		{"base_atk": 10.0, "rof": 5.0},
		{"proj_speed": 600.0, "range": 600.0, "spread_deg": 0.0}, [{
			"threshold_id": "TH_SIZE_NOVA", "metric": "size_mult", "threshold": 3.0,
			"effect_id": "EF_SIZE", "params": {"radius_mult": 1.5, "atk_ratio": 0.4},
		}])


func _test_size_nova_unit() -> void:
	print("── 体积极限质变（效果单元） ──")
	var w1 := _make_weapon(GameConst.WeaponForm.BALLISTIC, _size_threshold_data(),
		Vector2(300, 640))
	var size_data := _make_trait_data("TRAIT_SIZE", GameConst.PoolClass.MECH, &"",
		&"EF_SIZE", 0.18, [GameConst.TraitEvent.ON_SPAWN, GameConst.TraitEvent.ON_HIT])
	var tb := TraitBase.new()
	tb.setup(size_data)
	var ef := TraitEffect.resolve(&"EF_SIZE")
	var proj := _spawn_proj({
		"position": Vector2(300, 640),
		"velocity": Vector2.ZERO,
		"lifetime": 10.0,
		"pierce": 1,
		"hitbox_radius": 6.0,
		"panel_snapshot": {"base_atk": 10.0},
		"team": 0,
	})
	var tctx := TraitContext.new()
	tctx.event = GameConst.TraitEvent.ON_HIT
	tctx.projectile = proj
	tctx.weapon = w1
	var nova0: int = DebugStats.get_counter(&"size_nova_triggered")
	# 阈下：2.7× < 3.0 → 不触发
	proj.size_mult = 2.7
	var near_low := _spawn_enemy(_make_enemy_data("E_NOVA_LO"), Vector2(320, 640))
	ef.handle(tb, tctx)
	_check("体积极限（单元）：size 2.7 < 3.0 → 不触发冲击波",
		_approx(near_low.hp, 1000.0) and DebugStats.get_counter(&"size_nova_triggered") == nova0)
	# 阈上：4.0× ≥ 3.0 → 冲击波（半径 1.5×弹体 = 36、40% ATK = 4）
	proj.size_mult = 4.0
	var near := _spawn_enemy(_make_enemy_data("E_NOVA_HI"), Vector2(320, 640))
	var far := _spawn_enemy(_make_enemy_data("E_NOVA_FAR"), Vector2(450, 640))
	_grid.rebuild(_alive_enemies)
	ef.handle(tb, tctx)
	_check("体积极限（单元）：size 4.0 ≥ 3.0 → 冲击波命中近旁敌（40%ATK = 4）",
		_approx(near.hp, 996.0), "hp=%s" % str(near.hp))
	_check("体积极限（单元）：冲击波半径外（150px > 36+网格保守余量）不波及",
		_approx(far.hp, 1000.0), "hp=%s" % str(far.hp))
	_check("体积极限（单元）：nova 计数 +1",
		DebugStats.get_counter(&"size_nova_triggered") == nova0 + 1)
	proj.nullify()
	w1.free()


func _test_size_nova_engine() -> void:
	print("── 体积极限质变（引擎路径验收） ──")
	var w1 := _make_weapon(GameConst.WeaponForm.BALLISTIC, _size_threshold_data(),
		Vector2(300, 640))
	var size_data := _make_trait_data("TRAIT_SIZE_ENG", GameConst.PoolClass.MECH, &"",
		&"EF_SIZE", 0.18, [GameConst.TraitEvent.ON_SPAWN, GameConst.TraitEvent.ON_HIT])
	size_data.stack_max = 8
	for i in range(7):
		w1.attach_trait(size_data)                 # 7 层 ×1.18 = 3.186 ≥ 3.0
	var primary := _spawn_enemy(_make_enemy_data("E_NOVA_MAIN"), Vector2(365, 640))
	var secondary := _spawn_enemy(_make_enemy_data("E_NOVA_SEC", 1000.0, 2.0),
		Vector2(365, 658))                          # 爆点 26.9px 内 / 不在弹道上 / 距武器更远
	w1.try_fire()
	var proj := _live_proj_pool_nodes()[0] as ProjectileBase
	_check("体积累计（引擎）：MEC_SIZE_STACK 7 层 → 1.18^7 ≈ 3.186",
		_approx(proj.size_mult, pow(1.18, 7.0), 0.001), "mult=%s" % str(proj.size_mult))
	_bump_frame()
	for i in range(12):
		if not proj.visible:
			break
		_bump_frame()
		proj.tick(DT)                              # 弹速 600 → 第 9 帧命中主目标（dist 20）
	_check("引擎命中：主目标受直击 10", _approx(primary.hp, 990.0), "hp=%s" % str(primary.hp))
	_check("引擎路径：size_mult≥3.0 命中应触发 TH_SIZE_NOVA 冲击波（次级目标 −40%ATK=4）",
		_approx(secondary.hp, 996.0),
		"hp=%s（期望 996——TraitContext.weapon 未接线，见报告）" % str(secondary.hp))
	_nullify_all_proj_pool()
	w1.free()


# ── 6. 分裂三重闸门 + ON_EXPIRE 分裂继承（要点 6） ────────────────
func _test_split_gates() -> void:
	print("── 分裂三重闸门 / 分裂继承 ──")
	var max_gen: int = 3
	var max_children: int = 8
	if GameConfig.balance != null:
		max_gen = GameConfig.balance.split_max_generation
		max_children = GameConfig.balance.split_max_children
	# 闸门一：代数 ≤3
	var p_gen := _spawn_proj({"position": Vector2(360, 640), "velocity": Vector2.ZERO,
		"lifetime": 10.0, "pierce": 1, "hitbox_radius": 6.0, "generation": max_gen,
		"panel_snapshot": {"base_atk": 10.0}, "team": 0})
	var rej_gen0: int = DebugStats.get_counter(&"split_rejected_generation")
	p_gen.request_split(2, 28.0, 0.4)
	_check("分裂闸门一：代数 %d（再分裂 →%d 超 ≤3）拒绝 + 计数" % [max_gen, max_gen + 1],
		DebugStats.get_counter(&"split_rejected_generation") == rej_gen0 + 1
			and _live_proj_pool_nodes().size() == 1)
	p_gen.nullify()
	# 闸门二：单次子数 ≤8
	var p_cnt := _spawn_proj({"position": Vector2(360, 640), "velocity": Vector2.ZERO,
		"lifetime": 10.0, "pierce": 1, "hitbox_radius": 6.0, "generation": 0,
		"panel_snapshot": {"base_atk": 10.0}, "team": 0})
	var rej_cnt0: int = DebugStats.get_counter(&"split_rejected_children")
	p_cnt.request_split(max_children + 1, 28.0, 0.4)
	_check("分裂闸门二：单次 %d > %d 拒绝 + 计数" % [max_children + 1, max_children],
		DebugStats.get_counter(&"split_rejected_children") == rej_cnt0 + 1
			and _live_proj_pool_nodes().size() == 1)
	# 闸门三：全场软上限（夹具收窄 soft_limit 验证闸门语义）
	var rej_soft0: int = DebugStats.get_counter(&"split_rejected_soft_limit")
	_proj_pool.soft_limit = _proj_pool.total_active()
	p_cnt.request_split(2, 28.0, 0.4)
	_check("分裂闸门三：全场存活 ≥ 软上限 → 拒绝 + 计数",
		DebugStats.get_counter(&"split_rejected_soft_limit") == rej_soft0 + 1
			and _live_proj_pool_nodes().size() == 1)
	_proj_pool.soft_limit = 1500
	p_cnt.nullify()
	# ON_EXPIRE 分裂（母弹消亡 → EF_FRACTAL split_request → request_split）
	var stack := TraitStack.new()
	var d_frac := _make_trait_data("TRAIT_FRACTAL", GameConst.PoolClass.MECH, &"",
		&"EF_FRACTAL", 2.0, [GameConst.TraitEvent.ON_EXPIRE])
	d_frac.value2 = 0.4
	d_frac.params = {"spread_deg": 28.0}
	stack.attach(d_frac)
	var d_inh := _make_trait_data("TRAIT_SPD_INH", GameConst.PoolClass.ADD, &"add_spd",
		&"EF_STAT", 0.18, [])
	d_inh.inheritable = true
	stack.attach(d_inh)
	var mother := _spawn_proj({
		"position": Vector2(360, 640),
		"velocity": Vector2(0, -600),
		"lifetime": 0.05,
		"pierce": 1,
		"hitbox_radius": 6.0,
		"element": GameConst.Element.FIR,
		"attach_value": 5.0,
		"generation": 0,
		"panel_snapshot": {"base_atk": 10.0},
		"trait_stack": stack,
		"team": 0,
	})
	mother.tick(0.1)                               # 寿命耗尽 → EXPIRED → ON_EXPIRE → 分裂
	var children: Array = []
	for node in _live_proj_pool_nodes():
		var p := node as ProjectileBase
		if p.generation == 1:
			children.append(p)
	_check("ON_EXPIRE 分裂：母弹消亡 → 2 枚 generation=1 子代（count=2）",
		children.size() == 2 and int(_proj_pool.stats()["live"]) == 2,
		"children=%d live=%d" % [children.size(), int(_proj_pool.stats()["live"])])
	var inherit_ok := true
	var elem_ok := true
	var attach_ok := true
	var angle_set: Array = []
	for c in children:
		var child := c as ProjectileBase
		inherit_ok = (inherit_ok
			and _approx(float(child.panel_snapshot.get("base_atk", 0.0)), 4.0, 0.001))
		elem_ok = (elem_ok and child.element == GameConst.Element.FIR)
		attach_ok = (attach_ok and _approx(child.attach_value, 0.0))
		angle_set.append(snappedf(child.velocity.angle_to(Vector2(0, -600)), 0.0001))
	angle_set.sort()
	_check("分裂继承 F-13：ATK 面板 40%（10 → 4.0）",
		inherit_ok and children.size() == 2)
	_check("分裂继承：元素继承 / 元素附着不继承（attach_value=0）",
		elem_ok and attach_ok)
	_check("分裂继承：夹角 ±28°（spread_deg，均匀分布）",
		_approx(float(angle_set[0]), -deg_to_rad(28.0), 0.001)
			and _approx(float(angle_set[1]), deg_to_rad(28.0), 0.001),
		"angles=%s" % str(angle_set))
	var stack_ok := true
	for c in children:
		var child := c as ProjectileBase
		stack_ok = (stack_ok and (child.trait_stack is TraitStack
			and ((child.trait_stack as TraitStack).size() == 1
				and (child.trait_stack as TraitStack).traits[0].data.id == &"TRAIT_SPD_INH")))
	_check("分裂继承 E-01：仅 inheritable 词条下传（分裂词条自身不复制，防指数裂变）",
		stack_ok and children.size() == 2)
	_nullify_all_proj_pool()


# ── 7. 反弹增伤乘区（要点 7） ─────────────────────────────────────
func _make_bounce_trait() -> TraitData:
	var d := _make_trait_data("TRAIT_BOUNCE_SYN", GameConst.PoolClass.MULT, &"syn_bounce",
		&"EF_BOUNCE", 1.4, [])
	d.cap_pool_p = 2.8
	d.condition = {"condition_id": GameConst.ConditionId.AFTER_BOUNCE, "params": {}}
	return d


func _test_bounce_mult() -> void:
	print("── 反弹增伤乘区 ──")
	# 条件自评（SynergyRules：AFTER_BOUNCE ← HIT_IS_BOUNCE）
	var stack := TraitStack.new()
	stack.attach(_make_bounce_trait())
	var proj := _spawn_proj({"position": Vector2(360, 640), "velocity": Vector2.ZERO,
		"lifetime": 10.0, "pierce": 1, "hitbox_radius": 6.0,
		"panel_snapshot": {"base_atk": 10.0}, "team": 0})
	var tctx := TraitContext.new()
	tctx.event = GameConst.TraitEvent.ON_HIT
	tctx.projectile = proj
	var dctx := DamageContext.make()
	dctx.hit_flags = GameConst.HIT_IS_BOUNCE
	tctx.damage_ctx = dctx
	var pools_bounce: Array[Dictionary] = stack.collect_mult_pools(tctx)
	tctx.damage_ctx = DamageContext.make()
	var pools_plain: Array[Dictionary] = stack.collect_mult_pools(tctx)
	_check("条件自评：AFTER_BOUNCE（hit_flags=IS_BOUNCE）→ 注入 ×1.4 乘区",
		pools_bounce.size() == 1 and (_approx(float(pools_bounce[0]["contrib"]), 1.4, 0.0001)
			and StringName(str(pools_bounce[0]["pool_id"])) == &"syn_bounce"))
	_check("条件自评：未反弹 → 该乘区不注入（contrib 0 条件拦截）", pools_plain.is_empty())
	proj.nullify()
	# 引擎路径：反弹后命中 → 伤害 ×(1+1.4) = 24
	var enemy := _spawn_enemy(_make_enemy_data("E_BOUNCE"), Vector2(366, 640))
	var stack2 := TraitStack.new()
	stack2.attach(_make_bounce_trait())
	var proj2 := _spawn_proj({
		"position": Vector2(3, 640),
		"velocity": Vector2(-6000, 0),
		"lifetime": 10.0,
		"pierce": 1,
		"bounces": 2,
		"hitbox_radius": 6.0,
		"panel_snapshot": {"base_atk": 10.0},
		"trait_stack": stack2,
		"team": 0,
	})
	for i in range(10):
		if not proj2.visible:
			break
		_bump_frame()
		proj2.tick(DT)                             # 首帧左缘反弹 → 右行 ~50px/帧 → 第 8 帧命中
	_check("反弹乘区（引擎）：反弹后命中伤害 = 10×(1+1.4) = 24",
		_approx(enemy.hp, 976.0, 0.01), "hp=%s" % str(enemy.hp))
	# 基线：未反弹直击 → 10
	var enemy2 := _spawn_enemy(_make_enemy_data("E_NOBOUNCE"), Vector2(366, 400))
	var proj3 := _spawn_proj({
		"position": Vector2(340, 400),
		"velocity": Vector2(2400, 0),
		"lifetime": 10.0,
		"pierce": 1,
		"hitbox_radius": 6.0,
		"panel_snapshot": {"base_atk": 10.0},
		"team": 0,
	})
	_bump_frame()
	proj3.tick(DT)
	_check("基线：未反弹直击伤害 10（乘区不注入）", _approx(enemy2.hp, 990.0, 0.01),
		"hp=%s" % str(enemy2.hp))
	_nullify_all_proj_pool()


# ── 8. 元素状态单元（要点 8-A） ───────────────────────────────────
func _test_elemental_state() -> void:
	print("── ElementalState 状态单元 ──")
	var lambdas: Array[float] = [0.35, 0.30, 0.40]
	# FIR：部分附着不触发
	var st := ElementalState.new()
	_check("附着：FIR 60 < 100 → 无状态触发（返回 NONE，槽内累计）",
		st.apply(GameConst.Element.FIR, 60.0, 0.0) == ElementalState.TRIGGER_NONE
			and _approx(st.gauges[GameConst.Element.FIR], 60.0))
	# FIR 满槽 → 点燃
	var code: int = st.apply(GameConst.Element.FIR, 40.0, 200.0)
	_check("点燃：FIR 满槽 → TRIGGER_BURN（层 1 / 3s / 快照 200）",
		code == ElementalState.TRIGGER_BURN and (st.burn_layers == 1
			and (_approx(st.burn_timer, 3.0) and (_approx(st.burn_snapshot_atk, 200.0)
				and _approx(st.gauges[GameConst.Element.FIR], 0.0)))))
	_check("状态自评：burn 期 is_state_active(FIR)=true（SYN_BURN_DEVOUR 输入）",
		st.is_state_active(GameConst.Element.FIR))
	# 层上限：5 层后第 6 次附着拒绝
	for i in range(4):
		st.apply(GameConst.Element.FIR, 100.0)
	var code6: int = st.apply(GameConst.Element.FIR, 100.0)
	_check("点燃层上限：第 5 层后第 6 次满槽附着拒绝（层保持 5）",
		code6 == ElementalState.TRIGGER_NONE and st.burn_layers == 5)
	# DOT 跳伤节拍（0.5s 一跳）
	var due_before: bool = st.consume_dot_due()
	st.tick(0.5, lambdas)
	var due_after: bool = st.consume_dot_due()
	var due_again: bool = st.consume_dot_due()
	_check("DOT 节拍：未到期不消费，0.5s 后恰一跳",
		(not due_before) and (due_after and not due_again))
	# 燃尽层清零
	st.tick(3.0, lambdas)
	_check("燃尽：burn_timer 到期 → 层清零（重复附着重新累计）+ 状态失效",
		st.burn_layers == 0 and not st.is_state_active(GameConst.Element.FIR))
	# λ 比例衰减（F-22）
	var st2 := ElementalState.new()
	st2.apply(GameConst.Element.FIR, 60.0)
	st2.apply(GameConst.Element.ICE, 60.0)
	st2.apply(GameConst.Element.LTG, 60.0)
	st2.tick(1.0, lambdas)
	_check("λ 比例衰减：60×(1−λ) → FIR 39 / ICE 42 / LTG 36",
		_approx(st2.gauges[GameConst.Element.FIR], 39.0, 0.001)
			and (_approx(st2.gauges[GameConst.Element.ICE], 42.0, 0.001)
				and _approx(st2.gauges[GameConst.Element.LTG], 36.0, 0.001)))
	# ICE：满槽寒滞 → 二次满槽完全冻结
	var st3 := ElementalState.new()
	var code_chill: int = st3.apply(GameConst.Element.ICE, 100.0)
	_check("寒滞：ICE 满槽 → TRIGGER_CHILL（移速 0.6 + 易伤 ×1.25）",
		code_chill == ElementalState.TRIGGER_CHILL
			and (_approx(st3.get_speed_factor(), 0.6)
				and (_approx(st3.get_vuln_factor(), 1.25)
					and st3.is_state_active(GameConst.Element.ICE))))
	var code_freeze: int = st3.apply(GameConst.Element.ICE, 100.0)
	_check("完全冻结：二次满槽 → TRIGGER_FREEZE（定身 speed 0）",
		code_freeze == ElementalState.TRIGGER_FREEZE
			and _approx(st3.get_speed_factor(), 0.0))
	# LTG：满槽感电（覆写传导目标数）
	var st4 := ElementalState.new()
	var code_shock: int = st4.apply(GameConst.Element.LTG, 100.0, 0.0, {"chain_targets": 4})
	_check("感电：LTG 满槽 → TRIGGER_SHOCK（层 2 覆写传导 4 目标）",
		code_shock == ElementalState.TRIGGER_SHOCK and st4.shock_chain_targets == 4)
	# 免疫位（F-17）
	var st_burn := ElementalState.new()
	st_burn.immune_mask = GameConst.IMMUNE_BURN
	_check("免疫：IMMUNE_BURN → 点燃不触发",
		st_burn.apply(GameConst.Element.FIR, 100.0) == ElementalState.TRIGGER_NONE
			and st_burn.burn_layers == 0)
	var st_shock := ElementalState.new()
	st_shock.immune_mask = GameConst.IMMUNE_SHOCK
	_check("免疫：IMMUNE_SHOCK → 感电不触发",
		st_shock.apply(GameConst.Element.LTG, 100.0) == ElementalState.TRIGGER_NONE)
	var st_frz := ElementalState.new()
	st_frz.immune_mask = GameConst.IMMUNE_FREEZE
	st_frz.apply(GameConst.Element.ICE, 100.0)
	var code_chill2: int = st_frz.apply(GameConst.Element.ICE, 100.0)
	_check("免疫：IMMUNE_FREEZE → 二次满槽仅寒滞（不冻结）",
		code_chill2 == ElementalState.TRIGGER_CHILL and _approx(st_frz.freeze_timer, 0.0))


# ── 9. 元素系统编排（要点 8-B：真件管线结算） ─────────────────────
func _test_elemental_system() -> void:
	print("── ElementalSystem 附着-衰减-反应 ──")
	# 宿主挂载 + 附着通道
	var e1 := _spawn_enemy(_make_enemy_data("E_EL1"), Vector2(200, 640))
	_sys.register_host(e1)
	_check("宿主挂载：register_host → ElementalState 注入", e1.get("elemental") is ElementalState)
	_sys.apply_attach(e1, GameConst.Element.FIR, 60.0)
	var st1: ElementalState = e1.get("elemental")
	_check("附着通道：apply_attach 60 → 槽内累计 60（未满不触发）",
		st1 != null and _approx(st1.gauges[GameConst.Element.FIR], 60.0))
	# 碎裂 ×2.0（点燃剩余 DOT 总额 180 × 2.0 = 360）
	_sys.apply_attach(e1, GameConst.Element.FIR, 100.0, {"snapshot": 200.0})  # 满槽 → 点燃
	_sys.apply_attach(e1, GameConst.Element.FIR, 30.0)                        # 复附着（双槽条件）
	_sys.apply_attach(e1, GameConst.Element.ICE, 30.0)
	_bump_frame()
	_sys.detect_reactions()
	_check("碎裂：2.0× 点燃剩余 DOT（0.15×200×1层×6跳=180 → 360 落血）",
		_approx(e1.hp, 640.0, 0.01), "hp=%s" % str(e1.hp))
	_check("碎裂消耗：双槽清空 + 燃尽（timer/层清零）",
		_approx(st1.gauges[GameConst.Element.FIR], 0.0)
			and (_approx(st1.gauges[GameConst.Element.ICE], 0.0)
				and (_approx(st1.burn_timer, 0.0) and st1.burn_layers == 0)))
	# 过载：120% ATK × 快照，半径 90 扩散
	var e2 := _spawn_enemy(_make_enemy_data("E_EL2"), Vector2(600, 640))
	var e2b := _spawn_enemy(_make_enemy_data("E_EL2B"), Vector2(660, 640))    # 60px < 90
	var e2c := _spawn_enemy(_make_enemy_data("E_EL2C"), Vector2(750, 640))    # 150px > 90
	_sys.register_host(e2)
	_sys.apply_attach(e2, GameConst.Element.FIR, 30.0, {"snapshot": 100.0})
	_sys.apply_attach(e2, GameConst.Element.LTG, 30.0)
	_bump_frame()
	_sys.detect_reactions()
	_check("过载：120%ATK（快照 100×1.2 = 120）主目标落血",
		_approx(e2.hp, 880.0, 0.01), "hp=%s" % str(e2.hp))
	_check("过载扩散：半径 90 内次级目标同额结算 / 圈外不波及",
		_approx(e2b.hp, 880.0, 0.01) and _approx(e2c.hp, 1000.0, 0.01))
	# 超导：全抗 −30%，6s 到期恢复
	var ed3 := _make_enemy_data("E_EL3")
	ed3.resist = [0.3, 0.1, 0.0, 0.0]
	var e3 := _spawn_enemy(ed3, Vector2(200, 900))
	_sys.register_host(e3)
	_sys.apply_attach(e3, GameConst.Element.ICE, 30.0)
	_sys.apply_attach(e3, GameConst.Element.LTG, 30.0)
	_bump_frame()
	_sys.detect_reactions()
	_check("超导：全抗 −30%（0.3→0.0 / 0.1→−0.2 / 0→−0.3，可击破至负值）",
		_approx(e3.get_resist(GameConst.Element.KIN), 0.0, 0.0001)
			and (_approx(e3.get_resist(GameConst.Element.FIR), -0.2, 0.0001)
				and _approx(e3.get_resist(GameConst.Element.LTG), -0.3, 0.0001)))
	_bump_frame()
	_sys.tick(6.5)
	_check("超导到期：6s 后恢复 +0.3（回到 0.3/0.1/0.0）",
		_approx(e3.get_resist(GameConst.Element.KIN), 0.3, 0.0001)
			and (_approx(e3.get_resist(GameConst.Element.FIR), 0.1, 0.0001)
				and _approx(e3.get_resist(GameConst.Element.LTG), 0.0, 0.0001)))
	# 反应 CD 分立（v1.1.0 授权更新：超导 rule.cd=6.0；原 cd_rxn=2s 全局口径退役）
	var st3: ElementalState = e3.get("elemental")
	var super0: int = DebugStats.get_counter(&"reaction_superconduct")
	_sys.apply_attach(e3, GameConst.Element.ICE, 30.0)
	_sys.apply_attach(e3, GameConst.Element.LTG, 30.0)
	_bump_frame()
	_sys.detect_reactions()
	_check("反应 CD：触发后 reaction_cd = 6s（超导 rule cd 分立），期内同反应不再触发",
		_approx(float(st3.reaction_cd.get(GameConst.ReactionType.RXN_ICE_LTG, 0.0)), 6.0, 0.01)
			and DebugStats.get_counter(&"reaction_superconduct") == super0 + 1)
	_sys.apply_attach(e3, GameConst.Element.ICE, 30.0)
	_sys.apply_attach(e3, GameConst.Element.LTG, 30.0)
	_bump_frame()
	_sys.detect_reactions()
	_check("反应 CD：6s 内重附双槽不触发",
		DebugStats.get_counter(&"reaction_superconduct") == super0 + 1)
	_bump_frame()
	_sys.tick(6.0)
	_sys.apply_attach(e3, GameConst.Element.ICE, 30.0)
	_sys.apply_attach(e3, GameConst.Element.LTG, 30.0)
	_bump_frame()
	_sys.detect_reactions()
	_check("反应 CD：超导 cd=6.0 过期后可再次触发",
		DebugStats.get_counter(&"reaction_superconduct") == super0 + 2)
	# 一帧一反应 + 优先级（碎裂 > 过载 > 超导）
	var e5 := _spawn_enemy(_make_enemy_data("E_EL5"), Vector2(600, 200))
	_sys.register_host(e5)
	var rxn0: int = DebugStats.get_counter(&"reaction_triggered")
	_sys.apply_attach(e5, GameConst.Element.FIR, 30.0)
	_sys.apply_attach(e5, GameConst.Element.ICE, 30.0)
	_sys.apply_attach(e5, GameConst.Element.LTG, 30.0)
	_bump_frame()
	_sys.detect_reactions()
	var st5: ElementalState = e5.get("elemental")
	_check("反应优先级：三槽齐备 → 仅碎裂触发（一帧一反应）",
		DebugStats.get_counter(&"reaction_triggered") == rxn0 + 1
			and (_approx(st5.gauges[GameConst.Element.FIR], 0.0)
				and (_approx(st5.gauges[GameConst.Element.ICE], 0.0)
					and _approx(st5.gauges[GameConst.Element.LTG], 30.0, 0.001))))
	_bump_frame()
	_sys.detect_reactions()
	_check("一帧一反应：剩余单槽（LTG）不成对 → 不再触发",
		DebugStats.get_counter(&"reaction_triggered") == rxn0 + 1)
	# 感电连锁：3 目标 / 160px / 35% 每跳 / 深度 2 衰减 / 同链去重
	var e_a := _spawn_enemy(_make_enemy_data("E_S_A"), Vector2(360, 640))
	var e_b := _spawn_enemy(_make_enemy_data("E_S_B"), Vector2(440, 640))
	var e_c := _spawn_enemy(_make_enemy_data("E_S_C"), Vector2(360, 760))
	var e_d := _spawn_enemy(_make_enemy_data("E_S_D"), Vector2(480, 700))
	var e_e := _spawn_enemy(_make_enemy_data("E_S_E"), Vector2(900, 640))
	for h in [e_a, e_b, e_c, e_d, e_e]:
		_sys.register_host(h)
	_sys.apply_attach(e_a, GameConst.Element.LTG, 100.0, {"hit_damage": 100.0})
	_check("感电连锁：满槽 → 160px 内最近 3 目标各受 35%×100 = 35",
		_approx(e_b.hp, 965.0, 0.01) and (_approx(e_c.hp, 965.0, 0.01)
			and _approx(e_d.hp, 965.0, 0.01)),
		"B=%s C=%s D=%s" % [str(e_b.hp), str(e_c.hp), str(e_d.hp)])
	_check("感电连锁：源目标去重 / 540px 外不传导",
		_approx(e_a.hp, 1000.0, 0.01) and _approx(e_e.hp, 1000.0, 0.01))
	# DOT 跳伤（15%ATK × 层数，0.5s 一跳，HIT_IS_DOT 不掷暴击）
	var e6 := _spawn_enemy(_make_enemy_data("E_DOT"), Vector2(600, 900))
	_sys.register_host(e6)
	_sys.apply_attach(e6, GameConst.Element.FIR, 100.0, {"snapshot": 200.0})
	_bump_frame()
	_sys.tick(0.5)
	_bump_frame()
	_sys.tick(0.5)
	_check("DOT 跳伤：15%ATK×1 层 = 30/跳 ×2 跳 = 60 落血",
		_approx(e6.hp, 940.0, 0.01), "hp=%s" % str(e6.hp))
	# 反应强化 ×1.8（ELE_REACTION_VOID → WeaponBase.attach_trait 注册通道；置末避免污染前组系数）
	var w_reg := _make_weapon(GameConst.WeaponForm.BALLISTIC,
		_make_weapon_data(GameConst.WeaponForm.BALLISTIC), Vector2(100, 100), _sys)
	var d_void := _make_trait_data("TRAIT_RXN_VOID", GameConst.PoolClass.ELEM, &"",
		&"EF_ELEMENTAL", 0.0, [])
	d_void.params = {"reaction_mult": 1.8}
	_check("反应强化注册：attach_trait(ELE_REACTION_VOID) → ×1.8 聚合",
		w_reg.attach_trait(d_void) and _approx(_sys.reaction_mult(), 1.8, 0.0001))
	var e1b := _spawn_enemy(_make_enemy_data("E_EL1B"), Vector2(200, 200))
	_sys.register_host(e1b)
	_sys.apply_attach(e1b, GameConst.Element.FIR, 100.0, {"snapshot": 200.0})
	_sys.apply_attach(e1b, GameConst.Element.FIR, 30.0)
	_sys.apply_attach(e1b, GameConst.Element.ICE, 30.0)
	_bump_frame()
	_sys.detect_reactions()
	_check("碎裂 ×反应强化：360 × 1.8 = 648 落血", _approx(e1b.hp, 352.0, 0.01),
		"hp=%s" % str(e1b.hp))
	w_reg.free()


# ── 10. 环绕武器 / 弧斩消弹（要点 10） ────────────────────────────
func _test_orbit_weapon() -> void:
	print("── OrbitWeapon 环绕力场 ──")
	var data1: WeaponData = _make_weapon_data(GameConst.WeaponForm.MELEE,
		{"base_atk": 10.0, "cd": 0.5},
		{"orbs": 2, "orbit_radius": 90.0, "angular_speed": 0.0, "orb_radius": 16.0,
		"hit_cd": 0.25, "knockback": 0.0, "nullify": false})
	var w1 := _make_weapon(GameConst.WeaponForm.MELEE, data1, Vector2(360, 640)) as OrbitWeapon
	# 谐振轨道通道（MEC_ORBIT_LINK：ctx.weapon = OrbitWeapon 的 ON_SPAWN 派发）
	var stack := TraitStack.new()
	stack.attach(_make_trait_data("TRAIT_ORBIT_LINK", GameConst.PoolClass.MECH, &"",
		&"EF_MECH", 0.0, [GameConst.TraitEvent.ON_SPAWN]))
	var tctx := TraitContext.new()
	tctx.event = GameConst.TraitEvent.ON_SPAWN
	tctx.weapon = w1
	stack.dispatch(GameConst.TraitEvent.ON_SPAWN, tctx)
	_check("谐振轨道：MEC_ORBIT_LINK ON_SPAWN → orbs_bonus +1", w1.orbs_bonus == 1)
	w1.tick(DT)                                    # try_fire → 创建常驻力场
	_check("力场参数重写：orbs = 表值+加成 = 3 / 半径 90 / 角速度口径",
		w1.orbit_field != null and (w1.orbit_field.orbs == 3
			and (_approx(w1.orbit_field.orbit_radius, 90.0)
				and _approx(w1.orbit_field.angular_speed, 0.0))))
	_check("力场常驻：再次 try_fire 不重复调度", not w1.try_fire())
	# 周期判定：orb0 相位 0 → (450, 640)；hit_cd 0.25s → 40 tick 恰 2 击
	var enemy := _spawn_enemy(_make_enemy_data("E_ORBIT"), Vector2(450, 640))
	for i in range(40):
		w1.tick(DT)
	_check("环绕周期判定：命中 → hit_cd 0.25s → 周期再击（40 tick 恰 2 次 ×10）",
		_approx(enemy.hp, 980.0, 0.01),
		"hp=%s（orbit_field.weapon=%s——_ensure_orbit_field 未注入结算宿主，判定早退，见报告）"
			% [str(enemy.hp), str(w1.orbit_field.weapon)])
	w1.free()


func _test_arc_slash() -> void:
	print("── ArcSlash 周期挥斩 / 消弹格挡 ──")
	var data1: WeaponData = _make_weapon_data(GameConst.WeaponForm.MELEE,
		{"base_atk": 10.0, "cd": 0.5},
		{"nullify": true, "slash_radius": 150.0, "arc_deg": 120.0,
		"max_targets": 8, "knockback": 0.0})
	var w1 := _make_weapon(GameConst.WeaponForm.MELEE, data1, Vector2(360, 640)) as OrbitWeapon
	var e_in1 := _spawn_enemy(_make_enemy_data("E_SL_A"), Vector2(440, 640))   # 0° 80px
	var e_in2 := _spawn_enemy(_make_enemy_data("E_SL_B"), Vector2(463.9, 700)) # 30° 120px
	var e_out := _spawn_enemy(_make_enemy_data("E_SL_C"), Vector2(360, 760))   # 90° 扇外
	w1.tick(DT)                                    # 开窗（朝向最近敌 → facing 0）+ 首帧判定
	_check("挥斩：扇形内命中（0°/30° 各 −10）",
		_approx(e_in1.hp, 990.0, 0.01) and _approx(e_in2.hp, 990.0, 0.01),
		"A=%s B=%s" % [str(e_in1.hp), str(e_in2.hp)])
	_check("挥斩：扇形外（90° 超 ±60° 半角）不判定", _approx(e_out.hp, 1000.0, 0.01))
	# 敌弹注入（消弹格挡路径）：弧内 2 弹 + 弧外 1 弹
	var b_in1 := _spawn_enemy_bullet(Vector2(460, 640))
	var b_in2 := _spawn_enemy_bullet(Vector2(463.9, 700))
	var b_out := _spawn_enemy_bullet(Vector2(360, 780))
	var bullets: Array[Node2D] = [b_in1, b_in2, b_out]
	_bullet_grid.rebuild(bullets)
	w1.set_enemy_bullet_grid(_bullet_grid)
	var rz0: int = DebugStats.get_counter(&"recycle_reason_%d" % GameConst.RecycleReason.NULLIFIED)
	var bn0: int = DebugStats.get_counter(&"bullet_nullified")
	var free0: int = int(_proj_pool.stats()["free"])
	w1.tick(DT)                                    # 窗口期第 2 帧：弧内敌弹 NULLIFIED
	_check("消弹格挡：弧内敌方弹 → OnExpire(NULLIFIED) 统一收束（2 弹回收）",
		DebugStats.get_counter(&"recycle_reason_%d" % GameConst.RecycleReason.NULLIFIED) == rz0 + 2
			and (DebugStats.get_counter(&"bullet_nullified") == bn0 + 2
				and int(_proj_pool.stats()["free"]) == free0 + 2))
	_check("消弹格挡：弧外弹保留存活", not b_out.is_clean and b_out.visible)
	# 同窗同目标单次 + 窗口 0.15s 过期
	for i in range(19):
		w1.tick(DT)                                # 窗口耗尽（0.15s = 18 帧）
	_check("挥斩窗口：0.15s 判定窗 → 窗口外无判定（visible 复位）",
		_approx(w1.arc_slash.window_left, 0.0) and not w1.arc_slash.visible)
	_check("挥斩去重：同窗同目标单次（A/B 不再扣血）",
		_approx(e_in1.hp, 990.0, 0.01) and _approx(e_in2.hp, 990.0, 0.01))
	w1.free()
	# 单斩目标上限（max_targets=2）
	var data2: WeaponData = _make_weapon_data(GameConst.WeaponForm.MELEE,
		{"base_atk": 10.0, "cd": 0.5},
		{"nullify": true, "slash_radius": 150.0, "arc_deg": 120.0,
		"max_targets": 2, "knockback": 0.0})
	var w2 := _make_weapon(GameConst.WeaponForm.MELEE, data2, Vector2(360, 150)) as OrbitWeapon
	var f1 := _spawn_enemy(_make_enemy_data("E_CAP_A"), Vector2(430, 150))
	var f2 := _spawn_enemy(_make_enemy_data("E_CAP_B"), Vector2(460, 170))
	var f3 := _spawn_enemy(_make_enemy_data("E_CAP_C"), Vector2(453.9, 210))
	w2.tick(DT)
	var hurt := 0
	for e in [f1, f2, f3]:
		if not _approx(e.hp, 1000.0, 0.01):
			hurt += 1
	_check("单斩上限：max_targets=2 → 恰 2 个目标受伤", hurt == 2, "hurt=%d" % hurt)
	w2.free()


func _spawn_enemy_bullet(p_pos: Vector2) -> ProjectileBase:
	var b := _proj_pool.acquire() as ProjectileBase
	b.damage_pipeline = _pipeline
	b.pool = _proj_pool
	b.spawn({
		"position": p_pos,
		"velocity": Vector2.ZERO,
		"lifetime": 10.0,
		"pierce": 1,
		"hitbox_radius": 6.0,
		"panel_snapshot": {"base_atk": 0.0},
		"team": 1,
	})
	return b

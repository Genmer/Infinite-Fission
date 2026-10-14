# tests/runner/r195_laser_pierce_cases.gd
# R195 激光穿透统包用例体（由 test_r195_laser_pierce.gd 入口在 autoload 就绪后运行时加载编译）。
# 覆盖（S1-S9 探针，直驱范式沿用 pkg3_cases.gd：weapon(100,640) 沿 +X，
# E1/E2/E3=(260/420/580,640) 同轴 beam_length=560 内，E4=(700,640) t=600 超程对照，
# beam.tick(0.26) 节拍——每 tick 恰 2 跳/t目标）：
#   S1  基线（pierce=1）零位移：仅 E1 结算（978.4=1000−2×10×1.08 灼焦 1 层已知数）、
#       E2-E4 满血、束端=E1、settle 2 / popup 1（旧单目标口径逐位同构）
#   S2  预算口径 hit=N：N=2 → 恰 E1+E2（E3/E4 满血）；N=3 → 恰 E1-E3；E4 恒满血（超程）
#   S3  无逐目标衰减：N=2 时 E1/E2 同拍伤害相等（弹体真口径：每跳同 base_atk 只扣计数）
#   S4  SYN_PIERCE_EVO 激活：E1 index=2 → ×1.2、E2 index=3 → ×1.4（×灼焦 1.08；
#       N=1 单目标首跳即 ×1.2——与弹体同紫卡首跳同数值，pierce_index=序数+1）
#   S5  灼焦归属：N=2 持续照射 E1/E2 各自 scorch_layers_of>0、轴外 E3==0（B 案全量同叠）
#   S6  束端=末贯穿目标（t 最大者）；无敌时束长==beam_length 不超程（<1280 不穿屏）
#   S7  副束门（W4+MEC_SPLIT_PRISM，主束挂 AFF_PIERCE N=2）：副束 pierce==1 只结算
#       锁定 1 目标——同轴 E3 金丝雀恒满血（副束不吃穿透）
#   S8  折射分叉数不随 N 增长（W5 主束 N≥2 与 N=1 基线同分叉数）+ 贯穿目标
#       ∈hit_exclusions()（防分叉×穿透连乘）
#   S9  契约：last_hit_uid 恒==首（最近）目标 uid；_pierce_count()==maxi(L表+round
#       (add_pierce),0)（基线 1 / 挂 AFF_PIERCE 2）；pause 面板穿透行经 has_method
#       ("_pierce_count") 输出真值非 0（pause_overlay.gd:566 守卫自动转正）
# 确定性：pkg3 同款夹具（DamagePipelineStub 透传桩 S×M×L×C×V 直算、静止敌、固定坐标、
#         crit_rate=0 零掷骰）；词条挂真实 .tres（SYN_PIERCE_EVO/AFF_PIERCE/
#         MEC_SPLIT_PRISM——required_forms [0,1] 挂载侧不设门，直驱合法）。
extends RefCounted

const BALLISTIC_SCENE := "res://scenes/combat/projectiles/ballistic_projectile.tscn"
const HOMING_SCENE := "res://scenes/combat/projectiles/homing_projectile.tscn"
const LASER_SCENE := "res://scenes/combat/lasers/laser_beam.tscn"
const ENEMY_SCENE := "res://scenes/combat/enemies/enemy.tscn"
const DT := 1.0 / 120.0
const WEAPON_POS := Vector2(100.0, 640.0)        # 束原点（+X 轴向）
const E1_POS := Vector2(260.0, 640.0)            # t=160（首目标，最近）
const E2_POS := Vector2(420.0, 640.0)            # t=320（贯穿 2）
const E3_POS := Vector2(580.0, 640.0)            # t=480（贯穿 3 / S7 金丝雀）
const E4_POS := Vector2(700.0, 640.0)            # t=600 > 560 超程对照（恒不命中）
const AXIS_ENEMIES: Array[Vector2] = [E1_POS, E2_POS, E3_POS, E4_POS]

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []

var _proj_pool: ProjectilePool
var _homing_pool: ProjectilePool
var _laser_pool: LaserBeamPool
var _enemy_pool: EnemyPool
var _grid: SpaceGrid
var _pipeline: DamagePipelineStub
var _alive_enemies: Array[Node2D] = []
var _wd_counter: int = 0                         # WeaponData id 确定性计数器


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_ensure_autoloads()
	_test_s1_baseline()                           # 基线零位移（已知数 978.4）
	_test_s2_budget()                             # 预算口径 hit=N + E4 超程对照
	_test_s3_no_decay()                           # 无逐目标衰减
	_test_s4_syn_activation()                     # SYN 激活值（pierce_index=序数+1）
	_test_s5_scorch_attribution()                 # 灼焦归属（B 案全量同叠）
	_test_s6_beam_end()                           # 束端=末贯穿目标 / 无敌满束长
	_test_s7_sub_beam_gate()                      # 副束门（预算恒 1）
	_test_s8_refraction_forks()                   # 折射分叉数不随 N 增长
	_test_s9_contract()                           # last_hit_uid / _pierce_count / 面板行
	_summary()


func fail_count() -> int:
	return _fail


# ── 支撑（pkg3 直驱同款夹具） ─────────────────────────────────────
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


func _merge_dict(p_base: Dictionary, p_over: Dictionary) -> Dictionary:
	var out := p_base.duplicate(true)
	for key in p_over:
		out[key] = p_over[key]
	return out


func _make_weapon_data(p_pierce: int, p_segment: Dictionary) -> WeaponData:
	_wd_counter += 1
	var d := WeaponData.new()
	d.id = StringName("W_R195_%d" % _wd_counter)
	d.display_name = "R195 测试武器 %d" % _wd_counter
	d.form = GameConst.WeaponForm.LASER
	d.crit_rate = 0.0                             # 零掷骰（确定性）
	d.crit_dmg = 2.0
	d.hitbox_r = 6.0
	for i in range(5):
		var ls := WeaponLevelStats.new()
		ls.base_atk = 10.0
		ls.rof = 8.0                               # 跳频 8/s → tick(0.26) 恰 2 跳
		ls.cd = 0.5
		ls.pierce = p_pierce                       # L 表 pierce（预算口径直驱）
		ls.pellets = 1
		d.upgrade_table.append(ls)
	d.laser = _merge_dict(d.laser, p_segment)
	return d


func _make_weapon(p_data: WeaponData) -> LaserWeapon:
	var w := LaserWeapon.new()
	w.name = "R195Weapon_%d" % _wd_counter
	tree.get_root().add_child(w)
	w.position = WEAPON_POS
	w.setup(p_data, null, {
		"pipeline": _pipeline,
		"projectile_pool": _proj_pool,
		"enemy_grid": _grid,
		"laser_pool": _laser_pool,
		"homing_pool": _homing_pool,
		"elemental": null,
	})
	return w


func _make_enemy_data(p_id: String, p_hp: float = 1000.0, p_hitbox_r: float = 14.0) -> EnemyData:
	var d := EnemyData.new()
	d.id = StringName(p_id)
	d.display_name = p_id
	d.hp_base = p_hp
	d.spd_base = 0.0                              # 静止敌（几何确定性）
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


func _clear_enemies() -> void:
	# 探针间清场（同坐标复用防残血串扰；池归还 + 网格重建）
	for e in _alive_enemies:
		if is_instance_valid(e):
			_enemy_pool.release(e)
	_alive_enemies.clear()
	_grid.rebuild(_alive_enemies)


func _setup_world() -> void:
	_proj_pool = ProjectilePool.new()
	_proj_pool.name = "R195ProjPool"
	tree.get_root().add_child(_proj_pool)
	_proj_pool.setup(&"r195_test", load(BALLISTIC_SCENE), 16)
	_homing_pool = ProjectilePool.new()
	_homing_pool.name = "R195HomingPool"
	tree.get_root().add_child(_homing_pool)
	_homing_pool.setup(&"r195_homing", load(HOMING_SCENE), 8)
	_laser_pool = LaserBeamPool.new()
	_laser_pool.name = "R195LaserPool"
	tree.get_root().add_child(_laser_pool)
	_laser_pool.setup(&"r195_laser", load(LASER_SCENE), 16)
	var ep := EnemyPool.new()
	ep.name = "R195EnemyPool"
	tree.get_root().add_child(ep)
	ep.setup(&"r195_enemy", load(ENEMY_SCENE), 32)
	_enemy_pool = ep
	_grid = SpaceGrid.new()
	_grid.configure(Vector2(720, 1280), 192.0)
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
	_pipeline = null


func _load_trait(p_path: String) -> TraitData:
	# 真实 .tres 直载（挂载侧无形态门——CardGenerator.mount_gate_allows 仅卡架/回响
	# 路径；直驱合法。真源数据同步验证：required_forms [0,1] / SYN condition 等）
	var res: Variant = load(p_path)
	return res as TraitData


## 轴向探针：N=pierce 武器 + AXES 敌位 → try_fire → 每束 tick(0.26)×ticks 拍。
## 返回 {weapon, beam, enemies}（调用方断言后 free weapon）。
func _run_axis_probe(p_pierce: int, p_trait_paths: Array[String], p_positions: Array[Vector2],
		p_ticks: int = 1) -> Dictionary:
	var w := _make_weapon(_make_weapon_data(p_pierce, {"refract_beams": 0,
		"beam_length": 560.0}))
	for path in p_trait_paths:
		var td := _load_trait(path)
		_check("探针前置：真卡挂载（%s）" % path, td != null and w.attach_trait(td))
	var enemies: Array[Node2D] = []
	for i in p_positions.size():
		enemies.append(_spawn_enemy(_make_enemy_data("E_R195_%d" % i), p_positions[i]))
	_check("探针前置：try_fire 维持主束", w.try_fire() and w.active_beams.size() >= 1)
	var beam := w.active_beams[0]
	for t in p_ticks:
		beam.tick(0.26)
	return {"weapon": w, "beam": beam, "enemies": enemies}


## 轴向束端（Line2D 末点 → 全局坐标）
func _beam_end_global(p_beam: LaserBeam) -> Vector2:
	return p_beam.to_global(p_beam._line.get_point_position(1))


# ── S1 基线零位移（pierce=1 与旧单目标口径逐位同构） ───────────────
func _test_s1_baseline() -> void:
	print("── S1 基线（pierce=1）──")
	_setup_world()
	var probe := _run_axis_probe(1, [], AXIS_ENEMIES)
	var beam: LaserBeam = probe["beam"]
	var es: Array[Node2D] = probe["enemies"]
	_check("S1 前置：beam.pierce==1（预算缺省=旧口径）", beam.pierce == 1, str(beam.pierce))
	_check("S1①：仅 E1 结算——hp 978.4（2 跳×10×1.08 灼焦 1 层，pkg3 已知数同源）",
		_approx((es[0] as Enemy).hp, 978.4, 0.01), "hp=%s" % str((es[0] as Enemy).hp))
	var rest_full := true
	for i in range(1, 4):
		if not _approx((es[i] as Enemy).hp, 1000.0, 0.001):
			rest_full = false
	_check("S1②：E2/E3/E4 满血（单目标口径零贯穿）", rest_full)
	_check("S1③：束端==E1（首/最近目标）",
		_beam_end_global(beam).distance_to((es[0] as Node2D).global_position) <= 0.5,
		"end=%s" % str(_beam_end_global(beam)))
	_check("S1④：结算节拍 settle==2 / 跳字 ≤15Hz→1", beam.settle_count == 2
		and beam.popup_count == 1,
		"settle=%d popup=%d" % [beam.settle_count, beam.popup_count])
	(probe["weapon"] as LaserWeapon).free()
	_teardown_world()


# ── S2 预算口径 hit=N（E4 t=600 超程恒满血） ──────────────────────
func _test_s2_budget() -> void:
	print("── S2 预算口径 hit=N ──")
	_setup_world()
	# N=2 → 恰 E1+E2
	var p2 := _run_axis_probe(2, [], AXIS_ENEMIES)
	var b2: LaserBeam = p2["beam"]
	var e2s: Array[Node2D] = p2["enemies"]
	_check("S2①：N=2 → E1/E2 各 978.4（恰 2 目标×2 跳）",
		_approx((e2s[0] as Enemy).hp, 978.4, 0.01)
		and _approx((e2s[1] as Enemy).hp, 978.4, 0.01),
		"e1=%s e2=%s" % [str((e2s[0] as Enemy).hp), str((e2s[1] as Enemy).hp)])
	_check("S2②：N=2 → E3/E4 满血（预算截断 + 超程对照 t=600>560）",
		_approx((e2s[2] as Enemy).hp, 1000.0, 0.001)
		and _approx((e2s[3] as Enemy).hp, 1000.0, 0.001))
	_check("S2③：N=2 settle==4（2 目标×2 跳）", b2.settle_count == 4,
		"settle=%d" % b2.settle_count)
	(p2["weapon"] as LaserWeapon).free()
	_clear_enemies()
	# N=3 → 恰 E1-E3
	var p3 := _run_axis_probe(3, [], AXIS_ENEMIES)
	var e3s: Array[Node2D] = p3["enemies"]
	var first3_hit := true
	for i in range(3):
		if _approx((e3s[i] as Enemy).hp, 1000.0, 0.001):
			first3_hit = false
	_check("S2④：N=3 → E1-E3 全部结算（<1000）", first3_hit)
	_check("S2⑤：N=3 → E4 恒满血（超程对照零位移）",
		_approx((e3s[3] as Enemy).hp, 1000.0, 0.001),
		"e4=%s" % str((e3s[3] as Enemy).hp))
	(p3["weapon"] as LaserWeapon).free()
	_teardown_world()


# ── S3 无逐目标衰减（弹体真口径：每跳同 base_atk 只扣计数） ────────
func _test_s3_no_decay() -> void:
	print("── S3 无逐目标衰减 ──")
	_setup_world()
	var probe := _run_axis_probe(2, [], [E1_POS, E2_POS])
	var es: Array[Node2D] = probe["enemies"]
	var d1 := 1000.0 - (es[0] as Enemy).hp
	var d2 := 1000.0 - (es[1] as Enemy).hp
	_check("S3①：N=2 同拍 E1/E2 伤害相等（无 ×0.6^(n-1) 逐目标衰减；各 21.6）",
		_approx(d1, d2, 0.001) and _approx(d1, 21.6, 0.01),
		"d1=%.3f d2=%.3f" % [d1, d2])
	(probe["weapon"] as LaserWeapon).free()
	_teardown_world()


# ── S4 SYN_PIERCE_EVO 激活（pierce_index=序数+1，与弹体同式） ──────
func _test_s4_syn_activation() -> void:
	print("── S4 SYN 激活值 ──")
	_setup_world()
	var syn: Array[String] = ["res://resources/traits/SYN_PIERCE_EVO.tres"]
	# N=2：E1 index=2 → ×1.2、E2 index=3 → ×1.4（各 ×灼焦 1.08）
	var probe := _run_axis_probe(2, syn, [E1_POS, E2_POS])
	var es: Array[Node2D] = probe["enemies"]
	var d1 := 1000.0 - (es[0] as Enemy).hp
	var d2 := 1000.0 - (es[1] as Enemy).hp
	_check("S4①：E1 ×1.2（index=2：0.2×(2−1)）×灼焦1.08 → 2 跳 25.92",
		_approx(d1, 25.92, 0.01), "d1=%.4f" % d1)
	_check("S4②：E2 ×1.4（index=3：0.2×(3−1)）×灼焦1.08 → 2 跳 30.24",
		_approx(d2, 30.24, 0.01), "d2=%.4f" % d2)
	_check("S4③：逐目标伤害比 == 1.4/1.2（区内累进同弹体式）",
		_approx(d2 / d1, 1.4 / 1.2, 0.001), "ratio=%.4f" % (d2 / d1))
	(probe["weapon"] as LaserWeapon).free()
	_clear_enemies()
	# N=1 单目标：首跳即 ×1.2（pierce_index=2——与弹体同紫卡首跳同数值）
	var p1 := _run_axis_probe(1, syn, [E1_POS])
	var e1: Node2D = p1["enemies"][0]
	var d1s := 1000.0 - (e1 as Enemy).hp
	_check("S4④：N=1 首目标即 ×1.2 → 2 跳 25.92（SYN 激光 0→生效，R195 有意变更）",
		_approx(d1s, 25.92, 0.01), "d1=%.4f" % d1s)
	(p1["weapon"] as LaserWeapon).free()
	_teardown_world()


# ── S5 灼焦归属（B 案：贯穿目标全量同叠） ─────────────────────────
func _test_s5_scorch_attribution() -> void:
	print("── S5 灼焦归属 ──")
	LaserBeam.scorch_pool_reset()                 # 目标侧单池静态——跨用例隔离清池
	_setup_world()
	var off_axis := Vector2(300.0, 500.0)         # perp=140 > reach=21：主束永不命中
	var probe := _run_axis_probe(2, [], [E1_POS, E2_POS, off_axis, E4_POS])
	var es: Array[Node2D] = probe["enemies"]
	_check("S5①：E1 scorch_layers_of==1（1 层/0.25s，tick 0.26 恰 1 层）",
		LaserBeam.scorch_layers_of(int((es[0] as Node2D).get("uid"))) == 1,
		str(LaserBeam.scorch_layers_of(int((es[0] as Node2D).get("uid")))))
	_check("S5②：E2（贯穿目标）灼焦同叠 ==1（B 案全量同叠）",
		LaserBeam.scorch_layers_of(int((es[1] as Node2D).get("uid"))) == 1,
		str(LaserBeam.scorch_layers_of(int((es[1] as Node2D).get("uid")))))
	_check("S5③：轴外 E3 ==0（未命中不叠焦）",
		LaserBeam.scorch_layers_of(int((es[2] as Node2D).get("uid"))) == 0)
	(probe["weapon"] as LaserWeapon).free()
	_teardown_world()


# ── S6 束端=末贯穿目标 / 无敌满束长不超程 ─────────────────────────
func _test_s6_beam_end() -> void:
	print("── S6 束端点归属 ──")
	_setup_world()
	var probe2 := _run_axis_probe(2, [], [E1_POS, E2_POS, E3_POS, E4_POS])
	var e2s: Array[Node2D] = probe2["enemies"]
	_check("S6①：N=2 束端==末贯穿目标 E2（t 最大者）",
		_beam_end_global(probe2["beam"]).distance_to((e2s[1] as Node2D).global_position) <= 0.5,
		"end=%s" % str(_beam_end_global(probe2["beam"])))
	(probe2["weapon"] as LaserWeapon).free()
	_clear_enemies()
	var probe3 := _run_axis_probe(3, [], [E1_POS, E2_POS, E3_POS, E4_POS])
	var e3s: Array[Node2D] = probe3["enemies"]
	_check("S6②：N=3 束端==E3",
		_beam_end_global(probe3["beam"]).distance_to((e3s[2] as Node2D).global_position) <= 0.5)
	(probe3["weapon"] as LaserWeapon).free()
	_clear_enemies()
	# 无敌：画满 beam_length（UP 回退指向），不超程不穿屏（560<1280 逻辑域）
	var wl := _make_weapon(_make_weapon_data(2, {"refract_beams": 0, "beam_length": 560.0}))
	_check("S6 前置：try_fire（无目标维持 UP 指向）", wl.try_fire()
		and wl.active_beams.size() == 1)
	var bl: LaserBeam = wl.active_beams[0]
	bl.tick(0.26)
	var end_pos := _beam_end_global(bl)
	var span := (end_pos - bl.global_position).length()
	_check("S6③：无敌束长==beam_length（560，画满不超程）", _approx(span, 560.0, 0.5),
		"span=%.2f" % span)
	_check("S6④：束端恒 ≤beam_length<1280 逻辑像素（不穿屏）", span <= 560.5
		and end_pos.y >= -0.5 and end_pos.y <= 1280.5, "end=%s" % str(end_pos))
	wl.free()
	_teardown_world()


# ── S7 副束门（sub_beam 预算恒 1） ────────────────────────────────
func _test_s7_sub_beam_gate() -> void:
	print("── S7 副束门 ──")
	LaserBeam.scorch_pool_reset()
	_setup_world()
	# 主束 N=2（AFF_PIERCE）+ 棱镜副束（MEC_SPLIT_PRISM value1.45→1 副）：track 拓扑下
	# 副束锁 E2（主束目标 E1 互斥后的最近未锁定）——副束与主束同轴，E3 为「副束若吃
	# 穿透必被贯穿」的金丝雀
	var traits: Array[String] = ["res://resources/traits/AFF_PIERCE.tres",
		"res://resources/traits/MEC_SPLIT_PRISM.tres"]
	var w := _make_weapon(_make_weapon_data(1, {"refract_beams": 0, "beam_length": 560.0}))
	for path in traits:
		var td := _load_trait(path)
		_check("S7 前置：真卡挂载（%s）" % path, td != null and w.attach_trait(td))
	_check("S7 前置：_pierce_count()==2（L1+AFF_PIERCE 1.45→round 1）",
		w._pierce_count() == 2, str(w._pierce_count()))
	var e1 := _spawn_enemy(_make_enemy_data("E_S7A"), E1_POS)
	var e2 := _spawn_enemy(_make_enemy_data("E_S7B"), E2_POS)
	var e3 := _spawn_enemy(_make_enemy_data("E_S7C"), E3_POS)
	_check("S7 前置：try_fire 出主束+副束（棱镜 1 副）",
		w.try_fire() and w.active_beams.size() == 2,
		"beams=%d" % w.active_beams.size())
	var main: LaserBeam = w._main_beam
	var sub: LaserBeam = w._alive_sub_beams()[0]
	_check("S7①：副束 pierce==1（主束 _pierce_count()==2 不传导——_hit_budget 副束恒 1）",
		sub.pierce == 1 and main.pierce == 2,
		"sub=%d main=%d" % [sub.pierce, main.pierce])
	main.tick(0.26)
	sub.tick(0.26)
	_check("S7②：主束 N=2 结算 E1+E2（均 <1000）",
		(e1 as Enemy).hp < 999.999 and (e2 as Enemy).hp < 999.999,
		"e1=%s e2=%s" % [str((e1 as Enemy).hp), str((e2 as Enemy).hp)])
	_check("S7③：副束只结算锁定 1 目标——同轴 E3 金丝雀恒满血（副束不吃穿透）",
		_approx((e3 as Enemy).hp, 1000.0, 0.001), "e3=%s" % str((e3 as Enemy).hp))
	w.free()
	_teardown_world()


# ── S8 折射分叉数不随 N 增长 + 贯穿目标入排除集 ────────────────────
func _test_s8_refraction_forks() -> void:
	print("── S8 折射分叉门 ──")
	_setup_world()
	# 基线 N=1：E1 首触 → 1 条 depth1 子束（锁 E3=(300,560)，250px 内最近未命中）
	var wb := _make_weapon(_make_weapon_data(1, {"refract_beams": 1, "refract_ratio": 0.6,
		"refract_depth": 2, "beam_length": 560.0}))
	var b_e1 := _spawn_enemy(_make_enemy_data("E_S8A"), E1_POS)
	var b_e3 := _spawn_enemy(_make_enemy_data("E_S8B"), Vector2(300.0, 560.0))
	_check("S8 前置：try_fire 出主束", wb.try_fire()
		and wb.active_beams.size() == 1)
	(wb.active_beams[0] as LaserBeam).tick(DT)
	_check("S8①：基线 N=1 → 恰 1 条分叉（active_beams==2）",
		wb.active_beams.size() == 2, "beams=%d" % wb.active_beams.size())
	wb.free()
	_clear_enemies()
	# N=2：E1（首触分叉）+ E2（贯穿，不得触发第二分叉）+ E3（折射目标）
	var wp := _make_weapon(_make_weapon_data(1, {"refract_beams": 1, "refract_ratio": 0.6,
		"refract_depth": 2, "beam_length": 560.0}))
	wp.attach_trait(_load_trait("res://resources/traits/AFF_PIERCE.tres"))
	var p_e1 := _spawn_enemy(_make_enemy_data("E_S8C"), E1_POS)
	var p_e2 := _spawn_enemy(_make_enemy_data("E_S8D"), E2_POS)
	var p_e3 := _spawn_enemy(_make_enemy_data("E_S8E"), Vector2(300.0, 560.0))
	_check("S8 前置：主束 N==2", wp._pierce_count() == 2, str(wp._pierce_count()))
	wp.try_fire()
	var main: LaserBeam = wp.active_beams[0]
	main.tick(0.26)
	_check("S8②：N=2 分叉数与 N=1 基线相同（恰 1 条——贯穿目标不触发新分叉）",
		wp.active_beams.size() == 2, "beams=%d" % wp.active_beams.size())
	_check("S8③：贯穿目标 E1/E2 ∈ hit_exclusions()（防子束回烧）",
		main.hit_exclusions().has(int((p_e1 as Node2D).get("uid")))
		and main.hit_exclusions().has(int((p_e2 as Node2D).get("uid"))),
		str(main.hit_exclusions()))
	_check("S8④：分叉锁轴外折射目标 E3（250px 内最近未命中）",
		wp.active_beams.size() == 2
		and (wp.active_beams[1] as LaserBeam).target_uid == int((p_e3 as Node2D).get("uid")))
	_check("S8⑤：主束 N=2 照常贯穿结算 E2（<1000）",
		(p_e2 as Enemy).hp < 999.999, "e2=%s" % str((p_e2 as Enemy).hp))
	wp.free()
	_teardown_world()


# ── S9 契约（last_hit_uid / _pierce_count / 面板穿透行） ───────────
func _test_s9_contract() -> void:
	print("── S9 契约 ──")
	_setup_world()
	# last_hit_uid 仅随首目标写（N=2 多目标结算后仍==E1——R91 聚焦契约保留）
	var probe := _run_axis_probe(2, [], [E1_POS, E2_POS])
	var beam: LaserBeam = probe["beam"]
	var es: Array[Node2D] = probe["enemies"]
	_check("S9①：last_hit_uid==E1（首/最近目标——R91 主束锁定契约，多目标不漂移）",
		beam.last_hit_uid == int((es[0] as Node2D).get("uid")),
		"last=%d e1=%d" % [beam.last_hit_uid, int((es[0] as Node2D).get("uid"))])
	var w: LaserWeapon = probe["weapon"]
	_check("S9②：_pierce_count()==maxi(L表+round(add_pierce),0)（L表=2 空栈 → 2）",
		w._pierce_count() == maxi(int(w.get_stat(&"pierce"))
			+ int(round(float(w.trait_stack.aggregate_panel().get("add_pierce", 0.0)))), 0)
		and w._pierce_count() == 2, str(w._pierce_count()))
	w.free()
	_clear_enemies()
	# L 表基线（pierce=1）：空栈 → 恰 1（预算缺省=旧单目标口径，pkg3 零位移根）
	var w1 := _make_weapon(_make_weapon_data(1, {"refract_beams": 0, "beam_length": 560.0}))
	_check("S9②b：L表 pierce=1 空栈 → _pierce_count()==1（基线零位移）",
		w1._pierce_count() == 1, str(w1._pierce_count()))
	w1.free()
	_clear_enemies()
	# 挂 AFF_PIERCE（真实 .tres，required_forms [0,1] 激光可购直驱）→ N=2 > 基线
	var wp := _make_weapon(_make_weapon_data(1, {"refract_beams": 0, "beam_length": 560.0}))
	var aff := _load_trait("res://resources/traits/AFF_PIERCE.tres")
	_check("S9 前置：AFF_PIERCE 直载非空", aff != null)
	wp.attach_trait(aff)
	_check("S9③：挂 AFF_PIERCE → _pierce_count()==2（1+round(1.45)=1；面板 add_pierce）",
		wp._pierce_count() == 2
		and wp._pierce_count() == maxi(int(wp.get_stat(&"pierce"))
			+ int(round(float(wp.trait_stack.aggregate_panel().get("add_pierce", 0.0)))), 0),
		"n=%d add=%s" % [wp._pierce_count(),
			str(wp.trait_stack.aggregate_panel().get("add_pierce", 0.0))])
	# pause 面板穿透行：has_method("_pierce_count") 守卫自动转正（pause_overlay.gd:566）
	var overlay := PauseOverlay.new()
	tree.get_root().add_child(overlay)
	var line := String(overlay._weapon_stat_line(wp))
	_check("S9④：面板穿透行输出真值非 0（「穿透 2 名」——R195 面板恒 0→真值有意变更）",
		wp.has_method("_pierce_count") and line.contains("穿透 2 名"), line)
	overlay.free()
	wp.free()
	_teardown_world()


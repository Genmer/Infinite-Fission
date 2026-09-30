# tests/runner/w4_prism_cases.gd
# W4 激光组自测用例体（由 test_w4_prism.gd 入口在 autoload 就绪后运行时加载编译）。
# 覆盖（W4 五方向定案验收 1~5 + R183 折减 + 表现/接线项）：
#   A  真实 .tres 数据锚（base_atk 6/7/7/9/11、跳频=L 表 rof、死键删除、阈值替换）
#   1  默认单束（laser 段计数==1 / 锁定最近敌 / lifetime==0）
#   2  叠束硬帽（3×MEC_SPLIT_PRISM→4 段 / dmg_mult 0.6、L5 0.75 / 两两互斥 / 第 4 张拒）
#   3  聚焦归属（主束 6.7s ×2 / 副束恒 1.0 / PHASE_SYNC 3.35s 满 / AFF_CDR×4 保留 50%）
#   4  灼焦目标侧单池（双束曲线==单束 / 重叠回退 ×0.5 不叠灼焦）
#   5  预算与数值（池帽 12 峰值 / ≤30 跳/s / L5 满配 324.8±5 / R183 只主束+灰染）
#   +  拓扑三选一 / BEAM_LAG / TH_PRISM_CHOIR / SPECTRA 元素轮转 / 遗物乘区接线 /
#      池满副束拒绝计数（laser_subbeam_rejected）
# 确定性：seed(42) + 静止敌夹具（spd=0）+ 固定坐标；结算走包 2 透传桩（pkg3 同口径）；
#         场景切换处对旧敌置 dead（网格查询跳过——防同位 tie 污染最近敌判定）。
extends RefCounted

const LASER_SCENE := "res://scenes/combat/lasers/laser_beam.tscn"
const ENEMY_SCENE := "res://scenes/combat/enemies/enemy.tscn"
const W4_TRES := "res://resources/weapons/W4_pulse_beam.tres"
const DT := 1.0 / 120.0

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []

# 共享夹具（按组重建）
var _laser_pool: LaserBeamPool
var _enemy_pool: EnemyPool
var _grid: SpaceGrid                           # RefCounted（不入树、不 free——pkg3 同口径）
var _pipeline: DamagePipelineStub
var _alive_enemies: Array[Node2D] = []
var _wd_counter: int = 0
var _subbeam_events: Array = []               # laser_subbeam_spawned 事件记录（信号落位时）


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)                                       # 全局 RNG 固定种子（验收 1 口径）
	_ensure_autoloads()
	if EventBus.has_signal(&"laser_subbeam_spawned"):
		EventBus.connect(&"laser_subbeam_spawned", Callable(self, "_on_subbeam_spawned"))
	_test_w4_data_anchor()                         # A 真实 .tres 锚
	_setup_world()
	_test_default_single_beam()                    # 验收 1
	_teardown_world()
	_setup_world()
	_test_prism_stack_hardcap()                    # 验收 2
	_teardown_world()
	_setup_world()
	_test_overlap_fallback()                       # 验收 4b（×0.5 / 不叠灼焦）
	_teardown_world()
	_setup_world()
	_test_focus_ownership()                        # 验收 3
	_teardown_world()
	_setup_world()
	_test_scorch_single_pool()                     # 验收 4a（目标侧单池曲线）
	_teardown_world()
	_setup_world()
	_test_topology_fan_cofocus()                   # 拓扑三选一
	_teardown_world()
	_setup_world()
	_test_rhythm_traits()                          # BEAM_LAG / CHOIR / SPECTRA
	_teardown_world()
	_setup_world()
	_test_relic_inject()                           # 遗物乘区接线
	_teardown_world()
	_setup_world(12)
	_test_budget_and_rejection()                   # 验收 5a（池帽 12 + 拒绝计数）
	_teardown_world()
	_setup_world()
	_test_l5_full_dps()                            # 验收 5b（324.8±5）
	_teardown_world()
	_setup_world()
	_test_r183_copy()                              # 验收 5c（只主束 + 灰染 + 信号归属）
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


func _on_subbeam_spawned(p_owner_kind: int) -> void:
	_subbeam_events.append(int(p_owner_kind))


func _clear_enemies() -> void:
	# 场景切换清扫：旧敌移出网格并重建（dead 敌若占据 query_nearest 最近位，
	# acquire_target 会整体短路——R33 门失效根因，必须出网格而非仅置 dead）
	_alive_enemies.clear()
	if _grid != null:
		_grid.rebuild(_alive_enemies)


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


func _make_weapon_data(p_table: Dictionary = {}, p_segment: Dictionary = {},
		p_thresholds: Array = []) -> WeaponData:
	_wd_counter += 1
	var d := WeaponData.new()
	d.id = StringName("W4_TEST_%d" % _wd_counter)
	d.display_name = "W4 测试武器 %d" % _wd_counter
	d.form = GameConst.WeaponForm.LASER
	d.crit_rate = 0.0                             # 结算确定性（暴关闭）
	d.crit_dmg = 2.0
	d.hitbox_r = 6.0
	for i in range(5):
		var ls := WeaponLevelStats.new()
		ls.base_atk = float(p_table.get("base_atk", 10.0))
		ls.rof = float(p_table.get("rof", 8.0))
		ls.cd = float(p_table.get("cd", 0.5))
		ls.pierce = 1
		ls.pellets = 1
		d.upgrade_table.append(ls)
	d.laser = _merge_dict(d.laser, p_segment)
	for th in p_thresholds:
		d.threshold_traits.append(th)
	return d


func _make_trait_data(p_id: String, p_pool: int, p_pool_id: StringName,
		p_effect: StringName, p_value: float, p_stack_max: int = 1,
		p_params: Dictionary = {}) -> TraitData:
	var d := TraitData.new()
	d.id = StringName(p_id)
	d.display_name = p_id
	d.pool = p_pool
	d.pool_id = p_pool_id
	d.effect_id = p_effect
	d.value = p_value
	d.stack_max = p_stack_max
	d.decay_delta = 0.0
	d.proc_chance = 1.0
	d.inheritable = false
	for key in p_params:
		d.params[key] = p_params[key]
	return d


func _attach(p_w: LaserWeapon, p_trait: TraitData) -> bool:
	return p_w.trait_stack.attach(p_trait)


func _make_weapon(p_data: WeaponData, p_pos: Vector2) -> LaserWeapon:
	var w := LaserWeapon.new()
	w.name = "W4TestWeapon_%d" % _wd_counter
	tree.get_root().add_child(w)
	w.position = p_pos
	w.setup(p_data, null, {
		"pipeline": _pipeline,
		"projectile_pool": null,
		"enemy_grid": _grid,
		"laser_pool": _laser_pool,
		"elemental": null,
	})
	return w


func _make_enemy_data(p_id: String, p_hp: float = 100000.0) -> EnemyData:
	var d := EnemyData.new()
	d.id = StringName(p_id)
	d.display_name = p_id
	d.hp_base = p_hp
	d.spd_base = 0.0                               # 静止敌（几何确定性）
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


func _setup_world(p_laser_cap: int = 16) -> void:
	LaserBeam.scorch_pool_reset()                  # 目标侧单池隔离（静态态跨用例清池）
	_laser_pool = LaserBeamPool.new()
	_laser_pool.name = "W4LaserPool"
	tree.get_root().add_child(_laser_pool)
	_laser_pool.setup(&"w4_laser", load(LASER_SCENE), p_laser_cap)
	var ep := EnemyPool.new()
	ep.name = "W4EnemyPool"
	tree.get_root().add_child(ep)
	ep.setup(&"w4_enemy", load(ENEMY_SCENE), 64)
	_enemy_pool = ep
	_grid = SpaceGrid.new()
	_grid.configure(Vector2(720, 1280), 192.0)
	_pipeline = DamagePipelineStub.new()
	_alive_enemies.clear()
	_subbeam_events.clear()


func _teardown_world() -> void:
	_alive_enemies.clear()
	if _laser_pool != null:
		_laser_pool.free()
		_laser_pool = null
	if _enemy_pool != null:
		_enemy_pool.free()
		_enemy_pool = null
	_grid = null
	_pipeline = null


func _drive(p_w: WeaponBase, p_ticks: int) -> void:
	for i in range(p_ticks):
		GameConfig.frame_stamp += 1                # E-03 帧闸门推进（GameLoop 测试替身）
		p_w.tick(DT)


func _prism_enemies(p_origin: Vector2) -> Array[Enemy]:
	# 四目标夹具（主束最近 A；副束按距离序锁 D→B→C；两两互斥 + 射线无遮挡）
	var out: Array[Enemy] = []
	out.append(_spawn_enemy(_make_enemy_data("E_A"), p_origin + Vector2(160, 0)))    # d=160
	out.append(_spawn_enemy(_make_enemy_data("E_B"), p_origin + Vector2(0, -200)))   # d=200
	out.append(_spawn_enemy(_make_enemy_data("E_C"), p_origin + Vector2(150, 150)))  # d≈212
	out.append(_spawn_enemy(_make_enemy_data("E_D"), p_origin + Vector2(0, 190)))    # d=190
	return out


func _prism_trait() -> TraitData:
	# MEC_SPLIT_PRISM 合成定义（shared 词条上架前测试自洽；计数键语义不受 value 影响）
	return _make_trait_data("MEC_SPLIT_PRISM", GameConst.PoolClass.MECH, &"",
		&"EF_MECH", 1.0, 3)


func _alive_subs(p_w: LaserWeapon) -> Array[LaserBeam]:
	return p_w._alive_sub_beams()


# ── A. 真实 .tres 数据锚 ──────────────────────────────────────────
func _test_w4_data_anchor() -> void:
	print("── W4 .tres 数据锚 ──")
	var d: WeaponData = load(W4_TRES)
	_check("数据锚：真实 W4_pulse_beam.tres 可加载", d != null and d.id == &"W4_pulse_beam")
	var atk_expect: Array[float] = [6.0, 7.0, 7.0, 9.0, 11.0]
	var rof_expect: Array[float] = [8.0, 8.0, 9.0, 9.0, 9.0]
	var dps_expect: Array[float] = [48.0, 56.0, 63.0, 81.0, 99.0]
	var atk_ok := true
	var rof_ok := true
	var dps_ok := true
	for i in range(5):
		var ls: WeaponLevelStats = d.upgrade_table[i]
		atk_ok = atk_ok and _approx(ls.base_atk, atk_expect[i], 0.0001)
		rof_ok = rof_ok and _approx(ls.rof, rof_expect[i], 0.0001)
		dps_ok = dps_ok and _approx(ls.base_atk * ls.rof, dps_expect[i], 0.0001)
	_check("数据锚：base_atk 重定价 6/7/7/9/11（A3 tick_atk 锚兑现）", atk_ok)
	_check("数据锚：跳频=L 表 rof 8/8/9/9/9", rof_ok)
	_check("数据锚：主束 DPS 48/56/63/81/99", dps_ok)
	var laser: Dictionary = d.laser
	_check("数据锚：pulse_duration 死键删除（spawn lifetime 走缺省 0=常驻）",
		not laser.has("pulse_duration"))
	_check("数据锚：tick_rate 死键删除（跳频回退 L 表 rof 通道）", not laser.has("tick_rate"))
	_check("数据锚：折射死键退役（refract 三键不在 W4 段）",
		not laser.has("refract_beams") and not laser.has("refract_ratio")
			and not laser.has("refract_depth"))
	_check("数据锚：focus_ramp 保留（W4 聚焦专属）", bool(laser.get("focus_ramp", false)))
	var ratio_ok: bool = laser.get("sub_ratio_levels", []) is Array \
		and (laser["sub_ratio_levels"] as Array).size() == 5
	if ratio_ok:
		var ratios: Array = laser["sub_ratio_levels"]
		ratio_ok = _approx(float(ratios[0]), 0.6) and _approx(float(ratios[3]), 0.6) \
			and _approx(float(ratios[4]), 0.75)
	_check("数据锚：sub_ratio_levels=[0.6,0.6,0.6,0.6,0.75]（长度 5）", ratio_ok)
	var scorch_ok: bool = laser.get("scorch_max_layers_levels", []) is Array \
		and (laser["scorch_max_layers_levels"] as Array).size() == 5 \
		and int(laser["scorch_max_layers_levels"][4]) == 8
	_check("数据锚：scorch_max_layers_levels 末级 8（灼焦 ≤8 单池口径）", scorch_ok)
	# 阈值替换：删三条弹道死声明 → TH_PRISM_CHOIR + CRIT_SHARD 0.35
	var ids: Array[StringName] = []
	for th in d.threshold_traits:
		ids.append(StringName(str(th.get("threshold_id", ""))))
	_check("阈值：三条弹道死声明已删（SIZE_NOVA/FRACTAL_ECHO/BOUNCE_ETERNAL）",
		not ids.has(&"TH_SIZE_NOVA") and not ids.has(&"TH_FRACTAL_ECHO")
			and not ids.has(&"TH_BOUNCE_ETERNAL"))
	var choir: Dictionary = {}
	var shard: Dictionary = {}
	for th in d.threshold_traits:
		if StringName(str(th.get("threshold_id", ""))) == &"TH_PRISM_CHOIR":
			choir = th
		if StringName(str(th.get("threshold_id", ""))) == &"TH_CRIT_SHARD":
			shard = th
	var choir_params: Dictionary = choir.get("params", {})
	_check("阈值：TH_PRISM_CHOIR（sub_beam_count≥3 → EF_CHOIR tick_rate_bonus 2）",
		not choir.is_empty()
			and String(choir.get("metric", "")) == "sub_beam_count"
			and _approx(float(choir.get("threshold", 0.0)), 3.0, 0.0001)
			and StringName(str(choir.get("effect_id", ""))) == &"EF_CHOIR"
			and _approx(float(choir_params.get("tick_rate_bonus", 0.0)), 2.0, 0.0001))
	_check("阈值：TH_CRIT_SHARD 0.6→0.35",
		not shard.is_empty() and _approx(float(shard.get("threshold", 0.0)), 0.35, 0.0001))


# ── 1. 默认单束（验收 1） ─────────────────────────────────────────
func _test_default_single_beam() -> void:
	print("── 默认单束（验收 1） ──")
	var w := _make_weapon(load(W4_TRES), Vector2(100, 640))
	var e_near := _spawn_enemy(_make_enemy_data("E_NEAR"), Vector2(260, 640))      # 最近 160px
	_spawn_enemy(_make_enemy_data("E_FAR"), Vector2(400, 500))                     # 远端（离射线远）
	_check("默认单束：seed(42)+静止敌夹具 try_fire 成功", w.try_fire())
	_check("默认单束：laser 段计数==1（active_beams==1 且池 live==1）",
		w.active_beams.size() == 1 and int(_laser_pool.stats()["live"]) == 1)
	var beam := w.active_beams[0]
	_check("默认单束：lifetime==0（主束常驻化——pulse_duration 删除后缺省）", beam.lifetime == 0.0)
	_check("默认单束：depth=0 / dmg_mult=1 / 主束标识（非副束非折射）",
		beam.depth == 0 and _approx(beam.dmg_mult, 1.0)
			and (not beam.sub_beam) and (not beam.is_refraction))
	_check("默认单束：跳频 = L 表 rof 8（死键删除后回退通道）", _approx(beam.tick_rate, 8.0))
	_drive(w, 16)                                   # 0.133s ≥ 首跳间隔 0.125s → 恰 1 跳落 last_hit
	_check("默认单束：锁定最近敌（last_hit_uid==E_NEAR）", beam.last_hit_uid == e_near.uid,
		"last=%d near=%d" % [beam.last_hit_uid, e_near.uid])
	_check("默认单束：束归属字段 weapon_uid==武器 uid", beam.weapon_uid == w.uid)
	w.free()


# ── 2. 叠束硬帽（验收 2） ─────────────────────────────────────────
func _test_prism_stack_hardcap() -> void:
	print("── 叠束硬帽（验收 2） ──")
	var w := _make_weapon(_make_weapon_data({"base_atk": 10.0, "rof": 8.0}),
		Vector2(100, 640))
	var enemies := _prism_enemies(Vector2(100, 640))
	var main_uid: int = int(w.acquire_target().get("uid"))   # 主束目标=最近（副束排除锚）
	var prism := _prism_trait()
	_check("叠束：挂 3 张 MEC_SPLIT_PRISM 全成功（stack_max=3）",
		_attach(w, prism) and _attach(w, prism) and _attach(w, prism)
			and w._sub_beam_count() == 3)
	var rej0: int = DebugStats.get_counter(&"trait_attach_rejected_stack")
	var ok4: bool = _attach(w, prism)
	_check("叠束：第 4 张被拒且 DebugStack 计数 +1",
		(not ok4) and DebugStats.get_counter(&"trait_attach_rejected_stack") == rej0 + 1)
	_drive(w, 3)
	_check("叠束：段数==4（主束 1 + 副束 3）",
		w.active_beams.size() == 4 and int(_laser_pool.stats()["live"]) == 4)
	var subs := _alive_subs(w)
	_check("叠束：副束 dmg_mult == 主×0.6 ±1e-6（L1 sub_ratio）",
		subs.size() == 3
			and _approx(subs[0].dmg_mult, 0.6, 1e-6)
			and _approx(subs[1].dmg_mult, 0.6, 1e-6)
			and _approx(subs[2].dmg_mult, 0.6, 1e-6))
	_check("叠束：主束 dmg_mult==1（副束折价只作用于副束）",
		w._main_beam != null and _approx(w._main_beam.dmg_mult, 1.0, 1e-6))
	var uids: Array[int] = []
	for s in subs:
		uids.append(s.target_uid)
	var distinct := true
	for i in range(uids.size()):
		for j in range(i + 1, uids.size()):
			distinct = distinct and uids[i] != uids[j]
	var no_dup := true
	for u in uids:
		no_dup = no_dup and u > 0 and u != main_uid
	_check("叠束：目标两两互斥（3 副束 target_uid 互异、非空、不与主束同目标）",
		subs.size() == 3 and distinct and no_dup, "uids=%s" % str(uids))
	var sub_flag_ok := true
	for s in subs:
		sub_flag_ok = sub_flag_ok and s.sub_beam and s.focus_mult == 1.0 \
			and not s.overlap_fallback and not s.is_refraction
	_check("叠束：副束标识 sub_beam / focus_mult 恒 1.0 / 无回退 / 非折射", sub_flag_ok)
	_clear_enemies()                                # 场景切换：旧四目标出网格（防 tie）
	# L5 ×0.75 曲线
	var w5 := _make_weapon(_make_weapon_data({"base_atk": 11.0, "rof": 9.0},
		{"sub_ratio_levels": [0.6, 0.6, 0.6, 0.6, 0.75]}), Vector2(100, 640))
	w5.level = 5
	_prism_enemies(Vector2(100, 640))
	for i in range(3):
		_attach(w5, _prism_trait())
	_drive(w5, 3)
	var subs5 := _alive_subs(w5)
	var ratio_ok := subs5.size() == 3
	for s in subs5:
		ratio_ok = ratio_ok and _approx(s.dmg_mult, 0.75, 1e-6)
	_check("叠束：L5 副束 dmg_mult == 主×0.75 ±1e-6", ratio_ok)
	w5.free()


# ── 3. 聚焦归属（验收 3） ─────────────────────────────────────────
func _test_focus_ownership() -> void:
	print("── 聚焦归属（验收 3） ──")
	# 主束 6.7s 满 ×2 + 副束恒 1.0
	var seg := {"focus_ramp": true}
	var w := _make_weapon(_make_weapon_data({"base_atk": 10.0, "rof": 8.0}, seg),
		Vector2(100, 640))
	var e_fa := _spawn_enemy(_make_enemy_data("E_FA"), Vector2(100, 520))  # 主束正上 120px
	_spawn_enemy(_make_enemy_data("E_FB"), Vector2(100, 400))              # 延线上 240px
	_drive(w, 804)                                  # 6.7s @120Hz
	_check("聚焦：主束 6.7s focus_mult==2.0±0.05",
		_approx(w._main_beam.focus_mult, 2.0, 0.05),
		"mult=%f" % w._main_beam.focus_mult)
	for i in range(3):
		_attach(w, _prism_trait())
	_prism_enemies(Vector2(100, 640))               # 副束目标集（主束仍烧 E_FA=最近）
	_drive(w, 30)                                   # 0.25s：副束补位
	var subs := _alive_subs(w)
	_check("聚焦：副束补位 3 条且 focus_mult 恒 1.0（主束保持 ×2）",
		subs.size() == 3
			and subs.all(func(s): return s.focus_mult == 1.0)
			and _approx(w._main_beam.focus_mult, 2.0, 0.05))
	_clear_enemies()
	w.free()
	# PHASE_SYNC：3.35s 满（对照未挂载 3.35s 仅 ×1.5）
	var w2 := _make_weapon(_make_weapon_data({"base_atk": 10.0, "rof": 8.0}, seg),
		Vector2(100, 640))
	_attach(w2, _make_trait_data("MEC_PHASE_SYNC", GameConst.PoolClass.MECH, &"",
		&"EF_MECH", 1.0))
	for i in range(3):
		_attach(w2, _prism_trait())
	_prism_enemies(Vector2(100, 640))
	_drive(w2, 402)                                 # 3.35s @120Hz
	_check("聚焦：PHASE_SYNC 副束≥2 → 3.35s 爬满 ×2±0.05",
		_approx(w2._main_beam.focus_mult, 2.0, 0.05),
		"mult=%f" % w2._main_beam.focus_mult)
	_clear_enemies()
	w2.free()
	var w3 := _make_weapon(_make_weapon_data({"base_atk": 10.0, "rof": 8.0}, seg),
		Vector2(100, 640))
	_prism_enemies(Vector2(100, 640))               # 副束≥2 但无 PHASE_SYNC 对照
	for i in range(3):
		_attach(w3, _prism_trait())
	_drive(w3, 402)
	_check("聚焦：未挂 PHASE_SYNC 3.35s 仅 ×1.5（15%/s 基速对照）",
		_approx(w3._main_beam.focus_mult, 1.5, 0.05),
		"mult=%f" % w3._main_beam.focus_mult)
	_clear_enemies()
	w3.free()
	# AFF_CDR×4：换目标保留 50%±2%（计帧断言）
	var w4 := _make_weapon(_make_weapon_data({"base_atk": 10.0, "rof": 8.0}, seg),
		Vector2(100, 640))
	var cdr := _make_trait_data("AFF_CDR", GameConst.PoolClass.ADD, &"add_cdr",
		&"EF_STAT", 0.05, 4)
	for i in range(4):
		_attach(w4, cdr)
	var ka := _spawn_enemy(_make_enemy_data("E_CA"), Vector2(100, 440))
	_spawn_enemy(_make_enemy_data("E_CB"), Vector2(100, 300))
	_drive(w4, 490)                                 # 预热：越过首帧锁定损耗 → 同目标计满
	var pre: float = w4._focus_time
	_check("聚焦：AFF_CDR 预热 4s 同目标计时成立", pre > 3.9, "t=%f" % pre)
	ka.dead = true                                  # 换目标（延线敌 E_CB 接管）
	# 逐帧强推结算相位（_tick_left 清零 → 每帧恰 1 跳落 last_hit）→ 换锁帧确定
	var kept: float = -1.0
	for i in range(20):
		w4._main_beam._tick_left = 0.0
		_drive(w4, 1)
		if w4._focus_uid != ka.uid and w4._focus_uid > 0:
			kept = w4._focus_time                   # 换锁帧：保留 12.5%×4 层=50%
			break
	_check("聚焦：AFF_CDR×4 换目标保留 50%±2%（计帧断言）",
		pre > 3.9 and kept > 0.0 and _approx(kept / pre, 0.5, 0.02),
		"pre=%f kept=%f ratio=%f" % [pre, kept, kept / pre])
	_clear_enemies()
	w4.free()
	# 无 AFF_CDR：换目标归零（R91 既有契约不放宽）
	var w5 := _make_weapon(_make_weapon_data({"base_atk": 10.0, "rof": 8.0}, seg),
		Vector2(100, 640))
	var kb := _spawn_enemy(_make_enemy_data("E_DA"), Vector2(100, 440))
	_spawn_enemy(_make_enemy_data("E_DB"), Vector2(100, 300))
	_drive(w5, 490)
	var pre5: float = w5._focus_time
	kb.dead = true
	var zeroed := -1.0
	for i in range(20):
		w5._main_beam._tick_left = 0.0
		_drive(w5, 1)
		if w5._focus_uid != kb.uid and w5._focus_uid > 0:
			zeroed = w5._focus_time                 # 换锁帧：无 AFF_CDR → 归零
			break
	_check("聚焦：无 AFF_CDR 换目标归零重聚（既有口径）",
		pre5 > 3.9 and zeroed < 0.05, "pre=%f t=%f" % [pre5, zeroed])
	w5.free()


# ── 4a. 灼焦目标侧单池（验收 4） ──────────────────────────────────
func _test_scorch_single_pool() -> void:
	print("── 灼焦目标侧单池（验收 4） ──")
	var data := _make_weapon_data({"base_atk": 11.0, "rof": 8.0},
		{"scorch_max_layers_levels": [5.0, 5.0, 5.0, 5.0, 8.0]})
	# 单束对照：L5 cap 8，2s 层数曲线 [2,4,8]
	var w1 := _make_weapon(data, Vector2(100, 640))
	w1.level = 5
	var e1 := _spawn_enemy(_make_enemy_data("E_S1"), Vector2(300, 640))
	w1.try_fire()
	var b1 := w1.active_beams[0]
	var curve_single: Array[int] = []
	for i in range(20):
		GameConfig.frame_stamp += 1
		b1.tick(0.1)
		if i == 4 or i == 9 or i == 19:
			curve_single.append(LaserBeam.scorch_layers_of(e1.uid))
	_check("灼焦单池：单束 0.5/1.0/2.0s 层数曲线 [2,4,8]（≤8）",
		curve_single == ([2, 4, 8] as Array[int]),
		"curve=%s" % str(curve_single))
	w1.free()
	# 双束共照同目标：曲线与单束逐点一致（目标侧单池 = 单束口径，合并速率不翻倍）
	_clear_enemies()                                # 场景切换：单束对照敌出网格
	LaserBeam.scorch_pool_reset()
	var e2 := _spawn_enemy(_make_enemy_data("E_S2"), Vector2(300, 640))
	var w2a := _make_weapon(data, Vector2(100, 640))
	var w2b := _make_weapon(data, Vector2(100, 640))
	w2a.level = 5
	w2b.level = 5
	w2a.try_fire()
	w2b.try_fire()
	var b2a := w2a.active_beams[0]
	var b2b := w2b.active_beams[0]
	var curve_dual: Array[int] = []
	for i in range(20):
		GameConfig.frame_stamp += 1
		b2a.tick(0.1)
		b2b.tick(0.1)
		if i == 4 or i == 9 or i == 19:
			curve_dual.append(LaserBeam.scorch_layers_of(e2.uid))
	_check("灼焦单池：两束共照 2s 曲线==单束对照 [2,4,8]",
		curve_dual == curve_single, "curve=%s" % str(curve_dual))
	_check("灼焦单池：双束读数同源（束实例无私有层表）",
		b2a.get("scorch_layers") == null and b2b.get("scorch_layers") == null)
	# 死亡回收：存活目标条目保留、sweep 口可用
	LaserBeam.sweep_scorch_pool(_grid)
	_check("灼焦单池：sweep 后存活目标层数保留（回收口可用）",
		LaserBeam.scorch_layers_of(e2.uid) == 8)
	w2a.free()
	w2b.free()


# ── 4b. 重叠回退（验收 4） ────────────────────────────────────────
func _test_overlap_fallback() -> void:
	print("── 重叠回退 ×0.5 / 不叠灼焦 ──")
	var data := _make_weapon_data({"base_atk": 10.0, "rof": 8.0})
	var w := _make_weapon(data, Vector2(100, 640))
	var e := _spawn_enemy(_make_enemy_data("E_ONLY"), Vector2(300, 640))
	for i in range(3):
		_attach(w, _prism_trait())
	_drive(w, 5)
	var subs := _alive_subs(w)
	var merged := subs.size() == 3
	var fallback_ok := merged
	for s in subs:
		merged = merged and s.target_uid == e.uid
		fallback_ok = fallback_ok and _approx(s.dmg_mult, 0.5, 1e-6) and s.overlap_fallback
	_check("重叠回退：目标不足 → 3 副束全部并入主束目标", merged)
	_check("重叠回退：并入束 dmg_mult==0.5 ±1e-6 且 fallback 标识", fallback_ok)
	_clear_enemies()
	w.free()
	# 不叠灼焦：有回退副束 vs 纯主束 —— 同窗口层数一致
	var e_p := _spawn_enemy(_make_enemy_data("E_P"), Vector2(300, 640))
	var w_plain := _make_weapon(data, Vector2(100, 640))
	_drive(w_plain, 123)                            # 1.025s 纯主束（越过量化边界）
	var layers_plain := LaserBeam.scorch_layers_of(e_p.uid)
	w_plain.free()
	_clear_enemies()                                # 场景切换：纯主束对照敌出网格
	LaserBeam.scorch_pool_reset()
	var e_f := _spawn_enemy(_make_enemy_data("E_F"), Vector2(300, 640))
	var w_full := _make_weapon(data, Vector2(100, 640))
	for i in range(3):
		_attach(w_full, _prism_trait())
	_drive(w_full, 123)                            # 1.025s 主束 + 3 回退副束
	var layers_full := LaserBeam.scorch_layers_of(e_f.uid)
	_check("重叠回退：回退束不叠灼焦（层数==纯主束对照 4）",
		layers_plain == 4 and layers_full == layers_plain,
		"plain=%d full=%d" % [layers_plain, layers_full])
	w_full.free()


# ── 拓扑三选一 ───────────────────────────────────────────────────
func _test_topology_fan_cofocus() -> void:
	print("── 束间拓扑（laser_topology 三选一） ──")
	# FAN：固定角随主束朝向（反挂机——无目标常驻扫场不回收）
	var w := _make_weapon(_make_weapon_data({"base_atk": 10.0, "rof": 8.0}),
		Vector2(100, 640))
	_attach(w, _make_trait_data("MEC_BEAM_FAN", GameConst.PoolClass.MECH, &"",
		&"EF_MECH", 1.0))
	for i in range(2):
		_attach(w, _prism_trait())
	_spawn_enemy(_make_enemy_data("E_FAN"), Vector2(100, 440))   # 主束向上
	_drive(w, 5)
	var subs := _alive_subs(w)
	var fan_ok := subs.size() == 2
	if fan_ok:
		var up := Vector2.UP
		fan_ok = _approx(subs[0]._aim_dir.angle_to(up.rotated(deg_to_rad(-12.0))), 0.0, 0.01) \
			and _approx(subs[1]._aim_dir.angle_to(up.rotated(deg_to_rad(12.0))), 0.0, 0.01)
		var no_lock := true
		for s in subs:
			no_lock = no_lock and s.target_uid == 0
		fan_ok = fan_ok and no_lock
	_check("拓扑 FAN：2 副束固定角 ±12°（FAN_GAP 24° 对称）不索敌", fan_ok)
	var live_before := w.active_beams.size()
	_clear_enemies()                              # 全场无目标（反挂机窗口）
	_drive(w, 30)
	var all_live := w.active_beams.size() == live_before
	for b in w.active_beams:
		all_live = all_live and b.is_live()
	_check("拓扑 FAN：无目标常驻不回收（反挂机）", all_live)
	w.free()
	# COFOCUS：全束钉单体
	var w2 := _make_weapon(_make_weapon_data({"base_atk": 10.0, "rof": 8.0}),
		Vector2(100, 640))
	_attach(w2, _make_trait_data("MEC_BEAM_COFOCUS", GameConst.PoolClass.MECH, &"",
		&"EF_MECH", 1.0))
	for i in range(2):
		_attach(w2, _prism_trait())
	var e_c := _spawn_enemy(_make_enemy_data("E_CO"), Vector2(300, 640))   # 最近=主束靶
	_spawn_enemy(_make_enemy_data("E_CO2"), Vector2(100, 300))             # 场内次近
	_drive(w2, 25)                                   # 越过首跳间隔 → focus_uid 落定
	var subs2 := _alive_subs(w2)
	_check("拓扑 COFOCUS：全束钉单体（副束 target_uid==主束聚焦目标）",
		subs2.size() == 2
			and subs2.all(func(s): return s.target_uid == e_c.uid)
			and w2._focus_uid == e_c.uid)
	w2.free()
	# TRACK（缺省）互斥已在叠束用例覆盖；此处断言拓扑解析缺省值
	var w3 := _make_weapon(_make_weapon_data({"base_atk": 10.0, "rof": 8.0}),
		Vector2(100, 640))
	_attach(w3, _make_trait_data("MEC_BEAM_TRACK", GameConst.PoolClass.MECH, &"",
		&"EF_MECH", 1.0))
	_check("拓扑 TRACK：缺省拓扑解析为 track（独立寻的）",
		w3._beam_topology() == &"track")
	w3.free()


# ── 节奏词条（BEAM_LAG / CHOIR / SPECTRA） ────────────────────────
func _test_rhythm_traits() -> void:
	print("── 节奏词条（BEAM_LAG / TH_PRISM_CHOIR / SPECTRA） ──")
	# MEC_BEAM_LAG：每存活副束主束跳频 +0.5/s
	# R199 F02：消费端改读挂载 data.value×层数（旧 LAG_TICK_PER_SUB 常数不读值）——
	# 夹具 value 1.0→0.5 对齐 .tres 真源（MEC_BEAM_LAG.tres value=0.5），期望 10.5 不变
	var data := _make_weapon_data({"base_atk": 11.0, "rof": 9.0})
	var w := _make_weapon(data, Vector2(100, 640))
	_attach(w, _make_trait_data("MEC_BEAM_LAG", GameConst.PoolClass.MECH, &"",
		&"EF_MECH", 0.5))
	_prism_enemies(Vector2(100, 640))
	w.try_fire()
	_check("BEAM_LAG：无副束主束跳频==L 表 rof 9", _approx(w._main_beam.tick_rate, 9.0))
	for i in range(3):
		_attach(w, _prism_trait())
	_drive(w, 5)
	var subs := _alive_subs(w)
	_check("BEAM_LAG：3 存活副束 → 主束跳频 9+1.5=10.5（钳 [0.5,30]）",
		subs.size() == 3 and _approx(w._main_beam.tick_rate, 10.5, 0.0001),
		"rate=%f" % w._main_beam.tick_rate)
	_clear_enemies()
	w.free()
	# TH_PRISM_CHOIR：sub_beam_count≥3 → 副束跳频 +2/s（主束不受影响）
	var th_data := _make_weapon_data({"base_atk": 10.0, "rof": 8.0}, {}, [{
		"threshold_id": "TH_PRISM_CHOIR", "metric": "sub_beam_count", "threshold": 3.0,
		"effect_id": "EF_CHOIR", "params": {"tick_rate_bonus": 2.0},
	}])
	var w2 := _make_weapon(th_data, Vector2(100, 640))
	_prism_enemies(Vector2(100, 640))
	for i in range(3):
		_attach(w2, _prism_trait())
	_drive(w2, 5)
	var subs2 := _alive_subs(w2)
	var choir_ok := subs2.size() == 3 and _approx(w2._main_beam.tick_rate, 8.0, 0.0001)
	for s in subs2:
		choir_ok = choir_ok and _approx(s.tick_rate, 10.0, 0.0001)
	_check("TH_PRISM_CHOIR：3 副束跳频 8+2=10 / 主束保持 8", choir_ok)
	_clear_enemies()
	w2.free()
	# 2 副束（<3）不加成
	var w3 := _make_weapon(th_data, Vector2(100, 640))
	_prism_enemies(Vector2(100, 640))
	for i in range(2):
		_attach(w3, _prism_trait())
	_drive(w3, 5)
	var subs3 := _alive_subs(w3)
	var no_choir := subs3.size() == 2
	for s in subs3:
		no_choir = no_choir and _approx(s.tick_rate, 8.0, 0.0001)
	_check("TH_PRISM_CHOIR：2 副束（<3 阈值）跳频不加成", no_choir)
	_clear_enemies()
	w3.free()
	# MEC_BEAM_SPECTRA：副束按锁定次序轮转玩家元素池（删 KIN 硬编码）
	var seg := {"sub_ratio_levels": [0.6, 0.6, 0.6, 0.6, 0.75]}
	var w4 := _make_weapon(_make_weapon_data({"base_atk": 10.0, "rof": 8.0}, seg),
		Vector2(100, 640))
	var fir := _make_trait_data("ELE_IGNITE_T", GameConst.PoolClass.ELEM, &"",
		&"EF_ELEMENTAL", 1.0, 1, {"element": GameConst.Element.FIR})
	var ice := _make_trait_data("ELE_FREEZE_T", GameConst.PoolClass.ELEM, &"",
		&"EF_ELEMENTAL", 1.0, 1, {"element": GameConst.Element.ICE})
	_attach(w4, fir)
	_attach(w4, ice)
	_attach(w4, _make_trait_data("MEC_BEAM_SPECTRA", GameConst.PoolClass.MECH, &"",
		&"EF_MECH", 1.0))                        # 轮转开关卡（exclusive 通道本体）
	for i in range(3):
		_attach(w4, _prism_trait())
	_prism_enemies(Vector2(100, 640))
	_drive(w4, 5)
	var subs4 := _alive_subs(w4)
	var rot_ok := subs4.size() == 3
	if rot_ok:
		rot_ok = subs4[0].element == GameConst.Element.FIR \
			and subs4[1].element == GameConst.Element.ICE \
			and subs4[2].element == GameConst.Element.FIR
	_check("SPECTRA：副束按锁定次序轮转元素池 [FIR,ICE,FIR]",
		rot_ok, "n=%d elems=%s" % [subs4.size(),
			str(subs4.map(func(s): return s.element))])
	_check("SPECTRA：主束元素=附魔 dominant（ctx.element KIN 硬编码已删）",
		w4._main_beam.element == GameConst.Element.FIR)
	_clear_enemies()
	w4.free()
	# 未挂 SPECTRA：副束=主束附魔元素（对照）
	var w5 := _make_weapon(_make_weapon_data({"base_atk": 10.0, "rof": 8.0}, seg),
		Vector2(100, 640))
	_attach(w5, fir)
	_attach(w5, ice)
	for i in range(3):
		_attach(w5, _prism_trait())
	_prism_enemies(Vector2(100, 640))
	_drive(w5, 5)
	var spectra_off := _alive_subs(w5).size() == 3
	for s in _alive_subs(w5):
		spectra_off = spectra_off and s.element == GameConst.Element.FIR
	_check("SPECTRA：未挂载副束随主束附魔元素（不轮转）",
		spectra_off, "n=%d elems=%s" % [_alive_subs(w5).size(),
			str(_alive_subs(w5).map(func(s): return s.element))])
	w5.free()


# ── 遗物乘区接线 ─────────────────────────────────────────────────
func _test_relic_inject() -> void:
	print("── 遗物乘区接线（inject_relic_pools） ──")
	var data := _make_weapon_data({"base_atk": 10.0, "rof": 8.0})
	# 对照：无遗物一跳 10
	var w0 := _make_weapon(data, Vector2(100, 640))
	var e0 := _spawn_enemy(_make_enemy_data("E_R0"), Vector2(300, 640))
	w0.try_fire()
	w0.active_beams[0].tick(0.13)                   # ≥ 首跳间隔 0.125s → 恰 1 跳
	_check("遗物接线：无遗物一跳 10（对照）", _approx(e0.hp, 100000.0 - 10.0, 0.01),
		"hp=%s" % str(e0.hp))
	w0.free()
	_clear_enemies()                                # 场景切换：对照敌出网格（防 tie 短路）
	# 玻璃大炮遗物（REL_EF_GLASS 无条件注入 ×1.4）→ 一跳 14
	var handler := RelicHandler.new()
	var glass := RelicData.new()
	glass.id = &"R_W4TEST_GLASS"
	glass.effect_id = &"REL_EF_GLASS"
	glass.params = {"bonus": 0.4}
	handler.owned.append(glass)
	var w := _make_weapon(data, Vector2(100, 640))
	w.relic_handler = handler
	var e := _spawn_enemy(_make_enemy_data("E_R1"), Vector2(300, 640))
	w.try_fire()
	w.active_beams[0].tick(0.13)
	_check("遗物接线：激光跳伤路径消费 inject_relic_pools（一跳 10×1.4=14）",
		_approx(e.hp, 100000.0 - 14.0, 0.01), "hp=%s" % str(e.hp))
	w.free()
	handler.free()


# ── 预算与拒绝（验收 5a） ────────────────────────────────────────
func _test_budget_and_rejection() -> void:
	print("── 预算与池满拒绝（验收 5a：池帽 12） ──")
	var data := _make_weapon_data({"base_atk": 11.0, "rof": 9.0})
	_prism_enemies(Vector2(100, 640))
	var rej0: int = DebugStats.get_counter(&"laser_subbeam_rejected")
	# 满配三把 + 一把先出主束的凑位武器：需求 4×4=16 > 池帽 12 → 主束先占位、
	# 第 12 坑后被拒的是副束（laser_subbeam_rejected 消费点）
	var w_hold := _make_weapon(data, Vector2(100, 640))
	w_hold.try_fire()                                # 主束占 1 坑（无词条）
	var weapons: Array[LaserWeapon] = [w_hold]
	for i in range(3):
		var w := _make_weapon(data, Vector2(100, 640))
		for k in range(3):
			_attach(w, _prism_trait())
		weapons.append(w)
		_drive(w, 3)
	_check("预算：双激光满配全场段峰值 ≤12（池帽钳制 live==12）",
		int(_laser_pool.stats()["live"]) == 12,
		"live=%s" % str(_laser_pool.stats()["live"]))
	_drive(weapons[0], 117)                          # 累计 1.0s
	var settle_ok := true
	for w in weapons:
		for b in w.active_beams:
			settle_ok = settle_ok and b.settle_count <= 31   # ≤束数×30/s（钳 30 + 首跳容差）
	_check("预算：每束结算 ≤30 跳/s（tick_rate 钳制）", settle_ok)
	_check("预算：池满副束拒绝计数 laser_subbeam_rejected +1 以上",
		DebugStats.get_counter(&"laser_subbeam_rejected") > rej0,
		"rej=%d" % DebugStats.get_counter(&"laser_subbeam_rejected"))
	for w in weapons:
		w.free()


# ── L5 单体满配（验收 5b） ───────────────────────────────────────
func _test_l5_full_dps() -> void:
	print("── L5 单体满配 DPS（验收 5b） ──")
	var w := _make_weapon(_make_weapon_data({"base_atk": 11.0, "rof": 9.0},
		{"focus_ramp": true, "scorch_max_layers_levels": [5.0, 5.0, 5.0, 5.0, 8.0]}),
		Vector2(100, 640))
	w.level = 5
	var e := _spawn_enemy(_make_enemy_data("E_BOSS", 1000000000.0), Vector2(100, 440))
	_drive(w, 840)                                   # 7.0s：灼焦 2s 满 8 层 + 聚焦 6.7s 满 ×2
	_check("满配：聚焦 ×2 与灼焦 8 层同时在场",
		_approx(w._main_beam.focus_mult, 2.0, 0.01)
			and LaserBeam.scorch_layers_of(e.uid) == 8,
		"mult=%f layers=%d" % [w._main_beam.focus_mult, LaserBeam.scorch_layers_of(e.uid)])
	# 单跳足尺：消除节拍量化 → 恰 1 跳 = 11 × 2.0 × (1+8×0.08) = 36.08
	var b := w.active_beams[0]
	b._tick_left = 0.0
	var hp0: float = e.hp
	GameConfig.frame_stamp += 1
	b.tick(DT)
	var per_tick: float = hp0 - e.hp
	_check("满配：单跳伤害 36.08±0.5（tick_atk×聚焦×灼焦）",
		_approx(per_tick, 36.08, 0.5), "tick_dmg=%f" % per_tick)
	_check("满配：L5 单体满配 DPS 324.8±5（36.08 × 跳频 9）",
		_approx(w.active_beams[0].tick_rate, 9.0, 0.0001)
			and _approx(per_tick * 9.0, 324.72, 5.0),
		"dps=%f" % (per_tick * 9.0))
	w.free()


# ── R183 复制体（验收 5c） ───────────────────────────────────────
func _test_r183_copy() -> void:
	print("── R183 复制体折减（只主束 + 灰染） ──")
	var data := _make_weapon_data({"base_atk": 11.0, "rof": 9.0})
	_prism_enemies(Vector2(100, 640))
	# 源武器：3 副束满配
	var src := _make_weapon(data, Vector2(100, 640))
	for i in range(3):
		_attach(src, _prism_trait())
	_drive(src, 3)
	_check("R183：源武器满配 4 段（对照）",
		src.active_beams.size() == 4 and _alive_subs(src).size() == 3)
	# 复制体：同数据/同栈 copy_full；R183 接线口 sub_beams_override=0 + copy_tint
	#（player.gd _make_weapon_copy 消费约定，见 laser_weapon.gd 头注）
	var copy := _make_weapon(data, Vector2(100, 640))
	copy.level = src.level
	copy.trait_stack = src.trait_stack.copy_full()
	copy.sub_beams_override = 0                     # R183 复制体折减
	copy.copy_tint = true
	var copied_layers := 0                          # 复制体栈确含 3 层词条（copy_full 保真）
	for tb in copy.trait_stack.traits:
		if tb.data != null and tb.data.id == &"MEC_SPLIT_PRISM":
			copied_layers = tb.layers
	_check("R183：复制体词条栈==源栈层数（copy_full），但计数口被折减为 0",
		copied_layers == 3 and copy._sub_beam_count() == 0
			and copy.sub_beams_override == 0)
	_check("R183：复制体 try_fire 只出主束（并发束==1）", copy.try_fire())
	_drive(copy, 30)                                # 维持窗口：不回潮副束
	_check("R183：复制体并发束==1（维持期不回潮）",
		copy.active_beams.size() == 1 and _alive_subs(copy).is_empty())
	_check("R183：复制体主束灰染 flag（RARITY_NORMAL 灰蓝束）",
		copy.active_beams[0].gray_tint)
	var src_clean := not src._main_beam.gray_tint
	for s in _alive_subs(src):
		src_clean = src_clean and not s.gray_tint
	_check("R183：源武器束不灰染（对照）", src_clean)
	# laser_subbeam_spawned 归属字段断言（共享组 R187 落点：owner_kind 0=本体/1=复制体；
	# 复制体折减后恒不发——源武器 3 副束全为 BODY 归属）
	_check("R183/信号：laser_subbeam_spawned 已入 EventBus（共享组契约）",
		EventBus.has_signal(&"laser_subbeam_spawned"))
	var sig_ok := _subbeam_events.size() == 3
	for ev in _subbeam_events:
		sig_ok = sig_ok and int(ev) == GameConst.SUBBEAM_OWNER_BODY
	_check("R183/信号：源武器 3 条副束事件归属==SUBBEAM_OWNER_BODY（复制体零事件）",
		sig_ok, "events=%s" % str(_subbeam_events))
	src.free()
	copy.free()

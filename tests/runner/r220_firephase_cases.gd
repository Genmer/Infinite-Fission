# tests/runner/r220_firephase_cases.gd
# R220 火段数值包用例体（由 test_r220_firephase.gd 入口在 autoload 就绪后运行时加载）。
# 契约：docs/design/2026-10-03-R220-拆解契约.md §5.3（刀3②/5/6/7/10/12/13/14）。
# 段落：
#   ① 刀3②  weapon_base threshold_traits 预索引（get_threshold O(1) 与线性扫逐位等价）
#   ② 刀5   TraitStack 运行栈池化（借还/弃件/三失效面/运行位清零/_assert_clean/开关双态）
#   ③ 刀7   索敌单拍缓存（计数桩）/逐发元素分布统计等价/homing 前 K 选择（并列 tie-break）
#   ④ 刀13/14 数值锚（帧率优先 1.15/10.0/120/3.5+3.0/165 ↔ 特效优先 1.5/20.0/240/6.0+5.0/600）
#   ⑤ 刀6   镜/副/僚三组错帧相位（interval×(i/N)）+ 本体组波首同拍保持 + 确定性
#   ⑥ 刀12  帧率优先 32 发/物理步配额（顺延散开不丢不饿死）/特效优先无帽/队列帽丢弃
#   ⑦ 刀10  XpShard extends Node2D 磁吸/拾取/归池回归 + player._pickup_area 摘除
# 独立夹具段（①-④）照 pkg3_cases 先例自建池/网格/桩；GameLoop 段（⑤-⑦）照 w5_mirror
# 先例 boot main.tscn。PerfGovernor.mode_override 注入双态，用后复位 -1。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const BALLISTIC_SCENE := "res://scenes/combat/projectiles/ballistic_projectile.tscn"
const HOMING_SCENE := "res://scenes/combat/projectiles/homing_projectile.tscn"
const ENEMY_SCENE := "res://scenes/combat/enemies/enemy.tscn"
const DT := 1.0 / 60.0
const EPS := 0.0001

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null

# 独立夹具（pkg3 式）
var _proj_pool: ProjectilePool
var _homing_pool: ProjectilePool
var _enemy_pool: EnemyPool
var _grid: SpaceGrid
var _alive_enemies: Array[Node2D] = []
var _wd_counter: int = 0


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	PerfGovernor.mode_override = -1              # 保险复位（帧率优先=settings 缺省 0）
	TraitStack.POOLING_ENABLED = false           # 段隔离起步（产品默认修轮后=true；②段内显式双态）
	_setup_world()
	_test_1_threshold_index()                    # ① 刀3②
	_test_2_runtime_pool()                       # ② 刀5
	_test_7_target_cache_and_elements()          # ③ 刀7（缓存/元素分布）
	_test_3_homing_topk()                        # ③ 刀7（前 K 选择）
	_test_4_value_anchors()                      # ④ 刀13 数值锚（独立段）
	_teardown_world()
	_boot_game_loop()
	_test_5_stagger()                            # ⑤ 刀6（GameLoop：真注册表武器）
	_test_6_quota()                              # ⑥ 刀12（player 配额口）
	_test_4b_mirror_budget()                     # ④ 刀14（W5 真数据）
	_test_8_xp_shard_node2d()                    # ⑦ 刀10
	_teardown_game_loop()
	PerfGovernor.mode_override = -1
	TraitStack.POOLING_ENABLED = true            # 复位产品默认（R220 修轮开启）
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
		_failures.append("%s（%s）" % [p_name, p_detail])
		print("  FAIL | %s（%s）" % [p_name, p_detail])


func _approx(p_a: float, p_b: float, p_eps: float = EPS) -> bool:
	return absf(p_a - p_b) <= p_eps


# ══ 独立夹具装配（pkg3 先例） ═══════════════════════════════════════
func _setup_world() -> void:
	_proj_pool = ProjectilePool.new()
	_proj_pool.name = "R220ProjPool"
	tree.get_root().add_child(_proj_pool)
	_proj_pool.setup(&"r220_ballistic", load(BALLISTIC_SCENE), 64)
	_homing_pool = ProjectilePool.new()
	_homing_pool.name = "R220HomingPool"
	tree.get_root().add_child(_homing_pool)
	_homing_pool.setup(&"r220_homing", load(HOMING_SCENE), 32)
	var ep := EnemyPool.new()
	ep.name = "R220EnemyPool"
	tree.get_root().add_child(ep)
	ep.setup(&"r220_enemy", load(ENEMY_SCENE), 32)
	_enemy_pool = ep
	_grid = SpaceGrid.new()
	_grid.configure(Vector2(720, 1280), 192.0)


func _teardown_world() -> void:
	_release_all_enemies()
	if _proj_pool != null:
		_proj_pool.queue_free()
		_proj_pool = null
	if _homing_pool != null:
		_homing_pool.queue_free()
		_homing_pool = null
	if _enemy_pool != null:
		_enemy_pool.queue_free()
		_enemy_pool = null
	_grid = null


func _make_weapon_data(p_form: int, p_table: Dictionary = {}, p_segment: Dictionary = {},
		p_thresholds: Array = []) -> WeaponData:
	_wd_counter += 1
	var d := WeaponData.new()
	d.id = StringName("W_R220_%d" % _wd_counter)
	d.display_name = "R220 测试武器 %d" % _wd_counter
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
			for k in p_segment:
				d.ballistic[k] = p_segment[k]
		GameConst.WeaponForm.HOMING:
			for k in p_segment:
				d.homing[k] = p_segment[k]
	for th in p_thresholds:
		d.threshold_traits.append(th)
	return d


func _make_weapon(p_form: int, p_data: WeaponData, p_pos: Vector2) -> WeaponBase:
	var w: WeaponBase
	match p_form:
		GameConst.WeaponForm.BALLISTIC:
			w = BallisticWeapon.new()
		GameConst.WeaponForm.HOMING:
			w = HomingWeapon.new()
		_:
			w = LaserWeapon.new()
	w.name = "R220Weapon_%d" % _wd_counter
	tree.get_root().add_child(w)
	w.position = p_pos
	w.setup(p_data, null, {
		"pipeline": StubPipeline.new(),
		"projectile_pool": _proj_pool,
		"homing_pool": _homing_pool,
		"enemy_grid": _grid,
	})
	return w


func _make_trait_data(p_id: String, p_pool: int, p_pool_id: StringName, p_effect: StringName,
		p_value: float, p_hooks: Array = [], p_stack_max: int = 1) -> TraitData:
	var d := TraitData.new()
	d.id = StringName(p_id)
	d.display_name = p_id
	d.pool = p_pool
	d.pool_id = p_pool_id
	d.effect_id = p_effect
	d.value = p_value
	for h in p_hooks:
		d.event_hooks.append(int(h))
	d.stack_max = p_stack_max
	d.decay_delta = 0.0
	d.proc_chance = 1.0
	d.inheritable = false
	return d


func _make_enemy_data(p_id: StringName, p_hp: float = 100000.0) -> EnemyData:
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


func _spawn_enemy_at(p_pos: Vector2, p_id: StringName = &"E_R220") -> Enemy:
	var e := _enemy_pool.acquire() as Enemy
	e.spawn(_make_enemy_data(p_id), 1, 0)
	e._fade_left = 0.0
	e.modulate.a = 1.0
	e.position = p_pos
	_alive_enemies.append(e)
	_grid.rebuild(_alive_enemies)
	return e


func _release_all_enemies() -> void:
	for e in _alive_enemies:
		if e != null and is_instance_valid(e):
			_enemy_pool.release(e)
	_alive_enemies.clear()
	if _grid != null:
		_grid.rebuild([] as Array[Node2D])


func _live_bullets() -> int:
	return int(_proj_pool._live_order.size())


func _wipe_bullets() -> void:
	for node in _proj_pool._live_order.keys():
		(node as ProjectileBase).nullify()


# ══ ① 刀3②：threshold 预索引 ═════════════════════════════════════
func _test_1_threshold_index() -> void:
	print("── ① 刀3② threshold 预索引 ──")
	var thresholds := [
		{"threshold_id": &"TH_ALPHA", "metric": "bounce", "threshold": 12.0, "params": {"a": 1}},
		{"threshold_id": &"TH_BETA", "metric": "pellets", "threshold": 6.0},
		{"threshold_id": &"TH_GAMMA", "metric": "crit", "threshold": 0.35},
	]
	var w := _make_weapon(GameConst.WeaponForm.BALLISTIC,
		_make_weapon_data(GameConst.WeaponForm.BALLISTIC, {}, {}, thresholds),
		Vector2(360, 640)) as BallisticWeapon
	var linear_ok := true
	for tid in [&"TH_ALPHA", &"TH_BETA", &"TH_GAMMA"]:
		# 线性扫真源（data.threshold_traits 逐条比对）vs get_threshold 索引读
		var expect: Dictionary = {}
		for entry in w.data.threshold_traits:
			if StringName(str(entry.get("threshold_id", ""))) == tid:
				expect = entry
				break
		var got: Dictionary = w.get_threshold(tid)
		if got != expect or got.is_empty():
			linear_ok = false
	_check("①预索引三键与线性扫逐位等价（含 params 字典）", linear_ok)
	_check("①不存在键 → {}（O(1) miss）", w.get_threshold(&"TH_NOPE").is_empty())
	# 重复 id：首个优先（原线性扫返回首个匹配）
	var w2_data := _make_weapon_data(GameConst.WeaponForm.BALLISTIC, {}, {}, [
		{"threshold_id": &"TH_DUP", "threshold": 1.0},
		{"threshold_id": &"TH_DUP", "threshold": 2.0},
	])
	var w2 := _make_weapon(GameConst.WeaponForm.BALLISTIC, w2_data, Vector2(360, 640)) as BallisticWeapon
	_check("①重复 id 保留首个（原线性扫语义）",
		_approx(float(w2.get_threshold(&"TH_DUP").get("threshold", -1.0)), 1.0))
	# 空 threshold_traits 退化
	var w3 := _make_weapon(GameConst.WeaponForm.BALLISTIC,
		_make_weapon_data(GameConst.WeaponForm.BALLISTIC), Vector2(360, 640)) as BallisticWeapon
	_check("①空 threshold_traits 退化 → {}", w3.get_threshold(&"TH_ANY").is_empty())
	# 数据侧 mutate（size 变化）→ 防御重建生效
	w3.data.threshold_traits.append({"threshold_id": &"TH_LATE", "threshold": 9.0})
	_check("①数据 mutate 后 size 防御重建（追加即命中）",
		_approx(float(w3.get_threshold(&"TH_LATE").get("threshold", -1.0)), 9.0))
	w.free()
	w2.free()
	w3.free()


# ══ ② 刀5：运行栈池化 ═════════════════════════════════════════════
func _test_2_runtime_pool() -> void:
	print("── ② 刀5 运行栈池化 ──")
	var data := _make_weapon_data(GameConst.WeaponForm.BALLISTIC)
	var w := _make_weapon(GameConst.WeaponForm.BALLISTIC, data, Vector2(360, 640)) as BallisticWeapon
	var main: TraitStack = w.trait_stack
	w.attach_trait(_make_trait_data("R220_T1", GameConst.PoolClass.ADD, &"add_atk",
		&"EF_STAT", 0.2))

	# ── 开关关（产品默认）：每次 new 原路径 ──
	TraitStack.POOLING_ENABLED = false
	var rt_a := main.acquire_runtime()
	var rt_b := main.acquire_runtime()
	_check("②开关关=原路径：两次借出独立实例（每次 new）",
		rt_a != rt_b and rt_a != main and rt_b != main)
	rt_a.release_to_pool()
	rt_b.release_to_pool()
	var pool0: int = DebugStats.get_counter(&"trait_pool_discarded")

	# ── 开关开：借还复用 ──
	TraitStack.POOLING_ENABLED = true
	var rt1 := main.acquire_runtime()
	_check("②借出件=主栈定义克隆（词条数一致）", rt1.size() == main.size())
	# 运行位污染（模拟触发冷却）
	rt1.traits[0].cooldown_left = 0.37
	rt1.traits[0].frame_triggered = true
	var dirty0: int = DebugStats.get_counter(&"trait_pool_dirty")
	rt1.release_to_pool()
	_check("②归还后运行位清零 + _assert_clean 无污染计数",
		DebugStats.get_counter(&"trait_pool_dirty") == dirty0)
	var rt2 := main.acquire_runtime()
	_check("②借还复用同实例（池优先）", rt2 == rt1,
		"rt2==rt1：%s" % str(rt2 == rt1))
	_check("②复用件运行位已清（cooldown=0/frame_triggered=false）",
		_approx(rt2.traits[0].cooldown_left, 0.0) and not rt2.traits[0].frame_triggered)
	# 幂等：二次归还 no-op
	rt2.release_to_pool()
	rt2.release_to_pool()
	var rt3 := main.acquire_runtime()
	_check("②幂等：重复归还不重复入池（借出仍得一件）", rt3 != null)

	# ── 失效面①：选卡 attach_trait（挂新词条 → 世代 bump）──
	var rt_live := main.acquire_runtime()       # 存活「弹」持旧世代件（不还）
	w.attach_trait(_make_trait_data("R220_T2", GameConst.PoolClass.ADD, &"add_atk",
		&"EF_STAT", 0.3))                       # bump（清池）——rt_live 仍在「弹」上未还
	rt_live.release_to_pool()                   # bump 后晚归（世代陈旧件入池）
	var discard0: int = DebugStats.get_counter(&"trait_pool_discarded")
	var rt4 := main.acquire_runtime()
	_check("②失效面①（挂卡 attach）：晚归旧世代件弃件重建（trait_pool_discarded +1）",
		DebugStats.get_counter(&"trait_pool_discarded") == discard0 + 1
			and rt4 != rt_live and rt4.size() == main.size())
	_check("②失效面①：新件词条集=新主栈（含新挂词条）", rt4.size() == 2)

	# ── 失效面③：MULT/ELE 取优换定义（高品级覆盖 → bump）──
	var w3 := _make_weapon(GameConst.WeaponForm.BALLISTIC,
		_make_weapon_data(GameConst.WeaponForm.BALLISTIC), Vector2(360, 640)) as BallisticWeapon
	var m3: TraitStack = w3.trait_stack
	w3.attach_trait(_make_trait_data("R220_MULT", GameConst.PoolClass.MULT, &"m_test",
		&"EF_STAT", 1.0, [], 2))                # stack_max=2：第二张可挂（非 ADD 帽内叠层）
	var r3a := m3.acquire_runtime()
	r3a.release_to_pool()
	w3.attach_trait(_make_trait_data("R220_MULT", GameConst.PoolClass.MULT, &"m_test",
		&"EF_STAT", 2.0, [], 2))                # 同 id 高 value → 取优换定义（bump）
	var r3b := m3.acquire_runtime()
	_check("②失效面③（MULT 取优换定义）：新件 data.value==2.0（换定义生效）",
		_approx(float(r3b.traits[0].data.value), 2.0),
		"value=%.2f" % float(r3b.traits[0].data.value))

	# ── 首发弹面板=新值（三失效面行为锚：主栈变化后新弹带新栈）──
	var w5 := _make_weapon(GameConst.WeaponForm.BALLISTIC,
		_make_weapon_data(GameConst.WeaponForm.BALLISTIC, {"rof": 5.0},
			{"proj_speed": 600.0, "range": 600.0}), Vector2(360, 640)) as BallisticWeapon
	_spawn_enemy_at(Vector2(360, 500))
	w5.attach_trait(_make_trait_data("R220_P1", GameConst.PoolClass.ADD, &"add_crit",
		&"EF_STAT", 0.2))
	# 面 crit 初始 0.05 + add_crit 0.2 = 0.25 → 挂第二张后 0.45
	w5.try_fire()
	var snap1 := (w5.trait_stack.acquire_runtime())
	snap1.release_to_pool()
	# 直接读首发弹冻结面板
	var live_list: Array = _proj_pool._live_order.keys()
	var crit1 := float((live_list[0] as ProjectileBase).panel_snapshot.get("crit_rate", -1.0))
	_wipe_bullets()
	w5.attach_trait(_make_trait_data("R220_P2", GameConst.PoolClass.ADD, &"add_crit",
		&"EF_STAT", 0.2))                       # 失效面①（挂卡）
	w5.cooldown_left = 0.0
	w5.try_fire()
	live_list = _proj_pool._live_order.keys()
	var crit2 := float((live_list[0] as ProjectileBase).panel_snapshot.get("crit_rate", -1.0))
	_check("②首发弹面板=新值（挂卡后新弹 crit 0.2→0.4，夹具基率 0）",
		_approx(crit1, 0.2, 0.001) and _approx(crit2, 0.4, 0.001),
		"%.3f→%.3f" % [crit1, crit2])
	# 逐弹独立栈（E-13）：两弹栈实例互异
	var st1: TraitStack = (live_list[0] as ProjectileBase).trait_stack
	w5.cooldown_left = 0.0
	w5.try_fire()
	live_list = _proj_pool._live_order.keys()
	var st2: TraitStack = (live_list[live_list.size() - 1] as ProjectileBase).trait_stack
	_check("②逐弹独立栈实例（E-13 承重）", st1 != st2 and st1 != w5.trait_stack)
	_wipe_bullets()
	_release_all_enemies()
	w.free()
	w3.free()
	w5.free()
	TraitStack.POOLING_ENABLED = false


# ══ ③ 刀7（一）：索敌单拍缓存 + 逐发元素分布 ═══════════════════════
func _test_7_target_cache_and_elements() -> void:
	print("── ③ 刀7 索敌单拍缓存 / 逐发元素分布 ──")
	var counting := CountingGrid.new()
	counting.configure(Vector2(720, 1280), 192.0)
	var data := _make_weapon_data(GameConst.WeaponForm.BALLISTIC,
		{"rof": 5.0, "pellets": 1}, {"proj_speed": 600.0, "range": 600.0, "spread_deg": 0.0})
	var w := _make_weapon(GameConst.WeaponForm.BALLISTIC, data, Vector2(360, 640)) as BallisticWeapon
	w.enemy_grid = counting                     # 计数桩注入（覆写 query_nearest 计数）
	var e := Enemy.new()
	e.spawn(_make_enemy_data(&"E_CACHE"), 1, 0)
	e.position = Vector2(360, 500)
	_grid.rebuild([e])
	counting.rebuild([e])
	w.cooldown_left = 0.0
	counting.nearest_calls = 0
	w.tick(DT)                                   # 一拍：has_target_now + try_fire→aim
	_check("③单拍缓存：一拍 tick 全链 query_nearest 恰 1 次（原 2 次）",
		counting.nearest_calls == 1, "calls=%d" % counting.nearest_calls)
	# 直调 try_fire（tick 栈外）恒真查——语义保真
	w.cooldown_left = 0.0
	w.try_fire()
	_check("③栈外直调不共享缓存（直调路径语义保真）",
		counting.nearest_calls >= 2, "calls=%d" % counting.nearest_calls)
	_wipe_bullets()
	e.queue_free()

	# ── 逐发元素分布统计等价（三元素武器 360 发）──
	var welem := _make_weapon(GameConst.WeaponForm.BALLISTIC,
		_make_weapon_data(GameConst.WeaponForm.BALLISTIC, {"rof": 5.0, "pellets": 1},
			{"proj_speed": 600.0, "range": 600.0, "spread_deg": 0.0}),
		Vector2(360, 640)) as BallisticWeapon
	welem.attach_trait(_make_trait_data("R220_E1", GameConst.PoolClass.ELEM, &"e_fire",
		&"EF_ELEM_MARK", 1.0, [], 1))
	welem.trait_stack.traits[0].data.params["element"] = GameConst.Element.FIR
	welem.attach_trait(_make_trait_data("R220_E2", GameConst.PoolClass.ELEM, &"e_ice",
		&"EF_ELEM_MARK", 1.0, [], 1))
	welem.trait_stack.traits[1].data.params["element"] = GameConst.Element.ICE
	welem.attach_trait(_make_trait_data("R220_E3", GameConst.PoolClass.ELEM, &"e_ltg",
		&"EF_ELEM_MARK", 1.0, [], 1))
	welem.trait_stack.traits[2].data.params["element"] = GameConst.Element.LTG
	var ee := _spawn_enemy_at(Vector2(360, 500))
	var counts := {GameConst.Element.FIR: 0, GameConst.Element.ICE: 0, GameConst.Element.LTG: 0}
	var total := 360
	for i in range(total):
		welem.cooldown_left = 0.0
		welem.try_fire()
		var live: Array = _proj_pool._live_order.keys()
		var last := live[live.size() - 1] as ProjectileBase
		counts[int(last.element)] += 1
		last.nullify()                           # 池容量 64 << 360 样本——逐发回收防池满拒收污染统计
	# 三元素均匀 1/3：360 样本二项 σ≈9.2 → ±4σ≈37（分布等价 + 非退化双保险）
	var all_in_band := true
	for k in counts:
		if counts[k] < total / 3 - 40 or counts[k] > total / 3 + 40:
			all_in_band = false
	_check("③逐发元素分布等价（三元素各 ≈120±40，逐发 randi 留循环内）",
		all_in_band, "FIR=%d ICE=%d LTG=%d" % [counts[GameConst.Element.FIR],
			counts[GameConst.Element.ICE], counts[GameConst.Element.LTG]])
	welem.free()


# ══ ③ 刀7（二）：homing 前 K 选择 ═════════════════════════════════
func _test_3_homing_topk() -> void:
	print("── ③ 刀7 homing 前 K 选择 ──")
	var data := _make_weapon_data(GameConst.WeaponForm.HOMING,
		{"cd": 0.5}, {"proj_speed_init": 240.0, "volley_count_levels": [3.0, 3.0, 3.0, 3.0, 3.0]})
	var w := _make_weapon(GameConst.WeaponForm.HOMING, data, Vector2(360, 640)) as HomingWeapon
	w.enemy_grid = _grid
	_release_all_enemies()                          # 清上段残留敌（expect 真源仅本段 5 敌）
	# 5 敌距离递增（对称列错开避免并列）
	var positions := [Vector2(360, 540), Vector2(360, 460), Vector2(300, 700),
		Vector2(420, 800), Vector2(360, 900)]
	var enemies: Array[Node2D] = []
	for i in range(positions.size()):
		enemies.append(_spawn_enemy_at(positions[i], StringName("E_TOPK_%d" % i)))
	var got := w._acquire_volley_targets(3)
	# 旧式全量排序真源（sort_custom 距离升序取前 3 非 dead）
	var expect: Array[Node2D] = []
	var dup := enemies.duplicate()
	dup.sort_custom(func(a: Node2D, b: Node2D) -> bool:
		return a.global_position.distance_squared_to(w.muzzle_position()) \
			< b.global_position.distance_squared_to(w.muzzle_position()))
	for cand in dup:
		if expect.size() >= 3:
			break
		if cand != null and not bool(cand.get("dead")):
			expect.append(cand)
	var match_ok := got.size() == expect.size()
	for i in range(mini(got.size(), expect.size())):
		if got[i] != expect[i]:
			match_ok = false
	var dbg := "got=["
	for g in got:
		dbg += "%s," % str(g.get("uid"))
	dbg += "] expect=["
	for g in expect:
		dbg += "%s," % str(g.get("uid"))
	dbg += "]"
	_check("③前 K=3 与旧全量排序逐位一致（距离互异场景）", match_ok, dbg)
	# 并列 tie-break 确定性：同距两敌（对称位）→ 两次运行同选（uid 小者先）
	_release_all_enemies()
	var near_a := _spawn_enemy_at(Vector2(360, 500), &"E_TIE_A")
	var near_b := _spawn_enemy_at(Vector2(360, 780), &"E_TIE_B")   # 与 500 位同距（640 对称）
	var tie1 := w._acquire_volley_targets(2)
	var tie2 := w._acquire_volley_targets(2)
	_check("③并列确定性：同距两目标两次运行同选（uid tie-break）",
		tie1.size() == 2 and tie2.size() == 2 and tie1[0] == tie2[0] and tie1[1] == tie2[1],
		"t1=%s t2=%s" % [str(tie1.map(func(x): return x.get("uid"))),
			str(tie2.map(func(x): return x.get("uid")))])
	_release_all_enemies()
	w.free()


# ══ ④ 刀13 数值锚（独立段） ═══════════════════════════════════════
func _test_4_value_anchors() -> void:
	print("── ④ 刀13 数值锚（双态） ──")
	# ③ ETERNAL_QUOTA 读口
	PerfGovernor.mode_override = 0
	_check("④刀13③ 帧率优先 eternal_quota==120", BallisticWeapon.eternal_quota() == 120)
	PerfGovernor.mode_override = 1
	_check("④刀13③ 特效优先 eternal_quota==240（旧值）", BallisticWeapon.eternal_quota() == 240)
	PerfGovernor.mode_override = -1

	# ① lifetime 系数：range=600/speed=600 → 基数 1.0 × 系数
	var data := _make_weapon_data(GameConst.WeaponForm.BALLISTIC,
		{"rof": 5.0, "pellets": 1}, {"proj_speed": 600.0, "range": 600.0, "spread_deg": 0.0})
	var w := _make_weapon(GameConst.WeaponForm.BALLISTIC, data, Vector2(360, 640)) as BallisticWeapon
	_spawn_enemy_at(Vector2(360, 500))
	PerfGovernor.mode_override = 0
	w.try_fire()
	var life_fp := float((_proj_pool._live_order.keys()[0] as ProjectileBase).lifetime_left)
	_wipe_bullets()
	w.cooldown_left = 0.0
	PerfGovernor.mode_override = 1
	w.try_fire()
	var life_fx := float((_proj_pool._live_order.keys()[0] as ProjectileBase).lifetime_left)
	_wipe_bullets()
	w.cooldown_left = 0.0
	_check("④刀13① 帧率优先 lifetime 系数 1.15（600/600×1.15=1.15）",
		_approx(life_fp, 1.15, 0.001), "%.4f" % life_fp)
	_check("④刀13① 特效优先旧值 1.5（.tres 不改，代码分支）",
		_approx(life_fx, 1.5, 0.001), "%.4f" % life_fx)

	# ② MEC_BOUNCE 跳弹保底（ON_SPAWN：bounces>0 → lifetime floor）
	var bdata := _make_weapon_data(GameConst.WeaponForm.BALLISTIC,
		{"rof": 5.0, "pellets": 1}, {"proj_speed": 600.0, "range": 600.0, "spread_deg": 0.0})
	var wb := _make_weapon(GameConst.WeaponForm.BALLISTIC, bdata, Vector2(360, 640)) as BallisticWeapon
	wb.attach_trait(_make_trait_data("R220_BOUNCE", GameConst.PoolClass.MECH, &"mec_bounce",
		&"EF_BOUNCE", 2.0, [GameConst.TraitEvent.ON_SPAWN], 1))
	PerfGovernor.mode_override = 0
	wb.try_fire()
	var bl_fp := float((_proj_pool._live_order.keys()[0] as ProjectileBase).lifetime_left)
	_wipe_bullets()
	wb.cooldown_left = 0.0
	PerfGovernor.mode_override = 1
	wb.try_fire()
	var bl_fx := float((_proj_pool._live_order.keys()[0] as ProjectileBase).lifetime_left)
	_wipe_bullets()
	wb.cooldown_left = 0.0
	_check("④刀13② 帧率优先跳弹保底 10.0", _approx(bl_fp, 10.0, 0.001), "%.3f" % bl_fp)
	_check("④刀13② 特效优先旧值 20.0", _approx(bl_fx, 20.0, 0.001), "%.3f" % bl_fx)

	# ④ 自导寿命：主弹 3.5/6.0；子弹头 3.0/5.0
	var hdata := _make_weapon_data(GameConst.WeaponForm.HOMING,
		{"cd": 0.5}, {"proj_speed_init": 240.0, "volley_count": 1.0})
	var wh := _make_weapon(GameConst.WeaponForm.HOMING, hdata, Vector2(360, 640)) as HomingWeapon
	PerfGovernor.mode_override = 0
	wh.try_fire()
	var h_fp := float((_homing_pool._live_order.keys()[0] as ProjectileBase).lifetime_left)
	_wipe_homing()
	wh.cooldown_left = 0.0
	wh.sub_warheads_left = 1
	wh._launch_sub_warheads(Vector2(360, 600))
	var s_fp := float((_homing_pool._live_order.keys()[0] as ProjectileBase).lifetime_left)
	_wipe_homing()
	wh.cooldown_left = 0.0
	PerfGovernor.mode_override = 1
	wh.try_fire()
	var h_fx := float((_homing_pool._live_order.keys()[0] as ProjectileBase).lifetime_left)
	_wipe_homing()
	wh.cooldown_left = 0.0
	wh.sub_warheads_left = 1
	wh._launch_sub_warheads(Vector2(360, 600))
	var s_fx := float((_homing_pool._live_order.keys()[0] as ProjectileBase).lifetime_left)
	_wipe_homing()
	wh.cooldown_left = 0.0
	_check("④刀13④ 帧率优先自导主弹 3.5 / 子弹头 3.0",
		_approx(h_fp, 3.5, 0.001) and _approx(s_fp, 3.0, 0.001),
		"主 %.2f 子 %.2f" % [h_fp, s_fp])
	_check("④刀13④ 特效优先旧值 6.0 / 5.0",
		_approx(h_fx, 6.0, 0.001) and _approx(s_fx, 5.0, 0.001),
		"主 %.2f 子 %.2f" % [h_fx, s_fx])
	PerfGovernor.mode_override = -1
	_release_all_enemies()
	w.free()
	wb.free()
	wh.free()


func _wipe_homing() -> void:
	for node in _homing_pool._live_order.keys():
		(node as ProjectileBase).nullify()


# ══ ⑤ 刀6：三组错帧相位 ═══════════════════════════════════════════
func _boot_game_loop() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "GameLoopR220"
	tree.get_root().add_child(_gl)
	_gl.state = GameConst.GameStatus.MENU
	_gl.current_map_id = &"world_grove"
	_gl.start_run()
	_gl.player.set("max_hp", 1000000.0)
	_gl.player.set("hp", 1000000.0)
	_gl.player.unlocked_slots = 6
	_gl.state = GameConst.GameStatus.MENU


func _teardown_game_loop() -> void:
	tree.paused = false
	PerfGovernor.mode_override = -1
	RunSave.clear()
	if _gl != null:
		_gl.free()
		_gl = null


func _gl_fixtures(p_positions: Array[Vector2]) -> Array[Node2D]:
	var out: Array[Node2D] = []
	for pos in p_positions:
		var enemy := (_gl.pools[&"enemy"] as EnemyPool).acquire()
		enemy.spawn(_gl_fixture_enemy(&"E_R220_FIX"), 1, 0)
		enemy.position = pos
		out.append(enemy)
	_gl.enemy_grid.rebuild(out)
	return out


func _gl_fixture_enemy(p_id: StringName) -> EnemyData:
	var d := EnemyData.new()
	d.id = p_id
	d.display_name = String(p_id)
	d.hp_base = 1000000.0
	d.spd_base = 0.0
	d.dmg_base = 0.0
	d.exp_base = 1.0
	d.hitbox_r = 14.0
	d.resist = [0.0, 0.0, 0.0, 0.0]
	return d


func _gl_release(p_enemies: Array[Node2D]) -> void:
	for e in p_enemies:
		if e != null and is_instance_valid(e):
			(_gl.pools[&"enemy"] as EnemyPool).release(e)
	_gl.enemy_grid.rebuild([] as Array[Node2D])


func _gl_drive(p_frames: int, p_dt: float = DT) -> void:
	for i in range(p_frames):
		GameConfig.advance_frame()
		_gl.player.call(&"tick", p_dt, Vector2.ZERO)


func _gl_wipe_weapons() -> void:
	_gl.player.clear_mirrors()
	# ⑤段诺亚召唤的副本武器/护航舰也射弹（live=34 的 +2 来源）——统一走产品收口
	if _gl.player.has_method(&"_summon_restore"):
		_gl.player.call(&"_summon_restore")
	var slots: Array = _gl.player.get("weapon_slots")
	for i in range(slots.size()):
		var wv: Variant = slots[i]
		if wv != null and is_instance_valid(wv):
			slots[i] = null
			(wv as Node).queue_free()
	_gl.player.unlocked_slots = 6


func _test_5_stagger() -> void:
	print("── ⑤ 刀6 三组错帧相位 ──")
	PerfGovernor.mode_override = 1               # 错帧两模式都生效（工程刀——决策#8）
	var fixtures := _gl_fixtures([Vector2(360, 500)])

	# ── 副本组 + 僚机组（诺亚技能召唤）──
	_gl.player.set("character_id", &"noah")
	_gl.player.set("skill_cd_left", 0.0)
	var src := _gl.player.add_weapon(_gl.registry.get_weapon(&"W1_pistol"))
	_gl.player.activate_skill()
	var copies: Array = _gl.player.get("_summon_copies")
	var drones: Array = _gl.player.get("_summon_drones")
	var ok_phase := copies.size() == 2 and drones.size() == 2
	if ok_phase:
		var interval: float = (copies[0] as WeaponBase)._fire_interval()
		ok_phase = _approx((copies[0] as WeaponBase).cooldown_left, 0.0) \
			and _approx((copies[1] as WeaponBase).cooldown_left, interval * 0.5, 0.0001)
	_check("⑤副本组相位：copy[0]=同拍（0）/ copy[1]=interval×(1/2)",
		ok_phase, "copies=%d" % copies.size())
	var drone_ok := drones.size() == 2 \
		and _approx(float(drones[0].get("_fire_left")), 0.0) \
		and _approx(float(drones[1].get("_fire_left")), 0.55 * 0.5, 0.0001)
	_check("⑤僚机组相位：drone[0]=同拍 / drone[1]=0.55×(1/2)", drone_ok,
		"drones=%d" % drones.size())
	# 相位确定性：重召唤同构 → 同相位
	_gl.player.set("_summon_left", 0.0)
	_gl.player.call("_summon_restore")
	_gl.player.set("skill_cd_left", 0.0)
	_gl.player.activate_skill()
	var copies2: Array = _gl.player.get("_summon_copies")
	var det_ok := copies2.size() == 2 and copies.size() == 2
	if det_ok:
		det_ok = _approx((copies2[1] as WeaponBase).cooldown_left,
			(copies[1] as WeaponBase).cooldown_left, 0.0001)
	_check("⑤相位确定性：同构重召唤推导一致", det_ok)
	_gl.player.set("_summon_left", 0.0)
	_gl.player.call("_summon_restore")

	# ── 镜组（W5 棱镜 L5 → 3 镜）──
	_gl_wipe_weapons()
	var w1 := _gl.player.add_weapon(_gl.registry.get_weapon(&"W1_pistol"))
	var prism := MirrorWeapon.new()
	prism.setup(_gl.registry.get_weapon(&"W5_prism"), _gl.player, _gl.player.get("_deps"))
	if not _gl.player.equip_weapon(prism):
		prism.free()
		prism = null
	if prism != null:
		prism.level = 5                          # mirrors_count_levels L5=3
		prism.sync_mirrors(true)
	var mirrors: Array = prism.mirrors if prism != null else []
	var mirror_ok := mirrors.size() == 3
	if mirror_ok:
		var n := mirrors.size()
		for i in range(n):
			var expect_phase: float = mirrors[i]._fire_interval() * (float(i) / float(n)) \
				if i > 0 else 0.0
			if not _approx(mirrors[i].cooldown_left, expect_phase, 0.0001):
				mirror_ok = false
	_check("⑤镜组相位：mirror[i].cooldown_left == interval×(i/N)（N=3）", mirror_ok,
		"mirrors=%d" % mirrors.size())
	# 确定性：全清重建同相位
	var phases1: Array[float] = []
	for m in mirrors:
		phases1.append(m.cooldown_left)
	var n1: int = mirrors.size()                    # Array 引用语义：clear 后 mirrors 亦空
	_gl.player.clear_mirrors()
	prism.mirrors.clear()
	prism.sync_mirrors(true)
	var mirrors2: Array = prism.mirrors
	var det2 := mirrors2.size() == n1
	var dbg2 := "p1=["
	for p in phases1:
		dbg2 += "%.4f," % p
	dbg2 += "] p2=["
	for m in mirrors2:
		dbg2 += "%.4f," % m.cooldown_left
	dbg2 += "] n=%d" % mirrors2.size()
	for i in range(mini(mirrors2.size(), phases1.size())):
		if not _approx(mirrors2[i].cooldown_left, phases1[i], 0.0001):
			det2 = false
	_check("⑤镜组相位确定性：重建同相位（deterministic_source_pick 同构）", det2, dbg2)

	# ── 本体组波首同拍保持 ──
	_gl_wipe_weapons()
	var body_a := _gl.player.add_weapon(_gl.registry.get_weapon(&"W1_pistol"))
	var body_b := _gl.player.add_weapon(_gl.registry.get_weapon(&"W2_gatling"))
	body_a.cooldown_left = 0.0
	body_b.cooldown_left = 0.0
	_gl_drive(1)                                 # 一拍 tick：双武器冷却 0 + 敌在 → 同帧齐射
	var same_beat: bool = (body_a as WeaponBase).cooldown_left > 0.0 \
		and (body_b as WeaponBase).cooldown_left > 0.0    # 开火后 cooldown 置节拍间隔
	_check("⑤本体组波首同拍保持（双武器同帧首射——折中方案）", same_beat,
		"a=%.3f b=%.3f" % [(body_a as WeaponBase).cooldown_left,
			(body_b as WeaponBase).cooldown_left])
	_gl_wipe_weapons()
	_gl_release(fixtures)
	PerfGovernor.mode_override = -1


# ══ ⑥ 刀12：弹生成配额 ════════════════════════════════════════════
func _test_6_quota() -> void:
	print("── ⑥ 刀12 弹生成配额（双态） ──")
	_gl_wipe_weapons()                           # 清初始手枪等默认武器（配额计数纯净）
	_gl_clear_player_bullets()                   # ⑤段本体组波首的残留弹（live 基线归零）
	var fixtures := _gl_fixtures([Vector2(360, 500)])
	# 3 把 16 丸霰弹（夹具，rof=5 → 节拍 0.2s=12 帧）→ 每拍请求 48 发
	var shot_data := _make_weapon_data(GameConst.WeaponForm.BALLISTIC,
		{"rof": 5.0, "pellets": 16}, {"proj_speed": 600.0, "range": 600.0,
		"spread_deg": 13.0})
	var guns: Array[BallisticWeapon] = []
	for i in range(3):
		var g := BallisticWeapon.new()
		g.name = "R220QuotaGun%d" % i
		_gl.player.add_child(g)
		g.position = Vector2(360, 900)
		g.setup(shot_data, _gl.player, _gl.player.get("_deps"))
		if not _gl.player.equip_weapon(g):
			g.free()
		else:
			guns.append(g)
	_check("⑥前置：3 把 16 丸武器入槽", guns.size() == 3)

	# ── A 帧率优先：单步 48 发 → 32 放行 16 顺延 ──
	PerfGovernor.mode_override = 0
	var def0: int = DebugStats.get_counter(&"quota_deferred")
	var drop0: int = DebugStats.get_counter(&"quota_dropped")
	_gl_drive(1)
	var live_after_1 := _gl_live_player_bullets()
	_check("⑥A 帧率优先：单步 48 发 → 在场 32（配额帽咬合）",
		live_after_1 == 32, "live=%d" % live_after_1)
	_check("⑥A 超配 16 发顺延记账（quota_deferred +16）",
		DebugStats.get_counter(&"quota_deferred") - def0 == 16,
		"deferred=%d" % (DebugStats.get_counter(&"quota_deferred") - def0))
	_check("⑥A 顺延非丢弃（quota_dropped 零增长）",
		DebugStats.get_counter(&"quota_dropped") == drop0)

	# ── B 散开：顺延 16 对半拆两帧到期（def_a/def_b），帧2 只并入一半 ──
	# 节拍现实：帧1 w3 放行 0 未开火 → 冷却未走，帧2 到期重试（due 8+新 16 全放）；
	# 帧3 起 def_b 转入 pending 等下一节拍。断「顺延账减半」而非「下帧全补对齐」。
	_gl_drive(1)
	var acct2: int = int(guns[2].get("_quota_pending")) + int(guns[2].get("_quota_def_a")) \
		+ int(guns[2].get("_quota_def_b"))
	_gl_drive(1)
	var acct3: int = int(guns[2].get("_quota_pending")) + int(guns[2].get("_quota_def_a")) \
		+ int(guns[2].get("_quota_def_b"))
	_check("⑥B 散开：帧2 顺延账 16→8（对半拆分非同帧全补）",
		acct2 == 8 and acct3 == 8, "acct2=%d acct3=%d" % [acct2, acct3])

	# ── C 硬帽恒守 + 不饿死：满载持续驱动，单步生成恒 ≤32、pending 有界 ──
	var live_prev := _gl_live_player_bullets()
	var cap_ok := true
	var fired_any := false
	for i in range(120):
		_gl_drive(1)
		var now := _gl_live_player_bullets()
		if now - live_prev > 32:
			cap_ok = false
		live_prev = now
		if guns[2]._since_fire <= DT:
			fired_any = true
	var pend_max := 0
	for g in guns:
		pend_max = maxi(pend_max, int(g.get("_quota_pending")) + int(g.get("_quota_def_a")) \
			+ int(g.get("_quota_def_b")))
	_check("⑥C 满载硬帽：120 帧单步生成恒 ≤32（新丸+补发合计）", cap_ok)
	_check("⑥C 不饿死：满载下队尾武器保持开火节拍 + 顺延账有界（≤96）",
		fired_any and pend_max <= 96, "pend_max=%d" % pend_max)

	# ── D 守恒（有限需求）：单枪注入 pending=24 → 三拍后全部落地（顺延非丢弃）──
	_gl_clear_player_bullets()
	for g in guns:
		g.queue_free()
		var idx: int = (_gl.player.weapon_slots as Array).find(g)
		if idx >= 0:
			(_gl.player.weapon_slots as Array)[idx] = null
	var single_data := _make_weapon_data(GameConst.WeaponForm.BALLISTIC,
		{"rof": 5.0, "pellets": 16}, {"proj_speed": 600.0, "range": 600.0, "spread_deg": 13.0})
	var gun := BallisticWeapon.new()
	gun.name = "R220QuotaSingle"
	_gl.player.add_child(gun)
	gun.position = Vector2(360, 900)
	gun.setup(single_data, _gl.player, _gl.player.get("_deps"))
	_gl.player.equip_weapon(gun)
	gun.set("_quota_pending", 24)                # 注入历史顺延账（模拟上轮超配遗留）
	var spawned := 0
	var live_p := _gl_live_player_bullets()
	for i in range(40):                          # >3 拍（12 帧/拍）
		_gl_drive(1)
		var now := _gl_live_player_bullets()
		spawned += maxi(now - live_p, 0)
		live_p = now
	# 注入 24 + 三拍新丸 16×3 = 72 全部落地（第一拍帽 32 顺 8、第二拍 due8+新16 全放、
	# 第三拍起 16 全放——总量守恒零丢弃）
	_check("⑥D 守恒：注入 24+新 48 = 72 全落地（顺延非丢弃，dropped 零增长）",
		spawned == 72 and DebugStats.get_counter(&"quota_dropped") == drop0,
		"spawned=%d" % spawned)

	# ── E 特效优先：无配额 ──
	_gl_clear_player_bullets()
	for g2 in [gun]:
		g2.cooldown_left = 0.0
	PerfGovernor.mode_override = 1
	var def1: int = DebugStats.get_counter(&"quota_deferred")
	_gl_drive(1)
	_check("⑥E 特效优先：零顺延（mode_override=1 无帽）",
		DebugStats.get_counter(&"quota_deferred") == def1
			and _gl_live_player_bullets() == 16,
		"live=%d" % _gl_live_player_bullets())

	# ── F 队列帽溢出丢弃（quota_dropped）──
	_gl_clear_player_bullets()
	PerfGovernor.mode_override = 0
	var drop1: int = DebugStats.get_counter(&"quota_dropped")
	_gl.player.set("_quota_queue_size", _gl.player.QUOTA_QUEUE_CAP)   # 预占满队列
	gun.cooldown_left = 0.0
	gun.set("_quota_pending", 64)                # 大额到期+新丸 → 顺延溢出帽
	_gl_drive(1)
	_check("⑥F 队列帽溢出丢弃（quota_dropped 计数 >0）",
		DebugStats.get_counter(&"quota_dropped") > drop1,
		"drop=%d" % (DebugStats.get_counter(&"quota_dropped") - drop1))
	_gl.player.set("_quota_queue_size", 0)

	gun.queue_free()
	var idx2: int = (_gl.player.weapon_slots as Array).find(gun)
	if idx2 >= 0:
		(_gl.player.weapon_slots as Array)[idx2] = null
	_gl_release(fixtures)
	PerfGovernor.mode_override = -1


func _gl_live_player_bullets() -> int:
	var pool: ProjectilePool = _gl.pools[&"projectile"]
	var n := 0
	for node in pool._live_order.keys():
		if (node as ProjectileBase).team == 0:
			n += 1
	return n


func _gl_clear_player_bullets() -> void:
	var pool: ProjectilePool = _gl.pools[&"projectile"]
	for node in pool._live_order.keys():
		if (node as ProjectileBase).team == 0:
			(node as ProjectileBase).nullify()


# ══ ④ 刀14：镜面预算（W5 真数据） ═════════════════════════════════
func _test_4b_mirror_budget() -> void:
	print("── ④ 刀14 镜面发射预算 ──")
	var fixtures := _gl_fixtures([Vector2(360, 500)])
	var w1 := _gl.player.add_weapon(_gl.registry.get_weapon(&"W1_pistol"))
	var prism := MirrorWeapon.new()
	prism.setup(_gl.registry.get_weapon(&"W5_prism"), _gl.player, _gl.player.get("_deps"))
	if not _gl.player.equip_weapon(prism):
		prism.free()
		prism = null
	_check("④刀14 前置：棱镜入槽", prism != null)
	if prism != null:
		PerfGovernor.mode_override = 0
		_check("④刀14 帧率优先 budget_per_s==165（代码 override，.tres 不改）",
			_approx(prism.budget_per_s(), 165.0, 0.001))
		PerfGovernor.mode_override = 1
		_check("④刀14 特效优先 budget_per_s==600（.tres 原值）",
			_approx(prism.budget_per_s(), 600.0, 0.001))
		_check("④刀14 MIRROR_CAP==5 / BUDGET_WINDOW_S==1.0 不动",
			prism.MIRROR_CAP == 5 and _approx(prism.BUDGET_WINDOW_S, 1.0))
		# 帧率优先预算咬合：灌满 165 → 镜面拍静默跳过 + mirror_budget_skipped 可观测
		PerfGovernor.mode_override = 0
		prism.budget_spend(200.0)
		var img: MirrorImage = null
		prism.sync_mirrors(true)
		for m in prism.mirrors:
			if m != null and is_instance_valid(m):
				img = m
				break
		var skip0: int = DebugStats.get_counter(&"mirror_budget_skipped")
		if img != null:
			img.cooldown_left = 0.0
			img.tick(DT)
		_check("④刀14 帧率优先 mirror_budget_skipped 可观测（预算咬合）",
			img != null and DebugStats.get_counter(&"mirror_budget_skipped") > skip0)
		_gl_wipe_weapons()
	_gl_release(fixtures)
	PerfGovernor.mode_override = -1


# ══ ⑦ 刀10：XpShard Node2D 回归 ═══════════════════════════════════
func _test_8_xp_shard_node2d() -> void:
	print("── ⑦ 刀10 XpShard Node2D 化回归 ──")
	# 源级锚
	var pickup_src := FileAccess.get_file_as_string("res://scripts/entities/player/pickup.gd")
	var tscn_src := FileAccess.get_file_as_string("res://scenes/combat/pickups/xp_shard.tscn")
	_check("⑦pickup.gd extends Node2D（根物理体摘除）",
		pickup_src.contains("class_name XpShard") and pickup_src.contains("extends Node2D"))
	_check("⑦xp_shard.tscn 根节点 type=\"Node2D\"", tscn_src.contains("type=\"Node2D\""))
	var player_src := FileAccess.get_file_as_string("res://scripts/entities/player/player.gd")
	_check("⑦player._pickup_area 构建段摘除（零引用）",
		not player_src.contains("_pickup_area = Area2D.new()")
			and not player_src.contains("var _pickup_area"))
	# 池取件类型断言（真件池 acquire → XpShard / Node2D 基类）
	var shard := (_gl.pools[&"xp"] as XPPool).acquire()
	_check("⑦XPPool.acquire → XpShard（Node2D 基类，池契约不破）",
		shard != null and shard is XpShard and shard is Node2D)
	if shard == null:
		return
	# 磁吸/拾取回归：activate → 近距磁吸 → 吸收入账
	shard.position = _gl.player.global_position + Vector2(60, 0)   # 磁吸半径 120 内
	shard.activate(5.0, 0.0)
	var xp_before: float = _gl.player.get("xp")
	var absorbed := false
	for i in range(30):
		if shard.tick(DT):
			absorbed = true
			break
	_check("⑦磁吸→吸收入账（gain_xp 链回归）",
		absorbed and _approx(float(_gl.player.get("xp")) - xp_before, 5.0, 0.001))
	# 归池清零（池归还契约）
	if not absorbed:
		shard.visible = false                    # 未吸收路径防池外泄漏（正常应吸收）
	else:
		(_gl.pools[&"xp"] as XPPool).release(shard)
	_check("⑦归池后 _reset_state 清零（value=0/磁吸位复位）",
		_approx(shard.value, 0.0) and not shard.is_magnet())
	# 磁吸半径语义走 player.pickup_radius 字段（Area 摘除后距离判定不变）
	var far := (_gl.pools[&"xp"] as XPPool).acquire()
	far.position = _gl.player.global_position + Vector2(400, 0)   # 远超 120px
	far.activate(3.0, 0.0)
	var magnetized := false
	for i in range(10):
		far.tick(DT)
		if far.is_magnet():
			magnetized = true
			break
	_check("⑦远距（>pickup_radius）不磁吸（距离判定口径不变）", not magnetized)
	far.force_magnet()                            # 波末全屏回收通道回归
	var absorbed2 := false
	for i in range(120):
		if far.tick(DT):
			absorbed2 = true
			break
	_check("⑦force_magnet 全屏回收（R7 波末通道回归）", absorbed2)
	if not absorbed2:
		(_gl.pools[&"xp"] as XPPool).release(far)


# ══ 计数桩（刀7 索敌缓存） ════════════════════════════════════════
class CountingGrid:
	extends SpaceGrid
	var nearest_calls: int = 0

	func query_nearest(pos: Vector2, radius: float, exclude: Node2D) -> Node2D:
		nearest_calls += 1
		return super.query_nearest(pos, radius, exclude)


# ══ 透传桩（武器 spawn 路径 resolve 不触；bank shard 等免依赖） ══════
class StubPipeline:
	extends RefCounted
	func resolve(_ctx: DamageContext) -> DamageResult:
		return null

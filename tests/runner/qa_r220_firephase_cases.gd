# tests/runner/qa_r220_firephase_cases.gd
# QA 独立取证用例体（test_qa_r220_firephase.gd 入口运行时加载；不复用实现者断言）。
# 契约真源：docs/design/2026-10-03-R220-拆解契约.md §5.3 / 方案书刀3②/5/6/7/10/12/13/14。
# 用例分两类：
#   · 契约核对——断言契约口径（应过）；
#   · 【缺陷取证】——断言「实测观察到的事实」（缺陷行为本身），detail 里同时给出
#     契约期望值与实测值，供报告引用；此类 PASS = 取证成功 ≠ 行为正确。
# 段落：
#   S1 刀3② 预索引等价   S2 刀5 池化借还/三失效面/§6.1 归还口联测
#   S3 刀6 三组相位+本体同拍   S4 刀7 元素分布/前K tie-break/镜签名惰性
#   S5 刀13 数值锚双态   S6 刀14 镜预算双态+skipped
#   S7 刀12 配额双态/守恒/预留   S8 刀10 XpShard Node2D 全回归
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
var _pooling_default: bool = false            # 产品默认快照（run 入口先取——S2 首查用）

# 独立夹具（S1/S2/S5 段）
var _proj_pool: ProjectilePool
var _homing_pool: ProjectilePool
var _enemy_pool: EnemyPool
var _grid: SpaceGrid
var _alive_enemies: Array[Node2D] = []
var _wd_counter: int = 0


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(20261003)
	PerfGovernor.mode_override = -1
	_pooling_default = TraitStack.POOLING_ENABLED   # 产品默认快照（修轮后=true）——S2 首查
	TraitStack.POOLING_ENABLED = false              # 段隔离起步（S2 段内显式双态切换）
	_setup_world()
	_s1_threshold_index()
	_s2_runtime_pool()
	_s5_value_anchors()
	_s4_elements()
	_teardown_world()
	_boot_game_loop()
	_s4_topk()
	_s3_stagger()
	_s6_mirror_budget()
	_s7_quota()
	_s8_xp_shard()
	_teardown_game_loop()
	PerfGovernor.mode_override = -1
	TraitStack.POOLING_ENABLED = true            # 复位产品默认（R220 修轮开启）
	print("────────────────────────────────────────")
	print("QA 取证汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
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


# ══ 独立夹具装配（pkg3/r220 先例） ═══════════════════════════════════
func _setup_world() -> void:
	_proj_pool = ProjectilePool.new()
	_proj_pool.name = "QA220ProjPool"
	tree.get_root().add_child(_proj_pool)
	_proj_pool.setup(&"qa220_ballistic", load(BALLISTIC_SCENE), 96)
	_homing_pool = ProjectilePool.new()
	_homing_pool.name = "QA220HomingPool"
	tree.get_root().add_child(_homing_pool)
	_homing_pool.setup(&"qa220_homing", load(HOMING_SCENE), 32)
	var ep := EnemyPool.new()
	ep.name = "QA220EnemyPool"
	tree.get_root().add_child(ep)
	ep.setup(&"qa220_enemy", load(ENEMY_SCENE), 32)
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
	d.id = StringName("W_QA220_%d" % _wd_counter)
	d.display_name = "QA220 测试武器 %d" % _wd_counter
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
	w.name = "QA220Weapon_%d" % _wd_counter
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


func _make_enemy_data(p_id: StringName, p_hp: float = 1000000.0) -> EnemyData:
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


func _spawn_enemy_at(p_pos: Vector2, p_id: StringName = &"E_QA220") -> Enemy:
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


func _wipe_bullets() -> void:
	for node in _proj_pool._live_order.keys():
		(node as ProjectileBase).nullify()


func _wipe_homing() -> void:
	for node in _homing_pool._live_order.keys():
		(node as ProjectileBase).nullify()


# ══ S1 刀3②：threshold 预索引等价 ═══════════════════════════════════
func _s1_threshold_index() -> void:
	print("── S1 刀3② 预索引等价（QA 独立） ──")
	var thresholds := [
		{"threshold_id": &"TH_QA_A", "metric": "bounce", "threshold": 7.0, "params": {"k": 2}},
		{"threshold_id": &"TH_QA_B", "metric": "pellets", "threshold": 4.0},
	]
	var w := _make_weapon(GameConst.WeaponForm.BALLISTIC,
		_make_weapon_data(GameConst.WeaponForm.BALLISTIC, {}, {}, thresholds),
		Vector2(360, 640)) as BallisticWeapon
	var eq := true
	for tid in [&"TH_QA_A", &"TH_QA_B"]:
		var expect: Dictionary = {}
		for entry in w.data.threshold_traits:
			if StringName(str(entry.get("threshold_id", ""))) == tid:
				expect = entry
				break
		if w.get_threshold(tid) != expect:
			eq = false
	_check("S1 索引读==线性扫首匹配（含 params）", eq)
	_check("S1 miss 键 → {}", w.get_threshold(&"TH_QA_MISSING").is_empty())
	# mutate 防御：追加后（size 漂移）索引重建
	w.data.threshold_traits.append({"threshold_id": &"TH_QA_LATE", "threshold": 3.0})
	_check("S1 data mutate → size 门触发重建",
		_approx(float(w.get_threshold(&"TH_QA_LATE").get("threshold", -1.0)), 3.0))
	w.free()


# ══ S2 刀5：运行栈池化（借还/归还口联测/三失效面） ═══════════════════
func _s2_runtime_pool() -> void:
	print("── S2 刀5 运行栈池化（QA 独立） ──")
	_check("S2 产品默认 POOLING_ENABLED==true（B 包归还口已合入——契约 §6.1 前置满足，修轮开启）",
		_pooling_default == true, "默认=%s" % str(_pooling_default))

	var data := _make_weapon_data(GameConst.WeaponForm.BALLISTIC)
	var w := _make_weapon(GameConst.WeaponForm.BALLISTIC, data, Vector2(360, 640)) as BallisticWeapon
	var main: TraitStack = w.trait_stack
	w.attach_trait(_make_trait_data("QA_T1", GameConst.PoolClass.ADD, &"add_atk",
		&"EF_STAT", 0.2))

	# 开关关：独立实例
	TraitStack.POOLING_ENABLED = false
	var off_a := main.acquire_runtime()
	var off_b := main.acquire_runtime()
	_check("S2 开关关=每次 new（独立实例）", off_a != off_b and off_a != main)
	off_a.release_to_pool()
	off_b.release_to_pool()

	# 开关开：第一轮借还
	TraitStack.POOLING_ENABLED = true
	var a1 := main.acquire_runtime()
	a1.release_to_pool()
	var a2 := main.acquire_runtime()
	_check("S2 第一轮借还：池优先复用同实例", a2 == a1, "a2==a1:%s" % str(a2 == a1))

	# 修轮回归（原缺陷B）：复用件借出时恢复 _home_stack——二次借还照常回池（稳态池化成立）
	a2.release_to_pool()
	var pool_after_second_release: int = main._runtime_pool.size()
	var a3 := main.acquire_runtime()
	_check("S2 二次借出件归还照常回池（借出恢复 _home_stack——修轮回归）",
		pool_after_second_release == 1 and a3 == a1,
		"期望 池 size 1 ∧ a3==a1；实测 size=%d a3==a1:%s"
			% [pool_after_second_release, str(a3 == a1)])
	a3.release_to_pool()

	# 修轮回归（原缺陷A）：查池提前——池命中路径零 copy_runtime（借出免全额克隆）
	var cs := CountingStack.new()
	var ctb := TraitBase.new()
	ctb.setup(_make_trait_data("QA_CNT", GameConst.PoolClass.ADD, &"add_atk", &"EF_STAT", 0.1))
	cs.traits.append(ctb)
	var c1 := cs.acquire_runtime()
	c1.release_to_pool()
	var calls_before := cs.copy_calls
	var c2 := cs.acquire_runtime()                  # 池命中路径
	_check("S2 池命中零 copy_runtime（查池提前——修轮回归，借出不再白付克隆）",
		cs.copy_calls - calls_before == 0 and c2 == c1,
		"期望 池命中 0 次克隆；实测 copy_runtime 调用 +%d 次（c2==c1:%s）"
			% [cs.copy_calls - calls_before, str(c2 == c1)])
	c2.release_to_pool()

	# 池污染：归还前运行位清零 + _assert_clean 不计数
	var dirty0: int = DebugStats.get_counter(&"trait_pool_dirty")
	var b1 := main.acquire_runtime()
	b1.traits[0].cooldown_left = 0.42
	b1.traits[0].frame_triggered = true
	b1.release_to_pool()
	var b2 := main.acquire_runtime()
	_check("S2 池污染断言：归还清运行位（_assert_clean 零计数）",
		DebugStats.get_counter(&"trait_pool_dirty") == dirty0
			and _approx(b2.traits[0].cooldown_left, 0.0)
			and not b2.traits[0].frame_triggered)
	b2.release_to_pool()

	# §6.1 归还口联测（真实弹路径）：弹回收 → 栈归池
	# （先清池：使首发借出走「新件」路径；复用件路径的可持续归池由下方修轮回归用例锁）
	_spawn_enemy_at(Vector2(360, 120))              # 远敌：R33 门放行、弹不动不亡
	TraitStack.POOLING_ENABLED = true
	main._runtime_pool.clear()
	w.cooldown_left = 0.0
	w.try_fire()
	var bullet1: ProjectileBase = _proj_pool._live_order.keys()[0] as ProjectileBase
	var stack1: TraitStack = bullet1.trait_stack
	_check("S2 §6.1 弹侧借出：spawn 携带池借栈（≠主栈）",
		stack1 != null and stack1 != main)
	bullet1.nullify()
	_check("S2 §6.1 弹回收后栈归池（_runtime_pool size==1）",
		main._runtime_pool.size() == 1 and main._runtime_pool[0] == stack1,
		"size=%d" % main._runtime_pool.size())
	w.cooldown_left = 0.0
	w.try_fire()
	var bullet2: ProjectileBase = _proj_pool._live_order.keys()[0] as ProjectileBase
	var stack2: TraitStack = bullet2.trait_stack
	_check("S2 §6.1 二次发射：复用归池件（stack2==stack1）", stack2 == stack1)
	bullet2.nullify()
	_check("S2 复用件随弹回收后照常归池（真实弹路径可持续借还——修轮回归）",
		main._runtime_pool.size() == 1 and main._runtime_pool[0] == stack1,
		"期望 size==1；实测 size=%d" % main._runtime_pool.size())

	# 三失效面② MILESTONE 质变：value_mult×1.6 后首发弹面板=新值 + 旧世代件弃件
	TraitStack.POOLING_ENABLED = true
	var stale := main.acquire_runtime()             # 存活「弹」持旧世代件
	var discard0: int = DebugStats.get_counter(&"trait_pool_discarded")
	main.traits[0].value_mult = 1.6                 # 质变乘区（attach_trait :147 同款落点）
	w._invalidate_panel()                           # 质变路径统一失效口（:148 同款）
	w.cooldown_left = 0.0
	w.try_fire()
	var bullet3: ProjectileBase = _proj_pool._live_order.keys()[0] as ProjectileBase
	var entries3: Array = bullet3.panel_snapshot.get("add_entries", [])
	var contrib3 := float(entries3[0].get("contrib", -1.0)) if entries3.size() > 0 else -1.0
	_check("S2 失效面② 质变：首发弹面板=新值（add_entries contrib 0.2×1.6=0.32）",
		_approx(contrib3, 0.32, 0.001), "contrib=%.4f" % contrib3)
	stale.release_to_pool()                         # 晚归旧世代件
	var rt_after := main.acquire_runtime()
	_check("S2 失效面② 晚归旧世代件弃件（trait_pool_discarded +1）+ 新件带新乘区",
		DebugStats.get_counter(&"trait_pool_discarded") == discard0 + 1
			and _approx(float(rt_after.traits[0].value_mult), 1.6))
	rt_after.release_to_pool()
	_wipe_bullets()
	_release_all_enemies()
	w.free()
	TraitStack.POOLING_ENABLED = false


# ══ S5 刀13：数值锚（双态） ═════════════════════════════════════════
func _s5_value_anchors() -> void:
	print("── S5 刀13 数值锚双态（QA 独立） ──")
	PerfGovernor.mode_override = 0
	var q_fp := BallisticWeapon.eternal_quota()
	PerfGovernor.mode_override = 1
	var q_fx := BallisticWeapon.eternal_quota()
	_check("S5 刀13③ 永存配额 帧率优先 120 / 特效优先 240", q_fp == 120 and q_fx == 240,
		"%d / %d" % [q_fp, q_fx])

	_spawn_enemy_at(Vector2(360, 120))
	var w := _make_weapon(GameConst.WeaponForm.BALLISTIC,
		_make_weapon_data(GameConst.WeaponForm.BALLISTIC, {"rof": 5.0, "pellets": 1},
			{"proj_speed": 600.0, "range": 600.0, "spread_deg": 0.0}),
		Vector2(360, 640)) as BallisticWeapon
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
	_check("S5 刀13① 弹寿命系数 帧率优先 1.15 / 特效优先 1.5",
		_approx(life_fp, 1.15, 0.001) and _approx(life_fx, 1.5, 0.001),
		"%.4f / %.4f" % [life_fp, life_fx])

	var wb := _make_weapon(GameConst.WeaponForm.BALLISTIC,
		_make_weapon_data(GameConst.WeaponForm.BALLISTIC, {"rof": 5.0, "pellets": 1},
			{"proj_speed": 600.0, "range": 600.0, "spread_deg": 0.0}),
		Vector2(360, 640)) as BallisticWeapon
	wb.attach_trait(_make_trait_data("QA_BOUNCE", GameConst.PoolClass.MECH, &"mec_bounce",
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
	_check("S5 刀13② 跳弹寿命保底 帧率优先 10.0 / 特效优先 20.0",
		_approx(bl_fp, 10.0, 0.001) and _approx(bl_fx, 20.0, 0.001),
		"%.3f / %.3f" % [bl_fp, bl_fx])

	var wh := _make_weapon(GameConst.WeaponForm.HOMING,
		_make_weapon_data(GameConst.WeaponForm.HOMING, {"cd": 0.5},
			{"proj_speed_init": 240.0, "volley_count": 1.0}),
		Vector2(360, 640)) as HomingWeapon
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
	_check("S5 刀13④ 自导寿命 帧率优先 3.5/3.0 · 特效优先 6.0/5.0",
		_approx(h_fp, 3.5, 0.001) and _approx(s_fp, 3.0, 0.001)
			and _approx(h_fx, 6.0, 0.001) and _approx(s_fx, 5.0, 0.001),
		"%.2f/%.2f · %.2f/%.2f" % [h_fp, s_fp, h_fx, s_fx])
	PerfGovernor.mode_override = -1
	_release_all_enemies()
	w.free()
	wb.free()
	wh.free()


# ══ GameLoop 装配（S3/S4镜/S6/S7/S8） ═══════════════════════════════
func _boot_game_loop() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "GameLoopQA220"
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
	TraitStack.POOLING_ENABLED = true            # 复位产品默认（R220 修轮开启）
	RunSave.clear()
	if _gl != null:
		_gl.free()
		_gl = null


func _gl_fixtures(p_positions: Array[Vector2]) -> Array[Node2D]:
	var out: Array[Node2D] = []
	for pos in p_positions:
		var enemy := (_gl.pools[&"enemy"] as EnemyPool).acquire()
		enemy.spawn(_gl_fixture_enemy(&"E_QA220_FIX"), 1, 0)
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
	if _gl.player.has_method(&"_summon_restore"):
		_gl.player.call(&"_summon_restore")
	var slots: Array = _gl.player.get("weapon_slots")
	for i in range(slots.size()):
		var wv: Variant = slots[i]
		if wv != null and is_instance_valid(wv):
			slots[i] = null
			(wv as Node).queue_free()
	_gl.player.unlocked_slots = 6


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


# ══ S4 刀7（一）：元素分布（独立夹具段） ═════════════════════════════
func _s4_elements() -> void:
	print("── S4 刀7 逐发元素分布（QA 独立） ──")
	# 双元素分布（FIR/ICE）240 发
	var grid := SpaceGrid.new()
	grid.configure(Vector2(720, 1280), 192.0)
	var welem := _make_weapon(GameConst.WeaponForm.BALLISTIC,
		_make_weapon_data(GameConst.WeaponForm.BALLISTIC, {"rof": 5.0, "pellets": 1},
			{"proj_speed": 600.0, "range": 600.0, "spread_deg": 0.0}),
		Vector2(360, 640)) as BallisticWeapon
	welem.enemy_grid = grid
	welem.attach_trait(_make_trait_data("QA_E_FIR", GameConst.PoolClass.ELEM, &"e_fir",
		&"EF_ELEM_MARK", 1.0))
	welem.trait_stack.traits[0].data.params["element"] = GameConst.Element.FIR
	welem.attach_trait(_make_trait_data("QA_E_ICE", GameConst.PoolClass.ELEM, &"e_ice",
		&"EF_ELEM_MARK", 1.0))
	welem.trait_stack.traits[1].data.params["element"] = GameConst.Element.ICE
	var e0 := _spawn_enemy_at(Vector2(360, 120))
	grid.rebuild([e0])
	var n_fir := 0
	var n_ice := 0
	for i in range(240):
		welem.cooldown_left = 0.0
		welem.try_fire()
		var live: Array = _proj_pool._live_order.keys()
		var last := live[live.size() - 1] as ProjectileBase
		if int(last.element) == GameConst.Element.FIR:
			n_fir += 1
		else:
			n_ice += 1
		last.nullify()
	_check("S4 双元素逐发分布 ≈120±40（240 发）",
		n_fir >= 80 and n_fir <= 160 and n_ice >= 80 and n_ice <= 160,
		"FIR=%d ICE=%d" % [n_fir, n_ice])
	# 同拍多丸逐发独立（16 丸不全同元素）
	var wvol := _make_weapon(GameConst.WeaponForm.BALLISTIC,
		_make_weapon_data(GameConst.WeaponForm.BALLISTIC, {"rof": 5.0, "pellets": 16},
			{"proj_speed": 600.0, "range": 600.0, "spread_deg": 13.0}),
		Vector2(360, 640)) as BallisticWeapon
	wvol.enemy_grid = grid
	wvol.trait_stack = welem.trait_stack            # 共享双元素主栈（只读词条集）
	wvol.cooldown_left = 0.0
	wvol.try_fire()
	var elems_seen := {}
	for node in _proj_pool._live_order.keys():
		elems_seen[int((node as ProjectileBase).element)] = true
	_check("S4 同拍 16 丸元素非全同（逐发 randi 语义）", elems_seen.size() >= 2,
		"distinct=%d" % elems_seen.size())
	_wipe_bullets()
	_release_all_enemies()
	welem.free()
	wvol.free()


# ══ S4 刀7（二）：前 K 选择（GameLoop 真网格） ══════════════════════
func _s4_topk() -> void:
	print("── S4 刀7 homing 前 K 选择（QA 独立·GameLoop 网格） ──")
	var wh := HomingWeapon.new()
	wh.name = "QA220TopK"
	_gl.player.add_child(wh)
	wh.position = Vector2(360, 640)
	wh.setup(_make_weapon_data(GameConst.WeaponForm.HOMING, {"cd": 0.5},
		{"proj_speed_init": 240.0, "volley_count_levels": [4.0, 4.0, 4.0, 4.0, 4.0]}),
		_gl.player, _gl.player.get("_deps"))
	var fix := _gl_fixtures([Vector2(360, 540), Vector2(360, 470), Vector2(300, 760),
		Vector2(430, 900), Vector2(360, 1000), Vector2(500, 640)])
	var got := wh._acquire_volley_targets(4)
	var dup := fix.duplicate()
	var origin := wh.muzzle_position()
	dup.sort_custom(func(a: Node2D, b: Node2D) -> bool: return origin.distance_squared_to(a.global_position) < origin.distance_squared_to(b.global_position))
	var expect: Array[Node2D] = []
	for cand in dup:
		if expect.size() >= 4:
			break
		expect.append(cand)
	var match_ok := got.size() == expect.size()
	for i in range(mini(got.size(), expect.size())):
		if got[i] != expect[i]:
			match_ok = false
	_check("S4 前 K=4 与全量排序真源逐位一致（距离互异）", match_ok)

	# 并列 tie-break：对称同距两敌 + 乱序重建 → 两次同选、uid 小者先
	_gl_release(fix)
	var tie := _gl_fixtures([Vector2(360, 500), Vector2(360, 780)])   # 对 640 对称同距
	var t1 := wh._acquire_volley_targets(2)
	var uid_a := int(tie[0].get("uid"))
	var uid_b := int(tie[1].get("uid"))
	var smaller_first: Node2D = tie[0] if uid_a < uid_b else tie[1]
	var t2: Array[Node2D]
	_gl.enemy_grid.rebuild([tie[1], tie[0]])         # 乱序重建
	t2 = wh._acquire_volley_targets(2)
	_gl_release(tie)
	_check("S4 并列确定性：同距两目标两次（乱序网格）同选且 uid 小者先",
		t1.size() == 2 and t2.size() == 2 and t1[0] == t2[0] and t1[1] == t2[1]
			and t1[0] == smaller_first,
		"t1=[%d,%d] t2=[%d,%d] smaller=%d" % [int(t1[0].get("uid")), int(t1[1].get("uid")),
			int(t2[0].get("uid")), int(t2[1].get("uid")),
			int(smaller_first.get("uid"))])
	wh.queue_free()


# ══ S3 刀6：三组相位 + 本体同拍 ═════════════════════════════════════
func _s3_stagger() -> void:
	print("── S3 刀6 三组相位 + 本体同拍（QA 独立） ──")
	PerfGovernor.mode_override = 1               # 工程刀双模式生效
	var fixtures := _gl_fixtures([Vector2(360, 500)])

	# 副本组 + 僚机组（noah 召唤）
	_gl_wipe_weapons()
	_gl.player.set("character_id", &"noah")
	_gl.player.set("skill_cd_left", 0.0)
	_gl.player.add_weapon(_gl.registry.get_weapon(&"W1_pistol"))
	_gl.player.activate_skill()
	var copies: Array = _gl.player.get("_summon_copies")
	var drones: Array = _gl.player.get("_summon_drones")
	var cp_ok := copies.size() == 2
	if cp_ok:
		var iv: float = (copies[0] as WeaponBase)._fire_interval()
		cp_ok = _approx((copies[0] as WeaponBase).cooldown_left, 0.0) \
			and _approx((copies[1] as WeaponBase).cooldown_left, iv * 0.5)
	_check("S3 副本组相位 interval×(i/2)", cp_ok, "copies=%d" % copies.size())
	var dr_ok := drones.size() == 2 \
		and _approx(float(drones[0].get("_fire_left")), 0.0) \
		and _approx(float(drones[1].get("_fire_left")), 0.55 * 0.5)
	_check("S3 僚机组相位 0.55×(i/2)", dr_ok, "drones=%d" % drones.size())
	_gl.player.set("_summon_left", 0.0)
	_gl.player.call(&"_summon_restore")

	# 镜组：一次性建组（L5=3）→ 0 / interval×(1/3) / interval×(2/3)
	_gl_wipe_weapons()
	_gl.player.add_weapon(_gl.registry.get_weapon(&"W1_pistol"))
	var prism := MirrorWeapon.new()
	prism.setup(_gl.registry.get_weapon(&"W5_prism"), _gl.player, _gl.player.get("_deps"))
	if not _gl.player.equip_weapon(prism):
		prism.free()
		prism = null
	var mirror_ok := prism != null
	if mirror_ok:
		prism.level = 5
		prism.sync_mirrors(true)
		var ms: Array = prism.mirrors
		mirror_ok = ms.size() == 3
		if mirror_ok:
			var ivm: float = (ms[1] as MirrorImage)._fire_interval()
			for i in range(3):
				var want := ivm * (float(i) / 3.0)
				if not _approx((ms[i] as MirrorImage).cooldown_left, want):
					mirror_ok = false
	_check("S3 镜组一次性建组相位 interval×(i/3)", mirror_ok,
		"mirrors=%d" % (prism.mirrors.size() if prism != null else -1))
	if prism != null:
		# 相位确定性：全清重建同相位
		var phases1: Array[float] = []
		for m in prism.mirrors:
			phases1.append(m.cooldown_left)
		_gl.player.clear_mirrors()
		prism.mirrors.clear()
		prism.sync_mirrors(true)
		var det := prism.mirrors.size() == phases1.size()
		for i in range(mini(prism.mirrors.size(), phases1.size())):
			if not _approx(prism.mirrors[i].cooldown_left, phases1[i]):
				det = false
		_check("S3 镜组重建相位确定性（同构同推导）", det)

		# 修轮回归（原缺陷取证）：增长路径 容量 2 → 3 增量建组——存量镜按终态 N=3 重推相位
		# （原实现存量镜分母停留旧容量 2：镜[1]停在 interval×1/2，相位聚集上半拍）
		_gl.player.clear_mirrors()
		prism.mirrors.clear()
		prism.level = 3                           # mirrors_count_levels L3=2 → 容量 2
		prism.sync_mirrors(true)
		var grown_cap2_ok := prism.mirrors.size() == 2 \
			and _approx(prism.mirrors[1].cooldown_left,
				prism.mirrors[1]._fire_interval() * 0.5)
		prism.attach_trait(_make_trait_data("MEC_MIRROR_SPLIT", GameConst.PoolClass.MECH,
			&"mec_mirror_split", &"EF_STAT", 1.0))    # +1 层 → 容量 3（attach 自动 sync）
		var iv3: float = prism.mirrors[1]._fire_interval() if prism.mirrors.size() >= 3 else 0.0
		var m1_observed: float = prism.mirrors[1].cooldown_left if prism.mirrors.size() >= 3 else -1.0
		var m2_observed: float = prism.mirrors[2].cooldown_left if prism.mirrors.size() >= 3 else -1.0
		_check("S3 容量 2→3 增量建组：存量镜按终态 N=3 重推（镜[1]=interval×1/3——修轮回归）",
			grown_cap2_ok and prism.mirrors.size() == 3
				and _approx(m1_observed, iv3 / 3.0)
				and _approx(m2_observed, iv3 * (2.0 / 3.0)),
			"契约 interval×1/3=%.4f / ×2/3=%.4f；实测 m1=%.4f m2=%.4f"
				% [iv3 / 3.0, iv3 * (2.0 / 3.0), m1_observed, m2_observed])

	# 本体组波首同拍：双武器冷却 0 + 敌在 → 同帧齐射
	_gl_wipe_weapons()
	var body_a := _gl.player.add_weapon(_gl.registry.get_weapon(&"W1_pistol"))
	var body_b := _gl.player.add_weapon(_gl.registry.get_weapon(&"W2_gatling"))
	body_a.cooldown_left = 0.0
	body_b.cooldown_left = 0.0
	_gl_clear_player_bullets()
	_gl_drive(1)
	_check("S3 本体组波首同拍保持（双武器同帧首射）",
		float(body_a.get("_since_fire")) <= DT and float(body_b.get("_since_fire")) <= DT,
		"a=%.4f b=%.4f" % [float(body_a.get("_since_fire")), float(body_b.get("_since_fire"))])
	_gl_wipe_weapons()
	_gl_release(fixtures)
	PerfGovernor.mode_override = -1


# ══ S4（二）+ S6：镜签名惰性 / 刀14 镜预算 ═══════════════════════════
func _s6_mirror_budget() -> void:
	print("── S6 刀14 镜预算 / S4 刀7 镜签名惰性（QA 独立） ──")
	var fixtures := _gl_fixtures([Vector2(360, 500)])
	_gl.player.add_weapon(_gl.registry.get_weapon(&"W1_pistol"))
	var probe := ProbeMirror.new()
	probe.setup(_gl.registry.get_weapon(&"W5_prism"), _gl.player, _gl.player.get("_deps"))
	if not _gl.player.equip_weapon(probe):
		probe.free()
		probe = null
	_check("S6 前置：计数棱镜入槽", probe != null)
	if probe == null:
		_gl_release(fixtures)
		return

	# 刀14 双态预算锚
	PerfGovernor.mode_override = 0
	var b_fp := probe.budget_per_s()
	PerfGovernor.mode_override = 1
	var b_fx := probe.budget_per_s()
	_check("S6 刀14 budget_per_s 帧率优先 165 / 特效优先 600（.tres 原值）",
		_approx(b_fp, 165.0, 0.001) and _approx(b_fx, 600.0, 0.001),
		"%.1f / %.1f" % [b_fp, b_fx])
	_check("S6 刀14 MIRROR_CAP==5 / BUDGET_WINDOW_S==1.0 不动",
		probe.MIRROR_CAP == 5 and _approx(probe.BUDGET_WINDOW_S, 1.0))

	# 刀14 帧率优先预算咬合：灌满 165 → 镜面拍静默跳过 + skipped 计数
	PerfGovernor.mode_override = 0
	probe.level = 5
	probe.sync_mirrors(true)
	probe.budget_spend(200.0)
	var img: MirrorImage = null
	for m in probe.mirrors:
		if m != null and is_instance_valid(m):
			img = m
			break
	var skip0: int = DebugStats.get_counter(&"mirror_budget_skipped")
	if img != null:
		img.cooldown_left = 0.0
		img.tick(DT)
	_check("S6 刀14 帧率优先 mirror_budget_skipped 可观测（咬合）",
		img != null and DebugStats.get_counter(&"mirror_budget_skipped") > skip0)

	# 刀7 镜签名惰性【缺陷取证】：稳态（容量/存活/注册表全过）仍构建签名串
	probe.budget_spend(-1000.0)                   # 预算窗清零（防 skipped 干扰后续）
	probe._budget_spent = 0.0
	var ids_before: Array = []
	for m in probe.mirrors:
		ids_before.append(m.get_instance_id())
	probe.sig_builds = 0
	probe.sync_mirrors(false)                     # 稳态驱动拍（_on_tick_post 同款路径）
	_check("S6【缺陷取证】刀7 镜签名惰性：稳态 sync_mirrors 仍构建签名字符串",
		probe.sig_builds == 1,
		"契约期望（§5.3-4 容量未变零构建）：0 次构建；实测 %d 次（三快速门稳态全过）"
			% probe.sig_builds)
	var unchanged := probe.mirrors.size() == ids_before.size()
	for i in range(mini(probe.mirrors.size(), ids_before.size())):
		if probe.mirrors[i].get_instance_id() != ids_before[i]:
			unchanged = false
	_check("S6 稳态 sync_mirrors 不重排（镜实例原样）", unchanged)

	_gl_wipe_weapons()
	_gl_release(fixtures)
	PerfGovernor.mode_override = -1


# ══ S7 刀12：配额双态 / 守恒 / 预留 ═════════════════════════════════
func _s7_quota() -> void:
	print("── S7 刀12 弹生成配额（QA 独立） ──")
	_gl_wipe_weapons()
	_gl_clear_player_bullets()
	var fixtures := _gl_fixtures([Vector2(360, 120)])   # 远敌：射程外，40 帧窗内弹不死
	var shot_data := _make_weapon_data(GameConst.WeaponForm.BALLISTIC,
		{"rof": 5.0, "pellets": 16}, {"proj_speed": 600.0, "range": 600.0, "spread_deg": 13.0})
	var guns: Array[BallisticWeapon] = []
	for i in range(3):
		var g := BallisticWeapon.new()
		g.name = "QA220Quota%d" % i
		_gl.player.add_child(g)
		g.position = Vector2(360, 900)
		g.setup(shot_data, _gl.player, _gl.player.get("_deps"))
		if _gl.player.equip_weapon(g):
			guns.append(g)
		else:
			g.free()
	_check("S7 前置：3 把 16 丸武器入槽", guns.size() == 3)

	# A 帧率优先：单步 48 → 32 放行 + 16 顺延
	PerfGovernor.mode_override = 0
	var def0: int = DebugStats.get_counter(&"quota_deferred")
	var drop0: int = DebugStats.get_counter(&"quota_dropped")
	_gl_drive(1)
	_check("S7 A 帧率优先：单步 48 发 → 在场 32（硬帽咬合）",
		_gl_live_player_bullets() == 32, "live=%d" % _gl_live_player_bullets())
	_check("S7 A 超配顺延记账 +16（quota_deferred）",
		DebugStats.get_counter(&"quota_deferred") - def0 == 16,
		"deferred=%d" % (DebugStats.get_counter(&"quota_deferred") - def0))

	# B 特效优先：无帽（先清 A 段顺延账——顺延记账跨模式，FX 模式到期照发不丢，
	#   本断言只隔离「新丸零顺延+无帽」语义）
	_gl_clear_player_bullets()
	for g in guns:
		g.cooldown_left = 0.0
		g.set("_quota_pending", 0)
		g.set("_quota_def_a", 0)
		g.set("_quota_def_b", 0)
	PerfGovernor.mode_override = 1
	var def1: int = DebugStats.get_counter(&"quota_deferred")
	_gl_drive(1)
	_check("S7 B 特效优先：单步 48 发全放（零顺延）",
		_gl_live_player_bullets() == 48
			and DebugStats.get_counter(&"quota_deferred") == def1,
		"live=%d" % _gl_live_player_bullets())

	# C 守恒（顺延不丢）：单枪注入 pending 20 → 40 帧总落地 20+16×3=68
	# （节拍时序：tick 先减冷却、到 0 的下一拍才开火（elif 结构）→ 实际 13-14 帧/拍，
	#   40 帧窗恰 3 拍新丸；拍1 32（帽）+拍2 20（due4+新16）+拍3 16 = 68）
	PerfGovernor.mode_override = 0
	_gl_clear_player_bullets()
	for g in guns:
		g.queue_free()
		var idx: int = (_gl.player.weapon_slots as Array).find(g)
		if idx >= 0:
			(_gl.player.weapon_slots as Array)[idx] = null
	var gun := BallisticWeapon.new()
	gun.name = "QA220QuotaSingle"
	_gl.player.add_child(gun)
	gun.position = Vector2(360, 900)
	gun.setup(shot_data, _gl.player, _gl.player.get("_deps"))
	_gl.player.equip_weapon(gun)
	gun.set("_quota_pending", 20)
	var spawned := 0
	var live_p := _gl_live_player_bullets()
	for i in range(40):
		_gl_drive(1)
		var now := _gl_live_player_bullets()
		spawned += maxi(now - live_p, 0)
		live_p = now
	_check("S7 C 守恒：注入 20 + 新 48 = 68 全落地（顺延非丢弃，dropped 零增长）",
		spawned == 68 and DebugStats.get_counter(&"quota_dropped") == drop0,
		"spawned=%d 期望 68" % spawned)

	# D【缺陷取证】due 预留与开火节拍脱钩：不可开火武器长期占预留
	_gl_clear_player_bullets()
	gun.queue_free()
	var idx2: int = (_gl.player.weapon_slots as Array).find(gun)
	if idx2 >= 0:
		(_gl.player.weapon_slots as Array)[idx2] = null
	var gunA := BallisticWeapon.new()
	gunA.name = "QA220QuotaHold"
	_gl.player.add_child(gunA)
	gunA.position = Vector2(360, 900)
	gunA.setup(shot_data, _gl.player, _gl.player.get("_deps"))
	_gl.player.equip_weapon(gunA)
	gunA.set("_quota_pending", 24)                # 24 丸到期账
	gunA.cooldown_left = 999.0                    # 本步不可开火（长冷却）
	var gunB := BallisticWeapon.new()
	gunB.name = "QA220QuotaLive"
	_gl.player.add_child(gunB)
	gunB.position = Vector2(360, 900)
	gunB.setup(shot_data, _gl.player, _gl.player.get("_deps"))
	_gl.player.equip_weapon(gunB)
	gunB.cooldown_left = 0.0
	_gl_drive(1)
	_check("S7【缺陷取证】due 预留被不可开火武器占用：B 仅放行 8（32−24）",
		_gl_live_player_bullets() == 8,
		"预留应服务本步到期补发；实测不可开火者占 24 配额、活武器新丸仅 8（live=%d）"
			% _gl_live_player_bullets())
	gunA.queue_free()
	gunB.queue_free()
	for gq in [gunA, gunB]:
		var idx3: int = (_gl.player.weapon_slots as Array).find(gq)
		if idx3 >= 0:
			(_gl.player.weapon_slots as Array)[idx3] = null
	_gl_release(fixtures)
	PerfGovernor.mode_override = -1


# ══ S8 刀10：XpShard Node2D 全回归 ══════════════════════════════════
func _s8_xp_shard() -> void:
	print("── S8 刀10 XpShard Node2D 回归（QA 独立） ──")
	var pickup_src := FileAccess.get_file_as_string("res://scripts/entities/player/pickup.gd")
	var tscn_src := FileAccess.get_file_as_string("res://scenes/combat/pickups/xp_shard.tscn")
	var player_src := FileAccess.get_file_as_string("res://scripts/entities/player/player.gd")
	_check("S8 pickup.gd extends Node2D + class_name XpShard 保持",
		pickup_src.contains("extends Node2D") and pickup_src.contains("class_name XpShard"))
	_check("S8 xp_shard.tscn 根 type=\"Node2D\"", tscn_src.contains("type=\"Node2D\""))
	_check("S8 player.gd 零 _pickup_area 残留（除注释）",
		not player_src.contains("var _pickup_area") and not player_src.contains("_pickup_area = "))

	var shard := (_gl.pools[&"xp"] as XPPool).acquire()
	_check("S8 XPPool.acquire → XpShard（Node2D 基类）",
		shard != null and shard is XpShard and shard is Node2D)
	if shard == null:
		return
	shard.position = _gl.player.global_position + Vector2(60, 0)
	shard.activate(5.0, 0.0)
	var xp_before: float = float(_gl.player.get("xp"))
	var absorbed := false
	for i in range(30):
		if shard.tick(DT):
			absorbed = true
			break
	_check("S8 磁吸→吸收入账（gain_xp 5.0）",
		absorbed and _approx(float(_gl.player.get("xp")) - xp_before, 5.0, 0.001))
	if absorbed:
		(_gl.pools[&"xp"] as XPPool).release(shard)
	_check("S8 归池 _reset_state 清零（value=0/磁吸复位）",
		_approx(shard.value, 0.0) and not shard.is_magnet())
	var far := (_gl.pools[&"xp"] as XPPool).acquire()
	far.position = _gl.player.global_position + Vector2(400, 0)
	far.activate(3.0, 0.0)
	var magnetized := false
	for i in range(10):
		far.tick(DT)
		if far.is_magnet():
			magnetized = true
			break
	_check("S8 远距（>pickup_radius）不磁吸", not magnetized)
	far.force_magnet()
	var absorbed2 := false
	for i in range(200):
		if far.tick(DT):
			absorbed2 = true
			break
	_check("S8 force_magnet 全屏回收（R7 波末通道）", absorbed2)
	if not absorbed2:
		(_gl.pools[&"xp"] as XPPool).release(far)


# ══ 计数桩 ══════════════════════════════════════════════════════════
class CountingStack:
	extends TraitStack
	var copy_calls: int = 0

	func copy_runtime() -> TraitStack:
		copy_calls += 1
		return super.copy_runtime()


class ProbeMirror:
	extends MirrorWeapon
	var sig_builds: int = 0

	func _composition_signature() -> String:
		sig_builds += 1
		return super._composition_signature()


class StubPipeline:
	extends RefCounted
	func resolve(_ctx: DamageContext) -> DamageResult:
		return null

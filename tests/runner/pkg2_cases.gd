# tests/runner/pkg2_cases.gd
# 包 2 自测用例体（由 test_pkg2.gd 入口在 autoload 就绪后运行时加载编译）。
# 覆盖（任务书 7）：六大事件派发顺序=挂载序、回收五路径全部收束（OnExpire→清零→归还）、
# 穿透计数递减/反弹反射角镜像 <2°、Homing 角速度 clamp/二段延时/重索敌/AOE、
# 波次 TP 公式与表驱动一致+单帧≤8+同屏≤120、玩家相对拖动+边界钳制+无敌帧、
# 同帧同目标去重（E-03）、池零实例化运行（acquire/release 复用）、透传桩公式。
extends RefCounted

const BALLISTIC_SCENE := "res://scenes/combat/projectiles/ballistic_projectile.tscn"
const HOMING_SCENE := "res://scenes/combat/projectiles/homing_projectile.tscn"
const ENEMY_SCENE := "res://scenes/combat/enemies/enemy.tscn"
const PLAYER_SCENE := "res://scenes/combat/player/player.tscn"
const DT := 1.0 / 120.0

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _probe: Node                          # 事件探针（Node 订阅者，E-12）

# 共享夹具（按组重建）
var _proj_pool: ProjectilePool
var _homing_pool: ProjectilePool
var _enemy_pool: EnemyPool
var _grid: SpaceGrid
var _pipeline: DamagePipelineStub
var _alive_enemies: Array[Node2D] = []


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	_ensure_autoloads()
	_setup_probe()
	_test_stub_pipeline()
	await _test_contact_damage()
	_test_event_dispatch_order()
	_test_recycle_paths()
	_test_pierce_and_bounce()
	_test_frame_dedup()
	_test_homing()
	_test_enemy()
	await _test_player()
	_test_waves()
	_test_pool_zero_instantiate()
	_summary()
	if _probe != null:
		_probe.free()                             # 退出前清理探针（ObjectDB 泄漏检查）


func fail_count() -> int:
	return _fail


# ── 支撑 ──────────────────────────────────────────────────────────
func _approx(p_a: float, p_b: float, p_tol: float = 0.001) -> bool:
	# 容差近似断言（全局 is_equal_approx 仅 2 参；本文件统一用本辅助支持容差）
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


func _setup_probe() -> void:
	# 事件探针（运行时脚本——Node 订阅者，规避 E-12 拦截）
	var s := GDScript.new()
	s.source_code = "extends Node\n" \
		+ "var enemy_killed_hits: int = 0\n" \
		+ "var wave_started_hits: int = 0\n" \
		+ "var wave_cleared_hits: int = 0\n" \
		+ "var player_hit_hits: int = 0\n" \
		+ "var player_died_hits: int = 0\n" \
		+ "var level_up_hits: int = 0\n" \
		+ "var slot_unlocked_hits: int = 0\n" \
		+ "var boss_spawned_hits: int = 0\n" \
		+ "var last_wave_started: int = 0\n" \
		+ "var last_wave_cleared: int = 0\n" \
		+ "var last_level: int = 0\n" \
		+ "var last_slot: int = 0\n" \
		+ "func on_enemy_killed(_e: Node2D) -> void:\n\tenemy_killed_hits += 1\n" \
		+ "func on_wave_started(w: int) -> void:\n\twave_started_hits += 1\n\tlast_wave_started = w\n" \
		+ "func on_wave_cleared(w: int) -> void:\n\twave_cleared_hits += 1\n\tlast_wave_cleared = w\n" \
		+ "func on_player_hit(_d: float, _u: int) -> void:\n\tplayer_hit_hits += 1\n" \
		+ "func on_player_died() -> void:\n\tplayer_died_hits += 1\n" \
		+ "func on_level_up(l: int) -> void:\n\tlevel_up_hits += 1\n\tlast_level = l\n" \
		+ "func on_slot_unlocked(s: int) -> void:\n\tslot_unlocked_hits += 1\n\tlast_slot = s\n" \
		+ "func on_boss_spawned(_e: Node2D) -> void:\n\tboss_spawned_hits += 1\n"
	s.reload()
	_probe = Node.new()
	_probe.name = "Pkg2Probe"
	_probe.set_script(s)
	tree.get_root().add_child(_probe)
	EventBus.enemy_killed.connect(Callable(_probe, "on_enemy_killed"))
	EventBus.wave_started.connect(Callable(_probe, "on_wave_started"))
	EventBus.wave_cleared.connect(Callable(_probe, "on_wave_cleared"))
	EventBus.player_hit.connect(Callable(_probe, "on_player_hit"))
	EventBus.player_died.connect(Callable(_probe, "on_player_died"))
	EventBus.level_up.connect(Callable(_probe, "on_level_up"))
	EventBus.slot_unlocked.connect(Callable(_probe, "on_slot_unlocked"))
	EventBus.boss_spawned.connect(Callable(_probe, "on_boss_spawned"))


func _make_recording_trait() -> RefCounted:
	# 记录序假词条（on_event 按 TraitBase 方法签名 duck-typing 调用；ON_EXPIRE 期采样状态；
	# shared 为共享序列数组——多词条写入同一数组以验证挂载序交错）
	var s := GDScript.new()
	s.source_code = "extends RefCounted\n" \
		+ "var id: String = \"\"\n" \
		+ "var log: Array = []\n" \
		+ "var shared: Array = []\n" \
		+ "var expire_obs: Dictionary = {}\n" \
		+ "func on_event(p_event: int, p_ctx) -> void:\n" \
		+ "\tlog.append(id + \":\" + str(p_event))\n" \
		+ "\tshared.append(id + \":\" + str(p_event))\n" \
		+ "\tif p_event == 5:\n" \
		+ "\t\tvar proj = p_ctx[\"projectile\"]\n" \
		+ "\t\texpire_obs[\"velocity\"] = proj.velocity\n" \
		+ "\t\texpire_obs[\"is_clean\"] = proj.is_clean\n" \
		+ "\t\texpire_obs[\"visible\"] = proj.visible\n"
	s.reload()
	return s.new()


func _make_enemy_data(p_id: String, p_hp: float = 100.0, p_tp: float = 1.0, p_tags: int = 0) -> EnemyData:
	var d := EnemyData.new()
	d.id = StringName(p_id)
	d.display_name = p_id
	d.hp_base = p_hp
	d.spd_base = 75.0
	d.dmg_base = 8.0
	d.exp_base = 3.0
	d.tp_cost = p_tp
	d.hitbox_r = 14.0
	d.tags = p_tags
	return d


func _make_proj_pool(p_scene_path: String, p_cap: int) -> ProjectilePool:
	var pool := ProjectilePool.new()
	pool.name = "Pkg2ProjPool_%d" % (tree.get_root().get_child_count())
	tree.get_root().add_child(pool)
	pool.setup(&"pkg2_test", load(p_scene_path), p_cap)
	return pool


func _setup_world() -> void:
	# 弹/敌/网格/桩管线迷你世界（投射物测试组共享）
	_proj_pool = _make_proj_pool(BALLISTIC_SCENE, 32)
	var ep := EnemyPool.new()
	ep.name = "Pkg2EnemyPool_%d" % (tree.get_root().get_child_count())
	tree.get_root().add_child(ep)
	ep.setup(&"pkg2_enemy", load(ENEMY_SCENE), 32)
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
	if _enemy_pool != null:
		_enemy_pool.free()
		_enemy_pool = null
	if _homing_pool != null:
		_homing_pool.free()
		_homing_pool = null


func _spawn_ballistic(p_params: Dictionary, p_traits: Array = []) -> BallisticProjectile:
	var proj := _proj_pool.acquire() as BallisticProjectile
	proj.damage_pipeline = _pipeline
	proj.enemy_grid = _grid
	proj.pool = _proj_pool
	var params := p_params.duplicate()
	if not params.has("panel_snapshot"):
		params["panel_snapshot"] = {"base_atk": 10.0}
	if not p_traits.is_empty():
		params["traits"] = p_traits
	proj.spawn(params)
	return proj


func _spawn_enemy_at(p_data: EnemyData, p_pos: Vector2, p_wave: int = 1) -> Enemy:
	var e := _enemy_pool.acquire() as Enemy
	e.spawn(p_data, p_wave, 0)
	e.position = p_pos
	_alive_enemies.append(e)
	_grid.rebuild(_alive_enemies)
	return e


# ── 1. 透传桩 DamagePipelineStub ──────────────────────────────────
func _test_stub_pipeline() -> void:
	print("── DamagePipelineStub ──")
	_setup_world()
	var ed := _make_enemy_data("E_STUB", 500.0)
	var enemy := _spawn_enemy_at(ed, Vector2(360, 640))
	# S×M×L×C×V 直算：S=100×1.2+10=130；M=1.5；L=1.3；C=2.0；V=0.75 → 380.25
	var ctx := DamageContext.make()
	ctx.source_uid = 1
	ctx.target = enemy
	ctx.target_uid = enemy.uid
	ctx.frame_stamp = GameConfig.frame_stamp
	ctx.base_atk = 100.0
	ctx.add_entries = [{"trait_id": &"A", "pool_id": &"add_atk", "layer": 1, "contrib": 0.2, "decay_delta": 0.85, "is_curse": false}]
	ctx.flat_bonus = 10.0
	ctx.mult_pools = [{"pool_id": &"m1", "source_uid": 1, "contrib": 0.5, "cap_pool": 2.0}]
	ctx.local_pools = [{"local_id": &"l1", "contrib": 0.3, "cap_local": 1.0}]
	ctx.crit_chance = 1.0
	ctx.crit_mult = 2.0
	ctx.element = GameConst.Element.KIN
	ctx.target_resist = 0.25
	ctx.pos = enemy.position
	var result: DamageResult = _pipeline.resolve(ctx)
	_check("桩公式：S×M×L×C×V = 380.25", is_equal_approx(result.final_value, 380.25),
		"got %s" % str(result.final_value))
	_check("桩暴击：crit_chance=1 → is_crit", result.is_crit)
	_check("桩 killed 投影：hp 500 > 380.25 → false", not result.killed)
	_check("桩字段回填：panel/mult/local/factor", is_equal_approx(result.panel_snapshot, 130.0)
		and is_equal_approx(result.mult_product, 1.5) and is_equal_approx(result.local_product, 1.3)
		and is_equal_approx(result.target_factor, 0.75))
	# 反应通道：HIT_IS_REACTION 不掷暴击（暴率 1.0 也被掩码跳过）
	var ctx2 := DamageContext.make()
	ctx2.target = enemy
	ctx2.base_atk = 100.0
	ctx2.crit_chance = 1.0
	ctx2.crit_mult = 2.0
	ctx2.hit_flags = GameConst.HIT_IS_REACTION
	var result2: DamageResult = _pipeline.resolve_reaction(ctx2)
	_check("桩反应通道：不掷暴击 → 100", _approx(result2.final_value, 100.0) and not result2.is_crit)
	_check("桩反应 feel_level = CATALYST", result2.feel_level == GameConst.FeelLevel.CATALYST)
	var st: Dictionary = _pipeline.stats()
	_check("桩 stats：settles ≥ 2", int(st["settles"]) >= 2)
	# 工厂：真件未合入 → 回退桩（接口齐备性）
	var made: RefCounted = DamagePipelineStub.get_pipeline()
	_check("工厂 get_pipeline()：真件未合入回退桩（接口齐备）",
		made != null and made.has_method(&"resolve") and made.has_method(&"begin_frame") and made.has_method(&"end_frame"))
	_teardown_world()


# ── 2. 接触伤害（Area2D 低频通道） ────────────────────────────────
func _test_contact_damage() -> void:
	print("── 接触伤害（Area2D） ──")
	_setup_world()
	var player_scene: PackedScene = load(PLAYER_SCENE)
	var player: Player = player_scene.instantiate()
	player.position = Vector2(360, 900)
	tree.get_root().add_child(player)
	await tree.process_frame
	await tree.physics_frame
	await tree.physics_frame
	var hp0: float = player.hp
	var ed := _make_enemy_data("E_TOUCH", 100.0)
	ed.dmg_base = 12.0
	var enemy := _spawn_enemy_at(ed, Vector2(360, 900))
	await tree.physics_frame
	await tree.physics_frame
	enemy.tick(DT)
	_check("接触伤害：玩家 HP 扣减（无敌帧首击生效）", is_equal_approx(player.hp, hp0 - 12.0),
		"hp %s → %s" % [str(hp0), str(player.hp)])
	var hp_after_first: float = player.hp
	enemy.tick(DT)
	enemy.tick(DT)
	_check("接触伤害：无敌帧内不再扣血", is_equal_approx(player.hp, hp_after_first))
	for i in range(80):
		player.tick(DT, Vector2.ZERO)
	enemy.tick(DT)
	_check("接触伤害：无敌帧过后再次扣血（contact_tick 0.6s）", is_equal_approx(player.hp, hp_after_first - 12.0),
		"got %s" % str(player.hp))
	player.free()
	_teardown_world()


# ── 3. 六大事件派发顺序 = 挂载序 ───────────────────────────────────
func _test_event_dispatch_order() -> void:
	print("── 六大事件派发顺序 ──")
	_setup_world()
	var ta := _make_recording_trait()
	var tb := _make_recording_trait()
	var tc := _make_recording_trait()
	ta.set("id", "A")
	tb.set("id", "B")
	tc.set("id", "C")
	var shared: Array = []                          # 三词条共享序列（验证挂载序交错）
	ta.set("shared", shared)
	tb.set("shared", shared)
	tc.set("shared", shared)
	var ed := _make_enemy_data("E_ORDER", 500.0)
	var enemy := _spawn_enemy_at(ed, Vector2(365, 640))
	# 挂载序 A→B→C；六事件全触发：SPAWN(0)/TICK(1)/HIT(2)/PIERCE(3)/BOUNCE(4)/EXPIRE(5)
	var proj := _spawn_ballistic({
		"position": Vector2(360, 640),
		"velocity": Vector2(100, 0),
		"lifetime": 10.0,
		"pierce": 2,
		"bounces": 1,
		"hitbox_radius": 6.0,
	}, [ta, tb, tc])
	proj.tick(DT)                                     # tick1：ON_TICK → ON_HIT → ON_PIERCE（pierce 2→1）
	proj.position = Vector2(3, 640)
	proj.velocity = Vector2(-100, 0)
	proj.tick(DT)                                     # tick2：ON_BOUNCE（左缘反射）→ ON_TICK
	proj.position = Vector2(360, 640)
	proj.velocity = Vector2(100, 0)
	proj.tick(DT)                                     # tick3：ON_TICK → ON_HIT → ON_EXPIRE（pierce 1→0 回收）
	var log_a: Array = ta.get("log") as Array
	var log_b: Array = tb.get("log") as Array
	var log_c: Array = tc.get("log") as Array
	var expected: Array = []
	for pair in [["A", 0], ["B", 0], ["C", 0],
			["A", 1], ["B", 1], ["C", 1],
			["A", 2], ["B", 2], ["C", 2],
			["A", 3], ["B", 3], ["C", 3],
			["A", 4], ["B", 4], ["C", 4],
			["A", 1], ["B", 1], ["C", 1],
			["A", 1], ["B", 1], ["C", 1],
			["A", 2], ["B", 2], ["C", 2],
			["A", 5], ["B", 5], ["C", 5]]:
		expected.append(str(pair[0]) + ":" + str(pair[1]))
	_check("六大事件派发顺序 = 挂载序（全序列一致）", shared == expected,
		"got %s" % str(shared))
	_check("三条词条各自命中全部事件（9 项/条）", log_a.size() == 9 and log_b.size() == 9 and log_c.size() == 9,
		"a=%s b=%s c=%s" % [str(log_a.size()), str(log_b.size()), str(log_c.size())])
	var seq_a: Array = []
	var seq_b: Array = []
	var seq_c: Array = []
	for e in log_a:
		seq_a.append(int(String(e).split(":")[1]))
	for e in log_b:
		seq_b.append(int(String(e).split(":")[1]))
	for e in log_c:
		seq_c.append(int(String(e).split(":")[1]))
	_check("三条词条事件序列一致（A=B=C）", seq_a == seq_b and seq_b == seq_c)
	_check("敌人被命中两次（穿透序）", _approx(enemy.hp, 500.0 - 20.0),
		"hp %s" % str(enemy.hp))
	_teardown_world()


# ── 4. 回收五路径统一收束 ─────────────────────────────────────────
func _test_recycle_paths() -> void:
	print("── 回收五路径 ──")
	_setup_world()
	var ed := _make_enemy_data("E_RECY", 500.0)
	var free0: int = _proj_pool.stats()["free"]
	# 路径 1：EXPIRED（寿命耗尽）
	var t1 := _make_recording_trait()
	t1.set("id", "T")
	var r0: int = DebugStats.get_counter(&"recycle_reason_0")
	var p1 := _spawn_ballistic({"position": Vector2(360, 640), "velocity": Vector2(100, 0),
		"lifetime": 0.05, "pierce": 1, "hitbox_radius": 6.0}, [t1])
	p1.tick(0.1)
	_check_recycled("EXPIRED", t1, p1, free0)
	_check("EXPIRED 原因计数 +1", DebugStats.get_counter(&"recycle_reason_0") == r0 + 1)
	# 路径 2：PIERCE_DEPLETED（穿透耗尽）
	var t2 := _make_recording_trait()
	t2.set("id", "T")
	var r1: int = DebugStats.get_counter(&"recycle_reason_1")
	_spawn_enemy_at(ed, Vector2(365, 640))
	var p2 := _spawn_ballistic({"position": Vector2(360, 640), "velocity": Vector2(100, 0),
		"lifetime": 10.0, "pierce": 1, "hitbox_radius": 6.0}, [t2])
	p2.tick(DT)
	_check_recycled("PIERCE_DEPLETED", t2, p2, free0)
	_check("PIERCE_DEPLETED 原因计数 +1", DebugStats.get_counter(&"recycle_reason_1") == r1 + 1)
	# 路径 3：BOUNCE_DEPLETED（反弹预算耗尽后触缘）
	var t3 := _make_recording_trait()
	t3.set("id", "T")
	var r2: int = DebugStats.get_counter(&"recycle_reason_2")
	var p3 := _spawn_ballistic({"position": Vector2(3, 640), "velocity": Vector2(-100, 0),
		"lifetime": 10.0, "pierce": 1, "bounces": 1, "hitbox_radius": 6.0}, [t3])
	p3.tick(DT)                                     # 第一次触缘：反射（bounces 1→0）
	_check("BOUNCE 路径：首次反弹 bounces_left 1→0", p3.bounces_left == 0)
	p3.position = Vector2(717, 640)
	p3.velocity = Vector2(100, 0)
	p3.tick(DT)                                     # 第二次触缘：预算耗尽 → BOUNCE_DEPLETED
	_check_recycled("BOUNCE_DEPLETED", t3, p3, free0)
	_check("BOUNCE_DEPLETED 原因计数 +1", DebugStats.get_counter(&"recycle_reason_2") == r2 + 1)
	# 路径 4：NULLIFIED（消弹）
	var t4 := _make_recording_trait()
	t4.set("id", "T")
	var r3: int = DebugStats.get_counter(&"recycle_reason_3")
	var p4 := _spawn_ballistic({"position": Vector2(360, 640), "velocity": Vector2(100, 0),
		"lifetime": 10.0, "pierce": 1, "hitbox_radius": 6.0}, [t4])
	p4.nullify()
	_check_recycled("NULLIFIED", t4, p4, free0)
	_check("NULLIFIED 原因计数 +1", DebugStats.get_counter(&"recycle_reason_3") == r3 + 1)
	# 路径 5：FORCED（池硬上限强制回收最老——池侧直收经 meta 收束）
	var t5 := _make_recording_trait()
	t5.set("id", "T")
	var r4: int = DebugStats.get_counter(&"recycle_reason_4")
	var p5 := _spawn_ballistic({"position": Vector2(360, 640), "velocity": Vector2(100, 0),
		"lifetime": 10.0, "pierce": 1, "hitbox_radius": 6.0}, [t5])
	_proj_pool.force_recycle_oldest()
	_check_recycled("FORCED", t5, p5, free0)
	_check("FORCED 原因计数 +1", DebugStats.get_counter(&"recycle_reason_4") == r4 + 1)
	_check("FORCED 池计数 +1", _proj_pool.forced_recycle_count == 1)
	_teardown_world()


func _check_recycled(p_name: String, p_trait: RefCounted, p_proj: BallisticProjectile, p_free_before: int) -> void:
	# E-04 顺序断言：OnExpire 派发期状态未清（velocity 非零/is_clean false/visible true）
	# → 派发后清零（velocity ZERO/is_clean true）→ 池归还（visible false/free +1）
	var log: Array = p_trait.get("log") as Array
	var obs: Dictionary = p_trait.get("expire_obs") as Dictionary
	_check("%s：OnExpire 已派发" % p_name, log.has("T:5"), "log=%s" % str(log))
	_check("%s：派发期状态未清（velocity 非零）" % p_name,
		(obs.get("velocity", Vector2.ZERO) as Vector2) != Vector2.ZERO, "obs=%s" % str(obs))
	_check("%s：派发期未清零（is_clean=false）" % p_name, bool(obs.get("is_clean", true)) == false)
	_check("%s：派发期未归还（visible=true）" % p_name, bool(obs.get("visible", false)) == true)
	_check("%s：清零后 velocity=ZERO" % p_name, p_proj.velocity == Vector2.ZERO)
	_check("%s：清零后 is_clean=true" % p_name, p_proj.is_clean)
	_check("%s：池归还 visible=false" % p_name, not p_proj.visible)
	_check("%s：池 free 计数 +1" % p_name, int(_proj_pool.stats()["free"]) == p_free_before + 1,
		"free=%s" % str(_proj_pool.stats()["free"]))


# ── 5. 穿透计数 / 反弹反射角镜像 ─────────────────────────────────
func _test_pierce_and_bounce() -> void:
	print("── 穿透/反弹 ──")
	_setup_world()
	var ed := _make_enemy_data("E_PIERCE", 1000.0)
	_spawn_enemy_at(ed, Vector2(365, 640))
	# 穿透计数递减：pierce=3 → 命中后 2 → 1 → 0（回收）
	var proj := _spawn_ballistic({"position": Vector2(360, 640), "velocity": Vector2(100, 0),
		"lifetime": 10.0, "pierce": 3, "hitbox_radius": 6.0})
	proj.tick(DT)
	_check("穿透计数递减：pierce 3→2", proj.pierce_left == 2, "got %d" % proj.pierce_left)
	_check("穿透后弹体存活（继续飞行）", proj.velocity != Vector2.ZERO and proj.visible)
	proj.tick(DT)
	proj.tick(DT)
	_check("穿透耗尽：pierce=3 三次命中后回收", proj.pierce_left == 0 and not proj.visible)
	# 反弹反射角镜像 < 2°（左缘：法线 (1,0)，理想镜像 = 速度 x 分量取反）
	var p2 := _spawn_ballistic({"position": Vector2(3, 640), "velocity": Vector2(-80, -60),
		"lifetime": 10.0, "pierce": 1, "bounces": 2, "hitbox_radius": 6.0})
	p2.tick(DT)
	var mirror := Vector2(80, -60)
	_check("反弹反射角镜像 < 2°（左缘）", p2.velocity.angle_to(mirror) < deg_to_rad(2.0),
		"v=%s mirror=%s" % [str(p2.velocity), str(mirror)])
	_check("反弹后 bounces_left 2→1", p2.bounces_left == 1)
	# 上缘：法线 (0,1)，理想镜像 = 速度 y 分量取反
	var p3 := _spawn_ballistic({"position": Vector2(360, 3), "velocity": Vector2(-80, -60),
		"lifetime": 10.0, "pierce": 1, "bounces": 2, "hitbox_radius": 6.0})
	p3.tick(DT)
	var mirror3 := Vector2(-80, 60)
	_check("反弹反射角镜像 < 2°（上缘）", p3.velocity.angle_to(mirror3) < deg_to_rad(2.0),
		"v=%s mirror=%s" % [str(p3.velocity), str(mirror3)])
	_teardown_world()


# ── 6. 同帧同目标去重（E-03） ─────────────────────────────────────
func _test_frame_dedup() -> void:
	print("── 帧聚合去重（E-03） ──")
	_setup_world()
	var ed := _make_enemy_data("E_DEDUP", 100.0)
	var enemy := _spawn_enemy_at(ed, Vector2(365, 640))
	var proj := _spawn_ballistic({"position": Vector2(360, 640), "velocity": Vector2(100, 0),
		"lifetime": 10.0, "pierce": 9, "hitbox_radius": 6.0})
	var settles0: int = int(_pipeline.stats()["settles"])
	proj._submit_hit(enemy)
	proj._submit_hit(enemy)                          # 同帧第二次提交 → 帧聚合拦截
	_check("同帧同目标去重：血量只扣一次", is_equal_approx(enemy.hp, 100.0 - 10.0),
		"hp %s" % str(enemy.hp))
	_check("同帧同目标去重：结算只发生一次", int(_pipeline.stats()["settles"]) == settles0 + 1)
	proj.tick(DT)                                    # 下一帧聚合清零 → 再命中
	_check("帧聚合跨帧清零：下一帧可再命中", is_equal_approx(enemy.hp, 100.0 - 20.0),
		"hp %s" % str(enemy.hp))
	_teardown_world()


# ── 7. Homing：角速度 clamp / 二段延时 / 重索敌 / AOE ─────────────
func _test_homing() -> void:
	print("── Homing ──")
	_setup_world()
	_homing_pool = _make_proj_pool(HOMING_SCENE, 8)
	var ed := _make_enemy_data("E_HOM", 500.0)
	var a := _spawn_enemy_at(ed, Vector2(700, 640))  # 目标在右侧远处（测试窗内不可达）
	# 二段延时：arm_delay 内直飞（方向不追踪）
	var proj := _acquire_homing({
		"position": Vector2(360, 640), "velocity": Vector2(0, -100),
		"lifetime": 10.0, "pierce": 999, "hitbox_radius": 6.0,
		"target_uid": a.uid, "arm_delay": 0.005,
		"speed_init": 100.0, "speed_max": 100.0, "accel": 0.0, "turn_rate": 480.0,
		"blast_radius": 0.0, "blast_falloff": 0.6,
	})
	proj.tick(DT)                                    # arm 期内
	_check("二段延时：arm 期内直飞（方向保持 UP）",
		proj.velocity.normalized().angle_to(Vector2.UP) < 0.01,
		"dir=%s" % str(proj.velocity.normalized()))
	proj.tick(DT)                                    # arm 过期后首帧追踪
	var turned := absf(proj.velocity.normalized().angle_to(Vector2.UP))
	_check("角速度 clamp：单帧转向 ≤ turn_rate×dt（4°）", turned <= deg_to_rad(4.0) + 0.001 and turned > 0.0,
		"turned=%f°" % rad_to_deg(turned))
	# 多帧追踪收敛至目标方向
	for i in range(120):
		proj.tick(DT)
	_check("追踪收敛：朝向目标方向（误差 < 2°）",
		proj.velocity.normalized().angle_to((a.global_position - proj.global_position).normalized()) < deg_to_rad(2.0))
	# 重索敌：目标死亡 0.2s 后重锁最近敌（期间保留原 uid）
	var b := _spawn_enemy_at(ed, Vector2(360, 760))  # 备选目标（下方）
	var kill := DamageResult.new()
	kill.final_value = 999.0
	a.take_result(kill)                              # 目标死亡（dead 短路）
	for i in range(14):                              # 0.117s < 0.2s：仍在重索倒计时
		proj.tick(DT)
	_check("目标丢失：0.2s 内不重锁（保留原 uid）", proj.target_uid == a.uid,
		"uid=%d a=%d" % [proj.target_uid, a.uid])
	for i in range(20):                              # 累计 > 0.2s：重索敌
		proj.tick(DT)
	_check("目标丢失重索敌：0.2s 后锁定新目标", proj.target_uid == b.uid,
		"uid=%d b=%d" % [proj.target_uid, b.uid])
	# AOE 委托：命中即爆炸（主目标全额 + 次级目标线性衰减）
	var ed2 := _make_enemy_data("E_AOE", 100.0)
	var primary := _spawn_enemy_at(ed2, Vector2(300.0 + 100.0 * DT, 640))
	var p2 := _acquire_homing({
		"position": Vector2(300, 640), "velocity": Vector2(100, 0),
		"lifetime": 10.0, "pierce": 1, "hitbox_radius": 6.0,
		"target_uid": primary.uid, "arm_delay": 0.0,
		"speed_init": 100.0, "speed_max": 100.0, "accel": 0.0, "turn_rate": 480.0,
		"blast_radius": 45.0, "blast_falloff": 0.4,
		"panel_snapshot": {"base_atk": 10.0},
	})
	var secondary := _spawn_enemy_at(ed2, Vector2(300.0 + 100.0 * DT + 27.0, 640))
	p2.tick(DT)                                     # 命中 primary → 爆炸 → 次级衰减 → 回收
	_check("AOE 委托：主目标全额伤害", is_equal_approx(primary.hp, 100.0 - 10.0),
		"hp=%s" % str(primary.hp))
	var expect_s := 100.0 - 10.0 * (1.0 - (1.0 - 0.4) * (27.0 / 45.0))
	_check("AOE 委托：次级目标线性衰减伤害", _approx(secondary.hp, expect_s, 0.01),
		"hp=%s expect=%s" % [str(secondary.hp), str(expect_s)])
	_check("AOE 后导弹回收（命中即亡）", not p2.visible)
	_teardown_world()


func _acquire_homing(p_params: Dictionary) -> HomingProjectile:
	var proj := _homing_pool.acquire() as HomingProjectile
	proj.damage_pipeline = _pipeline
	proj.enemy_grid = _grid
	proj.pool = _homing_pool
	proj.spawn(p_params.duplicate())
	return proj


# ── 8. Enemy：成长缩放/受击/死亡/击退/精英/Boss 阶段 ───────────────
func _test_enemy() -> void:
	print("── Enemy ──")
	_setup_world()
	var ed := _make_enemy_data("E_SCALE", 72.0)
	var e1 := _spawn_enemy_at(ed, Vector2(100, 100), 1)
	_check("成长 w1：hp=72", is_equal_approx(e1.hp, 72.0))
	var e3 := _spawn_enemy_at(ed, Vector2(100, 100), 3)
	_check("成长 w3：hp=72×1.12²=90.32", _approx(e3.hp, 72.0 * 1.12 * 1.12, 0.01))
	_check("成长 w3：spd=75×(1+0.008×2)=76.2", _approx(e3.speed, 75.0 * 1.016, 0.01))
	_check("成长 w3：dmg=8×1.06²=8.98", _approx(e3.contact_dmg, 8.0 * 1.06 * 1.06, 0.01))
	_check("成长 w3：exp=3×1.085²=3.53", _approx(e3.exp_value, 3.0 * 1.085 * 1.085, 0.01))
	# 抗性快照
	ed.resist = [0.3, 0.0, 0.0, 0.0]
	var er := _spawn_enemy_at(ed, Vector2(100, 100), 1)
	_check("抗性快照读取：KIN=0.3", is_equal_approx(er.get_resist(GameConst.Element.KIN), 0.3))
	_check("抗性快照读取：FIR=0", is_equal_approx(er.get_resist(GameConst.Element.FIR), 0.0))
	# 受击入口 take_result + 死亡广播（一次性）
	var kills0: int = int(_probe.get("enemy_killed_hits"))
	var r := DamageResult.new()
	r.final_value = 30.0
	er.take_result(r)
	_check("take_result 扣血：72−30=42", is_equal_approx(er.hp, 42.0),
		"hp=%s" % str(er.hp))
	_check("take_result 非致死不广播", int(_probe.get("enemy_killed_hits")) == kills0)
	var r_kill := DamageResult.new()
	r_kill.final_value = 999.0
	er.take_result(r_kill)
	_check("死亡广播 enemy_killed", int(_probe.get("enemy_killed_hits")) == kills0 + 1)
	_check("死亡短路标志 dead", er.dead)
	er.take_result(r_kill)
	_check("死亡只执行一次（E-06 短路）", int(_probe.get("enemy_killed_hits")) == kills0 + 1)
	# 击退
	var ek := _spawn_enemy_at(ed, Vector2(100, 100), 1)
	ek.knockback(Vector2(50, 0))
	_check("击退：位置位移 50px", is_equal_approx(ek.position.x, 150.0))
	# 精英模板乘区
	var elite_data := _make_enemy_data("E_ELITE", 72.0)
	elite_data.elite_mult = {"hp": 4.2, "spd": 0.92, "dmg": 1.5, "exp": 8.0}
	var ee := _enemy_pool.acquire() as Enemy
	ee.spawn(elite_data, 1, GameConst.TAG_ELITE)
	_check("精英模板：hp ×4.2 = 302.4", _approx(ee.hp, 72.0 * 4.2, 0.01),
		"hp=%s" % str(ee.hp))
	_check("精英判定 is_elite", ee.is_elite())
	# Boss 阶段（HP<50% → phase 2 + 全抗 +0.2）
	var boss_data := _make_enemy_data("E_BOSS", 100.0, 1.0, GameConst.TAG_BOSS)
	boss_data.boss = {"phase2_resist": 0.2}
	var eb := _enemy_pool.acquire() as Enemy
	eb.spawn(boss_data, 1, 0)
	eb.position = Vector2(400, 100)
	eb.tick(DT)
	eb.apply_damage(60.0)
	eb.tick(DT)
	_check("Boss 阶段：HP<50% → phase=2", eb.boss_phase == 2)
	_check("Boss 阶段2 全抗 +0.2", is_equal_approx(eb.get_resist(GameConst.Element.KIN), 0.2))
	_teardown_world()


# ── 9. Player：拖动/钳制/无敌帧/经验/死亡/武器槽 ─────────────────
func _test_player() -> void:
	print("── Player ──")
	var player_scene: PackedScene = load(PLAYER_SCENE)
	var player: Player = player_scene.instantiate()
	player.position = Vector2(360, 1000)
	tree.get_root().add_child(player)
	await tree.process_frame
	# 相对拖动（move_delta 直投 1:1）
	player.tick(DT, Vector2(50, 30))
	_check("相对拖动：位移 = 拖动向量（1:1）",
		is_equal_approx(player.position.x, 410.0) and is_equal_approx(player.position.y, 1030.0),
		"pos=%s" % str(player.position))
	# 零拖动向量为静止
	player.tick(DT, Vector2.ZERO)
	_check("零拖动向量为静止", is_equal_approx(player.position.x, 410.0))
	# 边界钳制（E-15 下 40% 屏 + 左右界）
	player.tick(DT, Vector2(-2000, -2000))
	_check("边界钳制：x ≥ hitbox_r", _approx(player.position.x, player.hitbox_radius, 0.01))
	_check("边界钳制：y ≥ 1280×0.6 = 768", _approx(player.position.y, 768.0, 0.01),
		"y=%s" % str(player.position.y))
	player.tick(DT, Vector2(2000, 2000))
	_check("边界钳制：y ≤ 1280−r", _approx(player.position.y, 1280.0 - player.hitbox_radius, 0.01))
	# 无敌帧（contact_tick = 0.6s）
	var hp0: float = player.hp
	var hits0: int = int(_probe.get("player_hit_hits"))
	player.take_contact_damage(10.0)
	_check("受击扣血：hp −10", is_equal_approx(player.hp, hp0 - 10.0))
	_check("player_hit 事件派发", int(_probe.get("player_hit_hits")) == hits0 + 1)
	player.take_contact_damage(10.0)
	player.take_contact_damage(10.0)
	_check("无敌帧内不受击（0.6s）", is_equal_approx(player.hp, hp0 - 10.0))
	for i in range(80):
		player.tick(DT, Vector2.ZERO)
	player.take_contact_damage(10.0)
	_check("无敌帧过期后可再受击", is_equal_approx(player.hp, hp0 - 20.0))
	# 经验/等级（14×lv^1.4）与升级事件
	var lv0: int = int(_probe.get("level_up_hits"))
	player.gain_xp(14.0)
	_check("升级：14 经验 → LV2 + level_up 事件", player.level == 2 and int(_probe.get("level_up_hits")) == lv0 + 1)
	_check("升级曲线：xp_need = 14×2^1.4 ≈ 36.94", _approx(player.xp_need, 14.0 * pow(2.0, 1.4), 0.01),
		"need=%s" % str(player.xp_need))
	player.gain_xp(100.0)                           # 63.06 < 65.18 → 连升一级停在 LV3
	_check("多级连升：xp 100 → LV3（余量不足 LV4）", player.level == 3 and player.xp < player.xp_need,
		"lv=%d xp=%s need=%s" % [player.level, str(player.xp), str(player.xp_need)])
	# 死亡事件（只一次）——先退无敌帧再补致死一击
	var died0: int = int(_probe.get("player_died_hits"))
	for i in range(80):
		player.tick(DT, Vector2.ZERO)
	player.take_contact_damage(99999.0)
	_check("死亡事件 player_died 派发", int(_probe.get("player_died_hits")) == died0 + 1)
	player.take_contact_damage(99999.0)
	_check("死亡后不再受击/重复广播", int(_probe.get("player_died_hits")) == died0 + 1 and is_equal_approx(player.hp, 0.0))
	_check("get_hp_pct：死亡 → 0", is_equal_approx(player.get_hp_pct(), 0.0))
	player.free()
	# 武器槽（5 槽，槽 1 解锁初始）+ duck-typing 武器 tick + 槽位事件解锁
	var player2: Player = player_scene.instantiate()
	player2.position = Vector2(360, 1000)
	tree.get_root().add_child(player2)
	await tree.process_frame
	var ws := GDScript.new()
	ws.source_code = "extends Node\nvar ticks: int = 0\nfunc tick(_d: float) -> void:\n\tticks += 1\n"
	ws.reload()
	var weapons: Array[Node] = []
	for i in range(6):
		var w: Node = Node.new()
		w.set_script(ws)
		weapons.append(w)
	_check("武器槽：槽 1 可装备", player2.equip_weapon(weapons[0]))
	_check("武器槽：槽 2 未解锁拒绝", not player2.equip_weapon(weapons[1]))
	player2.unlock_slot(3)
	_check("武器槽：解锁至 3 后可装 2 把", player2.equip_weapon(weapons[1]) and player2.equip_weapon(weapons[2]))
	player2.tick(DT, Vector2.ZERO)
	_check("自动开火调度：武器 duck-typing tick 被调用",
		int(weapons[0].get("ticks")) == 1 and int(weapons[1].get("ticks")) == 1 and int(weapons[2].get("ticks")) == 1)
	var slots0: int = int(_probe.get("slot_unlocked_hits"))
	EventBus.emit_slot_unlocked(5)
	await tree.process_frame
	_check("slot_unlocked 事件驱动解锁至 5", int(_probe.get("slot_unlocked_hits")) == slots0 + 1 and player2.unlocked_slots == 5)
	_check("解锁 5 后装满 5 槽", player2.equip_weapon(weapons[3]) and player2.equip_weapon(weapons[4]))
	_check("5 槽全满拒绝第 6 把", not player2.equip_weapon(weapons[5]))
	player2.free()


# ── 10. WaveDirector / EnemySpawner ──────────────────────────────
func _test_waves() -> void:
	print("── WaveDirector/Spawner ──")
	# 公式 fallback（无表）：TP = 14 + 3.2w；精英波 ×1.25；无尽段 110×1.03^(w−30)
	var env := _setup_wave_env(null)
	var director: WaveDirector = env["director"]
	var spawner: EnemySpawner = env["spawner"]
	director.start_wave(1)
	_check("TP 公式（无表）：w1 = 17.2", _approx(director.tp_budget, 17.2))
	_check("波窗口公式：w1 = 18.4s", _approx(director.window_left, 18.4))
	_check("wave_started 事件：w1", int(_probe.get("last_wave_started")) == 1)
	_check("公式构成：w1 → 17 只杂兵入队", spawner.queue_count() == 17,
		"queue=%d" % spawner.queue_count())
	director.start_wave(8)
	_check("TP 公式（无表）：精英波 w8 = 39.6×1.25 = 49.5", _approx(director.tp_budget, 49.5),
		"got %s" % str(director.tp_budget))
	director.start_wave(35)
	_check("无尽段 TP：w35 = 110×1.03^5 ≈ 127.53", _approx(director.tp_budget, 110.0 * pow(1.03, 5.0)))
	_teardown_wave_env(env)
	# 表驱动：wave 5 表条目（G×20 + R×8，tp_override=0 → 公式 TP；窗口表值）
	var table := WaveTableData.new()
	var entry := WaveEntryData.new()
	entry.index = 5
	entry.composition = [{"enemy_id": "E1", "count": 20}, {"enemy_id": "E2", "count": 8}]
	entry.tp_override = 0.0
	entry.window = 20.0
	table.entries = [entry]
	var env2 := _setup_wave_env(table)
	var director2: WaveDirector = env2["director"]
	var spawner2: EnemySpawner = env2["spawner"]
	director2.start_wave(5)
	_check("表驱动：tp_override≤0 → 公式 TP = 30", _approx(director2.tp_budget, 30.0))
	_check("表驱动：窗口取表值 20s", _approx(director2.window_left, 20.0))
	_check("表驱动：构成 = 20+8 = 28 条入队", spawner2.queue_count() == 28,
		"queue=%d" % spawner2.queue_count())
	# 单帧 ≤8 节流
	spawner2.tick(DT, null)
	_check("生成节流：单帧 ≤ 8", spawner2.active_count() == 8, "active=%d" % spawner2.active_count())
	_teardown_wave_env(env2)
	# 同屏 ≤120 排队（直接驱动 spawner——独立于导演节拍可测）
	var env3 := _setup_wave_env(null)
	var spawner3: EnemySpawner = env3["spawner"]
	for i in range(200):
		spawner3.enqueue({"data_id": &"E1", "wave": 1, "tags": 0})
	for i in range(40):
		spawner3.tick(DT, null)
	_check("同屏上限：active = 120（余 80 排队）",
		spawner3.active_count() == 120 and spawner3.queue_count() == 80,
		"active=%d queue=%d" % [spawner3.active_count(), spawner3.queue_count()])
	_teardown_wave_env(env3)
	# 波次清空 + 缓冲 + 自动下一波（表窗口 0.5s 加速）
	var quick := WaveTableData.new()
	var qe := WaveEntryData.new()
	qe.index = 1
	qe.composition = [{"enemy_id": "E1", "count": 5}]
	qe.window = 0.5
	quick.entries = [qe]
	var env4 := _setup_wave_env(quick)
	var director4: WaveDirector = env4["director"]
	var spawner4: EnemySpawner = env4["spawner"]
	director4.start_wave(1)
	for i in range(8):
		director4.tick(DT)
	_check("加速波：5 敌全部入场", spawner4.active_count() == 5)
	# 击杀全部（spawner 订阅 enemy_killed → 池归还）
	var act: Array = []
	for e in spawner4.active:
		act.append(e)
	for e in act:
		var rk := DamageResult.new()
		rk.final_value = 99999.0
		(e as Enemy).take_result(rk)
	_check("击杀后活跃清零（池归还路径）", spawner4.active_count() == 0)
	var cleared0: int = int(_probe.get("wave_cleared_hits"))
	for i in range(80):
		director4.tick(DT)
		if int(_probe.get("wave_cleared_hits")) > cleared0:
			break
	_check("wave_cleared 事件（窗口过 + 清场）", int(_probe.get("wave_cleared_hits")) == cleared0 + 1
		and int(_probe.get("last_wave_cleared")) == 1)
	var started0: int = int(_probe.get("wave_started_hits"))
	for i in range(700):
		director4.tick(DT)                          # 缓冲 4s（1+3）→ 自动下一波
		if int(_probe.get("wave_started_hits")) > started0:
			break
	_check("波间缓冲后自动开下一波（wave_started(2)）",
		int(_probe.get("wave_started_hits")) > started0 and int(_probe.get("last_wave_started")) == 2)
	_teardown_wave_env(env4)
	# Boss 波：Boss 入场事件 + 伴随怪流水（场上 ≤12）
	var env5 := _setup_wave_env(null)
	var director5: WaveDirector = env5["director"]
	var spawner5: EnemySpawner = env5["spawner"]
	var registry5: DataRegistry = env5["registry"]
	registry5.enemies[&"BOSS_1"] = _make_enemy_data("BOSS_1", 5000.0, 16.0, GameConst.TAG_BOSS)
	director5.start_wave(10)
	var boss0: int = int(_probe.get("boss_spawned_hits"))
	director5.tick(DT)
	_check("Boss 波：boss_spawned 事件派发", int(_probe.get("boss_spawned_hits")) == boss0 + 1)
	var active_after_boss: int = spawner5.active_count()
	for i in range(1300):                           # 10.8s：伴随怪流水（×1/2.5s 场上≤12）
		director5.tick(DT)
	_check("Boss 波伴随怪流水：场上 > boss+1", spawner5.active_count() > active_after_boss,
		"active=%d→%d" % [active_after_boss, spawner5.active_count()])
	_check("Boss 波伴随怪上限 ≤ 12", spawner5.active_count() <= 12)
	_teardown_wave_env(env5)


func _setup_wave_env(p_table: WaveTableData) -> Dictionary:
	var pool := EnemyPool.new()
	pool.name = "WaveEnemyPool"
	tree.get_root().add_child(pool)
	pool.setup(&"enemy", load(ENEMY_SCENE), 140)
	var spawner := EnemySpawner.new()
	spawner.name = "WaveSpawner"
	tree.get_root().add_child(spawner)
	spawner.pool = pool
	var registry := DataRegistry.new()
	registry.enemies[&"E1"] = _make_enemy_data("E1", 72.0, 1.0)
	registry.enemies[&"E2"] = _make_enemy_data("E2", 40.0, 1.2)
	spawner.registry = registry
	var director := WaveDirector.new()
	director.name = "WaveDirectorNode"
	tree.get_root().add_child(director)
	director.spawner = spawner
	director.registry = registry
	director.wave_table = p_table
	return {"pool": pool, "spawner": spawner, "director": director, "registry": registry}


func _teardown_wave_env(p_env: Dictionary) -> void:
	(p_env["director"] as WaveDirector).free()
	(p_env["spawner"] as EnemySpawner).free()
	(p_env["pool"] as EnemyPool).free()


# ── 11. 池零实例化运行（acquire/release 复用） ────────────────────
func _test_pool_zero_instantiate() -> void:
	print("── 池零实例化 ──")
	var pool := _make_proj_pool(BALLISTIC_SCENE, 4)
	pool.prewarm(4)
	var st: Dictionary = pool.stats()
	_check("预热：free=4 / capacity=4", st["free"] == 4 and st["capacity"] == 4)
	var grid := SpaceGrid.new()
	grid.configure(Vector2(720, 1280), 192.0)
	var pipeline := DamagePipelineStub.new()
	for i in range(10):
		var proj := pool.acquire() as BallisticProjectile
		proj.damage_pipeline = pipeline
		proj.enemy_grid = grid
		proj.pool = pool
		proj.spawn({"position": Vector2(360, 640), "velocity": Vector2(100, 0),
			"lifetime": 5.0, "pierce": 1, "hitbox_radius": 6.0})
		proj.nullify()                              # 统一收束归还（五路径之一）
	st = pool.stats()
	_check("10 轮 acquire/release 复用：hits=10 / live=0 / free=4",
		st["hits"] == 10 and st["live"] == 0 and st["free"] == 4, "st=%s" % str(st))
	_check("池零实例化运行（runtime_instantiate = 0）", pool.runtime_instantiate_count == 0)
	_check("池零污染（pollution = 0）", pool.pollution_count == 0)
	pool.free()

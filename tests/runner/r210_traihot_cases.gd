# tests/runner/r210_traihot_cases.gd
# R210 用例体：vc17 真机弹段 9-12ms 两刀验收。
# 刀A=TraitStack.has_event_hook 静态挂钩闸（无挂钩事件分发直通——ON_TICK 数据侧
#   零挂钩，词条弹每帧字典+TraitContext 分配+全词条虚调用纯空转）；
# 刀B=窄相/敌弹判定的反射 get → 类型化直取（Enemy.hitbox_r/uid、Player.hitbox_radius）。
# 回归红线：词条弹 ON_HIT 伤害链分毫未动（真武器+真词条实弹打真敌）。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const DT60 := 1.0 / 60.0
const PLAYER_HOME := Vector2(360.0, 900.0)

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_boot_game_loop()
	await tree.process_frame
	await tree.process_frame
	_test_1_has_event_hook()
	_test_2_dispatch_gate()
	_test_3_typed_access()
	await _test_4_traited_damage_intact()
	_teardown_game_loop()
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


func _boot_game_loop() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "R210GameLoopUnderTest"
	tree.get_root().add_child(_gl)
	_gl.state = GameConst.GameStatus.MENU
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	_gl.start_run()
	_gl.state = GameConst.GameStatus.MENU
	_gl.player.global_position = PLAYER_HOME


func _teardown_game_loop() -> void:
	tree.paused = false
	RunSave.clear()
	if _gl != null:
		_gl.free()
		_gl = null


func _trait_data(p_id: String, p_hooks: Array, p_pool: int, p_effect: StringName) -> TraitData:
	var d := TraitData.new()
	d.id = StringName(p_id)
	d.display_name = p_id
	d.pool = p_pool
	d.value = 0.1
	d.stack_max = 5
	var hooks: Array[int] = []               # event_hooks 为 Array[int] 导出——字面量直赋类型不符
	for h in p_hooks:
		hooks.append(int(h))
	d.event_hooks = hooks
	d.effect_id = p_effect
	return d


# ── ① has_event_hook 语义（on_event 静态闸门同口径） ──
func _test_1_has_event_hook() -> void:
	print("── ① has_event_hook ──")
	var s_empty := TraitStack.new()
	_check("空栈任意事件 false", not s_empty.has_event_hook(GameConst.TraitEvent.ON_TICK)
		and not s_empty.has_event_hook(GameConst.TraitEvent.ON_HIT), "")
	var s_hit := TraitStack.new()
	s_hit.attach(_trait_data("T_R210_HIT", [GameConst.TraitEvent.ON_HIT],
		GameConst.PoolClass.ADD, &"EF_STAT"))
	_check("ON_HIT 挂钩栈：ON_HIT true / ON_TICK false（vc17 主犯事件）",
		s_hit.has_event_hook(GameConst.TraitEvent.ON_HIT)
			and not s_hit.has_event_hook(GameConst.TraitEvent.ON_TICK), "")
	var s_mult := TraitStack.new()
	s_mult.attach(_trait_data("T_R210_MULT", [GameConst.TraitEvent.ON_HIT],
		GameConst.PoolClass.MULT, &"EF_STAT"))
	_check("MULT 声明性池不入闸（on_event 池前 return 同口径）",
		not s_mult.has_event_hook(GameConst.TraitEvent.ON_HIT), "")
	var s_noeffect := TraitStack.new()
	s_noeffect.attach(_trait_data("T_R210_NOEF", [GameConst.TraitEvent.ON_TICK],
		GameConst.PoolClass.ADD, &""))
	_check("effect 解析失败的词条不入闸（effect 前置 return 同口径）",
		not s_noeffect.has_event_hook(GameConst.TraitEvent.ON_TICK), "")
	# 缓存失效：负缓存后再挂 ON_TICK 词条 → 立即翻正（attach 清缓存）
	s_hit.attach(_trait_data("T_R210_TICK", [GameConst.TraitEvent.ON_TICK],
		GameConst.PoolClass.ADD, &"EF_STAT"))
	_check("attach 后缓存失效重算（ON_TICK false→true）",
		s_hit.has_event_hook(GameConst.TraitEvent.ON_TICK), "")
	s_hit.clear()
	_check("clear 后回 false", not s_hit.has_event_hook(GameConst.TraitEvent.ON_HIT)
		and not s_hit.has_event_hook(GameConst.TraitEvent.ON_TICK), "")


# ── ② 分发闸：无挂钩事件直通（不建 ctx），有挂钩照常 ──
func _test_2_dispatch_gate() -> void:
	print("── ② 分发闸 ──")
	var pool := _gl.pools[&"projectile"] as ProjectilePool
	var proj := pool.acquire() as ProjectileBase
	proj.spawn({"pos": PLAYER_HOME, "velocity": Vector2(0.0, -300.0), "team": 0})
	# 无词条：既有直通（R188 契约原样）
	var r0: TraitContext = proj._dispatch_event(GameConst.TraitEvent.ON_TICK, {"game_delta": DT60})
	_check("无词条弹：null（R188 契约不回归）", r0 == null, "r0=%s" % str(r0))
	# 有词条无 ON_TICK 挂钩：直通 null（刀A——不分配 TraitContext）
	proj.trait_stack = TraitStack.new()
	proj.trait_stack.attach(_trait_data("T_R210_HIT", [GameConst.TraitEvent.ON_HIT],
		GameConst.PoolClass.ADD, &"EF_STAT"))
	var r1: TraitContext = proj._dispatch_event(GameConst.TraitEvent.ON_TICK, {"game_delta": DT60})
	_check("ON_HIT 栈 ON_TICK 事件：直通 null（每帧空转分配掐除）", r1 == null,
		"r1=%s" % str(r1))
	# 有 ON_TICK 挂钩：照常分发返回 ctx
	proj.trait_stack.attach(_trait_data("T_R210_TICK", [GameConst.TraitEvent.ON_TICK],
		GameConst.PoolClass.ADD, &"EF_STAT"))
	var r2: TraitContext = proj._dispatch_event(GameConst.TraitEvent.ON_TICK, {"game_delta": DT60})
	_check("真挂钩事件：照常分发（返回 TraitContext）", r2 is TraitContext,
		"r2=%s" % str(r2))
	pool.release(proj)


# ── ③ 刀B 类型化判定：与反射口径逐位等价 + 分支真走 ──
func _test_3_typed_access() -> void:
	print("── ③ 类型化判定 ──")
	var epool := _gl.pools[&"enemy"] as EnemyPool
	var enemy := epool.acquire() as Enemy
	enemy.spawn(_fixture_enemy(), 1, 0)
	enemy.global_position = PLAYER_HOME + Vector2(0.0, -100.0)
	var pool := _gl.pools[&"projectile"] as ProjectilePool
	var proj := pool.acquire() as ProjectileBase
	proj.spawn({"pos": PLAYER_HOME, "velocity": Vector2(0.0, -300.0), "team": 0})
	# Enemy 分支：hitbox_r=14 → reach=10+14=24 → 距离 23 真 / 25 假（边界逐位）
	proj.global_position = enemy.global_position + Vector2(23.0, 0.0)
	var near_hit: bool = proj._in_reach(enemy, 10.0)
	proj.global_position = enemy.global_position + Vector2(25.0, 0.0)
	var far_hit: bool = proj._in_reach(enemy, 10.0)
	_check("Enemy 分支读真 hitbox_r（23≤10+14 真 / 25>24 假）",
		near_hit and not far_hit,
		"near=%s far=%s" % [str(near_hit), str(far_hit)])
	# 非 Enemy 桩：get 回 null → 0 半径同口径（同距离下敌真桩假）
	var stub := Node2D.new()
	tree.get_root().add_child(stub)
	stub.global_position = enemy.global_position
	proj.global_position = enemy.global_position + Vector2(23.0, 0.0)
	var stub_hit: bool = proj._in_reach(stub, 10.0)
	_check("非 Enemy 桩回落反射路径（无 hitbox_r → 半径 0 → 23>10 假）",
		not stub_hit, "stub_hit=%s" % str(stub_hit))
	stub.free()
	# 敌弹 × 玩家：Player 分支 hitbox_radius 真值判定（清出生无敌帧——Q-16 闸不遮口径）
	var pproj := pool.acquire() as ProjectileBase
	pproj.spawn({"velocity": Vector2.ZERO, "team": 1})
	pproj.global_position = PLAYER_HOME + Vector2(0.0, -20.0)   # spawn 不吃 pos 键（落位显式设）
	pproj.panel_snapshot = {"base_atk": 5.0}
	_gl.player.set("invuln_left", 0.0)
	_gl.player.set("shield_interval", 0.0)    # 关格挡力场（就绪盾吞接触伤=血量不动的夹具干扰）
	var hp0: float = float(_gl.player.get("hp"))
	pproj._check_player_hit()
	var hp1: float = float(_gl.player.get("hp"))
	_check("敌弹接触真玩家走类型化 hitbox_radius（20≤16+弹径 触发扣血）",
		hp1 < hp0, "hp %f→%f" % [hp0, hp1])
	pool.release(pproj)
	pool.release(proj)
	_gl.spawner.active.erase(enemy)
	epool.release(enemy)


func _fixture_enemy() -> EnemyData:
	var d := EnemyData.new()
	d.id = &"E_R210_CASE"
	d.display_name = "E_R210_CASE"
	d.hp_base = 1000.0
	d.spd_base = 0.0
	d.dmg_base = 0.0
	d.exp_base = 1.0
	d.hitbox_r = 14.0
	d.resist = [0.0, 0.0, 0.0, 0.0]
	return d


# ── ④ 回归红线：真武器+真词条实弹打真敌（ON_HIT 链分毫未动） ──
func _test_4_traited_damage_intact() -> void:
	print("── ④ 词条伤害链 ──")
	var w := _gl.player.add_weapon(_gl.registry.get_weapon(&"W1_pistol"))
	_check("手枪装配（前置）", w != null, "")
	if w == null:
		return
	w.trait_stack.attach(_trait_data("T_R210_DMG", [GameConst.TraitEvent.ON_HIT],
		GameConst.PoolClass.ADD, &"EF_STAT"))
	var epool := _gl.pools[&"enemy"] as EnemyPool
	var enemy := epool.acquire() as Enemy
	enemy.spawn(_fixture_enemy(), 1, 0)
	enemy.global_position = PLAYER_HOME + Vector2(0.0, -220.0)
	_gl.spawner.active.append(enemy)
	var hp0: float = enemy.hp
	for i in range(150):                      # 2.5s 实弹（冷却+命中+词条全链）
		_gl.player.tick(DT60, Vector2.ZERO)
		_gl.enemy_grid.rebuild(_gl.spawner.active)
		_gl._tick_projectiles(DT60)
		for e in _gl.spawner.active:
			if is_instance_valid(e):
				(e as Enemy).tick(DT60)
		_gl.popup_manager.tick(DT60)
		_gl.game_feel.tick(DT60)
		EventBus.end_frame()
	_check("词条弹实弹命中（2.5s 内 hp 下降——ON_HIT 伤害链经分发闸后完好）",
		is_instance_valid(enemy) and enemy.hp < hp0,
		"hp %f→%s" % [hp0, str(enemy.hp if is_instance_valid(enemy) else -1)])
	if is_instance_valid(enemy):
		_gl.spawner.active.erase(enemy)
		epool.release(enemy)

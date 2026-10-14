# tests/test_r225_tick_cases.gd
# R225 弹tick侧刀用例体（入口 test_r225_tick.gd 运行时加载）。
# 锁机制契约而非实现细节：以自定义 SpyEffect（TraitEffect.register_custom 测试注册口，
# trait_effect.gd:42 官方扩展点）按事件计数派发——不读弹侧私有字段。
# 刀契约（R225，projectile_base.gd）：
#   · ON_TICK 派发闸 spawn 期 armed 快照——armed=false（栈无 ON_TICK 挂钩）时 tick 不再
#     构建 payload 字典（原每弹每帧死分配）；armed=true 走原路径；
#   · 回旋刃接触内冷清扫两段化（去 keys() 每帧分配）——0.4s 内冷节拍语义逐位一致；
#   · 回收原因计数键查表——DebugStats 键名逐一同名。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const DT60 := 1.0 / 60.0
const PLAYER_HOME := Vector2(360.0, 900.0)
const SPY_EFFECT_ID := &"EF_R225_SPY"          # 测试注册口自定义效果（运行期仅本套件注册）

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null
var _spy: SpyEffect = null


# 按事件计数的测试效果（handle 无实例状态副作用；计数器供断言）
class SpyEffect extends TraitEffect:
	var counts: Dictionary = {}               # TraitEvent -> int
	var last_delta: float = -1.0

	func handle(p_trait: TraitBase, p_ctx: TraitContext) -> void:
		var ev := int(p_ctx.event)
		counts[ev] = int(counts.get(ev, 0)) + 1
		last_delta = float(p_ctx.game_delta)

	func reset() -> void:
		counts.clear()
		last_delta = -1.0

	func n(p_event: int) -> int:
		return int(counts.get(p_event, 0))


# 直挂数组通道载体（on_event 鸭子接口——qa_r220_simchain ③a 同款 spawn 后注入路径）
class DirectHook extends RefCounted:
	var fired: int = 0

	func on_event(p_event: int, p_ctx: TraitContext) -> void:
		if int(p_event) == GameConst.TraitEvent.ON_TICK:
			fired += 1


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_boot_game_loop()
	_spy = SpyEffect.new()
	TraitEffect.register_custom(SPY_EFFECT_ID, _spy)
	await tree.process_frame
	_test_1_armed_dispatch()
	_test_2_unarmed_passthrough()
	_test_3_other_events_untouched()
	_test_4_pool_reuse_rearm()
	_test_5_boomerang_icd_cadence()
	_test_6_recycle_reason_keys()
	_test_7_plain_projectile_baseline()
	_test_8_direct_channel_live()
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
	_gl.name = "R225TickGameLoopUnderTest"
	tree.get_root().add_child(_gl)
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	_gl.start_run()
	_gl.state = GameConst.GameStatus.MENU
	_gl.player.global_position = PLAYER_HOME
	# 负载类夹具铁律：xp 封顶防选卡窗冲刷（本套件手动逐弹 tick 不驱动 _physics_process，
	# 仍按纪律封顶——boot 期引擎帧可能推进一步）
	_gl.player.set("xp_need", 1.0e12)
	_gl.player.set("max_hp", 1.0e12)
	_gl.player.set("hp", 1.0e12)


func _teardown_game_loop() -> void:
	tree.paused = false
	RunSave.clear()
	if _gl != null:
		_gl.free()
		_gl = null


# ── 夹具 ──────────────────────────────────────────────────────────

func _trait_data(p_id: String, p_hooks: Array, p_effect: StringName) -> TraitData:
	var d := TraitData.new()
	d.id = StringName(p_id)
	d.display_name = p_id
	d.pool = GameConst.PoolClass.ADD
	d.value = 0.1
	d.stack_max = 5
	var hooks: Array[int] = []                # event_hooks 为 Array[int] 导出——逐项转制
	for h in p_hooks:
		hooks.append(int(h))
	d.event_hooks = hooks
	d.effect_id = p_effect
	return d


func _fixture_enemy() -> EnemyData:
	var d := EnemyData.new()
	d.id = &"E_R225_TICK"
	d.display_name = "E_R225_TICK"
	d.hp_base = 1.0e9                         # 巨血防杀（零伤结算链路稳定）
	d.spd_base = 0.0
	d.dmg_base = 0.0
	d.exp_base = 1.0
	d.hitbox_r = 14.0
	d.resist = [0.0, 0.0, 0.0, 0.0]
	return d


func _spawn_enemy_at(p_pos: Vector2) -> Enemy:
	var epool := _gl.pools[&"enemy"] as EnemyPool
	var enemy := epool.acquire() as Enemy
	enemy.spawn(_fixture_enemy(), 1, 0)
	enemy.global_position = p_pos
	_gl.spawner.active.append(enemy)          # 网格重建数据源（手动 rebuild，不驱动 loop）
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	return enemy


func _release_enemy(p_enemy: Enemy) -> void:
	_gl.spawner.active.erase(p_enemy)
	(_gl.pools[&"enemy"] as EnemyPool).release(p_enemy)


func _spawn_proj(p_params: Dictionary, p_pos: Vector2) -> ProjectileBase:
	# 投射物 spawn 不吃 pos 键——落位 spawn 后显式赋值（实测坑③）
	var pool := _gl.pools[&"projectile"] as ProjectilePool
	var proj := pool.acquire() as ProjectileBase
	proj.spawn(p_params)
	proj.global_position = p_pos
	return proj


func _bump_frame() -> void:
	# 手动逐弹 tick 不驱动 GameLoop——E-03 帧闸（_last_trigger_frame == frame_stamp）
	# 需手动推进帧号，否则同帧第二次触发被吞
	GameConfig.frame_stamp += 1


# ── ① armed 路径：栈声明 ON_TICK 挂钩 → tick 逐帧派发照常 ──────────
func _test_1_armed_dispatch() -> void:
	print("── ① armed 派发（ON_TICK 挂钩栈） ──")
	_spy.reset()
	# 栈经 spawn 参数传入（真实链路=武器侧 spawn 契约键；armed 快照在 spawn 期计算）
	var stack := TraitStack.new()
	stack.attach(_trait_data("T_R225_TICK", [GameConst.TraitEvent.ON_TICK], SPY_EFFECT_ID))
	var proj := _spawn_proj({"velocity": Vector2.ZERO, "lifetime": 5.0,
		"trait_stack": stack}, PLAYER_HOME)
	for i in range(3):
		_bump_frame()
		proj.tick(DT60)
	_check("armed：3 次 tick → ON_TICK 恰 3 次派发（真挂钩零回归）",
		_spy.n(GameConst.TraitEvent.ON_TICK) == 3,
		"n=%d" % _spy.n(GameConst.TraitEvent.ON_TICK))
	_check("armed：game_delta 透传（payload 键契约）",
		absf(_spy.last_delta - DT60) < 0.0001,
		"delta=%f" % _spy.last_delta)
	(_gl.pools[&"projectile"] as ProjectilePool).release(proj)


# ── ② unarmed 路径：无 ON_TICK 挂钩栈 → ON_TICK 零派发 ────────────
func _test_2_unarmed_passthrough() -> void:
	print("── ② unarmed 直通（R210 闸契约） ──")
	_spy.reset()
	var proj := _spawn_proj({"velocity": Vector2(0.0, -60.0), "lifetime": 5.0}, PLAYER_HOME)
	proj.trait_stack = TraitStack.new()
	proj.trait_stack.attach(_trait_data("T_R225_HIT", [GameConst.TraitEvent.ON_HIT],
		SPY_EFFECT_ID))
	_bump_frame()
	proj.tick(DT60)
	_check("unarmed：tick 期 ON_TICK 零派发（死分配来源段）",
		_spy.n(GameConst.TraitEvent.ON_TICK) == 0,
		"n=%d" % _spy.n(GameConst.TraitEvent.ON_TICK))
	_check("unarmed：ON_TICK 分发请求直通 null（R210 has_event_hook 闸不回归）",
		proj._dispatch_event(GameConst.TraitEvent.ON_TICK,
			{"game_delta": DT60}) == null, "")
	(_gl.pools[&"projectile"] as ProjectilePool).release(proj)


# ── ③ 非 ON_TICK 事件零扰动：ON_SPAWN/ON_HIT/ON_EXPIRE 计数精确 ────
func _test_3_other_events_untouched() -> void:
	print("── ③ 非 ON_TICK 事件零扰动 ──")
	_spy.reset()
	# 敌与弹同位（距离 0 < 窄相 reach 6+14）——接触带内首 tick 必命中
	var enemy := _spawn_enemy_at(PLAYER_HOME)
	var stack := TraitStack.new()
	stack.attach(_trait_data("T_R225_MIX",
		[GameConst.TraitEvent.ON_SPAWN, GameConst.TraitEvent.ON_HIT,
			GameConst.TraitEvent.ON_EXPIRE], SPY_EFFECT_ID))
	var proj := _spawn_proj({"velocity": Vector2(0.0, -10.0), "lifetime": 0.05,
		"pierce": 3, "trait_stack": stack}, PLAYER_HOME)   # 数 tick 内寿命过期；pierce 3 首命中不回收
	proj.enemy_grid = _gl.enemy_grid          # 命中通道注入（武器侧同款接线 ballistic_weapon:333）
	for i in range(5):                        # 过期后多 tick 由 not _live 早退兜底（计数仍精确）
		_bump_frame()
		proj.tick(DT60)
	_check("ON_SPAWN 恰 1（spawn 期派发不受刀影响）",
		_spy.n(GameConst.TraitEvent.ON_SPAWN) == 1,
		"n=%d" % _spy.n(GameConst.TraitEvent.ON_SPAWN))
	_check("ON_HIT 恰 1（接触带 R196 生命周期去重下不重击）",
		_spy.n(GameConst.TraitEvent.ON_HIT) == 1,
		"n=%d" % _spy.n(GameConst.TraitEvent.ON_HIT))
	_check("ON_EXPIRE 恰 1（寿命过期回收派发不受刀影响）",
		_spy.n(GameConst.TraitEvent.ON_EXPIRE) == 1,
		"n=%d" % _spy.n(GameConst.TraitEvent.ON_EXPIRE))
	_check("ON_TICK 零派发（ unarmed 栈混挂三事件亦不误派）",
		_spy.n(GameConst.TraitEvent.ON_TICK) == 0,
		"n=%d" % _spy.n(GameConst.TraitEvent.ON_TICK))
	_release_enemy(enemy)


# ── ④ 池复用 armed 快照重算（spawn 期重算——池复用不串弹） ──────────
func _test_4_pool_reuse_rearm() -> void:
	print("── ④ 池复用 armed 重算 ──")
	_spy.reset()
	var pool := _gl.pools[&"projectile"] as ProjectilePool
	var stack_arm := TraitStack.new()
	stack_arm.attach(_trait_data("T_R225_ARM", [GameConst.TraitEvent.ON_TICK], SPY_EFFECT_ID))
	var proj := pool.acquire() as ProjectileBase
	proj.spawn({"velocity": Vector2.ZERO, "lifetime": 5.0, "trait_stack": stack_arm})
	proj.global_position = PLAYER_HOME
	_bump_frame()
	proj.tick(DT60)
	var armed_count := _spy.n(GameConst.TraitEvent.ON_TICK)
	pool.release(proj)                        # 单次归还（池化纪律：勿二次 release）
	var stack_noarm := TraitStack.new()
	stack_noarm.attach(_trait_data("T_R225_NOARM", [GameConst.TraitEvent.ON_HIT],
		SPY_EFFECT_ID))
	var proj2 := pool.acquire() as ProjectileBase
	proj2.spawn({"velocity": Vector2.ZERO, "lifetime": 5.0, "trait_stack": stack_noarm})
	proj2.global_position = PLAYER_HOME
	for i in range(2):
		_bump_frame()
		proj2.tick(DT60)
	_check("复用件换 unarmed 栈：ON_TICK 计数停在归还前值（armed 不跨生残留）",
		_spy.n(GameConst.TraitEvent.ON_TICK) == armed_count,
		"armed=%d now=%d" % [armed_count, _spy.n(GameConst.TraitEvent.ON_TICK)])
	pool.release(proj2)


# ── ⑤ 回旋刃接触内冷清扫语义等价（0.4s 内冷节拍不变） ──────────────
func _test_5_boomerang_icd_cadence() -> void:
	print("── ⑤ 回旋刃 ICD 节拍 ──")
	_spy.reset()
	var enemy := _spawn_enemy_at(PLAYER_HOME + Vector2(0.0, -40.0))
	# 低速回旋刃叠在敌上：漂移 <5px，恒在接触带（6+14=20px）内——节拍纯由 ICD 决定。
	# δ=0.2（0.4−0.2 二进制精确、无残差）——旧 keys() 实现与新 sweep 实现算术逐位同源。
	var stack := TraitStack.new()
	stack.attach(_trait_data("T_R225_BOOM", [GameConst.TraitEvent.ON_HIT], SPY_EFFECT_ID))
	var proj := _spawn_proj({"velocity": Vector2(10.0, 0.0), "lifetime": 5.0,
		"boomerang": true, "trait_stack": stack}, enemy.global_position)
	proj.enemy_grid = _gl.enemy_grid
	for i in range(6):                        # 1.2s：BOOM_HIT_ICD=0.4 → t≈0.2/0.6/1.0 三跳
		_bump_frame()
		proj.tick(0.2)
	_check("回旋刃 0.4s 内冷节拍不变（6×0.2s → 恰 3 次结算）",
		_spy.n(GameConst.TraitEvent.ON_HIT) == 3,
		"n=%d" % _spy.n(GameConst.TraitEvent.ON_HIT))
	_release_enemy(enemy)


# ── ⑥ 回收原因计数键同名等价（DebugStats 口径不变） ────────────────
func _test_6_recycle_reason_keys() -> void:
	print("── ⑥ 回收原因计数键 ──")
	var pool := _gl.pools[&"projectile"] as ProjectilePool
	var c0 := DebugStats.get_counter(&"recycle_reason_0")
	var proj := pool.acquire() as ProjectileBase
	proj.spawn({"velocity": Vector2.ZERO, "lifetime": 0.001})
	proj.global_position = PLAYER_HOME
	proj.tick(DT60)                           # 寿命过期 → EXPIRED=0
	_check("EXPIRED → recycle_reason_0 恰 +1（查表键同名）",
		DebugStats.get_counter(&"recycle_reason_0") == c0 + 1,
		"before=%d after=%d" % [c0, DebugStats.get_counter(&"recycle_reason_0")])
	var c3 := DebugStats.get_counter(&"recycle_reason_3")
	var proj2 := pool.acquire() as ProjectileBase
	proj2.spawn({"velocity": Vector2.ZERO, "lifetime": 5.0})
	proj2.global_position = PLAYER_HOME
	proj2.nullify()                           # NULLIFIED=3（M-08 消弹路径）
	_check("NULLIFIED → recycle_reason_3 恰 +1（查表键同名）",
		DebugStats.get_counter(&"recycle_reason_3") == c3 + 1,
		"before=%d after=%d" % [c3, DebugStats.get_counter(&"recycle_reason_3")])


# ── ⑦ 无词条弹运动/回收基线（armed=false 零扰动） ──────────────────
func _test_7_plain_projectile_baseline() -> void:
	print("── ⑦ 无词条弹基线 ──")
	var pool := _gl.pools[&"projectile"] as ProjectilePool
	var recycled0 := DebugStats.get_counter(&"projectile_recycled")
	var proj := pool.acquire() as ProjectileBase
	proj.spawn({"velocity": Vector2(0.0, -300.0), "lifetime": 5.0})
	proj.global_position = PLAYER_HOME
	_bump_frame()
	proj.tick(DT60)
	var moved := proj.global_position.distance_to(PLAYER_HOME)
	_check("无词条弹匀速位移（300px/s × 1/60s = 5px）",
		absf(moved - 5.0) < 0.5, "moved=%f" % moved)
	pool.release(proj)
	var proj2 := pool.acquire() as ProjectileBase
	proj2.spawn({"velocity": Vector2.ZERO, "lifetime": 5.0})
	proj2.global_position = Vector2(-500.0, -500.0)   # 屏外（含 96px 余量）
	_bump_frame()
	proj2.tick(DT60)                          # 出界 → EXPIRED 回收
	_check("无词条弹出界回收照常（projectile_recycled +1）",
		DebugStats.get_counter(&"projectile_recycled") == recycled0 + 1,
		"before=%d after=%d" % [recycled0, DebugStats.get_counter(&"projectile_recycled")])


# ── ⑧ 直挂数组通道 live 判定（spawn 后注入照常触发——simchain ③a 契约） ──
func _test_8_direct_channel_live() -> void:
	print("── ⑧ 直挂通道 live 判定 ──")
	var pool := _gl.pools[&"projectile"] as ProjectilePool
	var proj := pool.acquire() as ProjectileBase
	proj.spawn({"velocity": Vector2.ZERO, "lifetime": 5.0})   # spawn 时无栈无直挂 → armed=false
	proj.global_position = PLAYER_HOME
	var hook := DirectHook.new()
	proj.set("_traits_cache", [hook])         # spawn 后注入（测试/过渡通道——非快照可见面）
	_bump_frame()
	proj.tick(DT60)
	_check("直挂通道 spawn 后注入：ON_TICK 照常触发（live 判定保旧路径）",
		hook.fired == 1, "fired=%d" % hook.fired)
	pool.release(proj)

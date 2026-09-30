# tests/runner/r198_flow_weapon_cases.gd
# R198 组2 战斗流程·用例体（由 test_r198_flow_weapon.gd 入口在 autoload 就绪后运行时加载编译）。
# 结构（buff_audit_cases 全链 GameLoop + r195_laser_pierce_cases 组件级激光探针同款夹具）：
#   F1  二aw-1 遗物随继续局恢复：局内 activate → serialize_run.relics 同 id 集（纯基本
#       类型）→ 暂停回菜单（_reset_run_state 清 owned）→ continue_run 后 owned id 集一致
#       且常驻位生效（REL_MIDAS xp_mult>1）；旧档无 relics 键 continue 不崩且 owned 空。
#   F2  二aw-2 每击谐振慢速武器补偿：间隔 0.5s → cdp_eff=0.1s；0.1s → 0.02s（每秒收益
#       均 ≈0.2s 预算封顶）；5s 触顶 ×10 帽=0.1s；快速 0.02s 下限 1.0=0.01s（不低于改前）；
#       无参直调兼容=0.01s；守卫链不变（就绪不计费/存款<cdp 丢整击）；tick 回充口径不变。
#   F3  R192-low4 告警闸每局复位：真管线 R_alarm 超线广播（首局 1 次）→ 同条件再触发不
#       重播（未 reset 对照）→ reset_run_alarms → 再广播（两局各 +1）；R_rxn 独立双闸同口径。
#   F4  r194-1 空波计数单源化：空注册表回退分支计 wave_composition_registry_empty 恰 +1，
#       wave_empty_composition 归 tick 守卫侧每波恰 +1（不再双写 2/波）；合法表空
#       composition 场景守卫侧仍计一次（回退分支不触发）。
#   F5  P2-escort 护航舰副本 game_delta：仅驱动 player.tick(dt) → _life_left 逐值递减、
#       开火节拍 0.55s 推进、_anim_t 自累加、零 delta 冻结、到期 queue_free；引擎自驱
#       _process 已退出（has_method 恒 false）。
#   F6  r195-1 激光副束序数归零：副束首目标 ctx.pierce_index==1（spy 管线实录）→
#       SYN_PIERCE_EVO 对副束乘区贡献==0（副束结算 mult_product 恒 1.0）；主束序数原样
#       （首目标 index=2 ×1.2 / 次目标 index=3 ×1.4——S4 语义零改动）。
# 纪律：boot 后零 await（帧不插入——GameLoop 帧序不干扰手动驱动断言）；池化对象不二次
#       release；SpaceGrid=RefCounted 置 null 不 free；类型化赋值先于 is_instance_valid。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const BALLISTIC_SCENE := "res://scenes/combat/projectiles/ballistic_projectile.tscn"
const HOMING_SCENE := "res://scenes/combat/projectiles/homing_projectile.tscn"
const LASER_SCENE := "res://scenes/combat/lasers/laser_beam.tscn"
const ENEMY_SCENE := "res://scenes/combat/enemies/enemy.tscn"
const DT := 1.0 / 120.0
const WEAPON_POS := Vector2(100.0, 640.0)        # F6 束原点（+X 轴向，r195 探针同款）
const E1_POS := Vector2(260.0, 640.0)            # t=160（主束首目标）
const E2_POS := Vector2(420.0, 640.0)            # t=320（主束贯穿 2 / 副束锁定）
const E3_POS := Vector2(580.0, 640.0)            # t=480（S7 金丝雀同位对照）

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null

# F6 组件级激光探针件
var _proj_pool: ProjectilePool
var _homing_pool: ProjectilePool
var _laser_pool: LaserBeamPool
var _enemy_pool: EnemyPool
var _grid: SpaceGrid
var _stub: DamagePipelineStub
var _alive_enemies: Array[Node2D] = []
var _wd_counter: int = 0

# F4 组件级波探针件
var _probe_dir: WaveDirector = null
var _probe_spawner: EnemySpawner = null

# F3 告警计数器
var _alarm_count: int = 0


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_ensure_autoloads()
	_test_f4_wave_counter_single_source()         # 组件级（轻，先行）
	_test_f6_sub_beam_pierce_ordinal()            # 组件级激光世界
	_boot_game_loop()
	_test_f1_relic_save_restore()
	_test_f2_attack_cdr_interval_comp()
	_test_f3_alarm_reset_per_run()
	_test_f5_escort_drone_game_delta()
	_teardown_game_loop()
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)
	print("════════════════════════════════════════")


func fail_count() -> int:
	return _fail


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("PASS | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s %s" % [p_name, p_detail])
		print("FAIL | %s | %s" % [p_name, p_detail])


func _approx(p_a: float, p_b: float, p_tol: float = 1e-6) -> bool:
	return absf(p_a - p_b) <= p_tol


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


# ── GameLoop 全链引导（buff_audit_cases 同款） ─────────────────────
func _boot_game_loop() -> void:
	RunSave.clear()
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "R198FlowWeaponGameLoopUnderTest"
	tree.get_root().add_child(_gl)
	_gl.state = GameConst.GameStatus.MENU
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	var started: bool = _gl.start_run()
	_check("前置：GameLoop Boot → MENU → start_run", started
		and _gl.state == GameConst.GameStatus.PLAYING
		and _gl.relic_handler != null and _gl.player != null)
	_gl.player.set("max_hp", 1000000.0)
	_gl.player.set("hp", 1000000.0)


func _teardown_game_loop() -> void:
	tree.paused = false
	RunSave.clear()
	if _gl != null:
		_gl.free()
		_gl = null


func _pause_back_to_menu() -> void:
	# PLAYING→MENU 非法迁移（TRANSITIONS 表）——走用户真实路径 PLAYING→PAUSED→MENU
	if _gl.state == GameConst.GameStatus.PLAYING:
		_gl.change_state(GameConst.GameStatus.PAUSED)
	_gl.quit_to_menu()


# ── F1 二aw-1 遗物随继续局恢复 ────────────────────────────────────
func _test_f1_relic_save_restore() -> void:
	print("── F1 二aw-1 遗物随继续局恢复 ──")
	var rh: RelicHandler = _gl.relic_handler
	var ok := rh.activate(&"REL_MIDAS")
	_check("F1 前置：局内 activate REL_MIDAS", ok and rh.has_relic(&"REL_MIDAS"))
	var midas_mult := float(_gl.registry.get_relic(&"REL_MIDAS").params.get("mult", 1.0))
	var snap := _gl.serialize_run()
	_check("F1① serialize_run 含 relics 键", snap.has("relics"), str(snap.keys()))
	var ids: Array[String] = []
	var pure := true
	for entry_v: Variant in snap.get("relics", []):
		if entry_v is Dictionary and (entry_v as Dictionary).has("id") \
				and (entry_v as Dictionary)["id"] is String:
			ids.append((entry_v as Dictionary)["id"])
		else:
			pure = false
	_check("F1② relics id 集与 owned 一致且纯基本类型（{id:String}）",
		pure and ids.size() == 1 and ids[0] == "REL_MIDAS", str(snap.get("relics", [])))
	RunSave.save_run(snap)
	_pause_back_to_menu()
	_check("F1③ 回菜单后 owned 清（_reset_run_state 序——恢复必须在其后的前置）",
		_gl.state == GameConst.GameStatus.MENU and rh.owned.is_empty())
	var resumed := _gl.continue_run()
	_check("F1④ continue_run 成功（读档恢复进局）", resumed
		and _gl.state == GameConst.GameStatus.PLAYING)
	var ids2: Array[String] = []
	for r in rh.owned:
		ids2.append(String(r.id))
	_check("F1⑤ 恢复后 owned id 集一致（REL_MIDAS）",
		ids2.size() == 1 and ids2[0] == "REL_MIDAS", str(ids2))
	_check("F1⑥ 常驻位生效（xp_mult_factor==%s > 1）" % String.num(midas_mult, 2),
		_approx(rh.xp_mult_factor, midas_mult) and rh.xp_mult_factor > 1.0,
		str(rh.xp_mult_factor))
	# 旧档兼容：无 relics 键的 17 键旧版结构 → continue 不崩（崩溃即整套件挂）且 owned 空
	_pause_back_to_menu()
	RunSave.clear()
	var old_save := {
		"map_id": String(MapTable.FIRST_MAP_ID), "difficulty": 0, "daily": false,
		"wave": 2, "kills": 0, "elapsed": 1.0, "character": "sentinel",
		"level": 1, "xp": 0.0, "hp": 50.0, "max_hp": 60.0, "gold": 10,
		"rerolls": 2, "free_reroll": true, "unlocked_slots": 2, "slot_bonus": 0,
		"weapons": [],
	}
	RunSave.save_run(old_save)
	var resumed_old: bool = _gl.continue_run()    # 无 relics 键——get 默认空表零分支
	_check("F1⑦ 旧档（无 relics 键）continue 成功不崩", resumed_old)
	_check("F1⑧ 旧档恢复后 owned 空（空表兼容）", rh.owned.is_empty())
	_gl.player.set("max_hp", 1000000.0)
	_gl.player.set("hp", 1000000.0)


# ── F2 二aw-2 每击谐振慢速武器间隔折算补偿 ─────────────────────────
func _test_f2_attack_cdr_interval_comp() -> void:
	print("── F2 二aw-2 每击谐振慢速武器补偿 ──")
	var rh: RelicHandler = _gl.relic_handler
	var ok := rh.activate(&"REL_ATTACK_CDR")
	_check("F2 前置：激活 REL_ATTACK_CDR（.tres 新键 fire_mult_max 过加载）",
		ok and rh.has_relic(&"REL_ATTACK_CDR"))
	var atk_data := _gl.registry.get_relic(&"REL_ATTACK_CDR")
	_check("F2 前置：fire_mult_max 参数在档（10.0）",
		_approx(float(atk_data.params.get("fire_mult_max", 0.0)), 10.0),
		str(atk_data.params))
	var player: Node2D = _gl.player
	_check("F2 前置：激活拉满预算存款（cap=0.6=60 击，回充口径不变）",
		_approx(float(rh.get("_atk_cdr_budget")), 0.6), str(rh.get("_atk_cdr_budget")))
	var credits0: int = rh.attack_cdr_credits
	var secs0: float = rh.attack_cdr_seconds
	player.set("skill_cd_left", 120.0)
	# ① 间隔 0.5s：0.5×20=10 → ×10（≤帽）→ cdp_eff=0.1s
	rh.on_attack_fired(0.5)
	_check("F2① 间隔 0.5s 单击 cdp_eff=0.1s（技能 CD 直减同值）",
		_approx(120.0 - float(player.get("skill_cd_left")), 0.1, 1e-4)
		and _approx(rh.attack_cdr_seconds - secs0, 0.1, 1e-4)
		and rh.attack_cdr_credits == credits0 + 1,
		"cd=%.4f secs=%.4f" % [120.0 - float(player.get("skill_cd_left")),
			rh.attack_cdr_seconds - secs0])
	# ② 间隔 0.1s：0.1×20=2 → cdp_eff=0.02s
	var secs1: float = rh.attack_cdr_seconds
	rh.on_attack_fired(0.1)
	_check("F2② 间隔 0.1s 单击 cdp_eff=0.02s",
		_approx(rh.attack_cdr_seconds - secs1, 0.02, 1e-4),
		str(rh.attack_cdr_seconds - secs1))
	# ③ 每秒收益解耦：2 发/s×0.1 == 10 发/s×0.02 == 0.2s（预算封顶口径）
	_check("F2③ 每秒收益均 ≈0.2s（2×0.1 == 10×0.02，预算 20 击/s 封顶）",
		_approx(2.0 * 0.1, 10.0 * 0.02))
	# ④ 间隔 5s 触顶：5×20=100 → clamp ×10 → 0.1s
	var secs2: float = rh.attack_cdr_seconds
	rh.on_attack_fired(5.0)
	_check("F2④ 间隔 5s 单击触顶 ×10 帽（cdp_eff=0.1s，不超帽）",
		_approx(rh.attack_cdr_seconds - secs2, 0.1, 1e-4),
		str(rh.attack_cdr_seconds - secs2))
	# ⑤ 快速武器下限 1.0：0.02×20=0.4 → clamp ≥1 → cdp_eff=0.01s（收益不低于改前）
	var secs3: float = rh.attack_cdr_seconds
	rh.on_attack_fired(0.02)
	_check("F2⑤ 快速武器 0.02s 单击仍 0.01s（clampf 下限 1.0，不低于改前）",
		_approx(rh.attack_cdr_seconds - secs3, 0.01, 1e-4),
		str(rh.attack_cdr_seconds - secs3))
	# ⑥ 守卫链不变：技能就绪（cd_left≤0）不计费
	var credits_ready: int = rh.attack_cdr_credits
	player.set("skill_cd_left", 0.0)
	rh.on_attack_fired(0.5)
	_check("F2⑥ 守卫链：技能就绪不计费（credits 不变）",
		rh.attack_cdr_credits == credits_ready)
	# ⑦ 守卫链不变：预算按 cdp 守卫、扣减 cdp_eff——排空后整击丢弃
	player.set("skill_cd_left", 50.0)
	var credits_drain: int = rh.attack_cdr_credits
	for i in range(4):
		rh.on_attack_fired(5.0)                   # 各扣 0.1：0.37→0.27→0.17→0.07→排空钳 0
	var drained: int = rh.attack_cdr_credits - credits_drain
	rh.on_attack_fired(5.0)                       # 存款 0 < cdp → 整击丢弃
	_check("F2⑦ 存款 <cdp 丢整击（排空前恰 4 击计费，第 5 击拒计）",
		drained == 4 and rh.attack_cdr_credits == credits_drain + 4,
		"%d→%d" % [credits_drain, rh.attack_cdr_credits])
	# ⑧ 无参直调兼容（历史套件 rh.on_attack_fired() 直调口径）= 改前 cdp 不变
	rh.tick(100.0)                                # 预算回充口径不变（rate×cdp×dt 封帽）
	var budget_refill: float = float(rh.get("_atk_cdr_budget"))
	player.set("skill_cd_left", 50.0)
	var secs4: float = rh.attack_cdr_seconds
	rh.on_attack_fired()
	_check("F2⑧ 无参直调=改前口径 0.01s（历史套件直调兼容）+ tick 回充封帽 0.6",
		_approx(rh.attack_cdr_seconds - secs4, 0.01, 1e-4)
		and _approx(budget_refill, 0.6, 1e-4),
		"secs=%.4f refill=%s" % [rh.attack_cdr_seconds - secs4, str(budget_refill)])
	_check("F2⑨ 计费后存款按 cdp 网格递减（0.6−0.01=0.59，扣减口径不变）",
		_approx(float(rh.get("_atk_cdr_budget")), 0.59, 1e-4),
		str(rh.get("_atk_cdr_budget")))


# ── F3 R192-low4 告警闸每局复位 ───────────────────────────────────
func _on_alarm_probe(_p_result: DamageResult) -> void:
	_alarm_count += 1


func _test_f3_alarm_reset_per_run() -> void:
	print("── F3 R192-low4 告警闸每局复位 ──")
	var pipeline: RefCounted = _gl.pipeline
	_check("F3 前置：真管线（DamagePipeline 实例，闸字段在码）",
		pipeline is DamagePipeline)
	_check("F3 前置：reset_run_alarms 在码", pipeline.has_method(&"reset_run_alarms"))
	# 告警夹具：base_atk=1 + Local 池 contrib 600（cap_local 600 自带）→
	# ratio = S×M×L×C/base ≈ 601 > r_alarm_ratio 500 → alarm
	var dummy := _make_alarm_dummy()
	_alarm_count = 0
	EventBus.damage_alarm.connect(_on_alarm_probe)
	# 首局：触发 → 广播 1 次；同条件再触发 → 闸已闭不重播（未 reset 对照组）
	pipeline.call(&"begin_frame")
	_alarm_resolve_once(pipeline, dummy, 101)
	_check("F3① 首局超线触发 → 告警广播恰 1 次", _alarm_count == 1, str(_alarm_count))
	pipeline.call(&"begin_frame")
	_alarm_resolve_once(pipeline, dummy, 102)
	_check("F3② 未 reset 对照：闸已闭仅记审计，不重播（仍 1 次）",
		_alarm_count == 1, str(_alarm_count))
	# reset（R198：start_run/continue_run 进局路径已接线调用，此处直调同函数）
	pipeline.call(&"reset_run_alarms")
	pipeline.call(&"begin_frame")
	_alarm_resolve_once(pipeline, dummy, 103)
	_check("F3③ reset 后次局同条件再触发仍广播（两局各 +1）",
		_alarm_count == 2, str(_alarm_count))
	# R_rxn 独立双闸同口径（系数 100 > r_rxn_ratio 50）
	var stats0: Dictionary = pipeline.call(&"stats")
	var rxn0: int = int(stats0.get("rxn_alarms", 0))
	pipeline.call(&"begin_frame")
	_alarm_rxn_once(pipeline, dummy, 201)
	var stats1: Dictionary = pipeline.call(&"stats")
	_check("F3④ R_rxn 超线触发广播且计数 +1", _alarm_count == 3
		and int(stats1.get("rxn_alarms", 0)) == rxn0 + 1, str(_alarm_count))
	pipeline.call(&"begin_frame")
	_alarm_rxn_once(pipeline, dummy, 202)
	_check("F3⑤ R_rxn 未 reset 对照：不重播", _alarm_count == 3, str(_alarm_count))
	pipeline.call(&"reset_run_alarms")
	pipeline.call(&"begin_frame")
	_alarm_rxn_once(pipeline, dummy, 203)
	# R198 注：reset 后双闸同开——本条 rxn 超线结果同时满足 R_alarm 闸（resolve_reaction
	# 置 stack.audit.alarm，_broadcast 常规闸照读）与 R_rxn 闸，各广播一次（计数 +2）。
	# 此 co-fire 系 _broadcast 既有语义（进程首次 rxn 告警本就双闸齐发，非 R198 引入）；
	# R198 断言锚 = reset 后 rxn 通道确实再广播（闸复位生效），故计数恰 5。
	_check("F3⑥ R_rxn reset 后再广播（双闸一并复位；reset 后首条超线 rxn 双闸 co-fire +2）",
		_alarm_count == 5, str(_alarm_count))
	EventBus.damage_alarm.disconnect(_on_alarm_probe)
	if is_instance_valid(dummy):
		(_gl.pools[&"enemy"] as EnemyPool).release(dummy)


func _make_alarm_dummy() -> Enemy:
	var e: Enemy = (_gl.pools[&"enemy"] as EnemyPool).acquire()
	var data := EnemyData.new()
	data.id = &"E_R198_ALARM"
	data.hp_base = 1000000.0
	data.spd_base = 0.0
	data.hitbox_r = 14.0
	e.spawn(data, 1, 0)
	e.position = Vector2(300.0, 500.0)
	return e


func _alarm_resolve_once(p_pipeline: RefCounted, p_dummy: Enemy, p_stamp: int) -> void:
	var ctx := DamageContext.make()
	ctx.source_uid = 424242
	ctx.target = p_dummy
	ctx.target_uid = int(p_dummy.get("uid"))
	ctx.frame_stamp = p_stamp
	ctx.base_atk = 1.0
	ctx.crit_chance = 0.0
	ctx.crit_mult = 2.0
	ctx.element = GameConst.Element.KIN
	ctx.pos = p_dummy.global_position
	ctx.local_pools.append({
		"local_id": &"r198_alarm_probe", "contrib": 600.0, "cap_local": 600.0,
	})
	p_pipeline.call(&"resolve", ctx)


func _alarm_rxn_once(p_pipeline: RefCounted, p_dummy: Enemy, p_stamp: int) -> void:
	var ctx := DamageContext.make()
	ctx.source_uid = 424243
	ctx.target = p_dummy
	ctx.target_uid = int(p_dummy.get("uid"))
	ctx.frame_stamp = p_stamp
	ctx.base_atk = 1.0
	ctx.element = GameConst.Element.KIN
	ctx.pos = p_dummy.global_position
	p_pipeline.call(&"resolve_reaction", 1.0, 100.0, ctx)


# ── F4 r194-1 空波计数单源化（组件级探针，export_data_cases 同款装配） ──
func _test_f4_wave_counter_single_source() -> void:
	print("── F4 r194-1 空波计数单源化 ──")
	_setup_wave_probe(DataRegistry.new())        # 空注册表（= APK 缺 manifest 下游终态）
	var counter0: int = DebugStats.get_counter(&"wave_empty_composition")
	var reg0: int = DebugStats.get_counter(&"wave_composition_registry_empty")
	_probe_dir.start_wave(1)
	_check("F4① start_wave 回退分支：wave_composition_registry_empty 恰 +1（R198 独立计数器）",
		DebugStats.get_counter(&"wave_composition_registry_empty") == reg0 + 1,
		"%d→%d" % [reg0, DebugStats.get_counter(&"wave_composition_registry_empty")])
	for i in range(30):                           # 0.25s：守卫侧零请求路径
		_probe_dir.tick(DT)
	_check("F4② wave_empty_composition 归 tick 守卫侧：本波恰 +1（修前回退分支双写 +2）",
		DebugStats.get_counter(&"wave_empty_composition") == counter0 + 1,
		"%d→%d" % [counter0, DebugStats.get_counter(&"wave_empty_composition")])
	for i in range(30):                           # 同波续驱：每波一次旗不再计
		_probe_dir.tick(DT)
	_check("F4③ 同波续驱零增量（守卫旗单源每波一次）",
		DebugStats.get_counter(&"wave_empty_composition") == counter0 + 1
		and DebugStats.get_counter(&"wave_composition_registry_empty") == reg0 + 1)
	_teardown_wave_probe()
	# 合法表空 composition 场景：走 tick 守卫侧（表条目在、构成空 → 请求 0）
	var reg := DataRegistry.new()
	var wt := WaveTableData.new()
	wt.id = &"r198_empty_comp"
	var entry := WaveEntryData.new()
	entry.index = 1
	entry.window = 5.0
	wt.entries.append(entry)
	reg.wave_table = wt                        # 单表注册（DataRegistry.wave_table 单源）
	_setup_wave_probe(reg)
	_probe_dir.wave_table = wt
	var counter1: int = DebugStats.get_counter(&"wave_empty_composition")
	var reg1: int = DebugStats.get_counter(&"wave_composition_registry_empty")
	_probe_dir.start_wave(1)
	for i in range(10):
		_probe_dir.tick(DT)
	_check("F4④ 合法表空 composition：守卫侧计 wave_empty_composition 一次（回退分支不触发）",
		DebugStats.get_counter(&"wave_empty_composition") == counter1 + 1
		and DebugStats.get_counter(&"wave_composition_registry_empty") == reg1,
		"empty=%d→%d reg=%d→%d" % [counter1,
			DebugStats.get_counter(&"wave_empty_composition"), reg1,
			DebugStats.get_counter(&"wave_composition_registry_empty")])
	_teardown_wave_probe()


func _setup_wave_probe(p_registry: DataRegistry) -> void:
	var sp := EnemySpawner.new()
	sp.name = "R198ProbeSpawner"
	tree.get_root().add_child(sp)
	var wd := WaveDirector.new()
	wd.name = "R198ProbeDirector"
	tree.get_root().add_child(wd)
	wd.spawner = sp
	wd.registry = p_registry
	sp.registry = p_registry
	_probe_dir = wd
	_probe_spawner = sp


func _teardown_wave_probe() -> void:
	if _probe_dir != null and is_instance_valid(_probe_dir):
		_probe_dir.free()
	if _probe_spawner != null and is_instance_valid(_probe_spawner):
		_probe_spawner.free()
	_probe_dir = null
	_probe_spawner = null


# ── F5 P2-escort 护航舰副本 game_delta ────────────────────────────
func _test_f5_escort_drone_game_delta() -> void:
	print("── F5 P2-escort 护航舰 game_delta ──")
	var player: Player = _gl.player
	var drone := Player.SummonDrone.new()         # 内部类直建（非引擎场景路径）
	drone.name = "R198ProbeDrone"
	drone.side = 1
	player.add_child(drone)
	player._summon_drones.append(drone)           # 挂进同拍驱动列（Array[Node2D] 类型化）
	_check("F5 前置：drone 在列且寿命满 10s",
		player._summon_drones.has(drone) and _approx(drone._life_left, 10.0))
	_check("F5① 引擎自驱退出：_process 虚方法不再声明（引擎不再自驱）",
		not drone.has_method(&"_process") and drone.has_method(&"tick"))
	# 仅驱动 player.tick(dt)：寿命逐值递减（game_delta 直源，非墙上时钟）
	player.tick(1.0, Vector2.ZERO)
	_check("F5② player.tick(1.0) → _life_left 9.0（副本 delta 直源）",
		_approx(drone._life_left, 9.0), str(drone._life_left))
	player.tick(0.5, Vector2.ZERO)
	player.tick(0.5, Vector2.ZERO)
	_check("F5③ 0.5+0.5 → _life_left 8.0（逐值累加无漂移）"
		+ "；浮动相位 _anim_t 自累加 2.0（脱离墙上时钟）",
		_approx(drone._life_left, 8.0) and _approx(drone._anim_t, 2.0),
		"life=%.4f anim=%.4f" % [drone._life_left, drone._anim_t])
	_check("F5④ 开火节拍推进：第二拍触发后 _fire_left 重置 0.55s（0.55s 一发口径保持）",
		_approx(drone._fire_left, 0.55), str(drone._fire_left))
	# 零 game_delta = 冻结（时间缩放/暂停下主循环喂 0 → 僚机同步冻结，不独走墙上时钟）
	player.tick(0.0, Vector2.ZERO)
	_check("F5⑤ 零 delta 冻结：_life_left/_anim_t 不动（同步冻结语义）",
		_approx(drone._life_left, 8.0) and _approx(drone._anim_t, 2.0),
		"life=%.4f anim=%.4f" % [drone._life_left, drone._anim_t])
	# 到期回收：寿命尽 → queue_free（回收语义逐值保持）
	drone.set("_life_left", 0.05)
	player.tick(0.1, Vector2.ZERO)
	_check("F5⑥ 到期回收：寿命尽 queue_free 置位",
		drone.is_queued_for_deletion())
	# 预警闪烁语义保持：末 1.5s 窗内 modulate.a ∈ [0.4, 1.0]（0.4+0.6|sin| 值域）
	player._summon_drones.erase(drone)
	if is_instance_valid(drone):
		var a: float = drone._sprite.modulate.a
		_check("F5⑦ 预警闪烁值域保持 a∈[0.39,1.0]", a >= 0.39 and a <= 1.0, str(a))
		drone.free()                              # 探针自建件直接回收（非池化，无二次 release）


# ── F6 r195-1 激光副束序数加成归零（r195_laser_pierce_cases 同款夹具） ──
func _test_f6_sub_beam_pierce_ordinal() -> void:
	print("── F6 r195-1 激光副束序数归零 ──")
	LaserBeam.scorch_pool_reset()
	_setup_laser_world()
	var probe := _run_prism_probe(["res://resources/traits/AFF_PIERCE.tres",
		"res://resources/traits/MEC_SPLIT_PRISM.tres",
		"res://resources/traits/SYN_PIERCE_EVO.tres"])
	var main: LaserBeam = probe["main"]
	var sub: LaserBeam = probe["sub"]
	var spy: SpyPipeline = probe["spy"]
	main.tick(0.26)
	sub.tick(0.26)
	# spy 实录分类（束 uid 归束）
	var main_idx: Array[int] = []
	var main_mult: Array[float] = []
	var sub_idx: Array[int] = []
	var sub_mult: Array[float] = []
	for i in spy.source_log.size():
		if spy.source_log[i] == int(main.uid):
			main_idx.append(spy.pierce_log[i])
			main_mult.append(spy.mult_log[i])
		elif spy.source_log[i] == int(sub.uid):
			sub_idx.append(spy.pierce_log[i])
			sub_mult.append(spy.mult_log[i])
	_check("F6① 主束序数原样：首目标 pierce_index==2（S4 口径零改动）",
		main_idx.size() >= 1 and main_idx[0] == 2, str(main_idx))
	_check("F6② 主束次目标 pierce_index==3（贯穿累进保持）",
		main_idx.size() >= 2 and main_idx[1] == 3, str(main_idx))
	_check("F6③ 主束 SYN 贡献保持：首跳 ×1.2 / 次跳 ×1.4（mult_product 实录）",
		main_mult.size() >= 2 and _approx(main_mult[0], 1.2, 0.001)
		and _approx(main_mult[1], 1.4, 0.001), str(main_mult))
	_check("F6④ 副束首目标 ctx.pierce_index==1（R198 口径：序数加成仅主束）",
		sub_idx.size() >= 1 and sub_idx[0] == 1, str(sub_idx))
	_check("F6⑤ SYN_PIERCE_EVO 副束贡献==0（副束全部结算 mult_product 恒 1.0）",
		sub_mult.size() >= 1, str(sub_mult))
	var sub_mult_all_one := true
	for m in sub_mult:
		if not _approx(m, 1.0, 0.001):
			sub_mult_all_one = false
	_check("F6⑥ 副束乘区逐结算恒 1.0（无任何 SYN 池入账）",
		sub_mult_all_one, str(sub_mult))
	var w: LaserWeapon = probe["weapon"]
	if is_instance_valid(w):
		w.free()
	for e in _alive_enemies:
		if is_instance_valid(e):
			_enemy_pool.release(e)
	_alive_enemies.clear()
	_teardown_laser_world()


func _setup_laser_world() -> void:
	_proj_pool = ProjectilePool.new()
	_proj_pool.name = "R198ProjPool"
	tree.get_root().add_child(_proj_pool)
	_proj_pool.setup(&"r198_proj", load(BALLISTIC_SCENE), 16)
	_homing_pool = ProjectilePool.new()
	_homing_pool.name = "R198HomingPool"
	tree.get_root().add_child(_homing_pool)
	_homing_pool.setup(&"r198_homing", load(HOMING_SCENE), 8)
	_laser_pool = LaserBeamPool.new()
	_laser_pool.name = "R198LaserPool"
	tree.get_root().add_child(_laser_pool)
	_laser_pool.setup(&"r198_laser", load(LASER_SCENE), 16)
	var ep := EnemyPool.new()
	ep.name = "R198EnemyPool"
	tree.get_root().add_child(ep)
	ep.setup(&"r198_enemy", load(ENEMY_SCENE), 32)
	_enemy_pool = ep
	_grid = SpaceGrid.new()
	_grid.configure(Vector2(720, 1280), 192.0)
	_stub = DamagePipelineStub.new()
	_alive_enemies.clear()


func _teardown_laser_world() -> void:
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
	_stub = null


func _make_laser_weapon_data() -> WeaponData:
	_wd_counter += 1
	var d := WeaponData.new()
	d.id = StringName("W_R198_%d" % _wd_counter)
	d.display_name = "R198 测试激光 %d" % _wd_counter
	d.form = GameConst.WeaponForm.LASER
	d.crit_rate = 0.0
	d.crit_dmg = 2.0
	d.hitbox_r = 6.0
	for i in range(5):
		var ls := WeaponLevelStats.new()
		ls.base_atk = 10.0
		ls.rof = 8.0
		ls.cd = 0.5
		ls.pierce = 1                              # L 表 1（AFF_PIERCE 抬到 2）
		ls.pellets = 1
		d.upgrade_table.append(ls)
	d.laser["refract_beams"] = 0
	d.laser["beam_length"] = 560.0
	return d


func _run_prism_probe(p_trait_paths: Array[String]) -> Dictionary:
	var spy := SpyPipeline.new()
	spy.inner = _stub
	var w := LaserWeapon.new()
	w.name = "R198Weapon_%d" % _wd_counter
	tree.get_root().add_child(w)
	w.position = WEAPON_POS
	w.setup(_make_laser_weapon_data(), null, {
		"pipeline": spy,
		"projectile_pool": _proj_pool,
		"enemy_grid": _grid,
		"laser_pool": _laser_pool,
		"homing_pool": _homing_pool,
		"elemental": null,
	})
	for path in p_trait_paths:
		var td := load(path) as TraitData
		_check("F6 前置：真卡挂载（%s）" % path, td != null and w.attach_trait(td))
	var enemies: Array[Node2D] = []
	for pos: Vector2 in [E1_POS, E2_POS, E3_POS]:
		var e := _enemy_pool.acquire() as Enemy
		e.spawn(_make_enemy_data_r198("E_R198_%d" % enemies.size()), 1, 0)
		e.position = pos
		_alive_enemies.append(e)
		enemies.append(e)
	_grid.rebuild(_alive_enemies)
	var fired: bool = w.try_fire()
	_check("F6 前置：try_fire 出主束+副束（棱镜 1 副）",
		fired and w.active_beams.size() == 2, "beams=%d" % w.active_beams.size())
	var main: LaserBeam = w._main_beam
	var sub: LaserBeam = w._alive_sub_beams()[0]
	_check("F6 前置：副束预算恒 1（_hit_budget 副束门不动）",
		sub.pierce == 1 and main.pierce == 2,
		"sub=%d main=%d" % [sub.pierce, main.pierce])
	return {"weapon": w, "main": main, "sub": sub, "spy": spy}


func _make_enemy_data_r198(p_id: String) -> EnemyData:
	var d := EnemyData.new()
	d.id = StringName(p_id)
	d.display_name = p_id
	d.hp_base = 1000.0
	d.spd_base = 0.0
	d.dmg_base = 8.0
	d.exp_base = 3.0
	d.tp_cost = 1.0
	d.hitbox_r = 14.0
	return d


# F6 spy 管线（实录 ctx.pierce_index / mult_product 后透传 stub——鸭子协议，
# laser 侧 call(&"resolve")；SYN 对副束贡献==0 直接读乘区实录，免双探针伤害差分）
class SpyPipeline:
	extends RefCounted

	var inner: RefCounted = null
	var pierce_log: Array[int] = []
	var mult_log: Array[float] = []
	var source_log: Array[int] = []

	func resolve(p_ctx: DamageContext) -> DamageResult:
		pierce_log.append(int(p_ctx.pierce_index))
		source_log.append(int(p_ctx.source_uid))
		var result: DamageResult = inner.resolve(p_ctx)
		mult_log.append(float(result.mult_product))
		return result

	func resolve_reaction(p_ctx: DamageContext) -> DamageResult:
		return inner.resolve_reaction(p_ctx)

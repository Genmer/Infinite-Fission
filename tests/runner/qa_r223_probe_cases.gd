# tests/runner/qa_r223_probe_cases.gd
# R223 QA 独立探针用例体（入口 test_qa_r223_probe.gd 运行时 load——-s 编译期禁引工程
# 类名纪律；本文件运行时类名全部已注册）。与 r223_settlebudget_cases（开发自测）互补
# 的独立攻击面，不复述其断言形状：
#  P0   门控密封独立复核（A6 前提——出厂静态面 headless 帽 0）
#  P1   调速器【全新实例】语义（A1/A2/重点面6）：菜单/暂停整段跳过、EMA 首采直赋
#       （无 -1 混合/无假初始化）、vc29 全链判别（含 _drop_hold 战斗秒冻结——pre-fix
#       选卡样本会推进 hold 的判别器）、长选卡不开假升档窗、暂停同门、战斗内真恢复
#  P2a  刀R 闸序：亡目标判定先于预算闸（死目标永不入顺延队——A3 前提）
#  P2b  settle_aoe 端到端（A3/A4/重点面2 铺垫）：真管道下零值占位无双血 + 门关全量
#       冲刷 DPS 守恒 + 结N 只计真结算
#  P2c1 重启形态安全（重点面1 正向）：清场后全部顺延项在下一帧头被亡目标零成本丢弃
#       （dead 丢不耗预算 → 数量超帽也一帧清空）→ 新局敌人零幻影
#  P2c2 同帧击杀→归池→同节点复活形态（重点面1 反向判别）：顺延项跨帧头存活 + 池
#       LIFO 同节点复活 → 幻影伤害/旧 uid 派发（预期缺陷探针）
#  P2d  过期强冲账目恒等式（A5）：deferred = 预算冲刷 + 过期强冲 + 亡丢 + 超载丢；
#       结N=真结算数；R221 D1 兼容——旧帧戳结果批派发不被 30 帧过期守卫丢弃（重点面3）
#  P3   订阅者风暴面（重点面2）：顺延期 EventBus 零派发；冲刷每对恰一条合并事件；
#       popup 合并桶每目标一条；HUD override=0 直消费累计守恒
#  P4   幂等边角（重点面4）：真结算 dupe 预算尽仍折返缓存真结果；顺延后同键 dupe
#       的合并语义偏差探针（占位不入幂等缓存 → 同输入二次结算 base 翻倍——预期缺陷）
#  P5   反应通道（重点面5）：预算耗尽下 resolve_reaction 全额真结算不受门控
#  P6   真链形态（重点面7）：_gl._physics_process(DT) 整帧驱动下真弹池弹段命中→
#       预算顺延→次帧帧头冲刷→⑧段前派发的逐帧次序与无双血（重点面3 落地面）
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const DT := 1.0 / 60.0

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null
var _gov: Node = null                          # 全新 PerfGovernor 实例（与 autoload 隔离驱动）
var _field: Array[Enemy] = []                  # 在场夹具敌（与 spawner.active 同步维护）
var _spy: Array[DamageResult] = []             # EventBus.damage_resolved 到达序
var _rxn_count: int = 0                        # EventBus.reaction_triggered 计数
var _saved: Dictionary = {}                    # 静态面留存（自管自清）
var _hud_saved: int = -1


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_boot_game_loop()
	await tree.process_frame
	await tree.process_frame
	PerfGovernor.set_process(false)          # 引擎侧停走——全新实例手动确定性步进
	_saved = {
		"tier": PerfGovernor.tier, "transitions": PerfGovernor.transitions,
		"tier_override": PerfGovernor.tier_override, "mode_override": PerfGovernor.mode_override,
		"ema_inject": PerfGovernor._ema_inject, "budget": DamagePipeline.settle_budget_override,
	}
	_hud_saved = _gl.hud.dmg_half_freq_override
	EventBus.damage_resolved.connect(_on_damage_spy)
	EventBus.reaction_triggered.connect(_on_rxn_spy)
	_gl.state = GameConst.GameStatus.MENU
	tree.paused = false
	_p0_gate_default()
	_p1_governor()
	_p2a_dead_order()
	_p2b_settle_aoe()
	_p2c1_restart_safe()
	_p2c2_respawn_phantom()
	_p2d_stale_accounting()
	_p3_subscribers()
	_p4_idempotent_edges()
	_p5_reaction_channel()
	_p6_real_chain()
	await _cleanup()
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
	var main: Node = load(MAIN_SCENE).instantiate()
	tree.root.add_child(main)
	_gl = tree.root.get_node_or_null("Main") as GameLoop
	if _gl == null:
		for c in tree.root.get_children():
			if c is GameLoop:
				_gl = c
				break


# ── 订阅者 spy ────────────────────────────────────────────────────

func _on_damage_spy(r: DamageResult) -> void:
	_spy.append(r)


func _on_rxn_spy(_rxn: int, _pos: Vector2, _tuid: int) -> void:
	_rxn_count += 1


# ── 夹具 ──────────────────────────────────────────────────────────

func _fixture_enemy(p_id: StringName, p_hp: float) -> EnemyData:
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


func _spawn_enemy(p_id: StringName, p_hp: float = 100000.0, p_pos: Vector2 = Vector2.ZERO) -> Enemy:
	var pool := _gl.pools[&"enemy"] as EnemyPool
	var e := pool.acquire() as Enemy
	e.spawn(_fixture_enemy(p_id, p_hp), 1, 0)
	e._fade_left = 0.0
	e.modulate.a = 1.0
	e.position = p_pos
	if not _gl.spawner.active.has(e):
		_gl.spawner.active.append(e)
	_field.append(e)
	return e


func _release_enemy(p_e: Enemy) -> void:
	_gl.spawner.active.erase(p_e)
	_field.erase(p_e)
	(_gl.pools[&"enemy"] as EnemyPool).release(p_e)


func _field_clear() -> void:
	for e in _field.duplicate():
		if is_instance_valid(e):
			_gl.spawner.active.erase(e)
			(_gl.pools[&"enemy"] as EnemyPool).release(e)
	_field.clear()
	_gl.enemy_grid.rebuild(_gl.spawner.active)


func _mk_ctx(p_source: int, p_target: Enemy, p_base: float, p_frame: int) -> DamageContext:
	var ctx := DamageContext.make()
	ctx.source_uid = p_source
	ctx.target_uid = p_target.uid
	ctx.target = p_target
	ctx.frame_stamp = p_frame
	ctx.base_atk = p_base
	ctx.crit_chance = 0.0
	ctx.crit_mult = 2.0
	ctx.pos = p_target.global_position
	return ctx


func _resolve(p_ctx: DamageContext) -> DamageResult:
	return _gl.pipeline.call(&"resolve", p_ctx) as DamageResult


func _stat(p_key: String) -> int:
	return int((_gl.pipeline.call(&"stats") as Dictionary).get(p_key, 0))


func _fifo_size() -> int:
	return (_gl.pipeline.get(&"_pending_fifo") as Array).size()


func _queue_size() -> int:
	return (_gl.pipeline.get(&"_resolved_queue") as Array).size()


func _pending_clear() -> void:
	_gl.pipeline.get(&"_pending_pair").clear()
	(_gl.pipeline.get(&"_pending_fifo") as Array).clear()
	(_gl.pipeline.get(&"_resolved_queue") as Array).clear()


# ── P0 门控密封独立复核 ───────────────────────────────────────────

func _p0_gate_default() -> void:
	print("── P0 出厂静态面门控密封（A6 前提） ──")
	_check("P0 headless 出厂态结算帽 0（既有套件零扰动前提独立复核）",
		DamagePipeline.settle_budget_override == -1 and DamagePipeline._settle_cap_now() == 0,
		"override=%d cap=%d" % [DamagePipeline.settle_budget_override, DamagePipeline._settle_cap_now()])


# ── P1 调速器全新实例语义 ─────────────────────────────────────────

func _p1_governor() -> void:
	print("── P1 调速器全新实例：首采/vc29 全链/假升档窗/暂停门 ──")
	PerfGovernor.mode_override = 0             # vc29 = 帧率优先口径（地板 1——FX 地板 2 钉死 tier1 不可达）
	PerfGovernor.tier_override = -1
	PerfGovernor._ema_inject = -1.0
	PerfGovernor.tier = 3
	PerfGovernor.transitions = 0
	_gov = (load("res://autoload/perf_governor.gd") as GDScript).new()
	tree.root.add_child(_gov)
	_gov.set_process(false)
	_gov._test_reset()
	# P1.1 菜单期整段跳过：EMA 保持未初始化
	for i in 6:
		_gov._process(_gov.SAMPLE_S)
	_check("P1.1 菜单 6 采样 EMA 保持 -1（未初始化）且零档变/零校验臂",
		absf(_gov._ema + 1.0) < 1e-9 and PerfGovernor.transitions == 0
			and _gov._drop_ema < 0.0,
		"ema=%.4f trans=%d" % [_gov._ema, PerfGovernor.transitions])
	# P1.2 进局首采直赋（无 -1 混合）
	PerfGovernor._ema_inject = 80.0
	_gl.state = GameConst.GameStatus.PLAYING
	_gov._process(_gov.SAMPLE_S)
	_check("P1.2 首战斗采样直赋 80.0（EMA=-1 不参与混合/无假初始化）",
		absf(_gov._ema - 80.0) < 1e-9, "ema=%.4f" % _gov._ema)
	# P1.3 vc29 全链：降档 3→2→1 → 选卡窗 → 恢复战斗（步数动态——target 受本机刷新率
	# 钳制非恒 120；ema=35 对 0.90×target 恒真：target ≥ 60 → 阈值 ≥ 54 > 35）
	PerfGovernor._ema_inject = 35.0
	var ticks13 := 0
	while PerfGovernor.tier > 1 and ticks13 < 20:
		_gov._process(_gov.SAMPLE_S)
		ticks13 += 1
	_check("P1.3a 深载降档链 3→2→1（transitions=2 · ≤10 采样收敛）",
		PerfGovernor.tier == 1 and PerfGovernor.transitions == 2 and ticks13 <= 10,
		"tier=%d trans=%d ticks=%d target=%d" % [PerfGovernor.tier,
			PerfGovernor.transitions, ticks13, PerfGovernor._target_fps()])
	var ema_battle: float = _gov._ema
	_gl.state = GameConst.GameStatus.LEVEL_UP
	PerfGovernor._ema_inject = 120.0
	for i in 12:
		_gov._process(_gov.SAMPLE_S)
	_check("P1.3b 选卡窗 6s：EMA 逐位不动 + tier 钉 1 + 校验 hold 战斗秒冻结（pre-fix 会 +6s）",
		absf(_gov._ema - ema_battle) < 1e-9 and PerfGovernor.tier == 1
			and PerfGovernor.transitions == 2 and absf(_gov._drop_hold) < 1e-9
			and absf(_gov._recover_acc) < 1e-9,
		"ema=%.4f tier=%d hold=%.2f rec=%.2f" % [_gov._ema, PerfGovernor.tier,
			_gov._drop_hold, _gov._recover_acc])
	_gl.state = GameConst.GameStatus.PLAYING
	PerfGovernor._ema_inject = 35.0
	for i in 12:
		_gov._process(_gov.SAMPLE_S)
	_check("P1.3c 恢复战斗 6s：无效降档判回升+冻结（tier=2 · trans=3 · frozen）——vc29 判别器",
		PerfGovernor.tier == 2 and PerfGovernor.transitions == 3 and _gov._drop_frozen,
		"tier=%d trans=%d frozen=%s" % [PerfGovernor.tier, PerfGovernor.transitions,
			str(_gov._drop_frozen)])
	# P1.4 长选卡窗不开假升档窗
	_gov._test_reset()
	PerfGovernor.tier = 3
	PerfGovernor.transitions = 0
	PerfGovernor._ema_inject = 35.0
	_gl.state = GameConst.GameStatus.PLAYING
	var t14 := 0
	while PerfGovernor.tier > 2 and t14 < 20:
		_gov._process(_gov.SAMPLE_S)
		t14 += 1
	_check("P1.4a 单档降基线（tier=2 · trans=1）",
		PerfGovernor.tier == 2 and PerfGovernor.transitions == 1,
		"tier=%d trans=%d" % [PerfGovernor.tier, PerfGovernor.transitions])
	var ema2: float = _gov._ema
	_gl.state = GameConst.GameStatus.LEVEL_UP
	PerfGovernor._ema_inject = 120.0
	for i in 10:
		_gov._process(_gov.SAMPLE_S)
	_check("P1.4b 长选卡 5s：不开假升档窗（tier 仍 2 · _recover_acc=0 · EMA 不动）",
		PerfGovernor.tier == 2 and PerfGovernor.transitions == 1
			and absf(_gov._recover_acc) < 1e-9 and absf(_gov._ema - ema2) < 1e-9,
		"tier=%d rec=%.2f" % [PerfGovernor.tier, _gov._recover_acc])
	# P1.5 暂停同门（tree.paused 挂起口）+ 战斗内真恢复通道照常
	_gl.state = GameConst.GameStatus.PAUSED
	tree.paused = true
	PerfGovernor._ema_inject = 30.0
	for i in 4:
		_gov._process(_gov.SAMPLE_S)
	_check("P1.5a 暂停 2s：EMA 不动（paused 挂起口）+ tier 不变",
		absf(_gov._ema - ema2) < 1e-9 and PerfGovernor.tier == 2,
		"ema=%.4f tier=%d" % [_gov._ema, PerfGovernor.tier])
	tree.paused = false
	_gl.state = GameConst.GameStatus.PLAYING
	_gov._test_reset()                        # EMA 清空——首采直赋避开 35→119 收敛
	PerfGovernor._ema_inject = 119.0
	for i in 10:
		_gov._process(_gov.SAMPLE_S)
	_check("P1.5b 战斗内真恢复通道照常（5s 持续 → tier 回 3）",
		PerfGovernor.tier == 3 and PerfGovernor.transitions == 2,
		"tier=%d trans=%d" % [PerfGovernor.tier, PerfGovernor.transitions])
	# 静态面归位（后续管线用例不依赖调速器）
	PerfGovernor.mode_override = -1
	PerfGovernor._ema_inject = -1.0
	PerfGovernor.tier = 3
	PerfGovernor.transitions = 0
	_gov._test_reset()
	_gl.state = GameConst.GameStatus.MENU


# ── P2a 闸序：亡目标先于预算闸 ────────────────────────────────────

func _p2a_dead_order() -> void:
	print("── P2a 亡目标判定先于预算闸 ──")
	var e := _spawn_enemy(&"E_QA_P2A")
	DamagePipeline.settle_budget_override = 1
	_gl.pipeline.call(&"begin_frame", 100)
	var r1: DamageResult = _resolve(_mk_ctx(8100, e, 10.0, 100))
	e.dead = true                             # 预算耗尽后目标亡
	var dd0 := _stat("dropped_dead")
	var df0 := _stat("settle_deferred")
	var r2: DamageResult = _resolve(_mk_ctx(8200, e, 10.0, 100))
	_check("P2a 预算尽+亡目标 → dropped_dead 短路（null · 不入顺延队）",
		r1 != null and r2 == null and _stat("dropped_dead") == dd0 + 1
			and _stat("settle_deferred") == df0 and _fifo_size() == 0,
		"r2=%s dd=%d fifo=%d" % [str(r2 == null), _stat("dropped_dead") - dd0, _fifo_size()])
	_gl.pipeline.call(&"end_frame")
	DamagePipeline.settle_budget_override = -1
	_pending_clear()
	_field_clear()


# ── P2b settle_aoe 端到端（真武器节点调用方） ──────────────────────

func _p2b_settle_aoe() -> void:
	print("── P2b settle_aoe 端到端：零值占位无双血 + 门关冲刷 DPS 守恒 ──")
	var ea := _spawn_enemy(&"E_QA_P2B1", 100000.0, Vector2(2000, 360))
	var eb := _spawn_enemy(&"E_QA_P2B2", 100000.0, Vector2(2040, 360))
	var ec := _spawn_enemy(&"E_QA_P2B3", 100000.0, Vector2(2080, 360))
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	var w1: WeaponBase = _gl.player.weapon_slots[0] as WeaponBase
	if w1.damage_pipeline == null:
		w1.damage_pipeline = _gl.pipeline
	if w1.enemy_grid == null:
		w1.enemy_grid = _gl.enemy_grid
	DamagePipeline.settle_budget_override = 1
	var s0 := _stat("settles")
	var d0 := _stat("settle_deferred")
	var hp0 := ea.hp + eb.hp + ec.hp
	_gl.pipeline.call(&"begin_frame", GameConfig.frame_stamp)
	w1.settle_aoe(Vector2(2030, 360), 300.0, 10.0, false)
	_check("P2b 帽1 下三目标 AOE：恰 1 真结算入队 + 2 顺延（占位不入队）",
		_queue_size() == 1 and _stat("settle_deferred") == d0 + 2 and _fifo_size() == 2,
		"q=%d d=%d fifo=%d" % [_queue_size(), _stat("settle_deferred") - d0, _fifo_size()])
	_check("P2b 顺延期零落血（三敌总血量恰 -10——无双血）",
		absf((ea.hp + eb.hp + ec.hp) - (hp0 - 10.0)) < 0.001,
		"Δhp=%.3f" % ((ea.hp + eb.hp + ec.hp) - hp0))
	_gl.pipeline.call(&"end_frame")
	DamagePipeline.settle_budget_override = -1      # 门关（headless/桌面自动语义）
	_gl.pipeline.call(&"begin_frame", GameConfig.frame_stamp)
	_check("P2b 门关帧头全量冲刷：FIFO 清空 + DPS 守恒（总血量恰 -30）+ 结N=真结算 3",
		_fifo_size() == 0 and absf((ea.hp + eb.hp + ec.hp) - (hp0 - 30.0)) < 0.001
			and _stat("settles") == s0 + 3,
		"fifo=%d Δhp=%.3f settles=%d" % [_fifo_size(),
			(ea.hp + eb.hp + ec.hp) - hp0, _stat("settles") - s0])
	_gl.pipeline.call(&"dispatch_resolved_frame")
	_gl.pipeline.call(&"end_frame")
	_field_clear()


# ── P2c1 重启形态安全（清场亡目标零成本丢弃） ──────────────────────

func _p2c1_restart_safe() -> void:
	print("── P2c1 重启形态：清场后顺延残留一帧头全清（无幻影） ──")
	var pool := _gl.pools[&"enemy"] as EnemyPool
	var ea := _spawn_enemy(&"E_QA_P2C1A", 100000.0, Vector2(0, 360))
	var eb := _spawn_enemy(&"E_QA_P2C1B", 100000.0, Vector2(50, 360))
	DamagePipeline.settle_budget_override = 1
	var f0 := GameConfig.frame_stamp
	_gl.pipeline.call(&"begin_frame", f0)
	var _r1: DamageResult = _resolve(_mk_ctx(8300, ea, 10.0, f0))
	for i in 5:                                # 5 对顺延（>帽 1——模拟深载积压超预算）
		var _r: DamageResult = _resolve(_mk_ctx(8301 + i, eb, 10.0, f0))
	_check("P2c1 前置：帽内 1 真结算 + 5 对顺延在队", _fifo_size() == 5, "fifo=%d" % _fifo_size())
	_gl.pipeline.call(&"end_frame")
	# 暂停重开 _clear_battlefield 同构：在场敌同步归还池（dead=true · hp=0）
	var node_eb: Enemy = eb
	_release_enemy(ea)
	_release_enemy(eb)
	DamagePipeline.settle_budget_override = 1  # 真机门保持开（tier1/2 形态）
	var fd0 := _stat("settle_flush_dead")
	_gl.pipeline.call(&"begin_frame", f0 + 1)  # 新局帧 1 帧头：先于出怪
	_check("P2c1 亡目标零成本丢弃不耗预算：5 项一帧头全清（fifo=0 · dead+5）",
		_fifo_size() == 0 and _stat("settle_flush_dead") == fd0 + 5,
		"fifo=%d dead=%d" % [_fifo_size(), _stat("settle_flush_dead") - fd0])
	var m := pool.acquire() as Enemy
	_check("P2c1 池 LIFO：新局出怪复用即归调节点", m == node_eb,
		"same=%s" % str(m == node_eb))
	m.spawn(_fixture_enemy(&"E_QA_P2C1N", 100000.0), 1, 0)
	_check("P2c1 新局敌人满血（跨局零幻影伤害）", absf(m.hp - m.max_hp) < 0.001,
		"hp=%.1f max=%.1f" % [m.hp, m.max_hp])
	_release_enemy(m)
	DamagePipeline.settle_budget_override = -1
	_pending_clear()
	_field_clear()


# ── P2c2 同帧击杀→归池→同节点复活形态（预期缺陷判别） ─────────────

func _p2c2_respawn_phantom() -> void:
	print("── P2c2 同帧击杀→池复用复活：顺延项幻影伤害判别 ──")
	var pool := _gl.pools[&"enemy"] as EnemyPool
	var ea := _spawn_enemy(&"E_QA_P2C2A", 100000.0, Vector2(0, 360))
	var eb := _spawn_enemy(&"E_QA_P2C2B", 100000.0, Vector2(50, 360))
	DamagePipeline.settle_budget_override = 1
	var f1 := GameConfig.frame_stamp
	_gl.pipeline.call(&"begin_frame", f1)
	var _r1: DamageResult = _resolve(_mk_ctx(8400, ea, 10.0, f1))   # 帽内真结算（预算耗尽）
	var d0 := _stat("settle_deferred")
	var r2: DamageResult = _resolve(_mk_ctx(8401, eb, 10.0, f1))   # eb 顺延（活目标超帽跨帧头存活）
	_check("P2c2 前置：活目标顺延占位（跨帧头存活前提）",
		r2 != null and r2.deferred_merge and _stat("settle_deferred") == d0 + 1
			and _fifo_size() == 1, "fifo=%d" % _fifo_size())
	_gl.pipeline.call(&"end_frame")
	# 同帧 ④/⑤ 击杀→池归还（on_enemy_killed 即归还）+ ⑥ 出怪段同节点复用复活
	var old_uid: int = eb.uid
	_release_enemy(eb)
	var m := pool.acquire() as Enemy
	_check("P2c2 池 LIFO：出怪复用即刚亡节点（同帧复活形态成立）", m == eb,
		"same=%s" % str(m == eb))
	m.spawn(_fixture_enemy(&"E_QA_P2C2N", 100000.0), 1, 0)
	_check("P2c2 复活节点新身份（uid 单调不复用 · 满血）",
		m.uid != old_uid and absf(m.hp - m.max_hp) < 0.001,
		"uid %d→%d hp=%.1f" % [old_uid, m.uid, m.hp])
	var hp_pre: float = m.hp
	var reuse0 := _stat("settle_flush_reuse")
	_gl.pipeline.call(&"begin_frame", f1 + 1)  # 次帧头：顺延项冲刷
	_check("P2c2【修后契约】冲刷 uid 复验 → 新身份复活敌零幻影（Δhp=0 · reuse +1）",
		absf(m.hp - hp_pre) < 0.001 and _stat("settle_flush_reuse") == reuse0 + 1,
		"Δhp=%.3f reuse+%d（R223 修轮 QA-1/评审#3：uid 不符诚实丢弃）" % [m.hp - hp_pre,
			_stat("settle_flush_reuse") - reuse0])
	# 事件派发面：顺延项被丢弃 ⇒ 无 8401 事件入队（popup/HUD 消费面零死锚）
	_gl.pipeline.call(&"dispatch_resolved_frame")
	var phantom: DamageResult = null
	for r in _spy:
		if r.source_uid == 8401:
			phantom = r
	_check("P2c2【修后契约】零幻影事件派发（8401 无事件——消费面无死锚）",
		phantom == null,
		"phantom=%s" % str(phantom != null))
	_release_enemy(m)
	DamagePipeline.settle_budget_override = -1
	_pending_clear()
	_field_clear()


# ── P2d 过期强冲账目恒等式 + D1 派发兼容 ──────────────────────────

func _p2d_stale_accounting() -> void:
	print("── P2d 过期强冲恒等式 + D1 派发兼容 ──")
	var e := _spawn_enemy(&"E_QA_P2D", 1000000.0)
	var hp0 := e.hp
	DamagePipeline.settle_budget_override = 1
	var s0 := _stat("settles")
	var d0 := _stat("settle_deferred")
	var fl0 := _stat("settle_flush")
	var st0 := _stat("settle_stale_flush")
	var fd0 := _stat("settle_flush_dead")
	var ov0 := _stat("settle_overload_drop")
	var f2 := GameConfig.frame_stamp
	_gl.pipeline.call(&"begin_frame", f2)
	var _r0: DamageResult = _resolve(_mk_ctx(8500, e, 10.0, f2))    # 帽内真结算
	for i in 30:
		var _r: DamageResult = _resolve(_mk_ctx(8600 + i, e, 1.0, f2))
	_check("P2d 前置：1 真结算 + 30 对顺延", _fifo_size() == 30, "fifo=%d" % _fifo_size())
	_gl.pipeline.call(&"end_frame")
	for f in range(f2 + 1, f2 + 14):           # 13 帧：预算各冲 1 · 帧末维护过期强冲
		_gl.pipeline.call(&"begin_frame", f)
		_gl.pipeline.call(&"end_frame")
	var df := _stat("settle_deferred") - d0
	var fl := _stat("settle_flush") - fl0
	var st := _stat("settle_stale_flush") - st0
	_check("P2d 账目恒等：deferred(30) = 预算冲刷(13) + 过期强冲(17) + 亡丢(0) + 超载丢(0)",
		df == 30 and fl == 30 and st == 17 and _stat("settle_flush_dead") == fd0
			and _stat("settle_overload_drop") == ov0 and _fifo_size() == 0,
		"df=%d fl=%d st=%d dead=%d ov=%d fifo=%d" % [df, fl, st,
			_stat("settle_flush_dead") - fd0, _stat("settle_overload_drop") - ov0, _fifo_size()])
	_check("P2d 伤害守恒 + 结N=真结算数（1+30=31）",
		absf(e.hp - (hp0 - 40.0)) < 0.001 and _stat("settles") == s0 + 31,
		"Δhp=%.3f settles=%d" % [e.hp - hp0, _stat("settles") - s0])
	# D1 兼容：31 条旧帧戳（龄 ≤13）结果批派发不被 30 帧过期守卫丢弃
	_spy.clear()
	_gl.pipeline.call(&"dispatch_resolved_frame")
	_check("P2d D1 兼容：12 帧强冲窗 ⊂ 30 帧派发守卫窗（31 条全量派发 · 队列清空）",
		_spy.size() == 31 and _queue_size() == 0,
		"spy=%d q=%d" % [_spy.size(), _queue_size()])
	DamagePipeline.settle_budget_override = -1
	_field_clear()


# ── P3 订阅者风暴面 ───────────────────────────────────────────────

func _p3_subscribers() -> void:
	print("── P3 订阅者面：零派发顺延 / 每对恰一条 / popup 合并桶 / HUD 累计 ──")
	var ea := _spawn_enemy(&"E_QA_P3A", 100000.0)
	var eb := _spawn_enemy(&"E_QA_P3B", 100000.0)
	var ec := _spawn_enemy(&"E_QA_P3C", 100000.0)
	var hud_total0 := _gl.hud.total_damage
	_gl.hud.dmg_half_freq_override = 0         # 每帧直消费（断言确定性）
	_gl.popup_manager.clear_all()
	_spy.clear()
	DamagePipeline.settle_budget_override = 1
	var f3 := GameConfig.frame_stamp
	_gl.pipeline.call(&"begin_frame", f3)
	var _r1: DamageResult = _resolve(_mk_ctx(8700, ea, 10.0, f3))
	var _r2: DamageResult = _resolve(_mk_ctx(8701, eb, 10.0, f3))
	var _r3: DamageResult = _resolve(_mk_ctx(8702, ec, 10.0, f3))
	_check("P3 顺延期 EventBus 零派发（spy 0 · 仅帽内 1 条入队待派发）",
		_spy.is_empty() and _queue_size() == 1 and _fifo_size() == 2,
		"spy=%d q=%d fifo=%d" % [_spy.size(), _queue_size(), _fifo_size()])
	_gl.pipeline.call(&"end_frame")
	DamagePipeline.settle_budget_override = -1
	_gl.pipeline.call(&"begin_frame", f3 + 1)  # 门关全量冲刷
	_gl.pipeline.call(&"dispatch_resolved_frame")
	_check("P3 冲刷后每对恰一条事件（spy 3 · final 全 >0 · 无零值占位泄漏）",
		_spy.size() == 3 and _spy[0].final_value > 0.0 and _spy[1].final_value > 0.0
			and _spy[2].final_value > 0.0
			and not (_spy[0].deferred_merge or _spy[1].deferred_merge or _spy[2].deferred_merge),
		"spy=%d" % _spy.size())
	var pop_a := 0
	var pop_b := 0
	var pop_c := 0
	for n in _gl.popup_manager._active_list:
		var dp := n as DamagePopup
		if dp == null:
			continue
		if dp.target_uid == ea.uid:
			pop_a += 1
		elif dp.target_uid == eb.uid:
			pop_b += 1
		elif dp.target_uid == ec.uid:
			pop_c += 1
	_check("P3 popup 合并桶：每目标恰 1 条跳字（3 目标零重复）",
		pop_a == 1 and pop_b == 1 and pop_c == 1,
		"a=%d b=%d c=%d" % [pop_a, pop_b, pop_c])
	_check("P3 HUD 直消费累计守恒（total +30.0）",
		absf(_gl.hud.total_damage - (hud_total0 + 30.0)) < 0.001,
		"total=%.3f" % (_gl.hud.total_damage - hud_total0))
	_gl.hud.dmg_half_freq_override = _hud_saved
	_gl.popup_manager.clear_all()
	_gl.pipeline.call(&"end_frame")
	_field_clear()


# ── P4 幂等边角 ───────────────────────────────────────────────────

func _p4_idempotent_edges() -> void:
	print("── P4 幂等边角：真结算 dupe 折返 / 顺延后 dupe 合并偏差 ──")
	var e := _spawn_enemy(&"E_QA_P4", 1000000.0)
	var hp0 := e.hp
	DamagePipeline.settle_budget_override = 1
	var f4 := GameConfig.frame_stamp
	_gl.pipeline.call(&"begin_frame", f4)
	var ctxX := _mk_ctx(8800, e, 10.0, f4)
	var rx: DamageResult = _resolve(ctxX)                    # 帽内真结算（预算耗尽）
	var dupe0 := _stat("dropped_dupe")
	var d0 := _stat("settle_deferred")
	var rx2: DamageResult = _resolve(_mk_ctx(8800, e, 10.0, f4))  # 同键 dupe：预算尽仍折返
	_check("P4a 真结算 dupe 预算尽仍折返缓存真结果（同实例 · 不占预算不顺延）",
		rx2 == rx and not rx2.deferred_merge and _stat("dropped_dupe") == dupe0 + 1
			and _stat("settle_deferred") == d0 and _fifo_size() == 0,
		"same=%s dupe=%d fifo=%d" % [str(rx2 == rx),
			_stat("dropped_dupe") - dupe0, _fifo_size()])
	var ry: DamageResult = _resolve(_mk_ctx(8801, e, 10.0, f4))   # 顺延（占位入幂等缓存）
	var ry2: DamageResult = _resolve(_mk_ctx(8801, e, 10.0, f4))  # 同键 dupe：折返占位
	_check("P4b【修后契约】顺延后同键 dupe 折返占位（同实例 · 不再并入 base）",
		ry != null and ry.deferred_merge and ry2 == ry and _fifo_size() == 1,
		"fifo=%d same=%s（R223 修轮 QA-2：占位写幂等缓存）" % [_fifo_size(), str(ry2 == ry)])
	_gl.pipeline.call(&"end_frame")
	DamagePipeline.settle_budget_override = -1
	_gl.pipeline.call(&"begin_frame", f4 + 1)                 # 冲刷：dupe 短路=单次落账
	_check("P4b 冲刷单次落账（hp -20：真结算 10 + 顺延 10——pre-budget 幂等语义恢复）",
		absf(e.hp - (hp0 - 20.0)) < 0.001,
		"Δhp=%.3f（真结算 10 + 顺延单次 10）" % (e.hp - hp0))
	_gl.pipeline.call(&"end_frame")
	_field_clear()


# ── P5 反应通道不受预算影响 ───────────────────────────────────────

func _p5_reaction_channel() -> void:
	print("── P5 反应通道预算豁免 ──")
	var ea := _spawn_enemy(&"E_QA_P5A", 1000000.0)
	var eb := _spawn_enemy(&"E_QA_P5B", 100000.0)
	DamagePipeline.settle_budget_override = 1
	var f5 := GameConfig.frame_stamp
	_gl.pipeline.call(&"begin_frame", f5)
	var _r1: DamageResult = _resolve(_mk_ctx(8900, ea, 10.0, f5))   # 预算耗尽
	var rs0 := _stat("reaction_settles")
	var d0 := _stat("settle_deferred")
	var hp0 := eb.hp
	var ctxR := DamageContext.make()
	ctxR.source_uid = 8901
	ctxR.target_uid = eb.uid
	ctxR.target = eb
	ctxR.frame_stamp = f5
	ctxR.pos = eb.global_position
	var rr: DamageResult = _gl.pipeline.call(&"resolve_reaction", 100.0, 1.2, ctxR) as DamageResult
	_check("P5 预算耗尽下反应通道全额真结算（非占位 · final>0 · 落血=final）",
		rr != null and not rr.deferred_merge and rr.final_value > 0.0
			and absf(eb.hp - (hp0 - rr.final_value)) < 0.001,
		"final=%.2f Δhp=%.2f" % [rr.final_value if rr != null else -1.0,
			eb.hp - hp0])
	_check("P5 反应计数/零顺延/事件恰一条（reaction_settles+1 · settle_deferred 不变 · triggered=1）",
		_stat("reaction_settles") == rs0 + 1 and _stat("settle_deferred") == d0
			and _rxn_count == 1,
		"rs=%d d=%d rxn=%d" % [_stat("reaction_settles") - rs0,
			_stat("settle_deferred") - d0, _rxn_count])
	_gl.pipeline.call(&"end_frame")
	_gl.pipeline.get(&"_resolved_queue").clear()
	DamagePipeline.settle_budget_override = -1
	_field_clear()


# ── P6 真链形态：整帧驱动 ─────────────────────────────────────────

func _p6_real_chain() -> void:
	print("── P6 真链：_physics_process 整帧驱动（弹段→顺延→帧头冲刷→⑧派发） ──")
	_gl.state = GameConst.GameStatus.PLAYING
	# 武器静默：槽位清空（_reset_run_state 同款合法态——零开火噪音），用例尾段还原。
	# 弹/敌须在屏内（出界回收先于碰撞——首版探针 1800px 外布点被 EXPIRED 教育过）。
	var slots_saved: Array = []
	for i in range(_gl.player.weapon_slots.size()):
		slots_saved.append(_gl.player.weapon_slots[i])
		_gl.player.weapon_slots[i] = null
	var e1 := _spawn_enemy(&"E_QA_P6A", 100000.0, Vector2(300, 480))
	var e2 := _spawn_enemy(&"E_QA_P6B", 100000.0, Vector2(340, 480))
	var e3 := _spawn_enemy(&"E_QA_P6C", 100000.0, Vector2(380, 480))
	var pool := _gl.pools[&"projectile"] as ProjectilePool
	var bullets: Array[ProjectileBase] = []
	for i in 3:
		var b := pool.acquire() as ProjectileBase
		b.damage_pipeline = _gl.pipeline
		b.enemy_grid = _gl.enemy_grid
		b.pool = pool
		b.spawn({
			"velocity": Vector2(60.0, 0.0), "lifetime": 10.0, "pierce": 1, "team": 0,
			"weapon_ref": slots_saved[0],
			"panel_snapshot": {"base_atk": 10.0, "flat_bonus": 0.0, "crit_rate": 0.0,
				"crit_mult": 2.0, "add_entries": []},
			"position": [e1, e2, e3][i].global_position,
		})
		bullets.append(b)
	DamagePipeline.settle_budget_override = 1
	var hp1 := e1.hp
	var hp2 := e2.hp
	var hp3 := e3.hp
	var s0 := _stat("settles")
	var d0 := _stat("settle_deferred")
	_spy.clear()
	for f in 3:
		_gl._physics_process(DT)
		var spy_n := _spy.size()
		if f == 0:
			# 弹段 tick 逆序（与敌段同款倒序遍历）——真结算落在哪发弹不确定，
			# 断言口径：三敌中恰一敌 -10、其余零落血（帽1 恰 1 真结算）
			var hit_n := (1 if absf(e1.hp - hp1) > 0.001 else 0) 				+ (1 if absf(e2.hp - hp2) > 0.001 else 0) 				+ (1 if absf(e3.hp - hp3) > 0.001 else 0)
			_check("P6 帧1：帽1 恰 1 真结算即时派发 + 2 弹顺延占位（恰一敌 -10 · 余零落血）",
				spy_n == 1 and _stat("settle_deferred") == d0 + 2 and hit_n == 1
					and absf((e1.hp + e2.hp + e3.hp) - (hp1 + hp2 + hp3 - 10.0)) < 0.001,
				"spy=%d d=%d d1=%.3f d2=%.3f d3=%.3f" % [spy_n,
					_stat("settle_deferred") - d0, e1.hp - hp1, e2.hp - hp2, e3.hp - hp3])
		elif f == 1:
			_check("P6 帧2：帧头冲刷顺延对 1 → e2 落血 10（次帧 ⑧ 派发累计 spy 2）",
				spy_n == 2 and absf(e2.hp - (hp2 - 10.0)) < 0.001,
				"spy=%d Δe2=%.3f" % [spy_n, e2.hp - hp2])
		else:
			_check("P6 帧3：冲刷顺延对 2 → e3 落血 10（spy 3 · DPS 守恒 30）",
				spy_n == 3 and absf(e3.hp - (hp3 - 10.0)) < 0.001
					and absf((e1.hp + e2.hp + e3.hp) - (hp1 + hp2 + hp3 - 30.0)) < 0.001,
				"spy=%d Δtotal=%.3f" % [spy_n,
					(e1.hp + e2.hp + e3.hp) - (hp1 + hp2 + hp3)])
	_check("P6 穿透侧语义：占位被当真命中消费——三弹全部回收（pierce 耗尽）",
		not pool.active_projectiles().has(bullets[0])
			and not pool.active_projectiles().has(bullets[1])
			and not pool.active_projectiles().has(bullets[2]), "")
	_check("P6 结N=真结算数 3（顺延不计）+ 派发零零值（final 全 >0）",
		_stat("settles") == s0 + 3 and _spy.size() == 3
			and _spy[0].final_value > 0.0 and _spy[1].final_value > 0.0
			and _spy[2].final_value > 0.0,
		"settles=%d spy=%d" % [_stat("settles") - s0, _spy.size()])
	DamagePipeline.settle_budget_override = -1
	_gl.pipeline.get(&"_resolved_queue").clear()
	for i in range(slots_saved.size()):
		_gl.player.weapon_slots[i] = slots_saved[i]
	_gl.state = GameConst.GameStatus.MENU
	_field_clear()


func _cleanup() -> void:
	DamagePipeline.settle_budget_override = int(_saved.get("budget", -1))
	_pending_clear()
	_field_clear()
	if EventBus.damage_resolved.is_connected(_on_damage_spy):
		EventBus.damage_resolved.disconnect(_on_damage_spy)
	if EventBus.reaction_triggered.is_connected(_on_rxn_spy):
		EventBus.reaction_triggered.disconnect(_on_rxn_spy)
	_gl.hud.dmg_half_freq_override = _hud_saved
	PerfGovernor.mode_override = int(_saved.get("mode_override", -1))
	PerfGovernor.tier_override = int(_saved.get("tier_override", -1))
	PerfGovernor._ema_inject = float(_saved.get("ema_inject", -1.0))
	PerfGovernor.tier = int(_saved.get("tier", 3))
	PerfGovernor.transitions = int(_saved.get("transitions", 0))
	if _gov != null:
		_gov.free()
		_gov = null
	_gl.state = GameConst.GameStatus.MENU
	tree.paused = false
	PerfGovernor.set_process(true)
	if _gl != null:
		_gl.queue_free()
		await tree.process_frame

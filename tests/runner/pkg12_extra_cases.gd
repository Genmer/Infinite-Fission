# tests/runner/pkg12_extra_cases.gd
# v1.2.0 验收补漏用例体（由 test_pkg12_extra.gd 入口在 autoload 就绪后运行时加载编译）。
# tester 独立复算视角：pkg12 V41~V56 已覆盖项不重复；本文件锁「手算锚 + 全周期时序 +
# 全环克制 + 重开残留（v1.1.0 XE1 同口径扩面）」：
#   XE1 WAT 衰减 λ 手算锚 + λ 三处逐值镜像（schema / GameConfig.balance / .tres 文本）
#   XE2 冻结端到端全周期时序（2.5s 定身窗口 + CD 5s 门 + 二次冻结 + immune 全窗拦截）
#   XE3 盾克制端到端手算（FIR 100 打 ICE 盾 −200）+ SHIELD_COUNTER 全环 + REACTION 全局豁免
#   XE4 敌侧重开残留（冻结四字段 + 盾三字段 + 环——池复用归还清零责任，v1.1.0 XE1 同口径）
#   XE5 系统侧重开残留（reset_run 注册表清零）+ uid_conduct 复用行为（重开后链跳恰一次）
#   XE6 ElementRing 四扇区 progress(WAT) 显示通路（5→4 槽映射 + 钳制 + 运行期驱动）
#   XE7 既有 ICE 满槽冻结（1.2s 旧通道）同步升级全停（A11 §3：同一 freeze_timer 行为门）
# 确定性：真件 DamagePipeline（seed 42）+ crit_rate=0（不掷骰）+ 固定坐标/面板；
#         帧闸门经 GameConfig.frame_stamp 手动推进 + begin_frame 清幂等缓存。
extends RefCounted

const BALLISTIC_SCENE := "res://scenes/combat/projectiles/ballistic_projectile.tscn"
const ENEMY_SCENE := "res://scenes/combat/enemies/enemy.tscn"
const DT := 1.0 / 120.0

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []

var _proj_pool: ProjectilePool
var _enemy_pool: EnemyPool
var _grid: SpaceGrid
var _pipeline: DamagePipeline
var _sys: ElementalSystem
var _alive_enemies: Array[Node2D] = []
var _captured: Array[DamageResult] = []        # damage_resolved 捕获
var _rxn_events: Array[int] = []               # reaction_triggered 广播捕获


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_ensure_autoloads()
	_setup_world()
	_test_xe1_wat_decay_lambda()                  # XE1
	_test_xe2_freeze_full_cycle()                 # XE2
	_test_xe3_shield_counter_e2e()                # XE3
	_test_xe4_enemy_restart_residue()             # XE4
	_test_xe5_system_restart_residue()            # XE5
	_test_xe6_element_ring_progress()             # XE6
	_test_xe7_legacy_ice_freeze_fullstop()        # XE7
	_test_xe8_volatile_frozen_stop()              # XE8（审查 Important #2 回归）
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


func _bump() -> void:
	GameConfig.frame_stamp += 1                   # E-03 帧闸门推进（测试侧替身）


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


func _setup_world() -> void:
	_proj_pool = ProjectilePool.new()
	_proj_pool.name = "Pkg12xProjPool"
	tree.get_root().add_child(_proj_pool)
	_proj_pool.setup(&"pkg12x_test", load(BALLISTIC_SCENE), 16)
	var ep := EnemyPool.new()
	ep.name = "Pkg12xEnemyPool"
	tree.get_root().add_child(ep)
	ep.setup(&"pkg12x_enemy", load(ENEMY_SCENE), 24)
	_enemy_pool = ep
	_grid = SpaceGrid.new()
	_grid.configure(Vector2(720, 1280), 192.0)
	_alive_enemies.clear()
	_captured.clear()
	_pipeline = DamagePipeline.new()
	_pipeline.set_rng_seed(42)
	_sys = ElementalSystem.new()
	_sys.name = "Pkg12xElementalSystem"
	tree.get_root().add_child(_sys)
	_sys.pipeline = _pipeline
	_sys.enemy_grid = _grid
	EventBus.damage_resolved.connect(_on_damage_resolved)
	EventBus.reaction_triggered.connect(_on_reaction_triggered)


func _teardown_world() -> void:
	if EventBus.damage_resolved.is_connected(_on_damage_resolved):
		EventBus.damage_resolved.disconnect(_on_damage_resolved)
	if EventBus.reaction_triggered.is_connected(_on_reaction_triggered):
		EventBus.reaction_triggered.disconnect(_on_reaction_triggered)
	_alive_enemies.clear()
	_captured.clear()
	_rxn_events.clear()
	if _sys != null:
		_sys.free()
		_sys = null
	_pipeline = null
	if _proj_pool != null:
		_proj_pool.free()
		_proj_pool = null
	if _enemy_pool != null:
		_enemy_pool.free()
		_enemy_pool = null
	_grid = null


func _on_damage_resolved(p_result: DamageResult) -> void:
	_captured.append(p_result)


func _on_reaction_triggered(p_rxn: int, _p_pos: Vector2, _p_uid: int) -> void:
	_rxn_events.append(p_rxn)


func _make_enemy_data(p_id: String, p_hp: float = 1000.0) -> EnemyData:
	var d := EnemyData.new()
	d.id = StringName(p_id)
	d.display_name = p_id
	d.hp_base = p_hp
	d.spd_base = 0.0                              # 静止敌（几何确定性）
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


func _gauge(p_enemy: Node2D, p_element: int, p_value: float) -> void:
	# 非满槽预置附着（无状态触发）；snapshot 100 供剧变快照通道
	_sys.apply_attach(p_enemy, p_element, p_value, {"snapshot": 100.0})


func _freeze(p_enemy: Node2D) -> void:
	# 预置冻结（WAT+ICE 双附着 → 帧末检测）
	_gauge(p_enemy, GameConst.Element.WAT, 30.0)
	_gauge(p_enemy, GameConst.Element.ICE, 30.0)
	_detect()


func _detect() -> void:
	# 帧末检测替身（GameLoop 帧序：敌人阶段后调 detect_reactions）
	_captured.clear()
	_rxn_events.clear()
	_bump()
	_pipeline.begin_frame()
	_sys.detect_reactions()


func _direct_fake(p_value: float = 10.0) -> DamageResult:
	var r := DamageResult.new()
	r.final_value = p_value
	r.popup_style = GameConst.PopupStyle.NORMAL
	r.panel_snapshot = 100.0
	return r


func _hit_fake(p_element: int, p_value: float, p_style: int = GameConst.PopupStyle.NORMAL) -> DamageResult:
	var r := DamageResult.new()
	r.final_value = p_value
	r.popup_style = p_style
	r.element = p_element
	r.panel_snapshot = 100.0
	return r


func _read_source(p_path: String) -> String:
	var f := FileAccess.open(p_path, FileAccess.READ)
	if f == null:
		return ""
	return f.get_as_text()


func _purge_enemies() -> void:
	# 用例间隔离：归还全部存活敌 + 清空网格（池化复用，spawn 全量重置）
	for e in _alive_enemies:
		_sys.unregister_host(e)
		_enemy_pool.release(e)
	_alive_enemies.clear()
	_grid.rebuild(_alive_enemies)


# ── XE1 WAT 衰减 λ 手算锚 + 三处逐值镜像 ─────────────────────────
func _test_xe1_wat_decay_lambda() -> void:
	print("── XE1 WAT 衰减 λ 手算锚 ──")
	# a) 纯数学锚：apply(WAT,50) → tick 0.5 → 50×(1−0.38×0.5)=40.5（WAT 用 λ[3]=0.38）
	var st := ElementalState.new()
	var metered: bool = st.apply(GameConst.Element.WAT, 50.0) == ElementalState.TRIGGER_NONE \
		and _approx(st.gauges[GameConst.Element.WAT], 50.0)
	st.tick(0.5, BalanceTables.new().element_decay_lambda)
	var wat_anchor := _approx(st.gauges[GameConst.Element.WAT], 40.5)
	# b) 旧元素零漂锚：FIR 槽用 λ[0]=0.35 → 50×(1−0.35×0.5)=41.25
	var st2 := ElementalState.new()
	st2.apply(GameConst.Element.FIR, 50.0)
	st2.tick(0.5, BalanceTables.new().element_decay_lambda)
	var fir_anchor := _approx(st2.gauges[GameConst.Element.FIR], 41.25)
	# c) λ 三处逐值镜像：schema 默认 / GameConfig.balance 加载值 / balance_tables.tres 文本
	var want: Array[float] = [0.35, 0.30, 0.40, 0.38]
	var schema: Array[float] = BalanceTables.new().element_decay_lambda
	var loaded: Array[float] = GameConfig.balance.element_decay_lambda
	var mirror_ok: bool = schema.size() == 4 and loaded.size() == 4
	for i in range(4):
		if not mirror_ok:
			break
		mirror_ok = _approx(schema[i], want[i]) and _approx(loaded[i], want[i])
	var tres_src := _read_source("res://data/balance/balance_tables.tres")
	var tres_ok: bool = tres_src.contains("element_decay_lambda = [0.35, 0.3, 0.4, 0.38]")
	# d) 集成端到端：宿主注册 → apply_attach(WAT,50) → _sys.tick(0.5) → 40.5
	var e := _spawn_enemy(_make_enemy_data("XE1"), Vector2(120, 200))
	_sys.register_host(e)
	_gauge(e, GameConst.Element.WAT, 50.0)
	_sys.tick(0.5)
	var st_e: ElementalState = e.get("elemental")
	var e2e_ok: bool = st_e != null and _approx(st_e.gauges[GameConst.Element.WAT], 40.5)
	_sys.unregister_host(e)
	_enemy_pool.release(e)
	_alive_enemies.erase(e)
	_grid.rebuild(_alive_enemies)
	_check("XE1：WAT 衰减 λ 手算锚——apply(WAT,50)×0.5s→40.5（λ[3]=0.38）/ FIR 41.25（λ[0]=0.35 零漂）/ λ 三处逐值镜像 [0.35,0.30,0.40,0.38] / 宿主链端到端 40.5",
		metered and wat_anchor and fir_anchor and mirror_ok and tres_ok and e2e_ok,
		"metered=%s wat=%s fir=%s mirror=%s tres=%s e2e=%s" % [str(metered), str(wat_anchor),
			str(fir_anchor), str(mirror_ok), str(tres_ok), str(e2e_ok)])


# ── XE2 冻结端到端全周期时序 ─────────────────────────────────────
func _test_xe2_freeze_full_cycle() -> void:
	print("── XE2 冻结全周期时序 ──")
	# t=0：WAT30+ICE30 → 帧末冻结 timer 2.5 / sf=0；immune Boss 同帧拦截 timer 0
	var e := _spawn_enemy(_make_enemy_data("XE2_A", 2000.0), Vector2(120, 200))
	_sys.register_host(e)
	var eb := _spawn_enemy(_make_enemy_data("XE2_B", 2000.0), Vector2(400, 200))
	eb.immune_mask = GameConst.IMMUNE_FREEZE
	_sys.register_host(eb)
	_gauge(e, GameConst.Element.WAT, 30.0)
	_gauge(e, GameConst.Element.ICE, 30.0)
	_gauge(eb, GameConst.Element.WAT, 30.0)
	_gauge(eb, GameConst.Element.ICE, 30.0)
	_detect()
	var st: ElementalState = e.get("elemental")
	var stb: ElementalState = eb.get("elemental")
	var t0_ok: bool = st != null and _approx(st.freeze_timer, 2.5) \
		and _approx(st.get_speed_factor(), 0.0) \
		and stb != null and stb.freeze_timer <= 0.0
	# t=2.49：仍冻结（窗口内 sf=0）
	_sys.tick(2.49)
	var mid_ok: bool = st.freeze_timer > 0.0 and _approx(st.get_speed_factor(), 0.0) \
		and stb.freeze_timer <= 0.0
	# t=2.51：跨 2.5s 边界解控——timer 归零 / sf 回 1 / 到期计数清零
	_sys.tick(0.02)
	var unfreeze_ok: bool = st.freeze_timer <= 0.0 and _approx(st.get_speed_factor(), 1.0) \
		and st.freeze_hits == 0
	# t=2.51 CD 门（5s 未到）：双附着重挂 → detect 不再冻结（无广播）
	_gauge(e, GameConst.Element.WAT, 30.0)
	_gauge(e, GameConst.Element.ICE, 30.0)
	_detect()
	var gate_ok: bool = st.freeze_timer <= 0.0 \
		and not _rxn_events.has(GameConst.ReactionType.RXN_WAT_ICE) \
		and float(st.reaction_cd.get(GameConst.ReactionType.RXN_WAT_ICE, -1.0)) > 2.0
	# t=5.0 CD 走完：残余附着仍在阈值上（衰减后 WAT≈1.61/ICE≈7.59）→ 再冻结成功
	_sys.tick(2.49)
	_detect()
	var refreeze_ok: bool = _approx(st.freeze_timer, 2.5) \
		and _rxn_events.has(GameConst.ReactionType.RXN_WAT_ICE) \
		and _approx(st.gauges[GameConst.Element.WAT], 0.0) \
		and stb.freeze_timer <= 0.0                 # immune 敌全窗（5s）零冻结
	_check("XE2：冻结全周期时序——t0 冻结 timer 2.5/sf=0 + t2.49 仍冻结 + t2.51 解控 sf=1/计数清 + CD 门 5s 内不重触 + t5.0 二次冻结成功 + immune Boss 全窗拦截",
		t0_ok and mid_ok and unfreeze_ok and gate_ok and refreeze_ok,
		"t0=%s mid=%s unfreeze=%s gate=%s refreeze=%s" % [str(t0_ok), str(mid_ok),
			str(unfreeze_ok), str(gate_ok), str(refreeze_ok)])
	_purge_enemies()


# ── XE3 盾克制端到端手算 + SHIELD_COUNTER 全环 ───────────────────
func _test_xe3_shield_counter_e2e() -> void:
	print("── XE3 盾克制端到端 ──")
	# a) 克环字面 + shield_hit_factor 边界（越界 1.0 / 双向克制 2.0）
	var ring_literal: bool = true
	var want_ring: Array[int] = [-1, 2, 1, 4, 3]
	for i in range(5):
		if int(GameConst.SHIELD_COUNTER[i]) != want_ring[i]:
			ring_literal = false
	var f_ok: bool = is_equal_approx(GameConst.shield_hit_factor(-1, 1), 1.0) \
		and is_equal_approx(GameConst.shield_hit_factor(2, 1), 2.0) \
		and is_equal_approx(GameConst.shield_hit_factor(2, 9), 1.0) \
		and is_equal_approx(GameConst.shield_hit_factor(4, 3), 2.0) \
		and is_equal_approx(GameConst.shield_hit_factor(5, 1), 1.0)
	# b) ICE 盾 250：FIR 100 → −200 手算锚（50 余）；ICE 同盾 ×1 → 破盾无溢出；破后 KIN 落血
	var d1 := _make_enemy_data("XE3_A", 1000.0)
	d1.shield = {"element": 2, "capacity_ratio": 0.25}
	var e1 := _spawn_enemy(d1, Vector2(120, 200))
	var cap_ok: bool = is_equal_approx(e1.shield_hp, 250.0)
	e1.take_result(_hit_fake(GameConst.Element.FIR, 100.0))
	var counter_anchor := _approx(e1.shield_hp, 50.0) and _approx(e1.hp, 1000.0)
	e1.take_result(_hit_fake(GameConst.Element.ICE, 100.0))
	var break_ok: bool = _approx(e1.shield_hp, 0.0) and _approx(e1.hp, 1000.0) \
		and not e1.dead and is_equal_approx(e1.shield_progress(), 0.0)
	e1.take_result(_hit_fake(GameConst.Element.KIN, 50.0))
	var no_regen := _approx(e1.hp, 950.0) and _approx(e1.shield_hp, 0.0)
	# c) LTG 盾 250：WAT 克制 ×2 → −200 手算锚（50 余）；ICE ×1 → 破盾无溢出
	var d2 := _make_enemy_data("XE3_B", 1000.0)
	d2.shield = {"element": 3, "capacity_ratio": 0.25}
	var e2 := _spawn_enemy(d2, Vector2(400, 200))
	e2.take_result(_hit_fake(GameConst.Element.WAT, 100.0))
	var wat_ltg_anchor := _approx(e2.shield_hp, 50.0)
	e2.take_result(_hit_fake(GameConst.Element.ICE, 100.0))
	var e2_break := _approx(e2.shield_hp, 0.0) and _approx(e2.hp, 1000.0) and not e2.dead
	# d) REACTION 全局豁免：LTG 盾吃 RXN_WAT_LTG=4 通道 100 → ×1（150 余，即便 4=克制位）
	var d3 := _make_enemy_data("XE3_C", 1000.0)
	d3.shield = {"element": 3, "capacity_ratio": 0.25}
	var e3 := _spawn_enemy(d3, Vector2(680, 200))
	e3.take_result(_hit_fake(GameConst.ReactionType.RXN_WAT_LTG, 100.0,
		GameConst.PopupStyle.REACTION))
	var rxn_exempt := _approx(e3.shield_hp, 150.0)
	_purge_enemies()
	_check("XE3：盾克制端到端手算——SHIELD_COUNTER=[-1,2,1,4,3] + factor 越界 1.0/克制 2.0 + FIR 100 打 ICE 盾 −200（250→50）+ ICE 同盾破盾无溢出不可再生 + WAT 100 打 LTG 盾 −200 + REACTION 通道全局豁免 ×1",
		ring_literal and f_ok and cap_ok and counter_anchor and break_ok and no_regen
		and wat_ltg_anchor and e2_break and rxn_exempt,
		"ring=%s f=%s cap=%s fir200=%s brk=%s regen=%s wat200=%s brk2=%s rxn=%s"
			% [str(ring_literal), str(f_ok), str(cap_ok), str(counter_anchor), str(break_ok),
			str(no_regen), str(wat_ltg_anchor), str(e2_break), str(rxn_exempt)])


# ── XE4 敌侧重开残留（冻结 + 盾字段，v1.1.0 XE1 同口径扩面） ──────
func _test_xe4_enemy_restart_residue() -> void:
	print("── XE4 敌侧重开残留 ──")
	# 局内：带盾 + 冻结 + 破碎计数 1 + 盾被削（脏态制造）
	var sd := _make_enemy_data("XE4", 1000.0)
	sd.shield = {"element": 2, "capacity_ratio": 0.25}
	var e := _spawn_enemy(sd, Vector2(120, 200))
	_sys.register_host(e)
	_freeze(e)
	e.take_result(_direct_fake(10.0))             # 冻结期直击：freeze_hits=1 + 盾 250→240
	var st: ElementalState = e.get("elemental")
	var dirty: bool = st != null and st.freeze_timer > 0.0 and st.freeze_hits == 1 \
		and _approx(e.shield_hp, 240.0)
	# 重开链：unregister（state.reset+置空）→ 归还（_reset_state 清零责任）→ 复取重生（无盾数据）
	_sys.unregister_host(e)
	_enemy_pool.release(e)
	_alive_enemies.erase(e)
	var fresh := _make_enemy_data("XE4_FRESH", 800.0)
	var e2 := _enemy_pool.acquire() as Enemy
	e2.spawn(fresh, 1, 0)
	e2.position = Vector2(120, 200)
	_alive_enemies.append(e2)
	_grid.rebuild(_alive_enemies)
	var reuse_ok: bool = e2 == e                  # 池复用同实例（残留只能靠归还清零挡）
	var clean: bool = e2.shield_element == -1 and _approx(e2.shield_hp, 0.0) \
		and _approx(e2.shield_max, 0.0) and not e2._shield_ring.visible \
		and is_equal_approx(e2.shield_progress(), 0.0) and e2.get("elemental") == null
	# 新局重新挂状态容器：冻结四字段全零（无跨局虚冻结）
	_sys.register_host(e2)
	var st2: ElementalState = e2.get("elemental")
	var state_ok: bool = st2 != null and st2.freeze_timer <= 0.0 and st2.freeze_hits == 0 \
		and not st2.freeze_shatter_pending and _approx(st2.freeze_shatter_snapshot, 0.0)
	_purge_enemies()
	_check("XE4：敌侧重开残留（v1.1.0 XE1 同口径 v1.2.0 扩面）——冻结期带盾带计数的脏实例归还后池复用：盾三字段 −1/0/0 + 环隐藏 + elemental 置空 + 新容器冻结四字段全零",
		dirty and reuse_ok and clean and state_ok,
		"dirty=%s reuse=%s clean=%s state=%s" % [str(dirty), str(reuse_ok), str(clean),
			str(state_ok)])


# ── XE5 系统侧重开残留 + uid_conduct 复用行为 ────────────────────
func _test_xe5_system_restart_residue() -> void:
	print("── XE5 系统侧重开残留 ──")
	# a) 注册表脏 → reset_run 清零（v1.1.0 XE1 锚在 HEAD 复验）
	_sys.register_reaction_mult(424242, 1.8)
	_sys.register_mastery(424242, 2, 0.25)
	var dirty_mult := _sys.reaction_mult()
	var dirty_ok: bool = _approx(dirty_mult, 2.7) and _sys.mastery_layers() == 2
	_sys.reset_run()
	var clean_ok: bool = _approx(_sys.reaction_mult(), 1.0) and _sys.mastery_layers() == 0
	# b) uid_conduct 复用行为：重开后导电链结算恰一次（旧 uid 不产生幻影/重复跳伤）
	_purge_enemies()
	var o := _spawn_enemy(_make_enemy_data("XE5_O", 4000.0), Vector2(60, 700))
	_sys.register_host(o)
	var a := _spawn_enemy(_make_enemy_data("XE5_A", 4000.0), Vector2(260, 700))
	_sys.register_host(a)
	_gauge(o, GameConst.Element.WAT, 30.0)
	_gauge(o, GameConst.Element.LTG, 30.0)
	_detect()
	var main_jumps: Array[float] = []
	var a_jumps: Array[float] = []
	var o_uid := int(o.get("uid"))
	var a_uid := int(a.get("uid"))
	for r in _captured:
		if r.target_uid == o_uid and r.popup_style == GameConst.PopupStyle.REACTION:
			main_jumps.append(r.final_value)
		if r.target_uid == a_uid and r.popup_style == GameConst.PopupStyle.DOT:
			a_jumps.append(r.final_value)
	var conduct_ok: bool = main_jumps.size() == 1 and _approx(main_jumps[0], 90.0) \
		and a_jumps.size() == 1 and _approx(a_jumps[0], 90.0)
	_purge_enemies()
	_check("XE5：系统侧重开残留——VOID×精通注册（1.8×1.5=2.7）reset_run 后回 1.0/0 层（v1.1.0 锚）+ 重开后 uid_conduct 导电链恰结算一次（主 90 / 跳 90 无幻影）",
		dirty_ok and clean_ok and conduct_ok,
		"dirty=%s(%s) clean=%s conduct=%s main=%s hops=%s" % [str(dirty_ok), str(dirty_mult),
			str(clean_ok), str(conduct_ok), str(main_jumps), str(a_jumps)])


# ── XE6 ElementRing 四扇区 progress(WAT) 显示通路 ────────────────
func _test_xe6_element_ring_progress() -> void:
	print("── XE6 ElementRing progress(WAT) ──")
	# a) 5→4 槽映射（取 [1..4] = FIR/ICE/LTG/WAT）+ progress 观测口 + 钳制
	var ring := Enemy.ElementRing.new()
	ring.set_gauges([0.0, 10.0, 0.0, 30.0, 50.0])
	var mapped := true
	var want_gauges: Array[float] = [10.0, 0.0, 30.0, 50.0]
	for i in range(4):
		if not _approx(ring._gauges[i], want_gauges[i]):
			mapped = false
	var prog_ok: bool = mapped \
		and _approx(ring.progress(GameConst.Element.WAT), 0.5) \
		and _approx(ring.progress(GameConst.Element.LTG), 0.3) \
		and _approx(ring.progress(GameConst.Element.FIR), 0.1) \
		and _approx(ring.progress(GameConst.Element.ICE), 0.0) \
		and _approx(ring.progress(9), 0.5)             # 元素越界钳 idx 3（WAT 位）
	# b) 旧 4 槽/3 槽数组防御：size<5 → 全零快照
	ring.set_gauges([0.0, 0.0, 0.0, 0.0])
	var legacy_ok: bool = _approx(ring.progress(GameConst.Element.WAT), 0.0) \
		and _approx(ring.progress(GameConst.Element.FIR), 0.0)
	# c) 运行期驱动：宿主 WAT 附着 50 → enemy._tick_element_ring → 环 progress(WAT)=0.5 可见
	var e := _spawn_enemy(_make_enemy_data("XE6", 1000.0), Vector2(120, 200))
	_sys.register_host(e)
	_gauge(e, GameConst.Element.WAT, 50.0)
	e._tick_element_ring(1.0)                     # 15Hz 降频窗内必刷新
	var e_ring: Enemy.ElementRing = e._ring
	var drive_ok: bool = e_ring != null and e_ring.visible \
		and _approx(e_ring.progress(GameConst.Element.WAT), 0.5)
	_sys.unregister_host(e)
	_enemy_pool.release(e)
	_alive_enemies.erase(e)
	_grid.rebuild(_alive_enemies)
	ring.free()
	_check("XE6：ElementRing 四扇区 progress(WAT)——5 槽→[FIR,ICE,LTG,WAT] 快照映射 + progress 观测口 0.1/0.0/0.3/0.5 + 元素越界钳 WAT 位 + size<5 防御全零 + 运行期 _tick_element_ring 驱动可见",
		prog_ok and legacy_ok and drive_ok,
		"prog=%s legacy=%s drive=%s" % [str(prog_ok), str(legacy_ok), str(drive_ok)])


# ── XE7 既有 ICE 满槽冻结（1.2s 旧通道）同步升级全停 ─────────────
func _test_xe7_legacy_ice_freeze_fullstop() -> void:
	print("── XE7 旧 ICE 满槽冻结全停升级 ──")
	# A11 §3：既有 ICE 满槽冻结（1.2s 通道）与新 WAT+ICE 冻结同一 freeze_timer 行为门——
	# 旧通道冻结期 RANGED fire_cd 递减全停 + sf=0 + burn DOT 照跳
	var rd := _make_enemy_data("XE7", 2000.0)
	rd.behavior = GameConst.EnemyBehavior.RANGED
	rd.ranged = {"bullet_speed": 300.0, "fire_cd": 1.5, "bullet_atk_ratio": 0.5, "spread": 0.0}
	var e := _spawn_enemy(rd, Vector2(360, 400))
	_sys.register_host(e)
	var player_stub := Node2D.new()
	player_stub.name = "Pkg12xPlayerStub"
	tree.get_root().add_child(player_stub)
	player_stub.add_to_group(&"player")
	player_stub.position = Vector2(360, 1240)     # 远离（dist > fire_range，不实际开火）
	# 未冻结对照：fire_cd 正常递减
	e.fire_cd_left = 1.0
	e.tick(DT)
	var control_ok := e.fire_cd_left < 1.0
	# 旧通道冻结：ICE 满槽两次（首次寒滞 2.5s → 寒滞期内再次满槽 → freeze 1.2s）
	_sys.apply_attach(e, GameConst.Element.ICE, 100.0, {"snapshot": 100.0})
	_sys.apply_attach(e, GameConst.Element.ICE, 100.0, {"snapshot": 100.0})
	var st: ElementalState = e.get("elemental")
	var legacy_frozen: bool = st != null and _approx(st.freeze_timer, 1.2)
	# 冻结期：fire_cd 不减 + sf=0
	e.fire_cd_left = 1.0
	e.tick(DT)
	var gate_ok := _approx(e.fire_cd_left, 1.0) and _approx(st.get_speed_factor(), 0.0)
	# DOT 通道不受冻结拦截：挂点燃 → _sys.tick(0.5) 出 DOT 结算
	_sys.apply_attach(e, GameConst.Element.FIR, 100.0, {"snapshot": 100.0})
	_captured.clear()
	_sys.tick(0.5)
	var dot_ok := false
	for r in _captured:
		if r.popup_style == GameConst.PopupStyle.DOT and r.element == GameConst.Element.FIR:
			dot_ok = true
	player_stub.free()
	_purge_enemies()
	_check("XE7：既有 ICE 满槽冻结（1.2s 旧通道）同步升级全停——对照递减 + 旧通道 freeze 1.2s + 冻结期 fire_cd 不减/sf=0 + burn DOT 照跳（与 WAT+ICE 新通道同一行为门）",
		control_ok and legacy_frozen and gate_ok and dot_ok,
		"control=%s legacy=%s gate=%s dot=%s" % [str(control_ok), str(legacy_frozen),
			str(gate_ok), str(dot_ok)])


func _test_xe8_volatile_frozen_stop() -> void:
	print("── XE8 volatile 冻结收口（审查 Important #2）──")
	# 引信冲刺覆写原绕过 sf=0；修正后冻结期 volatile 移动全停（引信计时照常）
	var vd := _make_enemy_data("XE8", 2000.0)
	vd.behavior = GameConst.EnemyBehavior.CHASE
	var e := _spawn_enemy(vd, Vector2(360, 400))
	_sys.register_host(e)
	var player_stub := Node2D.new()
	player_stub.name = "Pkg12xPlayerStub8"
	tree.get_root().add_child(player_stub)
	player_stub.add_to_group(&"player")
	player_stub.position = Vector2(360, 600)      # 下方 200px（冲刺方向参照）
	# 武装引信：直接置位（绕过警戒半径时序）
	e._fuse_armed = true
	# 未冻结对照：引信冲刺位移（260px/s × DT）
	var y0: float = e.global_position.y
	e.tick(DT)
	var moved_charge: float = absf(e.global_position.y - y0)
	var charge_ok := moved_charge > 0.0
	# 冻结：WAT+ICE 双附着（不满槽——WAT 满 100 自清槽）→ 帧末 detect 触发 RXN_WAT_ICE
	var st: ElementalState = e.get("elemental")
	_sys.apply_attach(e, GameConst.Element.WAT, 50.0, {"snapshot": 100.0})
	_sys.apply_attach(e, GameConst.Element.ICE, 50.0, {"snapshot": 100.0})
	_sys.detect_reactions()
	var frozen_ok: bool = st != null and st.freeze_timer > 2.0
	# 冻结期：引信已武装但零位移（sf=0 不再被覆写绕过）
	var y1: float = e.global_position.y
	e.tick(DT)
	var frozen_move: float = absf(e.global_position.y - y1)
	var stop_ok := _approx(frozen_move, 0.0)
	player_stub.free()
	e.free()
	_check("XE8：volatile 引信冲刺在冻结期停摆（sf=0 不被覆写；未冻结对照位移 %.3f）" % moved_charge,
		charge_ok and frozen_ok and stop_ok,
		"charge=%s frozen=%s frozen_move=%.4f" % [str(charge_ok), str(frozen_ok), frozen_move])

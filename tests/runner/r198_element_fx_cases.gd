# tests/runner/r198_element_fx_cases.gd
# R198 组1「元环表现」验收用例体（由 test_r198_element_fx.gd 入口加载；SceneTree 模式，
# 骨架照 r192_element_cases / r197_build_panel_cases 既有 -cases 结构）。
# 覆盖（R198_BACKLOG_SWEEP.md §4 组1 各 WorkItem acceptance）：
#   ① R192-low1  结算臂级硬默认缺键告警（_rule_num 会话一次闸）+ reaction_stat_text
#                表缺键/枚举错位 push_warning 后仍返回空串 + 合法无统计段（RXN_LTG_HYD）
#                空串且零告警（结算不崩、默认值回落）
#   ② R192-low2  冻结臂补 IMMUNE_CHILL 检位——冰免疫目标整段不吃冻结/寒滞/易伤
#                （IMMUNE_FREEZE 半边语义不变；非免疫目标逐值 1.2s/2.5s/×1.25 3s）
#   ③ R192-low6  绽放 delay 1.5→0.75 双源同批锁（.gd 默认 == .tres 运行时 == 行为臂）
#   ④ R192-low7  感电卡名消歧——ELE_SHOCK display_name「雷引」、反应名「感电」单源不动
#   ⑤ R192-low9  四新卡配对措辞统一箭头式（X→反应名 同构；无「遇…即」列表式残留）
#   ⑥ R192-low10 popup 分桶逐值映射锁（直击 0 / 反应 1 / 其余 2 / 文字 3 / 引爆 4）
#   ⑦ R192-low3  燃烧「5层」口径——跳字统计段带层数 + 图鉴 mult_fmt 带层数（设计文档
#                R198 回写的实机一致性锁；文档文本零残留由仓库 grep 承担）
#   ⑧ r195-5     confetti 落雨恒用世界 720 域——960 宽画布域下 piece 初始 x∈[0,720]
#   ⑨ r195-6     beam_impact 迸裂池 10→20 槽——预建（tick/命中路径零 add_child）
extends RefCounted

const ENEMY_SCENE := "res://scenes/combat/enemies/enemy.tscn"
const BALANCE_PATH := "res://data/balance/balance_tables.tres"

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []

var _grid: SpaceGrid
var _pipeline: DamagePipeline
var _sys: ElementalSystem
var _alive_enemies: Array[Node2D] = []
var _enemy_pool: EnemyPool
var _balance_orig: BalanceTables = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(1980930)
	_ensure_autoloads()
	_test_stat_text_alarm_and_legal_silent()   # ①b R192-low1：stat 段缺键/枚举错位告警 + 感电零告警
	_setup_world()
	_test_settle_arm_missing_key_alarm()       # ①a R192-low1：缺键 rule 告警 + 默认回落不崩
	_test_freeze_arm_immune_chill()            # ② R192-low2：IMMUNE_CHILL 检位
	_test_bloom_delay_dual_source()            # ③ R192-low6：delay==0.75 双源 + 行为臂
	_test_shock_reaction_zero_alarm()          # ①c R192-low1：合法无统计段反应零告警（系统侧）
	_teardown_world()
	_test_card_name_and_pairing()              # ④⑤ R192-low7/9：卡名 + 箭头式配对
	_test_popup_bucket_map()                   # ⑥ R192-low10：分桶映射
	_test_burn_layer_wording()                 # ⑦ R192-low3：燃烧带层数口径
	_test_confetti_world_domain()              # ⑧ r195-5：落雨世界 720 域
	_test_impact_pool_20()                     # ⑨ r195-6：迸裂池 20 槽预建
	_summary()


func fail_count() -> int:
	return _fail


# ── 支撑 ──────────────────────────────────────────────────────────
func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("PASS | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s %s" % [p_name, p_detail])
		print("FAIL | %s | %s" % [p_name, p_detail])


func _summary() -> void:
	print("────────────────────────────────────────")
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])


func _approx(p_a: float, p_b: float, p_tol: float = 0.001) -> bool:
	return absf(p_a - p_b) <= p_tol


func _bump_frame() -> void:
	GameConfig.frame_stamp += 1                # E-03 帧闸门推进（GameLoop 帧序的测试侧替身）


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


# ── 缺键表换源（R192-low1 夹具：balance 副本删键 → 换入 → 恢复） ────
func _swap_balance_missing(p_keys: Array) -> BalanceTables:
	_balance_orig = GameConfig.balance
	var bt: BalanceTables = (load(BALANCE_PATH) as BalanceTables).duplicate(true)
	# 嵌套字典逐键独立拷贝（duplicate 与真源共享嵌套容器风险隔离——erase 严禁污染真源）
	var rt: Dictionary = {}
	for k in bt.reaction_table:
		rt[k] = (bt.reaction_table[k] as Dictionary).duplicate()
	for k in p_keys:
		rt.erase(String(k))
	bt.reaction_table = rt
	GameConfig.balance = bt
	return bt


func _restore_balance() -> void:
	if _balance_orig != null:
		GameConfig.balance = _balance_orig
		_balance_orig = null


# ── 世界夹具（rxn_channel/r192 范式瘦身：无武器弹道，直挂附着 + detect 驱动） ──
func _setup_world() -> void:
	var ep := EnemyPool.new()
	ep.name = "R198EnemyPool"
	tree.get_root().add_child(ep)
	ep.setup(&"r198_enemy", load(ENEMY_SCENE), 16)
	_enemy_pool = ep
	_grid = SpaceGrid.new()
	_grid.configure(Vector2(720, 1280), 192.0)
	_pipeline = DamagePipeline.new()           # 真件（感电连锁 _shock_chain 结算通道）
	_pipeline.set_rng_seed(198)
	_sys = ElementalSystem.new()
	_sys.name = "R198ElementalSystem"
	tree.get_root().add_child(_sys)
	_sys.pipeline = _pipeline
	_sys.enemy_grid = _grid
	_alive_enemies.clear()


func _teardown_world() -> void:
	_alive_enemies.clear()
	if _sys != null:
		_sys.free()
		_sys = null
	_pipeline = null
	if _enemy_pool != null:
		_enemy_pool.free()
		_enemy_pool = null
	_grid = null


func _make_enemy_data(p_id: String, p_hp: float = 100000.0) -> EnemyData:
	var d := EnemyData.new()
	d.id = StringName(p_id)
	d.display_name = p_id
	d.hp_base = p_hp
	d.spd_base = 0.0                           # 静止敌（几何确定性）
	d.dmg_base = 8.0
	d.exp_base = 3.0
	d.tp_cost = 1.0
	d.hitbox_r = 14.0
	return d


func _spawn_enemy(p_id: String, p_pos: Vector2) -> Enemy:
	var e := _enemy_pool.acquire() as Enemy
	e.spawn(_make_enemy_data(p_id), 1, 0)
	e.position = p_pos
	_alive_enemies.append(e)
	_grid.rebuild(_alive_enemies)
	return e


func _retire_enemy(p_enemy: Enemy) -> void:
	_sys.unregister_host(p_enemy)
	_alive_enemies.erase(p_enemy)
	_grid.rebuild(_alive_enemies)


# ── ①a R192-low1：结算臂缺键 rule → 告警路径触发且结算不崩（默认值回落） ──
func _test_settle_arm_missing_key_alarm() -> void:
	print("── ①a R192-low1 冻结臂缺键：告警一次 + 默认值回落 + 结算不崩 ──")
	_swap_balance_missing(["RXN_ICE_HYD"])     # 整键删除 → _rxn_rule 落 {} → 四键全缺
	var sys := ElementalSystem.new()
	sys.name = "R198MissingKeySys"
	tree.get_root().add_child(sys)
	sys.pipeline = _pipeline
	var e := _spawn_enemy("E_R198_MISSKEY", Vector2(360, 400))
	sys.register_host(e)
	var st := e.get("elemental") as ElementalState
	sys.apply_attach(e, GameConst.Element.ICE, 50.0)   # 半槽（不满槽不触发附着臂）
	sys.apply_attach(e, GameConst.Element.HYD, 100.0)  # 新元素满槽钳制存续（燃料）
	# 半槽附着不写状态（快照基线归零后由反应臂独占写入）
	st.freeze_timer = 0.0
	st.chill_timer = 0.0
	st.vuln_mult = 1.0
	st.vuln_timer = 0.0
	var rxn0: int = DebugStats.get_counter(&"reaction_triggered")
	_bump_frame()
	sys.detect_reactions()
	var gates := sys._rule_missing_warned
	_check("①a 缺键 rule 结算不崩：反应触发 +1 · 双槽清空 · cd 落闸",
		DebugStats.get_counter(&"reaction_triggered") == rxn0 + 1
		and _approx(st.gauges[GameConst.Element.ICE], 0.0)
		and _approx(st.gauges[GameConst.Element.HYD], 0.0)
		and float(st.reaction_cd.get(GameConst.ReactionType.RXN_ICE_HYD, 0.0)) > 1.0)
	_check("①a 默认值回落：冻结 1.2s / 寒滞 2.5s / 易伤 ×1.25 3s（默认硬默认不中断结算）",
		_approx(st.freeze_timer, 1.2) and _approx(st.chill_timer, 2.5)
		and _approx(st.vuln_mult, 1.25) and _approx(st.vuln_timer, 3.0),
		"freeze=%s chill=%s vuln=%s/%s" % [str(st.freeze_timer), str(st.chill_timer),
			str(st.vuln_mult), str(st.vuln_timer)])
	_check("①a 告警路径触发：会话一次闸记满 4 门（freeze_dur/chill_dur/vuln_mult/vuln_dur）",
		gates.size() == 4
		and gates.has("%d|freeze_dur" % GameConst.ReactionType.RXN_ICE_HYD)
		and gates.has("%d|chill_dur" % GameConst.ReactionType.RXN_ICE_HYD)
		and gates.has("%d|vuln_mult" % GameConst.ReactionType.RXN_ICE_HYD)
		and gates.has("%d|vuln_dur" % GameConst.ReactionType.RXN_ICE_HYD),
		str(gates))
	_retire_enemy(e)
	sys.free()
	_restore_balance()
	# 同条件回放（真表）：零缺键告警 + 表值逐值
	var sys2 := ElementalSystem.new()
	sys2.name = "R198RestoredSys"
	tree.get_root().add_child(sys2)
	sys2.pipeline = _pipeline
	var e2 := _spawn_enemy("E_R198_RESTORE", Vector2(360, 700))
	sys2.register_host(e2)
	var st2 := e2.get("elemental") as ElementalState
	sys2.apply_attach(e2, GameConst.Element.ICE, 50.0)
	sys2.apply_attach(e2, GameConst.Element.HYD, 100.0)
	st2.freeze_timer = 0.0
	st2.chill_timer = 0.0
	st2.vuln_mult = 1.0
	st2.vuln_timer = 0.0
	_bump_frame()
	sys2.detect_reactions()
	_check("①a 真表对照：零缺键告警 + 表值冻结 1.2s/寒滞 2.5s/易伤 ×1.25 3s",
		sys2._rule_missing_warned.is_empty()
		and _approx(st2.freeze_timer, 1.2) and _approx(st2.chill_timer, 2.5)
		and _approx(st2.vuln_mult, 1.25) and _approx(st2.vuln_timer, 3.0),
		str(sys2._rule_missing_warned))
	_retire_enemy(e2)
	sys2.free()


# ── ①b R192-low1：reaction_stat_text 缺键/枚举错位告警 + 合法无统计段静默 ──
func _test_stat_text_alarm_and_legal_silent() -> void:
	print("── ①b R192-low1 stat 统计段读表守卫 ──")
	_swap_balance_missing(["RXN_ICE_LTG"])     # 超导整键删除 → 表缺键路径
	var t1 := DamagePopup.reaction_stat_text(GameConst.ReactionType.RXN_ICE_LTG)
	_check("①b 表缺键：reaction_stat_text 返回空串且告警闸记账（RXN_ICE_LTG）",
		t1 == "" and DamagePopup._missing_stat_rule_warned.has("RXN_ICE_LTG"),
		"text=%s warned=%s" % [t1, str(DamagePopup._missing_stat_rule_warned.keys())])
	var t2 := DamagePopup.reaction_stat_text(9999)     # 枚举错位（值域外 rxn）
	_check("①b 枚举错位：reaction_stat_text 返回空串且告警闸记账（rxn=9999）",
		t2 == "" and DamagePopup._missing_stat_rule_warned.has(9999),
		"text=%s warned=%s" % [t2, str(DamagePopup._missing_stat_rule_warned.keys())])
	_restore_balance()
	# 合法无统计段（感电 RXN_LTG_HYD：表键在位而规则 = {}）——零告警静默空串
	var t3 := DamagePopup.reaction_stat_text(GameConst.ReactionType.RXN_LTG_HYD)
	_check("①b 合法无统计段（感电）：空串且零告警（禁误报——:220 注释口径）",
		t3 == "" and not DamagePopup._missing_stat_rule_warned.has("RXN_LTG_HYD")
		and not DamagePopup._missing_stat_rule_warned.has(GameConst.ReactionType.RXN_LTG_HYD),
		"text=%s warned=%s" % [t3, str(DamagePopup._missing_stat_rule_warned.keys())])
	var t4 := DamagePopup.reaction_stat_text(GameConst.ReactionType.RXN_FIR_ANE)
	_check("①b 合法无统计段（扩散·火）：空串且零告警", t4 == ""
		and not DamagePopup._missing_stat_rule_warned.has("RXN_FIR_ANE"))


# ── ①c R192-low1（系统侧）：感电反应臂零 rule 取键 → 会话闸全空 ─────
func _test_shock_reaction_zero_alarm() -> void:
	print("── ①c R192-low1 感电反应臂零误报 ──")
	var sys := ElementalSystem.new()
	sys.name = "R198ShockSys"
	tree.get_root().add_child(sys)
	sys.pipeline = _pipeline
	sys.enemy_grid = _grid
	var e := _spawn_enemy("E_R198_SHOCK", Vector2(360, 400))
	sys.register_host(e)
	sys.apply_attach(e, GameConst.Element.LTG, 50.0)   # 半槽雷（不满槽，附着臂不触发连锁）
	sys.apply_attach(e, GameConst.Element.HYD, 100.0)
	var rxn0: int = DebugStats.get_counter(&"reaction_triggered")
	_bump_frame()
	sys.detect_reactions()
	_check("①c 感电反应正常触发（+1 计数 · 双槽清空）",
		DebugStats.get_counter(&"reaction_triggered") == rxn0 + 1
		and _approx((e.get("elemental") as ElementalState).gauges[GameConst.Element.LTG], 0.0)
		and _approx((e.get("elemental") as ElementalState).gauges[GameConst.Element.HYD], 0.0))
	_check("①c 感电臂零缺键告警（合法无键规则不入取键路径——会话闸全空）",
		sys._rule_missing_warned.is_empty(), str(sys._rule_missing_warned))
	_retire_enemy(e)
	sys.free()


# ── ② R192-low2：冻结臂 IMMUNE_CHILL 检位（镜像附着段先例） ─────────
func _test_freeze_arm_immune_chill() -> void:
	print("── ② R192-low2 冻结臂 IMMUNE_CHILL 检位 ──")
	# 冰免疫（IMMUNE_CHILL）目标：整段不吃冻结/寒滞/易伤；清槽与广播保持无条件
	var e1 := _spawn_enemy("E_R198_CHILLIM", Vector2(200, 400))
	_sys.register_host(e1)
	var st1 := e1.get("elemental") as ElementalState
	st1.immune_mask = GameConst.IMMUNE_CHILL   # 仅寒滞免疫位（不含 IMMUNE_FREEZE——半边分离）
	var rxn0: int = DebugStats.get_counter(&"reaction_triggered")
	_sys.apply_attach(e1, GameConst.Element.ICE, 50.0)
	_sys.apply_attach(e1, GameConst.Element.HYD, 100.0)
	st1.freeze_timer = 0.0
	st1.chill_timer = 0.0
	st1.vuln_mult = 1.0
	st1.vuln_timer = 0.0
	_bump_frame()
	_sys.detect_reactions()
	_check("② IMMUNE_CHILL：冻结反应仍触发（计数 +1 · 双槽清空——消费契约不受免疫影响）",
		DebugStats.get_counter(&"reaction_triggered") == rxn0 + 1
		and _approx(st1.gauges[GameConst.Element.ICE], 0.0)
		and _approx(st1.gauges[GameConst.Element.HYD], 0.0))
	_check("② IMMUNE_CHILL：freeze 不发生（无 IMMUNE_FREEZE 位仍不冻）且 chill==0/vuln 不变",
		_approx(st1.freeze_timer, 0.0) and _approx(st1.chill_timer, 0.0)
		and _approx(st1.vuln_mult, 1.0) and _approx(st1.vuln_timer, 0.0),
		"freeze=%s chill=%s vuln=%s/%s" % [str(st1.freeze_timer), str(st1.chill_timer),
			str(st1.vuln_mult), str(st1.vuln_timer)])
	_retire_enemy(e1)
	# IMMUNE_FREEZE 半边语义不变（无寒滞免疫位）：拒定身仍吃寒滞/易伤——F-17 Boss 口径
	var e2 := _spawn_enemy("E_R198_FRZIM", Vector2(360, 400))
	_sys.register_host(e2)
	var st2 := e2.get("elemental") as ElementalState
	st2.immune_mask = GameConst.IMMUNE_FREEZE
	_sys.apply_attach(e2, GameConst.Element.ICE, 50.0)
	_sys.apply_attach(e2, GameConst.Element.HYD, 100.0)
	st2.freeze_timer = 0.0
	st2.chill_timer = 0.0
	st2.vuln_mult = 1.0
	st2.vuln_timer = 0.0
	_bump_frame()
	_sys.detect_reactions()
	_check("② IMMUNE_FREEZE 半边不变：不定身（freeze==0）仍吃寒滞 2.5s/易伤 ×1.25 3s",
		_approx(st2.freeze_timer, 0.0) and _approx(st2.chill_timer, 2.5)
		and _approx(st2.vuln_mult, 1.25) and _approx(st2.vuln_timer, 3.0),
		"freeze=%s chill=%s vuln=%s/%s" % [str(st2.freeze_timer), str(st2.chill_timer),
			str(st2.vuln_mult), str(st2.vuln_timer)])
	_retire_enemy(e2)
	# 非免疫目标：逐值不变（冻结 1.2s / 寒滞 2.5s / 易伤 ×1.25 3s）
	var e3 := _spawn_enemy("E_R198_PLAIN", Vector2(520, 400))
	_sys.register_host(e3)
	var st3 := e3.get("elemental") as ElementalState
	st3.immune_mask = 0
	_sys.apply_attach(e3, GameConst.Element.ICE, 50.0)
	_sys.apply_attach(e3, GameConst.Element.HYD, 100.0)
	st3.freeze_timer = 0.0
	st3.chill_timer = 0.0
	st3.vuln_mult = 1.0
	st3.vuln_timer = 0.0
	_bump_frame()
	_sys.detect_reactions()
	_check("② 非免疫目标逐值不变：冻结 1.2s / 寒滞 2.5s / 易伤 ×1.25 3s",
		_approx(st3.freeze_timer, 1.2) and _approx(st3.chill_timer, 2.5)
		and _approx(st3.vuln_mult, 1.25) and _approx(st3.vuln_timer, 3.0),
		"freeze=%s chill=%s vuln=%s/%s" % [str(st3.freeze_timer), str(st3.chill_timer),
			str(st3.vuln_mult), str(st3.vuln_timer)])
	_retire_enemy(e3)


# ── ③ R192-low6：绽放 delay 1.5→0.75 双源同批锁 ───────────────────
func _test_bloom_delay_dual_source() -> void:
	print("── ③ R192-low6 绽放 delay 双源同批（1.5→0.75，R198 契约变更） ──")
	var rt_runtime: Dictionary = GameConfig.balance.reaction_table
	var rt_default: Dictionary = BalanceTables.new().reaction_table   # .gd 脚本默认源
	var rt_tres: Dictionary = (load(BALANCE_PATH) as BalanceTables).reaction_table
	_check("③ 双源同值：运行时（.tres）== .gd 默认 == 0.75（validator 双源闸同批）",
		_approx(float(rt_runtime["RXN_HYD_DEN"]["delay"]), 0.75)
		and _approx(float(rt_default["RXN_HYD_DEN"]["delay"]), 0.75)
		and _approx(float(rt_tres["RXN_HYD_DEN"]["delay"]), 0.75),
		"runtime=%s default=%s" % [str(rt_runtime["RXN_HYD_DEN"]["delay"]),
			str(rt_default["RXN_HYD_DEN"]["delay"])])
	_check("③ coef/radius 不随调参漂移：χ1.5 / r120 保持",
		_approx(float(rt_runtime["RXN_HYD_DEN"]["coef"]), 1.5)
		and _approx(float(rt_runtime["RXN_HYD_DEN"]["radius"]), 120.0))
	# 行为臂：触发绽放 → bloom_timer≈0.75（R198 契约变更后延迟口径锁表值）
	var e := _spawn_enemy("E_R198_BLOOM", Vector2(640, 400))
	_sys.register_host(e)
	_sys.apply_attach(e, GameConst.Element.HYD, 50.0)
	_sys.apply_attach(e, GameConst.Element.DEN, 100.0)
	_bump_frame()
	_sys.detect_reactions()
	var st := e.get("elemental") as ElementalState
	_check("③ 行为臂：bloom_active 挂账 · bloom_timer≈0.75（锁表值 delay==0.75）",
		st.bloom_active and _approx(st.bloom_timer, 0.75, 0.001),
		"timer=%s" % str(st.bloom_timer))
	_retire_enemy(e)


# ── ④⑤ R192-low7/9：卡名消歧 + 四新卡箭头式配对 ───────────────────
func _card(p_id: String) -> TraitData:
	return load("res://resources/traits/%s.tres" % p_id) as TraitData


func _test_card_name_and_pairing() -> void:
	print("── ④⑤ R192-low7 卡名消歧 + R192-low9 四新卡箭头式 ──")
	var shock := _card("ELE_SHOCK")
	_check("④ R192-low7：ELE_SHOCK display_name==「雷引」（卡名让位反应名）",
		shock != null and String(shock.display_name) == "雷引",
		str(shock.display_name if shock != null else "<缺卡>"))
	_check("④ R192-low7：反应名「感电」单源不动（REACTION_NAMES + REACTION_LOOKS + 跳字名）",
		String(GameConst.REACTION_NAMES[GameConst.ReactionType.RXN_LTG_HYD]) == "感电"
		and String(DamagePopup.REACTION_LOOKS[GameConst.ReactionType.RXN_LTG_HYD]["name"]) == "感电")
	# 四新卡 desc 配对枚举「X→反应名」同构口径（R192-low9）
	var hydro := _card("ELE_HYDRO")
	var dendro := _card("ELE_DENDRO")
	var anemo := _card("ELE_ANEMO")
	var geo := _card("ELE_GEO")
	_check("⑤ 水卡（既有口径基准）：火→蒸发 · 冰→冻结 · 雷→感电 · 草→绽放",
		hydro != null and String(hydro.description).contains("火→蒸发")
		and String(hydro.description).contains("冰→冻结")
		and String(hydro.description).contains("雷→感电")
		and String(hydro.description).contains("草→绽放"))
	_check("⑤ 草卡：火→燃烧 · 雷→激化 · 水→绽放 · 风→扩散·草",
		dendro != null and String(dendro.description).contains("火→燃烧")
		and String(dendro.description).contains("雷→激化")
		and String(dendro.description).contains("水→绽放")
		and String(dendro.description).contains("风→扩散·草"))
	var anemo_d := String(anemo.description) if anemo != null else ""
	_check("⑤ 风卡：五配对箭头式全为「X→扩散·X」（反应名带·元素后缀）+ 岩→结晶·风",
		anemo_d.contains("火→扩散·火") and anemo_d.contains("冰→扩散·冰")
		and anemo_d.contains("雷→扩散·雷") and anemo_d.contains("水→扩散·水")
		and anemo_d.contains("草→扩散·草") and anemo_d.contains("岩→结晶·风"),
		anemo_d)
	_check("⑤ 风卡：无「遇…即」列表式残留（同构口径收口）",
		not anemo_d.contains("遇") and not anemo_d.contains("风+岩"), anemo_d)
	var geo_d := String(geo.description) if geo != null else ""
	_check("⑤ 岩卡：任意元素→结晶·X 箭头式（结晶族六名引 REACTION_NAMES 词）",
		geo_d.contains("任意元素→结晶·火/冰/雷/水/草/风"),
		geo_d)
	_check("⑤ 岩卡：无「遇…即」列表式残留", not geo_d.contains("遇"), geo_d)
	# 卡族主题名风格锚（R192-low7 口径对齐）：潮湿/草种/风域/岩铠/雷引
	_check("⑤ 卡族主题名风格：五元素卡各具主题名（潮湿/草种/风域/岩铠/雷引）",
		String(hydro.display_name) == "潮湿" and String(dendro.display_name) == "草种"
		and String(anemo.display_name) == "风域" and String(geo.display_name) == "岩铠"
		and String(shock.display_name) == "雷引")


# ── ⑥ R192-low10：popup 分桶逐值映射锁（与头注枚举对齐） ───────────
func _test_popup_bucket_map() -> void:
	print("── ⑥ R192-low10 popup 分桶映射（直击 0 / 反应 1 / 其余 2 / 文字 3 / 引爆 4） ──")
	var m := {
		GameConst.PopupStyle.NORMAL: 0,
		GameConst.PopupStyle.CRIT: 0,
		GameConst.PopupStyle.REACTION: 1,
		GameConst.PopupStyle.DOT: 2,
		GameConst.PopupStyle.HEAL: 2,
		GameConst.PopupStyle.XP: 2,
		GameConst.PopupStyle.IMMUNE: 2,
		GameConst.PopupStyle.CHARGE_BURST: 4,
	}
	var ok := true
	var bad := ""
	for style in m:
		if PopupManager._style_bucket(int(style)) != int(m[style]):
			ok = false
			bad = "%d→%d" % [int(style), PopupManager._style_bucket(int(style))]
			break
	_check("⑥ _style_bucket 逐值映射 == 头注桶枚举（含 CHARGE_BURST→4，R187）", ok, bad)


# ── ⑦ R192-low3：燃烧「5层」口径（设计文档 R198 回写的实机一致性锁） ──
func _test_burn_layer_wording() -> void:
	print("── ⑦ R192-low3 燃烧带层数口径 ──")
	_check("⑦ 跳字统计段：燃烧读表 burn_layers_max →「5层」（stat 型带层数非无数）",
		DamagePopup.reaction_stat_text(GameConst.ReactionType.RXN_FIR_DEN) == "5层",
		DamagePopup.reaction_stat_text(GameConst.ReactionType.RXN_FIR_DEN))
	var mult_fmt := String(GameConst.reaction_note("RXN_FIR_DEN")["mult_fmt"])
	_check("⑦ 图鉴 mult_fmt：「至多 N 层」口径（game_const.gd 文案真源未动）",
		mult_fmt.contains("至多") and mult_fmt.contains("层"), mult_fmt)
	# 其余 stat 型如实用词核对（设计文档表格逐行同源）
	_check("⑦ 其余 stat 型：超导-30% / 激化+25% / 结晶-15% / 冻结1.2s（如实用词不漂移）",
		DamagePopup.reaction_stat_text(GameConst.ReactionType.RXN_ICE_LTG) == "-30%"
		and DamagePopup.reaction_stat_text(GameConst.ReactionType.RXN_LTG_DEN) == "+25%"
		and DamagePopup.reaction_stat_text(GameConst.ReactionType.RXN_FIR_GEO) == "-15%"
		and DamagePopup.reaction_stat_text(GameConst.ReactionType.RXN_ICE_HYD) == "1.2s")


# ── ⑧ r195-5：confetti 落雨恒用世界 720 域 ─────────────────────────
func _test_confetti_world_domain() -> void:
	print("── ⑧ r195-5 confetti 落雨世界域（960 宽画布域下 x∈[0,720]） ──")
	# 3:4 画布（960 宽）SubViewport：get_visible_rect 是画布域（960），piece 坐标属世界
	# 720×1280 逻辑域——落雨带恒 [0,720]（3:4 画布世界可见带 [-120,840] ⊇ 落雨带全覆盖）
	var vp := SubViewport.new()
	vp.size = Vector2i(960, 1280)
	vp.name = "R198RainVP"
	tree.get_root().add_child(vp)
	var confetti := ConfettiBurst.new()
	confetti.name = "R198Confetti"
	vp.add_child(confetti)
	confetti._celebrate(Vector2(360.0, 640.0))
	var pieces: Array[Dictionary] = confetti._pieces
	_check("⑧ 爆发齐量：PIECE_COUNT 64 + RAIN_COUNT 26 = 90 枚",
		pieces.size() == ConfettiBurst.PIECE_COUNT + ConfettiBurst.RAIN_COUNT,
		str(pieces.size()))
	var all_in := true
	var max_x := -1.0
	var min_x := 9999.0
	for piece in pieces:
		var x := (piece["pos"] as Vector2).x
		max_x = maxf(max_x, x)
		min_x = minf(min_x, x)
		if x < 0.0 or x > 720.0:
			all_in = false
	_check("⑧ 全部 piece 初始 x∈[0,720]（世界 720 域——画布 960 宽不外溢）",
		all_in, "min_x=%s max_x=%s" % [str(min_x), str(max_x)])
	var rain_all_in := true
	var rain_max := -1.0
	for i in range(ConfettiBurst.RAIN_COUNT):
		var piece2: Dictionary = pieces[pieces.size() - 1 - i]   # 落雨段 = 尾部 RAIN_COUNT 枚
		var rx := (piece2["pos"] as Vector2).x
		rain_max = maxf(rain_max, rx)
		if rx < 0.0 or rx > 720.0:
			rain_all_in = false
	_check("⑧ 落雨带（尾部 26 枚）x∈[0,720] ⊆ 世界可见带 [-120,840]（3:4 画布全覆盖）",
		rain_all_in and rain_max <= 720.0, "rain_max_x=%s" % str(rain_max))
	vp.free()                                  # 非池化临时件（自由新建直 free——池化纪律不涉）


# ── ⑨ r195-6：beam_impact 迸裂池 20 槽预建 ─────────────────────────
func _test_impact_pool_20() -> void:
	print("── ⑨ r195-6 beam_impact 迸裂池扩容 10→20 ──")
	var layer := ElementalFxLayer.new()
	layer.name = "R198FxLayer"
	tree.get_root().add_child(layer)           # _ready 预建全部池 + 订阅表现层广播
	_check("⑨ 池槽总数==20 且常量同步（IMPACT_COUNT 10→20）",
		ElementalFxLayer.IMPACT_COUNT == 20 and layer._impacts.size() == 20,
		"const=%d size=%d" % [ElementalFxLayer.IMPACT_COUNT, layer._impacts.size()])
	var beam_slots := 0
	for c in layer.get_children():
		if String(c.name).begins_with("BeamImpact"):
			beam_slots += 1
	_check("⑨ 预建槽位：BeamImpact* 子节点恰 20（_ready 一次建齐）", beam_slots == 20,
		str(beam_slots))
	var children_before := layer.get_child_count()
	for i in range(25):                        # 25 次 > 20 槽 → 轮转回绕（_impact_idx 取模）
		layer._on_beam_impact(Vector2(360.0, 640.0), Vector2.RIGHT)
	layer._tick_impacts(1.0 / 60.0)
	_check("⑨ 命中/tick 路径零 add_child：子节点数不变（静态池零运行期实例化）",
		layer.get_child_count() == children_before,
		"before=%d after=%d" % [children_before, layer.get_child_count()])
	layer.free()                               # 非池化临时件（表现层宿主直 free）

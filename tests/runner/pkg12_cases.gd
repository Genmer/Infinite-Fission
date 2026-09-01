# tests/runner/pkg12_cases.gd
# v1.2.0 自测用例体（由 test_pkg12.gd 入口在 autoload 就绪后运行时加载编译）。
# 覆盖冻结方案 pkg12 用例组 V41~V56（A11_v1.2.0_design.md；每恰 1 断言）：
#   V41 WAT 基建 / V42 TIDE / V43 冻结触发 / V44 冻结全停 / V45 破碎
#   （W3b/W4/W5-W7/W8/W9 期追加 V46~V56）
# 确定性：真件 DamagePipeline（seed 42）+ crit_rate=0（不掷骰）+ 固定坐标/面板；
#         帧闸门经 GameConfig.frame_stamp 手动推进 + begin_frame 清幂等缓存。
extends RefCounted

const BALLISTIC_SCENE := "res://scenes/combat/projectiles/ballistic_projectile.tscn"
const ENEMY_SCENE := "res://scenes/combat/enemies/enemy.tscn"
const DT := 1.0 / 120.0
const ENEMY_TRES: Array[String] = [
	"res://resources/enemies/E1_grunt.tres", "res://resources/enemies/E2_runner.tres",
	"res://resources/enemies/E3_bastion.tres", "res://resources/enemies/E4_volatile.tres",
	"res://resources/enemies/E5_elite.tres", "res://resources/enemies/E6_boss1.tres",
	"res://resources/enemies/E6_boss2.tres", "res://resources/enemies/E6_boss3.tres",
]

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
var _captured: Array[DamageResult] = []        # damage_resolved 捕获（每次 _fire_at 清空）
var _rxn_events: Array[int] = []               # reaction_triggered 广播捕获


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_ensure_autoloads()
	_setup_world()
	_test_v41_wat_infra()                         # V41
	_test_v42_tide()                              # V42
	_test_v43_freeze_trigger()                    # V43
	_test_v44_freeze_fullstop()                   # V44
	_test_v45_shatter()                           # V45
	_test_v46_conduct()                           # V46
	_test_v47_vaporblast()                        # V47
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
	_proj_pool.name = "Pkg12ProjPool"
	tree.get_root().add_child(_proj_pool)
	_proj_pool.setup(&"pkg12_test", load(BALLISTIC_SCENE), 64)
	var ep := EnemyPool.new()
	ep.name = "Pkg12EnemyPool"
	tree.get_root().add_child(ep)
	ep.setup(&"pkg12_enemy", load(ENEMY_SCENE), 48)
	_enemy_pool = ep
	_grid = SpaceGrid.new()
	_grid.configure(Vector2(720, 1280), 192.0)
	_alive_enemies.clear()
	_captured.clear()
	_pipeline = DamagePipeline.new()
	_pipeline.set_rng_seed(42)
	_sys = ElementalSystem.new()
	_sys.name = "Pkg12ElementalSystem"
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


func _last_result() -> DamageResult:
	if _captured.is_empty():
		return null
	return _captured[_captured.size() - 1]


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


func _panel() -> Dictionary:
	# 零暴击零加算面板（伤害手算锚：final = base_atk × ∏M，resist 0）
	return {
		"base_atk": 100.0, "crit_rate": 0.0, "crit_mult": 2.0,
		"flat_bonus": 0.0, "add_entries": [], "chip_atk_pct": 0.0,
	}


func _spawn_proj(p_element: int, p_pos: Vector2, p_attach: float = 30.0, p_pierce: int = 1,
		p_stack: TraitStack = null, p_elemental: ElementalSystem = null) -> ProjectileBase:
	var proj := _proj_pool.acquire() as ProjectileBase
	proj.damage_pipeline = _pipeline
	proj.enemy_grid = _grid
	proj.pool = _proj_pool
	proj.elemental = p_elemental if p_elemental != null else _sys
	proj.spawn({
		"velocity": Vector2.ZERO,
		"lifetime": 1.0,
		"pierce": p_pierce,
		"bounces": 0,
		"hitbox_radius": 6.0,
		"element": p_element,
		"attach_value": p_attach,
		"generation": 0,
		"weapon_uid": 0,
		"panel_snapshot": _panel(),
		"team": 0,
		"position": p_pos,
		"trait_stack": p_stack,
	})
	return proj


func _fire_at(p_proj: ProjectileBase) -> void:
	# 单帧推进：清捕获/广播 + 帧号推进 + 幂等缓存清空（GameLoop 帧序的测试侧替身）+ 一 tick
	_captured.clear()
	_rxn_events.clear()
	_bump()
	_pipeline.begin_frame()
	p_proj.tick(DT)


func _detect(p_frames: int = 1) -> void:
	# 帧末检测替身（GameLoop 帧序：敌人阶段后调 detect_reactions）
	_captured.clear()
	_rxn_events.clear()
	for _i in range(p_frames):
		_bump()
		_pipeline.begin_frame()
	_sys.detect_reactions()


func _gauge(p_enemy: Node2D, p_element: int, p_value: float) -> void:
	# 非满槽预置附着（无状态触发）；snapshot 100 供剧变快照通道（过载/导电/汽爆基数）
	_sys.apply_attach(p_enemy, p_element, p_value, {"snapshot": 100.0})


func _freeze(p_enemy: Node2D) -> void:
	# 预置冻结（WAT+ICE 双附着 → 帧末检测）
	_gauge(p_enemy, GameConst.Element.WAT, 30.0)
	_gauge(p_enemy, GameConst.Element.ICE, 30.0)
	_detect()


func _read_source(p_path: String) -> String:
	var f := FileAccess.open(p_path, FileAccess.READ)
	if f == null:
		return ""
	return f.get_as_text()


func _purge_enemies() -> void:
	# 用例间隔离：归还全部存活敌 + 清空网格（池化复用，spawn 全量重置）——
	# V46/V47 的连锁/扩散几何要求无邻近杂敌（query_circle 保守半径 160+64）
	for e in _alive_enemies:
		_sys.unregister_host(e)
		_enemy_pool.release(e)
	_alive_enemies.clear()
	_grid.rebuild(_alive_enemies)


# ── V41 WAT 基建 ──────────────────────────────────────────────────
func _test_v41_wat_infra() -> void:
	print("── V41 WAT 基建 ──")
	# a) 枚举值 WAT=4（旧值零重编号）
	var enum_ok: bool = int(GameConst.Element.WAT) == 4 \
		and int(GameConst.Element.KIN) == 0 and int(GameConst.Element.FIR) == 1 \
		and int(GameConst.Element.ICE) == 2 and int(GameConst.Element.LTG) == 3
	# b) gauges 5 槽 + apply 满 100 清槽返 NONE 且无状态字段（WAT 无满槽状态臂）
	var st := ElementalState.new()
	var gauge5 := st.gauges.size() == 5
	var code: int = st.apply(GameConst.Element.WAT, 100.0)
	var full_none := code == ElementalState.TRIGGER_NONE \
		and _approx(st.gauges[GameConst.Element.WAT], 0.0) \
		and st.burn_timer <= 0.0 and st.chill_timer <= 0.0 and st.freeze_timer <= 0.0
	# c) λ 三处 4 项（schema 默认 / GameConfig.balance 加载值 / validator 无告警）
	var schema_n := BalanceTables.new().element_decay_lambda.size()
	var loaded_n: int = GameConfig.balance.element_decay_lambda.size() \
		if GameConfig.balance != null else -1
	var validator_clean := true
	for issue in DataValidator.new().validate_balance(BalanceTables.new()):
		var row: Dictionary = issue
		if String(row.get("message", "")).contains("element_decay_lambda"):
			validator_clean = false
	# d) 8 敌 .tres resist size 5
	var resist_ok := true
	var resist_detail := ""
	for path in ENEMY_TRES:
		var res: Resource = load(path)
		if res == null or not (res is EnemyData) or (res as EnemyData).resist.size() != 5:
			resist_ok = false
			resist_detail += "%s " % path
	# e) ELEMENT_COLORS 5 + WAT 色（A11 §1 冻结）
	var colors := ProjectileBase.ELEMENT_COLORS
	var wat := colors[GameConst.Element.WAT]
	var colors_ok := colors.size() == 5 and _approx(wat.r, 0.3) and _approx(wat.g, 0.75) \
		and _approx(wat.b, 0.9)
	# f) ElementRing TAU/4 四色
	var ring_ok: bool = Enemy.ElementRing.SECTOR == TAU / 4.0 \
		and Enemy.ElementRing.RING_COLORS.size() == 4
	# g) 无 4 槽状态字面量残留（elemental_state gauges / enemy set_gauges 调用点 grep；
	#    ElementRing._gauges 4 槽 = FIR/ICE/LTG/WAT 显示快照，属新口径合法字面量）
	var src_state := _read_source("res://scripts/combat/elemental/elemental_state.gd")
	var src_enemy := _read_source("res://scripts/entities/enemy/enemy.gd")
	var grep_ok := (not src_state.is_empty()) and (not src_enemy.is_empty()) \
		and not src_state.contains("[0.0, 0.0, 0.0, 0.0]") \
		and not src_enemy.contains("set_gauges([0.0, 0.0, 0.0, 0.0])")
	_check("V41：WAT 基建——枚举 WAT=4 旧序零变 / gauges 5 槽满 100 清槽返 NONE / λ 三处 4 项 / 8 敌 .tres resist 5 / ELEMENT_COLORS 5 WAT 色 / Ring TAU÷4 四色 / 无 4 槽字面量残留",
		enum_ok and gauge5 and full_none and schema_n == 4 and loaded_n == 4 and validator_clean
		and resist_ok and colors_ok and ring_ok and grep_ok,
		"enum=%s g5=%s none=%s λ=%s/%s clean=%s resist=%s%s colors=%s ring=%s grep=%s"
			% [str(enum_ok), str(gauge5), str(full_none), str(schema_n), str(loaded_n),
			str(validator_clean), str(resist_ok), resist_detail, str(colors_ok), str(ring_ok),
			str(grep_ok)])


# ── V42 ELE_TIDE ──────────────────────────────────────────────────
func _test_v42_tide() -> void:
	print("── V42 TIDE ──")
	# a) .tres 字段镜像（A11 §9 H1）
	var tide: TraitData = load("res://resources/traits/ELE_TIDE.tres") as TraitData
	var fields_ok: bool = tide != null and tide.id == &"ELE_TIDE" \
		and tide.display_name == "潮汐弹药" and tide.pool == GameConst.PoolClass.ELEM \
		and tide.effect_id == &"EF_ELEMENTAL" \
		and int(tide.params.get("element", -1)) == 4 \
		and _approx(float(tide.params.get("value", 0.0)), 22.0) \
		and _approx(float(tide.params.get("value_lv2", 0.0)), 33.0) \
		and tide.stack_max == 2 and tide.rarity == 2 and _approx(tide.value, 22.0)
	# b) traits 计数 32（registry 加载口径）
	var reg := DataRegistry.new()
	reg.load_all("res://data/manifest.cfg")
	var count_ok: bool = reg.traits.size() == 32 and int(reg.report.get("rejected", -1)) == 0
	# c) 层 2 附着 ×1.5（22 → 33）
	var e := _spawn_enemy(_make_enemy_data("V42"), Vector2(360, 300))
	_sys.register_host(e)
	var stack := TraitStack.new()
	stack.attach(tide)
	stack.attach(tide)
	_fire_at(_spawn_proj(GameConst.Element.KIN, e.global_position, 0.0, 1, stack))
	var st: ElementalState = e.get("elemental")
	var lv2_ok: bool = st != null and _approx(st.gauges[GameConst.Element.WAT], 33.0)
	_check("V42：ELE_TIDE——.tres 字段镜像（element 4 / 22 / lv2 33 / stack 2 / rarity 2）/ traits 32 剔除 0 / 层 2 附着 33",
		fields_ok and count_ok and lv2_ok,
		"fields=%s count=%s lv2=%s" % [str(fields_ok), str(count_ok),
			str(st.gauges[GameConst.Element.WAT] if st != null else -1.0)])


# ── V43 冻结触发 ──────────────────────────────────────────────────
func _test_v43_freeze_trigger() -> void:
	print("── V43 冻结触发 ──")
	# a) 未拦截：freeze_timer 2.5 + 双槽清 + 广播 + reaction_freeze 计数 + CD 5.0
	var e1 := _spawn_enemy(_make_enemy_data("V43_A"), Vector2(120, 200))
	_sys.register_host(e1)
	var cnt0: int = DebugStats.get_counter(&"reaction_freeze")
	_freeze(e1)
	var st1: ElementalState = e1.get("elemental")
	var a_ok: bool = st1 != null and _approx(st1.freeze_timer, 2.5) \
		and _approx(st1.gauges[GameConst.Element.WAT], 0.0) \
		and _approx(st1.gauges[GameConst.Element.ICE], 0.0) \
		and _rxn_events.has(GameConst.ReactionType.RXN_WAT_ICE) \
		and DebugStats.get_counter(&"reaction_freeze") == cnt0 + 1 \
		and _approx(float(st1.reaction_cd.get(GameConst.ReactionType.RXN_WAT_ICE, -1.0)), 5.0)
	# b) 免疫定身（Boss）：timer 0 + 双槽仍清 + 零广播（CD 已耗）
	var e2 := _spawn_enemy(_make_enemy_data("V43_B"), Vector2(400, 200))
	e2.immune_mask = GameConst.IMMUNE_FREEZE
	_sys.register_host(e2)                        # register_host 注入 immune_mask=1 的状态容器
	_freeze(e2)
	var st2: ElementalState = e2.get("elemental")
	var b_ok: bool = st2 != null and st2.freeze_timer <= 0.0 \
		and _approx(st2.gauges[GameConst.Element.WAT], 0.0) \
		and _approx(st2.gauges[GameConst.Element.ICE], 0.0) \
		and not _rxn_events.has(GameConst.ReactionType.RXN_WAT_ICE) \
		and DebugStats.get_counter(&"reaction_freeze") == cnt0 + 1
	_check("V43：冻结触发——timer 2.5 + WAT/ICE 双槽清 + 广播 + 计数 + CD 5s；immune_mask=1 拦截 timer 0 双槽仍清零广播",
		a_ok and b_ok,
		"a=%s b=%s" % [str(a_ok), str(b_ok)])


# ── V44 冻结全停 ──────────────────────────────────────────────────
func _test_v44_freeze_fullstop() -> void:
	print("── V44 冻结全停 ──")
	# a) RANGED：冻结 fire_cd 不减（对照：未冻结递减）
	var rd := _make_enemy_data("V44_R", 2000.0)
	rd.behavior = GameConst.EnemyBehavior.RANGED
	rd.ranged = {"bullet_speed": 300.0, "fire_cd": 1.5, "bullet_atk_ratio": 0.5, "spread": 0.0}
	var r1 := _spawn_enemy(rd, Vector2(360, 400))
	_sys.register_host(r1)
	r1.fire_cd_left = 1.0
	var player_stub := Node2D.new()
	player_stub.name = "Pkg12PlayerStub"
	tree.get_root().add_child(player_stub)
	player_stub.add_to_group(&"player")
	player_stub.position = Vector2(360, 1240)     # 远离（dist > fire_range，不实际开火）
	r1.tick(DT)                                   # 未冻结对照：fire_cd 递减
	var control_cd: float = r1.fire_cd_left
	_freeze(r1)
	r1.fire_cd_left = 1.0
	r1.tick(DT)                                   # 冻结：fire_cd 不减
	var frozen_cd: float = r1.fire_cd_left
	var ranged_ok := control_cd < 1.0 and _approx(frozen_cd, 1.0)
	# b) Boss：冻结弹幕/召唤计时全停
	var bd := _make_enemy_data("V44_B", 2000.0)
	bd.tags = GameConst.TAG_BOSS
	bd.boss = {"phases": 2, "phase2_resist": 0.0,
		"bullet_patterns": {"interval_s": 6.0, "pattern": "fan", "count": 8, "dmg": 10.0},
		"summons": {}}
	var b1 := _spawn_enemy(bd, Vector2(600, 400))
	_sys.register_host(b1)
	_freeze(b1)
	var cd0: float = b1._pattern_cd_left
	b1.tick(DT)
	var boss_ok := b1.is_boss() and _approx(b1._pattern_cd_left, cd0)
	# c) sf=0（速度因子通道）
	var st: ElementalState = r1.get("elemental")
	var sf_ok: bool = st != null and _approx(st.get_speed_factor(), 0.0)
	# d) burn DOT 照跳（冻结不拦 DOT 通道）
	var d1 := _spawn_enemy(_make_enemy_data("V44_D", 2000.0), Vector2(120, 600))
	_sys.register_host(d1)
	_sys.apply_attach(d1, GameConst.Element.FIR, 100.0, {"snapshot": 100.0})   # 满槽点燃
	_freeze(d1)
	_captured.clear()
	_sys.tick(0.5)
	var dot_ok := false
	for r in _captured:
		if r.popup_style == GameConst.PopupStyle.DOT and r.element == GameConst.Element.FIR:
			dot_ok = true
	_check("V44：冻结全停——RANGED fire_cd 不减（对照递减）/ Boss 弹幕计时全停 / sf=0 / burn DOT 照跳",
		ranged_ok and boss_ok and sf_ok and dot_ok,
		"ranged=%s(ctrl=%s fz=%s) boss=%s sf=%s dot=%s" % [str(ranged_ok), str(control_cd),
			str(frozen_cd), str(boss_ok), str(sf_ok), str(dot_ok)])
	player_stub.free()


# ── V45 破碎 ──────────────────────────────────────────────────────
func _test_v45_shatter() -> void:
	print("── V45 破碎 ──")
	# a) 3 次 NORMAL 直击 → timer 0 + 帧末结算 0.4×snapshot×φ（rm=1 无 VOID 注册 → 40 落血）
	#（HUD counts[3] 子断言随 W8 六槽 HUD 落地时并入本用例）
	var e1 := _spawn_enemy(_make_enemy_data("V45_A", 2000.0), Vector2(120, 800))
	_sys.register_host(e1)
	_freeze(e1)
	var st: ElementalState = e1.get("elemental")
	var hp0: float = e1.hp
	for i in range(3):
		_fire_at(_spawn_proj(GameConst.Element.KIN, e1.global_position))
	var hits_ok: bool = st != null and st.freeze_timer <= 0.0 \
		and st.freeze_shatter_pending and _approx(st.freeze_shatter_snapshot, 100.0)
	_captured.clear()
	_sys.tick(DT)                                 # 帧末破碎结算 0.4×100×1.0 = 40
	var settle_ok := false
	for r in _captured:
		if r.element == GameConst.ReactionType.RXN_WAT_ICE \
				and r.popup_style == GameConst.PopupStyle.REACTION \
				and _approx(r.final_value, 40.0):
			settle_ok = true
	_check("V45：破碎——3 NORMAL 直击解冻 + 帧末结算 40（0.4×snapshot×φ）落血",
		hits_ok and settle_ok and _approx(e1.hp, hp0 - 340.0, 0.01),
		"hits=%s settle=%s hp=%s" % [str(hits_ok), str(settle_ok), str(e1.hp)])
	# b) REACTION/DOT 不计入破碎
	var e2 := _spawn_enemy(_make_enemy_data("V45_B", 2000.0), Vector2(400, 800))
	_sys.register_host(e2)
	_freeze(e2)
	var st2: ElementalState = e2.get("elemental")
	var fake := DamageResult.new()
	fake.final_value = 40.0
	fake.popup_style = GameConst.PopupStyle.REACTION
	fake.panel_snapshot = 100.0
	e2.take_result(fake)
	var rxn_not_counted: bool = st2 != null and st2.freeze_hits == 0
	fake.popup_style = GameConst.PopupStyle.DOT
	e2.take_result(fake)
	var dot_not_counted: bool = st2 != null and st2.freeze_hits == 0
	# c) 到期清零：1 击后冻结自然到期 → 计数归零
	e2.take_result(_direct_fake())                # freeze_hits = 1
	_sys.tick(3.0)                                # 2.5s 冻结到期
	var expired_ok: bool = st2 != null and st2.freeze_timer <= 0.0 and st2.freeze_hits == 0
	_sys.tick(2.1)                                # 冻结 CD 5.0s 走完（3.0 + 2.1 ≥ 5.0）
	# d) 二次冻结重计
	_gauge(e2, GameConst.Element.WAT, 30.0)
	_gauge(e2, GameConst.Element.ICE, 30.0)
	_detect()
	e2.take_result(_direct_fake())
	var recount_ok: bool = st2 != null and st2.freeze_timer > 0.0 and st2.freeze_hits == 1
	_check("V45：破碎排除/到期/重计——REACTION/DOT 不计 / 到期清零 / 二次冻结重计",
		rxn_not_counted and dot_not_counted and expired_ok and recount_ok,
		"rxn=%s dot=%s exp=%s re=%s" % [str(rxn_not_counted), str(dot_not_counted),
			str(expired_ok), str(recount_ok)])


func _direct_fake() -> DamageResult:
	var r := DamageResult.new()
	r.final_value = 10.0
	r.popup_style = GameConst.PopupStyle.NORMAL
	r.panel_snapshot = 100.0
	return r


# ── V46 导电 ──────────────────────────────────────────────────────
func _test_v46_conduct() -> void:
	print("── V46 导电 ──")
	_purge_enemies()
	# a) 单列链：O→A→B→C 间距 200（query 保守 160+64=224 → 每跳恰 1 新目标）；X 距外
	# hop0 = 0.9×snapshot×φ(=1) = 90 → 54 → 32.4；主目标 REACTION 90；深度 3 封顶（X 不吃）
	var o := _spawn_enemy(_make_enemy_data("V46_O", 4000.0), Vector2(60, 700))
	_sys.register_host(o)
	var a := _spawn_enemy(_make_enemy_data("V46_A", 4000.0), Vector2(260, 700))
	_sys.register_host(a)
	var b := _spawn_enemy(_make_enemy_data("V46_B", 4000.0), Vector2(460, 700))
	_sys.register_host(b)
	var c := _spawn_enemy(_make_enemy_data("V46_C", 4000.0), Vector2(660, 700))
	_sys.register_host(c)
	var x := _spawn_enemy(_make_enemy_data("V46_X", 4000.0), Vector2(660, 900))
	_sys.register_host(x)
	_gauge(o, GameConst.Element.WAT, 30.0)
	_gauge(o, GameConst.Element.LTG, 30.0)
	_detect()
	var main_ok := false
	var hop_a := -1.0
	var hop_b := -1.0
	var hop_c := -1.0
	var hop_x := -1.0
	for r in _captured:
		if r.target_uid == int(o.get("uid")) and r.popup_style == GameConst.PopupStyle.REACTION \
				and r.element == GameConst.ReactionType.RXN_WAT_LTG \
				and _approx(r.final_value, 90.0):
			main_ok = true
		elif r.popup_style == GameConst.PopupStyle.DOT and r.element == GameConst.Element.LTG:
			if r.target_uid == int(a.get("uid")):
				hop_a = r.final_value
			elif r.target_uid == int(b.get("uid")):
				hop_b = r.final_value
			elif r.target_uid == int(c.get("uid")):
				hop_c = r.final_value
			elif r.target_uid == int(x.get("uid")):
				hop_x = r.final_value
	var chain_ok := main_ok and _approx(hop_a, 90.0) and _approx(hop_b, 54.0) \
		and _approx(hop_c, 32.4) and hop_x < 0.0
	# b) 清双槽 + CD 4.0
	var st: ElementalState = o.get("elemental")
	var clear_ok: bool = st != null and _approx(st.gauges[GameConst.Element.WAT], 0.0) \
		and _approx(st.gauges[GameConst.Element.LTG], 0.0) \
		and _approx(float(st.reaction_cd.get(GameConst.ReactionType.RXN_WAT_LTG, -1.0)), 4.0)
	_check("V46：导电——主 90×φ + BFS 3 跳衰减 90/54/32.4（深度封顶 X 不吃）+ WAT/LTG 双槽清 + CD 4s",
		chain_ok and clear_ok,
		"main=%s a=%s b=%s c=%s x=%s clear=%s" % [str(main_ok), str(hop_a), str(hop_b),
			str(hop_c), str(hop_x), str(clear_ok)])
	# c) 同帧 shock + conduct 并存：幂等键分流不互撞（共享目标吃两跳 35/90）
	_purge_enemies()
	var s_src := _spawn_enemy(_make_enemy_data("V46_S", 4000.0), Vector2(100, 1000))
	_sys.register_host(s_src)
	var s1 := _spawn_enemy(_make_enemy_data("V46_S1", 4000.0), Vector2(200, 1000))
	_sys.register_host(s1)
	var w_src := _spawn_enemy(_make_enemy_data("V46_W", 4000.0), Vector2(100, 1100))
	_sys.register_host(w_src)
	var shared := _spawn_enemy(_make_enemy_data("V46_SH", 4000.0), Vector2(260, 1050))
	_sys.register_host(shared)
	_bump()
	_pipeline.begin_frame()
	_captured.clear()
	_rxn_events.clear()
	# 同帧：感电（满 LTG 槽 → 即时 shock chain 35%×100）+ 导电（帧末 detect hop0 90）
	_sys.apply_attach(s_src, GameConst.Element.LTG, 100.0, {"hit_damage": 100.0})
	_gauge(w_src, GameConst.Element.WAT, 30.0)
	_gauge(w_src, GameConst.Element.LTG, 30.0)
	_sys.detect_reactions()
	var shared_jumps: Array[float] = []
	for r in _captured:
		if r.target_uid == int(shared.get("uid")) and r.popup_style == GameConst.PopupStyle.DOT:
			shared_jumps.append(r.final_value)
	var both_ok := shared_jumps.size() == 2 \
		and shared_jumps.has(35.0) and shared_jumps.has(90.0)
	_check("V46：同帧 shock+conduct 并存——共享目标吃两跳 35/90（_uid_chain/_uid_conduct 幂等分流不撞）",
		both_ok, "jumps=%s" % str(shared_jumps))


# ── V47 汽爆 ──────────────────────────────────────────────────────
func _test_v47_vaporblast() -> void:
	print("── V47 汽爆 ──")
	_purge_enemies()
	# a) 主 0.6×φ=60 + 半径 80 扩散（近 79 吃 / 远 95 不吃；窄相 reach=80+hitbox1=81）
	var vd := _make_enemy_data("V47_V", 4000.0)
	vd.hitbox_r = 1.0
	var v := _spawn_enemy(vd, Vector2(100, 200))
	_sys.register_host(v)
	var near_d := _make_enemy_data("V47_N", 4000.0)
	near_d.hitbox_r = 1.0
	var near := _spawn_enemy(near_d, Vector2(179, 200))
	_sys.register_host(near)
	var far_d := _make_enemy_data("V47_F", 4000.0)
	far_d.hitbox_r = 1.0
	var far := _spawn_enemy(far_d, Vector2(195, 200))
	_sys.register_host(far)
	_gauge(v, GameConst.Element.WAT, 30.0)
	_gauge(v, GameConst.Element.FIR, 30.0)
	_detect()
	var main_ok := false
	var near_hit := false
	var far_hit := false
	for r in _captured:
		if r.target_uid == int(v.get("uid")) and r.popup_style == GameConst.PopupStyle.REACTION \
				and r.element == GameConst.ReactionType.RXN_WAT_FIR \
				and _approx(r.final_value, 60.0):
			main_ok = true
		if r.target_uid == int(near.get("uid")):
			near_hit = true
		if r.target_uid == int(far.get("uid")):
			far_hit = true
	# b) 清双槽 + CD 3.0
	var st: ElementalState = v.get("elemental")
	var clear_ok: bool = st != null and _approx(st.gauges[GameConst.Element.WAT], 0.0) \
		and _approx(st.gauges[GameConst.Element.FIR], 0.0) \
		and _approx(float(st.reaction_cd.get(GameConst.ReactionType.RXN_WAT_FIR, -1.0)), 3.0)
	_check("V47：汽爆——主 60×φ + 半径 80 扩散（79 距吃/95 距不吃）+ WAT/FIR 双槽清 + CD 3s",
		main_ok and near_hit and not far_hit and clear_ok,
		"main=%s near=%s far=%s clear=%s" % [str(main_ok), str(near_hit), str(far_hit),
			str(clear_ok)])
	# c) 过载恒等重放：同几何 FIR+LTG → 扩散结算 element 承载 RXN_FIR_LTG（第 5 参缺省恒等）
	_purge_enemies()
	var ov := _spawn_enemy(_make_enemy_data("V47_OV", 4000.0), Vector2(100, 400))
	_sys.register_host(ov)
	var ov_near := _spawn_enemy(_make_enemy_data("V47_ON", 4000.0), Vector2(179, 400))
	_sys.register_host(ov_near)
	_gauge(ov, GameConst.Element.FIR, 30.0)
	_gauge(ov, GameConst.Element.LTG, 30.0)
	_detect()
	var ov_spread_el := -1
	for r in _captured:
		if r.target_uid == int(ov_near.get("uid")) \
				and r.popup_style == GameConst.PopupStyle.REACTION:
			ov_spread_el = r.element
	_check("V47：过载恒等重放——扩散结算 element 承载 RXN_FIR_LTG（_spread_reaction 缺省参零漂移）",
		ov_spread_el == GameConst.ReactionType.RXN_FIR_LTG, "el=%d" % ov_spread_el)

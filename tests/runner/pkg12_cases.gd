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
	_test_v48_quench()                            # V48
	_test_v49_amp_upgrade()                       # V49
	_test_v50_shield_data()                       # V50
	_test_v51_shield_runtime()                    # V51
	_test_v52_shield_ring()                       # V52
	_test_v53_presentation()                      # V53
	_test_v54_pipeline_veto()                     # V54
	_test_v55_dual_baseline()                     # V55
	_test_v56_closure()                           # V56
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
	var hud := HUD.new()                          # v1.2.0 W8：六槽 HUD 订阅（counts[3] 冻结槽）
	hud.name = "Pkg12V45Hud"
	tree.get_root().add_child(hud)
	hud.bind_events()                             # HUD 订阅由 GameLoop 调 bind_events（测试侧补齐）
	_sys.tick(DT)                                 # 帧末破碎结算 0.4×100×1.0 = 40
	var settle_ok := false
	for r in _captured:
		if r.element == GameConst.ReactionType.RXN_WAT_ICE \
				and r.popup_style == GameConst.PopupStyle.REACTION \
				and _approx(r.final_value, 40.0):
			settle_ok = true
	var v45_stats: Dictionary = hud.reaction_stats()
	var v45_counts: Array = v45_stats.get("counts", [])
	var hud45_ok: bool = v45_counts.size() == 6 and int(v45_counts[3]) == 1
	hud.free()
	_check("V45：破碎——3 NORMAL 直击解冻 + 帧末结算 40（0.4×snapshot×φ）落血 + HUD counts[3]=1",
		hits_ok and settle_ok and hud45_ok and _approx(e1.hp, hp0 - 340.0, 0.01),
		"hits=%s settle=%s hud=%s hp=%s" % [str(hits_ok), str(settle_ok), str(hud45_ok),
			str(e1.hp)])
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


# ── V48 淬火 ──────────────────────────────────────────────────────
func _test_v48_quench() -> void:
	print("── V48 淬火 ──")
	_purge_enemies()
	# a) WAT 附着 + FIR 直击 → 淬火 contrib 0.5；结算清 WAT（帧末无汽爆）
	var e1 := _spawn_enemy(_make_enemy_data("V48_A", 2000.0), Vector2(120, 200))
	_sys.register_host(e1)
	_gauge(e1, GameConst.Element.WAT, 30.0)
	var q0: int = DebugStats.get_counter(&"amplify_quench")
	_fire_at(_spawn_proj(GameConst.Element.FIR, e1.global_position))
	var r1 := _last_result()
	var st1: ElementalState = e1.get("elemental")
	var quench_ok: bool = r1 != null and st1 != null \
		and is_equal_approx(float(r1.pool_breakdown.get(&"amplify", -1.0)), 0.5) \
		and is_equal_approx(r1.final_value, 150.0) \
		and is_equal_approx(st1.gauges[GameConst.Element.WAT], 0.0) \
		and st1.gauges[GameConst.Element.FIR] > 0.0 \
		and DebugStats.get_counter(&"amplify_quench") == q0 + 1
	_bump()
	_sys.detect_reactions()
	var no_blast: bool = not _rxn_events.has(GameConst.ReactionType.RXN_WAT_FIR)
	_check("V48：淬火——WAT+FIR 直击 contrib 0.5 落血 150 + amplify_quench 分键 + 清 WAT 帧末无汽爆",
		quench_ok and no_blast,
		"quench=%s no_blast=%s brk=%s" % [str(quench_ok), str(no_blast),
			str(r1.pool_breakdown if r1 != null else {})])
	# b) ICE+WAT 双附着 + FIR 直击 → 融化优先（pkg11 恒等锚）：清 ICE 保 WAT
	var e2 := _spawn_enemy(_make_enemy_data("V48_B", 2000.0), Vector2(400, 200))
	_sys.register_host(e2)
	_gauge(e2, GameConst.Element.ICE, 30.0)
	_gauge(e2, GameConst.Element.WAT, 30.0)
	_fire_at(_spawn_proj(GameConst.Element.FIR, e2.global_position))
	var r2 := _last_result()
	var st2: ElementalState = e2.get("elemental")
	var melt_first: bool = r2 != null and st2 != null \
		and is_equal_approx(float(r2.pool_breakdown.get(&"amplify", -1.0)), 0.5) \
		and is_equal_approx(st2.gauges[GameConst.Element.ICE], 0.0) \
		and st2.gauges[GameConst.Element.WAT] > 0.0
	# c) ICE 直击 + WAT 附着 → 恒 1.0（蒸发只吃 FIR）
	var e3 := _spawn_enemy(_make_enemy_data("V48_C", 2000.0), Vector2(680, 200))
	_sys.register_host(e3)
	_gauge(e3, GameConst.Element.WAT, 30.0)
	_fire_at(_spawn_proj(GameConst.Element.ICE, e3.global_position))
	var r3 := _last_result()
	var ice_wat_ok: bool = r3 != null \
		and not r3.pool_breakdown.has(&"amplify") \
		and is_equal_approx(r3.final_value, 100.0)
	_check("V48：优先级——ICE+WAT 双附着 FIR 直击走 MELT（清 ICE 保 WAT）/ ICE 直击 + WAT 恒 1.0",
		melt_first and ice_wat_ok,
		"melt=%s ice_wat=%s" % [str(melt_first), str(ice_wat_ok)])


# ── V49 增幅升格 ──────────────────────────────────────────────────
func _test_v49_amp_upgrade() -> void:
	print("── V49 升格 ──")
	# a) 三因子 schema 默认 + GameConfig.balance 加载值镜像（.tres 同值）
	var schema := BalanceTables.new()
	var mirror_ok: bool = is_equal_approx(schema.amp_melt_factor, 1.5) \
		and is_equal_approx(schema.amp_vapor_factor, 2.0) \
		and is_equal_approx(schema.amp_quench_factor, 1.5) \
		and GameConfig.balance != null \
		and is_equal_approx(GameConfig.balance.amp_melt_factor, 1.5) \
		and is_equal_approx(GameConfig.balance.amp_vapor_factor, 2.0) \
		and is_equal_approx(GameConfig.balance.amp_quench_factor, 1.5)
	# b) melt/vapor 恒等（pkg11 数值不漂）：FIR 直击 ICE 附着 150 / ICE 直击 FIR 附着 200
	var e1 := _spawn_enemy(_make_enemy_data("V49_A", 2000.0), Vector2(120, 400))
	_sys.register_host(e1)
	_gauge(e1, GameConst.Element.ICE, 30.0)
	_fire_at(_spawn_proj(GameConst.Element.FIR, e1.global_position))
	var r1 := _last_result()
	var melt_ok: bool = r1 != null and is_equal_approx(r1.final_value, 150.0) \
		and is_equal_approx(float(r1.pool_breakdown.get(&"amplify", -1.0)), 0.5)
	var e2 := _spawn_enemy(_make_enemy_data("V49_B", 2000.0), Vector2(400, 400))
	_sys.register_host(e2)
	_gauge(e2, GameConst.Element.FIR, 30.0)
	_fire_at(_spawn_proj(GameConst.Element.ICE, e2.global_position))
	var r2 := _last_result()
	var vapor_ok: bool = r2 != null and is_equal_approx(r2.final_value, 200.0) \
		and is_equal_approx(float(r2.pool_breakdown.get(&"amplify", -1.0)), 1.0)
	# c) _amp_factor 缺键回退 fallback（null → v1.1.0 常量值通道）
	var fallback_ok: bool = is_equal_approx(_sys._amp_factor("amp_melt_factor", 1.5), 1.5) \
		and is_equal_approx(_sys._amp_factor("amp_no_such_key", 1.7), 1.7)
	_check("V49：增幅升格——三因子 schema/.tres 镜像 + melt/vapor 恒等（150/200）+ _amp_factor 缺键回退",
		mirror_ok and melt_ok and vapor_ok and fallback_ok,
		"mirror=%s melt=%s vapor=%s fb=%s" % [str(mirror_ok), str(melt_ok), str(vapor_ok),
			str(fallback_ok)])


# ── V50 盾数据 ────────────────────────────────────────────────────
func _test_v50_shield_data() -> void:
	print("── V50 盾数据 ──")
	# a) validator 三拒绝（element 缺键 / element 越界 / ratio 缺键与越界 → error 级）
	var v := DataValidator.new()
	var d1 := _make_enemy_data("V50_A")
	d1.shield = {"capacity_ratio": 0.3}           # 缺 element
	var d2 := _make_enemy_data("V50_B")
	d2.shield = {"element": 5, "capacity_ratio": 0.3}   # element 越界
	var d3 := _make_enemy_data("V50_C")
	d3.shield = {"element": 4, "capacity_ratio": 1.5}   # ratio 越界（缺键同拒绝）
	var rej := 0
	for d in [d1, d2, d3]:
		for issue in v.validate_enemy(d):
			var row: Dictionary = issue
			if String(row.get("severity", "")) == DataValidator.SEV_ERROR \
					and String(row.get("field", "")).begins_with("shield."):
				rej += 1
	var reject_ok := rej >= 3
	# b) 合法盾通过（空 = 无盾也通过）
	var d4 := _make_enemy_data("V50_D")
	d4.shield = {"element": 2, "capacity_ratio": 0.25}
	var clean := true
	for issue in v.validate_enemy(d4):
		var row4: Dictionary = issue
		if String(row4.get("severity", "")) == DataValidator.SEV_ERROR:
			clean = false
	# c) 三 .tres 赋盾值（A11 §1 冻结）
	var e5: EnemyData = load("res://resources/enemies/E5_elite.tres")
	var b2: EnemyData = load("res://resources/enemies/E6_boss2.tres")
	var b3: EnemyData = load("res://resources/enemies/E6_boss3.tres")
	var tres_ok: bool = e5 != null and b2 != null and b3 != null \
		and int(e5.shield.get("element", -1)) == 2 \
		and is_equal_approx(float(e5.shield.get("capacity_ratio", 0.0)), 0.25) \
		and int(b2.shield.get("element", -1)) == 3 \
		and is_equal_approx(float(b2.shield.get("capacity_ratio", 0.0)), 0.3) \
		and int(b3.shield.get("element", -1)) == 4 \
		and is_equal_approx(float(b3.shield.get("capacity_ratio", 0.0)), 0.3)
	_check("V50：盾数据——validator 三拒绝（element 缺/越界 + ratio 越）+ 合法盾通过 + 三 .tres 值",
		reject_ok and clean and tres_ok,
		"rej=%d clean=%s tres=%s" % [rej, str(clean), str(tres_ok)])


# ── V51 盾运行期 ──────────────────────────────────────────────────
func _test_v51_shield_runtime() -> void:
	print("── V51 盾运行期 ──")
	_purge_enemies()
	# a) capacity 换算（E5_elite w1：max_hp 72 → 盾 18）+ 环激活
	var e := _spawn_enemy(_make_enemy_data("V51_A", 1000.0), Vector2(120, 200))
	e.data.shield = {"element": 2, "capacity_ratio": 0.25}   # 复用池实例补赋盾口径
	e.shield_element = 2
	e.shield_max = e.max_hp * 0.25
	e.shield_hp = e.shield_max
	e._shield_ring.setup(2, e.hitbox_r + 11.0)
	e._shield_ring.visible = true
	e._shield_ring.set_progress(1.0)
	var cap_ok: bool = e.shield_active() and is_equal_approx(e.shield_max, e.max_hp * 0.25) \
		and is_equal_approx(e.shield_progress(), 1.0) and e._shield_ring.visible
	# b) 吸收：hp 不减 + 盾扣（KIN ×1）
	var hp0: float = e.hp
	var fake := DamageResult.new()
	fake.final_value = 10.0
	fake.popup_style = GameConst.PopupStyle.NORMAL
	fake.element = GameConst.Element.KIN
	fake.panel_snapshot = 100.0
	e.take_result(fake)
	var absorb_ok: bool = is_equal_approx(e.hp, hp0) \
		and is_equal_approx(e.shield_hp, e.shield_max - 10.0) and not e.dead
	# c) 克制：ICE 盾（element 2）吃 FIR（counter=1）×2
	e.shield_hp = 30.0
	fake.element = GameConst.Element.FIR
	e.take_result(fake)
	var counter_ok: bool = is_equal_approx(e.shield_hp, 10.0)
	# d) REACTION 结算不误判：WAT 盾（element 4）吃 RXN_WAT_LTG=4 通道 → 不吃 ×2
	var w := _spawn_enemy(_make_enemy_data("V51_W", 1000.0), Vector2(400, 200))
	w.shield_element = 4
	w.shield_max = 100.0
	w.shield_hp = 100.0
	var fake_rxn := DamageResult.new()
	fake_rxn.final_value = 10.0
	fake_rxn.popup_style = GameConst.PopupStyle.REACTION
	fake_rxn.element = GameConst.ReactionType.RXN_WAT_LTG   # 值 4 = WAT 盾的克制位撞值
	w.take_result(fake_rxn)
	var rxn_ok: bool = is_equal_approx(w.shield_hp, 90.0)   # ×1（非 ×2）
	# e) 破盾无溢出 + 破后不可再生 + killed 恒 false
	w.shield_hp = 5.0
	var w_hp0: float = w.hp
	fake_rxn.popup_style = GameConst.PopupStyle.NORMAL
	fake_rxn.element = GameConst.Element.KIN
	fake_rxn.final_value = 100.0
	w.take_result(fake_rxn)
	var break_ok: bool = is_equal_approx(w.shield_hp, 0.0) and is_equal_approx(w.hp, w_hp0) \
		and not w.shield_active() and not w.dead
	fake_rxn.final_value = 7.0
	w.take_result(fake_rxn)
	var no_regen: bool = is_equal_approx(w.hp, w_hp0 - 7.0) and is_equal_approx(w.shield_hp, 0.0)
	# f) 盾期增幅照乘 + 附着照常
	var s := _spawn_enemy(_make_enemy_data("V51_S", 2000.0), Vector2(120, 400))
	_sys.register_host(s)
	s.shield_element = 0
	s.shield_max = 50.0
	s.shield_hp = 50.0
	_gauge(s, GameConst.Element.ICE, 30.0)
	_fire_at(_spawn_proj(GameConst.Element.FIR, s.global_position))
	var r := _last_result()
	var st: ElementalState = s.get("elemental")
	var amp_ok: bool = r != null and st != null \
		and r.pool_breakdown.has(&"amplify") \
		and st.gauges[GameConst.Element.FIR] > 0.0
	# g) summon 剥盾（strip_shield 方法 + spawner 接线源码核对）
	var sp_src := _read_source("res://scripts/entities/wave/enemy_spawner.gd")
	s.strip_shield()
	var strip_ok: bool = s.shield_element == -1 and is_equal_approx(s.shield_hp, 0.0) \
		and not s._shield_ring.visible \
		and (not sp_src.is_empty()) and sp_src.contains("strip_shield()")
	_check("V51：盾运行期——capacity 换算/吸收 hp 不减/ICE 盾 FIR×2 KIN×1/REACTION 不误判（RXN_WAT_LTG=4 打 WAT 盾 ×1）/破盾无溢出+不可再生+killed false/盾期增幅照乘附着照常/summon strip",
		cap_ok and absorb_ok and counter_ok and rxn_ok and break_ok and no_regen
		and amp_ok and strip_ok,
		"cap=%s abs=%s ctr=%s rxn=%s brk=%s regen=%s amp=%s strip=%s"
			% [str(cap_ok), str(absorb_ok), str(counter_ok), str(rxn_ok), str(break_ok),
			str(no_regen), str(amp_ok), str(strip_ok)])


# ── V52 盾环 ──────────────────────────────────────────────────────
func _test_v52_shield_ring() -> void:
	print("── V52 盾环 ──")
	# a) progress：set_progress 钳制 0~1 + 观测口
	var ring := Enemy.ShieldRing.new()
	ring.setup(4, 25.0)                           # WAT 盾（A11 §1 色）
	ring.set_progress(0.5)
	var prog_ok: bool = is_equal_approx(ring.progress(), 0.5)
	ring.set_progress(1.5)
	prog_ok = prog_ok and is_equal_approx(ring.progress(), 1.0)
	ring.set_progress(-0.1)
	prog_ok = prog_ok and is_equal_approx(ring.progress(), 0.0)
	# b) 破盾 flash → tick 余韵后隐藏（progress 0 + flash 尽）
	ring.visible = true
	ring.set_progress(0.0)
	ring.flash()
	var flash_on: bool = ring.visible
	ring.tick(Enemy.ShieldRing.FLASH_TIME)
	var hide_ok: bool = flash_on and not ring.visible
	# c) flash 期不隐藏（盾非空 flash = 受击白闪语义独立于破盾）
	ring.visible = true
	ring.set_progress(1.0)
	ring.flash()
	ring.tick(Enemy.ShieldRing.FLASH_TIME)
	var flash_keep: bool = ring.visible           # progress 1 → 不隐藏
	# d) 池复用二次赋盾：spawn 带盾 → 破盾 → _reset_state 归还 → 再 spawn 带盾 → 环复活
	_purge_enemies()
	var sd := _make_enemy_data("V52_E", 1000.0)
	sd.shield = {"element": 4, "capacity_ratio": 0.3}
	var e1 := _spawn_enemy(sd, Vector2(120, 600))
	var first_ok: bool = e1._shield_ring.visible and is_equal_approx(e1.shield_progress(), 1.0)
	var fake := DamageResult.new()
	fake.final_value = 100000.0                   # 一击破盾（300 盾 << 100000）
	fake.popup_style = GameConst.PopupStyle.NORMAL
	fake.element = GameConst.Element.KIN
	e1.take_result(fake)
	_enemy_pool.release(e1)
	_alive_enemies.erase(e1)
	var e2 := _enemy_pool.acquire() as Enemy
	e2.spawn(sd, 1, 0)
	e2.position = Vector2(120, 700)
	_alive_enemies.append(e2)
	_grid.rebuild(_alive_enemies)
	var reuse_ok: bool = e2 == e1 and e2._shield_ring.visible \
		and is_equal_approx(e2.shield_progress(), 1.0) \
		and is_equal_approx(e2.shield_hp, 300.0)
	ring.free()
	_check("V52：盾环——progress 钳制观测 / 破盾 flash 余韵后隐藏（盾非空 flash 不隐藏）/ 池复用二次赋盾复活（A11 §9 H8 半径 hitbox+11）",
		prog_ok and hide_ok and flash_keep and first_ok and reuse_ok,
		"prog=%s hide=%s keep=%s first=%s reuse=%s" % [str(prog_ok), str(hide_ok),
			str(flash_keep), str(first_ok), str(reuse_ok)])


# ── V53 表现面 ────────────────────────────────────────────────────
func _test_v53_presentation() -> void:
	print("── V53 表现面 ──")
	# a) 六键全遍历（防漏键静默回退）：scene_id 映射 + 预设 + feel 档字面（A11 §6 冻结表）
	var expect_scenes := {
		GameConst.ReactionType.RXN_FIR_ICE: "burst_rxn_shatter",
		GameConst.ReactionType.RXN_FIR_LTG: "burst_rxn_overload",
		GameConst.ReactionType.RXN_ICE_LTG: "burst_rxn_superconduct",
		GameConst.ReactionType.RXN_WAT_ICE: "burst_rxn_freeze",
		GameConst.ReactionType.RXN_WAT_LTG: "burst_rxn_conduct",
		GameConst.ReactionType.RXN_WAT_FIR: "burst_rxn_vaporblast",
	}
	var expect_feel := {
		GameConst.ReactionType.RXN_FIR_ICE: [1.0, 1.0, 1.0],
		GameConst.ReactionType.RXN_FIR_LTG: [0.8, 0.85, 0.8],
		GameConst.ReactionType.RXN_ICE_LTG: [0.6, 0.7, 0.6],
		GameConst.ReactionType.RXN_WAT_ICE: [0.9, 0.9, 0.9],
		GameConst.ReactionType.RXN_WAT_LTG: [0.7, 0.75, 0.7],
		GameConst.ReactionType.RXN_WAT_FIR: [0.75, 0.8, 0.75],
	}
	var all_ok := true
	var detail := ""
	for rxn in expect_scenes:
		var scene_id := String(ParticleDirector.REACTION_SCENE_IDS.get(rxn, ""))
		var feel: Dictionary = GameFeelDirector.RXN_FEEL_SCALE.get(rxn, {})
		var want: Array = expect_feel[rxn]
		if scene_id != String(expect_scenes[rxn]) \
				or not ParticleDirector.REACTION_PRESETS.has(StringName(scene_id)) \
				or feel.is_empty() \
				or not is_equal_approx(float(feel.get("stop", -1.0)), float(want[0])) \
				or not is_equal_approx(float(feel.get("trauma", -1.0)), float(want[1])) \
				or not is_equal_approx(float(feel.get("ca", -1.0)), float(want[2])):
			all_ok = false
			detail += "rxn=%d scene=%s feel=%s | " % [int(rxn), scene_id, str(feel)]
	# b) HUD 六槽 clamp(0,5)：element 9 → 槽 5；element -2 → 槽 0
	var hud := HUD.new()
	hud.name = "Pkg12V53Hud"
	tree.get_root().add_child(hud)
	hud.reset_reactions()
	var r_hi := DamageResult.new()
	r_hi.final_value = 1.0
	r_hi.popup_style = GameConst.PopupStyle.REACTION
	r_hi.element = 9
	hud._on_damage_resolved(r_hi)
	var r_lo := DamageResult.new()
	r_lo.final_value = 1.0
	r_lo.popup_style = GameConst.PopupStyle.REACTION
	r_lo.element = -2
	hud._on_damage_resolved(r_lo)
	var hud_ok: bool = hud.reaction_counts.size() == 6 and int(hud.reaction_counts[5]) == 1 \
		and int(hud.reaction_counts[0]) == 1
	hud.free()
	# c) 结算行六名（碎裂/过载/超导/冻结/导电/汽爆）
	var screen := GameOverScreen.new()
	screen.name = "Pkg12V53Screen"
	tree.get_root().add_child(screen)
	var src := GDScript.new()
	src.source_code = "extends Node2D\nvar kills: int = 3\nvar wave: int = 2\n" \
		+ "var total_damage: float = 200.0\nvar reaction_counts: Array = [2, 0, 0, 1, 0, 0]\n" \
		+ "var reaction_damage: Array = [150.0, 0.0, 0.0, 50.0, 0.0, 0.0]\n"
	src.reload()
	var stub: Node2D = src.new()
	tree.get_root().add_child(stub)
	screen.stats_source = stub
	screen.show_summary()
	var text := screen.reaction_text()
	var text_ok: bool = text.contains("碎裂 2/150(75%)") and text.contains("冻结 1/50(25%)") \
		and text.contains("汽爆 0/0(0%)") and text.contains("导电 0/0(0%)")
	screen.free()
	stub.free()
	_check("V53：表现面——六键 scene_id/预设/feel 档全遍历防漏键回退 + HUD 六槽 clamp(0,5) + 结算行六名",
		all_ok and hud_ok and text_ok,
		"keys=%s hud=%s text=%s | %s" % [str(all_ok), str(hud_ok), str(text_ok), text])


# ── V54 管线 veto ─────────────────────────────────────────────────
func _test_v54_pipeline_veto() -> void:
	print("── V54 管线 veto ──")
	var src := _read_source("res://scripts/core/damage/damage_pipeline.gd")
	var lower := src.to_lower()
	_check("V54：damage_pipeline.gd 零改动守卫——源码小写不含 shield 字样（v1.2.0 一笔不碰）",
		(not lower.is_empty()) and not lower.contains("shield"))


# ── V55 双基线 ────────────────────────────────────────────────────
# 含 TIDE 卡池固定 seed 新基线快照（ELE_TIDE 入 ELEM 池后 seed 20260901 ×5 批 15 张实测序列）
const POOL_BASELINE := "AFF_MOVE_SWIFT,AFF_CRIT_DMG,MEC_KILL_BLAST,SYN_LOWHP_FURY,SYN_BURN_DEVOUR,AFF_MOVE_SWIFT,SYN_BOUNCE_SPEC,AFF_AREA,AFF_PROJ_SPD,AFF_CRIT_DMG,SYN_BURN_DEVOUR,AFF_MULTI,AFF_CRIT_RATE,AFF_CRIT_DMG,MEC_SHIELD"


func _test_v55_dual_baseline() -> void:
	print("── V55 双基线 ──")
	# a) 无 TIDE 恒等锚（pkg11 数值不漂）：KIN 直击 = 100；无 TIDE 无 WAT 附着
	var e := _spawn_enemy(_make_enemy_data("V55_A", 2000.0), Vector2(120, 900))
	_sys.register_host(e)
	_fire_at(_spawn_proj(GameConst.Element.KIN, e.global_position))
	var r := _last_result()
	var st: ElementalState = e.get("elemental")
	var base_ok: bool = r != null and st != null \
		and is_equal_approx(r.final_value, 100.0) \
		and is_equal_approx(st.gauges[GameConst.Element.WAT], 0.0)
	# b) 含 TIDE 卡池固定 seed 新基线快照（ELE_TIDE 入 ELEM 池 → 序列变化，落常量锚定）
	var reg := DataRegistry.new()
	reg.load_all("res://data/manifest.cfg")
	var gen := CardGenerator.new()                # RefCounted：不入树不 free
	gen.setup(reg)
	gen.rng.seed = 20260901
	var src_stub := GDScript.new()
	src_stub.source_code = "extends Node2D\nvar weapon_slots: Array = []\n" \
		+ "var unlocked_slots: int = 0\n"
	src_stub.reload()
	var player_stub: Node2D = src_stub.new()
	tree.get_root().add_child(player_stub)
	var seq: Array[String] = []
	for _batch in range(5):
		for card in gen.generate_candidates({"player": player_stub, "wave": 3}):
			seq.append(String(card.get("id", &"FALLBACK")))
	var sequence := ",".join(seq)
	if POOL_BASELINE == "":
		print("V55_PROBE baseline=", sequence)    # 首跑探测：将实测序列落 POOL_BASELINE 常量
	var pool_ok: bool = reg.traits.has(&"ELE_TIDE") \
		and reg.trait_ids_by_pool(GameConst.PoolClass.ELEM).has(&"ELE_TIDE") \
		and sequence == POOL_BASELINE
	player_stub.free()
	_check("V55：双基线——无 TIDE 恒等（KIN 100 / WAT 槽 0）+ 含 TIDE 卡池 seed 20260901 新基线快照锁定",
		base_ok and pool_ok,
		"base=%s pool=%s seq=%s" % [str(base_ok), str(pool_ok), sequence])


# ── V56 收尾 ──────────────────────────────────────────────────────
func _test_v56_closure() -> void:
	print("── V56 收尾 ──")
	var version: String = ProjectSettings.get_setting("application/config/version", "")
	var version_ok := version == "1.2.0"
	var progress := _read_source("res://PROGRESS.md")
	var progress_ok := (not progress.is_empty()) and progress.contains("1463") \
		and progress.contains("pkg12 19") and progress.contains("v1.2.0 增量")
	var a11 := _read_source("res://docs/analysis/A11_v1.2.0_design.md")
	var a11_ok := (not a11.is_empty()) and a11.contains("H8") \
		and a11.contains("RXN_WAT_ICE") and a11.contains("SHIELD_COUNTER")
	_check("V56：收尾——version=1.2.0 + PROGRESS 对账（1463/pkg12 19/v1.2.0 增量）+ A11 留痕含假设清单与克环",
		version_ok and progress_ok and a11_ok,
		"version=%s progress=%s a11=%s" % [version, str(progress_ok), str(a11_ok)])

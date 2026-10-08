# tests/qa_r228_qa_valvecheck_cases.gd
# QA-R228/R229 独立复核用例体（入口 qa_r228_qa_valvecheck.gd 运行时 load）。
# 与 test_r229_* 套件互为独立口径：本探针另起窗长（16 而非 8）、另起驱动序、
# 另覆盖套件未测面（ObjectPool.trim_free_to live>target 分支、门开 CRIT 与
# 中档共享隔次的 elif 互斥、强制开门不外溢非 CRIT）。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const N := 16                                   # QA 长窗（1/4→4、1/2→8 确定窗）
const VALVE_CAP := 448                          # game_loop.PROJ_POOL_VALVE_CAP 同值

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null


class TagNode extends Node2D:
	# on_enemy_killed 最小桩（不入树——不触发 spawner 归还/XP 旁路订阅）
	var tags: int = 0


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(20261004)
	_boot()
	await tree.process_frame
	await tree.process_frame
	PerfGovernor.set_process(false)              # tier 真值不被采样漂移（r223 先例）
	Meta.set_setting("fx_quality", 2)
	_gl.state = GameConst.GameStatus.MENU
	_part_a_burst_valve()
	_part_c_fx_quantize_spot()
	await _free_gl()
	await _part_b_pool_unit()
	await _part_b_gl_gate_order()
	_reset_all()
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


func _boot() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "QaR228GL"
	tree.get_root().add_child(_gl)


func _free_gl() -> void:
	tree.paused = false
	RunSave.clear()
	if _gl != null:
		_gl.free()
		_gl = null
	await tree.process_frame


# ── A. 粒子满载门（刀1）独立复核 ───────────────────────────────────

func _gf() -> GameFeelDirector:
	return _gl.game_feel


func _bursts() -> int:
	return _gl.game_feel.particles.burst_requests


func _thinned() -> int:
	return DebugStats.get_counter(&"burst_thinned")


func _mk_result(p_crit: bool, p_seq: int) -> DamageResult:
	var r := DamageResult.new()
	r.final_value = 3.0
	r.is_crit = p_crit
	r.feel_level = GameConst.FeelLevel.CRIT if p_crit else GameConst.FeelLevel.HIT
	r.target_uid = 2280000 + p_seq
	r.pos = Vector2(300.0, 600.0)
	r.popup_style = GameConst.PopupStyle.NORMAL
	return r


func _emit(p_crit: bool, p_n: int) -> int:
	var b0 := _bursts()
	for i in p_n:
		EventBus.damage_resolved.emit(_mk_result(p_crit, i))
	return _bursts() - b0


func _kills(p_tags: int, p_n: int) -> int:
	var b0 := _bursts()
	var stub := TagNode.new()
	stub.tags = p_tags
	stub.position = Vector2(300.0, 600.0)
	for i in p_n:
		_gf().on_enemy_killed(stub)
	stub.free()
	return _bursts() - b0


func _rxns(p_n: int) -> int:
	var b0 := _bursts()
	for i in p_n:
		_gf().on_reaction_triggered(GameConst.ReactionType.RXN_FIR_ICE,
			Vector2(300.0, 600.0), 2285000 + i)
	return _bursts() - b0


func _boss_kill() -> int:
	var b0 := _bursts()
	var stub := TagNode.new()
	stub.tags = GameConst.TAG_BOSS
	_gf().on_enemy_killed(stub)
	stub.free()
	return _bursts() - b0


func _reset_feel_overrides() -> void:
	GameFeelDirector.burst_thin_override = -1
	PerfGovernor.mode_override = -1
	PerfGovernor.tier_override = -1
	PerfGovernor.tier = 3


func _part_a_burst_valve() -> void:
	print("── A. 粒子满载门（刀1，isValve）独立复核 ──")
	# A1 哨兵四档 + 三重门逐项（直读 _burst_thin_on）
	_reset_feel_overrides()
	_check("A1 -1 真值：headless 非 mobile → 关",
		GameFeelDirector._burst_thin_on() == false, "")
	GameFeelDirector.burst_thin_override = -2
	_check("A1 -2 用户否决档 → 恒关", not GameFeelDirector._burst_thin_on(), "")
	GameFeelDirector.burst_thin_override = 1
	_check("A1 1 强制开 → 恒开", GameFeelDirector._burst_thin_on(), "")
	GameFeelDirector.burst_thin_override = -3
	PerfGovernor.mode_override = 0
	PerfGovernor.tier_override = 3
	_check("A1 -3 + tier3 → 关（tier≤2 门）", not GameFeelDirector._burst_thin_on(), "")
	PerfGovernor.tier_override = 2
	PerfGovernor.mode_override = 1
	_check("A1 -3 + 特效优先 → 关（帧率优先门）", not GameFeelDirector._burst_thin_on(), "")
	PerfGovernor.mode_override = 0
	_check("A1 -3 + tier2 + 帧率优先 → 开", GameFeelDirector._burst_thin_on(), "")
	GameFeelDirector.burst_thin_override = -1
	_check("A1 -1 + tier2 + 帧率优先 → 仍关（OS 门密封=桌面零扰动前提）",
		not GameFeelDirector._burst_thin_on(), "")
	_reset_feel_overrides()
	# A2 16 长窗采样相位（QA 独立窗长——1/4→4、1/2→8 非 8 窗巧合）
	GameFeelDirector.burst_thin_override = -3
	PerfGovernor.mode_override = 0
	PerfGovernor.tier_override = 2
	var t0 := _thinned()
	var c16 := _emit(true, N)
	_check("A2 门开 16 次 CRIT → +4（1/4 相位确定）", c16 == 4, "+%d" % c16)
	var k16 := _kills(0, N)
	_check("A2 门开 16 次普通敌击杀 → +4（1/4）", k16 == 4, "+%d" % k16)
	var e16 := _kills(GameConst.TAG_ELITE, N)
	_check("A2 门开 16 次精英击杀 → +8（1/2）", e16 == 8, "+%d" % e16)
	var r16 := _rxns(N)
	_check("A2 门开 16 次反应 → +8（1/2）", r16 == 8, "+%d" % r16)
	var boss1 := _boss_kill()
	_check("A2 Boss tag 击杀 → 1/1（全保留）", boss1 == 1, "+%d" % boss1)
	var thin_d := _thinned() - t0
	_check("A2 burst_thinned 判读口 ==40（12+12+8+8+0）", thin_d == 40, "+%d" % thin_d)
	_reset_feel_overrides()
	# A3 elif 独立计数器：门开 CRIT 不吃共享中档隔次；非 CRIT 隔次不受门影响
	Meta.set_setting("fx_quality", 1)
	GameFeelDirector.burst_thin_override = -3
	PerfGovernor.mode_override = 0
	PerfGovernor.tier_override = 2
	_gf().set("_thin_burst_tick", 0)
	_gf().set("_crit_thin_tick", 0)
	var crit_mid_open := _emit(true, 8)
	_check("A3 门开+中档：CRIT 8 → +2（独立 1/4，不吃共享隔次）",
		crit_mid_open == 2, "+%d" % crit_mid_open)
	_gf().set("_thin_burst_tick", 0)
	_gf().set("_crit_thin_tick", 0)
	var hit_mid_open := _emit(false, 8)
	_check("A3 门开+中档：非 CRIT 8 → +4（共享隔次仍生效于普命中）",
		hit_mid_open == 4, "+%d" % hit_mid_open)
	GameFeelDirector.burst_thin_override = -2
	_gf().set("_thin_burst_tick", 0)
	_gf().set("_crit_thin_tick", 0)
	var crit_mid_closed := _emit(true, 8)
	_check("A3 门关+中档：CRIT 8 → +4（旧隔次语义逐位保持）",
		crit_mid_closed == 4, "+%d" % crit_mid_closed)
	Meta.set_setting("fx_quality", 2)
	_reset_feel_overrides()
	# A4 桌面零扰动（无任何注入，真 EventBus 派发）
	Enemy.fullload_override = 0                 # R213 满载门隔离（非本刀面）
	var t1 := _thinned()
	var c8 := _emit(true, 8)
	var k8 := _kills(0, 8)
	var r8 := _rxns(8)
	var boss2 := _boss_kill()
	_check("A4 无注入桌面缺省：真派发 8/8/8/1（零扰动负向锚）",
		c8 == 8 and k8 == 8 and r8 == 8 and boss2 == 1,
		"%d/%d/%d/%d" % [c8, k8, r8, boss2])
	_check("A4 零削减计数（burst_thinned 不增）", _thinned() == t1,
		"+%d" % (_thinned() - t1))
	# A5 强制开门不外溢非 CRIT（R229 门只盖 CRIT/KILL/反应三路）
	GameFeelDirector.burst_thin_override = 1
	_gf().set("_crit_thin_tick", 0)
	var hit_hi := _emit(false, 8)
	_check("A5 强制开门+高档：非 CRIT 8 → +8（门不外溢普命中）", hit_hi == 8,
		"+%d" % hit_hi)
	var crit_hi := _emit(true, 8)
	_check("A5 强制开门+高档：CRIT 8 → +2（1/4 无条件生效）", crit_hi == 2,
		"+%d" % crit_hi)
	Enemy.fullload_override = -1
	_reset_feel_overrides()


# ── C. 特效层 alpha 量化（刀2，非阀门）抽查 ────────────────────────

func _part_c_fx_quantize_spot() -> void:
	print("── C. 特效层 alpha 量化（刀2，非阀门）抽查 ──")
	var qa_ok: bool = ElementalFxLayer._qa(0.0) == 0.0 \
		and ElementalFxLayer._qa(0.124) == 0.0 \
		and ElementalFxLayer._qa(0.126) == 0.25 \
		and ElementalFxLayer._qa(0.5) == 0.5 \
		and ElementalFxLayer._qa(0.87) == 0.75 \
		and ElementalFxLayer._qa(0.95) == 1.0 \
		and ElementalFxLayer._qa(0.9) == 1.0 \
		and ElementalFxLayer._qa(-0.2) == 0.0 \
		and ElementalFxLayer._qa(1.7) == 1.0
	_check("C1 _qa 契约直读（0.124→0 / 0.126→0.25 / 0.87→0.75 / 建槽底 0.95→1.0 / 钳制双向）",
		qa_ok, "")
	# C2 反应环族 6 件同相位 → 全员四分档 ∧ distinct ≤2（合批前提）
	var layer: ElementalFxLayer = _gl.elemental_fx
	for i in 6:
		EventBus.reaction_triggered.emit(GameConst.ReactionType.RXN_FIR_ICE,
			Vector2(200.0 + i * 20.0, 400.0), 2289000 + i)
	layer.tick(0.1)
	var alphas: Array[float] = []
	var grids: bool = true
	for slot: Dictionary in layer._rings:
		if float(slot["left"]) <= 0.0:
			continue
		var a: float = (slot["sprite"] as Sprite2D).modulate.a
		alphas.append(a)
		if not (a == 0.0 or a == 0.25 or a == 0.5 or a == 0.75 or a == 1.0):
			grids = false
	var distinct: int = 0
	var seen: Dictionary = {}
	for a in alphas:
		if not seen.has(a):
			seen[a] = true
			distinct += 1
	_check("C2 反应环族 live≥3 件全员 ∈ 四分档（量化写点在环族生效）",
		alphas.size() >= 3 and grids, "n=%d grids=%s" % [alphas.size(), str(grids)])
	_check("C2 同相位 distinct alpha ≤2（合批前提——R216/R217 断批定律反用）",
		distinct <= 2, "distinct=%d" % distinct)


# ── B. 弹池静载阀门（刀3）独立复核 ─────────────────────────────────

func _part_b_pool_unit() -> void:
	print("── B1 ObjectPool.trim_free_to 单元级 live-clamp 边界（套件未覆盖面） ──")
	var pn := Node.new()
	var ps := PackedScene.new()
	var pack_err: int = ps.pack(pn)
	pn.free()
	_check("B1 前置：PackedScene.pack 成品", pack_err == OK, "err=%d" % pack_err)
	var pool := ObjectPool.new()
	pool.name = "QaR228UnitPool"
	pool.setup(&"qa_r228_qa", ps, 10)
	tree.get_root().add_child(pool)
	pool.prewarm(10)
	var st0: Dictionary = pool.stats()
	_check("B1 预热后 cap==10 / free==10 / live==0",
		int(st0["capacity"]) == 10 and int(st0["free"]) == 10 and int(st0["live"]) == 0,
		str(st0))
	var held: Array[Node] = []
	for i in 6:
		held.append(pool.acquire())
	var st1: Dictionary = pool.stats()
	_check("B1 取 6 后 live==6 / free==4",
		int(st1["live"]) == 6 and int(st1["free"]) == 4,
		"live=%d free=%d" % [int(st1["live"]), int(st1["free"])])
	var trimmed: int = pool.trim_free_to(5)
	var st2: Dictionary = pool.stats()
	_check("B1 live=6 裁标 5 → 容量=maxi(5,6)==6 + 裁 4（live-clamp 分支）",
		trimmed == 4 and int(st2["capacity"]) == 6,
		"trimmed=%d cap=%d" % [trimmed, int(st2["capacity"])])
	_check("B1 裁后 free==0 / live==6（空闲全裁、活口不动）",
		int(st2["free"]) == 0 and int(st2["live"]) == 6,
		"free=%d live=%d" % [int(st2["free"]), int(st2["live"])])
	var miss_node: Node = pool.acquire()
	var st3: Dictionary = pool.stats()
	_check("B1 满帽 acquire → null+miss1（懒增长条件不可达——不实例化）",
		miss_node == null and int(st3["misses"]) == 1,
		"null=%s misses=%d" % [str(miss_node == null), int(st3["misses"])])
	_check("B1 裁后 runtime_inst==0（懒增长口封死）",
		int(st3["runtime_instantiates"]) == 0, "")
	pool.release(held[0])
	held.remove_at(0)
	var again: Node = pool.acquire()
	_check("B1 归还后再取 → 复用非空且零实例化",
		again != null and pool.runtime_instantiate_count == 0, "")
	var trimmed2: int = pool.trim_free_to(5)
	_check("B1 再裁 → 0 增量（free 已尽）/ 容量不动",
		trimmed2 == 0 and int(pool.stats()["capacity"]) == 6, "t2=%d" % trimmed2)
	for p in held:
		pool.release(p)
	pool.release(again)
	var st_end: Dictionary = pool.stats()
	_check("B1 全归还 free==6 / live==0 / ri 仍 0 / 拒还 0",
		int(st_end["free"]) == 6 and int(st_end["live"]) == 0
			and int(st_end["runtime_instantiates"]) == 0
			and int(st_end["rejected_releases"]) == 0, str(st_end))
	await tree.process_frame
	await tree.process_frame
	pool.free()


func _part_b_gl_gate_order() -> void:
	print("── B2 GameLoop 三重门序逐项 + 桌面零扰动 + 触发读数（新鲜 boot） ──")
	_boot()
	await tree.process_frame
	await tree.process_frame
	PerfGovernor.set_process(false)
	var pool: ProjectilePool = _gl.pools[&"projectile"] as ProjectilePool
	var cap0: int = int(pool.stats()["capacity"])
	_check("B2 新鲜 boot cap==820（静态 override 不跨进程）", cap0 == 820,
		"cap=%d" % cap0)
	# 哨兵直读（-1/-2/-3 × tier/mode 组合）
	GameLoop.pool_valve_override = -2
	PerfGovernor.tier_override = 2
	PerfGovernor.mode_override = 0
	_check("B2 _pool_valve_on()：-2 → false", not _gl._pool_valve_on(), "")
	GameLoop.pool_valve_override = -1
	_check("B2 _pool_valve_on()：-1 + tier2 + 帧率优先 → false（OS 门）",
		not _gl._pool_valve_on(), "")
	GameLoop.pool_valve_override = -3
	_check("B2 _pool_valve_on()：-3 + tier2 + 帧率优先 → true", _gl._pool_valve_on(), "")
	PerfGovernor.tier_override = 3
	_check("B2 _pool_valve_on()：-3 + tier3 → false（tier≤2 门）",
		not _gl._pool_valve_on(), "")
	PerfGovernor.tier_override = 2
	PerfGovernor.mode_override = 1
	_check("B2 _pool_valve_on()：-3 + 特效优先 → false（帧率优先门）",
		not _gl._pool_valve_on(), "")
	PerfGovernor.mode_override = 0
	# 行为逐项：门关组合驱帧必须不动（桌面零扰动 + 门序）
	GameLoop.pool_valve_override = -1
	for i in 3:
		_gl._physics_process(1.0 / 60.0)
	var st_a: Dictionary = pool.stats()
	_check("B2 真值门（-1）headless 三帧不裁（桌面零扰动）",
		int(st_a["capacity"]) == 820 and int(st_a["free"]) == 820,
		"cap=%d free=%d" % [int(st_a["capacity"]), int(st_a["free"])])
	GameLoop.pool_valve_override = -2
	_gl._physics_process(1.0 / 60.0)
	_check("B2 -2 强制关一帧不裁", int(pool.stats()["capacity"]) == 820, "")
	GameLoop.pool_valve_override = -3
	PerfGovernor.tier_override = 3
	_gl._physics_process(1.0 / 60.0)
	_check("B2 -3 + tier3 一帧不裁", int(pool.stats()["capacity"]) == 820, "")
	PerfGovernor.tier_override = 2
	PerfGovernor.mode_override = 1
	_gl._physics_process(1.0 / 60.0)
	_check("B2 -3 + 特效优先一帧不裁", int(pool.stats()["capacity"]) == 820, "")
	PerfGovernor.mode_override = 0
	var c0: int = DebugStats.get_counter(&"proj_pool_trim")
	_gl._physics_process(1.0 / 60.0)
	var st_z: Dictionary = pool.stats()
	_check("B2 -3 + tier2 + 帧率优先 触发：cap 820→448 ∧ free+live==448 ∧ 裁372",
		int(st_z["capacity"]) == VALVE_CAP
			and int(st_z["free"]) + int(st_z["live"]) == VALVE_CAP
			and DebugStats.get_counter(&"proj_pool_trim") - c0 == 820 - VALVE_CAP,
		"cap=%d free=%d live=%d trimΔ=%d" % [int(st_z["capacity"]), int(st_z["free"]),
			int(st_z["live"]), DebugStats.get_counter(&"proj_pool_trim") - c0])
	_check("B2 触发后 runtime_inst==0（懒增长口仍封死）",
		int(st_z["runtime_instantiates"]) == 0, "")
	_gl._physics_process(1.0 / 60.0)
	_gl._physics_process(1.0 / 60.0)
	_check("B2 会话闩：后续帧不再裁/不再计（一次性）",
		DebugStats.get_counter(&"proj_pool_trim") - c0 == 820 - VALVE_CAP
			and int(pool.stats()["capacity"]) == VALVE_CAP, "")
	await _free_gl()


func _reset_all() -> void:
	GameFeelDirector.burst_thin_override = -1
	GameLoop.pool_valve_override = -1
	Enemy.fullload_override = -1
	PerfGovernor.mode_override = -1
	PerfGovernor.tier_override = -1
	PerfGovernor.tier = 3
	PerfGovernor.transitions = 0
	PerfGovernor._ema_inject = -1.0
	PerfGovernor._test_reset()
	PerfGovernor.set_process(true)
	Meta.set_setting("fx_quality", 2)
	tree.paused = false
	RunSave.clear()

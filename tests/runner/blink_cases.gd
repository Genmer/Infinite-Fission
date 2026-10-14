# tests/runner/blink_cases.gd
# BLINK 闪现爆炸族用例体（由 test_blink.gd 入口在 autoload 就绪后运行时加载编译）。
# 真源：docs/design/ENEMY_PATTERNS_BASIC.md §3.3（行为伪代码）+ §6.6（测试锚）。
extends RefCounted

const DT := 1.0 / 120.0
const MAIN_SCENE := "res://scenes/main.tscn"

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_boot_game_loop()
	_test_e24_data_and_validator()                # E24 真源 + BLINK 校验
	_test_blink_snapshot_and_blast()              # 落点快照 ±24 + 引爆结算 + 走位出圈
	_test_blink_interrupts()                      # 冻结断读条 / 击退断引信 / 引信冻结停摆
	_test_world_layer_ring()                      # 红圈挂世界层钉死落点
	_test_wave_table_weave()                      # 魔域 w3 织入 E24
	_teardown_game_loop()
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)


func fail_count() -> int:
	return _fail


# ── 环境 ──────────────────────────────────────────────────────────
func _boot_game_loop() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "GameLoopUnderTest"
	tree.get_root().add_child(_gl)


func _teardown_game_loop() -> void:
	tree.paused = false
	RunSave.clear()
	if _gl != null:
		_gl.free()
		_gl = null


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("PASS | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s %s" % [p_name, p_detail])
		print("FAIL | %s | %s" % [p_name, p_detail])


func _make_blink_enemy() -> Enemy:
	# E24 真源直出（registry 校验通过后）：wave 1 零成长口径
	var data: EnemyData = _gl.registry.get_enemy(&"E24_rift_demon")
	var e: Enemy = (_gl.pools[&"enemy"] as EnemyPool).acquire()
	e.spawn(data, 1, 0)
	e.position = Vector2(360.0, 300.0)
	return e


func _release(e: Enemy) -> void:
	# 自爆死亡的敌人已经 EventBus.enemy_killed → spawner 回收；此处只归还存活实例
	if not e.dead:
		(_gl.pools[&"enemy"] as EnemyPool).release(e)


func _tick_blink(e: Enemy, p_frames: int) -> void:
	for i in range(p_frames):
		e.tick(DT)


# ── 数据 / 校验 ───────────────────────────────────────────────────
func _test_e24_data_and_validator() -> void:
	print("── E24 数据 / 校验 ──")
	var data: EnemyData = _gl.registry.get_enemy(&"E24_rift_demon")
	_check("E24：注册表收录", data != null)
	if data == null:
		return
	_check("E24：behavior = BLINK（未降级）",
		int(data.behavior) == GameConst.EnemyBehavior.BLINK)
	_check("E24：special 五键齐（cd/prep/fuse/blast_r/range）",
		data.special.has("blink_cd") and data.special.has("blink_prep")
		and data.special.has("fuse") and data.special.has("blast_r")
		and data.special.has("blink_range"))
	var v := DataValidator.new()
	var report: Array = v.validate_enemy(data)
	var errs := 0
	for r: Dictionary in report:
		if String(r.get("severity", "")) == DataValidator.SEV_ERROR:
			errs += 1
	_check("E24：validator 零 error", errs == 0, "errors=%d" % errs)
	# BLINK 缺 fuse/blast_r → error（§6.4 逐族必填断言）
	var bad := EnemyData.new()
	bad.id = &"E_BLINK_BAD"
	bad.hp_base = 47.0
	bad.behavior = GameConst.EnemyBehavior.BLINK
	bad.special = {"blink_cd": 3.2}
	var bad_report: Array = v.validate_enemy(bad)
	var bad_err := false
	for r: Dictionary in bad_report:
		if String(r.get("severity", "")) == DataValidator.SEV_ERROR:
			bad_err = true
	_check("校验：BLINK 缺 special.fuse/blast_r → error", bad_err)


# ── 快照 / 引爆 ───────────────────────────────────────────────────
func _test_blink_snapshot_and_blast() -> void:
	print("── 快照 / 引爆 ──")
	var e := _make_blink_enemy()
	_gl.player.position = Vector2(360.0, 640.0)
	_gl.player.invuln_left = 0.0
	_gl.player.hp = 60.0
	var hp0: float = _gl.player.hp
	# 巡航 → 进入读条（快照帧）
	var snap := Vector2.ZERO
	var state := 0
	for i in range(600):
		e.tick(DT)
		if int(e.blink_state()) == 1 and snap == Vector2.ZERO:
			snap = e.blink_target()
			state = 1
			break
	_check("BLINK：进入读条（快照就位）", state == 1)
	_check("BLINK：快照 = 施法帧玩家位置（±1px）",
		snap.distance_to(Vector2(360.0, 640.0)) <= 1.0)
	# 读条走完 → 闪现落点
	_tick_blink(e, 50)
	_check("BLINK：读条毕进入引信态", int(e.blink_state()) == 2)
	_check("BLINK：落点 = 快照 ±24px（§3.3）",
		e.global_position.distance_to(snap) <= 24.0 + 0.5)
	_check("BLINK：引信期存活", not e.dead)
	# 引信走完 → 引爆结算（玩家站圈内 → 吃 18 = dmg_base wave1）
	_tick_blink(e, 110)
	_check("BLINK：引信毕自爆死亡", e.dead)
	var dropped := hp0 - _gl.player.hp
	_check("BLINK：圈内玩家吃爆炸 18（30% 档）", absf(dropped - 18.0) < 0.01,
		"实扣 %.1f" % dropped)
	_release(e)
	# 走位出圈：闪现后立刻拉开 400px → 引爆炸死但玩家免伤
	var e2 := _make_blink_enemy()
	_gl.player.invuln_left = 0.0
	_gl.player.hp = 60.0
	for i in range(600):
		e2.tick(DT)
		if int(e2.blink_state()) == 2:
			break
	_gl.player.position = e2.global_position + Vector2(400.0, 0.0)   # 出圈走位
	_tick_blink(e2, 110)
	_check("BLINK：走位出圈免伤（引爆仍致死本体）",
		e2.dead and absf(_gl.player.hp - 60.0) < 0.001)
	_release(e2)


# ── 打断双路 ──────────────────────────────────────────────────────
func _test_blink_interrupts() -> void:
	print("── 打断双路 ──")
	# 冻结断读条（CHARGING 态 sf=0 → 回巡航 + 施法冷却）
	var e := _make_blink_enemy()
	e.elemental = ElementalState.new()
	for i in range(600):
		e.tick(DT)
		if int(e.blink_state()) == 1:
			break
	var pos0 := e.global_position
	e.elemental.freeze_timer = 1.0
	e.tick(DT)
	_check("BLINK：冻结断读条（回巡航）", int(e.blink_state()) == 0)
	_check("BLINK：打断后未位移", e.global_position.distance_to(pos0) <= 0.5)
	e.elemental.freeze_timer = 0.0
	# 施法冷却期不重入读条（2s）
	_tick_blink(e, 60)
	_check("BLINK：打断后进施法冷却（1s 内不重读条）", int(e.blink_state()) == 0)
	_release(e)
	# 引信冻结停摆（FUSED 态不推进不引爆）
	var e2 := _make_blink_enemy()
	e2.elemental = ElementalState.new()
	for i in range(600):
		e2.tick(DT)
		if int(e2.blink_state()) == 2:
			break
	e2.elemental.freeze_timer = 1.0
	_tick_blink(e2, 30)
	_check("BLINK：引信期冻结停摆（不引爆不推进）",
		int(e2.blink_state()) == 2 and not e2.dead)
	e2.elemental.freeze_timer = 0.0
	# 击退断引信（FUSED 态被击退 → 回巡航、不引爆）
	e2.knockback(Vector2(80.0, 0.0))
	_check("BLINK：击退断引信（回巡航）", int(e2.blink_state()) == 0)
	e2.set("_blink_cd", 3.0)                       # 置冷却（打断后不立即重入读条——隔离待测行为）
	_tick_blink(e2, 200)
	_check("BLINK：打断后不引爆", not e2.dead)
	_release(e2)


# ── 世界层红圈 ────────────────────────────────────────────────────
func _test_world_layer_ring() -> void:
	print("── 世界层红圈 ──")
	var e := _make_blink_enemy()
	for i in range(600):
		e.tick(DT)
		if int(e.blink_state()) == 2:
			break
	var ring: Telegraph.TelegraphCircle = e.get("_blink_ring")
	_check("BLINK：落点红圈实例化（TelegraphCircle）", ring != null)
	_check("BLINK：红圈挂世界层（非怪子节点——闪现后怪已位移）",
		ring != null and ring.get_parent() != e)
	_check("BLINK：红圈钉死快照落点",
		ring != null and ring.position.distance_to(e.blink_target()) <= 0.5)
	_check("BLINK：红圈半径 = blast_r 110", ring != null and ring.radius == 110.0)
	_release(e)


# ── 波表织入 ──────────────────────────────────────────────────────
func _test_wave_table_weave() -> void:
	print("── 魔域波表 ──")
	var demon_txt := FileAccess.get_file_as_string("res://resources/maps/wave_table_demon.tres")
	_check("魔域 w3：E24_rift_demon 织入（w3 新体验锚点）",
		demon_txt.contains("E24_rift_demon"))
	_check("注册表：E24 可被波表引用（悬空剔除校验通过）",
		_gl.registry.get_enemy(&"E24_rift_demon") != null)

# tests/runner/elite_affix_cases.gd
# 夜间R39 精英词缀用例体（由 test_elite_affix.gd 入口在 autoload 就绪后运行时加载编译）。
# 锁定口径（ENEMY_BOSS_TELEGRAPH §6）：
# · 投放门：wave<8 无词缀 / wave≥8 单词缀 / wave≥15 可双词缀（本批池无互斥对）；
# · 执行：ring=8 发环形 speed170 dmg7；sniper=3 发 24° 扇 speed300 dmg11（锁定快照）；
#   trapper=2 雷 blast80 dmg15；
# · 打断：前摇期冻结（elemental freeze）→ 取消 + cd 退 50%；
# · Boss 恒无词缀；前摇表值已含 +150ms；扫线/狂暴不在词缀池。
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
	_test_roll_gate()
	_test_ring_affix()
	_test_sniper_affix()
	_test_trapper_affix()
	_test_freeze_interrupt()
	_test_charger_affix()
	_test_caller_affix()
	_test_exclusive_pair()
	_teardown_game_loop()
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)


func fail_count() -> int:
	return _fail


func _boot_game_loop() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "GameLoopUnderTest"
	tree.get_root().add_child(_gl)
	_gl.state = GameConst.GameStatus.MENU
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	_gl.start_run()
	_gl.player.set("max_hp", 1000000.0)
	_gl.player.set("hp", 1000000.0)
	_gl.player.set("unlocked_slots", 4)


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


func _make_elite(p_wave: int) -> Enemy:
	# 真链路：走 spawner._elite_affix_roll（同 GameLoop 出怪行），非直调 set
	var data: EnemyData = _gl.registry.get_enemy(&"E5_elite").duplicate() as EnemyData
	var e: Enemy = (_gl.pools[&"enemy"] as EnemyPool).acquire()
	e.spawn(data, p_wave, GameConst.TAG_ELITE)
	e.projectile_pool = _gl.pools[&"projectile"]
	e.position = Vector2(360.0, 400.0)
	_gl.spawner.active.append(e)
	_gl.spawner.call("_elite_affix_roll", e, p_wave)
	return e


func _clear_bullets() -> void:
	# 倒序遍历（active_projectiles 契约：nullify→release→erase 当前位，正序隔一漏一）
	var list := (_gl.pools[&"projectile"] as ProjectilePool).active_projectiles()
	for i in range(list.size() - 1, -1, -1):
		var b: Node2D = list[i]
		if b is ProjectileBase and (b as ProjectileBase).team == 1:
			b.call("nullify")


func _count_enemy_bullets() -> int:
	var n := 0
	for b in (_gl.pools[&"projectile"] as ProjectilePool).active_projectiles():
		if b is ProjectileBase and (b as ProjectileBase).team == 1:
			n += 1
	return n


func _drive_cast(e: Enemy, p_frames: int) -> void:
	# 驱动词缀 tick（无头手动；玩家引用由 enemy._player() 解析）
	for i in range(p_frames):
		e.call("_tick_elite_affixes", DT, _gl.player, 1.0)


func _release_now(e: Enemy, p_affix: StringName) -> void:
	# 直达释放（参数断言用；前摇链路由 _drive_cast 覆盖）
	e.set("_affix_casting", e.elite_affixes.find(p_affix))
	e.set("_affix_cast_left", 0.0)
	e.set("_affix_cast_total", 0.55)
	e.set("_affix_dir", Vector2.UP)
	e.call("_affix_release", _gl.player)


# ── 用例 ──────────────────────────────────────────────────────────
func _test_roll_gate() -> void:
	print("── 投放门 ──")
	seed(7)
	var below: Enemy = _make_elite(7)
	_check("wave7 精英无词缀", below.elite_affixes.is_empty(),
		str(below.elite_affixes))
	(_gl.pools[&"enemy"] as EnemyPool).release(below)
	var has_affix := false
	var double_seen := false
	for i in range(24):
		var e: Enemy = _make_elite(8 if i % 2 == 0 else 16)
		has_affix = has_affix or not e.elite_affixes.is_empty()
		double_seen = double_seen or e.elite_affixes.size() == 2
		for a in e.elite_affixes:
			_check_inner(a in ["affix_ring", "affix_sniper", "affix_trapper"],
				"词缀 %s 越池（扫线/狂暴未下放）" % str(a))
		(_gl.pools[&"enemy"] as EnemyPool).release(e)
	_check("wave8+ 精英获得词缀", has_affix)
	_check("wave15+ 出现双词缀（24 次抽样 ≥1）", double_seen)
	var boss: Enemy = _make_elite(10)
	boss.set_elite_affixes([])               # 清掉 make 时 roll 的词缀（测 Boss 判定本身）
	boss.tags = boss.tags | GameConst.TAG_BOSS
	_gl.spawner.call("_elite_affix_roll", boss, 10)
	_check("Boss 恒无词缀", boss.elite_affixes.is_empty(),
		str(boss.elite_affixes))


var _inner_fail: bool = false


func _check_inner(p_cond: bool, p_msg: String) -> void:
	if not p_cond:
		_inner_fail = true
		print("  INNER-FAIL | %s" % p_msg)


func _test_ring_affix() -> void:
	print("── 环爆体 affix_ring ──")
	seed(11)
	var e: Enemy = _make_elite(10)
	if e.elite_affixes.is_empty():
		e.set_elite_affixes([&"affix_ring"])
	e.set_elite_affixes([&"affix_ring"])   # 无条件重设（make 时 roll 结果不定）
	var idx: int = e.elite_affixes.find(&"affix_ring")
	_check("前置：词缀在列", idx >= 0, str(e.elite_affixes))
	_clear_bullets()
	_release_now(e, &"affix_ring")
	_check("环爆：8 发环形弹", _count_enemy_bullets() == 8,
		"n=%d" % _count_enemy_bullets())
	_check("环爆：cd 重置为表值 7s", is_equal_approx(float(e._affix_cd[idx]), 7.0),
		"cd=%.2f" % float(e._affix_cd[idx]))
	(_gl.pools[&"enemy"] as EnemyPool).release(e)


func _test_sniper_affix() -> void:
	print("── 狙击手 affix_sniper ──")
	seed(13)
	var e: Enemy = _make_elite(10)
	e.set_elite_affixes([&"affix_sniper"])
	e.set("_affix_dir", Vector2.UP)
	_clear_bullets()
	e.set("_affix_casting", 0)
	e.set("_affix_cast_left", 0.0)
	e.set("_affix_cast_total", 0.85)
	e.call("_affix_release", _gl.player)
	var angles: Array[float] = []
	for b in (_gl.pools[&"projectile"] as ProjectilePool).active_projectiles():
		if b is ProjectileBase and (b as ProjectileBase).team == 1:
			angles.append(snappedf((b as ProjectileBase).velocity.angle_to(Vector2.UP), 0.001))
	angles.sort()
	_check("狙击：3 发", angles.size() == 3, "n=%d" % angles.size())
	if angles.size() == 3:
		_check("狙击：±12° 等角扇（arc 24°）",
			absf(angles[0] + deg_to_rad(12.0)) < 0.01 and absf(angles[2] - deg_to_rad(12.0)) < 0.01
				and absf(angles[1]) < 0.01, str(angles))
	(_gl.pools[&"enemy"] as EnemyPool).release(e)


func _test_trapper_affix() -> void:
	print("── 布雷者 affix_trapper ──")
	seed(17)
	var e: Enemy = _make_elite(10)
	e.set_elite_affixes([&"affix_trapper"])
	var mines_before := _count_mines()
	e.set("_affix_casting", 0)
	e.set("_affix_cast_left", 0.0)
	e.set("_affix_cast_total", 0.85)
	e.call("_affix_release", _gl.player)
	var mines_after := _count_mines()
	_check("布雷：新增 2 颗雷（blast 80）", mines_after - mines_before == 2,
		"%d→%d" % [mines_before, mines_after])
	(_gl.pools[&"enemy"] as EnemyPool).release(e)


func _count_mines() -> int:
	# BossMine 挂在 enemy.parent（池容器）——扫 whole tree 计数
	var n := 0
	var stack: Array[Node] = [tree.get_root()]
	while not stack.is_empty():
		var cur: Node = stack.pop_front()
		if cur is Enemy.BossMine:
			n += 1
		for c in cur.get_children():
			stack.append(c)
	return n


func _test_freeze_interrupt() -> void:
	print("── 冻结打断（cd 退 50%） ──")
	seed(19)
	var e: Enemy = _make_elite(10)
	e.set_elite_affixes([&"affix_ring"])
	# 直接触发前摇（绕开冷却等待）
	e._affix_cd[0] = 0.0
	_drive_cast(e, 2)
	_check("前摇已开启", e._affix_casting >= 0, "casting=%d" % e._affix_casting)
	# 模拟冻结：注入 elemental state 并置 freeze_timer
	var el := ElementalState.new()
	e.set("elemental", el)
	el.freeze_timer = 1.2
	_drive_cast(e, 6)
	_check("冻结打断：前摇取消", e._affix_casting == -1)
	_check("冻结打断：cd 退 50%（3.5s）", is_equal_approx(float(e._affix_cd[0]), 3.5),
		"cd=%.2f" % float(e._affix_cd[0]))
	(_gl.pools[&"enemy"] as EnemyPool).release(e)


func _test_charger_affix() -> void:
	print("── 冲锋者 affix_charger ──")
	seed(23)
	var e: Enemy = _make_elite(10)
	e.set_elite_affixes([&"affix_charger"])
	var base_speed: float = float(e.speed)
	# 走完整前摇：cd 清零 → 驱动至释放
	e._affix_cd[0] = 0.0
	var pos0: Vector2 = e.global_position
	_drive_cast(e, int(0.45 / DT) + 4)
	_check("冲锋：前摇毕进入冲刺位移", e.global_position.distance_to(pos0) > 2.0,
		"d=%.1f" % e.global_position.distance_to(pos0))
	_check("冲锋：冲刺期接触伤 ×1.25", is_equal_approx(float(e._affix_dmg_mult), 1.25),
		"mult=%.2f" % float(e._affix_dmg_mult))
	# 冲刺段走完 → mult 复位
	for i in range(int(0.4 / DT)):
		e.call("_tick_elite_affixes", DT, _gl.player, 1.0)
	_check("冲锋：段毕伤害复位", is_equal_approx(float(e._affix_dmg_mult), 1.0))
	(_gl.pools[&"enemy"] as EnemyPool).release(e)


var _summon_events: Array = []


func _test_caller_affix() -> void:
	print("── 唤潮者 affix_caller ──")
	seed(29)
	# 捕获广播（GameLoop 订阅的 cap 判定在同链路；此处锁 enemy 侧信号载荷）
	var cb := func(uid: int, eid: StringName, pos: Vector2, ratio: float) -> void:
		_summon_events.append([uid, eid, pos, ratio])
	EventBus.elite_summon_requested.connect(cb)
	var e: Enemy = _make_elite(10)
	e.call("set_elite_affixes", [&"affix_caller"])
	e._affix_cd[0] = 0.0
	_drive_cast(e, int(1.15 / DT) + 4)
	_check("唤潮：广播 1 次（E1_grunt / hp_ratio 0.5）",
		_summon_events.size() == 1 and String(_summon_events[0][1]) == "E1_grunt"
			and is_equal_approx(float(_summon_events[0][3]), 0.5),
		str(_summon_events))
	EventBus.elite_summon_requested.disconnect(cb)
	(_gl.pools[&"enemy"] as EnemyPool).release(e)


func _test_exclusive_pair() -> void:
	print("── 互斥对（charger×trapper） ──")
	seed(31)
	var pool: Array = _gl.spawner.ELITE_AFFIX_POOL
	var clash_seen := false
	for i in range(60):
		var e: Enemy = _make_elite(16)
		var names: Array[String] = []
		for a in e.elite_affixes:
			names.append(String(a))
		if names.has("affix_charger") and names.has("affix_trapper"):
			clash_seen = true
		(_gl.pools[&"enemy"] as EnemyPool).release(e)
	_check("互斥对：60 次双词缀抽样无 charger×trapper 同叠", not clash_seen)

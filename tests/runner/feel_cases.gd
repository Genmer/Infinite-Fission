# tests/runner/feel_cases.gd
# 打击质感 + 技能演出用例体（由 test_feel.gd 入口加载）。
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
	_test_skill_fx_and_ratio()
	_test_skill_cast_broadcast()
	_test_elite_kill_hitstop()
	_test_death_pop()
	_test_muzzle_flash()
	_test_sfx_pitch()
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


func _test_skill_fx_and_ratio() -> void:
	print("── 技能演出 / 时长条 ──")
	# 薇拉（rof 增益 4s）：激活 → ratio≈1 → 驱动 4s → 归零
	_gl.player.set("character_id", &"veles")
	_gl.player.set("skill_cd_left", 0.0)
	_check("前置：技能可释放", bool(_gl.player.call("skill_ready")))
	_check("前置：未释放时 ratio = 0", float(_gl.player.call("skill_active_ratio")) == 0.0)
	_gl.player.call("activate_skill")
	var r0: float = float(_gl.player.call("skill_active_ratio"))
	_check("技能演出：激活后 ratio≈1（时长条满）", r0 > 0.9, "%.2f" % r0)
	for i in range(360):                          # 3s
		_gl.player.tick(DT, Vector2.ZERO)
	var r_mid: float = float(_gl.player.call("skill_active_ratio"))
	_check("技能演出：中段 ratio 递减（0.2~0.6）", r_mid > 0.2 and r_mid < 0.6, "%.2f" % r_mid)
	for i in range(180):                          # 再 1.5s（超 4s）
		_gl.player.tick(DT, Vector2.ZERO)
	_check("技能演出：效果结束 ratio = 0（结束可读）",
		float(_gl.player.call("skill_active_ratio")) == 0.0)
	# 瞬发型角色（演算者·零）也有 0.8s 施放闪光
	_gl.player.set("character_id", &"zero")
	_gl.player.set("skill_cd_left", 0.0)
	_gl.player.call("activate_skill")
	var r_flash: float = float(_gl.player.call("skill_active_ratio"))
	_check("技能演出：瞬发型角色也有施放闪光（0.8s）", r_flash > 0.5, "%.2f" % r_flash)
	for i in range(120):
		_gl.player.tick(DT, Vector2.ZERO)
	_check("技能演出：瞬发闪光归零",
		float(_gl.player.call("skill_active_ratio")) == 0.0)


func _test_skill_cast_broadcast() -> void:
	print("── 施放广播（FX 层金环） ──")
	var saw_cast := [false]
	var handler := func(_pos: Vector2, _cid: String) -> void:
		saw_cast[0] = true
	EventBus.skill_cast.connect(handler)
	_gl.player.set("character_id", &"sentinel")
	_gl.player.set("skill_cd_left", 0.0)
	_gl.player.call("activate_skill")
	EventBus.skill_cast.disconnect(handler)
	_check("技能施放：skill_cast 广播（FX 层金环消费源）", bool(saw_cast[0]))


func _test_elite_kill_hitstop() -> void:
	print("── 精英击杀顿帧 ──")
	var e: Enemy = (_gl.pools[&"enemy"] as EnemyPool).acquire()
	var data: EnemyData = _gl.registry.get_enemy(&"E1_grunt")
	e.spawn(data, 10, GameConst.TAG_ELITE)
	e.position = Vector2(300.0, 600.0)
	_gl.spawner.active.append(e)
	_gl.game_feel.hit_stop_left = 0.0
	e.apply_damage(999999.0)
	_gl._physics_process(DT)
	_check("打击质感：精英击杀触发 CRIT 档顿帧", _gl.game_feel.hit_stop_left > 0.0)


func _test_death_pop() -> void:
	print("── 死亡弹爆 ──")
	var parent_n: Node = null
	var c1 := -1
	# 同帧连杀两只：c2 == c1 + 1（确定性——无帧推进即无弹爆过期干扰）
	for j in range(2):
		var e: Enemy = (_gl.pools[&"enemy"] as EnemyPool).acquire()
		var data: EnemyData = _gl.registry.get_enemy(&"E1_grunt")
		e.spawn(data, 1, 0)
		e.position = Vector2(500.0, 700.0)
		_gl.spawner.active.append(e)
		if parent_n == null:
			parent_n = e.get_parent()
		e.apply_damage(999999.0)
		var c: int = _count_death_pops(parent_n)
		if j == 0:
			c1 = c
		else:
			_check("打击质感：击杀落场死亡弹爆件（连杀计数 +1）", c == c1 + 1,
				"c1=%d c2=%d" % [c1, c])
	# 弹爆 0.2s 自清（驱动 _process 通道）
	var leftover: int = _count_death_pops(parent_n)
	for i in range(40):
		for c in parent_n.get_children():
			if str(c.name).begins_with("DeathPop"):
				c.call("_process", DT)
	await tree.process_frame
	_check("打击质感：弹爆 0.2s 自清", _count_death_pops(parent_n) <= leftover)


func _count_death_pops(p_root: Node) -> int:
	# 按类型计数（Godot 对同父重名子节点自动改名——名字计数不可靠）
	var n := 0
	for c in p_root.get_children():
		if c is Enemy.DeathPop:
			n += 1
	return n


func _test_muzzle_flash() -> void:
	print("── 枪口闪光 ──")
	var pistol: WeaponBase = _gl.player.weapon_slots[0]
	pistol.call("try_fire")
	var flash: Sprite2D = pistol.get("_muzzle_flash")
	_check("打击质感：枪口闪光可见（弹道武器开火）",
		flash != null and flash.visible)
	var timer: float = float(pistol.get("_muzzle_timer"))
	_check("打击质感：闪光计时推进（0.05s 自熄）", timer > 0.0 and timer <= 0.05)
	for p in (_gl.pools[&"projectile"] as ProjectilePool).active_projectiles():
		p.nullify()


func _test_sfx_pitch() -> void:
	print("── 音调微随机 ──")
	SfxBank.I.play(&"hit")
	var p1: AudioStreamPlayer = SfxBank.I._players[&"hit"]
	_check("打击质感：命中音调微随机（±6% 内）",
		p1.pitch_scale >= 0.93 and p1.pitch_scale <= 1.07,
		"%.3f" % p1.pitch_scale)

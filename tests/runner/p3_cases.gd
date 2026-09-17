# tests/runner/p3_cases.gd
# Boss 三阶段+狂暴+裂变召唤用例体（由 test_p3.gd 入口加载）。
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
	_test_three_phase_and_enrage()
	_test_summons_wiring()
	_test_real_boss_configs()
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


func _make_phase3_boss() -> Enemy:
	# 三阶段合成 Boss（enrage 全配置；零速防位移）
	var data := EnemyData.new()
	data.id = &"E_P3_T"
	data.hp_base = 1000000.0
	data.spd_base = 0.0
	data.dmg_base = 5.0
	data.hitbox_r = 14.0
	data.tags = GameConst.TAG_BOSS
	data.boss = {"phases": 3, "phase2_hp": 0.6, "phase3_hp": 0.3, "phase2_resist": 0.2,
		"barrage": [{"type": "ring", "phase": 1, "cd": 6.0, "telegraph": "swell",
			"telegraph_s": 0.4, "count": 6, "speed": 170.0, "dmg": 7.0}],
		"summons": {"interval_s": 12.0, "enemy_id": "E1_grunt", "count": 2},
		"enrage": {"hp_threshold": 0.3, "cd_mult": 0.8, "speed_mult": 1.2, "rate_mult": 1.3}}
	var boss: Enemy = (_gl.pools[&"enemy"] as EnemyPool).acquire()
	boss.spawn(data, 10, 0)
	boss.projectile_pool = _gl.pools[&"projectile"]
	boss.position = _gl.player.global_position + Vector2(300.0, 0.0)
	return boss


func _test_three_phase_and_enrage() -> void:
	print("── 三阶段 / 狂暴化 ──")
	var boss := _make_phase3_boss()
	for i in range(boss._barrage_cd.size()):
		boss._barrage_cd[i] = 99.0
	_check("前置：阶段 1", int(boss.boss_phase) == 1)
	# 跨 phase2（60%）
	boss.hp = boss.max_hp * 0.55
	boss.tick(DT)
	_check("阶段机：HP ≤ 60% → 阶段 2", int(boss.boss_phase) == 2)
	_check("阶段 2：全抗 +0.2 一次", absf(boss.resist[0] - 0.2) < 0.001)
	# 跨 phase3（30%）→ 狂暴
	boss.hp = boss.max_hp * 0.25
	boss.tick(DT)
	_check("阶段机：HP ≤ 30% → 阶段 3", int(boss.boss_phase) == 3)
	_check("B8：狂暴锁存（_enrage_done）", bool(boss.get("_enrage_done")))
	_check("B8：全抗不重复加（仍 0.2）", absf(boss.resist[0] - 0.2) < 0.001)
	_check("B8：乘区就位（cd ×0.8 / 弹速 ×1.2）",
		absf(float(boss.get("_enrage_cd_mult")) - 0.8) < 0.001
		and absf(float(boss.get("_enrage_speed_mult")) - 1.2) < 0.001)
	# 狂暴前摇缩档（0.4 × 0.85 = 0.34；先清切段重置的 cd 才能观测到起手）
	for i in range(boss._barrage_cd.size()):
		boss._barrage_cd[i] = 0.0
	_tick_boss(boss, 2)
	var tele: float = float(boss.get("_cast_total"))
	_check("B8：狂暴前摇 ×0.85（0.4→0.34）", tele > 0.3 and tele <= 0.35,
		"%.3f" % tele)
	# 回血不撤销狂暴（锁存）
	boss.hp = boss.max_hp * 0.9
	boss.tick(DT)
	_check("B8：血量回升不撤销狂暴（一次性锁存）",
		bool(boss.get("_enrage_done")) and int(boss.boss_phase) == 3)
	# 阶段切换 cd 重置（切段后 cd = max(cd×0.5, 1.5)）
	_check("切段：技能 cd 重置（≤ cd×0.5+容差）",
		float(boss.get("_barrage_cd")[0]) <= 3.0)
	(_gl.pools[&"enemy"] as EnemyPool).release(boss)


func _test_summons_wiring() -> void:
	print("── B4 裂变召唤 ──")
	_gl.state = GameConst.GameStatus.MENU
	_gl.start_run()
	_gl.player.set("max_hp", 1000000.0)
	_gl.player.set("hp", 1000000.0)
	var boss := _make_phase3_boss()
	boss.get("data").boss["summons"] = {"interval_s": 0.5, "enemy_id": "E1_grunt",
		"count": 2, "cap": 4, "hp_ratio": 0.3}
	_gl.spawner.active.append(boss)
	_gl._on_boss_spawned_track_summons(boss)
	for i in range(180):                          # 1.5s：至少 2 轮召唤节拍
		if _gl.state == GameConst.GameStatus.LEVEL_UP:
			_gl.change_state(GameConst.GameStatus.PLAYING)
		_gl._physics_process(DT)
	var summoned := 0
	var reduced_hp := false
	for e in _gl.spawner.active:
		if is_instance_valid(e) and not bool(e.get("dead")) \
				and (e as Enemy).data != null and String((e as Enemy).data.id) == "E1_grunt":
			summoned += 1
			if (e as Enemy).max_hp < (e as Enemy).data.hp_base * 1.2:
				reduced_hp = true                 # hp_ratio 0.3 折算（远低于 w1 基线）
	_check("B4：召唤节拍生成小怪（≥2 只）", summoned >= 2, "实得 %d" % summoned)
	_check("B4：召唤物面值折算（hp_ratio 0.3）", reduced_hp)
	# 上限：继续驱动 4s → 同种在场 ≤ cap 4
	for i in range(480):
		if _gl.state == GameConst.GameStatus.LEVEL_UP:
			_gl.change_state(GameConst.GameStatus.PLAYING)
		_gl._physics_process(DT)
	var alive := 0
	for e in _gl.spawner.active:
		if is_instance_valid(e) and not bool(e.get("dead")) \
				and (e as Enemy).data != null and String((e as Enemy).data.id) == "E1_grunt" \
				and int(e.get_meta(&"_summoned_by", -1)) == int(boss.get("uid")):
			alive += 1
	_check("B4：该 Boss 召唤物在场 ≤ cap（4，自然波次不误伤）", alive <= 4, "实得 %d" % alive)


func _test_real_boss_configs() -> void:
	print("── 真源配置 ──")
	for id in [&"E17_frost_sovereign", &"E18_demon_lord", &"E19_grove_warden",
		&"E20_swamp_hydra"]:
		var data: EnemyData = _gl.registry.get_enemy(id)
		_check("%s：三阶段 + enrage 在册" % String(id),
			data != null and int(data.boss.get("phases", 0)) == 3
			and data.boss.has("enrage"))
	var e6: EnemyData = _gl.registry.get_enemy(&"E6_boss1")
	_check("E6 教学级：保持两阶段（无 enrage）",
		e6 != null and int(e6.boss.get("phases", 0)) == 2 and not e6.boss.has("enrage"))


func _tick_boss(p_boss: Enemy, p_frames: int) -> void:
	for i in range(p_frames):
		p_boss.tick(DT)

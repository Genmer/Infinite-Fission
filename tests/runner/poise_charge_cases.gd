# tests/runner/poise_charge_cases.gd
# 韧性条打断 + B5 三连冲锋 + 施法音色用例体（由 test_poise_charge.gd 入口加载）。
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
	_test_poise_stagger()
	_test_stagger_blocks_and_laser_immunity()
	_test_charge_segments()
	_test_cast_sounds()
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
	_gl.player.set("unlocked_slots", 2)


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


func _make_poise_boss() -> Enemy:
	var data := EnemyData.new()
	data.id = &"E_POISE_T"
	data.hp_base = 1000000.0
	data.spd_base = 0.0
	data.dmg_base = 5.0
	data.hitbox_r = 14.0
	data.tags = GameConst.TAG_BOSS
	data.boss = {"phases": 3, "phase2_hp": 0.6, "phase3_hp": 0.3, "phase2_resist": 0.2,
		"poise_max": 50.0,
		"charge": {"phase": 2, "spd": 560.0, "segments": 3, "seg_time": 0.45,
			"gap_s": 0.55, "telegraph_s": 0.4, "dmg_pct": 35.0},
		"barrage": [{"type": "ring", "phase": 1, "cd": 6.0, "telegraph": "swell",
			"telegraph_s": 0.4, "count": 6, "speed": 170.0, "dmg": 7.0}],
		"summons": {}}
	var boss: Enemy = (_gl.pools[&"enemy"] as EnemyPool).acquire()
	boss.spawn(data, 10, 0)
	boss.projectile_pool = _gl.pools[&"projectile"]
	boss.position = _gl.player.global_position + Vector2(320.0, 0.0)
	for i in range(boss._barrage_cd.size()):
		boss._barrage_cd[i] = 0.0
	return boss


func _hit_boss(p_boss: Enemy, p_value: float) -> void:
	# 走真实受击入口（韧性积累挂在 take_result）
	var r := DamageResult.new()
	r.final_value = p_value
	r.pos = _gl.player.global_position
	p_boss.take_result(r)


func _test_poise_stagger() -> void:
	print("── 韧性条 / 硬直 ──")
	var boss := _make_poise_boss()
	_check("前置：poise_max = 50", absf(float(boss.get("poise_max")) - 50.0) < 0.001)
	# 单次 30：积累 0.3 未满
	_hit_boss(boss, 30.0)
	_check("韧性：单次 30 未满（积累 0.3）", absf(float(boss.get("poise")) - 0.3) < 0.001)
	# 韧性上限 50 太慢——直接压低上限验证满触发
	boss.set("poise_max", 1.0)
	_hit_boss(boss, 200.0)
	_check("韧性：打满 → 硬直 1.2s", float(boss.get("_stagger_left")) > 0.0
		and absf(float(boss.get("poise"))) < 0.001)
	_check("韧性：免疫窗 6s 就位", float(boss.get("_poise_immune_left")) > 5.0)
	# 硬直期：不移动不放技能
	var pos0: Vector2 = boss.global_position
	for i in range(60):
		boss.tick(DT)
	_check("硬直：1.2s 内停摆（未位移）",
		boss.global_position.distance_to(pos0) < 0.5
		and int(boss.get("_cast_idx")) < 0)
	# 免疫窗：硬直结束后打满也不再硬直（6s 内）
	for i in range(160):
		boss.tick(DT)                              # 1.33s：硬直结束
	_check("硬直：1.33s 后结束", float(boss.get("_stagger_left")) <= 0.0)
	_hit_boss(boss, 500.0)
	_check("韧性免疫窗：6s 内不再硬直", float(boss.get("poise")) < 5.0
		and float(boss.get("_stagger_left")) <= 0.0)
	(_gl.pools[&"enemy"] as EnemyPool).release(boss)


func _test_stagger_blocks_and_laser_immunity() -> void:
	print("── 打断统一入口 / B7 免疫 ──")
	var data := EnemyData.new()
	data.id = &"E_POISE_T2"
	data.hp_base = 1000000.0
	data.spd_base = 0.0
	data.dmg_base = 5.0
	data.hitbox_r = 14.0
	data.tags = GameConst.TAG_BOSS
	data.boss = {"phases": 2, "phase2_hp": 0.5, "phase2_resist": 0.2, "poise_max": 50.0,
		"barrage": [
			{"type": "ring", "phase": 1, "cd": 6.0, "telegraph": "swell",
				"telegraph_s": 0.4, "count": 6, "speed": 170.0, "dmg": 7.0},
			{"type": "laser_sweep", "phase": 1, "cd": 11.0, "telegraph": "line",
				"telegraph_s": 0.4, "arc_deg": 60.0, "sweep_s": 1.0, "width_px": 26.0,
				"dmg": 30.0},
		],
		"summons": {}}
	var boss: Enemy = (_gl.pools[&"enemy"] as EnemyPool).acquire()
	boss.spawn(data, 10, 0)
	boss.projectile_pool = _gl.pools[&"projectile"]
	boss.position = _gl.player.global_position + Vector2(300.0, 0.0)
	for i in range(boss._barrage_cd.size()):
		boss._barrage_cd[i] = 0.0
	boss.tick(DT)                                 # ring 起手（索引 0）
	_check("前置：ring 施法中", int(boss.get("_cast_idx")) >= 0)
	boss.cancel_cast()
	_check("打断：普通施法被取消", int(boss.get("_cast_idx")) < 0)
	# laser_sweep 施法免疫打断：起手 sweep → cancel_cast 不取消
	for i in range(400):                          # ring cd 6s 未到 → 必然轮到 sweep（索引 1）
		boss.tick(DT)
		if int(boss.get("_cast_idx")) == 1:
			break
	_check("前置：laser_sweep 施法中", int(boss.get("_cast_idx")) == 1)
	boss.cancel_cast()
	_check("B7 免疫：扫线施法不被韧性打断（绝对命题）", int(boss.get("_cast_idx")) == 1)
	(_gl.pools[&"enemy"] as EnemyPool).release(boss)


func _test_charge_segments() -> void:
	print("── B5 三连冲锋 ──")
	var boss := _make_poise_boss()
	boss.set("boss_phase", 2)                     # charge phase 门控 ≥2
	boss.set("_chg_cd", 0.0)                      # 清开场缓冲（spawn 缓冲 4s）
	_gl.player.global_position = boss.global_position + Vector2(0.0, 300.0)
	var pos0: Vector2 = boss.global_position
	var max_disp := 0.0
	var saw_state2 := false
	for i in range(300):                          # 2.5s：前摇+冲刺应发生
		boss.tick(DT)
		max_disp = maxf(max_disp, boss.global_position.distance_to(pos0))
		if int(boss.get("_chg_state")) == 2:
			saw_state2 = true
	_check("B5：冲锋进入冲刺态", saw_state2)
	_check("B5：冲刺位移显著（>150px）", max_disp > 150.0, "%.0f" % max_disp)
	# 完整周期回归冷却态（3 段 × 前摇+冲刺+段间 ≈ 3.6s，给 6s 窗口）
	var back_to_idle := false
	var last_state := -1
	var last_cd := 0.0
	for i in range(720):
		boss.tick(DT)
		last_state = int(boss.get("_chg_state"))
		last_cd = float(boss.get("_chg_cd"))
		if i % 60 == 0:
			print("DBG t=%.2f state=%d seg=%d cd=%.2f pos=%s" % [i * DT, last_state,
				boss.get("_chg_seg_left"), last_cd, str(boss.global_position)])
		if last_state == 0 and last_cd > 0.0:
			back_to_idle = true
			break
	_check("B5：三段打完回冷却态（cd 9s）", back_to_idle
		and absf(last_cd - 9.0) < 0.05, "state=%d cd=%.2f" % [last_state, last_cd])
	(_gl.pools[&"enemy"] as EnemyPool).release(boss)


func _test_cast_sounds() -> void:
	print("── 施法音色 ──")
	var sfx = _gl.sfx
	_check("音色：cast_warn 就绪", sfx != null and sfx.has_method("play")
		and sfx._players.has(&"cast_warn"))
	_check("音色：cast_snap 就绪", sfx != null and sfx._players.has(&"cast_snap"))

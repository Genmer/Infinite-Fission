# tests/runner/boss_theme_cases.gd
# Boss 主题攻击用例体（由 test_boss_themes.gd 入口在 autoload 就绪后运行时加载编译）。
# 真源：docs/design/ENEMY_BOSS_TELEGRAPH.md §5.2~5.5 / §9 P2 + 用户反馈（冰降冰/火喷火）。
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
	_test_boss_data_migrated()
	_test_mine_field_and_frost_pool()
	_test_laser_sweep()
	_test_player_hazard_slow()
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


func _spawn_boss_with_def(p_def: Dictionary) -> Enemy:
	var data := EnemyData.new()
	data.id = &"E_THEME_T"
	data.hp_base = 1000000.0
	data.spd_base = 0.0
	data.dmg_base = 5.0
	data.hitbox_r = 14.0
	data.tags = GameConst.TAG_BOSS
	data.boss = {"phases": 2, "phase2_hp": 0.5, "phase2_resist": 0.2,
		"barrage": [p_def], "summons": {}}
	var boss: Enemy = (_gl.pools[&"enemy"] as EnemyPool).acquire()
	boss.spawn(data, 10, 0)
	boss.projectile_pool = _gl.pools[&"projectile"]
	boss.position = _gl.player.global_position + Vector2(280.0, 0.0)
	for i in range(boss._barrage_cd.size()):
		boss._barrage_cd[i] = 0.0
	return boss


# ── 数据迁移 ──────────────────────────────────────────────────────
func _test_boss_data_migrated() -> void:
	print("── 四 Boss 主题配置 ──")
	var expects := {
		&"E17_frost_sovereign": ["mine"],
		&"E18_demon_lord": ["flame_wave"],
		&"E19_grove_warden": ["laser_sweep", "mine"],
		&"E20_swamp_hydra": ["mine", "laser_sweep", "poison_pool"],
	}
	for id in expects:
		var data: EnemyData = _gl.registry.get_enemy(id)
		_check("%s：barrage 新真源（存量双轨清零）" % String(id),
			data != null and data.boss.has("barrage")
			and not data.boss.has("bullet_patterns"))
		if data == null:
			continue
		var types: Array = []
		var ids: Array = []
		var pool_keys: Array = []
		for b: Dictionary in data.boss["barrage"]:
			types.append(String(b.get("type", "")))
			if b.has("id"):
				ids.append(String(b["id"]))
			if b.has("slow_pool"):
				pool_keys.append("slow_pool")
			if b.has("poison_pool"):
				pool_keys.append("poison_pool")
		var ok := true
		for want in expects[id]:
			if not types.has(String(want)) and not ids.has(String(want)) \
					and not pool_keys.has(String(want)):
				ok = false
		_check("%s：主题技能在册（%s）" % [String(id), str(expects[id])], ok)
	# 校验器：E19/E20 不再产生存量折算告警
	var v := DataValidator.new()
	var report: Array = v.validate_enemy(_gl.registry.get_enemy(&"E19_grove_warden"))
	var has_legacy_warn := false
	for r: Dictionary in report:
		if String(r.get("field", "")) == &"boss.bullet_patterns":
			has_legacy_warn = true
	_check("校验器：E19 存量折算告警清零（双轨清零）", not has_legacy_warn)


# ── 雷区 + 冰锁池 ─────────────────────────────────────────────────
func _test_mine_field_and_frost_pool() -> void:
	print("── 雷区 / 冰锁圈 ──")
	var def := {"type": "mine", "phase": 1, "cd": 10.0, "telegraph": "circle",
		"telegraph_s": 0.7, "count": 4, "trigger_r": 42.0, "blast_r": 90.0,
		"arm_s": 0.8, "life_s": 8.0, "dmg": 21.0, "flavor": "frost",
		"slow_pool": {"radius": 80.0, "life_s": 3.5, "drag_mult": 0.6}}
	var boss := _spawn_boss_with_def(def)
	_tick_boss(boss, 160)                          # 前摇 0.7s（84 帧）+ 释放
	var mines: Array[Node] = []
	for c in boss.get_parent().get_children():
		if str(c.name).begins_with("BossMine"):
			mines.append(c)
	_check("B6：雷区落地 4 颗（挂世界层）", mines.size() == 4, "实得 %d" % mines.size())
	_check("B6：地雷位置 ≠ Boss 本体子节点（世界层锚定）",
		mines.is_empty() or mines[0].get_parent() != boss)
	# 驱动地雷：红圈缩圈 0.7s → 落地展开 0.8s → 玩家踩上触发爆炸
	_gl.player.global_position = (mines[0] as Node2D).global_position
	_gl.player.invuln_left = 0.0
	var hp0: float = _gl.player.hp
	for i in range(200):
		(mines[0] as Node).call("_process", DT)
	var dropped := hp0 - _gl.player.hp
	_check("B6：踩雷爆炸结算 21（35% 档）", absf(dropped - 21.0) < 0.01,
		"实扣 %.1f" % dropped)
	# 冰锁池：爆炸后落 slow_pool → 玩家站圈内被减速
	var pools: Array[Node] = []
	for c in boss.get_parent().get_children():
		if str(c.name).begins_with("HazardPool"):
			pools.append(c)
	_check("B6/frost：爆炸落冰锁圈（HazardPool）", not pools.is_empty())
	var slowed := false
	for i in range(60):
		for c in pools:
			(c as Node).call("_process", DT)
		if absf(float(_gl.player.get("hazard_slow_mult")) - 1.0) > 0.001:
			slowed = true
			break
	_check("B6/frost：冰锁圈减速玩家（拖动映射 ×0.6）", slowed)
	_tick_boss(boss, 1)
	_gl.player.global_position = Vector2(40.0, 40.0)   # 拉离（防后续用例站圈吃伤害）
	_release_boss(boss)


func _test_laser_sweep() -> void:
	print("── 湮灭扫线 ──")
	var def := {"type": "laser_sweep", "phase": 1, "cd": 11.0, "telegraph": "line",
		"telegraph_s": 0.4, "arc_deg": 60.0, "sweep_s": 1.0, "width_px": 26.0,
		"dmg": 30.0, "flavor": "vine"}
	var boss := _spawn_boss_with_def(def)
	_tick_boss(boss, 6)                            # 进入前摇（紫线锁定）
	_check("B7：前摇期直线警示带可见",
		boss.get("_cast_line") != null and bool(boss.get("_cast_line").visible))
	_tick_boss(boss, 60)                           # 前摇毕 → 扫线落场
	var sweeps: Array[Node] = []
	for c in boss.get_parent().get_children():
		if str(c.name).begins_with("BossSweep"):
			sweeps.append(c)
	_check("B7：扫线束落场（世界层锚定 Boss 位置）", sweeps.size() == 1)
	if sweeps.is_empty():
		_release_boss(boss)
		return
	var sweep: Node = sweeps[0]
	_check("B7：起角 = 前摇锁定方向（不追踪）",
		absf(float(sweep.get("base_angle")) - float(boss.get("_cast_dir").angle())) < 0.01)
	# 玩家站进束路径 → 0.6s 一跳结算（沿锁定起角摆位——起角锁定后不追踪是正确行为）
	_gl.player.invuln_left = 0.0
	var hp0: float = _gl.player.hp
	_gl.player.global_position = (sweep as Node2D).global_position \
		+ Vector2.from_angle(float(sweep.get("base_angle"))) * 300.0
	for i in range(140):
		sweep.call("_process", DT)
	var dropped := hp0 - _gl.player.hp
	_check("B7：束内结算 30（50% 处决档）", absf(dropped - 30.0) < 0.01,
		"实扣 %.1f" % dropped)
	_release_boss(boss)


func _test_player_hazard_slow() -> void:
	print("── 玩家减速通道 ──")
	_gl.player.hazard_slow_mult = 1.0
	_gl.player.hazard_slow_left = 0.0
	_gl.player.apply_hazard_slow(0.6, 1.0)
	_check("apply_hazard_slow：系数与持续时间写入",
		absf(float(_gl.player.get("hazard_slow_mult")) - 0.6) < 0.001
		and float(_gl.player.get("hazard_slow_left")) > 0.9)
	_gl.player.tick(2.0, Vector2.ZERO)             # 推进超时长 → 到期还原
	_check("减速到期自动还原 1.0", absf(float(_gl.player.get("hazard_slow_mult")) - 1.0) < 0.001)


func _release_boss(p_boss: Enemy) -> void:
	(_gl.pools[&"enemy"] as EnemyPool).release(p_boss)


func _tick_boss(p_boss: Enemy, p_frames: int) -> void:
	for i in range(p_frames):
		p_boss.tick(DT)

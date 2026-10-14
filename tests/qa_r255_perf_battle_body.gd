# tests/qa_r255_perf_battle_body.gd
# R255 战斗帧预算分布用例体（入口 qa_r255_perf_battle.gd 运行时加载——autoload 全局名
# 此时可用，同 perf_500p100e_cases.gd 口径）。口径：headless 手动驱动 _physics_process
# (DT=1/120)，纯逻辑帧时间；补给动作在计时区间外。
extends RefCounted

const DT := 1.0 / 120.0
const ORBIT_RADIUS := 260.0
const ORBIT_SPEED := 1.1
const MAIN_SCENE := "res://scenes/main.tscn"
const TARGET_PROJ := 500
const TARGET_EBULLETS := 300
const TARGET_ENEMIES := 100
const TARGET_POPUPS := 40
const TARGET_PARTICLES := 60
const WARMUP_FRAMES := 300
const MEASURE_FRAMES := 3600                  # 30s @ 120Hz
const SUPPLY_PROJ_PER_FRAME := 16
const SUPPLY_EB_PER_FRAME := 16
const SUPPLY_ENEMY_PER_FRAME := 8
const SUPPLY_POPUP_PER_FRAME := 4
const PROJ_SPEED := 320.0
const EBULLET_SPEED := 240.0                  # Boss 弹速口径（PROGRESS 弹速 240）
const GRUNT_ID := &"E1_grunt"
const RUNNER_ID := &"E2_runner"
const NEW_MIX: Array[StringName] = [
	&"E25_phase_bomber", &"E26_shield_lancer", &"E27_warden_orb",
	&"E28_hexcaster", &"E29_longbowhawk", &"E30_hellfire_revenant",
]

var tree: SceneTree
var _gl: GameLoop = null
var _frame_us: PackedFloat64Array = PackedFloat64Array()
var _rng := RandomNumberGenerator.new()
var _popup_uid: int = 1
var _fails: int = 0
var _stage_sum: Dictionary = {}               # 全帧各阶段耗时和（ms）
var _stage_max: Dictionary = {}               # 各阶段峰值（ms）
var _worst: Array = []                        # [{idx,us,stage:{...}}] 最差 8 帧
var _wave_frames: Array = []                  # 波次切换帧（current_wave 变化帧）
var _last_wave: int = -1
var _eb_live: int = 0


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_rng.seed = 42
	await _boot()
	_start_run()
	_prime_load()
	_measure()
	_report()
	_teardown()


func fail_count() -> int:
	return _fails


func _boot() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	tree.get_root().add_child(_gl)
	var waited := 0
	while not _gl.boot_ready and waited < 600:
		await tree.process_frame
		waited += 1
	if not (_gl.boot_ready and _gl.state == GameConst.GameStatus.MENU):
		push_error("[probe] Boot 失败：%s" % str(_gl.boot_fatal))
		_fails += 1


func _start_run() -> void:
	# 直调 start_run（绕开 R252 祝福面板拦截——emit start_requested 会停在 MENU）
	var t0 := Time.get_ticks_usec()
	var ok: bool = _gl.start_run()
	var us := Time.get_ticks_usec() - t0
	_gl.stage_probe_enabled = true
	print("[probe] start_run() = %s，全程 %.2f ms（含 PopupGlyphAtlas 补烤等一次性成本；菜单停留不足口径）" % [
		str(ok), float(us) / 1000.0])
	if not ok:
		_fails += 1


func _prime_load() -> void:
	_enqueue_enemies(TARGET_ENEMIES)
	for i in range(16):
		_gl._physics_process(DT)
	_maintain_load()
	for i in range(4):
		_gl._physics_process(DT)
	_maintain_load()
	print("[probe] 预铺完成：敌 %d / 玩家弹 %d / 敌弹 %d / 跳字 %d / 粒子 live %d" % [
		_gl.spawner.active_count(), _proj_active(0), _proj_active(1),
		_gl.popup_manager.active_popups, _pool_live(&"particle")])


func _maintain_load() -> void:
	var proj_pool := _gl.pools[&"projectile"] as ProjectilePool
	# 玩家弹（team 0）
	var deficit := TARGET_PROJ - _proj_active(0)
	for i in range(mini(deficit, SUPPLY_PROJ_PER_FRAME)):
		var proj := proj_pool.acquire(0)
		if proj == null:
			break
		var dir := Vector2.RIGHT.rotated(_rng.randf() * TAU)
		proj.spawn({
			"velocity": dir * PROJ_SPEED,
			"lifetime": 8.0,
			"pierce": 1,
			"team": 0,
			"position": Vector2(_rng.randf_range(40.0, 680.0), _rng.randf_range(40.0, 1240.0)),
			"panel_snapshot": {
				"base_atk": 100.0, "crit_rate": 0.05, "crit_mult": 1.5,
				"flat_bonus": 0.0, "add_entries": [],
			},
		})
	# 敌弹（team 1，Boss 弹幕口径——仿 enemy.gd:1845 _spawn_boss_bullet）
	var eb_deficit := TARGET_EBULLETS - _proj_active(1)
	for i in range(mini(eb_deficit, SUPPLY_EB_PER_FRAME)):
		var bullet := proj_pool.acquire(1)
		if bullet == null:
			break
		bullet.pool = proj_pool
		bullet.position = Vector2(_rng.randf_range(60.0, 660.0), _rng.randf_range(60.0, 660.0))
		bullet.spawn({
			"velocity": Vector2.RIGHT.rotated(_rng.randf() * TAU) * EBULLET_SPEED,
			"lifetime": 6.0,
			"pierce": 1,
			"bounces": 0,
			"hitbox_radius": 5.0,
			"team": 1,
			"panel_snapshot": {"base_atk": 8.0},
		})
	# 敌
	var enemy_deficit := TARGET_ENEMIES - _gl.spawner.active_count()
	if enemy_deficit > 0:
		_enqueue_enemies(mini(enemy_deficit, SUPPLY_ENEMY_PER_FRAME))
	# 跳字
	var popup_supply := 0
	while _gl.popup_manager.active_popups < TARGET_POPUPS \
			and popup_supply < SUPPLY_POPUP_PER_FRAME:
		var fake := DamageResult.new()
		fake.target_uid = 900000 + _popup_uid
		fake.final_value = 25.0
		fake.pos = Vector2(_rng.randf_range(60.0, 660.0), _rng.randf_range(60.0, 1220.0))
		_gl.popup_manager.on_damage_resolved(fake)
		_popup_uid += 1
		popup_supply += 1
	# 粒子
	if _pool_live(&"particle") < TARGET_PARTICLES:
		(_gl.game_feel.particles).burst(&"fx_kill",
			Vector2(_rng.randf_range(60.0, 660.0), _rng.randf_range(60.0, 1220.0)), 2)


func _enqueue_enemies(p_count: int) -> void:
	for i in range(p_count):
		var id: StringName = GRUNT_ID
		var r := _rng.randf()
		if r > 0.8:
			id = RUNNER_ID
		elif r > 0.6:
			id = NEW_MIX[_rng.randi_range(0, NEW_MIX.size() - 1)]
		_gl.spawner.enqueue({"data_id": id, "wave": maxi(_gl.wave_director.current_wave, 1)})


func _auto_play() -> void:
	var ang := float(GameConfig.frame_stamp) * DT * ORBIT_SPEED
	var center := Vector2(360.0, 640.0)
	var next_pos := center + Vector2(cos(ang), sin(ang)) * ORBIT_RADIUS
	if _gl.player != null and is_instance_valid(_gl.player):
		_gl.player._drag_accum = (next_pos - _gl.player.global_position) / DT
		_gl.player.invuln_left = 1.0
		if GameConfig.frame_stamp % 600 == 0:
			_gl.player.hp = _gl.player.max_hp
	if _gl.state == GameConst.GameStatus.LEVEL_UP and _gl.card_select_ui.is_open:
		_gl.card_select_ui.choose(0)
	elif _gl.state == GameConst.GameStatus.GAME_OVER:
		_gl.restart_run()


func _measure() -> void:
	for i in range(WARMUP_FRAMES):
		_auto_play()
		_maintain_load()
		_gl._physics_process(DT)
	_frame_us.clear()
	_frame_us.resize(MEASURE_FRAMES)
	_last_wave = _gl.wave_director.current_wave
	for i in range(MEASURE_FRAMES):
		_auto_play()
		_maintain_load()
		var t0 := Time.get_ticks_usec()
		_gl._physics_process(DT)
		_frame_us[i] = float(Time.get_ticks_usec() - t0) / 1000.0
		for k in _gl.stage_probe_us:
			_stage_sum[k] = float(_stage_sum.get(k, 0.0)) + float(_gl.stage_probe_us[k]) / 1000.0
			_stage_max[k] = maxf(float(_stage_max.get(k, 0.0)), float(_gl.stage_probe_us[k]) / 1000.0)
		if _gl.wave_director.current_wave != _last_wave:
			_wave_frames.append({
				"from": _last_wave, "to": _gl.wave_director.current_wave,
				"idx": i, "frame_ms": _frame_us[i],
				"wave_stage_ms": float(_gl.stage_probe_us.get(&"wave", 0)) / 1000.0,
				"stage": _copy_stage(),
			})
			_last_wave = _gl.wave_director.current_wave
		_worst.append({"idx": i, "frame_ms": _frame_us[i], "stage": _copy_stage()})
		_worst.sort_custom(func(a, b): return a["frame_ms"] > b["frame_ms"])
		if _worst.size() > 8:
			_worst.resize(8)
		if (i + 1) % 1200 == 0:
			print("[probe] %5d/%d 帧 | 近段帧均 %.3f ms | 玩家弹 %d 敌弹 %d 敌 %d" % [
				i + 1, MEASURE_FRAMES, _recent_avg(i, 1200), _proj_active(0),
				_proj_active(1), _gl.spawner.active_count()])


func _copy_stage() -> Dictionary:
	var out := {}
	for k in _gl.stage_probe_us:
		out[String(k)] = int(_gl.stage_probe_us[k])
	return out


func _recent_avg(p_end_idx: int, p_n: int) -> float:
	var start := maxi(p_end_idx - p_n + 1, 0)
	var sum := 0.0
	for i in range(start, p_end_idx + 1):
		sum += _frame_us[i]
	return sum / float(p_end_idx - start + 1)


func _report() -> void:
	var sorted := _frame_us.duplicate()
	sorted.sort()
	var p50 := _pct(sorted, 0.50)
	var p95 := _pct(sorted, 0.95)
	var p99 := _pct(sorted, 0.99)
	var pmax := sorted[sorted.size() - 1]
	var avg := 0.0
	for v in _frame_us:
		avg += v
	avg /= float(_frame_us.size())
	print("── [probe] 帧时间统计（逻辑侧 %d 帧 @DT=1/120） ──" % _frame_us.size())
	print("[probe] avg=%.3f P50=%.3f P95=%.3f P99=%.3f MAX=%.3f (ms)" % [avg, p50, p95, p99, pmax])
	print("[probe] 全帧各阶段均值（ms/帧）：%s" % _fmt(_stage_sum, float(MEASURE_FRAMES)))
	print("[probe] 各阶段峰值（ms）：%s" % _fmt(_stage_max, 1.0))
	for w in _wave_frames:
		print("[probe] 波次切换 w%s→w%s @帧%d：全帧 %.3f ms｜wave 段 %.3f ms｜敌 %d｜段=%s" % [
			str(w["from"]), str(w["to"]), int(w["idx"]), float(w["frame_ms"]),
			float(w["wave_stage_ms"]), _gl.spawner.active_count(), str(w["stage"])])
	if _wave_frames.is_empty():
		print("[probe] 波次切换：测量窗内无自然波次推进")
	for entry in _worst:
		print("[probe] 最差帧 @%d：%.3f ms｜段=%s" % [int(entry["idx"]), float(entry["frame_ms"]), str(entry["stage"])])
	_eb_live = _proj_active(1)
	print("[probe] 终态负载：玩家弹 %d / 敌弹 %d / 敌 %d / 跳字 %d" % [
		_proj_active(0), _eb_live, _gl.spawner.active_count(), _gl.popup_manager.active_popups])
	if _gl.spawner.active_count() < 50 or _proj_active(0) < 300:
		print("PROBE-WARN | 负载未达目标（敌<50 或 玩家弹<300）——读数降档披露")
		_fails += 1


func _fmt(p_dict: Dictionary, p_div: float) -> String:
	var parts: Array[String] = []
	for k in p_dict:
		parts.append("%s=%.3f" % [String(k), float(p_dict[k]) / p_div])
	parts.sort()
	return "{" + ", ".join(parts) + "}"


func _pct(p_sorted: PackedFloat64Array, p_q: float) -> float:
	var idx := int(floor(p_q * float(p_sorted.size() - 1)))
	return p_sorted[clampi(idx, 0, p_sorted.size() - 1)]


func _proj_active(p_team: int) -> int:
	var n := 0
	for proj in (_gl.pools[&"projectile"] as ProjectilePool).active_projectiles():
		if proj != null and proj.team == p_team:
			n += 1
	return n


func _pool_live(p_id: StringName) -> int:
	return int((_gl.pools[p_id] as ObjectPool).stats()["live"])


func _teardown() -> void:
	tree.paused = false
	if _gl != null:
		_gl.free()
		_gl = null

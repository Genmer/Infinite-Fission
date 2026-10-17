# tests/qa_r289_indep_weapon_cases.gd
# R289 独立 QA 探针武器面。契约来源（用户任务/设计背景）：
#   b) A 隔帧节流守恒（真实武器 W2_gatling / W1_pistol，非 stub）：深载 120 物理步
#      执行步恰 60、武跳恰 60；开火/玩家弹总数与关态 ±10%；执行步 dt×2 模拟时间=关态。
#   c) 逐武器键记账：_stage_win_wpn_us 非全 0、族桶（W1→0/W2→1）>0、桶和 ≤ 火段总µs；
#      1Hz 行 武1..武9/副武/深/武跳/弹拒 在位且位于 派段µs 之后。
#   f) 关态正对照：deep 关（含 boost 关+deep_override=1）Player.tick 每步调武器、
#      武跳计数不增长。
# 夹具：main.tscn 真链 boot；清空槽后装 W2/W1 真件；E1_grunt 复制为 1e12 HP 固定靶；
# 全部 Player.tick / _physics_process 直驱（引擎自动 process 已关闭）。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const DT := 1.0 / 60.0

var tree: SceneTree
var _gl: Node = null
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _saved_settings: Dictionary = {}
var _saved_first_met: Dictionary = {}
var _saved_codex_weapons: Dictionary = {}
var _w2: WeaponBase = null
var _w1: WeaponBase = null
var _target: Enemy = null


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


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(289)
	_saved_settings = Meta._settings.duplicate()
	_saved_first_met = Meta.codex_first_met.duplicate()
	_saved_codex_weapons = Meta.codex_weapons.duplicate()
	await _boot()
	PerfGovernor.set_process(false)
	PerfGovernor.mode_override = -1
	PerfGovernor.tier_override = 3
	PerfGovernor.boost_override = 1
	PerfGovernor.deep_override = -1
	PerfGovernor.set_deep_active(false)
	Meta.set_setting("fx_quality", 2)
	Meta.set_setting("boost_res", 85)
	Meta.set_setting("perf_boost", 1)
	_gl.state = GameConst.GameStatus.PLAYING
	tree.paused = false
	_gl.player.set("_dead", false)
	_gl.player.set("max_hp", 1.0e12)
	_gl.player.set("hp", 1.0e12)
	_gl.player.set("xp_need", 1.0e12)
	_gl.player.unlocked_slots = 6
	_gl.player.global_position = Vector2(360.0, 980.0)
	_setup_weapons()
	_setup_target()
	_b_conservation()
	await _c_key_accounting()
	await _cleanup()


func _boot() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate()
	_gl.name = "R289IndepWeapon"
	tree.root.add_child(_gl)
	await tree.process_frame
	await tree.process_frame
	if not bool(_gl.get("boot_ready")):
		_check("boot 成功（main.tscn 真链）", false, str(_gl.get("boot_fatal")))
	else:
		_check("boot 成功（main.tscn 真链）", true, "")
	_gl.set_physics_process(false)
	_gl.set_process(false)


func _setup_weapons() -> void:
	var slots: Array = _gl.player.weapon_slots
	for i in range(slots.size()):
		var old: Variant = slots[i]
		slots[i] = null
		if old != null and is_instance_valid(old):
			(old as Node).queue_free()
	_w2 = _gl.player.add_weapon(_gl.registry.get_weapon(&"W2_gatling"))
	_w1 = _gl.player.add_weapon(_gl.registry.get_weapon(&"W1_pistol"))
	_check("夹具：真实 W2_gatling 装入", _w2 != null and _w2.data != null \
		and String(_w2.data.id) == "W2_gatling", str(_w2))
	_check("夹具：真实 W1_pistol 装入", _w1 != null and _w1.data != null \
		and String(_w1.data.id) == "W1_pistol", str(_w1))


func _setup_target() -> void:
	var epool: EnemyPool = _gl.pools[&"enemy"]
	_target = epool.acquire()
	if _target == null:
		_check("夹具：固定靶敌生成", false, "enemy pool acquire=null")
		return
	var src: EnemyData = _gl.registry.get_enemy(&"E1_grunt")
	var ed: EnemyData = src.duplicate() as EnemyData
	ed.hp_base = 1.0e12
	_target.bucket_host = epool.bucket_host
	_target.spawn(ed, 1, 0)
	_target.global_position = Vector2(360.0, 620.0)
	_target.dead = false
	_gl.spawner.active.append(_target)
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	_check("夹具：靶敌在网格内（W1/W2 可索敌）", _gl.enemy_grid.query_nearest(
		_gl.player.global_position, 1600.0, null) == _target, "")


func _set_active(p_weapons: Array) -> void:
	var slots: Array = _gl.player.weapon_slots
	for i in range(slots.size()):
		slots[i] = null
	for i in range(p_weapons.size()):
		if i < slots.size():
			slots[i] = p_weapons[i]


func _reset_weapon(p_w: WeaponBase, p_level: int) -> void:
	if p_w == null:
		return
	var deps: Dictionary = _gl.player.get("_deps")
	p_w.setup(p_w.data, _gl.player, deps)
	p_w.level = p_level
	p_w.cooldown_left = 0.0
	p_w._tick_seq = 0
	p_w._acq_cache_seq = -1
	p_w._acq_cache_target = null
	if p_w is BallisticWeapon:
		var bw := p_w as BallisticWeapon
		bw.spin_up_left = bw._spin_up_time()
		bw.rof_current = 0.0
		bw._since_fire = 999.0


func _clear_projectiles() -> void:
	var pool: ProjectilePool = _gl._projectile_pool
	var live: Array = pool.active_projectiles().duplicate()
	for p in live:
		if p != null and is_instance_valid(p):
			pool.release(p)


func _measure(p_w: WeaponBase, p_deep: bool, p_boost: bool, p_steps: int,
		p_level: int) -> Dictionary:
	_set_active([p_w])
	_reset_weapon(p_w, p_level)
	_clear_projectiles()
	PerfGovernor.boost_override = 1 if p_boost else 0
	PerfGovernor.deep_override = 1 if p_deep else 0
	_gl.player._wpn_lod_phase = 0
	var pool: ProjectilePool = _gl._projectile_pool
	var skip0 := int(DebugStats.get_counter(&"weapon_lod_skip"))
	var seq0 := int(p_w._tick_seq)
	var active0 := pool.total_active()
	for _i in range(p_steps):
		_gl.player.tick(DT, Vector2.ZERO)
	return {
		"bullets": pool.total_active() - active0,
		"exec": int(p_w._tick_seq) - seq0,
		"skip": int(DebugStats.get_counter(&"weapon_lod_skip")) - skip0,
		"phase": int(_gl.player._wpn_lod_phase),
	}


func _trace_fire(p_w: WeaponBase, p_deep: bool, p_steps: int, p_level: int,
		p_tag: String) -> void:
	_set_active([p_w])
	_reset_weapon(p_w, p_level)
	_clear_projectiles()
	PerfGovernor.boost_override = 1
	PerfGovernor.deep_override = 1 if p_deep else 0
	_gl.player._wpn_lod_phase = 0
	var pool: ProjectilePool = _gl._projectile_pool
	var steps: Array[int] = []
	var cds: Array[float] = []
	var spins: Array[float] = []
	for i in range(p_steps):
		var before := pool.total_active()
		_gl.player.tick(DT, Vector2.ZERO)
		if pool.total_active() > before:
			steps.append(i + 1)
			cds.append(float(p_w.cooldown_left))
			if p_w is BallisticWeapon:
				spins.append(float((p_w as BallisticWeapon).spin_up_left))
	var gaps: Array[int] = []
	for i in range(1, steps.size()):
		gaps.append(steps[i] - steps[i - 1])
	print("  TRACE %s shots=%d steps=%s gaps=%s" % [p_tag, steps.size(),
		str(steps.slice(0, mini(30, steps.size()))), str(gaps.slice(0, mini(29, gaps.size())))])
	if not cds.is_empty():
		print("  TRACE %s cd_first=%s spin_first=%s" % [p_tag,
			str(cds.slice(0, mini(8, cds.size()))),
			str(spins.slice(0, mini(8, spins.size())))])
	_clear_projectiles()


func _ratio(p_a: int, p_b: int) -> float:
	return float(p_a) / maxf(float(p_b), 1.0)


func _b_conservation() -> void:
	print("── b A 真武器节流守恒（W2 120 步 ×2 轮 / W1 300 步补测） ──")
	var off1 := _measure(_w2, false, true, 120, 3)
	var deep1 := _measure(_w2, true, true, 120, 3)
	_check("b1 W2 关态 120 步 → 武器执行 120 次、武跳 0",
		int(off1.exec) == 120 and int(off1.skip) == 0,
		"exec=%d skip=%d" % [int(off1.exec), int(off1.skip)])
	_check("b2 W2 深载 120 步 → 武器执行恰 60 次、武跳恰 60",
		int(deep1.exec) == 60 and int(deep1.skip) == 60,
		"exec=%d skip=%d" % [int(deep1.exec), int(deep1.skip)])
	_check("b3 W2 模拟时间守恒（深载 60×2δ == 关态 120×δ）",
		absf(float(deep1.exec) * 2.0 * DT - float(off1.exec) * DT) < 1.0e-9,
		"deep=%.6f off=%.6f" % [float(deep1.exec) * 2.0 * DT, float(off1.exec) * DT])
	var r1 := _ratio(int(deep1.bullets), int(off1.bullets))
	_check("b4 W2 深载玩家弹数 ≈ 关态（±10%）",
		r1 >= 0.90 and r1 <= 1.10,
		"deep=%d off=%d ratio=%.4f" % [int(deep1.bullets), int(off1.bullets), r1])

	# 证据追踪：逐物理步记录开火步号/冷却余量/预热余量（区分「时间量化」与「射速错误」）
	_trace_fire(_w2, false, 120, 3, "W2-off")
	_trace_fire(_w2, true, 120, 3, "W2-deep")
	_trace_fire(_w1, false, 300, 1, "W1-off")
	_trace_fire(_w1, true, 300, 1, "W1-deep")

	var off2 := _measure(_w2, false, true, 120, 3)
	var deep2 := _measure(_w2, true, true, 120, 3)
	var r2 := _ratio(int(deep2.bullets), int(off2.bullets))
	_check("b5 W2 第二轮复现（exec/skip 与弹数比）",
		int(deep2.exec) == 60 and int(deep2.skip) == 60 and r2 >= 0.90 and r2 <= 1.10,
		"deep=%d off=%d ratio=%.4f exec=%d skip=%d"
			% [int(deep2.bullets), int(off2.bullets), r2, int(deep2.exec), int(deep2.skip)])

	var offw1 := _measure(_w1, false, true, 300, 1)
	var deepw1 := _measure(_w1, true, true, 300, 1)
	var rw1 := _ratio(int(deepw1.bullets), int(offw1.bullets))
	_check("b6 W1 补测 300 步 → 执行 150/武跳 150",
		int(deepw1.exec) == 150 and int(deepw1.skip) == 150,
		"exec=%d skip=%d" % [int(deepw1.exec), int(deepw1.skip)])
	_check("b7 W1 深载弹数 ≈ 关态（±10%，300 步窗口）",
		rw1 >= 0.90 and rw1 <= 1.10,
		"deep=%d off=%d ratio=%.4f" % [int(deepw1.bullets), int(offw1.bullets), rw1])

	# f) 关态正对照：boost 关 + deep_override=1（deep_load 恒 false）
	var boff := _measure(_w2, true, false, 120, 3)
	_check("f1 boost 关 + deep_override=1 → deep_load false", not PerfGovernor.deep_load(), "")
	_check("f2 boost 关闭态 120 步 → 每步执行（exec=120、武跳=0）",
		int(boff.exec) == 120 and int(boff.skip) == 0,
		"exec=%d skip=%d" % [int(boff.exec), int(boff.skip)])
	_check("f3 boost 关闭态相位不推进（_wpn_lod_phase=0）", int(boff.phase) == 0,
		"phase=%d" % int(boff.phase))
	var boff_r := _ratio(int(boff.bullets), int(off1.bullets))
	_check("f4 boost 关闭态弹数与开态关态一致（±10%）",
		boff_r >= 0.90 and boff_r <= 1.10,
		"boost_off=%d off=%d ratio=%.4f" % [int(boff.bullets), int(off1.bullets), boff_r])
	PerfGovernor.boost_override = 1
	PerfGovernor.deep_override = -1
	PerfGovernor.set_deep_active(false)


func _c_key_accounting() -> void:
	print("── c 逐武器族键记账（W1→武1 / W2→武2；桶和 ≤ 火段总µs；1Hz 行键序） ──")
	_set_active([_w2, _w1])
	_reset_weapon(_w2, 3)
	_reset_weapon(_w1, 1)
	_clear_projectiles()
	PerfGovernor.boost_override = 1
	PerfGovernor.deep_override = 1
	PerfGovernor.set_deep_active(false)
	_gl.player._wpn_lod_phase = 0
	_gl.stage_probe_enabled = true
	_gl.diag_reset_stage_win_sums()
	Player.reset_stage_probe()

	# 直驱真 GameLoop 物理步（引擎自动 process 已关闭）；帧头火段总µs手工同步累计
	var total_wpn_us := 0
	for _i in range(30):
		total_wpn_us += Player.probe_weapons_us
		_gl._physics_process(DT)
	total_wpn_us += Player.probe_weapons_us
	# 尾帧补记（与 GameLoop 下一帧头同一行径，使 30 步全部入账）
	for i in range(10):
		_gl._stage_win_wpn_us[i] += Player.probe_wpn_us[i]

	var buckets: Array[int] = []
	var bucket_sum := 0
	for i in range(10):
		var v := int(_gl._stage_win_wpn_us[i])
		buckets.append(v)
		bucket_sum += v
	_check("c1 深载键窗非全 0（30 物理步）", bucket_sum > 0,
		"buckets=%s" % str(buckets))
	_check("c2 W1 真件落 武1 桶（index 0 > 0）", buckets[0] > 0,
		"武1=%d" % buckets[0])
	_check("c3 W2 真件落 武2 桶（index 1 > 0）", buckets[1] > 0,
		"武2=%d" % buckets[1])
	_check("c4 十桶和 ≤ 火段总µs（副本桶9为火段子集/重叠口径已注明）",
		bucket_sum <= total_wpn_us,
		"桶和=%d 火段总=%d 桶9=%d" % [bucket_sum, total_wpn_us, buckets[9]])
	_check("c5 驱动期 deep_load 恒 true", PerfGovernor.deep_load(), "")

	# 1Hz 行：键在位 + 位序
	var line := DebugStats._diag_format_line(_gl, Time.get_ticks_msec())
	var all_keys := true
	for k in ["武1µs", "武2µs", "武3µs", "武4µs", "武5µs", "武6µs", "武7µs",
			"武8µs", "武9µs", "副武µs", "深1 ", "武跳", "弹拒"]:
		if not line.contains(k):
			all_keys = false
	_check("c6 1Hz 行十三键在位（武1..武9/副武/深/武跳/弹拒）", all_keys, line.right(220))
	var i_pai := line.find("派段µs")
	var i_w1 := line.find("武1µs")
	var i_w2 := line.find("武2µs")
	var i_w9 := line.find("武9µs")
	var i_fu := line.find("副武µs")
	var i_deep := line.find("深1 ")
	var i_skip := line.find("武跳")
	var i_cap := line.find("弹拒")
	var order_ok := i_pai >= 0 and i_w1 > i_pai and i_w2 > i_w1 and i_w9 > i_w2 \
		and i_fu > i_w9 and i_deep > i_fu and i_skip > i_deep and i_cap > i_skip
	_check("c7 键位序：派段µs < 武1 < 武2 < 武9 < 副武 < 深 < 武跳 < 弹拒", order_ok,
		"派=%d 武1=%d 武2=%d 武9=%d 副=%d 深=%d 跳=%d 拒=%d"
			% [i_pai, i_w1, i_w2, i_w9, i_fu, i_deep, i_skip, i_cap])

	# 行值映射（独立注入已知值——防「键在但取错桶」）
	_gl._stage_win_wpn_us.fill(0)
	_gl._stage_win_wpn_us[0] = 111
	_gl._stage_win_wpn_us[1] = 222
	_gl._stage_win_wpn_us[8] = 888
	_gl._stage_win_wpn_us[9] = 999
	var line_map := DebugStats._diag_format_line(_gl, Time.get_ticks_msec())
	_check("c8 行值映射：武1=111 武2=222 武9=888 副武=999",
		line_map.contains("武1µs111") and line_map.contains("武2µs222") 			and line_map.contains("武9µs888") and line_map.contains("副武µs999"),
		line_map.right(220))
	PerfGovernor.deep_override = 0
	var line_off := DebugStats._diag_format_line(_gl, Time.get_ticks_msec())
	_check("c9 deep 关 1Hz 行 深0", line_off.contains("深0 "), line_off.right(160))
	_gl.stage_probe_enabled = false
	_gl.diag_reset_stage_win_sums()


func _cleanup() -> void:
	print("── 收尾（弹/靶/设置/探针还原） ──")
	_clear_projectiles()
	if _target != null and is_instance_valid(_target):
		_gl.spawner.active.erase(_target)
		var epool: EnemyPool = _gl.pools[&"enemy"]
		epool.release(_target)
		_target = null
	PerfGovernor.boost_override = -1
	PerfGovernor.deep_override = -1
	PerfGovernor.mode_override = -1
	PerfGovernor.tier_override = -1
	PerfGovernor.set_deep_active(false)
	_gl.stage_probe_enabled = false
	_gl.state = GameConst.GameStatus.MENU
	Player.reset_stage_probe()
	tree.paused = false
	RunSave.clear()
	Meta.codex_first_met = _saved_first_met.duplicate()
	Meta.codex_weapons = _saved_codex_weapons.duplicate()
	Meta._settings = _saved_settings.duplicate()
	Meta._save()
	_gl.queue_free()
	await tree.process_frame
	print("验收汇总：%d/%d 通过" % [_pass, _pass + _fail])
	if _fail > 0:
		for f in _failures:
			print("  FAIL 项：%s" % f)

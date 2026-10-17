# tests/qa_r289_indep_r2_cases.gd
# R289 修轮第 2 轮独立复核探针（新增，不改动既有 24/54 计数探针）。
# 覆盖用户点名的复核项：
#   P1-1 真武器长窗守恒：W2 300 步 / W1 300 步 / W3 300 步；deep/off 发数比 0.95..1.10
#        （下界=修轮目标，上界=原 ±10% 守恒口径；只测下界会漏掉射速过冲）；
#       逐物理步弹数增量 ≤ 单次齐射量（W1/W2=1，W3=pellets），负余量结转不得产生
#       单拍多次开火/多轮齐射。
#   P1-2 状态迁移与 HUD：PLAYING→540×960/.75；LEVEL_UP/PAUSED→612×1088/.85；
#       回 PLAYING→540；真实 change_state 触发 HUD 自动 refresh_stats/fit；
#       540 视口内读数盒右沿 ≤ vw−130；85 档/boost 关坐标 368。
#   P2-3 W3 整轮预检：帽沿 headroom<pellets 不发射且 CD 不变；team1 活弹不计入
#       team0 headroom；放出容量后整轮 pellets 发。
# 夹具：main.tscn 真链 boot；清空槽装 W2/W1/W3 真件；E1_grunt 复制 1e12 HP 固定靶；
# 全部 Player.tick / change_state 直驱，引擎自动 process 关闭。结束恢复设置/画布/闩。
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
var _saved_css: Vector2i = Vector2i.ZERO
var _saved_win_size: Vector2i = Vector2i.ZERO
var _saved_zoom: Vector2 = Vector2.ONE
var _saved_notch: int = 0
var _saved_snotch: int = 0
var _w1: WeaponBase = null
var _w2: WeaponBase = null
var _w3: WeaponBase = null
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
	_saved_css = _gl.get_window().content_scale_size
	_saved_win_size = _gl.get_window().size
	_saved_zoom = _gl.camera.zoom if _gl.camera != null else Vector2.ONE
	_saved_notch = int(_gl._boost_applied_notch)
	_saved_snotch = GameLoop._s_boost_applied_notch
	_setup_weapons()
	_setup_target()
	_p1_1_long_window()
	_p2_3_volley_cap()
	_p1_2_state_hud()
	await _cleanup()


func _boot() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate()
	_gl.name = "R289IndepR2"
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
	_w3 = _gl.player.add_weapon(_gl.registry.get_weapon(&"W3_shotgun"))
	_check("夹具：真实 W2_gatling 装入", _w2 != null and _w2.data != null \
		and String(_w2.data.id) == "W2_gatling", str(_w2))
	_check("夹具：真实 W1_pistol 装入", _w1 != null and _w1.data != null \
		and String(_w1.data.id) == "W1_pistol", str(_w1))
	_check("夹具：真实 W3_shotgun 装入", _w3 != null and _w3.data != null \
		and String(_w3.data.id) == "W3_shotgun", str(_w3))


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
	_check("夹具：靶敌在网格内（三武器可索敌）", _gl.enemy_grid.query_nearest(
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
		bw._quota_pending = 0
		bw._quota_def_a = 0
		bw._quota_def_b = 0


func _clear_projectiles() -> void:
	var pool: ProjectilePool = _gl._projectile_pool
	var live: Array = pool.active_projectiles().duplicate()
	for p in live:
		if p != null and is_instance_valid(p):
			pool.release(p)


func _measure_trace(p_w: WeaponBase, p_deep: bool, p_steps: int,
		p_level: int) -> Dictionary:
	# 逐物理步记录玩家弹增量。返回 bullets/fire_ticks/max_delta 等；deep 执行拍 dt×2
	# 由真实 Player.tick 驱动，不做时间换算。
	_set_active([p_w])
	_reset_weapon(p_w, p_level)
	_clear_projectiles()
	PerfGovernor.boost_override = 1
	PerfGovernor.deep_override = 1 if p_deep else 0
	_gl.player._wpn_lod_phase = 0
	var pool: ProjectilePool = _gl._projectile_pool
	var skip0 := int(DebugStats.get_counter(&"weapon_lod_skip"))
	var seq0 := int(p_w._tick_seq)
	var max_delta := 0
	var fire_ticks := 0
	var bullets := 0
	var negative_fire_ticks := 0
	var min_cd := 0.0
	var steps: Array[int] = []
	for i in range(p_steps):
		var before := int(pool.total_active())
		var cd_before := float(p_w.cooldown_left)
		_gl.player.tick(DT, Vector2.ZERO)
		var d := int(pool.total_active()) - before
		min_cd = minf(min_cd, float(p_w.cooldown_left))
		if d > 0:
			fire_ticks += 1
			bullets += d
			max_delta = maxi(max_delta, d)
			steps.append(i + 1)
			if cd_before < 0.0:
				negative_fire_ticks += 1
	print("  TRACE | deep=%s steps=%d exec=%d skip=%d fire_ticks=%d bullets=%d "
		% [str(p_deep), p_steps, int(p_w._tick_seq) - seq0,
			int(DebugStats.get_counter(&"weapon_lod_skip")) - skip0,
			fire_ticks, bullets]
		+ "max_delta=%d neg_cd_fire=%d first=%s" % [max_delta, negative_fire_ticks,
			str(steps.slice(0, mini(12, steps.size())))])
	return {
		"exec": int(p_w._tick_seq) - seq0,
		"skip": int(DebugStats.get_counter(&"weapon_lod_skip")) - skip0,
		"bullets": bullets,
		"fire_ticks": fire_ticks,
		"max_delta": max_delta,
		"negative_fire_ticks": negative_fire_ticks,
		"min_cd": min_cd,
		"steps": steps,
	}


func _ratio(p_a: int, p_b: int) -> float:
	return float(p_a) / maxf(float(p_b), 1.0)


func _p1_1_long_window() -> void:
	print("── r2-P1-1 真武器长窗守恒（W2/W1/W3 各 300 物理步，deep vs off） ──")
	# W2 长窗 300 步（用户点名）
	var w2_off := _measure_trace(_w2, false, 300, 3)
	var w2_deep := _measure_trace(_w2, true, 300, 3)
	_check("r2-b1 W2 300 步深载 exec=150 / skip=150",
		int(w2_deep["exec"]) == 150 and int(w2_deep["skip"]) == 150,
		"exec=%d skip=%d" % [int(w2_deep["exec"]), int(w2_deep["skip"])])
	var r2 := _ratio(int(w2_deep["bullets"]), int(w2_off["bullets"]))
	_check("r2-b2 W2 长窗 deep/off 发数比 0.95..1.10（守恒）", r2 >= 0.95 and r2 <= 1.10,
		"deep=%d off=%d ratio=%.4f" % [int(w2_deep["bullets"]), int(w2_off["bullets"]), r2])
	_check("r2-b3 W2 深载逐拍最多 1 发（负余量无单拍爆发）",
		int(w2_deep["max_delta"]) <= 1 and int(w2_deep["bullets"]) == int(w2_deep["fire_ticks"]),
		"max_delta=%d bullets=%d fire_ticks=%d" % [int(w2_deep["max_delta"]),
			int(w2_deep["bullets"]), int(w2_deep["fire_ticks"])])

	# W1 长窗 300 步
	var w1_off := _measure_trace(_w1, false, 300, 1)
	var w1_deep := _measure_trace(_w1, true, 300, 1)
	_check("r2-b4 W1 300 步深载 exec=150 / skip=150",
		int(w1_deep["exec"]) == 150 and int(w1_deep["skip"]) == 150,
		"exec=%d skip=%d" % [int(w1_deep["exec"]), int(w1_deep["skip"])])
	var r1 := _ratio(int(w1_deep["bullets"]), int(w1_off["bullets"]))
	_check("r2-b5 W1 长窗 deep/off 发数比 0.95..1.10（守恒）", r1 >= 0.95 and r1 <= 1.10,
		"deep=%d off=%d ratio=%.4f" % [int(w1_deep["bullets"]), int(w1_off["bullets"]), r1])
	_check("r2-b6 W1 深载逐拍最多 1 发（负余量无单拍爆发）",
		int(w1_deep["max_delta"]) <= 1 and int(w1_deep["bullets"]) == int(w1_deep["fire_ticks"]),
		"max_delta=%d bullets=%d fire_ticks=%d" % [int(w1_deep["max_delta"]),
			int(w1_deep["bullets"]), int(w1_deep["fire_ticks"])])

	# W3 多丸武器长窗：每拍要么 0 丸要么整轮 pellets，绝不多轮/多拍叠加
	_reset_weapon(_w3, 1)
	var pellets := int(_w3.call(&"_volley_pellet_count"))
	_check("r2-b7 W3 L1 整轮丸数≥2（前置）", pellets >= 2, "pellets=%d" % pellets)
	var w3_off := _measure_trace(_w3, false, 300, 1)
	var w3_deep := _measure_trace(_w3, true, 300, 1)
	_check("r2-b8 W3 300 步深载 exec=150 / skip=150",
		int(w3_deep["exec"]) == 150 and int(w3_deep["skip"]) == 150,
		"exec=%d skip=%d" % [int(w3_deep["exec"]), int(w3_deep["skip"])])
	var r3 := _ratio(int(w3_deep["bullets"]), int(w3_off["bullets"]))
	_check("r2-b9 W3 长窗 deep/off 发数比 0.95..1.10（守恒）", r3 >= 0.95 and r3 <= 1.10,
		"deep=%d off=%d ratio=%.4f" % [int(w3_deep["bullets"]), int(w3_off["bullets"]), r3])
	_check("r2-b10 W3 深载逐拍最多一轮齐射（max_delta≤pellets）",
		int(w3_deep["max_delta"]) <= pellets,
		"max_delta=%d pellets=%d" % [int(w3_deep["max_delta"]), pellets])
	_check("r2-b11 W3 深载无残轮/多轮叠加（bullets==fire_ticks×pellets）",
		int(w3_deep["bullets"]) == int(w3_deep["fire_ticks"]) * pellets,
		"bullets=%d fire_ticks=%d pellets=%d" % [int(w3_deep["bullets"]),
			int(w3_deep["fire_ticks"]), pellets])
	_clear_projectiles()


func _p2_3_volley_cap() -> void:
	print("── r2-P2-3 W3 整轮容量预检（帽沿/team1 不计入/释放整轮） ──")
	PerfGovernor.boost_override = 1
	PerfGovernor.deep_override = 1
	_gl.state = GameConst.GameStatus.PLAYING
	tree.paused = false
	_set_active([_w3])
	_reset_weapon(_w3, 1)
	_clear_projectiles()
	var pool: ProjectilePool = _gl._projectile_pool
	var pellets := int(_w3.call(&"_volley_pellet_count"))
	_check("r2-v1 池空时 team0 headroom=200", pool.team0_headroom() == 200,
		"headroom=%d" % pool.team0_headroom())

	# 填帽至剩余容量不足一整轮
	var filled: Array[Node] = []
	while pool.team0_headroom() >= pellets and filled.size() < 260:
		var b: ProjectileBase = pool.acquire(0)
		if b == null:
			break
		filled.append(b)
	var h_edge := pool.team0_headroom()
	_check("r2-v2 帽沿状态 headroom<pellets", h_edge < pellets,
		"headroom=%d pellets=%d filled=%d" % [h_edge, pellets, filled.size()])

	# team1 活弹注入：headroom 不应变化（判据 total_active−team1_live）
	var t1: Array[Node] = []
	for _i in range(5):
		var b1: ProjectileBase = pool.acquire(1)
		if b1 == null:
			break
		b1.team = 1
		t1.append(b1)
	var h_team1 := pool.team0_headroom()
	_check("r2-v3 team1 活弹不计入 team0 headroom",
		h_team1 == h_edge and pool.team1_live == t1.size(),
		"h_edge=%d h_team1=%d team1_live=%d" % [h_edge, h_team1, pool.team1_live])

	# 帽沿整轮跳：不生成、CD 不写
	_w3.cooldown_left = 0.0
	var before := int(pool.total_active())
	_w3.tick(DT)
	_check("r2-v4 headroom<pellets → 整轮不发射", int(pool.total_active()) == before,
		"before=%d after=%d" % [before, int(pool.total_active())])
	_check("r2-v5 整轮跳不写冷却（cd 仍为 0）", is_zero_approx(float(_w3.cooldown_left)),
		"cd=%.6f" % float(_w3.cooldown_left))
	_check("r2-v6 整轮跳不回收 team1（5 颗仍在活口）",
		pool.team1_live == t1.size(), "team1_live=%d" % pool.team1_live)
	for b in t1:
		if b != null and is_instance_valid(b):
			pool.release(b)
	_check("r2-v7 team1 归还后 headroom 仍为帽沿值",
		pool.team0_headroom() == h_edge and pool.team1_live == 0,
		"headroom=%d team1=%d" % [pool.team0_headroom(), pool.team1_live])

	# 释放 >= 一整轮 → 整轮齐射
	var release_n := mini(filled.size(), pellets + 2)
	for i in range(release_n):
		pool.release(filled[i])
	_w3.cooldown_left = 0.0
	var before2 := int(pool.total_active())
	_w3.tick(DT)
	var fired := int(pool.total_active()) - before2
	_check("r2-v8 容量恢复 → 整轮齐射 fired==pellets", fired == pellets,
		"fired=%d pellets=%d headroom=%d" % [fired, pellets, pool.team0_headroom()])
	_check("r2-v9 齐射成功写 CD", float(_w3.cooldown_left) > 0.0,
		"cd=%.6f" % float(_w3.cooldown_left))
	# 收尾：归还剩余填帽弹/活弹
	for i in range(release_n, filled.size()):
		var b2: Node = filled[i]
		if b2 != null and is_instance_valid(b2):
			pool.release(b2)
	_clear_projectiles()


func _force_window(p_w: int, p_h: int) -> void:
	# headless 根窗口默认 64×64，配合 stretch=expand 会把逻辑宽扩成 960——
	# 无法验证真机 540 宽。直接设窗口尺寸，使可见 rect 严格等于目标逻辑尺寸
	#（vp 探针：size=540×960 → vis=540×960；结束还原）。
	_gl.get_window().size = Vector2i(p_w, p_h)


func _change_state_checked(p_state: int, p_label: String) -> void:
	var ok := bool(_gl.change_state(p_state))
	_check("%s 迁移被接受" % p_label, ok, "state=%d" % int(_gl.state))
	if not ok:
		_gl.state = p_state
		_gl._apply_boost_resolution()
		_gl.hud.refresh_stats()


func _assert_resolution(p_label: String, p_css: Vector2i, p_zoom: float,
		p_notch: int, p_div: float) -> void:
	var win := _gl.get_window()
	_check("%s content_scale=%s" % [p_label, str(p_css)], win.content_scale_size == p_css,
		str(win.content_scale_size))
	_check("%s zoom=%.2f" % [p_label, p_zoom],
		_gl.camera.zoom.is_equal_approx(Vector2(p_zoom, p_zoom)), str(_gl.camera.zoom))
	_check("%s applied_notch=%d" % [p_label, p_notch],
		int(_gl._boost_applied_notch) == p_notch \
			and GameLoop.boost_applied_notch() == p_notch,
		"inst=%d static=%d" % [int(_gl._boost_applied_notch),
			GameLoop.boost_applied_notch()])
	_check("%s world_div=%.2f" % [p_label, p_div],
		is_equal_approx(GameLoop.boost_world_div(), p_div),
		str(GameLoop.boost_world_div()))


func _assert_hud(p_label: String, p_expect_x: float) -> void:
	var ro: Control = _gl.hud._r187_readout
	var vw: float = _gl.hud.get_viewport().get_visible_rect().size.x
	var right := ro.position.x + ro.size.x
	_check("%s 读数盒在视口内" % p_label,
		ro.position.x >= 0.0 and right <= vw + 1.0,
		"x=%.1f w=%.1f right=%.1f vw=%.1f" % [ro.position.x, ro.size.x, right, vw])
	_check("%s 坐标=%.1f" % [p_label, p_expect_x],
		is_equal_approx(ro.position.x, p_expect_x),
		"x=%.1f expect=%.1f vw=%.1f" % [ro.position.x, p_expect_x, vw])
	if int(_gl._boost_applied_notch) == 2:
		_check("%s 右沿 ≤ vw−130" % p_label, right <= vw - 130.0 + 0.5,
			"right=%.1f limit=%.1f" % [right, vw - 130.0])


func _p1_2_state_hud() -> void:
	print("── r2-P1-2 状态迁移 / 自动 HUD fit / 85 与 boost 关坐标 ──")
	PerfGovernor.boost_override = 1
	PerfGovernor.deep_override = 1
	_gl.state = GameConst.GameStatus.PLAYING
	tree.paused = false
	_force_window(540, 960)
	_gl._apply_boost_resolution()
	var vw_play: float = _gl.hud.get_viewport().get_visible_rect().size.x
	_check("r2-c0 PLAYING 强制窗口后逻辑宽=540（真机 540 视口）",
		is_equal_approx(vw_play, 540.0), "vw=%.1f" % vw_play)
	_assert_resolution("r2-c1 PLAYING 深载", Vector2i(540, 960), 0.75, 2, 0.75)
	_check("r2-c2 PLAYING 深载促键=2", PerfGovernor.boost_diag_state() == 2,
		str(PerfGovernor.boost_diag_state()))

	# 让 HUD 读数位有内容（W4 → 束 ×N 段），验证真实 refresh_stats 路径
	var w4: WeaponBase = _gl.player.add_weapon(_gl.registry.get_weapon(&"W4_pulse_beam"))
	_check("r2-c3 真实 W4_pulse_beam 装入（HUD 段前置）",
		w4 != null and w4.data != null and String(w4.data.id) == "W4_pulse_beam", str(w4))
	_gl.hud.refresh_stats()
	var ro: Label = _gl.hud._r187_readout
	_check("r2-c4 HUD 读数位可见且含束段",
		ro != null and ro.visible and ro.text.contains("束"),
		"visible=%s text=%s" % [str(ro != null and ro.visible), str(ro.text if ro != null else "")])
	var vw0: float = _gl.hud.get_viewport().get_visible_rect().size.x
	print("  HUDDBG | hud_vp_vis=%s hud_vp_size=%s gl_vp_vis=%s window_size=%s css=%s ro_pos=%s ro_size=%s"
		% [str(_gl.hud.get_viewport().get_visible_rect().size),
			str(_gl.hud.get_viewport().size),
			str(_gl.get_viewport().get_visible_rect().size),
			str(_gl.get_window().size),
			str(_gl.get_window().content_scale_size),
			str(_gl.hud._r187_readout.position),
			str(_gl.hud._r187_readout.size)])
	_assert_hud("r2-c5 PLAYING 540 读数位", maxf(vw0 - 354.0, 186.0))

	# PLAYING → LEVEL_UP：真实 change_state，HUD 依赖 state_changed→refresh_stats 自动 fit
	_force_window(612, 1088)
	_change_state_checked(GameConst.GameStatus.LEVEL_UP, "r2-c6 PLAYING→LEVEL_UP")
	_assert_resolution("r2-c7 LEVEL_UP", Vector2i(612, 1088), 0.85, 1, 0.85)
	var diag_lu := int(PerfGovernor.boost_diag_state())
	print("  OBSERVE | LEVEL_UP deep: applied_notch=%d diag_state=%d css=%s "
		% [int(_gl._boost_applied_notch), diag_lu, str(_gl.get_window().content_scale_size)]
		+ "（促N=应用态真值契约；此处实际应用档=1）")
	_assert_hud("r2-c8 LEVEL_UP 读数位", 368.0)

	# 回 PLAYING：自动 fit 回 notch2
	_force_window(540, 960)
	_change_state_checked(GameConst.GameStatus.PLAYING, "r2-c9 LEVEL_UP→PLAYING")
	_assert_resolution("r2-c10 回 PLAYING", Vector2i(540, 960), 0.75, 2, 0.75)
	var vw1: float = _gl.hud.get_viewport().get_visible_rect().size.x
	_assert_hud("r2-c11 回 PLAYING 读数位", maxf(vw1 - 354.0, 186.0))

	# PLAYING → PAUSED：自动回 85 档
	_force_window(612, 1088)
	_change_state_checked(GameConst.GameStatus.PAUSED, "r2-c12 PLAYING→PAUSED")
	_assert_resolution("r2-c13 PAUSED", Vector2i(612, 1088), 0.85, 1, 0.85)
	var diag_pa := int(PerfGovernor.boost_diag_state())
	print("  OBSERVE | PAUSED deep: applied_notch=%d diag_state=%d css=%s "
		% [int(_gl._boost_applied_notch), diag_pa, str(_gl.get_window().content_scale_size)]
		+ "（促N=应用态真值契约；此处实际应用档=1）")
	_assert_hud("r2-c14 PAUSED 读数位", 368.0)
	_force_window(540, 960)
	_change_state_checked(GameConst.GameStatus.PLAYING, "r2-c15 PAUSED→PLAYING")
	_assert_resolution("r2-c16 再回 PLAYING", Vector2i(540, 960), 0.75, 2, 0.75)

	# 85 档（deep 关）：612/.85，读数位 368
	PerfGovernor.boost_override = 1
	PerfGovernor.deep_override = 0
	_force_window(612, 1088)
	_gl._apply_boost_resolution()
	_gl.hud.refresh_stats()
	_assert_resolution("r2-c17 用户85 deep关", Vector2i(612, 1088), 0.85, 1, 0.85)
	_check("r2-c18 用户85 deep关促键=1", PerfGovernor.boost_diag_state() == 1,
		str(PerfGovernor.boost_diag_state()))
	_assert_hud("r2-c19 用户85 读数位", 368.0)

	# boost 关：720/1.0，读数位仍 368
	PerfGovernor.boost_override = 0
	PerfGovernor.deep_override = 1
	_force_window(720, 1280)
	_gl._apply_boost_resolution()
	_gl.hud.refresh_stats()
	_assert_resolution("r2-c20 boost关", Vector2i(720, 1280), 1.0, 0, 1.0)
	_check("r2-c21 boost关 ∧ deep_override=1 → deep_load false / 促0",
		not PerfGovernor.deep_load() and PerfGovernor.boost_diag_state() == 0, "")
	_assert_hud("r2-c22 boost关读数位", 368.0)
	# 恢复深载开态供收尾（不依赖）
	PerfGovernor.boost_override = 1
	PerfGovernor.deep_override = -1
	PerfGovernor.set_deep_active(false)
	_force_window(612, 1088)
	_gl._apply_boost_resolution()
	_gl.hud.refresh_stats()


func _cleanup() -> void:
	print("── 收尾（弹/靶/设置/画布/闩还原） ──")
	var pool: ProjectilePool = _gl._projectile_pool
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
	_gl._deep_on_acc = 0.0
	_gl._deep_off_acc = 0.0
	_gl._deep_dwell_s = 0.0
	_gl.state = GameConst.GameStatus.MENU
	tree.paused = false
	_gl.get_window().size = _saved_win_size
	_gl.get_window().content_scale_size = _saved_css
	if _gl.camera != null:
		_gl.camera.zoom = _saved_zoom
	_gl._boost_applied_notch = _saved_notch
	GameLoop._s_boost_applied_notch = _saved_snotch
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

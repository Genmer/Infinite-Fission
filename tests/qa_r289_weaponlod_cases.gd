# tests/qa_r289_weaponlod_cases.gd（R289 用例体——入口运行时加载）
# 覆盖（A 武器分键+隔帧节流 / B 深载密度帽 / C 75% 应急档）：
#   d1 深载滞回：fps<34×2s 置位 / 34..45 死区保持 / >45×4s 清位 / boost 关恒 false /
#      MENU 清位。
#   d2 单谓词四消费点一致：deep 开 → weapon_lod_on ∧ 敌帽 40（R290：60→40）∧ 促1（R291：促键=用户档真值）；deep 关 → 90/促1；
#      boost 关 → MAX_ONSCREEN/促0（关态逐位不变的正对照）。
#   d3 C 渲染档（R291 UI 定格）：用户 85 + deep → 画布定格 612×1088 + zoom .85 +
#      world_div .85（闩不改画布）；跨态（LEVEL_UP/PAUSED）同值；解除零写幂等。
#   d4 B 玩家弹帽：deep 开 acquire 至 BOOST_DEEP_TEAM0_CAP（R290：200→120）→ null + 弹拒计数；deep 关恢复可获。
#   d5 A 节拍+时间守恒：stub 武器 10 步深载 → tick 执行 5 次、累计 dt=10/60；
#      关态 10 步 → 10 次、累计同值（关态逐位不变）。
#   d6 A 仪器：副武桶计时>0（无 data 的副本桶）；族映射真值表（W1→0/W8→7/未知→9）。
#   d7 诊断行：武1µs..副武µs/深/武跳/弹拒 在位且位于 派段µs 之后；深1 与秒窗和直读。
#   d8 导出头 R289 句 + 三刀披露（%% 转义不炸）。
# 夹具纪律（r288 同款）：Meta 设置入口快照整字典还原 + _save 落盘；boost_override/
# deep_override 用毕复位；窗口 content_scale/zoom 入口快照还原；盘档自清（RunSave.clear）。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const DT := 1.0 / 60.0

var tree: SceneTree
var _gl: Node = null
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _saved_settings: Dictionary = {}
var _saved_css: Vector2i = Vector2i.ZERO
var _saved_zoom: Vector2 = Vector2.ONE
var _stub: WeaponBase = null
var _slot0_backup: WeaponBase = null
var _slot0_added: bool = false
var _acquired: Array[Node] = []


class StubWeapon extends WeaponBase:
	var acc: float = 0.0
	var calls: int = 0

	func tick(p_dt: float) -> void:
		acc += p_dt
		calls += 1


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
	_gl = scene.instantiate()
	_gl.name = "R289WeaponLod"
	tree.root.add_child(_gl)
	if not (_gl.get("boot_ready") and _gl.state == GameConst.GameStatus.MENU):
		push_error("[r289] Boot 失败：%s" % str(_gl.get("boot_fatal")))
		_fail += 1


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_saved_settings = Meta._settings.duplicate()      # 入口快照（收尾还原——磁盘不留测试痕）
	_boot()
	PerfGovernor.set_process(false)
	PerfGovernor.mode_override = -1
	PerfGovernor.tier_override = 3
	PerfGovernor.boost_override = -1
	PerfGovernor.deep_override = -1
	PerfGovernor.set_deep_active(false)
	Meta.set_setting("fx_quality", 2)                 # r230 先例：钉高防跨套件 user:// 残留漂门
	Meta.set_setting("boost_res", 85)
	Meta.set_setting("perf_boost", 1)
	_saved_css = _gl.get_window().content_scale_size
	_saved_zoom = _gl.camera.zoom
	_setup_battle()
	_d1_hysteresis()
	_d2_single_predicate()
	_d3_render_notch()
	_d4_player_bullet_cap()
	_d12_volley_starvation()
	_d5_lod_cadence_conservation()
	_d6_instrument()
	_d7_diag_line()
	_d8_export_header()
	_d9_hud_fit()
	_d10_volley_cap()
	_d11_boss_queue_priority()
	await _cleanup()


func _setup_battle() -> void:
	# 活战态夹具（滞回/C 档门均要求 PLAYING；玩家无限血防误触死亡短路）
	_gl.state = GameConst.GameStatus.PLAYING
	_gl.player.set("_dead", false)
	_gl.player.set("max_hp", 1.0e12)
	_gl.player.set("hp", 1.0e12)
	_gl.player.set("xp_need", 1.0e12)
	_gl.player.unlocked_slots = 6
	_gl.player.global_position = Vector2(360.0, 980.0)


func _deep_steps(p_fps: float, p_seconds: float) -> void:
	# R289 修轮：生产写点单帧 delta 钳 0.1s（后台恢复防御）——直驱按 0.1s 帧步进，
	# 与 _process 真链同语义。
	var _n := int(round(p_seconds / 0.1))
	for _i in range(_n):
		_gl._update_deep_load_at(p_fps, 0.1)


func _d1_hysteresis() -> void:
	print("── d1 深载滞回（2s 进 / 4s 出+10s 驻留 / 死区 / delta 钳制 / boost 门 / 菜单清位） ──")
	PerfGovernor.boost_override = 1
	PerfGovernor.deep_override = -1
	PerfGovernor.set_deep_active(false)
	_gl._deep_on_acc = 0.0
	_gl._deep_off_acc = 0.0
	_gl._deep_dwell_s = 0.0
	_deep_steps(20.0, 1.9)
	_check("d1 低帧 1.9s 未置位（滞回需 2s）", not PerfGovernor.deep_active())
	_deep_steps(20.0, 0.1)
	_check("d1 fps<34 累计 2s → 置位", PerfGovernor.deep_active())
	_deep_steps(40.0, 10.0)
	_check("d1 34..45 死区不清零", PerfGovernor.deep_active())
	_deep_steps(60.0, 3.0)
	_check("d1 高帧 3s 未清位（需 4s）", PerfGovernor.deep_active())
	_deep_steps(60.0, 1.0)
	_check("d1 fps>45 持续 4s → 清位（驻留已满 10s）", not PerfGovernor.deep_active())
	# 最小驻留：置位后 4s 高帧不得撤（dwell<10s）
	_gl._deep_on_acc = 0.0
	_gl._deep_off_acc = 0.0
	_gl._deep_dwell_s = 0.0
	_deep_steps(20.0, 2.0)
	_check("d1 再次置位（驻留测试前置）", PerfGovernor.deep_active())
	_deep_steps(60.0, 4.0)
	_check("d1 高帧 4s 但驻留<10s → 不撤（防极限环）", PerfGovernor.deep_active())
	_deep_steps(40.0, 4.0)
	_deep_steps(60.0, 4.0)
	_check("d1 驻留≥10s 且高帧 4s → 撤档", not PerfGovernor.deep_active())
	# 后台恢复巨 delta：单帧 5s 不得满足 2s 低帧门（内部钳 0.1s/帧）
	_gl._deep_on_acc = 0.0
	_gl._deep_off_acc = 0.0
	_gl._deep_dwell_s = 0.0
	_gl._update_deep_load_at(20.0, 5.0)
	_gl._update_deep_load_at(20.0, 5.0)
	_check("d1 巨 delta×2 不置位（钳 0.1s/帧）", not PerfGovernor.deep_active())
	_deep_steps(20.0, 2.0)
	_check("d1 正常 0.1s 步进累计 2s → 置位（钳制不破坏正常累积）", PerfGovernor.deep_active())
	# MENU → 即时清位（结算/菜单画布恒全分辨率）
	_gl.state = GameConst.GameStatus.MENU
	_gl._update_deep_load_at(20.0, 1.0)
	_check("d1 MENU → 清位", not PerfGovernor.deep_active())
	_gl.state = GameConst.GameStatus.PLAYING
	# boost 关：真值恒 false（无论计时器）
	PerfGovernor.deep_override = 1
	PerfGovernor.boost_override = 0
	_check("d1 boost 关 → deep_load 恒 false", not PerfGovernor.deep_load())
	PerfGovernor.boost_override = 1
	PerfGovernor.deep_override = -1
	PerfGovernor.set_deep_active(false)
	_gl._deep_on_acc = 0.0
	_gl._deep_off_acc = 0.0
	_gl._deep_dwell_s = 0.0


func _d2_single_predicate() -> void:
	print("── d2 单谓词四消费点一致（A 节流 / B 敌帽 / C 促键 / 关态正对照） ──")
	PerfGovernor.boost_override = 1
	PerfGovernor.deep_override = 1
	_check("d2 deep 开 → weapon_lod_on", PerfGovernor.weapon_lod_on())
	_check("d2 deep 开 → 敌帽 40", EnemySpawner.max_onscreen() == 40,
		str(EnemySpawner.max_onscreen()))
	_gl.state = GameConst.GameStatus.PLAYING
	_gl._apply_boost_resolution()
	_check("d2 deep 开（PLAYING 已应用）→ 促1（R291：促键=用户档真值，闩不改画布）",
		PerfGovernor.boost_diag_state() == 1, str(PerfGovernor.boost_diag_state()))
	PerfGovernor.deep_override = 0
	_gl._apply_boost_resolution()
	_check("d2 deep 关 → 敌帽 90", EnemySpawner.max_onscreen() == 90,
		str(EnemySpawner.max_onscreen()))
	_check("d2 deep 关 → 促1", PerfGovernor.boost_diag_state() == 1,
		str(PerfGovernor.boost_diag_state()))
	PerfGovernor.boost_override = 0
	_check("d2 boost 关 → 敌帽 MAX_ONSCREEN（逐位不变）",
		EnemySpawner.max_onscreen() == EnemySpawner.MAX_ONSCREEN,
		str(EnemySpawner.max_onscreen()))
	_check("d2 boost 关 → 促0", PerfGovernor.boost_diag_state() == 0,
		str(PerfGovernor.boost_diag_state()))
	_check("d2 boost 关 → weapon_lod_on false", not PerfGovernor.weapon_lod_on())
	PerfGovernor.boost_override = 1
	PerfGovernor.deep_override = -1


func _d3_render_notch() -> void:
	print("── d3 C 渲染档（R291 UI 定格：深载不改画布；跨态恒定；解除零写） ──")
	PerfGovernor.boost_override = 1
	Meta.set_setting("boost_res", 85)
	PerfGovernor.deep_override = 1
	_gl.state = GameConst.GameStatus.PLAYING
	_gl._apply_boost_resolution()
	var win := _gl.get_window()
	_check("d3 深载+PLAYING → 画布定格 612×1088（R291 删自动降档）",
		win.content_scale_size == Vector2i(612, 1088), str(win.content_scale_size))
	_check("d3 深载+PLAYING → zoom .85（不降 .75）",
		_gl.camera.zoom.is_equal_approx(Vector2(0.85, 0.85)), str(_gl.camera.zoom))
	_check("d3 深载+PLAYING → world_div .85",
		is_equal_approx(GameLoop.boost_world_div(), 0.85), str(GameLoop.boost_world_div()))
	# R291：自动档状态回退（R289 修轮 P1-2）随自动档一并删除——跨态恒定为定格断言
	_gl.state = GameConst.GameStatus.LEVEL_UP
	_gl._apply_boost_resolution()
	_check("d3 LEVEL_UP 定格 612×1088", win.content_scale_size == Vector2i(612, 1088),
		str(win.content_scale_size))
	_check("d3 LEVEL_UP zoom .85", _gl.camera.zoom.is_equal_approx(Vector2(0.85, 0.85)),
		str(_gl.camera.zoom))
	_check("d3 LEVEL_UP 促1（用户档真值）",
		PerfGovernor.boost_diag_state() == 1, str(PerfGovernor.boost_diag_state()))
	_gl.state = GameConst.GameStatus.PLAYING
	_gl._apply_boost_resolution()
	_check("d3 回 PLAYING 定格 612×1088（零写幂等）",
		win.content_scale_size == Vector2i(612, 1088), str(win.content_scale_size))
	_gl.state = GameConst.GameStatus.PAUSED
	_gl._apply_boost_resolution()
	_check("d3 PAUSED 定格 612×1088", win.content_scale_size == Vector2i(612, 1088),
		str(win.content_scale_size))
	_gl.state = GameConst.GameStatus.PLAYING
	_gl._apply_boost_resolution()
	_check("d3 再回 PLAYING 定格 612×1088", win.content_scale_size == Vector2i(612, 1088),
		str(win.content_scale_size))
	PerfGovernor.deep_override = 0
	_gl._apply_boost_resolution()
	_check("d3 解除 → 仍 612×1088（零写）", win.content_scale_size == Vector2i(612, 1088),
		str(win.content_scale_size))
	_check("d3 解除 → zoom .85", _gl.camera.zoom.is_equal_approx(Vector2(0.85, 0.85)),
		str(_gl.camera.zoom))
	_check("d3 解除回用户档 world_div=.85", is_equal_approx(GameLoop.boost_world_div(), 0.85),
		str(GameLoop.boost_world_div()))


func _d4_player_bullet_cap() -> void:
	print("── d4 B 深载玩家弹帽（%d 拒绝 + 弹拒键 / 解除恢复） ──" % ProjectilePool.BOOST_DEEP_TEAM0_CAP)
	PerfGovernor.boost_override = 1
	PerfGovernor.deep_override = 1
	var pool: ProjectilePool = _gl._projectile_pool
	var base := pool.total_active() - pool.team1_live
	_check("d4 前置：玩家弹活口 < %d" % ProjectilePool.BOOST_DEEP_TEAM0_CAP,
		base < ProjectilePool.BOOST_DEEP_TEAM0_CAP, "base=%d" % base)
	var c0 := int(DebugStats.get_counter(&"deep_bullet_capped"))
	var n := 0
	for _i in range(ProjectilePool.BOOST_DEEP_TEAM0_CAP + 60):
		var p: ProjectileBase = pool.acquire(0)
		if p == null:
			break
		n += 1
		_acquired.append(p)
	_check("d4 深载 acquire 至玩家弹帽上限", base + n == ProjectilePool.BOOST_DEEP_TEAM0_CAP,
		"base=%d n=%d" % [base, n])
	_check("d4 超帽返 null", n < ProjectilePool.BOOST_DEEP_TEAM0_CAP + 60, "n=%d" % n)
	_check("d4 弹拒计数递增", int(DebugStats.get_counter(&"deep_bullet_capped")) - c0 > 0,
		"Δ=%d" % (int(DebugStats.get_counter(&"deep_bullet_capped")) - c0))
	# 解除深载 → 同池恢复可获（帽门恒不触）
	PerfGovernor.deep_override = 0
	var p2: ProjectileBase = pool.acquire(0)
	_check("d4 解除深载后可再获", p2 != null, str(p2))
	if p2 != null:
		_acquired.append(p2)
	# 归还
	for p in _acquired:
		if p != null and is_instance_valid(p):
			pool.release(p)
	_acquired.clear()
	PerfGovernor.deep_override = -1


func _d12_volley_starvation() -> void:
	print("── d12 帽沿竞争：单发武器预留帽不得饿死多丸武器（P1-1 修轮） ──")
	PerfGovernor.boost_override = 1
	PerfGovernor.deep_override = 1
	_gl.state = GameConst.GameStatus.PLAYING
	var pool: ProjectilePool = _gl._projectile_pool
	var epool: EnemyPool = _gl.pools[&"enemy"]
	var slots: Array = _gl.player.weapon_slots
	for i in range(slots.size()):
		slots[i] = null
	var w1: WeaponBase = _gl.player.add_weapon(_gl.registry.get_weapon(&"W1_pistol"))
	var w3: WeaponBase = _gl.player.add_weapon(_gl.registry.get_weapon(&"W3_shotgun"))
	_check("d12 真实 W1+W3 同场装入", w1 != null and w3 != null
		and w1.data != null and w3.data != null, "w1=%s w3=%s" % [str(w1), str(w3)])
	if w1 == null or w3 == null:
		PerfGovernor.deep_override = -1
		return
	var pellets := int(w3.call(&"_volley_pellet_count"))
	var target: Enemy = epool.acquire()
	if target == null:
		_check("d12 靶敌生成（前置）", false, "enemy pool acquire=null")
		PerfGovernor.deep_override = -1
		return
	var src: EnemyData = _gl.registry.get_enemy(&"E1_grunt")
	var ed: EnemyData = src.duplicate() as EnemyData
	ed.hp_base = 1.0e12
	target.bucket_host = epool.bucket_host
	target.spawn(ed, 1, 0)
	target.global_position = Vector2(360.0, 700.0)
	target.dead = false
	_gl.spawner.active.append(target)
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	# 填到「只剩一轮容量」：单发武器被预留帽挡在 16 之外，多丸武器仍可齐射
	var filled: Array[Node] = []
	while pool.team0_headroom() > pellets and filled.size() < 240:
		var b: ProjectileBase = pool.acquire(0)
		if b == null:
			break
		filled.append(b)
	_check("d12 帽沿前置：剩余容量=一轮（%d）" % pellets,
		pool.team0_headroom() == pellets, "headroom=%d" % pool.team0_headroom())
	# 300 步竞争：按冷却归零→置正判定真实发射（pool 净值受命中回收干扰，不能当发数）
	_gl.player._wpn_lod_phase = 0
	var w3_fires := 0
	var w1_fires := 0
	var max_step_delta := 0
	var _rel_i := 0
	for _i in range(300):
		# 直驱 player.tick 不含弹体物理，命中/过期回收不会自然发生——每 4 步手动
		# 归还一颗填帽弹，模拟真实弹幕的持续周转（headroom 恢复节奏）。
		if _i % 4 == 0 and _rel_i < filled.size():
			pool.release(filled[_rel_i])
			_rel_i += 1
		var c3 := float(w3.cooldown_left)
		var c1 := float(w1.cooldown_left)
		var before := pool.total_active()
		_gl.player.tick(DT, Vector2.ZERO)
		max_step_delta = maxi(max_step_delta, pool.total_active() - before)
		if float(w3.cooldown_left) > 0.0 and c3 <= 0.0:
			w3_fires += 1
		if float(w1.cooldown_left) > 0.0 and c1 <= 0.0:
			w1_fires += 1
	_check("d12 多丸 W3 在帽沿竞争下不哑火（300 步 ≥2 轮）", w3_fires >= 2,
		"w3_fires=%d pellets=%d headroom=%d" % [w3_fires, pellets, pool.team0_headroom()])
	_check("d12 单发 W1 仍有开火（预留不反向饿死单发）", w1_fires >= 1,
		"w1_fires=%d" % w1_fires)
	_check("d12 无单拍多轮齐射（Δ≤pellets+1）", max_step_delta <= pellets + 1,
		"max_delta=%d pellets=%d" % [max_step_delta, pellets])
	# 收尾
	var live: Array = pool.active_projectiles().duplicate()
	for p in live:
		if p != null and is_instance_valid(p):
			pool.release(p)
	_gl.spawner.active.erase(target)
	epool.release(target)
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	for i in range(slots.size()):
		if slots[i] == w1 or slots[i] == w3:
			slots[i] = null
	if is_instance_valid(w1):
		w1.queue_free()
	if is_instance_valid(w3):
		w3.queue_free()
	WeaponBase.lod_dt_doubled = false
	PerfGovernor.deep_override = -1


func _d5_lod_cadence_conservation() -> void:
	print("── d5 A 隔帧节拍 + dt×2 模拟时间守恒（关态正对照） ──")
	PerfGovernor.boost_override = 1
	PerfGovernor.deep_override = 1
	_stub = StubWeapon.new()
	var slots: Array = _gl.player.weapon_slots
	if slots.is_empty():
		slots.append(_stub)
		_slot0_added = true
	else:
		_slot0_backup = slots[0]
		slots[0] = _stub
	Player.reset_stage_probe()
	_gl.player._wpn_lod_phase = 0
	var skip0 := int(DebugStats.get_counter(&"weapon_lod_skip"))
	for _i in range(10):
		_gl.player.tick(DT, Vector2.ZERO)
	_check("d5 深载 10 步只执行 5 次", int(_stub.calls) == 5, "calls=%d" % int(_stub.calls))
	_check("d5 深载执行步 dt×2 → 模拟时间守恒 10/60",
		absf(float(_stub.acc) - 10.0 * DT) < 1.0e-5, "acc=%.6f" % float(_stub.acc))
	_check("d5 武跳计数=5",
		int(DebugStats.get_counter(&"weapon_lod_skip")) - skip0 == 5,
		"Δ=%d" % (int(DebugStats.get_counter(&"weapon_lod_skip")) - skip0))
	# 关态：每步执行、dt 原值（逐位不变）
	PerfGovernor.deep_override = 0
	var calls0: int = _stub.calls
	var acc0: float = _stub.acc
	for _i in range(10):
		_gl.player.tick(DT, Vector2.ZERO)
	_check("d5 关态 10 步全执行", _stub.calls - calls0 == 10,
		"Δcalls=%d" % (_stub.calls - calls0))
	_check("d5 关态 dt 原值（累计同 10/60）",
		absf((_stub.acc - acc0) - 10.0 * DT) < 1.0e-5,
		"Δacc=%.6f" % (_stub.acc - acc0))
	PerfGovernor.deep_override = -1


func _d6_instrument() -> void:
	print("── d6 A 仪器（副本桶计时 / 武器族映射真值） ──")
	PerfGovernor.boost_override = 1
	PerfGovernor.deep_override = 1
	Player.reset_stage_probe()
	_gl.player._wpn_lod_phase = 0
	# 副本桶为墙钟 µs 累计：单次 no-op stub 可能取整到 0（曾偶发假红）——多跑 100 个
	# 执行步把噪声抬高到分辨率之上，断言只证「计时管线接通且累加」，不证单次成本。
	for _i in range(200):
		_gl.player.tick(DT, Vector2.ZERO)
	_check("d6 副武桶计时>0（stub 无 data → 副本桶）", Player.probe_wpn_us[9] > 0,
		"桶9=%d" % Player.probe_wpn_us[9])
	_check("d6 族映射 W1→0", WeaponBase.wpn_family_index(&"W1_pistol") == 0,
		str(WeaponBase.wpn_family_index(&"W1_pistol")))
	_check("d6 族映射 W8→7", WeaponBase.wpn_family_index(&"W8_orbit_field") == 7,
		str(WeaponBase.wpn_family_index(&"W8_orbit_field")))
	_check("d6 族映射 W9→8", WeaponBase.wpn_family_index(&"W9_arc_slash") == 8,
		str(WeaponBase.wpn_family_index(&"W9_arc_slash")))
	_check("d6 族映射 未知/空→副武桶 9",
		WeaponBase.wpn_family_index(&"NOPE") == 9 and WeaponBase.wpn_family_index(null) == 9, "")
	PerfGovernor.deep_override = -1


func _d7_diag_line() -> void:
	print("── d7 诊断行十三键（位序 / 直读 / 深1） ──")
	PerfGovernor.boost_override = 1
	PerfGovernor.deep_override = 1
	_gl._stage_win_wpn_us.fill(0)
	_gl._stage_win_wpn_us[0] = 777
	_gl._stage_win_wpn_us[7] = 333
	var line := DebugStats._diag_format_line(_gl, Time.get_ticks_msec())
	_check("d7 行含 武1µs777", line.contains("武1µs777"), line.left(160))
	_check("d7 行含 武8µs333", line.contains("武8µs333"), "")
	_check("d7 行含 副武µs 键", line.contains("副武µs"), "")
	_check("d7 行含 深1/武跳/弹拒", line.contains("深1 ") and line.contains("武跳") \
		and line.contains("弹拒"), "")
	var i_pai := line.find("派段µs")
	var i_wpn := line.find("武1µs")
	_check("d7 武键紧跟 派段µs 之后（行尾新段先例）", i_pai >= 0 and i_wpn > i_pai,
		"i_pai=%d i_wpn=%d" % [i_pai, i_wpn])
	PerfGovernor.deep_override = 0
	var line2 := DebugStats._diag_format_line(_gl, Time.get_ticks_msec())
	_check("d7 关态行 深0", line2.contains("深0 "), "")


func _d8_export_header() -> void:
	print("── d8 导出口径头（R289 句 / 三刀披露 / % 转义） ──")
	var txt := String(DebugStats.diag_export().get("text", ""))
	_check("d8 口径头含 R289 句", txt.contains("R289（A/B/C 深载三刀）"), "len=%d" % txt.length())
	_check("d8 口径头含 深N/武跳N/弹拒N",
		txt.contains("深N=深载滞回闩") and txt.contains("武跳N") and txt.contains("弹拒N"), "")
	_check("d8 口径头含 三刀/关态逐位不变披露",
		txt.contains("三刀=A 武器隔帧节流") and txt.contains("关态逐位不变"), "")


func _d9_hud_fit() -> void:
	print("── d9 HUD 读数位 540 逻辑宽适配（P1-2 修轮；R291 起 notch2 由用户手选 75 驱动） ──")
	PerfGovernor.boost_override = 1
	PerfGovernor.deep_override = 1
	Meta.set_setting("boost_res", 75)
	_gl.state = GameConst.GameStatus.PLAYING
	_gl._apply_boost_resolution()
	var ro: Control = _gl.hud._r187_readout
	_check("d9 读数位存在", ro != null, "")
	if ro == null:
		return
	ro.visible = true
	_gl.hud._fit_r187_readout()
	var vw: float = _gl.hud.get_viewport().get_visible_rect().size.x
	_check("d9 notch2 读数盒完全在视口内",
		ro.position.x >= 0.0 and ro.position.x + ro.size.x <= vw + 1.0,
		"x=%.1f w=%.1f vw=%.1f" % [ro.position.x, ro.size.x, vw])
	_check("d9 notch2 读数盒不压波次徽章（右沿 ≤ vw−130）",
		ro.position.x + ro.size.x <= vw - 129.0,
		"right=%.1f limit=%.1f" % [ro.position.x + ro.size.x, vw - 130.0])
	# 修轮 4（评审 P2-1）：顶部 HUD 全元素两两审计——读数位 y200 空槽，与 HP/XP/Lv/
	# 击杀/计时/护盾/临时护盾/目标条/徽章均不相交（护盾与徽章自身相交为 540 档存量）。
	var ro_rect := Rect2(ro.position, ro.size)
	var hud_rects := {
		"HP": Rect2(Vector2(24.0, 24.0), Vector2(340.0, 30.0)),
		"XP": Rect2(Vector2(54.0, 63.0), Vector2(292.0, 14.0)),
		"Lv": Rect2(Vector2(356.0, 60.0), Vector2(36.0, 25.0)),
		"击杀": Rect2(Vector2(24.0, 92.0), Vector2(150.0, 36.0)),
		"计时": Rect2(Vector2(184.0, 92.0), Vector2(112.0, 36.0)),
		"护盾": Rect2(Vector2(306.0, 92.0), Vector2(148.0, 36.0)),
		"临时护盾": Rect2(Vector2(306.0, 132.0), Vector2(148.0, 36.0)),
		"目标条": Rect2(Vector2(24.0, 136.0), Vector2(280.0, 26.0)),
		"徽章": Rect2(Vector2(vw - 122.0, 16.0), Vector2(106.0, 106.0)),
	}
	for _nm in hud_rects:
		_check("d9 notch2 读数盒与%s不相交" % str(_nm),
			not ro_rect.intersects(hud_rects[_nm]),
			"ro=%s %s=%s" % [str(ro_rect), str(_nm), str(hud_rects[_nm])])
	_check("d9 notch2 读数位在顶部 HUD 带下方空槽（y=200）",
		is_equal_approx(ro.position.y, 200.0), "y=%.1f" % ro.position.y)
	Meta.set_setting("boost_res", 85)
	PerfGovernor.deep_override = 0
	_gl._apply_boost_resolution()
	_gl.hud._fit_r187_readout()
	_check("d9 85 档读数盒回原坐标 (368,30)（既有布局零扰动）",
		is_equal_approx(ro.position.x, 368.0) and is_equal_approx(ro.position.y, 30.0),
		"pos=%s" % str(ro.position))


func _d10_volley_cap() -> void:
	print("── d10 多丸武器整轮容量预检（P2-3 修轮：帽沿不出 1/9 残轮） ──")
	PerfGovernor.boost_override = 1
	PerfGovernor.deep_override = 1
	_gl.state = GameConst.GameStatus.PLAYING
	var pool: ProjectilePool = _gl._projectile_pool
	var epool: EnemyPool = _gl.pools[&"enemy"]
	var target: Enemy = epool.acquire()
	if target == null:
		_check("d10 靶敌生成（前置）", false, "enemy pool acquire=null")
		return
	var src: EnemyData = _gl.registry.get_enemy(&"E1_grunt")
	var ed: EnemyData = src.duplicate() as EnemyData
	ed.hp_base = 1.0e12
	target.bucket_host = epool.bucket_host
	target.spawn(ed, 1, 0)
	target.global_position = Vector2(360.0, 800.0)
	target.dead = false
	_gl.spawner.active.append(target)
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	var w3: WeaponBase = _gl.player.add_weapon(_gl.registry.get_weapon(&"W3_shotgun"))
	_check("d10 真实 W3_shotgun 装入", w3 != null and w3.data != null
		and String(w3.data.id) == "W3_shotgun", str(w3))
	if w3 == null or w3.data == null:
		_gl.spawner.active.erase(target)
		epool.release(target)
		return
	var pellets := int(w3.call(&"_volley_pellet_count"))
	_check("d10 丸数≥2（多丸前置）", pellets >= 2, "pellets=%d" % pellets)
	# 填帽：acquire 到剩余容量 < 一整轮
	var filled: Array[Node] = []
	while pool.team0_headroom() >= pellets and filled.size() < 260:
		var b: ProjectileBase = pool.acquire(0)
		if b == null:
			break
		filled.append(b)
	_check("d10 帽沿状态：剩余容量不足整轮",
		pool.team0_headroom() < pellets, "headroom=%d pellets=%d"
			% [pool.team0_headroom(), pellets])
	var before := pool.total_active()
	WeaponBase.lod_dt_doubled = false            # 直调 tick 走 1×dt 关态分支（防前序残留）
	w3.cooldown_left = 0.0
	w3._quota_pending = 2                       # 顺延丸在场：预检拒绝不得吞掉
	w3.tick(DT)
	_check("d10 容量不足 → 整轮不发射", pool.total_active() == before,
		"before=%d after=%d" % [before, pool.total_active()])
	_check("d10 整轮跳不写冷却（容量恢复即续射）", w3.cooldown_left <= 0.0,
		"cd=%.4f" % w3.cooldown_left)
	_check("d10 预检拒绝保留顺延丸（due 不被清零）", int(w3._quota_pending) == 2,
		"due=%d" % int(w3._quota_pending))
	# 释放空间 → 整轮齐射（不残轮）
	var k := mini(filled.size(), pellets + 2)
	for i in range(k):
		pool.release(filled[i])
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	w3.cooldown_left = 0.0
	var before2 := pool.total_active()
	WeaponBase.lod_dt_doubled = false
	w3.tick(DT)
	var fired := pool.total_active() - before2
	_check("d10 容量恢复 → 整轮齐射（新丸+顺延）", fired == pellets + 2,
		"fired=%d pellets=%d due=2" % [fired, pellets])
	# 收尾：归还剩余填帽弹/靶/武器
	var leftover: Array = filled.slice(k)
	for b in leftover:
		if b != null and is_instance_valid(b):
			pool.release(b)
	var live: Array = pool.active_projectiles().duplicate()
	for p in live:
		if p != null and is_instance_valid(p):
			pool.release(p)
	_gl.spawner.active.erase(target)
	epool.release(target)
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	var slots: Array = _gl.player.weapon_slots
	for i in range(slots.size()):
		if slots[i] == w3:
			slots[i] = null
	if is_instance_valid(w3):
		w3.queue_free()
	PerfGovernor.deep_override = -1


func _d11_boss_queue_priority() -> void:
	print("── d11 Boss 优先入队（P2-4 修轮：60 帽下不排队尾） ──")
	var sp: EnemySpawner = _gl.spawner
	sp.spawn_queue.clear()
	sp.enqueue({"data_id": &"E1_grunt", "wave": 1})
	sp.enqueue({"data_id": &"E1_grunt", "wave": 1})
	sp.enqueue({"data_id": &"BOSS_TEST", "wave": 1, "tags": 2}, true)
	_check("d11 优先项插到队首（不排队尾）",
		sp.spawn_queue.size() == 3 and String(sp.spawn_queue[0].get("data_id", "")) == "BOSS_TEST",
		"size=%d front=%s" % [sp.spawn_queue.size(),
			str(sp.spawn_queue[0].get("data_id", "")) if not sp.spawn_queue.is_empty() else "?"])
	_check("d11 普通项仍按 FIFO 追加（队首后两只为普通）",
		sp.spawn_queue.size() == 3
			and String(sp.spawn_queue[1].get("data_id", "")) == "E1_grunt"
			and String(sp.spawn_queue[2].get("data_id", "")) == "E1_grunt", "")
	sp.spawn_queue.clear()


func _cleanup() -> void:
	print("── 收尾（夹具还原） ──")
	# stub 武器槽还原
	var slots: Array = _gl.player.weapon_slots
	if _stub != null and not slots.is_empty():
		if _slot0_added:
			slots[0] = null
		else:
			slots[0] = _slot0_backup
		_stub.free()
		_stub = null
	# 活弹归还（异常路径兜底）
	var pool: ProjectilePool = _gl._projectile_pool
	for p in _acquired:
		if p != null and is_instance_valid(p):
			pool.release(p)
	_acquired.clear()
	# 设置/闩/画布/静态镜像还原
	PerfGovernor.boost_override = -1
	PerfGovernor.deep_override = -1
	PerfGovernor.mode_override = -1
	PerfGovernor.tier_override = -1
	PerfGovernor.set_deep_active(false)
	_gl._deep_on_acc = 0.0
	_gl._deep_off_acc = 0.0
	_gl.get_window().content_scale_size = _saved_css
	if _gl.camera != null:
		_gl.camera.zoom = _saved_zoom
	GameLoop._s_boost_applied_notch = 0
	RunSave.clear()
	Meta._settings = _saved_settings.duplicate()     # 入口快照还原（含 perf_boost/boost_res）
	Meta._save()
	_gl.queue_free()
	await tree.process_frame
	print("验收汇总：%d/%d 通过" % [_pass, _pass + _fail])
	if _fail > 0:
		for f in _failures:
			print("  FAIL 项：%s" % f)

# tests/runner/weapon_orbit_cases.gd
# 武器悬浮层 + W9 随机挥砍 + 环绕飞刀用例体（由 test_weapon_orbit.gd 入口加载）。
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
	_test_avatar_layer()
	_test_muzzle_alignment()
	_test_no_target_gate()
	_test_w9_random_facing()
	_test_energy_orb_visuals()
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


func _add(p_id: StringName) -> WeaponBase:
	return _gl.player.add_weapon(_gl.registry.get_weapon(p_id))


# ── 悬浮层 ────────────────────────────────────────────────────────
func _test_avatar_layer() -> void:
	print("── 武器悬浮层 ──")
	var layer: Node = null
	for c in _gl.player.get_children():
		if c is WeaponOrbitAvatars:
			layer = c
	_check("悬浮层：玩家子节点在册", layer != null)
	if layer == null:
		return
	_add(&"W2_gatling")                            # start_run 已给手枪（槽 0）
	_add(&"W4_pulse_beam")
	for i in range(3):
		layer.call("_process", DT)             # 化身惰性创建 + 可见性同步（无头需手动驱动）
	var live_count := 0
	for w in _gl.player.get("weapon_slots"):
		if w != null and is_instance_valid(w):
			live_count += 1
	var visible_avatars := 0
	for a in layer.get_children():
		if a is Sprite2D and a.visible:
			visible_avatars += 1
	_check("悬浮层：化身数 = 在场武器数（%d）" % live_count, visible_avatars == live_count,
		"visible=%d live=%d" % [visible_avatars, live_count])
	# 均匀分布：可见化身两两角距 ≈ TAU/n（手动驱动 _process——无头模式自跑不生效）
	layer_process()
	var angles: Array[float] = []
	for a in layer.get_children():
		if a is Sprite2D and a.visible:
			angles.append((a.position).angle())
	_check("悬浮层：多武器环绕分布（≥2 化身有角位）", angles.size() >= 2)
	# R25b：化身贴图 = 对应武器图标（「手枪悬浮是个球」回归锁定）
	var tex_ok := true
	for i in range(_gl.player.get("weapon_slots").size()):
		var w = _gl.player.get("weapon_slots")[i]
		if w == null or not is_instance_valid(w):
			continue
		var expect: ImageTexture = TextureFactory.weapon_icon(
			StringName(String(w.get("data").id)))
		if _avatars_ref(i) != expect:
			tex_ok = false
	_check("悬浮层：化身贴图 = 对应武器图标（不是圆珠占位）", tex_ok)
	if angles.size() >= 2:
		angles.sort()
		var spread: float = angles[-1] - angles[0]
		_check("悬浮层：环绕角跨度 > PI/2", spread > PI * 0.5, "%.2f" % spread)
	# 动态重排：拿掉一把 → 可见化身 -1
	for i in range(_gl.player.get("weapon_slots").size()):
		var w = _gl.player.weapon_slots[i]
		if w != null and is_instance_valid(w) and w != _gl.player.weapon_slots[0]:
			_gl.player.weapon_slots[i] = null
			w.free()                           # 即时移除（queue_free 延迟污染计数）
			break
	live_count -= 1
	for i in range(2):
		layer.call("_process", DT)
	visible_avatars = 0
	for a in layer.get_children():
		if a is Sprite2D and a.visible:
			visible_avatars += 1
	_check("悬浮层：拆武器后化身动态重排（-1）", visible_avatars == live_count,
		"visible=%d live=%d" % [visible_avatars, live_count])


# ── R25 发射口对齐（用户点名禁令） ────────────────────────────────
func _test_muzzle_alignment() -> void:
	print("── 发射口对齐 ──")
	_gl.player.global_position = Vector2(360.0, 640.0)   # R30：居中——出生点贴顶会触发
	                                                     # 枪口屏幕钳制，干扰前伸断言
	for i in range(3):
		layer_process()
	var pistol: WeaponBase = _gl.player.weapon_slots[0]
	var muzzle: Vector2 = pistol.call("muzzle_position")
	var avatar_g: Vector2 = _gl.player.call("weapon_muzzle_global", pistol)
	_check("发射口：弹道武器 muzzle = 化身位（≠玩家中心）",
		muzzle.distance_to(avatar_g) < 0.5 and muzzle.distance_to(_gl.player.global_position) > 20.0,
		"muzzle=%s avatar=%s player=%s" % [str(muzzle), str(avatar_g),
			str(_gl.player.global_position)])
	# 实弹出膛位 = 发射口；R30 朝向/枪口尖断言同遍收集（nullify 前取完数据）
	var b0: int = int((_gl.pools[&"projectile"] as ProjectilePool).stats()["live"])
	pistol.call("try_fire")
	var spawned_at_muzzle := false
	var tip_ahead := false
	var tip_dbg := ""
	var av0: Sprite2D = _avatar_node(0)
	var av_center: Vector2 = av0.global_position if av0 != null else Vector2.ZERO
	for p in (_gl.pools[&"projectile"] as ProjectilePool).active_projectiles():
		if p is ProjectileBase and (p as ProjectileBase).team == 0 				and p.get("weapon_ref") == pistol:
			var pos: Vector2 = (p as ProjectileBase).global_position
			if pos.distance_to(muzzle) < 24.0:
				spawned_at_muzzle = true
			var off: Vector2 = pos - av_center
			var bdir: Vector2 = (p as ProjectileBase).velocity.normalized()
			if absf(off.length() - 18.0) < 2.0 and off.normalized().dot(bdir) > 0.99:
				tip_ahead = true
			tip_dbg = "off_len=%.2f dot=%.4f bullet=%s center=%s muzzle=%s" % [
				off.length(), off.normalized().dot(bdir), str(pos), str(av_center), str(muzzle)]
			p.call("nullify")
	_check("发射口：实弹从化身位出膛", spawned_at_muzzle)
	# R30：化身朝向 = 武器开火指向（枪口始终向发射的方向；+X 画布直接取角）
	var aim: Vector2 = pistol.call("aim_direction")
	_check("朝向：化身 rotation 跟随开火指向",
		av0 != null and is_equal_approx(av0.rotation, aim.angle()),
		"rot=%.3f aim_ang=%.3f" % [av0.rotation if av0 != null else -99.0, aim.angle()])
	_check("朝向：子弹从化身前方枪口尖出膛（≈18px 前伸且与弹速同向）", tip_ahead, tip_dbg)
	# 近战保持角色中心（力场/挥砍圆心不变）
	var w8: WeaponBase = _add(&"W8_orbit_field")
	w8.call("try_fire")
	var melee_muzzle: Vector2 = w8.call("muzzle_position")
	_check("近战：力场圆心仍在角色中心（不受化身影响）",
		melee_muzzle.distance_to(_gl.player.global_position) < 0.5,
		"%.1f" % melee_muzzle.distance_to(_gl.player.global_position))
	# 激光保持角色中心（持续束锚定）
	var laser: WeaponBase = _add(&"W4_pulse_beam")
	var laser_muzzle: Vector2 = laser.call("muzzle_position")
	_check("激光：束锚定仍在角色中心", laser_muzzle.distance_to(
		_gl.player.global_position) < 0.5)


# ── R33 无敌人不开火门 ────────────────────────────────────────────
func _test_no_target_gate() -> void:
	print("── 无敌人不开火（R33 门控） ──")
	var pistol: WeaponBase = _gl.player.weapon_slots[0]
	var pool: ProjectilePool = _gl.pools[&"projectile"]
	var live0: int = int(pool.stats()["live"])
	# 场上无敌：tick 不开火、冷却保持就绪
	pistol.cooldown_left = 0.0
	for i in range(12):
		pistol.tick(DT)
	_check("无敌门：tick 不开火（池不增）", int(pool.stats()["live"]) == live0,
		"live=%d→%d" % [live0, int(pool.stats()["live"])])
	_check("无敌门：冷却保持就绪（0）", is_equal_approx(pistol.cooldown_left, 0.0),
		"cd=%.4f" % pistol.cooldown_left)
	# 敌现即射：第一帧就开火进入冷却
	var enemy: Enemy = (_gl.pools[&"enemy"] as EnemyPool).acquire()
	enemy.spawn(_gl.registry.get_enemy(&"E1_grunt"), 10, 0)
	enemy.global_position = _gl.player.global_position + Vector2(0.0, -240.0)
	_gl.spawner.active.append(enemy)
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	pistol.cooldown_left = 0.0
	pistol.tick(DT)
	_check("敌现即射：第一帧开火进冷却", pistol.cooldown_left > 0.0,
		"cd=%.4f" % pistol.cooldown_left)
	_check("敌现即射：池 +1", int(pool.stats()["live"]) == live0 + 1,
		"live=%d" % int(pool.stats()["live"]))
	# 敌灭即停：清场后冷却走完不再开火
	_gl.spawner.active.erase(enemy)
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	(_gl.pools[&"enemy"] as EnemyPool).release(enemy)
	for p in pool.active_projectiles():
		if p is ProjectileBase and (p as ProjectileBase).team == 0:
			p.call("nullify")
	var live2: int = int(pool.stats()["live"])
	while pistol.cooldown_left > 0.0:
		pistol.tick(DT)
	for i in range(6):
		pistol.tick(DT)
	_check("敌灭即停：清场后不再开火", int(pool.stats()["live"]) == live2,
		"live=%d→%d" % [live2, int(pool.stats()["live"])])


func layer_process() -> void:
	var layer: Node = null
	for c in _gl.player.get_children():
		if c is WeaponOrbitAvatars:
			layer = c
	if layer != null:
		for i in range(3):
			layer.call("_process", DT)


func _avatar_node(p_i: int) -> Sprite2D:
	# R30 用例辅助：按槽位取化身 Sprite2D 节点（_ensure_avatars 槽位对齐，子节点序 = 槽位）
	var layer: Node = null
	for c in _gl.player.get_children():
		if c is WeaponOrbitAvatars:
			layer = c
	if layer == null:
		return null
	return layer.get_child(p_i) as Sprite2D


# ── W9 随机挥砍 ───────────────────────────────────────────────────
func _avatars_ref(i: int) -> ImageTexture:
	# 用例辅助：按槽位取化身贴图（与 _ensure_avatars 槽位对齐一致）
	var layer: Node = null
	for c in _gl.player.get_children():
		if c is WeaponOrbitAvatars:
			layer = c
	if layer == null:
		return null
	var kids := layer.get_children()
	if i >= kids.size():
		return null
	return (kids[i] as Sprite2D).texture


func _test_w9_random_facing() -> void:
	print("── W9 随机挥砍 ──")
	_gl.player.set("unlocked_slots", 5)            # 前面用例已占 4 槽
	var w9: WeaponBase = _add(&"W9_arc_slash")
	_check("前置：W9 装配", w9 != null)
	if w9 == null:
		return
	var facings: Array[float] = []
	for i in range(8):
		w9.call("_slash_window")
		facings.append(float(w9.get("arc_slash").get("facing")))
		w9.get("arc_slash").set("window_left", 0.0)   # 关窗（下一窗独立随机）
	var uniq := {}
	for f in facings:
		uniq[f] = true
	_check("W9：挥砍朝向随机化（8 窗 ≥4 个不同朝向）", uniq.size() >= 4,
		"distinct=%d" % uniq.size())
	# 半径逐级成长
	w9.level = 1
	_check("W9：L1 刀范围 150", absf(float(w9.call("_leveled_param", "slash_radius",
		float(w9.data.melee.get("slash_radius", 150.0)))) - 150.0) < 0.001)
	w9.level = 5
	_check("W9：L5 刀范围 230（活动范围放大）",
		absf(float(w9.call("_leveled_param", "slash_radius",
			float(w9.data.melee.get("slash_radius", 150.0)))) - 230.0) < 0.001)

# ── 环绕飞刀 ────────────────────────────────────────────────────
func _test_energy_orb_visuals() -> void:
	print("── 环绕飞刀（R32 默认形态重做） ──")
	# R30 修复：weapon_slots 数组上限 5 且前面用例已占满——此前 _add 返回 null 在
	# 首个断言前崩掉整段（脚本错误不落 fail → 假绿漏测）。复用在场 W8，不再新占槽。
	var w8: WeaponBase = null
	for w in _gl.player.weapon_slots:
		if w != null and is_instance_valid(w) and String(w.data.id).begins_with("W8"):
			w8 = w
			break
	_check("前置：W8 在场", w8 != null, "全槽占满且无 W8（数组上限 5）")
	if w8 == null:
		return
	w8.call("try_fire")
	var field: Node = w8.get("orbit_field")
	_check("前置：力场创建", field != null)
	if field == null:
		return
	_check("默认形态：style 键保持 orb（卡组/升级表契约不变）",
		String(field.get("style")) == "orb")
	_check("飞刀：命中脉冲池就位（刀刃白闪通道）", field.get("_orb_punch") != null)
	# R32：珠核贴图隐藏（刀体程序化绘制，不再是球）；辉光保留并按元素染色
	var cores: Array = field.get("_orb_cores")
	var glows: Array = field.get("_orb_glows")
	_check("飞刀：珠核贴图隐藏（默认不再是球）",
		cores.size() > 0 and not bool((cores[0] as Sprite2D).visible))
	_check("飞刀：辉光底光保留（元素染色通道就位）",
		glows.size() > 0 and bool((glows[0] as Sprite2D).visible))

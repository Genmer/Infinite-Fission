# tests/runner/weapon_orbit_cases.gd
# 武器悬浮层 + W9 随机挥砍 + 环绕能量球用例体（由 test_weapon_orbit.gd 入口加载）。
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
	for i in range(3):
		layer.call("_process", DT)
	var angles: Array[float] = []
	for a in layer.get_children():
		if a is Sprite2D and a.visible:
			angles.append((a.position).angle())
	_check("悬浮层：多武器环绕分布（≥2 化身有角位）", angles.size() >= 2)
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


# ── W9 随机挥砍 ───────────────────────────────────────────────────
func _test_w9_random_facing() -> void:
	print("── W9 随机挥砍 ──")
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

# ── 环绕能量球 ────────────────────────────────────────────────────
func _test_energy_orb_visuals() -> void:
	print("── 环绕能量球 ──")
	var w8: WeaponBase = _add(&"W8_orbit_field")
	w8.call("try_fire")
	var field: Node = w8.get("orbit_field")
	_check("前置：力场创建", field != null)
	if field == null:
		return
	_check("默认形态：style = orb", String(field.get("style")) == "orb")
	_check("能量球：命中脉冲池就位（电火花/内弧绘制通道）",
		field.get("_orb_punch") != null)

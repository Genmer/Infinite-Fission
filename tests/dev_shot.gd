# tests/dev_shot.gd —— 截图自检 harness（不入库：自检后删除）
# 用法：Godot --path /tmp/if_art_c_pop -s tests/dev_shot.gd（非 headless，需窗口）
# 注意：-s 入口脚本编译早于 autoload 全局名注册——本文件禁止出现 EventBus/GameConfig
# 等 autoload 标识符与游戏类静态类型标注（GameConst 为全局 class_name 可用）；
# gl 及子句柄全部走 Variant 动态解析（autoload 就绪后运行期绑定）。
extends SceneTree

var gl = null                                    # GameLoop 实例（动态类型：编译期不可引用）


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	await process_frame
	DirAccess.make_dir_recursive_absolute("res://screens/selfcheck")
	var scene: PackedScene = load("res://scenes/main.tscn")
	gl = scene.instantiate()
	root.add_child(gl)
	print("DEVSHOT boot_ready=", gl.boot_ready)
	await process_frame
	gl.menu_screen.start_requested.emit()
	await _frames(30)
	gl.player.global_position = Vector2(360.0, 1060.0)
	gl.player.invuln_left = 999.0
	# ── 1. 新主角战斗全景（移动喷焰点亮帧） ─────────────────────────
	# 拖动保鲜：每物理帧重投 _drag_accum（120Hz 下每渲染帧 2 tick，tick 后即清零——
	# 单次投递会在拍摄帧被第二个 tick 吃掉，喷焰恒灭）。漂移 ~0.25px/tick 可忽略。
	var keeper := func() -> void:
		if gl != null and is_instance_valid(gl.player):
			gl.player._drag_accum = Vector2(30.0, -10.0)
	physics_frame.connect(keeper)
	await _frames(3)
	gl.player.invuln_left = 0.0              # 拍摄帧脱离无敌闪烁相位 → 满 alpha（呼吸是正常表现）
	await process_frame
	await _shot("01_battle_player_mech")
	physics_frame.disconnect(keeper)
	gl.player.invuln_left = 999.0            # 后续镜头继续防误伤
	# ── 2. 点燃敌 ──────────────────────────────────────────────
	var burn := _spawn_test_enemy(Vector2(240.0, 620.0))
	gl.elemental.apply_attach(burn, GameConst.Element.FIR, 100.0, {"snapshot": 100.0})
	await _frames(50)
	gl.player._drag_accum = Vector2(160.0, -50.0)
	await process_frame
	await _shot("02_enemy_burn")
	# ── 3. 冻结敌（二次满槽 → 完全冻结冰壳） ───────────────────────
	var froz := _spawn_test_enemy(Vector2(470.0, 560.0))
	gl.elemental.apply_attach(froz, GameConst.Element.ICE, 100.0, {})
	await _frames(5)
	gl.elemental.apply_attach(froz, GameConst.Element.ICE, 100.0, {})
	await _frames(6)
	await _shot("03_enemy_frozen")
	# ── 4. 感电 + 连锁闪电瞬间 ───────────────────────────────────
	var src := _spawn_test_enemy(Vector2(360.0, 820.0))
	var near1 := _spawn_test_enemy(Vector2(470.0, 760.0))
	var near2 := _spawn_test_enemy(Vector2(260.0, 900.0))
	await _frames(2)
	gl.elemental.apply_attach(src, GameConst.Element.LTG, 100.0,
		{"hit_damage": 40.0, "snapshot": 100.0})
	await process_frame
	await _shot("04_shock_chain_bolt")
	await _frames(2)
	await _shot("05_shock_chain_bolt2")
	# ── 5. 超导雾（ICE+LTG 双槽 → RXN_ICE_LTG） ───────────────────
	var sup := _spawn_test_enemy(Vector2(360.0, 700.0))
	gl.elemental.apply_attach(sup, GameConst.Element.ICE, 60.0, {})
	gl.elemental.apply_attach(sup, GameConst.Element.LTG, 60.0, {})
	gl.elemental.detect_reactions()
	await _frames(4)
	await _shot("06_superconduct_mist")
	# ── 6. 暂停面板（战斗背景 + HUD 按钮隐藏 + 面板） ──────────────
	gl.request_pause()
	await _frames(3)
	await _shot("07_pause_overlay")
	print("SHOTS-DONE")
	quit(0)


func _spawn_test_enemy(p_pos: Vector2) -> Enemy:
	var data := EnemyData.new()
	data.id = &"E_SHOT"
	data.display_name = "shot"
	data.behavior = GameConst.EnemyBehavior.CHASE
	data.hp_base = 1000000.0
	data.spd_base = 0.0
	data.dmg_base = 0.0
	data.exp_base = 3.0
	data.hitbox_r = 26.0
	var e: Enemy = (gl.pools[&"enemy"] as EnemyPool).acquire()
	e.spawn(data, 1, 0)
	e.position = p_pos
	gl.spawner.active.append(e)
	gl.elemental.register_host(e)
	gl.enemy_grid.rebuild(gl.spawner.active)
	return e


func _frames(p_count: int) -> void:
	for i in range(p_count):
		await process_frame


func _shot(p_name: String) -> void:
	var img: Image = root.get_viewport().get_texture().get_image()
	img.save_png("res://screens/selfcheck/%s.png" % p_name)
	print("SHOT saved: %s" % p_name)

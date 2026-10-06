# tests/runner/r237_contact_radial_cases.gd
# R237 清退刀用例体（入口运行时 load——cases 禁 test_ 前缀防电池 glob 误收）。
# 覆盖：
# ① off 默认零扰动：旗=false 读数 / 池敌 HitArea 构建在位（boot-off 实例）/
#    off 态直驱 tick 不结算（距离内无物理步=R202 ② 白名单语义锁——blink 走位出圈同族）
# ② on 态构建清退：CONTACT_RADIAL=true 下新构敌（Enemy.new+add_child→_ready 读旗）
#    _hit_area==null——敌侧物理面零注册
# ③ on 态行为（池敌运行时翻旗——混态=boot-off 构建但结算走直判分支）：
#    a 距离内 tick 结算（hp 减 contact_dmg） / b 无敌帧节流 / c 出圈不结算 /
#    d 玩家 _dead 闸 / e off 态真物理帧孪生（await physics_frame×2 信号 arm 后 tick
#    同减量——双模结算等价对拍，r202_g3 ②a 同款驱动）
# ④ player 源级锚：惰化块（if Enemy.CONTACT_RADIAL → layer 0+双 monitoring 关）恰 1 处
# ⑤ 旗复位（teardown 后 false=源默认关态，等归因 verdict 翻开）
# ⑥ 套件总项数断言（R231 假绿教训）
# E4 引爆线走 VOLATILE_TRIGGER_SLACK 独立距离通道，不在本刀面（头注披露非断言）。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const PLAYER_SOURCE := "res://scripts/entities/player/player.gd"
const DT := 1.0 / 60.0
const EXPECTED_TOTAL := 12

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(20261007)
	await _boot_game_loop()
	await tree.process_frame
	await tree.process_frame
	_gl.state = GameConst.GameStatus.MENU             # 静止环境（r230/r236 先例）
	PerfGovernor.set_process(false)
	GameLoop.SIM_30HZ_ENABLED = false
	GameLoop.sim30_override = -1
	_test_1_off_zero_perturbation()
	await _test_2_on_construction_retreat()
	_test_3_on_behavior()
	await _test_3e_off_physics_twin()
	_test_4_player_source_anchor()
	await _cleanup()
	_check("⑤ 旗复位=源默认关态（teardown 后 CONTACT_RADIAL==false）",
		Enemy.CONTACT_RADIAL == false, str(Enemy.CONTACT_RADIAL))
	_check("⑥ 套件总项数（EXPECTED=%d——R231 假绿教训）" % EXPECTED_TOTAL,
		_pass + _fail + 1 == EXPECTED_TOTAL, "实得 %d" % (_pass + _fail + 1))
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)
	print("验收汇总：%d/%d 通过" % [_pass, _pass + _fail])


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


func _boot_game_loop() -> void:
	var main: Node = load(MAIN_SCENE).instantiate()
	tree.root.add_child(main)
	await tree.process_frame
	_gl = tree.root.get_node_or_null("Main") as GameLoop
	if _gl == null:
		for c in tree.root.get_children():
			if c is GameLoop:
				_gl = c
				break


func _fixture_enemy(p_id: StringName, p_hp: float, p_dmg: float = 0.0) -> EnemyData:
	# r202_g3_enemyhot_cases.gd:64 同款夹具（静态：spd 0 / 可配 dmg）
	var d := EnemyData.new()
	d.id = p_id
	d.display_name = String(p_id)
	d.hp_base = p_hp
	d.spd_base = 0.0
	d.dmg_base = p_dmg
	d.exp_base = 1.0
	d.hitbox_r = 14.0
	d.resist = [0.0, 0.0, 0.0, 0.0]
	return d


func _acquire(p_id: StringName, p_hp: float = 100.0, p_dmg: float = 0.0) -> Enemy:
	var enemy := (_gl.pools[&"enemy"] as EnemyPool).acquire()
	enemy.spawn(_fixture_enemy(p_id, p_hp, p_dmg), 1, 0)
	return enemy


func _release(p_enemy: Enemy) -> void:
	(_gl.pools[&"enemy"] as EnemyPool).release(p_enemy)


# ═══ ① off 默认零扰动 ═════════════════════════════════════════
func _test_1_off_zero_perturbation() -> void:
	print("── ① off 默认零扰动（信号通道原语义） ──")
	_check("①a 默认旗=false（boot 后读数——vc41 翻开前源默认）",
		Enemy.CONTACT_RADIAL == false, str(Enemy.CONTACT_RADIAL))
	var player := _gl.player
	var enemy := _acquire(&"E_R237_OFF", 100.0, 25.0)
	enemy.global_position = player.global_position + Vector2(1000.0, 0.0)
	_check("①b 池敌 HitArea 构建在位（boot-off 实例——_hit_area!=null 信号通道完整）",
		enemy._hit_area != null, str(enemy._hit_area))
	player.hp = 1000.0
	player.invuln_left = 0.0
	player._dead = false
	enemy.global_position = player.global_position + Vector2(20.0, 0.0)   # < reach 30
	enemy.tick(DT)                                                        # 直驱无物理步
	_check("①c off 态直驱 tick 不结算（距离内无物理步——R202 ② 白名单语义锁）",
		absf(player.hp - 1000.0) < 0.001, "hp=%.1f" % player.hp)
	_release(enemy)


# ═══ ② on 态构建清退 ══════════════════════════════════════════
func _test_2_on_construction_retreat() -> void:
	print("── ② on 态构建清退（新构敌零 HitArea） ──")
	Enemy.CONTACT_RADIAL = true
	var fresh := Enemy.new()
	tree.root.add_child(fresh)                # _ready 读旗 → 跳过 _build_contact_area
	_check("②a on 态新构敌 _hit_area==null（敌侧物理面零注册）",
		fresh._hit_area == null, str(fresh._hit_area))
	fresh.queue_free()
	Enemy.CONTACT_RADIAL = false


# ═══ ③ on 态行为（池敌运行时翻旗=混态：boot-off 构建+直判结算分支） ═══
func _test_3_on_behavior() -> void:
	print("── ③ on 态行为（双半径直判） ──")
	Enemy.CONTACT_RADIAL = true
	var player := _gl.player
	var enemy := _acquire(&"E_R237_ON", 100.0, 25.0)   # contact_dmg 25（无 affix ×1）
	enemy.global_position = player.global_position + Vector2(1000.0, 0.0)
	var reach: float = float(enemy.hitbox_r) + float(player.hitbox_radius)
	# ③a 距离内直驱结算
	player.hp = 1000.0
	player.invuln_left = 0.0
	player._dead = false
	enemy.global_position = player.global_position + Vector2(reach - 2.0, 0.0)
	enemy.tick(DT)
	_check("③a on 态距离内 tick 结算（hp 减 contact_dmg=25——直驱即结算，混态旗优先）",
		absf(player.hp - 975.0) < 0.001, "hp=%.1f" % player.hp)
	# ③b 无敌帧节流（take_contact_damage 内闸不变）
	enemy.tick(DT)
	_check("③b on 态无敌帧节流（第二 tick 零结算——contact_tick 闸不变）",
		absf(player.hp - 975.0) < 0.001, "hp=%.1f" % player.hp)
	# ③c 出圈不结算
	player.hp = 1000.0
	player.invuln_left = 0.0
	enemy.global_position = player.global_position + Vector2(reach + 2.0, 0.0)
	enemy.tick(DT)
	_check("③c on 态出圈不结算（reach+2 距离²比较口径）",
		absf(player.hp - 1000.0) < 0.001, "hp=%.1f" % player.hp)
	# ③d 玩家 _dead 闸
	enemy.global_position = player.global_position + Vector2(10.0, 0.0)
	player._dead = true
	player.invuln_left = 0.0
	player.hp = 1000.0
	enemy.tick(DT)
	_check("③d on 态玩家 _dead 闸（死亡态零结算——闸在 take_contact_damage 内）",
		absf(player.hp - 1000.0) < 0.001, "hp=%.1f" % player.hp)
	player._dead = false
	Enemy.CONTACT_RADIAL = false
	_release(enemy)


# ═══ ③e off 态真物理帧孪生（双模结算等价对拍） ═════════════════
func _test_3e_off_physics_twin() -> void:
	print("── ③e off 态真物理帧孪生（r202_g3 ②a 同款驱动） ──")
	Enemy.CONTACT_RADIAL = false
	var player := _gl.player
	var enemy := _acquire(&"E_R237_TWIN", 100.0, 25.0)
	enemy.global_position = player.global_position + Vector2(1000.0, 0.0)
	player.hp = 1000.0
	player.invuln_left = 0.0
	player._dead = false
	enemy.global_position = player.global_position + Vector2(20.0, 0.0)   # < reach 30
	await tree.physics_frame
	await tree.physics_frame              # 两次物理冲刷 → area_entered 旗 arm（R202 实证）
	enemy.tick(DT)
	_check("③e off 态物理孪生（信号 arm 后 tick 结算同减量 25——双模等价对拍）",
		absf(player.hp - 975.0) < 0.001, "hp=%.1f" % player.hp)
	_release(enemy)


# ═══ ④ player 源级锚 ══════════════════════════════════════════
func _test_4_player_source_anchor() -> void:
	print("── ④ player 源级锚（惰化块恰 1 处） ──")
	var src := ""
	var fa := FileAccess.open(PLAYER_SOURCE, FileAccess.READ)
	if fa != null:
		src = fa.get_as_text().replace("\r\n", "\n")
		fa.close()
	_check("④a player 源级惰化锚（if Enemy.CONTACT_RADIAL: → layer 0+双 monitoring 关 恰 1 处）",
		src.count("if Enemy.CONTACT_RADIAL:") == 1, "count=%d" % src.count("if Enemy.CONTACT_RADIAL:"))


func _cleanup() -> void:
	Enemy.CONTACT_RADIAL = false
	PerfGovernor.set_process(true)
	_gl.state = GameConst.GameStatus.MENU
	var player := _gl.player
	if player != null and is_instance_valid(player):
		player._dead = false
		player.invuln_left = 0.0

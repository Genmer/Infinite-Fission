# tests/runner/rcv_sanctuary_cases.gd
# 二cv#6 近战敌贴脸豁免用例体（入口运行时 load——cases 禁 test_ 前缀防电池 glob 误收）。
# 覆盖：
# ① 惰性锚：无近战武器 fold 后 melee_sanctuary_r==0 + CHASE 敌贴身照常结算（纯远程
#    构筑威胁模型零扰动回归锚）
# ② 豁免生效（W9 装备态）：fold=补刀刃圈 150 / 贴身 tick 零结算 / 抑制计数自增 /
#    off 态信号通道孪生（r202 ②a 同款驱动——双模守卫等价）
# ③ 作用域对照：RANGED 行为敌贴身仍结算（豁免只对追击型）
# ④ 作用域对照：TAG_BOSS 的 CHASE 敌贴身仍结算（Boss 冲锋伤害同走接触通道必须排除）
# ⑤ 通道隔离（E4 自爆）：贴身后 fuse 仍 arm + 接触结算被抑制 + 引爆线照常落血
#    （VOLATILE_TRIGGER_SLACK 独立通道不受守卫面）
# ⑥ 半径对拍：melee_sanctuary_r == effective_slash_radius()（同源断言）+ 双近战取
#    max（R245 表值迁移：W9 L1=150 > W13 L1=130——W9 圈胜出）+ W13 L1 表值 130 数值锚
# ⑦ 旗复位 + 套件总项数断言（R231 假绿教训，r237 同款）
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const DT := 1.0 / 60.0
const EXPECTED_TOTAL := 18

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null
var _melee_weapons: Array[WeaponBase] = []   # 清场登记（add_weapon 真件——测试尾统一回收）


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(20261009)
	await _boot_game_loop()
	await tree.process_frame
	await tree.process_frame
	_gl.state = GameConst.GameStatus.MENU             # 静止环境（r230/r236 先例）
	PerfGovernor.set_process(false)
	GameLoop.SIM_30HZ_ENABLED = false
	GameLoop.sim30_override = -1
	Enemy.CONTACT_RADIAL = true                       # 全套件直判模（teardown 复位——r237:212 同款）
	_gl.player.set("unlocked_slots", 5)               # 三槽连装（W9+W13）前置
	_test_1_inert_baseline()
	await _test_2_sanctuary_on()
	_test_3_ranged_untouched()
	_test_4_boss_untouched()
	await _test_5_volatile_channel()
	await _test_6_radius_parity()
	await _cleanup()
	_check("⑦a 旗复位=源默认关态（teardown 后 CONTACT_RADIAL==false）",
		Enemy.CONTACT_RADIAL == false, str(Enemy.CONTACT_RADIAL))
	_check("⑦b 套件总项数（EXPECTED=%d——R231 假绿教训）" % EXPECTED_TOTAL,
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


func _fixture_enemy(p_id: StringName, p_hp: float, p_dmg: float = 25.0) -> EnemyData:
	# r237_contact_radial_cases.gd:84 同款夹具（静态：spd 0 / 可配 dmg；behavior 默认 CHASE）
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


func _acquire(p_id: StringName, p_hp: float = 100.0, p_dmg: float = 25.0,
		p_tags: int = 0) -> Enemy:
	var enemy := (_gl.pools[&"enemy"] as EnemyPool).acquire()
	enemy.spawn(_fixture_enemy(p_id, p_hp, p_dmg), 1, p_tags)
	return enemy


func _release(p_enemy: Enemy) -> void:
	(_gl.pools[&"enemy"] as EnemyPool).release(p_enemy)


func _arm_player(p_hp: float = 1000.0) -> void:
	# 接触结算前置态：满血 + 无无敌帧 + 活体（r237 ③a 同款三连复位）
	_gl.player.hp = p_hp
	_gl.player.invuln_left = 0.0
	_gl.player._dead = false


func _equip_melee(p_id: StringName) -> WeaponBase:
	# add_weapon 真链（r243_melee_cases.gd:127 同款——deps/registry/横幅全真）
	var w := _gl.player.add_weapon(_gl.registry.get_weapon(p_id))
	if w != null:
		_melee_weapons.append(w)
	return w


# ═══ ① 惰性锚（无近战武器=规则完全不参与） ══════════════════════
func _test_1_inert_baseline() -> void:
	print("── ① 惰性锚（首发手枪局——守卫恒假零扰动） ──")
	var player := _gl.player
	player.tick(DT, Vector2.ZERO)                 # fold 走一遍——证明折算本身对纯远程恒 0
	_check("①a 无近战武器 fold 后 melee_sanctuary_r==0（守卫惰性之源）",
		absf(player.melee_sanctuary_r) < 0.001, "r=%.2f" % player.melee_sanctuary_r)
	var enemy := _acquire(&"E_RCV_A", 100.0, 25.0)
	_arm_player()
	enemy.global_position = player.global_position + Vector2(20.0, 0.0)   # < reach 30
	enemy.tick(DT)
	_check("①b 惰性态贴身照常结算（hp 1000→975——既有接触规则回归锚）",
		absf(player.hp - 975.0) < 0.001, "hp=%.1f" % player.hp)
	_release(enemy)


# ═══ ② 豁免生效（W9 装备态） ══════════════════════════════════
func _test_2_sanctuary_on() -> void:
	print("── ② 豁免生效（W9 补刀刃圈 150） ──")
	var player := _gl.player
	var w9 := _equip_melee(&"W9_arc_slash")
	_check("②前置 W9 装槽成功", w9 != null, str(w9))
	var cnt0: int = DebugStats.get_counter(&"melee_enemy_suppressed")
	player.tick(DT, Vector2.ZERO)                 # 折算圈（玩家侧逐帧口径——真实生效路径）
	_check("②a fold 后 melee_sanctuary_r==W9 刃圈 150（L1 无词条）",
		absf(player.melee_sanctuary_r - 150.0) < 0.01,
		"r=%.2f" % player.melee_sanctuary_r)
	var enemy := _acquire(&"E_RCV_B", 100.0, 25.0)
	_arm_player()
	enemy.global_position = player.global_position + Vector2(20.0, 0.0)   # ⊂ 刃圈 150
	enemy.tick(DT)
	_check("②b 贴身 tick 零结算（hp 1000 不动——补刀圈内近战敌攻击不生效）",
		absf(player.hp - 1000.0) < 0.001, "hp=%.1f" % player.hp)
	_check("②c 抑制计数自增（DebugStats melee_enemy_suppressed 判读口）",
		DebugStats.get_counter(&"melee_enemy_suppressed") > cnt0,
		"cnt %d→%d" % [cnt0, DebugStats.get_counter(&"melee_enemy_suppressed")])
	# ②d off 态信号通道孪生（CONTACT_RADIAL=false + 物理重叠旗 arm——r202 ②a 同款驱动；
	# 守卫 on/off 双分支共用，off 分支独立成口故单独锁定）
	Enemy.CONTACT_RADIAL = false
	cnt0 = DebugStats.get_counter(&"melee_enemy_suppressed")
	_arm_player()
	await tree.physics_frame
	await tree.physics_frame              # 两次物理冲刷 → area_entered 旗 arm
	enemy.tick(DT)
	_check("②d off 态信号通道同被豁免（旗 arm 后 tick 仍零结算 + 计数自增）",
		absf(player.hp - 1000.0) < 0.001
		and DebugStats.get_counter(&"melee_enemy_suppressed") > cnt0,
		"hp=%.1f cnt %d→%d" % [player.hp, cnt0,
		DebugStats.get_counter(&"melee_enemy_suppressed")])
	Enemy.CONTACT_RADIAL = true
	_release(enemy)


# ═══ ③ 作用域对照：RANGED 行为不豁免 ═══════════════════════════
func _test_3_ranged_untouched() -> void:
	print("── ③ 作用域对照（RANGED 行为敌仍结算） ──")
	var player := _gl.player
	var data := _fixture_enemy(&"E_RCV_R", 100.0, 25.0)
	data.behavior = GameConst.EnemyBehavior.RANGED
	var enemy := (_gl.pools[&"enemy"] as EnemyPool).acquire()
	enemy.spawn(data, 1, 0)
	_arm_player()
	enemy.global_position = player.global_position + Vector2(20.0, 0.0)
	enemy.tick(DT)
	_check("③ RANGED 行为贴身仍结算（hp 1000→975——豁免只对追击型）",
		absf(player.hp - 975.0) < 0.001, "hp=%.1f" % player.hp)
	_release(enemy)


# ═══ ④ 作用域对照：Boss 不豁免 ═════════════════════════════════
func _test_4_boss_untouched() -> void:
	print("── ④ 作用域对照（Boss 冲锋接触不豁免） ──")
	var player := _gl.player
	var enemy := _acquire(&"E_RCV_BOSS", 100.0, 25.0, GameConst.TAG_BOSS)
	_check("④前置 Boss 夹具 is_boss 真",
		enemy.is_boss() and enemy.behavior == GameConst.EnemyBehavior.CHASE,
		"boss=%s behavior=%d" % [str(enemy.is_boss()), enemy.behavior])
	_arm_player()
	enemy.global_position = player.global_position + Vector2(20.0, 0.0)
	enemy.tick(DT)
	_check("④ Boss 贴身仍结算（hp 1000→975——冲锋伤害同走接触通道必须放行）",
		absf(player.hp - 975.0) < 0.001, "hp=%.1f" % player.hp)
	_release(enemy)


# ═══ ⑤ 通道隔离：E4 自爆引爆线不受守卫面 ═══════════════════════
func _test_5_volatile_channel() -> void:
	print("── ⑤ 通道隔离（E4 引爆线照常） ──")
	var player := _gl.player
	var data := _fixture_enemy(&"E4_volatile", 100.0, 25.0)
	var bug := (_gl.pools[&"enemy"] as EnemyPool).acquire()
	bug.spawn(data, 1, 0)
	_arm_player()
	bug.global_position = player.global_position + Vector2(20.0, 0.0)
	bug.tick(DT)
	# 同拍双断言：接触结算被豁免（②b 同口径）但引爆触发线照常 arm——
	# 通道隔离的真义是「豁免不外溢」：贴脸保护拦磨血，不拦自爆机制本身
	_check("⑤a E4 贴身接触仍被豁免（hp 1000 不动——守卫面覆盖但不过度）",
		absf(player.hp - 1000.0) < 0.001, "hp=%.1f" % player.hp)
	_check("⑤b E4 引爆触发线照常 arm（fuse_armed 真——VOLATILE_TRIGGER_SLACK 独立通道）",
		bool(bug.fuse_armed()), "armed=%s" % str(bug.fuse_armed()))
	# 引爆线落血：清引信尾差 → 下一 tick 走 _explode（20px ⊂ 爆径 110）→
	# _explode 直调 take_contact_damage 不经守卫——hp 必减（引爆完池自归还不二次 release）
	bug.set("_fuse_left", 0.0)
	_arm_player()
	bug.tick(DT)
	_check("⑤c E4 引爆照常落血（hp 1000→975——爆炸通道未被守卫拦截）",
		absf(player.hp - 975.0) < 0.001, "hp=%.1f" % player.hp)


# ═══ ⑥ 半径对拍（同源 + max 语义） ═════════════════════════════
func _test_6_radius_parity() -> void:
	print("── ⑥ 半径对拍（effective_slash_radius 同源） ──")
	var player := _gl.player
	var w13 := _equip_melee(&"W13_great_sword")
	_check("⑥前置 W13 装槽成功", w13 != null, str(w13))
	player.tick(DT, Vector2.ZERO)
	var w13_r: float = (w13 as OrbitWeapon).effective_slash_radius()
	_check("⑥a 双近战 fold 取 max（R245 表值迁移：W9 L1 150 > W13 L1 130——圈=较大者胜出）",
		absf(player.melee_sanctuary_r - 150.0) < 0.01 and w13_r < 150.0,
		"fold=%.2f w13=%.2f" % [player.melee_sanctuary_r, w13_r])
	_check("⑥b W13 L1 表值锚 130（R245 表值迁移——slash_radius_levels[0] 下压）",
		absf(w13_r - 130.0) < 0.01,
		"r=%.2f" % w13_r)


# ═══ 清场（共享态零残留） ══════════════════════════════════════
func _cleanup() -> void:
	Enemy.CONTACT_RADIAL = false
	PerfGovernor.set_process(true)
	_gl.state = GameConst.GameStatus.MENU
	var player := _gl.player
	if player != null and is_instance_valid(player):
		for i in range(player.weapon_slots.size()):
			var w: WeaponBase = player.weapon_slots[i]
			if w != null and _melee_weapons.has(w):
				player.weapon_slots[i] = null
				w.queue_free()
		player.melee_sanctuary_r = 0.0               # 防残留圈外溢到同进程后续套件
		player._dead = false
		player.invuln_left = 0.0
	_melee_weapons.clear()
	await tree.process_frame

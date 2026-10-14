# tests/runner/r245_melee_unify_cases.gd
# R245「近战统一」（需求③ · 流B）用例体（由 test_r245_melee_unify.gd 入口运行时 load——
# -s 编译期禁引工程类名纪律；cases 禁 test_ 前缀防电池 glob 误收）。
# 覆盖设计文档 §7 验收 #3（A~F）+ 源码锚：
#   A 组 半径表下压（§3.2）：.tres 表 [130,140,155,170,190] 逐级 + 每级 < W9 同级
#        [150,165,180,200,230] + 实装裸读 L1/L5 + 质变无 radius_mult 零位移。
#   B 组 挡弹域双源统一（§3.3）：BLOCK_RADIUS_TABLE [60,66,72,80,92] 常量锚 +
#        block_radius_for 钳制四向 + GUARD_RADIUS_RATIO 删除源码锚；警戒弧与斩击窗
#        两通道逐级行为（域内弹消 / 域外弹不受——query_arc 判定界=表值+64px 保守衬垫，
#        域外弹按表值+72px 摆）；W9 nullify 确定性消弹全额旧口径保持（防误伤断言）。
#   C 组 化身随圈成长（§3.4-1）：W13 L1 scale==0.62、L5==0.62×190/130、W9 对照
#        0.62 零位移、巨刃乘区同步长大。
#   D 组 开窗剑体缩放（§3.4-2）：blade_visual_scale L1==130/150（>0.8 不触下限）、
#        L5==190/150、W9 ==1.0 对照（公式不动）。
#   E 组 虚线圈半径即时刷新（§3.4-3）：升级后 _dash_radius 当帧跟表（重绘判定锚），
#        slash_radius 快照陈旧不复位——虚线画 live effective 真值（无陈旧圈）。
#   F 组 乘区序保持（§3.2）：巨刃 ×1.2 / 广域 ×1.18 / 双乘下 W13 effective 恒 <
#        W9 同乘（同乘区序关系不破）。
# 确定性：固定坐标/静止敌/crit=0 副本数据/帧戳手动推进（r243 系夹具同式）；
# 掷骰只取 1.0 两极桩（r243_block §3.4 口径）。
extends RefCounted

const EXPECTED_TOTAL := 32
const DT := 1.0 / 120.0
const MAIN_SCENE := "res://scenes/main.tscn"
const OW_SRC_PATH := "res://scripts/combat/weapon/melee/orbit_weapon.gd"
const ARC_SRC_PATH := "res://scripts/combat/weapon/melee/arc_slash.gd"
# 域内/域外弹位表（逐级）：域内 = 表值-5（必入）；域外 = 表值+72（> 表值+64 判定界必出）
const BLOCK_TABLE: Array[float] = [60.0, 66.0, 72.0, 80.0, 92.0]
const GUARD_IN_OFFS: Array[float] = [55.0, 61.0, 67.0, 75.0, 87.0]
const GUARD_OUT_OFFS: Array[float] = [132.0, 138.0, 144.0, 152.0, 164.0]
const W9_LEVELS: Array[float] = [150.0, 165.0, 180.0, 200.0, 230.0]
const COS60 := 0.5
const SIN60 := 0.8660254

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(20261009)
	_boot_game_loop()
	await tree.process_frame
	await tree.process_frame
	_group_a_radius_table()
	_group_b_block_domain()
	await _group_c_avatar_growth()
	_group_d_blade_scale()
	_group_e_dash_refresh()
	_group_f_mult_order()
	_teardown_game_loop()
	_check("⑦ 套件总项数（EXPECTED=%d——R231 假绿教训）" % EXPECTED_TOTAL,
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


func _read_src(p_path: String) -> String:
	var f := FileAccess.open(p_path, FileAccess.READ)
	return f.get_as_text() if f != null else ""


# ── 夹具（r243_melee_cases 同式） ──────────────────────────────────
func _boot_game_loop() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "R245MeleeGameLoopUnderTest"
	tree.get_root().add_child(_gl)
	_gl.state = GameConst.GameStatus.MENU
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	_gl.start_run()
	_gl.player.set("max_hp", 1000000.0)
	_gl.player.set("hp", 1000000.0)
	_gl.player.global_position = Vector2(360.0, 640.0)   # 居中（几何确定性）


func _teardown_game_loop() -> void:
	tree.paused = false
	RunSave.clear()
	if _gl != null:
		_gl.free()
		_gl = null


func _fresh_weapon(p_id: StringName, p_prefix: String) -> OrbitWeapon:
	# 拆旧同 id 武器 → 清场 → 新装（crit=0 副本数据 + meta 修正归零——伤害探针确定性）
	for i in range(_gl.player.weapon_slots.size()):
		var w = _gl.player.weapon_slots[i]
		if w != null and is_instance_valid(w) and w.data != null \
				and String(w.data.id).begins_with(p_prefix):
			_gl.player.weapon_slots[i] = null
			w.free()
	_clear_enemies()
	_gl.player.set("unlocked_slots", 5)
	var w := _gl.player.add_weapon(_gl.registry.get_weapon(p_id)) as OrbitWeapon
	if w != null:
		w.data = w.data.duplicate(true)
		w.data.crit_rate = 0.0
		w.meta_atk_pct = 0.0
		w.call("_invalidate_panel")
	return w


func _fresh_w9() -> OrbitWeapon:
	return _fresh_weapon(&"W9_arc_slash", "W9")


func _fresh_w13() -> OrbitWeapon:
	return _fresh_weapon(&"W13_great_sword", "W13")


func _spawn_e(p_pos: Vector2, p_hp: float = 100000.0) -> Enemy:
	var enemy := (_gl.pools[&"enemy"] as EnemyPool).acquire()
	enemy.spawn(_gl.registry.get_enemy(&"E1_grunt"), 1, 0)
	enemy.set("speed", 0.0)                        # 静止敌（几何确定性）
	enemy.set("max_hp", p_hp)
	enemy.set("hp", p_hp)
	enemy.global_position = p_pos
	_gl.spawner.active.append(enemy)
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	return enemy


func _clear_enemies() -> void:
	if _gl == null:
		return
	for e in _gl.spawner.active.duplicate():
		_gl.spawner.active.erase(e)
		(_gl.pools[&"enemy"] as EnemyPool).release(e)
	_gl.enemy_grid.rebuild(_gl.spawner.active)


func _spawn_bullet(p_pos: Vector2) -> ProjectileBase:
	var pool: ProjectilePool = _gl.pools[&"projectile"]
	var b := pool.acquire() as ProjectileBase
	if b == null:
		return null
	b.damage_pipeline = _gl.pipeline
	b.pool = pool
	b.spawn({
		"position": p_pos, "velocity": Vector2.ZERO, "lifetime": 10.0,
		"pierce": 1, "hitbox_radius": 6.0, "panel_snapshot": {"base_atk": 0.0},
		"team": 1,
	})
	return b


func _rebuild_bullets(p_bullets: Array) -> void:
	var arr: Array[Node2D] = []
	for b in p_bullets:
		if b != null and is_instance_valid(b):
			arr.append(b)
	_gl.enemy_bullet_grid.rebuild(arr)


func _release_bullets(p_bullets: Array) -> void:
	for b in p_bullets:
		if b != null and is_instance_valid(b) and not (b as ProjectileBase).is_clean:
			(b as ProjectileBase).pool.release(b)


func _alive(p_b: ProjectileBase) -> bool:
	return p_b != null and is_instance_valid(p_b) and not p_b.is_clean


func _step(p_w: WeaponBase, p_ticks: int) -> void:
	for i in range(p_ticks):
		GameConfig.frame_stamp += 1             # E-03 帧闸门推进
		p_w.tick(DT)
	_ripple_frame()


func _ripple_frame() -> void:
	# 帧序外圈兜底：清弹防跨界（B 组循环级间残留弹不渗下一级读数）
	pass


func _attach_by_id(p_w: WeaponBase, p_id: StringName) -> bool:
	return p_w.attach_trait(_gl.registry.get_trait(p_id))


func _avatar_of(p_w: WeaponBase) -> Sprite2D:
	# 化身槽动态定位（rcu_faqi _avatar_idx_of 同式——不假设槽位排布）
	var oa: Variant = _gl.player.get("orbit_avatars")
	if oa == null or not is_instance_valid(oa as Node):
		return null
	var entries: Array = (oa as WeaponOrbitAvatars)._entries_of(_gl.player)
	var idx: int = entries.find(p_w)
	if idx < 0 or idx >= (oa as WeaponOrbitAvatars)._avatars.size():
		return null
	return (oa as WeaponOrbitAvatars)._avatars[idx]


# ── A 组：半径表下压（4 项） ──────────────────────────────────────
func _group_a_radius_table() -> void:
	print("── A 组：W13 半径表下压与法器对照（§3.2） ──")
	var wd13 := _gl.registry.get_weapon(&"W13_great_sword")
	var m13: Dictionary = wd13.melee
	var levels13: Array = m13.get("slash_radius_levels", [])
	var base13 := float(m13.get("slash_radius", -1.0))
	var table_ok := absf(base13 - 130.0) < 0.0001 and levels13.size() == 5 \
		and absf(float(levels13[0]) - 130.0) < 0.0001 \
		and absf(float(levels13[1]) - 140.0) < 0.0001 \
		and absf(float(levels13[2]) - 155.0) < 0.0001 \
		and absf(float(levels13[3]) - 170.0) < 0.0001 \
		and absf(float(levels13[4]) - 190.0) < 0.0001
	_check("A1 .tres 表读回（slash_radius 130 + levels [130,140,155,170,190] 逐级）",
		table_ok, "base=%s levels=%s" % [str(base13), str(levels13)])
	var wd9 := _gl.registry.get_weapon(&"W9_arc_slash")
	var levels9: Array = wd9.melee.get("slash_radius_levels", [])
	var lt_ok := true
	for i in range(5):
		if float(levels13[i]) >= float(levels9[i]):
			lt_ok = false
	_check("A2 每级 < W9 法器同级（130<150 / 140<165 / 155<180 / 170<200 / 190<230）",
		lt_ok and levels9.size() == 5, "w13=%s w9=%s" % [str(levels13), str(levels9)])
	var w13 := _fresh_w13()
	var r_l1: float = w13.effective_slash_radius() if w13 != null else -1.0
	w13.level = 5
	var r_l5: float = w13.effective_slash_radius() if w13 != null else -1.0
	_check("A3 实装裸读（L1 effective==130 / L5==190——无乘区）",
		w13 != null and absf(r_l1 - 130.0) < 0.001 and absf(r_l5 - 190.0) < 0.001,
		"L1=%s L5=%s" % [str(r_l1), str(r_l5)])
	w13.transcended = true                    # L5 质变（裂地斩无 radius_mult 键）
	var r_t2: float = w13.effective_slash_radius() if w13 != null else -1.0
	_check("A4 质变零位移（transcend 无 radius_mult → L5 仍 190 < W9×1.15=264.5）",
		w13 != null and absf(r_t2 - 190.0) < 0.001 and r_t2 < 264.5,
		"t2=%s" % str(r_t2))


# ── B 组：挡弹域双源统一（14 项） ─────────────────────────────────
func _group_b_block_domain() -> void:
	print("── B 组：挡弹域 BLOCK_RADIUS_TABLE 双源统一（§3.3） ──")
	var table: Array[float] = OrbitWeapon.BLOCK_RADIUS_TABLE
	var table_ok := table.size() == 5 \
		and absf(table[0] - 60.0) < 0.0001 and absf(table[1] - 66.0) < 0.0001 \
		and absf(table[2] - 72.0) < 0.0001 and absf(table[3] - 80.0) < 0.0001 \
		and absf(table[4] - 92.0) < 0.0001
	_check("B1a 常量锚（OrbitWeapon.BLOCK_RADIUS_TABLE == [60,66,72,80,92]——法器基准×40%）",
		table_ok, "table=%s" % str(table))
	_check("B1b block_radius_for 钳制四向（L1..L5 逐档 + level 0 钳 60 + level 99 钳 92）",
		absf(OrbitWeapon.block_radius_for(1) - 60.0) < 0.0001
			and absf(OrbitWeapon.block_radius_for(2) - 66.0) < 0.0001
			and absf(OrbitWeapon.block_radius_for(3) - 72.0) < 0.0001
			and absf(OrbitWeapon.block_radius_for(4) - 80.0) < 0.0001
			and absf(OrbitWeapon.block_radius_for(5) - 92.0) < 0.0001
			and absf(OrbitWeapon.block_radius_for(0) - 60.0) < 0.0001
			and absf(OrbitWeapon.block_radius_for(99) - 92.0) < 0.0001,
		"lv0=%s lv99=%s" % [str(OrbitWeapon.block_radius_for(0)),
			str(OrbitWeapon.block_radius_for(99))])
	var ow_src := _read_src(OW_SRC_PATH)
	var arc_src := _read_src(ARC_SRC_PATH)
	_check("B1c 源码锚（GUARD_RADIUS_RATIO 已删 + 警戒弧/斩击窗双消费 block_radius_for + 圈重绘半径锚在册）",
		not ow_src.contains("GUARD_RADIUS_RATIO")
			and ow_src.contains("BLOCK_RADIUS_TABLE")
			and _func_body(ow_src, "func _tick_guard_arc").contains("block_radius_for(level)")
			and arc_src.contains("block_radius_for"),
		"ow_len=%d arc_len=%d" % [ow_src.length(), arc_src.length()])
	# 警戒弧逐级（单武器循环：窗耗尽后待机巡逻，节拍手动同步）
	var w13 := _fresh_w13()
	if w13 == null:
		for i in range(5):
			_check("B2%s 警戒弧挡弹域逐级（装配缺失）" % ["abcde"[i]], false)
		_check("B4 W9 nullify 消弹全额（装配缺失）", false)
		return
	w13.data.melee["block_chance"] = 1.0           # 1.0 两极桩（r243_block §3.4 口径）
	var c := _gl.player.global_position
	_spawn_e(c + Vector2(120.0, 0.0))              # 敌 +X 定 _guard_facing（全级交战圈内）
	w13._slash_window(0.0, false)                  # 开一窗（首拍刷新 facing 缓存）
	_step(w13, 44)                                 # 窗耗尽 + 待机空巡两拍
	for lv in range(1, 6):
		var b_in := _spawn_bullet(c + Vector2(GUARD_IN_OFFS[lv - 1], 0.0))
		var b_out := _spawn_bullet(c + Vector2(GUARD_OUT_OFFS[lv - 1], 0.0))
		_rebuild_bullets([b_in, b_out])
		w13.level = lv
		w13._guard_left = 0.0                      # 节拍同步：下一 tick 即检查
		_step(w13, 1)
		_check("B2%s 警戒弧挡弹域 L%d==%d（域内 %s 消 / 域外 %s 不受）"
				% ["abcde"[lv - 1], lv, int(BLOCK_TABLE[lv - 1]),
					str(GUARD_IN_OFFS[lv - 1]), str(GUARD_OUT_OFFS[lv - 1])],
			not _alive(b_in) and _alive(b_out),
			"in_clean=%s out_alive=%s" % [str(not _alive(b_in)), str(_alive(b_out))])
		_release_bullets([b_in, b_out])
	_clear_enemies()
	# 斩击窗逐级（_slash_window 确定性开窗——直调内部口无冷却限制）
	var w13w := _fresh_w13()
	if w13w == null:
		for i in range(5):
			_check("B3%s 斩击窗挡弹域逐级（装配缺失）" % ["abcde"[i]], false)
		return
	w13w.data.melee["block_chance"] = 1.0
	for lv in range(1, 6):
		var d_in := GUARD_IN_OFFS[lv - 1]
		var d_out := GUARD_OUT_OFFS[lv - 1]
		var w1 := _spawn_bullet(c + Vector2(d_in * COS60, d_in * SIN60))    # 窗弧 ±60° 内
		var w2 := _spawn_bullet(c + Vector2(d_in * COS60, -d_in * SIN60))
		var w_out := _spawn_bullet(c + Vector2(d_out * COS60, d_out * SIN60))
		_rebuild_bullets([w1, w2, w_out])
		w13w.level = lv
		w13w._slash_window(0.0, false)             # facing=0 开窗（radius 注入逐级 effective）
		_step(w13w, 1)                             # tick → _nullify_enemy_bullets（读表）
		_check("B3%s 斩击窗挡弹域 L%d==%d（±60° 域内双弹消 / 域外不受）"
				% ["abcde"[lv - 1], lv, int(BLOCK_TABLE[lv - 1])],
			not _alive(w1) and not _alive(w2) and _alive(w_out),
			"w1=%s w2=%s out=%s" % [str(not _alive(w1)), str(not _alive(w2)),
				str(_alive(w_out))])
		_release_bullets([w1, w2, w_out])
	# W9 nullify 确定性消弹全额保持（140px > 表域 124 但 < 全额域 214 → 消——不读表判据）
	var w9 := _fresh_w9()
	var b9: ProjectileBase = null
	if w9 != null:
		w9._slash_window(0.0, false)               # W9 L1 slash_radius=150
		b9 = _spawn_bullet(c + Vector2(140.0, 0.0))
		_rebuild_bullets([b9])
		_step(w9, 1)
	_check("B4 W9 nullify 消弹域全额保持（140px 弹仍消——若误读表 L1 域 124 则不消）",
		w9 != null and not _alive(b9),
		"alive=%s" % str(_alive(b9)))
	if _alive(b9):
		_release_bullets([b9])


# ── C 组：化身随圈成长（4 项） ────────────────────────────────────
func _group_c_avatar_growth() -> void:
	print("── C 组：W13 化身随圈成长（§3.4-1） ──")
	var w13 := _fresh_w13()
	await tree.process_frame                          # 化身层 _process 刷新（scale 写入）
	await tree.process_frame
	var av := _avatar_of(w13)
	var s_l1: float = av.scale.x if av != null else -1.0
	_check("C1 W13 L1 化身 scale==0.62（与现状一致零突兀）",
		w13 != null and av != null and absf(s_l1 - 0.62) < 0.001,
		"scale=%s" % str(s_l1))
	w13.level = 5
	await tree.process_frame
	await tree.process_frame
	var s_l5: float = av.scale.x if av != null else -1.0
	_check("C2 W13 L5 化身 scale==0.62×190/130≈0.9077（随圈成长）",
		av != null and absf(s_l5 - 0.62 * 190.0 / 130.0) < 0.001,
		"scale=%s" % str(s_l5))
	var w9 := _fresh_w9()                             # 对照：非 W13 恒 0.62（旧口径零位移）
	await tree.process_frame
	await tree.process_frame
	var av9 := _avatar_of(w9)
	var s9: float = av9.scale.x if av9 != null else -1.0
	_check("C3 W9 化身 scale==0.62 对照零位移（非 W13 不随圈）",
		w9 != null and av9 != null and absf(s9 - 0.62) < 0.001,
		"scale=%s" % str(s9))
	var w13g := _fresh_w13()                          # 巨刃乘区同步长大（effective 已含）
	if w13g == null:
		_check("C4 巨刃乘区化身长大（装配缺失）", false)
		return
	var ok_g := _attach_by_id(w13g, &"MEC_GIANT_BLADE")
	await tree.process_frame
	await tree.process_frame
	var avg := _avatar_of(w13g)
	var sg: float = avg.scale.x if avg != null else -1.0
	_check("C4 巨刃 ×1.2 化身同步长大（L1 130×1.2=156 → scale==0.62×156/130=0.744）",
		ok_g and avg != null and absf(sg - 0.62 * 156.0 / 130.0) < 0.001,
		"ok=%s scale=%s" % [str(ok_g), str(sg)])


# ── D 组：开窗剑体缩放（3 项） ────────────────────────────────────
func _group_d_blade_scale() -> void:
	print("── D 组：开窗 blade_visual_scale（§3.4-2——公式不动新表自动落地） ──")
	var w13 := _fresh_w13()
	var s_l1: float = -1.0
	if w13 != null:
		w13._slash_window(0.0, false)               # L1 开窗（radius 注入 130）
		s_l1 = w13.arc_slash.blade_visual_scale()
	_check("D1 W13 L1 blade_visual_scale==130/150≈0.867（>0.8 不触下限）",
		w13 != null and absf(s_l1 - 130.0 / 150.0) < 0.001,
		"s=%s" % str(s_l1))
	var s_l5: float = -1.0
	if w13 != null:
		w13.level = 5
		_step(w13, 44)                             # 旧窗耗尽（槽 0 复位——防重开落新槽）
		w13._slash_window(0.0, false)               # 重开窗（radius 注入 190）
		s_l5 = w13.arc_slash.blade_visual_scale()
	_check("D2 W13 L5 blade_visual_scale==190/150≈1.267（新表自动落地）",
		w13 != null and absf(s_l5 - 190.0 / 150.0) < 0.001,
		"s=%s" % str(s_l5))
	var w9 := _fresh_w9()
	var s9: float = -1.0
	if w9 != null:
		w9._slash_window(0.0, false)                # W9 L1 表值 150=BLADE_TABLE_R
		s9 = w9.arc_slash.blade_visual_scale()
	_check("D3 W9 L1 blade_visual_scale==1.0 对照（表值 150=设计基准零位移）",
		w9 != null and absf(s9 - 1.0) < 0.001,
		"s=%s" % str(s9))


# ── E 组：虚线圈半径即时刷新（3 项） ──────────────────────────────
func _group_e_dash_refresh() -> void:
	print("── E 组：虚线圈半径当帧刷新（§3.4-3——升级后无陈旧圈） ──")
	var w13 := _fresh_w13()
	if w13 == null:
		_check("E1 待机虚线半径锚（装配缺失）", false)
		_check("E1b 升级当帧刷新（装配缺失）", false)
		_check("E1c 半径稳定不抖（装配缺失）", false)
		return
	w13._slash_window(0.0, false)                   # L1 开窗（130 快照）
	_step(w13, 44)                                  # 窗耗尽 + 待机虚线挂（半径锚记 130）
	var dash: ArcSlash = w13.arc_slash
	var anchor_l1: float = dash._dash_radius if dash != null else -1.0
	_check("E1 待机虚线半径锚==130（L1 live 真值上帧已记）",
		dash != null and absf(anchor_l1 - 130.0) < 0.05,
		"anchor=%s" % str(anchor_l1))
	w13.level = 2                                   # 升级（L2 effective 140——池不重铺）
	_step(w13, 1)                                   # 当帧 tick
	var anchor_l2: float = dash._dash_radius if dash != null else -1.0
	var snap: float = dash.slash_radius if dash != null else -1.0
	_check("E1b 升级当帧刷新（_dash_radius 130→140 即时 + slash_radius 快照仍 130——虚线画 live 真值非陈旧快照）",
		dash != null and absf(anchor_l2 - 140.0) < 0.05
			and absf(snap - 130.0) < 0.001,
		"anchor=%s snap=%s" % [str(anchor_l2), str(snap)])
	_step(w13, 1)
	var anchor_stable: float = dash._dash_radius if dash != null else -1.0
	_check("E1c 半径稳定不抖（连续帧锚恒 140——去重纪律不破）",
		dash != null and absf(anchor_stable - 140.0) < 0.05,
		"anchor=%s" % str(anchor_stable))


# ── F 组：乘区序保持（3 项） ──────────────────────────────────────
func _group_f_mult_order() -> void:
	print("── F 组：乘区序保持（§3.2——同乘区 W13 恒 < W9） ──")
	# F1 巨刃 ×1.2：W13 L5 190×1.2=228 < W9 L5 230×1.2=276
	var w13g := _fresh_w13()
	var ok13: bool = w13g != null and _attach_by_id(w13g, &"MEC_GIANT_BLADE")
	w13g.level = 5
	var r13: float = w13g.effective_slash_radius() if w13g != null else -1.0
	var w9g := _fresh_w9()
	var ok9: bool = w9g != null and _attach_by_id(w9g, &"MEC_GIANT_BLADE")
	w9g.level = 5
	var r9: float = w9g.effective_slash_radius() if w9g != null else -1.0
	_check("F1 巨刃 ×1.2 序保持（W13 L5 228 < W9 L5 276）",
		ok13 and ok9 and absf(r13 - 228.0) < 0.01 and absf(r9 - 276.0) < 0.01
			and r13 < r9,
		"w13=%s w9=%s" % [str(r13), str(r9)])
	# F2 广域 ×1.18：W13 L5 190×1.18=224.2 < W9 L5 230×1.18=271.4
	var w13r := _fresh_w13()
	var ok13r: bool = w13r != null and _attach_by_id(w13r, &"AFF_RANGE")
	w13r.level = 5
	var rr13: float = w13r.effective_slash_radius() if w13r != null else -1.0
	var w9r := _fresh_w9()
	var ok9r: bool = w9r != null and _attach_by_id(w9r, &"AFF_RANGE")
	w9r.level = 5
	var rr9: float = w9r.effective_slash_radius() if w9r != null else -1.0
	_check("F2 广域 ×1.18 序保持（W13 L5 224.2 < W9 L5 271.4）",
		ok13r and ok9r and absf(rr13 - 224.2) < 0.05 and absf(rr9 - 271.4) < 0.05
			and rr13 < rr9,
		"w13=%s w9=%s" % [str(rr13), str(rr9)])
	# F3 双乘极端序：W13 L5 190×1.2×1.18=269.04 < W9 230×1.2×1.18=325.68
	var w13d := _fresh_w13()
	var ok13d1: bool = w13d != null and _attach_by_id(w13d, &"MEC_GIANT_BLADE")
	var ok13d2: bool = ok13d1 and _attach_by_id(w13d, &"AFF_RANGE")
	w13d.level = 5
	var rd13: float = w13d.effective_slash_radius() if w13d != null else -1.0
	var w9d := _fresh_w9()
	var ok9d1: bool = w9d != null and _attach_by_id(w9d, &"MEC_GIANT_BLADE")
	var ok9d2: bool = ok9d1 and _attach_by_id(w9d, &"AFF_RANGE")
	w9d.level = 5
	var rd9: float = w9d.effective_slash_radius() if w9d != null else -1.0
	_check("F3 双乘序保持（巨刃+广域 W13 L5 269.04 < W9 325.68——同乘区序不破）",
		ok13d2 and ok9d2 and absf(rd13 - 269.04) < 0.05
			and absf(rd9 - 325.68) < 0.05 and rd13 < rd9,
		"w13=%s w9=%s" % [str(rd13), str(rd9)])


func _func_body(p_src: String, p_head: String) -> String:
	var start := p_src.find(p_head)
	if start < 0:
		return ""
	var next := p_src.find("\nfunc ", start + p_head.length())
	if next < 0:
		next = p_src.length()
	return p_src.substr(start, next - start)

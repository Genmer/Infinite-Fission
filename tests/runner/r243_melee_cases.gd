# tests/runner/r243_melee_cases.gd
# R243 近战重组（w2-melee）用例体（由 test_r243_melee.gd 入口加载；cases 禁 test_ 前缀
# 防电池 glob 误收）。覆盖（w2-melee 验收 ①~⑩）：
#   A 组 W13 表/模式读回：数值表 L1/L5（64/130/140°/10 目、105/190/180°）+ mode 改义
#        （_is_slash_mode = slash|cleave，缺省回落 nullify 旧口径）+ 裸斩半径 130。
#   B 组 cleave 定向开弧：R33 无目标不开火；try_fire → _open_slash(aim, muzzle)；
#        不建 OrbitField；巨刃 ×1.2 / 广域 ×1.18 乘式（helper 上移版消费）；
#        spawn 键三件（greatsword / block 0.30 / knockback 100）+ W9 口径零位移 +
#        _orbit_params cleave 不注入追击键。
#   C 组 常驻警戒弧：_guard_facing 缓存；两极（chance=1.0 正面全消 + 侧后 90° 外不受 /
#        chance=0.0 零消弹）；帽 4/检查；节拍 0.1s；斩击窗停巡判据。
#        （R245 §3.3 挡弹域改 BLOCK_RADIUS_TABLE[level]——弹位按名义域 60 内重摆）
#   D 组 幻影斩挂点（inert）：零词条零行为；2 层 +2 道（facing +90°×i、错帧 0.12s）；
#        额外 +2 封顶；全额伤害（atk_mult 1.0）。
#   E 组 W8 刀位挡弹：block_chance 0.30；enemy_bullet_grid 注入；chance=1.0 帽 4/tick
#        + 余弹续消；chance=0.0 零消弹；刀位域外不受。
#   F 组 W8 子引爆拆分：请求空零行为；子引爆 = ±spread×0.5R 处 ×0.55R ×0.4 dmg；
#        无孙代反断言（spy 恰 1 次派发）；禁止路径源码反断言；蓄能锚 mini。
#   G 组 狼头弯刀 + 染色：_orb_tint 三态（KIN 兜底 / 单元素同色零位移 / 双元素混色）；
#        绘制结构（_draw_wolf_knife + PLAYER 主填充、_draw_flying_knives 删除）；
#        knife_scale 视觉通道；styled_orbs smoke。
#   H 组 helper 上移：本地实现四函数删除（源码断言）+ W8 orbs 走基类 _orbit_link_count。
#   ⑫ 套件总项数断言（R231 假绿教训）。
# 确定性：固定坐标/静止敌/crit=0 副本数据/帧戳手动推进（E-03 闸门口径，仿 w8_charge）。
extends RefCounted

const EXPECTED_TOTAL := 53   # 二cx#2 +3 / 二cy +3（B10d 穿透下架 + B10e/B9c 剑体缩放）
const DT := 1.0 / 120.0
const MAIN_SCENE := "res://scenes/main.tscn"
const OW_SRC_PATH := "res://scripts/combat/weapon/melee/orbit_weapon.gd"
const OF_SRC_PATH := "res://scripts/combat/weapon/melee/orbit_field.gd"

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null
var _ow_src: String = ""
var _of_src: String = ""


# ON_EXPIRE 间谍（写 melee_split_request——§4.5 通道 B 词条臂的桩，w5 入库前的替身）
class MeleeSplitSpy extends TraitEffect:
	var calls: int = 0
	func handle(p_trait: TraitBase, p_ctx: TraitContext) -> void:
		calls += 1
		p_ctx.melee_split_request = {
			"count": 2, "spread_deg": 28.0, "inherit_ratio": 0.4, "echo": false,
		}


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(20261008)
	_boot_game_loop()
	_ow_src = _read_src(OW_SRC_PATH)
	_of_src = _read_src(OF_SRC_PATH)
	_group_a_data_mode()
	_group_b_cleave()
	_group_c_guard_arc()
	_group_d_phantom()
	_group_e_w8_block()
	_group_f_sub_detonate()
	_group_g_wolf_tint()
	_group_h_helper_lift()
	_teardown_game_loop()
	_check("⑫ 套件总项数（EXPECTED=%d——R231 假绿教训）" % EXPECTED_TOTAL,
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


# ── 夹具 ──────────────────────────────────────────────────────────
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


func _fresh_w8() -> OrbitWeapon:
	OrbitField.reset_detonate_gates()
	return _fresh_weapon(&"W8_orbit_field", "W8")


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


func _alive_count(p_bullets: Array) -> int:
	var n := 0
	for b in p_bullets:
		if b != null and is_instance_valid(b) and not (b as ProjectileBase).is_clean:
			n += 1
	return n


func _bump() -> void:
	GameConfig.frame_stamp += 1                    # E-03 帧闸门推进（引爆 ICD 帧戳时钟）


func _step(p_w: WeaponBase, p_ticks: int) -> void:
	for i in range(p_ticks):
		_bump()
		p_w.tick(DT)


func _attach_local_trait(p_w: WeaponBase, p_id: StringName, p_value: float,
		p_hooks: Array[int] = []) -> void:
	var t := TraitData.new()
	t.id = p_id
	t.display_name = "TST"
	t.pool = GameConst.PoolClass.LOCAL
	t.pool_id = &"tst_local"
	t.effect_id = &"EF_STAT"
	t.value = p_value
	t.stack_max = 9
	t.event_hooks = p_hooks
	p_w.attach_trait(t)


func _attach_by_id(p_w: WeaponBase, p_id: StringName) -> bool:
	return p_w.attach_trait(_gl.registry.get_trait(p_id))


# ── A 组：W13 表/模式读回（5 项） ─────────────────────────────────
func _group_a_data_mode() -> void:
	print("── A 组：W13 数值表与 mode 改义读回 ──")
	var wd := _gl.registry.get_weapon(&"W13_great_sword")
	var m: Dictionary = wd.melee
	_check("A1 W13 表读回（form3 / mode cleave / weapon_class melee / block 0.30 / knockback 100）",
		wd != null and int(wd.form) == GameConst.WeaponForm.MELEE
		and String(m.get("mode", "")) == "cleave"
		and String(m.get("weapon_class", "")) == "melee"
		and absf(float(m.get("block_chance", -1.0)) - 0.30) < 0.0001
		and absf(float(m.get("knockback", -1.0)) - 100.0) < 0.0001,
		"mode=%s block=%s" % [str(m.get("mode")), str(m.get("block_chance"))])
	wd = _gl.registry.get_weapon(&"W13_great_sword")
	_check("A2 L1 数值表（atk 64 / 半径 130 / 弧 140° / 10 目标）",
		absf(float(wd.upgrade_table[0].base_atk) - 64.0) < 0.0001
		and absf(float(m.get("slash_radius_levels", [])[0]) - 130.0) < 0.0001
		and absf(float(m.get("arc_deg_levels", [])[0]) - 140.0) < 0.0001
		and int(m.get("max_targets", 0)) == 10)
	_check("A3 L5 数值表（atk 105 / 半径 190 / 弧 180°）",
		absf(float(wd.upgrade_table[4].base_atk) - 105.0) < 0.0001
		and absf(float(m.get("slash_radius_levels", [])[4]) - 190.0) < 0.0001
		and absf(float(m.get("arc_deg_levels", [])[4]) - 180.0) < 0.0001)
	# mode 改义四向 + 缺省回落（_is_slash_mode = mode ∈ {slash, cleave}）
	var w13p := OrbitWeapon.new()
	w13p.data = wd
	var w8p := OrbitWeapon.new()
	w8p.data = _gl.registry.get_weapon(&"W8_orbit_field")
	var w9p := OrbitWeapon.new()
	w9p.data = _gl.registry.get_weapon(&"W9_arc_slash")
	var stub_orbit := OrbitWeapon.new()
	stub_orbit.data = _mk_mode_wd({})
	var stub_nullify := OrbitWeapon.new()
	stub_nullify.data = _mk_mode_wd({"nullify": true})
	_check("A4 mode 改义（W13 slash+cleave / W9 slash 非 cleave / W8 双否 / 缺省{}→orbit / nullify→slash 非 cleave）",
		w13p._is_slash_mode() and w13p._is_cleave_mode()
		and w9p._is_slash_mode() and not w9p._is_cleave_mode()
		and not w8p._is_slash_mode() and not w8p._is_cleave_mode()
		and not stub_orbit._is_slash_mode()
		and stub_nullify._is_slash_mode() and not stub_nullify._is_cleave_mode())
	w13p.free()
	w8p.free()
	w9p.free()
	stub_orbit.free()
	stub_nullify.free()
	var w13 := _fresh_w13()
	_check("A5 L1 裸 effective_slash_radius == 130（无乘区）",
		w13 != null and absf(w13.effective_slash_radius() - 130.0) < 0.001,
		"r=%s" % str(w13.effective_slash_radius() if w13 != null else -1.0))


func _mk_mode_wd(p_melee: Dictionary) -> WeaponData:
	var wd := WeaponData.new()
	wd.id = &"TST_R243_MODE"
	wd.display_name = "TST"
	wd.form = GameConst.WeaponForm.MELEE
	wd.melee = p_melee
	return wd


# ── B 组：cleave 定向开弧（9 项） ─────────────────────────────────
func _group_b_cleave() -> void:
	print("── B 组：W13 cleave 定向开弧 ──")
	var w13 := _fresh_w13()
	_check("B1 R33 无目标不开火（try_fire false + 零窗零槽）",
		w13 != null and not w13.try_fire()
		and w13.orbit_field == null and w13.arc_slash == null)
	if w13 == null:
		return
	var c := _gl.player.global_position
	var e := _spawn_e(c + Vector2(120.0, 0.0))     # 二cx#2 交战门后：敌须进 130×1.15≈149.5 圈内才开弧（R245 新表）
	var fired := w13.try_fire()
	_check("B2 有敌定向开弧（敌入交战圈 → true + 不建 OrbitField + 窗开）",
		fired and w13.orbit_field == null and w13.arc_slash != null
		and w13.arc_slash.window_left > 0.0,
		"fired=%s field=%s" % [str(fired), str(w13.orbit_field)])
	_check("B3 定向 facing≈0（敌 +X）+ 中心 = muzzle_position（玩家位）",
		w13.arc_slash != null and absf(wrapf(w13.arc_slash.facing, -PI, PI)) < 0.01
		and w13.arc_slash.strike_center.distance_to(c) < 0.01,
		"facing=%s" % str(w13.arc_slash.facing if w13.arc_slash != null else 99.0))
	_check("B4 窗口径读回（半径 130 / 弧 140° / 上限 10）",
		w13.arc_slash != null and absf(w13.arc_slash.slash_radius - 130.0) < 0.001
		and absf(w13.arc_slash.arc_deg - 140.0) < 0.001 and w13.arc_slash.max_targets == 10)
	_check("B7 spawn 键三件（blade_style greatsword / block_chance -1 哨兵·R243 迁移/发现修复：快照 0.30 短路弹反成长改 live 口 / knockback 快照 100）",
		w13.arc_slash != null and w13.arc_slash.blade_style == &"greatsword"
		and absf(w13.arc_slash.block_chance - (-1.0)) < 0.0001
		and absf(w13.arc_slash.knockback - 100.0) < 0.0001,
		"style=%s chance=%s kb=%s" % [str(w13.arc_slash.blade_style if w13.arc_slash != null else &"nil"),
			str(w13.arc_slash.block_chance if w13.arc_slash != null else -1.0),
			str(w13.arc_slash.knockback if w13.arc_slash != null else -1.0)])
	var params: Dictionary = w13._orbit_params()
	_check("B9 _orbit_params 守卫（W13 无 leash/chase/engage 追击键；W9 有 leash_radius）",
		not params.has("leash_radius") and not params.has("chase_speed")
		and not params.has("engage_r"))
	# 巨刃乘区（helper 上移版消费：R = 130×(1+0.2×1)）——独立新 W13（词条不可卸）
	var w13g := _fresh_w13()
	var ok_giant := _attach_by_id(w13g, &"MEC_GIANT_BLADE")
	_check("B5 巨刃乘区 130×1.2=156（MEC_GIANT_BLADE 1 层，基类 helper 版）",
		ok_giant and absf(w13g.effective_slash_radius() - 156.0) < 0.01,
		"ok=%s r=%s" % [str(ok_giant), str(w13g.effective_slash_radius())])
	# 广域乘区（AFF_RANGE add_range 池：R = 130×1.18）
	var w13r := _fresh_w13()
	var ok_range := _attach_by_id(w13r, &"AFF_RANGE")
	_check("B6 范围乘区 130×1.18=153.4（AFF_RANGE add_range 池）",
		ok_range and absf(w13r.effective_slash_radius() - 153.4) < 0.05,
		"ok=%s r=%s" % [str(ok_range), str(w13r.effective_slash_radius())])
	# W9 口径零位移：saber / -1 哨兵（旧口径 nullify→1.0）/ 击退基值 0
	var w9 := _fresh_w9()
	w9._slash_window(0.0, false)                   # 兼容通道确定性开窗（玩家中心）
	_check("B8 W9 spawn 口径零位移（saber / block_chance=-1 哨兵 / knockback 0）",
		w9.arc_slash != null and w9.arc_slash.blade_style == &"saber"
		and absf(w9.arc_slash.block_chance - (-1.0)) < 0.0001
		and absf(w9.arc_slash.knockback - 0.0) < 0.0001,
		"style=%s chance=%s kb=%s" % [str(w9.arc_slash.blade_style),
			str(w9.arc_slash.block_chance), str(w9.arc_slash.knockback)])
	var params9: Dictionary = w9._orbit_params()
	_check("B9b W9 slash 追击键保持（leash_radius 注入）", params9.has("leash_radius"))
	_check("B9c 二cy#1 W9 L1 剑体缩放==1.0（表值半径 150=BLADE_TABLE_R——设计基准零位移）",
		w9.arc_slash != null and absf(w9.arc_slash.blade_visual_scale() - 1.0) < 0.001,
		"s=%s" % str(w9.arc_slash.blade_visual_scale() if w9.arc_slash != null else -1.0))
	# ── 二cx#2 交战门（有敌人靠近才攻击）：远敌不挥 / 外圈探肩即挥 / 冷却保持就绪 ──
	var w13g2 := _fresh_w13()
	var e_far := _spawn_e(c + Vector2(300.0, 0.0))    # 300 > 130×1.15=149.5 → 圈外不挥（R245 新表）
	var far_fired := w13g2.try_fire()
	_check("B10 二cx#2 圈外敌不挥（300px>149.5 交战圈 → false + 零窗）",
		not far_fired and (w13g2.arc_slash == null or w13g2.arc_slash.window_left <= 0.0),
		"fired=%s" % str(far_fired))
	_check("B10b 二cx#2 圈外期冷却保持就绪（cooldown_left==0——敌进圈即斩零补等）",
		w13g2.cooldown_left <= 0.0, "cd=%s" % str(w13g2.cooldown_left))
	e_far.global_position = c + Vector2(140.0, 0.0)   # 140 ⊂ (130, 149.5) 外圈——探肩即视为靠近
	_gl.enemy_grid.rebuild(_gl.spawner.active)        # 网格快照刷新（_spawn_e 同式）
	var near_fired := w13g2.try_fire()
	_check("B10c 二cx#2 外圈探肩即挥（140px∈(130,149.5) → true + facing 朝敌）",
		near_fired and w13g2.arc_slash != null
		and absf(wrapf(w13g2.arc_slash.facing, -PI, PI)) < 0.01,
		"fired=%s facing=%s" % [str(near_fired),
			str(w13g2.arc_slash.facing if w13g2.arc_slash != null else 99.0)])
	# 二cy#2 穿透弹头卡对 W10 精确下架：回旋刃命中从不因穿透耗尽回收
	#（projectile_base `pierce_left > 0 or _boomerang` 恒活——穿透=死数字），
	# 用户「回旋刀的穿透弹头有啥用，攻击距离固定本来就能穿透」。
	var pierce_td: TraitData = _gl.registry.get_trait(&"AFF_PIERCE")
	var w10: WeaponBase = _gl.player.add_weapon(_gl.registry.get_weapon(&"W10_boomerang"))
	var w2g: WeaponBase = _gl.player.add_weapon(_gl.registry.get_weapon(&"W2_gatling"))
	var pierce_ok := pierce_td != null and w10 != null and w2g != null \
		and (pierce_td.params.get("excluded_weapons", []) as Array).has("W10_boomerang") \
		and not CardGenerator.mount_gate_allows(pierce_td, w10) \
		and CardGenerator.mount_gate_allows(pierce_td, w2g)
	_check("B10d 二cy#2 穿透弹头卡对 W10 下架（excluded 键 + 门拒 W10 + 对照放行 W2 弹道）",
		pierce_ok, "ok=%s" % str(pierce_ok))
	if w10 != null:
		for i in range(_gl.player.weapon_slots.size()):
			if _gl.player.weapon_slots[i] == w10:
				_gl.player.weapon_slots[i] = null
		w10.free()
	if w2g != null:
		for i in range(_gl.player.weapon_slots.size()):
			if _gl.player.weapon_slots[i] == w2g:
				_gl.player.weapon_slots[i] = null
		w2g.free()
	# 二cy#1 剑体视觉随判定半径缩放（w13g2 窗在开——B10c 开窗 slash_radius=130 快照；
	# B2 的 w13 已被本组 _fresh_w13 清场拆除，勿引用）
	_check("B10e 二cy#1 W13 剑体缩放=130/150≈0.867（刀尖贴虚线圈——视觉/判定同源）",
		w13g2 != null and w13g2.arc_slash != null
		and absf(w13g2.arc_slash.blade_visual_scale() - 130.0 / 150.0) < 0.001,
		"s=%s" % str(w13g2.arc_slash.blade_visual_scale()
			if w13g2 != null and w13g2.arc_slash != null else -1.0))
	_clear_enemies()


# ── C 组：常驻警戒弧（6 项） ─────────────────────────────────────
func _group_c_guard_arc() -> void:
	print("── C 组：W13 常驻警戒弧（§2.5-6/§3.3） ──")
	var w13 := _fresh_w13()
	if w13 == null:
		_check("C 组前置：W13 装配", false)
		return
	w13.data.melee["block_chance"] = 1.0           # 两极桩（bullet_block_chance 直读 melee 段）
	var c := _gl.player.global_position
	var e := _spawn_e(c + Vector2(120.0, 0.0))     # 敌 +X 定 facing（二cx#2：敌须进 149.5 交战圈——R245 新表）
	_step(w13, 1)                                  # 首拍：try_fire 开窗 + facing 缓存
	_check("C1 _guard_facing 缓存自 aim_direction（敌 +X → ≈0）",
		absf(wrapf(w13._guard_facing, -PI, PI)) < 0.01,
		"facing=%s" % str(w13._guard_facing))
	_check("C6a 斩击窗内停巡判据在开（_slash_window_active true）",
		w13._slash_window_active())
	_step(w13, 44)                                 # 窗耗尽（0.34s≈41 帧）+ 待机空巡两拍
	_check("C6b 窗外停巡解除（_slash_window_active false）",
		not w13._slash_window_active())
	# chance=1.0 两极：正面 3 弹全消 + 侧后弹不受
	# （R245 §3.3 挡弹域 L1=60——弹位按名义域内重摆：55/53.7/53.7 ≤ 60）
	w13._guard_left = 0.0                          # 测试内同步节拍（下一 tick 即检查）
	var b_f1 := _spawn_bullet(c + Vector2(55.0, 0.0))
	var b_f2 := _spawn_bullet(c + Vector2(48.0, 22.0))
	var b_f3 := _spawn_bullet(c + Vector2(48.0, -22.0))
	var b_rear := _spawn_bullet(c + Vector2(-80.0, 0.0))
	var bullets: Array = [b_f1, b_f2, b_f3, b_rear]
	_rebuild_bullets(bullets)
	var parry0: int = DebugStats.get_counter(&"bullet_parry")
	var ripples: Array = []
	var cb := func(p_pos: Vector2) -> void: ripples.append(p_pos)
	EventBus.bullet_nullified.connect(cb)
	_step(w13, 1)
	EventBus.bullet_nullified.disconnect(cb)
	var rear_alive: bool = b_rear != null and is_instance_valid(b_rear) \
		and not (b_rear as ProjectileBase).is_clean
	_check("C2 chance=1.0 正面 90° 扇形全消（3 弹）+ 侧后 90° 外不受 + 涟漪逐弹",
		_alive_count(bullets) == 1 and rear_alive
		and DebugStats.get_counter(&"bullet_parry") == parry0 + 3
		and ripples.size() == 3,
		"alive=%d rear=%s parryΔ=%d ripples=%d" % [_alive_count(bullets), str(rear_alive),
			DebugStats.get_counter(&"bullet_parry") - parry0, ripples.size()])
	_release_bullets(bullets)
	# 帽 4/检查 + 节拍 0.1s：首查恰 4（剩余节拍 0.0917 起表）→ 8 tick 未到零消弹 → 跨 0.1s 再消 4
	# （R245 挡弹域 L1=60：burst 弹位 40+1.5i——最远 58.6 ≤ 60 名义域内）
	w13._guard_left = 0.0
	var burst: Array = []
	for i in range(10):
		burst.append(_spawn_bullet(c + Vector2(40.0 + 1.5 * float(i), 12.0 * float(i % 3))))
	_rebuild_bullets(burst)
	_step(w13, 1)
	var cap_first := 10 - _alive_count(burst)
	_release_bullets(burst)
	var burst2: Array = []
	for i in range(10):
		burst2.append(_spawn_bullet(c + Vector2(40.0 + 1.5 * float(i), 12.0 * float(i % 3))))
	_rebuild_bullets(burst2)
	_step(w13, 8)                                  # 节拍余量 0.0917−0.0667 > 0 → 未到检查拍
	var idle_alive := _alive_count(burst2)
	_step(w13, 6)                                  # 累计 ≥ 0.1s → 检查触发
	var cap_second := idle_alive - _alive_count(burst2)
	_check("C4 警戒帽 4/检查（两轮各恰 4 消弹）",
		cap_first == 4 and cap_second == 4,
		"first=%d second=%d" % [cap_first, cap_second])
	_check("C5 节拍 0.1s（8 tick=0.067s 未到零消弹；跨 0.1s 触发）",
		idle_alive == 10 and cap_second == 4,
		"idle_alive=%d" % idle_alive)
	_release_bullets(burst)
	_release_bullets(burst2)
	# chance=0.0 两极：零消弹
	var w13z := _fresh_w13()
	w13z.data.melee["block_chance"] = 0.0
	var ez := _spawn_e(c + Vector2(120.0, 0.0))    # 二cx#2：交战圈内（R245 新表 149.5 圈）
	_step(w13z, 46)                                # 开窗 + 窗耗尽（敌在场防 R33 抖动）
	var bz: Array = []
	for i in range(3):
		bz.append(_spawn_bullet(c + Vector2(70.0 + 5.0 * float(i), 0.0)))
	_rebuild_bullets(bz)
	var parryz0: int = DebugStats.get_counter(&"bullet_parry")
	w13z._guard_left = 0.0                          # 同步节拍：下一 tick 即检查（chance=0 早退）
	_step(w13z, 2)
	_check("C3 chance=0.0 零消弹（正面弹全部保留 + 计数零增）",
		_alive_count(bz) == 3
		and DebugStats.get_counter(&"bullet_parry") == parryz0,
		"alive=%d" % _alive_count(bz))
	_release_bullets(bz)
	_clear_enemies()


# ── D 组：幻影斩挂点（4 项） ─────────────────────────────────────
func _group_d_phantom() -> void:
	print("── D 组：W13 幻影斩（MEC_ORBIT_LINK 消费挂点，inert） ──")
	var w13 := _fresh_w13()
	if w13 == null:
		_check("D 组前置：W13 装配", false)
		return
	var c := _gl.player.global_position
	var e := _spawn_e(c + Vector2(120.0, 0.0))    # 二cx#2：交战圈内（R245 新表 149.5 圈）
	_step(w13, 1)                                   # tick 路径首拍：开火 + 冷却装表（防重复排队）
	_check("D1 零词条 inert（队列恒空——词条门未扩 W13 前零行为）",
		w13.arc_slash != null and w13.arc_slash.window_left > 0.0
		and w13._phantom_queue.is_empty(),
		"queue=%d" % w13._phantom_queue.size())
	# 2 层 → _orbit_link_count()==2 → 队列 2 道（封顶内）
	var w13b := _fresh_w13()
	_attach_local_trait(w13b, &"MEC_ORBIT_LINK", 1.45)
	_attach_local_trait(w13b, &"MEC_ORBIT_LINK", 1.45)
	var count2: int = w13b._orbit_link_count()
	var eb := _spawn_e(c + Vector2(120.0, 0.0))   # 二cx#2：交战圈内（R245 新表 149.5 圈）
	_step(w13b, 1)                                  # 首拍开火（tick 装冷却）→ 队列 2
	_check("D2 ORBIT_LINK 2 层 → 基类 _orbit_link_count()==2 → 队列 2 道",
		count2 == 2 and w13b._phantom_queue.size() == 2,
		"count=%d queue=%d" % [count2, w13b._phantom_queue.size()])
	_step(w13b, 14)                                # 0.125s ≥ 错帧 0.12s → 第 1 道
	_step(w13b, 15)                                # 0.25s ≥ 2×0.12s → 第 2 道
	var slots: Array[ArcSlash] = w13b._slash_pool
	var f1_ok := slots.size() == 3
	var face1 := 0.0
	var face2 := 0.0
	if slots.size() >= 3:
		face1 = slots[1].facing
		face2 = slots[2].facing
	_check("D3 错帧 0.12s×2 开弧（槽池 3 窗 + facing +90°/+180° + 队列清空）",
		f1_ok and absf(wrapf(face1 - PI * 0.5, -PI, PI)) < 0.01
		and absf(wrapf(face2 - PI, -PI, PI)) < 0.01
		and w13b._phantom_queue.is_empty(),
		"slots=%d f1=%s f2=%s" % [slots.size(), str(face1), str(face2)])
	# 封顶 +2：5 层 → count 5 → 队列仍 2；全额伤害（各槽 atk_mult 恒 1.0）
	var w13c := _fresh_w13()
	for i in range(5):
		_attach_local_trait(w13c, &"MEC_ORBIT_LINK", 1.45)
	var count5: int = w13c._orbit_link_count()
	var ec := _spawn_e(c + Vector2(120.0, 0.0))   # 二cx#2：交战圈内（R245 新表 149.5 圈）
	_step(w13c, 1)                                  # 首拍开火（tick 装冷却）→ 队列封顶 2
	var queue5 := w13c._phantom_queue.size()
	_step(w13c, 30)                                # 0.25s：两道幻影斩先后开弧、队列清空
	var slots5: Array[ArcSlash] = w13c._slash_pool
	var mult_ok := slots5.size() >= 3
	if mult_ok:
		for s in slots5:
			if absf(s.atk_mult - 1.0) > 0.0001:
				mult_ok = false
	_check("D4 封顶 +2（5 层 count=5 仍 2 道）+ 全额伤害（各槽 atk_mult==1.0）",
		count5 == 5 and queue5 == 2 and w13c._phantom_queue.is_empty()
		and slots5.size() == 3 and mult_ok,
		"count=%d queue=%d slots=%d" % [count5, queue5, slots5.size()])
	_clear_enemies()


# ── E 组：W8 刀位挡弹（5 项） ────────────────────────────────────
func _group_e_w8_block() -> void:
	print("── E 组：W8 刀位挡弹（§3.3） ──")
	var w8 := _fresh_w8()
	if w8 == null:
		_check("E 组前置：W8 装配", false)
		return
	_check("E1 W8 bullet_block_chance()==0.30（.tres 基线直读）",
		absf(w8.bullet_block_chance() - 0.30) < 0.0001,
		"chance=%s" % str(w8.bullet_block_chance()))
	var fired := w8.try_fire()
	var field: OrbitField = w8.orbit_field
	_check("E2 enemy_bullet_grid 注入（OrbitField 新字段 == GameLoop 同一网格实例）",
		fired and field != null and field.enemy_bullet_grid == _gl.enemy_bullet_grid)
	if field == null:
		return
	field.knockback = 0.0
	field.angular_speed = 0.0                      # 静止定相：orb0 = +90X / orb1 = -90X
	# chance=1.0 桩：6 弹压刀位（帽 4/tick）+ 1 远弹（刀位域外 160px）
	w8.data.melee["block_chance"] = 1.0
	var c := _gl.player.global_position
	var orb0 := c + Vector2(90.0, 0.0)
	var near: Array = []
	for off in [Vector2(0, 0), Vector2(6, 0), Vector2(0, 8), Vector2(-7, -5),
			Vector2(12, 4), Vector2(-4, 12)]:
		near.append(_spawn_bullet(orb0 + off))
	var far := _spawn_bullet(orb0 + Vector2(160.0, 0.0))
	var bullets: Array = near.duplicate()
	bullets.append(far)
	_rebuild_bullets(bullets)
	var parry0: int = DebugStats.get_counter(&"bullet_parry")
	_step(w8, 1)
	var blocked1: int = DebugStats.get_counter(&"bullet_parry") - parry0
	_step(w8, 1)
	var blocked2: int = DebugStats.get_counter(&"bullet_parry") - parry0 - blocked1
	_check("E3 chance=1.0 帽 4/tick（首 tick 恰 4）+ 余弹次 tick 续消（再 2）",
		blocked1 == 4 and blocked2 == 2 and _alive_count(near) == 0,
		"b1=%d b2=%d near_alive=%d" % [blocked1, blocked2, _alive_count(near)])
	_check("E5 刀位域外弹不受（160px > orb_r×knife_scale+6 查询域）",
		far != null and is_instance_valid(far) and not (far as ProjectileBase).is_clean)
	_release_bullets(bullets)
	# chance=0.0 两极
	var w8z := _fresh_w8()
	w8z.data.melee["block_chance"] = 0.0           # 两极桩（基线 .tres 为 0.30）
	w8z.try_fire()
	var fieldz: OrbitField = w8z.orbit_field
	var out_alive := -1
	if fieldz != null:
		fieldz.knockback = 0.0
		fieldz.angular_speed = 0.0
		var cz := _gl.player.global_position
		var bz: Array = []
		for i in range(3):
			bz.append(_spawn_bullet(cz + Vector2(90.0, 6.0 * float(i))))
		_rebuild_bullets(bz)
		var parryz0: int = DebugStats.get_counter(&"bullet_parry")
		_step(w8z, 1)
		out_alive = _alive_count(bz)
		_check("E4 chance=0.0 零消弹（刀位域内弹全部保留）",
			out_alive == 3 and DebugStats.get_counter(&"bullet_parry") == parryz0,
			"alive=%d" % out_alive)
		_release_bullets(bz)
	else:
		_check("E4 chance=0.0 零消弹（力场缺失）", false)
	_clear_enemies()


# ── F 组：W8 子引爆拆分（7 项） ──────────────────────────────────
func _group_f_sub_detonate() -> void:
	print("── F 组：W8 子引爆拆分（§4.5-4 纯结算体） ──")
	var w8 := _fresh_w8()
	if w8 == null:
		_check("F 组前置：W8 装配", false)
		return
	var field := w8.try_fire() and w8.orbit_field != null
	if not field:
		_check("F 组前置：力场创建", false)
		return
	var f: OrbitField = w8.orbit_field
	f.knockback = 0.0
	f.angular_speed = 0.0
	f.detonate_radius = 300.0                      # 测试局部放大（子爆几何余量）
	var c := _gl.player.global_position
	var center := c + Vector2(250.0, -150.0)       # 引爆心（屏内余量）
	var dir28 := Vector2(cos(deg_to_rad(28.0)), sin(deg_to_rad(28.0)))
	var e1 := _spawn_e(center)
	# F1：请求空 = 行为零变化（无 ON_EXPIRE 词条臂 → 单次结算）
	OrbitField.set_charge(e1, int(round(f.charge_max)))
	OrbitField.reset_detonate_gates()
	_bump()
	var det0: int = DebugStats.get_counter(&"w8_detonations")
	var aoe0: int = DebugStats.get_counter(&"w8_detonation_aoe_targets")
	var hp1 := float(e1.hp)
	var fired1 := f._maybe_detonate(e1)
	_check("F1 请求空零行为（e1 恰 50 = atk×5 + aoe_targets 恰 1 次结算）",
		fired1 and absf((hp1 - float(e1.hp)) - 50.0) < 0.05
		and DebugStats.get_counter(&"w8_detonation_aoe_targets") == aoe0 + 1
		and DebugStats.get_counter(&"w8_detonations") == det0 + 1,
		"Δ=%s aoeΔ=%d" % [str(hp1 - float(e1.hp)),
			DebugStats.get_counter(&"w8_detonation_aoe_targets") - aoe0])
	# F2/F3/F4：spy 写 melee_split_request（count=2 / spread 28° / inherit 0.4）
	var spy := MeleeSplitSpy.new()
	var td := TraitData.new()
	td.id = &"TST_MELEE_SPLIT"
	td.display_name = "TST"
	td.pool = GameConst.PoolClass.LOCAL
	td.pool_id = &"tst_local"
	td.effect_id = &"EF_STAT"
	td.value = 1.0
	td.stack_max = 9
	td.event_hooks = [GameConst.TraitEvent.ON_EXPIRE]
	w8.attach_trait(td)
	for tb in w8.trait_stack.traits:
		if tb.data != null and tb.data.id == &"TST_MELEE_SPLIT":
			tb.effect = spy
	var p_a := _spawn_e(center + dir28 * 320.0)    # 子爆 A 射线上（母爆 314 域外）
	var p_b := _spawn_e(center + Vector2(dir28.x, -dir28.y) * 320.0)   # 子爆 B 射线上
	var p_far := _spawn_e(center + dir28 * 336.0)  # 双子爆 179px 域外（半径界探针）
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	OrbitField.set_charge(e1, int(round(f.charge_max)))
	OrbitField.reset_detonate_gates()
	_bump()
	var det1: int = DebugStats.get_counter(&"w8_detonations")
	var hps: Array[float] = [float(e1.hp), float(p_a.hp), float(p_b.hp), float(p_far.hp)]
	var fired2 := f._maybe_detonate(e1)
	var d_e1: float = hps[0] - float(e1.hp)
	var d_a: float = hps[1] - float(p_a.hp)
	var d_b: float = hps[2] - float(p_b.hp)
	var d_far: float = hps[3] - float(p_far.hp)
	_check("F2 子引爆数量 ×2（±spread×0.5R 双子各中其位：探针恰 20 = dmg×0.55R 半径 ×0.4 伤）",
		fired2 and absf(d_a - 20.0) < 0.05 and absf(d_b - 20.0) < 0.05,
		"dA=%s dB=%s" % [str(d_a), str(d_b)])
	_check("F3 子引爆半径 ×0.55（320px 命中界 170≤179 内 / 336px 界外 186>179 零波及）",
		absf(d_far) < 0.001,
		"farΔ=%s" % str(d_far))
	_check("F4 无孙代反断言（ON_EXPIRE 派发恰 1 次 + w8_detonations 恰 +1——子引爆零派发）",
		spy.calls == 1 and DebugStats.get_counter(&"w8_detonations") == det1 + 1,
		"spy=%d detsΔ=%d" % [spy.calls, DebugStats.get_counter(&"w8_detonations") - det1])
	_check("F5 结构反断言（_consume_melee_split 函数体含 _detonate_settle(pos_i 调用、"
		+ "不含 _detonate_aoe——树状递归禁止路径）",
		_func_body(_of_src, "func _consume_melee_split").contains("_detonate_settle(pos_i")
		and not _func_body(_of_src, "func _consume_melee_split").contains("_detonate_aoe"))
	_check("F6 拆分结构（_detonate_settle/_consume_melee_split 在册 + 母体 _detonate_aoe"
		+ " 调纯结算体 + melee 宿主 ON_EXPIRE 派发在场）",
		_of_src.contains("func _detonate_settle")
		and _of_src.contains("func _consume_melee_split")
		and _func_body(_of_src, "func _detonate_aoe").contains("_detonate_settle(p_pos")
		and _of_src.contains("tctx.melee = self"))
	_clear_enemies()
	# F7：蓄能锚 mini（子引爆拆分不扰动蓄能状态机——改前逐位一致）
	var w8b := _fresh_w8()
	var field_ok := w8b != null and w8b.try_fire() and w8b.orbit_field != null
	if not field_ok:
		_check("F7 蓄能锚 mini（力场缺失）", false)
		return
	var fb: OrbitField = w8b.orbit_field
	fb.knockback = 0.0
	fb.angular_speed = 0.0
	var cb2 := _gl.player.global_position
	var eA := _spawn_e(cb2 + Vector2(90.0, 0.0))
	var eB := _spawn_e(cb2 + Vector2(150.0, 0.0))  # 引爆心 60px（AoE 内）
	var eC := _spawn_e(cb2 + Vector2(210.0, 0.0))  # 引爆心 120px（AoE 外）
	_step(w8b, 1)
	var ch1 := OrbitField.charge_of(eA)
	_step(w8b, 12)
	var ch2 := OrbitField.charge_of(eA)
	var detB: int = DebugStats.get_counter(&"w8_detonations")
	var hpB := float(eB.hp)
	var hpC := float(eC.hp)
	var detonated := false
	for i in range(600):
		_step(w8b, 1)
		if OrbitField.charge_of(eA) == 0 and i > 12:
			detonated = true
			break
	var d_sub := hpB - float(eB.hp)
	_check("F7 蓄能锚 mini（首触 +1 / gain_cd 内冷却 / 满档恰 1 引爆 60px 恰 50 / 120px 零波及）",
		ch1 == 1 and ch2 == 1 and detonated
		and DebugStats.get_counter(&"w8_detonations") == detB + 1
		and absf(d_sub - 50.0) < 0.05 and absf(hpC - float(eC.hp)) < 0.001,
		"ch1=%d ch2=%d det=%s subΔ=%s" % [ch1, ch2,
			str(DebugStats.get_counter(&"w8_detonations") - detB), str(d_sub)])
	_clear_enemies()


func _func_body(p_src: String, p_head: String) -> String:
	var start := p_src.find(p_head)
	if start < 0:
		return ""
	var next := p_src.find("\nfunc ", start + p_head.length())
	if next < 0:
		next = p_src.length()
	return p_src.substr(start, next - start)


# ── G 组：狼头弯刀 + 染色（6 项） ────────────────────────────────
func _group_g_wolf_tint() -> void:
	print("── G 组：狼头弯刀绘制与 _orb_tint 混色源 ──")
	var w8 := _fresh_w8()
	if w8 == null or w8.try_fire() == false or w8.orbit_field == null:
		_check("G 组前置：力场创建", false)
		return
	var field: OrbitField = w8.orbit_field
	field.knockback = 0.0
	_check("G1 KIN 兜底（无 ELE 卡 → PopPalette.SUCCESS 薄荷绿保留）",
		field._orb_tint(0) == PopPalette.SUCCESS)
	var ok_fir := _attach_by_id(w8, &"ELE_IGNITE")
	var fir: Color = PopPalette.ELEMENT_COLORS[GameConst.Element.FIR]
	_check("G2 单元素同色零位移（ELE_IGNITE → FIR 色逐位同 dominant 旧口径）",
		ok_fir and field._orb_tint(0).is_equal_approx(fir),
		"ok=%s tint=%s" % [str(ok_fir), str(field._orb_tint(0))])
	var ok_ice := _attach_by_id(w8, &"ELE_FREEZE")
	var ice: Color = PopPalette.ELEMENT_COLORS[GameConst.Element.ICE]
	var tint := field._orb_tint(0)
	# R243 迁移/发现修复：blend 改 HSV 色相插值（RGB 均值 3+ 元素洗灰回归）——FIR/ICE
	# 近对跖回落高饱和成员（FIR）色相；断言改属性化：饱和保真 + 明度 = 成员均值
	_check("G3 双元素混色（FIR+ICE → blend_element_color HSV 口径：饱和保真 + 明度均值）",
		ok_ice and tint.s >= maxf(fir.s, ice.s) - 0.001
		and absf(tint.v - (fir.v + ice.v) * 0.5) < 0.001,
		"tint=%s fir_s=%s ice_s=%s" % [str(tint), str(fir.s), str(ice.s)])
	_check("G4 绘制结构（_draw_wolf_knife 在册 + PLAYER 主填充 + 狼首/獠牙剪影 + "
		+ "_draw_flying_knives 已删 + styled 缺省臂路由）",
		_of_src.contains("func _draw_wolf_knife")
		and _func_body(_of_src, "func _draw_wolf_knife").contains("PopPalette.PLAYER")
		and _func_body(_of_src, "func _draw_wolf_knife").contains("獠牙")
		and not _of_src.contains("func _draw_flying_knives")
		and _func_body(_of_src, "func _draw_styled_orbs").contains("_draw_wolf_knife(i"))
	# knife_scale 视觉缩放通道原样生效（glow 底光随缩放——既有观测口）
	field.knife_scale = 1.0
	field._update_orb_sprites(DT)
	var s1: float = field._orb_glows[0].scale.x
	field.knife_scale = 2.0
	field._update_orb_sprites(DT)
	var s2: float = field._orb_glows[0].scale.x
	_check("G5 knife_scale 视觉缩放通道（1.0→2.0 glow 线性 ×2）",
		s1 > 0.0 and absf(s2 / s1 - 2.0) < 0.01, "s1=%s s2=%s" % [str(s1), str(s2)])
	# 绘制烟测（orb 缺省臂全路径执行不崩——headless draw 命令为无渲染 no-op）
	var smoke_ok := true
	if field.style != "orb":
		smoke_ok = false
	field._draw_styled_orbs()
	_check("G6 styled_orbs 缺省臂绘制烟测（style==orb + 全路径调用不崩）", smoke_ok)


# ── H 组：helper 上移切换（2 项） ────────────────────────────────
func _group_h_helper_lift() -> void:
	print("── H 组：helper 上移（WeaponBase 基类版切换） ──")
	var lifted := not _ow_src.contains("func _giant_blade_layers") \
		and not _ow_src.contains("func _giant_blade_value") \
		and not _ow_src.contains("func _range_mult") \
		and not _ow_src.contains("func _orbit_link_knives")
	_check("H1 本地实现四函数已删（_giant_blade_layers/_giant_blade_value/_range_mult/"
		+ "_orbit_link_knives）+ cleave/警戒弧/幻影斩入口在册",
		lifted and _ow_src.contains("func _is_cleave_mode")
		and _ow_src.contains("func _tick_guard_arc")
		and _ow_src.contains("func _queue_phantom_slashes"))
	var w8 := _fresh_w8()
	var ok := w8 != null and w8.try_fire() and w8.orbit_field != null
	if not ok:
		_check("H2 W8 orbs 走基类 _orbit_link_count（力场缺失）", false)
		return
	var before: int = w8.orbit_field.orbs
	_attach_local_trait(w8, &"MEC_ORBIT_LINK", 1.45)
	_attach_local_trait(w8, &"MEC_ORBIT_LINK", 1.45)
	var after: int = w8.orbit_field.orbs
	_check("H2 W8 orbs 消费基类 _orbit_link_count（L1 基 2 + 2 层 ×1 = 4）",
		before == 2 and after == 4, "before=%d after=%d" % [before, after])

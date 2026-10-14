# tests/runner/r243_prime_cases.gd
# R243 五武器 Lv5 质变形态（w4-prime）用例体（入口运行时 load）。
# 覆盖（验收 ①~⑦ + 设计 §7.1/§7.2/§9.1 test_r243_transcend ①~⑥）：
# ① 机制：五武器 L4 transcended==false / L5 升级首次置位 true + milestone 广播
#   （id=max_<id>、文本=display_name·质变名）+ 幂等（L5 已帽重复 level_up 不递增、
#   milestone 不二次、leveled 不再发）
# ② ATK 单咽喉：get_stat("base_atk") ×atk_mult——W13 L5=126（105×1.2）/L4=92 不乘、
#   W11 L5 面板=31.5（42×0.75）实弹读回同值、W9/W8/W12 atk_mult=1.0 表值直读
# ③ 行为参数读回：W9 弧 160→200°（arc_bonus 40）/半径 230×1.15=264.5/池槽重铺同值；
#   W13 弧 180→270°/击退快照 180/黑金巨剑刃身 ×1.3 加宽顶点表读回；
#   W8 orbs 4+2=6/引爆当量 6.5/引爆半径 99（90×1.1）/力场实体读回同值/狼头白银化；
#   W12 震荡半径 128×1.25=160、平表 96×1.25=120（验收锚算术）
# ④ W9 同心回斩：窗末挂账 → 0.18s 后同心回斩一道（atk_mult 0.5/gen+1/同中心/回扫/
#   不递归），母斩 55 + 回斩 27.5 = 82.5 实伤读回
# ⑤ W12 崩山击外环：内环 160 外环 256（×1.6）伤害 ×0.4=38.4，同 _shock_uid 幂等分流
#  （重叠带 A 恰吃内环 96 一次、外环独占带 B 吃 38.4，targets Δ3）
# ⑥ 图标链路：五武器 static weapon_icon_tex(false/true) 非空 56px 互异 + 化身取图
#   transcended 选键门（w1 消费式 get("transcended") 置位后为真）
# ⑦ milestone 无名回落「终极形态」+ GroundShockFx 双环外环臂读回（fx.ring_radius）
# ⚠ 共享文件委托臂（texture_factory.gd）has_static_method 在 Godot 4.3 不存在（w2 已
#   登记）——本套件只直断各武器脚本 static func 本体，不触发共享委托链。
# 最后：套件总项数断言（R231 假绿教训）。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const DT := 1.0 / 120.0
const EXPECTED_TOTAL := 65

const FIVE := [
	{"id": &"W8_orbit_field", "name": "苍狼啸月"},
	{"id": &"W9_arc_slash", "name": "碧涛旋舞"},
	{"id": &"W11_spirit_sword", "name": "万剑诀"},
	{"id": &"W12_ground_axe", "name": "崩山击"},
	{"id": &"W13_great_sword", "name": "裂地斩"},
]

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null
var _w: Dictionary = {}                      # id -> 槽位武器实例（case1 装配）
var _milestones: Array[Dictionary] = []     # EventBus.trait_milestone 捕获
var _leveled_counts: Dictionary = {}        # id -> leveled 信号发射计数


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(20261008)
	if not _boot_game_loop():
		_check("前置：GameLoop 装配", false, "start_run 失败")
		_report()
		return
	await tree.process_frame
	await tree.process_frame
	EventBus.trait_milestone.connect(_on_milestone)
	_case1_flag_milestone_idempotent()
	_case2_atk_throat()
	_case3_behavior_params()
	_case4_w9_echo()
	_case5_w12_ring()
	_case6_icons_and_gate()
	_case7_no_name_fallback()
	_teardown()
	_check("⑧ 套件总项数（EXPECTED=%d——R231 假绿教训）" % EXPECTED_TOTAL,
		_pass + _fail + 1 == EXPECTED_TOTAL, "实得 %d" % (_pass + _fail + 1))
	_report()


func _report() -> void:
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


func _on_milestone(p_id: StringName, p_name: String, _p_mult: float) -> void:
	_milestones.append({"id": p_id, "name": p_name})


func _on_leveled(_p_level: int, p_id: String) -> void:
	_leveled_counts[p_id] = int(_leveled_counts.get(p_id, 0)) + 1


func _milestone_count(p_id: StringName) -> int:
	var n := 0
	for m in _milestones:
		if m["id"] == p_id:
			n += 1
	return n


func _milestone_text(p_id: StringName) -> String:
	for m in _milestones:
		if m["id"] == p_id:
			return String(m["name"])
	return ""


# ── 夹具 ──────────────────────────────────────────────────────────
func _boot_game_loop() -> bool:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "R243PrimeGameLoopUnderTest"
	tree.get_root().add_child(_gl)
	_gl.state = GameConst.GameStatus.MENU
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	var ok: bool = _gl.start_run()
	_gl.state = GameConst.GameStatus.MENU        # 冻结帧序——全部手动驱动（lingjian 同式）
	_gl.player.set("max_hp", 1000000.0)
	_gl.player.set("hp", 1000000.0)
	_gl.player.global_position = Vector2(360.0, 640.0)   # 居中（几何确定性）
	_gl.player.set("unlocked_slots", 6)          # 首发 1（start_run 装备）+ 五质变武器
	return ok


func _teardown() -> void:
	if EventBus.trait_milestone.is_connected(_on_milestone):
		EventBus.trait_milestone.disconnect(_on_milestone)
	tree.paused = false
	RunSave.clear()
	_release_all_proj()
	_clear_enemies()
	if _gl != null:
		_gl.free()
		_gl = null


func _add_slot_weapon(p_id: StringName) -> WeaponBase:
	# 槽位装配（工厂数型真链）+ 探针确定性（crit=0 副本数据 + meta 修正归零）
	var w := _gl.player.add_weapon(_gl.registry.get_weapon(p_id)) as WeaponBase
	if w != null:
		w.data = w.data.duplicate(true)
		w.data.crit_rate = 0.0
		w.meta_atk_pct = 0.0
		w.call(&"_invalidate_panel")
		w.leveled.connect(_on_leveled.bind(String(p_id)))
		_leveled_counts[String(p_id)] = 0
	return w


func _spawn_e(p_pos: Vector2, p_hp: float = 100000.0) -> Enemy:
	var enemy := (_gl.pools[&"enemy"] as EnemyPool).acquire()
	enemy.spawn(_gl.registry.get_enemy(&"E1_grunt"), 1, 0)
	enemy.set("speed", 0.0)                      # 静止敌（几何确定性）
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


func _my_projs(p_uid: int, p_gen: int = 0) -> Array[ProjectileBase]:
	var pool := _gl.pools[&"projectile"] as ProjectilePool
	var out: Array[ProjectileBase] = []
	for p in pool.active_projectiles():
		var pb := p as ProjectileBase
		if pb != null and not pb.is_clean and int(pb.weapon_uid) == p_uid \
				and int(pb.generation) == p_gen:
			out.append(pb)
	return out


func _release_all_proj() -> void:
	if _gl == null:
		return
	var pool := _gl.pools[&"projectile"] as ProjectilePool
	var victims: Array = []
	for p in pool.active_projectiles():
		victims.append(p)
	for v in victims:
		var pb := v as ProjectileBase
		if pb != null and not pb.is_clean:
			pool.release(pb)


func _bump_tick(p_node: Node) -> void:
	GameConfig.frame_stamp += 1                  # E-03 帧闸门推进（lingjian 夹具同式）
	p_node.call(&"tick", DT)


func _tick_slash(p_slot: ArcSlash, p_center: Vector2) -> void:
	# 挥斩实体推进（ArcSlash.tick(delta, center) 双参契约——武器侧 _on_tick_post 同式）
	GameConfig.frame_stamp += 1
	p_slot.call(&"tick", DT, p_center)


# ── ① 机制：L4 false / L5 置位 / milestone / 幂等（五武器） ────────
func _case1_flag_milestone_idempotent() -> void:
	print("── ① 质变机制：L4 false / L5 置位 / milestone 文本 / 幂等（五武器） ──")
	for entry: Dictionary in FIVE:
		var wid: StringName = entry["id"]
		var tname: String = entry["name"]
		var w := _add_slot_weapon(wid)
		var tag := String(wid).split("_")[0]
		var type_ok: bool = (w is FlyingSwordWeapon) if wid == &"W11_spirit_sword" \
			else ((w is GroundAxeWeapon) if wid == &"W12_ground_axe" else (w is OrbitWeapon))
		_check("①%s 工厂数型（行为载体实例化）" % tag, w != null and type_ok,
			"cls=%s" % str(w != null and is_instance_valid(w) and w.get_class()))
		if w == null:
			continue
		_w[wid] = w
		for i in range(3):
			w.level_up()
		var flag4: Variant = w.get("transcended")
		_check("①%s L4：transcended==false（bool 型）且 milestone 未发" % tag,
			w.level == 4 and typeof(flag4) == TYPE_BOOL and not bool(flag4)
				and _milestone_count(StringName("max_%s" % String(wid))) == 0,
			"lv=%d flag=%s" % [w.level, str(flag4)])
		_check("①%s L4：leveled 恰发 3 次" % tag,
			int(_leveled_counts[String(wid)]) == 3,
			"n=%d" % int(_leveled_counts[String(wid)]))
		# L4→L5 前置：W9/W13 预建挥斩槽（验证 _on_transcend 池槽重铺——质变参数即时生效）
		if w is OrbitWeapon and WeaponBase.melee_mode_of(w.data.melee) != "orbit":
			(w as OrbitWeapon)._ensure_slash_instance()
		w.level_up()
		var flag5: Variant = w.get("transcended")
		_check("①%s L5：transcended 首次置位 true" % tag,
			w.level == 5 and typeof(flag5) == TYPE_BOOL and bool(flag5),
			"lv=%d flag=%s" % [w.level, str(flag5)])
		var mid := StringName("max_%s" % String(wid))
		var text := _milestone_text(mid)
		_check("①%s milestone：id=max_<id> + 文本含 display_name 与质变名「%s」" % [tag, tname],
			_milestone_count(mid) == 1 and text.contains(String(w.data.display_name))
				and text.contains(tname) and text.contains("·"),
			"text=%s" % text)
		w.level_up()
		w.level_up()
		_check("①%s 幂等：L5 已帽重复 level_up 不递增/不二次置位/milestone 不重发/leveled 不再发" % tag,
			w.level == 5 and bool(w.get("transcended"))
				and _milestone_count(mid) == 1
				and int(_leveled_counts[String(wid)]) == 4,
			"lv=%d ms=%d lvled=%d" % [w.level, _milestone_count(mid),
				int(_leveled_counts[String(wid)])])


# ── ② ATK 单咽喉（get_stat ×atk_mult → 面板/实弹） ────────────────
func _case2_atk_throat() -> void:
	print("── ② ATK 单咽喉：W13 126 / W11 31.5 / ×1.0 三武器表值直读 ──")
	var w13 := _w.get(&"W13_great_sword") as WeaponBase
	_check("②W13 L5 get_stat(base_atk)==126（105×1.2——质变乘区单咽喉）",
		w13 != null and is_equal_approx(w13.get_stat(&"base_atk"), 126.0),
		"atk=%s" % str(w13.get_stat(&"base_atk") if w13 != null else -1.0))
	_check("②W13 L5 面板快照 base_atk==126（meta 0——结算同源）",
		w13 != null and is_equal_approx(
			float(w13.build_panel_snapshot().get("base_atk", 0.0)), 126.0),
		"panel=%s" % str(w13.build_panel_snapshot().get("base_atk", 0.0) if w13 != null else -1.0))
	# L4 对照：未质变不乘（fresh 直置等级探针——w5 直置等级先例）
	var w13b := OrbitWeapon.new()
	w13b.data = (_gl.registry.get_weapon(&"W13_great_sword") as WeaponData).duplicate(true)
	w13b.level = 4
	var l4_atk := float(w13b.get_stat(&"base_atk"))
	_check("②W13 L4 get_stat(base_atk)==92（未质变零乘区）", is_equal_approx(l4_atk, 92.0),
		"atk=%s" % str(l4_atk))
	w13b.free()
	var w11 := _w.get(&"W11_spirit_sword") as WeaponBase
	var panel11 := float(w11.build_panel_snapshot().get("base_atk", 0.0)) if w11 != null else -1.0
	_check("②W11 L5 面板 base_atk==31.5（42×0.75 万剑诀单剑）",
		w11 != null and is_equal_approx(panel11, 31.5), "panel=%s" % str(panel11))
	var swords := _my_projs(w11.uid) if w11 != null else []
	if w11 != null:
		w11.try_fire()
		swords = _my_projs(w11.uid)
	var sword_ok := swords.size() >= 1
	var sword_atk := -1.0
	if sword_ok:
		sword_atk = float(swords[swords.size() - 1].panel_snapshot.get("base_atk", 0.0))
	_check("②W11 实弹 panel_snapshot.base_atk==31.5（spawn 快照同源）",
		sword_ok and is_equal_approx(sword_atk, 31.5),
		"n=%d atk=%s" % [swords.size(), str(sword_atk)])
	_release_all_proj()
	_check("②×1.0 三武器表值直读（W9 55 / W8 17 / W12 96——atk_mult 1.0 恒等）",
		_is_atk(_w.get(&"W9_arc_slash"), 55.0) and _is_atk(_w.get(&"W8_orbit_field"), 17.0)
			and _is_atk(_w.get(&"W12_ground_axe"), 96.0),
		"9=%s 8=%s 12=%s" % [str(_get_atk(_w.get(&"W9_arc_slash"))),
			str(_get_atk(_w.get(&"W8_orbit_field"))), str(_get_atk(_w.get(&"W12_ground_axe")))])


func _is_atk(p_w: Variant, p_expect: float) -> bool:
	return p_w != null and is_equal_approx(float((p_w as WeaponBase).get_stat(&"base_atk")),
		p_expect)


func _get_atk(p_w: Variant) -> float:
	return float((p_w as WeaponBase).get_stat(&"base_atk")) if p_w != null else -1.0


# ── ③ 行为参数读回（弧/半径/orbs/引爆/击退/贴图差） ────────────────
func _case3_behavior_params() -> void:
	print("── ③ 行为参数读回：W9 200°/×1.15 · W13 270°/kb180/×1.3 · W8 6/6.5/99 · W12 ×1.25 ──")
	var w9 := _w.get(&"W9_arc_slash") as OrbitWeapon
	if w9 != null:
		var arc := float(w9.effective_arc_deg())
		var radius := float(w9.effective_slash_radius())
		var slot_arc := float(w9.arc_slash.arc_deg) if w9.arc_slash != null else -1.0
		_check("③W9 碧涛旋舞：弧 160+40=200°（effective_arc_deg）+ 半径 230×1.15=264.5"
			+ "（尾乘）+ 池槽重铺同值（_on_transcend 即时生效）",
			is_equal_approx(arc, 200.0) and absf(radius - 264.5) < 1e-3
				and is_equal_approx(slot_arc, 200.0),
			"arc=%s r=%s slot=%s" % [str(arc), str(radius), str(slot_arc)])
	var w13 := _w.get(&"W13_great_sword") as OrbitWeapon
	if w13 != null:
		var arc13 := float(w13.effective_arc_deg())
		var slot := w13.arc_slash
		var kb := float(slot.knockback) if slot != null else -1.0
		var slot_arc := float(slot.arc_deg) if slot != null else -1.0
		var slot_t2: bool = slot != null and bool(slot.transcended)
		_check("③W13 裂地斩：弧 180+90=270° + 池槽重铺同值 + 击退快照 100+80=180"
			+ " + 槽 transcended 位在册",
			is_equal_approx(arc13, 270.0) and is_equal_approx(slot_arc, 270.0)
				and is_equal_approx(kb, 180.0) and slot_t2,
			"arc=%s slot=%s kb=%s t2=%s" % [str(arc13), str(slot_arc), str(kb), str(slot_t2)])
		# 黑金巨剑刃身加宽 1.3×：顶点表读回（二cu 直刃表 y=9×2.08=18.72；基准 14.4）
		var poly_t2: PackedVector2Array = slot._blade_polygon()
		var raw := ArcSlash.new()
		raw.spawn({"blade_style": ArcSlash.STYLE_GREATSWORD})
		var poly_base: PackedVector2Array = raw._blade_polygon()
		_check("③W13 质变刃身 ×1.3：直刃表 y 9×2.08=18.72（基准 14.4，二cu）",
			absf(poly_t2[1].y - 18.72) < 1e-3 and absf(poly_base[1].y - 14.4) < 1e-3,
			"t2=%s base=%s" % [str(poly_t2[1].y), str(poly_base[1].y)])
		raw.free()
	var w8 := _w.get(&"W8_orbit_field") as OrbitWeapon
	if w8 != null:
		var params: Dictionary = w8._orbit_params()
		var pre_ok := int(params.get("orbs", -1)) == 6 \
			and is_equal_approx(float(params.get("detonate_mult", 0.0)), 6.5) \
			and absf(float(params.get("detonate_radius", 0.0)) - 99.0) < 1e-3
		_check("③W8 苍狼啸月参数集：orbs 4+2=6 + 引爆当量 5+1.5=6.5 + 引爆半径 90×1.1=99",
			pre_ok, "p=%s" % str(params))
		w8.try_fire()                            # 力场懒创建（首开火）
		var field := w8.orbit_field
		var field_ok := field != null and field.orbs == 6 \
			and is_equal_approx(field.detonate_mult, 6.5) \
			and absf(field.detonate_radius - 99.0) < 1e-3
		_check("③W8 力场实体读回：orbs/detonate_mult/detonate_radius 同值（重铺链）",
			field_ok, "field=%s" % str(field != null))
		var silver: Color = field._wolf_body_color() if field != null else Color(0.0, 0.0, 0.0, 0.0)
		var expect_silver := PopPalette.PLAYER.lerp(Color.WHITE, 0.72)
		_check("③W8 狼头白银化：_wolf_body_color = PLAYER→WHITE 0.72（≠默认蓝）",
			field != null and silver.is_equal_approx(expect_silver)
				and not silver.is_equal_approx(PopPalette.PLAYER),
			"col=%s" % str(silver))
	var w12 := _w.get(&"W12_ground_axe") as WeaponBase
	if w12 != null:
		var r5 := float(w12._shock_radius())
		_check("③W12 崩山击：L5 震荡半径 128×1.25=160（radius_mult 尾乘）",
			absf(r5 - 160.0) < 1e-3, "r=%s" % str(r5))
		# 验收锚算术（96×1.25=120）：平表探针（fresh 直置 L5+质变）
		var w12b := GroundAxeWeapon.new()
		w12b.data = (_gl.registry.get_weapon(&"W12_ground_axe") as WeaponData).duplicate(true)
		w12b.data.melee["shock_radius_levels"] = [96.0, 96.0, 96.0, 96.0, 96.0]
		w12b.level = 5
		w12b.transcended = true
		var r_flat := float(w12b._shock_radius())
		w12b.free()
		_check("③W12 平表锚算术：96×1.25=120（radius_mult 乘区语义逐位）",
			absf(r_flat - 120.0) < 1e-3, "r=%s" % str(r_flat))
	# W11 万剑诀 volley：质变每拍 1→3 剑（±10° 扇形循环展开）
	var w11v := _w.get(&"W11_spirit_sword") as WeaponBase
	if w11v != null:
		var volley := int(w11v.call(&"_sword_volley_count"))
		var fan := float(w11v.call(&"_sword_fan_deg"))
		w11v.try_fire()                          # 无目标 → aim 回退 UP（-90° 基准）
		var vs := _my_projs(w11v.uid)
		var angles := {}
		for s in vs:
			var d := rad_to_deg((s as ProjectileBase).velocity.angle() + PI * 0.5)
			angles[snappedf(d, 0.5)] = true
		_check("③W11 万剑诀 volley：每拍 1→3 剑 + ±10° 扇形（fan_deg 10 循环展开）",
			volley == 3 and is_equal_approx(fan, 10.0) and vs.size() == 3
				and angles.size() == 3 and angles.has(-10.0) and angles.has(0.0)
				and angles.has(10.0),
			"volley=%d fan=%s n=%d angles=%s" % [volley, str(fan), vs.size(), str(angles)])
		_release_all_proj()


# ── ④ W9 碧涛旋舞同心回斩（0.18s / ×0.5 / 同心 / 不递归） ──────────
func _case4_w9_echo() -> void:
	print("── ④ W9 同心回斩：窗末 0.18s 同心回斩一道（×0.5）+ 母 55 + 子 27.5 = 82.5 ──")
	var w9 := _w.get(&"W9_arc_slash") as OrbitWeapon
	if w9 == null or w9.arc_slash == null:
		_check("④W9 同心回斩前置（槽在册）", false, "slot=null")
		return
	var slot := w9.arc_slash
	var center := w9.muzzle_position()
	var enemy := _spawn_e(center + Vector2(100.0, 0.0))   # 弧心正右 100px（母/子双覆盖域）
	var hp0 := float(enemy.hp)
	slot.open_window(0.0, center)
	# 母斩窗（0.34s）：首 tick 即判定 → Δ55
	for i in range(3):
		_tick_slash(slot, center)
	var mother_dmg := hp0 - float(enemy.hp)
	_check("④母斩命中恰 55（L5 表值 atk_mult 1.0）",
		absf(mother_dmg - 55.0) < 0.05, "Δ=%s" % str(mother_dmg))
	# 窗末（41 tick）挂账 → 0.10s 后未到期（无子窗）
	for i in range(50):
		_tick_slash(slot, center)
	_check("④回斩延迟：窗闭 +0.10s < 0.18s 未开子窗",
		slot._child_slashes.is_empty(), "n=%d" % slot._child_slashes.size())
	for i in range(27):
		_tick_slash(slot, center)
	var children := slot._child_slashes
	var child := children[0] if children.size() == 1 else null
	_check("④回斩到点（窗闭后 ~0.18s）恰开一道子窗",
		children.size() == 1, "n=%d" % children.size())
	var child_ok := child != null and absf(child.atk_mult - 0.5) < 1e-3 \
		and child.generation == 1
	_check("④回斩子窗：atk_mult=0.5（echo_ratio）+ generation=1",
		child_ok, "mult=%s gen=%s" % [
			str(child.atk_mult if child != null else -1.0),
			str(child.generation if child != null else -1)])
	var shape_ok := child != null \
		and child.strike_center.distance_to(center) < 0.01 \
		and bool(child.sweep_reverse) and child.echo_ratio <= 0.0
	_check("④回斩子窗：同心（strike_center==母心）+ 回扫读感 + 不递归（echo_ratio 0）",
		shape_ok, "center=%s rev=%s echo=%s" % [
			str(child.strike_center.distance_to(center) if child != null else -1.0),
			str(child.sweep_reverse if child != null else false),
			str(child.echo_ratio if child != null else -1.0)])
	# 回斩窗判定推进 → 子斩伤害 27.5；总伤 82.5
	for i in range(5):
		_tick_slash(slot, center)
	var total := hp0 - float(enemy.hp)
	_check("④总伤 = 母 55 + 回斩 27.5 = 82.5（echo_ratio 实伤读回）",
		absf(total - 82.5) < 0.1, "Δ=%s" % str(total))
	_clear_enemies()


# ── ⑤ W12 崩山击外环（×1.6 / ×0.4 / _shock_uid 幂等分流） ──────────
func _case5_w12_ring() -> void:
	print("── ⑤ W12 外环震荡：内 160 外 256（×1.6）伤 ×0.4=38.4 + 重叠带幂等分流 ──")
	var w12 := _w.get(&"W12_ground_axe") as WeaponBase
	if w12 == null:
		_check("⑤W12 外环前置", false, "w=null")
		return
	var pos := Vector2(500.0, 500.0)
	var ea := _spawn_e(pos)                              # 内环心（内外重叠带）
	var eb := _spawn_e(pos + Vector2(200.0, 0.0))        # 200px：内环窄相外（>160+hitbox）、外环内（≤256）
	var hp_a := float(ea.hp)
	var hp_b := float(eb.hp)
	var targets0 := DebugStats.get_counter(&"axe_shock_targets")
	w12.on_axe_land(pos)                                 # 直调落地结算口（斧飞行段归 w2 域）
	var da := hp_a - float(ea.hp)
	var db := hp_b - float(eb.hp)
	var targets_d := int(DebugStats.get_counter(&"axe_shock_targets")) - int(targets0)
	_check("⑤内环 A：恰 96 一次（重叠带同 _shock_uid 同帧幂等去重——外环不双吃）",
		absf(da - 96.0) < 0.05, "Δa=%s" % str(da))
	_check("⑤外环 B：恰 38.4（96×0.4 ring_ratio——外环独占带）",
		absf(db - 38.4) < 0.05, "Δb=%s" % str(db))
	_check("⑤targets Δ3（内环 A + 外环 A + 外环 B——外环 A 结算入幂等闸不计伤）",
		targets_d == 3, "Δ=%d" % targets_d)
	_check("⑤落地读回：内环半径 160 + 外环半径 256（160×1.6）",
		absf(float(w12.last_land_shock_radius) - 160.0) < 1e-3
			and absf(float(w12.last_land_ring_radius) - 256.0) < 1e-3,
		"r=%s ring=%s" % [str(w12.last_land_shock_radius), str(w12.last_land_ring_radius)])
	var fx := w12.last_fx as GroundAxeWeapon.GroundShockFx
	_check("⑤GroundShockFx 双环外环臂：ring_radius==256 读回（单环态恒 0）",
		fx != null and absf(fx.ring_radius - 256.0) < 1e-3,
		"fx=%s ring=%s" % [str(fx != null), str(fx.ring_radius if fx != null else -1.0)])


# ── ⑥ 图标链路（static func 本体 + 化身选键门） ───────────────────
func _case6_icons_and_gate() -> void:
	print("── ⑥ 图标链路：五武器 weapon_icon_tex(false/true) 56px 互异 + 选键门置位 ──")
	_check("⑥W11 灵剑图标：base/t2 非空 56px 互异（默认银蓝/质变鎏金）",
		_icon_pair_ok(FlyingSwordWeapon.weapon_icon_tex(false),
			FlyingSwordWeapon.weapon_icon_tex(true)))
	_check("⑥W12 裂地斧图标：base/t2 非空 56px 互异（默认岩钢/质变岩纹金脉）",
		_icon_pair_ok(GroundAxeWeapon.weapon_icon_tex(false),
			GroundAxeWeapon.weapon_icon_tex(true)))
	_check("⑥W13 阔剑图标：base/t2 非空 56px 互异（黑金巨剑/加宽+金裂纹）",
		_icon_pair_ok(OrbitWeapon.weapon_icon_tex(false),
			OrbitWeapon.weapon_icon_tex(true)))
	_check("⑥W8 天狼刀图标：base/t2 非空 56px 互异（蓝狼头/白银化+月牙）",
		_icon_pair_ok(OrbitField.weapon_icon_tex(false),
			OrbitField.weapon_icon_tex(true)))
	_check("⑥W9 旋风刀图标：base/t2 非空 56px 互异（青绿弯刀/加深双旋臂）",
		_icon_pair_ok(ArcSlash.weapon_icon_tex(false),
			ArcSlash.weapon_icon_tex(true)))
	var gate_ok := true
	for entry: Dictionary in FIVE:
		var w: Variant = _w.get(entry["id"])
		if w == null:
			gate_ok = false
			continue
		var v: Variant = (w as WeaponBase).get("transcended")
		if not (v != null and typeof(v) == TYPE_BOOL and bool(v)):
			gate_ok = false
	_check("⑥化身取图选键门（w1 消费式 get(transcended)）：五武器置位后全真——t2 键链路接通",
		gate_ok)
	# 质变战斗内贴图差 _draw 烟测（NOTIFICATION_DRAW 真通道，fengren 同式——不炸即过）
	var smoke_ok := true
	var smoke_detail := ""
	for combo: Array in [[ArcSlash.STYLE_SABER, true], [ArcSlash.STYLE_GREATSWORD, true],
		[ArcSlash.STYLE_SABER, false]]:
		var s := ArcSlash.new()
		tree.get_root().add_child(s)
		s.spawn({"blade_style": combo[0], "transcended": combo[1],
			"slash_radius": 150.0, "arc_deg": 120.0})
		s.open_window(0.0, Vector2(400.0, 640.0))
		if not s.visible:
			smoke_ok = false
			smoke_detail += "开窗失败;"
		s.notification(CanvasItem.NOTIFICATION_DRAW)
		s.free()
	_check("⑥质变 _draw 烟测：saber/greatsword ×质变/默认 三组合窗口态绘制不炸且开窗可见",
		smoke_ok, smoke_detail)


func _icon_pair_ok(p_a: ImageTexture, p_b: ImageTexture) -> bool:
	if p_a == null or p_b == null:
		return false
	if p_a.get_size() != Vector2(56.0, 56.0) or p_b.get_size() != Vector2(56.0, 56.0):
		return false
	var ia := p_a.get_image()
	var ib := p_b.get_image()
	if ia == null or ib == null:
		return false
	return ia.get_data() != ib.get_data()


# ── ⑦ milestone 无名回落「终极形态」 ───────────────────────────────
func _case7_no_name_fallback() -> void:
	print("── ⑦ milestone 无名回落：transcend 缺 name → 「终极形态」 ──")
	var w11c := FlyingSwordWeapon.new()
	w11c.data = (_gl.registry.get_weapon(&"W11_spirit_sword") as WeaponData).duplicate(true)
	w11c.data.melee["transcend"] = {"atk_mult": 1.0}       # 无 name（validator 域外探针）
	var before := _milestones.size()
	for i in range(4):
		w11c.level_up()
	var text := ""
	if _milestones.size() > before:
		text = String(_milestones[_milestones.size() - 1]["name"])
	_check("⑦无名质变：milestone 文本以「终极形态」收尾（不出现旧质变名）",
		w11c.transcended and text.ends_with("终极形态") and not text.contains("万剑诀"),
		"flag=%s text=%s" % [str(w11c.transcended), text])
	w11c.free()

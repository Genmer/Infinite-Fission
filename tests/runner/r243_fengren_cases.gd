# tests/runner/r243_fengren_cases.gd
# R243 法器·旋风刀（w2-fengren）用例体（入口运行时 load——cases 禁 test_ 前缀防电池 glob 误收）。
# 覆盖（验收 ①~⑩）：
# ① spawn 新增 blade_tint/blade_style（缺省 saber + 青绿身份色读回）
# ② saber 深弯月弧刃顶点表（刀背控制点 (38,6)→(95,14)→(128,6)→(150,-10)、刃口 -Y 内收）
# ③ greatsword 读回（刃身宽 1.6×、暗黑底 Color(0.16,0.15,0.2) + 金刃口 Color(0.95,0.78,0.35)）
# ④ 弧光强化常量（20°→28°、宽 3.0→4.0）+ _draw 双式烟测
# ⑤ 判定零改动：150/120° 扇形命中数不变（2 内命中 −10、扇外不掉）
# ⑥ 掷骰挡弹两极（chance=0.0 零消弹 / =1.0 全消；缺省 -1 旧口径 nullify 派生）+
#    W9（nullify=true）恒 100% 逐位不变 + bullet_parry/bullet_nullified 双计数并存 +
#    emit_bullet_nullified 涟漪保持
# ⑦ 附着钩子（inert）：attach_requests 逐请求 apply_attach + host_elements 投递 +
#    请求空=零行为
# ⑧ 子斩结构（inert）：atk_mult/generation 缺省恒等 + 窗末一次性 ON_EXPIRE +
#    melee_split_request 消费（2 子斩窗：半径 ×0.55、atk=inherit、gen+1、facing±spread
#    均布）+ 代数硬帽 MAX_GENERATION=3 封顶 + 请求空零行为
# ⑨ 击退 spawn 快照：kb 快照直推 + Σadd_knock 平加池；W9 恒 0 零位移
# ⑩ tint 层级：有元素=blend_element_color()、无元素=blade_style 身份色
# ⑪ 套件总项数断言（R231 假绿教训）
extends RefCounted

const EXPECTED_TOTAL := 31                       # 30 用例断言 + 总项数断言自身

const BALLISTIC_SCENE := "res://scenes/combat/projectiles/ballistic_projectile.tscn"
const ENEMY_SCENE := "res://scenes/combat/enemies/enemy.tscn"
const DT := 1.0 / 120.0

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _stubs: Array = []                           # 收尾 free（Node 桩）
var _ripple: int = 0                             # emit_bullet_nullified 涟漪计数

# 世界夹具（一次搭建、计数全走 Δ）
var _proj_pool: ProjectilePool
var _enemy_pool: EnemyPool
var _grid: SpaceGrid
var _bullet_grid: SpaceGrid
var _pipeline: DamagePipelineStub
var _alive_enemies: Array[Node2D] = []
var _split_effect: TraitEffect                   # EF_FENGREN_SPLIT（ON_EXPIRE → melee_split_request）
var _attach_effect: TraitEffect                  # EF_FENGREN_ATTACH（ON_HIT → attach_requests）


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(20261008)
	_setup_world()
	_setup_test_effects()
	EventBus.bullet_nullified.connect(_on_ripple)
	# ── A 组：blade 参数化（①②③④⑩ + ⑧ 缺省恒等） ──
	_case1_default_saber()
	_case2_saber_crescent()
	_case3_greatsword()
	_case4_tint_hierarchy()
	_case5_tip_arc()
	_case6_draw_smoke()
	_case7_spawn_defaults()
	# ── B 组：W9 判定零改动 + 恒 100% 消弹 + 击退恒 0（⑤⑥⑨） ──
	_setup_enemies()
	_case8_judge_unchanged()
	_case9_w9_nullify_100()
	_case10_w9_knockback_zero()
	_teardown_enemies()
	# ── C 组：掷骰两极（⑥） ──
	_case11_block_chance_zero()
	_case12_block_chance_one()
	_case13_legacy_minus_one()
	# ── D 组：附着钩子（⑦） ──
	_setup_enemies()
	_case14_attach_requests()
	_case15_host_elements()
	_case16_attach_empty()
	# ── E 组：子斩结构（⑧） ──
	_case17_child_slashes()
	_case18_generation_cap()
	_case19_generation_direct_reject()
	_case20_split_request_empty()
	_case21_atk_mult_damage()
	# ── F 组：击退快照（⑨） ──
	_case22_knockback_snapshot()
	_case23_add_knock_pool()
	_teardown_enemies()
	_cleanup()
	_check("⑪ 套件总项数（EXPECTED=%d——R231 假绿教训）" % EXPECTED_TOTAL,
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


func _approx(p_a: float, p_b: float, p_tol: float = 0.001) -> bool:
	return absf(p_a - p_b) <= p_tol


func _col_eq(p_a: Color, p_b: Color, p_tol: float = 0.0001) -> bool:
	return p_a.r >= p_b.r - p_tol and p_a.r <= p_b.r + p_tol \
		and p_a.g >= p_b.g - p_tol and p_a.g <= p_b.g + p_tol \
		and p_a.b >= p_b.b - p_tol and p_a.b <= p_b.b + p_tol


func _on_ripple(_p_pos: Vector2) -> void:
	_ripple += 1


# ── 桩工厂 ────────────────────────────────────────────────────────
func _mk_melee_wd(p_melee: Dictionary, p_atk: float = 10.0,
		p_id: StringName = &"TST_FENGREN") -> WeaponData:
	var wd := WeaponData.new()
	wd.id = p_id
	wd.display_name = "TST_FENGREN"
	wd.form = GameConst.WeaponForm.MELEE
	wd.crit_rate = 0.0
	wd.crit_dmg = 2.0
	for i in range(5):
		var lv := WeaponLevelStats.new()
		lv.base_atk = p_atk
		lv.rof = 1.0
		lv.cd = 1.0
		wd.upgrade_table.append(lv)
	wd.melee = p_melee
	return wd


func _mk_weapon(p_melee: Dictionary, p_pos: Vector2, p_atk: float = 10.0) -> OrbitWeapon:
	var w := OrbitWeapon.new()
	tree.get_root().add_child(w)
	w.position = p_pos
	w.setup(_mk_melee_wd(p_melee, p_atk), null, {
		"pipeline": _pipeline,
		"projectile_pool": _proj_pool,
		"enemy_grid": _grid,
		"enemy_bullet_grid": _bullet_grid,
	})
	_stubs.append(w)
	return w


func _mk_slash(p_params: Dictionary, p_parent: Node = null) -> ArcSlash:
	# 独立挥斩实体（无 weapon 宿主——掷骰两极/代数直调等纯结构用例）
	var host: Node = p_parent if p_parent != null else tree.get_root()
	var s := ArcSlash.new()
	host.add_child(s)
	s.enemy_bullet_grid = _bullet_grid
	s.enemy_grid = _grid
	s.spawn(p_params)
	_stubs.append(s)
	return s


func _mk_trait(p_id: String, p_pool: int, p_effect: StringName, p_hooks: Array,
		p_params: Dictionary = {}) -> TraitData:
	var d := TraitData.new()
	d.id = StringName(p_id)
	d.display_name = p_id
	d.pool = p_pool
	d.pool_id = &""
	d.effect_id = p_effect
	d.value = 0.0
	d.params = p_params
	for h in p_hooks:
		d.event_hooks.append(int(h))
	d.stack_max = 1
	d.decay_delta = 0.0
	d.proc_chance = 1.0
	d.inheritable = false
	return d


func _attach_add(p_w: OrbitWeapon, p_pool: StringName, p_value: float) -> void:
	var t := TraitData.new()
	t.id = StringName("TST_" + String(p_pool))
	t.display_name = "TST"
	t.pool = GameConst.PoolClass.ADD
	t.pool_id = p_pool
	t.effect_id = &"EF_STAT"
	t.value = p_value
	t.stack_max = 3
	t.decay_delta = 0.85
	t.proc_chance = 1.0
	p_w.attach_trait(t)


func _attach_ele(p_w: OrbitWeapon, p_element: int) -> void:
	var t := TraitData.new()
	t.id = StringName("TST_ELE_%d" % p_element)
	t.display_name = "TST"
	t.pool = GameConst.PoolClass.ELEM
	t.pool_id = &""
	t.effect_id = &"EF_ELEMENTAL"
	t.value = 1.0
	t.params = {"element": p_element}
	t.proc_chance = 1.0
	p_w.attach_trait(t)


func _spawn_enemy(p_pos: Vector2, p_hp: float = 1000.0) -> Node2D:
	var d := EnemyData.new()
	d.id = StringName("E_FR_%d" % (_alive_enemies.size() + 1))
	d.display_name = String(d.id)
	d.hp_base = p_hp
	d.spd_base = 0.0
	d.dmg_base = 8.0
	d.exp_base = 3.0
	d.tp_cost = 1.0
	d.hitbox_r = 14.0
	var e := _enemy_pool.acquire() as Node2D
	e.call(&"spawn", d, 1, 0)
	e.position = p_pos
	_alive_enemies.append(e)
	_grid.rebuild(_alive_enemies)
	return e


func _spawn_enemy_bullet(p_pos: Vector2) -> ProjectileBase:
	var b := _proj_pool.acquire() as ProjectileBase
	b.damage_pipeline = _pipeline
	b.pool = _proj_pool
	b.spawn({
		"position": p_pos,
		"velocity": Vector2.ZERO,
		"lifetime": 10.0,
		"pierce": 1,
		"hitbox_radius": 6.0,
		"panel_snapshot": {"base_atk": 0.0},
		"team": 1,
	})
	return b


# ── 世界夹具 ──────────────────────────────────────────────────────
func _setup_world() -> void:
	_proj_pool = ProjectilePool.new()
	_proj_pool.name = "FengrenProjPool"
	tree.get_root().add_child(_proj_pool)
	_proj_pool.setup(&"fengren_test", load(BALLISTIC_SCENE), 64)
	var ep := EnemyPool.new()
	ep.name = "FengrenEnemyPool"
	tree.get_root().add_child(ep)
	ep.setup(&"fengren_enemy", load(ENEMY_SCENE), 32)
	_enemy_pool = ep
	_grid = SpaceGrid.new()
	_grid.configure(Vector2(720, 1280), 192.0)
	_bullet_grid = SpaceGrid.new()
	_bullet_grid.configure(Vector2(720, 1280), 192.0)
	_pipeline = DamagePipelineStub.new()
	_alive_enemies.clear()


func _setup_test_effects() -> void:
	# EF_FENGREN_SPLIT：ON_EXPIRE（宿主 = 近战载体）→ melee_split_request 输出
	#（w2-buff EF_FRACTAL melee 臂的桩替身——本任务只验载体侧消费结构）
	var split := GDScript.new()
	split.source_code = "extends TraitEffect\n" \
		+ "var requests: Array = []\n" \
		+ "func handle(p_trait, p_ctx) -> void:\n" \
		+ "\tif p_ctx.event == GameConst.TraitEvent.ON_EXPIRE and p_ctx.melee != null:\n" \
		+ "\t\tp_ctx.melee_split_request = {\"count\": 2, \"spread_deg\": 60.0, " \
		+ "\"inherit_ratio\": 0.4, \"echo\": false}\n" \
		+ "\t\trequests.append(p_ctx.melee)\n"
	split.reload()
	_split_effect = split.new() as TraitEffect
	TraitEffect.register_custom(&"EF_FENGREN_SPLIT", _split_effect)
	# EF_FENGREN_ATTACH：ON_HIT → attach_requests 数组输出（w3 ELE 多元素臂的桩替身）
	var attach := GDScript.new()
	attach.source_code = "extends TraitEffect\n" \
		+ "var hosts: Array = []\n" \
		+ "func handle(p_trait, p_ctx) -> void:\n" \
		+ "\tif p_ctx.event == GameConst.TraitEvent.ON_HIT:\n" \
		+ "\t\thosts.append(p_ctx.host_elements.duplicate())\n" \
		+ "\t\tp_ctx.attach_requests.append({\"element\": 1, \"value\": 25.0, \"overrides\": {}})\n"
	attach.reload()
	_attach_effect = attach.new() as TraitEffect
	TraitEffect.register_custom(&"EF_FENGREN_ATTACH", _attach_effect)


func _setup_enemies() -> void:
	_alive_enemies.clear()
	_grid.rebuild(_alive_enemies)


func _teardown_enemies() -> void:
	_alive_enemies.clear()
	_grid.rebuild(_alive_enemies)


func _cleanup() -> void:
	EventBus.bullet_nullified.disconnect(_on_ripple)
	for s in _stubs:
		if s != null and s is Node and is_instance_valid(s):
			(s as Node).free()
	_stubs.clear()
	if _proj_pool != null:
		_proj_pool.free()
		_proj_pool = null
	if _enemy_pool != null:
		_enemy_pool.free()
		_enemy_pool = null


# ── A 组：blade 参数化 ────────────────────────────────────────────
func _case1_default_saber() -> void:
	print("── ① blade_tint/blade_style 缺省（saber + 青绿身份色） ──")
	var s := _mk_slash({"slash_radius": 150.0, "arc_deg": 120.0})
	_check("①缺省 blade_style=saber 且 blade_tint=青绿 Color(0.35,0.92,0.55)",
		s.blade_style == ArcSlash.STYLE_SABER and _col_eq(s.blade_tint, ArcSlash.SABER_TINT),
		"style=%s tint=%s" % [str(s.blade_style), str(s.blade_tint)])
	if s is Node:
		s.free()


func _case2_saber_crescent() -> void:
	print("── ② saber 深弯月弧刃顶点表 ──")
	var s := _mk_slash({"blade_style": &"saber"})
	var poly := s._blade_polygon()
	var spine_ok := poly[0].is_equal_approx(Vector2(38.0, 6.0)) \
		and poly[1].is_equal_approx(Vector2(95.0, 14.0)) \
		and poly[2].is_equal_approx(Vector2(128.0, 6.0)) \
		and poly[3].is_equal_approx(Vector2(150.0, -10.0))
	# 刃口 -Y 侧弧线内收：中段最深 −13（R61 旧表 −26 → 内收过半）
	var edge_tucked := poly[5].is_equal_approx(Vector2(100.0, -13.0)) \
		and poly[4].is_equal_approx(Vector2(140.0, -20.0)) \
		and poly[6].is_equal_approx(Vector2(65.0, -11.0))
	_check("②saber 刀背控制点 (38,6)→(95,14)→(128,6)→(150,-10) 且刃口 -Y 内收（-26→-13）",
		spine_ok and edge_tucked, "poly=%s" % str(poly))
	if s is Node:
		s.free()


func _case3_greatsword() -> void:
	print("── ③ greatsword 式读回（w2-melee W13 消费） ──")
	var s := _mk_slash({"blade_style": &"greatsword"})
	var poly := s._blade_polygon()
	_check("③greatsword：blade_style 读回 + 缺省暗黑底 Color(0.16,0.15,0.2)",
		s.blade_style == ArcSlash.STYLE_GREATSWORD
			and _col_eq(s.blade_tint, Color(0.16, 0.15, 0.2)),
		"style=%s tint=%s" % [str(s.blade_style), str(s.blade_tint)])
	# 二cu DNF 巨剑直刃化：等宽直刃表 poly[1]=(118, 9×1.6=14.4)（旧弯月表 (95,22.4) 退役）
	_check("③greatsword：金刃口 Color(0.95,0.78,0.35) 常量 + 直刃等宽 9×1.6=14.4（二cu）",
		_col_eq(ArcSlash.GREATSWORD_EDGE, Color(0.95, 0.78, 0.35))
			and ArcSlash.GREATSWORD_WIDTH_MULT == 1.6
			and poly[1].is_equal_approx(Vector2(118.0, 14.4)),
		"edge=%s poly1=%s" % [str(ArcSlash.GREATSWORD_EDGE), str(poly[1])])
	if s is Node:
		s.free()


func _case4_tint_hierarchy() -> void:
	print("── ⑩ tint 层级（无元素=身份色 / 有元素=混色） ──")
	var w_ele := OrbitWeapon.new()
	tree.get_root().add_child(w_ele)
	w_ele.setup(_mk_melee_wd({"nullify": true}), null, {})
	_attach_ele(w_ele, GameConst.Element.FIR)
	var s_ele := ArcSlash.new()
	w_ele.add_child(s_ele)
	s_ele.weapon = w_ele
	s_ele.spawn({"slash_radius": 150.0})
	var blended: Color = w_ele.blend_element_color()
	_check("⑩有元素：blade_tint = weapon.blend_element_color()（火卡 → 元素色）",
		_col_eq(s_ele.blade_tint, blended) and not _col_eq(blended, Color.WHITE),
		"tint=%s blend=%s" % [str(s_ele.blade_tint), str(blended)])
	var s_plain := ArcSlash.new()
	var w_plain := OrbitWeapon.new()
	tree.get_root().add_child(w_plain)
	w_plain.setup(_mk_melee_wd({"nullify": true}), null, {})   # 无 ELE 卡（空池）
	s_plain.weapon = w_plain
	s_plain.spawn({"slash_radius": 150.0})
	_stubs.append(w_plain)
	_stubs.append(s_ele)
	_stubs.append(s_plain)
	_check("⑩无元素（空池）：blade_tint 回落 blade_style 身份色（青绿）",
		_col_eq(s_plain.blade_tint, ArcSlash.SABER_TINT),
		"tint=%s" % str(s_plain.blade_tint))


func _case5_tip_arc() -> void:
	print("── ④ 弧光强化常量（20°→28° / 3.0→4.0） ──")
	_check("④刀尖弧光 TIP_ARC_DEG=28.0 且 TIP_ARC_WIDTH=4.0",
		ArcSlash.TIP_ARC_DEG == 28.0 and ArcSlash.TIP_ARC_WIDTH == 4.0,
		"deg=%s w=%s" % [str(ArcSlash.TIP_ARC_DEG), str(ArcSlash.TIP_ARC_WIDTH)])


func _case6_draw_smoke() -> void:
	print("── ④ _draw 双式烟测（NOTIFICATION_DRAW 真通道，不炸即过） ──")
	var ok := true
	var detail := ""
	for style in [ArcSlash.STYLE_SABER, ArcSlash.STYLE_GREATSWORD]:
		var s := _mk_slash({"blade_style": style, "slash_radius": 150.0, "arc_deg": 120.0})
		s.open_window(0.0, Vector2(400, 640))
		if not s.visible:
			ok = false
			detail += "%s 开窗失败;" % String(style)
		# 经 NOTIFICATION_DRAW 派发（直接调 _draw 会被 canvas_item 绘制守卫拒绝）
		s.notification(CanvasItem.NOTIFICATION_DRAW)
		if s is Node:
			s.free()
	_check("④_draw 双式（saber/greatsword）窗口态绘制不炸且开窗可见", ok, detail)


func _case7_spawn_defaults() -> void:
	print("── ⑧ spawn 缺省恒等（旧调用方零位移） ──")
	var s := _mk_slash({"slash_radius": 150.0})
	_check("⑧缺省恒等：atk_mult=1.0 / generation=0 / block_chance=-1 / knockback=0.0",
		_approx(s.atk_mult, 1.0) and s.generation == 0
			and _approx(s.block_chance, -1.0) and _approx(s.knockback, 0.0),
		"atk=%s gen=%d chance=%s kb=%s" % [str(s.atk_mult), s.generation,
			str(s.block_chance), str(s.knockback)])
	if s is Node:
		s.free()


# ── B 组：W9 判定零改动 + 恒 100% + 击退恒 0 ─────────────────────
func _case8_judge_unchanged() -> void:
	print("── ⑤ 判定零改动（150/120° 扇形命中数不变） ──")
	var w := _mk_weapon({"nullify": true, "slash_radius": 150.0, "arc_deg": 120.0,
		"max_targets": 8, "knockback": 0.0}, Vector2(360, 640))
	var e_in1 := _spawn_enemy(Vector2(440, 640))      # 0° 80px
	var e_in2 := _spawn_enemy(Vector2(463.9, 700))    # 30° 120px
	var e_out := _spawn_enemy(Vector2(360, 760))      # 90° 扇外
	w.cooldown_left = 10.0                            # 阻断 try_fire（保持窗口朝向）
	w._slash_window(0.0, false)
	w.tick(DT)
	_check("⑤扇形口径不变：0°/30° 内弧各 −10、90° 扇外不掉（命中数 2 不变）",
		_approx(e_in1.hp, 990.0, 0.01) and _approx(e_in2.hp, 990.0, 0.01)
			and _approx(e_out.hp, 1000.0, 0.01),
		"A=%s B=%s C=%s" % [str(e_in1.hp), str(e_in2.hp), str(e_out.hp)])
	_stubs.erase(w)
	w.free()


func _case9_w9_nullify_100() -> void:
	print("── ⑥ W9（nullify=true）恒 100% 消弹逐位不变 ──")
	var w := _mk_weapon({"nullify": true, "slash_radius": 150.0, "arc_deg": 120.0,
		"max_targets": 8, "knockback": 0.0}, Vector2(360, 640))
	w.cooldown_left = 10.0
	w._slash_window(0.0, false)
	w.tick(DT)                                        # 消耗首帧判定
	var b_in1 := _spawn_enemy_bullet(Vector2(460, 640))
	var b_in2 := _spawn_enemy_bullet(Vector2(463.9, 700))
	var b_out := _spawn_enemy_bullet(Vector2(360, 780))
	var bullets: Array[Node2D] = [b_in1, b_in2, b_out]
	_bullet_grid.rebuild(bullets)
	var rz0: int = DebugStats.get_counter(
		&"recycle_reason_%d" % GameConst.RecycleReason.NULLIFIED)
	var bn0: int = DebugStats.get_counter(&"bullet_nullified")
	var bp0: int = DebugStats.get_counter(&"bullet_parry")
	var free0: int = int(_proj_pool.stats()["free"])
	var ripple0 := _ripple
	w.cooldown_left = 10.0
	w.tick(DT)                                        # 窗口期第 2 帧：掷骰（恒 1.0 确定性）
	var rz_now: int = DebugStats.get_counter(
		&"recycle_reason_%d" % GameConst.RecycleReason.NULLIFIED)
	_check("⑥W9 恒 100%：弧内 2 弹 NULLIFIED 统一收束（recycle Δ2）、弧外存活",
		rz_now == rz0 + 2 and b_out.visible,
		"rzΔ=%d out_visible=%s" % [rz_now - rz0, str(b_out.visible)])
	_check("⑥bullet_parry 与 bullet_nullified 双计数并存（各 +2）+ 涟漪保持（+2）",
		DebugStats.get_counter(&"bullet_parry") == bp0 + 2
			and DebugStats.get_counter(&"bullet_nullified") == bn0 + 2
			and _ripple == ripple0 + 2,
		"parryΔ=%d nullΔ=%d rippleΔ=%d" % [
			DebugStats.get_counter(&"bullet_parry") - bp0,
			DebugStats.get_counter(&"bullet_nullified") - bn0,
			_ripple - ripple0])
	_check("⑥弹池回收 +2（free 计数）",
		int(_proj_pool.stats()["free"]) == free0 + 2,
		"freeΔ=%d" % (int(_proj_pool.stats()["free"]) - free0))
	_stubs.erase(w)
	w.free()


func _case10_w9_knockback_zero() -> void:
	print("── ⑨ W9 击退恒 0 零位移 ──")
	var w := _mk_weapon({"nullify": true, "slash_radius": 150.0, "arc_deg": 120.0,
		"max_targets": 8, "knockback": 0.0}, Vector2(360, 640))
	var e := _spawn_enemy(Vector2(440, 640))
	w.cooldown_left = 10.0
	w._slash_window(0.0, false)
	w.tick(DT)
	_check("⑨W9 快照 0：命中敌 knock_vel 恒零（零位移）",
		_approx(e.hp, 990.0, 0.01) and e.get("knock_vel") == Vector2.ZERO,
		"hp=%s kv=%s" % [str(e.hp), str(e.get("knock_vel"))])
	_stubs.erase(w)
	w.free()


# ── C 组：掷骰两极（不测中间采样——§3.4） ─────────────────────────
func _mk_bullets_in_arc() -> Array[Node2D]:
	var out: Array[Node2D] = [
		_spawn_enemy_bullet(Vector2(740, 640)),
		_spawn_enemy_bullet(Vector2(726.4, 680)),
		_spawn_enemy_bullet(Vector2(700, 713.9)),
	]
	return out


func _rebuild_bullet_grid(p_bullets: Array[Node2D] = []) -> void:
	_bullet_grid.rebuild(p_bullets)


func _case11_block_chance_zero() -> void:
	print("── ⑥ 掷骰两极：chance=0.0 零消弹 ──")
	var s := _mk_slash({"slash_radius": 150.0, "arc_deg": 120.0, "block_chance": 0.0,
		"nullify": false})
	var bullets := _mk_bullets_in_arc()
	_bullet_grid.rebuild(bullets)
	var bp0: int = DebugStats.get_counter(&"bullet_parry")
	s.open_window(0.0, Vector2(640, 640))
	s.tick(DT, Vector2(640, 640))
	var alive := 0
	for b in bullets:
		if b.visible:
			alive += 1
	_check("⑥chance=0.0：零消弹（parry Δ0、3 弹全存活）",
		DebugStats.get_counter(&"bullet_parry") == bp0 and alive == 3,
		"parryΔ=%d alive=%d" % [DebugStats.get_counter(&"bullet_parry") - bp0, alive])
	_rebuild_bullet_grid()


func _case12_block_chance_one() -> void:
	print("── ⑥ 掷骰两极：chance=1.0 全消 ──")
	var s := _mk_slash({"slash_radius": 150.0, "arc_deg": 120.0, "block_chance": 1.0,
		"nullify": false})
	var bullets := _mk_bullets_in_arc()
	_bullet_grid.rebuild(bullets)
	var bp0: int = DebugStats.get_counter(&"bullet_parry")
	var free0: int = int(_proj_pool.stats()["free"])
	s.open_window(0.0, Vector2(640, 640))
	s.tick(DT, Vector2(640, 640))
	_check("⑥chance=1.0：确定性全消（parry Δ3、free +3）",
		DebugStats.get_counter(&"bullet_parry") == bp0 + 3
			and int(_proj_pool.stats()["free"]) == free0 + 3,
		"parryΔ=%d" % (DebugStats.get_counter(&"bullet_parry") - bp0))
	_rebuild_bullet_grid()


func _case13_legacy_minus_one() -> void:
	print("── ⑥ 缺省 -1 旧口径（nullify 派生——桩夹具零位移） ──")
	var s_on := _mk_slash({"slash_radius": 150.0, "arc_deg": 120.0, "nullify": true})
	var bullets_on := _mk_bullets_in_arc()
	_bullet_grid.rebuild(bullets_on)
	s_on.open_window(0.0, Vector2(640, 640))
	s_on.tick(DT, Vector2(640, 640))
	var on_alive := 0
	for b in bullets_on:
		if b.visible:
			on_alive += 1
	_rebuild_bullet_grid()
	var s_off := _mk_slash({"slash_radius": 150.0, "arc_deg": 120.0, "nullify": false})
	var bullets_off := _mk_bullets_in_arc()
	_bullet_grid.rebuild(bullets_off)
	s_off.open_window(0.0, Vector2(640, 640))
	s_off.tick(DT, Vector2(640, 640))
	var off_alive := 0
	for b in bullets_off:
		if b.visible:
			off_alive += 1
	_check("⑥缺省 -1：nullify=true → 全消（存活 0）/ nullify=false → 零消弹（存活 3）",
		on_alive == 0 and off_alive == 3, "on=%d off=%d" % [on_alive, off_alive])
	_rebuild_bullet_grid()


# ── D 组：附着钩子（⑦ inert） ────────────────────────────────────
func _case14_attach_requests() -> void:
	print("── ⑦ attach_requests 逐请求 apply_attach ──")
	var w := _mk_weapon({"nullify": true, "slash_radius": 150.0, "arc_deg": 120.0,
		"max_targets": 8, "knockback": 0.0}, Vector2(360, 640))
	var spy := SpyElem.new()
	w.elemental = spy
	w.attach_trait(_mk_trait("TST_FR_ATTACH", GameConst.PoolClass.MECH,
		&"EF_FENGREN_ATTACH", [GameConst.TraitEvent.ON_HIT]))
	var e := _spawn_enemy(Vector2(440, 640))
	w.cooldown_left = 10.0
	w._slash_window(0.0, false)
	w.tick(DT)
	_check("⑦attach 消费：请求 (element=1, value=25) 逐条 apply_attach，快照=当跳结算 10.0",
		e.hp < 1000.0 and spy.calls.size() == 1
			and int(spy.calls[0][0]) == int(GameConst.Element.FIR)
			and _approx(float(spy.calls[0][1]), 25.0)
			and _approx(float(spy.calls[0][2]), 10.0),
		"calls=%s hp=%s" % [str(spy.calls), str(e.hp)])
	_stubs.erase(w)
	w.free()


func _case15_host_elements() -> void:
	print("── ⑦ host_elements 投递（§6.4 守卫输入） ──")
	(_attach_effect as Object).set("hosts", [])    # 效果单例跨用例共享——先清记录
	var w := _mk_weapon({"nullify": true, "slash_radius": 150.0, "arc_deg": 120.0,
		"max_targets": 8, "knockback": 0.0}, Vector2(360, 640))
	var spy := SpyElem.new()
	w.elemental = spy
	w.attach_trait(_mk_trait("TST_FR_ATTACH2", GameConst.PoolClass.MECH,
		&"EF_FENGREN_ATTACH", [GameConst.TraitEvent.ON_HIT]))
	_spawn_enemy(Vector2(440, 640))
	w.cooldown_left = 10.0
	w._slash_window(0.0, false)
	w.tick(DT)
	var hosts_no_ele: Array = (_attach_effect as Object).get("hosts")
	var empty_ok: bool = hosts_no_ele.size() == 1 and (hosts_no_ele[0] as Array).is_empty()
	_attach_ele(w, GameConst.Element.FIR)
	w._slash_window(0.0, false)
	w.cooldown_left = 10.0
	GameConfig.frame_stamp += 1                # E-03 帧闸推进（跨帧二次派发放行）
	w.tick(DT)
	var hosts_ele: Array = (_attach_effect as Object).get("hosts")
	var ele_ok: bool = hosts_ele.size() == 2 \
		and (hosts_ele[1] as Array).size() == 1 \
		and int((hosts_ele[1] as Array)[0]) == int(GameConst.Element.FIR)
	_check("⑦host_elements = weapon._element_pool()（空池=[]；火卡=[FIR]）",
		empty_ok and ele_ok, "no_ele=%s ele=%s" % [str(hosts_no_ele), str(hosts_ele)])
	_stubs.erase(w)
	w.free()


func _case16_attach_empty() -> void:
	print("── ⑦ 请求空 = 零行为 ──")
	var w := _mk_weapon({"nullify": true, "slash_radius": 150.0, "arc_deg": 120.0,
		"max_targets": 8, "knockback": 0.0}, Vector2(360, 640))
	var spy := SpyElem.new()
	w.elemental = spy
	_spawn_enemy(Vector2(440, 640))
	w.cooldown_left = 10.0
	w._slash_window(0.0, false)
	w.tick(DT)
	_check("⑦无词条：attach_requests 空 → apply_attach 零调用（命中照常）",
		spy.calls.is_empty(), "calls=%s" % str(spy.calls))
	_stubs.erase(w)
	w.free()


# ── E 组：子斩结构（⑧ inert） ────────────────────────────────────
func _walk_children(p_root: ArcSlash) -> Array:
	# BFS 收集全部派生子斩（含孙代）
	var out: Array = []
	var queue: Array = [p_root]
	while not queue.is_empty():
		var node: ArcSlash = queue.pop_front()
		for c in node._child_slashes:
			if c != null and is_instance_valid(c):
				out.append(c)
				queue.append(c)
	return out


func _case17_child_slashes() -> void:
	print("── ⑧ 窗末 ON_EXPIRE + melee_split_request 消费（2 子斩窗） ──")
	var w := _mk_weapon({"nullify": true, "slash_radius": 150.0, "arc_deg": 120.0,
		"max_targets": 8, "knockback": 0.0}, Vector2(360, 640))
	w.attach_trait(_mk_trait("TST_FR_SPLIT", GameConst.PoolClass.MECH,
		&"EF_FENGREN_SPLIT", [GameConst.TraitEvent.ON_EXPIRE]))
	w.cooldown_left = 10.0
	w._slash_window(0.0, false)
	var parent: ArcSlash = w.arc_slash
	var children: Array = []
	for i in range(41):                               # 0.34s @DT → 第 41 帧归 0
		w.cooldown_left = 10.0
		GameConfig.frame_stamp += 1                   # E-03 帧闸推进（真机每帧递增同口径）
		w.tick(DT)
		if not parent._child_slashes.is_empty() and children.is_empty():
			children = parent._child_slashes.duplicate()
	var c0: ArcSlash = children[0] if children.size() > 0 else null
	var c1: ArcSlash = children[1] if children.size() > 1 else null
	var struct_ok: bool = children.size() == 2 and c0 != null and c1 != null \
		and c0.generation == 1 and c1.generation == 1 \
		and _approx(c0.atk_mult, 0.4) and _approx(c1.atk_mult, 0.4) \
		and _approx(c0.slash_radius, 82.5) and _approx(c1.slash_radius, 82.5) \
		and c0.window_left > 0.0 and c1.window_left > 0.0
	_check("⑧窗末派生 2 子斩窗：generation=1、atk_mult=0.4、半径 150×0.55=82.5、窗口激活",
		struct_ok, "n=%d gen=%s atk=%s r=%s" % [children.size(),
			str([c0.generation if c0 != null else -1, c1.generation if c1 != null else -1]),
			str([c0.atk_mult if c0 != null else -1.0, c1.atk_mult if c1 != null else -1.0]),
			str([c0.slash_radius if c0 != null else -1.0])])
	var spread := deg_to_rad(60.0)
	var facing_ok: bool = c0 != null and c1 != null \
		and _approx(c0.facing, -spread, 0.0001) and _approx(c1.facing, spread, 0.0001)
	_check("⑧facing±spread 均布：facing 0 ± 60° → 子斩朝向 [-60°, +60°]", facing_ok,
		"f0=%s f1=%s" % [str(c0.facing if c0 != null else NAN),
			str(c1.facing if c1 != null else NAN)])
	_check("⑧窗末一次性闸：parent._expire_fired=true 且请求消费恰 1 次（派发序首帧）",
		parent._expire_fired
			and (_split_effect as Object).get("requests").size() == 1,
		"fired=%s req=%d" % [str(parent._expire_fired),
			(_split_effect as Object).get("requests").size()])
	_stubs.erase(w)
	w.free()


func _case18_generation_cap() -> void:
	print("── ⑧ 代数硬帽 MAX_GENERATION=3 封顶（链式静默） ──")
	var w := _mk_weapon({"nullify": true, "slash_radius": 150.0, "arc_deg": 120.0,
		"max_targets": 8, "knockback": 0.0}, Vector2(360, 640))
	w.attach_trait(_mk_trait("TST_FR_SPLIT2", GameConst.PoolClass.MECH,
		&"EF_FENGREN_SPLIT", [GameConst.TraitEvent.ON_EXPIRE]))
	w.cooldown_left = 10.0
	w._slash_window(0.0, false)
	var parent: ArcSlash = w.arc_slash
	var sg0: int = DebugStats.get_counter(&"split_rejected_generation")
	for i in range(400):                              # 链式全静默（4 代窗口 + E-03 去重余量）
		w.cooldown_left = 10.0
		GameConfig.frame_stamp += 1                   # E-03 帧闸推进（每帧一代新派发额度）
		w.tick(DT)
	var all := _walk_children(parent)
	var gens := {}
	var max_gen := 0
	for c in all:
		gens[(c as ArcSlash).generation] = true
		max_gen = maxi(max_gen, (c as ArcSlash).generation)
	# 同帧孪生子斩共享武器词条栈——E-03 本帧已触发闸仅放行首者派发（引擎既有语义），
	# 确定性链 = 2(gen1) + 2(gen2) + 2(gen3)；gen3 窗末请求写入后被代数硬帽拒绝。
	_check("⑧链式封顶：2+2+2=6 子斩、generation ∈ {1,2,3}（无 gen4——硬帽结构性封顶）",
		all.size() == 6 and max_gen == 3 and gens.size() == 3,
		"n=%d maxgen=%d gens=%s" % [all.size(), max_gen, str(gens.keys())])
	_check("⑧gen3 再裂被代数硬帽拒绝：split_rejected_generation Δ1",
		DebugStats.get_counter(&"split_rejected_generation") == sg0 + 1,
		"rejectedΔ=%d" % (DebugStats.get_counter(&"split_rejected_generation") - sg0))
	_stubs.erase(w)
	w.free()


func _case19_generation_direct_reject() -> void:
	print("── ⑧ generation=3 直调拒绝 ──")
	var s := _mk_slash({"slash_radius": 150.0, "generation": 3})
	var sg0: int = DebugStats.get_counter(&"split_rejected_generation")
	s._open_child_slashes(Vector2(640, 640),
		{"count": 2, "spread_deg": 60.0, "inherit_ratio": 0.4})
	_check("⑧gen3 +1=4 > 3：零子斩 + split_rejected_generation 计数 +1",
		s._child_slashes.is_empty()
			and DebugStats.get_counter(&"split_rejected_generation") == sg0 + 1,
		"n=%d Δ=%d" % [s._child_slashes.size(),
			DebugStats.get_counter(&"split_rejected_generation") - sg0])
	if s is Node:
		s.free()


func _case20_split_request_empty() -> void:
	print("── ⑧ 请求空 = 零行为 ──")
	var w := _mk_weapon({"nullify": true, "slash_radius": 150.0, "arc_deg": 120.0,
		"max_targets": 8, "knockback": 0.0}, Vector2(360, 640))
	w.cooldown_left = 10.0
	w._slash_window(0.0, false)
	var parent: ArcSlash = w.arc_slash
	for i in range(45):
		w.cooldown_left = 10.0
		GameConfig.frame_stamp += 1
		w.tick(DT)
	_check("⑧无词条（无 ON_EXPIRE 挂钩）：窗末零派发零子斩",
		parent._expire_fired and parent._child_slashes.is_empty(),
		"fired=%s n=%d" % [str(parent._expire_fired), parent._child_slashes.size()])
	_stubs.erase(w)
	w.free()


func _case21_atk_mult_damage() -> void:
	print("── ⑧ atk_mult 伤害链（ctx.base_atk 乘区） ──")
	var w := _mk_weapon({"nullify": true, "slash_radius": 150.0, "arc_deg": 120.0,
		"max_targets": 8, "knockback": 0.0}, Vector2(360, 640))
	var e := _spawn_enemy(Vector2(440, 640))
	w.cooldown_left = 10.0
	w._slash_window(0.0, false)
	var default_mult: float = w.arc_slash.atk_mult
	w.arc_slash.atk_mult = 0.4                        # 子斩伤害比直设（spawn 键同源）
	w.tick(DT)
	_check("⑧atk_mult=0.4 → 落血 4.0（10×0.4）；缺省读回 1.0",
		_approx(default_mult, 1.0) and _approx(e.hp, 996.0, 0.01),
		"default=%s hp=%s" % [str(default_mult), str(e.hp)])
	_stubs.erase(w)
	w.free()


# ── F 组：击退 spawn 快照（⑨） ───────────────────────────────────
func _case22_knockback_snapshot() -> void:
	print("── ⑨ 击退 = spawn knockback 快照（径向） ──")
	var w := _mk_weapon({"nullify": true, "slash_radius": 150.0, "arc_deg": 120.0,
		"max_targets": 8, "knockback": 100.0}, Vector2(360, 640))
	var e := _spawn_enemy(Vector2(440, 640))          # 0° 80px → 径向 +X
	w.cooldown_left = 10.0
	w._slash_window(0.0, false)
	w.tick(DT)
	var kv: Vector2 = e.get("knock_vel")
	_check("⑨快照 100 → knock_vel=径向(900,0)（Enemy 冲量 ×9 通道）",
		_approx(e.hp, 990.0, 0.01) and kv.is_equal_approx(Vector2(900.0, 0.0)),
		"hp=%s kv=%s" % [str(e.hp), str(kv)])
	_stubs.erase(w)
	w.free()


func _case23_add_knock_pool() -> void:
	print("── ⑨ Σadd_knock 平加池（knockback_force 同源） ──")
	var w := _mk_weapon({"nullify": true, "slash_radius": 150.0, "arc_deg": 120.0,
		"max_targets": 8, "knockback": 0.0}, Vector2(360, 640))
	_attach_add(w, &"add_knock", 30.0)
	var e := _spawn_enemy(Vector2(440, 640))
	w.cooldown_left = 10.0
	w._slash_window(0.0, false)
	w.tick(DT)
	var kv: Vector2 = e.get("knock_vel")
	_check("⑨快照 0 + Σadd_knock=30 → knock_vel=(270,0)（平加池直推）",
		kv.is_equal_approx(Vector2(270.0, 0.0)), "kv=%s" % str(kv))
	_stubs.erase(w)
	w.free()


# ── ⑦ spy 元素系统（apply_attach 记录桩——不落状态） ──────────────
class SpyElem extends ElementalSystem:
	var calls: Array = []                        # [element, value, snapshot] 记录

	func apply_attach(p_enemy: Node2D, p_element: int, p_value: float,
			p_info: Dictionary = {}) -> void:
		calls.append([p_element, p_value, float(p_info.get("snapshot", 0.0))])

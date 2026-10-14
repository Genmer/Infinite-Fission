# tests/runner/r243_elem_cases.gd
# R243 多元素全效果触发+混色（w3-element）用例体（入口运行时 load——cases 禁 test_ 前缀
# 防电池 glob 误收）。覆盖（验收 ①~⑦）：
# ① 七张 ELE 卡（IGNITE/FREEZE/SHOCK/HYDRO/GEO/DENDRO/ANEMO）tres 读回：
#    required_forms == [0,1,2,3] 且 excluded_weapons == [&"W8_orbit_field"]（§6.2）
# ② attach_requests 并发附着链：双 ELE 卡数组输出（挂载序）+ 单槽 attach_request=末位
#    （后位覆写兼容）+ 单元素栈逐字节不变；消费端 _apply_elemental 数组逐条附着且
#    单槽分支跳过（防双发）+ 旧单槽路径（空数组）兼容
# ③ host_elements 集合守卫：池外元素卡零产出；空池 = 无限制旧语义（KIN 直挂通道）
# ④ 混色 blend_element_color（R243 迁移/发现修复——HSV 色相插值替代 RGB 均值）：
#    双元素 = 饱和保真 + 明度成员均值；单元素 = 该色且与 dominant_element 同值；
#    空池 = 白
# ⑤ 激光豁免回归：_laser_second_elem_blocked 维持（持元素激光第二张拒 / 无元素与
#    非激光 false）+ 主束真源 dominant 恒首卡
# ⑥ W9 斩击附着：挂火卡 _slash_hit 钩子 → 敌 gauges[FIR]==22（真元素系统真 gauge）
# ⑦ W8 不可挂 ELE：mount_gate_allows excluded_weapons 门拒（七卡全拒；W9/W13/弹道放行）
# ⑧ homing spawn attach_elements 接线：spawned proj.attach_elements == [FIR] →
#    _build_trait_ctx.host_elements == [FIR]（守卫输入贯通）
# ⑨ 套件总项数断言（R231 假绿教训）
extends RefCounted

const EXPECTED_TOTAL := 33                       # 32 用例断言 + 总项数断言自身

const PROJ_SCENE := "res://scenes/combat/projectiles/ballistic_projectile.tscn"
const ENEMY_SCENE := "res://scenes/combat/enemies/enemy.tscn"
const DT := 1.0 / 120.0

const ELE_IDS: Array[String] = ["ELE_IGNITE", "ELE_FREEZE", "ELE_SHOCK", "ELE_HYDRO",
	"ELE_GEO", "ELE_DENDRO", "ELE_ANEMO"]

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _stubs: Array = []                           # 收尾 free（Node 桩）

# 世界夹具（一次搭建、计数全走 Δ）
var _proj_pool: ProjectilePool
var _enemy_pool: EnemyPool
var _grid: SpaceGrid
var _bullet_grid: SpaceGrid
var _pipeline: DamagePipelineStub
var _elem_sys: ElementalSystem                   # 真件元素系统（gauge 断言通道）
var _alive_enemies: Array[Node2D] = []


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(20261008)
	_setup_world()
	# ── A 组：① 七卡扩门（tres 读回） ──
	_case1_seven_cards()
	# ── B 组：② attach_requests 数组输出 + 单槽兼容（通道级） ──
	_case2_array_output()
	_case3_single_compat()
	# ── C 组：③ host_elements 集合守卫 ──
	_case4_guard_blocks()
	_case5_guard_empty_legacy()
	# ── D 组：④ 混色三断言 ──
	_case6_blend_dual()
	_case7_blend_single()
	_case8_blend_empty()
	# ── E 组：① 端到端一击双附着（真弹体+真元素系统+真 gauge） ──
	_setup_enemies()
	_case9_e2e_dual_attach()
	_teardown_enemies()
	# ── F 组：② 消费端（数组防双发 + 旧单槽兼容） ──
	_setup_enemies()
	_case10_consume_array()
	_case11_consume_legacy()
	_teardown_enemies()
	# ── G 组：⑤ 激光豁免回归 ──
	_case12_laser_gate()
	# ── H 组：⑥ W9 斩击附着（w2-fengren _slash_hit 钩子） ──
	_setup_enemies()
	_case13_w9_slash_attach()
	_teardown_enemies()
	# ── I 组：⑦ W8 excluded_weapons 门拒 ──
	_case14_w8_gate()
	# ── J 组：⑧ homing attach_elements 接线 ──
	_setup_enemies()
	_case15_homing_attach()
	_teardown_enemies()
	_cleanup()
	_check("⑨ 套件总项数（EXPECTED=%d——R231 假绿教训）" % EXPECTED_TOTAL,
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


func _col_eq(p_a: Color, p_b: Color, p_tol: float = 0.001) -> bool:
	return p_a.r >= p_b.r - p_tol and p_a.r <= p_b.r + p_tol \
		and p_a.g >= p_b.g - p_tol and p_a.g <= p_b.g + p_tol \
		and p_a.b >= p_b.b - p_tol and p_a.b <= p_b.b + p_tol


func _ele(p_id: String) -> TraitData:
	return load("res://resources/traits/%s.tres" % p_id) as TraitData


func _kill_live_projs() -> void:
	for node in _proj_pool.active_projectiles():
		(node as ProjectileBase).nullify()


# ── 桩工厂 ────────────────────────────────────────────────────────
func _mk_wd(p_form: int, p_id: StringName, p_atk: float = 10.0) -> WeaponData:
	var wd := WeaponData.new()
	wd.id = p_id
	wd.display_name = String(p_id)
	wd.form = p_form
	wd.crit_rate = 0.0
	wd.crit_dmg = 2.0
	for i in range(5):
		var lv := WeaponLevelStats.new()
		lv.base_atk = p_atk
		lv.rof = 1.0
		lv.cd = 1.0
		wd.upgrade_table.append(lv)
	return wd


func _mk_melee_wd(p_melee: Dictionary, p_id: StringName = &"TST_ELEM_W",
		p_atk: float = 10.0) -> WeaponData:
	var wd := _mk_wd(GameConst.WeaponForm.MELEE, p_id, p_atk)
	wd.melee = p_melee
	return wd


func _mk_weapon(p_wd: WeaponData, p_pos: Vector2) -> WeaponBase:
	var w := OrbitWeapon.new()
	tree.get_root().add_child(w)
	w.position = p_pos
	w.setup(p_wd, null, {
		"pipeline": _pipeline,
		"projectile_pool": _proj_pool,
		"enemy_grid": _grid,
		"enemy_bullet_grid": _bullet_grid,
	})
	_stubs.append(w)
	return w


func _mk_weapon_of(p_class: GDScript, p_wd: WeaponData) -> WeaponBase:
	# 任意武器类桩（Laser/Ballistic 门用例——形态真源在 data，类身份按用例语义选）
	var w: WeaponBase = p_class.new()
	tree.get_root().add_child(w)
	w.setup(p_wd, null, {})
	_stubs.append(w)
	return w


func _spawn_proj(p_params: Dictionary, p_spy: ElementalSystem = null) -> ProjectileBase:
	var proj := _proj_pool.acquire() as ProjectileBase
	proj.damage_pipeline = _pipeline
	proj.enemy_grid = _grid
	proj.pool = _proj_pool
	proj.elemental = p_spy if p_spy != null else _elem_sys
	proj.spawn(p_params.duplicate())
	return proj


func _spawn_enemy(p_pos: Vector2, p_hp: float = 1000.0) -> Node2D:
	var d := EnemyData.new()
	d.id = StringName("E_W3ELEM_%d" % (_alive_enemies.size() + 1))
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


func _dual_stack(p_a: String, p_b: String) -> TraitStack:
	var stack := TraitStack.new()
	stack.attach(_ele(p_a))
	stack.attach(_ele(p_b))
	return stack


# ── 世界夹具 ──────────────────────────────────────────────────────
func _setup_world() -> void:
	_proj_pool = ProjectilePool.new()
	_proj_pool.name = "W3ElemProjPool"
	tree.get_root().add_child(_proj_pool)
	_proj_pool.setup(&"w3_elem_test", load(PROJ_SCENE), 64)
	var ep := EnemyPool.new()
	ep.name = "W3ElemEnemyPool"
	tree.get_root().add_child(ep)
	ep.setup(&"w3_elem_enemy", load(ENEMY_SCENE), 16)
	_enemy_pool = ep
	_grid = SpaceGrid.new()
	_grid.configure(Vector2(720, 1280), 192.0)
	_bullet_grid = SpaceGrid.new()
	_bullet_grid.configure(Vector2(720, 1280), 192.0)
	_pipeline = DamagePipelineStub.new()
	var real_pipe := DamagePipeline.new()
	real_pipe.set_rng_seed(42)
	_elem_sys = ElementalSystem.new()
	_elem_sys.name = "W3ElemElementalSystem"
	tree.get_root().add_child(_elem_sys)
	_elem_sys.pipeline = real_pipe
	_elem_sys.enemy_grid = _grid
	_alive_enemies.clear()


func _setup_enemies() -> void:
	_kill_live_projs()
	_alive_enemies.clear()
	_grid.rebuild(_alive_enemies)


func _teardown_enemies() -> void:
	_alive_enemies.clear()
	_grid.rebuild(_alive_enemies)


func _cleanup() -> void:
	_kill_live_projs()
	for s in _stubs:
		if s != null and s is Node and is_instance_valid(s):
			(s as Node).free()
	_stubs.clear()
	if _elem_sys != null:
		_elem_sys.free()
		_elem_sys = null
	if _proj_pool != null:
		_proj_pool.free()
		_proj_pool = null
	if _enemy_pool != null:
		_enemy_pool.free()
		_enemy_pool = null


# ── A 组：① 七卡扩门（tres 读回，§6.2） ───────────────────────────
func _case1_seven_cards() -> void:
	print("── ① 七张 ELE 卡 required_forms [0,1,2,3] + excluded_weapons [W8] ──")
	for eid in ELE_IDS:
		var t := _ele(eid)
		var forms: Variant = t.params.get("required_forms", null) if t != null else null
		var excluded: Variant = t.params.get("excluded_weapons", null) if t != null else null
		_check("①%s：required_forms==[0,1,2,3] 且 excluded_weapons==[&\"W8_orbit_field\"]" % eid,
			t != null and forms is Array and (forms as Array) == [0, 1, 2, 3]
				and excluded is Array and (excluded as Array) == [&"W8_orbit_field"],
			"forms=%s excl=%s" % [str(forms), str(excluded)])


# ── B 组：② attach_requests 数组输出 + 单槽兼容（通道级） ─────────
func _case2_array_output() -> void:
	print("── ② 双 ELE 卡并发：数组输出（挂载序）+ 单槽=末位后位覆写 ──")
	var stack := _dual_stack("ELE_IGNITE", "ELE_FREEZE")   # 挂载序 FIR→ICE
	var ctx := TraitContext.new()
	ctx.event = GameConst.TraitEvent.ON_HIT
	var pool: Array[int] = [GameConst.Element.FIR, GameConst.Element.ICE]
	ctx.host_elements = pool
	stack.dispatch(GameConst.TraitEvent.ON_HIT, ctx)
	var reqs: Array[Dictionary] = ctx.attach_requests
	var arr_ok: bool = reqs.size() == 2 \
		and int(reqs[0].get("element", -1)) == int(GameConst.Element.FIR) \
		and _approx(float(reqs[0].get("value", -1.0)), 22.0) \
		and int(reqs[1].get("element", -1)) == int(GameConst.Element.ICE) \
		and _approx(float(reqs[1].get("value", -1.0)), 22.0) \
		and (reqs[0].get("overrides", null) is Dictionary) \
		and (reqs[0].get("overrides", {}) as Dictionary).is_empty()
	_check("②双卡：attach_requests 按挂载序 [{FIR,22,{}},{ICE,22,{}}] 并发输出", arr_ok,
		"reqs=%s" % str(reqs))
	_check("②单槽兼容：attach_request == attach_requests[-1]（后位覆写 = ICE 条目）",
		ctx.attach_request == reqs[-1],
		"slot=%s last=%s" % [str(ctx.attach_request), str(reqs[-1])])


func _case3_single_compat() -> void:
	print("── ② 单元素栈：单槽逐字节不变（旧断言零位移口径） ──")
	var stack := TraitStack.new()
	stack.attach(_ele("ELE_IGNITE"))
	var ctx := TraitContext.new()
	ctx.event = GameConst.TraitEvent.ON_HIT
	stack.dispatch(GameConst.TraitEvent.ON_HIT, ctx)
	_check("②单卡：attach_requests 恰 1 条且 attach_request 逐字节 == {FIR, 22.0, {}}",
		ctx.attach_requests.size() == 1
			and ctx.attach_request == {"element": GameConst.Element.FIR,
				"value": 22.0, "overrides": {}}
			and ctx.attach_requests[0] == ctx.attach_request,
		"reqs=%s slot=%s" % [str(ctx.attach_requests), str(ctx.attach_request)])


# ── C 组：③ host_elements 集合守卫 ────────────────────────────────
func _case4_guard_blocks() -> void:
	print("── ③ 池外元素卡零产出（host_elements=[FIR] 拒 SHOCK） ──")
	var stack := _dual_stack("ELE_IGNITE", "ELE_SHOCK")    # FIR + LTG
	var ctx := TraitContext.new()
	ctx.event = GameConst.TraitEvent.ON_HIT
	var pool: Array[int] = [GameConst.Element.FIR]
	ctx.host_elements = pool
	stack.dispatch(GameConst.TraitEvent.ON_HIT, ctx)
	var reqs: Array[Dictionary] = ctx.attach_requests
	_check("③SHOCK（LTG ∉ [FIR]）零产出：attach_requests 仅 IGNITE 条目",
		reqs.size() == 1 and int(reqs[0].get("element", -1)) == int(GameConst.Element.FIR),
		"reqs=%s" % str(reqs))
	_check("③池内 IGNITE 照常：单槽 = FIR 条目（末位即唯一产出）",
		ctx.attach_request == {"element": GameConst.Element.FIR,
			"value": 22.0, "overrides": {}},
		"slot=%s" % str(ctx.attach_request))


func _case5_guard_empty_legacy() -> void:
	print("── ③ 空池 = 无限制旧语义（KIN 直挂通道全放行） ──")
	var stack := _dual_stack("ELE_IGNITE", "ELE_SHOCK")
	var p_ltg := _spawn_proj({"position": Vector2(150, 150), "velocity": Vector2.ZERO,
		"lifetime": 10.0, "pierce": 1, "hitbox_radius": 6.0,
		"element": GameConst.Element.LTG, "attach_value": 0.0, "team": 0})
	var ctx := TraitContext.new()
	ctx.event = GameConst.TraitEvent.ON_HIT
	ctx.projectile = p_ltg                                 # host_elements 缺省空
	stack.dispatch(GameConst.TraitEvent.ON_HIT, ctx)
	_check("③空 host_elements：双卡全放行（当发随机元素不再收窄——LTG 宿主照发 FIR+LTG）",
		ctx.attach_requests.size() == 2
			and int(ctx.attach_requests[0].get("element", -1)) == int(GameConst.Element.FIR)
			and int(ctx.attach_requests[1].get("element", -1)) == int(GameConst.Element.LTG),
		"reqs=%s" % str(ctx.attach_requests))
	_kill_live_projs()


# ── D 组：④ 混色三断言（weapon_base.blend_element_color） ────────
func _case6_blend_dual() -> void:
	print("── ④ 双元素：HSV 色相插值（饱和保真 + 明度=成员均值） ──")
	var w := _mk_weapon(_mk_melee_wd({"nullify": true}), Vector2.ZERO)
	w.attach_trait(_ele("ELE_IGNITE"))
	w.attach_trait(_ele("ELE_FREEZE"))
	var fir: Color = PopPalette.ELEMENT_COLORS[GameConst.Element.FIR]
	var ice: Color = PopPalette.ELEMENT_COLORS[GameConst.Element.ICE]
	var got: Color = w.blend_element_color()
	# R243 迁移/发现修复：blend 改 HSV 色相插值（替代 RGB 均值——3+ 元素洗灰回归）。
	# FIR/ICE 色相近对跖（圆周矢量长 <0.35）→ 回落最高饱和成员（FIR）色相；断言改
	# 属性化：饱和保真（≥成员最大 sat）+ 明度 = 成员均值（tol 1e-3）
	_check("④双元素 blend：饱和保真 ≥ max(FIR,ICE).s + 明度==成员均值（HSV 插值口径）",
		got.s >= maxf(fir.s, ice.s) - 0.001
		and absf(got.v - (fir.v + ice.v) * 0.5) < 0.001,
		"got=%s fir_s=%s ice_s=%s" % [str(got), str(fir.s), str(ice.s)])


func _case7_blend_single() -> void:
	print("── ④ 单元素：blend = 该色 且 与 dominant_element 同值 ──")
	var w := _mk_weapon(_mk_melee_wd({"nullify": true}), Vector2.ZERO)
	w.attach_trait(_ele("ELE_IGNITE"))
	var fir: Color = PopPalette.ELEMENT_COLORS[GameConst.Element.FIR]
	var got: Color = w.blend_element_color()
	_check("④单元素（火卡）：blend == ELEMENT_COLORS[FIR]", _col_eq(got, fir, 0.001),
		"got=%s fir=%s" % [str(got), str(fir)])
	_check("④单元素：blend 与 dominant_element 色同值（零位移）",
		_col_eq(got, PopPalette.ELEMENT_COLORS[w.dominant_element()], 0.001),
		"dominant=%d" % w.dominant_element())


func _case8_blend_empty() -> void:
	print("── ④ 空池 = 中性白 ──")
	var w := _mk_weapon(_mk_melee_wd({"nullify": true}), Vector2.ZERO)   # 无 ELE 卡
	_check("④空池 blend == Color.WHITE", _col_eq(w.blend_element_color(), Color.WHITE, 0.0001),
		"got=%s" % str(w.blend_element_color()))


# ── E 组：① 端到端一击双附着（真弹体 + 真元素系统 + 真 gauge） ────
func _case9_e2e_dual_attach() -> void:
	print("── ① 双 ELE 卡（火+冰）一击双附着：gauges[FIR]>0 且 gauges[ICE]>0 ──")
	var enemy := _spawn_enemy(Vector2(365, 640))
	_elem_sys.register_host(enemy)
	var stack := _dual_stack("ELE_IGNITE", "ELE_FREEZE")
	var pool: Array[int] = [GameConst.Element.FIR, GameConst.Element.ICE]
	var p := _spawn_proj({
		"position": Vector2(360, 640), "velocity": Vector2(100, 0),
		"lifetime": 10.0, "pierce": 1, "hitbox_radius": 6.0,
		"element": GameConst.Element.FIR, "attach_value": 0.0,
		"attach_elements": pool,                            # R243 §6.3 spawn 键
		"team": 0, "panel_snapshot": {"base_atk": 100.0},
		"trait_stack": stack.copy_runtime(),
	})
	GameConfig.frame_stamp += 1                            # E-03：spawn 已派发 ON_SPAWN，命中须推帧
	p.tick(DT)
	var st: ElementalState = enemy.get("elemental")
	var fir: float = st.gauges[GameConst.Element.FIR] if st != null else -1.0
	var ice: float = st.gauges[GameConst.Element.ICE] if st != null else -1.0
	_check("①一击双附着：gauges[FIR]>0 且 gauges[ICE]>0", fir > 0.0 and ice > 0.0,
		"fir=%s ice=%s" % [str(fir), str(ice)])
	_check("①恰各一跳（22.0——payload 附着值 0 不叠加、数组消费不双发）",
		_approx(fir, 22.0) and _approx(ice, 22.0), "fir=%s ice=%s" % [str(fir), str(ice)])
	_kill_live_projs()


# ── F 组：② 消费端（数组逐条 + 防双发 + 旧单槽兼容） ──────────────
func _case10_consume_array() -> void:
	print("── ② _apply_elemental 数组消费：逐条附着且单槽分支跳过（防双发） ──")
	var spy := SpyElem.new()
	var enemy := _spawn_enemy(Vector2(150, 640))
	var p := _spawn_proj({"position": Vector2(150, 150), "velocity": Vector2.ZERO,
		"lifetime": 10.0, "pierce": 1, "hitbox_radius": 6.0,
		"panel_snapshot": {"base_atk": 50.0}, "team": 0}, spy)
	var ctx := TraitContext.new()
	var reqs: Array[Dictionary] = [
		{"element": GameConst.Element.FIR, "value": 5.0, "overrides": {}},
		{"element": GameConst.Element.ICE, "value": 7.0, "overrides": {}},
	]
	ctx.attach_requests = reqs
	ctx.attach_request = reqs[-1]                          # 模拟产出侧末位覆写
	p._apply_elemental(enemy, null, ctx)
	var calls: Array = spy.calls
	var ok: bool = calls.size() == 2 \
		and int(calls[0][0]) == int(GameConst.Element.FIR) and _approx(float(calls[0][1]), 5.0) \
		and int(calls[1][0]) == int(GameConst.Element.ICE) and _approx(float(calls[1][1]), 7.0) \
		and _approx(float(calls[0][2]), 50.0) and _approx(float(calls[1][2]), 50.0)
	_check("②数组消费：恰 2 次 apply_attach（FIR=5 / ICE=7，快照=panel 50）", ok,
		"calls=%s" % str(calls))
	_check("②防双发：单槽条目（ICE 同值）未再消费（不是 3 次）", calls.size() == 2,
		"n=%d" % calls.size())
	_kill_live_projs()


func _case11_consume_legacy() -> void:
	print("── ② 旧单槽路径兼容（attach_requests 空 → 单槽分支照旧） ──")
	var spy := SpyElem.new()
	var enemy := _spawn_enemy(Vector2(250, 640))
	var p := _spawn_proj({"position": Vector2(150, 150), "velocity": Vector2.ZERO,
		"lifetime": 10.0, "pierce": 1, "hitbox_radius": 6.0,
		"panel_snapshot": {"base_atk": 50.0}, "team": 0}, spy)
	var ctx := TraitContext.new()
	ctx.attach_request = {"element": GameConst.Element.LTG, "value": 9.0, "overrides": {}}
	p._apply_elemental(enemy, null, ctx)
	var calls: Array = spy.calls
	_check("②旧单槽：恰 1 次 apply_attach（LTG=9）——单槽输出兼容不破",
		calls.size() == 1 and int(calls[0][0]) == int(GameConst.Element.LTG)
			and _approx(float(calls[0][1]), 9.0),
		"calls=%s" % str(calls))
	_kill_live_projs()


# ── G 组：⑤ 激光豁免回归（_laser_second_elem_blocked 维持） ───────
func _case12_laser_gate() -> void:
	print("── ⑤ 激光豁免：持元素激光第二张 ELE 拒上架 + 主束恒 dominant ──")
	var cg := CardGenerator.new()
	var w_laser := _mk_weapon_of(LaserWeapon, _mk_wd(GameConst.WeaponForm.LASER, &"W4_TEST_LASER"))
	w_laser.attach_trait(_ele("ELE_IGNITE"))
	_check("⑤持火激光：第二张 ELE（FREEZE）_laser_second_elem_blocked==true（双 ELE 第二张不上架）",
		cg._laser_second_elem_blocked(_ele("ELE_FREEZE"), w_laser),
		"blocked=%s" % str(cg._laser_second_elem_blocked(_ele("ELE_FREEZE"), w_laser)))
	var w_laser_plain := _mk_weapon_of(LaserWeapon,
		_mk_wd(GameConst.WeaponForm.LASER, &"W4_TEST_LASER2"))
	var w_ball := _mk_weapon_of(BallisticWeapon,
		_mk_wd(GameConst.WeaponForm.BALLISTIC, &"W1_TEST_DART"))
	w_ball.attach_trait(_ele("ELE_IGNITE"))
	_check("⑤无元素激光 / 弹道宿主：门恒 false（非激光逐发随机不受限、激光未持元素可首挂）",
		not cg._laser_second_elem_blocked(_ele("ELE_FREEZE"), w_laser_plain)
		and not cg._laser_second_elem_blocked(_ele("ELE_FREEZE"), w_ball),
		"plain=%s ball=%s" % [
			str(cg._laser_second_elem_blocked(_ele("ELE_FREEZE"), w_laser_plain)),
			str(cg._laser_second_elem_blocked(_ele("ELE_FREEZE"), w_ball))])
	_check("⑤主束真源：laser.dominant_element() == FIR（挂载序首张非 KIN——束色稳定通道不动）",
		w_laser.dominant_element() == GameConst.Element.FIR,
		"dom=%d" % w_laser.dominant_element())
	_check("⑤持火激光：任何 ELE 卡（含同卡 IGNITE）均拒——单元素结构性成立幂等",
		cg._laser_second_elem_blocked(_ele("ELE_IGNITE"), w_laser),
		"same_card=%s" % str(cg._laser_second_elem_blocked(_ele("ELE_IGNITE"), w_laser)))


# ── H 组：⑥ W9 斩击附着（w2-fengren _slash_hit 附着钩子） ─────────
func _case13_w9_slash_attach() -> void:
	print("── ⑥ W9 挂火卡斩中敌：gauges[FIR]==22（真元素系统） ──")
	var w := _mk_weapon(_mk_melee_wd({"nullify": true, "slash_radius": 150.0,
		"arc_deg": 120.0, "max_targets": 8, "knockback": 0.0}, &"TST_W9_ELEM"),
		Vector2(360, 640))
	w.attach_trait(_ele("ELE_IGNITE"))                     # 元素池 = [FIR] → host_elements
	var enemy := _spawn_enemy(Vector2(440, 640))           # 0° 80px 扇内
	_elem_sys.register_host(enemy)
	w.elemental = _elem_sys
	w.cooldown_left = 10.0                                 # 阻断 try_fire（保持窗口朝向）
	w._slash_window(0.0, false)
	w.tick(DT)
	var st: ElementalState = enemy.get("elemental")
	var fir: float = st.gauges[GameConst.Element.FIR] if st != null else -1.0
	_check("⑥W9 斩击附着：gauges[FIR] == 22.0（_slash_hit → apply_attach）", _approx(fir, 22.0),
		"fir=%s" % str(fir))
	var ice: float = st.gauges[GameConst.Element.ICE] if st != null else -1.0
	_check("⑥未挂冰卡：gauges[ICE] 恒 0（池外元素零串写）", _approx(ice, 0.0), "ice=%s" % str(ice))


# ── I 组：⑦ W8 不可挂 ELE（excluded_weapons 门拒） ────────────────
func _case14_w8_gate() -> void:
	print("── ⑦ W8 excluded_weapons 门拒（七卡全拒）；W9/W13/弹道放行 ──")
	var w8 := _mk_weapon(_mk_melee_wd({"nullify": false}, &"W8_orbit_field"), Vector2.ZERO)
	var all_blocked := true
	var detail := ""
	for eid in ELE_IDS:
		if CardGenerator.mount_gate_allows(_ele(eid), w8):
			all_blocked = false
			detail += "%s 放行;" % eid
	_check("⑦W8：七张 ELE 卡 mount_gate_allows 全拒（R186 拆除维持——精确下架不动 required_forms）",
		all_blocked, detail)
	var w9 := _mk_weapon(_mk_melee_wd({"nullify": true}, &"W9_arc_slash"), Vector2.ZERO)
	var w13 := _mk_weapon(_mk_melee_wd({"nullify": false}, &"W13_great_sword"), Vector2.ZERO)
	var w1 := _mk_weapon(_mk_wd(GameConst.WeaponForm.BALLISTIC, &"W1_test_dart"), Vector2.ZERO)
	var w6 := _mk_weapon(_mk_wd(GameConst.WeaponForm.HOMING, &"W6_test_missile"), Vector2.ZERO)
	_check("⑦对照：W9/W13/弹道/自导均可挂（required_forms [0,1,2,3] 覆盖；仅 W8 被排除）",
		CardGenerator.mount_gate_allows(_ele("ELE_IGNITE"), w9)
			and CardGenerator.mount_gate_allows(_ele("ELE_IGNITE"), w13)
			and CardGenerator.mount_gate_allows(_ele("ELE_IGNITE"), w1)
			and CardGenerator.mount_gate_allows(_ele("ELE_IGNITE"), w6),
		"w9=%s w13=%s w1=%s w6=%s" % [
			str(CardGenerator.mount_gate_allows(_ele("ELE_IGNITE"), w9)),
			str(CardGenerator.mount_gate_allows(_ele("ELE_IGNITE"), w13)),
			str(CardGenerator.mount_gate_allows(_ele("ELE_IGNITE"), w1)),
			str(CardGenerator.mount_gate_allows(_ele("ELE_IGNITE"), w6))])


# ── J 组：⑧ homing spawn attach_elements 接线（本任务 ③ 一行） ────
func _case15_homing_attach() -> void:
	print("── ⑧ HomingWeapon spawn：attach_elements == 元素池（守卫输入贯通） ──")
	var w := HomingWeapon.new()
	tree.get_root().add_child(w)
	w.position = Vector2(360, 600)
	w.setup(_mk_wd(GameConst.WeaponForm.HOMING, &"W6_test_missile"), null, {
		"pipeline": _pipeline,
		"projectile_pool": _proj_pool,
		"enemy_grid": _grid,
		"homing_pool": _proj_pool,
	})
	w.attach_trait(_ele("ELE_IGNITE"))                     # 元素池 = [FIR]
	_spawn_enemy(Vector2(360, 700))                        # 100px 正下（第 1 近目标）
	var before: int = _proj_pool.active_projectiles().size()
	var fired: bool = w.try_fire()
	var active := _proj_pool.active_projectiles()
	var spawned: ProjectileBase = null
	if fired and active.size() == before + 1:
		for node in active:                                # 按 weapon_uid 定位新弹（池序不保证）
			if (node as ProjectileBase).weapon_uid == w.uid:
				spawned = node as ProjectileBase
				break
	var expect_pool: Array[int] = [GameConst.Element.FIR]
	_check("⑧spawn 键读回：proj.attach_elements == [FIR]（homing 一行接线生效）",
		spawned != null and spawned.attach_elements == expect_pool,
		"fired=%s n=%d attach=%s" % [str(fired), active.size(),
			str(spawned.attach_elements) if spawned != null else "null"])
	var host_ok: bool = spawned != null \
		and (spawned as ProjectileBase)._build_trait_ctx(GameConst.TraitEvent.ON_HIT) \
			.host_elements == expect_pool
	_check("⑧守卫输入贯通：_build_trait_ctx.host_elements == [FIR]", host_ok,
		"host=%s" % str(spawned._build_trait_ctx(GameConst.TraitEvent.ON_HIT).host_elements
			if spawned != null else []))
	_kill_live_projs()


# ── spy 元素系统（apply_attach 记录桩——不落状态） ─────────────────
class SpyElem extends ElementalSystem:
	var calls: Array = []                        # [element, value, snapshot] 记录

	func apply_attach(p_enemy: Node2D, p_element: int, p_value: float,
			p_info: Dictionary = {}) -> void:
		calls.append([p_element, p_value, float(p_info.get("snapshot", 0.0))])

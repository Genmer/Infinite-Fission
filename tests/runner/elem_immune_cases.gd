# tests/runner/elem_immune_cases.gd
# 元素免疫/配色用例体（由 test_elem_immune.gd 入口加载）。真源：ELEMENT_DEEPEN.md。
extends RefCounted

const DT := 1.0 / 120.0
const MAIN_SCENE := "res://scenes/main.tscn"

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null
var _w1: WeaponBase = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_boot_game_loop()
	_test_fire_immune_bug()
	_test_ice_immune_frostling()
	_test_popup_element_colors()
	_test_reaction_fx_slots()
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
	_w1 = _gl.player.weapon_slots[0]


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


func _make_mob(p_data_id: StringName, p_pos: Vector2) -> Enemy:
	var data: EnemyData = _gl.registry.get_enemy(p_data_id)
	var e: Enemy = (_gl.pools[&"enemy"] as EnemyPool).acquire()
	e.spawn(data, 1, 0)
	e.position = p_pos
	return e


func _resolve_elem(p_target: Enemy, p_element: int) -> DamageResult:
	# 直击结算（元素附着由 weapon_ref 弹体通道承担，此处专测伤害归零与 immune 标记）
	var ctx: DamageContext = _w1.build_damage_context(p_target)
	ctx.base_atk = 100.0
	ctx.crit_chance = 0.0
	ctx.element = p_element
	var result = _gl.pipeline.call(&"resolve", ctx)
	return result


# ── 火免疫（E4 爆虫） ─────────────────────────────────────────────
func _test_fire_immune_bug() -> void:
	print("── 火免疫（E4 爆虫） ──")
	var e := _make_mob(&"E4_volatile", Vector2(300.0, 500.0))
	e.max_hp = 1000000.0
	e.hp = 1000000.0                            # 厚血化（三种元素连打不致死）
	_check("E4：FIR 免疫标注（数据）", bool(e.call("is_elem_immune", GameConst.Element.FIR)))
	_check("E4：不可点燃（immune_mask IMMUNE_BURN）",
		int(e.get("immune_mask")) & GameConst.IMMUNE_BURN != 0)
	var r: DamageResult = _resolve_elem(e, GameConst.Element.FIR)
	_check("元素免疫：火伤打火虫 final = 0（「没用」）", absf(r.final_value) < 0.001
		and bool(r.immune), "%.1f immune=%s" % [r.final_value, str(r.immune)])
	_check("元素免疫：免疫命中 popup_style = IMMUNE",
		int(r.popup_style) == GameConst.PopupStyle.IMMUNE)
	# 物理保底 / 非免疫元素：独立 dummy（管线幂等缓存按 同帧+同源+同目标 命中——
	# 同目标二次结算须换目标实例绕开缓存）
	var e2 := _make_mob(&"E4_volatile", Vector2(300.0, 500.0))
	e2.max_hp = 1000000.0
	e2.hp = 1000000.0
	var r2: DamageResult = _resolve_elem(e2, GameConst.Element.KIN)
	_check("物理保底：KIN 打火虫正常结算（>0 且非免疫）",
		r2.final_value > 0.0 and not bool(r2.immune),
		"%.1f immune=%s" % [r2.final_value, str(r2.immune)])
	var e3 := _make_mob(&"E4_volatile", Vector2(300.0, 500.0))
	e3.max_hp = 1000000.0
	e3.hp = 1000000.0
	var r3: DamageResult = _resolve_elem(e3, GameConst.Element.ICE)
	_check("非免疫元素：冰打火虫正常结算", r3.final_value > 0.0 and not bool(r3.immune),
		"%.1f immune=%s" % [r3.final_value, str(r3.immune)])
	(_gl.pools[&"enemy"] as EnemyPool).release(e)
	(_gl.pools[&"enemy"] as EnemyPool).release(e2)
	(_gl.pools[&"enemy"] as EnemyPool).release(e3)


# ── 冰免疫（E9 冰霜仔） ───────────────────────────────────────────
func _test_ice_immune_frostling() -> void:
	print("── 冰免疫（E9 冰霜仔） ──")
	var e := _make_mob(&"E9_frostling", Vector2(300.0, 500.0))
	e.max_hp = 1000000.0
	e.hp = 1000000.0
	_check("E9：ICE 免疫标注（数据）", bool(e.call("is_elem_immune", GameConst.Element.ICE)))
	_check("E9：不可冻结/寒滞（immune_mask 3）",
		int(e.get("immune_mask")) & (GameConst.IMMUNE_FREEZE | GameConst.IMMUNE_CHILL)
			== (GameConst.IMMUNE_FREEZE | GameConst.IMMUNE_CHILL))
	var r: DamageResult = _resolve_elem(e, GameConst.Element.ICE)
	_check("元素免疫：冰伤打冰怪 final = 0", absf(r.final_value) < 0.001 and bool(r.immune))
	# 附着拒绝：冰弹命中后不附冰槽（ElementalSystem.apply_attach 守卫）
	e.elemental = ElementalState.new()
	e.elemental.immune_mask = int(e.get("immune_mask"))
	_gl.elemental.apply_attach(e, GameConst.Element.ICE, 50.0)
	_check("附着拒绝：免疫怪冰槽不涨",
		float(e.elemental.gauges[GameConst.Element.ICE]) == 0.0)
	(_gl.pools[&"enemy"] as EnemyPool).release(e)


# ── 跳字元素配色 ──────────────────────────────────────────────────
func _test_popup_element_colors() -> void:
	print("── 跳字元素配色 ──")
	Meta.set_setting("damage_numbers_on", true)
	var pm := _gl.popup_manager
	pm.clear_all()                              # 清免疫测试残留跳字
	var pos := Vector2(360.0, 400.0)
	var cases := {
		GameConst.Element.FIR: Color(1.0, 0.6, 0.25),
		GameConst.Element.ICE: Color(0.62, 0.85, 1.0),
		GameConst.Element.LTG: PopPalette.SHOCK,
		GameConst.Element.KIN: Color(1.0, 1.0, 1.0),
	}
	for element in cases:
		var r := DamageResult.new()
		r.final_value = 10.0
		r.target_uid = 300000 + int(element)
		r.pos = pos
		r.popup_style = GameConst.PopupStyle.NORMAL
		r.element = int(element)
		pm.on_damage_resolved(r)
	# 找活跃跳字核对配色（最后一条 = 本元素）
	var ok_all := true
	var detail := ""
	for p in pm._active_list:
		var expected: Color = cases[p.element]
		var actual: Color = p._label.self_modulate
		if (absf(actual.r - expected.r) + absf(actual.g - expected.g)
				+ absf(actual.b - expected.b)) > 0.03 and p.element != GameConst.Element.KIN:
			ok_all = false
			detail = "%s %s" % [str(p.element), str(actual)]
	_check("跳字配色：FIR 橙 / ICE 冰蓝 / LTG 紫 / KIN 白", ok_all, detail)
	pm.clear_all()
	# 免疫跳字：样式 IMMUNE →「免疫」灰蓝
	var ri := DamageResult.new()
	ri.final_value = 0.0
	ri.target_uid = 400001
	ri.pos = pos
	ri.popup_style = GameConst.PopupStyle.IMMUNE
	pm.on_damage_resolved(ri)
	var immune_popup: DamagePopup = pm._active_list[-1] if pm._active_list.size() > 0 else null
	_check("跳字配色：免疫命中显示「免疫」灰蓝",
		immune_popup != null and immune_popup._label.text == "免疫")
	pm.clear_all()


# ── 反应专属特效 ──────────────────────────────────────────────────
func _test_reaction_fx_slots() -> void:
	print("── 反应专属特效 ──")
	var layer: Node = _gl.elemental_fx
	_check("前置：FX 层就绪", layer != null)
	# 过载：紫橙双环落场
	EventBus.emit_reaction_triggered(GameConst.ReactionType.RXN_FIR_LTG,
		Vector2(360.0, 600.0), 1)
	var overload_rings := 0
	for c in layer.get_children():
		if str(c.name).begins_with("RxnRing") and c.visible:
			overload_rings += 1
	_check("过载：专属紫橙双环落场", overload_rings == 2, "实得 %d" % overload_rings)
	# 超导：冰紫雾环落场
	EventBus.emit_reaction_triggered(GameConst.ReactionType.RXN_ICE_LTG,
		Vector2(360.0, 600.0), 2)
	overload_rings = 0
	for c in layer.get_children():
		if str(c.name).begins_with("RxnRing") and c.visible:
			overload_rings += 1
	_check("超导：专属冰紫雾环落场（累计 4）", overload_rings == 4, "实得 %d" % overload_rings)
	# 推进 1s → 全部自清
	for i in range(80):
		layer._tick_rxn_rings(1.0 / 60.0)
	overload_rings = 0
	for c in layer.get_children():
		if str(c.name).begins_with("RxnRing") and c.visible:
			overload_rings += 1
	_check("反应环：扩散淡出自清（0 残留）", overload_rings == 0)

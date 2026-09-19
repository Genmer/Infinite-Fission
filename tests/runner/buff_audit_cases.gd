# tests/runner/buff_audit_cases.gd
# 全池 buff 行为审计用例体（由 test_buff_audit.gd 入口加载）。
# 此前 pkg3 已覆盖：FROST_EXEC/BURN_DEVOUR/FIRST_STRIKE/BOUNCE_SPEC 条件、MEC_BOUNCE/
# SIZE_STACK/SHIELD/ORBIT_LINK、ELE 四卡附着。本套件补齐零覆盖四卡 + ADD 数值表锁定。
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
	_test_lowhp_fury()
	_test_pierce_evo_ramp()
	_test_kill_blast()
	_test_fractal_split()
	_test_add_value_table()
	_test_element_enchant()
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


func _attach(p_card_id: StringName, p_weapon: WeaponBase = null) -> bool:
	var t: TraitData = _gl.registry.get_trait(p_card_id)
	if t == null:
		return false
	var w: WeaponBase = p_weapon if p_weapon != null else _w1
	return bool(w.attach_trait(t))


func _make_dummy(p_pos: Vector2) -> Enemy:
	var e: Enemy = (_gl.pools[&"enemy"] as EnemyPool).acquire()
	var data := EnemyData.new()
	data.id = &"E_AUDIT_DUMMY"
	data.hp_base = 100000.0
	data.spd_base = 0.0
	data.hitbox_r = 14.0
	e.spawn(data, 1, 0)
	e.position = p_pos
	return e


func _resolve_base(p_target: Enemy, p_player_hp_pct: float = 1.0, p_pierce_index: int = 0) -> float:
	# 真管线结算：base 100 / 零暴击 / 零抗 dummy → final_value 即乘区观测值。
	# 先设 ctx 字段再 collect（乘区条件在 collect 时按 ctx 评估——真实弹体流程镜像）
	var ctx := _w1.build_damage_context(p_target)
	ctx.base_atk = 100.0
	ctx.crit_chance = 0.0
	ctx.player_hp_pct = p_player_hp_pct
	ctx.pierce_index = p_pierce_index
	ctx.mult_pools.clear()
	var tctx := TraitContext.new()
	tctx.event = GameConst.TraitEvent.ON_HIT
	tctx.weapon = _w1
	tctx.damage_ctx = ctx
	if _w1.trait_stack != null:
		for pool in _w1.trait_stack.collect_mult_pools(tctx):
			ctx.mult_pools.append(pool)
	var result = _gl.pipeline.call(&"resolve", ctx)
	return float(result.final_value)


# ── SYN_LOWHP_FURY 背水协议（PLAYER_HP_BELOW 35% → ×1.6） ──────────
func _test_lowhp_fury() -> void:
	print("── 背水协议（fury_dmg） ──")
	_check("前置：SYN_LOWHP_FURY 入注册表", _gl.registry.get_trait(&"SYN_LOWHP_FURY") != null)
	var base := _resolve_base(_make_dummy(Vector2(300.0, 500.0)), 1.0)
	var fury := _resolve_base(_make_dummy(Vector2(300.0, 500.0)), 0.2)
	_check("背水：满血无乘区（≈100）", absf(base - 100.0) < 0.5, "%.1f" % base)
	_check("背水：HP<35% → ×1.6（未挂卡也基线 100——卡未挂时无差异）",
		absf(fury - base) < 0.5, "%.1f vs %.1f" % [fury, base])
	# 挂卡后：低血 ×1.6，满血仍 ≈100
	var ok := _attach(&"SYN_LOWHP_FURY")
	_check("背水：真卡挂载", ok)
	var low := _resolve_base(_make_dummy(Vector2(300.0, 500.0)), 0.2)
	var full := _resolve_base(_make_dummy(Vector2(300.0, 500.0)), 1.0)
	_check("背水：挂卡后 HP<35% → ≈160", absf(low - 160.0) < 0.8, "%.1f" % low)
	_check("背水：挂卡后满血无乘区（≈100）", absf(full - 100.0) < 0.5, "%.1f" % full)


# ── SYN_PIERCE_EVO 贯穿协鸣（每穿透 1 层 +0.2 累进） ───────────────
func _test_pierce_evo_ramp() -> void:
	print("── 贯穿协鸣（pierce_dmg ramp） ──")
	_check("前置：SYN_PIERCE_EVO 入注册表", _gl.registry.get_trait(&"SYN_PIERCE_EVO") != null)
	var ok := _attach(&"SYN_PIERCE_EVO")
	_check("贯穿协鸣：真卡挂载", ok)
	var p1 := _resolve_base(_make_dummy(Vector2(300.0, 500.0)), 1.0, 1)
	var p3 := _resolve_base(_make_dummy(Vector2(300.0, 500.0)), 1.0, 3)
	_check("贯穿协鸣：首穿无加成（≈100）", absf(p1 - 100.0) < 0.5, "%.1f" % p1)
	_check("贯穿协鸣：穿 3 → ×1.4（+0.2×2）", absf(p3 - 140.0) < 0.8, "%.1f" % p3)


# ── MEC_KILL_BLAST 死亡新星 ───────────────────────────────────────
func _test_kill_blast() -> void:
	print("── 死亡新星（kill_blast） ──")
	var ok := _attach(&"MEC_KILL_BLAST")
	_check("死亡新星：真卡挂载", ok)
	# 弱化杂兵摆在弹道上，致命面板弹命中击杀 → ON_EXPIRE 新星广播
	var grunt: Enemy = (_gl.pools[&"enemy"] as EnemyPool).acquire()
	var data := EnemyData.new()
	data.id = &"E_KB_TARGET"
	data.hp_base = 1.0
	data.spd_base = 0.0
	data.hitbox_r = 14.0
	grunt.spawn(data, 1, 0)
	grunt.position = _w1.global_position + Vector2(220.0, 0.0)
	_gl.spawner.active.append(grunt)
	var b: ProjectileBase = (_gl.pools[&"projectile"] as ProjectilePool).acquire()
	b.pool = _gl.pools[&"projectile"]
	b.position = _w1.global_position
	var snap: Dictionary = _w1.build_panel_snapshot()
	snap["base_atk"] = 999.0                     # 致命面板（击杀记录用）
	b.spawn({
		"velocity": Vector2(500.0, 0.0), "lifetime": 1.0, "pierce": 1, "bounces": 0,
		"hitbox_radius": 6.0, "element": GameConst.Element.KIN, "attach_value": 0.0,
		"generation": 0, "weapon_uid": _w1.get("uid"), "weapon_ref": _w1,
		"panel_snapshot": snap, "team": 0,
		"trait_stack": _w1.trait_stack.copy_runtime(),
	})
	b.damage_pipeline = _gl.pipeline
	b.enemy_grid = _gl.enemy_grid
	b.elemental = _gl.elemental
	var saw_blast := [false]
	var handler := func(_pos: Vector2, _r: float) -> void:
		saw_blast[0] = true
	EventBus.kill_blast.connect(handler)
	# 驱动 GameLoop 帧（网格按帧重建 + 弹体 tick + 过期 ON_EXPIRE）；1s 寿命 4s 内必炸
	for i in range(480):
		if _gl.state == GameConst.GameStatus.LEVEL_UP:
			_gl.change_state(GameConst.GameStatus.PLAYING)
		_gl._physics_process(DT)
	EventBus.kill_blast.disconnect(handler)
	_check("死亡新星：击杀弹过期触发新星广播（ON_EXPIRE→settle_aoe）", bool(saw_blast[0]))


# ── MEC_FRACTAL 几何分裂 ──────────────────────────────────────────
func _test_fractal_split() -> void:
	print("── 几何分裂（fractal） ──")
	var ok := _attach(&"MEC_FRACTAL")
	_check("几何分裂：真卡挂载", ok)
	var b: ProjectileBase = (_gl.pools[&"projectile"] as ProjectilePool).acquire()
	b.pool = _gl.pools[&"projectile"]
	b.position = _w1.global_position
	b.spawn({
		"velocity": Vector2(400.0, 0.0), "lifetime": 5.0, "pierce": 1, "bounces": 0,
		"hitbox_radius": 6.0, "element": GameConst.Element.KIN, "attach_value": 0.0,
		"generation": 0, "weapon_uid": _w1.get("uid"), "weapon_ref": _w1,
		"panel_snapshot": _w1.build_panel_snapshot(), "team": 0,
		"trait_stack": _w1.trait_stack.copy_runtime(),
	})
	b.damage_pipeline = _gl.pipeline
	b.enemy_grid = _gl.enemy_grid
	b.elemental = _gl.elemental
	b.tick(DT)
	var live0: int = int((_gl.pools[&"projectile"] as ProjectilePool).stats()["live"])
	b.nullify()                                   # NULLIFIED → _recycle → ON_EXPIRE → 分裂
	var children := 0
	for p in (_gl.pools[&"projectile"] as ProjectilePool).active_projectiles():
		if p is ProjectileBase and int(p.get("generation")) == 1:
			children += 1
	_check("几何分裂：母弹消亡分裂子代（≥2 枚 generation=1）", children >= 2,
		"实得 %d" % children)
	_check("几何分裂：母弹回收（live 净增 = 子代数）",
		int((_gl.pools[&"projectile"] as ProjectilePool).stats()["live"]) == live0 - 1 + children)
	for p in (_gl.pools[&"projectile"] as ProjectilePool).active_projectiles():
		p.nullify()


# ── R26 元素附魔（弹丸 element 跟随武器 ELE 卡，多元素随机） ──
func _test_element_enchant() -> void:
	print("── 元素附魔 ──")
	# 无 ELE 卡：KIN（白）
	_check("前置：无附魔 → KIN", _w1.call("_shot_element") == GameConst.Element.KIN)
	# 挂点燃 → FIR
	var ok1 := _attach(&"ELE_IGNITE")
	_check("附魔：挂点燃卡成功", ok1)
	_check("附魔：点燃 → 出膛元素 FIR（跳字橙）",
		ok1 and _w1.call("_shot_element") == GameConst.Element.FIR)
	# 再挂冰 → 双元素随机（多次采样应出现 FIR 与 ICE 两种）
	var ok2 := _attach(&"ELE_FREEZE")
	_check("附魔：挂冰卡成功", ok2)
	var seen := {}
	for i in range(60):
		seen[_w1.call("_shot_element")] = true
	_check("附魔：双元素随机（FIR/ICE 均出现——「一会红一会蓝」）",
		seen.has(GameConst.Element.FIR) and seen.has(GameConst.Element.ICE),
		str(seen.keys()))
	# 出膛验证：实弹 element = 附魔元素（多发采样应 FIR/ICE 混发）
	var got_fir := false
	var got_ice := false
	for i in range(12):
		_w1.call("try_fire")
		for p in (_gl.pools[&"projectile"] as ProjectilePool).active_projectiles():
			if p is ProjectileBase and (p as ProjectileBase).team == 0 					and p.get("weapon_ref") == _w1:
				if int(p.get("element")) == GameConst.Element.FIR:
					got_fir = true
				elif int(p.get("element")) == GameConst.Element.ICE:
					got_ice = true
				p.call("nullify")
	_check("附魔：实弹 element ∈ 附魔集合（FIR/ICE，随机分布由 _shot_element 60 采样锁定）",
		got_fir or got_ice, "fir=%s ice=%s" % [str(got_fir), str(got_ice)])


# ── ADD 数值表锁定（防口径漂移） ──────────────────────────────────
func _test_add_value_table() -> void:
	print("── ADD 数值表 ──")
	var expected := {
		&"AFF_ATK_UP": 0.15, &"AFF_ROF_UP": 0.12, &"AFF_CDR": 0.1,
		&"AFF_CRIT_RATE": 0.08, &"AFF_CRIT_DMG": 0.3, &"AFF_PROJ_SPD": 0.18,
		&"AFF_HP_UP": 25.0, &"AFF_SKILL_HASTE": 0.12, &"AFF_PICKUP": 0.3,
		&"AFF_AREA": 0.15, &"AFF_PIERCE": 1.45, &"AFF_MULTI": 1.45,
		&"AFF_XP_GAIN": 0.15, &"AFF_GOLD": 0.2,
	}
	var bad: Array[String] = []
	for id in expected:
		var t: TraitData = _gl.registry.get_trait(id)
		if t == null or absf(float(t.value) - float(expected[id])) > 0.0001:
			bad.append(String(id))
	_check("数值表：14 张 ADD 卡 value 与定版一致（防漂移）", bad.is_empty(), str(bad))
	_check("数值表：MEC_KNOCK 击退 +60（R18 归位 ADD）",
		_gl.registry.get_trait(&"MEC_KNOCK") != null
		and absf(float(_gl.registry.get_trait(&"MEC_KNOCK").value) - 60.0) < 0.001)
	# 卡面完整性：36 张卡描述全非空
	var empty_desc := 0
	for id in _gl.registry.traits.keys():
		var t: TraitData = _gl.registry.traits[id]
		if t != null and String(t.description).strip_edges() == "":
			empty_desc += 1
	_check("卡面完整性：全部词条描述非空（0 空描述）", empty_desc == 0)

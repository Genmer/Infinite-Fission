# tests/runner/r243_block_cases.gd
# R243 挡弹成长卡（w3-block）用例体（由 test_r243_block.gd 入口运行时 load——cases 禁
# test_ 前缀防电池 glob 误收）。覆盖（任务验收 ①新卡 §3.3 / ②套件集成 §9.1 ①~⑧ /
# ③表现口径）：
#   A 组 新卡规格：pool 0(ADD)/add_block/0.08/stack 3/rarity 1/decay 0.85 + params
#        required_forms[3]+required_class[melee] + 描述逐字 + required_class 挂载门
#        （W8/W13 true、W9 talisman 拒、form0 拒、无目标拒）+ 1 层 0.38 / 3 层 0.54
#        （0.30+0.24——R14 逐层全额聚合）+ validate_trait 绿 + ADD_POOL_IDS 第 17 员。
#   B 组 统一掷骰口基线：W8=0.30 / W9=1.0（nullify 优先）/ W11=W12=1.0 / form0=0.0。
#   C 组 W8 刀位挡弹：网格注入；chance=1.0 帽 4/tick + 余弹次 tick 续消；域外弹不受；
#        chance=0.0 零消弹（两极断言——不测中间采样 §3.4）；预置 30 弹单 tick 恰 4
#        （帽护栏）；涟漪逐弹 + bullet_parry 计数。
#   D 组 法器确定性消弹（5 项）：灵剑飞行路径 1.0 全消帽 6/tick（两 tick 累计 8 + 圈外
#        控制弹）；斧落地震荡帽 24/次（预置 30 弹恰消 24 + 余 6 保留 + 落地涟漪逐弹）；
#        斧飞行路径消弹帽 6/tick（R243 迁移/发现修复——设计 §3.2 W12「飞行接触同灵剑」）。
#   E 组 W13 警戒弧双域（7 项）：_guard_facing 缓存 + 窗激活判据；斩击窗全弧同受掷骰（±60°
#        guard 域外弹 1.0 桩全消、窗内正后弹不受）；待机正面 90° 扇形全消 + 侧后不受 +
#        涟漪；帽 4/检查；节拍 0.1s；chance=0.0 待机零消弹；挥斩窗挂弹反卡 live 成长
#       （R243 迁移/发现修复——spawn 快照 0.30 短路改 -1 哨兵 live 口）。
#   F 组 集成与全量校验：registry rejected==0（新卡入库零剔除）；涟漪口径汇总（近战
#        概率域与法器确定性域共用 emit_bullet_nullified）；成长达 W13 警戒弧 live 消费口。
#   ⑦ 套件总项数断言（R231 假绿教训）。
# 确定性：固定坐标/静止敌/crit=0 副本数据/帧戳手动推进；掷骰只取 1.0/0.0 两极（§3.4）。
extends RefCounted

const EXPECTED_TOTAL := 32
const DT := 1.0 / 120.0
const MAIN_SCENE := "res://scenes/main.tscn"
const CARD_ID := &"MEC_BULLET_PARRY"
const CARD_DESC := "近战武器格挡子弹概率 +8%（基础 30%），可叠 3 层"

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null
var _stubs: Array = []                       # 收尾 free（Node 桩）
var _bullets: Array[Node2D] = []             # 桩敌弹（rebuild 敌弹网格用）
var _ripple_melee: int = 0                   # 近战概率域涟漪记录（C 组）
var _ripple_talisman: int = 0                # 法器确定性域涟漪记录（D 组斧落地）
var _ripple_cb: Callable = Callable()        # 当前涟漪间谍（可空——精确拆卸）


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(20261008)
	_boot_game_loop()
	_group_a_card()
	_group_b_chance_base()
	_group_c_w8_block()
	_group_d_talisman()
	_group_e_w13_guard()
	_group_f_integration()
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
	for s in _stubs:
		if s != null and s is Node and is_instance_valid(s):
			(s as Node).free()
	_stubs.clear()
	tree.paused = false
	RunSave.clear()
	if _gl != null:
		_gl.free()
		_gl = null


func _slot_solo(p_id: StringName) -> WeaponBase:
	# 拆全部旧武器（OrbitField/ArcSlash 均为武器子节点——随 free 释放）→ 清场 → 单装
	# 目标武器（组建互不串场；crit=0 副本数据 + meta 修正归零——伤害探针确定性）。
	if _gl == null:
		return null
	_clear_bullets()
	for i in range(_gl.player.weapon_slots.size()):
		var w = _gl.player.weapon_slots[i]
		if w != null and is_instance_valid(w):
			_gl.player.weapon_slots[i] = null
			w.free()
	_clear_enemies()
	_gl.player.set("unlocked_slots", 5)
	var w: WeaponBase = _gl.player.add_weapon(_gl.registry.get_weapon(p_id))
	if w != null and w.data != null:
		w.data = w.data.duplicate(true)
		w.data.crit_rate = 0.0
		w.meta_atk_pct = 0.0
		w.call(&"_invalidate_panel")
	return w


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
	# 桩敌弹（team=1 静止珠——最小参数域；手动 rebuild 进敌弹网格，_tick 不驱动）
	var pool := _gl.pools[&"projectile"] as ProjectilePool
	var b := pool.acquire() as ProjectileBase
	if b == null:
		return null
	b.pool = pool
	b.enemy_grid = _gl.enemy_grid
	b.spawn({
		"position": p_pos, "velocity": Vector2.ZERO, "lifetime": 30.0,
		"pierce": 1, "hitbox_radius": 6.0, "team": 1,
		"panel_snapshot": {"base_atk": 0.0},
	})
	_bullets.append(b)
	return b


func _rebuild_bullet_grid() -> void:
	var arr: Array[Node2D] = []
	for b in _bullets:
		if b != null and is_instance_valid(b):
			arr.append(b)
	_gl.enemy_bullet_grid.rebuild(arr)


func _clear_bullets() -> void:
	if _gl == null:
		return
	for b in _bullets.duplicate():
		if b != null and is_instance_valid(b) and not (b as ProjectileBase).is_clean:
			(_gl.pools[&"projectile"] as ProjectilePool).release(b)
	_bullets.clear()
	_rebuild_bullet_grid()


func _alive_count(p_list: Array) -> int:
	var n := 0
	for b in p_list:
		if b != null and is_instance_valid(b) and not (b as ProjectileBase).is_clean:
			n += 1
	return n


func _release_list(p_list: Array) -> void:
	for b in p_list:
		if b != null and is_instance_valid(b) and not (b as ProjectileBase).is_clean:
			(_gl.pools[&"projectile"] as ProjectilePool).release(b)


func _bump() -> void:
	GameConfig.frame_stamp += 1                    # E-03 帧闸门推进


func _step(p_w: WeaponBase, p_ticks: int) -> void:
	for i in range(p_ticks):
		_bump()
		p_w.tick(DT)


func _attach_card(p_w: WeaponBase) -> bool:
	return p_w.attach_trait(_gl.registry.get_trait(CARD_ID))


func _count_ripples(p_sink: Array) -> void:
	_ripple_cb = func(p_pos: Vector2) -> void: p_sink.append(p_pos)
	EventBus.bullet_nullified.connect(_ripple_cb)


func _disconnect_ripples() -> void:
	if _ripple_cb.is_valid():
		EventBus.bullet_nullified.disconnect(_ripple_cb)
	_ripple_cb = Callable()


# ── A 组：新卡规格（§3.3，6 项） ─────────────────────────────────
func _group_a_card() -> void:
	print("── A 组：MEC_BULLET_PARRY 新卡规格（§3.3） ──")
	var t: TraitData = _gl.registry.get_trait(CARD_ID)
	_check("A1 新卡入库（pool=0 ADD / pool_id=add_block / value=0.08 / stack_max=3 / "
		+ "rarity=1 / decay_delta=0.85）",
		t != null and int(t.pool) == GameConst.PoolClass.ADD
		and StringName(t.pool_id) == &"add_block"
		and absf(float(t.value) - 0.08) < 0.000001 and int(t.stack_max) == 3
		and int(t.rarity) == 1 and absf(float(t.decay_delta) - 0.85) < 0.000001,
		"t=%s pool=%s pid=%s v=%s" % [str(t), str(t.pool if t != null else -1),
			str(t.pool_id if t != null else &""), str(t.value if t != null else -1.0)])
	_check("A2 params（required_forms [3] + required_class [\"melee\"]）+ 描述逐字",
		t != null and t.params.get("required_forms", []) == [3]
		and t.params.get("required_class", []) == ["melee"]
		and String(t.description) == CARD_DESC,
		"params=%s desc=%s" % [str(t.params if t != null else {}),
			str(t.description if t != null else "")])
	# required_class 挂载门：法器目标拒卡（已 100% 无意义）、form 0 拒、无目标拒
	var w8_stub := WeaponBase.new()
	w8_stub.data = _gl.registry.get_weapon(&"W8_orbit_field")
	var w13_stub := WeaponBase.new()
	w13_stub.data = _gl.registry.get_weapon(&"W13_great_sword")
	var w9_stub := WeaponBase.new()
	w9_stub.data = _gl.registry.get_weapon(&"W9_arc_slash")
	var w0 := WeaponData.new()
	w0.id = &"TST_BLOCK_FORM0"
	w0.form = GameConst.WeaponForm.BALLISTIC
	var w0_stub := WeaponBase.new()
	w0_stub.data = w0
	_stubs.append(w8_stub)
	_stubs.append(w13_stub)
	_stubs.append(w9_stub)
	_stubs.append(w0_stub)
	_check("A3 required_class 门（W8 true / W13 true / W9 talisman 拒 / form0 拒 / "
		+ "无目标拒——零门早退不放行）",
		t != null and CardGenerator.mount_gate_allows(t, w8_stub)
		and CardGenerator.mount_gate_allows(t, w13_stub)
		and not CardGenerator.mount_gate_allows(t, w9_stub)
		and not CardGenerator.mount_gate_allows(t, w0_stub)
		and not CardGenerator.mount_gate_allows(t, null))
	# 成长终值（实件消费口：R14 逐层全额聚合——1 层 0.38 / 3 层 0.54）
	var w8 := _slot_solo(&"W8_orbit_field")
	if w8 == null:
		_check("A4 前置：W8 装配", false)
		_check("A5 前置：W8 装配", false)
		return
	var ok1: bool = _attach_card(w8)
	var c1: float = w8.bullet_block_chance()
	_check("A4 挂卡 1 层 → 0.30+0.08=0.38（bullet_block_chance live 消费口）",
		ok1 and absf(c1 - 0.38) < 0.000001, "ok=%s c=%s" % [str(ok1), str(c1)])
	var ok2: bool = _attach_card(w8)
	var ok3: bool = _attach_card(w8)
	var c3: float = w8.bullet_block_chance()
	var mult := 1.0
	for tb in w8.trait_stack.traits:
		if tb.data != null and tb.data.id == CARD_ID:
			mult = tb.value_mult
	_check("A5 挂卡 3 层 → 0.30+0.24=0.54（逐层全额；满层质变未开门 value_mult==1.0）",
		ok2 and ok3 and absf(c3 - 0.54) < 0.000001 and absf(mult - 1.0) < 0.000001,
		"ok2=%s ok3=%s c=%s mult=%s" % [str(ok2), str(ok3), str(c3), str(mult)])
	_check("A6 validator：validate_trait(卡)==[] + add_block ∈ ADD_POOL_IDS 第 17 员"
		+ "（追加不重排——前 16 位不动）",
		t != null and DataValidator.new().validate_trait(t).is_empty()
		and DataValidator.ADD_POOL_IDS.size() == 18
		and DataValidator.ADD_POOL_IDS[15] == &"add_range"
		and DataValidator.ADD_POOL_IDS[16] == &"add_block"
		and DataValidator.ADD_POOL_IDS[17] == &"add_boom_range",
		"size=%d" % DataValidator.ADD_POOL_IDS.size())


# ── B 组：统一掷骰口基线（4 项） ─────────────────────────────────
func _group_b_chance_base() -> void:
	print("── B 组：bullet_block_chance 基线（§3.1） ──")
	var w8s := WeaponBase.new()
	w8s.data = _gl.registry.get_weapon(&"W8_orbit_field")
	var w9s := WeaponBase.new()
	w9s.data = _gl.registry.get_weapon(&"W9_arc_slash")
	var w11s := WeaponBase.new()
	w11s.data = _gl.registry.get_weapon(&"W11_spirit_sword")
	var w12s := WeaponBase.new()
	w12s.data = _gl.registry.get_weapon(&"W12_ground_axe")
	var w1s := WeaponBase.new()
	w1s.data = _gl.registry.get_weapon(&"W1_pistol")
	_stubs.append(w8s)
	_stubs.append(w9s)
	_stubs.append(w11s)
	_stubs.append(w12s)
	_stubs.append(w1s)
	_check("B1 W8（melee/block_chance 0.30）→ 0.30",
		absf(w8s.bullet_block_chance() - 0.30) < 0.000001,
		str(w8s.bullet_block_chance()))
	_check("B2 W9（nullify 优先）→ 1.0",
		absf(w9s.bullet_block_chance() - 1.0) < 0.000001,
		str(w9s.bullet_block_chance()))
	_check("B3 W11/W12（法器 nullify=true）→ 1.0 / 1.0",
		absf(w11s.bullet_block_chance() - 1.0) < 0.000001
		and absf(w12s.bullet_block_chance() - 1.0) < 0.000001,
		"%s / %s" % [str(w11s.bullet_block_chance()), str(w12s.bullet_block_chance())])
	_check("B4 W1（form 0）→ 0.0（非近战族恒 0）",
		absf(w1s.bullet_block_chance() - 0.0) < 0.000001,
		str(w1s.bullet_block_chance()))


# ── C 组：W8 刀位挡弹（6 项） ────────────────────────────────────
func _group_c_w8_block() -> void:
	print("── C 组：W8 刀位挡弹（§3.3 两极 + 帽 + 表现口径） ──")
	var w8 := _slot_solo(&"W8_orbit_field")
	if w8 == null:
		_check("C 组前置：W8 装配", false)
		return
	var fired: bool = w8.try_fire()
	var field: OrbitField = w8.orbit_field
	_check("C1 enemy_bullet_grid 注入（OrbitField 字段 == GameLoop 同一网格实例）",
		fired and field != null and field.enemy_bullet_grid == _gl.enemy_bullet_grid)
	if field == null:
		return
	field.knockback = 0.0
	field.angular_speed = 0.0                      # 静止定相：orb0 = +90X
	w8.data.melee["block_chance"] = 1.0            # 1.0 桩（两极断言之全消极）
	var c := _gl.player.global_position
	var orb0 := c + Vector2(90.0, 0.0)
	var near: Array = []
	for off in [Vector2(0, 0), Vector2(6, 0), Vector2(0, 8), Vector2(-7, -5),
			Vector2(12, 4), Vector2(-4, 12)]:
		near.append(_spawn_bullet(orb0 + off))
	var far := _spawn_bullet(orb0 + Vector2(160.0, 0.0))
	_rebuild_bullet_grid()
	var ripples: Array = []
	_count_ripples(ripples)
	var parry0: int = DebugStats.get_counter(&"bullet_parry")
	_step(w8, 1)
	var blocked1: int = DebugStats.get_counter(&"bullet_parry") - parry0
	_step(w8, 1)
	var blocked2: int = DebugStats.get_counter(&"bullet_parry") - parry0 - blocked1
	_disconnect_ripples()
	_ripple_melee = ripples.size()
	_check("C2 chance=1.0 帽 4/tick（首 tick 恰 4）+ 余弹次 tick 续消（再 2）",
		blocked1 == 4 and blocked2 == 2 and _alive_count(near) == 0,
		"b1=%d b2=%d alive=%d" % [blocked1, blocked2, _alive_count(near)])
	_check("C3 刀位域外弹不受（160px > 查询域 orb_r×knife_scale+6）",
		far != null and is_instance_valid(far) and not (far as ProjectileBase).is_clean)
	_check("C6 表现口径（W8 概率域）：涟漪逐弹（Δ6）+ bullet_parry 计数同源（Δ6）",
		_ripple_melee == 6 and DebugStats.get_counter(&"bullet_parry") - parry0 == 6,
		"ripples=%d parryΔ=%d" % [_ripple_melee,
			DebugStats.get_counter(&"bullet_parry") - parry0])
	_release_list(near)
	_release_list([far])
	# 帽护栏：预置 30 弹单 tick 恰 4（≤帽——跨刀共享余额）
	var burst: Array = []
	for i in range(30):
		burst.append(_spawn_bullet(orb0
			+ Vector2(float(i % 6) * 3.0 - 7.5, float(i / 6) * 3.0 - 7.5)))
	_rebuild_bullet_grid()
	var parry_b0: int = DebugStats.get_counter(&"bullet_parry")
	_step(w8, 1)
	var cap30: int = DebugStats.get_counter(&"bullet_parry") - parry_b0
	_check("C5 帽护栏：预置 30 弹单 tick 消弹恰 4（≤帽 4/tick）",
		cap30 == 4, "cap=%d" % cap30)
	_release_list(burst)
	_clear_bullets()
	# 0 极：chance=0.0 零消弹
	var w8z := _slot_solo(&"W8_orbit_field")
	var firedz: bool = w8z != null and w8z.try_fire()
	var fieldz: OrbitField = w8z.orbit_field if w8z != null else null
	if not firedz or fieldz == null:
		_check("C4 chance=0.0 零消弹（力场缺失）", false)
		return
	fieldz.knockback = 0.0
	fieldz.angular_speed = 0.0
	w8z.data.melee["block_chance"] = 0.0
	var cz := _gl.player.global_position
	var bz: Array = []
	for i in range(3):
		bz.append(_spawn_bullet(cz + Vector2(90.0, 6.0 * float(i))))
	_rebuild_bullet_grid()
	var parry_z0: int = DebugStats.get_counter(&"bullet_parry")
	_step(w8z, 1)
	_check("C4 chance=0.0 零消弹（刀位域内 3 弹全保留 + 计数零增）",
		_alive_count(bz) == 3
		and DebugStats.get_counter(&"bullet_parry") == parry_z0,
		"alive=%d" % _alive_count(bz))


# ── D 组：法器确定性消弹（5 项） ─────────────────────────────────
func _my_swords(p_uid: int) -> Array[ProjectileBase]:
	var out: Array[ProjectileBase] = []
	for p in (_gl.pools[&"projectile"] as ProjectilePool).active_projectiles():
		var pb := p as ProjectileBase
		if pb != null and not pb.is_clean and int(pb.weapon_uid) == p_uid \
				and int(pb.generation) == 0:
			out.append(pb)
	return out


func _group_d_talisman() -> void:
	print("── D 组：法器路径消弹（§3.2——灵剑帽 6/tick + 斧落地帽 24/次） ──")
	# 灵剑飞行路径：1.0 全消、帽 6/剑/tick（两极全消极 + 帽）
	var w11 := _slot_solo(&"W11_spirit_sword")
	if w11 == null:
		_check("D 组前置：W11 装配", false)
		return
	var chance11: float = w11.bullet_block_chance()
	w11.try_fire()                                 # 无目标 → aim 回退 UP；剑悬停发射位
	var swords := _my_swords(int(w11.uid))
	if swords.is_empty():
		_check("D1 前置（剑在场）", false)
		_check("D2 前置（剑在场）", false)
	else:
		var sword_pos := (swords[0] as ProjectileBase).global_position
		var offs: Array[Vector2] = [Vector2(0, -4), Vector2(4, 0), Vector2(-4, 0),
			Vector2(0, 4), Vector2(7, 7), Vector2(-7, 7), Vector2(7, -7), Vector2(-7, -7)]
		for off in offs:
			_spawn_bullet(sword_pos + off)         # 全部 ≤13px（9+4 查询域内）
		var ctrl := _spawn_bullet(sword_pos + Vector2(0.0, -120.0))   # 查询超集域外控制弹
		_rebuild_bullet_grid()
		_bump()
		w11.tick(DT)                               # 武器一 tick → _tick_path_nullify
		var cleared := 0
		for b in _bullets:
			if b != ctrl and (b as ProjectileBase).is_clean:
				cleared += 1
		_check("D1 灵剑 chance==1.0（nullify 优先）+ 圈内 8 弹一 tick 恰消 6（帽 6/tick）",
			absf(chance11 - 1.0) < 0.000001 and cleared == 6,
			"chance=%s cleared=%d" % [str(chance11), cleared])
		_bump()
		w11.tick(DT)
		var cleared2 := 0
		for b in _bullets:
			if b != ctrl and (b as ProjectileBase).is_clean:
				cleared2 += 1
		_check("D2 第二 tick 余 2 全消（累计 8）+ 圈外控制弹不受",
			cleared2 == 8 and ctrl != null and is_instance_valid(ctrl)
			and not (ctrl as ProjectileBase).is_clean, "cleared2=%d" % cleared2)
	_release_my_swords(int(w11.uid))
	_clear_bullets()
	# 斧落地震荡：帽 24/次（预置 30 弹恰消 24——确定性全消极 + 帽）
	var axe := _slot_solo(&"W12_ground_axe")
	if axe == null:
		_check("D 组前置：W12 装配", false)
		return
	var target: Enemy = _spawn_e(Vector2(560.0, 640.0))   # 掷斧目标（落点 = 目标快照）
	var burst: Array = []
	for i in range(30):
		burst.append(_spawn_bullet(Vector2(560.0, 640.0)
			+ Vector2(float(i % 6) * 10.0 - 25.0, float(i / 6) * 10.0 - 25.0)))
	_rebuild_bullet_grid()
	var ripples: Array = []
	_count_ripples(ripples)
	var clear0: int = DebugStats.get_counter(&"axe_bullets_cleared")
	axe.cooldown_left = 0.0
	_bump()
	axe.tick(DT)                                   # 冷却就绪 + 有敌 → 掷斧
	_run_axes_to_completion()
	_disconnect_ripples()
	_ripple_talisman = ripples.size()
	var cleared_axe: int = DebugStats.get_counter(&"axe_bullets_cleared") - clear0
	_check("D3 斧落地震荡帽 24/次：预置 30 弹恰消 24（axe_bullets_cleared Δ24）",
		cleared_axe == 24, "cleared=%d" % cleared_axe)
	_check("D4 余 6 保留（帽外不受）+ 落地涟漪逐弹 Δ24（确定性消弹共用涟漪口径）",
		_alive_count(burst) == 6 and _ripple_talisman == 24,
		"alive=%d ripples=%d" % [_alive_count(burst), _ripple_talisman])
	_release_list(burst)
	_clear_bullets()
	# 斧飞行路径消弹（R243 迁移/发现修复——设计 §3.2 W12「飞行接触同灵剑（帽 6/tick）」：
	# 飞行走廊 = 100% 消弹域；两极断言之 1.0 全消极 + 帽）
	var target5: Enemy = _spawn_e(Vector2(560.0, 640.0))   # 掷斧目标（开火门 + 落点快照）
	axe.cooldown_left = 0.0
	_bump()
	axe.tick(DT)                                   # 掷斧（try_fire 后同 tick _on_tick_post 起巡）
	var axes5 := _axes_live()
	var near5: Array = []
	if axes5.is_empty():
		_check("D5 斧飞行路径消弹（前置：斧在场）", false)
	else:
		var flight := axes5[0] as ProjectileBase
		for i in range(15):                        # 手推斧沿路径前移 15 tick（≈80px，未抵落点）
			_bump()
			flight.tick(DT)
		var axe_pos := flight.global_position
		var offs5: Array[Vector2] = [Vector2(0, -4), Vector2(4, 0), Vector2(-4, 0),
			Vector2(0, 4), Vector2(7, 7), Vector2(-7, 7), Vector2(7, -7), Vector2(-7, -7)]
		for off in offs5:
			near5.append(_spawn_bullet(axe_pos + off))   # 全部 ≤13px（hitbox 12+4 查询域内）
		var ctrl5 := _spawn_bullet(axe_pos + Vector2(0.0, -120.0))   # 查询超集域外控制弹
		_rebuild_bullet_grid()
		_bump()
		axe.tick(DT)                               # 武器 tick → _tick_path_nullify
		var c5a := 8 - _alive_count(near5)
		_bump()
		axe.tick(DT)
		var c5b := 8 - _alive_count(near5)
		_check("D5 斧飞行路径消弹：chance==1.0 圈内 8 弹一 tick 恰消 6（帽 6/tick）"
			+ "+ 次 tick 全消（累计 8）+ 圈外控制弹不受",
			c5a == 6 and c5b == 8 and ctrl5 != null and is_instance_valid(ctrl5)
			and not (ctrl5 as ProjectileBase).is_clean, "c1=%d c2=%d" % [c5a, c5b])
		_release_list([flight])                    # 中途斧回收（不落点——冻结套件防残留）
	_release_list(near5 if not axes5.is_empty() else [])
	_clear_bullets()
	_clear_enemies()


func _release_my_swords(p_uid: int) -> void:
	var pool := _gl.pools[&"projectile"] as ProjectilePool
	var victims: Array = []
	for p in pool.active_projectiles():
		var pb := p as ProjectileBase
		if pb != null and not pb.is_clean and int(pb.weapon_uid) == p_uid:
			victims.append(pb)
	for v in victims:
		pool.release(v)


func _axes_live() -> Array:                        # 活跃掷斧弹（flight_axe 且 live）
	var out: Array = []
	for p in (_gl.pools[&"projectile"] as ProjectilePool).active_projectiles():
		if is_instance_valid(p) and p is ProjectileBase \
				and bool((p as ProjectileBase).get("_flight_axe")) \
				and bool((p as ProjectileBase).get("_live")):
			out.append(p)
	return out


func _run_axes_to_completion(p_max_iters: int = 300) -> void:
	# 母斧逐 tick 推进至落地回收（liedifu 同式——只驱 flight_axe 弹，不驱武器防重掷）
	for i in range(p_max_iters):
		var axes := _axes_live()
		if axes.is_empty():
			return
		_bump()
		for a in axes:
			if is_instance_valid(a):
				(a as ProjectileBase).tick(DT)


# ── E 组：W13 警戒弧双域（7 项） ─────────────────────────────────
func _group_e_w13_guard() -> void:
	print("── E 组：W13 常驻警戒弧 + 斩击窗双域（§3.3/§2.5-6） ──")
	var w13 := _slot_solo(&"W13_great_sword")
	if w13 == null:
		_check("E 组前置：W13 装配", false)
		return
	w13.data.melee["block_chance"] = 1.0           # 1.0 桩（先于首拍——窗快照同值）
	var c := _gl.player.global_position
	_spawn_e(c + Vector2(300.0, 0.0))              # 敌 +X 定 facing（在场防 R33 不开火门）
	_step(w13, 1)                                  # 首拍：try_fire 开窗 + facing 缓存
	_check("E1 _guard_facing 缓存自 aim（敌 +X → ≈0）+ 斩击窗激活（_slash_window_active）",
		w13.arc_slash != null and absf(wrapf(w13._guard_facing, -PI, PI)) < 0.01
		and w13._slash_window_active(),
		"facing=%s" % str(w13._guard_facing))
	# 斩击窗全弧域：±60° 弹（窗弧 ±70° 内、guard 域 0.6R×±45° 外）——只能由 ArcSlash 口消
	var w1 := _spawn_bullet(c + Vector2(75.0, 129.9))     # 150∠+60°
	var w2 := _spawn_bullet(c + Vector2(75.0, -129.9))    # 150∠-60°
	var rear := _spawn_bullet(c + Vector2(-80.0, 0.0))    # 180°（窗弧外 + guard 停巡）
	_rebuild_bullet_grid()
	var parry_w0: int = DebugStats.get_counter(&"bullet_parry")
	_step(w13, 1)                                  # 窗内 tick → _nullify_enemy_bullets
	_check("E2 斩击窗全弧同受掷骰（±60° 1.0 桩全消——guard 半角 45°/半径 0.6R 域外）"
		+ "+ 窗内正后 180° 弹不受",
		(w1 as ProjectileBase).is_clean and (w2 as ProjectileBase).is_clean
		and rear != null and is_instance_valid(rear)
		and not (rear as ProjectileBase).is_clean
		and DebugStats.get_counter(&"bullet_parry") - parry_w0 == 2,
		"w=%s/%s rear=%s parryΔ=%d" % [str((w1 as ProjectileBase).is_clean),
			str((w2 as ProjectileBase).is_clean),
			str(rear != null and is_instance_valid(rear)
				and not (rear as ProjectileBase).is_clean),
			DebugStats.get_counter(&"bullet_parry") - parry_w0])
	_release_list([w1, w2, rear])
	_clear_bullets()
	_step(w13, 44)                                 # 窗耗尽（0.34s≈41 帧）+ 待机空巡
	_check("E3 待机警戒域：正面 90° 扇形 3 弹全消 + 侧后 90° 外不受 + 涟漪逐弹",
		_guard_front_check(w13, c))
	# 帽 4/检查 + 节拍 0.1s（C 组 melee 同式双轮推进）
	w13._guard_left = 0.0                          # 同步节拍：下一 tick 即检查
	var burst: Array = []
	for i in range(10):
		burst.append(_spawn_bullet(c + Vector2(60.0 + 4.0 * float(i),
			12.0 * float(i % 3))))
	_rebuild_bullet_grid()
	_step(w13, 1)
	var cap_first := 10 - _alive_count(burst)
	_release_list(burst)
	_clear_bullets()
	var burst2: Array = []
	for i in range(10):
		burst2.append(_spawn_bullet(c + Vector2(60.0 + 4.0 * float(i),
			12.0 * float(i % 3))))
	_rebuild_bullet_grid()
	_step(w13, 8)                                  # 节拍余量 0.0917−0.0667 > 0 → 未到检查拍
	var idle_alive := _alive_count(burst2)
	_step(w13, 6)                                  # 累计 ≥ 0.1s → 检查触发
	var cap_second := idle_alive - _alive_count(burst2)
	_check("E4 警戒帽 4/检查（两轮各恰 4 消弹）", cap_first == 4 and cap_second == 4,
		"first=%d second=%d" % [cap_first, cap_second])
	_check("E5 警戒节拍 0.1s（8 tick=0.067s 未到零消弹；跨 0.1s 触发）",
		idle_alive == 10 and cap_second == 4, "idle_alive=%d" % idle_alive)
	_release_list(burst2)
	_clear_bullets()
	# 0 极：chance=0.0 待机零消弹
	var w13z := _slot_solo(&"W13_great_sword")
	if w13z == null:
		_check("E6 chance=0.0 待机零消弹（装配缺失）", false)
		_clear_enemies()
		return
	w13z.data.melee["block_chance"] = 0.0
	_spawn_e(c + Vector2(300.0, 0.0))              # 敌在场（开火门）
	_step(w13z, 46)                                # 开窗 + 窗耗尽（敌在场防 R33 抖动）
	var bz: Array = []
	for i in range(3):
		bz.append(_spawn_bullet(c + Vector2(70.0 + 5.0 * float(i), 0.0)))
	_rebuild_bullet_grid()
	var parry_z0: int = DebugStats.get_counter(&"bullet_parry")
	w13z._guard_left = 0.0                         # 同步节拍（chance=0 早退）
	_step(w13z, 2)
	_check("E6 chance=0.0 待机零消弹（正面弹全保留 + 计数零增）",
		_alive_count(bz) == 3
		and DebugStats.get_counter(&"bullet_parry") == parry_z0,
		"alive=%d" % _alive_count(bz))
	_release_list(bz)
	_clear_bullets()
	# 阔剑挥斩窗 live 挡弹成长（R243 迁移/发现修复——原 spawn 快照 0.30 经 ArcSlash
	# _bullet_block_chance 的 >=0 短路，MEC_BULLET_PARRY 成长对斩击窗永不生效，仅警戒弧
	# 走 live；-1 哨兵后窗口逐 tick live 读基线 + Σadd_block）
	var w13p := _slot_solo(&"W13_great_sword")
	if w13p == null:
		_check("E7 挥斩窗弹反 live 成长（前置：W13 装配）", false)
		_clear_enemies()
		return
	w13p.data.melee["block_chance"] = 0.0          # 基线归零（快照口径下窗恒 0——成长不可见）
	var okp1: bool = _attach_card(w13p)
	var okp2: bool = _attach_card(w13p)
	var okp3: bool = _attach_card(w13p)
	_spawn_e(c + Vector2(300.0, 0.0))              # 敌在场（R33 开火门）
	w13p.try_fire()                                # 开窗（旧口径：快照 0.0 短路——挂卡无效）
	var win_chance: float = 0.0 if w13p.arc_slash == null \
		else float(w13p.arc_slash._bullet_block_chance())
	_check("E7 阔剑挥斩窗挂弹反卡后挡弹率上升：基线 0 + 3 层卡 → 窗掷骰口 0.24 live"
		+ "（快照口径恒 0——-1 哨兵修复判据）",
		okp1 and okp2 and okp3 and w13p.arc_slash != null
		and absf(win_chance - 0.24) < 0.000001
		and absf(float(w13p.bullet_block_chance()) - 0.24) < 0.000001,
		"win=%s live=%s" % [str(win_chance), str(w13p.bullet_block_chance())])
	_clear_enemies()


func _guard_front_check(p_w13: WeaponBase, p_c: Vector2) -> bool:
	# E3 断言体：正面 3 弹（80∠0° / 80.6∠29.7° / 80.6∠-29.7°——guard 域 114px×±45° 内）
	# 全消 + 侧后弹不受 + 涟漪 3。
	p_w13._guard_left = 0.0
	var f1 := _spawn_bullet(p_c + Vector2(80.0, 0.0))
	var f2 := _spawn_bullet(p_c + Vector2(70.0, 40.0))
	var f3 := _spawn_bullet(p_c + Vector2(70.0, -40.0))
	var rear := _spawn_bullet(p_c + Vector2(-80.0, 0.0))
	var bullets: Array = [f1, f2, f3, rear]
	_rebuild_bullet_grid()
	var ripples: Array = []
	_count_ripples(ripples)
	var parry0: int = DebugStats.get_counter(&"bullet_parry")
	_step(p_w13, 1)
	_disconnect_ripples()
	var rear_alive: bool = rear != null and is_instance_valid(rear) \
		and not (rear as ProjectileBase).is_clean
	var front_ok: bool = (_alive_count(bullets) == 1 and rear_alive
		and DebugStats.get_counter(&"bullet_parry") - parry0 == 3
		and ripples.size() == 3)
	return front_ok


# ── F 组：集成与全量校验（3 项） ─────────────────────────────────
func _group_f_integration() -> void:
	print("── F 组：全量校验 + 涟漪口径汇总 + 成长 live 消费 ──")
	var rejected_n := int(_gl.registry.report.get("rejected", -1))
	_check("F1 registry 全量校验 rejected==0（新卡入库零剔除）",
		rejected_n == 0 and int(_gl.registry.report.get("total", 0)) > 0,
		"rejected=%d total=%d" % [rejected_n, int(_gl.registry.report.get("total", 0))])
	_check("F2 涟漪口径汇总：近战概率域（W8）与法器确定性域（斧落地）共用 "
		+ "emit_bullet_nullified（双侧均触发）",
		_ripple_melee > 0 and _ripple_talisman > 0,
		"melee=%d talisman=%d" % [_ripple_melee, _ripple_talisman])
	var w13 := _slot_solo(&"W13_great_sword")
	var ok1: bool = w13 != null and _attach_card(w13)
	var ok2: bool = w13 != null and _attach_card(w13)
	var ok3: bool = w13 != null and _attach_card(w13)
	var c := 0.0 if w13 == null else w13.bullet_block_chance()
	_check("F3 成长达 W13 警戒弧 live 消费口（挂卡 3 层 → bullet_block_chance==0.54）",
		ok1 and ok2 and ok3 and absf(c - 0.54) < 0.000001, "c=%s" % str(c))

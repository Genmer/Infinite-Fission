# tests/runner/r243_lingjian_cases.gd
# R243 法器·灵剑（w2-lingjian）用例体（入口运行时 load——cases 禁 test_ 前缀防电池 glob 误收）。
# 覆盖（任务验收 ①~⑧ + 设计 §9.1 talisman ①②③）：
# ① spawn 速度 860 / 射程 420（寿命=range/speed×1.15）/ pierce=1；
#   命中单敌即回收（PIERCE_DEPLETED）且第二敌不掉血（单体语义=永不穿过多目标）
# ② spawn 键集：flight_sword=true / panel_snapshot+acquire_runtime / weapon_ref /
#   attach_elements=元素池副本 / element=逐发掷取 / size_mult 恒 1
# ③ 数值：crit 0.05/2.0 默认；基础击退 0 + MEC_KNOCK 平加 60 非死卡；
#   AFF_RANGE 3 层 → 射程 646.8 且寿命随射程自动延长；AFF_CDR 经 cd 通道自动生效
# ③体积 G=MEC_GIANT_BLADE：G=1→10.8 / G=2→12.6（9×1.2/9×1.4），size_mult 恒 1
# ④ 飞行路径消弹：chance=1.0 桩下全消、帽 6/tick；chance=0 极零消弹（两极断言）
# ⑤ 数量挂点（§4.3）：1+min(_orbit_link_count(),6)；帽 8 层假栈 → 7
# ⑤b 齐射分配（R243 迁移/发现修复——需求 8 可读性）：第 i 剑掷第 i 近敌（三敌三剑
#   逐位分敌）；无目标 ±4°/剑 扇出兜底（slot 0 贴 aim 基向）——数量词条非隐形单体倍伤
# ⑦ 质变挂点 pre-w4 守卫：transcend 占位在册但 volley/fan 不提前生效 = 单剑
# ⑧ 挂 MEC_FRACTAL 子代 flight_sword=true（迷你飞剑 ±28°、atk×0.4）
# ⑥ 图标：weapon_icon_tex(false/true) 56px 非空、质变鎏金与默认银蓝互异
# ⚠ texture_factory 委托臂（共享文件，非本任务文件集）has_static_method 在 Godot 4.3
#   不存在——W11 图标委托臂触发即脚本报错（详见任务产出说明），故套件只断言本脚本
#   static func 本体（委托臂修复由共享文件归属方完成）。
# 最后：套件总项数断言（R231 假绿教训）。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const DT := 1.0 / 120.0
const EXPECTED_TOTAL := 38

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null
var _w: FlyingSwordWeapon = null
var _bullets: Array[Node2D] = []             # 桩敌弹（rebuild 敌弹网格用）


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(20261008)
	if not _boot_game_loop():
		_check("前置：GameLoop 装配", false, "start_run 失败")
		_report()
		return
	await tree.process_frame
	await tree.process_frame
	_case1_setup_and_numbers()
	_case2_single_target()
	_case3_giant_blade_radius()
	_case4_path_nullify()
	_case5_volley_link()
	_case5b_multi_target()
	_case6_transcend_guard_and_fractal()
	_case7_icon()
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


# ── 夹具 ──────────────────────────────────────────────────────────
func _boot_game_loop() -> bool:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "R243LingjianGameLoopUnderTest"
	tree.get_root().add_child(_gl)
	_gl.state = GameConst.GameStatus.MENU
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	var ok: bool = _gl.start_run()
	_gl.state = GameConst.GameStatus.MENU        # 冻结帧序——全部手动驱动（r241 同式）
	_gl.player.set("max_hp", 1000000.0)
	_gl.player.set("hp", 1000000.0)
	_gl.player.global_position = Vector2(360.0, 640.0)   # 居中（几何确定性）
	_gl.player.set("unlocked_slots", 5)
	_w = _add_w11()
	return ok and _w != null


func _teardown() -> void:
	tree.paused = false
	RunSave.clear()
	_release_all_proj()
	_clear_enemies()
	if _gl != null:
		_gl.free()
		_gl = null


func _add_w11() -> FlyingSwordWeapon:
	# 装备 W11（工厂数型切换断言位：swords mode → FlyingSwordWeapon）+ 探针确定性
	#（crit=0 副本数据 + meta 修正归零——伤害探针确定性；w8 夹具同式）
	var w := _gl.player.add_weapon(_gl.registry.get_weapon(&"W11_spirit_sword")) as FlyingSwordWeapon
	if w != null:
		w.data = w.data.duplicate(true)
		w.data.crit_rate = 0.0
		w.meta_atk_pct = 0.0
		w.call(&"_invalidate_panel")
	return w


func _strip_traits() -> void:
	if _w != null and _w.trait_stack != null:
		_w.trait_stack.traits.clear()
		_w.call(&"_invalidate_panel")


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


func _spawn_bullet(p_pos: Vector2) -> ProjectileBase:
	# 桩敌弹（team=1 静止珠——敌弹 spawn 点最小参数域，_tick 不驱动）
	var pool := _gl.pools[&"projectile"] as ProjectilePool
	var b := pool.acquire() as ProjectileBase
	if b == null:
		return null
	b.pool = pool
	b.enemy_grid = _gl.enemy_grid
	b.global_position = p_pos
	b.spawn({
		"position": p_pos, "velocity": Vector2.ZERO, "lifetime": 30.0,
		"pierce": 1, "hitbox_radius": 6.0, "team": 1,
		"panel_snapshot": {"base_atk": 5.0},
	})
	_bullets.append(b)
	return b


func _rebuild_bullet_grid() -> void:
	_gl.enemy_bullet_grid.rebuild(_bullets)


func _clear_bullets() -> void:
	for b in _bullets.duplicate():
		if b != null and is_instance_valid(b) and not (b as ProjectileBase).is_clean:
			(_gl.pools[&"projectile"] as ProjectilePool).release(b)
	_bullets.clear()
	_rebuild_bullet_grid()


func _my_swords(p_gen: int = 0) -> Array[ProjectileBase]:
	var pool := _gl.pools[&"projectile"] as ProjectilePool
	var out: Array[ProjectileBase] = []
	for p in pool.active_projectiles():
		var pb := p as ProjectileBase
		if pb != null and not pb.is_clean and int(pb.weapon_uid) == _w.uid \
				and int(pb.generation) == p_gen:
			out.append(pb)
	return out


func _release_my_swords() -> void:
	# 释放本武器全部在场弹（任意 generation——母弹/子代通吃）
	var pool := _gl.pools[&"projectile"] as ProjectilePool
	var victims: Array = []
	for p in pool.active_projectiles():
		var pb := p as ProjectileBase
		if pb != null and not pb.is_clean and int(pb.weapon_uid) == _w.uid:
			victims.append(pb)
	for v in victims:
		pool.release(v)


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
	_bullets.clear()


func _bump_tick(p_node: Node) -> void:
	GameConfig.frame_stamp += 1                  # E-03 帧闸门推进（w8 夹具同式）
	p_node.call(&"tick", DT)


func _fly_until_recycled(p_sword: ProjectileBase, p_max_ticks: int = 240) -> int:
	var n := 0
	while n < p_max_ticks and not p_sword.is_clean:
		GameConfig.frame_stamp += 1
		p_sword.tick(DT)
		n += 1
	return n


# ── ①②③ 装配 / spawn 键集 / 数值与节拍 ──────────────────────────
func _case1_setup_and_numbers() -> void:
	print("── ①②③ 装配 / spawn 键集 / 数值与节拍 ──")
	_check("前置：工厂数型切换——add_weapon(W11) → FlyingSwordWeapon 实例",
		_w is FlyingSwordWeapon)
	_strip_traits()
	var e := _spawn_e(Vector2(360.0, 430.0))     # 索敌目标（正上方 210px）
	var fired: bool = _w.try_fire()
	var swords := _my_swords()
	_check("①try_fire 发射真投射物（恰 1 柄在场）", fired and swords.size() == 1,
		"n=%d" % swords.size())
	if swords.is_empty():
		_clear_enemies()
		return
	var s := swords[0]
	var v := s.velocity
	# 二cu 合一：W11 出膛口=悬浮化身（_avatar_muzzle 同弹道武器口径）——方向基准随之
	_check("①spawn 速度 860px/s（sword_speed 表值）+ 方向朝最近敌（自化身出膛口，二cu）",
		absf(v.length() - 860.0) < 1e-3
		and v.normalized().dot((e.global_position - _w.muzzle_position()).normalized()) > 0.999,
		"spd=%s" % str(v.length()))
	_check("①pierce_left==1（表 pierce=1——单体语义参数面）", int(s.pierce_left) == 1,
		"pierce=%d" % int(s.pierce_left))
	_check("①G=0 判定半径 9.0（hitbox_r 表值）+ size_mult 恒 1",
		absf(float(s.hitbox_radius) - 9.0) < 1e-3 and is_equal_approx(float(s.size_mult), 1.0),
		"r=%s size=%s" % [str(s.hitbox_radius), str(s.size_mult)])
	_check("③寿命=420/860×1.15（射程→寿命公式）",
		absf(float(s.lifetime_left) - 420.0 / 860.0 * 1.15) < 1e-3,
		"life=%s" % str(s.lifetime_left))
	_check("②flight_sword 形态键读回 true（w1 弹体分支接管面）",
		bool(s.get("_flight_sword")) and not bool(s.get("_flight_axe")))
	_check("②panel_snapshot 读回 base_atk 24 + weapon_ref==武器 + acquire_runtime 运行栈在册",
		is_equal_approx(float(s.panel_snapshot.get("base_atk", 0.0)), 24.0)
		and s.weapon_ref == _w and s.trait_stack != null,
		"atk=%s ref=%s stack=%s" % [str(s.panel_snapshot.get("base_atk", 0.0)),
		str(s.weapon_ref == _w), str(s.trait_stack != null)])
	_release_my_swords()
	# 元素键：挂 FIR → attach_elements==池副本、element 逐发掷取 ∈ 池
	var ok_fir: bool = _w.attach_trait(_gl.registry.get_trait(&"ELE_IGNITE"))
	var ele := int((_gl.registry.get_trait(&"ELE_IGNITE") as TraitData).params.get("element", -1))
	_w.try_fire()
	swords = _my_swords()
	var elem_ok := false
	if swords.size() >= 1:
		var s2 := swords[swords.size() - 1]
		elem_ok = s2.attach_elements == [ele] and int(s2.element) == ele
	_check("②attach_elements==_element_pool().duplicate()（[FIR]）+ element=逐发掷取∈池",
		ok_fir and elem_ok, "fir=%s attach=%s" % [str(ok_fir), str(elem_ok)])
	_release_my_swords()
	_strip_traits()
	# 节拍：cd 通道 _fire_interval + AFF_CDR 自动生效（add_cdr 0.1）
	var i0 := float(_w._fire_interval())
	var rof_mult := float(_w._player_rof_mult())
	var ok_cdr: bool = _w.attach_trait(_gl.registry.get_trait(&"AFF_CDR"))
	var i1 := float(_w._fire_interval())
	_check("③节拍 cd 通道：L1 interval==0.55/rof_mult + AFF_CDR → ×0.9 自动生效",
		is_equal_approx(i0, 0.55 / rof_mult) and ok_cdr
		and is_equal_approx(i1, i0 * 0.9),
		"i0=%s i1=%s" % [str(i0), str(i1)])
	# crit 默认（未被探针副本污染的原表读面板——0.05/2.0）
	var w_probe := FlyingSwordWeapon.new()
	w_probe.data = _gl.registry.get_weapon(&"W11_spirit_sword")
	w_probe.trait_stack = TraitStack.new()
	var snap := w_probe.build_panel_snapshot()
	_check("③crit 默认 0.05/2.0（W11 表值入面板）",
		is_equal_approx(float(snap.get("crit_rate", 0.0)), 0.05)
		and is_equal_approx(float(snap.get("crit_mult", 0.0)), 2.0),
		"rate=%s mult=%s" % [str(snap.get("crit_rate", 0.0)), str(snap.get("crit_mult", 0.0))])
	w_probe.free()
	# 击退：基础 0（melee 段不设 knockback）+ MEC_KNOCK 平加 60（非死卡——弹体命中路径
	# 经 weapon_ref.knockback_force() 自动消费）
	_check("③基础击退 0 + MEC_KNOCK 平加 60（Σadd_knock 非死卡）",
		is_equal_approx(float(_w.knockback_force()), 0.0)
		and _w.attach_trait(_gl.registry.get_trait(&"MEC_KNOCK"))
		and is_equal_approx(float(_w.knockback_force()), 60.0),
		"kb=%s" % str(_w.knockback_force()))
	_strip_traits()
	# AFF_RANGE 3 层：射程 646.8（420×1.54）+ 寿命随射程自动延长
	var ok_r1: bool = _w.attach_trait(_gl.registry.get_trait(&"AFF_RANGE"))
	var ok_r2: bool = _w.attach_trait(_gl.registry.get_trait(&"AFF_RANGE"))
	var ok_r3: bool = _w.attach_trait(_gl.registry.get_trait(&"AFF_RANGE"))
	_w.try_fire()
	swords = _my_swords()
	var range_ok := false
	if swords.size() >= 1:
		var s3 := swords[swords.size() - 1]
		range_ok = is_equal_approx(float(_w._range_mult()), 1.54) \
			and absf(float(_w._sword_range()) - 646.8) < 0.05 \
			and absf(float(s3.lifetime_left) - 646.8 / 860.0 * 1.15) < 1e-3
	_check("③AFF_RANGE 3 层 → 飞行射程 646.8（420×1.54）+ 寿命=range/speed×1.15 随射程延长",
		ok_r1 and ok_r2 and ok_r3 and range_ok,
		"mult=%s range=%s" % [str(_w._range_mult()), str(_w._sword_range())])
	_release_my_swords()
	_strip_traits()
	_clear_enemies()


# ── ① 命中单敌即回收、第二敌不掉血 ───────────────────────────────
func _case2_single_target() -> void:
	print("── ① 单体命中回收（PIERCE_DEPLETED）+ 第二敌不掉血 ──")
	var ea := _spawn_e(Vector2(360.0, 600.0))    # 弹道上第一敌（玩家上方 40px）
	var eb := _spawn_e(Vector2(360.0, 300.0))    # 同线后方第二敌（340px）
	var hp_a0 := float(ea.hp)
	var hp_b0 := float(eb.hp)
	var rec0 := DebugStats.get_counter(&"recycle_reason_1")   # PIERCE_DEPLETED 计数
	var fired: bool = _w.try_fire()
	var swords := _my_swords()
	if not fired or swords.is_empty():
		_check("①命中单敌回收", false, "fired=%s n=%d" % [str(fired), str(swords.size())])
		_clear_enemies()
		return
	var ticks := _fly_until_recycled(swords[0])
	var dmg_a := hp_a0 - float(ea.hp)
	var rec1 := DebugStats.get_counter(&"recycle_reason_1")
	_check("①命中单敌掉血恰 24（crit=0 探针确定性，tol 0.05）",
		absf(dmg_a - 24.0) < 0.05, "Δ=%s ticks=%d" % [str(dmg_a), ticks])
	_check("①命中 1 敌即回收（is_clean + PIERCE_DEPLETED 计数恰 +1）",
		swords[0].is_clean and rec1 == rec0 + 1, "clean=%s rec=%d→%d"
		% [str(swords[0].is_clean), rec0, rec1])
	_check("①第二敌不掉血（单体语义=永不穿过多目标）",
		absf(hp_b0 - float(eb.hp)) < 0.001, "Δb=%s" % str(hp_b0 - float(eb.hp)))
	_check("①回收后武器侧飞剑出列（在场 gen0 剑数归零）", _my_swords().is_empty())
	_clear_enemies()


# ── ③ 体积判定成长（MEC_GIANT_BLADE） ────────────────────────────
func _case3_giant_blade_radius() -> void:
	print("── ③ 体积判定成长 G=1→10.8 / G=2→12.6（size_mult 恒 1） ──")
	var ok_g1: bool = _w.attach_trait(_gl.registry.get_trait(&"MEC_GIANT_BLADE"))
	_check("③G=1：_sword_hit_radius()==10.8（9×1.2）",
		ok_g1 and absf(float(_w._sword_hit_radius()) - 10.8) < 1e-3,
		"r=%s" % str(_w._sword_hit_radius()))
	var ok_g2: bool = _w.attach_trait(_gl.registry.get_trait(&"MEC_GIANT_BLADE"))
	_w.try_fire()
	var swords := _my_swords()
	var spawn_ok := false
	if swords.size() >= 1:
		var s := swords[swords.size() - 1]
		spawn_ok = absf(float(s.hitbox_radius) - 12.6) < 1e-3 \
			and is_equal_approx(float(s.size_mult), 1.0)
	_check("③G=2：判定半径 12.6（9×1.4）实弹读回 + size_mult 恒 1",
		ok_g2 and absf(float(_w._sword_hit_radius()) - 12.6) < 1e-3 and spawn_ok,
		"r=%s spawn_ok=%s" % [str(_w._sword_hit_radius()), str(spawn_ok)])
	_release_my_swords()
	_strip_traits()


# ── ④ 飞行路径消弹（chance 两极 + 帽 6/tick） ─────────────────────
func _case4_path_nullify() -> void:
	print("── ④ 飞行路径消弹：chance=1.0 全消帽 6/tick；chance=0 极零消弹 ──")
	_clear_enemies()
	var chance := float(_w.bullet_block_chance())
	_check("④nullify=true → bullet_block_chance()==1.0（确定性掷骰口）",
		is_equal_approx(chance, 1.0), "chance=%s" % str(chance))
	_w.try_fire()                                # 无目标 → aim 回退 UP；剑悬停发射位
	var swords := _my_swords()
	if swords.is_empty():
		_check("④路径消弹前置（剑在场）", false, "n=0")
		return
	var sword_pos := (swords[0] as ProjectileBase).global_position
	var in_r: Array[Vector2] = [Vector2(0, -4), Vector2(4, 0), Vector2(-4, 0), Vector2(0, 4),
		Vector2(7, 7), Vector2(-7, 7), Vector2(7, -7), Vector2(-7, -7)]   # 全部 ≤13px（9+4）
	for off in in_r:
		_spawn_bullet(sword_pos + off)
	# 圈外控制弹：置于查询超集半径之外（SpaceGrid.query_circle 保守超集口径
	# reach=r+max_entity_radius(64)→13+64=77px——40px 仍在查询返回集内会被全消，
	# 故控制位取 120px；生产语义=返回集全消，无窄相，与 ArcSlash 消弹同口径）
	var ctrl := _spawn_bullet(sword_pos + Vector2(0.0, -120.0))
	_rebuild_bullet_grid()
	_bump_tick(_w)                               # 武器一 tick → _on_tick_post 路径消弹
	var cleared := 0
	for b in _bullets:
		if b != ctrl and (b as ProjectileBase).is_clean:
			cleared += 1
	_check("④圈内 8 弹一 tick 恰消 6（帽 6/tick）", cleared == 6, "cleared=%d" % cleared)
	_check("④圈外控制弹不受影响", not ctrl.is_clean)
	_bump_tick(_w)
	var cleared2 := 0
	for b in _bullets:
		if b != ctrl and (b as ProjectileBase).is_clean:
			cleared2 += 1
	_check("④第二 tick 余 2 全消（累计 8——确定性全消）", cleared2 == 8,
		"cleared=%d" % cleared2)
	_release_my_swords()
	_clear_bullets()
	# chance=0 极（拔 nullify 的副本数据——两极断言之 0 极）
	_w.data.melee["nullify"] = false
	_w.call(&"_invalidate_panel")
	var chance0 := float(_w.bullet_block_chance())
	for i in range(3):
		_spawn_bullet(sword_pos + Vector2(float(i) * 3.0, -3.0))
	_rebuild_bullet_grid()
	_w.try_fire()
	swords = _my_swords()
	if swords.is_empty():
		_check("④chance=0 极前置（剑在场）", false, "n=0")
	else:
		_bump_tick(_w)
		var cleared0 := 0
		for b in _bullets:
			if (b as ProjectileBase).is_clean:
				cleared0 += 1
		_check("④chance=0 极（block_chance=0）一 tick 零消弹",
			is_equal_approx(chance0, 0.0) and cleared0 == 0,
			"chance=%s cleared=%d" % [str(chance0), cleared0])
	_release_my_swords()
	_clear_bullets()
	_w.data.melee["nullify"] = true              # 还原副本数据
	_w.call(&"_invalidate_panel")


# ── ⑤ 数量挂点（inert：1+min(link,6)） ───────────────────────────
func _case5_volley_link() -> void:
	print("── ⑤ 数量挂点：1+min(_orbit_link_count(),6)，额外 +6 封顶 ──")
	_clear_enemies()
	_strip_traits()
	_check("⑤无词条 _volley_sword_count()==1",
		int(_w._volley_sword_count()) == 1, "n=%d" % int(_w._volley_sword_count()))
	var ok_l1: bool = _w.attach_trait(_gl.registry.get_trait(&"MEC_ORBIT_LINK"))
	var c1 := int(_w._volley_sword_count())
	var ok_l2: bool = _w.attach_trait(_gl.registry.get_trait(&"MEC_ORBIT_LINK"))
	var c2 := int(_w._volley_sword_count())
	_check("⑤MEC_ORBIT_LINK 1 层→2 / 2 层→3（_orbit_link_count 1/2）",
		ok_l1 and ok_l2 and c1 == 2 and c2 == 3
		and int(_w._orbit_link_count()) == 2, "c1=%d c2=%d" % [c1, c2])
	# 帽：注入 layers=8 假 TraitBase（真类型——typed Array[TraitBase]），断言 1+min(8,6)=7
	var scratch := TraitStack.new()
	var fake := TraitBase.new()
	fake.data = _gl.registry.get_trait(&"MEC_ORBIT_LINK")
	fake.layers = 8
	scratch.traits.append(fake)
	var saved := _w.trait_stack
	_w.trait_stack = scratch
	var capped := int(_w._volley_sword_count())
	_w.trait_stack = saved
	_check("⑤额外 +6 封顶（8 层假栈 → 1+min(8,6)=7）", capped == 7, "capped=%d" % capped)
	_release_my_swords()
	_w.try_fire()
	var n := _my_swords().size()
	_check("⑤实弹齐射数==3（2 层挂卡——消费侧真正消费挂点）", n == 3, "n=%d" % n)
	_release_my_swords()
	_strip_traits()


# ── ⑤b 齐射分配（R243 发现修复：多剑不同目标/角度） ───────────────
func _case5b_multi_target() -> void:
	print("── ⑤b 齐射分配：第 i 剑掷第 i 近敌；不足 ±4°/剑 扇出（非隐形单体倍伤） ──")
	_clear_enemies()
	_strip_traits()
	var ok_l1: bool = _w.attach_trait(_gl.registry.get_trait(&"MEC_ORBIT_LINK"))
	var ok_l2: bool = _w.attach_trait(_gl.registry.get_trait(&"MEC_ORBIT_LINK"))
	# 目标足额：三敌按距离升序三角分布（200 / 250.6 / 277.8px，方位互异）
	var ea := _spawn_e(Vector2(360.0, 440.0))    # 正上 200px（最近）
	var eb := _spawn_e(Vector2(140.0, 520.0))    # 左上 250.6px（次近）
	var ec := _spawn_e(Vector2(600.0, 500.0))    # 右上 277.8px（第三）
	var fired: bool = _w.try_fire()
	var swords := _my_swords()
	if not ok_l1 or not ok_l2 or not fired or swords.size() != 3:
		_check("⑤b 三敌三剑逐位分敌（前置：3 剑在场）", false,
			"l=%s/%s fired=%s n=%d" % [str(ok_l1), str(ok_l2), str(fired), swords.size()])
		_release_my_swords()
		_clear_enemies()
		_strip_traits()
		return
	var c := _w.muzzle_position()                 # 二cu 合一：分配方向基准=化身出膛口
	# 期望序按化身出膛口动态重排（二cu：出膛口随化身环位，与武器本体位的距离序可异位）
	var sorted_t: Array[Vector2] = [ea.global_position, eb.global_position, ec.global_position]
	sorted_t.sort_custom(func(a: Vector2, b: Vector2) -> bool:
		return c.distance_squared_to(a) < c.distance_squared_to(b))
	var in_order := true
	var distinct := true
	for i in range(3):
		var v: Vector2 = (swords[i] as ProjectileBase).velocity.normalized()
		if v.dot(((sorted_t[i] - c).normalized())) <= 0.999:
			in_order = false                     # 第 i 剑未指向第 i 近敌
		for j in range(3):
			if j != i and absf(rad_to_deg(v.angle_to(
					(swords[j] as ProjectileBase).velocity.normalized()))) < 0.5:
				distinct = false                 # 方向互异（≥0.5° 分离）
	_check("⑤b 三剑各指一个不同敌（第 i 剑 → 第 i 近敌逐位命中 + 方向互异 ≥0.5°）",
		in_order and distinct, "order=%s distinct=%s" % [str(in_order), str(distinct)])
	_release_my_swords()
	_clear_enemies()
	# 目标不足：无目标扇出兜底（slot 0 贴 aim 基向 UP，档位 +4°/-4°）
	_w.try_fire()
	swords = _my_swords()
	var fan_ok := swords.size() == 3
	if fan_ok:
		var expect := [0.0, 4.0, -4.0]
		for i in range(swords.size()):
			var ang := rad_to_deg(Vector2.UP.angle_to(
				(swords[i] as ProjectileBase).velocity.normalized()))
			if absf(ang - float(expect[i])) > 0.5:
				fan_ok = false
	_check("⑤b 无目标扇出兜底：3 剑角 {0°,+4°,-4°}（±SLOT_FAN_DEG/剑，slot 0 贴 aim）",
		fan_ok, "n=%d ok=%s" % [swords.size(), str(fan_ok)])
	_release_my_swords()
	_strip_traits()


# ── ⑦ 质变挂点 pre-w4 守卫 + ⑧ FRACTAL 子代 ──────────────────────
func _case6_transcend_guard_and_fractal() -> void:
	print("── ⑦ 质变挂点 pre-w4 守卫（单剑）+ ⑧ FRACTAL 子代 flight_sword ──")
	_clear_enemies()
	var tc: Dictionary = _w.data.melee.get("transcend", {})
	_check("⑦pre-w4 守卫：transcend 占位在册（volley 3.0）但 volley/fan 不提前生效",
		is_equal_approx(float(tc.get("volley", 0.0)), 3.0)
		and int(_w._sword_volley_count()) == 1 and is_equal_approx(float(_w._sword_fan_deg()), 0.0),
		"volley=%d fan=%s" % [int(_w._sword_volley_count()), str(_w._sword_fan_deg())])
	_w.try_fire()
	var n := _my_swords().size()
	_check("⑦实弹单剑（w4 未落地=transcended 键缺位）", n == 1, "n=%d" % n)
	_release_my_swords()
	_strip_traits()
	# ⑧ 分裂子代：挂 MEC_FRACTAL → 母弹回收（nullify）→ 子代迷你飞剑
	var ok_f: bool = _w.attach_trait(_gl.registry.get_trait(&"MEC_FRACTAL"))
	_w.try_fire()
	var mothers := _my_swords()
	if not ok_f or mothers.is_empty():
		_check("⑧FRACTAL 子代前置", false, "ok=%s n=%d" % [str(ok_f), str(mothers.size())])
		return
	var mother := mothers[0]
	var mv := mother.velocity
	mother.nullify()                             # → ON_EXPIRE → split_request → request_split
	var children := _my_swords(1)
	_check("⑧母弹回收裂出恰 2 枚子代（MEC_FRACTAL 1 层 2 枚）", children.size() == 2,
		"n=%d" % children.size())
	var form_ok := true
	var angle_ok := true
	var inherit_ok := true
	for ch in children:
		if not bool(ch.get("_flight_sword")):
			form_ok = false
		var ang := absf(rad_to_deg(mv.angle_to(ch.velocity)))
		if absf(ang - 28.0) > 1.5:
			angle_ok = false
		if absf(float(ch.panel_snapshot.get("base_atk", 0.0)) - 24.0 * 0.7) > 0.05:
			inherit_ok = false                    # 二ct：分裂恒继承 70%
	_check("⑧子代 flight_sword==true（迷你飞剑——w1 request_split 分支承载）", form_ok)
	_check("⑧子代速度旋转 ±28°（tol 1.5°）+ 面板 ATK×0.7（16.8，二ct）", angle_ok and inherit_ok,
		"angle=%s inherit=%s" % [str(angle_ok), str(inherit_ok)])
	_release_my_swords()
	_strip_traits()


# ── ⑥ 图标 static func ───────────────────────────────────────────
func _case7_icon() -> void:
	print("── ⑥ 图标 weapon_icon_tex：56px 朝上竖剑；默认银蓝/质变鎏金互异 ──")
	var tex_a: ImageTexture = FlyingSwordWeapon.weapon_icon_tex(false)
	var tex_b: ImageTexture = FlyingSwordWeapon.weapon_icon_tex(true)
	_check("⑥默认/质变图标非空 ImageTexture 且 56×56（画布朝上 -Y 口径）",
		tex_a != null and tex_b != null
		and tex_a.get_size() == Vector2(56.0, 56.0)
		and tex_b.get_size() == Vector2(56.0, 56.0),
		"a=%s b=%s" % [str(tex_a != null), str(tex_b != null)])
	var data_diff := tex_a != tex_b
	if tex_a != null and tex_b != null:
		var img_a: Image = tex_a.get_image()
		var img_b: Image = tex_b.get_image()
		if img_a != null and img_b != null and img_a.get_data().size() > 0 \
				and img_b.get_data().size() > 0:
			data_diff = img_a.get_data() != img_b.get_data()
	_check("⑥质变鎏金与默认银蓝图像互异（逐像素数据比对）", data_diff)

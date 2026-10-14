# tests/runner/r243_liedifu_cases.gd
# R243 法器·裂地斧（w2-liedifu）用例体（入口运行时 load——cases 禁 test_ 前缀防电池 glob 误收；
# -s 对非 MainLoop 脚本会挂起——前缀化 cases 文件会让 _batt_r215.py glob 误收后死挂）。
# 覆盖（设计 §9.1 talisman ④⑤⑥⑦ + 任务验收 ①~⑩）：
# ① 每拍掷斧（cd 3.6 通道）→ 最近敌位置快照 target_point（640px/s）+ spawn 键集 +
#    幽灵飞行途中敌不掉血（贴斧 toucher 桩）+ 目标中途死亡不重锁 + 抵达 FORCED 回收
# ② 落地震荡：半径内全额（面板终值 56）+ 窄相精判外不掉（粗相候选内 dist>R+hitbox 拒）+
#    幂等 _shock_uid / shock_scale 读回
# ③ 落点清弹：预置 3 敌弹全 nullified（帽 24/次先例）
# ④ MEC_HIT_BURST 挂上后震荡 ON_HIT 派发迸裂计数（空栈 = inert 由①无词条路径覆盖）
# ⑤ GroundShockFx：z_index=2 / 半径读回 / 0.35s 生命销毁（手驱 + 真帧流双证）
# ⑥ L5 面板 96/2.8 读回（cd 3.6→2.8 通道）+ 震荡半径双断言：默认形态表顶 128 /
#    质变 160（R243 有意契约变更——w2 波 128 为质变前裸表值，w4 波崩山击 ×1.25）
# ⑦ FRACTAL 子斧：落地碎裂 2 枚（flight_axe 继承/generation=3 封堵/shock_scale=0.4/
#    面板 22.4/target_point=母落点+出射方向×120）→ 二次迷你震荡（38.4）+ 代数闸拒绝计数
# ⑧ 数量挂点：ORBIT_LINK 1 层斧群 2、第 i 斧掷第 i 近敌、不足重叠首目标 ±20° 错位
# ⑨ 击退：径向 100%（knock_vel≈80×9 径向）+ MEC_KNOCK 平加池消费（MEC_KNOCK 消费点反死卡）
# ⑩ 图标：static func weapon_icon_tex(false/true) 非空 56×56 两版分立
# ⑪ 套件总项数断言（R231 假绿教训）
# 确定性：GameLoop 夹具（w8_charge 同款）+ 静止敌 + crit=0 副本数据 + 帧戳手动推进。
# 已知共享面备注：texture_factory.gd:1549 has_static_method 非 GDScript API（w1 交付面缺陷，
# 委托臂恒异常回落占位）——本套件只断本脚本 static 直出（共享文件缺陷另行登记，勿硬编码绿）。
extends RefCounted

const EXPECTED_TOTAL := 32                     # ⑥ 迁移双断言 +1（R243：默认 128/质变 160）
const DT := 1.0 / 60.0
const MAIN_SCENE := "res://scenes/main.tscn"
const PLAYER_POS := Vector2(360.0, 640.0)     # 居中（几何确定性；全部坐标离屏界内）

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(20261008)
	_boot_game_loop()
	_case1_fire_ghost()
	_case2_shock_narrow()
	_case3_clear_bullets()
	_case4_hit_burst_fx()
	await _case5_fx_lifetime()                     # 含 await——必须挂起等真帧流用例
	_case6_l5_panel()
	_case7_fractal_children()
	_case8_axe_count()
	_case9_knockback()
	_case10_icon()
	_teardown_game_loop()
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


# ── 夹具（w8_charge_cases 同款 GameLoop 桩） ──────────────────────
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
	_gl.player.set("unlocked_slots", 5)
	_gl.player.global_position = PLAYER_POS


func _teardown_game_loop() -> void:
	tree.paused = false
	RunSave.clear()
	if _gl != null:
		_gl.free()
		_gl = null


func _fresh_axe() -> GroundAxeWeapon:
	# 拆旧 W12 → 清场 → 新装（crit=0 副本数据 + meta 修正归零——伤害确定性）；
	# 玩家位置回锚（真帧流用例期间仿真在跑——玩家会漂移，几何用例需确定锚）
	for i in range(_gl.player.weapon_slots.size()):
		var w = _gl.player.weapon_slots[i]
		if w != null and is_instance_valid(w) and w.data != null \
				and String(w.data.id).begins_with("W12"):
			_gl.player.weapon_slots[i] = null
			w.free()
	_gl.player.global_position = PLAYER_POS
	_clear_enemies()
	var axe: GroundAxeWeapon = _gl.player.add_weapon(
		_gl.registry.get_weapon(&"W12_ground_axe")) as GroundAxeWeapon
	if axe != null:
		axe.data = axe.data.duplicate(true)
		axe.data.crit_rate = 0.0
		axe.meta_atk_pct = 0.0
		axe.call("_invalidate_panel")
	return axe


func _spawn_e(p_pos: Vector2, p_hp: float = 100000.0) -> Enemy:
	var enemy := (_gl.pools[&"enemy"] as EnemyPool).acquire()
	enemy.spawn(_gl.registry.get_enemy(&"E1_grunt"), 1, 0)
	enemy.set("speed", 0.0)
	enemy.set("max_hp", p_hp)
	enemy.set("hp", p_hp)
	enemy.global_position = p_pos
	_gl.spawner.active.append(enemy)
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	return enemy


func _clear_enemies() -> void:
	for e in _gl.spawner.active.duplicate():
		_gl.spawner.active.erase(e)
		(_gl.pools[&"enemy"] as EnemyPool).release(e)
	_gl.enemy_grid.rebuild(_gl.spawner.active)


func _spawn_enemy_bullet(p_pos: Vector2) -> ProjectileBase:
	var b := (_gl.pools[&"projectile"] as ProjectilePool).acquire()
	b.spawn({
		"position": p_pos,
		"velocity": Vector2(20.0, 0.0),
		"lifetime": 10.0,
		"pierce": 1,
		"team": 1,
	})
	return b


func _bump() -> void:
	GameConfig.frame_stamp += 1                    # E-03 帧闸门推进


func _fire_axe(p_axe: GroundAxeWeapon) -> void:
	p_axe.cooldown_left = 0.0
	_bump()
	p_axe.tick(DT)                                 # 冷却就绪 + 有敌 → 掷斧


func _axes_live() -> Array:                       # 活跃掷斧弹（flight_axe 且 live）
	var out: Array = []
	for p in (_gl.pools[&"projectile"] as ProjectilePool).active_projectiles():
		if is_instance_valid(p) and p is ProjectileBase \
				and bool((p as ProjectileBase).get("_flight_axe")) \
				and bool((p as ProjectileBase).get("_live")):
			out.append(p)
	return out


func _run_axes_to_completion(p_max_iters: int = 300) -> void:
	for i in range(p_max_iters):
		var axes := _axes_live()
		if axes.is_empty():
			return
		_bump()
		for a in axes:
			if is_instance_valid(a):
				(a as ProjectileBase).tick(DT)


func _trait_value_of(p_axe: GroundAxeWeapon, p_id: StringName) -> float:
	if p_axe.trait_stack == null:
		return 0.0
	for tb in p_axe.trait_stack.traits:
		if tb.data != null and tb.data.id == p_id:
			return float(tb.data.value)
	return 0.0


# ── ① 掷斧键集 + 幽灵飞行 + 不重锁 + 抵达回收 ────────────────────
func _case1_fire_ghost() -> void:
	print("── ① 掷斧 spawn 键集 / 幽灵飞行 / 落点不重锁 / 抵达 FORCED 回收 ──")
	var axe := _fresh_axe()
	var target := _spawn_e(Vector2(560.0, 640.0))
	_check("①工厂分派接管：add_weapon(W12) 实例 = GroundAxeWeapon", axe != null,
		str(axe))
	if axe == null:
		return
	_fire_axe(axe)
	var axes := _axes_live()
	var cd_ok := absf(axe.cooldown_left - 3.6) < 0.01 \
		and absf(axe.cooldown_left - axe._fire_interval()) < 0.0001
	_check("①每拍掷斧（cd 3.6 通道）：恰 1 枚 live 斧 + cooldown=_fire_interval=3.6",
		axes.size() == 1 and cd_ok,
		"axes=%d cd=%.4f interval=%.4f" % [axes.size(), axe.cooldown_left,
		axe._fire_interval()])
	if axes.is_empty():
		return
	var p: ProjectileBase = axes[0]
	var tp: Vector2 = p.get("_target_point")
	var keys_ok := bool(p.get("_flight_axe")) \
		and tp.distance_to(target.global_position) < 0.5 \
		and is_equal_approx(float(p.get("_shock_scale")), 1.0) \
		and int(p.get("generation")) == 0 \
		and absf(p.velocity.length() - 640.0) < 0.0001 \
		and p.weapon_ref == axe \
		and is_equal_approx(float(p.get("_panel_base_atk")), 56.0) \
		and p.team == 0 and p.pierce_left == 1
	_check("①spawn 键集：flight_axe/target_point=敌位快照/shock_scale 1.0/gen0/速 640/weapon_ref/面板 56/team0",
		keys_ok, "tp=%s vel=%.2f" % [str(tp), p.velocity.length()])
	# 幽灵飞行：toucher 敌逐 tick 贴斧位（若碰撞通道未跳过必吃接触伤）
	var toucher := _spawn_e(Vector2(150.0, 150.0))
	toucher.hp = 50000.0
	var toucher_hp0 := float(toucher.hp)
	var mid_ticks := 0
	for i in range(12):
		if not bool(p.get("_live")):
			break
		toucher.global_position = p.global_position    # 贴斧（命中域 12+14=26px 内）
		_bump()
		p.tick(DT)
		mid_ticks += 1
	_check("①幽灵飞行：途中 %d tick 贴斧敌零接触伤（hp 不变）" % mid_ticks,
		mid_ticks >= 8 and is_equal_approx(float(toucher.hp), toucher_hp0),
		"ticks=%d hp=%s→%s" % [mid_ticks, str(toucher_hp0), str(toucher.hp)])
	# 目标中途死亡不重锁：target_point 保持发射快照，斧仍落原点
	toucher.global_position = Vector2(150.0, 150.0)   # 撤离落点域
	target.hp = 0.0
	target.set("dead", true)
	var land0: int = DebugStats.get_counter(&"axe_landings")
	_run_axes_to_completion()
	var land_delta: int = DebugStats.get_counter(&"axe_landings") - land0
	var land_pos: Vector2 = axe.last_land_pos
	_check("①目标中途死亡不重锁：落地 ≈ 原快照落点（≤26px）+ landings Δ1 + FORCED 回收",
		land_delta == 1 and land_pos.distance_to(Vector2(560.0, 640.0)) <= 26.0
		and not bool(p.get("_live")) and bool(p.get("is_clean")),
		"land=%s Δ%d live=%s" % [str(land_pos), land_delta, str(p.get("_live"))])
	_check("①目标已亡震荡零目标（dead 短路）+ toucher 全程 hp 不变",
		DebugStats.get_counter(&"axe_shock_targets") == 0
		and is_equal_approx(float(toucher.hp), toucher_hp0),
		"targets=%d toucher=%s" % [DebugStats.get_counter(&"axe_shock_targets"),
		str(toucher.hp)])


# ── ② 落地震荡全额 + 窄相精判 ────────────────────────────────────
func _case2_shock_narrow() -> void:
	print("── ② 落地震荡：半径内全额 / 窄相精判外不掉 / shock_scale 读回 ──")
	var axe := _fresh_axe()
	var a := _spawn_e(Vector2(560.0, 640.0))          # 目标 = 震荡心（dist≈0）
	var b := _spawn_e(Vector2(700.0, 640.0))          # 距落地 ≥140 > 96+14（窄相外）
	var hp_a0 := float(a.hp)
	var hp_b0 := float(b.hp)
	_fire_axe(axe)
	_run_axes_to_completion()
	var dmg_ok := absf((hp_a0 - float(a.hp)) - 56.0) < 0.6
	_check("②震荡半径内全额：A 落血恰 56（面板终值，无衰减）+ targets Δ1",
		dmg_ok and DebugStats.get_counter(&"axe_shock_targets") == 1,
		"Δhp=%s targets=%d" % [str(hp_a0 - float(a.hp)),
		DebugStats.get_counter(&"axe_shock_targets")])
	_check("②窄相精判外不掉：B（粗相候选域内 dist>R+hitbox）hp 不变",
		is_equal_approx(float(b.hp), hp_b0),
		"Δhp=%s" % str(hp_b0 - float(b.hp)))
	_check("②落地读回：R_shock=96×scale1.0（_shock_uid 每落地新签非零）",
		absf(axe.last_land_shock_radius - 96.0) < 0.01
		and is_equal_approx(axe.last_land_shock_scale, 1.0) and axe._shock_uid != 0,
		"R=%.3f scale=%.3f uid=%d" % [axe.last_land_shock_radius,
		axe.last_land_shock_scale, axe._shock_uid])
	# 直调窄相对（确定性圆心）：粗相 query_circle(pos,96) 精判 reach=96+64=160 →
	# dist 100（≤96+14）命中、dist 120（>110）拒——窄相为 AoE 半径口径真值
	var n1 := _spawn_e(Vector2(500.0, 200.0))
	var n2 := _spawn_e(Vector2(520.0, 200.0))
	var n1_hp0 := float(n1.hp)
	var n2_hp0 := float(n2.hp)
	axe._shock_uid = GameConst.next_uid()
	axe._settle_shock(Vector2(400.0, 200.0), 96.0, 50.0)
	_check("②窄相分界直调：dist100（≤R+hitbox）落血 50 / dist120（粗相 160 内）不掉",
		absf((n1_hp0 - float(n1.hp)) - 50.0) < 0.6
		and is_equal_approx(float(n2.hp), n2_hp0),
		"n1Δ=%s n2Δ=%s" % [str(n1_hp0 - float(n1.hp)), str(n2_hp0 - float(n2.hp))])


# ── ③ 落点清弹 ───────────────────────────────────────────────────
func _case3_clear_bullets() -> void:
	print("── ③ 落点清弹（法器 100% 确定性，震荡半径内全 nullified） ──")
	var axe := _fresh_axe()
	_spawn_e(Vector2(560.0, 640.0))
	var bullets: Array = []
	for pos in [Vector2(520.0, 640.0), Vector2(560.0, 600.0), Vector2(580.0, 680.0)]:
		bullets.append(_spawn_enemy_bullet(pos))
	var items: Array[Node2D] = []
	for b in bullets:
		items.append(b)
	_gl.enemy_bullet_grid.rebuild(items)
	_fire_axe(axe)
	_run_axes_to_completion()
	var all_dead := true
	for b in bullets:
		if bool((b as ProjectileBase).get("_live")) \
				or not bool((b as ProjectileBase).get("is_clean")):
			all_dead = false
	_check("③预置 3 敌弹全 nullified（live=false + is_clean）+ 清弹计数恰 Δ3",
		all_dead and DebugStats.get_counter(&"axe_bullets_cleared") == 3,
		"cleared=%d" % DebugStats.get_counter(&"axe_bullets_cleared"))


# ── ④ MEC_HIT_BURST 震荡迸裂 + fx 读回 ───────────────────────────
func _case4_hit_burst_fx() -> void:
	print("── ④ 震荡 ON_HIT 派发（MEC_HIT_BURST 迸裂计数）+ GroundShockFx 读回 ──")
	var axe := _fresh_axe()
	# 空栈 inert 旁证（真断言）：①②③已跑完整震荡链且无迸裂卡——迸裂计数应仍为 0
	_check("④空栈震荡 inert：①②③震荡链跑毕 hit_burst_triggered 恒 0（无卡不派发迸裂）",
		DebugStats.get_counter(&"hit_burst_triggered") == 0,
		"burst=%d" % DebugStats.get_counter(&"hit_burst_triggered"))
	var burst_ok: bool = axe.attach_trait(_gl.registry.get_trait(&"MEC_HIT_BURST"))
	var p1 := _spawn_e(Vector2(560.0, 640.0))
	var p2 := _spawn_e(Vector2(620.0, 640.0))         # 相距 60 ≤ 迸裂 80+14
	var burst0: int = DebugStats.get_counter(&"hit_burst_triggered")
	var tgt0: int = DebugStats.get_counter(&"axe_shock_targets")
	_fire_axe(axe)
	_run_axes_to_completion()
	var burst_delta: int = DebugStats.get_counter(&"hit_burst_triggered") - burst0
	# 双目标同帧结算：TraitBase.can_trigger 单帧单次闸（trait_base.gd:75）收敛为 Δ1——
	# 迸裂自 0→1 即证震荡 ON_HIT 派发链通（空栈 inert 已由前置断言背书）
	_check("④MEC_HIT_BURST 挂上：震荡 ON_HIT → 迸裂计数触发（同帧双目标经单帧 ICD 收敛 Δ1）+ targets Δ2",
		burst_ok and burst_delta == 1
		and DebugStats.get_counter(&"axe_shock_targets") - tgt0 == 2,
		"burstΔ=%d targetsΔ=%d" % [burst_delta,
		DebugStats.get_counter(&"axe_shock_targets") - tgt0])
	var fx := axe.last_fx
	_check("④GroundShockFx 读回：非空 + z_index=2 + 半径=96（shock_scale 缩放入厂）",
		fx != null and is_instance_valid(fx) and fx.z_index == 2
		and absf(fx.shock_radius - 96.0) < 0.01,
		"fx=%s z=%s r=%s" % [str(fx != null), str(fx.z_index if fx != null else -1),
		str(fx.shock_radius if fx != null else -1.0)])


# ── ⑤ 特效 0.35s 生命销毁 ────────────────────────────────────────
func _case5_fx_lifetime() -> void:
	print("── ⑤ GroundShockFx 0.35s 生命销毁（手驱 + 真帧流） ──")
	var axe := _fresh_axe()
	_spawn_e(Vector2(560.0, 640.0))
	_fire_axe(axe)
	_run_axes_to_completion()
	var fx := axe.last_fx
	var fx_ready := fx != null and is_instance_valid(fx)
	_check("⑤前置：落地特效节点在树", fx_ready, "last_fx=%s" % str(fx))
	if not fx_ready:
		return
	fx._process(0.4)                               # 手驱越 0.35s 生命线 → R253 归还池
	await tree.process_frame
	_check("⑤手驱 0.4s：归还池（隐藏+停处理——FX_LIFE=0.35 寿命口径不变，R253 池化）",
		is_instance_valid(fx) and not fx.visible and not fx.is_processing(),
		"valid=%s visible=%s processing=%s" % [str(is_instance_valid(fx)),
		str(fx.visible), str(fx.is_processing())])
	# 真帧流：新落地特效自然老化销毁
	_clear_enemies()
	_spawn_e(Vector2(560.0, 640.0))
	_fire_axe(axe)
	_run_axes_to_completion()
	var fx2 := axe.last_fx
	var fx2_was := fx2 != null and is_instance_valid(fx2)   # Godot4 释放件 ==null——先录在树位
	var deadline := Time.get_ticks_msec() + 2500
	while fx2_was and fx2 != null and is_instance_valid(fx2) and fx2.visible \
			and Time.get_ticks_msec() < deadline:
		await tree.process_frame
	_check("⑤真帧流 0.35s 自然归还（2.5s 预算内隐藏+停处理，R253 池化）",
		fx2_was and fx2 != null and is_instance_valid(fx2) and not fx2.visible,
		"was=%s now_valid=%s land=%d live=%d lastland=%s" % [str(fx2_was),
		str(fx2.visible if fx2 != null else null), axe.land_count,
		_axes_live().size(), str(axe.last_land_pos)])


# ── ⑥ L5 面板读回 ────────────────────────────────────────────────
func _case6_l5_panel() -> void:
	print("── ⑥ L5 面板 96/2.8 读回 + 震荡半径默认 128/质变 160（R243 迁移） ──")
	var axe := _fresh_axe()
	_check("⑥L1 基线：_shock_radius=96 / _fire_interval=3.6（cd 通道）",
		absf(axe._shock_radius() - 96.0) < 0.01
		and absf(axe._fire_interval() - 3.6) < 0.01,
		"R=%.3f cd=%.4f" % [axe._shock_radius(), axe._fire_interval()])
	for i in range(4):
		axe.level_up()
	_check("⑥L5 读回：base_atk 96 / cd 2.8 / 面板 96",
		axe.level == 5 and is_equal_approx(axe.get_stat(&"base_atk"), 96.0)
		and is_equal_approx(axe.get_stat(&"cd"), 2.8)
		and is_equal_approx(float(axe.build_panel_snapshot().get("base_atk", 0.0)), 96.0),
		"lv=%d atk=%s cd=%s" % [axe.level, str(axe.get_stat(&"base_atk")),
		str(axe.get_stat(&"cd"))])
	# R243 有意契约变更：w2 波 128 为质变前裸表值，w4 波质变「崩山击」×1.25 后为 160
	#（level_up 抵 L5 即置位 transcended——weapon_base 质变置位链；radius_mult 尾乘
	# ground_axe_weapon._shock_radius）
	_check("⑥L5 质变震荡半径 128×1.25=160（R243 有意契约变更：w2 波 128 为质变前裸表值，w4 质变 ×1.25 → 160）",
		bool(axe.transcended) and absf(axe._shock_radius() - 160.0) < 0.01,
		"R=%.3f t2=%s" % [axe._shock_radius(), str(axe.transcended)])
	# 默认形态对照（未质变直置探针——w5 直置等级先例）：表顶裸值 128 + 表内证人
	var axe_p := GroundAxeWeapon.new()
	axe_p.data = (_gl.registry.get_weapon(&"W12_ground_axe") as WeaponData).duplicate(true)
	axe_p.level = 5
	axe_p.transcended = false
	_check("⑥默认形态（未质变）震荡半径表顶 128（shock_radius_levels[5] 裸值，无词条零乘区）",
		absf(float(axe_p.data.melee["shock_radius_levels"][4]) - 128.0) < 0.01
			and absf(axe_p._shock_radius() - 128.0) < 0.01,
		"R=%.3f" % axe_p._shock_radius())
	axe_p.free()


# ── ⑦ FRACTAL 子斧 ───────────────────────────────────────────────
func _case7_fractal_children() -> void:
	print("── ⑦ W12×FRACTAL：母斧落地碎裂子斧 → 二次迷你震荡 → 代数闸封堵 ──")
	var axe := _fresh_axe()
	var fractal_ok: bool = axe.attach_trait(_gl.registry.get_trait(&"MEC_FRACTAL"))
	_spawn_e(Vector2(560.0, 640.0))
	_fire_axe(axe)
	# 母斧单弹推进至落地即停（land_count=1）——子斧落地另段驱动
	var guard := 0
	while guard < 300 and int(axe.land_count) == 0:
		var flying := _axes_live()
		if flying.is_empty():
			break
		_bump()
		for a in flying:
			(a as ProjectileBase).tick(DT)
		guard += 1
	var mother_land: Vector2 = axe.last_land_pos
	var children := _axes_live()
	var child_ok := children.size() == 2
	var child_tp_ok := children.size() == 2
	var child_tp_detail := ""
	for c in children:
		var cp: ProjectileBase = c
		if not (bool(cp.get("_flight_axe")) and int(cp.get("generation")) == 3
				and is_equal_approx(float(cp.get("_shock_scale")), 0.7)   # 二ct：恒 70%
				and absf(float(cp.get("_panel_base_atk")) - 39.2) < 0.01):
			child_ok = false                       # 二ct：56 面板 ×0.7 = 39.2
		var ctp: Vector2 = cp.get("_target_point")
		if ctp.distance_to(mother_land) < 118.0 or ctp.distance_to(mother_land) > 122.0:
			child_tp_ok = false                    # 落点 = 母落点 + 出射方向 ×120
		child_tp_detail += "%.0fpx " % ctp.distance_to(mother_land)
	_check("⑦母斧落地碎裂 2 子斧：flight_axe 继承 + generation=3 封堵 + shock_scale=0.7 + 面板 39.2（二ct）",
		fractal_ok and child_ok and int(axe.land_count) == 1,
		"n=%d land=%s" % [children.size(), str(axe.land_count)])
	_check("⑦子斧 target_point = 母落点 + 出射方向 ×120（tol 2px）",
		child_tp_ok, "距母落点=%s" % child_tp_detail)
	var land0: int = DebugStats.get_counter(&"axe_landings")
	var rej0: int = DebugStats.get_counter(&"split_rejected_generation")
	_run_axes_to_completion()                      # 子斧落地 → 二次迷你震荡
	var land_delta: int = DebugStats.get_counter(&"axe_landings") - land0
	var rej_delta: int = DebugStats.get_counter(&"split_rejected_generation") - rej0
	_check("⑦子斧落地二次迷你震荡：landings Δ2 + R=96×0.7=67.2（二ct）+ scale 0.7 读回 + fx 同径",
		land_delta == 2 and absf(axe.last_land_shock_radius - 67.2) < 0.01
		and is_equal_approx(axe.last_land_shock_scale, 0.7)
		and axe.last_fx != null and absf(axe.last_fx.shock_radius - 67.2) < 0.01,
		"Δland=%d R=%.3f scale=%.3f" % [land_delta, axe.last_land_shock_radius,
		axe.last_land_shock_scale])
	_check("⑦代数闸封堵：子斧再裂 split_rejected_generation Δ2 + 无 gen2 子斧残留",
		rej_delta == 2 and _axes_live().is_empty() and int(axe.land_count) == 3,
		"rejΔ=%d live=%d land_count=%d" % [rej_delta, _axes_live().size(),
		axe.land_count])


# ── ⑧ 数量挂点 ───────────────────────────────────────────────────
func _case8_axe_count() -> void:
	print("── ⑧ 数量挂点：ORBIT_LINK 斧群帽 + 第 i 斧掷第 i 近敌 + ±20° 错位 ──")
	var axe := _fresh_axe()
	var link_ok: bool = axe.attach_trait(_gl.registry.get_trait(&"MEC_ORBIT_LINK"))
	_check("⑧ORBIT_LINK 1 层（value 1.45→+1）：_orbit_link_count=1 → 斧群 2（1+min(1,3)）",
		link_ok and axe._orbit_link_count() == 1 and axe.axe_count() == 2,
		"link=%s knives=%d count=%d" % [str(link_ok), axe._orbit_link_count(),
		axe.axe_count()])
	var near := _spawn_e(Vector2(460.0, 640.0))
	var far := _spawn_e(Vector2(660.0, 640.0))
	_fire_axe(axe)
	var axes := _axes_live()
	var tp_ok := axes.size() == 2
	var near_tp := Vector2.ZERO
	var far_tp := Vector2.ZERO
	for a in axes:
		var tp: Vector2 = (a as ProjectileBase).get("_target_point")
		if tp.distance_to(near.global_position) < 0.5:
			near_tp = tp
		elif tp.distance_to(far.global_position) < 0.5:
			far_tp = tp
	tp_ok = tp_ok and near_tp != Vector2.ZERO and far_tp != Vector2.ZERO
	_check("⑧第 i 斧掷第 i 近敌：两斧 target_point 分别对位近/远敌位置快照",
		tp_ok, "axes=%d near=%s far=%s" % [axes.size(), str(near_tp), str(far_tp)])
	_run_axes_to_completion()
	# 不足重叠：单敌 + 斧群 2 → 第二斧 ±20° 错位（等距、角差 20°）
	_clear_enemies()
	var solo := _spawn_e(Vector2(560.0, 640.0))
	_fire_axe(axe)
	axes = _axes_live()
	var overlap_ok := axes.size() == 2
	var overlap_detail := "axes=%d" % axes.size()
	if overlap_ok:
		var origin: Vector2 = axe.muzzle_position()           # 二cu 合一：出掷真源 = 化身出膛口
		var primary: Vector2 = (axes[0] as ProjectileBase).get("_target_point")
		var extra: Vector2 = (axes[1] as ProjectileBase).get("_target_point")
		var base_dir: Vector2 = solo.global_position - origin
		var extra_dir: Vector2 = extra - origin
		var ang := absf(rad_to_deg(wrapf(extra_dir.angle() - base_dir.angle(), -PI, PI)))
		overlap_ok = primary.distance_to(solo.global_position) < 0.5 \
			and absf(ang - 20.0) < 0.6 \
			and absf(extra_dir.length() - base_dir.length()) < 0.6
		overlap_detail = "pri=%s solo=%s extra=%s ang=%.2f len=%.1f/%.1f" % [
			str(primary), str(solo.global_position), str(extra), ang,
			extra_dir.length(), base_dir.length()]
	_check("⑧不足重叠首目标 ±20° 错位：主斧对位 + 副斧等距角差 20°",
		overlap_ok, overlap_detail)
	_run_axes_to_completion()


# ── ⑨ 击退（MEC_KNOCK 消费点） ───────────────────────────────────
func _case9_knockback() -> void:
	print("── ⑨ 落点震荡径向击退（melee.knockback 80）+ MEC_KNOCK 平加池 ──")
	var axe := _fresh_axe()
	var k := _spawn_e(Vector2(560.0, 640.0))
	_fire_axe(axe)
	_run_axes_to_completion()
	var kv: Vector2 = k.get("knock_vel")
	var radial: Vector2 = (k.global_position - axe.last_land_pos).normalized()
	_check("⑨径向击退：knock_vel ≈ 80×9=720 且方向 = 落点→目标心（径向 100%/切向 0）",
		absf(kv.length() - 720.0) < 1.0 and kv.normalized().dot(radial) > 0.99,
		"|kv|=%.2f dot=%.4f" % [kv.length(),
		kv.normalized().dot(radial) if kv.length() > 0.01 else -1.0])
	var kb0 := axe._axe_knockback()
	var knock_ok: bool = axe.attach_trait(_gl.registry.get_trait(&"MEC_KNOCK"))
	var card_v := _trait_value_of(axe, &"MEC_KNOCK")
	var kb1 := axe._axe_knockback()
	_check("⑨MEC_KNOCK 平加池消费：基线 80 → 80+value（MEC_KNOCK 对 W12 实测有效——反死卡）",
		knock_ok and absf(kb0 - 80.0) < 0.01 and card_v > 0.0
		and absf(kb1 - (80.0 + card_v)) < 0.01,
		"kb0=%.2f card=%.2f kb1=%.2f" % [kb0, card_v, kb1])


# ── ⑩ 图标 static func ──────────────────────────────────────────
func _case10_icon() -> void:
	print("── ⑩ weapon_icon_tex(false/true)：56px 朝上 -Y 双形态 ──")
	var tex0 := GroundAxeWeapon.weapon_icon_tex(false)
	var tex1 := GroundAxeWeapon.weapon_icon_tex(true)
	var tex0b := GroundAxeWeapon.weapon_icon_tex(false)     # 缓存幂等
	_check("⑩图标 static：默认/质变两版非空 56×56 + 缓存幂等 + 两版分立",
		tex0 != null and tex1 != null
		and tex0.get_size() == Vector2(56, 56)
		and tex1.get_size() == Vector2(56, 56)
		and tex0 == tex0b and tex0 != tex1,
		"t0=%s t1=%s size=%s" % [str(tex0 != null), str(tex1 != null),
		str(tex0.get_size() if tex0 != null else Vector2.ZERO)])

# tests/runner/pkg7_extra_cases.gd
# v0.7.0 验收补漏用例体（由 test_pkg7_extra.gd 入口在 autoload 就绪后运行时加载编译）。
# 定位：pkg7_cases.gd 已覆盖 A6 主干断言；本文件只补 pkg7 未覆盖的验收点
#（引用观测口：ParticleDirector.burst_requests / BossBar.is_visible_bar/displayed_pct /
#  Enemy.ring_visible/ring_progress / Enemy.ElementRing.RING_COLORS / WaveDirector.gold_rush_remaining_ratio）。
# 确定性：固定 RNG 种子（金币 4242 批内重播 / ChipHandler 91 / 管线 777）。
extends RefCounted

const DT := 1.0 / 120.0                          # 120Hz 物理帧

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null                         # 共享 GameLoop（Boot 一次）


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_ensure_autoloads()
	_boot_game_loop()
	_test_u1_validator_idempotent()               # U1 重复扫描幂等
	_test_u3_chip_quota_superset()                # U3 芯片不占乘区 top-8 名额
	_test_u3_joint_hand_calc()                    # U3 joint 公式手算对照
	_test_u3_chip_reset_baseline()                # U3 拔芯片（reset）回基线
	_test_u3_clamp_retained()                     # U3 射速 30 / 暴击 1.0 钳保留
	_test_u8_ring_colors_decay_death()            # U8 元素色 / 衰减 / 死亡隐藏
	_test_u9_burst_count_and_scene_map()          # U9 burst 计数 + scene_id 映射在环
	_test_u12_boss_bar()                          # U12 Boss 波 BossBar 联动
	_test_u13_summon_with_14_normals()            # U13 伴随满场（14）召唤仍触发
	_test_u14_shop_kind_single_source()           # U14 shop_ui kind 单源同步断言
	_test_u5_rush_drop_count()                    # U5 固定种子掉落次数 rush > 普通
	_test_u5_reward_monotonic()                   # U5 波末奖励与清速单调
	_test_economy_chain_w6()                      # ③ 金币关 w6 经济链一次
	_test_u4u7_shop_reopen_reproducible()         # U4+U7 闭店重开固定种子可复现
	_teardown_game_loop()
	# 汇总
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)


func fail_count() -> int:
	return _fail


# ── 环境引导（pkg7 夹具模式） ─────────────────────────────────────
func _ensure_autoloads() -> void:
	_check("autoload 就绪（EventBus/GameConfig/DebugStats）",
		EventBus != null and GameConfig != null and DebugStats != null)
	_check("GameConfig 非致命（balance 加载）", not GameConfig.is_fatal() and GameConfig.balance != null)


func _boot_game_loop() -> void:
	_gl = GameLoop.new()
	_gl.name = "GameLoopUnderTest"
	tree.get_root().add_child(_gl)
	_check("Boot：完成且进入 MENU", _gl.boot_ready and _gl.state == GameConst.GameStatus.MENU)
	_check("开局：start_run → PLAYING（波次 1）", _gl.start_run()
		and _gl.state == GameConst.GameStatus.PLAYING)


func _teardown_game_loop() -> void:
	tree.paused = false
	if _gl != null:
		_gl.free()
		_gl = null


func _check(p_desc: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("  PASS %s" % p_desc)
	else:
		_fail += 1
		_failures.append("%s %s" % [p_desc, p_detail])
		print("  FAIL %s %s" % [p_desc, p_detail])


func _clear_battlefield() -> void:
	# 清场（非战斗语义：静默归还，不触发掉落/计数）
	_gl.spawner.spawn_queue.clear()
	for e in _gl.spawner.active.duplicate():
		_gl.spawner.on_enemy_killed(e)


func _dismiss_blessing_fixture() -> void:
	# v0.9.0 授权更新（A8）：wave_cleared 新增赐福订阅（w>=2 开门）——夹具排险：
	# 清暂存位 + 跳过已开门的赐福（无补偿），恢复 PLAYING 态语义
	_gl._deferred_blessing = false
	if _gl.blessing_ui != null and _gl.blessing_ui.is_open:
		_gl.blessing_ui.skip_requested.emit()


func _release_all_coins() -> void:
	# 清空场内金币（不入账——保持经济链断言口径纯净）
	while not _gl.active_coins.is_empty():
		var coin: GoldCoin = _gl.active_coins[_gl.active_coins.size() - 1]
		(_gl.pools[&"gold"] as GoldPool).release(coin)
		_gl.active_coins.remove_at(_gl.active_coins.size() - 1)


func _mk_pipeline_target() -> Enemy:
	var e := Enemy.new()
	e.uid = GameConst.next_uid()
	e.hp = 1000000000.0
	e.max_hp = 1000000000.0
	return e


func _mk_ctx(p_target: Enemy, p_stamp: int) -> DamageContext:
	var ctx := DamageContext.make()
	ctx.source_uid = 1
	ctx.target = p_target
	ctx.target_uid = int(p_target.uid)
	ctx.frame_stamp = p_stamp
	ctx.base_atk = 100.0
	ctx.crit_chance = 0.0
	return ctx


# ══ U1：validator 重复扫描幂等（非法夹具剔除计数不膨胀） ═══════════
func _test_u1_validator_idempotent() -> void:
	print("── U1 重复扫描幂等 ──")
	var reg := _gl.registry
	var v := DataValidator.new()
	var bad := ChipData.new()
	bad.id = &"CHIP_BAD2"
	bad.stat_key = &"atk_pct"
	bad.values = [0.1, 0.2]                       # 缺档 → SEV_ERROR
	reg.chips[&"CHIP_BAD2"] = bad
	var r1: Dictionary = v.validate_all(reg)
	var r2: Dictionary = v.validate_all(reg)      # 重复扫描
	var chip_reject_1 := 0
	var chip_reject_2 := 0
	for row in (r1["rejected"] as Array):
		if String((row as Dictionary).get("category", "")) == "chips":
			chip_reject_1 += 1
	for row in (r2["rejected"] as Array):
		if String((row as Dictionary).get("category", "")) == "chips":
			chip_reject_2 += 1
	_check("validate_all：重复扫描 rejected 数不膨胀（%d = %d）" % [(r1["rejected"] as Array).size(),
		(r2["rejected"] as Array).size()],
		(r1["rejected"] as Array).size() == (r2["rejected"] as Array).size()
		and int(r1["total"]) == int(r2["total"]))
	_check("validate_all：坏芯片每次恰剔除 1 次（不重复计数）",
		chip_reject_1 == 1 and chip_reject_2 == 1,
		"r1=%d r2=%d" % [chip_reject_1, chip_reject_2])
	reg.chips.erase(&"CHIP_BAD2")
	var r3: Dictionary = v.validate_all(reg)
	var chip_reject_3 := 0
	for row in (r3["rejected"] as Array):
		if String((row as Dictionary).get("category", "")) == "chips":
			chip_reject_3 += 1
	_check("validate_all：剔除坏件后 chips 类目 0 剔除（12 枚全清洁；v0.8.0 +4 变体授权更新）",
		chip_reject_3 == 0 and reg.chips.size() == 12)


# ══ U3：芯片不占乘区 top-8 名额（10 乘区池 + 芯片全额生效） ═════════
func _test_u3_chip_quota_superset() -> void:
	print("── U3 芯片不占 top-8 名额 ──")
	var pipe := DamagePipeline.new()
	pipe.set_rng_seed(777)
	var e := _mk_pipeline_target()
	pipe.begin_frame()
	var ctx := _mk_ctx(e, 101)
	for i in range(10):
		(ctx.mult_pools as Array[Dictionary]).append({
			"pool_id": StringName("p%02d" % (i + 1)), "source_uid": 0,
			"contrib": 0.05, "cap_pool": 7.0,
		})
	ctx.chip_entries = [{"stat": &"atk_pct", "contrib": 0.35}]
	var r := pipe.resolve(ctx)
	# 期望：10 池按 (M−1) 全等 → pool_id 字典序取 p01~p08（M = 1.05^8），p09/p10 截断；
	# 芯片独立段全额 1.35（不入名额）→ final = 100 × 1.05^8 × 1.35
	var expected := 100.0 * pow(1.05, 8.0) * 1.35
	var pool_ids: Array = []
	for m: Dictionary in (r.audit.truncated_mults as Array):
		pool_ids.append(String(m["pool_id"] if m.has("pool_id") else m))
	_check("10 池 + 芯片：audit.pool_count = 8（芯片不占名额）",
		r != null and r.audit.pool_count == 8, "count=%d" % (r.audit.pool_count if r != null else -1))
	_check("10 池：top-8 截断恰 2 项（p09/p10）",
		(r.audit.truncated_mults as Array).size() == 2,
		str(r.audit.truncated_mults if r != null else []))
	_check("芯片全额生效：final = 100 × 1.05^8 × 1.35 = %.4f" % expected,
		r != null and is_equal_approx(r.final_value, expected),
		"final=%s" % str(r.final_value if r != null else -1.0))
	_check("乘区积 = 1.05^8（若芯片挤占名额该值不同——判别位）",
		r != null and is_equal_approx(r.mult_product, pow(1.05, 8.0)),
		"M=%s" % str(r.mult_product if r != null else -1.0))
	_check("未触联合钳（1.477×1.35 < 8 → 无 compressed）",
		r != null and not r.audit.compressed)
	e.free()


# ══ U3：joint 公式手算对照（M=2.0 × chip=1.35 → joint=min(2.7,8)=2.7） ══
func _test_u3_joint_hand_calc() -> void:
	print("── U3 joint 手算对照 ──")
	var pipe := DamagePipeline.new()
	pipe.set_rng_seed(777)
	var e := _mk_pipeline_target()
	pipe.begin_frame()
	var ctx := _mk_ctx(e, 201)
	(ctx.mult_pools as Array[Dictionary]).append({
		"pool_id": &"hand_pool", "source_uid": 1, "contrib": 1.0, "cap_pool": 7.0,
	})                                             # M = 1 + min(1.0, 7.0) = 2.0
	ctx.chip_entries = [{"stat": &"atk_pct", "contrib": 0.35}]   # chip_product = 1.35
	var r := pipe.resolve(ctx)
	# 手算：joint = min(2.0 × 1.35, 8.0) = 2.7；final = S(100) × 2.7 × L(1) × C(1) × V(1) = 270
	_check("手算：M=2.0 / chip=1.35 → mult_product×chip_product = 2.7",
		r != null and is_equal_approx(r.mult_product, 2.0)
		and is_equal_approx(r.chip_product, 1.35)
		and is_equal_approx(minf(r.mult_product * r.chip_product, 8.0), 2.7))
	_check("管线输出与手算一致：final = 270",
		r != null and is_equal_approx(r.final_value, 270.0),
		"final=%s" % str(r.final_value if r != null else -1.0))
	_check("joint 未触 cap_prod（无 compressed）", r != null and not r.audit.compressed)
	e.free()


# ══ U3：拔芯片（reset_run）回基线 ═════════════════════════════════
func _test_u3_chip_reset_baseline() -> void:
	print("── U3 拔芯片回基线 ──")
	var h := _gl.chip_handler
	h.reset_run()
	h.unlocked_slots = 3                   # 门控夹具（v0.7.0 审查裁定）
	var weapon: WeaponBase = _gl.player.weapon_slots[0]
	var target := _mk_pipeline_target()
	h.equip(&"CHIP_ATK", 3)                       # 金档 0.35
	weapon.invalidate_panel()
	var ctx_on := weapon.build_damage_context(target)
	var on_ok := ctx_on.chip_entries.size() == 1 \
		and is_equal_approx(float((ctx_on.chip_entries[0] as Dictionary).get("contrib", 0.0)), 0.35)
	_check("装备后：weapon ctx chip_entries = [atk_pct 0.35]", on_ok)
	h.reset_run()                                  # 拔芯片
	weapon.invalidate_panel()
	var ctx_off := weapon.build_damage_context(target)
	var snap_off := weapon.build_panel_snapshot()
	_check("拔芯片后：ctx chip_entries 空 + 快照 chip_atk_pct = 0（回基线）",
		ctx_off.chip_entries.is_empty() and is_equal_approx(float(snap_off.get("chip_atk_pct", -1.0)), 0.0))
	_check("拔芯片后：stat_bonus(atk_pct) = 0", is_equal_approx(h.stat_bonus(&"atk_pct"), 0.0))
	target.free()


# ══ U3：护栏 clamp 保留（射速 ≤30 / 暴击率 ≤1.0，芯片叠加后仍收口） ══
func _test_u3_clamp_retained() -> void:
	print("── U3 clamp 保留 ──")
	var h := _gl.chip_handler
	h.reset_run()
	h.unlocked_slots = 3                   # 门控夹具（v0.7.0 审查裁定）
	# 射速钳：内存构造 BALLISTIC（rof=28，超 30 需芯片叠加）
	var wd := WeaponData.new()
	wd.id = &"W_TEST_ROF_CLAMP"
	wd.display_name = "测试·射速钳"
	wd.form = GameConst.WeaponForm.BALLISTIC
	var lv := WeaponLevelStats.new()
	lv.base_atk = 10.0
	lv.rof = 28.0
	wd.upgrade_table = [lv]
	var bw := BallisticWeapon.new()
	bw.setup(wd, _gl.player, {"chip_handler": h})
	bw._fire_interval()
	_check("无芯片：rof_current = 28（未触钳）", is_equal_approx(bw.rof_current, 28.0))
	h.equip(&"CHIP_ROF", 3)                       # 28 × 1.25 = 35 → 钳 30
	var interval := bw._fire_interval()
	_check("金 rof 芯片：rof_current 钳 30（F11 护栏保留）",
		is_equal_approx(bw.rof_current, 30.0), "rof=%s" % str(bw.rof_current))
	_check("射速钳后 interval = 1/30", is_equal_approx(interval, 1.0 / 30.0))
	bw.free()
	# 暴击钳：内存构造 crit_rate=0.9 → +0.18 = 1.08 → 钳 1.0
	h.reset_run()
	h.unlocked_slots = 3                   # 门控夹具（v0.7.0 审查裁定）
	var wd2 := WeaponData.new()
	wd2.id = &"W_TEST_CRIT_CLAMP"
	wd2.display_name = "测试·暴击钳"
	wd2.form = GameConst.WeaponForm.BALLISTIC
	wd2.crit_rate = 0.9
	var lv2 := WeaponLevelStats.new()
	lv2.base_atk = 10.0
	lv2.rof = 5.0
	wd2.upgrade_table = [lv2]
	var cw := BallisticWeapon.new()
	cw.setup(wd2, _gl.player, {"chip_handler": h})
	cw.invalidate_panel()                          # 面板快照为失效重算口径（同 pkg7）
	var snap0 := cw.build_panel_snapshot()
	_check("无芯片：面板 crit_rate = 0.9（表值）",
		is_equal_approx(float(snap0.get("crit_rate", -1.0)), 0.9))
	h.equip(&"CHIP_CRIT", 3)                      # 0.9 + 0.18 = 1.08
	cw.invalidate_panel()
	var snap1 := cw.build_panel_snapshot()
	_check("crit 芯片叠加：crit_rate 钳 1.0（cap_crit_rate 保留）",
		is_equal_approx(float(snap1.get("crit_rate", -1.0)), 1.0),
		"crit=%s" % str(snap1.get("crit_rate", -1.0)))
	cw.free()
	h.reset_run()


# ══ U8：环元素色（A6 §9 冻结表）/ 衰减 / 死亡归还隐藏 ═════════════
func _test_u8_ring_colors_decay_death() -> void:
	print("── U8 环元素色/衰减/死亡隐藏 ──")
	# 元素色冻结表（headless 不验像素；与 A6 §9 表一致 + 绘制常量单源）
	# v1.2.0 授权更新：WAT 入场 → RING_COLORS 3 → 4（A11 §2；FIR/ICE/LTG 三值冻结不变）
	var colors: Array[Color] = Enemy.ElementRing.RING_COLORS
	var ok4 := colors.size() == 4
	_check("ElementRing.RING_COLORS 恰 4 元素（v1.2.0 授权更新）", ok4)
	if ok4:
		var fir := colors[GameConst.Element.FIR - 1]
		var ice := colors[GameConst.Element.ICE - 1]
		var ltg := colors[GameConst.Element.LTG - 1]
		var wat := colors[GameConst.Element.WAT - 1]
		_check("FIR 橙 (1.0,0.45,0.2,0.9)（A6 §9 冻结）",
			is_equal_approx(fir.r, 1.0) and is_equal_approx(fir.g, 0.45)
			and is_equal_approx(fir.b, 0.2) and is_equal_approx(fir.a, 0.9))
		_check("ICE 蓝 (0.4,0.75,1.0,0.9)",
			is_equal_approx(ice.r, 0.4) and is_equal_approx(ice.g, 0.75)
			and is_equal_approx(ice.b, 1.0) and is_equal_approx(ice.a, 0.9))
		_check("LTG 紫 (0.75,0.6,1.0,0.9)",
			is_equal_approx(ltg.r, 0.75) and is_equal_approx(ltg.g, 0.6)
			and is_equal_approx(ltg.b, 1.0) and is_equal_approx(ltg.a, 0.9))
		_check("WAT 水青 (0.3,0.75,0.9,0.9)（A11 §1 冻结）",
			is_equal_approx(wat.r, 0.3) and is_equal_approx(wat.g, 0.75)
			and is_equal_approx(wat.b, 0.9) and is_equal_approx(wat.a, 0.9))
	# 衰减：附着 60 → λ_FIR 衰减 0.5s → 进度严格下降
	var es := ElementalSystem.new()
	var e := Enemy.new()
	tree.get_root().add_child(e)
	e.spawn(_gl.registry.get_enemy(&"E1_grunt"), 5, 0)
	e.position = Vector2(360.0, 400.0)
	es.register_host(e)
	e.elemental.gauges[GameConst.Element.FIR] = 60.0
	e.tick(DT)
	var before := e.ring_progress(GameConst.Element.FIR)
	_check("衰减前：FIR 进度 0.6 / 环显示", e.ring_visible() and is_equal_approx(before, 0.6))
	es.tick(0.5)                                   # λ_FIR=0.35 → 60×(1−0.175)=49.5
	e.tick(0.1)                                    # >1/15 → 快照刷新
	var after := e.ring_progress(GameConst.Element.FIR)
	_check("衰减后：进度严格下降（%s < 0.6）" % str(after), after < before and after > 0.0,
		"before=%s after=%s" % [str(before), str(after)])
	es.unregister_host(e)
	es.free()
	e.free()
	# 死亡归还隐藏（真实 enemy_killed 链 → 池归还 _reset_state → 环隐藏）
	var es2 := ElementalSystem.new()
	var pool := _gl.pools[&"enemy"] as EnemyPool
	var e2 := pool.acquire() as Enemy
	e2.spawn(_gl.registry.get_enemy(&"E1_grunt"), 5, 0)
	e2.global_position = Vector2(360.0, 640.0)
	es2.register_host(e2)
	e2.elemental.gauges[GameConst.Element.ICE] = 70.0
	e2.tick(DT)
	_check("死亡前：附着敌环显示", e2.ring_visible())
	EventBus.emit_enemy_killed(e2)                 # 完整死亡链（掉落/归还/清零）
	_check("死亡归还后：环隐藏 + elemental 清零",
		not e2.ring_visible() and e2.elemental == null)
	es2.unregister_host(e2)
	es2.free()


# ══ U9：burst 调用计数（观测口）+ 反应 scene_id 映射在环 ═══════════
func _test_u9_burst_count_and_scene_map() -> void:
	print("── U9 burst 计数与映射在环 ──")
	# 映射表字面值（A6 §9 冻结：碎裂/过载/超导；v1.2.0 授权更新：水系三反 A11 §6）
	_check("映射表字面值：碎裂→burst_rxn_shatter",
		String(ParticleDirector.REACTION_SCENE_IDS[GameConst.ReactionType.RXN_FIR_ICE]) == "burst_rxn_shatter")
	_check("映射表字面值：过载→burst_rxn_overload",
		String(ParticleDirector.REACTION_SCENE_IDS[GameConst.ReactionType.RXN_FIR_LTG]) == "burst_rxn_overload")
	_check("映射表字面值：超导→burst_rxn_superconduct",
		String(ParticleDirector.REACTION_SCENE_IDS[GameConst.ReactionType.RXN_ICE_LTG]) == "burst_rxn_superconduct")
	_check("映射表字面值：冻结→burst_rxn_freeze（v1.2.0 授权更新）",
		String(ParticleDirector.REACTION_SCENE_IDS[GameConst.ReactionType.RXN_WAT_ICE]) == "burst_rxn_freeze")
	_check("映射表字面值：导电→burst_rxn_conduct（v1.2.0 授权更新）",
		String(ParticleDirector.REACTION_SCENE_IDS[GameConst.ReactionType.RXN_WAT_LTG]) == "burst_rxn_conduct")
	_check("映射表字面值：汽爆→burst_rxn_vaporblast（v1.2.0 授权更新）",
		String(ParticleDirector.REACTION_SCENE_IDS[GameConst.ReactionType.RXN_WAT_FIR]) == "burst_rxn_vaporblast")
	var gf := _gl.game_feel
	var pd := gf.particles
	var pool := _gl.pools[&"particle"] as ParticlePool
	var reactions := [GameConst.ReactionType.RXN_FIR_ICE,
		GameConst.ReactionType.RXN_FIR_LTG, GameConst.ReactionType.RXN_ICE_LTG,
		GameConst.ReactionType.RXN_WAT_ICE, GameConst.ReactionType.RXN_WAT_LTG,
		GameConst.ReactionType.RXN_WAT_FIR]
	var all_ok := true
	var detail := ""
	for rxn in reactions:
		var n0: int = pd.burst_requests             # 观测口：受理 burst 请求累计
		gf.on_reaction_triggered(int(rxn), Vector2(100.0, 100.0), 0)
		var count_ok: bool = pd.burst_requests == n0 + 1
		var expected_scene := String(ParticleDirector.REACTION_SCENE_IDS[rxn])
		var scene_seen := false
		for pe in pool.get_children():
			var gpe := pe as GPUParticles2D
			if gpe != null and gpe.visible \
					and gpe.get_meta(&"_burst_scene_id", &"") == StringName(expected_scene):
				scene_seen = true
		pool.release_active_all()
		if not count_ok or not scene_seen:
			all_ok = false
			detail += "rxn=%d burstΔ=%d scene(%s)=%s | " % [int(rxn),
				pd.burst_requests - n0, expected_scene, str(scene_seen)]
	_check("六反应：on_reaction_triggered → burst 恰 +1 且发射器挂正确 scene_id（在环；v1.2.0 授权更新）",
		all_ok, detail)


# ══ U12：Boss 波 BossBar 联动（boss_spawned 登场 / 死亡隐藏） ══════
func _test_u12_boss_bar() -> void:
	print("── U12 BossBar 联动 ──")
	_clear_battlefield()
	var h := _gl.chip_handler
	h.reset_run()
	_gl.wave_director.start_wave(10)
	var guard := 0
	while not _gl.spawner.queue_empty() and guard < 400:
		_gl.spawner.tick(DT, _gl.enemy_grid)
		guard += 1
	var boss: Enemy = null
	for e in _gl.spawner.active:
		var en := e as Enemy
		if en != null and en.is_boss():
			boss = en
	_check("w10：Boss 实体在场", boss != null)
	var bar := _gl.boss_bar
	_check("Boss 登场 → BossBar 显示且绑定该 Boss（boss_spawned 链）",
		bar.is_visible_bar() and bar.boss == boss)
	_check("满血登场：displayed_pct = 1.0", is_equal_approx(bar.displayed_pct(), 1.0),
		str(bar.displayed_pct()))
	EventBus.emit_enemy_killed(boss)               # 完整死亡链（含 Boss 芯片掉落）
	_check("Boss 死亡 → BossBar 隐藏", not bar.is_visible_bar())
	h.reset_run()
	_clear_battlefield()


# ══ U13：伴随满场（14 只普通敌）时 Boss 召唤仍触发（独立计数闸） ══
func _test_u13_summon_with_14_normals() -> void:
	print("── U13 伴随满场召唤仍触发 ──")
	_clear_battlefield()
	var spawner := _gl.spawner
	spawner.summon_active_count = 0
	for i in range(14):
		spawner.enqueue({"data_id": &"E1_grunt", "wave": 12, "tags": 0})
	spawner.tick(DT, _gl.enemy_grid)               # 8 只/帧
	spawner.tick(DT, _gl.enemy_grid)               # 6 只
	_check("夹具：场上 14 只普通敌（旧 active_count 闸 ≥12 必拦的规模）",
		spawner.active_count() == 14 and spawner.summon_active_count == 0,
		"active=%d summon=%d" % [spawner.active_count(), spawner.summon_active_count])
	var pool := _gl.pools[&"enemy"] as EnemyPool
	var boss2 := pool.acquire() as Enemy
	boss2.spawn(_gl.registry.get_enemy(&"E6_boss2"), 20, GameConst.TAG_BOSS)
	boss2.summon_spawner = spawner
	boss2.projectile_pool = _gl.pools[&"projectile"]
	var q0 := spawner.queue_count()
	boss2._summon_cd_left = DT
	boss2.tick(DT)
	_check("14 只伴随在场：Boss 召唤仍入队 +2（闸只看 summon_active_count）",
		spawner.queue_count() == q0 + 2,
		"queue=%d expect=%d" % [spawner.queue_count(), q0 + 2])
	_check("召唤未出生：summon_active_count 仍 0（出生才计数）",
		spawner.summon_active_count == 0)
	spawner.spawn_queue.clear()
	(_gl.pools[&"enemy"] as EnemyPool).release(boss2)
	_clear_battlefield()


# ══ U14：shop_ui 货架 kind 中文名单源（GameConst.card_kind_name 同步断言） ══
func _test_u14_shop_kind_single_source() -> void:
	print("── U14 shop_ui kind 单源 ──")
	var shop := _gl.shop_ui
	var card := {"kind": 0, "display_name": "X", "description": "d"}
	var t0 := shop._shelf_text(card, false, 50)
	_check("shop 货架 kind=0 → 「[精通] X」（与 GameConst.card_kind_name 同步）",
		String(t0).begins_with("[%s] X" % GameConst.card_kind_name(0)), str(t0))
	card["kind"] = 3
	var t3 := shop._shelf_text(card, false, 50)
	_check("shop 货架 kind=3 → 「[保底] X」", String(t3).begins_with("[%s] X" % GameConst.card_kind_name(3)))
	card["kind"] = 9
	var t9 := shop._shelf_text(card, false, 50)
	_check("shop 货架 kind=9 越界钳 → 「[武器] X」",
		String(t9).begins_with("[%s] X" % GameConst.card_kind_name(9)))
	var tw := shop._shelf_text(card, true, 50)
	_check("shop 武器架 p_weapon=true → 「[武器] …」（不经 kind 字段）",
		String(tw).begins_with("[武器] "))


# ══ U5：固定种子掉落次数对比（chance 覆写 max(原,0.5)） ════════════
func _test_u5_rush_drop_count() -> void:
	print("── U5 固定种子掉落次数对比 ──")
	_gl.chip_handler.reset_run()                   # K_gold / add_gold_drop 隔离
	var e1 := _gl.registry.get_enemy(&"E1_grunt")
	var rush_drops := _kill_batch_drops(true, e1)
	var normal_drops := _kill_batch_drops(false, e1)
	_gl.set_gold_rng_seed(42)                      # 还原默认金币种子
	_check("同种子同构 40 杀：金币关掉落次数(%d) > 普通波(%d)（chance 0.06 → 下限 0.5）"
		% [rush_drops, normal_drops], rush_drops > normal_drops,
		"rush=%d normal=%d" % [rush_drops, normal_drops])


func _kill_batch_drops(p_rush: bool, p_data: EnemyData) -> int:
	# 固定种子重播 40 杀，统计出币次数（每杀至多 1 币；币即杀即还——只数次数）
	_gl.set_gold_rng_seed(4242)
	var drops := 0
	for i in range(40):
		var e := Enemy.new()
		e.spawn(p_data, 6, 0)
		e.gold_rush = p_rush
		e.global_position = Vector2(360.0, 200.0 + 10.0 * float(i))
		var c0: int = _gl.active_coins.size()
		_gl._on_enemy_killed_drop_gold(e)
		drops += _gl.active_coins.size() - c0
		while _gl.active_coins.size() > c0:
			(_gl.pools[&"gold"] as GoldPool).release(_gl.active_coins[_gl.active_coins.size() - 1])
			_gl.active_coins.remove_at(_gl.active_coins.size() - 1)
		e.free()
	return drops


# ══ U5：波末奖励与清速单调（ratio = 剩余时间比，快清多得） ═════════
func _test_u5_reward_monotonic() -> void:
	print("── U5 波末奖励单调 ──")
	_clear_battlefield()
	_gl.chip_handler.reset_run()                   # K_gold 隔离（amount 不缩放）
	var counter0 := DebugStats.get_counter(&"gold_rush_reward")
	# 快清：满剩余比 1.0 → base(10+5×16)=90 × 1.0 = 90
	_gl.wave_director.start_wave(16)
	_gl.wave_director._hard_cap_left = 8.0
	var g0 := _gl.gold
	EventBus.emit_wave_cleared(16)
	var fast := _gl.gold - g0
	_check("w16 快清（ratio 1.0）：波末奖励 +90（base 90 × 1.0）", fast == 90, "delta=%d" % fast)
	# 慢清：剩余比 0.5 → 90 × 0.5 = 45
	_gl.wave_director.start_wave(16)
	_gl.wave_director._hard_cap_left = 4.0
	var g1 := _gl.gold
	EventBus.emit_wave_cleared(16)
	var slow := _gl.gold - g1
	_check("w16 慢清（ratio 0.5）：波末奖励 +45", slow == 45, "delta=%d" % slow)
	_check("清速单调：快清 90 > 慢清 45（ratio 与奖励单调一致）", fast > slow)
	_check("波末奖励遥测 +2", DebugStats.get_counter(&"gold_rush_reward") == counter0 + 2)
	# v0.9.0 授权更新：wave_cleared 新增赐福订阅（w>=2 开门，A8）——夹具排险：清暂存位 +
	# 跳过已开门的赐福（无补偿），保持后续商店流用例的 PLAYING 态语义
	_dismiss_blessing_fixture()
	_clear_battlefield()


# ══ ③：金币关 w6 经济链一次（全灭总收益 = 波内掉落 + 波末奖励） ══
func _test_economy_chain_w6() -> void:
	print("── ③ 金币关 w6 经济链 ──")
	_clear_battlefield()
	_release_all_coins()
	_gl.chip_handler.reset_run()                   # 无 gold 芯片 → K_gold=0（金额精确）
	_gl.wave_director.start_wave(6)
	var guard := 0
	while not _gl.spawner.queue_empty() and guard < 2000:
		_gl.spawner.tick(DT, _gl.enemy_grid)
		guard += 1
	var rush_n := 0
	for e in _gl.spawner.active:
		var en := e as Enemy
		if en != null and en.gold_rush:
			rush_n += 1
	_check("夹具：w6 全场 rush 敌（%d 只，全部带 gold_rush 标记）" % rush_n,
		rush_n == _gl.spawner.active_count() and rush_n > 0,
		"active=%d rush=%d" % [_gl.spawner.active_count(), rush_n])
	var g0 := _gl.gold
	while not _gl.spawner.active.is_empty():       # 全灭（真实 enemy_killed 链 → 掉落）
		EventBus.emit_enemy_killed(_gl.spawner.active[0])
	var sum_drops := 0.0
	for coin in _gl.active_coins:
		sum_drops += float((coin as GoldCoin).value)
	_check("波内掉落已产出（Σ%d 金币，未入账）" % int(sum_drops), sum_drops > 0.0)
	_check("击杀只产币不入账：余额不变", _gl.gold == g0, "gold=%d g0=%d" % [_gl.gold, g0])
	while not _gl.active_coins.is_empty():         # 吸收（走 _tick_gold_coins 同款入账路径）
		var coin: GoldCoin = _gl.active_coins[_gl.active_coins.size() - 1]
		_gl._add_gold(coin.value)
		(_gl.pools[&"gold"] as GoldPool).release(coin)
		_gl.active_coins.remove_at(_gl.active_coins.size() - 1)
	_check("吸收后：gold = g0 + Σ掉落（%d + %d）" % [g0, int(sum_drops)],
		_gl.gold == g0 + int(sum_drops), "gold=%d" % _gl.gold)
	_gl.wave_director._hard_cap_left = 8.0         # 满剩余比 1.0 → 奖励 (10+30)×1.0 = 40
	var counter0 := DebugStats.get_counter(&"gold_rush_reward")
	EventBus.emit_wave_cleared(6)
	_check("波末奖励 +40（base 40 × 1.0）", _gl.gold == g0 + int(sum_drops) + 40,
		"gold=%d" % _gl.gold)
	_check("经济链闭合：全灭总收益 = 波内掉落 + 波末奖励（遥测 +1）",
		_gl.gold == g0 + int(sum_drops) + 40
		and DebugStats.get_counter(&"gold_rush_reward") == counter0 + 1)
	_gl.chip_handler.reset_run()
	_dismiss_blessing_fixture()                   # v0.9.0 授权更新：w6 wave_cleared 赐福排险（A8）
	_clear_battlefield()


# ══ U4+U7：闭店重开固定种子 offers 可复现（商店流全链） ═══════════
func _test_u4u7_shop_reopen_reproducible() -> void:
	print("── U4+U7 闭店重开可复现 ──")
	var h := _gl.chip_handler
	h.reset_run()
	h.unlocked_slots = 3
	_check("夹具：PLAYING 态可开店", _gl.state == GameConst.GameStatus.PLAYING)
	h.set_rng_seed(91)
	_check("开店 A", _gl._open_shop_flow(12, false))
	var offer_a: Array = (_gl.shop_ui.shelf_state()["chips"] as Array).duplicate()
	_gl._close_shop()
	h.set_rng_seed(91)
	_check("开店 B（同种子重开）", _gl._open_shop_flow(12, false))
	var offer_b: Array = _gl.shop_ui.shelf_state()["chips"]
	var same := (offer_a as Array).size() == (offer_b as Array).size() and not (offer_a as Array).is_empty()
	if same:
		for i in range((offer_a as Array).size()):
			var a: Dictionary = offer_a[i]
			var b: Dictionary = offer_b[i]
			if String(a.get("chip_id", &"")) != String(b.get("chip_id", &"")) \
					or int(a.get("rarity", -1)) != int(b.get("rarity", -1)):
				same = false
	_check("闭店重开：芯片货架 offers 逐位可复现（chip_id + rarity）",
		same, "A=%s B=%s" % [str(offer_a), str(offer_b)])
	_gl._close_shop()
	h.reset_run()

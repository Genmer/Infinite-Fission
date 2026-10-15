# tests/runner/strategic_boost_cases.gd — 策略降载自动化测试套件
extends RefCounted

var _fails: int = 0
var _passes: int = 0


func fail_count() -> int:
	return _fails


func assert_eq(actual, expected, msg: String = "") -> void:
	if actual == expected:
		_passes += 1
	else:
		_fails += 1
		print("FAIL | %s: 预期 %s，实际得到 %s" % [msg, str(expected), str(actual)])


func assert_true(cond: bool, msg: String = "") -> void:
	if cond:
		_passes += 1
	else:
		_fails += 1
		print("FAIL | %s: 期望为 true" % msg)


func assert_false(cond: bool, msg: String = "") -> void:
	if not cond:
		_passes += 1
	else:
		_fails += 1
		print("FAIL | %s: 期望为 false" % msg)


func run(_tree: SceneTree) -> void:
	print("=== 开始执行策略降载自动化测试 (Strategic Boost Test) ===")
	test_t1_governor_modes()
	test_t2_enemy_geom_cache()
	test_t3_enemy_vis_culling()
	test_t4_reaction_defer_and_flush()
	test_t5_reaction_damping()
	test_t6_viewport_culling()
	test_t7_cluster_merging()
	test_t8_reaction_size_cache()
	test_t9_rng_zero_shift()
	print("=== 策略降载测试完成：PASS %d / FAIL %d ===" % [_passes, _fails])


func test_t1_governor_modes() -> void:
	var orig_ov := PerfGovernor.boost_override
	PerfGovernor.boost_override = 0
	assert_false(PerfGovernor.boost_mode(), "T1: boost_override=0 应关闭保帧模式")
	assert_false(PerfGovernor.strategic_boost_active(), "T1: strategic_boost_active 应随之关闭")
	PerfGovernor.boost_override = 1
	assert_true(PerfGovernor.boost_mode(), "T1: boost_override=1 应开启保帧模式")
	assert_true(PerfGovernor.strategic_boost_active(), "T1: strategic_boost_active 应随之开启")
	PerfGovernor.boost_override = orig_ov


func test_t2_enemy_geom_cache() -> void:
	var orig_ov := PerfGovernor.boost_override
	PerfGovernor.boost_override = 1
	var enemy := Enemy.new()
	assert_false(enemy._frame_geom_valid, "T2: 初始几何缓存应未生效")
	# 空指针守卫
	assert_false(enemy._ensure_frame_geom(null), "T2: player 为空时应安全返回 false")
	assert_eq(enemy._get_dist_to_player(null), 999999.0, "T2: 空 player 距离应返回安全大值")
	assert_eq(enemy._get_dir_to_player(null), Vector2.ZERO, "T2: 空 player 方向应返回零向量")
	
	# 构造虚拟 player 测试几何解算
	var dummy_pl := Node2D.new()
	dummy_pl.global_position = Vector2(300.0, 400.0)
	enemy.global_position = Vector2(0.0, 0.0)
	assert_true(enemy._ensure_frame_geom(dummy_pl), "T2: 有效 player 几何解算成功")
	assert_true(enemy._frame_geom_valid, "T2: 几何缓存应标记为有效")
	assert_eq(enemy._dist_sq_to_player, 250000.0, "T2: 距离平方计算准确 (300^2 + 400^2)")
	assert_eq(enemy._get_dist_to_player(dummy_pl), 500.0, "T2: 距离解算准确 (500)")
	var dir := enemy._get_dir_to_player(dummy_pl)
	assert_true(absf(dir.x - 0.6) < 0.001 and absf(dir.y - 0.8) < 0.001, "T2: 单位方向向量计算准确 (0.6, 0.8)")
	
	# 重置验证
	enemy._reset_frame_geom()
	assert_false(enemy._frame_geom_valid, "T2: 重置后几何缓存应失效")
	
	# 保帧模式关闭回归验证
	PerfGovernor.boost_override = 0
	assert_false(enemy._ensure_frame_geom(dummy_pl), "T2: 保帧模式关闭时几何缓存应禁用回归原生")
	var dir_off := enemy._get_dir_to_player(dummy_pl)
	assert_true(absf(dir_off.x - 0.6) < 0.001 and absf(dir_off.y - 0.8) < 0.001, "T2: 保帧关闭时单位方向向量正常原生解算")
	assert_eq(enemy._get_dist_to_player(dummy_pl), 500.0, "T2: 保帧关闭时距离正常原生解算")
	
	PerfGovernor.boost_override = orig_ov
	dummy_pl.free()
	enemy.free()


func test_t3_enemy_vis_culling() -> void:
	var orig_ov := PerfGovernor.boost_override
	PerfGovernor.boost_override = 1
	var enemy := Enemy.new()
	# 屏幕外坐标
	enemy.global_position = Vector2(3000.0, 3000.0)
	assert_true(enemy._is_vis_cullable(), "T3: 保帧模式下屏幕外普通杂兵应被裁剪")
	
	# 屏幕内坐标
	enemy.global_position = Vector2(360.0, 640.0)
	assert_false(enemy._is_vis_cullable(), "T3: 屏幕内杂兵绝不裁剪")
	
	# 屏幕外但有自爆引信激活
	enemy.global_position = Vector2(3000.0, 3000.0)
	enemy._fuse_armed = true
	assert_false(enemy._is_vis_cullable(), "T3: 关键自爆引信激活绝不裁剪")
	enemy._fuse_armed = false
	
	# 保帧模式关闭时
	PerfGovernor.boost_override = 0
	assert_false(enemy._is_vis_cullable(), "T3: 保帧模式关闭时绝不裁剪")
	
	PerfGovernor.boost_override = orig_ov
	enemy.free()


func test_t4_reaction_defer_and_flush() -> void:
	var orig_ov := PerfGovernor.boost_override
	var orig_budget := DamagePipeline.settle_budget_override
	PerfGovernor.boost_override = 1
	DamagePipeline.settle_budget_override = 48
	var pipeline := DamagePipeline.new()
	pipeline.begin_frame(1, true)
	
	# 构造虚拟敌人与上下文
	var dummy_enemy := Enemy.new()
	dummy_enemy.hp = 1000.0
	dummy_enemy.uid = 1001
	var ctx := DamageContext.make()
	ctx.source_uid = 1
	ctx.target = dummy_enemy
	ctx.target_uid = 1001
	ctx.frame_stamp = 1
	ctx.element = GameConst.ReactionType.RXN_FIR_LTG
	ctx.pos = Vector2(100.0, 100.0)
	
	# 正常预算内结算
	var res1 := pipeline.resolve_reaction(100.0, 1.5, ctx)
	assert_true(res1 != null and not res1.deferred_merge, "T4: 预算充足时反应应立即结算")
	
	# 强制耗尽本帧预算
	pipeline._settle_left = 0
	var ctx2 := DamageContext.make()
	ctx2.source_uid = 2
	ctx2.target = dummy_enemy
	ctx2.target_uid = 1001
	ctx2.frame_stamp = 1
	ctx2.element = GameConst.ReactionType.RXN_FIR_LTG
	ctx2.pos = Vector2(100.0, 100.0)
	
	var res2 := pipeline.resolve_reaction(100.0, 1.5, ctx2)
	assert_true(res2 != null and res2.deferred_merge, "T4: 预算耗尽时保帧模式反应应顺延")
	
	# 冲刷次帧
	pipeline.begin_frame(2, true)
	assert_true(pipeline._pending_fifo.is_empty(), "T4: 次帧冲刷后顺延队列应已结清")
	
	DamagePipeline.settle_budget_override = orig_budget
	PerfGovernor.boost_override = orig_ov
	dummy_enemy.free()


func test_t5_reaction_damping() -> void:
	var orig_ov := PerfGovernor.boost_override
	PerfGovernor.boost_override = 1
	var elem_sys := ElementalSystem.new()
	GameConfig.frame_stamp = 10
	
	var d1 := elem_sys._get_rxn_damping_factor(999)
	assert_eq(d1, 1.0, "T5: 首次反应阻尼系数为 1.0")
	var d2 := elem_sys._get_rxn_damping_factor(999)
	assert_eq(d2, 0.6, "T5: 同帧第2次反应阻尼系数为 0.6")
	var d3 := elem_sys._get_rxn_damping_factor(999)
	assert_eq(d3, 0.35, "T5: 同帧第3次反应阻尼系数为 0.35")
	
	# 换帧重置
	GameConfig.frame_stamp = 11
	var d4 := elem_sys._get_rxn_damping_factor(999)
	assert_eq(d4, 1.0, "T5: 换帧后阻尼计数器自动重置为 1.0")
	
	# 保帧模式关闭
	PerfGovernor.boost_override = 0
	var d5 := elem_sys._get_rxn_damping_factor(999)
	var d6 := elem_sys._get_rxn_damping_factor(999)
	assert_eq(d5, 1.0, "T5: 保帧模式关闭时阻尼恒为 1.0")
	assert_eq(d6, 1.0, "T5: 保帧模式关闭时二次阻尼恒为 1.0")
	
	PerfGovernor.boost_override = orig_ov
	elem_sys.free()


func test_t6_viewport_culling() -> void:
	# 视口范围为 (-64, -64) ~ (784, 1344)
	assert_true(PopupManager.is_in_viewport(Vector2(100.0, 100.0)), "T6: 视口内点正常判定")
	assert_true(PopupManager.is_in_viewport(Vector2(700.0, 1200.0)), "T6: 视口边缘内点正常判定")
	assert_false(PopupManager.is_in_viewport(Vector2(2000.0, 500.0)), "T6: 远离视口点判定在视口外")
	assert_false(PopupManager.is_in_viewport(Vector2(-200.0, 500.0)), "T6: 负坐标点判定在视口外")


func test_t7_cluster_merging() -> void:
	var r_normal := DamageResult.new()
	r_normal.target_tags = 0
	r_normal.is_crit = false
	r_normal.popup_style = GameConst.PopupStyle.NORMAL
	assert_false(PopupManager._is_cluster_exempt(r_normal), "T7: 普通小怪直击应当参与分簇汇聚")
	
	var r_boss := DamageResult.new()
	r_boss.target_tags = GameConst.TAG_BOSS
	r_boss.is_crit = false
	r_boss.popup_style = GameConst.PopupStyle.NORMAL
	assert_true(PopupManager._is_cluster_exempt(r_boss), "T7: Boss 伤害必须强制豁免分簇")
	
	var r_elite := DamageResult.new()
	r_elite.target_tags = GameConst.TAG_ELITE
	r_elite.is_crit = false
	r_elite.popup_style = GameConst.PopupStyle.NORMAL
	assert_true(PopupManager._is_cluster_exempt(r_elite), "T7: 精英怪伤害必须强制豁免分簇")
	
	var r_crit := DamageResult.new()
	r_crit.target_tags = 0
	r_crit.is_crit = true
	r_crit.popup_style = GameConst.PopupStyle.CRIT
	assert_true(PopupManager._is_cluster_exempt(r_crit), "T7: 暴击伤害必须强制豁免分簇")
	
	var r_rxn := DamageResult.new()
	r_rxn.target_tags = 0
	r_rxn.popup_style = GameConst.PopupStyle.REACTION
	assert_true(PopupManager._is_cluster_exempt(r_rxn), "T7: 反应大字必须强制豁免分簇")


func test_t8_reaction_size_cache() -> void:
	var sz2 := DamagePopup.get_cached_reaction_size("超载")
	assert_eq(sz2, Vector2(136.0, 80.0), "T8: 2字反应预设尺寸准确")
	var sz4 := DamagePopup.get_cached_reaction_size("感电连锁")
	assert_eq(sz4, Vector2(210.0, 80.0), "T8: 4字反应预设尺寸准确")


func test_t9_rng_zero_shift() -> void:
	# 校验全局 RNG 在执行策略各方法后保持零位移
	seed(42)
	var expected_rng_seq: Array[int] = []
	for i in range(10):
		expected_rng_seq.append(randi())
		
	# 重新重置为 42
	seed(42)
	# 执行一系列策略调用
	var _active := PerfGovernor.strategic_boost_active()
	var _sz := DamagePopup.get_cached_reaction_size("超载")
	var _in_vp := PopupManager.is_in_viewport(Vector2(500.0, 500.0))
	var dummy_res := DamageResult.new()
	var _exempt := PopupManager._is_cluster_exempt(dummy_res)
	
	var actual_rng_seq: Array[int] = []
	for i in range(10):
		actual_rng_seq.append(randi())
		
	assert_eq(actual_rng_seq, expected_rng_seq, "T9: 策略降载模块零调用全局 RNG，验证序列逐位一致")

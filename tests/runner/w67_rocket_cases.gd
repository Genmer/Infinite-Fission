# tests/runner/w67_rocket_cases.gd
# W6/W7 双火箭 30% 规格用例体（由 test_w67_rocket.gd 入口在 autoload 就绪后运行时加载编译）。
# 覆盖（R187 五方向定案「rockets」验收 1~5 / 6 项）：
#   ① 比例断言：W6 blast_r 级表 [30,32,34,36,38] 对 W7 110 → 逐级 ∈[0.25,0.36] 均值 ∈[0.27,0.34]；
#      溅射比 0.6×atk 对 W7 atk ≤0.40 均值 ∈[0.28,0.33]；W7 现网字段冻结 + TH_SIZE_NOVA 保留；
#      W6 阈值分叉（TH_SWARM_NOVA 换入 / TH_SIZE_NOVA 换出 / CRIT_SHARD 0.35）
#   ② 齐射行为：L5 对 3 dummy 单节拍 3 弹 target_uid 互异（第 i 发锁第 i 近）；对 1 dummy
#      余弹 ×0.6^j 直击递减；HIVE_RACK×2 → 5 枚硬顶；池满弃发计数；池空返回 false 不崩
#   ②+ TH_SWARM_NOVA 空爆行为（volley≥5 → 1.2×blast_r / 30%ATK）
#   ③ 引信连携：FUSE_COAT×2 直击挂引信 4s 幂等；引信敌受自导爆炸 ×1.4；
#      FUSE_DETONATE×2 追加恰一次 2×0.5×atk 且 0.5s 护栏内无第二次
#   ④ validator 负例：volley_count 域 / blast_r_levels 域 / blast_atk_ratio 域 / _levels 长度
#   ⑤ R183 折减 + 预算：副本 volley_eff==1 / sub_eff==min(sub,3)；满配双火箭+双副本
#      tick 10s 在场弹峰值≤64；池压丢弃计数可读
#   ⑥ 爆径<50 → 震屏 HIT 档（真实 GameLoop missile_blast 订阅者探针）
# 确定性：固定坐标/固定参数、crit_rate=0（stub 直算无掷骰）、夹具用真 .tres 词条
#（MEC_HIVE_RACK / MEC_FUSE_COAT / MEC_FUSE_DETONATE），敌侧引信通道直读 enemy.gd 字段。
extends RefCounted

const HOMING_SCENE := "res://scenes/combat/projectiles/homing_projectile.tscn"
const ENEMY_SCENE := "res://scenes/combat/enemies/enemy.tscn"
const MAIN_SCENE := "res://scenes/main.tscn"
const W6_PATH := "res://resources/weapons/W6_micro_missile.tres"
const W7_PATH := "res://resources/weapons/W7_cluster_rocket.tres"
const RACK_PATH := "res://resources/traits/MEC_HIVE_RACK.tres"
const COAT_PATH := "res://resources/traits/MEC_FUSE_COAT.tres"
const DETONATE_PATH := "res://resources/traits/MEC_FUSE_DETONATE.tres"
const DT := 1.0 / 60.0

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _wd_counter: int = 0                       # 夹具 WeaponData id 确定性计数器

var _homing_pool: ProjectilePool
var _enemy_pool: EnemyPool
var _grid: SpaceGrid
var _capture: CapturePipeline                  # 结算捕获（records：uid/base/flags）
var _alive_enemies: Array[Node2D] = []
var _weapons: Array[WeaponBase] = []           # 夹具武器（teardown 统一回收防泄漏）


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_test_data_ratio_spec()                        # ①
	_setup_world()
	_test_volley_targets_and_fan()                 # ② A：第 i 近索敌 + 出膛扇
	_teardown_world()
	_setup_world()
	_test_volley_fallback_damage()                 # ② B：余弹 ×0.6^j 直击递减
	_teardown_world()
	_setup_world()
	_test_hive_rack_and_pool_full()                # ② C：HIVE_RACK 硬顶 + 池满弃发/池空 false
	_teardown_world()
	_setup_world()
	_test_swarm_nova()                             # ② D：TH_SWARM_NOVA 空爆
	_teardown_world()
	_setup_world()
	_test_fuse_coat()                              # ③ A：挂引信幂等 + 引信敌 ×1.4
	_teardown_world()
	_setup_world()
	_test_fuse_detonate()                          # ③ B：引爆余波恰一次 + 0.5s 护栏
	_teardown_world()
	_test_validator_negatives()                    # ④
	_setup_world()
	await _test_r183_and_budget()                  # ⑤
	_teardown_world()
	await _test_blast_feel_tier()                  # ⑥
	_summary()


func fail_count() -> int:
	return _fail


# ── ① 30% 规格比例断言（数据级，load 现网 .tres） ─────────────────
func _test_data_ratio_spec() -> void:
	print("── ① 30% 规格比例断言（数据级） ──")
	var w6 := load(W6_PATH) as WeaponData
	var w7 := load(W7_PATH) as WeaponData
	_check("前置：W6/W7 .tres 加载", w6 != null and w7 != null)
	if w6 == null or w7 == null:
		return
	# 爆径比：W6 blast_r_levels 对 W7 110
	var blast_levels: Array = w6.homing.get("blast_r_levels", [])
	var ratios: Array[float] = []
	var ratio_ok := blast_levels.size() == 5
	if ratio_ok:
		for v in blast_levels:
			var r := float(v) / 110.0
			ratios.append(r)
			ratio_ok = ratio_ok and r >= 0.25 and r <= 0.36
	_check("爆径比逐级 ∈[0.25,0.36]（[30,32,34,36,38] / 110）",
		ratio_ok, str(blast_levels))
	var r_mean := _mean(ratios)
	_check("爆径比均值 ∈[0.27,0.34]（30.9% 锚）", r_mean >= 0.27 and r_mean <= 0.34,
		"%.4f" % r_mean)
	# 溅射比：0.6×W6_atk 对 W7 atk（1.0×）
	var splash: Array[float] = []
	var splash_ok := true
	for i in range(5):
		var sr := 0.6 * float(w6.upgrade_table[i].base_atk) / float(w7.upgrade_table[i].base_atk)
		splash.append(sr)
		splash_ok = splash_ok and sr <= 0.40
	_check("溅射比逐级 ≤0.40（blast_atk_ratio 0.6 直算）", splash_ok, str(splash))
	var s_mean := _mean(splash)
	_check("溅射比均值 ∈[0.28,0.33]（30.0% 锚）", s_mean >= 0.28 and s_mean <= 0.33,
		"%.4f" % s_mean)
	_check("W6 blast_atk_ratio == 0.6",
		is_equal_approx(float(w6.homing.get("blast_atk_ratio", 0.0)), 0.6))
	_check("W7 blast_atk_ratio == 1.0（现网口径显式化）",
		is_equal_approx(float(w7.homing.get("blast_atk_ratio", 0.0)), 1.0))
	_check("W6 proj_speed_init 240→420（手感矛盾修复）",
		is_equal_approx(float(w6.homing.get("proj_speed_init", 0.0)), 420.0))
	_check("W6 volley_count_levels == [1,1,2,2,3]",
		_float_array_eq(w6.homing.get("volley_count_levels", []),
			[1.0, 1.0, 2.0, 2.0, 3.0]),
		str(w6.homing.get("volley_count_levels", [])))
	# 阈值分叉（身份线）
	_check("W6 含 TH_SWARM_NOVA", _has_threshold(w6, &"TH_SWARM_NOVA"))
	_check("W6 不含 TH_SIZE_NOVA（换出）", not _has_threshold(w6, &"TH_SIZE_NOVA"))
	_check("W6 TH_CRIT_SHARD 0.6→0.35",
		is_equal_approx(_threshold_value(w6, &"TH_CRIT_SHARD"), 0.35))
	var swarm := _threshold_of(w6, &"TH_SWARM_NOVA")
	var swarm_params: Dictionary = swarm.get("params", {})
	_check("TH_SWARM_NOVA 声明：volley_count≥5 → 1.2×blast_r / 30%ATK",
		is_equal_approx(float(swarm.get("threshold", 0.0)), 5.0)
		and StringName(str(swarm.get("effect_id", ""))) == &"EF_SWARM_NOVA"
		and is_equal_approx(float(swarm_params.get("radius_mult", 0.0)), 1.2)
		and is_equal_approx(float(swarm_params.get("atk_ratio", 0.0)), 0.3))
	# W7 现网冻结（新增 blast_atk_ratio 外全字段不动 + 阈值保留声明）
	_check("W7 保留 TH_SIZE_NOVA/FRACTAL_ECHO/BOUNCE_ETERNAL（身份线）",
		_has_threshold(w7, &"TH_SIZE_NOVA") and _has_threshold(w7, &"TH_FRACTAL_ECHO")
		and _has_threshold(w7, &"TH_BOUNCE_ETERNAL"))
	# R187 §2.1.10 全武器共享死节点修复：TH_CRIT_SHARD 0.6→0.35（含 W7——评审裁定
	# 「唯一漏点」翻转；身份线三条 TH_SIZE_NOVA/FRACTAL_ECHO/BOUNCE_ETERNAL 保留不动）
	_check("W7 TH_CRIT_SHARD 0.6→0.35（全武器共享死节点修复）",
		is_equal_approx(_threshold_value(w7, &"TH_CRIT_SHARD"), 0.35))
	var atk_ok := true
	var atk_exp: Array[float] = [38.0, 38.0, 46.0, 54.0, 68.0]
	for i in range(5):
		atk_ok = atk_ok and is_equal_approx(float(w7.upgrade_table[i].base_atk), atk_exp[i])
	_check("W7 atk 表冻结 [38,38,46,54,68]", atk_ok)
	_check("W7 blast_r=110 / sub_count=5 / sub 180/600 冻结",
		is_equal_approx(float(w7.homing.get("blast_r", 0.0)), 110.0)
		and int(w7.homing.get("sub_count", 0)) == 5
		and is_equal_approx(float(w7.homing.get("sub_speed_init", 0.0)), 180.0)
		and is_equal_approx(float(w7.homing.get("sub_accel", 0.0)), 600.0))
	_check("W7 sub_count_levels 冻结 [5,6,6,8,8]",
		_float_array_eq(w7.homing.get("sub_count_levels", []),
			[5.0, 6.0, 6.0, 8.0, 8.0]))
	# validator 正控：现网双 .tres 零 error（新键校验/通用 _levels 补口下存活）
	var v := DataValidator.new()
	_check("validator 正控：W6 零 error", _error_count(v.validate_weapon(w6)) == 0,
		str(v.validate_weapon(w6)))
	_check("validator 正控：W7 零 error", _error_count(v.validate_weapon(w7)) == 0,
		str(v.validate_weapon(w7)))


# ── ② A：齐射目标分配 + 出膛扇 ────────────────────────────────────
func _test_volley_targets_and_fan() -> void:
	print("── ② 齐射行为 A：第 i 发锁第 i 近 + ±10° 出膛扇 ──")
	var w6 := _make_w6_l5()
	var d1 := _spawn_enemy(Vector2(360, 600))     # 300px 最近
	var d2 := _spawn_enemy(Vector2(360, 450))     # 450px
	var d3 := _spawn_enemy(Vector2(360, 300))     # 600px 最远
	_check("L5 对 3 dummy：try_fire 成功且 volley_eff==3",
		w6.try_fire() and w6.volley_eff == 3, str(w6.volley_eff))
	var missiles := _live_missiles()
	_check("L5 对 3 dummy 单节拍 3 弹", missiles.size() == 3, str(missiles.size()))
	var uid_set := {}
	for m in missiles:
		uid_set[int((m as HomingProjectile).target_uid)] = true
	_check("3 弹 target_uid 互异", uid_set.size() == 3, str(uid_set))
	var by_dist: Array = [d1, d2, d3]              # 布点即距离升序
	var order_ok := missiles.size() == 3
	for i in range(missiles.size()):
		var m := missiles[i] as HomingProjectile
		var rank := -1
		for j in range(by_dist.size()):
			if int((by_dist[j] as Node2D).get("uid")) == m.target_uid:
				rank = j
				break
		order_ok = order_ok and rank == i
	_check("第 i 发锁第 i 近目标（距离升序累计排除）", order_ok)
	if missiles.size() == 3:
		var v0 := (missiles[0] as HomingProjectile).velocity.normalized()
		var v1 := (missiles[1] as HomingProjectile).velocity.normalized()
		var v2 := (missiles[2] as HomingProjectile).velocity.normalized()
		_check("出膛扇 ±10° 均布（中位 0°，两翼 ±10°）",
			is_equal_approx(rad_to_deg(Vector2.UP.angle_to(v1)), 0.0)
			and is_equal_approx(absf(rad_to_deg(Vector2.UP.angle_to(v0))), 10.0)
			and is_equal_approx(absf(rad_to_deg(Vector2.UP.angle_to(v2))), 10.0),
			"%.2f/%.2f/%.2f" % [rad_to_deg(Vector2.UP.angle_to(v0)),
				rad_to_deg(Vector2.UP.angle_to(v1)), rad_to_deg(Vector2.UP.angle_to(v2))])
	_nullify_missiles()


# ── ② B：目标不足余弹退回最近目标 ×0.6^j 直击递减 ─────────────────
func _test_volley_fallback_damage() -> void:
	print("── ② 齐射行为 B：余弹 ×0.6^j 直击递减 ──")
	var w6 := _make_w6_l5()
	var dummy := _spawn_enemy(Vector2(360, 600))  # 唯一目标
	_check("前置：try_fire 成功（3 弹全轮）", w6.try_fire())
	var missiles := _live_missiles()
	_check("对 1 dummy 单节拍 3 弹（余弹退回最近目标）", missiles.size() == 3,
		str(missiles.size()))
	var mults: Array[float] = []
	var all_on_dummy := missiles.size() == 3
	for m in missiles:
		var hp := m as HomingProjectile
		mults.append(hp.direct_mult)
		all_on_dummy = all_on_dummy and int(hp.target_uid) == int(dummy.get("uid"))
	mults.sort()
	_check("余弹直击乘子 = [0.36, 0.6, 1.0]（×0.6^j）",
		mults.size() == 3 and is_equal_approx(mults[0], 0.36) \
			and is_equal_approx(mults[1], 0.6) and is_equal_approx(mults[2], 1.0),
		str(mults))
	_check("3 弹 target_uid 全部=最近 dummy", all_on_dummy)
	# 驱动飞行至 3 次直击结算（单一目标：主弹自爆排除、无溅射项干扰）
	var finals: Array = []
	for i in range(900):
		_advance_missiles(DT)
		finals = _record_bases_for(int(dummy.get("uid")))
		if finals.size() >= 3:
			break
	finals.sort()
	var seq_ok := finals.size() == 3
	if seq_ok:
		seq_ok = absf(float(finals[0]) - 32.0 * 0.36) <= 1.0 \
			and absf(float(finals[1]) - 32.0 * 0.6) <= 1.0 \
			and absf(float(finals[2]) - 32.0) <= 1.0
	_check("伤害序列 = atk×[1.0,0.6,0.36]±1", seq_ok, str(finals))


# ── ② C：HIVE_RACK 硬顶 5 枚 + 池满弃发/池空 false ────────────────
func _test_hive_rack_and_pool_full() -> void:
	print("── ② 齐射行为 C：HIVE_RACK×2 → 5 枚硬顶 + 池审计 ──")
	var w6 := _make_w6_l5()
	_spawn_enemy(Vector2(360, 600))
	var rack := load(RACK_PATH) as TraitData
	_check("前置：MEC_HIVE_RACK 词条在册", rack != null)
	w6.attach_trait(rack)
	w6.attach_trait(rack)
	_check("HIVE_RACK×2 → volley_eff==5（L5 基线 3+2，clamp[1,5] 内）",
		w6.try_fire() and w6.volley_eff == 5, str(w6.volley_eff))
	_check("单节拍 5 弹（硬顶 5 枚/轮）", _live_missiles().size() == 5,
		str(_live_missiles().size()))
	_nullify_missiles()
	# 小池弃发：容量 4 → 齐射 5 枚弃 1 弹（计数可读）；全占用再射 → false 不崩
	var drops_before := DebugStats.get_counter(&"homing_volley_dropped")
	var mini := ProjectilePool.new()
	mini.name = "W67MiniPool"
	tree.get_root().add_child(mini)
	mini.setup(&"w67_mini", load(HOMING_SCENE), 4)
	var w6m := _make_w6_l5()
	var rack2 := load(RACK_PATH) as TraitData
	w6m.attach_trait(rack2)
	w6m.attach_trait(rack2)                       # 齐射 5（3+2）——超容量触发弃发
	w6m.homing_pool = mini                        # 换绑小池（setup deps 注入口同语义）
	_check("池容 4：try_fire 仍成功（4 发出膛 + 1 弃发）",
		w6m.try_fire() and mini._live_order.size() == 4,
		str(mini._live_order.size()))
	_check("池满弃发计数 +1（homing_volley_dropped 可读）",
		DebugStats.get_counter(&"homing_volley_dropped") == drops_before + 1,
		str(DebugStats.get_counter(&"homing_volley_dropped")))
	_check("池空（4/4 占用）：try_fire 返回 false 不崩",
		(not w6m.try_fire()) and mini._live_order.size() == 4)
	_check("池空弃发计数再 +1",
		DebugStats.get_counter(&"homing_volley_dropped") == drops_before + 2)
	mini.free()                                    # 小池（含 4 活弹——free 级联，不入池审计）


# ── ② D：TH_SWARM_NOVA 空爆（volley≥5 → 1.2×blast_r / 30%ATK） ────
func _test_swarm_nova() -> void:
	print("── ② 齐射行为 D：TH_SWARM_NOVA 空爆 ──")
	var th := [{
		"threshold_id": &"TH_SWARM_NOVA", "metric": "volley_count", "threshold": 5.0,
		"effect_id": &"EF_SWARM_NOVA", "params": {"radius_mult": 1.2, "atk_ratio": 0.3},
	}]
	var data := _make_homing_data(32.0, {
		"proj_speed_init": 420.0, "proj_speed_max": 720.0, "accel": 900.0,
		"turn_rate": 480.0, "arm_delay": 0.15, "blast_r": 38.0, "blast_falloff": 0.6,
		"blast_atk_ratio": 0.6,
	}, th)
	var w := _make_homing_weapon(data, Vector2(360, 900))
	w.level = 5
	var primary := _spawn_enemy(Vector2(500, 300))
	var near := _spawn_enemy(Vector2(540, 300))   # 40px：爆径 38 外、空爆 1.2×38=45.6 内
	var proj := _spawn_missile(w, {"blast_radius": 38.0, "volley_size": 5})
	proj.global_position = primary.global_position
	var mark := _capture.records.size()
	proj._maybe_swarm_nova(primary)               # 直击主目标排除口径同 TH_SIZE_NOVA
	var near_recs := _records_since(near, mark)
	_check("空爆：volley≥5 → 每枚 1.2×blast_r 半径冲击波（38→45.6 覆盖 40px 圈）",
		near_recs.size() == 1, str(near_recs))
	_check("空爆伤害 = 30%ATK（32×0.3=9.6，settle_aoe 平方无衰减口径）",
		near_recs.size() == 1 and absf(float(near_recs[0].get("base", 0.0)) - 9.6) <= 0.2,
		str(near_recs))
	_check("空爆旗标 AOE_SECONDARY + 排除直击主目标",
		near_recs.size() == 1 and _has_flag(near_recs[0], GameConst.HIT_IS_AOE_SECONDARY)
		and _records_since(primary, mark).is_empty())
	# 负例 1：volley<5 不触发
	var proj2 := _spawn_missile(w, {"blast_radius": 38.0, "volley_size": 3})
	proj2.global_position = primary.global_position
	var mark2 := _capture.records.size()
	proj2._maybe_swarm_nova(primary)
	_check("负例：volley_size=3 < 阈值 5 → 无空爆",
		_records_since(near, mark2).is_empty())
	# 负例 2：武器无 TH_SWARM_NOVA 声明不触发
	var plain := _make_homing_data(32.0, {
		"proj_speed_init": 420.0, "proj_speed_max": 720.0, "accel": 900.0,
		"turn_rate": 480.0, "arm_delay": 0.15, "blast_r": 38.0, "blast_falloff": 0.6,
	})
	var wp := _make_homing_weapon(plain, Vector2(360, 900))
	var proj3 := _spawn_missile(wp, {"blast_radius": 38.0, "volley_size": 5})
	proj3.global_position = primary.global_position
	var mark3 := _capture.records.size()
	proj3._maybe_swarm_nova(primary)
	_check("负例：武器无 TH_SWARM_NOVA 阈值 → 无空爆",
		_records_since(near, mark3).is_empty())
	_nullify_missiles()


# ── ③ A：引信涂层（直击挂 4s 幂等 + 引信敌自导爆炸 ×1.4） ─────────
func _test_fuse_coat() -> void:
	print("── ③ 引信 A：FUSE_COAT×2 挂引信幂等 + 引信敌爆炸 ×1.4 ──")
	var coat := load(COAT_PATH) as TraitData
	_check("前置：MEC_FUSE_COAT 词条在册", coat != null)
	var data := _make_homing_data(32.0, {
		"proj_speed_init": 420.0, "proj_speed_max": 720.0, "accel": 900.0,
		"turn_rate": 480.0, "arm_delay": 0.15, "blast_r": 40.0, "blast_falloff": 0.6,
		"blast_atk_ratio": 0.6,
	})
	var w := _make_homing_weapon(data, Vector2(360, 900))
	w.attach_trait(coat)
	w.attach_trait(coat)
	# 布点：A(500,300) 主靶；B(528,300)/C(472,300) 左右对称 28px（出膛上漂 ~4px 后
	# 两者到爆心等距 → scale 同为 ~0.717，比值检验干净）
	var a := _spawn_enemy(Vector2(500, 300))
	var b := _spawn_enemy(Vector2(528, 300))
	var c := _spawn_enemy(Vector2(472, 300))
	# 第一轮：直击 B（挂引信）
	var p1 := _spawn_missile(w, {"blast_radius": 40.0})
	p1.global_position = b.global_position
	_advance_missiles(DT)
	_check("FUSE_COAT×2 直击命中后 fuse_mark_left>0（敌侧通道，4s）",
		is_equal_approx(float(b.get("fuse_mark_left")), 4.0),
		str(b.get("fuse_mark_left")))
	# 第二轮：直击 A → B（引信在身）溅射 ×1.4，C（无引信）×1.0 对照
	var p2 := _spawn_missile(w, {"blast_radius": 40.0})
	p2.global_position = a.global_position
	_advance_missiles(DT)
	var b_base := _last_secondary_base(b)
	var c_base := _last_secondary_base(c)
	_check("引信敌受自导爆炸 ×1.4（0.6×0.717×1.4×32≈19.3）",
		absf(b_base - 32.0 * 0.6 * 0.717 * 1.4) <= 0.4, "%.3f" % b_base)
	_check("无引信对照 ×1.0（0.6×0.717×32≈13.8）",
		absf(c_base - 32.0 * 0.6 * 0.717) <= 0.4, "%.3f" % c_base)
	_check("引信乘区比 == 1.4±0.01", c_base > 0.0 and absf(b_base / c_base - 1.4) <= 0.01,
		"%.4f" % (b_base / c_base))
	# 幂等：再次直击 B → 引信续 4s 不叠加
	var p3 := _spawn_missile(w, {"blast_radius": 40.0})
	p3.global_position = b.global_position
	_advance_missiles(DT)
	_check("幂等：直击已引信敌 → fuse_mark_left 恒 4.0（不叠加不翻倍）",
		is_equal_approx(float(b.get("fuse_mark_left")), 4.0),
		str(b.get("fuse_mark_left")))
	_check("前置对照：三靶 id 可解析", int(a.get("uid")) > 0 and int(b.get("uid")) > 0
		and int(c.get("uid")) > 0)
	_nullify_missiles()


# ── ③ B：定向爆破（W7 消耗引信追加 0.5/层×atk 余波 + 0.5s 护栏） ──
func _test_fuse_detonate() -> void:
	print("── ③ 引信 B：FUSE_DETONATE×2 追加恰一次 2×0.5×atk + 0.5s 护栏 ──")
	var coat := load(COAT_PATH) as TraitData
	var detonate := load(DETONATE_PATH) as TraitData
	_check("前置：MEC_FUSE_COAT/MEC_FUSE_DETONATE 词条在册", coat != null and detonate != null)
	# W6 铺设枪（coat×2，爆径 40）+ W7 引爆枪（detonate×2，爆径 110）
	var data6 := _make_homing_data(32.0, {
		"proj_speed_init": 420.0, "proj_speed_max": 720.0, "accel": 900.0,
		"turn_rate": 480.0, "arm_delay": 0.15, "blast_r": 40.0, "blast_falloff": 0.6,
		"blast_atk_ratio": 0.6,
	})
	var w6 := _make_homing_weapon(data6, Vector2(360, 900))
	w6.attach_trait(coat)
	w6.attach_trait(coat)
	var data7 := _make_homing_data(68.0, {
		"proj_speed_init": 300.0, "proj_speed_max": 720.0, "accel": 900.0,
		"turn_rate": 480.0, "arm_delay": 0.15, "blast_r": 110.0, "blast_falloff": 0.6,
		"blast_atk_ratio": 1.0,
	})
	var w7 := _make_homing_weapon(data7, Vector2(360, 900))
	w7.attach_trait(detonate)
	w7.attach_trait(detonate)
	var d := _spawn_enemy(Vector2(500, 300))      # W7 主靶
	var e := _spawn_enemy(Vector2(560, 300))      # 60px：t=0.545 → scale 0.782
	# 铺设：W6 直击 E → 引信 4s
	var p0 := _spawn_missile(w6, {"blast_radius": 40.0})
	p0.global_position = e.global_position
	_advance_missiles(DT)
	_check("前置：E 已挂引信（fuse_mark_left=4）",
		is_equal_approx(float(e.get("fuse_mark_left")), 4.0))
	# 引爆：W7 直击 D → E 溅射（68×1.0×0.782×1.4=74.4）+ 余波（68×0.5×2=68 恰一次）
	var p1 := _spawn_missile(w7, {"blast_radius": 110.0})
	p1.global_position = d.global_position
	_advance_missiles(DT)
	var recs := _records_since(e, 0).slice(-2)
	# §2.3.5 目标侧标记口径（评审 R10）：amp 随涂层标记落敌身——W7 引爆溅射命中引信敌
	# 同享 ×1.4（双卡连携通道；余波按自身公式 0.5/层×ATK 定额不叠 amp）
	_check("引信敌受 W7 溅射 ×1.4（涂层标记随敌身，74.4）",
		recs.size() >= 1 and absf(float(recs[0].get("base", 0.0)) - 68.0 * 0.782 * 1.4) <= 0.7,
		str(recs))
	_check("FUSE_DETONATE×2 追加恰一次 2×0.5×atk=68（0.5s 护栏首窗）",
		recs.size() == 2 and absf(float(recs[1].get("base", 0.0)) - 68.0) <= 0.01
		and _has_flag(recs[1], GameConst.HIT_IS_AOE_SECONDARY), str(recs))
	_check("爆炸消耗引信：fuse_mark_left==0", is_equal_approx(float(e.get("fuse_mark_left")), 0.0),
		str(e.get("fuse_mark_left")))
	_check("护栏置位：fuse_detonate_guard_left==0.5（敌侧通道）",
		is_equal_approx(float(e.get("fuse_detonate_guard_left")), 0.5),
		str(e.get("fuse_detonate_guard_left")))
	# 护栏内：重挂引信后第二次 W7 爆炸 → 溅射有、余波无
	var p2 := _spawn_missile(w6, {"blast_radius": 40.0})
	p2.global_position = e.global_position
	_advance_missiles(DT)
	var mark := _capture.records.size()
	var p3 := _spawn_missile(w7, {"blast_radius": 110.0})
	p3.global_position = d.global_position
	_advance_missiles(DT)
	var recs2 := _records_since(e, mark)
	_check("0.5s 护栏内无第二次：仅溅射 1 条（×1.4）、无追加余波",
		recs2.size() == 1 and absf(float(recs2[0].get("base", 0.0)) - 68.0 * 0.782 * 1.4) <= 0.7,
		str(recs2))
	# 护栏过期（敌侧通道计时推进替身——enemy.gd tick 衰减归共享组）：第三次爆炸余波恢复
	e.set("fuse_detonate_guard_left", 0.0)
	var mark2 := _capture.records.size()
	var p4 := _spawn_missile(w7, {"blast_radius": 110.0})
	p4.global_position = d.global_position
	_advance_missiles(DT)
	var recs3 := _records_since(e, mark2)
	_check("护栏过期后余波恢复（恰一次 68）",
		recs3.size() == 2 and absf(float(recs3[1].get("base", 0.0)) - 68.0) <= 0.01, str(recs3))
	_nullify_missiles()


# ── ④ validator 负例 ──────────────────────────────────────────────
func _test_validator_negatives() -> void:
	print("── ④ validator 负例（volley/blast_r_levels/blast_atk_ratio/_levels 长度） ──")
	var v := DataValidator.new()
	var base := _w6_seg()
	var cases := [
		{"name": "volley_count_levels[0]=0 <1（域 [1,5]）", "mut": {"volley_count_levels": [0.0, 1.0, 2.0, 2.0, 3.0]}, "field": "volley_count_levels"},
		{"name": "volley_count_levels[4]=6 >5（域 [1,5]）", "mut": {"volley_count_levels": [1.0, 1.0, 2.0, 2.0, 6.0]}, "field": "volley_count_levels"},
		{"name": "volley_count_levels 长度 4 ≠5（通用 _levels 补口）", "mut": {"volley_count_levels": [1.0, 1.0, 2.0, 2.0]}, "field": "volley_count_levels"},
		{"name": "blast_r_levels[0]=0（域 (0,128]）", "mut": {"blast_r_levels": [0.0, 32.0, 34.0, 36.0, 38.0]}, "field": "blast_r_levels"},
		{"name": "blast_r_levels[4]=200 >128（域 (0,128]）", "mut": {"blast_r_levels": [30.0, 32.0, 34.0, 36.0, 200.0]}, "field": "blast_r_levels"},
		{"name": "blast_atk_ratio=0（域 (0,1]）", "mut": {"blast_atk_ratio": 0.0}, "field": "blast_atk_ratio"},
		{"name": "blast_atk_ratio=1.5（域 (0,1]）", "mut": {"blast_atk_ratio": 1.5}, "field": "blast_atk_ratio"},
	]
	for c in cases:
		var seg := base.duplicate(true)
		var mut: Dictionary = c.get("mut")
		for k in mut:
			seg[k] = mut[k]
		var d := _make_homing_data(32.0, seg)
		var issues := v.validate_weapon(d)
		_check("validator 报 error：%s" % str(c.get("name")),
			_has_error_on(issues, String(c.get("field"))), str(issues))
	# 正控：合法段零 error（负例底座本身干净）
	var ok := v.validate_weapon(_make_homing_data(32.0, base))
	_check("validator 正控：负例底座（合法段）零 error", _error_count(ok) == 0, str(ok))


# ── ⑤ R183 复制体折减 + 发射预算 ──────────────────────────────────
func _test_r183_and_budget() -> void:
	print("── ⑤ R183 复制体折减 + 满配双火箭发射预算 ──")
	var player := StubPlayer.new()
	player.name = "W67StubPlayer"
	tree.get_root().add_child(player)
	var data6 := _make_homing_data(32.0, _w6_seg())
	var data7 := _make_homing_data(68.0, _w7_seg())
	var w6 := _make_homing_weapon(data6, Vector2(300, 640), player)
	w6.level = 5
	var w7 := _make_homing_weapon(data7, Vector2(420, 640), player)
	w7.level = 5
	var copy6 := _make_homing_weapon(data6, Vector2(300, 700), player)
	copy6.level = 5
	var copy7 := _make_homing_weapon(data7, Vector2(420, 700), player)
	copy7.level = 5
	var copies: Array[WeaponBase] = [copy6, copy7]
	player._summon_copies = copies
	for pos: Vector2 in [Vector2(360, 300), Vector2(360, 420), Vector2(520, 360)]:
		_spawn_enemy(pos)
	# 折减断言（本体先行开火——volley_eff/sub_eff 在开火期按当前等级/副本身份折算）
	_check("前置：W6 本体 volley_eff==3（L5 开火折算）",
		w6.try_fire() and w6.volley_eff == 3, str(w6.volley_eff))
	_check("前置：W7 本体 sub_eff==8（L5 开火折算）",
		w7.try_fire() and w7.sub_eff == 8, str(w7.sub_eff))
	_nullify_missiles()
	_check("R183：W6 副本 volley_eff==1（单发）",
		copy6.try_fire() and copy6.volley_eff == 1 and _live_missiles().size() == 1,
		"%d/%d" % [copy6.volley_eff, _live_missiles().size()])
	_check("R183：W7 副本 sub_eff==min(8,3)==3",
		copy7.try_fire() and copy7.sub_eff == 3, str(copy7.sub_eff))
	copy7._on_missile_impact(Vector2(400, 400), 110.0)
	var copy7_subs := 0
	for m in _live_missiles():
		var hp := m as HomingProjectile
		if hp.generation == 1 and hp.weapon_uid == copy7.uid:
			copy7_subs += 1
	_check("R183：W7 副本子弹头当轮 3 枚（折减生效）", copy7_subs == 3, str(copy7_subs))
	_nullify_missiles()
	# 预算：满配双火箭+双副本 tick 10s——在场弹峰值 ≤64（homing 池软上限）、弃发计数可读
	var weapons: Array = [w6, w7, copy6, copy7]
	var peak := 0
	for f in range(300):                           # 10s @ 30Hz
		GameConfig.advance_frame()
		for w in weapons:
			(w as WeaponBase).tick(1.0 / 30.0)
		_tick_missiles(1.0 / 30.0)
		peak = maxi(peak, _homing_pool.total_active())
	var drops := DebugStats.get_counter(&"homing_volley_dropped")
	_check("满配双火箭+双副本 tick 10s：在场弹峰值 ≤64", peak <= 64 and peak > 0,
		"peak=%d drops=%d" % [peak, drops])
	_check("丢弃计数可读（homing_volley_dropped）", drops >= 0, "drops=%d" % drops)
	# 池压审计：软上限压到 4 强制饱和（需求 ~30 发/s ≫ 4 槽）→ 弃发计数增长
	var drops_before := DebugStats.get_counter(&"homing_volley_dropped")
	_homing_pool.soft_limit = 4
	for f in range(90):                            # 3s 高压窗
		GameConfig.advance_frame()
		for w in weapons:
			(w as WeaponBase).tick(1.0 / 30.0)
		_tick_missiles(1.0 / 30.0)
	_check("池压饱和：homing_volley_dropped 增长（弃发计数可读且真实落账）",
		DebugStats.get_counter(&"homing_volley_dropped") > drops_before,
		"%d → %d" % [drops_before, DebugStats.get_counter(&"homing_volley_dropped")])
	player.free()                                  # StubPlayer（武器随 teardown 池回收）


# ── ⑥ 爆径<50 → 震屏 HIT 档（真实 GameLoop 订阅者探针） ───────────
func _test_blast_feel_tier() -> void:
	print("── ⑥ 爆径<50 震屏分档（GameLoop missile_blast 订阅者） ──")
	var scene: PackedScene = load(MAIN_SCENE)
	var gl := scene.instantiate() as GameLoop
	gl.name = "W67GameLoop"
	tree.get_root().add_child(gl)
	await tree.process_frame
	await tree.process_frame
	Meta.set_setting("shake_on", true)
	var feel := gl.game_feel
	var ready_ok := feel != null and feel.shake != null and feel.feel_config != null
	_check("前置：GameLoop game_feel/shake/feel_config 就绪", ready_ok)
	if ready_ok:
		feel.shake.trauma = 0.0
		EventBus.emit_missile_blast(Vector2(360, 400), 40.0)   # W6 档（<50）
		var d_small := feel.shake.trauma
		feel.shake.trauma = 0.0
		EventBus.emit_missile_blast(Vector2(360, 400), 110.0)  # W7 档（≥50）
		var d_big := feel.shake.trauma
		_check("blast_r=40（<50）→ 震屏 HIT 档（trauma 0.15）",
			is_equal_approx(d_small, 0.15), "%.3f" % d_small)
		_check("blast_r=110（≥50）→ 震屏 CRIT 档（trauma 0.4）",
			is_equal_approx(d_big, 0.4), "%.3f" % d_big)
	tree.paused = false
	RunSave.clear()
	gl.free()


# ── 夹具 ──────────────────────────────────────────────────────────
func _w6_seg() -> Dictionary:
	return {
		"proj_speed_init": 420.0, "proj_speed_max": 720.0, "accel": 900.0,
		"turn_rate": 480.0, "arm_delay": 0.15, "blast_r": 38.0, "blast_falloff": 0.6,
		"blast_atk_ratio": 0.6,
		"volley_count_levels": [1.0, 1.0, 2.0, 2.0, 3.0],
		"blast_r_levels": [30.0, 32.0, 34.0, 36.0, 38.0],
	}


func _w7_seg() -> Dictionary:
	return {
		"proj_speed_init": 300.0, "proj_speed_max": 720.0, "accel": 900.0,
		"turn_rate": 480.0, "arm_delay": 0.15, "blast_r": 110.0, "blast_falloff": 0.6,
		"blast_atk_ratio": 1.0,
		"sub_count": 0, "sub_count_levels": [5.0, 6.0, 6.0, 8.0, 8.0],
		"sub_speed_init": 180.0, "sub_accel": 600.0,
	}


func _setup_world(p_capacity: int = 96, p_soft: int = 64) -> void:
	_homing_pool = ProjectilePool.new()
	_homing_pool.name = "W67HomingPool"
	tree.get_root().add_child(_homing_pool)
	_homing_pool.setup(&"w67_homing", load(HOMING_SCENE), p_capacity)
	_homing_pool.soft_limit = p_soft
	_homing_pool.hard_limit = 96
	var ep := EnemyPool.new()
	ep.name = "W67EnemyPool"
	tree.get_root().add_child(ep)
	ep.setup(&"w67_enemy", load(ENEMY_SCENE), 32)
	_enemy_pool = ep
	_grid = SpaceGrid.new()
	_grid.configure(Vector2(720, 1280), 192.0)
	_capture = CapturePipeline.new()
	_alive_enemies.clear()
	_weapons.clear()


func _teardown_world() -> void:
	_alive_enemies.clear()
	for w in _weapons:
		if w != null and is_instance_valid(w):
			w.free()
	_weapons.clear()
	if _homing_pool != null:
		_homing_pool.free()
		_homing_pool = null
	if _enemy_pool != null:
		_enemy_pool.free()
		_enemy_pool = null
	_grid = null
	_capture = null


func _make_homing_data(p_atk: float, p_segment: Dictionary,
		p_thresholds: Array = []) -> WeaponData:
	_wd_counter += 1
	var d := WeaponData.new()
	d.id = StringName("W67_TEST_%d" % _wd_counter)
	d.display_name = "W67 测试自导 %d" % _wd_counter
	d.form = GameConst.WeaponForm.HOMING
	d.crit_rate = 0.0                             # stub 直算无掷骰（确定性）
	d.crit_dmg = 2.0
	d.hitbox_r = 6.0
	for i in range(5):
		var ls := WeaponLevelStats.new()
		ls.base_atk = p_atk
		ls.rof = 2.0
		ls.cd = 0.5
		ls.pierce = 1
		ls.pellets = 1
		d.upgrade_table.append(ls)
	d.homing = p_segment
	for th in p_thresholds:
		d.threshold_traits.append(th)
	return d


func _make_homing_weapon(p_data: WeaponData, p_pos: Vector2,
		p_player: Node2D = null) -> HomingWeapon:
	_wd_counter += 1
	var w := HomingWeapon.new()
	w.name = "W67Weapon_%d" % _wd_counter
	tree.get_root().add_child(w)
	w.position = p_pos
	w.setup(p_data, p_player, {
		"pipeline": _capture,
		"projectile_pool": null,
		"enemy_grid": _grid,
		"homing_pool": _homing_pool,
	})
	_weapons.append(w)
	return w


func _make_w6_l5() -> HomingWeapon:
	var w := _make_homing_weapon(_make_homing_data(32.0, _w6_seg()), Vector2(360, 900))
	w.level = 5
	return w


func _make_enemy_data(p_id: String) -> EnemyData:
	var d := EnemyData.new()
	d.id = StringName(p_id)
	d.display_name = p_id
	d.hp_base = 1000000.0                         # 静止不死靶（几何/序列确定性）
	d.spd_base = 0.0
	d.dmg_base = 0.0
	d.exp_base = 3.0
	d.tp_cost = 1.0
	d.hitbox_r = 14.0
	return d


func _spawn_enemy(p_pos: Vector2) -> Enemy:
	var e := _enemy_pool.acquire() as Enemy
	e.spawn(_make_enemy_data("E_W67_%d" % _alive_enemies.size()), 1, 0)
	e.position = p_pos
	_alive_enemies.append(e)
	_grid.rebuild(_alive_enemies)
	return e


func _spawn_missile(p_weapon: HomingWeapon, p_extra: Dictionary) -> HomingProjectile:
	var proj := _homing_pool.acquire() as HomingProjectile
	proj.damage_pipeline = _capture
	proj.enemy_grid = _grid
	proj.pool = _homing_pool
	var params := {
		"position": Vector2(700, 700),
		"velocity": Vector2.ZERO,
		"lifetime": 6.0,
		"pierce": 1,
		"bounces": 0,
		"hitbox_radius": 6.0,
		"element": GameConst.Element.KIN,
		"attach_value": 0.0,
		"generation": 0,
		"weapon_uid": p_weapon.uid,
		"weapon_ref": p_weapon,
		"panel_snapshot": p_weapon.build_panel_snapshot(),
		"trait_stack": p_weapon.trait_stack.copy_runtime() if p_weapon.trait_stack != null else null,
		"team": 0,
		"blast_atk_ratio": float(p_weapon.data.homing.get("blast_atk_ratio", 1.0)),
	}
	for k in p_extra:
		params[k] = p_extra[k]
	proj.spawn(params)
	return proj


func _advance_missiles(p_dt: float) -> void:
	_tick_missiles(p_dt)


func _tick_missiles(p_dt: float) -> void:
	if _homing_pool == null:
		return
	var actives := _homing_pool.active_projectiles()
	for j in range(actives.size() - 1, -1, -1):   # 倒序防回收重入（GameLoop 帧序④同口径）
		(actives[j] as ProjectileBase).tick(p_dt)


func _live_missiles() -> Array:
	var out: Array = []
	if _homing_pool != null:
		for node in _homing_pool._live_order.keys():
			out.append(node)
	return out


func _nullify_missiles() -> void:
	if _homing_pool == null:
		return
	for node in _homing_pool._live_order.keys():
		(node as ProjectileBase).nullify()


func _records_since(p_enemy: Node2D, p_mark: int) -> Array:
	var out: Array = []
	var uid := int(p_enemy.get("uid"))
	for rec in _capture.records.slice(p_mark):
		if int(rec.get("uid", 0)) == uid:
			out.append(rec)
	return out


func _record_bases_for(p_uid: int) -> Array:
	var out: Array = []
	for rec in _capture.records:
		if int(rec.get("uid", 0)) == p_uid:
			out.append(float(rec.get("base", 0.0)))
	return out


func _last_secondary_base(p_enemy: Node2D) -> float:
	var recs := _records_since(p_enemy, 0)
	for i in range(recs.size() - 1, -1, -1):
		if _has_flag(recs[i], GameConst.HIT_IS_AOE_SECONDARY):
			return float(recs[i].get("base", 0.0))
	return 0.0


func _has_flag(p_rec: Dictionary, p_flag: int) -> bool:
	return int(p_rec.get("flags", 0)) & p_flag != 0


func _mean(p_arr: Array[float]) -> float:
	var s := 0.0
	for v in p_arr:
		s += v
	return s / maxf(float(p_arr.size()), 1.0)


func _float_array_eq(p_arr: Variant, p_exp: Array) -> bool:
	if not (p_arr is Array) or (p_arr as Array).size() != p_exp.size():
		return false
	for i in range(p_exp.size()):
		if not is_equal_approx(float((p_arr as Array)[i]), float(p_exp[i])):
			return false
	return true


func _has_threshold(p_d: WeaponData, p_id: StringName) -> bool:
	return not _threshold_of(p_d, p_id).is_empty()


func _threshold_of(p_d: WeaponData, p_id: StringName) -> Dictionary:
	for tt in p_d.threshold_traits:
		if StringName(str(tt.get("threshold_id", ""))) == p_id:
			return tt
	return {}


func _threshold_value(p_d: WeaponData, p_id: StringName) -> float:
	return float(_threshold_of(p_d, p_id).get("threshold", -1.0))


func _error_count(p_issues: Array) -> int:
	var n := 0
	for issue in p_issues:
		if String(issue.get("severity", "")) == DataValidator.SEV_ERROR:
			n += 1
	return n


func _has_error_on(p_issues: Array, p_field_part: String) -> bool:
	for issue in p_issues:
		if String(issue.get("severity", "")) == DataValidator.SEV_ERROR \
				and String(issue.get("field", "")).contains(p_field_part):
			return true
	return false


# ── 断言支撑（residue_cases 同款） ────────────────────────────────
func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("PASS | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s %s" % [p_name, p_detail])
		print("FAIL | %s | %s" % [p_name, p_detail])


func _summary() -> void:
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		print("失败项：")
		for f in _failures:
			print("  - %s" % f)


# R183 复制体检测桩宿主（player.gd _summon_copies 通道同形——宽类型 get 兼容；
# rof 三倍率 neutral 值对齐 WeaponBase._player_rof_mult 读取口，防 float(null) 中断 tick）
class StubPlayer extends Node2D:
	var _summon_copies: Array[WeaponBase] = []
	var rof_mult: float = 1.0
	var map_rof_mult: float = 1.0
	var comp_rof_mult: float = 1.0


# 结算捕获管线（DamagePipelineStub 包裹层：resolve 前记录 ctx 供断言）
class CapturePipeline:
	extends RefCounted

	var records: Array = []                        # {uid:int, base:float, flags:int}
	var _inner := DamagePipelineStub.new()

	func resolve(p_ctx: DamageContext) -> DamageResult:
		records.append({"uid": p_ctx.target_uid, "base": p_ctx.base_atk,
			"flags": p_ctx.hit_flags})
		return _inner.resolve(p_ctx)

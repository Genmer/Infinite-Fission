# tests/runner/r248_feedfix_cases.gd
# R248 反馈吞没与卡面品质收口用例体（由 test_r248_feedfix.gd 入口在 autoload 就绪后
# 运行时加载编译）。锚点对应簇1 各刀：
# · graze 节流（player 唯一发点 / 0.25s 节流 / 表现侧 graze_fx 锁步）；
# · 敌弹保留配额（默认路径逐位 = pkg0 :330 契约不破 / 挤老玩家弹 / 无可挤仍丢弃）；
# · 非 CHASE 精英词缀 tick（RANGED 精英 affix_ring 释放 8 发）；
# · BossMine 宿主失效（已 arm 原地爆 / _done 防重入 / 未 arm 静默清）；
# · 五卡品质卡面数字=运行值 / 二元卡「品质不影响效果」/ PHASE_SYNC 去 ×2 /
#   ELE lv2 白名单泛化（E-08：注册表 .tres 不写穿）。
extends RefCounted

const DT := 1.0 / 120.0
const MAIN_SCENE := "res://scenes/main.tscn"
const EPS := 0.0001

# c8②：二元拓扑卡全集（value≈1.0 且 stack_max==1 的 9 张 + PHASE_SYNC 同判定入面）
const BINARY_IDS: Array[StringName] = [
	&"MEC_BEAM_COFOCUS", &"MEC_BEAM_FAN", &"MEC_BEAM_TRACK", &"MEC_BEAM_SPECTRA",
	&"MEC_CHAIN_DETONATE", &"MEC_CRIT_SHARD", &"MEC_MIRROR_LOCK",
	&"MEC_MIRROR_WEIGHT", &"MEC_RICOCHET_HALL", &"MEC_PHASE_SYNC",
]

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null
var _gen: CardGenerator = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_boot_game_loop()
	_test_graze_throttle()
	_test_pool_enemy_quota()
	_test_ranged_elite_affix()
	_test_boss_mine_host_loss()
	_test_five_card_faces()
	_test_binary_neutral_note()
	_test_ele_lv2_scaling()
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
	_gen = CardGenerator.new()
	_gen.setup(_gl.registry)


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


# ── c4① graze 掠过反馈 ────────────────────────────────────────────
func _test_graze_throttle() -> void:
	print("── c4① graze 节流 ──")
	var player: Player = _gl.player
	var hits0: int = DebugStats.get_counter(&"graze_hits")
	var fx0: int = DebugStats.get_counter(&"graze_fx")
	player.set("invuln_left", 1.0)
	# 无敌窗直调：恰 +1（二cp#1 无敌期静默吞没的计数口）
	player.take_contact_damage(10.0)
	_check("无敌窗首击：graze_hits 恰 +1 且节流窗置位 0.25s",
		DebugStats.get_counter(&"graze_hits") == hits0 + 1
			and is_equal_approx(float(player.get("_graze_fb_left")), 0.25),
		"hits=%d fb=%.3f" % [DebugStats.get_counter(&"graze_hits"),
			float(player.get("_graze_fb_left"))])
	# 0.25s 节流内第二发：不再计
	player.take_contact_damage(10.0)
	_check("节流窗内第二发：graze_hits 不再计",
		DebugStats.get_counter(&"graze_hits") == hits0 + 1)
	# 节流衰减（tick 既有衰减段推进）→ 恢复计数
	player.tick(0.3, Vector2.ZERO)
	_check("tick 0.3s：节流窗归零", float(player.get("_graze_fb_left")) <= 0.0,
		"fb=%.3f" % float(player.get("_graze_fb_left")))
	player.take_contact_damage(10.0)
	_check("节流衰减后第三发：graze_hits 再 +1",
		DebugStats.get_counter(&"graze_hits") == hits0 + 2)
	# 表现侧（game_loop 订阅）：headless 零副作用仅计数——与发射数锁步
	_check("表现侧 graze_fx 与发射数锁步（headless 仅计数）",
		DebugStats.get_counter(&"graze_fx") == fx0 + 2,
		"fx=%d" % DebugStats.get_counter(&"graze_fx"))
	_check("无敌窗被打不掉血（数值零变——contact_tick 刀不入本簇）",
		is_equal_approx(float(player.get("hp")), 1000000.0))
	player.set("invuln_left", 0.0)


# ── c4② 敌弹保留配额 ─────────────────────────────────────────────
func _release_all_bullets(p_pool: ProjectilePool) -> void:
	var list := p_pool.active_projectiles()
	for i in range(list.size() - 1, -1, -1):
		p_pool.release(list[i])


func _test_pool_enemy_quota() -> void:
	print("── c4② 敌弹保留配额 ──")
	var pool: ProjectilePool = _gl.pools[&"projectile"]
	_release_all_bullets(pool)
	var misses0: int = pool.miss_count()
	var dropped0: int = DebugStats.get_counter(&"enemy_bullet_dropped")
	var forced0: int = pool.forced_recycle_count
	# 软上限收缩成小值（pkg0 :325 pp2.soft_limit=1 同款口径）——真实容量 820 < 1500，
	# 收缩后才真正走进 ProjectilePool 软上限分支（而非 ObjectPool 容量分支）；测毕恢复
	var soft_backup: int = pool.soft_limit
	pool.soft_limit = 4
	var soft := 4
	# ① 填满至软上限（缺省 acquire()=玩家弹路——pkg0 默认路径零扰动的前提态）
	var oldest: Node = null
	while pool.total_active() < soft:
		var b: ProjectileBase = pool.acquire()
		if b == null:
			break                                 # 防御：容量不足时不再空转
		if oldest == null:
			oldest = b
	_check("前置：池饱和至软上限 %d（全玩家弹）" % soft, pool.total_active() == soft,
		"live=%d" % pool.total_active())
	# ② 默认路径逐位锁：超软上限 → null + misses+1（pkg0 :330 契约）
	var drop: ProjectileBase = pool.acquire()
	_check("默认路径：饱和后 acquire() → null + misses+1（逐位不变）",
		drop == null and pool.miss_count() == misses0 + 1)
	# ③ 敌弹配额：acquire(1) 沿插入序挤掉最老玩家弹腾位后重试成功
	var eb: ProjectileBase = pool.acquire(1)
	_check("敌弹配额：饱和玩家弹下 acquire(1) 成功", eb != null)
	_check("敌弹配额：复得的正是被挤的最老玩家弹（FORCED 回收 LIFO）", eb == oldest)
	_check("敌弹配额：forced_recycle_count +1", pool.forced_recycle_count == forced0 + 1)
	_check("敌弹配额：腾位成功不记 miss、不记 enemy_bullet_dropped",
		pool.miss_count() == misses0 + 1
			and DebugStats.get_counter(&"enemy_bullet_dropped") == dropped0)
	# ④ 无玩家弹可挤：全池改记 team=1 → acquire(1) 仍 null + misses+1 + 丢弃遥测 +1
	for b in pool.active_projectiles():
		if b is ProjectileBase:
			(b as ProjectileBase).team = 1
	var m1: int = pool.miss_count()
	var eb2: ProjectileBase = pool.acquire(1)
	_check("无玩家弹：acquire(1) → null + misses+1 + enemy_bullet_dropped+1",
		eb2 == null and pool.miss_count() == m1 + 1
			and DebugStats.get_counter(&"enemy_bullet_dropped") == dropped0 + 1)
	pool.soft_limit = soft_backup
	_release_all_bullets(pool)
	_check("清场：池归零", pool.total_active() == 0)


# ── c4③ 非 CHASE 精英词缀复活 ────────────────────────────────────
func _clear_bullets() -> void:
	var list := (_gl.pools[&"projectile"] as ProjectilePool).active_projectiles()
	for i in range(list.size() - 1, -1, -1):
		var b: Node2D = list[i]
		if b is ProjectileBase and (b as ProjectileBase).team == 1:
			b.call("nullify")


func _count_enemy_bullets() -> int:
	var n := 0
	for b in (_gl.pools[&"projectile"] as ProjectilePool).active_projectiles():
		if b is ProjectileBase and (b as ProjectileBase).team == 1:
			n += 1
	return n


func _test_ranged_elite_affix() -> void:
	print("── c4③ 非 CHASE 精英词缀 tick ──")
	seed(7)
	var data: EnemyData = _gl.registry.get_enemy(&"E5_elite").duplicate() as EnemyData
	data.behavior = GameConst.EnemyBehavior.RANGED          # 投放面既有（spawner 无 behavior 过滤）
	var e: Enemy = (_gl.pools[&"enemy"] as EnemyPool).acquire()
	e.spawn(data, 10, GameConst.TAG_ELITE)
	e.projectile_pool = _gl.pools[&"projectile"]
	e.position = Vector2(360.0, 60.0)                       # 远离玩家（下缘）——常规开火/接触零干扰
	e.set("fire_cd_left", 999.0)
	e.call("set_elite_affixes", [&"affix_ring"])
	e._affix_cd[0] = 0.0                                    # 就绪即发（绕 7s 冷却）
	_clear_bullets()
	for i in range(int(1.4 / DT)):                          # 前摇 0.55s + 余量，全走 tick 主体新段
		e.call("tick", DT)
	_check("RANGED 精英非空词缀：完整 tick 推进 affix_ring 释放 8 发敌弹",
		_count_enemy_bullets() == 8, "n=%d" % _count_enemy_bullets())
	(_gl.pools[&"enemy"] as EnemyPool).release(e)
	_clear_bullets()


# ── c4④ BossMine 宿主失效 ────────────────────────────────────────
func _count_hazard_pools() -> int:
	var n := 0
	var stack: Array[Node] = [tree.get_root()]
	while not stack.is_empty():
		var cur: Node = stack.pop_front()
		if cur is Enemy.HazardPool:
			n += 1
		for c in cur.get_children():
			stack.append(c)
	return n


func _test_boss_mine_host_loss() -> void:
	print("── c4④ BossMine 宿主失效原地引爆 ──")
	var holder := Node2D.new()
	tree.get_root().add_child(holder)
	# 已 arm：宿主失效 → 原地引爆一次（HazardPool 落地）后自摘
	var mine_armed: Node2D = Enemy.BossMine.new()
	holder.add_child(mine_armed)
	mine_armed.position = Vector2(3600.0, 3600.0)           # 远离玩家——伤害/触发零干扰
	mine_armed.set("telegraph_s", 0.0)
	mine_armed.set("arm_s", 0.0)
	mine_armed.set("trigger_r", 1.0)
	mine_armed.set("pool_cfg", {"radius": 40.0, "life_s": 2.0})
	mine_armed.set("host", Node2D.new())                    # 无 data 属性 → get("data")==null = 失效
	var pools0: int = _count_hazard_pools()
	mine_armed.call("_process", DT)
	_check("已 arm 宿主失效：原地引爆 → HazardPool 落地",
		_count_hazard_pools() == pools0 + 1,
		"n=%d→%d" % [pools0, _count_hazard_pools()])
	_check("已 arm 宿主失效：引爆后自摘（queue_free）", mine_armed.is_queued_for_deletion())
	mine_armed.call("_process", DT)
	_check("_done 旗：摘除窗重入不二次引爆", _count_hazard_pools() == pools0 + 1)
	# 未 arm：维持现状静默清（无 HazardPool）
	var mine_fresh: Node2D = Enemy.BossMine.new()
	holder.add_child(mine_fresh)
	mine_fresh.position = Vector2(3600.0, 3600.0)
	mine_fresh.set("telegraph_s", 5.0)
	mine_fresh.set("arm_s", 5.0)
	mine_fresh.set("host", Node2D.new())
	var pools1: int = _count_hazard_pools()
	mine_fresh.call("_process", DT)
	_check("未 arm 宿主失效：静默清（无 HazardPool）",
		_count_hazard_pools() == pools1 and mine_fresh.is_queued_for_deletion())
	for c in holder.get_children():
		c.free()                                            # queue_free 未落地——直接 free 清场
	holder.free()


# ── c8① 五卡品质卡面数字=运行值 ──────────────────────────────────
func _scaled_face(p_tid: StringName, p_rarity: int) -> Dictionary:
	var batch: Array[Dictionary] = [{
		"kind": CardGenerator.CardKind.TRAIT, "rarity": p_rarity,
		"value_scale": 1.0, "data": _gl.registry.get_trait(p_tid).duplicate(),
	}]
	_gen._apply_rarity_values(batch)
	return batch[0]


func _test_five_card_faces() -> void:
	print("── c8① 五卡品质卡面=运行值 ──")
	# HIT_BURST：运行层1=value×scale / 层2=value×scale×ratio_lv2（trait_effect_hit_burst）
	var hb_b := String(_scaled_face(&"MEC_HIT_BURST", 1)["description"])
	var hb_g := String(_scaled_face(&"MEC_HIT_BURST", 3)["description"])
	_check("HIT_BURST 蓝：49%/63%（=0.35×1.4 / ×1.28 运行终值）",
		hb_b.contains("迸裂 49% ATK") and hb_b.contains("2 层 63%/半径 100"), hb_b)
	_check("HIT_BURST 金：91%/116%（=0.35×2.6 / ×1.28 运行终值）",
		hb_g.contains("迸裂 91% ATK") and hb_g.contains("2 层 116%/半径 100"), hb_g)
	_check("HIT_BURST 卡面泄漏已清（内部备注不入卡面）",
		not String(_gl.registry.get_trait(&"MEC_HIT_BURST").description).contains("用户反馈"), hb_b)
	# CRITICAL_MASS：运行 5+value×layers（orbit_field._crit_mass_mult_bonus）
	var cm_b := String(_scaled_face(&"MEC_CRITICAL_MASS", 1)["description"])
	var cm_g := String(_scaled_face(&"MEC_CRITICAL_MASS", 3)["description"])
	_check("CRITICAL_MASS 蓝：5×→8×（=5+round(1×1.4×2)）", cm_b.contains("5×→8×"), cm_b)
	_check("CRITICAL_MASS 金：5×→10×（=5+round(1×2.6×2)）", cm_g.contains("5×→10×"), cm_g)
	# FRACTAL：运行层1=round(value)、层2=maxi(count_lv2, 层1+1)（trait_effect_fractal）
	var fr_b := String(_scaled_face(&"MEC_FRACTAL", 1)["description"])
	var fr_g := String(_scaled_face(&"MEC_FRACTAL", 3)["description"])
	_check("FRACTAL 蓝：分裂 3 枚 / 2 层 4 枚（蓝 3/4 与运行同式）",
		fr_b.contains("分裂 3 枚") and fr_b.contains("2 层 4 枚"), fr_b)
	_check("FRACTAL 金：分裂 5 枚 / 2 层 6 枚（金 5/6 与运行同式；fixHint 只盖层1 的旧病已修）",
		fr_g.contains("分裂 5 枚") and fr_g.contains("2 层 6 枚") and not fr_g.contains("分裂 2 枚"),
		fr_g)
	# BOUNCE：运行 int(round(value))×层（trait_effect_bounce:20）——修「显示+2.8≠运行3」
	var bo_b := String(_scaled_face(&"MEC_BOUNCE", 1)["description"])
	var bo_g := String(_scaled_face(&"MEC_BOUNCE", 3)["description"])
	_check("BOUNCE 蓝：+3（=int(round(2×1.4))，非 +2.8）", bo_b.contains("反弹次数 +3："), bo_b)
	_check("BOUNCE 金：+5（=int(round(2×2.6))）", bo_g.contains("反弹次数 +5："), bo_g)
	_check("BOUNCE 定向替换保护：「反弹谱变」×1.4 与「≥5 次」字样原样保留",
		bo_g.contains("「反弹谱变」×1.4") and bo_g.contains("≥5 次"), bo_g)
	# FUSE_DETONATE：运行余波 = base_atk×value×层（homing_projectile）
	var fu_b := String(_scaled_face(&"MEC_FUSE_DETONATE", 1)["description"])
	var fu_g := String(_scaled_face(&"MEC_FUSE_DETONATE", 3)["description"])
	_check("FUSE 蓝：0.7/层（=0.5×1.4）", fu_b.contains("0.7/层"), fu_b)
	_check("FUSE 金：1.3/层（=0.5×2.6）", fu_g.contains("1.3/层"), fu_g)
	# 白卡回退原文（scale=1.0 两段逐字节不变）
	var hb_w := String(_scaled_face(&"MEC_HIT_BURST", 0)["description"])
	_check("HIT_BURST 白：35%/45% 逐字节回退原文",
		hb_w == "命中时向落点半径 80 内迸裂 35% ATK；2 层 45%/半径 100", hb_w)


# ── c8②/③ 二元卡尾注抑制 + PHASE_SYNC 卡面 ──────────────────────
func _test_binary_neutral_note() -> void:
	print("── c8②/③ 二元卡尾注 + PHASE_SYNC ──")
	for tid in BINARY_IDS:
		var gold := _scaled_face(tid, 3)
		var desc := String(gold["description"])
		_check("二元卡 %s 金：尾注=「品质不影响效果」" % String(tid),
			desc.contains("品质不影响效果") and not desc.contains("品质：效果数值 ×"),
			desc.substr(desc.length() - 40))
		_check("二元卡 %s 金：compose 不拼「品质加成」假话行" % String(tid),
			not CardSelectUI.compose_desc_text(desc, 2.6, false).contains("品质加成"),
			CardSelectUI.compose_desc_text(desc, 2.6, false).substr(0, 40))
	# 数值卡对照：品质加成尾行保持（r220 C2b 契约族不破）
	var num := _scaled_face(&"AFF_ATK_UP", 1)
	var num_desc := String(num["description"])
	_check("数值卡对照（AFF_ATK_UP 蓝）：仍走品质缩放重写与加成尾行",
		not num_desc.contains("品质不影响效果")
			and CardSelectUI.compose_desc_text(num_desc, 1.4, false).contains("品质加成"),
		num_desc)
	# PHASE_SYNC：卡面去「×2」（运行恒 FOCUS_RAMP_SYNC=0.30 判 id——×2.4/2.9/3.6 是反向虚高）
	var raw_sync := String(_gl.registry.get_trait(&"MEC_PHASE_SYNC").description)
	_check("PHASE_SYNC .tres：描述无「×2」字样（方案B：卡面不再声称读 value）",
		not raw_sync.contains("×2"), raw_sync)
	var sync_gold := String(_scaled_face(&"MEC_PHASE_SYNC", 3)["description"])
	_check("PHASE_SYNC 金卡：封顶 3.35s 文案保留 + 无 ×2.4 反向虚高 + 品质不影响效果",
		sync_gold.contains("封顶 3.35s 即满") and not sync_gold.contains("×2.4")
			and sync_gold.contains("品质不影响效果"), sync_gold)


# ── c8④ ELE lv2 白名单泛化 ───────────────────────────────────────
func _test_ele_lv2_scaling() -> void:
	print("── c8④ ELE lv2 白名单泛化 ──")
	var ig := _scaled_face(&"ELE_IGNITE", 3)
	var ig_params: Dictionary = (ig["data"] as TraitData).params
	_check("ELE_IGNITE 金：dot_ratio_lv2 = 白×2.6（0.22→0.572）",
		absf(float(ig_params.get("dot_ratio_lv2", 0.0)) - 0.572) < EPS,
		str(ig_params.get("dot_ratio_lv2")))
	var sh := _scaled_face(&"ELE_SHOCK", 3)
	var sh_params: Dictionary = (sh["data"] as TraitData).params
	_check("ELE_SHOCK 金：chain_targets_lv2 计数键取整（4→int(round(10.4))=10）",
		typeof(sh_params.get("chain_targets_lv2")) == TYPE_INT
			and int(sh_params["chain_targets_lv2"]) == 10,
		str(sh_params.get("chain_targets_lv2")))
	_check("ELE_SHOCK 金：chain_decay_lv2 同乘 scale（0.75→1.95）",
		absf(float(sh_params.get("chain_decay_lv2", 0.0)) - 1.95) < EPS,
		str(sh_params.get("chain_decay_lv2")))
	# E-08 防线：注册表共享 .tres 不写穿
	var reg_ig: TraitData = _gl.registry.get_trait(&"ELE_IGNITE")
	_check("E-08：注册表 .tres 原值不写穿（dot_ratio_lv2 仍 0.22）",
		absf(float(reg_ig.params.get("dot_ratio_lv2", 0.0)) - 0.22) < EPS,
		str(reg_ig.params.get("dot_ratio_lv2")))
	# 像素半径键不缩放（现行口径）
	_check("spread_radius_lv2 维持不缩放（像素半径口径）",
		absf(float(ig_params.get("spread_radius_lv2", 0.0)) - 150.0) < EPS,
		str(ig_params.get("spread_radius_lv2")))

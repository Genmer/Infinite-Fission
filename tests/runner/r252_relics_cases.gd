# tests/runner/r252_relics_cases.gd
# R252 遗物扩容用例体（由 test_r252_relics.gd 入口在 autoload 就绪后运行时加载编译）。
# 覆盖（设计 §3.5）：R0 注册面 / R1-R16 每件三件套（激活生效-守卫-reset）/ R17 权重三源 /
#   R18 存档随档 / reset 运行态清零联动。
# 确定性：GameLoop 完整 Boot（main.tscn 实例化）；事件断言以直调回调为主（波形接线由
#   pkg5/verify_feedback 既有锁承载）、GUILLOTINE 走真 EventBus damage_resolved 派发；
#   概率型（PYRE）以 params.chance=1.0 注入消除随机（用后还原 0.25）。
# 注：设计 §3.5-R3 验收示例「杀 25 层→0.5」与 §3.2-#3 params{cap:15}/机制文案「至多 15 层」
#   相互矛盾——按 params 数据契约实施（25 杀→15 层帽→contrib 0.30），本套件按 0.30 断言。
# autoload 纪律（R252C）：本文件零字面 autoload 标识符（EventBus/Meta/RunSave/GameConfig/
# DebugStats 一律经 _resolve_autoloads 运行时解析）——命名全局在 -s 两段式入口里于 autoload
# 注册后才存在，早编译场景（--check-only / 直接 -s 本文件 / 其他 runner 提前 load）会报
# 「Compile Error: Identifier not found」。逻辑零改动，仅引用通道换运行时。
# 直跑形态：-s tests/runner/r252_relics_cases.gd → _initialize 自引导（等 autoload 注册后
# 自执行用例并 quit）——兼容 runner 直接点名用例体文件的验收方式（上轮直跑挂主循环 420s
# 超时的根修）。两段式形态：test_r252_relics.gd 入口 load 本文件 .new() 后调 run(tree)。
extends SceneTree

const DT := 1.0 / 120.0
const MAIN_SCENE := "res://scenes/main.tscn"

# R252 十六新件（设计 §3.2 顺序）
const NEW_IDS: Array[StringName] = [
	&"REL_GREED_MATRIX", &"REL_WAVE_INTEREST", &"REL_FAULTLESS_CHAIN", &"REL_VANGUARD",
	&"REL_CRIMSON_RUSH", &"REL_GUILLOTINE", &"REL_PYRE", &"REL_KINGSLAY",
	&"REL_ELITE_WINDOW", &"REL_FOCUS_MARK", &"REL_RESONANT_TOUCH", &"REL_LEVEL_TREASURY",
	&"REL_CROWN_TALLY", &"REL_FIELD_MEDIC", &"REL_BLOOD_TITHE", &"REL_GRAVITY_WELL",
]
# R0 params 契约键（设计 §3.2 params 列逐件对照）
const NEW_PARAMS: Dictionary = {
	&"REL_GREED_MATRIX": ["per_gold", "step", "cap_steps", "pool"],
	&"REL_WAVE_INTEREST": ["per", "gain", "cap"],
	&"REL_FAULTLESS_CHAIN": ["step", "cap", "pool"],
	&"REL_VANGUARD": ["mult", "pool"],
	&"REL_CRIMSON_RUSH": ["pct", "step", "pool"],
	&"REL_GUILLOTINE": ["pct", "boss_pct"],
	&"REL_PYRE": ["chance", "atk_ratio", "radius", "icd"],
	&"REL_KINGSLAY": ["atk_ratio", "radius"],
	&"REL_ELITE_WINDOW": ["window", "step", "pool"],
	&"REL_FOCUS_MARK": ["step", "cap", "pool"],
	&"REL_RESONANT_TOUCH": ["window", "step", "cap", "pool"],
	&"REL_LEVEL_TREASURY": ["gold_per_level"],
	&"REL_CROWN_TALLY": ["boss_gold", "elite_gold"],
	&"REL_FIELD_MEDIC": ["heal_pct"],
	&"REL_BLOOD_TITHE": ["cost", "step", "pool"],
	&"REL_GRAVITY_WELL": ["first_slot_bias"],
}

var tree: SceneTree
var run_completed: bool = false       # 防伪绿：run() 走完汇总打印才置位（入口校验）
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null
# autoload 运行时解析缓存（_resolve_autoloads 于 run() 开头从 root 取节点）
var _eb: Node = null                          # EventBus
var _meta: Node = null                        # MetaManager
var _gc: Node = null                          # GameConfig
var _ds: Node = null                          # DebugStats


func _initialize() -> void:
	# -s 直跑：本实例即主循环；_initialize 期 autoload 未注册——起协程等两帧（test_pkg5.gd 同款）
	_run_direct()


func _run_direct() -> void:
	await process_frame
	await process_frame
	run(self)
	quit(1 if (fail_count() > 0 or not run_completed) else 0)


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	_resolve_autoloads()
	seed(42)
	_ensure_autoloads()
	_test_r0_registry()
	_test_r1_greed_matrix()
	_test_r2_wave_interest()
	_test_r3_faultless_chain()
	_test_r4_vanguard()
	_test_r5_crimson_rush()
	_test_r6_guillotine()
	_test_r7_pyre()
	_test_r8_kingslay()
	_test_r9_elite_window()
	_test_r10_focus_mark()
	_test_r11_resonant_touch()
	_test_r12_level_treasury()
	_test_r13_crown_tally()
	_test_r14_field_medic()
	_test_r15_blood_tithe()
	_test_r16_gravity_well()
	_test_r17_weight_three_sources()
	_test_reset_clearance()
	_test_r18_save_restore()
	_teardown_game_loop()
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)
	run_completed = true


func fail_count() -> int:
	return _fail


# ── 环境引导 ──────────────────────────────────────────────────────
func _resolve_autoloads() -> void:
	# autoload 注册名 = project.godot 注册表（pkg5 同名单）
	var root: Node = tree.get_root()
	_eb = root.get_node_or_null(NodePath("EventBus"))
	_meta = root.get_node_or_null(NodePath("Meta"))
	_gc = root.get_node_or_null(NodePath("GameConfig"))
	_ds = root.get_node_or_null(NodePath("DebugStats"))
	# RunSave 不在此列：class_name 静态类（run_save.gd:13），非 autoload——字面调用


func _ensure_autoloads() -> void:
	_check("autoload 就绪（EventBus/GameConfig/DebugStats）",
		_eb != null and _gc != null and _ds != null)
	_check("GameConfig 非致命（balance 加载）",
		not bool(_gc.call("is_fatal")) and _gc.get("balance") != null)


func _boot_game_loop() -> void:
	# 套件隔离（pkg5 同款）：boot 前清继续档 + Meta 归零
	RunSave.clear()
	_meta.set("upgrades", {})
	_meta.set("crystals", 0)
	_meta.set("character_id", &"sentinel")
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "GameLoopUnderTest"
	tree.get_root().add_child(_gl)


func _teardown_game_loop() -> void:
	tree.paused = false
	RunSave.clear()
	if _gl != null:
		_gl.free()
		_gl = null


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
	else:
		_fail += 1
		_failures.append("%s%s" % [p_name, "｜" + p_detail if p_detail != "" else ""])
		print("  [FAIL] %s %s" % [p_name, p_detail])


func _handler() -> RelicHandler:
	return _gl.relic_handler


func _weapon() -> WeaponBase:
	return _gl.player.weapon_slots[0]


# ── 夹具（pkg5/mirror_muzzle/verify_feedback 同源口径） ────────────
func _mk_enemy(p_tags: int = 0, p_hp: float = 1000.0) -> Enemy:
	var data := EnemyData.new()
	data.id = &"E_R252"
	data.hp_base = p_hp
	data.spd_base = 0.0
	data.dmg_base = 5.0
	data.exp_base = 7.0
	data.hitbox_r = 14.0
	var e := (_gl.pools[&"enemy"] as EnemyPool).acquire()
	e.spawn(data, 1, p_tags)
	return e


func _release_enemy(p_e: Enemy) -> void:
	_gl.spawner.active.erase(p_e)
	(_gl.pools[&"enemy"] as EnemyPool).release(p_e)


func _grid_add(p_e: Enemy) -> void:
	_gl.spawner.active.append(p_e)
	_gl.enemy_grid.rebuild(_gl.spawner.active)


func _grid_drop(p_e: Enemy) -> void:
	# 网格夹具回收（mirror_muzzle 同式：出 active + 还池 + 空表重建）
	_gl.spawner.active.erase(p_e)
	(_gl.pools[&"enemy"] as EnemyPool).release(p_e)
	_gl.enemy_grid.rebuild(_gl.spawner.active)


func _inject_ctx(p_target: Node2D, p_hp_pct: float = 1.0) -> DamageContext:
	# 命中时点乘区问询（WeaponBase.inject_relic_pools 同入口——真实消费路径）
	var ctx := DamageContext.make()
	ctx.player_hp_pct = p_hp_pct
	_weapon().inject_relic_pools(ctx, p_target)
	return ctx


func _pool_contrib(p_ctx: DamageContext, p_pool: StringName) -> float:
	# 无池 → -1（本批注入分支 contrib 恒 >0，-1 哨兵与 0 可区分）
	for pool in p_ctx.mult_pools:
		if StringName(String(pool.get("pool_id", ""))) == p_pool:
			return float(pool.get("contrib", 0.0))
	return -1.0


# ── R0 注册面 ─────────────────────────────────────────────────────
func _test_r0_registry() -> void:
	print("── R0 注册面 ──")
	_boot_game_loop()
	_check("R0① 注册表 40 件（18 旧 + 16 新 + R253 防御控制向 6）", _gl.registry.relics.size() == 40,
		"n=%d" % _gl.registry.relics.size())
	_check("R0② Boot 致命清单为空（新 .tres 全过 data_validator）",
		_gl.boot_fatal.is_empty() and _gl.boot_ready, str(_gl.boot_fatal))
	var shape_ok := true
	var shape_bad := ""
	for rid in NEW_IDS:
		var rd := _gl.registry.get_relic(rid)
		if rd == null:
			shape_ok = false
			shape_bad = "%s 缺失" % String(rid)
			break
		if int(rd.rarity) != 3 or not bool(rd.unique):
			shape_ok = false
			shape_bad = "%s rarity=%s unique=%s" % [String(rid), str(rd.rarity), str(rd.unique)]
			break
		if String(rd.effect_id) == "":
			shape_ok = false
			shape_bad = "%s effect_id 空" % String(rid)
			break
		for key_v in (NEW_PARAMS[rid] as Array):
			if not rd.params.has(String(key_v)):
				shape_ok = false
				shape_bad = "%s 缺 params 键 %s" % [String(rid), String(key_v)]
				break
		if String(rd.description).contains("§") or String(rd.description).contains("A3 "):
			shape_ok = false
			shape_bad = "%s 描述黑话" % String(rid)
			break
	_check("R0③ 16 新件 rarity=3 / unique / effect_id / params 契约键 / R60 黑话全过",
		shape_ok, shape_bad)
	# 悬空 listen_events 防线：新件声明域 ⊆ EVENT_NAMES（level_up_batch 域外特判不声明）
	var listen_ok := true
	var listen_bad := ""
	for rid2 in NEW_IDS:
		var rd2 := _gl.registry.get_relic(rid2)
		for ev in rd2.listen_events:
			if not (_eb.get("known_events") as Array).has(ev):
				listen_ok = false
				listen_bad = "%s 悬空事件 %s" % [String(rid2), String(ev)]
	_check("R0④ 新件 listen_events 全部 ∈ EventBus 注册域（validator 域内声明）",
		listen_ok, listen_bad)


# ── R1 贪婪矩阵 ───────────────────────────────────────────────────
func _test_r1_greed_matrix() -> void:
	print("── R1 REL_GREED_MATRIX ──")
	var h := _handler()
	h.reset_run()
	var e := _mk_enemy()
	_gl.player.gold = 100
	var ctx0 := _inject_ctx(e)
	_check("R1 守卫：未持有 → 金币 100 无乘区池",
		_pool_contrib(ctx0, &"greed_dmg") < 0.0)
	_check("R1 激活", h.activate(&"REL_GREED_MATRIX"))
	_check("R1 守卫：unique 重复激活拒绝",
		not h.activate(&"REL_GREED_MATRIX") and h.owned_count() == 1)
	_gl.player.gold = 100
	_check("R1 生效：100 金 → 5 档 contrib 0.25",
		is_equal_approx(_pool_contrib(_inject_ctx(e), &"greed_dmg"), 0.25),
		str(_pool_contrib(_inject_ctx(e), &"greed_dmg")))
	_gl.player.gold = 1050
	_check("R1 封顶：1050 金 → 10 档帽 contrib 0.5",
		is_equal_approx(_pool_contrib(_inject_ctx(e), &"greed_dmg"), 0.5))
	_gl.player.gold = 19
	_check("R1 边界：19 金不足一档 → 无池",
		_pool_contrib(_inject_ctx(e), &"greed_dmg") < 0.0)
	_gl.player.gold = 20
	_check("R1 边界：恰 20 金 → 1 档 0.05",
		is_equal_approx(_pool_contrib(_inject_ctx(e), &"greed_dmg"), 0.05))
	_release_enemy(e)


# ── R2 低息存款 ───────────────────────────────────────────────────
func _test_r2_wave_interest() -> void:
	print("── R2 REL_WAVE_INTEREST ──")
	var h := _handler()
	h.reset_run()
	_gl.player.gold = 250
	h._on_wave_cleared(3)
	_check("R2 守卫：未持有 → 波末无利息", _gl.player.gold == 250)
	_check("R2 激活", h.activate(&"REL_WAVE_INTEREST"))
	_gl.player.gold = 250
	h._on_wave_cleared(3)
	_check("R2 生效：250 金 → 利息 +10（2 档×5）", _gl.player.gold == 260,
		str(_gl.player.gold))
	_gl.player.gold = 1000
	h._on_wave_cleared(4)
	_check("R2 封顶：1000 金 → +30 帽（非 50）", _gl.player.gold == 1030,
		str(_gl.player.gold))
	_gl.player.gold = 99
	h._on_wave_cleared(5)
	_check("R2 边界：99 金不足一档 → 0 利息", _gl.player.gold == 99)
	_gl.player.gold = 0
	h._on_wave_cleared(6)
	_check("R2 边界：0 金 → 0 利息", _gl.player.gold == 0)


# ── R3 无瑕链路 ───────────────────────────────────────────────────
func _test_r3_faultless_chain() -> void:
	print("── R3 REL_FAULTLESS_CHAIN ──")
	var h := _handler()
	h.reset_run()
	var e := _mk_enemy()
	_check("R3 激活", h.activate(&"REL_FAULTLESS_CHAIN"))
	for i in range(15):
		h._on_enemy_killed(e)
	_check("R3 生效：15 杀 → 15 层 contrib 0.30",
		is_equal_approx(_pool_contrib(_inject_ctx(e), &"faultless_dmg"), 0.30),
		str(_pool_contrib(_inject_ctx(e), &"faultless_dmg")))
	for i in range(10):
		h._on_enemy_killed(e)
	_check("R3 封顶：25 杀仍 15 层帽 → contrib 0.30（params cap=15 数据契约）",
		is_equal_approx(_pool_contrib(_inject_ctx(e), &"faultless_dmg"), 0.30))
	h._on_player_hit(5.0, 0)
	_check("R3 受击清零：contrib 归零", _pool_contrib(_inject_ctx(e), &"faultless_dmg") < 0.0)
	_release_enemy(e)


# ── R4 先手矩阵 ───────────────────────────────────────────────────
func _test_r4_vanguard() -> void:
	print("── R4 REL_VANGUARD ──")
	var h := _handler()
	h.reset_run()
	var e := _mk_enemy()
	e.max_hp = 1000.0
	e.hp = 1000.0
	_check("R4 激活", h.activate(&"REL_VANGUARD"))
	_check("R4 生效：满血目标 contrib 1.0（×2）",
		is_equal_approx(_pool_contrib(_inject_ctx(e), &"vanguard_dmg"), 1.0),
		str(_pool_contrib(_inject_ctx(e), &"vanguard_dmg")))
	e.hp = 500.0
	_check("R4 守卫：残血目标无池",
		_pool_contrib(_inject_ctx(e), &"vanguard_dmg") < 0.0)
	e.hp = 1000.0
	_check("R4 满血恢复后再入池（无一次性消耗语义）",
		is_equal_approx(_pool_contrib(_inject_ctx(e), &"vanguard_dmg"), 1.0))
	_release_enemy(e)


# ── R5 裂颅狂潮 ───────────────────────────────────────────────────
func _test_r5_crimson_rush() -> void:
	print("── R5 REL_CRIMSON_RUSH ──")
	var h := _handler()
	h.reset_run()
	var e := _mk_enemy()
	_check("R5 激活", h.activate(&"REL_CRIMSON_RUSH"))
	_check("R5 守卫：满血（1.0）无池",
		_pool_contrib(_inject_ctx(e, 1.0), &"lowhp_dmg") < 0.0)
	_check("R5 边界：恰 0.5（不小于）无池",
		_pool_contrib(_inject_ctx(e, 0.5), &"lowhp_dmg") < 0.0)
	_check("R5 生效：血线 0.4 → contrib 0.30",
		is_equal_approx(_pool_contrib(_inject_ctx(e, 0.4), &"lowhp_dmg"), 0.30),
		str(_pool_contrib(_inject_ctx(e, 0.4), &"lowhp_dmg")))
	_check("R5 生效：血线 0.6 → 无池",
		_pool_contrib(_inject_ctx(e, 0.6), &"lowhp_dmg") < 0.0)
	_release_enemy(e)


# ── R6 断头台协议 ─────────────────────────────────────────────────
func _test_r6_guillotine() -> void:
	print("── R6 REL_GUILLOTINE ──")
	var h := _handler()
	h.reset_run()
	_check("R6 激活", h.activate(&"REL_GUILLOTINE"))
	# 精英 11.9%（< 12%）→ 结算后处决（uid 记忆经 inject 捕获；真 EventBus 派发）
	var elite := _mk_enemy(GameConst.TAG_ELITE)
	elite.max_hp = 1000.0
	elite.hp = 119.0
	_inject_ctx(elite)
	var res := DamageResult.new()
	res.target_uid = elite.uid
	_eb.call(&"emit_damage_resolved", res)
	_check("R6 生效：精英 11.9% 血结算后死亡", is_instance_valid(elite) and elite.dead)
	# 首领 6.1%（> 6%）存活；5.9%（< 6%）死亡
	var boss := _mk_enemy(GameConst.TAG_BOSS)
	boss.max_hp = 1000.0
	boss.hp = 61.0
	_inject_ctx(boss)
	var res2 := DamageResult.new()
	res2.target_uid = boss.uid
	_eb.call(&"emit_damage_resolved", res2)
	_check("R6 阈值：首领 6.1% 存活（> boss_pct）", is_instance_valid(boss) and not boss.dead)
	boss.hp = 59.0
	var res3 := DamageResult.new()
	res3.target_uid = boss.uid
	_eb.call(&"emit_damage_resolved", res3)
	_check("R6 生效：首领 5.9% 结算后死亡", is_instance_valid(boss) and boss.dead)
	# 守卫：精英 20% 血不处决；普通怪低血不处决（域限 tag）
	var elite2 := _mk_enemy(GameConst.TAG_ELITE)
	elite2.max_hp = 1000.0
	elite2.hp = 200.0
	_inject_ctx(elite2)
	var res4 := DamageResult.new()
	res4.target_uid = elite2.uid
	_eb.call(&"emit_damage_resolved", res4)
	_check("R6 守卫：精英 20% 血不处决", is_instance_valid(elite2) and not elite2.dead)
	var plain := _mk_enemy(0)
	plain.max_hp = 1000.0
	plain.hp = 1.0
	_inject_ctx(plain)
	var res5 := DamageResult.new()
	res5.target_uid = plain.uid
	_eb.call(&"emit_damage_resolved", res5)
	_check("R6 守卫：普通怪低血不处决（仅精英/首领域）",
		is_instance_valid(plain) and not plain.dead)
	_release_enemy(elite2)
	_release_enemy(plain)


# ── R7 葬列火种 ───────────────────────────────────────────────────
func _test_r7_pyre() -> void:
	print("── R7 REL_PYRE ──")
	var h := _handler()
	h.reset_run()
	var pyre_rd := _gl.registry.get_relic(&"REL_PYRE")
	var chance0: float = pyre_rd.params.get("chance", 0.25)
	pyre_rd.params["chance"] = 1.0                            # 注入必爆（用后还原）
	_check("R7 激活", h.activate(&"REL_PYRE"))
	var victim := _mk_enemy(0, 100000.0)
	victim.position = Vector2(400.0, 300.0)
	var near := _mk_enemy(0, 100000.0)
	near.position = Vector2(450.0, 300.0)                     # 半径 120 内
	var far := _mk_enemy(0, 100000.0)
	far.position = Vector2(800.0, 300.0)                      # 半径 120 外
	_grid_add(victim)
	_grid_add(near)
	_grid_add(far)
	var near_hp0: float = near.hp
	var far_hp0: float = far.hp
	h._on_enemy_killed(victim)
	_check("R7 生效：击杀尸爆 → 近旁敌掉血（150% 主武器攻击力 AoE 真结算）",
		is_instance_valid(near) and near.hp < near_hp0,
		"%.0f→%.0f" % [near_hp0, near.hp])
	_check("R7 半径：圈外敌不掉血", is_instance_valid(far)
		and is_equal_approx(far.hp, far_hp0))
	# icd 0.3s：窗口内第二杀不爆（chance=1.0 仍被内冷抑制；尸位须在 near 半径内）
	# GameConfig.frame_stamp 推进：模拟换帧——绕开真管线 (source,target,frame) 幂等缓存
	#（测试不驱动物理帧，frame_stamp 恒定会把同帧二次结算去重成空结果）
	var near_hp1: float = near.hp
	_gc.set("frame_stamp", int(_gc.get("frame_stamp")) + 1)
	var victim2 := _mk_enemy(0, 100000.0)
	victim2.position = Vector2(430.0, 300.0)
	h._on_enemy_killed(victim2)
	_check("R7 内冷：0.3s 内二连击杀不爆", is_instance_valid(near)
		and is_equal_approx(near.hp, near_hp1))
	h.tick(0.4)                                               # 推过内冷窗
	_gc.set("frame_stamp", int(_gc.get("frame_stamp")) + 1)
	var victim3 := _mk_enemy(0, 100000.0)
	victim3.position = Vector2(430.0, 300.0)
	h._on_enemy_killed(victim3)
	var r7_dbg := "near_valid=%s" % str(is_instance_valid(near))
	if is_instance_valid(near):
		r7_dbg += " hp=%.1f hp1=%.1f cd=%.3f v3pos=%s" % [near.hp, near_hp1,
			h._pyre_cd_left, str(victim3.global_position)]
	_check("R7 内冷解除：0.4s 后再杀再爆", is_instance_valid(near) and near.hp < near_hp1, r7_dbg)
	_grid_drop(near)
	_grid_drop(far)
	pyre_rd.params["chance"] = chance0                        # 还原 .tres 参数
	h.reset_run()                                             # 清 _pyre_cd_left 等运行态


# ── R8 弑王回响 ───────────────────────────────────────────────────
func _test_r8_kingslay() -> void:
	print("── R8 REL_KINGSLAY ──")
	var h := _handler()
	h.reset_run()
	var elite := _mk_enemy(GameConst.TAG_ELITE, 100000.0)
	elite.position = Vector2(400.0, 300.0)
	var near := _mk_enemy(0, 100000.0)
	near.position = Vector2(100.0, 100.0)                     # 全场半径 2000 内
	_grid_add(elite)
	_grid_add(near)
	var near_hp0: float = near.hp
	h._on_enemy_killed(elite)
	_check("R8 守卫：未持有 → 精英死无全场 AoE",
		is_instance_valid(near) and is_equal_approx(near.hp, near_hp0))
	_check("R8 激活", h.activate(&"REL_KINGSLAY"))
	var elite2 := _mk_enemy(GameConst.TAG_ELITE, 100000.0)
	elite2.position = Vector2(400.0, 300.0)
	_grid_add(elite2)
	h._on_enemy_killed(elite2)
	_check("R8 生效：精英死 → 全场敌 250% 主武器攻击力掉血",
		is_instance_valid(near) and near.hp < near_hp0,
		"%.0f→%.0f" % [near_hp0, near.hp])
	var near_hp1: float = near.hp
	h._on_enemy_killed(_mk_enemy(0, 100000.0))                # 普通怪死不触发
	_check("R8 域限：普通怪死亡无全场 AoE",
		is_instance_valid(near) and is_equal_approx(near.hp, near_hp1))
	_grid_drop(near)


# ── R9 猎杀时刻 ───────────────────────────────────────────────────
func _test_r9_elite_window() -> void:
	print("── R9 REL_ELITE_WINDOW ──")
	var h := _handler()
	h.reset_run()
	var plain := _mk_enemy()
	_check("R9 激活", h.activate(&"REL_ELITE_WINDOW"))
	_check("R9 守卫：未击杀精英 → 无池",
		_pool_contrib(_inject_ctx(plain), &"elite_window_dmg") < 0.0)
	h._on_enemy_killed(plain)
	_check("R9 域限：普通怪击杀不置窗",
		_pool_contrib(_inject_ctx(plain), &"elite_window_dmg") < 0.0)
	var elite := _mk_enemy(GameConst.TAG_ELITE)
	h._on_enemy_killed(elite)
	_check("R9 生效：精英死后窗内 contrib 0.25",
		is_equal_approx(_pool_contrib(_inject_ctx(plain), &"elite_window_dmg"), 0.25),
		str(_pool_contrib(_inject_ctx(plain), &"elite_window_dmg")))
	h.tick(4.1)
	_check("R9 窗口：4.1s 后过期无池",
		_pool_contrib(_inject_ctx(plain), &"elite_window_dmg") < 0.0)
	var boss := _mk_enemy(GameConst.TAG_BOSS)
	h._on_enemy_killed(boss)
	_check("R9 域限：首领击杀同置窗",
		is_equal_approx(_pool_contrib(_inject_ctx(plain), &"elite_window_dmg"), 0.25))
	_release_enemy(plain)


# ── R10 猎杀印记 ──────────────────────────────────────────────────
func _test_r10_focus_mark() -> void:
	print("── R10 REL_FOCUS_MARK ──")
	var h := _handler()
	h.reset_run()
	var e := _mk_enemy()
	_check("R10 激活", h.activate(&"REL_FOCUS_MARK"))
	var contrib := -1.0
	for i in range(5):
		contrib = _pool_contrib(_inject_ctx(e), &"focus_dmg")
	_check("R10 生效：同目标 5 发 → contrib 0.15（3%×5 逐发爬升）",
		is_equal_approx(contrib, 0.15), str(contrib))
	for i in range(7):
		contrib = _pool_contrib(_inject_ctx(e), &"focus_dmg")
	_check("R10 封顶：12 发 → 10 层帽 contrib 0.30",
		is_equal_approx(contrib, 0.30), str(contrib))
	var e2 := _mk_enemy()
	contrib = _pool_contrib(_inject_ctx(e2), &"focus_dmg")
	_check("R10 换目标：层数清零重爬（新目标首发 0.03）",
		is_equal_approx(contrib, 0.03), str(contrib))
	_release_enemy(e)
	_release_enemy(e2)


# ── R11 共鸣触媒 ──────────────────────────────────────────────────
func _test_r11_resonant_touch() -> void:
	print("── R11 REL_RESONANT_TOUCH ──")
	var h := _handler()
	h.reset_run()
	var e := _mk_enemy()
	h._on_reaction_triggered(0, Vector2.ZERO, 0)
	_check("R11 守卫：未持有 → 反应不置层",
		_pool_contrib(_inject_ctx(e), &"resonant_dmg") < 0.0)
	_check("R11 激活", h.activate(&"REL_RESONANT_TOUCH"))
	_eb.call(&"emit_reaction_triggered", 0, Vector2.ZERO, 0)      # 真信号派发（bind_events 接线）
	_check("R11 生效：1 反应 → contrib 0.06",
		is_equal_approx(_pool_contrib(_inject_ctx(e), &"resonant_dmg"), 0.06),
		str(_pool_contrib(_inject_ctx(e), &"resonant_dmg")))
	for i in range(4):
		_eb.call(&"emit_reaction_triggered", 0, Vector2.ZERO, 0)
	_check("R11 叠层：5 反应 → contrib 0.30（6%×5）",
		is_equal_approx(_pool_contrib(_inject_ctx(e), &"resonant_dmg"), 0.30))
	_eb.call(&"emit_reaction_triggered", 0, Vector2.ZERO, 0)
	_check("R11 封顶：6 反应仍 5 层帽 → 0.30",
		is_equal_approx(_pool_contrib(_inject_ctx(e), &"resonant_dmg"), 0.30))
	h.tick(3.1)
	_check("R11 窗口：3.1s 后到期层清 → 无池",
		_pool_contrib(_inject_ctx(e), &"resonant_dmg") < 0.0)
	_release_enemy(e)


# ── R12 跃升金库 ──────────────────────────────────────────────────
func _test_r12_level_treasury() -> void:
	print("── R12 REL_LEVEL_TREASURY ──")
	var h := _handler()
	h.reset_run()
	_gl.player.gold = 0
	h._on_level_up(3)
	h._on_level_up_batch(3)
	_check("R12 守卫：未持有 → 单级/批均不入账", _gl.player.gold == 0)
	_check("R12 激活（.tres 声明 level_up 域内）", h.activate(&"REL_LEVEL_TREASURY"))
	_gl.player.gold = 0
	h._on_level_up(3)
	_check("R12 单级臂：level_up → 恰 +25（批分支不触发——双臂互斥不重复计账）",
		_gl.player.gold == 25, str(_gl.player.gold))
	h._on_level_up_batch(3)
	_check("R12 批臂：level_up_batch(3) → 恰 +75（25×批级数，单级分支不触发）",
		_gl.player.gold == 100, str(_gl.player.gold))
	_gl.player.gold = 0
	h._on_level_up_batch(5)
	_check("R12 巨批：batch(5) → +125", _gl.player.gold == 125, str(_gl.player.gold))


# ── R13 猎首金冠 ──────────────────────────────────────────────────
func _test_r13_crown_tally() -> void:
	print("── R13 REL_CROWN_TALLY ──")
	var h := _handler()
	h.reset_run()
	_gl.player.gold = 0
	h._on_enemy_killed(_mk_enemy(GameConst.TAG_BOSS))
	h._on_enemy_killed(_mk_enemy(GameConst.TAG_ELITE))
	_check("R13 守卫：未持有 → 击杀不入账", _gl.player.gold == 0)
	_check("R13 激活", h.activate(&"REL_CROWN_TALLY"))
	_gl.player.gold = 0
	h._on_enemy_killed(_mk_enemy(GameConst.TAG_BOSS))
	_check("R13 生效：首领 +80", _gl.player.gold == 80, str(_gl.player.gold))
	h._on_enemy_killed(_mk_enemy(GameConst.TAG_ELITE))
	_check("R13 生效：精英 +30", _gl.player.gold == 110, str(_gl.player.gold))
	h._on_enemy_killed(_mk_enemy(0))
	_check("R13 域限：普通怪 +0", _gl.player.gold == 110, str(_gl.player.gold))


# ── R14 战地医师 ──────────────────────────────────────────────────
func _test_r14_field_medic() -> void:
	print("── R14 REL_FIELD_MEDIC ──")
	var h := _handler()
	h.reset_run()
	var max_hp: float = _gl.player.max_hp
	_gl.player.hp = 10.0
	h._on_wave_cleared(2)
	_check("R14 守卫：未持有 → 波末不回血", is_equal_approx(_gl.player.hp, 10.0))
	_check("R14 激活", h.activate(&"REL_FIELD_MEDIC"))
	_gl.player.hp = 10.0
	h._on_wave_cleared(2)
	_check("R14 生效：波末回 8%% max_hp（10 → 10+0.08×%.0f）" % max_hp,
		is_equal_approx(_gl.player.hp, 10.0 + max_hp * 0.08),
		str(_gl.player.hp))
	_gl.player.hp = max_hp
	h._on_wave_cleared(3)
	_check("R14 钳制：满血不溢出", is_equal_approx(_gl.player.hp, max_hp))


# ── R15 血税契约 ──────────────────────────────────────────────────
func _test_r15_blood_tithe() -> void:
	print("── R15 REL_BLOOD_TITHE ──")
	var h := _handler()
	h.reset_run()
	var e := _mk_enemy()
	_gl.player.gold = 50
	h._on_wave_started(3)
	_check("R15 守卫：未持有 → 不扣费", _gl.player.gold == 50)
	_check("R15 激活", h.activate(&"REL_BLOOD_TITHE"))
	_gl.player.gold = 50
	h._on_wave_started(3)
	_check("R15 扣费：波开始支付 10 金（50→40）", _gl.player.gold == 40,
		str(_gl.player.gold))
	_check("R15 生效：付费波 inject contrib 0.15",
		is_equal_approx(_pool_contrib(_inject_ctx(e), &"tithe_dmg"), 0.15),
		str(_pool_contrib(_inject_ctx(e), &"tithe_dmg")))
	_gl.player.gold = 5
	h._on_wave_started(4)
	_check("R15 欠费：金币不足不扣费本波失效", _gl.player.gold == 5
		and _pool_contrib(_inject_ctx(e), &"tithe_dmg") < 0.0)
	_gl.player.gold = 10
	h._on_wave_started(5)
	_check("R15 边界：恰足额（==cost）可付费（10→0 + 乘区在场）",
		_gl.player.gold == 0
		and is_equal_approx(_pool_contrib(_inject_ctx(e), &"tithe_dmg"), 0.15))
	_release_enemy(e)


# ── R16 引力井 ────────────────────────────────────────────────────
func _test_r16_gravity_well() -> void:
	print("── R16 REL_GRAVITY_WELL ──")
	var h := _handler()
	h.reset_run()
	var cg := _gl.card_generator
	var slots: Array = _gl.player.get("weapon_slots")
	var owned_weapons: Array[WeaponBase] = []
	for w in slots:
		if w is WeaponBase and is_instance_valid(w):
			owned_weapons.append(w)
	_check("R16 前置：boot 玩家持有 ≥1 武器", not owned_weapons.is_empty())
	# 基线（未持有）：种子扫描出含词条卡的批次（R246 豁免豁口——wave≥6 无保底替换）
	cg.owned_relics.clear()
	var base_seqs: Array = []
	for s in range(48):
		cg.rng.seed = s
		var batch := cg.generate_candidates({"player": _gl.player, "wave": 6})
		base_seqs.append(_batch_sig(batch))
	# 持有引力井：首张词条卡必 ∈「已装备武器任一可装备」子池
	cg.owned_relics.append(&"REL_GRAVITY_WELL")
	var trait_batches := 0
	var bias_ok := true
	var bias_bad := ""
	for s2 in range(48):
		cg.rng.seed = s2
		var batch2 := cg.generate_candidates({"player": _gl.player, "wave": 6})
		var first_trait: Dictionary = {}
		for card in batch2:
			if int(card.get("kind", -1)) == CardGenerator.CardKind.TRAIT:
				first_trait = card
				break
		if first_trait.is_empty():
			continue
		trait_batches += 1
		var td := first_trait.get("data") as TraitData
		var fits := false
		for w2 in owned_weapons:
			if CardGenerator.mount_gate_allows(td, w2):
				fits = true
				break
		if not fits:
			bias_ok = false
			bias_bad = "seed=%d 首词条 %s 不适配任何已装备武器" % [s2, String(td.id)]
			break
	_check("R16 生效：首张词条卡 ∈ 已装备武器可装备子池（48 种子扫描）",
		trait_batches > 0 and bias_ok, bias_bad)
	# 子池空回落：持有引力井时同种子批次序列仍确定（无 rng 新增消费——同种子两次逐项一致）
	cg.rng.seed = 7
	var seq_a := _batch_sig(cg.generate_candidates({"player": _gl.player, "wave": 6}))
	cg.rng.seed = 7
	var seq_b := _batch_sig(cg.generate_candidates({"player": _gl.player, "wave": 6}))
	_check("R16 rng 纪律：同种子两批逐项一致（子池收窄零新增 rng 消费）", seq_a == seq_b)
	cg.owned_relics.clear()                                   # 还原（R17/R18 需干净面）


func _batch_sig(p_batch: Array[Dictionary]) -> String:
	var parts: Array[String] = []
	for c in p_batch:
		parts.append("%s:%s" % [str(c.get("kind", -1)), String(c.get("id", &""))])
	return "|".join(parts)


# ── R17 权重三源 ──────────────────────────────────────────────────
func _test_r17_weight_three_sources() -> void:
	print("── R17 RELIC 权重三源 ──")
	var h := _handler()
	h.reset_run()
	_check("R17① 运行时真源 GameConfig.balance.category_weights[RELIC]==8.0（.tres 装载面）",
		is_equal_approx(float(_gc.get("balance").category_weights.get("RELIC", 0.0)), 8.0),
		str(_gc.get("balance").category_weights.get("RELIC")))
	_check("R17② 生成器运行时 dict card_generator.category_weights[RELIC]==8.0（setup 覆写后）",
		is_equal_approx(float(_gl.card_generator.category_weights.get("RELIC", 0.0)), 8.0),
		str(_gl.card_generator.category_weights.get("RELIC")))
	_check("R17③ const 镜像 CardGenerator.CATEGORY_WEIGHTS[RELIC]==8.0",
		is_equal_approx(float(CardGenerator.CATEGORY_WEIGHTS["RELIC"]), 8.0))
	var bt := BalanceTables.new()
	_check("R17④ 默认表 balance_tables.gd category_weights[RELIC]==8",
		is_equal_approx(float(bt.category_weights.get("RELIC", 0)), 8.0))
	# _unowned_relic_ids 含全部新件（unique 未持有 + 大关门：无局态 set_run_map("") 全开，
	# 断言后还原原值——mech_gate_cases「无局口径」同源）
	var prev_map: StringName = StringName(String(_meta.call("run_map_id")))
	_meta.call("set_run_map", &"")
	var unowned := _gl.card_generator._unowned_relic_ids()
	var missing := ""
	for rid in NEW_IDS:
		if not unowned.has(rid):
			missing = String(rid)
			break
	_meta.call("set_run_map", prev_map)
	_check("R17⑤ _unowned_relic_ids 含全部 16 新件（自动入池零登记）",
		missing == "", missing)


# ── reset 运行态清零联动 ──────────────────────────────────────────
func _test_reset_clearance() -> void:
	print("── R-reset 重开运行态清零 ──")
	var h := _handler()
	h.reset_run()
	var e := _mk_enemy()
	h.activate(&"REL_FAULTLESS_CHAIN")
	h.activate(&"REL_ELITE_WINDOW")
	h.activate(&"REL_FOCUS_MARK")
	h.activate(&"REL_RESONANT_TOUCH")
	h.activate(&"REL_LEVEL_TREASURY")
	h._on_enemy_killed(e)                                     # faultless +1 / window 置位
	_inject_ctx(e)                                            # focus 记忆 uid/层数
	h._on_reaction_triggered(0, Vector2.ZERO, 0)              # resonant 置层
	h._on_level_up_batch(2)                                   # 遥测计数
	h.activate(&"REL_BLOOD_TITHE")
	_gl.player.gold = 50
	h._on_wave_started(1)                                     # tithe 置位（gold 40）
	h.reset_run()
	_check("R-reset① 无瑕层清零", h._faultless_stacks == 0)
	_check("R-reset② 猎杀窗清零", h._elite_window_left == 0.0)
	_check("R-reset③ 印记目标/层数记忆清零",
		h._mark_target_iid == 0 and h._mark_steps == 0)
	_check("R-reset④ 共鸣层/窗清零",
		h._resonant_stacks == 0 and h._resonant_left == 0.0)
	_check("R-reset⑤ 血税波内有效位清零", not h._tithe_paid_wave)
	_check("R-reset⑥ uid 记忆表清空", h._uid_target_refs.is_empty())
	_check("R-reset⑦ owned 全清（遗物每场重新获取）", h.owned.is_empty())
	_release_enemy(e)


# ── R18 存档随档（r198_flow_weapon F1 同式） ──────────────────────
func _test_r18_save_restore() -> void:
	print("── R18 存档随档 ──")
	var h := _handler()
	h.reset_run()
	var started: bool = _gl.start_run()
	_check("R18 前置：start_run 进局", started and _gl.state == GameConst.GameStatus.PLAYING)
	_check("R18① 局内激活新件", h.activate(&"REL_GREED_MATRIX"))
	var snap := _gl.serialize_run()
	var ids: Array[String] = []
	for entry_v in snap.get("relics", []):
		if entry_v is Dictionary:
			ids.append(String((entry_v as Dictionary).get("id", "")))
	_check("R18② serialize_run.relics 含新件 id", ids.has("REL_GREED_MATRIX"), str(ids))
	RunSave.save_run(snap)
	if _gl.state == GameConst.GameStatus.PLAYING:
		_gl.change_state(GameConst.GameStatus.PAUSED)
	_gl.quit_to_menu()
	_check("R18③ 回菜单后 owned 清", _gl.state == GameConst.GameStatus.MENU
		and h.owned.is_empty())
	var resumed: bool = _gl.continue_run()
	_check("R18④ continue_run 恢复进局", resumed
		and _gl.state == GameConst.GameStatus.PLAYING)
	_check("R18⑤ 恢复后新件在册（常驻位随档）", h.has_relic(&"REL_GREED_MATRIX"))
	_gl.player.gold = 100
	var e := _mk_enemy()
	_check("R18⑥ 恢复后乘区生效（100 金 → greed_dmg 0.25）",
		is_equal_approx(_pool_contrib(_inject_ctx(e), &"greed_dmg"), 0.25),
		str(_pool_contrib(_inject_ctx(e), &"greed_dmg")))
	_release_enemy(e)

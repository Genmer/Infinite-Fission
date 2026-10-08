# tests/runner/r223_settlebudget_cases.gd
# R223 vc29 回归修复用例体（入口 test_r223_settlebudget.gd 运行时 load——-s 编译期
# 禁引工程类名纪律）。覆盖（tracker 二p #2/#4/#5）：
# ① 刀R：预算顺延基础——超帽命中 FIFO 顺延返回零值占位（不落血/不入派发队/穿透侧
#    消费语义由 deferred_merge 标记承载）+ 计数；
# ② 刀R：幂等先于预算——同帧同对重复命中折返回真结果（不占预算不顺延）；
# ③ 刀R：同对累积冲刷——顺延项 base 累积、帧头预算内一次真结算（期望 DPS 守恒）；
# ④ 刀R：死亡目标冲刷诚实丢弃 + 计数；
# ⑤ 刀R：过期强冲——12 帧窗外的积压帧末强制落账；
# ⑥ 刀R：硬帽修剪——>256 丢最老 + 计数；门关（override=0）积压全量冲刷不滞留；
# ⑦ 刀R：门控密封——headless 默认/强制关零扰动；-3 模拟真机门下 tier→帽映射逐档
#    （3→0 / 2→96 / 1→48）+ 特效优先恒 0；
# ⑧ Fix Q：vc29 场景复现——降档链 3→2→1 后选卡窗 fps120 样本不入 EMA（EMA 逐位
#    不动），6s 校验窗读纯战斗 EMA → 无效降档回升+冻结（pre-fix 该场景假「有效」
#    钉死 tier1——本用例即判别器）；
# ⑨ Fix Q：长选卡窗不开假升档窗（EMA 不被 120 拉高），恢复战斗后真 120 样本才升档。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null
var _released: Array[Enemy] = []


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_boot_game_loop()
	await tree.process_frame
	await tree.process_frame
	PerfGovernor.set_process(false)          # 引擎侧停走——用例手动 _process 确定性步进
	_gl.state = GameConst.GameStatus.MENU    # 刀R 用例态：真武器零开火（结算直驱管线）
	# 全用例零中途 await：同步段内引擎物理帧不插入（begin_frame 状态不被冲刷）
	_test_1_defer_basics()
	_test_2_idempotent_before_budget()
	_test_3_pair_accum_flush()
	_test_4_dead_flush_drop()
	_test_5_stale_force_flush()
	_test_6_overload_trim_and_gate_off_flush()
	_test_7_gate_hermeticity()
	_release_all()
	_gl.state = GameConst.GameStatus.PLAYING # Fix Q 用例态：零敌在场（无武器结算噪音）
	_test_8_q_vc29_card_window()
	_test_9_q_no_fake_recover()
	_release_all()
	_gl.state = GameConst.GameStatus.MENU    # 修轮用例回到直驱态
	_test_10_uid_reuse_guard()
	_test_11_kill_backlink_and_attach_skip()
	_test_12_combat_gating()
	await _cleanup()
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


func _boot_game_loop() -> void:
	var main: Node = load(MAIN_SCENE).instantiate()
	tree.root.add_child(main)
	_gl = tree.root.get_node_or_null("Main") as GameLoop
	if _gl == null:
		for c in tree.root.get_children():
			if c is GameLoop:
				_gl = c
				break


# ── 夹具 ──────────────────────────────────────────────────────────

func _fixture_enemy(p_id: StringName, p_hp: float) -> EnemyData:
	var d := EnemyData.new()
	d.id = p_id
	d.display_name = String(p_id)
	d.hp_base = p_hp
	d.spd_base = 0.0
	d.dmg_base = 0.0
	d.exp_base = 1.0
	d.hitbox_r = 14.0
	d.resist = [0.0, 0.0, 0.0, 0.0]
	return d


func _spawn_enemy(p_id: StringName, p_hp: float = 100000.0) -> Enemy:
	var pool := _gl.pools[&"enemy"] as EnemyPool
	var e := pool.acquire() as Enemy
	e.spawn(_fixture_enemy(p_id, p_hp), 1, 0)
	e._fade_left = 0.0
	e.modulate.a = 1.0
	_released.append(e)
	return e


func _release_all() -> void:
	var pool := _gl.pools[&"enemy"] as EnemyPool
	for e in _released:
		if is_instance_valid(e) and not e.dead:   # 击杀用例敌已随 _on_died 自动归池
			pool.release(e)
	_released.clear()


func _mk_ctx(p_source: int, p_target: Enemy, p_base: float, p_frame: int) -> DamageContext:
	var ctx := DamageContext.make()
	ctx.source_uid = p_source
	ctx.target_uid = p_target.uid
	ctx.target = p_target
	ctx.frame_stamp = p_frame
	ctx.base_atk = p_base
	ctx.crit_chance = 0.0
	ctx.crit_mult = 2.0
	ctx.pos = p_target.global_position
	return ctx


func _resolve(p_ctx: DamageContext) -> DamageResult:
	return _gl.pipeline.call(&"resolve", p_ctx) as DamageResult


func _stat(p_key: String) -> int:
	return int((_gl.pipeline.call(&"stats") as Dictionary).get(p_key, 0))


func _fifo_size() -> int:
	return (_gl.pipeline.get(&"_pending_fifo") as Array).size()


func _pstats(p_key: String) -> int:
	# PerfGovernor 静态读（用例体内直引 class_name——运行时已注册）
	match p_key:
		"tier":
			return PerfGovernor.tier
		"transitions":
			return PerfGovernor.transitions
	return -1


# ── ① 刀R：预算顺延基础 ───────────────────────────────────────────

func _test_1_defer_basics() -> void:
	print("── ① 刀R：预算顺延基础 ──")
	_check("①常量契约（帽 48/96 · 过期 12 · 硬帽 256）",
		DamagePipeline.SETTLE_BUDGET_T1 == 48 and DamagePipeline.SETTLE_BUDGET_T2 == 96
			and DamagePipeline.SETTLE_STALE_FRAME == 12
			and DamagePipeline.SETTLE_PENDING_HARD_CAP == 256, "")
	var e := _spawn_enemy(&"E_R223_A")
	var hp0 := e.hp
	DamagePipeline.settle_budget_override = 2
	_gl.pipeline.call(&"begin_frame", 100)
	var r1 := _resolve(_mk_ctx(7001, e, 10.0, 100))
	var r2 := _resolve(_mk_ctx(7002, e, 10.0, 100))
	var r3 := _resolve(_mk_ctx(7003, e, 10.0, 100))
	_check("①帽内两发真结算（final>0 · 非占位 · 落血 20）",
		r1 != null and r2 != null and r1.final_value > 0.0 and not r1.deferred_merge
			and absf(e.hp - (hp0 - 20.0)) < 0.001,
		"hp=%.1f" % e.hp)
	_check("①超帽第三发零值占位（final=0 · killed=false · deferred_merge=true）",
		r3 != null and r3.final_value == 0.0 and not r3.killed and r3.deferred_merge, "")
	_check("①占位不落血（hp 仍 hp0−20）", absf(e.hp - (hp0 - 20.0)) < 0.001,
		"hp=%.1f" % e.hp)
	_check("①计数（settles=2 · settle_deferred=1）",
		_stat("settles") >= 2 and _stat("settle_deferred") >= 1,
		"settles=%d deferred=%d" % [_stat("settles"), _stat("settle_deferred")])
	_check("①占位不入派发队（队列恰 2 条）",
		(_gl.pipeline.get(&"_resolved_queue") as Array).size() == 2, "")
	_gl.pipeline.call(&"end_frame")
	DamagePipeline.settle_budget_override = -1
	_gl.pipeline.get(&"_pending_pair").clear()
	(_gl.pipeline.get(&"_pending_fifo") as Array).clear()


# ── ② 刀R：幂等先于预算 ───────────────────────────────────────────

func _test_2_idempotent_before_budget() -> void:
	print("── ② 刀R：幂等先于预算 ──")
	var e := _spawn_enemy(&"E_R223_B")
	DamagePipeline.settle_budget_override = 1
	var dupe0 := _stat("dropped_dupe")
	var def0 := _stat("settle_deferred")
	_gl.pipeline.call(&"begin_frame", 200)
	var ra := _resolve(_mk_ctx(7101, e, 10.0, 200))
	var rb := _resolve(_mk_ctx(7101, e, 10.0, 200))   # 同帧同对重复：幂等折返
	var rc := _resolve(_mk_ctx(7102, e, 5.0, 200))    # 预算耗尽后新对：顺延
	_check("②同帧同对折返回真结果（非占位）",
		rb != null and not rb.deferred_merge and rb == ra, "")
	_check("②占位不污染幂等缓存（rc 为占位非缓存真值）",
		rc != null and rc.deferred_merge, "")
	# R223 修轮 QA-2：顺延占位入幂等缓存——同键二次 resolve 折返占位（不再并入 base）
	var rc2 := _resolve(_mk_ctx(7102, e, 5.0, 200))
	_check("②修QA-2：同键占位折返（rc2==rc 同一占位实例）",
		rc2 == rc and rc2.deferred_merge, "")
	_check("②折返/占位折返计账（dupe+2 · deferred 仅新对 +1）",
		_stat("dropped_dupe") == dupe0 + 2 and _stat("settle_deferred") == def0 + 1,
		"dupe=%d deferred=%d" % [_stat("dropped_dupe") - dupe0, _stat("settle_deferred") - def0])
	_gl.pipeline.call(&"end_frame")
	DamagePipeline.settle_budget_override = -1
	_gl.pipeline.get(&"_pending_pair").clear()
	(_gl.pipeline.get(&"_pending_fifo") as Array).clear()


# ── ③ 刀R：同对累积冲刷 ───────────────────────────────────────────

func _test_3_pair_accum_flush() -> void:
	print("── ③ 刀R：同对累积冲刷（跨帧形态——QA-2 修复后同帧同键走占位折返） ──")
	var e := _spawn_enemy(&"E_R223_C")
	var hp0 := e.hp
	DamagePipeline.settle_budget_override = 1
	_gl.pipeline.call(&"begin_frame", 300)
	_resolve(_mk_ctx(7201, e, 10.0, 300))            # X：帽内真结算（预算耗尽）
	_resolve(_mk_ctx(7202, e, 5.0, 300))             # C：顺延 [C]
	_resolve(_mk_ctx(7203, e, 10.0, 300))            # A：顺延 [C,A]
	_check("③双顺延在队（FIFO=2）", _fifo_size() == 2, "fifo=%d" % _fifo_size())
	_gl.pipeline.call(&"end_frame")
	var def_mid := _stat("settle_deferred")
	_gl.pipeline.call(&"begin_frame", 301)           # 帧头冲刷 C（预算耗尽）
	_resolve(_mk_ctx(7203, e, 15.0, 301))            # A 跨帧再中（键含帧号——无占位
	                                                 # 折返，并入既有项 base 10+15）
	_check("③跨帧同对并入（FIFO 仍 1 · deferred +1 · hp 扣 X+C=15）",
		_fifo_size() == 1 and _stat("settle_deferred") == def_mid + 1
			and absf(e.hp - (hp0 - 15.0)) < 0.001,
		"fifo=%d def+%d hp=%.1f" % [_fifo_size(), _stat("settle_deferred") - def_mid, e.hp])
	_gl.pipeline.call(&"end_frame")
	_gl.pipeline.call(&"begin_frame", 302)           # 帧头冲刷 A：base 25 一次真结算
	_check("③冲刷一次真结算（累积 base 25 全额落账 · FIFO 清空）",
		absf(e.hp - (hp0 - 40.0)) < 0.001 and _fifo_size() == 0,
		"hp=%.1f（期望 hp0−40）fifo=%d" % [e.hp, _fifo_size()])
	_gl.pipeline.call(&"end_frame")
	DamagePipeline.settle_budget_override = -1


# ── ④ 刀R：死亡目标冲刷丢弃 ───────────────────────────────────────

func _test_4_dead_flush_drop() -> void:
	print("── ④ 刀R：死亡目标冲刷诚实丢弃 ──")
	var e := _spawn_enemy(&"E_R223_D")
	DamagePipeline.settle_budget_override = 1
	_gl.pipeline.call(&"begin_frame", 400)
	_resolve(_mk_ctx(7301, e, 10.0, 400))            # 帽内真结算
	_resolve(_mk_ctx(7302, e, 10.0, 400))            # 顺延
	var hp_dead := e.hp
	e.dead = true                                      # 目标亡于冲刷前（死亡新星次级常见态）
	var dead0 := _stat("settle_flush_dead")
	var flush0 := _stat("settle_flush")
	_gl.pipeline.call(&"begin_frame", 401)           # 帧头冲刷遇亡目标
	_check("④亡目标冲刷诚实丢弃（settle_flush_dead +1 · settle_flush 不增）",
		_stat("settle_flush_dead") == dead0 + 1 and _stat("settle_flush") == flush0,
		"dead+%d flush+%d" % [_stat("settle_flush_dead") - dead0, _stat("settle_flush") - flush0])
	_check("④亡目标零落血", e.hp == hp_dead, "hp=%.1f" % e.hp)
	e.dead = false
	_gl.pipeline.call(&"end_frame")
	DamagePipeline.settle_budget_override = -1


# ── ⑤ 刀R：过期强冲 ───────────────────────────────────────────────

func _test_5_stale_force_flush() -> void:
	print("── ⑤ 刀R：过期强冲（12 帧窗外帧末落账） ──")
	var e := _spawn_enemy(&"E_R223_E")
	var hp0 := e.hp
	DamagePipeline.settle_budget_override = 1
	_gl.pipeline.call(&"begin_frame", 500)
	_resolve(_mk_ctx(7401, e, 10.0, 500))            # 帽内真结算
	for i in 30:
		_resolve(_mk_ctx(7500 + i, e, 1.0, 500))     # 30 对顺延（FIFO 30 项）
	_check("⑤30 对顺延在队（FIFO=30）", _fifo_size() == 30, "fifo=%d" % _fifo_size())
	var stale0 := _stat("settle_stale_flush")
	var flush0 := _stat("settle_flush")
	for f in range(501, 514):                        # 13 帧：每帧预算 1 仅冲刷队头 1 项
		_gl.pipeline.call(&"begin_frame", f)
		_gl.pipeline.call(&"end_frame")              # 帧末维护：窗外项强冲
	var stale_n := _stat("settle_stale_flush") - stale0
	var drain_n := _stat("settle_flush") - flush0 - stale_n
	_check("⑤过期强冲触发（stale_flush ≥ 15 且 FIFO 清空）",
		stale_n >= 15 and _fifo_size() == 0,
		"stale=%d fifo=%d" % [stale_n, _fifo_size()])
	_check("⑤账目守恒（预算冲刷+过期强冲 = 30 · hp 扣 10+30）",
		drain_n + stale_n == 30 and absf(e.hp - (hp0 - 40.0)) < 0.001,
		"drain=%d stale=%d hp=%.1f（期望 hp0−40）" % [drain_n, stale_n, e.hp])
	DamagePipeline.settle_budget_override = -1


# ── ⑥ 刀R：硬帽修剪 + 门关全量冲刷 ─────────────────────────────────

func _test_6_overload_trim_and_gate_off_flush() -> void:
	print("── ⑥ 刀R：硬帽修剪 + 门关全量冲刷 ──")
	var e := _spawn_enemy(&"E_R223_F")
	var hp0 := e.hp
	DamagePipeline.settle_budget_override = 1
	var stale_pre := _stat("settle_stale_flush")
	_gl.pipeline.call(&"begin_frame", 600)
	_resolve(_mk_ctx(7601, e, 10.0, 600))            # 帽内真结算
	for i in 300:
		_resolve(_mk_ctx(7700 + i, e, 1.0, 600))     # 300 对顺延 → 帧末硬帽修剪
	_gl.pipeline.call(&"end_frame")
	var drop0 := _stat("settle_overload_drop")
	_check("⑥硬帽修剪（FIFO=256 · overload_drop ≥ 44）",
		_fifo_size() == 256 and drop0 >= 44,
		"fifo=%d drop=%d" % [_fifo_size(), drop0])
	_check("⑥修剪后帧序未强冲（同帧龄 0 < 12——stale 零增）",
		_stat("settle_stale_flush") == stale_pre,
		"stale+%d" % [_stat("settle_stale_flush") - stale_pre])
	DamagePipeline.settle_budget_override = -2       # 门关
	var flush0 := _stat("settle_flush")
	_gl.pipeline.call(&"begin_frame", 601)           # 门关路径：积压立即全量冲刷
	_check("⑥门关全量冲刷（FIFO 清空 · settle_flush +256）",
		_fifo_size() == 0 and _stat("settle_flush") == flush0 + 256,
		"fifo=%d flush+%d" % [_fifo_size(), _stat("settle_flush") - flush0])
	_check("⑥伤害守恒（hp 扣 10+256——被修剪 44 项为诚实卸载不计入）",
		absf(e.hp - (hp0 - 266.0)) < 0.001, "hp=%.1f" % e.hp)
	DamagePipeline.settle_budget_override = -1


# ── ⑦ 刀R：门控密封 + tier 映射 ───────────────────────────────────

func _test_7_gate_hermeticity() -> void:
	print("── ⑦ 刀R：门控密封 + tier→帽映射 ──")
	var e := _spawn_enemy(&"E_R223_G")
	_check("⑦headless 默认帽 0（既有套件零扰动前提）",
		DamagePipeline._settle_cap_now() == 0, "")
	DamagePipeline.settle_budget_override = -2
	_check("⑦强制关帽 0", DamagePipeline._settle_cap_now() == 0, "")
	var def0 := _stat("settle_deferred")
	_gl.pipeline.call(&"begin_frame", 700)
	for i in 5:
		var r := _resolve(_mk_ctx(7800 + i, e, 3.0, 700))
		if r == null or r.deferred_merge:
			_check("⑦帽 0 全真结算（第 %d 发）" % i, false, "占位泄漏")
			break
	_check("⑦帽 0 零顺延（settle_deferred 不增）", _stat("settle_deferred") == def0, "")
	_gl.pipeline.call(&"end_frame")
	# -3 模拟真机门：tier→帽映射逐档 + 特效优先恒 0
	DamagePipeline.settle_budget_override = -3
	PerfGovernor.mode_override = 0
	PerfGovernor.tier_override = 3
	_check("⑦模拟真机门：tier3 → 帽 0", DamagePipeline._settle_cap_now() == 0, "")
	PerfGovernor.tier_override = 2
	_check("⑦模拟真机门：tier2 → 帽 96", DamagePipeline._settle_cap_now() == 96, "")
	PerfGovernor.tier_override = 1
	_check("⑦模拟真机门：tier1 → 帽 48", DamagePipeline._settle_cap_now() == 48, "")
	PerfGovernor.mode_override = 1
	_check("⑦特效优先 → 帽 0（刀仅帧率优先）", DamagePipeline._settle_cap_now() == 0, "")
	PerfGovernor.mode_override = -1
	PerfGovernor.tier_override = -1
	PerfGovernor.tier = 2
	_check("⑦真值 tier2（tier_override 撤销）→ 帽 96", DamagePipeline._settle_cap_now() == 96, "")
	PerfGovernor.tier = 3
	DamagePipeline.settle_budget_override = -1
	_check("⑦恢复默认后帽回 0", DamagePipeline._settle_cap_now() == 0, "")


# ── ⑧ Fix Q：vc29 选卡窗场景复现 ──────────────────────────────────

func _test_8_q_vc29_card_window() -> void:
	print("── ⑧ Fix Q：vc29 选卡窗场景复现 ──")
	PerfGovernor.mode_override = -1
	PerfGovernor.tier_override = -1
	PerfGovernor.tier = 3
	PerfGovernor.transitions = 0
	PerfGovernor._ema_inject = 35.0                 # 0.29×120：深载战斗帧率
	PerfGovernor._test_reset()
	_gl.state = GameConst.GameStatus.PLAYING
	tree.paused = false
	for i in 8:                                       # 4s：3→2→1 降档链（每档 2s）
		PerfGovernor._process(PerfGovernor.SAMPLE_S)
	_check("⑧降档链 3→1（tier=1 · transitions=2）",
		PerfGovernor.tier == 1 and PerfGovernor.transitions == 2,
		"tier=%d trans=%d" % [PerfGovernor.tier, PerfGovernor.transitions])
	var ema_battle := PerfGovernor._ema
	_gl.state = GameConst.GameStatus.LEVEL_UP        # 选卡窗：fps120 样本 2s
	PerfGovernor._ema_inject = 120.0
	for i in 4:
		PerfGovernor._process(PerfGovernor.SAMPLE_S)
	_check("⑧选卡窗样本不入 EMA（逐位不动=%.2f）" % ema_battle,
		absf(PerfGovernor._ema - ema_battle) < 0.001,
		"ema=%.2f（期望 %.2f）" % [PerfGovernor._ema, ema_battle])
	_check("⑧选卡窗零档变（tier 仍 1 · 无假升档）",
		PerfGovernor.tier == 1 and PerfGovernor.transitions == 2,
		"tier=%d trans=%d" % [PerfGovernor.tier, PerfGovernor.transitions])
	_gl.state = GameConst.GameStatus.PLAYING          # 恢复战斗：6s 校验窗读纯战斗 EMA
	PerfGovernor._ema_inject = 35.0
	for i in 12:                                      # 6s 战斗态：hold 至 EFFECT_CHECK_S
		PerfGovernor._process(PerfGovernor.SAMPLE_S)
	_check("⑧无效降档回升+冻结（tier=2 · transitions=3 · frozen）——pre-fix 判别器",
		PerfGovernor.tier == 2 and PerfGovernor.transitions == 3 and PerfGovernor._drop_frozen,
		"tier=%d trans=%d frozen=%s" % [PerfGovernor.tier, PerfGovernor.transitions,
			str(PerfGovernor._drop_frozen)])
	_check("⑧校验窗关闭复位（_drop_ema=-1 · hold=0）",
		PerfGovernor._drop_ema == -1.0 and PerfGovernor._drop_hold == 0.0, "")


# ── ⑨ Fix Q：长选卡窗不开假升档窗 ─────────────────────────────────

func _test_9_q_no_fake_recover() -> void:
	print("── ⑨ Fix Q：长选卡窗不开假升档窗 ──")
	PerfGovernor.tier = 3
	PerfGovernor.transitions = 0
	PerfGovernor._ema_inject = 35.0
	PerfGovernor._test_reset()
	_gl.state = GameConst.GameStatus.PLAYING
	for i in 4:                                       # 3→2 一档降
		PerfGovernor._process(PerfGovernor.SAMPLE_S)
	_check("⑨降一档基线（tier=2）", PerfGovernor.tier == 2, "tier=%d" % PerfGovernor.tier)
	var ema_battle := PerfGovernor._ema
	_gl.state = GameConst.GameStatus.LEVEL_UP        # 长选卡窗 5s 的 120 样本
	PerfGovernor._ema_inject = 120.0
	for i in 10:
		PerfGovernor._process(PerfGovernor.SAMPLE_S)
	_check("⑨长窗零假升档（tier 仍 2 · EMA 不动）",
		PerfGovernor.tier == 2 and PerfGovernor.transitions == 1
			and absf(PerfGovernor._ema - ema_battle) < 0.001,
		"tier=%d trans=%d ema=%.2f" % [PerfGovernor.tier, PerfGovernor.transitions,
			PerfGovernor._ema])
	_gl.state = GameConst.GameStatus.PLAYING          # 恢复战斗：真样本驱动的恢复通道
	PerfGovernor._test_reset()                        # EMA 清空——首采直赋避开 35→120
	PerfGovernor._ema_inject = 119.0                 # 收敛带（>0.95×120 但 <120 帽）
	for i in 10:                                      # 10×0.5s=5s 持续 → 真升档
		PerfGovernor._process(PerfGovernor.SAMPLE_S)
	_check("⑨战斗内真恢复通道照常（tier 回 3 · transitions=2）",
		PerfGovernor.tier == 3 and PerfGovernor.transitions == 2,
		"tier=%d trans=%d" % [PerfGovernor.tier, PerfGovernor.transitions])


# ── ⑩ 修轮：uid 复用防护（QA-1/评审#3 同锤） ──────────────────────

func _test_10_uid_reuse_guard() -> void:
	print("── ⑩ 修轮：冲刷 uid 复用防护 ──")
	var e := _spawn_enemy(&"E_R223_H")
	var hp0 := e.hp
	DamagePipeline.settle_budget_override = 1
	_gl.pipeline.call(&"begin_frame", 800)
	_resolve(_mk_ctx(7901, e, 10.0, 800))            # 帽内真结算
	_resolve(_mk_ctx(7902, e, 50.0, 800))            # 顺延（死亡新星次级常见态）
	var uid_old := e.uid
	e.uid = uid_old + 1                              # 模拟池节点复用 spawn() 派新 uid
	                                              # （同帧 LIFO 取回同节点——QA P2c2 形态）
	var reuse0 := _stat("settle_flush_reuse")
	var dead0 := _stat("settle_flush_dead")
	var hp_reused := e.hp
	_gl.pipeline.call(&"begin_frame", 801)           # 帧头冲刷：uid 不符 → 诚实丢弃
	_check("⑩uid 不符丢弃（settle_flush_reuse +1 · flush_dead 不增）",
		_stat("settle_flush_reuse") == reuse0 + 1 and _stat("settle_flush_dead") == dead0,
		"reuse+%d dead+%d" % [_stat("settle_flush_reuse") - reuse0,
			_stat("settle_flush_dead") - dead0])
	_check("⑩新身份零幻影伤害（hp 仍 hp0−10）", absf(e.hp - (hp0 - 10.0)) < 0.001,
		"hp=%.1f（复用时 %.1f）" % [e.hp, hp_reused])
	e.uid = uid_old                                   # 复位（归还前还原池语义）
	_gl.pipeline.call(&"end_frame")
	DamagePipeline.settle_budget_override = -1


# ── ⑪ 修轮：冲刷击杀证据回填（评审 high）+ 附着跳过（评审#2） ──────

func _test_11_kill_backlink_and_attach_skip() -> void:
	print("── ⑪ 修轮：击杀证据回填 + 顺延附着跳过 ──")
	var pool := _gl.pools[&"projectile"] as ProjectilePool
	var proj := pool.acquire()
	proj.damage_pipeline = _gl.pipeline
	proj.enemy_grid = _gl.enemy_grid
	proj.pool = pool
	proj.spawn({
		"velocity": Vector2(60.0, 0.0), "lifetime": 10.0, "pierce": 2, "team": 0,
		"panel_snapshot": {"base_atk": 100.0, "flat_bonus": 0.0,
			"crit_rate": 0.0, "crit_mult": 2.0, "add_entries": []},
		"position": Vector2.ZERO,
	})
	var ek := _spawn_enemy(&"E_R223_KILL", 30.0)     # 30 hp：冲刷 base 100 必杀
	var ctx := proj._build_damage_ctx(ek)             # kill_backlink 由构建口挂 weakref(self)
	ctx.frame_stamp = 850                             # 对齐本用例帧号轴（构建口读
	                                                 # GameConfig.frame_stamp≈用例首帧——
	                                                 # 显式覆写防过期窗误判陈旧）
	DamagePipeline.settle_budget_override = 1
	_gl.pipeline.call(&"begin_frame", 850)
	_resolve(_mk_ctx(7911, ek, 5.0, 850))             # 帽内真结算（预算耗尽；ek 25hp 存活）
	var r_def := _resolve(ctx)                        # 弹侧 ctx 顺延（base 100 → 冲刷必杀）
	_check("⑪顺延占位（deferred_merge）", r_def != null and r_def.deferred_merge, "")
	_gl.pipeline.call(&"end_frame")
	_gl.pipeline.call(&"begin_frame", 851)           # 帧头冲刷：击杀 + 证据回填
	_check("⑪冲刷击杀回填 killed_target（弹存活期证据——死亡新星消费面）",
		proj.killed_target and ek.dead,
		"killed=%s dead=%s" % [str(proj.killed_target), str(ek.dead)])
	_gl.pipeline.call(&"end_frame")
	# 负例：归池弹（_live=false）不回填——晚到证据已无消费点
	var proj2 := pool.acquire()
	proj2.damage_pipeline = _gl.pipeline
	proj2.enemy_grid = _gl.enemy_grid
	proj2.pool = pool
	proj2.spawn({
		"velocity": Vector2(60.0, 0.0), "lifetime": 10.0, "pierce": 2, "team": 0,
		"panel_snapshot": {"base_atk": 100.0, "flat_bonus": 0.0,
			"crit_rate": 0.0, "crit_mult": 2.0, "add_entries": []},
		"position": Vector2.ZERO,
	})
	proj2._live = false
	var ek2 := _spawn_enemy(&"E_R223_KILL2", 30.0)
	var ctx2 := proj2._build_damage_ctx(ek2)
	ctx2.frame_stamp = 852
	_gl.pipeline.call(&"begin_frame", 852)
	_resolve(_mk_ctx(7912, ek2, 5.0, 852))            # 帽内（预算耗尽）
	_resolve(ctx2)                                    # 顺延（kill_backlink=proj2 已亡形）
	_gl.pipeline.call(&"end_frame")
	_gl.pipeline.call(&"begin_frame", 853)           # 冲刷击杀——proj2 不回填
	_check("⑪归池弹不回填（_live=false 晚到证据丢弃）",
		ek2.dead and not proj2.killed_target,
		"dead=%s killed=%s" % [str(ek2.dead), str(proj2.killed_target)])
	_gl.pipeline.call(&"end_frame")
	# 附着跳过（评审#2）：占位命中跳过 apply_attach——真结果照常提交
	var spy := ElementalSpy.new()
	proj2._live = true
	proj2.elemental = spy
	proj2.element = GameConst.Element.FIR
	proj2.attach_value = 5.0
	var ek3 := _spawn_enemy(&"E_R223_ATTACH", 100000.0)
	var ph := DamageResult.new()
	ph.deferred_merge = true
	proj2._apply_elemental(ek3, ph, TraitContext.new())
	_check("⑪顺延占位跳过附着（apply_attach 零调用——感电连锁 0 伤空放根除）",
		spy.attach_calls == 0, "calls=%d" % spy.attach_calls)
	var real_r := DamageResult.new()
	real_r.final_value = 5.0
	proj2._apply_elemental(ek3, real_r, TraitContext.new())
	_check("⑪真结果附着照常（apply_attach 1 次）",
		spy.attach_calls == 1, "calls=%d" % spy.attach_calls)
	proj2.elemental = null
	pool.release(proj)
	pool.release(proj2)
	DamagePipeline.settle_budget_override = -1


class ElementalSpy extends ElementalSystem:
	# 附着间谍（⑪ 用例——elemental 强类型依赖位的最小桩：仅覆写 apply_attach 计数，
	# 不入树不跑引擎 tick；签名随父类含默认参）
	var attach_calls: int = 0
	func apply_attach(_t: Node2D, _e: int, _v: float, _p: Dictionary = {}) -> void:
		attach_calls += 1


# ── ⑫ 修轮：暂停/选卡窗冲刷挂起（战斗冻结契约） ───────────────────

func _test_12_combat_gating() -> void:
	print("── ⑫ 修轮：非战斗帧冲刷挂起 ──")
	var e := _spawn_enemy(&"E_R223_PAUSE")
	var hp0 := e.hp
	DamagePipeline.settle_budget_override = 1
	_gl.pipeline.call(&"begin_frame", 900)
	_resolve(_mk_ctx(7921, e, 10.0, 900))            # 帽内真结算
	_resolve(_mk_ctx(7922, e, 7.0, 900))             # 顺延 [Y]
	_gl.pipeline.call(&"end_frame")
	var flush0 := _stat("settle_flush")
	for f in range(901, 920):                        # 19 帧非战斗（暂停/选卡窗形态）：
		_gl.pipeline.call(&"begin_frame", f, false)  # 冲刷挂起 + 帧末维护挂起
		_gl.pipeline.call(&"end_frame")              # （帧龄 19 > 12 也不强冲）
	_check("⑫非战斗帧零冲刷零强冲（FIFO=1 · hp 仍 hp0−10）",
		_fifo_size() == 1 and _stat("settle_flush") == flush0
			and absf(e.hp - (hp0 - 10.0)) < 0.001,
		"fifo=%d flush+%d hp=%.1f" % [_fifo_size(), _stat("settle_flush") - flush0, e.hp])
	_gl.pipeline.call(&"begin_frame", 921, true)     # 恢复战斗：首帧统一冲刷
	_check("⑫恢复战斗冲刷落账（hp 扣 17 · FIFO 清空）",
		absf(e.hp - (hp0 - 17.0)) < 0.001 and _fifo_size() == 0,
		"hp=%.1f fifo=%d" % [e.hp, _fifo_size()])
	_gl.pipeline.call(&"end_frame")
	DamagePipeline.settle_budget_override = -1


func _cleanup() -> void:
	DamagePipeline.settle_budget_override = -1
	_gl.pipeline.get(&"_pending_pair").clear()
	(_gl.pipeline.get(&"_pending_fifo") as Array).clear()
	(_gl.pipeline.get(&"_resolved_queue") as Array).clear()
	PerfGovernor.mode_override = -1
	PerfGovernor.tier_override = -1
	PerfGovernor._ema_inject = -1.0
	PerfGovernor.tier = 3
	PerfGovernor.transitions = 0
	PerfGovernor._test_reset()
	PerfGovernor.set_process(true)
	tree.paused = false
	_release_all()
	if _gl != null:
		_gl.queue_free()
		await tree.process_frame

# tests/runner/qa_r223_edge_cases.gd
# R223 修轮 QA 复测边角用例体（入口 test_qa_r223_edge.gd 运行时 load——-s 编译期禁引
# 工程类名纪律）。补两套既修套件（r223_settlebudget ⑩⑪⑫ / qa_r223_probe P2c2·P4b）
# 未覆盖的修后新边角，不复述其断言形状：
#  E1  kill_backlink 对 HomingProjectile 的覆盖：直击 builder 挂链动态断言 + 顺延冲刷
#      击杀回填功能链（Homing 三结算位——直击/溅射 _blast_secondaries/余波——按
#      homing_projectile.gd 全部经同一 _build_damage_ctx(super) 构建，builder 断言即
#      覆盖三位的挂链一致性；功能链动态验证其中直击位）
#  E2a 预算冲刷：队头连续 uid 复用丢弃不耗预算（drop 不占预算 → 同帧头继续冲后续项）
#  E2b FIFO 中段遇 uid 复用项：头项复用丢弃 + 后项照常真结算（账目恒等式）
#  E2c 帧末过期强冲中段 remove_at + uid 复用丢弃混合形态（13 帧预算排空 → 窗外强冲
#      真结算 ×2 + 复用丢弃 ×1，账目恒等式 deferred=预算+强冲+亡丢+复用+超载）
#  E3  暂停窗内泄漏 resolve 的顺延语义（非战斗帧 _settle_left=0 → 泄漏命中走顺延占位、
#      同键 dupe 折返占位；暂停窗龄超 12 帧不强冲；恢复战斗首帧统一冲刷）
#  E4  顺/冲/弃遥测差分在 1Hz 拉取下的正确性（首拉立基线、变更期差分逐轴对账、
#      重复拉取增量归零——diag_counts 经 _diag_pipe_delta 三轴）
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null
var _field: Array[Enemy] = []
var _saved_budget: int = -1


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_boot_game_loop()
	await tree.process_frame
	await tree.process_frame
	PerfGovernor.set_process(false)
	_saved_budget = DamagePipeline.settle_budget_override
	_gl.state = GameConst.GameStatus.MENU
	tree.paused = false
	_e1_homing_backlink()
	_e2a_flush_head_reuse_no_budget()
	_e2b_fifo_mid_reuse()
	_e2c_stale_mid_reuse()
	_e3_pause_leak_defer()
	_e4_diag_delta()
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


func _spawn_enemy(p_id: StringName, p_hp: float = 100000.0, p_pos: Vector2 = Vector2.ZERO) -> Enemy:
	var pool := _gl.pools[&"enemy"] as EnemyPool
	var e := pool.acquire() as Enemy
	e.spawn(_fixture_enemy(p_id, p_hp), 1, 0)
	e._fade_left = 0.0
	e.modulate.a = 1.0
	e.position = p_pos
	if not _gl.spawner.active.has(e):
		_gl.spawner.active.append(e)
	_field.append(e)
	return e


func _release_enemy(p_e: Enemy) -> void:
	_gl.spawner.active.erase(p_e)
	_field.erase(p_e)
	if not p_e.dead:                            # 已亡敌归池口在死亡路径（重复归还拒绝）
		(_gl.pools[&"enemy"] as EnemyPool).release(p_e)


func _field_clear() -> void:
	for e in _field.duplicate():
		if is_instance_valid(e) and not e.dead:   # 击杀敌已随死亡路径自动归池
			_gl.spawner.active.erase(e)
			(_gl.pools[&"enemy"] as EnemyPool).release(e)
		elif is_instance_valid(e):
			_gl.spawner.active.erase(e)
	_field.clear()
	_gl.enemy_grid.rebuild(_gl.spawner.active)


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


func _pending_clear() -> void:
	_gl.pipeline.get(&"_pending_pair").clear()
	(_gl.pipeline.get(&"_pending_fifo") as Array).clear()
	(_gl.pipeline.get(&"_resolved_queue") as Array).clear()


# ── E1 kill_backlink × HomingProjectile ──────────────────────────

func _e1_homing_backlink() -> void:
	print("── E1 Homing kill_backlink：builder 挂链 + 顺延冲刷击杀回填功能链 ──")
	var pool_h: ProjectilePool = _gl.get(&"_homing_pool")
	var homing: ProjectileBase = pool_h.acquire() as ProjectileBase
	homing.damage_pipeline = _gl.pipeline
	homing.enemy_grid = _gl.enemy_grid
	homing.pool = pool_h
	homing.spawn({
		"velocity": Vector2(60.0, 0.0), "lifetime": 10.0, "pierce": 1, "team": 0,
		"panel_snapshot": {"base_atk": 100.0, "flat_bonus": 0.0, "crit_rate": 0.0,
			"crit_mult": 2.0, "add_entries": []},
		"position": Vector2.ZERO,
	})
	var ek := _spawn_enemy(&"E_QAE_HOM", 30.0, Vector2(300, 480))
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	var ctx := homing._build_damage_ctx(ek)
	var ref_ok: bool = ctx.kill_backlink != null and ctx.kill_backlink.get_ref() == homing
	_check("E1a Homing 直击 ctx 挂 kill_backlink（weakref 指回本弹——builder 单口三位共用）",
		ref_ok, "backlink=%s" % str(ctx.kill_backlink != null))
	# 功能链：弹侧 ctx 顺延 → 次帧头冲刷击杀 → killed_target 回填（弹存活期证据）
	ctx.frame_stamp = 2000
	DamagePipeline.settle_budget_override = 1
	_gl.pipeline.call(&"begin_frame", 2000)
	var _r0: DamageResult = _resolve(_mk_ctx(9200, ek, 5.0, 2000))   # 帽内真结算（25hp 残）
	var r_def: DamageResult = _resolve(ctx)                          # 弹 ctx 顺延（base 100 必杀）
	_gl.pipeline.call(&"end_frame")
	var backlink_alive: bool = homing._live
	_gl.pipeline.call(&"begin_frame", 2001)                          # 冲刷：击杀 + 回填
	_check("E1b Homing 顺延冲刷击杀回填 killed_target（_live 守卫内 · 死亡新星消费面）",
		r_def != null and r_def.deferred_merge and backlink_alive
			and ek.dead and homing.killed_target,
		"defer=%s live=%s dead=%s killed=%s" % [str(r_def != null and r_def.deferred_merge),
			str(backlink_alive), str(ek.dead), str(homing.killed_target)])
	_gl.pipeline.call(&"end_frame")
	pool_h.release(homing)
	DamagePipeline.settle_budget_override = -1
	_pending_clear()
	_field_clear()


# ── E2a 预算冲刷：队头连续复用丢弃不耗预算 ─────────────────────────

func _e2a_flush_head_reuse_no_budget() -> void:
	print("── E2a 冲刷队头 uid 复用连续丢弃不耗预算 ──")
	var pool := _gl.pools[&"enemy"] as EnemyPool
	var ea := _spawn_enemy(&"E_QAE_2AA")
	var eb := _spawn_enemy(&"E_QAE_2AB")
	var hp_a := ea.hp
	var hp_b := eb.hp
	DamagePipeline.settle_budget_override = 1
	var f := 2010
	_gl.pipeline.call(&"begin_frame", f)
	var _r1: DamageResult = _resolve(_mk_ctx(9210, ea, 10.0, f))     # 帽内真结算（预算尽）
	var d0 := _stat("settle_deferred")
	var _r2: DamageResult = _resolve(_mk_ctx(9211, eb, 10.0, f))     # B1 顺延
	var _r3: DamageResult = _resolve(_mk_ctx(9212, eb, 10.0, f))     # B2 顺延
	_gl.pipeline.call(&"end_frame")
	_check("E2a 前置：双顺延在队", _stat("settle_deferred") == d0 + 2 and _fifo_size() == 2,
		"fifo=%d" % _fifo_size())
	_release_enemy(eb)
	var m := pool.acquire() as Enemy
	var same_node: bool = m == eb
	m.spawn(_fixture_enemy(&"E_QAE_2AB2", 100000.0), 1, 0)           # 同节点新 uid 满血
	var reuse0 := _stat("settle_flush_reuse")
	var flush0 := _stat("settle_flush")
	_gl.pipeline.call(&"begin_frame", f + 1)                         # 帧头：B1/B2 均 uid 不符
	_check("E2a 队头双复用丢弃不耗预算（reuse+2 · flush+0 · FIFO 清空——drop 让预算留给后续项）",
		same_node and _stat("settle_flush_reuse") == reuse0 + 2
			and _stat("settle_flush") == flush0 and _fifo_size() == 0,
		"same=%s reuse+%d flush+%d fifo=%d" % [str(same_node),
			_stat("settle_flush_reuse") - reuse0, _stat("settle_flush") - flush0, _fifo_size()])
	_check("E2a 零幻影落账（复活节点 Δhp=0 · 帽内敌 Δ=-10）+ 恒等式 deferred2=复用2",
		absf(m.hp - hp_b) < 0.001 and absf(ea.hp - (hp_a - 10.0)) < 0.001
			and _stat("settle_deferred") == d0 + 2,
		"Δnew=%.1f Δa=%.1f def=%d" % [m.hp - hp_b, ea.hp - hp_a, _stat("settle_deferred") - d0])
	_release_enemy(m)
	DamagePipeline.settle_budget_override = -1
	_pending_clear()
	_field_clear()


# ── E2b FIFO 中段遇 uid 复用项 ────────────────────────────────────

func _e2b_fifo_mid_reuse() -> void:
	print("── E2b FIFO 中段 uid 复用：头项丢弃 + 后项照常真结算 ──")
	var pool := _gl.pools[&"enemy"] as EnemyPool
	var ec := _spawn_enemy(&"E_QAE_2BC")
	var ed := _spawn_enemy(&"E_QAE_2BD")
	var hp_c := ec.hp
	var hp_d := ed.hp
	DamagePipeline.settle_budget_override = 1
	var f := 2020
	_gl.pipeline.call(&"begin_frame", f)
	var _r1: DamageResult = _resolve(_mk_ctx(9220, ed, 10.0, f))     # 帽内真结算
	var d0 := _stat("settle_deferred")
	var _r2: DamageResult = _resolve(_mk_ctx(9221, ec, 10.0, f))     # C1 顺延（队头）
	var _r3: DamageResult = _resolve(_mk_ctx(9222, ed, 10.0, f))     # D1 顺延（队尾）
	_gl.pipeline.call(&"end_frame")
	_release_enemy(ec)                                               # 队头项目标亡→复用
	var m := pool.acquire() as Enemy
	var same_node: bool = m == ec
	m.spawn(_fixture_enemy(&"E_QAE_2BC2", 100000.0), 1, 0)
	var reuse0 := _stat("settle_flush_reuse")
	var flush0 := _stat("settle_flush")
	_gl.pipeline.call(&"begin_frame", f + 1)                         # 头 C1 复用丢弃 → 尾 D1 真结算
	_check("E2b 中段复用丢弃后预算照常冲尾项（reuse+1 · flush+1 · FIFO 清空）",
		same_node and _stat("settle_flush_reuse") == reuse0 + 1
			and _stat("settle_flush") == flush0 + 1 and _fifo_size() == 0,
		"same=%s reuse+%d flush+%d fifo=%d" % [str(same_node),
			_stat("settle_flush_reuse") - reuse0, _stat("settle_flush") - flush0, _fifo_size()])
	_check("E2b 账目逐位（复活节点 Δ0 · ed Δ-20 真结算+冲刷 · 恒等式 deferred2=flush1+reuse1）",
		absf(m.hp - hp_c) < 0.001 and absf(ed.hp - (hp_d - 20.0)) < 0.001
			and _stat("settle_deferred") == d0 + 2,
		"Δc=%.1f Δd=%.1f def=%d" % [m.hp - hp_c, ed.hp - hp_d, _stat("settle_deferred") - d0])
	_release_enemy(m)
	DamagePipeline.settle_budget_override = -1
	_pending_clear()
	_field_clear()


# ── E2c 过期强冲中段 remove_at + 复用丢弃混合 ─────────────────────

func _e2c_stale_mid_reuse() -> void:
	print("── E2c 过期强冲窗：真结算×2 + 中段复用丢弃混合账目 ──")
	var pool := _gl.pools[&"enemy"] as EnemyPool
	var en_e := _spawn_enemy(&"E_QAE_2CE")
	var en_f := _spawn_enemy(&"E_QAE_2CF")
	var hp_e := en_e.hp
	var hp_f := en_f.hp
	DamagePipeline.settle_budget_override = 1
	var f := 2030
	_gl.pipeline.call(&"begin_frame", f)
	var _r0: DamageResult = _resolve(_mk_ctx(9230, en_f, 10.0, f))   # 帽内真结算（enF 先挨 10）
	var hp_f_mid := en_f.hp                                          # 归还前已落账口径（复用重生后满血不可比）
	var d0 := _stat("settle_deferred")
	for i in 15:                                                     # E1..E15 顺延（base 1.0）
		var _ri: DamageResult = _resolve(_mk_ctx(9231 + i, en_e, 1.0, f))
	var _rz: DamageResult = _resolve(_mk_ctx(9246, en_f, 10.0, f))   # F1 顺延（队尾）
	_gl.pipeline.call(&"end_frame")
	_check("E2c 前置：16 对顺延在队", _stat("settle_deferred") == d0 + 16 and _fifo_size() == 16,
		"fifo=%d" % _fifo_size())
	_release_enemy(en_f)                                             # F1 目标复用（E 项不受影响）
	var m := pool.acquire() as Enemy
	var same_node: bool = m == en_f
	m.spawn(_fixture_enemy(&"E_QAE_2CF2", 100000.0), 1, 0)
	var reuse0 := _stat("settle_flush_reuse")
	var flush0 := _stat("settle_flush")
	var stale0 := _stat("settle_stale_flush")
	for k in range(1, 14):                                           # 13 帧：预算各冲 1（E1..E13）
		_gl.pipeline.call(&"begin_frame", f + k)
		_gl.pipeline.call(&"end_frame")
	# 帧末维护（age 13 > 12）：E14/E15 强冲真结算 + F1 uid 复用丢弃（中段 remove_at 路径）
	_check("E2c 混合强冲账目（stale+2 真结算 · reuse+1 · flush+15 · FIFO 清空）",
		same_node and _stat("settle_stale_flush") == stale0 + 2
			and _stat("settle_flush_reuse") == reuse0 + 1
			and _stat("settle_flush") == flush0 + 15 and _fifo_size() == 0,
		"same=%s stale+%d reuse+%d flush+%d fifo=%d" % [str(same_node),
			_stat("settle_stale_flush") - stale0, _stat("settle_flush_reuse") - reuse0,
			_stat("settle_flush") - flush0, _fifo_size()])
	_check("E2c 伤害守恒（enE Δ-15=13 预算+2 强冲 · enF 帽内真结算落账 hp_f_mid=hp_f-10）",
		absf(en_e.hp - (hp_e - 15.0)) < 0.001 and absf(hp_f_mid - (hp_f - 10.0)) < 0.001,
		"Δe=%.1f fmid=%.1f（期望 %.1f）" % [en_e.hp - hp_e, hp_f_mid - hp_f, -10.0])
	_check("E2c F1 复用零幻影 + 恒等式 deferred16=13+2+1（复活节点满血 · def 计 16）",
		absf(m.hp - hp_f) < 0.001 and _stat("settle_deferred") == d0 + 16,
		"Δnew=%.1f def=%d" % [m.hp - hp_f, _stat("settle_deferred") - d0])
	_release_enemy(m)
	DamagePipeline.settle_budget_override = -1
	_pending_clear()
	_field_clear()


# ── E3 暂停窗内泄漏 resolve 的顺延语义 ────────────────────────────

func _e3_pause_leak_defer() -> void:
	print("── E3 暂停窗泄漏 resolve：顺延占位 + 同键折返 + 窗内不强冲 + 恢复冲刷 ──")
	var en_g := _spawn_enemy(&"E_QAE_3G")
	var hp_g := en_g.hp
	DamagePipeline.settle_budget_override = 1
	var p := 2040
	_gl.pipeline.call(&"begin_frame", p, false)                      # 非战斗帧：预算不武装
	var d0 := _stat("settle_deferred")
	var r_leak: DamageResult = _resolve(_mk_ctx(9250, en_g, 10.0, p))  # 泄漏命中
	var r_dupe: DamageResult = _resolve(_mk_ctx(9250, en_g, 10.0, p))  # 同键 dupe
	_check("E3 泄漏命中走顺延占位（预算未武装）+ 同键 dupe 折返同一占位（幂等跨战斗门成立）",
		r_leak != null and r_leak.deferred_merge and r_dupe == r_leak
			and _stat("settle_deferred") == d0 + 1 and _fifo_size() == 1
			and absf(en_g.hp - hp_g) < 0.001,
		"dupe_same=%s fifo=%d Δhp=%.1f" % [str(r_dupe == r_leak), _fifo_size(), en_g.hp - hp_g])
	var flush0 := _stat("settle_flush")
	for k in range(1, 16):                                           # 15 帧非战斗（age 15 > 12）
		_gl.pipeline.call(&"begin_frame", p + k, false)
		_gl.pipeline.call(&"end_frame")
	_check("E3 暂停窗零冲刷零强冲（窗龄 15 超过期窗仍挂起——AC-16.2 冻结契约）",
		_stat("settle_flush") == flush0 and _fifo_size() == 1
			and absf(en_g.hp - hp_g) < 0.001,
		"flush+%d fifo=%d Δhp=%.1f" % [_stat("settle_flush") - flush0, _fifo_size(),
			en_g.hp - hp_g])
	_gl.pipeline.call(&"begin_frame", p + 16, true)                  # 恢复战斗首帧统一冲刷
	_check("E3 恢复战斗冲刷落账（Δ-10 · FIFO 清空）",
		absf(en_g.hp - (hp_g - 10.0)) < 0.001 and _fifo_size() == 0,
		"Δhp=%.1f fifo=%d" % [en_g.hp - hp_g, _fifo_size()])
	_gl.pipeline.call(&"end_frame")
	DamagePipeline.settle_budget_override = -1
	_field_clear()


# ── E4 顺/冲/弃遥测差分（1Hz 拉取语义） ───────────────────────────

func _e4_diag_delta() -> void:
	print("── E4 顺/冲/弃 diag 差分：立基线 / 变更差分 / 重复拉取归零 ──")
	var en_h := _spawn_enemy(&"E_QAE_4H")
	var en_i := _spawn_enemy(&"E_QAE_4I")
	var en_j := _spawn_enemy(&"E_QAE_4J")
	DamagePipeline.settle_budget_override = 1
	var pull0: Dictionary = _gl.diag_counts()                        # 拉取立基线（增量口径）
	var f := 2060
	_gl.pipeline.call(&"begin_frame", f)
	var _r1: DamageResult = _resolve(_mk_ctx(9260, en_h, 10.0, f))   # 帽内真结算
	var _r2: DamageResult = _resolve(_mk_ctx(9261, en_i, 10.0, f))   # I1 顺延
	var _r3: DamageResult = _resolve(_mk_ctx(9262, en_j, 10.0, f))   # J1 顺延
	en_i.dead = true                                 # I 亡于冲刷前（亡丢路径）
	_gl.pipeline.call(&"end_frame")
	_gl.pipeline.call(&"begin_frame", f + 1)                         # I1 亡丢（不耗预算）→ J1 真冲刷
	_gl.pipeline.call(&"end_frame")
	var pull1: Dictionary = _gl.diag_counts()
	# diag 值语义=自上次拉取的差分（首拉立基线返 0——boot 期调试行可能已拉过，pull0 值不约束）
	var d_def: int = int(pull1.get(&"settles_deferred", -1))
	var d_flh: int = int(pull1.get(&"settles_flushed", -1))
	var d_drn: int = int(pull1.get(&"settles_dropped", -1))
	var d_set: int = int(pull1.get(&"settles", -1))
	_check("E4 变更期差分逐轴对账（顺+2 冲+1 弃+1[亡] 结+2——pull0→pull1 间仅本用例变更）",
		d_def == 2 and d_flh == 1 and d_drn == 1 and d_set == 2,
		"顺%d 冲%d 弃%d 结%d" % [d_def, d_flh, d_drn, d_set])
	var pull2: Dictionary = _gl.diag_counts()                        # 重复拉取：基线已立 → 归零
	var z_def: int = int(pull2.get(&"settles_deferred", -1))
	var z_flh: int = int(pull2.get(&"settles_flushed", -1))
	var z_drn: int = int(pull2.get(&"settles_dropped", -1))
	_check("E4 重复拉取增量归零（1Hz 语义——无重复计数）",
		z_def == 0 and z_flh == 0 and z_drn == 0,
		"顺%d 冲%d 弃%d" % [z_def, z_flh, z_drn])
	DamagePipeline.settle_budget_override = -1
	_field_clear()


func _cleanup() -> void:
	DamagePipeline.settle_budget_override = _saved_budget
	_pending_clear()
	_field_clear()
	if _gl != null:
		_gl.queue_free()
		await tree.process_frame

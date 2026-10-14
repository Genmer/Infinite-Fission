# tests/runner/r220_simchain_cases.gd
# R220 弹段链用例体（包B：刀1/3①/4/8/9/11 + 接线）。
# ① 刀1：十六段冻结契约（card_open/card_drain 插位）+ TAGS 开/消。
# ② 刀1：卡键拆分——开窗级联归 card_open、PLAYING 帧溢出消化归 card_drain（互斥分立）。
# ③ 刀1：模N 新口径（物理帧差分×1000÷实际采样墙钟窗）+ 跨窗 `*` 标记 + 首采哨兵。
# ④ 刀1：结N（settles 秒差分）/ 自导N（_homing_pool 在场数）键可读（含刀4 typed 落血）。
# ⑤ 刀3①：EF_CRIT_SHARD 保守闸——TH_BANK_SHOT 并入 armed（bank 达线置 crit=1.0 必须保触发）。
# ⑥ 刀4：homing _is_target_valid 类型化双轨（Enemy 直读 / 桩 Variant gets）+ 源锚。
# ⑦ 刀8①②③：面板快照扁平 5 字段等价、幂等缓存同实例、audit 跨命中无污染。
# ⑧ 刀8④：ProjectilePool O(1) swap-remove 表结构 + 索引一致性 + 单帧恰 tick 一次。
# ⑨ 刀9：敌弹快慢路径等价（位移逐位/出界同帧/撞玩家同伤）+ ⚠PR 检查单源锚。
# ⑩ 刀11：damage_resolved 批化（⑧段前派发/end_frame 只清空/跳字同帧起跳/升格批内保序）
#         + HUD/relic 30Hz 降频门（关门暂存、开门一并消费、累计不丢）。
# ⑪ 接线：popup max_active_for 档帽回退锁（调速器档帽越权面已清除——R220 修轮）+ diag 尾段 结N 自N 调N/变N。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const DT := 1.0 / 60.0
const EPS := 0.0001

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null
var _spy_sources: Array[int] = []            # EventBus.damage_resolved spy（source_uid 到达序）
var _spy_cb: Callable


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_boot_game_loop()
	await tree.process_frame
	await tree.process_frame
	_spy_cb = func(r: DamageResult) -> void: _spy_sources.append(int(r.source_uid))
	EventBus.damage_resolved.connect(_spy_cb)
	_test_1_stage_contract()
	_test_2_card_split()
	_test_3_sim_hz()
	_test_4_settles_homing()
	_test_5_bank_shot()
	_test_6_typed_dual_track()
	_test_7_flat_idem_audit()
	_test_8_swap_remove()
	_test_9_fast_path()
	_test_10_batched()
	_test_11_wiring()
	EventBus.damage_resolved.disconnect(_spy_cb)
	_teardown_game_loop()
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
	await tree.process_frame
	_gl = tree.root.get_node_or_null("Main") as GameLoop
	if _gl == null:
		for c in tree.root.get_children():
			if c is GameLoop:
				_gl = c
				break


func _teardown_game_loop() -> void:
	if _gl != null:
		_gl.queue_free()
		await tree.process_frame


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


func _spawn_enemy(p_id: StringName, p_hp: float = 1000.0) -> Enemy:
	var pool := _gl.pools[&"enemy"] as EnemyPool
	var e := pool.acquire() as Enemy
	e.spawn(_fixture_enemy(p_id, p_hp), 1, 0)
	e._fade_left = 0.0
	e.modulate.a = 1.0
	return e


func _release_enemy(p_e: Enemy) -> void:
	(_gl.pools[&"enemy"] as EnemyPool).release(p_e)


func _w1() -> WeaponBase:
	return _gl.player.weapon_slots[0] as WeaponBase


func _proj_pool() -> ProjectilePool:
	return _gl.pools[&"projectile"] as ProjectilePool


func _spawn_player_bullet(p_weapon: WeaponBase, p_crit: float, p_pos: Vector2,
		p_extra_panel: Dictionary = {}) -> ProjectileBase:
	# 玩家弹夹具（pool 注入 + spawn 契约；不 add_child——池预热实例已挂池下）
	var pool := _proj_pool()
	var proj := pool.acquire()
	proj.damage_pipeline = _gl.pipeline
	proj.enemy_grid = _gl.enemy_grid
	proj.pool = pool
	var panel: Dictionary = {
		"base_atk": 10.0, "flat_bonus": 2.0,
		"crit_rate": p_crit, "crit_mult": 2.0, "add_entries": [],
	}
	panel.merge(p_extra_panel, true)
	proj.spawn({
		"velocity": Vector2(60.0, 0.0), "lifetime": 10.0, "pierce": 1, "team": 0,
		"weapon_ref": p_weapon, "panel_snapshot": panel, "position": p_pos,
	})
	return proj


func _spawn_enemy_bullet(p_pos: Vector2, p_vel: Vector2, p_lifetime: float,
		p_base_atk: float) -> ProjectileBase:
	# 敌弹夹具（team=1 最小参数域——与 enemy.gd 两处 spawn 点同域，见 _fast_path 判据）
	var pool := _proj_pool()
	var proj := pool.acquire()
	proj.damage_pipeline = _gl.pipeline
	proj.enemy_grid = _gl.enemy_grid
	proj.pool = pool
	proj.spawn({
		"velocity": p_vel, "lifetime": p_lifetime, "pierce": 1, "team": 1,
		"panel_snapshot": {"base_atk": p_base_atk}, "position": p_pos,
	})
	return proj


func _release_bullet(p_b: ProjectileBase) -> void:
	if p_b != null and is_instance_valid(p_b):
		_proj_pool().release(p_b)


func _clear_projectiles() -> void:
	# 池清场（快照迭代防 release 重入；勿二次 release）
	var pool := _proj_pool()
	for n in pool.active_projectiles().duplicate():
		if is_instance_valid(n):
			pool.release(n)


func _make_ctx(p_source: int, p_target: Enemy, p_base: float, p_crit: float) -> DamageContext:
	var ctx := DamageContext.make()
	ctx.source_uid = p_source
	ctx.target_uid = p_target.uid
	ctx.target = p_target
	ctx.frame_stamp = GameConfig.frame_stamp
	ctx.base_atk = p_base
	ctx.crit_chance = p_crit
	ctx.crit_mult = 2.0
	ctx.pos = p_target.global_position
	return ctx


func _pipeline_stats(p_key: StringName) -> int:
	return int((_gl.pipeline.call(&"stats") as Dictionary).get(p_key, 0))


# ── ① 刀1：十六段冻结契约 ────────────────────────────────────────

func _test_1_stage_contract() -> void:
	print("── ① 十六段契约 ──")
	var order: Array[StringName] = [
		&"player", &"player_mv", &"player_wp", &"shard", &"grid_rebuild", &"grid_projectile",
		&"enemy", &"wave", &"feel_shard", &"feel", &"fx", &"popup", &"ui",
		&"card_open", &"card_drain", &"other",
	]
	_check("①段序冻结：十五段→十六段（card_open/card_drain 插 ui 后 other 前，序逐位锁死）",
		DebugStats.DIAG_STAGE_ORDER == order and DebugStats.DIAG_STAGE_ORDER.size() == 16,
		str(DebugStats.DIAG_STAGE_ORDER))
	_check("①标签：开/消分立映射在位（碎/卡同检）",
		str(DebugStats.DIAG_STAGE_TAGS.get(&"card_open", "")) == "开"
			and str(DebugStats.DIAG_STAGE_TAGS.get(&"card_drain", "")) == "消"
			and str(DebugStats.DIAG_STAGE_TAGS.get(&"shard", "")) == "碎",
		str(DebugStats.DIAG_STAGE_TAGS))
	var i_ui: int = order.find(&"ui")
	var i_open: int = order.find(&"card_open")
	var i_drain: int = order.find(&"card_drain")
	var i_other: int = order.find(&"other")
	_check("①插位：ui < card_open < card_drain < other",
		i_ui < i_open and i_open < i_drain and i_drain < i_other,
		"ui=%d open=%d drain=%d other=%d" % [i_ui, i_open, i_drain, i_other])


# ── ② 刀1：卡开/卡消拆键 ─────────────────────────────────────────

func _test_2_card_split() -> void:
	print("── ② 卡键拆分 ──")
	_gl.stage_probe_enabled = true
	_gl.state = GameConst.GameStatus.PLAYING
	_gl._physics_process(DT)                 # PLAYING 帧各段探针写入
	_gl.player.set("xp_need", 10)
	_gl.player.gain_xp(10)
	_gl.stage_probe_us.clear()
	_gl.call(&"_consume_deferred_level_open")   # 开窗级联直驱（LEVEL_UP 态）
	var probe: Dictionary = _gl.stage_probe_us
	_check("②开窗归「开」：card_open 入账且 card_drain 零写入（拆键分立）",
		probe.has(&"card_open") and not probe.has(&"card_drain"),
		"keys=%s" % str(probe.keys()))
	while _gl.state == GameConst.GameStatus.LEVEL_UP:
		_gl.card_select_ui.choose(0)
	_gl.stage_probe_us.clear()
	_gl._physics_process(DT)                 # 回 PLAYING：溢出消化槽包装器记账
	_check("②PLAYING 帧归「消」：card_drain 恒记账且 card_open 零写入",
		probe.has(&"card_drain") and not probe.has(&"card_open"),
		"keys=%s" % str(probe.keys()))
	_gl.stage_probe_enabled = false


# ── ③ 刀1：模N 新口径 + 跨窗标记 ─────────────────────────────────

func _test_3_sim_hz() -> void:
	print("── ③ 模N 新口径 ──")
	var ds: Node = (load("res://autoload/debug_stats.gd") as GDScript).new()
	var now := Time.get_ticks_msec()
	var phys := Engine.get_physics_frames()
	# 跨窗（>1.5×DIAG_SAMPLE_MS=1500ms）：物理帧差分 10 / 墙钟窗 3000ms → 10/3Hz + `*`
	#（差分取 10：headless 快启物理帧实测 ~25，非负差分保口径；期望值按公式动态算）
	var diff := 10
	var expect_cross := int(round(float(diff) * 1000.0 / 3000.0))
	ds.set("_diag_last_ms", now - 3000)
	ds.set("_diag_last_phys", phys - diff)
	var line_cross: String = ds.call(&"_diag_format_line", _gl, now)
	_check("③跨窗标记：物理差分%d÷墙钟3000ms → 模%d*（供判读剔除）" % [diff, expect_cross],
		line_cross.contains("模%d*" % expect_cross),
		line_cross.right(100) + " phys=%d" % phys)
	# 正常窗：差分 10 / 1000ms → 10Hz 无星
	var expect_ok := int(round(float(diff) * 1000.0 / 1000.0))
	ds.set("_diag_last_ms", now - 1000)
	ds.set("_diag_last_phys", phys - diff)
	var line_ok: String = ds.call(&"_diag_format_line", _gl, now)
	_check("③正常窗：差分%d÷1000ms → 模%d（无跨窗星标）" % [diff, expect_ok],
		line_ok.contains("模%d" % expect_ok) and not line_ok.contains("模%d*" % expect_ok),
		line_ok.right(100))
	# 首采哨兵：_diag_last_phys=-1 不出差值脏值（模0 不带标）
	ds.set("_diag_last_phys", -1)
	var line_first: String = ds.call(&"_diag_format_line", _gl, now)
	_check("③首采哨兵：-1 基线 → 模0 无星（不出脏值）",
		line_first.contains("模0") and not line_first.contains("模0*"), line_first.right(100))
	ds.free()
	# 窗基线保护源锚：_diag_last_ms 刷新在拼行之后（否则窗恒 0——vc26 模157-363 根因）
	var src_ds: String = FileAccess.get_file_as_string("res://autoload/debug_stats.gd")
	_check("③窗基线源锚：_diag_push 在 _diag_last_ms 刷新之前（窗=真实墙钟差）",
		src_ds.find("_diag_push(_diag_format_line") >= 0
			and src_ds.find("_diag_push(_diag_format_line") < src_ds.find("_diag_last_ms = now"),
		"find_push=%d find_refresh=%d" % [src_ds.find("_diag_push(_diag_format_line"),
			src_ds.find("_diag_last_ms = now")])


# ── ④ 刀1：结N / 自导N ───────────────────────────────────────────

func _test_4_settles_homing() -> void:
	print("── ④ 结N/自导N ──")
	var e1 := _spawn_enemy(&"E_R220_SETTLE", 1000.0)
	var c0: Dictionary = _gl.diag_counts()
	_check("④新键：settles/homing_projectiles 在 diag_counts",
		c0.has(&"settles") and c0.has(&"homing_projectiles"), str(c0.keys()))
	var hp0 := e1.hp
	for i in 3:
		var r: DamageResult = _gl.pipeline.call(&"resolve", _make_ctx(6000 + i, e1, 1.0, 0.0))
		if r == null:
			break
	var c1: Dictionary = _gl.diag_counts()
	_check("④结N 差分：3 次真件 resolve → settles==3（首拉立基线返 0 后的增量）",
		int(c1[&"settles"]) == 3, "setttles=%d" % int(c1[&"settles"]))
	_check("④刀4 typed 落血：真敌 hp 恰降 3（base=1 无乘区 resist=0）",
		is_equal_approx(e1.hp, hp0 - 3.0), "%.2f→%.2f" % [hp0, e1.hp])
	# 自导N：_homing_pool 在场数（弹N 不含自导池的口径纠正）
	var hpool: ProjectilePool = _gl._homing_pool as ProjectilePool
	var h0 := int(c1[&"homing_projectiles"])
	var hproj := hpool.acquire()
	hproj.spawn({"velocity": Vector2(60.0, 0.0), "lifetime": 5.0, "pierce": 1,
		"target_uid": e1.uid})
	_check("④自导N：acquire+spawn → 在场 +1",
		int(_gl.diag_counts()[&"homing_projectiles"]) == h0 + 1)
	hpool.release(hproj)
	_check("④自导N：release → 归零",
		int(_gl.diag_counts()[&"homing_projectiles"]) == h0)
	_gl.pipeline.call(&"end_frame")          # 遥测落盘；R221 D1 后批化态不清队——显式排空
	_gl.pipeline.get("_resolved_queue").clear()
	_gl.spawner.active.erase(e1)
	_release_enemy(e1)


# ── ⑤ 刀3①：EF_CRIT_SHARD 保守闸 + bank-shot 保真 ────────────────

func _test_5_bank_shot() -> void:
	print("── ⑤ armed 闸/bank-shot 保真 ──")
	var w1 := _w1()
	var th_bank: Dictionary = w1.get_threshold(&"TH_BANK_SHOT")
	var th_crit: Dictionary = w1.get_threshold(&"TH_CRIT_SHARD")
	_check("⑤前置：W1 声明 TH_BANK_SHOT/TH_CRIT_SHARD（.tres 阈值表）",
		not th_bank.is_empty() and not th_crit.is_empty(),
		"bank=%s crit=%s" % [str(th_bank.is_empty()), str(th_crit.is_empty())])
	# 主目标 + 近距弹射目标（< SHARD_RADIUS 120px）
	var e_main := _spawn_enemy(&"E_R220_BANK_MAIN", 100000.0)
	e_main.position = Vector2(500, 600)
	var e_near := _spawn_enemy(&"E_R220_BANK_NEAR", 100000.0)
	e_near.position = Vector2(560, 600)
	_gl.spawner.active.append(e_main)
	_gl.spawner.active.append(e_near)
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	# b1：W1 + 面板 crit 0.1（< 0.35）——armed 仅因 TH_BANK_SHOT 声明并入而为真
	var b1 := _spawn_player_bullet(w1, 0.1, Vector2(500, 600))
	_check("⑤armed 并入 bank：W1 弹 crit=0.1 仍 armed（面板 crit<阈值的黄金弹保触发）",
		b1._crit_shard_armed, "")
	var before1 := DebugStats.get_counter(&"crit_shard_triggered")
	b1._bounces_done = 12                    # 达线（TH_BANK_SHOT threshold=12.0）
	b1._submit_hit(e_main)
	_check("⑤bank-shot 保真：达线命中 → _apply_bank_shot 置 crit=1.0 过 0.35 闸 → 直发段触发 +1",
		DebugStats.get_counter(&"crit_shard_triggered") - before1 == 1,
		"Δ=%d" % (DebugStats.get_counter(&"crit_shard_triggered") - before1))
	# b2 对照：无任何阈值声明的基类武器 + crit 0.1 → armed=false → 直发段整段跳过
	var wf := WeaponBase.new()
	var b2 := _spawn_player_bullet(wf, 0.1, Vector2(500, 600))
	_check("⑤armed 闸拦截：无声明武器（data=null）+ crit 0.1 → armed=false",
		not b2._crit_shard_armed, "")
	var before2 := DebugStats.get_counter(&"crit_shard_triggered")
	b2._bounces_done = 12
	b2._submit_hit(e_main)
	_check("⑤闸语义：armed=false 命中不触发直发段（省扫描不误触发）",
		DebugStats.get_counter(&"crit_shard_triggered") - before2 == 0,
		"Δ=%d" % (DebugStats.get_counter(&"crit_shard_triggered") - before2))
	# b3：crit 通道保真——面板 0.5 ≥ 0.35 无 bounce 也 armed 且触发
	var b3 := _spawn_player_bullet(w1, 0.5, Vector2(560, 600))
	_check("⑤crit 阈值通道：面板 0.5 ≥ 0.35 → armed（TH_CRIT_SHARD 原通道不回归）",
		b3._crit_shard_armed, "")
	var before3 := DebugStats.get_counter(&"crit_shard_triggered")
	b3._submit_hit(e_near)
	_check("⑤crit 通道触发：无 bounce 达阈值 → 直发段 +1",
		DebugStats.get_counter(&"crit_shard_triggered") - before3 == 1,
		"Δ=%d" % (DebugStats.get_counter(&"crit_shard_triggered") - before3))
	# b4：闸放行 ≠ 必触发——armed（bank 并入）但无 bounce 且 crit 0.1 < 0.35 → 掷骰不过
	var b4 := _spawn_player_bullet(w1, 0.1, Vector2(500, 600))
	var before4 := DebugStats.get_counter(&"crit_shard_triggered")
	b4._submit_hit(e_main)
	_check("⑤闸不越权：armed 但 crit 0.1 未达 0.35 → 不触发（闸=放行非强制）",
		DebugStats.get_counter(&"crit_shard_triggered") - before4 == 0,
		"Δ=%d" % (DebugStats.get_counter(&"crit_shard_triggered") - before4))
	_release_bullet(b1)
	_release_bullet(b2)
	_release_bullet(b3)
	_release_bullet(b4)
	wf.free()
	_gl.pipeline.call(&"end_frame")          # 遥测落盘；R221 D1 后批化态不清队——显式排空
	_gl.pipeline.get("_resolved_queue").clear()
	_gl.spawner.active.erase(e_main)
	_gl.spawner.active.erase(e_near)
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	_release_enemy(e_main)
	_release_enemy(e_near)


# ── ⑥ 刀4：类型化双轨 ────────────────────────────────────────────

func _test_6_typed_dual_track() -> void:
	print("── ⑥ 类型化双轨 ──")
	var e2 := _spawn_enemy(&"E_R220_HOMING", 1000.0)
	var h := (_gl._homing_pool as ProjectilePool).acquire() as HomingProjectile
	h.target_uid = e2.uid
	h._target = e2
	_check("⑥Enemy 分支：not dead 且 uid 匹配 → 有效",
		h._is_target_valid(), "")
	h.target_uid = e2.uid + 999
	_check("⑥Enemy 分支：uid 不匹配（池回收复用新身份）→ 无效",
		not h._is_target_valid(), "")
	var stub := StubTarget.new()
	stub.uid = 777
	h._target = stub
	h.target_uid = 777
	_check("⑥桩回落：非 Enemy 走 Variant gets（dead=false/uid 匹配 → 有效）",
		h._is_target_valid(), "")
	stub.dead = true
	_check("⑥桩回落：dead=true → 无效",
		not h._is_target_valid(), "")
	stub.free()
	(_gl._homing_pool as ProjectilePool).release(h)
	# 桩双轨源锚（else 路径保留——R210 先例；typed 主路径走直读）
	var src_pb: String = FileAccess.get_file_as_string("res://scripts/combat/projectile/projectile_base.gd")
	_check("⑥源锚：_submit_hit 死亡短路/反弹盾 else 桩路径在位",
		src_pb.contains("elif bool(p_target.get(\"dead\"))")
			and src_pb.contains("elif p_target.has_method(&\"try_reflect_projectile\")"),
		"")
	var src_hm: String = FileAccess.get_file_as_string("res://scripts/combat/projectile/homing_projectile.gd")
	_check("⑥源锚：_is_target_valid else Variant gets 在位",
		src_hm.contains("if bool(_target.get(\"dead\"))"), "")
	_release_enemy(e2)


# ── ⑦ 刀8①②③：扁平快照 / 幂等 / audit 无污染 ────────────────────

func _test_7_flat_idem_audit() -> void:
	print("── ⑦ 扁平/幂等/audit ──")
	var e3 := _spawn_enemy(&"E_R220_FLAT", 1000.0)
	var b7 := _spawn_player_bullet(_w1(), 0.25, Vector2(100, 100),
		{"add_entries": [{"pool_id": &"qa_r220", "contrib": 3.0, "cap_pool": 3.0, "priority": 0}]})
	_check("⑦扁平展开：5 键 spawn 期展开为弹上字段（_panel_* 逐字段等价）",
		is_equal_approx(b7._panel_base_atk, 10.0) and is_equal_approx(b7._panel_flat_bonus, 2.0)
			and is_equal_approx(b7._panel_crit_rate, 0.25) and is_equal_approx(b7._panel_crit_mult, 2.0)
			and b7._panel_add_entries.size() == 1,
		"atk=%.2f flat=%.2f crit=%.2f mult=%.2f adds=%d" % [b7._panel_base_atk,
			b7._panel_flat_bonus, b7._panel_crit_rate, b7._panel_crit_mult,
			b7._panel_add_entries.size()])
	var ctx := b7._build_damage_ctx(e3)
	_check("⑦_build_damage_ctx 读扁平：ctx 5 字段与快照逐位一致",
		is_equal_approx(ctx.base_atk, 10.0) and is_equal_approx(ctx.flat_bonus, 2.0)
			and is_equal_approx(ctx.crit_chance, 0.25) and is_equal_approx(ctx.crit_mult, 2.0)
			and ctx.add_entries.size() == 1
			and is_equal_approx(float((ctx.add_entries[0] as Dictionary).get("contrib", 0.0)), 3.0),
		"atk=%.2f adds=%d" % [ctx.base_atk, ctx.add_entries.size()])
	b7.panel_snapshot["base_atk"] = 7.0       # 中途直改字典（反射/测试夹具通道）
	var ctx2 := b7._build_damage_ctx(e3)
	_check("⑦命中链口径：中途改写字典不影响 ctx（spawn 期扁平快照——幂等语义）",
		is_equal_approx(ctx2.base_atk, 10.0), "%.2f" % ctx2.base_atk)
	_release_bullet(b7)
	# 幂等回归：同键二次 resolve 返回缓存同实例
	var ctxI := _make_ctx(6101, e3, 1.0, 0.0)
	var rI: DamageResult = _gl.pipeline.call(&"resolve", ctxI)
	var dupe0 := _pipeline_stats(&"dropped_dupe")
	var rI2: DamageResult = _gl.pipeline.call(&"resolve", ctxI)
	_check("⑦幂等：同 (source,target,frame) 二次 resolve → 缓存同实例 + dropped_dupe+1",
		rI != null and rI == rI2 and _pipeline_stats(&"dropped_dupe") == dupe0 + 1,
		"same=%s dupe=%d→%d" % [str(rI == rI2), dupe0, _pipeline_stats(&"dropped_dupe")])
	# audit 跨命中无污染（resolve_reaction 的 ratio=coefficient 可控特征值）
	var e4 := _spawn_enemy(&"E_R220_AUD_A", 100000.0)
	var e5 := _spawn_enemy(&"E_R220_AUD_B", 100000.0)
	var ctxA := DamageContext.make()
	ctxA.source_uid = 6201
	ctxA.target_uid = e4.uid
	ctxA.target = e4
	ctxA.frame_stamp = GameConfig.frame_stamp
	var rA: DamageResult = _gl.pipeline.call(&"resolve_reaction", 100.0, 1.1, ctxA)
	var ctxB := DamageContext.make()
	ctxB.source_uid = 6202
	ctxB.target_uid = e5.uid
	ctxB.target = e5
	ctxB.frame_stamp = GameConfig.frame_stamp
	var rB: DamageResult = _gl.pipeline.call(&"resolve_reaction", 100.0, 2.2, ctxB)
	_check("⑦audit 不复用：两命中 audit 实例不同（audit 随 DamageResult 逃逸）",
		rA != null and rB != null and rA.audit != null and rB.audit != null
			and rA.audit != rB.audit,
		"a_null=%s b_null=%s same=%s" % [str(rA == null or rA.audit == null),
			str(rB == null or rB.audit == null), str(rA != null and rB != null and rA.audit == rB.audit)])
	_check("⑦audit 无污染：rA.ratio 保持 1.1（后续命中不复用改写）+ rB.ratio=2.2",
		is_equal_approx(rA.audit.ratio, 1.1) and is_equal_approx(rB.audit.ratio, 2.2),
		"rA=%.3f rB=%.3f" % [rA.audit.ratio, rB.audit.ratio])
	# ModifierStack 复用件（借出建件）
	_check("⑦ModifierStack 复用：_reused_stack 已建（深度<=0 借出单件复用）",
		_gl.pipeline.get("_reused_stack") != null, "")
	var src_dp: String = FileAccess.get_file_as_string("res://scripts/core/damage/damage_pipeline.gd")
	_check("⑦复用源锚：REUSE_MODIFIER_STACK 开关 + DamageAudit 每命中 new",
		src_dp.contains("const REUSE_MODIFIER_STACK := true")
			and src_dp.contains("stack.audit = DamageAudit.new()"),
		"")
	_gl.pipeline.call(&"end_frame")          # 遥测落盘；R221 D1 后批化态不清队——显式排空
	_gl.pipeline.get("_resolved_queue").clear()
	_gl.spawner.active.erase(e3)
	_gl.spawner.active.erase(e4)
	_gl.spawner.active.erase(e5)
	_release_enemy(e3)
	_release_enemy(e4)
	_release_enemy(e5)


# ── ⑧ 刀8④：swap-remove 表契约 ───────────────────────────────────

func _test_8_swap_remove() -> void:
	print("── ⑧ swap-remove ──")
	_clear_projectiles()
	var pool := _proj_pool()
	var a1 := pool.acquire()
	var a2 := pool.acquire()
	var a3 := pool.acquire()
	var a4 := pool.acquire()
	_check("⑧登记：acquire×4 → active 4 条（顺序=取出序）",
		pool.active_projectiles().size() == 4, str(pool.active_projectiles().size()))
	pool.release(a2)
	var act := pool.active_projectiles()
	_check("⑧换位结构：release(a2) → [a1,a4,a3]（尾元素 O(1) 换位非线性扫）",
		act.size() == 3 and act[0] == a1 and act[1] == a4 and act[2] == a3,
		"size=%d" % act.size())
	_check("⑧索引一致：_active_index 与 _active_list 下标全量对齐",
		_pool_index_consistent(pool), "")
	var a5 := pool.acquire()
	_check("⑧再取：acquire 追加尾槽 a5（4 条）",
		pool.active_projectiles().size() == 4 and pool.active_projectiles()[3] == a5, "")
	pool.force_recycle_oldest()
	act = pool.active_projectiles()
	_check("⑧force 回收最老：a1 出表（_live_order 首键）余 a3/a4/a5 在",
		not act.has(a1) and act.has(a3) and act.has(a4) and act.has(a5), "")
	_check("⑧索引一致（force 路径后）", _pool_index_consistent(pool), "")
	pool.release(a3)
	pool.release(a4)
	pool.release(a5)
	_check("⑧清场：全部归还 → active 空",
		pool.active_projectiles().is_empty(), str(pool.active_projectiles().size()))
	# 单帧恰 tick 一次（快照缓冲迭代 + tick 内自回收 swap-remove 不扰动未访问位）
	var p1 := _spawn_player_bullet(_w1(), 0.0, Vector2(300, 300))
	var p2 := _spawn_player_bullet(_w1(), 0.0, Vector2(320, 300))
	p2.lifetime_left = DT                    # 本帧寿命尽（tick 内自回收）
	var p3 := _spawn_player_bullet(_w1(), 0.0, Vector2(340, 300))
	_gl._tick_one_pool(pool, DT)
	act = pool.active_projectiles()
	_check("⑧恰 tick 一次：p2 寿命尽自回收 → 剩 [p1,p3]（换位不丢不重）",
		act.size() == 2 and act.has(p1) and act.has(p3), "size=%d" % act.size())
	_check("⑧位移恰一次：p1/p3 各 +v×DT（60×1/60=1px，非 2px）",
		is_equal_approx(p1.position.x, 301.0) and is_equal_approx(p3.position.x, 341.0),
		"p1=%.3f p3=%.3f" % [p1.position.x, p3.position.x])
	_release_bullet(p1)
	_release_bullet(p3)


func _pool_index_consistent(p_pool: ProjectilePool) -> bool:
	var idx_map: Dictionary = p_pool.get("_active_index")
	var act := p_pool.active_projectiles()
	for n in act:
		if int(idx_map.get(n, -1)) != act.find(n):
			return false
	return idx_map.size() == act.size()


# ── ⑨ 刀9：敌弹快慢路径等价 ──────────────────────────────────────

func _test_9_fast_path() -> void:
	print("── ⑨ 敌弹快路径 ──")
	var src_gl: String = FileAccess.get_file_as_string("res://scripts/loop/game_loop.gd")
	var src_pb: String = FileAccess.get_file_as_string("res://scripts/combat/projectile/projectile_base.gd")
	_check("⑨源锚：ENEMY_BULLET_FAST_PATH 分流开关 + ⚠PR 检查单（新 team=1 spawn 点必须最小参数）",
		src_gl.contains("const ENEMY_BULLET_FAST_PATH := true")
			and src_pb.contains("team=1 spawn 点必须最小参数"),
		"")
	_clear_projectiles()
	var pool := _proj_pool()
	# 位移等价：同参数双胞胎，一个强制慢路径
	var f1 := _spawn_enemy_bullet(Vector2(300, 300), Vector2(60, 0), 10.0, 5.0)
	var f2 := _spawn_enemy_bullet(Vector2(300, 300), Vector2(60, 0), 10.0, 5.0)
	f2._fast_path = false
	_check("⑨判据：team1 最小参数域 → _fast_path=true；强制 false 走慢路径",
		f1._fast_path and not f2._fast_path,
		"f1=%s f2=%s" % [str(f1._fast_path), str(f2._fast_path)])
	for i in 20:
		_gl._tick_one_pool(pool, DT)
	_check("⑨位移逐位等价：20 帧（60Hz）后快慢路径位置一致（v×dt 恰一次/帧）",
		f1.position.distance_to(f2.position) < EPS,
		"f1=%s f2=%s" % [str(f1.position), str(f2.position)])
	_release_bullet(f1)
	_release_bullet(f2)
	# 出界同帧回收
	var f3 := _spawn_enemy_bullet(Vector2(1000, 300), Vector2(60000, 0), 5.0, 5.0)
	var f4 := _spawn_enemy_bullet(Vector2(1000, 300), Vector2(60000, 0), 5.0, 5.0)
	f4._fast_path = false
	_gl._tick_one_pool(pool, DT)
	_check("⑨出界同帧回收：快/慢同帧双双出表（EXPIRED 语义一致）",
		not pool.active_projectiles().has(f3) and not pool.active_projectiles().has(f4), "")
	# 撞玩家等价：伤害同源（快=_panel_base_atk 扁平 / 慢=panel_snapshot 字典）
	var pl := _gl.player as Player
	pl.invuln_left = 0.0
	var hp0 := pl.hp
	var f5 := _spawn_enemy_bullet(pl.global_position, Vector2.ZERO, 5.0, 5.0)
	_gl._tick_one_pool(pool, DT)
	_check("⑨快路径撞玩家：本帧回收 + take_contact_damage(面板 base_atk=5)",
		not pool.active_projectiles().has(f5) and is_equal_approx(pl.hp, hp0 - 5.0),
		"live=%s hp %.1f→%.1f" % [str(pool.active_projectiles().has(f5)), hp0, pl.hp])
	pl.invuln_left = 0.0
	var hp1 := pl.hp
	var f6 := _spawn_enemy_bullet(pl.global_position, Vector2.ZERO, 5.0, 5.0)
	f6._fast_path = false
	_gl._tick_one_pool(pool, DT)
	_check("⑨慢路径撞玩家：同帧回收 + 同伤害（读字典通道——反射/夹具改写可达）",
		not pool.active_projectiles().has(f6) and is_equal_approx(pl.hp, hp1 - 5.0),
		"live=%s hp %.1f→%.1f" % [str(pool.active_projectiles().has(f6)), hp1, pl.hp])


# ── ⑩ 刀11：批化派发 + 30Hz 门 ───────────────────────────────────

func _test_10_batched() -> void:
	print("── ⑩ 批化派发/30Hz 门 ──")
	_clear_projectiles()
	var e6 := _spawn_enemy(&"E_R220_BATCH", 100000.0)
	var src_dp: String = FileAccess.get_file_as_string("res://scripts/core/damage/damage_pipeline.gd")
	var src_gl: String = FileAccess.get_file_as_string("res://scripts/loop/game_loop.gd")
	_check("⑩源锚：DAMAGE_RESOLVED_BATCHED 开关 + R221 D1 批化态 end_frame 不清队（顺延归 dispatch 过期守卫）",
		src_dp.contains("const DAMAGE_RESOLVED_BATCHED := true")
			and src_dp.contains("if not DAMAGE_RESOLVED_BATCHED:"),
		"")
	var i_disp: int = src_gl.find("dispatch_resolved_frame")
	var i_ui: int = src_gl.find("_tick_ui(")
	_check("⑩源锚：派发点在 _tick_ui 之前（⑧段前统一派发）",
		i_disp >= 0 and i_ui >= 0 and i_disp < i_ui,
		"disp=%d ui=%d" % [i_disp, i_ui])
	# 行为：结算入队 → 派发口统一派发
	_gl.pipeline.get("_resolved_queue").clear()   # R221 D1：清场（前段批化残留不再被 end_frame 兜底清）
	_spy_sources.clear()
	_gl.pipeline.call(&"resolve", _make_ctx(7001, e6, 1.0, 0.0))
	_check("⑩批化：resolve 后未即时派发（spy 零到达）",
		_spy_sources.is_empty(), str(_spy_sources))
	_gl.pipeline.call(&"dispatch_resolved_frame")
	_check("⑩派发：dispatch_resolved_frame → spy 恰 1 条且 source 对位",
		_spy_sources.size() == 1 and _spy_sources[0] == 7001, str(_spy_sources))
	_gl.pipeline.call(&"resolve", _make_ctx(7002, e6, 1.0, 0.0))
	_gl.pipeline.call(&"end_frame")
	_check("⑩end_frame 帧末不派发（R221 D1：批化态不清队——7002 留队顺延，清队契约归 dispatch 过期守卫/r221_fixreg ⑦）",
		_spy_sources.size() == 1
			and (_gl.pipeline.get("_resolved_queue") as Array).size() == 1,
		str(_spy_sources))
	(_gl.pipeline.get("_resolved_queue") as Array).clear()   # 清场：保护后续保序对位
	# 跳字同帧起跳 + NORMAL→CRIT 升格批内保序
	var pm: PopupManager = _gl.popup_manager
	pm.clear_all()
	var act0 := pm._active_list.size()
	_spy_sources.clear()
	var vN: DamageResult = _gl.pipeline.call(&"resolve", _make_ctx(7003, e6, 10.0, 0.0))
	var vC: DamageResult = _gl.pipeline.call(&"resolve", _make_ctx(7004, e6, 10.0, 1.0))
	_check("⑩跳字同帧起跳·前半：批内未派发 → popup 不起（dispatch 前零跳字）",
		_spy_sources.is_empty() and pm._active_list.size() == act0,
		"spy=%d act=%d→%d" % [_spy_sources.size(), act0, pm._active_list.size()])
	_gl.pipeline.call(&"dispatch_resolved_frame")
	_check("⑩批内保序：派发序 = 入队序 [7003(N), 7004(C)]",
		_spy_sources.size() == 2 and _spy_sources[0] == 7003 and _spy_sources[1] == 7004,
		str(_spy_sources))
	_check("⑩跳字同帧起跳·后半：dispatch 后同帧起字（act0+1——同 uid 并字只一条）",
		pm._active_list.size() == act0 + 1,
		"act=%d" % pm._active_list.size())
	var host: DamagePopup = null
	for n in pm._active_list:
		var dp := n as DamagePopup
		if dp != null and dp.target_uid == e6.uid:
			host = dp
	_check("⑩升格保序：NORMAL 宿主并入 CRIT 升格（style=CRIT）+ merged=vN+vC",
		host != null and host.style == GameConst.PopupStyle.CRIT
			and is_equal_approx(host.merged_value, vN.final_value + vC.final_value),
		"style=%d merged=%.2f expect=%.2f" % [host.style if host != null else -1,
			host.merged_value if host != null else -1.0,
			(vN.final_value + vC.final_value) if (vN != null and vC != null) else -1.0])
	pm.clear_all()
	# HUD 30Hz 门：关门暂存/开门一并消费/累计不丢/override=0 每帧
	var hud: HUD = _gl.hud
	var r1 := DamageResult.new()
	r1.final_value = 1.0
	r1.popup_style = GameConst.PopupStyle.NORMAL
	var r2 := DamageResult.new()
	r2.final_value = 2.0
	r2.popup_style = GameConst.PopupStyle.NORMAL
	var r4 := DamageResult.new()
	r4.final_value = 4.0
	r4.popup_style = GameConst.PopupStyle.NORMAL
	var r8 := DamageResult.new()
	r8.final_value = 8.0
	r8.popup_style = GameConst.PopupStyle.NORMAL
	var t0 := hud.total_damage
	hud.dmg_half_freq_override = 1
	hud._on_damage_resolved(r1)
	_check("⑩HUD 首帧消费相位：开门帧直消费（R206 先减后判先例）+pending 空",
		is_equal_approx(hud.total_damage, t0 + 1.0) and (hud.get("_dmg_pending") as Array).is_empty(),
		"total=%.1f pending=%d" % [hud.total_damage, (hud.get("_dmg_pending") as Array).size()])
	hud._on_damage_resolved(r2)
	_check("⑩HUD 关门帧：暂存不消费（total 不变）",
		is_equal_approx(hud.total_damage, t0 + 1.0) and (hud.get("_dmg_pending") as Array).size() == 1,
		"total=%.1f pending=%d" % [hud.total_damage, (hud.get("_dmg_pending") as Array).size()])
	hud._on_damage_resolved(r4)
	_check("⑩HUD 开门帧：一并消费 B+C（+6 保序累计）",
		is_equal_approx(hud.total_damage, t0 + 7.0) and (hud.get("_dmg_pending") as Array).is_empty(),
		"total=%.1f" % hud.total_damage)
	hud._on_damage_resolved(r8)
	_check("⑩HUD 累计不丢：关门帧暂存 D（total 不变 pending 1）",
		is_equal_approx(hud.total_damage, t0 + 7.0) and (hud.get("_dmg_pending") as Array).size() == 1,
		"total=%.1f pending=%d" % [hud.total_damage, (hud.get("_dmg_pending") as Array).size()])
	hud.dmg_half_freq_override = 0
	hud._on_damage_resolved(r1)
	_check("⑩HUD override=0：每帧直消费原路径（+1；暂存 D 由开门帧补消费不在此断）",
		is_equal_approx(hud.total_damage, t0 + 8.0), "total=%.1f" % hud.total_damage)
	hud.dmg_half_freq_override = -1
	(hud.get("_dmg_pending") as Array).clear()
	hud.set("_dmg_subtick_left", 1)
	# relic 30Hz 门（同款逻辑；消费体 _process_damage_resolved 拆分保时序）
	var rh: RelicHandler = _gl.relic_handler
	rh.dmg_half_freq_override = 1
	rh._on_damage_resolved(r1)
	_check("⑩relic 首帧消费相位：开门帧直消费（pending 空 subtick 置 2）",
		(rh.get("_dmg_pending") as Array).is_empty() and int(rh.get("_dmg_subtick_left")) == 2,
		"pending=%d subtick=%d" % [(rh.get("_dmg_pending") as Array).size(),
			int(rh.get("_dmg_subtick_left"))])
	rh._on_damage_resolved(r2)
	_check("⑩relic 关门帧：暂存 1 条（subtick 递减）",
		(rh.get("_dmg_pending") as Array).size() == 1 and int(rh.get("_dmg_subtick_left")) == 1,
		"pending=%d subtick=%d" % [(rh.get("_dmg_pending") as Array).size(),
			int(rh.get("_dmg_subtick_left"))])
	rh.dmg_half_freq_override = -1
	rh.set("_dmg_subtick_left", 1)
	_gl.pipeline.call(&"end_frame")
	_gl.spawner.active.erase(e6)
	_release_enemy(e6)


# ── ⑪ 接线：popup 档帽 + diag 尾段 ───────────────────────────────

func _test_11_wiring() -> void:
	print("── ⑪ 接线（档帽回退/尾段） ──")
	# R220 修轮：popup 调速器档帽（帧率优先 tier≤2 → 12/16）为越权应用面——超出全部 14 刀
	# 与契约 §1-B8/§2.1 清单（无刀位/无裁定/无回滚台账/无独立开关），已整块移除。本组断言
	# 由「锁档帽生效」翻案为「锁回退彻底」：全模式全档下跳字帽只由 fx_quality 决定
	# （r218 ④ 口径 80/40/20 逐位还原）。
	PerfGovernor.tier_override = -1
	PerfGovernor.mode_override = -1
	_check("⑪零扰动：desktop 默认 tier=3 → 高档帽 80（r218 ④ 口径不变）",
		PopupManager.max_active_for(2) == 80,
		"cap=%d" % PopupManager.max_active_for(2))
	PerfGovernor.mode_override = 0                  # 帧率优先（frame_priority()=true）
	PerfGovernor.tier_override = 1
	_check("⑪档帽回退：帧率优先 + tier1 → 帽仍 80（调速器档帽越权面已清除）",
		PopupManager.max_active_for(2) == 80, "cap=%d" % PopupManager.max_active_for(2))
	PerfGovernor.tier_override = 2
	_check("⑪档帽回退：帧率优先 + tier2 → 帽仍 80",
		PopupManager.max_active_for(2) == 80, "cap=%d" % PopupManager.max_active_for(2))
	PerfGovernor.mode_override = 1                  # 特效优先：同口径零影响
	PerfGovernor.tier_override = 1
	_check("⑪档帽回退：特效优先 tier1 → 帽仍 80（全模式零影响）",
		PopupManager.max_active_for(2) == 80, "cap=%d" % PopupManager.max_active_for(2))
	PerfGovernor.mode_override = 0
	PerfGovernor.tier_override = 1
	_check("⑪档帽回退：帧率优先 tier1 下 中/低档 40/20（r218 数组口径还原）",
		PopupManager.max_active_for(1) == 40 and PopupManager.max_active_for(0) == 20,
		"mid=%d low=%d" % [PopupManager.max_active_for(1), PopupManager.max_active_for(0)])
	PerfGovernor.tier_override = -1
	PerfGovernor.mode_override = -1
	# diag 尾段：结N/自N/调N + 变N
	var e7 := _spawn_enemy(&"E_R220_TAIL", 1000.0)
	_gl.diag_counts()                              # 立结N 差分基线
	_gl.pipeline.call(&"resolve", _make_ctx(7201, e7, 1.0, 0.0))
	_gl.pipeline.call(&"resolve", _make_ctx(7202, e7, 1.0, 0.0))
	var ds: Node = (load("res://autoload/debug_stats.gd") as GDScript).new()
	var line: String = ds.call(&"_diag_format_line", _gl, Time.get_ticks_msec())
	var tail_expect := " 结2 自0 调%d" % PerfGovernor.effective_tier()
	_check("⑪尾段格式：%s（契约 §3.4 追加在 ri 之后）" % tail_expect,
		line.contains(tail_expect),
		line.right(80))
	PerfGovernor.transitions = 3
	var line2: String = ds.call(&"_diag_format_line", _gl, Time.get_ticks_msec())
	_check("⑪变N：transitions>0 → 追加 ` 变3`（真采样驱动累计档变数）",
		line2.contains(" 变3"), line2.right(60))
	PerfGovernor.transitions = 0                   # 复位（真机读数不被测试污染）
	ds.free()
	_gl.pipeline.call(&"end_frame")
	_gl.spawner.active.erase(e7)
	_release_enemy(e7)


# ── 桩目标（刀4 else 双轨；Node2D duck-type） ─────────────────────

class StubTarget extends Node2D:
	var uid := 0
	var dead := false

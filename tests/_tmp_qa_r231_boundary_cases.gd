# tests/_tmp_qa_r231_boundary_cases.gd
# R231 QA1 独立边界复核用例体（入口 _tmp_qa_r231_boundary.gd 运行时 load）。
# 覆盖移交清单边界项（test_r231_* 套件未单列的口）：
#   a) MEC_BOUNCE 预算耗尽弹（_had_bounces=true ∧ bounces_left=0）不被刀C① 早退吞掉
#      ——BOUNCE_DEPLETED 回收（非 EXPIRED/非反射）；无预算弹对照=EXPIRED（早退正主）；
#   b) TH_BANK_SHOT 金染升格弹（W1 bounce_count≥12）：_vis_invariant 不立旗 + 升格后
#      _vis_variant 重判为 GOLD(6)（反弹失效重判链在无旗状态下照常工作）；
#   c) EF_SIZE 弹：不立旗/不进快路径 + 慢路径首帧 _sync_visual 按派发后半径重同步贴图；
#   d) 无栈弹（trait_stack=null）判慢（qa_r220_simchain ③a 回归口径复锁）；
#   e) 池化复用串弹防御：归还后 _pfast/_vis_invariant/_traveled/range_left/_fast_radius/
#      _fast_path/_tick_dispatch_armed 全零；同实例重生带预算 → 判慢且反弹真实生效。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const DT := 1.0 / 60.0

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _gl: GameLoop = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	await tree.process_frame
	await tree.process_frame
	var main: Node = load(MAIN_SCENE).instantiate()
	tree.root.add_child(main)
	await tree.process_frame
	_gl = tree.root.get_node_or_null("Main") as GameLoop
	if _gl == null:
		for c in tree.root.get_children():
			if c is GameLoop:
				_gl = c
				break
	_gl.state = GameConst.GameStatus.MENU
	var gov: Node = tree.root.get_node_or_null("PerfGovernor")
	if gov != null:
		gov.set_process(false)
	_test_a_bounce_depleted()
	_test_b_bank_gold_upgrade()
	_test_c_ef_size_resync()
	_test_d_null_stack_slow()
	await _test_e_pool_reuse_zeroing()
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d" % [_pass, _fail])
	if _gl != null:
		_gl.queue_free()
		await tree.process_frame
		await tree.process_frame


func fail_count() -> int:
	return _fail


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("  PASS | %s" % p_name)
	else:
		_fail += 1
		print("  FAIL | %s（%s）" % [p_name, p_detail])


func _mk_stack(p_trait_ids: Array) -> TraitStack:
	var s := TraitStack.new()
	for tid in p_trait_ids:
		s.attach(_gl.registry.get_trait(tid))
	return s


func _acquire() -> ProjectileBase:
	var pool := _gl.pools[&"projectile"] as ProjectilePool
	var proj := pool.acquire()
	proj.damage_pipeline = _gl.pipeline
	proj.enemy_grid = _gl.enemy_grid
	proj.pool = pool
	return proj


func _spawn(p_pos: Vector2, p_overrides: Dictionary = {}) -> ProjectileBase:
	var params := {
		"velocity": Vector2(0.0, -500.0), "lifetime": 5.0, "pierce": 3, "team": 0,
		"hitbox_radius": 8.0, "range": 900.0,
		"trait_stack": TraitStack.new(),
		"panel_snapshot": {"base_atk": 10.0, "flat_bonus": 0.0,
			"crit_rate": 0.0, "crit_mult": 2.0, "add_entries": []},
		"position": p_pos,
	}
	for k in p_overrides:
		params[k] = p_overrides[k]
	var proj := _acquire()
	proj.spawn(params)
	return proj


func _reason_delta(p_reason: int, p_last: Dictionary) -> int:
	var key := StringName("recycle_reason_%d" % p_reason)
	var cur: int = DebugStats.get_counter(key)
	var last: int = int(p_last.get(key, 0))
	p_last[key] = cur
	return cur - last


# ── a) 预算耗尽弹不被早退吞掉 ──────────────────────────────────────
func _test_a_bounce_depleted() -> void:
	print("── a) 预算耗尽 → BOUNCE_DEPLETED（刀C① 早退不误吞） ──")
	var b := _spawn(Vector2(360.0, 640.0), {"velocity": Vector2(1200.0, 0.0),
		"lifetime": 9.0, "range": 0.0, "bounces": 1, "pierce": 9})
	_check("a 前置：预算弹 _had_bounces=true 且 bounces_left=1",
		b._had_bounces and b.bounces_left == 1)
	var bounced := false
	for i in range(120):
		b.tick(DT)
		if not b._live:
			break
		if b.bounces_left == 0 and b._bounces_done == 1:
			bounced = true
			break
	_check("a 第一次触墙反弹发生（bounces_left 1→0，仍存活）", bounced and b._live)
	_check("a 反弹后 _vis_invariant 不立旗（预算弹排除）", not b._vis_invariant)
	var snap := {}
	var depleted := false
	if b._live:
		snap[StringName("recycle_reason_2")] = DebugStats.get_counter(&"recycle_reason_2")
		snap[StringName("recycle_reason_0")] = DebugStats.get_counter(&"recycle_reason_0")
		for i in range(240):
			b.tick(DT)
			if not b._live:
				depleted = _reason_delta(2, snap) == 1 and _reason_delta(0, snap) == 0
				break
	_check("a 耗尽回收=BOUNCE_DEPLETED（早退未吞，非 EXPIRED）", depleted,
		"bnc=%d exp=%d" % [_reason_delta(2, snap), _reason_delta(0, snap)])
	# 对照：无预算弹同路径 → EXPIRED（早退正主；套件 ⑧ 已锁，此处双保险）
	var nb := _spawn(Vector2(360.0, 640.0), {"velocity": Vector2(1200.0, 0.0),
		"lifetime": 9.0, "range": 0.0, "pierce": 9})
	var snap2 := {}
	snap2[StringName("recycle_reason_0")] = DebugStats.get_counter(&"recycle_reason_0")
	snap2[StringName("recycle_reason_2")] = DebugStats.get_counter(&"recycle_reason_2")
	for i in range(240):
		nb.tick(DT)
		if not nb._live:
			break
	_check("a 对照：无预算弹出屏=EXPIRED（早退吞四边计算=预期）",
		_reason_delta(0, snap2) == 1 and _reason_delta(2, snap2) == 0)


# ── b) TH_BANK_SHOT 金染升格 ───────────────────────────────────────
func _test_b_bank_gold_upgrade() -> void:
	print("── b) TH_BANK_SHOT 金染升格弹不立旗且升格重判可达 ──")
	var w1ref := WeaponBase.new()
	w1ref.setup(_gl.registry.get_weapon(&"W1_pistol"), _gl.player, {})
	_check("b 前置：W1 声明 TH_BANK_SHOT(threshold=12)",
		absf(float(w1ref.get_threshold(&"TH_BANK_SHOT").get("threshold", 0.0)) - 12.0) < 0.001)
	var b := _spawn(Vector2(360.0, 640.0), {"velocity": Vector2(2000.0, 0.0),
		"lifetime": 60.0, "range": 0.0, "bounces": 14, "pierce": 99,
		"weapon_ref": w1ref})
	_check("b 预算弹 _vis_invariant 不立旗（TH_BANK 升格面保守排除）", not b._vis_invariant)
	var gold := false
	var flag_stayed_off := true
	for i in range(1500):
		b.tick(DT)
		if not b._live:
			break
		if b._vis_invariant:
			flag_stayed_off = false
		if b._vis_variant == 6 and b._bounces_done >= 12:
			gold = true
			break
	_check("b 升格重判可达：_bounces_done≥12 后 _vis_variant=GOLD(6)", gold,
		"variant=%d done=%d live=%s" % [b._vis_variant, b._bounces_done, str(b._live)])
	_check("b 全程未误立旗", flag_stayed_off)


# ── c) EF_SIZE 弹不立旗 + 慢路径首帧重同步 ─────────────────────────
func _test_c_ef_size_resync() -> void:
	print("── c) EF_SIZE 弹：不立旗/不进快路径 + 慢路径首帧贴图重同步 ──")
	var b := _spawn(Vector2(360.0, 900.0), {"trait_stack": _mk_stack([&"AFF_AREA"])})
	_check("c EF_SIZE 判 slow（不进快路径）", not b._pfast)
	_check("c EF_SIZE 不立旗", not b._vis_invariant)
	_check("c 前置：派发期 size_mult 已写（>1）", b.size_mult > 1.0)
	var stale: float = b._sprite.scale.x
	var want := b.effective_radius() / 32.0
	b.tick(DT)
	_check("c 慢路径首帧 _sync_visual 重同步（spawn 期陈旧缩放 → 派发后半径）",
		absf(b._sprite.scale.x - want) < 0.001,
		"scale=%.4f want=%.4f spawn期=%.4f" % [b._sprite.scale.x, want, stale])


# ── d) 无栈弹判慢 ──────────────────────────────────────────────────
func _test_d_null_stack_slow() -> void:
	print("── d) 无栈弹（trait_stack=null）判慢 ──")
	var b := _spawn(Vector2(360.0, 900.0), {"trait_stack": null})
	_check("d 无栈弹判 slow（僚机直发通道；③a 回归口径）", not b._pfast, str(b._pfast))


# ── e) 池化复用串弹防御 ────────────────────────────────────────────
func _test_e_pool_reuse_zeroing() -> void:
	print("── e) 池化复用：归还清零 + 同实例重生不串快路径态 ──")
	var b := _spawn(Vector2(360.0, 900.0))
	for i in range(20):
		if not b._live:
			break
		b._tick_fast_player(DT)
	_check("e 前置：资格弹已快路径驱动（_traveled>0 ∧ range_left>0 ∧ 两旗立）",
		b._traveled > 0.0 and b.range_left > 0.0 and b._pfast and b._vis_invariant)
	var pool := _gl.pools[&"projectile"] as ProjectilePool
	pool.release(b)
	_check("e 归还后 _pfast=false", not b._pfast)
	_check("e 归还后 _vis_invariant=false", not b._vis_invariant)
	_check("e 归还后 _traveled=0", absf(b._traveled) < 0.0001, str(b._traveled))
	_check("e 归还后 range_left=0", absf(b.range_left) < 0.0001, str(b.range_left))
	_check("e 归还后 _fast_radius=0（敌弹口同清）", absf(b._fast_radius) < 0.0001,
		str(b._fast_radius))
	_check("e 归还后 _fast_path=false", not b._fast_path)
	_check("e 归还后 _tick_dispatch_armed=false", not b._tick_dispatch_armed)
	# 同实例重生（池 LIFO 取回）：带预算参数 → 重算判慢且反弹真实生效（无上代快路径残留）
	var same: bool = _acquire() == b
	_check("e 池 LIFO 取回同实例（复用口径成立）", same)
	var b2 := b
	b2.spawn({
		"velocity": Vector2(1500.0, 0.0), "lifetime": 9.0, "pierce": 9, "team": 0,
		"hitbox_radius": 8.0, "bounces": 1, "range": 0.0, "trait_stack": null,
		"panel_snapshot": {"base_atk": 10.0, "flat_bonus": 0.0, "crit_rate": 0.0,
			"crit_mult": 2.0, "add_entries": []},
		"position": Vector2(360.0, 900.0),
	})
	_check("e 重生后重判：无栈+带预算弹 _pfast=false（判慢真因=trait_stack:null——R235 4a 后带栈预算弹判 fast；无上代资格残留同证）", not b2._pfast)
	var flipped := false
	for i in range(120):
		b2.tick(DT)
		if not b2._live:
			break
		if b2.velocity.x < 0.0:
			flipped = true
			break
	_check("e 重生后反弹真实生效（触墙反射——无串弹残留吞噬物理）", flipped)
	# 清场
	if b2._live:
		pool.release(b2)
	var pool_e := _gl.pools[&"enemy"] as EnemyPool
	for e in _gl.spawner.active.duplicate():
		if is_instance_valid(e):
			pool_e.release(e)
	_gl.spawner.active.clear()

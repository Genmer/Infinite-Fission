# tests/runner/r232_precache_cases.gd
# R232 刀1c 用例体（入口 test_r232_precache.gd 运行时 load）。覆盖矩阵：
# ① 全 condition_id × 随机参数 100 组：缓存路径 vs 活评路径 collect_mult_pools 逐值对拍
#    （设计 AC-5 测试锁——9/11 纯贡献 + PIERCE_INDEX_GE 贡献式）；
# ② PIERCE_INDEX_GE 贡献式专项（pi 1..4 × min 参数——缓存 base 现乘 (pi−1)）；
# ③ 栈失效（attach 换定义/新增 MULT → 缓存重建，新值可见）；
# ④ 帧稳定条件跨帧变化（player_hp_pct 跨阈值——条件活评非缓存）；
# ⑤ 池 dict 复用断言（缓存命中两次 collect 返回同一 dict 实例）+ orbit/arc 排除
#    （tctx.projectile=null 走活评路径——每次新 dict，AC-4 例外披露的测试面）；
# ⑥ 开关 false 原路径回归（活评恒等）。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const RANDOM_GROUPS := 100               # 设计 AC：全 condition_id × 随机参数 100 组
const EXPECTED_TOTAL := 13               # 套件总项数断言（R231 假绿教训）

# 乘区条件封闭枚举（GameConst.ConditionId 全量 11 值——含 NONE/TARGET_TAG_IN 留位）
const ALL_CONDITIONS := [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10]

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(4233)
	_boot_game_loop()
	await tree.process_frame
	await tree.process_frame
	PerfGovernor.set_process(false)
	_gl.state = GameConst.GameStatus.MENU
	_test_1_random_equiv_100()
	_test_2_pierce_contribution()
	_test_3_invalidation()
	_test_4_frame_stable_conditions()
	_test_5_dict_reuse_and_exclusion()
	_test_6_switch_off_parity()
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
	_rng.seed = 20261004


# ── 夹具 ──────────────────────────────────────────────────────────

func _mk_stack(p_cond_id: int, p_params: Dictionary, p_value: float) -> TraitStack:
	# 单 MULT 词条栈（TraitData 代码构造——condition/params 随机面）
	var stack := TraitStack.new()
	var td := TraitData.new()
	td.id = &"T_R232_PRE"
	td.display_name = "R232_PRE"
	td.pool = GameConst.PoolClass.MULT
	td.pool_id = &"r232_pre"
	td.effect_id = &"NONE_EFFECT"
	td.value = p_value
	td.cap_pool_p = 8.0
	td.stack_max = 1
	td.condition = {"condition_id": p_cond_id, "params": p_params}
	stack.attach(td)
	return stack


func _mk_tctx(p_stack_host_stack: bool, p_dctx: DamageContext, p_target: Node2D) -> TraitContext:
	# 投射物形态 tctx（projectile 通道=缓存路径唯一门）；p_stack_host_stack 仅占位
	var tctx := TraitContext.new()
	tctx.event = GameConst.TraitEvent.ON_HIT
	tctx.projectile = _carrier
	tctx.target = p_target
	tctx.damage_ctx = p_dctx
	return tctx


var _carrier: ProjectileBase = null


func _ensure_carrier() -> void:
	if _carrier != null and is_instance_valid(_carrier):
		return
	var pool := _gl.pools[&"projectile"] as ProjectilePool
	var proj := pool.acquire() as ProjectileBase
	proj.damage_pipeline = _gl.pipeline
	proj.enemy_grid = _gl.enemy_grid
	proj.pool = pool
	proj.spawn({
		"velocity": Vector2.ZERO, "lifetime": 10.0, "pierce": 9, "team": 0,
		"panel_snapshot": {"base_atk": 100.0, "flat_bonus": 0.0,
			"crit_rate": 0.0, "crit_mult": 2.0, "add_entries": []},
		"position": Vector2.ZERO,
	})
	_carrier = proj


func _mk_target(p_id: StringName, p_burning: bool, p_frozen: bool, p_shocked: bool,
		p_hp_pct: float, p_tags: int) -> Enemy:
	var pool := _gl.pools[&"enemy"] as EnemyPool
	var e := pool.acquire() as Enemy
	var d := EnemyData.new()
	d.id = p_id
	d.display_name = String(p_id)
	d.hp_base = 1000.0
	d.spd_base = 0.0
	d.dmg_base = 0.0
	d.exp_base = 1.0
	d.hitbox_r = 14.0
	d.resist = [0.0, 0.0, 0.0, 0.0]
	e.spawn(d, 1, p_tags)
	e._fade_left = 0.0
	var st := ElementalState.new()
	if p_burning:
		st.burn_timer = 2.0
	if p_frozen:
		st.freeze_timer = 2.0
	if p_shocked:
		st.gauges[GameConst.Element.LTG] = 50.0
	e.elemental = st
	e.hp = e.max_hp * p_hp_pct
	return e


func _mk_dctx(p_pierce: int, p_bounce: bool, p_hp_pct: float, p_first_wave: bool) -> DamageContext:
	var ctx := DamageContext.make()
	ctx.source_uid = 9901
	ctx.target_uid = 1
	ctx.frame_stamp = 100
	ctx.base_atk = 100.0
	ctx.pierce_index = p_pierce
	ctx.hit_flags = GameConst.HIT_IS_BOUNCE if p_bounce else 0
	ctx.player_hp_pct = p_hp_pct
	ctx.is_first_hit_of_wave = p_first_wave
	return ctx


func _collect_with(p_stack: TraitStack, p_precache: bool, p_tctx: TraitContext) -> Array[Dictionary]:
	TraitStack.TRAIT_PRECACHE = p_precache
	var out: Array[Dictionary] = p_stack.collect_mult_pools(p_tctx)
	return out


func _pools_equal(p_a: Array[Dictionary], p_b: Array[Dictionary]) -> bool:
	if p_a.size() != p_b.size():
		return false
	for i in range(p_a.size()):
		var a: Dictionary = p_a[i]
		var b: Dictionary = p_b[i]
		for k in ["pool_id", "source_uid", "contrib", "cap_pool", "priority"]:
			if a.get(k) != b.get(k):
				return false
	return true


func _pools_dump(p_p: Array[Dictionary]) -> String:
	var s := "["
	for d in p_p:
		s += "{%s,%.4f,%.2f}" % [str(d.get("pool_id")), float(d.get("contrib")), float(d.get("cap_pool"))]
	return s + "]"


# ── ① 全条件 × 随机参数 100 组逐值对拍 ────────────────────────────

func _test_1_random_equiv_100() -> void:
	print("── ① 全 condition_id × 随机参数 %d 组：缓存 vs 活评逐值对拍 ──" % RANDOM_GROUPS)
	var bad := 0
	var covered := {}
	for g in range(RANDOM_GROUPS):
		var cond_id: int = ALL_CONDITIONS[_rng.randi_range(0, ALL_CONDITIONS.size() - 1)]
		covered[cond_id] = true
		var params := _random_params(cond_id)
		var value := _rng.randf_range(-0.5, 2.0)     # 含负值（防御面）
		var stack := _mk_stack(cond_id, params, value)
		var target := _mk_target(&"E_R232_P1", _rng.randf() < 0.5, _rng.randf() < 0.5,
			_rng.randf() < 0.5, _rng.randf_range(0.0, 1.2), _rng.randi_range(0, 3))
		_ensure_carrier()
		var dctx := _mk_dctx(_rng.randi_range(1, 4), _rng.randf() < 0.5,
			_rng.randf_range(0.0, 1.0), _rng.randf() < 0.5)
		var tctx := _mk_tctx(true, dctx, target)
		var live := _collect_with(stack, false, tctx)
		TraitStack.TRAIT_PRECACHE = true             # 重置有效位后再走缓存路径
		stack.set("_pre_built", false)
		var cached := _collect_with(stack, true, tctx)
		if not _pools_equal(live, cached):
			bad += 1
			if bad <= 3:
				print("    组%03d 失配 cond=%d params=%s live=%s cached=%s"
					% [g, cond_id, str(params), _pools_dump(live), _pools_dump(cached)])
		(_gl.pools[&"enemy"] as EnemyPool).release(target)
	var missing: Array = []
	for c in ALL_CONDITIONS:
		if not covered.has(c):
			missing.append(c)
	_check("①%d 组缓存 vs 活评逐值相等（失配 0）" % RANDOM_GROUPS, bad == 0,
		"失配=%d" % bad)
	_check("①11 条件全覆盖（含 NONE/TARGET_TAG_IN 留位）", missing.is_empty(),
		"缺=%s" % str(missing))


func _random_params(p_cond: int) -> Dictionary:
	match p_cond:
		GameConst.ConditionId.PIERCE_INDEX_GE:
			return {"min": _rng.randi_range(1, 3)}
		GameConst.ConditionId.PLAYER_HP_BELOW, GameConst.ConditionId.PLAYER_HP_ABOVE, \
		GameConst.ConditionId.TARGET_HP_BELOW:
			return {"pct": _rng.randf_range(0.05, 0.95)}
		GameConst.ConditionId.TARGET_TAG_IN:
			return {"tags": _rng.randi_range(0, 3)}
		_:
			return {}


# ── ② PIERCE 贡献式专项 ───────────────────────────────────────────

func _test_2_pierce_contribution() -> void:
	print("── ② PIERCE_INDEX_GE 贡献式缓存（base 现乘 (pi−1)） ──")
	_ensure_carrier()
	var stack := _mk_stack(GameConst.ConditionId.PIERCE_INDEX_GE, {"min": 2}, 0.3)
	var target := _mk_target(&"E_R232_P2", false, false, false, 1.0, 0)
	var all_ok := true
	var detail := ""
	for pi in range(1, 5):
		var dctx := _mk_dctx(pi, false, 1.0, false)
		var tctx := _mk_tctx(true, dctx, target)
		var live := _collect_with(stack, false, tctx)
		stack.set("_pre_built", false)
		var cached := _collect_with(stack, true, tctx)
		var expect_ok := pi >= 2
		var contrib := float(cached[0]["contrib"]) if cached.size() == 1 else 0.0
		var expect := 0.3 * float(maxi(pi - 1, 0))
		if _pools_equal(live, cached) and (cached.size() == 1) == expect_ok \
				and (not expect_ok or absf(contrib - expect) < 0.0001):
			detail += "pi%d=%.2f " % [pi, contrib]
		else:
			all_ok = false
			detail += "pi%d 失配(%s) " % [pi, _pools_dump(cached)]
	_check("②pi1 不注入 · pi2=0.3 · pi3=0.6 · pi4=0.9（逐位=活评）", all_ok, detail)
	(_gl.pools[&"enemy"] as EnemyPool).release(target)


# ── ③ 栈失效（attach 重建） ───────────────────────────────────────

func _test_3_invalidation() -> void:
	print("── ③ 缓存失效（attach 新 MULT → 重建可见） ──")
	_ensure_carrier()
	var stack := _mk_stack(GameConst.ConditionId.NONE, {}, 0.5)
	var dctx := _mk_dctx(1, false, 1.0, false)
	var tctx := _mk_tctx(true, dctx, null)
	var first := _collect_with(stack, true, tctx)
	_check("③首次构建 NONE 常驻 1 池 contrib=0.5", first.size() == 1
		and is_equal_approx(float(first[0]["contrib"]), 0.5), _pools_dump(first))
	var td2 := TraitData.new()
	td2.id = &"T_R232_PRE2"
	td2.pool = GameConst.PoolClass.MULT
	td2.pool_id = &"r232_pre2"
	td2.effect_id = &"NONE_EFFECT"
	td2.value = 0.8
	td2.cap_pool_p = 8.0
	td2.condition = {"condition_id": GameConst.ConditionId.NONE, "params": {}}
	stack.attach(td2)                                 # 失效口：attach → _pre_built=false
	var second := _collect_with(stack, true, tctx)
	_check("③attach 后缓存重建（2 池 · 0.5/0.8 同现）", second.size() == 2
		and is_equal_approx(float(second[0]["contrib"]), 0.5)
		and is_equal_approx(float(second[1]["contrib"]), 0.8), _pools_dump(second))
	# 取优换定义（同 id 高值覆盖）路径：attach 内 bump 同样置失效位
	var td3 := TraitData.new()
	td3.id = &"T_R232_PRE2"
	td3.pool = GameConst.PoolClass.MULT
	td3.pool_id = &"r232_pre2"
	td3.effect_id = &"NONE_EFFECT"
	td3.value = 1.1
	td3.cap_pool_p = 8.0
	td3.condition = {"condition_id": GameConst.ConditionId.NONE, "params": {}}
	stack.attach(td3)
	var third := _collect_with(stack, true, tctx)
	_check("③取优换定义后新值 1.1 可见（失效面③覆盖）", third.size() == 2
		and is_equal_approx(float(third[1]["contrib"]), 1.1), _pools_dump(third))


# ── ④ 帧稳定条件跨帧变化 ──────────────────────────────────────────

func _test_4_frame_stable_conditions() -> void:
	print("── ④ 帧稳定条件跨帧（player_hp_pct 跨阈值——条件活评非缓存） ──")
	_ensure_carrier()
	var stack := _mk_stack(GameConst.ConditionId.PLAYER_HP_BELOW, {"pct": 0.35}, 0.4)
	var dctx_lo := _mk_dctx(1, false, 0.2, false)     # 背水真
	var dctx_hi := _mk_dctx(1, false, 0.9, false)     # 背水假
	var t_lo := _mk_tctx(true, dctx_lo, null)
	var t_hi := _mk_tctx(true, dctx_hi, null)
	var warm := _collect_with(stack, true, t_lo)      # 缓存已建（背水真）
	_check("④缓存建立（血线 0.2<0.35 → 1 池 0.4）", warm.size() == 1
		and is_equal_approx(float(warm[0]["contrib"]), 0.4), _pools_dump(warm))
	var after := _collect_with(stack, true, t_hi)     # 缓存命中期跨阈值——必须为空
	_check("④血线回升同栈缓存命中期条件翻转（0 池——贡献缓存不冻结条件）",
		after.is_empty(), _pools_dump(after))
	var back := _collect_with(stack, true, t_lo)
	_check("④血线再回落恢复注入（1 池）", back.size() == 1, _pools_dump(back))
	# WAVE_FIRST_HIT 同面（禁帧缓存条款）
	var stack_w := _mk_stack(GameConst.ConditionId.WAVE_FIRST_HIT, {}, 0.25)
	var dctx_w1 := _mk_dctx(1, false, 1.0, true)
	var dctx_w2 := _mk_dctx(1, false, 1.0, false)
	var w1 := _collect_with(stack_w, true, _mk_tctx(true, dctx_w1, null))
	var w2 := _collect_with(stack_w, true, _mk_tctx(true, dctx_w2, null))
	_check("④WAVE_FIRST_HIT 逐命中活评（true→1 池 / false→0 池）",
		w1.size() == 1 and w2.is_empty(), "%s|%s" % [_pools_dump(w1), _pools_dump(w2)])


# ── ⑤ dict 复用 + orbit/arc 排除 ─────────────────────────────────

func _test_5_dict_reuse_and_exclusion() -> void:
	print("── ⑤ 池 dict 复用断言 + orbit/arc 排除（tctx.projectile=null 走活评） ──")
	_ensure_carrier()
	var stack := _mk_stack(GameConst.ConditionId.NONE, {}, 0.5)
	var dctx := _mk_dctx(1, false, 1.0, false)
	var tctx := _mk_tctx(true, dctx, null)
	var a := _collect_with(stack, true, tctx)
	var b := _collect_with(stack, true, tctx)
	_check("⑤缓存路径两次 collect 返回同一 dict 实例（复用改值不重建——is_same 身份判）",
		a.size() == 1 and is_same(a[0], b[0]), "")
	# orbit/arc 形态 tctx（weapon/melee 载体——projectile=null）必须走活评路径：
	# 主栈 LIVE 语义（分析 AC-4 例外）——每次新 dict 且值与活评逐位同
	var mtctx := TraitContext.new()
	mtctx.event = GameConst.TraitEvent.ON_HIT
	mtctx.weapon = null
	mtctx.melee = null
	mtctx.target = null
	mtctx.damage_ctx = dctx
	stack.set("_pre_built", false)
	var m1 := _collect_with(stack, true, mtctx)
	var m2 := _collect_with(stack, true, mtctx)
	_check("⑤projectile=null（orbit/arc 形态）走活评（每次新 dict 实例——主栈 LIVE 语义）",
		m1.size() == 1 and not is_same(m1[0], m2[0])
		and is_equal_approx(float(m1[0]["contrib"]), 0.5), "")


# ── ⑥ 开关 false 原路径回归 ───────────────────────────────────────

func _test_6_switch_off_parity() -> void:
	print("── ⑥ 开关 false 原路径回归 ──")
	_ensure_carrier()
	var stack := _mk_stack(GameConst.ConditionId.PLAYER_HP_ABOVE, {"pct": 0.7}, 0.6)
	var dctx := _mk_dctx(1, false, 0.9, false)
	var tctx := _mk_tctx(true, dctx, null)
	var off := _collect_with(stack, false, tctx)
	_check("⑥开关 false 活评路径（1 池 0.6——满血壁垒真）", off.size() == 1
		and is_equal_approx(float(off[0]["contrib"]), 0.6), _pools_dump(off))
	TraitStack.TRAIT_PRECACHE = true


# ── 收尾 ──────────────────────────────────────────────────────────

func _cleanup() -> void:
	_check("套件总项数（EXPECTED=%d——R231 假绿教训：总项数也要断言）" % EXPECTED_TOTAL,
		_pass + _fail == EXPECTED_TOTAL, "实=%d" % (_pass + _fail))
	TraitStack.TRAIT_PRECACHE = true
	DamagePipeline.CTX_REUSE = true
	if _carrier != null and is_instance_valid(_carrier):
		(_gl.pools[&"projectile"] as ProjectilePool).release(_carrier)
	_carrier = null
	PerfGovernor.set_process(true)
	if _gl != null:
		_gl.queue_free()
		await tree.process_frame

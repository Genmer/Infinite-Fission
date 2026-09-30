# tests/runner/high_stack_cases.gd
# 高位叠层审计用例体（由 test_high_stack.gd 两段式入口运行期 load()，autoload 就绪后编译）。
# 真源：用户问「buff 后期无限叠层是否都在生效」——本套件落库十条即绿口径：
# ①千层聚合线性（100/1000 层 ±1e-9 + 逐层增量）②attach 门 stack_max 封顶
# ③F4 池钳 2.0 + clamped_add 记账 + FALLBACK dmg(40)==dmg(99)（饱和点=设计内显式钳制）
# ④诅咒全额线性 + 终值钳 0 无 NaN ⑤乘区护栏（cap_pool/top-8/cap_prod 8.0/crit 1.0/
#   cdr 0.6/rof 30）⑥R186 每击谐振预算网格（60 击/回充帽/就绪不计费/同帧 120 击恰 60/
#   120Hz 帧粒度 soak ≥120k tick）⑦R183 反应乘区注册表千次循环归 1.0
# ⑧详情面板叠层显示（pause_overlay.gd:524 正则修复：+15%×2→+30% 等）
# ⑨逐帧聚合成本线性标度（比值 ∈[5,15]，禁写死绝对 µs）+ copy_full 混品级保真
# ⑩存档现版绿口径（layers 往返保真/恢复受 stack_max 钳/满层质变 ×1.6 末次挂载再触发）。
# 可搬运探针来源（res:// 路径改写后并入）：qa_tmp_buffs16/probe_buffs16.gd、
# qa_tmp_buffaudit3/stack_audit_cases.gd、qa_tmp_buffaudit2/stack_probe_cases.gd。
# 存档有损项（混品级降白/运行期卡蒸发/遗物不入档）按仲裁裁定只写注释不落断言。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const SOAK_TICKS := 120000                       # ⑥ 120Hz 帧粒度 soak 下限（≥120k tick）
const DT_120 := 1.0 / 120.0

var tree: SceneTree = null
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null
var _w1: WeaponBase = null
var _overlay: PauseOverlay = null                # ⑧ 显示断言宿主（不进树，纯方法调用）


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_boot_game_loop()
	_section("① 千层线性（100/1000 层聚合 ±1e-9 + 逐层增量）")
	_test_thousand_layer_linear()
	_section("② attach 门 stack_max 封顶（真卡帽 / 99 帽载体）")
	_test_attach_cap()
	_section("③ F4 池钳 2.0 + clamped_add 记账 + FALLBACK dmg(40)==dmg(99)")
	_test_f4_pool_clamp()
	_section("④ 诅咒全额线性 + 终值钳 0（无 NaN/Inf 泄漏）")
	_test_curse_full_and_zero_floor()
	_section("⑤ 乘区护栏（cap_pool/top-8/cap_prod 8.0/crit 1.0/cdr 0.6/rof 30）")
	_test_mult_guards()
	_section("⑥ R186 每击谐振预算网格 + 120Hz 帧粒度 soak")
	_test_r186_budget_grid()
	_section("⑦ R183 反应乘区注册表（千次循环归 1.0/同 uid 覆写/局清）")
	_test_r183_registry()
	_section("⑧ 详情面板叠层显示（+15%×2→+30% 等，依赖 :524 正则修复）")
	_test_display_rendering()
	_section("⑨ 聚合成本线性标度（比值 ∈[5,15]）+ copy_full 混品级保真")
	_test_cost_scaling_and_copy_full()
	_section("⑩ 存档现版绿口径（layers 往返/stack_max 钳/满层质变 ×1.6）")
	_test_save_green_path()
	_teardown_game_loop()
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)


func fail_count() -> int:
	return _fail


# ── 夹具 ─────────────────────────────────────────────────────────
func _boot_game_loop() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "HighStackLoopUnderTest"
	tree.get_root().add_child(_gl)
	_gl.state = GameConst.GameStatus.MENU
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	_gl.start_run()
	_gl.player.set("max_hp", 1000000.0)
	_gl.player.set("hp", 1000000.0)
	_w1 = _gl.player.weapon_slots[0]


func _teardown_game_loop() -> void:
	tree.paused = false
	RunSave.clear()
	Meta.set_run_map(MapTable.FIRST_MAP_ID)      # ⑩ 改过的质变门查询口复位
	_gl.elemental.clear_reaction_mults()
	_gl.relic_handler.reset_run()
	if _overlay != null and is_instance_valid(_overlay):
		_overlay.free()
		_overlay = null
	if _gl != null:
		_gl.free()
		_gl = null


func _cfg() -> Object:
	return tree.get_root().get_node("GameConfig")


func _section(p_title: String) -> void:
	print("── %s ──" % p_title)


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("PASS | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s | %s" % [p_name, p_detail])
		print("FAIL | %s | %s" % [p_name, p_detail])


func _mk_add(p_pool: StringName, p_value: float, p_stack_max: int, p_id: StringName = &"") -> TraitData:
	# 探针词条构造（id 缺省按池派生；同池多 id 场景显式传 p_id 防止并层）
	var td := TraitData.new()
	td.id = p_id if p_id != &"" else StringName("HSC_%s" % String(p_pool))
	td.display_name = "hsc_probe"
	td.pool = GameConst.PoolClass.ADD
	td.pool_id = p_pool
	td.effect_id = &"EF_STAT"
	td.value = p_value
	td.decay_delta = 0.0
	td.stack_max = p_stack_max
	return td


func _attach_n(p_stack: TraitStack, p_td: TraitData, p_n: int) -> int:
	var ok := 0
	for i in range(p_n):
		if p_stack.attach(p_td):
			ok += 1
	return ok


func _bench_us(p_iters: int, p_callable: Callable) -> float:
	var t0 := Time.get_ticks_usec()
	for i in range(p_iters):
		p_callable.call()
	return float(Time.get_ticks_usec() - t0) / float(p_iters)


func _reset_stack() -> void:
	_w1.trait_stack.clear()
	_w1.call("_invalidate_panel")


func _reacquire_weapon() -> void:
	# _restore_run_state 重建武器节点——恢复后必须重取 slot[0]（否则写孤儿栈）
	_w1 = _gl.player.weapon_slots[0]


func _mounted_of(p_id: StringName) -> TraitBase:
	for tb in _w1.trait_stack.traits:
		if tb.data != null and tb.data.id == p_id:
			return tb
	return null


func _agg_of_id(p_stack: TraitStack, p_pool: StringName, p_id: StringName) -> float:
	# 仅统计 p_id 词条对 p_pool 的贡献（逐 mounted 求和，避免同池跨 ID 混算）
	var total := 0.0
	for m in p_stack.traits:
		if m.data != null and m.data.id == p_id and m.data.pool_id == p_pool:
			for v in m.layer_values:
				total += float(v) * float(m.value_mult)
	return total


func _live_layers_of(p_id: StringName) -> int:
	for wv: Variant in _gl.player.weapon_slots:
		if wv == null or not is_instance_valid(wv):
			continue
		var stack: TraitStack = wv.get("trait_stack")
		if stack == null:
			continue
		for m in stack.traits:
			if m.data != null and m.data.id == p_id:
				return int(m.layers)
	return 0


func _saved_layers_of(p_saved: Dictionary, p_id: String) -> int:
	for wv: Variant in p_saved.get("weapons", []):
		var wd: Dictionary = wv if wv is Dictionary else {}
		for tv: Variant in wd.get("traits", []):
			var td: Dictionary = tv if tv is Dictionary else {}
			if String(td.get("id", "")) == p_id:
				return int(td.get("layers", 0))
	return -1


func _make_dummy(p_pos: Vector2) -> Enemy:
	# 管线结算目标（高血 dummy——E-06 死亡短路：target==null 的 resolve 会被丢弃）
	var e: Enemy = (_gl.pools[&"enemy"] as EnemyPool).acquire()
	var data := EnemyData.new()
	data.id = &"E_HSC_DUMMY"
	data.hp_base = 1000000.0
	data.spd_base = 0.0
	data.hitbox_r = 14.0
	e.spawn(data, 1, 0)
	e.position = p_pos
	return e


func _resolve_with_n_adds(p_target: Enemy, p_n: int, p_val: float, p_curse: bool) -> DamageResult:
	# 真管线直注 n 条 add_entry（base 100 / 零暴击）；每发推帧号防同帧幂等折叠
	GameConfig.frame_stamp += 1
	var ctx := DamageContext.make()
	ctx.source_uid = 925000 + p_n + (1 if p_curse else 0)
	ctx.frame_stamp = int(GameConfig.frame_stamp)
	ctx.target = p_target
	ctx.target_uid = int(p_target.get("uid"))
	ctx.pos = p_target.global_position
	ctx.base_atk = 100.0
	ctx.crit_chance = 0.0
	for i in range(p_n):
		ctx.add_entries.append({"pool_id": &"add_atk", "layer": 1, "contrib": p_val,
			"decay_delta": 0.85, "is_curse": p_curse})
	return _gl.pipeline.resolve(ctx)


# ── ① 千层线性 ───────────────────────────────────────────────────
func _test_thousand_layer_linear() -> void:
	var td := _mk_add(&"add_atk", 0.15, 4000)
	var s := TraitStack.new()
	var got := _attach_n(s, td, 1000)
	var m := s.traits[0]
	_check("①a 1000 层逐层挂载全成功，layers/layer_values 同步 1000",
		got == 1000 and int(m.layers) == 1000 and (m.layer_values as Array).size() == 1000,
		"got=%d layers=%d" % [got, int(m.layers)])
	var agg := float(s.aggregate_panel().get(&"add_atk", 0.0))
	_check("①b 1000 层 aggregate_panel = 150.0（绝对误差 <1e-9，无隐藏饱和）",
		absf(agg - 150.0) < 1e-9, str(agg))
	_check("①c stacked_add_total 与面板同源 150.0",
		absf(m.stacked_add_total() - 150.0) < 1e-9, str(m.stacked_add_total()))
	var before := float(s.aggregate_panel().get(&"add_atk", 0.0))
	s.attach(td)
	var after := float(s.aggregate_panel().get(&"add_atk", 0.0))
	_check("①d 第 1001 层增量恰 +0.15（逐层仍按层生效）", absf((after - before) - 0.15) < 1e-12,
		"%f -> %f" % [before, after])
	var s100 := TraitStack.new()
	_attach_n(s100, td, 100)
	var agg100 := float(s100.aggregate_panel().get(&"add_atk", 0.0))
	_check("①e 100 层 aggregate_panel = 15.0（±1e-9）", absf(agg100 - 15.0) < 1e-9, str(agg100))


# ── ② attach 门 stack_max 封顶（R196 有意契约变更：ADD 池帽放宽至
#    stack_max + OVERCAP_EXT_MAX(5)——超帽层 ×0.7 计贡献，非 ADD 池保持原帽） ──
func _test_attach_cap() -> void:
	var real_td: TraitData = _gl.registry.get_trait(&"AFF_ATK_UP")
	var s := TraitStack.new()
	var got := _attach_n(s, real_td, 10)
	var over := _attach_n(s, real_td, 1)
	# R196 有意契约变更（原「attach×10 → 恰 3 层，满层再挂拒绝」）：ADD 池恰收
	# stack_max+OVERCAP_EXT_MAX = 3+5 = 8 层，第 9 层拒绝
	_check("②a 真卡 AFF_ATK_UP attach×10 → 恰 8 层（stack_max+超帽延伸 5），第 9 层拒绝",
		got == 8 and over == 0 and int(s.traits[0].layers) == 8,
		"got=%d over=%d" % [got, over])
	var fb := _mk_add(&"add_atk", 0.05, 99, &"HSC_FALLBACK99")
	var s99 := TraitStack.new()
	var got99 := _attach_n(s99, fb, 200)
	# R196 有意契约变更（原「恰 99 层硬帽」）：ADD 池硬帽平移至 99+OVERCAP_EXT_MAX = 104
	_check("②b 运行期 stack_max=99 载体（FALLBACK 口径）attach×200 → 恰 104 层硬帽（stack_max+5）",
		got99 == 104 and int(s99.traits[0].layers) == 104, str(got99))


# ── ③ F4 池钳 2.0 + 记账 + FALLBACK dmg(40)==dmg(99) ─────────────
func _test_f4_pool_clamp() -> void:
	var caps: Dictionary = _cfg().balance.add_pool_caps
	_check("③a F4 帽真源 add_atk = 2.0", absf(float(caps.get("add_atk", 0.0)) - 2.0) < 1e-12,
		str(caps.get("add_atk")))
	var ms := ModifierStack.new()
	ms.audit = DamageAudit.new()
	var entries: Array[Dictionary] = []
	for i in range(99):
		entries.append({"trait_id": &"HSC_FALLBACK99", "pool_id": &"add_atk", "layer": 1,
			"contrib": 0.05, "decay_delta": 0.85, "is_curse": false})
	ms.aggregate_add(entries, caps)
	_check("③b 99×0.05=4.95 → F4 钳 2.0 + audit.clamped_add 记账（饱和可见非隐式）",
		absf(float(ms.add_pool_sum.get(&"add_atk", 0.0)) - 2.0) < 1e-12
		and (ms.audit as DamageAudit).clamped_add.has(&"add_atk"),
		str(ms.add_pool_sum.get(&"add_atk")))
	# 管线端到端：40 层（恰触帽）与 99 层终值相等 = 饱和点设计内（>40 层边际 0，不失控）
	var dummy := _make_dummy(Vector2(300.0, 500.0))
	var r40 := _resolve_with_n_adds(dummy, 40, 0.05, false)
	var r99 := _resolve_with_n_adds(dummy, 99, 0.05, false)
	_check("③c FALLBACK dmg(40) == dmg(99) == 300（1+F4 帽 2.0）",
		r40 != null and r99 != null
		and absf(float(r40.final_value) - 300.0) < 0.01
		and absf(float(r99.final_value) - 300.0) < 0.01,
		"40=%s 99=%s" % [str(r40.final_value if r40 != null else -1.0),
			str(r99.final_value if r99 != null else -1.0)])
	_check("③d 99 层审计可见（clamped_add）且 R_alarm 不误报",
		r99 != null and (r99.audit as DamageAudit).clamped_add.has(&"add_atk")
		and not bool((r99.audit as DamageAudit).alarm))
	dummy.queue_free()


# ── ④ 诅咒全额 + 终值钳 0 ────────────────────────────────────────
func _test_curse_full_and_zero_floor() -> void:
	var caps: Dictionary = _cfg().balance.add_pool_caps
	var ms := ModifierStack.new()
	var entries: Array[Dictionary] = []
	for i in range(99):
		entries.append({"pool_id": &"add_atk", "layer": 1, "contrib": -0.1,
			"decay_delta": 0.85, "is_curse": true})
	ms.aggregate_add(entries, caps)
	_check("④a 诅咒 99 层线性全额 −9.9（不衰减/不钳——惩罚语义按层全额）",
		absf(float(ms.add_pool_sum.get(&"add_atk", 0.0)) + 9.9) < 1e-9,
		str(ms.add_pool_sum.get(&"add_atk")))
	var curse := _mk_add(&"add_atk", -0.1, 4000, &"HSC_CURSE")
	curse.params = {"is_curse": true}
	var s := TraitStack.new()
	_attach_n(s, curse, 1000)
	_check("④b 诅咒 1000 层叠层面全额 −100（无 NaN）",
		is_finite(s.traits[0].stacked_add_total())
		and absf(s.traits[0].stacked_add_total() + 100.0) < 1e-6,
		str(s.traits[0].stacked_add_total()))
	var dummy := _make_dummy(Vector2(300.0, 500.0))
	var rc := _resolve_with_n_adds(dummy, 99, -0.1, true)
	_check("④c 诅咒 99 层 → S 转负、终值钳 0（有限、无 NaN、无误告警）",
		rc != null and float(rc.panel_snapshot) < 0.0 and float(rc.final_value) == 0.0
		and is_finite(float(rc.final_value))
		and not bool((rc.audit as DamageAudit).alarm),
		"S=%s final=%s" % [str(rc.panel_snapshot if rc != null else 0.0),
			str(rc.final_value if rc != null else 0.0)])
	dummy.queue_free()


# ── ⑤ 乘区护栏 ───────────────────────────────────────────────────
func _test_mult_guards() -> void:
	# 单区钳（⑤c）：agg > cap_pool → merged_M = 1 + cap_pool
	var ms := ModifierStack.new()
	var one: Array[Dictionary] = [{"pool_id": &"mult_probe", "source_uid": 0,
		"contrib": 5.0, "cap_pool": 2.0, "priority": 0}]
	ms.aggregate_mults(one, int(_cfg().balance.cap_mul_count), float(_cfg().balance.cap_prod))
	_check("⑤a 单区钳：contrib 5.0/cap_pool 2.0 → merged_M = 3.0",
		ms.resolved_mults.size() == 1 and absf(float(ms.resolved_mults[0]["M"]) - 3.0) < 1e-12,
		str(ms.resolved_mults))
	# 名额 top-8 + 整体钳 cap_prod=8.0（20 区 ×3.0 → 3^8=6561 → 8）
	var ms4 := ModifierStack.new()
	ms4.audit = DamageAudit.new()
	var many: Array[Dictionary] = []
	for i in range(20):
		many.append({"pool_id": StringName("mult_p%02d" % i), "source_uid": 0,
			"contrib": 2.0, "cap_pool": 2.0, "priority": 0})
	ms4.aggregate_mults(many, int(_cfg().balance.cap_mul_count), float(_cfg().balance.cap_prod))
	_check("⑤b 乘区名额 top-8（20 区 → 8 入）+ cap_prod 钳 8.0 + 审计 compressed",
		ms4.resolved_mults.size() == 8 and absf(ms4.product_clamped - 8.0) < 1e-12
		and (ms4.audit as DamageAudit).compressed,
		"n=%d prod=%s" % [ms4.resolved_mults.size(), str(ms4.product_clamped)])
	# 消费口显式钳：crit 1.0 / 技能急速 0.6 / BALLISTIC 节拍 30/s
	_attach_n(_w1.trait_stack, _mk_add(&"add_crit", 0.08, 4000), 1000)
	_w1.call("_invalidate_panel")
	var snap: Dictionary = _w1.build_panel_snapshot()
	_check("⑤c add_crit 1000 层 → crit_rate 钳 cap_crit_rate=1.0",
		absf(float(snap.get("crit_rate", 0.0)) - 1.0) < 1e-12, str(snap.get("crit_rate")))
	_attach_n(_w1.trait_stack, _mk_add(&"add_skillcdr", 0.12, 4000), 1000)
	_gl.player.call("refresh_skill_cd")
	_check("⑤d add_skillcdr 1000 层 → 技能急速钳 0.6",
		absf(float(_gl.player.call("skill_haste_pct")) - 0.6) < 1e-12,
		str(_gl.player.call("skill_haste_pct")))
	_attach_n(_w1.trait_stack, _mk_add(&"add_rof", 0.12, 4000), 1000)
	# W1 首发为 BALLISTIC 形态：节拍走 rof×(1+Σadd_rof)，最终钳 cap_rof 30/s
	var interval := float(_w1.call("_fire_interval"))
	_check("⑤e BALLISTIC add_rof 1000 层 → 节拍钳 1/30 s（cap_rof_per_weapon=30）",
		absf(interval - 1.0 / 30.0) < 0.001, "interval=%f（1/30=%f）" % [interval, 1.0 / 30.0])
	_reset_stack()


# ── ⑥ R186 每击谐振预算网格 + soak ───────────────────────────────
func _test_r186_budget_grid() -> void:
	var rh: RelicHandler = _gl.relic_handler
	rh.reset_run()
	var ok: bool = rh.activate(&"REL_ATTACK_CDR")
	_check("⑥a 激活拉满存款 0.6（20/s×0.01×3 网格化快照）",
		ok and absf(rh._atk_cdr_budget - 0.6) < 1e-12, str(rh._atk_cdr_budget))
	_gl.player.set("skill_cd_left", 120.0)
	for i in range(60):
		rh.on_attack_fired()
	_check("⑥b 满 60 击直减 0.6 → CD 119.4（snappedf 网格无浮点漂移）",
		absf(float(_gl.player.get("skill_cd_left")) - 119.4) < 1e-9,
		str(_gl.player.get("skill_cd_left")))
	_check("⑥c 计费遥测 credits==60 / seconds==0.60",
		int(rh.attack_cdr_credits) == 60 and absf(rh.attack_cdr_seconds - 0.6) < 1e-9,
		"%d / %f" % [rh.attack_cdr_credits, rh.attack_cdr_seconds])
	var cd_before: float = float(_gl.player.get("skill_cd_left"))
	rh.on_attack_fired()
	_check("⑥d 存款枯竭第 61 击不直减（<1 击预算整击丢弃）",
		absf(float(_gl.player.get("skill_cd_left")) - cd_before) < 1e-12)
	rh.tick(1.0)
	_check("⑥e tick(1s) 回充 0.2（20 击/s 口径）", absf(rh._atk_cdr_budget - 0.2) < 1e-12,
		str(rh._atk_cdr_budget))
	rh.tick(2.0)
	_check("⑥f 继续回充钳存款帽 0.6", absf(rh._atk_cdr_budget - 0.6) < 1e-12,
		str(rh._atk_cdr_budget))
	# 同帧 120 击恰 60 计费（帽语义：0.6/0.01=60 击后整击丢弃）
	var credits0 := int(rh.attack_cdr_credits)
	for i in range(120):
		rh.on_attack_fired()
	_check("⑥g 同帧 120 击恰 +60 计费 / CD 119.4→118.8（回充-消耗循环无漂移）",
		int(rh.attack_cdr_credits) - credits0 == 60
		and absf(float(_gl.player.get("skill_cd_left")) - 118.8) < 1e-9,
		"credits+%d cd=%s" % [int(rh.attack_cdr_credits) - credits0,
			str(_gl.player.get("skill_cd_left"))])
	# 就绪不计费：技能就绪（cd≤0）时预算留存
	rh.tick(2.0)
	_gl.player.set("skill_cd_left", 0.0)
	var b_full: float = rh._atk_cdr_budget
	rh.on_attack_fired()
	_check("⑥h 技能就绪不计费（存款留存）", absf(rh._atk_cdr_budget - b_full) < 1e-12)
	# 120Hz 帧粒度 soak：≥120k 次 tick(1/120s)，预算恰回充至帽、遥测零计费、无漂移
	_gl.player.set("skill_cd_left", 120.0)
	for i in range(60):
		rh.on_attack_fired()                     # 存款清零
	var credits_pre := int(rh.attack_cdr_credits)
	for i in range(SOAK_TICKS):
		rh.tick(DT_120)
	_check("⑥i 120k×(1/120s) tick soak：预算恰回帽 0.6、计费零增、无 NaN",
		absf(rh._atk_cdr_budget - 0.6) < 1e-12 and is_finite(rh._atk_cdr_budget)
		and int(rh.attack_cdr_credits) == credits_pre,
		"budget=%s credits=%d" % [str(rh._atk_cdr_budget), int(rh.attack_cdr_credits)])
	rh.reset_run()


# ── ⑦ R183 反应乘区注册表 ────────────────────────────────────────
func _test_r183_registry() -> void:
	var sys := _gl.elemental
	sys.clear_reaction_mults()
	_check("⑦a 清空后 reaction_mult = 1.0", absf(sys.reaction_mult() - 1.0) < 1e-12,
		str(sys.reaction_mult()))
	sys.register_reaction_mult(7, 1.8)
	sys.register_reaction_mult(7, 4.7)
	_check("⑦b 同 uid 重注册覆盖（4.7，非连乘 8.46）", absf(sys.reaction_mult() - 4.7) < 1e-12,
		str(sys.reaction_mult()))
	sys.clear_reaction_mults()                   # 清 ⑦b 残留——千次循环从空表起步
	for i in range(1000):
		sys.register_reaction_mult(i + 100, 4.7)
		sys.unregister_reaction_mult(i + 100)
	_check("⑦c 1000 注册/注销循环 → 表空 + 聚合归 1.0（注销泄漏回归锁）",
		(sys._reaction_mults as Dictionary).is_empty()
		and absf(sys.reaction_mult() - 1.0) < 1e-12,
		"n=%d mult=%s" % [(sys._reaction_mults as Dictionary).size(), str(sys.reaction_mult())])
	sys.register_reaction_mult(1000 + 5, 4.7)
	sys.unregister_reaction_mult(99999)          # 幻影 uid 静默
	_check("⑦d 注销口精确移除 + 幻影 uid 静默",
		(sys._reaction_mults as Dictionary).size() == 1)
	sys.clear_reaction_mults()
	_check("⑦e 局清空回 1.0（start_run/continue_run 两口同源）",
		absf(sys.reaction_mult() - 1.0) < 1e-12, str(sys.reaction_mult()))


# ── ⑧ 详情面板叠层显示 ──────────────────────────────────────────
func _mk_desc_tb(p_desc: String, p_value: float, p_layers: int) -> TraitBase:
	# 显示断言夹具：描述含首个「+N」记号 + 逐层记账值；stack_max=99 防 mount 语义干扰
	var td := TraitData.new()
	td.id = StringName("HSC_DSP_%s" % str(p_layers))
	td.display_name = "hsc_display"
	td.description = p_desc
	td.pool = GameConst.PoolClass.ADD
	td.pool_id = &"add_atk"
	td.effect_id = &"EF_STAT"
	td.value = p_value
	td.stack_max = 99
	var tb := TraitBase.new()
	tb.setup(td)
	tb.layers = p_layers
	var vals: Array[float] = []
	for i in range(p_layers):
		vals.append(p_value)
	tb.layer_values = vals
	return tb


func _test_display_rendering() -> void:
	if _overlay == null:
		_overlay = PauseOverlay.new()            # 不进树：_trait_desc_bbcode 为纯函数段
	var ov := _overlay
	# +15%×2：修复前单数字位正则把「+15%」咬成「+1」→ 渲染「+0.35%」
	var out1 := ov._trait_desc_bbcode(_mk_desc_tb("攻击 +15%", 0.15, 2))
	_check("⑧a +15%×2 → 「+30%」（金色高亮），不再渲染「+0.3…」",
		out1.contains("+30%") and not out1.contains("+0.3") and out1.contains("ffd54a"),
		str(out1))
	# +25×4：修复前「+25」咬成「+2」→ 渲染「+1005」
	var out2 := ov._trait_desc_bbcode(_mk_desc_tb("攻击 +25", 25.0, 4))
	_check("⑧b +25×4 → 「+100」，不再渲染「1005」",
		out2.contains("+100") and not out2.contains("1005"), str(out2))
	var out3 := ov._trait_desc_bbcode(_mk_desc_tb("攻速 +8%", 0.08, 3))
	_check("⑧c +8%×3 → 「+24%」", out3.contains("+24%"), str(out3))
	var out4 := ov._trait_desc_bbcode(_mk_desc_tb("弹丸 +1", 1.0, 2))
	_check("⑧d +1×2 → 「+2」", out4.contains("+2"), str(out4))
	var desc5 := "攻击 +15%"
	var out5 := ov._trait_desc_bbcode(_mk_desc_tb(desc5, 0.15, 1))
	_check("⑧e 1 层描述逐字不变（不改写）", out5 == desc5, str(out5))
	var desc6 := "攻击 +10%"
	var out6 := ov._trait_desc_bbcode(_mk_desc_tb(desc6, -0.10, 2))
	_check("⑧f 负值（-10%）描述逐字不变（eff≤0 早退不改写）", out6 == desc6, str(out6))


# ── ⑨ 成本线性标度 + copy_full 混品级保真 ────────────────────────
func _test_cost_scaling_and_copy_full() -> void:
	var pools: Array[StringName] = [&"add_atk", &"add_rof", &"add_cdr", &"add_crit",
		&"add_critdmg", &"add_spd", &"add_size", &"add_knock", &"add_pickup",
		&"add_xp", &"add_gold", &"add_skillcdr"]
	var t100 := -1.0
	var t1000 := -1.0
	for n in [100, 1000]:
		var stack := TraitStack.new()
		for pid in pools:
			_attach_n(stack, _mk_add(pid, 0.05, 4000), n)
		var t_panel := _bench_us(2000, func() -> void: stack.aggregate_panel())
		print("N=%4d | aggregate_panel %8.3f µs/次" % [n, t_panel])
		if n == 100:
			t100 = t_panel
		else:
			t1000 = t_panel
	var ratio := t1000 / maxf(t100, 0.001)
	_check("⑨a 成本随层数线性标度（1000 层/100 层比值 ∈[5,15]——O(总层数) 无超线性爆炸；禁写死绝对 µs）",
		t100 > 0.0 and ratio > 5.0 and ratio < 15.0,
		"t100=%f t1000=%f ratio=%f" % [t100, t1000, ratio])
	# copy_full 混品级保真（R183/R187 僚机复制路径）：逐层品级数值逐位搬运
	var sm := TraitStack.new()
	var vals := [0.15, 0.21, 0.39]
	for k in range(vals.size()):
		_attach_n(sm, _mk_add(&"add_atk", vals[k], 4000,
			StringName("HSC_MIX_%d" % k)), 50)
	var src_agg := _agg_of_id(sm, &"add_atk", &"HSC_MIX_0") \
		+ _agg_of_id(sm, &"add_atk", &"HSC_MIX_1") + _agg_of_id(sm, &"add_atk", &"HSC_MIX_2")
	var clone := sm.copy_full()
	var full_agg := 0.0
	var full_layers := 0
	for tb in clone.traits:
		full_agg += tb.stacked_add_total()
		full_layers += (tb.layer_values as Array).size()
	_check("⑨b copy_full 混品级保真：源 37.5 → 克隆 37.5（±1e-9）且逐层条目 150 保真",
		absf(src_agg - 37.5) < 1e-9 and absf(full_agg - 37.5) < 1e-9 and full_layers == 150,
		"src=%s clone=%s layers=%d" % [str(src_agg), str(full_agg), full_layers])
	# 注：copy_runtime 逐层值不搬运（单层口径回落）为既有 E-13/R183 设计口径，本组不落断言。


# ── ⑩ 存档现版绿口径 ─────────────────────────────────────────────
func _test_save_green_path() -> void:
	# a. layers 往返保真：内存快照 → ConfigFile 落盘回读 → _restore_run_state 实挂
	_reset_stack()
	var ok3 := true
	for i in range(3):
		ok3 = bool(_w1.attach_trait(_gl.registry.get_trait(&"AFF_ATK_UP"))) and ok3
	var agg_before := _agg_of_id(_w1.trait_stack, &"add_atk", &"AFF_ATK_UP")
	var saved: Dictionary = _gl.serialize_run()
	var saved_layers := _saved_layers_of(saved, "AFF_ATK_UP")
	RunSave.save_run(saved)
	var reloaded := RunSave.load_run()
	var disk_layers := _saved_layers_of(reloaded, "AFF_ATK_UP")
	_gl._restore_run_state(reloaded)
	_reacquire_weapon()
	var live_layers := _live_layers_of(&"AFF_ATK_UP")
	var agg_after := _agg_of_id(_w1.trait_stack, &"add_atk", &"AFF_ATK_UP")
	_check("⑩a layers 往返保真：存 3 = 落盘回读 3 = 恢复实挂 3，聚合 0.45→0.45",
		ok3 and saved_layers == 3 and disk_layers == 3 and live_layers == 3
		and absf(agg_before - 0.45) < 1e-9 and absf(agg_after - 0.45) < 1e-9,
		"saved=%d disk=%d live=%d agg=%s" % [saved_layers, disk_layers, live_layers,
			str(agg_after)])
	# b. 恢复受注册表 stack_max 钳：快照 99 层 → 读档按基件帽重挂封顶
	#    R196 有意契约变更（原「回读恰 3」）：ADD 池帽 = stack_max+OVERCAP_EXT_MAX = 3+5 = 8
	_reset_stack()
	var dup: TraitData = (_gl.registry.get_trait(&"AFF_ATK_UP") as Resource).duplicate()
	dup.stack_max = 99
	for i in range(99):
		_w1.attach_trait(dup)
	var saved2: Dictionary = _gl.serialize_run()
	var snap_layers := _saved_layers_of(saved2, "AFF_ATK_UP")
	_gl._restore_run_state(saved2)
	_reacquire_weapon()
	var live2 := _live_layers_of(&"AFF_ATK_UP")
	_check("⑩b 恢复受 stack_max 钳：存 99 → 回读恰 8（注册表基件帽 3+超帽延伸 5 生效，不越帽）",
		snap_layers == 99 and live2 == 8, "snap=%d live=%d" % [snap_layers, live2])
	# c. 满层质变 ×1.6：第 4 关门开（MechanicGate idx≥3）→ 挂满 value_mult=1.6；
	#    恢复路径按 game_loop.gd:1422「满层质变在末次挂载自然触发」复现 ×1.6
	_reset_stack()
	Meta.set_run_map(&"world_grove")
	for i in range(3):
		_w1.attach_trait(_gl.registry.get_trait(&"AFF_ATK_UP"))
	var m := _mounted_of(&"AFF_ATK_UP")
	var aggq := _agg_of_id(_w1.trait_stack, &"add_atk", &"AFF_ATK_UP")
	_check("⑩c-预 满层挂载质变 value_mult==1.6（0.15×3×1.6=0.72）",
		m != null and absf(m.value_mult - 1.6) < 1e-12 and absf(aggq - 0.72) < 1e-9,
		"mult=%s agg=%s" % [str(m.value_mult if m != null else -1.0), str(aggq)])
	var saved3: Dictionary = _gl.serialize_run()
	_gl._restore_run_state(saved3)
	_reacquire_weapon()
	var m2 := _mounted_of(&"AFF_ATK_UP")
	var live3 := _live_layers_of(&"AFF_ATK_UP")
	var agg3 := _agg_of_id(_w1.trait_stack, &"add_atk", &"AFF_ATK_UP")
	_check("⑩c 恢复后满层质变再触发：3 层 + value_mult==1.6 + 聚合 0.72",
		live3 == 3 and m2 != null and absf(m2.value_mult - 1.6) < 1e-12
		and absf(agg3 - 0.72) < 1e-9,
		"live=%d mult=%s agg=%s" % [live3,
			str(m2.value_mult if m2 != null else -1.0), str(agg3)])
	# 存档有损项（仲裁裁定：工程纪律冻结存档层 run_save.gd:8-10 口径，专门立项另修——
	# 本套件只注释不落断言，防「有损现状」被 golden 锁死）：
	# · serialize_run 仅存 {id, layers}（game_loop.gd:1300）→ layer_values/逐层品级不入档，
	#   混品级读档降白（白+蓝 → 白×层数）；
	# · 运行期构造卡（FALLBACK_ATK/GAMBLER_CURSE，stack_max=99）不在注册表 → 读档整卡蒸发；
	# · 遗物不入档。
	Meta.set_run_map(MapTable.FIRST_MAP_ID)

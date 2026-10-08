# tests/qa_r226_overflow_cases.gd
# R226 拆帽边界探针用例体（入口 tests/qa_r226_overflow_probe.gd）。
# 纯逻辑面（TraitStack / ModifierStack 静态数学），不进场景——聚焦：
#   A 超大层数 float64 溢出/NaN（decay 收敛路 / 整数线性路 / 层展开 entries 路）
#   B F4 池钳退役：aggregate_add 全额化（pool_caps 传而不用）
#   C 诅咒负贡献：全额线性不衰减（×0.7 退役后无隐性折算）
#   D MULT 取优无限层：data 覆盖 + 层计数，语义与帽时代一致
#   E 满层质变 ×1.6：超里程碑后续层同享乘区（幂等、有限）
#   F 存档恢复数学：restore = N×attach_trait 同构（无帽放行）
extends RefCounted

const BIG_N := 100_000                    # 探针叠层规模（实际局内不可达的「爽叠」上界量级）

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_test_a1_decay_pool_full_amount()
	_test_a2_linear_pool_full_amount()
	_test_a3_decay_sum_static_extremes()
	_test_a4_entries_path_finite()
	_test_b1_f4_pool_clamp_retired()
	_test_c1_curse_full_linear()
	_test_d1_mult_take_best_infinite()
	_test_e1_milestone_mult_all_layers()
	_test_f1_restore_math_no_cap()
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)
	print("验收汇总：%d/%d 通过" % [_pass, _pass + _fail])


func fail_count() -> int:
	return _fail


func _check(p_ok: bool, p_name: String, p_detail: String = "") -> void:
	if p_ok:
		_pass += 1
		print("PASS | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s | %s" % [p_name, p_detail])
		print("FAIL | %s | %s" % [p_name, p_detail])


func _mk_add_trait(p_pid: StringName, p_value: float, p_delta: float) -> TraitData:
	var t := TraitData.new()
	t.id = StringName("QA_R226_%s" % p_pid)
	t.display_name = "QA探针·%s" % p_pid
	t.pool = GameConst.PoolClass.ADD
	t.pool_id = p_pid
	t.effect_id = &"EF_STAT"
	t.value = p_value
	t.decay_delta = p_delta
	t.stack_max = 3
	t.rarity = 0
	return t


func _attach_n(p_stack: TraitStack, p_data: TraitData, p_n: int) -> void:
	for i in range(p_n):
		p_stack.attach(p_data)


func _finite(p_v: float) -> bool:
	return is_finite(p_v) and not is_nan(p_v)


# ── A1：衰减池 10 万层全额（layer_values 展开路） ──
func _test_a1_decay_pool_full_amount() -> void:
	var s := TraitStack.new()
	var t := _mk_add_trait(&"add_atk", 0.12, 0.15)
	var t0 := Time.get_ticks_msec()
	_attach_n(s, t, BIG_N)
	var ms := Time.get_ticks_msec() - t0
	var agg := s.aggregate_panel()
	var got: float = float(agg.get(&"add_atk", -1.0))
	var want: float = 0.12 * float(BIG_N)
	_check(_finite(got) and absf(got - want) < 0.000001,
		"A1 衰减池 %d 层全额（×0.7 退役）" % BIG_N,
		"got=%.6f want=%.6f" % [got, want])
	print("     （attach %d 层耗时 %dms——增长轴参考）" % [BIG_N, ms])


# ── A2：整数池（pierce）大层线性 ──
func _test_a2_linear_pool_full_amount() -> void:
	var s := TraitStack.new()
	var t := _mk_add_trait(&"add_pierce", 1.0, 0.0)
	_attach_n(s, t, BIG_N)
	var got: float = float(s.aggregate_panel().get(&"add_pierce", -1.0))
	_check(_finite(got) and absf(got - float(BIG_N)) < 0.000001,
		"A2 整数池 %d 层线性全额" % BIG_N, "got=%.3f" % got)


# ── A3：decay_sum 静态极端层数（管线同式） ──
func _test_a3_decay_sum_static_extremes() -> void:
	var conv := TraitStack.decay_sum(0.12, 1_000_000_000_000, 0.15)   # δ^n 下溢 → 收敛 0.12/0.85
	var expect_conv := 0.12 / 0.85
	var lin := TraitStack.decay_sum(0.12, 1_000_000_000_000, 1.0)     # δ≥1 退化线性
	_check(_finite(conv) and absf(conv - expect_conv) < 1e-9,
		"A3a decay_sum 1e12 层收敛（δ=0.15）", "got=%.9f want=%.9f" % [conv, expect_conv])
	_check(_finite(lin) and absf(lin - 0.12e12) < 1.0,
		"A3b decay_sum 1e12 层 δ=1 线性有限", "got=%f" % lin)


# ── A4：entries 路（管线真源同构）10 万条全有限 ──
func _test_a4_entries_path_finite() -> void:
	var s := TraitStack.new()
	var t := _mk_add_trait(&"add_atk", 0.12, 0.15)
	_attach_n(s, t, BIG_N)
	var t0 := Time.get_ticks_msec()
	var entries := s.aggregate_add_entries()
	var ms := Time.get_ticks_msec() - t0
	var total := 0.0
	var all_finite := true
	for e in entries:
		var c := float(e.get("contrib", 0.0))
		if not _finite(c):
			all_finite = false
			break
		total += c
	_check(all_finite and entries.size() == BIG_N
		and absf(total - 0.12 * float(BIG_N)) < 0.001,
		"A4 add_entries %d 条全有限且全额" % BIG_N,
		"n=%d total=%.4f" % [entries.size(), total])
	print("     （aggregate_add_entries %d 条耗时 %dms/次——每次 attach 后面板重建付一次）"
		% [BIG_N, ms])


# ── B1：F4 池钳退役——aggregate_add 传 caps 不钳 ──
func _test_b1_f4_pool_clamp_retired() -> void:
	var ms := ModifierStack.new()
	var entries: Array[Dictionary] = []
	for i in range(300):
		entries.append({
			"trait_id": &"QA_R226_atk", "pool_id": &"add_atk", "layer": 1,
			"contrib": 0.5, "decay_delta": 0.0, "is_curse": false,
		})
	var audit := DamageAudit.new()
	ms.audit = audit
	ms.aggregate_add(entries, {&"add_atk": 2.0})
	var got: float = float(ms.add_pool_sum.get(&"add_atk", 0.0))
	_check(absf(got - 150.0) < 1e-9 and audit.clamped_add.is_empty()
		and not audit.clamped_flat,
		"B1 F4 退役：300×0.5=150 超旧钳 2.0 全额放行（audit.clamped_add 恒空）",
		"got=%.4f clamped_add=%s" % [got, str(audit.clamped_add)])


# ── C1：诅咒负贡献全额线性（无衰减无折算） ──
func _test_c1_curse_full_linear() -> void:
	var ms := ModifierStack.new()
	var entries: Array[Dictionary] = []
	for i in range(200):
		entries.append({
			"trait_id": &"QA_R226_curse", "pool_id": &"add_atk", "layer": 1,
			"contrib": -0.05, "decay_delta": 0.15, "is_curse": true,
		})
	entries.append({                       # 正贡献大层（衰减路）混入——总账仍有限
			"trait_id": &"QA_R226_atk", "pool_id": &"add_atk", "layer": 1000,
			"contrib": 0.4, "decay_delta": 0.5, "is_curse": false})
	ms.aggregate_add(entries, {})
	var got: float = float(ms.add_pool_sum.get(&"add_atk", 0.0))
	var want := -0.05 * 200.0 + 0.4 * (1.0 - pow(0.5, 1000.0)) / 0.5
	_check(_finite(got) and absf(got - want) < 1e-6,
		"C1 诅咒 200×(-0.05) 全额线性 + 正贡献衰减路混账有限", "got=%.6f want=%.6f" % [got, want])


# ── D1：MULT 取优无限层（data 覆盖 + 层计数同帽时代） ──
func _test_d1_mult_take_best_infinite() -> void:
	var s := TraitStack.new()
	var low := TraitData.new()
	low.id = &"QA_R226_syn"
	low.pool = GameConst.PoolClass.MULT
	low.pool_id = &"syn_frost_exec"
	low.effect_id = &"EF_STAT"
	low.value = 0.25
	low.cap_pool_p = 2.0
	low.stack_max = 1
	var high := low.duplicate() as TraitData
	high.value = 0.5
	high.rarity = 3
	_attach_n(s, low, 4)
	var ok_mid: bool = s.traits[0].data.value == 0.25 and s.traits[0].layers == 4
	_attach_n(s, high, 3)
	var m := s.traits[0]
	_check(ok_mid and m.layers == 7 and m.data.value == 0.5,
		"D1 MULT 取优：白×4 后金×3 → data=金 0.5、层计 7（无限叠不拒）",
		"layers=%d val=%.2f" % [m.layers, float(m.data.value)])
	# 乘区侧语义不变：单区钳仍生效（0.5 ≤ cap 2.0 → M=1.5）
	var ms := ModifierStack.new()
	ms.aggregate_mults([{"pool_id": &"syn_frost_exec", "source_uid": 0,
		"contrib": 0.5, "cap_pool": 2.0, "priority": 0}], 4, 100.0)
	var mval: float = float(ms.resolved_mults[0]["M"]) if ms.resolved_mults.size() > 0 else 0.0
	_check(absf(mval - 1.5) < 1e-9, "D2 MULT 单区钳 F5 保留（×1.5 不受 R226 影响）",
		"M=%.4f" % mval)


# ── E1：满层质变 ×1.6 全层共享（含里程碑后续层）+ 幂等 ──
func _test_e1_milestone_mult_all_layers() -> void:
	var s := TraitStack.new()
	var t := _mk_add_trait(&"add_atk", 0.10, 0.0)
	_attach_n(s, t, 3)                      # 挂至 stack_max=3 → 里程碑（weapon_base 同构）
	var m := s.traits[0]
	m.value_mult = 1.6
	_attach_n(s, t, 7)                      # 里程碑后再叠 7 层（R226 爽叠轴）
	var got: float = float(s.aggregate_panel().get(&"add_atk", -1.0))
	var want: float = 0.10 * 1.6 * 10.0
	_check(absf(got - want) < 1e-9 and is_equal_approx(m.value_mult, 1.6),
		"E1 质变 ×1.6 全层共享（里程碑后 7 层同乘）",
		"got=%.5f want=%.5f mult=%.2f" % [got, want, m.value_mult])


# ── F1：存档恢复数学（restore = N×attach，无帽放行、层值全额） ──
func _test_f1_restore_math_no_cap() -> void:
	var s := TraitStack.new()
	var t := _mk_add_trait(&"add_hp", 25.0, 0.0)
	_attach_n(s, t, 300)                    # 快照 layers=300 → 恢复逐次 attach 同构
	var m := s.traits[0]
	var got: float = m.stacked_add_total()
	_check(m.layers == 300 and absf(got - 25.0 * 300.0) < 1e-9,
		"F1 存档 300 层恢复无帽全额（add_hp 25×300=7500）",
		"layers=%d total=%.1f" % [m.layers, got])

# tests/runner/elem_smoke_cases.gd
# R192 元素扩容冒烟用例体（由 test_elem_smoke.gd 入口在 autoload 就绪后运行时加载编译）。
# 真源：docs/design/R192_ELEMENT_MATRIX.md §2 七元素定义表 / §3 idContract / §5 底座裁定 /
# §13.1「新增」行。断言全部引用 GameConst 枚举与表（禁自创别名）：
#   · 枚举冒烟：Element.size()==8、序数 0..7、ELEM_IMMUNE_HYD/ANE/GEO/DEN==16/32/64/128
#     （旧三位 2/4/8 与 IMMUNE_FREEZE 等位不变——追加不重排）；ReactionType 演进口径
#     （现役碎裂0/过载1/超导2 字面序锁 + size==reaction_table 行数，禁锁死 20）
#   · λ 四源一致：.tres 反序列化 == .gd 默认（逐位）== 7 项定值
#     [0.35,0.30,0.40,0.35,0.50,0.25,0.30]（裁定⑤：实现组无自由裁量）；GameConfig.balance
#     运行时同值；validator 对 3 项 λ 输入告警（非致命）+ ElementalState 欠长槽兜底 0.35
#   · 附着段：HYD 累积 / HYD 满槽钳制 GAUGE_MAX 不清零不触发（新元素身份分支）/ FIR 满槽
#     清零+点燃（旧三元素逐字节不变）/ HYD+LTG has_both / elem_immune=16 拒附着（系统级）/
#     λ 新槽衰减（gauges[4] 按 λ[3]）
#   · 数据守护探针：仅带旧 3 键 reaction_table 的 BalanceTables 校验 → 仅告警不拒启；
#     进程内删表键 → 报告含键集缺口项（validator 四源键集双射闸——wire 核心守护产出）；
#     card_generator reaction_mult 语义键泛化（2.2 假卡金品质→卡面 ×5.7，VOID 仍 ×4.7）
extends RefCounted

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	_test_enum_smoke()
	_test_lambda_sources()
	_test_validator_lambda_fallback()
	_test_attach_semantics()
	_test_old_table_load_warning()
	_test_validator_keyset_probe()
	_test_reaction_mult_probe()
	_summary()


func fail_count() -> int:
	return _fail


# ── 支撑 ──────────────────────────────────────────────────────────
func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("PASS | %s" % p_name)
	else:
		_fail += 1
		_failures.append(p_name)
		print("FAIL | %s | %s" % [p_name, p_detail])


func _summary() -> void:
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  失败项：%s" % f)


func _approx(p_a: float, p_b: float, p_tol: float = 0.001) -> bool:
	return absf(p_a - p_b) <= p_tol


# ── 1. 枚举冒烟（idContract §3.1 逐字锁） ─────────────────────────
func _test_enum_smoke() -> void:
	print("── 枚举冒烟：Element 全序 + 免疫位 + ReactionType 演进 ──")
	var el: Dictionary = GameConst.Element
	_check("Element.size()==8（KIN 不参反应但占位）", el.size() == 8, "size=%d" % el.size())
	_check("元素序数 0..7（追加不重排：KIN=0 槽恒 0 弃用 · FIR/ICE/LTG 原值不动）",
		int(el.KIN) == 0 and int(el.FIR) == 1 and int(el.ICE) == 2 and int(el.LTG) == 3
		and int(el.HYD) == 4 and int(el.ANE) == 5 and int(el.GEO) == 6 and int(el.DEN) == 7)
	_check("免疫位旧三位不变（FIR=2/ICE=4/LTG=8——bit=1<<Element 通用式）",
		GameConst.ELEM_IMMUNE_FIR == 2 and GameConst.ELEM_IMMUNE_ICE == 4
		and GameConst.ELEM_IMMUNE_LTG == 8)
	_check("免疫位新四位（HYD=16/ANE=32/GEO=64/DEN=128）",
		GameConst.ELEM_IMMUNE_HYD == 16 and GameConst.ELEM_IMMUNE_ANE == 32
		and GameConst.ELEM_IMMUNE_GEO == 64 and GameConst.ELEM_IMMUNE_DEN == 128)
	_check("IMMUNE_FREEZE/CHILL/BURN/SHOCK 位不变（1/2/4/8——状态免疫与元素免疫分账）",
		GameConst.IMMUNE_FREEZE == 1 and GameConst.IMMUNE_CHILL == 2
		and GameConst.IMMUNE_BURN == 4 and GameConst.IMMUNE_SHOCK == 8)
	var rxn_enum: Dictionary = GameConst.ReactionType
	var rt: Dictionary = GameConfig.balance.reaction_table
	_check("ReactionType 演进口径：现役 0/1/2 字面序锁（追加保序）+ size==reaction_table 行数",
		int(rxn_enum.RXN_FIR_ICE) == 0 and int(rxn_enum.RXN_FIR_LTG) == 1
		and int(rxn_enum.RXN_ICE_LTG) == 2 and rxn_enum.size() == rt.size(),
		"enum=%d table=%d" % [rxn_enum.size(), rt.size()])


# ── 2. λ 四源一致（§5.2 同批纪律的套件侧守望） ────────────────────
func _test_lambda_sources() -> void:
	print("── λ 四源：.tres == .gd 默认 == 7 项定值 == 运行时 ──")
	var want: Array[float] = [0.35, 0.30, 0.40, 0.35, 0.50, 0.25, 0.30]
	var bt_gd: BalanceTables = BalanceTables.new()              # .gd 默认
	var bt_tres: BalanceTables = load("res://data/balance/balance_tables.tres")  # 运行时真源
	var ok_gd: bool = bt_gd.element_decay_lambda.size() == 7
	var ok_tres: bool = bt_tres.element_decay_lambda.size() == 7
	for i in range(7):
		ok_gd = ok_gd and _approx(bt_gd.element_decay_lambda[i], want[i], 0.0001)
		ok_tres = ok_tres and _approx(bt_tres.element_decay_lambda[i], want[i], 0.0001)
	_check("λ .gd 默认 恰 7 项且逐位 == 定值 [0.35,0.30,0.40,0.35,0.50,0.25,0.30]", ok_gd,
		str(bt_gd.element_decay_lambda))
	_check("λ .tres 反序列化 恰 7 项且逐位 == .gd 默认（双源一致）",
		ok_tres and bt_tres.element_decay_lambda.size() == bt_gd.element_decay_lambda.size(),
		str(bt_tres.element_decay_lambda))
	var rt_lam: Array = GameConfig.balance.element_decay_lambda
	var ok_rt: bool = rt_lam.size() == 7
	for j in range(mini(rt_lam.size(), 7)):
		ok_rt = ok_rt and _approx(float(rt_lam[j]), want[j], 0.0001)
	_check("λ GameConfig.balance（运行时）恰 7 项同值", ok_rt, str(rt_lam))


# ── 3. validator λ 闸 + 欠长兜底衰减 ─────────────────────────────
func _test_validator_lambda_fallback() -> void:
	print("── validator：3 项 λ 输入告警（非致命）+ 欠长槽兜底 0.35 ──")
	var bt3 := BalanceTables.new()
	bt3.element_decay_lambda = [0.35, 0.30, 0.40]               # 旧 3 项输入
	var rep: Array = DataValidator.new().validate_balance(bt3)
	var hit := {}
	for issue in rep:
		if String(issue.get("field", "")).contains("element_decay_lambda"):
			hit = issue
	_check("validator：3 项 λ 输入 → 报告含 element_decay_lambda 项（恰 7 口径）",
		not hit.is_empty(), "rep=%d 项" % rep.size())
	_check("validator：λ 缺项为非致命（fatal==false 字段级回退不拒启——_nf 报告通道）",
		not hit.is_empty() and not bool(hit.get("fatal", true)),
		str(hit))
	# 欠长静默兜底：3 项 λ 输入下 HYD 槽（i=4）取兜底 0.35 衰减（:63-67 槽 i−1 直索引守卫）
	var st := ElementalState.new()
	st.gauges[GameConst.Element.HYD] = 60.0
	st.gauges[GameConst.Element.LTG] = 60.0
	st.tick(1.0, [0.35, 0.30, 0.40])
	_check("欠长兜底：HYD 槽按兜底 0.35 衰减（60→39）",
		_approx(st.gauges[GameConst.Element.HYD], 39.0, 0.01),
		str(st.gauges[GameConst.Element.HYD]))
	_check("欠长兜底：LTG 槽按 λ[2]=0.40 正常衰减（60→36）",
		_approx(st.gauges[GameConst.Element.LTG], 36.0, 0.01))


# ── 4. 附着段（M2 满槽语义裁定④：新元素钳制 · 旧三元素逐字节不变） ──
func _test_attach_semantics() -> void:
	print("── 附着段：HYD 累积 / 满槽钳制 / FIR 旧语义 / has_both / 免疫16 / λ 新槽 ──")
	# HYD 累积（附着通道对新元素零改动继承）
	var st := ElementalState.new()
	st.apply(GameConst.Element.HYD, 60.0)
	_check("附着：apply(HYD,60) → gauges[4]==60（新元素累积）",
		_approx(st.gauges[GameConst.Element.HYD], 60.0, 0.001))
	# HYD 满槽钳制：不清零不触发（分支按元素身份 p_element>=HYD，非 TRIGGER_NONE 返回码）
	var code_clamp: int = st.apply(GameConst.Element.HYD, 60.0)
	_check("满槽钳制：HYD 累计满槽 → gauges[4]==GAUGE_MAX 钳制不清零",
		_approx(st.gauges[GameConst.Element.HYD], ElementalState.GAUGE_MAX, 0.001))
	_check("满槽钳制：HYD 满槽返回 TRIGGER_NONE（无 _trigger 臂——燃料存续）",
		code_clamp == ElementalState.TRIGGER_NONE and st.burn_layers == 0
		and st.freeze_timer == 0.0 and st.shock_chain_cd == 0.0)
	# FIR 满槽旧语义逐字节不变：清零 → _trigger 点燃
	var st_fir := ElementalState.new()
	var code_fir: int = st_fir.apply(GameConst.Element.FIR, 100.0)
	_check("FIR 满槽旧语义不变：gauges[1]==0 且 burn_layers==1（TRIGGER_BURN）",
		code_fir == ElementalState.TRIGGER_BURN
			and _approx(st_fir.gauges[GameConst.Element.FIR], 0.0, 0.001)
			and st_fir.burn_layers == 1)
	# HYD+LTG 双附着 has_both（反应条件谓词通用 int）
	var st2 := ElementalState.new()
	st2.apply(GameConst.Element.HYD, 30.0)
	st2.apply(GameConst.Element.LTG, 30.0)
	_check("双附着：HYD+LTG has_both == true", st2.has_both(GameConst.Element.HYD,
		GameConst.Element.LTG))
	# λ 新槽衰减：gauges[4] 按 λ[3]=0.35（裁定⑤ HYD=0.35）
	var st3 := ElementalState.new()
	st3.gauges[GameConst.Element.HYD] = 60.0
	st3.tick(1.0, [0.35, 0.30, 0.40, 0.35, 0.50, 0.25, 0.30])
	_check("λ 新槽衰减：gauges[4] 按 λ[3]=0.35（60→39）",
		_approx(st3.gauges[GameConst.Element.HYD], 39.0, 0.01),
		str(st3.gauges[GameConst.Element.HYD]))
	# elem_immune=16 拒附着（系统级：is_elem_immune 通用式 elem_immune & (1<<p_element)）
	var sys = load("res://scripts/combat/elemental/elemental_system.gd").new()
	tree.get_root().add_child(sys)
	sys.pipeline = KeysetSpyPipeline.new()
	var enemy = load("res://scripts/entities/enemy/enemy.gd").new()
	enemy.uid = 7001
	enemy.set("elem_immune", GameConst.ELEM_IMMUNE_HYD)         # 水免疫（16）
	tree.get_root().add_child(enemy)
	sys.register_host(enemy)
	sys.apply_attach(enemy, GameConst.Element.HYD, 50.0)
	var st_e: ElementalState = enemy.get("elemental")
	_check("免疫：elem_immune=16 拒 HYD 附着（gauges[4] 恒 0）",
		st_e != null and _approx(st_e.gauges[GameConst.Element.HYD], 0.0, 0.001))
	enemy.queue_free()
	sys.queue_free()


class KeysetSpyPipeline extends RefCounted:
	# 结算桩（rxn_codex 同款）：附着段用不到反应结算，桩防空
	var calls: Array = []
	func resolve_reaction(p_ctx) -> RefCounted:
		calls.append([int(p_ctx.element), float(p_ctx.base_atk)])
		return null


# ── 5. 旧 3 键 reaction_table 加载 → 仅告警不拒启 ─────────────────
func _test_old_table_load_warning() -> void:
	print("── 旧表兼容：仅 3 键 reaction_table → 告警不拒启 ──")
	var bt_old := BalanceTables.new()
	bt_old.reaction_table = {
		"RXN_FIR_ICE": {"coef": 2.0},
		"RXN_FIR_LTG": {"coef": 1.2, "radius": 90.0},
		"RXN_ICE_LTG": {"resist_delta": -0.3, "duration": 6.0},
	}
	var rep: Array = DataValidator.new().validate_balance(bt_old)
	var keyset_hit := {}
	var fatal_count := 0
	for issue in rep:
		if String(issue.get("field", "")).contains("reaction_table"):
			keyset_hit = issue
		if bool(issue.get("fatal", false)):
			fatal_count += 1
	_check("旧 3 键表：报告含 reaction_table 键集缺口项（enum==table 双射闸报红）",
		not keyset_hit.is_empty(), "rep=%d 项" % rep.size())
	_check("旧 3 键表：缺口项非致命（fatal==false）→ 仅告警不拒启",
		not keyset_hit.is_empty() and not bool(keyset_hit.get("fatal", true)),
		str(keyset_hit))
	_check("旧 3 键表：全报告零 fatal 项（DataRegistry 不剔除不拒启）", fatal_count == 0,
		"fatal=%d" % fatal_count)


# ── 6. validator 键集探针（进程内删表键 → 报告含缺口项） ──────────
func _test_validator_keyset_probe() -> void:
	print("── 守护探针：进程内删 reaction_table 一键 → validator 报红 ──")
	var bt: BalanceTables = GameConfig.balance.duplicate()       # 不污染运行时单例
	var victim: String = ""
	for k in bt.reaction_table:
		victim = String(k)
		break                                     # 删首键（任意键同罪——双射闸无白名单）
	var dropped: int = bt.reaction_table.size()
	bt.reaction_table.erase(victim)
	var rep: Array = DataValidator.new().validate_balance(bt)
	var hit := {}
	for issue in rep:
		if String(issue.get("field", "")).contains("reaction_table"):
			hit = issue
	_check("删表键（%s）→ 报告含 reaction_table 键集缺口项（半接线不可静默）" % victim,
		bt.reaction_table.size() == dropped - 1 and not hit.is_empty(),
		"rep=%d 项" % rep.size())
	_check("删表键缺口走非致命报告通道（fatal==false 启动期报红不崩溃）",
		not hit.is_empty() and not bool(hit.get("fatal", true)))


# ── 7. card_generator reaction_mult 泛化探针（wire T5 守护） ──────
func _test_reaction_mult_probe() -> void:
	print("── 泛化探针：reaction_mult 语义键（2.2 假卡 ×5.7 · VOID 仍 ×4.7） ──")
	var gen = load("res://scripts/cards/card_generator.gd").new()
	var fake := TraitData.new()
	fake.id = &"TEST_RXN_FAKE"                   # 非 VOID id——证分支按语义键非按 id
	fake.value = 2.2
	fake.description = "全部混合反应的结算值 ×2.2（常驻）"
	fake.params = {"reaction_mult": 2.2}
	var face: String = gen._rarity_desc_mech(fake, 2.6, 3)      # 金品质 scale=2.6
	_check("reaction_mult 假卡：金品质卡面 ×5.7（2.2×2.6=5.72→%.1f 口径）" % 5.72,
		face.contains("×5.7") and not face.contains("×2.2"), "face=%s" % face)
	var void_card: TraitData = load("res://resources/traits/ELE_REACTION_VOID.tres")
	var void_face: String = gen._rarity_desc_mech(void_card, 2.6, 3)
	_check("VOID 金卡逐字节不变：×4.7（1.8×2.6=4.68→×4.7——verify_feedback 同口径锁）",
		void_card != null and void_face.contains("×4.7") and not void_face.contains("×1.8"),
		"face=%s" % void_face)

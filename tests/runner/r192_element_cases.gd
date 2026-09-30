# tests/runner/r192_element_cases.gd
# R192 七元素反应大矩阵验收用例体（由 test_r192_element.gd 入口加载；SceneTree 模式仿 test_history.gd）。
# 真源：docs/design/R192_ELEMENT_MATRIX.md §2 七元素定义表 / §3 idContract（唯一真源）/
# §4 反应实现规格 / §15 验收命令。断言分组（六项验收标准）：
#   ① reaction_table 键集合 == idContract §3.3 全表（C(7,2)=21 配对逐键对：20 键逐行
#      键/数值/配对元素/中文名/优先级 + 冰+草留白无键；id 低枚举序在前；扩散族转移语义）
#   ② 七元素枚举在位（KIN..DEN 序数 0..7 追加不重排）+ element_decay_lambda 恰 7 项
#      + PopPalette.ELEMENT_COLORS 每元素色表键在位 + 四张新元素卡 §3.2 字段 + 解锁关
#   ③ 端到端：同一把真武器挂两种新元素卡 → 实弹附着 → 触发对应反应——
#      绽放 RXN_HYD_DEN（非族新反应）+ 扩散·水 RXN_HYD_ANE（族模板反应）+ 扩散·草行为探针
#   ④ 图鉴「反应」页行数 == reaction_table 行数（动态断言，禁硬编码）+ 留白标注行恰 1
#   ⑤ 反应跳字文本含中文反应名与数字（dmg 型 蒸发150→合并184；stat 型 超导-30% /
#      结晶·火-15% / 冻结1.2s——全部读真源表格式化）
#   ⑥ 旧 3 反应行为回归（碎裂 2.0×点燃剩余 DOT 池引爆 / 过载 1.2×快照主目标+AoE /
#      超导 −0.3 全抗 6s）
extends RefCounted

const BALLISTIC_SCENE := "res://scenes/combat/projectiles/ballistic_projectile.tscn"
const ENEMY_SCENE := "res://scenes/combat/enemies/enemy.tscn"
const MAIN_SCENE := "res://scenes/main.tscn"
const DT := 1.0 / 120.0

# idContract §3.3 反应 21 配对全表（20 键 + 冰+草留白；逐字抄录设计文档，禁自创别名）：
# [id, 元素A(低枚举序在前), 元素B, reaction_table 数值键, 中文名, 转移元素(仅族模板·扩散)]
const CONTRACT_RXNS: Array = [
	["RXN_FIR_ICE", "FIR", "ICE", {"coef": 2.0}, "碎裂", ""],
	["RXN_FIR_HYD", "FIR", "HYD", {"coef": 1.5}, "蒸发", ""],
	["RXN_HYD_DEN", "HYD", "DEN", {"coef": 1.5, "radius": 120.0, "delay": 0.75}, "绽放", ""],   # R198 契约变更：绽放 delay 1.5→0.75（R192-low6 双源同批调参）
	["RXN_FIR_LTG", "FIR", "LTG", {"coef": 1.2, "radius": 90.0}, "过载", ""],
	["RXN_FIR_ANE", "FIR", "ANE", {"coef": 0.8, "radius": 120.0, "targets": 3.0}, "扩散·火", "FIR"],
	["RXN_ICE_ANE", "ICE", "ANE", {"coef": 0.8, "radius": 120.0, "targets": 3.0}, "扩散·冰", "ICE"],
	["RXN_LTG_ANE", "LTG", "ANE", {"coef": 0.8, "radius": 120.0, "targets": 3.0}, "扩散·雷", "LTG"],
	["RXN_HYD_ANE", "HYD", "ANE", {"coef": 0.8, "radius": 120.0, "targets": 3.0}, "扩散·水", "HYD"],
	["RXN_ANE_DEN", "ANE", "DEN", {"coef": 0.8, "radius": 120.0, "targets": 3.0}, "扩散·草", "DEN"],
	["RXN_ICE_HYD", "ICE", "HYD", {"freeze_dur": 1.2, "chill_dur": 2.5, "vuln_mult": 1.25, "vuln_dur": 3.0}, "冻结", ""],
	["RXN_LTG_HYD", "LTG", "HYD", {}, "感电", ""],
	["RXN_FIR_DEN", "FIR", "DEN", {"burn_layers_max": 5.0, "burn_dur": 3.0}, "燃烧", ""],
	["RXN_LTG_DEN", "LTG", "DEN", {"vuln_mult": 1.25, "vuln_dur": 3.0}, "激化", ""],
	["RXN_ICE_LTG", "ICE", "LTG", {"resist_delta": -0.3, "duration": 6.0}, "超导", ""],
	# 结晶族 id 逐字照抄 §3.3 id 列（低序在前；唯 RXN_DEN_GEO 设计原文即高序在前——
	# DEN(7)>GEO(6)，id 以 §3.3 表为唯一真源逐字遵守，实现 game_const.gd 同字面）
	["RXN_FIR_GEO", "FIR", "GEO", {"dr": 0.15, "dr_dur": 6.0}, "结晶·火", ""],
	["RXN_ICE_GEO", "ICE", "GEO", {"dr": 0.15, "dr_dur": 6.0}, "结晶·冰", ""],
	["RXN_LTG_GEO", "LTG", "GEO", {"dr": 0.15, "dr_dur": 6.0}, "结晶·雷", ""],
	["RXN_HYD_GEO", "HYD", "GEO", {"dr": 0.15, "dr_dur": 6.0}, "结晶·水", ""],
	["RXN_DEN_GEO", "DEN", "GEO", {"dr": 0.15, "dr_dur": 6.0}, "结晶·草", ""],
	["RXN_ANE_GEO", "ANE", "GEO", {"dr": 0.15, "dr_dur": 6.0}, "结晶·风", ""],
]

# 四张新元素卡（idContract §3.2：id 全局唯一 / pool=4 / value=22 / element=4..7）
const NEW_ELEM_CARDS: Array = [
	["ELE_HYDRO", 4], ["ELE_ANEMO", 5], ["ELE_GEO", 6], ["ELE_DENDRO", 7],
]

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []

var _proj_pool: ProjectilePool
var _enemy_pool: EnemyPool
var _grid: SpaceGrid
var _pipeline: DamagePipelineStub
var _real_pipeline: DamagePipeline          # 真件（ElementalSystem 反应结算通道）
var _sys: ElementalSystem
var _alive_enemies: Array[Node2D] = []


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(20260928)                             # 全局 RNG 固定种子（实弹元素抽取确定性）
	_ensure_autoloads()
	_test_reaction_contract()                  # ① idContract 全表逐键对
	_test_element_matrix()                     # ② 七元素枚举/λ/色表/新卡/解锁关
	_setup_world()
	_test_e2e_bloom()                          # ③a 同武器双新卡 → 绽放（非族新反应）
	_test_e2e_spread()                         # ③b 同武器双新卡 → 扩散·水（族模板反应）
	_test_spread_dendro_probe()                # ③c 扩散·草转移元素行为探针（真件系统级）
	_test_legacy_three()                       # ⑥ 旧 3 反应行为回归
	_teardown_world()
	_test_codex_and_popup()                    # ④⑤ 图鉴动态行数 + 跳字文本（GameLoop 真件）
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
		_failures.append("%s %s" % [p_name, p_detail])
		print("FAIL | %s | %s" % [p_name, p_detail])


func _summary() -> void:
	print("────────────────────────────────────────")
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)
	print("验收汇总：%d/%d 通过" % [_pass, _pass + _fail])


func _approx(p_a: float, p_b: float, p_tol: float = 0.001) -> bool:
	return absf(p_a - p_b) <= p_tol


func _bump_frame() -> void:
	GameConfig.frame_stamp += 1                # E-03 帧闸门推进（GameLoop 帧序的测试侧替身）


func _ensure_autoloads() -> void:
	if tree.get_root().get_node_or_null("EventBus") == null:
		_install_autoload("EventBus", "res://autoload/event_bus.gd")
	if tree.get_root().get_node_or_null("GameConfig") == null:
		_install_autoload("GameConfig", "res://autoload/game_config.gd")
	if tree.get_root().get_node_or_null("DebugStats") == null:
		_install_autoload("DebugStats", "res://autoload/debug_stats.gd")


func _install_autoload(p_name: String, p_path: String) -> void:
	var script: GDScript = load(p_path)
	var node: Node = script.new()
	node.name = p_name
	tree.get_root().add_child(node)


func _ele(p_id: StringName) -> TraitData:
	return load("res://resources/traits/%s.tres" % String(p_id)) as TraitData


func _elem_of(p_name: String) -> int:
	# 元素枚举名 → 序数（idContract 逐字引用；坏名返回 -1 由断言暴露）
	var v: Variant = GameConst.Element.get(p_name)
	return int(v) if v != null else -1


func _pair_sorted(p_a: int, p_b: int) -> Array:
	return [mini(p_a, p_b), maxi(p_a, p_b)]


func _rxn_id_of(p_pair: Array) -> String:
	# 枚举序 int → 成员名（id 即表键，idContract 低枚举序在前惯例的运行时反查）
	for key in GameConst.ReactionType:
		if int(GameConst.ReactionType[key]) == int(p_pair[0]):
			return String(key)
	return ""


# ── ① reaction_table 键集合 == idContract §3.3 全表（21 配对逐键对） ──
func _test_reaction_contract() -> void:
	print("── ① idContract 全表：21 配对逐键对（20 键 + 冰草留白） ──")
	var rt: Dictionary = GameConfig.balance.reaction_table
	var rxn_enum: Dictionary = GameConst.ReactionType
	# 逐键对：键在位 + 数值逐键等值 + 配对元素集合 + 中文名单源 + id 低枚举序在前
	for row in CONTRACT_RXNS:
		var rid: String = row[0]
		var ea: int = _elem_of(row[1])
		var eb: int = _elem_of(row[2])
		var want: Dictionary = row[3]
		var cname: String = row[4]
		var rule_v: Variant = rt.get(rid, null)
		var rule_ok := rule_v is Dictionary
		if rule_ok:
			var rule: Dictionary = rule_v
			rule_ok = rule.size() == want.size()
			for k in want:
				rule_ok = rule_ok and rule.has(k) \
					and _approx(float(rule[k]), float(want[k]), 0.0001)
		var rxn_id: int = int(rxn_enum.get(rid, -1))
		var pair_v: Variant = ElementalSystem.RXN_PAIRS.get(rxn_id, null)
		var pair_ok := pair_v is Array and (pair_v as Array).size() == 2 \
			and _pair_sorted(int((pair_v as Array)[0]), int((pair_v as Array)[1])) \
				== _pair_sorted(ea, eb)
		var name_ok := String(GameConst.REACTION_NAMES.get(rxn_id, "")) == cname
		# id 低序在前惯例（RXN_DEN_GEO 为设计 §3.3 行 19 原文自身的例外——表为真源）
		var convention_ok := ea < eb or rid == "RXN_DEN_GEO"
		_check("① %s：表键在位 + 数值 %s + 配对(%s,%s) + 中文名「%s」单源"
			% [rid, str(want), row[1], row[2], cname],
			rt.has(rid) and rule_ok and pair_ok and name_ok and convention_ok,
			"rule=%s pair=%s name=%s" % [str(rule_v), str(pair_v),
				str(GameConst.REACTION_NAMES.get(rxn_id, "<缺>"))])
	# 族模板·扩散转移语义（§3.3「转移X」列；结算核 _spread_attach 消费 pair[0]）
	for row in CONTRACT_RXNS:
		var tname: String = row[5]
		if tname.is_empty():
			continue
		var rid2: String = row[0]
		var want_elem: int = _elem_of(tname)
		var pair2: Array = ElementalSystem.RXN_PAIRS[int(GameConst.ReactionType[rid2])]
		_check("① %s：扩散族转移元素 == 被扩元素 %s（§3.3 同模板列）" % [rid2, tname],
			int(pair2[0]) == want_elem, "pair=%s" % str(pair2))
	# 21 配对闭包（动态推导）：C(7,2)=21 对中 RXN_PAIRS 恰 20 键全覆盖、无同配对双键，
	# 唯一未覆盖配对 == 冰+草留白（禁自创别名/禁第三留白）
	var covered := {}
	var dup_pairs: int = 0
	for rxn_id in ElementalSystem.RXN_PAIRS:
		var p: Array = ElementalSystem.RXN_PAIRS[rxn_id]
		var ckey := "%d-%d" % [mini(int(p[0]), int(p[1])), maxi(int(p[0]), int(p[1]))]
		if covered.has(ckey):
			dup_pairs += 1
		covered[ckey] = true
	var name_by_ord := {}
	for ename in GameConst.Element:
		name_by_ord[int(GameConst.Element[ename])] = String(ename)
	var uncovered: Array = []
	for i in range(1, GameConst.Element.size()):
		for j in range(i + 1, GameConst.Element.size()):
			if not covered.has("%d-%d" % [i, j]):
				uncovered.append("%s+%s" % [name_by_ord[i], name_by_ord[j]])
	_check("① 21 配对闭包：C(7,2)=21 对中表键恰 20 键全覆盖 · 无同配对双键 · 唯一留白=冰+草",
		covered.size() == 20 and dup_pairs == 0 and uncovered == ["ICE+DEN"], str(uncovered))
	# id 形状守护：全部表键 id 形如 RXN_<元素名>_<元素名> 且编码配对 == RXN_PAIRS 配对（无别名）
	var shape_ok := true
	var shape_bad := ""
	for k in rt:
		var parts := String(k).trim_prefix("RXN_").split("_")
		var ok2 := parts.size() == 2
		if ok2:
			var ea_v: Variant = GameConst.Element.get(String(parts[0]))
			var eb_v: Variant = GameConst.Element.get(String(parts[1]))
			ok2 = ea_v != null and eb_v != null
			if ok2:
				var pair3: Array = ElementalSystem.RXN_PAIRS[int(GameConst.ReactionType[String(k)])]
				ok2 = _pair_sorted(int(ea_v), int(eb_v)) \
					== _pair_sorted(int(pair3[0]), int(pair3[1]))
		if not ok2:
			shape_ok = false
			shape_bad = String(k)
	_check("① 全部表键 id 形如 RXN_<元素>_<元素> 且编码配对 == RXN_PAIRS（无自创别名）",
		shape_ok, shape_bad)
	# id 低序在前惯例：恰 RXN_DEN_GEO 一键高序在前（设计 §3.3 行 19 原文即如此——表为真源）
	var high_first: Array = []
	for row in CONTRACT_RXNS:
		if _elem_of(row[1]) >= _elem_of(row[2]):
			high_first.append(row[0])
	_check("① id 低枚举序在前：恰 RXN_DEN_GEO 一键高序在前（设计 §3.3 行 19 原文例外）",
		high_first == ["RXN_DEN_GEO"], str(high_first))
	_check("① reaction_table 行数 == ReactionType 枚举行数 == 契约 20 键（键集双射）",
		rt.size() == rxn_enum.size() and rt.size() == CONTRACT_RXNS.size(),
		"table=%d enum=%d" % [rt.size(), rxn_enum.size()])
	# 优先级列：RXN_ORDER == 契约行序 1..20（碎裂>过载>超导 头部相对位在内）
	var order_ok: bool = ElementalSystem.RXN_ORDER.size() == rxn_enum.size()
	for i in range(mini(ElementalSystem.RXN_ORDER.size(), CONTRACT_RXNS.size())):
		order_ok = order_ok and int(ElementalSystem.RXN_ORDER[i]) \
			== int(rxn_enum[CONTRACT_RXNS[i][0]])
	_check("① RXN_ORDER == idContract 优先级 1..20（碎裂>过载>超导 头部相对位保持）",
		order_ok, str(ElementalSystem.RXN_ORDER))


# ── ② 七元素枚举在位 + λ 恰 7 + 色表键在位 + 新卡字段 + 解锁关 ─────
func _test_element_matrix() -> void:
	print("── ② 七元素矩阵：枚举/λ/色表/新卡/解锁关 ──")
	var el: Dictionary = GameConst.Element
	_check("② Element.size()==8 且七元素枚举在位（序数 0..7 追加不重排）",
		el.size() == 8 and _elem_of("KIN") == 0 and _elem_of("FIR") == 1
		and _elem_of("ICE") == 2 and _elem_of("LTG") == 3 and _elem_of("HYD") == 4
		and _elem_of("ANE") == 5 and _elem_of("GEO") == 6 and _elem_of("DEN") == 7,
		str(el))
	# λ 衰减数组：恰 7 项（ask 口径）+ 逐位 == 裁定⑤定值（运行时/默认/兜底三源）
	var want_lambda: Array[float] = [0.35, 0.30, 0.40, 0.35, 0.50, 0.25, 0.30]
	var lam_rt: Array = GameConfig.balance.element_decay_lambda
	var lam_gd: Array = BalanceTables.new().element_decay_lambda
	var lam_fb: Array = ElementalSystem.LAMBDA_FALLBACK
	var lam_ok := lam_rt.size() == 7 and lam_gd.size() == 7 and lam_fb.size() == 7
	for i in range(7):
		lam_ok = lam_ok and _approx(float(lam_rt[i]), want_lambda[i], 0.0001) \
			and _approx(float(lam_gd[i]), want_lambda[i], 0.0001) \
			and _approx(float(lam_fb[i]), want_lambda[i], 0.0001)
	_check("② element_decay_lambda 恰 7 项（运行时 == .gd 默认 == 兜底 == 裁定⑤定值）",
		lam_ok, "rt=%s gd=%s fb=%s" % [str(lam_rt), str(lam_gd), str(lam_fb)])
	# 色表：每元素色表键在位（0..7 全键）+ 新四元素色值 == §2 定义表
	var colors: Dictionary = PopPalette.ELEMENT_COLORS
	var keys_ok := colors.size() == 8
	for e in range(8):
		keys_ok = keys_ok and colors.has(e)
	_check("② PopPalette.ELEMENT_COLORS 每元素色表键在位（0..7 恰 8 键）", keys_ok, str(colors.keys()))
	_check("② 新四元素色值 == §2 定义表（HYD #4cc2f1 / ANE #74c2a8 / GEO #fab632 / DEN #a5c83b）",
		colors[4] == Color("4cc2f1") and colors[5] == Color("74c2a8")
		and colors[6] == Color("fab632") and colors[7] == Color("a5c83b"))
	_check("② 旧四色不漂移（KIN 白 / FIR #ef7938 / ICE #9fd6e3 / LTG 改色 #af8ec1）",
		colors[0] == Color(1.0, 1.0, 1.0) and colors[1] == Color("ef7938")
		and colors[2] == Color("9fd6e3") and colors[3] == Color("af8ec1"))
	# 四张新元素卡：§3.2 字段 + id 全局唯一（无别名第二卡）
	var registry := DataRegistry.new()
	registry.load_all("res://data/manifest.cfg")   # 生产同路径（含 DataValidator 全量校验）
	for card in NEW_ELEM_CARDS:
		var cid: String = card[0]
		var t := registry.get_trait(StringName(cid))
		var ok := t != null
		if ok:
			ok = int(t.params.get("element", -1)) == int(card[1]) \
				and int(t.pool) == GameConst.PoolClass.ELEM \
				and String(t.effect_id) == &"EF_ELEMENTAL" \
				and _approx(float(t.value), 22.0, 0.0001) \
				and (t.params.get("required_forms", []) as Array) == [0, 1, 2] \
				and int(t.stack_max) == 2 and int(t.rarity) == 1
		_check("② 新卡 %s：在册 + element=%s + ELEM 池/EF_ELEMENTAL/value=22/三形态/2 层/稀有度 1"
			% [cid, str(card[1])], ok,
			str(t.params if t != null else "<缺卡>"))
	var alias_ok := true
	var alias_detail := ""
	for tid in registry.traits:
		var td: TraitData = registry.get_trait(tid)
		if td == null or int(td.pool) != GameConst.PoolClass.ELEM:
			continue
		var e: int = int(td.params.get("element", -1))
		if e >= GameConst.Element.HYD:
			var known := false
			for card in NEW_ELEM_CARDS:
				known = known or String(td.id) == String(card[0])
			if not known:
				alias_ok = false
				alias_detail = String(td.id)
	_check("② ELEM 池 element∈4..7 的卡恰四张新 id（无自创别名/重复注册）", alias_ok, alias_detail)
	# 解锁关（§3.3 解锁关列）：水@第 4 关（idx≥3）/ 风岩草@第 5 关（idx≥4）
	var gate_ok := true
	for card in NEW_ELEM_CARDS:
		var t2 := registry.get_trait(StringName(card[0]))
		Meta.set_run_map(MapTable.MAPS[2].id)   # 第 3 关：新四元素全不上架
		var at3 := MechanicGate.trait_allowed(t2)
		Meta.set_run_map(MapTable.MAPS[3].id)   # 第 4 关：仅水
		var at4 := MechanicGate.trait_allowed(t2)
		Meta.set_run_map(MapTable.MAPS[4].id)   # 第 5 关：全开
		var at5 := MechanicGate.trait_allowed(t2)
		var want4: bool = int(card[1]) == GameConst.Element.HYD
		gate_ok = gate_ok and not at3 and at4 == want4 and at5
	Meta.set_run_map(&"")                       # 还原无局口径（防跨套件污染）
	_check("② 解锁关：第 3 关全拒 · 第 4 关仅水 · 第 5 关风/岩/草全开 · 无局全开", gate_ok)


# ── 世界夹具（rxn_channel 范式：透传桩弹道 + 真件管线元素结算） ─────
func _setup_world() -> void:
	_proj_pool = ProjectilePool.new()
	_proj_pool.name = "R192ProjPool"
	tree.get_root().add_child(_proj_pool)
	_proj_pool.setup(&"r192_test", load(BALLISTIC_SCENE), 64)
	var ep := EnemyPool.new()
	ep.name = "R192EnemyPool"
	tree.get_root().add_child(ep)
	ep.setup(&"r192_enemy", load(ENEMY_SCENE), 16)
	_enemy_pool = ep
	_grid = SpaceGrid.new()
	_grid.configure(Vector2(720, 1280), 192.0)
	_pipeline = DamagePipelineStub.new()
	_real_pipeline = DamagePipeline.new()      # 真件：反应结算内部落血（9b）
	_real_pipeline.set_rng_seed(42)
	_sys = ElementalSystem.new()
	_sys.name = "R192ElementalSystem"
	tree.get_root().add_child(_sys)
	_sys.pipeline = _real_pipeline
	_sys.enemy_grid = _grid
	_alive_enemies.clear()


func _teardown_world() -> void:
	_alive_enemies.clear()
	if _sys != null:
		_sys.free()
		_sys = null
	_real_pipeline = null
	if _proj_pool != null:
		_proj_pool.free()
		_proj_pool = null
	if _enemy_pool != null:
		_enemy_pool.free()
		_enemy_pool = null
	_grid = null
	_pipeline = null


func _make_enemy_data(p_id: String, p_hp: float = 1000.0) -> EnemyData:
	var d := EnemyData.new()
	d.id = StringName(p_id)
	d.display_name = p_id
	d.hp_base = p_hp
	d.spd_base = 0.0                           # 静止敌（几何确定性）
	d.dmg_base = 8.0
	d.exp_base = 3.0
	d.tp_cost = 1.0
	d.hitbox_r = 14.0
	return d


func _spawn_enemy(p_data: EnemyData, p_pos: Vector2) -> Enemy:
	var e := _enemy_pool.acquire() as Enemy
	e.spawn(p_data, 1, 0)
	e.position = p_pos
	_alive_enemies.append(e)
	_grid.rebuild(_alive_enemies)
	return e


func _retire_enemy(p_enemy: Enemy) -> void:
	# 簇清场：注销状态宿主 + 移出网格（防陈旧敌被后续簇的实弹/AoE 误命中——
	# 网格里的死位影敌会吞掉命中却无状态容器，附着静默丢失）
	_sys.unregister_host(p_enemy)
	_alive_enemies.erase(p_enemy)
	_grid.rebuild(_alive_enemies)


func _make_weapon(p_pos: Vector2) -> BallisticWeapon:
	# 真件弹道武器（面板 100 / 散射 0 / 弹速 600——实弹附着通道与生产同链路）
	var d := WeaponData.new()
	d.id = &"W_R192_PROBE"
	d.display_name = "R192 端到端探针"
	d.form = GameConst.WeaponForm.BALLISTIC
	d.crit_rate = 0.0
	d.crit_dmg = 2.0
	d.hitbox_r = 6.0
	for i in range(5):
		var ls := WeaponLevelStats.new()
		ls.base_atk = 100.0
		ls.rof = 5.0
		ls.cd = 0.5
		ls.pierce = 1
		ls.pellets = 1
		d.upgrade_table.append(ls)
	d.ballistic = {"proj_speed": 600.0, "range": 600.0, "spread_deg": 0.0}
	var w := BallisticWeapon.new()
	w.name = "R192ProbeWeapon"
	tree.get_root().add_child(w)
	w.position = p_pos
	w.setup(d, null, {
		"pipeline": _pipeline,
		"projectile_pool": _proj_pool,
		"enemy_grid": _grid,
		"laser_pool": null,
		"elemental": _sys,
	})
	return w


func _active_proj_ids() -> Dictionary:
	var ids := {}
	for node in _proj_pool.active_projectiles():
		ids[(node as ProjectileBase).get_instance_id()] = true
	return ids


func _kill_live_projs() -> void:
	for node in _proj_pool.active_projectiles():
		(node as ProjectileBase).nullify()


func _fire_until_pair(p_weapon: BallisticWeapon, p_state: ElementalState,
		p_elem_a: int, p_elem_b: int, p_max_shots: int) -> bool:
	# 实弹驱动：逐发开火 + 推进新弹至命中（附着/落血随弹体结算）——
	# 每发元素由武器 _shot_element 随机抽取（固定种子确定性），直至双新元素槽成对。
	for _shot in range(p_max_shots):
		if p_state.gauges[p_elem_a] > 0.0 and p_state.gauges[p_elem_b] > 0.0:
			return true
		_bump_frame()
		p_weapon.cooldown_left = 0.0
		var before := _active_proj_ids()
		p_weapon.try_fire()
		var fresh: Array[ProjectileBase] = []
		for node in _proj_pool.active_projectiles():
			var proj := node as ProjectileBase
			if not before.has(proj.get_instance_id()):
				fresh.append(proj)
		for _f in range(220):                    # 600px/s × 220/120s > 600px 全程
			_bump_frame()
			for proj in fresh:
				if is_instance_valid(proj):
					proj.tick(DT)
			if p_state.gauges[p_elem_a] > 0.0 and p_state.gauges[p_elem_b] > 0.0:
				return true
		_kill_live_projs()
	return p_state.gauges[p_elem_a] > 0.0 and p_state.gauges[p_elem_b] > 0.0


# ── ③a 端到端：ELE_HYDRO + ELE_DENDRO 同武器 → 绽放（非族新反应） ──
func _test_e2e_bloom() -> void:
	print("── ③ 端到端 A：同武器挂水+草新卡 → 绽放（延迟 AoE，非族新反应） ──")
	var enemy := _spawn_enemy(_make_enemy_data("E_R192_BLM", 100000.0), Vector2(80, 640))
	_sys.register_host(enemy)
	var w := _make_weapon(Vector2(80, 1100))
	_check("③A 前置：ELE_HYDRO + ELE_DENDRO 双新卡同武器挂载",
		w.attach_trait(_ele(&"ELE_HYDRO")) and w.attach_trait(_ele(&"ELE_DENDRO")))
	var st := enemy.get("elemental") as ElementalState
	var paired := _fire_until_pair(w, st, GameConst.Element.HYD, GameConst.Element.DEN, 24)
	_check("③A 实弹附着：双新元素槽成对（gauges[HYD]>0 且 gauges[DEN]>0）", paired,
		"hyd=%s den=%s" % [str(st.gauges[GameConst.Element.HYD]),
			str(st.gauges[GameConst.Element.DEN])])
	if paired:
		var rxn0: int = DebugStats.get_counter(&"reaction_triggered")
		_bump_frame()
		_sys.detect_reactions()
		_check("③A 绽放触发：计数 +1 · cd[RXN_HYD_DEN]=2s · 双槽清空",
			DebugStats.get_counter(&"reaction_triggered") == rxn0 + 1
			and _approx(float(st.reaction_cd.get(GameConst.ReactionType.RXN_HYD_DEN, 0.0)), 2.0, 0.01)
			and _approx(st.gauges[GameConst.Element.HYD], 0.0, 0.001)
			and _approx(st.gauges[GameConst.Element.DEN], 0.0, 0.001))
		_check("③A 绽放延迟臂：bloom_active 挂账 · bloom_timer≈0.75（R198 契约变更：延迟 1.5→0.75）",
			st.bloom_active and st.bloom_timer > 0.5 and st.bloom_timer <= 0.75 + 0.001,
			"timer=%s" % str(st.bloom_timer))
		var hp0: float = enemy.hp
		_sys.tick(1.6)                           # 到期消费（consume_bloom_expired 模式）
		_check("③A 到期爆发：χ1.5×S_snap(100) 主目标落血 150（隔离簇无副目标）",
			_approx(hp0 - enemy.hp, 150.0, 0.01), "Δhp=%s" % str(hp0 - enemy.hp))
	w.free()
	_kill_live_projs()
	_retire_enemy(enemy)


# ── ③b 端到端：ELE_ANEMO + ELE_HYDRO 同武器 → 扩散·水（族模板反应） ──
func _test_e2e_spread() -> void:
	print("── ③ 端到端 B：同武器挂风+水新卡 → 扩散·水（族模板反应） ──")
	var enemy := _spawn_enemy(_make_enemy_data("E_R192_SPR", 100000.0), Vector2(360, 640))
	var c1 := _spawn_enemy(_make_enemy_data("E_R192_SPR_C1", 100000.0), Vector2(430, 640))   # 70px < 120
	var c2 := _spawn_enemy(_make_enemy_data("E_R192_SPR_C2", 100000.0), Vector2(290, 640))   # 70px < 120
	_sys.register_host(enemy)
	_sys.register_host(c1)                     # 生产口径：全体敌出生即挂载状态容器（spawner）
	_sys.register_host(c2)
	var w := _make_weapon(Vector2(360, 1100))   # 主目标严格最近（460px < 候选 465px）——瞄主目标
	_check("③B 前置：ELE_ANEMO + ELE_HYDRO 双新卡同武器挂载",
		w.attach_trait(_ele(&"ELE_ANEMO")) and w.attach_trait(_ele(&"ELE_HYDRO")))
	var st := enemy.get("elemental") as ElementalState
	var paired := _fire_until_pair(w, st, GameConst.Element.ANE, GameConst.Element.HYD, 24)
	_check("③B 实弹附着：风+水双槽成对", paired,
		"ane=%s hyd=%s" % [str(st.gauges[GameConst.Element.ANE]),
			str(st.gauges[GameConst.Element.HYD])])
	if paired:
		var rxn0: int = DebugStats.get_counter(&"reaction_triggered")
		var hp0: float = enemy.hp
		_bump_frame()
		_sys.detect_reactions()
		_check("③B 扩散·水触发：计数 +1 · cd[RXN_HYD_ANE]=2s · 主目标双槽清空",
			DebugStats.get_counter(&"reaction_triggered") == rxn0 + 1
			and _approx(float(st.reaction_cd.get(GameConst.ReactionType.RXN_HYD_ANE, 0.0)), 2.0, 0.01)
			and _approx(st.gauges[GameConst.Element.ANE], 0.0, 0.001)
			and _approx(st.gauges[GameConst.Element.HYD], 0.0, 0.001))
		_check("③B 族模板直伤：主目标 χ0.8×S_snap(100) 落血 80",
			_approx(hp0 - enemy.hp, 80.0, 0.01), "Δhp=%s" % str(hp0 - enemy.hp))
		var st1 := c1.get("elemental") as ElementalState
		var st2 := c2.get("elemental") as ElementalState
		_check("③B 满槽转移：至多 3 敌 gauges[HYD]==GAUGE_MAX 钳制不清零（燃料存续）",
			st1 != null and st2 != null
			and _approx(st1.gauges[GameConst.Element.HYD], ElementalState.GAUGE_MAX, 0.001)
			and _approx(st2.gauges[GameConst.Element.HYD], ElementalState.GAUGE_MAX, 0.001),
			"c1=%s c2=%s" % [str(st1.gauges[GameConst.Element.HYD] if st1 != null else -1.0),
				str(st2.gauges[GameConst.Element.HYD] if st2 != null else -1.0)])
	w.free()
	_kill_live_projs()
	_retire_enemy(enemy)
	_retire_enemy(c1)
	_retire_enemy(c2)


# ── ③c 扩散·草转移元素行为探针（真件系统级；idContract §3.3「转移草」） ──
func _test_spread_dendro_probe() -> void:
	print("── ③ 探针：扩散·草（RXN_ANE_DEN）转移元素 == 草（§3.3 同模板列） ──")
	var enemy := _spawn_enemy(_make_enemy_data("E_R192_SPRD", 100000.0), Vector2(80, 100))
	var nb := _spawn_enemy(_make_enemy_data("E_R192_SPRD_N", 100000.0), Vector2(160, 100))   # 80px < 120
	_sys.register_host(enemy)
	_sys.register_host(nb)
	_sys.apply_attach(enemy, GameConst.Element.ANE, 30.0, {"snapshot": 100.0})
	_sys.apply_attach(enemy, GameConst.Element.DEN, 30.0)
	_bump_frame()
	_sys.detect_reactions()
	var st_nb := nb.get("elemental") as ElementalState
	var den_gauge: float = st_nb.gauges[GameConst.Element.DEN] if st_nb != null else -1.0
	var ane_gauge: float = st_nb.gauges[GameConst.Element.ANE] if st_nb != null else -1.0
	_check("③ 探针 扩散·草：邻居满槽转移的是草（gauges[DEN]==GAUGE_MAX）",
		_approx(den_gauge, ElementalState.GAUGE_MAX, 0.001),
		"邻居 gauges[DEN]=%s gauges[ANE]=%s（实现转移了谁一目了然）"
			% [str(den_gauge), str(ane_gauge)])
	_retire_enemy(enemy)
	_retire_enemy(nb)


# ── ⑥ 旧 3 反应行为回归（碎裂引爆 / 过载 AoE / 超导减抗数值） ──────
func _test_legacy_three() -> void:
	print("── ⑥ 旧 3 反应回归：碎裂引爆 · 过载 AoE · 超导减抗数值 ──")
	# 碎裂（RXN_FIR_ICE）：2.0 × 点燃剩余 DOT 池（池基非快照基）——3 层 × 0.15×100 × 剩余 4 跳
	var e1 := _spawn_enemy(_make_enemy_data("E_R192_SHT", 100000.0), Vector2(80, 400))
	_sys.register_host(e1)
	var st1 := e1.get("elemental") as ElementalState
	st1.burn_layers = 3
	st1.burn_timer = 2.0                       # 剩余 4 跳（burn_tick 0.5）
	st1.burn_tick = 0.5
	st1.burn_dot_ratio = 0.15
	st1.burn_snapshot_atk = 100.0
	var hp1: float = e1.hp
	_sys.apply_attach(e1, GameConst.Element.FIR, 30.0, {"snapshot": 100.0})
	_sys.apply_attach(e1, GameConst.Element.ICE, 30.0)
	_bump_frame()
	_sys.detect_reactions()
	_check("⑥ 碎裂引爆：落血 == 2.0 × 剩余 DOT 池 180 = 360（池基结算）",
		_approx(hp1 - e1.hp, 360.0, 0.01), "Δhp=%s" % str(hp1 - e1.hp))
	_check("⑥ 碎裂燃尽：burn_timer==0 · burn_layers==0 · 双槽清空",
		_approx(st1.burn_timer, 0.0, 0.001) and st1.burn_layers == 0
		and _approx(st1.gauges[GameConst.Element.FIR], 0.0, 0.001)
		and _approx(st1.gauges[GameConst.Element.ICE], 0.0, 0.001))
	_retire_enemy(e1)
	# 过载（RXN_FIR_LTG）：主目标 1.2×快照 120 + 半径 90 AoE 邻居同额（中心不重复结算）
	var e2 := _spawn_enemy(_make_enemy_data("E_R192_OVL", 100000.0), Vector2(400, 400))
	var nb2 := _spawn_enemy(_make_enemy_data("E_R192_OVL_N", 100000.0), Vector2(480, 400))   # 80px < 90
	_sys.register_host(e2)
	_sys.register_host(nb2)
	var hp2: float = e2.hp
	var hp2n: float = nb2.hp
	_sys.apply_attach(e2, GameConst.Element.FIR, 30.0, {"snapshot": 100.0})
	_sys.apply_attach(e2, GameConst.Element.LTG, 30.0)
	_bump_frame()
	_sys.detect_reactions()
	var st2 := e2.get("elemental") as ElementalState
	_check("⑥ 过载：主目标 −120（1.2×快照 100）+ AoE 邻居 −120（中心不双吃）",
		_approx(hp2 - e2.hp, 120.0, 0.01) and _approx(hp2n - nb2.hp, 120.0, 0.01),
		"main=%s nb=%s" % [str(hp2 - e2.hp), str(hp2n - nb2.hp)])
	_check("⑥ 过载：双槽清空 + cd[RXN_FIR_LTG]=2s",
		st2 != null and _approx(st2.gauges[GameConst.Element.FIR], 0.0, 0.001)
		and _approx(st2.gauges[GameConst.Element.LTG], 0.0, 0.001)
		and _approx(float(st2.reaction_cd.get(GameConst.ReactionType.RXN_FIR_LTG, 0.0)), 2.0, 0.01))
	_retire_enemy(e2)
	_retire_enemy(nb2)
	# 超导（RXN_ICE_LTG）：全抗 −0.3 · 持续 6s（纯减益；M0 账本记录 delta）
	var e3 := _spawn_enemy(_make_enemy_data("E_R192_SUP", 100000.0), Vector2(700, 400))
	_sys.register_host(e3)
	_sys.apply_attach(e3, GameConst.Element.ICE, 30.0)
	_sys.apply_attach(e3, GameConst.Element.LTG, 30.0)
	_bump_frame()
	_sys.detect_reactions()
	var st3 := e3.get("elemental") as ElementalState
	_check("⑥ 超导减抗数值：全抗 −0.3（KIN/FIR 位实测 −0.3）",
		_approx(e3.get_resist(GameConst.Element.KIN), -0.3, 0.0001)
		and _approx(e3.get_resist(GameConst.Element.FIR), -0.3, 0.0001),
		"kin=%s fir=%s" % [str(e3.get_resist(GameConst.Element.KIN)),
			str(e3.get_resist(GameConst.Element.FIR))])
	_check("⑥ 超导：持续 6.0s · 账本 delta==−0.3（M0 到期按记录恢复）",
		st3 != null and st3.superconduct_active
		and _approx(st3.superconduct_left, 6.0, 0.001)
		and _approx(st3.superconduct_delta, -0.3, 0.0001),
		"left=%s delta=%s" % [str(st3.superconduct_left if st3 != null else -1.0),
			str(st3.superconduct_delta if st3 != null else 0.0)])
	_retire_enemy(e3)


# ── ④⑤ 图鉴动态行数 + 反应跳字文本（GameLoop 真件） ───────────────
func _test_codex_and_popup() -> void:
	print("── ④⑤ 图鉴反应页动态行数 + 跳字文本（中文名+数字） ──")
	var scene: PackedScene = load(MAIN_SCENE)
	var gl = scene.instantiate() as GameLoop
	gl.name = "GameLoopUnderTestR192"
	tree.get_root().add_child(gl)
	gl.set_physics_process(false)
	_check("④⑤ 前置：GameLoop 就绪 + registry 已注入 MenuScreen",
		gl.boot_ready and gl.menu_screen.registry != null)
	_test_codex_rows_dynamic(gl)
	_test_popup_text(gl)
	tree.paused = false
	RunSave.clear()
	gl.free()


func _live_rows(p_list: Node) -> Array:
	# queue_free 已挂未销毁的行不计（rxn_codex 探针同口径）
	var out: Array = []
	for c in p_list.get_children():
		if not c.is_queued_for_deletion():
			out.append(c)
	return out


func _test_codex_rows_dynamic(p_gl: GameLoop) -> void:
	var menu = p_gl.menu_screen
	var rt: Dictionary = GameConfig.balance.reaction_table
	menu._on_lobby_pressed("codex")
	menu._on_codex_tab("反应")
	var rxn_rows: Array = []
	var blank_rows: Array = []
	for row in _live_rows(menu._panel_list):
		if row.get_node_or_null("RxnName") != null:
			rxn_rows.append(row)
		elif row.get_node_or_null("RxnBlankNote") != null:
			blank_rows.append(row)
	_check("④ 图鉴反应行数 == reaction_table 行数（%d 行，动态口径禁硬编码）" % rt.size(),
		rxn_rows.size() == rt.size(),
		"rows=%d table=%d" % [rxn_rows.size(), rt.size()])
	_check("④ 冰+草留白标注行恰 1 且文案单源 REACTION_BLANK_NOTE",
		blank_rows.size() == 1
		and String((blank_rows[0].get_node("RxnBlankNote") as Label).text)
			== GameConst.REACTION_BLANK_NOTE,
		str(blank_rows.size()))
	# 行-键双射：行中文名集合 == {REACTION_NAMES[表键枚举]}（每表键恰一行，动态）
	var want_names := {}
	for k in rt:
		want_names[String(GameConst.REACTION_NAMES[int(GameConst.ReactionType[String(k)])])] = true
	var got_names := {}
	for row in rxn_rows:
		got_names[String((row.get_node("RxnName") as Label).text)] = true
	_check("④ 行-键双射：反应行中文名集合 == REACTION_NAMES[reaction_table 键集]（逐键恰一行）",
		got_names == want_names and got_names.size() == rt.size(),
		"got=%d want=%d" % [got_names.size(), want_names.size()])
	menu._on_panel_close()


func _test_popup_text(p_gl: GameLoop) -> void:
	# 跳字文本级断言：走真件 PopupManager 起字链路——
	# dmg 型 = 名+合并值直读；stat 型 = 名+rxn_stat（manager 起字读表一次性格式化）
	var pm: PopupManager = p_gl.popup_manager
	var pool: PopupPool = p_gl.pools[&"popup"]
	pool.prewarm(GameConfig.get_pool_capacity(&"popup"))
	var numbers_prev: bool = bool(Meta.settings("damage_numbers_on"))
	var provider_prev: Callable = pm.baseline_provider
	Meta.set_setting("damage_numbers_on", true)
	pm.baseline_provider = Callable()          # 分级关闭（量级档噪声隔离）
	pm.tick(10.0)
	pm.clear_all()
	pm._rxn_frame_stamp = -1                   # 帧计数器隔离（同帧护栏判据重置）
	# dmg 型：蒸发 150（中文名 + 数字）
	var r := DamageResult.new()
	r.final_value = 150.0
	r.target_uid = 720001
	r.pos = Vector2(300.0, 400.0)
	r.popup_style = GameConst.PopupStyle.REACTION
	r.element = GameConst.ReactionType.RXN_FIR_HYD
	pm.on_damage_resolved(r)
	var p0: DamagePopup = pm._active_list[-1]
	_check("⑤ 跳字 dmg 型：蒸发 150 → 文本「蒸发150」（中文反应名 + 数字）",
		p0._label.text == "蒸发150", "text=%s" % p0._label.text)
	p0.merge(34.0)
	pm.tick(DT)                                # R189：合并置脏 → tick 帧内一次刷新
	_check("⑤ 跳字 dmg 型合并：+34 → 文本「蒸发184」（纯函数 f(look, merged_value)）",
		p0._label.text == "蒸发184", "text=%s" % p0._label.text)
	# stat 型：超导（manager 起字读表 −0.3 → −30%）
	pm.on_reaction_triggered(GameConst.ReactionType.RXN_ICE_LTG, Vector2(320.0, 400.0), 720002)
	var p1: DamagePopup = pm._active_list[-1]
	_check("⑤ 跳字 stat 型：超导标签「超导-30%」（读表 roundi(−0.3×100)）",
		p1._label.text == "超导-30%" and absf(p1.merged_value) <= 0.001,
		"text=%s" % p1._label.text)
	# stat 型：结晶·火（dr 0.15 → −15%）
	pm.on_reaction_triggered(GameConst.ReactionType.RXN_FIR_GEO, Vector2(340.0, 400.0), 720003)
	var p2: DamagePopup = pm._active_list[-1]
	_check("⑤ 跳字 stat 型：结晶·火标签「结晶·火-15%」（读表 dr×100）",
		p2._label.text == "结晶·火-15%", "text=%s" % p2._label.text)
	# stat 型：冻结（freeze_dur 1.2 → 1.2s）
	pm.on_reaction_triggered(GameConst.ReactionType.RXN_ICE_HYD, Vector2(360.0, 400.0), 720004)
	var p3: DamagePopup = pm._active_list[-1]
	_check("⑤ 跳字 stat 型：冻结标签「冻结1.2s」（读表 freeze_dur）",
		p3._label.text == "冻结1.2s", "text=%s" % p3._label.text)
	pm.clear_all()
	pm.baseline_provider = provider_prev
	Meta.set_setting("damage_numbers_on", numbers_prev)

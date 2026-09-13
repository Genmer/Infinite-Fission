# tests/runner/mech_gate_cases.gd
# 机制解锁节奏用例体（由 test_mech_gate.gd 入口在 autoload 就绪后运行时加载编译）。
# 节奏表真源 MechanicGate（2026-09-13 用户反馈）：第 1 关纯基础构筑 → 第 2 关火/冰元素 +
# 遗物 → 第 3 关感电（过载/超导随之可发生）→ 第 4 关满层质变 → 第 5 关赌徒诅咒。
# 用例收尾一律 set_run_map(&"") 还原无局口径（防跨套件/跨用例污染）。
extends RefCounted

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	_test_no_run_open()
	_test_per_map_gates()
	_test_trait_allowed()
	_test_relic_allowed()
	_test_intro_lines()
	_test_card_pool_linkage()
	_test_milestone_mount_gate()
	_test_devour_fx_smoke()
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
	Meta.set_run_map(&"")                     # 还原无局口径（后续套件/真机菜单不受污染）


func _set_map_idx(p_idx: int) -> void:
	# 大关下标 → 地图注入（MapTable.MAPS 顺序即关卡序）
	Meta.set_run_map(MapTable.MAPS[p_idx].id)


class StubPlayer extends Node:
	# 卡牌生成查询桩：真实属性（普通 Node.set 对不存在属性是 no-op）
	var weapon_slots: Array = []


# ── 用例 ──────────────────────────────────────────────────────────
func _test_no_run_open() -> void:
	print("── 无局口径：门控全开（菜单/测试基线不受影响） ──")
	Meta.set_run_map(&"")
	_check("无局：map_index = -1", MechanicGate.map_index() == -1)
	_check("无局：元素/感电/遗物/质变/诅咒全部开放",
		MechanicGate.elements_basic_unlocked() and MechanicGate.shock_unlocked()
		and MechanicGate.relics_unlocked() and MechanicGate.milestone_unlocked()
		and MechanicGate.curse_relic_unlocked())


func _test_per_map_gates() -> void:
	print("── 大关门控位（节奏表逐关断言） ──")
	_set_map_idx(0)
	_check("第1关草原：全部未解锁（纯基础构筑）",
		not MechanicGate.elements_basic_unlocked() and not MechanicGate.shock_unlocked()
		and not MechanicGate.relics_unlocked() and not MechanicGate.milestone_unlocked()
		and not MechanicGate.curse_relic_unlocked())
	_set_map_idx(1)
	_check("第2关冰原：火/冰元素 + 遗物开放；感电/质变/诅咒未解锁",
		MechanicGate.elements_basic_unlocked() and MechanicGate.relics_unlocked()
		and not MechanicGate.shock_unlocked() and not MechanicGate.milestone_unlocked()
		and not MechanicGate.curse_relic_unlocked())
	_set_map_idx(2)
	_check("第3关魔域：感电开放；质变/诅咒未解锁",
		MechanicGate.shock_unlocked() and not MechanicGate.milestone_unlocked()
		and not MechanicGate.curse_relic_unlocked())
	_set_map_idx(3)
	_check("第4关树海：满层质变开放；诅咒未解锁",
		MechanicGate.milestone_unlocked() and not MechanicGate.curse_relic_unlocked())
	_set_map_idx(4)
	_check("第5关沼泽：赌徒诅咒开放", MechanicGate.curse_relic_unlocked())
	Meta.set_run_map(&"")


func _test_trait_allowed() -> void:
	print("── 元素词条细粒度门（ELEM 池按元素） ──")
	var ignite: TraitData = load("res://resources/traits/ELE_IGNITE.tres")
	var shock: TraitData = load("res://resources/traits/ELE_SHOCK.tres")
	var atk: TraitData = load("res://resources/traits/AFF_ATK_UP.tres")
	_check("夹具：ELE_IGNITE(火)/ELE_SHOCK(雷)/AFF_ATK_UP 存在",
		ignite != null and shock != null and atk != null)
	_set_map_idx(0)
	_check("第1关：火/冰/雷词条均不上架；ADD 池不受门控",
		not MechanicGate.trait_allowed(ignite) and not MechanicGate.trait_allowed(shock)
		and MechanicGate.trait_allowed(atk))
	_set_map_idx(1)
	_check("第2关：火词条上架；雷词条不上架",
		MechanicGate.trait_allowed(ignite) and not MechanicGate.trait_allowed(shock))
	_set_map_idx(2)
	_check("第3关：雷词条上架", MechanicGate.trait_allowed(shock))
	var devour: TraitData = load("res://resources/traits/SYN_BURN_DEVOUR.tres")
	var frost_exec: TraitData = load("res://resources/traits/SYN_FROST_EXEC.tres")
	var first_strike: TraitData = load("res://resources/traits/SYN_FIRST_STRIKE.tres")
	_check("夹具：SYN_BURN_DEVOUR / SYN_FROST_EXEC / SYN_FIRST_STRIKE 存在",
		devour != null and frost_exec != null and first_strike != null)
	_set_map_idx(0)
	_check("第1关：点燃/寒滞条件乘区不上架（死卡门）；其他条件乘区不受限",
		not MechanicGate.trait_allowed(devour) and not MechanicGate.trait_allowed(frost_exec)
		and MechanicGate.trait_allowed(first_strike))
	_set_map_idx(1)
	_check("第2关：点燃/寒滞条件乘区上架",
		MechanicGate.trait_allowed(devour) and MechanicGate.trait_allowed(frost_exec))
	Meta.set_run_map(&"")


func _test_relic_allowed() -> void:
	print("── 遗物细粒度门（常规遗物第 2 关 / 赌徒诅咒终关） ──")
	_set_map_idx(0)
	_check("第1关：全部遗物不上架（类目关闭）",
		not MechanicGate.relic_allowed(&"REL_GAMBLER")
		and not MechanicGate.relic_allowed(&"REL_OVERCLOCK"))
	_set_map_idx(1)
	_check("第2关：常规遗物上架；赌徒未上架",
		MechanicGate.relic_allowed(&"REL_OVERCLOCK")
		and not MechanicGate.relic_allowed(&"REL_GAMBLER"))
	_set_map_idx(4)
	_check("第5关：赌徒上架", MechanicGate.relic_allowed(&"REL_GAMBLER"))
	Meta.set_run_map(&"")


func _test_intro_lines() -> void:
	print("── 大关新机制文案（选关行 / 开局横幅共用） ──")
	var all_ok := true
	for i in range(MapTable.count()):
		if MechanicGate.intro_for_map(i).is_empty():
			all_ok = false
	_check("五大关：intro 文案全部非空", all_ok)
	_check("越界：intro 空串（不崩溃）", MechanicGate.intro_for_map(99) == ""
		and MechanicGate.intro_for_map(-1) == "")


func _test_card_pool_linkage() -> void:
	print("── 卡池联动（CardGenerator 消费门控） ──")
	var registry := DataRegistry.new()
	registry.load_all("res://data/manifest.cfg")
	var gen := CardGenerator.new()
	gen.setup(registry)
	var player_stub := StubPlayer.new()
	tree.root.add_child(player_stub)
	_check("注册表：ELE_IGNITE / REL_GAMBLER 入册",
		registry.get_trait(&"ELE_IGNITE") != null and registry.get_relic(&"REL_GAMBLER") != null)
	# 第 1 关：ELEM 候选空 + 遗物候选空（RELIC 类目重 roll 由 relic_available 承担）
	_set_map_idx(0)
	var elem0 := gen._trait_candidates("ELEM", player_stub, [])
	_check("第1关：ELEM 候选空（无元素卡上架）", elem0.is_empty())
	_check("第1关：遗物候选空（类目门关闭）", gen._unowned_relic_ids().is_empty())
	# 第 2 关：火/冰上架、雷不上架；遗物候选非空且不含赌徒
	_set_map_idx(1)
	var elem1 := gen._trait_candidates("ELEM", player_stub, [])
	_check("第2关：ELEM 候选 = 火/冰（含点燃，不含感电）",
		elem1.has(&"ELE_IGNITE") and not elem1.has(&"ELE_SHOCK"),
		"pool=%s" % [elem1])
	_check("第2关：遗物候选非空（类目开启）", not gen._unowned_relic_ids().is_empty())
	# 第 3 关：感电上架
	_set_map_idx(2)
	var elem2 := gen._trait_candidates("ELEM", player_stub, [])
	_check("第3关：ELEM 候选含感电", elem2.has(&"ELE_SHOCK"))
	# 第 5 关：赌徒进入遗物候选
	_set_map_idx(4)
	_check("第5关：遗物候选含赌徒硬币", gen._unowned_relic_ids().has(&"REL_GAMBLER"))
	player_stub.queue_free()
	Meta.set_run_map(&"")


func _test_milestone_mount_gate() -> void:
	print("── 质变挂载门（WeaponBase.attach_trait ×1.6） ──")
	var registry := DataRegistry.new()
	registry.load_all("res://data/manifest.cfg")
	var wdata: WeaponData = registry.get_weapon(&"W1_pistol")
	var tdata: TraitData = registry.get_trait(&"AFF_ATK_UP")
	_check("夹具：W1_pistol / AFF_ATK_UP 存在", wdata != null and tdata != null)
	_set_map_idx(0)
	var w0: WeaponBase = BallisticWeapon.new()
	tree.root.add_child(w0)
	w0.setup(wdata, null, {})
	for i in range(tdata.stack_max):
		w0.attach_trait(tdata)
	var mult0 := 1.0
	for tb in w0.trait_stack.traits:
		if tb.data.id == &"AFF_ATK_UP":
			mult0 = float(tb.value_mult)
	_check("第1关草原：挂满层不触发质变（value_mult 恒 1）", absf(mult0 - 1.0) <= 0.001,
		"mult=%f" % mult0)
	w0.queue_free()
	_set_map_idx(3)
	var w3: WeaponBase = BallisticWeapon.new()
	tree.root.add_child(w3)
	w3.setup(wdata, null, {})
	for i in range(tdata.stack_max):
		w3.attach_trait(tdata)
	var mult3 := 1.0
	for tb in w3.trait_stack.traits:
		if tb.data.id == &"AFF_ATK_UP":
			mult3 = float(tb.value_mult)
	_check("第4关树海：挂满层触发质变（value_mult ×1.6）", absf(mult3 - 1.6) <= 0.001,
		"mult=%f" % mult3)
	w3.queue_free()
	Meta.set_run_map(&"")


func _test_devour_fx_smoke() -> void:
	# 烈焰吞噬特效冒烟（表现层池化件：触发/节流/归还全链路——2026-09-13 用户反馈配套）
	print("── 吞噬特效冒烟（ElementalFxLayer 内聚池） ──")
	var fx := ElementalFxLayer.new()
	tree.root.add_child(fx)                       # _ready：建池 + 订阅 EventBus
	fx._on_burn_devour(Vector2(100.0, 100.0))
	var active := 0
	for dv in fx._devours:
		if float(dv["left"]) > 0.0:
			active += 1
	_check("吞噬特效：触发后 1 槽激活", active == 1, "active=%d" % active)
	fx._on_burn_devour(Vector2(200.0, 200.0))
	active = 0
	for dv in fx._devours:
		if float(dv["left"]) > 0.0:
			active += 1
	_check("吞噬特效：节流期内二次触发被拦（仍 1 槽）", active == 1, "active=%d" % active)
	fx.tick(DEVOUR_CD_TICK)                       # 过节流窗 → 可再触发
	fx._on_burn_devour(Vector2(300.0, 300.0))
	active = 0
	for dv in fx._devours:
		if float(dv["left"]) > 0.0:
			active += 1
	_check("吞噬特效：节流窗后可再触发（2 槽）", active == 2, "active=%d" % active)
	fx.tick(1.0)                                  # 超时归还 → 全池清空
	active = 0
	for dv in fx._devours:
		if float(dv["left"]) > 0.0:
			active += 1
	_check("吞噬特效：生命期后归还（0 槽激活）", active == 0, "active=%d" % active)
	fx.queue_free()


const DEVOUR_CD_TICK := 0.1                   # > DEVOUR_CD(0.09) 的单步推进

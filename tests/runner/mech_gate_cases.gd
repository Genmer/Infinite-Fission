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
	_test_new_elem_gates()          # R192：water/final_elem 门 + 新四卡门矩阵（追加段）
	_test_intro_new_reactions()     # R192：MAP_INTROS 第 4/5 关行新反应名
	_test_intro_broadcast_once()    # R192：开局横幅每局恰一次（既有通道）
	_test_r199_shelf_gates()        # R199：G5 死卡上架门（D01/D02/D03/D06/D17）
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
	# R191 仲裁（dwfq-aeba7902-2 修订批准，夹具接线非断言放宽）：ELE 三卡
	# required_forms=[0,1,2] 近战死卡上架门落地后，无目标武器的候选查询经
	# mount_gate form=-1 恒被形态门过滤——补真实弹道宿主（:194 先例同构），
	# 候选断言语义原样（上架什么仍由大关门决定，形态门只是被合法宿主满足）。
	var gate_target: WeaponBase = BallisticWeapon.new()
	tree.root.add_child(gate_target)
	gate_target.setup(registry.get_weapon(&"W1_pistol"), null, {})
	_check("注册表：ELE_IGNITE / REL_GAMBLER 入册",
		registry.get_trait(&"ELE_IGNITE") != null and registry.get_relic(&"REL_GAMBLER") != null)
	# 第 1 关：ELEM 候选空 + 遗物候选空（RELIC 类目重 roll 由 relic_available 承担）
	_set_map_idx(0)
	var elem0 := gen._trait_candidates("ELEM", player_stub, [], gate_target)
	_check("第1关：ELEM 候选空（无元素卡上架）", elem0.is_empty())
	_check("第1关：遗物候选空（类目门关闭）", gen._unowned_relic_ids().is_empty())
	# 第 2 关：火/冰上架、雷不上架；遗物候选非空且不含赌徒
	_set_map_idx(1)
	var elem1 := gen._trait_candidates("ELEM", player_stub, [], gate_target)
	_check("第2关：ELEM 候选 = 火/冰（含点燃，不含感电）",
		elem1.has(&"ELE_IGNITE") and not elem1.has(&"ELE_SHOCK"),
		"pool=%s" % [elem1])
	_check("第2关：遗物候选非空（类目开启）", not gen._unowned_relic_ids().is_empty())
	# 第 3 关：感电上架
	_set_map_idx(2)
	var elem2 := gen._trait_candidates("ELEM", player_stub, [], gate_target)
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


# ══ R192 元素扩容（docs/design/R192_ELEMENT_MATRIX.md §9/§13.1；追加段，既有原文保留） ══
func _test_new_elem_gates() -> void:
	# M2 集成窗原子性验收：枚举扩容必须与显式门分支同批——禁 mechanic_gate ELEM match
	# 落兜底 return shock_unlocked()（=第 3 关静默全上架）与 MULT 兜底 return true（死卡）。
	print("── R192 新元素门（water_unlocked idx≥3 / final_elem_unlocked idx≥4） ──")
	Meta.set_run_map(&"")
	_check("无局：water/final_elem 全开（菜单/测试口径）",
		MechanicGate.water_unlocked() and MechanicGate.final_elem_unlocked())
	for i in range(3):
		_set_map_idx(i)
		_check("第%d关：water/final_elem 均未解锁" % (i + 1),
			not MechanicGate.water_unlocked() and not MechanicGate.final_elem_unlocked())
	_set_map_idx(3)
	_check("第4关：water 解锁；final_elem 未解锁",
		MechanicGate.water_unlocked() and not MechanicGate.final_elem_unlocked())
	_set_map_idx(4)
	_check("第5关：water/final_elem 全解锁",
		MechanicGate.water_unlocked() and MechanicGate.final_elem_unlocked())
	Meta.set_run_map(&"")
	# 新四卡门矩阵（idContract §3.2 逐字；夹具在册即数据底座产出验收）
	print("── R192 新元素卡门矩阵（idx0/1/2 全闭 · idx3 仅 HYDRO · idx4 全开） ──")
	var new_cards := {}
	for id: StringName in [&"ELE_HYDRO", &"ELE_ANEMO", &"ELE_GEO", &"ELE_DENDRO"]:
		new_cards[id] = load("res://resources/traits/%s.tres" % String(id))
	_check("夹具：四张新元素卡在册（ELE_HYDRO/ELE_ANEMO/ELE_GEO/ELE_DENDRO）",
		new_cards[&"ELE_HYDRO"] != null and new_cards[&"ELE_ANEMO"] != null
		and new_cards[&"ELE_GEO"] != null and new_cards[&"ELE_DENDRO"] != null)
	for i in range(3):
		_set_map_idx(i)
		var all_closed := true
		for id2 in new_cards:
			all_closed = all_closed and not MechanicGate.trait_allowed(new_cards[id2])
		_check("第%d关：新四卡全部不上架（ELEM match 显式分支——无兜底静默上架）" % (i + 1),
			all_closed)
	_set_map_idx(3)
	_check("第4关：仅 ELE_HYDRO 上架（ANE/GEO/DEN 第 5 关起）",
		MechanicGate.trait_allowed(new_cards[&"ELE_HYDRO"])
		and not MechanicGate.trait_allowed(new_cards[&"ELE_ANEMO"])
		and not MechanicGate.trait_allowed(new_cards[&"ELE_GEO"])
		and not MechanicGate.trait_allowed(new_cards[&"ELE_DENDRO"]))
	_set_map_idx(4)
	_check("第5关：新四卡全部上架",
		MechanicGate.trait_allowed(new_cards[&"ELE_HYDRO"])
		and MechanicGate.trait_allowed(new_cards[&"ELE_ANEMO"])
		and MechanicGate.trait_allowed(new_cards[&"ELE_GEO"])
		and MechanicGate.trait_allowed(new_cards[&"ELE_DENDRO"]))
	# ELEM 池 8 卡齐（ARC_SURGE 系 MULT 池不在册——ARC 不附着三重结构保持）
	var pool8: Array[TraitData] = [
		load("res://resources/traits/ELE_IGNITE.tres"),
		load("res://resources/traits/ELE_FREEZE.tres"),
		load("res://resources/traits/ELE_SHOCK.tres"),
		load("res://resources/traits/ELE_REACTION_VOID.tres"),
		new_cards[&"ELE_HYDRO"], new_cards[&"ELE_ANEMO"],
		new_cards[&"ELE_GEO"], new_cards[&"ELE_DENDRO"],
	]
	var all8 := true
	for t: TraitData in pool8:
		all8 = all8 and t != null and MechanicGate.trait_allowed(t)
	_check("第5关：ELEM 池 8 卡全开放（4 旧 + 4 新；权重三源 10→14 属数据侧另验）", all8)
	Meta.set_run_map(&"")


func _test_intro_new_reactions() -> void:
	# MAP_INTROS 第 4/5 关行追加段（第 1-3 行原文不动；播报走既有 mechanics_intro 通道）
	print("── R192 MAP_INTROS：第 4/5 关行含新元素卡与新反应名 ──")
	_check("第1~3关 intro 原文不动（起点 / 元素一期·碎裂初见 / 感电卡·过载·超导）",
		MechanicGate.intro_for_map(0).contains("起点")
		and MechanicGate.intro_for_map(1).contains("元素一期")
		and MechanicGate.intro_for_map(1).contains("碎裂初见")
		and MechanicGate.intro_for_map(2).contains("感电卡")
		and MechanicGate.intro_for_map(2).contains("过载")
		and MechanicGate.intro_for_map(2).contains("超导"))
	var intro4 := MechanicGate.intro_for_map(3)
	_check("第4关 intro：含水元素卡段（新反应：蒸发 · 冻结 · 感电）",
		intro4.contains("水元素卡") and intro4.contains("蒸发")
		and intro4.contains("冻结") and intro4.contains("感电"), intro4)
	var intro5 := MechanicGate.intro_for_map(4)
	_check("第5关 intro：含草/风/岩元素卡段（燃烧·激化·绽放·扩散族·结晶族）",
		intro5.contains("草") and intro5.contains("风") and intro5.contains("岩")
		and intro5.contains("燃烧") and intro5.contains("激化")
		and intro5.contains("绽放") and intro5.contains("扩散")
		and intro5.contains("结晶"), intro5)


func _test_intro_broadcast_once() -> void:
	# 播报每局恰一次（选关开局 → mechanics_intro 单发；零新事件——防回环双增）
	print("── R192 播报：开局横幅每局恰一次 ──")
	var bk_maps: Dictionary = Meta.maps_cleared.duplicate()
	var bk_done: Dictionary = Meta.achievements_done.duplicate()
	Meta.mark_map_cleared(MapTable.MAPS[2].id)  # 解锁第 4 关（判据 = 上一关已通关）
	var scene: PackedScene = load("res://scenes/main.tscn")
	var gl = scene.instantiate() as GameLoop
	gl.name = "GameLoopForIntroOnce"
	tree.get_root().add_child(gl)
	gl.state = GameConst.GameStatus.MENU
	var emit_count: Array = [0]
	var seen_text: Array[String] = []
	var spy := func(t: String) -> void:
		emit_count[0] += 1
		seen_text.append(t)
	EventBus.mechanics_intro.connect(spy)
	gl._on_menu_start(MapTable.MAPS[3].id)
	_check("第4关开局：mechanics_intro 恰发 1 次（无回环双增）", emit_count[0] == 1,
		"count=%d" % emit_count[0])
	_check("第4关开局：横幅文本含水元素卡新反应段（真源 MAP_INTROS）",
		not seen_text.is_empty() and seen_text[0].contains("蒸发")
		and seen_text[0].contains("水元素卡"),
		seen_text[0] if not seen_text.is_empty() else "<无播报>")
	EventBus.mechanics_intro.disconnect(spy)
	tree.paused = false
	RunSave.clear()
	gl.free()
	Meta.maps_cleared = bk_maps                # 还原（防跨套件污染）
	Meta.achievements_done = bk_done
	Meta.set_run_map(&"")


# ══ R199 发布前全面体检 G5 组（docs/design/R199_RELEASE_SWEEP.md §G5；追加段） ══
# 统一思路：不合格武器不再上架——上架侧收紧（货架/回响/黑市同一道 mount_gate_allows），
# 战斗侧消费口零改动。补齐 D02 体检指出的「货架不再上架」负例测试缺口。
func _test_r199_shelf_gates() -> void:
	print("── R199 G5 死卡上架门（能力键 / 投射物上下文 / 遗物角色门 / 激光单元素） ──")
	var registry := DataRegistry.new()
	registry.load_all("res://data/manifest.cfg")
	var gen := CardGenerator.new()
	gen.setup(registry)
	var stub := StubPlayer.new()
	tree.root.add_child(stub)
	var made: Array[WeaponBase] = []
	# ── D01 平行校准：requires_weapon_keys（lateral_gap_levels 全仓仅 W1 在册） ──
	var w1 := _mk_weapon(BallisticWeapon.new(), &"W1_pistol", registry, made)
	var w2 := _mk_weapon(BallisticWeapon.new(), &"W2_gatling", registry, made)
	var w3 := _mk_weapon(BallisticWeapon.new(), &"W3_shotgun", registry, made)
	var w10 := _mk_weapon(BallisticWeapon.new(), &"W10_boomerang", registry, made)
	var cal: TraitData = registry.get_trait(&"MEC_PARALLEL_CAL")
	_check("R199 D01 夹具：MEC_PARALLEL_CAL 落 requires_weapon_keys=[lateral_gap_levels]",
		cal != null
		and (cal.params.get("requires_weapon_keys", []) as Array).has("lateral_gap_levels"))
	_check("R199 D01：平行校准过门 W1（编队键在册）；W2/W3/W10 无编队键不上架",
		CardGenerator.mount_gate_allows(cal, w1)
		and not CardGenerator.mount_gate_allows(cal, w2)
		and not CardGenerator.mount_gate_allows(cal, w3)
		and not CardGenerator.mount_gate_allows(cal, w10))
	# ── D02 回廊弹幕：能力键 + 前置词条双门（requires_trait 语义保持） ──
	var hall: TraitData = registry.get_trait(&"MEC_RICOCHET_HALL")
	_check("R199 D02 夹具：MEC_RICOCHET_HALL 落 requires_weapon_keys + requires_trait",
		hall != null
		and (hall.params.get("requires_weapon_keys", []) as Array).has("lateral_gap_levels")
		and String(hall.params.get("requires_trait", "")) == "MEC_BOUNCE")
	_check("R199 D02：回廊弹幕 W1 未持边界反弹不上架（组合门前置保持）",
		not CardGenerator.mount_gate_allows(hall, w1))
	w1.attach_trait(registry.get_trait(&"MEC_BOUNCE"))
	_check("R199 D02：回廊弹幕 W1 持边界反弹后上架（编队弹正主）",
		CardGenerator.mount_gate_allows(hall, w1))
	w2.attach_trait(registry.get_trait(&"MEC_BOUNCE"))
	_check("R199 D02：回廊弹幕 W2 纵持边界反弹仍不上架（无编队键 = 恒 false 回廊，卡面承诺不可达）",
		not CardGenerator.mount_gate_allows(hall, w2))
	# ── D03 死亡新星：requires_projectile（仅弹道/自导携 projectile 上下文） ──
	var w4 := _mk_weapon(LaserWeapon.new(), &"W4_pulse_beam", registry, made)
	var w6 := _mk_weapon(HomingWeapon.new(), &"W6_micro_missile", registry, made)
	var w8 := _mk_weapon(OrbitWeapon.new(), &"W8_orbit_field", registry, made)
	var w9 := _mk_weapon(OrbitWeapon.new(), &"W9_arc_slash", registry, made)
	var blast: TraitData = registry.get_trait(&"MEC_KILL_BLAST")
	_check("R199 D03 夹具：MEC_KILL_BLAST 落 requires_projectile=true",
		blast != null and bool(blast.params.get("requires_projectile", false)))
	_check("R199 D03：死亡新星上架弹道 W1 / 自导 W6；激光 W4、近战 W8/W9 不上架",
		CardGenerator.mount_gate_allows(blast, w1)
		and CardGenerator.mount_gate_allows(blast, w6)
		and not CardGenerator.mount_gate_allows(blast, w4)
		and not CardGenerator.mount_gate_allows(blast, w8)
		and not CardGenerator.mount_gate_allows(blast, w9))
	# ── D04 动能冲击：excluded_weapons 精确下架 W9（执行口径 supersede：计划原拟去
	#    form 3，经仲裁保留 [0,2,3]——W8 环绕力场同 form 且为击退真实消费方） ──
	var knock: TraitData = registry.get_trait(&"MEC_KNOCK")
	_check("R199 D04 夹具：MEC_KNOCK required_forms 锁定矩阵原样 [0,2,3] + 落 excluded_weapons=[W9]",
		knock != null
		and (knock.params.get("required_forms", []) as Array).has(3)
		and (knock.params.get("excluded_weapons", []) as Array).has("W9_arc_slash"))
	_check("R199 D04：动能冲击过门 W8（环绕力场击退消费方，R187 解锁保持）",
		CardGenerator.mount_gate_allows(knock, w8))
	_check("R199 D04：动能冲击不过门 W9（零击退设计，追击者货架不再上架）",
		not CardGenerator.mount_gate_allows(knock, w9))
	var add_w9: Array[StringName] = gen._trait_candidates("ADD", stub, [], w9)
	var add_w8: Array[StringName] = gen._trait_candidates("ADD", stub, [], w8)
	_check("R199 D04：货架负例——W9 候选集不含动能冲击 / W8 候选集仍含（防改回锁定）",
		not add_w9.has(&"MEC_KNOCK") and add_w8.has(&"MEC_KNOCK"),
		"w9=%s" % str(add_w9))
	# ── D17 激光双元素死卡：已持元素 → 第二张元素卡不再进候选池（货架侧收窄） ──
	_set_map_idx(1)
	var elem0: Array[StringName] = gen._trait_candidates("ELEM", stub, [], w4)
	_check("R199 D17 前置：激光 W4 未持元素时元素卡照常上架",
		elem0.has(&"ELE_IGNITE") and elem0.has(&"ELE_FREEZE"), str(elem0))
	w4.attach_trait(registry.get_trait(&"ELE_IGNITE"))
	var elem1: Array[StringName] = gen._trait_candidates("ELEM", stub, [], w4)
	_check("R199 D17：激光 W4 已持点燃 → 点燃/冰冻不再上架（主束单元素定案，第二张死卡）",
		not elem1.has(&"ELE_IGNITE") and not elem1.has(&"ELE_FREEZE"), str(elem1))
	w1.attach_trait(registry.get_trait(&"ELE_IGNITE"))
	var elem_w1: Array[StringName] = gen._trait_candidates("ELEM", stub, [], w1)
	_check("R199 D17 对照：弹道 W1 已持点燃 → 冰冻仍上架（弹道逐发随机双元素合法）",
		elem_w1.has(&"ELE_FREEZE"), str(elem_w1))
	# ── D06 每击谐振角色门（无技能角色不上架；计数口照旧零改动） ──
	var bk_char: StringName = Meta.character_id
	Meta.character_id = &"fission"
	_set_map_idx(1)
	_check("R199 D06：无技能角色（改造者·枢）每击谐振不上架（计费口恒早退死遗物）",
		not MechanicGate.relic_allowed(&"REL_ATTACK_CDR"))
	_check("R199 D06：角色门只收登记遗物——超频照常上架",
		MechanicGate.relic_allowed(&"REL_OVERCLOCK"))
	Meta.character_id = &"sentinel"
	_check("R199 D06：有技能角色（哨兵-9）每击谐振照常上架",
		MechanicGate.relic_allowed(&"REL_ATTACK_CDR"))
	Meta.character_id = bk_char               # 还原选人（防跨用例污染）
	_set_map_idx(0)
	for w in made:
		w.queue_free()
	stub.queue_free()
	Meta.set_run_map(&"")


func _mk_weapon(p_w: WeaponBase, p_id: StringName, p_registry: DataRegistry,
		p_sink: Array[WeaponBase]) -> WeaponBase:
	# 夹具：注册表直载武器实例（仅读 data/form 做门断言，不发火不进池）
	tree.root.add_child(p_w)
	p_w.setup(p_registry.get_weapon(p_id), null, {})
	p_sink.append(p_w)
	return p_w

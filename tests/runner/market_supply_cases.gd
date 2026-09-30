# tests/runner/market_supply_cases.gd
# R188-1 黑市供给回归用例体（由 test_market_supply.gd 入口加载）。
# 五断言（验收原文）：
#   ① 真终局（配方=verify_feedback_cases.gd:2950-2988 枯竭循环）开店 buyable_count()>=1
#   ② 词条枯竭态有非 heal 词条行，购买后词条 id 落在展示 target 的 trait_stack 上（展示=实挂）
#   ③ 挂满 12 条不同词条武器为 target 的行，购买不扣金且词条未挂（拒买——堵付费空买链）
#   ④ 持 REL_BLACK_MARKET 出现金卡行价=260（.tres params.gold_card_price 数据驱动）、
#     购买后 unlocked_slots+1，满槽不上架
#   ⑤ 清空 _wares 后 open 立即补保底常青行且可购（buyable_count()==0 触发终兜底）
# 行为口径抽查：刷新价曲线 15×market_mult(wave,9)×1.5ⁿ 不变；购买即下架、关店
# _refresh_count 归零；R37 玩家侧 5 池词条不出现在黑市货架。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_boot_game_loop()
	_test_endgame_pool_supply()
	_test_full_stack_reject_buy()
	_test_gold_card_row()
	_test_evergreen_fallback()
	_test_refresh_price_curve()
	_teardown_game_loop()
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)


func fail_count() -> int:
	return _fail


func _boot_game_loop() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "GameLoopUnderTest"
	tree.get_root().add_child(_gl)
	_gl.state = GameConst.GameStatus.MENU
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	_gl.start_run()


func _teardown_game_loop() -> void:
	tree.paused = false
	RunSave.clear()
	if _gl != null:
		_gl.free()
		_gl = null


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("PASS | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s %s" % [p_name, p_detail])
		print("FAIL | %s | %s" % [p_name, p_detail])


func _tid_layers(p_w: WeaponBase, p_tid: StringName) -> int:
	# 目标武器栈上某词条 id 的当前层数（0 = 未挂）
	if p_w == null or not is_instance_valid(p_w) or p_w.trait_stack == null:
		return 0
	for tb in p_w.trait_stack.traits:
		if tb.data != null and tb.data.id == p_tid:
			return int(tb.layers)
	return 0


func _find_ware(p_kind: String, p_evergreen: bool = false) -> int:
	# 货架上第一个非空且 kind 匹配的行下标（-1 = 无；p_evergreen 追加常青货标记过滤）
	var shop := _gl.shop_ui
	for i in range(shop._wares.size()):
		var ware: Dictionary = shop._wares[i]
		if ware.is_empty() or String(ware.get("kind")) != p_kind:
			continue
		if p_evergreen and not bool(ware.get("evergreen", false)):
			continue
		return i
	return -1


func _exhaust_null_target_pool() -> void:
	# 枯竭循环（配方=verify_feedback_cases.gd:2950-2988 原样）：null 目标口径反复叠满
	# 全部武器侧可售词条（跨武器合计 stack_max）——R188 扩池前「黑市卖完」的真终局前提
	var targets: Array[WeaponBase] = [_gl.player.weapon_slots[0]]
	var add_ids := [&"W6_micro_missile", &"W8_orbit_field"]
	var add_i := 0
	var overflow := false
	for round_i in range(60):
		var any_left := false
		for category in ["ADD", "MULT", "MECH", "ELEM"]:
			var pool: Array[StringName] = _gl.card_generator._trait_candidates(
				category, _gl.player, [])
			var clean: Array[StringName] = []
			for tid: StringName in pool:
				var td: TraitData = _gl.card_generator.registry.get_trait(tid)
				if td != null and not (td.pool_id in GameConst.PLAYER_SIDE_POOLS):
					clean.append(tid)
			if clean.is_empty():
				continue
			any_left = true
			var src: TraitData = _gl.card_generator.registry.get_trait(clean[0])
			var placed := false
			for w in targets:
				if w.trait_stack.attach(src):
					placed = true
					break
			while not placed and add_i < add_ids.size():
				var extra: WeaponBase = _gl.player.add_weapon(
					_gl.registry.get_weapon(add_ids[add_i]))
				add_i += 1
				if extra != null:
					targets.append(extra)
					if extra.trait_stack.attach(src):
						placed = true
						break
			if not placed:
				overflow = true                # 槽满也放不下（前置失败信号）
				break
		if overflow or not any_left:
			break
	_check("R188-1 前置：null 目标候选全部叠满（枯竭复现，无溢出）", not overflow)


# ── ①② 真终局供给 + 展示=实挂 ────────────────────────────────────
func _test_endgame_pool_supply() -> void:
	print("── R188-1 ①② 真终局供给 + 展示=实挂 ──")
	_gl.call(&"quit_to_menu")                 # 复位到 MENU（start_run 仅 MENU→PLAYING 合法迁移）
	_gl.call(&"start_run")
	_gl.player.set("unlocked_slots", 5)          # 预留空宿主槽位（多武器是后期常态）
	_gl.player.set("gold", 9999)
	_exhaust_null_target_pool()
	# 空栈宿主：枯竭态下带 target 容量感知口径的供货承载位（多武器玩家的真实后期形态）
	var extra_w: WeaponBase = _gl.player.add_weapon(_gl.registry.get_weapon(&"W3_shotgun"))
	_check("R188-1 前置：补充空栈宿主武器", extra_w != null)
	var shop := _gl.shop_ui
	shop.open(_gl.player, 20, false)
	_check("① 真终局（枯竭循环后）开店 buyable_count() >= 1",
		shop.buyable_count() >= 1, "buyable=%d" % shop.buyable_count())
	# ② 扩池后：null 口径已枯竭，带 target 容量感知口径仍有非 heal 词条行可供
	var trait_idx := _find_ware("trait")
	for attempt in range(4):
		if trait_idx >= 0:
			break
		shop._on_refresh_pressed()               # 付费重掷换宿主签（金币充足，真链重掷）
		trait_idx = _find_ware("trait")
	_check("② 词条枯竭态货架有非 heal 词条行（口径对齐扩池生效）", trait_idx >= 0)
	if trait_idx >= 0:
		var ware: Dictionary = shop._wares[trait_idx]
		var target_w: WeaponBase = ware.get("target")
		var tid: StringName = (ware.get("data") as TraitData).id
		var layers0 := _tid_layers(target_w, tid)
		var gold0 := int(_gl.player.get("gold"))
		var price0 := shop._price(ware)
		shop._buy(trait_idx)
		_check("② 展示=实挂：购买后词条 id 落在展示 target 的 trait_stack 上",
			_tid_layers(target_w, tid) == layers0 + 1,
			"tid=%s layers %d→%d" % [tid, layers0, _tid_layers(target_w, tid)])
		_check("② 购买扣金 + 购买即下架（_wares 行清空）",
			int(_gl.player.get("gold")) == gold0 - price0 and shop._wares[trait_idx].is_empty(),
			"gold %d→%d price=%d" % [gold0, int(_gl.player.get("gold")), price0])
	shop.close()


# ── ③ 满 12 词条 target 拒买不扣金 ────────────────────────────────
func _test_full_stack_reject_buy() -> void:
	print("── R188-1 ③ 满 12 词条 target 拒买不扣金 ──")
	_gl.call(&"quit_to_menu")                 # 复位到 MENU（start_run 仅 MENU→PLAYING 合法迁移）
	_gl.call(&"start_run")
	_gl.player.set("unlocked_slots", 5)
	# 空栈新武器作 target（前序块武器栈有残留——start_run 不清武器栈，取证需干净栈）
	var w_t: WeaponBase = _gl.player.add_weapon(_gl.registry.get_weapon(&"W5_prism"))
	_check("③ 前置：取得空栈 target 武器", w_t != null and w_t.trait_stack.traits.is_empty())
	if w_t == null:
		return
	var mounted := 0
	for tid: StringName in _gl.card_generator.registry.traits.keys():
		if mounted >= 12:
			break
		var td: TraitData = _gl.card_generator.registry.get_trait(tid)
		if td != null and w_t.trait_stack.attach(td):
			mounted += 1
	_check("③ 前置：target 武器直挂 12 条不同词条（TraitStack.MAX_TRAITS 满栈）",
		mounted == 12, "mounted=%d" % mounted)
	var tid13 := &""
	for tid2: StringName in _gl.card_generator.registry.traits.keys():
		var anywhere := false
		for w in _gl.player.weapon_slots:
			if w != null and is_instance_valid(w) and _tid_layers(w, tid2) > 0:
				anywhere = true
				break
		if not anywhere:
			tid13 = tid2
			break
	_check("③ 前置：取得第 13 条未挂词条（全武器栈均无）", tid13 != &"")
	var shop := _gl.shop_ui
	_gl.player.set("gold", 500)
	shop.open(_gl.player, 12, false)
	# 白盒构造「满栈 target 的行」：复验谓词必须拒买——不扣金、不静默换宿主
	var data13: TraitData = (_gl.card_generator.registry.get_trait(tid13) as TraitData).duplicate()
	shop._wares.append({
		"kind": "trait", "data": data13, "rarity": 0, "target": w_t,
		"base": 40.0, "mult": 1.0,
	})
	var idx := shop._wares.size() - 1
	shop._buy(idx)
	_check("③ 满 12 词条武器为 target 的行：购买不扣金",
		int(_gl.player.get("gold")) == 500, "gold=%d" % int(_gl.player.get("gold")))
	var leaked := 0
	for w in _gl.player.weapon_slots:
		if w != null and is_instance_valid(w):
			leaked += _tid_layers(w, tid13)
	_check("③ 拒买且第 13 条词条未挂到任何武器（不静默换宿主）", leaked == 0,
		"leaked=%d" % leaked)
	shop.close()


# ── ④ REL_BLACK_MARKET 金卡行 ─────────────────────────────────────
func _test_gold_card_row() -> void:
	print("── R188-1 ④ REL_BLACK_MARKET 金卡行 ──")
	_gl.call(&"quit_to_menu")                 # 复位到 MENU（start_run 仅 MENU→PLAYING 合法迁移）
	_gl.call(&"start_run")
	_gl.player.set("unlocked_slots", 3)
	_gl.player.set("gold", 1000)
	# apply_choice 的 RELIC 通道同源入列口径（card_generator.owned_relics）
	_gl.card_generator.owned_relics.append(&"REL_BLACK_MARKET")
	var shop := _gl.shop_ui
	shop.open(_gl.player, 9, false)
	var g_idx := _find_ware("gold_card")
	_check("④ 持 REL_BLACK_MARKET 出现金卡行", g_idx >= 0)
	if g_idx >= 0:
		var g_ware: Dictionary = shop._wares[g_idx]
		var bm: RelicData = _gl.card_generator.registry.get_relic(&"REL_BLACK_MARKET")
		var want := int(bm.params.get("gold_card_price", 260))
		_check("④ 金卡价 = .tres params.gold_card_price（260，数据驱动无硬编码）",
			want == 260 and shop._price(g_ware) == want,
			"tres=%d price=%d" % [want, shop._price(g_ware)])
		var slots0 := int(_gl.player.get("unlocked_slots"))
		var gold0 := int(_gl.player.get("gold"))
		shop._buy(g_idx)
		_check("④ 购买金卡 → unlocked_slots +1（SLOT_BONUS 提前解锁帽内下一槽）",
			int(_gl.player.get("unlocked_slots")) == slots0 + 1,
			"slots %d→%d" % [slots0, int(_gl.player.get("unlocked_slots"))])
		_check("④ 购买扣金 260 + 购买即下架",
			int(_gl.player.get("gold")) == gold0 - want and shop._wares[g_idx].is_empty())
	# 满槽守卫：帽内开满 → 重掷后不再上架（不上架不收钱）
	_gl.player.set("unlocked_slots", int(_gl.player.call(&"slot_cap_total")))
	shop._reroll_wares(false)
	_check("④ 满槽不上架（无金卡行）", _find_ware("gold_card") < 0)
	shop.close()


# ── ⑤ 终兜底常青货 ────────────────────────────────────────────────
func _test_evergreen_fallback() -> void:
	print("── R188-1 ⑤ 终兜底常青货 ──")
	_gl.call(&"quit_to_menu")                 # 复位到 MENU（start_run 仅 MENU→PLAYING 合法迁移）
	_gl.call(&"start_run")
	var shop := _gl.shop_ui
	# 真终局可购归零态：全武器满级（weapon_up 断供）+ 遗物全拥有（relic 断供）+
	# 满血（heal 禁购）+ 金币 25（词条行 28 金起买不起、常青货 25 金恰好可购）。
	# 补一把空栈武器：常青货宿主容量感知的落点位（前序块满栈武器挂不进新 id）
	var fb_w: WeaponBase = _gl.player.add_weapon(_gl.registry.get_weapon(&"W4_pulse_beam"))
	_check("R188-1 前置：补充可挂载空栈宿主", fb_w != null)
	for w in _gl.player.weapon_slots:
		if w != null and is_instance_valid(w):
			(w as WeaponBase).set("level", WeaponBase.MAX_LEVEL)
	for rid: StringName in _gl.card_generator.registry.relics.keys():
		if not _gl.card_generator.owned_relics.has(rid):
			_gl.card_generator.owned_relics.append(rid)
	_gl.player.set("hp", _gl.player.get("max_hp"))
	_gl.player.set("gold", 25)
	shop.open(_gl.player, 22, false)
	var fb_idx := _find_ware("trait", true)
	_check("⑤ buyable_count()==0 触发终兜底常青货上架（FALLBACK_ATK 运行期构造）",
		fb_idx >= 0)
	_check("⑤ 保底行可购（buyable_count() >= 1）", shop.buyable_count() >= 1,
		"buyable=%d" % shop.buyable_count())
	if fb_idx >= 0:
		var fb_ware: Dictionary = shop._wares[fb_idx]
		var fb_target: WeaponBase = fb_ware.get("target")
		var layers0 := _tid_layers(fb_target, &"FALLBACK_ATK")
		shop._buy(fb_idx)
		_check("⑤ 购买保底行：FALLBACK_ATK 落展示 target 栈 + 金币 25→0",
			_tid_layers(fb_target, &"FALLBACK_ATK") == layers0 + 1
				and int(_gl.player.get("gold")) == 0)
	# 验收原文动作：清空 _wares → open 立即补保底常青行且可购
	_gl.player.set("gold", 25)
	shop._wares.clear()
	shop.open(_gl.player, 22, false)
	_check("⑤ 清空 _wares 后 open 立即补保底常青行且可购",
		_find_ware("trait", true) >= 0 and shop.buyable_count() >= 1,
		"buyable=%d" % shop.buyable_count())
	shop.close()


# ── 行为口径抽查 ──────────────────────────────────────────────────
func _test_refresh_price_curve() -> void:
	print("── R188-1 口径抽查：刷新价曲线 / 关店归零 / R37 ──")
	_gl.call(&"quit_to_menu")                 # 复位到 MENU（start_run 仅 MENU→PLAYING 合法迁移）
	_gl.call(&"start_run")
	_gl.player.set("gold", 99999)
	var shop := _gl.shop_ui
	shop.open(_gl.player, 7, false)
	var curve_ok := true
	for n in range(3):
		shop.set("_refresh_count", n)
		var expect := int(ceil(15.0 * shop.market_mult(7, 9) * pow(1.5, float(n))))
		if int(shop.refresh_cost()) != expect:
			curve_ok = false
	_check("刷新价曲线不变：15×market_mult(wave,9)×1.5ⁿ（n=0,1,2 逐点相等）", curve_ok)
	shop.set("_refresh_count", 0)
	var c0: int = shop.refresh_cost()
	shop.set("_refresh_count", 2)
	_check("刷新价累进读感（c2≈2.25·c0）",
		absf(float(shop.refresh_cost()) / float(c0) - 2.25) < 0.2,
		"c0=%d c2=%d" % [c0, shop.refresh_cost()])
	shop.close()
	shop.open(_gl.player, 7, false)              # 同波重开（行情系数同源——c0 可比）
	_check("关店 _refresh_count 归零（重开回基准价 ==c0）",
		shop.refresh_count_used() == 0 and int(shop.refresh_cost()) == c0,
		"used=%d cost=%d c0=%d" % [shop.refresh_count_used(), shop.refresh_cost(), c0])
	# R37：黑市货架词条行不含玩家侧 5 池（add_hp/add_xp/add_pickup/add_skillcdr/add_gold）
	var side_seen := false
	var checked := 0
	for ware in shop._wares:
		if not ware.is_empty() and String(ware.get("kind")) == "trait":
			var td: TraitData = ware.get("data")
			checked += 1
			if td != null and (td.pool_id in GameConst.PLAYER_SIDE_POOLS):
				side_seen = true
	_check("R37：黑市货架无玩家侧池词条（扫 %d 行）" % checked, checked > 0 and not side_seen)
	shop.close()

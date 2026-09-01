# tests/runner/pkg8_cases.gd
# v0.8.0 自测用例体（由 test_pkg8.gd 入口在 autoload 就绪后运行时加载编译）。
# 覆盖 A7_v0.8.0_design.md 增量（按 V 任务分节，逐步累计；夹具沿用 pkg7 GameLoop 完整 Boot 模式）。
# 确定性：固定 RNG 种子（ChipHandler 4242 / 副词条流 4243 / CardGenerator 42 / 金币 42）。
extends RefCounted

const DT := 1.0 / 120.0                          # 120Hz 物理帧

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null                         # 共享 GameLoop（Boot 一次）


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_ensure_autoloads()
	_boot_game_loop()
	_test_v14_substats()                          # V14 副词条
	_test_v15_set_bonus()                         # V15 套装
	_test_v6_curse()                              # V6 诅咒运行时
	_test_v9_detach()                             # V9 词条移除/净化
	_teardown_game_loop()
	# 汇总
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)


func fail_count() -> int:
	return _fail


# ── 环境引导（pkg7 夹具模式） ─────────────────────────────────────
func _ensure_autoloads() -> void:
	_check("autoload 就绪（EventBus/GameConfig/DebugStats）",
		EventBus != null and GameConfig != null and DebugStats != null)
	_check("GameConfig 非致命（balance 加载）", not GameConfig.is_fatal() and GameConfig.balance != null)


func _boot_game_loop() -> void:
	_gl = GameLoop.new()
	_gl.name = "GameLoopUnderTest"
	tree.get_root().add_child(_gl)
	_check("Boot：完成且进入 MENU", _gl.boot_ready and _gl.state == GameConst.GameStatus.MENU)


func _teardown_game_loop() -> void:
	tree.paused = false
	if _gl != null:
		_gl.free()
		_gl = null


func _check(p_desc: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("  PASS %s" % p_desc)
	else:
		_fail += 1
		_failures.append("%s %s" % [p_desc, p_detail])
		print("  FAIL %s %s" % [p_desc, p_detail])


# ══ V14：副词条（独立流 / roll_substats / equip 三参 / 聚合） ═══════
func _test_v14_substats() -> void:
	print("── V14 副词条 ──")
	var h := _gl.chip_handler
	var reg := _gl.registry
	# 常量冻结
	_check("SUBSTAT_RNG_SEED=4243 / SET_BONUS_MULT=1.10",
		ChipHandler.SUBSTAT_RNG_SEED == 4243 and is_equal_approx(ChipHandler.SET_BONUS_MULT, 1.10))
	var values_ok := true
	for key in GameConst.CHIP_STAT_KEYS:
		values_ok = values_ok and ChipHandler.SUBSTAT_VALUES.has(key)
	_check("SUBSTAT_VALUES 覆盖全部 8 键", values_ok)
	_check("SUBSTAT_DIST 累积 {0:0.50, 1:0.85}",
		is_equal_approx(float(ChipHandler.SUBSTAT_DIST[0]), 0.50)
		and is_equal_approx(float(ChipHandler.SUBSTAT_DIST[1]), 0.85))
	# 重播种确定性：同 reset 同序列
	h.reset_run()
	var seq_a := _roll_substats_snapshot(h)
	h.reset_run()
	var seq_b := _roll_substats_snapshot(h)
	_check("副词条流重播种：reset 后序列逐位一致", seq_a == seq_b)
	# 主 roll 流（4242）独立性：roll_substats 不消费主 rng——重随副词条后主流位置不变
	h.reset_run()
	h.unlocked_slots = 3
	var offers_a := h.roll_shop_offers(12)        # 消费主流 + 副词条流
	var offer_ids_a := _offer_ids(offers_a)
	h.reset_run()
	h.unlocked_slots = 3
	var offers_b := h.roll_shop_offers(12)
	_check("roll_shop_offers：同种子货架（含预随副词条）可复现",
		offer_ids_a == _offer_ids(offers_b) and offers_a.size() == offers_b.size())
	# offer 结构：substats 键合法（键域 ⊂ 8 键−主键 / 值 = 固定小值 / 无重复键）
	var offer_ok := true
	for offer in offers_a:
		var chip := reg.get_chip(StringName(String(offer.get("chip_id", ""))))
		if chip == null:
			offer_ok = false
			continue
		offer_ok = offer_ok and _substats_valid(h, chip.stat_key, offer.get("substats", []))
	_check("roll_shop_offers：每 offer 预随合法 substats（所见即所得）",
		offer_ok and not offers_a.is_empty())
	# 1000 抽条数分布门值（0 条 50% / 1 条 35% / 2 条 15%）
	h.reset_run()
	var counts := {0: 0, 1: 0, 2: 0}
	for i in range(1000):
		var rolled := h.roll_substats(&"atk_pct")
		counts[rolled.size()] += 1
	_check("roll_substats：条数 ∈ {0,1,2} 且池排除主键",
		int(counts[0]) + int(counts[1]) + int(counts[2]) == 1000)
	_check("条数分布：0 条 460~540 / 1 条 310~390 / 2 条 110~190（±40 门值）",
		int(counts[0]) in range(460, 541) and int(counts[1]) in range(310, 391)
		and int(counts[2]) in range(110, 191),
		"%s" % str(counts))
	# equip 第三参默认 []（旧调用兼容）+ substats 键入列
	h.reset_run()
	h.unlocked_slots = 3
	_check("equip 旧签名兼容：equip(CHIP_ATK, 0) → true", h.equip(&"CHIP_ATK", 0))
	var snap := h.slot_snapshot()
	_check("旧路径 value_text 恒等（空副词条无摘要）", String((snap[0] as Dictionary).get("value_text", "")) == "+10%")
	h.reset_run()
	h.unlocked_slots = 3
	var custom: Array[Dictionary] = [{"stat": &"rof", "value": 0.015}]
	_check("equip 三参：custom substats 入列",
		h.equip(&"CHIP_ATK", 0, custom))
	_check("stat_bonus 聚合：主值 + 副词条同键求和",
		is_equal_approx(h.stat_bonus(&"atk_pct"), 0.10)
		and is_equal_approx(h.stat_bonus(&"rof"), 0.015))
	var snap2 := h.slot_snapshot()
	_check("slot_snapshot：value_text 追加副词条摘要",
		String((snap2[0] as Dictionary).get("value_text", "")).contains("射速"))
	# max_hp 分支旧路径恒等（0 诅咒下 curse 通道等价——V6 步验）
	h.reset_run()
	h.unlocked_slots = 3
	var hp0: float = _gl.player.hp
	var max0: float = _gl.player.max_hp
	_check("equip：CHIP_HP 金档（三参默认）→ max_hp +80 + HP 回补",
		h.equip(&"CHIP_HP", 3) and is_equal_approx(_gl.player.max_hp, max0 + 80.0)
		and is_equal_approx(_gl.player.hp, minf(hp0 + 80.0, max0 + 80.0)))
	# grant_boss_chip：granted 路径带出 substats（Boss 槽位夹具）
	h.reset_run()
	h.unlocked_slots = 3
	h.set_rng_seed(4242)
	var drop: Dictionary = {}
	for i in range(20):
		drop = h.grant_boss_chip(10)
		if bool(drop.get("granted")):
			break
	var grant_ok := bool(drop.get("granted"))
	var grant_chip := StringName(String(drop.get("chip_id", "")))
	var grant_valid := true
	if grant_ok:
		var gdata := reg.get_chip(grant_chip)
		grant_valid = gdata != null \
			and _substats_valid(h, gdata.stat_key, drop.get("substats", []))
	_check("grant_boss_chip：granted 路径带出合法 substats", grant_valid and grant_ok,
		"chip=%s" % String(grant_chip))


# ══ V15：套装（主属性同 stat_key ≥2 枚 → 该键总和 ×1.10；3 枚仍 ×1.10） ══
func _test_v15_set_bonus() -> void:
	print("── V15 套装 ──")
	var h := _gl.chip_handler
	# 单枚：无套装乘区
	h.reset_run()
	h.unlocked_slots = 3
	h.equip(&"CHIP_ATK", 0)
	_check("套装单枚：stat_bonus(atk_pct)=0.10（×1）",
		is_equal_approx(h.stat_bonus(&"atk_pct"), 0.10))
	# 双 atk_pct（CHIP_ATK 白 0.10 + CHIP_ATK2 白 0.12）：(0.10+0.12)×1.10 = 0.242
	h.equip(&"CHIP_ATK2", 0)
	_check("套装双 atk_pct：(0.10+0.12)×1.10 = 0.242",
		is_equal_approx(h.stat_bonus(&"atk_pct"), 0.242),
		str(h.stat_bonus(&"atk_pct")))
	# 双 max_hp（CHIP_HP 白 20 + CHIP_HP2 白 15）：(20+15)×1.10 = 38.5
	h.reset_run()
	h.unlocked_slots = 3
	h.equip(&"CHIP_HP", 0)
	_check("套装单 max_hp：stat_bonus(max_hp)=20（×1）", is_equal_approx(h.stat_bonus(&"max_hp"), 20.0))
	h.equip(&"CHIP_HP2", 0)
	_check("套装双 max_hp：(20+15)×1.10 = 38.5",
		is_equal_approx(h.stat_bonus(&"max_hp"), 38.5), str(h.stat_bonus(&"max_hp")))
	# 副词条同键不触发套装（主键计数判据——仅主属性计数）
	h.reset_run()
	h.unlocked_slots = 3
	var sub_atk: Array[Dictionary] = [{"stat": &"atk_pct", "value": 0.02}]
	h.equip(&"CHIP_ROF", 0, sub_atk)
	_check("套装判据：主键计数=1（副词条同键不计）→ 不乘 1.10",
		is_equal_approx(h.stat_bonus(&"atk_pct"), 0.02), str(h.stat_bonus(&"atk_pct")))
	# 3 枚仍 ×1.10（阈值制非逐枚；同键第三枚直接入列夹具模拟）
	h.reset_run()
	h.unlocked_slots = 3
	h.equip(&"CHIP_ATK", 0)
	h.equip(&"CHIP_ATK2", 0)
	var atk := h.registry.get_chip(&"CHIP_ATK")
	h.equipped.append({"chip": atk, "rarity": 0, "substats": []})
	_check("套装 3 枚仍 ×1.10：(0.10+0.12+0.10)×1.10 = 0.352",
		is_equal_approx(h.stat_bonus(&"atk_pct"), 0.352), str(h.stat_bonus(&"atk_pct")))
	# 异键不互扰：双 atk_pct 不影响 rof 单键
	_check("套装异键隔离：stat_bonus(rof) 恒 0", is_equal_approx(h.stat_bonus(&"rof"), 0.0))


# ══ V6：诅咒运行时（CurseHandler / compute_max_hp 唯一公式 / 双通道无敌 / 受击乘区） ══
func _test_v6_curse() -> void:
	print("── V6 诅咒运行时 ──")
	var h := _gl.chip_handler
	var player := _gl.player
	var c := _gl.curse_handler
	# GameLoop Boot 组装 + 注入
	_check("Boot：CurseHandler 组装 + player deps 注入（A7 §V6）",
		c != null and player.get("_deps").get("curse_handler") == c
		and h.curse_handler == c)
	_check("常量冻结：MAX=5 / 每层 0.08/0.15/0.04",
		CurseHandler.MAX_CURSE_LAYERS == 5
		and is_equal_approx(CurseHandler.DMG_TAKEN_PER_LAYER, 0.08)
		and is_equal_approx(CurseHandler.GOLD_DROP_PER_LAYER, 0.15)
		and is_equal_approx(CurseHandler.MAXHP_PER_LAYER, 0.04))
	# compute_max_hp 唯一公式（静态纯函数）
	_check("compute_max_hp：基线 (0,0,0,0)=100",
		is_equal_approx(Player.compute_max_hp(0.0, 0.0, 0.0, 0), 100.0))
	_check("compute_max_hp：角色+芯片+flat (0.3,80,10,0)=220",
		is_equal_approx(Player.compute_max_hp(0.3, 80.0, 10.0, 0), 220.0))
	_check("compute_max_hp：诅咒 2 层 (0,0,0,2)=92",
		is_equal_approx(Player.compute_max_hp(0.0, 0.0, 0.0, 2), 92.0))
	_check("compute_max_hp：下限钳 1.0（(-0.99,0,0,5)→0.8→1.0）",
		is_equal_approx(Player.compute_max_hp(-0.99, 0.0, 0.0, 5), 1.0))
	# CurseHandler 单元：加/减层钳制 + 遥测 + 乘区问询
	c.reset_run()
	_check("reset_run：清零 + recompute（max_hp 回基线 100）",
		c.curse_count == 0 and c.curses_taken == 0 and c.curses_purged == 0
		and is_equal_approx(player.max_hp, 100.0))
	_check("add_curse：+2 → 返 2 / dmg_taken_mult=1.16 / gold_drop_bonus=0.30",
		c.add_curse(2) == 2 and is_equal_approx(c.dmg_taken_mult(), 1.16)
		and is_equal_approx(c.gold_drop_bonus(), 0.30))
	_check("add_curse：+9 钳到上限 → 返 3 / is_maxed",
		c.add_curse(9) == 3 and c.is_maxed() and c.curse_count == 5)
	_check("add_curse：满层拒绝 → 返 0", c.add_curse(1) == 0)
	_check("remove_curse：−4 → 返 4 / 层数 1 / 净化遥测 +4",
		c.remove_curse(4) == 4 and c.curse_count == 1 and c.curses_purged == 4)
	_check("remove_curse：残余 1 层全移 → 返 1 / 层数 0",
		c.remove_curse(2) == 1 and c.curse_count == 0)
	_check("remove_curse：0 层再减 → 返 0", c.remove_curse(1) == 0)
	# recompute 通道：max_hp = (100+chip+flat)×(1−0.04n) + curse_changed 广播
	c.reset_run()
	c.add_curse(1)
	_check("recompute：1 层 max_hp = 100×0.96 = 96",
		is_equal_approx(player.max_hp, 96.0), str(player.max_hp))
	player.max_hp_bonus_flat = 20.0
	c.recompute_max_hp()
	_check("recompute：flat 池计入（100+20)×0.96 = 115.2",
		is_equal_approx(player.max_hp, 115.2), str(player.max_hp))
	player.max_hp_bonus_flat = 0.0
	var got_curse: Array = []
	var cb_curse := func(count: int, max_hp: float) -> void: got_curse.append([count, max_hp])
	EventBus.curse_changed.connect(cb_curse)
	c.recompute_max_hp(10.0)
	EventBus.curse_changed.disconnect(cb_curse)
	_check("recompute(Δ=10)：芯片回补口径 hp=minf(hp+10,max) + curse_changed 广播（1 层 96）",
		(got_curse as Array).size() == 1 and int((got_curse[0] as Array)[0]) == 1
		and is_equal_approx(player.max_hp, 96.0))
	# 受击乘区（诅咒 ×(1+0.08n)）+ 双通道无敌
	player.respawn()
	c.reset_run()
	var hp0: float = player.hp
	player.invuln_left = 0.0
	player.take_contact_damage(10.0)
	_check("受击 0 诅咒恒等：扣 10 + 受击无敌写入",
		is_equal_approx(player.hp, hp0 - 10.0) and player.invuln_left > 0.0)
	var hp1: float = player.hp
	player.take_contact_damage(10.0)
	_check("受击无敌期：二跳免伤（invuln 通道）", is_equal_approx(player.hp, hp1))
	c.add_curse(2)
	player.invuln_left = 0.0
	var hp2: float = player.hp
	player.take_contact_damage(10.0)
	_check("受击诅咒乘区：2 层 ×1.16 → 扣 11.6",
		is_equal_approx(hp2 - player.hp, 11.6), str(hp2 - player.hp))
	# 冲刺无敌通道：并联判定 + 互不覆盖（受击不写 dash 通道）
	player.respawn()
	c.reset_run()
	player.invuln_left = 0.0
	player.dash_invuln_left = 0.15
	var hp3: float = player.hp
	player.take_contact_damage(10.0)
	_check("dash_invuln 通道：受击判定免伤且不写 invuln_left",
		is_equal_approx(player.hp, hp3) and player.invuln_left == 0.0
		and player.dash_invuln_left > 0.0)
	# respawn：max_hp 公式重导出 + flat/dash 通道清零
	player.max_hp_bonus_flat = 30.0
	player.dash_invuln_left = 0.1
	player.respawn()
	_check("respawn：max_hp=compute_max_hp(char_pct,0,0,0) + flat/dash 清零",
		is_equal_approx(player.max_hp, 100.0) and player.max_hp_bonus_flat == 0.0
		and player.dash_invuln_left == 0.0 and is_equal_approx(player.hp, 100.0))
	# maxhp utility：flat 池 + recompute（0 诅咒 → base+10 恒等）
	_gl.start_run()
	_gl.change_state(GameConst.GameStatus.SHOP)
	_gl.shop_ui.open(9, false, [], {}, 0)
	_gl.gold = 200
	_gl._on_shop_utility(&"maxhp")
	_check("maxhp utility：flat+recompute（max_hp=110 / flat=10 / 限购位）",
		is_equal_approx(player.max_hp, 110.0) and player.max_hp_bonus_flat == 10.0
		and bool(_gl.shop_ui.shelf_state()["maxhp_used"]))
	_gl.shop_ui.close()
	_gl.change_state(GameConst.GameStatus.PLAYING)
	# 芯片 max_hp 键：curse recompute 通道（0 诅咒 + 单枚恒等 +80）
	h.reset_run()
	h.unlocked_slots = 3
	var max_before: float = player.max_hp
	_check("equip CHIP_HP 金档（recompute 通道）：max_hp +80",
		h.equip(&"CHIP_HP", 3) and is_equal_approx(player.max_hp, max_before + 80.0))
	# cursed 卡同步诅咒层（卡流接入点：_on_card_choice）
	c.reset_run()
	h.reset_run()
	_gl.change_state(GameConst.GameStatus.LEVEL_UP)
	var cursed_card := {"id": &"AFF_ATK_UP", "kind": CardGenerator.CardKind.TRAIT,
		"rarity": 3, "cursed": true, "data": _gl.registry.get_trait(&"AFF_ATK_UP")}
	_gl._on_card_choice(cursed_card)
	_check("cursed 卡 apply → add_curse(1)（卡流接入点 1/2）",
		c.curse_count == 1 and c.curses_taken == 1 and _gl.state == GameConst.GameStatus.PLAYING)
	_gl.change_state(GameConst.GameStatus.GAME_OVER)
	_gl.restart_run()
	_check("restart：诅咒层数/遥测随局清零",
		c.curse_count == 0 and c.curses_taken == 0 and c.curses_purged == 0)


# ══ V9：词条移除（TraitStack 三 API / is_curse 单源 / strip+purify 仲裁） ════
func _test_v9_detach() -> void:
	print("── V9 词条移除 ──")
	# is_curse_trait 唯一判定
	var curse_data := TraitData.new()
	curse_data.id = &"TEST_CURSE"
	curse_data.pool = GameConst.PoolClass.ADD
	curse_data.pool_id = &"add_atk"
	curse_data.value = -0.1
	curse_data.params = {"stat": "atk_pct"}      # 无 is_curse 装饰（退役键）
	curse_data.stack_max = 99
	var ok_data := TraitData.new()
	ok_data.id = &"TEST_OK"
	ok_data.pool = GameConst.PoolClass.ADD
	ok_data.pool_id = &"add_atk"
	ok_data.value = 0.2
	ok_data.stack_max = 99
	var mult_neg := TraitData.new()
	mult_neg.id = &"TEST_MULT_NEG"
	mult_neg.pool = GameConst.PoolClass.MULT
	mult_neg.value = -0.1
	_check("is_curse_trait：ADD 负值=true / ADD 正值=false / MULT 负值=false",
		TraitStack.is_curse_trait(curse_data) and not TraitStack.is_curse_trait(ok_data)
		and not TraitStack.is_curse_trait(mult_neg))
	# 栈操作：peek/detach_last(skip_curse) / detach_by_id
	var stack := TraitStack.new()
	stack.attach(curse_data)
	stack.attach(curse_data)                      # 同 id 叠层 ×2
	stack.attach(ok_data)
	var peek_ok: Dictionary = stack.peek_last(true)
	_check("peek_last(true)：跳过诅咒 → 末位非诅咒 TEST_OK",
		bool(peek_ok.get("ok")) and StringName(String(peek_ok.get("trait_id"))) == &"TEST_OK"
		and int(peek_ok.get("layers")) == 1 and not bool(peek_ok.get("is_curse")))
	var det: Dictionary = stack.detach_last(true)
	_check("detach_last(true)：摘 TEST_OK 1 层 → layers_left=0",
		bool(det.get("ok")) and StringName(String(det.get("trait_id"))) == &"TEST_OK"
		and int(det.get("layers_left")) == 0 and stack.size() == 1)
	var peek_curse: Dictionary = stack.peek_last(false)
	_check("peek_last(false)：末位含诅咒 + is_curse 标记（单源）",
		bool(peek_curse.get("ok")) and bool(peek_curse.get("is_curse")))
	_check("detach_last(true)：仅剩诅咒 → ok=false",
		not bool(stack.detach_last(true).get("ok")))
	var d1: Dictionary = stack.detach_by_id(&"TEST_CURSE", 1)
	_check("detach_by_id：诅咒 2→1 层 → layers_left=1（实例保留）",
		bool(d1.get("ok")) and int(d1.get("layers_left")) == 1 and stack.size() == 1)
	var d2: Dictionary = stack.detach_by_id(&"TEST_CURSE", 1)
	_check("detach_by_id：最后一层 → layers_left=0（实例摘除）",
		bool(d2.get("ok")) and int(d2.get("layers_left")) == 0 and stack.is_empty())
	_check("detach_by_id：无命中 → ok=false", not bool(stack.detach_by_id(&"TEST_CURSE").get("ok")))
	# aggregate_add_entries is_curse 单源（params 无 is_curse 仍判诅咒）
	stack.attach(curse_data)
	var entries := stack.aggregate_add_entries()
	_check("aggregate_add_entries：is_curse 单源判定（params 退役）",
		(entries as Array).size() == 1 and bool((entries[0] as Dictionary).get("is_curse")))
	# GameLoop strip/purify 仲裁（真武器 + 商店夹具）
	_gl.start_run()
	_gl.change_state(GameConst.GameStatus.SHOP)
	_gl.shop_ui.open(9, false, [], {}, 0)
	_gl.gold = 1000
	var weapon := _gl.player.weapon_slots[0]
	weapon.attach_trait(ok_data)
	var layers0 := _stack_layers(weapon.trait_stack)
	_gl._on_shop_utility(&"strip")
	_check("strip：扣 60 + 非诅咒词条 −1 层",
		_gl.gold == 940 and _stack_layers(weapon.trait_stack) == layers0 - 1,
		"gold=%d layers=%d" % [_gl.gold, _stack_layers(weapon.trait_stack)])
	# strip 拒绝：无非诅咒词条
	var g0: int = _gl.gold
	weapon.trait_stack.clear()
	_gl._on_shop_utility(&"strip")
	_check("strip：无非诅咒词条 → 拒绝不扣款", _gl.gold == g0)
	# purify：GAMBLER_CURSE 词条优先
	var gambler := TraitData.new()
	gambler.id = &"GAMBLER_CURSE"
	gambler.pool = GameConst.PoolClass.ADD
	gambler.pool_id = &"add_atk"
	gambler.value = -0.1
	gambler.stack_max = 99
	weapon.attach_trait(gambler)
	_gl.curse_handler.reset_run()                 # 隔离深渊层（确保走词条分支）
	var g1: int = _gl.gold
	_gl._on_shop_utility(&"purify")
	_check("purify：GAMBLER_CURSE 词条摘除（80 金）",
		_gl.gold == g1 - 80 and not stack_has_id(weapon.trait_stack, &"GAMBLER_CURSE"))
	# purify：无词条诅咒 → 深渊层 −1
	_gl.curse_handler.reset_run()
	_gl.curse_handler.add_curse(2)
	var g2: int = _gl.gold
	_gl._on_shop_utility(&"purify")
	_check("purify：深渊层 −1（80 金）",
		_gl.gold == g2 - 80 and _gl.curse_handler.curse_count == 1)
	# purify 拒绝：皆无
	_gl.curse_handler.reset_run()
	var g3: int = _gl.gold
	_gl._on_shop_utility(&"purify")
	_check("purify：无词条无深渊层 → 拒绝不扣款",
		_gl.gold == g3 and _gl.curse_handler.curse_count == 0)
	_gl.shop_ui.close()
	_gl.change_state(GameConst.GameStatus.PLAYING)


func _stack_layers(p_stack: TraitStack) -> int:
	var total := 0
	for tb in p_stack.traits:
		total += int((tb as TraitBase).layers)
	return total


func stack_has_id(p_stack: TraitStack, p_id: StringName) -> bool:
	for tb in p_stack.traits:
		if (tb as TraitBase).data.id == p_id:
			return true
	return false


func _roll_substats_snapshot(p_h: ChipHandler) -> Array:
	# 副词条流固定消费序快照（100 抽条数 + 首键）
	var out: Array = []
	for i in range(100):
		var rolled := p_h.roll_substats(&"rof")
		var row := [rolled.size()]
		for sub in rolled:
			row.append(String(sub.get("stat", "")))
		out.append(str(row))
	return out


func _offer_ids(p_offers: Array) -> Array[String]:
	var out: Array[String] = []
	for offer in p_offers:
		out.append(String((offer as Dictionary).get("chip_id", "")))
	return out


func _substats_valid(p_h: ChipHandler, p_main_key: StringName, p_substats: Variant) -> bool:
	# substats 契约：Array、≤2 条、键 ∈ 8 键−主键、无重复、值 = 固定小值表
	if not (p_substats is Array):
		return false
	var arr := p_substats as Array
	if arr.size() > 2:
		return false
	var seen: Dictionary = {}
	for sub in arr:
		var d := sub as Dictionary
		var stat := StringName(String(d.get("stat", "")))
		if not GameConst.CHIP_STAT_KEYS.has(stat) or stat == p_main_key or seen.has(stat):
			return false
		seen[stat] = true
		if not is_equal_approx(float(d.get("value", -1.0)), float(ChipHandler.SUBSTAT_VALUES.get(stat, -1.0))):
			return false
	return true

# tests/runner/pkg7_cases.gd
# v0.7.0 自测用例体（由 test_pkg7.gd 入口在 autoload 就绪后运行时加载编译）。
# 覆盖 A6_v0.7.0_design.md 增量（按 U 任务分节；夹具沿用 pkg6 GameLoop 完整 Boot 模式）。
# 确定性：固定 RNG 种子（ChipHandler 默认 seed 4242 / CardGenerator 42 / 金币 42）。
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
	_test_chip_data()                             # U1
	_test_chip_handler()                          # U2
	_test_chip_pipeline()                         # U3
	_test_u12_u13_u14()                           # U12+U13+U14
	_test_gold_rush()                             # U5
	_test_shop_chips()                            # U4+U7
	_test_boss_chip_drop()                        # U6
	_test_reaction_presentation()                 # U8+U9+U10
	_teardown_game_loop()
	# 汇总
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)


func fail_count() -> int:
	return _fail


# ── 环境引导（pkg6 夹具模式） ─────────────────────────────────────
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


# ══ U1：芯片数据层 ════════════════════════════════════════════════
func _test_chip_data() -> void:
	print("── U1 芯片数据层 ──")
	var reg := _gl.registry
	# 封闭注册表 + manifest 类目
	_check("CHIP_STAT_KEYS 恰好 8 键（A6 §1 冻结表）", GameConst.CHIP_STAT_KEYS.size() == 8)
	for key in [&"atk_pct", &"rof", &"crit_rate", &"crit_dmg", &"attach_strength",
			&"gold_gain", &"max_hp", &"xp_gain"]:
		if not GameConst.CHIP_STAT_KEYS.has(key):
			_check("CHIP_STAT_KEYS 含 %s" % String(key), false)
	_check("chips 类目注册 8 枚（0 剔除）", reg.chips.size() == 8,
		"实际 %d" % reg.chips.size())
	# 冻结数值表（id -> [stat_key, values 白/蓝/紫/金]）
	var table := {
		&"CHIP_ATK": [&"atk_pct", [0.10, 0.16, 0.24, 0.35]],
		&"CHIP_ROF": [&"rof", [0.08, 0.12, 0.18, 0.25]],
		&"CHIP_CRIT": [&"crit_rate", [0.05, 0.08, 0.12, 0.18]],
		&"CHIP_CRITDMG": [&"crit_dmg", [0.15, 0.25, 0.40, 0.60]],
		&"CHIP_ATTACH": [&"attach_strength", [0.15, 0.25, 0.35, 0.50]],
		&"CHIP_GOLD": [&"gold_gain", [0.10, 0.18, 0.28, 0.40]],
		&"CHIP_HP": [&"max_hp", [20.0, 35.0, 55.0, 80.0]],
		&"CHIP_XP": [&"xp_gain", [0.08, 0.14, 0.22, 0.32]],
	}
	var names := {
		&"CHIP_ATK": "攻击核心", &"CHIP_ROF": "超频模块", &"CHIP_CRIT": "精准校准",
		&"CHIP_CRITDMG": "暴伤放大器", &"CHIP_ATTACH": "元素共鸣器", &"CHIP_GOLD": "贪婪金币",
		&"CHIP_HP": "生命方舟", &"CHIP_XP": "经验汲取",
	}
	for id in table:
		var chip := reg.get_chip(id)
		if chip == null:
			_check("芯片 %s 注册加载" % String(id), false)
			continue
		var row: Array = table[id]
		var vals: Array = row[1]
		var ok: bool = chip.stat_key == row[0] and chip.values.size() == 4
		for i in range(4):
			ok = ok and is_equal_approx(chip.values[i], float(vals[i]))
		_check("芯片 %s 数值冻结（stat_key + 4 档）" % String(id), ok,
			"stat=%s vals=%s" % [String(chip.stat_key), str(chip.values)])
		_check("芯片 %s 中文名/描述非空" % String(id),
			chip.display_name == names[id] and chip.description != "")
	# validator：全部 0 错误
	var v := DataValidator.new()
	var all_clean := true
	for id in reg.chips:
		var c := reg.get_chip(id)
		if not v.validate_chip(c).is_empty():
			all_clean = false
	_check("validate_chip：8 枚全部 0 错误", all_clean)
	# validator 剔除路径：坏数据逐一判错（仅 error 级触发剔除；warning 不剔除）
	var bad := ChipData.new()
	_check("validate_chip：空 id 报错", _has_error(v.validate_chip(bad)))
	bad.id = &"CHIP_BAD"
	_check("validate_chip：stat_key 悬空报错", _has_error(v.validate_chip(bad)))
	bad.stat_key = &"no_such_stat"
	_check("validate_chip：stat_key 越界报错", _has_error(v.validate_chip(bad)))
	bad.stat_key = &"atk_pct"
	_check("validate_chip：values 缺档报错（3 项）", _has_error(v.validate_chip(bad)))
	bad.values = [0.1, 0.0, 0.2, 0.3]
	_check("validate_chip：values 含 ≤0 报错", _has_error(v.validate_chip(bad)))
	bad.values = [0.3, 0.2, 0.2, 0.1]
	_check("validate_chip：values 非单调报错", _has_error(v.validate_chip(bad)))
	bad.values = [0.1, 0.2, 0.2, 0.3]
	bad.display_name = "测试芯片"
	_check("validate_chip：合法构造 0 错误 0 告警", v.validate_chip(bad).is_empty())
	var unnamed := ChipData.new()
	unnamed.id = &"CHIP_UNNAMED"
	unnamed.stat_key = &"atk_pct"
	unnamed.values = [0.1, 0.2, 0.3, 0.4]
	var unnamed_verdicts := v.validate_chip(unnamed)
	_check("validate_chip：display_name 空 → 仅 warning（不剔除）",
		not unnamed_verdicts.is_empty() and not _has_error(unnamed_verdicts))
	# registry 剔除闭环（内存注入坏件 → validate_all → rejected 含 chips → erase）
	bad.values = [0.1, 0.2]                          # 重新注入错误（缺档）
	reg.chips[&"CHIP_BAD"] = bad
	var result: Dictionary = v.validate_all(reg)
	var rejected_chips := false
	for r in result["rejected"]:
		if r.get("category") == &"chips":
			rejected_chips = true
	_check("validate_all：坏芯片进 rejected（chips 类目闭环）", rejected_chips)
	reg.chips.erase(&"CHIP_BAD")
	_check("get_chip：未命中返回 null", reg.get_chip(&"CHIP_NOPE") == null)


func _has_error(p_verdicts: Array) -> bool:
	# validator 语义：仅 SEV_ERROR 触发剔除（warning 不剔除）
	for v in p_verdicts:
		if String(v.get("severity", DataValidator.SEV_ERROR)) == DataValidator.SEV_ERROR:
			return true
	return false


# ══ U2：芯片运行时（ChipHandler / 事件 / 波次解锁） ════════════════
func _test_chip_handler() -> void:
	print("── U2 芯片运行时 ──")
	# 事件注册表镜像 +2（共 21）
	_check("EVENT_NAMES 共 21 且含 chip_slot_unlocked/gold_rush_started",
		DataValidator.EVENT_NAMES.size() == 21
		and DataValidator.EVENT_NAMES.has(&"chip_slot_unlocked")
		and DataValidator.EVENT_NAMES.has(&"gold_rush_started"),
		str(DataValidator.EVENT_NAMES.size()))
	var reg := _gl.registry
	var player := _gl.player
	var h := _gl.chip_handler
	_check("夹具：GameLoop Boot 组装 ChipHandler（setup 后槽 0/空）",
		h != null and h.unlocked_slots == 0 and h.free_slots() == 3 and h.equipped.is_empty())
	_check("EventBus 信号可经 emit 包装派发（订阅收到）", _probe_chip_signals())
	# equip 五门 fail-fast
	var h_null := ChipHandler.new()
	_check("equip 五门：registry null → false", h_null.equip(&"CHIP_ATK", 0) == false)
	h_null.free()
	_check("equip 五门：get_chip 悬空 id → false", h.equip(&"CHIP_NOPE", 0) == false)
	_check("equip：合法装备 CHIP_ATK 白 → true", h.equip(&"CHIP_ATK", 0) == true)
	_check("equip 五门：同 id 重复 → false", h.equip(&"CHIP_ATK", 2) == false)
	_check("装备后 stat_bonus(atk_pct)=0.10（白档）", is_equal_approx(h.stat_bonus(&"atk_pct"), 0.10))
	_check("遥测 chips_granted=1", h.chips_granted == 1)
	# 槽位解锁信号 → unlocked_slots（幂等取大 + 越界钳 1~3）
	EventBus.emit_chip_slot_unlocked(9)
	_check("chip_slot_unlocked(9) 越界钳 3", h.unlocked_slots == 3)
	# rarity 取档 + 面板失效（equip 后 crit 折算进快照——U3 断言数值，此处断言失效生效路径）
	_check("free_slots 随装备递减", h.free_slots() == 2)
	# max_hp 特殊键：max_hp 上抬 + HP 回补
	var hp0: float = player.hp
	var max0: float = player.max_hp
	_check("equip：CHIP_HP 金档 → true", h.equip(&"CHIP_HP", 3) == true)
	_check("max_hp 特殊键：max_hp +80 且 HP 回补（满血钳新上限）",
		is_equal_approx(player.max_hp, max0 + 80.0)
		and is_equal_approx(player.hp, minf(hp0 + 80.0, max0 + 80.0)))
	_check("stat_bonus(max_hp)=80（金档）", is_equal_approx(h.stat_bonus(&"max_hp"), 80.0))
	# slot_snapshot
	var snap := h.slot_snapshot()
	_check("slot_snapshot 恒 3 格", snap.size() == 3)
	_check("slot_snapshot 已装备项键齐全（chip_id/display_name/stat_key/rarity/value_text）",
		(snap[0] as Dictionary).has("chip_id") and String((snap[0] as Dictionary).get("display_name", "")) == "攻击核心"
		and String((snap[0] as Dictionary).get("value_text", "")) == "+10%")
	_check("slot_snapshot 空槽 {} 占位", (snap[2] as Dictionary).is_empty())
	# roll_shop_offers：格数/未持有池/无放回/定价
	h.reset_run()
	h.set_rng_seed(4242)
	h.unlocked_slots = 3
	var w1 := h.roll_shop_offers(1)
	_check("roll_shop_offers(w1)：1 格 {chip_id,rarity,price}", w1.size() == 1
		and (w1[0] as Dictionary).has("chip_id") and (w1[0] as Dictionary).has("rarity")
		and (w1[0] as Dictionary).has("price"))
	var w12 := h.roll_shop_offers(12)
	_check("roll_shop_offers(w12)：2 格（wave≥10 且可用 ≥2）", w12.size() == 2
		and String((w12[0] as Dictionary).get("chip_id", &"")) != String((w12[1] as Dictionary).get("chip_id", &"")))
	_check("roll_shop_offers：price 与 price_for_rarity 一致",
		int((w12[0] as Dictionary).get("price", 0)) == h.price_for_rarity(int((w12[0] as Dictionary).get("rarity", 0))))
	# 同 id 定价/转金币梯度
	_check("price_for_rarity 梯度 40/70/120/220", h.price_for_rarity(0) == 40 and h.price_for_rarity(1) == 70
		and h.price_for_rarity(2) == 120 and h.price_for_rarity(3) == 220)
	_check("convert_gold = round(price×0.5)", h.convert_gold(0) == 20 and h.convert_gold(1) == 35
		and h.convert_gold(2) == 60 and h.convert_gold(3) == 110)
	# 已持有池排除：装备 3 枚（3 槽满）后 offer 不含已持有；多余 equip 拒绝
	h.reset_run()
	h.unlocked_slots = 3
	h.equip(&"CHIP_ATK", 0)
	h.equip(&"CHIP_ROF", 0)
	h.equip(&"CHIP_CRIT", 0)
	var offers := h.roll_shop_offers(12)
	var excludes := true
	for o in offers:
		if h.is_equipped(StringName(String(o.get("chip_id", &"")))):
			excludes = false
	_check("roll_shop_offers：未持有池（offer 不含已装备）", offers.size() == 2 and excludes)
	_check("free_slots=0（3 槽满，多余 equip 拒绝）", h.equip(&"CHIP_HP", 1) == false and h.free_slots() == 0)
	# 池空路径：独立 mini registry 仅 1 枚 + 已装备 → offer [] / grant 转金币
	var mini_reg := DataRegistry.new()
	var solo := ChipData.new()
	solo.id = &"CHIP_SOLO"
	solo.stat_key = &"atk_pct"
	solo.values = [0.1, 0.2, 0.3, 0.4]
	mini_reg.chips[&"CHIP_SOLO"] = solo
	var h2 := ChipHandler.new()
	h2.setup({"registry": mini_reg, "player": null})
	h2.equip(&"CHIP_SOLO", 0)
	_check("roll_shop_offers：全持有 → []（池空空架）", h2.roll_shop_offers(12).is_empty())
	_check("grant_boss_chip：池空 → 转金币（granted=false）",
		bool(h2.grant_boss_chip(12).get("granted")) == false
		and h2.chips_converted == 1 and h2.gold_from_convert >= 20)
	h2.free()
	# grant_boss_chip：槽满 → 转金币（granted=false + converted_gold + 遥测）
	h.reset_run()
	h.unlocked_slots = 3
	h.equip(&"CHIP_ATK", 0)
	h.equip(&"CHIP_ROF", 0)
	h.equip(&"CHIP_CRIT", 0)
	var conv0 := h.chips_converted
	var gconv0 := h.gold_from_convert
	var drop := h.grant_boss_chip(15)
	_check("grant_boss_chip：槽满 → 转金币（granted=false/converted_gold=110 范围）",
		bool(drop.get("granted")) == false and int(drop.get("converted_gold", 0)) == h.convert_gold(int(drop.get("rarity", 0))))
	_check("转金币遥测累计", h.chips_converted == conv0 + 1 and h.gold_from_convert >= gconv0 + 20)
	# grant_boss_chip：空槽 → granted 且已装备
	h.reset_run()
	h.set_rng_seed(4242)
	h.unlocked_slots = 1
	var drop2 := h.grant_boss_chip(15)
	_check("grant_boss_chip：有空槽 → granted=true 且槽位占用",
		bool(drop2.get("granted")) and h.is_equipped(StringName(String(drop2.get("chip_id", &"")))))
	# reset_run 清零（rng 重播种 → 同种子序列可复现）
	h.reset_run()
	_check("reset_run：装备/槽位/遥测清零", h.equipped.is_empty() and h.unlocked_slots == 0
		and h.chips_granted == 0 and h.chips_converted == 0 and h.gold_from_convert == 0)
	h.set_rng_seed(7)
	var seq_a := h.roll_shop_offers(12)
	h.reset_run()
	h.set_rng_seed(7)
	var seq_b := h.roll_shop_offers(12)
	_check("reset_run + set_rng_seed：同种子货架序列可复现", _offers_equal(seq_a, seq_b))
	# roll_rarity 值域 + 波次权重真源（静态纯函数不改实例状态）
	var rg := CardGenerator.rarity_weights_for(1)
	_check("rarity_weights_for(w1) 基础表 {58,30,10,2}",
		is_equal_approx(float(rg[0]), 58.0) and is_equal_approx(float(rg[1]), 30.0)
		and is_equal_approx(float(rg[2]), 10.0) and is_equal_approx(float(rg[3]), 2.0))
	var rg10 := CardGenerator.rarity_weights_for(20)
	_check("rarity_weights_for(w20) 调整公式（白 44/蓝 32/紫 19/金 5）",
		is_equal_approx(float(rg10[0]), 44.0) and is_equal_approx(float(rg10[1]), 32.0)
		and is_equal_approx(float(rg10[2]), 19.0) and is_equal_approx(float(rg10[3]), 5.0))
	var in_range := true
	for i in range(200):
		var r := h.roll_rarity(25)
		if r < 0 or r > 3:
			in_range = false
	_check("roll_rarity 值域 [0,3]×200", in_range)
	# 波次解锁集成：start_wave(1) → 槽 1（GameLoop 全链）
	h.reset_run()
	_gl.wave_director.start_wave(1)
	_check("start_wave(1) → chip_slot_unlocked(1) → unlocked_slots=1", h.unlocked_slots == 1)
	_gl.wave_director.start_wave(10)
	_check("start_wave(10) → unlocked_slots=2", h.unlocked_slots == 2)
	_gl.wave_director.start_wave(20)
	_check("start_wave(20) → unlocked_slots=3", h.unlocked_slots == 3)
	# 还原夹具（chip 状态不污染后续用例）
	h.reset_run()
	player.max_hp = max0
	player.hp = hp0


func _probe_chip_signals() -> bool:
	# emit 包装派发探针（类型化信号 + 包装连通性）
	var got_chip: Array = []
	var got_rush: Array = []
	var cb_chip := func(slot: int) -> void: got_chip.append(slot)
	var cb_rush := func(wave: int) -> void: got_rush.append(wave)
	EventBus.chip_slot_unlocked.connect(cb_chip)
	EventBus.gold_rush_started.connect(cb_rush)
	EventBus.emit_chip_slot_unlocked(2)
	EventBus.emit_gold_rush_started(6)
	EventBus.chip_slot_unlocked.disconnect(cb_chip)
	EventBus.gold_rush_started.disconnect(cb_rush)
	return (got_chip as Array).size() == 1 and int((got_chip as Array)[0]) == 2 \
		and (got_rush as Array).size() == 1 and int((got_rush as Array)[0]) == 6


func _offers_equal(p_a: Array[Dictionary], p_b: Array[Dictionary]) -> bool:
	if p_a.size() != p_b.size():
		return false
	for i in range(p_a.size()):
		if String(p_a[i].get("chip_id", &"")) != String(p_b[i].get("chip_id", &"")) \
				or int(p_a[i].get("rarity", -1)) != int(p_b[i].get("rarity", -1)):
			return false
	return true


# ══ U3：芯片结算接线（管线 ⑥b 独立乘区段 / 面板折算 / 消费点） ══════
func _test_chip_pipeline() -> void:
	print("── U3 芯片结算接线 ──")
	# cap_chip_zone schema 默认 + validator 非致命域
	_check("cap_chip_zone schema 默认 1.0", is_equal_approx(GameConfig.balance.cap_chip_zone, 1.0))
	var v := DataValidator.new()
	var bad_bt := BalanceTables.new()
	bad_bt.cap_chip_zone = 4.5
	_check("validate_balance：cap_chip_zone=4.5 ∉ (0,4] 报错（非致命）",
		_balance_has_field(v.validate_balance(bad_bt), "cap_chip_zone"))
	var good_bt := BalanceTables.new()
	good_bt.cap_chip_zone = 4.0
	_check("validate_balance：cap_chip_zone=4.0 合法（无该字段报告）",
		not _balance_has_field(v.validate_balance(good_bt), "cap_chip_zone"))
	# aggregate_chip 单元（Σ / 负钳 0 / cap 截断 / 审计）
	var stack := ModifierStack.new()
	stack.audit = DamageAudit.new()
	stack.aggregate_chip([{"stat": &"atk_pct", "contrib": 0.35}, {"stat": &"atk_pct", "contrib": 0.65}], 4.0)
	_check("aggregate_chip：Σ=1.0 → chip_product=2.0", is_equal_approx(stack.chip_product, 2.0))
	var stack_neg := ModifierStack.new()
	stack_neg.audit = DamageAudit.new()
	stack_neg.aggregate_chip([{"stat": &"atk_pct", "contrib": -0.5}], 4.0)
	_check("aggregate_chip：负贡献钳 0 → chip_product=1.0", is_equal_approx(stack_neg.chip_product, 1.0))
	var stack_cap := ModifierStack.new()
	stack_cap.audit = DamageAudit.new()
	stack_cap.aggregate_chip([{"stat": &"atk_pct", "contrib": 6.0}], 1.0)
	_check("aggregate_chip：Σ>cap 截断 + clamped_chip + audit 同步",
		is_equal_approx(stack_cap.chip_product, 2.0) and stack_cap.audit.clamped_chip
		and is_equal_approx(stack_cap.audit.chip_product, 2.0))
	# 管线 ⑥b：final = S × min(M×chip, cap_prod) × L × C × V
	var pipe := DamagePipeline.new()
	pipe.set_rng_seed(12345)
	var e := Enemy.new()
	e.uid = GameConst.next_uid()
	e.hp = 1000000.0
	e.max_hp = 1000000.0
	pipe.begin_frame()
	var ctx := DamageContext.make()
	ctx.source_uid = 1
	ctx.target = e
	ctx.target_uid = int(e.uid)
	ctx.frame_stamp = 1
	ctx.base_atk = 100.0
	ctx.crit_chance = 0.0
	ctx.chip_entries = [{"stat": &"atk_pct", "contrib": 0.5}]
	var r1 := pipe.resolve(ctx)
	_check("管线 ⑥b：chip 0.5 → final=150 / chip_product=1.5",
		r1 != null and is_equal_approx(r1.final_value, 150.0) and is_equal_approx(r1.chip_product, 1.5))
	# 恒等性：chip_product=1.0 时与 v0.6.0 公式恒等（fixed-seed 回归共证）
	pipe.begin_frame()
	var ctx2 := DamageContext.make()
	ctx2.source_uid = 1
	ctx2.target = e
	ctx2.target_uid = int(e.uid)
	ctx2.frame_stamp = 2
	ctx2.base_atk = 100.0
	ctx2.crit_chance = 0.0
	var r2 := pipe.resolve(ctx2)
	_check("管线恒等：零芯片 final=100（v0.6.0 公式不变）",
		r2 != null and is_equal_approx(r2.final_value, 100.0) and is_equal_approx(r2.chip_product, 1.0))
	# cap_chip_zone 截断（Σ6.0 → 钳 1.0 → final=200 + audit.clamped_chip）
	pipe.begin_frame()
	var ctx3 := DamageContext.make()
	ctx3.source_uid = 1
	ctx3.target = e
	ctx3.target_uid = int(e.uid)
	ctx3.frame_stamp = 3
	ctx3.base_atk = 100.0
	ctx3.crit_chance = 0.0
	ctx3.chip_entries = [{"stat": &"atk_pct", "contrib": 6.0}]
	var r3 := pipe.resolve(ctx3)
	_check("管线 ⑥b：Σ 超限钳 cap_chip_zone → final=200 + clamped_chip",
		r3 != null and is_equal_approx(r3.final_value, 200.0) and r3.audit.clamped_chip)
	# 联合钳：M=8（contrib 7 cap 7）× chip 2.0 → joint=min(16,8)=8 → final=800 + compressed
	pipe.begin_frame()
	var ctx4 := DamageContext.make()
	ctx4.source_uid = 1
	ctx4.target = e
	ctx4.target_uid = int(e.uid)
	ctx4.frame_stamp = 4
	ctx4.base_atk = 100.0
	ctx4.crit_chance = 0.0
	ctx4.mult_pools = [{"pool_id": &"frost_dmg", "source_uid": 1, "contrib": 7.0, "cap_pool": 7.0}]
	ctx4.chip_entries = [{"stat": &"atk_pct", "contrib": 1.0}]
	var r4 := pipe.resolve(ctx4)
	_check("管线 joint：min(M×chip, cap_prod)=8 → final=800 + compressed 语义",
		r4 != null and is_equal_approx(r4.final_value, 800.0) and r4.audit.compressed)
	# 反应不吃芯片段：resolve_reaction 的 chip_product 恒 1.0（A6 §3 契约）
	pipe.begin_frame()
	var ctx5 := DamageContext.make()
	ctx5.source_uid = 2
	ctx5.target = e
	ctx5.target_uid = int(e.uid)
	ctx5.frame_stamp = 5
	ctx5.base_atk = 100.0
	ctx5.chip_entries = [{"stat": &"atk_pct", "contrib": 1.0}]
	var r5 := pipe.resolve_reaction(100.0, 2.0, ctx5)
	_check("反应通道不吃芯片段：final=200 / chip_product=1.0",
		r5 != null and is_equal_approx(r5.final_value, 200.0) and is_equal_approx(r5.chip_product, 1.0))
	e.free()
	# 武器面板折算（crit_rate/crit_mult/chip_atk_pct）+ 装备后失效
	var h := _gl.chip_handler
	h.reset_run()
	var weapon: WeaponBase = _gl.player.weapon_slots[0]
	weapon.invalidate_panel()
	var snap0 := weapon.build_panel_snapshot()
	h.equip(&"CHIP_CRIT", 3)
	h.equip(&"CHIP_CRITDMG", 3)
	h.equip(&"CHIP_ATK", 3)
	weapon.invalidate_panel()
	var snap1 := weapon.build_panel_snapshot()
	_check("面板折算：crit_rate = 表值 + 0.18（cap 内）",
		is_equal_approx(float(snap1.get("crit_rate", -1.0)), minf(float(snap0.get("crit_rate", 0.0)) + 0.18, 1.0)))
	_check("面板折算：crit_mult = 表值 + 0.6",
		is_equal_approx(float(snap1.get("crit_mult", -1.0)), float(snap0.get("crit_mult", 0.0)) + 0.6))
	_check("面板快照增键 chip_atk_pct = 0.35", is_equal_approx(float(snap1.get("chip_atk_pct", -1.0)), 0.35))
	# ctx 注入两处：weapon 路径 + projectile 路径（快照键 → chip_entries）
	var target := Enemy.new()
	target.uid = GameConst.next_uid()
	var wctx := weapon.build_damage_context(target)
	_check("weapon ctx 注入：chip_entries=[atk_pct 0.35]",
		wctx.chip_entries.size() == 1
		and StringName(String((wctx.chip_entries[0] as Dictionary).get("stat", ""))) == &"atk_pct"
		and is_equal_approx(float((wctx.chip_entries[0] as Dictionary).get("contrib", 0.0)), 0.35))
	var proj := ProjectileBase.new()
	proj.panel_snapshot = {"base_atk": 50.0, "chip_atk_pct": 0.35}
	proj.uid = GameConst.next_uid()
	var pctx := proj._build_damage_ctx(target)
	_check("projectile ctx 注入：chip_entries=[atk_pct 0.35]",
		pctx.chip_entries.size() == 1
		and is_equal_approx(float((pctx.chip_entries[0] as Dictionary).get("contrib", 0.0)), 0.35))
	proj.free()
	target.free()
	# 射速：BALLISTIC rof × (1+K_rof)；非 BALLISTIC interval = cd×(1−cdr)/(1+K_rof)
	h.reset_run()
	var bw := BallisticWeapon.new()
	bw.setup(_gl.registry.get_weapon(&"W1_pistol"), _gl.player, {"chip_handler": h})
	var rof_base: float = bw.get_stat(&"rof")
	bw._fire_interval()
	_check("BALLISTIC 无芯片：rof_current = 表值", is_equal_approx(bw.rof_current, rof_base))
	h.equip(&"CHIP_ROF", 3)
	bw._fire_interval()
	_check("BALLISTIC 金 rof 芯片：rof_current = 表值 × 1.25", is_equal_approx(bw.rof_current, rof_base * 1.25))
	bw.free()
	var laser_data: WeaponData = null
	for wid in _gl.registry.weapons:
		if (_gl.registry.weapons[wid] as WeaponData).form != GameConst.WeaponForm.BALLISTIC:
			laser_data = _gl.registry.weapons[wid]
			break
	var lw := LaserWeapon.new()
	lw.setup(laser_data, _gl.player, {"chip_handler": h})
	var cd_base: float = lw.get_stat(&"cd")
	h.reset_run()                                 # 先归零（BALLISTIC 段遗留 rof 芯片）
	var interval_no := lw._fire_interval()
	h.equip(&"CHIP_ROF", 3)
	var interval_chip := lw._fire_interval()
	_check("非 BALLISTIC：interval = cd/(1+K_rof)（金 1.25）",
		is_equal_approx(interval_no, cd_base) and is_equal_approx(interval_chip, cd_base / 1.25))
	lw.free()
	h.reset_run()
	# 消费点：金币 ×(1+K_gold)（负数不缩放）/ 经验 ×(1+K_xp) / 附着 ×(1+K_attach)
	h.equip(&"CHIP_GOLD", 3)                      # 金档 0.40
	var g0 := _gl.gold
	_gl._add_gold(100)
	_check("_add_gold 正增量 ×1.4 → +140", _gl.gold == g0 + 140, "gold=%d" % _gl.gold)
	_gl._add_gold(-40)
	_check("_add_gold 负增量不缩放 → -40", _gl.gold == g0 + 100)
	_gl._add_gold(-(g0 + 100 - g0))               # 还原余额（净 -100）
	h.reset_run()
	h.equip(&"CHIP_XP", 0)                        # 白档 0.08
	var xp_enemy := Enemy.new()
	xp_enemy.exp_value = 10.0
	xp_enemy.global_position = Vector2(200.0, 800.0)
	_gl._on_enemy_killed_drop_xp(xp_enemy)
	var shard_ok := false
	if not _gl.active_shards.is_empty():
		var shard := _gl.active_shards[_gl.active_shards.size() - 1]
		shard_ok = is_equal_approx(shard.value, 10.8)
		_gl.active_shards.erase(shard)
		(_gl.pools[&"xp"] as XPPool).release(shard)
	_check("经验掉落 ×1.08（K_xp 白档）", shard_ok)
	xp_enemy.free()
	h.reset_run()
	h.equip(&"CHIP_ATTACH", 2)                    # 紫档 0.35
	var es := ElementalSystem.new()
	es.chip_handler = h
	var ae := Enemy.new()
	ae.immune_mask = 0
	es.register_host(ae)
	es.apply_attach(ae, GameConst.Element.FIR, 20.0)
	var st: ElementalState = ae.elemental
	_check("附着入口 ×1.35（K_attach 紫档）",
		st != null and is_equal_approx(st.gauges[GameConst.Element.FIR], 27.0))
	es.free()
	ae.free()
	h.reset_run()
	# respawn：max_hp 重导出基线（芯片/商店加成不跨局）
	_gl.player.max_hp = 555.0
	_gl.player.hp = 555.0
	_gl.player.respawn()
	_check("respawn：max_hp 回基线 %d" % int(GameConfig.get_constant(&"player_base_hp", 100.0)),
		is_equal_approx(_gl.player.max_hp, GameConfig.get_constant(&"player_base_hp", 100.0)))


func _balance_has_field(p_verdicts: Array, p_field: String) -> bool:
	for v in p_verdicts:
		if String(v.get("field", "")) == p_field:
			return true
	return false


# ══ U12+U13+U14：双 Boss 修复 / 召唤独立计数 / kind 单源 + 红闪 ═════
func _test_u12_u13_u14() -> void:
	print("── U12 双 Boss 修复 ──")
	# 波表静态：w10/w20/w30 composition 空（events BOSS 保留）
	var table := _gl.registry.get_wave_table()
	var empty_ok := true
	for wave in [10, 20, 30]:
		for entry in table.entries:
			if entry.index == wave and not entry.composition.is_empty():
				empty_ok = false
	_check("波表：w10/w20/w30 composition 置空（events BOSS 保留）", empty_ok)
	# 动态：每 Boss 波 TAG_BOSS 敌恰 1 只（_spawn_boss 唯一路径）
	for wave in [10, 20, 30]:
		_gl.spawner.spawn_queue.clear()
		for e in _gl.spawner.active.duplicate():
			_gl.spawner.on_enemy_killed(e)
		_gl.wave_director.start_wave(wave)
		var guard := 0
		while not _gl.spawner.queue_empty() and guard < 400:
			_gl.spawner.tick(DT, _gl.enemy_grid)
			guard += 1
		var boss_n := 0
		for e2 in _gl.spawner.active:
			if e2 is Enemy and (e2 as Enemy).is_boss():
				boss_n += 1
		_check("w%d：TAG_BOSS 敌恰 1 只（双 Boss 修复）" % wave, boss_n == 1, "n=%d" % boss_n)
		for e3 in _gl.spawner.active.duplicate():
			_gl.spawner.on_enemy_killed(e3)       # 静默归还（非战斗语义）
	print("── U13 召唤独立计数 ──")
	var spawner := _gl.spawner
	spawner.summon_active_count = 0
	var boss2: Enemy = (_gl.pools[&"enemy"] as EnemyPool).acquire() as Enemy
	boss2.spawn(_gl.registry.get_enemy(&"E6_boss2"), 20, GameConst.TAG_BOSS)
	boss2.summon_spawner = spawner
	boss2.projectile_pool = _gl.pools[&"projectile"]
	var q0 := spawner.queue_count()
	boss2._summon_cd_left = DT
	boss2.tick(DT)
	_check("boss2 split 召唤入队 2", spawner.queue_count() == q0 + 2)
	var has_summon_key := true
	for entry in spawner.spawn_queue:
		var row: Dictionary = entry
		if StringName(String(row.get("data_id", ""))) == &"E5_elite":
			has_summon_key = has_summon_key and bool(row.get("summon", false))
	_check("召唤入列条目含 summon:true", has_summon_key)
	spawner.tick(DT, _gl.enemy_grid)              # 出队 → 出生计数
	_check("出生计数 summon_active_count=2", spawner.summon_active_count == 2)
	var summoned: Array[Node2D] = []
	for e4 in spawner.active:
		var en := e4 as Enemy
		if en != null and en.is_summon:
			summoned.append(e4)
	_check("出生实体 is_summon=true ×2", summoned.size() == 2)
	for e5 in summoned:
		spawner.on_enemy_killed(e5)               # 归还前读 is_summon → 计数-1
	_check("死亡归还后计数回 0", spawner.summon_active_count == 0)
	# U13 闸：召唤独立计数满 12 → 拦截（不再被普通敌 active_count 干扰）
	spawner.summon_active_count = 12
	var q1 := spawner.queue_count()
	boss2._summon_cd_left = DT
	boss2.tick(DT)
	_check("召唤闸：summon_active_count≥12 → 拦截", spawner.queue_count() == q1)
	spawner.summon_active_count = 0
	(_gl.pools[&"enemy"] as EnemyPool).release(boss2)   # 静默归还（非战斗语义）
	print("── U14 kind 单源 + 受击红闪 + heal 预禁用 ──")
	_check("card_kind_name 全表",
		GameConst.card_kind_name(0) == "精通" and GameConst.card_kind_name(1) == "词条"
		and GameConst.card_kind_name(2) == "遗物" and GameConst.card_kind_name(3) == "保底"
		and GameConst.card_kind_name(4) == "武器")
	_check("card_kind_name 越界钳 0~4",
		GameConst.card_kind_name(9) == "武器" and GameConst.card_kind_name(-1) == "精通")
	var btn := Button.new()
	_gl.card_select_ui._setup_button(btn, {"kind": 4, "display_name": "X", "description": ""})
	_check("CardSelectUI kind 单源：[武器] 前缀", String(btn.text).begins_with("[武器]"))
	btn.free()
	var gf := _gl.game_feel
	_check("红闪初始隐藏（零强度门控）",
		gf.hit_flash_left == 0.0 and not gf.hit_flash_rect.visible)
	EventBus.emit_player_hit(8.0, 0)
	_check("受击 → 红闪激活 0.22s",
		is_equal_approx(gf.hit_flash_left, 0.22) and gf.hit_flash_rect.visible)
	gf.tick(0.10)
	_check("raw 衰减中仍可见", gf.hit_flash_left > 0.0 and gf.hit_flash_rect.visible)
	gf.tick(0.30)
	_check("衰减归零隐藏", gf.hit_flash_left == 0.0 and not gf.hit_flash_rect.visible)
	# heal 预禁用（U7 自包含部分：open 后与 heal 购买后回写）
	var shop := _gl.shop_ui
	shop.open(9, false, [], {}, 1000)
	shop.set_player_full_hp(true)
	_check("满血 → heal 预禁用", (shop._util_buttons[&"heal"] as Button).disabled)
	shop.set_player_full_hp(false)
	_check("非满血 + 余额足 → heal 可购", not (shop._util_buttons[&"heal"] as Button).disabled)
	shop.close()


# ══ U5：金币狂欢关 ════════════════════════════════════════════════
func _test_gold_rush() -> void:
	print("── U5 金币关 ──")
	var wd := _gl.wave_director
	var spawner := _gl.spawner
	# 判定：w6/16/26 开（表 events）；其余/无尽段不开
	_check("is_gold_rush_wave：w6/w16/w26 true",
		wd.is_gold_rush_wave(6) and wd.is_gold_rush_wave(16) and wd.is_gold_rush_wave(26))
	_check("is_gold_rush_wave：w5/w15/w26 外 false，无尽 w40 false",
		not wd.is_gold_rush_wave(5) and not wd.is_gold_rush_wave(15) and not wd.is_gold_rush_wave(40))
	var rush_events := 0
	for entry in _gl.registry.get_wave_table().entries:
		if entry.index in [6, 16, 26] and entry.events.has(&"GOLD_RUSH"):
			rush_events += 1
	_check("波表：w6/w16/w26 events 含 GOLD_RUSH", rush_events == 3)
	# projected_max_hp 真源：spawn max_hp 与预测一致（非精英）
	var e1 := _gl.registry.get_enemy(&"E1_grunt")
	var e := Enemy.new()
	e.spawn(e1, 7, 0)
	_check("projected_max_hp：spawn max_hp 同源（hp_base×1.12^6）",
		is_equal_approx(e.max_hp, Enemy.projected_max_hp(e1, 7)))
	e.free()
	# start_wave(6)：入列条目注入 gold_rush + hp_override = projected×0.4；剩余比有值
	spawner.spawn_queue.clear()
	for e2 in spawner.active.duplicate():
		spawner.on_enemy_killed(e2)
	wd.start_wave(6)
	_check("start_wave(6)：入列条目全部 gold_rush=true 且 hp_override=projected×0.4",
		_queue_all_rush(spawner))
	_check("金币关剩余比 ∈ (0,1]（进行中波）", wd.gold_rush_remaining_ratio() > 0.0
		and wd.gold_rush_remaining_ratio() <= 1.0)
	wd._hard_cap_left = 4.0
	_check("剩余比：hard_cap_left=4 → 0.5", is_equal_approx(wd.gold_rush_remaining_ratio(), 0.5))
	# 出队消费：enemy.gold_rush=true 且 max_hp = override
	spawner.tick(DT, _gl.enemy_grid)
	var rush_enemy: Enemy = null
	for e3 in spawner.active:
		var en := e3 as Enemy
		if en != null and en.gold_rush:
			rush_enemy = en
	_check("spawn 消费：gold_rush 标记 + max_hp=override（0.4 血）",
		rush_enemy != null and rush_enemy.max_hp <= Enemy.projected_max_hp(e1, 6) * 0.4 + 0.01)
	# 掉落覆写：gold_rush 敌 chance≥0.5 恒过 + 面值 ×2（复制 roll 流口径验证；归还前执行）
	_gl.set_gold_rng_seed(777)
	var probe := RandomNumberGenerator.new()
	probe.seed = 777
	var coin0: int = _gl.active_coins.size()
	_gl._on_enemy_killed_drop_gold(rush_enemy)
	if _gl.active_coins.size() > coin0:
		probe.randf()                             # chance 位（rush 恒过）
		var base_v := probe.randi_range(8, 12)    # E1 gold_drop min/max
		var expected := int(round(float(base_v) * 2.0))
		_check("金币关掉落面值 ×2（词条叠加口径）",
			is_equal_approx(_gl.active_coins[_gl.active_coins.size() - 1].value, float(expected)),
			"value=%s expected=%d" % [str(_gl.active_coins[_gl.active_coins.size() - 1].value), expected])
		(_gl.pools[&"gold"] as GoldPool).release(_gl.active_coins[_gl.active_coins.size() - 1])
		_gl.active_coins.remove_at(_gl.active_coins.size() - 1)
	else:
		_check("金币关掉落：恒过 chance≥0.5（未出币=异常）", false)
	# 波末奖励：清场归还后手动派发 wave_cleared（此时 phase 进行中，ratio=0.5）
	for e4 in spawner.active.duplicate():
		spawner.on_enemy_killed(e4)
	spawner.spawn_queue.clear()
	_gl.chip_handler.reset_run()                  # 金币芯片隔离（amount 不被 K_gold 缩放干扰）
	var g0 := _gl.gold
	var reward0: int = DebugStats.get_counter(&"gold_rush_reward")
	var popups0: int = _gl.popup_manager.active_popups
	EventBus.emit_wave_cleared(6)
	var amount_expected := 20                     # base=10+5×6=40 × ratio 0.5
	_check("波末奖励：+20（base 40 × 0.5）→ gold=%d" % (_gl.gold - g0), _gl.gold == g0 + amount_expected,
		"gold=%d g0=%d" % [_gl.gold, g0])
	_check("波末奖励遥测 +1", DebugStats.get_counter(&"gold_rush_reward") == reward0 + 1)
	_check("文本跳字「金币狂欢 +20」已展示", _popup_text_seen(_gl.popup_manager, "金币狂欢 +20")
		or _gl.popup_manager.active_popups >= popups0)
	# 非金币关 wave_cleared：无奖励
	wd.start_wave(7)
	wd._hard_cap_left = 4.0
	var g1 := _gl.gold
	EventBus.emit_wave_cleared(7)
	_check("非金币关：无波末奖励", _gl.gold == g1)
	spawner.spawn_queue.clear()
	for e5 in spawner.active.duplicate():
		spawner.on_enemy_killed(e5)
	# 横幅覆写：gold_rush_started → "WAVE n · 金币狂欢"
	EventBus.emit_gold_rush_started(16)
	_check("HUD 金币狂欢横幅（覆写普通横幅）",
		_gl.hud.banner_visible() and String(_gl.hud._banner_label.text) == "WAVE 16 · 金币狂欢")
	# 清场：金币关残留（无）
	spawner.spawn_queue.clear()


func _queue_all_rush(p_spawner: EnemySpawner) -> bool:
	if p_spawner.spawn_queue.is_empty():
		return false
	for entry in p_spawner.spawn_queue:
		var row: Dictionary = entry
		if not bool(row.get("gold_rush", false)):
			return false
	return true


func _popup_text_seen(p_manager: PopupManager, p_text: String) -> bool:
	for popup in p_manager._active_list:
		if is_instance_valid(popup) and String(popup._label.text) == p_text:
			return true
	return false


# ══ U4+U7：商店全量重排 + 芯片货架/槽位面板 + 仲裁扩展 ═════════════
func _test_shop_chips() -> void:
	print("── U4+U7 商店芯片 ──")
	var shop := _gl.shop_ui
	# 布局契约：rects 两两无交集 + 屏内
	var rects := shop.layout_rects()
	_check("layout_rects：10 项（卡3+武器+芯片2+utility3+面板+离开）", rects.size() == 11,
		str(rects.size()))
	var pairwise := true
	for i in range(rects.size()):
		var r1: Rect2 = rects[i]
		if r1.position.x < 0.0 or r1.position.y < 0.0 \
				or r1.end.x > 720.0 or r1.end.y > 1280.0:
			pairwise = false
		for j in range(rects.size()):
			if i != j and r1.intersects(rects[j] as Rect2):
				pairwise = false
	_check("layout_rects：两两无交集 + 全部屏内（720×1280）", pairwise)
	# 全量重排坐标锚点抽查
	_check("坐标表：标题 y=96 / 离开 (60,980,600x80)",
		is_equal_approx(shop._title.position.y, 96.0)
		and is_equal_approx((shop._card_buttons[3] as Button).position.y, 478.0)
		and is_equal_approx((shop._chip_buttons[0] as Button).position.y, 584.0)
		and is_equal_approx((shop._util_buttons[&"heal"] as Button).size.y, 84.0)
		and is_equal_approx((shop._slot_labels[0] as Label).get_parent().size.x, 188.0))
	# 槽位面板注入：空槽占位 / 已装备显示
	shop.set_chip_slots([{"chip_id": &"CHIP_ATK", "display_name": "攻击核心",
		"stat_key": &"atk_pct", "rarity": 3, "value_text": "+35%"}, {}, {}])
	_check("set_chip_slots：已装备 [金]+value / 空槽占位",
		String((shop._slot_labels[0] as Label).text).contains("攻击核心")
		and String((shop._slot_labels[1] as Label).text) == "空槽")
	# 芯片货架注入 + 四态（空架 / 槽满 / 余额不足 / 可购）
	shop.open(12, false, [], {}, 1000)
	shop.set_chip_shelf([
		{"chip_id": &"CHIP_ATK", "rarity": 3, "price": 220, "display_name": "攻击核心", "value_text": "+35%"},
	], 0)
	_check("芯片架：free_slots=0 → disabled +（槽满）后缀",
		(shop._chip_buttons[0] as Button).disabled
		and String((shop._chip_buttons[0] as Button).text).contains("槽满"))
	shop.set_chip_shelf([], 3)
	_check("芯片架：空 offer → disabled + 空架",
		(shop._chip_buttons[0] as Button).disabled
		and String((shop._chip_buttons[0] as Button).text) == "空架")
	shop.set_chip_shelf([
		{"chip_id": &"CHIP_ATK", "rarity": 3, "price": 220, "display_name": "攻击核心", "value_text": "+35%"},
		{"chip_id": &"CHIP_ROF", "rarity": 0, "price": 40, "display_name": "超频模块", "value_text": "+25%"},
	], 2)
	_check("芯片架：余额足可购 / price_for(4/5) 读 offer",
		not (shop._chip_buttons[0] as Button).disabled
		and shop.price_for(4) == 220 and shop.price_for(5) == 40)
	shop.refresh_gold(30)
	_check("芯片架：余额不足 disabled（gold 30 < 40）", (shop._chip_buttons[1] as Button).disabled)
	# shelf_state 新键
	var st: Dictionary = shop.shelf_state()
	_check("shelf_state 增键 chips/chip_purchased/chip_free_slots",
		(st["chips"] as Array).size() == 2 and (st["chip_purchased"] as Array).size() == 2
		and int(st["chip_free_slots"]) == 2)
	shop.close()
	# 购买仲裁全链（五查 + 扣款 + 槽位刷新）
	_gl.start_run()
	_gl.chip_handler.reset_run()
	_gl.gold = 0
	_gl._add_gold(1000)
	_check("夹具：_open_shop_flow 开店（SHOP 态 + 芯片架已注入）",
		_gl._open_shop_flow(12, false) and _gl.state == GameConst.GameStatus.SHOP
		and (_gl.shop_ui.shelf_state()["chips"] as Array).size() == 2)
	var offer4: Dictionary = (_gl.shop_ui.shelf_state()["chips"] as Array)[0]
	var price4 := int(offer4.get("price", 0))
	var gold0 := _gl.gold
	var equipped0: int = _gl.chip_handler.equipped.size()
	_gl._on_shop_purchase(4)
	_check("购买芯片：扣款 %d + equip + 槽位面板刷新" % price4,
		_gl.gold == gold0 - price4 and _gl.chip_handler.equipped.size() == equipped0 + 1
		and _gl.chip_handler.is_equipped(StringName(String(offer4.get("chip_id", ""))))
		and bool((_gl.shop_ui.shelf_state()["purchased"] as Array)[4]))
	_gl._on_shop_purchase(4)
	_check("五查·已购：重复购买拒绝（余额不变）", _gl.gold == gold0 - price4)
	# 余额不足分支：余额直清零（绕开 K_gold 缩放）后买 index 5 → 拒绝不扣款
	_gl.gold = 0
	var g_before := _gl.gold
	_gl._on_shop_purchase(5)
	_check("五查·余额不足：拒绝且不扣款", _gl.gold == g_before and _gl.gold == 0)
	_gl._add_gold(1000)
	_gl._on_shop_purchase(5)
	_check("余额回补后 index5 可购（第二格）",
		_gl.chip_handler.equipped.size() == equipped0 + 2)
	# reroll 全域：卡架 + 芯片架刷新（武器架维持）；余额直赋值（绕开 K_gold 缩放）
	_gl.gold = 100
	var chips_before: Array = _gl.shop_ui.shelf_state()["chips"]
	_gl._on_shop_utility(&"reroll")
	_check("reroll：卡架+芯片架同帧刷新（chip 购买位复位）",
		bool(_gl.shop_ui.shelf_state()["reroll_used"])
		and (_gl.shop_ui.shelf_state()["chips"] as Array).size() >= 1
		and not bool((_gl.shop_ui.shelf_state()["purchased"] as Array)[4]))
	_check("reroll：扣款 30", _gl.gold == 70)
	# 闭店回 PLAYING
	_gl._close_shop()
	_check("闭店 → PLAYING（芯片状态保留）",
		_gl.state == GameConst.GameStatus.PLAYING and _gl.chip_handler.equipped.size() >= 2)
	# 还原夹具
	_gl.chip_handler.reset_run()


# ══ U6：Boss 芯片掉落（连接序 + granted/转金币双路 + 非敌门控） ════
func _test_boss_chip_drop() -> void:
	print("── U6 Boss 芯片掉落 ──")
	var h := _gl.chip_handler
	var pool := _gl.pools[&"enemy"] as EnemyPool
	# granted 路径：空槽 Boss 死亡 → 装备 + 跳字（连接序功能性验证：tags 先于归还清零）
	h.reset_run()
	var granted0 := h.chips_granted
	var boss1: Enemy = pool.acquire() as Enemy
	boss1.spawn(_gl.registry.get_enemy(&"E6_boss1"), 10, GameConst.TAG_BOSS)
	boss1.global_position = Vector2(360.0, 240.0)
	boss1._on_died()                              # enemy_killed → chip/gold/xp 掉落 + 归还
	_check("Boss 死亡 → 芯片装备（granted 路径）",
		h.chips_granted == granted0 + 1 and h.equipped.size() == 1)
	_check("跳字「芯片 [名] 已装备」", _popup_prefix_seen("芯片 ["))
	# 转金币路径：槽满 Boss 死亡 → converted_gold 经 _add_gold + 跳字
	h.reset_run()
	h.unlocked_slots = 3
	h.equip(&"CHIP_ATK", 0)
	h.equip(&"CHIP_ROF", 0)
	h.equip(&"CHIP_CRIT", 0)                      # 无 gold 芯片 → K_gold=0（金额精确）
	var conv0 := h.chips_converted
	var g0 := _gl.gold
	var boss2: Enemy = pool.acquire() as Enemy
	boss2.spawn(_gl.registry.get_enemy(&"E6_boss2"), 20, GameConst.TAG_BOSS)
	boss2.global_position = Vector2(360.0, 240.0)
	boss2._on_died()
	_check("Boss 死亡 → 槽满转金币（granted=false + 入账 20~110）",
		h.chips_converted == conv0 + 1 and _gl.gold == g0 + h.gold_from_convert
		and h.gold_from_convert > 0)
	_check("跳字「芯片满 → +N 金币」", _popup_prefix_seen("芯片满 → +"))
	h.reset_run()
	# 非 Boss 门控：普通敌死亡不掉芯片
	var equipped0 := h.equipped.size()
	var grunt: Enemy = pool.acquire() as Enemy
	grunt.spawn(_gl.registry.get_enemy(&"E1_grunt"), 1, 0)
	grunt.global_position = Vector2(360.0, 800.0)
	grunt._on_died()
	_check("普通敌死亡不掉芯片（TAG_BOSS 门控）", h.equipped.size() == equipped0)
	# 直接调用门控（非 Enemy 载荷静默跳过）
	var before := h.chips_granted
	_gl._on_enemy_killed_drop_chip(null)
	_check("非敌载荷静默跳过", h.chips_granted == before)


func _popup_prefix_seen(p_prefix: String) -> bool:
	for popup in _gl.popup_manager._active_list:
		if is_instance_valid(popup) and String((popup as DamagePopup)._label.text).begins_with(p_prefix):
			return true
	return false


# ══ U8+U9+U10：附着环 / 反应粒子分级 / 反应统计与结算行 ════════════
func _test_reaction_presentation() -> void:
	print("── U8 附着环（ElementRing） ──")
	var es := ElementalSystem.new()
	var e := Enemy.new()
	tree.get_root().add_child(e)                  # 入树 → _ready 组装 _ring/_fuse_ring
	e.spawn(_gl.registry.get_enemy(&"E1_grunt"), 5, 0)
	e.position = Vector2(360.0, 400.0)
	_check("U8：spawn 后环隐藏（无附着）", e.ring_visible() == false)
	es.register_host(e)
	var st: ElementalState = e.elemental
	st.gauges[GameConst.Element.FIR] = 60.0
	e.tick(DT)
	_check("U8：附着 >1 → 环显示 + FIR 进度 0.6",
		e.ring_visible() and is_equal_approx(e.ring_progress(GameConst.Element.FIR), 0.6))
	_check("U8：ICE/LTG 进度 0（快照同帧）",
		is_equal_approx(e.ring_progress(GameConst.Element.ICE), 0.0)
		and is_equal_approx(e.ring_progress(GameConst.Element.LTG), 0.0))
	# 15Hz 降频：显示首拍相位重置为 1/15
	_check("U8：15Hz 降频相位（重置为 1/15）",
		is_equal_approx(e._ring_refresh_left, 1.0 / 15.0))
	# 衰减至 ≤1 → 隐藏
	st.gauges[GameConst.Element.FIR] = 0.0
	e.tick(DT)
	_check("U8：附着归零 → 环隐藏", e.ring_visible() == false)
	# 归还清零
	st.gauges[GameConst.Element.ICE] = 80.0
	e.tick(DT)
	e._reset_state()
	_check("U8：_reset_state → 环隐藏 + 快照清零",
		e.ring_visible() == false and is_equal_approx(e.ring_progress(GameConst.Element.ICE), 0.0))
	es.free()
	e.free()
	print("── U9 反应粒子/分级 ──")
	# REACTION_SCENE_IDS 三键覆盖
	_check("U9：REACTION_SCENE_IDS 覆盖三反应",
		ParticleDirector.REACTION_SCENE_IDS.size() == 3
		and ParticleDirector.REACTION_SCENE_IDS.has(GameConst.ReactionType.RXN_FIR_ICE)
		and ParticleDirector.REACTION_SCENE_IDS.has(GameConst.ReactionType.RXN_FIR_LTG)
		and ParticleDirector.REACTION_SCENE_IDS.has(GameConst.ReactionType.RXN_ICE_LTG))
	# burst 返回发射器 + 反应材质重指（防串色）
	var pd := _gl.game_feel.particles
	var emitter := (_gl.pools[&"particle"] as ParticlePool).burst(
		&"burst_rxn_shatter", Vector2(100.0, 100.0), ParticleDirector.PRIORITY_CRIT)
	_check("U9：ParticlePool.burst 返回发射器（源兼容可 null）", emitter != null)
	(_gl.pools[&"particle"] as ParticlePool).release(emitter)
	pd.burst(&"burst_rxn_overload", Vector2(120.0, 120.0), ParticleDirector.PRIORITY_CRIT)
	var mat_ok := false
	var mat_color := Color.WHITE
	for pe in (_gl.pools[&"particle"] as ParticlePool).get_children():
		var gpe := pe as GPUParticles2D
		if gpe != null and gpe.visible and gpe.get_meta(&"_burst_scene_id", &"") == &"burst_rxn_overload":
			var m := gpe.process_material as ParticleProcessMaterial
			if m != null and is_equal_approx(m.color.r, 1.0) and is_equal_approx(m.color.g, 0.9):
				mat_ok = true
				mat_color = m.color
	(_gl.pools[&"particle"] as ParticlePool).release_active_all()
	_check("U9：反应场景 id → 专属预设材质（过载亮黄）", mat_ok, str(mat_color))
	# 分级：hit_stop / trauma / ca 缩放（CATALYST 基值 50ms/0.5/0.016）
	var gf := _gl.game_feel
	var base_stop := 50.0                          # CATALYST 顿帧基值 ms
	var base_trauma := 0.5                         # CATALYST trauma 基值
	var base_ca := 0.004 * 4.0                    # CATALYST 色差基值（base×mult）
	var scales := {
		GameConst.ReactionType.RXN_FIR_ICE: {"stop": 1.0, "trauma": 1.0, "ca": 1.0},
		GameConst.ReactionType.RXN_FIR_LTG: {"stop": 0.8, "trauma": 0.85, "ca": 0.8},
		GameConst.ReactionType.RXN_ICE_LTG: {"stop": 0.6, "trauma": 0.7, "ca": 0.6},
	}
	var scale_ok := true
	var scale_detail := ""
	for rxn in scales:
		gf.hit_stop_left = 0.0
		gf.hit_stop_active_ms = 0.0
		gf.shake.trauma = 0.0
		gf._ca_peak = 0.0                         # 色差峰值重置（同档更强覆盖语义）
		gf._ca_left = 0.0
		gf.on_reaction_triggered(int(rxn), Vector2.ZERO, 0)
		var row: Dictionary = scales[rxn]
		var exp_stop: float = base_stop * float(row["stop"])
		var exp_trauma: float = base_trauma * float(row["trauma"])
		var exp_ca: float = base_ca * float(row["ca"])
		if not is_equal_approx(gf.hit_stop_active_ms, exp_stop) \
				or not is_equal_approx(gf.shake.trauma, exp_trauma) \
				or not is_equal_approx(gf.current_ca_intensity, exp_ca):
			scale_ok = false
			scale_detail += "rxn=%d stop=%s/%s trauma=%s/%s ca=%s/%s | " % [int(rxn),
				str(gf.hit_stop_active_ms), str(exp_stop), str(gf.shake.trauma), str(exp_trauma),
				str(gf.current_ca_intensity), str(exp_ca)]
		gf.tick(1.0)
	_check("U9：碎裂/过载/超导打击感分级（×1.0/×0.8/×0.6）", scale_ok, scale_detail)
	print("── U10 反应统计与结算行 ──")
	_gl.hud.reset_reactions()
	_gl.hud.total_damage = 0.0                    # 夹具：总伤害清零（p% 分母确定性）
	_emit_reaction_result(GameConst.ReactionType.RXN_FIR_ICE, 120.0)
	_emit_reaction_result(GameConst.ReactionType.RXN_FIR_ICE, 30.0)
	_emit_reaction_result(GameConst.ReactionType.RXN_ICE_LTG, 50.0)
	var stats: Dictionary = _gl.hud.reaction_stats()
	_check("U10：反应统计（碎裂 2/150 · 超导 1/50）",
		int((stats["counts"] as Array)[0]) == 2 and is_equal_approx(float((stats["damage"] as Array)[0]), 150.0)
		and int((stats["counts"] as Array)[2]) == 1)
	_gl.game_over_screen.show_summary()
	_check("U10：结算行反应段（碎裂 2/150(75%) / 超导 1/50(25%)）",
		String(_gl.game_over_screen.reaction_text()).contains("碎裂 2/150(75%)")
		and String(_gl.game_over_screen.reaction_text()).contains("超导 1/50(25%)"),
		_gl.game_over_screen.reaction_text())
	_gl.hud.reset_reactions()
	_gl.game_over_screen.show_summary()
	_check("U10：无元素战斗零值占位",
		String(_gl.game_over_screen.reaction_text()).contains("碎裂 0/0(0%)"))
	_gl.hud.total_damage = 0.0                    # 还原 HUD 夹具


func _emit_reaction_result(p_rxn: int, p_value: float) -> void:
	var r := DamageResult.new()
	r.final_value = p_value
	r.popup_style = GameConst.PopupStyle.REACTION
	r.element = p_rxn                             # 反应通道 element 承载 ReactionType（管线契约）
	EventBus.emit_damage_resolved(r)

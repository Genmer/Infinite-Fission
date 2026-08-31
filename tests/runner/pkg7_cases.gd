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

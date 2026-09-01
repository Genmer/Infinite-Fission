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

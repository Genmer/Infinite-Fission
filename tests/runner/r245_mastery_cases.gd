# tests/runner/r245_mastery_cases.gd
# R245 需求⑤「武器精通品质梯三档全分化」用例体（入口 test_r245_mastery.gd 运行时
# load——-s 编译期禁引工程类名纪律）。真源 docs/design/2026-10-09-R245-design.md §5。
#
# 验收锚（§7-5，逐项）：
#  A) 三品质 boosts == 1/2/3（白/蓝/紫 roll）——注意与 E（L1-2 紫被钳蓝）及 §5.3 表
#     「紫 仅 L3+（金 roll 钳落）」互斥的原文表述：按真源 §5.2 公式（boosts = 1+rarity、
#     rarity_cap 钳档语义不变）落地——L1 白/蓝/紫roll = 1/2/2（紫钳蓝），三档全分化
#     1/2/3 在紫的首个合法位 L3 断言（verify_feedback R85 先例同位）。
#  B) L1 金 roll → 钳蓝 → +2；L4 金 roll → 钳紫 → +3（去金档语义不回归）。
#  C) 文案含「×2」「×3」与 boosts 同步；display_name Lv 区间正确（精通：<名> LvA→LvB）。
#  D) L4+紫 → mini(lv+boosts, MAX_LEVEL) 钳 5（实升 +1）；L5 →「已满级（终值表口径）」。
#  E) L1-2 紫被钳蓝（rarity_cap 断言不回归；L3 紫不钳对照）。
#  F) 源码锚：MASTERY_DOUBLE_RARITY 全文件零出现（常量删除）+ 新公式在
#     _apply_rarity_values 体内恰一处 + 连升 ×N 动态化格式串在位。
#  G) apply_choice 真路径：L3 紫 → 连升 3 级 mini 钳 5（lv 3→5）。
#  H) 全矩阵 5 级 × 4 roll 逐格锁（§5.3 增益值表 20 格：钳后 rarity/boosts/target/
#     两文案独立重推导精确匹配）。
#  I) 预热变体含 R245 六态精通文案（稀有×2 两态 / 史诗×3 两态 / +1 / 已满级——
#     新增蓝档文本必须入预热键，否则开窗量测增量 ≤2 契约破）。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const GEN_SRC := "res://scripts/cards/card_generator.gd"

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_boot_game_loop()
	await tree.process_frame
	await tree.process_frame
	_test_source_anchors()
	_test_tier_ladder()
	_test_gold_clamp()
	_test_wording_sync()
	_test_cap_clamp_matrix()
	_test_apply_chain()
	_test_prewarm_texts()
	_teardown_game_loop()
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)
	print("验收汇总：%d/%d 通过" % [_pass, _pass + _fail])


func fail_count() -> int:
	return _fail


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("  PASS | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s（%s）" % [p_name, p_detail])
		print("  FAIL | %s（%s）" % [p_name, p_detail])


func _boot_game_loop() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "R245MasteryUnderTest"
	tree.get_root().add_child(_gl)              # _ready → boot（registry/card_generator 全环）


func _teardown_game_loop() -> void:
	tree.paused = false
	if _gl != null:
		_gl.free()
		_gl = null


# ── 真路径造卡：_make_mastery_card + 强制 rarity + _apply_rarity_values ──
func _forced_card(p_weapon: Object, p_rarity: int) -> Dictionary:
	# verify_feedback R85 锁同款手法：模拟任意品质 roll（含金 roll/遗物保底金）
	var gen: CardGenerator = _gl.card_generator
	var card := gen._make_mastery_card(p_weapon)
	card["rarity"] = p_rarity
	gen._apply_rarity_values([card])
	return card


func _probe_weapon_data() -> WeaponData:
	var wdata: WeaponData = null
	for wid in _gl.registry.weapons:
		wdata = _gl.registry.get_weapon(wid)
		if wdata != null:
			break
	return wdata


# ── F：源码锚（§6.2.7 裁函数体区间防后来者污染） ──────────────────
func _test_source_anchors() -> void:
	print("── F 源码锚：常量删除 + 新公式落位 ──")
	var src: String = FileAccess.get_file_as_string(GEN_SRC)
	_check("F1 MASTERY_DOUBLE_RARITY 全文件零出现（常量已删，R245 §5.2）",
		src.count("MASTERY_DOUBLE_RARITY") == 0, "count=%d" % src.count("MASTERY_DOUBLE_RARITY"))
	var f_at: int = src.find("func _apply_rarity_values")
	var body: String = src.substr(f_at, src.find("\nfunc ", f_at + 10) - f_at) if f_at >= 0 else ""
	_check("F2 _apply_rarity_values 体内 boosts := 1 + rarity 恰一处",
		body.count("var boosts := 1 + rarity") == 1,
		"count=%d" % body.count("var boosts := 1 + rarity"))
	_check("F3 连升倍数动态化格式串在位（品质连升 ×%d 随 boosts）",
		body.contains("品质连升 ×%d") and not body.contains("品质连升 ×2）\" % PopPalette"),
		"len=%d" % body.length())


# ── A/E：三档全分化 boosts = 1 + rarity ────────────────────────────
func _test_tier_ladder() -> void:
	print("── A/E 三档分化 boosts=1+rarity + rarity_cap 钳档 ──")
	var wdata := _probe_weapon_data()
	var fake := WeaponBase.new()               # 不入树（仅读 level/data——预热器同款）
	fake.data = wdata
	fake.level = 1
	var c_white := _forced_card(fake, 0)
	var c_blue := _forced_card(fake, 1)
	var c_purple := _forced_card(fake, 2)
	_check("A L1 白 roll → boosts 1", int(c_white.get("level_boosts", -1)) == 1,
		"boosts=%d" % int(c_white.get("level_boosts", -1)))
	_check("A L1 蓝 roll → boosts 2（蓝白不再同值——用户第⑤条主诉）",
		int(c_blue.get("level_boosts", -1)) == 2,
		"boosts=%d" % int(c_blue.get("level_boosts", -1)))
	_check("A L1 紫 roll → 钳蓝 boosts 2（rarity_cap 优先于三档——§5.3 紫仅 L3+）",
		int(c_purple.get("rarity", -1)) == 1 and int(c_purple.get("level_boosts", -1)) == 2,
		"rarity=%d boosts=%d" % [int(c_purple.get("rarity", -1)), int(c_purple.get("level_boosts", -1))])
	fake.level = 3                              # 紫的首个合法位（L3 起 cap=2）
	var c3_white := _forced_card(fake, 0)
	var c3_blue := _forced_card(fake, 1)
	var c3_purple := _forced_card(fake, 2)
	_check("A L3 白/蓝/紫 → boosts 1/2/3（三档全分化——§5.3 增益值表）",
		int(c3_white.get("level_boosts", -1)) == 1 and int(c3_blue.get("level_boosts", -1)) == 2
			and int(c3_purple.get("level_boosts", -1)) == 3,
		"w/b/p=%d/%d/%d" % [int(c3_white.get("level_boosts", -1)),
			int(c3_blue.get("level_boosts", -1)), int(c3_purple.get("level_boosts", -1))])
	# E：L1-2 紫被钳蓝（rarity_cap 断言不回归）+ L3 紫不钳对照
	var r1 := int(_forced_card(fake, 2).get("rarity", -1))
	fake.level = 1
	var e1 := int(_forced_card(fake, 2).get("rarity", -1))
	fake.level = 2
	var e2 := int(_forced_card(fake, 2).get("rarity", -1))
	_check("E L1/L2 紫被钳蓝、L3 紫不钳（rarity_cap=1 if lv<3 else 2 不回归）",
		e1 == 1 and e2 == 1 and r1 == 2, "L1=%d L2=%d L3=%d" % [e1, e2, r1])
	fake.free()


# ── B：金 roll 钳落（去金档语义不变） ─────────────────────────────
func _test_gold_clamp() -> void:
	print("── B 金 roll 钳落（R85 去金档保留） ──")
	var wdata := _probe_weapon_data()
	var fake := WeaponBase.new()
	fake.data = wdata
	fake.level = 1
	var g1 := _forced_card(fake, 3)
	_check("B L1 金 roll → 钳蓝 +2（去金档 + 蓝档新值）",
		int(g1.get("rarity", -1)) == 1 and int(g1.get("level_boosts", -1)) == 2,
		"rarity=%d boosts=%d" % [int(g1.get("rarity", -1)), int(g1.get("level_boosts", -1))])
	fake.level = 4
	var g4 := _forced_card(fake, 3)
	_check("B L4 金 roll → 钳紫 +3（去金档保留，紫档新值）",
		int(g4.get("rarity", -1)) == 2 and int(g4.get("level_boosts", -1)) == 3,
		"rarity=%d boosts=%d" % [int(g4.get("rarity", -1)), int(g4.get("level_boosts", -1))])
	fake.free()


# ── C/D：文案同步（×N 与 boosts 同步 / Lv 区间 / mini 钳 5 / 已满级） ──
func _test_wording_sync() -> void:
	print("── C/D 卡面文案 ×N 动态化 + Lv 区间 + 满级 ──")
	var wdata := _probe_weapon_data()
	var wname := wdata.display_name
	var fake := WeaponBase.new()
	fake.data = wdata
	fake.level = 1
	var c_blue := _forced_card(fake, 1)
	_check("C L1 蓝：desc=「武器等级 +2（稀有品质连升 ×2）（终值表口径）」",
		String(c_blue.get("description", "")) == "武器等级 +2（稀有品质连升 ×2）（终值表口径）",
		"desc=%s" % String(c_blue.get("description", "")))
	_check("C L1 蓝：display_name Lv 区间（Lv1→Lv3）",
		String(c_blue.get("display_name", "")) == "精通：%s Lv1→Lv3" % wname,
		"dn=%s" % String(c_blue.get("display_name", "")))
	var c_white := _forced_card(fake, 0)
	_check("C L1 白：无连升尾注（+1 不带品质连升字样）",
		String(c_white.get("description", "")) == "武器等级 +1（终值表口径）",
		"desc=%s" % String(c_white.get("description", "")))
	fake.level = 3
	var c_purple := _forced_card(fake, 2)
	_check("C L3 紫：desc=「武器等级 +2（史诗品质连升 ×3，已触顶）（终值表口径）」（+3 被 mini 钳 5 → 实升 +2，触顶标注）",
		String(c_purple.get("description", "")) == "武器等级 +2（史诗品质连升 ×3，已触顶）（终值表口径）",
		"desc=%s" % String(c_purple.get("description", "")))
	_check("C L3 紫：display_name Lv 区间（Lv3→Lv5）",
		String(c_purple.get("display_name", "")) == "精通：%s Lv3→Lv5" % wname,
		"dn=%s" % String(c_purple.get("display_name", "")))
	fake.level = 4
	var c4_purple := _forced_card(fake, 2)
	_check("D L4+紫：mini(lv+boosts, MAX_LEVEL) 钳 5（4+3=7 → Lv4→Lv5，实升 +1，×3 尾注+已触顶标注）",
		String(c4_purple.get("display_name", "")) == "精通：%s Lv4→Lv5" % wname
			and String(c4_purple.get("description", "")) == "武器等级 +1（史诗品质连升 ×3，已触顶）（终值表口径）",
		"dn=%s desc=%s" % [String(c4_purple.get("display_name", "")), String(c4_purple.get("description", ""))])
	fake.level = 5
	var c5 := _forced_card(fake, 2)
	_check("D L5 紫：满级文案「已满级（终值表口径）」（target==lv 短路）",
		String(c5.get("description", "")) == "已满级（终值表口径）"
			and String(c5.get("display_name", "")) == "精通：%s Lv5→Lv5" % wname,
		"dn=%s desc=%s" % [String(c5.get("display_name", "")), String(c5.get("description", ""))])
	fake.free()


# ── H：全矩阵逐格锁（§5.3 增益值表 5级×4roll=20 格） ───────────────
func _test_cap_clamp_matrix() -> void:
	print("── H 全矩阵 20 格（钳档/boosts/target/两文案独立重推导） ──")
	var wdata := _probe_weapon_data()
	var wname := wdata.display_name
	var fake := WeaponBase.new()
	fake.data = wdata
	# 期望表（§5.3 + rarity_cap 钳档 + mini 终值钳）：expect[lv][roll_r] = [钳后rarity, boosts, target]
	var expect := {
		1: {0: [0, 1, 2], 1: [1, 2, 3], 2: [1, 2, 3], 3: [1, 2, 3]},
		2: {0: [0, 1, 3], 1: [1, 2, 4], 2: [1, 2, 4], 3: [1, 2, 4]},
		3: {0: [0, 1, 4], 1: [1, 2, 5], 2: [2, 3, 5], 3: [2, 3, 5]},
		4: {0: [0, 1, 5], 1: [1, 2, 5], 2: [2, 3, 5], 3: [2, 3, 5]},
		5: {0: [0, 1, 5], 1: [1, 2, 5], 2: [2, 3, 5], 3: [2, 3, 5]},
	}
	var all_ok := true
	var bad: Array[String] = []
	for lv in range(1, 6):
		fake.level = lv
		for r in range(4):
			var card := _forced_card(fake, r)
			var e: Array = expect[lv][r]
			var want_dn := "精通：%s Lv%d→Lv%d" % [wname, lv, int(e[2])]
			var want_desc := _expect_desc(lv, int(e[0]), int(e[1]), int(e[2]))
			if int(card.get("rarity", -1)) != int(e[0]) \
					or int(card.get("level_boosts", -1)) != int(e[1]) \
					or String(card.get("display_name", "")) != want_dn \
					or String(card.get("description", "")) != want_desc:
				all_ok = false
				bad.append("L%d r%d→[%d,%d,%d] 实况 rar=%d b=%d dn=%s desc=%s" % [lv, r,
					int(e[0]), int(e[1]), int(e[2]), int(card.get("rarity", -1)),
					int(card.get("level_boosts", -1)), String(card.get("display_name", "")),
					String(card.get("description", ""))])
	fake.free()
	_check("H 5级×4roll 全 20 格逐位（rarity 钳档/boosts/target/display_name/description）",
		all_ok, str(bad.slice(0, 3)))


func _expect_desc(p_lv: int, p_rarity: int, p_boosts: int, p_target: int) -> String:
	# 测试侧独立拼串（设计 §5.2/§5.4 格式——不调产品码，断言独立于实现）；
	# R245 交付前小修：连升被终值钳断（lv+boosts>target 且未满级）时尾注「，已触顶」
	if p_target <= p_lv:
		return "已满级（终值表口径）"
	var gain := p_target - p_lv
	if p_boosts > 1:
		var cap_note := "，已触顶" if p_lv + p_boosts > p_target else ""
		return "武器等级 +%d（%s品质连升 ×%d%s）（终值表口径）" % [gain,
			PopPalette.rarity_name(p_rarity), p_boosts, cap_note]
	return "武器等级 +%d（终值表口径）" % gain


# ── G：apply_choice 真路径（真武器 level_up 连升） ─────────────────
func _test_apply_chain() -> void:
	print("── G 应用链 apply_choice 真路径 ──")
	var gen: CardGenerator = _gl.card_generator
	var w: WeaponBase = (_gl.player.get("weapon_slots") as Array)[0]
	w.level = 3
	var card := _forced_card(w, 2)              # L3 紫 → boosts 3
	gen.apply_choice(card, _gl.player)
	_check("G L3 紫精通应用 → 连升 3 级 mini 钳 5（lv 3→5）",
		int(w.get("level")) == 5, "lv=%d" % int(w.get("level")))
	w.level = 1
	var card_b := _forced_card(w, 1)            # L1 蓝 → boosts 2
	gen.apply_choice(card_b, _gl.player)
	_check("G L1 蓝精通应用 → 连升 2 级（lv 1→3）",
		int(w.get("level")) == 3, "lv=%d" % int(w.get("level")))


# ── I：预热变体含 R245 六态精通文案 ───────────────────────────────
func _test_prewarm_texts() -> void:
	print("── I 预热变体六态精通文案（card_desc_prewarm 契约） ──")
	var gen := CardGenerator.new()
	gen.setup(_gl.registry)
	var variants: Array[Dictionary] = gen.enumerate_prewarm_variants([])
	var txts := {}
	for v in variants:
		txts[String(v["desc"])] = true
	_check("I 六态全在变体（+1 / +2稀有×2 / +1稀有×2已触顶 / +2史诗×3已触顶 / +1史诗×3已触顶 / 已满级）",
		txts.has("武器等级 +1（终值表口径）")
			and txts.has("武器等级 +2（稀有品质连升 ×2）（终值表口径）")
			and txts.has("武器等级 +1（稀有品质连升 ×2，已触顶）（终值表口径）")
			and txts.has("武器等级 +2（史诗品质连升 ×3，已触顶）（终值表口径）")
			and txts.has("武器等级 +1（史诗品质连升 ×3，已触顶）（终值表口径）")
			and txts.has("已满级（终值表口径）"),
		"种数=%d" % txts.keys().size())
	_check("I 旧压平文本「史诗品质连升 ×2」零残留（R85 文案退役）",
		not _has_desc_contains(variants, "史诗品质连升 ×2"),
		"")
	var fake_probe := WeaponBase.new()          # 旧文本运行时零再现（真路径单点复验）
	fake_probe.data = _probe_weapon_data()
	fake_probe.level = 3
	_check("I 运行时真路径零旧文本（L3 紫不再产「×2」）",
		not String(_forced_card(fake_probe, 2).get("description", "")).contains("连升 ×2"),
		String(_forced_card(fake_probe, 2).get("description", "")))
	fake_probe.free()


func _has_desc_contains(p_variants: Array[Dictionary], p_sub: String) -> bool:
	for v in p_variants:
		if String(v["desc"]).contains(p_sub):
			return true
	return false

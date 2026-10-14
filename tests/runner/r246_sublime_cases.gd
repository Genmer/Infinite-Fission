# tests/runner/r246_sublime_cases.gd
# R246「红色传说·技能升华卡」用例体（由 test_r246_sublime.gd 入口在 autoload 就绪后
# 运行时加载）。契约真源 docs/design/sublime/_card_system.md §7（T1~T10）+ cards 泳道
# game_loop 接线（S 组）。夹具：T 组 = DataRegistry 裸载（r245 同式）+ 自建
# CardGenerator + Node 假人（不入树）；S 组 = GameLoop 完整 Boot（pkg4 同式）。
# 纪律：勿靠真随机掷出 0.001%——定种流扫描命中位（每批恰耗一掷，消耗到命中位下一批
# 必中/首掷 miss 位必不中）；勿 add_child 池化节点；Meta 首尾快照还原防跨套件污染。
extends RefCounted

const MANIFEST_PATH := "res://data/manifest.cfg"   # game_loop.MANIFEST_PATH 同值
const SUBLIME_PROBE_SEED := 20261008              # CardGenerator.SUBLIME_SEED 同值（流探针）
const STREAM_SCAN_CAP := 2000000                  # 流扫描上限（P(miss)=e^-20≈2e-9）

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _registry: DataRegistry = null
var _gl: GameLoop = null
var _hit_idx: int = -1                            # 定种流中首个 <SUBLIME_CHANCE 抽位
var _mech_log: Array[String] = []                 # mechanics_intro 捕获（T5）
var _bk: Dictionary = {}


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(246)
	_snapshot_meta()
	_boot_registry()
	_scan_hit_idx()
	_test_t1_palette()
	_test_t2_chance_two_state()
	_test_t3_exemptions()
	_test_t4_replacement()
	_test_t5_apply()
	_test_t6_fission()
	_test_t7_face()
	_test_t8_idle()
	_test_t9_prewarm()
	_test_t10_rng_discipline()
	await _test_s_game_loop_wiring()
	_teardown()
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
		print("PASS | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s %s" % [p_name, p_detail])
		print("FAIL | %s | %s" % [p_name, p_detail])


# ── 环境（r245 裸载式） ─────────────────────────────────────────
func _snapshot_meta() -> void:
	_bk = {
		"character_id": Meta.character_id,
		"crystals": Meta.crystals,
	}
	Meta.character_id = &"sentinel"


func _restore_meta() -> void:
	Meta.character_id = StringName(String(_bk["character_id"]))
	Meta.crystals = int(_bk["crystals"])
	Meta.set_run_daily(false)
	Meta.set_run_map(MapTable.FIRST_MAP_ID)
	Meta.set_run_difficulty(GameConst.Difficulty.NORMAL)


func _boot_registry() -> void:
	_registry = DataRegistry.new()
	_registry.load_all(MANIFEST_PATH)
	_check("前置：DataRegistry 裸载就绪（词条/武器/遗物全量）",
		_registry.traits.size() > 0 and _registry.weapons.size() > 0)


func _teardown() -> void:
	tree.paused = false
	RunSave.clear()
	if _gl != null:
		_gl.free()
		_gl = null
	_restore_meta()
	Meta._save()


# ── 夹具：定种流两态（勿靠真随机掷出 0.001% —— 设计 §7 纪律） ──
func _scan_hit_idx() -> void:
	# 流式扫描：SUBLIME_PROBE_SEED 定种流中第一个 <SUBLIME_CHANCE 的抽位（期望 ~10 万）。
	# generate_candidates 每批恰耗一掷 → 把 _sublime_rng 重置到定种流后：
	#   耗 hit_idx 掷 → 下一批「本批首掷」即命中位（出卡）；
	#   零消耗      → 本批首掷 = 流第 0 位（miss 位，需 hit_idx ≥ 1 保证 ≥ 概率）。
	var probe := RandomNumberGenerator.new()
	probe.seed = SUBLIME_PROBE_SEED
	_hit_idx = -1
	for i in range(STREAM_SCAN_CAP):
		if probe.randf() < CardGenerator.SUBLIME_CHANCE:
			_hit_idx = i
			break
	_check("前置：定种流 0.001% 命中位扫描在案（hit_idx=" + str(_hit_idx) + "，上限内）",
		_hit_idx >= 1, "hit_idx=" + str(_hit_idx) + "（0 = 首掷即中，miss 态需 ≥1）")


func _to_hit(p_gen: CardGenerator) -> void:
	# 重置升华流到定种流并消耗到命中位（下一批必出红卡）
	p_gen._sublime_rng.seed = SUBLIME_PROBE_SEED
	for i in range(_hit_idx):
		p_gen._sublime_rng.randf()


func _to_miss(p_gen: CardGenerator) -> void:
	# 重置升华流到定种流第 0 位（首掷 miss——_scan_hit_idx 已保证 hit_idx ≥ 1）
	p_gen._sublime_rng.seed = SUBLIME_PROBE_SEED


func _ctx(p_player: Node, p_extra: Dictionary = {}) -> Dictionary:
	var ctx := {"player": p_player, "wave": 7}
	for k in p_extra:
		ctx[k] = p_extra[k]
	return ctx


func _count_kind(p_cands: Array[Dictionary], p_kind: int) -> int:
	var n := 0
	for c in p_cands:
		if int(c.get("kind", -1)) == p_kind:
			n += 1
	return n


func _find_kind(p_cands: Array[Dictionary], p_kind: int) -> Dictionary:
	for c in p_cands:
		if int(c.get("kind", -1)) == p_kind:
			return c
	return {}


func _new_gen() -> CardGenerator:
	var g := CardGenerator.new()
	g.setup(_registry)
	return g


# ── T1 品质表第 5 档（palette 单源） ─────────────────────────────
func _test_t1_palette() -> void:
	print("── T1 品质表第 5 档 ──")
	_check("T1 RARITY_NAMES 五档（[普通,稀有,史诗,辉煌,传说]）",
		PopPalette.RARITY_NAMES.size() == 5 and PopPalette.RARITY_NAMES[0] == "普通"
			and PopPalette.RARITY_NAMES[1] == "稀有" and PopPalette.RARITY_NAMES[2] == "史诗"
			and PopPalette.RARITY_NAMES[3] == "辉煌" and PopPalette.RARITY_NAMES[4] == "传说",
		str(PopPalette.RARITY_NAMES))
	_check("T1 RARITY_COLORS 五档 + [4]==RARITY_SUBLIME(#ff2e63)",
		PopPalette.RARITY_COLORS.size() == 5
			and PopPalette.rarity_color(4) == Color("ff2e63"),
		str(PopPalette.RARITY_COLORS))
	_check("T1 金档只换字：色值 #ffc93c 与顺序 [3] 零动",
		PopPalette.RARITY_LEGEND == Color("ffc93c")
			and PopPalette.rarity_color(3) == Color("ffc93c")
			and PopPalette.rarity_name(3) == "辉煌")
	_check("T1 红档三重避让警示红（≠ENEMY/≠ENEMY_DEEP/≠碎裂描边）",
		PopPalette.rarity_color(4) != PopPalette.ENEMY
			and PopPalette.rarity_color(4) != PopPalette.ENEMY_DEEP
			and PopPalette.rarity_color(4) != PopPalette.RXN_LINE_SHATTER)
	_check("T1 越界钳制安全（rarity_color(5)/rarity_name(99)/rarity_name(-1)）",
		PopPalette.rarity_color(5) == PopPalette.rarity_color(4)
			and PopPalette.rarity_name(99) == "传说"
			and PopPalette.rarity_name(-1) == "普通")


# ── T2 掷率字面 + 定种两态 ───────────────────────────────────────
func _test_t2_chance_two_state() -> void:
	print("── T2 掷率 0.001% 字面 + 两态 ──")
	_check("T2 SUBLIME_CHANCE == 0.00001（0.001% 字面精确）",
		is_equal_approx(CardGenerator.SUBLIME_CHANCE, 0.00001),
		"%s" % str(CardGenerator.SUBLIME_CHANCE))
	_check("T2 构造期定种 20261008（R88 _slot_rng 同式）",
		CardGenerator.SUBLIME_SEED == 20261008
			and CardGenerator.new()._sublime_rng.seed == 20261008)
	var stub := StubPlayer.new()
	var g_miss := _new_gen()
	_to_miss(g_miss)
	var cands_miss := g_miss.generate_candidates(_ctx(stub))
	_check("T2 miss 态（本批首掷 ≥1e-5）：不出升华卡",
		_count_kind(cands_miss, CardGenerator.CardKind.SUBLIME) == 0)
	var g_hit := _new_gen()
	_to_hit(g_hit)
	var cands_hit := g_hit.generate_candidates(_ctx(stub))
	var sub := _find_kind(cands_hit, CardGenerator.CardKind.SUBLIME)
	_check("T2 hit 态（本批首掷 <1e-5）：恰出 1 张升华卡",
		_count_kind(cands_hit, CardGenerator.CardKind.SUBLIME) == 1)
	_check("T2 hit 卡 rarity==4（红档不被钳金）", int(sub.get("rarity", -1)) == 4,
		"rarity=%s" % str(sub.get("rarity", -1)))
	_check("T2 批大小不变（替换非追加，货架恒 deal 张）",
		cands_hit.size() == 3 and cands_miss.size() == 3)
	stub.free()


# ── T3 豁免面（保底/重随/诅咒/槽位替换永不侵蚀红卡——硬契约） ──
func _test_t3_exemptions() -> void:
	print("── T3 豁免面 ──")
	# 行为面：掷中批叠满 REL_OVERCLOCK 保底 + REL_WORDS_TIDE 重随 + REL_GAMBLER 诅咒
	var stub := StubPlayer.new()
	var g := _new_gen()
	_to_hit(g)
	var cands := g.generate_candidates(_ctx(stub, {
		"deal_count": 4,
		"min_rarity_floor": 3,
		"fixed_rarities": [3, 3, 3, 3],
		"curse_last": true,
	}))
	var sub := _find_kind(cands, CardGenerator.CardKind.SUBLIME)
	_check("T3 满遗物语境掷中：升华卡仍在架且恰 1 张",
		_count_kind(cands, CardGenerator.CardKind.SUBLIME) == 1)
	_check("T3 升华卡 rarity 恒 4（保底/重随不顶穿不改写）",
		int(sub.get("rarity", -1)) == 4, "rarity=%s" % str(sub.get("rarity", -1)))
	_check("T3 升华卡永不带诅咒（curse_last 收紧为仅 TRAIT——红/诅咒撞色消除）",
		not bool(sub.get("cursed", false)))
	# 诅咒回归：非升华批 TRAIT 末位照常被打诅咒（收紧不误伤既有 REL_GAMBLER 语义）
	var bare := BareStubPlayer.new()             # 无 enable_sublime → 升华掷不参与
	var g2 := _new_gen()
	var cursed_trait_seen := false
	for attempt in range(60):
		var c2 := g2.generate_candidates(_ctx(bare, {"deal_count": 4, "curse_last": true}))
		if c2.size() >= 4 and int(c2[3].get("kind", -1)) == CardGenerator.CardKind.TRAIT:
			cursed_trait_seen = bool(c2[3].get("cursed", false))
			break
	_check("T3 诅咒回归：TRAIT 末位照常带 curse（收紧仅放走非 TRAIT）", cursed_trait_seen)
	bare.free()
	# 源级锚（r212 先例）：四道显式防线在源（防未来插入点前移回归——现行注入天然后置）
	var src := FileAccess.get_file_as_string("res://scripts/cards/card_generator.gd")
	_check("T3 源级锚：重随循环豁免 SUBLIME",
		src.contains("if int(out[i].get(\"kind\", -1)) == CardKind.SUBLIME:"))
	_check("T3 源级锚：保底语句豁免 SUBLIME",
		src.contains("and int(out[0].get(\"kind\", -1)) != CardKind.SUBLIME:"))
	_check("T3 源级锚：金卡槽替换双保险豁免 SUBLIME",
		src.contains("and int(card.get(\"kind\", -1)) != CardKind.SUBLIME"))
	_check("T3 源级锚：curse_last 收紧为仅 TRAIT",
		src.contains("int(out[3].get(\"kind\", CardKind.FALLBACK)) == CardKind.TRAIT:"))
	# 槽位共存：金卡槽替换命中间 → 槽位卡与升华卡同批共存（互不吞）
	var slot_stub := SlotStubPlayer.new()
	var g3 := _new_gen()
	g3._slot_rng.seed = _slot_hit_seed()
	_to_hit(g3)
	var c3 := g3.generate_candidates(_ctx(slot_stub, {"deal_count": 4}))
	_check("T3 金卡槽替换命中批：槽位卡 1 张 + 升华卡 1 张共存互不吞",
		_count_kind(c3, CardGenerator.CardKind.SLOT_BONUS) == 1
			and _count_kind(c3, CardGenerator.CardKind.SUBLIME) == 1)
	slot_stub.free()
	stub.free()


func _slot_hit_seed() -> int:
	# 首掷 <0.05 的 _slot_rng 种子（5% → 数十次内必中）
	var r := RandomNumberGenerator.new()
	for s in range(10000):
		r.seed = s
		if r.randf() < 0.05:
			return s
	return 0


# ── T4 替换规则 ──────────────────────────────────────────────────
func _test_t4_replacement() -> void:
	print("── T4 替换规则 ──")
	# 全保底批（空注册表 → 全 FALLBACK）：掷中即耗不上架、不补偿不重掷、批大小不变
	var stub := StubPlayer.new()
	var g := CardGenerator.new()                 # 不 setup → registry null → 全 fallback
	_to_hit(g)
	var cands := g.generate_candidates(_ctx(stub))
	_check("T4 空注册表全 fallback：掷中不上架（保底卡神圣不可替换）",
		_count_kind(cands, CardGenerator.CardKind.SUBLIME) == 0
			and _count_kind(cands, CardGenerator.CardKind.FALLBACK) == 3,
		"size=%d" % cands.size())
	_check("T4 不补偿：批大小仍 3（无追加无移除）", cands.size() == 3)
	# 掷中已耗：紧接一批（miss 位）不出（不补偿不重掷）
	_to_miss(g)
	var cands2 := g.generate_candidates(_ctx(stub))
	_check("T4 掷中即耗：后续批不出（无补偿重掷）",
		_count_kind(cands2, CardGenerator.CardKind.SUBLIME) == 0)
	# 源级锚：注入替换扫描跳过 FALLBACK/SLOT_BONUS（末位保底卡保护）
	var src := FileAccess.get_file_as_string("res://scripts/cards/card_generator.gd")
	_check("T4 源级锚：替换扫描跳过 FALLBACK/SLOT_BONUS",
		src.contains("if skip_kind == CardKind.FALLBACK or skip_kind == CardKind.SLOT_BONUS:"))
	_check("T4 源级锚：注入落点在 _apply_rarity_values 之后（防 clampi 钳金）",
		src.find("_apply_rarity_values(out)") < src.find("_make_sublime_card(player)"))
	stub.free()


# ── T5 apply_choice 拾取生效 ─────────────────────────────────────
func _test_t5_apply() -> void:
	print("── T5 apply_choice ──")
	var g := _new_gen()
	var stub := StubPlayer.new()
	var card: Dictionary = g._make_sublime_card(stub)
	var cnt0: int = DebugStats.get_counter(&"sublime_card_chosen")
	_mech_log.clear()
	EventBus.mechanics_intro.connect(_on_mech_intro)
	g.apply_choice(card, stub)
	EventBus.mechanics_intro.disconnect(_on_mech_intro)
	_check("T5 enable_sublime 调用计数 ==1（鸭子守卫直调）", stub.enable_calls == 1,
		"calls=%d" % stub.enable_calls)
	_check("T5 player 侧升华位置位", stub.sublime_on)
	_check("T5 mechanics_intro 播报「红色传说 · 技能已升华！（本局有效）」",
		_mech_log.size() == 1 and _mech_log[0] == "红色传说 · 技能已升华！（本局有效）",
		str(_mech_log))
	_check("T5 DebugStats 计数 sublime_card_chosen +1",
		DebugStats.get_counter(&"sublime_card_chosen") == cnt0 + 1)
	# 幂等口径（设计 §2.5：同局第二张 1e-10 重复调用无害——player 侧布尔不变）
	g.apply_choice(card, stub)
	_check("T5 二次 apply 幂等（player 侧布尔保持 true）",
		stub.enable_calls == 2 and stub.sublime_on)
	# 无 enable_sublime 的 player（skills 未合入期守卫态）：零崩溃零调用
	var bare := BareStubPlayer.new()
	g.apply_choice(card, bare)                   # 走通即守卫生效（崩溃则套件中止）
	_check("T5 无 enable_sublime 守卫：零崩溃通过（不调不炸）", true)
	stub.free()
	bare.free()


func _on_mech_intro(p_text: String) -> void:
	_mech_log.append(p_text)


# ── T6 fission 两态 ──────────────────────────────────────────────
func _test_t6_fission() -> void:
	print("── T6 fission 两态 ──")
	# 表有键态（meta 泳道 R247 已落表）：fission（no_skill）凭 sublime_desc 上架读表文案
	var fission_entry: Dictionary = CharacterTable.get_character(&"fission")
	var desc_has_key := String(fission_entry.get("sublime_desc", "")) != ""
	var stub := StubPlayer.new()
	stub.character_id = &"fission"
	var g := _new_gen()
	_to_hit(g)
	var cands := g.generate_candidates(_ctx(stub))
	if desc_has_key:
		var sub := _find_kind(cands, CardGenerator.CardKind.SUBLIME)
		_check("T6 表有键：fission 掷中上架（sublime_desc 即替代升华判据）",
			_count_kind(cands, CardGenerator.CardKind.SUBLIME) == 1)
		_check("T6 表有键：描述含表文案（动态读表拼接）",
			String(sub.get("description", "")).contains(
				String(fission_entry.get("sublime_desc", ""))))
		_check("T6 表有键：卡名带表升华名（%s）"
			% String(fission_entry.get("sublime_name", "")),
			String(sub.get("display_name", "")) == "技能升华：%s"
				% String(fission_entry.get("sublime_name", "")))
		# 表无键态：运行时临时摘键复现（能力探测——const 表冻结则源级锚兜底）
		if not fission_entry.is_read_only():
			var orig := String(fission_entry.get("sublime_desc", ""))
			fission_entry.erase("sublime_desc")
			if not fission_entry.has("sublime_desc"):
				var g2 := _new_gen()
				_to_hit(g2)
				var c2 := g2.generate_candidates(_ctx(stub))
				_check("T6 表无键：fission 掷中不上架（「抽了没反应」破洞卡杜绝）",
					_count_kind(c2, CardGenerator.CardKind.SUBLIME) == 0)
				fission_entry["sublime_desc"] = orig   # 立即还原（绝不留痕）
				_check("T6 表无键探针还原：键已回填",
					String(fission_entry.get("sublime_desc", "")) == orig)
			else:
				_check("T6 表无键态：摘键失败以源级锚兜底（_sublime_available 读表键）",
				 FileAccess.get_file_as_string("res://scripts/cards/card_generator.gd")
					.contains("return String(CharacterTable.get_character(cid).get(\"sublime_desc\", \"\")) != \"\""))
		else:
			_check("T6 表无键态：const 表嵌套冻结不可注入（源级锚兜底）",
				FileAccess.get_file_as_string("res://scripts/cards/card_generator.gd")
					.contains("return String(CharacterTable.get_character(cid).get(\"sublime_desc\", \"\")) != \"\""))
	else:
		# 集成窗口期（meta 泳道未落表）：表无键态即当前真态
		_check("T6 表无键（meta 未落表态）：fission 掷中不上架",
			_count_kind(cands, CardGenerator.CardKind.SUBLIME) == 0)
	# T6 变体（R247 终修回归锁）：三新角色有技能（has_skill 真）但升华版未落表
	#（sublime_desc 无键）→ _sublime_available 判据收紧后掷中不上架——旧判据
	# 「has_skill 恒放行」会掷出「空文案 + 零行为」破洞卡（QA/评审 P0 收口）
	for new_cid: StringName in [&"medic", &"vortex", &"reaper"]:
		var nstub := StubPlayer.new()
		nstub.character_id = new_cid
		var ng := _new_gen()
		_to_hit(ng)
		var nc := ng.generate_candidates(_ctx(nstub))
		_check("T6 变体：新角色 %s 掷中不上架（has_skill 真但表无 sublime_desc——破洞卡杜绝）"
			% String(new_cid),
			_count_kind(nc, CardGenerator.CardKind.SUBLIME) == 0)
		nstub.free()
	# 判据一致性锚：13 角色全表 _sublime_available ⇔ sublime_desc 非空（单源两处同步锁）
	var src := FileAccess.get_file_as_string("res://scripts/cards/card_generator.gd")
	_check("T6 源级锚：判据已收紧为单判据（has_skill 放行已撤——r247 终修）",
		not src.contains("CharacterTable.has_skill(cid) \\\n\t\tor String")
			and src.contains("return String(CharacterTable.get_character(cid).get(\"sublime_desc\", \"\")) != \"\""))
	stub.free()


# ── T7 卡面数据面 ────────────────────────────────────────────────
func _test_t7_face() -> void:
	print("── T7 卡面数据面 ──")
	var g := _new_gen()
	var stub := StubPlayer.new()
	var card: Dictionary = g._make_sublime_card(stub)
	_check("T7 卡 dict：kind==SUBLIME(6) / id==SUBLIME_SKILL / rarity==4",
		int(card.get("kind", -1)) == CardGenerator.CardKind.SUBLIME
			and StringName(String(card.get("id", ""))) == &"SUBLIME_SKILL"
			and int(card.get("rarity", -1)) == 4)
	_check("T7 卡 dict：data==null（不走词条链，E-08 天然不破）+ milestone==false（无金名质变预告）",
		card.get("data", {}) == null and not bool(card.get("milestone", true)))
	_check("T7 卡 dict：value_scale==1.0（无品质加成尾行——compose_desc_text 守卫口径）",
		is_equal_approx(float(card.get("value_scale", 0.0)), 1.0))
	_check("T7 描述含「0.001%」+「红色传说」（概率卡面显示主露出）",
		String(card.get("description", "")).contains("0.001%")
			and String(card.get("description", "")).contains("红色传说"))
	_check("T7 卡名「技能升华：…」前缀（读表升华名拼接）",
		String(card.get("display_name", "")).begins_with("技能升华"))
	# 卡面档位数据源（类别行「升华 · 传说」/顶带红/5 珠的 palette 供数——渲染归 ui 泳道）
	_check("T7 档位供数：rarity_name(4)==传说 + rarity_color(4)==RARITY_SUBLIME",
		PopPalette.rarity_name(4) == "传说"
			and PopPalette.rarity_color(4) == PopPalette.RARITY_SUBLIME)
	# 预热键=实拼键（R220 契约：roll 卡描述必须命中预热变体集）
	var variants := g.enumerate_prewarm_variants([])
	var hit := false
	for v in variants:
		if String(v.get("desc", "")) == String(card.get("description", "")) \
				and is_equal_approx(float(v.get("value_scale", 0.0)), 1.0):
			hit = true
			break
	_check("T7 预热键=实拼键：roll 卡描述∈预热变体集（value_scale 同 1.0）", hit)
	stub.free()


# ── T8 挂机必选（998 特判） ──────────────────────────────────────
func _test_t8_idle() -> void:
	print("── T8 挂机 998 ──")
	var g := _new_gen()
	var stub := StubPlayer.new()
	var sub := g._make_sublime_card(stub)
	stub.free()
	var gold := {"kind": CardGenerator.CardKind.TRAIT, "rarity": 3,
		"value_scale": 2.6, "milestone": true, "id": &"AFF_ATK_UP"}
	var cursed := {"kind": CardGenerator.CardKind.TRAIT, "rarity": 3,
		"value_scale": 2.6, "cursed": true, "id": &"AFF_CRIT_RATE"}
	var pickup := {"kind": CardGenerator.CardKind.TRAIT, "rarity": 2,
		"value_scale": 1.9, "id": &"AFF_PICKUP"}
	_check("T8 score(升华卡)==998.0", AutoIdleStrategy.score(sub) == 998.0,
		"%s" % str(AutoIdleStrategy.score(sub)))
	_check("T8 998 > 金词条卡理论上限（3×2.6+质变2=9.8）",
		AutoIdleStrategy.score(gold) == 9.8 and AutoIdleStrategy.score(sub) > AutoIdleStrategy.score(gold))
	_check("T8 软排除清单不含升华卡（998 不受罚分侵蚀）",
		not (AutoIdleStrategy.SOFT_EXCLUDE_TRAITS as Array[StringName]).has(&"SUBLIME_SKILL")
			and AutoIdleStrategy.score(sub) > AutoIdleStrategy.score(pickup))
	_check("T8 pick 普通模式：升华卡槽位必选（金/升华/诅咒 → idx1）",
		AutoIdleStrategy.pick([gold, sub, cursed], false) == 1)
	_check("T8 pick 成对模式：含升华卡的行必选（行 1 → 槽 6）",
		AutoIdleStrategy.pick([gold, gold, sub, gold], true) == 6)
	_check("T8 pick 成对模式：诅咒行让位（行 0 含诅咒 → 行 1 升华 → 槽 6）",
		AutoIdleStrategy.pick([cursed, gold, sub, gold], true) == 6)
	_check("T8 诅咒评分仍在负域（−999 语义不回归）",
		AutoIdleStrategy.score(cursed) < 0.0)


# ── T9 预热零 rng + 升华变体 ────────────────────────────────────
func _test_t9_prewarm() -> void:
	print("── T9 预热零 rng ──")
	var g := _new_gen()
	var st_rng0: int = g.rng.state
	var st_slot0: int = g._slot_rng.state
	var st_sub0: int = g._sublime_rng.state
	var variants := g.enumerate_prewarm_variants([])
	_check("T9 零 rng 契约：三流 state 前后不变（rng/_slot_rng/_sublime_rng）",
		g.rng.state == st_rng0 and g._slot_rng.state == st_slot0
			and g._sublime_rng.state == st_sub0)
	# 期望变体数 = 表有 sublime_desc 角色数 + 通用兜底 1（动态随 meta 表扩容）
	var expect := 1
	for c in CharacterTable.CHARACTERS:
		if String(c.get("sublime_desc", "")) != "":
			expect += 1
	var got := 0
	for v in variants:
		if String(v.get("desc", "")).contains("0.001%"):
			got += 1
	_check("T9 升华变体在架（表有键角色各 1 + 通用兜底 1 = %d）" % expect, got == expect,
		"got=%d expect=%d" % [got, expect])
	var generic_desc := String(g._build_sublime_card("", "").get("description", ""))
	var generic_hit := false
	for v in variants:
		if String(v.get("desc", "")) == generic_desc:
			generic_hit = true
			break
	_check("T9 通用兜底变体逐字节在架（_build_sublime_card 单源）", generic_hit)


# ── T10 RNG 纪律（独立掷流不扰动既有确定性序列） ─────────────────
func _test_t10_rng_discipline() -> void:
	print("── T10 RNG 纪律 ──")
	var a := _new_gen()
	var b := _new_gen()
	var stub := SlotStubPlayer.new()              # 带槽位口 → _slot_rng 每批同耗（更强对照）
	_to_miss(a)
	_to_hit(b)
	var ca := a.generate_candidates(_ctx(stub))
	var cb := b.generate_candidates(_ctx(stub))
	_check("T10 对照前置：A 批无升华 / B 批恰 1 张",
		_count_kind(ca, CardGenerator.CardKind.SUBLIME) == 0
			and _count_kind(cb, CardGenerator.CardKind.SUBLIME) == 1)
	for i in range(99):
		a.generate_candidates(_ctx(stub))
		b.generate_candidates(_ctx(stub))
	_check("T10 100 批后主 rng.state 相等（升华掷/替换零扰动——pkg4 分布锁前置保证）",
		a.rng.state == b.rng.state,
		"a=%d b=%d" % [a.rng.state, b.rng.state])
	_check("T10 100 批后 _slot_rng.state 相等（金卡槽流零扰动）",
		a._slot_rng.state == b._slot_rng.state)
	_check("T10 _sublime_rng 流独立分叉（A/B 消耗位不同）",
		a._sublime_rng.state != b._sublime_rng.state)
	stub.free()


# ── S 组 game_loop 接线（sublime 随档 + 流定种） ─────────────────
func _test_s_game_loop_wiring() -> void:
	print("── S 组 game_loop 接线 ──")
	RunSave.clear()
	_gl = GameLoop.new()
	_gl.name = "R246GameLoopUnderTest"
	tree.get_root().add_child(_gl)
	await tree.process_frame
	await tree.process_frame
	if not _check_continue("S 前置：GameLoop Boot 完成（MENU）",
			_gl.boot_ready and _gl.state == GameConst.GameStatus.MENU):
		return
	# S1/S2 序列化
	var snap := _gl.serialize_run()
	_check("S1 serialize_run 含 sublime 单键（{on, fission_layers}）",
		snap.has("sublime") and snap.get("sublime", {}) is Dictionary)
	var sub1: Dictionary = snap.get("sublime", {})
	_check("S1 默认态：on==false / fission_layers==0（skills 未升华零迁移）",
		not bool(sub1.get("on", true)) and int(sub1.get("fission_layers", -1)) == 0,
		str(sub1))
	_gl.player.set("skill_sublime", true)
	_gl.player.set("_reson_layers", 123)
	var snap2 := _gl.serialize_run()
	var sub2: Dictionary = snap2.get("sublime", {})
	_check("S2 升华态随档：on==true / fission_layers==123（duck 读口）",
		bool(sub2.get("on", false)) and int(sub2.get("fission_layers", -1)) == 123,
		str(sub2))
	_gl.player.set("skill_sublime", false)
	_gl.player.set("_reson_layers", 0)
	# S3 回填（skills 泳道 enable_sublime 合入前后双态兼容）
	var has_enable: bool = _gl.player.has_method(&"enable_sublime")
	_gl._restore_run_state({"character": "sentinel", "weapons": [], "level": 5,
		"max_hp": 60.0, "hp": 60.0, "sublime": {"on": true, "fission_layers": 77}})
	if has_enable:
		_check("S3 回填 on=true → enable_sublime 已调（skill_sublime==true 幂等）",
			bool(_gl.player.get("skill_sublime")))
		_check("S3 fission 层数专用口回填 77（clamp 0..500）",
			int(_gl.player.get("_reson_layers")) == 77)
	else:
		_check("S3 回填守卫：无 enable_sublime 期零崩溃（skill_sublime 保持 false）",
			not bool(_gl.player.get("skill_sublime")))
	_gl.player.set("skill_sublime", false)
	_gl.player.set("_reson_layers", 0)
	# S4 每日定种 / 常规 randomize
	_gl.start_run(24680)
	_check("S4 每日局升华流定种（seed==24680）",
		_gl.card_generator._sublime_rng.seed == 24680,
		"seed=%d" % _gl.card_generator._sublime_rng.seed)
	_gl.request_pause()                          # PLAYING→PAUSED（quit_to_menu 合法迁移前置）
	_gl.quit_to_menu()                           # PAUSED→MENU（quit_to_menu 状态机守卫）
	_gl.start_run()
	_check("S4 常规局升华流 randomize（≠24680 ≠构造种）",
		_gl.card_generator._sublime_rng.seed != 24680
			and _gl.card_generator._sublime_rng.seed != CardGenerator.SUBLIME_SEED)
	# S5 源级锚：三处注入口 + 序列化/回填行
	var src := FileAccess.get_file_as_string("res://scripts/loop/game_loop.gd")
	_check("S5 源级锚：reseed_sublime 三处（每日/常规/继续）",
		src.count("reseed_sublime") >= 3, "count=%d" % src.count("reseed_sublime"))
	_check("S5 源级锚：serialize sublime 落键 + restore enable_sublime 回填",
		src.contains("\"sublime\": sublime_snap") and src.contains("&\"enable_sublime\""))


func _check_continue(p_name: String, p_cond: bool) -> bool:
	# S 组前置断言（失败即跳过 S 组剩余——GameLoop 未 boot 无从续测）
	_check(p_name, p_cond)
	return p_cond


# ── 假人（Node 域——generate_candidates/apply_choice 形参类型守卫） ──
class BareStubPlayer extends Node:
	# 最小假人：无 enable_sublime（has_method 假——掷侧/apply 侧守卫态）
	var character_id: StringName = &"sentinel"
	var level := 10
	var unlocked_slots := 2
	var weapon_slots: Array = []


class StubPlayer extends BareStubPlayer:
	# 有技能假人：enable_sublime 计数（T5 幂等口径）
	var enable_calls := 0
	var sublime_on := false

	func enable_sublime() -> void:
		enable_calls += 1
		sublime_on = true


class SlotStubPlayer extends StubPlayer:
	# 槽位口假人：grant_slot_bonus 在身 → 金卡槽替换掷参与（T3/T10 更强对照）
	func slot_cap_total() -> int:
		return 4

	func grant_slot_bonus() -> void:
		pass

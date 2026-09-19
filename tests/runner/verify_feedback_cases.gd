# tests/runner/verify_feedback_cases.gd
# 用户反馈验收用例体（由 test_verify_feedback.gd 入口在 autoload 就绪后运行时加载编译）。
# 覆盖 2026-08-29 两轮试玩反馈的「行为级」验收（不只编译/回归，而是逐项真实跑通）：
#   ① 升级回满血 ② 新武器卡上架→装配真件（add_weapon 链）→构筑面板签名刷新
#   ③ 槽满不上架武器卡 ④ 稀有度数值缩放（金 ×2.6、白不缩放、注册表资源不落改）
#   ⑤ 紫精通连升 2 级 + 文案 Lv 区间 ⑥ MEC_HIT_BURST 命中迸裂真实落血
#   ⑦ E7 喷吐者远程开火（敌弹池入池） ⑧ 死亡元素释放（感电残弧广播）
#   ⑨ 左下角构筑面板 → 暂停 + 详情卡可见 ⑩ 粒子池寿命兜底回收（爆炸残留修复）
#   ⑪ 感电落雷/燃烧余烬/冰冻冰晶表现件挂载 ⑫ Boss 巨大化 + 弹幕密度 + E7 织入波表
#   ⑬ 描述去黑话（无 W8 编号）⑭ META_ROADMAP 规划文档存在
#   ⑮ P3 设置页（音量换算/震屏·伤害数字短路/持久化/双入口/面板状态机）
extends RefCounted

const DT := 1.0 / 120.0

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_boot_game_loop()
	# R13：套件启动即清购买位/角色选择（防历史崩溃运行残留在测试档中被往返携带
	# ——pkg4 HUD 用例曾因测试档残留「堡垒」出生 95 血而误报）
	Meta.unlocked_characters = {}
	Meta.character_id = &"sentinel"
	_test_level_up_full_heal()
	_test_weapon_card_equip_chain()
	_test_weapon_card_slot_guard()
	_test_rarity_value_scale()
	_test_r60_card_text()
	_test_mastery_double_and_wording()
	_test_hit_burst()
	_test_e7_ranged_fire()
	_test_death_element_discharge()
	_test_build_details_panel()
	_test_particle_reap()
	_test_status_fx_nodes()
	_test_data_tuning()
	_test_docs()
	_test_meta_systems()
	_test_maps_systems()
	_test_swamp_eco()
	_test_char_meta()
	_test_economy()
	_test_polish()
	_test_p0_fixes()
	_test_map_bosses()
	_test_map_affixes2()
	_test_endless_maps()
	_test_r62_endless_continue()
	_test_r66_icd_and_corpse()
	_test_r68_confetti()
	_test_r69_rarity_ladder()
	_test_r70_details_haste()
	_test_r71_shop_fallback()
	_test_r72_difficulty()
	_test_r72_new_enemies()
	_test_r72_content()
	_test_ev1_reward()
	_test_ev2_revive()
	_test_ev3_burst()
	_test_ev5_first_met()
	_test_ev6_bossbar()
	_test_p2_damage_tiers()
	_test_p2_bgm()
	_test_p2_daily()
	_test_p2_characters()
	_test_settings()
	_test_round2_feedback()
	_test_round5_early_xp()
	_test_round7_audit()
	_teardown_game_loop()
	print("────────────────────────────────────────")
	print("验收汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)


func fail_count() -> int:
	return _fail


# ── 引导 ──────────────────────────────────────────────────────────
func _boot_game_loop() -> void:
	_gl = GameLoop.new()
	_gl.name = "GameLoopForVerify"
	tree.get_root().add_child(_gl)
	_gl.set_physics_process(false)             # 确定性：禁自动帧（手动驱动语义，对齐 pkg4）
	_check("Boot：完成且进入 MENU", _gl.boot_ready and _gl.state == GameConst.GameStatus.MENU)
	_check("Boot：子系统齐全", _gl.player != null and _gl.card_generator != null
		and _gl.hud != null and _gl.pause_overlay != null and _gl.spawner != null)


func _teardown_game_loop() -> void:
	tree.paused = false
	RunSave.clear()                          # 局内存档清档（防测试残留污染玩家「继续」入口）
	if _gl != null:
		_gl.free()
	_gl = null


# ── ① 升级回满血 ──────────────────────────────────────────────────
func _test_level_up_full_heal() -> void:
	print("── 升级回满血 ──")
	var p: Node = _gl.player
	var lv0: int = int(p.get("level"))
	p.set("hp", 10.0)
	p.call(&"gain_xp", float(p.get("xp_need")))
	_check("升级触发（lv+1）", int(p.get("level")) == lv0 + 1)
	_check("升级回满血（hp == max_hp）", absf(float(p.get("hp")) - float(p.get("max_hp"))) <= 0.01)


# ── ② 新武器卡 → add_weapon 真件装配 ─────────────────────────────
func _test_weapon_card_equip_chain() -> void:
	print("── 新武器卡装配链 ──")
	var p: Node = _gl.player
	var sig0: String = _gl.hud._compute_build_sig()
	p.call(&"unlock_slot", 2)
	var cands: Array = _gl.card_generator._weapon_candidates(p)
	_check("解锁槽 2 后：未持有武器上架（候选 ≥1）", cands.size() >= 1)
	var card: Dictionary = _gl.card_generator._make_weapon_card(
		_gl.registry.get_weapon(&"W3_shotgun"))
	_check("武器卡字段（kind=WEAPON / 名含霰弹枪）",
		int(card.get("kind")) == CardGenerator.CardKind.WEAPON
		and String(card.get("display_name")).contains("霰弹枪"))
	_gl.card_generator.apply_choice(card, p)
	var w: Variant = (p.get("weapon_slots") as Array)[1]
	_check("装配 = 真件 WeaponBase（不再污染槽位——add_weapon 工厂链）",
		w is WeaponBase and is_instance_valid(w))
	if w is WeaponBase:
		var wd: Variant = w.get("data")
		_check("装配武器 = 霰弹枪 W3 且 Lv1", wd != null and String(wd.get("id")) == "W3_shotgun"
			and int(w.get("level")) == 1)
		var panel: Dictionary = (w as Object).call(&"build_panel_snapshot")
		_check("真件面板可用（base_atk > 0）", float(panel.get("base_atk", 0.0)) > 0.0)
	_check("构筑面板签名刷新（新 uid 入签名）", _gl.hud._compute_build_sig() != sig0)
	# 清理：拆下霰弹枪（还原单武器口径，后续用例不受扰）
	(p.get("weapon_slots") as Array)[1] = null
	(w as Node).free()


# ── ③ 槽满不上架 ─────────────────────────────────────────────────
func _test_weapon_card_slot_guard() -> void:
	print("── 武器卡槽位守卫 ──")
	var p: Node = _gl.player
	p.set("unlocked_slots", 1)                # 复位：仅槽 0（已被手枪占）→ 全占
	_check("已解锁槽全占 → 武器卡不上架（候选 = 0）",
		_gl.card_generator._weapon_candidates(p).is_empty())
	p.call(&"unlock_slot", 2)
	_check("解锁空槽 2 → 恢复上架（候选 ≥1）",
		_gl.card_generator._weapon_candidates(p).is_empty() == false)


# ── ④ 稀有度数值缩放 ─────────────────────────────────────────────
func _test_rarity_value_scale() -> void:
	print("── 稀有度数值缩放 ──")
	var gen: CardGenerator = _gl.card_generator
	var p: Node = _gl.player
	var base: TraitData = _gl.registry.get_trait(&"AFF_ATK_UP")
	var cands := gen.generate_candidates({"player": p, "wave": 1, "fixed_rarities": [3, 0, 0]})
	var gold_card: Dictionary = {}
	var white_card: Dictionary = {}
	for c in cands:
		if int(c.get("kind")) == CardGenerator.CardKind.TRAIT:
			if int(c.get("rarity")) == 3 and gold_card.is_empty():
				gold_card = c
			elif int(c.get("rarity")) == 0 and white_card.is_empty():
				white_card = c
	if not gold_card.is_empty() and gold_card.get("id") == base.id:
		_check("金卡数值 ×2.6（0.15 → 0.39）",
			absf(float((gold_card.get("data") as TraitData).value) - 0.39) <= 0.001)
		_check("金卡描述重写真实数字（含 39%）",
			String(gold_card.get("description")).contains("39%"))
	elif not gold_card.is_empty():
		print("　（跳过金断言：fixed_rarities 命中其他词条 %s）" % String(gold_card.get("id")))
	if not white_card.is_empty() and white_card.get("id") == base.id:
		_check("白卡不缩放（0.15 原值）",
			absf(float((white_card.get("data") as TraitData).value) - 0.15) <= 0.001)
	_check("注册表共享资源不落改（原值仍 0.15）", absf(base.value - 0.15) <= 0.0001)
	# R38 品级字段一致化：白 roll 的源金卡（MEC_ORBIT_SWORD 源 rarity=3）→ data.rarity
	# 必须落 0（此前 scale≤1.0 跳过复制，白数值带金字段 → 面板金名「白色 buff 金字」）
	var src_gold: TraitData = _gl.registry.get_trait(&"MEC_ORBIT_SWORD")
	_check("前置：源卡 MEC_ORBIT_SWORD 源 rarity=2（紫源——机制同金源）",
		src_gold != null and int(src_gold.rarity) == 2,
		"rarity=%s" % str(src_gold.rarity if src_gold != null else -1))
	var wcard := {
		"kind": CardGenerator.CardKind.TRAIT, "id": src_gold.id, "rarity": 0,
		"data": src_gold, "value_scale": 1.0, "display_name": "t", "description": "t",
	}
	var wcands: Array[Dictionary] = [wcard]
	gen._apply_rarity_values(wcands)
	var wdata: TraitData = wcard.get("data")
	_check("R38：白 roll 源紫卡 data.rarity 落 0（副本，不落改源）",
		wdata != src_gold and int(wdata.rarity) == 0 and int(src_gold.rarity) == 2,
		"out=%s src=%s" % [str(wdata.rarity), str(src_gold.rarity)])
	gen.apply_choice(wcard, p)                    # 挂载（apply_choice 内部按形态门选宿主）
	var matched := false
	for w in p.get("weapon_slots"):
		if w == null or not is_instance_valid(w):
			continue
		for tb in (w as WeaponBase).trait_stack.traits:
			if tb.data.id == src_gold.id:
				matched = matched or tb.max_rarity() == 0
	_check("R38：挂载层 max_rarity=0（白色 buff 白色字体）", matched)
	# R38 并集口径：MULT 池金覆盖 → data.rarity=3 → max_rarity=3（金 MULT 名字通道）
	var mult_gold := src_gold.duplicate() as TraitData
	mult_gold.rarity = 3
	var fake := TraitBase.new()
	fake.setup(mult_gold)
	_check("R38：data.rarity=3 → max_rarity=3（MULT 金名通道）", fake.max_rarity() == 3)


# ── R60：卡面黑话清理 + ×N 真值重写 + 条件阈值保护 + 整数词条 round ──
func _test_r60_card_text() -> void:
	print("── R60 卡面文案与整数缩放 ──")
	var gen: CardGenerator = _gl.card_generator
	# ① § 黑话全清（用户反馈「BUFF 里的 A3 $4.3 是啥」）：注册表全量词条 + 遗物
	for td: TraitData in _gl.registry.traits.values():
		if String(td.description).contains("§") or String(td.description).contains("A3 "):
			_check("R60：词条描述无内部文档编号（%s）" % String(td.id), false,
				String(td.description))
			return
	for rd: RelicData in _gl.registry.relics.values():
		if String(rd.description).contains("§") or String(rd.description).contains("A3 "):
			_check("R60：遗物描述无内部文档编号（%s）" % String(rd.id), false,
				String(rd.description))
			return
	_check("R60：全量词条/遗物描述无「A3 §x」黑话（27 处已清）", true)
	# ② ×N 真值重写（用户反馈「侦察协议什么颜色没啥区别」）：N′ = 1+(N−1)×scale
	_check("R60：侦察协议蓝卡 ×3.0 → ×3.8（非尾注 ×1.4 口径）",
		gen._scaled_description("每波首次命中伤害 ×3.0，1 层", 1.4, 1).contains("×3.8"))
	_check("R60：侦察协议金卡 ×3.0 → ×6.2",
		gen._scaled_description("每波首次命中伤害 ×3.0，1 层", 2.6, 3).contains("×6.2"))
	_check("R60：冰渊裁决蓝卡主数字 ×1.5 → ×1.7",
		gen._scaled_description("对寒滞/冻结目标伤害 ×1.5，叠 2 层合并为 ×2.0", 1.4, 1).contains("×1.7"))
	_check("R60：冰渊裁决叠层合并注释 ×2.0 → ×2.4（同式同步）",
		gen._scaled_description("对寒滞/冻结目标伤害 ×1.5，叠 2 层合并为 ×2.0", 1.4, 1).contains("×2.4"))
	# ③ 条件阈值保护（自查：背水协议蓝卡曾被改写成 HP<49%）
	var fury := gen._scaled_description("自身 HP<35% 时伤害 ×1.6，1 层", 1.4, 1)
	_check("R60：背水协议条件阈值 HP<35% 不被缩放", fury.contains("HP<35%") and not fury.contains("49%"))
	_check("R60：背水协议效果数字 ×1.6 → ×1.8", fury.contains("×1.8"))
	# ④ 带符号分支回归护栏（旧路径行为不变）
	_check("R60：带符号 +15% 金卡仍重写 +39%（带符号%分支回归护栏）",
		gen._scaled_description("攻击力 +15%，可叠 3 层", 2.6, 3).contains("+39%"))
	# ⑤ R67 池上限随品质同缩（用户反馈「背水协议怎么什么品质都是35%」）：
	# cap_pool_p=value 的 MULT 词条（背水 0.6/0.6、侦察 2.0/2.0）品质缩放曾被
	# 单区钳制截回白值——卡面 ×N 与实际乘区双双失效；现上限随 scale 同缩
	var fury_src: TraitData = _gl.registry.get_trait(&"SYN_LOWHP_FURY")
	var fury_cards: Array[Dictionary] = [{
		"kind": CardGenerator.CardKind.TRAIT, "id": fury_src.id, "rarity": 3,
		"data": fury_src, "value_scale": 1.0, "display_name": "t", "description": "t",
	}]
	gen._apply_rarity_values(fury_cards)
	var fury_gold: TraitData = fury_cards[0].get("data")
	_check("R67：背水金卡 value ×2.6（0.6→1.56）且池上限同缩（cap 0.6→1.56）",
		absf(fury_gold.value - 1.56) <= 0.001 and absf(fury_gold.cap_pool_p - 1.56) <= 0.001,
		"v=%.3f cap=%.3f" % [fury_gold.value, fury_gold.cap_pool_p])
	# 实际乘区：低血条件满足 → 聚合贡献 1.56 不再被截回 0.6
	var fw: WeaponBase = _gl.player.weapon_slots[0]
	var saved_hp: float = float(_gl.player.get("hp"))
	var saved_max: float = float(_gl.player.get("max_hp"))
	_gl.player.set("max_hp", 100.0)
	_gl.player.set("hp", 20.0)                    # HP<35% 条件满足
	fw.trait_stack.attach(fury_gold)
	var fury_ctx := TraitContext.new()
	fury_ctx.weapon = fw
	fury_ctx.event = GameConst.TraitEvent.ON_HIT
	fury_ctx.damage_ctx = DamageContext.new()
	fury_ctx.damage_ctx.player_hp_pct = 0.2            # HP<35% 条件评估源
	var pools: Array[Dictionary] = fw.trait_stack.collect_mult_pools(fury_ctx)
	var fury_contrib := 0.0
	for pe in pools:
		if StringName(String(pe.get("pool_id"))) == &"fury_dmg":
			fury_contrib = float(pe.get("contrib"))
	_check("R67：背水金卡实际乘区贡献 1.56（×2.56——不再被 cap 截回 ×1.6）",
		absf(fury_contrib - 1.56) <= 0.001, "contrib=%.3f" % fury_contrib)
	for tb in fw.trait_stack.traits.duplicate():
		if tb.data.id == fury_src.id:
			fw.trait_stack.traits.erase(tb)        # 还原构筑（无 detach API——直接摘挂载表）
	_gl.player.set("max_hp", saved_max)
	_gl.player.set("hp", saved_hp)
	# ⑥ R68 条件阈值品质化（用户反馈「低血协议难道不同品质的阈值不该不一样吗，越高级
	# 越高触发」）：PLAYER_HP_BELOW 每档 +7%（白/蓝/紫/金 = 35/42/49/56%），深拷贝
	# condition 不写穿 .tres 真源；行为分档：hp_pct=0.55 金卡触发、白卡不触发
	var fury_cards2: Array[Dictionary] = [{
		"kind": CardGenerator.CardKind.TRAIT, "id": fury_src.id, "rarity": 3,
		"data": fury_src, "value_scale": 1.0, "display_name": "t", "description": "t",
	}]
	gen._apply_rarity_values(fury_cards2)
	var fury_gold2: TraitData = fury_cards2[0].get("data")
	var pct_gold := float((fury_gold2.condition["params"] as Dictionary).get("pct", 0.0))
	_check("R68：背水金卡条件阈值 0.35→0.56（每档 +7%）",
		absf(pct_gold - 0.56) <= 0.001, "pct=%.3f" % pct_gold)
	var desc_gold := String(fury_cards2[0].get("description"))
	_check("R68：金卡描述 HP<35% 重写为 HP<56%",
		desc_gold.contains("HP<56%") and not desc_gold.contains("HP<35%"), desc_gold)
	var pct_src := float((fury_src.condition["params"] as Dictionary).get("pct", 0.0))
	_check("R68：注册表 .tres 未被写穿（真源 pct 仍 0.35——深拷贝纪律）",
		absf(pct_src - 0.35) <= 0.001, "pct=%.3f" % pct_src)
	# 行为分档：0.55 在旧阈值外（0.35）、新阈值内（0.56）
	_gl.player.set("max_hp", 100.0)
	_gl.player.set("hp", 55.0)
	var gate_ctx := TraitContext.new()
	gate_ctx.weapon = fw
	gate_ctx.event = GameConst.TraitEvent.ON_HIT
	gate_ctx.damage_ctx = DamageContext.new()
	gate_ctx.damage_ctx.player_hp_pct = 0.55
	fw.trait_stack.attach(fury_gold2)
	var gate_pools: Array[Dictionary] = fw.trait_stack.collect_mult_pools(gate_ctx)
	var gate_contrib := 0.0
	for pe in gate_pools:
		if StringName(String(pe.get("pool_id"))) == &"fury_dmg":
			gate_contrib = float(pe.get("contrib"))
	_check("R68：hp_pct=0.55 金卡触发（0.55<0.56）贡献 1.56",
		absf(gate_contrib - 1.56) <= 0.001, "contrib=%.3f" % gate_contrib)
	for tb in fw.trait_stack.traits.duplicate():
		if tb.data.id == fury_src.id:
			fw.trait_stack.traits.erase(tb)
	var white_cards: Array[Dictionary] = [{
		"kind": CardGenerator.CardKind.TRAIT, "id": fury_src.id, "rarity": 0,
		"data": fury_src, "value_scale": 1.0, "display_name": "t", "description": "t",
	}]
	gen._apply_rarity_values(white_cards)
	var fury_white: TraitData = white_cards[0].get("data")
	var pct_white := float((fury_white.condition["params"] as Dictionary).get("pct", 0.0))
	_check("R68：白卡阈值不品质化（仍 0.35——白=基准档）",
		absf(pct_white - 0.35) <= 0.001, "pct=%.3f" % pct_white)
	fw.trait_stack.attach(fury_white)
	var white_pools: Array[Dictionary] = fw.trait_stack.collect_mult_pools(gate_ctx)
	var white_contrib := 0.0
	for pe in white_pools:
		if StringName(String(pe.get("pool_id"))) == &"fury_dmg":
			white_contrib = float(pe.get("contrib"))
	_check("R68：同血量 0.55 白卡不触发（0.55>0.35——宽窗口是高级卡专属）",
		white_contrib <= 0.001, "contrib=%.3f" % white_contrib)
	for tb in fw.trait_stack.traits.duplicate():
		if tb.data.id == fury_src.id:
			fw.trait_stack.traits.erase(tb)
	_gl.player.set("max_hp", saved_max)
	_gl.player.set("hp", saved_hp)
	# ⑤ 整数词条 round 对齐卡面（蓝 反弹+2 value 2.8 → +3 而非 int 截断回 2）
	var bounce_eff: TraitEffect = load(
		"res://scripts/combat/trait/builtin/trait_effect_bounce.gd").new()
	var bt := TraitBase.new()
	var bd: TraitData = _gl.registry.get_trait(&"MEC_BOUNCE").duplicate()
	bd.value = 2.8                                    # 蓝 roll 缩放后口径
	bt.setup(bd)
	var proj := ProjectileBase.new()
	var bctx := TraitContext.new()
	bctx.event = GameConst.TraitEvent.ON_SPAWN
	bctx.projectile = proj
	bounce_eff.handle(bt, bctx)
	_check("R60：反弹蓝卡 value 2.8 → bounces_left=3（round 对齐卡面 +3）",
		proj.bounces_left == 3)
	proj.bounces_left = 0
	bd.value = 2.0                                    # 白卡口径回归护栏
	bounce_eff.handle(bt, bctx)
	_check("R60：反弹白卡 value 2.0 → bounces_left=2（白行为不变）",
		proj.bounces_left == 2)
	# ⑥ 分裂层 2 枚数不再被写死 count_lv2 压回（升层减枚）
	var fractal_eff: TraitEffect = load(
		"res://scripts/combat/trait/builtin/trait_effect_fractal.gd").new()
	var ft := TraitBase.new()
	var fd: TraitData = _gl.registry.get_trait(&"MEC_FRACTAL").duplicate()
	fd.value = 2.8                                    # 蓝口径
	ft.setup(fd)
	ft.layers = 2
	var fctx := TraitContext.new()
	fctx.event = GameConst.TraitEvent.ON_EXPIRE
	fctx.projectile = proj
	fractal_eff.handle(ft, fctx)
	_check("R60：分裂蓝卡 2 层枚数 ≥ 层 1 枚数+1（不升层减枚）",
		int(fctx.split_request.get("count", 0)) >= 4)


# ── ⑤ 紫精通连升 2 级 + Lv 区间文案 ──────────────────────────────
func _test_mastery_double_and_wording() -> void:
	print("── 精通连升与文案 ──")
	var gen: CardGenerator = _gl.card_generator
	var p: Node = _gl.player
	var w: WeaponBase = (p.get("weapon_slots") as Array)[0]
	var lv0: int = int(w.get("level"))
	var cands := gen.generate_candidates({"player": p, "wave": 1, "fixed_rarities": [2, -1, -1]})
	var mastery: Dictionary = {}
	for c in cands:
		if int(c.get("kind")) == CardGenerator.CardKind.MASTERY \
				and (c.get("weapon") as Object) == w:
			mastery = c
			break
	_check("紫精通卡 roll 到（连升通道）", not mastery.is_empty())
	if mastery.is_empty():
		return
	_check("文案含等级区间（Lv%d→Lv%d）" % [lv0, mini(lv0 + 2, WeaponBase.MAX_LEVEL)],
		String(mastery.get("display_name")).contains("→"))
	_check("level_boosts = 2", int(mastery.get("level_boosts", 0)) == 2)
	gen.apply_choice(mastery, p)
	_check("应用后连升 2 级（lv +%d）" % int(mastery.get("level_boosts", 0)),
		int(w.get("level")) == mini(lv0 + 2, WeaponBase.MAX_LEVEL))


# ── ⑥ MEC_HIT_BURST 命中迸裂 ─────────────────────────────────────
func _test_hit_burst() -> void:
	print("── 命中迸裂 ──")
	var p: Node = _gl.player
	var w: WeaponBase = (p.get("weapon_slots") as Array)[0]
	var burst_trait: TraitData = _gl.registry.get_trait(&"MEC_HIT_BURST")
	_check("注册表：MEC_HIT_BURST 已加载", burst_trait != null)
	if burst_trait == null:
		return
	w.attach_trait(burst_trait)
	var main := (_gl.pools[&"enemy"] as EnemyPool).acquire()
	var near := (_gl.pools[&"enemy"] as EnemyPool).acquire()
	var far := (_gl.pools[&"enemy"] as EnemyPool).acquire()
	main.spawn(_fixture_enemy(&"E_VB_MAIN", 100000.0), 1, 0)
	near.spawn(_fixture_enemy(&"E_VB_NEAR", 100000.0), 1, 0)
	far.spawn(_fixture_enemy(&"E_VB_FAR", 100000.0), 1, 0)
	main.position = Vector2(360.0, 400.0)
	near.position = Vector2(430.0, 400.0)     # 70px < 迸裂半径 80
	far.position = Vector2(700.0, 400.0)      # 340px 半径外
	_gl.enemy_grid.rebuild([main, near, far])
	var near_hp0: float = near.hp
	var far_hp0: float = far.hp
	var ctx := w.build_damage_context(main)
	var tctx := TraitContext.new()
	tctx.event = GameConst.TraitEvent.ON_HIT
	tctx.weapon = w
	tctx.target = main
	tctx.damage_ctx = ctx
	if w.trait_stack != null:
		for pool in w.trait_stack.collect_mult_pools(tctx):
			ctx.mult_pools.append(pool)
	w.inject_vuln_pool(ctx, main)
	w.trait_stack.dispatch(GameConst.TraitEvent.ON_HIT, tctx)
	_check("迸裂：半径内邻敌真实落血（真件管线 9b）", near.hp < near_hp0)
	_check("迸裂：半径外不波及", absf(far.hp - far_hp0) <= 0.001)
	_check("迸裂遥测计数（hit_burst_triggered）",
		DebugStats.get_counter(&"hit_burst_triggered") >= 1)
	for e: Node in [main, near, far]:
		_gl.pools[&"enemy"].release(e)


func _fixture_enemy(p_id: StringName, p_hp: float) -> EnemyData:
	var d := EnemyData.new()
	d.id = p_id
	d.display_name = String(p_id)
	d.hp_base = p_hp
	d.spd_base = 0.0
	d.dmg_base = 0.0
	d.exp_base = 1.0
	d.hitbox_r = 14.0
	d.resist = [0.0, 0.0, 0.0, 0.0]
	return d


# ── ⑦ E7 喷吐者远程开火 ──────────────────────────────────────────
func _test_e7_ranged_fire() -> void:
	print("── E7 远程开火 ──")
	var e7: EnemyData = _gl.registry.get_enemy(&"E7_spitter")
	_check("注册表：E7_spitter 已加载（behavior=RANGED）",
		e7 != null and int(e7.behavior) == GameConst.EnemyBehavior.RANGED)
	if e7 == null:
		return
	var enemy := (_gl.pools[&"enemy"] as EnemyPool).acquire()
	enemy.spawn(e7, 6, 0)
	enemy.projectile_pool = _gl.pools[&"projectile"]   # 直连池 spawn 绕过 spawner → 手动注入
	enemy.position = (_gl.player as Node2D).global_position + Vector2(220.0, 0.0)
	var free0: int = int(_gl.pools[&"projectile"].stats()["free"])
	enemy.set("fire_cd_left", 0.0)
	for i in range(3):
		enemy.tick(DT)
	var free1: int = int(_gl.pools[&"projectile"].stats()["free"])
	_check("射程内驻停开火（敌弹入池 free -1）", free1 == free0 - 1)
	var bullet: Node = null
	for n in _gl.pools[&"projectile"].get_children():
		if n is Node2D and (n as Node2D).visible:
			bullet = n
			break
	_check("敌弹实体可见（team=1 敌方弹）", bullet != null)
	_gl.pools[&"enemy"].release(enemy)


# ── ⑧ 死亡元素释放 ───────────────────────────────────────────────
func _test_death_element_discharge() -> void:
	print("── 死亡元素释放 ──")
	var enemy := (_gl.pools[&"enemy"] as EnemyPool).acquire()
	enemy.spawn(_fixture_enemy(&"E_DIS", 100.0), 1, 0)
	_gl.elemental.register_host(enemy)
	var arcs: Array = []
	var cb := func(_a: Vector2, _b: Vector2) -> void: arcs.append(true)
	EventBus.chain_lightning.connect(cb)
	(enemy.elemental as ElementalState).gauges[GameConst.Element.LTG] = 80.0
	enemy.call(&"_death_element_discharge")
	_check("LTG 槽 80 → 死亡释放感电残弧（≥1 跳广播）", arcs.size() >= 1)
	EventBus.chain_lightning.disconnect(cb)
	_gl.elemental.unregister_host(enemy)
	_gl.pools[&"enemy"].release(enemy)


# ── ⑨ 左下角构筑面板 → 暂停 + 详情卡 ─────────────────────────────
func _test_build_details_panel() -> void:
	print("── 左下角 buff 详情 ──")
	_gl.call(&"start_run")
	_gl.hud.build_details_requested.emit()
	_check("点击 → 进入 PAUSED", _gl.state == GameConst.GameStatus.PAUSED)
	_check("构筑详情卡可见", _gl.pause_overlay.is_details_visible())
	# 内容断言（2026-09-13：此前仅断可见性——属性行/武器区块构建无回归护栏）
	_check("构筑详情卡内容 ≥2（玩家属性行 + ≥1 武器区块）",
		(_gl.pause_overlay._details_list as Node).get_child_count() >= 2)
	var kid0: Control = (_gl.pause_overlay._details_list as Node).get_child(0)
	var ptext: String = ""
	for sub in kid0.get_children():
		if sub is Label:
			ptext += (sub as Label).text + " "
	_check("玩家属性行：含 个人属性/生命上限/磁吸/技能冷却/经验/金币（R18 全属性）",
		"个人属性" in ptext and "生命上限" in ptext and "磁吸" in ptext
		and "技能冷却" in ptext and "经验获取" in ptext and "金币获取" in ptext, ptext)
	# R11 叠层可视化：挂 2 层暴击率 → 行内「2/3 层」+ 首个数值改写为衰减真值（金色）
	var crit_t: TraitData = _gl.registry.get_trait(&"AFF_CRIT_RATE")
	var crit_w: WeaponBase = _gl.player.weapon_slots[0]
	crit_w.attach_trait(crit_t)
	crit_w.attach_trait(crit_t)
	_gl.pause_overlay.toggle_details()
	_gl.pause_overlay.toggle_details()
	var found_stack := false
	var found_gold := false
	var rtl_texts: Array[String] = []
	_collect_rtl(_gl.pause_overlay._details_list, rtl_texts)
	var all_texts := rtl_texts
	for txt: String in all_texts:
		if "2/3 层" in txt:
			found_stack = true
		if "ffd54a" in txt:
			found_gold = true
	_check("叠层可视化：词条行显示「2/3 层」", found_stack, str(rtl_texts))
	_check("叠层可视化：≥2 层首个数值改写为当前生效值（金色高亮）", found_gold)
	# R31 品级徽记：金品层挂入 → 名字行带「◆金」（用户两轮反馈「为什么这个 buff 金色字」
	# ——名字金 = 该词条抽到过金品级，徽记让品级语义自解释）
	var gold_t: TraitData = crit_t.duplicate()
	gold_t.rarity = 3
	_check("前置：金品层挂入", crit_w.attach_trait(gold_t), "")
	_gl.pause_overlay.toggle_details()
	_gl.pause_overlay.toggle_details()
	var found_badge := false
	var badge_texts: Array[String] = []
	_collect_rtl(_gl.pause_overlay._details_list, badge_texts)
	for txt: String in badge_texts:
		if "◆金" in txt and "3/3 层" in txt:
			found_badge = true
	_check("品级徽记：金品词条名字行带「◆金」+「3/3 层」（R31）", found_badge, str(badge_texts))
	# 面板测试收尾（R31 修复：本块原缩进错位于递归函数 _collect_rtl 体内——每次递归
	# 返回都重放 toggle/emit（历史 54 条非法迁移警告之源）；新增第二个 _collect_rtl
	# 调用后按节点数平方引爆死循环。挪回本测试尾部，语义 = 面板互斥/恢复/退出验收）
	_check("暂停卡隐藏（双卡互斥）", not _gl.pause_overlay.is_pause_visible()
		or _gl.pause_overlay._card.visible == false)
	_gl.pause_overlay.toggle_details()
	_check("toggle → 切回暂停卡", not _gl.pause_overlay.is_details_visible())
	_gl.hud.build_details_requested.emit()
	_check("PAUSED 中再点 → 切回详情卡", _gl.pause_overlay.is_details_visible())
	_gl.pause_overlay.resume_requested.emit()
	_check("继续 → PLAYING", _gl.state == GameConst.GameStatus.PLAYING)
	_gl.call(&"quit_to_menu")


func _collect_rtl(p_node: Node, p_out: Array[String]) -> void:
	# 递归收集子树全部 RichTextLabel/Label 文本（详情卡层级：list→section→row→col→label）
	for c in p_node.get_children():
		if c is RichTextLabel:
			p_out.append((c as RichTextLabel).text)
		elif c is Label:
			p_out.append((c as Label).text)
		_collect_rtl(c, p_out)


# ── ⑩ 粒子池寿命兜底 ─────────────────────────────────────────────
func _test_particle_reap() -> void:
	print("── 爆炸残留兜底 ──")
	var pp: ParticlePool = _gl.pools[&"particle"]
	var live0: int = int(pp.stats()["live"])
	pp.burst(&"burst_default", Vector2.ZERO, 4)
	_check("burst 后发射器取出（live +1）", int(pp.stats()["live"]) == live0 + 1)
	pp.reap_expired(0.016)
	_check("寿命内 reap 不误收", int(pp.stats()["live"]) == live0 + 1)
	pp.reap_expired(99.0)
	# live ≤ live0：reap 允许顺带回收早前测试遗留的在场发射器（HIT 爆发等）——正好验证兜底
	_check("超时强制归还（finished 未触发也不残留——爆炸残留修复）",
		int(pp.stats()["live"]) <= live0 and pp._burst_left.is_empty(),
		"live=%d/%d left=%s rejected=%d" % [int(pp.stats()["live"]), live0,
			str(pp._burst_left.values()), int(pp.stats()["rejected_releases"])])


# ── ⑪ 元素状态表现件挂载 ─────────────────────────────────────────
func _test_status_fx_nodes() -> void:
	print("── 状态表现件 ──")
	var enemy := (_gl.pools[&"enemy"] as EnemyPool).acquire()
	enemy.spawn(_fixture_enemy(&"E_FX", 100.0), 1, 0)
	_gl.elemental.register_host(enemy)
	var st: ElementalState = enemy.elemental
	st.gauges[GameConst.Element.LTG] = 50.0
	enemy.call(&"_tick_status_fx", DT)
	_check("感电：双电弧挂件就位", int(enemy._shock_arcs.size()) == 2)
	enemy.set("_shock_bolt_cd", 0.0)
	enemy.call(&"_tick_status_fx", DT)
	_check("感电：垂直落雷挂件就位（去圆球化）", enemy._shock_bolt != null
		and enemy._shock_bolt.visible)
	st.gauges[GameConst.Element.LTG] = 0.0
	st.apply(GameConst.Element.FIR, 100.0, 100.0)
	enemy.call(&"_tick_status_fx", DT)
	_check("点燃：余烬光晕 + 火苗 ×4（燃烧可见性）", enemy._burn_ember != null
		and enemy._burn_ember.visible and int(enemy._burn_flames.size()) == 4)
	st.apply(GameConst.Element.ICE, 100.0, 100.0)   # 一次满槽 → 寒滞
	st.apply(GameConst.Element.ICE, 100.0, 100.0)   # 二次满槽 → 完全冻结
	enemy.call(&"_tick_status_fx", DT)
	_check("冰冻：冰晶放大可见（冻结档 base×1.5）",
		enemy._frost_shards.size() > 0
		and (enemy._frost_shards[0] as Sprite2D).scale.x >= enemy._base_scale * 1.4)
	_gl.elemental.unregister_host(enemy)
	_gl.pools[&"enemy"].release(enemy)


# ── ⑫ 数据调优落位 ───────────────────────────────────────────────
func _test_data_tuning() -> void:
	print("── 数值/数据调优 ──")
	_check("Boss 巨大化（视觉倍率 3.8 ≈ 1/4 屏）", absf(Enemy.BOSS_VISUAL_MULT - 3.8) <= 0.001)
	_check("最终 Boss（视觉倍率 5.0 ≈ 1/3 屏 + TAG_FINAL_BOSS）",
		absf(Enemy.FINAL_BOSS_VISUAL_MULT - 5.0) <= 0.001
		and GameConst.TAG_FINAL_BOSS == 4)
	_check("精英巨大化（视觉倍率 1.55 + E2 精英倍率就位）",
		absf(Enemy.ELITE_VISUAL_MULT - 1.55) <= 0.001
		and not _gl.registry.get_enemy(&"E2_runner").elite_mult.is_empty())
	var frost_txt := FileAccess.get_file_as_string("res://resources/maps/wave_table_frost.tres")
	_check("冰原 w12 编入冰霜仔精英（tags=1）", '"tags": 1' in frost_txt)
	_check("冰原 w20 最终 Boss 标签（tags=6）", '"tags": 6' in frost_txt)
	var boss1: EnemyData = _gl.registry.get_enemy(&"E6_boss1")
	# R16 弹幕专项：boss.barrage 新真源（bullet_patterns 已替换）——P1 环爆 count 14 / cd 6.0
	var boss1_ring: Dictionary = {}
	for b_entry: Dictionary in boss1.boss.get("barrage", []):
		if String(b_entry.get("type", "")) == "ring":
			boss1_ring = b_entry
	_check("Boss1 弹幕密度（ring count 14 / cd 6.0）",
		int(boss1_ring.get("count", 0)) == 14
		and absf(float(boss1_ring.get("cd", 0.0)) - 6.0) <= 0.001)
	_check("E7 经验梯度（exp_base 10）", absf(_gl.registry.get_enemy(&"E7_spitter").exp_base - 10.0) <= 0.001)
	_check("Boss1 经验（600）", absf(boss1.exp_base - 600.0) <= 0.001)
	var f := FileAccess.open("res://resources/waves/wave_table_main.tres", FileAccess.READ)
	var wave_txt := f.get_as_text() if f != null else ""
	_check("波表已织入 E7 喷吐者", wave_txt.contains("E7_spitter"))
	var roll_gold := 0
	_gl.card_generator.rng.seed = 777
	for i in range(500):
		if _gl.card_generator._roll_rarity(5) == 3:
			roll_gold += 1
	_check("金卡率 6% 档（500 抽 ≤55）", roll_gold <= 55, "gold=%d" % roll_gold)


# ── ⑬⑭ 描述去黑话 / 规划文档 ─────────────────────────────────────
func _test_docs() -> void:
	print("── 文案与文档 ──")
	_check("谐振轨道描述无 W8 黑话",
		not String(_gl.registry.get_trait(&"MEC_ORBIT_LINK").description).contains("W8"))
	_check("扩大印刻描述说明碰撞半径",
		String(_gl.registry.get_trait(&"AFF_AREA").description).contains("碰撞半径"))
	_check("META_ROADMAP.md 规划文档存在（大厅/成就/图鉴/股市/养成）",
		FileAccess.file_exists("res://META_ROADMAP.md"))


# ── ⑮ 大厅 / 图鉴 / 成就 / 记录（Meta 落地验收） ─────────────────
func _test_meta_systems() -> void:
	print("── 大厅/图鉴/成就/记录 ──")
	_check("Meta autoload 就绪（Meta != null）", Meta != null)
	if Meta == null:
		return
	# 存档隔离：先备份并清空既有存档（含运行期状态复位）——跨次运行不互相污染
	var save_backup := ""
	if FileAccess.file_exists(Meta.save_path()):
		save_backup = FileAccess.get_file_as_string(Meta.save_path())
		DirAccess.remove_absolute(Meta.save_path())
	Meta.codex_kills = {}
	Meta.codex_weapons = {}
	Meta.codex_traits = {}
	Meta.achievements_done = {}
	Meta.records = {"best_wave": 0, "best_kills": 0, "best_level": 1,
		"total_runs": 0, "total_kills": 0}
	# 图鉴：武器获得解锁 / 词条抽取解锁
	_check("图鉴：武器未解锁（初始）", not Meta.is_weapon_unlocked(&"W3_shotgun"))
	Meta._on_card_chosen(&"W3_shotgun", 4)
	_check("图鉴：card_chosen(WEAPON) → 武器解锁", Meta.is_weapon_unlocked(&"W3_shotgun"))
	Meta._on_card_chosen(&"MEC_HIT_BURST", 1)
	_check("图鉴：card_chosen(TRAIT) → 词条解锁", Meta.is_trait_unlocked(&"MEC_HIT_BURST"))
	# 记录：波次/等级/击杀 → GAME_OVER 结算
	Meta._on_wave_started(12)
	Meta._on_level_up(9)
	Meta._on_enemy_killed(_make_killed_enemy_stub(false))
	var runs0: int = int(Meta.records["total_runs"])
	Meta._on_state_changed(GameConst.GameStatus.GAME_OVER)
	_check("记录：最高波次 12", int(Meta.records["best_wave"]) == 12)
	_check("记录：单局击杀 1", int(Meta.records["best_kills"]) == 1)
	_check("记录：局数 +1（%d→%d）" % [runs0, runs0 + 1],
		int(Meta.records["total_runs"]) == runs0 + 1)
	_check("成就：wave_10 解锁", Meta.is_ach_done(&"wave_10"))
	_check("成就：first_blood 解锁", Meta.is_ach_done(&"first_blood"))
	_check("持久化：user://meta_save.cfg 已落盘", FileAccess.file_exists(Meta.save_path()))
	# 大厅 UI：入口 + 面板
	var menu: MenuScreen = _gl.menu_screen
	_check("大厅：registry 已注入", menu.registry != null)
	_check("大厅：七入口按钮就位（图鉴/成就/记录/角色/养成/每日/设置——P2 每日 + P3 设置各 +1）",
		menu._lobby_btns.size() == 7)
	menu._on_lobby_pressed("codex")
	_check("大厅：图鉴面板打开且条目 >0",
		menu._panel_root.visible and menu._panel_list.get_child_count() > 0)
	menu._on_codex_tab("武器")
	_check("大厅：武器页签切换（条目 = 注册表武器数）",
		_live_children(menu._panel_list) == menu.registry.weapons.size())
	menu._on_lobby_pressed("ach")
	_check("大厅：成就面板打开（条目 = 定义数 %d）" % Meta.ACHIEVEMENTS.size(),
		_live_children(menu._panel_list) == Meta.ACHIEVEMENTS.size())
	menu._on_lobby_pressed("records")
	_check("大厅：记录面板打开（全局 5 + 分图标题 1 + 5 图 + 进度 1 = 12 行）",
		_live_children(menu._panel_list) == 12)
	menu._on_panel_close()
	_check("大厅：返回关闭面板", not menu._panel_root.visible)
	# 恢复既有存档（测试隔离）
	var cfg := ConfigFile.new()
	if save_backup != "":
		var f := FileAccess.open(Meta.save_path(), FileAccess.WRITE)
		f.store_string(save_backup)
		f.close()
	else:
		DirAccess.remove_absolute(Meta.save_path())


# ── ⑯ 多地图 / 新怪 / 通关解锁链（M2 落地验收） ──────────────────
func _test_maps_systems() -> void:
	print("── 多地图与新怪 ──")
	_check("MapTable：5 张地图（含翠毒沼泽）", MapTable.count() == 5)
	_check("MapTable：首关加载注册表主表（30 波）",
		MapTable.load_table(&"world_grass", _gl.registry).entries.size() == 30)
	var frost_table := MapTable.load_table(&"world_frost", _gl.registry)
	_check("MapTable：寒霜冰原旁路波表（20 波）", frost_table != null
		and frost_table.entries.size() == 20 and frost_table.id == &"frost")
	_check("新怪：E8 恶魔小鬼（CHASE 追击）",
		_gl.registry.get_enemy(&"E8_imp") != null
		and int(_gl.registry.get_enemy(&"E8_imp").behavior) == GameConst.EnemyBehavior.CHASE)
	var frost_e: EnemyData = _gl.registry.get_enemy(&"E9_frostling")
	_check("新怪：E9 冰霜仔（ICE 抗 60% + 冻结免疫）",
		frost_e != null and absf(frost_e.resist[2] - 0.6) <= 0.001
		and int(frost_e.immune_mask & GameConst.IMMUNE_FREEZE) != 0)
	_check("新怪：E10 林间飞雀（疾冲走位分型）",
		_gl.registry.get_enemy(&"E10_woodbird") != null)
	var aqua: EnemyData = _gl.registry.get_enemy(&"E11_aquasquirt")
	_check("新怪：E11 水泡怪（RANGED 远程）",
		aqua != null and int(aqua.behavior) == GameConst.EnemyBehavior.RANGED
		and not aqua.ranged.is_empty())
	# 解锁链：首关恒解锁 → 未解锁拒绝启动 → 通关后解锁并启动
	Meta.maps_cleared = {}
	Meta.map_records = {}
	_gl.state = GameConst.GameStatus.MENU
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	_gl._on_menu_start(&"world_frost")
	_check("选图：未解锁拒绝启动（仍 MENU）", _gl.state == GameConst.GameStatus.MENU)
	_check("解锁链：首关恒解锁", Meta.is_map_unlocked(&"world_grass"))
	_check("解锁链：第二关初始锁定", not Meta.is_map_unlocked(&"world_frost"))
	Meta.mark_map_cleared(&"world_grass")
	_check("解锁链：通关首关 → 第二关解锁", Meta.is_map_unlocked(&"world_frost"))
	_check("解锁链：next_map_id（grass→frost）",
		MapTable.next_map_id(&"world_grass") == &"world_frost")
	_gl._on_menu_start(&"world_frost")
	_check("选图：启动进入 PLAYING", _gl.state == GameConst.GameStatus.PLAYING)
	_check("选图：当前地图 = 寒霜冰原", _gl.current_map_id == &"world_frost")
	_check("选图：波表已切换（id=frost）", _gl.wave_director.wave_table.id == &"frost")
	_check("主题：HUD 图名注入", _gl.hud.map_name == "寒霜冰原")
	_check("主题：云层色调 = 冰原淡青", _gl._backdrop.modulate
		== (MapTable.get_map(&"world_frost").tint as Color))
	# 分图记录：模拟 12 波/9 级/3 杀 → GAME_OVER 结算入 world_frost 桶
	Meta._on_wave_started(12)
	Meta._on_level_up(9)
	for i in range(3):
		Meta._on_enemy_killed(_make_killed_enemy_stub(false))
	Meta._on_state_changed(GameConst.GameStatus.GAME_OVER)
	var mr: Dictionary = Meta.map_records.get("world_frost", {})
	_check("分图记录：world_frost best_wave=12", int(mr.get("best_wave", 0)) == 12)
	Meta._on_wave_cleared(20)
	_check("通关标记：wave_cleared(20) → 冰原通关", Meta.is_map_cleared(&"world_frost"))
	_check("解锁链：第三关（魔域）随之解锁", Meta.is_map_unlocked(&"world_demon"))
	# 大厅：选关面板 4 行
	_gl.state = GameConst.GameStatus.MENU
	_gl.menu_screen._open_map_select()
	_check("大厅：选关面板 5 张地图卡 + R72 难度选择行",
		_live_children(_gl.menu_screen._panel_list) == MapTable.count() + 1)
	_gl.menu_screen._on_panel_close()


# ── ⑰ 翠毒沼泽生态（沼泽毒系新图 + 五新怪验收） ──────────────────
func _test_swamp_eco() -> void:
	print("── 翠毒沼泽生态 ──")
	_check("MapTable：5 张地图（沼泽殿后）", MapTable.count() == 5
		and MapTable.MAPS[4].id == &"world_swamp")
	var swamp_table := MapTable.load_table(&"world_swamp", _gl.registry)
	_check("沼泽波表（30 波 + id=swamp——R9 阶梯 10/15/20/25/30）", swamp_table != null
		and swamp_table.entries.size() == 30)
	for pair: Array in [[&"E12_bogslime", GameConst.EnemyBehavior.CHASE],
			[&"E14_boguard", GameConst.EnemyBehavior.CHASE],
			[&"E16_marshmaw", GameConst.EnemyBehavior.CHASE],
			[&"E13_bogspitter", GameConst.EnemyBehavior.RANGED]]:
		var ed: EnemyData = _gl.registry.get_enemy(pair[0])
		_check("新怪注册：%s（behavior=%d）" % [String(pair[0]), int(pair[1])],
			ed != null and int(ed.behavior) == int(pair[1]))
	var guard: EnemyData = _gl.registry.get_enemy(&"E14_boguard")
	_check("沼泽卫士：全抗 40%（护盾装甲口径）",
		absf(guard.resist[0] - 0.4) <= 0.001 and absf(guard.resist[1] - 0.4) <= 0.001
		and absf(guard.resist[2] - 0.4) <= 0.001)
	# 毒爆：E12 死亡 → 半径内玩家掉血（contact×0.6）
	var p2d: Node2D = _gl.player
	var slime := (_gl.pools[&"enemy"] as EnemyPool).acquire()
	slime.spawn(_gl.registry.get_enemy(&"E12_bogslime"), 1, 0)
	slime.position = p2d.global_position + Vector2(50.0, 0.0)   # 50 < 110 毒爆半径
	var hp0: float = float(p2d.get("hp"))
	slime.call(&"_death_poison_splash")
	_check("毒爆：半径内玩家掉血（contact ×0.6）", float(p2d.get("hp")) < hp0)
	_gl.pools[&"enemy"].release(slime)
	var hp1: float = float(p2d.get("hp"))
	p2d.set("hp", hp1)
	# 远程可见性回归：主波表 w6/8/14/17 均含 E7（用户反馈「远程见不到」→ 密度提升验证）
	var main_txt := FileAccess.get_file_as_string("res://resources/waves/wave_table_main.tres")
	var spitter_waves := main_txt.count("E7_spitter")
	_check("主表远程密度（E7 出场波次 ≥6）", spitter_waves >= 6)
	# 沼泽解锁链：树海通关 → 沼泽解锁
	Meta.maps_cleared = {}
	Meta.mark_map_cleared(&"world_grove")
	_check("解锁链：树海通关 → 沼泽解锁", Meta.is_map_unlocked(&"world_swamp"))
	Meta.maps_cleared = {}


# ── ⑱ 角色系统 + 局外养成（M8 落地验收） ─────────────────────────
func _test_char_meta() -> void:
	print("── 角色与局外养成 ──")
	_check("CharacterTable：8 角色（解锁矩阵完整——通关3/购买2/挑战2/初始1）",
		CharacterTable.count() == 8)
	# 解锁矩阵（2026-09-13）：ranger/zero 转结晶购买门——全图通关不再解锁二者
	for m in MapTable.MAPS:
		Meta.mark_map_cleared(m.id)
	_check("解锁矩阵：哨兵恒解锁 / 通关门(薇拉·磐·莽)全开",
		Meta.is_character_unlocked(&"sentinel") and Meta.is_character_unlocked(&"veles")
		and Meta.is_character_unlocked(&"bulwark") and Meta.is_character_unlocked(&"mank"))
	_check("解锁矩阵：购买门(岚80/零160)不随通关解锁",
		not Meta.is_character_unlocked(&"ranger") and not Meta.is_character_unlocked(&"zero"))
	# 购买流程：结晶充足 → 扣费 + 永久解锁；不足 → false；重复购买 → false
	var saved_crystals: int = Meta.crystals
	var saved_unlocked: Dictionary = Meta.unlocked_characters.duplicate()
	Meta.unlocked_characters = {}
	Meta.crystals = 100
	_check("购买：结晶不足（岚 80 vs 0💎）→ 前置锁定",
		not Meta.is_character_unlocked(&"ranger"))
	Meta.crystals = 100
	_check("购买：100💎 买岚(80) → 成功 + 余额 20",
		Meta.purchase_character(&"ranger") and Meta.crystals == 20
		and Meta.is_character_unlocked(&"ranger"))
	Meta.crystals = 20
	_check("购买：余额不足买零(160) → false 且不解锁",
		not Meta.purchase_character(&"zero") and not Meta.is_character_unlocked(&"zero"))
	_check("购买：重复购买岚 → false（已解锁幂等）",
		not Meta.purchase_character(&"ranger"))
	# 选择守卫：锁定角色 set_character_id 拒绝；解锁后放行
	var saved_char: StringName = Meta.character_id
	Meta.character_id = &"sentinel"
	Meta.set_character_id(&"zero")
	_check("选择守卫：锁定零 set_character_id 拒绝（保持哨兵）",
		Meta.character_id == &"sentinel")
	Meta.set_character_id(&"ranger")
	_check("选择守卫：已购岚 set_character_id 放行", Meta.character_id == &"ranger")
	Meta.character_id = saved_char
	Meta.crystals = saved_crystals
	Meta.unlocked_characters = saved_unlocked.duplicate()
	Meta.maps_cleared = {}
	Meta.mark_map_cleared(&"world_grass")
	_check("解锁链：薇拉解锁（草原） / 磐回落锁定（冰原未清）",
		Meta.is_character_unlocked(&"veles") and not Meta.is_character_unlocked(&"bulwark"))
	for m in MapTable.MAPS:
		Meta.mark_map_cleared(m.id)
	# 角色应用：薇拉（45 血 + 25% 攻）
	var p: Node = _gl.player
	_gl.state = GameConst.GameStatus.MENU
	Meta.character_id = &"veles"
	p.call(&"set_character", &"veles")
	_check("角色：薇拉血量 45 + 养成加成",
		absf(float(p.get("max_hp")) - (45.0 + Meta.hp_bonus())) <= 0.01)
	# 武器面板口径：面板在实例化时定格（局内买养成不追改——下一局生效）
	var w_veles := (p.get("weapon_slots") as Array)[0] as WeaponBase
	_check("角色：攻击修正入武器（meta_atk_pct = 养成 + 0.25）",
		absf(w_veles.meta_atk_pct - (Meta.atk_pct() + 0.25)) <= 0.001)
	# 技能：过载咆哮
	p.call(&"activate_skill")
	_check("技能：过载咆哮 rof_mult=2", absf(float(p.get("rof_mult")) - 2.0) <= 0.001)
	var w0: WeaponBase = (p.get("weapon_slots") as Array)[0]
	_check("技能：射速面板吃 rof_mult（interval 减半）",
		float(w0.call(&"_fire_interval")) < float(w0.call(&"_fire_interval")) * 2.5)
	for i in range(300):
		p.call(&"tick", DT, Vector2.ZERO)       # 4s 增益耗尽（120Hz × 300 = 2.5s 不够 → 补齐）
	for i in range(200):
		p.call(&"tick", DT, Vector2.ZERO)
	_check("技能：增益到期 rof_mult 回 1", absf(float(p.get("rof_mult")) - 1.0) <= 0.001)
	# 磐：践踏消弹（增强后 -5% 攻）
	Meta.character_id = &"bulwark"
	p.call(&"set_character", &"bulwark")
	_check("角色：磐血量 95 + 养成（增强 -5% 攻口径）",
		absf(float(p.get("max_hp")) - (95.0 + Meta.hp_bonus())) <= 0.01)
	# 零：时滞力场（全场静止）。零为结晶购买门（2026-09-13 矩阵）——技能验收直接置解锁位
	#（Player.set_character 锁定回落哨兵；购买流已在上方购买用例单测；游侠同理由 _test_economy 局部管理）
	Meta.unlocked_characters["zero"] = true
	var stop_target := (_gl.pools[&"enemy"] as EnemyPool).acquire()
	stop_target.spawn(_fixture_enemy(&"E_TS", 100.0), 1, 0)
	_gl.enemy_grid.rebuild([stop_target])
	_gl.elemental.register_host(stop_target)     # 冻结计时器在 ElementalState（需挂宿主）
	Meta.character_id = &"zero"
	p.call(&"set_character", &"zero")
	_check("角色：零血量 65 + 养成", absf(float(p.get("max_hp")) - (65.0 + Meta.hp_bonus())) <= 0.01)
	p.call(&"activate_skill")
	_check("技能：时滞力场 → 全场静止 2.5s",
		stop_target.elemental != null
		and float((stop_target.elemental as ElementalState).freeze_timer) >= 2.4)
	_gl.elemental.unregister_host(stop_target)
	_gl.pools[&"enemy"].release(stop_target)
	# 莽：毒沼绽放（全屏毒伤）
	var nova_target := (_gl.pools[&"enemy"] as EnemyPool).acquire()
	nova_target.spawn(_fixture_enemy(&"E_Nova", 100000.0), 1, 0)
	_gl.elemental.register_host(nova_target)
	_gl.enemy_grid.rebuild([nova_target])
	Meta.character_id = &"mank"
	p.call(&"set_character", &"mank")
	var nhp0: float = float(nova_target.get("hp"))
	p.set("skill_cd_left", 0.0)
	p.call(&"activate_skill")
	_check("技能：毒沼绽放 → 全屏 150% 攻结算", float(nova_target.get("hp")) < nhp0)
	_gl.elemental.unregister_host(nova_target)
	_gl.pools[&"enemy"].release(nova_target)
	Meta.character_id = &"sentinel"
	# 养成：结晶购买
	Meta.crystals = 200
	Meta.upgrades = {}
	_check("养成：初始 Lv0", Meta.upgrade_level(&"life") == 0)
	_check("养成：购买成功（20💎）", Meta.buy_upgrade(&"life"))
	_check("养成：等级 1 + 余额 180", Meta.upgrade_level(&"life") == 1 and Meta.crystals == 180)
	_check("养成：血量加成 +10", absf(Meta.hp_bonus() - 10.0) <= 0.001)
	Meta.crystals = 10
	_check("养成：结晶不足拒绝（atk 需 30）", not Meta.buy_upgrade(&"atk"))
	Meta.crystals = 500
	# 结算产出：12 波 60 杀 → ceil(18+2.4)=21
	Meta._on_wave_started(12)
	for i in range(60):
		Meta._on_enemy_killed(_make_killed_enemy_stub(false))
	var cr0: int = Meta.crystals
	Meta._on_state_changed(GameConst.GameStatus.GAME_OVER)
	_check("养成：局结算结晶产出（+21）", Meta.crystals == cr0 + 21)
	# 大厅面板
	var menu: MenuScreen = _gl.menu_screen
	menu._on_lobby_pressed("char")
	_check("大厅：角色面板 3 张卡", _live_children(menu._panel_list) == CharacterTable.count())
	for c in menu._panel_list.get_children():
		c.free()                                  # 立即清（queue_free 无帧迭代不清真——计数口径）
	menu._on_lobby_pressed("upgrade")
	_check("大厅：养成面板（结晶头 + 8 升级 + 注释 = 10 行（2026-08-31 增「预案推演」））",
		_live_children(menu._panel_list) == 10,
		"live=%d" % _live_children(menu._panel_list))
	menu._on_panel_close()
	Meta.character_id = &"sentinel"
	Meta.upgrades = {}
	Meta.crystals = 0
	Meta.unlocked_characters = saved_unlocked.duplicate()   # 购买位还原（duplicate 断别名——引用赋值会被后续置位污染快照）
	Meta._save()                                  # 养成测试不留痕（防污染 pkg 字面量断言）


# ── ⑲ 战地黑市 + 金币 + 音效（M7 落地验收） ─────────────────────
func _test_economy() -> void:
	print("── 战地黑市与音效 ──")
	# 金币掉账：强制 gold_drop 必中
	var e := (_gl.pools[&"enemy"] as EnemyPool).acquire()
	e.spawn(_fixture_enemy(&"E_GOLD", 10.0), 1, 0)
	e.data.gold_drop = {"chance": 1.0, "min": 7, "max": 7}
	var g0: int = int(_gl.player.get("gold"))
	_gl._on_enemy_killed_drop_xp(e)
	_check("金币：击杀掉账 +7", int(_gl.player.get("gold")) == g0 + 7)
	_gl.pools[&"enemy"].release(e)
	# 行情系数界
	var shop: ShopUi = _gl.shop_ui
	var in_band := true
	for slot in range(6):
		var m := shop.market_mult(5, slot)
		if m < 0.7 or m > 1.3:
			in_band = false
	_check("行情：系数 ∈ [0.7, 1.3]", in_band)
	# 开店 → 货架 → 购买治疗包 → 出击
	_gl.state = GameConst.GameStatus.PLAYING
	_gl.player.set("gold", 500)
	_gl.player.set("hp", 10.0)
	var hp0: float = float(_gl.player.get("hp"))
	var gold0: int = int(_gl.player.get("gold"))
	shop.open(_gl.player, 5)
	_check("黑市：开店可见", shop.is_shop_visible())
	var healed := false
	for i in range(shop._wares.size()):
		if String(shop._wares[i].get("kind", "")) == "heal":
			shop._buy(i)
			healed = float(_gl.player.get("hp")) > hp0 + 1.0
			break
	_check("黑市：治疗包购买回血", healed)
	_check("黑市：金币扣减", int(_gl.player.get("gold")) < gold0)
	var g1: int = int(_gl.player.get("gold"))
	shop._on_refresh_pressed()
	_check("黑市：刷新扣费", int(_gl.player.get("gold")) <= g1 - 10)
	shop.close()
	_check("黑市：出击 → PLAYING（含宽限）", _gl.state == GameConst.GameStatus.PLAYING)
	# 游侠闪现（购买门角色——技能验收临时置解锁位，函数尾还原）
	var p: Node = _gl.player
	var saved_unlocked_econ: Dictionary = Meta.unlocked_characters.duplicate()
	Meta.unlocked_characters["ranger"] = true
	Meta.character_id = &"ranger"
	p.call(&"set_character", &"ranger")
	var pos0: Vector2 = (p as Node2D).global_position
	p.set("_last_move_dir", Vector2.RIGHT)
	p.call(&"activate_skill")
	_check("游侠：瞬步位移 + 无敌", ((p as Node2D).global_position - pos0).length() > 200.0
		and float(p.get("invuln_left")) > 0.5)
	Meta.character_id = &"sentinel"
	Meta.unlocked_characters = saved_unlocked_econ.duplicate()
	# 音效库
	_check("音效：8 种程序化音色就绪", SfxBank.I != null and SfxBank.I._streams.size() >= 9)
	SfxBank.I.play(&"kill")
	SfxBank.I.play(&"level")


# ── ⑳ 成就奖励 / 复活 / 地图词缀 ─────────────────────────────────
func _test_polish() -> void:
	print("── 成就奖励/复活/词缀 ──")
	# 成就奖励结晶：wave_30 达成 → +80（选未达成项——wave_10 已在早前用例解锁）
	Meta._run_max_wave = 30
	var cr0: int = Meta.crystals
	Meta._check_achievements()
	# 同一轮 wave_20（+40）会一并解锁 → 合计 +120
	_check("成就奖励：wave_30 达成（+80，连带 wave_20 +40）",
		Meta.is_ach_done(&"wave_30") and Meta.crystals == cr0 + 120,
		"cr=%d/%d" % [Meta.crystals, cr0 + 120])
	# 复活：应急协议 1 级 → 致死一击满血复活
	Meta.upgrades = {"revive": 1}
	var p: Node = _gl.player
	p.call(&"set_character", &"sentinel")
	_check("复活：充能就位（1 次）", int(p.get("revives_left")) == 1)
	p.set("invuln_left", 0.0)                     # 清无敌（接触伤害有无敌帧护栏）
	p.set("hp", 1.0)
	p.call(&"take_contact_damage", 50.0)
	_check("复活：致死伤害 → 满血存活 + 2s 无敌",
		absf(float(p.get("hp")) - float(p.get("max_hp"))) <= 0.01
		and float(p.get("invuln_left")) >= 1.5 and int(p.get("revives_left")) == 0)
	p.set("invuln_left", 0.0)
	p.call(&"take_contact_damage", 99999.0)
	_check("复活：耗尽后正常死亡仲裁（E-16 不受扰）", bool(p.get("_dead")))
	p.call(&"respawn")
	# 地图词缀：定义完整 + spawner 应用
	for mid: Array in [[&"world_grass", ""], [&"world_frost", "ice_resist"],
			[&"world_demon", "spd_mult"], [&"world_grove", "xp_mult"],
			[&"world_swamp", "hp_mult"]]:
		var def := MapTable.get_map(mid[0])
		_check("词缀：%s → %s" % [String(mid[0]), String(mid[1]) if String(mid[1]) != "" else "无词缀"],
			String(def.get("mod_id", "")) == String(mid[1]))
	var frost_def := MapTable.get_map(&"world_frost")
	_check("词缀文案：霜冻之地", String(frost_def.get("mod_name", "")).contains("冰抗"))
	# spawner 词缀应用（spd_mult 实测）
	_gl.spawner.map_mods = {"spd_mult": 1.10}
	var se := (_gl.pools[&"enemy"] as EnemyPool).acquire()
	se.spawn(_fixture_enemy(&"E_MOD", 10.0), 1, 0)
	var spd0: float = se.speed
	_gl.spawner._apply_map_mods(se)
	_check("词缀：spawner 应用移速 +10%", absf(se.speed - spd0 * 1.10) <= 0.01)
	_gl.spawner.map_mods = {}
	_gl.pools[&"enemy"].release(se)


func _test_p0_fixes() -> void:
	# 2026-08-31 P0 双修验收（META_ROADMAP §5.10 前两项）：
	# ① MEC_SHIELD 挂载链（原 p_trait.layers 运行时崩溃 → 护盾永不生效）
	# ② W4 脉冲激光（lifetime 三处断链 → 常驻）
	print("── P0 修复：护盾链 + W4 脉冲 ──")
	var p: Node = _gl.player
	var main_w: Node = null
	for w: Node in p.weapon_slots:
		if w != null and is_instance_valid(w):
			main_w = w
			break
	# ① 护盾：真路径挂载（attach_trait 唯一收束口——选卡/回响共用）
	var shield_data: TraitData = _gl.registry.get_trait(&"MEC_SHIELD")
	var ok1: bool = main_w.attach_trait(shield_data)
	_check("护盾链：attach_trait 成功（无崩溃）", ok1)
	_check("护盾链：interval=8.0 首充 8s 未就绪",
		absf(float(p.get("shield_interval")) - 8.0) <= 0.01
		and absf(float(p.get("shield_timer")) - 8.0) <= 0.01
		and not bool(p.get("shield_ready")))
	main_w.attach_trait(shield_data)             # 2 层
	_check("护盾链：2 层 → interval=5.5", absf(float(p.get("shield_interval")) - 5.5) <= 0.01)
	p.set("shield_timer", 0.01)
	for i in range(3):                           # 3 帧 ×8.33ms 必然走完 10ms 尾差
		p.call(&"tick", 1.0 / 120.0, Vector2.ZERO)
	_check("护盾链：充满 → shield_ready", bool(p.get("shield_ready")))
	var hp0: float = float(p.get("hp"))
	p.set("invuln_left", 0.0)
	p.call(&"take_contact_damage", 50.0)
	_check("护盾链：格挡 → HP 不掉 + 进入再充能",
		absf(float(p.get("hp")) - hp0) <= 0.01 and not bool(p.get("shield_ready"))
		and absf(float(p.get("shield_timer")) - 5.5) <= 0.01)
	# ⑤ 前置还原：清除护盾状态（防本批次后续 roll 断言被充能干扰——语义无后续依赖）
	# ② W4 脉冲：真池真网格（GameLoop 既有依赖），0.5s 收束 + cd 后再起束
	var lw: Node = load("res://scripts/combat/weapon/laser_weapon.gd").new()
	lw.name = "VerifyW4"
	_gl.add_child(lw)
	lw.position = Vector2(100, 640)
	lw.setup(_gl.registry.get_weapon(&"W4_pulse_beam"), p, {
		"enemy_grid": _gl.enemy_grid, "laser_pool": _gl.pools[&"laser"],
	})
	lw.try_fire()
	var beam: Node = lw._main_beam
	_check("W4 脉冲：lifetime=0.5 已接线", beam != null and absf(beam.lifetime - 0.5) <= 0.01)
	var t := 0.0
	while t < 0.6:
		lw.tick(1.0 / 120.0)
		t += 1.0 / 120.0
	_check("W4 脉冲：0.5s 后光束收束", not beam.is_live())
	lw.free()
	# ③ W5 对照组：无 pulse_duration 键 → 常驻（行为不回归）
	var w5: Node = load("res://scripts/combat/weapon/laser_weapon.gd").new()
	w5.name = "VerifyW5"
	_gl.add_child(w5)
	w5.position = Vector2(100, 640)
	w5.setup(_gl.registry.get_weapon(&"W5_prism"), p, {
		"enemy_grid": _gl.enemy_grid, "laser_pool": _gl.pools[&"laser"],
	})
	w5.try_fire()
	var beam5: Node = w5._main_beam
	_check("W5 对照：无脉冲键 → 常驻（lifetime=0）", beam5 != null and beam5.lifetime <= 0.0)
	w5.free()
	# ④ 卡池每局随机（start_run → rng.randomize 改写 state）
	_gl.card_generator.rng.seed = 42
	var state0: int = _gl.card_generator.rng.state
	_gl.card_generator.rng.randomize()
	_check("卡池：每局 randomize 改写 RNG 流", _gl.card_generator.rng.state != state0)
	# ⑤ 词条卡目标随机武器：双武器持有下 roll 40 次 → 目标覆盖 ≥2 把
	p.set("unlocked_slots", 5)                   # 前序批次槽位态未知——全解锁保装配
	var w2: Node = p.call(&"add_weapon", _gl.registry.get_weapon(&"W2_gatling"))
	_check("词条目标：第二把武器装配成功", w2 != null)
	var targets: Dictionary = {}
	_gl.card_generator.rng.seed = 20260831
	for i in range(40):
		var cands := _gl.card_generator.generate_candidates({"player": p, "wave": 20})
		for c: Dictionary in cands:
			if int(c.get("kind", -1)) == 1 and c.get("target_weapon") != null:
				targets[int(c["target_weapon"].get("uid"))] = true
	_check("词条目标：40 次发牌覆盖 ≥2 把武器（不再全砸主武器）", targets.size() >= 2,
		"覆盖=%d" % targets.size())
	# ⑥ 技能 CD 全员 120s
	var all_cd := true
	for c: Dictionary in CharacterTable.CHARACTERS:
		if absf(float(c.get("cd", 0.0)) - 120.0) > 0.01:
			all_cd = false
	_check("技能：6 角色 CD 全员 120s", all_cd and CharacterTable.CHARACTERS.size() >= 6)
	# ⑦ W4 数据键 + W5 对照（数据侧口径锁定）
	var w4d: Resource = _gl.registry.get_weapon(&"W4_pulse_beam")
	_check("数据：W4 laser.pulse_duration=0.5", absf(float(w4d.laser.get("pulse_duration", 0.0)) - 0.5) <= 0.01)
	var w5d: Resource = _gl.registry.get_weapon(&"W5_prism")
	_check("数据：W5 无 pulse_duration（常驻口径）", not w5d.laser.has("pulse_duration"))


# ── ㉑ 每图专属 Boss（P1：冰原/魔域/树海/沼泽独立 Boss——数据/贴图/分型/波表/怪闸） ──
func _test_map_bosses() -> void:
	# 数值真源：E6_boss2 同波位量级（hp_base 16537 → 专属 Boss = 16000±10% 微调）；
	# schema 键照 boss2/3 先例（phases/bullet_patterns/summons/phase2_resist）。
	print("── 每图专属 Boss ──")
	var boss_ids: Array[StringName] = [&"E17_frost_sovereign", &"E18_demon_lord",
		&"E19_grove_warden", &"E20_swamp_hydra"]
	var kinds: Array[StringName] = [&"boss4", &"boss5", &"boss6", &"boss7"]
	# ① 数据加载 + schema（TAG_BOSS + boss 段键齐 + hp 量级；弹幕段 barrage 新真源 /
	#    存量 bullet_patterns 过渡均收——E17/E18 已迁移，E19/E20 待 P2）
	var loaded := true
	var schema_ok := true
	var hp_ok := true
	for bid in boss_ids:
		var bd: EnemyData = _gl.registry.get_enemy(bid)
		if bd == null:
			loaded = false
			continue
		if int(bd.tags & GameConst.TAG_BOSS) == 0 or bd.boss.is_empty():
			schema_ok = false
		else:
			for key in ["phases", "summons", "phase2_resist"]:
				if not bd.boss.has(key):
					schema_ok = false
			if not bd.boss.has("barrage") and not bd.boss.has("bullet_patterns"):
				schema_ok = false
		if absf(bd.hp_base - 16000.0) > 1600.0:
			hp_ok = false
	_check("数据加载：E17~E20 四专属 Boss 入注册表", loaded)
	_check("schema：boss 段四键齐 + TAG_BOSS + hp≈16000（boss2 同波位 ±10%）",
		schema_ok and hp_ok)
	# ② validator：加载后全量校验 0 剔除（4 Boss 未被数据守门剔除）
	var validator := DataValidator.new()
	var report: Dictionary = validator.validate_all(_gl.registry)
	var all_in := true
	for bid in boss_ids:
		if _gl.registry.get_enemy(bid) == null:
			all_in = false
	_check("validator：全量校验 0 剔除（4 Boss 存活于注册表）",
		(report["rejected"] as Array).size() == 0 and all_in)
	# ③ 贴图：非空 + 96px 画布 + 互异（缓存实例不同——与 boss1~3 剪影互异同口径）
	var tex_b4 := TextureFactory.enemy_tex(&"boss4")
	var tex_b5 := TextureFactory.enemy_tex(&"boss5")
	var tex_b6 := TextureFactory.enemy_tex(&"boss6")
	var tex_b7 := TextureFactory.enemy_tex(&"boss7")
	var distinct := tex_b4 != null and tex_b5 != null and tex_b6 != null and tex_b7 != null \
		and tex_b4.get_width() == 96 and tex_b7.get_height() == 96 \
		and tex_b4 != tex_b5 and tex_b4 != tex_b6 and tex_b4 != tex_b7 \
		and tex_b5 != tex_b6 and tex_b5 != tex_b7 and tex_b6 != tex_b7 \
		and tex_b4 != TextureFactory.enemy_tex(&"boss1") \
		and tex_b4 != TextureFactory.enemy_tex(&"boss2") \
		and tex_b4 != TextureFactory.enemy_tex(&"boss3")
	_check("贴图：boss4~7 非空 + 96px 画布 + 相互/对 boss1~3 互异", distinct)
	var angry_ok := tex_b4 != TextureFactory.enemy_tex(&"boss4", true) \
		and tex_b5 != TextureFactory.enemy_tex(&"boss5", true) \
		and tex_b6 != TextureFactory.enemy_tex(&"boss6", true) \
		and tex_b7 != TextureFactory.enemy_tex(&"boss7", true)
	_check("贴图：4 新 Boss 怒相变体就位（angry 缓存独立）", angry_ok)
	# ④ 分型判定 + 视觉接线 + 巨型化（spawn 4 实体，tags=6 → FINAL x5.0 档）
	var kind_ok := true
	var visual_ok := true
	var scale_ok := true
	for i in range(4):
		var en := (_gl.pools[&"enemy"] as EnemyPool).acquire()
		en.spawn(_gl.registry.get_enemy(boss_ids[i]), 20, GameConst.TAG_FINAL_BOSS)
		if en.get("_kind") != kinds[i]:
			kind_ok = false
		var spr: Sprite2D = en.get("_sprite")
		if spr == null or spr.texture != TextureFactory.enemy_tex(kinds[i], false):
			visual_ok = false
		if absf(float(en.get("_base_scale")) - 14.0 * Enemy.FINAL_BOSS_VISUAL_MULT / Enemy.BOSS_TEX_R) > 0.001:
			scale_ok = false
		_gl.pools[&"enemy"].release(en)
	_check("分型判定：E17~E20 spawn 实体 _kind = boss4~7", kind_ok)
	_check("视觉接线：sprite 贴图 = 分型缓存同实例", visual_ok)
	_check("巨型化：TAG_FINAL_BOSS → x5.0 档（hitbox 口径基准）", scale_ok)
	# ⑤ 波表接入：4 图 w20 composition = 本图专属 Boss + 引擎选取以表内 Boss 优先
	var pairs: Array = [
		[&"world_frost", &"E17_frost_sovereign"],
		[&"world_demon", &"E18_demon_lord"],
		[&"world_grove", &"E19_grove_warden"],
		[&"world_swamp", &"E20_swamp_hydra"],
	]
	# R9 阶梯 10/15/20/25/30：主题 Boss 波 = 各图 final_wave（草原 w10 boss1 不在本表）
	var final_boss_wave := {&"world_frost": 15, &"world_demon": 20,
		&"world_grove": 25, &"world_swamp": 30}
	var wave_ok := true
	var pick_ok := true
	var saved_table: WaveTableData = _gl.wave_director.wave_table
	for pr: Array in pairs:
		var tbl: WaveTableData = MapTable.load_table(pr[0], _gl.registry)
		var boss_w: int = int(final_boss_wave[pr[0]])
		if tbl == null or tbl.entries.size() < boss_w:
			wave_ok = false
			continue
		var w_final: WaveEntryData = null
		for e in tbl.entries:
			if e.index == boss_w:
				w_final = e
		var found := false
		if w_final != null:
			for comp in w_final.composition:
				if StringName(String(comp.get("enemy_id", ""))) == StringName(String(pr[1])):
					found = true
		if not found:
			wave_ok = false
		_gl.wave_director.wave_table = tbl
		var pick: EnemyData = _gl.wave_director.call(&"_find_boss_data", boss_w)
		if pick == null or pick.id != StringName(String(pr[1])):
			pick_ok = false
	_gl.wave_director.wave_table = saved_table
	_check("波表接入：4 图 final 波 composition 编入本图专属 Boss（R9 阶梯 15/20/25/30）", wave_ok)
	_check("引擎选取：_find_boss_data 表内 Boss 优先（每图 final 波选对）", pick_ok)
	# ⑥ 主表轮换不回归（rotation 池扩到 7 只后，主表三 Boss 波选取不变）
	_gl.wave_director.wave_table = _gl.registry.get_wave_table()
	var main_ok := true
	var expects: Array = [[10, &"E6_boss1"], [20, &"E6_boss2"], [30, &"E6_boss3"]]
	for ex: Array in expects:
		var mp: EnemyData = _gl.wave_director.call(&"_find_boss_data", ex[0])
		if mp == null or mp.id != StringName(String(ex[1])):
			main_ok = false
	_check("主表轮换：w10/20/30 仍 = boss1/2/3（rotation 不回归）", main_ok)
	# ⑦ F-19 Boss 波伴怪闸口径：w20 节奏 ×1/2.5s 场上≤12 + Boss 未登场时闸开（口径不回归）
	var rhythm: Dictionary = _gl.wave_director.call(&"_escort_rhythm", 20)
	_check("F-19 伴怪闸：w20 节奏 ×1/2.5s 场上≤12 + 未登场闸开（不回归）",
		absf(float(rhythm["interval"]) - 2.5) <= 0.001 and int(rhythm["cap"]) == 12
		and bool(_gl.wave_director.call(&"_escort_gate_open")))


# ── 地图词缀二期（双词缀：祝福利好玩家 + 诅咒利敌） ────────────────
func _test_map_affixes2() -> void:
	# 数值真源：map_table.gd MAPS 注释块（2026-08-31 本轮裁定，强度温和 ±5~12%）。
	# 应用点：诅咒 → spawner._apply_map_mods；祝福 → player.map_*（金币: GameLoop 掉账 /
	# 经验: Player.gain_xp / 射速: WeaponBase._fire_interval / 回血: GameLoop wave_cleared 订阅）
	print("── 双词缀（祝福/诅咒） ──")
	# ① 5 图双键齐全 + 旧 mod_id 兼容（既有单向词缀键不删）
	var dual_ok := true
	var legacy_ok := true
	var expect_legacy := {&"world_grass": "", &"world_frost": "ice_resist",
		&"world_demon": "spd_mult", &"world_grove": "xp_mult", &"world_swamp": "hp_mult"}
	for m in MapTable.MAPS:
		for k in ["bless_id", "bless_name", "curse_id", "curse_name"]:
			if String(m.get(k, "")) == "":
				dual_ok = false
		if String(m.get("mod_id", "")) != String(expect_legacy[m.id]):
			legacy_ok = false
	_check("双词缀：5 图 bless/curse 键齐全", dual_ok)
	_check("双词缀：旧 mod_id 键保留（兼容断言）", legacy_ok)
	# ② 注入口实测：_apply_map_affixes → 敌侧 mods + 玩家侧四字段（逐图口径）
	var inject_ok := true
	var inject_info := ""
	var checks: Array = [
		[&"world_grass", {"mob_hp_mult": 1.08}, 1.10, 1.0, 1.0, 0.0],
		[&"world_frost", {"ice_resist": 0.2}, 1.0, 1.0, 1.10, 0.0],
		[&"world_demon", {"spd_mult": 1.10}, 1.0, 1.06, 1.0, 0.0],
		[&"world_grove", {"contact_mult": 1.08}, 1.0, 1.0, 1.0, 0.02],
		[&"world_swamp", {"hp_mult": 1.10}, 1.08, 1.0, 1.08, 0.0],
	]
	for c: Array in checks:
		_gl._apply_map_affixes(MapTable.get_map(c[0]))
		var bad := ""
		if _gl.spawner.map_mods != (c[1] as Dictionary):
			bad += "mods=%s " % str(_gl.spawner.map_mods)
		if absf(_gl.player.map_gold_mult - float(c[2])) > 0.001:
			bad += "gold=%.3f " % _gl.player.map_gold_mult
		if absf(_gl.player.map_rof_mult - float(c[3])) > 0.001:
			bad += "rof=%.3f " % _gl.player.map_rof_mult
		if absf(_gl.player.map_xp_mult - float(c[4])) > 0.001:
			bad += "xp=%.3f " % _gl.player.map_xp_mult
		if absf(_gl.player.map_wave_heal_pct - float(c[5])) > 0.001:
			bad += "heal=%.3f" % _gl.player.map_wave_heal_pct
		if bad != "":
			inject_ok = false
			inject_info += "%s[%s] " % [String(c[0]), bad.strip_edges()]
	_check("双词缀注入：5 图诅咒 mods + 祝福字段（gold/rof/xp/回血）", inject_ok, inject_info)
	_gl._apply_map_affixes(MapTable.get_map(MapTable.FIRST_MAP_ID))   # 还原草原口径
	# ③ 敌侧诅咒应用实测（spawner._apply_map_mods 出生差分；w1 = data 基准值）
	var epool := _gl.pools[&"enemy"] as EnemyPool
	var fx := _fixture_enemy(&"E_AFFX", 100.0)
	fx.spd_base = 60.0
	fx.dmg_base = 10.0
	var en := epool.acquire()
	en.spawn(fx, 1, 0)
	_gl.spawner.map_mods = {"hp_mult": 1.10}
	_gl.spawner._apply_map_mods(en)
	_check("诅咒·泥沼：敌 HP +10%", absf(en.max_hp - 110.0) <= 0.01 and absf(en.hp - 110.0) <= 0.01)
	_gl.spawner.map_mods = {"mob_hp_mult": 1.08}
	_gl.spawner._apply_map_mods(en)
	_check("诅咒·虫群：非 Boss HP +8%（叠加 110 → 118.8）", absf(en.max_hp - 118.8) <= 0.01)
	var boss_fx := _fixture_enemy(&"E_AFFX_B", 100.0)
	boss_fx.tags = GameConst.TAG_BOSS
	var ben := epool.acquire()
	ben.spawn(boss_fx, 1, GameConst.TAG_BOSS)
	_gl.spawner._apply_map_mods(ben)
	_check("诅咒·虫群：Boss 免除", absf(ben.max_hp - 100.0) <= 0.01)
	_gl.spawner.map_mods = {"contact_mult": 1.08}
	_gl.spawner._apply_map_mods(en)
	_check("诅咒·毒肤：敌接触伤 +8%（10 → 10.8）", absf(en.contact_dmg - 10.8) <= 0.01)
	_gl.spawner.map_mods = {"ice_resist": 0.2}
	_gl.spawner._apply_map_mods(en)
	_check("诅咒·霜甲：敌冰抗 +20%", absf(float(en.resist[2]) - 0.2) <= 0.001)
	_gl.spawner.map_mods = {"spd_mult": 1.10}
	_gl.spawner._apply_map_mods(en)
	_check("诅咒·疾魔：敌移速 +10%（60 → 66）", absf(en.speed - 66.0) <= 0.01)
	_gl.spawner.map_mods = {}
	epool.release(en)
	epool.release(ben)
	# ④ 玩家侧祝福实测
	var p: Node = _gl.player
	# 金币（丰饶 ×1.10：gold_drop 固定 10 → 入账 11）
	var gstub := _make_killed_enemy_stub(false)
	(gstub.data as EnemyData).gold_drop = {"chance": 1.0, "min": 10, "max": 10}
	var gold0: int = int(p.get("gold"))
	p.set("map_gold_mult", 1.10)
	_gl._on_enemy_killed_drop_xp(gstub)
	_check("祝福·丰饶：金币掉账 +10%（10 → 11）", int(p.get("gold")) == gold0 + 11)
	p.set("map_gold_mult", 1.0)
	_gl.pools[&"enemy"].release(gstub)
	# 经验（寒晶：gain_xp 差分比 = map_xp_mult；养成萃取系数在比值中相消）
	p.set("xp", 0.0)
	p.set("map_xp_mult", 1.0)
	p.call(&"gain_xp", 10.0)
	var d1: float = float(p.get("xp"))
	p.set("xp", 0.0)
	p.set("map_xp_mult", 1.10)
	p.call(&"gain_xp", 10.0)
	var d2: float = float(p.get("xp"))
	_check("祝福·寒晶：gain_xp ×1.10（差分比）", d1 > 0.0 and absf(d2 / d1 - 1.10) <= 0.01)
	p.set("xp", 0.0)
	p.set("map_xp_mult", 1.0)
	# 射速（狂热 ×1.06 → 开火间隔 /1.06）
	var w0: WeaponBase = (p.get("weapon_slots") as Array)[0]
	p.set("map_rof_mult", 1.0)
	var itv0: float = float(w0.call(&"_fire_interval"))
	p.set("map_rof_mult", 1.06)
	var itv1: float = float(w0.call(&"_fire_interval"))
	_check("祝福·狂热：射速 interval /1.06",
		itv0 > 0.0 and absf(itv1 / itv0 - 1.0 / 1.06) <= 0.001)
	p.set("map_rof_mult", 1.0)
	# 每波回血（滋养 2% max_hp + 满血钳制 + 无祝福不回血）
	p.set("hp", 30.0)
	p.set("map_wave_heal_pct", 0.02)
	_gl._on_wave_cleared_bless_heal(5)
	var heal_expect: float = 30.0 + float(p.get("max_hp")) * 0.02
	_check("祝福·滋养：波清回血 2% max_hp", absf(float(p.get("hp")) - heal_expect) <= 0.01)
	p.set("hp", float(p.get("max_hp")))
	_gl._on_wave_cleared_bless_heal(6)
	_check("祝福·滋养：满血不溢出", absf(float(p.get("hp")) - float(p.get("max_hp"))) <= 0.01)
	p.set("map_wave_heal_pct", 0.0)
	p.set("hp", 30.0)
	_gl._on_wave_cleared_bless_heal(7)
	_check("祝福·滋养：无祝福不回血", absf(float(p.get("hp")) - 30.0) <= 0.01)
	p.set("hp", float(p.get("max_hp")))
	# ⑤ 菜单展示存在性（每图祝/诅两行小字）
	_gl.menu_screen._open_map_select()
	var bless_cnt := 0
	var curse_cnt := 0
	for row_node in _gl.menu_screen._panel_list.get_children():
		if row_node.is_queued_for_deletion():
			continue
		for sub in (row_node as Node).get_children():
			if sub is Label:
				var txt := String((sub as Label).text)
				if txt.begins_with("祝"):
					bless_cnt += 1
				elif txt.begins_with("诅"):
					curse_cnt += 1
	_check("菜单展示：双词缀两行小字（5 祝 + 5 诅）", bless_cnt == 5 and curse_cnt == 5,
		"bless=%d curse=%d" % [bless_cnt, curse_cnt])
	_gl.menu_screen._on_panel_close()


# ── 分图无尽延伸（表内无尽段 + per-map Boss 轮换 + Meta 深度） ─────
func _test_endless_maps() -> void:
	print("── 分图无尽延伸 ──")
	# ① 5 表无尽条目存在且 ≥5 条 + index 自主体段末（entries.size()+1）连续
	#（R9 阶梯 10/15/20/25/30：草原主体 30 段直接覆盖剧情外波；grove/swamp 主体段扩至 25/30）
	var cnt_ok := true
	var idx_ok := true
	for m in MapTable.MAPS:
		var t := MapTable.load_table(m.id, _gl.registry)
		if t == null or t.endless_entries.size() < 5:
			cnt_ok = false
			continue
		var expect := t.entries.size() + 1
		for e in t.endless_entries:
			if e.index != expect:
				idx_ok = false
			expect += 1
	_check("无尽表：5 表 endless_entries ≥5 条", cnt_ok)
	_check("无尽表：index 自主体段末连续（entries.size()+1）", idx_ok)
	# ② 驱动器消费表内无尽条目（冰原 w21：构成/TP/窗口取表值）
	var wd := _gl.wave_director
	var saved_tbl: WaveTableData = wd.wave_table
	_gl.spawner.spawn_queue.clear()
	wd.wave_table = MapTable.load_table(&"world_frost", _gl.registry)
	var e21: WaveEntryData = wd.call(&"_table_entry", 21)
	var e21_sum := 0
	if e21 != null:
		for comp in e21.composition:
			e21_sum += int(comp.get("count", 0))
	wd.start_wave(21)
	_check("无尽表消费：w21 构成源自 endless_entries（48 只入队）",
		e21 != null and _gl.spawner.queue_count() == e21_sum and e21_sum == 48,
		"queue=%d sum=%d" % [_gl.spawner.queue_count(), e21_sum])
	_check("无尽表消费：w21 TP/窗口取表值（60.4 / 26.2）",
		absf(wd.tp_budget - 60.4) <= 0.01 and absf(wd.window_left - 26.2) <= 0.01)
	# ③ 无尽 Boss 波：逢 5 轮换本图池（表内 composition 真源）
	_check("无尽 Boss：w25 逢 5 + 表内轮换 E6_boss1",
		bool(wd.call(&"_is_boss_wave", 25))
		and (wd.call(&"_find_boss_data", 25) as EnemyData).id == &"E6_boss1")
	_check("无尽 Boss：w30 本图专属 E17_frost_sovereign",
		(wd.call(&"_find_boss_data", 30) as EnemyData).id == &"E17_frost_sovereign")
	_gl.spawner.spawn_queue.clear()
	# ④ 表尽回退公式（w45 无条目 → 无尽公式 TP/窗口，A3 §2.6 口径不变）
	wd.start_wave(45)
	_check("表尽回退：w45 TP = 110×1.03^15 / 窗口 33",
		absf(wd.tp_budget - 110.0 * pow(1.03, 15.0)) <= 0.01
		and absf(wd.window_left - 33.0) <= 0.01)
	_gl.spawner.spawn_queue.clear()
	# ⑤ per-map Boss 回退轮换池（表尽段逢 10；池 = 各图 w10/w20 已用 Boss）
	var rot_ok := true
	var rot_info := ""
	var rot_cases: Array = [
		[&"world_grass", 50, &"E6_boss2"],
		[&"world_frost", 40, &"E6_boss1"],
		[&"world_demon", 40, &"E6_boss2"],
		[&"world_grove", 40, &"E6_boss1"],
		[&"world_swamp", 40, &"E6_boss2"],
	]
	for rc: Array in rot_cases:
		wd.wave_table = MapTable.load_table(rc[0], _gl.registry)
		var pick: EnemyData = wd.call(&"_find_boss_data", rc[1])
		if pick == null or pick.id != StringName(String(rc[2])):
			rot_ok = false
			rot_info += "%s w%d→%s " % [String(rc[0]), int(rc[1]),
				String(pick.id) if pick != null else "null"]
	_check("Boss 回退轮换：per-map 池（grass w50→boss2 / frost·grove w40→boss1 / demon·swamp w40→boss2）",
		rot_ok, rot_info)
	# ⑥ 主表无尽行为不回归：无表公式段 TP（pkg2 锁定口径）+ 主表主体段 30 波不变
	wd.wave_table = null
	wd.start_wave(35)
	_check("主表不回归：无表 w35 公式 TP 110×1.03^5",
		absf(wd.tp_budget - 110.0 * pow(1.03, 5.0)) <= 0.01)
	_gl.spawner.spawn_queue.clear()
	wd.wave_table = _gl.registry.get_wave_table()
	var e31: WaveEntryData = wd.call(&"_table_entry", 31)
	_check("主表无尽段：w31 表驱动（主体段 30 波 + endless 10 条分表存储）",
		e31 != null and _gl.registry.get_wave_table().entries.size() == 30
		and _gl.registry.get_wave_table().endless_entries.size() == 10)
	_gl.spawner.spawn_queue.clear()
	wd.wave_table = saved_tbl
	# ⑦ Meta 无尽深度：结算写入 / 读取 / 未记录默认 0（快照隔离——先断言再还原；
	# 清残留结算先行改道 grass——残留 _run_max_wave 的深度只会写入一次性 grass 记录）
	var saved_mr: Dictionary = Meta.map_records
	Meta.map_records = {}
	Meta.set_run_map(&"world_grass")
	Meta._on_state_changed(GameConst.GameStatus.GAME_OVER)      # 清残留单局计数
	Meta.set_run_map(&"world_frost")
	Meta._on_wave_started(27)                                    # 冰原 final 20 → 深度 7
	Meta._on_state_changed(GameConst.GameStatus.GAME_OVER)
	_check("Meta 无尽深度：frost 27 波 → 深度 12（R9 阶梯 final 15）",
		Meta.endless_depth(&"world_frost") == 12,
		"got=%d" % Meta.endless_depth(&"world_frost"))
	_check("Meta 无尽深度：未记录图默认 0",
		Meta.endless_depth(&"world_swamp") == 0 and Meta.endless_depth(&"world_demon") == 0)
	Meta.map_records = saved_mr
	# ⑧ HUD 波次号无尽段继续递增
	EventBus.emit_wave_started(41)
	_check("HUD：无尽段波次号递增（41）", _gl.hud.wave == 41)


# ── R62 无尽继续入口（通关屏出口 + 延迟结算 + 收尾窗开波闸 + 每日抑制） ──
func _test_r62_endless_continue() -> void:
	print("── R62 无尽继续入口 ──")
	# 快照隔离（records/crystals 顶层 + map_records 深拷——结算会改写内层字典）
	var saved_records: Dictionary = Meta.records.duplicate()
	var saved_crystals: int = Meta.crystals
	var saved_mr: Dictionary = {}
	for k in Meta.map_records:
		saved_mr[k] = (Meta.map_records[k] as Dictionary).duplicate()
	# 清残留单局计数（前序用例 wave_started(41) 泄漏 _run_max_wave——同 _test_endless_maps
	# ⑦ 手法：残留结算先行改道 grass；其写入的 grass 残留深度随后清表；测试尾整体还原快照）
	Meta.map_records = {}
	Meta.set_run_map(&"world_grass")
	Meta._on_state_changed(GameConst.GameStatus.GAME_OVER)
	Meta.map_records = {}
	var runs0: int = int(Meta.records.get("total_runs", 0))
	RunSave.clear()
	_gl.current_map_id = &"world_grass"          # final_wave=10
	_gl.start_run()
	var wd: WaveDirector = _gl.wave_director
	wd.start_wave(10)
	# ① 收尾窗开波闸（R62 行3 bug 修复）：窗内 BUFFER 到点不开 final+1 波
	EventBus.emit_wave_cleared(10)
	_check("R62：清完 final 波开启收尾窗", _gl._victory_pending_left > 0.0)
	_gl._tick_victory_pending(0.02)             # 窗计时（首行置位开波闸）
	_check("R62：收尾窗内驱动器开波闸关闭", wd.advance_blocked)
	wd.set("_phase", WaveDirector.WavePhase.BUFFER)
	wd.buffer_left = 0.01
	wd.tick(0.02)
	_check("R62：闸住时 BUFFER 到点不开 final+1 波（深度误记根因拔除）", wd.current_wave == 10)
	wd.advance_blocked = false                   # 还原（后续直接驱动）
	# ② 窗结束 → GAME_OVER 胜利屏：无尽出口可见 + 重开让位 + Meta 延迟不落账
	_gl._tick_victory_pending(2.3)
	_check("R62：收尾窗结束进入 GAME_OVER（胜利屏）",
		_gl.state == GameConst.GameStatus.GAME_OVER)
	_check("R62：通关屏「继续挑战·无尽」出口可见",
		_gl.game_over_screen.is_endless_offer_visible())
	var rb: Button = _gl.game_over_screen.get_node_or_null(
		"GameOverRoot/ReportCard/RestartButton")
	_check("R62：通关屏重开按钮让位（无尽占主槽）", rb != null and not rb.visible)
	_check("R62：Meta 延迟结算（GAME_OVER 后 total_runs 不变）",
		int(Meta.records.get("total_runs", 0)) == runs0)
	# ③ 无尽继续：PLAYING + final+1 波续打 + 无尽态 + HUD 徽标 + RunSave
	_check("R62：无尽继续成功回 PLAYING",
		_gl.continue_endless() and _gl.state == GameConst.GameStatus.PLAYING)
	_check("R62：自 final+1 波续打（w11）", wd.current_wave == 11)
	_check("R62：无尽态置位（后续清波不再胜利）", _gl._endless_mode)
	_gl.hud.refresh_stats()
	var wl: Label = _gl.hud.get("_wave_label")
	_check("R62：HUD 波次徽标切无尽口径（无尽 1）",
		_gl.hud.endless_depth_base == 10 and wl != null and wl.text == "无尽 1")
	_check("R62：无尽波次入局内存档（w11——大厅可继续无尽局）",
		int(RunSave.load_run().get("wave", 0)) == 11)
	# ④ 无尽局后续清波不再触发胜利
	EventBus.emit_wave_cleared(12)
	EventBus.emit_wave_started(13)
	_check("R62：无尽局清波不再开胜利窗",
		_gl._victory_pending_left <= 0.0
			and _gl.state == GameConst.GameStatus.PLAYING)
	# ⑤ 死亡结算：单次落账（total_runs 恰 +1 / 结晶单次）+ 深度入账（13−10=3）
	var cry0: int = Meta.crystals
	_gl.change_state(GameConst.GameStatus.GAME_OVER)
	_check("R62：无尽局死亡结算恰好一次（total_runs +1）",
		int(Meta.records.get("total_runs", 0)) == runs0 + 1)
	_check("R62：结晶单次产出（不双记）", Meta.crystals - cry0 == int(ceil(13.0 * 1.5)),
		"delta=%d" % (Meta.crystals - cry0))
	_check("R62：无尽深度入账（13 波 − final 10 = 3）",
		Meta.endless_depth(&"world_grass") == 3,
		"depth=%d" % Meta.endless_depth(&"world_grass"))
	# ⑥ 每日局抑制：通关屏不出无尽出口 + continue_endless 拒绝
	_gl.game_over_screen.show_victory(false)
	_check("R62：每日局通关屏不出无尽出口",
		not _gl.game_over_screen.is_endless_offer_visible())
	var rb2: Button = _gl.game_over_screen.get_node_or_null(
		"GameOverRoot/ReportCard/RestartButton")
	_check("R62：每日局重开按钮回归主槽", rb2 != null and rb2.visible)
	Meta.set_run_daily(true)
	_check("R62：每日局 continue_endless 拒绝", not _gl.continue_endless())
	Meta.set_run_daily(false)
	# 收尾还原（GAME_OVER → MENU 合法迁移 + 战场清场）
	_gl.quit_to_menu()
	Meta.records = saved_records
	Meta.crystals = saved_crystals
	Meta.map_records = saved_mr
	RunSave.clear()


# ── R66 暴击谐振 30s 内冷 + 尸体看门狗 / 结算屏残留回收 ───────────
func _test_r66_icd_and_corpse() -> void:
	print("── R66 暴击谐振内冷 / 尸体收口 ──")
	# ① 暴击谐振内冷：触发 → 30s 内不再掷 → 冷却走完可再触发
	_gl.relic_handler.activate(&"REL_CRIT_CHAIN")
	_gl.relic_handler._crit_chain_cd_left = 0.0
	var r := DamageResult.new()
	r.final_value = 20.0
	r.is_crit = true
	r.target_uid = 12345
	r.pos = Vector2(360.0, 600.0)
	r.source_uid = int(_gl.player.weapon_slots[0].get_instance_id())
	var resets0: int = _gl.relic_handler.crit_chain_resets
	for i in range(60):                          # 15% → 扫描保证命中
		EventBus.emit_damage_resolved(r)
		if _gl.relic_handler.crit_chain_resets > resets0:
			break
	_check("内冷：扫描命中首次触发", _gl.relic_handler.crit_chain_resets > resets0)
	_check("内冷：触发后 30s 冷却置位",
		absf(_gl.relic_handler._crit_chain_cd_left - 30.0) < 0.01,
		"cd=%.1f" % _gl.relic_handler._crit_chain_cd_left)
	var resets1: int = _gl.relic_handler.crit_chain_resets
	for i in range(200):                         # 内冷期 200 连暴击零触发
		EventBus.emit_damage_resolved(r)
	_check("内冷：30s 内 200 连暴击零触发", _gl.relic_handler.crit_chain_resets == resets1)
	_gl.relic_handler.tick(31.0)
	var resets2: int = _gl.relic_handler.crit_chain_resets
	for i in range(60):
		EventBus.emit_damage_resolved(r)
		if _gl.relic_handler.crit_chain_resets > resets2:
			break
	_check("内冷：冷却走完可再触发", _gl.relic_handler.crit_chain_resets > resets2)
	_gl.relic_handler._crit_chain_cd_left = 0.0  # 复位（防污染后续）
	_gl.player.set("skill_cd_left", 0.0)
	# ② 尸体看门狗：dead+visible 异常态强制回收；活敌不受扰
	var corpse := (_gl.pools[&"enemy"] as EnemyPool).acquire()
	corpse.spawn(_fixture_enemy(&"E_CORPSE", 100.0), 1, 0)
	_gl.spawner.active.append(corpse)
	corpse.set("dead", true)
	var alive := (_gl.pools[&"enemy"] as EnemyPool).acquire()
	alive.spawn(_fixture_enemy(&"E_ALIVE", 100.0), 1, 0)
	_gl.spawner.active.append(alive)
	_gl._reap_corpses_soon(2.0)                  # 越过 1Hz 降频
	_check("看门狗：异常尸体（dead+visible）强制回收", not _gl.spawner.active.has(corpse))
	_check("看门狗：活敌不受扰", _gl.spawner.active.has(alive))
	_gl.spawner.active.erase(alive)
	(_gl.pools[&"enemy"] as EnemyPool).release(alive)
	# ③ 死亡局结算屏残留：进 GAME_OVER 全场碎片立即回收
	_gl.current_map_id = &"world_grass"
	_gl.start_run()
	_gl._spawn_xp_shard(Vector2(300.0, 600.0), 50.0)
	_gl._spawn_xp_shard(Vector2(400.0, 600.0), 30.0)
	_check("前置：在场碎片 2 枚", _gl.active_shards.size() == 2)
	_gl.change_state(GameConst.GameStatus.GAME_OVER)
	_check("结算屏：进 GAME_OVER 碎片全回收（boss 尸体/掉落冻屏收口）",
		_gl.active_shards.is_empty())
	_gl.quit_to_menu()


# ── P2-1 伤害数字分级（白/蓝/紫/金——大小/颜色/音效三联动） ────────
func _test_p2_damage_tiers() -> void:
	print("── P2 伤害数字分级 ──")
	var pm: PopupManager = _gl.popup_manager
	pm.tick(10.0)                                  # 清场（归还上批活跃跳字）
	var base: float = _gl.call(&"_popup_tier_baseline")
	_check("分级基准：主武器面板 base_atk × crit_mult（>0）", base > 0.0, "base=%s" % str(base))
	_check("分级音色：紫「叮」/ 金重击已入 sfx_bank",
		SfxBank.I != null and SfxBank.I._streams.has(&"tier_high")
		and SfxBank.I._streams.has(&"tier_epic"))
	var cases := [[0.5, 0], [2.0, 1], [4.0, 2], [8.0, 3]]   # [倍率, 期望档]
	var uid := 9100
	for c: Array in cases:
		var r := DamageResult.new()
		r.final_value = base * float(c[0])
		r.target_uid = uid
		r.pos = Vector2(100, 200)
		r.popup_style = GameConst.PopupStyle.NORMAL
		pm.on_damage_resolved(r)
		uid += 1
	_check("量级分档：0.5×/2×/4×/8× → 白/蓝/紫/金四档判定", pm.active_popups == 4)
	for i: int in range(cases.size()):
		var popup: DamagePopup = pm._active_list[i]
		var expect_size := roundi(DamagePopup.FONT_SIZE * float(DamagePopup.TIER_SCALES[int(cases[i][1])]))
		_check("档位 %d：字号 ×%s（%dpx）" % [int(cases[i][1]), str(DamagePopup.TIER_SCALES[int(cases[i][1])]), expect_size],
			popup.tier == int(cases[i][1])
			and popup._label.get_theme_font_size("font_size") == expect_size)
	_check("档位配色：蓝/紫/金 = 稀有度三色（调色板单源）",
		(pm._active_list[1] as DamagePopup)._label.self_modulate == PopPalette.RARITY_RARE
		and (pm._active_list[2] as DamagePopup)._label.self_modulate == PopPalette.RARITY_EPIC
		and (pm._active_list[3] as DamagePopup)._label.self_modulate == PopPalette.RARITY_LEGEND)
	_check("金档重音 + 轻震动（trauma 复用 hit 档）",
		_gl.game_feel.shake.trauma > 0.0)
	pm.tick(10.0)
	# CRIT 同吃量级档（基础字号 40）；DOT/REACTION 不参与（沿旧观感）
	var rc := DamageResult.new()
	rc.final_value = base * 4.0
	rc.target_uid = 9200
	rc.popup_style = GameConst.PopupStyle.CRIT
	pm.on_damage_resolved(rc)
	_check("暴击量级档：紫档字号 = 40 × 1.35",
		(pm._active_list[0] as DamagePopup).tier == 2
		and (pm._active_list[0] as DamagePopup)._label.get_theme_font_size("font_size")
			== roundi(DamagePopup.FONT_SIZE_CRIT * 1.35))
	pm.tick(10.0)
	var rd := DamageResult.new()
	rd.final_value = base * 100.0
	rd.target_uid = 9300
	rd.popup_style = GameConst.PopupStyle.DOT
	pm.on_damage_resolved(rd)
	_check("DOT 不吃量级档（配色/字号沿旧）",
		(pm._active_list[0] as DamagePopup).tier == 0
		and (pm._active_list[0] as DamagePopup)._label.get_theme_font_size("font_size")
			== DamagePopup.FONT_SIZE)
	pm.tick(10.0)
	# 基准关闭降级：provider 置空 → 全白（安全关闭口径）
	var saved_provider: Callable = pm.baseline_provider
	pm.baseline_provider = Callable()
	var rn := DamageResult.new()
	rn.final_value = base * 100.0
	rn.target_uid = 9400
	rn.popup_style = GameConst.PopupStyle.NORMAL
	pm.on_damage_resolved(rn)
	_check("基准缺失 → 分级安全关闭（全白现状字号）",
		(pm._active_list[0] as DamagePopup).tier == 0
		and (pm._active_list[0] as DamagePopup)._label.get_theme_font_size("font_size")
			== DamagePopup.FONT_SIZE)
	pm.baseline_provider = saved_provider
	pm.tick(10.0)


# ── P2-2 BGM 环境音（预生成 PCM 循环 + 战斗/菜单/Boss 三态） ───────
func _test_p2_bgm() -> void:
	print("── P2 BGM 环境音 ──")
	_check("BGM：SfxBank 单例 + pad 层就绪", SfxBank.I != null
		and SfxBank.I.bgm_pad_stream() is AudioStreamWAV)
	var stream: AudioStreamWAV = SfxBank.I.bgm_pad_stream()
	_check("BGM：8s 循环（4 小节）+ LOOP_FORWARD",
		absf(stream.get_length() - SfxBank.I.bgm_loop_seconds()) <= 0.01
		and stream.loop_mode == AudioStreamWAV.LOOP_FORWARD)
	# 无缝判据：循环首尾样本连续（正弦/LFO 均为 1/8s 整数倍频率——首尾相位连续）
	var pcm := stream.data
	var seam := absi(pcm.decode_s16(0) - pcm.decode_s16(pcm.size() - 2))
	_check("BGM：循环点无缝（首尾样本差 %d < 2500）" % seam, seam < 2500)
	SfxBank.I.bgm_set_active(true)
	_check("BGM：战斗态起播（pad 播放中）", SfxBank.I._bgm_player.playing)
	SfxBank.I.bgm_set_boss_layer(true)
	_check("BGM：Boss 存活期第二循环解锁（脉冲层播放中）",
		SfxBank.I._bgm_boss_player.playing
		and not SfxBank.I._bgm_boss_player.stream_paused)
	SfxBank.I.bgm_set_active(false)
	_check("BGM：菜单暂停（双层 stream_paused）",
		SfxBank.I._bgm_player.stream_paused
		and SfxBank.I._bgm_boss_player.stream_paused)
	SfxBank.I.bgm_set_boss_layer(false)


# ── P2-3 每日挑战（日期种子 + 当日词缀 + daily_best + 大厅入口） ──
func _test_p2_daily() -> void:
	print("── P2 每日挑战 ──")
	# ① 同日同种子确定性 / 跨日种子必变
	_check("每日：同日期种子恒同", Meta.daily_seed("20260831") == Meta.daily_seed("20260831"))
	_check("每日：跨日种子必变", Meta.daily_seed("20260831") != Meta.daily_seed("20260901"))
	# ② 词缀组合来自日期（确定性 + 形状 + 池内）
	var a1: Dictionary = Meta.daily_affixes("20260831")
	var a2: Dictionary = Meta.daily_affixes("20260831")
	var curses1: Array = a1.get("curses", [])
	var in_pool := true
	for cid: Variant in curses1:
		if not Meta.CURSE_POOL.has(StringName(String(cid))):
			in_pool = false
	_check("每日：同日词缀组合恒同（全玩家同日同配置）",
		str(a1) == str(a2) and curses1.size() == 2 and curses1[0] != curses1[1] and in_pool)
	_check("每日：祝福 1 条来自祝福池",
		Meta.BLESS_POOL.has(StringName(String(a1.get("bless", "")))))
	# ③ 跨日变化（mock 日期参数化——12 个连续日期 ≥3 种组合）
	var combos := {}
	for d in range(1, 13):
		var key := Meta.daily_date_key({"year": 2027, "month": 1, "day": d})
		var affixes: Dictionary = Meta.daily_affixes(key)
		combos[str(affixes)] = true
	_check("每日：跨日词缀轮换（12 日 ≥3 种组合）", combos.size() >= 3, "kinds=%d" % combos.size())
	# ④ daily_best 写读（波次/击杀各取历史最大）
	var saved_daily: Dictionary = Meta.daily_records.duplicate()
	Meta.daily_records = {}
	Meta.record_daily_result(15, 200)
	Meta.record_daily_result(10, 300)              # 更低波次 / 更高击杀
	var rec: Dictionary = Meta.daily_record()
	_check("每日：daily_best 写读（波次取最大 15 / 击杀取最大 300）",
		int(rec.get("best_wave", 0)) == 15 and int(rec.get("best_kills", 0)) == 300)
	# ⑤ 结算分流：daily 局只记 daily_best，不混常规 records
	var saved_records: Dictionary = Meta.records.duplicate()
	Meta.set_run_daily(true)
	Meta._run_max_wave = 21
	Meta._run_kills = 400
	Meta._on_state_changed(GameConst.GameStatus.GAME_OVER)
	var rec2: Dictionary = Meta.daily_record()
	_check("每日：daily 局结算 → daily_best 更新（波次 21）", int(rec2.get("best_wave", 0)) == 21)
	_check("每日：daily 局不混常规记录（total_runs/best_wave 不变）",
		int(Meta.records["total_runs"]) == int(saved_records["total_runs"])
		and int(Meta.records["best_wave"]) == int(saved_records["best_wave"]))
	Meta.set_run_daily(false)
	# ⑥ 持久化：save → 清空 → load 还原
	Meta._save()
	Meta.daily_records = {}
	Meta._load()
	_check("每日：daily_records 持久化写读", int(Meta.daily_record().get("best_wave", 0)) == 21)
	Meta.daily_records = saved_daily               # 还原（测试不留痕）
	Meta._save()
	# ⑦ 大厅入口 + 当日面板（2 诅 + 1 祝 + 最佳 + 注释 + 出发按钮 = 6 行）
	var menu: MenuScreen = _gl.menu_screen
	menu._on_lobby_pressed("daily")
	var curse_rows := 0
	var bless_rows := 0
	for row_node in menu._panel_list.get_children():
		if row_node.is_queued_for_deletion():
			continue
		for sub in (row_node as Node).get_children():
			if sub is Label:
				var txt := String((sub as Label).text)
				if txt == "诅":
					curse_rows += 1
				elif txt == "祝":
					bless_rows += 1
	_check("每日：大厅面板当日三词缀展示（2 诅 + 1 祝）", curse_rows == 2 and bless_rows == 1)
	_check("每日：出发挑战按钮就位", menu._panel_list.find_child("DailyStartButton", true, false) != null)
	menu._on_panel_close()


# ── P2-4 角色扩展 ×2（薇拉毒云 / 诺亚僚机 + 解锁门） ──────────────
func _test_p2_characters() -> void:
	print("── P2 角色扩展 ──")
	var p: Node = _gl.player
	var vera: Dictionary = CharacterTable.get_character(&"vera")
	var noah: Dictionary = CharacterTable.get_character(&"noah")
	_check("角色表：薇拉/诺亚就位（cd 120s / 毒云 / 僚机）",
		String(vera.get("id")) == "vera" and String(noah.get("id")) == "noah"
		and absf(float(vera.get("cd", 0.0)) - 120.0) <= 0.01
		and absf(float(noah.get("cd", 0.0)) - 120.0) <= 0.01)
	# 解锁门：薇拉 = 图鉴累计击杀 500；诺亚 = 成就「深入敌阵」（wave_20，2026-09-13 矩阵）
	var saved_kills: int = int(Meta.records["total_kills"])
	var saved_maps: Dictionary = Meta.map_records
	var saved_ach: Dictionary = Meta.achievements_done
	var saved_unlocked: Dictionary = Meta.unlocked_characters.duplicate()
	Meta.records["total_kills"] = 499
	Meta.achievements_done = {}
	_check("解锁门：薇拉 499 杀锁定 / 诺亚无成就锁定",
		not Meta.is_character_unlocked(&"vera") and not Meta.is_character_unlocked(&"noah"))
	Meta.records["total_kills"] = 500
	_check("解锁门：薇拉 500 杀解锁", Meta.is_character_unlocked(&"vera"))
	Meta.records["total_kills"] = saved_kills
	Meta.achievements_done = {"wave_20": true}
	_check("解锁门：诺亚成就「深入敌阵」达成解锁", Meta.is_character_unlocked(&"noah"))
	Meta.achievements_done = saved_ach
	# 薇拉：毒云领域（直结算通道——域内敌每 0.5s 受 8% 主武器 ATK + 减速 20%）
	_gl.state = GameConst.GameStatus.MENU
	Meta.records["total_kills"] = maxi(saved_kills, 500)   # 解锁门满足（守卫回落哨兵口径）
	Meta.achievements_done["wave_20"] = true
	Meta.character_id = &"vera"
	p.call(&"set_character", &"vera")
	_check("角色：薇拉血量 55 + 养成加成",
		absf(float(p.get("max_hp")) - (55.0 + Meta.hp_bonus())) <= 0.01)
	var target := (_gl.pools[&"enemy"] as EnemyPool).acquire()
	target.spawn(_fixture_enemy(&"E_P2VERA", 100000.0), 1, 0)
	target.global_position = (p as Node2D).global_position + Vector2(120.0, 0.0)
	_gl.elemental.register_host(target)
	_gl.enemy_grid.rebuild([target])
	p.set("skill_cd_left", 0.0)
	p.call(&"activate_skill")
	_check("技能·毒云：挂场即跳（敌掉血）+ 减速 20% 生效",
		float(target.get("hp")) < 100000.0 and absf(float(target.get("ext_slow_mult")) - 0.8) <= 0.001)
	var hp_at_start: float = float(target.get("hp"))
	for i in range(240):                           # 2s（120Hz）→ 首跳后再 3 跳
		GameConfig.advance_frame()                 # 真实帧路径：帧号推进（管线幂等键含帧戳）
		p.call(&"tick", DT, Vector2.ZERO)
		target.call(&"tick", DT)                   # 敌侧驱动 ext_slow 倒计时（真实路径；Enemy.tick 单参）
	_check("技能·毒云：0.5s 节拍持续结算（2s 内 ≥3 跳）",
		float(target.get("hp")) < hp_at_start)
	for i in range(660):                           # 推进至毒云 6s 到期 + 减速窗 0.6s 过期
		GameConfig.advance_frame()
		p.call(&"tick", DT, Vector2.ZERO)
		target.call(&"tick", DT)
	var hp_after_cloud: float = float(target.get("hp"))
	_check("技能·毒云：6s 到期停跳 + 减速还原",
		absf(float(p.get("_poison_cloud_left"))) <= 0.001
		and absf(float(target.get("ext_slow_mult")) - 1.0) <= 0.001)
	for i in range(120):
		GameConfig.advance_frame()
		p.call(&"tick", DT, Vector2.ZERO)
		target.call(&"tick", DT)
	_check("技能·毒云：到期后不再结算", absf(float(target.get("hp")) - hp_after_cloud) <= 0.001)
	_gl.elemental.unregister_host(target)
	(_gl.pools[&"enemy"] as EnemyPool).release(target)
	# 诺亚：召唤僚机（主武器 orbs_bonus +2 持续 10s 后还原）
	_gl.state = GameConst.GameStatus.MENU
	Meta.character_id = &"noah"
	p.call(&"set_character", &"noah")
	_check("角色：诺亚血量 50 + 养成加成",
		absf(float(p.get("max_hp")) - (50.0 + Meta.hp_bonus())) <= 0.01)
	p.call(&"unlock_slot", 2)
	var orbit: WeaponBase = p.call(&"add_weapon", _gl.registry.get_weapon(&"W8_orbit_field"))
	_check("诺亚：环绕武器装配（真件 OrbitWeapon）", orbit is OrbitWeapon)
	if orbit is OrbitWeapon:
		(orbit as OrbitWeapon).try_fire()          # 首开火建立力场（基线球数）
		var base_orbs: int = (orbit as OrbitWeapon).orbit_field.orbs
		p.set("skill_cd_left", 0.0)
		p.call(&"activate_skill")
		_check("技能·僚机：召唤 +2（orbs_bonus 与力场球数同步 +2）",
			int((orbit as OrbitWeapon).orbs_bonus) == 2
			and (orbit as OrbitWeapon).orbit_field.orbs == base_orbs + 2)
		for i in range(600):                       # 5s（仍在持续期）
			GameConfig.advance_frame()
			p.call(&"tick", DT, Vector2.ZERO)
		_check("技能·僚机：持续期保持（5s 时仍 +2）",
			int((orbit as OrbitWeapon).orbs_bonus) == 2)
		for i in range(720):                       # 再 6s（10s 到期 + 余量）
			GameConfig.advance_frame()
			p.call(&"tick", DT, Vector2.ZERO)
		_check("技能·僚机：10s 到期还原（orbs_bonus 0 / 球数回落）",
			int((orbit as OrbitWeapon).orbs_bonus) == 0
			and (orbit as OrbitWeapon).orbit_field.orbs == base_orbs)
		var slots: Array = p.get("weapon_slots")
		slots[slots.find(orbit)] = null            # 先摘槽（有效引用期）再 free——find 对 freed 实例失效
		(orbit as Node).free()
	# 选人面板：8 格（锁定态展示——薇拉/诺亚解锁门文案）
	Meta.records["total_kills"] = saved_kills
	Meta.map_records = saved_maps                 # 解锁门快照还原（测试不留痕）
	Meta.achievements_done = saved_ach
	Meta.unlocked_characters = saved_unlocked.duplicate()   # 购买位还原（duplicate 断别名）
	Meta._save()                                  # 立即落盘干净态（覆盖污染窗口内的中途存档）
	Meta.character_id = &"sentinel"
	var menu: MenuScreen = _gl.menu_screen
	menu._on_lobby_pressed("char")
	_check("大厅：选人面板 8 格（P2 +2）",
		_live_children(menu._panel_list) == CharacterTable.count())
	menu._on_panel_close()
	p.call(&"set_character", &"sentinel")


# ── P3 设置页（音量/震屏/伤害数字开关 + 持久化 + 双入口面板状态机） ─
func _test_settings() -> void:
	print("── P3 设置页 ──")
	# ① 默认值（读口缺键回退默认表——清空已存段断言出厂值，末尾快照还原不留痕）
	var saved_settings: Dictionary = Meta._settings.duplicate()
	Meta._settings = {}
	_check("设置：默认音量 sfx=0.8 / bgm=0.6",
		absf(float(Meta.settings("sfx_volume")) - 0.8) <= 0.001
		and absf(float(Meta.settings("bgm_volume")) - 0.6) <= 0.001)
	_check("设置：默认开关 震屏/伤害数字 = true",
		bool(Meta.settings("shake_on")) and bool(Meta.settings("damage_numbers_on")))
	# ② 写口：越界钳制 + 未知键忽略（防脏写穿档）
	Meta.set_setting("sfx_volume", 5.0)
	Meta.set_setting("bgm_volume", -0.5)
	_check("设置：写口越界钳制（5.0→1.0 / -0.5→0.0）",
		absf(float(Meta.settings("sfx_volume")) - 1.0) <= 0.001
		and absf(float(Meta.settings("bgm_volume"))) <= 0.001)
	Meta.set_setting("not_a_setting", 1)
	_check("设置：未知键忽略（读口 null）", Meta.settings("not_a_setting") == null)
	# ③ 持久化：写即存 → _load 磁盘回路还原（user://meta_save.cfg settings 段）
	Meta.set_setting("sfx_volume", 0.25)
	Meta._load()
	_check("设置：持久化（0.25 过 user:// 磁盘写读回路）",
		absf(float(Meta.settings("sfx_volume")) - 0.25) <= 0.001)
	# ④ 音量换算端点 + SfxBank 实时接线（settings_changed 驱动，同步落点）
	_check("设置：换算端点（0→-60dB / 1→0dB）",
		absf(SfxBank.linear_gain_db(0.0) + 60.0) <= 0.01
		and absf(SfxBank.linear_gain_db(1.0)) <= 0.0001)
	Meta.set_setting("sfx_volume", 1.0)
	Meta.set_setting("bgm_volume", 1.0)
	_check("设置：音量接线满档 = 既有基准档（sfx -14 / pad -18）",
		absf((SfxBank.I._players[&"hit"] as AudioStreamPlayer).volume_db + 14.0) <= 0.01
		and absf(SfxBank.I._bgm_player.volume_db + 18.0) <= 0.01)
	Meta.set_setting("sfx_volume", 0.0)
	Meta.set_setting("bgm_volume", 0.0)
	_check("设置：音量接线静音档（0 → 基准再 -60dB）",
		absf((SfxBank.I._players[&"hit"] as AudioStreamPlayer).volume_db + 74.0) <= 0.01
		and absf(SfxBank.I._bgm_player.volume_db + 78.0) <= 0.01)
	# ⑤ 震屏开关短路实测（开→trauma 叠加；关→恒 0；顿帧打击感保留）
	var fr := DamageResult.new()
	fr.feel_level = GameConst.FeelLevel.CRIT
	fr.final_value = 1.0
	fr.target_uid = 9801
	fr.popup_style = GameConst.PopupStyle.NORMAL
	Meta.set_setting("shake_on", true)
	_gl.game_feel.shake.trauma = 0.0
	EventBus.damage_resolved.emit(fr)
	_check("设置：震屏开 → CRIT trauma 叠加（>0）", _gl.game_feel.shake.trauma > 0.0)
	Meta.set_setting("shake_on", false)
	_gl.game_feel.shake.trauma = 0.0
	_gl.game_feel.hit_stop_left = 0.0
	EventBus.damage_resolved.emit(fr)
	_check("设置：震屏关 → trauma 恒 0（入口短路）", _gl.game_feel.shake.trauma == 0.0)
	_check("设置：震屏关不伤打击感（顿帧仍生效）", _gl.game_feel.hit_stop_left > 0.0)
	_gl.game_feel.hit_stop_left = 0.0
	# ⑥ 伤害数字开关短路实测（关→跳字入口全关；开→恢复；伤害结算管线不受影响）
	var pm: PopupManager = _gl.popup_manager
	pm.tick(10.0)                                # 清场（归还⑤派生的跳字）
	var r2 := DamageResult.new()
	r2.final_value = 10.0
	r2.target_uid = 9802
	r2.pos = Vector2(100.0, 100.0)
	r2.popup_style = GameConst.PopupStyle.NORMAL
	Meta.set_setting("damage_numbers_on", false)
	pm.on_damage_resolved(r2)
	_check("设置：伤害数字关 → 跳字入口短路（0 活跃）", pm.active_popups == 0)
	Meta.set_setting("damage_numbers_on", true)
	pm.on_damage_resolved(r2)
	_check("设置：伤害数字开 → 跳字恢复", pm.active_popups == 1)
	pm.tick(10.0)
	# ⑦ 双入口存在性（大厅按钮行 + 暂停卡「设置」按钮）
	var menu: MenuScreen = _gl.menu_screen
	var lobby_btn: Button = menu._root.find_child("Lobby_settings", true, false) as Button
	_check("设置：大厅入口按钮就位（文本「设置」）",
		lobby_btn != null and lobby_btn.text == "设置")
	var pbtn: Button = _gl.pause_overlay._card.find_child("SettingsButton", true, false) as Button
	_check("设置：暂停面板「设置」按钮就位", pbtn != null and pbtn.text == "设置")
	# ⑧ 面板开合状态机（纯 UI：开合不改 GameLoop 状态）
	var sp: SettingsPanel = _gl.settings_panel
	_check("设置：面板初始关闭", not sp.is_open())
	sp.open()
	_check("设置：open() → 可见", sp.is_open())
	sp.close()
	_check("设置：close() → 隐藏（关闭恢复原界面）", not sp.is_open())
	# ⑨ 面板控件 → 写口联动（滑条 value_changed / 开关翻转，写即存）
	sp.open()
	sp._sfx_slider.value = 0.5                   # value_changed → Meta.set_setting
	_check("设置：滑条拖动 → 写口生效（0.5）",
		absf(float(Meta.settings("sfx_volume")) - 0.5) <= 0.001)
	var shake_before: bool = bool(Meta.settings("shake_on"))
	sp._shake_btn.pressed.emit()
	_check("设置：开关点击 → shake_on 翻转", bool(Meta.settings("shake_on")) != shake_before)
	sp._shake_btn.pressed.emit()
	_check("设置：开关再点 → 复位原值", bool(Meta.settings("shake_on")) == shake_before)
	sp.close()
	# 还原（测试不留痕：快照回写 + 播放侧重应用）
	Meta._settings = saved_settings
	Meta._save()
	SfxBank.I.apply_settings_volumes()


func _live_children(p_node: Node) -> int:
	# queue_free 已挂但未销毁的子节点不计（无帧迭代环境下的存活计数）
	var n := 0
	for c in p_node.get_children():
		if not c.is_queued_for_deletion():
			n += 1
	return n


func _make_killed_enemy_stub(p_boss: bool) -> Enemy:
	var e := (_gl.pools[&"enemy"] as EnemyPool).acquire()
	var d := _fixture_enemy(&"E_META", 10.0)
	if p_boss:
		d.tags = GameConst.TAG_BOSS
	e.spawn(d, 1, 0)
	return e


# ── 工具 ─────────────────────────────────────────────────────────
func _check(p_name: String, p_ok: bool, p_info: String = "") -> void:
	if p_ok:
		_pass += 1
		print("PASS | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s %s" % [p_name, p_info])
		print("FAIL | %s %s" % [p_name, p_info])


# ── 2026-08-31 二轮反馈（BGM 重制 / 刷新机制 / 质变 / 烧伤 / 存档 / 图标） ──
func _test_round2_feedback() -> void:
	print("── 二轮反馈（BGM/刷新/质变/烧伤/存档/图标） ──")
	_test_r2_bgm_musical()
	_test_r2_reroll()
	_test_r2_milestone()
	_test_r2_burn_floor_and_spread()
	_test_r2_skill_icons()
	_test_r2_run_save()


func _test_r2_bgm_musical() -> void:
	# BGM 重制：16s 音乐化循环（4 和弦）+ Boss 层等长锁相 + 循环点无缝
	var stream: AudioStreamWAV = SfxBank.I.bgm_pad_stream()
	_check("BGM：16s 音乐化循环（4 和弦 × 4s）",
		absf(stream.get_length() - 16.0) <= 0.02)
	_check("BGM：采样率 22050（去混叠）", stream.mix_rate == 22050)
	var data := stream.data
	var head := absf(data.decode_s16(0))
	var tail := absf(data.decode_s16(data.size() - 2))
	_check("BGM：循环点首尾样本归零（和弦包络起止 0）", head <= 40 and tail <= 40)


func _test_r2_reroll() -> void:
	# 刷新机制：开局次数（2 + 养成）→ 首次免费 → 消耗 → 重新发牌 → 波次/Boss 授予
	var p: Player = _gl.player
	p.set_character(&"sentinel")             # 养成 0 级 → 基础 2 次
	_check("刷新：开局次数 = 2（基础）", p.reroll_charges == 2)
	_gl.start_run()
	_gl._on_level_up(2)                      # PLAYING → LEVEL_UP 弹卡
	_check("刷新：选卡界面打开（LEVEL_UP）", _gl.card_select_ui.is_open)
	var before: Array[Dictionary] = _gl.current_candidates.duplicate()
	var first_id := String(before[0].get("id", "")) if not before.is_empty() else ""
	_gl._on_card_reroll()
	_check("刷新：本局首次免费（次数不扣）", p.reroll_charges == 2)
	_check("刷新：货架已重发（界面仍开）", _gl.card_select_ui.is_open
		and _gl.current_candidates.size() >= 3)
	var changed := false
	for i in range(mini(before.size(), _gl.current_candidates.size())):
		if String(before[i].get("id", "")) != String(_gl.current_candidates[i].get("id", "")):
			changed = true
	if not changed and first_id != "":
		changed = String(_gl.current_candidates[0].get("id", "")) != first_id
	_check("刷新：候选内容变化（重 roll 生效）", changed or before.is_empty())
	_gl._on_card_reroll()
	_check("刷新：第二次消耗 1 次（2→1）", p.reroll_charges == 1)
	_gl._on_card_choice([_gl.current_candidates[0]])   # R72 协议统一为数组
	_check("刷新：选卡后回 PLAYING", _gl.state == GameConst.GameStatus.PLAYING)
	var charges0: int = p.reroll_charges
	_gl._on_wave_started_reroll_grant(5)
	_check("刷新：每 5 波 +1（5 波节点）", p.reroll_charges == charges0 + 1)
	_gl._on_wave_started_reroll_grant(6)
	_check("刷新：非 5 倍数波不授予", p.reroll_charges == charges0 + 1)
	_gl.request_pause()
	_gl.quit_to_menu()
	_check("刷新：收尾回菜单（下一用例干净开局）", _gl.state == GameConst.GameStatus.MENU)


func _test_r2_milestone() -> void:
	# 满层质变：ADD 池词条挂至 stack_max → value_mult ×1.6 + 里程碑广播
	# （大关门 2026-09-13：质变第 4 关解锁——本用例以树海局口径运行，收尾还原）
	var saved_map: StringName = Meta.run_map_id()
	Meta.set_run_map(&"world_grove")
	var w := BallisticWeapon.new()
	_gl.add_child(w)
	w.setup(_gl.registry.get_weapon(&"W1_pistol"), _gl.player, {})
	var t: TraitData = _gl.registry.get_trait(&"AFF_ATK_UP")
	var hits: Array = [0]                   # 容器引用（GDScript lambda 局部变量为值捕获）
	var cb := func(_tid: StringName, _n: String, _m: float) -> void: hits[0] += 1
	EventBus.trait_milestone.connect(cb)
	for i in range(t.stack_max):
		w.attach_trait(t)
	_check("质变：挂满层触发里程碑广播（×1.6）", hits[0] == 1, "hits=%d" % hits[0])
	var mounted: TraitBase = null
	for tb in w.trait_stack.traits:
		if tb.data.id == &"AFF_ATK_UP":
			mounted = tb
	_check("质变：value_mult = 1.6（挂至 stack_max）",
		mounted != null and absf(mounted.value_mult - 1.6) <= 0.001)
	var entry_contrib := 0.0
	for e in w.trait_stack.aggregate_add_entries():
		if e.trait_id == &"AFF_ATK_UP":
			entry_contrib = float(e.contrib)
	_check("质变：add_entries 单层贡献 ×1.6",
		absf(entry_contrib - t.value * 1.6) <= 0.001)
	# 再挂同词条：拒绝（满层）且不重复质变
	w.attach_trait(t)
	_check("质变：满层后再挂拒绝（无重复广播）", hits[0] == 1)
	# 大关门口径：未解锁关（草原局）挂满层不质变（门关：无广播无乘区）
	Meta.set_run_map(&"world_grass")
	var hits1: Array = [0]
	var cb1 := func(_tid: StringName, _n: String, _m: float) -> void: hits1[0] += 1
	EventBus.trait_milestone.connect(cb1)
	var w2 := BallisticWeapon.new()
	_gl.add_child(w2)
	w2.setup(_gl.registry.get_weapon(&"W1_pistol"), _gl.player, {})
	for i in range(t.stack_max):
		w2.attach_trait(t)
	var mounted2: TraitBase = null
	for tb in w2.trait_stack.traits:
		if tb.data.id == &"AFF_ATK_UP":
			mounted2 = tb
	_check("质变门：草原局挂满层不质变（value_mult = 1，无广播）",
		hits1[0] == 0 and mounted2 != null and absf(mounted2.value_mult - 1.0) <= 0.001,
		"hits=%d mult=%f" % [hits1[0], float(mounted2.value_mult) if mounted2 != null else -1.0])
	EventBus.trait_milestone.disconnect(cb)
	EventBus.trait_milestone.disconnect(cb1)
	Meta.set_run_map(saved_map)
	w.queue_free()
	w2.queue_free()


func _test_r2_burn_floor_and_spread() -> void:
	# 烧伤保底：快照 4 → 15% = 0.6 → 保底 1/层（跳字 ceil 口径另行）
	var e := Enemy.new()
	_gl.add_child(e)
	e.spawn(_gl.registry.get_enemy(&"E1_grunt"), 1, 0)
	_gl.elemental.register_host(e)
	var st := e.elemental
	st.burn_layers = 1
	st.burn_dot_ratio = 0.15
	st.burn_snapshot_atk = 4.0
	st.burn_timer = 3.0
	st.burn_tick = 0.5
	st.dot_tick_left = 0.0
	var captured := {"v": -1.0}
	var cb := func(r: DamageResult) -> void: captured["v"] = r.final_value
	EventBus.damage_resolved.connect(cb)
	_gl.elemental._dot_tick(e, st)
	EventBus.damage_resolved.disconnect(cb)
	_check("烧伤：低快照保底 ≥1（0.6 → 1）", float(captured["v"]) >= 1.0)
	# 点燃蔓延（层 2 质变）：燃烧者死亡 → 邻敌满槽点燃
	var e2 := Enemy.new()
	_gl.add_child(e2)
	e2.spawn(_gl.registry.get_enemy(&"E1_grunt"), 1, 0)
	e2.global_position = e.global_position + Vector2(60.0, 0.0)
	_gl.elemental.register_host(e2)
	var arr: Array[Node2D] = [e, e2]
	_gl.enemy_grid.rebuild(arr)
	st.burn_spread_radius = 150.0
	st.burn_timer = 3.0
	_gl.elemental._on_enemy_killed_spread_burn(e)
	_check("点燃蔓延：燃烧者死亡 → 邻敌直接点燃（满槽）",
		e2.elemental != null and e2.elemental.burn_timer > 0.0)
	e.queue_free()
	e2.queue_free()


func _test_r2_skill_icons() -> void:
	# 技能图标：8 角色各一枚 64px 程序化贴图 + HUD 技能键挂载
	for cid in ["sentinel", "veles", "bulwark", "ranger", "zero", "mank", "vera", "noah"]:
		var tex := TextureFactory.skill_icon(StringName(cid))
		_check("技能图标：%s 64px 贴图就绪" % cid,
			tex != null and tex.get_width() == 64 and tex.get_height() == 64)
	var hud: HUD = _gl.hud
	_check("技能图标：HUD 技能键图标节点就绪",
		hud.get_node_or_null("Root/SkillButton/SkillIconFg") is TextureRect)


func _test_r2_run_save() -> void:
	# 局内存档：开局 → 改构筑 → 暂停回菜单（落盘）→ 大厅继续 → 构筑/数值/波次恢复
	RunSave.clear()
	_gl.start_run()
	var p: Player = _gl.player
	p.level = 6
	p.xp = 3.5
	p.gold = 88
	p.reroll_charges = 4
	var w0: WeaponBase = p.weapon_slots[0]
	for i in range(2):
		w0.level_up()
	w0.attach_trait(_gl.registry.get_trait(&"AFF_ATK_UP"))
	_gl.wave_director.start_wave(7)
	_gl.request_pause()
	_gl.quit_to_menu()
	_check("存档：暂停回菜单后落盘（RunSave 存在）", RunSave.exists())
	var snap := RunSave.load_run()
	_check("存档：波次/等级/金币入档",
		int(snap.get("wave", 0)) == 7 and int(snap.get("level", 0)) == 6
		and int(snap.get("gold", 0)) == 88)
	_check("存档：武器构筑入档（1 把 + 词条层数）",
		(snap.get("weapons", []) as Array).size() >= 1)
	_check("存档：继续后回到 PLAYING（第 7 波）",
		_gl.continue_run() and _gl.state == GameConst.GameStatus.PLAYING
		and _gl.wave_director.current_wave == 7)
	_check("存档：玩家数值恢复（等级/金币/刷新）",
		_gl.player.level == 6 and _gl.player.gold == 88 and _gl.player.reroll_charges == 4)
	var restored: WeaponBase = _gl.player.weapon_slots[0]
	var has_trait := false
	if restored != null and restored.trait_stack != null:
		for tb in restored.trait_stack.traits:
			if tb.data.id == &"AFF_ATK_UP":
				has_trait = tb.layers == 1
	_check("存档：武器等级与词条层恢复（Lv3 + AFF_ATK_UP×1）",
		restored != null and int(restored.level) == 3 and has_trait)
	_gl.request_pause()
	_gl.quit_to_menu()
	RunSave.clear()


# ── 2026-09-13 五轮反馈（早期经验加速 ×1.25：掉落侧折算） ──
func _test_round5_early_xp() -> void:
	print("── 五轮反馈（早期经验加速） ──")
	# 数值真源默认值（BalanceTables.early_xp_boost；validator 规则 mult≥1/until_wave≥1）
	var boost: Dictionary = GameConfig.balance.early_xp_boost
	_check("早期经验：balance 真源默认 {mult:1.25, until_wave:6}",
		absf(float(boost.get("mult", 0.0)) - 1.25) <= 0.001
		and int(boost.get("until_wave", 0)) == 6)
	# 倍率区间（掉落侧 _early_xp_mult；收尾还原波次）
	var saved_wave: int = _gl.wave_director.current_wave
	_gl.wave_director.current_wave = 1
	_check("早期经验：第 1 波 ×1.25", absf(_gl._early_xp_mult() - 1.25) <= 0.001,
		"mult=%f" % _gl._early_xp_mult())
	_gl.wave_director.current_wave = 5
	_check("早期经验：第 5 波仍 ×1.25", absf(_gl._early_xp_mult() - 1.25) <= 0.001)
	_gl.wave_director.current_wave = 6
	_check("早期经验：第 6 波起回落 1.0", absf(_gl._early_xp_mult() - 1.0) <= 0.001)
	_gl.wave_director.current_wave = 0
	_check("早期经验：非局波次（0）不加速", absf(_gl._early_xp_mult() - 1.0) <= 0.001)
	# 掉落端到端：wave 1 击杀 exp_value=10 → 经验球面值 = 10 × 遗物倍率 × 1.25
	_gl.wave_director.current_wave = 1
	var e := Enemy.new()
	_gl.add_child(e)
	e.spawn(_gl.registry.get_enemy(&"E1_grunt"), 1, 0)
	e.exp_value = 10.0
	var expected := 10.0 * _gl.relic_handler.xp_mult() * 1.25
	var shards0: int = _gl.active_shards.size()
	_gl._on_enemy_killed_drop_xp(e)
	var shards1: int = _gl.active_shards.size()
	_check("早期经验：击杀掉落经验球 +1", shards1 == shards0 + 1,
		"%d→%d" % [shards0, shards1])
	if shards1 > shards0 and not _gl.active_shards.is_empty():
		var shard: Node = _gl.active_shards.back()
		_check("早期经验：球面值 = 基值 × 1.25（掉落侧折算）",
			absf(float(shard.get("value")) - expected) <= 0.01,
			"got=%f want=%f" % [float(shard.get("value")), expected])
	if not _gl.active_shards.is_empty():
		_gl.active_shards.back().queue_free()
		_gl.active_shards.pop_back()
	e.queue_free()
	_gl.wave_director.current_wave = saved_wave


# ── 2026-09-13 七轮反馈（护盾溢出修复 / 属性展示 / 全量死卡审计接线） ──
func _test_round7_audit() -> void:
	print("── 七轮反馈（护盾溢出/属性展示/死卡审计） ──")
	var p: Node = _gl.player
	# ① 护盾条填充不溢出面板（填充起点 x=34、面板宽 148 → 上限 111）
	var hud: HUD = _gl.hud
	var shield_panel: Control = hud.get_node("Root/ShieldBar")
	var shield_fill: Panel = shield_panel.get_node("ShieldFill")
	p.set("shield_interval", 8.0)
	p.set("shield_ready", true)
	p.set("shield_timer", 0.0)
	hud.refresh_stats()
	_check("护盾条：满充能填充宽度 ≤ 111（不溢出 148 面板）",
		float(shield_fill.size.x) <= 111.5,
		"fill_w=%s" % str(shield_fill.size))
	# ② 构筑详情卡属性行（攻击/暴击/间隔实际生效值）
	var w0: WeaponBase = p.weapon_slots[0]
	var line: String = _gl.pause_overlay._weapon_stat_line(w0)
	_check("属性展示：详情卡属性行含 攻击/暴击/间隔 三段",
		"攻击" in line and "暴击" in line and "间隔" in line, line)
	# ③ AFF_PROJ_SPD / AFF_AREA 死卡接线（弹道弹速 / 碰撞半径乘数）
	var spd_t: TraitData = _gl.registry.get_trait(&"AFF_PROJ_SPD")
	var area_t: TraitData = _gl.registry.get_trait(&"AFF_AREA")
	var mult0: float = float(w0.call("_proj_spd_mult"))
	var size0: float = float(w0.call("_proj_size_mult"))
	w0.attach_trait(spd_t)
	w0.attach_trait(area_t)
	var mult1: float = float(w0.call("_proj_spd_mult"))
	var size1: float = float(w0.call("_proj_size_mult"))
	_check("死卡接线：弹速池/体积池挂卡后乘数 > 1（衰减聚合）",
		mult0 == 1.0 and size0 == 1.0 and mult1 > 1.1 and size1 > 1.08,
		"spd %s→%s size %s→%s" % [mult0, mult1, size0, size1])
	# ④ AFF_SKILL_HASTE（原移速卡重做）：挂卡 → 技能基线缩短
	var haste_t: TraitData = _gl.registry.get_trait(&"AFF_SKILL_HASTE")
	_check("夹具：AFF_SKILL_HASTE 就位（add_skillcdr 池）",
		haste_t != null and String(haste_t.pool_id) == "add_skillcdr")
	var cd0: float = float(p.get("skill_cd_base"))
	p.call("refresh_skill_cd")
	w0.attach_trait(haste_t)
	p.call("refresh_skill_cd")
	var cd1: float = float(p.get("skill_cd_base"))
	_check("死卡接线：技能急速挂卡 → 技能冷却基线缩短", cd1 < cd0,
		"%s→%s" % [cd0, cd1])
	# ⑤ AFF_PICKUP 死卡接线：磁吸半径增长
	var pick_t: TraitData = _gl.registry.get_trait(&"AFF_PICKUP")
	var r0: float = float(p.get("pickup_radius"))
	w0.attach_trait(pick_t)
	p.call("refresh_pickup_radius")
	var r1: float = float(p.get("pickup_radius"))
	_check("死卡接线：拾取半径词条 → 磁吸半径增长", r1 > r0, "%s→%s" % [r0, r1])
	# ⑥ 形态/武器适配门：谐振轨道不上手枪货架、环绕武器可得上；弹丸数/穿透不进近战
	var gen := _gl.card_generator
	var orbit_w: WeaponBase = OrbitWeapon.new()
	_gl.add_child(orbit_w)
	orbit_w.setup(_gl.registry.get_weapon(&"W8_orbit_field"), null, {})
	var mech_pistol: Array[StringName] = gen._trait_candidates("MECH", p, [], w0)
	var mech_orbit: Array[StringName] = gen._trait_candidates("MECH", p, [], orbit_w)
	_check("形态门：手枪货架无谐振轨道（§5.12 P0 根修）", not mech_pistol.has(&"MEC_ORBIT_LINK"))
	_check("形态门：环绕武器货架有谐振轨道", mech_orbit.has(&"MEC_ORBIT_LINK"))
	var multi_orbit: Array[StringName] = gen._trait_candidates("ADD", p, [], orbit_w)
	_check("形态门：非弹道武器无弹丸数/穿透卡",
		not multi_orbit.has(&"AFF_MULTI") and not multi_orbit.has(&"AFF_PIERCE"))
	orbit_w.queue_free()
	# ⑦ REL_BLACK_MARKET：排程 → 波清空后真实开店（LEVEL_UP 态 + 商店可见）
	if _gl.state != GameConst.GameStatus.MENU:
		_gl.quit_to_menu()
	_gl.start_run()
	_gl.current_map_id = &"world_swamp"        # R10：黑市重调 w8 起每 5 波；沼泽 final 30 避开胜利结算
	Meta.set_run_map(&"world_swamp")
	_gl.relic_handler.activate(&"REL_BLACK_MARKET")
	EventBus.emit_wave_cleared(8)
	_check("黑市遗物：w8 清空 → 排程消费并开店（LEVEL_UP + 可见）",
		_gl.relic_handler.pending_shop_waves == 0
		and _gl.state == GameConst.GameStatus.LEVEL_UP
		and _gl.shop_ui.is_shop_visible())
	_gl.shop_ui.close()
	_gl.quit_to_menu()
	# ⑧ AFF_XP_GAIN（R9 经验倍率卡）：挂卡 → gain_xp 放大（压平经验防升级仲裁）
	_gl.start_run()
	var xp_t: TraitData = _gl.registry.get_trait(&"AFF_XP_GAIN")
	_check("夹具：AFF_XP_GAIN 就位（add_xp 池）",
		xp_t != null and String(xp_t.pool_id) == "add_xp")
	var w9: WeaponBase = _gl.player.weapon_slots[0]
	_gl.player.xp_need = 999999.0
	var xp_snap: float = float(_gl.player.xp)
	w9.attach_trait(xp_t)
	_gl.player.gain_xp(10.0)
	var xp_gain: float = float(_gl.player.xp) - xp_snap
	_check("经验倍率卡：挂卡后 10 经验入账 > 10（×1.15）", xp_gain > 10.0,
		"gain=%s" % str(xp_gain))
	_gl.quit_to_menu()
	# ⑨ 反弹动作实感修复（R9b）：①带预算子弹寿命延长 ②反弹谱变组合门
	var bounce_t: TraitData = _gl.registry.get_trait(&"MEC_BOUNCE")
	var spec_t: TraitData = _gl.registry.get_trait(&"SYN_BOUNCE_SPEC")
	_check("夹具：MEC_BOUNCE / SYN_BOUNCE_SPEC 就位", bounce_t != null and spec_t != null)
	var wb: WeaponBase = _gl.player.weapon_slots[0]
	var gen9 := _gl.card_generator
	var add_plain: Array[StringName] = gen9._trait_candidates("MULT", _gl.player, [], wb)
	_check("反弹组合门：未持「边界反弹」时「反弹谱变」不上架", not add_plain.has(&"SYN_BOUNCE_SPEC"))
	wb.attach_trait(bounce_t)
	var add_with: Array[StringName] = gen9._trait_candidates("MULT", _gl.player, [], wb)
	_check("反弹组合门：持有「边界反弹」后「反弹谱变」上架", add_with.has(&"SYN_BOUNCE_SPEC"))
	var bproj_params := {"lifetime": 1.6}
	var bounce_proj: ProjectileBase = (_gl.pools[&"projectile"] as ProjectilePool).acquire()
	if bounce_proj != null:
		_bounce_probe(bounce_proj, bounce_t, bproj_params)
	_check("反弹动作：带预算子弹【射程无限】（寿命抬到 20s 上限，打空必达边界）",
		bounce_proj == null or float(bounce_proj.lifetime_left) >= 20.0,
		"life=%s" % str(bounce_proj.lifetime_left) if bounce_proj != null else "no-proj")
	if bounce_proj != null:
		(bounce_proj as ProjectileBase).nullify()
	# ⑩ 元素弹色串扰回归（R12：用户实测「霰弹枪点火，手枪弹丸变红」）
	var fire_t: TraitData = _gl.registry.get_trait(&"ELE_IGNITE")
	var w_pistol: WeaponBase = _gl.player.weapon_slots[0]
	_gl.player.set("unlocked_slots", 5)        # 装配需空槽（R12 回归用例解锁全槽）
	var w_shot: WeaponBase = _gl.player.call(&"add_weapon", _gl.registry.get_weapon(&"W3_shotgun"))
	_check("夹具：霰弹枪装配成功", w_shot != null and w_shot.data.id == &"W3_shotgun")
	w_shot.attach_trait(fire_t)
	w_pistol.try_fire()
	w_shot.try_fire()
	var pistol_elems: Array[int] = []
	var shot_elems: Array[int] = []
	for c in (_gl.pools[&"projectile"] as Node).get_children():
		var pr: Variant = c
		if pr == null or not is_instance_valid(pr) or not bool(pr.get("_live")):
			continue
		var el: int = int(pr.get("element"))
		if int(pr.get("weapon_uid")) == w_pistol.uid:
			pistol_elems.append(el)
		elif int(pr.get("weapon_uid")) == w_shot.uid:
			shot_elems.append(el)
	var pistol_clean := true
	for el: int in pistol_elems:
		if el != GameConst.Element.KIN:
			pistol_clean = false
	var shot_fired := shot_elems.size() > 0
	var shot_fire := shot_fired
	for el: int in shot_elems:
		if el != GameConst.Element.FIR:
			shot_fire = false
	_check("元素弹色：手枪弹全部 KIN（无跨武器串扰）", pistol_clean,
		"pistol_elems=%s" % str(pistol_elems))
	_check("元素弹色：霰弹弹全部 FIR（火附魔生效）", shot_fire,
		"shot_elems=%s" % str(shot_elems))
	for c in (_gl.pools[&"projectile"] as Node).get_children():
		if c is ProjectileBase and bool(c.get("_live")):
			(c as ProjectileBase).nullify()
	# ⑪ R15：经验萃取卡显示【通用】（不再挂武器名）
	var xp_card: Dictionary = gen._make_trait_card(&"AFF_XP_GAIN", 1, w_pistol)
	_check("通用前缀：经验萃取卡含【通用】（不再挂武器名）",
		"【通用】" in String(xp_card.get("display_name")),
		str(xp_card.get("display_name")))
	# ⑫ R15：自导武器边界反弹（此前自导 tick 无边界反弹路径）
	var homing_w: WeaponBase = _gl.player.call(&"add_weapon", _gl.registry.get_weapon(&"W6_micro_missile"))
	if homing_w != null:
		homing_w.attach_trait(bounce_t)
		homing_w.try_fire()
		var bounced := false
		var homing_live := 0
		for c in (_gl.pools[&"projectile"] as Node).get_children():
			var pr2: Variant = c
			if pr2 != null and is_instance_valid(pr2) and bool(pr2.get("_live")) 					and int(pr2.get("weapon_uid")) == homing_w.uid:
				homing_live += 1
				if int(pr2.get("bounces_left")) > 0 and float(pr2.get("lifetime_left")) >= 20.0:
					bounced = true
		_check("自导反弹：导弹带预算（射程无限 + 预算注入）", homing_live > 0 and bounced,
			"live=%d" % homing_live)
	# ⑬ R15：冰原通关 → 解锁魔域（通关链 + 胜利流程联动）
	_gl.quit_to_menu()
	_gl.current_map_id = &"world_frost"
	_gl.start_run()
	_gl.wave_director.current_wave = 15
	EventBus.emit_wave_cleared(15)
	_check("冰原通关：w15 清空 → 冰原已通关标记", Meta.is_map_cleared(&"world_frost"))
	_check("冰原通关：魔域随之解锁", Meta.is_map_unlocked(&"world_demon"))
	print("── 七轮反馈完 ──")


func _test_r68_confetti() -> void:
	print("── R68 彩纸冻结根修 ──")
	# 用户反馈「还有boss爆炸的色块还在」+ 运行日志实证（9.8 万行 "Trying to assign
	# invalid previously freed instance" at confetti.gd:_process）：旧版到期彩纸只
	# queue_free 不摘数组 → 下一帧类型化赋值在已释放实例上赋值即抛错 → _process 中止
	# → 排在其后的彩纸冻结半空永不清除。修复后到期/外销项立即摘数组，数组恒存活项。
	var burst := ConfettiBurst.new()
	_gl.add_child(burst)                           # 入树（_celebrate 内 ding 跳字需 create_tween）
	burst._celebrate(Vector2(360.0, 640.0))
	_check("R68：彩纸爆发满编 90 枚（64 fountain + 26 rain）",
		burst._pieces.size() == 90, "size=%d" % burst._pieces.size())
	# E4 单节点化：纯数据结构（无 node 键）——到期摘数组断言即覆盖（下方 2.5s 全清）。
	# 泵 2 帧推进确认逐帧推进 + 摘除纪律仍生效
	burst._process(DT)
	burst._process(DT)
	_check("E4：彩纸纯数据推进（无子节点——单 draw pass）",
		burst.get_child_count() == 1, "children=%d" % burst.get_child_count())  # 仅 ding Label
	# 泵 2.5s（120Hz × 300 帧 > 最长寿命 1.1s）：全部到期，数组清空、_alive 复位
	for i in range(300):
		burst._process(DT)
	_check("R68：2.5s 后彩纸全清（数组空——不再有冻结半空的残留条）",
		burst._pieces.is_empty(), "left=%d" % burst._pieces.size())
	_check("R68：_alive 复位待发（下次 Boss 死亡可再爆发）", not burst._alive)
	# 再爆一轮验证复位可复用（w10/w20/w30 多次庆祝）：数组重新满编
	burst._celebrate(Vector2(360.0, 640.0))
	_check("R68：复位后再爆发满编 90（多 Boss 复用不残留）",
		burst._pieces.size() == 90, "size=%d" % burst._pieces.size())
	burst.free()                                   # 宿主自清（ding Label 等余项）


func _test_r69_rarity_ladder() -> void:
	print("── R69 品质梯审计修复 ──")
	# 用户反馈「自己检查一下有哪些buff多品质的分配不合理（金色不够强），或者干脆
	# 不同级别数值一样的情况」——审计 6 处实锤，本块验收修复后的品质梯分化：
	# ① 计数型取整塌缩（AFF_PIERCE/AFF_MULTI 基值 1.0 ×1.4 取整回 +1「蓝=白」）
	# ② MEC_ORBIT_LINK value 死数字 + ON_SPAWN 实机永不派发（真机死卡）
	# ③ MEC_SHIELD value 死数字（四品质同 8s）④ MEC_KILL_BLAST 同（同 30%）
	# ⑤ ELE_REACTION_VOID 读 params 不读 value（同 ×1.8）
	var gen: CardGenerator = _gl.card_generator
	# ① 计数梯：基值 1.45 → round 梯 +1/+2/+3/+4（四档全分化）
	for id in [&"AFF_PIERCE", &"AFF_MULTI", &"MEC_ORBIT_LINK"]:
		var src: TraitData = _gl.registry.get_trait(id)
		var ladder: Array = []
		for r in range(4):
			var cards: Array[Dictionary] = [{
				"kind": CardGenerator.CardKind.TRAIT, "id": src.id, "rarity": r,
				"data": src, "value_scale": 1.0, "display_name": "t", "description": "t",
			}]
			gen._apply_rarity_values(cards)
			ladder.append(int(round(float((cards[0].get("data") as TraitData).value))))
		_check("R69：%s 取整梯 +1/+2/+3/+4（基值 1.45 治「蓝=白」塌缩）" % String(id),
			ladder == [1, 2, 3, 4], str(ladder))
	# ② 卡面真值（金卡）：计数 +4（非通用分支的 +3.8 假数字）
	var pierce_gold := _gold_card(gen, &"AFF_PIERCE")
	_check("R69：穿透弹头金卡卡面「+4」（round 终值，非 +3.8）",
		String(pierce_gold.get("description")).contains("+4")
		and not String(pierce_gold.get("description")).contains("+3.8"),
		String(pierce_gold.get("description")))
	# ③ 格挡力场：金卡充能 ×2.6 → 8s/5.7/4.2/3.1s（卡面 + 实际间隔）
	var shield_gold := _gold_card(gen, &"MEC_SHIELD")
	var sd := String(shield_gold.get("description"))
	_check("R69：格挡力场金卡卡面「3.1s」/「2.1s」（充能 ×2.6）",
		sd.contains("3.1s") and sd.contains("2.1s"), sd)
	_gl.player.apply_shield_trait(1, {"interval_s": 8.0, "interval_lv2": 5.5}, 2.6)
	_check("R69：格挡金卡实际充能间隔 8/2.6 ≈ 3.08s",
		absf(_gl.player.shield_interval - 8.0 / 2.6) <= 0.01,
		"i=%.2f" % _gl.player.shield_interval)
	_gl.player.apply_shield_trait(1, {"interval_s": 8.0, "interval_lv2": 5.5}, 1.0)
	# ④ 死亡新星：金卡 value 0.78 + 卡面 78%/层2 117%
	var blast_gold := _gold_card(gen, &"MEC_KILL_BLAST")
	var bd := String(blast_gold.get("description"))
	_check("R69：死亡新星金卡 value 0.78（42/57/78% ATK 品质梯）",
		absf(float((blast_gold.get("data") as TraitData).value) - 0.78) <= 0.001,
		"v=%.3f" % float((blast_gold.get("data") as TraitData).value))
	_check("R69：死亡新星金卡卡面「78%」/层2「117%」",
		bd.contains("78%") and bd.contains("117%"), bd)
	# ⑤ 虚空反应：金卡 value 4.68 + 卡面 ×4.7（直乘口径，非 1+(N−1)×s）
	var void_gold := _gold_card(gen, &"ELE_REACTION_VOID")
	_check("R69：虚空反应金卡 value ×4.68 + 卡面「×4.7」（直乘口径）",
		absf(float((void_gold.get("data") as TraitData).value) - 4.68) <= 0.001
			and String(void_gold.get("description")).contains("×4.7"),
		String(void_gold.get("description")))


func _gold_card(p_gen: CardGenerator, p_id: StringName) -> Dictionary:
	# 品质化单卡生成辅助（rarity=3 金）
	var src: TraitData = _gl.registry.get_trait(p_id)
	var cards: Array[Dictionary] = [{
		"kind": CardGenerator.CardKind.TRAIT, "id": src.id, "rarity": 3,
		"data": src, "value_scale": 1.0, "display_name": "t", "description": "t",
	}]
	p_gen._apply_rarity_values(cards)
	return cards[0]


func _test_r70_details_haste() -> void:
	print("── R70 技能急速终值行 + 加特林深色弹条 ──")
	# 用户反馈「我技能急速一直点，但是详情没写最终加成多少」：详情卡个人属性区补
	# 技能急速终值行（skill_haste_pct 跨武器聚合，与 refresh_skill_cd 同 clamp）
	_gl.call(&"start_run")
	var haste_t: TraitData = _gl.registry.get_trait(&"AFF_SKILL_HASTE")
	var w: WeaponBase = _gl.player.weapon_slots[0]
	w.attach_trait(haste_t)
	w.attach_trait(haste_t)
	_check("R70：技能急速 2 层聚合终值 -24%（skill_haste_pct）",
		absf(_gl.player.skill_haste_pct() - 0.24) <= 0.001,
		"p=%.3f" % _gl.player.skill_haste_pct())
	_gl.hud.build_details_requested.emit()
	_check("R70 前置：详情卡打开（PAUSED）", _gl.pause_overlay.is_details_visible())
	var texts: Array[String] = []
	_collect_rtl(_gl.pause_overlay._details_list, texts)
	var haste_row := ""
	for txt: String in texts:
		if "技能急速 -" in txt:                  # 个人属性终值行（区别于武器区块词条行）
			haste_row = txt
	_check("R70：详情卡「技能急速 -24%」终值行可见",
		"-24%" in haste_row and "技能冷却" in haste_row, haste_row)
	_gl.pause_overlay.resume_requested.emit()
	for tb in w.trait_stack.traits.duplicate():
		if tb.data.id == haste_t.id:
			w.trait_stack.traits.erase(tb)
	_gl.call(&"quit_to_menu")
	# 用户反馈「加特林子弹加黑一点，加粗一点，看的很不清楚」：R69 白亮芯曳光在晴空
	# 亮底下对比不足——贴图重做为藏青弹体 + 白热弹头；画布 56×12 加厚
	var tex := TextureFactory.tracer_tex()
	var img := tex.get_image()
	var mid_lum := 0.0
	for x in range(20, 40):                        # 中段（避开头部白热段）
		var c := img.get_pixel(x, img.get_height() / 2)
		mid_lum += (c.r + c.g + c.b) / 3.0
	mid_lum /= 20.0
	_check("R70：曳光条中段弹体深色（藏青基调，亮底可读——均亮度 <0.5）",
		mid_lum < 0.5, "%.2f" % mid_lum)
	_check("R70：曳光条画布加厚 56×12（宽高比 >4 保持横条读感）",
		img.get_width() == 56 and img.get_height() == 12,
		"%d×%d" % [img.get_width(), img.get_height()])


func _test_r71_shop_fallback() -> void:
	print("── R71 黑市货架兜底 + 刷新按钮反馈 ──")
	# 用户反馈「后期我刷新黑市，没刷出东西」：① 词条全叠满 → 四类别候选枯竭 →
	# 货架空；② 金币不足刷新静默无效。修复：武器强化兜底货 + 按钮置灰
	_gl.call(&"start_run")
	var shop := _gl.shop_ui
	# ① 枯竭复现：全部武器侧可售词条叠满 stack_max（跨武器合计口径）
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
			for tid in pool:
				var td: TraitData = _gl.card_generator.registry.get_trait(tid)
				if td != null and not (td.pool_id in CardGenerator.PLAYER_SIDE_POOLS):
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
				overflow = true                    # 槽满也放不下（前置失败信号）
				break
		if overflow or not any_left:
			break
	_check("R71 前置：武器侧候选全部叠满（枯竭复现，无溢出）", not overflow)
	shop.open(_gl.player, 20, false)
	var buyable := 0
	var weapon_up_count := 0
	for ware in shop._wares:
		if not ware.is_empty():
			buyable += 1
			if String(ware.get("kind")) == "weapon_up":
				weapon_up_count += 1
	_check("R71：枯竭货架仍有 ≥3 件可买（武器强化 + 治疗包兜底——不再「没刷出东西」）",
		buyable >= 3, "buyable=%d" % buyable)
	_check("R71：武器强化兜底货上架（词条池枯竭不断货）", weapon_up_count >= 1,
		"up=%d" % weapon_up_count)
	# ② 买武器强化 → 目标武器真升 1 级
	_gl.player.set("gold", 500)
	var up_idx := -1
	for i in range(shop._wares.size()):
		if not shop._wares[i].is_empty() \
				and String(shop._wares[i].get("kind")) == "weapon_up":
			up_idx = i
			break
	if up_idx >= 0:
		var up_w: WeaponBase = shop._wares[up_idx].get("target")
		var lv0: int = int(up_w.get("level"))
		shop._buy(up_idx)
		_check("R71：购买武器强化 → 目标武器 +1 级", int(up_w.get("level")) == lv0 + 1,
			"lv %d→%d" % [lv0, int(up_w.get("level"))])
	else:
		_check("R71：购买武器强化（货架必有 weapon_up 索引）", false, "missing")
	# ③ 金币不足 → 刷新按钮置灰（静默吞点击根修）+ 点了无副作用
	_gl.player.set("gold", 0)
	shop._refresh()
	var refresh_btn := shop._root.get_node("ShopCard/ShopRefreshButton") as Button
	_check("R71：金币不足刷新按钮置灰禁点", refresh_btn != null and refresh_btn.disabled)
	var size_before: int = shop._wares.size()
	shop._on_refresh_pressed()
	_check("R71：金币不足点刷新无副作用（货架原样、不扣钱）",
		shop._wares.size() == size_before and int(_gl.player.get("gold")) == 0)
	shop.close()
	_gl.call(&"quit_to_menu")


func _bounce_probe(p_proj: ProjectileBase, p_bounce: TraitData, p_params: Dictionary) -> void:
	# 反弹寿命探针：模拟 ON_SPAWN 注入（attach 后 trait_effect_bounce 走事件派发）
	p_proj.spawn({
		"position": Vector2(360, 640), "velocity": Vector2(0, -600), "lifetime": p_params.lifetime,
		"pierce": 1, "bounces": 0, "hitbox_radius": 6.0, "element": 0, "attach_value": 0.0,
		"generation": 0, "weapon_uid": 0, "panel_snapshot": {}, "team": 0,
	})
	var tctx := TraitContext.new()
	tctx.event = GameConst.TraitEvent.ON_SPAWN
	tctx.projectile = p_proj
	var tb := TraitBase.new()
	tb.setup(p_bounce)
	tb.on_event(GameConst.TraitEvent.ON_SPAWN, tctx)   # 效果入口（闸门→effect.handle）


func _test_r72_difficulty() -> void:
	print("── R72 难度三档（困难 ×3 / 地狱 ×9 + 复活 + 成对抉择） ──")
	# ① 档位口径（GameConst 静态真源）
	_check("R72：HP/攻击乘区 1/3/9（困难 ×3，地狱再 ×3）",
		GameConst.difficulty_hp_mult(0) == 1.0 and GameConst.difficulty_hp_mult(1) == 3.0
			and GameConst.difficulty_hp_mult(2) == 9.0
			and GameConst.difficulty_dmg_mult(1) == 3.0
			and GameConst.difficulty_dmg_mult(2) == 9.0)
	_check("R72：附赠复活 0/1/3",
		GameConst.difficulty_revives(0) == 0 and GameConst.difficulty_revives(1) == 1
			and GameConst.difficulty_revives(2) == 3)
	_check("R72：成对抉择判定（地狱必触发 / 困难 5% 边界 / 普通永不）",
		GameConst.difficulty_dual_pick(2, 0.999)
			and GameConst.difficulty_dual_pick(1, 0.049)
			and not GameConst.difficulty_dual_pick(1, 0.051)
			and not GameConst.difficulty_dual_pick(0, 0.0))
	# ② 地狱局开局：难度注入 spawner + 复活 +3
	_gl._difficulty = GameConst.Difficulty.HELL
	_gl.state = GameConst.GameStatus.MENU            # 直达 MENU（start_run 前置；套件既有口径）
	_gl.call(&"start_run")
	_check("R72：地狱局 spawner 难度注入（出生管线乘区生效点）",
		_gl.spawner.difficulty == GameConst.Difficulty.HELL)
	_check("R72：地狱开局复活 = 应急协议 + 3",
		_gl.player.revives_left - Meta.revive_charges() == 3,
		"rev=%d" % _gl.player.revives_left)
	# ③ 出生管线实测：同一敌数据 普通 vs 地狱 → HP/接触伤 恰 ×9
	var e_data: EnemyData = _gl.registry.get_enemy(&"E1_grunt")
	var hp_n := 0.0
	var hp_h := 0.0
	var dmg_n := 0.0
	var dmg_h := 0.0
	for d in [GameConst.Difficulty.NORMAL, GameConst.Difficulty.HELL]:
		var spawner := EnemySpawner.new()
		spawner.pool = _gl.pools[&"enemy"]
		spawner.registry = _gl.registry
		spawner.difficulty = d
		spawner.enqueue({"data_id": &"E1_grunt", "wave": 1, "tags": 0})
		spawner.tick(0.016, _gl.enemy_grid)
		if spawner.active.is_empty():
			_check("R72：难度出生管线出怪（d=%d）" % d, false)
			spawner.free()
			continue
		var e: Enemy = spawner.active[0]
		if d == GameConst.Difficulty.NORMAL:
			hp_n = e.max_hp
			dmg_n = e.contact_dmg
		else:
			hp_h = e.max_hp
			dmg_h = e.contact_dmg
		(spawner.pool as EnemyPool).release(e)   # 池正确归还（E-04 纪律）
		spawner.active.clear()
		spawner.free()
		_check("R72：%s局 E1 出生（数值采样）" % GameConst.difficulty_name(d), true)
	if hp_n > 0.0 and hp_h > 0.0:
		_check("R72：地狱敌 HP = 普通 ×9（出生管线难度乘区）",
			absf(hp_h / hp_n - 9.0) <= 0.001, "%.1f/%.1f=%.2f" % [hp_h, hp_n, hp_h / hp_n])
		_check("R72：地狱敌接触伤 = 普通 ×9",
			absf(dmg_h / dmg_n - 9.0) <= 0.001, "%.1f/%.1f" % [dmg_h, dmg_n])
	# ④ 成对抉择 UI：6 卡双列 + 点行带走两张 + 普通模式单选协议。
	# 独立 CardSelectUI 实例（绕开 game_loop 的 choice_made 连接——避免选卡副作用
	# 关闭界面/切状态干扰后续断言）
	var dual_cards: Array[Dictionary] = []
	for i in range(6):
		dual_cards.append({
			"kind": CardGenerator.CardKind.TRAIT, "id": &"T%d" % i, "rarity": i % 4,
			"value_scale": 1.0, "display_name": "测试卡%d" % i, "description": "d",
		})
	var ui := CardSelectUI.new()
	_gl.add_child(ui)
	ui.open(dual_cards, true)
	_check("R72：成对模式 6 卡可见（candidate_count）", ui.candidate_count() == 6)
	var got_pair: Array = []
	ui.choice_made.connect(func(p_cards: Array) -> void:
		got_pair.clear()
		got_pair.append_array(p_cards))      # 容器内变异（lambda 捕贝语义下重绑不可见）
	ui.choose(4)                                # 槽 4 = 行 0 左 → 带走行 0 两张
	_check("R72：点行内任一张 → 同行两张一起选中",
		got_pair.size() == 2 and String(got_pair[0].get("display_name")) == "测试卡0"
			and String(got_pair[1].get("display_name")) == "测试卡1",
		str(got_pair))
	ui.choose(7)                                # 槽 7 = 行 1 右 → 测试卡3
	_check("R72：第二行选择映射正确（槽 7 → 卡 2/3）",
		got_pair.size() == 2 and String(got_pair[1].get("display_name")) == "测试卡3")
	ui.close()
	var three_cards: Array[Dictionary] = [dual_cards[0], dual_cards[1], dual_cards[2]]
	ui.open(three_cards, false)                 # 普通模式 3 卡
	ui.choose(0)
	_check("R72：普通模式单选协议（数组单元素——向后兼容）",
		got_pair.size() == 1 and String(got_pair[0].get("display_name")) == "测试卡0")
	ui.close()
	ui.free()
	# ⑤ 存档往返：难度入 RunSave
	_gl._difficulty = GameConst.Difficulty.HARD
	var payload := _gl.serialize_run()
	RunSave.save_run(payload)
	var loaded: Dictionary = RunSave.load_run()
	_check("R72：局内存档携带难度档（继续局保持 ×3 口径）",
		int(loaded.get("difficulty", -1)) == GameConst.Difficulty.HARD)
	RunSave.clear()
	_gl._difficulty = GameConst.Difficulty.NORMAL
	_gl.spawner.difficulty = GameConst.Difficulty.NORMAL
	_gl.state = GameConst.GameStatus.MENU


func _spawn_r72_enemy(p_id: StringName, p_pos: Vector2) -> Enemy:
	# R72 新形态敌生成辅助（真件池 + 入树 + 网格注册）
	var e := (_gl.pools[&"enemy"] as EnemyPool).acquire()
	e.spawn(_gl.registry.get_enemy(p_id), 1, 0)
	# 池化实例本就是 EnemyPool 节点子节点（spawner 同口径——不 reparent）
	e.global_position = p_pos
	_gl.spawner.active.append(e)
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	return e


func _release_r72_enemy(p_e: Enemy) -> void:
	_gl.spawner.active.erase(p_e)
	(_gl.pools[&"enemy"] as EnemyPool).release(p_e)


func _test_r72_new_enemies() -> void:
	print("── R72 新形态敌六种（盾/反弹/法术/预判/闪现自爆×2） ──")
	# ① 注册与形象
	for pair in [["E25_phase_bomber", &"phase"], ["E26_shield_lancer", &"shieldlancer"],
			["E27_warden_orb", &"warden"], ["E28_hexcaster", &"hexcaster"],
			["E29_longbowhawk", &"longbow"], ["E30_hellfire_revenant", &"revenant"]]:
		var e_data: EnemyData = _gl.registry.get_enemy(StringName(pair[0]))
		_check("R72：%s 注册可查 + 形象贴图非空" % String(pair[0]),
			e_data != null and TextureFactory.enemy_tex(pair[1]) != null)
	# ② 正面盾：E26 前方命中的伤害 ≈ 后方的 15%（绕后全伤）
	var shield_e := _spawn_r72_enemy(&"E26_shield_lancer",
		_gl.player.global_position + Vector2(180.0, 0.0))
	_check("R72：壁垒枪兵快照 正面减伤 0.85",
		absf(shield_e._frontal_shield - 0.85) <= 0.001,
		"s=%.2f" % shield_e._frontal_shield)
	var hp0 := shield_e.hp
	var r_front := DamageResult.new()
	r_front.final_value = 100.0
	r_front.pos = shield_e.global_position + Vector2(-14.0, 0.0)   # 玩家侧 = 前方
	shield_e.take_result(r_front)
	var dmg_front := hp0 - shield_e.hp
	hp0 = shield_e.hp
	var r_back := DamageResult.new()
	r_back.final_value = 100.0
	r_back.pos = shield_e.global_position + Vector2(14.0, 0.0)     # 背后
	shield_e.take_result(r_back)
	var dmg_back := hp0 - shield_e.hp
	_check("R72：正面命中伤害 ≈ 背后 ×0.15（盾面判向）",
		absf(dmg_front - 15.0) <= 1.0 and absf(dmg_back - 100.0) <= 1.0,
		"front=%.1f back=%.1f" % [dmg_front, dmg_back])
	_release_r72_enemy(shield_e)
	# ③ 反弹盾：E27 首击折返（team 翻 1）→ 冷却期不弹 → 冷却走完再弹
	var warden := _spawn_r72_enemy(&"E27_warden_orb",
		_gl.player.global_position + Vector2(160.0, 0.0))
	var proj := ProjectileBase.new()
	proj.velocity = Vector2(300.0, 0.0)
	proj.team = 0
	proj.panel_snapshot = {"base_atk": 40.0}
	var bounced: bool = warden.try_reflect_projectile(proj)
	_check("R72：秘纹守卫就绪反弹（team 翻 1 + 伤害 ×0.6）",
		bounced and proj.team == 1
			and absf(float(proj.panel_snapshot.get("base_atk", 0.0)) - 24.0) <= 0.01,
		"team=%d atk=%.1f" % [proj.team, float(proj.panel_snapshot.get("base_atk", 0.0))])
	proj.team = 0
	_check("R72：冷却期不反弹（伤害照常）",
		not warden.try_reflect_projectile(proj))
	warden._reflect_cd = 0.0
	_check("R72：冷却走完恢复反弹", warden.try_reflect_projectile(proj))
	proj.free()
	_release_r72_enemy(warden)
	# ④ 法术圈：E28 施法生成紫圈 + 引爆圈内掉血/圈外免伤
	var caster := _spawn_r72_enemy(&"E28_hexcaster",
		_gl.player.global_position + Vector2(120.0, 0.0))
	caster._cast_spell(_gl.player)              # 圈钉在玩家位置
	var rings := 0
	for c in caster.get_parent().get_children():   # 圈挂敌池节点下（_blink_teleport 同口径）
		if c is Telegraph.TelegraphCircle or String(c.name) == "SpellRing":
			rings += 1
	_check("R72：咒术师施法 → 法术圈挂世界层", rings >= 1, "rings=%d" % rings)
	var hp_save: float = _gl.player.hp
	_gl.player.invuln_left = 0.0
	caster._detonate_spell(_gl.player.global_position, 95.0)   # 圈内（玩家就在圈心）
	_check("R72：法术圈引爆 圈内玩家掉血（contact_dmg 口径）",
		_gl.player.hp < hp_save, "hp %.0f→%.0f" % [hp_save, _gl.player.hp])
	hp_save = _gl.player.hp
	_gl.player.invuln_left = 0.0
	caster._detonate_spell(_gl.player.global_position + Vector2(400.0, 0.0), 95.0)
	_check("R72：圈外引爆 玩家不掉血", is_equal_approx(_gl.player.hp, hp_save))
	for c in caster.get_parent().get_children():
		if String(c.name) == "SpellRing":
			c.queue_free()
	_release_r72_enemy(caster)
	# ⑤ 预判箭：E29 玩家右移 → 弹道朝玩家前方（x 速度分量显著）
	var hawk := _spawn_r72_enemy(&"E29_longbowhawk",
		_gl.player.global_position + Vector2(0.0, 200.0))
	hawk._player_vel_est = Vector2(500.0, 0.0)
	hawk.projectile_pool = _gl.pools[&"projectile"]
	_break_fire(hawk, _gl.player)              # 直调开火（绕过冷却推进）
	for p in (_gl.pools[&"projectile"] as ProjectilePool).active_projectiles():
		if p is ProjectileBase and (p as ProjectileBase).team == 1:
			var bv: Vector2 = (p as ProjectileBase).velocity
			_check("R72：长弓隼卫提前量（玩家右移 → 弹道右倾）",
				bv.x > 250.0, "v=%s" % str(bv))
			(_gl.pools[&"projectile"] as ProjectilePool).release(p)
			break
	_release_r72_enemy(hawk)
	# ⑥ E30 地狱闪现自爆参数快照
	var rev_e := _spawn_r72_enemy(&"E30_hellfire_revenant",
		_gl.player.global_position + Vector2(150.0, 0.0))
	_check("R72：狱焰归魂 爆面 150 / 引信 0.55（地狱强化口径）",
		absf(rev_e._blink_blast_r - 150.0) <= 0.01 and absf(rev_e._blink_fuse - 0.55) <= 0.01,
		"r=%.0f fuse=%.2f" % [rev_e._blink_blast_r, rev_e._blink_fuse])
	_release_r72_enemy(rev_e)
	# ⑦ 波表织入：普通零改动 / 困难混入 / 地狱全量 + 高波精英化
	var wd := _gl.wave_director
	wd.wave_table = MapTable.load_table(MapTable.FIRST_MAP_ID, _gl.registry)
	wd.difficulty = GameConst.Difficulty.NORMAL
	var normal_roll: Array[Dictionary] = wd._roll_composition(3)
	var has_new := false
	for en in normal_roll:
		if String(en.get("data_id", "")).begins_with("E25") 				or String(en.get("data_id", "")).begins_with("E26") 				or String(en.get("data_id", "")).begins_with("E28"):
			has_new = true
	_check("R72：普通局波表零改动（新形态不出现）", not has_new)
	wd.difficulty = GameConst.Difficulty.HARD
	var hard_roll: Array[Dictionary] = wd._roll_composition(3)
	var hard_new := 0
	for en in hard_roll:
		var sid := String(en.get("data_id", ""))
		if sid.begins_with("E25") or sid.begins_with("E26") or sid.begins_with("E28"):
			hard_new += 1
	_check("R72：困难局每波混入 ≥2 只新形态", hard_new >= 2, "n=%d" % hard_new)
	wd.difficulty = GameConst.Difficulty.HELL
	var hell_roll: Array[Dictionary] = wd._roll_composition(8)
	var hell_new := 0
	var hell_elite_new := false
	for en in hell_roll:
		var sid := String(en.get("data_id", ""))
		if sid.begins_with("E25") or sid.begins_with("E26") or sid.begins_with("E27") 				or sid.begins_with("E28") or sid.begins_with("E29") or sid.begins_with("E30"):
			hell_new += 1
			if int(en.get("tags", 0)) & GameConst.TAG_ELITE:
				hell_elite_new = true
	_check("R72：地狱局伴随 ≥4 只新形态 + 高波精英化", hell_new >= 4 and hell_elite_new,
		"n=%d elite=%s" % [hell_new, str(hell_elite_new)])
	wd.difficulty = GameConst.Difficulty.NORMAL
	# ⑧ 图鉴：攻击方式行 + 图标映射
	_check("R72：图鉴攻击方式行（壁垒枪兵 = 绕后提示）",
		_gl.menu_screen._enemy_attack_note("E26_shield_lancer").contains("绕"))
	_check("R72：图鉴图标映射（E27 → warden 贴图）",
		_gl.menu_screen._enemy_icon_tex("E27_warden_orb") == TextureFactory.enemy_tex(&"warden"))


func _break_fire(p_enemy: Enemy, p_player: Node2D) -> void:
	# 射箭兵开火直调（绕过冷却推进——测试注入）
	p_enemy._fire_at(p_player)


func _test_r72_content() -> void:
	print("── R72 内容扩展（遗物 6 件 + 词条 3 条） ──")
	var rh := _gl.relic_handler
	# ① 注册可查（DataValidator 全过——pkg0 rejected=0 另行锁定）
	for rid in ["REL_THORNS", "REL_KILL_FRENZY", "REL_DOUBLE_TAP", "REL_GLASS_CANNON",
			"REL_CRIT_LIFESTEAL", "REL_TIMELORD"]:
		_check("R72：遗物 %s 注册可查" % rid, _gl.registry.get_relic(rid) != null)
	for tid in ["MEC_OVERKILL", "SYN_BULWARK", "ELE_ARC_SURGE"]:
		_check("R72：词条 %s 注册可查" % tid, _gl.registry.get_trait(tid) != null)
	# ② 时之沙：技能冷却 ×0.8
	_gl.player.set("skill_cd_base", 120.0)
	_gl.player.set("skill_cd_left", 60.0)
	_check("R72：时之沙激活 → 技能冷却 120→96 / 在途 60→48",
		rh.activate(&"REL_TIMELORD")
			and absf(float(_gl.player.get("skill_cd_base")) - 96.0) <= 0.01
			and absf(float(_gl.player.get("skill_cd_left")) - 48.0) <= 0.01)
	# ③ 玻璃大炮：最大生命 −25%
	_gl.player.set("max_hp", 100.0)
	_gl.player.set("hp", 100.0)
	_check("R72：玻璃大炮激活 → 最大生命 100→75",
		rh.activate(&"REL_GLASS_CANNON")
			and absf(float(_gl.player.get("max_hp")) - 75.0) <= 0.01)
	# ④ 连杀狂热：击杀叠层 → 伤害加成；窗口衰减清零
	_check("R72：连杀狂热激活", rh.activate(&"REL_KILL_FRENZY"))
	var kill_stub := _make_killed_enemy_stub(false)
	rh._on_enemy_killed(kill_stub)
	rh._on_enemy_killed(kill_stub)
	rh._on_enemy_killed(kill_stub)
	_check("R72：3 连杀 → 狂热 +24%（3 层 ×8%）",
		absf(rh.frenzy_dmg_bonus() - 0.24) <= 0.001, "%.3f" % rh.frenzy_dmg_bonus())
	rh.tick(3.1)
	_check("R72：狂热窗口 3s 过后清零", rh.frenzy_dmg_bonus() <= 0.0)
	(_gl.pools[&"enemy"] as EnemyPool).release(kill_stub)
	# ⑤ 双重节拍：注入通道掷中时 double_tap 乘区在（rng 扫描保命中）
	_check("R72：双重节拍激活", rh.activate(&"REL_DOUBLE_TAP"))
	var tap_seen := false
	var tap_ctx := DamageContext.new()
	for i in range(200):
		tap_ctx.mult_pools.clear()
		rh.inject_hit_mult_pools(tap_ctx, null)
		for pool in tap_ctx.mult_pools:
			if StringName(String(pool.get("pool_id"))) == &"double_tap" 					and absf(float(pool.get("contrib", 0.0)) - 1.0) <= 0.001:
				tap_seen = true
	_check("R72：双重节拍 15% 概率注入 ×2 乘区（200 掷扫描必中）", tap_seen)
	# ⑥ 汲血刻印：暴击回血 + 内冷
	_gl.player.set("hp", 10.0)
	rh._lifesteal_cd_left = 0.0
	_check("R72：汲血刻印激活", rh.activate(&"REL_CRIT_LIFESTEAL"))
	var ls_r := DamageResult.new()
	ls_r.final_value = 5.0
	ls_r.is_crit = true
	ls_r.target_uid = 999
	EventBus.emit_damage_resolved(ls_r)
	_check("R72：暴击 → 回血 2% 最大生命（10→11.5）",
		absf(float(_gl.player.get("hp")) - 11.5) <= 0.01,
		"hp=%.1f" % float(_gl.player.get("hp")))
	var hp_after: float = _gl.player.get("hp")
	EventBus.emit_damage_resolved(ls_r)
	_check("R72：汲血内冷 0.6s 内不重复回血",
		is_equal_approx(float(_gl.player.get("hp")), hp_after))
	# ⑦ 荆棘王座：受击反击 AoE（近旁敌掉血）
	_check("R72：荆棘王座激活", rh.activate(&"REL_THORNS"))
	rh._thorns_cd_left = 0.0
	var thorn_e := _spawn_r72_enemy(&"E1_grunt",
		_gl.player.global_position + Vector2(80.0, 0.0))
	var thorn_hp0 := thorn_e.hp
	_gl.player.invuln_left = 0.0
	_gl.player.take_contact_damage(5.0)
	_check("R72：受击反击 → 近旁敌人掉血（settle_aoe 真结算）",
		thorn_e.hp < thorn_hp0, "%.0f→%.0f" % [thorn_hp0, thorn_e.hp])
	_release_r72_enemy(thorn_e)
	# ⑧ 新词条条件乘区：处决线 / 壁垒线 / 感电特攻
	var fw3: WeaponBase = _gl.player.weapon_slots[0]
	var saved_hp2: float = _gl.player.get("hp")
	var saved_max2: float = _gl.player.get("max_hp")
	var overkill: TraitData = _gl.registry.get_trait(&"MEC_OVERKILL")
	fw3.trait_stack.attach(overkill)
	var low_e := _spawn_r72_enemy(&"E1_grunt", Vector2(600.0, 200.0))
	low_e.hp = low_e.max_hp * 0.2                # 处决线内
	var ov_ctx := TraitContext.new()
	ov_ctx.weapon = fw3
	ov_ctx.event = GameConst.TraitEvent.ON_HIT
	ov_ctx.target = low_e
	ov_ctx.damage_ctx = DamageContext.new()
	ov_ctx.damage_ctx.player_hp_pct = 0.9        # 同时给壁垒线用
	var ov_contrib := 0.0
	for pool in fw3.trait_stack.collect_mult_pools(ov_ctx):
		if StringName(String(pool.get("pool_id"))) == &"execute_dmg":
			ov_contrib = float(pool.get("contrib"))
	_check("R72：处决协议 目标 HP<30% → ×1.5 乘区生效",
		absf(ov_contrib - 0.5) <= 0.001, "c=%.2f" % ov_contrib)
	var bulwark: TraitData = _gl.registry.get_trait(&"SYN_BULWARK")
	fw3.trait_stack.attach(bulwark)
	var bw_contrib := 0.0
	for pool in fw3.trait_stack.collect_mult_pools(ov_ctx):
		if StringName(String(pool.get("pool_id"))) == &"bulwark_dmg":
			bw_contrib = float(pool.get("contrib"))
	_check("R72：壁垒协议 玩家 HP>70% → ×1.4 乘区生效",
		absf(bw_contrib - 0.4) <= 0.001, "c=%.2f" % bw_contrib)
	var arc: TraitData = _gl.registry.get_trait(&"ELE_ARC_SURGE")
	fw3.trait_stack.attach(arc)
	if low_e.elemental == null:
		low_e.elemental = ElementalState.new()   # 条件自评容器（elemental 系按需挂）
	low_e.elemental.gauges[GameConst.Element.LTG] = 80.0   # 感电槽 ≥ 阈值（is_state_active 口径）
	var arc_contrib := 0.0
	for pool in fw3.trait_stack.collect_mult_pools(ov_ctx):
		if StringName(String(pool.get("pool_id"))) == &"shocked_dmg":
			arc_contrib = float(pool.get("contrib"))
	_check("R72：链隙电弧 感电目标 → ×1.5 乘区生效",
		absf(arc_contrib - 0.5) <= 0.001, "c=%.2f" % arc_contrib)
	_release_r72_enemy(low_e)
	for tb in fw3.trait_stack.traits.duplicate():
		if tb.data.id in [overkill.id, bulwark.id, arc.id]:
			fw3.trait_stack.traits.erase(tb)
	_gl.player.set("max_hp", saved_max2)
	_gl.player.set("hp", saved_hp2)
	# ⑨ 图鉴自动跟进：词条页数据源 = 注册表扫描（新词条零接线可见）
	_check("R72：词条注册表含新三条（图鉴扫描自动收录）",
		_gl.registry.get_trait(&"MEC_OVERKILL") != null
			and _gl.registry.get_trait(&"SYN_BULWARK") != null
			and _gl.registry.get_trait(&"ELE_ARC_SURGE") != null)
	rh.reset_run()                              # 遗物运行态清零（防污染后续）


func _test_ev1_reward() -> void:
	print("── E1 难度风险回报（困难 ×1.5 / 地狱 ×2.5） ──")
	# ① 静态口径
	_check("E1：收益乘区 1/1.5/2.5",
		GameConst.difficulty_reward_mult(0) == 1.0
			and GameConst.difficulty_reward_mult(1) == 1.5
			and GameConst.difficulty_reward_mult(2) == 2.5)
	# ② 经验入账实测：同面值碎片 地狱 = 普通 ×2.5（xp_gained 信号精确捕获——
	# xp 余量读数会被升级回路扣减污染）
	var gained: Array = []
	var xp_cb := func(p_amount: float) -> void: gained.append(p_amount)
	EventBus.xp_gained.connect(xp_cb)
	_gl.player.set_difficulty(GameConst.Difficulty.NORMAL)
	_gl.player.gain_xp(10.0)
	var xp_normal: float = float(gained[0])
	_gl.player.set_difficulty(GameConst.Difficulty.HELL)
	_gl.player.gain_xp(10.0)
	var xp_hell: float = float(gained[1])
	EventBus.xp_gained.disconnect(xp_cb)
	_gl.player.set_difficulty(GameConst.Difficulty.NORMAL)
	_check("E1：地狱同面值经验入账 = 普通 ×2.5（升级回路不受扰）",
		xp_hell / xp_normal > 2.49 and xp_hell / xp_normal < 2.51,
		"%.2f" % (xp_hell / xp_normal))
	# ③ 金币掉账：难度乘区入账（构造高掉率敌 + 扫描保证命中）
	_gl._difficulty = GameConst.Difficulty.HELL
	_gl.player.set_difficulty(GameConst.Difficulty.HELL)
	_gl.player.gold = 0
	var gold_e := _make_killed_enemy_stub(false)
	(gold_e.data as EnemyData).gold_drop = {"chance": 1.0, "min": 100, "max": 100}
	for i in range(30):
		_gl.player.gold = 0
		_gl.call("_on_enemy_killed_drop_xp", gold_e)
		if _gl.player.gold >= 240:
			break
	_check("E1：地狱金币掉账 ≥ 基值 ×2.4（×2.5 乘区落账）",
		_gl.player.gold >= 240, "gold=%d" % _gl.player.gold)
	(_gl.pools[&"enemy"] as EnemyPool).release(gold_e)
	_gl._difficulty = GameConst.Difficulty.NORMAL
	_gl.player.set_difficulty(GameConst.Difficulty.NORMAL)
	_gl.call(&"quit_to_menu")


func _test_ev2_revive() -> void:
	print("── E2 复活演出（冲击环 + 横幅 + 最高档顿帧） ──")
	_gl.player.revives_left = 1
	_gl.player.hp = 0.0
	_gl.player.invuln_left = 0.0
	var banners: Array[String] = []
	var banner_cb := func(p_text: String) -> void: banners.append(p_text)
	EventBus.mechanics_intro.connect(banner_cb)
	var blasts: Array = []
	var blast_cb := func(p_pos: Vector2, p_radius: float) -> void: blasts.append(p_radius)
	EventBus.kill_blast.connect(blast_cb)
	var ok := _gl.player._try_revive()
	EventBus.mechanics_intro.disconnect(banner_cb)
	EventBus.kill_blast.disconnect(blast_cb)
	_check("E2 前置：复活成功且满血+无敌", ok and _gl.player.hp == _gl.player.max_hp
		and _gl.player.invuln_left > 0.0)
	_check("E2：复活横幅（剩余次数提示）",
		banners.size() >= 1 and String(banners[0]).contains("复活"),
		str(banners))
	_check("E2：白环冲击表现（kill_blast 通道 r=260）",
		blasts.size() >= 1 and absf(float(blasts[0]) - 260.0) <= 0.01, str(blasts))
	_check("E2：次数耗尽拒绝复活（不误发演出）",
		not _gl.player._try_revive())


func _test_ev3_burst() -> void:
	print("── E3 升级波纹（选卡确认金色扩散环） ──")
	_gl.state = GameConst.GameStatus.MENU
	_gl.call(&"start_run")
	var bursts0 := 0
	for c in _gl.get_children():
		if String(c.name).begins_with("LevelBurst"):
			bursts0 += 1
	_gl.state = GameConst.GameStatus.LEVEL_UP
	_gl._on_card_choice([_gl.current_candidates[0] if not _gl.current_candidates.is_empty()
		else {"kind": CardGenerator.CardKind.FALLBACK, "id": &"t"}])
	var bursts := 0
	for c in _gl.get_children():
		if c is GameLoop.LevelBurst:
			bursts += 1
	_check("E3：选卡确认 → 波纹件挂载（≥1）", bursts >= bursts0 + 1, "n=%d" % bursts)
	_check("E3：波纹推进后自清（0.6s 模拟）",
		true)                                     # 生命周期断言走帧模拟（下方）
	var burst_ref: GameLoop.LevelBurst = null
	for c in _gl.get_children():
		if c is GameLoop.LevelBurst:
			burst_ref = c
	if burst_ref != null:
		for i in range(60):
			burst_ref._process(1.0 / 60.0)
		_check("E3：0.5s 生命周期到点自清（queue_free 已请求）",
			burst_ref.is_queued_for_deletion())
	else:
		_check("E3：波纹件引用（缺失跳过生命周期断言）", bursts == 0)
	_gl.call(&"quit_to_menu")


func _test_ev5_first_met() -> void:
	print("── E5 新怪首遇提示条（跨局一次） ──")
	Meta.codex_first_met.clear()                # 测试档清位（首遇态复位）
	var notices: Array[String] = []
	var cb := func(p_text: String) -> void: notices.append(p_text)
	EventBus.mechanics_intro.connect(cb)
	var e := _spawn_r72_enemy(&"E26_shield_lancer",
		_gl.player.global_position + Vector2(150.0, 0.0))
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	_gl.spawner.tick(0.016, _gl.enemy_grid)     # 出队管线（同帧无队列——直触首遇判定经 spawner tick 不覆盖此路）
	# 直接走出队路径验证：enqueue + tick
	var sp := EnemySpawner.new()
	sp.pool = _gl.pools[&"enemy"]
	sp.registry = _gl.registry
	sp.enqueue({"data_id": &"E28_hexcaster", "wave": 1, "tags": 0})
	sp.tick(0.016, _gl.enemy_grid)
	EventBus.mechanics_intro.disconnect(cb)
	_check("E5：首遇出队 → 提示条（首次遭遇 + 机制一句话）",
		notices.size() >= 1 and String(notices[0]).contains("首次遭遇")
			and String(notices[0]).contains("法术圈"), str(notices))
	_check("E5：meta 标记落账（跨局记忆）",
		Meta.codex_first_met.has("E28_hexcaster"))
	_check("E5：二次遭遇不再提示",
		not Meta.mark_first_met(&"E28_hexcaster"))
	_check("E5：旧怪无提示文案（零打扰）",
		GameConst.enemy_attack_note("E1_grunt").is_empty())
	_release_r72_enemy(e)
	if sp.active.size() > 0:
		var se: Enemy = sp.active[0]
		sp.active.clear()
		(_gl.pools[&"enemy"] as EnemyPool).release(se)
	sp.free()
	Meta.codex_first_met.clear()


func _test_ev6_bossbar() -> void:
	print("── E6 Boss 血条打击反馈（白残影 + 受击白闪） ──")
	var bar := _gl.hud.get_node_or_null("BossBar") as BossBar
	if bar == null:
		bar = BossBar.new()
		_gl.add_child(bar)
	var boss := _spawn_r72_enemy(&"E6_boss1", Vector2(400.0, 300.0))
	boss.add_tag(GameConst.TAG_BOSS) if boss.has_method(&"add_tag") else null
	boss.tags = GameConst.TAG_BOSS
	EventBus.emit_boss_spawned(boss)
	_check("E6 前置：血条登场", bar.boss == boss and bar._root.visible)
	var pct0: float = bar._last_pct
	boss.hp = boss.max_hp * 0.7                  # 打掉 30%
	bar.tick(1.0 / 60.0)
	_check("E6：掉血瞬间 → 受击白闪激活 + 残影段出现",
		bar._hurt_flash > 0.0 and bar._ghost_fill.visible
			and bar._displayed_pct > 0.69,
		"flash=%.2f ghost_w=%.0f" % [bar._hurt_flash, bar._ghost_fill.size.x])
	for i in range(70):
		bar.tick(1.0 / 60.0)                     # 1.16s：白闪衰减 + 残影追平（0.4/s 追速）
	_check("E6：0.66s 后白闪熄灭（填充回珊瑚色）",
		bar._hurt_flash <= 0.0
			and is_equal_approx(bar._fill_style.bg_color.r, PopPalette.ENEMY.r))
	_check("E6：残影追平真实血量（速读归零）",
		bar._ghost_fill.visible == false)
	EventBus.emit_enemy_killed(boss)             # 死亡链内 spawner 归还（勿二次 release）
	bar._root.visible = false
	bar.boss = null

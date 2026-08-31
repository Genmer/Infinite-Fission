# scripts/cards/card_generator.gd
# M-17 CardGenerator（架构 §2.16）：三选一候选生成/过滤/fallback/应用。
# 掉卡规则真源 A3 §6：
#   §6.1 稀有度权重（w<10 基础 {白58,蓝30,紫10,金2}；w≥10 调整公式——白 58−0.7w（下限 40）、
#        蓝 30+0.1w（上限 34）、紫 10×(1+0.045w)、金 2×(1+0.075w)，收敛于 §6.1 深度列）
#   §6.3 卡池构成（类别 roll）：MASTERY 12 / ADD 40 / MULT 18 / MECH 14 / ELEM 10 / RELIC 6
#        （遗物唯一，抽空 → 重 roll 为乘区）
#   §6.4 叠层规则：同 ID 至 stack_max 后该 ID 移出池（过滤依据）
#   AC-16.4 卡池耗尽 fallback："+5% 攻击"属性卡，界面永不空。
# RNG 注入（架构 §0.1-5：影响确定性的掷骰走 RandomNumberGenerator 实例流）。
class_name CardGenerator
extends RefCounted

enum CardKind { MASTERY, TRAIT, RELIC, FALLBACK, WEAPON }

var registry: DataRegistry = null             # M-14 注入
var rarity_weights: Dictionary = {}           # {rarity(int) -> weight(float)}（按波次折算）
var category_weights: Dictionary = {}         # {category(String) -> weight(float)}（A3 §6.3 静态表）
var owned_relics: Array[StringName] = []      # 每场已获遗物（unique 每场唯一，A3 §5）

var rng: RandomNumberGenerator = RandomNumberGenerator.new()
var fallback_uses: int = 0                    # 遥测：fallback 卡发放数（AC-16.4）

const RNG_SEED: int = 42                      # 卡牌 roll 固定种子（与管线 set_rng_seed 同口径）


func _init() -> void:
	# 卡牌 roll 确定化（B_spec 固定种子口径：测试确定性 + 同种子可复现构筑——A3 §7
	# 四套构筑可复现）；游戏运行时随机性由 spawner 出生点流（randomize）与管线暴击流
	# 承担，卡牌流不引入额外随机源。
	rng.seed = RNG_SEED

# 类别权重静态表（A3 §6.3 原值；BalanceTables.category_weights 为同源镜像）。
# WEAPON（用户反馈 2026-08-29「怎么只有手枪」：原版无任何新武器获取途径——equip_weapon
# 全工程零调用点；新武器卡补全构筑获取链）。
const CATEGORY_WEIGHTS := {
	"MASTERY": 12.0, "ADD": 36.0, "MULT": 18.0, "MECH": 14.0, "ELEM": 10.0, "RELIC": 6.0,
	"WEAPON": 10.0,
}
const CANDIDATE_COUNT := 3                    # 三选一
const MAX_WEAPON_TRAITS := 12                 # 单武器词条上限（WeaponBase.attach_trait 拒绝线）
const FALLBACK_ATK_PCT := 0.05                # fallback 属性卡：攻击 +5%（AC-16.4 原文）
# 稀有度数值倍率（用户反馈 2026-08-29「不同等级数值差距大点，不然没有刷金卡的爽感」：
# 原口径稀有度 roll 只影响卡面颜色，词条 value 恒为 .tres 定值 → 金白同值无爽感）。
# 白/蓝/紫/金 → value ×倍率，卡面描述首百分比同步重写；MASTERY 紫/金 → 连升 2 级。
const RARITY_VALUE_SCALE := [1.0, 1.4, 1.9, 2.6]
const MASTERY_DOUBLE_RARITY := 2              # 紫(2)/金(3) 精通卡 → +2 级

var _re_pct := RegEx.create_from_string("[+-]?\\d+(\\.\\d+)?%")   # 描述首百分比定位
var _re_signed := RegEx.create_from_string("[+-]\\d+(\\.\\d+)?")   # 描述首带符号数值（平数值词条）


func setup(p_registry: DataRegistry) -> void:
	# 注入注册表 + 类别权重表（BalanceTables 优先，同源镜像兜底）
	registry = p_registry
	category_weights = CATEGORY_WEIGHTS.duplicate()
	if GameConfig.balance != null and not GameConfig.balance.category_weights.is_empty():
		for key in GameConfig.balance.category_weights:
			category_weights[String(key)] = float(GameConfig.balance.category_weights[key])


func generate_candidates(p_context: Dictionary) -> Array[Dictionary]:
	# ★ 三选一：稀有度 roll → 类别 roll → 过滤 → 不足补 fallback（AC-16.4 界面永不空）
	# context: {player: Player, wave: int}
	# 集成包 B.2 增量键（全部可选，缺省 = 原 pkg4 冻结行为）：
	#   deal_count        → REL_GAMBLER 四选一（发牌数，钳 [3,8]）
	#   min_rarity_floor  → REL_OVERCLOCK 稀有度保底（应用于首张——A3 §5「下一张卡」口径）
	#   fixed_rarities    → REL_WORDS_TIDE 重随保序（逐位覆盖稀有度 roll，保留原 roll 序列）
	#   curse_last        → REL_GAMBLER 末位卡必带诅咒（A3 §9.3-10 净化占位）
	var player: Node = p_context.get("player")
	var wave := int(p_context.get("wave", 1))
	var deal := clampi(int(p_context.get("deal_count", CANDIDATE_COUNT)),
		CANDIDATE_COUNT, 8)
	var floor_rarity := int(p_context.get("min_rarity_floor", -1))
	var fixed_rarities: Variant = p_context.get("fixed_rarities", [])
	var out: Array[Dictionary] = []
	var picked_ids: Array[StringName] = []       # 同批去重（同 ID 不重复上货架）
	for i in range(deal):
		var card := _roll_one(player, wave, picked_ids)
		if card.is_empty():
			card = _fallback_stat_card()
		if card["kind"] != CardKind.FALLBACK:
			picked_ids.append(card["id"])
		out.append(card)
	# 不足 3 → fallback 补（类目全空 / 全部被过滤时兜底）
	while out.size() < CANDIDATE_COUNT:
		out.append(_fallback_stat_card())
	# REL_OVERCLOCK：稀有度保底应用于首张（A3 §5「本波下一张卡稀有度保底紫+」）
	if floor_rarity >= 0 and not out.is_empty():
		out[0]["rarity"] = maxi(int(out[0].get("rarity", 0)), floor_rarity)
	# REL_WORDS_TIDE：重随保序（逐位覆盖稀有度；deal 与保底消费顺序由调用方 GameLoop 保证）
	if fixed_rarities is Array:
		var fixed := fixed_rarities as Array
		for i in range(mini(out.size(), fixed.size())):
			out[i]["rarity"] = int(fixed[i])
	# REL_GAMBLER：第 4 张必带诅咒（apply_choice 侧附加 ATK −10% 诅咒词条）
	if bool(p_context.get("curse_last", false)) and out.size() >= 4:
		out[3]["cursed"] = true
	# 稀有度 → 数值落值（必须在 floor/fixed 覆盖之后：保底/重随改写稀有度时数值随行）
	_apply_rarity_values(out)
	return out


func _apply_rarity_values(p_cards: Array[Dictionary]) -> void:
	# 稀有度 × RARITY_VALUE_SCALE 落值：TRAIT 复制注册表资源后缩放 value（共享 .tres
	# 不落改，E-08 纪律）+ 描述首百分比重写；MASTERY 紫/金 = 连升 2 级（封顶 MAX_LEVEL）。
	for card in p_cards:
		var rarity := clampi(int(card.get("rarity", 0)), 0, RARITY_VALUE_SCALE.size() - 1)
		var scale := float(RARITY_VALUE_SCALE[rarity])
		match int(card.get("kind", CardKind.FALLBACK)):
			CardKind.TRAIT:
				if bool(card.get("scaled", false)):
					continue
				card["value_scale"] = scale
				card["scaled"] = true
				var data: TraitData = card.get("data")
				if data == null or scale <= 1.0:
					continue
				var scaled := data.duplicate() as TraitData
				scaled.value = data.value * scale
				scaled.description = _scaled_description(data.description, scale, rarity)
				card["data"] = scaled
				card["description"] = scaled.description
			CardKind.MASTERY:
				var weapon: Object = card.get("weapon")
				if weapon == null or not is_instance_valid(weapon):
					continue
				var boosts := 2 if rarity >= MASTERY_DOUBLE_RARITY else 1
				card["level_boosts"] = boosts
				var lv := int(weapon.get("level"))
				var target := mini(lv + boosts, WeaponBase.MAX_LEVEL)
				var wdata: WeaponData = weapon.get("data")
				var wname := wdata.display_name if wdata != null else "?"
				# 文案统一（用户反馈「紫色精通+3 但效果是+2」矛盾）：名称显示等级区间，
				# 描述说明提升量与连升来源
				card["display_name"] = "精通：%s Lv%d→Lv%d" % [wname, lv, target]
				var boost_txt := "（%s品质连升 ×2）" % PopPalette.rarity_name(rarity) \
					if boosts > 1 else ""
				card["description"] = ("武器等级 +%d%s（终值表口径）" % [target - lv, boost_txt]) \
					if target > lv else "已满级（终值表口径）"


func _scaled_description(p_desc: String, p_scale: float, p_rarity: int) -> String:
	# 描述数值重写（用户反馈二轮「史诗强化×1.9 是什么」→ 卡面必须直接显示真实数值）：
	# ① 首百分比 "+15%" → "+39%"；② 首带符号平数值 "+25" → "+47"（带号数字 = 效果值，
	#   "可叠 N 层"等无号数字不误伤）；③ 两者皆无 → 追加品质倍率尾注
	var m := _re_pct.search(p_desc)
	if m == null:
		m = _re_signed.search(p_desc)
	if m == null:
		return "%s（%s品质：效果数值 ×%.1f）" % [p_desc, PopPalette.rarity_name(p_rarity), p_scale]
	var raw := m.get_string()
	var is_pct := raw.ends_with("%")
	var num := raw.trim_suffix("%").to_float()
	var scaled_num := num * p_scale
	var signed := raw.begins_with("+") or raw.begins_with("-")
	var body := ("%+.1f" % scaled_num) if (signed and not is_equal_approx(scaled_num,
		roundf(scaled_num))) else (("%+.0f" % scaled_num) if signed \
		else (("%.1f" % scaled_num) if not is_equal_approx(scaled_num, roundf(scaled_num)) \
		else "%.0f" % scaled_num))
	return p_desc.substr(0, m.get_start()) + body + ("%" if is_pct else "") \
		+ p_desc.substr(m.get_end())


func apply_choice(p_card: Dictionary, p_player: Node) -> void:
	# 应用：词条挂载 / 遗物生效 / 精通升级 / 属性成长（M-17 职责）
	var kind := int(p_card.get("kind", CardKind.FALLBACK))
	match kind:
		CardKind.MASTERY:
			var weapon: Object = p_card.get("weapon")
			if weapon != null and is_instance_valid(weapon) and weapon.has_method(&"level_up"):
				# 紫/金精通连升 2 级（level_boosts 由 _apply_rarity_values 落卡；封顶在 level_up 内）
				for i in range(maxi(int(p_card.get("level_boosts", 1)), 1)):
					weapon.call(&"level_up")     # WeaponBase.level_up：level+1 → 面板失效 → leveled 信号
		CardKind.WEAPON:
			# 新武器装配（用户反馈 2026-08-29「怎么只有手枪」——原版无获取途径）。
			# 入口 = add_weapon 形态工厂（实例化 + setup + 装槽）；equip_weapon 收窄
			# WeaponBase 实例签名，传数据会污染槽位（用户实测「选了霰弹枪没出现」根因）
			var wdata: WeaponData = p_card.get("data")
			if wdata != null and p_player != null and p_player.has_method(&"add_weapon"):
				p_player.call(&"add_weapon", wdata)
		CardKind.TRAIT, CardKind.FALLBACK:
			var data: TraitData = p_card.get("data")
			if data != null:
				# 词条挂目标武器（用户反馈「全是手枪强化」——卡面标注的武器即实际挂载对象）
				var target: Object = p_card.get("target_weapon")
				var weapon := target if target is WeaponBase and is_instance_valid(target) \
					else _primary_weapon(p_player)
				if weapon != null:
					weapon.attach_trait(data)
		CardKind.RELIC:
			var rid := StringName(String(p_card.get("id", "")))
			if rid != &"" and not owned_relics.has(rid):
				owned_relics.append(rid)
	if kind == CardKind.FALLBACK:
		fallback_uses += 1
	# REL_GAMBLER 诅咒卡（第 4 张）：附加 ATK −10% 诅咒词条（运行期构造 TraitData，
	# 负贡献全额入池——B_spec 诅咒语义；净化机制 A3 §9.3-10 占位不做）
	if bool(p_card.get("cursed", false)):
		var curse := _primary_weapon(p_player)
		if curse != null:
			curse.attach_trait(_make_curse_trait())
	EventBus.emit_card_chosen(StringName(String(p_card.get("id", ""))), kind)


# ── 内部：roll 链 ─────────────────────────────────────────────────
func _roll_one(p_player: Node, p_wave: int, p_picked: Array[StringName]) -> Dictionary:
	# 单张：类别 roll（池空重 roll）→ 稀有度 roll → 候选过滤 → 随机抽 1
	var relic_available := _unowned_relic_ids().size() > 0
	for attempt in range(8):
		var category: Variant = _weighted_key(category_weights)
		if category == "RELIC" and not relic_available:
			# 遗物抽空 → 重 roll 为乘区（A3 §6.3 原文）
			category = "MULT"
		match category:
			"MASTERY":
				var pool := _mastery_candidates(p_player)
				# 同批去重（用户反馈 2026-08-29「独立升级给玩家选择」）：本批已出过的武器
				# 升级卡不再重复——多持时同批多张 MASTERY 必然指向不同武器，玩家可自选
				# 「单系走到底」还是「多系铺开」。
				var fresh: Array = []
				for w in pool:
					var token := StringName("wpn#%d" % int(w.get("uid")))
					if not p_picked.has(token):
						fresh.append(w)
				if not fresh.is_empty():
					var weapon: Object = fresh[rng.randi_range(0, fresh.size() - 1)]
					p_picked.append(StringName("wpn#%d" % int(weapon.get("uid"))))
					return _make_mastery_card(weapon)
			"ADD", "MULT", "MECH", "ELEM":
				var target := _random_owned_weapon(p_player)
				var trait_pool := _trait_candidates(category, p_player, p_picked, target)
				if not trait_pool.is_empty():
					var tid: StringName = trait_pool[rng.randi_range(0, trait_pool.size() - 1)]
					return _make_trait_card(tid, p_wave, target)
			"WEAPON":
				# 新武器卡（用户反馈 2026-08-29）：未持有武器 + 有空槽 → 随机一把上架
				var weapon_pool := _weapon_candidates(p_player)
				if not weapon_pool.is_empty():
					var wdata: WeaponData = weapon_pool[rng.randi_range(0, weapon_pool.size() - 1)]
					return _make_weapon_card(wdata)
			"RELIC":
				var relics := _unowned_relic_ids()
				if not relics.is_empty():
					var rid: StringName = relics[rng.randi_range(0, relics.size() - 1)]
					return _make_relic_card(rid, p_wave)
			_:
				pass
	return {}                                   # 全类目空 → 调用方 fallback


func _trait_candidates(p_category: String, p_player: Node, p_picked: Array[StringName],
		p_target: WeaponBase = null) -> Array[StringName]:
	# 类别 → PoolClass → 注册表池 → 叠层/重复过滤（§6.4：至 stack_max 移出池）。
	# p_target 给定时按目标武器自身叠层计数（词条目标随机化，2026-08-30）
	var pool_class := _pool_class_for(p_category)
	if registry == null or pool_class < 0:
		return []
	var used_layers := _used_trait_layers(p_player)
	if p_target != null and is_instance_valid(p_target):
		used_layers = {}
		var tstack: Variant = p_target.get("trait_stack")
		if tstack != null and tstack.get("traits") != null:
			for tb: Variant in (tstack.get("traits") as Array):
				var td: Variant = tb.get("data")
				if td != null:
					used_layers[StringName(str(td.get("id")))] = int(tb.get("layers"))
	var out: Array[StringName] = []
	for tid in registry.trait_ids_by_pool(pool_class):
		if p_picked.has(tid):
			continue                            # 同批货架去重
		var t := registry.get_trait(tid)
		if t == null:
			continue
		if used_layers.get(tid, 0) >= t.stack_max:
			continue                            # 叠层上限（§6.4）
		out.append(tid)
	return out


func _mastery_candidates(p_player: Node) -> Array:
	# 未满级武器列表（每把一个候选；A3 §3.10 同武器 5 级封顶后移出）
	var out: Array = []
	if p_player == null:
		return out
	var slots: Array = p_player.get("weapon_slots")
	for w in slots:
		if w is WeaponBase and is_instance_valid(w) and int(w.get("level")) < WeaponBase.MAX_LEVEL:
			out.append(w)
	return out


func _weapon_candidates(p_player: Node) -> Array[WeaponData]:
	# 新武器卡候选（用户反馈 2026-08-29「怎么只有手枪」）：注册表武器 − 已持有，
	# 且玩家存在已解锁空槽（equip_weapon 首空槽口径，满员不上架）
	var out: Array[WeaponData] = []
	if registry == null or p_player == null:
		return out
	var has_free_slot := false
	var owned: Dictionary = {}
	for w in p_player.get("weapon_slots"):
		if w is WeaponBase and is_instance_valid(w):
			var wd: WeaponData = w.get("data")
			if wd != null:
				owned[wd.id] = true
	var unlocked: int = int(p_player.get("unlocked_slots"))
	var slots: Array = p_player.get("weapon_slots")
	for i in range(mini(unlocked, slots.size())):
		if slots[i] == null:
			has_free_slot = true
			break
	if not has_free_slot:
		return out
	for wid in registry.weapons.keys():
		if owned.has(wid):
			continue
		var wd := registry.get_weapon(wid)
		if wd != null:
			out.append(wd)
	return out


func _make_weapon_card(p_wdata: WeaponData) -> Dictionary:
	# 新武器卡：应用 = Player.equip_weapon（首空槽装配 + 词条随武器重建）
	var wname := p_wdata.display_name if p_wdata != null else "?"
	var form_names := ["弹道", "激光", "自导", "近战"]
	var form_txt: String = form_names[clampi(int(p_wdata.form), 0, 3)] \
		if p_wdata != null else "?"
	return {
		"kind": CardKind.WEAPON,
		"id": StringName(String(p_wdata.id)) if p_wdata != null else &"",
		"rarity": 2,
		"data": p_wdata,
		"display_name": "新武器：%s" % wname,
		"description": "%s形态武器，装配至空槽位（词条随武器独立成长）" % form_txt,
		"value_scale": 1.0,
	}


func _unowned_relic_ids() -> Array[StringName]:
	# 未获得遗物（unique 每场唯一）
	var out: Array[StringName] = []
	if registry == null:
		return out
	for rid in registry.relics:
		if not owned_relics.has(rid):
			out.append(rid)
	return out


func _make_trait_card(p_tid: StringName, p_wave: int, p_target: WeaponBase = null) -> Dictionary:
	# 数值缩放统一收敛在 _apply_rarity_values（终值稀有度单次缩放——修复 2026-08-31：
	# 此前本函数按 roll 稀有度预放大一次、_apply_rarity_values 再按终值放大一次，
	# 蓝卡实际 ×1.96 / 金卡 ×6.76，卡面数字与描述口径漂移）
	var t := registry.get_trait(p_tid)
	var rarity := _roll_rarity(p_wave)
	var data: TraitData = null
	if t != null:
		data = t.duplicate() as TraitData
	# 满层质变预览（2026-08-31）：本卡若挂上即满层（ADD 池 stack_max ≥2 且现有层 = max−1）
	# → 卡面标注「质变」，描述补「全部层数 ×1.6」（质变实装在 WeaponBase.attach_trait）
	var milestone := false
	if t != null and t.pool == GameConst.PoolClass.ADD and t.stack_max >= 2 \
			and p_target != null and is_instance_valid(p_target):
		var cur := 0
		var tstack: Variant = p_target.get("trait_stack")
		if tstack != null and tstack.get("traits") != null:
			for tb: Variant in (tstack.get("traits") as Array):
				var td: Variant = tb.get("data")
				if td != null and StringName(str(td.get("id"))) == p_tid:
					cur = int(tb.get("layers"))
		milestone = cur + 1 >= t.stack_max
	var prefix := ("【%s】" % _weapon_short_name(p_target)) if p_target != null else ""
	if milestone:
		prefix = "◆质变◆" + prefix
	var card := {
		"kind": CardKind.TRAIT,
		"id": p_tid,
		"rarity": rarity,
		"value_scale": 1.0,
		"data": data,
		"target_weapon": p_target,
		"display_name": prefix + (t.display_name if t != null else String(p_tid)),
		"description": (t.description if t != null else ""),
		"milestone": milestone,
	}
	if milestone:
		var note := "\n◆ 满层质变：该词条全部层数数值 ×1.6！"
		card["description"] = String(card["description"]) + note
		if data != null:
			# 同步写入 data 副本描述（_apply_rarity_values 描述重写以 data.description 为源）
			data.description = String(data.description) + note
	return card


func _make_mastery_card(p_weapon: Object) -> Dictionary:
	var data: WeaponData = p_weapon.get("data")
	return {
		"kind": CardKind.MASTERY,
		"id": StringName(String(data.id)) if data != null else &"",
		"rarity": _roll_rarity(1),
		"data": data,
		"weapon": p_weapon,
		"display_name": "精通：%s +%d" % [data.display_name if data != null else "?", int(p_weapon.get("level")) + 1],
		"description": "武器等级 +1（终值表口径）",
	}


func _make_relic_card(p_rid: StringName, p_wave: int) -> Dictionary:
	var r := registry.get_relic(p_rid)
	return {
		"kind": CardKind.RELIC,
		"id": p_rid,
		"rarity": _roll_rarity(p_wave),
		"data": r,
		"display_name": r.display_name if r != null else String(p_rid),
		"description": r.description if r != null else "",
	}


func _fallback_stat_card() -> Dictionary:
	# 卡池耗尽 → "+5% 攻击"类属性卡（AC-16.4，界面永不空）。
	# 运行期构造 TraitData（内存对象，非 .tres 加载——E-08 纪律不破）；decay_delta 取
	# 架构示例值 0.85（与 AFF_ATK_UP 同池同 δ，F-21 约束内）。
	var data := TraitData.new()
	data.id = &"FALLBACK_ATK"
	data.display_name = "应急强化"
	data.description = "攻击力 +5%"
	data.pool = GameConst.PoolClass.ADD
	data.pool_id = &"add_atk"
	data.effect_id = &"EF_STAT"
	data.value = FALLBACK_ATK_PCT
	data.decay_delta = 0.85
	data.params = {"stat": "atk_pct"}
	data.stack_max = 99
	return {
		"kind": CardKind.FALLBACK,
		"id": &"FALLBACK_ATK",
		"rarity": 0,
		"data": data,
		"display_name": "应急强化（+5% 攻击）",
		"description": "卡池候选耗尽的保底属性卡",
	}


func _make_curse_trait() -> TraitData:
	# REL_GAMBLER 第 4 张的诅咒载荷（ATK −10%——A3 §5 curse_atk_pct；运行期构造，
	# 非 .tres 加载 E-08 纪律不破；δ 同池 0.85，F-21 约束内）
	var data := TraitData.new()
	data.id = &"GAMBLER_CURSE"
	data.display_name = "赌徒诅咒"
	data.description = "攻击力 -10%（赌徒硬币代价）"
	data.pool = GameConst.PoolClass.ADD
	data.pool_id = &"add_atk"
	data.effect_id = &"EF_STAT"
	data.value = float(CARD_EXTRA_CURSE_PARAMS.get("curse_atk_pct", -0.1))
	data.decay_delta = 0.85
	data.params = {"stat": "atk_pct", "is_curse": true}
	data.stack_max = 99
	return data


# REL_GAMBLER .tres params 镜像（curse_atk_pct 真源 resources/relics/REL_GAMBLER.tres）
const CARD_EXTRA_CURSE_PARAMS := {"curse_atk_pct": -0.1}


# ── 内部：权重工具 ────────────────────────────────────────────────
func _roll_rarity(p_wave: int) -> int:
	# A3 §6.1 基础 {58,30,10,2} → 用户反馈 2026-08-29「金色概率稍微高点」：{46,30,15,6}
	# + 波次成长加强（金 6×(1+0.06w)；w≥10 生效调整公式）
	rarity_weights = {
		0: 46.0, 1: 30.0, 2: 15.0, 3: 6.0,
	}
	if p_wave >= 10:
		rarity_weights[0] = maxf(46.0 - 0.6 * float(p_wave), 34.0)
		rarity_weights[1] = minf(30.0 + 0.1 * float(p_wave), 34.0)
		rarity_weights[2] = minf(15.0 * (1.0 + 0.05 * float(p_wave)), 30.0)
		rarity_weights[3] = 6.0 * (1.0 + 0.06 * float(p_wave))
	return int(_weighted_key(rarity_weights))


func _weighted_key(p_weights: Dictionary) -> Variant:
	# 权重随机抽取（权重和 >0 前提由静态表/校验保证）
	var total := 0.0
	for key in p_weights:
		total += maxf(float(p_weights[key]), 0.0)
	if total <= 0.0:
		return null
	var roll := rng.randf() * total
	for key in p_weights:
		roll -= maxf(float(p_weights[key]), 0.0)
		if roll <= 0.0:
			return key
	return p_weights.keys().back()


func _pool_class_for(p_category: String) -> int:
	# 类别字符串 → GameConst.PoolClass（封闭映射）
	match p_category:
		"ADD":
			return GameConst.PoolClass.ADD
		"MULT":
			return GameConst.PoolClass.MULT
		"MECH":
			return GameConst.PoolClass.MECH
		"ELEM":
			return GameConst.PoolClass.ELEM
	return -1                                 # MASTERY/RELIC 不走 Trait 池


func _used_trait_layers(p_player: Node) -> Dictionary:
	# 玩家全部武器栈的同 ID 层数合计（§6.4 叠层上限判据；玩家侧常驻词条计入首武器口径）
	var used: Dictionary = {}
	if p_player == null:
		return used
	var slots: Array = p_player.get("weapon_slots")
	for w in slots:
		if w == null or not is_instance_valid(w):
			continue
		var stack: Variant = w.get("trait_stack")
		if stack == null:
			continue
		for tb in stack.get("traits"):
			var tid: StringName = tb.get("data").id
			used[tid] = int(used.get(tid, 0)) + int(tb.get("layers"))
	return used


func _random_owned_weapon(p_player: Node) -> WeaponBase:
	# 随机选一把已装备武器（词条目标——所有武器都有强化概率，用户反馈 2026-08-30）
	var out: Array[WeaponBase] = []
	for w in p_player.get("weapon_slots"):
		if w is WeaponBase and is_instance_valid(w):
			out.append(w)
	if out.is_empty():
		return _primary_weapon(p_player)
	return out[rng.randi_range(0, out.size() - 1)]


func _weapon_short_name(p_weapon: WeaponBase) -> String:
	if p_weapon == null or not is_instance_valid(p_weapon):
		return "?"
	var wd: Variant = p_weapon.get("data")
	return String(wd.get("display_name")) if wd != null else "?"


func _primary_weapon(p_player: Node) -> WeaponBase:
	# 主武器（首个非空槽；词条挂载宿主）
	if p_player == null:
		return null
	var slots: Array = p_player.get("weapon_slots")
	for w in slots:
		if w is WeaponBase:
			return w
	return null

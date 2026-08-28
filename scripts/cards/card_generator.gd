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

enum CardKind { MASTERY, TRAIT, RELIC, FALLBACK }

var registry: DataRegistry = null             # M-14 注入
var rarity_weights: Dictionary = {}           # {rarity(int) -> weight(float)}（按波次折算）
var category_weights: Dictionary = {}         # {category(String) -> weight(float)}（A3 §6.3 静态表）
var owned_relics: Array[StringName] = []      # 每场已获遗物（unique 每场唯一，A3 §5）

var rng: RandomNumberGenerator = RandomNumberGenerator.new()
var fallback_uses: int = 0                    # 遥测：fallback 卡发放数（AC-16.4）

# 类别权重静态表（A3 §6.3 原值；BalanceTables.category_weights 为同源镜像）
const CATEGORY_WEIGHTS := {
	"MASTERY": 12.0, "ADD": 40.0, "MULT": 18.0, "MECH": 14.0, "ELEM": 10.0, "RELIC": 6.0,
}
const CANDIDATE_COUNT := 3                    # 三选一
const MAX_WEAPON_TRAITS := 12                 # 单武器词条上限（WeaponBase.attach_trait 拒绝线）
const FALLBACK_ATK_PCT := 0.05                # fallback 属性卡：攻击 +5%（AC-16.4 原文）


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
	var player: Node = p_context.get("player")
	var wave := int(p_context.get("wave", 1))
	var out: Array[Dictionary] = []
	var picked_ids: Array[StringName] = []       # 同批去重（同 ID 不重复上货架）
	for i in range(CANDIDATE_COUNT):
		var card := _roll_one(player, wave, picked_ids)
		if card.is_empty():
			card = _fallback_stat_card()
		if card["kind"] != CardKind.FALLBACK:
			picked_ids.append(card["id"])
		out.append(card)
	# 不足 3 → fallback 补（类目全空 / 全部被过滤时兜底）
	while out.size() < CANDIDATE_COUNT:
		out.append(_fallback_stat_card())
	return out


func apply_choice(p_card: Dictionary, p_player: Node) -> void:
	# 应用：词条挂载 / 遗物生效 / 精通升级 / 属性成长（M-17 职责）
	var kind := int(p_card.get("kind", CardKind.FALLBACK))
	match kind:
		CardKind.MASTERY:
			var weapon: Object = p_card.get("weapon")
			if weapon != null and is_instance_valid(weapon) and weapon.has_method(&"level_up"):
				weapon.call(&"level_up")         # WeaponBase.level_up：level+1 → 面板失效 → leveled 信号
		CardKind.TRAIT, CardKind.FALLBACK:
			var data: TraitData = p_card.get("data")
			if data != null:
				var weapon := _primary_weapon(p_player)
				if weapon != null:
					weapon.attach_trait(data)
		CardKind.RELIC:
			var rid := StringName(String(p_card.get("id", "")))
			if rid != &"" and not owned_relics.has(rid):
				owned_relics.append(rid)
	if kind == CardKind.FALLBACK:
		fallback_uses += 1
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
				if not pool.is_empty():
					var weapon: Object = pool[rng.randi_range(0, pool.size() - 1)]
					return _make_mastery_card(weapon)
			"ADD", "MULT", "MECH", "ELEM":
				var trait_pool := _trait_candidates(category, p_player, p_picked)
				if not trait_pool.is_empty():
					var tid: StringName = trait_pool[rng.randi_range(0, trait_pool.size() - 1)]
					return _make_trait_card(tid, p_wave)
			"RELIC":
				var relics := _unowned_relic_ids()
				if not relics.is_empty():
					var rid: StringName = relics[rng.randi_range(0, relics.size() - 1)]
					return _make_relic_card(rid, p_wave)
			_:
				pass
	return {}                                   # 全类目空 → 调用方 fallback


func _trait_candidates(p_category: String, p_player: Node, p_picked: Array[StringName]) -> Array[StringName]:
	# 类别 → PoolClass → 注册表池 → 叠层/重复过滤（§6.4：至 stack_max 移出池）
	var pool_class := _pool_class_for(p_category)
	if registry == null or pool_class < 0:
		return []
	var used_layers := _used_trait_layers(p_player)
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


func _unowned_relic_ids() -> Array[StringName]:
	# 未获得遗物（unique 每场唯一）
	var out: Array[StringName] = []
	if registry == null:
		return out
	for rid in registry.relics:
		if not owned_relics.has(rid):
			out.append(rid)
	return out


func _make_trait_card(p_tid: StringName, p_wave: int) -> Dictionary:
	var t := registry.get_trait(p_tid)
	return {
		"kind": CardKind.TRAIT,
		"id": p_tid,
		"rarity": _roll_rarity(p_wave),
		"data": t,
		"display_name": t.display_name if t != null else String(p_tid),
		"description": t.description if t != null else "",
	}


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


# ── 内部：权重工具 ────────────────────────────────────────────────
func _roll_rarity(p_wave: int) -> int:
	# A3 §6.1：w<10 基础 {58,30,10,2}；w≥10 调整公式（收敛于深度列）
	rarity_weights = {
		0: 58.0, 1: 30.0, 2: 10.0, 3: 2.0,
	}
	if p_wave >= 10:
		rarity_weights[0] = maxf(58.0 - 0.7 * float(p_wave), 40.0)
		rarity_weights[1] = minf(30.0 + 0.1 * float(p_wave), 34.0)
		rarity_weights[2] = 10.0 * (1.0 + 0.045 * float(p_wave))
		rarity_weights[3] = 2.0 * (1.0 + 0.075 * float(p_wave))
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


func _primary_weapon(p_player: Node) -> WeaponBase:
	# 主武器（首个非空槽；词条挂载宿主）
	if p_player == null:
		return null
	var slots: Array = p_player.get("weapon_slots")
	for w in slots:
		if w is WeaponBase:
			return w
	return null

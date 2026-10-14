# scripts/cards/card_generator.gd
# M-17 CardGenerator（架构 §2.16）：三选一候选生成/过滤/fallback/应用。
# 掉卡规则真源 A3 §6：
#   §6.1 稀有度权重（w<10 基础 {白58,蓝30,紫10,金2}；w≥10 调整公式——白 58−0.7w（下限 40）、
#        蓝 30+0.1w（上限 34）、紫 10×(1+0.045w)、金 2×(1+0.075w)，收敛于 §6.1 深度列）
#   §6.3 卡池构成（类别 roll）：MASTERY 12 / ADD 40 / MULT 18 / MECH 14 / ELEM 14（R192
#        10→14，池 8 员稀释补偿）/ RELIC 6
#        （遗物唯一，抽空 → 重 roll 为乘区）
#   §6.4 叠层规则：同 ID 至 stack_max 后该 ID 移出池（过滤依据）
#   AC-16.4 卡池耗尽 fallback："+5% 攻击"属性卡，界面永不空。
# RNG 注入（架构 §0.1-5：影响确定性的掷骰走 RandomNumberGenerator 实例流）。
class_name CardGenerator
extends RefCounted

# R246 尾追 SUBLIME=6（只追加不重排）：红色传说「技能升华」卡——单卡通用（D5），
# 效果=升华当前角色技能（player.enable_sublime，skills 泳道），不挂词条栈/不写 .tres
enum CardKind { MASTERY, TRAIT, RELIC, FALLBACK, WEAPON, SLOT_BONUS, SUBLIME }

var registry: DataRegistry = null             # M-14 注入
var _slot_rng := RandomNumberGenerator.new()   # R88 扩容金卡独立随机（种子 _init 期固定——可复现）
# R246 红色传说独立掷流（0.001% 每批一次掷）：不与主 rng/_slot_rng 混流——不扰动
# pkg4 金 500 抽等按固定种子断言分布的确定性序列（架构 §0.1-5 实例流纪律）
var _sublime_rng := RandomNumberGenerator.new()
# R246 红色传说爆率字面（用户原话「爆率只有0.001%」= 1e-5；randf() ∈ [0,1) 精确等概；
# 不进 _roll_rarity 相对权重表——那会漂移四档概率撞翻分布锁，也不接 rarity_weights
# 僵尸 .tres 镜像——设计 §2.2/§8 裁定）
const SUBLIME_CHANCE := 0.00001
const SUBLIME_SEED: int = 20261008            # 构造期定种（R88 _slot_rng 同式——可复现）
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
	# R183 真修：扩容金卡流同口径构造期定种。旧「懒初始化 seed==0 守卫」几乎恒假
	#（Godot 4 的 RandomNumberGenerator.new() 默认带熵种子）→ 4% 金卡替换实际逐进程
	# 随机——pkg4「空注册表 → 全 fallback」用例被 UI choose(0) 偶发选中的金卡污染
	#（grant_slot_bonus 改玩家槽位态）而偶发红
	_slot_rng.seed = 20260919
	# R246 红色传说流同口径构造期定种（GameLoop 每日局定种 / 常规局·继续局 randomize——
	# game_loop 与 card_generator.rng 同点注入，见 GameLoop.start_run/continue_run）
	_sublime_rng.seed = SUBLIME_SEED


func reseed_sublime(p_seed: int = -1) -> void:
	# R246 升华流种子注入口（GameLoop 消费）：每日挑战局 p_seed≥0 定种（全服同日同批
	# 出卡口径——与 card_generator.rng 同点注入）；常规局/继续局缺省 randomize
	#（存档不含 RNG 状态，继续局重掷流既有口径）
	if p_seed >= 0:
		_sublime_rng.seed = p_seed
	else:
		_sublime_rng.randomize()

# 类别权重静态表（A3 §6.3 原值；BalanceTables.category_weights 为同源镜像）。
# WEAPON（用户反馈 2026-08-29「怎么只有手枪」：原版无任何新武器获取途径——equip_weapon
# 全工程零调用点；新武器卡补全构筑获取链；R5.12-P1 构筑提速 10→14）。
# ELEM（R192 wire 案 10→14）：元素池 4→8 员（HYD/ANE/GEO/DEN 入池），w=10 时每卡获取
# 稀释 −52% 过狠、w=14 → −32%——三源同改（本 const + balance_tables.gd 默认 +
# data/balance/balance_tables.tres 运行时真源；setup() 逐键覆写本 const，单改此处运行时无效）。
# RELIC（R252 遗物扩容）：池 18→34 稀释对冲，6→8 三源同改（单卡命中率 5.1%→6.7%）。
const CATEGORY_WEIGHTS := {
	"MASTERY": 12.0, "ADD": 36.0, "MULT": 18.0, "MECH": 14.0, "ELEM": 14.0, "RELIC": 8.0,
	"WEAPON": 14.0,
}
# R5.12-P1 构筑提速①：前期货架保底 ≥1 张武器卡（w < 5 或玩家等级 ≤ 3 时生效）
const EARLY_WEAPON_UNTIL_WAVE := 5
const EARLY_WEAPON_UNTIL_LEVEL := 3
const CANDIDATE_COUNT := 3                    # 三选一
const MAX_WEAPON_TRAITS := 12                 # 单武器词条上限（WeaponBase.attach_trait 拒绝线）
# R80 玩家侧池真源上移 GameConst.PLAYER_SIDE_POOLS（卡面前缀 / 黑市过滤 / 详情归段共用）
const FALLBACK_ATK_PCT := 0.05                # fallback 属性卡：攻击 +5%（AC-16.4 原文）
# 稀有度数值倍率（用户反馈 2026-08-29「不同等级数值差距大点，不然没有刷金卡的爽感」：
# 原口径稀有度 roll 只影响卡面颜色，词条 value 恒为 .tres 定值 → 金白同值无爽感）。
# 白/蓝/紫/金 → value ×倍率，卡面描述首百分比同步重写；MASTERY boosts = 1 + rarity
#（R245 三档全分化：白+1/蓝+2/紫+3——R85 双档压平常量已删）。
const RARITY_VALUE_SCALE := [1.0, 1.4, 1.9, 2.6]

var _re_pct := RegEx.create_from_string("[+-]\\d+(\\.\\d+)?%")   # 描述首带符号百分比（R60：无符号 % 是条件阈值如 HP<35%，永不匹配）
var _re_signed := RegEx.create_from_string("[+-]\\d+(\\.\\d+)?")   # 描述首带符号数值（平数值词条）
var _re_mult := RegEx.create_from_string("×\\d+(\\.\\d+)?")         # ×N 乘区倍率（R60：乘区词条主数字，如「伤害 ×3.0」；后缀式「3.0×」不匹配）


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
	# R185 金卡「武器槽+1」替换式（用户裁定两改）：①概率按「出金的概率 5%」=每批一次掷
	#（旧每张 4% 独立掷 → 每批 3 张 ≈11.5% 过频）；②语义=提前解锁帽内下一槽（不再越帽）
	# → 仅当 unlocked < 有效帽时才可替换，帽内开满后自然断供。保底卡神圣不可替换
	#（AC-16.4 界面永不空语义）。
	var slot_roll := player != null and player.has_method(&"grant_slot_bonus") 		and int(player.get("unlocked_slots")) < int(player.call(&"slot_cap_total")) 		and _slot_rng.randf() < 0.05
	# R252 引力井（REL_GRAVITY_WELL）：持有时本批第一张词条卡走「已装备武器可装备」
	# 首选子池（首批置位，词条卡落地即消费；非词条卡不消费——语义=「第一张词条卡」）
	var gravity_pending := owned_relics.has(&"REL_GRAVITY_WELL")
	for i in range(deal):
		var card := _roll_one(player, wave, picked_ids, gravity_pending)
		if gravity_pending and int(card.get("kind", -1)) == CardKind.TRAIT:
			gravity_pending = false
		if card.is_empty():
			card = _fallback_stat_card()
		if slot_roll and card.get("kind") != CardKind.SLOT_BONUS 				and int(card.get("kind", -1)) != CardKind.FALLBACK 				and int(card.get("kind", -1)) != CardKind.SUBLIME:   # R246 双保险：金卡槽替换永不吞升华卡
			card = _make_slot_bonus_card()
			slot_roll = false                    # 每批至多一张
		if card["kind"] != CardKind.FALLBACK:
			picked_ids.append(card["id"])
		out.append(card)
	# 不足 3 → fallback 补（类目全空 / 全部被过滤时兜底）
	while out.size() < CANDIDATE_COUNT:
		out.append(_fallback_stat_card())
	# R5.12-P1 构筑提速①：前期货架保底 ≥1 张武器卡（w < 5 或 level ≤ 3）——本批无武器卡
	# 时末位替换为一张（武器池空时自然跳过；构筑成型提速，用户反馈「前期构筑太慢」）。
	# WORDS_TIDE 定序重随（fixed_rarities 非空）时豁免——替换会破坏遗物保序契约
	var saw_weapon := false
	for c in out:
		if int(c.get("kind", CardKind.FALLBACK)) == CardKind.WEAPON:
			saw_weapon = true
			break
	if not saw_weapon and player != null and fixed_rarities.is_empty() \
			and wave < EARLY_WEAPON_UNTIL_WAVE \
			and int(player.get("level")) <= EARLY_WEAPON_UNTIL_LEVEL:
		var weapon_pool := _weapon_candidates(player)
		if not weapon_pool.is_empty():
			var wdata: WeaponData = weapon_pool[rng.randi_range(0, weapon_pool.size() - 1)]
			out[out.size() - 1] = _make_weapon_card(wdata)
	# REL_OVERCLOCK：稀有度保底应用于首张（A3 §5「本波下一张卡稀有度保底紫+」）
	# R246 豁免防线：升华卡稀有度神圣（0.001% 被 100% 保底顶穿=设计破洞）——保底永不
	# 顶穿红档（现行注入在其后天然不撞，此守卫防未来插入点前移回归，T3 硬契约锁）
	if floor_rarity >= 0 and not out.is_empty() \
			and int(out[0].get("kind", -1)) != CardKind.SUBLIME:
		out[0]["rarity"] = maxi(int(out[0].get("rarity", 0)), floor_rarity)
	# REL_WORDS_TIDE：重随保序（逐位覆盖稀有度；deal 与保底消费顺序由调用方 GameLoop 保证）
	if fixed_rarities is Array:
		var fixed := fixed_rarities as Array
		for i in range(mini(out.size(), fixed.size())):
			# R246 豁免防线：重随逐位覆盖永不改写升华卡 rarity（恒 4）——T3 硬契约
			if int(out[i].get("kind", -1)) == CardKind.SUBLIME:
				continue
			out[i]["rarity"] = int(fixed[i])
	# REL_GAMBLER：第 4 张必带诅咒（apply_choice 侧附加 ATK −10% 诅咒词条）
	# R246 收紧：仅词条卡（kind==TRAIT）可被打诅咒——升华/武器/精通等非 TRAIT 卡永不
	# 带诅咒（红品质与诅咒警示红 ENEMY 同屏撞色结构性消除，设计 §1.3）
	if bool(p_context.get("curse_last", false)) and out.size() >= 4 \
			and int(out[3].get("kind", CardKind.FALLBACK)) == CardKind.TRAIT:
		out[3]["cursed"] = true
	# 稀有度 → 数值落值（必须在 floor/fixed 覆盖之后：保底/重随改写稀有度时数值随行）
	_apply_rarity_values(out)
	# R246 红色传说「技能升华」注入：独立掷流每批一次 randf()<0.001%（掷中即耗不补偿，
	# 出现率恒 ≤ 名义值绝不超发）；替换末位向前第一张非保底卡（FALLBACK/SLOT_BONUS
	# 神圣不可替换——AC-16.4 界面永不空口径；WEAPON 可被替换，0.001% 语义下接受）；
	# 全批皆保底（空注册表测试态）→ 本批放弃上架。★ 落点必须在 _apply_rarity_values 之后：
	# 前移会被其 clampi(rarity,0,size-1) 钳成金档 ×2.6（已实证）——硬约束勿前移。
	# 守卫链：鸭子 has_method(enable_sublime)（skills 泳道未合入期零掷）→ _sublime_available
	#（R247 终修：判据收紧为表 sublime_desc 非空——有技能但升华版未设计落表的角色
	#（medic/vortex/reaper）不掷，杜绝「0.001% 抽了没反应」破洞卡，设计 §3 D7）
	if player != null and player.has_method(&"enable_sublime") and _sublime_available(player) \
			and _sublime_rng.randf() < SUBLIME_CHANCE:
		for i in range(out.size() - 1, -1, -1):
			var skip_kind := int(out[i].get("kind", CardKind.FALLBACK))
			if skip_kind == CardKind.FALLBACK or skip_kind == CardKind.SLOT_BONUS:
				continue                          # 保底卡神圣不可替换
			out[i] = _make_sublime_card(player)
			break
	return out


func _apply_rarity_values(p_cards: Array[Dictionary]) -> void:
	# 稀有度 × RARITY_VALUE_SCALE 落值：TRAIT 复制注册表资源后缩放 value（共享 .tres
	# 不落改，E-08 纪律）+ 描述首百分比重写；MASTERY boosts = 1 + rarity（R245 三档
	# 全分化：白+1/蓝+2/紫+3，封顶 MAX_LEVEL）。
	for card in p_cards:
		# R246 防线：升华卡不参与词条数值缩放（红≠更强的词条，设计 §1.4 缩放域不扩档）——
		# 显式跳过免得 clampi 算出无用 scale 死值（现行注入在本函数之后，此守卫防回归）
		if int(card.get("kind", CardKind.FALLBACK)) == CardKind.SUBLIME:
			continue
		var rarity := clampi(int(card.get("rarity", 0)), 0, RARITY_VALUE_SCALE.size() - 1)
		var scale := float(RARITY_VALUE_SCALE[rarity])
		match int(card.get("kind", CardKind.FALLBACK)):
			CardKind.TRAIT:
				if bool(card.get("scaled", false)):
					continue
				card["value_scale"] = scale
				card["scaled"] = true
				var data: TraitData = card.get("data")
				if data == null:
					continue
				# R38 品级字段一致化（用户反馈「白色 buff 金色字体」）：roll 品级必须落
				# data.rarity——此前 scale≤1.0 直接跳过，源 .tres 金/紫 rarity 原样带入
				# 白品卡（白数值金名字）；共享 .tres 不落改（E-08），故无论品级一律复制
				var out := data.duplicate() as TraitData
				out.rarity = rarity
				if scale > 1.0:
					out.value = data.value * scale
					# c8④（二cp#1）：2 层质变值随品质同缩白名单泛化——value_lv2 之外扩
					# dot_ratio_lv2 / chain_decay_lv2（比率键同乘 scale）与 chain_targets_lv2
					# （计数键 round 取整——消费侧 elemental_state int() 取整安全，R192
					# 产出侧契约不变）。原病同 R192 审查④：单层附着随品质抬升后，二层
					# 质变仍用白基准 → 质变零/负收益。spread_radius_lv2 / radius_lv2
					# 维持不缩放（像素半径现行口径，HIT_BURST radius_lv2 同）。
					# params 经 duplicate() 为浅拷贝（直改写穿 .tres 注册表真源，
					# E-08）——深复制后改（R68 condition 同款防线）。
					if data.params.has("value_lv2") or data.params.has("dot_ratio_lv2") \
							or data.params.has("chain_decay_lv2") or data.params.has("chain_targets_lv2"):
						out.params = data.params.duplicate(true)
						for lv2_key in ["value_lv2", "dot_ratio_lv2", "chain_decay_lv2"]:
							if out.params.has(lv2_key):
								out.params[lv2_key] = float(out.params[lv2_key]) * scale
						if out.params.has("chain_targets_lv2"):
							out.params["chain_targets_lv2"] = int(round(
								float(out.params["chain_targets_lv2"]) * scale))
					# R66b：MULT/LOCAL 池上限随品质同缩——否则「上限=白值」的词条（背水协议
					# cap 0.6 = value 0.6）品质缩放全被单区钳制截回白值，「什么品质都一样」
					#（用户反馈「背水协议怎么什么品质都是35%」——35% 条件阈值本不缩放，
					# 乘数也因上限失效）。上限语义不变：限制区内叠层总和，锚点随本卡缩放。
				if data.pool == GameConst.PoolClass.MULT:
					out.cap_pool_p = data.cap_pool_p * scale
				elif data.pool == GameConst.PoolClass.LOCAL:
					out.cap_local = data.cap_local * scale
				# R68：PLAYER_HP_BELOW 条件阈值品质化（用户反馈「低血协议……越高级越高
				# 触发」）：每档 +7%（背水协议白/蓝/紫/金 = 35/42/49/56%）——高级卡乘数
				# 大，触发窗口同步放宽才配得上品质。condition 深拷贝后改（duplicate() 对
				# Dictionary 是浅拷贝，直改会写穿 .tres 注册表真源——E-08 违例）；描述中
				# "HP<NN%" 按旧→新整词替换（_scaled_description 本身不碰无符号 %）
				var hp_old_txt := ""
				var hp_new_txt := ""
				if int(data.condition.get("condition_id", GameConst.ConditionId.NONE)) \
						== GameConst.ConditionId.PLAYER_HP_BELOW:
					var params_in: Dictionary = data.condition.get("params", {})
					var base_pct := clampf(float(params_in.get("pct", 0.35)), 0.05, 0.9)
					var new_pct := clampf(base_pct + 0.07 * float(rarity), 0.05, 0.9)
					out.condition = data.condition.duplicate(true)
					out.condition["params"]["pct"] = new_pct
					hp_old_txt = "HP<%d%%" % int(round(base_pct * 100.0))
					hp_new_txt = "HP<%d%%" % int(round(new_pct * 100.0))
				# R69 机制/计数型词条特例卡面（_rarity_desc_mech）：这些词条的品质数值
				# 口径（取整计数/除法间隔/直接乘数）与通用 ×N、带符号% 重写不匹配——
				# 通用 ③ 分支会把「+1」重写成非整数「+3.8」与实际 round 消费不符
				# c8②：二元拓扑卡判定（value≈1.0 且 stack_max==1：束间拓扑三选一/镜面指向
				# 二选一/PHASE_SYNC 等 10 张）——效果只认挂没挂、与品质无关，品质尾注
				# 「×N」是假话，抑制之（选文案分支，不动 _roll_rarity 消费序列——seed=42
				# 选卡确定性流锚）。TH_* 阈值卡（value 同为 1.0）不上卡架，天然不在面内。
				var quality_neutral := is_equal_approx(data.value, 1.0) and data.stack_max == 1
				var custom_desc := _rarity_desc_mech(data, scale, rarity)
				if custom_desc != "":
					out.description = custom_desc
				else:
					out.description = _scaled_description(data.description, scale, rarity,
						quality_neutral)
					if not hp_new_txt.is_empty() and out.description.contains(hp_old_txt):
						out.description = out.description.replace(hp_old_txt, hp_new_txt)
				card["description"] = out.description
				card["data"] = out
			CardKind.MASTERY:
				var weapon: Object = card.get("weapon")
				if weapon == null or not is_instance_valid(weapon):
					continue
				# R85 精通卡去金档（用户「金色直接干掉，到处金色」）：品质只有白/蓝/紫——
				# L1-2 白蓝、L3 起可紫；金 roll/遗物保底金在此钳落。
				# 金色语义留给词条卡与 5 级金质变——升级卡不再抢金色读感
				var lv_pre := int(weapon.get("level"))
				var rarity_cap := 1 if lv_pre < 3 else 2
				if rarity > rarity_cap:
					rarity = rarity_cap
					card["rarity"] = rarity
				# R245 品质全分化（用户「蓝色白色都是+1？」）：boosts = 1 + rarity——
				# 白+1 / 蓝+2 / 紫+3；rarity_cap 钳档语义不变（L1-2 白蓝、L3 起可紫，金
				# roll/保底金仍钳落——R85 的去金档保留，只废除蓝白同值压平）
				var boosts := 1 + rarity
				card["level_boosts"] = boosts
				var lv := int(weapon.get("level"))
				var target := mini(lv + boosts, WeaponBase.MAX_LEVEL)
				var wdata: WeaponData = weapon.get("data")
				var wname := wdata.display_name if wdata != null else "?"
				# 文案统一（用户反馈「紫色精通+3 但效果是+2」矛盾）：名称显示等级区间，
				# 描述说明提升量与连升来源；连升倍数随 boosts 动态（R245 三档分化）
				card["display_name"] = "精通：%s Lv%d→Lv%d" % [wname, lv, target]
				# 触顶标注（R245 评审 low 落地）：连升被 Lv5 终值钳断（名义 ×N > 实升）时
				# 尾注标「已触顶」——消除「+1 与 ×3 并存」读法歧义（用户曾报「紫色精通+3
				# 但效果是+2」同类困惑；实升数字与 Lv 区间仍以实为准）
				var capped := target > lv and lv + boosts > target
				var cap_note := "，已触顶" if capped else ""
				var boost_txt := "（%s品质连升 ×%d%s）" % [PopPalette.rarity_name(rarity), boosts, cap_note] \
					if boosts > 1 else ""
				card["description"] = ("武器等级 +%d%s（终值表口径）" % [target - lv, boost_txt]) \
					if target > lv else "已满级（终值表口径）"


# R69 计数型词条（+N 取整消费；基值 1.45 → 取整梯 = 白/蓝/紫/金 +1/+2/+3/+4——
# 基值 1.0 时 ×1.4 取整塌回 +1，「蓝=白」；1.45 是四档全分化的最小实用基值）
# R187 增补：MEC_SPLIT_PRISM（W4 副激光 +1）/ MEC_MIRROR_SPLIT（W5 镜面 +1）/
# MEC_HIVE_RACK（W6 齐射 +1 枚）——计数键口径：消费点直读词条栈层数（不走 add 池、
# 显式豁免满层质变 ×1.6 与乘区名额——计数键 ≠ 伤害键）
const COUNT_TRAIT_IDS: Array[StringName] = [&"AFF_PIERCE", &"AFF_MULTI", &"MEC_ORBIT_LINK",
	&"MEC_SPLIT_PRISM", &"MEC_MIRROR_SPLIT", &"MEC_HIVE_RACK"]

# R187 阈值型词条（TH_*：质变阈值声明的注册表镜像，全局唯一 id 真源在 resources/traits/）。
# 阈值消费走 WeaponData.threshold_traits（武器 .tres 内联 metric/threshold/effect_id），
# 词条本体永不上卡架——_trait_candidates 按 params.threshold_only 过滤（防卡池污染）
const THRESHOLD_ONLY_KEY := "threshold_only"


func _rarity_desc_mech(p_data: TraitData, p_scale: float, p_rarity: int) -> String:
	# R69 机制/计数型词条卡面品质重写（返回 "" = 非特例，走通用 _scaled_description）：
	# 这些词条的品质口径与通用分支不匹配——通用 ③ 会把「+1」写成非整数「+3.8」、
	# ×N 分支按 1+(N−1)×scale 而它们的乘数是 value 直乘、间隔是除法。
	# · 计数型（AFF_PIERCE/AFF_MULTI/MEC_ORBIT_LINK）：「+1」→「+N」按 round 终值
	# · MEC_SHIELD（value=充能倍率）：秒数 = 基准/倍率（8s→5.7/4.2/3.1s）
	# · MEC_KILL_BLAST（value=爆炸伤害比）："30%"/层2 "45%" 按终值重写
	# · EF_ELEMENTAL value_lv2（params 语义键分流，id 不进判据）：先走通用重写
	#   （+22→+N.N 带号数字），再重写「→30/跳」锚 = 30×scale（R192 审查④——运行时
	#   lv2 按品质因子放大，卡面不同步即「+57.2/跳 … 质变：附着→30/跳」自相矛盾；
	#   白卡 scale=1.0 两段逐字节不变）
	# · 反应乘数卡（params.reaction_mult，value=反应乘数直乘）：「×1.8」→「×N.N」（R192
	#   泛化为语义键分流——卡 id 不进判据）
	var _r := p_rarity                                 # 预留：文案按品质措辞（当前不用）
	var desc := p_data.description
	if COUNT_TRAIT_IDS.has(p_data.id):
		var n := maxi(int(round(p_data.value * p_scale)), 1)
		return _replace_first(desc, "+1", "+%d" % n)
	if p_data.id == &"MEC_SHIELD":
		var s1 := float(p_data.params.get("interval_s", 8.0)) / p_scale
		var s2 := float(p_data.params.get("interval_lv2", 5.5)) / p_scale
		var out_s := _replace_first(desc, "8s", "%.1fs" % s1)
		return _replace_first(out_s, "5.5s", "%.1fs" % s2)
	if p_data.id == &"MEC_KILL_BLAST":
		var pct := int(round(p_data.value * p_scale * 100.0))
		var pct2 := int(round(float(p_data.params.get("atk_ratio_lv2", 0.45)) * p_scale * 100.0))
		var out_p := _replace_first(desc, "30%", "%d%%" % pct)
		return _replace_first(out_p, "45%", "%d%%" % pct2)
	if p_data.params.has("value_lv2"):
		var out_d := _scaled_description(desc, p_scale, p_rarity)
		var lv2_v := int(round(float(p_data.params.get("value_lv2", 30.0)) * p_scale))
		return _replace_first(out_d, "→30/跳", "→%d/跳" % lv2_v)
	if p_data.params.has("reaction_mult"):
		# R192 wire T5 泛化：反应乘数卡（params.reaction_mult 语义键，VOID 本含该键）共用
		# 本臂——品质缩放 = value × scale（与旧 id 特例同式）；锚字样按基值生成（基值 1.8
		# → "×1.8" 与原描述逐字节同形，金卡 1.8×2.6=4.68 → "×4.7" 逐字节不变——verify_feedback
		# 契约锁）。禁按 id 字面量分流、禁按「×N 字样」猜测分流。
		return _replace_first(desc, "×%.1f" % p_data.value,
			"×%.1f" % (p_data.value * p_scale))
	# ── c8① 五死数字卡特例臂（二cp#1：卡面死数字 ≠ 运行值随品质缩放，用户反复点名
	# 「显示的和实际不一样」类）——全部 _replace_first 定向替换，保护描述内非效果数字
	# 字样（「反弹谱变」×1.4 /「≥5 次」/ 像素半径 / 阈值档）；id 臂循 MEC_SHIELD/
	# MEC_KILL_BLAST 先例——五个词条的运行消费点全部按 id 判定（orbit_field/_set_volatile
	# 家族/homing_projectile/trait_effect_bounce/fractal），params 加语义键无运行读取方，
	# 诚实口径优先。白数字两段逐字节不变（白卡 scale=1.0 回退原文）。
	if p_data.id == &"MEC_HIT_BURST":
		# 运行（trait_effect_hit_burst.gd:26-29）：层1=value；层2=value×ratio_lv2。
		# 卡面 % = round(终值×100)；radius/radius_lv2 像素口径不缩放不重写
		var hb1 := int(round(p_data.value * p_scale * 100.0))
		var hb2 := int(round(p_data.value * p_scale * float(p_data.params.get("ratio_lv2", 1.28)) * 100.0))
		var hb := _replace_first(desc, "35%", "%d%%" % hb1)
		return _replace_first(hb, "45%", "%d%%" % hb2)
	if p_data.id == &"MEC_CRITICAL_MASS":
		# 运行（orbit_field.detonate_mult + _crit_mass_mult_bonus）：5 + value×layers；
		# 卡面按满层（2）取整——白 7×（r187_rework 行为锁同源）/蓝 8×/紫 9×/金 10×；
		# 半径 70→85px 像素口径不动
		var cm := 5 + int(round(p_data.value * p_scale * 2.0))
		return _replace_first(desc, "7×", "%d×" % cm)
	if p_data.id == &"MEC_FRACTAL":
		# 运行（trait_effect_fractal.gd:29-35）逐位同式：层1=round(value×scale)、
		# 层2=maxi(count_lv2, 层1+1)（白 2/3 蓝 3/4 紫 4/5 金 5/6）。先换层2 锚再换
		# 层1 锚——层1 换完后其数字可能与层2 锚字样撞串（蓝卡两段同为「3 枚」形态）
		var f1 := int(round(p_data.value * p_scale))
		var f2 := maxi(int(round(float(p_data.params.get("count_lv2", 3.0)))), f1 + 1)
		var fr := _replace_first(desc, "2 层 3 枚", "2 层 %d 枚" % f2)
		return _replace_first(fr, "分裂 2 枚", "分裂 %d 枚" % f1)
	if p_data.id == &"MEC_BOUNCE":
		# 运行（trait_effect_bounce.gd:20）：int(round(value))×层——卡面同式取整，修
		# 蓝卡「显示 +2.8 ≠ 运行 +3」；「反弹谱变×1.4」「≥5 次」字样由定向替换保护
		return _replace_first(desc, "+2", "+%d" % int(round(p_data.value * p_scale)))
	if p_data.id == &"MEC_FUSE_DETONATE":
		# 运行（homing_projectile._blast_secondaries）：余波 = base_atk×value×层——
		# 卡面每层值 = 0.5×scale（白 0.5/层 蓝 0.7 紫 1.0 金 1.3）
		return _replace_first(desc, "0.5/层", "%.1f/层" % (p_data.value * p_scale))
	return ""


static func _replace_first(p_s: String, p_what: String, p_with: String) -> String:
	# 只替换首次出现（GDScript String.replace 无次数参数）
	var i := p_s.find(p_what)
	if i < 0:
		return p_s
	return p_s.substr(0, i) + p_with + p_s.substr(i + p_what.length())


func _scaled_description(p_desc: String, p_scale: float, p_rarity: int,
		p_quality_neutral: bool = false) -> String:
	# 描述数值重写（用户反馈二轮「史诗强化×1.9 是什么」→ 卡面必须直接显示真实数值）。
	# R60 就近类型判优：×N / 带符号% / 带符号平数三者取**最先出现**者为效果数字——
	# ① ×N（乘区词条主数字，如侦察协议「伤害 ×3.0」）：全部 ×N 按真值终值重写
	#   N′ = 1 + (N−1)×scale（乘区 M = 1+Σ贡献，品质只缩放加成部分；叠层合并注释
	#   「合并为 ×2.0」同式同步重写，白/蓝/紫/金侦察协议 = ×3.0/3.8/4.8/6.2）；
	# ② "+15%" → "+39%"；③ "+25" → "+47"（带号数字 = 效果值；"可叠 N 层"、"HP<35%"
	#   等无号数字永不误伤——R60 修复：背水协议蓝卡条件阈值曾被缩放成 HP<49%）；
	# ④ 皆无 → 追加品质倍率尾注（c8②：二元拓扑卡 p_quality_neutral 改追加
	#   「品质不影响效果」——这些卡效果与品质无关，×N 尾注是假话）
	var mx := _re_mult.search(p_desc)
	var mp := _re_pct.search(p_desc)
	var ms := _re_signed.search(p_desc)
	const NO_MATCH: int = 1 << 30
	var pos_mult := mx.get_start() if mx != null else NO_MATCH
	var pos_pct := mp.get_start() if mp != null else NO_MATCH
	var pos_sign := ms.get_start() if ms != null else NO_MATCH
	if pos_mult < pos_pct and pos_mult <= pos_sign:
		return _rewrite_mult_numbers(p_desc, p_scale)
	var m: RegExMatch = mp if pos_pct <= pos_sign else ms
	if m == null:
		if p_quality_neutral:
			return "%s（品质不影响效果）" % p_desc
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


func _rewrite_mult_numbers(p_desc: String, p_scale: float) -> String:
	# ×N 全量重写（乘区词条）：N′ = 1 + (N−1)×scale——打印值 N = 1+Σ贡献（注册表
	# value 即加成部分），品质缩放只作用于加成段，故 ×3.0 蓝 = ×3.8 而非 ×4.2
	var out_text := ""
	var last := 0
	for mm in _re_mult.search_all(p_desc):
		var n := mm.get_string().substr(1).to_float()
		out_text += p_desc.substr(last, mm.get_start() - last) \
			+ "×%.1f" % (1.0 + (n - 1.0) * p_scale)
		last = mm.get_end()
	return out_text + p_desc.substr(last)


func apply_choice(p_card: Dictionary, p_player: Node) -> void:
	# 应用：词条挂载 / 遗物生效 / 精通升级 / 属性成长（M-17 职责）
	var kind := int(p_card.get("kind", CardKind.FALLBACK))
	match kind:
		CardKind.MASTERY:
			var weapon: Object = p_card.get("weapon")
			if weapon != null and is_instance_valid(weapon) and weapon.has_method(&"level_up"):
				# 精通按品质连升 +1/+2/+3 级（R245 三档分化；level_boosts 由
				# _apply_rarity_values 落卡；封顶在 level_up 内）
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
				if int(p_card.get("kind", CardKind.TRAIT)) == CardKind.FALLBACK:
					# R262d：FALLBACK 卡（卡池耗尽保底/黑市常青货）直走全局授予——
					# 不再挂单武器栈（用户裁定「攻击力是全局的」）
					_grant_fallback(p_player, int(data.rarity),
						String(p_card.get("display_name", "应急强化")), false)
				else:
					# 词条挂目标武器（用户反馈「全是手枪强化」——卡面标注的武器即实际挂载对象）。
					# R18 挂载侧适配门（用户点名「别加了个寂寞」）：黑市等无 target_weapon 的
					# 购买路径必须按形态/武器适配门选宿主——冷却卡不再可能挂上弹道手枪变废卡
					var target: Object = p_card.get("target_weapon")
					var weapon := target if target is WeaponBase and is_instance_valid(target) \
						else _pick_attach_target(data, p_player)
					# R189c 挂载失败转应急强化（评审#12：单栈 12 条目帽满时词条卡静默浪费——
					# 挂机无人值守下反复发生。R262d：转化改全局授予，数值按被转词条品级缩放
					#（用户裁定「不同品级 buff 数值应该不一致」）；R238 修（H2 静默降级）横幅明示
					if weapon != null and not weapon.attach_trait(data):
						_grant_fallback(p_player, int(data.rarity),
							String(data.display_name), true)
		CardKind.RELIC:
			var rid := StringName(String(p_card.get("id", "")))
			if rid != &"" and not owned_relics.has(rid):
				owned_relics.append(rid)
		CardKind.SLOT_BONUS:
			# R88 金卡 → R185 语义：提前解锁帽内下一槽（幂等失败=已满不动）
			if p_player != null and p_player.has_method(&"grant_slot_bonus"):
				p_player.call(&"grant_slot_bonus")
		CardKind.SUBLIME:
			# R246 红色传说·技能升华卡：拾取即生效（本局语义——用户原话「本局技能升级为
			# 升华版」）；不落 Meta 存档、不挂词条栈（data:null）。enable_sublime 幂等
			#（skills 泳道：局内布尔置位，同局第二张 1e-10 概率重复调用无害，不叠层补偿）。
			# 鸭子守卫与掷侧同式——skills 泳道未合入期零崩溃
			if p_player != null and p_player.has_method(&"enable_sublime"):
				p_player.call(&"enable_sublime")
				EventBus.mechanics_intro.emit("红色传说 · 技能已升华！（本局有效）")
				DebugStats.count(&"sublime_card_chosen")
	if kind == CardKind.FALLBACK:
		fallback_uses += 1
	# REL_GAMBLER 诅咒卡（第 4 张）：附加 ATK −10% 诅咒词条（运行期构造 TraitData，
	# 负贡献全额入池——B_spec 诅咒语义；净化机制 A3 §9.3-10 占位不做）
	if bool(p_card.get("cursed", false)):
		var curse := _primary_weapon(p_player)
		if curse != null:
			# R262b L17：诅咒附加失败出声（R238「选了没生效」静默家族同修——丢失对
			# 玩家有利向，透明化取舍）
			if not curse.attach_trait(_make_curse_trait()):
				DebugStats.count(&"curse_attach_rejected")
				EventBus.mechanics_intro.emit("诅咒未能附加：该武器词条栏已满")
	EventBus.emit_card_chosen(StringName(String(p_card.get("id", ""))), kind)


# ── 内部：roll 链 ─────────────────────────────────────────────────
func _roll_one(p_player: Node, p_wave: int, p_picked: Array[StringName],
		p_gravity_bias: bool = false) -> Dictionary:
	# 单张：类别 roll（池空重 roll）→ 稀有度 roll → 候选过滤 → 随机抽 1
	# 遗物类目门控（MechanicGate）：第 1 关不上架遗物——重 roll 为乘区（同抽空口径）
	var relic_available := MechanicGate.relics_unlocked() and _unowned_relic_ids().size() > 0
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
				# R252 引力井：首词条位先按「已装备武器任一可装备」划首选子池再走原抽选
				#（子池空回落全池；零新增 rng 调用——同一次数消费，仅候选集收窄）
				if p_gravity_bias and not trait_pool.is_empty():
					trait_pool = _gravity_bias_pool(trait_pool, p_player)
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


func _gravity_bias_pool(p_pool: Array[StringName], p_player: Node) -> Array[StringName]:
	# R252 引力井（REL_GRAVITY_WELL）：首词条位子池收窄——「当前已装备武器任一可装备」
	#（mount_gate_allows 任一武器命中即入池，与回响/黑市同门零分叉）；子池空回落全池。
	# 零新增 rng 调用（货架 rng 消费序不位移，仅候选集收窄——设计 §3.2-16 硬约束）。
	var slots: Variant = p_player.get("weapon_slots")
	if not (slots is Array):
		return p_pool
	var weapons: Array[WeaponBase] = []
	for w in (slots as Array):
		if w is WeaponBase and is_instance_valid(w):
			weapons.append(w)
	if weapons.is_empty():
		return p_pool                          # 无已装备武器 → 首选子池空 → 回落全池
	var out: Array[StringName] = []
	for tid in p_pool:
		var t := registry.get_trait(tid) if registry != null else null
		if t == null:
			continue
		for w2 in weapons:
			if mount_gate_allows(t, w2):
				out.append(tid)
				break
	if out.is_empty():
		return p_pool                          # 子池空回落全池（设计 §3.2-16）
	return out


func _trait_candidates(p_category: String, p_player: Node, p_picked: Array[StringName],
		p_target: WeaponBase = null) -> Array[StringName]:
	# 类别 → PoolClass → 注册表池 → 重复过滤（R226 起无叠层帽，_used_trait_layers 退役）
	# p_target 给定时按目标武器过滤（词条目标随机化，2026-08-30）
	var pool_class := _pool_class_for(p_category)
	if registry == null or pool_class < 0:
		return []
	var out: Array[StringName] = []
	for tid in registry.trait_ids_by_pool(pool_class):
		if p_picked.has(tid):
			continue                            # 同批货架去重
		var t := registry.get_trait(tid)
		if t == null:
			continue
		# R226 有意契约变更（用户拍板「肉鸽别搞上限，就是给人爽叠的」）：上架叠层帽拆除
		#（原 §6.4「至 stack_max 移出池」→ R196 放宽 ADD 池 stack_max+5 → 本轮全池无限）
		# ——满层词条持续上架，与 TraitStack.attach 无限叠同口径； MilestoneGate/形态门/
		# 死卡门等非帽过滤全部保留
		if bool(t.params.get(THRESHOLD_ONLY_KEY, false)):
			continue                            # R187 阈值型词条（TH_*）不上卡架（注册表镜像专用）
		if not MechanicGate.trait_allowed(t):
			continue                            # 元素解锁门（火/冰 第 2 关 · 雷 第 3 关）
		if not _form_allows(t, p_target):
			continue                            # 形态/武器适配门（错形态词条不上架——§5.12 P0）
		if _laser_second_elem_blocked(t, p_target):
			continue                            # R199 D17 激光双元素死卡门（上架侧收窄）
		out.append(tid)
	return out


func _laser_second_elem_blocked(p_t: TraitData, p_target: WeaponBase) -> bool:
	# R199 D17 激光双元素死卡（上架侧收窄，combat 侧零改动）：激光主束元素 = 挂载序首个
	# 非 KIN 附魔（weapon_base.gd:317-326 dominant_element；laser_weapon.gd:215 主束缺省
	# 取值）且永不轮换；trait_effect_elemental.gd:44-46 宿主元素守卫使异元素词条零附着
	# ——激光已持元素后再上架第二张元素词条卡 = 结构性死卡（零附着/无寒滞易伤冻结，
	# 碎裂反应不可达）。弹道/自导逐发随机取元素（weapon_base roll）不受此限。
	# 设计定案（laser_beam.gd:14-15）：W4 主束单元素——激光形态目标已持有元素词条
	# （ELEM 池 + params.element 键）→ 元素词条卡不再进入该目标的候选池。
	if p_target == null or not is_instance_valid(p_target):
		return false
	var wd: Variant = p_target.get("data")
	var form_v: Variant = wd.get("form") if wd != null else null
	if wd == null or (int(form_v) if form_v != null else -1) != GameConst.WeaponForm.LASER:
		return false
	if int(p_t.pool) != GameConst.PoolClass.ELEM or not p_t.params.has("element"):
		return false                             # 非元素卡/无 element 键（如反应强化）不在此限
	var tstack: Variant = p_target.get("trait_stack")
	if tstack == null or tstack.get("traits") == null:
		return false
	for tb: Variant in (tstack.get("traits") as Array):
		var td: Variant = tb.get("data")
		if td != null and int(td.pool) == GameConst.PoolClass.ELEM \
				and (td as TraitData).params.has("element"):
			return true                          # 目标已持元素词条 → 第二张元素卡不上架
	return false


func _form_allows(p_t: TraitData, p_target: WeaponBase) -> bool:
	# 卡架候选过滤 → 委托统一挂载侧门（R187 拆公共静态：回响/副本/直挂等一切
	# 非「候选-选卡」挂载路径共用同一道门，杜绝绕门分叉）
	return mount_gate_allows(p_t, p_target)


static func mount_gate_allows(p_t: TraitData, p_target: WeaponBase) -> bool:
	# ★ R187 挂载侧统一适配门（原 _form_allows 本体静态化——防回响绕门 P0 前科补挂）：
	# REL_ECHO 回响复制（relic_handler 挂载路径）等非卡架挂载必须经本门校验
	# required_weapon/required_forms/requires_trait/exclusive_group，否则「平行校准」
	# 类武器专属词条会经回响落到不适配武器（W1 验收 6 反证口径）。
	# 形态/武器适配（TraitData.params，2026-09-13 全量审计接线）：
	# · required_forms = WeaponForm 数组（0 弹道/1 激光/2 自导/3 近战）——投射物专属词条
	#   （反弹/分裂/体积/弹速/穿透/弹丸数）不上架错形态武器；
	# · required_weapon = 单武器 id（MEC_ORBIT_LINK 仅环绕力场 W8——谐振轨道上手枪误刷根修）；
	# · 两键缺省 = 全形态通用（攻击/暴击/HP/元素/条件乘区等）。
	# R199 上架侧收紧三键（死卡治理——不合格武器不再上架，货架/回响/黑市同门）：
	# · requires_weapon_keys = 能力键数组：候选 WeaponData 四形态段（ballistic/laser/homing/
	#   melee）或顶层须实有该键（消费实证 ballistic_weapon.gd:340-345 _formation_enabled
	#   纯数据驱动读 ballistic.lateral_gap_levels，全仓仅 W1 在册）——无键武器挂上即零
	#   效果死卡（D01 平行校准 / D02 回廊弹幕）；
	# · requires_projectile = true：仅携带 projectile 上下文的形态（弹道/自导经
	#   projectile_base 派发生命周期；消费侧 trait_effect_mech.gd:33 projectile==null 早退）
	#   ——激光（beam 上下文，projectile 恒 null，laser_beam.gd:587-595）与近战（无
	#   ON_EXPIRE 派发点）不上架（D03 死亡新星）；
	# · excluded_weapons = 排除武器 id 数组：同形态段内个别零消费武器精确下架，不动
	#   required_forms 锁定矩阵（D04 动能冲击——R199 D04 执行口径 supersede 记录：计划原拟
	#   required_forms 去 form 3，经实证 W8 环绕力场同 form=3 且是击退真实消费方
	#   orbit_field.gd:583 / w8_charge_cases.gd:424「40+60」锁定，去 3 会误下架 W8 并打红
	#   pool_wiring_cases.gd:306 / r187_rework_cases.gd:460/:2095 三处 R187 锁定断言；
	#   改按武器 id 精确下架零击退设计的 W9 追击者 arc_slash.gd:23/:36 全文件零读取，
	#   证据链见升级仲裁记录）。
	var forms: Variant = p_t.params.get("required_forms", null)
	var weapon_req: Variant = p_t.params.get("required_weapon", null)
	var need_trait: Variant = p_t.params.get("requires_trait", null)
	var wkeys: Variant = p_t.params.get("requires_weapon_keys", null)          # R199 D01/D02
	var need_proj: bool = bool(p_t.params.get("requires_projectile", false))   # R199 D03
	var excluded: Variant = p_t.params.get("excluded_weapons", null)           # R199 D04
	var class_req: Variant = p_t.params.get("required_class", null)            # R243 类别门
	if forms == null and weapon_req == null and need_trait == null \
			and wkeys == null and not need_proj and excluded == null and class_req == null:
		return true
	var form := -1
	var wid := &""
	var has_trait_req := false
	var weapon_class := ""
	if p_target != null and is_instance_valid(p_target):
		var wd: Variant = p_target.get("data")
		if wd != null:
			var form_v: Variant = wd.get("form")
			form = int(form_v) if form_v != null else -1
			var id_v: Variant = wd.get("id")
			wid = StringName(String(id_v)) if id_v != null else &""
			# R243 类别读回（melee.weapon_class，缺省 melee——与运行时回落同口径）
			var seg: Variant = wd.get("melee")
			weapon_class = String((seg as Dictionary).get("weapon_class", "melee")) \
				if seg is Dictionary else "melee"
		if need_trait != null:
			# 组合卡门（R9b：反弹谱变需先持有边界反弹——前置词条不在，组合卡不上架）
			var tstack: Variant = p_target.get("trait_stack")
			if tstack != null and tstack.get("traits") != null:
				for tb: Variant in (tstack.get("traits") as Array):
					var td: Variant = tb.get("data")
					if td != null and StringName(str(td.get("id"))) == StringName(String(need_trait)):
						has_trait_req = true
						break
	if weapon_req != null:
		# R65：required_weapon 支持数组（MEC_ORBIT_LINK 同时适配 W8/W9；单值口径不变）
		if weapon_req is Array:
			var allowed := false
			for wv in (weapon_req as Array):
				if wid == StringName(String(wv)):
					allowed = true
					break
			if not allowed:
				return false
		elif wid != StringName(String(weapon_req)):
			return false
	if need_trait != null and not has_trait_req:
		return false
	if wkeys != null and not _weapon_data_has_keys(p_target, wkeys):
		return false                             # R199 D01/D02 能力键门：无键武器不上架
	if need_proj and form != GameConst.WeaponForm.BALLISTIC \
			and form != GameConst.WeaponForm.HOMING:
		return false                             # R199 D03 投射物上下文门（无目标 form=-1 同拦）
	if excluded != null:
		# R199 D04 负向排除：按武器 id 精确下架（required_forms 矩阵不动——同段其余照常）
		if excluded is Array:
			for wv in (excluded as Array):
				if wid == StringName(String(wv)):
					return false
		elif wid == StringName(String(excluded)):
			return false
	if forms is Array and not (forms as Array).is_empty() and not (forms as Array).has(form):
		return false
	if class_req != null:
		# R243 类别门（§1.5）：目标必须 form 3（MELEE 族）且 melee.weapon_class ∈ 所列
		# 类别数组；目标非 form 3（含无目标 form=-1）恒 false——类别词条只属于近战族。
		# 只带 required_class 的卡不得被上方零门早退放行（早退聚合已同批扩 class_req 判空）。
		if form != GameConst.WeaponForm.MELEE:
			return false
		var class_ok := false
		if class_req is Array:
			for cv in (class_req as Array):
				if String(cv) == weapon_class:
					class_ok = true
					break
		else:
			class_ok = String(class_req) == weapon_class
		if not class_ok:
			return false
	# R19 互斥组（exclusive_group）：目标武器已挂同组词条 → 本卡永不再上架
	#（环绕形态卡口径——用户点名「选中一个后续其他就不会出现」）
	var excl: Variant = p_t.params.get("exclusive_group", null)
	if excl != null and p_target != null and is_instance_valid(p_target):
		var tstack: Variant = p_target.get("trait_stack")
		if tstack != null and tstack.get("traits") != null:
			for tb: Variant in (tstack.get("traits") as Array):
				var td: Variant = tb.get("data")
				if td != null and String(td.params.get("exclusive_group", "")) == String(excl):
					return false
	return true


# R199 D01/D02 能力键实有性（static——货架/回响/黑市经 mount_gate_allows 同门共用）：
# 所列键全部实有才放行（空数组 = 无要求恒真）；键语义与消费侧
# ballistic_weapon._formation_enabled 同源（纯数据驱动，无武器 id 硬编码）。
static func _weapon_data_has_keys(p_target: WeaponBase, p_keys: Variant) -> bool:
	if p_keys is Array:
		for kv in (p_keys as Array):
			if not _weapon_data_has_key(p_target, String(kv)):
				return false
		return true
	return _weapon_data_has_key(p_target, String(p_keys))


static func _weapon_data_has_key(p_target: WeaponBase, p_key: String) -> bool:
	# 四形态段（ballistic/laser/homing/melee）任一 Dictionary 或 WeaponData 顶层属性
	# 持有该键即真；目标无效/非 WeaponData = 无法证实实有 → false（保守不上架）
	if p_target == null or not is_instance_valid(p_target):
		return false
	var wd: Variant = p_target.get("data")
	if wd == null or not (wd is WeaponData):
		return false
	var wdata := wd as WeaponData
	if wdata.get(p_key) != null:
		return true                              # 顶层属性键
	for section in [wdata.ballistic, wdata.laser, wdata.homing, wdata.melee]:
		if section is Dictionary and section.has(p_key):
			return true                          # 形态段键（lateral_gap_levels 所在层）
	return false


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
	# 且玩家存在已解锁空槽（equip_weapon 首空槽口径，满员不上架）。
	# R196 武器准入门：MechanicGate.weapon_allowed 过滤（大关分批上架——同 trait_allowed
	# / relic_allowed 既有消费范式；无局态全开 = 既有验收基线不受扰）。写口
	# mark_weapon_codex 不设门——只有候选上架才可被抽，门自然收口。
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
		if not MechanicGate.weapon_allowed(StringName(String(wid))):
			continue                        # 武器准入门（R196：越门大关不上架）
		var wd := registry.get_weapon(wid)
		if wd != null:
			out.append(wd)
	return out


func _make_weapon_card(p_wdata: WeaponData) -> Dictionary:
	# 新武器卡：应用 = Player.equip_weapon（首空槽装配 + 词条随武器重建）
	# R243：form 3 时类别文案接 WEAPON_CLASS_NAMES 单源（法器/近战——display_name 已带
	# 类别前缀，卡面描述与之一致；其余形态沿用四形态文案）
	var wname := p_wdata.display_name if p_wdata != null else "?"
	var form_txt: String = "?"
	if p_wdata != null:
		if int(p_wdata.form) == GameConst.WeaponForm.MELEE:
			var seg: Variant = p_wdata.get("melee")
			var wcls := String((seg as Dictionary).get("weapon_class", "melee")) \
				if seg is Dictionary else "melee"
			form_txt = String(GameConst.WEAPON_CLASS_NAMES.get(wcls, "近战"))
		else:
			var form_names := ["弹道", "激光", "自导", "近战"]
			form_txt = form_names[clampi(int(p_wdata.form), 0, 3)]
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
	# 未获得遗物（unique 每场唯一）+ 大关门（常规遗物第 2 关起 / 赌徒诅咒终关）
	var out: Array[StringName] = []
	if registry == null:
		return out
	for rid in registry.relics:
		if not owned_relics.has(rid) and MechanicGate.relic_allowed(rid):
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
	# → 卡面标注「质变」，描述补「全部层数 ×1.6」（质变实装在 WeaponBase.attach_trait；
	#   大关门：满层质变第 4 关解锁——未解锁期不上架预告）
	# R226 有意契约变更：R196 超帽态预览（≥stack_max 追 OVERCAP_NOTE「收益降低 30%」）
	# 随超帽衰减一并退役——满层后继续叠全额，无注记（overcap 字段保留恒 false，卡面
	# 消费端零改动）
	# R262e 需求①：已满层徽标（用户「如果 buff 满了，出现的 buff 左上角加个提示」）——
	# 判定=目标武器栈该词条层数已达 stack_max（质变里程碑点已过）。cur 计算对全池
	#（MEC_SHIELD stack_max=2 等 MECH 池同样有「满了」语义）；R226 起超帽层仍全额，
	# 徽标是「里程碑已达」信息位非「白加」警告。
	var cur := 0
	if t != null and p_target != null and is_instance_valid(p_target):
		var tstack: Variant = p_target.get("trait_stack")
		if tstack != null and tstack.get("traits") != null:
			for tb: Variant in (tstack.get("traits") as Array):
				var td: Variant = tb.get("data")
				if td != null and StringName(str(td.get("id"))) == p_tid:
					cur = int(tb.get("layers"))
	var milestone := false
	var overcap := false
	if t != null and t.pool == GameConst.PoolClass.ADD:
		# R226 评审 L2：预告语义收紧——只有「本卡恰触发质变」（cur+1==stack_max）才预告；
		# 已质变态（cur≥stack_max）后续卡不再重复承诺 ×1.6
		if MechanicGate.milestone_unlocked() and t.stack_max >= 2:
			milestone = cur + 1 == t.stack_max
	var maxed := t != null and int(t.stack_max) >= 2 and cur >= int(t.stack_max)
	# 前缀体系（R10 整理）：玩家侧池（生命/经验/磁吸/技能急速）=【通用】——效果全局生效，
	# 不再误导性地挂武器名；武器侧词条 =【武器名】（绑定目标武器）
	var prefix := "【通用】" if t != null and (t.pool_id in GameConst.PLAYER_SIDE_POOLS) 		else (("【%s】" % _weapon_short_name(p_target)) if p_target != null else "")
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
		"overcap": overcap,
		"maxed": maxed,                           # R262e ①：已满层徽标（选卡窗左上角提示）
	}
	if milestone:
		var note := TRAIT_MILESTONE_NOTE
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


func _make_slot_bonus_card() -> Dictionary:
	# R88 金色扩容卡 → R185 语义修正：提前解锁帽内下一槽（总位数=难度帽不变）
	return {
		"kind": CardKind.SLOT_BONUS,
		"id": &"SLOT_BONUS",
		"rarity": 3,
		"value_scale": 1.0,
		"display_name": "武器槽 +1",
		"description": "提前解锁下一个武器槽（本局有效；总槽位数不变，只是提前开锁）",
		"milestone": false,
	}


# ── R246 红色传说「技能升华」卡（设计真源 docs/design/sublime/_card_system.md §2/§3）──
func _make_sublime_card(p_player: Node) -> Dictionary:
	# 单卡通用（D5）：文案真源 = CharacterTable 当前角色条目 sublime_* 键（meta 泳道落表、
	# 角色设计师填值；本函数只读表拼接——卡系统不持有任何角色升华数值）。
	# data:null + value_scale:1.0：不走词条链（不挂栈/不写共享 .tres——E-08 天然不破；
	# compose_desc_text :500 守卫 value_scale>1 → 无品质加成尾行）；milestone 恒 false
	#（永不触发金名质变预告——红名独占，设计 §1.5）。
	var cid_v: Variant = p_player.get("character_id") if p_player != null else null
	var cid := StringName(String(cid_v)) if cid_v != null else &"sentinel"
	var ch := CharacterTable.get_character(cid)
	return _build_sublime_card(String(ch.get("sublime_name", "")),
		String(ch.get("sublime_desc", "")))


func _build_sublime_card(p_sname: String, p_sdesc: String) -> Dictionary:
	# 升华卡纯数据拼装（零 rng——预热变体与本卡同源单源，防两处格式串漂移）。
	# 描述尾句「爆率 0.001%（红色传说）」= 任务要求的概率卡面显示（全仓此前无品级
	# 概率文案挂点，这是新挂点，设计 §5.2）
	return {
		"kind": CardKind.SUBLIME,
		"id": &"SUBLIME_SKILL",
		"rarity": 4,
		"value_scale": 1.0,
		"data": null,
		"display_name": "技能升华" + ("：%s" % p_sname if p_sname != "" else ""),
		"description": (p_sdesc + "\n" if p_sdesc != "" else "")
			+ "本局技能升级为升华版 · 爆率 0.001%（红色传说）",
		"milestone": false,
		"overcap": false,
	}


func _sublime_available(p_player: Node) -> bool:
	# R246 升华可用性（设计 §3 D7 两态收敛）→ R247 终修判据收紧：
	# 唯一判据 = 表 sublime_desc 非空（meta 泳道落表的角色设计师升华/替代升华文案）。
	# 旧判据「has_skill 恒放行」对升华版未设计的新角色（R247 medic/vortex/reaper
	# 有技能无 sublime 键）会掷出「空文案 + 零行为」破洞卡——player.activate_skill
	# 三分支无 skill_sublime 变体、enable_sublime 仅置位，抽中最贵卡零兑现，与
	# :920 区「杜绝什么都不发生的破洞卡」自相矛盾（QA/评审双报，P0 收口）。
	# 收紧后与 fission 判据统一：表有键（含 fission 替代升华）→ 掷；表无键 → 不掷。
	if p_player == null:
		return false
	var cid_v: Variant = p_player.get("character_id")
	var cid := StringName(String(cid_v)) if cid_v != null else &"sentinel"
	return String(CharacterTable.get_character(cid).get("sublime_desc", "")) != ""


func _make_relic_card(p_rid: StringName, p_wave: int) -> Dictionary:
	var r := registry.get_relic(p_rid)
	# 品质下限单源 RelicData.rarity（.tres 声明档，全遗物=3 金）——纯按波 roll 会掷出
	# 假紫：RELIC 无 _apply_rarity_values 分支，紫 roll 与金 roll 卡面逐字节同貌，
	# 超频核心紫/金读作一样（二cv#7 根因）。maxi 保底语义=「遗物品质不低于 .tres
	# 声明档」（未来降档遗物仍可保留高档 roll）。保留 _roll_rarity 调用（maxi 左操作
	# 数）：该 rng 消费是选卡确定性流（seed=42 定种回归锁）的流锚，去掉一次消费会让
	# 后续类别 roll 序列整体位移。数值不缩放：遗物=全局规则一次性件（unique），
	# RARITY_VALUE_SCALE 不适用。
	var tres_rarity := clampi(int(r.rarity), 0, 4) if r != null else 3
	return {
		"kind": CardKind.RELIC,
		"id": p_rid,
		"rarity": maxi(_roll_rarity(p_wave), tres_rarity),
		"data": r,
		"display_name": r.display_name if r != null else String(p_rid),
		"description": r.description if r != null else "",
	}


func _grant_fallback(p_player, p_rarity: int, p_source_name: String,
		p_from_overflow: bool) -> void:
	# R262d 应急强化统一授予口（三产口收束：FALLBACK 卡直选/黑市常青货走 p_from_overflow=
	# false，词条栏满转化走 true）。数值=白 5% 基准 × RARITY_VALUE_SCALE[p_rarity]（转化
	# 传被转词条品级）；通道=player.add_fallback_atk 全武器累计。转化横幅带品级与数值
	#（R238「选了没生效」横幅家族——文案随品级区分同步升级）。
	if p_player == null or not is_instance_valid(p_player) \
			or not p_player.has_method(&"add_fallback_atk"):
		DebugStats.count(&"fallback_grant_skipped")
		return
	var card := _fallback_stat_card(p_rarity)
	var data: TraitData = card.get("data")
	if data == null:
		return
	p_player.call(&"add_fallback_atk", float(data.value))
	if p_from_overflow:
		var tier_txt := "" if p_rarity <= 0 else "·%s" % ["蓝", "紫", "金"][clampi(p_rarity, 1, 3) - 1]
		EventBus.mechanics_intro.emit("词条栏已满：%s 转为应急强化%s（全武器 +%.1f%% 攻击）" \
			% [p_source_name, tier_txt, float(data.value) * 100.0])


func _fallback_stat_card(p_rarity: int = 0) -> Dictionary:
	# 卡池耗尽 → "+5% 攻击"类属性卡（AC-16.4，界面永不空）。
	# 运行期构造 TraitData（内存对象，非 .tres 加载——E-08 纪律不破）。
	# R262d 品级区分（用户裁定「不同品级 buff 数值应该不一致」）：value 按
	# RARITY_VALUE_SCALE 缩放（白 5%/蓝 7%/紫 9.5%/金 13%），转化产口传被转词条
	# 品级，卡池耗尽/黑市常青货保底口径传 0（白）。生效通道=player.add_fallback_atk
	# 全武器累计（不再挂单武器栈）；每层全额（R226 起全池无衰减——decay_delta=0.85
	# 为遗留记账键，管线 layer=1 恒全额，R262 交付解释「逐层衰减」口径已修正）。
	var rarity := clampi(p_rarity, 0, RARITY_VALUE_SCALE.size() - 1)
	var val := FALLBACK_ATK_PCT * float(RARITY_VALUE_SCALE[rarity])
	var data := TraitData.new()
	data.id = &"FALLBACK_ATK"
	data.display_name = "应急强化"
	data.description = "全武器攻击力 +%.1f%%" % (val * 100.0)
	data.pool = GameConst.PoolClass.ADD
	data.pool_id = &"add_atk"
	data.effect_id = &"EF_STAT"
	data.value = val
	data.rarity = rarity
	data.decay_delta = 0.85
	data.params = {"stat": "atk_pct"}
	data.stack_max = 99
	var suffix := "" if rarity == 0 else "·%s" % ["蓝", "紫", "金"][rarity - 1]
	return {
		"kind": CardKind.FALLBACK,
		"id": &"FALLBACK_ATK",
		"rarity": rarity,
		"data": data,
		"display_name": "应急强化%s（全武器 +%.1f%% 攻击）" % [suffix, val * 100.0],
		"description": "卡池候选耗尽的保底属性卡（全武器生效）",
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

# 满层质变尾注（_make_trait_card 与 R220 刀2 变体源口共用单源——防两处格式串漂移
# 导致预热键与实拼文本错位；提取自 _make_trait_card 内联串，逐字节等价）
const TRAIT_MILESTONE_NOTE := "\n◆ 满层质变：该词条全部层数数值 ×1.6！"


# ── R220 刀2（D2）：卡面描述变体源口（菜单期预热器数据源） ──────────
# 契约 2026-10-03-R220 §1-D2：为 card_desc_prewarm.gd 枚举全卡面描述变体——
# ① TRAIT：_scaled_description ×4 稀有度数值重写（含 _rarity_desc_mech 特例与
#   PLAYER_HP_BELOW 条件文案重写——全部经 _apply_rarity_values 真路径生成）×
#   {plain, milestone 尾注, overcap 尾注, 双尾注} 态（尾注追加条件镜像 _make_trait_card
#   :739-780 纯数据条件；MechanicGate 门是局内动态，按超集生成无害）；
# ② MASTERY：等级文案（描述与武器名无关——等级只进 display_name 不进量测文本；
#   按等级域生成 = 任意「当前持有武器等级 ±3 近窗」的超集——R245 boosts 最高 +3，
#   相邻两窗武器等级最大跳变 3）× 4 稀有度（金档被 _apply_rarity_values MASTERY 分支
#   钳落、boosts 1/2/3 三态全走真路径）；
# ③ WEAPON（4 形态文案，_make_weapon_card 直调——该函数零 rng）/ RELIC（RelicData
#   原文）/ FALLBACK / SLOT_BONUS（后两者固定文案卡，_make_* 零 rng 直调）。
# 纪律：本函数零 rng 消费（_make_trait_card/_make_relic_card/_make_mastery_card 的
# roll 路径不进本口——防扰动卡流确定性）；_scaled_description 本体零改动（契约冻结）。
# 返回 [{desc: String, value_scale: float}]（去重）——desc=卡 dict "description" 键
# 变体全文，value_scale=_apply_rarity_values 落卡值（>1 时 UI 侧拼品质尾行——尾行/
# ⇄/宽档/行距叉乘归预热器，经 CardSelectUI.compose_desc_text 单源拼接）。
func enumerate_prewarm_variants(p_mastery_levels: Array = []) -> Array[Dictionary]:
	if registry == null:
		return []
	var out: Array[Dictionary] = []
	var seen := {}
	# ① TRAIT：全注册表 × 尾注态 × 4 稀有度
	for tid in registry.traits:
		var t: TraitData = registry.get_trait(tid)
		if t == null or bool(t.params.get(THRESHOLD_ONLY_KEY, false)):
			continue                             # TH_* 永不上卡架（R187 阈值型词条）
		var is_add: bool = t.pool == GameConst.PoolClass.ADD
		# 变体组合=[milestone]；R226 超帽注记退役（OVERCAP_NOTE 删除）——原超帽两变体拆除
		#（R220 刀2 变体键空间随之收窄）
		var combos: Array = [[false]]
		if is_add:
			combos.append([true])
		for combo in combos:
			for r in range(RARITY_VALUE_SCALE.size()):
				var data: TraitData = t.duplicate() as TraitData
				if data == null:
					continue
				var base_desc := t.description
				if combo[0]:
					base_desc += TRAIT_MILESTONE_NOTE
				data.description = base_desc
				var batch: Array[Dictionary] = [
					{"kind": CardKind.TRAIT, "rarity": r, "value_scale": 1.0, "data": data},
				]
				_apply_rarity_values(batch)
				_emit_prewarm_variant(out, seen, String(batch[0].get("description", "")),
					float(batch[0].get("value_scale", 1.0)))
	# ② MASTERY：等级域 × 4 稀有度（假武器走 _apply_rarity_values MASTERY 分支真路径；
	# 描述只含 boosts 数与品质名——与武器名/等级无关，去重后仅数种文本）
	var levels: Array = p_mastery_levels
	if levels.is_empty():
		for lv in range(1, WeaponBase.MAX_LEVEL + 1):
			levels.append(lv)
	var wdata_probe: WeaponData = null
	for wid in registry.weapons:
		wdata_probe = registry.get_weapon(wid)
		if wdata_probe != null:
			break
	if wdata_probe != null:
		var fake := WeaponBase.new()             # 不入树（仅读 level/data 两字段）
		fake.data = wdata_probe
		for lv in levels:
			fake.level = clampi(int(lv), 1, WeaponBase.MAX_LEVEL)
			for r in range(RARITY_VALUE_SCALE.size()):
				var mbatch: Array[Dictionary] = [
					{"kind": CardKind.MASTERY, "rarity": r, "weapon": fake},
				]
				_apply_rarity_values(mbatch)
				_emit_prewarm_variant(out, seen, String(mbatch[0].get("description", "")),
					float(mbatch[0].get("value_scale", 1.0)))
		fake.free()
	# ③ WEAPON / RELIC / FALLBACK / SLOT_BONUS 固定文案卡
	for wid in registry.weapons:
		var wd: WeaponData = registry.get_weapon(wid)
		if wd == null:
			continue
		var wcard := _make_weapon_card(wd)       # 零 rng（rarity 固定 2）
		_emit_prewarm_variant(out, seen, String(wcard.get("description", "")),
			float(wcard.get("value_scale", 1.0)))
	for rid in registry.relics:
		var rd: RelicData = registry.get_relic(rid)
		if rd == null:
			continue
		_emit_prewarm_variant(out, seen, String(rd.description), 1.0)
	var fb := _fallback_stat_card()              # 零 rng
	_emit_prewarm_variant(out, seen, String(fb.get("description", "")), 1.0)
	var sb := _make_slot_bonus_card()            # 零 rng
	_emit_prewarm_variant(out, seen, String(sb.get("description", "")),
		float(sb.get("value_scale", 1.0)))
	# ④ R246 升华卡变体（设计 §4）：表有 sublime_desc 键的角色各 1 条（meta 泳道落表后
	# 自动扩容，至多全角色数）+ 通用兜底 1 条——_build_sublime_card 纯数据拼接零 rng
	#（零 rng 契约保持，T9 断言 rng.state 前后不变）；红卡开窗 miss 至多 1 条/窗可忽略
	for c in CharacterTable.CHARACTERS:
		var sdesc := String(c.get("sublime_desc", ""))
		if sdesc == "":
			continue                              # 表无键角色不产变体（掷侧同口径不上架）
		var scard := _build_sublime_card(String(c.get("sublime_name", "")), sdesc)
		_emit_prewarm_variant(out, seen, String(scard.get("description", "")),
			float(scard.get("value_scale", 1.0)))
	var sb_generic := _build_sublime_card("", "")   # 通用兜底（无表键文案的红卡卡面）
	_emit_prewarm_variant(out, seen, String(sb_generic.get("description", "")), 1.0)
	return out


func _emit_prewarm_variant(p_out: Array[Dictionary], p_seen: Dictionary,
		p_desc: String, p_vs: float) -> void:
	# 变体去重落表（desc+value_scale 联合键；同文本不同 value_scale 是不同卡面——
	# 尾行由 value_scale 决定，必须联合去重防丢尾行变体）
	var key := "%s\u0001%s" % [p_desc, str(p_vs)]
	if p_seen.has(key):
		return
	p_seen[key] = true
	p_out.append({"desc": p_desc, "value_scale": p_vs})


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


func _pick_attach_target(p_t: TraitData, p_player: Node) -> WeaponBase:
	# 挂载侧形态/武器适配门（R18）：在已装备武器中过滤「该词条有消费点」的宿主，
	# 随机取一；全不适配退主武器（现状口径——通用词条不受影响）
	var valid: Array[WeaponBase] = []
	for w in p_player.get("weapon_slots"):
		if w is WeaponBase and is_instance_valid(w) and _form_allows(p_t, w):
			valid.append(w)
	if valid.is_empty():
		return _primary_weapon(p_player)
	return valid[rng.randi_range(0, valid.size() - 1)]


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

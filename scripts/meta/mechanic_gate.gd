# scripts/meta/mechanic_gate.gd
# MechanicGate（2026-09-13 用户反馈「机制太多，包括元素反应……大关卡大关卡地解锁，
# 每关都有新体验」）：战斗机制解锁节奏的单一真源。
#
# 设计原则（对齐 A3 §6 掉卡节奏与 M2 通关链）：
# · 节奏表按大关（MapTable.MAPS 下标）推进，小关（波次）不再塞新机制——每张大关一个
#   「新体验主题」，开局 HUD 横幅宣告（EventBus.mechanics_intro），选关面板同步展示。
# · 第 1 关纯射击 + 基础构筑（强化/乘区/机械词条 + 精通 + 新武器 + 换一批）；
#   元素状态第 2 关入门（火/冰；双元素齐备时碎裂反应自然初见——预告不压教学）；
#   感电 + 过载/超导第 3 关（紫晶魔域「爆发关」主题呼应）；满层质变第 4 关（构筑
#   深化期才触发得起来）；诅咒博弈第 5 关（终关高风险玩法）。
# · 门只设在「来源侧」（卡池上架 + 质变挂载），不动 ElementalSystem 结算核——
#   反应可发生性由元素附着可得性自然涌现（第 1 关无元素卡 → 无状态无反应）。
# · 查询口径：无局态（菜单/测试，Meta.run_map_id 未注入）一律全开——既有行为与
#   293+731 验收基线不受门控影响；进局（start_run/continue_run 已 set_run_map）才收口。
class_name MechanicGate
extends RefCounted

# 各大关「新解锁」文案（下标 = MapTable.MAPS 下标；空串 = 该关无新机制行）。
# 真源注释块：数值/解锁位调整只改这里 + _unlock_flags，两处保持同步。
const MAP_INTROS: Array[String] = [
	"起点：词条构筑 · 武器精通 · 新武器 · 换一批",
	"元素一期：火 / 冰元素卡（点燃 · 寒滞 · 碎裂初见）｜遗物卡",
	"感电卡｜新反应：过载 · 超导",
	"满层质变：词条满层数值 ×1.6",
	"诅咒博弈：赌徒硬币（第 4 张卡必带诅咒）",
]


static func map_index() -> int:
	# 当前局大关下标；无局（菜单/测试）→ -1 = 门控全开口径
	var mid := Meta.run_map_id()
	return MapTable.get_map_index(mid) if mid != StringName("") else -1


# ── 机制门（进局收口，无局全开） ─────────────────────────────────
static func elements_basic_unlocked() -> bool:
	# 火 / 冰元素卡（点燃 / 寒滞）——第 2 关「寒霜冰原」起
	var idx := map_index()
	return idx < 0 or idx >= 1


static func shock_unlocked() -> bool:
	# 感电卡——第 3 关「紫晶魔域」起（过载 / 超导随雷元素补齐而自然可发生）
	var idx := map_index()
	return idx < 0 or idx >= 2


static func relics_unlocked() -> bool:
	# 遗物卡类目——第 2 关起
	var idx := map_index()
	return idx < 0 or idx >= 1


static func milestone_unlocked() -> bool:
	# 满层质变（×1.6）——第 4 关「翡翠树海」起
	var idx := map_index()
	return idx < 0 or idx >= 3


static func curse_relic_unlocked() -> bool:
	# 赌徒硬币（诅咒卡）——第 5 关「翠毒沼泽」起
	var idx := map_index()
	return idx < 0 or idx >= 4


# ── 消费侧辅助 ───────────────────────────────────────────────────
static func trait_allowed(p_trait: TraitData) -> bool:
	# ELEM 池细粒度过滤：火/冰 第 2 关、雷 第 3 关；无 element 键 = 反应家族词条
	# （ELE_REACTION_VOID 反应强化）→ 随反应体系第 3 关开放。
	# MULT 池元素条件乘区（SYN_BURN_DEVOUR 点燃 / SYN_FROST_EXEC 寒滞冻结 / 感电条件）
	# 随对应元素同关开放——无元素的第 1 关不上架死卡；其余池不设门。
	if p_trait == null:
		return true
	if p_trait.pool == GameConst.PoolClass.ELEM:
		match int(p_trait.params.get("element", GameConst.Element.KIN)):
			GameConst.Element.FIR, GameConst.Element.ICE:
				return elements_basic_unlocked()
			GameConst.Element.LTG:
				return shock_unlocked()
		return shock_unlocked()
	if p_trait.pool == GameConst.PoolClass.MULT:
		match int(p_trait.condition.get("condition_id", GameConst.ConditionId.NONE)):
			GameConst.ConditionId.TARGET_FROZEN, GameConst.ConditionId.TARGET_BURNING:
				return elements_basic_unlocked()
			GameConst.ConditionId.TARGET_SHOCKED:
				return shock_unlocked()
	return true


static func relic_allowed(p_relic_id: StringName) -> bool:
	# 遗物按 ID 细粒度过滤：赌徒硬币（诅咒源）仅终关上架，其余随 RELIC 类目同关开放
	if p_relic_id == &"REL_GAMBLER":
		return curse_relic_unlocked()
	return relics_unlocked()


static func intro_for_map(p_index: int) -> String:
	# 某大关的新机制文案（选关面板行 + 开局横幅共用；越界/第 1 关起有值）
	if p_index < 0 or p_index >= MAP_INTROS.size():
		return ""
	return MAP_INTROS[p_index]

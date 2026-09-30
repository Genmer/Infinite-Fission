# scripts/loop/auto_idle_strategy.gd
# R188-3 挂机自动选择策略（idle 独占）：static 纯函数——零实例状态 / 零副作用 / 零 RNG。
# 消费方：GameLoop._tick_auto_idle（选卡 0.5s 展示窗到期）调用 pick(candidates, is_dual)
# 得到 choose(槽位) 入参：普通模式 = 卡 index（0~3）；成对模式 = 行左槽 4+row*2
#（card_select_ui.choose 成对协议：点任一张带走同行两张）。
# 评分：rarity × value_scale +（milestone ? +2 : 0）−（cursed ? 999 : 0）；
# 成对模式按行两卡合计评分；同分取低 index（严格大于比较——遍历序即平局裁决）。
# ★ 硬不变量：永不输出诅咒卡/行。
#   诅咒载荷（GAMBLER_CURSE，card_generator._make_curse_trait）恒挂第 4 张
#   （generate_candidates 侧 curse_last → out[3]["cursed"]=true）：
#   · 普通模式 deal ≥ 3 → 恒有安全卡（out[0..2]）；
#   · 成对模式 6 卡行 = [0,1][2,3][4,5] → 诅咒恒在第 1 行，恒有 2 条全安全行。
#   诅咒项得分 ≤ −999 + 非负加成 < 0 ≤ 任一安全项得分，argmax 天然避开；
#   本函数仍显式跳过含诅咒项兜底（契约防线，非平衡语义）——任何实现改动都不得让
#   pick 的返回值指向 cursed 卡或含 cursed 卡的行。
class_name AutoIdleStrategy
extends RefCounted

const MILESTONE_BONUS := 2.0                  # 满层质变卡加成（「到什么程度会质变」优先）
const CURSE_PENALTY := 999.0                  # 诅咒罚分（压过一切非诅咒项可能得分）
const DUAL_SLOT_BASE := 4                     # 成对模式槽位基址（card_select_ui 槽 4~9 协议）


static func score(p_card: Dictionary) -> float:
	# 单卡评分（纯函数；缺省字段按中性值回退——value_scale 缺省 1.0 / rarity 缺省 0）
	var value := float(clampi(int(p_card.get("rarity", 0)), 0, 3)) \
		* maxf(float(p_card.get("value_scale", 1.0)), 0.0)
	if bool(p_card.get("milestone", false)):
		value += MILESTONE_BONUS
	if bool(p_card.get("cursed", false)):
		value -= CURSE_PENALTY
	return value


static func pick(p_candidates: Array[Dictionary], p_is_dual: bool) -> int:
	# 主入口：普通返回卡 index（0~size-1）；成对返回行左槽 4+row*2（choose 协议直通）。
	# 空货架防御返回 -1（GameLoop 侧 is_open/候选守卫下正常不出现）。
	if p_candidates.is_empty():
		return -1
	if p_is_dual:
		return _pick_dual(p_candidates)
	return _pick_single(p_candidates)


static func _pick_single(p_candidates: Array[Dictionary]) -> int:
	# 普通模式：逐卡 argmax（严格大于 → 同分取低 index）；诅咒卡直接跳过（硬不变量）；
	# 全诅咒属契约外态，兜底返回 0（调用方货架协议保证至少 3 张安全卡）
	var best := -1
	var best_score := -INF
	for i in range(p_candidates.size()):
		if bool(p_candidates[i].get("cursed", false)):
			continue                              # ★ 永不选诅咒
		var s := score(p_candidates[i])
		if s > best_score:
			best_score = s
			best = i
	return best if best >= 0 else 0


static func _pick_dual(p_candidates: Array[Dictionary]) -> int:
	# 成对模式：按行合计评分（带走同行两张——行内含诅咒即整行弃选，双卡同罚）；
	# 同分行取低 row；返回行左槽 4+row*2；全行含诅咒属契约外态，兜底返回 4
	var rows := ceili(float(p_candidates.size()) / 2.0)
	var best_row := -1
	var best_score := -INF
	for r in range(rows):
		var row_score := 0.0
		var row_cursed := false
		for k in range(2):
			var idx := r * 2 + k
			if idx >= p_candidates.size():
				break
			if bool(p_candidates[idx].get("cursed", false)):
				row_cursed = true                 # ★ 含诅咒行永不输出
				break
			row_score += score(p_candidates[idx])
		if row_cursed:
			continue
		if row_score > best_score:
			best_score = row_score
			best_row = r
	if best_row < 0:
		return DUAL_SLOT_BASE
	return DUAL_SLOT_BASE + best_row * 2

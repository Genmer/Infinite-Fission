# scripts/combat/trait/synergy_rules.gd
# M-10 附庸：SynergyRule 条件乘区求值器（架构 §三.5 / B_spec §2.2 hit_flags 驱动）。
# 六条独立乘区词条（A3 §4.3）的条件在来源侧求值（§4.4 ②——contrib 注入
# DamageContext.mult_pools 前完成），实现为 ConditionId 绑定的内置求值函数
# switch 分发（白名单模板：value / value × (ctx.pierce_index − 1)；禁运行时 Expression）。
class_name SynergyRules
extends RefCounted


static func evaluate(p_trait: TraitBase, p_ctx: TraitContext) -> float:
	# 条件自评 → 乘区贡献（条件不满足 → 0 = 不注入该区）
	if p_trait.data == null:
		return 0.0
	var condition: Dictionary = p_trait.data.condition
	var condition_id := int(condition.get("condition_id", GameConst.ConditionId.NONE))
	var params: Dictionary = condition.get("params", {})
	if not condition_met(condition_id, params, p_ctx):
		return 0.0
	return contribution(condition_id, p_trait.data.value, p_ctx)


static func condition_met(p_condition_id: int, p_params: Dictionary, p_ctx: TraitContext) -> bool:
	# 条件判定（输入：DamageContext 快照 hit_flags/pierce_index/player_hp_pct + 目标元素状态）
	match p_condition_id:
		GameConst.ConditionId.TARGET_FROZEN:
			return _target_state_active(p_ctx, GameConst.Element.ICE)
		GameConst.ConditionId.TARGET_BURNING:
			return _target_state_active(p_ctx, GameConst.Element.FIR)
		GameConst.ConditionId.TARGET_SHOCKED:
			return _target_state_active(p_ctx, GameConst.Element.LTG)
		GameConst.ConditionId.AFTER_BOUNCE:
			if p_ctx.damage_ctx != null:
				return (p_ctx.damage_ctx.hit_flags & GameConst.HIT_IS_BOUNCE) != 0
			return false
		GameConst.ConditionId.PIERCE_INDEX_GE:
			if p_ctx.damage_ctx == null:
				return false
			return p_ctx.damage_ctx.pierce_index >= int(p_params.get("min", 2))
		GameConst.ConditionId.PLAYER_HP_BELOW:
			if p_ctx.damage_ctx == null:
				return false
			return p_ctx.damage_ctx.player_hp_pct < float(p_params.get("pct", 0.35))
		GameConst.ConditionId.WAVE_FIRST_HIT:
			if p_ctx.damage_ctx != null:
				return p_ctx.damage_ctx.is_first_hit_of_wave
			return false
		GameConst.ConditionId.TARGET_TAG_IN:
			if p_ctx.target == null:
				return false
			var mask := int(p_params.get("tags", 0))
			return (int(p_ctx.target.get("tags")) & mask) != 0
		GameConst.ConditionId.NONE:
			return true                       # 无条件常驻乘区
	return false


static func contribution(p_condition_id: int, p_value: float, p_ctx: TraitContext) -> float:
	# 贡献公式（§三.5 白名单模板的编译期映射）
	if p_condition_id == GameConst.ConditionId.PIERCE_INDEX_GE and p_ctx.damage_ctx != null:
		# "value * (ctx.pierce_index - 1)"：每穿透一层 +value（区内累进）
		return p_value * float(maxi(p_ctx.damage_ctx.pierce_index - 1, 0))
	return p_value


static func _target_state_active(p_ctx: TraitContext, p_element: int) -> bool:
	# 目标元素状态自评（SYN_FROST_EXEC 对寒滞/冻结、SYN_BURN_DEVOUR 对点燃）
	if p_ctx.target == null:
		return false
	var state: Variant = p_ctx.target.get("elemental")
	if state is ElementalState:
		return (state as ElementalState).is_state_active(p_element)
	return false

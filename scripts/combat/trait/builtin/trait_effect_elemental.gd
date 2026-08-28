# scripts/combat/trait/builtin/trait_effect_elemental.gd
# 元素附着家族（EF_ELEMENTAL）：attach_request 输出（引擎在结算后提交 ElementalSystem，
# §4.4 ⑤ 时序——快照取当跳结算结果）。
# · ELE_IGNITE/ELE_FREEZE/ELE_SHOCK（ELEM 池）：ON_SPAWN 投射物元素标记（抗性/视觉通道），
#   ON_HIT 附着请求 {element, value, overrides}；层 2 递进经 params.lv2 键声明
#   （A3 §4.5：点燃 DOT→22% / 冰冻附着→30 / 感电传导→4 目标）。
# · ELE_REACTION_VOID：常驻词条（hooks 空）——反应强化经 WeaponBase.attach_trait 注册到
#   ElementalSystem.register_reaction_mult（全局 ×1.8）。
# · SYN_FROST_EXEC / SYN_BURN_DEVOUR（MULT 池）不经事件派发：条件自评走 SynergyRules。
extends TraitEffect


func handle(p_trait: TraitBase, p_ctx: TraitContext) -> void:
	if p_trait.data == null or p_trait.data.pool != GameConst.PoolClass.ELEM:
		return
	match p_ctx.event:
		GameConst.TraitEvent.ON_SPAWN:
			if p_ctx.projectile != null:
				p_ctx.projectile.element = int(p_trait.data.params.get("element",
					GameConst.Element.KIN))
		GameConst.TraitEvent.ON_HIT:
			_emit_attach_request(p_trait, p_ctx)


func _emit_attach_request(p_trait: TraitBase, p_ctx: TraitContext) -> void:
	# 附着请求输出（引擎在管线结算后统一提交：快照/本次伤害取结算结果，§4.4 ⑤）
	var element := int(p_trait.data.params.get("element", GameConst.Element.KIN))
	var value := p_trait.data.value
	var overrides: Dictionary = {}
	if p_trait.layers >= 2:
		value = float(p_trait.data.params.get("value_lv2", value))
		for key in ["dot_ratio", "chain_targets"]:
			if p_trait.data.params.has(String(key) + "_lv2"):
				overrides[key] = float(p_trait.data.params[String(key) + "_lv2"])
	p_ctx.attach_request = {"element": element, "value": value, "overrides": overrides}

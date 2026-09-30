# scripts/combat/trait/builtin/trait_effect_elemental.gd
# 元素附着家族（EF_ELEMENTAL）：attach_request 输出（引擎在结算后提交 ElementalSystem，
# §4.4 ⑤ 时序——快照取当跳结算结果）。
# · ELE_IGNITE/ELE_FREEZE/ELE_SHOCK（ELEM 池）：ON_SPAWN 投射物元素标记（抗性/视觉通道），
#   ON_HIT 附着请求 {element, value, overrides}；层 2 递进经 params.lv2 键声明
#   （A3 §4.5：点燃 DOT→22% / 冰冻附着→30 / 感电传导→4 目标）。
#   R191 双守卫（用户反馈「选了火和电没反应」——同武器双 ELE 卡时挂载序末位覆写
#   spawn 随机元素/attach_request，第二元素永远附不上→反应结构性不可达）：
#   ON_SPAWN 仅中性弹写元素（spawn 参数已由 WeaponBase._shot_element 每发随机取一，
#   R26「多元素共存→每发随机取一」第三腿补齐）；ON_HIT 按当发宿主元素放行匹配词条
#   （宿主交替→双槽交替→反应可达）。单元素栈输出逐字节不变。
# · ELE_REACTION_VOID：常驻词条（hooks 空）——反应强化经 WeaponBase.attach_trait 注册到
#   ElementalSystem.register_reaction_mult（全局 ×1.8）。
# · SYN_FROST_EXEC / SYN_BURN_DEVOUR（MULT 池）不经事件派发：条件自评走 SynergyRules。
extends TraitEffect


func handle(p_trait: TraitBase, p_ctx: TraitContext) -> void:
	if p_trait.data == null or p_trait.data.pool != GameConst.PoolClass.ELEM:
		return
	match p_ctx.event:
		GameConst.TraitEvent.ON_SPAWN:
			# R191 宿主守卫：仅中性弹写元素——非中性弹的元素已是当发随机结果
			# （_shot_element），再整写即覆写为挂载序末位；KIN 宿主 = 无附魔弹
			# （直挂/兼容通道）→ 附魔染色照旧写入。
			if p_ctx.projectile != null \
					and int(p_ctx.projectile.element) == GameConst.Element.KIN:
				p_ctx.projectile.element = int(p_trait.data.params.get("element",
					GameConst.Element.KIN))
		GameConst.TraitEvent.ON_HIT:
			_emit_attach_request(p_trait, p_ctx)


func _emit_attach_request(p_trait: TraitBase, p_ctx: TraitContext) -> void:
	# 附着请求输出（引擎在管线结算后统一提交：快照/本次伤害取结算结果，§4.4 ⑤）
	var element := int(p_trait.data.params.get("element", GameConst.Element.KIN))
	# R191 宿主元素守卫：attach_request 单槽字典，同栈后位词条整写会吃掉前位输出——
	# 按当发宿主元素只放行匹配词条；host_el 取投射物→光束→KIN（六事件宿主按形态其一，
	# TraitContext 契约）。KIN 宿主 = 无宿主元素约束 → 全放行（W8 零消费点通道不变）。
	var host_el := GameConst.Element.KIN
	if p_ctx.projectile != null:
		host_el = int(p_ctx.projectile.element)
	elif p_ctx.beam != null:
		host_el = int(p_ctx.beam.element)
	if host_el != GameConst.Element.KIN and host_el != element:
		return
	var value := p_trait.data.value
	var overrides: Dictionary = {}
	if p_trait.layers >= 2:
		# 层 2 质变覆写键（2026-08-31）：dot_ratio（DOT 15→22%）/ chain_targets（3→4）/
		# chain_decay（连锁衰减 0.6→0.75，跳得更远）/ spread_radius（点燃蔓延：燃烧者死亡传火）
		# R192 审查④：value_lv2 随品质缩放在产出侧完成（card_generator 品质块对 params
		# 深复制后同乘 scale——本侧无白基准锚可除，MEC_KILL_BLAST 的 params.atk_ratio
		# 锚先例此处不备），运行时直读即终值。
		value = float(p_trait.data.params.get("value_lv2", value))
		for key in ["dot_ratio", "chain_targets", "chain_decay", "spread_radius"]:
			if p_trait.data.params.has(String(key) + "_lv2"):
				overrides[key] = float(p_trait.data.params[String(key) + "_lv2"])
	p_ctx.attach_request = {"element": element, "value": value, "overrides": overrides}

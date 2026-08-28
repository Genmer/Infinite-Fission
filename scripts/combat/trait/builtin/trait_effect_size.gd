# scripts/combat/trait/builtin/trait_effect_size.gd
# 体积极限家族（EF_SIZE）：size_mult 累计 + ≥3.0× 触发 TH_SIZE_NOVA 冲击波质变（A3 §4.4/§3.11）。
# · MEC_SIZE_STACK（MECH 池）：每层 ×(1+value) 连乘（A3 §7.4 构筑 D 口径：1.18^layers）。
# · AFF_AREA（ADD/add_size 池）：线性加算 ×(1 + value×layers)（§7.4：AFF_AREA ×2 → ×1.30）。
# · 碰撞盒/精灵等比（ProjectileBase.effective_radius，AC-08.1 判定/视觉比值恒定）。
extends TraitEffect


func handle(p_trait: TraitBase, p_ctx: TraitContext) -> void:
	if p_trait.data == null:
		return
	match p_ctx.event:
		GameConst.TraitEvent.ON_SPAWN:
			_apply_size_mult(p_trait, p_ctx)
		GameConst.TraitEvent.ON_HIT:
			_maybe_nova(p_trait, p_ctx)


func _apply_size_mult(p_trait: TraitBase, p_ctx: TraitContext) -> void:
	# ON_SPAWN：体积累计（子弹/光束/近战通用；仅投射物有 size_mult 通道）
	if p_ctx.projectile == null:
		return
	if p_trait.data.pool == GameConst.PoolClass.MECH:
		# MEC_SIZE_STACK：每层连乘（1.18^n）
		p_ctx.projectile.size_mult *= pow(1.0 + p_trait.data.value, float(p_trait.layers))
	else:
		# AFF_AREA（add_size）：线性加算（1 + Σ层值）
		p_ctx.projectile.size_mult *= 1.0 + p_trait.data.value * float(p_trait.layers)


func _maybe_nova(p_trait: TraitBase, p_ctx: TraitContext) -> void:
	# ON_HIT：总体积 ≥3.0× → TH_SIZE_NOVA 冲击波（半径 1.5×弹体、40% ATK 范围伤害）
	# 宿主武器可能中途被移除（飞行中弹体）——失效引用按无武器处理
	if p_ctx.projectile == null or p_ctx.weapon == null \
			or not is_instance_valid(p_ctx.weapon):
		return
	var threshold: Dictionary = p_ctx.weapon.get_threshold(&"TH_SIZE_NOVA")
	if threshold.is_empty():
		return
	if p_ctx.projectile.size_mult < float(threshold.get("threshold", 3.0)):
		return
	var params: Dictionary = threshold.get("params", {})
	var radius := p_ctx.projectile.effective_radius() * float(params.get("radius_mult", 1.5))
	var atk: float = p_ctx.projectile.panel_snapshot.get("base_atk", 0.0) \
		* float(params.get("atk_ratio", 0.4))
	# 排除直击主目标（冲击波 = 次级结算，不重复结算本跳直击目标）
	var exclude: Node2D = null
	if p_ctx.damage_ctx != null:
		exclude = p_ctx.damage_ctx.target as Node2D
	p_ctx.weapon.settle_aoe(p_ctx.projectile.global_position, radius, float(atk), true, exclude)
	DebugStats.count(&"size_nova_triggered")

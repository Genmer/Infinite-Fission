# scripts/combat/trait/builtin/trait_effect_bounce.gd
# 反弹/折射家族（EF_BOUNCE）：bounces_left 增量 + 增伤乘区注入 SYN_BOUNCE_SPEC。
# · MEC_BOUNCE（MECH 池，ON_SPAWN）：反弹预算 += value × layers（+2/层组）。
# · TH_BOUNCE_ETERNAL（反弹 ≥5 次，A3 §3.11）：弹体永存——range/lifetime → 999，
#   仅反弹预算耗尽后消亡（ON_BOUNCE 期检查）。
# · SYN_BOUNCE_SPEC（MULT 池）不经事件派发：×1.4 贡献在 collect_mult_pools 条件自评
#   （AFTER_BOUNCE → HIT_IS_BOUNCE，B_spec §2.2 hit_flags）。
extends TraitEffect


func handle(p_trait: TraitBase, p_ctx: TraitContext) -> void:
	if p_ctx.projectile == null or p_trait.data == null:
		return
	match p_ctx.event:
		GameConst.TraitEvent.ON_SPAWN:
			if p_trait.data.pool == GameConst.PoolClass.MECH:
				# R60（用户反馈「侦察协议什么颜色都没区别」同族）：整数型词条品质缩放
				# value ×1.4/1.9/2.6 → int() 截断回退白值（蓝 2.8 截回 2）；round 对齐
				# 卡面显示（+2/+3/+4/+5）
				p_ctx.projectile.bounces_left += int(round(p_trait.data.value)) * p_trait.layers
				# R9c（用户裁定）：带反弹预算的子弹【射程无限】——打空的子弹必达屏幕边界
				# 弹回，预算耗尽才在边缘回收（BOUNCE_DEPLETED 兜底）。20s 为绝对上限
				#（2 次反弹的理论飞行时间远低于此），≥5 次仍走 TH_BOUNCE_ETERNAL 永存
				if p_ctx.projectile.bounces_left > 0:
					p_ctx.projectile.lifetime_left = maxf(p_ctx.projectile.lifetime_left, 20.0)
		GameConst.TraitEvent.ON_BOUNCE:
			_maybe_eternal(p_trait, p_ctx)


func _maybe_eternal(p_trait: TraitBase, p_ctx: TraitContext) -> void:
	# TH_BOUNCE_ETERNAL：已反弹 ≥ threshold → range/lifetime → 999（仅反弹耗尽后消亡）
	if p_ctx.weapon == null:
		return
	var threshold: Dictionary = p_ctx.weapon.get_threshold(&"TH_BOUNCE_ETERNAL")
	if threshold.is_empty():
		return
	var done := int(p_ctx.projectile.get("_bounces_done"))
	if done < int(threshold.get("threshold", 5)):
		return
	var params: Dictionary = threshold.get("params", {})
	var eternal := float(params.get("lifetime", 999.0))
	p_ctx.projectile.lifetime_left = maxf(p_ctx.projectile.lifetime_left, eternal)
	if p_ctx.projectile.get("range_left") != null:
		p_ctx.projectile.set("range_left", maxf(float(p_ctx.projectile.get("range_left")), eternal))
	DebugStats.count(&"bounce_eternal_triggered")

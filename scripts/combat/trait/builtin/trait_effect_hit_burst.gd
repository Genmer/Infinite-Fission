# scripts/combat/trait/builtin/trait_effect_hit_burst.gd
# 命中迸裂家族（EF_HIT_BURST，用户反馈 2026-08-29「子弹命中分裂、扩散也可以来」）：
# MEC_HIT_BURST——直击落点向邻近敌人迸裂 value×ATK 的范围伤害 [质变]。
# · 触发时点：ON_HIT（词条随投射物/光束/近战六事件派发进入本处理器）。
# · 结算：落点半径 params.radius 内全体（排除直击主目标），单体走「直接管线 resolve」
#   通道（同 EF_CRIT_SHARD 审查 Fix 4 口径：真件管线步骤 9b 内部 take_result 落血一次）。
# · 层 2：半径 params.radius_lv2 + value × params.ratio_lv2 递进（.tres params 契约键）。
# · 无闸门（与暴击弹片的阈值质变区分）：命中即发，冷却由 hit 频率天然限制。
extends TraitEffect

const BURST_RADIUS_DEFAULT := 80.0           # 迸裂半径缺省 px（.tres params.radius 可覆写）


func handle(p_trait: TraitBase, p_ctx: TraitContext) -> void:
	if p_ctx.event != GameConst.TraitEvent.ON_HIT:
		return
	# 宿主武器可能中途被移除（飞行中弹体）——失效引用按无武器处理
	if p_ctx.weapon == null or not is_instance_valid(p_ctx.weapon) \
			or p_ctx.damage_ctx == null:
		return
	var grid: SpaceGrid = p_ctx.weapon.enemy_grid
	if grid == null:
		return
	var params: Dictionary = p_trait.data.params
	var radius := float(params.get("radius", BURST_RADIUS_DEFAULT))
	var ratio := float(p_trait.data.value)
	if p_trait.layers >= 2:
		radius = float(params.get("radius_lv2", radius))
		ratio *= float(params.get("ratio_lv2", 1.0))
	var pos := p_ctx.damage_ctx.pos
	if p_ctx.projectile != null:
		pos = p_ctx.projectile.global_position
	var exclude: Node2D = p_ctx.damage_ctx.target as Node2D
	var pipeline: RefCounted = p_ctx.weapon.damage_pipeline
	if pipeline == null or not pipeline.has_method(&"resolve"):
		return
	var settled := 0
	for cand in grid.query_circle(pos, radius):
		if cand == null or cand == exclude or bool(cand.get("dead")):
			continue
		var hr: Variant = cand.get("hitbox_r")
		var reach := radius + (float(hr) if hr != null else 0.0)
		if (cand as Node2D).global_position.distance_to(pos) > reach:
			continue
		var ctx := DamageContext.make()
		ctx.source_uid = p_ctx.weapon.uid
		ctx.target = cand
		ctx.target_uid = int(cand.get("uid"))
		ctx.frame_stamp = GameConfig.frame_stamp
		ctx.base_atk = maxf(p_ctx.damage_ctx.base_atk * ratio, 0.0)
		ctx.element = GameConst.Element.KIN
		ctx.hit_flags |= GameConst.HIT_IS_AOE_SECONDARY
		ctx.pos = (cand as Node2D).global_position
		pipeline.call(&"resolve", ctx)        # 步骤 9b 内部落血（见头注释通道说明）
		settled += 1
	if settled > 0:
		DebugStats.count(&"hit_burst_triggered")

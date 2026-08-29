# scripts/combat/trait/builtin/trait_effect_crit_shard.gd
# 暴击弹片家族（EF_CRIT_SHARD，A3 §3.11）：TH_CRIT_SHARD——暴击率 ≥ 60% → 命中弹射
# 0.5× 暴伤的二次弹片 [质变]。
# · 触发时点：ON_HIT（挂载 EF_CRIT_SHARD 的词条随投射物/光束六事件派发进入本处理器）。
# · 闸门读 weapon.get_threshold(&"TH_CRIT_SHARD")：threshold 声明于 WeaponData.
#   threshold_traits（9 武器 .tres 全量声明，params = {"ratio": 0.5}）。
# · 暴击口径说明（主控裁定）：ON_HIT 派发先于管线 ⑦ 暴击掷骰（DamagePipeline.resolve
#   内部才产出 result.is_crit），命中时点可得真源为 DamageContext.crit_chance（暴击率
#   面板快照）——故闸门取「暴击率堆过阈值」口径；pkg5 断言同口径锁定。
# · 弹片值 = ratio × 暴伤（暴伤 = base_atk × crit_mult——暴击命中全额口径，A3「0.5× 暴伤」）。
# · 结算：邻近单体弹射（最近未命中者，确定性；无邻接目标 → 不结算）。走「直接管线 resolve
#   单体」通道（审查 Fix 4 授权选项）：真件管线步骤 9b 内部 take_result 落血一次——
#   不经 settle_aoe（其双轨落血口径与全工程 5 处调用点已于 2026-08-29 统一双轨修复）。
extends TraitEffect

const SHARD_RADIUS := 120.0                   # 弹片邻近索敌半径 px（A3 未给 → 主控裁定占位）


func handle(p_trait: TraitBase, p_ctx: TraitContext) -> void:
	if p_ctx.event != GameConst.TraitEvent.ON_HIT:
		return
	# 宿主武器可能中途被移除（飞行中弹体）——失效引用按无武器处理
	if p_ctx.weapon == null or not is_instance_valid(p_ctx.weapon) \
			or p_ctx.damage_ctx == null:
		return
	var threshold: Dictionary = p_ctx.weapon.get_threshold(&"TH_CRIT_SHARD")
	if threshold.is_empty():
		return
	var crit_rate := p_ctx.damage_ctx.crit_chance
	if crit_rate < float(threshold.get("threshold", 0.6)):
		return                                # 暴击率未堆过阈值 → 质变未激活
	var target := _shard_target(p_ctx)
	if target == null:
		return                                # 半径内无弹射目标 → 弹片不结算（二次弹片语义）
	var params: Dictionary = threshold.get("params", {})
	var ratio := float(params.get("ratio", 0.5))
	# 弹片值 = ratio × 暴伤（base_atk × crit_mult）；次级结算（HIT_IS_AOE_SECONDARY 同构）
	var ctx := DamageContext.make()
	ctx.source_uid = p_ctx.weapon.uid
	ctx.target = target
	ctx.target_uid = int(target.get("uid"))
	ctx.frame_stamp = GameConfig.frame_stamp
	ctx.base_atk = maxf(p_ctx.damage_ctx.base_atk * p_ctx.damage_ctx.crit_mult * ratio, 0.0)
	ctx.element = GameConst.Element.KIN
	ctx.hit_flags |= GameConst.HIT_IS_AOE_SECONDARY
	ctx.pos = (target as Node2D).global_position
	var pipeline: RefCounted = p_ctx.weapon.damage_pipeline
	if pipeline != null and pipeline.has_method(&"resolve"):
		pipeline.call(&"resolve", ctx)        # 步骤 9b 内部落血（见头注释通道说明）
		DebugStats.count(&"crit_shard_triggered")


func _shard_target(p_ctx: TraitContext) -> Node2D:
	# 弹射目标：命中位置 SHARD_RADIUS 内最近存活单体（排除直击主目标——弹射语义；确定性）
	var grid: SpaceGrid = p_ctx.weapon.enemy_grid
	if grid == null:
		return null
	var pos := p_ctx.damage_ctx.pos
	if p_ctx.projectile != null:
		pos = p_ctx.projectile.global_position
	var exclude: Node2D = p_ctx.damage_ctx.target as Node2D
	var best: Node2D = null
	var best_d := INF
	for cand in grid.query_circle(pos, SHARD_RADIUS):
		if cand == null or cand == exclude or bool(cand.get("dead")):
			continue
		var d := pos.distance_squared_to((cand as Node2D).global_position)
		if d < best_d:
			best_d = d
			best = cand
	return best

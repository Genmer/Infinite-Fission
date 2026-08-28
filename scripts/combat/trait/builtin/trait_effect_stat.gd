# scripts/combat/trait/builtin/trait_effect_stat.gd
# 加算属性家族（EF_STAT）：面板段聚合——add_atk 经 panel_snapshot.add_entries 入管线
# 步骤 3（F3 衰减真源）；其余加算池（rof/cdr/crit/critdmg/spd/pierce/pellets/hp/move/pickup）
# 由 WeaponBase.build_panel_snapshot / 参数构造侧聚合（build ctx 时求值）。
# 事件通道无逐发副作用（OnSpawn/OnHit 钩子为声明性——A3 §4.2 触发事件列）。
extends TraitEffect


func handle(p_trait: TraitBase, p_ctx: TraitContext) -> void:
	# 无逐发副作用：聚合在武器面板/参数构造侧（TraitStack.aggregate_panel / aggregate_add_entries）
	pass

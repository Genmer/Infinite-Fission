# scripts/combat/trait/builtin/trait_effect_mech.gd
# 通用机制家族（EF_MECH）：死亡新星 / 谐振轨道 / 格挡（A3 §4.4）。
# · MEC_KILL_BLAST（ON_EXPIRE）：本弹曾击杀 → 爆炸 30% ATK 半径 70（2 层 → 45%/90）。
# · MEC_ORBIT_LINK（ON_SPAWN）：环绕体 +1（仅装备 W8/OrbitWeapon 时生效，orbs_bonus 通道）。
# · MEC_SHIELD（常驻，OnDamageTaken）：玩家侧护盾——EventBus 无对应生命周期事件，
#   运行时应用属包 4 卡牌流/玩家接线（本包数据 + 家族分派就位）。
extends TraitEffect


func handle(p_trait: TraitBase, p_ctx: TraitContext) -> void:
	if p_trait.data == null:
		return
	match p_ctx.event:
		GameConst.TraitEvent.ON_SPAWN:
			if p_ctx.weapon != null and is_instance_valid(p_ctx.weapon) \
					and p_ctx.weapon is OrbitWeapon:
				(p_ctx.weapon as OrbitWeapon).orbs_bonus += p_trait.layers
		GameConst.TraitEvent.ON_EXPIRE:
			_maybe_kill_blast(p_trait, p_ctx)


func _maybe_kill_blast(p_trait: TraitBase, p_ctx: TraitContext) -> void:
	# 死亡新星：击杀时爆炸（引擎在 _on_settled 记录 killed_target/last_hit_pos）
	# 宿主武器可能中途被移除（飞行中弹体）——失效引用按无武器处理
	if p_ctx.projectile == null or p_ctx.weapon == null \
			or not is_instance_valid(p_ctx.weapon):
		return
	if not p_ctx.projectile.killed_target:
		return
	var ratio := float(p_trait.data.params.get("atk_ratio", 0.3))
	var radius := float(p_trait.data.params.get("radius", 70.0))
	if p_trait.layers >= 2:
		ratio = float(p_trait.data.params.get("atk_ratio_lv2", ratio))
		radius = float(p_trait.data.params.get("radius_lv2", radius))
	var atk := float(p_ctx.projectile.panel_snapshot.get("base_atk", 0.0)) * ratio
	p_ctx.weapon.settle_aoe(p_ctx.projectile.last_hit_pos, radius, atk, true)
	DebugStats.count(&"kill_blast_triggered")

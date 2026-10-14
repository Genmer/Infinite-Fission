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
			# R69：MEC_ORBIT_LINK 的 ON_SPAWN 分支已删——环绕武器不产投射物，生产链路
			# 唯一 ON_SPAWN 派发点在 projectile_base（真机永不触发，测试手动派发掩盖成
			# 「看似工作」的死卡）。环绕刀数现由 OrbitWeapon._orbit_link_knives() 聚合
			# 直读挂载表（品质梯分化：每层 +1/+2/+3/+4）
			pass
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
	# R69 品质梯分化：爆炸伤害比改读 data.value（旧读 params.atk_ratio 固定 30%——四品质
	# 完全一样，用户反馈「不同级别数值一样」）。白基准 0.3；蓝/紫/金 ×1.4/1.9/2.6
	# = 42%/57%/78% ATK（params.atk_ratio 仅作缺省兜底）
	var ratio := float(p_trait.data.value)
	var base_ratio := maxf(float(p_trait.data.params.get("atk_ratio", 0.3)), 0.001)
	if is_equal_approx(ratio, 0.0):
		ratio = base_ratio
	var radius := float(p_trait.data.params.get("radius", 70.0))
	if p_trait.layers >= 2:
		# lv2 为绝对白值口径（45%）——按本卡品质因子（value/白基准）同比放大
		ratio = float(p_trait.data.params.get("atk_ratio_lv2", 0.45)) * (ratio / base_ratio)
		radius = float(p_trait.data.params.get("radius_lv2", radius))
	var atk := float(p_ctx.projectile.panel_snapshot.get("base_atk", 0.0)) * ratio
	p_ctx.weapon.settle_aoe(p_ctx.projectile.last_hit_pos, radius, atk, true)
	EventBus.emit_kill_blast(p_ctx.projectile.last_hit_pos, radius)   # R13 爆炸环特效
	DebugStats.count(&"kill_blast_triggered")

# scripts/combat/weapon/melee/orbit_field.gd
# M-08 OrbitField（架构 §2.8.5）：环绕力场实体——浮游球绕本体公转 + 周期范围判定。
# · 公转推进：angle += angular_speed °/s（240°/s，A3 §3.8）；球位均匀相位分布。
# · 判定调度：每球对同一目标独立 hit_cd（"orb_idx:target_uid" 冷却表）；命中 →
#   武器侧 ctx 结算（面板快照展开）+ 击退（可打断自爆引导，AC-06.1）。
# · 生命周期：单武器常驻单例（OrbitWeapon 持有；tick 由武器驱动，随宿主平移）。
class_name OrbitField
extends Node2D

var orbs: int = 2                              # 浮游球数
var orbit_radius: float = 90.0
var angular_speed: float = 240.0               # °/s
var orb_radius: float = 16.0
var angle: float = 0.0                         # 公转相位（rad）
var knockback: float = 40.0
var target_hit_cd: Dictionary = {}             # "orb_idx:target_uid" -> 剩余冷却
var hit_cd: float = 0.5

var weapon: WeaponBase = null                  # 结算宿主（OrbitWeapon 注入）


func spawn(p_params: Dictionary) -> void:
	# 初始化（OrbitWeapon._ensure_orbit_field 构造）
	orbs = clampi(int(p_params.get("orbs", 2)), 1, 16)
	orbit_radius = maxf(float(p_params.get("orbit_radius", 90.0)), 1.0)
	angular_speed = float(p_params.get("angular_speed", 240.0))
	orb_radius = maxf(float(p_params.get("orb_radius", 16.0)), 1.0)
	knockback = float(p_params.get("knockback", 40.0))
	hit_cd = maxf(float(p_params.get("hit_cd", 0.5)), 0.01)
	angle = 0.0
	target_hit_cd.clear()
	visible = true
	queue_redraw()


func tick(p_game_delta: float, p_center: Vector2) -> void:
	# 公转推进 + 球位更新 + 判定调度（每目标独立 hit_cd）+ 击退
	position = p_center
	angle = wrapf(angle + deg_to_rad(angular_speed) * p_game_delta, 0.0, TAU)
	for key in target_hit_cd:
		target_hit_cd[key] = maxf(float(target_hit_cd[key]) - p_game_delta, 0.0)
	if weapon == null or weapon.enemy_grid == null:
		queue_redraw()
		return
	for i in range(orbs):
		var orb_pos := _orb_position(i, p_center)
		_judge_orb(i, orb_pos, p_center)
	queue_redraw()


func _judge_orb(p_orb_index: int, p_orb_pos: Vector2, p_center: Vector2) -> void:
	# 单球周期判定：圆查询 → hit_cd 就绪目标 → 武器侧结算 + 击退
	var candidates: Array[Node2D] = []
	candidates.append_array(weapon.enemy_grid.query_circle(p_orb_pos, orb_radius))
	for target in candidates:
		if target == null or bool(target.get("dead")):
			continue
		var dist := p_orb_pos.distance_to((target as Node2D).global_position)
		if dist > orb_radius + float(target.get("hitbox_r")):
			continue
		var key := "%d:%d" % [p_orb_index, int(target.get("uid"))]
		if float(target_hit_cd.get(key, 0.0)) > 0.0:
			continue
		target_hit_cd[key] = hit_cd
		_orbit_hit(p_orb_index, target, p_center)


func _orbit_hit(p_orb_index: int, p_target: Node2D, p_center: Vector2) -> void:
	# 环绕体周期结算（武器面板快照展开 → 管线；§4.4 同构时序：乘区预聚合 → 派发 → 结算）
	var ctx := weapon.build_damage_context(p_target)
	var tctx := TraitContext.new()
	tctx.event = GameConst.TraitEvent.ON_HIT
	tctx.weapon = weapon
	tctx.melee = self
	tctx.target = p_target
	tctx.damage_ctx = ctx
	if weapon.trait_stack != null:
		for pool in weapon.trait_stack.collect_mult_pools(tctx):
			ctx.mult_pools.append(pool)
	weapon.inject_vuln_pool(ctx, p_target)
	if weapon.trait_stack != null:
		weapon.trait_stack.dispatch(GameConst.TraitEvent.ON_HIT, tctx)
	var result: DamageResult = null
	if weapon.damage_pipeline != null:
		result = weapon.damage_pipeline.call(&"resolve", ctx)
	# 落血口径双轨（同 weapon_base.settle_aoe 审查修复）：真件 DamagePipeline 九步 9b
	# 在 resolve 内部已 take_result 落血（_apply_to_target——killed 判定/死亡广播唯一
	# 执行点），本侧再落血即环绕体伤害 ×2；透传桩 resolve 只算不落血，落血职责在调用
	# 方（pkg2/pkg3 桩用例锁定口径，保持不变）。管线为 null 时 result 为 null，本就不落血。
	if result != null and not (weapon.damage_pipeline is DamagePipeline) \
			and p_target.has_method(&"take_result"):
		p_target.call(&"take_result", result)
	_apply_knockback(p_target, p_center)
	DebugStats.count(&"orbit_hit")


func _apply_knockback(p_target: Node2D, p_center: Vector2) -> void:
	# 击退（径向离心方向；可打断自爆引导——引导行为 M2）
	if knockback <= 0.0 or p_target == null:
		return
	var dir := ((p_target as Node2D).global_position - p_center).normalized()
	if dir == Vector2.ZERO:
		dir = Vector2.UP
	if p_target.has_method(&"knockback"):
		p_target.call(&"knockback", dir * knockback)


func _orb_position(p_index: int, p_center: Vector2) -> Vector2:
	# 球位：均匀相位分布（i × 2π/orbs）
	var phase := angle + TAU * float(p_index) / float(orbs)
	return p_center + Vector2(cos(phase), sin(phase)) * orbit_radius


func _reset_state() -> void:
	# 清零契约（武器回收期）
	angle = 0.0
	target_hit_cd.clear()


func _draw() -> void:
	# 占位渲染：浮游球圆环（美术后续替换）
	if not visible:
		return
	var color := Color(0.55, 0.95, 0.6, 0.85)
	for i in range(orbs):
		var phase := angle + TAU * float(i) / float(orbs)
		var local := Vector2(cos(phase), sin(phase)) * orbit_radius
		draw_circle(local, orb_radius, color)

# scripts/combat/weapon/homing_weapon.gd
# M-07 HomingWeapon（架构 §2.8.4，形态 C）：微型导弹 W6 / 集束火箭 W7 同构。
# · try_fire：cd 制 → 索敌 → 发射 HomingProjectile（锁定 uid；角速度/加速度/二段延时/
#   blast AOE 参数全量注入——spawn 参数字典契约 §2.7.1 注）。
# · 集束变体：主弹命中/消亡经 impact_hook 回调 → _launch_sub_warheads（sub_count 枚
#   延时 sub_delay 寻的子弹头；A3 §3.7：子弹头初速 180/加速 600）。
class_name HomingWeapon
extends WeaponBase

var sub_warheads_left: int = 0                 # 集束火箭变体：子弹头待发数（当轮）
var homing_pool: ProjectilePool = null         # homing 场景池注入


func setup(p_data: WeaponData, p_player: Node2D, p_deps: Dictionary) -> void:
	super(p_data, p_player, p_deps)
	homing_pool = p_deps.get("homing_pool", projectile_pool)
	sub_warheads_left = 0


func try_fire() -> bool:
	# cd 制 → 索敌 → 发射 HomingProjectile（锁定 uid）
	if data == null or homing_pool == null:
		return false
	var target := acquire_target()
	if target == null:
		return false                           # 无目标：不消耗节拍（下帧再索敌）
	var proj := homing_pool.acquire() as ProjectileBase
	if proj == null:
		return false
	_inject_projectile_deps(proj)
	var dir := (target.global_position - muzzle_position()).normalized()
	if dir == Vector2.ZERO:
		dir = AIM_FALLBACK
	proj.spawn({
		"position": muzzle_position(),
		"velocity": dir * float(data.homing.get("proj_speed_init", 240.0)),
		"lifetime": 6.0,
		"pierce": 1,
		"bounces": 0,
		"hitbox_radius": data.hitbox_r,
		"element": GameConst.Element.KIN,
		"attach_value": 0.0,
		"generation": 0,
		"weapon_uid": uid,
		"panel_snapshot": build_panel_snapshot(),
		"trait_stack": trait_stack.copy_runtime() if trait_stack != null else null,
		"team": 0,
		"target_uid": int(target.get("uid")),
		"turn_rate": float(data.homing.get("turn_rate", 480.0)),
		"speed_init": float(data.homing.get("proj_speed_init", 240.0)),
		"speed_max": float(data.homing.get("proj_speed_max", 720.0)),
		"accel": float(data.homing.get("accel", 900.0)),
		"arm_delay": float(data.homing.get("arm_delay", 0.15)),
		"blast_radius": _leveled_param("blast_r", float(data.homing.get("blast_r", 45.0))),
		"blast_falloff": float(data.homing.get("blast_falloff", 0.6)),
	})
	if proj is HomingProjectile and _sub_count() > 0:
		# 包 3 收口：主弹命中回调（集束火箭子弹头调度——HomingProjectile.impact_hook）
		(proj as HomingProjectile).impact_hook = _on_missile_impact
	sub_warheads_left = _sub_count()
	return true


func _on_missile_impact(p_pos: Vector2, p_radius: float) -> void:
	# 主弹爆开 → 子弹头调度（A3 §3.7；AOE 主体由 HomingProjectile._blast_secondaries 承担）
	_launch_sub_warheads(p_pos)


func _launch_sub_warheads(p_pos: Vector2) -> void:
	# sub_count 枚延时寻的子弹头（各延时 sub_delay 后寻的——arm_delay 通道）
	if homing_pool == null or sub_warheads_left <= 0:
		return
	var sub_speed := float(data.homing.get("sub_speed_init", 180.0))
	var sub_accel := float(data.homing.get("sub_accel", 600.0))
	for i in range(sub_warheads_left):
		var proj := homing_pool.acquire() as ProjectileBase
		if proj == null:
			break                             # 池满：余弹丢弃（AC-14.4）
		_inject_projectile_deps(proj)
		var angle := TAU * float(i) / float(sub_warheads_left)
		proj.spawn({
			"position": p_pos,
			"velocity": Vector2.RIGHT.rotated(angle) * sub_speed,
			"lifetime": 5.0,
			"pierce": 1,
			"bounces": 0,
			"hitbox_radius": data.hitbox_r,
			"element": GameConst.Element.KIN,
			"attach_value": 0.0,
			"generation": 1,
			"weapon_uid": uid,
			"panel_snapshot": build_panel_snapshot(),
			"trait_stack": trait_stack.copy_runtime() if trait_stack != null else null,
			"team": 0,
			"target_uid": 0,                   # 子弹头：重索敌通道（初速散射延时后寻的）
			"turn_rate": float(data.homing.get("turn_rate", 480.0)),
			"speed_init": sub_speed,
			"speed_max": float(data.homing.get("proj_speed_max", 720.0)),
			"accel": sub_accel,
			"arm_delay": float(data.homing.get("sub_delay", 0.4)),
			"blast_radius": float(data.homing.get("blast_r", 55.0)),
			"blast_falloff": float(data.homing.get("blast_falloff", 0.6)),
		})
	sub_warheads_left = 0


func _sub_count() -> int:
	# 集束子弹头数（逐级形态参数——A3 §3.7：5/6/6/8/8）
	return int(_leveled_param("sub_count", float(data.homing.get("sub_count", 0))))


func _leveled_param(p_key: String, p_default: float) -> float:
	# 逐级形态参数（形态段新增键 <key>_levels: Array[float]——AC-02.1 仅新增键）
	var levels: Variant = data.homing.get(String(p_key) + "_levels", null)
	if levels is Array and level >= 1 and level <= (levels as Array).size():
		return float((levels as Array)[level - 1])
	return p_default


func _inject_projectile_deps(p_proj: ProjectileBase) -> void:
	# 依赖注入（非初始值，不走 spawn 参数字典——契约 §2.7.1 注）
	p_proj.damage_pipeline = damage_pipeline
	p_proj.enemy_grid = enemy_grid
	p_proj.pool = homing_pool
	p_proj.elemental = elemental

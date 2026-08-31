# scripts/combat/weapon/ballistic_weapon.gd
# M-05 BallisticWeapon（架构 §2.8.2，形态 A）：手枪/加特林/霰弹三变体同构。
# · 手枪：匀速直线 + 微散射（±spread_deg）；霰弹：N=pellets 发散射锥均匀分布；
#   加特林：spin_up_time 预热 → rof_hot 满热（F11 分段：预热→满热→停射 0.8s 冷却重置）。
# · 射速口径：rof_final = rof × (1+ΣAdd_ROF) clamp 30（双护栏；加特林冷/热插值后同样钳制）。
# · 出弹链路：面板快照 + 词条运行时栈（copy_runtime）→ ProjectilePool.acquire →
#   spawn 参数字典（契约冻结，§2.7.1 注）；词条 OnSpawn 期完成体积/反弹预算/元素标记。
class_name BallisticWeapon
extends WeaponBase

var spin_up_left: float = 0.0                  # 加特林预热剩余（0 = 非加特林/已满热）
var rof_current: float = 0.0                   # F11：rof × (1+ΣAdd_ROF) clamp 30（当前口径）
var _since_fire: float = 999.0                 # 距上次开火（停射 0.8s 冷却重置判据）
const SPIN_COOLDOWN_RESET := 0.8               # 停射冷却重置（A3 §3.2）


func setup(p_data: WeaponData, p_player: Node2D, p_deps: Dictionary) -> void:
	super(p_data, p_player, p_deps)
	spin_up_left = _spin_up_time()
	rof_current = 0.0
	_since_fire = 999.0


func try_fire() -> bool:
	# N=pellets 发 × 散射锥均匀分布 → ProjectilePool.acquire（软上限池侧拒绝）
	if data == null or projectile_pool == null:
		return false
	var pellets := _pellet_count()
	var speed := _projectile_speed()
	var dir := aim_direction()
	var fired := 0
	for i in range(pellets):
		var proj := projectile_pool.acquire() as ProjectileBase
		if proj == null:
			break                             # 池满：后续丸丢弃（AC-14.4）
		_inject_projectile_deps(proj)
		var angle := _spread_angle(i, pellets)
		var range_left := _range()
		proj.spawn({
			"position": muzzle_position(),
			"velocity": dir.rotated(angle) * speed,
			"lifetime": maxf(range_left / maxf(speed, 1.0), 0.1) * 1.5,
			"range": range_left,
			"pierce": _pierce_count(),
			"bounces": 0,
			"hitbox_radius": data.hitbox_r,
			"element": GameConst.Element.KIN,
			"attach_value": 0.0,
			"generation": 0,
			"weapon_uid": uid,
			"weapon_ref": self,
			"panel_snapshot": build_panel_snapshot(),
			"trait_stack": trait_stack.copy_runtime() if trait_stack != null else null,
			"team": 0,
		})
		fired += 1
	if fired > 0:
		_since_fire = 0.0
		_advance_spin()
	return fired > 0


func _spread_angle(p_i: int, p_total: int) -> float:
	# 第 i 丸在总锥内的均匀角度（spread_deg 为半锥角 ±；单丸 = 锥内随机抖动）
	var spread := deg_to_rad(_spread_deg())
	if p_total <= 1:
		return randf_range(-spread, spread)
	return -spread + spread * 2.0 * float(p_i) / float(p_total - 1)


func _on_tick_post(p_game_delta: float) -> void:
	# 加特林冷却重置：停射 0.8s → 预热归零（F11 分段第三段）
	_since_fire += p_game_delta
	if _spin_up_time() > 0.0 and _since_fire >= SPIN_COOLDOWN_RESET:
		spin_up_left = _spin_up_time()


func _fire_interval() -> float:
	# F11 + v0.7.0：rof × (1+ΣAdd_ROF) × (1+K_rof) clamp [0.1, 30]（芯片 rof 独立乘数，
	# A6 §3；射速 ≤30 双护栏保留）；加特林 = 冷/热按预热进度插值
	rof_current = clampf(_effective_rof() * (1.0 + _add_rof()) * (1.0 + _chip_rof()), 0.1, _cap_rof())
	return 1.0 / rof_current


func _effective_rof() -> float:
	# 加特林冷/热插值（预热进度 0→1：rof → rof_hot）；非加特林 = 表值
	var cold := get_stat(&"rof")
	var hot := _rof_hot()
	if _spin_up_time() <= 0.0 or hot <= 0.0:
		return cold
	var progress := 1.0 - spin_up_left / maxf(_spin_up_time(), 0.01)
	return lerpf(cold, hot, clampf(progress, 0.0, 1.0))


func _advance_spin() -> void:
	# 开火推进预热（预热→满热）
	if _spin_up_time() > 0.0:
		spin_up_left = maxf(spin_up_left - _fire_interval(), 0.0)


func _add_rof() -> float:
	# ΣAdd_ROF（F3 衰减聚合，TraitStack.aggregate_panel）
	if trait_stack == null:
		return 0.0
	return float(trait_stack.aggregate_panel().get("add_rof", 0.0))


func _pellet_count() -> int:
	# pellets = L 表值 + Add_Pellets 线性层（A3 §4.2：多重装填 +1 共享散射锥）
	var extra := 0
	if trait_stack != null:
		extra = int(round(float(trait_stack.aggregate_panel().get("add_pellets", 0.0))))
	return maxi(int(get_stat(&"pellets")) + extra, 1)


func _pierce_count() -> int:
	# pierce = L 表值 + Add_Pierce 线性层（穿透弹头 +1）
	var extra := 0
	if trait_stack != null:
		extra = int(round(float(trait_stack.aggregate_panel().get("add_pierce", 0.0))))
	return maxi(int(get_stat(&"pierce")) + extra, 0)


func _projectile_speed() -> float:
	# proj_speed × (1+ΣAdd_Spd)（弹道加速 +18%）
	var mult := 0.0
	if trait_stack != null:
		mult = float(trait_stack.aggregate_panel().get("add_spd", 0.0))
	return float(data.ballistic.get("proj_speed", 620.0)) * (1.0 + mult)


func _range() -> float:
	return maxf(float(data.ballistic.get("range", 680.0)), 10.0)


func _spread_deg() -> float:
	# 半锥角（A3 §3.1/§3.2：±2°/±6°；§3.3 霰弹 26° 锥 = ±13°）
	return _leveled_param("spread_deg", float(data.ballistic.get("spread_deg", 2.0)))


func _rof_hot() -> float:
	# 满热射速（加特林变体 >0 生效；L 表递进）
	return _leveled_param("rof_hot", float(data.ballistic.get("rof_hot", 0.0)))


func _spin_up_time() -> float:
	return _leveled_param("spin_up_time", float(data.ballistic.get("spin_up_time", 0.0)))


func _leveled_param(p_key: String, p_default: float) -> float:
	# 逐级形态参数（形态段新增键 <key>_levels: Array[float]——AC-02.1 仅新增键；
	# A3 §3.2/§3.3：加特林 spin_up/rof_hot 与霰弹 L5 锥角随等级变化）
	var levels: Variant = data.ballistic.get(String(p_key) + "_levels", null)
	if levels is Array and level >= 1 and level <= (levels as Array).size():
		return float((levels as Array)[level - 1])
	return p_default


func _inject_projectile_deps(p_proj: ProjectileBase) -> void:
	# 依赖注入（非初始值，不走 spawn 参数字典——契约 §2.7.1 注）
	p_proj.damage_pipeline = damage_pipeline
	p_proj.enemy_grid = enemy_grid
	p_proj.pool = projectile_pool
	p_proj.elemental = elemental

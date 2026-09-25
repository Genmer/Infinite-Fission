# scripts/combat/weapon/homing_weapon.gd
# M-07 HomingWeapon（架构 §2.8.4，形态 C）：微型导弹 W6 / 集束火箭 W7 同构。
# · try_fire：cd 制 → 齐射索敌 → 逐枚发射 HomingProjectile（R187 §三.6 30% 规格齐射轴：
#   volley_count_levels 逐级 1/1/2/2/3 + MEC_HIVE_RACK 叠层 +1 枚/层，clamp[1,5] 硬顶；
#   第 i 发锁第 i 近目标——圆查询按距离升序取前 N；目标不足余弹退回最近目标直击
#   ×0.6^j 递减；出膛 ±10° 均布扇，借 arm_delay 0.15s 并排直飞 → 追踪汇聚弧）。
# · R183 复制体折减（观察口 volley_eff/sub_eff）：W6 副本齐射强制 1 枚；W7 副本子弹头
#   min(sub,3)。副本判定读宿主 _summon_copies 通道（player.gd，宽类型 get 不硬绑）。
# · 集束变体：主弹命中/消亡经 impact_hook 回调 → _launch_sub_warheads（sub_count 枚
#   延时 sub_delay 寻的子弹头；A3 §3.7：子弹头初速 180/加速 600）。
class_name HomingWeapon
extends WeaponBase

const VOLLEY_HARD_CAP := 5                    # 齐射硬顶 5 枚/轮（validator 同域 [1,5]）
const VOLLEY_FAN_DEG := 10.0                  # 出膛扇面全幅 ±10°（单发恒 0°）
const VOLLEY_FALLBACK_DECAY := 0.6            # 目标不足余弹直击递减基数（×0.6^j）
const SUB_COPY_CAP := 3                       # R183 W7 副本子弹头折减帽（min(sub,3)）

var sub_warheads_left: int = 0                 # 集束火箭变体：子弹头待发数（当轮）
var homing_pool: ProjectilePool = null         # homing 场景池注入
var volley_eff: int = 0                        # R183 折减观察口：最近一次折算的实际齐射数
var sub_eff: int = 0                           # R183 折减观察口：最近一次折算的实际子弹头数


func setup(p_data: WeaponData, p_player: Node2D, p_deps: Dictionary) -> void:
	super(p_data, p_player, p_deps)
	homing_pool = p_deps.get("homing_pool", projectile_pool)
	sub_warheads_left = 0
	_refresh_r183_effective()


func muzzle_position() -> Vector2:
	# R25 发射口对齐：子弹从对应悬浮化身位置出膛（视觉发射口=武器）
	return _avatar_muzzle()


func try_fire() -> bool:
	# cd 制 → 齐射索敌 → 逐枚发射（锁定 uid；spawn 参数字典契约 §2.7.1 注）
	if data == null or homing_pool == null:
		return false
	_refresh_r183_effective()
	var targets := _acquire_volley_targets(volley_eff)
	if targets.is_empty():
		return false                           # 无目标：不消耗节拍（下帧再索敌）
	var spd_mult := _proj_spd_mult()      # AFF_PROJ_SPD 弹速池（死卡接线）
	var size_mult := _proj_size_mult()    # AFF_AREA 体积池（死卡接线）
	var speed0 := float(data.homing.get("proj_speed_init", 240.0))
	var origin := muzzle_position()
	var launched := 0
	for i in range(volley_eff):
		var proj := homing_pool.acquire() as ProjectileBase
		if proj == null:
			# 池满：余弹弃发（AC-14.4 不崩不阻塞；弃发计数入预算审计——DebugStats.R187 登记）
			DebugStats.count(&"homing_volley_dropped")
			break
		_inject_projectile_deps(proj)
		# 第 i 发锁第 i 近目标；目标不足余弹退回最近目标 ×0.6^j 直击递减
		var target: Node2D = targets[i] if i < targets.size() else targets[0]
		var direct_mult := 1.0
		if i >= targets.size():
			direct_mult = pow(VOLLEY_FALLBACK_DECAY, float(i - targets.size() + 1))
		var dir := (target.global_position - origin).normalized()
		if dir == Vector2.ZERO:
			dir = AIM_FALLBACK
		# 出膛扇：±10° 均布（volley=1 恒 0°，pkg3 单弹速度断言零回归）
		var spread := 0.0
		if volley_eff > 1:
			spread = deg_to_rad(VOLLEY_FAN_DEG) * (float(i) / float(volley_eff - 1) * 2.0 - 1.0)
		proj.spawn({
			"position": origin,
			"velocity": dir.rotated(spread) * speed0 * spd_mult,
			"lifetime": 6.0,
			"pierce": 1,
			"bounces": 0,
			"hitbox_radius": data.hitbox_r * size_mult,
			"element": _shot_element(),
			"attach_value": 0.0,
			"generation": 0,
			"weapon_uid": uid,
			"weapon_ref": self,
			"panel_snapshot": build_panel_snapshot(),
			"trait_stack": trait_stack.copy_runtime() if trait_stack != null else null,
			"team": 0,
			"target_uid": int(target.get("uid")),
			"turn_rate": float(data.homing.get("turn_rate", 480.0)),
			"speed_init": speed0 * spd_mult,
			"speed_max": float(data.homing.get("proj_speed_max", 720.0)) * spd_mult,
			"accel": float(data.homing.get("accel", 900.0)),
			"arm_delay": float(data.homing.get("arm_delay", 0.15)),
			"blast_radius": _leveled_param("blast_r", float(data.homing.get("blast_r", 45.0))),
			"blast_falloff": float(data.homing.get("blast_falloff", 0.6)),
			"blast_atk_ratio": float(data.homing.get("blast_atk_ratio", 1.0)),
			"direct_mult": direct_mult,
			"volley_size": volley_eff,
		})
		if proj is HomingProjectile and _sub_count() > 0:
			# 包 3 收口：主弹命中回调（集束火箭子弹头调度——HomingProjectile.impact_hook）
			(proj as HomingProjectile).impact_hook = _on_missile_impact
		launched += 1
	sub_warheads_left = sub_eff
	return launched > 0


func _on_missile_impact(p_pos: Vector2, p_radius: float) -> void:
	# 主弹爆开 → 子弹头调度（A3 §3.7；AOE 主体由 HomingProjectile._blast_secondaries 承担）
	_launch_sub_warheads(p_pos)


func _launch_sub_warheads(p_pos: Vector2) -> void:
	# sub_count 枚延时寻的子弹头（各延时 sub_delay 后寻的——arm_delay 通道）；
	# R183 副本折减：sub_warheads_left 已在 try_fire 折算为 sub_eff（min(sub,3)）
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
			"hitbox_radius": data.hitbox_r * _proj_size_mult(),
			"element": _shot_element(),
			"attach_value": 0.0,
			"generation": 1,
			"weapon_uid": uid,
			"weapon_ref": self,
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


# ── R187 齐射轴 / R183 复制体折减 ─────────────────────────────────
func _base_volley() -> int:
	# 齐射基线（volley_count_levels：1/1/2/2/3；缺省键 = 单发——pkg3 通用夹具零回归）
	return int(round(_leveled_param("volley_count", 1.0)))


func _hive_rack_layers() -> int:
	# MEC_HIVE_RACK 直读挂载表（仿 orbit_weapon 消费 MEC_ORBIT_LINK 先例）：
	# 品质梯 value 取整 × 层数（白 +1/层 / 蓝 +2/层——卡面口径与消费端一致）
	if trait_stack == null:
		return 0
	for tb in trait_stack.traits:
		if tb.data != null and tb.data.id == &"MEC_HIVE_RACK":
			return maxi(int(round(float(tb.data.value))), 1) * tb.layers
	return 0


func _refresh_r183_effective() -> void:
	# R183 复制体折减（W6 volley_eff=1 / W7 sub_eff=min(sub,3)）；非副本 = 等级表满编。
	# 判定读宿主 _summon_copies 身份（宽类型 get——测试桩/无宿主返回 null 走满编）
	var copy := _is_summon_copy()
	volley_eff = clampi(_base_volley() + _hive_rack_layers(), 1, VOLLEY_HARD_CAP)
	if copy:
		volley_eff = 1                          # W6 副本齐射强制单发
	sub_eff = mini(_sub_count(), SUB_COPY_CAP) if copy else _sub_count()


func _is_summon_copy() -> bool:
	# R183 副本身份判定（player.gd _summon_copies 独立数组通道——副本不占武器槽）
	if player == null or not is_instance_valid(player):
		return false
	var copies: Variant = player.get("_summon_copies")
	if copies is Array:
		for c in (copies as Array):
			if c == self:
				return true
	return false


func _acquire_volley_targets(p_count: int) -> Array[Node2D]:
	# 第 i 近目标分配：圆查询全候选按距离升序取前 p_count（exclude 语义=累计排除已锁定
	# 目标——单参 exclude 链会回选更近目标；与基类 acquire_target 同口径 1600 半径）
	var targets: Array[Node2D] = []
	if enemy_grid == null or p_count <= 0:
		return targets
	var origin := muzzle_position()
	var candidates: Array[Node2D] = []
	candidates.append_array(enemy_grid.query_circle(origin, 1600.0))
	candidates.sort_custom(func(a: Node2D, b: Node2D) -> bool:
		return a.global_position.distance_squared_to(origin) \
			< b.global_position.distance_squared_to(origin))
	for cand in candidates:
		if targets.size() >= p_count:
			break
		if cand == null or bool(cand.get("dead")):
			continue
		targets.append(cand)
	return targets


func _inject_projectile_deps(p_proj: ProjectileBase) -> void:
	# 依赖注入（非初始值，不走 spawn 参数字典——契约 §2.7.1 注）
	p_proj.damage_pipeline = damage_pipeline
	p_proj.enemy_grid = enemy_grid
	p_proj.pool = homing_pool
	p_proj.elemental = elemental

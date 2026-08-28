# scripts/combat/projectile/homing_projectile.gd
# M-09 HomingProjectile（架构 §2.7.2）：转向/加速/命中范围爆炸。
# 二段延时启动（arm_delay 内直飞无追踪）/ 角速度转向插值 clamp / 加速度推进 clamp 末速 /
# 目标丢失重索敌（0.2s 节奏）/ 命中即爆炸（AOE 次级结算 IS_AOE_SECONDARY）。
class_name HomingProjectile
extends ProjectileBase

var target_uid: int = 0                       # 锁定目标（死亡 0.2s 内重索敌，AC-05.4）
var turn_rate: float = 480.0                  # 最大角速度 °/s
var speed_init: float = 240.0
var speed_max: float = 720.0
var accel: float = 900.0
var arm_delay: float = 0.15                   # 二段延时启动（直飞段无追踪，AC-05.1）
var blast_radius: float = 45.0                # 命中范围爆炸
var blast_falloff: float = 0.6                # 中心 100% → 边缘 60%（线性）
# 包 3 收口：主弹命中回调（W7 集束火箭子弹头调度——HomingWeapon._on_missile_impact；
# 依赖注入通道，不走 spawn 参数字典契约）
var impact_hook: Callable = Callable()

var _target: Node2D = null                    # 目标节点缓存（uid 校验防池回收复用错绑）
var _arm_left: float = 0.0
var _retarget_left: float = 0.0
var _speed_cur: float = 0.0
var _last_dir: Vector2 = Vector2.UP          # 上一帧航向（速度零值防御）

const RETARGET_INTERVAL := 0.2                # 目标丢失重索敌节奏（AC-05.4）
const TARGET_SEARCH_RADIUS := 1600.0          # 索敌扫描半径（覆盖全屏 + 余量）


func _read_form_params(p_params: Dictionary) -> void:
	# 形态参数（架构 §2.7.1 注冻结给包 3 的 Homing 八键）
	target_uid = int(p_params.get("target_uid", 0))
	turn_rate = float(p_params.get("turn_rate", 480.0))
	speed_init = maxf(float(p_params.get("speed_init", 240.0)), 0.0)
	speed_max = maxf(float(p_params.get("speed_max", 720.0)), 0.0)
	accel = float(p_params.get("accel", 900.0))
	arm_delay = maxf(float(p_params.get("arm_delay", 0.15)), 0.0)
	blast_radius = maxf(float(p_params.get("blast_radius", 45.0)), 0.0)
	blast_falloff = clampf(float(p_params.get("blast_falloff", 0.6)), 0.0, 1.0)
	_arm_left = arm_delay
	_retarget_left = RETARGET_INTERVAL
	_speed_cur = speed_init
	_last_dir = velocity.normalized()
	if _last_dir == Vector2.ZERO:
		_last_dir = Vector2.UP
	_target = null
	_resolve_target()


func _reset_form_state() -> void:
	target_uid = 0
	turn_rate = 480.0
	speed_init = 240.0
	speed_max = 720.0
	accel = 900.0
	arm_delay = 0.15
	blast_radius = 45.0
	blast_falloff = 0.6
	impact_hook = Callable()                  # 包 3 收口：命中回调清零
	_target = null
	_arm_left = 0.0
	_retarget_left = 0.0
	_speed_cur = 0.0
	_last_dir = Vector2.UP


func _move(p_game_delta: float) -> void:
	# 加速度推进（clamp 末速）→ arm 计时内直飞 / 计时外转向插值 clamp → 位移
	_speed_cur = minf(_speed_cur + accel * p_game_delta, speed_max)
	if _arm_left > 0.0:
		_arm_left -= p_game_delta
		velocity = _last_dir * _speed_cur     # 二段延时：直飞无追踪（AC-05.1）
	else:
		_track(p_game_delta)
	global_position += velocity * p_game_delta


func _track(p_game_delta: float) -> void:
	# 转向插值 clamp 角速度；目标丢失走重索敌节奏（期间直飞）
	if _target == null and target_uid != 0:
		_retarget()                            # 初次锁定补锁（spawn 期未能解析）
	if not _is_target_valid():
		_retarget_left -= p_game_delta
		if _retarget_left <= 0.0:
			_retarget()
			_retarget_left = RETARGET_INTERVAL
		velocity = _last_dir * _speed_cur
		return
	_retarget_left = RETARGET_INTERVAL         # 目标有效持续复位（丢失后计时 0.2s 才重索）
	var desired := (_target.global_position - global_position).normalized()
	var max_turn := deg_to_rad(turn_rate) * p_game_delta
	_last_dir = _rotate_toward(_last_dir, desired, max_turn)
	velocity = _last_dir * _speed_cur


func _is_target_valid() -> bool:
	# uid 双重校验：节点回收复用后 uid 已换（新身份）→ 视为丢失，杜绝错绑
	if _target == null or not is_instance_valid(_target):
		return false
	if bool(_target.get("dead")):
		return false
	return int(_target.get("uid")) == target_uid


func _retarget() -> void:
	# 重索敌：网格 query_nearest（排除原目标）；初锁期（_target 为空）先按 target_uid 全域扫描
	if enemy_grid == null:
		return
	if _target == null and target_uid != 0:
		_resolve_target()
		if _target != null:
			return                        # 初锁成功
	var found := enemy_grid.query_nearest(global_position, TARGET_SEARCH_RADIUS, _target)
	if found != null and not bool(found.get("dead")):
		_target = found
		target_uid = int(found.get("uid"))


func _resolve_target() -> void:
	# target_uid → 节点解析：网格全域扫描首个 uid 匹配（弹初生时目标可在任意位置）
	if enemy_grid == null or target_uid == 0:
		return
	var candidates: Array[Node2D] = []
	candidates.append_array(enemy_grid.query_circle(global_position, TARGET_SEARCH_RADIUS))
	for cand in candidates:
		if int(cand.get("uid")) == target_uid and not bool(cand.get("dead")):
			_target = cand
			return


func _rotate_toward(p_cur: Vector2, p_desired: Vector2, p_max_turn: float) -> Vector2:
	# 转向插值 clamp：本帧最大角速度内朝期望方向旋转（角速度上限硬闸）
	var angle := p_cur.angle_to(p_desired)
	if angle <= p_max_turn or angle < 0.0001:
		return p_desired.normalized()
	var cross := p_cur.cross(p_desired)
	return p_cur.rotated(signf(cross) * p_max_turn)


func _on_settled(p_target: Node2D, p_result: DamageResult, p_tctx: TraitContext = null) -> void:
	# 命中即爆炸：主目标结算 → 集束回调（W7 子弹头调度，包 3 收口）→ AOE 次级结算
	# （IS_AOE_SECONDARY，线性衰减）→ 附着 → 回收（无穿透语义）
	_apply_result_to(p_target, p_result)
	if p_result != null:
		killed_target = killed_target or p_result.killed
		last_hit_pos = global_position
	if impact_hook.is_valid():
		impact_hook.call(global_position, blast_radius)
	_blast_secondaries(p_target)
	_apply_elemental(p_target, p_result, p_tctx)
	_recycle(GameConst.RecycleReason.PIERCE_DEPLETED)


func _blast_secondaries(p_primary: Node2D) -> void:
	# 命中范围爆炸 AOE 委托：blast_radius 内其余目标线性衰减次级结算
	#（中心 100% → 边缘 blast_falloff；E-03 帧聚合同帧同目标去重同样适用于次级目标）
	if blast_radius <= 0.0 or enemy_grid == null or damage_pipeline == null:
		return
	var candidates: Array[Node2D] = []
	candidates.append_array(enemy_grid.query_circle(global_position, blast_radius))
	for cand in candidates:
		if not _live:
			break
		if cand == p_primary or not _in_reach(cand, blast_radius):
			continue
		var c_uid: Variant = cand.get("uid")
		if c_uid == null or hits_this_frame.has(c_uid) or bool(cand.get("dead")):
			continue
		hits_this_frame[c_uid] = true
		var dist := global_position.distance_to(cand.global_position)
		var t := clampf(dist / blast_radius, 0.0, 1.0)
		var scale := 1.0 - (1.0 - blast_falloff) * t
		var ctx := _build_damage_ctx(cand)
		ctx.hit_flags |= GameConst.HIT_IS_AOE_SECONDARY
		ctx.base_atk *= scale
		var result: DamageResult = damage_pipeline.call(&"resolve", ctx)
		_apply_result_to(cand, result)

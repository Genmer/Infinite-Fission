# scripts/combat/projectile/homing_projectile.gd
# M-09 HomingProjectile（架构 §2.7.2）：转向/加速/命中范围爆炸。
# 二段延时启动（arm_delay 内直飞无追踪）/ 角速度转向插值 clamp / 加速度推进 clamp 末速 /
# 目标丢失重索敌（0.2s 节奏）/ 命中即爆炸（AOE 次级结算 IS_AOE_SECONDARY）。
# R187 §三.6 30% 规格追加：
# · blast_atk_ratio 溅射口径（W6 0.6 / W7 1.0——直击不砍，只折爆炸伤害）；
# · direct_mult 齐射目标不足余弹直击递减（×0.6^j，仅直击路径，溅射另行覆写 base_atk）；
# · 引信连携：直击挂引信（MEC_FUSE_COAT，敌侧通用标记通道 fuse_mark_left 4s 幂等刷新）
#   → 引信敌受自导爆炸 ×(1+0.2×层) → W7 爆炸消耗引信追加 0.5/层×ATK 余波（每敌 0.5s
#   护栏走敌侧 fuse_detonate_guard_left——防同帧双爆双吃）；
# · TH_SWARM_NOVA（W6 身份线）：齐射 ≥5 → 每枚空爆 1.2×blast_r / 30%ATK 冲击波。
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
var blast_atk_ratio: float = 1.0              # R187 溅射伤比 ∈(0,1]（W6 0.6 / W7 1.0）
var direct_mult: float = 1.0                  # R187 齐射余弹直击递减乘子（×0.6^j）
var volley_size: int = 0                      # R187 本轮齐射数（≥5 且武器含 TH_SWARM_NOVA → 空爆）
# 包 3 收口：主弹命中回调（W7 集束火箭子弹头调度——HomingWeapon._on_missile_impact；
# 依赖注入通道，不走 spawn 参数字典契约）
var impact_hook: Callable = Callable()

const FUSE_MARK_DURATION := 4.0               # 引信涂层时长 s（直击幂等刷新——MEC_FUSE_COAT）
const FUSE_DET_GUARD := 0.5                   # 定向爆破护栏 s（每敌；计时在敌侧通道推进）

var _target: Node2D = null                    # 目标节点缓存（uid 校验防池回收复用错绑）
var _arm_left: float = 0.0
var _retarget_left: float = 0.0
var _speed_cur: float = 0.0
var _last_dir: Vector2 = Vector2.UP          # 上一帧航向（速度零值防御）

const RETARGET_INTERVAL := 0.2                # 目标丢失重索敌节奏（AC-05.4）
const TARGET_SEARCH_RADIUS := 1600.0          # 索敌扫描半径（覆盖全屏 + 余量）

var _det_uid: int = 0                         # 引爆/余波结算独立 source_uid（管线幂等键分流——
                                              # 同帧「溅射 + 余波」对同一目标不互撞；OrbitField
                                              # _detonate_uid 同款先例，实例级一次）


func _init() -> void:
	_det_uid = GameConst.next_uid()


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
	blast_atk_ratio = clampf(float(p_params.get("blast_atk_ratio", 1.0)), 0.0, 1.0)
	direct_mult = maxf(float(p_params.get("direct_mult", 1.0)), 0.0)
	volley_size = maxi(int(p_params.get("volley_size", 0)), 0)
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
	blast_atk_ratio = 1.0
	direct_mult = 1.0
	volley_size = 0
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
	# 命中即爆炸：主目标结算 → W6 直击挂引信（幂等刷新）→ 集束回调（W7 子弹头调度，
	# 包 3 收口）→ AOE 次级结算（IS_AOE_SECONDARY，blast_atk_ratio×线性衰减；引信敌
	# ×coat 乘区 + FUSE_DETONATE 消耗引信追加余波）→ 蜂群新星空爆（TH_SWARM_NOVA）
	# → 附着 → 回收（无穿透语义）
	_apply_result_to(p_target, p_result)
	_apply_fuse_coat(p_target)
	if p_result != null:
		killed_target = killed_target or p_result.killed
		last_hit_pos = global_position
	if impact_hook.is_valid():
		impact_hook.call(global_position, blast_radius)
	EventBus.emit_missile_blast(global_position, blast_radius)   # R80 强化版爆炸（四层爆+震屏+低音）
	_blast_secondaries(p_target)
	_maybe_swarm_nova(p_target)
	_apply_elemental(p_target, p_result, p_tctx)
	_recycle(GameConst.RecycleReason.PIERCE_DEPLETED)


func _recycle(p_reason: int, p_released_by_pool: bool = false) -> void:
	# R80 过期空爆：寿命尽（arm 后）原地起爆——导弹总会炸（用户反馈「没有命中范围爆炸」：
	# 目标中途死亡/脱锁的导弹此前直飞到过期消失，视觉上等于没有 AoE）
	if p_reason == GameConst.RecycleReason.EXPIRED and _live \
			and blast_radius > 0.0 and _arm_left <= 0.0:
		EventBus.emit_missile_blast(global_position, blast_radius)
		_blast_secondaries(null)
		_maybe_swarm_nova(null)
	super(p_reason, p_released_by_pool)


func _blast_secondaries(p_primary: Node2D) -> void:
	# 命中范围爆炸 AOE 委托：blast_radius 内其余目标线性衰减次级结算
	#（中心 blast_atk_ratio×ATK → 边缘 ×blast_falloff——R187 30% 规格：W6 0.6 / W7 1.0；
	# E-03 帧聚合同帧同目标去重同样适用于次级目标）。引信敌 ×(1+coat_value×layers)；
	# FUSE_DETONATE（W7 消费口）：引信敌爆炸消耗引信追加 0.5/层×ATK 余波，每敌 0.5s
	# 护栏（敌侧 fuse_detonate_guard_left 通道）内不二次追加。
	if blast_radius <= 0.0 or enemy_grid == null or damage_pipeline == null:
		return
	var det_layers := 0
	var det_value := 0.0
	if trait_stack is TraitStack:
		for tb in (trait_stack as TraitStack).traits:
			if tb.data != null and tb.data.id == &"MEC_FUSE_DETONATE":
				det_layers = tb.layers
				det_value = float(tb.data.value)
				break
	var splash_base := float(panel_snapshot.get("base_atk", 0.0)) * blast_atk_ratio
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
		ctx.base_atk = splash_base * scale * _fuse_amp_mult(cand)
		var result: DamageResult = damage_pipeline.call(&"resolve", ctx)
		_apply_result_to(cand, result)
		if det_layers > 0 and _fuse_mark_left(cand) > 0.0:
			var guard: Variant = cand.get("fuse_detonate_guard_left")
			if guard != null and float(guard) > 0.0:
				continue                    # 0.5s 护栏内：不消耗不追加（防同帧双爆双吃）
			cand.set("fuse_detonate_guard_left", FUSE_DET_GUARD)
			_set_fuse_mark(cand, 0.0)       # 爆炸消耗引信
			var actx := _build_damage_ctx(cand)
			# 余波独立幂等键（source_uid 分流）：同一帧内溅射已结算 (uid,cand,frame)，
			# 余波若沿用弹体 uid 会被管线幂等缓存吞掉（缓存短路在落血之前——余波恒 0 伤）。
			actx.source_uid = _det_uid
			actx.hit_flags |= GameConst.HIT_IS_AOE_SECONDARY
			actx.base_atk = float(panel_snapshot.get("base_atk", 0.0)) * det_value * float(det_layers)
			var aresult: DamageResult = damage_pipeline.call(&"resolve", actx)
			_apply_result_to(cand, aresult)
			_aftershock_aoe(cand, det_value, det_layers)


func _aftershock_aoe(p_center: Node2D, p_det_value: float, p_det_layers: int) -> void:
	# §2.3.5 余波溅射半径：定向爆破余波以 0.5×blast_r 波及邻近敌（同额 0.5/层×ATK，
	# 设计无衰减声明）；复用 _det_uid 独立幂等键同帧不与溅射互撞；引信敌本体已在上方
	# 单体结算（验收「恰一次」口径）——本查询排除之。
	if blast_radius <= 0.0 or enemy_grid == null or damage_pipeline == null \
			or p_det_layers <= 0 or p_center == null:
		return
	var radius := blast_radius * 0.5
	if radius <= 0.0:
		return
	var pos := (p_center as Node2D).global_position
	var atk := float(panel_snapshot.get("base_atk", 0.0)) * p_det_value * float(p_det_layers)
	for cand2 in enemy_grid.query_circle(pos, radius):
		if cand2 == null or cand2 == p_center or bool(cand2.get("dead")):
			continue
		var actx2 := _build_damage_ctx(cand2)
		actx2.source_uid = _det_uid
		actx2.hit_flags |= GameConst.HIT_IS_AOE_SECONDARY
		actx2.base_atk = maxf(atk, 0.0)
		var aresult2: DamageResult = damage_pipeline.call(&"resolve", actx2)
		_apply_result_to(cand2, aresult2)


func _build_damage_ctx(p_target: Node2D) -> DamageContext:
	# 直击 ctx 扩展：齐射目标不足余弹 ×0.6^j 直击递减（仅直击路径生效——溅射/余波在
	# _blast_secondaries 内另行覆写 base_atk，不继承本乘子）
	var ctx := super(p_target)
	if not is_equal_approx(direct_mult, 1.0):
		ctx.base_atk *= direct_mult
	return ctx


func _maybe_swarm_nova(p_primary: Node2D) -> void:
	# TH_SWARM_NOVA（W6 身份线）：齐射 ≥5 → 每枚空爆 1.2×blast_r / 30%ATK 冲击波
	#（exclude 直击主目标，同 TH_SIZE_NOVA 口径；radius_mult/atk_ratio 数据驱动）。
	# volley_size=0（子弹头/无齐射上下文）不触发。
	if volley_size <= 0 or weapon_ref == null or not is_instance_valid(weapon_ref):
		return
	var threshold: Dictionary = (weapon_ref as WeaponBase).get_threshold(&"TH_SWARM_NOVA")
	if threshold.is_empty():
		return
	if float(volley_size) < float(threshold.get("threshold", 5.0)):
		return
	var params: Dictionary = threshold.get("params", {})
	var radius := blast_radius * float(params.get("radius_mult", 1.2))
	var atk: float = float(panel_snapshot.get("base_atk", 0.0)) * float(params.get("atk_ratio", 0.3))
	(weapon_ref as WeaponBase).settle_aoe(global_position, radius, atk, true, p_primary)
	DebugStats.count(&"swarm_nova_triggered")


# ── R187 引信连携（敌侧通用标记通道：enemy.gd fuse_mark_left / fuse_detonate_guard_left） ──
func _apply_fuse_coat(p_target: Node2D) -> void:
	# W6 直击挂引信（MEC_FUSE_COAT 直读挂载表）：4s 幂等刷新（重击续 4s 不叠加）。
	# §2.3.5 目标侧增伤标记：amp = 1+coat_value×层 随标落敌身（fuse_coat_amp，幂等取
	# max）——期间任何自导爆炸（W6 溅射 / W7 引爆溅射）命中引信敌同享，双卡连携通道。
	if p_target == null or _coat_layers() <= 0:
		return
	var amp := 1.0 + _coat_value() * float(_coat_layers())
	if p_target.has_method(&"apply_fuse_mark"):
		p_target.call(&"apply_fuse_mark", FUSE_MARK_DURATION, amp)
		return
	_set_fuse_mark(p_target, FUSE_MARK_DURATION)   # 桩目标回退：raw 通道（无 amp 字段语义）
	p_target.set("fuse_coat_amp", amp)


func _coat_layers() -> int:
	if not (trait_stack is TraitStack):
		return 0
	for tb in (trait_stack as TraitStack).traits:
		if tb.data != null and tb.data.id == &"MEC_FUSE_COAT":
			return tb.layers
	return 0


func _coat_value() -> float:
	if not (trait_stack is TraitStack):
		return 0.0
	for tb in (trait_stack as TraitStack).traits:
		if tb.data != null and tb.data.id == &"MEC_FUSE_COAT":
			return float(tb.data.value)
	return 0.0


func _fuse_amp_mult(p_target: Node2D) -> float:
	# 引信敌受自导爆炸增伤（§2.3.5 目标侧标记口径）：amp 随 W6 涂层落敌身
	#（fuse_coat_amp，挂标时写入）——期间任何自导爆炸命中引信敌同享（W6 溅射 /
	# W7 引爆溅射；卡面「引信目标受到的自导爆炸伤害 +20%/层」字面口径，评审 R10）；
	# 非引信敌 ×1.0
	if _fuse_mark_left(p_target) <= 0.0:
		return 1.0
	var v: Variant = p_target.get("fuse_coat_amp")
	return float(v) if v != null else 1.0


func _fuse_mark_left(p_target: Node2D) -> float:
	# 敌侧引信读数（字段缺省 = 通道未挂，0 安全值——get/set 宽类型不硬绑 Enemy 类）
	if p_target == null:
		return 0.0
	var v: Variant = p_target.get("fuse_mark_left")
	return float(v) if v != null else 0.0


func _set_fuse_mark(p_target: Node2D, p_value: float) -> void:
	if p_target != null:
		p_target.set("fuse_mark_left", p_value)

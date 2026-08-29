# scripts/combat/weapon/melee/arc_slash.gd
# M-08 ArcSlash（架构 §2.8.5）：周期挥斩实体——固定角度弧形判定 + 击退 + 消弹。
# · 判定窗口 0.15s（窗口外无判定，AC-06.3 ±1° 扇形口径）；朝向 = 开窗时刻最近敌方向
#   （窗口期内固定不扫摆）。
# · 扇形判定：query_arc（中心角 facing、半角 arc_deg/2、半径 slash_radius）；
#   单斩目标上限 max_targets；同窗同目标单次（_struck 去重）。
# · 消弹（nullify=true，W9）：弧内敌方弹幕 → ProjectileBase.nullify() →
#   OnExpire(NULLIFIED) → 清零 → 弹池回收（AC-06.2 统一收束路径）。
class_name ArcSlash
extends Node2D

var slash_radius: float = 150.0
var arc_deg: float = 120.0                    # 扇形角
var facing: float = 0.0                       # 固定角度窗口中心（rad）
var window_left: float = 0.0                  # 判定窗口剩余（0.15s）
var max_targets: int = 8                      # 单斩目标上限
var knockback: float = 180.0
var nullify: bool = false                     # 消弹开关（W9=true）
var enemy_grid: SpaceGrid = null              # 注入（扇形判定）
var enemy_bullet_grid: SpaceGrid = null       # 注入（消弹查询；GameLoop 帧序③双网格）
var weapon: WeaponBase = null                 # 结算宿主（OrbitWeapon 注入）

var _struck: Dictionary = {}                  # 同窗已判定目标去重（uid -> true）


func spawn(p_params: Dictionary) -> void:
	slash_radius = maxf(float(p_params.get("slash_radius", 150.0)), 1.0)
	arc_deg = clampf(float(p_params.get("arc_deg", 120.0)), 1.0, 360.0)
	max_targets = maxi(int(p_params.get("max_targets", 8)), 1)
	knockback = float(p_params.get("knockback", 180.0))
	nullify = bool(p_params.get("nullify", false))
	window_left = 0.0
	facing = 0.0
	_struck.clear()
	visible = false


func open_window(p_facing: float) -> void:
	# 挥斩窗口开启（持续 0.15s；窗口中心固定于开窗时刻朝向）
	facing = p_facing
	window_left = OrbitWeapon.SLASH_WINDOW
	_struck.clear()
	visible = true
	queue_redraw()


func tick(p_game_delta: float, p_center: Vector2) -> void:
	# 窗口内：扇形判定（query_arc）+ 击退 + 消弹；窗口外无判定
	if window_left <= 0.0:
		if visible:
			visible = false
			queue_redraw()
		return
	position = p_center
	window_left = maxf(window_left - p_game_delta, 0.0)
	_judge_arc(p_center)
	if nullify:
		_nullify_enemy_bullets(p_center)
	queue_redraw()


func _judge_arc(p_center: Vector2) -> void:
	# 扇形判定：query_arc（半径/半角/中心角）→ 上限内逐目标结算 + 击退
	if enemy_grid == null or weapon == null:
		return
	var candidates: Array[Node2D] = []
	candidates.append_array(enemy_grid.query_arc(p_center, slash_radius,
		facing, deg_to_rad(arc_deg) * 0.5))
	var hit := 0
	for target in candidates:
		if hit >= max_targets:
			break
		if target == null or bool(target.get("dead")):
			continue
		var uid := int(target.get("uid"))
		if _struck.has(uid):
			continue
		_struck[uid] = true
		_slash_hit(target, p_center)
		hit += 1


func _slash_hit(p_target: Node2D, p_center: Vector2) -> void:
	# 挥斩结算（武器面板快照展开 → 管线；§4.4 同构时序）
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
	# 执行点），本侧再落血即挥斩伤害 ×2；透传桩 resolve 只算不落血，落血职责在调用
	# 方（pkg2/pkg3 桩用例锁定口径，保持不变）。管线为 null 时 result 为 null，本就不落血。
	if result != null and not (weapon.damage_pipeline is DamagePipeline) \
			and p_target.has_method(&"take_result"):
		p_target.call(&"take_result", result)
	if knockback > 0.0 and p_target.has_method(&"knockback"):
		var dir := ((p_target as Node2D).global_position - p_center).normalized()
		if dir == Vector2.ZERO:
			dir = Vector2.UP
		p_target.call(&"knockback", dir * knockback)
	DebugStats.count(&"arc_slash_hit")


func _nullify_enemy_bullets(p_center: Vector2) -> void:
	# 弧内敌方弹 → OnExpire(NULLIFIED) 路径销毁（AC-06.2——统一收束弹池回收）
	if enemy_bullet_grid == null:
		return
	var bullets: Array[Node2D] = []
	bullets.append_array(enemy_bullet_grid.query_arc(p_center, slash_radius,
		facing, deg_to_rad(arc_deg) * 0.5))
	for bullet in bullets:
		if bullet is ProjectileBase and (bullet as ProjectileBase).team == 1:
			(bullet as ProjectileBase).nullify()
			DebugStats.count(&"bullet_nullified")


func _reset_state() -> void:
	# 清零契约（武器回收期）
	window_left = 0.0
	_struck.clear()
	visible = false


func _draw() -> void:
	# 占位渲染：扇形楔块（窗口期可视化；美术后续替换）
	if not visible or window_left <= 0.0:
		return
	var color := Color(1.0, 0.9, 0.35, 0.35)
	var half := deg_to_rad(arc_deg) * 0.5
	var steps := maxi(int(arc_deg / 12.0), 3)
	var points := PackedVector2Array([Vector2.ZERO])
	for i in range(steps + 1):
		var a := facing - half + (2.0 * half) * float(i) / float(steps)
		points.append(Vector2(cos(a), sin(a)) * slash_radius)
	draw_colored_polygon(points, color)

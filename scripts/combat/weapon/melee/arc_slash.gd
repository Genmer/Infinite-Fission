# scripts/combat/weapon/melee/arc_slash.gd
# M-08 ArcSlash（架构 §2.8.5）：周期挥斩实体——固定角度弧形判定 + 消弹。
# R7：击退权移交霰弹枪（本武器 180px 强击退每刀推飞全屏怪 = 用户实测「闪退」根因）；
# 视觉重做——z_index 提层 + 双层弧面 + 0.15s 窗口内扫动 + 前缘亮线（原单层低透明楔块被怪压住不可见）。
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
var knockback: float = 0.0                   # R7：默认无击退（击退权在霰弹枪；保留参数位）
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
	z_index = 5                                  # 敌/玩家之上（R7：原默认 z 被怪精灵压住）


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
	# R10 根因修复：本节点是武器（玩家子节点）的子节点——position 为局部坐标，
	# 此前直接塞 muzzle_position() 全局值 → 视觉画到屏幕外（判定用全局所以只有「虚空伤害」）
	position = weapon.to_local(p_center) if weapon != null and is_instance_valid(weapon) 		else p_center
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
			EventBus.emit_bullet_nullified((bullet as ProjectileBase).global_position)


func _reset_state() -> void:
	# 清零契约（武器回收期）
	window_left = 0.0
	_struck.clear()
	visible = false


func _draw() -> void:
	# 挥斩视觉（夜间R59 重做——用户反馈「不是个刀吗，怎么是个扇子」：旧版铺整扇
	# 面填充+全弧描边 = 判定范围画成扇子）。现 = 一道弯月刀光沿扇角扫过：
	# 主体钢白弯月（窄弧带）+ 三道渐隐拖尾弧 + 亮白前缘；判定仍为 query_arc 扇形。
	if not visible or window_left <= 0.0:
		return
	var half := deg_to_rad(arc_deg) * 0.5
	var progress := clampf(1.0 - window_left / OrbitWeapon.SLASH_WINDOW, 0.0, 1.0)
	var sweep := facing - half + 2.0 * half * clampf(progress * 1.15, 0.0, 1.0)
	var band := deg_to_rad(34.0)                 # 刀光弧带张角（窄月）
	var r_out := slash_radius
	var r_in := slash_radius * 0.55
	# 拖尾残影（3 道，位置滞后、α 递减——挥砍轨迹读感）
	for k in range(3):
		var tp := clampf(progress - 0.16 * float(k + 1), 0.0, 1.0)
		if tp <= 0.0:
			continue
		var ts := facing - half + 2.0 * half * clampf(tp * 1.15, 0.0, 1.0)
		var trail_a := [0.26, 0.14, 0.07][k]
		_draw_moon(ts, band * 1.25, r_out * 0.98, r_in * 1.08,
			Color(0.62, 0.85, 1.0, trail_a))
	# 主体弯月（钢白，青蓝辉光边）
	_draw_moon(sweep, band, r_out, r_in, Color(0.93, 0.97, 1.0, 0.8))
	# 前缘亮线（刀刃）
	var half_b := band * 0.5
	var edge := PackedVector2Array()
	for i in range(7):
		var a := sweep - half_b + band * float(i) / 6.0
		edge.append(Vector2(cos(a), sin(a)) * r_out)
	draw_polyline(edge, Color(1.0, 1.0, 1.0, 0.95), 4.0, true)


func _draw_moon(p_center_a: float, p_band: float, p_r_out: float, p_r_in: float,
		p_color: Color) -> void:
	# 弯月弧带多边形：外弧 a-band/2 → a+band/2（半径 p_r_out）+ 内弧反向（p_r_in）
	var half_b := p_band * 0.5
	var steps := 8
	var pts := PackedVector2Array()
	for i in range(steps + 1):
		var a := p_center_a - half_b + p_band * float(i) / float(steps)
		pts.append(Vector2(cos(a), sin(a)) * p_r_out)
	for j in range(steps + 1):
		var a2 := p_center_a + half_b - p_band * float(j) / float(steps)
		pts.append(Vector2(cos(a2), sin(a2)) * p_r_in)
	draw_colored_polygon(pts, p_color)

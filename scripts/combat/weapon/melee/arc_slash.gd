# scripts/combat/weapon/melee/arc_slash.gd
# M-08 ArcSlash（架构 §2.8.5）：周期挥斩实体——固定角度弧形判定 + 消弹。
# R7：击退权移交霰弹枪（本武器 180px 强击退每刀推飞全屏怪 = 用户实测「闪退」根因）；
# R61 视觉（用户两轮反馈「怎么是个扇子」）：z_index 提层 + 实体刀形抡过（刀身/刃口/
# 护手/柄多边形旋转扫扇角，淡刀残影 + 刀尖短弧光）——R59 弧带方案铺满扇区读感仍是扇子。
# R65 追击者重做（用户重定义 W9）：中心 = 追击刀位（strike_center）、判定窗口放慢
#（0.15→0.34s——用户点名「动画慢点」）；判定口径（query_arc 半径/半角/上限/消弹）不变。
# · 判定窗口 SLASH_WINDOW（窗口外无判定，AC-06.3 ±1° 扇形口径）；朝向 = 开窗时刻
#   刀→目标方向（窗口期内固定不扫摆）。
# · 扇形判定：query_arc（中心角 facing、半角 arc_deg/2、半径 slash_radius）；
#   单斩目标上限 max_targets；同窗同目标单次（_struck 去重）。
# · 消弹（nullify=true，W9）：弧内敌方弹幕 → ProjectileBase.nullify() →
#   OnExpire(NULLIFIED) → 清零 → 弹池回收（AC-06.2 统一收束路径）。
class_name ArcSlash
extends Node2D

var slash_radius: float = 150.0
var arc_deg: float = 120.0                    # 扇形角
var facing: float = 0.0                       # 固定角度窗口中心（rad）
var window_left: float = 0.0                  # 判定窗口剩余（R65：0.34s）
var strike_center: Vector2 = Vector2.INF      # R65 刀位中心（INF = 未设 → 跟随宿主）
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


func open_window(p_facing: float, p_center: Vector2 = Vector2.INF,
		p_radius: float = -1.0) -> void:
	# 挥斩窗口开启（持续 SLASH_WINDOW；窗口中心固定于开窗时刻朝向）。
	# R65：p_center = 刀位世界中心（追击开砍——中心从玩家移到刀，判定口径不变）；
	# p_radius > 0 = 本窗判定半径（巨刃乘区后的面板值）。缺省 → 旧口径（跟随宿主）。
	facing = p_facing
	strike_center = p_center
	if p_radius > 0.0:
		slash_radius = p_radius
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
	# R65：刀位开窗后中心固定在刀位（不随玩家移动）；宿主中心口径保留给旧调用方
	var center := strike_center if strike_center != Vector2.INF else p_center
	# R10 根因修复：本节点是武器（玩家子节点）的子节点——position 为局部坐标，
	# 此前直接塞 muzzle_position() 全局值 → 视觉画到屏幕外（判定用全局所以只有「虚空伤害」）
	position = weapon.to_local(center) if weapon != null and is_instance_valid(weapon) 		else center
	window_left = maxf(window_left - p_game_delta, 0.0)
	_judge_arc(center)
	if nullify:
		_nullify_enemy_bullets(center)
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
	# 挥斩视觉（R61 二次重做——用户复反馈「不是个刀吗，怎么是个扇子」：R59 弯月弧带
	# 方案中主体+三道拖尾弧相邻重叠，半透明弧带几乎铺满 120° 扇区，读感仍是扇子）。
	# 现 = **实体刀形抡过**：刀身多边形（刀背弧线+刀刃+护手+柄，r 8→slash_radius 全长）
	# 绕中心旋转扫过扇角，2 把淡刀残影给运动读感，刀尖拖 20° 短弧光表速度；
	# 判定仍为 query_arc 扇形（视觉与判定口径解耦——视觉是刀在抡，判定是扇形范围）。
	if not visible or window_left <= 0.0:
		return
	var half := deg_to_rad(arc_deg) * 0.5
	var progress := clampf(1.0 - window_left / OrbitWeapon.SLASH_WINDOW, 0.0, 1.0)
	var sweep := facing - half + 2.0 * half * clampf(progress * 1.15, 0.0, 1.0)
	# 残影：2 把淡刀（角度滞后拉开间距不叠本体、α 递减；填充+描边保证**刀形轮廓**可辨
	# ——纯低透明填充会糊成弧形色带，正是「读感像扇子」的残影来源）
	for k in range(2):
		var tp := progress - 0.16 * float(k + 1)
		if tp <= 0.0:
			continue
		var ta := facing - half + 2.0 * half * clampf(tp * 1.15, 0.0, 1.0)
		draw_set_transform(Vector2(), ta, Vector2.ONE)
		var ga: float = [0.34, 0.16][k]
		_draw_blade(Color(0.62, 0.85, 1.0, ga), Color(0.82, 0.94, 1.0, minf(ga * 1.9, 0.7)), false)
	# 本体刀（顶点渐变：刀背暗钢→刃口亮白，刃部突出；深色护手/柄）
	draw_set_transform(Vector2(), sweep, Vector2.ONE)
	_draw_blade(Color(0.93, 0.97, 1.0, 0.92), Color(1.0, 1.0, 1.0, 0.95), true)
	draw_set_transform(Vector2(), 0.0, Vector2.ONE)
	# 刀尖拖出的短弧光（仅 20°，跟在本体后——速度感；不再全弧描边）
	var tip := PackedVector2Array()
	for i in range(5):
		var a := sweep - deg_to_rad(20.0) + deg_to_rad(20.0) * float(i) / 4.0
		tip.append(Vector2(cos(a), sin(a)) * (slash_radius * 0.97))
	draw_polyline(tip, Color(1.0, 1.0, 1.0, 0.4), 3.0, true)


func _draw_blade(p_fill: Color, p_line: Color, p_full: bool) -> void:
	# 刀体（刀身局部系：+X = 出刃方向，刀尖在 slash_radius 端；-Y = 挥动前进侧 = 刃口）。
	# 柄在玩家/化身近端（r≈8..34），刀身 r≈38..slash_radius——一把全长出刃的直背弯刃刀
	var deep := Color(0.16, 0.28, 0.45, 0.95)
	# 刀身：刀背（+Y 侧，近直带缓弧）→ 刀尖 → 刀刃（-Y 侧，弧形收锋）
	var blade := PackedVector2Array([
		Vector2(38.0, 6.0), Vector2(95.0, 5.0), Vector2(128.0, 0.0), Vector2(150.0, -10.0),
		Vector2(142.0, -24.0), Vector2(100.0, -26.0), Vector2(65.0, -22.0), Vector2(38.0, -6.0),
	])
	if p_full:
		# 顶点渐变（刀背暗钢 → 刃口亮白）：刀身不再是整块平色，刃/背一眼可分
		var cols := PackedColorArray([
			Color(0.55, 0.66, 0.84, 0.95), Color(0.62, 0.74, 0.90, 0.95),
			Color(0.78, 0.88, 1.0, 0.95), Color(0.95, 0.98, 1.0, 0.95),
			p_fill, Color(0.92, 0.97, 1.0, 0.95), Color(0.85, 0.93, 1.0, 0.95),
			Color(0.70, 0.81, 0.96, 0.95),
		])
		draw_polygon(blade, cols)
		# 刃口亮线（锋利读感；-Y 侧 = 旋转前进方向，刃口领先进刀）
		draw_polyline(PackedVector2Array([
			Vector2(142.0, -24.0), Vector2(100.0, -26.0), Vector2(65.0, -22.0), Vector2(38.0, -6.0),
		]), p_line, 3.5, true)
		# 刀背描线（暗色，压出背面轮廓——刀形立体感）
		draw_polyline(PackedVector2Array([
			Vector2(38.0, 6.0), Vector2(95.0, 5.0), Vector2(128.0, 0.0),
		]), Color(0.25, 0.38, 0.58, 0.8), 2.0, true)
	else:
		# 残影：低透明填充 + 全轮廓描边——保住刀形剪影（无描边会糊成弧形色带）
		draw_colored_polygon(blade, p_fill)
		draw_polyline(blade, p_line, 2.0, true)
	# 护手（径向短横档）+ 柄（近端深色握把，加粗保证可辨）
	draw_colored_polygon(PackedVector2Array([
		Vector2(34.0, -10.0), Vector2(38.0, -10.0), Vector2(38.0, 10.0), Vector2(34.0, 10.0),
	]), deep)
	draw_colored_polygon(PackedVector2Array([
		Vector2(6.0, -4.5), Vector2(34.0, -4.5), Vector2(34.0, 4.5), Vector2(6.0, 4.5),
	]), deep)

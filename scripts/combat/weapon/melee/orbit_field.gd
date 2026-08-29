# scripts/combat/weapon/melee/orbit_field.gd
# M-08 OrbitField（架构 §2.8.5）：环绕力场实体——浮游球绕本体公转 + 周期范围判定。
# · 公转推进：angle += angular_speed °/s（240°/s，A3 §3.8）；球位均匀相位分布。
# · 判定调度：每球对同一目标独立 hit_cd（"orb_idx:target_uid" 冷却表）；命中 →
#   武器侧 ctx 结算（面板快照展开）+ 击退（可打断自爆引导，AC-06.1）。
# · 生命周期：单武器常驻单例（OrbitWeapon 持有；tick 由武器驱动，随宿主平移）。
# · 表现（用户反馈 2026-08-29「力场特效没看见」→ 占位圆废弃）：薄荷绿光球（辉光底 +
#   珠核贴纸风）+ 虚线轨道环 + 公转扫掠残辉；命中 → 球体膨胀脉冲 + 命中点冲击小环。
class_name OrbitField
extends Node2D

const HIT_FLASH_COUNT := 8                    # 命中冲击小环并发池（轮换）
const HIT_FLASH_LIFE := 0.22                  # 命中小环时长 s
const PATH_DASHES := 26                       # 轨道虚线段数（奇数段绘制 = 虚线观感）

var orbs: int = 2                              # 浮游球数
var orbit_radius: float = 90.0
var angular_speed: float = 240.0               # °/s
var orb_radius: float = 16.0
var angle: float = 0.0                         # 公转相位（rad）
var knockback: float = 40.0
var target_hit_cd: Dictionary = {}             # "orb_idx:target_uid" -> 剩余冷却
var hit_cd: float = 0.5

var weapon: WeaponBase = null                  # 结算宿主（OrbitWeapon 注入）

var _orb_glows: Array[Sprite2D] = []           # 球体辉光底层（soft_dot 薄荷绿）
var _orb_cores: Array[Sprite2D] = []           # 球体珠核（bead 描边贴纸风）
var _orb_punch: Array[float] = []              # 命中膨胀脉冲（每球独立 0→1→0）
var _hit_flashes: Array[Dictionary] = []       # [{sprite, left}]（命中冲击小环池）
var _flash_idx: int = 0


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
	z_index = 4                                  # 敌/弹（z=0 树序层）之上、元素特效层（z=5）之下
	_build_visuals()
	queue_redraw()


func _build_visuals() -> void:
	# 表现件预建（spawn 期一次；球数在 spawn 时已定，运行期零实例化）
	if not _orb_cores.is_empty():
		return
	var mint := PopPalette.SUCCESS
	for i in range(orbs):
		var glow := Sprite2D.new()
		glow.name = "OrbGlow%d" % i
		glow.texture = TextureFactory.soft_dot(64)
		glow.modulate = Color(mint.r, mint.g, mint.b, 0.42)
		add_child(glow)
		_orb_glows.append(glow)
		var core := Sprite2D.new()
		core.name = "OrbCore%d" % i
		core.texture = TextureFactory.bead(mint.lerp(Color.WHITE, 0.55))
		add_child(core)
		_orb_cores.append(core)
		_orb_punch.append(0.0)
	var flash_col := mint.lerp(Color.WHITE, 0.25)
	for i in range(HIT_FLASH_COUNT):
		var sp := Sprite2D.new()
		sp.name = "HitFlash%d" % i
		sp.texture = TextureFactory.ring_tex(flash_col, 48, 4.0)
		sp.visible = false
		add_child(sp)
		_hit_flashes.append({"sprite": sp, "left": 0.0})


func tick(p_game_delta: float, p_center: Vector2) -> void:
	# 公转推进 + 球位更新 + 判定调度（每目标独立 hit_cd）+ 击退 + 表现推进
	position = p_center
	angle = wrapf(angle + deg_to_rad(angular_speed) * p_game_delta, 0.0, TAU)
	for key in target_hit_cd:
		target_hit_cd[key] = maxf(float(target_hit_cd[key]) - p_game_delta, 0.0)
	if weapon == null or weapon.enemy_grid == null:
		_update_orb_sprites(p_game_delta)
		queue_redraw()
		return
	for i in range(orbs):
		var orb_pos := _orb_position(i, p_center)
		_judge_orb(i, orb_pos, p_center)
	_update_orb_sprites(p_game_delta)
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
		_fire_hit_fx(p_orb_index, p_orb_pos)


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


func _update_orb_sprites(p_game_delta: float) -> void:
	# 球体表现推进：跟位 + 命中膨胀脉冲 + 辉光呼吸（本体 position = 轨道中心，局部零点）
	for i in range(orbs):
		if i >= _orb_cores.size():
			break
		var pos := _orb_position(i, Vector2.ZERO)
		var punch := float(_orb_punch[i])
		_orb_glows[i].position = pos
		_orb_cores[i].position = pos
		_orb_cores[i].rotation = angle * 3.0
		_orb_cores[i].scale = Vector2.ONE * (orb_radius / 32.0) * (1.0 + 0.38 * punch)
		_orb_glows[i].scale = Vector2.ONE * (orb_radius * 1.9 / 32.0) * (1.0 + 0.5 * punch)
		_orb_glows[i].modulate.a = 0.4 + 0.3 * punch + 0.07 * sin(angle * 3.0 + float(i) * 2.1)
		_orb_punch[i] = maxf(punch - p_game_delta * 5.0, 0.0)
	for flash: Dictionary in _hit_flashes:
		var left := float(flash["left"])
		if left <= 0.0:
			continue
		left = maxf(left - p_game_delta, 0.0)
		flash["left"] = left
		var sp: Sprite2D = flash["sprite"]
		if left <= 0.0:
			sp.visible = false
			continue
		var t := 1.0 - left / HIT_FLASH_LIFE
		sp.scale = Vector2.ONE * lerpf(orb_radius / 19.0, orb_radius * 2.2 / 19.0, t)
		sp.modulate.a = 0.85 * (1.0 - t)


func _fire_hit_fx(p_orb_index: int, p_orb_pos: Vector2) -> void:
	# 命中反馈：球体膨胀脉冲 + 命中点冲击小环（读得清「这球撞到东西了」）
	if p_orb_index < _orb_punch.size():
		_orb_punch[p_orb_index] = 1.0
	if _hit_flashes.is_empty():
		return
	var flash: Dictionary = _hit_flashes[_flash_idx % _hit_flashes.size()]
	_flash_idx += 1
	var sp: Sprite2D = flash["sprite"]
	sp.position = to_local(p_orb_pos)
	sp.rotation = randf() * TAU
	sp.visible = true
	flash["left"] = HIT_FLASH_LIFE


func _reset_state() -> void:
	# 清零契约（武器回收期）
	angle = 0.0
	target_hit_cd.clear()


func _draw() -> void:
	# 力场本体渲染：淡薄荷填充 + 虚线轨道环 + 公转扫掠残辉（占位圆已废——用户反馈）
	# + 底部数值标注（用户反馈二轮「下面还要有具体的值」：环绕数 / 单击伤害）
	if not visible:
		return
	var mint := PopPalette.SUCCESS
	draw_circle(Vector2.ZERO, orbit_radius, Color(mint.r, mint.g, mint.b, 0.07))
	var pulse := 0.5 + 0.5 * sin(angle * 2.0)
	draw_arc(Vector2.ZERO, orbit_radius, 0.0, TAU, 64,
		Color(mint.r, mint.g, mint.b, 0.05 + 0.04 * pulse), orbit_radius * 0.10, true)
	var seg_arc := TAU / float(PATH_DASHES)
	for i in range(PATH_DASHES):
		if i % 2 == 0:
			continue                            # 奇数段绘制 = 虚线
		var a0 := float(i) * seg_arc
		draw_arc(Vector2.ZERO, orbit_radius, a0, a0 + seg_arc, 5,
			Color(mint.r, mint.g, mint.b, 0.38), 2.4, true)
	# 扫掠残辉：公转相位后方 42° 渐隐厚弧（运动方向读感）
	var trail_a := angle - deg_to_rad(42.0)
	draw_arc(Vector2.ZERO, orbit_radius, trail_a, angle, 12,
		Color(mint.r, mint.g, mint.b, 0.18), orb_radius * 1.5, true)
	# 数值标注（力场下缘：环绕 ×N · 单击伤害；半透明贴纸风小字）
	var atk := 0.0
	if weapon != null and is_instance_valid(weapon):
		atk = float(weapon.build_panel_snapshot().get("base_atk", 0.0))
	var txt := "环绕 ×%d · %.0f/击" % [orbs, atk]
	var font := ThemeDB.fallback_font
	draw_string(font, Vector2(-60.0, orbit_radius + 22.0), txt,
		HORIZONTAL_ALIGNMENT_CENTER, 120.0, 13, Color(mint.r, mint.g, mint.b, 0.85))

# scripts/combat/weapon/melee/orbit_field.gd
# M-08 OrbitField（架构 §2.8.5）：环绕力场实体——浮游刀绕本体公转 + 周期范围判定。
# · 公转推进：angle += angular_speed °/s（240°/s，A3 §3.8）；刀位均匀相位分布。
# · 判定调度：每刀对同一目标独立 hit_cd（"orb_idx:target_uid" 冷却表）；命中 →
#   武器侧 ctx 结算（面板快照展开）+ 击退（可打断自爆引导，AC-06.1）。
# · 生命周期：单武器常驻单例（OrbitWeapon 持有；tick 由武器驱动，随宿主平移）。
# · 表现（R32 用户反馈「球太怪了，换成飞刀」）：默认 = 环绕飞刀（刀尖沿运动方向
#   回旋；钢白刀身 + 元素刀脊辉光 + 命中白闪）+ 虚线轨道环 + 公转扫掠残辉；
#   形态卡（sword 剑 / axe 斧 / bolt 闪电，R19）覆盖默认绘制。
class_name OrbitField
extends Node2D

const HIT_FLASH_COUNT := 8                    # 命中冲击小环并发池（轮换）
const HIT_FLASH_LIFE := 0.22                  # 命中小环时长 s
const PATH_DASHES := 26                       # 轨道虚线段数（奇数段绘制 = 虚线观感）

var style: String = "orb"                      # 环绕形态（orb 飞刀默认 / sword 剑 / axe 斧 / bolt 闪电，R19/R32；键名 orb 为卡组契约保持）
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
var _anim_t: float = 0.0                       # 表现时钟（bolt 颤动相位，R19）


func spawn(p_params: Dictionary) -> void:
	# 初始化（OrbitWeapon._ensure_orbit_field 构造 / refresh_orbit_field 重铺——球数增减即改）
	orbs = clampi(int(p_params.get("orbs", 2)), 1, 16)
	orbit_radius = maxf(float(p_params.get("orbit_radius", 90.0)), 1.0)
	angular_speed = float(p_params.get("angular_speed", 240.0))
	orb_radius = maxf(float(p_params.get("orb_radius", 16.0)), 1.0)
	knockback = float(p_params.get("knockback", 40.0))
	hit_cd = maxf(float(p_params.get("hit_cd", 0.5)), 0.01)
	style = String(p_params.get("style", "orb"))
	angle = 0.0
	target_hit_cd.clear()
	visible = true
	z_index = 4                                  # 敌/弹（z=0 树序层）之上、元素特效层（z=5）之下
	_build_visuals()
	_sync_orb_visibility()
	queue_redraw()


func _build_visuals() -> void:
	# 表现件预建（spawn 期一次；球数增长时补建差额——诺亚僚机召唤通道，P2；仅增量实例化）
	if _orb_cores.is_empty():
		var mint := PopPalette.SUCCESS
		var flash_col := mint.lerp(Color.WHITE, 0.25)
		for i in range(HIT_FLASH_COUNT):
			var sp := Sprite2D.new()
			sp.name = "HitFlash%d" % i
			sp.texture = TextureFactory.ring_tex(flash_col, 48, 4.0)
			sp.visible = false
			add_child(sp)
			_hit_flashes.append({"sprite": sp, "left": 0.0})
	var mint2 := PopPalette.SUCCESS
	while _orb_cores.size() < orbs:
		var i := _orb_cores.size()
		var glow := Sprite2D.new()
		glow.name = "OrbGlow%d" % i
		glow.texture = TextureFactory.soft_dot(64)
		glow.modulate = Color(mint2.r, mint2.g, mint2.b, 0.42)
		add_child(glow)
		_orb_glows.append(glow)
		var core := Sprite2D.new()
		core.name = "OrbCore%d" % i
		core.texture = TextureFactory.bead(mint2.lerp(Color.WHITE, 0.55))
		add_child(core)
		_orb_cores.append(core)
		_orb_punch.append(0.0)


func _sync_orb_visibility() -> void:
	# 球数收缩（还原通道）：超额球体隐藏（数组保留——再次召唤复用，不反复增删子节点）。
	# R32：默认 = 飞刀程序化绘制——珠核贴图一律隐藏（辉光保留作刀身底光）
	for i in range(_orb_cores.size()):
		_orb_cores[i].visible = false
		_orb_glows[i].visible = i < orbs


func tick(p_game_delta: float, p_center: Vector2) -> void:
	# 公转推进 + 球位更新 + 判定调度（每目标独立 hit_cd）+ 击退 + 表现推进
	# R10 根因修复：同弧斩——局部/全局坐标空间错配（环绕力场此前同样整场不可见）
	position = weapon.to_local(p_center) if weapon != null and is_instance_valid(weapon) 		else p_center
	_anim_t += p_game_delta
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
		# R32：辉光按元素染色（_orb_tint）——附魔刀的底光跟随元素色
		var tint := _orb_tint(i)
		_orb_glows[i].modulate = Color(tint.r, tint.g, tint.b,
			0.4 + 0.3 * punch + 0.07 * sin(angle * 3.0 + float(i) * 2.1))
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


func _draw_styled_orbs() -> void:
	# R19 形态环绕体（用户点名「剑/斧头/闪电自己扩展」）：
	# sword 裂空剑 = 径向外指的渐尖刃（蓝白）/ axe 裂空斧 = 柄+楔形斧头（金橙，厚重）/
	# bolt 雷霆 = 切向锯齿闪电（葡萄紫，高频颤动）。朝向/相位随公转角推进。
	for i in range(orbs):
		var pos := _orb_position(i, Vector2.ZERO)
		var phase := angle + TAU * float(i) / float(orbs)
		var dir := Vector2.from_angle(phase)              # 径向外指
		var tan := Vector2(-dir.y, dir.x)                 # 切向（运动方向）
		match style:
			&"sword":
				var tip := pos + dir * orb_radius * 1.35
				var base_c := pos - dir * orb_radius * 0.55
				var perp := tan * orb_radius * 0.30
				draw_colored_polygon(PackedVector2Array([
					tip, base_c + perp, base_c - perp]),
					Color(PopPalette.PLAYER.r, PopPalette.PLAYER.g, PopPalette.PLAYER.b, 0.95))
				draw_line(base_c - perp * 1.5, base_c + perp * 1.5,
					PopPalette.XP, 2.6, true)             # 护手
				draw_line(pos - dir * orb_radius * 0.5, pos - dir * orb_radius * 1.05,
					PopPalette.OUTLINE, 3.2, true)        # 剑柄
			&"axe":
				var handle_a := pos - dir * orb_radius * 0.9
				var handle_b := pos + dir * orb_radius * 0.6
				draw_line(handle_a, handle_b, PopPalette.OUTLINE, 4.0, true)   # 斧柄
				var head_c := pos + dir * orb_radius * 0.35
				var wedge := PackedVector2Array([
					head_c + tan * orb_radius * 0.85 + dir * orb_radius * 0.25,
					head_c + tan * orb_radius * 0.55 - dir * orb_radius * 0.30,
					head_c - tan * orb_radius * 0.10 - dir * orb_radius * 0.18,
				])
				draw_colored_polygon(wedge, PopPalette.XP)                     # 斧刃（外弧楔）
				draw_arc(head_c + dir * orb_radius * 0.1, orb_radius * 0.72,
					phase - PI * 0.5, phase + PI * 0.28, 10,
					Color(PopPalette.ENEMY.r, PopPalette.ENEMY.g, PopPalette.ENEMY.b, 0.9),
					3.4, true)
			&"bolt":
				var flicker := 0.7 + 0.3 * sin(_anim_t * 26.0 + float(i) * 2.3)
				var col := Color(PopPalette.SHOCK.r, PopPalette.SHOCK.g,
					PopPalette.SHOCK.b, clampf(flicker, 0.0, 1.0))
				var zig := PackedVector2Array()
				var origin := pos - dir * orb_radius * 0.9
				for seg in range(5):
					var seg_dir := tan.rotated(0.9 if seg % 2 == 0 else -0.9)
					zig.append(origin + seg_dir * orb_radius * (0.55 + 0.3 * float(seg)))
				draw_polyline(zig, col, 3.2, true)
				draw_circle(pos, 3.2, col)
			_:
				pass                                  # orb 默认：飞刀程序化绘制（_draw_flying_knives）


func _draw_flying_knives() -> void:
	# R32 默认形态重做（用户反馈「环绕力场球太怪了，换成飞刀」）：
	# 浮游体 = 环绕飞刀——刀尖沿运动方向（公转切向）回旋飞行；钢白刀身 +
	# 元素附魔刀脊辉光（_orb_tint 染色）+ 深色刀柄；命中 → 刀刃白闪脉冲。
	for i in range(orbs):
		var pos := _orb_position(i, Vector2.ZERO)
		var phase := angle + TAU * float(i) / float(orbs)
		var dir := Vector2.from_angle(phase)              # 径向
		var motion := Vector2(-dir.y, dir.x)              # 切向（运动方向 = 刀尖指向）
		var side := Vector2(-motion.y, motion.x)
		var punch := float(_orb_punch[i]) if i < _orb_punch.size() else 0.0
		var blade := orb_radius * (1.05 + 0.22 * punch)   # 刀体全长
		var w := orb_radius * 0.17                        # 半刀宽
		var tip := pos + motion * blade * 0.55
		var shoulder := pos + motion * blade * 0.08
		var base := pos - motion * blade * 0.45
		var steel := Color(0.93, 0.96, 1.0, 0.96)
		draw_colored_polygon(PackedVector2Array([
			tip, shoulder + side * w, base + side * w,
			base - side * w, shoulder - side * w,
		]), steel)
		# 刀脊元素辉光（附魔色；未附魔 = 薄荷绿）+ 刀尾护线
		var tint := _orb_tint(i)
		draw_line(shoulder + side * w * 0.9, tip, Color(tint.r, tint.g, tint.b, 0.9), 2.0, true)
		draw_line(base + side * w * 0.9, base - side * w * 0.9,
			Color(tint.r, tint.g, tint.b, 0.55), 2.0, true)
		# 刀柄（刀体后方短柄）
		draw_line(base, pos - motion * blade * 0.72, PopPalette.OUTLINE, 3.4, true)
		# 命中白闪（双刃边线，脉冲驱动）
		if punch > 0.01:
			var flash := Color(1.0, 1.0, 1.0, punch)
			var fl := 1.6 + 1.4 * punch
			draw_line(tip, base + side * w * 1.3, flash, fl, true)
			draw_line(tip, base - side * w * 1.3, flash, fl, true)


func _orb_tint(p_index: int) -> Color:
	# R26 元素附魔染色（无 ELE 卡 = 默认薄荷绿）。多元素共存按球错开——
	# 「一会红一会蓝」的环绕版：每球取一个附魔元素色（index 稳定映射）
	var elems: Array[int] = []
	if weapon != null and is_instance_valid(weapon) and weapon.trait_stack != null:
		for tb in weapon.trait_stack.traits:
			var td: Variant = tb.get("data")
			if td != null and int(td.pool) == GameConst.PoolClass.ELEM 					and (td as TraitData).params.has("element"):
				elems.append(int((td as TraitData).params["element"]))
	if elems.is_empty():
		return PopPalette.SUCCESS               # 无附魔 = 默认薄荷绿
	var e: int = elems[p_index % elems.size()]
	match e:
		GameConst.Element.FIR:
			return Color(1.0, 0.55, 0.3)
		GameConst.Element.ICE:
			return Color(0.62, 0.85, 1.0)
		GameConst.Element.LTG:
			return PopPalette.SHOCK
		_:
			return PopPalette.SUCCESS


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
	# R19 形态绘制（sword 剑 / axe 斧 / bolt 闪电——程序化多边形，贴图零实例化）
	# R32：默认 = 环绕飞刀（程序化绘制，不再是能量球）
	if style != "orb":
		_draw_styled_orbs()
	else:
		_draw_flying_knives()
	# 数值标注（力场下缘：环绕 ×N · 单击伤害；半透明贴纸风小字）
	var atk := 0.0
	if weapon != null and is_instance_valid(weapon):
		atk = float(weapon.build_panel_snapshot().get("base_atk", 0.0))
	var txt := "环绕 ×%d · %.0f/击" % [orbs, atk]
	var font := ThemeDB.fallback_font
	draw_string(font, Vector2(-60.0, orbit_radius + 22.0), txt,
		HORIZONTAL_ALIGNMENT_CENTER, 120.0, 13, Color(mint.r, mint.g, mint.b, 0.85))

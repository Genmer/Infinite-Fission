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
var leash_radius: float = 0.0                  # R65 追击活动半径（>0 = W9 追击模式；0 = W8 环绕模式不变）
var chase_speed: float = 420.0                 # R65 追击移速（px/s）
var engage_r: float = 46.0                     # R65 贴身开砍距离（刀心-目标心）
var knife_scale: float = 1.0                   # R65 巨刃词条：刀体视觉缩放
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
var _knife_pos: Array[Vector2] = []            # R65 逐刀位置（局部坐标，相对玩家）
var _knife_face: Array[float] = []             # R65 逐刀朝向（rad；追击=行进方向 / 环绕=切向）
var _knife_target: Array[Node2D] = []          # R65 逐刀当前目标（null = 无目标回轨）
var _last_center: Vector2 = Vector2.ZERO       # R65 最近宿主世界位（strike 世界位换算基准）


func spawn(p_params: Dictionary) -> void:
	# 初始化（OrbitWeapon._ensure_orbit_field 构造 / refresh_orbit_field 重铺——球数增减即改）
	orbs = clampi(int(p_params.get("orbs", 2)), 1, 16)
	orbit_radius = maxf(float(p_params.get("orbit_radius", 90.0)), 1.0)
	angular_speed = float(p_params.get("angular_speed", 240.0))
	orb_radius = maxf(float(p_params.get("orb_radius", 16.0)), 1.0)
	knockback = float(p_params.get("knockback", 40.0))
	hit_cd = maxf(float(p_params.get("hit_cd", 0.5)), 0.01)
	leash_radius = maxf(float(p_params.get("leash_radius", 0.0)), 0.0)
	chase_speed = maxf(float(p_params.get("chase_speed", 420.0)), 60.0)
	engage_r = maxf(float(p_params.get("engage_r", 46.0)), 8.0)
	knife_scale = maxf(float(p_params.get("knife_scale", 1.0)), 0.4)
	style = String(p_params.get("style", "orb"))
	angle = 0.0
	target_hit_cd.clear()
	visible = true
	z_index = 4                                  # 敌/弹（z=0 树序层）之上、元素特效层（z=5）之下
	_sync_knife_arrays()
	_build_visuals()
	_sync_orb_visibility()
	queue_redraw()


func _sync_knife_arrays() -> void:
	# R65 逐刀状态数组对齐 orbs（新增刀落位轨道槽；收缩保留——再扩复用）
	while _knife_pos.size() < orbs:
		var i := _knife_pos.size()
		_knife_pos.append(_orbit_slot(i))
		_knife_face.append(_knife_pos[i].angle() + PI * 0.5)
		_knife_target.append(null)
	if _knife_pos.size() > orbs:
		_knife_pos.resize(orbs)
		_knife_face.resize(orbs)
		_knife_target.resize(orbs)


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
		# R64 刀形可读化：光晕缩到刀体尺度（64→32px）并压暗——此前满幅光球的轮廓
		# 压过 17px 小刀，整体读感仍是「绿球不是飞刀」（用户四轮同类反馈的环绕版）
		glow.scale = Vector2.ONE * 0.5
		glow.modulate = Color(mint2.r, mint2.g, mint2.b, 0.26)
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
	_last_center = p_center
	_anim_t += p_game_delta
	angle = wrapf(angle + deg_to_rad(angular_speed) * p_game_delta, 0.0, TAU)
	for key in target_hit_cd:
		target_hit_cd[key] = maxf(float(target_hit_cd[key]) - p_game_delta, 0.0)
	if leash_radius > 0.0:
		# R65 W9 追击模式：逐刀索敌追击/回轨（无接触判定——伤害全部走挥砍弧）
		_tick_chase(p_game_delta, p_center)
		_update_orb_sprites(p_game_delta)
		queue_redraw()
		return
	# W8 环绕模式（口径不变）：刀位 = 轨道槽 + 逐球周期接触判定
	_sync_knife_arrays()
	for i in range(orbs):
		_knife_pos[i] = _orbit_slot(i)
		_knife_face[i] = _knife_pos[i].angle() + PI * 0.5
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


func _orbit_slot(p_index: int) -> Vector2:
	# R65 轨道槽位（局部偏移；环绕模式刀位 = 本槽，追击模式回归点）
	var phase := angle + TAU * float(p_index) / float(orbs)
	return Vector2(cos(phase), sin(phase)) * orbit_radius


func _tick_chase(p_game_delta: float, p_center: Vector2) -> void:
	# R65 W9 追击 AI：逐刀在活动半径（leash_radius）内索最近敌 → 追至贴身悬停；
	# 无敌 → 回轨道槽环绕。攻击判定不在本层（贴身开砍由 OrbitWeapon 消费
	# collect_engaged_strikes → ArcSlash 弧形判定——攻击范围口径零变化）。
	var candidates: Array[Node2D] = []
	if weapon != null and is_instance_valid(weapon) and weapon.enemy_grid != null:
		candidates.append_array(weapon.enemy_grid.query_circle(p_center, leash_radius))
	var step := chase_speed * p_game_delta
	for i in range(orbs):
		var target: Node2D = _pick_chase_target(candidates, p_center + _knife_pos[i],
			_knife_target[i])
		_knife_target[i] = target
		if target != null:
			var to_t: Vector2 = weapon.to_local(target.global_position) - _knife_pos[i]
			var dist := to_t.length()
			var dir := to_t / maxf(dist, 0.001)
			_knife_face[i] = dir.angle()
			if dist > engage_r * 0.55:
				_knife_pos[i] += dir * minf(step, maxf(dist - engage_r * 0.5, 0.0))
		else:
			var slot := _orbit_slot(i)
			var to_s: Vector2 = slot - _knife_pos[i]
			var d_s := to_s.length()
			if d_s > 0.5:
				_knife_pos[i] += (to_s / d_s) * minf(step, d_s)
				_knife_face[i] = to_s.angle()
			else:
				_knife_face[i] = slot.angle() + PI * 0.5
		# 活动半径硬钳（刀不离玩家超过 leash——「行动范围 250%」边界）
		if _knife_pos[i].length() > leash_radius:
			_knife_pos[i] = _knife_pos[i].normalized() * leash_radius


func _pick_chase_target(p_candidates: Array[Node2D], p_knife_world: Vector2,
		p_sticky: Node2D) -> Node2D:
	# 目标选取：粘性优先（现目标仍活且在候选内不换——防抖动）；否则取离刀最近者
	if p_sticky != null and is_instance_valid(p_sticky) and not bool(p_sticky.get("dead")) \
			and p_candidates.has(p_sticky):
		return p_sticky
	var best: Node2D = null
	var best_d := 1e9
	for cand in p_candidates:
		if cand == null or bool(cand.get("dead")):
			continue
		var d := p_knife_world.distance_to(cand.global_position)
		if d < best_d:
			best_d = d
			best = cand
	return best


func collect_engaged_strikes() -> Array[Dictionary]:
	# R65 贴身开砍点收集（OrbitWeapon 冷却就绪时消费）：
	# [{center: 世界刀位, facing: 刀→目标角}]；空表 = 刀还在路上（不消耗武器节拍）
	var out: Array[Dictionary] = []
	for i in range(orbs):
		var target: Node2D = _knife_target[i]
		if target == null or not is_instance_valid(target) or bool(target.get("dead")):
			continue
		var knife_world := _last_center + _knife_pos[i]
		var to_t: Vector2 = target.global_position - knife_world
		if to_t.length() <= engage_r + float(target.get("hitbox_r")):
			out.append({
				"center": knife_world,
				"facing": to_t.angle(),
				"index": i,
			})
	return out


func _update_orb_sprites(p_game_delta: float) -> void:
	# 球体表现推进：跟位（R65：逐刀位 _knife_pos——环绕=轨道槽/追击=追击位）+
	# 命中膨胀脉冲 + 辉光呼吸（本体 position = 轨道中心，局部零点）
	for i in range(orbs):
		if i >= _orb_cores.size():
			break
		var pos := _knife_pos[i] if i < _knife_pos.size() else _orbit_slot(i)
		var punch := float(_orb_punch[i])
		_orb_glows[i].position = pos
		_orb_cores[i].position = pos
		_orb_cores[i].rotation = angle * 3.0
		_orb_cores[i].scale = Vector2.ONE * (orb_radius / 32.0) * (1.0 + 0.38 * punch)
		_orb_glows[i].scale = Vector2.ONE * (orb_radius * 1.9 / 32.0) * (1.0 + 0.5 * punch) * knife_scale
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
	# sword 裂空剑 = 径向外指的渐尖刃（蓝白）/ axe 裂空斧 = 双手战斧（R34 重做：
	# 长柄+双层宽刃+配重锤头，金橙）/ bolt 雷霆 = 纯电弧（R34 重做：折线主干+
	# 分叉副枝+端点火花星，废除紫球圆点标记）。朝向/相位随公转角推进。
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
				# R34 斧形态重做（用户反馈「斧头也太儿戏了」）：厚重双手战斧——
				# 深色长柄贯穿 + 双层宽刃（外弧金橙主刃 + 内层亮黄高光刃）+ 背部配重锤头
				var handle_a := pos - dir * orb_radius * 1.05
				var handle_b := pos + dir * orb_radius * 0.55
				draw_line(handle_a, handle_b, PopPalette.OUTLINE, 5.2, true)   # 长柄
				draw_circle(handle_a, orb_radius * 0.22,
					Color(PopPalette.XP.r, PopPalette.XP.g, PopPalette.XP.b, 0.9))  # 柄尾缠头
				# 配重锤头（柄背侧——厚重感来源）
				var back := pos - dir * orb_radius * 0.28
				draw_circle(back, orb_radius * 0.34,
					Color(PopPalette.OUTLINE.r, PopPalette.OUTLINE.g, PopPalette.OUTLINE.b, 0.95))
				# 主刃：外弧楔（金橙）
				var head_c := pos + dir * orb_radius * 0.30
				var wedge := PackedVector2Array([
					head_c + tan * orb_radius * 1.05 + dir * orb_radius * 0.30,
					head_c + tan * orb_radius * 0.62 - dir * orb_radius * 0.34,
					head_c - tan * orb_radius * 0.06 - dir * orb_radius * 0.20,
				])
				draw_colored_polygon(wedge, PopPalette.XP)
				# 高光内刃（亮黄小楔——开锋读感）
				var edge := PackedVector2Array([
					head_c + tan * orb_radius * 0.95 + dir * orb_radius * 0.26,
					head_c + tan * orb_radius * 0.55 - dir * orb_radius * 0.28,
					head_c - tan * orb_radius * 0.02 - dir * orb_radius * 0.16,
				])
				draw_colored_polygon(edge, Color(1.0, 0.92, 0.55, 0.95))
				# 刃口弧线（外缘白线——锋利轮廓）
				draw_arc(head_c + dir * orb_radius * 0.12, orb_radius * 0.95,
					phase - PI * 0.52, phase + PI * 0.30, 12,
					Color(1.0, 1.0, 1.0, 0.85), 2.6, true)
			&"bolt":
				# R34 闪电形态重做（用户反馈「闪电的紫色球怎么还在」）：紫球是 bolt
				# 画法末端的小圆点（r3.2 球心标记）——废除。现 = 纯电弧：高频颤动
				# 折线主干 + 分叉副枝 + 端点火花星（无任何球状元素）
				var flicker := 0.7 + 0.3 * sin(_anim_t * 26.0 + float(i) * 2.3)
				var col := Color(PopPalette.SHOCK.r, PopPalette.SHOCK.g,
					PopPalette.SHOCK.b, clampf(flicker, 0.0, 1.0))
				var origin := pos - dir * orb_radius * 0.9
				var joints: Array[Vector2] = [origin]
				for seg in range(4):
					var seg_dir := tan.rotated(0.9 if seg % 2 == 0 else -0.9)
					joints.append(origin + seg_dir * orb_radius * (0.5 + 0.32 * float(seg)))
				draw_polyline(PackedVector2Array(joints), col, 3.4, true)
				# 分叉副枝（中段节点 → 切向斜出短线）
				var branch_from: Vector2 = joints[2]
				draw_line(branch_from, branch_from + tan.rotated(1.5) * orb_radius * 0.5,
					Color(col.r, col.g, col.b, col.a * 0.7), 2.2, true)
				draw_line(branch_from, branch_from + tan.rotated(-1.7) * orb_radius * 0.4,
					Color(col.r, col.g, col.b, col.a * 0.6), 2.0, true)
				# 端点火花星（四向短线——放电读感，替代原球心圆点）
				var tip_j: Vector2 = joints[-1]
				for k in range(4):
					var spark_dir := Vector2.from_angle(TAU * float(k) / 4.0 + _anim_t * 6.0)
					draw_line(tip_j, tip_j + spark_dir * orb_radius * 0.26,
						Color(1.0, 1.0, 1.0, col.a), 1.8, true)
			_:
				pass                                  # orb 默认：飞刀程序化绘制（_draw_flying_knives）


func _draw_flying_knives() -> void:
	# R32 默认形态重做（用户反馈「环绕力场球太怪了，换成飞刀」）：
	# 浮游体 = 环绕飞刀——刀尖沿运动方向（公转切向）回旋飞行；钢白刀身 +
	# 元素附魔刀脊辉光（_orb_tint 染色）+ 深色刀柄；命中 → 刀刃白闪脉冲。
	# R64 刀形可读化：刀长原 = orb_radius×1.05（≈17px），比光晕球还小，读感仍
	# 「绿点不是刀」——刀体加长度下限（判定半径 orb_radius 不动，视觉>判定是
	# 动作游戏惯例）+ 全轮廓亮描边 + 刃口亮线，刀形一眼可辨。
	for i in range(orbs):
		var pos := _knife_pos[i] if i < _knife_pos.size() else _orbit_slot(i)
		var face := _knife_face[i] if i < _knife_face.size() else pos.angle() + PI * 0.5
		var motion := Vector2.from_angle(face)          # R65：追击=行进方向 / 环绕=切向
		var side := Vector2(-motion.y, motion.x)
		var punch := float(_orb_punch[i]) if i < _orb_punch.size() else 0.0
		var blade := maxf(orb_radius * 1.05, 34.0) * (1.05 + 0.22 * punch) * knife_scale   # 刀体全长（R65 巨刃缩放）
		var w := maxf(orb_radius * 0.17, 3.4) * knife_scale                              # 半刀宽
		var tip := pos + motion * blade * 0.55
		var shoulder := pos + motion * blade * 0.08
		var base := pos - motion * blade * 0.45
		var steel := Color(0.93, 0.96, 1.0, 0.96)
		var body := PackedVector2Array([
			tip, shoulder + side * w, base + side * w,
			base - side * w, shoulder - side * w,
		])
		draw_colored_polygon(body, steel)
		# 全轮廓亮描边（深底上压出刀形剪影——R61 弧斩同款手法）
		draw_polyline(body, Color(1.0, 1.0, 1.0, 0.85), 1.8, true)
		# 刀脊元素辉光（附魔色；未附魔 = 薄荷绿）+ 刀尾护线
		var tint := _orb_tint(i)
		draw_line(shoulder + side * w * 0.9, tip, Color(tint.r, tint.g, tint.b, 0.9), 2.4, true)
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
	# R65 追击模式：环示 = 活动范围（leash_radius，更淡——「刀能跑多远」）；
	# 环绕模式口径不变（轨道环 = orbit_radius）
	if not visible:
		return
	var mint := PopPalette.SUCCESS
	var ring_r := orbit_radius
	var ring_a_faint := 0.07
	if leash_radius > 0.0:
		ring_r = leash_radius
		ring_a_faint = 0.045
	draw_circle(Vector2.ZERO, ring_r, Color(mint.r, mint.g, mint.b, ring_a_faint))
	var pulse := 0.5 + 0.5 * sin(angle * 2.0)
	draw_arc(Vector2.ZERO, ring_r, 0.0, TAU, 64,
		Color(mint.r, mint.g, mint.b, 0.05 + 0.04 * pulse), orbit_radius * 0.10, true)
	var seg_arc := TAU / float(PATH_DASHES)
	for i in range(PATH_DASHES):
		if i % 2 == 0:
			continue                            # 奇数段绘制 = 虚线
		var a0 := float(i) * seg_arc
		draw_arc(Vector2.ZERO, ring_r, a0, a0 + seg_arc, 5,
			Color(mint.r, mint.g, mint.b, 0.38), 2.4, true)
	# 扫掠残辉：公转相位后方 42° 渐隐厚弧（运动方向读感；追击模式无公转带——不画）
	if leash_radius <= 0.0:
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
	var fmt := "环绕 ×%d · %.0f/击"
	if leash_radius > 0.0:
		fmt = "追击 ×%d · %.0f/斩"
	var txt := fmt % [orbs, atk]
	var font := ThemeDB.fallback_font
	draw_string(font, Vector2(-60.0, orbit_radius + 22.0), txt,
		HORIZONTAL_ALIGNMENT_CENTER, 120.0, 13, Color(mint.r, mint.g, mint.b, 0.85))

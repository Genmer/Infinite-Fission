# scripts/combat/weapon/melee/ground_axe_weapon.gd
# R243 W12 法器·裂地斧 GroundAxeWeapon（设计 §2.3，w2-liedifu 交付）：
# · 每拍（cd 3.6→2.8 通道，WeaponBase._fire_interval 非弹道分支）向最近敌位置快照
#   target_point 掷斧（640px/s；目标中途死亡不重锁——落点发射时锁定）。
# · 斧体 = 真投射物幽灵飞行（projectile_base "flight_axe" 键：_check_collision 对敌
#   整体跳过——飞行途中无接触伤；抵达判定/寿命兜底在弹侧 _axe_step/_axe_land）。
# · 飞行路径消弹（R243 评审修复——设计 §3.2 W12「飞行接触同灵剑」）：每 tick 逐柄
#   在场斧 query_circle(斧位, effective_radius()+4) 全消（nullify=true → 1.0 确定性），
#   帽 6/斧/tick（性能护栏）——flying_sword_weapon._tick_path_nullify 同构。
# · 抵达（距 target_point ≤24px 或寿命尽）→ 弹侧回调本侧 on_axe_land(pos)：
#   震荡结算（仿 OrbitField._detonate_aoe 窄相骨架）+ 落点清弹 + GroundShockFx 裂地特效，
#   随后弹侧 _recycle(FORCED)（回收点即斧的 ON_EXPIRE 触发点——挂 MEC_FRACTAL 时子斧
#   由 projectile_base.request_split 斧分支派生，子斧落地走同一 on_axe_land 二次迷你震荡）。
# · 数量挂点：斧群 = 1 + min(_orbit_link_count(), 3)。
# · 质变「崩山击」（w4-prime §7.2）：震荡半径尾乘 transcend.radius_mult（×1.25）+
#   外环震荡（半径 ×ring_mult 1.6 / 伤害 ×ring_ratio 0.4，同 _shock_uid 幂等分流——
#   重叠带由管线 (source,target,frame) 幂等闸去重）+ GroundShockFx 双环外环臂
#  （ring_radius>0 时滞后扩张的第二道冲击环）。
# · 图标：static func weapon_icon_tex(p_transcended)——texture_factory 委托臂消费；
#   贴图生成在本脚本内（不动共享 TextureFactory，栅格内核复用其 static 光栅化口）。
class_name GroundAxeWeapon
extends WeaponBase

const THROW_SPEED_DEFAULT := 640.0        # 掷斧速度缺省（.tres melee.throw_speed 键覆写）
const SHOCK_RADIUS_DEFAULT := 96.0        # 震荡半径缺省（.tres melee.shock_radius 键覆写）
const AXE_ACQUIRE_RADIUS := 1600.0        # 掷斧索敌半径（WeaponBase.acquire_target 同域）
const AXE_COUNT_BONUS_CAP := 3            # MEC_ORBIT_LINK 斧群加成帽（额外 +3 封顶 §4.3）
const OVERLAP_OFFSET_DEG := 20.0          # 不足重叠首目标的错位角（±20° 递增 §4.3）
const AXE_CLEAR_CAP := 24                 # 落点清弹帽/次（复活清弹帽先例 player.gd:133-134）
const AXE_PATH_CLEAR_MARGIN := 4.0        # 飞行路径消弹查询余量（判定半径+4，灵剑同式 §3.2）
const AXE_PATH_CLEAR_CAP := 6             # 单斧单 tick 路径消弹帽（性能护栏，灵剑同式）
const LIFETIME_MARGIN := 1.15             # 寿命余量系数（dist/speed ×1.15——w11 射程同式）
const LIFETIME_FLOOR := 0.2               # 寿命地板 s（防零距离除零/过短）
const SHOCK_LIFETIME_MULT := 1.0          # 震荡伤害源口径（全额无衰减，§2.3 数值表注）

var _enemy_bullet_grid: SpaceGrid = null   # 敌弹网格（落点/路径清弹查询——deps 注入，OrbitWeapon 同式）
var _axes: Array[Node2D] = []              # 本武器在场掷斧引用（路径消弹驱动面；回收即出列）
var _shock_uid: int = 0                    # 本次震荡幂等 source_uid（每落地 GameConst.next_uid() 新签）

# ── 观测口（专项套件断言消费；生产零读——赋值成本可忽略） ──
var land_count: int = 0                    # 累计落地次数（母斧 + 子斧同一入口）
var last_land_pos: Vector2 = Vector2.ZERO  # 最近一次落地位置
var last_land_shock_radius: float = 0.0    # 最近一次震荡半径终值（含 shock_scale/G/Σadd_range/质变）
var last_land_shock_scale: float = 1.0     # 最近一次落地弹体 shock_scale 读回
var last_land_ring_radius: float = 0.0     # R243 §7.2 最近一次外环半径（0 = 未质变未触发）
var last_fx: Node2D = null                 # 最近一次裂地特效节点引用（0.35s 自毁）

static var _icon_cache: Dictionary = {}    # 图标本地缓存（键 base/t2——勿写 TextureFactory 共享缓存）


func setup(p_data: WeaponData, p_player: Node2D, p_deps: Dictionary) -> void:
	super(p_data, p_player, p_deps)
	_enemy_bullet_grid = p_deps.get("enemy_bullet_grid")
	_axes.clear()
	_shock_uid = 0
	land_count = 0
	last_land_pos = Vector2.ZERO
	last_land_shock_radius = 0.0
	last_land_shock_scale = 1.0
	last_land_ring_radius = 0.0
	last_fx = null


func try_fire() -> bool:
	# 每拍掷斧：斧群 = 1 + min(_orbit_link_count(), 3)（§4.3 W12 帽）；第 i 斧掷向
	# 第 i 近敌位置快照（target_point——飞行中目标死亡不重锁）；不足重叠首目标 ±20° 错位。
	if data == null or projectile_pool == null or enemy_grid == null:
		return false
	var plans := _acquire_throw_plans(axe_count())
	if plans.is_empty():
		return false
	var speed := maxf(float(data.melee.get("throw_speed", THROW_SPEED_DEFAULT)), 1.0)
	var panel_snap := build_panel_snapshot()
	var elems := _element_pool()
	var thrown := 0
	for plan in plans:
		var proj := projectile_pool.acquire() as ProjectileBase
		if proj == null:
			DebugStats.count(&"w12_axe_dropped")   # 池满丢弃（AC-14.4 同口径）
			break
		_inject_projectile_deps(proj)
		var from := muzzle_position()
		var to: Vector2 = plan["point"]
		var dir := to - from
		if dir.length_squared() < 1.0:
			dir = Vector2.UP                       # 零距离异常桩兜底（同 aim_direction 地板）
		var dist := dir.length()
		proj.spawn({
			"position": from,
			"velocity": dir.normalized() * speed,
			"lifetime": dist / speed * LIFETIME_MARGIN + LIFETIME_FLOOR,
			"pierce": 1,
			"hitbox_radius": maxf(float(data.hitbox_r), 1.0),
			"element": _element_pick(elems),
			"attach_value": 0.0,
			"generation": 0,
			"weapon_uid": uid,
			"weapon_ref": self,
			"panel_snapshot": panel_snap,
			"trait_stack": trait_stack.acquire_runtime() if trait_stack != null else null,
			"team": 0,
			# ── R243 掷斧形态键集（§2.3 spawn 键集——分裂/迸发/元素词条随斧运行前提） ──
			"flight_axe": true,
			"target_point": to,                    # 落点快照（目标中途死亡不重锁）
			"shock_scale": 1.0,                    # 母斧恒 1.0（子斧 = inherit_ratio，弹侧写）
			"attach_elements": elems.duplicate(),
		})
		# 池节点复用防重（灵剑 _swords 同式）：擦陈旧引用再入列——防池 LIFO 复用同节点时
		# 同斧双引用、路径消弹循环对一柄斧跑多轮
		_axes.erase(proj)
		_axes.append(proj)
		thrown += 1
	if thrown > 0:
		# 二cu 法器合一（用户「另外俩都按这个标准做」）：掷出即化身出击——环绕斧化身
		# 本身扑向首斧落点再回环（W10 回旋刃出击读感同标准）；纯表现，无口环境静默跳过
		if player != null and is_instance_valid(player) and player.has_method(&"weapon_avatar_sortie"):
			player.call(&"weapon_avatar_sortie", self, plans[0]["point"])
	return thrown > 0


func muzzle_position() -> Vector2:
	# 二cu 合一：掷斧从悬浮化身斧刃出膛（弹道武器同口径 _avatar_muzzle——化身出击
	# 期间实时跟随出击位，本尊在环位兜底）
	return _avatar_muzzle()


func _on_tick_post(p_game_delta: float) -> void:
	# 飞斧飞行路径消弹（§3.2 W12「飞行接触同灵剑」——评审修复补齐）
	_tick_path_nullify()


func axe_count() -> int:
	# 斧群数量（§4.3 W12 消费侧带帽：基础 1 + ORBIT_LINK 计算值 min(·,3)）
	return 1 + mini(_orbit_link_count(), AXE_COUNT_BONUS_CAP)


func on_axe_land(p_pos: Vector2) -> void:
	# ★ 斧落地结算口（projectile_base._axe_land 消费——§2.3 落地时序第一步；随后弹侧
	# _recycle(FORCED)→ON_EXPIRE→FRACTAL 子斧）。弹体 shock_scale 缺省 1.0 缩放震荡半径；
	# 伤害读弹体面板（母斧 = 武器面板；FRACTAL 子斧面板已按 inherit_ratio 预缩——设计
	# §2.3「子斧伤害缩减自动成立」，本侧不二次乘 shock_scale 防 0.4×0.4 双缩）。
	var shock_scale := 1.0
	var dmg := -1.0
	var lander := _find_lander(p_pos)
	if lander != null:
		shock_scale = maxf(float(lander.get("_shock_scale")), 0.0)
		var snap: Variant = lander.get("panel_snapshot")
		if snap is Dictionary and float((snap as Dictionary).get("base_atk", 0.0)) > 0.0:
			dmg = float((snap as Dictionary).get("base_atk", 0.0))
	if dmg < 0.0:
		dmg = float(build_panel_snapshot().get("base_atk", 0.0))   # 弹体面板缺失回落武器面板
	_shock_uid = GameConst.next_uid()          # 幂等 source_uid 每落地新签（管线 (source,target,frame) 分流先例 orbit_field.gd:81-83）
	var radius := _shock_radius() * shock_scale
	land_count += 1
	last_land_pos = p_pos
	last_land_shock_radius = radius
	last_land_shock_scale = shock_scale
	_settle_shock(p_pos, radius, dmg)
	_nullify_enemy_bullets(p_pos, radius)
	# w4 外环震荡挂点（质变 ring_mult/ring_ratio，同 _shock_uid 幂等分流；pre-w4 恒空不触发）。
	# R243 §7.2 崩山击：外环半径 = 内环终值 × ring_mult（1.6——含 radius_mult 尾乘：
	# 96×1.25×1.6=204.8）、伤害 ×ring_ratio（0.4）；同 _shock_uid = 与内环同帧同目标
	# 由管线幂等闸去重（重叠带不双吃），外环独占带（内环外）独立结算。
	var ring_radius := 0.0
	var ring := _outer_ring_cfg()
	if not ring.is_empty() and float(ring.get("ring_mult", 0.0)) > 0.0:
		var ring_ratio := maxf(float(ring.get("ring_ratio", 0.4)), 0.0)
		ring_radius = radius * float(ring.get("ring_mult"))
		last_land_ring_radius = ring_radius
		_settle_shock(p_pos, ring_radius, dmg * ring_ratio)
	else:
		last_land_ring_radius = 0.0
	last_fx = _launch_shock_fx(p_pos, radius, ring_radius)
	_feel_land_trauma()                        # R243 可选8：落地震屏（CATALYST 档）
	DebugStats.count(&"axe_landings")


func _feel_land_trauma() -> void:
	# 巨斧落地震屏（R243 评审可选8——「仪式感」；player.gd 复活演出同款 game_feel 组
	# 取节点）：CATALYST 档（trauma 0.5——裂地重量级读感，重于导弹爆 CRIT 档、轻于
	# BOSS_DEATH）。设置页震屏开关由 add_trauma_for_level 内部短路承担；headless/
	# 无 game_feel 节点零副作用。
	var tree := get_tree()
	if tree == null:
		return
	var feel := tree.get_first_node_in_group(&"game_feel")
	if feel != null and feel.has_method(&"add_trauma_for_level"):
		feel.call(&"add_trauma_for_level", GameConst.FeelLevel.CATALYST)


func _shock_radius() -> float:
	# R_shock = shock_radius_levels[L] × (1+0.15×G) × (1+Σadd_range) × transcend.radius_mult
	# 第一乘项 = MEC_GIANT_BLADE 层数（0.15/层对齐 DETONATE_RADIUS_PER_LAYER 单源）；
	# 第二乘项 = AFF_RANGE 消费点（§4.6② 反死卡）。
	# R243 §7.2 崩山击尾乘 = transcend.radius_mult（×1.25，仅质变；未质变恒 1.0 零位移）。
	# 掷斧射程不吃 add_range（锁定目标位置）。
	if data == null:
		return 0.0
	return _leveled_param("shock_radius", float(data.melee.get("shock_radius", SHOCK_RADIUS_DEFAULT))) \
		* (1.0 + OrbitField.DETONATE_RADIUS_PER_LAYER * float(_giant_blade_layers())) \
		* _range_mult() * _tc_mult("radius_mult", 1.0)


func _settle_shock(p_pos: Vector2, p_radius: float, p_dmg: float) -> void:
	# 落地震荡结算（仿 OrbitField._detonate_aoe 窄相骨架 orbit_field.gd:476-507）：
	# enemy_grid.query_circle 粗相 → dist ≤ R+target.hitbox_r 窄相精判 → 逐目标
	# DamageContext（source_uid=_shock_uid / base_atk=面板终值 / HIT_IS_AOE_SECONDARY /
	# element=_element_pick）→ ON_HIT 四件套（§2.3-4/§4.4 迸裂/暴击词条对震荡生效）→
	# resolve → attach_requests 消费（§6.4 空=inert）→ 径向击退（MEC_KNOCK 消费点）。
	if enemy_grid == null or damage_pipeline == null or data == null:
		return
	var candidates: Array[Node2D] = []
	candidates.append_array(enemy_grid.query_circle(p_pos, p_radius))
	var elems := _element_pool()
	var element := _element_pick(elems)       # 伤害元素逐震荡单掷（抗性入参形态；附着走 host_elements 全池）
	var knock := _axe_knockback()
	for target in candidates:
		if target == null or bool(target.get("dead")):
			continue
		if (target as Node2D).global_position.distance_to(p_pos) \
				> p_radius + float(target.get("hitbox_r")):
			continue                              # 窄相精判（AoE 半径口径真值）
		var ctx := build_damage_context(target)
		ctx.source_uid = _shock_uid
		ctx.base_atk = maxf(p_dmg * SHOCK_LIFETIME_MULT, 0.0)
		ctx.hit_flags |= GameConst.HIT_IS_AOE_SECONDARY
		ctx.element = element
		var tctx := TraitContext.new()
		tctx.event = GameConst.TraitEvent.ON_HIT
		tctx.weapon = self
		tctx.melee = self
		tctx.target = target
		tctx.damage_ctx = ctx
		tctx.host_elements = elems.duplicate()    # §6.4 守卫输入（ELE 卡全放行）
		if trait_stack != null:
			for pool in trait_stack.collect_mult_pools(tctx):
				ctx.mult_pools.append(pool)
		inject_vuln_pool(ctx, target)
		if trait_stack != null:
			trait_stack.dispatch(GameConst.TraitEvent.ON_HIT, tctx)
		var result: DamageResult = damage_pipeline.call(&"resolve", ctx)
		# 落血口径双轨（同 _detonate_aoe/_charge_settle）：真件 resolve 内部已落血；透传桩由调用方落血
		if result != null and not (damage_pipeline is DamagePipeline) \
				and target.has_method(&"take_result"):
			target.call(&"take_result", result)
		# R243 评审可选8：复用 W8 引爆大字通道（EventBus.w8_detonated → popup_manager
		# CHARGE_BURST 大字，值 = 该敌本帧结算聚合 orbit_field.gd 同款先例）播震荡结算值
		# ——w8_detonations 计数不在此写（W8 武器侧单一写点防双计）；外环与内环同帧同
		# 目标二次发射时聚合已消费、值 ≤0 早退（大字自然合并，零双字）。
		if EventBus.has_signal(&"w8_detonated"):
			EventBus.call(&"emit_w8_detonated", (target as Node2D).global_position,
				int(target.get("uid")))
		if elemental != null:
			for request in tctx.attach_requests:
				elemental.call(&"apply_attach", target, int(request.get("element", 0)),
					float(request.get("value", 0.0)), {
						"snapshot": result.final_value if result != null else 0.0,
						"overrides": request.get("overrides", {}),
					})
		_apply_shock_knockback(target, p_pos, knock)
		DebugStats.count(&"axe_shock_targets")


func _nullify_enemy_bullets(p_pos: Vector2, p_radius: float) -> void:
	# 落点清弹（法器 100% 确定性，§3.2 W12 落点域）：enemy_bullet_grid.query_circle(pos, R)
	# 全部 nullify()（涟漪 + NULLIFIED 统一收束）；帽 24/次（复活清弹帽先例 player.gd:133-134）。
	if _enemy_bullet_grid == null:
		return
	var cleared := 0
	for b in _enemy_bullet_grid.query_circle(p_pos, p_radius):
		if cleared >= AXE_CLEAR_CAP:
			break
		if is_instance_valid(b) and b is ProjectileBase and (b as ProjectileBase).team == 1:
			EventBus.emit_bullet_nullified((b as Node2D).global_position)
			(b as ProjectileBase).nullify()
			cleared += 1
			DebugStats.count(&"axe_bullets_cleared")


func _tick_path_nullify() -> void:
	# 飞斧飞行路径消弹（§3.2 W12「飞行接触同灵剑（帽 6/tick）」——100% 消弹域走廊）：
	# 每 tick 逐柄在场斧 query_circle(斧位, effective_radius()+4) → 逐弹掷骰统一口
	#（bullet_block_chance()：W12 nullify=true → 1.0 确定性全消）；帽 6/斧/tick。
	# 出列判据：引用失效 / is_clean（已回收）/ weapon_uid 易主（池节点复用防串弹）。
	# 飞行走廊消弹与落地震荡消弹互补——斧沿途经过的弹幕即清（灵剑
	# flying_sword_weapon._tick_path_nullify 同构）。
	if _enemy_bullet_grid == null or _axes.is_empty():
		return
	var chance := bullet_block_chance()
	if chance <= 0.0:
		return
	var kept: Array[Node2D] = []
	for axe in _axes:
		if not is_instance_valid(axe):
			continue
		var pb := axe as ProjectileBase
		if pb == null or pb.is_clean or pb.weapon_uid != uid:
			continue                              # 已回收（落地/超程）/ 池节点易主——出列
		kept.append(axe)
		var bullets: Array[Node2D] = []
		bullets.append_array(_enemy_bullet_grid.query_circle(
			pb.global_position, pb.effective_radius() + AXE_PATH_CLEAR_MARGIN))
		var cleared := 0
		for bullet in bullets:
			if cleared >= AXE_PATH_CLEAR_CAP:
				break                             # 帽 6/tick（弹幕洪峰护栏，灵剑同式）
			var eb := bullet as ProjectileBase
			if eb == null or eb.team != 1 or eb.is_clean:
				continue                          # 只消在场敌弹（回收态/我方弹跳过）
			if chance < 1.0 and randf() >= chance:
				continue                          # 概率掷骰（法器 1.0 = 确定性短路）
			eb.nullify()                          # → NULLIFIED 统一收束（弹池回收）
			cleared += 1
			DebugStats.count(&"bullet_parry")     # 统一掷骰口计数（§3.1）
			EventBus.emit_bullet_nullified(eb.global_position)
	_axes = kept


func _apply_shock_knockback(p_target: Node2D, p_pos: Vector2, p_force: float) -> void:
	# 震荡击退（MEC_KNOCK W12 消费点 §2.3-6）：落点→目标心径向 100%、切向 0（「跌开」
	# 读感）；敌侧通道 = Enemy.knockback（质量分级/冲量衰减/引导打断契约不变）。
	if p_force <= 0.0 or p_target == null or not is_instance_valid(p_target) \
			or not p_target.has_method(&"knockback"):
		return
	var dir := (p_target as Node2D).global_position - p_pos
	if dir.length() < 0.01:
		return
	p_target.call(&"knockback", dir.normalized() * p_force)


func _axe_knockback() -> float:
	# 击退力 = melee.knockback(80) + Σadd_knock（平加池先例 weapon_base.knockback_force
	# weapon_base.gd:454——W12 击退真源在 melee 段，故本侧平加式自读）。
	if data == null:
		return 0.0
	var kb := float(data.melee.get("knockback", 0.0))
	if trait_stack != null:
		kb += float(trait_stack.aggregate_panel().get("add_knock", 0.0))
	return maxf(kb, 0.0)


func _acquire_throw_plans(p_count: int) -> Array[Dictionary]:
	# 掷斧计划集：第 i 斧 → 第 i 近敌位置快照；不足时重叠首目标 ±20° 递增错位落点。
	var plans: Array[Dictionary] = []
	if p_count < 1 or enemy_grid == null:
		return plans
	var from := muzzle_position()
	var sorted: Array[Node2D] = []
	for cand in enemy_grid.query_circle(from, AXE_ACQUIRE_RADIUS):
		if cand != null and not bool(cand.get("dead")):
			sorted.append(cand)
	sorted.sort_custom(_nearer_from.bind(from))
	for i in range(p_count):
		if i < sorted.size():
			plans.append({"point": (sorted[i] as Node2D).global_position, "target": sorted[i]})
		elif not plans.is_empty():
			# 不足：重叠首目标 ±20°×递增错位（+20/-20/+40……出掷角域，落点随距离外推）
			var rel: Vector2 = plans[0]["point"] - from
			var steps := (i + 1) / 2                  # 整除递增档
			var side := 1.0 if (i % 2) == 1 else -1.0
			plans.append({"point": from + rel.rotated(deg_to_rad(OVERLAP_OFFSET_DEG) * side * float(steps)),
				"target": plans[0]["target"]})
	return plans


func _nearer_from(p_a: Node2D, p_b: Node2D, p_from: Vector2) -> bool:
	# 索敌距离序比较（sort_custom bind 载体——第 i 斧掷第 i 近敌）
	return p_from.distance_squared_to(p_a.global_position) \
		< p_from.distance_squared_to(p_b.global_position)


func _find_lander(p_pos: Vector2) -> ProjectileBase:
	# 落地斧识别（on_axe_land 只收 pos——弹侧调用单参契约）：弹回收前扫描活跃弹，
	# 取距 pos 最近且仍在场的 flight_axe 弹（落地调用点距离恒 0）读 _shock_scale/面板。
	# 子斧不经本侧 try_fire（request_split 派生）也能被同一入口覆盖。
	if projectile_pool == null:
		return null
	var best: ProjectileBase = null
	var best_d := 48.0                         # 抵达带 24px + 帧内步长余量
	for p in projectile_pool.active_projectiles():
		if is_instance_valid(p) and p is ProjectileBase and (p as ProjectileBase).team == 0 \
				and bool(p.get("_flight_axe")):
			var d: float = (p as Node2D).global_position.distance_to(p_pos)
			if d <= best_d:
				best_d = d
				best = p
	return best


func _launch_shock_fx(p_pos: Vector2, p_radius: float, p_ring_radius: float = 0.0) -> GroundShockFx:
	# 裂地特效出厂（GroundShockFx 半径随 shock_scale 缩放——子斧小型裂地读感）。
	# R243 §7.2：p_ring_radius > 0（崩山击质变）→ 双环外环臂（外环滞后扩张）。
	# R253（c9a 缓办清账）池化发射口：原每次 new+0.35s queue_free（MissileBlastFx.spawn
	# 静态池协议同款）；随机裂纹/碎屑参数随出厂重掷，读感与新建一致
	var fx := GroundShockFx.spawn(self, p_pos,
		maxf(p_radius, 8.0), maxf(p_ring_radius, 0.0)) as GroundShockFx
	return fx


func _outer_ring_cfg() -> Dictionary:
	# w4 质变外环震荡挂点（pre-w4 惰性）：质变键 ring_mult/ring_ratio 仅质变态消费——
	# 现阶段 WeaponBase 无 transcended 状态位（w4 交付），get() 恒 null → 恒 {} 不触发；
	# w4 交付后本口自动武装（零再接线）。null 与 false 同门（bool(null) 非法，勿包）。
	if data == null or get("transcended") != true:
		return {}
	var tc: Variant = data.melee.get("transcend")
	if not (tc is Dictionary):
		return {}
	return tc


func _leveled_param(p_key: String, p_default: float) -> float:
	# 逐级形态参数（melee.<key>_levels——OrbitWeapon._leveled_param 同式本侧副本；
	# 同名方法遮蔽合法，w2-melee 收口如上移 WeaponBase 亦零改名兼容）
	# QA-heal r1：键串拼改 WeaponBase._leveled_key 静态键缓存（常量税——震荡半径逐帧触达）
	var levels: Variant = data.melee.get(WeaponBase._leveled_key(p_key), null)
	if levels is Array and level >= 1 and level <= (levels as Array).size():
		return float((levels as Array)[level - 1])
	return p_default


func _inject_projectile_deps(p_proj: ProjectileBase) -> void:
	# 弹体依赖注入（非初始值不走 spawn 字典——ballistic_weapon.gd:330 先例）
	p_proj.damage_pipeline = damage_pipeline
	p_proj.enemy_grid = enemy_grid
	p_proj.pool = projectile_pool
	p_proj.elemental = elemental


# ── ⑨ 图标（texture_factory 委托臂消费——static func weapon_icon_tex） ─────────
static func weapon_icon_tex(p_transcended: bool) -> ImageTexture:
	# R243 W12 图标（§2.3/§7.1）：56px 画布朝上（-Y，与三新武器画布口径一致——化身层
	# +90° 补偿经 _is_blade_weapon 白名单生效）。默认 = 岩钢掷斧（竖柄 + 顶部弧刃 +
	# 白刃口高光）；质变「崩山击」= 岩纹（土岩斧体 + 金色岩裂脉 + 土黄刃口）。
	# 栅格内核复用 TextureFactory static 光栅化口（只读复用，不改共享文件）；
	# 缓存在本脚本 static（勿写共享 _cache——单一写者纪律）。
	var key := "t2" if p_transcended else "base"
	if _icon_cache.has(key):
		return _icon_cache[key]
	var tex: ImageTexture = TextureFactory._render(56, 56,
		TextureFactory._shade(_icon_layers(p_transcended)))
	_icon_cache[key] = tex
	return tex


static func _icon_layers(p_transcended: bool) -> Array:
	# 图层集（layer = {sd: SDF Callable, fill: Color, ow: 描边宽}——TextureFactory._shade 契约）
	var brown := Color(0.45, 0.3, 0.18)       # 柄木褐（与裂地特效裂纹同源色）
	var steel := Color(0.62, 0.68, 0.78)
	var deep := Color(0.22, 0.26, 0.36)
	var edge := Color(1.0, 1.0, 1.0, 0.88)
	if p_transcended:
		steel = Color(0.42, 0.35, 0.27)       # 土岩斧体
		deep = Color(0.2, 0.16, 0.12)
		edge = Color(0.94, 0.78, 0.42)        # 亮土黄刃口
	var gold := Color(0.95, 0.78, 0.35)
	var head := PackedVector2Array([          # 顶部弧刃（单刃宽斧，朝上 -Y）
		Vector2(-13.5, -6.0), Vector2(-12.0, -15.0), Vector2(-6.0, -20.5),
		Vector2(3.0, -22.0), Vector2(11.0, -18.0), Vector2(14.0, -10.0),
		Vector2(13.0, -4.0), Vector2(8.0, -9.0), Vector2(0.0, -11.0), Vector2(-8.0, -9.5),
	])
	var edge_light := PackedVector2Array([    # 刃口白光（外缘细条）
		Vector2(-10.5, -13.5), Vector2(-6.0, -18.5), Vector2(2.5, -20.0),
		Vector2(9.5, -16.5), Vector2(11.5, -11.5), Vector2(8.0, -14.5),
		Vector2(1.0, -16.5), Vector2(-6.0, -15.0),
	])
	var layers: Array = [
		# R267 视觉刀：水晶外壳层（斧头弧刃同形外扩；身份岩钢/土岩未钳——c′ 特征层）
		{"sd": TextureFactory._poly_sd(CrystalBladeFactory.expand_poly(head,
			CrystalBladeFactory.ICON_SHELL_EXPAND)),
			"fill": CrystalBladeFactory.icon_shell_color(steel), "ow": 0.0},
		{"sd": TextureFactory._box_at(Vector2(0.0, 8.0), Vector2(1.8, 12.5), 1.2),
			"fill": brown, "ow": 2.4},
		{"sd": TextureFactory._box_at(Vector2(0.0, 16.0), Vector2(2.4, 3.0), 1.0),
			"fill": deep, "ow": 2.2},
		{"sd": TextureFactory._poly_sd(head), "fill": steel, "ow": 2.6},
		{"sd": TextureFactory._poly_sd(edge_light), "fill": edge, "ow": 0.0},
		{"sd": TextureFactory._box_at(Vector2(-0.5, -4.5), Vector2(3.6, 2.0), 1.0),
			"fill": deep, "ow": 2.2},
		{"sd": TextureFactory._circle_at(Vector2(9.0, -15.0), 1.7),
			"fill": edge, "ow": 0.0},
	]
	if p_transcended:
		# 岩裂脉（金纹三道：刃面两道斜脉 + 柄身一道）
		layers.append({"sd": TextureFactory._box_rot_at(Vector2(2.0, -14.0),
			Vector2(7.5, 0.7), 0.6, -0.5), "fill": gold, "ow": 0.0})
		layers.append({"sd": TextureFactory._box_rot_at(Vector2(-3.0, -9.0),
			Vector2(5.5, 0.6), 0.5, 0.65), "fill": gold, "ow": 0.0})
		layers.append({"sd": TextureFactory._box_rot_at(Vector2(0.0, 9.0),
			Vector2(8.0, 0.6), 0.5, 0.15), "fill": gold, "ow": 0.0})
	CrystalBladeFactory.note_icon_built(&"W12_ground_axe")   # R267 c′ 机制标记
	return layers


# ── 掷斧弹体贴图（projectile_base._VIS_AXE 消费——static func，勿动共享 TextureFactory） ──
static var _flight_tex_cache: Dictionary = {}  # 弹体贴图本地缓存（键 base/t2|色——勿写共享 _cache）
const FLIGHT_STEEL := Color(0.62, 0.68, 0.78)  # 弹体岩钢缺省（KIN 原观感单源——缺省参与质变门同源）


static func flight_tex(p_transcended: bool, p_fill: Color = FLIGHT_STEEL,
		p_quality: int = -1) -> ImageTexture:
	# R243 掷斧弹体（§2.3 视觉斧体「掷出的巨斧」）：64px 画布朝上 -Y（projectile_base
	# _apply_visual_rotation 以 angle+PI/2 对齐速度方向——斧刃迎向落点，_axe_step 逐 tick
	# 重指落点时转向即时跟随）。默认 = 岩钢弧刃巨斧；质变崩山击 = 土岩斧体 + 金色岩裂脉
	#（与图标 _icon_layers 同源造型放大版）。表现放大由弹侧 AXE_VIS_MULT 承担（命中盒
	# 不变）。栅格内核只读复用 TextureFactory static 口；缓存在本脚本 static。
	# 簇2 c2-③（R243 新武器 flight_tex 无色参缺口收口——晚于 R211 七条清单的漏登记项）：
	# 斧刃基色参数化（R208 tracer_tex 同款）——元素附魔传元素表色；缺省岩钢保 KIN 原
	# 观感。质变岩纹仅在 p_fill==缺省（KIN 未染）时参与键与换色=质变与元素撞车元素
	# 优先、KIN 才落岩纹（二cm/R241② 口径）；元素染时 t2 键归并 base，同色斧体
	# t2/base 共享同贴图实例（桶合批友好）。
	# R267 视觉刀 §2.3/§2.4：元素染色 → 水晶配方（CrystalBladeFactory 烘焙形态——
	# 对应元素透明刀水晶质感，反馈 B；缓存键含 quality=低特效降级接 §2.5-4）；KIN
	# 缺省岩钢与质变岩纹走原配方逐位不动（§2.2 豁免）。
	if not CrystalBladeFactory.is_identity_fill(p_fill):
		var q := CrystalBladeFactory.live_fx_quality() if p_quality < 0 \
			else clampi(p_quality, 0, 2)
		return CrystalBladeFactory.crystal_tex(&"ground_axe", p_fill, false, q)
	var tainted := p_transcended and p_fill == FLIGHT_STEEL
	var key := "%s|%s" % ["t2" if tainted else "base", p_fill.to_html()]
	if _flight_tex_cache.has(key):
		return _flight_tex_cache[key]
	var brown := Color(0.45, 0.3, 0.18)       # 柄木褐（与裂地特效裂纹同源色）
	var steel := p_fill
	var deep := Color(0.22, 0.26, 0.36)
	var edge := Color(1.0, 1.0, 1.0, 0.88)
	if tainted:
		steel = Color(0.42, 0.35, 0.27)       # 土岩斧体（仅 KIN 未染时——元素优先）
		deep = Color(0.2, 0.16, 0.12)
		edge = Color(0.94, 0.78, 0.42)        # 亮土黄刃口
	var gold := Color(0.95, 0.78, 0.35)
	var head := PackedVector2Array([          # 顶部弧刃（单刃宽斧，朝上 -Y）
		Vector2(-16.5, -6.0), Vector2(-15.0, -17.0), Vector2(-7.0, -24.5),
		Vector2(4.0, -26.5), Vector2(14.0, -21.5), Vector2(17.0, -11.0),
		Vector2(16.0, -3.5), Vector2(9.5, -10.0), Vector2(0.0, -12.5), Vector2(-9.5, -11.0),
	])
	var layers: Array = [
		{"sd": TextureFactory._box_at(Vector2(0.0, 8.0), Vector2(2.8, 22.0), 1.2),
			"fill": brown, "ow": 2.4},
		{"sd": TextureFactory._box_at(Vector2(0.0, 21.5), Vector2(3.8, 4.0), 1.0),
			"fill": deep, "ow": 2.2},
		{"sd": TextureFactory._poly_sd(head), "fill": steel, "ow": 2.6},
		{"sd": TextureFactory._poly_sd(PackedVector2Array([
			Vector2(-12.5, -14.5), Vector2(-7.0, -21.0), Vector2(3.0, -23.0),
			Vector2(11.5, -18.5), Vector2(13.5, -12.5), Vector2(9.0, -16.0),
			Vector2(1.0, -18.0), Vector2(-7.0, -16.5),
		])), "fill": edge, "ow": 0.0},
		{"sd": TextureFactory._box_at(Vector2(-0.5, -4.5), Vector2(4.5, 2.4), 1.0),
			"fill": deep, "ow": 2.2},
		{"sd": TextureFactory._circle_at(Vector2(10.5, -17.0), 2.0),
			"fill": edge, "ow": 0.0},
	]
	if tainted:
		# 岩裂脉（金纹三道：刃面两道斜脉 + 柄身一道——图标同式；仅 KIN 未染时——元素优先）
		layers.append({"sd": TextureFactory._box_rot_at(Vector2(2.5, -15.0),
			Vector2(9.0, 0.8), 0.6, -0.5), "fill": gold, "ow": 0.0})
		layers.append({"sd": TextureFactory._box_rot_at(Vector2(-3.5, -9.0),
			Vector2(6.5, 0.7), 0.5, 0.65), "fill": gold, "ow": 0.0})
		layers.append({"sd": TextureFactory._box_rot_at(Vector2(0.0, 10.0),
			Vector2(9.5, 0.7), 0.5, 0.15), "fill": gold, "ow": 0.0})
	var tex: ImageTexture = TextureFactory._render(64, 64, TextureFactory._shade(layers))
	_flight_tex_cache[key] = tex
	return tex


# ══ GroundShockFx 裂地特效（同文件内轻量节点类，§2.3） ═══════════════════════
# 扩张冲击环（0→R、线宽 5→2、α 1→0）+ 5 条放射裂纹 polyline（±15° 均布、长 0.55×R、
# 深褐 + 内侧亮土黄高光）+ 8 粒抛物线飞溅碎屑（外抛 40~70px）；z_index=2 地面层
# （低于敌人 z=5 口径，ArcSlash z_index=5 先例）；0.35s 生命自毁。
class GroundShockFx:
	extends Node2D

	const FX_LIFE := 0.35
	const CRACK_COUNT := 5
	const CRACK_JITTER_DEG := 15.0
	const CRACK_LEN_RATIO := 0.55
	const DEBRIS_COUNT := 8
	const DEBRIS_MIN_DIST := 40.0
	const DEBRIS_MAX_DIST := 70.0
	const RING_WIDTH_FROM := 5.0
	const RING_WIDTH_TO := 2.0
	const CRACK_BROWN := Color(0.45, 0.3, 0.18)
	const CRACK_HIGHLIGHT := Color(0.94, 0.78, 0.42)

	const POOL_MAX := 6                          # R253 池上限（裂地并发峰值余量）

	static var _free: Array = []                 # R253 空闲件栈（LIFO）
	static var _pool_news: int = 0
	static var _pool_hits: int = 0

	var shock_radius: float = 96.0
	var ring_radius: float = 0.0               # R243 §7.2 外环臂半径（0 = 单环——未质变/子斧）
	var _age := 0.0
	var _crack_angles: Array[float] = []
	var _crack_kinks: Array[float] = []
	var _debris_dirs: Array[Vector2] = []
	var _debris_dist: Array[float] = []
	var _debris_r: Array[float] = []

	static func spawn(p_layer: Node, p_pos: Vector2, p_shock_radius: float,
			p_ring_radius: float) -> Object:
		# R253 池化发射口（替代 new+add_child；z_index/top_level/世界位随出厂重申）
		if p_layer == null:
			return null
		var item = _acquire(p_layer)
		item.z_index = 2
		item.top_level = true                   # 定世界位（宿主移动不拖拽地面裂纹）
		item.global_position = p_pos
		item.shock_radius = p_shock_radius
		item.ring_radius = p_ring_radius
		item._age = 0.0
		item.setup_fx()
		item.visible = true
		item.set_process(true)
		item.queue_redraw()
		return item

	static func _acquire(p_layer: Node) -> Object:
		while not _free.is_empty():
			var cand = _free.pop_back()
			if cand != null and is_instance_valid(cand):
				_pool_hits += 1
				if cand.get_parent() != p_layer:
					cand.get_parent().remove_child(cand)
					p_layer.add_child(cand)
				return cand
		_pool_news += 1
		var item = GroundShockFx.new()
		p_layer.add_child(item)
		return item

	static func _release(p_item) -> void:
		if p_item == null or not is_instance_valid(p_item):
			return
		p_item.visible = false
		p_item.set_process(false)
		if _free.size() < POOL_MAX:
			_free.append(p_item)
		else:
			p_item.queue_free()

	func setup_fx() -> void:
		_crack_angles.clear()                   # R253 池复用重掷（MissileBlastFx._reroll 同语义）
		_crack_kinks.clear()
		_debris_dirs.clear()
		_debris_dist.clear()
		_debris_r.clear()
		for i in range(CRACK_COUNT):
			var spread := TAU * float(i) / float(CRACK_COUNT)
			_crack_angles.append(spread + randf_range(-deg_to_rad(CRACK_JITTER_DEG),
				deg_to_rad(CRACK_JITTER_DEG)))
			_crack_kinks.append(randf_range(-0.22, 0.22))
		for i in range(DEBRIS_COUNT):
			var ang := TAU * (float(i) + randf_range(-0.3, 0.3)) / float(DEBRIS_COUNT)
			_debris_dirs.append(Vector2.from_angle(ang))
			_debris_dist.append(randf_range(DEBRIS_MIN_DIST, DEBRIS_MAX_DIST))
			_debris_r.append(randf_range(1.6, 3.0))

	func _process(p_delta: float) -> void:
		_age += p_delta
		if _age >= FX_LIFE:
			_release(self)                    # R253 归还池（原 0.35s queue_free——验收⑦寿命口径不变）
			return
		queue_redraw()

	func _draw() -> void:
		# R271 P4：绘µs wrap（自绘件 _draw 计时入 &"draw" 桶——只加计不改行为；
		# 原体迁 _draw_r271，早退 return 由委托面兜底不漏收口）
		DebugStats.bucket_begin(&"draw")
		_draw_r271()
		DebugStats.bucket_end(&"draw")


	func _draw_r271() -> void:
		var t := clampf(_age / FX_LIFE, 0.0, 1.0)
		var alpha := 1.0 - t
		# 扩张冲击环：0→R、线宽 5→2、α 1→0
		var ring_r := shock_radius * t
		var ring_w := lerpf(RING_WIDTH_FROM, RING_WIDTH_TO, t)
		if ring_r > 1.0:
			draw_arc(Vector2.ZERO, ring_r, 0.0, TAU, 48,
				Color(CRACK_BROWN.r, CRACK_BROWN.g, CRACK_BROWN.b, alpha), ring_w, true)
			draw_arc(Vector2.ZERO, maxf(ring_r - ring_w, 1.0), 0.0, TAU, 48,
				Color(CRACK_HIGHLIGHT.r, CRACK_HIGHLIGHT.g, CRACK_HIGHLIGHT.b, alpha * 0.45),
				maxf(ring_w - 1.0, 1.0), true)
		# R243 §7.2 崩山击双环外环臂：外环（ring_radius>0）滞后扩张（进度相位偏移 0.35
		# ——内外环时间错落读感），暗褐描环 + 内侧高光，α 同衰减
		if ring_radius > shock_radius + 1.0:
			var ring_t := clampf((t - 0.35) / 0.65, 0.0, 1.0)
			var outer_r := ring_radius * ring_t
			if outer_r > 1.0:
				var outer_a := alpha * (0.8 + 0.2 * ring_t)
				draw_arc(Vector2.ZERO, outer_r, 0.0, TAU, 48,
					Color(CRACK_BROWN.r, CRACK_BROWN.g, CRACK_BROWN.b, outer_a), ring_w, true)
				draw_arc(Vector2.ZERO, maxf(outer_r - ring_w, 1.0), 0.0, TAU, 48,
					Color(CRACK_HIGHLIGHT.r, CRACK_HIGHLIGHT.g, CRACK_HIGHLIGHT.b,
						outer_a * 0.4), maxf(ring_w - 1.0, 1.0), true)
		# 放射裂纹 polyline（长 0.55×R）+ 内侧亮土黄高光
		var crack_len := shock_radius * CRACK_LEN_RATIO
		for i in range(_crack_angles.size()):
			var dir := Vector2.from_angle(_crack_angles[i])
			var kink: Vector2 = dir.rotated(_crack_kinks[i])
			var pts := PackedVector2Array([
				dir * 4.0,
				dir * (crack_len * 0.45) + kink * (crack_len * 0.08),
				dir * crack_len,
			])
			draw_polyline(pts, Color(CRACK_BROWN.r, CRACK_BROWN.g, CRACK_BROWN.b, alpha), 2.4, true)
			var hi := PackedVector2Array([
				dir * 5.0,
				dir * (crack_len * 0.4) + kink * (crack_len * 0.05),
				dir * (crack_len * 0.86),
			])
			draw_polyline(hi, Color(CRACK_HIGHLIGHT.r, CRACK_HIGHLIGHT.g, CRACK_HIGHLIGHT.b,
				alpha * 0.6), 1.0, true)
		# 飞溅碎屑：抛物线外抛（外抛 40~70px，竖向 -Y 拱弧读「抛起再落」）
		var fly := minf(t * 1.6, 1.0)          # 前段快速外抛
		var arc := sin(minf(t * 1.25, 1.0) * PI)
		for i in range(_debris_dirs.size()):
			var pos := _debris_dirs[i] * (_debris_dist[i] * fly) + Vector2(0.0, -10.0 * arc)
			draw_circle(pos, _debris_r[i], Color(CRACK_BROWN.r, CRACK_BROWN.g,
				CRACK_BROWN.b, alpha * 0.85))

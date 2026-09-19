# scripts/combat/weapon/melee/orbit_weapon.gd
# M-08 OrbitWeapon（架构 §2.8.5，形态 D）：环绕力场 W8 / 周期挥斩 W9 同构。
# · 环绕模式（nullify=false，W8）：浮游球绕本体公转（angular_speed °/s）；每球对同一
#   目标判定冷却 hit_cd（OrbitField 周期范围判定 + 击退，可打断自爆引导）。
# · 挥斩模式（nullify=true，W9，R65 追击者重做——用户重定义）：飞刀在活动范围
#   （slash_radius×2.5）内自主索敌追击（OrbitField 追击 AI），贴身（engage_r）即开砍；
#   冷却就绪时有任一刀贴身 → 该刀位开弧（中心=刀、朝向=目标——判定 query_arc 半径/
#   弧角/消弹口径与旧版完全一致，仅中心从玩家移到刀位）；刀未贴身不消耗节拍（cd 保持
#   就绪等刀追上）；无敌时段回归环绕玩家。多刀 = 每拍各自开弧（刀数量 buff 轴）。
# · orbs_bonus：MEC_ORBIT_LINK（谐振轨道）环绕体加成通道（W8 浮游球 / W9 追击刀）。
class_name OrbitWeapon
extends WeaponBase

const SLASH_WINDOW := 0.34                    # 挥斩判定窗口（R65：0.15→0.34——用户点名动画放慢）
const SLASH_LEASH_MULT := 2.5                 # R65：活动范围 = 挥砍半径 ×250%（用户定义）
const ENGAGE_R := 46.0                        # R65：贴身开砍距离（刀心-目标心）
const CHASE_SPEED := 420.0                    # R65：追击移速 px/s

var orbit_field: OrbitField = null            # 环绕力场实体（单武器常驻单例）
var arc_slash: ArcSlash = null                # 周期挥斩实体槽 0（兼容观测口；多刀 = _slash_pool）
var _slash_pool: Array[ArcSlash] = []         # R65：多刀各自开弧的挥斩实例池
var orbs_bonus: int = 0                       # 谐振轨道词条加成（MEC_ORBIT_LINK）


var _enemy_bullet_grid: SpaceGrid = null      # 敌弹网格（消弹查询——R7 接线，此前从未注入）


func setup(p_data: WeaponData, p_player: Node2D, p_deps: Dictionary) -> void:
	super(p_data, p_player, p_deps)
	_enemy_bullet_grid = p_deps.get("enemy_bullet_grid")
	orbs_bonus = 0
	orbit_field = null
	arc_slash = null
	_slash_pool.clear()


func has_target_now() -> bool:
	# R33 无敌人不开火门（用户反馈）：W8 力场 = 常驻判定场（非射击）直接放行；
	# W9 挥砍窗同门——无敌人不空挥（与 R25「无敌人时刀原位悬浮」设计一致）
	if _is_slash_mode():
		return super.has_target_now()
	return true


func try_fire() -> bool:
	# 近战形态"开火"= 周期性判定调度（hit_cd / cd）
	if data == null:
		return false
	if _is_slash_mode():
		# R65 追击者：冷却就绪 → 消费 OrbitField 贴身刀位开弧（每把贴身刀各开一弧）；
		# 刀全部在路上 → 不消耗节拍（false——WeaponBase 冷却保持就绪，追上即砍）
		if orbit_field == null:
			_ensure_orbit_field()
			return false
		var strikes: Array[Dictionary] = orbit_field.collect_engaged_strikes()
		if strikes.is_empty():
			return false
		for s in strikes:
			_open_slash(float(s["facing"]), s["center"])
		return true
	if orbit_field == null:
		_ensure_orbit_field()
		return orbit_field != null
	return false                              # 力场已常驻：无重复调度


func level_up() -> void:
	# 升级后重铺力场（R19：angular_speed/orbit_radius/orb_r 逐级成长即时生效）
	super.level_up()
	refresh_orbit_field()


func attach_trait(p_trait: TraitData) -> bool:
	# 词条挂载（R19 环绕形态卡：orbit_style 形态卡挂上即重铺外观+乘区；
	# R65 巨刃（knife_scale）/环绕体数（orbs_bonus 由词条效果置位）挂上即时重铺）
	var ok := super.attach_trait(p_trait)
	if ok and p_trait != null and (p_trait.params.has("orbit_style") \
			or p_trait.params.has("knife_scale")):
		refresh_orbit_field()
	return ok


func _orbit_style() -> StringName:
	# 环绕形态（R19 用户点名「剑/斧/闪电可换，选中一个后续其他不再出现」）：
	# 读挂载表中带 orbit_style 参数的形态卡；未选 = orb（默认浮游球）
	if trait_stack == null:
		return &""
	var style := &""
	for tb in trait_stack.traits:
		var td: Variant = tb.get("data")
		if td != null and (td as TraitData).params.has("orbit_style"):
			style = StringName(String((td as TraitData).params["orbit_style"]))   # 后挂覆盖
	return style


func _on_tick_post(p_game_delta: float) -> void:
	# 常驻实体推进（力场公转/追击 AI + 挥斩窗口判定；宿主位置驱动）
	# R65：W9 常驻刀体（无敌人也可见——环绕待机）；挥斩窗口自持中心（刀位），不再随宿主
	if orbit_field != null and is_instance_valid(orbit_field):
		orbit_field.tick(p_game_delta, muzzle_position())
	for slash in _slash_pool:
		if is_instance_valid(slash):
			slash.tick(p_game_delta, muzzle_position())


func _slash_window(p_facing: float = 0.0, p_random: bool = true) -> void:
	# 挥斩窗口开启（兼容通道：无追击力场时的玩家中心开窗——旧测试/特殊 AI 用；
	# 生产路径 = try_fire → OrbitField 贴身刀位 → _open_slash）。
	# p_random = false → 用 p_facing 确定性开窗（测试/特殊 AI 用；允许任意角度含负）。
	if _slash_pool.is_empty():
		_ensure_slash_instance()
		if _slash_pool.is_empty():
			return
	var facing := (randf() * TAU) if p_random else p_facing
	_open_slash(facing, muzzle_position())


func _open_slash(p_facing: float, p_center: Vector2) -> void:
	# R65 单刀开弧：中心=刀位世界坐标、朝向=刀→目标；判定半径/弧角走当前面板
	#（含 MEC_GIANT_BLADE 巨刃乘区——攻击范围 buff 轴）
	if _slash_pool.is_empty():
		_ensure_slash_instance()
	var slot: ArcSlash = null
	for s in _slash_pool:
		if s.window_left <= 0.0:
			slot = s
			break
	if slot == null:
		slot = _ensure_slash_instance()
	if slot == null:
		return
	slot.open_window(p_facing, p_center, effective_slash_radius())


func effective_slash_radius() -> float:
	# R65 挥砍判定半径 = 逐级参数 × 巨刃乘区（MEC_GIANT_BLADE 每层 +20%）
	return _leveled_param("slash_radius", float(data.melee.get("slash_radius", 150.0))) \
		* (1.0 + 0.2 * float(_giant_blade_layers()))


func _giant_blade_layers() -> int:
	# 巨刃词条层数（params 带 knife_scale 的挂载条目；R65 大小 buff 轴）
	if trait_stack == null:
		return 0
	var layers := 0
	for tb in trait_stack.traits:
		var td: Variant = tb.get("data")
		if td != null and (td as TraitData).params.has("knife_scale"):
			layers += int(tb.get("layers"))
	return layers


func _ensure_orbit_field() -> void:
	# 环绕力场创建（单武器常驻单例——池化收益为零，直接持有；池化属集成期优化项）
	orbit_field = OrbitField.new()
	orbit_field.name = "OrbitField"
	add_child(orbit_field)
	orbit_field.weapon = self                   # 结算宿主注入（缺失 → OrbitField.tick 判定早退）
	orbit_field.spawn(_orbit_params())


func _orbit_params() -> Dictionary:
	# 力场参数集（orbs 含 orbs_bonus 加成——诺亚僚机召唤通道，P2）。
	# R19 形态乘区——sword 再命中节奏 +25% / axe 范围+25% 击退+60% 转速-15% /
	# bolt 转速+50% 体积-10%（用户点名「剑/斧/闪电自己扩展」）
	# R65 W9 追击参数：活动范围 = 挥砍半径 ×250% / 追击移速 / 贴身距离 / 巨刃视觉缩放
	var style := _orbit_style()
	var orbit_radius := _leveled_param("orbit_radius", float(data.melee.get("orbit_radius", 90.0)))
	var angular := _leveled_param("angular_speed", float(data.melee.get("angular_speed", 240.0)))
	var orb_r := _leveled_param("orb_r", float(data.melee.get("orb_r", data.melee.get("orb_radius", 16.0))))
	var hit_cd := float(data.melee.get("hit_cd", 0.5))
	var knockback := float(data.melee.get("knockback", 40.0))
	match style:
		&"sword":
			hit_cd *= 0.75
		&"axe":
			orbit_radius *= 1.25
			orb_r *= 1.15
			knockback *= 1.6
			angular *= 0.85
		&"bolt":
			orb_r *= 0.9
			angular *= 1.5
			hit_cd *= 1.15
	var out := {
		"orbs": _leveled_param("orbs", float(data.melee.get("orbs", 2))) + orbs_bonus,
		"orbit_radius": orbit_radius,
		"angular_speed": angular,
		"orb_radius": orb_r,
		"hit_cd": hit_cd,
		"knockback": knockback,
		"style": String(style) if style != &"" else "orb",
		"knife_scale": 1.0 + 0.25 * float(_giant_blade_layers()),   # R65 巨刃：刀体视觉 +25%/层
	}
	if _is_slash_mode():
		out["leash_radius"] = effective_slash_radius() * SLASH_LEASH_MULT
		out["chase_speed"] = CHASE_SPEED
		out["engage_r"] = ENGAGE_R
	return out


func refresh_orbit_field() -> void:
	# 已常驻力场按当前参数重铺（R65：W8/W9 双模式通用——追击模式刀数/巨刃/等级即时
	# 生效；诺亚僚机召唤/还原通道同口）；力场未建（首开火前）→ 无需重铺
	#（orbs_bonus 由 _ensure_orbit_field 自然生效）
	if orbit_field == null or not is_instance_valid(orbit_field):
		return
	orbit_field.spawn(_orbit_params())


func _ensure_slash_instance() -> ArcSlash:
	# 挥斩实例创建/复用（R65 多刀池：每把贴身刀各开一弧；池随用随建，槽 0 = arc_slash 兼容口）
	var slash := ArcSlash.new()
	slash.name = "ArcSlash%d" % _slash_pool.size()
	add_child(slash)
	slash.weapon = self
	slash.enemy_grid = enemy_grid
	slash.enemy_bullet_grid = _enemy_bullet_grid   # R7 接线：消弹查询（此前恒 null = W9 消弹死功能）
	slash.spawn({
		"slash_radius": _leveled_param("slash_radius", float(data.melee.get("slash_radius", 150.0))),
		"arc_deg": _leveled_param("arc_deg", float(data.melee.get("arc_deg", 120.0))),
		"max_targets": int(data.melee.get("max_targets", 8)),
		"knockback": float(data.melee.get("knockback", 180.0)),
		"nullify": bool(data.melee.get("nullify", false)),
	})
	_slash_pool.append(slash)
	if arc_slash == null or not is_instance_valid(arc_slash):
		arc_slash = slash                     # 兼容观测口（槽 0）
	return slash


# 兼容别名（旧调用方/测试）
func _ensure_arc_slash() -> void:
	_ensure_slash_instance()


func set_enemy_bullet_grid(p_grid: SpaceGrid) -> void:
	# 敌弹网格注入（GameLoop 帧序③ enemy_bullet_grid——包 4 集成期接线；消弹查询）
	for slash in _slash_pool:
		slash.enemy_bullet_grid = p_grid


func _is_slash_mode() -> bool:
	# W9 挥斩形态判定（nullify=true：固定角度弧形判定 + 消弹）
	return bool(data.melee.get("nullify", false))


func _leveled_param(p_key: String, p_default: float) -> float:
	# 逐级形态参数（形态段新增键 <key>_levels: Array[float]——A3 §3.8/§3.9 逐级递进）
	var levels: Variant = data.melee.get(String(p_key) + "_levels", null)
	if levels is Array and level >= 1 and level <= (levels as Array).size():
		return float((levels as Array)[level - 1])
	return p_default

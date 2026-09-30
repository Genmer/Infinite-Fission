# scripts/combat/weapon/melee/orbit_weapon.gd
# M-08 OrbitWeapon（架构 §2.8.5，形态 D）：环绕力场 W8 / 周期挥斩 W9 同构。
# · 环绕模式（nullify=false，W8）：浮游球绕本体公转（angular_speed °/s）；接触 = 蓄能
#   命中（接触伤 + 蓄能 +1，OrbitField 蓄能状态机），满档敌侧引爆——try_fire 恒 false
#   契约不变（力场常驻非射击，pkg3 断言锁定）。
# · 引力脉冲：melee.cd 占位死键改义 = pulse_cd 节拍——本侧自持计时器消费 weapon_base
#   ._fire_interval 的 cd×(1−ΣCDR)/rof_mult 通道（AFF_CDR 对 W8 首次生效），每拍驱动
#   OrbitField.gravity_pulse（环内已蓄能目标 +1）。
# · 挥斩模式（nullify=true，W9，R65 追击者重做——用户重定义）：飞刀在活动范围
#   （slash_radius×2.5）内自主索敌追击（OrbitField 追击 AI），贴身（engage_r）即开砍；
#   冷却就绪时有任一刀贴身 → 该刀位开弧（中心=刀、朝向=目标——判定 query_arc 半径/
#   弧角/消弹口径与旧版完全一致，仅中心从玩家移到刀位）；刀未贴身不消耗节拍（cd 保持
#   就绪等刀追上）；无敌时段回归环绕玩家。多刀 = 每拍各自开弧（刀数量 buff 轴）。
# · orbs_bonus：MEC_ORBIT_LINK（谐振轨道）环绕体加成通道（W8 浮游球 / W9 追击刀）。
# · R186 拆除声明：_orbit_params 不再注入 attach_gate/attach_mult（附着三件套随蓄能
#   改版整体退役——OrbitField 侧 apply_attach 零消费点，test_w8_charge 锁死不复潮）。
#   蓄能键组（charge_max/charge_gain_cd/detonate_mult/detonate_radius/effective_blade_cap/
#   detonate_global_icd）全落 .tres melee 段，此处仅注入。形态卡改义：剑 = hit_cd×0.75
#   死数值保留（gatling 契约观测口）+ 活闸 charge_gain_cd×0.7；斧/巨刃 = 引爆半径
#   +15%/层；BOLT 转速×1.5 维持。击退终值仍 = 形态乘区后平加 Σadd_knock（MEC_KNOCK
#   required_forms 解锁 [3] 后 W8 首次吃到动能冲击池）。
class_name OrbitWeapon
extends WeaponBase

const SLASH_WINDOW := 0.34                    # 挥斩判定窗口（R65：0.15→0.34——用户点名动画放慢）
const SLASH_LEASH_MULT := 2.5                 # R65：活动范围 = 挥砍半径 ×250%（用户定义）
const ENGAGE_R := 46.0                        # R65：贴身开砍距离（刀心-目标心）
const CHASE_SPEED := 420.0                    # R65：追击移速 px/s
const PULSE_MIN_INTERVAL := 0.05              # 引力脉冲节拍下限（CDR 钳制后防 0 除）
const COPY_PHASE_OFFSET_DEG := 45.0           # R183 W8 复制体阵相位偏移（BASE 单环阵 + 45°）
# R199 F01/F04：词条 value 基准锚（.tres value 同值——桩夹具 value≤0 缺省回落）
const GIANT_BLADE_SCALE_BASE := 0.25          # MEC_GIANT_BLADE 刀体缩放基准（白）
const ORBIT_STYLE_BASE := {                   # 环绕形态主乘区基准（白）
	&"sword": 0.25, &"axe": 0.25, &"bolt": 0.50,
}

var orbit_field: OrbitField = null            # 环绕力场实体（单武器常驻单例）
var arc_slash: ArcSlash = null                # 周期挥斩实体槽 0（兼容观测口；多刀 = _slash_pool）
var _slash_pool: Array[ArcSlash] = []         # R65：多刀各自开弧的挥斩实例池
var orbs_bonus: int = 0                       # 谐振轨道词条加成（MEC_ORBIT_LINK）
var _pulse_left: float = 0.0                  # 引力脉冲倒计时（消费 _fire_interval 通道）


var _enemy_bullet_grid: SpaceGrid = null      # 敌弹网格（消弹查询——R7 接线，此前从未注入）


func setup(p_data: WeaponData, p_player: Node2D, p_deps: Dictionary) -> void:
	super(p_data, p_player, p_deps)
	_enemy_bullet_grid = p_deps.get("enemy_bullet_grid")
	orbs_bonus = 0
	orbit_field = null
	arc_slash = null
	_slash_pool.clear()
	_pulse_left = 0.0


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
	# R65 巨刃（knife_scale）挂上即时重铺；R69 谐振轨道聚合直读 → 挂上即重铺刀数；
	# R196 广域印刻（add_range 池）挂上即重铺——环绕半径/挥砍范围即时生效）
	var ok := super.attach_trait(p_trait)
	if ok and p_trait != null and (p_trait.params.has("orbit_style") \
			or p_trait.params.has("knife_scale") or p_trait.id == &"MEC_ORBIT_LINK" \
			or p_trait.pool_id == &"add_range"):
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
		# W8 引力脉冲（pulse_cd 节拍）：自持计时器消费 weapon_base._fire_interval 的
		# cd×(1−ΣCDR)/rof_mult 通道（AFF_CDR 对 W8 首次生效——此前 add_cdr 仅 W9 在吃）；
		# try_fire 恒 false 契约不变（力场常驻非射击），脉冲不占开火节拍。
		if not _is_slash_mode():
			_pulse_left -= p_game_delta
			if _pulse_left <= 0.0:
				orbit_field.gravity_pulse()
				_pulse_left += maxf(_fire_interval(), PULSE_MIN_INTERVAL)
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
	# R196 ×_range_mult()：AFF_RANGE 广域印刻（W9 判定半径 + 追击 leash _orbit_params
	# 同源联动——判定半径经 ArcSlash.open_window 注入，本值即唯一真源）
	return _leveled_param("slash_radius", float(data.melee.get("slash_radius", 150.0))) \
		* (1.0 + 0.2 * float(_giant_blade_layers())) * _range_mult()


func _range_mult() -> float:
	# R196「武器范围」词条（AFF_RANGE / add_range 池）：环绕轨道半径与挥砍范围
	# +18%/层（aggregate_panel 聚合真值；trait_stack 判空返 1.0——零词条不放大）
	if trait_stack == null:
		return 1.0
	return 1.0 + float(trait_stack.aggregate_panel().get("add_range", 0.0))


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


func _giant_blade_value() -> float:
	# R199 F01：巨刃刀体缩放真源 = 挂载条目 data.value（白基准 0.25；品质缩放沿
	# card_generator value×scale 链路——金卡 0.65 与卡面「刀体 +65%」一致）。旧消费
	# 硬编码 0.25 只数层不读值（_giant_blade_layers），0.65 全仓无消费点。value≤0
	#（桩夹具零声明）回落 GIANT_BLADE_SCALE_BASE，存量断言零位移。
	if trait_stack != null:
		for tb in trait_stack.traits:
			var td: Variant = tb.get("data")
			if td != null and (td as TraitData).params.has("knife_scale"):
				var v := float((td as TraitData).value)
				if v > 0.0:
					return v
				break
	return GIANT_BLADE_SCALE_BASE


func _orbit_style_value() -> float:
	# R199 F04：环绕形态主乘区真源 = 形态卡 data.value（白基准 sword/axe 0.25 /
	# bolt 0.50——tres 自本批回填；品质缩放沿 card_generator value×scale 链路，金卡
	# 0.65/0.65/1.30 与卡面数字一致）。旧实现 match 硬编码乘区、tres value=0.0 从不
	# 被消费——金卡数字集体失真（斧「范围+65%」实发 25%、雷「转速+130%」实发 50%、
	# 剑「再命中节奏+65%」实发 25%）。value≤0（旧数据/桩夹具）回落基准常量零位移。
	var style := _orbit_style()
	if trait_stack != null:
		for tb in trait_stack.traits:
			var td: Variant = tb.get("data")
			if td != null and (td as TraitData).params.has("orbit_style"):
				var v := float((td as TraitData).value)
				if v > 0.0:
					return v
				break
	return float(ORBIT_STYLE_BASE.get(style, 0.0))


func _ensure_orbit_field() -> void:
	# 环绕力场创建（单武器常驻单例——池化收益为零，直接持有；池化属集成期优化项）
	orbit_field = OrbitField.new()
	orbit_field.name = "OrbitField"
	add_child(orbit_field)
	orbit_field.weapon = self                   # 结算宿主注入（缺失 → OrbitField.tick 判定早退）
	orbit_field.spawn(_orbit_params())
	_pulse_left = maxf(_fire_interval(), PULSE_MIN_INTERVAL)   # 脉冲节拍与力场同步起表


func _orbit_params() -> Dictionary:
	# 力场参数集（orbs 含 orbs_bonus 加成——诺亚僚机召唤通道，P2）。
	# R19 形态乘区——sword 再命中节奏 +25%（hit_cd 死数值保留，gatling 契约观测口）/
	# axe 范围+25% 击退+60% 转速-15% / bolt 转速+50% 体积-10%（用户点名「剑/斧/闪电自己扩展」）
	# R65 W9 追击参数：活动范围 = 挥砍半径 ×250% / 追击移速 / 贴身距离 / 巨刃视觉缩放
	# W8 蓄能改版：charge_gain_cd 活闸（数据键真源 melee 段；缺省回落 hit_cd 旧通道——
	# 旧数据/桩夹具零声明也成立）；剑形态改义 = charge_gain_cd×0.7（蓄能速率语义迁入）；
	# 斧/巨刃改义 = 引爆半径 +15%/层。
	var style := _orbit_style()
	var copy := _is_summon_copy()
	var orbit_radius := _leveled_param("orbit_radius", float(data.melee.get("orbit_radius", 90.0)))
	var angular := _leveled_param("angular_speed", float(data.melee.get("angular_speed", 240.0)))
	var orb_r := _leveled_param("orb_r", float(data.melee.get("orb_r", data.melee.get("orb_radius", 16.0))))
	var orbs_n := _leveled_param("orbs", float(data.melee.get("orbs", 2)))
	var phase_offset_deg := 0.0
	if copy:
		# R183 W8 复制体裁定（§一 统一表）：固定 BASE 单环阵（等级成长不带入——
		# melee 段基线值直读，不走 _leveled_param）+ 相位偏移 45°（与本体错位公转）
		orbit_radius = float(data.melee.get("orbit_radius", 90.0))
		angular = float(data.melee.get("angular_speed", 240.0))
		orb_r = float(data.melee.get("orb_r", data.melee.get("orb_radius", 16.0)))
		orbs_n = float(data.melee.get("orbs", 2))
		phase_offset_deg = COPY_PHASE_OFFSET_DEG
	# R196 广域印刻（AFF_RANGE / add_range 池）：环绕轨道半径 ×(1+Σadd_range)——
	# 置于 copy 分支之后，本体与复制体同享（复制体仅锁等级成长，词条栈 copy_full
	# 全量带入——R183 只锁等级、词条不锁口径）
	orbit_radius *= _range_mult()
	var hit_cd := float(data.melee.get("hit_cd", 0.5))
	var knockback := float(data.melee.get("knockback", 40.0))
	# 蓄能闸终值：melee.charge_gain_cd(_levels) 优先，未声明回落 hit_cd（旧数据兼容）
	var gain_cd: float
	if data.melee.has("charge_gain_cd"):
		gain_cd = _leveled_param("charge_gain_cd", float(data.melee.get("charge_gain_cd", 0.5)))
	else:
		gain_cd = hit_cd
	# 引爆半径改义乘区：巨刃 +15%/层（R65 视觉轴追加引爆当量轴）+ 斧形态 +15%/层
	var radius_bonus := 1.0 + OrbitField.DETONATE_RADIUS_PER_LAYER \
		* float(_giant_blade_layers() + _trait_layers(&"MEC_ORBIT_AXE"))
	# R199 F04 形态乘区真源化：sword 再命中节奏 / axe 范围 / bolt 转速改读形态卡
	# data.value（_orbit_style_value；白基准与旧硬编码同值——0.25/0.25/0.50，存量断言
	# 零位移；金卡经 value×scale 链路与卡面一致）。次要乘区（体积/击退/转速微调/
	# 蓄能闸）仍为形态常量（卡面未随品质缩放，保持）。
	var style_value := _orbit_style_value()
	match style:
		&"sword":
			hit_cd *= 1.0 - style_value               # 再命中节奏 +value% = 命中冷却 −value
			gain_cd *= 0.7
		&"axe":
			orbit_radius *= 1.0 + style_value
			orb_r *= 1.15
			knockback *= 1.6
			angular *= 0.85
		&"bolt":
			orb_r *= 0.9
			angular *= 1.0 + style_value
			hit_cd *= 1.15
	# R186 M5 击退终值钉死（继承）：终值 = data.melee.knockback × 形态乘区（上方 match 原样）
	# + Σadd_knock（乘区之后平加，不进乘区——knockback_force() 先例 weapon_base.gd:349-357：
	# data 值后平加池）。MEC_KNOCK required_forms 解锁 [3] 后 W8 首次吃到动能冲击池。
	# W9 零波及：ArcSlash 直读 data.melee.knockback（_ensure_slash_instance），
	# 本值仅 OrbitField 环绕模式击退消费。
	if trait_stack != null:
		knockback += float(trait_stack.aggregate_panel().get("add_knock", 0.0))
	var out := {
		"orbs": int(orbs_n) + orbs_bonus + _orbit_link_knives(),
		"orbit_radius": orbit_radius,
		"angular_speed": angular,
		"orb_radius": orb_r,
		"hit_cd": hit_cd,
		"knockback": knockback,
		# R183 W8 复制体相位偏移（OrbitField.spawn 起表角；本体 0）
		"angle_deg": phase_offset_deg,
		# ── W8 蓄能引爆键组（数据键全落 .tres melee 段）──
		# MEC_CRITICAL_MASS 消费口（R187 §2.5.6 当量轴）：每层 +value 引爆倍率
		# （value=1.0，stack_max=2 → 5×→7×；数据声明驱动，直读挂载表——_orbit_link_knives 先例）
		"charge_max": float(data.melee.get("charge_max", 5.0)),
		"charge_gain_cd": maxf(gain_cd, 0.05),
		"detonate_mult": float(data.melee.get("detonate_mult", 5.0))
			+ _crit_mass_mult_bonus(),
		"detonate_radius": maxf(float(data.melee.get("detonate_radius", 90.0)) * radius_bonus, 1.0),
		"effective_blade_cap": int(data.melee.get("effective_blade_cap", 8)),
		"detonate_global_icd": float(data.melee.get("detonate_global_icd", 0.5)),
		"style": String(style) if style != &"" else "orb",
		"knife_scale": 1.0 + _giant_blade_value() * float(_giant_blade_layers()),
		# R65 巨刃：刀体视觉 +value/层（R199 F01：改读 data.value——白 0.25/金 0.65 与卡面一致）
	}
	if _is_slash_mode():
		out["leash_radius"] = effective_slash_radius() * SLASH_LEASH_MULT
		out["chase_speed"] = CHASE_SPEED
		out["engage_r"] = ENGAGE_R
	return out


func _trait_layers(p_id: StringName) -> int:
	# 指定词条挂载层数（形态卡改义乘区消费——axe 引爆半径轴）
	if trait_stack == null:
		return 0
	for tb in trait_stack.traits:
		if tb.data != null and tb.data.id == p_id:
			return int(tb.get("layers"))
	return 0


func _is_summon_copy() -> bool:
	# R183 副本身份判定（player.gd _summon_copies 独立数组通道——homing_weapon 同款）
	if player == null or not is_instance_valid(player):
		return false
	var copies: Variant = player.get("_summon_copies")
	if copies is Array:
		for c in (copies as Array):
			if c == self:
				return true
	return false


func _crit_mass_mult_bonus() -> float:
	# MEC_CRITICAL_MASS「临界质量」引爆倍率加算（每层 +data.value；缺省 0——卡未挂/桩
	# 夹具零声明不失能）。消费点在 _orbit_params detonate_mult 键——refresh_orbit_field
	# 重铺即生效（挂卡即时口径，同 MEC_KNOCK add_knock 平加池先例）。
	if trait_stack == null:
		return 0.0
	for tb in trait_stack.traits:
		if tb.data != null and tb.data.id == &"MEC_CRITICAL_MASS":
			return float(tb.data.value) * float(tb.get("layers"))
	return 0.0


func _orbit_link_knives() -> int:
	# R69 谐振轨道聚合直读：旧实现走 ON_SPAWN 效果派发 += layers——但环绕武器不产
	# 投射物、生产链路唯一的 ON_SPAWN 派发点在投射物生成（projectile_base），实战中
	# 该效果**永不触发**（测试手动派发掩盖，真机死卡）。改为参数构造侧直读挂载表：
	# LOCAL 池同 ID 取优（挂载侧语义）→ 最高品质 value × 层数；value 1.45 的取整梯
	# = 白/蓝/紫/金每层 +1/+2/+3/+4 刀（品质梯分化，用户反馈「不同级别数值一样」）
	if trait_stack == null:
		return 0
	var knives := 0
	for tb in trait_stack.traits:
		if tb.data != null and tb.data.id == &"MEC_ORBIT_LINK":
			knives = maxi(int(round(float(tb.data.value))), 1) * tb.layers
			break
	return knives


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

# scripts/combat/weapon/melee/orbit_weapon.gd
# M-08 OrbitWeapon（架构 §2.8.5，形态 D）：环绕力场 W8 / 周期挥斩 W9 / 定身巨斩 W13 同构。
# · 环绕模式（mode=orbit，W8）：浮游狼头刀绕本体公转（angular_speed °/s）；接触 = 蓄能
#   命中（接触伤 + 蓄能 +1，OrbitField 蓄能状态机），满档敌侧引爆——try_fire 恒 false
#   契约不变（力场常驻非射击，pkg3 断言锁定）。
# · 引力脉冲：melee.cd 占位死键改义 = pulse_cd 节拍——本侧自持计时器消费 weapon_base
#   ._fire_interval 的 cd×(1−ΣCDR)/rof_mult 通道（AFF_CDR 对 W8 首次生效），每拍驱动
#   OrbitField.gravity_pulse（环内已蓄能目标 +1）。
# · 挥斩模式（mode=slash，W9，R65 追击者重做——用户重定义）：飞刀在活动范围
#   （slash_radius×2.5）内自主索敌追击（OrbitField 追击 AI），贴身（engage_r）即开砍；
#   冷却就绪时有任一刀贴身 → 该刀位开弧（中心=刀、朝向=目标——判定 query_arc 半径/
#   弧角/消弹口径与旧版完全一致，仅中心从玩家移到刀位）；刀未贴身不消耗节拍（cd 保持
#   就绪等刀追上）；无敌时段回归环绕玩家。多刀 = 每拍各自开弧（刀数量 buff 轴）。
# · 定身巨斩（mode=cleave，W13，R243 §2.5）：剑不追击不建力场——原地朝最近敌人方向
#   定向开弧（aim_direction 定向、muzzle_position 中心，R33 无目标不开火门）；判定/
#   去重/挡弹/绘制免费复用 ArcSlash（_slash_pool 单槽）。常驻警戒弧（§3.3）：待机期
#   0.1s 节拍正面 90° 扇形概率挡弹（R245 §3.3 挡弹域改读 BLOCK_RADIUS_TABLE 按等级取档、
#   帽 4/检查、_guard_facing = 最近 aim_direction 缓存）——斩击窗全弧挡弹由 ArcSlash 既有口承载
#  （双域互补）。幻影斩（§4.3 MEC_ORBIT_LINK，inert）：每层 +1 道追加斩（facing+90°×i、
#   错帧 0.12s、全额伤害），额外 +2 封顶。
# · orbs_bonus：MEC_ORBIT_LINK（谐振轨道）环绕体加成通道（W8 浮游球 / W9 追击刀）。
# · R186 拆除声明：_orbit_params 不再注入 attach_gate/attach_mult（附着三件套随蓄能
#   改版整体退役——OrbitField 侧 apply_attach 零消费点，test_w8_charge 锁死不复潮）。
#   蓄能键组（charge_max/charge_gain_cd/detonate_mult/detonate_radius/effective_blade_cap/
#   detonate_global_icd）全落 .tres melee 段，此处仅注入。形态卡改义：剑 = hit_cd×0.75
#   死数值保留（gatling 契约观测口）+ 活闸 charge_gain_cd×0.7；斧/巨刃 = 引爆半径
#   +15%/层；BOLT 转速×1.5 维持。击退终值仍 = 形态乘区后平加 Σadd_knock（MEC_KNOCK
#   required_forms 解锁 [3] 后 W8 首次吃到动能冲击池）。
# · R243 helper 上移（§4.1/§4.3/§4.6）：_giant_blade_layers/_giant_blade_value/
#   _range_mult/_orbit_link_count 本地实现删除，调用点零改名走 WeaponBase 基类版
#  （R_cleave = slash_radius_levels[L]×(1+0.2×G)×(1+Σadd_range)——公式逐位同源）。
# · R243 §7.2 质变（w4-prime）：W8 苍狼啸月 = orbs+2 / 引爆当量 +1.5（×5→×6.5，MEC_
#   CRITICAL_MASS 同通道平加）/ 引爆半径 ×1.1；W9 碧涛旋舞 = 弧 +40°（160→200°）+
#   判定半径尾乘 ×1.15 + 同心回斩（echo_ratio 0.5/echo_delay 0.18）；W13 裂地斩 =
#   弧 +90°（180→270°）+ 击退 +80（快照 100→180）。_on_transcend 重铺力场与斩池。
class_name OrbitWeapon
extends WeaponBase

const SLASH_WINDOW := 0.34                    # 挥斩判定窗口（R65：0.15→0.34——用户点名动画放慢）
const SLASH_LEASH_MULT := 2.5                 # R65：活动范围 = 挥砍半径 ×250%（用户定义）
const ENGAGE_R := 46.0                        # R65：贴身开砍距离（刀心-目标心）
const CHASE_SPEED := 420.0                    # R65：追击移速 px/s
const PULSE_MIN_INTERVAL := 0.05              # 引力脉冲节拍下限（CDR 钳制后防 0 除）
const COPY_PHASE_OFFSET_DEG := 45.0           # R183 W8 复制体阵相位偏移（BASE 单环阵 + 45°）
# R243 §2.5-6/§3.3 W13 常驻警戒弧（cleave 待机期挡弹载体）
const GUARD_BEAT := 0.1                       # 警戒检查节拍 s（0.1s）
const GUARD_HALF_ARC_DEG := 45.0              # 半角 45° → 正面 90° 扇形
const GUARD_BLOCK_CAP := 4                    # 挡弹帽（4 弹/检查）
# R245 §3.3 挡弹域表 = 法器范围基准（W9 slash_radius_levels [150,165,180,200,230]）× 0.40
# 静态口径：不联动乘区（巨刃/广域）/质变/装备状态——挡弹是防御隐性机制，40% 约束取
# 基础表口径（设计取舍：精确联动需跨武器读表且使 40% 约束失义，可读性优先）。
# 消费双域：待机警戒弧（本文件 _tick_guard_arc）+ 斩击窗（ArcSlash._nullify_enemy_
# bullets 经 block_radius_for 读同表——W13 型概率挡弹域；W9 nullify 确定性消弹不读表，
# 全额 slash_radius 旧口径保持）。层级关系：挡弹域(60-92) < W13 圈(130-190) < 法器圈(150-230)。
const BLOCK_RADIUS_TABLE: Array[float] = [60.0, 66.0, 72.0, 80.0, 92.0]
# R243 §4.3 W13 幻影斩（MEC_ORBIT_LINK 消费，inert）
const PHANTOM_STAGGER := 0.12                 # 追加斩错帧 s
const PHANTOM_HALF_TURN := PI * 0.5           # 每道追加斩偏转 +90°
const PHANTOM_CAP := 2                        # 幻影斩封顶（额外 +2——§4.3 数量帽表）
# R199 F04：环绕形态主乘区基准（白）
const ORBIT_STYLE_BASE := {                   # 环绕形态主乘区基准（白）
	&"sword": 0.25, &"axe": 0.25, &"bolt": 0.50,
}
# 二cx#2 W13 cleave 交战门外圈：有效半径 ×1.15（「范围内（或者范围外指定距离）」——
# 敌头探进外圈即视为靠近，挥砍窗 0.34s 内走近敌自然入判定圈；只认圈外 = 永不空挥）
const CLEAVE_ENGAGE_MULT := 1.15

var orbit_field: OrbitField = null            # 环绕力场实体（单武器常驻单例）
var arc_slash: ArcSlash = null                # 周期挥斩实体槽 0（兼容观测口；多刀 = _slash_pool）
var _slash_pool: Array[ArcSlash] = []         # R65：多刀各自开弧的挥斩实例池
var orbs_bonus: int = 0                       # 谐振轨道词条加成（MEC_ORBIT_LINK）
var _pulse_left: float = 0.0                  # 引力脉冲倒计时（消费 _fire_interval 通道）
var _enemy_bullet_grid: SpaceGrid = null      # 敌弹网格（消弹查询——R7 接线，此前从未注入）
# R243 §2.5-6 cleave 常驻警戒弧状态
var _guard_left: float = 0.0                  # 警戒节拍倒计时（0.1s 检查节拍）
var _guard_facing: float = AIM_FALLBACK.angle()   # 最近 aim_direction 缓存（无目标保持上次朝向）
# R243 §4.3 幻影斩计时队列（[{left: float, facing: float}]——轻量数组仿 _pulse_left）
var _phantom_queue: Array[Dictionary] = []


func setup(p_data: WeaponData, p_player: Node2D, p_deps: Dictionary) -> void:
	super(p_data, p_player, p_deps)
	_enemy_bullet_grid = p_deps.get("enemy_bullet_grid")
	orbs_bonus = 0
	orbit_field = null
	arc_slash = null
	_slash_pool.clear()
	_pulse_left = 0.0
	_guard_left = 0.0                           # R243 cleave 警戒弧起表（首拍即检查）
	_guard_facing = AIM_FALLBACK.angle()
	_phantom_queue.clear()


func has_target_now() -> bool:
	# R33 无敌人不开火门（用户反馈）：W8 力场 = 常驻判定场（非射击）直接放行；
	# W9 挥砍窗同门防空挥；W13 巨斩走交战门（二cx#2）。
	if _is_slash_mode():
		if _is_cleave_mode():
			# 二cx#2「有敌人靠近才攻击」（用户复反馈：原走 super 索敌 1600px 门——
			# 远处有敌 W13 也朝空气抡剑）。cleave 定身不追击：最近敌进有效半径×1.15
			# 交战圈才开砍；无近敌冷却保持就绪，敌一进圈即刻挥（节拍零补等）。
			return _cleave_engage_target() != null
		return super.has_target_now()
	return true


func acquire_target() -> Node2D:
	# R293 模拟刀 B·缝隙A：slash 模式（W9 族）索敌改走 1600 圆扫帧级共享条目——
	# 一次 query_circle(玩家位,1600) 同时供 ① nearest 派生（argmin 严格 <、遍历序
	# 与 query_nearest 同构——space_grid 两查询共用 _cells_in_range 行主序×桶插入序，
	# 平局同取首个，逐位等价）② OrbitField._tick_chase 的 leash 候选子集（同谓词
	# 保序过滤）。本体+同拍同位副本/镜面同帧共享一条目（SimQueryShare 帧纪元键）。
	# cleave/orbit 走基类（cleave 小 reach 交战门另走 shared_nearest 独立键——1600
	# 条目不得顶替进圈判定语义）。R220 单拍缓存语义原样保留（_tick_seq 键先闸——
	# 子拍坍缩不动；dead 过滤逐调用同基类口径）。
	if not _is_slash_mode():
		return super.acquire_target()
	if _in_tick and _acq_cache_seq == _tick_seq:
		return _acq_cache_target
	var found: Node2D = null
	if enemy_grid != null:
		var cand := SimQueryShare.slash_nearest(_in_tick, enemy_grid,
			muzzle_position())
		if cand != null and not bool(cand.get("dead")):
			found = cand
	_acq_cache_seq = _tick_seq
	_acq_cache_target = found
	return found


func _cleave_engage_target() -> Node2D:
	# 二cx#2 W13 交战门目标口：query_nearest(reach = 有效半径×CLEAVE_ENGAGE_MULT)
	# 最近活敌 + 中心距精判（query 口径含 +max_entity_radius(64px) 保守衬垫——超集
	# 候选直放会隐性放宽门到 reach+64；本门要的是「敌进圈」中心距语义）。
	# 网格缺席（装配中途/桩）→ null（门恒假不挥——防空挥主诉面优先）。返回值兼作
	# 朝向源候选（try_fire 侧 aim_direction 与本查询同最近敌——门过时两者恒同目标）。
	# R293 模拟刀 B：小 reach 门经 SimQueryShare 帧级共享（键含 reach——与 1600 条目
	# 分立成条，不放宽门；tick 栈内同帧二门〔has_target_now+try_fire 复检〕坍缩为
	# 每帧 1 实查，dead 过滤/中心距精判逐调用原样）。
	if enemy_grid == null:
		return null
	var reach := effective_slash_radius() * CLEAVE_ENGAGE_MULT
	var cand := SimQueryShare.shared_nearest(_in_tick, enemy_grid,
		muzzle_position(), reach)
	if cand != null and not bool(cand.get("dead")) \
			and cand.global_position.distance_to(muzzle_position()) <= reach:
		return cand
	return null


func try_fire() -> bool:
	# 近战形态"开火"= 周期性判定调度（hit_cd / cd）
	if data == null:
		return false
	if _is_slash_mode():
		if _is_cleave_mode():
			# R243 §2.5-2 W13 定身巨斩：剑不追击不建力场——交战门（二cx#2 has_target_now
			# 覆写：最近敌进有效半径×1.15 圈才开砍）→ 定向开弧（朝向 = aim_direction、
			# 中心 = muzzle_position；非随机 facing、非追击刀位）。判定/去重/挡弹/绘制
			# 复用 ArcSlash（_slash_pool 单槽）。
			if not has_target_now():
				return false
			var facing := aim_direction().angle()
			_open_slash(facing, muzzle_position())
			_queue_phantom_slashes(facing)      # §4.3 幻影斩（inert——词条门未扩前恒 0 道）
			return true
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
	# R243 §2.5-6：W13 cleave 待机期警戒弧（0.1s 节拍正面 90° 概率挡弹）+ 幻影斩计时
	if _is_cleave_mode():
		_tick_guard_arc(p_game_delta)
		_tick_phantom_slashes(p_game_delta)
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


func _tick_guard_arc(p_game_delta: float) -> void:
	# R243 §2.5-6/§3.3 W13 常驻警戒弧：cleave 待机期（无斩击窗）以 0.1s 节拍对正面
	# 90° 扇形（R245 §3.3 挡弹域 = BLOCK_RADIUS_TABLE[level] × ±45°——法器范围基准×40%
	# 静态表，不联动乘区）敌弹逐弹掷 bullet_block_chance()（W13 基线 0.30），帽 4/检查；
	# 挡下走 nullify() 统一收束 + 青涟漪 + bullet_parry。
	# _guard_facing = 最近 aim_direction 缓存（无目标保持上次朝向——正面身份不漂移）。
	# 斩击窗内的全弧挡弹由 ArcSlash 既有口承载（双域互补——窗内本侧停巡防双掷）。
	if data == null:
		return
	var target := acquire_target()
	if target != null and is_instance_valid(target) and not bool(target.get("dead")):
		var dir := (target.global_position - muzzle_position()).normalized()
		if dir != Vector2.ZERO:
			_guard_facing = dir.angle()
	if _slash_window_active():
		return                                  # 斩击窗：全弧挡弹归 ArcSlash（双域互补）
	_guard_left -= p_game_delta
	if _guard_left > 0.0:
		return
	_guard_left += GUARD_BEAT
	if _enemy_bullet_grid == null:
		return
	var chance := bullet_block_chance()
	if chance <= 0.0:
		return
	var reach := block_radius_for(level)
	var bullets: Array[Node2D] = _enemy_bullet_grid.query_arc(muzzle_position(), reach,
		_guard_facing, deg_to_rad(GUARD_HALF_ARC_DEG))
	var blocks := 0
	for bullet in bullets:
		if blocks >= GUARD_BLOCK_CAP:
			break
		if bullet is ProjectileBase and (bullet as ProjectileBase).team == 1:
			if chance >= 1.0 or randf() < chance:
				(bullet as ProjectileBase).nullify()
				blocks += 1
				DebugStats.count(&"bullet_parry")
				EventBus.emit_bullet_nullified((bullet as ProjectileBase).global_position)


func _slash_window_active() -> bool:
	# 斩击窗在开（任一槽 window_left > 0）——cleave 警戒弧停巡判据
	for s in _slash_pool:
		if is_instance_valid(s) and s.window_left > 0.0:
			return true
	return false


func _queue_phantom_slashes(p_facing: float) -> void:
	# R243 §4.3 幻影斩（MEC_ORBIT_LINK，inert）：每层 +1 道追加斩——facing + 90°×i、
	# 错帧 0.12s（轻量计时数组仿 _pulse_left）、全额伤害（复用 _open_slash 全额面板）。
	# 额外 +2 封顶（§4.3 数量帽表——防重武器乘层数爆炸）；词条门未扩 W13 前 _orbit_link_count
	# 恒 0 = 零追加斩（行为零变化）。
	var extra := mini(_orbit_link_count(), PHANTOM_CAP)
	for i in range(extra):
		_phantom_queue.append({
			"left": PHANTOM_STAGGER * float(i + 1),
			"facing": wrapf(p_facing + PHANTOM_HALF_TURN * float(i + 1), 0.0, TAU),
		})


func _tick_phantom_slashes(p_game_delta: float) -> void:
	# 幻影斩计时推进：到期道次即开弧（全额伤害），未到期保留（错帧 0.12s/道）
	if _phantom_queue.is_empty():
		return
	var remain: Array[Dictionary] = []
	for entry in _phantom_queue:
		var left := float(entry.get("left", 0.0)) - p_game_delta
		if left <= 0.0:
			_open_slash(float(entry.get("facing", 0.0)), muzzle_position())
		else:
			entry["left"] = left
			remain.append(entry)
	_phantom_queue = remain


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


static func block_radius_for(p_level: int) -> float:
	# R245 §3.3 挡弹域表读口：按武器 level（1..5）取档，钳表界（越界档回端点——
	# 测试桩/异常 level 零崩溃面）。静态单源：本文件警戒弧与 ArcSlash 斩击窗双域
	# 统一消费（同表同取法——挡弹是防御隐性机制，静态口径不联动乘区/质变/装备态）。
	return BLOCK_RADIUS_TABLE[clampi(p_level - 1, 0, BLOCK_RADIUS_TABLE.size() - 1)]


func effective_slash_radius() -> float:
	# R65 挥砍判定半径 = 逐级参数 × 巨刃乘区（MEC_GIANT_BLADE 每层 +20%）
	# R196 ×_range_mult()：AFF_RANGE 广域印刻（W9/W13 判定半径 + 追击 leash _orbit_params
	# 同源联动——判定半径经 ArcSlash.open_window 注入，本值即唯一真源）
	# R243 ⑨：巨刃/广域乘区 helper 已上移 WeaponBase（调用点零改名——
	# R_cleave = slash_radius_levels[L] × (1+0.2×G) × (1+Σadd_range)，公式逐位同源）
	# R243 §7.2 尾乘 transcend.radius_mult（W9 碧涛旋舞 ×1.15；W13 无此键恒 1.0 零位移）
	return _leveled_param("slash_radius", float(data.melee.get("slash_radius", 150.0))) \
		* (1.0 + 0.2 * float(_giant_blade_layers())) * _range_mult() \
		* _tc_mult("radius_mult", 1.0)


func effective_arc_deg() -> float:
	# R243 §7.2 挥斩弧角终值 = 逐级参数 + transcend.arc_bonus_deg（仅质变；W9 碧涛旋舞
	# 160°+40°=200°、W13 裂地斩 180°+90°=270°；未质变 = 逐级值零位移）。
	# 消费点 = _ensure_slash_instance spawn（池槽质变后经 _respawn_slash_pool 重铺）。
	var arc := _leveled_param("arc_deg", float(data.melee.get("arc_deg", 120.0)))
	return arc + _tc_mult("arc_bonus_deg", 0.0)


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
	# R243 §3.3：补敌弹网格注入（OrbitField.enemy_bullet_grid 新字段——W8 刀位挡弹查询）。
	# 仅环绕/追击模式经本口建场——cleave 不建 OrbitField（无追击刀/无 leash）。
	orbit_field = OrbitField.new()
	orbit_field.name = "OrbitField"
	add_child(orbit_field)
	orbit_field.weapon = self                   # 结算宿主注入（缺失 → OrbitField.tick 判定早退）
	orbit_field.enemy_bullet_grid = _enemy_bullet_grid   # R243 §3.3 W8 刀位挡弹
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
	# W9 零波及：ArcSlash 击退 = spawn 期快照（_slash_knockback_snapshot——R243 §2.5-4），
	# 本值仅 OrbitField 环绕模式击退消费。
	if trait_stack != null:
		knockback += float(trait_stack.aggregate_panel().get("add_knock", 0.0))
	var out := {
		# R243 §7.2 W8 苍狼啸月：orbs 终值 +transcend.orbs_bonus（+2——MEC_ORBIT_LINK
		# 同通道加算，仅质变；未质变 _tc_mult 缺省 0.0 零位移）
		"orbs": int(orbs_n) + orbs_bonus + _orbit_link_count()
			+ int(round(_tc_mult("orbs_bonus", 0.0))),
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
		# R243 §7.2 苍狼啸月：引爆当量 +transcend.detonate_mult_add（加算 ×5→×6.5——
		# MEC_CRITICAL_MASS 同通道平加）；引爆半径 ×transcend.radius_mult（×1.1）
		"charge_max": float(data.melee.get("charge_max", 5.0)),
		"charge_gain_cd": maxf(gain_cd, 0.05),
		"detonate_mult": float(data.melee.get("detonate_mult", 5.0))
			+ _crit_mass_mult_bonus() + _tc_mult("detonate_mult_add", 0.0),
		"detonate_radius": maxf(float(data.melee.get("detonate_radius", 90.0)) * radius_bonus
			* _tc_mult("radius_mult", 1.0), 1.0),
		"effective_blade_cap": int(data.melee.get("effective_blade_cap", 8)),
		"detonate_global_icd": float(data.melee.get("detonate_global_icd", 0.5)),
		"style": String(style) if style != &"" else "orb",
		"knife_scale": 1.0 + _giant_blade_value() * float(_giant_blade_layers()),
		# R65 巨刃：刀体视觉 +value/层（R199 F01：改读 data.value——白 0.25/金 0.65 与卡面一致）
	}
	if _is_slash_mode() and not _is_cleave_mode():
		# R65 W9 追击键组（R243 §2.5-3 cleave 守卫：巨斩不注入追击键——无追击刀/无 leash）
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


func refresh_orbit_field() -> void:
	# 已常驻力场按当前参数重铺（R65：W8/W9 双模式通用——追击模式刀数/巨刃/等级即时
	# 生效；诺亚僚机召唤/还原通道同口）；力场未建（首开火前）→ 无需重铺
	#（orbs_bonus 由 _ensure_orbit_field 自然生效）
	if orbit_field == null or not is_instance_valid(orbit_field):
		return
	orbit_field.spawn(_orbit_params())


func _ensure_slash_instance() -> ArcSlash:
	# 挥斩实例创建/复用（R65 多刀池：每把贴身刀各开一弧；池随用随建，槽 0 = arc_slash 兼容口）
	# R243 §2.5-4/§3.1 W13 增补：cleave 巨斩 = greatsword 刀形 + block_chance 掷骰挡弹
	# （0.30——ArcSlash ⑥ 消费口已入库）。W9 = saber（缺省）+ 旧口径哨兵 -1（nullify→1.0
	# 否则 0.0——桩夹具零位移）。击退改 spawn 期快照（§2.5-4；W9 基值 0——MEC_KNOCK
	# excluded_weapons 下架——零位移；W13 基值 100，Σadd_knock 与质变 +80 在消费侧平加）。
	# R243 §7.2：spawn 参数集统一 _slash_spawn_params（质变重铺 _respawn_slash_pool 同源）。
	var slash := ArcSlash.new()
	slash.name = "ArcSlash%d" % _slash_pool.size()
	add_child(slash)
	slash.weapon = self
	slash.enemy_grid = enemy_grid
	slash.enemy_bullet_grid = _enemy_bullet_grid   # R7 接线：消弹查询（此前恒 null = W9 消弹死功能）
	slash.spawn(_slash_spawn_params())
	_slash_pool.append(slash)
	if arc_slash == null or not is_instance_valid(arc_slash):
		arc_slash = slash                     # 兼容观测口（槽 0）
	return slash


func _slash_spawn_params() -> Dictionary:
	# R243 §7.2 挥斩 spawn 参数集单源（_ensure_slash_instance / _respawn_slash_pool 共用）：
	# 弧角走 effective_arc_deg（质变 arc_bonus_deg 尾加——W9 200°/W13 270°）；质变态位与
	# 同心回斩键（echo_ratio/echo_delay——W9 碧涛旋舞 0.5/0.18；W13 无键缺省 0=禁用）。
	# R243 评审修复（发现批次）：W13 挡弹也传 -1 哨兵走 weapon.bullet_block_chance() live
	# 口（W9 同款先例）——原 block_chance spawn 快照 0.30 在 ArcSlash._bullet_block_chance
	# 的 >=0 短路分支下把挥斩窗钉死在 0.30，MEC_BULLET_PARRY 成长（0.30→0.54）对斩击窗
	# 永不生效（仅警戒弧走 live）。-1 哨兵 = 窗内逐 tick live 读（基线 + Σadd_block 即时
	# 聚合）；weapon 宿主由 _ensure_slash_instance 恒注入，无桩回落风险。
	return {
		"slash_radius": _leveled_param("slash_radius", float(data.melee.get("slash_radius", 150.0))),
		"arc_deg": effective_arc_deg(),
		"max_targets": int(data.melee.get("max_targets", 8)),
		"knockback": _slash_knockback_snapshot(),
		"nullify": bool(data.melee.get("nullify", false)),
		"blade_style": (&"greatsword" if _is_cleave_mode() else &"saber"),
		"crystal": true,                        # R267 视觉刀：水晶配方风格键（§2.4 W13
		                                        # spawn 接线——激活仍需元素池非 KIN，ArcSlash
		                                        # 侧 live 判；子斩/回斩经 _open_child_slash 继承）
		"block_chance": -1.0,
		"transcended": transcended,
		"echo_ratio": _tc_mult("echo_ratio", 0.0),
		"echo_delay": _tc_mult("echo_delay", 0.18),
	}


func _respawn_slash_pool() -> void:
	# R243 §7.2 质变重铺：已建池槽按当前参数重 spawn（弧角/击退/贴图差/回斩键即时生效
	# ——spawn 复位窗口态与子斩窗；升级时点窗口重建可接受，refresh_orbit_field 重铺
	# 蓄能闸同口径）。未建池 = 首开火自然带新参数，无需处理。
	for s in _slash_pool:
		if is_instance_valid(s):
			s.spawn(_slash_spawn_params())


func _on_transcend() -> void:
	# R243 §7.1 质变重铺钩子（OrbitWeapon 系）：W8 苍狼啸月 = 力场重铺（orbs+2/引爆
	# 6.5/半径 ×1.1 即时生效）；W9/W13 = 挥斩池槽重铺（弧角/击退/贴图差/回斩键）。
	refresh_orbit_field()
	_respawn_slash_pool()


func _slash_knockback_snapshot() -> float:
	# R243 §2.5-4 挥斩击退 spawn 期快照 = data.melee.knockback 基值（纯数据快照；
	# Σadd_knock 由 ArcSlash._slash_hit 消费侧平加——快照不聚合防双加）。W9 基值 0
	#（MEC_KNOCK excluded_weapons 下架）零位移；W13 基值 100，质变「裂地斩」加
	# transcend.knockback_add（+80 → 180——§7.2，消费侧平加池照旧）。
	if data == null:
		return 0.0
	return float(data.melee.get("knockback", 0.0)) + _tc_mult("knockback_add", 0.0)


# 兼容别名（旧调用方/测试）
func _ensure_arc_slash() -> void:
	_ensure_slash_instance()


func set_enemy_bullet_grid(p_grid: SpaceGrid) -> void:
	# 敌弹网格注入（GameLoop 帧序③ enemy_bullet_grid——包 4 集成期接线；消弹查询）
	# R243 §3.3：力场常驻场景同步补注（W8 刀位挡弹查询与 ArcSlash 同源）
	_enemy_bullet_grid = p_grid
	if orbit_field != null and is_instance_valid(orbit_field):
		orbit_field.enemy_bullet_grid = p_grid
	for slash in _slash_pool:
		slash.enemy_bullet_grid = p_grid


func _is_slash_mode() -> bool:
	# R243 §2.5-1 改义（mode 键单源 WeaponBase.melee_mode_of）：mode ∈ {slash, cleave}——
	# 缺省回落 nullify 旧口径（true→slash / false→orbit，桩夹具兼容）；W9 .tres 显式
	# mode:"slash" 后行为同值。
	if data == null:
		return false
	var mode := WeaponBase.melee_mode_of(data.melee)
	return mode == "slash" or mode == "cleave"


func _is_cleave_mode() -> bool:
	# R243 §2.5 W13 定身巨斩模式判定（mode 单源同上）
	if data == null:
		return false
	return WeaponBase.melee_mode_of(data.melee) == "cleave"


func _leveled_param(p_key: String, p_default: float) -> float:
	# 逐级形态参数（形态段新增键 <key>_levels: Array[float]——A3 §3.8/§3.9 逐级递进）
	# QA-heal r1：键串拼每调新建 String = 常量税（贴脸豁免圈逐帧折算/化身扫弧逐帧触达）
	# ——改 WeaponBase._leveled_key 静态键缓存（映射全局不变，零失效面）
	var levels: Variant = data.melee.get(WeaponBase._leveled_key(p_key), null)
	if levels is Array and level >= 1 and level <= (levels as Array).size():
		return float((levels as Array)[level - 1])
	return p_default


# ── R243 §7.2 W13 裂地斩图标（texture_factory 委托臂消费——static func） ─────────
# 共享工厂 _delegate_weapon_icon 的 "W13_great_sword" 臂指向本脚本同名静态口（w1 预埋）；
# 默认 = 黑金巨剑（暗黑刃身 + 金刃口）；质变 = 刀身加宽 1.3× + 金色裂纹纹路。
# 贴图生成放本脚本（不动共享 TextureFactory；栅格内核只读复用其 static 光栅化口；
# 缓存在本脚本 static——勿写共享 _cache，单一写者纪律）。

static var _icon_cache: Dictionary = {}    # 图标本地缓存（键 base/t2）

const ICON_BLADE_DARK := Color(0.16, 0.15, 0.2)        # 暗黑刃身（§2.5 底色）
const ICON_EDGE_GOLD := Color(0.95, 0.78, 0.35)        # 金刃口（§2.5）
const ICON_GUARD_DEEP := Color(0.35, 0.28, 0.12)       # 护手暗金
const ICON_T2_WIDEN := 1.3                             # 质变刀身加宽 1.3×（§7.2）


static func weapon_icon_tex(p_transcended: bool) -> ImageTexture:
	# R243 W13 图标（56px 画布朝上 -Y——化身 +90° 朝向补偿经 _is_blade_weapon 白名单）。
	var key := "t2" if p_transcended else "base"
	if _icon_cache.has(key):
		return _icon_cache[key]
	var tex: ImageTexture = TextureFactory._render(56, 56,
		TextureFactory._shade(_icon_layers(p_transcended)))
	_icon_cache[key] = tex
	return tex


static func _icon_layers(p_transcended: bool) -> Array:
	# 图层集（layer = {sd: SDF Callable, fill: Color, ow: 描边宽}——TextureFactory._shade 契约）。
	# 二cu DNF 巨剑重画（用户「阔剑应该是dnf 巨剑那种形象」）：旧版 = 渐缩宽刃（弯刀读感
	# 不够「巨」）→ 平行等宽厚重直刃 + 长斜角巨尖 + 双侧金刃口 + 宽展大护手 + 短柄大珠
	#（刃长 ≫ 柄长 = 巨剑比例）。质变 = 刃身再展 ×1.25 + 金色裂纹三道（口径承 §7.2）。
	var widen := (ICON_T2_WIDEN * 0.96) if p_transcended else 1.0   # 底形已加宽——t2 微展防溢画布
	var _w := func(p_pts: PackedVector2Array) -> PackedVector2Array:
		var out := PackedVector2Array()
		for pt in p_pts:
			out.append(Vector2(pt.x * widen, pt.y))
		return out
	var blade: PackedVector2Array = _w.call(PackedVector2Array([   # 巨剑刃身（平行等宽 + 长斜角尖）
		Vector2(0.0, -26.0), Vector2(7.2, -15.0), Vector2(7.6, -2.0), Vector2(6.2, 6.0),
		Vector2(-6.2, 6.0), Vector2(-7.6, -2.0), Vector2(-7.2, -15.0),
	]))
	var edge_r: PackedVector2Array = _w.call(PackedVector2Array([   # 金刃口·右（DNF 巨剑双发光刃口）
		Vector2(7.3, -14.0), Vector2(7.7, -2.0), Vector2(6.3, 5.0),
		Vector2(5.3, 4.4), Vector2(6.5, -1.6), Vector2(6.4, -13.4),
	]))
	var edge_l: PackedVector2Array = _w.call(PackedVector2Array([   # 金刃口·左（镜像）
		Vector2(-7.3, -14.0), Vector2(-7.7, -2.0), Vector2(-6.3, 5.0),
		Vector2(-5.3, 4.4), Vector2(-6.5, -1.6), Vector2(-6.4, -13.4),
	]))
	var layers: Array = [
		# R267 视觉刀：水晶外壳层（金色 aura——W13 黑金身份的晶壳读感；暗黑底未钳，
		# §2.2 评审⑦ 黑金契约同守；c′ 防混搭特征层）
		{"sd": TextureFactory._poly_sd(CrystalBladeFactory.expand_poly(blade,
			CrystalBladeFactory.ICON_SHELL_EXPAND)),
			"fill": CrystalBladeFactory.icon_shell_color(ICON_EDGE_GOLD), "ow": 0.0},
		{"sd": TextureFactory._poly_sd(blade), "fill": ICON_BLADE_DARK, "ow": 2.6},
		{"sd": TextureFactory._poly_sd(edge_r), "fill": ICON_EDGE_GOLD, "ow": 0.0},
		{"sd": TextureFactory._poly_sd(edge_l), "fill": ICON_EDGE_GOLD, "ow": 0.0},
		# 中央刃脊暗金粗线（厚重读感）
		{"sd": TextureFactory._box_at(Vector2(0.0, -9.0), Vector2(1.4, 14.0), 0.6),
			"fill": ICON_GUARD_DEEP, "ow": 0.0},
		# 宽展大护手（十字横档 + 两端圆钉——巨剑肩宽）
		{"sd": TextureFactory._box_at(Vector2(0.0, 8.5), Vector2(11.0, 2.4), 1.2),
			"fill": ICON_GUARD_DEEP, "ow": 2.2},
		{"sd": TextureFactory._circle_at(Vector2(-10.6, 8.5), 1.5), "fill": ICON_EDGE_GOLD,
			"ow": 0.0},
		{"sd": TextureFactory._circle_at(Vector2(10.6, 8.5), 1.5), "fill": ICON_EDGE_GOLD,
			"ow": 0.0},
		# 短柄 + 大柄珠（刃长 ≫ 柄长）
		{"sd": TextureFactory._box_at(Vector2(0.0, 14.5), Vector2(2.0, 4.0), 1.2),
			"fill": ICON_GUARD_DEEP, "ow": 2.2},
		{"sd": TextureFactory._circle_at(Vector2(0.0, 19.5), 2.6), "fill": ICON_EDGE_GOLD,
			"ow": 0.0},
	]
	if p_transcended:
		# 金色裂纹（刃面三道折线纹——裂地斩质变读感；_poly_sd 窄长四边形近似细裂缝）
		for crack: Array in [
			[Vector2(-2.6, -16.0), Vector2(-3.6, -12.0), Vector2(-2.2, -8.5)],
			[Vector2(2.8, -13.0), Vector2(3.8, -8.0), Vector2(2.4, -3.0)],
			[Vector2(-1.2, -6.0), Vector2(-2.4, -1.0), Vector2(-0.8, 3.5)],
		]:
			var pts: PackedVector2Array = PackedVector2Array(crack)
			var crack_pts := PackedVector2Array()
			for i in range(pts.size()):
				crack_pts.append(pts[i] + Vector2(0.55, 0.0))
				crack_pts.append(pts[i] - Vector2(0.55, 0.0))
			layers.append({"sd": TextureFactory._poly_sd(crack_pts),
				"fill": ICON_EDGE_GOLD, "ow": 0.0})
	CrystalBladeFactory.note_icon_built(&"W13_great_sword")   # R267 c′ 机制标记
	return layers

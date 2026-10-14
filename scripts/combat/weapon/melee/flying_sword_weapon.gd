# scripts/combat/weapon/melee/flying_sword_weapon.gd
# R243 法器·灵剑 FlyingSwordWeapon（W11_spirit_sword，设计 §2.2）：
# · 每拍（cd 通道 _fire_interval=cd×(1−ΣCDR)/rof_mult，AFF_CDR 经基类自动生效）向最近
#   敌人发射真投射物（projectile_pool.acquire，team=0），复用整条弹体管线（_submit_hit
#   四件套：暴击/乘区/ON_HIT 派发/附着——迸发/暴击/元素附着免费获得）。
# · 单体语义 = pierce=1：命中 1 敌即 PIERCE_DEPLETED 回收（projectile_base.gd:1033-1038
#   既有路径），永不穿过多目标（§1.4「法器无穿透概念」= 永不穿过多目标）。
# · 飞剑形态键 flight_sword=true（w1 弹体分支消费：贴图顺速度方向+刺击残影；分裂子代
#   继承 flight_sword——projectile_base.gd:1211-1212，本侧只断言挂 MEC_FRACTAL 时子代
#   flight_sword=true，request_split 三重闸门在引擎侧）。
# · 飞行路径消弹（§3.2）：每 tick enemy_bullet_grid.query_circle(剑位,
#   effective_radius()+4) 全消，nullify=true → bullet_block_chance()=1.0 确定性，
#   帽 6/tick（性能护栏，逐弹掷骰前先网格查询）。
# · 数量挂点（§4.3）：齐射剑数 = 1 + min(_orbit_link_count(), 6)（额外 +6 封顶）。
#   齐射分配（R243 评审修复——需求 8 可读性）：第 i 剑掷向第 i 近敌（W12 斧群
#   _acquire_throw_plans 同式）；目标不足回落 ±SLOT_FAN_DEG/剑 微角扇出（slot 0 恒贴
#   aim 基向）——修「全部同膛平行出射 → 最近单敌吃 N 倍单击、数量词条读作隐形单体
#   倍伤」（pierce=1 命中即没入，平行剑与首剑同归一敌）。质变 volley（§7.2 万剑诀）
#   的 ±fan_deg 扇形在 slot 角之上叠加，语义不变。
# · 质变挂点（w4 消费，§7.2）：volley/fan_deg 读 _transcend_params——pre-w4 WeaponBase
#   无 transcended/_transcend_params 键 = 单剑（get/has_method 守卫，w4 落地自动激活）。
# · 图标：static func weapon_icon_tex(p_transcended)（56px 画布朝上 -Y；默认银蓝小剑竖剑
#   +白刃光，质变鎏金）——贴图函数放本脚本，不动共享 TextureFactory（其委托臂
#   texture_factory.gd:1535-1552 自动接管；layers/_shade/_render 管线口径仿同文件）。
class_name FlyingSwordWeapon
extends WeaponBase

# ── 固定参数（§2.2——数值锚定全在 W11_spirit_sword.tres 与本表常量） ──
const SWORD_LIFE_MULT := 1.15                  # 寿命 = range/speed×1.15（随射程自动延长——AFF_RANGE 消费点）
const SWORD_RANGE_FLOOR := 10.0                # 射程地板（超短数据兜底）
const SWORD_HIT_GROWTH := 0.2                  # 巨刃判定乘率 0.2/层（W9 挥砍半径同源 orbit_weapon.gd:165-170）
const LINK_EXTRA_CAP := 6                      # 齐射额外剑数封顶（§4.3 W11 帽）
const SLOT_FAN_DEG := 4.0                      # 目标不足时齐射扇出档（±4°/剑，slot 错位）
const SWORD_ACQUIRE_RADIUS := 1600.0           # 齐射索敌半径（acquire_target 同域，W12 斧群同式）
const PATH_CLEAR_MARGIN := 4.0                 # 路径消弹查询余量（query 半径 = 判定半径+4，§3.2）
const PATH_CLEAR_CAP := 6                      # 单剑单 tick 消弹帽（性能护栏）

var enemy_bullet_grid: SpaceGrid = null        # 敌弹网格（路径消弹查询——deps 注入同 OrbitWeapon 口径）
var _swords: Array[Node2D] = []                # 本武器在场飞剑引用（路径消弹驱动面；回收即出列）
var _primary_target_pos: Vector2 = Vector2.ZERO  # 二cu 合一：最近敌位快照（化身出击落点）
var _has_primary_target: bool = false            # 同上（无目标时出击按射程半程回落）


func muzzle_position() -> Vector2:
	# 二cu 合一：剑光从悬浮化身剑尖出膛（弹道武器同口径 _avatar_muzzle——R25「发射口
	# 和武器对上」纪律；化身出击期间实时跟随出击位，本尊在环位兜底）
	return _avatar_muzzle()


func setup(p_data: WeaponData, p_player: Node2D, p_deps: Dictionary) -> void:
	super(p_data, p_player, p_deps)
	enemy_bullet_grid = p_deps.get("enemy_bullet_grid")
	_swords.clear()


func try_fire() -> bool:
	# 每拍齐射：第 i 剑掷向第 i 近敌（R243 评审修复——需求 8 可读性；W12 斧群同式），
	# 目标不足回落 ±SLOT_FAN_DEG/剑 扇出（slot 0 恒贴 aim 基向——单剑行为逐位不变）。
	# 无目标时 aim 回退 UP。质变 volley（§7.2 万剑诀）>1 时在其上按 fan_deg ±扇形展开。
	# 池满丢弃计数（AC-14.4 同口径）。
	if data == null or projectile_pool == null:
		return false
	var speed := _sword_speed()
	var flight_range := _sword_range()
	var life := maxf(flight_range / maxf(speed, 1.0), 0.1) * SWORD_LIFE_MULT
	var pierce_cnt := _sword_pierce()
	var hit_r := _sword_hit_radius()
	var muzzle := muzzle_position()
	var dir := aim_direction()
	var perp := dir.orthogonal()
	var panel_snap := build_panel_snapshot()
	var elems := _element_pool()
	var volley := _sword_volley_count()
	var fan := deg_to_rad(_sword_fan_deg())
	var aim_dirs := _acquire_aim_dirs(dir, _volley_sword_count())
	var fired := 0
	for slot in range(_volley_sword_count()):
		for v in range(volley):
			# slot 角 = 本剑方位相对 aim 基向的有符号差（第 i 近敌方向 / 扇出兜底档）；
			# 质变 volley 扇形叠加其上（slot 0 单剑时 angle==0——pre-fix 行为零位移）
			var angle := dir.angle_to(aim_dirs[slot])
			if volley > 1:
				angle += -fan + 2.0 * fan * float(v) / float(volley - 1)
			var proj := projectile_pool.acquire() as ProjectileBase
			if proj == null:
				DebugStats.count(&"w11_spawn_dropped")   # 池满丢弃计数（AC-14.4 拒收率审计口）
				return fired > 0
			_inject_projectile_deps(proj)
			proj.spawn({
				# 出膛位 2px/剑横向微分离（纯视觉防像素重合——R196 W1「多重装填弹丸像素
				# 重合读作未生效」同款读感护栏；2px ≪ 9px 判定半径，判定口径零位移）
				"position": muzzle + perp * (2.0 * float(slot)),
				"velocity": dir.rotated(angle) * speed,
				"lifetime": life,
				"pierce": pierce_cnt,
				"bounces": 0,
				"hitbox_radius": hit_r,
				"element": _element_pick(elems),
				"attach_value": 0.0,
				"generation": 0,
				"weapon_uid": uid,
				"weapon_ref": self,
				"panel_snapshot": panel_snap,
				"trait_stack": trait_stack.acquire_runtime() if trait_stack != null else null,
				"team": 0,
				# ── R243 形态键（§2.2 spawn 键集——w1 弹体分支消费） ──
				"flight_sword": true,
				"attach_elements": elems.duplicate(),
			})
			# 池节点复用防重：先擦本武器对同一节点的陈旧引用（上柄飞剑已回收但尚未轮到
			# 逐 tick 出列时，池 LIFO 复用同节点发新剑——不擦则同节点双引用、消弹循环
			# 对一柄剑跑多轮）；erase 按对象恒等比对，无陈旧引用时 O(n) 空扫无害
			_swords.erase(proj)
			_swords.append(proj)
			fired += 1
	if fired > 0:
		_notify_avatar_sortie(aim_dirs[0], flight_range)
	return fired > 0


func _notify_avatar_sortie(p_dir: Vector2, p_range: float) -> void:
	# 二cu 法器合一（用户「原本环绕的那个就是跑去砍人那个」）：开火即通知化身层出击——
	# 环绕灵剑化身本身扑向主目标（最近敌）再回环，连续开火 = 化身连续出击（去原地空转）。
	# 纯表现通道：player 无该口（旧桩/测试环境）静默跳过，判定/数值零参与。
	if player == null or not is_instance_valid(player) or not player.has_method(&"weapon_avatar_sortie"):
		return
	var to := muzzle_position() + p_dir * p_range * 0.5   # 无目标：射程半程方向位
	if _has_primary_target:
		to = _primary_target_pos                          # 有目标：扑向最近敌身位
	player.call(&"weapon_avatar_sortie", self, to)


func _on_tick_post(p_game_delta: float) -> void:
	# 飞剑飞行路径消弹（§3.2）：每 tick 对每柄在场飞剑 query_circle 剑位全消（帽 6）。
	_tick_path_nullify()


# ── 数值口（§2.2 固定参数单源） ──────────────────────────────────
func _sword_speed() -> float:
	# 刺击弹速 860px/s（melee.sword_speed；弹道段不适用——速度走 spawn 键，无 add_spd 消费）
	return maxf(float(data.melee.get("sword_speed", 860.0)), 1.0)


func _sword_range() -> float:
	# 飞行射程 = sword_range × (1+Σadd_range)（AFF_RANGE 消费点——_range_mult 上移副本）
	return maxf(float(data.melee.get("sword_range", 420.0)), SWORD_RANGE_FLOOR) * _range_mult()


func _sword_pierce() -> int:
	# 单体语义：升级表 pierce 列（L1~L5 恒 1）；表缺键回落 melee.pierce（桩夹具兼容）
	var p := int(get_stat(&"pierce"))
	if p <= 0:
		p = int(data.melee.get("pierce", 1))
	return maxi(p, 1)


func _sword_hit_radius() -> float:
	# 刺击判定半径 = hitbox_r × (1+0.2×G)，G=MEC_GIANT_BLADE 层数（§2.2 体积判定成长式；
	# G=0/1/2 → 9.0/10.8/12.6 px）。size_mult 恒 1（成长在本侧乘好再传，不走 AFF_AREA 池）
	return maxf(float(data.hitbox_r), 1.0) * (1.0 + SWORD_HIT_GROWTH * float(_giant_blade_layers()))


# ── 数量/质变挂点 ────────────────────────────────────────────────
func _volley_sword_count() -> int:
	# 齐射剑数 = 1 + min(_orbit_link_count(), 6)（§4.3——消费侧自行 mini，额外 +6 封顶；
	# MEC_ORBIT_LINK 上架扩列由 T5 词条矩阵任务完成，本挂点先行 inert）
	return 1 + mini(_orbit_link_count(), LINK_EXTRA_CAP)


func _acquire_aim_dirs(p_base: Vector2, p_count: int) -> Array[Vector2]:
	# 齐射分配（R243 评审修复——需求 8 可读性；W12 斧群 _acquire_throw_plans 同式）：
	# 第 i 剑 → 第 i 近敌方位快照；目标不足回落 ±SLOT_FAN_DEG/剑 扇出（+4/-4/+8……
	# 错位出射角域，W12 ±20° 同式档位递增）；slot 0 恒贴 p_base（aim 基向）——目标足额时
	# 各剑分敌，单目标不再吃 N 倍齐射单击（pierce=1 平行剑全归一敌的隐形单体倍伤）。
	var dirs: Array[Vector2] = []
	if p_count < 1:
		return dirs
	var from := muzzle_position()
	var sorted: Array[Node2D] = []
	if enemy_grid != null:
		for cand in enemy_grid.query_circle(from, SWORD_ACQUIRE_RADIUS):
			if cand != null and not bool(cand.get("dead")):
				sorted.append(cand)
	sorted.sort_custom(_nearer_from.bind(from))
	# 二cu 合一挂点：最近敌位快照（化身出击落点——slot 0 即 sorted[0]）
	_has_primary_target = not sorted.is_empty()
	if _has_primary_target:
		_primary_target_pos = (sorted[0] as Node2D).global_position
	for i in range(p_count):
		if i < sorted.size():
			var to: Vector2 = (sorted[i] as Node2D).global_position - from
			dirs.append(to.normalized() if to.length_squared() > 1.0 else p_base)
		elif not dirs.is_empty():
			var steps := (i + 1) / 2              # 整除递增档（W12 错位同式）
			var side := 1.0 if (i % 2) == 1 else -1.0
			dirs.append(p_base.rotated(deg_to_rad(SLOT_FAN_DEG) * side * float(steps)))
		else:
			dirs.append(p_base)                   # slot 0 兜底（无目标/零距异常）
	return dirs


func _nearer_from(p_a: Node2D, p_b: Node2D, p_from: Vector2) -> bool:
	# 索敌距离序比较（sort_custom bind 载体——第 i 剑掷第 i 近敌；W12 同式本侧副本）
	return p_from.distance_squared_to(p_a.global_position) \
		< p_from.distance_squared_to(p_b.global_position)


func _transcend_active() -> bool:
	# w4 交付 WeaponBase.transcended 前的守卫读（属性缺位 get 返 NIL——bool(NIL) 在
	# Godot 4.3 是运行时错误「Nonexistent 'bool' constructor」，必须 typeof 显式判型）
	var flag: Variant = get("transcended")
	return typeof(flag) == TYPE_BOOL and flag


func _sword_volley_count() -> int:
	# 质变每剑倍数（§7.2 万剑诀 volley 3.0）——pre-w4 单剑：WeaponBase.transcended /
	# _transcend_params 由 w4 交付（get/has_method 守卫，数据表 transcend 占位不提前生效）
	if not _transcend_active() or not has_method(&"_transcend_params"):
		return 1
	return maxi(int(round(float(call(&"_transcend_params").get("volley", 1.0)))), 1)


func _sword_fan_deg() -> float:
	# 质变扇形角（万剑诀 fan_deg 10.0，±10° 展开）——pre-w4 恒 0（同上守卫）
	if not _transcend_active() or not has_method(&"_transcend_params"):
		return 0.0
	return maxf(float(call(&"_transcend_params").get("fan_deg", 0.0)), 0.0)


func _inject_projectile_deps(p_proj: ProjectileBase) -> void:
	# 依赖注入（非初始值，不走 spawn 参数字典——契约 §2.7.1 注；ballistic 同口径）
	p_proj.damage_pipeline = damage_pipeline
	p_proj.enemy_grid = enemy_grid
	p_proj.pool = projectile_pool
	p_proj.elemental = elemental


# ── 飞行路径消弹（§3.2） ─────────────────────────────────────────
func _tick_path_nullify() -> void:
	# 每 tick 逐柄在场飞剑：query_circle(剑位, effective_radius()+4) → 逐弹掷骰统一口
	#（bullet_block_chance()：W11 nullify=true → 1.0 确定性全消）；帽 6/剑/tick（性能护栏）。
	# 出列判据：引用失效 / is_clean（已回收）/ weapon_uid 易主（池节点复用防串弹）。
	if enemy_bullet_grid == null or _swords.is_empty():
		return
	var chance := bullet_block_chance()
	if chance <= 0.0:
		return
	var kept: Array[Node2D] = []
	for sword in _swords:
		if not is_instance_valid(sword):
			continue
		var pb := sword as ProjectileBase
		if pb == null or pb.is_clean or pb.weapon_uid != uid:
			continue                                  # 已回收 / 池节点易主——出列
		kept.append(sword)
		var bullets: Array[Node2D] = []
		bullets.append_array(enemy_bullet_grid.query_circle(
			pb.global_position, pb.effective_radius() + PATH_CLEAR_MARGIN))
		var cleared := 0
		for bullet in bullets:
			if cleared >= PATH_CLEAR_CAP:
				break                                 # 帽 6/tick（弹幕洪峰护栏）
			var eb := bullet as ProjectileBase
			if eb == null or eb.team != 1 or eb.is_clean:
				continue                              # 只消在场敌弹（回收态/我方弹跳过）
			if chance < 1.0 and randf() >= chance:
				continue                              # 概率掷骰（法器 1.0 = 确定性短路）
			eb.nullify()                              # → NULLIFIED 统一收束（弹池回收）
			cleared += 1
			DebugStats.count(&"bullet_parry")         # 统一掷骰口计数（§3.1——与 bullet_nullified 并存）
			EventBus.emit_bullet_nullified(eb.global_position)
	_swords = kept


# ── 图标（static func——不动共享 TextureFactory，委托臂自动接管） ──
static func weapon_icon_tex(p_transcended: bool) -> ImageTexture:
	# 二cu 重画（用户「目前的阔剑给灵剑（再细点，发点光即可）」）：刃身 = 旧 W13 阔剑
	# 宽刃轮廓 ×0.6 宽（细版），银蓝配色 + 外辉光层（发点光——剑光武器读感）；56px 画布
	# 朝上 -Y 口径不变（化身 +90° 朝向补偿）。质变万剑诀 = 鎏金 + 暖辉。
	var blue := PopPalette.PLAYER
	var deep := blue.lerp(PopPalette.OUTLINE, 0.32)
	var blade := blue.lerp(Color.WHITE, 0.55)              # 银蓝剑身
	var edge := Color(1.0, 1.0, 1.0, 0.9)                  # 白刃光
	var glow := Color(blue.lerp(Color.WHITE, 0.45).r,
		blue.lerp(Color.WHITE, 0.45).g, blue.lerp(Color.WHITE, 0.45).b, 0.30)
	var guard := deep
	if p_transcended:
		blade = PopPalette.GOLD.lerp(Color.WHITE, 0.30)    # 质变鎏金剑身
		edge = Color(1.0, 0.96, 0.78, 0.95)                # 暖白刃光
		glow = Color(PopPalette.GOLD.r, PopPalette.GOLD.g, PopPalette.GOLD.b, 0.34)
		guard = PopPalette.GOLD.lerp(PopPalette.OUTLINE, 0.35)
	# 宽刃轮廓（旧 W13 阔剑刃形细版：尖 -24 / 肩 -12.9 / 最宽 -4 / 根 4）
	var slim := PackedVector2Array([
		Vector2(0.0, -24.0), Vector2(2.2, -12.9), Vector2(2.6, -4.0), Vector2(2.1, 4.0),
		Vector2(-2.1, 4.0), Vector2(-2.6, -4.0), Vector2(-2.2, -12.9),
	])
	var halo := PackedVector2Array()                       # 外辉光（同形 ×1.9 宽——发点光）
	for pt in slim:
		halo.append(Vector2(pt.x * 1.9, pt.y))
	var layers: Array = [
		# R267 视觉刀：水晶外壳层（c′ 防混搭特征层；身份银蓝/鎏金未钳——图标非
		# 元素染色路径）
		{"sd": TextureFactory._poly_sd(CrystalBladeFactory.expand_poly(slim,
			CrystalBladeFactory.ICON_SHELL_EXPAND)),
			"fill": CrystalBladeFactory.icon_shell_color(blade), "ow": 0.0},
		{"sd": TextureFactory._poly_sd(halo), "fill": glow, "ow": 0.0},
		{"sd": TextureFactory._poly_sd(slim), "fill": blade, "ow": 2.2},
		# 白刃光（剑脊细条 + 尖端提亮）
		{"sd": TextureFactory._box_at(Vector2(0.0, -7.0), Vector2(0.9, 9.5), 0.6),
			"fill": edge, "ow": 0.0},
		# 护手（细横档——灵剑轻灵）+ 柄 + 柄尾宝珠
		{"sd": TextureFactory._box_at(Vector2(0.0, 6.5), Vector2(5.2, 1.6), 1.0),
			"fill": guard, "ow": 2.0},
		{"sd": TextureFactory._box_at(Vector2(0.0, 12.0), Vector2(1.5, 4.2), 1.0),
			"fill": guard, "ow": 2.0},
		{"sd": TextureFactory._circle_at(Vector2(0.0, 17.0), 1.9), "fill": edge, "ow": 0.0},
	]
	if p_transcended:
		# 鎏金缀光（质变读感：柄尾两侧金色小星）
		layers.append({"sd": TextureFactory._circle_at(Vector2(-5.5, 15.0), 1.3),
			"fill": PopPalette.GOLD, "ow": 0.0})
		layers.append({"sd": TextureFactory._circle_at(Vector2(5.5, 15.0), 1.3),
			"fill": PopPalette.GOLD, "ow": 0.0})
	CrystalBladeFactory.note_icon_built(&"W11_spirit_sword")   # R267 c′ 机制标记
	return TextureFactory._render(56, 56, TextureFactory._shade(layers))


# ── 飞剑弹体贴图（projectile_base._VIS_SWORD 消费——static func，勿动共享 TextureFactory） ──
static var _flight_tex_cache: Dictionary = {}  # 弹体贴图本地缓存（键 base/t2——勿写共享 _cache）


static func flight_tex(p_transcended: bool, p_fill: Color = PopPalette.PLAYER,
		p_quality: int = -1) -> ImageTexture:
	# 二cy 剑形弹体重画（用户「白的跟子弹一样的，不会是灵剑吧…不是让你把灵剑做成子弹」）：
	# 二cu 纯光条（零护手零剑柄）读感=白色子弹，退役 → **真剑形**：细尖剑刃（-30..2）
	# + 十字护手（y 2..5）+ 短柄（5..13）+ 尾珠 + 双层刃辉光（「再细点，发点光」）。
	# 用户说的「一道痕（半透明）」= 命中剑痕（sword_mark→elemental_fx_layer 剑痕池），
	# 与弹体分工：弹体=剑本体飞出、痕=命中效果（G2 契约不变）。64px 画布朝上 -Y 口径
	# 不变（_apply_visual_rotation angle+PI/2 对齐速度——剑尖迎速向）。
	# 簇2 c2-③（R243 新武器 flight_tex 无色参缺口收口——晚于 R211 七条清单的漏登记项）：
	# 刃体基色参数化（R208 tracer_tex 同款）——元素附魔传元素表色；缺省 PLAYER 保原
	# 银蓝观感。质变鎏金（万剑诀）仅在 p_fill==缺省（KIN 未染）时参与键与换色=质变与
	# 元素撞车元素优先、KIN 才落鎏金（二cm/R241② 口径）；元素染时 t2 键归并 base，
	# 同色剑 t2/base 共享同贴图实例（桶合批友好）。
	# R267 视觉刀 §2.3/§2.4：元素染色 → 水晶配方（CrystalBladeFactory 烘焙形态——
	# 对应元素透明刀水晶质感，反馈 B；缓存键含 quality=低特效降级接 §2.5-4，质变键
	# 元素优先归并同 r248 F1c 口径）；KIN 缺省银蓝与质变鎏金走原配方逐位不动
	#（§2.2 豁免——is_identity_fill 二道闸同判）。
	if not CrystalBladeFactory.is_identity_fill(p_fill):
		var q := CrystalBladeFactory.live_fx_quality() if p_quality < 0 \
			else clampi(p_quality, 0, 2)
		return CrystalBladeFactory.crystal_tex(&"spirit_sword", p_fill, false, q)
	var tainted := p_transcended and p_fill == PopPalette.PLAYER
	var key := "%s|%s" % ["t2" if tainted else "base", p_fill.to_html()]
	if _flight_tex_cache.has(key):
		return _flight_tex_cache[key]
	var blue := p_fill
	var blade := blue.lerp(Color.WHITE, 0.55)                  # 银蓝剑刃
	var edge := Color(1.0, 1.0, 1.0, 0.95)                     # 白刃线
	var metal := blue.darkened(0.45)                           # 护手（同色系压深金属）
	var grip := blue.darkened(0.62)                            # 剑柄（最深——柄/刃一眼可分）
	var halo_o := Color(blue.lerp(Color.WHITE, 0.35).r,
		blue.lerp(Color.WHITE, 0.35).g, blue.lerp(Color.WHITE, 0.35).b, 0.24)
	var halo_m := Color(blue.lerp(Color.WHITE, 0.45).r,
		blue.lerp(Color.WHITE, 0.45).g, blue.lerp(Color.WHITE, 0.45).b, 0.44)
	if tainted:
		blade = PopPalette.GOLD.lerp(Color.WHITE, 0.30)        # 鎏金剑刃（仅 KIN 未染时——元素优先）
		edge = Color(1.0, 0.97, 0.80, 0.97)
		metal = PopPalette.GOLD.darkened(0.40)
		grip = PopPalette.GOLD.darkened(0.60)
		halo_o = Color(PopPalette.GOLD.r, PopPalette.GOLD.g, PopPalette.GOLD.b, 0.28)
		halo_m = Color(PopPalette.GOLD.lerp(Color.WHITE, 0.3).r,
			PopPalette.GOLD.lerp(Color.WHITE, 0.3).g,
			PopPalette.GOLD.lerp(Color.WHITE, 0.3).b, 0.46)
	# 剑刃主体（-Y 尖 -30 → 根 +2；肩最宽 ±2.6@-12、根 ±2.0——细剑比例）
	var sword_blade := PackedVector2Array([
		Vector2(0.0, -30.0), Vector2(1.4, -22.0), Vector2(2.6, -12.0),
		Vector2(2.0, 2.0), Vector2(-2.0, 2.0), Vector2(-2.6, -12.0), Vector2(-1.4, -22.0),
	])
	var halo := func(p_mult: float) -> PackedVector2Array:
		# 刃辉光（仅横向外扩 ×mult，纵向保持剑长——柄/护手不进辉光层）
		var pts := PackedVector2Array()
		for pt in sword_blade:
			pts.append(Vector2(pt.x * p_mult, pt.y))
		return pts
	var layers: Array = [
		# 双层刃辉光（外 ×2.6 α0.24 / 中 ×1.6 α0.44——发点光）
		{"sd": TextureFactory._poly_sd(halo.call(2.6)), "fill": halo_o, "ow": 0.0},
		{"sd": TextureFactory._poly_sd(halo.call(1.6)), "fill": halo_m, "ow": 0.0},
		# 剑刃主体 + 白刃锋线（右缘竖线 -24..0——锋利读感）
		{"sd": TextureFactory._poly_sd(sword_blade), "fill": blade, "ow": 1.4},
		{"sd": TextureFactory._box_at(Vector2(1.4, -12.0), Vector2(0.7, 12.0), 0.5),
			"fill": edge, "ow": 0.0},
		# 十字护手（横条 11px×3px——剑/弹一眼可分的结构读感）
		{"sd": TextureFactory._box_at(Vector2(0.0, 3.5), Vector2(5.5, 1.5), 0.5),
			"fill": metal, "ow": 0.8},
		# 剑柄（深色短柄）+ 尾珠
		{"sd": TextureFactory._box_at(Vector2(0.0, 9.0), Vector2(1.6, 4.0), 0.5),
			"fill": grip, "ow": 0.0},
		{"sd": TextureFactory._circle_at(Vector2(0.0, 13.5), 1.5), "fill": metal, "ow": 0.0},
	]
	var tex: ImageTexture = TextureFactory._render(64, 64, TextureFactory._shade(layers))
	_flight_tex_cache[key] = tex
	return tex

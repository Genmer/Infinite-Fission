# scripts/entities/player/weapon_orbit_avatars.gd
# R25 武器悬浮层（用户点名「所有武器都是悬浮在主角身边的形式，多武器动态绕主角排列」）：
# · 每把已装备武器一个化身（复用 weapon_icon 程序化贴图——零新美术），
#   N 把武器按槽位均匀分布在主角环绕环上，公转慢旋 + 悬浮呼吸。
# · W9 化身 = 真刀：无敌人时原位悬浮呼吸；挥斩窗口刀随窗口扫动（贴着挥砍弧旋转）。
# · 换武器即时重排（槽位扫描脏检查——化身贴图按武器 id 惰性换）。
# · 编排：玩家子节点（原点跟随），_process 自驱；纯表现层（零判定/数值副作用）。
class_name WeaponOrbitAvatars
extends Node2D

const RING_R := 58.0                          # 环绕半径 px（内环基准）
# 二cv#3 法器环绕分层（用户「一圈不够环绕就每种环绕一层，旋风第一层、第二个法器绕其外」）：
# 法器按装备序逐层外扩（第 1 把在 RING_R，第 2 把 +RING_STEP…），非法器恒内环——
# 挤在一圈的法器化身互相叠贴读感差，分层后每件法器独占一环清晰可辨
const RING_STEP := 30.0                       # 法器分层外扩步长 px（层差 ~化身直径，不叠不散）
const RITUAL_IDS := ["W8_orbit_field", "W9_arc_slash", "W11_spirit_sword",
	"W12_ground_axe", "W13_great_sword"]      # 法器集合（精确 id——分层判定唯一口径）
const SPIN := 0.7                             # 公转角速度 rad/s
const BOB_AMP := 4.0                          # 悬浮呼吸幅度 px
const BOB_FREQ := 2.2                         # 呼吸频率 rad/s
const AVATAR_SCALE := 0.62                    # 化身缩放（56px 画布 → ~35px）
# R245 §3.4-1 W13 化身随圈成长基准（= W13 L1 slash_radius 表值）：scale =
# AVATAR_SCALE × (effective_slash_radius / 130)——L1 0.62（≈35px 与现状一致零突兀）、
# L5 0.62×190/130 ≈ 0.907（≈51px）；环半径 RING_R/RING_STEP 不动（多武器共享环）。
const W13_AVATAR_BASE_R := 130.0
const MUZZLE_REACH := 18.0                    # 枪口前伸 px（56×0.62 半长 ~17 ≈ 枪口尖）
# 二cu 法器合一出击态（用户「原本环绕的那个就是跑去砍人那个…原地抽风的形象就可以去掉了」
# ＋「旋风刀这套实现很可以，另外俩都按这个标准做」）：W11/W12 开火即化身扑向攻击位再
# 回环——环绕化身=攻击体（W10 回旋刃出击读感标杆）；纯表现（判定/数值零参与）
const SORTIE_OUT_S := 0.16                    # 出击段时长 s（quad-in 快扑）
const SORTIE_BACK_S := 0.30                   # 回环段时长 s（quad-out 滑回，环位实时重算）
const SORTIE_SCALE := 1.32                    # 出击期化身放大（扑出读感）

var _avatars: Array[Sprite2D] = []            # 槽位对齐化身（4 槽，惰性创建）
var _sorties: Array[Dictionary] = []          # 槽位对齐出击态 [{active, phase, t, from, to}]
var _ring_buf: Array[int] = []                # 二cv 评审收口：环分层号成员缓冲（逐帧零新建数组）
var _entries_buf: Array = []                  # R188①：展示序列成员缓冲（_entries_of 原地
                                              # clear+append 重建——三调用方即取即弃零持有）
var _slot_cache: Array[Dictionary] = []       # R188③④：槽位解析缓存 {w, t2, is_blade, icon,
                                              # src_id}——仅武器实例或质变位变化才重解析
                                              #（图标键/刃类前缀判/僚机染色的 String 中转全在
                                              # 缓存未命中路径，逐帧热路径零分配）
var _spin: float = 0.0                        # 公转相位
var _t: float = 0.0                           # 呼吸/颤动时钟


func _ready() -> void:
	z_index = 6                                  # 玩家之上、UI 之下


func _process(p_delta: float) -> void:
	var player := get_parent() as Node2D
	if player == null or not is_instance_valid(player):
		return
	_t += p_delta
	_spin = wrapf(_spin + SPIN * p_delta, 0.0, TAU)
	var slots: Array = player.get("weapon_slots")
	if slots == null:
		return
	# R183 展示序列 = 真实武器（槽序）+ 僚机复制武器（追加环尾，金色染色区分）
	var entries := _entries_of(player)
	var n := maxi(entries.size(), 1)
	var layers := _ring_layers(entries)          # 二cv#3：槽位对齐层号（法器按装备序外扩）
	_ensure_avatars(entries.size())
	for i in range(_avatars.size()):
		var w: Variant = entries[i] if i < entries.size() else null
		var avatar := _avatars[i]
		# R30 防御：无数据的槽位武器（测试桩/装配中途）跳过取贴图——data.id 空引用
		if w == null or not is_instance_valid(w) or (w as WeaponBase).data == null:
			avatar.visible = false
			continue
		avatar.visible = true
		# R25b 修复（用户反馈「手枪的悬浮武器怎么是个球」）：化身贴图 = 对应武器
		# 的程序化图标（此前占位圆珠忘了换——每一颗都是球）
		# R243 质变变体选键（§7.1 缓存键 <id>_t2）：.get 守卫——transcended 字段未交付
		# 波次恒 null → 基图（w4 交付后自动切 t2，消费侧零改动）。判 null 先于 bool()
		#（bool(null) 在 Godot 4.3 = Nonexistent 'bool' constructor 运行时错误）
		# R188③④：槽位解析缓存——data.id 本就是 StringName（weapon_data.gd:8），旧
		# `StringName(String(data.id))` 双转换 + 刃类/僚机判定每帧 String 中转全是逐帧
		# 常量税；键 = 武器实例 + 质变位（图标键与 is_blade/src_id 只随这两位变化），
		# 命中即直出，未命中（换武器/质变切换）才走工厂查表与 String 解析
		var wb := w as WeaponBase
		var t2_v: Variant = wb.get("transcended")
		var t2: bool = t2_v != null and bool(t2_v)
		var cache: Dictionary = _slot_cache[i]
		if cache.is_empty() or cache.get("w") != w or bool(cache.get("t2", not t2)) != t2:
			var wid: StringName = wb.data.id           # 零转换零 intern 查表（id 原生 StringName）
			cache = {
				"w": w, "t2": t2,
				"icon": TextureFactory.weapon_icon_t2(wid) if t2 \
					else TextureFactory.weapon_icon(wid),
				"is_blade": String(wid).begins_with("W9"),   # 仅 W9 贴弧扫动（_process 口径；
				                                             # W11/W12/W13 白名单是 avatar_global
				                                             # 朝向还原另一口径，不混用）
				"w13": String(wid).begins_with("W13"),       # R245 §3.4-1 化身随圈成长判定
				                                             #（仅缩放轴——见 _avatar_scale）
				"src_id": String(wid),                       # 僚机染色比对键（R187 分派表）
			}
			_slot_cache[i] = cache
		var icon: ImageTexture = cache["icon"]
		if avatar.texture != icon:
			avatar.texture = icon
		# 均匀分布：按在场武器数重排（动态绕主角排列——R25）
		var ang := _spin + TAU * float(i) / float(n)
		var bob := sin(_t * BOB_FREQ + float(i) * 1.7) * BOB_AMP
		# 二cv#3：半径 = RING_R + 层号×RING_STEP（第 1 把法器内环、第 2 把外一层…；
		# 非法器层号 0 恒内环）。层号与 entries 同长同序，i 必不越界（null 槽已 continue）
		var r := RING_R + float(layers[i]) * RING_STEP
		# W9 化身 = 真刀：挥斩窗口贴弧扫动（返回 true = 刀已贴弧定位，跳过默认环绕位）
		# R188③④：刃类判定走槽位缓存直出（原每帧 String(data.id).begins_with 分配）
		var is_blade: bool = cache["is_blade"]
		# 二cu 合一：出击态接管位/向/缩放（W11/W12 开火扑出——见 begin_sortie）；
		# 非出击走原路径（W9 挥斩贴弧 / 默认环位+开火指向）。归位常态 scale 统一复位
		#（出击放大/挥斩 1.25× 的收口径——旧版挥斩后不复位的遗留观感一并收口）
		var in_sortie := i < _sorties.size() and bool(_sorties[i].get("active", false))
		var blade_swept := false
		if in_sortie:
			_tick_sortie(i, avatar, p_delta, n, r)   # 二cv#3：出击回环落点回它自己的层
		else:
			avatar.scale = Vector2.ONE * _avatar_scale(wb, cache)
			if is_blade and _tick_blade(w, avatar, r + 26.0):
				blade_swept = true               # 刀已贴弧（挥砍中）
		if not in_sortie and not blade_swept:
			avatar.position = Vector2.from_angle(ang) * (r + bob)
			# R30（用户反馈「转圈子弹从屁股出来，枪口要始终向发射的方向」）：化身朝向跟随
			# 真实开火指向——aim_direction 与实弹出膛方向同源（无目标=UP 回退一致）。
			# 图标画布口径：枪械类朝右（+X）直接取角；W9 刀画布朝上（-Y）+90° 补偿
			#（与挥斩姿态同式，悬浮待机 = 指向最近敌人的持刀姿态）
			var aim: Vector2 = (w as WeaponBase).aim_direction()
			avatar.rotation = aim.angle() + (PI * 0.5 if is_blade else 0.0)
		# R87 元素共鸣染色（用户反馈「激光获取燃烧没变红」）：化身随附魔元素着色——
		# R243 混色改版（§6.5）：非 KIN 元素色 RGB 均值（多元素 = 混色，单元素 = 该色
		# 与 dominant 同值、空池 = 白）——blend_element_color() 直赋，lerp 平滑过渡保留。
		# R183 僚机副本：金色染色（与护航舰同源——「僚机在场」一眼可辨，元素色让位）
		# R187 折减裁定表染色（按源武器 id 分派——副本身份由 _summon_copies 数组权威判定）：
		# W1 金 / W4 灰 / W6 钢蓝 / W7 橙红；镜面 = 银白/冰青（禁金——读感分界裁定）
		var is_copy := _is_summon_copy(player, w)
		var is_mirror := _is_mirror_image(player, w)
		var tint := Color.WHITE
		if is_mirror:
			tint = PopPalette.PLAYER.lerp(Color.WHITE, 0.62)
		elif is_copy:
			var src_id: String = cache["src_id"]       # R188③④：染色分派键走槽位缓存
			if src_id == "W4_pulse_beam":
				tint = Color(0.62, 0.64, 0.68)                 # 灰染
			elif src_id == "W6_micro_missile":
				tint = Color(0.55, 0.68, 0.86)                 # 钢蓝
			elif src_id == "W7_cluster_rocket":
				tint = Color(1.0, 0.55, 0.35)                  # 橙红
			else:
				tint = PopPalette.GOLD                         # R183 既有金染兜底（W1 等）
		else:
			tint = (w as WeaponBase).blend_element_color()
		avatar.modulate = avatar.modulate.lerp(tint, minf(p_delta * 10.0, 1.0))


func _is_summon_copy(p_player: Node2D, p_weapon: Variant) -> bool:
	# R183 副本判定：是否在玩家 _summon_copies 数组（僚机复制武器）
	var copies: Variant = p_player.get("_summon_copies")
	if copies is Array:
		return (copies as Array).has(p_weapon)
	return false


func _is_mirror_image(p_player: Node2D, p_weapon: Variant) -> bool:
	# R187 W5 镜面判定：是否在玩家 _mirror_images 数组（万镜回廊——银白/冰青染色）
	var mirrors: Variant = p_player.get("_mirror_images")
	if mirrors is Array:
		return (mirrors as Array).has(p_weapon)
	return false


func _entries_of(p_player: Node2D) -> Array:
	# 展示序列（发射口查询用）：真实武器（槽序）+ 僚机复制武器（环尾追加）
	# R188①：改成员缓冲原地 clear+append 重建（原每调新建 Array——_process 每帧常量税）。
	# 三调用方（_process :51 / avatar_global / begin_sortie）即取即弃无跨查询持有（已核）；
	# rcu 夹具直呼本口读内容，缓冲重建内容逐位不变 → 内容断言照绿
	var entries := _entries_buf
	entries.clear()
	var slots: Variant = p_player.get("weapon_slots")
	if slots is Array:
		for w in slots:
			if w != null and is_instance_valid(w):
				entries.append(w)
	var copies: Variant = p_player.get("_summon_copies")
	if copies is Array:
		for w in copies:
			if w != null and is_instance_valid(w):
				entries.append(w)
	var mirrors: Variant = p_player.get("_mirror_images")
	if mirrors is Array:
		for w in mirrors:
			if w != null and is_instance_valid(w):
				entries.append(w)          # R187 镜面化身（环尾追加——银白/冰青染色区分）
	return entries


func _ring_layers(p_entries: Array) -> Array[int]:
	# 二cv#3 法器环绕分层：槽位对齐层号表（与 p_entries 同长同序）。法器按装备序
	# 记 0,1,2…（第 1 把在 RING_R 内环，第 2 把外推 RING_STEP，依此类推）；非法器
	# 恒 0（内环）——弹道武器贴身、法器逐层外扩，一圈挤不下就每种一层。
	# 僚机副本/镜面追加武器跟 entries 序走（同式计数不豁免——与宿主分层读感一致）。
	# data 缺失（测试桩/装配中途）按非法器兜底层 0，零崩溃面。
	# 二cv 评审收口：逐帧重建 Array 是常量税（R188/R225 先例）——写入成员缓冲
	# _ring_buf 原地 resize+赋值（_process 每帧调用点零新建；rcu 夹具直呼本口读回不变）。
	_ring_buf.resize(p_entries.size())
	var orb_seq := 0
	for i in range(p_entries.size()):
		var w: Variant = p_entries[i]
		var wid: Variant = null                     # R188④：id 原生 StringName（weapon_data.gd:8）——
		if w != null and is_instance_valid(w):      # 删 String 中转，直用跨型哈希查集合
			var d: Variant = (w as WeaponBase).data #（探针已证 StringName in Array[String]
			if d != null:                           # 命中：hit=true miss=false）
				wid = d.id
		if wid != null and wid in RITUAL_IDS:
			_ring_buf[i] = orb_seq
			orb_seq += 1
		else:
			_ring_buf[i] = 0
	return _ring_buf


func avatar_global(p_weapon: WeaponBase) -> Variant:
	# 发射口查询（R25）：返回该武器化身**枪口**的全局位置；化身不可见/未建 → null
	#（调用方回退）。R30：化身随射击指向旋转后，出膛点前伸到枪管尖端（化身位 + 朝向
	# ×MUZZLE_REACH）——子弹从枪口出膛而非枪身中段；W9 刀画布朝上，朝向 −90° 还原。
	# R183：僚机复制武器不在 weapon_slots——查询序列扩至「真实 + 副本」。
	# R191#2（用户反馈「枪口不在镜子也不在复制出的加特林身上」）：镜面开火经 inner
	# 查询，而 inner 是外层 MirrorImage 包装体的 child（入册的是包装体本体，见
	# mirror_image.gd setup_mirror/add_child）——首查恒落空 → 调用方回退
	# inner.global_position（静态菱形标记位），可见化身却在公转环上，两环两角永不
	# 合拢。修复：首查落空时沿 p_weapon.get_parent()（外层包装体）别名再查一次
	# entries，命中即返回包装体化身枪口；副本/真件首次 find 即命中，本分支零触达
	#（行为零变化）；两级落空维持 null（调用方回退本体位）。
	var player := get_parent()
	if player == null or not is_instance_valid(player):
		return null
	var entries := _entries_of(player as Node2D)
	var idx: int = entries.find(p_weapon)
	if idx < 0:
		var alias: Variant = p_weapon.get_parent()   # R191#2 镜面别名（外层包装体）
		if alias is WeaponBase:
			idx = entries.find(alias)
	if idx < 0 or idx >= _avatars.size():
		return null
	var a := _avatars[idx]
	if not a.visible:
		return null
	var facing := a.rotation - PI * 0.5 if _is_blade_weapon(entries[idx]) else a.rotation
	return a.global_position + Vector2.from_angle(facing) * MUZZLE_REACH


func _avatar_scale(p_wb: WeaponBase, p_cache: Dictionary) -> float:
	# R245 §3.4-1 常态化身缩放：非 W13 = AVATAR_SCALE（旧口径零位移）；W13 = AVATAR_
	# SCALE × (effective_slash_radius / W13_AVATAR_BASE_R)——化身随圈成长（L1 0.62
	# 与现状一致、L5 ≈0.907；巨刃/广域乘区同步长大，effective 已含）。effective 逐帧
	# live 读（升级/挂卡即时反映——槽位缓存键不含等级，勿入缓存防陈旧读数）；weapon
	# 无 effective 口（非近战桩）回落常量。
	if bool(p_cache.get("w13", false)) and p_wb.has_method(&"effective_slash_radius"):
		return AVATAR_SCALE * maxf(float(p_wb.call(&"effective_slash_radius")), 1.0) \
			/ W13_AVATAR_BASE_R
	return AVATAR_SCALE


func _is_blade_weapon(p_w: Variant) -> bool:
	# 槽位武器是否刃类（画布朝上口径——朝向还原用）。R243 白名单扩（§2.2/终审⑤）：
	# W9 前缀 + W11/W12/W13（三新武器画布统一朝上 -Y，复用 +90° 朝向补偿——W11 剑指
	# 飞行方向、W13 剑指斩击方向；W12 无 arc_slash 字段 → _tick_blade 返 false 走
	# 默认环绕位但补偿生效，斧刃指向公转切向）
	if p_w == null or not is_instance_valid(p_w):
		return false
	var d: Variant = (p_w as WeaponBase).data
	if d == null:
		return false
	var wid := String(d.id)
	return wid.begins_with("W9") or wid == "W11_spirit_sword" \
		or wid == "W12_ground_axe" or wid == "W13_great_sword"


func _ensure_avatars(p_slots: int) -> void:
	while _avatars.size() < p_slots:
		var sp := Sprite2D.new()
		sp.name = "WeaponAvatar%d" % _avatars.size()
		sp.texture = TextureFactory.bead(PopPalette.PLAYER, 32)
		sp.scale = Vector2.ONE * AVATAR_SCALE
		add_child(sp)
		_avatars.append(sp)
		_slot_cache.append({})                     # R188③④：解析缓存随槽扩容（惰性填充）
		_sorties.append({"active": false, "phase": 0, "t": 0.0,
			"from": Vector2.ZERO, "to": Vector2.ZERO})


func _tick_blade(p_w: WeaponBase, p_avatar: Sprite2D, p_ring_r: float) -> bool:
	# W9 刀联动：挥斩窗口内贴挥砍弧扫动（前缘位置对齐窗口进度）；无窗口原位悬浮
	var slash: Variant = p_w.get("arc_slash")
	var data: Variant = p_w.data
	var radius: float = 150.0
	var arc := 120.0
	if data != null:
		radius = float(p_w.call("_leveled_param", "slash_radius",
			float(data.melee.get("slash_radius", 150.0))))
		arc = float(p_w.call("_leveled_param", "arc_deg", float(data.melee.get("arc_deg", 120.0))))
		# 二cv#4：质变弧加成并入化身扫弧（W9 碧涛旋舞 160+40=200°）——此前只读逐级表，
		# Lv5 质变后化身扫弧仍停在基础弧（贴图态不随质变切换的陈旧读数——_tc_mult 为
		# WeaponBase 基类口，未质变恒返缺省 0 零位移）
		arc += float(p_w._tc_mult("arc_bonus_deg", 0.0))
	if slash == null or not is_instance_valid(slash):
		return false
	var window_left: float = float(slash.get("window_left"))
	var facing: float = float(slash.get("facing"))
	if window_left <= 0.0:
		return false                            # 无窗口：默认悬浮
	# 窗口内：刀贴到挥砍弧前缘（进度 0→1 从 -arc/2 扫到 +arc/2）。
	# 二cv#3：贴弧基准不内跳——maxf(弧位, 本槽环位) 取大者：W9 Lv1 弧位 = slash_radius
	# 150+10 = 160，仅盖层 0~2（环位 84/114/144）；层 3/4（174/204）时取环位——外层
	# 法器挥斩从自己的层位外贴、不出现环位→弧位的半径倒吸（分层修复的预期方向，非
	# 回归）；Lv5 质变弧位 240 恒盖全层，唯此档「弧位恒大」口径成立。
	var progress: float = clampf(1.0 - window_left / OrbitWeapon.SLASH_WINDOW, 0.0, 1.0)
	var half := deg_to_rad(arc) * 0.5
	var sweep := facing - half + 2.0 * half * progress
	p_avatar.position = Vector2.from_angle(sweep) * maxf(radius + 10.0, p_ring_r)
	p_avatar.rotation = sweep + PI * 0.5         # 刃指向扫动方向
	p_avatar.scale = Vector2.ONE * (AVATAR_SCALE * 1.25)   # 挥斩时略放大
	return true


# ── 二cu 法器合一出击态（W11 灵剑 / W12 掷斧——W10 回旋刃出击读感标杆） ──
func begin_sortie(p_weapon: WeaponBase, p_target: Vector2) -> void:
	# 出击入口（player.weapon_avatar_sortie 委托；W11/W12 开火即调）：化身扑向攻击位。
	# 目标位世界→本层局部（本层随玩家平移，局部位 = 相对玩家位）；武器无化身（槽位外/
	# 不可见/测试桩环境）静默返回——表现层零兜底崩溃面。出击中再触发 = 重定向新目标
	#（连续开火 = 化身连续扑刺，from 取当前位无缝续飞）。
	var player := get_parent() as Node2D
	if player == null or not is_instance_valid(player):
		return
	var entries := _entries_of(player)
	var idx: int = entries.find(p_weapon)
	if idx < 0:
		var alias: Variant = p_weapon.get_parent()   # 镜面包装体别名（avatar_global 同式）
		if alias is WeaponBase:
			idx = entries.find(alias)
	if idx < 0 or idx >= _avatars.size() or not _avatars[idx].visible:
		return
	_sorties[idx] = {"active": true, "phase": 0, "t": 0.0,
		"from": _avatars[idx].position, "to": to_local(p_target)}


func _tick_sortie(p_i: int, p_avatar: Sprite2D, p_delta: float, p_n: int, p_home_r: float) -> void:
	# 出击态推进（_process 每帧，出击槽位独占）：出段 quad-in 快扑（0.16s）→ 回段
	# quad-out 滑回（0.30s；home = 实时环位——公转/玩家位移中归位不脱环）。二cv#3：
	# p_home_r = 本槽分层半径（RING_R + 层号×RING_STEP）——外层法器出击回环落回自己的
	# 层，不横穿内环。朝向 = 运动方向 +90°（刃画布 -Y 补偿，_is_blade_weapon 口径同式）；
	# 完成恢复常态 scale。
	var s: Dictionary = _sorties[p_i]
	s["t"] = float(s["t"]) + p_delta
	if int(s["phase"]) == 0:
		var k := clampf(float(s["t"]) / SORTIE_OUT_S, 0.0, 1.0)
		var from: Vector2 = s["from"]
		var to: Vector2 = s["to"]
		p_avatar.position = from.lerp(to, k * k)          # quad ease-in（蓄力快扑）
		var dir := to - from
		if dir.length_squared() > 1.0:
			p_avatar.rotation = dir.angle() + PI * 0.5    # 刃迎扑出方向
		if k >= 1.0:
			s["phase"] = 1
			s["t"] = 0.0
	else:
		var k := clampf(float(s["t"]) / SORTIE_BACK_S, 0.0, 1.0)
		var e := 1.0 - (1.0 - k) * (1.0 - k)              # quad ease-out（滑回）
		var home := Vector2.from_angle(_spin + TAU * float(p_i) / float(maxi(p_n, 1))) \
			* (p_home_r + sin(_t * BOB_FREQ + float(p_i) * 1.7) * BOB_AMP)
		var to: Vector2 = s["to"]
		p_avatar.position = to.lerp(home, e)
		var dir := home - p_avatar.position
		if dir.length_squared() > 1.0:
			p_avatar.rotation = dir.angle() + PI * 0.5
		if k >= 1.0:
			s["active"] = false
			p_avatar.scale = Vector2.ONE * AVATAR_SCALE   # 归位常态
			return
	p_avatar.scale = Vector2.ONE * (AVATAR_SCALE * SORTIE_SCALE)  # 出击期放大

# scripts/entities/player/weapon_orbit_avatars.gd
# R25 武器悬浮层（用户点名「所有武器都是悬浮在主角身边的形式，多武器动态绕主角排列」）：
# · 每把已装备武器一个化身（复用 weapon_icon 程序化贴图——零新美术），
#   N 把武器按槽位均匀分布在主角环绕环上，公转慢旋 + 悬浮呼吸。
# · W9 化身 = 真刀：无敌人时原位悬浮呼吸；挥斩窗口刀随窗口扫动（贴着挥砍弧旋转）。
# · 换武器即时重排（槽位扫描脏检查——化身贴图按武器 id 惰性换）。
# · 编排：玩家子节点（原点跟随），_process 自驱；纯表现层（零判定/数值副作用）。
class_name WeaponOrbitAvatars
extends Node2D

const RING_R := 58.0                          # 环绕半径 px
const SPIN := 0.7                             # 公转角速度 rad/s
const BOB_AMP := 4.0                          # 悬浮呼吸幅度 px
const BOB_FREQ := 2.2                         # 呼吸频率 rad/s
const AVATAR_SCALE := 0.62                    # 化身缩放（56px 画布 → ~35px）

var _avatars: Array[Sprite2D] = []            # 槽位对齐化身（4 槽，惰性创建）
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
	var live: Array = []
	for w in slots:
		if w != null and is_instance_valid(w):
			live.append(w)
	var n := maxi(live.size(), 1)
	_ensure_avatars(slots.size())
	for i in range(_avatars.size()):
		var w: Variant = slots[i] if i < slots.size() else null
		var avatar := _avatars[i]
		var active: bool = w != null and is_instance_valid(w)
		avatar.visible = active
		if not active:
			continue
		# R25b 修复（用户反馈「手枪的悬浮武器怎么是个球」）：化身贴图 = 对应武器
		# 的程序化图标（此前占位圆珠忘了换——每一颗都是球）
		var wid: StringName = StringName(String((w as WeaponBase).data.id))
		var icon: ImageTexture = TextureFactory.weapon_icon(wid)
		if avatar.texture != icon:
			avatar.texture = icon
		# 均匀分布：按在场武器数重排（动态绕主角排列——R25）
		var slot_in_live := live.find(w)
		var ang := _spin + TAU * float(slot_in_live) / float(n)
		var bob := sin(_t * BOB_FREQ + float(i) * 1.7) * BOB_AMP
		var r := RING_R
		# W9 化身 = 真刀：挥斩窗口贴弧扫动（无窗口原位悬浮呼吸）
		var w9_data: Variant = (w as WeaponBase).data
		var is_blade: bool = w9_data != null and String(w9_data.id).begins_with("W9")
		if is_blade:
			_tick_blade(w, avatar, r)
			r = RING_R + 26.0                    # 刀悬浮更靠外一点
		avatar.position = Vector2.from_angle(ang) * (r + bob)
		avatar.rotation = ang                    # 朝向外侧（武器朝外的姿态读感）


func avatar_global(p_weapon: WeaponBase) -> Variant:
	# 发射口查询（R25）：返回该武器化身的全局位置；化身不可见/未建 → null（调用方回退）
	var player := get_parent()
	if player == null or not is_instance_valid(player):
		return null
	var slots: Variant = player.get("weapon_slots")
	if slots == null:
		return null
	var idx: int = (slots as Array).find(p_weapon)
	if idx < 0 or idx >= _avatars.size():
		return null
	var a := _avatars[idx]
	if not a.visible:
		return null
	return a.global_position


func _ensure_avatars(p_slots: int) -> void:
	while _avatars.size() < p_slots:
		var sp := Sprite2D.new()
		sp.name = "WeaponAvatar%d" % _avatars.size()
		sp.texture = TextureFactory.bead(PopPalette.PLAYER, 32)
		sp.scale = Vector2.ONE * AVATAR_SCALE
		add_child(sp)
		_avatars.append(sp)


func _tick_blade(p_w: WeaponBase, p_avatar: Sprite2D, p_ring_r: float) -> void:
	# W9 刀联动：挥斩窗口内贴挥砍弧扫动（前缘位置对齐窗口进度）；无窗口原位悬浮
	var slash: Variant = p_w.get("arc_slash")
	var data: Variant = p_w.data
	var radius: float = 150.0
	var arc := 120.0
	if data != null:
		radius = float(p_w.call("_leveled_param", "slash_radius",
			float(data.melee.get("slash_radius", 150.0))))
		arc = float(p_w.call("_leveled_param", "arc_deg", float(data.melee.get("arc_deg", 120.0))))
	if slash == null or not is_instance_valid(slash):
		return
	var window_left: float = float(slash.get("window_left"))
	var facing: float = float(slash.get("facing"))
	if window_left <= 0.0:
		return                                  # 无窗口：调用方保持原位悬浮
	# 窗口内：刀贴到挥砍弧前缘（进度 0→1 从 -arc/2 扫到 +arc/2）
	var progress: float = clampf(1.0 - window_left / OrbitWeapon.SLASH_WINDOW, 0.0, 1.0)
	var half := deg_to_rad(arc) * 0.5
	var sweep := facing - half + 2.0 * half * progress
	p_avatar.position = Vector2.from_angle(sweep) * (radius + 10.0)
	p_avatar.rotation = sweep + PI * 0.5         # 刃指向扫动方向
	p_avatar.scale = Vector2.ONE * (AVATAR_SCALE * 1.25)   # 挥斩时略放大

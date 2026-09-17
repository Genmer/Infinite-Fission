# scripts/combat/weapon/melee/orbit_weapon.gd
# M-08 OrbitWeapon（架构 §2.8.5，形态 D）：环绕力场 W8 / 周期挥斩 W9 同构。
# · 环绕模式（nullify=false，W8）：浮游球绕本体公转（angular_speed °/s）；每球对同一
#   目标判定冷却 hit_cd（OrbitField 周期范围判定 + 击退，可打断自爆引导）。
# · 挥斩模式（nullify=true，W9）：cd 制周期挥斩——固定角度扇形判定窗口 0.15s（窗口外
#   无判定）+ 击退 + 消弹（弧内敌方弹幕 → OnExpire(NULLIFIED) 弹池回收，AC-06.2）。
# · orbs_bonus：MEC_ORBIT_LINK（谐振轨道）环绕体加成通道（仅本形态生效）。
class_name OrbitWeapon
extends WeaponBase

const SLASH_WINDOW := 0.15                    # 挥斩判定窗口（架构 §2.8.5）

var orbit_field: OrbitField = null            # 环绕力场实体（单武器常驻单例）
var arc_slash: ArcSlash = null                # 周期挥斩实体（窗口期激活）
var orbs_bonus: int = 0                       # 谐振轨道词条加成（MEC_ORBIT_LINK）


var _enemy_bullet_grid: SpaceGrid = null      # 敌弹网格（消弹查询——R7 接线，此前从未注入）


func setup(p_data: WeaponData, p_player: Node2D, p_deps: Dictionary) -> void:
	super(p_data, p_player, p_deps)
	_enemy_bullet_grid = p_deps.get("enemy_bullet_grid")
	orbs_bonus = 0
	orbit_field = null
	arc_slash = null


func try_fire() -> bool:
	# 近战形态"开火"= 周期性判定调度（hit_cd / cd）
	if data == null:
		return false
	if _is_slash_mode():
		_slash_window()
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
	# 词条挂载（R19 环绕形态卡：orbit_style 形态卡挂上即重铺外观+乘区）
	var ok := super.attach_trait(p_trait)
	if ok and p_trait != null and p_trait.params.has("orbit_style"):
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
	# 常驻实体推进（力场公转/挥斩窗口判定；宿主位置驱动）
	if orbit_field != null and is_instance_valid(orbit_field):
		orbit_field.tick(p_game_delta, muzzle_position())
	if arc_slash != null and is_instance_valid(arc_slash):
		arc_slash.tick(p_game_delta, muzzle_position())


func _slash_window() -> void:
	# 挥斩窗口开启（持续 0.15s，窗口外无判定；朝向最近敌）
	if arc_slash == null:
		_ensure_arc_slash()
		if arc_slash == null:
			return
	var facing := aim_direction().angle()
	arc_slash.open_window(facing)


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
	return {
		"orbs": _leveled_param("orbs", float(data.melee.get("orbs", 2))) + orbs_bonus,
		"orbit_radius": orbit_radius,
		"angular_speed": angular,
		"orb_radius": orb_r,
		"hit_cd": hit_cd,
		"knockback": knockback,
		"style": String(style) if style != &"" else "orb",
	}


func refresh_orbit_field() -> void:
	# 已常驻力场按当前参数重铺（诺亚僚机召唤/还原通道：orbs_bonus 变更即时生效）；
	# 挥斩形态 / 力场未建（首开火前）→ 无需重铺（orbs_bonus 由 _ensure_orbit_field 自然生效）
	if _is_slash_mode() or orbit_field == null or not is_instance_valid(orbit_field):
		return
	orbit_field.spawn(_orbit_params())


func _ensure_arc_slash() -> void:
	# 挥斩实体创建（同上：单武器常驻单例）
	arc_slash = ArcSlash.new()
	arc_slash.name = "ArcSlash"
	add_child(arc_slash)
	arc_slash.weapon = self
	arc_slash.enemy_grid = enemy_grid
	arc_slash.enemy_bullet_grid = _enemy_bullet_grid   # R7 接线：消弹查询（此前恒 null = W9 消弹死功能）
	arc_slash.spawn({
		"slash_radius": float(data.melee.get("slash_radius", 150.0)),
		"arc_deg": _leveled_param("arc_deg", float(data.melee.get("arc_deg", 120.0))),
		"max_targets": int(data.melee.get("max_targets", 8)),
		"knockback": float(data.melee.get("knockback", 180.0)),
		"nullify": bool(data.melee.get("nullify", false)),
	})


func set_enemy_bullet_grid(p_grid: SpaceGrid) -> void:
	# 敌弹网格注入（GameLoop 帧序③ enemy_bullet_grid——包 4 集成期接线；消弹查询）
	if arc_slash != null:
		arc_slash.enemy_bullet_grid = p_grid


func _is_slash_mode() -> bool:
	# W9 挥斩形态判定（nullify=true：固定角度弧形判定 + 消弹）
	return bool(data.melee.get("nullify", false))


func _leveled_param(p_key: String, p_default: float) -> float:
	# 逐级形态参数（形态段新增键 <key>_levels: Array[float]——A3 §3.8/§3.9 逐级递进）
	var levels: Variant = data.melee.get(String(p_key) + "_levels", null)
	if levels is Array and level >= 1 and level <= (levels as Array).size():
		return float((levels as Array)[level - 1])
	return p_default

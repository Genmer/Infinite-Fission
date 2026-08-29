# scripts/entities/player/player.gd
# M-02 Player（架构 §2.12）：Area2D 命中盒（低频，Q-15 例外通道）+ 磁吸拾取区（120px）。
# 操作：相对拖动（Q-3）——_unhandled_input 采样拖动向量，tick 应用 + 活动区钳制（下 40% 屏，E-15）。
# 受击：简化路径（Q-16）——无敌帧 contact_tick=0.6s 判定 → 直接扣 HP → 事件，不入 M-12。
# 编排说明（§2.17）：tick(game_delta, move_delta) 由 GameLoop ② 驱动；
# move_delta 非零 = GameLoop 显式投递（E-15 输入采样）；零向量 = 玩家消费自身 _unhandled_input 采样。
class_name Player
extends Area2D

# 初始 HP 真源 = cfg player_base_hp=60（用户实测反馈 2026-08-29 裁定回注，原 100 被围
# 数分钟不死无张力；贴脸 4.5s 死、E1 一次磨血 16.7%、E4 爆炸 33%、Boss 接触 33~58%
# ——「杂兵磨血、精英/Boss 杀人」梯度成立，且 REL_HARVEST 0.4% 回血不致被满血钳死）。
var max_hp: float = 60.0                       # 声明值与 cfg 同口径（_ready 覆读 cfg 真源）
var hp: float = 60.0
var move_speed: float = 280.0                 # 移速（相对拖动 1:1 口径下的调试/键盘备用参数）
var pickup_radius: float = 120.0              # Q-13 磁吸半径（pickup_pct 词条加成属包 3 常驻词条）
# 角色系统（用户反馈「不同的角色有不同的技能」）：选择经 Meta 持久化，开局 set_character 应用
var character_id: StringName = &"sentinel"
var character_atk_pct: float = 0.0            # 角色攻击修正（武器面板经 meta_atk_pct 合成）
var rof_mult: float = 1.0                     # 过载咆哮射速倍率（WeaponBase._fire_interval 消费）
var skill_cd_base: float = 30.0
var skill_cd_left: float = 0.0
var skill_active_left: float = 0.0            # 增益型技能剩余时长（过载）
var _skill_shield_left: float = 0.0           # 紧急护盾剩余（表现走护盾泡）
var invuln_left: float = 0.0                  # 受击无敌帧（contact_tick=0.6s 口径）
var weapon_slots: Array[WeaponBase] = []      # ≤5（集成包 B.8 第二批收紧：pkg2 用例已迁移 WeaponBase 真件）
var unlocked_slots: int = 1                   # w3→2 / w7→3 / Boss1→4 / Boss2 或 w21→5（F-19）
var level: int = 1
var xp: float = 0.0
var xp_need: float = 14.0                     # 14 × lv^1.4
var hitbox_radius: float = 16.0               # 命中盒半径（敌弹距离判定口径）

var _dead: bool = false
var _drag_accum: Vector2 = Vector2.ZERO       # 相对拖动采样累计（E-15）
var input_enabled: bool = true                 # 输入使能（暂停恢复 0.5s 防误触宽限期——GameLoop 驱动）
# 格挡力场（MEC_SHIELD 玩家侧接线，A3 §4.4：每 interval_s 生成护盾格挡 1 次接触伤害，
# 2 层 → 5.5s；shield_interval<=0 = 未持有。charge 就绪 → 力场环可见；格挡瞬间脉冲扩散）
var shield_interval: float = 0.0
var shield_timer: float = 0.0                  # 充能剩余（就绪后停走；HUD 护盾条数据源）
var shield_ready: bool = false
var _shield_pulse_left: float = 0.0            # 格挡扩散脉冲剩余（表现层）
var _pickup_area: Area2D = null
var _pickup_shape: CollisionShape2D = null
var _hit_shape: CollisionShape2D = null
var _sprite: Sprite2D = null
var _flame_l: Sprite2D = null                  # 左引擎喷焰（移动时点亮 + 抖动）
var _flame_r: Sprite2D = null                  # 右引擎喷焰（与左反相抖动）
var _flash: Sprite2D = null                    # 受击白闪剪影（叠在机体上方）
var _shield_ring: Sprite2D = null              # 格挡力场环（就绪可见 + 格挡脉冲——A3 §4.4 MEC_SHIELD）
var _flash_left: float = 0.0
var _punch_left: float = 0.0                   # 受击 squash punch 剩余
var _tilt: float = 0.0                         # 移动倾斜（横移 bank）
var _anim_t: float = 0.0                       # 帧内动画时钟（喷焰抖动/无敌闪烁/hover）
var _visual_scale: float = 1.0                 # 机体基础缩放（hitbox 口径换算）
var _deps: Dictionary = {}                     # setup 注入位（pipeline/pools/grid/registry——包 3/4 接线）

const MAX_SLOTS := 5
const RESPAWN_INVULN_S := 1.5                 # 重开无敌帧 s（B_spec 无数值 → 主控裁定，见 respawn 注释）
const SHIP_TEX_R := 38.0                       # 机体贴图本体半径 px（TextureFactory.ship 96 画布）
const VISUAL_MULT := 1.35                      # 视觉半径 / 命中盒（弹幕游戏惯例：盒小于形）
const FLASH_TIME := 0.18                       # 受击白闪时长
const PUNCH_TIME := 0.24                       # 受击 squash punch 时长
const HOVER_AMP := 2.6                         # hover 待机浮动幅度 px（用户反馈：主角机体活起来）
const HOVER_PERIOD := 2.6                      # hover 周期 rad/s 基频
const POD_L := Vector2(-20.0, 34.0)            # 左引擎舱喷口（贴图坐标——随 _visual_scale 缩放）
const POD_R := Vector2(20.0, 34.0)             # 右引擎舱喷口
const SHIELD_PULSE_TIME := 0.32                # 格挡脉冲扩散时长 s（表现层）
const SHIELD_RING_R := 46.0                    # 力场环贴图基准半径 px（TextureFactory.shield_bubble）


func _ready() -> void:
	# 组注册（敌/敌弹经组查找缓存玩家引用）+ 命中盒/拾取区/贴纸渲染组装（代码组装为主）
	add_to_group(&"player")
	_hit_shape = CollisionShape2D.new()
	_hit_shape.name = "HitShape"
	var hit_circle := CircleShape2D.new()
	hit_circle.radius = hitbox_radius
	_hit_shape.shape = hit_circle
	add_child(_hit_shape)
	_pickup_area = Area2D.new()
	_pickup_area.name = "PickupArea"
	_pickup_shape = CollisionShape2D.new()
	_pickup_shape.name = "PickupShape"
	var pickup_circle := CircleShape2D.new()
	pickup_circle.radius = pickup_radius
	_pickup_shape.shape = pickup_circle
	_pickup_area.add_child(_pickup_shape)
	add_child(_pickup_area)
	# 方向 C「哨兵-9」拦截机（用户试玩反馈 2026-08-29 重设计）：三角翼小机甲战机
	#（贴纸厚描边 + 座舱机器人驾驶员）+ 双引擎青蓝喷焰 + hover 待机浮动
	_visual_scale = hitbox_radius * VISUAL_MULT / SHIP_TEX_R
	_flame_l = Sprite2D.new()
	_flame_l.name = "FlameL"
	_flame_l.texture = TextureFactory.engine_flame()
	_flame_l.position = POD_L * _visual_scale
	_flame_l.visible = false
	add_child(_flame_l)
	_flame_r = Sprite2D.new()
	_flame_r.name = "FlameR"
	_flame_r.texture = TextureFactory.engine_flame()
	_flame_r.position = POD_R * _visual_scale
	_flame_r.visible = false
	add_child(_flame_r)
	_sprite = Sprite2D.new()
	_sprite.name = "Visual"
	_sprite.centered = true
	_sprite.texture = TextureFactory.ship()
	_sprite.scale = Vector2(_visual_scale, _visual_scale)
	add_child(_sprite)
	_flash = Sprite2D.new()
	_flash.name = "Flash"
	_flash.texture = TextureFactory.ship(true)
	_flash.scale = Vector2(_visual_scale, _visual_scale)
	_flash.visible = false
	add_child(_flash)
	# 格挡力场环（MEC_SHIELD 就绪时显示；叠在机体上方，半透青蓝泡泡——挡住才「现形」的力场感）
	_shield_ring = Sprite2D.new()
	_shield_ring.name = "ShieldRing"
	_shield_ring.texture = TextureFactory.shield_bubble()
	_shield_ring.scale = Vector2.ONE * (_visual_scale * SHIELD_RING_R / 24.0)
	_shield_ring.visible = false
	add_child(_shield_ring)
	weapon_slots.resize(MAX_SLOTS)
	EventBus.slot_unlocked.connect(_on_slot_unlocked_event)
	var bal := GameConfig.balance
	if bal != null:
		# 初始 HP 真源 = cfg player_base_hp（60；张力调校值已回注真源，消除双轨）
		max_hp = GameConfig.get_constant(&"player_base_hp", 60.0)
		hp = max_hp
		pickup_radius = bal.pickup_radius
		xp_need = _xp_need_for(level)


func setup(p_deps: Dictionary) -> void:
	# 注入 pipeline/pools/grid/registry（包 3/4 接线；当前仅存档，武器实例由 equip 装载）
	_deps = p_deps


func tick(p_game_delta: float, p_move_delta: Vector2) -> void:
	# 相对拖动移动 + 边界钳制 + 无敌帧推进 + 武器自动开火调度
	if _dead:
		return
	if invuln_left > 0.0:
		invuln_left -= p_game_delta
		if invuln_left < 0.0:
			invuln_left = 0.0
	# 角色技能节拍（冷却 + 增益型剩余）
	if skill_cd_left > 0.0:
		skill_cd_left = maxf(skill_cd_left - p_game_delta, 0.0)
	if skill_active_left > 0.0:
		skill_active_left = maxf(skill_active_left - p_game_delta, 0.0)
		if skill_active_left <= 0.0:
			rof_mult = 1.0
	# 格挡力场充能（MEC_SHIELD：非就绪期走表，充满置位；未持有词条时 interval=0 短路）
	if shield_interval > 0.0 and not shield_ready:
		shield_timer = maxf(shield_timer - p_game_delta, 0.0)
		if shield_timer <= 0.0:
			shield_ready = true
	var total := p_move_delta
	if total == Vector2.ZERO:
		total = _drag_accum if input_enabled else Vector2.ZERO   # 宽限期吞掉自采样拖动（防误触）
	_drag_accum = Vector2.ZERO
	global_position += total
	_clamp_to_playfield()
	# 武器自动开火调度（每帧 tick；集成包 B.8 第二批收紧：weapon_slots 已收窄 WeaponBase——直调）
	for weapon in weapon_slots:
		if weapon != null:
			weapon.tick(p_game_delta)
	_tick_visual(p_game_delta, total)


func _unhandled_input(p_event: InputEvent) -> void:
	# 输入抽象：相对拖动采样（Q-3；E-15 单指针锁定由 GameLoop 输入层承担，本层累计拖动向量）
	if p_event is InputEventScreenDrag:
		_drag_accum += (p_event as InputEventScreenDrag).relative
	elif p_event is InputEventMouseMotion:
		var mm := p_event as InputEventMouseMotion
		if (mm.button_mask & MOUSE_BUTTON_LEFT) != 0:
			_drag_accum += mm.relative


func take_contact_damage(p_dmg: float) -> void:
	# ★ 简化路径（Q-16）：无敌帧判定 → 格挡力场 → 直接扣 HP → player_hit 事件（不入 M-12）
	if _dead or invuln_left > 0.0:
		return
	# 格挡力场优先（A3 §4.4 MEC_SHIELD：就绪的护盾吞掉这次接触伤害并进入再充能）
	if shield_ready:
		shield_ready = false
		shield_timer = shield_interval
		_shield_pulse_left = SHIELD_PULSE_TIME
		invuln_left = GameConfig.balance.contact_tick if GameConfig.balance != null else 0.6
		EventBus.emit_shield_blocked(global_position)
		return
	var dmg := maxf(p_dmg, 0.0)
	hp -= dmg
	invuln_left = GameConfig.balance.contact_tick if GameConfig.balance != null else 0.6
	_flash_left = FLASH_TIME                     # 方向 C：受击变白弹回
	_punch_left = PUNCH_TIME
	EventBus.emit_player_hit(dmg, 0)
	if hp <= 0.0:
		hp = 0.0
		_on_died()


func apply_max_hp_up(p_amount: float) -> void:
	# AFF_HP_UP 消费点（A3 §4.2：max_hp +25/层，可叠 4 层）：上限增量与当前血等量回补
	#（主控裁定 2026-08-29——买血条即时爽感）；负值（诅咒对称口径）双向钳制不越界。
	max_hp += p_amount
	hp = minf(hp + p_amount, max_hp)


func apply_shield_trait(p_layers: int, p_params: Dictionary) -> void:
	# MEC_SHIELD 消费点（A3 §4.4）：每 interval_s 生成护盾格挡 1 次接触伤害；
	# 2 层 → interval_lv2(5.5s)。重复挂载/层变化即刷新间隔；首个护盾需走完一次充能。
	shield_interval = float(p_params.get(
		"interval_lv2", p_params.get("interval_s", 8.0))) if p_layers >= 2 \
		else float(p_params.get("interval_s", 8.0))
	if not shield_ready and shield_timer <= 0.0:
		shield_timer = shield_interval


func equip_weapon(p_weapon: WeaponBase) -> bool:
	# 装入武器实例（集成包 B.8 第二批收紧：签名收窄 WeaponBase——pkg2 用例已迁移真件武器）
	if p_weapon == null:
		return false
	for i in range(weapon_slots.size()):
		if weapon_slots[i] == null:
			if i >= unlocked_slots:
				return false                 # 槽未解锁
			weapon_slots[i] = p_weapon
			if p_weapon.get_parent() == null:
				add_child(p_weapon)
			return true
	return false                             # 无空槽


func add_weapon(p_data: WeaponData) -> WeaponBase:
	# 形态工厂（架构 §2.12）：槽位检查 → 实例化（按 form 分派）→ setup → 装槽挂载。
	# 无可用槽 / 未知形态 → 返回 null（不实例化，调用方按 null 降级）。
	if p_data == null:
		return null
	var slot := _first_available_slot()
	if slot < 0:
		return null                          # 无空槽（或槽未解锁）
	var weapon := _instantiate_weapon(p_data)
	if weapon == null:
		return null
	weapon.setup(p_data, self, _deps)        # 注入包：pipeline/pools/grid/laser_pool/elemental
	weapon.meta_atk_pct = Meta.atk_pct() + character_atk_pct   # 局外养成 + 角色修正（M8/角色系统）
	weapon_slots[slot] = weapon
	if weapon.get_parent() == null:
		add_child(weapon)
	return weapon


# ── 内部 ──────────────────────────────────────────────────────────
func _first_available_slot() -> int:
	# 首个已解锁空槽索引（无 → -1；与 equip_weapon 遍历口径一致）
	for i in range(weapon_slots.size()):
		if weapon_slots[i] == null:
			if i >= unlocked_slots:
				return -1                    # 槽未解锁（槽序即解锁序）
			return i
	return -1


func _instantiate_weapon(p_data: WeaponData) -> WeaponBase:
	# 形态分派（WeaponForm：BALLISTIC/LASER/HOMING/MELEE → 对应武器子类）
	match p_data.form:
		GameConst.WeaponForm.BALLISTIC:
			return BallisticWeapon.new()
		GameConst.WeaponForm.LASER:
			return LaserWeapon.new()
		GameConst.WeaponForm.HOMING:
			return HomingWeapon.new()
		GameConst.WeaponForm.MELEE:
			return OrbitWeapon.new()
	return null                              # 未知形态（WeaponData 校验已封 {0,1,2,3}）


func unlock_slot(p_slot: int) -> bool:
	# 槽位解锁（幂等；事件由 WaveDirector/集成侧派发）
	if p_slot > unlocked_slots and p_slot <= MAX_SLOTS:
		unlocked_slots = p_slot
		return true
	return false


func set_character(p_id: StringName) -> void:
	# 应用角色（大厅选人 → GameLoop.start_run/respawn 调用；含局外养成加成——M8）
	character_id = p_id
	var def := CharacterTable.get_character(p_id)
	max_hp = float(def.get("hp", 60.0)) + Meta.hp_bonus()
	hp = max_hp
	pickup_radius = 120.0 * (1.0 + Meta.magnet_pct())
	character_atk_pct = float(def.get("atk_pct", 0.0))
	skill_cd_base = float(def.get("cd", 30.0)) * (1.0 - Meta.skill_cdr_pct())
	skill_cd_left = 0.0
	rof_mult = 1.0
	# 攻击修正动态注入（真修：武器面板若只在实例化期定格，大厅买养成/选角后开局不生效）
	for w in weapon_slots:
		if w is WeaponBase and is_instance_valid(w):
			(w as WeaponBase).meta_atk_pct = Meta.atk_pct() + character_atk_pct
			(w as WeaponBase).call(&"_invalidate_panel")


func skill_ready() -> bool:
	return skill_cd_left <= 0.0 and not _dead


func activate_skill() -> bool:
	# 角色主动技能（HUD 技能键调用；冷却中 false）
	if not skill_ready():
		return false
	skill_cd_left = skill_cd_base
	match character_id:
		&"sentinel":
			invuln_left = maxf(invuln_left, 3.0)
			_skill_shield_left = 3.0
		&"veles":
			rof_mult = 2.0
			skill_active_left = 4.0
		&"bulwark":
			_skill_stomp()
	DebugStats.count(&"skill_used")
	return true


func _skill_stomp() -> void:
	# 震荡践踏：220px 内敌人击退 + 260px 内敌方弹清除（复用 NULLIFIED 统一收束）
	var grid: Variant = _deps.get("enemy_grid")
	if grid != null:
		for e in (grid as SpaceGrid).query_circle(global_position, 220.0):
			if e == null or bool(e.get("dead")):
				continue
			if e.has_method(&"knockback"):
				e.call(&"knockback", ((e as Node2D).global_position - global_position).normalized() * 280.0)
	var bgrid: Variant = _deps.get("enemy_bullet_grid")
	if bgrid != null:
		var cleared := 0
		for b in (bgrid as SpaceGrid).query_circle(global_position, 260.0):
			if b is ProjectileBase and (b as ProjectileBase).team == 1:
				EventBus.emit_bullet_nullified((b as Node2D).global_position)
				(b as ProjectileBase).nullify()
				cleared += 1
			if cleared >= 24:
				break


func gain_xp(p_amount: float) -> void:
	# 经验/等级：xp_gained → 升级（多级连升逐次广播，弹卡排队由 GameLoop 仲裁 E-16）
	# 升级回满血（用户反馈 2026-08-29「升级还是回满血吧」：升级即奖励，血条拉满解压）
	var amount := maxf(p_amount, 0.0)
	xp += amount
	EventBus.emit_xp_gained(amount)
	while xp >= xp_need:
		xp -= xp_need
		level += 1
		xp_need = _xp_need_for(level)
		hp = max_hp
		EventBus.emit_level_up(level)


func respawn() -> void:
	# 重开复活（GameLoop.restart_run → _reset_run_state 调用；集成包修复：死亡短路
	# _dead 属一次性 E-16 仲裁标志，必须随局重置——否则重开后 take_contact_damage 永久无效）
	# 重生无敌 1.5s（B_spec 无重生无敌数值 → 主控裁定；重开保护——防残留/新刷弹幕
	# 重生首帧秒杀，配合 GameLoop._reset_run_state 战场清场序，审查 Fix 1）
	_dead = false
	hp = max_hp
	level = 1
	xp = 0.0
	xp_need = _xp_need_for(1)
	unlocked_slots = 1
	invuln_left = RESPAWN_INVULN_S
	# 格挡力场复位（词条随武器重建重挂；interval 清零防上局残留——挂载时再置位）
	shield_interval = 0.0
	shield_timer = 0.0
	shield_ready = false
	_shield_pulse_left = 0.0
	_drag_accum = Vector2.ZERO
	skill_cd_left = 0.0
	skill_active_left = 0.0
	rof_mult = 1.0
	set_character(Meta.character_id)          # 重开按当前角色+养成重置（M8/角色系统）
	_flash_left = 0.0                            # 表现态复位（方向 C）
	_punch_left = 0.0
	_tilt = 0.0
	modulate.a = 1.0
	if _sprite != null:
		_sprite.scale = Vector2(_visual_scale, _visual_scale)
		_sprite.rotation = 0.0


func get_hp_pct() -> float:
	# 背水协议条件（SYN_LOWHP_FURY ctx）
	if max_hp <= 0.0:
		return 0.0
	return hp / max_hp


func _on_died() -> void:
	# 死亡事件（E-16 优先级最高——GameLoop 仲裁；只派发一次）
	if _dead:
		return
	_dead = true
	EventBus.emit_player_died()


func _on_slot_unlocked_event(p_slot: int) -> void:
	unlock_slot(p_slot)


func _clamp_to_playfield() -> void:
	# E-15：位置钳制活动区（下 40% 屏）
	var size := Vector2(720.0, 1280.0)
	if GameConfig.balance != null:
		size = Vector2(GameConfig.balance.res_logic)
	global_position.x = clampf(global_position.x, hitbox_radius, size.x - hitbox_radius)
	global_position.y = clampf(global_position.y, size.y * 0.6, size.y - hitbox_radius)


func _xp_need_for(p_level: int) -> float:
	# 14 × lv^1.4（balance.xp_curve 真源；lv → lv+1 升级所需）
	var base := 14.0
	var power := 1.4
	if GameConfig.balance != null:
		base = float(GameConfig.balance.xp_curve.get("base", 14.0))
		power = float(GameConfig.balance.xp_curve.get("power", 1.4))
	return base * pow(float(maxi(p_level, 1)), power)


# ── 方向 C 表现层（贴纸机体：倾斜 / 双引擎喷焰 / hover 浮动 / 受击白闪弹回 / 无敌闪烁） ──
func _tick_visual(p_game_delta: float, p_move: Vector2) -> void:
	# 纯表现（game_delta 通道——顿帧自然冻结）；不触碰数值与碰撞
	_anim_t += p_game_delta
	# hover 待机浮动（正弦 bob——机体「悬停感」，叠加在倾斜/挤压之上）
	var hover_y := sin(_anim_t * HOVER_PERIOD) * HOVER_AMP
	_sprite.position = Vector2(0.0, hover_y)
	# 移动倾斜（横移 bank）+ 移动拉伸
	var target_tilt := clampf(-p_move.x * 0.05, -0.38, 0.38)
	_tilt += (target_tilt - _tilt) * minf(p_game_delta * 16.0, 1.0)
	var moving := p_move.length_squared() > 0.01
	var squash := minf(p_move.length() * 0.012, 0.18)
	var punch := 1.0
	if _punch_left > 0.0:
		_punch_left = maxf(_punch_left - p_game_delta, 0.0)
		var bt := 1.0 - _punch_left / PUNCH_TIME
		punch = 1.0 + 0.34 * exp(-5.0 * bt) * sin(bt * 20.0)
	_sprite.rotation = _tilt
	_sprite.scale = Vector2(_visual_scale * (1.0 - squash) * punch,
		_visual_scale * (1.0 + squash) / punch)
	# 双引擎喷焰：移动时点亮 + 左右反相频闪抖动（随倾斜旋转 + hover 同步浮动）
	_flame_l.visible = moving and not _dead
	_flame_r.visible = _flame_l.visible
	if _flame_l.visible:
		var hover_off := Vector2(0.0, hover_y)
		_flame_l.rotation = _tilt
		_flame_r.rotation = _tilt
		_flame_l.position = (POD_L * _visual_scale).rotated(_tilt) + hover_off
		_flame_r.position = (POD_R * _visual_scale).rotated(_tilt) + hover_off
		var flick_l := 0.9 + 0.25 * sin(_anim_t * 42.0)
		var flick_r := 0.9 + 0.25 * sin(_anim_t * 42.0 + PI)
		_flame_l.scale = Vector2(_visual_scale * flick_l, _visual_scale * (1.7 - flick_l * 0.55))
		_flame_r.scale = Vector2(_visual_scale * flick_r, _visual_scale * (1.7 - flick_r * 0.55))
	# 受击白闪剪影
	if _flash_left > 0.0:
		_flash_left = maxf(_flash_left - p_game_delta, 0.0)
		_flash.visible = true
		_flash.rotation = _tilt
		_flash.position = _sprite.position
		_flash.modulate.a = clampf(_flash_left / FLASH_TIME, 0.0, 1.0)
	else:
		_flash.visible = false
	# 无敌帧闪烁（半透呼吸）
	modulate.a = 0.62 + 0.38 * sin(_anim_t * 26.0) if invuln_left > 0.0 else 1.0
	# 格挡力场环（MEC_SHIELD）：就绪=青蓝泡泡呼吸；充能=隐藏；格挡=扩散脉冲淡出
	if _shield_ring != null:
		if _shield_pulse_left > 0.0:
			_shield_pulse_left = maxf(_shield_pulse_left - p_game_delta, 0.0)
			var bt := 1.0 - _shield_pulse_left / SHIELD_PULSE_TIME
			_shield_ring.visible = true
			_shield_ring.rotation = 0.0
			_shield_ring.position = _sprite.position
			_shield_ring.scale = Vector2.ONE * (_visual_scale * SHIELD_RING_R / 24.0
				* (1.0 + 0.55 * bt))
			_shield_ring.modulate.a = (1.0 - bt) * 0.9
		elif _skill_shield_left > 0.0:
			_skill_shield_left = maxf(_skill_shield_left - p_game_delta, 0.0)
			_shield_ring.visible = true
			_shield_ring.rotation = _anim_t * 2.4
			_shield_ring.position = _sprite.position
			_shield_ring.scale = Vector2.ONE * (_visual_scale * SHIELD_RING_R / 24.0
				* (1.0 + 0.06 * sin(_anim_t * 9.0)))
			_shield_ring.modulate.a = 0.55 + 0.2 * sin(_anim_t * 8.0)
		elif shield_interval > 0.0 and shield_ready:
			_shield_ring.visible = true
			_shield_ring.rotation = _anim_t * 0.9
			_shield_ring.position = _sprite.position
			_shield_ring.scale = Vector2.ONE * (_visual_scale * SHIELD_RING_R / 24.0
				* (1.0 + 0.045 * sin(_anim_t * 5.2)))
			_shield_ring.modulate.a = 0.5 + 0.14 * sin(_anim_t * 5.2)
		else:
			_shield_ring.visible = false

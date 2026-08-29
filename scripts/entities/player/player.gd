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
var invuln_left: float = 0.0                  # 受击无敌帧（contact_tick=0.6s 口径）
var weapon_slots: Array[WeaponBase] = []      # ≤5（集成包 B.8 第二批收紧：pkg2 用例已迁移 WeaponBase 真件）
var unlocked_slots: int = 1                   # w3→2 / w7→3 / Boss1→4 / Boss2 或 w21→5（F-19）
var level: int = 1
var xp: float = 0.0
var xp_need: float = 14.0                     # 14 × lv^1.4
var hitbox_radius: float = 16.0               # 命中盒半径（敌弹距离判定口径）

var _dead: bool = false
var _drag_accum: Vector2 = Vector2.ZERO       # 相对拖动采样累计（E-15）
var _pickup_area: Area2D = null
var _pickup_shape: CollisionShape2D = null
var _hit_shape: CollisionShape2D = null
var _sprite: Sprite2D = null
var _flame: Sprite2D = null                    # 喷气小尾巴（移动时点亮 + 抖动）
var _flash: Sprite2D = null                    # 受击白闪剪影（叠在舰体上方）
var _flash_left: float = 0.0
var _punch_left: float = 0.0                   # 受击 squash punch 剩余
var _tilt: float = 0.0                         # 移动倾斜（横移 bank）
var _anim_t: float = 0.0                       # 帧内动画时钟（尾焰抖动/无敌闪烁）
var _visual_scale: float = 1.0                 # 舰体基础缩放（hitbox 口径换算）
var _deps: Dictionary = {}                     # setup 注入位（pipeline/pools/grid/registry——包 3/4 接线）

const MAX_SLOTS := 5
const RESPAWN_INVULN_S := 1.5                 # 重开无敌帧 s（B_spec 无数值 → 主控裁定，见 respawn 注释）
const SHIP_TEX_R := 38.0                       # 舰体贴图本体半径 px（TextureFactory.ship 96 画布）
const VISUAL_MULT := 1.35                      # 视觉半径 / 命中盒（弹幕游戏惯例：盒小于形）
const FLASH_TIME := 0.18                       # 受击白闪时长
const PUNCH_TIME := 0.24                       # 受击 squash punch 时长


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
	# 方向 C「哨兵-9」：天空蓝圆头小飞船（厚描边 + 白肚皮）+ 喷气小尾巴
	_visual_scale = hitbox_radius * VISUAL_MULT / SHIP_TEX_R
	_flame = Sprite2D.new()
	_flame.name = "Flame"
	_flame.texture = TextureFactory.ship_flame()
	_flame.position = Vector2(0.0, 26.0)
	_flame.visible = false
	add_child(_flame)
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
	var total := p_move_delta
	if total == Vector2.ZERO:
		total = _drag_accum                 # GameLoop 未投递时消费自采样拖动
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
	# ★ 简化路径（Q-16）：无敌帧判定 → 直接扣 HP → player_hit 事件（不入 M-12）
	if _dead or invuln_left > 0.0:
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


func gain_xp(p_amount: float) -> void:
	# 经验/等级：xp_gained → 升级（多级连升逐次广播，弹卡排队由 GameLoop 仲裁 E-16）
	var amount := maxf(p_amount, 0.0)
	xp += amount
	EventBus.emit_xp_gained(amount)
	while xp >= xp_need:
		xp -= xp_need
		level += 1
		xp_need = _xp_need_for(level)
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
	_drag_accum = Vector2.ZERO
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


# ── 方向 C 表现层（贴纸舰体：倾斜 / 尾焰 / 受击白闪弹回 / 无敌闪烁） ──
func _tick_visual(p_game_delta: float, p_move: Vector2) -> void:
	# 纯表现（game_delta 通道——顿帧自然冻结）；不触碰数值与碰撞
	_anim_t += p_game_delta
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
	# 尾焰：移动时点亮 + 频闪抖动
	_flame.visible = moving and not _dead
	if _flame.visible:
		_flame.rotation = _tilt
		_flame.position = Vector2(0.0, 26.0).rotated(_tilt)
		var flicker := 0.9 + 0.25 * sin(_anim_t * 42.0)
		_flame.scale = Vector2(_visual_scale * flicker, _visual_scale * (1.6 - flicker * 0.5))
	# 受击白闪剪影
	if _flash_left > 0.0:
		_flash_left = maxf(_flash_left - p_game_delta, 0.0)
		_flash.visible = true
		_flash.rotation = _tilt
		_flash.modulate.a = clampf(_flash_left / FLASH_TIME, 0.0, 1.0)
	else:
		_flash.visible = false
	# 无敌帧闪烁（半透呼吸）
	modulate.a = 0.62 + 0.38 * sin(_anim_t * 26.0) if invuln_left > 0.0 else 1.0

# scripts/entities/player/player.gd
# M-02 Player（架构 §2.12）：Area2D 命中盒（低频，Q-15 例外通道）+ 磁吸拾取区（120px）。
# 操作：相对拖动（Q-3）——_unhandled_input 采样拖动向量，tick 应用 + 活动区钳制（下 40% 屏，E-15）。
# 受击：简化路径（Q-16）——无敌帧 contact_tick=0.6s 判定 → 直接扣 HP → 事件，不入 M-12。
# 编排说明（§2.17）：tick(game_delta, move_delta) 由 GameLoop ② 驱动；
# move_delta 非零 = GameLoop 显式投递（E-15 输入采样）；零向量 = 玩家消费自身 _unhandled_input 采样。
class_name Player
extends Area2D

var max_hp: float = 100.0
var hp: float = 100.0
var move_speed: float = 280.0                 # 移速（相对拖动 1:1 口径下的调试/键盘备用参数）
var pickup_radius: float = 120.0              # Q-13 磁吸半径（pickup_pct 词条加成属包 3 常驻词条）
var invuln_left: float = 0.0                  # 受击无敌帧（contact_tick=0.6s 口径）
var dash_invuln_left: float = 0.0             # v0.8.0 冲刺无敌通道（0.15s；受击判定 OR 并联，互不覆盖）
var weapon_slots: Array[WeaponBase] = []      # ≤5（集成包 B.8 第二批收紧：pkg2 用例已迁移 WeaponBase 真件）
var unlocked_slots: int = 1                   # w3→2 / w7→3 / Boss1→4 / Boss2 或 w21→5（F-19）
var level: int = 1
var xp: float = 0.0
var xp_need: float = 14.0                     # 14 × lv^1.4
var hitbox_radius: float = 16.0               # 命中盒半径（敌弹距离判定口径）
var max_hp_bonus_flat: float = 0.0            # v0.8.0 商店 maxhp flat 池（recompute_max_hp 口径）
var character: CharacterData = null           # v0.8.0 角色数据（apply_character 注入；null = 默认）
# ── v0.8.0 冲刺（A7 §V21 冻结） ──
var dash_left: float = 0.0                    # 冲刺剩余时长 s
var dash_cd_left: float = 0.0                 # 冲刺冷却剩余 s（自激活起计）
var _last_move_dir: Vector2 = Vector2.ZERO    # 最近非零移动方向（单位向量；零 = 从未移动）

var _dead: bool = false
var _drag_accum: Vector2 = Vector2.ZERO       # 相对拖动采样累计（E-15）
var _pickup_area: Area2D = null
var _pickup_shape: CollisionShape2D = null
var _hit_shape: CollisionShape2D = null
var _sprite: Sprite2D = null
var _deps: Dictionary = {}                     # setup 注入位（pipeline/pools/grid/registry——包 3/4 接线）

const MAX_SLOTS := 5
const RESPAWN_INVULN_S := 1.5                 # 重生无敌帧 s（B_spec 无数值 → 主控裁定，见 respawn 注释）
# v0.8.0 冲刺常量（A7 §V21 冻结）
const DASH_TIME := 0.18                       # 冲刺时长 s
const DASH_DISTANCE := 220.0                  # 冲刺总位移 px（速度 = 220/0.18 ≈ 1222 px/s）
const DASH_INVULN := 0.15                     # 冲刺无敌时长 s（独立通道，与受击 invuln 互不覆盖）
const DASH_CD := 1.5                          # 冲刺冷却 s（自激活起计）
const TEX_SIZE := 32
static var _shared_texture: ImageTexture = null
const BODY_COLOR := Color(0.35, 0.9, 1.0)


func _ready() -> void:
	# 组注册（敌/敌弹经组查找缓存玩家引用）+ 命中盒/拾取区/占位渲染组装（代码组装为主）
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
	_sprite = Sprite2D.new()
	_sprite.name = "Visual"
	_sprite.centered = true
	_sprite.texture = _get_placeholder_texture()
	var scale_f := hitbox_radius / (TEX_SIZE * 0.5)
	_sprite.scale = Vector2(scale_f, scale_f)
	_sprite.self_modulate = BODY_COLOR
	add_child(_sprite)
	weapon_slots.resize(MAX_SLOTS)
	EventBus.slot_unlocked.connect(_on_slot_unlocked_event)
	var bal := GameConfig.balance
	if bal != null:
		max_hp = GameConfig.get_constant(&"player_base_hp", 100.0)   # player_base_hp 真源 cfg（A3 §0.1）
		hp = max_hp
		pickup_radius = bal.pickup_radius
		xp_need = _xp_need_for(level)


func setup(p_deps: Dictionary) -> void:
	# 注入 pipeline/pools/grid/registry（包 3/4 接线；当前仅存档，武器实例由 equip 装载）
	_deps = p_deps


static func compute_max_hp(p_char_pct: float, p_chip_sum: float, p_flat: float,
		p_curse_layers: int) -> float:
	# ★ v0.8.0 max_hp 公式唯一真源（A7 §V6 冻结）：
	# maxf((base×(1+char_pct) + chip_sum + flat) × (1−0.04n), 1.0)
	# CurseHandler.recompute_max_hp / respawn 全部经此；base 真源 cfg player_base_hp。
	var base: float = GameConfig.get_constant(&"player_base_hp", 100.0)
	return maxf((base * (1.0 + p_char_pct) + p_chip_sum + p_flat)
		* (1.0 - CurseHandler.MAXHP_PER_LAYER * float(maxi(p_curse_layers, 0))), 1.0)


func char_max_hp_pct() -> float:
	# 角色 max_hp% 加成（character null → 0.0 兜底；CharacterData.max_hp_pct）
	if character == null:
		return 0.0
	return character.max_hp_pct


func character_xp_mult() -> float:
	# 角色经验乘子（character null → 1.0 兜底；CharacterData.xp_mult）
	if character == null:
		return 1.0
	return character.xp_mult


func apply_character(p_data: CharacterData) -> void:
	# v0.8.0 角色应用（GameLoop._reset_run_state 在 respawn 前调用；A7 §V18）：
	# move_speed = 基速×乘数 / pickup_radius = 基准+增量（同步 _pickup_shape）；
	# ★ max_hp 不直改——由 respawn → compute_max_hp(char_pct,…) 公式承载。
	character = p_data
	if p_data == null:
		return
	var base_speed: float = GameConfig.get_constant(&"player_base_speed", 280.0)
	move_speed = base_speed * p_data.move_speed_mult
	var base_radius: float = GameConfig.balance.pickup_radius if GameConfig.balance != null else 120.0
	pickup_radius = base_radius + p_data.pickup_radius_add
	if _pickup_shape != null:
		var circle := _pickup_shape.shape as CircleShape2D
		if circle != null:
			circle.radius = pickup_radius


func tick(p_game_delta: float, p_move_delta: Vector2) -> void:
	# 相对拖动移动 + 边界钳制 + 无敌帧推进 + 武器自动开火调度
	if _dead:
		return
	if invuln_left > 0.0:
		invuln_left -= p_game_delta
		if invuln_left < 0.0:
			invuln_left = 0.0
	# v0.8.0 冲刺无敌通道并列递减（game_delta；与受击 invuln 互不覆盖）
	if dash_invuln_left > 0.0:
		dash_invuln_left -= p_game_delta
		if dash_invuln_left < 0.0:
			dash_invuln_left = 0.0
	if dash_left > 0.0:
		dash_left -= p_game_delta
		if dash_left < 0.0:
			dash_left = 0.0
	if dash_cd_left > 0.0:
		dash_cd_left -= p_game_delta
		if dash_cd_left < 0.0:
			dash_cd_left = 0.0
	# v0.8.0 冲刺位移（A7 §V21）：固定速度 = DASH_DISTANCE/DASH_TIME，方向 = 最近非零方向；
	# 冲刺期清 _drag_accum（防冲刺结束帧拖动跳变）
	if dash_left > 0.0:
		_drag_accum = Vector2.ZERO
		global_position += _last_move_dir * (DASH_DISTANCE / DASH_TIME) * p_game_delta
	else:
		var total := p_move_delta
		if total == Vector2.ZERO:
			total = _drag_accum                 # GameLoop 未投递时消费自采样拖动
		_drag_accum = Vector2.ZERO
		if total != Vector2.ZERO:
			_last_move_dir = total.normalized()   # 最近非零方向（单位向量）
		global_position += total
	_clamp_to_playfield()
	# 武器自动开火调度（每帧 tick；集成包 B.8 第二批收紧：weapon_slots 已收窄 WeaponBase——直调）
	for weapon in weapon_slots:
		if weapon != null:
			weapon.tick(p_game_delta)


func _unhandled_input(p_event: InputEvent) -> void:
	# 输入抽象：相对拖动采样（Q-3；E-15 单指针锁定由 GameLoop 输入层承担，本层累计拖动向量）
	if p_event is InputEventScreenDrag:
		_drag_accum += (p_event as InputEventScreenDrag).relative
	elif p_event is InputEventMouseMotion:
		var mm := p_event as InputEventMouseMotion
		if (mm.button_mask & MOUSE_BUTTON_LEFT) != 0:
			_drag_accum += mm.relative
	elif p_event is InputEventKey:
		# v0.8.0 冲刺（A7 §V21）：Shift 按下触发（try_dash fail-fast；HUD 冲刺钮共用）
		# 审查 Q3：过滤 echo——长按不自动连冲（仅按下沿触发一次）
		var key := p_event as InputEventKey
		if key.physical_keycode == KEY_SHIFT and key.pressed and not key.echo:
			try_dash()


func try_dash() -> bool:
	# v0.8.0 冲刺申请（A7 §V21 冻结）：四 fail-fast——死亡 / 冲刺中 / 冷却中 / 从未移动
	#（零方向）；任一命中 → false 且【不进冷却】。成功 → 三计时置位 + 遥测。
	if _dead or dash_left > 0.0 or dash_cd_left > 0.0 or _last_move_dir == Vector2.ZERO:
		return false
	dash_left = DASH_TIME
	dash_cd_left = DASH_CD
	dash_invuln_left = DASH_INVULN
	DebugStats.count(&"dash_activated")
	return true


func take_contact_damage(p_dmg: float) -> void:
	# ★ 简化路径（Q-16）：无敌帧判定（受击 OR 冲刺双通道并联，互不覆盖）→ 诅咒受伤乘区 →
	# 直接扣 HP → player_hit 事件（不入 M-12）。冲刺无敌期受击不写 dash 通道（仍只写 invuln_left）。
	if _dead or invuln_left > 0.0 or dash_invuln_left > 0.0:
		return
	var curse_mult := 1.0
	var handler: Variant = _deps.get("curse_handler")
	if handler is CurseHandler:
		curse_mult = (handler as CurseHandler).dmg_taken_mult()
	var dmg: float = maxf(p_dmg * curse_mult, 0.0)
	hp -= dmg
	invuln_left = GameConfig.balance.contact_tick if GameConfig.balance != null else 0.6
	EventBus.emit_player_hit(dmg, 0)
	if hp <= 0.0:
		hp = 0.0
		_on_died()


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
	# v0.7.0（A6 §3）：max_hp 重导出基线真源——v0.8.0 起公式唯一真源 Player.compute_max_hp
	#（0 芯片 / 0 flat / 0 诅咒 / 角色加成口径）；max_hp_bonus_flat 与冲刺计时随局清零。
	_dead = false
	max_hp = compute_max_hp(char_max_hp_pct(), 0.0, 0.0, 0)
	hp = max_hp
	max_hp_bonus_flat = 0.0
	dash_left = 0.0
	dash_cd_left = 0.0
	dash_invuln_left = 0.0
	_last_move_dir = Vector2.ZERO                # 从未移动语义复位（零方向不冲刺不进冷却）
	level = 1
	xp = 0.0
	xp_need = _xp_need_for(1)
	unlocked_slots = 1
	invuln_left = RESPAWN_INVULN_S
	_drag_accum = Vector2.ZERO


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


static func _get_placeholder_texture() -> ImageTexture:
	# 共享静态占位圆形纹理（程序化生成；美术后续替换）
	if _shared_texture == null:
		var img := Image.create(TEX_SIZE, TEX_SIZE, false, Image.FORMAT_RGBA8)
		var c := float(TEX_SIZE) * 0.5 - 0.5
		for y in range(TEX_SIZE):
			for x in range(TEX_SIZE):
				var dx := float(x) - c
				var dy := float(y) - c
				if dx * dx + dy * dy <= c * c:
					img.set_pixel(x, y, Color.WHITE)
		_shared_texture = ImageTexture.create_from_image(img)
	return _shared_texture

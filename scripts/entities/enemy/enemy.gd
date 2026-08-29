# scripts/entities/enemy/enemy.gd
# M-03 Enemy（架构 §2.11）：Node2D + 子 Area2D（接触伤害，低频）+ Sprite2D（方向 C 分型贴图
# + 共享受击闪白材质 + 果冻感动画）。
# 弹-敌命中由投射物侧 SpaceGrid 查询完成（Q-15，Area2D 只承担玩家接触例外通道）；
# 敌间分离力走网格 10Hz（E-10）——包 4 集成期挂入（enemy_grid 引用已就绪）。
# 方向 C 分型（贴纸风：厚描边 + 眼睛脸）：E1 珊瑚圆球怪 / E2 尖头飞镖（朝向+拉长）/
# E3 方胖装甲块（特厚描边）/ E4 爆虫（充气变大+红脸，警示圈改虚线）/ E5 基底+金冠 /
# Boss 大型聚合体（多层本体 + 漂浮小卫星球，受击果冻抖动）。
# 编排说明（§2.17）：本实体只做自身行为/受击/死亡；tick(game_delta) 由 GameLoop ⑤ 驱动。
class_name Enemy
extends Node2D

var uid: int = 0
var data: EnemyData = null
var tags: int = 0                             # TAG_ELITE / TAG_BOSS
var hp: float = 1.0
var max_hp: float = 1.0
var speed: float = 75.0                       # 波次成长后终值
var contact_dmg: float = 8.0
var exp_value: float = 3.0
var behavior: int = GameConst.EnemyBehavior.CHASE
var hitbox_r: float = 14.0                    # 碰撞半径快照（data.hitbox_r；投射物窄相判定读取）
var resist: Array[float] = [0.0, 0.0, 0.0, 0.0]  # KIN/FIR/ICE/LTG 快照（超导 −30% 实时改写）
var immune_mask: int = 0
var elemental: ElementalState = null          # 状态容器（M-11 注入；包 3 收紧：register_host 挂 ElementalState）
var dead: bool = false                        # 死亡短路标志（E-06：首次致死立即置位）
var boss_phase: int = 0                       # Boss 阶段（HP<50% → 2 等）
var fire_cd_left: float = 0.0                 # RANGED 行为射击冷却
var projectile_pool: ProjectilePool = null    # 敌弹池注入（RANGED 开火；ballistic 场景池）
var enemy_grid: SpaceGrid = null               # 网格引用注入（E-10 分离力/查询预留）

# RANGED 行为参数（EnemyData.ranged 快照）
var bullet_speed: float = 300.0
var fire_cd: float = 1.5
var bullet_atk_ratio: float = 0.5
var spread_deg: float = 0.0
var fire_range: float = 340.0

# ── 爆虫自爆（包 3 转包 4 遗留） ─────────────────────────────────
# 真源 A3 §2.2 敌表 E4 行：「爆炸 20（半径 110，接触后 1.2s 引爆，警示圈）」+ 警报后冲刺 260；
# A3 §3.9 备注：「击退可打断自爆引导」。EnemyData schema 无自爆字段（包 4 裁定：机制常量落
# 敌人 AI 代码侧，注释真源；后续扩展点 = EnemyBehavior 枚举增项，需框架评审），
# 种类判定按 .tres id 约定（resources/enemies/E4_volatile.tres）。
const VOLATILE_ID := &"E4_volatile"
const VOLATILE_FUSE_TIME := 1.2          # 接触后引爆倒计时 s（A3 §2.2 E4 行）
const VOLATILE_BLAST_RADIUS := 110.0     # 爆炸半径 px（= 警示圈半径，A3 §2.2 E4 行）
const VOLATILE_CHARGE_SPEED := 260.0     # 警报后冲刺速度 px/s（A3 §2.2 E4 行）
const VOLATILE_TRIGGER_SLACK := 4.0      # 接触触发余量 px（命中盒和 + 判定缓冲）

var _fuse_armed: bool = false                 # 自爆引导激活（接触后置位）
var _fuse_left: float = 0.0                   # 引爆倒计时（game_delta 通道——顿帧自然冻结）
var _fuse_ring: FuseRing = null               # 警示圈（程序化绘制）

# ── 内部运行时 ─────────────────────────────────────────────────
var _hit_area: Area2D = null                  # 接触伤害判定（低频通道）
var _hit_shape: CollisionShape2D = null
var _sprite: Sprite2D = null                  # 渲染（方向 C 分型贴图 + 共享受击闪白 shader）
var _material: ShaderMaterial = null
var _flash_left: float = 0.0
var _fade_left: float = 0.0
var _player_cache: Node2D = null

# 方向 C 表现层（敌人角色化 2026-08-29：分型剪影/表情/动画状态机）
var _base_scale: float = 1.0                  # hitbox 口径基础缩放（果冻/充能缩放的乘算基准）
var _kind: StringName = &"grunt"              # 分型缓存（spawn 期判定一次——tick 零字符串开销）
var _crown: Sprite2D = null                   # 精英金色皇冠挂件（TAG_ELITE）
var _satellites: Array[Sprite2D] = []         # Boss 漂浮小卫星球（聚合体多层）
var _shadow: Sprite2D = null                  # 底影（E5 悬浮 / Boss；贴地椭圆）
var _sparkles: Array[Sprite2D] = []           # E5 精英微光粒（金色小珠）
var _armor_sprite: Sprite2D = null            # E3 外甲板（与内芯分层错位）
var _armor_cracked: bool = false              # E3 外甲裂纹态（HP≤50% 换裂纹贴图）
var _armor_jiggle_left: float = 0.0           # E3 受击甲板错位抖动剩余
var _wobble_left: float = 0.0                 # 受击果冻抖动剩余
var _face_state: int = 0                      # E4 脸状态（0 平静/1 惊恐/2 引爆）
var _anim_t: float = 0.0                      # 表现时钟（卫星公转/抖动相位）
var _boss_orbit: float = 0.0                  # 卫星公转角
var _boss_angry: bool = false                 # Boss 二阶段变脸贴图标志
var _spawn_left: float = 0.0                  # 出生弹入剩余（0→1 带 overshoot）
var _dash_state: int = 0                      # E2 冲刺状态机（0 巡航/1 蓄力/2 冲刺/3 回弹）
var _dash_left: float = 0.0                   # E2 当前阶段剩余
var _dash_dir: Vector2 = Vector2.ZERO         # E2 冲刺锁定方向（蓄力期末采样）

# E2 疾冲冲刺周期（视觉+走位表现；数值真源 = 本块常量，用户裁定方向 C 敌人角色化：
# 蓄力 0.3s telegraph（果冻压扁+微抖）→ 冲刺 0.35s×1.9 速（拉长 1.4×）→ 回弹 0.25s 半速）
const DASH_CHARGE_TIME := 0.3               # 蓄力 telegraph 时长 s
const DASH_GO_TIME := 0.35                  # 冲刺时长 s
const DASH_RECOVER_TIME := 0.25             # 回弹恢复时长 s
const DASH_CRUISE_TIME := 0.9               # 巡航时长 s
const DASH_SPEED_MULT := 1.9                # 冲刺速度倍率
const DASH_STRETCH := 1.4                   # 冲刺拉长倍率（朝向轴）
const DASH_CHARGE_SQUASH := 0.78            # 蓄力压扁比例

const FLASH_TIME := 0.06                     # 受击闪白时长（用户裁定：0.06s 更脆）
const SPAWN_TIME := 0.35                     # 出生弹入时长（easeOutBack overshoot）
const FADE_IN_TIME := 0.12                    # 入场透明渐显（主体弹入由 SPAWN_TIME 承担）
const TEX_SIZE := 64                          # 敌人贴图画布边长（逻辑半径 32 = hitbox 口径）
const BOSS_TEX_R := 40.0                      # Boss 贴图本体半径 px（96 画布聚合体）
const BOSS_VISUAL_MULT := 1.9                 # Boss 视觉放大倍率（大型聚合体观感；碰撞盒不变）
const WOBBLE_TIME := 0.22                     # 受击果冻抖动时长
const HOVER_AMP := 6.0                        # E5 悬浮幅度 px
static var _flash_shader: Shader = null


func _ready() -> void:
	# 池化实例化期组装（代码组装为主，.tscn 仅做容器，§1.4）
	_sprite = Sprite2D.new()
	_sprite.name = "Visual"
	_sprite.centered = true
	_sprite.texture = TextureFactory.enemy_tex(&"grunt")
	_material = ShaderMaterial.new()
	_material.shader = _get_flash_shader()
	_sprite.material = _material
	add_child(_sprite)
	_hit_area = Area2D.new()
	_hit_area.name = "HitArea"
	_hit_shape = CollisionShape2D.new()
	_hit_shape.name = "HitShape"
	_hit_area.add_child(_hit_shape)
	add_child(_hit_area)
	_fuse_ring = FuseRing.new()
	_fuse_ring.name = "FuseRing"
	_fuse_ring.radius = VOLATILE_BLAST_RADIUS
	_fuse_ring.visible = false
	add_child(_fuse_ring)
	visible = false                            # 池内不可见（取出 spawn 后激活）


func spawn(p_data: EnemyData, p_wave: int, p_tags: int) -> void:
	# 波次成长缩放（F27 四条曲线：HP/DMG 指数、SPD 线性、EXP 通胀）+ 精英模板乘区 + M1 行为降级
	uid = GameConst.next_uid()
	data = p_data
	tags = p_tags | p_data.tags
	var e_hp := 1.0
	var e_spd := 1.0
	var e_dmg := 1.0
	var e_exp := 1.0
	if (tags & GameConst.TAG_ELITE) != 0 and not data.elite_mult.is_empty():
		e_hp = float(data.elite_mult.get("hp", 1.0))
		e_spd = float(data.elite_mult.get("spd", 1.0))
		e_dmg = float(data.elite_mult.get("dmg", 1.0))
		e_exp = float(data.elite_mult.get("exp", 1.0))
	var bal := GameConfig.balance
	var w := float(maxi(p_wave, 1))
	var hp_growth := 1.12 if bal == null else bal.hp_growth_per_wave
	var dmg_growth := 1.06 if bal == null else bal.dmg_growth_per_wave
	var spd_growth := 0.008 if bal == null else bal.spd_growth_per_wave
	var exp_growth := 1.085 if bal == null else bal.exp_inflation_per_wave
	max_hp = data.hp_base * pow(hp_growth, w - 1.0) * e_hp
	hp = max_hp
	speed = data.spd_base * (1.0 + spd_growth * (w - 1.0)) * e_spd
	contact_dmg = data.dmg_base * pow(dmg_growth, w - 1.0) * e_dmg
	exp_value = data.exp_base * pow(exp_growth, w - 1.0) * e_exp
	behavior = data.behavior
	if behavior != GameConst.EnemyBehavior.CHASE and behavior != GameConst.EnemyBehavior.RANGED:
		behavior = GameConst.EnemyBehavior.CHASE    # M1 范围外行为降级（DataValidator 已告警）
	hitbox_r = maxf(data.hitbox_r, 1.0)
	resist = data.resist.duplicate()
	immune_mask = data.immune_mask
	dead = false
	boss_phase = 1 if is_boss() else 0
	elemental = null                          # 包 3 ElementalSystem.register_host 挂入
	bullet_speed = float(data.ranged.get("bullet_speed", 300.0))
	fire_cd = maxf(float(data.ranged.get("fire_cd", 1.5)), 0.1)
	bullet_atk_ratio = float(data.ranged.get("bullet_atk_ratio", 0.5))
	spread_deg = float(data.ranged.get("spread", 0.0))
	fire_range = float(data.ranged.get("fire_range", 340.0))
	fire_cd_left = fire_cd * 0.5              # 开场半冷却（避免同帧齐射）
	_flash_left = 0.0
	_fade_left = FADE_IN_TIME
	_wobble_left = 0.0
	_face_state = 0
	_anim_t = 0.0
	_boss_orbit = 0.0
	_boss_angry = false
	_spawn_left = SPAWN_TIME                  # 出生弹入（0→1 带 overshoot）
	_dash_state = 0
	_dash_left = 0.0
	_dash_dir = Vector2.ZERO
	_armor_cracked = false
	_armor_jiggle_left = 0.0
	if _armor_sprite != null:
		_armor_sprite.position = Vector2.ZERO
		_armor_sprite.rotation = 0.0
	if _sprite != null:
		_sprite.position = Vector2.ZERO
	modulate.a = 0.0                          # 入场渐显起点（前 0.12s 内完成）
	_apply_flash(0.0)
	visible = true
	_sync_visual()


func tick(p_game_delta: float) -> void:
	# 行为机（追击/远程）+ 状态效果速度因子 + 接触伤害 + Boss 阶段检查
	if dead:
		return
	_tick_visual(p_game_delta)
	if _fade_left > 0.0:
		_fade_left -= p_game_delta
		modulate.a = clampf(1.0 - _fade_left / FADE_IN_TIME, 0.0, 1.0)
	if _flash_left > 0.0:
		_flash_left -= p_game_delta
		_apply_flash(clampf(_flash_left / FLASH_TIME, 0.0, 1.0))
	# 状态效果速度因子（寒滞 0.6 / 冻结 0.0——包 3 收紧为 ElementalState 直调；无容器时 1.0）
	var sf := 1.0
	if elemental != null:
		sf = elemental.get_speed_factor()
	var player := _player()
	match behavior:
		GameConst.EnemyBehavior.CHASE:
			if player != null:
				if _kind == &"dart":
					_tick_dart_chase(p_game_delta, player, sf)
				else:
					var dir := (player.global_position - global_position).normalized()
					var spd := speed * sf
					if _fuse_armed:
						spd = VOLATILE_CHARGE_SPEED    # 警报后冲刺（A3 §2.2 E4 行；自爆冲刺不受寒滞减速修正口径）
					global_position += dir * spd * p_game_delta
				_tick_volatile_fuse(p_game_delta, player)
		GameConst.EnemyBehavior.RANGED:
			_tick_ranged(p_game_delta, player, sf)
		_:
			pass
	# 接触伤害（Area2D 低频通道——玩家侧无敌帧 contact_tick 节流）
	if _hit_area != null:
		for area in _hit_area.get_overlapping_areas():
			if area is Player:
				(area as Player).take_contact_damage(contact_dmg)
	_check_boss_phase()


func take_result(p_result: DamageResult) -> void:
	# 受击入口（pipeline 步骤 9 之后由投射物侧调用）：扣血 + 受击闪白/果冻抖动 + 死亡广播
	# 易伤标记：包 3 ElementalSystem 合入后经 elemental 容器承担（get_vuln_factor 已就绪）
	apply_damage(p_result.final_value)
	if not dead:
		_flash_left = FLASH_TIME
		_wobble_left = WOBBLE_TIME           # 方向 C：果冻抖动（squash & stretch）
		if _kind == &"bastion":
			_armor_jiggle_left = 0.18        # E3：甲板错位咔咔抖动
		_apply_flash(1.0)


func apply_damage(p_value: float) -> bool:
	# 管线写血唯一入口；返回 killed（死亡只执行一次，E-06）
	if dead:
		return false
	hp -= maxf(p_value, 0.0)
	if hp <= 0.0:
		hp = 0.0
		_on_died()
		return true
	return false


func get_resist(p_element: int) -> float:
	# 快照读取（含超导削抗后的当前值——resist 数组被反应实时改写）
	if p_element < 0 or p_element >= resist.size():
		return 0.0
	return resist[p_element]


func get_vuln_factor() -> float:
	# 目标侧易伤因子（冰冻易伤 ×1.25——包 3 收紧为 ElementalState 直调；默认 1.0）
	if elemental != null:
		return elemental.get_vuln_factor()
	return 1.0


func knockback(p_force: Vector2) -> void:
	# 近战击退（A3 §3.9：击退可打断自爆引导）；M1 即时位移
	global_position += p_force
	if _fuse_armed:
		_cancel_fuse()


func is_volatile() -> bool:
	# 爆虫种类判定（EnemyData schema 无自爆字段——包 4 裁定按 .tres id 约定，见常量块注释）
	return data != null and data.id == VOLATILE_ID


func _tick_dart_chase(p_game_delta: float, p_player: Node2D, p_speed_factor: float) -> void:
	# E2 疾冲状态机（CHASE 分支内）：巡航 → 蓄力 telegraph（0.3s 原地压扁微抖）→
	# 冲刺（0.35s×1.9 速锁定方向，撞界/贴身回弹）→ 回弹（0.25s 半速后撤）。game_delta 通道。
	_dash_left -= p_game_delta
	if _dash_left <= 0.0:
		match _dash_state:
			0:
				_dash_state = 1                       # 巡航毕 → 蓄力 telegraph
				_dash_left = DASH_CHARGE_TIME
			1:
				_dash_dir = (p_player.global_position - global_position).normalized()
				_dash_state = 2
				_dash_left = DASH_GO_TIME
			2:
				_dash_state = 3
				_dash_left = DASH_RECOVER_TIME
			_:
				_dash_state = 0
				_dash_left = DASH_CRUISE_TIME
	match _dash_state:
		0:
			# 巡航：正常追击（受状态效果减速）
			var dir := (p_player.global_position - global_position).normalized()
			global_position += dir * speed * p_speed_factor * p_game_delta
		1:
			pass                                    # 蓄力：原地 telegraph（压扁微抖在表现层）
		2:
			# 冲刺：锁定方向 1.9×（不吃寒滞修正口径——与 E4 自爆冲刺同理）
			global_position += _dash_dir * speed * DASH_SPEED_MULT * p_game_delta
			# 撞界回弹：钳出界即反弹方向并提前收势
			var size := Vector2(720.0, 1280.0)
			if GameConfig.balance != null:
				size = Vector2(GameConfig.balance.res_logic)
			var p := global_position
			if p.x <= hitbox_r or p.x >= size.x - hitbox_r:
				_dash_dir = Vector2(-_dash_dir.x, _dash_dir.y)
				_dash_state = 3
				_dash_left = DASH_RECOVER_TIME
			elif p.y <= hitbox_r or p.y >= size.y - hitbox_r:
				_dash_dir = Vector2(_dash_dir.x, -_dash_dir.y)
				_dash_state = 3
				_dash_left = DASH_RECOVER_TIME
			elif global_position.distance_to(p_player.global_position) <= hitbox_r + 20.0:
				# 命中回弹：贴身即收势（接触伤害由 Area2D 低频通道承担）
				_dash_state = 3
				_dash_left = DASH_RECOVER_TIME
		3:
			# 回弹：半速后撤（吃寒滞修正）
			var away := (global_position - p_player.global_position).normalized()
			global_position += away * speed * 0.5 * p_speed_factor * p_game_delta


# ── 爆虫自爆引导（包 3 转包 4 遗留；数值真源见常量块注释） ──────────
func _tick_volatile_fuse(p_game_delta: float, p_player: Node2D) -> void:
	# CHASE 分支内调用：未引导时检测接触 → 激活 1.2s 引爆倒计时 + 警示圈；引导中倒计时归零引爆
	if not is_volatile() or dead:
		return
	if not _fuse_armed:
		var reach := hitbox_r + float(p_player.get("hitbox_radius")) + VOLATILE_TRIGGER_SLACK
		if global_position.distance_to(p_player.global_position) <= reach:
			_fuse_armed = true
			_fuse_left = VOLATILE_FUSE_TIME
			_fuse_ring.visible = true
			_fuse_ring.progress = 0.0
		return
	_fuse_left -= p_game_delta
	_fuse_ring.progress = 1.0 - clampf(_fuse_left / VOLATILE_FUSE_TIME, 0.0, 1.0)
	_fuse_ring.queue_redraw()
	if _fuse_left <= 0.0:
		_explode(p_player)


func _explode(p_player: Node2D) -> void:
	# 引爆：半径 110px 内玩家结算爆炸伤害（= dmg_base 波次成长值，A3「爆炸 20」）；本体死亡
	_fuse_armed = false
	_fuse_left = 0.0
	_fuse_ring.visible = false
	if p_player != null and is_instance_valid(p_player):
		if global_position.distance_to(p_player.global_position) <= VOLATILE_BLAST_RADIUS:
			(p_player as Player).take_contact_damage(contact_dmg)
	hp = 0.0
	_on_died()


func _cancel_fuse() -> void:
	# 击退打断（A3 §3.9 备注）；警示圈收起，回到普通追击（可再次触发）
	_fuse_armed = false
	_fuse_left = 0.0
	_fuse_ring.visible = false


func fuse_armed() -> bool:
	# 测试/遥测观测口
	return _fuse_armed


func fuse_left() -> float:
	return _fuse_left


func is_boss() -> bool:
	return (tags & GameConst.TAG_BOSS) != 0


func is_elite() -> bool:
	return (tags & GameConst.TAG_ELITE) != 0


func _on_died() -> void:
	# 一次性死亡：置 dead → EventBus.emit_enemy_killed → 池归还（EnemySpawner 订阅承担）
	dead = true
	EventBus.emit_enemy_killed(self)


func _tick_ranged(p_game_delta: float, p_player: Node2D, p_speed_factor: float) -> void:
	# RANGED：射程外逼近，射程内驻停 + 冷却射击（敌弹走简化伤害路径 Q-16）
	if p_player == null:
		return
	var dist := global_position.distance_to(p_player.global_position)
	if dist > fire_range:
		var dir := (p_player.global_position - global_position).normalized()
		global_position += dir * speed * p_speed_factor * p_game_delta
	fire_cd_left -= p_game_delta
	if fire_cd_left <= 0.0 and dist <= fire_range:
		_fire_at(p_player)
		fire_cd_left = fire_cd


func _fire_at(p_player: Node2D) -> void:
	# 敌弹发射（ballistic 场景池；散射 spread_deg；伤害=contact_dmg×bullet_atk_ratio）
	if projectile_pool == null:
		return
	var bullet := projectile_pool.acquire() as BallisticProjectile
	if bullet == null:
		return
	bullet.pool = projectile_pool
	var dir := (p_player.global_position - global_position).normalized()
	if spread_deg > 0.0:
		dir = dir.rotated(randf_range(-deg_to_rad(spread_deg), deg_to_rad(spread_deg)))
	bullet.position = global_position
	bullet.spawn({
		"velocity": dir * bullet_speed,
		"lifetime": 5.0,
		"pierce": 1,
		"bounces": 0,
		"hitbox_radius": 5.0,
		"team": 1,
		"panel_snapshot": {"base_atk": contact_dmg * bullet_atk_ratio},
	})


func _check_boss_phase() -> void:
	# Boss 阶段检查（HP<50% → 阶段2 全抗 +phase2_resist；阶段3 预留）
	if not is_boss() or boss_phase != 1:
		return
	if hp >= max_hp * 0.5:
		return
	boss_phase = 2
	var p2 := float(data.boss.get("phase2_resist", 0.0))
	if p2 > 0.0:
		for i in range(resist.size()):
			resist[i] = minf(resist[i] + p2, 0.8)


func _reset_state() -> void:
	# 归还清零契约（E-04/E-05：状态容器/行为参数/计时/位标志；uid 保留——同帧网格快照去重依赖）
	data = null
	tags = 0
	hp = 0.0
	max_hp = 0.0
	speed = 75.0
	contact_dmg = 8.0
	exp_value = 3.0
	behavior = GameConst.EnemyBehavior.CHASE
	hitbox_r = 14.0
	resist = [0.0, 0.0, 0.0, 0.0]
	immune_mask = 0
	elemental = null
	dead = true                               # 池内 = 不存在（死亡态短路）：同帧网格快照仍含
	                                          # 已归还节点，二次命中经 apply_damage 走 dead 短路
	                                          # /管线 dropped_dead 丢弃——否则会二次死亡广播 +
	                                          # 重复归还被拒（集成包压力场景实测 91 次，已修）
	boss_phase = 0
	fire_cd_left = 0.0
	projectile_pool = null
	enemy_grid = null
	bullet_speed = 300.0
	fire_cd = 1.5
	bullet_atk_ratio = 0.5
	spread_deg = 0.0
	fire_range = 340.0
	_fuse_armed = false
	_fuse_left = 0.0
	if _fuse_ring != null:
		_fuse_ring.visible = false
		_fuse_ring.progress = 0.0
	_flash_left = 0.0
	_fade_left = 0.0
	_wobble_left = 0.0
	_face_state = 0
	_anim_t = 0.0
	_boss_orbit = 0.0
	_boss_angry = false
	_spawn_left = 0.0
	_dash_state = 0
	_dash_left = 0.0
	_dash_dir = Vector2.ZERO
	_armor_cracked = false
	_armor_jiggle_left = 0.0
	_kind = &"grunt"
	modulate.a = 1.0
	_apply_flash(0.0)
	if _sprite != null:
		_sprite.rotation = 0.0
		_sprite.position = Vector2.ZERO
		_sprite.scale = Vector2(_base_scale, _base_scale)
		_sprite.texture = TextureFactory.enemy_tex(&"grunt")
	if _armor_sprite != null:
		_armor_sprite.visible = false
		_armor_sprite.position = Vector2.ZERO
		_armor_sprite.rotation = 0.0
		_armor_sprite.texture = TextureFactory.enemy_tex(&"bastion_armor")
	if _shadow != null:
		_shadow.visible = false
		_shadow.modulate.a = 1.0
	if _crown != null:
		_crown.visible = false
	for i in range(_satellites.size()):
		_satellites[i].visible = false
	for i in range(_sparkles.size()):
		_sparkles[i].visible = false
		_sparkles[i].modulate.a = 1.0


# ── 支撑 ──────────────────────────────────────────────────────────
func _player() -> Node2D:
	# 玩家引用缓存（组查找；包 4 集成期可改为显式注入——当前零接线成本）
	if _player_cache == null or not is_instance_valid(_player_cache):
		_player_cache = null
		var tree := get_tree()
		if tree != null:
			_player_cache = tree.get_first_node_in_group(&"player") as Node2D
	return _player_cache


func _sync_visual() -> void:
	# 方向 C 分型渲染同步：贴图按种类切换 + 半径等比缩放（Boss 视觉放大；碰撞盒不变）。
	# 分型判定只在 spawn 期做一次（_kind 缓存——tick 表现层零字符串开销）。
	if _sprite == null or data == null:
		return
	_kind = _visual_kind()
	var r := hitbox_r
	var is_boss_kind := String(_kind).begins_with("boss")
	if is_boss_kind:
		_base_scale = r * BOSS_VISUAL_MULT / BOSS_TEX_R
		_sprite.texture = TextureFactory.enemy_tex(_kind, false)
	else:
		_base_scale = r / (TEX_SIZE * 0.5)
		match _kind:
			&"volatile":
				_sprite.texture = TextureFactory.enemy_tex(&"volatile", false)
			&"elite":
				_sprite.texture = TextureFactory.enemy_tex(&"elite")
			&"bastion":
				_sprite.texture = TextureFactory.enemy_tex(&"bastion_core")
			_:
				_sprite.texture = TextureFactory.enemy_tex(_kind)
	_sprite.scale = Vector2(_base_scale, _base_scale)
	_sprite.rotation = 0.0
	_ensure_armor(_kind)
	_ensure_crown(_kind)
	_ensure_shadow(_kind)
	_ensure_sparkles(_kind)
	_ensure_satellites(_kind)
	# 绘制序（同 z 树序，禁 z_index 负值——会压到世界背景之下）：底影 < 外甲板 < 本体
	# （后 move 的排 index 0：先甲板后底影 → 最终序 底影(0) < 甲板(1) < 本体）
	if _armor_sprite != null:
		move_child(_armor_sprite, 0)
	if _shadow != null:
		move_child(_shadow, 0)
	if _hit_shape != null:
		var shape := CircleShape2D.new()
		shape.radius = r
		_hit_shape.shape = shape


func _visual_kind() -> StringName:
	# 分型判定（tag 优先级 Boss > 精英 > E1~E5 id 前缀约定）：
	# boss1/2/3 三套剪影互异的大型聚合体；E5 精英 = 金腹徽基底（引擎侧加皇冠/悬浮/微光）
	if is_boss() and data != null:
		var bid := String(data.id)
		if bid.begins_with("E6_boss2"):
			return &"boss2"
		if bid.begins_with("E6_boss3"):
			return &"boss3"
		return &"boss1"
	if is_elite():
		return &"elite"
	if data == null:
		return &"grunt"
	var sid := String(data.id)
	if sid.begins_with("E2"):
		return &"dart"
	if sid.begins_with("E3"):
		return &"bastion"
	if sid.begins_with("E4"):
		return &"volatile"
	return &"grunt"


func _ensure_armor(p_kind: StringName) -> void:
	# E3 重甲外甲板（双层甲板分层：外甲贴图叠在内芯上方，运行期错位摆动）；
	# 非 E3 复用时仅隐藏（节点随池实例存活，跨复用零实例化）
	var want := p_kind == &"bastion"
	if want and _armor_sprite == null:
		_armor_sprite = Sprite2D.new()
		_armor_sprite.name = "ArmorPlate"
		_armor_sprite.texture = TextureFactory.enemy_tex(&"bastion_armor")
		add_child(_armor_sprite)
	if _armor_sprite != null:
		_armor_sprite.visible = want
		if want:
			_armor_sprite.scale = Vector2(_base_scale, _base_scale)


func _ensure_crown(p_kind: StringName) -> void:
	# 精英金色皇冠小标（E5 基底 + 皇冠；非精英回收挂件）
	var want := is_elite() and not String(p_kind).begins_with("boss")
	if want and _crown == null:
		_crown = Sprite2D.new()
		_crown.name = "Crown"
		_crown.texture = TextureFactory.crown()
		add_child(_crown)
	if _crown != null:
		_crown.visible = want
		if want:
			_crown.scale = Vector2(_base_scale, _base_scale)
			_crown.position = Vector2(0.0, -(hitbox_r * 1.18))


func _ensure_shadow(p_kind: StringName) -> void:
	# 底影（E5 悬浮 / Boss 大型体；贴地椭圆，悬浮高度驱动缩放——「离地感」）
	# 绘制序用树序（_sync_visual 末尾 move_child 置底），不用 z_index 负值——
	# 负 z 会排到世界背景之下被盖住
	var want := String(p_kind).begins_with("boss") or p_kind == &"elite"
	if want and _shadow == null:
		_shadow = Sprite2D.new()
		_shadow.name = "GroundShadow"
		_shadow.texture = TextureFactory.shadow_ellipse()
		add_child(_shadow)
	if _shadow != null:
		_shadow.visible = want
		if want:
			var w := hitbox_r * 2.6 if String(p_kind).begins_with("boss") else hitbox_r * 1.7
			_shadow.scale = Vector2(w / 64.0 * 2.0, w / 64.0 * 0.62)
			_shadow.position = Vector2(0.0, hitbox_r * 1.05)


func _ensure_sparkles(p_kind: StringName) -> void:
	# E5 精英微光粒（两颗金色小珠缓浮闪烁——「一眼精英」第三件套：皇冠/阴影/微光）
	var want := p_kind == &"elite"
	if want and _sparkles.is_empty():
		for i in range(2):
			var sp := Sprite2D.new()
			sp.name = "Sparkle%d" % i
			sp.texture = TextureFactory.bead(PopPalette.GOLD, 16, false)
			add_child(sp)
			_sparkles.append(sp)
	for i in range(_sparkles.size()):
		var sp := _sparkles[i]
		sp.visible = want
		if want:
			sp.scale = Vector2(_base_scale * 0.22, _base_scale * 0.22)


func _ensure_satellites(p_kind: StringName) -> void:
	# Boss 漂浮小卫星球（boss1=2 颗 / boss2/3=3 颗；白珠公转，运行期只更新位置）
	# 非 Boss 复用时仅隐藏（节点随池实例存活，跨复用零实例化）
	var want := String(p_kind).begins_with("boss")
	var count := 3 if _kind == &"boss2" or _kind == &"boss3" else 2
	if want and _satellites.is_empty():
		for i in range(3):
			var orb := Sprite2D.new()
			orb.name = "Satellite%d" % i
			orb.texture = TextureFactory.bead(PopPalette.PANEL, 32, false)
			add_child(orb)
			_satellites.append(orb)
	for i in range(_satellites.size()):
		var orb := _satellites[i]
		orb.visible = want and i < count
		if orb.visible:
			orb.scale = Vector2(_base_scale, _base_scale) * 0.42


func _tick_visual(p_game_delta: float) -> void:
	# 表现层状态机（game_delta 通道——顿帧自然冻结；零碰撞、零数值副作用）：
	# 出生弹入 / 受击果冻 / 分型动画（E1 摇摆呼吸 / E2 冲刺形变 / E3 甲板错位 /
	# E4 充能三段变脸 / E5 悬浮微光 / Boss 公转 + 二阶段变脸）。
	_anim_t += p_game_delta
	var sx := _base_scale
	var sy := _base_scale
	var rot := 0.0
	var off := Vector2.ZERO
	match _kind:
		&"dart":
			rot = _dart_rotation()
			match _dash_state:
				1:                                      # 蓄力 telegraph：压扁 + 高频微抖
					sx = _base_scale * DASH_CHARGE_SQUASH
					sy = _base_scale * (2.0 - DASH_CHARGE_SQUASH)
					off = Vector2(sin(_anim_t * 84.0), cos(_anim_t * 67.0)) * 1.3 * _base_scale
				2:                                      # 冲刺：沿朝向拉长 1.4×
					sx = _base_scale * 0.75
					sy = _base_scale * DASH_STRETCH
				3:                                      # 回弹：反向压缩
					sx = _base_scale * 1.12
					sy = _base_scale * 0.9
				_:
					sx = _base_scale * 0.92
					sy = _base_scale * 1.08
		&"bastion":
			var breathe_b := 1.0 + 0.02 * sin(_anim_t * 3.4 + float(uid % 32))
			sx = _base_scale * breathe_b
			sy = _base_scale * (2.0 - breathe_b)
			_tick_bastion_armor(p_game_delta)
		&"volatile":
			rot = 0.05 * sin(_anim_t * 3.0 + float(uid % 32))
			var grow := 1.0
			if _fuse_armed:
				var prog := 1.0 - clampf(_fuse_left / VOLATILE_FUSE_TIME, 0.0, 1.0)
				grow = 1.0 + 0.5 * prog * prog          # 越滚越大（二次缓动）
				if _fuse_left <= VOLATILE_FUSE_TIME * 0.25:
					grow = 1.5                          # 引爆前 0.3s：鼓到最大 + 高频抖动
					off = Vector2(sin(_anim_t * 92.0), cos(_anim_t * 76.0)) * 1.6 * _base_scale
				_set_volatile_face(2 if _fuse_left <= VOLATILE_FUSE_TIME * 0.25 else 1)
			else:
				_set_volatile_face(0)
			sx = _base_scale * grow
			sy = _base_scale * grow
		&"elite":
			var hover := (1.0 - cos(_anim_t * 2.2)) * 0.5
			off.y = -hover * HOVER_AMP
			var breathe_e := 1.0 + 0.03 * sin(_anim_t * 4.6 + float(uid % 32))
			sx = _base_scale * breathe_e
			sy = _base_scale * (2.0 - breathe_e)
			_tick_elite_extras(hover)
		&"boss1", &"boss2", &"boss3":
			off.y = sin(_anim_t * 1.6) * 4.0 * _base_scale
			_tick_boss(p_game_delta)
		_:
			# grunt（E1）：idle 摇摆 + 呼吸（果冻感基调）
			rot = 0.06 * sin(_anim_t * 3.1 + float(uid % 32))
			var breathe_g := 1.0 + 0.035 * sin(_anim_t * 5.0 + float(uid % 32))
			sx = _base_scale * breathe_g
			sy = _base_scale * (2.0 - breathe_g)
	# 受击果冻抖动（squash & stretch 弹性衰减）——覆盖分型形变
	if _wobble_left > 0.0:
		_wobble_left = maxf(_wobble_left - p_game_delta, 0.0)
		var bt := 1.0 - _wobble_left / WOBBLE_TIME
		var s := 1.0 + 0.22 * exp(-4.5 * bt) * sin(bt * 22.0)
		sx = _base_scale * s
		sy = _base_scale * (2.0 - s)
	# 出生弹入（easeOutBack：0→1 带 overshoot）
	if _spawn_left > 0.0:
		_spawn_left = maxf(_spawn_left - p_game_delta, 0.0)
		var bt_spawn := 1.0 - _spawn_left / SPAWN_TIME
		var c1 := 1.70158
		var c3 := c1 + 1.0
		var f := 1.0 + c3 * pow(bt_spawn - 1.0, 3.0) + c1 * pow(bt_spawn - 1.0, 2.0)
		sx *= f
		sy *= f
	_sprite.scale = Vector2(sx, sy)
	_sprite.rotation = rot
	_sprite.position = off


func _dart_rotation() -> float:
	# E2 贴图朝上 → 旋转对齐玩家方向
	var player := _player()
	if player != null and is_instance_valid(player):
		var dir := (player.global_position - global_position).normalized()
		return dir.angle() + PI * 0.5
	return PI * 0.5


func _set_volatile_face(p_state: int) -> void:
	# E4 三段变脸（0 平静好奇 / 1 惊恐瞪眼 / 2 闭眼引爆）——仅状态跃迁时换贴图
	if _face_state == p_state:
		return
	_face_state = p_state
	if _sprite == null:
		return
	match p_state:
		2:
			_sprite.texture = TextureFactory.enemy_tex(&"volatile", true)
		1:
			_sprite.texture = TextureFactory.enemy_tex(&"volatile_scared")
		_:
			_sprite.texture = TextureFactory.enemy_tex(&"volatile", false)


func _tick_bastion_armor(p_game_delta: float) -> void:
	# E3 外甲板「咔咔」错位：低频相位摆 + 受击抖动加强；HP≤50% 换裂纹板
	if _armor_sprite == null or not _armor_sprite.visible:
		return
	if not _armor_cracked and max_hp > 0.0 and hp <= max_hp * 0.5:
		_armor_cracked = true
		_armor_sprite.texture = TextureFactory.enemy_tex(&"bastion_armor_cracked")
	var sway := sin(_anim_t * 6.3) * 1.6 * _base_scale
	if _armor_jiggle_left > 0.0:
		_armor_jiggle_left = maxf(_armor_jiggle_left - p_game_delta, 0.0)
		sway += sin(_armor_jiggle_left * 90.0) * 2.6 * _base_scale
	_armor_sprite.position = Vector2(sway, 0.0)
	_armor_sprite.rotation = 0.02 * sin(_anim_t * 5.1)


func _tick_elite_extras(p_hover: float) -> void:
	# E5「一眼精英」三件套联动：皇冠随悬浮升降 / 底影随高度缩放变淡 / 微光粒缓浮闪烁
	if _crown != null and _crown.visible:
		_crown.position = Vector2(0.0, -(hitbox_r * 1.18) - p_hover * HOVER_AMP)
	if _shadow != null and _shadow.visible:
		var w := hitbox_r * 1.7 * (1.0 - 0.25 * p_hover)
		_shadow.scale = Vector2(w / 64.0 * 2.0, w / 64.0 * 0.62)
		_shadow.modulate.a = 1.0 - 0.35 * p_hover
	for i in range(_sparkles.size()):
		var sp := _sparkles[i]
		if not sp.visible:
			continue
		var ang := _anim_t * 1.7 + PI * float(i)
		var rr := hitbox_r * 1.25
		sp.position = Vector2(cos(ang) * rr, sin(ang) * rr * 0.6 - hitbox_r * 0.2)
		sp.modulate.a = 0.45 + 0.4 * sin(_anim_t * 3.3 + float(i) * 2.1)


func _tick_boss(p_game_delta: float) -> void:
	# Boss：二阶段变脸（HP<50% → boss_phase=2 时怒相贴图 + 公转提速）；卫星公转；底影随浮
	if boss_phase >= 2 and not _boss_angry:
		_boss_angry = true
		_sprite.texture = TextureFactory.enemy_tex(_kind, true)
	if not _satellites.is_empty():
		_boss_orbit += p_game_delta * (3.6 if _boss_angry else 2.1)
		var orbit_r := hitbox_r * BOSS_VISUAL_MULT * 1.18
		var count := 2 if _kind == &"boss1" else 3
		for i in range(_satellites.size()):
			var ang := _boss_orbit + TAU * float(i) / float(count)
			_satellites[i].position = Vector2(cos(ang), sin(ang)) * orbit_r
	if _shadow != null and _shadow.visible:
		_shadow.modulate.a = 0.85 + 0.15 * sin(_anim_t * 1.6)


func _apply_flash(p_amount: float) -> void:
	# 受击闪白（shader 占位：flash_amount 0→1 白色混合）
	if _material != null:
		_material.set_shader_parameter(&"flash_amount", p_amount)


static func _get_flash_shader() -> Shader:
	# 受击闪白 shader 占位（共享 shader；材质按实例持有，flash_amount 独立）
	if _flash_shader == null:
		_flash_shader = Shader.new()
		_flash_shader.code = "\
shader_type canvas_item;\n\
uniform float flash_amount : hint_range(0.0, 1.0) = 0.0;\n\
void fragment() {\n\
	vec4 tex = texture(TEXTURE, UV);\n\
	COLOR = vec4(mix(tex.rgb, vec3(1.0), flash_amount), tex.a);\n\
}\n"
	return _flash_shader


# ── 爆虫警示圈（方向 C：虚线圈 + 进度环；半径 = VOLATILE_BLAST_RADIUS，A3 §2.2「警示圈」） ──
class FuseRing:
	extends Node2D

	var radius: float = 110.0
	var progress: float = 0.0                   # 引导进度 0~1（圈色渐亮渐红）

	func _draw() -> void:
		# 虚线警戒圈（亮底风格：虚线圆 + 淡填充 + 进度弧，程序化绘制）
		var fill := Color(1.0, 0.36, 0.36, 0.05 + 0.13 * progress)
		draw_circle(Vector2.ZERO, radius, fill)
		var segs := 28
		var seg_arc := TAU / float(segs * 2)
		var edge := Color(1.0, 0.36, 0.36, 0.4 + 0.5 * progress)
		for i in range(segs):
			var a0 := float(i) * seg_arc * 2.0
			draw_arc(Vector2.ZERO, radius, a0, a0 + seg_arc, 8, edge, 3.5, true)
		# 进度弧（柠檬金→珊瑚红，贴近倒计时紧迫感）
		if progress > 0.01:
			draw_arc(Vector2.ZERO, radius * 0.86, -PI * 0.5,
				-PI * 0.5 + TAU * progress, 48, PopPalette.XP, 5.0, true)

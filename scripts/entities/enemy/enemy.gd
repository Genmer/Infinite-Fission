# scripts/entities/enemy/enemy.gd
# M-03 Enemy（架构 §2.11）：Node2D + 子 Area2D（接触伤害，低频）+ Sprite2D（共享受击闪白材质）。
# 弹-敌命中由投射物侧 SpaceGrid 查询完成（Q-15，Area2D 只承担玩家接触例外通道）；
# 敌间分离力走网格 10Hz（E-10）——包 4 集成期挂入（enemy_grid 引用已就绪）。
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
var resist: Array[float] = [0.0, 0.0, 0.0, 0.0, 0.0]  # KIN/FIR/ICE/LTG/WAT 快照（超导 −30% 实时改写；v1.2.0 5 位，A11 §2）
var immune_mask: int = 0
var elemental: ElementalState = null          # 状态容器（M-11 注入；包 3 收紧：register_host 挂 ElementalState）
var dead: bool = false                        # 死亡短路标志（E-06：首次致死立即置位）
var boss_phase: int = 0                       # Boss 阶段（HP<50% → 2 等）
var fire_cd_left: float = 0.0                 # RANGED 行为射击冷却
var projectile_pool: ProjectilePool = null    # 敌弹池注入（RANGED 开火；ballistic 场景池）
var enemy_grid: SpaceGrid = null               # 网格引用注入（E-10 分离力/查询预留）
var summon_spawner: EnemySpawner = null       # v0.6.0 召唤注入（Boss 召唤入队宿主；spawner 出队段注入）
var _spawn_wave: int = 1                      # v0.6.0 召唤波号快照（波次成长口径）
var is_summon: bool = false                   # v0.7.0 U13：Boss 召唤物标记（出生入列键 summon:true）
var gold_rush: bool = false                   # v0.7.0 U5：金币狂欢波标记（掉落覆写消费）

# ── v0.6.0 Boss 弹幕/召唤（A4 §7；T7 落地，Boss3 charge/phase3/laser_sweep defer 不消费） ──
var _boss_pattern: Dictionary = {}            # bullet_patterns 快照（spawn 时 duplicate）
var _boss_summons: Dictionary = {}            # summons 快照（spawn 时 duplicate）
var _pattern_cd_left: float = 0.0             # 弹幕计时（开场半冷却防同帧齐射）
var _summon_cd_left: float = 0.0              # 召唤计时（开场半冷却）
var _spiral_offset: float = 0.0               # spiral 逐轮推进角（rad）

const BOSS_BULLET_SPEED := 300.0              # Boss 弹速 px/s（A3 §2.2 Boss 弹）
const BOSS_BULLET_LIFETIME := 6.0             # Boss 弹存活 s
const BOSS_BULLET_RADIUS := 6.0               # Boss 弹命中半径 px
const FAN_STEP_DEG := 10.0                    # fan 相邻弹夹角（P2 用 count_phase2）
const SPIRAL_ADVANCE := 0.7                   # spiral 每轮推进角 rad
const BOSS_SUMMON_ACTIVE_CAP := 12            # 场上召唤上限（spawner.active_count 闸）

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
var _ring: ElementRing = null                 # v0.7.0 U8：附着环（FIR/ICE/LTG 扇区弧）
var _ring_refresh_left: float = 0.0           # v0.7.0 U8：附着环 15Hz 降频相位

# ── 内部运行时 ─────────────────────────────────────────────────
var _hit_area: Area2D = null                  # 接触伤害判定（低频通道）
var _hit_shape: CollisionShape2D = null
var _sprite: Sprite2D = null                  # 占位渲染（共享受击闪白 shader）
var _material: ShaderMaterial = null
var _flash_left: float = 0.0
var _fade_left: float = 0.0
var _player_cache: Node2D = null

const FLASH_TIME := 0.12                     # 受击闪白时长
const FADE_IN_TIME := 0.3                     # 入场渐显时长
const TEX_SIZE := 64                          # 占位圆形纹理边长
static var _shared_texture: ImageTexture = null
static var _flash_shader: Shader = null
const BODY_COLORS := {
	"boss": Color(0.9, 0.25, 0.3),
	"elite": Color(1.0, 0.6, 0.15),
	"ranged": Color(0.7, 0.5, 0.9),
	"default": Color(0.5, 0.65, 0.8),
}


func _ready() -> void:
	# 池化实例化期组装（代码组装为主，.tscn 仅做容器，§1.4）
	_sprite = Sprite2D.new()
	_sprite.name = "Visual"
	_sprite.centered = true
	_sprite.texture = _get_placeholder_texture()
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
	_ring = ElementRing.new()
	_ring.name = "ElementRing"
	_ring.visible = false
	add_child(_ring)
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
	var dmg_growth := 1.06 if bal == null else bal.dmg_growth_per_wave
	var spd_growth := 0.008 if bal == null else bal.spd_growth_per_wave
	var exp_growth := 1.085 if bal == null else bal.exp_inflation_per_wave
	# v0.7.0 U5：HP 成长真源统一走 projected_max_hp（消除公式双写——金币关 hp_override 同源）
	max_hp = projected_max_hp(data, p_wave) * e_hp
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
	is_summon = false                            # v0.7.0 U13：默认非召唤（入列键 summon 置真）
	gold_rush = false                            # v0.7.0 U5：默认非金币关（波次标记置真）
	boss_phase = 1 if is_boss() else 0
	elemental = null                          # 包 3 ElementalSystem.register_host 挂入
	bullet_speed = float(data.ranged.get("bullet_speed", 300.0))
	fire_cd = maxf(float(data.ranged.get("fire_cd", 1.5)), 0.1)
	bullet_atk_ratio = float(data.ranged.get("bullet_atk_ratio", 0.5))
	spread_deg = float(data.ranged.get("spread", 0.0))
	fire_range = float(data.ranged.get("fire_range", 340.0))
	fire_cd_left = fire_cd * 0.5              # 开场半冷却（避免同帧齐射）
	# v0.6.0 Boss 弹幕/召唤快照（duplicate 防资源共享改写；空段 = 非 Boss/无弹幕，tick 短路）
	_boss_pattern = (data.boss.get("bullet_patterns", {}) as Dictionary).duplicate()
	_boss_summons = (data.boss.get("summons", {}) as Dictionary).duplicate()
	_pattern_cd_left = float(_boss_pattern.get("interval_s", 6.0)) * 0.5   # 开场半冷却
	_summon_cd_left = float(_boss_summons.get("interval_s", 12.0)) * 0.5
	_spiral_offset = 0.0
	_spawn_wave = p_wave
	_flash_left = 0.0
	_fade_left = FADE_IN_TIME
	if _ring != null:                          # v0.7.0 U8：附着环半径 = hitbox + 7px
		_ring.radius = hitbox_r + 7.0
		_ring.visible = false
		_ring.set_gauges([0.0, 0.0, 0.0, 0.0, 0.0])
	_ring_refresh_left = 0.0
	modulate.a = 0.0                          # 入场渐显起点
	_apply_flash(0.0)
	visible = true
	_sync_visual()


func tick(p_game_delta: float) -> void:
	# 行为机（追击/远程）+ 状态效果速度因子 + 接触伤害 + Boss 阶段检查
	if dead:
		return
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
	# v1.2.0 冻结全停判定（A11 §3：移动 sf=0 既有 + RANGED/Boss 行为门；
	# 同一 freeze_timer 通道——既有 ICE 满槽冻结同步升级全停）
	var frozen := elemental != null and elemental.freeze_timer > 0.0
	_tick_element_ring(p_game_delta)           # v0.7.0 U8：附着环驱动（15Hz 降频）
	var player := _player()
	match behavior:
		GameConst.EnemyBehavior.CHASE:
			if player != null:
				var dir := (player.global_position - global_position).normalized()
				var spd := speed * sf
				if _fuse_armed:
					spd = VOLATILE_CHARGE_SPEED    # 警报后冲刺（A3 §2.2 E4 行；自爆冲刺不受寒滞减速修正口径）
				global_position += dir * spd * p_game_delta
				_tick_volatile_fuse(p_game_delta, player)
		GameConst.EnemyBehavior.RANGED:
			if not frozen:
				_tick_ranged(p_game_delta, player, sf)
		_:
			pass
	# 接触伤害（Area2D 低频通道——玩家侧无敌帧 contact_tick 节流）
	if _hit_area != null:
		for area in _hit_area.get_overlapping_areas():
			if area is Player:
				(area as Player).take_contact_damage(contact_dmg)
	if is_boss():
		_tick_boss_patterns(p_game_delta)     # v0.6.0：Boss 弹幕/召唤计时（A4 §7）
	_check_boss_phase()


func take_result(p_result: DamageResult) -> void:
	# 受击入口（pipeline 步骤 9 之后由投射物侧调用）：扣血 + 受击闪白 + 死亡广播
	# 易伤标记：包 3 ElementalSystem 合入后经 elemental 容器承担（get_vuln_factor 已就绪）
	# v1.2.0 冻结破碎直击计数（A11 §3）：冻结期内 NORMAL/CRIT 直击入账（第 3 击解冻+帧末破碎；
	# REACTION/DOT 等其他通道不计）
	if elemental != null and elemental.freeze_timer > 0.0 \
			and (p_result.popup_style == GameConst.PopupStyle.NORMAL
				or p_result.popup_style == GameConst.PopupStyle.CRIT):
		elemental.register_freeze_hit(p_result.panel_snapshot)
	apply_damage(p_result.final_value)
	if not dead:
		_flash_left = FLASH_TIME
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


func spawn_wave() -> int:
	# v0.7.0 观测口：出生波号快照（U6 Boss 芯片掉落按出生波 roll；_spawn_wave spawn 期已记录）
	return _spawn_wave


static func projected_max_hp(p_data: EnemyData, p_wave: int) -> float:
	# v0.7.0 U5：波次成长 HP 预测真源 = hp_base × hp_growth^(w−1)。TAG_ELITE 运行期乘区
	# 不在本口径（波表构成里精英走 E5 模板自带 hp_base——预测已含模板口径；GOLD_RUSH 变体
	# 按 0.4× 模板基础生效，精英不另乘 = 有意设计，审查 Q3 留痕 A6）。spawn 内改调本真源 +
	# WaveDirector 金币关 hp_override 同源（消除双写）。
	var bal := GameConfig.balance
	var hp_growth := 1.12 if bal == null else bal.hp_growth_per_wave
	return p_data.hp_base * pow(hp_growth, float(maxi(p_wave, 1)) - 1.0)


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


# ── v0.6.0 Boss 弹幕三形态 + 召唤（A4 §7） ────────────────────────
func _tick_boss_patterns(p_game_delta: float) -> void:
	# Boss 专用计时（tick 内 is_boss 时调用；dead 短路已由 tick 入口拦）：
	# 弹幕/召唤双计时器，开场半冷却（interval_s×0.5），发射后回满间隔
	# v1.2.0：冻结全停（A11 §3——弹幕+召唤计时全停，dead 短路后判定）
	if dead:
		return
	if elemental != null and elemental.freeze_timer > 0.0:
		return
	if not _boss_pattern.is_empty():
		_pattern_cd_left -= p_game_delta
		if _pattern_cd_left <= 0.0:
			_fire_pattern()
			_pattern_cd_left = maxf(float(_boss_pattern.get("interval_s", 6.0)), 0.1)
	if not _boss_summons.is_empty():
		_summon_cd_left -= p_game_delta
		if _summon_cd_left <= 0.0:
			_summon_allies()
			_summon_cd_left = maxf(float(_boss_summons.get("interval_s", 12.0)), 0.1)


func _fire_pattern() -> void:
	# 三形态（A4 §7）：fan（朝向玩家扇形）/ ring（环形均分）/ spiral（逐轮推进）。
	# P2 判定统一 boss_phase >= 2（真源 _check_boss_phase HP<50%）；count_phase2 /
	# speed_mult_phase2 仅 P2 生效；伤害只走 panel_snapshot.base_atk 单点路径。
	var count := int(_boss_pattern.get("count", 8))
	var phase2 := boss_phase >= 2
	if phase2 and _boss_pattern.has("count_phase2"):
		count = int(_boss_pattern.get("count_phase2", count))
	var speed := BOSS_BULLET_SPEED
	if phase2 and _boss_pattern.has("speed_mult_phase2"):
		speed *= float(_boss_pattern.get("speed_mult_phase2", 1.0))
	var dmg := float(_boss_pattern.get("dmg", 10.0))
	match String(_boss_pattern.get("pattern", "fan")):
		"fan":
			var player := _player()
			var to_player := 0.0
			if player != null:
				to_player = (player.global_position - global_position).angle()
			for i in range(count):
				var angle := to_player \
					+ (float(i) - float(count - 1) / 2.0) * deg_to_rad(FAN_STEP_DEG)
				_fire_boss_bullet(angle, speed, dmg)
		"ring":
			for i in range(count):
				_fire_boss_bullet(float(i) * TAU / float(count), speed, dmg)
		"spiral":
			for i in range(count):
				_fire_boss_bullet(_spiral_offset + float(i) * TAU / float(count), speed, dmg)
			_spiral_offset = fmod(_spiral_offset + SPIRAL_ADVANCE, TAU)
		_:
			pass                                    # 未知形态：跳过该轮（降级不崩溃）


func _fire_boss_bullet(p_angle: float, p_speed: float, p_dmg: float) -> void:
	# 单发 Boss 弹（★ 伤害只走 panel_snapshot.base_atk → take_contact_damage 单点，
	# projectile_base team=1 既有路径；禁入 DamagePipeline/settle_aoe——双落血防线，A4 §7 留痕 3）
	if projectile_pool == null:
		return
	var bullet := projectile_pool.acquire() as BallisticProjectile
	if bullet == null:
		return                                      # 满池：跳过该发（不阻塞不崩溃）
	bullet.pool = projectile_pool
	bullet.position = global_position
	bullet.spawn({
		"velocity": Vector2.RIGHT.rotated(p_angle) * p_speed,
		"lifetime": BOSS_BULLET_LIFETIME,
		"pierce": 1,
		"bounces": 0,
		"hitbox_radius": BOSS_BULLET_RADIUS,
		"team": 1,
		"panel_snapshot": {"base_atk": p_dmg},
	})


func _summon_allies() -> void:
	# 召唤（A4 §7 + v0.7.0 U13）：门 = spawner 注入 + 场上召唤 < BOSS_SUMMON_ACTIVE_CAP
	#（U13 修复：原闸 spawner.active_count() 含普通敌——杂波期 Boss 召唤被误拦/放量失真，
	# 改为召唤独立计数 summon_active_count）+ 分波门（summons.phase 仅 P2 放行）；
	# 位置 = Boss 周围半径 90px 环形均分（无 RNG 确定性）；
	# mode=="split" 且 hp_ratio → hp_override = max_hp × hp_ratio（spawn 侧消费）
	if summon_spawner == null or _boss_summons.is_empty() or dead:
		return
	if summon_spawner.summon_active_count >= BOSS_SUMMON_ACTIVE_CAP:
		return
	if _boss_summons.has("phase") and boss_phase < int(_boss_summons.get("phase", 0)):
		return                                      # 分波门未开（P2 才召唤）
	var data_id := StringName(String(_boss_summons.get("enemy_id", "")))
	if data_id == &"":
		return
	var count := int(_boss_summons.get("count", 1))
	if boss_phase >= 2 and _boss_summons.has("count_phase2"):
		count = int(_boss_summons.get("count_phase2", count))
	var hp_override := 0.0
	if String(_boss_summons.get("mode", "")) == "split":
		hp_override = maxf(float(_boss_summons.get("hp_ratio", 0.0)), 0.0)
	for i in range(count):
		var pos := global_position \
			+ Vector2.RIGHT.rotated(TAU * float(i) / float(count)) * 90.0
		var entry := {"data_id": data_id, "wave": _spawn_wave, "tags": 0, "pos": pos,
			"summon": true}                        # v0.7.0 U13：入列即标记（出生计数）
		if hp_override > 0.0:
			entry["hp_override"] = max_hp * hp_override
		summon_spawner.enqueue(entry)


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


# ── v0.7.0 U8：附着环（FIR/ICE/LTG 扇区弧；15Hz 降频快照） ────────
const RING_REFRESH_HZ := 15.0                  # 附着环刷新频率（降频——绘制成本护栏）


func _tick_element_ring(p_game_delta: float) -> void:
	# max(gauges[1..4]) > 1.0 → 显示 + 15Hz 降频 set_gauges/queue_redraw；否则隐藏（零开销门控；
	# 审查 Q4：无附着路径零分配——不再每 tick 构造临时数组；v1.2.0 门 >=5 / peak 含 WAT，A11 §2）
	if _ring == null:
		return
	if elemental != null and elemental.gauges.size() >= 5:
		var gauges := elemental.gauges
		var peak := maxf(gauges[1], maxf(gauges[2], maxf(gauges[3], gauges[4])))
		if peak > 1.0:
			if not _ring.visible:
				_ring.visible = true
			_ring_refresh_left -= p_game_delta
			if _ring_refresh_left <= 0.0:
				_ring_refresh_left = 1.0 / RING_REFRESH_HZ
				_ring.set_gauges(gauges)
			return
	if _ring.visible:
		_ring.visible = false


func ring_visible() -> bool:
	# v0.7.0 U8 观测口
	return _ring != null and _ring.visible


func ring_progress(p_element: int) -> float:
	# v0.7.0 U8 观测口：p_element ∈ GameConst.Element（FIR/ICE/LTG）→ 0~1
	return _ring.progress(p_element) if _ring != null else 0.0


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
	resist = [0.0, 0.0, 0.0, 0.0, 0.0]
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
	summon_spawner = null                       # v0.6.0：Boss 弹幕/召唤全量清零（含注入引用）
	is_summon = false                           # v0.7.0 U13/U5：标记清零
	gold_rush = false
	_boss_pattern = {}
	_boss_summons = {}
	_pattern_cd_left = 0.0
	_summon_cd_left = 0.0
	_spiral_offset = 0.0
	_spawn_wave = 1
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
	if _ring != null:
		_ring.visible = false                    # v0.7.0 U8：附着环清零
		_ring.set_gauges([0.0, 0.0, 0.0, 0.0, 0.0])
	_ring_refresh_left = 0.0
	_flash_left = 0.0
	_fade_left = 0.0
	modulate.a = 1.0
	_apply_flash(0.0)


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
	# 占位渲染同步：半径等比缩放 + 染色（按 tag/行为）
	if _sprite == null or data == null:
		return
	var r := hitbox_r
	var scale_f := r / (TEX_SIZE * 0.5)
	_sprite.scale = Vector2(scale_f, scale_f)
	_sprite.self_modulate = _body_color()
	if _hit_shape != null:
		var shape := CircleShape2D.new()
		shape.radius = r
		_hit_shape.shape = shape


func _body_color() -> Color:
	if is_boss():
		return BODY_COLORS["boss"]
	if is_elite():
		return BODY_COLORS["elite"]
	if behavior == GameConst.EnemyBehavior.RANGED:
		return BODY_COLORS["ranged"]
	return BODY_COLORS["default"]


func _apply_flash(p_amount: float) -> void:
	# 受击闪白（shader 占位：flash_amount 0→1 白色混合）
	if _material != null:
		_material.set_shader_parameter(&"flash_amount", p_amount)


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


# ── 爆虫警示圈（程序化占位绘制；半径 = VOLATILE_BLAST_RADIUS，A3 §2.2「警示圈」） ──
class FuseRing:
	extends Node2D

	var radius: float = 110.0
	var progress: float = 0.0                   # 引导进度 0~1（圈色渐亮渐红）

	func _draw() -> void:
		# 外圈描边 + 内域淡填充（进度越深越醒目；程序化占位美术）
		var edge := Color(1.0, 0.25, 0.2, 0.35 + 0.45 * progress)
		var fill := Color(1.0, 0.2, 0.15, 0.06 + 0.12 * progress)
		draw_circle(Vector2.ZERO, radius, fill)
		draw_arc(Vector2.ZERO, radius, 0.0, TAU, 48, edge, 3.0, true)


# ── v0.7.0 U8 附着环（FIR/ICE/LTG/WAT 各占 90° 扇区；程序化占位绘制；v1.2.0 4 扇区，A11 §2） ──
class ElementRing:
	extends Node2D

	const RING_COLORS: Array[Color] = [
		Color(1.0, 0.45, 0.2, 0.9),              # FIR 橙
		Color(0.4, 0.75, 1.0, 0.9),              # ICE 蓝
		Color(0.75, 0.6, 1.0, 0.9),              # LTG 紫
		Color(0.3, 0.75, 0.9, 0.9),              # WAT 水青（v1.2.0；= ELEMENT_COLORS[4] alpha 0.9 版）
	]
	const SECTOR := TAU / 4.0                    # 每元素 90° 扇区（v1.2.0：TAU/3 → TAU/4）
	const GAUGE_MAX := 100.0                     # ElementalState.GAUGE_MAX 同值（显示归一）

	var radius: float = 21.0
	var _gauges: Array[float] = [0.0, 0.0, 0.0, 0.0]  # FIR/ICE/LTG/WAT 快照（v1.2.0 4 槽）

	func set_gauges(p: Array[float]) -> void:
		# 快照（p 为 ElementalState 5 槽 gauges——取 [1..4]）+ 重绘
		if p.size() >= 5:
			_gauges = [p[1], p[2], p[3], p[4]]
		else:
			_gauges = [0.0, 0.0, 0.0, 0.0]
		queue_redraw()

	func progress(p_element: int) -> float:
		# 观测口：p_element ∈ GameConst.Element → 满槽比例 0~1
		var idx := clampi(p_element - 1, 0, 3)
		return clampf(_gauges[idx] / GAUGE_MAX, 0.0, 1.0)

	func _draw() -> void:
		# 每元素 90° 扇区弧：起点 = −PI/2 + idx×90°，扫角 = 90°×clamp(gauge/100)；
		# 颜色 FIR 橙 / ICE 蓝 / LTG 紫 / WAT 水青，线宽 3，alpha 0.9
		for i in range(4):
			var frac := clampf(_gauges[i] / GAUGE_MAX, 0.0, 1.0)
			if frac <= 0.0:
				continue
			var start := -PI / 2.0 + float(i) * SECTOR
			draw_arc(Vector2.ZERO, radius, start, start + SECTOR * frac, 24,
				RING_COLORS[i], 3.0, true)

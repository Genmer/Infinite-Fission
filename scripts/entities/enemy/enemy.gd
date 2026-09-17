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
var knock_vel: Vector2 = Vector2.ZERO         # 击退冲量速度（衰减式位移——R7 闪退根因修复）
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
var ext_slow_mult: float = 1.0                # 外部减速乘区（P2 毒云等直结算通道；与元素冰缓正交）
var ext_slow_left: float = 0.0                # 外部减速剩余 s（到期自动还原 1.0——免逐敌摘除）
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
var _fuse_ring: Telegraph.TelegraphCircle = null   # 警示圈（FuseRing 泛化件，ENEMY_BOSS_TELEGRAPH §1.4）

# ── Boss 弹幕施法状态机（ENEMY_BOSS_TELEGRAPH.md §1.4/§9 P1：ring/aimed_spread/spiral 三型） ──
# cast 三状态位：casting 由 _cast_idx >= 0 表达（cast_id/cast_left 口径）；前摇/冷却/跟射/螺旋
# 全走 game_delta 通道 + sf 门槛（冻结 sf=0：前摇停摆、冷却不走、不发弹）。追击中齐射——
# 不改 behavior、与 fire_range 语义解耦（roadmap 原案）。
var _barrage: Array = []                      # boss.barrage 快照（spawn 期折算存量 bullet_patterns）
var _barrage_cd: Array[float] = []            # 各技能冷却剩余（下标对齐 _barrage；开场错相）
var _cast_idx: int = -1                       # 施法中技能索引（-1 = 空闲）
var _cast_dir: Vector2 = Vector2.ZERO         # aimed_spread 起手锁定方向（前摇内不追踪）
var _cast_left: float = 0.0                   # 前摇剩余 s
var _cast_total: float = 0.4                  # 前摇总长（膨胀/闪红插值基准；三档 0.4/0.7/1.0）
var _pending_waves: Array[Dictionary] = []    # aimed_spread 多波跟射 {def, dir, left, timer}
var _emit_left: float = 0.0                   # spiral 持续喷剩余 s
var _emit_tick: float = 0.0                   # spiral 发射节拍器
var _emit_angle: float = 0.0                  # spiral 当前步进角（弧度）
var _emit_def: Dictionary = {}                # spiral 配置快照
var _cast_glow: float = 0.0                   # TelegraphSwell 强度 0~1（_tick_visual 消费）
var _cast_fan: Telegraph.TelegraphFan = null  # aimed_spread 扇形警示（紫，§1.2）
var _cast_line: Telegraph.TelegraphLine = null     # laser_sweep 直线警示带（紫，§1.2 B7）

# ── BLINK 闪现爆炸族（ENEMY_PATTERNS_BASIC §3.3，用户点名；R16 实装） ──
# 三态：0 巡航（0.85× 速追击）/ 1 施法读条（0.35s 闪紫收缩）/ 2 落地引信（0.8s 红圈进度环）。
# 落点 = 施法瞬间玩家位置快照（惩罚站桩；走位出圈即为解）。打断双路：冻结断读条、
# 击退断引信（爆虫口径）；计时全走 game_delta + sf 通道（顿帧/冻结自然停摆）。
var _blink_state: int = 0
var _blink_cd: float = 0.0                    # 闪现冷却剩余
var _blink_left: float = 0.0                  # 读条/引信共用倒计时
var _blink_target: Vector2 = Vector2.ZERO     # 施法瞬间玩家位置快照（落点真源）
var _blink_ring: Telegraph.TelegraphCircle = null   # 落点红圈（挂世界层——闪现后怪已位移）
var _blink_cd_max: float = 3.2                # ── special 参数快照（缺省 = §3.3 数值） ──
var _blink_prep: float = 0.35
var _blink_fuse: float = 0.8
var _blink_blast_r: float = 110.0
var _blink_range: float = 340.0

# ── Boss 三阶段 + B8 狂暴化（R18 P3；乘区缺省 1.0 = 未狂暴） ──
var _enrage_done: bool = false
var _enrage_cd_mult: float = 1.0              # 技能 cd ×0.8
var _enrage_rate_mult: float = 1.0            # spiral 喷发频率 ×1.3
var _enrage_speed_mult: float = 1.0           # 追击/弹速 ×1.2
var _enrage_tele_mult: float = 1.0            # 前摇 ×0.85（下限 0.34s）
var _red_tint_left: float = 0.0               # 全身红染剩余 s

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
var _hit_jolt_left: float = 0.0               # 受击位移颤动剩余（R19 打击质感，纯表现）
var _hit_jolt_dir: Vector2 = Vector2.ZERO     # 颤动方向（远离命中点）
var _face_state: int = 0                      # E4 脸状态（0 平静/1 惊恐/2 引爆）
var _anim_t: float = 0.0                      # 表现时钟（卫星公转/抖动相位）
var _boss_orbit: float = 0.0                  # 卫星公转角
var _boss_angry: bool = false                 # Boss 二阶段变脸贴图标志
var _spawn_left: float = 0.0                  # 出生弹入剩余（0→1 带 overshoot）
var _dash_state: int = 0                      # E2 冲刺状态机（0 巡航/1 蓄力/2 冲刺/3 回弹）
var _dash_left: float = 0.0                   # E2 当前阶段剩余
var _dash_dir: Vector2 = Vector2.ZERO         # E2 冲刺锁定方向（蓄力期末采样）

# 方向 C 元素状态表现层（用户反馈 2026-08-29「闪电/灼烧等特效」；只读 ElementalState，
# 零数值/碰撞副作用，_reset_state 全复位，共享贴图 + 无逐敌 shader）：
var _burn_flames: Array[Sprite2D] = []        # 点燃：顶部上飘火苗 ×4（循环重生）
var _burn_ember: Sprite2D = null              # 点燃：体周余烬光晕（本底下层呼吸，用户反馈「燃烧看不见」）
var _frost_shards: Array[Sprite2D] = []       # 寒滞/冻结：结霜菱形冰渣 ×3
var _frost_ring: Sprite2D = null              # 冻结冰壳描边圈（白环）
var _super_mist: Sprite2D = null              # 超导淡紫雾圈（低 alpha 底层氛围）
var _shock_arcs: Array[Line2D] = []           # 感电：双锯齿电弧（相位错开→半常亮感）
var _shock_arc_left: float = 0.0              # 电弧剩余显示时长（两弧共用相位）
var _shock_arc_cd: float = 0.0                # 下次电弧倒计时
var _arc_pattern_idx: int = 0                 # 电弧顶点池轮换游标
var _shock_bolt: Line2D = null                # 感电：垂直落雷（天降锯齿——去圆球化，用户反馈二轮）
var _shock_bolt_left: float = 0.0             # 落雷剩余显示时长
var _shock_bolt_cd: float = 0.0               # 下次落雷倒计时
var _shock_impact: Sprite2D = null            # 落雷命中点四角星闪
static var _arc_pattern_pool: Array[PackedVector2Array] = []   # 预生成电弧折线顶点池（全敌共享）
static var _bolt_pattern_pool: Array[PackedVector2Array] = []  # 预生成落雷折线顶点池（全敌共享）

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
const BOSS_VISUAL_MULT := 3.8                 # Boss 视觉放大倍率（≈1/4 屏，用户反馈三轮；碰撞盒不变）
const FINAL_BOSS_VISUAL_MULT := 5.0           # 最终 Boss 视觉放大倍率（≈1/3 屏，TAG_FINAL_BOSS）
const ELITE_VISUAL_MULT := 1.55               # 种族精英视觉放大倍率（「很大的」大怪，用户反馈三轮）
const WOBBLE_TIME := 0.22                     # 受击果冻抖动时长
const HOVER_AMP := 6.0                        # E5 悬浮幅度 px
const BURN_FLAME_COUNT := 4                   # 点燃火苗并发数（用户反馈「燃烧看不见」→ 加量放大）
const FROST_SHARD_COUNT := 3                  # 结霜冰渣数
const SHOCK_ARC_TIME := 0.13                  # 感电小电弧存活时长 s（0.08 太一闪而过，用户反馈敷衍）
const SHOCK_ARC_PERIOD := 0.26                # 电弧出现基础周期 s（双弧相位错开 ±0.25 随机）
const SHOCK_BOLT_TIME := 0.12                 # 垂直落雷存活时长 s
const SHOCK_BOLT_PERIOD := 0.9                # 落雷基础周期 s（±0.2 随机）
const GAUGE_DISCHARGE_FULL := 95.0            # 死亡释放满档判定（≥95% 槽 → 双残弧）
const BOG_SPLASH_RADIUS := 110.0              # 毒泡史莱姆死亡毒爆半径 px（E12 专属）
const BOG_SPLASH_RATIO := 0.6                 # 毒爆伤害 = contact_dmg × 0.6            # 死亡释放满档判定（≥95% 槽 → 双残弧）

# ── Boss 弹幕常量（ENEMY_BOSS_TELEGRAPH.md §1.4/附速查卡） ──────────
const SPIRAL_EMIT_TICK := 0.09                # spiral 每臂发弹间隔 s（B3）
const BOSS_BULLET_LIFETIME := 5.0             # 敌弹寿命 s（弹幕 hitbox 5px 同口径）
const BOSS_SWELL_MAX := 0.35                  # TelegraphSwell 膨胀上限（×1.35，二次缓动）

# ── BLINK 族常量（ENEMY_PATTERNS_BASIC §3.3；参数真源 = E24 special，缺省兜底） ──
const BLINK_OFFSET := 24.0                    # 落点随机偏移上限 px（防贴脸重合）
const BLINK_CRUISE_MULT := 0.85               # 巡航追速倍率（「追不太上」的错觉）
const BLINK_FREEZE_CD := 2.0                  # 读条被冻结打断后的施法冷却 s（§3.3 反制）
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
	_fuse_ring = Telegraph.TelegraphCircle.new()
	_fuse_ring.name = "FuseRing"
	_fuse_ring.radius = VOLATILE_BLAST_RADIUS
	_fuse_ring.color = Color(1.0, 0.36, 0.36)    # 红 = 爆炸（§1.2 色彩语义；FuseRing 原配色）
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
	if behavior != GameConst.EnemyBehavior.CHASE and behavior != GameConst.EnemyBehavior.RANGED \
			and behavior != GameConst.EnemyBehavior.BLINK:
		behavior = GameConst.EnemyBehavior.CHASE    # M1 范围外行为降级（DataValidator 已告警；BLINK R16 起支持）
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
	# Boss 弹幕快照 + 冷却开场错相（±50% 随机相位，防多 Boss/多技能同帧齐射）
	_barrage = _resolve_barrage(data)
	_barrage_cd.clear()
	for b_def: Dictionary in _barrage:
		_barrage_cd.append(maxf(float(b_def.get("cd", 5.0)), 0.5) * randf_range(0.5, 1.0))
	_reset_cast_state()
	# BLINK 参数快照 + 开场错相（防同帧齐闪）
	if behavior == GameConst.EnemyBehavior.BLINK:
		_blink_cd_max = maxf(float(data.special.get("blink_cd", 3.2)), 0.5)
		_blink_prep = maxf(float(data.special.get("blink_prep", 0.35)), 0.1)
		_blink_fuse = maxf(float(data.special.get("fuse", 0.8)), 0.1)
		_blink_blast_r = maxf(float(data.special.get("blast_r", 110.0)), 10.0)
		_blink_range = maxf(float(data.special.get("blink_range", 340.0)), 10.0)
		_blink_cd = _blink_cd_max * randf_range(0.5, 1.0)
		_blink_state = 0
		_blink_target = global_position
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
	_reset_status_fx()                        # 元素状态表现层复位（池复用安全）
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
	# 外部减速乘区（P2 毒云等直结算通道）：剩余窗推进，到期自动还原——与元素冰缓正交叠乘
	if ext_slow_left > 0.0:
		ext_slow_left = maxf(ext_slow_left - p_game_delta, 0.0)
		if ext_slow_left <= 0.0:
			ext_slow_mult = 1.0
		else:
			sf *= ext_slow_mult
	var player := _player()
	# 击退冲量衰减位移（R7：与追击位移叠加，指数衰减——9/s 阻尼约 0.11s 消散）
	if knock_vel != Vector2.ZERO:
		global_position += knock_vel * p_game_delta
		knock_vel = knock_vel.lerp(Vector2.ZERO, minf(9.0 * p_game_delta, 1.0))
	match behavior:
		GameConst.EnemyBehavior.CHASE:
			if player != null:
				if _kind == &"dart" or _kind == &"woodbird" or _kind == &"bogleaper":
					_tick_dart_chase(p_game_delta, player, sf)
				else:
					var dir := (player.global_position - global_position).normalized()
					var spd := speed * sf * _enrage_speed_mult   # R18 P3：狂暴追击提速
					if _fuse_armed:
						spd = VOLATILE_CHARGE_SPEED    # 警报后冲刺（A3 §2.2 E4 行；自爆冲刺不受寒滞减速修正口径）
					global_position += dir * spd * p_game_delta
				_tick_volatile_fuse(p_game_delta, player)
			if is_boss():
				_tick_boss_barrage(p_game_delta, player, sf)
		GameConst.EnemyBehavior.RANGED:
			_tick_ranged(p_game_delta, player, sf)
		GameConst.EnemyBehavior.BLINK:
			_tick_blink(p_game_delta, player, sf)
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
		# R19 打击质感：受击位移颤动（纯表现层——远离命中点 6px 微退，不改判定）
		_hit_jolt_left = 0.09
		_hit_jolt_dir = (global_position - p_result.pos).normalized() 			if global_position.distance_to(p_result.pos) > 1.0 else Vector2.ZERO
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
	# 近战/弹丸击退（A3 §3.9：打断自爆引导）。R7 重构（用户实测「全屏怪被打闪退」）：
	# ① 质量分级——Boss 完全免疫、精英 ×0.35（大怪不再被推飞）
	# ② 冲量速度衰减位移（原即时 += 位移一步跳半个屏 = 「闪退」观感根因）
	if is_boss():
		return
	# p_force 语义 = 总位移 px（设计直观：参数即击退距离）。冲量 = 位移 × 阻尼
	#（阻尼 9/s ⇒ 约 0.33s 内滑完 95%，滑行观感而非闪退）
	var scaled := p_force * (0.35 if (tags & GameConst.TAG_ELITE) != 0 else 1.0)
	knock_vel += scaled * 9.0
	if _fuse_armed:
		_cancel_fuse()
	if _blink_state == 2:
		_cancel_blink()                          # BLINK 引信期被击退打断（§3.3 爆虫口径）
	if scaled.length() >= 100.0:
		EventBus.emit_knockback_hit(global_position)   # 击退小字（强击退才提示）


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
	# R19 打击质感：死亡弹爆（白环扩散 + 四向碎屑，0.2s 自清——击杀瞬间重量感）
	if get_parent() != null and clampi(int(Meta.settings("fx_quality")), 0, 2) > 0:
		var pop := DeathPop.new()
		pop.name = "DeathPop"
		pop.position = global_position
		get_parent().add_child(pop)
	_death_poison_splash()
	_death_element_discharge()
	EventBus.emit_enemy_killed(self)


func _death_poison_splash() -> void:
	# 毒泡史莱姆（E12）死亡毒爆（用户反馈「沼泽怪物毒相关」）：半径 110 内玩家吃
	# contact_dmg × 60% + 绿色毒环残效（一次性表现件挂父层自消——死亡瞬发低频可接受）
	if data == null or not String(data.id).begins_with("E12"):
		return
	var player := _player()
	if player != null and is_instance_valid(player) \
			and global_position.distance_to(player.global_position) <= BOG_SPLASH_RADIUS:
		(player as Player).take_contact_damage(contact_dmg * BOG_SPLASH_RATIO)
	var splash := PoisonSplash.new()
	splash.position = global_position
	splash.radius = BOG_SPLASH_RADIUS * 0.7
	get_parent().add_child(splash)


func _death_element_discharge() -> void:
	# 死亡元素释放（用户反馈「后期元素不触发/至少没显示」：高 DPS 下怪 1~2 击死、计量槽
	# 永远攒不满 → 槽内残留元素在死亡瞬间可见化。纯表现层：复用既有广播通道，零结算副作用）
	if elemental == null:
		return
	var pos := global_position
	if elemental.burn_timer > 0.0:
		EventBus.emit_elemental_dot_fired(pos)    # 燃尽余烬：橙光晕 + 火星（DOT 跳伤同款表现）
	if elemental.freeze_timer > 0.0 or elemental.chill_timer > 0.0 \
			or elemental.vuln_timer > 0.0:
		EventBus.emit_bullet_nullified(pos)       # 冰霜碎裂：青色涟漪（消弹同款表现通道）
	var ltg: float = elemental.gauges[GameConst.Element.LTG]
	if ltg >= 60.0:
		# 感电残留电弧（≥60% 槽位；就近乱窜的放电残弧——表现层专用广播，无连锁结算）
		var hops := 2 if ltg >= GAUGE_DISCHARGE_FULL else 1
		for i in range(hops):
			var off := Vector2(randf_range(-95.0, 95.0), randf_range(-75.0, 75.0))
			EventBus.emit_chain_lightning(pos, pos + off)


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


# ── BLINK 闪现爆炸族（ENEMY_PATTERNS_BASIC §3.3） ────────────────────
func _tick_blink(p_dt: float, p_player: Node2D, p_sf: float) -> void:
	# 惩罚站桩：闪现目标 = 施法瞬间玩家位置快照，落点红圈给足走位窗（走位永远有解）。
	if p_player == null:
		return
	match _blink_state:
		0:
			# 巡航：0.85× 速追击（吃 sf 减速）+ 冷却推进
			var dir := (p_player.global_position - global_position).normalized()
			global_position += dir * speed * BLINK_CRUISE_MULT * p_sf * p_dt
			_blink_cd -= p_dt
			if _blink_cd <= 0.0 \
					and global_position.distance_to(p_player.global_position) <= _blink_range:
				_blink_target = p_player.global_position      # 快照！落点=玩家当前位置
				_blink_state = 1
				_blink_left = _blink_prep
		1:
			# 施法读条：闪紫收缩（表现层 &"rift" 分支）；冻结在 CHARGING 态 = 打断施法
			if p_sf <= 0.0:
				_cancel_blink(BLINK_FREEZE_CD)
				return
			_blink_left -= p_dt
			if _blink_left <= 0.0:
				_blink_teleport()
		2:
			# 落地引信：红圈进度环推进；冻结仅停摆（引信期唯一打断 = 击退，knockback 入口）
			if p_sf <= 0.0:
				return
			_blink_left -= p_dt
			if _blink_ring != null and is_instance_valid(_blink_ring):
				_blink_ring.progress = 1.0 - clampf(_blink_left / _blink_fuse, 0.0, 1.0)
				_blink_ring.queue_redraw()
			if _blink_left <= 0.0:
				_blink_explode(p_player)


func _blink_teleport() -> void:
	# 落点 = 快照 ±24px 随机偏移（防贴脸重合），钳屏内；红圈挂世界层钉死落点
	var off := Vector2(randf_range(-BLINK_OFFSET, BLINK_OFFSET),
		randf_range(-BLINK_OFFSET, BLINK_OFFSET))
	var size := Vector2(720.0, 1280.0)
	if GameConfig.balance != null:
		size = Vector2(GameConfig.balance.res_logic)
	global_position = (_blink_target + off).clamp(
		Vector2.ONE * hitbox_r, size - Vector2.ONE * hitbox_r)
	_blink_state = 2
	_blink_left = _blink_fuse
	_blink_ring = Telegraph.TelegraphCircle.new()
	_blink_ring.name = "BlinkRing"
	_blink_ring.radius = _blink_blast_r
	_blink_ring.color = Color(1.0, 0.36, 0.36)    # 红 = 爆炸/定点 AOE（§1.2 语义）
	_blink_ring.position = _blink_target
	_blink_ring.progress = 0.0
	get_parent().add_child(_blink_ring)


func _blink_explode(p_player: Node2D) -> void:
	# 引爆：半径内玩家吃 contact_dmg（30% 档 = dmg_base 波次成长值，E4 口径）；本体死亡
	_clear_blink_ring()
	# 爆炸环特效（复用 kill_blast 表现通道：橙红环+闪光，纯表现无结算）
	EventBus.emit_kill_blast(global_position, _blink_blast_r)
	if p_player != null and is_instance_valid(p_player) \
			and global_position.distance_to(p_player.global_position) <= _blink_blast_r:
		(p_player as Player).take_contact_damage(contact_dmg)
	hp = 0.0
	_on_died()


func _cancel_blink(p_cd: float = -1.0) -> void:
	# 打断统一入口：冻结断读条 / 击退断引信（§3.3 反制双路）→ 回巡航；p_cd ≥0 时重置施法冷却
	_blink_state = 0
	_blink_left = 0.0
	if p_cd >= 0.0:
		_blink_cd = p_cd
	_clear_blink_ring()


func _clear_blink_ring() -> void:
	if _blink_ring != null and is_instance_valid(_blink_ring):
		_blink_ring.queue_free()
	_blink_ring = null


func blink_state() -> int:
	# 测试/遥测观测口（0 巡航 / 1 读条 / 2 引信）
	return _blink_state


func blink_target() -> Vector2:
	return _blink_target


func _check_boss_phase() -> void:
	# Boss 阶段机（ENEMY_BOSS_TELEGRAPH §3/§4，R18 P3 三段化）：
	# phase2 = HP ≤ phase2_hp（缺省 0.6，E6 兼容 0.5）/ phase3 = HP ≤ phase3_hp（0.3）。
	# 切段：全抗 +phase2_resist、清当前施法、技能 cd 全部重置 max(cd×0.5, 1.5)（防无缝连放）。
	# phase3 入段 = B8 狂暴化（数据 enrage 在册时，一次性锁存）。
	if not is_boss() or data == null or boss_phase >= int(data.boss.get("phases", 2)):
		return
	var ratio := hp / maxf(max_hp, 1.0)
	var phases := int(data.boss.get("phases", 2))
	if phases >= 3 and boss_phase < 3 and ratio <= float(data.boss.get("phase3_hp", 0.3)):
		_enter_boss_phase(3)
	elif boss_phase < 2 and ratio <= float(data.boss.get("phase2_hp", 0.6)):
		_enter_boss_phase(2)


func _enter_boss_phase(p_phase: int) -> void:
	boss_phase = p_phase
	if p_phase == 2:
		# 全抗 +phase2_resist 仅 P2 一次（§3 阶段表：P3 狂暴期不再加抗）
		var p2 := float(data.boss.get("phase2_resist", 0.0))
		if p2 > 0.0:
			for i in range(resist.size()):
				resist[i] = minf(resist[i] + p2, 0.8)
	# 阶段切换节奏（§3）：清当前 cast + 全技能 cd 重置 max(cd×0.5, 1.5)，防切段无缝连放
	_cast_idx = -1
	_cast_left = 0.0
	if _cast_fan != null:
		_cast_fan.visible = false
	if _cast_line != null:
		_cast_line.visible = false
	for j in range(_barrage_cd.size()):
		_barrage_cd[j] = maxf(float(_barrage[j].get("cd", 5.0)) * 0.5, 1.5)
	if p_phase >= 3 and not _enrage_done and data.boss.has("enrage"):
		_enter_enrage()


func _enter_enrage() -> void:
	# B8 狂暴化（一次性锁存 _enrage_done——防回血词缀循环跨阈值重复触发）：
	# 怒相变脸（_tick_boss 既有）+ 全身红染 2s + 横幅广播 + 全数值放大
	var cfg: Dictionary = data.boss.get("enrage", {})
	_enrage_done = true
	_enrage_cd_mult = float(cfg.get("cd_mult", 0.8))
	_enrage_rate_mult = float(cfg.get("rate_mult", 1.3))
	_enrage_speed_mult = float(cfg.get("speed_mult", 1.2))
	_enrage_tele_mult = maxf(float(cfg.get("tele_mult", 0.85)), 0.34)
	_red_tint_left = 2.0
	EventBus.emit_mechanics_intro("⚠ %s 狂暴化！" % String(data.display_name))


# ── Boss 弹幕技能机（ENEMY_BOSS_TELEGRAPH.md §1.4/§2/§9 P1） ─────────
func _resolve_barrage(p_data: EnemyData) -> Array:
	# boss.barrage 直取；存量 bullet_patterns 读入时折算（§4 迁移规则：pattern
	# fan→aimed_spread / ring→ring / spiral→spiral，interval_s→cd，telegraph 默认 swell 0.4）
	var barr: Array = []
	var raw: Variant = p_data.boss.get("barrage", null)
	if raw is Array:
		for entry: Variant in raw:
			if entry is Dictionary and not entry.is_empty():
				barr.append(entry)
		return barr
	var legacy: Variant = p_data.boss.get("bullet_patterns", null)
	if legacy is Dictionary and not legacy.is_empty():
		var pattern := String(legacy.get("pattern", "ring"))
		barr.append({
			"type": "aimed_spread" if pattern == "fan" else pattern,
			"phase": 1,
			"cd": maxf(float(legacy.get("interval_s", 4.5)), 0.5),
			"telegraph": "swell", "telegraph_s": 0.4,
			"count": int(legacy.get("count", 12)),
			"speed": 200.0,
			"speed_mult_phase2": float(legacy.get("speed_mult_phase2", 1.0)),
			"dmg": float(legacy.get("dmg", 7.0)),
		})
	return barr


func _tick_boss_barrage(p_dt: float, p_player: Node2D, p_sf: float) -> void:
	# Boss 弹幕技能机：追击中齐射。冻结（sf=0）全停摆——前摇不推进/冷却不走/跟射与螺旋暂停；
	# 顿帧走 game_delta 通道天然同口径（§1.3）。
	if _barrage.is_empty() or projectile_pool == null or p_player == null:
		return
	if p_sf <= 0.0:
		return
	# 跟射波（aimed_spread waves>1：方向已锁定，波间隔 wave_gap_s）
	var wi := 0
	while wi < _pending_waves.size():
		var wave: Dictionary = _pending_waves[wi]
		wave["timer"] = float(wave["timer"]) - p_dt
		if float(wave["timer"]) <= 0.0:
			_fire_spread(wave["def"], wave["dir"])
			wave["left"] = int(wave["left"]) - 1
			wave["timer"] = float(wave["def"].get("wave_gap_s", 0.25))
			if int(wave["left"]) <= 0:
				_pending_waves.remove_at(wi)
				continue
		wi += 1
	# spiral 持续喷发（前摇结束后的发射期，Boss 仍追击——「追击中齐射」）
	if _emit_left > 0.0:
		_tick_spiral_emit(p_dt)
		return
	# 施法前摇：推进 → 归零结算（结算必须由预警完成触发——§1.1 铁律）
	if _cast_idx >= 0:
		_cast_left -= p_dt
		_cast_glow = clampf(1.0 - _cast_left / maxf(_cast_total, 0.01), 0.0, 1.0)
		if _cast_fan != null and _cast_fan.visible:
			_cast_fan.progress = _cast_glow
			_cast_fan.queue_redraw()
		if _cast_line != null and _cast_line.visible:
			_cast_line.progress = _cast_glow
			_cast_line.queue_redraw()
		if _cast_left <= 0.0:
			_release_cast(p_player)
		return
	_cast_glow = maxf(_cast_glow - p_dt * 4.0, 0.0)   # 释放后闪红余晖快速消退
	# 冷却推进 + 技能挑选（就绪取配置序首个——cd 定值不随机化，Archero 固定循环 §8.4）
	for j in range(_barrage_cd.size()):
		_barrage_cd[j] -= p_dt
	for j in range(_barrage.size()):
		if int(_barrage[j].get("phase", 1)) > boss_phase:
			continue
		if _barrage_cd[j] > 0.0:
			continue
		_begin_cast(j, p_player)
		return


func _begin_cast(p_idx: int, p_player: Node2D) -> void:
	_cast_idx = p_idx
	_cast_total = maxf(float(_barrage[p_idx].get("telegraph_s", 0.4))
		* _enrage_tele_mult, 0.34)              # 狂暴前摇 ×0.85（下限 0.34s §1.3）
	_cast_left = _cast_total
	_cast_glow = 0.0
	# aimed_spread：扇形警示起手即锁定玩家当前位置（§1.2 同形同色：警示即弹道，
	# 前摇内不追踪——玩家读扇走位即为解；B2「前摇内不追踪」口径）
	if String(_barrage[p_idx].get("type", "ring")) == "aimed_spread":
		_cast_dir = (p_player.global_position - global_position).normalized()
		if _cast_dir == Vector2.ZERO:
			_cast_dir = Vector2.RIGHT
		if _cast_fan == null:
			_cast_fan = Telegraph.TelegraphFan.new()
			_cast_fan.name = "CastFan"
			add_child(_cast_fan)
		_cast_fan.setup_dir(_cast_dir)
		_cast_fan.radius = maxf(150.0, float(_barrage[p_idx].get("speed", 300.0)) * _cast_total * 1.15)
		_cast_fan.arc_deg = float(_barrage[p_idx].get("arc_deg", 44.0))
		_cast_fan.progress = 0.0
		_cast_fan.visible = true
	# laser_sweep：紫色直线警示带（B7 处决技——起角锁定，带内不追踪）
	elif String(_barrage[p_idx].get("type", "ring")) == "laser_sweep":
		_cast_dir = (p_player.global_position - global_position).normalized()
		if _cast_dir == Vector2.ZERO:
			_cast_dir = Vector2.RIGHT
		if _cast_line == null:
			_cast_line = Telegraph.TelegraphLine.new()
			_cast_line.name = "CastLine"
			add_child(_cast_line)
		_cast_line.setup_dir(_cast_dir)
		_cast_line.width = float(_barrage[p_idx].get("width_px", 26.0))
		_cast_line.progress = 0.0
		_cast_line.visible = true


func _release_cast(p_player: Node2D) -> void:
	# 前摇完成结算（Telegraph.finished 口径）：按型分发 → 重置该技能 cd → 收警示件
	var def: Dictionary = _barrage[_cast_idx]
	var type := String(def.get("type", "ring"))
	match type:
		"ring":
			_fire_ring(def)
		"aimed_spread":
			_fire_spread(def, _cast_dir)
			var waves := int(def.get("waves", 1))
			if waves > 1:
				_pending_waves.append({"def": def, "dir": _cast_dir,
					"left": waves - 1, "timer": float(def.get("wave_gap_s", 0.25))})
		"spiral":
			_emit_def = def
			_emit_left = float(def.get("emit_s", 2.4))
			_emit_tick = 0.0
			_emit_angle = (p_player.global_position - global_position).angle()
		"mine":
			_spawn_mine_field(def, p_player)        # B6 荆棘雷区（R18 P2：flavor 皮）
		"laser_sweep":
			_spawn_laser_sweep(def)                 # B7 湮灭扫线（R18 P2：起角已锁定）
		_:
			pass
	_barrage_cd[_cast_idx] = maxf(float(def.get("cd", 5.0)) * _enrage_cd_mult, 0.5)
	_cast_idx = -1
	_cast_left = 0.0
	if _cast_fan != null:
		_cast_fan.visible = false
	if _cast_line != null:
		_cast_line.visible = false


func _fire_ring(def: Dictionary) -> void:
	# B1 聚能环爆：360° 均匀环，相位随机防齐刷（ENEMY_PATTERNS_BASIC §3.2 ring 口径）
	var count := _phase_count(def)
	var speed := _phase_speed(def)
	var dmg := float(def.get("dmg", 7.0))
	var phase0 := randf() * TAU
	for k in range(count):
		_spawn_boss_bullet(Vector2.from_angle(phase0 + TAU * float(k) / float(count)), speed, dmg)


func _fire_spread(def: Dictionary, p_dir: Vector2) -> void:
	# B2 锁定扇射：扇心=锁定方向（起手快照），等角展开
	var count := int(def.get("count", 5))
	var arc := deg_to_rad(float(def.get("arc_deg", 44.0)))
	var speed := _phase_speed(def)
	var dmg := float(def.get("dmg", 13.0))
	for k in range(count):
		var t := 0.0 if count <= 1 else float(k) / float(count - 1) - 0.5
		_spawn_boss_bullet(p_dir.rotated(t * arc), speed, dmg)


func _tick_spiral_emit(p_dt: float) -> void:
	# B3 旋转火舌：双臂（数据可配）每 SPIRAL_EMIT_TICK 每臂 1 发，步进 step_deg
	_emit_left -= p_dt
	_emit_tick -= p_dt
	var arms := maxi(int(_emit_def.get("arms", 2)), 1)
	var speed := _phase_speed(_emit_def)
	var dmg := float(_emit_def.get("dmg", 6.0))
	var step := deg_to_rad(float(_emit_def.get("step_deg", 17.0)))
	while _emit_tick <= 0.0 and _emit_left > 0.0:
		_emit_tick += SPIRAL_EMIT_TICK / _enrage_rate_mult
		for a in range(arms):
			_spawn_boss_bullet(Vector2.from_angle(_emit_angle + TAU * float(a) / float(arms)), speed, dmg)
		_emit_angle += step
	if _emit_left <= 0.0:
		_emit_left = 0.0


func _phase_count(def: Dictionary) -> int:
	# 弹数（count_phase2 二阶段增密覆写——B1「P3 才经历密度放大」前置口径）
	if boss_phase >= 2 and def.has("count_phase2"):
		return int(def["count_phase2"])
	return int(def.get("count", 12))


func _phase_speed(def: Dictionary) -> float:
	# 弹速（speed_mult_phase2 存量口径延续）
	var spd := float(def.get("speed", 200.0))
	if boss_phase >= 2:
		spd *= float(def.get("speed_mult_phase2", 1.0))
	return spd * _enrage_speed_mult


func _spawn_boss_bullet(p_dir: Vector2, p_speed: float, p_dmg: float) -> void:
	# 敌弹统一通道（§1.4）：池化 acquire + team=1；出弹位=身缘（视觉放大 3.8× 不穿模）
	var bullet := projectile_pool.acquire() as BallisticProjectile
	if bullet == null:
		return
	bullet.pool = projectile_pool
	bullet.position = global_position + p_dir * (hitbox_r * 2.6 + 6.0)
	bullet.spawn({
		"velocity": p_dir * p_speed,
		"lifetime": BOSS_BULLET_LIFETIME,
		"pierce": 1,
		"bounces": 0,
		"hitbox_radius": 5.0,
		"team": 1,
		"panel_snapshot": {"base_atk": p_dmg},
	})


func _spawn_mine_field(def: Dictionary, p_player: Node2D) -> void:
	# B6 荆棘雷区（R18 P2）：混合布点（Boss 环带 + 玩家预测位）——每颗落点先红圈缩圈
	# telegraph_s → 落地 arm_s 激活 → 触发半径内/寿命到期爆炸；flavor 皮：
	# frost=冰锁圈（拖动减速）/ venom=毒潭（站场 DoT）/ fire=火焰地（站场 DoT）
	var count := _phase_count(def)
	var telegraph_s := float(def.get("telegraph_s", 0.7))
	var size := Vector2(720.0, 1280.0)
	if GameConfig.balance != null:
		size = Vector2(GameConfig.balance.res_logic)
	for k in range(count):
		var pos := Vector2.ZERO
		if k % 2 == 0:
			# 奇数位：玩家当前位置附近（预测位混合，±140px）
			pos = p_player.global_position \
				+ Vector2(randf_range(-140.0, 140.0), randf_range(-140.0, 140.0))
		else:
			# 偶数位：Boss 环带（半径 160~300 随机）
			pos = global_position + Vector2.from_angle(randf() * TAU) \
				* randf_range(160.0, 300.0)
		pos = pos.clamp(Vector2.ONE * 40.0, size - Vector2.ONE * 40.0)
		var mine := BossMine.new()
		mine.name = "BossMine%d" % k
		mine.position = pos
		mine.trigger_r = float(def.get("trigger_r", 42.0))
		mine.blast_r = float(def.get("blast_r", 90.0))
		mine.dmg = float(def.get("dmg", 21.0))
		mine.life_s = float(def.get("life_s", 8.0))
		mine.telegraph_s = telegraph_s
		mine.arm_s = float(def.get("arm_s", 0.8))
		mine.flavor = String(def.get("flavor", "thorn"))
		mine.host = self
		if def.has("poison_pool"):
			mine.pool_cfg = def["poison_pool"]
			mine.pool_kind = "venom"
		elif def.has("slow_pool"):
			mine.pool_cfg = def["slow_pool"]
			mine.pool_kind = "frost"
		get_parent().add_child(mine)


func _spawn_laser_sweep(def: Dictionary) -> void:
	# B7 湮灭扫线（R18 P2）：起角已在前摇锁定（_cast_dir）；束锚定施法瞬间 Boss 位置，
	# 扫 arc_deg / sweep_s，线宽 width_px，命中 0.6s 一次（处决级 50% 档，不可打断）
	var sweep := BossSweep.new()
	sweep.name = "BossSweep"
	sweep.position = global_position
	sweep.base_angle = _cast_dir.angle()
	sweep.arc_deg = float(def.get("arc_deg", 100.0))
	sweep.sweep_s = float(def.get("sweep_s", 1.6))
	sweep.width_px = float(def.get("width_px", 26.0))
	sweep.dmg = float(def.get("dmg", 30.0))
	sweep.flavor = String(def.get("flavor", "vine"))
	sweep.host = self
	if def.has("poison_pool"):
		sweep.pool_cfg = def["poison_pool"]
		sweep.pool_kind = "venom"
	get_parent().add_child(sweep)


func _reset_cast_state() -> void:
	# 池归还/spawn 双路复位（E-04/E-05 清零契约：施法位/计时/跟射/螺旋/表现件全清）
	_cast_idx = -1
	_cast_dir = Vector2.ZERO
	_cast_left = 0.0
	_cast_total = 0.4
	_pending_waves.clear()
	_emit_left = 0.0
	_emit_tick = 0.0
	_emit_angle = 0.0
	_emit_def = {}
	_cast_glow = 0.0
	if _cast_fan != null:
		_cast_fan.visible = false
	if _cast_line != null:
		_cast_line.visible = false


func _reset_state() -> void:
	knock_vel = Vector2.ZERO                     # R7：击退冲量归还清零
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
	ext_slow_mult = 1.0                       # 外部减速复位（P2：池归还清零契约同口径）
	ext_slow_left = 0.0
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
	_reset_cast_state()                             # Boss 弹幕施法态清零（E-04/E-05 契约）
	_barrage = []
	_barrage_cd.clear()
	_blink_state = 0                                # BLINK 三态清零 + 落点圈回收（池复用安全）
	_blink_cd = 0.0
	_blink_left = 0.0
	_blink_target = Vector2.ZERO
	_clear_blink_ring()
	_enrage_done = false
	_enrage_cd_mult = 1.0
	_enrage_rate_mult = 1.0
	_enrage_speed_mult = 1.0
	_enrage_tele_mult = 1.0
	_red_tint_left = 0.0
	_flash_left = 0.0
	_fade_left = 0.0
	_wobble_left = 0.0
	_hit_jolt_left = 0.0
	_hit_jolt_dir = Vector2.ZERO
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
	_reset_status_fx()


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
		var boss_mult := FINAL_BOSS_VISUAL_MULT 			if (tags & GameConst.TAG_FINAL_BOSS) != 0 else BOSS_VISUAL_MULT
		_base_scale = r * boss_mult / BOSS_TEX_R
		_sprite.texture = TextureFactory.enemy_tex(_kind, false)
	elif is_elite():
		_base_scale = r * ELITE_VISUAL_MULT / (TEX_SIZE * 0.5)
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
	# boss1~7 七套剪影互异的大型聚合体（boss4~7 = 每图专属 Boss，P1 2026-08-31）；
	# E5 精英 = 金腹徽基底（引擎侧加皇冠/悬浮/微光）
	if is_boss() and data != null:
		var bid := String(data.id)
		if bid.begins_with("E6_boss2"):
			return &"boss2"
		if bid.begins_with("E6_boss3"):
			return &"boss3"
		if bid.begins_with("E17"):
			return &"boss4"
		if bid.begins_with("E18"):
			return &"boss5"
		if bid.begins_with("E19"):
			return &"boss6"
		if bid.begins_with("E20"):
			return &"boss7"
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
	if sid.begins_with("E7"):
		return &"spitter"
	if sid.begins_with("E8"):
		return &"imp"
	if sid.begins_with("E9"):
		return &"frostling"
	if sid.begins_with("E10"):
		return &"woodbird"
	if sid.begins_with("E11"):
		return &"aquasquirt"
	if sid.begins_with("E12"):
		return &"bogslime"
	if sid.begins_with("E13"):
		return &"bogspitter"
	if sid.begins_with("E14"):
		return &"boguard"
	if sid.begins_with("E15"):
		return &"bogleaper"
	if sid.begins_with("E16"):
		return &"marshmaw"
	if sid.begins_with("E24"):
		return &"rift"
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
	# Boss 漂浮小卫星球（boss1=2 颗 / 其余 Boss=3 颗；白珠公转，运行期只更新位置）
	# 非 Boss 复用时仅隐藏（节点随池实例存活，跨复用零实例化）
	var want := String(p_kind).begins_with("boss")
	var count := 2 if _kind == &"boss1" else 3
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
		&"rift":
			# E24 裂隙爆魔：漂浮微旋 + 呼吸；读条期收缩（TelegraphSwell 变体，§3.3）
			rot = 0.05 * sin(_anim_t * 3.4 + float(uid % 32))
			var breathe_r := 1.0 + 0.03 * sin(_anim_t * 5.2 + float(uid % 32))
			if _blink_state == 1:
				var prog_r := 1.0 - clampf(_blink_left / maxf(_blink_prep, 0.01), 0.0, 1.0)
				breathe_r *= 1.0 - 0.25 * prog_r      # 读条收缩
			sx = _base_scale * breathe_r
			sy = _base_scale * breathe_r
		&"elite":
			var hover := (1.0 - cos(_anim_t * 2.2)) * 0.5
			off.y = -hover * HOVER_AMP
			var breathe_e := 1.0 + 0.03 * sin(_anim_t * 4.6 + float(uid % 32))
			sx = _base_scale * breathe_e
			sy = _base_scale * (2.0 - breathe_e)
			_tick_elite_extras(hover)
		&"boss1", &"boss2", &"boss3", &"boss4", &"boss5", &"boss6", &"boss7":
			off.y = sin(_anim_t * 1.6) * 4.0 * _base_scale
			_tick_boss(p_game_delta)
			if _cast_glow > 0.0:
				# TelegraphSwell（§1.2）：本体膨胀 + 闪红（二次缓动语言，×1.35 上限）
				var swell := 1.0 + BOSS_SWELL_MAX * _cast_glow * _cast_glow
				sx *= swell
				sy *= swell
		_:
			# grunt（E1）：idle 摇摆 + 呼吸（果冻感基调）
			rot = 0.06 * sin(_anim_t * 3.1 + float(uid % 32))
			var breathe_g := 1.0 + 0.035 * sin(_anim_t * 5.0 + float(uid % 32))
			sx = _base_scale * breathe_g
			sy = _base_scale * (2.0 - breathe_g)
	# R19 受击位移颤动（纯表现：命中方向反向微退）
	if _hit_jolt_left > 0.0:
		_hit_jolt_left = maxf(_hit_jolt_left - p_game_delta, 0.0)
		off += _hit_jolt_dir * 6.0 * (_hit_jolt_left / 0.09)
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
	_tick_status_fx(p_game_delta)
	# TelegraphSwell 闪红层（叠加在状态染色之上——闪红=即将齐射，§1.2 语义）
	if _cast_glow > 0.0 and _sprite != null:
		_sprite.self_modulate = _sprite.self_modulate.lerp(Color(1.0, 0.36, 0.36), _cast_glow * 0.85)
	# BLINK 读条闪紫层（§3.3 出手前摇：本体闪紫 + 收缩）
	if _blink_state == 1 and _sprite != null:
		var blink_glow := 1.0 - clampf(_blink_left / maxf(_blink_prep, 0.01), 0.0, 1.0)
		_sprite.self_modulate = _sprite.self_modulate.lerp(Color(0.7, 0.5, 1.0), blink_glow * 0.8)
	# B8 狂暴红染（入场 2s 强红染衰减至常驻微红——一眼狂暴）
	if _enrage_done and _sprite != null:
		_red_tint_left = maxf(_red_tint_left - p_game_delta, 0.0)
		var rage_a := 0.45 if _red_tint_left > 0.0 else 0.18
		_sprite.self_modulate = _sprite.self_modulate.lerp(Color(1.0, 0.25, 0.25), rage_a)


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


# ── 元素状态表现层（方向 C：点燃/寒滞/冻结/感电/超导可视化；用户反馈 2026-08-29） ──
# 只读 ElementalState（tick ⑤ 阶段已先行更新），game_delta 通道（顿帧/暂停自然冻结）。
# 节点惰性创建（卫星球同模式）、随池实例存活；贴图 TextureFactory 惰性缓存共享；
# 染色走 self_modulate（无逐敌 shader）；小电弧折线用预生成顶点池轮换（零逐帧随机顶点生成）。
func _tick_status_fx(p_game_delta: float) -> void:
	if elemental == null:
		return
	var burning: bool = elemental.burn_timer > 0.0
	var chilled: bool = elemental.chill_timer > 0.0
	var frozen: bool = elemental.freeze_timer > 0.0
	var shocked: bool = elemental.gauges[GameConst.Element.LTG] > 0.0
	var supercon: bool = elemental.superconduct_active
	_tick_burn_flames(p_game_delta, burning)
	_tick_frost(chilled, frozen)
	_tick_shock_fx(p_game_delta, shocked)
	_tick_super_fx(supercon)
	_tick_status_tint(burning, chilled, frozen, shocked)


func _ensure_super_mist() -> void:
	# 超导：淡紫雾圈（低 alpha 氛围底层；电场感由高频电弧承担——去环去「球」，用户反馈二轮）
	if _super_mist == null:
		_super_mist = Sprite2D.new()
		_super_mist.name = "SuperMist"
		_super_mist.texture = TextureFactory.soft_dot(64)
		_super_mist.modulate = Color(PopPalette.SHOCK.r, PopPalette.SHOCK.g,
			PopPalette.SHOCK.b, 0.3)
		add_child(_super_mist)


func _tick_super_fx(p_supercon: bool) -> void:
	# 超导表现：雾圈压暗到氛围级 + 电弧双倍频率（电场感，无圆环）
	if not p_supercon:
		if _super_mist != null:
			_super_mist.visible = false
		return
	_ensure_super_mist()
	_super_mist.visible = true
	_super_mist.position = Vector2.ZERO
	_super_mist.scale = Vector2.ONE * (hitbox_r * 3.0 / 64.0)
	_super_mist.modulate.a = 0.16 + 0.05 * sin(_anim_t * 3.1)
	if _shock_arc_cd > SHOCK_ARC_PERIOD * 0.5:
		_shock_arc_cd = SHOCK_ARC_PERIOD * 0.5    # 超导期电弧加倍频繁


func _tick_shock_fx(p_game_delta: float, p_shocked: bool) -> void:
	# 感电表现（用户反馈二轮「还是圆球」→ 彻底去环）：垂直落雷（天降锯齿 + 命中点
	# 四角星闪）周期打击 + 双体表电弧错相轮闪——全程「正被电」的读感
	if not p_shocked:
		for arc in _shock_arcs:
			arc.visible = false
		if _shock_bolt != null:
			_shock_bolt.visible = false
		if _shock_impact != null:
			_shock_impact.visible = false
		return
	# 双电弧：同一相位池错半周期（第二弧翻转朝向），覆盖感电全程 ~100% 可见
	if _shock_arcs.is_empty():
		for i in range(2):
			var arc := Line2D.new()
			arc.name = "ShockArc%d" % i
			arc.width = clampf(hitbox_r * 0.18, 3.0, 6.0)
			arc.default_color = PopPalette.SHOCK.lerp(Color.WHITE, 0.25 if i == 0 else 0.0)
			arc.joint_mode = Line2D.LINE_JOINT_ROUND
			arc.begin_cap_mode = Line2D.LINE_CAP_ROUND
			arc.end_cap_mode = Line2D.LINE_CAP_ROUND
			arc.visible = false
			add_child(arc)
			_shock_arcs.append(arc)
	if _shock_arc_left > 0.0:
		_shock_arc_left = maxf(_shock_arc_left - p_game_delta, 0.0)
		if _shock_arc_left <= 0.0:
			for arc in _shock_arcs:
				arc.visible = false
	_shock_arc_cd -= p_game_delta
	if _shock_arc_cd <= 0.0:
		_shock_arc_cd = SHOCK_ARC_PERIOD + randf() * 0.12
		var patterns := _get_arc_patterns()
		for i in range(_shock_arcs.size()):
			var arc := _shock_arcs[i]
			arc.points = patterns[_arc_pattern_idx % patterns.size()]
			_arc_pattern_idx += 1
			arc.rotation = randf() * TAU
			arc.scale = Vector2.ONE * hitbox_r * 1.35
			arc.visible = i == 0
		# 第二弧延迟半程点亮（错相闪烁）
		_shock_arcs[1].visible = false
		_shock_arc_left = SHOCK_ARC_TIME
	if _shock_arcs.size() > 1 and _shock_arc_left > 0.0 \
			and _shock_arc_left < SHOCK_ARC_TIME * 0.5:
		_shock_arcs[1].visible = true
	# 垂直落雷：顶部天降锯齿劈到本体 + 四角星爆闪（周期 ~0.9s，存活 0.12s）
	# R19 特效质量：低档关闭落雷（电弧已足够表意——群体感电期减负）
	if clampi(int(Meta.settings("fx_quality")), 0, 2) > 0:
		_tick_shock_bolt(p_game_delta)


func _tick_shock_bolt(p_game_delta: float) -> void:
	if _shock_bolt == null:
		_shock_bolt = Line2D.new()
		_shock_bolt.name = "ShockBolt"
		_shock_bolt.width = clampf(hitbox_r * 0.2, 3.5, 6.5)
		_shock_bolt.default_color = PopPalette.SHOCK.lerp(Color.WHITE, 0.45)
		_shock_bolt.joint_mode = Line2D.LINE_JOINT_ROUND
		_shock_bolt.begin_cap_mode = Line2D.LINE_CAP_ROUND
		_shock_bolt.end_cap_mode = Line2D.LINE_CAP_ROUND
		_shock_bolt.visible = false
		add_child(_shock_bolt)
	if _shock_impact == null:
		_shock_impact = Sprite2D.new()
		_shock_impact.name = "ShockImpact"
		_shock_impact.texture = TextureFactory.star(48, Color.WHITE)
		_shock_impact.modulate = PopPalette.SHOCK.lerp(Color.WHITE, 0.7)
		_shock_impact.visible = false
		add_child(_shock_impact)
	if _shock_bolt_left > 0.0:
		_shock_bolt_left = maxf(_shock_bolt_left - p_game_delta, 0.0)
		if _shock_bolt_left <= 0.0:
			_shock_bolt.visible = false
			_shock_impact.visible = false
		else:
			_shock_impact.rotation += p_game_delta * 16.0
			_shock_impact.scale = Vector2.ONE * (hitbox_r * 0.09) \
				* (1.0 + _shock_bolt_left / SHOCK_BOLT_TIME)
			return
	_shock_bolt_cd -= p_game_delta
	if _shock_bolt_cd <= 0.0:
		_shock_bolt_cd = SHOCK_BOLT_PERIOD + randf() * 0.2
		var strike_h := hitbox_r * 4.5 + 60.0    # 雷云高度（屏上感）
		var pts := PackedVector2Array()
		var segs := 4
		for i in range(segs + 1):
			var t := float(i) / float(segs)
			var jit := 0.0 if i == 0 or i == segs \
				else randf_range(-1.0, 1.0) * strike_h * 0.09
			pts.append(Vector2(jit, -strike_h * (1.0 - t)))
		_shock_bolt.points = pts
		_shock_bolt.visible = true
		_shock_impact.visible = true
		_shock_impact.position = Vector2.ZERO
		_shock_impact.rotation = randf() * TAU
		_shock_impact.scale = Vector2.ONE * hitbox_r * 0.18
		_shock_bolt_left = SHOCK_BOLT_TIME


func _reset_status_fx() -> void:
	# spawn / 池归还双路复位（隐藏挂件 + 清计时 + 染色回白）
	_shock_arc_left = 0.0
	_shock_arc_cd = 0.0
	_arc_pattern_idx = 0
	_shock_bolt_left = 0.0
	_shock_bolt_cd = randf() * 0.3            # 复用错相（避免整波怪同帧落雷）
	for f in _burn_flames:
		f.visible = false
	for s in _frost_shards:
		s.visible = false
	if _frost_ring != null:
		_frost_ring.visible = false
	if _super_mist != null:
		_super_mist.visible = false
	for arc in _shock_arcs:
		arc.visible = false
	if _shock_bolt != null:
		_shock_bolt.visible = false
	if _shock_impact != null:
		_shock_impact.visible = false
	if _burn_ember != null:
		_burn_ember.visible = false
	if _sprite != null:
		_sprite.self_modulate = Color.WHITE


func _tick_burn_flames(p_game_delta: float, p_burning: bool) -> void:
	# 点燃：体周余烬光晕（本底下层呼吸）+ 顶部 4 粒放大火苗循环上飘（用户反馈
	# 「燃烧的特效没看见」→ 火苗 ×2.2 放大 + 常驻光晕，小体型敌也可读）
	if _burn_ember == null:
		_burn_ember = Sprite2D.new()
		_burn_ember.name = "BurnEmber"
		_burn_ember.texture = TextureFactory.soft_dot(64)
		_burn_ember.show_behind_parent = true     # 压到本体贴图下层（光晕不糊脸）
		_burn_ember.modulate = Color(PopPalette.ENEMY.r, PopPalette.ENEMY.g,
			PopPalette.ENEMY.b, 0.0)
		add_child(_burn_ember)
	_burn_ember.visible = p_burning
	if p_burning:
		_burn_ember.position = Vector2(0.0, hitbox_r * 0.12)
		_burn_ember.scale = Vector2.ONE * hitbox_r * 0.24 \
			* (1.0 + 0.1 * sin(_anim_t * 8.4))
		_burn_ember.modulate.a = 0.3 + 0.1 * sin(_anim_t * 7.2)
	# R19 特效质量：火苗数预算 高4/中2/低0（低档仅余烬光晕——成群点燃敌不再拖帧）
	var flame_budget: int = [0, 2, BURN_FLAME_COUNT][clampi(int(Meta.settings("fx_quality")), 0, 2)]
	if _burn_flames.is_empty():
		if not p_burning or flame_budget <= 0:
			return
		for i in range(flame_budget):
			var f := Sprite2D.new()
			f.name = "BurnFlame%d" % i
			f.texture = TextureFactory.flame_bit()
			add_child(f)
			_burn_flames.append(f)
	if not p_burning or flame_budget <= 0:
		for f in _burn_flames:
			f.visible = false
		return
	var base := hitbox_r * _base_scale
	for i in range(_burn_flames.size()):
		var f := _burn_flames[i]
		f.visible = true
		var cyc := fmod(_anim_t * 1.35 + float(i) * 0.37, 1.0)     # 0→1 生命周期相位
		var sway := sin(_anim_t * 7.0 + float(i) * 2.4) * base * 0.16
		f.position = Vector2((float(i) - 1.5) * base * 0.55 + sway,
			-hitbox_r * _base_scale * (0.7 + cyc * 0.95))
		f.rotation = sway * 0.08
		f.scale = Vector2.ONE * _base_scale * (1.25 + 1.05 * cyc)  # ×2.2 放大（原 0.58+0.5）
		f.modulate = Color(1.0, 1.0, 1.0, clampf(maxf(sin(cyc * PI) * 1.35, 0.4), 0.0, 1.0))
		# 白（贴图本色：橙外焰+亮黄内芯）→ 橙红渐深（自带饱和度，避免淡黄洗白）
		f.self_modulate = Color.WHITE.lerp(PopPalette.ENEMY, cyc * 0.7)


func _tick_frost(p_chilled: bool, p_frozen: bool) -> void:
	# 寒滞/冻结：本体结霜大冰晶（冻结更大更亮更密——用户反馈「冰冻没看见效果」×1.8 放大）
	# + 冻结期加厚冰壳描边圈 + 冰蓝强染色（_tick_status_tint）
	if _frost_shards.is_empty():
		if not p_chilled and not p_frozen:
			return
		for i in range(FROST_SHARD_COUNT):
			var s := Sprite2D.new()
			s.name = "FrostShard%d" % i
			s.texture = TextureFactory.ice_shard()
			add_child(s)
			_frost_shards.append(s)
	for i in range(_frost_shards.size()):
		var s := _frost_shards[i]
		s.visible = p_chilled or p_frozen
		if not s.visible:
			continue
		match i:
			0:
				s.position = Vector2(-0.62, -0.62) * hitbox_r
			1:
				s.position = Vector2(0.66, -0.36) * hitbox_r
			_:
				s.position = Vector2(0.05, 0.55) * hitbox_r
		s.rotation = 0.6 * float(i) + 0.16 * sin(_anim_t * 2.6 + float(i))
		s.scale = Vector2.ONE * _base_scale * (1.5 if p_frozen else 1.0)   # ×1.8 放大（原 0.78/0.55）
		s.self_modulate = Color(1.0, 1.0, 1.0, 1.0) if p_frozen \
			else Color(1.0, 1.0, 1.0, 0.9)
	if p_frozen:
		if _frost_ring == null:
			_frost_ring = Sprite2D.new()
			_frost_ring.name = "FrostRing"
			_frost_ring.texture = TextureFactory.ring_tex(
				PopPalette.PLAYER.lerp(Color.WHITE, 0.55), 48, 5.5)
			add_child(_frost_ring)
		_frost_ring.visible = true
		_frost_ring.position = Vector2.ZERO
		_frost_ring.scale = Vector2.ONE * (hitbox_r * 1.55 / 19.0) \
			* (1.0 + 0.05 * sin(_anim_t * 6.4))                        # 贴图环半径 19px 口径
		_frost_ring.modulate.a = 0.75 + 0.25 * sin(_anim_t * 5.2)
	elif _frost_ring != null:
		_frost_ring.visible = false


static func _get_arc_patterns() -> Array[PackedVector2Array]:
	# 预生成电弧折线顶点池（8 组 × 4 顶点，坐标 = hitbox_r 单位；全敌共享零逐帧生成）
	if _arc_pattern_pool.is_empty():
		for i in range(8):
			var flip := 1.0 if i % 2 == 0 else -1.0
			var amp := 0.30 + 0.06 * float(i % 3)
			var pts := PackedVector2Array([
				Vector2(-1.0, 0.0),
				Vector2(-0.42, flip * amp),
				Vector2(0.36, -flip * amp * 0.85),
				Vector2(1.0, flip * amp * 0.3),
			])
			_arc_pattern_pool.append(pts)
	return _arc_pattern_pool


func _tick_status_tint(p_burning: bool, p_chilled: bool, p_frozen: bool, p_shocked: bool) -> void:
	# 本体状态染色（self_modulate 乘色——零 shader 开销）：点燃橙红呼吸 / 寒滞冰蓝 /
	# 冻结冰蓝封冻（用户反馈「冰冻没看见」→ 加强到一眼可辨）/ 感电微频闪；
	# 取色全部 = PopPalette 表内 lerp 派生（单源纪律）
	var tint := Color.WHITE
	if p_burning:
		var breath := 0.38 + 0.1 * sin(_anim_t * 6.2)
		tint = tint.lerp(PopPalette.ENEMY.lerp(PopPalette.XP, 0.45), breath)   # 橙红呼吸
	if p_chilled:
		tint = tint.lerp(PopPalette.PLAYER.lerp(Color.WHITE, 0.45), 0.55)      # 寒滞冰蓝（加强）
	if p_frozen:
		tint = tint.lerp(PopPalette.PLAYER.lerp(Color.WHITE, 0.6), 0.88)       # 冻结重冰蓝封冻
	if p_shocked:
		tint = tint.lerp(Color.WHITE, maxf(sin(_anim_t * 46.0), 0.0) * 0.14)   # 微频闪
	_sprite.self_modulate = tint


# ── 毒爆残效（E12 死亡毒环；一次性自消表现件——警示圈同款程序化绘制） ──
class PoisonSplash:
	extends Node2D

	var radius: float = 77.0
	var _life: float = 0.38

	func _process(p_delta: float) -> void:
		_life -= p_delta
		if _life <= 0.0:
			queue_free()
			return
		queue_redraw()

	func _draw() -> void:
		var t := clampf(_life / 0.38, 0.0, 1.0)
		var poison := PopPalette.SUCCESS.lerp(PopPalette.XP, 0.35)
		draw_circle(Vector2.ZERO, radius * (1.15 - 0.15 * t), Color(poison.r, poison.g, poison.b, 0.16 * t))
		draw_arc(Vector2.ZERO, radius * (1.15 - 0.15 * t), 0.0, TAU, 40,
			Color(poison.r, poison.g, poison.b, 0.7 * t), 4.0, true)


# ── Boss 地雷（B6 荆棘雷区，R18 P2；自驱节点——PROCESS_PAUSABLE 暂停/选卡自然冻结） ──
# 生命周期：落点红圈缩圈（telegraph_s）→ 落地 arm_s 激活 → 触发半径内玩家/寿命到期
# 爆炸（blast_r 结算 dmg）→ flavor 附加池（frost 冰锁减速圈 / venom 毒潭 DoT）。
# 宿主 Boss 归还清零（data==null）即自毁——池复用/重开零残留。
class BossMine:
	extends Node2D

	var trigger_r: float = 42.0
	var blast_r: float = 90.0
	var dmg: float = 21.0
	var life_s: float = 8.0
	var telegraph_s: float = 0.7
	var arm_s: float = 0.8
	var flavor: String = "thorn"
	var pool_cfg: Dictionary = {}
	var pool_kind: String = ""
	var host: Node2D = null

	var _t: float = 0.0
	var _ring: Telegraph.TelegraphCircle = null
	var _pulse_t: float = 0.0

	func _ready() -> void:
		_ring = Telegraph.TelegraphCircle.new()
		_ring.radius = blast_r
		_ring.color = Color(1.0, 0.36, 0.36)     # 红 = 爆炸/定点 AOE（§1.2 语义）
		add_child(_ring)

	func _process(p_delta: float) -> void:
		if host != null and (not is_instance_valid(host) or host.get("data") == null):
			queue_free()                          # 宿主已归还/重开——零残留
			return
		_t += p_delta
		if _t < telegraph_s:
			_ring.visible = true
			_ring.progress = _t / maxf(telegraph_s, 0.01)
			_ring.queue_redraw()
			return
		_ring.visible = false
		if _t < telegraph_s + arm_s:
			queue_redraw()                        # 落地展开（arm 期不触发）
			return
		var player := _get_player()
		if player != null and is_instance_valid(player):
			if global_position.distance_to(player.global_position) <= trigger_r:
				_explode(player)
				return
		if _t >= telegraph_s + arm_s + life_s:
			_explode(player)
			return
		_pulse_t += p_delta * (6.0 if _player_in_trigger() else 2.4)
		queue_redraw()                           # 闪烁读感（玩家贴近加速脉冲）

	func _player_in_trigger() -> bool:
		var player := _get_player()
		return player != null and is_instance_valid(player) \
			and global_position.distance_to(player.global_position) <= trigger_r

	func _explode(p_player: Node2D) -> void:
		if p_player != null and is_instance_valid(p_player) \
				and global_position.distance_to(p_player.global_position) <= blast_r:
			(p_player as Player).take_contact_damage(dmg)
		if not pool_cfg.is_empty():
			var pool := HazardPool.new()
			pool.name = "HazardPool"
			pool.position = global_position
			pool.radius = float(pool_cfg.get("radius", 80.0))
			pool.life_s = float(pool_cfg.get("life_s", 3.0))
			pool.host = host
			match pool_kind:
				"frost":
					pool.slow_mult = float(pool_cfg.get("drag_mult", 0.65))
					pool.color = PopPalette.PLAYER.lerp(Color.WHITE, 0.4)
				"venom":
					pool.dmg_per_tick = 60.0 * float(pool_cfg.get("dps_pct", 8.0)) / 100.0
					pool.color = PopPalette.SUCCESS.lerp(PopPalette.XP, 0.3)
				"fire":
					pool.dmg_per_tick = 60.0 * float(pool_cfg.get("dps_pct", 8.0)) / 100.0
					pool.color = PopPalette.ENEMY
			get_parent().add_child(pool)
		EventBus.emit_kill_blast(global_position, blast_r * 0.6)   # 爆炸环表现（复用通道）
		queue_free()

	func _draw() -> void:
		if _t < telegraph_s:
			return                                # 落点预警期只画红圈
		var armed := _t >= telegraph_s + arm_s
		var body := Color(0.22, 0.2, 0.26, 1.0) if armed else Color(0.3, 0.28, 0.34, 0.7)
		draw_circle(Vector2.ZERO, 9.0, body)
		var edge := _flavor_color()
		if armed:
			var pulse := 0.55 + 0.45 * sin(_pulse_t * TAU)
			draw_arc(Vector2.ZERO, 13.0 + 2.0 * sin(_pulse_t * TAU), 0.0, TAU, 20,
				Color(edge.r, edge.g, edge.b, 0.4 + 0.5 * pulse), 2.5, true)
		else:
			draw_arc(Vector2.ZERO, 12.0, 0.0, TAU, 16, Color(edge.r, edge.g, edge.b, 0.5), 2.0, true)
		draw_circle(Vector2.ZERO, 3.5, edge)

	func _flavor_color() -> Color:
		match flavor:
			"frost":
				return PopPalette.PLAYER.lerp(Color.WHITE, 0.35)
			"venom":
				return PopPalette.SUCCESS.lerp(PopPalette.XP, 0.3)
			"fire":
				return PopPalette.ENEMY
			_:
				return PopPalette.XP              # thorn 荆棘金

	func _get_player() -> Node2D:
		var tree := get_tree()
		return tree.get_first_node_in_group(&"player") as Node2D if tree != null else null


# ── Boss 扫线（B7 湮灭扫线，R18 P2；起角锁定——带内不追踪，处决技不可打断） ──
# 前摇（Boss 施法态 TelegraphLine 1.0s）完成后落场：锚定施法瞬间 Boss 位置，
# 0° 起角扫 arc_deg / sweep_s；命中判定 = 玩家到当前射线垂距 ≤ 线宽一半，0.6s 一次。
class BossSweep:
	extends Node2D

	var base_angle: float = 0.0
	var arc_deg: float = 100.0
	var sweep_s: float = 1.6
	var width_px: float = 26.0
	var dmg: float = 30.0
	var flavor: String = "vine"
	var pool_cfg: Dictionary = {}
	var pool_kind: String = ""
	var host: Node2D = null

	const BEAM_LEN := 1500.0
	const HIT_TICK := 0.6

	var _t: float = 0.0
	var _hit_tick: float = 0.0
	var _ang := 0.0

	func _process(p_delta: float) -> void:
		if host != null and (not is_instance_valid(host) or host.get("data") == null):
			queue_free()                          # 宿主已归还/重开——零残留
			return
		_t += p_delta
		_ang = base_angle + deg_to_rad(arc_deg) * clampf(_t / maxf(sweep_s, 0.01), 0.0, 1.0)
		_hit_tick -= p_delta
		var player := _get_player()
		if player != null and is_instance_valid(player) and _hit_tick <= 0.0:
			var rel: Vector2 = player.global_position - global_position
			var proj := rel.dot(Vector2.from_angle(_ang))
			var perp := absf(rel.cross(Vector2.from_angle(_ang)))
			if proj >= 0.0 and proj <= BEAM_LEN \
					and perp <= width_px * 0.5 + 8.0:
				(player as Player).take_contact_damage(dmg)
				_hit_tick = HIT_TICK
		queue_redraw()
		if _t >= sweep_s:
			# 扫线毒尾（venom 皮）：扫完终点落毒潭一次，随后自清
			if not pool_cfg.is_empty() and not has_meta("_pool_dropped"):
				set_meta(&"_pool_dropped", true)
				var pool := HazardPool.new()
				pool.name = "HazardPool"
				pool.position = global_position + Vector2.from_angle(_ang) * 300.0
				pool.radius = float(pool_cfg.get("radius", 40.0))
				pool.life_s = float(pool_cfg.get("life_s", 3.0))
				pool.dmg_per_tick = 60.0 * float(pool_cfg.get("dps_pct", 8.0)) / 100.0
				pool.color = PopPalette.SUCCESS.lerp(PopPalette.XP, 0.3)
				pool.host = host
				get_parent().add_child(pool)
			queue_free()

	func _draw() -> void:
		var c := _beam_color()
		var dir := Vector2.from_angle(_ang)
		var tail := dir * BEAM_LEN
		# 主束（厚线）+ 外辉（淡宽线）——同形同色（前摇紫线 = 结算紫束）
		draw_line(Vector2.ZERO, tail, Color(c.r, c.g, c.b, 0.9), width_px, true)
		draw_line(Vector2.ZERO, tail, Color(c.r, c.g, c.b, 0.3), width_px * 1.9, true)
		draw_circle(Vector2.ZERO, width_px * 0.7, Color(c.r, c.g, c.b, 0.9))

	func _beam_color() -> Color:
		match flavor:
			"venom":
				return PopPalette.SUCCESS.lerp(PopPalette.XP, 0.35)
			"fire":
				return PopPalette.ENEMY
			_:
				return Color(0.7, 0.5, 1.0)       # vine/默认 紫（§1.2 狙击线语义）

	func _get_player() -> Node2D:
		var tree := get_tree()
		return tree.get_first_node_in_group(&"player") as Node2D if tree != null else null


# ── Boss 附加池（frost 冰锁减速 / venom 毒潭 / fire 火焰地，R18 P2；自驱自清） ──
class HazardPool:
	extends Node2D

	var radius: float = 80.0
	var life_s: float = 3.0
	var tick_s: float = 0.6
	var dmg_per_tick: float = 0.0
	var slow_mult: float = 1.0
	var color: Color = PopPalette.SUCCESS
	var host: Node2D = null

	var _t: float = 0.0
	var _tick: float = 0.0

	func _process(p_delta: float) -> void:
		if host != null and (not is_instance_valid(host) or host.get("data") == null):
			queue_free()
			return
		_t += p_delta
		if _t >= life_s:
			queue_free()
			return
		_tick -= p_delta
		if _tick <= 0.0:
			_tick += tick_s
			var player := _get_player()
			if player != null and is_instance_valid(player) \
					and global_position.distance_to(player.global_position) <= radius:
				if dmg_per_tick > 0.0:
					(player as Player).take_contact_damage(dmg_per_tick)
				if slow_mult < 1.0:
					(player as Player).apply_hazard_slow(slow_mult, tick_s * 1.6)
		queue_redraw()

	func _draw() -> void:
		var fade := clampf((life_s - _t) / 1.0, 0.0, 1.0)   # 末 1s 淡出
		var a := 0.85 * fade
		draw_circle(Vector2.ZERO, radius, Color(color.r, color.g, color.b, 0.14 * a))
		draw_arc(Vector2.ZERO, radius, 0.0, TAU, 36, Color(color.r, color.g, color.b, 0.7 * a), 3.0, true)
		draw_arc(Vector2.ZERO, radius * 0.7, 0.0, TAU, 28, Color(color.r, color.g, color.b, 0.25 * a), 2.0, true)

	func _get_player() -> Node2D:
		var tree := get_tree()
		return tree.get_first_node_in_group(&"player") as Node2D if tree != null else null


# ── 死亡弹爆（R19 打击质感；一次性自清表现件——毒爆残效同款模式） ──
# 白环收缩扩散 + 四向碎屑飞散 0.2s；宿主敌已归还，本件挂世界层自清。
class DeathPop:
	extends Node2D

	const LIFE := 0.2

	var _t: float = LIFE

	func _process(p_delta: float) -> void:
		_t -= p_delta
		if _t <= 0.0:
			queue_free()
			return
		queue_redraw()

	func _draw() -> void:
		var t := 1.0 - clampf(_t / LIFE, 0.0, 1.0)
		var col := Color(1.0, 1.0, 1.0, (1.0 - t) * 0.9)
		draw_arc(Vector2.ZERO, 8.0 + 22.0 * t, 0.0, TAU, 20, col, 3.0, true)
		draw_circle(Vector2.ZERO, 7.0 * (1.0 - t), Color(1.0, 1.0, 1.0, (1.0 - t) * 0.5))
		for i in range(4):
			var a := TAU * float(i) / 4.0 + t * 1.2
			var d := 10.0 + 16.0 * t
			draw_circle(Vector2(cos(a), sin(a)) * d, 2.6 * (1.0 - t), col)

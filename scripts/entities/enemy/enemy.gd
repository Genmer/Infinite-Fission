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
var resist: Array[float] = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]  # KIN..DEN 8 元素快照（超导 −30% 实时改写；R192 追加不重排——旧档 4 项 .tres 越界位 get_resist 回 0.0 中性）
var immune_mask: int = 0
var elem_immune: int = 0                      # 元素伤害免疫位（R22 P1：bit = 1 << Element）
var elemental: ElementalState = null          # 状态容器（M-11 注入；包 3 收紧：register_host 挂 ElementalState）
var ext_slow_mult: float = 1.0                # 外部减速乘区（P2 毒云等直结算通道；与元素冰缓正交）
var ext_slow_left: float = 0.0                # 外部减速剩余 s（到期自动还原 1.0——免逐敌摘除）

# ── R187 敌侧通用标记通道（共享组；W6/W7 引信 + W8 蓄能——「标记在敌人身上」） ──
# 命名避让说明：本类既有爆虫自爆访问器 fuse_left()（pkg4:524 契约冻结不可改名），
# W6/W7 引信通道避让为 fuse_mark_left（文档 R187 §三.6 的「fuse_left 字段」同义位）。
var fuse_mark_left: float = 0.0               # 引信涂层剩余 s（W6 直击挂 4s 幂等刷新；>0 = 引信在身）
var fuse_coat_amp: float = 1.0                # 引信增伤倍率（§2.3.5 目标侧标记：挂标时随涂层落敌身，
                                              # 任何自导爆炸命中引信敌同享 ×(1+0.2×层)——W7 连携通道）
var fuse_detonate_guard_left: float = 0.0     # 定向爆破护栏剩余 s（每敌 0.5s——防同帧双爆双吃）
var charge_stacks: int = 0                    # W8 蓄能档位（目标 uid 全局单例：本体+复制体共享加速、引爆当量不复制）
var charge_cap: int = 5                       # 最近叠档的帽（头顶读数「x/N」分母；W8 charge_max 默认 5，validator [3,8]）
var charge_gain_cd_left: float = 0.0          # 蓄能获取共享内冷剩余 s（同目标口径——承接 hit_cd 退役语义）
var detonate_icd_left: float = 0.0            # 单目标引爆 ICD 剩余 s（0.25s；全局 ICD 在武器侧）
var dead: bool = false                        # 死亡短路标志（E-06：首次致死立即置位）
var boss_phase: int = 0                       # Boss 阶段（HP<50% → 2 等）
var fire_cd_left: float = 0.0                 # RANGED 行为射击冷却
var projectile_pool: ProjectilePool = null    # 敌弹池注入（RANGED 开火；ballistic 场景池）
var enemy_grid: SpaceGrid = null               # 网格引用注入（E-10 分离力/查询预留）
var bucket_host: Node = null                   # R214 E' 分桶 host 注入（敌池 TexBucketHost；
                                               # null=不分桶——老测试直连池零行为变化）

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
var _spell_ring: Telegraph.TelegraphCircle = null   # R253 SpellRing 进度弧宿主引用（_tick_ranged 推进）
var _spell_delay: float = 0.9               # R253 施法读条总时长（进度归一化分母；0=无活动圈）
var _blink_threat: bool = false               # R251 需求①：躲爆威胁旗——读条毕落地置位（快照
                                              # ±24px ⊂ blast_r，玩家 0.35s 前还在圈心=真实威胁）；
                                              # 引爆未伤人据此授橙盾；打断/池归还清零防错授

# ── Boss 韧性条（Poise，R23 P3：ENEMY_BOSS_TELEGRAPH §2.1——受击积累→硬直打断） ──
var poise_max: float = 0.0                    # 韧性上限（spawn 期 boss.poise_max，缺省 50；0 = 未启用）
var poise: float = 0.0                        # 当前韧性积累
var _poise_immune_left: float = 0.0           # 硬直后免疫窗剩余（6s）
var _stagger_left: float = 0.0                # 硬直剩余 s（1.2s：停摆+打断——「压制窗口」）

# ── B5 破裂冲锋（R23 P3：E18 charge 数据接线；三段冲刺+橙向条） ──
var _chg_state: int = 0                       # 0 冷却巡航 / 1 前摇 / 2 冲刺 / 3 段间
var _chg_left: float = 0.0
var _chg_seg_left: int = 0
var _chg_dir: Vector2 = Vector2.ZERO
var _chg_cd: float = 4.0
var _chg_cfg: Dictionary = {}
var _chg_fan: Telegraph.TelegraphFan = null   # 冲锋橙向条（§1.2 橙=冲撞落点）

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
var _contact_player: Player = null            # R202 ②：接触重叠玩家缓存（area_entered/exited 维护）
var _sprite: Sprite2D = null                  # 渲染（方向 C 分型贴图 + 共享受击闪白 shader）
var _material: ShaderMaterial = null
var _flash_left: float = 0.0
var _fade_left: float = 0.0
var _player_cache: Node2D = null

# ── R233 T6（决策3.1 插值层）：渲染插值双缓冲——global_position 定性为「显示缓存」，
# 模拟真位以 _ip_curr 为准（game_loop 恢复/快照遍历维护时序）。_ip_prev=N-1 步末位。
# spawn 置位不挂本类 spawn()——出生位由 spawner 挂位（enemy.position=…）后定型，置位
# 口 = ip_birth_snap()（spawner 置位后调用）；release 不清（下任 spawn 重置覆盖，设计 3.4）。
var _ip_prev: Vector2 = Vector2.ZERO
var _ip_curr: Vector2 = Vector2.ZERO

# 方向 C 表现层（敌人角色化 2026-08-29：分型剪影/表情/动画状态机）
var _base_scale: float = 1.0                  # hitbox 口径基础缩放（果冻/充能缩放的乘算基准）
var _kind: StringName = &"grunt"              # 分型缓存（spawn 期判定一次——tick 零字符串开销）
var _crown: Sprite2D = null                   # 精英金色皇冠挂件（TAG_ELITE）
var _satellites: Array[Sprite2D] = []         # Boss 漂浮小卫星球（聚合体多层）
var _shadow: Sprite2D = null                  # 底影（E5 悬浮 / Boss；贴地椭圆）
var _sparkles: Array[Sprite2D] = []           # E5 精英微光粒（金色小珠）
var _fullload_decor_hidden: bool = false      # R225：满载纯装饰门已施加标志（false=装饰随 want
                                              # 常显；_reset_state 池归还清零防复用错相）
var _armor_sprite: Sprite2D = null            # E3 外甲板（与内芯分层错位）
var _armor_cracked: bool = false              # E3 外甲裂纹态（HP≤50% 换裂纹贴图）
var _armor_jiggle_left: float = 0.0           # E3 受击甲板错位抖动剩余
var _wobble_left: float = 0.0                 # 受击果冻抖动剩余
var _hit_jolt_left: float = 0.0               # 受击位移颤动剩余（R19 打击质感，纯表现）
var _hit_jolt_dir: Vector2 = Vector2.ZERO     # 颤动方向（远离命中点）
var _face_state: int = 0                      # E4 脸状态（0 平静/1 惊恐/2 引爆）
var _anim_t: float = 0.0                      # 表现时钟（卫星公转/抖动相位）
var _boss_orbit: float = 0.0                  # 卫星公转角
# ── R72 新形态机制（困难/地狱扩展敌：盾兵/反弹盾/法术兵/射箭兵） ──────────────
var _frontal_shield: float = 0.0               # 正面减伤比（0=无盾；命中来向与「面向玩家」
                                               # 夹角在 shield_arc 半角内 → 伤害 ×(1−比)）
var _shield_arc: float = deg_to_rad(110.0)     # 盾面有效弧（全角弧度）
var _reflect_cd_max: float = 0.0               # 反弹盾周期（0=无；就绪时来弹折返攻玩家）
var _reflect_cd: float = 0.0                   # 反弹冷却剩余
var _is_caster: bool = false                   # 法术兵（RANGED 特化：法术圈 AoE 替代直射）
var _spell_cfg: Dictionary = {}                # {radius, delay, atk_ratio}
var _aim_lead: bool = false                    # 射箭兵（提前量射击）
var _player_vel_est: Vector2 = Vector2.ZERO    # 玩家速度估计（逐帧差分 + 平滑）
var _last_player_pos: Vector2 = Vector2.INF    # 上一帧玩家位置（差分锚点）
var _boss_angry: bool = false                 # Boss 二阶段变脸贴图标志
var _body_kind: StringName = &"grunt"         # R188⑪：本体贴图规格缓存（kind）——闪白窗逐帧衰减
                                              # 读成员，不再每帧 _body_tex_spec() 新建 Array(2)+String
                                              #（逐帧分配税纪律，R188/R225 先例；写点 _refresh_body_spec）
var _body_angry: bool = false                 # R188⑪：本体贴图规格缓存（怒相/volatile 引爆脸）
var _spawn_left: float = 0.0                  # 出生弹入剩余（0→1 带 overshoot）
# 夜间R39 精英词缀技（ENEMY_BOSS_TELEGRAPH §6：Boss 技弱化版，前摇 +150ms 已含表值）
const AFFIX_DEFS: Dictionary = {
	&"affix_ring": {"cd": 7.0, "telegraph": 0.55, "type": "ring"},
	&"affix_sniper": {"cd": 6.0, "telegraph": 0.85, "type": "sniper"},
	&"affix_trapper": {"cd": 13.0, "telegraph": 0.85, "type": "trapper"},   # 二db cd 9→13：脚下雷投放降频（用户「出现得太频繁」）
	&"affix_charger": {"cd": 6.0, "telegraph": 0.45, "type": "charger"},
	&"affix_caller": {"cd": 14.0, "telegraph": 1.15, "type": "caller"},
}
var elite_affixes: Array[StringName] = []     # 生效词缀（≤2；charger×trapper 互斥由投放侧规避）
var _affix_cd: Array[float] = []              # 各词缀独立冷却（与 Boss 弹幕计时器隔离）
var _affix_casting: int = -1                  # 前摇中词缀下标（-1 无）
var _affix_cast_left: float = 0.0
var _affix_cast_total: float = 0.0
var _affix_dir: Vector2 = Vector2.RIGHT       # 狙击扇锁定方向（起手快照）
var _affix_tel_circle: Telegraph.TelegraphCircle = null
var _affix_tel_fan: Telegraph.TelegraphFan = null
var _affix_dash_left: float = 0.0             # charger 冲刺段剩余（0=非冲刺）
var _affix_dash_dir: Vector2 = Vector2.RIGHT  # charger 锁定方向
var _affix_dmg_mult: float = 1.0              # charger 冲刺期接触伤害 ×1.25（dmg 25%→平值 15 口径）
var _dash_state: int = 0                      # E2 冲刺状态机（0 巡航/1 蓄力/2 冲刺/3 回弹）
var _dash_left: float = 0.0                   # E2 当前阶段剩余
var _dash_dir: Vector2 = Vector2.ZERO         # E2 冲刺锁定方向（蓄力期末采样）

# 方向 C 元素状态表现层（用户反馈 2026-08-29「闪电/灼烧等特效」；只读 ElementalState，
# 零数值/碰撞副作用，_reset_state 全复位，共享贴图 + 无逐敌 shader）：
var _burn_flames: Array[Sprite2D] = []        # 点燃：顶部上飘火苗 ×4（循环重生）
var _burn_ember: Sprite2D = null              # 点燃：体周余烬光晕（本底下层呼吸，用户反馈「燃烧看不见」）
var _frost_shards: Array[Sprite2D] = []       # 寒滞/冻结：结霜菱形冰渣 ×3
var _frost_ring: Sprite2D = null              # 冻结冰壳描边圈（白环）
var _super_mist: Array[Sprite2D] = []         # 超导电离雾点群（R57：3 个小雾点绕体漂浮——单块大 soft_dot 读作「纯紫圆球」，用户反馈三轮）
var _shock_arcs: Array[Line2D] = []           # 感电：双锯齿电弧（相位错开→半常亮感）
var _shock_arc_left: float = 0.0              # 电弧剩余显示时长（两弧共用相位）
var _shock_arc_cd: float = 0.0                # 下次电弧倒计时
var _arc_pattern_idx: int = 0                 # 电弧顶点池轮换游标
var _shock_bolt: Line2D = null                # 感电：垂直落雷（天降锯齿——去圆球化，用户反馈二轮）
var _shock_bolt_left: float = 0.0             # 落雷剩余显示时长
var _shock_bolt_cd: float = 0.0               # 下次落雷倒计时
var _shock_impact: Sprite2D = null            # 落雷命中点四角星闪
# R237 清退刀：接触伤害去物理化（默认 false=信号通道原语义）。on 态=敌不建 HitArea、
# tick 内双半径直判（hitbox_r+player.hitbox_radius，与物理圆重叠同口径；结算是
# take_contact_damage 内 _dead/无敌帧/格挡闸不变，生产=物理帧内逐位等价）。动机=vc40
# 真机 物步µs 15-64ms（物理相），终局物理空间清空。⚠直驱测试语义有意变更仅限 on 态
# （R202 ② 白名单注记：blink_cases「走位出圈免伤」等不步物理用例在默认 off 态不受扰；
# 翻开 vc41 时该族语义迁移随包裁定）。翻开前置门=桌面 A/B 归因 verdict（probe_r237_physattr）。
static var CONTACT_RADIAL: bool = false

# R237 闪白换桶刀：满载档受击闪白改「白变体贴图换桶」（渲染轴归因定案——深载 dc
# 增量 83-123% 在敌域 F1，受击闪白窗 modulate≠WHITE（R217 两档白乘）把闪白敌逐件
# 打出批组交错断批是断批主源；弹/碎桶实证 540-694 件合批 0-3dc=合批天花板）。
# on（默认）=满载闪白走 TextureFactory.enemy_tex_flash 白变体（强闪全白剪影/弱闪半白
# 混合，两档强度语义保留）+ modulate 复位 WHITE + 材质摘除 + _place_in_bucket() 换桶
# （R214 E' 变脸换桶同款——同档全敌同贴图同桶，至多 2 个闪白桶=至多 2 批 bounded）；
# 轻载路径零改动（ShaderMaterial 混合闪白保留）。
# 视觉口径披露：满载档受击闪白 = modulate 过曝白乘 → 白剪影/半白贴图（经典 hit-flash
# 观感，亮度读感略变）；轻载观感零变化。用户否决口：FLASH_TEX=false 单点回退
# （R216 碎片烤色先例——满载路径回 modulate 白乘现状，测试双态用）。
static var FLASH_TEX: bool = true
var _flash_tex_on: bool = false                 # 白变体贴图在身标志（闪毕/门回落/池归还
                                               # 三路复位共用账本——true=texture 是白变体，
                                               # 复位口据此换回本体贴图防池复用残留）

# R240 敌本体 MultiMesh 镜像门（渲染轴 F1 敌域第二刀——vc44 轻压力局判读定案：轻载
# fps 地板主犯=渲染轴，渲ms 16.4-16.8 单独封顶 60fps；R237 F1 边际 190-437dc=战斗
# dc 增量 83-123%，闪白换桶刀〔vc41〕真机无可感收益→断批主源=染色组合×渐显×瞬态件
# 交错，逐敌 Sprite 合批结构性到顶）。on（默认）=符合条件的敌本体绘制改
# TexBucketHost 按贴图 MultiMesh 镜像（每贴图恒 1 draw，实例色承载染色/渐显——
# tex_bucket_host.gd 头注）；排除面=boss*/elite/bastion（叠层子件语义）+
# FLASH_TEX=false（实例色 8-bit 钳位承不住 >1 白乘——闪白联动贴图化路径必须可用）。
# off（单点回退）=逐敌 Sprite 现状零扰动。视觉口径披露：桶内本体层恒在瞬态指示件
# 之下（原后生敌盖先出指示器，现指示器恒在上——可读性口径）；轻载闪白从 shader
# 混合改白变体贴图（=现满载观感，白剪影/半白——R237 已披露口径）。
static var BODY_MM: bool = true
var _mm_on: bool = false                        # 本体镜像在册标志（place 尾维护——闪白
                                               # 分支/池复位口读它判「贴图路径常开」）

static var _arc_pattern_pool: Array[PackedVector2Array] = []   # 预生成电弧折线顶点池（全敌共享）
static var _bolt_pattern_pool: Array[PackedVector2Array] = []  # 预生成落雷折线顶点池（全敌共享）

# ── R202 ⑤：表现层写点节流游标 ──
# _tick_status_fx 30Hz 门（_sfx_sig 状态位签名 / _sfx_write_left 节拍 / _sfx_accum
# 跳写期累计 delta——写帧一次结清，电弧/落雷倒计时墙钟精度不漂移）；
# _tick_visual transform 量化游标（projectile_base.gd:834 _vis_scale_q 先例——
# 呼吸/摇摆连续小幅度动画按量化级跳写；_reset_state/_sync_visual 直写后置
# _vis_tx_stale 强制下帧全量对齐防游标失配）。
var _sfx_sig: int = -1
var _sfx_write_left: float = 0.0
var _sfx_accum: float = 0.0
var _vis_tx_stale: bool = true
var _vis_sx_q: int = 0
var _vis_sy_q: int = 0
var _vis_rot_q: int = 0
var _vis_off_q: Vector2 = Vector2.INF

# 单帧玩家几何缓存（仅单 tick 内惰性解算复用）
var _frame_geom_valid: bool = false
var _frame_geom_stamp: int = -1
var _to_player: Vector2 = Vector2.ZERO
var _dist_sq_to_player: float = -1.0
var _dist_to_player: float = -1.0
var _dir_to_player: Vector2 = Vector2.ZERO

const VIS_CULL_MARGIN := 64.0
const VIS_CULL_RECT := Rect2(-VIS_CULL_MARGIN, -VIS_CULL_MARGIN, 720.0 + 2.0 * VIS_CULL_MARGIN, 1280.0 + 2.0 * VIS_CULL_MARGIN)


func _reset_frame_geom() -> void:
	_frame_geom_valid = false
	_frame_geom_stamp = -1
	_dist_sq_to_player = -1.0
	_dist_to_player = -1.0
	_dir_to_player = Vector2.ZERO


func _ensure_frame_geom(p_player: Node2D = null) -> bool:
	if not PerfGovernor.boost_mode():
		return false
	if _frame_geom_valid and _frame_geom_stamp == GameConfig.frame_stamp:
		return true
	var pl := p_player if p_player != null else _player()
	if pl == null or not is_instance_valid(pl):
		return false
	_to_player = pl.global_position - global_position
	_dist_sq_to_player = _to_player.length_squared()
	_dist_to_player = -1.0
	_dir_to_player = Vector2.ZERO
	_frame_geom_valid = true
	_frame_geom_stamp = GameConfig.frame_stamp
	return true


func _get_dist_to_player(p_player: Node2D = null) -> float:
	var pl := p_player if p_player != null else _player()
	if pl == null or not is_instance_valid(pl):
		return 999999.0
	if not PerfGovernor.boost_mode():
		return global_position.distance_to(pl.global_position)
	if not _ensure_frame_geom(pl):
		return global_position.distance_to(pl.global_position)
	if _dist_to_player < 0.0:
		_dist_to_player = sqrt(_dist_sq_to_player)
	return _dist_to_player


func _get_dir_to_player(p_player: Node2D = null) -> Vector2:
	var pl := p_player if p_player != null else _player()
	if pl == null or not is_instance_valid(pl):
		return Vector2.ZERO
	if not PerfGovernor.boost_mode():
		return (pl.global_position - global_position).normalized()
	if not _ensure_frame_geom(pl):
		return (pl.global_position - global_position).normalized()
	if _dir_to_player == Vector2.ZERO:
		var d := _get_dist_to_player(pl)
		_dir_to_player = _to_player / d if d > 0.0001 else Vector2.ZERO
	return _dir_to_player


func _is_vis_cullable() -> bool:
	if not PerfGovernor.boost_mode():
		return false
	if is_boss():
		return false
	if _fuse_armed or _fuse_left > 0.0:
		return false
	if _dash_state == 1 or _blink_state == 1:
		return false
	if _spawn_left > 0.0 or _wobble_left > 0.0 or _flash_left > 0.0:
		return false
	return not VIS_CULL_RECT.has_point(global_position)

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

# ── N01/R199 Boss 设计出场波（波表首次登场位；hp_base 即该波设计所见血量） ─────
# 真源 = 五图波表 Boss 行首现位（R199_RELEASE_SWEEP §G2）：boss1=草原/寒霜/树海 w10、
# boss2=魔域/沼泽 w10、boss3=草原 w30、E17=寒霜 w15、E18=魔域 w20、E19=树海 w25、
# E20=沼泽 w30。Enemy.spawn 对 TAG_BOSS/TAG_FINAL_BOSS 改按 pow(growth, w−出场波)
# 差值成长（.tres 的 hp_base 已含出场波成长，spawn 再乘一层 = 双重成长——E6_boss1@w10
# 曾 ×3.33 / E6_boss3@w30 ×32）；无尽轮换位（如 E6_boss1@w35）按差值缩放不失真。
# 表未收录的 Boss id（测试桩/自定义）保持旧全额口径；普通敌路径零改动。
const BOSS_DEBUT_WAVE: Dictionary = {
	&"E6_boss1": 10,
	&"E6_boss2": 10,
	&"E6_boss3": 30,
	&"E17_frost_sovereign": 15,
	&"E18_demon_lord": 20,
	&"E19_grove_warden": 25,
	&"E20_swamp_hydra": 30,
}
static var _flash_shader: Shader = null

# ── R202 ①：fx_quality 热路径读缓存（static 单值 + settings_changed 订阅直写） ──
# 敌侧表现层每帧每敌读档（火苗预算/落雷门/死亡弹爆门等 ×N敌×60Hz——probe_heat_scan
# 实测 Meta.settings 单次 ~0.25µs，满屏敌纯查表税）。口径：
# · 每实例 _ready 订阅 settings_changed、全部写同一 static 值——池敌连接随会话常驻；
#   探针/测试侧 queue_free 的实例由引擎自动断连，新建实例 _ready 再订（任意时刻
#   ≥1 活敌在树缓存即鲜活，Enemy 数量级 ≤128 连接可忽略）。
# · ⚠直写盲区：绕过 set_setting 直改 Meta._settings（测试快照回写先例
#   verify_feedback_cases.gd:2424 / r195_adapt_cases.gd:857/:870）不发信号——缓存留旧值。
#   现有用例恰好「还原值 == 末次 emit 值」不红，属潜伏陷阱；新用例必须走 set_setting。
static var _fx_quality_cache: int = -1        # -1 = 未初始化（首读惰性取值）

# ── R202 ④：敌侧状态表现件档位预算（照 elemental_fx_layer.gd:49-51 DOT_SPARK_BUDGET/
#    BOLT_ZAP_BUDGET 先例：低档关 / 中档减量 / 高档全量；高档口径逐位不变——测试默认
#    q=2 的 flames 4 / arcs 2 / shards 3 等既有断言（verify_feedback_cases.gd:661-686）
#    不得降。R202 ①：原 :2389 每帧每敌数组字面量 [0,2,BURN_FLAME_COUNT] 分配提为 const） ──
const FLAME_BUDGET: Array[int] = [0, 2, BURN_FLAME_COUNT]
const FROST_SHARD_BUDGET: Array[int] = [0, 2, FROST_SHARD_COUNT]
const FROST_RING_MIN_Q := 1                    # 冻结冰壳描边圈：中/高档开（低档剩染色读感）
const SHOCK_ARC_BUDGET: Array[int] = [0, 1, 2]
const SUPER_MIST_BUDGET: Array[int] = [0, 2, 3]

# ── R202 ⑤：状态表现层写点节拍（30Hz 降频——计时由累计 delta 结清不漂移；写透三条件
#    见 _tick_status_fx：状态签名变化 / 惰性建件未齐 / 节拍到点） ──
const STATUS_FX_WRITE_INTERVAL := 1.0 / 30.0

# ── R202 ⑥：Boss 附属（BossMine/BossSweep/HazardPool 三内类）共用玩家弱引用缓存 ──
# （get_first_node_in_group 每帧每件的 C++ 组查询折为一次弱解引用；玩家释放后 WeakRef
#  落空自动重查——enemy._player() 成员缓存同语义先例）
static var _appendage_player: WeakRef = null


# R262b H1：渐隐 α 四分档量化（enemy 本地 static——与 ElementalFxLayer._qa 同公式
# 同 0.25 步进；本侧不引 gamefeel 类：ElementalFxLayer:309 已反向引 Enemy.fullload_dim，
# 双向 class_name 引用成环即加载序风险，斩断本方向）
static func _qa_a(p_a: float) -> float:
	return float(roundi(clampf(p_a, 0.0, 1.0) * 4)) / 4.0


static func _fx_q() -> int:
	# fx_quality 档位读（缓存口；钳制 [0,2] 同 Meta._normalized_setting 口径）。
	# R203 真机分辨率专项：mobile 门内高档降中档——1.5K-2K 屏上状态表现件族
	# （火苗/冰渣/电弧/超导雾，满配 ~10.5 可见件/敌）是移动 GPU 填充与绘制项大头，
	# 真机实测怪稍多即 5-10 帧，降档减半保帧（桌面/headless 不受影响——verify 高档
	# 口径断言仍在桌面口径下逐位成立）
	# R220 模式地基（契约 A5 调速器映射写点）：PerfGovernor.fx_quality_cap() 档帽与
	# mobile 门 mini(cache,1) 合成取小——帽口生效门：tier_override 注入直驱（测试通道）/
	# mobile 按 tier 映射（3→2/2→1/1→0）/ 非 mobile 无注入恒 2（默认 tier=3 下
	# mini(cache,2)==cache——桌面/headless 既有口径零扰动，r202_g3/fx_quality 旧断言逐位不变）
	if _fx_quality_cache < 0:
		_fx_quality_cache = clampi(int(Meta.settings(&"fx_quality")), 0, 2)
	if OS.has_feature("mobile"):
		return mini(mini(_fx_quality_cache, 1), PerfGovernor.fx_quality_cap())
	return mini(_fx_quality_cache, PerfGovernor.fx_quality_cap())


static func _sfx_q() -> int:
	# R269 必改3：音效独立档口（制作人裁定：音效成本不在渲染轴——保帧模式不静音战斗）。
	# 关模式：与既有 _fx_q() 逐位同值（含 tier 帽语义，零扰动——boost 关路径深载 tier1
	# 静音=既有行为本批不动）；开模式：纯用户设置档（mobile 高档降中档现状保留）——
	# 不受 boost 钉 0、也不受调速器 tier 压档（保护性旁路，§3.3-A6）。消费点=四处
	# 施法音效门（_begin_cast/_release_cast/_affix_begin/_affix_release）。
	if not PerfGovernor.boost_mode():
		return _fx_q()
	if _fx_quality_cache < 0:
		_fx_quality_cache = clampi(int(Meta.settings(&"fx_quality")), 0, 2)
	return mini(_fx_quality_cache, 1) if OS.has_feature("mobile") else _fx_quality_cache


# ── R213 渲染四案共用满载门（vc20 真机定案：120 敌满载 dc361-1020/o2635、fps12-35，
#    帧预算大头在引擎侧——A~D 四刀同判据同开关；桌面口径零扰动，敌数回落自动恢复） ──
const FULLLOAD_ENEMY_MIN := 80                 # 满载判定：在树活敌 ≥80（2/3 屏帽 120）
const FULLLOAD_ENEMY_RELEASE := 72             # 评审#2 滞回下沿：开 ≥80 / 关 <72——敌数在
                                               # 80 附近震荡（击杀率≈刷怪率）时防状态件错相
                                               # 闪烁与闪白材质挂/摘横跳
static var fullload_override: int = -1         # 测试覆写口（r207_split 先例）：-1=真值门；
                                               # 0/1=强制关/开（headless 验收 A~D 门行为）
static var _fullload_latched: bool = false     # 滞回锁存态（真值路径维护；覆写口不读不写——
                                               # 测试注入不改锁存，波清空敌 0<72 自复位）

static func fullload_dim() -> bool:
	# R213 满载门真值：mobile 且活敌过门（Enemy.live_count 静态计数，_crit_stop_dense
	# 同源判据 game_feel_director.gd:257）+ 评审#2 滞回。仅状态表现件族消费
	# （_state_fx_q/普命中粒子/DOT 跳伤表现/闪白去 shader 化/XP 并珠）——音效门
	# （SfxBank 四处 _fx_q()>0）与死亡爆闪（_on_died DeathPop）不走本口，击杀反馈保留。
	if fullload_override >= 0:
		return fullload_override == 1
	if _fullload_latched:
		if not OS.has_feature("mobile") or live_count < FULLLOAD_ENEMY_RELEASE:
			_fullload_latched = false
			DebugStats.count(&"fullload_flips")   # 评审#4：门翻转计数（真机震荡耗时量化口）
	else:
		if OS.has_feature("mobile") and live_count >= FULLLOAD_ENEMY_MIN:
			_fullload_latched = true
			DebugStats.count(&"fullload_flips")
	return _fullload_latched


static func _state_fx_q() -> int:
	# R213 A案：敌状态表现件专用档位口——满载时归 0 档（火苗/冰渣/电弧/雾/落雷/冰环
	# 全隐藏，「在烧/在冻」读感由 _tick_status_tint 染色独自承担——R217 修轮起余烬光晕
	# 满载同隐（异贴图桶内断批，评审#1），非满载余烬仍常驻；降档显隐/回升补建走
	# _tick_status_fx 既有预算对齐机制（30Hz 写点 ≤33ms 生效，敌数回落自动恢复）。
	# 音效与死亡爆闪仍读 _fx_q()。
	if fullload_dim():
		return 0
	return _fx_q()


static func _decor_hidden_now() -> bool:
	# R269 C1：装饰门谓词并 boost（§3.5——只影响装饰显隐）：boost 开时皇冠/微光粒/
	# 卫星球/底影四族装饰恒隐（敌<80 段也隐；甲板保留=R225 语义原文）。fullload_dim
	# 本体不动=翻N/闪白/状态件等其余消费（:427/:477/:2757/:3128 一带）零波及；boost
	# 不写 _fullload_latched 锁存——fullload_flips 计数不因 boost 翻转而 +（§5-C1 断言）。
	# 唯一消费点=_apply_fullload_decor（复显走 _ensure_* want 语义，boost 关自动复显）。
	return fullload_dim() or PerfGovernor.boost_mode()


# ── R230 K2c：DeathPop/桶内演出件并发活口帽（阀门刀） ────────────────
# R230 夹具谱实锤（docs/qa/qa_r230_dcscan_baseline.json）：F1 敌桶本体 134dc（52.8%）
# 根因=DeathPop/PoisonSplash 自绘件（_draw 折线/弧逐件自成 dc、不参与纹理合批）穿插在
# 敌桶绘制序内打断敌本体合批（F1 单独可见仅 ~63dc，P2−P1=−52~−92）；深载杀率高时并发
# 活口 ~80（风暴档实测，池帽 96），穿插面随并发线性放大。本刀＝并发活口帽（分析 T6+
# 复审口径：sprite 化/并发帽二选一由谱定，主控按耦合面证据选并发帽——sprite 化需外溢
# telegraph.gd 触发降 backlog 条款，不走）：
#   门 = 三重门（mobile ∧ 帧率优先 ∧ tier≤2，R229 _burst_thin_on 同序同款）∧ 满载敌数
#   滞回门（fullload_dim——敌<80 段行为逐位不变）；门内 DeathPop+PoisonSplash 合计活口
#   ≤ DEATHPOP_FX_CAP，超帽申请「最老抢占」让位（注册表队头老实例经 _release 提前收尾
#   入池——可观测降级非静默吞，帽N 逐件计数）。豁免对齐 R229 粒子门口径：Boss 全保留
#  （不占帽位、不被抢占）、精英 1/2 采样、普通敌按帽放行。R226 口径=保险丝非成长帽
#  （帽只收表现件寿命，无任何成长数值改动）。
# 红线：甲板/护甲渲染必显不受帽影响（本刀零触碰 _ensure_armor/_armor 路径）；死亡结算/
# 掉落/经验零触碰（许可口只拦表现件发射，emit_enemy_killed/毒爆伤害在调用点照走）；
# 绘制序不变（不挪树、不改 z——件仍挂敌父域原位，抢占=原位隐藏入池既有协议）。
# tier3/特效优先/桌面/敌<80 恒关=逐位不变（门外 _death_fx_admit 恒 true，注册表纯记账）。
const DEATHPOP_FX_CAP := 10                   # 并发活口帽起点值（依据：DeathPop LIFE=0.2s
                                              # → 无抢占放行上限 50/s；夹具 S-A F3 稳态活口
                                              # ~7、风暴带 ~80——10=稳态+余量，穿插面收缩
                                              # ~8 倍，落设计建议 8-12 带内）
static var deathpop_cap_override: int = -1    # -1=真值自动门 / -2=强制关（用户否决档）/
                                              # -3=模拟 mobile（跳过 OS 检查直入 tier 分支，
                                              # headless 可测）/ 1=强开（burst_thin_override
                                              # 四态先例同款语义）
static var _death_fx_live: Array = []         # 受帽演出件注册表（插入序=创建序，[0]=最老；
                                              # 仅非 Boss 件入册——Boss 全保留不占帽位）
static var _death_fx_elite_tick: int = 0      # 精英 1/2 采样计数器（R229 _kill_thin_tick 同款）


static func _deathpop_cap_on() -> bool:
	# 门判定（R223 哨兵形状，_burst_thin_on 同序同款 + fullload_dim 滞回尾门）：
	# -2 恒关（用户否决压过一切注入）；1 恒开（探针档，headless 直入）；
	# -3 跳过 OS.has_feature("mobile") 直入后两门（「模拟真机」——真机语义与测试口径
	# 共用同一条门序）；真值路径 = mobile ∧ 帧率优先 ∧ tier≤2 ∧ 敌≥80 滞回。
	# R269：boost 分支插在两哨兵之后、mobile 门之前（§3.3）——保帧模式内死亡演出帽
	# 恒开（不依赖 fullload/tier/mobile；-2 用户否决仍在最高优先压过 boost）。
	if deathpop_cap_override == -2:
		return false
	if deathpop_cap_override == 1:
		return true
	if PerfGovernor.boost_mode():
		return true                          # R269：保帧模式死亡演出帽门（单向阀——关=下方真值序逐位）
	if deathpop_cap_override != -3 and not OS.has_feature("mobile"):
		return false
	if not PerfGovernor.frame_priority():
		return false
	if PerfGovernor.effective_tier() > 2:
		return false
	return fullload_dim()


static func _death_fx_cap_now() -> int:
	# R269：死亡演出并发帽现值（纯函数可测，§5-a5）——boost 开 → mini(DEATHPOP_FX_CAP, 4)
	#（增量面=PoisonSplash 收缩；DeathPop 侧实际被 :1167 fx 钉 0 前置门整挡吸收）；
	# boost 关 → DEATHPOP_FX_CAP 原值（r230_k2 哨兵四态逐位）。
	return mini(DEATHPOP_FX_CAP, 4) if PerfGovernor.boost_mode() else DEATHPOP_FX_CAP


static func _death_fx_admit(p_is_boss: bool, p_is_elite: bool) -> bool:
	# 演出件发射许可口（DeathPop.pop/PoisonSplash.pop 唯一入口；门外恒 true 零扰动）。
	# 豁免序：Boss 全保留 → 精英 1/2 采样 → 并发帽（未满直过 / 满则最老抢占让位）。
	# 被帽件只拦表现不拦结算——调用点（_on_died/_death_poison_splash）死亡链路照走。
	if not _deathpop_cap_on():
		return true
	if p_is_boss:
		return true
	if p_is_elite:
		_death_fx_elite_tick += 1
		if _death_fx_elite_tick % 2 != 1:
			DebugStats.count(&"deathpop_capped")
			return false
	_death_fx_purge()
	if _death_fx_live.size() < _death_fx_cap_now():   # R269：帽值经 _death_fx_cap_now（boost 开收缩 4）
		return true
	if _death_fx_preempt_oldest():
		return true
	return false                              # 防御臂：注册表无可让位件（理论不可达）——
	                                          # 按帽拒绝并计数，不静默吞


static func _death_fx_track(p_item: Node2D) -> void:
	# 入册（非 Boss 件 acquire 成功后调用；O(1) 尾插，创建序=队序——绘制/生命周期零影响）
	_death_fx_live.append(p_item)


static func _death_fx_untrack(p_item: Node2D) -> void:
	# 销册（两内嵌类 _release 唯一出口调用；幂等——Boss 件/外来件不在册静默返回）
	_death_fx_live.erase(p_item)


static func _death_fx_purge() -> void:
	# 清悬空引用（场景重开/宿主清空时 queue_free 的件不经 _release——admit 前置压缩；
	# 注册表 ≤帽量级、逆序 remove 零成本）
	for i in range(_death_fx_live.size() - 1, -1, -1):
		if not is_instance_valid(_death_fx_live[i]):
			_death_fx_live.remove_at(i)


static func _death_fx_preempt_oldest() -> bool:
	# 最老抢占：注册表队头（最老）演出件提前收尾让位——原位隐藏入池/超池弃用（_release
	# 既有协议），「老爆闪早熄」可观测降级（R226 披露口径），逐件计帽N。
	# 先出册再 _release（untrack 幂等无双重记账）；类分派显式（call() 走静态方法跨版本
	# 行为不稳，不用）。
	while not _death_fx_live.is_empty():
		var item: Node2D = _death_fx_live.pop_front()
		if item is DeathPop:
			DeathPop._release(item)
			DebugStats.count(&"deathpop_capped")
			return true
		elif item is PoisonSplash:
			PoisonSplash._release(item)
			DebugStats.count(&"deathpop_capped")
			return true
	return false


func _ready() -> void:
	# 池化实例化期组装（代码组装为主，.tscn 仅做容器，§1.4）
	_sprite = Sprite2D.new()
	_sprite.name = "Visual"
	_sprite.centered = true
	_sprite.texture = TextureFactory.enemy_tex(&"grunt")
	_material = ShaderMaterial.new()
	_material.shader = _get_flash_shader()
	# R202 ③：闪白窗外不挂材质（常态恢复 2D 批处理——逐实例 ShaderMaterial 常驻会
	# 打断同图集批处理；起闪 _apply_flash(>0) 挂回、窗外摘除，_material 随池存活零新建）
	add_child(_sprite)
	if not CONTACT_RADIAL:
		_build_contact_area()
	DebugStats.bucket_begin(&"telegraph")   # R269：警µs 桶（创建/挂树/配置——只加计时不改行为）
	_fuse_ring = Telegraph.TelegraphCircle.new()
	_fuse_ring.name = "FuseRing"
	_fuse_ring.radius = VOLATILE_BLAST_RADIUS
	_fuse_ring.color = Color(1.0, 0.36, 0.36)    # 红 = 爆炸（§1.2 色彩语义；FuseRing 原配色）
	_fuse_ring.visible = false
	add_child(_fuse_ring)
	DebugStats.bucket_end(&"telegraph")
	visible = false                            # 池内不可见（取出 spawn 后激活）
	# R202 ①：fx_quality 缓存订阅（每实例一连、共写 static 单值——见声明处口径注释）
	Meta.settings_changed.connect(_on_fx_quality_setting)
	if _fx_quality_cache < 0:
		_fx_quality_cache = clampi(int(Meta.settings(&"fx_quality")), 0, 2)


func _build_contact_area() -> void:
	# R237 清退刀抽函数（原 _ready 内联块——off 态逐字原语义）：敌 HitArea 构建+接线。
	# R235 搭车①：mask 收窄——默认 layer=1/mask=1 下全场敌-敌互相监测纯浪费（桌面实测
	# 全成本 ≤1ms 非主头，真机 A/B 待证）。mask=2 + player.collision_layer=3：敌只与
	# 玩家配对（信号过滤 _on_contact_area 本就只认 Player，语义逐位）。
	_hit_area = Area2D.new()
	_hit_area.name = "HitArea"
	_hit_area.collision_mask = 2
	_hit_shape = CollisionShape2D.new()
	_hit_shape.name = "HitShape"
	_hit_area.add_child(_hit_shape)
	add_child(_hit_area)
	# R202 ②：接触伤害改物理信号驱动缓存（area_entered/exited 维护 _contact_player，
	# tick 读旗结算——消除原每敌每帧 get_overlapping_areas() 数组分配（probe_heat_scan
	# [B] 实测 0.288µs/次 ×N敌×60Hz 纯税）。判定真源仍 = 物理圆重叠（enemy shape 半径
	# = hitbox_r + player.hitbox_radius=16——与 projectile_base.gd:326-333 双半径和
	# 口径同源）。R202 否决「tick 内直算圆距」的历史注记被 R237 CONTACT_RADIAL 开关
	# 承接：on 态即直判变体（测试语义迁移随包裁定），off 默认态白名单语义不动。
	_hit_area.area_entered.connect(_on_contact_area)
	_hit_area.area_exited.connect(_on_contact_area_left)


func _on_fx_quality_setting(p_key: String) -> void:
	# settings_changed 订阅侧（R202 ①）：仅 fx_quality 键刷新缓存
	if p_key == &"fx_quality":
		_fx_quality_cache = clampi(int(Meta.settings(&"fx_quality")), 0, 2)


func _on_contact_area(p_area: Area2D) -> void:
	# R202 ②：接触重叠进入（玩家本体 extends Area2D——旧轮询 `area is Player` 同过滤）
	if p_area is Player:
		_contact_player = p_area


func _on_contact_area_left(p_area: Area2D) -> void:
	# R202 ②：接触重叠退出（清旗；玩家被释放的悬挂引用由 tick 读旗处 is_instance_valid 兜底）
	if p_area == _contact_player:
		_contact_player = null


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
	# N01/R199：Boss 血量去双重波次成长——hp_base 已是设计出场波血量（BOSS_DEBUT_WAVE），
	# 改按「实际波 − 设计出场波」差值成长；出场波未收录的 Boss id 与普通敌保持旧口径。
	var hp_exp := w - 1.0
	if (tags & (GameConst.TAG_BOSS | GameConst.TAG_FINAL_BOSS)) != 0 and BOSS_DEBUT_WAVE.has(data.id):
		hp_exp = maxf(w - float(BOSS_DEBUT_WAVE[data.id]), 0.0)
	max_hp = data.hp_base * pow(hp_growth, hp_exp) * e_hp
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
	elem_immune = data.elem_immune
	# 夜间R5 状态免疫桥接（实锤：elem_immune 只管伤害侧，immune_mask 状态侧从未
	# 接线——火免疫怪照样被点燃/冰免疫怪照样被冻结，F-17 免疫矩阵缺半边）：
	# 元素伤害免疫怪不吃对应元素状态；Boss 默认免定身（F-17：保留寒滞+易伤）
	if (elem_immune & GameConst.ELEM_IMMUNE_FIR) != 0:
		immune_mask |= GameConst.IMMUNE_BURN
	if (elem_immune & GameConst.ELEM_IMMUNE_ICE) != 0:
		immune_mask |= GameConst.IMMUNE_CHILL | GameConst.IMMUNE_FREEZE
	if (elem_immune & GameConst.ELEM_IMMUNE_LTG) != 0:
		immune_mask |= GameConst.IMMUNE_SHOCK
	if is_boss():
		immune_mask |= GameConst.IMMUNE_FREEZE
	dead = false
	_reset_marks()                              # R187 通用标记通道随出生清零（池复用防陈旧前科）
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
	# R72 新形态机制快照（special 驱动；见成员块注释）
	_frontal_shield = clampf(float(data.special.get("frontal_shield", 0.0)), 0.0, 0.95)
	_shield_arc = deg_to_rad(clampf(float(data.special.get("shield_arc", 110.0)), 20.0, 180.0))
	_reflect_cd_max = maxf(float(data.special.get("reflect_cd", 0.0)), 0.0)
	_reflect_cd = 0.0                          # 出生即就绪（首弹必弹——威胁立现；此后走冷却）
	_is_caster = bool(data.special.get("spell", false))
	_spell_cfg = {
		"radius": maxf(float(data.special.get("spell_radius", 95.0)), 20.0),
		"delay": maxf(float(data.special.get("spell_delay", 0.9)), 0.3),
		"atk_ratio": clampf(float(data.special.get("spell_atk_ratio", 1.0)), 0.1, 3.0),
	}
	_aim_lead = bool(data.special.get("aim_lead", false))
	_player_vel_est = Vector2.ZERO
	_last_player_pos = Vector2.INF
	if is_boss():
		poise_max = maxf(float(data.boss.get("poise_max", 50.0)), 0.0)
		_chg_cfg = data.boss.get("charge", {})
		if not _chg_cfg.is_empty():
			_chg_cd = 4.0                            # 开场缓冲
	_flash_left = 0.0
	_fade_left = FADE_IN_TIME
	_wobble_left = 0.0
	_face_state = 0
	_anim_t = 0.0
	_boss_orbit = 0.0
	_boss_angry = false
	elite_affixes = []
	_affix_cd = []
	_affix_casting = -1
	if not is_boss() and is_elite():
		for a in data.elite_affixes:
			if AFFIX_DEFS.has(a) and not elite_affixes.has(a):
				elite_affixes.append(a)
				_affix_cd.append(maxf(float(AFFIX_DEFS[a]["cd"]) * 0.5, 2.0))   # 开场半冷却错相
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


func ip_birth_snap() -> void:
	# R233 T6 决策3.1：spawn 置位——插值缓冲 prev=curr=出生位（防池上家残位飞入 +
	# 中途 spawn 无跳变）。出生位在 spawner 挂位（position 赋值）后才定型，故本口由
	# spawner 置位后调用（enemy_spawner.tick）；测试夹具直spawn+挂位同款复用。
	_ip_prev = global_position
	_ip_curr = global_position
	# R238 修（H5 接触信号缓存缺口·workflow 诊断实证）：敌在重叠态被归池、又在重叠位
	# 复用时，物理对持续重叠不产生新 area_entered → _contact_player 永不 arm=贴身接触
	# 伤不结算（护盾条充满也永不被触发的面）。本口=出生位定型点，在此按双半径和口径
	# （hitbox_r+hitbox_radius，与物理圆重叠同源）做一次距离预判补 arm——spawn 内不做
	# （位置尚为池上家残留位，判定失真）。信号通道语义不变：后续 area_exited 照常清
	# 旗；CONTACT_RADIAL on 态走直判不依赖本缓存。
	var pl := _player()
	if pl != null and is_instance_valid(pl):
		var reach := hitbox_r + float(pl.hitbox_radius)
		if global_position.distance_squared_to(pl.global_position) <= reach * reach:
			_contact_player = pl


func tick(p_game_delta: float) -> void:
	# 行为机（追击/远程）+ 状态效果速度因子 + 接触伤害 + Boss 阶段检查
	if dead:
		return
	_reset_frame_geom()
	_tick_visual(p_game_delta)
	if _fade_left > 0.0:
		_fade_left -= p_game_delta
		# R217 刀A：渐显量化 4 档（连续 alpha 逐敌唯一=出生窗断批；0.12s 内四步肉眼无感）
		var fa := clampf(1.0 - _fade_left / FADE_IN_TIME, 0.0, 1.0)
		modulate.a = roundf(fa * 3.0) / 3.0
	if _flash_left > 0.0:
		_flash_left -= p_game_delta
		_apply_flash(clampf(_flash_left / FLASH_TIME, 0.0, 1.0))   # 窗口末帧量归 0 → _apply_flash 摘材质（R202 ③）
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
	# R187 通用标记通道计时推进（game_delta 通道——顿帧自然冻结；到期归零不清前科：
	# 前科防的是「只减不清」的池复用残留，清零统一收口在 spawn/_on_died/_reset_state 三处）
	if fuse_mark_left > 0.0:
		fuse_mark_left = maxf(fuse_mark_left - p_game_delta, 0.0)
	if fuse_detonate_guard_left > 0.0:
		fuse_detonate_guard_left = maxf(fuse_detonate_guard_left - p_game_delta, 0.0)
	if charge_gain_cd_left > 0.0:
		charge_gain_cd_left = maxf(charge_gain_cd_left - p_game_delta, 0.0)
	if detonate_icd_left > 0.0:
		detonate_icd_left = maxf(detonate_icd_left - p_game_delta, 0.0)
	var player := _player()
	# 击退冲量衰减位移（R7：与追击位移叠加，指数衰减——9/s 阻尼约 0.11s 消散）
	if knock_vel != Vector2.ZERO:
		global_position += knock_vel * p_game_delta
		knock_vel = knock_vel.lerp(Vector2.ZERO, minf(9.0 * p_game_delta, 1.0))
	# R72 射箭兵提前量：玩家速度估计（逐帧差分 + 平滑；供 _fire_at 提前量解算）
	if player != null:
		if _last_player_pos != Vector2.INF:
			var pv := (player.global_position - _last_player_pos) / maxf(p_game_delta, 0.001)
			_player_vel_est = _player_vel_est.lerp(pv, 0.35)
		_last_player_pos = player.global_position
	# R72 反弹盾冷却推进
	if _reflect_cd > 0.0:
		_reflect_cd = maxf(_reflect_cd - p_game_delta, 0.0)
	match behavior:
		GameConst.EnemyBehavior.CHASE:
			if player != null:
				if _kind == &"dart" or _kind == &"woodbird" or _kind == &"bogleaper":
					_tick_dart_chase(p_game_delta, player, sf)
				else:
					var dir := _get_dir_to_player(player)
					var spd := speed * sf * _enrage_speed_mult * (0.0 if _stagger_left > 0.0 else 1.0)   # R18 P3 狂暴提速；R23 硬直停摆
					if _fuse_armed:
						spd = VOLATILE_CHARGE_SPEED    # 警报后冲刺（A3 §2.2 E4 行；自爆冲刺不受寒滞减速修正口径）
					global_position += dir * spd * p_game_delta
					_reset_frame_geom()
					_tick_volatile_fuse(p_game_delta, player)
			if is_boss():
				# R23：硬直期停摆（不移动不放技能），韧性免疫窗照常衰减
				if _stagger_left > 0.0:
					_stagger_left = maxf(_stagger_left - p_game_delta, 0.0)
					_poise_immune_left = maxf(_poise_immune_left - p_game_delta, 0.0)
				else:
					_tick_boss_barrage(p_game_delta, player, sf)
					_tick_boss_charge(p_game_delta, player, sf)
			elif not elite_affixes.is_empty():
				# 夜间R39：精英词缀技 tick（硬直同 Boss 口径停摆；冻结打断在 tick 内判定）
				if _stagger_left > 0.0:
					_stagger_left = maxf(_stagger_left - p_game_delta, 0.0)
				else:
					_tick_elite_affixes(p_game_delta, player, sf)
		GameConst.EnemyBehavior.RANGED:
			_tick_ranged(p_game_delta, player, sf)
		GameConst.EnemyBehavior.BLINK:
			_tick_blink(p_game_delta, player, sf)
		_:
			pass
	# c4③ 非 CHASE 精英词缀复活（二cp#1：RANGED/BLINK 精英的金冠词缀 tick 从未推进——
	# enemy_spawner._elite_affix_roll 无 behavior 过滤=投放面早已存在，词缀挂上即死卡，
	# E7_spitter/E24_rift_demon 等六种族金冠全灭）：match 块后独立段照抄 CHASE 分支
	#（:802-807）同款硬直停摆口径；player 可空语义与 CHASE 现状一致——
	# _tick_elite_affixes 内部自带 p_player==null/projectile_pool 判空守卫
	if behavior != GameConst.EnemyBehavior.CHASE and not elite_affixes.is_empty():
		if _stagger_left > 0.0:
			_stagger_left = maxf(_stagger_left - p_game_delta, 0.0)
		else:
			_tick_elite_affixes(p_game_delta, player, sf)
	# 接触伤害（R202 ②：物理信号驱动缓存替代 Area2D overlap 轮询——原每敌每帧
	# get_overlapping_areas() 返回新数组（probe_heat_scan [B] 实测 0.288µs/次 ×N敌×60Hz
	# 纯分配税），改 _on_contact_area 维护 _contact_player 旗 + tick 读旗结算；
	# 判定真源仍为物理圆重叠（enemy shape 半径 = hitbox_r + player.hitbox_radius=16，
	# 双半径和口径与 projectile_base.gd:326-333 同源）。局内语义与原轮询逐位一致：
	# 重叠起于物理帧、玩家侧无敌帧 contact_tick 节流闸在 take_contact_damage 内不变、
	# E4 引爆触发线 VOLATILE_TRIGGER_SLACK 口径不变。实现取舍注释见 _ready 接线处）
	# R237 清退刀：CONTACT_RADIAL on=tick 内双半径直判（距离²比较零分配零 sqrt；
	# 口径与物理圆重叠同源=hitbox_r+player.hitbox_radius，E4 引爆线走自身
	# VOLATILE_TRIGGER_SLACK 独立通道不受本刀影响）；off=信号通道原语义（R202 ②）。
	# 二cv#6 近战敌贴脸豁免（贴脸保护）：追击型（CHASE）非 Boss 敌与玩家距离落入
	# 「已装备近战武器补刀刃圈」（player.melee_sanctuary_r，无近战武器恒 0=守卫恒假
	# 零扰动）→ 接触伤害整体豁免。接触距离（双半径和≈30px）恒 ⊂ 刃圈（≥150px），
	# 故实际语义=持近战武器时追击敌贴身磨血豁免（FEEDBACK_TRACKER 二cv#6 原话
	# 「补刀范围内就不要生效了」）；E2 疾冲命中回弹与精英 charger×1.25 伤害同走本
	# 结算口自动覆盖（词缀乘区随豁免一并失效）。Boss 冲锋伤害同走本通道
	# （_tick_boss_charge 注：接触伤害由 Area2D 触碰通道承担）故必须 is_boss() 排除；
	# RANGED/BLINK/DASHER 行为与 E4 引爆/E12 毒爆/法术圈/闪现引爆等独立通道不在守卫面
	#（DASHER 当前无近战实例敌——resources/enemies 零该 behavior 落地、E2_runner 缺省
	# CHASE 在面内；未来新增近战型 DASHER 不享受贴脸豁免，届时需复评守卫面语义——二cv
	# QA 边界记录）。
	# 判读计数只在「本会结算」的重叠处自增（刃圈内未贴脸的常规抑制不计防 60Hz 膨胀）。
	var sanctuary := false
	if player != null and player is Player and behavior == GameConst.EnemyBehavior.CHASE \
			and not is_boss():
		var sanctuary_r: float = (player as Player).melee_sanctuary_r
		if sanctuary_r > 0.0:
			sanctuary = _dist_sq_to_player <= sanctuary_r * sanctuary_r if _ensure_frame_geom(player) \
				else global_position.distance_squared_to(player.global_position) <= sanctuary_r * sanctuary_r
	if CONTACT_RADIAL:
		var pl := _player()
		if pl != null and is_instance_valid(pl):
			var reach := hitbox_r + float(pl.hitbox_radius)
			var dsq := _dist_sq_to_player if _ensure_frame_geom(pl) else global_position.distance_squared_to(pl.global_position)
			if dsq <= reach * reach:
				if sanctuary:
					DebugStats.count(&"melee_enemy_suppressed")
				else:
					pl.take_contact_damage(contact_dmg * _affix_dmg_mult)
	elif _hit_area != null and _contact_player != null and is_instance_valid(_contact_player):
		if sanctuary:
			DebugStats.count(&"melee_enemy_suppressed")
		else:
			_contact_player.take_contact_damage(contact_dmg * _affix_dmg_mult)
	_check_boss_phase()


func take_result(p_result: DamageResult) -> void:
	# 受击入口（pipeline 步骤 9 之后由投射物侧调用）：扣血 + 受击闪白/果冻抖动 + 死亡广播
	# 易伤标记：包 3 ElementalSystem 合入后经 elemental 容器承担（get_vuln_factor 已就绪）
	# R72 带盾兵（壁垒枪兵）：盾面面向玩家——命中来向在盾弧内 → 伤害 ×(1−减伤比)
	# （绕后/侧翼全伤害；测向用命中点向量 vs 「自身→玩家」向量点积，≥ 半弧余弦即正面）
	var final_dmg := p_result.final_value
	if _frontal_shield > 0.0:
		var shield_player := _player()
		if shield_player != null and is_instance_valid(shield_player):
			var to_hit := (p_result.pos - global_position).normalized()
			var to_player := _get_dir_to_player(shield_player) if _ensure_frame_geom(shield_player) \
				else (shield_player.global_position - global_position).normalized()
			if to_hit.dot(to_player) >= cos(_shield_arc * 0.5):
				final_dmg *= (1.0 - _frontal_shield)
	apply_damage(final_dmg)
	if is_boss() and poise_max > 0.0 and final_dmg > 0.0:
		_accumulate_poise(final_dmg)
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


func is_elem_immune(p_element: int) -> bool:
	# 元素伤害免疫查询（R22 P1）：免疫 = 伤害归零 + 元素附着拒绝
	return (elem_immune & (1 << p_element)) != 0


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
	# R251 需求①：武装后引爆且未伤人 = 玩家躲过自爆 → mine_dodged 授闪避护盾（与 BossMine
	# :3411 同构：hit 旗先置位、发射在玩家有效性守卫之外——p_player 失效时 was_armed 成立
	# 照发，由 player._on_mine_dodged 的 _dead 守卫吸收；armed = 玩家曾贴脸，威胁结构性成立）
	var was_armed := _fuse_armed               # 清零前捕获（R251 头号陷阱：后清即丢武装记忆）
	_fuse_armed = false
	_fuse_left = 0.0
	_fuse_ring.visible = false
	var hit := false
	if p_player != null and is_instance_valid(p_player):
		if global_position.distance_to(p_player.global_position) <= VOLATILE_BLAST_RADIUS:
			(p_player as Player).take_contact_damage(contact_dmg * _affix_dmg_mult)
			hit = true
	EventBus.emit_kill_blast(global_position, VOLATILE_BLAST_RADIUS * 0.6)   # 爆炸环表现
	                                                              #（复用通道；R251 QA A-1 提前办理
	                                                              # 设计 §6.2 #3——躲爆因果读感四源对齐，
	                                                              # BossMine :3437 同款 0.6 折算）
	if not hit and was_armed:
		EventBus.emit_mine_dodged(global_position)   # 躲过敌方爆炸（自爆虫）——未伤人授橙盾
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


func defuse_if_armed() -> bool:
	# R266 公开清引导口（GameLoop 模态冻结用）：引导中（fuse_armed）→ 打断引导回普通
	# 追击（复用击退打断 _cancel_fuse 语义：警示圈收起，可再次接触重新引导）。
	# 动机：升级选卡/暂停把玩家冻结在原地，弹卡瞬间已贴脸引导中的爆虫收卡后残余引信
	# 不足（贴脸冲刺 260px/s + 爆炸半径 110px——剩 <0.5s 数学上躲不掉=「选卡被炸」
	# 体感）；进模态时清引导=收卡后重新接触重新计 1.2s，玩家有完整反应窗。
	if not _fuse_armed:
		return false
	_cancel_fuse()
	return true


# ── R187 通用标记通道 API（共享组；W6/W7 引信 + W8 蓄能唯一写入口） ──
func _reset_marks() -> void:
	# 标记通道清零（spawn / _on_died / _reset_state 三路统一收口——池复用防陈旧前科）
	fuse_mark_left = 0.0
	fuse_coat_amp = 1.0
	fuse_detonate_guard_left = 0.0
	charge_stacks = 0
	charge_gain_cd_left = 0.0
	detonate_icd_left = 0.0


func apply_fuse_mark(p_duration: float, p_amp: float = 1.0) -> void:
	# 引信涂层挂标（MEC_FUSE_COAT 消费口）：幂等刷新——重复命中取 max（不叠加时长/
	# 增伤倍率，层数增伤随标记落敌身）；A3 §2.3「4s 幂等刷新」口径 + §2.3.5 目标侧 amp
	fuse_mark_left = maxf(fuse_mark_left, maxf(p_duration, 0.0))
	fuse_coat_amp = maxf(fuse_coat_amp, maxf(p_amp, 1.0))


func has_fuse_mark() -> bool:
	# 引信在身判定（W7 定向爆破消费口 + 测试观测口）
	return fuse_mark_left > 0.0


func add_charge_stacks(p_delta: int, p_cap: int) -> int:
	# 蓄能叠档（W8 接触/脉冲消费口）：目标 uid 全局单例——本体+复制体同孔加速；
	# p_cap ≤0 视为无帽（调用方传 charge_max）。返回叠后档位。
	charge_stacks = clampi(charge_stacks + maxi(p_delta, 0), 0, maxi(p_cap, charge_stacks))
	charge_cap = maxi(p_cap, charge_stacks)
	queue_redraw()                            # R187 §2.5.10：头顶「蓄能 x/5」读数随档重绘
	return charge_stacks


func clear_charge_stacks() -> void:
	# 满档引爆后清零重蓄（W8 引爆消费口）
	charge_stacks = 0
	queue_redraw()


func _draw() -> void:
	# R271 P4：绘µs wrap（自绘件 _draw 计时入 &"draw" 桶——只加计不改行为；
	# 原体迁 _draw_r271，早退 return 由委托面兜底不漏收口）
	DebugStats.bucket_begin(&"draw")
	_draw_r271()
	DebugStats.bucket_end(&"draw")


func _draw_r271() -> void:
	# R187 §2.5.10 验收项：W8 蓄能目标头顶「蓄能 x/5」档位读数。无 W8 参战时
	# charge_stacks 恒 0 → 零绘制；queue_redraw 只在叠档/引爆清零时触发，无常驻成本。
	if charge_stacks <= 0:
		return
	var font := ThemeDB.fallback_font
	if font == null:
		return
	var label := "蓄能 %d/%d" % [charge_stacks, maxi(charge_cap, charge_stacks)]
	draw_string(font, Vector2(-30.0, -34.0), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1.0, 0.76, 0.28))


static var live_count: int = 0                 # R189c：在树活敌数（顿帧密集场「敌 >N」判据——§4.4 设计口径）


func _enter_tree() -> void:
	live_count += 1


func _exit_tree() -> void:
	live_count = maxi(live_count - 1, 0)


func is_boss() -> bool:
	return (tags & GameConst.TAG_BOSS) != 0


func is_elite() -> bool:
	return (tags & GameConst.TAG_ELITE) != 0


func _on_died() -> void:
	# 一次性死亡：置 dead → EventBus.emit_enemy_killed → 池归还（EnemySpawner 订阅承担）
	# R285 T3：死亡链拆分——inline 面（dead 旗+marks 清零）保持即时（死亡短路/E-06
	# 一次性语义不动）；fan-out 四件（DeathPop/毒溅/元素释放/击杀广播）在 boost 死亡
	# 冲刷模式（〔v2·M2〕静态 bool 帧级缓存）下入队、冲刷点统一执行（快照计数制），
	# 关态直调与现网调用序逐字相同。RNG/读数漂移声明见 _death_fanout 头注。
	dead = true
	_reset_marks()                              # R187 敌亡回收：引信/蓄能随死亡清零
	                                            #（蓄能池以 uid 单例——亡敌残留档位会污染复用实例）
	if GameLoop.death_flush_frame:
		GameLoop.enqueue_death(self)
	else:
		_death_fanout()


func _death_fanout() -> void:
	# 原 _on_died 尾段（DeathPop→毒溅→元素释放→emit_enemy_killed）逐字搬移——
	# R285 T3 冲刷段（命中杀在冲刷点①/④尾、DOT·反应杀在冲刷点②/⑤尾、意外入队在
	# 兜底点③/帧末统一执行）。
	# ── R285 同帧多杀击杀连锁读数漂移声明（boost 开侧限定；设计 §3.1.5 声明④/
	# §0.2 迁移点④）── dead 旗全部在入队时点（apply_damage 时点）置位、先于任何
	# fan-out 执行：燎原 _on_enemy_killed_spread_burn 的 dead 过滤目标集较关态收窄
	# （关态下 A 死时同帧稍后才死的 B 仍活可被满槽点燃，T3 下 B 已 dead 被跳过=燎原
	# DOT 伤害分布单向收窄漂移）；连杀狂热/精英首杀/回声·共鸣叠层在后续命中乘区的
	# 读数同族漂移。**承诺不变面**：伤害数值分布、命中率统计、穿透/去重契约、
	# fan-out 内部派发序（挂载序）——击杀连锁读数漂移明示不在承诺内，按统计带验收。
	# boost 关侧零入队零延迟（fan-out 即时，pkg4 零位移）。
	var timed := GameLoop.prof_buckets_frame
	if timed:
		DebugStats.bucket_begin(&"death_flush")     # R285 P0：灭µs（fan-out 冲刷段——R286 行键名避撞 R269 死µs；关态也累计）
	# R19 打击质感：死亡弹爆（白环扩散 + 四向碎屑，0.2s 自清——击杀瞬间重量感）
	# R188 档0：入池复用（DeathPop.pop——原每杀 instantiate+自毁）
	if get_parent() != null and _fx_q() > 0:
		# R230 K2c：豁免旗随件下传（Boss 全保留/精英 1/2/普通按帽）——许可口只拦表现，
		# 下方 emit_enemy_killed 死亡结算链零触碰
		DeathPop.pop(get_parent(), global_position, _death_element_tint(),   # G5：死因元素迸色
			is_boss(), is_elite())
	_death_poison_splash()
	_death_element_discharge()
	EventBus.emit_enemy_killed(self)
	if timed:
		DebugStats.bucket_end(&"death_flush")


func _death_element_tint() -> Color:
	# G5 死因元素染色：死亡瞬间元素槽最高者决定迸色（阈值 25——挂零元素不染）；
	# base 全部取色表单源 PopPalette.ELEMENT_COLORS（派生 lerp 结构保留）：
	# 火=表橙偏金 / 冰=表冰蓝提亮 / 雷=表电紫 / 水/风/岩/草=表色直读（R192 八元素）
	if elemental == null:
		return Color.WHITE
	var best := GameConst.Element.KIN
	var best_gauge := 25.0
	for e in range(elemental.gauges.size()):
		var g := float(elemental.gauges[e])
		if g > best_gauge:
			best_gauge = g
			best = e
	match best:
		GameConst.Element.FIR:
			return PopPalette.ELEMENT_COLORS[GameConst.Element.FIR].lerp(PopPalette.XP, 0.55)
		GameConst.Element.ICE:
			return PopPalette.ELEMENT_COLORS[GameConst.Element.ICE].lerp(Color.WHITE, 0.5)
		GameConst.Element.LTG:
			return PopPalette.ELEMENT_COLORS[GameConst.Element.LTG].lerp(Color.WHITE, 0.2)
		GameConst.Element.HYD, GameConst.Element.ANE, GameConst.Element.GEO, \
		GameConst.Element.DEN:
			return PopPalette.ELEMENT_COLORS[best]
		_:
			return Color.WHITE


func _death_poison_splash() -> void:
	# 毒泡史莱姆（E12）死亡毒爆（用户反馈「沼泽怪物毒相关」）：半径 110 内玩家吃
	# contact_dmg × 60% + 绿色毒环残效（一次性表现件挂父层自消——死亡瞬发低频可接受）
	if data == null or not String(data.id).begins_with("E12"):
		return
	var player := _player()
	if player != null and is_instance_valid(player) \
			and global_position.distance_to(player.global_position) <= BOG_SPLASH_RADIUS:
		(player as Player).take_contact_damage(contact_dmg * BOG_SPLASH_RATIO)
	# R188 档0：毒环残效入池复用（PoisonSplash.pop——原每杀 instantiate+自毁）
	# R230 K2c：豁免旗随件下传（毒环伤害结算在上方照走，许可口只拦表现件）
	PoisonSplash.pop(get_parent(), global_position, BOG_SPLASH_RADIUS * 0.7,
		is_boss(), is_elite())


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
	# R253 SpellRing 进度弧推进（_blink_ring 同款）：宿主活着推进读条重绘——原静态
	# 虚线圈玩家无从读条（c9a 缓办清账·表现补全）；宿主死亡/归还后停推（圈停最后
	# 进度，SceneTreeTimer 照炸=宿主无关引爆设计口径不动）
	if _spell_ring != null and is_instance_valid(_spell_ring) and _spell_delay > 0.0:
		_spell_ring.progress = minf(_spell_ring.progress + p_game_delta / _spell_delay, 1.0)
		_spell_ring.queue_redraw()
	if fire_cd_left <= 0.0 and dist <= fire_range:
		# R72 法术兵（咒术师）：直射改法术圈——玩家脚下读条紫圈 → 延迟 AoE
		#（走位永远有解：读条 delay 给足移出半径的时间）
		if _is_caster:
			_cast_spell(p_player)
		else:
			_fire_at(p_player)
		fire_cd_left = fire_cd


func _fire_at(p_player: Node2D) -> void:
	# 敌弹发射（ballistic 场景池；散射 spread_deg；伤害=contact_dmg×bullet_atk_ratio）
	# c4②：传 team=1——软上限饱和时按保留配额挤掉最老玩家弹（默认 0 路径=纯丢弃）
	if projectile_pool == null:
		return
	var bullet := projectile_pool.acquire(1) as BallisticProjectile
	if bullet == null:
		return
	bullet.pool = projectile_pool
	var aim := p_player.global_position
	if _aim_lead:
		# R72 射箭兵（长弓隼卫）：提前量——飞行时间 × 玩家速度估计（0.9 收敛系数
		# 防 100% 命中；快弹速压缩走位窗 = 「被预判」的体感来源）
		var flight := global_position.distance_to(aim) / maxf(bullet_speed, 1.0)
		aim += _player_vel_est * flight * 0.9
	var dir := (aim - global_position).normalized()
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



func _cast_spell(p_player: Node2D) -> void:
	# R72 法术兵施法：玩家位置钉紫圈（TelegraphCircle）→ delay 后引爆——圈内玩家吃
	# contact_dmg × atk_ratio；圈随 SceneTreeTimer 推进（process_always=false：暂停
	# 随战斗冻结，读条不偷跑）。施法者本体安全（远距威胁，逼走位不逼贴脸）
	if p_player == null or not is_instance_valid(p_player):
		return
	DebugStats.bucket_begin(&"telegraph")   # R269：警µs 桶（SpellRing 创建/挂树/配置）
	var ring := Telegraph.TelegraphCircle.new()
	ring.name = "SpellRing"
	ring.radius = float(_spell_cfg.get("radius", 95.0))
	ring.color = Color(0.62, 0.4, 1.0)          # 紫 = 法术/狙击读条（§1.2 语义）
	ring.position = p_player.global_position
	ring.progress = 0.0
	get_parent().add_child(ring)
	DebugStats.bucket_end(&"telegraph")
	var delay := float(_spell_cfg.get("delay", 0.9))
	_spell_ring = ring                          # R253 进度弧宿主引用（_tick_ranged 推进）
	_spell_delay = maxf(delay, 0.05)            # 防除零（delay 数据退化护栏）
	var tree := get_tree()
	if tree == null:
		ring.queue_free()
		DebugStats.count(&"perffx_qfree")        # R269：释N 计数（警示件 queue_free）
		return
	var timer := tree.create_timer(delay, false, false, true)
	var center: Vector2 = ring.position
	var radius := ring.radius
	timer.timeout.connect(func() -> void:
		_detonate_spell(center, radius)
		if is_instance_valid(ring):
			ring.queue_free()
			DebugStats.count(&"perffx_qfree"))    # R269：释N 计数（Telegraph 定时回收处）


func _detonate_spell(p_center: Vector2, p_radius: float) -> void:
	# 法术圈引爆（timer 回调；宿主可能已死/归还——按位置结算与宿主无关）
	# R251 需求①：圈生成即钉玩家脚下（_cast_spell 快照）→ 未伤人 = 真实走位躲开，发
	# mine_dodged 授橙盾（无威胁旗——圈心恒为施法帧玩家位，威胁结构性成立；发射位置
	# p_center 为捕获局部量，宿主池复用无残留）
	EventBus.emit_kill_blast(p_center, p_radius)   # 爆炸环表现（复用通道）
	var player := _player()
	var hit := false
	if player != null and is_instance_valid(player) 			and player.global_position.distance_to(p_center) <= p_radius:
		(player as Player).take_contact_damage(
			contact_dmg * float(_spell_cfg.get("atk_ratio", 1.0)))
		hit = true
	if not hit:
		EventBus.emit_mine_dodged(p_center)


func try_reflect_projectile(p_proj: Node) -> bool:
	# R72 反弹盾（秘纹守卫）：就绪期来弹整体折返——team 翻 1（敌弹）、速度改指向
	# 玩家、伤害按原弹面板 ×0.6；命中取消（不落血/不耗穿透）。冷却期伤害照常
	if _reflect_cd_max <= 0.0 or _reflect_cd > 0.0 or dead:
		return false
	_reflect_cd = _reflect_cd_max
	var vel_v: Variant = p_proj.get("velocity")
	var speed := (vel_v as Vector2).length() if vel_v is Vector2 else 320.0
	var player := _player()
	var dir := (player.global_position - global_position).normalized() 		if player != null and is_instance_valid(player) else -Vector2.UP
	p_proj.set("velocity", dir * maxf(speed, 300.0))
	p_proj.set("team", 1)
	var pool_v: Variant = p_proj.get("pool")     # R269 修1（评审中#1）：team 翻转点同步计数
	if pool_v is ProjectilePool:                 # +1（全库唯一翻转点；pool 注入缺失由 1Hz
		(pool_v as ProjectilePool).note_team1_flip()   # recount_team1 实扫自愈兜底）
	var snap_v: Variant = p_proj.get("panel_snapshot")
	if snap_v is Dictionary:
		var snap := (snap_v as Dictionary).duplicate()
		snap["base_atk"] = float(snap.get("base_atk", 10.0)) * 0.6
		p_proj.set("panel_snapshot", snap)
	EventBus.emit_bullet_nullified(global_position)   # 青涟漪表现（消弹同款）
	DebugStats.count(&"reflect_guard_bounce")
	return true

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
	# 落点 = 快照 ±24px 随机偏移（防贴脸重合），钳屏内；红圈挂世界层钉死落点。
	# 偏移按半径 ≤24px 圆盘均匀采样（§3.3 rand_offset(24)：到快照距离恒 ≤24——
	# 逐轴 ±24 方形采样角点最远 24√2 ≈ 34px，会破「落点 = 快照 ±24px」口径）
	var off := Vector2.from_angle(randf() * TAU) * (BLINK_OFFSET * sqrt(randf()))
	var size := Vector2(720.0, 1280.0)
	if GameConfig.balance != null:
		size = Vector2(GameConfig.balance.res_logic)
	global_position = (_blink_target + off).clamp(
		Vector2.ONE * hitbox_r, size - Vector2.ONE * hitbox_r)
	_blink_state = 2
	_blink_left = _blink_fuse
	_blink_threat = true                        # R251 需求①：落地引信期威胁成立（读条已锁定玩家位）
	DebugStats.bucket_begin(&"telegraph")   # R269：警µs 桶（BlinkRing 创建/挂树/配置）
	_blink_ring = Telegraph.TelegraphCircle.new()
	_blink_ring.name = "BlinkRing"
	_blink_ring.radius = _blink_blast_r
	_blink_ring.color = Color(1.0, 0.36, 0.36)    # 红 = 爆炸/定点 AOE（§1.2 语义）
	_blink_ring.position = _blink_target
	_blink_ring.progress = 0.0
	get_parent().add_child(_blink_ring)
	DebugStats.bucket_end(&"telegraph")


func _blink_explode(p_player: Node2D) -> void:
	# 引爆：半径内玩家吃 contact_dmg（30% 档 = dmg_base 波次成长值，E4 口径）；本体死亡
	# R251 需求①：落地引信期引爆且未伤人 = 玩家走位躲过闪现爆 → mine_dodged 授橙盾
	#（与 BossMine :3411 同构：发射在玩家有效性守卫之外；威胁门 = _blink_threat 落地置位）
	_clear_blink_ring()
	# 爆炸环特效（复用 kill_blast 表现通道：橙红环+闪光，纯表现无结算）
	EventBus.emit_kill_blast(global_position, _blink_blast_r)
	var hit := false
	if p_player != null and is_instance_valid(p_player) \
			and global_position.distance_to(p_player.global_position) <= _blink_blast_r:
		(p_player as Player).take_contact_damage(contact_dmg)
		hit = true
	if not hit and _blink_threat:
		EventBus.emit_mine_dodged(global_position)
	hp = 0.0
	_on_died()


func _cancel_blink(p_cd: float = -1.0) -> void:
	# 打断统一入口：冻结断读条 / 击退断引信（§3.3 反制双路）→ 回巡航；p_cd ≥0 时重置施法冷却
	#（R251 需求①：打断路径不发躲爆——威胁旗就地清零，未引燃不结算）
	_blink_state = 0
	_blink_left = 0.0
	_blink_threat = false
	if p_cd >= 0.0:
		_blink_cd = p_cd
	_clear_blink_ring()


func _clear_blink_ring() -> void:
	if _blink_ring != null and is_instance_valid(_blink_ring):
		_blink_ring.queue_free()
		DebugStats.count(&"perffx_qfree")      # R269：释N 计数（警示件 queue_free）
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
		EventBus.emit_boss_phase_changed(3, false)
	elif boss_phase < 2 and ratio <= float(data.boss.get("phase2_hp", 0.6)):
		_enter_boss_phase(2)
		EventBus.emit_boss_phase_changed(2, false)


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
		EventBus.emit_boss_phase_changed(0, true)   # phase=0 表狂暴（音效侧区分）


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
	if SfxBank.I != null and _sfx_q() > 0:      # R269：音效独立档口换读（boost 钉 0 不静音战斗）
		SfxBank.I.play(&"cast_warn")            # R23 前摇警示音
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
		DebugStats.bucket_begin(&"telegraph")   # R269：警µs 桶（CastFan 创建/挂树/配置——含池复用态）
		if _cast_fan == null:
			_cast_fan = Telegraph.TelegraphFan.new()
			_cast_fan.name = "CastFan"
			add_child(_cast_fan)
		_cast_fan.setup_dir(_cast_dir)
		_cast_fan.radius = maxf(150.0, float(_barrage[p_idx].get("speed", 300.0)) * _cast_total * 1.15)
		_cast_fan.arc_deg = float(_barrage[p_idx].get("arc_deg", 44.0))
		_cast_fan.progress = 0.0
		_cast_fan.visible = true
		DebugStats.bucket_end(&"telegraph")
	# laser_sweep：紫色直线警示带（B7 处决技——起角锁定，带内不追踪）
	elif String(_barrage[p_idx].get("type", "ring")) == "laser_sweep":
		_cast_dir = (p_player.global_position - global_position).normalized()
		if _cast_dir == Vector2.ZERO:
			_cast_dir = Vector2.RIGHT
		DebugStats.bucket_begin(&"telegraph")   # R269：警µs 桶（CastLine 创建/挂树/配置——含池复用态）
		if _cast_line == null:
			_cast_line = Telegraph.TelegraphLine.new()
			_cast_line.name = "CastLine"
			add_child(_cast_line)
		_cast_line.setup_dir(_cast_dir)
		_cast_line.width = float(_barrage[p_idx].get("width_px", 26.0))
		_cast_line.progress = 0.0
		_cast_line.visible = true
		DebugStats.bucket_end(&"telegraph")


func _release_cast(p_player: Node2D) -> void:
	# 前摇完成结算（Telegraph.finished 口径）：按型分发 → 重置该技能 cd → 收警示件
	var def: Dictionary = _barrage[_cast_idx]
	var type := String(def.get("type", "ring"))
	if SfxBank.I != null and _sfx_q() > 0:      # R269：音效独立档口换读（boost 钉 0 不静音战斗）
		SfxBank.I.play(&"cast_snap")            # R23 释放干脆音
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


func set_elite_affixes(p_affixes: Array) -> void:
	# 夜间R39 投放收口（spawner wave8+ 调用；data 引用由调用方替换为副本）。
	# 参数 untyped：call 通道传入数组经 Variant 装箱后与 Array[StringName] 形参失配
	elite_affixes = []
	_affix_cd = []
	_affix_casting = -1
	for a in p_affixes:
		var affix := StringName(String(a))
		if AFFIX_DEFS.has(affix) and not elite_affixes.has(affix):
			elite_affixes.append(affix)
			_affix_cd.append(maxf(float(AFFIX_DEFS[affix]["cd"]) * 0.5, 2.0))   # 开场半冷却错相


func _tick_elite_affixes(p_dt: float, p_player: Node2D, p_sf: float) -> void:
	# 夜间R39 精英词缀技机（§6）：独立冷却计时器（与 Boss 系统隔离）；冻结/寒滞
	# （p_sf==0 或 elemental freeze）打断前摇 + cd 退 50%——「冰系控制流对精英的差异化」
	if projectile_pool == null or p_player == null:
		return
	if p_sf <= 0.0 or _elite_frozen():
		if _affix_casting >= 0:               # 冻结打断：前摇取消 + cd 退 50%
			_affix_cancel_cast()
		return
	if _affix_dash_left > 0.0:
		# charger 冲刺段：1.9× 锁定方向（不吃寒滞口径同 E2）；撞界即收
		_affix_dash_left = maxf(_affix_dash_left - p_dt, 0.0)
		global_position += _affix_dash_dir * speed * DASH_SPEED_MULT * p_dt
		var size := Vector2(720.0, 1280.0)
		if GameConfig.balance != null:
			size = Vector2(GameConfig.balance.res_logic)
		var p := global_position
		if p.x <= hitbox_r or p.x >= size.x - hitbox_r 				or p.y <= hitbox_r or p.y >= size.y - hitbox_r:
			global_position = p.clamp(Vector2.ONE * float(hitbox_r), size - Vector2.ONE * float(hitbox_r))
			_affix_dash_left = 0.0
		if _affix_dash_left <= 0.0:
			_affix_dmg_mult = 1.0
		return
	if _affix_casting >= 0:
		_affix_cast_left = maxf(_affix_cast_left - p_dt, 0.0)
		_affix_push_telegraph()
		if _affix_cast_left <= 0.0:
			_affix_release(p_player)
		return
	for i in range(elite_affixes.size()):
		_affix_cd[i] = maxf(float(_affix_cd[i]) - p_dt, 0.0)
		if float(_affix_cd[i]) <= 0.0:
			_affix_begin(i, p_player)
			return


func _elite_frozen() -> bool:
	var el: Variant = get("elemental")
	return el is ElementalState and float((el as ElementalState).freeze_timer) > 0.0


func _affix_cancel_cast() -> void:
	# 打断：cd 退 50%（保留一半进度感）+ 收警示件
	var i := _affix_casting
	_affix_casting = -1
	if i >= 0 and i < _affix_cd.size():
		_affix_cd[i] = maxf(float(AFFIX_DEFS[elite_affixes[i]]["cd"]) * 0.5, 1.0)
	_affix_clear_telegraph()


func _affix_begin(p_idx: int, p_player: Node2D) -> void:
	_affix_casting = p_idx
	if SfxBank.I != null and _sfx_q() > 0:      # R269：音效独立档口换读（boost 钉 0 不静音战斗）
		SfxBank.I.play(&"cast_warn")        # 夜间R44：前摇警示音（与 Boss 技同政策）
	var def: Dictionary = AFFIX_DEFS[elite_affixes[p_idx]]
	_affix_cast_total = maxf(float(def["telegraph"]), 0.3)
	_affix_cast_left = _affix_cast_total
	if String(def["type"]) == "sniper":
		_affix_dir = (p_player.global_position - global_position).normalized()
		if _affix_dir == Vector2.ZERO:
			_affix_dir = Vector2.RIGHT
		if _affix_tel_fan == null:
			DebugStats.bucket_begin(&"telegraph")   # R269：警µs 桶（AffixFan 创建/挂树）
			_affix_tel_fan = Telegraph.TelegraphFan.new()
			_affix_tel_fan.name = "AffixFan"
			add_child(_affix_tel_fan)
			DebugStats.bucket_end(&"telegraph")
		_affix_tel_fan.setup_dir(_affix_dir)
		_affix_tel_fan.arc_deg = 24.0
		_affix_tel_fan.radius = 320.0
	elif _affix_tel_circle == null:
		DebugStats.bucket_begin(&"telegraph")   # R269：警µs 桶（AffixCircle 创建/挂树）
		_affix_tel_circle = Telegraph.TelegraphCircle.new()
		_affix_tel_circle.name = "AffixCircle"
		add_child(_affix_tel_circle)
		DebugStats.bucket_end(&"telegraph")
	if String(def["type"]) == "sniper":
		if _affix_tel_circle != null:
			_affix_tel_circle.visible = false
		_affix_tel_fan.visible = true
	else:
		if _affix_tel_fan != null:
			_affix_tel_fan.visible = false
		_affix_tel_circle.visible = true
		_affix_tel_circle.radius = 190.0 if String(def["type"]) != "trapper" else 110.0
	_affix_push_telegraph()


func _affix_push_telegraph() -> void:
	var prog := 1.0 - _affix_cast_left / maxf(_affix_cast_total, 0.01)
	if _affix_tel_circle != null and _affix_tel_circle.visible:
		_affix_tel_circle.progress = prog
		_affix_tel_circle.queue_redraw()
	if _affix_tel_fan != null and _affix_tel_fan.visible:
		_affix_tel_fan.progress = prog
		_affix_tel_fan.queue_redraw()


func _affix_clear_telegraph() -> void:
	# 显隐翻转（Boss cast_fan 同口径）：progress 清零 + 隐藏，节点池化复用
	if _affix_tel_circle != null:
		_affix_tel_circle.progress = 0.0
		_affix_tel_circle.visible = false
	if _affix_tel_fan != null:
		_affix_tel_fan.progress = 0.0
		_affix_tel_fan.visible = false


func _affix_release(p_player: Node2D) -> void:
	# 前摇完成执行（弱化参数真源 = ENEMY_BOSS_TELEGRAPH §6 表；伤害沿用平值）
	var i := _affix_casting
	_affix_casting = -1
	_affix_clear_telegraph()
	if SfxBank.I != null and _sfx_q() > 0:      # R269：音效独立档口换读（boost 钉 0 不静音战斗）
		SfxBank.I.play(&"cast_snap")        # 夜间R44：释放干脆音
	if i < 0 or i >= elite_affixes.size():
		return
	var affix: StringName = elite_affixes[i]
	_affix_cd[i] = maxf(float(AFFIX_DEFS[affix]["cd"]), 1.0)
	match affix:
		&"affix_ring":
			_fire_ring({"count": 8, "speed": 170.0, "dmg": 7.0})
		&"affix_sniper":
			_fire_spread({"count": 3, "arc_deg": 24.0, "speed": 300.0, "dmg": 11.0}, _affix_dir)
		&"affix_trapper":
			_spawn_mine_field({"count": 2, "blast_r": 80.0, "dmg": 15.0,
				"telegraph_s": 0.85}, p_player)
		&"affix_charger":
			# 单段冲刺（E2 状态机口径）：1.9× 速 0.35s 锁定方向；期间接触伤 ×1.25（25%）
			_affix_dash_dir = (p_player.global_position - global_position).normalized()
			if _affix_dash_dir == Vector2.ZERO:
				_affix_dash_dir = Vector2.RIGHT
			_affix_dash_left = DASH_GO_TIME
			_affix_dmg_mult = 1.25
		&"affix_caller":
			# 唤潮者：唤 1 只 E1_grunt（hp_ratio 0.5 / 场上限 2——cap 判定在 GameLoop 订阅侧）
			EventBus.emit_elite_summon_requested(uid, &"E1_grunt", global_position, 0.5)


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
	# c4②：传 team=1 走敌弹保留配额（Boss 弹幕真空根治——满场玩家弹不再吞掉 Boss 开火）
	var bullet := projectile_pool.acquire(1) as BallisticProjectile
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


# ── 韧性条（Poise，R23 P3） ──────────────────────────────────────────
func _accumulate_poise(p_damage: float) -> void:
	# 韧性伤害 = final × 0.01（DPS 500 基准 ≈10s 打满——「每 10 秒一次压制窗口」§2.1）
	if _poise_immune_left > 0.0:
		return
	poise = minf(poise + p_damage * 0.01, poise_max)
	if poise >= poise_max:
		_stagger()


func _stagger() -> void:
	# 硬直 1.2s：当前前摇取消 + 全技能 cd 退 50% + 韧性清空 + 6s 免疫窗
	#（B7 湮灭扫线施法免疫打断——cancel_cast 内口径）
	poise = 0.0
	_poise_immune_left = 6.0
	_stagger_left = 1.2
	cancel_cast()
	for j in range(_barrage_cd.size()):
		_barrage_cd[j] = maxf(float(_barrage_cd[j]) * 0.5, 0.0)


func cancel_cast() -> void:
	# 统一打断入口（§2.1）：清施法状态 + 警示件收起。
	# laser_sweep 施法免疫打断（§2 B7「处决技韧性条无效」——给玩家保留必须走位的绝对命题）
	if _cast_idx >= 0 and _cast_idx < _barrage.size() 			and String(_barrage[_cast_idx].get("type", "")) == "laser_sweep":
		return
	_cast_idx = -1
	_cast_left = 0.0
	if _cast_fan != null:
		_cast_fan.visible = false
	if _cast_line != null:
		_cast_line.visible = false


# ── B5 破裂冲锋（R23 P3：E18 charge 数据接线） ────────────────────────
func _tick_boss_charge(p_dt: float, p_player: Node2D, p_sf: float) -> void:
	# phase 门控三段冲锋：前摇橙条（方向锁定）→ 段冲刺 → 段间回气 → …… → 冷却。
	# 冲刺接触伤害由 Area2D 触碰通道承担；冻结/硬直停摆（上层 sf/门槛）。
	if _chg_cfg.is_empty() or p_player == null:
		return
	if int(_chg_cfg.get("phase", 2)) > boss_phase:
		return
	if p_sf <= 0.0:
		return
	match _chg_state:
		0:
			_chg_cd -= p_dt
			if _chg_cd <= 0.0:
				_chg_state = 1
				_chg_left = float(_chg_cfg.get("telegraph_s", 0.4))
				_chg_seg_left = int(_chg_cfg.get("segments", 3))   # 段数在周期起点一次性装载
				_chg_dir = (p_player.global_position - global_position).normalized()
				_ensure_chg_fan()
				_chg_fan.setup_dir(_chg_dir)
				_chg_fan.arc_deg = 24.0
				_chg_fan.radius = float(_chg_cfg.get("spd", 560.0)) * float(_chg_cfg.get("seg_time", 0.45))
				_chg_fan.progress = 0.0
				_chg_fan.color = Color(1.0, 0.62, 0.2)   # 橙 = 冲撞落点（§1.2）
				_chg_fan.visible = true
		1:
			_chg_left -= p_dt
			if _chg_fan != null and _chg_fan.visible:
				_chg_fan.progress = clampf(1.0 - _chg_left / maxf(float(_chg_cfg.get("telegraph_s", 0.4)), 0.01), 0.0, 1.0)
				_chg_fan.queue_redraw()
			if _chg_left <= 0.0:
				if _chg_fan != null:
					_chg_fan.visible = false
				_chg_state = 2
				_chg_left = float(_chg_cfg.get("seg_time", 0.45))
		2:
			global_position += _chg_dir * float(_chg_cfg.get("spd", 560.0)) * p_dt
			_chg_left -= p_dt
			var size := Vector2(720.0, 1280.0)
			if GameConfig.balance != null:
				size = Vector2(GameConfig.balance.res_logic)
			var hit_wall := global_position.x <= hitbox_r or global_position.x >= size.x - hitbox_r 				or global_position.y <= hitbox_r or global_position.y >= size.y - hitbox_r
			global_position = global_position.clamp(Vector2.ONE * hitbox_r, size - Vector2.ONE * hitbox_r)
			var near := global_position.distance_to(p_player.global_position) <= hitbox_r + 24.0
			if _chg_left <= 0.0 or hit_wall or near:
				_chg_seg_left -= 1
				if _chg_seg_left <= 0:
					_chg_state = 0
					_chg_cd = 9.0                       # B5 冷却（§2）
				else:
					_chg_state = 3
					_chg_left = float(_chg_cfg.get("gap_s", 0.55))
		3:
			_chg_left -= p_dt
			global_position -= _chg_dir * speed * 0.3 * p_dt   # 段间回气缓退
			if _chg_left <= 0.0:
				_chg_state = 1
				_chg_left = float(_chg_cfg.get("telegraph_s", 0.4))
				_chg_dir = (p_player.global_position - global_position).normalized()
				if _chg_fan != null:
					_chg_fan.setup_dir(_chg_dir)
					_chg_fan.progress = 0.0
					_chg_fan.visible = true


func _ensure_chg_fan() -> void:
	if _chg_fan == null:
		DebugStats.bucket_begin(&"telegraph")   # R269：警µs 桶（ChargeFan 创建/挂树）
		_chg_fan = Telegraph.TelegraphFan.new()
		_chg_fan.name = "ChargeFan"
		add_child(_chg_fan)
		DebugStats.bucket_end(&"telegraph")


func _reset_cast_state() -> void:
	# 池归还/spawn 双路复位（E-04/E-05 清零契约：施法位/计时/跟射/螺旋/表现件全清）
	_cast_idx = -1
	_cast_dir = Vector2.ZERO
	_cast_left = 0.0
	_cast_total = 0.4
	_pending_waves.clear()
	if _chg_fan != null:
		_chg_fan.visible = false
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
	# R72 新形态机制复位（池化归还清零——E-04）
	_reset_frame_geom()
	_mm_on = false                            # R240：镜像在册标志清零（unplace 已注销，
	                                          # 防池内 _apply_flash(0.0) 误判贴图路径）
	_frontal_shield = 0.0
	_shield_arc = deg_to_rad(110.0)
	_reflect_cd_max = 0.0
	_reflect_cd = 0.0
	_is_caster = false
	_spell_cfg = {}
	_aim_lead = false
	_player_vel_est = Vector2.ZERO
	_last_player_pos = Vector2.INF
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
	resist = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
	immune_mask = 0
	elem_immune = 0
	elemental = null
	ext_slow_mult = 1.0                       # 外部减速复位（P2：池归还清零契约同口径）
	ext_slow_left = 0.0
	_reset_marks()                            # R187 通用标记通道归还清零（引信/蓄能/双 ICD）
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
	_spell_ring = null                         # R253 进度弧引用随池归还断链（圈本体 timer 回调自理）
	_spell_delay = 0.9
	_reset_cast_state()                             # Boss 弹幕施法态清零（E-04/E-05 契约）
	_barrage = []
	_barrage_cd.clear()
	_blink_state = 0                                # BLINK 三态清零 + 落点圈回收（池复用安全）
	_blink_cd = 0.0
	_blink_left = 0.0
	_blink_target = Vector2.ZERO
	_blink_threat = false                           # R251 需求①：躲爆威胁旗随池归还清零（防残留错授）
	_clear_blink_ring()
	_enrage_done = false
	_enrage_cd_mult = 1.0
	poise_max = 0.0
	poise = 0.0
	_poise_immune_left = 0.0
	_stagger_left = 0.0
	_chg_state = 0
	_chg_left = 0.0
	_chg_seg_left = 0
	_chg_dir = Vector2.ZERO
	_chg_cd = 0.0
	_chg_cfg = {}
	if _chg_fan != null:
		_chg_fan.visible = false
	_enrage_rate_mult = 1.0
	_enrage_speed_mult = 1.0
	_enrage_tele_mult = 1.0
	_red_tint_left = 0.0
	_flash_left = 0.0
	_fade_left = 0.0
	_wobble_left = 0.0
	_hit_jolt_left = 0.0
	_hit_jolt_dir = Vector2.ZERO
	_contact_player = null                     # R202 ②：池复用清接触旗（重叠态由物理信号重arm）
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
	_body_kind = &"grunt"                        # R188⑪：池复用规格缓存归位 grunt（防残留——spawn 由 _sync_visual 重推导）
	_body_angry = false
	modulate.a = 1.0
	_apply_flash(0.0)
	if _sprite != null:
		_sprite.rotation = 0.0
		_sprite.position = Vector2.ZERO
		_sprite.scale = Vector2(_base_scale, _base_scale)
		_sprite.texture = TextureFactory.enemy_tex(&"grunt")
		_vis_tx_stale = true                 # R202 ⑤：直写 transform 后置脏——下帧全量对齐量化游标
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
	_fullload_decor_hidden = false           # R225：装饰门标志随池归还清零——装饰已强制
	                                         # 隐藏、非门所致；下次 spawn 经 _sync_visual
	                                         # → _apply_fullload_decor 重推导（防复用错相）
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
	_refresh_body_spec()                         # R188⑪：分型定档即刷本体规格缓存（spawn 期一次）
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
	_vis_tx_stale = true                     # R202 ⑤：直写 transform 后置脏——下帧全量对齐量化游标
	_ensure_armor(_kind)
	_ensure_crown(_kind)
	_ensure_shadow(_kind)
	_ensure_sparkles(_kind)
	_ensure_satellites(_kind)
	_apply_fullload_decor()                  # R225：满载门开时出生即刻隐装饰（无首帧闪现）
	# 绘制序（同 z 树序，禁 z_index 负值——会压到世界背景之下）：底影 < 外甲板 < 本体
	# （后 move 的排 index 0：先甲板后底影 → 最终序 底影(0) < 甲板(1) < 本体）
	if _armor_sprite != null:
		move_child(_armor_sprite, 0)
	if _shadow != null:
		move_child(_shadow, 0)
	if _hit_shape != null:
		_hit_shape.shape = _hit_circle(r)
	_place_in_bucket()


func _place_in_bucket() -> void:
	# R214 E'：本体贴图定档后落同贴图桶（敌 120 item → 每 kind ≈1 批；换贴图自动换桶）。
	# 覆盖点：_sync_visual 尾（spawn/分型）+ _tick_boss 怒相变脸；桶为原点无变换，
	# local position 语义恒等。host 为 null（老测试直连池）零操作。
	# R240：place 尾追本体镜像注册/注销（贴图变化自动换 mm 键——与换桶同款语义）。
	if bucket_host != null and _sprite != null and _sprite.texture != null:
		bucket_host.place(self, _sprite.texture)
		_apply_body_mirror()


func _mm_eligible() -> bool:
	# R240 镜像资格：门开+闪白贴图路径可用（联动约束——mm 实例色 8-bit 钳位承载不了
	# 白乘 >1，闪白必须走白变体贴图）+ host 具备镜像能力+分型不在排除面（boss/精英/
	# bastion 有叠层子件〔皇冠/底影/甲板/卫星〕，其与本体相对树序语义敏感，保持逐敌
	# Sprite 现状；大众杂兵=纯本体+上层瞬态件，镜像后相对序逐位保持）。
	if not BODY_MM or not FLASH_TEX:
		return false
	if bucket_host == null or not bucket_host.has_method(&"mirror_register"):
		return false
	var k := String(_visual_kind())
	if k.begins_with("boss") or k == "elite" or k == "bastion":
		return false
	return true


func _apply_body_mirror() -> void:
	# R240 本体镜像注册口（_place_in_bucket 尾=贴图定档后唯一调用点——变脸/闪白换
	# 贴图复用本路径自动换键）。镜像期 _sprite 恒隐（CanvasItem 摘出渲染，仅作
	# transform/色读源）；资格失配（排除分型/门关）→ 复显+注销，幂等。
	if _mm_eligible():
		_sprite.visible = false
		bucket_host.mirror_register(self, _sprite, _sprite.texture)
		_mm_on = true
	else:
		_sprite.visible = true
		if bucket_host != null:
			bucket_host.mirror_unregister(self)
		_mm_on = false


static var _hit_circle_cache: Dictionary = {}   # R207：int(半径) -> CircleShape2D 复用池

static func _hit_circle(p_radius: float) -> CircleShape2D:
	# R207 波次尖峰直嫌（vc14 真机 尖峰波81ms）：_sync_visual 每次出生 new 一个
	# CircleShape2D——spawn 风暴帧（≤8 只/帧）叠加分配+初始化；shape 为只读资源可
	# 安全跨实例共享（同半径共用一份，物理侧零语义差）。
	var key := int(round(p_radius * 2.0))
	if not _hit_circle_cache.has(key):
		var shape := CircleShape2D.new()
		shape.radius = p_radius
		_hit_circle_cache[key] = shape
	return _hit_circle_cache[key]


func _visual_kind() -> StringName:
	return visual_kind_for(data, tags)


static func visual_kind_for(p_data: EnemyData, p_tags: int) -> StringName:
	# R215 刀C抽出：分型判定纯函数化（id 前缀 + tags 位）——game_loop 菜单预热建队
	# 零 spawn 消费同一映射（单源防漂移）。实例语义逐位不变。
	# 分型判定（tag 优先级 Boss > 精英 > E1~E5 id 前缀约定）：
	# boss1~7 七套剪影互异的大型聚合体（boss4~7 = 每图专属 Boss，P1 2026-08-31）；
	# E5 精英 = 金腹徽基底（引擎侧加皇冠/悬浮/微光）
	if (p_tags & GameConst.TAG_BOSS) != 0 and p_data != null:
		var bid := String(p_data.id)
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
	if (p_tags & GameConst.TAG_ELITE) != 0:
		return &"elite"
	if p_data == null:
		return &"grunt"
	var sid := String(p_data.id)
	# R72 新形态（E25~E30 必须先于 E2/E3 短前缀判定——begins_with 撞前缀）
	if sid.begins_with("E25"):
		return &"phase"
	if sid.begins_with("E26"):
		return &"shieldlancer"
	if sid.begins_with("E27"):
		return &"warden"
	if sid.begins_with("E28"):
		return &"hexcaster"
	if sid.begins_with("E29"):
		return &"longbow"
	if sid.begins_with("E30"):
		return &"revenant"
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


func _apply_fullload_decor() -> void:
	# R225 满载敌侧纯装饰子件隐藏门（候选 a+b，可否决披露）：皇冠（精英）/微光粒（精英）/
	# 卫星球（Boss）/底影（精英+Boss）四族 per-instance Sprite2D 子件 = 桶外独立 canvas
	# item（R214 桶只落本体贴图——_place_in_bucket 仅收 _sprite.texture）。审计证据：
	# vc22 定案曾列「累积附件项（甲板/皇冠/微光…）」为 dc 退化嫌疑、vc23「桶外非池化物」、
	# vc26「组N 达标而 dc 300-800，桶外 dc 构成低优先归因」（FEEDBACK_TRACKER 二d#1/二f#3/
	# 二l#2）——满载（敌≥80 滞回门）期隐藏四族装饰减桶外 dc，为满载 dc 减半让路。
	# 只砍纯装饰：本体贴图/状态染色/狂暴红/死亡爆闪/血条全不动（读感承担面不变）；
	# 甲板（E3 外甲板）保留——半身剪影非纯装饰，不入本批。门回落走 _ensure_* 既有
	# want 语义自动复显（滞回防 80/72 震荡横跳）；非满载（桌面）零扰动。
	# 同型先例：R217 修轮余烬满载同隐（_burn_ember.visible = p_burning and not fullload_dim()）。
	var fl := _decor_hidden_now()             # R269 C1：唯一装饰消费处换并 boost 谓词（§3.5）
	if _fullload_decor_hidden == fl:
		return                                   # 门态未变零写点（每敌每帧一次分支）
	_fullload_decor_hidden = fl
	if fl:
		if _crown != null:
			_crown.visible = false
		if _shadow != null:
			_shadow.visible = false
		for sp in _sparkles:
			sp.visible = false
		for orb in _satellites:
			orb.visible = false
	else:
		# 复显走 _ensure_* 单源（分型 want 判定不在此复制——防两处口径漂移）
		_ensure_crown(_kind)
		_ensure_shadow(_kind)
		_ensure_sparkles(_kind)
		_ensure_satellites(_kind)


func _tick_visual(p_game_delta: float) -> void:
	# 表现层状态机（game_delta 通道——顿帧自然冻结；零碰撞、零数值副作用）：
	# 出生弹入 / 受击果冻 / 分型动画（E1 摇摆呼吸 / E2 冲刺形变 / E3 甲板错位 /
	# E4 充能三段变脸 / E5 悬浮微光 / Boss 公转 + 二阶段变脸）。
	if _is_vis_cullable():
		_anim_t += p_game_delta
		return
	_apply_fullload_decor()                  # R225：门翻转随 tick 落位（开=隐/关=复显；
	                                         # 置于分型动画前——隐藏期 _tick_elite_extras/
	                                         # _tick_boss 的装饰逐帧写点经 .visible 门自然跳过）
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
		&"shieldlancer", &"warden":
			# R72 盾面朝玩家（贴图朝上 = 盾在前；引擎侧旋转）+ 呼吸
			var p_face := _player()
			if p_face != null and is_instance_valid(p_face):
				rot = (p_face.global_position - global_position).angle() + PI * 0.5
			var breathe_s := 1.0 + 0.025 * sin(_anim_t * 3.8 + float(uid % 32))
			sx = _base_scale * breathe_s
			sy = _base_scale * (2.0 - breathe_s)
		&"phase", &"revenant":
			# R72 幻影/狱焰（闪现自爆族）：漂浮微旋 + 读条收缩（rift 同款）
			rot = 0.07 * sin(_anim_t * 4.2 + float(uid % 32))
			var breathe_p := 1.0 + 0.035 * sin(_anim_t * 5.4 + float(uid % 32))
			if _blink_state == 1:
				var prog_p := 1.0 - clampf(_blink_left / maxf(_blink_prep, 0.01), 0.0, 1.0)
				breathe_p *= 1.0 - 0.25 * prog_p
			sx = _base_scale * breathe_p
			sy = _base_scale * breathe_p
		&"hexcaster":
			# R72 咒术师：法杖抬手脉冲（射击冷却临近时鼓胀——施法预警）
			var cast_glow_h := 1.0 - clampf(fire_cd_left / maxf(fire_cd, 0.01), 0.0, 1.0)
			var breathe_h := 1.0 + 0.03 * sin(_anim_t * 4.0 + float(uid % 32)) 				+ 0.12 * pow(cast_glow_h, 2.0)
			sx = _base_scale * breathe_h
			sy = _base_scale * (2.0 - breathe_h)
		&"longbow":
			# R72 长弓隼卫：朝玩家的隼形（dart 同款朝向逻辑）
			rot = _dart_rotation()
			sx = _base_scale * 0.94
			sy = _base_scale * 1.06
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
	# R202 ⑤：transform 写点量化（projectile_base.gd:834 _vis_scale_q 先例）——呼吸/
	# 摇摆/悬浮等连续小幅度动画按量化级跳写（scale 1/64 级 / 旋转 1° 级 / 偏移 0.25px 级，
	# 肉眼不可辨）；受击果冻/出生弹入/冲刺形变等大幅度状态动画跨级仍逐帧写（响应不受
	# 影响）。_reset_state/_sync_visual 直写 transform 后置 _vis_tx_stale 强制下帧全量对齐。
	var sx_q := int(floorf(sx * 64.0))
	var sy_q := int(floorf(sy * 64.0))
	var rot_q := int(floorf(rot * 57.29578))
	var off_q := Vector2(floorf(off.x * 4.0), floorf(off.y * 4.0))
	if _vis_tx_stale:
		_vis_tx_stale = false
		_vis_sx_q = sx_q
		_vis_sy_q = sy_q
		_vis_rot_q = rot_q
		_vis_off_q = off_q
		_sprite.scale = Vector2(sx, sy)
		_sprite.rotation = rot
		_sprite.position = off
	else:
		if sx_q != _vis_sx_q or sy_q != _vis_sy_q:
			_vis_sx_q = sx_q
			_vis_sy_q = sy_q
			_sprite.scale = Vector2(sx, sy)
		if rot_q != _vis_rot_q:
			_vis_rot_q = rot_q
			_sprite.rotation = rot
		if off_q != _vis_off_q:
			_vis_off_q = off_q
			_sprite.position = off
	_tick_status_fx(p_game_delta)
	# R217 刀A：本体染色改每帧**确定性重算 + 档位量化**（_apply_body_tint——self_modulate
	# 唯一写点）。vc24 定案：原「状态染色 30Hz lerp + 吟唱/闪紫/狂暴逐帧 lerp 收敛链」
	# 逐敌相位唯一值 = 桶内断批（94 敌单桶碎近百批、dc~1040）；同状态组合敌同帧同色 → 同批
	_apply_body_tint(p_game_delta)


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
	_refresh_body_spec()                         # R188⑪：三段脸写点同步规格缓存（先于 sprite 守卫——无 sprite 亦保账实一致）
	if _sprite == null:
		return
	match p_state:
		2:
			_sprite.texture = TextureFactory.enemy_tex(&"volatile", true)
		1:
			_sprite.texture = TextureFactory.enemy_tex(&"volatile_scared")
		_:
			_sprite.texture = TextureFactory.enemy_tex(&"volatile", false)
	_place_in_bucket()                   # R214 E'：变脸换贴图须随换桶（漏则异贴图滞留旧桶断批）


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
		# R262b H1：α 四分档量化（精英微光珠共享 bead 键同档合批）
		sp.modulate.a = _qa_a(0.45 + 0.4 * sin(_anim_t * 3.3 + float(i) * 2.1))


func _tick_boss(p_game_delta: float) -> void:
	# Boss：二阶段变脸（HP<50% → boss_phase=2 时怒相贴图 + 公转提速）；卫星公转；底影随浮
	if boss_phase >= 2 and not _boss_angry:
		_boss_angry = true
		_body_angry = true                      # R188⑪：怒相写点同步规格缓存（kind 不变）
		_sprite.texture = TextureFactory.enemy_tex(_kind, true)
		_place_in_bucket()                      # R214 E'：变脸换贴图 → 换桶（保持合批）
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
	# R202 ③：>0 起闪挂回材质（take_result 1.0 / 窗口内衰减值）；归 0 窗外摘除
	# （_sprite.material = null 恢复 2D 批处理——闪白窗 0.06s 外全程无逐敌 shader）。
	# _material 实例随池存活，attach/detach 零新建；spawn/_reset_state 的
	# _apply_flash(0.0) 兼任池复用摘除口。
	# R213 C案：满载门——闪白去 shader 化（vc20 满载高命中时任一时刻 ~12 敌常挂逐实例
	# ShaderMaterial，每个断一批；modulate 白乘近似（分量 >1 过曝）视觉略弱但零批处理
	# 扰动）。走 _sprite.modulate 通道——与 _tick_status_tint 的 self_modulate 染色
	# 分通道独立不互踩；两分支互相复位对方通道（门切换/回落边界零残留）。
	# R237 闪白换桶刀（FLASH_TEX=true 默认）：满载档白乘再进贴图化——白变体贴图换桶
	# （强闪全白剪影/弱闪半白混合，R217 两档强度语义保留；modulate 恒 WHITE、材质恒摘
	# → 闪白窗内敌不再因 modulate≠WHITE 打出同桶交错断批）。FLASH_TEX=false 单点回退=
	# 满载白乘现状（R216 碎片烤色先例）；_flash_tex_on 为白变体在身唯一账本，闪毕/门
	# 回落/池归还三路经 _restore_flash_tex() 换回本体贴图回原桶（零状态残留）。
	# R240：贴图路径门扩为 fullload_dim() or _mm_on——镜像敌（实例色 8-bit 钳位承不住
	# 白乘）闪白无论满载与否恒走白变体贴图（=现满载观感，轻载 shader 混合仅保留给
	# 排除分型/门关的逐敌 Sprite 敌）。
	if _material == null:
		return
	if fullload_dim() or _mm_on:
		if _sprite == null:
			return
		if _sprite.material == _material:
			_sprite.material = null              # 摘除门开启前可能已挂的材质
		if FLASH_TEX:
			# R237：满载闪白贴图化——白变体 + modulate 复位 WHITE + 落白变体桶
			# （R214 E' 变脸换桶同款；place 幂等——同档续闪零 reparent）。p>0 只在
			# 活跃上下文触达（take_result/tick 衰减），无条件落桶安全。
			if p_amount > 0.0:
				# R188⑪：规格读成员（贴图写点 _refresh_body_spec 维护）——原每闪帧
				# _body_tex_spec() 新建 Array(2)+String(_kind) 是闪白窗逐敌逐帧分配税；
				# 缓存值与 _body_tex_spec() 单源同语义（写点同步，零语义变）
				_sprite.texture = TextureFactory.enemy_tex_flash(_body_kind, _body_angry, p_amount >= 0.5)
				_flash_tex_on = true
				_place_in_bucket()
			else:
				_restore_flash_tex()             # 闪毕/池归还：换回本体贴图回原桶（含归还链守卫）
			if _sprite.modulate != Color.WHITE:
				_sprite.modulate = Color.WHITE   # 复位 FLASH_TEX=false 期白乘残留（切换边界）
			return
		if _flash_tex_on:
			_restore_flash_tex()                 # R237：true 期起闪 → 开关翻 false 续窗边界
		if p_amount > 0.0:
			# R217 刀A：白乘量化 2 档（原连续 1+2p 逐敌唯一值=闪白窗内全员断批；两档
			# 固定倍率全敌同值 → 同批。CRIT/普击强度差并入两档：≥0.5 强闪 2.4×/弱闪 1.5×）
			_sprite.modulate = Color.WHITE * (2.4 if p_amount >= 0.5 else 1.5)
		else:
			_sprite.modulate = Color.WHITE
		return
	if p_amount > 0.0:
		if _sprite != null:
			if _flash_tex_on:
				_restore_flash_tex()             # R237：门回落边界——白变体换回本体回原桶
			if _sprite.modulate != Color.WHITE:
				_sprite.modulate = Color.WHITE   # 复位满载期白乘残留（门回落边界）
			if _sprite.material == null:
				_sprite.material = _material
		_material.set_shader_parameter(&"flash_amount", p_amount)
	elif _sprite != null:
		# QA-R213-001：归零路径无条件复位白乘残留——门开期受击（modulate>1、材质已摘）
		# → 门回落后死亡归还，_reset_state 走本分支（p=0.0），旧 elif 只摘材质不复位
		# modulate → 复用敌持续过曝至下次受击。与 :2356 满载分支对称双通道互复位。
		if _flash_tex_on:
			_restore_flash_tex()                 # R237：门回落闪毕同口复位（零状态残留）
		if _sprite.modulate != Color.WHITE:
			_sprite.modulate = Color.WHITE
		if _sprite.material == _material:
			_sprite.material = null


func _body_tex_spec() -> Array:
	# R237 闪白换桶刀：本体贴图 (kind, angry) 规格随当前态重推导——与 _sync_visual /
	# _set_volatile_face / _tick_boss 三处贴图写点同源（单源防漂移）：闪毕回原桶与
	# 白变体取变体均走本口，volatile 三段脸 / boss 怒相在闪白窗内变脸后复位取新脸
	#（不回旧脸）。返回 [StringName kind, bool angry]。
	# R188⑪：本函数降级为「写点边缘一次性推导」（_refresh_body_spec 缓存进成员）——
	# 逐帧衰减路径只读成员。boss 前缀判定改 boss1~7 StringName 集合 == 比较（值域见
	# visual_kind_for——String(_kind).begins_with 每次新建 String 是热路径税）。
	if _kind == &"boss1" or _kind == &"boss2" or _kind == &"boss3" or _kind == &"boss4" \
			or _kind == &"boss5" or _kind == &"boss6" or _kind == &"boss7":
		return [_kind, _boss_angry]
	match _kind:
		&"volatile":
			match _face_state:
				2:
					return [&"volatile", true]
				1:
					return [&"volatile_scared", false]
				_:
					return [&"volatile", false]
		&"elite":
			return [&"elite", false]
		&"bastion":
			return [&"bastion_core", false]
		_:
			return [_kind, false]


func _refresh_body_spec() -> void:
	# R188⑪：贴图写点（_sync_visual / _set_volatile_face / _tick_boss / _reset_state）
	# 统一把 _body_tex_spec() 结果缓存进成员——闪白窗逐帧衰减（_apply_flash p>0）改读
	# 成员，规格推导只发生在变脸/分型/复位等边缘事件（零逐帧分配）。
	var spec: Array = _body_tex_spec()
	_body_kind = spec[0]
	_body_angry = spec[1]


func _restore_flash_tex() -> void:
	# R237 闪白换桶刀：白变体复位口（闪毕 / 门回落 / 池归还三路共用——_flash_tex_on
	# 唯一清零点）。贴图换回本体 kind 规格；回桶带归还链守卫：ObjectPool.release 开头
	# bucket_host.unplace 已把敌归位池根，此时敌不在桶下 → is_ancestor_of 不成立跳过
	# 回桶（防释放中敌被重新挂桶违反 R214 池根生命周期；复取 spawn 由 _sync_visual
	# 尾 _place_in_bucket 正常落桶）。桶 host 为 null（老测试直连池）仅复位贴图。
	# R272 V-C2 评审#1（满载档暗门）：V-C1/C2 惰性归位后归还敌**留桶**，is_ancestor_of
	# 恒真——原守卫失守，满载档（fullload_dim 换白变体贴图路径）_reset_state 期间
	# 重新落桶+MM 镜像重注册（非 grunt 死亡换桶 reparent / grunt 闪白窗内死亡 1 次）。
	# 修=守卫加 dead 门：_reset_state 先置 dead=true（:2246）后调本口，归还路径
	# dead==true 跳过回桶；活跃期闪毕/门回落 dead==false 路径逐位不变。
	_flash_tex_on = false
	if _sprite == null:
		return
	var spec: Array = _body_tex_spec()
	var r_kind: StringName = spec[0]
	var r_angry: bool = spec[1]
	_sprite.texture = TextureFactory.enemy_tex(r_kind, r_angry)
	if bucket_host != null and bucket_host.is_ancestor_of(self) and not dead:
		_place_in_bucket()


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
	# R202 ⑤：写点 30Hz 降频——跳写期间累计 delta、写帧一次结清（电弧/落雷倒计时的
	# 墙钟精度不漂移，只量化到 30Hz 拍）。写透三条件（缺一不可——
	# verify_feedback_cases.gd:661-686 单次 _tick_status_fx(DT) 后即断挂件六行）：
	# ① 状态位签名变化（显隐翻转必须当帧落位）② 惰性建件未齐（挂件创建首 tick 立即写）
	# ③ 30Hz 节拍到点。
	_sfx_accum += p_game_delta
	_sfx_write_left -= p_game_delta
	var sig := (1 if burning else 0) | (2 if chilled else 0) | (4 if frozen else 0) \
		| (8 if shocked else 0) | (16 if supercon else 0)
	if sig != _sfx_sig or _sfx_write_left <= 0.0 \
			or _sfx_lazy_pending(burning, chilled, frozen, shocked, supercon):
		_sfx_sig = sig
		_sfx_write_left = STATUS_FX_WRITE_INTERVAL
		var dt := _sfx_accum
		_sfx_accum = 0.0
		_tick_burn_flames(dt, burning)
		_tick_frost(chilled, frozen)
		_tick_shock_fx(dt, shocked)
		_tick_super_fx(supercon)
		_tick_status_tint(burning, chilled, frozen, shocked)


func _sfx_lazy_pending(p_burning: bool, p_chilled: bool, p_frozen: bool, p_shocked: bool,
		p_supercon: bool) -> bool:
	# 惰性建件判据（R202 ⑤ 迫写条件②；预算感知——低档预算 0 的件永不建、不构成
	# 迫写条件，30Hz 节流在低档不被击穿）
	if p_burning and _burn_ember == null:
		return true
	var q := _state_fx_q()
	if (p_chilled or p_frozen) and FROST_SHARD_BUDGET[q] > 0 and _frost_shards.is_empty():
		return true
	if p_frozen and q >= FROST_RING_MIN_Q and _frost_ring == null:
		return true
	if p_shocked and SHOCK_ARC_BUDGET[q] > 0 and _shock_arcs.is_empty():
		return true
	# 落雷「到期待击」也迫写：正常流 cd 只在写帧递减、到期同帧即击（可见）；cd ≤ 0 且
	# 未可见仅发生于外置归零（verify_feedback_cases.gd:670 set("_shock_bolt_cd",0) 单步
	# 断言口径）——迫写保证到点雷不因节拍迟发
	if p_shocked and q > 0 and (_shock_bolt == null
			or (_shock_bolt_cd <= 0.0 and not _shock_bolt.visible)):
		return true
	if p_supercon and SUPER_MIST_BUDGET[q] > 0 and _super_mist.is_empty():
		return true
	return false


func _ensure_super_mist() -> void:
	# 超导电离雾点群（夜间R57 去球化三轮：单块大 soft_dot 低 alpha 下仍读作「纯紫圆球」）——
	# 3 个小雾点绕体错相漂浮，读感 = 电离雾屑而非实心球；电场感仍由高频电弧承担
	# R202 ④：雾点数接 fx_quality 档预算 [0,2,3]（低档关 / 中档 2 / 高档 = 原 3）
	for i in range(SUPER_MIST_BUDGET[_state_fx_q()]):
		if i < _super_mist.size():
			continue
		var sp := Sprite2D.new()
		sp.name = "SuperMist%d" % i
		sp.texture = TextureFactory.soft_dot(64)
		sp.modulate = Color(PopPalette.SHOCK.r, PopPalette.SHOCK.g,
			PopPalette.SHOCK.b, 0.14)
		sp.scale = Vector2.ONE * (hitbox_r * 0.9 / 64.0)
		add_child(sp)
		_super_mist.append(sp)


func _tick_super_fx(p_supercon: bool) -> void:
	# 超导表现：雾点群绕体慢转漂浮（错相呼吸）+ 电弧双倍频率（电场感，无圆环无球）
	if not p_supercon:
		for sp in _super_mist:
			sp.visible = false
		return
	_ensure_super_mist()
	var mist_budget: int = SUPER_MIST_BUDGET[_state_fx_q()]
	for i in range(_super_mist.size()):
		var sp: Sprite2D = _super_mist[i]
		# R202 ④：档位降档后超额雾点隐藏（高档建满 3 → 中档只见 2）
		if i >= mist_budget:
			sp.visible = false
			continue
		var ang := _anim_t * 0.9 + TAU * float(i) / 3.0
		sp.position = Vector2.from_angle(ang) * hitbox_r * 0.85 			+ Vector2(0.0, sin(_anim_t * 2.2 + float(i) * 1.9) * 3.0)
		sp.modulate.a = 0.10 + 0.06 * (0.5 + 0.5 * sin(_anim_t * 2.6 + float(i) * 2.1))
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
	# R202 ④：弧数接 fx_quality 档预算 [0,1,2]（低档关 / 中档单弧 / 高档 = 原双弧）
	var arc_budget: int = SHOCK_ARC_BUDGET[_state_fx_q()]
	if _shock_arcs.is_empty():
		for i in range(arc_budget):
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
	# R202 ④：降档后超额弧隐藏（高档建满 2 → 中档只见 1）
	for i in range(_shock_arcs.size()):
		if i >= arc_budget:
			_shock_arcs[i].visible = false
	if _shock_arc_left > 0.0:
		_shock_arc_left = maxf(_shock_arc_left - p_game_delta, 0.0)
		if _shock_arc_left <= 0.0:
			for arc in _shock_arcs:
				arc.visible = false
	_shock_arc_cd -= p_game_delta
	if _shock_arc_cd <= 0.0:
		_shock_arc_cd = SHOCK_ARC_PERIOD + randf() * 0.12
		var patterns := _get_arc_patterns()
		# R63 去球化（四轮）：Line2D.width 随 transform 缩放——scale hitbox_r×1.35≈30 把
		# 4px 线宽放大成 ~120px 紫色巨条，双弧随机旋转交叉糊成一团 = 用户「纯紫色圆球」
		# 根因（前三轮修的弹体/星闪/雾点都不是它）。宽度除以缩放补偿：屏上恒 3~6px 细弧
		var arc_scale := hitbox_r * 1.35
		for i in range(mini(_shock_arcs.size(), arc_budget)):
			var arc := _shock_arcs[i]
			arc.points = patterns[_arc_pattern_idx % patterns.size()]
			_arc_pattern_idx += 1
			arc.rotation = randf() * TAU
			arc.scale = Vector2.ONE * arc_scale
			arc.width = clampf(hitbox_r * 0.18, 3.0, 6.0) / arc_scale
			arc.visible = i == 0
		# 第二弧延迟半程点亮（错相闪烁；中档单弧跳过）
		if _shock_arcs.size() > 1:
			_shock_arcs[1].visible = false
		_shock_arc_left = SHOCK_ARC_TIME
	if _shock_arcs.size() > 1 and arc_budget > 1 and _shock_arc_left > 0.0 \
			and _shock_arc_left < SHOCK_ARC_TIME * 0.5:
		_shock_arcs[1].visible = true
	# 垂直落雷：顶部天降锯齿劈到本体 + 四角星爆闪（周期 ~0.9s，存活 0.12s）
	# R19 特效质量：低档关闭落雷（电弧已足够表意——群体感电期减负）；R202 ① 改缓存读
	if _state_fx_q() > 0:
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
		_shock_impact.texture = TextureFactory.spark4(48, Color.WHITE)   # 夜间R57：四芒细星（五角粗星自旋读作紫球）
		_shock_impact.modulate = PopPalette.SHOCK.lerp(Color.WHITE, 0.7)
		_shock_impact.visible = false
		add_child(_shock_impact)
	if _shock_bolt_left > 0.0:
		_shock_bolt_left = maxf(_shock_bolt_left - p_game_delta, 0.0)
		if _shock_bolt_left <= 0.0:
			_shock_bolt.visible = false
			_shock_impact.visible = false
		else:
			_shock_impact.rotation += p_game_delta * 5.0
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
	# R202 ⑤：写点节拍游标复位（签名 -1 = 池复用首 tick 必写透；累计/节拍清零）
	_sfx_sig = -1
	_sfx_write_left = 0.0
	_sfx_accum = 0.0
	for f in _burn_flames:
		f.visible = false
	for s in _frost_shards:
		s.visible = false
	if _frost_ring != null:
		_frost_ring.visible = false
	for sp in _super_mist:
		sp.visible = false
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
	# R217 修轮（评审#1）：余烬异贴图（soft_dot≠本体）桶内必断批且 断N 不可见——满载随
	# A案挂件一同隐藏，「在烧」读感由本体量化呼吸（0.46/0.30 档）独自承担（同冻结口径）
	_burn_ember.visible = p_burning and not fullload_dim()
	if p_burning:
		_burn_ember.position = Vector2(0.0, hitbox_r * 0.12)
		_burn_ember.scale = Vector2.ONE * hitbox_r * 0.24 \
			* (1.0 + 0.1 * sin(_anim_t * 8.4))
		_burn_ember.modulate.a = 0.3 + 0.1 * sin(_anim_t * 7.2)
	# R19 特效质量：火苗数预算 高4/中2/低0（低档仅余烬光晕——成群点燃敌不再拖帧）
	# R202 ①：档位表提为 const + fx_quality 改 static 缓存读（原每帧每敌数组字面量
	# 分配 + Meta.settings 字典查询——probe_heat_scan [A] 实测 0.25µs/次的查表税）
	var flame_budget: int = FLAME_BUDGET[_state_fx_q()]
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
		# R262b H1：α 四分档量化+色相插值系数 3 档量化——共享 flame_bit 键的敌桶火苗
		# 按（α档×色档）合批（R216 断批定律收口；先例 elemental_fx_layer 同律）
		f.modulate = Color(1.0, 1.0, 1.0,
			_qa_a(clampf(maxf(sin(cyc * PI) * 1.35, 0.4), 0.0, 1.0)))
		# 白（贴图本色：橙外焰+亮黄内芯）→ 橙红渐深（自带饱和度，避免淡黄洗白）
		f.self_modulate = Color.WHITE.lerp(PopPalette.ENEMY,
			float(roundi(cyc * 0.7 * 3.0)) / 3.0)


func _tick_frost(p_chilled: bool, p_frozen: bool) -> void:
	# 寒滞/冻结：本体结霜大冰晶（冻结更大更亮更密——用户反馈「冰冻没看见效果」×1.8 放大）
	# + 冻结期加厚冰壳描边圈 + 冰蓝强染色（_tick_status_tint）
	# R202 ④：冰渣数/冰环接 fx_quality 档预算（渣 [0,2,3]——高档 = 原 3；
	# 环低档关 FROST_RING_MIN_Q=1——低档冻结读感由冰蓝强染色承担）
	var shard_budget: int = FROST_SHARD_BUDGET[_state_fx_q()]
	if _frost_shards.is_empty():
		if not p_chilled and not p_frozen:
			return
		for i in range(shard_budget):
			var s := Sprite2D.new()
			s.name = "FrostShard%d" % i
			s.texture = TextureFactory.ice_shard()
			add_child(s)
			_frost_shards.append(s)
	for i in range(_frost_shards.size()):
		var s := _frost_shards[i]
		s.visible = (p_chilled or p_frozen) and i < shard_budget
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
	if p_frozen and _state_fx_q() >= FROST_RING_MIN_Q:
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
		# R262b H1：α 四分档量化（共享 ring_tex 键同档合批）
		_frost_ring.modulate.a = _qa_a(0.75 + 0.25 * sin(_anim_t * 5.2))
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


func _apply_body_tint(p_game_delta: float) -> void:
	# R217 刀A：本体染色 self_modulate **唯一写点**——每帧从 WHITE 起点确定性重算，
	# 连续量全部量化 2 档（点燃呼吸 sin/感电频闪/吟唱进度/闪紫前摇），离散态系数固定
	#（冻结/寒滞/狂暴常驻 0.18/入场强红 0.45）→ 同状态组合敌同帧同色 → 同桶同批
	#（断批点从 ~敌数 降为 ≤ 档组合数）。状态位判据与 _tick_status_fx 头部同源直读。
	if _sprite == null:
		return
	if _enrage_done:
		_red_tint_left = maxf(_red_tint_left - p_game_delta, 0.0)
	var tint := Color.WHITE
	if elemental != null:
		if elemental.burn_timer > 0.0:
			# 点燃橙红呼吸：sin 相位量化 2 档（≈1Hz 明暗交替，呼吸读感保持）
			var breath := 0.46 if sin(_anim_t * 6.2) >= 0.0 else 0.30
			tint = tint.lerp(PopPalette.ENEMY.lerp(PopPalette.XP, 0.45), breath)
		if elemental.chill_timer > 0.0:
			tint = tint.lerp(PopPalette.ELEMENT_COLORS[GameConst.Element.ICE].lerp(Color.WHITE, 0.45), 0.55)
		if elemental.freeze_timer > 0.0:
			tint = tint.lerp(PopPalette.PLAYER.lerp(Color.WHITE, 0.6), 0.88)
		if elemental.gauges[GameConst.Element.LTG] > 0.0:
			# 感电微频闪：46rad/s 方波量化（原 sin 连续值逐敌相位唯一）
			tint = tint.lerp(Color.WHITE, 0.14 if sin(_anim_t * 46.0) > 0.0 else 0.0)
	if _cast_glow > 0.0:
		# TelegraphSwell 闪红（即将齐射 §1.2）：进度量化 2 档
		tint = tint.lerp(Color(1.0, 0.36, 0.36), 0.85 if _cast_glow >= 0.5 else 0.45)
	if _blink_state == 1:
		# BLINK 读条闪紫（出手前摇 §3.3）：前摇进度量化 2 档
		var blink_glow := 1.0 - clampf(_blink_left / maxf(_blink_prep, 0.01), 0.0, 1.0)
		tint = tint.lerp(Color(0.7, 0.5, 1.0), 0.8 if blink_glow >= 0.5 else 0.4)
	if _enrage_done:
		# B8 狂暴红染：入场 2s 强红 0.45 → 常驻微红 0.18（两档固定绝对值——原逐帧 lerp
		# 收敛链每敌值不同=常驻断批）
		tint = tint.lerp(Color(1.0, 0.25, 0.25), 0.45 if _red_tint_left > 0.0 else 0.18)
	_sprite.self_modulate = tint


func is_batch_broken() -> bool:
	# R217 刀B：桶内断批直读（diag 遥测「断N」——modulate/self_modulate 任一非白或
	# 敌根渐显 α<1 的敌计数；与 dc 对读定桶内断批贡献。闪白窗/染色窗/入场渐显窗内
	# 为 true——渐显写在敌根 modulate.a（tick 量化 4 档），非 _sprite 通道，须单查）
	if _sprite != null \
		and (_sprite.modulate != Color.WHITE or _sprite.self_modulate != Color.WHITE):
		return true
	return modulate.a != 1.0


func sprite_modulate_key() -> String:
	# R218 刀A：分组N 元组键（modulate|self_modulate 两通道**浮点分量**——根 α 由调用方
	# 拼接；diag_counts 1Hz 遥测专用，同键=同帧同色=同批。修轮#1（评审）：勿用
	# to_html()——8-bit 钳位会把闪白两档（WHITE×2.4/×1.5）与纯白折叠同键，桶内
	# 真实分组被低计误导 vc26 归因；浮点分量下 2.400/1.500/1.000 三键分明）
	if _sprite == null:
		return "none"
	return "%.3f,%.3f,%.3f|%.3f,%.3f,%.3f" % [
		_sprite.modulate.r, _sprite.modulate.g, _sprite.modulate.b,
		_sprite.self_modulate.r, _sprite.self_modulate.g, _sprite.self_modulate.b]


func _tick_status_tint(p_burning: bool, p_chilled: bool, p_frozen: bool, p_shocked: bool) -> void:
	# R217 刀A：原实现（30Hz lerp 链）并入 _apply_body_tint 每帧确定性重算——本函数保留
	# 签名转发（_tick_status_fx 写点节拍门内的调用兼容），参数即状态签名断言锚
	_apply_body_tint(0.0)


# ── 毒爆残效（E12 死亡毒环；一次性自消表现件——警示圈同款程序化绘制） ──
# R188 档0：入池复用（协议同 DeathPop——原每杀 new+queue_free 自毁）
class PoisonSplash:
	extends Node2D

	const LIFE := 0.38
	const POOL_MAX := 8                            # 池上限（E12 并发毒爆余量）

	static var _free: Array = []                   # 空闲件栈（LIFO）
	static var _active: int = 0                   # 在外活跃数（acquire/release 双向记账）
	static var _pool_news: int = 0
	static var _pool_hits: int = 0

	var radius: float = 77.0
	var _life: float = LIFE

	# R188 档0 池化发射口（替代 add_child(new)）
	# R230 K2c：+豁免旗参（缺省 false 保持旧签名兼容）+并发帽许可口——被帽件不发射，
	# 仅 Enemy 侧计帽N；毒环伤害结算在 _death_poison_splash 调用点照走（只拦表现）
	static func pop(p_parent: Node, p_pos: Vector2, p_radius: float,
			p_is_boss: bool = false, p_is_elite: bool = false) -> void:
		DebugStats.bucket_begin(&"deathfx")   # R269：死µs 桶（函数体首尾 wrap——DeathPop 同协议）
		if p_parent == null:
			DebugStats.bucket_end(&"deathfx")
			return
		if not Enemy._death_fx_admit(p_is_boss, p_is_elite):
			DebugStats.bucket_end(&"deathfx")
			return
		var item = _acquire(p_parent)
		item.position = p_pos
		item.radius = p_radius
		item._life = LIFE
		item.visible = true
		item.set_process(true)
		item.queue_redraw()
		if not p_is_boss:
			Enemy._death_fx_track(item)       # R230 K2c：非 Boss 件入册受帽（Boss 全保留）
		DebugStats.bucket_end(&"deathfx")

	static func _acquire(p_parent: Node) -> Object:
		while not _free.is_empty():
			var cand = _free.pop_back()
			if cand != null and is_instance_valid(cand):
				_pool_hits += 1
				_active += 1
				return cand
		_pool_news += 1
		var item = PoisonSplash.new()
		p_parent.add_child(item)
		_active += 1
		return item

	static func _release(p_item) -> void:
		DebugStats.bucket_begin(&"deathfx")   # R269：死µs 桶（_release 路径——DeathPop 同协议）
		if p_item == null or not is_instance_valid(p_item):
			DebugStats.bucket_end(&"deathfx")
			return
		_active -= 1
		Enemy._death_fx_untrack(p_item)       # R230 K2c：销册（幂等——Boss 件不在册）
		if _free.size() < POOL_MAX and not _free.has(p_item):
			p_item.visible = false
			p_item.set_process(false)
			_free.append(p_item)
		else:
			p_item.queue_free()
			DebugStats.count(&"perffx_qfree")  # R269：释N 计数（演出件 queue_free）
		DebugStats.bucket_end(&"deathfx")

	static func fx_pool_stats() -> Dictionary:
		# 基准池对账口径扩展（R188 档0）：{live, free, news, hits}——live 双向记账（在 ReleaseDiscard 场景下仍准确）
		return {"live": _active, "free": _free.size(), "news": _pool_news, "hits": _pool_hits}

	func _process(p_delta: float) -> void:
		_life -= p_delta
		if _life <= 0.0:
			_release(self)
			return
		queue_redraw()                          # 毒圈 _draw 全程随 _life 连续变（逐帧重绘必要）

	func _draw() -> void:
		# R271 P4：绘µs wrap（自绘件 _draw 计时入 &"draw" 桶——只加计不改行为；
		# 原体迁 _draw_r271，早退 return 由委托面兜底不漏收口）
		DebugStats.bucket_begin(&"draw")
		_draw_r271()
		DebugStats.bucket_end(&"draw")


	func _draw_r271() -> void:
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
	var _threat_near: bool = false                # 二db M2：armed 后玩家曾入 blast×2 圈（威胁记忆——授盾门）
	var _done: bool = false                       # c4④：已引爆旗（宿主失效臂防重复引爆——queue_free 帧末摘除前重入防线）

	func _ready() -> void:
		DebugStats.bucket_begin(&"telegraph")   # R269：警µs 桶（BossMine 落点红圈创建/挂树/配置）
		_ring = Telegraph.TelegraphCircle.new()
		_ring.radius = blast_r
		_ring.color = Color(1.0, 0.36, 0.36)     # 红 = 爆炸/定点 AOE（§1.2 语义）
		add_child(_ring)
		DebugStats.bucket_end(&"telegraph")

	func _process(p_delta: float) -> void:
		if host != null and (not is_instance_valid(host) or host.get("data") == null):
		# c4④（二cp#1④）：Boss 残血被反杀时满场雷「啪」瞬间消失零反馈——宿主失效
		# 且已过 arm 线的雷先原地引爆一次（_explode 空守卫已支持直调，爆炸环/
		# HazardPool 照走）再随 queue_free 摘除；未 arm 维持静默清（预警期无威胁无
		# 反馈）。_done 旗防 queue_free 摘除窗内重入二次引爆。二db M3：改传真实
		# 玩家——原 null 短路伤判造成「脚下雷零伤引爆窗」，且逐颗白送 dodge 层。
			if not _done and _t >= telegraph_s + arm_s:
				_done = true
				_explode(_get_player())           # 内部自含 queue_free——不再重复调用
				return
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
			var pd := global_position.distance_to(player.global_position)
			if not _threat_near and pd <= blast_r * 2.0:
				_threat_near = true                   # 二db M2 威胁门：armed 后玩家曾入 blast×2 圈
			if pd <= trigger_r:
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
		# 二db 躲雷正反馈：引爆未伤人（玩家在 blast 外/已离场）→ mine_dodged → 玩家橙盾
		#（触发即炸无逃跑窗——trigger_r<blast_r 同帧结算，所以「躲过」=没被炸到这一路；
		# 未 arm 静默清不走此，无威胁不授盾）
		var hit := false
		if p_player != null and is_instance_valid(p_player) \
				and global_position.distance_to(p_player.global_position) <= blast_r:
			(p_player as Player).take_contact_damage(dmg)
			hit = true
		if not pool_cfg.is_empty():
			var pool := HazardPool.new()
			pool.name = "HazardPool"
			pool.position = global_position
			pool.radius = float(pool_cfg.get("radius", 80.0))
			pool.life_s = float(pool_cfg.get("life_s", 3.0))
			# c4④：宿主失效臂引爆时 host 已释放——传 null 让 HazardPool 走完自身
			# life_s（否则首帧自毁，原地引爆只余一帧无读感）；host 存活路径语义不变
			pool.host = host if is_instance_valid(host) else null
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
		EventBus.emit_kill_blast(global_position, blast_r * 0.6)   # 爆炸环表现（复用通道；二db M1
	                                                          # dedent 出池分支——thorn 雷无池也有爆感）
		if not hit and _threat_near:
			EventBus.emit_mine_dodged(global_position)             # 二db：躲过（未伤人引爆）；
		                                                          # M2 威胁门——armed 后玩家曾入
		                                                          # blast×2 圈才算「躲过」（远离雷不授）
		queue_free()

	func _draw() -> void:
		# R271 P4：绘µs wrap（自绘件 _draw 计时入 &"draw" 桶——只加计不改行为；
		# 原体迁 _draw_r271，早退 return 由委托面兜底不漏收口）
		DebugStats.bucket_begin(&"draw")
		_draw_r271()
		DebugStats.bucket_end(&"draw")


	func _draw_r271() -> void:
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
		# R202 ⑥：static 弱引用缓存（BossMine/BossSweep/HazardPool 三附属共用
		# Enemy._appendage_player——每帧每件的 get_first_node_in_group C++ 组查询
		# 折为一次弱解引用；玩家释放后 WeakRef 落空自动重查。enemy._player() 成员缓存
		# 同语义先例）
		var p: Object = Enemy._appendage_player.get_ref() if Enemy._appendage_player != null else null
		if p != null and is_instance_valid(p):
			return p as Node2D
		var tree := get_tree()
		var found := tree.get_first_node_in_group(&"player") as Node2D if tree != null else null
		Enemy._appendage_player = weakref(found) if found != null else null
		return found


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
		# R271 P4：绘µs wrap（自绘件 _draw 计时入 &"draw" 桶——只加计不改行为；
		# 原体迁 _draw_r271，早退 return 由委托面兜底不漏收口）
		DebugStats.bucket_begin(&"draw")
		_draw_r271()
		DebugStats.bucket_end(&"draw")


	func _draw_r271() -> void:
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
		# R202 ⑥：static 弱引用缓存（同 BossMine._get_player——三附属共用单缓存）
		var p: Object = Enemy._appendage_player.get_ref() if Enemy._appendage_player != null else null
		if p != null and is_instance_valid(p):
			return p as Node2D
		var tree := get_tree()
		var found := tree.get_first_node_in_group(&"player") as Node2D if tree != null else null
		Enemy._appendage_player = weakref(found) if found != null else null
		return found


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
	var _drawn_once: bool = false                # R262b L2：首绘闩（fade 阶段才恢复重绘）

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
		# R262b L2：_draw 唯一随时间变量=末 1s 淡出 fade——前段输出恒定，首绘后停
		# 重绘（多雷/多潭同场时 N 件×60Hz 重录 4 基元的纯浪费项），末 1s 恢复逐帧
		if not _drawn_once:
			queue_redraw()
			_drawn_once = true
		elif life_s - _t <= 1.0:
			queue_redraw()

	func _draw() -> void:
		# R271 P4：绘µs wrap（自绘件 _draw 计时入 &"draw" 桶——只加计不改行为；
		# 原体迁 _draw_r271，早退 return 由委托面兜底不漏收口）
		DebugStats.bucket_begin(&"draw")
		_draw_r271()
		DebugStats.bucket_end(&"draw")


	func _draw_r271() -> void:
		var fade := clampf((life_s - _t) / 1.0, 0.0, 1.0)   # 末 1s 淡出
		var a := 0.85 * fade
		draw_circle(Vector2.ZERO, radius, Color(color.r, color.g, color.b, 0.14 * a))
		draw_arc(Vector2.ZERO, radius, 0.0, TAU, 36, Color(color.r, color.g, color.b, 0.7 * a), 3.0, true)
		draw_arc(Vector2.ZERO, radius * 0.7, 0.0, TAU, 28, Color(color.r, color.g, color.b, 0.25 * a), 2.0, true)

	func _get_player() -> Node2D:
		# R202 ⑥：static 弱引用缓存（同 BossMine._get_player——三附属共用单缓存）
		var p: Object = Enemy._appendage_player.get_ref() if Enemy._appendage_player != null else null
		if p != null and is_instance_valid(p):
			return p as Node2D
		var tree := get_tree()
		var found := tree.get_first_node_in_group(&"player") as Node2D if tree != null else null
		Enemy._appendage_player = weakref(found) if found != null else null
		return found


# ── 死亡弹爆（R19 打击质感；一次性自清表现件——毒爆残效同款模式） ──
# 白环收缩扩散 + 四向碎屑飞散 0.2s；宿主敌已归还，本件挂世界层自清。
# R188 档0：入池复用（原每杀 new+queue_free——高频击杀期节点 churn/尖峰根源；
# 复用协议 = 归还时 visible=false+停处理，跨场景重开悬挂引用由 is_instance_valid 剔除）。
class DeathPop:
	extends Node2D

	const LIFE := 0.2
	const POOL_MAX := 96                           # 池上限（风暴档实测并发 ~80；超池直接弃用不缓存）

	static var _free: Array = []                   # 空闲件栈（LIFO）
	static var _active: int = 0                    # 在外活跃数（acquire/release 双向记账）
	static var _pool_news: int = 0                 # 遥测：新建累计
	static var _pool_hits: int = 0                 # 遥测：复用累计

	var tint := Color.WHITE                        # G5 元素染色（死因元素迸色——构筑可读性）

	var _t: float = LIFE

	# R188 档0 池化发射口（替代 add_child(new)；发射 = 复用/新建 + 复位 + 挂层 + 激活）
	# R230 K2c：+豁免旗参（缺省 false 保持旧签名兼容）+并发帽许可口——被帽件不发射，
	# 仅 Enemy 侧计帽N；纯表现件，死亡结算/掉落链零触碰；挂层/复位序原样（绘制序不变）
	static func pop(p_parent: Node, p_pos: Vector2, p_tint: Color,
			p_is_boss: bool = false, p_is_elite: bool = false) -> void:
		DebugStats.bucket_begin(&"deathfx")   # R269：死µs 桶（函数体首尾 wrap——只加计时不改行为）
		if p_parent == null:
			DebugStats.bucket_end(&"deathfx")
			return
		if not Enemy._death_fx_admit(p_is_boss, p_is_elite):
			DebugStats.bucket_end(&"deathfx")
			return
		var item = _acquire(p_parent)
		item.tint = p_tint
		item.position = p_pos
		item._t = LIFE
		item.visible = true
		item.set_process(true)
		item.queue_redraw()
		if not p_is_boss:
			Enemy._death_fx_track(item)       # R230 K2c：非 Boss 件入册受帽（Boss 全保留）
		DebugStats.bucket_end(&"deathfx")

	static func _acquire(p_parent: Node) -> Object:
		while not _free.is_empty():
			var cand = _free.pop_back()
			if cand != null and is_instance_valid(cand):
				_pool_hits += 1
				_active += 1
				return cand
		_pool_news += 1
		var item = DeathPop.new()
		p_parent.add_child(item)
		_active += 1
		return item

	static func _release(p_item) -> void:
		# 归还（到期自清路径）：池未满入栈复用，超池弃用（七池 _prepare_for_pool 同款机械清理）
		DebugStats.bucket_begin(&"deathfx")   # R269：死µs 桶（_release 路径）
		if p_item == null or not is_instance_valid(p_item):
			DebugStats.bucket_end(&"deathfx")
			return
		_active -= 1
		Enemy._death_fx_untrack(p_item)       # R230 K2c：销册（幂等——Boss 件不在册）
		if _free.size() < POOL_MAX and not _free.has(p_item):
			p_item.visible = false
			p_item.set_process(false)
			_free.append(p_item)
		else:
			p_item.queue_free()
			DebugStats.count(&"perffx_qfree")  # R269：释N 计数（演出件 queue_free——释放成本以计数归因）
		DebugStats.bucket_end(&"deathfx")

	static func fx_pool_stats() -> Dictionary:
		# 基准池对账口径扩展（R188 档0）：{live, free, news, hits}——live 双向记账（在 ReleaseDiscard 场景下仍准确）
		return {"live": _active, "free": _free.size(), "news": _pool_news, "hits": _pool_hits}

	func _process(p_delta: float) -> void:
		_t -= p_delta
		if _t <= 0.0:
			_release(self)
			return
		queue_redraw()                          # 该 FX 件 _draw 全程随 _t 连续变（逐帧重绘必要）

	func _draw() -> void:
		# R271 P4：绘µs wrap（自绘件 _draw 计时入 &"draw" 桶——只加计不改行为；
		# 原体迁 _draw_r271，早退 return 由委托面兜底不漏收口）
		DebugStats.bucket_begin(&"draw")
		_draw_r271()
		DebugStats.bucket_end(&"draw")


	func _draw_r271() -> void:
		var t := 1.0 - clampf(_t / LIFE, 0.0, 1.0)
		var col := Color(tint.r, tint.g, tint.b, (1.0 - t) * 0.9)
		draw_arc(Vector2.ZERO, 8.0 + 22.0 * t, 0.0, TAU, 20, col, 3.0, true)
		draw_circle(Vector2.ZERO, 7.0 * (1.0 - t),
			Color(tint.r, tint.g, tint.b, (1.0 - t) * 0.5))
		for i in range(4):
			var a := TAU * float(i) / 4.0 + t * 1.2
			var d := 10.0 + 16.0 * t
			draw_circle(Vector2(cos(a), sin(a)) * d, 2.6 * (1.0 - t), col)

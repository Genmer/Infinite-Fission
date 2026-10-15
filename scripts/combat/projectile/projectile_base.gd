# scripts/combat/projectile/projectile_base.gd
# M-09 ProjectileBase（架构 §2.7.1）：投射物系统抽象基类。
# Q-15：弹-敌碰撞走 SpaceGrid 自管查询——不用 Area2D 回调，故基类为 Node2D（Sprite2D 子节点渲染）。
# 契约：
#   ① 六大生命周期事件唯一派发点（OnSpawn/OnTick/OnHit/OnPierce/OnBounce/OnExpire），
#      派发顺序 = 词条挂载顺序（确定性，B_spec M-09）；
#   ② 回收五路径统一收束 _recycle（EXPIRED/PIERCE_DEPLETED/BOUNCE_DEPLETED/NULLIFIED/FORCED）：
#      OnExpire 派发 → 状态清零 → 池归还（E-04 顺序断言）；
#   ③ 同帧同目标去重（E-03 帧聚合：hits_this_frame，一帧一目标一条）。
# 编排说明（§2.17）：本实体只做自身运动/碰撞/结算提交；tick(game_delta) 由 GameLoop 固定帧序驱动。
class_name ProjectileBase
extends Node2D

var uid: int = 0                              # GameConst.next_uid()
# R285 T1：弹运行序号（spawn 递增、单调不清——_reset_state 不复位的刻意例外）。
# 冲刷序守卫真源：命中对落缓冲时记录落对时刻的 serial，冲刷时 serial≠现值=该节点已
# 被回收且被 FRACTAL 子代 pool.acquire 复用 → 该弹剩余对全跳过（防幻影对以「子代
# 身份」误结算；关态无缓冲存活不受影响）。
var run_serial: int = 0
var team: int = 0                             # 0=玩家弹 1=敌方弹（消弹/命中判定分流）
var velocity: Vector2 = Vector2.ZERO
var lifetime_left: float = 0.0                # 寿命（超程/超时 → EXPIRED）
var pierce_left: int = 0                      # 穿透计数器（剩余可命中目标数）
var bounces_left: int = 0                     # 反弹计数器
# G4 回旋刃（W10）：出程减速 → 回程加速返航（双程伤害——pierce 走两遍敌群）
var _boomerang: bool = false
var _boom_phase: int = 0                       # 0=出程减速 1=回程返航
var _boom_speed_init: float = 0.0
var _boom_return_speed: float = 0.0              # 回程返航速度（加速爬升）
var _boom_origin: Vector2 = Vector2.ZERO         # R78 出手点（定距甩满的丈量原点）
var _boom_range: float = 340.0                   # R78 甩满距离（spawn range 注入）
var _boom_icd: Dictionary = {}                   # R78 同敌接触内冷 {uid: 剩余秒}
# R243 §5.1 末端分裂语义校准：ON_EXPIRE 整体前移闸——回旋弹在甩满/速度地板翻相点
# 派发一次 ON_EXPIRE 并消费 split_request（分裂落在甩满点=「范围延长」语义），_recycle
# 同段以本旗标守卫不再二次派发（搬迁非双发：防 FRACTAL+KILL_BLAST 双挂同一次击杀
# 在甩满点与回手各炸一次）。寿命兜底路径（翻相前 EXPIRED）与非回旋弹（恒 false）走
# 原 _recycle 派发行为不变。
var _boom_expire_fired: bool = false
const BOOM_HIT_ICD := 0.4                        # R78 多次接触结算间隔（平衡值）
# R191 用户反馈「回旋武器太小快看不见」：金色新月刃表现层放大倍率 ×5.0
# （纯表现——命中盒不变：碰撞半径走 hitbox_r×size_mult，与 sprite scale 完全解耦）
const BOOM_VIS_MULT := 5.0
# R243 法器弹体表现层放大（§2.2 飞剑 / §2.3 视觉斧体——纯表现命中盒不变，R191 同口径）：
# 二cu 剑光改版 ×3.2（9px 判定 → ~58px 剑光条，「一道道剑光刺过去」读感）/ 掷斧 ×2.2
const SWORD_VIS_MULT := 3.2
const AXE_VIS_MULT := 2.2
const SWORD_TRAIL_LEN := 42.0                   # 二cu：刺击残影 30→42px（剑光拖尾加长）
# R268 性能刀 P3②：刺击拖尾长度档位表（单源常量——fx_quality 0 档取半额，1/2 档原值；
# arc_slash.gd 档0 残影砍半同族先例。tier1(mobile q0)==SWORD_TRAIL_LEN*0.5、
# tier2/desktop==原值——档位断言面直读本表（qa_r268_physphase）。
const SWORD_TRAIL_LEN_BY_FXQ := [SWORD_TRAIL_LEN * 0.5, SWORD_TRAIL_LEN, SWORD_TRAIL_LEN]
# R268 性能刀 P3①：mobile 拖尾重绘半频门最小间隔（累计 1/30s 才置脏——渲轴满帽主嫌
# 减压；桌面/非 mobile 零变化）与测试注入口（-1=平台自动 / 0=桌面逐帧恒真 / 1=mobile
# 半频门——headless 无 mobile 特征位，套件用毕复位 -1）
const TRAIL_REDRAW_MIN_DT := 1.0 / 30.0
static var trail_halffreq_override: int = -1
# R271 S4：台架短路注入口（设计 §3.2 短路臂——trail_halffreq_override 同款先例：static
# 面 + 默认零短路；弹 tick 早退=纯注入态，产品默认逐位现状；计数仅供台架断言）
static var shortcircuit_tick: bool = false
static var tick_skip_count: int = 0
var generation: int = 0                       # 分裂代数（≤3，E-01）
var hitbox_radius: float = 6.0
var element: int = GameConst.Element.KIN
var attach_value: float = 0.0                 # 元素附着负载（命中时提交 ElementalSystem）
var size_mult: float = 1.0                    # 体积极限累计（碰撞盒/精灵等比）
# R187 W1 三线收束 steer 通道（共享组开放；武器组只传参——spawn 契约可选键）：
# 出膛横向偏移（lateral_gap px，符号与武器侧 position 偏移同号）在行进达
# range×converge_pct 前线性回收归瞄准线（55% 射程处三弹距瞄准线 <10px 验收口径）。
# 瞄准线方向缺省 = 初速方向（直线弹道即瞄准线）。
var _conv_gap: float = 0.0                    # 剩余横向偏移 px（0 = 无收束）
var _conv_gap0: float = 0.0                   # 出膛横向偏移快照（确定性重放用）
var _conv_dist: float = 0.0                   # 收束总距 px（range × converge_pct）
var _conv_done: float = 0.0                   # 已收束距离累计
var _conv_authored: bool = false              # 武器侧已用初速指焦点收束（steer 让位防双通道过冲）
var _corridor: bool = false                   # MEC_RICOCHET_HALL 回廊标记（反弹 offset 镜像）
var weapon_uid: int = 0                       # 来源武器（面板快照归属）
var weapon_ref: WeaponBase = null             # 来源武器引用（spawn 参数字典可选键——词条效果引擎侧结算通道，池化复位清零防陈旧引用）
var panel_snapshot: Dictionary = {}           # 武器面板快照 {base_atk, crit_rate, crit_mult, flat_bonus, add_entries[]}
# 包 3 收口：真件 TraitStack 替换鸭子接口（spawn 参数字典契约不变；引用类型收紧）
var trait_stack: TraitStack = null            # 本弹词条宿主（M-10 运行时栈副本）
var damage_pipeline: RefCounted = null        # 注入（结算入口；DamagePipelineStub 或包 1 真件）
var hits_this_frame: Dictionary = {}          # target_uid -> true（帧聚合，E-03）
# R220 刀8①：面板快照扁平字段（spawn 期展开一次——_build_damage_ctx 读字段不读字典，
# 省每命中 5 次 Dictionary.get；panel_snapshot 字典本体保留给其余消费点：分裂子代
# duplicate/接触伤害/元素附着/直接改写面板的测试夹具）。
var _panel_base_atk: float = 0.0
var _panel_flat_bonus: float = 0.0
var _panel_crit_rate: float = 0.0
var _panel_crit_mult: float = 2.0
var _panel_add_entries: Array = []            # add_entries 引用持有（不复制）
# R220 刀3①：EF_CRIT_SHARD 保守闸（spawn 期算一次）——true 才可能在 _prepare_hit_traits
# 尾部走武器侧直发段（false 整段跳过，省每命中 _stack_has_effect 逐词条转换）。
# 保守超集：运行栈载体 || 武器声明 TH_BANK_SHOT（bank-shot 达线在命中链内把
# ctx.crit_chance 置 1.0——纯面板 crit 闸会静默丢该交互）|| (TH_CRIT_SHARD 声明且
# 弹冻结面板 crit_rate ≥ 阈值)。
var _crit_shard_armed: bool = false
# R220 刀9：敌弹内联快路径缓存——team==1 且全判据过（见 spawn 期赋值处清单）时
# game_loop._tick_one_pool 分流走 _tick_fast；_fast_radius = effective_radius() spawn
# 快照（敌弹无词条通道 → size_mult 生命周期内不变）。
var _fast_path: bool = false
var _fast_radius: float = 0.0
# R231 刀B：玩家弹内联快路径缓存——team==0 直线池弹，spawn 期 ON_SPAWN 派发「后」判定
# （MEC_BOUNCE/EF_SIZE 在派发期写 bounces_left/size_mult，派发前判定会误标=行为回归
# 主洞，分析 AC-4）；判据/快照值清单见 spawn 尾部赋值处。game_loop._tick_one_pool
# 三缓冲分区驱动 _tick_fast_player；池化归还清零（_reset_state 防串弹）。
var _pfast: bool = false
# R231 刀B：射程通道字段上收基类（原 BallisticProjectile 独有——快路径 _tick_fast_player
# 须在基类内联超射程回收，分析 AC-6「玩家直线弹恒带 range>0，照搬敌弹『无 range 键』
# 判据则探针场景零收益」）。语义/初值/清零口不变（Ballistic._read_form_params 写入、
# _reset_form_state 清零、_move 消费），仅声明位上移；Homing 等其余子类不消费（零影响）。
var range_left: float = 0.0                   # 射程快照（>0 启用超射程判定；≤0 仅寿命过期）
var _traveled: float = 0.0                    # 已飞行里程（射程判定）
# R225（弹tick侧刀）：ON_TICK 派发 armed 快照（tick 期 payload 字典分配闸——判据与
# _dispatch_event 内 R210 has_event_hook 闸同源：仅 TraitStack 路径快照；直挂词条数组
# 通道挂钩面不可静态判且存在 spawn 后注入夹具 → tick 期 live 判定。spawn 期一次，归还清零）。
var _tick_dispatch_armed: bool = false
# R225（弹tick侧刀）：回旋刃接触内冷表 sweep 缓冲（tick 每帧两段清扫用——替代原
# _boom_icd.keys() 每帧数组分配；成员复用零每帧分配，R188 档0 _candidates 同先例）。
var _boom_icd_sweep: Array = []
# R196 FIX-2 生命周期级逐目标已命中表（同 _hit_exclusions/_boom_icd 池化 Dictionary 先例）：
# target_uid -> true——弹体一生一目标一条（RC3b：弹敌重叠接触带内逐 tick 重击同一存活
# 敌人耗光穿透预算，「再多贯穿 1 名敌人」从不发生）；回旋刃豁免不查不录（R78 接触节拍
# + G11 双程贯穿依赖同敌多次结算）
var _hit_uids: Dictionary = {}
# R232 刀1b：弹侧 DamageContext 复用件（DamagePipeline.CTX_REUSE 开关；借出即全字段
# 重置——重置清单见 _reset_ctx_scratch 头注，R220 _acquire_stack 同款纪律）。逃逸面
# 前提=分析 AC-3：全仓唯一跨帧持有者 pending 已同步袋化解除；词条 handle 九族全部
# 派发期内只读；嵌套 resolve（hit_burst/crit_shard/size nova）自建新 ctx 不碰 scratch。
var _ctx_scratch: DamageContext = null
var enemy_grid: SpaceGrid = null              # 注入（碰撞查询）
var pool: ProjectilePool = null               # 注入（回收归属）
# 包 3 收口：ElementalSystem 真件类型收紧（§4.4 ⑤ 附着通道）
var elemental: ElementalSystem = null         # 注入（元素附着入口）
# 包 3 收口：击杀证据（MEC_KILL_BLAST 死亡新星的 ON_EXPIRE 期判定输入）
var killed_target: bool = false               # 本弹存活期曾击杀（结算结果回填）
var last_hit_pos: Vector2 = Vector2.ZERO      # 最近命中位置（死亡新星锚点）
var is_clean: bool = true                     # 池清洁标记（归还/取出双向断言口径）
# ── R243 弹体形态键基建（§2.2/§2.3/§6.3；不含 §5.1 前移闸——那归 w2-boom） ──
var _flight_sword: bool = false               # 飞剑形态（W11）：直线高速刺击单体——子代继承键（防「大剑裂成圆点」）
var _flight_axe: bool = false                 # 掷斧幽灵飞行（W12）：途中无接触伤（_check_collision 敌判定跳过）
var _target_point: Vector2 = Vector2.ZERO     # 掷斧落点快照（发射时锁定；目标中途死亡不重锁）
var _shock_scale: float = 1.0                 # 落地震荡缩放（分裂子斧 = inherit_ratio；母斧恒 1.0）
var attach_elements: Array[int] = []          # 本发附着元素全集（§6.3——_build_trait_ctx 填 tctx.host_elements）
const AXE_ARRIVE_DIST := 24.0                 # 掷斧抵达判定距离 px（距 target_point ≤24 = 落地）
const AXE_CHILD_THROW := 120.0                # 子斧出掷距离 px（request_split 斧分支——§2.3 域校准）

# ── 内部运行时 ─────────────────────────────────────────────────
var _traits_cache: Array = []                 # 挂载词条数组快照（trait_stack.traits 引用；派发序=挂载序）
var _live: bool = false                       # 生命周期存活标志（spawn 置位 / _recycle 清除）
var _in_recycle: bool = false                 # _recycle 重入保护
var _had_bounces: bool = false                # 出生时携带反弹预算（区分 BOUNCE_DEPLETED / EXPIRED）
var _bounces_done: int = 0                    # 已反弹次数（HIT_IS_BOUNCE 条件）
var _pierce_hits: int = 0                     # 已命中序数（HIT_AFTER_PIERCE 条件）
var _player_cache: Node2D = null              # 敌弹/条件求值用玩家引用（组查找缓存）
var _screen := Vector2(720.0, 1280.0)        # 逻辑分辨率缓存（spawn 期从 GameConfig 刷新）
var _sprite: Sprite2D = null                  # 占位渲染子节点（美术后续替换）
# R188 档0 分配清扫：
var _candidates: Array[Node2D] = []           # 碰撞候选成员缓冲（替代每弹每帧新建数组；复制语义不变——
                                              # query_circle 返回内部复用缓冲，提交链路内的 AOE/重索敌会复用同一缓冲）
var _vis_variant: int = -1                    # 贴图变体缓存（-1 未初始化；spawn/reset/反弹失效）
var _vis_scale_q: float = -1.0                # 量化缩放缓存（1/32 级——肉眼不可辨阈值内跳过重设）
var _vis_rot_tracked: bool = false            # 当前变体是否逐帧跟踪速度朝向（曳光/导弹）
# R231 刀C②：视觉恒定旗标（spawn 尾部与 _pfast 同址计算，判据同源；_sync_visual 早退用
# ——立旗条件/证据见 spawn 尾部赋值处）。池化归还清零。
var _vis_invariant: bool = false
# R233 T5（决策4 swept 隧穿对策）：本步运动执行「前」的步前暂存位——swept 线段窄相的
# prev 单一来源。stash 点=运动行前（tick() 内 _move 调用前 / _tick_fast / _tick_fast_player
# 运动行前；Ballistic/Homing 覆写 _move 不调 super——stash 挂 tick 调用点才覆盖全部运动
# 模型）。与 T6 插值缓冲（_ip_prev/_ip_curr）彻底解耦：_ip_prev 在帧末快照语义下是
# N-2 步末位，用它扫的是两步位移（≤65px）→ 跨帧重复命中破守恒断言（分析 R3）；本字段
# 恒=上步末位（单步弦长口径），插值开/关与 headless 直驱三态语义一致。
var _swept_prev: Vector2 = Vector2.ZERO
# R233 T6（决策3.1 插值层）：渲染插值双缓冲——global_position 定性为「显示缓存」，模拟
# 真位以 _ip_curr 为准（恢复遍历帧入口还原 / 快照遍历帧末收编，时序见 game_loop）。
# 与 _swept_prev（T5 步前暂存）彻底解耦：_ip_prev=N-1 步末位、_ip_curr=N 步末位——
# _swept_prev 恒=本步运动前位，swept 线段窄相只读 _swept_prev（分析 R3 红线）。
# spawn 置位 prev=curr=出生位（防池上家残位飞入 + 中途 spawn 无跳变）；release 不清
# （设计 3.4：下任 spawn 重置覆盖，池内实体不在活跃表、三遍历天然豁免）。
var _ip_prev: Vector2 = Vector2.ZERO
var _ip_curr: Vector2 = Vector2.ZERO

const _VIS_ENEMY := 0                         # 敌方弹（珊瑚珠）
const _VIS_BOOM := 1                          # 回旋刃（金新月）
const _VIS_MISSILE_W6 := 2                    # W6 微导
const _VIS_MISSILE_W7 := 3                    # W7 集束火箭
const _VIS_TRACER := 4                        # W2 曳光条
const _VIS_MIRROR := 5                        # R187 镜面珠
const _VIS_GOLD := 6                          # R187 黄金弹（TH_BANK_SHOT 达线）
const _VIS_LTG_STAR := 7                      # 电花四角星
const _VIS_PLAIN := 8                         # 普通珠（KIN/FIR/ICE 着色在 apply 期按 element 取）
const _VIS_SWORD := 9                         # R243 飞剑（W11 §2.2）：剑形贴图顺速度方向 + 刺击残影
const _VIS_AXE := 10                          # R243 掷斧（W12 §2.3）：斧形贴图顺速度方向（幽灵飞行）

const OFFSCREEN_MARGIN := 96.0                # 出界回收余量（半径 + 边距）
const TEX_SIZE := 64                          # 弹珠贴图画布边长（逻辑半径 32，TextureFactory 口径）
# R225（弹tick侧刀）：回收原因计数键常量表（下标=RecycleReason 枚举值）——原 _recycle
# 每次 `StringName("recycle_reason_%d" % p_reason)` 字符串格式化 + StringName 构造
# （深载高周转每秒数百次回收各付一次）；查表后键名逐一同名，DebugStats 口径不变。
const _RECYCLE_REASON_KEYS: Array[StringName] = [
	&"recycle_reason_0", &"recycle_reason_1", &"recycle_reason_2",
	&"recycle_reason_3", &"recycle_reason_4",
]


func _ready() -> void:
	# 池化实例化期组装占位渲染（代码组装为主；.tscn 仅做容器，§1.4）
	_sprite = Sprite2D.new()
	_sprite.name = "Visual"
	_sprite.centered = true
	_sprite.texture = TextureFactory.bead(PopPalette.PLAYER, TEX_SIZE)
	add_child(_sprite)
	visible = false                            # 池内不可见（取出 spawn 后激活）


func spawn(p_params: Dictionary) -> void:
	# ★ 池取出后统一初始化（参数字典契约，冻结给包 3——架构 §2.7.1 注）：
	#   基础键：{velocity, lifetime, pierce, bounces, hitbox_radius, element, attach_value,
	#            generation, weapon_uid, panel_snapshot, trait_stack, team}
	#   可选键：{weapon_ref（来源武器引用——TH_SIZE_NOVA/MEC 系效果引擎侧结算通道，
	#            Variant 判 is WeaponBase 后赋值；飞行中武器可能被移除，消费侧须守卫）}
	#   Homing 追加：{target_uid, turn_rate, speed_init, speed_max, accel, arm_delay,
	#                blast_radius, blast_falloff}
	#   Ballistic 可选：{accel（默认 0）, range（默认 0 = 仅寿命过期）}
	#   便捷扩展键（可选）：{traits（直接词条数组——测试/过渡期）, position（出生点）}
	# 依赖注入（非初始值，不走参数字典）：damage_pipeline / enemy_grid / pool / elemental 由武器侧 acquire 后设置。
	uid = GameConst.next_uid()
	run_serial += 1                              # R285 T1：运行序号递增（单调——_reset_state 不清）
	velocity = p_params.get("velocity", Vector2.ZERO)
	lifetime_left = maxf(float(p_params.get("lifetime", 2.0)), 0.0)
	pierce_left = maxi(int(p_params.get("pierce", 1)), 0)
	bounces_left = maxi(int(p_params.get("bounces", 0)), 0)
	_boomerang = bool(p_params.get("boomerang", false))   # G4 回旋刃标记
	_boom_phase = 0
	_boom_speed_init = velocity.length()
	_boom_origin = global_position                    # R78 定距甩满原点
	_boom_range = maxf(float(p_params.get("range", 340.0)), 120.0)
	_boom_icd.clear()
	_had_bounces = bounces_left > 0
	hitbox_radius = maxf(float(p_params.get("hitbox_radius", 6.0)), 0.0)
	element = int(p_params.get("element", GameConst.Element.KIN))
	attach_value = float(p_params.get("attach_value", 0.0))
	generation = int(p_params.get("generation", 0))
	weapon_uid = int(p_params.get("weapon_uid", 0))
	team = int(p_params.get("team", 0))
	var snap: Variant = p_params.get("panel_snapshot", {})
	panel_snapshot = snap if typeof(snap) == TYPE_DICTIONARY else {}
	# 包 3 收口：TraitStack 真件类型收窄（契约键 trait_stack 语义不变）
	trait_stack = p_params.get("trait_stack", null) as TraitStack
	weapon_ref = null                            # 默认清零（可选键缺省 = 无宿主武器）
	var wref: Variant = p_params.get("weapon_ref", null)
	if wref is WeaponBase:
		weapon_ref = wref
	_traits_cache = []
	if trait_stack != null:
		var mounted: Variant = trait_stack.get("traits")
		if mounted is Array:
			_traits_cache = mounted
	var direct: Variant = p_params.get("traits", [])
	if direct is Array and not (direct as Array).is_empty():
		_traits_cache = direct
	if p_params.has("position"):
		position = p_params["position"]
		_boom_origin = global_position                # R78 出膛后取原点（position 落位在快照段之后）
	# R233 T5：swept 步前暂存位随 spawn 置出生位（首 tick 运动前再 stash 覆盖——防
	# spawn 后未 tick 的直接碰撞查询路径读到池上家残位）
	_swept_prev = global_position
	# R233 T6：插值缓冲随 spawn 置出生位（prev=curr=出生位——中途 spawn 无跳变；
	# 池上家残位防飞入。出生位在此已定型：position 可选键快照段落位之后）
	_ip_prev = global_position
	_ip_curr = global_position
	# R187 W1 收束 steer 通道参数（可选键缺省关闭——既有武器/测试零回归）：
	# 键名对齐修复：武器侧 spawn 传 "lateral_offset"（ballistic_weapon 编队出膛横向偏移，
	# 亦为回廊 offset 镜像基准）——本侧原读 "lateral_gap" 恒 0 死路，保留旧键回退兼容。
	_conv_gap = float(p_params.get("lateral_offset", p_params.get("lateral_gap", 0.0)))
	_conv_gap0 = _conv_gap
	_corridor = bool(p_params.get("corridor", false))
	_conv_authored = bool(p_params.get("converge_authored", false))
	var conv_pct := clampf(float(p_params.get("converge_pct", 0.0)), 0.0, 1.0)
	var conv_range := float(p_params.get("range", 0.0))
	_conv_dist = conv_range * conv_pct if conv_pct > 0.0 and conv_range > 0.0 else 0.0
	_conv_done = 0.0
	# R243 弹体形态键读参（§2.2/§2.3/§6.3——全可选键，缺省关闭零波及旧弹）：
	_flight_sword = bool(p_params.get("flight_sword", false))
	_flight_axe = bool(p_params.get("flight_axe", false))
	_target_point = p_params.get("target_point", global_position)
	_shock_scale = maxf(float(p_params.get("shock_scale", 1.0)), 0.0)
	attach_elements.clear()
	var attach_pool: Variant = p_params.get("attach_elements", [])
	if attach_pool is Array:
		for ev in (attach_pool as Array):
			attach_elements.append(int(ev))
	_read_form_params(p_params)
	hits_this_frame.clear()
	_hit_uids.clear()                             # R196 FIX-2：生命周期命中表随池取出清零（原地 clear，禁分配）
	_bounces_done = 0
	_pierce_hits = 0
	killed_target = false                     # 包 3 收口：击杀证据复位
	last_hit_pos = Vector2.ZERO
	is_clean = false
	_live = true
	_in_recycle = false
	if GameConfig.balance != null:
		_screen = Vector2(GameConfig.balance.res_logic)
	visible = true
	_vis_variant = -1                           # R188 档0：贴图变体缓存失效（team/武器/元素已换）
	_sync_visual()
	# R220 刀8①：面板快照 5 键展开为弹上字段（spawn 一次；_build_damage_ctx 读字段）
	_panel_base_atk = float(panel_snapshot.get("base_atk", 0.0))
	_panel_flat_bonus = float(panel_snapshot.get("flat_bonus", 0.0))
	_panel_crit_rate = float(panel_snapshot.get("crit_rate", 0.0))
	_panel_crit_mult = float(panel_snapshot.get("crit_mult", 2.0))
	var adds_snap: Variant = panel_snapshot.get("add_entries", [])
	_panel_add_entries = adds_snap if adds_snap is Array else []
	# R220 刀3①：EF_CRIT_SHARD 保守闸 spawn 期一次（_stack_has_effect 仅此处调用——
	# 命中链不再逐词条扫描）。TH_BANK_SHOT 并入 armed：ballistic_weapon._apply_bank_shot
	# 在命中链内达线置 ctx.crit_chance=1.0，面板 crit<阈值的 W1 黄金弹必须保触发。
	_crit_shard_armed = _stack_has_effect(&"EF_CRIT_SHARD")
	if not _crit_shard_armed and weapon_ref != null and is_instance_valid(weapon_ref):
		if not weapon_ref.get_threshold(&"TH_BANK_SHOT").is_empty():
			_crit_shard_armed = true
		else:
			var crit_th: Dictionary = weapon_ref.get_threshold(&"TH_CRIT_SHARD")
			if not crit_th.is_empty() \
					and _panel_crit_rate >= float(crit_th.get("threshold", 0.6)):
				_crit_shard_armed = true
	# R220 刀9：敌弹快路径判据（spawn 期一次；false 回落慢路径保语义）。逐条=敌弹
	# spawn 点（enemy.gd:1006-1014 / :1581-1587）参数域已核实的 no-op 项：
	#   bounces==0（edge bounce 双调无分支命中）/ 非 boomerang（回旋运动不可达）/
	#   _conv_gap==0（converge steer 首行守卫直返，projectile_base.gd:236 同文件）/
	#   无词条（ON_TICK 闸本就直通、size_mult 生命周期不变 → 半径可快照）/
	#   element 非 LTG（电花自旋为纯表现且敌弹恒 KIN）/
	#   无 accel/range 键（Ballistic._move 的加减速与射程判定退化匀速直线）。
	# ⚠PR 检查单：新 team=1 spawn 点必须最小参数（同上域）；带 bounce/词条/converge/
	#   boomerang/LTG/accel/range 的敌弹会被本判定自动回落慢路径，但请同步评审
	#   _tick_fast 跳过清单是否仍为 no-op。
	_fast_path = team == 1 and bounces_left == 0 and not _boomerang \
		and _conv_gap == 0.0 and not _has_any_trait() \
		and element != GameConst.Element.LTG \
		and float(p_params.get("accel", 0.0)) == 0.0 \
		and float(p_params.get("range", 0.0)) <= 0.0
	_fast_radius = effective_radius()
	# R225（弹tick侧刀）：ON_TICK armed 快照（判据=R210 has_event_hook 同口径——见
	# tick 内注释；直挂数组通道不走快照，tick 期 live 判定兼容 spawn 后注入夹具）。
	if trait_stack is TraitStack:
		_tick_dispatch_armed = (trait_stack as TraitStack).has_event_hook(
			GameConst.TraitEvent.ON_TICK)
	else:
		_tick_dispatch_armed = false
	_dispatch_event(GameConst.TraitEvent.ON_SPAWN)
	# R231 刀B：玩家弹快路径判据——必须在 ON_SPAWN 派发「之后」取终值（MEC_BOUNCE
	# 派发期写 bounces_left += 预算、EF_SIZE 派发期写 size_mult：派发前判定会把跳弹弹
	# 误标快路径=漏反弹物理、半径快照陈旧——分析 AC-4 两处必改项之一）。
	# ⚠PR 检查单（分析 AC-6 全量清单）：直线池 team=0 spawn 点共 3 处——
	#   ballistic_weapon.gd:181（主/镜面变体同路径）、player.gd:1502 僚机直发、
	#   projectile_base.request_split 子代（trait_stack=copy_for_split 仅 inheritable
	#   词条：MEC_FRACTAL=true，MEC_BOUNCE/AFF_*/EF_SIZE 均 false→子代保持资格）。
	#   新 spawn 点落判据外的弹自动回落慢路径（保语义），落地前请核对 _tick_fast_player
	#   跳过清单是否仍逐项 no-op。
	# 逐条 no-op 证据（对照 tick() 慢路径；分析 AC-1/2/3/4/6）：
	#   · bounces_left（R235 4a 放宽：跳弹弹入快路径——贴边带预检在 _tick_fast_player
	#     回落 _check_edge_bounce 本体，未贴边帧慢链逐项 no-op；_had_bounces 兜
	#     BOUNCE_DEPLETED 同判）；
	#   · not _boomerang → 回旋运动/_boom_icd 清扫不可达；
	#   · _conv_gap==0.0 → _apply_converge_steer 首行守卫直返；
	#   · element!=LTG → 电花自旋（纯表现）不可达；
	#   · trait_stack is TraitStack → 无栈弹（null）一律慢路径——spawn 后 _traits_cache
	#     注入通道（R225 qa_r220_simchain ③a 夹具先例：直挂数组/挂钩 spawn 后注入须
	#     live 可见）在快路径跳过 ON_TICK 闸下会静默丢触发（电池 ③a 五断言实锤）；
	#     生产直线弹恒带 acquire_runtime() 栈（ballistic_weapon）、分裂子代恒
	#     copy_for_split 栈——仅 player.gd:1502 僚机直发无栈失格（披露，量级小）；
	#   · not _stack_has_effect(EF_SIZE) → 资格弹半径/变体 spawn 后无非 spawn 期写者
	#     （AC-4 复核清零）→ 跳过 _sync_visual 逐位 no-op（量化比较恒不触发；曳光/导弹
	#     变体 rotation 恒定——资格弹速度方向不变，AC-3）；
	#   · accel==0 → Ballistic._move 加速分支退化匀速直线（玩家侧无 accel 写者，纯防御）。
	_pfast = team == 0 and not _boomerang \
		and not _flight_axe and not _flight_sword \
		and _conv_gap == 0.0 and element != GameConst.Element.LTG \
		and not _tick_dispatch_armed \
		and trait_stack is TraitStack \
		and float(p_params.get("accel", 0.0)) == 0.0 \
		and not _stack_has_effect(&"EF_SIZE")
	# （R235 4a：bounces_left 子句移除——跳弹弹入快路径，贴边帧由 _tick_fast_player
	# 预检回落 _check_edge_bounce 本体保语义；range 超程判定自带 bounces_left<=0 豁免。）
	_fast_radius = effective_radius()            # ON_SPAWN 后终值（size_mult 派发期改写已定）
	# R231 刀C②：视觉恒定旗标（与 _pfast 同址同源；spawn 期 :215 首帧 _sync_visual 已完成
	# 变体解析，_vis_rot_tracked 此处可用）。立旗条件与逐位 no-op 证据：
	# · not _stack_has_effect(EF_SIZE) → size_mult 无非 spawn 期写者（AC-4 复核清零）→
	#   scale_q 量化比较恒等；
	# · bounces_left==0 ∧ not _had_bounces → 反弹失效重判（_apply_bounce 置
	#   _vis_variant=-1）与 TH_BANK_SHOT 金染升格不可达 → 变体失效位恒不触发；
	# · not _boomerang → BOOM 变体 ×5 视觉面不参与；
	# · not _vis_rot_tracked → 曳光/导弹朝向刷新分支（elif）结构性不可达——朝向跟踪
	#   变体排除出旗标面（保守：homing 转向弹全程慢路径须真实刷新，转向弹恒 tracked）。
	# EF_SIZE/升格路径/朝向跟踪弹不立旗（本证）。team==0 = 刀B 同域。
	_vis_invariant = team == 0 and not _boomerang \
		and bounces_left == 0 and not _had_bounces \
		and not _stack_has_effect(&"EF_SIZE") \
		and not _vis_rot_tracked


func tick(p_game_delta: float) -> void:
	# 运动学 → 出界/寿命 → 网格查询 → 帧聚合命中提交（GameLoop ④ 驱动）
	if shortcircuit_tick:                   # R271 S4：台架短路（默认 false=零短路零成本）
		tick_skip_count += 1
		return
	if not _live:
		return
	hits_this_frame.clear()
	lifetime_left -= p_game_delta
	if lifetime_left <= 0.0:
		if _flight_axe:
			_axe_land()                     # R243 寿命兜底=现场落地（§2.3——碎裂语义一致，仍走 FORCED 回收派发 ON_EXPIRE）
			return
		_recycle(GameConst.RecycleReason.EXPIRED)
		return
	if _flight_axe:
		if _axe_step(p_game_delta):
			return                          # R243 抵达落地回收——本帧不再落位
	if _boomerang:
		# R225（弹tick侧刀）：内冷清扫两段化——原 `for uid in _boom_icd.keys()` 每帧
		# 分配键数组；现先原地减时、到期 uid 收进成员 sweep 缓冲（复用零分配），再统一
		# erase（Dictionary 迭代期只改值不增删键，安全；语义与逐键减时逐键擦除逐位一致）。
		_boom_icd_sweep.clear()
		for uid in _boom_icd:
			var icd_left: float = float(_boom_icd[uid]) - p_game_delta
			if icd_left <= 0.0:
				_boom_icd_sweep.append(uid)
			else:
				_boom_icd[uid] = icd_left
		for uid in _boom_icd_sweep:
			_boom_icd.erase(uid)
		if _boom_step(p_game_delta):
			return                            # G4 回旋运动接管；收回即回收本帧不再落位
	_swept_prev = global_position                 # R233 T5：步前暂存（运动执行前——swept prev=上步末位）
	_move(p_game_delta)
	if not _live:
		return
	_apply_converge_steer(p_game_delta)       # R187 W1 三线收束（横向偏移线性归瞄准线）
	_check_edge_bounce()                        # R15：基类统一边界反弹（弹道覆写内亦有调用——幂等）
	if not _live:
		return
	_check_offscreen()
	if not _live:
		return
	_sync_visual()
	if element == GameConst.Element.LTG and _sprite != null:
		_sprite.rotation += p_game_delta * 10.0   # 电花自旋（星形电弹读感——去球化配套）
	if _boomerang and _sprite != null:
		_sprite.rotation += p_game_delta * 16.0   # G4 旋刃高速自旋
		if _trail_redraw_due(p_game_delta):       # R268 性能刀 P3①：mobile 半频门（桌面恒真零变化）
			queue_redraw()                        # G6 拖尾弧重绘
	elif _flight_sword:
		if _trail_redraw_due(p_game_delta):       # R268 性能刀 P3①：同门（灵剑逐帧尾迹半频）
			queue_redraw()                        # R243 刺击残影重绘（拖刺击读感）
	# R225（弹tick侧刀）：ON_TICK 派发闸改 armed 快照 + 直挂通道 live 兜底——原
	# `if _has_any_trait()` 闸放行后，调用点 payload 字典 `{"game_delta": ...}` 每弹
	# 每帧无条件分配，而 _dispatch_event 内 R210 has_event_hook 闸（数据侧 ON_TICK
	# 挂钩为零，R225 全量复核 resources/traits/*.tres event_hooks 无一含值 1）立即
	# null 返回——字典成死分配（深载夹具每弹 12 词条栈：~420 弹 ×60Hz ≈ 2.5 万次/秒）。
	# · TraitStack 路径（生产）：armed=false 时整段跳过与「调用后 null 返回」逐位等价
	#   （返回值本处无消费点）；快照口径与 R220 刀3① _crit_shard_armed / 刀9
	#   _fast_path 同先例（运行栈借出期词条面不变，主栈 attach 走世代失效换新栈）。
	# · 直挂数组通道（测试/过渡）：保留 live 判定——qa_r220_simchain ③a 夹具在
	#   spawn 后注入 _traits_cache（旧代码 live 查可见），快照化会静默丢触发。
	if _tick_dispatch_armed or (not (trait_stack is TraitStack)
			and not _traits_cache.is_empty()):
		_dispatch_event(GameConst.TraitEvent.ON_TICK,
			{"game_delta": p_game_delta})
	# R285 T1：boost 门内命中步分流（〔v2·M2〕静态 bool 帧级缓存——非 boost_mode() 直读；
	# 关态零新增调用=现状逐字路径）。boost 开=收集制（查询+窄相同口径，命中对落
	# GameLoop 帧缓冲、④ 尾统一提交）；RNG 契约变更声明见 _collect_hit_pairs 头注。
	if team == 0 and GameLoop.grid_hit_frame:
		_collect_hit_pairs()
	else:
		_check_collision()


func _tick_fast(p_gd: float, p_player: Node2D, p_player_r: float) -> void:
	# R220 刀9：敌弹内联快路径（game_loop._tick_one_pool team 分区专用；判据在 spawn 期
	# 缓存 _fast_path——见 spawn 内 ⚠PR 检查单）。与 tick() 慢路径的四断言语义逐位等价，
	# 分支序保持慢路径原序（寿命 → 位移 → 出界 → 撞玩家）。跳过项逐条 no-op 证据：
	#   · hits_this_frame.clear()——敌弹无 _submit_hit 调用者，字典恒空，clear=纯开销；
	#   · boomerang 块——spawn 无 boomerang 键（不可达，判据已含 not _boomerang）；
	#   · _apply_converge_steer——_conv_gap==0.0 首行守卫直返（:236 同文件）；
	#   · _check_edge_bounce（基类+Ballistic 双调）——bounces_left==0 且 _had_bounces==false
	#     → 四边 normal 计算后无分支命中；
	#   · _sync_visual——敌弹半径/变体 spawn 后不变（无词条/无反弹）→ floorf 量化比较
	#     恒不触发重设，纯计算省去；
	#   · LTG 电花自旋——敌弹 element 恒 KIN（enemy spawn 无 element 键；纯表现）；
	#   · ON_TICK 闸——无 trait_stack/直挂词条 → _has_any_trait()==false 本就直通；
	#   · _check_collision 的 team 分派——team==1 恒走 _check_player_hit，此处直排。
	# 半径用 _fast_radius（spawn 快照）；伤害读 _panel_base_atk（spawn 期扁平字段——敌弹
	# 无中途改写面板通道）。每步仍驱动（只减每步调用数不减驱动步数——不引入 2δ 隧穿）。
	# 回收统一走 _recycle（E-04 契约，回收原因与慢路径逐位一致）。
	if not _live:
		return
	lifetime_left -= p_gd
	if lifetime_left <= 0.0:
		_recycle(GameConst.RecycleReason.EXPIRED)
		return
	# R233 T5：步前暂存（字段单步语义全弹统一；敌弹撞玩家判定面不动——决策4「不动」项，
	# 敌弹速 ≤560 → 步长 18.7px vs reach 直径 44px 富余充足）
	_swept_prev = global_position
	global_position += velocity * p_gd
	var m := _fast_radius + OFFSCREEN_MARGIN
	var g := global_position
	if g.x < -m or g.x > _screen.x + m or g.y < -m or g.y > _screen.y + m:
		_recycle(GameConst.RecycleReason.EXPIRED)
		return
	if p_player != null and is_instance_valid(p_player):
		var reach := _fast_radius + p_player_r
		if g.distance_squared_to(p_player.global_position) <= reach * reach:
			if p_player is Player:
				(p_player as Player).take_contact_damage(_panel_base_atk)
			elif p_player.has_method(&"take_contact_damage"):
				p_player.call(&"take_contact_damage", float(panel_snapshot.get("base_atk", 0.0)))
			_recycle(GameConst.RecycleReason.PIERCE_DEPLETED)


func _tick_fast_player(p_gd: float) -> void:
	# R231 刀B：玩家弹内联快路径（game_loop._tick_one_pool 三缓冲分区驱动；资格判据
	# 在 spawn 期 ON_SPAWN 派发后缓存 _pfast——清单见 spawn 尾部）。分支序=慢路径原序：
	# 寿命 → 直线运动 → range 超程 → 贴边带预检回落（R235 4a——跳弹弹专属，见下）→
	# 出界 → 接触预检回落。与敌弹 _tick_fast 的差异：
	# · hits_this_frame.clear() 保留——玩家弹是 E-03 帧聚合消费者（清零口=spawn/_reset_state
	#   原地 clear，此处 per-tick 清空语义与慢路径 tick() 逐位一致）；
	# · range 内联（AC-6：玩家直线弹恒带 range>0，超射程 EXPIRED 是活语义）——判定式与
	#   Ballistic._move 逐字同款（range_left>0 ∧ _traveled≥range_left ∧ bounces_left≤0 ∧
	#   非 boomerang；R15 豁免语义随判据天然成立），序=运动后、出界判定前，回收点同位；
	# · 接触预检 query_circle_snap 非空即回落 _check_collision()——完整重查+候选复制+
	#   live 窄相+_submit_hit 链零改动（伤害/词条/穿透/回收链一行不动）。
	#   R5 缓冲别名纪律：预检只读返回缓冲的非空性，随即回落完整重查——不得持缓冲跨查询
	#   （提交链内 AOE/重索敌查询会复用同一缓冲）。
	# 跳过项（boomerang 块/converge steer/edge bounce/_sync_visual/LTG 自旋/ON_TICK 闸）
	# no-op 证据见 spawn 尾部判据清单；R235 4a 后跳弹弹的 edge bounce 改为贴边帧真实
	# 回落（仅无预算弹仍 no-op）；_fast_radius 为 ON_SPAWN 后终值快照（EF_SIZE 排除
	# ⇒ 半径生命周期不变）。每步仍驱动（不引入 2δ 隧穿）；回收统一 _recycle（E-04，
	# 回收原因与慢路径逐位一致）。
	# 评审 LOW#1 披露：速度恰与壁面平行（dot(normal)==0）且贴边的退化点下，慢路径
	# 每 tick 双调 _check_edge_bounce 会连烧 2 跳预算（双调幂等在该点不成立——慢路径
	# 自身病态），快路径单调只烧 1 跳——玩家移动 clamp（r16）+有机散射下结构性不可达，
	# 披露不修（修=动慢路径判据，等价面另行收口）。
	if not _live:
		return
	hits_this_frame.clear()
	lifetime_left -= p_gd
	if lifetime_left <= 0.0:
		_recycle(GameConst.RecycleReason.EXPIRED)
		return
	# R233 T5：步前暂存（运动执行前——swept prev=上步末位）
	_swept_prev = global_position
	global_position += velocity * p_gd
	_traveled += velocity.length() * p_gd
	if range_left > 0.0 and _traveled >= range_left and bounces_left <= 0 and not _boomerang:
		_recycle(GameConst.RecycleReason.EXPIRED)
		return
	# R235 4a：跳弹臂贴边带预检（spawn 判据已放宽 bounces_left>0 入快路径）。四边比较
	# 与 _check_edge_bounce 本体同源同半径（_fast_radius==effective_radius()——EF_SIZE
	# 已判据排除 ⇒ 半径生命周期不变）；未贴边=直通（跳弹弹 95%+ 中场直飞，慢链全 no-op）；
	# 贴边=回落本体（反射/BOUNCE_DEPLETED/离面判定/回廊镜像/ON_BOUNCE 全在 _apply_bounce
	# 内自动照走），反射发生（_bounces_done 变化）补一次 _sync_visual（慢路径 tick() 每帧
	# _sync_visual 的同职——_apply_bounce 置 _vis_variant=-1 需单帧刷新）。序=运动后、
	# 出界判定前（慢路径原序：先反弹再出界，防贴边反弹帧口径漂移）。
	if bounces_left > 0 or _had_bounces:
		var br := _fast_radius
		var gp := global_position
		if gp.x <= br or gp.x >= _screen.x - br or gp.y <= br or gp.y >= _screen.y - br:
			var b0 := _bounces_done
			_check_edge_bounce()
			if not _live:
				return                          # BOUNCE_DEPLETED（预算耗尽贴边帧）
			if _bounces_done != b0:
				_sync_visual()
	var m := _fast_radius + OFFSCREEN_MARGIN
	var g := global_position
	if g.x < -m or g.x > _screen.x + m or g.y < -m or g.y > _screen.y + m:
		_recycle(GameConst.RecycleReason.EXPIRED)
		return
	# R235 4b：命中弹双查询合并——预检半径升为与 _check_collision 完全同口径的 query_r
	# （er + 30Hz 弦半膨胀；er==_fast_radius 判据下 ≥ 原 pre_r 恒成立），结果直接复制进
	# _candidates（R5 别名纪律：复制后不持返回缓冲），非空回落 _check_collision(true)
	# 跳过重查直走窄相+提交链（候选=同口径超集，窄相裁定不变）；空=现状直通。
	# R285 T1：boost 门内命中步分流（收集制——同口径查询在 _collect_hit_pairs 内完成，
	# 不复制候选、不即时结算；〔v2·M2〕静态 bool 帧级缓存读零字典查）。
	if GameLoop.grid_hit_frame:
		_collect_hit_pairs()
	elif enemy_grid != null:
		var er := effective_radius()
		var query_r := er
		if GameLoop.sim30_effective():
			query_r += (global_position - _swept_prev).length() * 0.5
		_candidates.clear()
		_candidates.append_array(enemy_grid.query_circle_snap(global_position, query_r))
		if not _candidates.is_empty():
			_check_collision(true)


func _move(p_game_delta: float) -> void:
	# 抽象：子类运动模型（直线/转向插值）。基类=匀速直线。
	global_position += velocity * p_game_delta


func _apply_converge_steer(p_game_delta: float) -> void:
	# R187 W1 三线收束 steer 通道（共享组开放）：横向偏移随行进线性回收——
	# 每前进 1px 回收 gap0/_conv_dist 比例份，至 range×converge_pct 处恰归瞄准线
	#（验收：L5 弹步进至 55% 射程三弹距瞄准线 <10px）。纯几何位移、不改速度方向
	#（不与索敌/反弹语义耦合）；速度近零（测试静止弹）时按 0 行进自然不动。
	if _conv_gap == 0.0 or _conv_dist <= 0.0 or _conv_done >= _conv_dist:
		return
	if _conv_authored:
		return                                 # 武器侧初速指焦点已收束——steer 让位（防双通道过冲）
	var spd := velocity.length()
	if spd <= 1.0:
		return
	var step := minf(spd * p_game_delta, _conv_dist - _conv_done)
	# shift 只取模长（gap0 带符号会让负 gap 侧发散——键名激活前通道恒 0 死路不可见的
	# 潜伏符号 bug），方向由 signf(_conv_gap) 单一提供：±lane 双侧均向瞄准线收束
	var shift := absf(_conv_gap0) * (step / _conv_dist)
	var perp := velocity.normalized().orthogonal()
	shift = minf(shift, absf(_conv_gap))      # 收束末端防过冲（浮点残差钳制）
	global_position -= perp * shift * signf(_conv_gap)
	_conv_gap -= shift * signf(_conv_gap)
	_conv_done += step


func _boom_step(p_game_delta: float) -> bool:
	# G4 回旋刃运动接管：出程指数减速（撒出）→ 低速翻转 → 回程向玩家加速返航（收线）。
	# 只改写 velocity，落位仍由 _move 完成；返回 true = 已回收（tick 跳过本帧 _move）。
	if _boom_phase == 0:
		# R78 定距甩满：轻衰减（0.55/秒——手感保留），到位即翻（固定距离，不随命中/速度变化）
		velocity *= pow(0.55, p_game_delta)
		if global_position.distance_to(_boom_origin) >= _boom_range:
			_boom_fire_expire()               # R243 §5.1：ON_EXPIRE 前移到甩满翻相点（分裂落甩满点）
			_boom_phase = 1
			_boom_return_speed = velocity.length()
		elif velocity.length() <= 60.0:
			# R241 ③ 速度地板翻相：边界反弹（R15 跳弹）把方向折回后距原点可能回缩→
			# 永达不到甩满距离——TH_BOUNCE_ETERNAL 永存门（999s 寿命）下速度指数衰减
			# 至 ~0 = 死刃滞空 999s 累积。正常甩满在 ~150px/s 前已达成（520→∫=870px>380），
			# 地板 60 仅在反弹折返/异常态触达=兜底翻转回家（起步速给地板值就近爬升）。
			_boom_fire_expire()               # R243 §5.1：速度地板兜底翻相同享前移闸（一次派发）
			_boom_phase = 1
			_boom_return_speed = 160.0
	else:
		var player := _find_player()
		if player == null:
			return false                          # 无锚点：维持漂移交由寿命兜底
		var to_player: Vector2 = player.global_position - global_position
		_boom_return_speed = move_toward(_boom_return_speed, 860.0, 1500.0 * p_game_delta)
		velocity = to_player.normalized() * _boom_return_speed
		if to_player.length() <= 28.0:
			_recycle(GameConst.RecycleReason.FORCED)   # 收回——整段双程伤害结算完毕
			return true
	return false


func _boom_fire_expire() -> void:
	# R243 §5.1 末端分裂语义校准：ON_EXPIRE 整体前移到甩满/速度地板翻相点（搬迁非双发，
	# 不动 R241 三锁——0.55 系数/boomerang 键/寿命地板 1.2 逐位未触碰）。原派发点 =
	# 返航到手 28px 的 _recycle（EF_FRACTAL 分裂恒发生在玩家身边 =「从角色分裂」读感）；
	# 前移后全部 ON_EXPIRE 词条在甩程末端收束一次：
	# · EF_FRACTAL：分裂落在甩满点（子代位≈翻相位非玩家位——需求 9「范围延长」语义）；
	# · MEC_KILL_BLAST：时点从回手提前到甩程末端，爆炸位仍 = last_hit_pos
	# 	（trait_effect_mech.gd:45 结算位与派发时点无关），无 killed_target 时 guard 原样不炸。
	# _recycle 侧同段以 _boom_expire_fired 守卫——翻相过的回旋弹不再二次派发（同一次
	# 击杀不双炸）；仅回旋翻相路径置位，非回旋弹/寿命兜底路径恒走原 _recycle 派发。
	if _boom_expire_fired:
		return
	_boom_expire_fired = true
	var tctx := _dispatch_event(GameConst.TraitEvent.ON_EXPIRE)
	if tctx != null and not tctx.split_request.is_empty():
		var request: Dictionary = tctx.split_request
		request_split(int(request.get("count", 0)), float(request.get("spread_deg", 0.0)),
			float(request.get("inherit_ratio", 0.0)), bool(request.get("echo", false)))


func _axe_step(p_game_delta: float) -> bool:
	# R243 掷斧幽灵飞行推进（§2.3，_boom_step 同款节拍模式）：每 tick 向 target_point
	# 匀速推进（落点发射时快照——目标中途死亡不重锁）；返回 true = 已落地回收（tick 跳过
	# 本帧 _move）。抵达判定 = 距 target_point ≤ AXE_ARRIVE_DIST(24px) 或本步可跨。
	# 注意：本函数只改写 velocity（直指落点），落位仍由 _move 完成。
	if not _live:
		return false
	var to_target := _target_point - global_position
	var dist := to_target.length()
	var step := velocity.length() * p_game_delta
	if dist <= AXE_ARRIVE_DIST or (step > 0.0 and dist <= step):
		_axe_land()
		return true
	if step > 0.0:
		velocity = to_target.normalized() * velocity.length()
	return false


func _axe_land() -> void:
	# R243 斧抵达时序（§2.3）：weapon.on_axe_land(pos)（震荡+清弹+特效——w2 交付）
	# → _recycle(FORCED)。斧的回收点即其正常 ON_EXPIRE 触发点（不涉 §5.1 回旋前移闸）
	# → 挂 MEC_FRACTAL 时由 _recycle 统一派发子斧。weapon 未交付 on_axe_land（w2 前）
	# 或已失效：静默落地回收不崩（load 守卫同纪律）。速度零向量（异常桩）：直接落地。
	if weapon_ref != null and is_instance_valid(weapon_ref) \
			and weapon_ref.has_method(&"on_axe_land"):
		weapon_ref.call(&"on_axe_land", global_position)
	_recycle(GameConst.RecycleReason.FORCED)


func _read_form_params(p_params: Dictionary) -> void:
	# 子类形态参数读取钩子（Homing 八键 / Ballistic 可选 accel、range）
	pass


func _reset_form_state() -> void:
	# 子类形态清零钩子（与 _reset_state 同步）
	pass


func is_player_projectile() -> bool:
	return team == 0


func effective_radius() -> float:
	# 碰撞半径（体积极限词条等比放大）
	return hitbox_radius * size_mult


# ── 碰撞（SpaceGrid 自管查询，Q-15） ────────────────────────────
func _collect_hit_pairs() -> void:
	# R285 T1：boost 网格命中路径收集段——查询+窄相与 _check_collision 逐字同口径
	# （三守卫同序同判定、同 query_r 式、同 _in_reach/_in_reach_swept 本体），差异仅
	# 两点：①候选**不复制**进 _candidates（复用 query_circle_snap 返回缓冲就地窄相
	# ——R235 4b 的 append_array 复制消除；R5 别名纪律：窄相循环内不再发起任何网格
	# 查询）；②**不即时 _submit_hit**——窄相通过者落 GameLoop 帧对缓冲，④ 尾
	# _flush_hit_pairs 按收集自然序统一提交。
	# ── R285 RNG 契约变更声明（boost 开侧限定；照 R226 拆帽/R268 P1 先例）──
	# boost 开启时命中结算时点从「各弹 tick 槽内即时」改为「④ 尾统一冲刷」，由此允许：
	# ①同帧内 ctx.player_hp_pct / ctx.is_first_hit_of_wave 条件读取先后序漂移；
	# ②homing 弹在「同帧 AOE 击杀原目标」场景下的重索敌时点漂移（收集段先于冲刷段）；
	# ③死亡 fan-out 内全局 rng 消费相对管线结算法（独立流）的交错序漂移；④同帧多杀
	# 击杀连锁读数漂移（dead 旗全部在对提交段置位先于任何 fan-out——燎原点燃目标集
	# 单向收窄等，详见 enemy._death_fanout 头注）。**承诺不变面**：单体结算链数值
	#（乘区/暴击概率/抗性九步管线零改动）、命中率统计期望（命中判定距离式零改动）、
	# 穿透/反弹预算语义、E-03/R196 去重契约、六大生命周期事件派发序。boost 关侧零
	# 执行（pkg4 seed=42 116 项零位移）。
	if team == 1:
		return
	if _flight_axe:
		return                              # R243 掷斧幽灵飞行守卫（与 _check_collision 同位）
	if enemy_grid == null:
		return
	var timed := GameLoop.prof_buckets_frame
	if timed:
		DebugStats.bucket_begin(&"hit_collect")   # R285 P0：命µs（收集段查询+窄相）
	var er := effective_radius()
	var swept := GameLoop.sim30_effective()
	var query_r := er
	if swept:
		query_r += (global_position - _swept_prev).length() * 0.5
	var reach := er
	var cands := enemy_grid.query_circle_snap(global_position, query_r)
	for target in cands:
		if not _live:
			break                           # 序守卫（与 _check_collision 同款——收集段内
			                                # 自身被回收即弃余候选）
		if swept:
			if _in_reach_swept(target, reach):
				GameLoop.append_hit_pair(self, target)
		elif _in_reach(target, reach):
			GameLoop.append_hit_pair(self, target)
	if timed:
		DebugStats.bucket_end(&"hit_collect")


func _check_collision(p_skip_query: bool = false) -> void:
	# p_skip_query（R235 4b）：调用方（_tick_fast_player 预检）已按同口径 query_r 复制好
	# _candidates 时跳过重查，直走窄相+提交链——候选超集与窄相裁定口径与全查逐位一致。
	if team == 1:
		_check_player_hit()
		return
	if _flight_axe:
		return                              # R243 掷斧幽灵飞行（§2.3）：途中无接触伤——敌判定整体跳过
		                                    # （敌弹不分流：本守卫仅 team==0 路径可达，零波及）
	if enemy_grid == null:
		return
	# 候选复制（query_circle_snap 返回内部复用缓冲；提交链路内的 AOE/重索敌查询会复用同一缓冲）
	# + 窄相判定（§4.4 候选语义：网格保守半径超集 → 实际 hitbox_r 收窄）。
	# R188 档0：复制进成员缓冲（原每弹每帧新建数组；复制语义承重墙保留不动）
	# R231 刀A：粗判切 query_circle_snap（rebuild 期位置快照——④ 相位活敌 live 位≡
	# 快照位；死亡-回池敌位置不变+dead 短路兜底，分析 AC-1/AC-2）。窄相 _in_reach
	# 保持 live 读不动：候选粗判允许超集，最终裁定口径不变。
	# R231 刀C③：effective_radius() 就地缓存——本函数内两次调用（查询半径+窄相 reach
	# 基数）之间 hitbox_radius/size_mult 无写者（纯读 × 纯读），缓存=逐位同值。
	var er := effective_radius()
	var swept := GameLoop.sim30_effective()
	if not p_skip_query:
		# R233 T5（决策4）：30Hz 态粗判半径膨胀 +|v|·dt/2（最坏 979.2 档 +16.3px，查询半径
		# 6→22.3px——候选超集口径不变，多扫一环格成本≈0）；谓词关=query_r 恒 er（60Hz 逐位
		# 现网）。粗判 reach=query_r+max_entity_radius(64) vs 弦半 16.4+tr≤22 —— swept 全部
		# 可能命中仍在候选集内（超集论证的粗判半场）。
		# （实况注：粗判现走 R231 刀A 的 query_circle_snap 快照位查询——设计稿写 query_circle
		# 系 R231 前旧称，膨胀挂在实际查询口上。）
		var query_r := er
		if swept:
			query_r += (global_position - _swept_prev).length() * 0.5
		_candidates.clear()
		_candidates.append_array(enemy_grid.query_circle_snap(global_position, query_r))
	var reach := er
	for target in _candidates:
		if not _live:
			break
		# R233 T5（决策4）：30Hz 态窄相线段化——本步步前位→步末位弦 vs 目标圆（线段含
		# 两端点 ⇒ 现网点命中 ⊆ 线段命中，只增候选不漏击）；60Hz 态保持现网点判定逐位。
		# Homing 溅射 _blast_secondaries 的 _in_reach(cand, blast_radius) 仍走点判定
		# （爆心径向 AOE 无 swept 语义——决策4 范围仅弹-敌接触检测）。
		if swept:
			if _in_reach_swept(target, reach):
				_submit_hit(target)
		elif _in_reach(target, reach):
			_submit_hit(target)


func _in_reach(p_target: Node2D, p_radius: float) -> bool:
	# 窄相判定：圆距 ≤ 自身查询半径 + 目标实际 hitbox_r（Enemy.hitbox_r 快照）。
	# R188 档0：平方距离比较（去 sqrt）；R210 反射 get→类型化直取（真机 181 弹 ×
	# 候选数每步的 Variant 字符串查表在 ARM 上代价放大——桌面 µs 级不可见）
	if p_target == null:
		return false
	var tr := 0.0
	if p_target is Enemy:
		tr = (p_target as Enemy).hitbox_r
	else:
		var r: Variant = p_target.get("hitbox_r")
		tr = float(r) if r != null else 0.0
	var reach := p_radius + tr
	return global_position.distance_squared_to(p_target.global_position) <= reach * reach


func _in_reach_swept(p_target: Node2D, p_radius: float) -> bool:
	# R233 T5（决策4）：swept 窄相——本步位移线段（_swept_prev→global_position，步前
	# 暂存口径见成员注）到目标圆心距离 ≤ 查询半径+目标实际 hitbox_r。线段含两端点 ⇒
	# 现网点命中 ⊆ 线段命中（超集，只增候选不漏击）；零位移（静止弹/零弦）退化为点距
	# =点判定同值。tr 读取口径与 _in_reach 逐位同源（Enemy 类型化直取 + else 反射桩）。
	# 注意：Homing 溅射 _blast_secondaries 共用的 _in_reach 是爆心径向 AOE，不本函数化
	# （爆炸无 swept 语义——决策4 范围仅弹-敌接触检测）。
	if p_target == null:
		return false
	var tr := 0.0
	if p_target is Enemy:
		tr = (p_target as Enemy).hitbox_r
	else:
		var r: Variant = p_target.get("hitbox_r")
		tr = float(r) if r != null else 0.0
	var reach := p_radius + tr
	return _seg_point_dist_sq(_swept_prev, global_position,
		p_target.global_position) <= reach * reach


static func _seg_point_dist_sq(p_a: Vector2, p_b: Vector2, p_p: Vector2) -> float:
	# 点到线段距离平方（一次投影 + 平方比较，无 sqrt——_in_reach R188 平方口径同纪律；
	# Vector2 float32 下不做边界贴合断言的精度依赖）。零长线段（a==b）退化为点距。
	var ab := p_b - p_a
	var len_sq := ab.length_squared()
	if len_sq <= 0.0:
		return p_p.distance_squared_to(p_a)
	var t := clampf((p_p - p_a).dot(ab) / len_sq, 0.0, 1.0)
	return p_p.distance_squared_to(p_a + ab * t)


func _check_player_hit() -> void:
	# 敌弹 × 玩家：单目标距离判定（玩家命中盒为 Area2D 低频通道 Q-15 例外；
	# 敌弹量少，直接距离判定避免物理回调开销）。伤害走简化路径（Q-16：不入 M-12）。
	var player := _find_player()
	if player == null:
		return
	var pr := 0.0
	if player is Player:                       # R210 类型化直取（反射 get 同口径剔除）
		pr = (player as Player).hitbox_radius
	else:
		var pr_v: Variant = player.get("hitbox_radius")
		pr = float(pr_v) if pr_v != null else 0.0
	var reach := effective_radius() + pr
	if global_position.distance_to(player.global_position) > reach:
		return
	# R220 刀9（吸收刀4 敌弹点 :346）：Player 类型化直调 take_contact_damage；else 保留
	# has_method 桩路径（r210 双轨）。慢路径仍读 panel_snapshot 字典——中途改写面板的
	# 通道（秘纹守卫反射 ×0.6 直改字典、测试夹具直设）不受 spawn 期扁平化影响。
	if player is Player:
		(player as Player).take_contact_damage(float(panel_snapshot.get("base_atk", 0.0)))
	elif player.has_method(&"take_contact_damage"):
		player.call(&"take_contact_damage", float(panel_snapshot.get("base_atk", 0.0)))
	_recycle(GameConst.RecycleReason.PIERCE_DEPLETED)


func _submit_hit(p_target: Node2D) -> void:
	# §4.4 时序：① ctx = 面板快照展开 + 运行态 → ② 词条乘区预聚合（条件自评）→
	# ③ ON_HIT 派发（挂载序）→ ④ pipeline.resolve → ⑤ 附着/穿透/回收后处理
	if p_target == null:
		return
	var t_uid: Variant = (p_target as Enemy).uid if p_target is Enemy else p_target.get("uid")
	if t_uid == null:
		return
	if hits_this_frame.has(t_uid):
		return                                # E-03 帧聚合：一帧一目标一条
	hits_this_frame[t_uid] = true
	# R196 FIX-2 生命周期级逐目标去重（有意契约变更）：帧去重后、死亡短路前——
	# 已命中目标整弹生命周期内不再结算（直接 return：不耗穿透预算/不落伤/不计
	# _pierce_hits/不派发词条）。原帧级去重挡不住接触带（弹 6+敌 14≈20px、120Hz 下
	# ≈8 tick）内逐 tick 重击同一存活敌人——pierce=2 时 E1 承伤 28=2×14、同线 E2 零伤；
	# 现语义 pierce=N 恰贯穿 N 名不同敌人（AFF_PIERCE 卡面「可再多贯穿 1 名敌人」达成）。
	# 回旋刃豁免（不查不录）：R78 同敌接触内冷 0.4s 一跳 + G11 命中不耗穿透/去回双程
	# 皆贯穿，依赖同敌多次结算（verify_feedback G11 锚 hp 逐触递减）。
	# bounce 后不清表（默认拍板：回场弹对回程同敌零重击）。
	# 清零口：spawn（池取出）+ _reset_state（归还）原地 clear——R188 红线禁每帧分配。
	if not _boomerang:
		if _hit_uids.has(t_uid):
			return
		_hit_uids[t_uid] = true
	# E-06 死亡短路（R220 刀4 类型化：Enemy 分支直读字段；else 保留 Variant 路径供
	# 测试桩——R210 双轨先例）
	if p_target is Enemy:
		if (p_target as Enemy).dead:
			return
	elif bool(p_target.get("dead")):
		return
	# R72 反弹盾（秘纹守卫）：就绪期来弹折返攻玩家——本次命中取消（不落血/不耗穿透；
	# 反弹后的弹 team=1，后续走敌弹通道，不再与发射者友军判定）
	# R220 刀4：Enemy 分支直调（真机命中链 has_method(String) 反射在 ARM 代价放大）；
	# else 桩路径保留
	if p_target is Enemy:
		if (p_target as Enemy).try_reflect_projectile(self):
			return
	elif p_target.has_method(&"try_reflect_projectile") 			and bool(p_target.call(&"try_reflect_projectile", self)):
		return
	# R78 回旋刃接触节拍：同敌内冷（0.4s）内不结算——多次接触按间隔成伤；
	# 命中轻弹开（碰到回弹的物理读感；返航归位不受影响）
	if _boomerang:
		if float(_boom_icd.get(t_uid, 0.0)) > 0.0:
			return
		_boom_icd[t_uid] = BOOM_HIT_ICD
		var away: Vector2 = global_position - p_target.global_position
		if away.length_squared() > 0.001 and velocity.length() > 1.0:
			velocity = velocity.normalized().lerp(away.normalized(), 0.30) 				* velocity.length()
	# 二cu 灵剑命中剑痕（用户「目标身上会有对应的剑痕（斜着的剑痕出现 小范围性的）」）：
	# 飞剑命中即向表现层发剑痕事件（角度=来速方向，FX 侧 +45° 斜置）；纯表现——
	# 零判定/数值参与，ElementalFxLayer 池化消费（质量分档低档关）
	if _flight_sword:
		EventBus.emit_sword_mark(p_target.global_position, velocity.angle())
	_pierce_hits += 1                        # 命中序数（HIT_AFTER_PIERCE 条件）
	var ctx := _build_damage_ctx(p_target)
	# 包 3 收口（§4.4 ②）：TraitStack 真件乘区预聚合 + 目标易伤乘区注入（A2 §1.8）
	var tctx := _prepare_hit_traits(ctx, p_target)
	var result: DamageResult = null
	if damage_pipeline != null and damage_pipeline.has_method(&"resolve"):
		result = damage_pipeline.call(&"resolve", ctx)
	else:
		result = DamageResult.new()          # 无管线防御：零伤害直通（集成期注入后不可达）
		result.final_value = 0.0
		result.killed = false
	_on_settled(p_target, result, tctx)


func _prepare_hit_traits(p_ctx: DamageContext, p_target: Node2D) -> TraitContext:
	# 包 3 收口（§4.4 ②③）：乘区预聚合（collect_mult_pools 条件自评注入 mult_pools）
	# + 易伤乘区（vuln 池）+ ON_HIT 派发（TraitStack 真件通道 / 直挂数组兼容通道）
	# + 集成包 B.2：遗物命中时点独立乘区（经 weapon_ref 的 RelicHandler 通道）
	var tctx := _build_trait_ctx(GameConst.TraitEvent.ON_HIT,
		{"target": p_target, "damage_ctx": p_ctx})
	inject_hit_relic_pools(p_ctx, p_target, weapon_ref)
	if trait_stack is TraitStack:
		for pool in (trait_stack as TraitStack).collect_mult_pools(tctx):
			p_ctx.mult_pools.append(pool)
		_inject_vuln_pool(p_ctx, p_target)
		(trait_stack as TraitStack).dispatch(GameConst.TraitEvent.ON_HIT, tctx)
	elif not _traits_cache.is_empty():
		for mounted in _traits_cache:
			if mounted is Object and (mounted as Object).has_method(&"on_event"):
				(mounted as Object).call(&"on_event", GameConst.TraitEvent.ON_HIT, tctx)
	# R187 §2.1.10「全武器共享死节点修复」生产触发载体：TH_CRIT_SHARD 阈值质变武器侧
	# 消费（TH_SWARM_NOVA/TH_PRISM_CHOIR 同款 weapon.get_threshold 直读先例）——运行时
	# 栈无 EF_CRIT_SHARD 载体词条时经此触发（10 武器 .tres 全量声明 TH_CRIT_SHARD，但
	# 无任何词条携带该 effect_id，此前生产路径恒不触发）；未来若有载体卡则随栈派发，
	# 本侧自动让位不双触发。
	# R220 刀3①保守闸：armed=false（栈无载体 + 武器未声明 TH_BANK_SHOT + 未声明/
	# 面板 crit<阈值的 TH_CRIT_SHARD——spawn 期算一次）整段跳过，省每命中
	# _stack_has_effect 逐词条 StringName 转换扫描。armed 超集已并入 bank-shot 声明
	#（达线置 ctx.crit_chance=1.0 的命中时点改写口——评审指出的口径漏洞）。
	if _crit_shard_armed and not _stack_has_effect(&"EF_CRIT_SHARD"):
		var shard := TraitEffect.resolve(&"EF_CRIT_SHARD")
		if shard != null:
			shard.handle(null, tctx)
	return tctx


func _stack_has_effect(p_effect_id: StringName) -> bool:
	# 运行时栈是否已携带指定 effect_id 的载体词条（防武器侧派发与栈派发双触发）。
	# R220 刀3①：仅 spawn 期闸计算与 armed 命中链放行段调用（不再逐命中白付）。
	if trait_stack is TraitStack:
		for tb in (trait_stack as TraitStack).traits:
			var td: Variant = tb.get("data")
			if td != null and StringName(str(td.get("effect_id"))) == p_effect_id:
				return true
	return false


# ── R187 激光跳伤遗物公共入口（共享组通道；激光组 laser_beam._settle_one_tick 调用） ──
static func inject_hit_relic_pools(p_ctx: DamageContext, p_target: Node2D,
		p_weapon: WeaponBase) -> void:
	# 激光束非投射物载体——此前跳伤路径接不通 inject_relic_pools（全仓唯一调用点在
	# _prepare_hit_traits），5 件命中遗物对激光全无效（「抽了没反应」）。本公共入口与
	# 投射物命中同源通道：inject_relic_pools 内部按 has_mult_pool 去重，同 ctx 多跳安全。
	# 宿主武器飞行/结算中途可能被移除——is_instance_valid 守卫在前（先判有效再赋值纪律）。
	if p_ctx != null and p_weapon != null and is_instance_valid(p_weapon):
		p_weapon.inject_relic_pools(p_ctx, p_target)


func _inject_vuln_pool(p_ctx: DamageContext, p_target: Node2D) -> void:
	# 包 3 收口：目标侧易伤乘区注入（冰冻易伤 ×1.25——vuln 池在管线步骤⑤入池，A2 §1.8）。
	# 集成包 B.7 去重：同 ctx 已含 vuln 池（如来源武器已注入）时跳过。
	# R232 刀1a：Enemy 类型分支直读 elemental 字段（原 .get("elemental") String 反射
	# ——R220 刀4 漏网第 2 处）；else 保留 Variant 路径供桩（R210 双轨先例）。
	if p_target == null or WeaponBase.has_mult_pool(p_ctx, &"vuln"):
		return
	var state: Variant = (p_target as Enemy).elemental if p_target is Enemy \
		else p_target.get("elemental")
	if state is ElementalState:
		var factor := (state as ElementalState).get_vuln_factor()
		if factor > 1.0:
			p_ctx.mult_pools.append({
				"pool_id": &"vuln",
				"source_uid": 0,
				"contrib": factor - 1.0,
				"cap_pool": factor - 1.0,
				"priority": 0,
			})


func _build_damage_ctx(p_target: Node2D) -> DamageContext:
	# DamageContext 构建（B_spec §2.2；乘区 contrib 由词条在 ON_HIT 期注入）
	# R220 刀8①：5 键读弹上扁平字段（spawn 期展开——不再逐命中 Dictionary.get）；
	# R220 刀4：get_resist 类型化直调（else 桩路径保留）。
	# R232 刀1b：CTX_REUSE 时复用弹侧 scratch（借出即全字段重置——重置清单 22 字段
	# 见 _reset_ctx_scratch；build 本体再逐字段覆写，未覆盖位 rng_stream_id/三池由
	# 重置兜住）；false=DamageContext.make() 原路径（一键回退）。
	var ctx: DamageContext
	if DamagePipeline.CTX_REUSE:
		if _ctx_scratch == null:
			_ctx_scratch = DamageContext.new()
		_reset_ctx_scratch()
		ctx = _ctx_scratch
	else:
		ctx = DamageContext.make()
	ctx.source_uid = uid
	ctx.target_uid = int(p_target.get("uid"))
	ctx.target = p_target
	ctx.kill_backlink = weakref(self)          # R223 修轮：预算顺延冲刷击杀时回填
	                                             # killed_target（死亡新星消费面）——弹侧
	                                             # ctx 构建唯一口，Homing 经 super 同链
	ctx.frame_stamp = GameConfig.frame_stamp
	ctx.base_atk = _panel_base_atk
	ctx.flat_bonus = _panel_flat_bonus
	ctx.crit_chance = _panel_crit_rate
	ctx.crit_mult = _panel_crit_mult
	if not _panel_add_entries.is_empty():
		for entry in _panel_add_entries:
			ctx.add_entries.append(entry)     # 逐项入列（类型化数组不接受整批 Array 直赋）
	ctx.element = element
	ctx.hit_flags = _hit_flags()
	if p_target is Enemy:
		ctx.target_resist = (p_target as Enemy).get_resist(element)
	elif p_target.has_method(&"get_resist"):
		ctx.target_resist = float(p_target.call(&"get_resist", element))
	ctx.bounce_count = _bounces_done
	ctx.pierce_index = _pierce_hits + 1
	ctx.generation = generation
	# is_first_hit_of_wave：波首命中位（集成包 B.4 接线——WaveDirector.wave_first_kill_done
	# 置位前为 true，SYN_FIRST_STRIKE「本波首杀前」条件真源；无来源武器引用 → false 安全）
	ctx.is_first_hit_of_wave = _wave_first_hit()
	ctx.player_hp_pct = _player_hp_pct()
	ctx.pos = global_position
	return ctx


func _reset_ctx_scratch() -> void:
	# R232 刀1b：ctx 借出即清（DamageContext 全部 22 字段逐一——漏一项=跨命中污染）：
	# 标量/引用 19 项清默认值 + 三池数组 clear（复用数组不换引用——类型化数组不收
	# Array 直赋的现网注释保留）。build 本体随后覆写其中 19 项；rng_stream_id 与
	# mult_pools/local_pools 无 build 侧写口（乘区由 ② 预聚合 append）——全靠本清零
	# 防跨命中残留。由 _build_damage_ctx 每次命中前调用（CT态 scratch 恒非空）。
	var ctx := _ctx_scratch
	ctx.source_uid = 0
	ctx.target_uid = 0
	ctx.target = null
	ctx.frame_stamp = 0
	ctx.rng_stream_id = 0
	ctx.base_atk = 0.0
	ctx.flat_bonus = 0.0
	ctx.crit_chance = 0.0
	ctx.crit_mult = 2.0
	ctx.element = GameConst.Element.KIN
	ctx.hit_flags = 0
	ctx.target_resist = 0.0
	ctx.bounce_count = 0
	ctx.pierce_index = 0
	ctx.generation = 0
	ctx.is_first_hit_of_wave = false
	ctx.player_hp_pct = 1.0
	ctx.pos = Vector2.ZERO
	ctx.kill_backlink = null
	ctx.add_entries.clear()
	ctx.mult_pools.clear()
	ctx.local_pools.clear()


func _wave_first_hit() -> bool:
	# 经来源武器查询波首命中位（weapon_ref 为空 = 无宿主通道 → false 安全，pkg2 口径不变）
	if weapon_ref != null and is_instance_valid(weapon_ref):
		return (weapon_ref as WeaponBase).is_wave_first_hit()
	return false


func _hit_flags() -> int:
	# hit_flags 位标志（词条条件自评，B_spec §2.2）
	var flags := 0
	if _bounces_done > 0:
		flags |= GameConst.HIT_IS_BOUNCE
	if _pierce_hits >= 1:
		flags |= GameConst.HIT_AFTER_PIERCE
	if generation > 0:
		flags |= GameConst.HIT_IS_SPLIT_CHILD
	return flags


func _on_settled(p_target: Node2D, p_result: DamageResult, p_tctx: TraitContext = null) -> void:
	# 结算后（§4.4 ⑤）：结果应用 → 元素附着（本弹载荷 + ELE 词条请求）→ 穿透计数 →
	# OnPierce 或回收判定；击杀证据回填（死亡新星输入）
	_apply_result_to(p_target, p_result)
	# 武器击退（R7：霰弹枪 knockback 参数——方向 = 弹道行进向；质量分级在 Enemy.knockback）
	# R220 刀4：Enemy/WeaponBase 类型化直调（else 保留 has_method 桩路径——R210 双轨）
	var has_knockback := false
	if p_target is Enemy:
		has_knockback = true
	elif p_target.has_method(&"knockback"):
		has_knockback = true
	if weapon_ref != null and is_instance_valid(weapon_ref) and has_knockback:
		var kf: float = (weapon_ref as WeaponBase).knockback_force()
		if kf > 0.0 and velocity.length() > 1.0:
			if p_target is Enemy:
				(p_target as Enemy).knockback(velocity.normalized() * kf)
			else:
				p_target.call(&"knockback", velocity.normalized() * kf)
	if p_result != null:
		killed_target = killed_target or p_result.killed
		last_hit_pos = global_position
	_apply_elemental(p_target, p_result, p_tctx)
	# G11 回旋刃：命中不耗穿透——去回双程皆贯穿（用户反馈「击中就消失还回旋什么」）；
	# 回收只由返航到手 / 寿命兜底。ON_PIERCE 词条钩子照常逐跳派发（构筑不受损）
	if not _boomerang:
		pierce_left -= 1
	if pierce_left > 0 or _boomerang:
		# R262b L4：空词条闸前置（照 ON_TICK :441-444 先例）——payload 字典只在有
		# 词条栈时构造，穿透风暴期每命中的死分配归零（_dispatch_event 内部同名闸保留）
		if _has_any_trait():
			_dispatch_event(GameConst.TraitEvent.ON_PIERCE, {"target": p_target})
	else:
		_recycle(GameConst.RecycleReason.PIERCE_DEPLETED)


func _apply_elemental(p_target: Node2D, p_result: DamageResult, p_tctx: TraitContext) -> void:
	# 包 3 收口（§4.4 ⑤）：元素附着——本弹载荷（element/attach_value，武器/词条注入）
	# + ELE 词条 attach_request（引擎侧统一提交 ElementalSystem；快照取当跳结算结果）
	# R223 修轮（评审#2）：预算顺延占位命中跳过附着——占位 final=0 会让满槽感电
	# 连锁 _shock_chain(0)（0 伤空放闪电=R199 D16 已修问题的深载条件性复发）；跳过=
	# 该跳 gauge 暂停（深载 tier≤2 限定、体感为附着节奏略缓，无空放特效）
	if p_result != null and p_result.deferred_merge:
		return
	if elemental == null or p_target == null:
		return
	var snapshot := 0.0
	var hit_damage := 0.0
	if p_result != null:
		snapshot = p_result.panel_snapshot
		hit_damage = p_result.final_value
	else:
		snapshot = float(panel_snapshot.get("base_atk", 0.0))
	if element != GameConst.Element.KIN and attach_value > 0.0:
		elemental.apply_attach(p_target, element, attach_value,
			{"snapshot": snapshot, "hit_damage": hit_damage})
	if p_tctx != null and not p_tctx.attach_requests.is_empty():
		# R243 §6.3 全元素并发消费：attach_requests 数组非空时逐条附着——旧单槽分支跳过
		#（防双发；w3 改 trait_effect_elemental 产出数组前恒空 = 走旧单槽，零行为变化）
		for request in p_tctx.attach_requests:
			elemental.apply_attach(p_target, int(request.get("element", GameConst.Element.KIN)),
				float(request.get("value", 0.0)), {
					"snapshot": snapshot,
					"hit_damage": hit_damage,
					"overrides": request.get("overrides", {}),
				})
	elif p_tctx != null and not p_tctx.attach_request.is_empty():
		var request: Dictionary = p_tctx.attach_request
		elemental.apply_attach(p_target, int(request.get("element", GameConst.Element.KIN)),
			float(request.get("value", 0.0)), {
				"snapshot": snapshot,
				"hit_damage": hit_damage,
				"overrides": request.get("overrides", {}),
			})


func _apply_result_to(p_target: Node2D, p_result: DamageResult) -> void:
	# Enemy.take_result（扣血/易伤标记/死亡广播——pipeline 步骤 9 之后由本侧应用）。
	# 落血口径双轨（同 weapon_base.settle_aoe 审查修复）：真件 DamagePipeline 九步 9b
	# 在 resolve 内部已 take_result 落血（_apply_to_target——killed 判定/死亡广播唯一
	# 执行点），本侧再落血即直击伤害 ×2（主路径 _submit_hit / Homing 集束次级）；透传
	# 桩 resolve 只算不落血，落血职责在调用方（pkg2/pkg3 桩用例锁定口径，保持不变）。
	# 管线为 null（无管线防御零伤直通）非真件，仍走本侧落血（行为不变）。
	if p_target == null or damage_pipeline is DamagePipeline:
		return
	if p_target.has_method(&"take_result"):
		p_target.call(&"take_result", p_result)


# ── 六大生命周期事件唯一派发点 ──────────────────────────────────
func _has_any_trait() -> bool:
	# R188 档0：空词条判定（栈空/无宿主 且 直挂数组空 → 派发零分配直通）。
	# _traits_cache 在 spawn 期已抓取 trait_stack.traits 引用——非空即有词条；
	# 直挂数组通道（"traits" 便捷键）也落入 _traits_cache，此处双查兜底。
	if not _traits_cache.is_empty():
		return true
	return trait_stack is TraitStack and not (trait_stack as TraitStack).traits.is_empty()


func _dispatch_event(p_event: int, p_extra: Dictionary = {}) -> TraitContext:
	# ★ M-09 契约：派发顺序 = 挂载顺序（确定性）；无词条零开销直通（R188 档0 兑现：
	# 空词条 → 不构造 payload 字典与 TraitContext，返回 null）。
	# 返回值消费点审计（R188）：_recycle(ON_EXPIRE) 消费 tctx.split_request 且判空在前
	# （tctx != null 先于 is_empty）——null 安全；spawn/tick/_apply_bounce/_on_settled
	# 忽略返回值；ON_HIT 结算链走 _build_trait_ctx 直构不经本捷径。
	# 包 3 收口：TraitStack 真件派发通道（链式深度 3 熔断 + 同事件重入保护，M-10）；
	# 直挂数组通道（spawn 参数字典 "traits" 便捷键）保留为测试/过渡期兼容路径。
	if not _has_any_trait():
		return null
	# R210 无挂钩事件直通：真机 vc17 弹段 9-12ms 主犯——词条弹每帧 ON_TICK 分发付出
	# payload 字典 + TraitContext 分配 + 全词条虚调用，而数据侧 ON_TICK 挂钩为零
	#（on_event 静态闸门全灭=跳过分发零行为差异；can_trigger 动态闸不计入=保守超集）
	if trait_stack is TraitStack and not (trait_stack as TraitStack).has_event_hook(p_event):
		return null
	var ctx := _build_trait_ctx(p_event, p_extra)
	if trait_stack is TraitStack:
		(trait_stack as TraitStack).dispatch(p_event, ctx)
	elif not _traits_cache.is_empty():
		for mounted in _traits_cache:
			if mounted is Object and (mounted as Object).has_method(&"on_event"):
				(mounted as Object).call(&"on_event", p_event, ctx)
	return ctx


func _build_trait_ctx(p_event: int, p_extra: Dictionary = {}) -> TraitContext:
	# 包 3 收口：单点改构 TraitContext 实例（原 Dictionary 载荷——架构 §2.9.1 真件替换）
	var ctx := TraitContext.new()
	ctx.event = p_event
	ctx.projectile = self
	ctx.beam = null
	ctx.melee = null
	ctx.weapon = null
	ctx.target = p_extra.get("target")
	ctx.damage_ctx = p_extra.get("damage_ctx")
	ctx.game_delta = float(p_extra.get("game_delta", 0.0))
	# R243 §6.3：宿主元素全集接线（_submit_hit 链 ON_HIT / 全生命周期事件同一构造点）——
	# ELE 词条 _emit_attach_request 守卫输入（池外元素零附着）；空池 = 无限制旧语义
	ctx.host_elements = attach_elements.duplicate()
	# 来源武器接线（TH_SIZE_NOVA/MEC 系效果依赖 ctx.weapon 的 get_threshold/settle_aoe）；
	# 武器可能中途被移除——飞行中弹体守卫，失效引用按无武器处理
	ctx.weapon = weapon_ref if is_instance_valid(weapon_ref) else null
	return ctx


# ── 分裂（三重闸门 §六.3） ──────────────────────────────────────
func request_split(p_count: int, p_spread_deg: float, p_inherit_ratio: float,
		p_echo: bool = false) -> void:
	# 代数 ≤3 + 单次子数 ≤8 + 全场软上限；F-13：子代仅继承面板快照比例（不继承乘区/元素附着）
	# 包 3 收口：p_echo（TH_FRACTAL_ECHO，分裂深度 ≥3）——词条定义继承扩展至乘区词条
	if pool == null:
		return
	var max_gen: int = 3 if GameConfig.balance == null else GameConfig.balance.split_max_generation
	if generation + 1 > max_gen:
		DebugStats.count(&"split_rejected_generation")
		return
	var max_children: int = 8 if GameConfig.balance == null else GameConfig.balance.split_max_children
	if p_count > max_children:
		DebugStats.count(&"split_rejected_children")
		return
	if pool.total_active() >= pool.soft_limit:
		DebugStats.count(&"split_rejected_soft_limit")
		return
	for i in range(p_count):
		var child := pool.acquire() as ProjectileBase
		if child == null:
			return                            # 池满：后续子代丢弃（AC-14.4）
		child.damage_pipeline = damage_pipeline
		child.enemy_grid = enemy_grid
		child.pool = pool
		child.elemental = elemental
		child.position = position
		var angle_offset := 0.0
		if p_count > 1:
			angle_offset = deg_to_rad(p_spread_deg) * (float(i) / float(p_count - 1) - 0.5) * 2.0
		var child_panel: Dictionary = panel_snapshot.duplicate(true)
		child_panel["base_atk"] = float(child_panel.get("base_atk", 0.0)) * p_inherit_ratio
		var params := {
			"velocity": velocity.rotated(angle_offset),
			# R241 ①：子代寿命地板 1.2s——EXPIRE 期分裂（母弹寿命/出屏消亡，含回旋刃
			# 近墙衰减消亡路径）的 lifetime_left 已 ≤0，原样继承=子代首帧即死（分裂静默
			# 白给）；地板给子代独立短命（直弹 ~射程/速×系数量级，回旋子代由 range 接管）。
			"lifetime": maxf(lifetime_left, 1.2),
			"pierce": 1,
			"bounces": 0,
			"hitbox_radius": hitbox_radius * p_inherit_ratio,   # 二ct：子代尺寸=母体当前 ×70% 动态（视觉经 effective_radius 自动跟随）
			"element": element,
			"attach_value": 0.0,             # F-13：不继承元素附着
			"generation": generation + 1,
			"weapon_uid": weapon_uid,
			"weapon_ref": weapon_ref,            # 分裂子代继承来源武器（效果引擎侧通道）
			"panel_snapshot": child_panel,
			"team": team,
		}
		# R241 ①：回旋母弹的子代=迷你回旋刃（原 plain 珠视觉+直线飞行=「大刃裂成小圆点」
		# 读感破碎；改继承回旋形态：短甩程 0.55×+自回手——接刃碎裂再撒一把小刃的读感）
		if _boomerang:
			params["boomerang"] = true
			params["range"] = maxf(_boom_range * 0.55, 120.0)
		# R243 通道 A 子代形态继承（§2.2/§2.3——与 R241 回旋分支并列）：
		# · 飞剑（W11）：子代继承 flight_sword（迷你飞剑——防「大剑裂成圆点」同款读感破碎）
		# · 掷斧（W12）：子斧继承幽灵飞行（途中无接触伤）；target_point = 现场位 + 子代出射
		#   方向 × AXE_CHILD_THROW（散射角随 velocity.rotated(angle_offset) 保真——出射即四散）；
		#   shock_scale = inherit_ratio（震荡半径/伤害双缩，w2 on_axe_land 消费）；★generation=3
		#   链式封堵：子斧落地回收的 ON_EXPIRE 再写 split_request 时 3+1>3 走既有代数闸拒绝
		#   （split_rejected_generation——防 inheritable FRACTAL 连锁 14/39 枚子震荡）
		var child_vel: Vector2 = params["velocity"]
		if _flight_sword:
			params["flight_sword"] = true
		if _flight_axe:
			var throw_dir := child_vel.normalized() if child_vel.length_squared() > 0.0001 \
				else velocity.normalized()
			params["flight_axe"] = true
			params["target_point"] = position + throw_dir * AXE_CHILD_THROW
			params["shock_scale"] = p_inherit_ratio
			params["generation"] = 3
		# F-13：inheritable 词条定义复制（TraitStack.copy_for_split——包 3 真件；
		# 定义引用复制非深拷贝，子代条件自评、独立过护栏）
		if trait_stack is TraitStack:
			params["trait_stack"] = (trait_stack as TraitStack).copy_for_split(
				generation + 1, p_echo)
		child.spawn(params)


# ── 反弹（反射角镜像） ──────────────────────────────────────────
func _apply_bounce(p_normal: Vector2) -> void:
	# 边界反弹：反射角镜像 v' = v − 2(v·n)n + bounces_left-- + ON_BOUNCE 派发
	velocity = velocity - 2.0 * velocity.dot(p_normal) * p_normal
	var r := effective_radius()
	if p_normal.x > 0.0:
		global_position.x = r
	elif p_normal.x < 0.0:
		global_position.x = _screen.x - r
	if p_normal.y > 0.0:
		global_position.y = r
	elif p_normal.y < 0.0:
		global_position.y = _screen.y - r
	bounces_left -= 1
	_bounces_done += 1
	_vis_variant = -1                           # R188 档0：反弹达线 bank 升格重判（TH_BANK_SHOT）
	# R187 MEC_RICOCHET_HALL「回廊弹幕」（§2.4.4 消费口，武器侧 corridor 标记 +
	# lateral_offset 基准）：反弹后 lane offset 镜像——弹位按当前飞行垂直轴翻到镜像侧
	#（位移 = +perp×2×gap，与收束 steer 同符号约定），编队镜像保持回场（散弹变回廊弹幕）
	if _corridor and absf(_conv_gap) > 0.01 and velocity.length_squared() > 1.0:
		var perp := velocity.normalized().orthogonal()
		global_position += perp * 2.0 * _conv_gap
		_conv_gap = -_conv_gap
	_dispatch_event(GameConst.TraitEvent.ON_BOUNCE)
	if team == 0:   # R184 评审修正：只认我方弹——秘纹守卫反射（team 翻 1）的敌控弹不播「我方回弹」音
		EventBus.emit_bullet_bounced(global_position)   # 反弹音广播（节流在 SfxBank 侧 THROTTLE_MS）


func _check_edge_bounce() -> void:
	# 屏幕四边反射判定（Ballistic 反弹路径）：预算内反射；预算耗尽（曾有预算）BOUNCE_DEPLETED；
	# 从未携带预算的子弹不在此拦截（出屏后由 _check_offscreen 以 EXPIRED 回收）。
	# R231 刀C①：无预算早退——bounces_left==0 ∧ not _had_bounces → 首行直返。no-op 证据
	# （R220 敌弹 _tick_fast 头注同款论证）：无预算弹四边 normal 计算后必无分支命中——
	# normal≠ZERO 时 bounces_left>0 为假 ∧ _had_bounces 为假 → 反射/回收两分支均不可达，
	# 函数返回后全局态零变化（不反射/不改速/不回收）；早退仅省 4 次 normal 计算+2 次比较。
	# 双调幂等点（基类 tick 与 Ballistic._move 尾——同帧两调）同口径同证：早退后两调皆零体。
	if bounces_left == 0 and not _had_bounces:
		return
	var r := effective_radius()
	var pos := global_position
	var normal := Vector2.ZERO
	if pos.x <= r:
		normal = Vector2(1, 0)
	elif pos.x >= _screen.x - r:
		normal = Vector2(-1, 0)
	elif pos.y <= r:
		normal = Vector2(0, 1)
	elif pos.y >= _screen.y - r:
		normal = Vector2(0, -1)
	if normal == Vector2.ZERO:
		return
	if velocity.dot(normal) > 0.0:
		return                                  # 已在离面方向（R15 基类统一后幂等——防边界处同帧双弹）
	if bounces_left > 0:
		_apply_bounce(normal)
	elif _had_bounces:
		_recycle(GameConst.RecycleReason.BOUNCE_DEPLETED)


# ── R268 性能刀 P3：拖尾重绘半频门 + 刺击拖尾长度档位 ────────────────
var _trail_redraw_acc: float = 0.0             # R268 P3①：半频门 dt 累计（秒；归还被清零防池复用串值）


func _trail_redraw_due(p_game_delta: float) -> bool:
	# R268 性能刀 P3①：mobile 拖尾重绘半频门——dt 化计时门（累计 ≥1/30s 才置脏重绘，
	# 非帧奇偶——掉帧不减半语义，R206 mobile 跳字隔帧 tick 同族先例）；桌面/非 mobile
	# 恒真（现状逐帧零变化）。headless 无 mobile 特征位 → trail_halffreq_override 注入。
	var halffreq := OS.has_feature("mobile")
	if trail_halffreq_override == 0:
		return true
	if trail_halffreq_override == 1:
		halffreq = true
	if not halffreq:
		return true
	_trail_redraw_acc += p_game_delta
	if _trail_redraw_acc < TRAIL_REDRAW_MIN_DT:
		return false
	_trail_redraw_acc = 0.0
	return true


func _proj_fx_quality() -> int:
	# R268 性能刀 P3②：特效质量档读口（arc_slash.gd:577 / orbit_field.gd:1025 同口径
	# 镜像——Meta 单源钳 [0,2] + mobile 降档帽 1）
	var q := clampi(int(Meta.settings("fx_quality")), 0, 2)
	if OS.has_feature("mobile"):
		q = mini(q, 1)
	return q


func _sword_trail_len() -> float:
	# R268 性能刀 P3②：刺击拖尾长度档位化——0 档（mobile tier1 深载降档）取半额，
	# 1/2 档原值（tier2/desktop 零变化）。SWORD_TRAIL_LEN_BY_FXQ 单源表。
	return float(SWORD_TRAIL_LEN_BY_FXQ[clampi(_proj_fx_quality(), 0, 2)])


func _draw() -> void:
	# R271 P4：绘µs wrap（自绘件 _draw 计时入 &"draw" 桶——只加计不改行为；
	# 原体迁 _draw_r271，早退 return 由委托面兜底不漏收口）
	DebugStats.bucket_begin(&"draw")
	_draw_r271()
	DebugStats.bucket_end(&"draw")


func _draw_r271() -> void:
	# G6 回旋刃拖尾 + R243 灵剑刺击残影（共用本节点 _draw：局部坐标，节点不随速度旋转，
	# 弧向/刺痕向即尾迹向——重绘驱动在 tick 内各自 queue_redraw）
	if not _live:
		return
	if _boomerang:
		_draw_boom_trail()
	elif _flight_sword:
		_draw_sword_stab_trail()


func _draw_boom_trail() -> void:
	# G6 回旋刃拖尾：速度反方向渐隐金弧
	var back := -velocity.normalized()
	var side := back.orthogonal() * 0.35
	var prev := Vector2.ZERO
	for i in range(1, 6):
		var k := float(i) / 5.0
		var pt := back * (28.0 * k) + side * (14.0 * k * k)   # 微弯外扫（R191 随 ×5.0 刃体等比放宽）
		draw_line(prev, pt, Color(PopPalette.GOLD.r, PopPalette.GOLD.g, PopPalette.GOLD.b,
			(1.0 - k) * 0.45), 4.0 * (1.0 - k * 0.6))
		prev = pt


func _draw_sword_stab_trail() -> void:
	# R243 灵剑刺击残影（§2.2「拖刺击残影」；§7.2 质变「金色刺击残影」）：速度反方向
	# 渐隐刺痕折线——默认 = 弹族元素表色（_plain_fill，KIN 即玩家蓝·银蓝剑读感），
	# 万剑诀质变 = 金色（G6 拖尾同款 4 段渐隐折线，零新粒子系统）。
	if velocity.length_squared() <= 1.0:
		return
	var col := PopPalette.GOLD if _host_transcended() else _plain_fill()
	var trail_len := _sword_trail_len()           # R268 性能刀 P3②：档位表单源（0 档半额）
	var back := -velocity.normalized()
	var prev := Vector2.ZERO
	for i in range(1, 5):
		var k := float(i) / 4.0
		var pt := back * (trail_len * k)
		draw_line(prev, pt, Color(col.r, col.g, col.b, (1.0 - k) * 0.5),
			3.2 * (1.0 - k * 0.5))
		prev = pt


func _check_offscreen() -> void:
	# 出界判定：屏外余量（半径 + OFFSCREEN_MARGIN）→ EXPIRED
	var m := effective_radius() + OFFSCREEN_MARGIN
	if global_position.x < -m or global_position.x > _screen.x + m \
			or global_position.y < -m or global_position.y > _screen.y + m:
		_recycle(GameConst.RecycleReason.EXPIRED)


# ── 消弹（NULLIFIED 路径入口：ArcSlash 弧内敌方弹幕清除，包 3 M-08 调用） ──
func nullify() -> void:
	_recycle(GameConst.RecycleReason.NULLIFIED)


# ── 回收五路径统一收束（E-04） ───────────────────────────────────
func _recycle(p_reason: int, p_released_by_pool: bool = false) -> void:
	# ★ 顺序契约：OnExpire 派发 → 状态清零 → 池归还。
	# p_released_by_pool=true 为 FORCED 直收路径（ProjectilePool.force_recycle_oldest
	# 直接调 release，未经本入口）——归还动作由池侧完成，此处只做派发与清零。
	# 包 3 收口：ON_EXPIRE 期 split_request 输出由引擎在此执行（三重闸门在 request_split）。
	if not _live or _in_recycle:
		return
	_in_recycle = true
	_live = false
	var timed := GameLoop.prof_buckets_frame
	if timed:
		DebugStats.bucket_begin(&"recycle")       # R285 P0：回µs（_recycle→release 链
		                                          # ——关态也累计，零行为）
	DebugStats.count(&"projectile_recycled")
	# R225（弹tick侧刀）：原因键查表（零格式化分配；越界值回退旧格式化路径保底——
	# 枚举五值内行为逐位一致）。
	if p_reason >= 0 and p_reason < _RECYCLE_REASON_KEYS.size():
		DebugStats.count(_RECYCLE_REASON_KEYS[p_reason])
	else:
		DebugStats.count(StringName("recycle_reason_%d" % p_reason))
	# R243 §5.1 前移闸守卫：翻相过的回旋弹（_boom_expire_fired=true）已在甩满/速度地板
	# 翻相点派发过 ON_EXPIRE 并消费 split——此处不再二次派发（防双发：FRACTAL+KILL_BLAST
	# 双挂同一次击杀只在甩程末端炸一次）。寿命兜底路径（翻相前 EXPIRED，flag=false）与
	# 非回旋弹（flag 恒 false）走原派发行为不变。
	if not _boom_expire_fired:
		var tctx := _dispatch_event(GameConst.TraitEvent.ON_EXPIRE)
		if tctx != null and not tctx.split_request.is_empty():
			var request: Dictionary = tctx.split_request
			request_split(int(request.get("count", 0)), float(request.get("spread_deg", 0.0)),
				float(request.get("inherit_ratio", 0.0)), bool(request.get("echo", false)))
	_reset_state()
	if not p_released_by_pool and pool != null:
		pool.release(self)                    # 池再调 _reset_state（幂等清零）
	if timed:
		DebugStats.bucket_end(&"recycle")
	_in_recycle = false


func _reset_state() -> void:
	# 归还清零契约（E-04/E-05：速度/计数/词条/帧聚合/计时）。
	# FORCED 直收收束：池侧直接 release（未经 _recycle）→ meta 携带原因在此补走统一收束。
	if _live and has_meta(&"_recycle_reason"):
		var reason: int = int(get_meta(&"_recycle_reason", GameConst.RecycleReason.FORCED))
		remove_meta(&"_recycle_reason")
		_recycle(reason, true)
		return
	# R220 刀5 归还口（B3 侧接线，契约 §6.1）：TraitStack 池借出的运行栈随弹回收归池——
	# null + is_instance_valid + has_method 三重守卫（has_method 仅回收路径每弹一次，
	# 不进每命中热路径；C 包未落地/池化关闭时 release_to_pool 不存在或 no-op，零炸）。
	if trait_stack != null and is_instance_valid(trait_stack) \
			and trait_stack.has_method(&"release_to_pool"):
		(trait_stack as TraitStack).release_to_pool()
	velocity = Vector2.ZERO
	lifetime_left = 0.0
	pierce_left = 0
	bounces_left = 0
	_had_bounces = false
	_bounces_done = 0
	_boomerang = false                            # G4 回旋态随归还清零
	_boom_phase = 0
	_boom_speed_init = 0.0
	_boom_return_speed = 0.0
	_boom_expire_fired = false                   # R243 §5.1：前移闸旗标随归还清零（池复用防串弹）
	_boom_icd.clear()                            # R78 接触内冷表清零
	_conv_gap = 0.0                              # R187 收束 steer 通道归还清零
	_conv_gap0 = 0.0
	_conv_authored = false
	_corridor = false
	_conv_dist = 0.0
	_conv_done = 0.0
	_pierce_hits = 0
	generation = 0
	hitbox_radius = 6.0
	element = GameConst.Element.KIN
	attach_value = 0.0
	size_mult = 1.0
	# R243 形态键归还清零（池复用防串弹；spawn 期重读）
	_flight_sword = false
	_flight_axe = false
	_target_point = Vector2.ZERO
	_shock_scale = 1.0
	attach_elements.clear()
	weapon_uid = 0
	weapon_ref = null                           # 池复用防陈旧引用（武器可能已销毁）
	team = 0
	panel_snapshot = {}
	# R220 刀8①/刀3①/刀9：扁平面板字段 + armed 闸 + 快路径缓存随归还清零（池复用防串弹）
	_panel_base_atk = 0.0
	_panel_flat_bonus = 0.0
	_panel_crit_rate = 0.0
	_panel_crit_mult = 2.0
	_panel_add_entries = []
	_crit_shard_armed = false
	_fast_path = false
	_fast_radius = 0.0
	_pfast = false                               # R231 刀B：玩家弹快路径缓存随归还清零（池复用防串弹；spawn 期重算）
	_trail_redraw_acc = 0.0                      # R268 性能刀 P3①：半频门累计随归还清零（池复用防串值）
	_vis_invariant = false                       # R231 刀C②：视觉恒定旗标随归还清零（池复用防串弹；spawn 期重算）
	_tick_dispatch_armed = false                # R225：ON_TICK armed 快照随归还清零（池复用防串弹；spawn 期重算）
	_swept_prev = Vector2.ZERO                   # R233 T5：swept 步前暂存位随归还清零（池复用防串弹；spawn 期重置）
	trait_stack = null
	_traits_cache = []
	# R232 刀1b：ctx 复用件归还侧引用松绑（池复用防陈旧 target/backlink 挂靠——
	# 下次借出 _reset_ctx_scratch 全字段重置，此处只提前断引用不重建对象）
	if _ctx_scratch != null:
		_ctx_scratch.target = null
		_ctx_scratch.kill_backlink = null
	killed_target = false                     # 包 3 收口：击杀证据清零
	last_hit_pos = Vector2.ZERO
	hits_this_frame.clear()
	_hit_uids.clear()                            # R196 FIX-2：生命周期命中表随归还清零（池复用防串弹）
	_reset_form_state()
	is_clean = true
	_vis_variant = -1                           # R188 档0：缓存失效（池复用清零口径）
	_sync_visual()


# ── 支撑 ──────────────────────────────────────────────────────────
func _sync_visual() -> void:
	# 方向 C 渲染同步：半径等比缩放 + 阵营贴图（我方=蓝亮圆珠白高光 / 敌方=珊瑚圆珠白高光，
	# 描边+高光烘焙——亮底敌我辨识核心）。元素差异着色（2026-08-31 用户反馈「火焰没啥特效」：
	# 火弹=橙 / 冰弹=淡冰蓝 / 电弹=葡萄紫——抽到元素卡后弹幕颜色即时反馈构筑）。
	# R188 档0：脏标记 + 阈值缓存——贴图变体在 spawn 期解析一次（反弹达线 bank 升格会失效
	# 重判），量化缩放（1/32 级，肉眼不可辨）变化才重设贴图/缩放；朝向跟踪变体（曳光/导弹）
	# 缓存命中时仅刷新 rotation。视觉口径与直排版逐位一致。
	# R231 刀C②：视觉恒定旗标早退——_vis_invariant 弹（半径/变体生命周期不变+无朝向刷新
	# 面，判据见 spawn 尾部赋值处）整函数逐位 no-op：量化比较 scale_q 恒等、变体失效位
	# _vis_variant 恒 ≥0、elif 朝向刷新分支结构性不可达（rot_tracked 恒假）。变体未解析
	# （_vis_variant<0）不早退——spawn 期首帧解析照走。
	if _sprite == null:
		return
	if _vis_invariant and _vis_variant >= 0:
		return
	var scale_f := effective_radius() / (float(TEX_SIZE) * 0.5)
	var scale_q := floorf(scale_f * 32.0)
	if _vis_variant < 0 or scale_q != _vis_scale_q:
		_vis_variant = _resolve_visual_variant()
		_vis_scale_q = scale_q
		_vis_rot_tracked = _vis_variant == _VIS_TRACER \
			or _vis_variant == _VIS_MISSILE_W6 or _vis_variant == _VIS_MISSILE_W7 \
			or _vis_variant == _VIS_SWORD or _vis_variant == _VIS_AXE
		_apply_visual_variant(_vis_variant, scale_f)
	elif _vis_rot_tracked:
		_apply_visual_rotation()


func _resolve_visual_variant() -> int:
	# 贴图变体纯判定（分支顺序与 R188 前直排版一致；apply 侧据此取贴图/缩放/朝向）
	if team == 1:
		return _VIS_ENEMY
	# R243 法器形态键优先（§2.2/§2.3：飞剑/掷斧弹体各有贴图——缺此分支曾全落
	# _VIS_PLAIN 圆珠，「大剑裂成圆点」读感破碎正是本分支要根治的）
	if _flight_sword:
		return _VIS_SWORD
	if _flight_axe:
		return _VIS_AXE
	if _boomerang:
		return _VIS_BOOM
	var wid := &""
	if weapon_ref != null and is_instance_valid(weapon_ref) and weapon_ref.data != null:
		wid = weapon_ref.data.id
	if wid == &"W6_micro_missile":
		return _VIS_MISSILE_W6
	if wid == &"W7_cluster_rocket":
		return _VIS_MISSILE_W7
	if wid == &"W2_gatling":
		return _VIS_TRACER
	# 镜面判读走 Variant 真值：is_mirror_image 仅 BallisticWeapon 声明（ballistic_weapon.gd:46），
	# Homing/其余宿主 get() 缺属性即 null——bool(Variant) 入参 null 抛
	# 「Nonexistent 'bool' constructor」运行期错，此处不得包 bool()
	if weapon_ref != null and is_instance_valid(weapon_ref) \
			and weapon_ref.get("is_mirror_image"):
		return _VIS_MIRROR
	# R187 W1 黄金弹（TH_BANK_SHOT 阈值驱动通用视觉）：宿主声明该质变且本弹
	# 累计反弹达线 → 金染升格（必暴/弹片结算归 W1 组 EF_BANK 处理器）
	if weapon_ref != null and is_instance_valid(weapon_ref):
		var bank_th: Dictionary = weapon_ref.get_threshold(&"TH_BANK_SHOT")
		if not bank_th.is_empty() \
				and float(_bounces_done) >= float(bank_th.get("threshold", 12.0)):
			return _VIS_GOLD
	if element == GameConst.Element.LTG:
		return _VIS_LTG_STAR
	return _VIS_PLAIN


func _plain_fill() -> Color:
	# 元素差异着色（火=表橙 / 冰=表冰蓝 / 雷=表电紫 / 水/风/岩/草=表色 / 其余=玩家蓝）
	# ——命中盒无关，纯表现；R192 取色单源 PopPalette.ELEMENT_COLORS（星形电花路径
	# :901 派生自动跟随）
	match element:
		GameConst.Element.FIR:
			return PopPalette.ELEMENT_COLORS[GameConst.Element.FIR]
		GameConst.Element.ICE:
			return PopPalette.ELEMENT_COLORS[GameConst.Element.ICE]
		GameConst.Element.LTG:
			return PopPalette.ELEMENT_COLORS[GameConst.Element.LTG]
		GameConst.Element.HYD, GameConst.Element.ANE, GameConst.Element.GEO, \
		GameConst.Element.DEN:
			return PopPalette.ELEMENT_COLORS[element]
		_:
			return PopPalette.PLAYER


func _apply_visual_variant(p_variant: int, p_scale_f: float) -> void:
	# 变体落地（贴图/缩放/朝向一次设齐；判定顺序=R188 前直排版逐支对应）
	match p_variant:
		_VIS_ENEMY:
			_sprite.texture = TextureFactory.bead(PopPalette.ENEMY, TEX_SIZE)
			_sprite.rotation = 0.0
			_sprite.scale = Vector2(p_scale_f, p_scale_f)
		_VIS_BOOM:
			# G4 回旋刃：金色新月刃 ×5.0 表现层放大（命中盒不变，BOOM_VIS_MULT），自旋见 tick
			# R241 ②：元素附魔刃体基色（R208 加特林曳光同口径——KIN 保持金色原观感）
			_sprite.texture = TextureFactory.boomerang_tex(
				_plain_fill() if element != GameConst.Element.KIN else PopPalette.GOLD)
			_sprite.rotation = 0.0
			_sprite.scale = Vector2(p_scale_f * BOOM_VIS_MULT, p_scale_f * BOOM_VIS_MULT)
		_VIS_MISSILE_W6, _VIS_MISSILE_W7:
			# 簇2 c2-①（R211 收口报告 :128 遗留 #3 收口）：元素附魔弹体按 _plain_fill
			# 表色（R208 曳光同口径，缓存键带色）；KIN 走原浅灰蓝字面保原观感
			#（_plain_fill 对 KIN 返 PLAYER≠原弹体灰蓝，不能直接二参）。
			_sprite.texture = TextureFactory.missile_tex(
				_plain_fill() if element != GameConst.Element.KIN else Color(0.78, 0.84, 0.95))
			# R26/R35 弹体放大：W7 集束主火箭 ×4.6 / W6 微导 ×3.2（命中盒不变）
			var missile_mult := 4.6 if p_variant == _VIS_MISSILE_W7 else 3.2
			_sprite.scale = Vector2(p_scale_f * missile_mult, p_scale_f * missile_mult)
			_apply_visual_rotation()
		_VIS_TRACER:
			# 加特林曳光条（R72 口径 Y4.0）；R208（用户反馈「加特林选了元素没变对应色」）：
			# 弹体基色按元素表色生成（火橙/冰蓝曳光；KIN 保持藏青原观感——着色口径与
			# _plain_fill 珠族同源，缓存键带色零重绘）
			var tracer_fill := _plain_fill() if element != GameConst.Element.KIN else PopPalette.INK
			_sprite.texture = TextureFactory.tracer_tex(tracer_fill)
			_sprite.scale = Vector2(p_scale_f * 7.5, p_scale_f * 4.0)
			_apply_visual_rotation()
		_VIS_MIRROR:
			# R187 镜面珠（禁金染）+ 簇2 c2-②（R211 收口报告 :130 遗留 #5 收口）：
			# 元素附魔镜面内壳随弹 element 表色——镜面内壳即持 is_mirror_image 的
			# BallisticWeapon 副本（player.copy_full），弹 element 已带棱镜栈元素，
			# 弹侧自读 _plain_fill 单源即可，无需宿主 dominant_element 跳转；
			# KIN 缺省 PLAYER 保银白原观感，_plain_fill 永不返 GOLD → 禁金染天然保持。
			_sprite.texture = TextureFactory.mirror_bead(
				_plain_fill() if element != GameConst.Element.KIN else PopPalette.PLAYER, TEX_SIZE)
			_sprite.rotation = 0.0
			_sprite.scale = Vector2(p_scale_f, p_scale_f)
		_VIS_GOLD:
			_sprite.texture = TextureFactory.gold_bead(TEX_SIZE)
			_sprite.rotation = 0.0
			_sprite.scale = Vector2(p_scale_f, p_scale_f)
		_VIS_LTG_STAR:
			# 电花四角星（白芯提亮保辨识）+ tick 自旋
			_sprite.texture = TextureFactory.star(TEX_SIZE,
				PopPalette.SHOCK.lerp(Color.WHITE, 0.25))
			_sprite.scale = Vector2(p_scale_f, p_scale_f)
		_VIS_SWORD:
			# R243 灵剑（§2.2「视觉=飞剑贴图顺速度方向、拖刺击残影」）：剑形贴图（static
			# 产图放各武器脚本——R243 纪律勿动共享 TextureFactory）+ 表现层放大（命中盒
			# 不变，R191 同口径）+ 朝向跟踪（画布朝上 -Y = angle+PI/2，导弹同式）。
			# 质变万剑诀（§7.2）= 鎏金剑体（宿主 transcended 守卫读——pre-w4/无宿主回落默认）。
			_sprite.texture = _flight_form_tex(true)
			_sprite.scale = Vector2(p_scale_f * SWORD_VIS_MULT, p_scale_f * SWORD_VIS_MULT)
			_apply_visual_rotation()
		_VIS_AXE:
			# R243 掷斧（§2.3 视觉斧体）：斧形贴图同式顺速度方向（_axe_step 逐 tick 重指
			# 落点，rot_tracked 令转向即时跟随）；质变崩山击 = 岩纹斧体。
			_sprite.texture = _flight_form_tex(false)
			_sprite.scale = Vector2(p_scale_f * AXE_VIS_MULT, p_scale_f * AXE_VIS_MULT)
			_apply_visual_rotation()
		_:
			_sprite.texture = TextureFactory.bead(_plain_fill(), TEX_SIZE)
			_sprite.rotation = 0.0
			_sprite.scale = Vector2(p_scale_f, p_scale_f)
	_place_in_bucket()


func _place_in_bucket() -> void:
	# R214 E'：弹体贴图定档后落同贴图桶（同变体/同阵营弹树序相邻 → 合批；阵营混排
	# 断批的根治——R212 素材②）。桶为原点无变换，local position 语义恒等；
	# pool 未注入/host 未装配（老测试）零操作。is_clean 闸（false=激活期）：spawn 先置
	# is_clean=false 再 _sync_visual → 落桶；归还链 _reset_state 先置 is_clean=true 再
	# _sync_visual 重排贴图 → 闸挡回，unplace 归位池根不被覆盖。
	if is_clean:
		return
	if pool != null and pool.bucket_host != null and _sprite != null and _sprite.texture != null:
		pool.bucket_host.place(self, _sprite.texture)


func _apply_visual_rotation() -> void:
	# 朝向跟踪（导弹：贴图朝上 = angle + PI/2，机头对齐航向；曳光：贴图指向右 = angle）。
	# 低速保持既有 rotation（直排版口径不变）。
	# R243：飞剑/掷斧画布同导弹朝上 -Y（剑尖/斧刃迎向飞行方向）——走 else 分支零改动。
	if velocity.length_squared() <= 1.0:
		return
	if _vis_variant == _VIS_TRACER:
		_sprite.rotation = velocity.angle()
	else:
		_sprite.rotation = velocity.angle() + PI * 0.5


func _host_transcended() -> bool:
	# R243 宿主质变态守卫读（flying_sword_weapon._transcend_active 同口径：属性缺位
	# get 返 NIL，bool(NIL) 在 4.3 是运行时错误「Nonexistent 'bool' constructor」——
	# 必须 typeof 显式判型）。无宿主 / 失效引用 / pre-w4 = 默认形态。
	if weapon_ref == null or not is_instance_valid(weapon_ref):
		return false
	var flag: Variant = weapon_ref.get("transcended")
	return typeof(flag) == TYPE_BOOL and flag


func _flight_form_tex(p_sword: bool) -> Texture2D:
	# R243 飞剑/掷斧弹体贴图单源：static func flight_tex 在各武器脚本（贴图生成放武器
	# 脚本、不动共享 TextureFactory——R243 纪律；脚本内 static 缓存 = 同形态弹共享同
	# 贴图实例，_place_in_bucket 桶合批友好）。质变染体（鎏金剑体/岩纹斧体，§7.2）按
	# 宿主 transcended 切换缓存键。
	# 簇2 c2-③：元素附魔传 _plain_fill 表色染剑刃/斧刃；KIN 一参回落保原蓝/原钢
	#（_plain_fill 对 KIN 返 PLAYER——≠斧原钢 0.62,0.68,0.78，KIN 若二参会烤出蓝斧）。
	# 质变与元素撞车时贴图函数内元素优先（KIN 才落鎏金/岩纹）。
	if p_sword:
		if element == GameConst.Element.KIN:
			return FlyingSwordWeapon.flight_tex(_host_transcended())
		return FlyingSwordWeapon.flight_tex(_host_transcended(), _plain_fill())
	if element == GameConst.Element.KIN:
		return GroundAxeWeapon.flight_tex(_host_transcended())
	return GroundAxeWeapon.flight_tex(_host_transcended(), _plain_fill())


func _find_player() -> Node2D:
	# 玩家引用缓存（组查找；包 4 集成期可改为显式注入——当前零接线成本）
	if _player_cache == null or not is_instance_valid(_player_cache):
		_player_cache = null
		var tree := get_tree()
		if tree != null:
			_player_cache = tree.get_first_node_in_group(&"player") as Node2D
	return _player_cache


func _player_hp_pct() -> float:
	# 背水协议条件（SYN_LOWHP_FURY ctx；无玩家 → 1.0 满血安全值）
	# R220 刀4：Player 类型化直调（else 保留 has_method 桩路径——R210 双轨）
	var player := _find_player()
	if player == null:
		return 1.0
	if player is Player:
		return (player as Player).get_hp_pct()
	if player.has_method(&"get_hp_pct"):
		return float(player.call(&"get_hp_pct"))
	return 1.0


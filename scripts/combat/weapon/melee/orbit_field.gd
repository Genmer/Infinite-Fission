# scripts/combat/weapon/melee/orbit_field.gd
# M-08 OrbitField（架构 §2.8.5）：环绕力场实体——浮游刀绕本体公转 + 蓄能引爆状态机。
# · 公转推进：angle += angular_speed °/s（240°/s，A3 §3.8）；刀位均匀相位分布。
# · 蓄能状态机（W8 核心改版，R186 附着位拆除）：接触 = 蓄能源——刀对目标接触（同目标
#   内冷却 charge_gain_cd，替代旧 hit_cd 逐刀冷却语义）→ 接触伤（输出底，完整管线乘区）
#   + 蓄能 +1。蓄能池 = 敌侧通用标记通道 charge_stacks（目标 uid 全局单例——本体/复制体
#   共池，敌亡回收在共享组 enemy.gd）；敌未暴露该通道时回落静态池（uid 单例语义不变）。
#   满 charge_max → 敌侧引爆 detonate_mult×atk 的 detonate_radius AoE 并清零——时钟在
#   敌人身上，全武器唯一锯齿输出。
# · 引力脉冲：pulse_cd 节拍（OrbitWeapon 经 weapon_base._fire_interval 的 cd×(1−ΣCDR)
#   通道驱动 gravity_pulse，AFF_CDR 对 W8 首次生效）——环内已蓄能目标 +1（与接触共用
#   蓄能闸：总蓄能率钳 1/charge_gain_cd，蓄能率公式 R=min(orbs×angular/360+1/pulse_cd,
#   1/charge_gain_cd) 的两项同闸）。
# · 引爆三道闸：①全局共享 ICD（detonate_global_icd=0.5s，静态帧戳——本体+复制体共闸）
#   ②单目标 ICD 0.25s ③单目标刀数帽 effective_blade_cap=8（数量词条语义=覆盖面+提前
#   饱和：16 刀对单目标的命中事件 ≤8 刀等价位）。
# · 塑场：击退径向外推改义 = 切向 60%（沿公转方向扫带）+ 径向归环 40%（朝轨道半径修正，
#   钳 ±8px/击）；仍走 Enemy.knockback（质量分级/自爆引导打断契约不变）。
# · 阈值：TH_DETONATION_ECHO（detonation_count≥8 → 下次引爆×1.5 后重计）/
#   TH_RING_PRESSURE（charged_hits≥60 → 引爆半径+20%）。
# · R186 拆除声明：attach_gate/attach_mult/_attach_cd 与按球定元素（_orb_element/
#   _enchant_elements）全删；ELE 词条 ON_HIT 派发的 attach_request 在 W8 零消费点——
#   apply_attach 永不触达（test_w8_charge 锁死不复潮）。染色降为 weapon.dominant_element()
#   单色（R87 共鸣源，纯视觉、无附着语义）。
# · 生命周期：单武器常驻单例（OrbitWeapon 持有；tick 由武器驱动，随宿主平移）。
# · W9 追击模式零波及（蓄能/脉冲/引爆仅环绕模式可达；命中仍走 ArcSlash 弧形判定）。
# · 表现（R32→R243 §2.4）：默认 = 狼头弯刀（近战·天狼刀——刀身弯月弧刃 + 狼首护手
#   剪影，PLAYER 蓝主填充 + 白獠牙高光；knife_scale 视觉缩放通道原样生效）+ 形态卡
#  （sword 剑 / axe 斧 / bolt 闪电，R19）覆盖绘制。
# · R243 §3.3 W8 挡弹：逐刀逐帧判定 pass（_judge_orb）附带敌弹圆查询
#  （enemy_bullet_grid，OrbitWeapon._ensure_orbit_field 注入），逐弹掷
#   weapon.bullet_block_chance()（W8 基线 0.30），帽 4/tick；挡下走 nullify() 统一
#   收束 + bullet_nullified 涟漪 + bullet_parry 计数。
# · R243 §4.5-4 子引爆拆分：_detonate_aoe = 纯结算体 _detonate_settle + 末端
#   ON_EXPIRE 派发与 melee_split_request 消费——子引爆只走纯结算体（无孙代，
#   禁止子引爆同走 _detonate_aoe 的树状递归路径）；请求空 = 行为零变化。
class_name OrbitField
extends Node2D

const HIT_FLASH_COUNT := 8                    # 命中冲击小环并发池（轮换）
const HIT_FLASH_LIFE := 0.22                  # 命中小环时长 s
const PATH_DASHES := 26                       # 轨道虚线段数（奇数段绘制 = 虚线观感）

# ── R268 V1 匕首感修复常量（用户反馈 A「近战·旋风刀跟匕首一样」——设计 §3.1 处方
#    tunable 值；判定/蓄能/挡弹走 orb_radius 零动，本块全部纯视觉） ──────────────
const BLADE_LEN_FLOOR := 50.0                 # V1-A1：刀参数地板 34→50（W8 orb_r 16-20
                                              # 全等级命中旧地板 34=恒 35.7px 零成长根因①）
const BLADE_LEN_GROWTH := 1.8                 # V1-A1：地板外每级线性成长 px（(orb_r-16)×1.8）
const BLADE_W_FLOOR := 5.2                    # V1-A2：刀宽地板 3.4→5.2（长宽比 3.3:1→≈2.8:1）
const TRAIL_SPAN_DEG := 42.0                  # V1-B：逐刀拖尾弧跨（原 42° 口径保持）
const TRAIL_ALPHA := 0.30                     # V1-B：拖尾 α 0.18→0.30（R262b α 四分档取档；
                                              # 薄荷 α0.18 on 白底 #eef3ff ≈不可见根因③）
const TRAIL_WIDTH_N := 2.2                    # V1-B：拖尾宽 orb_r×1.5→×2.2
const GHOST_LAG_DEG := 12.0                   # V1-C：残影公转切向滞后角（处方带 10-14° 中值）
const GHOST_BODY_ALPHA := 0.22                # V1-C：残影 body 多边形 α（处方 ≈0.22）

# ── 蓄能引爆（W8 核心改版数据键，真源 resources/weapons/W8_orbit_field.tres melee 段）──
const CHARGE_KEY := &"charge_stacks"          # 敌侧通用标记通道键（共享组 enemy.gd 契约）
const DETONATE_TARGET_ICD := 0.25             # 闸②：单目标引爆 ICD s
const GAME_HZ := 120.0                        # 帧戳时钟（GameConfig.frame_stamp @120Hz）
const KNOCK_TANGENT_RATIO := 0.6              # 塑场：击退切向分量 60%
const KNOCK_RING_RATIO := 0.4                 # 塑场：击退径向归环分量 40%
const KNOCK_RADIAL_CAP := 8.0                 # 塑场：径向分量钳 ±8px/击（验收口径）
const DETONATE_RADIUS_PER_LAYER := 0.15       # 斧/巨刃改义：引爆半径 +15%/层
const PULSE_IDLE_GAP := 0.15                  # 脉冲自闸：距上次蓄能的最小间隔 s（cap 域让位）
const ECHO_THRESHOLD_DEFAULT := 8.0           # TH_DETONATION_ECHO 缺省锚（与 .tres 同值）
const ECHO_MULT_DEFAULT := 1.5
const RING_THRESHOLD_DEFAULT := 60.0          # TH_RING_PRESSURE 缺省锚（与 .tres 同值）
const RING_MULT_DEFAULT := 1.2
const CHAIN_TRAIT_ID := &"MEC_CHAIN_DETONATE"  # 链式引爆卡（R187 §2.5.6 传导轴）
const CHAIN_TRANSFER_RADIUS := 160.0          # 传导半径 px（160px 内最近敌）
const BULLET_BLOCK_CAP_PER_TICK := 4          # R243 §3.3：刀位挡弹帽（4 消弹/tick）
const BULLET_BLOCK_MARGIN := 6.0              # 刀位挡弹查询外扩（orb_r×knife_scale+6）

static var _detonate_global_stamp: int = 0    # 闸①：全局引爆解禁帧戳（本体+复制体共享）
static var _detonate_target_stamp: Dictionary = {}   # 闸②：uid -> 解禁帧戳
static var _charge_pool: Dictionary = {}      # 蓄能回落池（敌未暴露 charge_stacks 通道时；
                                              # 静态表 = uid 全局单例语义不变）

var style: String = "orb"                      # 环绕形态（orb 飞刀默认 / sword 剑 / axe 斧 / bolt 闪电，R19/R32；键名 orb 为卡组契约保持）
var leash_radius: float = 0.0                  # R65 追击活动半径（>0 = W9 追击模式；0 = W8 环绕模式不变）
var chase_speed: float = 420.0                 # R65 追击移速（px/s）
var engage_r: float = 46.0                     # R65 贴身开砍距离（刀心-目标心）
var knife_scale: float = 1.0                   # R65 巨刃词条：刀体视觉缩放
var orbs: int = 2                              # 浮游球数
var orbit_radius: float = 90.0
var angular_speed: float = 240.0               # °/s
var orb_radius: float = 16.0
var angle: float = 0.0                         # 公转相位（rad）
var knockback: float = 40.0
var hit_cd: float = 0.5                        # 旧逐刀冷却键（死数值保留：gatling 形态卡契约
                                               # 观测口 + charge_gain_cd 缺省回落源）
var charge_max: float = 5.0                    # 满档蓄能（引爆阈值；validator [3,8]）
var charge_gain_cd: float = 0.5                # 同目标蓄能内冷却 s（替代 hit_cd 活闸语义）
var detonate_mult: float = 5.0                 # 引爆当量 = ×atk
var detonate_radius: float = 90.0              # 引爆 AoE 半径 px（斧/巨刃 +15%/层）
var effective_blade_cap: int = 8               # 单目标刀数帽（覆盖面+提前饱和）
var detonate_global_icd: float = 0.5           # 闸①：全局共享引爆 ICD s
var charged_hits: int = 0                      # TH_RING_PRESSURE 计数（蓄能命中累计）
var detonation_count: int = 0                  # TH_DETONATION_ECHO 计数（引爆累计）
var _gain_cd: Dictionary = {}                  # 蓄能闸：target_uid -> 剩余冷却
var _blade_hits: Dictionary = {}               # 刀数帽：target_uid -> {orb_idx: true}（每公转周重置）

var weapon: WeaponBase = null                  # 结算宿主（OrbitWeapon 注入）
var enemy_bullet_grid: SpaceGrid = null        # R243 §3.3 敌弹网格（刀位挡弹查询——
                                               # OrbitWeapon._ensure_orbit_field 注入新字段）
var _detonate_uid: int = 0                     # 引爆结算独立 source_uid（管线幂等键分流——
                                               # 同帧接触伤/引爆不互撞，ElementalSystem DOT/连锁
                                               # 独立 uid 同款先例）

var _orb_glows: Array[Sprite2D] = []           # 球体辉光底层（soft_dot 薄荷绿）
var _orb_cores: Array[Sprite2D] = []           # 球体珠核（bead 描边贴纸风）
var _orb_punch: Array[float] = []              # 命中膨胀脉冲（每球独立 0→1→0）
var _hit_flashes: Array[Dictionary] = []       # [{sprite, left}]（命中冲击小环池）
var _flash_idx: int = 0
var _anim_t: float = 0.0                       # 表现时钟（bolt 颤动相位，R19）
var _knife_pos: Array[Vector2] = []            # R65 逐刀位置（局部坐标，相对玩家）
var _knife_face: Array[float] = []             # R65 逐刀朝向（rad；追击=行进方向 / 环绕=切向）
var _knife_target: Array[Node2D] = []          # R65 逐刀当前目标（null = 无目标回轨）
var _last_center: Vector2 = Vector2.ZERO       # R65 最近宿主世界位（strike/脉冲世界位换算基准）
# R188 档0 治理件：
var _gain_cd_expired: Array[int] = []          # _gain_cd 零值即擦的两相擦除 scratch（成员复用零分配）
var _judge_scratch: Array[Node2D] = []         # _judge_orb 候选成员缓冲（复制语义保留；嵌套网格查询
                                               # 走网格内部缓冲，不改写本 scratch——同实例重入无通道）
var _redraw_ctr: int = 0                       # 重绘节流计数（120Hz tick → 60Hz queue_redraw）
var _label_ctr: int = 0                        # 蓄能读数节流计数（60Hz 重绘 → 15Hz 网格查询）
var _label_cache: Array[Dictionary] = []       # 蓄能档位读数缓存 [{lp, text, col}]（查询帧重建）
var _label_atk_text: String = ""               # 底缘数值标注缓存（build_panel_snapshot 每 12 重绘刷一次）
var _block_left: int = 0                       # R243 §3.3 刀位挡弹帽余额（4/tick，判定帧首重置）
var _lod_judge: bool = false                   # R289 A：本判定帧为深载隔帧执行步（dt×2——
                                               # 挡弹概率/帽按两帧等效折算）


func _init() -> void:
	# 引爆幂等键分流 uid（实例级一次；同帧「接触伤 + 引爆」双结算不同键——L5 幂等护栏
	# 不会把引爆当成接触伤的重复结算丢弃）
	_detonate_uid = GameConst.next_uid()


func spawn(p_params: Dictionary) -> void:
	# 初始化（OrbitWeapon._ensure_orbit_field 构造 / refresh_orbit_field 重铺——球数增减即改）
	orbs = clampi(int(p_params.get("orbs", 2)), 1, 16)
	orbit_radius = maxf(float(p_params.get("orbit_radius", 90.0)), 1.0)
	angular_speed = float(p_params.get("angular_speed", 240.0))
	orb_radius = maxf(float(p_params.get("orb_radius", 16.0)), 1.0)
	knockback = float(p_params.get("knockback", 40.0))
	hit_cd = maxf(float(p_params.get("hit_cd", 0.5)), 0.01)
	# 蓄能键组（OrbitWeapon._orbit_params 注入；数据键全落 melee 段——吸取 attach_mult
	# 未落 .tres 教训）。charge_gain_cd 缺省回落 hit_cd 旧通道（旧数据/桩夹具零声明也成立）。
	charge_max = clampf(float(p_params.get("charge_max", 5.0)), 1.0, 16.0)
	charge_gain_cd = maxf(float(p_params.get("charge_gain_cd", hit_cd)), 0.05)
	detonate_mult = maxf(float(p_params.get("detonate_mult", 5.0)), 0.1)
	detonate_radius = clampf(float(p_params.get("detonate_radius", 90.0)), 1.0, 256.0)
	effective_blade_cap = maxi(int(p_params.get("effective_blade_cap", 8)), 0)
	detonate_global_icd = maxf(float(p_params.get("detonate_global_icd", 0.5)), 0.0)
	leash_radius = maxf(float(p_params.get("leash_radius", 0.0)), 0.0)
	chase_speed = maxf(float(p_params.get("chase_speed", 420.0)), 60.0)
	engage_r = maxf(float(p_params.get("engage_r", 46.0)), 8.0)
	# R262b L10 契约注：knife_scale 在 .tres 声明为布尔 true（探测位），真值走
	# MEC_GIANT_BLADE.value（weapon_base._giant_blade_value→orbit_weapon 注入计算后
	# float）——本处 float(bool)=1.0 静默无缩放，故 params 原样直达即错；任何旁路把
	# .tres params 直接塞进本表前必须先转注入形态（见 attach_mult 未落 .tres 教训）
	knife_scale = maxf(float(p_params.get("knife_scale", 1.0)), 0.4)
	style = String(p_params.get("style", "orb"))
	# R183 W8 复制体相位偏移（BASE 单环阵 + 45°——复制体与本体错位公转；本体恒 0）
	angle = deg_to_rad(float(p_params.get("angle_deg", 0.0)))
	_gain_cd.clear()                              # 重铺即清蓄能闸（新词条构成重计）
	_blade_hits.clear()
	_label_atk_text = ""                          # R188 档0：重铺即刷数值标注缓存（形态/参数可能已变）
	_label_cache.clear()
	charged_hits = 0
	detonation_count = 0
	visible = true
	z_index = 4                                  # 敌/弹（z=0 树序层）之上、元素特效层（z=5）之下
	_sync_knife_arrays()
	_build_visuals()
	_sync_orb_visibility()
	queue_redraw()


func _sync_knife_arrays() -> void:
	# R65 逐刀状态数组对齐 orbs（新增刀落位轨道槽；收缩保留——再扩复用）
	while _knife_pos.size() < orbs:
		var i := _knife_pos.size()
		_knife_pos.append(_orbit_slot(i))
		_knife_face.append(_knife_pos[i].angle() + PI * 0.5)
		_knife_target.append(null)
	if _knife_pos.size() > orbs:
		_knife_pos.resize(orbs)
		_knife_face.resize(orbs)
		_knife_target.resize(orbs)


func _build_visuals() -> void:
	# 表现件预建（spawn 期一次；球数增长时补建差额——诺亚僚机召唤通道，P2；仅增量实例化）
	if _orb_cores.is_empty():
		var mint := PopPalette.SUCCESS
		var flash_col := mint.lerp(Color.WHITE, 0.25)
		for i in range(HIT_FLASH_COUNT):
			var sp := Sprite2D.new()
			sp.name = "HitFlash%d" % i
			sp.texture = TextureFactory.ring_tex(flash_col, 48, 4.0)
			sp.visible = false
			add_child(sp)
			_hit_flashes.append({"sprite": sp, "left": 0.0})
	var mint2 := PopPalette.SUCCESS
	while _orb_cores.size() < orbs:
		var i := _orb_cores.size()
		var glow := Sprite2D.new()
		glow.name = "OrbGlow%d" % i
		glow.texture = TextureFactory.soft_dot(64)
		# R64 刀形可读化：光晕缩到刀体尺度（64→32px）并压暗——此前满幅光球的轮廓
		# 压过 17px 小刀，整体读感仍是「绿球不是飞刀」（用户四轮同类反馈的环绕版）
		glow.scale = Vector2.ONE * 0.5
		glow.modulate = Color(mint2.r, mint2.g, mint2.b, 0.26)
		add_child(glow)
		_orb_glows.append(glow)
		var core := Sprite2D.new()
		core.name = "OrbCore%d" % i
		core.texture = TextureFactory.bead(mint2.lerp(Color.WHITE, 0.55))
		add_child(core)
		_orb_cores.append(core)
		_orb_punch.append(0.0)


func _sync_orb_visibility() -> void:
	# 球数收缩（还原通道）：超额球体隐藏（数组保留——再次召唤复用，不反复增删子节点）。
	# R32：默认 = 飞刀程序化绘制——珠核贴图一律隐藏（辉光保留作刀身底光）
	for i in range(_orb_cores.size()):
		_orb_cores[i].visible = false
		_orb_glows[i].visible = i < orbs


func tick(p_game_delta: float, p_center: Vector2) -> void:
	# 公转推进 + 球位更新 + 接触蓄能判定（charge_gain_cd 内冷却）+ 塑场击退 + 表现推进
	# R10 根因修复：同弧斩——局部/全局坐标空间错配（环绕力场此前同样整场不可见）
	position = weapon.to_local(p_center) if weapon != null and is_instance_valid(weapon) 		else p_center
	_last_center = p_center
	_anim_t += p_game_delta
	var prev_angle := angle
	angle = wrapf(angle + deg_to_rad(angular_speed) * p_game_delta, 0.0, TAU)
	if angle < prev_angle:
		_blade_hits.clear()                       # 刀数帽按公转周重置（每转重新计闸）
	# R188 档0：_gain_cd 零值即擦（两相擦除——先收集到期键再统一 erase；原实现零值残留
	# 随敌流持续累积，长局键数无界）
	_gain_cd_expired.clear()
	for key in _gain_cd:
		var left := float(_gain_cd[key]) - p_game_delta
		if left <= 0.0:
			_gain_cd_expired.append(int(key))
		else:
			_gain_cd[key] = left
	for key in _gain_cd_expired:
		_gain_cd.erase(key)
	if leash_radius > 0.0:
		# R65 W9 追击模式：逐刀索敌追击/回轨（无接触判定——伤害全部走挥砍弧；
		# 蓄能/脉冲/引爆为 W8 环绕模式独占，W9 零波及）
		_tick_chase(p_game_delta, p_center)
		_update_orb_sprites(p_game_delta)
		_request_redraw()
		return
	# W8 环绕模式（口径不变）：刀位 = 轨道槽 + 逐球周期接触蓄能判定
	_sync_knife_arrays()
	# R289 A：隔帧执行步（weapon.tick 收到 dt×2）把挡弹帽 ×2——两次判定并一次的等效帽；
	# 概率在 _block_bullets_near 内按 1−(1−p)² 折算。
	_lod_judge = WeaponBase.lod_dt_doubled
	_block_left = BULLET_BLOCK_CAP_PER_TICK * (2 if _lod_judge else 1)
	for i in range(orbs):
		_knife_pos[i] = _orbit_slot(i)
		_knife_face[i] = _knife_pos[i].angle() + PI * 0.5
	if weapon == null or weapon.enemy_grid == null:
		_update_orb_sprites(p_game_delta)
		_request_redraw()
		return
	for i in range(orbs):
		var orb_pos := _orb_position(i, p_center)
		_judge_orb(i, orb_pos, p_center)
	_update_orb_sprites(p_game_delta)
	_request_redraw()


func _request_redraw() -> void:
	# R188 档0：重绘节流（120Hz tick → 60Hz 重绘；公转/自旋视觉平滑度不变级，
	# headless 渲染无关——真机渲染面收益；蓄能读数走 _label_cache 独立节拍）
	# R233 T4 决策2-④：模拟 30Hz 下本节流会把 _draw() 自绘（公转环/球体）打到 15Hz
	# ——插值层只覆写实体 global_position 救不了 _draw() 自绘内容，谓词成立时短路
	# 每 tick 重绘（=30Hz，与现状 mobile 60Hz tick÷2 实效等价；回退 60Hz 档原样恢复）。
	# 注：_label_ctr 读数节流（%12/%4，纯表现低危）不在本刀四处清单内（设计决策2 定案
	# 未列入——重绘频率回升后其刷新率随之上行，披露不改动）。
	_redraw_ctr += 1
	# R289 修轮（评审 P2-5）：深载 15fps 时武器块仅 7.5 次/s，再叠 %2 节流会掉到
	# 3.75Hz（读感「刀环瞬移」）——深载态短路节流（=执行拍 7.5Hz，与移动同步）。
	if GameLoop.sim30_effective() or PerfGovernor.deep_load() or _redraw_ctr % 2 == 0:
		queue_redraw()


func _judge_orb(p_orb_index: int, p_orb_pos: Vector2, p_center: Vector2) -> void:
	# 单球周期判定：圆查询 → 接触目标 → 蓄能命中登记（接触伤 + 蓄能 +1）。
	# R188 档0：候选复制进成员 scratch（原每球每帧新建数组；query_circle 返回内部
	# 复用缓冲，复制语义承重墙保留——嵌套网格查询走网格内部缓冲，不改写本 scratch）
	_judge_scratch.clear()
	_judge_scratch.append_array(weapon.enemy_grid.query_circle(p_orb_pos, orb_radius))
	var tan := _orb_tangent(p_orb_pos, p_center)
	for target in _judge_scratch:
		if target == null or bool(target.get("dead")):
			continue
		var dist := p_orb_pos.distance_to((target as Node2D).global_position)
		if dist > orb_radius + float(target.get("hitbox_r")):
			continue
		if _register_charge_hit(p_orb_index, target, p_center, tan) and p_orb_index >= 0:
			# R199 C16：命中反馈接线——_fire_hit_fx 是 _orb_punch 置 1 与 _hit_flashes
			# 点亮的唯一写点，此前全仓零调用（特效系统整链死码：球体膨胀脉冲+命中点
			# 冲击小环从不显示）。命中点 = 环绕球心（全局坐标，函数内 to_local 落位）。
			_fire_hit_fx(p_orb_index, p_orb_pos)
	# R243 §3.3：刀位挡弹（附带本判定 pass——概率掷骰，帽 4/tick 全场共享）
	_block_bullets_near(p_orb_pos)


func _block_bullets_near(p_orb_pos: Vector2) -> void:
	# W8 天狼刀刀位挡弹（R243 §3.3）：query_circle(刀位, orb_r×knife_scale+6) → 逐弹
	# 掷 weapon.bullet_block_chance()（W8 基线 0.30，MEC_BULLET_PARRY add_block 池成长）
	# → 命中掷骰即 nullify()（统一收束 OnExpire(NULLIFIED)）+ 青涟漪 + bullet_parry 计数。
	# 帽 4/tick：跨刀共享余额（_block_left，tick 判定帧首重置）——防弹幕洪峰逐刀翻倍。
	# R289 A：隔帧执行步（两次判定并一次）概率折算 1−(1−p)²，帽 ×2 由 tick 首置——
	# 期望挡弹率按模拟时间守恒（浮点域近似：弹集跨步变化属披露近似，非精确等价）。
	if enemy_bullet_grid == null or weapon == null or not is_instance_valid(weapon):
		return
	if _block_left <= 0:
		return
	var chance := weapon.bullet_block_chance()
	if _lod_judge and chance > 0.0:
		chance = 1.0 - (1.0 - chance) * (1.0 - chance)
	if chance <= 0.0:
		return
	var bullets := enemy_bullet_grid.query_circle(p_orb_pos,
		orb_radius * knife_scale + BULLET_BLOCK_MARGIN)
	for bullet in bullets:
		if _block_left <= 0:
			break
		if bullet is ProjectileBase and (bullet as ProjectileBase).team == 1:
			if chance >= 1.0 or randf() < chance:
				(bullet as ProjectileBase).nullify()
				_block_left -= 1
				DebugStats.count(&"bullet_parry")
				EventBus.emit_bullet_nullified((bullet as ProjectileBase).global_position)


func gravity_pulse() -> int:
	# 引力脉冲（OrbitWeapon 按 pulse_cd 节拍驱动；节拍走 weapon_base cd×(1−ΣCDR) 通道）：
	# 环内已蓄能目标 +1——透明闸+自闸（_register_pulse_hit：不占接触冷却、距上次蓄能
	# 不足 PULSE_IDLE_GAP 时让位），实现蓄能率公式 R=min(orbs×angular/360+1/pulse_cd,
	# 1/charge_gain_cd) 的加性项与 cap 域。返回实际脉冲命中数（观测口）。
	if weapon == null or not is_instance_valid(weapon) or weapon.enemy_grid == null:
		return 0
	if leash_radius > 0.0:
		return 0                                  # W9 追击模式无环绕脉冲（零波及）
	var pulses := 0
	var reach := orbit_radius + orb_radius
	var candidates: Array[Node2D] = []
	candidates.append_array(weapon.enemy_grid.query_circle(_last_center, reach))
	for target in candidates:
		if target == null or bool(target.get("dead")):
			continue
		if charge_of(target) < 1:
			continue                              # 已蓄能目标才吃脉冲（空池目标不受场引力）
		if _last_center.distance_to((target as Node2D).global_position) \
				> reach + float(target.get("hitbox_r")):
			continue
		var tan := _orb_tangent((target as Node2D).global_position, _last_center)
		if _register_pulse_hit(target, _last_center, tan):
			pulses += 1
	return pulses


func _register_pulse_hit(p_target: Node2D, p_center: Vector2, p_tangent: Vector2) -> bool:
	# 引力脉冲蓄能登记（与接触共用引爆链，闸位不同）：
	# · 透明闸——脉冲不占用/不置位接触冷却 _gain_cd（否则脉冲只是顶替下一次接触增益，
	#   稳态速率恒钉在接触率，公式 R=接触率+1/pulse_cd 的加性项失效）；
	# · 自闸——距上次蓄能（任意源）不足 PULSE_IDLE_GAP 时让位：公式 cap 域（L3+ 接触
	#   饱和档）脉冲自然稀疏，L1/L2 满弛档脉冲足额落账。
	# p_orb_index 闸（刀数帽）不适用——脉冲是场能量，不是刀。
	if p_target == null or not is_instance_valid(p_target) or bool(p_target.get("dead")):
		return false
	var tuid := int(p_target.get("uid"))
	if float(_gain_cd.get(tuid, 0.0)) > charge_gain_cd - PULSE_IDLE_GAP:
		return false                              # 自闸：距上次蓄能过近（cap 饱和域让位）
	_gain_charge(p_target, int(round(charge_max)))
	charged_hits += 1
	_charge_settle(p_target, p_center, p_tangent)
	_maybe_detonate(p_target)
	return true


func _register_charge_hit(p_orb_index: int, p_target: Node2D, p_center: Vector2,
		p_tangent: Vector2) -> bool:
	# 接触蓄能命中登记（引力脉冲走 _register_pulse_hit 独立闸位）：
	# 蓄能闸 → 刀数帽 → 蓄能 +1 → 接触伤 → 引爆检定。
	if p_target == null or not is_instance_valid(p_target):
		return false
	if bool(p_target.get("dead")):
		_forget_target(int(p_target.get("uid")))
		return false
	var tuid := int(p_target.get("uid"))
	if float(_gain_cd.get(tuid, 0.0)) > 0.0:
		return false                              # 同目标蓄能内冷却（同帧双球仅 +1 的闸）
	var blades: Dictionary = _blade_hits.get(tuid, {})
	if p_orb_index >= 0 and effective_blade_cap > 0 \
			and blades.size() >= effective_blade_cap and not blades.has(p_orb_index):
		return false                              # 闸③：单目标刀数帽（覆盖面+提前饱和）
	_gain_cd[tuid] = charge_gain_cd
	_gain_charge(p_target, int(round(charge_max)))
	charged_hits += 1
	_charge_settle(p_target, p_center, p_tangent)
	if p_orb_index >= 0:
		blades[p_orb_index] = true
		_blade_hits[tuid] = blades
	_maybe_detonate(p_target)
	return true


func _gain_charge(p_target: Node2D, p_cap: int) -> void:
	# 蓄能 +1（钳 p_cap）：敌侧走共享组通用标记通道 API（add_charge_stacks——
	# 「W8 接触/脉冲消费口」唯一写入口）；未暴露该 API 的目标回落静态池。
	if p_target.has_method(&"add_charge_stacks"):
		p_target.call(&"add_charge_stacks", 1, p_cap)
		return
	set_charge(p_target, mini(charge_of(p_target) + 1, p_cap))


func _charge_settle(p_target: Node2D, p_center: Vector2, p_tangent: Vector2) -> void:
	# 接触伤结算（蓄能命中的输出底；§4.4 同构时序：乘区预聚合 → 派发 → 结算）。
	# R186 拆除声明：旧附着提交块（resolve 后 apply_attach）整块删除——ELE 词条 ON_HIT
	# 派发的 attach_request 在 W8 零消费点，伤害通道恒 KIN（ctx 不改）。
	var ctx := weapon.build_damage_context(p_target)
	var tctx := TraitContext.new()
	tctx.event = GameConst.TraitEvent.ON_HIT
	tctx.weapon = weapon
	tctx.melee = self
	tctx.target = p_target
	tctx.damage_ctx = ctx
	if weapon.trait_stack != null:
		for pool in weapon.trait_stack.collect_mult_pools(tctx):
			ctx.mult_pools.append(pool)
	weapon.inject_vuln_pool(ctx, p_target)
	if weapon.trait_stack != null:
		weapon.trait_stack.dispatch(GameConst.TraitEvent.ON_HIT, tctx)
	var result: DamageResult = null
	if weapon.damage_pipeline != null:
		result = weapon.damage_pipeline.call(&"resolve", ctx)
	# 落血口径双轨（同 weapon_base.settle_aoe 审查修复）：真件 DamagePipeline 九步 9b
	# 在 resolve 内部已 take_result 落血（_apply_to_target——killed 判定/死亡广播唯一
	# 执行点），本侧再落血即环绕体伤害 ×2；透传桩 resolve 只算不落血，落血职责在调用
	# 方（pkg2/pkg3 桩用例锁定口径，保持不变）。管线为 null 时 result 为 null，本就不落血。
	if result != null and not (weapon.damage_pipeline is DamagePipeline) \
			and p_target.has_method(&"take_result"):
		p_target.call(&"take_result", result)
	_apply_knockback(p_target, p_center, p_tangent)
	DebugStats.count(&"orbit_hit")


func _maybe_detonate(p_target: Node2D) -> bool:
	# 满档引爆检定（三道闸 → AoE → 清零）。时钟在敌人身上：蓄能池 uid 全局单例——
	# 本体/复制体/脉冲多源共池，谁填满谁引爆，全局 ICD 保同帧恰 1 次。
	if p_target == null or not is_instance_valid(p_target) or bool(p_target.get("dead")):
		return false
	if charge_of(p_target) < int(round(charge_max)):
		return false
	var stamp := GameConfig.frame_stamp
	if stamp < _detonate_global_stamp:
		return false                              # 闸①：全局共享 ICD（本体+复制体共闸）
	var tuid := int(p_target.get("uid"))
	if stamp < int(_detonate_target_stamp.get(tuid, 0)):
		return false                              # 闸②：单目标 ICD
	var atk := 0.0
	if weapon != null and is_instance_valid(weapon):
		atk = float(weapon.build_panel_snapshot().get("base_atk", 0.0))
	# 阈值质变：TH_DETONATION_ECHO（累计 detonation_count ≥ 阈 → 本次引爆×1.5 后重计）/
	# TH_RING_PRESSURE（累计 charged_hits ≥ 阈 → 引爆半径+20%）。get_threshold 缺声明时
	# 走常量缺省锚（与 .tres 同值——阈值条目被引用校验剔除也不失能）。
	var echo_armed := detonation_count >= _echo_threshold()
	var dmg := atk * detonate_mult * (_echo_mult() if echo_armed else 1.0)
	var radius := detonate_radius * _ring_pressure_mult()
	if dmg > 0.0 and radius > 0.0:
		_detonate_aoe((p_target as Node2D).global_position, radius, dmg)
	# 引爆清零（锯齿回落，时钟归位）——敌侧走共享组引爆消费口 clear_charge_stacks
	if p_target.has_method(&"clear_charge_stacks"):
		p_target.call(&"clear_charge_stacks")
	else:
		set_charge(p_target, 0)
	_blade_hits.erase(tuid)
	_detonate_global_stamp = stamp + _icd_frames(detonate_global_icd)
	_detonate_target_stamp[tuid] = stamp + _icd_frames(DETONATE_TARGET_ICD)
	detonation_count = 0 if echo_armed else detonation_count + 1
	_chain_transfer(p_target)                 # R187 链式引爆（MEC_CHAIN_DETONATE 消费口）
	DebugStats.count(&"w8_detonations")
	if EventBus.has_signal(&"w8_detonated"):
		EventBus.call(&"emit_w8_detonated", (p_target as Node2D).global_position, tuid)
	return true


func _chain_transfer(p_detonated: Node2D) -> void:
	# R187 链式引爆（MEC_CHAIN_DETONATE 消费口，§2.5.6）：引爆时转移
	# floor(charge_max×0.4) 档蓄能给引爆点 160px 内最近存活敌——纯物理通道（构成
	# 「先打谁、传给谁」的清场排序）；引爆 AoE 溅射不回灌蓄能（_detonate_aoe 不走
	# _gain_charge，滚雪球防阀），转移只经本口一次性落账。
	if _holder_trait_layers(CHAIN_TRAIT_ID) <= 0:
		return
	var amount := int(floor(charge_max * 0.4))
	if amount <= 0 or weapon == null or not is_instance_valid(weapon) \
			or weapon.enemy_grid == null:
		return
	var pos := (p_detonated as Node2D).global_position
	var best: Node2D = null
	var best_d := CHAIN_TRANSFER_RADIUS
	# R188 别名审计：此处原直接引用网格内部缓冲（query_circle 返回值零复制别名）——
	# 本环内虽无嵌套网格查询（现行为安全），但本函数由 _judge_orb 候选迭代中途触发，
	# 复用成员 scratch 会外层踩踏；引爆 Rare 路径维持局部复制（语义等价、防脆弱）
	var candidates: Array[Node2D] = []
	candidates.append_array(weapon.enemy_grid.query_circle(pos, CHAIN_TRANSFER_RADIUS))
	for cand in candidates:
		if cand == null or cand == p_detonated or bool(cand.get("dead")):
			continue
		var d := pos.distance_to((cand as Node2D).global_position)
		if d < best_d:
			best_d = d
			best = cand
	if best == null:
		return
	if best.has_method(&"add_charge_stacks"):
		best.call(&"add_charge_stacks", amount, int(round(charge_max)))
	else:
		set_charge(best, mini(charge_of(best) + amount, int(round(charge_max))))
	DebugStats.count(&"w8_chain_transfers")


func _holder_trait_layers(p_id: StringName) -> int:
	# 宿主武器指定词条挂载层数（结算宿主直读——_trait_layers 的 OrbitField 侧镜像）
	if weapon == null or not is_instance_valid(weapon) or weapon.trait_stack == null:
		return 0
	for tb in weapon.trait_stack.traits:
		if tb.data != null and tb.data.id == p_id:
			return int(tb.get("layers"))
	return 0


func _detonate_aoe(p_pos: Vector2, p_radius: float, p_dmg: float) -> void:
	# 母引爆入口（R243 §4.5-4 终审①拆分）= 纯结算体 _detonate_settle + 末端
	# ON_EXPIRE 派发与 melee_split_request 消费。禁止实现路径：子引爆同走本入口
	# （树状递归）——子引爆只走 _detonate_settle，结构上无孙代（套件反断言把守）。
	_detonate_settle(p_pos, p_radius, p_dmg)
	_consume_melee_split(p_pos, p_radius, p_dmg)


func _detonate_settle(p_pos: Vector2, p_radius: float, p_dmg: float) -> void:
	# 引爆纯结算体（R243 §4.5-4：原 _detonate_aoe 结算逻辑原样搬入，_detonate_uid 复用；
	# 母引爆与子引爆共用本口——子引爆不再派发 ON_EXPIRE，故无孙代）：
	# ① source_uid = _detonate_uid——管线幂等键 (source,target,frame) 与同帧接触伤分流，
	#    引爆心目标自身的引爆伤害不被幂等缓存吞掉（ElementalSystem DOT/连锁先例）；
	# ② 网格候选后补窄相精判（dist ≤ 半径 + 目标 hitbox）——rebuild 入桶取保守
	#    max_entity_radius 粗筛，settle_aoe 无窄相会把 detonate_radius 外的敌卷进来。
	if weapon == null or not is_instance_valid(weapon) \
			or weapon.damage_pipeline == null or weapon.enemy_grid == null:
		return
	var candidates: Array[Node2D] = []
	candidates.append_array(weapon.enemy_grid.query_circle(p_pos, p_radius))
	for target in candidates:
		if target == null or bool(target.get("dead")):
			continue
		if (target as Node2D).global_position.distance_to(p_pos) \
				> p_radius + float(target.get("hitbox_r")):
			continue                              # 窄相精判（AoE 半径口径真值）
		var ctx := DamageContext.make()
		ctx.source_uid = _detonate_uid
		ctx.target = target
		ctx.target_uid = int(target.get("uid"))
		ctx.frame_stamp = GameConfig.frame_stamp
		ctx.base_atk = maxf(p_dmg, 0.0)
		ctx.element = GameConst.Element.KIN
		ctx.hit_flags |= GameConst.HIT_IS_AOE_SECONDARY
		ctx.pos = (target as Node2D).global_position
		var result: DamageResult = weapon.damage_pipeline.call(&"resolve", ctx)
		# 落血口径双轨（同 _charge_settle）：真件 resolve 内部已落血；透传桩由调用方落血
		if result != null and not (weapon.damage_pipeline is DamagePipeline) \
				and target.has_method(&"take_result"):
			target.call(&"take_result", result)
	DebugStats.count(&"w8_detonation_aoe_targets", candidates.size())


func _consume_melee_split(p_pos: Vector2, p_radius: float, p_dmg: float) -> void:
	# 母引爆末端：ON_EXPIRE 派发（tctx.melee=self，六事件宿主近战形态首接）→ 消费
	# melee_split_request（R243 §4.5 通道 B 输出槽；EF_FRACTAL melee 臂由后续波次接线，
	# 现网无生产者 = 请求空 = 行为零变化）。子引爆 = 引爆心 ±spread 均布方向 ×0.5R 处
	# count 个 _detonate_settle(pos_i, R×0.55, dmg×inherit_ratio)——纯结算体直落，
	# 不派发 ON_EXPIRE（无孙代；_detonate_uid 复用，同帧重叠目标由管线幂等闸去重）。
	if weapon == null or not is_instance_valid(weapon) or weapon.trait_stack == null:
		return
	var tctx := TraitContext.new()
	tctx.event = GameConst.TraitEvent.ON_EXPIRE
	tctx.weapon = weapon
	tctx.melee = self
	weapon.trait_stack.dispatch(GameConst.TraitEvent.ON_EXPIRE, tctx)
	var req: Dictionary = tctx.melee_split_request
	if req.is_empty():
		return
	var count := clampi(int(req.get("count", 0)), 0, 8)
	var spread := deg_to_rad(float(req.get("spread_deg", 0.0)))
	var ratio := clampf(float(req.get("inherit_ratio", 0.0)), 0.0, 1.0)
	for i in range(count):
		# 角度均布（request_split 同式：[-spread, +spread] 线性均布；count==1 → 0°）
		var ang := 0.0
		if count > 1:
			ang = spread * (float(i) / float(count - 1) - 0.5) * 2.0
		var pos_i := p_pos + Vector2.from_angle(ang) * (p_radius * 0.5)
		_detonate_settle(pos_i, p_radius * 0.55, p_dmg * ratio)


static func charge_of(p_target: Node2D) -> int:
	# 蓄能读取（蓄能池 = 目标 uid 全局单例）：敌侧通用标记通道 charge_stacks 优先，
	# 未暴露该通道（共享组 enemy.gd 未落地/桩目标）回落静态池（单例语义不变）。
	if p_target == null or not is_instance_valid(p_target):
		return 0
	if CHARGE_KEY in p_target:
		return int(p_target.get(CHARGE_KEY))
	return int(_charge_pool.get(int(p_target.get("uid")), 0))


static func set_charge(p_target: Node2D, p_value: int) -> void:
	# 蓄能写入（同 charge_of 双通道；负值钳 0）
	if p_target == null or not is_instance_valid(p_target):
		return
	var v := maxi(p_value, 0)
	if CHARGE_KEY in p_target:
		p_target.set(CHARGE_KEY, v)
		return
	_charge_pool[int(p_target.get("uid"))] = v


static func reset_detonate_gates() -> void:
	# 测试/夹具收口：引爆闸与回落池清零（静态态不随实例回收；生产帧戳单调，残留戳恒过去
	# 时刻无害，仅测试确定性需要显式清）
	_detonate_global_stamp = 0
	_detonate_target_stamp.clear()
	_charge_pool.clear()


static func _icd_frames(p_seconds: float) -> int:
	# ICD 秒 → 帧戳增量（GameConfig.frame_stamp @120Hz；幂等键口径，多力场实例不双耗）
	return int(round(p_seconds * GAME_HZ))


func _echo_threshold() -> float:
	var entry := _threshold_entry(&"TH_DETONATION_ECHO")
	return float(entry.get("threshold", ECHO_THRESHOLD_DEFAULT))


func _echo_mult() -> float:
	var entry := _threshold_entry(&"TH_DETONATION_ECHO")
	var params: Dictionary = entry.get("params", {}) if entry.get("params", {}) is Dictionary else {}
	return maxf(float(params.get("echo_mult", ECHO_MULT_DEFAULT)), 1.0)


func _ring_pressure_mult() -> float:
	if charged_hits < _ring_threshold():
		return 1.0
	var entry := _threshold_entry(&"TH_RING_PRESSURE")
	var params: Dictionary = entry.get("params", {}) if entry.get("params", {}) is Dictionary else {}
	return maxf(float(params.get("radius_mult", RING_MULT_DEFAULT)), 1.0)


func _ring_threshold() -> float:
	var entry := _threshold_entry(&"TH_RING_PRESSURE")
	return float(entry.get("threshold", RING_THRESHOLD_DEFAULT))


func _threshold_entry(p_id: StringName) -> Dictionary:
	# 阈值声明查询（A3 §3.11 通用质变阈值；宿主武器 threshold_traits 真源）
	if weapon == null or not is_instance_valid(weapon):
		return {}
	return weapon.get_threshold(p_id)


func _apply_knockback(p_target: Node2D, p_center: Vector2, p_tangent: Vector2) -> void:
	# 塑场击退（径向外推改版）：切向 60%（沿公转运动方向扫带）+ 径向归环 40%（朝轨道
	# 半径修正，钳 ±8px/击——验收口径「切向分量>0、径向≤8px/击」）。仍走 Enemy.knockback
	# （质量分级/冲量衰减/自爆引导打断契约不变——引导行为 M2 保留）。
	if knockback <= 0.0 or p_target == null:
		return
	var force := p_tangent * knockback * KNOCK_TANGENT_RATIO
	var to_t := (p_target as Node2D).global_position - p_center
	var dist := to_t.length()
	if dist > 1.0:
		var ring_err := orbit_radius - dist
		if absf(ring_err) > 2.0:                  # 贴环死区（±2px 内不修——防环上抖动）
			force += to_t.normalized() * minf(knockback * KNOCK_RING_RATIO,
				KNOCK_RADIAL_CAP) * signf(ring_err)
	if force.length() <= 0.01:
		return
	if p_target.has_method(&"knockback"):
		p_target.call(&"knockback", force)


func _orb_tangent(p_orb_pos: Vector2, p_center: Vector2) -> Vector2:
	# 公转切向（运动方向；塑场切向分量方向源——与 _draw_styled_orbs 切向同式）
	var dir_out := (p_orb_pos - p_center).normalized()
	if dir_out == Vector2.ZERO:
		return Vector2.ZERO
	return Vector2(-dir_out.y, dir_out.x)


func _forget_target(p_uid: int) -> void:
	# 目标失效/敌亡清场（蓄能池敌亡回收在共享组 enemy.gd——本侧清刀数帽/回落池残留）
	_gain_cd.erase(p_uid)
	_blade_hits.erase(p_uid)
	_charge_pool.erase(p_uid)
	_detonate_target_stamp.erase(p_uid)


func _orb_position(p_index: int, p_center: Vector2) -> Vector2:
	# 球位：均匀相位分布（i × 2π/orbs）
	var phase := angle + TAU * float(p_index) / float(orbs)
	return p_center + Vector2(cos(phase), sin(phase)) * orbit_radius


func _orbit_slot(p_index: int) -> Vector2:
	# R65 轨道槽位（局部偏移；环绕模式刀位 = 本槽，追击模式回归点）
	var phase := angle + TAU * float(p_index) / float(orbs)
	return Vector2(cos(phase), sin(phase)) * orbit_radius


func _tick_chase(p_game_delta: float, p_center: Vector2) -> void:
	# R65 W9 追击 AI：逐刀在活动半径（leash_radius）内索最近敌 → 追至贴身悬停；
	# 无敌 → 回轨道槽环绕。攻击判定不在本层（贴身开砍由 OrbitWeapon 消费
	# collect_engaged_strikes → ArcSlash 弧形判定——攻击范围口径零变化）。
	var candidates: Array[Node2D] = []
	if weapon != null and is_instance_valid(weapon) and weapon.enemy_grid != null:
		candidates.append_array(weapon.enemy_grid.query_circle(p_center, leash_radius))
	var step := chase_speed * p_game_delta
	for i in range(orbs):
		var target: Node2D = _pick_chase_target(candidates, p_center + _knife_pos[i],
			_knife_target[i])
		_knife_target[i] = target
		if target != null:
			var to_t: Vector2 = weapon.to_local(target.global_position) - _knife_pos[i]
			var dist := to_t.length()
			var dir := to_t / maxf(dist, 0.001)
			_knife_face[i] = dir.angle()
			if dist > engage_r * 0.55:
				_knife_pos[i] += dir * minf(step, maxf(dist - engage_r * 0.5, 0.0))
		else:
			var slot := _orbit_slot(i)
			var to_s: Vector2 = slot - _knife_pos[i]
			var d_s := to_s.length()
			if d_s > 0.5:
				_knife_pos[i] += (to_s / d_s) * minf(step, d_s)
				_knife_face[i] = to_s.angle()
			else:
				_knife_face[i] = slot.angle() + PI * 0.5
		# 活动半径硬钳（刀不离玩家超过 leash——「行动范围 250%」边界）
		if _knife_pos[i].length() > leash_radius:
			_knife_pos[i] = _knife_pos[i].normalized() * leash_radius


func _pick_chase_target(p_candidates: Array[Node2D], p_knife_world: Vector2,
		p_sticky: Node2D) -> Node2D:
	# 目标选取：粘性优先（现目标仍活且在候选内不换——防抖动）；否则取离刀最近者
	if p_sticky != null and is_instance_valid(p_sticky) and not bool(p_sticky.get("dead")) \
			and p_candidates.has(p_sticky):
		return p_sticky
	var best: Node2D = null
	var best_d := 1e9
	for cand in p_candidates:
		if cand == null or bool(cand.get("dead")):
			continue
		var d := p_knife_world.distance_to(cand.global_position)
		if d < best_d:
			best_d = d
			best = cand
	return best


func collect_engaged_strikes() -> Array[Dictionary]:
	# R65 贴身开砍点收集（OrbitWeapon 冷却就绪时消费）：
	# [{center: 世界刀位, facing: 刀→目标角}]；空表 = 刀还在路上（不消耗武器节拍）
	var out: Array[Dictionary] = []
	for i in range(orbs):
		var target: Node2D = _knife_target[i]
		if target == null or not is_instance_valid(target) or bool(target.get("dead")):
			continue
		var knife_world := _last_center + _knife_pos[i]
		var to_t: Vector2 = target.global_position - knife_world
		if to_t.length() <= engage_r + float(target.get("hitbox_r")):
			out.append({
				"center": knife_world,
				"facing": to_t.angle(),
				"index": i,
			})
	return out


func _update_orb_sprites(p_game_delta: float) -> void:
	# 球体表现推进：跟位（R65：逐刀位 _knife_pos——环绕=轨道槽/追击=追击位）+
	# 命中膨胀脉冲 + 辉光呼吸（本体 position = 轨道中心，局部零点）
	for i in range(orbs):
		if i >= _orb_cores.size():
			break
		var pos := _knife_pos[i] if i < _knife_pos.size() else _orbit_slot(i)
		var punch := float(_orb_punch[i])
		_orb_glows[i].position = pos
		_orb_cores[i].position = pos
		_orb_cores[i].rotation = angle * 3.0
		_orb_cores[i].scale = Vector2.ONE * (orb_radius / 32.0) * (1.0 + 0.38 * punch)
		_orb_glows[i].scale = Vector2.ONE * (orb_radius * 1.9 / 32.0) * (1.0 + 0.5 * punch) * knife_scale
		# R32：辉光按元素染色（_orb_tint）——附魔刀的底光跟随元素色
		# R262b M6：α 四分档量化（共享 soft_dot 键同档合批——R216 定律收口）
		var tint := _orb_tint(i)
		_orb_glows[i].modulate = Color(tint.r, tint.g, tint.b,
			ElementalFxLayer._qa(0.4 + 0.3 * punch + 0.07 * sin(angle * 3.0 + float(i) * 2.1)))
		_orb_punch[i] = maxf(punch - p_game_delta * 5.0, 0.0)
	for flash: Dictionary in _hit_flashes:
		var left := float(flash["left"])
		if left <= 0.0:
			continue
		left = maxf(left - p_game_delta, 0.0)
		flash["left"] = left
		var sp: Sprite2D = flash["sprite"]
		if left <= 0.0:
			sp.visible = false
			continue
		var t := 1.0 - left / HIT_FLASH_LIFE
		sp.scale = Vector2.ONE * lerpf(orb_radius / 19.0, orb_radius * 2.2 / 19.0, t)
		sp.modulate.a = ElementalFxLayer._qa(0.85 * (1.0 - t))   # R262b M6：α 四分档


func _fire_hit_fx(p_orb_index: int, p_orb_pos: Vector2) -> void:
	# 命中反馈：球体膨胀脉冲 + 命中点冲击小环（读得清「这球撞到东西了」）
	if p_orb_index < _orb_punch.size():
		_orb_punch[p_orb_index] = 1.0
	if _hit_flashes.is_empty():
		return
	var flash: Dictionary = _hit_flashes[_flash_idx % _hit_flashes.size()]
	_flash_idx += 1
	var sp: Sprite2D = flash["sprite"]
	sp.position = to_local(p_orb_pos)
	sp.rotation = randf() * TAU
	sp.visible = true
	flash["left"] = HIT_FLASH_LIFE


func _draw_styled_orbs() -> void:
	# R19 形态环绕体（用户点名「剑/斧头/闪电自己扩展」）：
	# sword 裂空剑 = 径向外指的渐尖刃（蓝白）/ axe 裂空斧 = 双手战斧（R34 重做：
	# 长柄+双层宽刃+配重锤头，金橙）/ bolt 雷霆 = 纯电弧（R34 重做：折线主干+
	# 分叉副枝+端点火花星，废除紫球圆点标记）。朝向/相位随公转角推进。
	for i in range(orbs):
		var pos := _orb_position(i, Vector2.ZERO)
		var phase := angle + TAU * float(i) / float(orbs)
		var dir := Vector2.from_angle(phase)              # 径向外指
		var tan := Vector2(-dir.y, dir.x)                 # 切向（运动方向）
		match style:
			&"sword":
				var tip := pos + dir * orb_radius * 1.35
				var base_c := pos - dir * orb_radius * 0.55
				var perp := tan * orb_radius * 0.30
				draw_colored_polygon(PackedVector2Array([
					tip, base_c + perp, base_c - perp]),
					Color(PopPalette.PLAYER.r, PopPalette.PLAYER.g, PopPalette.PLAYER.b, 0.95))
				draw_line(base_c - perp * 1.5, base_c + perp * 1.5,
					PopPalette.XP, 2.6, true)             # 护手
				draw_line(pos - dir * orb_radius * 0.5, pos - dir * orb_radius * 1.05,
					PopPalette.OUTLINE, 3.2, true)        # 剑柄
			&"axe":
				# R34 斧形态重做（用户反馈「斧头也太儿戏了」）：厚重双手战斧——
				# 深色长柄贯穿 + 双层宽刃（外弧金橙主刃 + 内层亮黄高光刃）+ 背部配重锤头
				var handle_a := pos - dir * orb_radius * 1.05
				var handle_b := pos + dir * orb_radius * 0.55
				draw_line(handle_a, handle_b, PopPalette.OUTLINE, 5.2, true)   # 长柄
				draw_circle(handle_a, orb_radius * 0.22,
					Color(PopPalette.XP.r, PopPalette.XP.g, PopPalette.XP.b, 0.9))  # 柄尾缠头
				# 配重锤头（柄背侧——厚重感来源）
				var back := pos - dir * orb_radius * 0.28
				draw_circle(back, orb_radius * 0.34,
					Color(PopPalette.OUTLINE.r, PopPalette.OUTLINE.g, PopPalette.OUTLINE.b, 0.95))
				# 主刃：外弧楔（金橙）
				var head_c := pos + dir * orb_radius * 0.30
				var wedge := PackedVector2Array([
					head_c + tan * orb_radius * 1.05 + dir * orb_radius * 0.30,
					head_c + tan * orb_radius * 0.62 - dir * orb_radius * 0.34,
					head_c - tan * orb_radius * 0.06 - dir * orb_radius * 0.20,
				])
				draw_colored_polygon(wedge, PopPalette.XP)
				# 高光内刃（亮黄小楔——开锋读感）
				var edge := PackedVector2Array([
					head_c + tan * orb_radius * 0.95 + dir * orb_radius * 0.26,
					head_c + tan * orb_radius * 0.55 - dir * orb_radius * 0.28,
					head_c - tan * orb_radius * 0.02 - dir * orb_radius * 0.16,
				])
				draw_colored_polygon(edge, Color(1.0, 0.92, 0.55, 0.95))
				# 刃口弧线（外缘白线——锋利轮廓）
				draw_arc(head_c + dir * orb_radius * 0.12, orb_radius * 0.95,
					phase - PI * 0.52, phase + PI * 0.30, 12,
					Color(1.0, 1.0, 1.0, 0.85), 2.6, true)
			&"bolt":
				# R34 闪电形态重做（用户反馈「闪电的紫色球怎么还在」）：紫球是 bolt
				# 画法末端的小圆点（r3.2 球心标记）——废除。现 = 纯电弧：高频颤动
				# 折线主干 + 分叉副枝 + 端点火花星（无任何球状元素）
				var flicker := 0.7 + 0.3 * sin(_anim_t * 26.0 + float(i) * 2.3)
				var col := Color(PopPalette.SHOCK.r, PopPalette.SHOCK.g,
					PopPalette.SHOCK.b, clampf(flicker, 0.0, 1.0))
				var origin := pos - dir * orb_radius * 0.9
				var joints: Array[Vector2] = [origin]
				for seg in range(4):
					var seg_dir := tan.rotated(0.9 if seg % 2 == 0 else -0.9)
					joints.append(origin + seg_dir * orb_radius * (0.5 + 0.32 * float(seg)))
				draw_polyline(PackedVector2Array(joints), col, 3.4, true)
				# 分叉副枝（中段节点 → 切向斜出短线）
				var branch_from: Vector2 = joints[2]
				draw_line(branch_from, branch_from + tan.rotated(1.5) * orb_radius * 0.5,
					Color(col.r, col.g, col.b, col.a * 0.7), 2.2, true)
				draw_line(branch_from, branch_from + tan.rotated(-1.7) * orb_radius * 0.4,
					Color(col.r, col.g, col.b, col.a * 0.6), 2.0, true)
				# 端点火花星（四向短线——放电读感，替代原球心圆点）
				var tip_j: Vector2 = joints[-1]
				for k in range(4):
					var spark_dir := Vector2.from_angle(TAU * float(k) / 4.0 + _anim_t * 6.0)
					draw_line(tip_j, tip_j + spark_dir * orb_radius * 0.26,
						Color(1.0, 1.0, 1.0, col.a), 1.8, true)
			_:
				# R243 §2.4 orb 默认 = 狼头弯刀（近战·天狼刀，替换 R32 环绕飞刀）：
				# 刀身沿运动方向（公转切向），刀根狼首护手剪影，蓝主填充 + 白獠牙高光。
				var wpos := _knife_pos[i] if i < _knife_pos.size() else _orbit_slot(i)
				var wface := _knife_face[i] if i < _knife_face.size() \
					else wpos.angle() + PI * 0.5
				# R268 V1-C：公转切向滞后 12° 廉价轮廓残影（速度风读感——60Hz 刀尖跳变
				# ≈13.8px/帧 + 零残影旧拖尾隐形 =「转得快却像瞬移」根因④；只画 body
				# 多边形 α0.22 + 藏青轮廓，跳过狼首/柄/獠牙 = 半 draw 量；降档门
				# fx_quality==0 砍残影；追击模式无公转相位不画——W9 判定零波及）
				if leash_radius <= 0.0 and ghost_gate(_fx_quality()):
					var gphase := angle + TAU * float(i) / float(orbs) \
						- deg_to_rad(GHOST_LAG_DEG)
					var gpos := Vector2.from_angle(gphase) * orbit_radius
					var gface := gpos.angle() + PI * 0.5
					var gbody := wolf_blade_poly(gpos, Vector2.from_angle(gface),
						wolf_blade_len(orb_radius, 0.0, knife_scale),
						wolf_blade_w(orb_radius, knife_scale))
					var gcol := _wolf_body_color()
					draw_polygon(gbody, PackedColorArray(
						[Color(gcol.r, gcol.g, gcol.b, GHOST_BODY_ALPHA)]))
					draw_polyline(gbody, Color(PopPalette.OUTLINE.r,
						PopPalette.OUTLINE.g, PopPalette.OUTLINE.b, 0.5), 1.4, true)
				_draw_wolf_knife(i, wpos, Vector2.from_angle(wface))


# ── R268 V1 匕首感修复：狼刀几何静态单源（qa_r268_transparent 代数断言读回口 +
#    V1-C 残影同几何复用；顶点系数逐位保持 R243 原表——V1 只动长度/宽度标量） ──

static func wolf_blade_base(p_orb_radius: float) -> float:
	# V1-A1 处方式基础长（punch/knife_scale 乘链前——设计断言带 [50,60] 的读回口）：
	# maxf(orb_r×1.05, 50) + (orb_r−16)×1.8——地板 34→50 成长穿透 + 地板外线性成长；
	# W8 L1 基础 50px → L5 基础 57.2px（连柄全长 < orbit_radius 90-120 环内不叠本体）。
	return maxf(p_orb_radius * 1.05, BLADE_LEN_FLOOR) \
		+ (p_orb_radius - 16.0) * BLADE_LEN_GROWTH


static func wolf_blade_len(p_orb_radius: float, p_punch: float, p_knife_scale: float) -> float:
	# V1-A1 全参数：基础长 × (1.05+0.22·punch) × scale——punch/knife_scale 巨刃乘链
	# 原样保持（MEC_GIANT_BLADE 通道零动；punch=0 基线 ×1.05 与旧式同基）。
	return wolf_blade_base(p_orb_radius) * (1.05 + 0.22 * p_punch) * p_knife_scale


static func wolf_blade_w(p_orb_radius: float, p_knife_scale: float) -> float:
	# V1-A2：宽地板 3.4→5.2（刀宽 9.8→15px 级、长宽比 ≈2.8:1，处方 ≤3.4:1）。
	return maxf(p_orb_radius * 0.17, BLADE_W_FLOOR) * p_knife_scale


static func wolf_blade_poly(p_pos: Vector2, p_motion: Vector2, p_blade: float,
		p_w: float) -> PackedVector2Array:
	# 弯月弧刃刀身 7 顶点（刀背外弧鼓出 +side，刃口 -side 内收，刀尖前掠）——
	# 序：0 尖 / 1 背中 / 2 背根 / 3 根前 / 4 根后 / 5 刃根 / 6 刃中。
	var side := Vector2(-p_motion.y, p_motion.x)   # 刃口法向（-side = 挥动前进侧 = 刃口）
	return PackedVector2Array([
		p_pos + p_motion * p_blade * 0.60 + side * p_blade * 0.12,
		p_pos + p_motion * p_blade * 0.34 + side * p_blade * 0.16,
		p_pos + p_motion * p_blade * 0.06 + side * p_blade * 0.15,
		p_pos - p_motion * p_blade * 0.30 + side * p_blade * 0.04,
		p_pos - p_motion * p_blade * 0.30 - side * p_blade * 0.02,
		p_pos + p_motion * p_blade * 0.06 - side * (p_w * 1.6),
		p_pos + p_motion * p_blade * 0.36 - side * (p_w * 1.2),
	])


static func ghost_gate(p_quality: int) -> bool:
	# V1-C 残影降档门（纯函数测试口）：fx_quality==0 砍残影（arc_slash.gd:512 档0
	# 残影砍半先例同族）；档 1/2 残影存在；mobile mini(q,1) 经 _fx_quality 落档 1 保留。
	return p_quality >= 1


func _draw_wolf_knife(p_index: int, p_pos: Vector2, p_motion: Vector2) -> void:
	# R243 §2.4 天狼刀（W8 默认 orb 形态重绘，替换 R32 环绕飞刀——用户点名「狼头弯刀」）：
	# 弯月弧刃刀身（PopPalette.PLAYER 蓝主填充）+ 刃口白高光 + 狼首护手剪影（双耳 +
	# 白獠牙高光）。判定半径（orb_radius）不动，视觉缩放通道 knife_scale 原样生效
	# （MEC_GIANT_BLADE——glow 底光与刀体同步缩放）；命中膨胀/白闪脉冲沿袭 R32 口径。
	# 元素染色（_orb_tint → blend_element_color）走刀脊辉光线与 glow 底光（R26 通道保持）。
	# R243 §7.2 苍狼啸月（质变）：狼头刀银白化——PopPalette 白银梯度（PLAYER→WHITE
	# 0.72）+ 月牙高光短弧（金白）；_wolf_body_color 单源取色，重绘流（每 tick
	# _request_redraw）质变置位下一帧自动切换，零额外接线。
	var motion := p_motion
	var side := Vector2(-motion.y, motion.x)      # 刃口法向（-side = 挥动前进侧 = 刃口）
	var punch := float(_orb_punch[p_index]) if p_index < _orb_punch.size() else 0.0
	# R268 V1-A1/A2：刀参数改静态单源（wolf_blade_len/wolf_blade_w——地板 34→50 成长
	# 穿透 + 宽 3.4→5.2；punch/knife_scale 乘链保持）
	var blade := wolf_blade_len(orb_radius, punch, knife_scale)
	var w := wolf_blade_w(orb_radius, knife_scale)
	# ── 弯月弧刃刀身（顶点表静态单源 wolf_blade_poly——本体与 V1-C 残影同几何）──
	var body := wolf_blade_poly(p_pos, motion, blade, w)
	var tip: Vector2 = body[0]
	var spine_mid: Vector2 = body[1]
	var spine_root: Vector2 = body[2]
	var root_fwd: Vector2 = body[3]
	var root_back: Vector2 = body[4]
	var edge_root: Vector2 = body[5]
	var edge_mid: Vector2 = body[6]
	var blue := _wolf_body_color()
	# R267 视觉刀 §2.4：W8 刀身三层化（壳/核/缘）+ 降档——元素染色路径（水晶配方，
	# crystal_cols static 缓存直出零新建 §2.6-g；壳层顶点逐刀动态经 expand_poly 内联
	# 外扩——§2.2「现顶点绕质心外扩」）；KIN/空池蓝身薄荷线豁免路径逐位不动（§2.2）。
	var tint := _orb_tint(p_index)
	if _crystal_active():
		var q := _fx_quality()
		if q >= 2:
			var shell_cols := CrystalBladeFactory.crystal_cols(&"wolf", tint,
				_holder_transcended(), q, CrystalBladeFactory.LAYER_SHELL)
			if not shell_cols.is_empty():
				draw_polygon(CrystalBladeFactory.expand_poly(body,
					CrystalBladeFactory.SHELL_EXPAND), shell_cols)
		draw_polygon(body, CrystalBladeFactory.crystal_cols(&"wolf", tint,
			_holder_transcended(), q, CrystalBladeFactory.LAYER_BODY))
		# 修轮①评审：全轮廓描边（原路径本有浅轮廓线，水晶分支拆 darkened 剪影后
		# 淡元素刀身在亮底近隐形——补 OUTLINE 轮廓，与烘焙态/挥斩体口径对齐）
		draw_polyline(body, CrystalBladeFactory.crystal_outline_color(), 1.6, true)
		# R268 V1-D：白on白修正——白刃缘改元素色提亮 0.55（fill.lightened 处方：
		# palette.gd BG=#eef3ff 对纯白亮度差 ≈5% 全隐形=匕首感根因③白位；ALPHA_EDGE
		# α 与 crystal_cols 层3 共享表零触——b-2/b-5 钉值零波及；上一条语句=全轮廓
		# 描边线（crystal_outline_color）为 §3.2 硬边①明文冻结线未触——R268 评审修
		# nit①：按语句内容指称不按行号（本批 hunk 插行后设计文档旧锚 :954 已漂移）；
		# plain 臂白高光/白獠牙本批不动）
		var edge_col := tint.lightened(0.55)
		edge_col.a = CrystalBladeFactory.ALPHA_EDGE
		draw_polyline(PackedVector2Array([tip, edge_mid, edge_root]), edge_col, 2.2, true)
	else:
		draw_colored_polygon(body, Color(blue.r, blue.g, blue.b, 0.95))
		# 刀体轮廓描边（深底压剪影——R61 弧斩同款手法）
		draw_polyline(body, Color(0.86, 0.93, 1.0, 0.85), 1.6, true)
		# 刃口白高光（-Y/-side 侧：tip → 刃中 → 刃根）
		draw_polyline(PackedVector2Array([tip, edge_mid, edge_root]),
			Color(1.0, 1.0, 1.0, 0.92), 2.2, true)
	# R243 §7.2 苍狼啸月月牙高光：刃身中段金白短弧（横跨刃面的弯月读感）
	if _holder_transcended():
		var mid := p_pos + motion * blade * 0.30 - side * blade * 0.02
		var ma := motion.angle()
		draw_arc(mid, blade * 0.30, ma - 1.15, ma + 1.15, 10,
			Color(1.0, 0.97, 0.84, 0.8), 2.0, true)
	# 刀脊元素辉光线（_orb_tint 混色源；未附魔 = 薄荷绿——R192 单源口径保持；
	# tint 取值已上移至刀身分支前——水晶/原路径共用同源取色）
	draw_polyline(PackedVector2Array([root_fwd, spine_root, spine_mid, tip]),
		Color(tint.r, tint.g, tint.b, 0.9), 2.0, true)
	# ── 狼首护手剪影（刀根护手位：吻部朝刃向，双耳后掠，白獠牙高光）──
	var head := p_pos - motion * blade * 0.40
	var dark := blue.lerp(PopPalette.OUTLINE, 0.38)
	var snout := head + motion * blade * 0.17
	var jaw_l := head - motion * blade * 0.05 + side * blade * 0.095
	var jaw_r := head - motion * blade * 0.05 - side * blade * 0.095
	var neck := head - motion * blade * 0.15
	draw_colored_polygon(PackedVector2Array([snout, jaw_l, neck, jaw_r]),
		Color(dark.r, dark.g, dark.b, 0.96))
	# 双耳（后掠小三角——狼首剪影辨识位）
	for ear_side: float in [1.0, -1.0]:
		var ear_base := head - motion * blade * 0.03 + side * blade * 0.08 * ear_side
		var ear_tip := head - motion * blade * 0.13 + side * blade * 0.17 * ear_side
		var ear_back := head - motion * blade * 0.11 + side * blade * 0.05 * ear_side
		draw_colored_polygon(PackedVector2Array([ear_base, ear_tip, ear_back]),
			Color(dark.r, dark.g, dark.b, 0.96))
	# 白獠牙高光（吻部下侧两枚前指小三角）
	for fang_side: float in [1.0, -1.0]:
		var fang_base := snout - motion * blade * 0.055 + side * blade * 0.045 * fang_side
		var fang_tip := fang_base + motion * blade * 0.075 + side * blade * 0.012 * fang_side
		var fang_hind := fang_base - motion * blade * 0.035
		draw_colored_polygon(PackedVector2Array([fang_base, fang_tip, fang_hind]),
			Color(1.0, 1.0, 1.0, 0.95))
	# 刀柄（狼首后方短柄 + 缠头）
	draw_line(head, p_pos - motion * blade * 0.66, PopPalette.OUTLINE,
		3.4 * knife_scale, true)
	# 命中白闪（双刃边线，脉冲驱动——R32 反馈通道保持）
	if punch > 0.01:
		var flash := Color(1.0, 1.0, 1.0, punch)
		var fl := 1.6 + 1.4 * punch
		draw_line(tip, root_back + side * w * 1.3, flash, fl, true)
		draw_line(tip, root_back - side * w * 1.3, flash, fl, true)


func _wolf_body_color() -> Color:
	# R243 §7.2 苍狼啸月刀身取色单源（测试读回口）：默认 = PopPalette.PLAYER 蓝；
	# 质变 = 白银梯度（PLAYER→WHITE 0.72——L=-1.0 归一 White 距离读感）。狼首/描线
	# 色自本色派生（_draw_wolf_knife 内 blue.lerp/OUTLINE 链不变）。
	# R267 视觉刀：本口为 KIN/身份路径专用（水晶路径不消费——§2.2 豁免路径取色单源）。
	if _holder_transcended():
		return PopPalette.PLAYER.lerp(Color.WHITE, 0.72)
	return PopPalette.PLAYER


func _crystal_active() -> bool:
	# R267 视觉刀：W8 水晶路径激活判（dominant 非 KIN——与 _orb_tint 取色源同条件
	# §2.3；KIN/空池蓝身薄荷线 = 豁免路径零改动 §2.2 评审⑦）。
	return weapon != null and is_instance_valid(weapon) \
		and weapon.dominant_element() != GameConst.Element.KIN


func _fx_quality() -> int:
	# R267 视觉刀：特效质量档（arc_slash._fx_quality 同式镜像——钳 [0,2] + mobile
	# 降 1 档；Meta 单一真源）。水晶路径降档矩阵（§2.5-4）的档位读口。
	var q := clampi(int(Meta.settings("fx_quality")), 0, 2)
	if OS.has_feature("mobile"):
		q = mini(q, 1)
	return q


func _holder_transcended() -> bool:
	# 宿主质变态位（w4 WeaponBase.transcended——typed 字段直读；结算宿主注入前=false）
	return weapon != null and is_instance_valid(weapon) and weapon.transcended


# ── R243 §7.2 W8 苍狼啸月图标（texture_factory <id>_t2 委托位——static func） ────
# 共享工厂 weapon_icon_t2 缓存键机制（w1 已备）；委托注册（_delegate_weapon_icon
# paths 增 "W8_orbit_field" → 本脚本）属共享文件改动，已在任务产出说明登记。
# 默认 = 蓝狼头弯刀；质变 = 银白化（白银梯度）+ 月牙高光。贴图生成本脚本内自持
#（不动共享 TextureFactory；栅格内核只读复用其 static 光栅化口；本脚本 static 缓存）。

static var _icon_cache: Dictionary = {}    # 图标本地缓存（键 base/t2——勿写共享 _cache）

const ICON_SILVER_MIX := 0.72              # 白银梯度混合档（与 _wolf_body_color 同值单源语义）


static func weapon_icon_tex(p_transcended: bool) -> ImageTexture:
	# R243 W8 图标（56px 画布朝上 -Y）：弯月刀身 + 狼首护手剪影 + 獠牙高光；
	# 质变 = 银白刀身 + 金白月牙高光。
	var key := "t2" if p_transcended else "base"
	if _icon_cache.has(key):
		return _icon_cache[key]
	var tex: ImageTexture = TextureFactory._render(56, 56,
		TextureFactory._shade(_icon_layers(p_transcended)))
	_icon_cache[key] = tex
	return tex


static func _icon_layers(p_transcended: bool) -> Array:
	# 图层集（TextureFactory._shade 契约同 ground_axe_weapon._icon_layers）。
	var blue := PopPalette.PLAYER
	var body := blue
	if p_transcended:
		body = blue.lerp(Color.WHITE, ICON_SILVER_MIX)      # 苍狼啸月银白化
	var dark := body.lerp(PopPalette.OUTLINE, 0.38)
	var crescent := Color(1.0, 0.97, 0.84) if p_transcended else Color(1, 1, 1, 0)
	# 弯月弧刃刀身（外弧刀背 + 内收刃口，尖朝上 -Y）
	var blade := PackedVector2Array([
		Vector2(0.0, -22.0), Vector2(6.5, -16.0), Vector2(9.0, -7.0),
		Vector2(7.5, 2.0), Vector2(3.0, 6.0), Vector2(-1.5, 2.5),
		Vector2(-3.0, -7.0), Vector2(-2.0, -15.0),
	])
	var layers: Array = [
		# R267 视觉刀：水晶外壳层（身份蓝未钳——图标非元素染色路径；c′ 防混搭特征层）
		{"sd": TextureFactory._poly_sd(CrystalBladeFactory.expand_poly(blade,
			CrystalBladeFactory.ICON_SHELL_EXPAND)),
			"fill": CrystalBladeFactory.icon_shell_color(body), "ow": 0.0},
		{"sd": TextureFactory._poly_sd(blade), "fill": body, "ow": 2.4},
		# 刃口白高光（-X 侧内收线）
		{"sd": TextureFactory._poly_sd(PackedVector2Array([
			Vector2(6.0, -14.0), Vector2(7.2, -6.0), Vector2(4.5, 2.5),
			Vector2(2.6, 1.5), Vector2(4.6, -6.5), Vector2(3.6, -13.0),
		])), "fill": Color(1.0, 1.0, 1.0, 0.9), "ow": 0.0},
		# 狼首护手剪影（吻部朝上 + 双耳）
		{"sd": TextureFactory._poly_sd(PackedVector2Array([
			Vector2(0.0, 8.0), Vector2(4.5, 10.5), Vector2(3.0, 15.0), Vector2(-3.0, 15.0),
			Vector2(-4.5, 10.5),
		])), "fill": dark, "ow": 2.2},
		{"sd": TextureFactory._poly_sd(PackedVector2Array([
			Vector2(-4.5, 11.0), Vector2(-7.0, 7.5), Vector2(-3.5, 8.5),
		])), "fill": dark, "ow": 1.6},
		{"sd": TextureFactory._poly_sd(PackedVector2Array([
			Vector2(4.5, 11.0), Vector2(7.0, 7.5), Vector2(3.5, 8.5),
		])), "fill": dark, "ow": 1.6},
		# 刀柄
		{"sd": TextureFactory._box_at(Vector2(0.0, 20.0), Vector2(1.7, 4.4), 1.0),
			"fill": dark, "ow": 2.0},
	]
	if p_transcended:
		# 月牙高光（金白短弧贴刃面——弧月读感；SDF 细弧月牙多边形近似）
		layers.append({"sd": TextureFactory._poly_sd(PackedVector2Array([
			Vector2(-5.5, -12.0), Vector2(-7.5, -5.0), Vector2(-6.0, 1.0),
			Vector2(-4.4, 0.0), Vector2(-5.6, -5.0), Vector2(-3.8, -11.0),
		])), "fill": crescent, "ow": 0.0})
	CrystalBladeFactory.note_icon_built(&"W8_orbit_field")   # R267 c′ 机制标记
	return layers


func _orb_tint(_p_index: int) -> Color:
	# R26 元素附魔染色（无 ELE 卡 = 默认薄荷绿）。R186 拆除声明：按球定元素（_orb_element
	# 稳定映射）随附着三件套一并删除——染色为纯视觉读数、零附着语义。
	# R243 §6.5：取色源换 weapon.blend_element_color()（元素池非 KIN 色 RGB 均值——
	# 多元素混色读感）；KIN 兜底 PopPalette.SUCCESS 保留。pre-w3 单元素武器
	# blend = 该元素色本身 → 与旧 dominant_element() 逐位同色（零位移）。
	if weapon != null and is_instance_valid(weapon) \
			and weapon.dominant_element() != GameConst.Element.KIN:
		return weapon.blend_element_color()
	return PopPalette.SUCCESS


func _reset_state() -> void:
	# 清零契约（武器回收期）
	angle = 0.0
	_gain_cd.clear()
	_blade_hits.clear()
	charged_hits = 0
	detonation_count = 0


func _draw() -> void:
	# R271 P4：绘µs wrap（自绘件 _draw 计时入 &"draw" 桶——只加计不改行为；
	# 原体迁 _draw_r271，早退 return 由委托面兜底不漏收口）
	DebugStats.bucket_begin(&"draw")
	_draw_r271()
	DebugStats.bucket_end(&"draw")


func _draw_r271() -> void:
	# 力场本体渲染：淡薄荷填充 + 虚线轨道环 + 公转扫掠残辉（占位圆已废——用户反馈）
	# + 底部数值标注（用户反馈二轮「下面还要有具体的值」：环绕数 / 单击伤害 / 蓄能档）
	# R65 追击模式：环示 = 活动范围（leash_radius，更淡——「刀能跑多远」）；
	# 环绕模式口径不变（轨道环 = orbit_radius）
	if not visible:
		return
	var mint := PopPalette.SUCCESS
	var ring_r := orbit_radius
	var ring_a_faint := 0.07
	if leash_radius > 0.0:
		ring_r = leash_radius
		ring_a_faint = 0.045
	draw_circle(Vector2.ZERO, ring_r, Color(mint.r, mint.g, mint.b, ring_a_faint))
	var pulse := 0.5 + 0.5 * sin(angle * 2.0)
	draw_arc(Vector2.ZERO, ring_r, 0.0, TAU, 64,
		Color(mint.r, mint.g, mint.b, 0.05 + 0.04 * pulse), orbit_radius * 0.10, true)
	var seg_arc := TAU / float(PATH_DASHES)
	for i in range(PATH_DASHES):
		if i % 2 == 0:
			continue                            # 奇数段绘制 = 虚线
		var a0 := float(i) * seg_arc
		draw_arc(Vector2.ZERO, ring_r, a0, a0 + seg_arc, 5,
			Color(mint.r, mint.g, mint.b, 0.38), 2.4, true)
	# 扫掠残辉：R268 V1-B——固定薄荷单段改逐刀 42° 元素色渐隐弧（白底薄荷 α0.18
	# ≈不可见=「瞬移」根因③；α 0.30=R262b 四分档取档、宽 orb_r×2.2、色走 _orb_tint；
	# 刀数 ≤6 时逐刀弧互不叠带（间距 ≥60° > 弧跨 42°），更密刀位回落单段减淡防糊——
	# draw_arc 增量 ≤5（最小档）；追击模式无公转带——不画。
	# R268 评审修①④(a)：档位门——fx_quality==0 回落单段（1 draw_arc=改前同量，
	# 最弱机/渲ms 满帽机不加逐刀未降档增量），档 1/2 逐刀弧；门复用 ghost_gate
	# 同族语义（与 V1-C 残影门同判据，arc_slash.gd:512 档0 砍半先例同源））
	if leash_radius <= 0.0:
		var trail_span := deg_to_rad(TRAIL_SPAN_DEG)
		var tcol := _orb_tint(0)
		if orbs >= 1 and orbs <= 6 and ghost_gate(_fx_quality()):
			for bi in range(orbs):
				var b_phase := angle + TAU * float(bi) / float(orbs)
				draw_arc(Vector2.ZERO, orbit_radius, b_phase - trail_span, b_phase, 12,
					Color(tcol.r, tcol.g, tcol.b, TRAIL_ALPHA),
					orb_radius * TRAIL_WIDTH_N, true)
		else:
			draw_arc(Vector2.ZERO, orbit_radius, angle - trail_span, angle, 12,
				Color(tcol.r, tcol.g, tcol.b, TRAIL_ALPHA * 0.6),
				orb_radius * TRAIL_WIDTH_N, true)
	# R19 形态绘制（sword 剑 / axe 斧 / bolt 闪电——程序化多边形，贴图零实例化）
	# R243 §2.4：默认 orb = 狼头弯刀（_draw_styled_orbs 缺省分支，替换 R32 环绕飞刀）
	_draw_styled_orbs()
	# 数值标注（力场下缘：环绕 ×N · 单击伤害 · 满档引爆当量；半透明贴纸风小字）。
	# R188 档0：build_panel_snapshot 每 12 次重绘刷一次（原每次重绘全量重建面板快照）
	_label_ctr += 1
	if _label_atk_text.is_empty() or _label_ctr % 12 == 0:
		var atk := 0.0
		if weapon != null and is_instance_valid(weapon):
			atk = float(weapon.build_panel_snapshot().get("base_atk", 0.0))
		# 二dc QA BUG-2（R243 遗留）：追击分支 2 占位吃 4 实参 →「not all arguments
		# converted」逐帧报错 + 标注永不显示——分支各自格式化
		if leash_radius > 0.0:
			_label_atk_text = "追击 ×%d · %.0f/斩" % [orbs, atk]
		else:
			_label_atk_text = "环绕 ×%d · %.0f/击 · 引爆 %d×@%d" % [orbs, atk,
				int(round(detonate_mult)), int(round(detonate_radius))]
	var font := ThemeDB.fallback_font
	draw_string(font, Vector2(-60.0, orbit_radius + 22.0), _label_atk_text,
		HORIZONTAL_ALIGNMENT_CENTER, 160.0, 13, Color(mint.r, mint.g, mint.b, 0.85))
	# §2.5.10 蓄能档位读数（表现验收项，非打磨项）：已蓄能目标头顶「蓄能 x/5」小字——
	# 亮度随档位爬升、满档亮红（即将引爆）；W8 环绕模式专属（W9 追击无蓄能语义不画）。
	# R188 档0：网格查询 60Hz→15Hz（每 4 次重绘重建缓存，非查询帧画缓存——读数连续不闪）
	if leash_radius <= 0.0 and weapon != null and is_instance_valid(weapon) \
			and weapon.enemy_grid != null:
		if _label_ctr % 4 == 1 or _label_cache.is_empty():
			_label_cache.clear()
			var reach := orbit_radius + orb_radius
			for t in weapon.enemy_grid.query_circle(_last_center, reach):
				if t == null or bool(t.get("dead")):
					continue
				var ch := charge_of(t)
				if ch <= 0:
					continue
				var hr: Variant = t.get("hitbox_r")
				var lp := to_local((t as Node2D).global_position) \
					+ Vector2(-34.0, (-float(hr) if hr != null else -12.0) - 10.0)
				var full := ch >= int(round(charge_max))
				var col := Color(1.0, 0.42, 0.36, 0.95) if full \
					else Color(mint.r, mint.g, mint.b, 0.5 + 0.42 * float(ch) / maxf(charge_max, 1.0))
				_label_cache.append({
					"lp": lp,
					"text": "蓄能 %d/%d" % [ch, int(round(charge_max))],
					"col": col,
				})
		for entry in _label_cache:
			draw_string(font, entry["lp"], entry["text"],
				HORIZONTAL_ALIGNMENT_CENTER, 68.0, 11, entry["col"])

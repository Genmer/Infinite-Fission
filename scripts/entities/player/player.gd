# scripts/entities/player/player.gd
# M-02 Player（架构 §2.12）：Area2D 命中盒（低频，Q-15 例外通道）。
# R220 刀10：磁吸拾取区 Area2D 摘除（零信号零 overlap 消费者——磁吸/拾取全走
# XpShard.tick 距离判定读 pickup_radius，pickup.gd:184/:299-302 口径不变）；
# 物理 space 缩容 ~161 个无消费者 area（player._pickup_area 1 + 每碎片根 160）。
# 操作：相对拖动（Q-3）——_unhandled_input 采样拖动向量，tick 应用 + 活动区钳制（下 40% 屏，E-15）。
# 受击：简化路径（Q-16）——无敌帧 contact_tick=0.6s 判定 → 直接扣 HP → 事件，不入 M-12。
# 编排说明（§2.17）：tick(game_delta, move_delta) 由 GameLoop ② 驱动；
# move_delta 非零 = GameLoop 显式投递（E-15 输入采样）；零向量 = 玩家消费自身 _unhandled_input 采样。
class_name Player
extends Area2D

# R293 模拟刀 B：② 相位括号助手按路径引用（headless -s 不重扫类缓存——裸新
# class_name 不可解析；Player 非 WeaponBase 子类，独立声明一份）。
const SimQueryShare = preload("res://scripts/combat/weapon/sim_query_share.gd")

# ── R246 击杀快照账本（static：脚本加载期抢订 enemy_killed，派发位早于 Boot 全部订阅） ──
# 动机（「连接序 = 派发序」纪律，game_loop.gd _boot_build_actors ★注先例）：玩家节点在
# Boot 序中晚于 EnemySpawner 入树（spawner :2440 / player :2451），实例侧 enemy_killed
# 订阅的派发位恒在 spawner 死亡归还之后——尸身 tags 被 _reset_state 置 0、elemental 置
# null，玩家侧 zero（死亡瞬间仍凝滞判定）/fission（普/精/Boss 分档）会恒读空值。本账本
# 在脚本加载期（main 场景实例化链，autoload 已就绪）以 lambda 抢订，派发位先于 spawner
# ——归还前落 tags/freeze 快照；玩家处理器经 _kill_snap 读账本，账本 miss 回退尸身直读
# （直接调用/无派发路径，此时尸身未清）。环形 64 条防长局膨胀（同帧消费，帽宽裕）。
static var _kill_ledger: Dictionary = {}       # uid -> {tags:int, freeze:float}
static var _kill_ledger_fifo: Array[int] = []  # 落账 FIFO（环形淘汰序）
static var _kill_ledger_fn: Callable = Callable()


static func _static_init() -> void:
	_kill_ledger_fn = func(p_enemy: Node2D) -> void:
		var uid_v: Variant = p_enemy.get("uid")
		if uid_v == null:
			return                           # 非敌节点（探针 stub）——无 uid 不落账
		var freeze := 0.0
		var st: Variant = p_enemy.get("elemental")
		if st is ElementalState:
			freeze = (st as ElementalState).freeze_timer
		var uid := int(uid_v)
		# R253（QA BUG-2 修复暴露）：GAME_OVER 清场期敌已归还（release 清 tags）后延迟
		# kill 信号再入——int(null) 炸断 choose 收口链（merged 残留）；已归还敌不入账
		var tags_v: Variant = p_enemy.get("tags")
		if tags_v == null:
			return
		_kill_ledger[uid] = {"tags": int(tags_v), "freeze": freeze}
		_kill_ledger_fifo.append(uid)
		if _kill_ledger_fifo.size() > 64:
			_kill_ledger.erase(_kill_ledger_fifo.pop_front())
	EventBus.enemy_killed.connect(_kill_ledger_fn)


static func _kill_snap(p_enemy: Node2D) -> Dictionary:
	# 死亡瞬间快照统一读口：账本（EventBus 派发路径——先于 spawner 归还落账）优先，
	# miss（直接调用/账本环淘汰/无 uid 探针）回退尸身直读（此路径尸身尚未被归还清零）
	var uid_v: Variant = p_enemy.get("uid")
	if uid_v != null:
		var snap: Variant = _kill_ledger.get(int(uid_v))
		if snap is Dictionary:
			return snap
	var freeze_fb := 0.0
	var st_fb: Variant = p_enemy.get("elemental")
	if st_fb is ElementalState:
		freeze_fb = (st_fb as ElementalState).freeze_timer
	var tags_v: Variant = p_enemy.get("tags")
	return {"tags": int(tags_v) if tags_v != null else 0, "freeze": freeze_fb}


# 初始 HP 真源 = cfg player_base_hp=60（用户实测反馈 2026-08-29 裁定回注，原 100 被围
# 数分钟不死无张力；贴脸 4.5s 死、E1 一次磨血 16.7%、E4 爆炸 33%、Boss 接触 33~58%
# ——「杂兵磨血、精英/Boss 杀人」梯度成立，且 REL_HARVEST 0.4% 回血不致被满血钳死）。
var max_hp: float = 60.0                       # 声明值与 cfg 同口径（_ready 覆读 cfg 真源）
var hp: float = 60.0
var move_speed: float = 280.0                 # 移速（相对拖动 1:1 口径下的调试/键盘备用参数）
var pickup_radius: float = 120.0
var gold: int = 0                             # 金币（击杀 gold_drop 掉账；战地黑市货币，M7）
var _difficulty: int = 0                      # R73 难度档镜像（GameLoop 开局注入；经验乘区源）
var reroll_charges: int = 2                   # 选卡刷新次数（换一批；开局 2 + 局外养成，2026-08-31 用户反馈）
var _last_move_dir: Vector2 = Vector2.UP      # 最近移动方向（游侠闪现取向）
var revives_left: int = 0                     # 应急协议剩余复活（局外养成，每局重置）
var map_xp_mult: float = 1.0                  # 地图词缀·经验倍率（GameLoop.start_run 注入）              # Q-13 磁吸半径（pickup_pct 词条加成属包 3 常驻词条）
var map_gold_mult: float = 1.0                # 地图祝福·金币倍率（GameLoop 金币掉账消费；词缀二期）
var hazard_slow_left: float = 0.0             # 冰锁圈外部减速剩余 s（R18 P2 frost flavor）
var hazard_slow_mult: float = 1.0             # 拖动映射系数（0.65 = 减速 35%，到期还原 1.0）
var map_rof_mult: float = 1.0                 # 地图祝福·射速倍率（WeaponBase._fire_interval 消费；词缀二期）
var map_wave_heal_pct: float = 0.0            # 地图祝福·每波回血比 max_hp（GameLoop wave_cleared 消费；词缀二期）
# 角色系统（用户反馈「不同的角色有不同的技能」）：选择经 Meta 持久化，开局 set_character 应用
var character_id: StringName = &"sentinel"
var character_atk_pct: float = 0.0            # 角色攻击修正（武器面板经 meta_atk_pct 合成）
var run_fallback_atk_pct: float = 0.0         # R262d 局内应急强化累计（全武器攻击加算，
                                              # 经 meta_atk_pct 三注入点合成；set_character
                                              # 复位区清零——继续局回填在 weapons 重建前）
var rof_mult: float = 1.0                     # 过载咆哮射速倍率（WeaponBase._fire_interval 消费）
var comp_rof_mult: float = 1.0                # 无技能角色 CDR 折算·全武器射速乘区（改造者·枢契约；refresh_skill_cd 真源，有技能角色恒 1.0）
var skill_cd_relic_mult := 1.0                   # R80 遗物技能冷却乘区（时之沙 ×0.8；refresh 常驻消费）
var skill_cd_base: float = 30.0
var skill_cd_left: float = 0.0
var skill_active_left: float = 0.0            # 增益型技能剩余时长（过载）
var _skill_shield_left: float = 0.0           # 紧急护盾剩余（表现走护盾泡）
var _skill_fx_left: float = 0.0               # 技能演出剩余 s（R19：HUD 时长条 + 玩家光环）
var _skill_fx_max: float = 0.0                # 演出总长（ratio 分母）
# ── R246 技能升华（真源 docs/design/sublime/*.md；卡系统唯一授予口 enable_sublime()，
#    幂等；set_character 复位区清 false——继续局回填在 set_character 之后执行天然不冲突）──
var skill_sublime: bool = false               # 升华位（HUD 红描边统一读口 player.get("skill_sublime")）
var _sub_field_left := 0.0                    # sentinel·绝对屏障：力场权威计时（>0 = 无敌来自升华技能）
var _sub_field_tick_left := 0.0               # 相位反冲节拍（0.5s 一跳）
var _sub_absorb_gate_left := 0.0              # 吸收计数节流闸（0.5s 计 1 次）
var _sub_absorb_reduced := 0.0                # 本施放已回充 CD 量（帽 20s）
var _overload_ramp_t := 0.0                   # veles·临界过载：爬坡累计时间
var _heat_stacks := 0                         # veles 余热层（窗口内击杀积累，到期逐层冷却）
var _heat_drop_left := 0.0                    # veles 距下一次掉层剩余
var _stomp_aftershock_pulses := 0             # bulwark·余震壁垒：剩余余震跳数（0=无窗）
var _stomp_aftershock_left := 0.0             # 距下一跳余震倒计时
var _stomp_barrier := 0.0                     # 磐岩护壁剩余吸收量（帽 48；纯会话态零存档）
var _shadow_fuses: Array[Dictionary] = []     # ranger·百影穿袭：待爆残影 {pos, left}
var _lurk_stacks := 0                         # ranger 潜影层（12s/层 帽 4；受击清零、施放消耗）
var _lurk_timer := 0.0                        # ranger 蓄层计时
var _ts_left := 0.0                           # zero·时滞奇点：窗口剩余（玩家侧唯一真值）
var _ts_bonus := 0.0                          # zero 击杀延展已积攒量（封顶账本）
var _ts_pulse_left := 0.0                     # zero 距下一次力场按压剩余
var _mank_essence := 0                        # mank·万毒噬界：腐化精华层（帽 30；会话态）
var _blast_uid_seq := 0                       # mank 腐沼爆裂合成 UID 轮内序号
var _echo_stacks := 0                         # echo·无尽回响：回声层（仅主窗内叠）
var _echo_afterglow_left := 0.0               # echo 渐弱余韵剩余
var _echo_chord_homo := false                 # echo 双生和弦快照（true=同频共振）
var _resonance_stacks := 0                    # noah·万械共鸣：共鸣层（帽 40；跨施放保留）
var _resonance_time_bonus := 0.0              # noah 当窗已兑延时 s
var _summon_meta_base: Array[float] = []      # noah 副本 meta_atk_pct 基准快照（防重复叠加）
var _reson_layers := 0                        # fission·本命同调：同调层 0..500
var _reson_kill_count := 0                    # fission 追溯回填原始击杀计数（run 作用域；set_character 清零）
var _dr_window_left := 0.0                    # medic·医疗矩阵：减伤窗剩余（×0.5，与无敌独立）
var _vortex_left := 0.0                       # vortex·奇点：窗口剩余
var _vortex_tick_count := 0                   # vortex 降频计数（每 2 物理帧一拉）
var _reaper_left := 0.0                       # reaper·收割窗：伤害窗剩余
# 毒云领域（毒系学者·薇拉，P2 数值真源）：以玩家为中心 300px、持续 6s；每 0.5s 对域内敌
# 结算 8% 主武器 ATK 毒伤 + 减速 20%。直结算通道（不动管线/不挂元素状态——走 AOE_SECONDARY
# 幂等键，同构 mank 毒沼绽放先例；减速走 Enemy.ext_slow 外部乘区，与元素冰缓正交）
var _poison_cloud_left: float = 0.0           # 毒云剩余（game_delta 通道）
var _poison_cloud_tick_left: float = 0.0      # 下一跳倒计时
var _poison_stack_table: Dictionary = {}      # R246 vera·毒理学终章：uid→{"e":敌, "layers":int}
var _poison_catalysis_pending := false        # R246 催化解离错帧挂起（tick 顶部下一帧执行）
# 召唤僚机（召唤师·诺亚，R183 用户重定义数值真源）：随机复制 2 把当前已装备武器
#（同数据/同等级/词条栈全量拷贝——含逐层品级数值），持续 10s 到期回收；
# 两架护航舰（R93 视觉）随行 + 复制武器进悬浮环金色染色参战。副本不占真实槽位
#（独立 _summon_copies 数组——选卡目标/存档序列化/词条叠层判据均不受污染）
var _summon_left: float = 0.0                 # 僚机剩余（game_delta 通道）
var _summon_drones: Array[Node2D] = []        # R93 护航舰（编队侧翼跟随的视觉件）
var _summon_copies: Array[WeaponBase] = []    # R183 复制武器（tick 驱动 + 悬浮环展示）
# R187 W5 万镜回廊：镜面独立数组（永久会话态——不占武器槽、永不进 _summon_copies、
# 不随 _reset_skill_temp_state 清空；读档/波首按武器槽序+固定哈希确定性重推导指向，
# 存档层冻结零新增键）。实体类（MirrorImage）归棱镜组 mirror_image.gd——本侧按
# WeaponBase 鸭子协议驱动（tick/refresh_fire_interval/is_instance_valid 三守卫）。
var _mirror_images: Array = []
var _mirror_locked: bool = false              # MEC_MIRROR_LOCK 挂载态（挂卡后波首不重掷——确定性出口兜底）
var invuln_left: float = 0.0                  # 受击无敌帧（contact_tick=0.6s 口径）
var _graze_fb_left: float = 0.0               # c4① graze 反馈节流剩余 s（0.25s；float 成员零分配——R188 纪律）
var dr_left: float = 0.0                      # R192 结晶晶盾减伤剩余 s（crystal_shield_request 唯一消费；纯会话态零存档）
var relic_dr: float = 0.0                     # R253 防御向遗物减伤（relic_handler._maintain_relic_dr 每帧写——末路壁垒/守护本能/壁垒契约；与晶盾 dr 乘法复合独立闸）
var dr_value: float = 0.0                     # 当前减伤比例（0.15 = −15%；刷新不叠加，到期归零）
var _revive_protect_left: float = 0.0         # 复活保护青弧剩余 s（E2 r2；只由 _try_revive 置位，respawn/restore 显式清零）
var _revive_protect_max: float = 0.0          # 青弧总长（ratio 分母；演出态不入快照——continue 局由 restore 清零）
var weapon_slots: Array[WeaponBase] = []      # ≤7（集成包 B.8 第二批收紧：pkg2 用例已迁移 WeaponBase 真件）
var orbit_avatars: WeaponOrbitAvatars = null  # 武器悬浮层（R25：发射口对齐化身）
var unlocked_slots: int = 2                   # 开局 = 难度默认 2/3/3；w7→3 / Boss1→4 / Boss2 或 w21→5 / Boss3 或 w31→6（R183）
var slot_bonus: int = 0                       # R185 金卡解锁计数（帽内提前解锁数，不抬高有效帽）
var level: int = 1
var xp: float = 0.0
var xp_need: float = 14.0                     # 14 × lv^1.4
var level_burst_last: int = 0                 # R188 档3 遥测：最近一次 gain_xp 连升级数（连升探针观测口）
var level_burst_max: int = 0                  # R188 档3 遥测：历史最大单次连升级数
var hitbox_radius: float = 16.0               # 命中盒半径（敌弹距离判定口径）
# 二cv#6 贴脸豁免圈：已装备 MELEE 形态武器中最大的 effective_slash_radius（玩家中心
# 刃圈半径，与二cv#2 近战范围虚线同值同源）。逐帧在 tick 武器循环内折算（升级/换卡/
# 出售/超凡时机全自动覆盖）；无近战武器恒 0 → 敌侧守卫恒假=纯远程构筑威胁模型零扰动。
var melee_sanctuary_r: float = 0.0

var _dead: bool = false
# R233 T6（决策3.1 插值层）：渲染插值双缓冲——global_position 定性为「显示缓存」，模拟
# 真位以 _ip_curr 为准（game_loop 恢复/快照遍历维护时序；帧末快照把步内瞬移/击退统一
# 收编）。玩家持久非池化：_ready 置位 prev=curr=初始位，此后快照遍历全程续拍。
var _ip_prev: Vector2 = Vector2.ZERO
var _ip_curr: Vector2 = Vector2.ZERO
# R217 刀C：player.tick 拆键探针（vc24 尖峰玩117ms 归因）——移段=增益节拍+移动，
# 火段=四组武器调度（weapon_slots/僚机/镜面/护航舰）。GameLoop ② 段前清零、段后读入
# stage_probe_us（键 player_mv「移」/player_wp「火」）。static：GameLoop 持实例读数。
static var probe_pre_us: int = 0
static var probe_weapons_us: int = 0
# R289 A：逐武器族窗口计时（0..8=W1..W9，9=僚机/镜面/护航舰副本桶）——GameLoop 帧头
# 累计进 武1µs..武9µs/副武µs 秒窗键，回答「哪把武器吃了 火 段」。只加计时不改行为。
static var probe_wpn_us: PackedInt64Array = PackedInt64Array([0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
var _wpn_lod_phase: int = 0                   # R289 A：深载隔帧节流相位（0=执行步 1=跳步）
var _sub_lod_ctr: int = 0                     # R291 峰值刀：副武四分频相位（0=执行副武的武器执行拍）

# ── R220 刀12：帧率优先弹生成配额（护栏刀——主控决策#4 终值 32 发/物理步） ──
# 仅 PerfGovernor.frame_priority()==true 生效（特效优先=无配额恒放行）；超配丸经
# WeaponBase._spawn_quota_allow 顺延 1-2 帧交错散开（防预算恢复瞬间再对齐），顺延/
# 丢弃计数入 DebugStats.quota_deferred / quota_dropped（R220_COUNTER_KEYS 审计块）。
# 配额回滚=置无限大（SPAWN_QUOTA_PER_STEP 换 _QUOTA_UNLIMITED 即完全关闭）。
const SPAWN_QUOTA_PER_STEP := 32              # 帧率优先每物理步全组弹生成配额（四组共享）
const QUOTA_QUEUE_CAP := 256                  # 补发顺延队列帽（约 2 步满载对齐帧顺延量；溢出丢弃）
const _QUOTA_UNLIMITED := 1 << 30
var _spawn_quota_left: int = _QUOTA_UNLIMITED  # 本步新丸配额余量（火段入口重置——步内递减）
var _quota_due_pool: int = 0                   # 本步顺延补发预留池（=min(全场到期,32)；due
                                               # 优先吃本池——满载时队尾武器补发不被槽序前位饿死）
var _quota_queue_size: int = 0                 # 顺延队列占用（帽判定；到期出队回落）


static func reset_stage_probe() -> void:
	probe_pre_us = 0
	probe_weapons_us = 0
	probe_wpn_us.fill(0)
var _drag_accum: Vector2 = Vector2.ZERO       # 相对拖动采样累计（E-15）
var _active_drag_index: int = -1              # R194 首指锁定（-1=无锁）：首条 ScreenDrag 认领，
                                              # 异 index 丢弃，released 清锁——修单指双计数/多指串扰
var input_enabled: bool = true                 # 输入使能（暂停恢复 0.5s 防误触宽限期——GameLoop 驱动）
var _prev_input_enabled: bool = true          # R194 input_enabled 镜像（上升沿清首指锁——
                                              # 宽限期内按下的旧指针不延续锁权）
# 格挡力场（MEC_SHIELD 玩家侧接线，A3 §4.4：每 interval_s 生成护盾格挡 1 次接触伤害，
# 2 层 → 5.5s；shield_interval<=0 = 未持有。charge 就绪 → 力场环可见；格挡瞬间脉冲扩散）
# R253 独立计时（用户口径「多个武器的护盾应该独立计时」取代 R238 H3 聚合）：真源=
# _shield_units（weapon uid → 各自 interval/timer/ready/layers），每把挂 MEC_SHIELD 的
# 武器一份独立单元（各自几何充能、各自就绪）；被击中时消耗「间隔最大」的就绪单元。
# 下列四字段降级为 HUD/测试派生视图（_sync_shield_view 同步——读法不变零迁移）。
var shield_interval: float = 0.0
var shield_timer: float = 0.0                  # 充能剩余（就绪后停走；HUD 护盾条数据源）
var shield_ready: bool = false
var shield_layers: int = 0                     # 二cv#1：词条当前总层数（HUD 护盾条「X N」读数源——
                                               # 原层数只折叠进充能间隔即丢弃，玩家无从得知叠了几层）
var _shield_units: Dictionary = {}             # R253 独立计时单元表（uid → {interval,timer,ready,layers}）
var _shield_pulse_left: float = 0.0            # 格挡扩散脉冲剩余（表现层）
# 二db 橙盾（躲爆奖励）：敌方爆炸（地雷/自爆虫/闪现爆/法术圈）未伤人 → mine_dodged → +1 层，全盾 10s 刷新
# （可叠至上限；每层挡下一次接触伤害——先于蓝盾消耗，临时过期资源先用先消）
var temp_shield_stacks: int = 0                # 橙盾层数（HUD 橙条读数源；归零即失效）
var temp_shield_left: float = 0.0              # 橙盾剩余 s（层清随归零；HUD 填充/秒读源）
var _dodge_frame_stamp: int = -1               # R253 同帧多源合并帧戳（雷海+自爆海同帧齐爆=一次走位 1 层）
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

const MAX_SLOTS := GameConst.MAX_WEAPON_SLOTS   # 槽位数组上限（真源 GameConst；难度帽 5/6/6 恒在其内）
# R243 新武器脚本路径（_instantiate_weapon MELEE mode 分派消费；ResourceLoader.exists
# 守卫——脚本未交付波次回落 OrbitWeapon 不崩）
const FLYING_SWORD_SCRIPT_PATH := "res://scripts/combat/weapon/melee/flying_sword_weapon.gd"
const GROUND_AXE_SCRIPT_PATH := "res://scripts/combat/weapon/melee/ground_axe_weapon.gd"
const RESPAWN_INVULN_S := 1.5                 # 重开无敌帧 s（B_spec 无数值 → 主控裁定，见 respawn 注释）
const REVIVE_INVULN_S := 5.0                  # 复活无敌帧 s（二cs：3.0→5.0，用户「没反应过来」——反应窗拉长）
const GRAZE_FEEDBACK_CD := 0.25               # c4① graze 微光节流 s（无敌窗被打的轻反馈节拍；只发信号不动数值）
const REVIVE_CLEAR_RADIUS := 260.0            # 复活清弹缓冲半径 px（E2 r2；与旧 kill_blast r=260 同口径）
const REVIVE_CLEAR_CAP := 24                  # 复活清弹上限（与 _skill_stomp 消弹同帽——公平性缓冲而非清场权）
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
# 二db 橙盾参数（用户口径：躲过敌方爆炸给 10s 临时护盾、可叠加；上限为防 boss 满场雷
# 一次吃满滚雪球的护栏值——用户否决可放宽）
const TEMP_SHIELD_TIME := 10.0                 # 橙盾寿命 s（每次叠层整体刷新）
const TEMP_SHIELD_MAX := 5                     # 叠层上限
# ── P2 角色技能参数（数值真源：META_ROADMAP §5.10 角色扩展 ×2） ──
const POISON_CLOUD_RADIUS := 300.0             # 毒云半径 px
const POISON_CLOUD_DURATION := 6.0             # 毒云持续 s
const POISON_CLOUD_TICK := 0.5                 # 结算节拍 s（域内敌每 0.5s 一跳）
const POISON_CLOUD_ATK_PCT := 0.08             # 每跳伤害 = 8% 主武器 ATK（毒伤，直结算）
const POISON_CLOUD_SLOW := 0.20                # 减速 20%（ext_slow 乘区 0.8）
const POISON_SLOW_REFRESH := 0.6               # 减速刷新窗 s（>结算节拍，防 120Hz 边界闪烁）
const SUMMON_COPIES := 2                      # 僚机数（= 复制武器数；用户口径「相当于临时复制俩武器」）
const SUMMON_DURATION := 10.0                  # 僚机持续 s
# ── R246 技能升华参数（数值真源：docs/design/sublime/*.md 总监终审版；勿动上方原常量）──
const SUBLIME_FIELD_DURATION := 5.0            # sentinel 绝对屏障：无敌/力场 3→5s
const SUBLIME_FIELD_PULSE_TICK := 0.5          # 相位反冲节拍 s（5s 恰 10 跳 = 150% ATK）
const SUBLIME_FIELD_RADIUS := 120.0            # 反冲半径 px
const SUBLIME_FIELD_ATK_PCT := 0.15            # 每跳 15% 主武器 ATK
const SUBLIME_FIELD_KNOCK := 220.0             # 每跳击退冲量 px（≤ stomp 的 280）
const SUBLIME_FIELD_ABSORB_GATE := 0.5         # 吸收节流闸 s
const SUBLIME_FIELD_ABSORB_CD := 2.0           # 每次吸收回充 CD s
const SUBLIME_FIELD_ABSORB_CAP := 20.0         # 单施放回充帽 s
const SUBLIME_WINDOW := 5.0                    # veles 临界过载：窗口 4→5s
const SUBLIME_ROF_START := 2.0                 # 爬坡起点（= 普通版恒温值）
const SUBLIME_ROF_PEAK := 3.2                  # 爬坡峰值
const SUBLIME_RAMP_STEP := 0.25                # 爬坡步长（20 档；档间才 refresh）
const HEAT_STACK_MAX := 5                      # veles 余热层帽
const HEAT_STACK_PCT := 0.04                   # 每层余热射速增益
const HEAT_DROP_INTERVAL := 1.2                # 掉层间隔（满层尾迹 6s）
const BULWARK_SUBLIME_FX := 3.8                # bulwark 余震壁垒演出 s（盖余震窗）
const STOMP_AFTERSHOCK_INTERVAL := 1.0         # 余震间隔 s
const STOMP_AFTERSHOCK_PULSES := 3             # 余震跳数（t+1/2/3s）
const STOMP_BARRIER_PER_BULLET := 1.5          # 每清 1 弹转化的护壁量
const STOMP_BARRIER_CAP := 48.0                # 磐岩护壁帽
const RANGER_SUBLIME_FX := 1.2                 # ranger 百影穿袭演出 s（含残影爆窗）
const SHADOW_DASH_BASE_DIST := 340.0           # 基础瞬步距离 px（普通 260→340）
const SHADOW_DASH_DIST_PER_LURK := 30.0        # 每层潜影 +30px（满 4 层 460）
const SHADOW_DASH_INVULN := 1.8                # 无敌 s（普通 1.0→1.8）
const SHADOW_DASH_ATK_BASE := 2.4              # 路径伤害 240% 主武器 ATK
const SHADOW_DASH_ATK_PER_LURK := 0.4          # 每层 +40%（满层 400%）
const SHADOW_SWEEP_RADIUS := 56.0              # 穿袭胶囊半径 px
const SHADOW_SWEEP_STEP := 64.0                # 沿线步进 px
const SHADOW_ECHO_FUSE := 0.45                 # 残影引信 s
const SHADOW_ECHO_ATK := 1.2                   # 残影爆伤 120% ATK
const SHADOW_ECHO_RADIUS := 150.0              # 残影爆伤半径 px
const SHADOW_ECHO_KNOCK := 160.0               # 残影击退冲量
const SHADOW_ECHO_CLEAR_R := 110.0             # 残影拂弹半径 px
const SHADOW_ECHO_CLEAR_CAP := 6               # 每影拂弹帽
const LURK_STACK_MAX := 4                      # 潜影层帽
const LURK_STACK_INTERVAL := 12.0              # 蓄层间隔 s（不受击）
const TS_WINDOW := 3.5                         # zero 时滞奇点：基础窗口 2.5→3.5s
const TS_EXT_PER_KILL := 0.15                  # 每次凝滞击杀延展量 s
const TS_EXT_MAX := 0.9                        # 延展帽 s（6 杀）
const TS_PULSE_INTERVAL := 0.25                # 力场按压节拍 s
const TS_ROF := 1.2                            # 唯我演算：窗口内射速乘区
const SUBLIME_NOVA_PCT := 2.10                 # mank 万毒噬界：毒爆基础倍率 210%
const SUBLIME_ESSENCE_MAX := 30                # 腐化精华上限
const SUBLIME_ESSENCE_PCT := 0.02              # 每层 +2%（加算入倍率）
const SUBLIME_ESSENCE_ELITE := 2               # 精英击杀喂层
const SUBLIME_ESSENCE_BOSS := 5                # Boss 击杀喂层
const SUBLIME_BLAST_PCT := 0.50                # 腐沼爆裂 50% ATK
const SUBLIME_BLAST_RADIUS := 140.0            # 爆裂半径 px
const POISON_CLOUD_SUBLIME_DURATION := 7.0     # vera 毒理学终章：持续 6→7s
const POISON_CLOUD_SUBLIME_RADIUS_END := 390.0 # 半径成长终值 px（300 起线性）
const POISON_STACK_MAX := 12                   # 毒蚀层数帽
const POISON_STACK_DMG_PER := 0.06             # 每层跳伤 +6%
const POISON_STACK_SLOW_PER := 0.015           # 每层减速额外 +1.5pp
const POISON_CATALYSIS_PER_STACK := 0.03       # 催化解离每层 3% ATK
const SUBLIME_SUMMON_COPIES := 3               # noah 万械共鸣：复制武器/护航舰 2→3
const SUBLIME_SUMMON_DURATION := 16.0          # 基础持续 10→16s
const SUBLIME_DRONE_ATK_PCT := 0.18            # 舰弹 12%→18% 主武器 ATK
const RESONANCE_MAX := 40                      # 共鸣层帽
const RESONANCE_DMG_PER_STACK := 0.015         # 每层 +1.5% 副本/舰弹伤害
const RESONANCE_TIME_PER := 5                  # 每 5 层 +1s
const RESONANCE_TIME_BONUS_CAP := 8.0          # 恋战延时帽 s（最长 24s）
const ECHO_SUBLIME_MULT_HETERO := 1.80         # echo 无尽回响：双声部主窗基础射速
const ECHO_SUBLIME_MULT_HOMO := 1.90           # 同频共振主窗基础射速
const ECHO_SUBLIME_PER_STACK := 0.02           # 每层主窗增益（仅双声部）
const ECHO_SUBLIME_STACK_CAP := 6              # 回声层帽
const ECHO_SUBLIME_AFTERGLOW_MULT := 1.35      # 余韵射速（主窗增幅之半）
const ECHO_SUBLIME_AFTERGLOW_PER := 0.5        # 余韵 s/层（同频共振）
const ECHO_SUBLIME_AFTERGLOW_PER_HETERO := 0.6 # 余韵 s/层（双声部）
const ECHO_SUBLIME_AFTERGLOW_CAP := 3.0        # 余韵时长帽（双声部 3.6）
const MEDIC_HEAL_PCT := 0.3                    # medic 医疗矩阵：回复 30% max_hp
const MEDIC_DR_WINDOW := 4.0                   # medic 减伤窗 s
const MEDIC_DR_VALUE := 0.5                    # medic 减伤窗乘区（×0.5）
const VORTEX_SINGULARITY_DURATION := 3.0       # vortex 奇点：窗口 s
const VORTEX_PULL_RADIUS := 320.0              # 向心牵引半径 px
const VORTEX_PULL_FORCE := 70.0                # 每拉冲量 px（每 2 物理帧一次）
const VORTEX_BLAST_RADIUS := 220.0             # 末爆半径 px
const VORTEX_BLAST_ATK := 1.2                  # 末爆 120% 主武器 ATK
const REAPER_WINDOW := 6.0                     # reaper 收割窗 s
const REAPER_ATK_BUFF := 0.5                   # reaper 伤害窗 atk 尾乘 +50%
const SUBLIME_RESON_CAP := 500                 # fission 本命同调：层数帽
const SUBLIME_RESON_PER_LAYER := 0.0013        # 每层攻击 +0.13%
const SUBLIME_INSTANT_ATK := 0.08              # fission 抽卡即时糖 +8%
const SUBLIME_BACKFILL := 0.5                  # fission 追溯回填比（本局已击杀 ×0.5）
const SUBLIME_CDR_RATE := 0.65                 # fission 升华 CDR 折算率（普 0.5）
const SUBLIME_CDR_CAP := 0.45                  # fission 升华射速帽（普 0.30）
const SUBLIME_MODPARTS := [                    # fission Ω 改装件五档表（200/300/400/500 走 extern_buffs）
	{"at": 100, "id": &"mag", "name": "Ω-弹匣", "atk": 0.08},
	{"at": 200, "id": &"thrust", "name": "Ω-推进", "spd": 0.08},
	{"at": 300, "id": &"focus", "name": "Ω-聚焦", "size": 0.08},
	{"at": 400, "id": &"fc", "name": "Ω-火控", "crit": 0.05},
	{"at": 500, "id": &"oc", "name": "Ω-超频", "rof": 0.08},
]


func _ready() -> void:
	# 组注册（敌/敌弹经组查找缓存玩家引用）+ 命中盒/拾取区/贴纸渲染组装（代码组装为主）
	add_to_group(&"player")
	# R235 搭车①：layer 置 3（保留 bit1 + 增 bit2）——敌 _hit_area.collision_mask=2 只与
	# 本体配对（敌-敌 pair 消除；_on_contact_area 信号过滤语义不变，接触伤害链零改动）。
	# R237 清退刀：CONTACT_RADIAL on=玩家侧物理面整体惰化（layer 0+双 monitoring 关，
	# 接触伤害走敌侧 tick 直判——物理空间终局清空；boot 时读旗，运行中翻旗不追溯已建实例）。
	if Enemy.CONTACT_RADIAL:
		collision_layer = 0
		monitoring = false
		monitorable = false
	else:
		collision_layer = 3
	_hit_shape = CollisionShape2D.new()
	_hit_shape.name = "HitShape"
	var hit_circle := CircleShape2D.new()
	hit_circle.radius = hitbox_radius
	_hit_shape.shape = hit_circle
	add_child(_hit_shape)
	# R220 刀10：磁吸拾取区 Area2D 构建段摘除（零消费者——磁吸/拾取全走 XpShard.tick
	# 距离判定读 pickup_radius；物理 space 每 step 省 1 个无消费者 area 的注册/同步/pair）
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
	# R25 武器悬浮层（用户点名「所有武器悬浮在主角身边，多武器动态绕主角排列」）
	orbit_avatars = WeaponOrbitAvatars.new()
	orbit_avatars.name = "WeaponOrbitAvatars"
	add_child(orbit_avatars)
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
	EventBus.crystal_shield_request.connect(grant_crystal_shield)   # R192 结晶族反应（ElementalSystem 结晶臂唯一发点）
	EventBus.mine_dodged.connect(_on_mine_dodged)   # 二db 躲爆橙盾（敌方爆炸未伤人发点——R251 扩自爆虫/闪现爆/法术圈）
	# R246 升华击杀订阅（echo 回声层 / noah 军械共鸣 / fission 本命同调原始计数——回调内
	# character_id/skill_sublime 双守卫，非对应角色恒零开销；:221-222 连接口同款先例）
	EventBus.enemy_killed.connect(_on_echo_kill_stack)
	EventBus.enemy_killed.connect(_on_resonance_kill)
	EventBus.enemy_killed.connect(_on_enemy_killed_resonance)
	var bal := GameConfig.balance
	if bal != null:
		# 初始 HP 真源 = cfg player_base_hp（60；张力调校值已回注真源，消除双轨）
		max_hp = GameConfig.get_constant(&"player_base_hp", 60.0)
		hp = max_hp
		pickup_radius = bal.pickup_radius
		xp_need = _xp_need_for(level)
	# R233 T6：插值缓冲置初始位（prev=curr=初始位——玩家持久非池化，此后帧末快照全程续拍）
	_ip_prev = global_position
	_ip_curr = global_position


func setup(p_deps: Dictionary) -> void:
	# 注入 pipeline/pools/grid/registry（包 3/4 接线；当前仅存档，武器实例由 equip 装载）
	_deps = p_deps


func tick(p_game_delta: float, p_move_delta: Vector2) -> void:
	# 相对拖动移动 + 边界钳制 + 无敌帧推进 + 武器自动开火调度
	# R217 刀C：段内计时基准（移段/火段拆键——见 weapon 调度处注释）
	var _probe_t0 := Time.get_ticks_usec()
	if _dead:
		return
	if invuln_left > 0.0:
		invuln_left -= p_game_delta
		if invuln_left < 0.0:
			invuln_left = 0.0
	# c4① graze 反馈节流递减（既有衰减段顺带推进；float 成员零分配合规 R188 纪律）
	if _graze_fb_left > 0.0:
		_graze_fb_left = maxf(_graze_fb_left - p_game_delta, 0.0)
	# R246 绝对屏障（sentinel 升华）：力场权威计时 + 0.5s 相位反冲 + 吸收节流闸衰减
	#（首跳挂场即有反馈——vera 毒云 :899 首跳即刻同款；5s 窗恰 10 跳 = 150% ATK）
	if _sub_field_left > 0.0:
		_sub_field_left = maxf(_sub_field_left - p_game_delta, 0.0)
		_sub_absorb_gate_left = maxf(_sub_absorb_gate_left - p_game_delta, 0.0)
		_sub_field_tick_left -= p_game_delta
		if _sub_field_tick_left <= 0.0 and _sub_field_left > 0.0:
			_sub_field_tick_left += SUBLIME_FIELD_PULSE_TICK
			_sub_field_pulse()
	# R246 催化解离（vera 升华）：错帧执行——末跳与窗归零同帧同源同目标会被管线幂等键
	# 短路吞成 0 伤，挂 pending 到下一 tick 帧（帧号自然错开，玩家无感）
	if _poison_catalysis_pending:
		_poison_catalysis_pending = false
		_poison_catalysis_burst()
	# R192 结晶晶盾：tick 衰减（到期归零——减伤闸以 dr_left>0 为判据，双字段同步收口）
	if dr_left > 0.0:
		dr_left = maxf(dr_left - p_game_delta, 0.0)
		if dr_left <= 0.0:
			dr_value = 0.0
	# R246 医疗矩阵（medic）：减伤窗倒数（×0.5 乘区在 take_contact_damage dr 闸后消费）
	if _dr_window_left > 0.0:
		_dr_window_left = maxf(_dr_window_left - p_game_delta, 0.0)
	# 角色技能节拍（冷却 + 增益型剩余）
	if skill_cd_left > 0.0:
		skill_cd_left = maxf(skill_cd_left - p_game_delta, 0.0)
	# R246 余震壁垒（bulwark 升华）：施放后 1s × 3 跳余震（读实时 global_position 跟随推进；
	# _dead 守卫——死亡瞬间未跳完的余震窗停跳，收口走 _reset_skill_temp_state）
	if _stomp_aftershock_pulses > 0 and not _dead:
		_stomp_aftershock_left -= p_game_delta
		if _stomp_aftershock_left <= 0.0:
			_stomp_pulse(200.0, 140.0, 220.0, 8, true)
			_stomp_aftershock_pulses -= 1
			_stomp_aftershock_left = STOMP_AFTERSHOCK_INTERVAL
	if _skill_fx_left > 0.0:
		_skill_fx_left = maxf(_skill_fx_left - p_game_delta, 0.0)
		queue_redraw()                            # 光环呼吸/倒数弧重绘
	# 复活保护青弧倒数（E2 r2）：块内进入即刷（含归零当帧——归零后 _draw 守卫不再绘制，
	# 本帧重绘抹掉最后画面防整圈残影）；跨局清口见 clear_revive_protect
	if _revive_protect_left > 0.0:
		_revive_protect_left = maxf(_revive_protect_left - p_game_delta, 0.0)
		queue_redraw()
	# R246 时滞奇点（zero 升华）：力场窗口推进 + 0.25s 按压（新入场敌一并凝滞）；窗外零监听
	if _ts_left > 0.0:
		_ts_left = maxf(_ts_left - p_game_delta, 0.0)
		_ts_pulse_left -= p_game_delta
		if _ts_pulse_left <= 0.0 and _ts_left > 0.0:
			_ts_pulse_left = TS_PULSE_INTERVAL
			_timestop_pulse()
		if _ts_left <= 0.0:
			_ts_left = 0.0
			_ts_bonus = 0.0
			if EventBus.enemy_killed.is_connected(_on_enemy_killed_timestop):
				EventBus.enemy_killed.disconnect(_on_enemy_killed_timestop)
	if skill_active_left > 0.0:
		skill_active_left = maxf(skill_active_left - p_game_delta, 0.0)
		# R246 临界过载（veles 升华）：窗口内爬坡（0.25s 一档 2.0→3.2；档间 refresh 触发
		# R29 在途冷却立即缩短——「越打越快」体感核心）
		if skill_sublime and character_id == &"veles":
			_overload_ramp_t += p_game_delta
			var ramp_step := int(_overload_ramp_t / SUBLIME_RAMP_STEP)
			var ramp_target := lerpf(SUBLIME_ROF_START, SUBLIME_ROF_PEAK,
				clampf(float(ramp_step) * SUBLIME_RAMP_STEP / SUBLIME_WINDOW, 0.0, 1.0))
			if not is_equal_approx(ramp_target, rof_mult):
				rof_mult = ramp_target
				refresh_weapon_intervals()
		if skill_active_left <= 0.0:
			# R246 到期分流：veles 余热软着陆 / echo 渐弱余韵 / 其余硬复位（普通路径逐位不变）
			if skill_sublime and character_id == &"veles" and _heat_stacks > 0:
				rof_mult = 1.0 + _heat_stacks * HEAT_STACK_PCT   # 余热软着陆（替硬复位）
				_heat_drop_left = HEAT_DROP_INTERVAL
				_overload_ramp_t = 0.0
				refresh_weapon_intervals()
			elif skill_sublime and character_id == &"echo" and _echo_stacks > 0:
				_echo_enter_afterglow()
			else:
				rof_mult = 1.0
				refresh_weapon_intervals()   # R29：过载到期登记新基准（节拍变长不回罚）
	elif skill_sublime and character_id == &"veles" and _heat_stacks > 0:
		# R246 余热渐冷：每 1.2s 掉 1 层（mult 变小 → R29 契约变长不回罚，在途冷却原样保留）
		_heat_drop_left -= p_game_delta
		if _heat_drop_left <= 0.0:
			_heat_stacks -= 1
			rof_mult = 1.0 + _heat_stacks * HEAT_STACK_PCT
			refresh_weapon_intervals()
			_heat_drop_left = HEAT_DROP_INTERVAL
	elif _echo_afterglow_left > 0.0:
		# R246 渐弱余韵（echo 升华）：半强度余韵递减，归零才回 1.0（回声不灭只是衰减）
		_echo_afterglow_left = maxf(_echo_afterglow_left - p_game_delta, 0.0)
		if _echo_afterglow_left <= 0.0:
			_echo_stacks = 0
			rof_mult = 1.0
			refresh_weapon_intervals()   # R29：降挡「节拍变长不回罚」同款
	# 毒云领域节拍（薇拉：剩余推进 + 0.5s 一跳域内结算/减速刷新）
	if _poison_cloud_left > 0.0:
		_poison_cloud_left = maxf(_poison_cloud_left - p_game_delta, 0.0)
		_poison_cloud_tick_left -= p_game_delta
		if _poison_cloud_tick_left <= 0.0:
			_poison_cloud_tick_left += POISON_CLOUD_TICK
			_poison_cloud_pulse()
			# R246 领域滋生：升华半径随时间 300→390 线性成长——emit 与 pulse 内 query 同源
			EventBus.emit_poison_cloud_tick(global_position, _cloud_radius_now())   # R10 毒圈持续表现
		if _poison_cloud_left <= 0.0:
			EventBus.emit_poison_cloud_end()   # R199 H01：云结束即广播（fx 层立即入渐隐，
			                                   # 根治「毒圈全亮滞留 4s 误导走位」）
			# R246 催化解离：消散瞬间转挂 pending（tick 顶部下一帧结算——错帧防幂等键吞跳）
			if skill_sublime and not _poison_stack_table.is_empty():
				_poison_catalysis_pending = true
	# R246 百影穿袭（ranger 升华）：残影引信推进（到点爆裂）+ 潜影蓄能（帽内计时）
	for _fi in range(_shadow_fuses.size() - 1, -1, -1):
		var fuse: Dictionary = _shadow_fuses[_fi]
		fuse["left"] = maxf(float(fuse["left"]) - p_game_delta, 0.0)
		if float(fuse["left"]) <= 0.0:
			_shadow_echo_blast(fuse["pos"])
			_shadow_fuses.remove_at(_fi)
	if skill_sublime and character_id == &"ranger" and _lurk_stacks < LURK_STACK_MAX:
		_lurk_timer += p_game_delta
		if _lurk_timer >= LURK_STACK_INTERVAL:
			_lurk_timer -= LURK_STACK_INTERVAL
			_lurk_stacks += 1
	# 僚机到期还原（诺亚：复制武器回收 + 护航舰离场）
	if _summon_left > 0.0:
		_summon_left = maxf(_summon_left - p_game_delta, 0.0)
		if _summon_left <= 0.0:
			_summon_restore()
	# R246 奇点（vortex）：3s 向心牵引（降频每 2 物理帧一拉——Boss 免疫/精英 ×0.35 由
	# enemy.knockback 质量分级自动继承）+ 窗尽 220px 120% 末爆（照 nova 结算模板）
	if _vortex_left > 0.0:
		_vortex_left = maxf(_vortex_left - p_game_delta, 0.0)
		_vortex_tick_count += 1
		if _vortex_tick_count % 2 == 0:
			_vortex_pull()
		if _vortex_left <= 0.0:
			_vortex_blast()
	# R246 收割窗（reaper）：6s 伤害窗到期还原 extern atk 乘区（启停均遍历全武器失效面板）
	if _reaper_left > 0.0:
		_reaper_left = maxf(_reaper_left - p_game_delta, 0.0)
		if _reaper_left <= 0.0:
			_apply_reaper_buffs(false)
	# 格挡力场充能（R253 独立计时：逐单元充能各自就绪——真源 _shield_units；HUD 读
	# 视图字段由 _sync_shield_view 尾部同步；单元数 ≤ 武器槽 5，纯算术循环零分配）
	if not _shield_units.is_empty():
		for k in _shield_units:
			var u: Dictionary = _shield_units[k]
			if u.ready:
				continue
			u.timer = maxf(float(u.timer) - p_game_delta, 0.0)
			if float(u.timer) <= 0.0:
				u.ready = true
		_sync_shield_view()
	# 二db 橙盾寿命走表（层>0 才计；归零层清——HUD 橙条随 left 收缩到 0 消失）
	if temp_shield_stacks > 0:
		temp_shield_left = maxf(temp_shield_left - p_game_delta, 0.0)
		if temp_shield_left <= 0.0:
			temp_shield_stacks = 0
	# R194 input_enabled 上升沿（宽限期结束）清首指锁：宽限期间认领锁的旧指针不延续
	# 锁权，恢复采样后由当前按下的手指重新认领（采样→消费→钳制链路与宽限语义不动）
	if input_enabled and not _prev_input_enabled:
		_active_drag_index = -1
	_prev_input_enabled = input_enabled
	var total := p_move_delta
	if total == Vector2.ZERO:
		total = _drag_accum if input_enabled else Vector2.ZERO   # 宽限期吞掉自采样拖动（防误触）
	_drag_accum = Vector2.ZERO
	if total != Vector2.ZERO:
		_last_move_dir = total.normalized()
	# 冰锁圈外部减速（R18 P2 frost flavor：拖动映射 ×mult，到期还原——Boss 文档 §5.2）
	if hazard_slow_left > 0.0:
		hazard_slow_left = maxf(hazard_slow_left - p_game_delta, 0.0)
		if hazard_slow_left <= 0.0:
			hazard_slow_mult = 1.0
		total *= hazard_slow_mult
	global_position += total
	_clamp_to_playfield()
	# 武器自动开火调度（每帧 tick；集成包 B.8 第二批收紧：weapon_slots 已收窄 WeaponBase——直调）
	# R217 刀C：拆键探针——移段=前段（增益节拍+移动），火段=四组武器调度（本体/僚机/
	# 镜面/护航舰）；GameLoop 每帧 tick 前 reset_stage_probe 清零、②段后读数
	var _wp_t0 := Time.get_ticks_usec()
	probe_pre_us += int(_wp_t0 - _probe_t0)
	# R220 刀12：本步全组弹生成配额重置（火段入口——四组驱动共享；帧率优先 32 发/
	# 物理步、特效优先无限。每步直查 frame_priority，模式切换下一物理步即生效）。
	# due 预留池：全场到期顺延丸 min(总量,32) 先占配额——补发优先于新丸（满载时
	# 队尾武器 due 不被槽序前位的新丸饿死，pending 不膨胀）；两池合计恒 ≤32（硬帽）。
	if PerfGovernor.frame_priority():
		var due_total := 0
		for w in weapon_slots:
			if w != null and is_instance_valid(w):
				due_total += int(w.get("_quota_pending"))
		for copy in _summon_copies:
			if copy != null and is_instance_valid(copy):
				due_total += int(copy.get("_quota_pending"))
		for mirror in _mirror_images:
			if mirror != null and is_instance_valid(mirror) and mirror.has_method(&"get"):
				due_total += int(mirror.get("_quota_pending"))
		_quota_due_pool = mini(due_total, SPAWN_QUOTA_PER_STEP)
		_spawn_quota_left = SPAWN_QUOTA_PER_STEP - _quota_due_pool
	else:
		_quota_due_pool = 0
		_spawn_quota_left = _QUOTA_UNLIMITED
	# R289 A：深载隔帧节流——武器块每 2 物理步执行一次，执行步 dt×2 折算。冷却/射速/
	# 蓄能闸/词条计时全部秒基 ⇒ 模拟时间守恒（同秒内开火次数与伤害不变，只省执行税）；
	# 命中判定频次减半（W8 接触/挡弹已按概率折算，W9 挥砍窗饱和略降——设计披露）。
	# boost 关/deep 关 → _wp_run 恒 true、dt 原值（逐位不变）。
	var _wp_dt := p_game_delta
	var _wp_run := true
	if PerfGovernor.weapon_lod_on():
		_wpn_lod_phase = 1 - _wpn_lod_phase
		if _wpn_lod_phase == 1:
			_wp_run = false
			DebugStats.count(&"weapon_lod_skip", 1)
		else:
			_wp_dt = p_game_delta * 2.0
	WeaponBase.lod_dt_doubled = _wp_run and _wp_dt > p_game_delta
	WeaponBase.lod_beats = 2                        # R291：主武器组子拍数（dt×2 原语义；副武组另行写 4）
	# R293 模拟刀 B：② 相位括号开——四组武器调度段内敌位/网格成员结构性冻结
	#（击退速度型 ⑤ 才位移、rebuild/insert 在 ④、死亡回池位置不变），武器侧
	# 查询帧级共享（SimQueryShare——索敌/追击/齐射候选跨武器同帧同键复用）只在
	# 本括号内生效；括号外（含测试直驱武器拍）恒原查询路径。括号含在火段计时窗内
	#（惰性首查者付费——武9µs/副武µs 归因链不断）。
	SimQueryShare.begin_phase()
	if _wp_run:
		# 二cv#6：贴脸豁免圈随武器循环逐帧折算（零新增遍历——≤7 槽 × has_method 微秒级，
		# 落在 probe_weapons_us 计时段内；逐帧而非事件刷新是防升级/换卡/出售/超凡漏接）
		melee_sanctuary_r = 0.0
		for weapon in weapon_slots:
			if weapon != null:
				var _w_t0 := Time.get_ticks_usec()
				weapon.tick(_wp_dt)
				var _w_us := int(Time.get_ticks_usec() - _w_t0)
				if weapon.data != null:
					probe_wpn_us[WeaponBase.wpn_family_index(weapon.data.id)] += _w_us
				else:
					probe_wpn_us[WeaponBase.WPN_FAMILY_OTHER] += _w_us
				if weapon.data != null and weapon.data.form == GameConst.WeaponForm.MELEE \
						and weapon.has_method(&"effective_slash_radius"):
					melee_sanctuary_r = maxf(melee_sanctuary_r,
						float(weapon.call(&"effective_slash_radius")))
		# R291 峰值刀：深载副武四分频——副本/镜面/护航舰组每 2 个武器执行拍跑 1 次
		#（=每 4 物理步），执行拍 dt×4 秒基守恒（冷却/词条计时/奏鸣加速全 dt 缩放，
		# 与 A 刀 dt×2 同族数学，频次再折半）。vc89 真机：副武µs 100-204k/s 占玩段约
		# 1/3 且事件量 dt 折算省不掉 ⇒ 唯一可直砍轴=执行频次。boost 关/deep 关 →
		# _sub_run 恒真、dt 原值（关态逐位不变）。
		var _sub_run := true
		var _sub_dt := _wp_dt
		if PerfGovernor.weapon_lod_on():
			_sub_lod_ctr = 1 - _sub_lod_ctr
			if _sub_lod_ctr == 1:
				_sub_run = false
			else:
				_sub_dt = p_game_delta * 4.0
				WeaponBase.lod_beats = 4            # 副武组执行拍子拍数（dt×4 配对）
		# R183 僚机复制武器同拍驱动（副本不在 weapon_slots——独立数组，到期回收）
		var _c_t0 := Time.get_ticks_usec()
		if _sub_run:
			for copy in _summon_copies:
				if copy != null:
					copy.tick(_sub_dt)
			# R187 W5 镜面军团同拍驱动（永久会话态——无 10s 到期，只在回收口/重开清空；
			# 镜面实体按鸭子协议驱动——WeaponBase 子类或自备 tick() 的 Node2D 均可）
			for mirror in _mirror_images:
				if mirror != null and is_instance_valid(mirror) and mirror.has_method(&"tick"):
					mirror.call(&"tick", _sub_dt)
			# R198（P2-escort）：护航舰同拍驱动——SummonDrone._process 自驱改吃副本 game_delta
			#（引擎不再自驱；时间缩放/暂停冻结下僚机与主循环同步，不独走墙上时钟）
			for drone in _summon_drones:
				if drone != null and is_instance_valid(drone):
					drone.tick(_sub_dt)
		probe_wpn_us[WeaponBase.WPN_FAMILY_OTHER] += int(Time.get_ticks_usec() - _c_t0)
	SimQueryShare.end_phase()                      # R293 模拟刀 B：② 相位括号闭（共享窗口结束）
	probe_weapons_us += int(Time.get_ticks_usec() - _wp_t0)
	_tick_visual(p_game_delta, total)


# ── R220 刀12：弹生成配额口（武器侧 _spawn_quota_allow 经 has_method 鸭子守卫调用） ──
func quota_request(p_shots: int) -> int:
	# 新丸配额问询：返回本步放行丸数（0..p_shots；普通池递减——四组全组共享）
	var take := mini(p_shots, _spawn_quota_left)
	_spawn_quota_left -= take
	return take


func quota_request_due(p_n: int) -> int:
	# 顺延补发问询（优先通道）：due 池放行——补发先于新丸（防队尾饿死/队列膨胀）；
	# 池不足部分由武器侧回落 quota_request 普通池竞争
	var take := mini(p_n, _quota_due_pool)
	_quota_due_pool -= take
	return take


func quota_enqueue(p_n: int) -> int:
	# 顺延入队：返回被队列帽挤出丢弃数（quota_dropped 计数在武器侧统一落——
	# 与 quota_deferred 同帧成对可读）
	var room := maxi(QUOTA_QUEUE_CAP - _quota_queue_size, 0)
	var take := mini(p_n, room)
	_quota_queue_size += take
	return p_n - take


func quota_dequeue(p_n: int) -> void:
	# 到期出队（武器 tick 顺延推进调用——队列占用回落，防帽假满饿死新顺延）
	_quota_queue_size = maxi(_quota_queue_size - p_n, 0)


func _unhandled_input(p_event: InputEvent) -> void:
	# 输入抽象：相对拖动采样（Q-3）；R194 单指针锁定由本层承担——首条 ScreenDrag 认领
	# _active_drag_index，异 index（次指）丢弃；emulate_mouse_from_touch 下首指同时合成
	# MouseMotion(device=-1)，与 ScreenDrag 双路重复累计（≈速度×2）→ 仿真路丢弃，桌面
	# 真鼠标 device=0 基线不受影响。消费侧（tick 宽限吞拖 + 逐帧清零）语义不变
	if p_event is InputEventScreenDrag:
		var drag := p_event as InputEventScreenDrag
		if _active_drag_index == -1:
			_active_drag_index = drag.index          # 首指认领（无锁态先到先得）
		elif drag.index != _active_drag_index:
			return                                    # 次指拖动不累计（防多指速度叠乘）
		_drag_accum += drag.relative
	elif p_event is InputEventScreenTouch:
		var st := p_event as InputEventScreenTouch
		if not st.pressed and st.index == _active_drag_index:
			_active_drag_index = -1                   # 首指抬起清锁（次指可在下条拖动认领——锁转移）
	elif p_event is InputEventMouseMotion:
		var mm := p_event as InputEventMouseMotion
		if mm.device == InputEvent.DEVICE_ID_EMULATION:
			return                                    # 触摸仿真鼠标路（已由 ScreenDrag 累计——防双计数）
		if (mm.button_mask & MOUSE_BUTTON_LEFT) != 0:
			_drag_accum += mm.relative


func _draw() -> void:
	# R271 P4：绘µs wrap（自绘件 _draw 计时入 &"draw" 桶——只加计不改行为；
	# 原体迁 _draw_r271，早退 return 由委托面兜底不漏收口）
	DebugStats.bucket_begin(&"draw")
	_draw_r271()
	DebugStats.bucket_end(&"draw")


func _draw_r271() -> void:
	# R19 技能演出光环（效果持续可视化——「不知道效果何时结束」终解）：
	# 金色呼吸外环 + 剩余时长倒数弧（12 点方向顺时针收拢，归零即效果结束）
	if _skill_fx_left > 0.0 and _skill_fx_max > 0.0:
		var ratio := clampf(_skill_fx_left / _skill_fx_max, 0.0, 1.0)
		var pulse := 0.5 + 0.5 * sin(_skill_fx_left * 9.0)
		draw_circle(Vector2.ZERO, 36.0, Color(1.0, 0.85, 0.3, 0.05 + 0.05 * pulse))
		draw_arc(Vector2.ZERO, 36.0, 0.0, TAU, 44, Color(1.0, 0.85, 0.3, 0.28), 2.0, true)
		draw_arc(Vector2.ZERO, 36.0, -PI * 0.5, -PI * 0.5 + TAU * ratio, 44,
			Color(1.0, 0.9, 0.45, 0.95), 4.0, true)
	# E2 r2 复活保护青弧（独立字段生命周期：_try_revive 置位 → tick 衰减 → respawn/
	# _restore 显式清零；全部绘制含淡底环置于 left>0 守卫内——不画恒显底环，归零当帧
	# 重绘即整弧消失、跨局不残留）。半径 42px 与金弧 36px 错开（复活+技能同屏可读）
	if _revive_protect_left > 0.0 and _revive_protect_max > 0.0:
		var rv_ratio := clampf(_revive_protect_left / _revive_protect_max, 0.0, 1.0)
		draw_circle(Vector2.ZERO, 42.0, Color(0.45, 0.95, 1.0, 0.06))
		draw_arc(Vector2.ZERO, 42.0, 0.0, TAU, 44, Color(0.45, 0.95, 1.0, 0.24), 2.0, true)
		draw_arc(Vector2.ZERO, 42.0, -PI * 0.5, -PI * 0.5 + TAU * rv_ratio, 44,
			Color(0.45, 0.95, 1.0, 0.95), 4.0, true)


func take_contact_damage(p_dmg: float) -> void:
	# ★ 简化路径（Q-16）：无敌帧判定 → 格挡力场 → 结晶晶盾减伤闸 → 直接扣 HP →
	# player_hit 事件（不入 M-12）。R192：减伤闸位于无敌帧/格挡闸后、HP 直减前——
	# 结晶族反应唯一玩家侧消费漏斗（dr 刷新不叠加，纯会话态零存档）
	if _dead or invuln_left > 0.0:
		# R246 绝对屏障（sentinel 升华）：力场吞下这口伤害 → 回充（接触/敌弹同漏斗同权重；
		# _sub_field_left>0 强限定——复活/受击/重生无敌期被打不计，防与通用无敌帧串味）
		if _sub_field_left > 0.0:
			_sub_absorb_hit()
		# c4① graze 掠过反馈（二cp#1：无敌期被打此前完全静默——4s 内 80 发穿身敌弹仅
		# 6 发落账）：节流窗归零才发一次轻信号 + 计数。只做信号反馈不做数值刀
		#（contact_tick 0.6→0.35 已入 skipped 待数值评审）；死亡态不发（复活演出另有通道）
		if not _dead and _graze_fb_left <= 0.0:
			_graze_fb_left = GRAZE_FEEDBACK_CD
			EventBus.emit_graze(global_position)
			DebugStats.count(&"graze_hits", 1)
		return
	# 二db 橙盾（躲雷奖励）：先于蓝盾消耗（临时过期资源先用先消；整击吞下同蓝盾口径
	# ——contact_tick 无敌帧防同帧连击透层；涟漪/成就计数复用 shield_blocked 通道）
	if temp_shield_stacks > 0 and temp_shield_left > 0.0:
		temp_shield_stacks -= 1
		if temp_shield_stacks == 0:
			temp_shield_left = 0.0
		_shield_pulse_left = SHIELD_PULSE_TIME
		invuln_left = GameConfig.balance.contact_tick if GameConfig.balance != null else 0.6
		DebugStats.count(&"orange_blocks", 1)
		EventBus.emit_shield_blocked(global_position)
		return
	# 格挡力场优先（A3 §4.4 MEC_SHIELD：任一独立单元就绪即挡。R253 独立计时：消耗
	# 「间隔最大」的就绪单元——慢盾先挡归位重充，快充盾留给高频弹幕；格挡后进入再充能）
	var block_key := -1
	var block_interval := -1.0
	for k in _shield_units:
		var u: Dictionary = _shield_units[k]
		if u.ready and float(u.interval) > block_interval:
			block_interval = float(u.interval)
			block_key = k
	if block_key >= 0:
		var bu: Dictionary = _shield_units[block_key]
		bu.ready = false
		bu.timer = bu.interval
		_shield_pulse_left = SHIELD_PULSE_TIME
		invuln_left = GameConfig.balance.contact_tick if GameConfig.balance != null else 0.6
		DebugStats.count(&"shield_blocks", 1)      # R238：格挡计数（1Hz 行「挡N」差分——护盾效果日志可判读口）
		EventBus.emit_shield_blocked(global_position)
		_sync_shield_view()
		return
	var dmg := maxf(p_dmg, 0.0)
	if dr_left > 0.0:
		dmg *= 1.0 - clampf(dr_value, 0.0, 0.8)   # 结晶晶盾：×(1−dr)（dr_value 0.15 → ×0.85）
	dmg *= 1.0 - clampf(relic_dr, 0.0, 0.8)       # R253 防御向遗物减伤（独立乘区——与晶盾乘法复合）
	# R246 磐岩护壁（bulwark 升华）：dr 闸后、HP 直减前先行吸收；耗尽即透——
	# 全吸收复用 MEC_SHIELD 格挡口径（contact_tick 无敌帧防同帧连击秒破）；上报净伤
	if _stomp_barrier > 0.0:
		var soaked := minf(_stomp_barrier, dmg)
		_stomp_barrier -= soaked
		dmg -= soaked
		if dmg <= 0.0:
			invuln_left = GameConfig.balance.contact_tick if GameConfig.balance != null else 0.6
			return
	# R246 医疗矩阵（medic）：减伤窗 ×0.5（与无敌/晶盾独立叠乘，窗内持续生效）
	if _dr_window_left > 0.0:
		dmg *= MEDIC_DR_VALUE
	hp -= dmg
	invuln_left = GameConfig.balance.contact_tick if GameConfig.balance != null else 0.6
	_flash_left = FLASH_TIME                     # 方向 C：受击变白弹回
	_punch_left = PUNCH_TIME
	EventBus.emit_player_hit(dmg, 0)
	# R246 潜影断影（ranger 升华）：实减 HP 路径才清（格挡 :439-446 / 无敌早退 :436-437 不清——
	# 格挡=「挡住」非「受创」，奖励叠甲走位流）
	if _lurk_stacks > 0:
		_lurk_stacks = 0
		_lurk_timer = 0.0
	if hp <= 0.0:
		if _try_revive():
			return                             # 复活成功：满血 + 无敌，不掉死亡仲裁
		hp = 0.0
		_on_died()


func apply_max_hp_up(p_amount: float) -> void:
	# AFF_HP_UP 消费点（A3 §4.2：max_hp +25/层，可叠 4 层）：上限增量与当前血等量回补
	#（主控裁定 2026-08-29——买血条即时爽感）；负值（诅咒对称口径）双向钳制不越界。
	max_hp += p_amount
	hp = minf(hp + p_amount, max_hp)


func _on_mine_dodged(_p_pos: Vector2) -> void:
	# 二db 橙盾 grant（EventBus.mine_dodged 唯一消费——敌方爆炸未伤人发点：R251 起 =
	# BossMine/自爆虫/闪现爆/法术圈四源）：+1 层并整体刷新 10s；死亡态不授（复活演出
	# 不打断）。R253：同帧多源合并（帧戳）+ 授层逻辑下沉 grant_temp_shield 公开口
	#（金钟罩静默授予复用）。纯会话态零存档。
	if _dead:
		return
	if _dodge_frame_stamp == Engine.get_process_frames():
		return                               # R253 同帧多源合并（QA丙-3 收敛建议）：雷海+
		                                       # 自爆海同帧齐爆=一次走位的运气只授 1 层
	_dodge_frame_stamp = Engine.get_process_frames()
	grant_temp_shield(false)


func grant_temp_shield(p_silent: bool = false) -> void:
	# R253 公开授盾口：+1 层并整体刷新 10s（帽 5）。p_silent=true 为节奏授予（金钟罩
	# 每 30s）——不发首获教学 toast、计独立键 orange_gain_relic（判读口径与躲爆分离）；
	# 躲爆路径 p_silent=false 保持原 toast/计数语义。
	if _dead:
		return
	if not p_silent and temp_shield_stacks == 0:
		# 二db M1：首次/回落后再获放一次教学 toast（奖励时刻因果建立——hover 手机不可达）
		EventBus.emit_mechanics_intro("⚡ 闪避护盾：躲过敌方爆炸获得，存在 10 秒可叠加，每层挡下一次伤害")
	temp_shield_stacks = mini(temp_shield_stacks + 1, TEMP_SHIELD_MAX)
	temp_shield_left = TEMP_SHIELD_TIME
	DebugStats.count(&"orange_gain_relic" if p_silent else &"orange_gain", 1)


func apply_shield_trait(p_layers: int, p_params: Dictionary, p_charge_mult: float = 1.0,
		p_uid: int = 0) -> void:
	# MEC_SHIELD 消费点（A3 §4.4）：每 interval_s 生成护盾格挡 1 次接触伤害。重复挂载/
	# 层变化即刷新间隔。R69 品质梯分化：p_charge_mult = 词条 value（白 1.0 → 蓝/紫/金
	# 1.4/1.9/2.6），充能间隔 = 基准 / 倍率（8s → 5.7/4.2/3.1s）。
	# R238 修（用户真机两报「选了没生效/没看到」·workflow 五假设诊断实证）：
	# · H4 首挂即就绪——原首挂须走完一次充能（timer=interval 空窗 8s），深载选卡窗
	#   关闭即被围殴=选完立刻掉血，体感「没生效」；现选卡瞬间护盾可用一次（卡面
	#   「每 Ns 生成」不超售——首次即给一枚），此后每 interval 充能。
	# · H1 层数增益去两档封顶改几何逐层——原 lv1=8/lv2=5.5 第 3 层起饱和（R226 拆
	#   上架帽后满层词条持续上架，第 3+ 层零可感变化=「叠层不生效」违约 R226 原则）；
	#   现 interval = interval_s × (interval_lv2/interval_s)^(层-1) 几何递减（lv3≈3.8s、
	#   lv4≈2.6s…），钳 0.5s 下限，每层真实变快。
	# R253 独立计时（用户口径取代 R238 H3 聚合）：p_uid = 武器 uid（weapon_base 逐武器
	# 上报，每武器一份独立单元——跨武器不聚合不覆写）；uid=0 为旧签名兼容单元（测试
	# 直调/无武器语境）。同 uid 重挂=刷新该单元间隔与层数，充能进度与就绪态保持。
	var s := maxf(float(p_params.get("interval_s", 8.0)), 0.5)
	var s2 := maxf(float(p_params.get("interval_lv2", s)), 0.5)
	var ratio := clampf(s2 / s, 0.2, 1.0)
	var base := s * pow(ratio, maxf(p_layers - 1, 0))
	var interval := maxf(base / maxf(p_charge_mult, 0.05), 0.5)
	if _shield_units.has(p_uid):
		var u: Dictionary = _shield_units[p_uid]
		u.interval = interval
		u.layers = p_layers
		if not u.ready and float(u.timer) <= 0.0:
			u.timer = interval
	else:
		_shield_units[p_uid] = {"interval": interval, "timer": 0.0,
			"ready": true, "layers": p_layers}    # R238 H4：首挂即就绪
	_sync_shield_view()


func _sync_shield_view() -> void:
	# R253 视图同步：旧四字段为 HUD/测试派生视图（数据真源=_shield_units）——layers=
	# Σ各单元层数；ready=任一就绪；interval/timer=未就绪单元中最先充满者（全就绪回落
	# 最大 interval 单元——HUD 满条态读数有主）。纯算术零分配（tick 每帧调用合规）。
	if _shield_units.is_empty():
		shield_interval = 0.0
		shield_timer = 0.0
		shield_ready = false
		shield_layers = 0
		return
	var total_layers := 0
	var any_ready := false
	var best_ratio := -1.0                    # timer/interval 最大 = 最先充满
	var best_interval := 0.0
	var best_timer := 0.0
	var max_ready_interval := 0.0
	for k in _shield_units:
		var u: Dictionary = _shield_units[k]
		total_layers += int(u.layers)
		var u_interval := float(u.interval)
		if u.ready:
			any_ready = true
			max_ready_interval = maxf(max_ready_interval, u_interval)
			continue
		var u_ratio := float(u.timer) / u_interval if u_interval > 0.0 else 0.0
		# tie-break：同比例（如刚消耗完都=1.0）选绝对剩余最短者——最先回盾的单元上条
		if u_ratio > best_ratio or (is_equal_approx(u_ratio, best_ratio)
				and float(u.timer) < best_timer):
			best_ratio = u_ratio
			best_interval = u_interval
			best_timer = float(u.timer)
	shield_layers = total_layers
	shield_ready = any_ready
	if best_ratio >= 0.0:
		shield_interval = best_interval
		shield_timer = best_timer
	else:
		shield_interval = max_ready_interval   # 全就绪：满条代表单元（timer=0 满条口径）
		shield_timer = 0.0


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
	weapon.meta_atk_pct = Meta.atk_pct() + character_atk_pct + run_fallback_atk_pct   # 局外养成 + 角色修正 + 应急强化全局累计（M8/R262d）
	weapon_slots[slot] = weapon
	if weapon.get_parent() == null:
		add_child(weapon)
	# R251 需求③ 武器首获回退卡（M3 迁移：mechanics_intro 横幅改 first_encounter_card）
	# 卡选窗上架「出现即算」烧键后，此处为无选卡窗路径（首发武器/商店购买等）回退口；
	# 同键 W_id 先到先得互斥无双弹；title/body 格式与 game_loop 上架触发同 §3.2 契约
	var note := GameConst.weapon_note(String(p_data.id))
	if not note.is_empty() and Meta.mark_first_met(StringName("W_" + String(p_data.id))):
		EventBus.emit_first_encounter_card("【新武器】%s" % p_data.display_name, note,
			&"weapon", StringName(String(p_data.id)))
	_apply_resonance(-1)   # R246 fission 本命同调：新装/被挤位武器按当前层数重注入（非升华零操作）
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
	# R187 W5 万镜回廊：棱镜本体 = MirrorWeapon（镜面军团编排层，继承 LaserWeapon
	# 锚束通道；生产接线——仲裁 dwfq-a3b78ef6-1 批准，棱镜组补线 1 行）
	# R243 类别底座（§1.5）：MELEE 分支按 melee.mode 二级分派——swords→FlyingSwordWeapon、
	# axe→GroundAxeWeapon、其余（orbit/slash/cleave）仍归 OrbitWeapon（cleave 分支在
	# OrbitWeapon 内）。mode 缺省回落 nullify 旧口径（true→slash 否则 orbit，§1.2——
	# 单源 WeaponBase.melee_mode_of）。两新脚本未交付波次：ResourceLoader 存在性守卫
	# 回落 OrbitWeapon 不崩（脚本交付后 w2 套件断言实例类型）。
	match p_data.form:
		GameConst.WeaponForm.BALLISTIC:
			return BallisticWeapon.new()
		GameConst.WeaponForm.LASER:
			return MirrorWeapon.new() if String(p_data.id) == "W5_prism" \
				else LaserWeapon.new()
		GameConst.WeaponForm.HOMING:
			return HomingWeapon.new()
		GameConst.WeaponForm.MELEE:
			match WeaponBase.melee_mode_of(p_data.melee):
				"swords":
					if ResourceLoader.exists(FLYING_SWORD_SCRIPT_PATH):
						var fs: GDScript = load(FLYING_SWORD_SCRIPT_PATH)
						if fs != null and fs.can_instantiate():
							return fs.new() as WeaponBase
					return OrbitWeapon.new()
				"axe":
					if ResourceLoader.exists(GROUND_AXE_SCRIPT_PATH):
						var ga: GDScript = load(GROUND_AXE_SCRIPT_PATH)
						if ga != null and ga.can_instantiate():
							return ga.new() as WeaponBase
					return OrbitWeapon.new()
				_:
					return OrbitWeapon.new()
	return null                              # 未知形态（WeaponData 校验已封 {0,1,2,3}）


func slot_cap_total() -> int:
	# R185 有效槽位帽 = 难度帽（5/6/6）；金卡只提前解锁帽内槽位、不再 +1 扩容
	#（用户口径「本来5个位置2解锁3锁，+1后应3解锁2锁」——总位数恒定）
	return mini(GameConst.difficulty_slot_cap(_difficulty), MAX_SLOTS)


func unlock_slot(p_slot: int) -> bool:
	# 槽位解锁（幂等；事件由 WaveDirector/集成侧派发；R185 金卡同走 slot_unlocked 事件）。
	# R183：波浪里程碑解锁被难度帽截断（普通帽 5——里程碑链最高到 6 由难度决定）
	if p_slot > unlocked_slots and p_slot <= slot_cap_total():
		unlocked_slots = p_slot
		return true
	return false


func grant_slot_bonus() -> bool:
	# R88 金卡「武器槽+1」→ R185 语义：提前解锁帽内下一槽（不越帽）；
	# 帽内已满 = 无槽可解，拒绝（卡池侧 <slot_cap_total 门同步断供）
	if unlocked_slots >= slot_cap_total():
		return false
	EventBus.emit_mechanics_intro("✦ 武器槽 %d 解锁（金卡）" % (unlocked_slots + 1))
	unlocked_slots += 1
	slot_bonus += 1                              # 统计口径：本局金卡解锁数（不参与帽）
	return true


func set_character(p_id: StringName) -> void:
	# 应用角色（大厅选人 → GameLoop.start_run/respawn 调用；含局外养成加成——M8）
	# 解锁守卫：未通关解锁链的角色回落哨兵（存档迁移/异常输入防御）
	if not Meta.is_character_unlocked(p_id):
		p_id = &"sentinel"
	character_id = p_id
	var def := CharacterTable.get_character(p_id)
	max_hp = float(def.get("hp", 60.0)) + Meta.hp_bonus()
	hp = max_hp
	pickup_radius = 120.0 * (1.0 + Meta.magnet_pct())
	gold = 30 + Meta.start_gold()                # 开局资金（养成·初始资金，M8 二期）
	reroll_charges = 2 + Meta.reroll_bonus()     # 刷新次数（基础 2 + 养成·预案推演，选卡刷新机制）
	revives_left = Meta.revive_charges()         # 应急协议（每局重置）
	character_atk_pct = float(def.get("atk_pct", 0.0))
	apply_character_visual()
	comp_rof_mult = 1.0                          # CDR 折算乘区随角色复位（无技能角色由 refresh_skill_cd 立即重算）
	refresh_skill_cd()
	skill_cd_left = 0.0
	rof_mult = 1.0
	skill_sublime = false                        # R246：升华位随角色重建清零（继续局由 _restore_run_state
	                                             # 在 set_character 之后回填 enable_sublime()，先清后回无冲突）
	run_fallback_atk_pct = 0.0                   # R262d：应急强化累计随角色重建清零（继续局由
	                                             # _restore_run_state 在 weapons 重建前回填，注入即含）
	_reson_layers = 0                            # R246 fission 同调层随角色复位
	_reson_kill_count = 0                        # R246 fission 追溯回填原始击杀计数（run 作用域）
	refresh_pickup_radius()
	_reset_skill_temp_state()                    # 换角色即时清临时态（毒云/僚机还原）
	# 攻击修正动态注入（真修：武器面板若只在实例化期定格，大厅买养成/选角后开局不生效）
	for w in weapon_slots:
		if is_instance_valid(w) and w is WeaponBase:   # freed 实例上评估 is 会报脚本错——判序 valid 在前
			(w as WeaponBase).meta_atk_pct = Meta.atk_pct() + character_atk_pct + run_fallback_atk_pct
			# R246：extern 乘区随角色复位清空（fission Ω 改装件/reaper 伤害窗不泄漏给下一角色）
			if not (w as WeaponBase).extern_buffs.is_empty():
				(w as WeaponBase).extern_buffs = {}
				(w as WeaponBase).call(&"refresh_fire_interval")
			(w as WeaponBase).call(&"_invalidate_panel")


func apply_character_visual() -> void:
	# 舰体随角色着色（R13 用户反馈「选了新角色战斗中还是默认飞船」）——
	# 贴图共享、modulate 区分（低成本角色辨识）；受击闪白走 _apply_flash 临时覆盖不冲突
	var tints := {
		&"sentinel": Color(1.0, 1.0, 1.0), &"veles": Color(1.0, 0.72, 0.72),
		&"bulwark": Color(0.72, 0.84, 1.0), &"ranger": Color(0.66, 1.0, 0.92),
		&"zero": Color(0.85, 0.72, 1.0), &"mank": Color(0.66, 1.0, 0.55),
		&"vera": Color(0.72, 1.0, 0.72), &"noah": Color(1.0, 0.93, 0.62),
		&"fission": Color(0.75, 0.82, 0.95), &"echo": Color(0.94, 0.62, 1.0),
		# R246 新三角色（表条目归 meta 泳道——着色先行，选人即生效）
		&"medic": Color(0.95, 1.0, 0.98), &"vortex": Color(0.72, 0.78, 1.0),
		&"reaper": Color(0.92, 0.72, 0.85),
	}
	var tint: Color = tints.get(character_id, Color.WHITE)
	if _sprite != null:
		_sprite.modulate = tint
	if _flash != null and float(_flash.modulate.a) <= 0.0:
		_flash.modulate = tint


func _weapon_pool_sum(p_pool: StringName) -> float:
	# 跨武器聚合某 ADD 池合计（玩家侧词条的消费口：AFF_PICKUP 磁吸 / AFF_SKILL_HASTE 技能急速）
	var total := 0.0
	for w in weapon_slots:
		if w == null or not is_instance_valid(w):
			continue
		var stack: Variant = w.get("trait_stack")
		if stack == null:
			continue
		var agg: Dictionary = stack.call(&"aggregate_panel")
		total += float(agg.get(p_pool, 0.0))
	return total


func refresh_pickup_radius() -> void:
	# 磁吸半径 = 基准 ×(1 + 养成磁吸 + AFF_PICKUP 词条池)（2026-09-13 死卡接线；挂卡后重算）
	# R220 刀10：拾取 shape 半径同步段摘除（磁吸判定走 XpShard._pickup_radius 距离读
	# player.pickup_radius 字段——本函数只剩字段真源职责）
	# R226 有意契约变更（用户拍板「肉鸽别搞上限」）：原 +200% 叠加上限拆除——词条池
	# 无限叠全额生效（吸收速率侧已有 24/帧 帽做性能保险丝，R215/R225）
	var bal := GameConfig.balance
	var base := bal.pickup_radius if bal != null else 120.0
	pickup_radius = base * (1.0 + Meta.magnet_pct()
		+ maxf(_weapon_pool_sum(&"add_pickup"), 0.0))


func skill_haste_pct() -> float:
	# 技能急速最终加成（构筑详情展示口，R70 用户反馈「详情没写最终加成多少」）：
	# 跨武器 add_skillcdr 池合计。R226 有意契约变更：原 -60% 叠加上限拆除——
	# 与 refresh_skill_cd 消费同源无帽（CD 数学地板见 refresh_skill_cd）
	return maxf(_weapon_pool_sum(&"add_skillcdr"), 0.0)


func refresh_skill_cd() -> void:
	# 技能冷却基线 = 角色 cd ×(1 − 养成CDR) ×(1 − 技能急速池)
	#（AFF_SKILL_HASTE 2026-09-13 重做接线；挂卡后由 GameLoop 触发重算）
	# R29 迟到减CD（用户反馈）：技能急速到手时**已在倒计时**的技能CD按新旧基线比例
	# 立刻缩短——不再等本次冷却自然走完；基线变长不回罚（同武器侧口径）。
	# R226 有意契约变更：急速池上限拆除；(1−池) 因子保 0.1 数学地板（CD 不归零=
	# 技能仍有节拍，非成长上限）
	var base := float(CharacterTable.get_character(character_id).get("cd", 120.0))
	var new_base := base * (1.0 - Meta.skill_cdr_pct()) \
		* maxf(1.0 - _weapon_pool_sum(&"add_skillcdr"), 0.1) * skill_cd_relic_mult
	if skill_cd_base > 0.0 and new_base > 0.0 and skill_cd_left > 0.0 \
			and new_base < skill_cd_base and not is_equal_approx(new_base, skill_cd_base):
		skill_cd_left = clampf(skill_cd_left * new_base / skill_cd_base, 0.0, new_base)
	skill_cd_base = new_base
	# 无技能角色（改造者·枢）CDR 折算：养成CDR / 技能急速池 / 时之沙无法作用于不存在的
	# 技能——按 0.5 折算率转成全武器射速乘区（封顶 +30%）；有技能角色恒 1.0（不与过载/
	# 双生回响等技能射速窗双通道叠算）。折算变化即时刷新武器节拍（R29 先例 :486）
	# R246 本命同调（升华）：折算率 0.5→0.65、射速帽 +30%→+45%（非升华恒 0.5/0.30）
	var cdr_rate := SUBLIME_CDR_RATE if skill_sublime else 0.5
	var cdr_cap := SUBLIME_CDR_CAP if skill_sublime else 0.30
	var comp := 1.0 if has_skill() \
		else 1.0 + minf((1.0 - new_base / maxf(base, 0.01)) * cdr_rate, cdr_cap)
	if not is_equal_approx(comp, comp_rof_mult):
		comp_rof_mult = comp
		refresh_weapon_intervals()


func refresh_weapon_intervals() -> void:
	# R29 迟到减CD：角色侧射速增益变化（过载咆哮启停 / 地图祝福·狂热）时同步全部
	# 武器节拍——增益开启的瞬间武器已在倒计时的冷却立刻按比例缩短（立刻见效）
	for w in weapon_slots:
		if w != null and is_instance_valid(w) and w is WeaponBase:
			(w as WeaponBase).refresh_fire_interval()
	for copy in _summon_copies:               # R183 副本同口径（持续期内增益启停同样即时见效）
		if copy != null and is_instance_valid(copy):
			copy.refresh_fire_interval()
	for mirror in _mirror_images:             # R187 W5 攻速传导：AFF_ROF_UP/AFF_CDR 挂棱镜即全体镜面生效
		if mirror != null and is_instance_valid(mirror) and mirror.has_method(&"refresh_fire_interval"):
			mirror.call(&"refresh_fire_interval")


func _skill_time_stop() -> void:
	# 时滞力场（演算者·零·终极控场）：全场敌人静止 2.5s——直写 freeze_timer
	#（角色终极无视免疫位；仅定身，不清血——数值零副作用）
	var grid: Variant = _deps.get("enemy_grid")
	if grid == null:
		return
	for e in (grid as SpaceGrid).query_circle(global_position, 4096.0):
		if e == null or bool(e.get("dead")):
			continue
		var st: Variant = e.get("elemental")
		if st is ElementalState:
			(st as ElementalState).freeze_timer = 2.5   # 冻结计时器在元素状态容器（真修）
	DebugStats.count(&"time_stop")


func _skill_time_stop_sublime() -> void:
	# R246 时滞奇点（演算者·零·升华）：持续力场 + 击杀延展 + 唯我演算
	_ts_left = TS_WINDOW
	_ts_bonus = 0.0
	_ts_pulse_left = 0.0                       # 本帧即首压（挂场即有反馈，vera 毒云同款）
	_timestop_pulse()
	rof_mult = TS_ROF                          # 唯我演算：复用 veles/echo 射速窗通道
	skill_active_left = TS_WINDOW              # 到期复位骑既有 :266-269 口（rof_mult 自动回 1.0）
	if not EventBus.enemy_killed.is_connected(_on_enemy_killed_timestop):
		EventBus.enemy_killed.connect(_on_enemy_killed_timestop)
	refresh_weapon_intervals()                # R29：开启瞬间在途冷却立即按新节拍缩短
	DebugStats.count(&"time_stop_sublime")


func _timestop_pulse() -> void:
	# R246 力场按压：以玩家为心 4096 半径（全屏兜底，与 _skill_time_stop 同口径）把窗口
	# 剩余压进 freeze_timer——直写绕过 immune_mask（升华保持普通版「无视免疫」签名）
	var grid: Variant = _deps.get("enemy_grid")
	if grid == null:
		return
	for e in (grid as SpaceGrid).query_circle(global_position, 4096.0):
		if e == null or bool(e.get("dead")):
			continue
		var st: Variant = e.get("elemental")
		if st is ElementalState:
			(st as ElementalState).freeze_timer = \
				maxf((st as ElementalState).freeze_timer, _ts_left)


func _on_enemy_killed_timestop(p_enemy: Node2D) -> void:
	# R246 时之收割：仅升华零的窗口内、击杀「死亡瞬间仍凝滞」的敌人才延展——
	# 派发时 elemental 状态仍在（enemy.gd:1085-1099 置序先例）。凝滞判定用
	# freeze_timer>0 而非 _ts_left 单条件：元素通道冻结落在窗内的亡敌同样算数
	if not skill_sublime or character_id != &"zero" or _ts_left <= 0.0:
		return
	# 死亡瞬间快照经 _kill_snap（账本优先——本订阅派发位在 spawner 归还之后，尸身
	# elemental 已清；凝滞判定用 freeze_timer>0 而非 _ts_left 单条件：元素通道冻结
	# 落在窗内的亡敌同样算数）
	var snap := _kill_snap(p_enemy)
	if float(snap.get("freeze", 0.0)) > 0.0 and _ts_bonus < TS_EXT_MAX:
		_ts_bonus = minf(_ts_bonus + TS_EXT_PER_KILL, TS_EXT_MAX)
		_ts_left = minf(_ts_left + TS_EXT_PER_KILL, TS_WINDOW + TS_EXT_MAX)
		skill_active_left = maxf(skill_active_left, _ts_left)   # 射速窗随延展同步拉长
		_skill_fx_left = maxf(_skill_fx_left, TS_EXT_PER_KILL)  # HUD 时长条随延展续命
		_skill_fx_max = maxf(_skill_fx_max, _ts_left)           # 分母同步抬（含本次延展——防虚高）


func _inject_relic_pools(p_ctx: DamageContext, p_target: Node2D) -> void:
	# R199 D07：角色技能结算通道（毒沼绽放/毒云）遗物命中乘区注入——照 WeaponBase.
	# inject_relic_pools 先例（weapon_base.gd:466 → relic_handler.inject_hit_mult_pools）；
	# 问询通道 = setup deps 的 relic_handler（game_loop.gd:1410 B.2 注入位）。鸭子问询
	# 零新编译期类型边；deps 未含（测试裸 Player）→ 零操作。
	var rh: Variant = _deps.get("relic_handler")
	if rh != null and (rh as Object).has_method(&"inject_hit_mult_pools"):
		(rh as Object).call(&"inject_hit_mult_pools", p_ctx, p_target)


func _sub_absorb_hit() -> void:
	# R246 绝对屏障·吸收回充（sentinel 升华）：力场吞下一次来袭 → CD −2s——
	# 0.5s 节流（敌接触物理帧级调用不节流会算成 60 次/s）+ 单施放帽 20s（≈基准 CD 16.7%）
	if _sub_absorb_gate_left > 0.0 or _sub_absorb_reduced >= SUBLIME_FIELD_ABSORB_CAP:
		return
	_sub_absorb_gate_left = SUBLIME_FIELD_ABSORB_GATE
	_sub_absorb_reduced += SUBLIME_FIELD_ABSORB_CD
	skill_cd_left = maxf(skill_cd_left - SUBLIME_FIELD_ABSORB_CD, 0.0)
	EventBus.emit_shield_blocked(global_position)   # 复用格挡涟漪表现（event_bus.gd:196 先例）
	DebugStats.count(&"sub_field_absorb")


func _sub_field_pulse() -> void:
	# R246 绝对屏障·相位反冲：每 0.5s 对 120px 内敌结算 15% 主武器 ATK 并击退 220——
	# 伤害照 _skill_poison_nova 结算段（DamageContext+AOE_SECONDARY+KIN+crit0+遗物注入）、
	# 击退照 _stomp_pulse 鸭子调用（Boss 免疫/精英 ×0.35 自动继承）
	var grid: Variant = _deps.get("enemy_grid")
	var pipeline: Variant = _deps.get("pipeline")
	var w0: Variant = weapon_slots[0] if weapon_slots.size() > 0 else null
	if grid == null or w0 == null:
		return
	var base := float((w0 as WeaponBase).build_panel_snapshot().get("base_atk", 0.0)) \
		* SUBLIME_FIELD_ATK_PCT
	for e in (grid as SpaceGrid).query_circle(global_position, SUBLIME_FIELD_RADIUS):
		if e == null or bool(e.get("dead")):
			continue
		var ctx := DamageContext.make()
		ctx.source_uid = int(get_instance_id())     # 玩家侧幂等键（Player 无 uid 字段，同 nova 口径）
		ctx.target = e
		ctx.target_uid = int(e.get("uid"))
		ctx.frame_stamp = GameConfig.frame_stamp
		ctx.base_atk = base
		ctx.element = GameConst.Element.KIN         # 无元素通道（R199 D14 口径，免疫敌不拦零）
		ctx.hit_flags |= GameConst.HIT_IS_AOE_SECONDARY
		ctx.crit_chance = 0.0                       # 技能通道不吃暴击（同 nova）
		ctx.pos = (e as Node2D).global_position
		_inject_relic_pools(ctx, e)                 # R199 D07 遗物乘区同注入
		if pipeline != null and (pipeline as Object).has_method(&"resolve"):
			pipeline.call(&"resolve", ctx)
		if e.has_method(&"knockback"):
			e.call(&"knockback",
				((e as Node2D).global_position - global_position).normalized()
				* SUBLIME_FIELD_KNOCK)
	DebugStats.count(&"sub_field_pulse")


func _skill_poison_nova() -> void:
	# 毒沼绽放（腐化者·莽·终极毒核）：全屏敌人结算 150% 主武器攻击（AOE_SECONDARY 通道）
	# R246 万毒噬界（升华）：倍率 210% + 腐化精华层 ×2%/层（帽 30 → 满层 270%）；
	# 接住 resolve 返回的 killed 位喂层 + 死者原地腐沼爆裂（50% × 140px，深度 1）
	var grid: Variant = _deps.get("enemy_grid")
	var pipeline: Variant = _deps.get("pipeline")
	var w0: Variant = weapon_slots[0] if weapon_slots.size() > 0 else null
	if grid == null or w0 == null:
		return
	var sublime := skill_sublime
	var panel := float((w0 as WeaponBase).build_panel_snapshot().get("base_atk", 0.0))
	var pct := 1.5                               # 普通版口径（回归锚点）
	if sublime:
		pct = SUBLIME_NOVA_PCT + float(_mank_essence) * SUBLIME_ESSENCE_PCT
	var base := panel * pct
	var settled := 0
	var blast_pos: Array[Vector2] = []           # R246：本轮击杀者的爆裂锚点（升华）
	for e in (grid as SpaceGrid).query_circle(global_position, 4096.0):
		if e == null or bool(e.get("dead")):
			continue
		var ctx := DamageContext.make()
		ctx.source_uid = int(get_instance_id())   # 玩家侧 nova 幂等键（Player 无 uid 字段）
		ctx.target = e
		ctx.target_uid = int(e.get("uid"))
		ctx.frame_stamp = GameConfig.frame_stamp
		ctx.base_atk = base
		ctx.element = GameConst.Element.KIN       # R199 D14：毒系技能无元素通道（原 FIR 被火免疫
		                                          # 敌 elem_immune=2 拦零——毒沼绽放对 E4/E8 恒 0 伤）
		ctx.hit_flags |= GameConst.HIT_IS_AOE_SECONDARY
		ctx.crit_chance = 0.0
		ctx.pos = (e as Node2D).global_position
		_inject_relic_pools(ctx, e)               # R199 D07：技能通道遗物乘区（管线⑤主通道直消费）
		var res: Variant = null
		if pipeline != null and (pipeline as Object).has_method(&"resolve"):
			res = (pipeline as Object).call(&"resolve", ctx)   # R246：接住返回值（原来丢弃）
			settled += 1
		if sublime and res is DamageResult and (res as DamageResult).killed:
			_gain_mank_essence(e)                 # R246 机制一：毒爆击杀喂层
			blast_pos.append((e as Node2D).global_position)
	if settled > 0:
		DebugStats.count(&"poison_nova")
	if sublime and not blast_pos.is_empty():
		_resolve_corpse_blasts(blast_pos, panel, grid, pipeline)


func _resolve_corpse_blasts(p_anchors: Array[Vector2], p_panel: float,
		p_grid: Variant, p_pipeline: Variant) -> void:
	# R246 机制二·腐沼爆裂：击杀者原地 140px 爆裂，对内存活敌各结算 50% 面板——
	# 护栏①每目标每轮一次（blasted 去重）②深度 1（本函数击杀不再回流锚点）
	# ③合成 source_uid（玩家实例 id + 轮内序号 ×1e6——先例 ground_axe _shock_uid，
	# 防与毒爆主体同帧同目标撞 (source,target,frame) 幂等键被吞）
	_blast_uid_seq += 1
	var blast_uid := int(get_instance_id()) + _blast_uid_seq * 1000000
	var blasted := {}
	for anchor in p_anchors:
		EventBus.emit_kill_blast(anchor, SUBLIME_BLAST_RADIUS)   # 表现：复用爆炸环通道
		DebugStats.count(&"poison_blast")
		for e in (p_grid as SpaceGrid).query_circle(anchor, SUBLIME_BLAST_RADIUS):
			if e == null or bool(e.get("dead")):  # 毒爆阵亡者(dead=true)天然跳过 → 只打存活者
				continue
			var uid := int(e.get("uid"))
			if blasted.has(uid):                   # 护栏①：每目标每轮一次
				continue
			blasted[uid] = true
			var ctx := DamageContext.make()
			ctx.source_uid = blast_uid             # 护栏③：合成 UID
			ctx.target = e
			ctx.target_uid = uid
			ctx.frame_stamp = GameConfig.frame_stamp
			ctx.base_atk = p_panel * SUBLIME_BLAST_PCT
			ctx.element = GameConst.Element.KIN    # 与毒爆全通道同口径（免疫零伤不拦）
			ctx.hit_flags |= GameConst.HIT_IS_AOE_SECONDARY
			ctx.crit_chance = 0.0
			ctx.pos = (e as Node2D).global_position
			_inject_relic_pools(ctx, e)            # 遗物乘区同注
			var res: Variant = null
			if p_pipeline != null and (p_pipeline as Object).has_method(&"resolve"):
				res = (p_pipeline as Object).call(&"resolve", ctx)
			if res is DamageResult and (res as DamageResult).killed:
				_gain_mank_essence(e)              # 闭环：爆裂击杀同样喂层（不 append——深度 1）


func _gain_mank_essence(p_enemy: Variant) -> void:
	# R246 机制一喂层：tags 位分档（enemy.gd:15 TAG_ELITE/TAG_BOSS；鸭子读与 nova 循环同风格）
	# tags 读 _kill_snap 死亡瞬间快照（resolve 返回时 spawner 可能已归还清 tags——账本
	# 派发位先于 spawner，直调/未派发路径回退尸身直读同样成立）
	var tags := int(_kill_snap(p_enemy as Node2D).get("tags", 0)) if p_enemy is Node2D else 0
	var add := 1
	if (tags & (GameConst.TAG_BOSS | GameConst.TAG_FINAL_BOSS)) != 0:
		add = SUBLIME_ESSENCE_BOSS
	elif (tags & GameConst.TAG_ELITE) != 0:
		add = SUBLIME_ESSENCE_ELITE
	var before := _mank_essence
	_mank_essence = mini(_mank_essence + add, SUBLIME_ESSENCE_MAX)
	if _mank_essence == SUBLIME_ESSENCE_MAX and before < SUBLIME_ESSENCE_MAX:
		EventBus.emit_mechanics_intro("毒核完全体：万毒噬界 270%")
		DebugStats.count(&"mank_essence_capped")
	elif _mank_essence in [10, 20] and before < _mank_essence:
		EventBus.emit_mechanics_intro(
			"毒核吞噬：腐化精华 %d/%d" % [_mank_essence, SUBLIME_ESSENCE_MAX])


func weapon_muzzle_global(p_weapon: WeaponBase, p_no_screen_clamp: bool = false) -> Vector2:
	# R25 发射口对齐（用户点名「发射口和对应武器对不上」禁令）：子弹出膛点 =
	# 该武器悬浮化身的当前位置；化身不可用 → 回退武器本体位（玩家中心）。
	# R253（R201 评审缓办清账·激光豁免）：p_no_screen_clamp=true 跳过 12px 屏幕钳制——
	# 钳制目的是防弹丸从屏外出生（回收边界），激光是束纯视觉锚点，贴边束锚被拉回
	# 屏内 12px 会与化身脱钩（R201 评审 low 遗留）；仅激光族传 true，弹道五族保持。
	if orbit_avatars != null and is_instance_valid(orbit_avatars):
		var pos: Variant = orbit_avatars.avatar_global(p_weapon)
		if pos != null:
			if p_no_screen_clamp:
				return pos as Vector2
			var size := Vector2(720.0, 1280.0)
			if GameConfig.balance != null:
				size = Vector2(GameConfig.balance.res_logic)
			return (pos as Vector2).clamp(Vector2.ONE * 12.0, size - Vector2.ONE * 12.0)
	return p_weapon.global_position


func weapon_avatar_sortie(p_weapon: WeaponBase, p_target: Vector2) -> void:
	# 二cu 法器合一（用户「原本环绕的那个就是跑去砍人那个」）：法器开火即化身出击——
	# 环绕化身本身扑向攻击位再回环（W10 回旋刃出击读感为标杆，W11/W12 消费）。
	# 纯表现通道：化身层无该武器化身（不可见/未建）静默无操作
	if orbit_avatars != null and is_instance_valid(orbit_avatars):
		orbit_avatars.begin_sortie(p_weapon, p_target)


func _clamp_to_playfield_pos(p_pos: Vector2) -> Vector2:
	var size: Vector2 = Vector2(720.0, 1280.0)
	if GameConfig.balance != null:
		size = Vector2(GameConfig.balance.res_logic)
	return Vector2(clampf(p_pos.x, 24.0, size.x - 24.0), clampf(p_pos.y, 24.0, size.y - 24.0))


func has_skill() -> bool:
	# 玩家侧「有无主动技能」读口（HUD 技能键置灰 / activate_skill 早退共用）：
	# 真源 = CharacterTable 条目 no_skill 键（无技能角色如改造者·枢置 true——
	# 8 旧角色无此键 → 恒 true，零回归）。CharacterTable 若落地 static has_skill
	# 则同源同语义，两读口不冲突
	return not bool(CharacterTable.get_character(character_id).get("no_skill", false))


func skill_ready() -> bool:
	return skill_cd_left <= 0.0 and not _dead


func _reset_skill_temp_state() -> void:
	# 技能临时态收口（换角色/重开共用）：毒云清零 + 僚机到期还原（武器可能已被重开清场
	# 回收——_summon_restore 内有 is_instance_valid 守卫）。
	# ★R187 刻意不含镜面：_mirror_images 是永久会话态（验收 2 反向断言——本函数执行后
	# _summon_copies 空而 _mirror_images 原样）；镜面回收只在 clear_mirrors（重开/换局）。
	var cloud_was_active := _poison_cloud_left > 0.0
	_poison_cloud_left = 0.0
	_poison_cloud_tick_left = 0.0
	if cloud_was_active:
		EventBus.emit_poison_cloud_end()   # R199 H01：换角/重开清毒云同样收口（fx 层即入渐隐）
	_summon_restore()
	# ── R246 升华会话态收口（换角/重开共用；skill_sublime 本身不在此清——随 set_character
	#    复位区/继续局回填契约走卡系统侧，见 enable_sublime 注释）──
	_sub_field_left = 0.0                     # sentinel 力场
	_sub_field_tick_left = 0.0
	_sub_absorb_gate_left = 0.0
	_sub_absorb_reduced = 0.0
	if EventBus.enemy_killed.is_connected(_on_enemy_killed_overload):
		EventBus.enemy_killed.disconnect(_on_enemy_killed_overload)   # veles 余热监听
	_heat_stacks = 0
	_heat_drop_left = 0.0
	_overload_ramp_t = 0.0
	_stomp_aftershock_pulses = 0              # bulwark 余震窗
	_stomp_aftershock_left = 0.0
	_stomp_barrier = 0.0                      # 磐岩护壁（纯会话态零存档——dr_left 先例）
	_shadow_fuses.clear()                     # ranger 残影
	_lurk_stacks = 0
	_lurk_timer = 0.0
	_ts_left = 0.0                            # zero 力场窗
	_ts_bonus = 0.0
	if EventBus.enemy_killed.is_connected(_on_enemy_killed_timestop):
		EventBus.enemy_killed.disconnect(_on_enemy_killed_timestop)
	_mank_essence = 0                         # mank 腐化精华（层数不保真——位保真层数不保）
	_poison_stack_table.clear()               # vera 毒蚀层表
	_poison_catalysis_pending = false
	_echo_stacks = 0                          # echo 回声层/余韵（rof 复位两口现成：:623/:1283）
	_echo_afterglow_left = 0.0
	_resonance_stacks = 0                     # noah 共鸣书（_summon_restore 刻意不清层——此处随局清）
	_resonance_time_bonus = 0.0
	_dr_window_left = 0.0                     # medic 减伤窗
	_vortex_left = 0.0                        # vortex 奇点窗
	if _reaper_left > 0.0:                    # reaper 伤害窗（提前收口须还原 extern atk 乘区）
		_reaper_left = 0.0
		_apply_reaper_buffs(false)


func activate_skill() -> bool:
	# 角色主动技能（HUD 技能键调用；冷却中 false）
	if not skill_ready():
		return false
	if not has_skill():
		return false               # 无技能角色（改造者·枢契约）：不置 CD、不发 skill_cast、不计数
	skill_cd_left = skill_cd_base
	match character_id:
		&"sentinel":
			if skill_sublime:
				# R246 绝对屏障：无敌/护盾泡 3→5s + 力场权威计时（吸收节拍随施放复位）
				invuln_left = maxf(invuln_left, SUBLIME_FIELD_DURATION)
				_skill_shield_left = SUBLIME_FIELD_DURATION
				_sub_field_left = SUBLIME_FIELD_DURATION
				_sub_field_tick_left = 0.0        # 首跳即刻（挂场即有反馈）
				_sub_absorb_gate_left = 0.0
				_sub_absorb_reduced = 0.0
			else:
				invuln_left = maxf(invuln_left, 3.0)
				_skill_shield_left = 3.0
		&"veles":
			if skill_sublime:
				# R246 临界过载：5s 窗，rof_mult 由 2.0 线性爬升至 3.2；击杀计余热层
				_overload_ramp_t = 0.0
				rof_mult = SUBLIME_ROF_START
				skill_active_left = SUBLIME_WINDOW
				_heat_stacks = 0                  # 重施放兜底清层（防极端 CDR 下跨周期残留）
				_heat_drop_left = 0.0
				if not EventBus.enemy_killed.is_connected(_on_enemy_killed_overload):
					EventBus.enemy_killed.connect(_on_enemy_killed_overload)
				refresh_weapon_intervals()
			else:
				rof_mult = 2.0
				skill_active_left = 4.0
				refresh_weapon_intervals()   # R29：过载开启瞬间武器倒计时立刻按新节拍缩短
		&"bulwark":
			if skill_sublime:
				# R246 余震壁垒：主震更猛 + 播种 1s × 3 跳余震窗
				_stomp_pulse(300.0, 380.0, 340.0, 40, true)
				_stomp_aftershock_pulses = STOMP_AFTERSHOCK_PULSES
				_stomp_aftershock_left = STOMP_AFTERSHOCK_INTERVAL
			else:
				_stomp_pulse(220.0, 280.0, 260.0, 24, false)
		&"ranger":
			if skill_sublime:
				_skill_shadow_dash()              # R246 百影穿袭
			else:
				var dir := _last_move_dir if _last_move_dir != Vector2.ZERO else Vector2.UP
				global_position += dir * 260.0
				# R246 越界回弹修复：瞬步落点改与移动同口径的活动区钳制（_clamp_to_playfield，
				# y 钳下 40% 屏）。原 _clamp_to_playfield_pos 全屏界（y≥24）放行越活动区落点，
				# 下一帧 tick 的活动区钳制（y≥768）再拉回——向上瞬步承诺 260px 实兑 ~32px
				# 且伴随一帧回弹抖动；统一口径后向上瞬步停在活动区上界（净位移最大化、零回弹）。
				_clamp_to_playfield()
				invuln_left = maxf(invuln_left, 1.0)
		&"zero":
			if skill_sublime:
				_skill_time_stop_sublime()        # R246 时滞奇点
			else:
				_skill_time_stop()
		&"mank":
			_skill_poison_nova()
		&"vera":
			_skill_poison_cloud()
		&"noah":
			_skill_summon_orbs()
		&"echo":
			if skill_sublime:
				# R246 无尽回响：双生和弦施放瞬间快照武器 id（第二槽空 → 按异款兜底）
				var id0 := _chord_id(0)
				var id1 := _chord_id(1)
				_echo_chord_homo = id0 != "" and id0 == id1
				_echo_stacks = 0
				rof_mult = ECHO_SUBLIME_MULT_HOMO if _echo_chord_homo else ECHO_SUBLIME_MULT_HETERO
				if _echo_chord_homo:
					EventBus.emit_mechanics_intro("【同频共振】双生回响·同款共鸣：射速 +90%！")
			else:
				rof_mult = 1.5                    # 双生回响：5s 全武器射速 +50%（复用 veles 射速窗通道）
			skill_active_left = 5.0
			refresh_weapon_intervals()            # 开启瞬间武器倒计时立刻按新节拍缩短（R29 同款）
		&"medic":
			# R246 医疗矩阵：回复 30% max_hp + 4s 减伤窗（×0.5，与无敌独立）
			hp = minf(hp + MEDIC_HEAL_PCT * max_hp, max_hp)
			_dr_window_left = MEDIC_DR_WINDOW
		&"vortex":
			# R246 奇点：3s 向心牵引（首帧即拉）+ 窗尽末爆
			_vortex_left = VORTEX_SINGULARITY_DURATION
			_vortex_tick_count = 1
			_vortex_pull()
		&"reaper":
			# R246 收割窗：6s 全武器伤害窗（extern atk 乘区 +50%，启停遍历失效面板）
			_reaper_left = REAPER_WINDOW
			_apply_reaper_buffs(true)
	var fx_dur := _skill_fx_duration()
	_skill_fx_left = fx_dur
	_skill_fx_max = fx_dur
	EventBus.emit_skill_cast(global_position, String(character_id))   # 施放金环爆发（表现层）
	DebugStats.count(&"skill_used")
	return true


func _skill_fx_duration() -> float:
	# 技能演出时长（R19：增益型 = 效果持续时间，瞬发型 = 0.8s 施放闪光——
	# 「效果何时结束」一眼可读：HUD 时长条 + 玩家光环同步倒数）
	match character_id:
		&"sentinel":
			return SUBLIME_FIELD_DURATION if skill_sublime else 3.0   # R246：金环/HUD 与 5s 力场同步
		&"veles":
			return SUBLIME_WINDOW if skill_sublime else 4.0           # R246：临界过载 5s 窗
		&"bulwark":
			return BULWARK_SUBLIME_FX if skill_sublime else 0.8       # R246：时长条盖余震窗
		&"ranger":
			return RANGER_SUBLIME_FX if skill_sublime else 0.8        # R246：含残影爆窗
		&"zero":
			return TS_WINDOW if skill_sublime else 0.8                # R246：增益窗型演出（延展续命见 _on_enemy_killed_timestop）
		&"vera":
			return POISON_CLOUD_SUBLIME_DURATION if skill_sublime else POISON_CLOUD_DURATION
		&"noah":
			return (SUBLIME_SUMMON_DURATION + _resonance_time_bonus) if skill_sublime else SUMMON_DURATION
		&"echo":
			return 5.0                            # 双生回响增益窗（HUD 时长条 + 金弧同步倒数；升华余韵段 _echo_enter_afterglow 内续接）
		&"medic":
			return MEDIC_DR_WINDOW                # R246：减伤窗 4s
		&"vortex":
			return VORTEX_SINGULARITY_DURATION    # R246：奇点 3s
		&"reaper":
			return REAPER_WINDOW                  # R246：收割窗 6s
	return 0.8


func skill_active_ratio() -> float:
	# 技能效果剩余比例 0~1（HUD 时长条消费；瞬发型 0.8s 施放闪光共用通道）
	if _skill_fx_max <= 0.0:
		return 0.0
	return clampf(_skill_fx_left / _skill_fx_max, 0.0, 1.0)


# ══ R246 技能升华：统一授予口 + 各角色新函数（真源 docs/design/sublime/*.md）══════
func add_fallback_atk(p_pct: float) -> void:
	# R262d 应急强化全局授予口（三产口统一收束：卡池耗尽保底卡/词条栏满转化/黑市常青货——
	# 用户裁定「攻击力是全局的」：原挂单武器栈只加一把武器，现全武器共享）。数值线：每层
	# 全额累加（R226 起全池无衰减——decay_delta=0.85 是遗留记账键非生效机制），品级区分在
	# 产口侧按 RARITY_VALUE_SCALE 缩放后传入。重推复用 _apply_resonance(-1) 静默口——
	# 本命/非本命两态 target_pct 注入序同源（含 fallback 成分）。
	if p_pct == 0.0:
		return
	run_fallback_atk_pct += p_pct
	DebugStats.count(&"fallback_atk_stack")
	_apply_resonance(-1)


func enable_sublime() -> void:
	# 升华统一入口（卡系统唯一授予口；幂等——已升华零副作用）。内部置位后按角色分发
	# 初始化：fission 走替代分支含追溯回填（本局已击杀 ×0.5 折层，帽 500——「晚抽不亏」）；
	# 其余角色无预建派生态（全部施放时惰性归零，授予时机早晚零影响）。
	# 生命周期：set_character 复位区清 false（换角/重开）；继续局由 _restore_run_state 在
	# set_character 之后回填本口（先清后回，R212 skill_cd 同款恢复序）。
	if skill_sublime:
		return
	skill_sublime = true
	if character_id == &"fission":
		_reson_layers = mini(int(round(float(_reson_kill_count) * SUBLIME_BACKFILL)),
			SUBLIME_RESON_CAP)
		_apply_resonance(-1)                    # -1 = 静默注入（抽卡横幅归卡面；改装件横幅才走档位跨越口）
		refresh_skill_cd()                      # M3 折算参数变化即时重算（comp 变化内部自刷节拍）


func _on_enemy_killed_overload(_p_enemy: Node2D) -> void:
	# R246 临界过载·余热计层：仅升华 veles 的窗口内击杀计层（僚机/毒云等玩家侧输出同算）
	if skill_sublime and character_id == &"veles" and skill_active_left > 0.0:
		_heat_stacks = mini(_heat_stacks + 1, HEAT_STACK_MAX)


func _chord_id(p_i: int) -> String:
	# R246 双生和弦快照读口：第 p_i 槽武器 data.id（空槽/已回收 → ""）
	if p_i >= weapon_slots.size():
		return ""
	var w: Variant = weapon_slots[p_i]
	if w != null and is_instance_valid(w) and w is WeaponBase and (w as WeaponBase).data != null:
		return String((w as WeaponBase).data.id)
	return ""


func _echo_enter_afterglow() -> void:
	# R246 渐弱余韵：主窗归零 → 1.35 定值 + 层×(0.5|0.6)s（帽 3.0|3.6）；fx 续接
	#（比率读口零改动——_skill_fx_* 重置即 HUD 时长条/光环倒数无缝续接）
	var per := ECHO_SUBLIME_AFTERGLOW_PER if _echo_chord_homo \
		else ECHO_SUBLIME_AFTERGLOW_PER_HETERO
	var cap := ECHO_SUBLIME_AFTERGLOW_CAP + (0.6 if not _echo_chord_homo else 0.0)
	_echo_afterglow_left = minf(float(_echo_stacks) * per, cap)
	rof_mult = ECHO_SUBLIME_AFTERGLOW_MULT
	refresh_weapon_intervals()                # R29：换挡立即生效
	_skill_fx_left = _echo_afterglow_left
	_skill_fx_max = maxf(_echo_afterglow_left, 0.01)


func _on_echo_kill_stack(_p_enemy: Node2D) -> void:
	# R246 回声叠响（_ready 常驻订阅 + flag 守卫）：仅主窗内叠层（余韵期/封顶短路）
	if not (skill_sublime and character_id == &"echo"):
		return
	if skill_active_left <= 0.0 or _echo_stacks >= ECHO_SUBLIME_STACK_CAP:
		return
	_echo_stacks += 1
	if not _echo_chord_homo:                   # 双声部：层微增主窗（同频共振不吃层）
		rof_mult = minf(rof_mult + ECHO_SUBLIME_PER_STACK,
			ECHO_SUBLIME_MULT_HETERO + ECHO_SUBLIME_PER_STACK * ECHO_SUBLIME_STACK_CAP)
		refresh_weapon_intervals()             # 层数变化瞬间节拍同步


func _on_resonance_kill(_p_enemy: Node2D) -> void:
	# R246 军械共鸣（_ready 常驻订阅 + flag/窗双守卫）：窗口内全场击杀 +1 层（帽 40）——
	# 信号不带击杀者（enemy_killed 广播无来源通道），按「僚机在场期间的全场击杀」计
	if not (skill_sublime and character_id == &"noah"):
		return
	if _summon_left <= 0.0:
		return                                 # 窗外击杀不计
	if _resonance_stacks >= RESONANCE_MAX:
		return
	_resonance_stacks += 1
	_apply_resonance_mult()                    # 即时火力回写（当帧生效，下一发弹吃满）
	# 恋战延时：跨 5 层阈值即时 +1s（帽 +8s）——窗长/时长条/舰体寿命三处同帧同涨
	var target := minf(floorf(float(_resonance_stacks) / float(RESONANCE_TIME_PER)),
		RESONANCE_TIME_BONUS_CAP)
	if target > _resonance_time_bonus:
		var gain := target - _resonance_time_bonus
		_resonance_time_bonus = target
		_summon_left += gain                   # tick 到期段零改动即消费
		_skill_fx_left += gain                 # HUD 时长条/光环倒数同步延长
		_skill_fx_max += gain
		for d in _summon_drones:               # 舰体寿命随窗同步（不提前离场——修订③）
			if d != null and is_instance_valid(d):
				d.set("_life_left", float(d.get("_life_left")) + gain)


func _apply_resonance_mult() -> void:
	# R246 共鸣乘区即时回写：副本 meta_atk_pct = 施放基准快照 + 1.5%×层（幂等可重入——
	# 基准防叠错）；护航舰无字段，_fire_at_nearest 开火时现读层数
	if _summon_meta_base.size() != _summon_copies.size():
		return                                 # 基准缺失（旧窗副本）——防越界
	var bonus := RESONANCE_DMG_PER_STACK * float(_resonance_stacks)
	for i in _summon_copies.size():
		var c := _summon_copies[i]
		if c != null and is_instance_valid(c):
			c.meta_atk_pct = _summon_meta_base[i] + bonus


func _skill_shadow_dash() -> void:
	# R246 百影穿袭（游侠·岚·升华）：先按潜影层算参数，再位移/结算，最后消耗层（顺序不可倒）
	var dir := _last_move_dir if _last_move_dir != Vector2.ZERO else Vector2.UP
	var from := global_position
	var dist := SHADOW_DASH_BASE_DIST + SHADOW_DASH_DIST_PER_LURK * float(_lurk_stacks)
	var dmg_pct := SHADOW_DASH_ATK_BASE + SHADOW_DASH_ATK_PER_LURK * float(_lurk_stacks)
	global_position += dir * dist
	_clamp_to_playfield()                    # 活动区钳制单一真源（R246 越界回弹修复口径）
	invuln_left = maxf(invuln_left, SHADOW_DASH_INVULN)
	var to := global_position
	_shadow_sweep_damage(from, to, dmg_pct)  # M1 路径结算（uid 去重）
	_shadow_fuses.append({"pos": from, "left": SHADOW_ECHO_FUSE})             # M2 起点残影
	_shadow_fuses.append({"pos": from.lerp(to, 0.5), "left": SHADOW_ECHO_FUSE})  # M2 中点残影
	_lurk_stacks = 0                         # M3 施放消耗
	_lurk_timer = 0.0


func _shadow_sweep_damage(p_from: Vector2, p_to: Vector2, p_dmg_pct: float) -> void:
	# R246 穿袭路径结算：胶囊近似（沿线 64px 步进 56px 圆查询）+ uid 去重——同敌只结一次；
	# 结算口径 = _skill_poison_nova（AOE_SECONDARY + KIN + crit 0 + 遗物注入 + pipeline）
	var grid: Variant = _deps.get("enemy_grid")
	var pipeline: Variant = _deps.get("pipeline")
	var w0: Variant = weapon_slots[0] if weapon_slots.size() > 0 else null
	if grid == null or w0 == null:
		return
	var base := float((w0 as WeaponBase).build_panel_snapshot().get("base_atk", 0.0))
	var steps := int(ceilf(p_from.distance_to(p_to) / SHADOW_SWEEP_STEP)) + 1
	var hit_uids := {}
	for i in range(steps + 1):
		var c := p_from.lerp(p_to, float(i) / float(maxi(steps - 1, 1)))
		for e in (grid as SpaceGrid).query_circle(c, SHADOW_SWEEP_RADIUS):
			if e == null or bool(e.get("dead")) or hit_uids.has(int(e.get("uid"))):
				continue
			hit_uids[int(e.get("uid"))] = true
			var ctx := DamageContext.make()
			ctx.source_uid = int(get_instance_id())  # 玩家侧幂等键（mank/vera 同口径）
			ctx.target = e
			ctx.target_uid = int(e.get("uid"))
			ctx.frame_stamp = GameConfig.frame_stamp
			ctx.base_atk = base * p_dmg_pct
			ctx.element = GameConst.Element.KIN
			ctx.hit_flags |= GameConst.HIT_IS_AOE_SECONDARY
			ctx.crit_chance = 0.0
			ctx.pos = (e as Node2D).global_position
			_inject_relic_pools(ctx, e)
			if pipeline != null and (pipeline as Object).has_method(&"resolve"):
				pipeline.call(&"resolve", ctx)
	if not hit_uids.is_empty():
		DebugStats.count(&"shadow_dash_sweep")


func _shadow_echo_blast(p_pos: Vector2) -> void:
	# R246 残影爆：150px 结算 120% ATK + 向外击退 160（_stomp_pulse 模板）
	#          + 110px 拂弹帽 6（team==1 才清——stomp 清弹段模板）
	var grid: Variant = _deps.get("enemy_grid")
	var pipeline: Variant = _deps.get("pipeline")
	var base := _weapon0_base_atk()
	if grid != null and base > 0.0 and pipeline != null \
			and (pipeline as Object).has_method(&"resolve"):
		for e in (grid as SpaceGrid).query_circle(p_pos, SHADOW_ECHO_RADIUS):
			if e == null or bool(e.get("dead")):
				continue
			var ctx := DamageContext.make()
			ctx.source_uid = int(get_instance_id())
			ctx.target = e
			ctx.target_uid = int(e.get("uid"))
			ctx.frame_stamp = GameConfig.frame_stamp
			ctx.base_atk = base * SHADOW_ECHO_ATK
			ctx.element = GameConst.Element.KIN
			ctx.hit_flags |= GameConst.HIT_IS_AOE_SECONDARY
			ctx.crit_chance = 0.0
			ctx.pos = (e as Node2D).global_position
			_inject_relic_pools(ctx, e)
			(pipeline as Object).call(&"resolve", ctx)
			if e.has_method(&"knockback"):
				e.call(&"knockback",
					((e as Node2D).global_position - p_pos).normalized() * SHADOW_ECHO_KNOCK)
	var bgrid: Variant = _deps.get("enemy_bullet_grid")
	if bgrid == null:
		return
	var cleared := 0
	for b in (bgrid as SpaceGrid).query_circle(p_pos, SHADOW_ECHO_CLEAR_R):
		if b is ProjectileBase and (b as ProjectileBase).team == 1:
			EventBus.emit_bullet_nullified((b as Node2D).global_position)
			(b as ProjectileBase).nullify()
			cleared += 1
		if cleared >= SHADOW_ECHO_CLEAR_CAP:
			break


func _on_enemy_killed_resonance(p_enemy: Node2D) -> void:
	# R246 本命同调·M1 叠层（_ready 常驻订阅；死因不区分——改造者从战场数据学习）：
	# 普通 +1 / 精英 +3 / Boss·终 +15，帽 500。原始计数器先递增（run 作用域——enable_sublime
	# 追溯回填源，未升华期照常计数）；未升华态零层计（纯增量守卫）
	if character_id != &"fission":
		return
	_reson_kill_count += 1
	if not skill_sublime or _reson_layers >= SUBLIME_RESON_CAP:
		return
	var gained := 1
	# 分档读死亡瞬间快照（账本优先——本订阅派发位在 spawner 归还之后，尸身 tags 已清 0）
	var tags := int(_kill_snap(p_enemy).get("tags", 0))
	if (tags & (GameConst.TAG_BOSS | GameConst.TAG_FINAL_BOSS)) != 0:
		gained = 15
	elif (tags & GameConst.TAG_ELITE) != 0:
		gained = 3
	var before := _reson_layers
	_reson_layers = mini(_reson_layers + gained, SUBLIME_RESON_CAP)
	_apply_resonance(before)                 # before 传入 = 档位跨越检测用


func _reson_atk_extra() -> float:
	# R246 本命武装攻击加区（M4 即时糖 + M1 层数 + Ω-弹匣；非升华恒 0 = 其余角色零位移）
	if not skill_sublime:
		return 0.0
	var pct := SUBLIME_INSTANT_ATK + _reson_layers * SUBLIME_RESON_PER_LAYER
	for part in SUBLIME_MODPARTS:            # 攻击类档位走表（未来加档只改表）
		if _reson_layers >= int(part.at) and part.has("atk"):
			pct += float(part.atk)
	return pct


func _modpart_buffs() -> Dictionary:
	# R246 本命武装质量/攻速注入口（Ω-推进/聚焦/火控/超频；空表 = 零位移）
	var out := {}
	if skill_sublime:
		for part in SUBLIME_MODPARTS:
			if _reson_layers >= int(part.at):
				for key in [&"spd", &"size", &"crit", &"rof"]:
					if part.has(key):
						out[key] = float(out.get(key, 0.0)) + float(part[key])
	return out


func _apply_resonance(p_prev_layers: int) -> void:
	# R246 注入：遍历 weapon_slots，data.id == 本命 id 者重写 meta_atk_pct（照 set_character
	# :626-630 注入模式含 _invalidate_panel）+ extern_buffs 质量/攻速乘区（weapon_base 4 读点）
	var sig := _signature_weapon_id()
	var buffs := _modpart_buffs()
	var atk_extra := _reson_atk_extra()
	for w in weapon_slots:
		# ★守卫序：is_instance_valid 在前（freed 实例上后续取值报脚本错——:628 先例注释）
		if w == null or not is_instance_valid(w) or w is not WeaponBase or w.data == null:
			continue
		var mine := StringName(String(w.data.id)) == sig
		var target_pct := Meta.atk_pct() + character_atk_pct + run_fallback_atk_pct \
				+ (atk_extra if mine else 0.0)
		if not is_equal_approx(w.meta_atk_pct, target_pct):
			w.meta_atk_pct = target_pct
			w.call(&"_invalidate_panel")       # 面板失效（weapon_base build_panel_snapshot 消费）
		var want_buffs: Dictionary = buffs if mine else {}
		if w.extern_buffs != want_buffs:
			w.extern_buffs = want_buffs        # 质量/攻速注入口（weapon_base 4 读点消费）
			w.call(&"refresh_fire_interval")   # R29：Ω-超频 rof 档跨即刻拍刷新（变长不回罚）
	# 档位跨越横幅（装载瞬间一次性；p_prev_layers=-1 静默口——enable_sublime 回填/换装重注入）
	if p_prev_layers >= 0:
		for part in SUBLIME_MODPARTS:
			if p_prev_layers < int(part.at) and _reson_layers >= int(part.at):
				EventBus.emit_mechanics_intro("【改装件装载】%s（本命武装强化）" % part.name)


func _signature_weapon_id() -> StringName:
	# R246 本命仲裁 = 首发仲裁同源（Meta.custom_weapon → 兜底 W1_pistol；game_loop
	# _starting_weapon_id 同口径）。slot0 活体优先（对账双保险后必为本命）；
	# 脏 id 由 GameLoop 装备期兜底成 W1，局内 slot0 实际 id 即真相
	var s0: Variant = weapon_slots[0] if weapon_slots.size() > 0 else null
	if s0 != null and is_instance_valid(s0) and s0 is WeaponBase \
			and (s0 as WeaponBase).data != null:
		return StringName(String((s0 as WeaponBase).data.id))
	var saved := Meta.custom_weapon()
	return saved if saved != &"" else &"W1_pistol"


func resonance_snapshot() -> Dictionary:
	# R246 存档读口（卡系统 serialize_run "sublime" 键透传）：{on, fission_layers}
	return {"on": skill_sublime, "fission_layers": _reson_layers}


func restore_resonance(p_data: Dictionary) -> void:
	# R246 续档回填口（幂等：仅升华位为真时生效；clampi 防旧档脏值——R212 skill_cd 同款）
	if not skill_sublime:
		return
	_reson_layers = clampi(int(p_data.get("fission_layers", 0)), 0, SUBLIME_RESON_CAP)
	_apply_resonance(-1)
	refresh_skill_cd()


func _vortex_pull() -> void:
	# R246 奇点·向心牵引：以玩家为心 320px 内敌人向心击退（每 2 物理帧一拉——降频防
	# 物理帧级 knockback 调用堆积；Boss 免疫/精英 ×0.35 由 enemy.knockback 自动继承）
	var grid: Variant = _deps.get("enemy_grid")
	if grid == null:
		return
	for e in (grid as SpaceGrid).query_circle(global_position, VORTEX_PULL_RADIUS):
		if e == null or bool(e.get("dead")):
			continue
		if e.has_method(&"knockback"):
			e.call(&"knockback",
				(global_position - (e as Node2D).global_position).normalized()
				* VORTEX_PULL_FORCE)


func _vortex_blast() -> void:
	# R246 奇点·末爆：窗尽 220px 结算 120% 主武器 ATK（照 nova 结算模板）
	var grid: Variant = _deps.get("enemy_grid")
	var pipeline: Variant = _deps.get("pipeline")
	var base := _weapon0_base_atk()
	if grid == null or pipeline == null or not (pipeline as Object).has_method(&"resolve"):
		return
	for e in (grid as SpaceGrid).query_circle(global_position, VORTEX_BLAST_RADIUS):
		if e == null or bool(e.get("dead")):
			continue
		var ctx := DamageContext.make()
		ctx.source_uid = int(get_instance_id())
		ctx.target = e
		ctx.target_uid = int(e.get("uid"))
		ctx.frame_stamp = GameConfig.frame_stamp
		ctx.base_atk = base * VORTEX_BLAST_ATK
		ctx.element = GameConst.Element.KIN
		ctx.hit_flags |= GameConst.HIT_IS_AOE_SECONDARY
		ctx.crit_chance = 0.0
		ctx.pos = (e as Node2D).global_position
		_inject_relic_pools(ctx, e)
		(pipeline as Object).call(&"resolve", ctx)
	EventBus.emit_kill_blast(global_position, VORTEX_BLAST_RADIUS)


func _apply_reaper_buffs(p_on: bool) -> void:
	# R246 收割窗启停：全武器 extern atk 乘区 ±50% + 面板失效（atk 无 rof——节拍不刷新）
	var want: Dictionary = {&"atk": REAPER_ATK_BUFF} if p_on else {}
	for w in weapon_slots:
		if w != null and is_instance_valid(w) and w is WeaponBase:
			if (w as WeaponBase).extern_buffs != want:
				(w as WeaponBase).extern_buffs = want
				(w as WeaponBase).call(&"_invalidate_panel")


func _skill_poison_cloud() -> void:
	# 毒云领域（毒系学者·薇拉）：以玩家为中心 300px 持续 6s，域内敌每 0.5s 受 8% 主武器
	# ATK 毒伤 + 减速 20%。★ 直结算通道（方案裁定，注释真源）：每跳独立 DamageContext 走
	# 管线 resolve（AOE_SECONDARY 幂等键——同构 mank 毒沼绽放先例），不挂 ElementalState
	# 附着（不动元素管线）；减速走 Enemy.ext_slow 外部乘区（与元素冰缓正交、到期自动还原）。
	if skill_sublime:
		# R246 毒理学终章：7s 窗 + 清层表（cast 先清层幂等口径，防极端 CDR 重掷残层）；
		# fx 层 cast 时长随升华窗 7.0（普通版缺省 6.0）
		_poison_cloud_left = POISON_CLOUD_SUBLIME_DURATION
		_poison_stack_table.clear()
		_poison_catalysis_pending = false
		EventBus.emit_poison_cloud_cast(global_position, _cloud_radius_now(),
			POISON_CLOUD_SUBLIME_DURATION)
	else:
		_poison_cloud_left = POISON_CLOUD_DURATION
		EventBus.emit_poison_cloud_cast(global_position, POISON_CLOUD_RADIUS)   # R10 毒云特效
	_poison_cloud_tick_left = 0.0               # 首跳即刻生效（挂场即有反馈）
	_poison_cloud_pulse()


func _cloud_radius_now() -> float:
	# R246 领域滋生：300 → 390 线性插值（普通版恒 300）——query/emit/fx 三方同源
	if not skill_sublime:
		return POISON_CLOUD_RADIUS
	var t := 1.0 - _poison_cloud_left / POISON_CLOUD_SUBLIME_DURATION
	return lerpf(POISON_CLOUD_RADIUS, POISON_CLOUD_SUBLIME_RADIUS_END, clampf(t, 0.0, 1.0))


func _poison_stack_layers(p_e: Variant) -> int:
	# R246 毒蚀层数读口（无记录 = 0；死敌条目惰性回收——is_instance_valid 先于取字段）
	var uid := int(p_e.get("uid"))
	var rec: Variant = _poison_stack_table.get(uid)
	if rec == null:
		return 0
	var e: Variant = (rec as Dictionary).get("e")
	if not is_instance_valid(e) or bool(e.get("dead")):
		_poison_stack_table.erase(uid)
		return 0
	return int((rec as Dictionary).get("layers"))


func _poison_stack_add(p_e: Variant) -> void:
	# R246 毒蚀叠层：每跳结算后 +1 层（帽 12）——层数记敌人个体，后进域从 0 起算
	var uid := int(p_e.get("uid"))
	if not _poison_stack_table.has(uid):
		_poison_stack_table[uid] = {"e": p_e, "layers": 0}
	var rec: Dictionary = _poison_stack_table[uid]
	rec["layers"] = mini(int(rec.get("layers")) + 1, POISON_STACK_MAX)


func _poison_catalysis_burst() -> void:
	# R246 催化解离：领域消散瞬间对所有带层敌人（不限域内——毒已入体）按层数终结结算后清层；
	# 错帧执行（tick 顶部 pending）——末跳与窗归零同帧会被管线幂等键 (source,target,frame) 吞跳
	var pipeline: Variant = _deps.get("pipeline")
	var base := _weapon0_base_atk()
	for uid in _poison_stack_table.keys():
		var rec: Variant = _poison_stack_table[uid]
		var e: Variant = (rec as Dictionary).get("e")
		if not is_instance_valid(e) or bool(e.get("dead")):
			continue
		var layers := int((rec as Dictionary).get("layers"))
		if layers <= 0 or base <= 0.0 or pipeline == null \
				or not (pipeline as Object).has_method(&"resolve"):
			continue
		var ctx := DamageContext.make()
		ctx.source_uid = int(get_instance_id())   # 与毒云跳同口径（已错帧，键不冲突）
		ctx.target = e
		ctx.target_uid = int(e.get("uid"))
		ctx.frame_stamp = GameConfig.frame_stamp
		ctx.base_atk = base * POISON_CATALYSIS_PER_STACK * layers
		ctx.element = GameConst.Element.KIN       # 无元素通道（D14 同批口径）
		ctx.hit_flags |= GameConst.HIT_IS_AOE_SECONDARY
		ctx.crit_chance = 0.0
		ctx.pos = (e as Node2D).global_position
		_inject_relic_pools(ctx, e)
		(pipeline as Object).call(&"resolve", ctx)
	_poison_stack_table.clear()
	DebugStats.count(&"poison_catalysis_burst")


func _weapon0_base_atk() -> float:
	# 主武器面板快照抽取（nova/cloud 的 w0 读取同源——催化结算复用）
	var w0: Variant = weapon_slots[0] if weapon_slots.size() > 0 else null
	if is_instance_valid(w0) and w0 is WeaponBase:
		return float((w0 as WeaponBase).build_panel_snapshot().get("base_atk", 0.0))
	return 0.0


func _poison_cloud_pulse() -> void:
	# 毒云单跳：网格圆查询 → 刷新减速窗 + 逐敌结算毒伤（域外敌由 ext_slow_left 到期自愈）
	var grid: Variant = _deps.get("enemy_grid")
	var pipeline: Variant = _deps.get("pipeline")
	var w0: Variant = weapon_slots[0] if weapon_slots.size() > 0 else null
	if grid == null:
		return
	var base := 0.0
	if is_instance_valid(w0) and w0 is WeaponBase:
		base = float((w0 as WeaponBase).build_panel_snapshot().get("base_atk", 0.0))
	# R246 领域滋生：升华半径随窗成长（query/emit 同源 _cloud_radius_now）
	var radius := _cloud_radius_now()
	for e in (grid as SpaceGrid).query_circle(global_position, radius):
		if e == null or bool(e.get("dead")):
			continue
		# R246 毒蚀叠层：减速 20% + 每层 1.5pp（升华）；跳伤 +6%/层（结算前取层——首跳 0 层）
		var layers := _poison_stack_layers(e) if skill_sublime else 0
		var slow := POISON_CLOUD_SLOW + (POISON_STACK_SLOW_PER * layers if skill_sublime else 0.0)
		e.set("ext_slow_mult", 1.0 - slow)
		e.set("ext_slow_left", POISON_SLOW_REFRESH)
		if base <= 0.0 or pipeline == null or not (pipeline as Object).has_method(&"resolve"):
			continue
		var ctx := DamageContext.make()
		ctx.source_uid = int(get_instance_id())  # 玩家侧幂等键（Player 无 uid 字段——mank 同口径）
		ctx.target = e
		ctx.target_uid = int(e.get("uid"))
		ctx.frame_stamp = GameConfig.frame_stamp
		ctx.base_atk = base * POISON_CLOUD_ATK_PCT \
			* (1.0 + POISON_STACK_DMG_PER * layers if skill_sublime else 1.0)
		ctx.element = GameConst.Element.KIN      # R199 D14：毒云无元素通道（沿 mank 同批矫正——
		                                         # 原 FIR 口径被火免疫敌 elem_immune=2 拦零）
		ctx.hit_flags |= GameConst.HIT_IS_AOE_SECONDARY
		ctx.crit_chance = 0.0                    # 领域 DoT 不暴击（稳定期望口径）
		ctx.pos = (e as Node2D).global_position
		_inject_relic_pools(ctx, e)              # R199 D07：技能通道遗物乘区（管线⑤主通道直消费）
		pipeline.call(&"resolve", ctx)
		if skill_sublime:
			_poison_stack_add(e)                 # R246 毒蚀：结算后 +1 层（帽 12）
	DebugStats.count(&"poison_cloud_pulse")


func _skill_summon_orbs() -> void:
	# 召唤僚机（召唤师·诺亚，R183 用户重定义）：随机复制 2 把当前已装备武器——
	# 同数据/同等级/词条栈全量拷贝（含逐层品级数值与质变乘区），持续 10s；
	# 相当于临时多出两把武器在打（用户原话口径）。无武器可复制（异常防御）→
	# 仅 R93 护航舰随行。副本不占真实槽位（_summon_copies 独立数组——
	# 选卡目标/存档序列化/词条叠层判据均不受污染），悬浮环金色染色参战。
	# R246 叠层根治（R244 诊断·用户「武器会越叠越多」）：效果期内再施放（手动或
	# R241 自动施法在 CDR 堆叠下有效 CD<10s 窗）先回收旧副本/护航舰再重掷——
	# _summon_restore 内含 is_instance_valid 守卫 + ELE 反应乘区 unregister，
	# 对空数组幂等；语义=「刷新时长」而非「效果期内拒绝」，与全角色幂等口径对齐。
	_summon_restore()
	_summon_meta_base.clear()                    # R246：副本乘区基准快照（防重复叠加）
	# R246 万械共鸣（升华）：dur 先算（16s + 存量层数预支延时）——舰体寿命/HUD 时长条
	# 初值/_summon_left 三处同源（activate_skill 尾段经 _skill_fx_duration 再读预支值）
	var dur := SUMMON_DURATION
	if skill_sublime:
		_resonance_time_bonus = minf(floorf(float(_resonance_stacks)
			/ float(RESONANCE_TIME_PER)), RESONANCE_TIME_BONUS_CAP)
		dur = SUBLIME_SUMMON_DURATION + _resonance_time_bonus
	_spawn_fallback_drones(dur)                  # R246：舰体寿命=本窗 dur（拔 10s 硬编码）
	var pool: Array[WeaponBase] = []
	for w in weapon_slots:
		# R187 R183 互斥裁定：复制池排除 W5_prism——「临时件永不产出永久件」
		#（镜面在 _mirror_images 独立数组，本就不可复制；双保险防未来槽位化回潮）
		if w != null and is_instance_valid(w) and w.data != null \
				and String(w.data.id) != "W5_prism":
			pool.append(w)
	if pool.is_empty():
		_summon_left = dur                    # 仅护航舰（正常局恒有手枪，防御路径）
		DebugStats.count(&"summon_drones_fallback")
		return
	var copies_n := SUBLIME_SUMMON_COPIES if skill_sublime else SUMMON_COPIES
	for i in range(copies_n):
		var src := pool[randi() % pool.size()]
		var copy := _make_weapon_copy(src)
		if copy != null:
			# R220 刀6（折中方案）：副本组相位错开——cooldown_left = 节拍 × (组内序/组数)。
			# 本体组保留波首同拍（保齐射爽感），镜面/副本/僚机三组按序错帧削对齐帧；
			# 确定性推导零存档键（i=0 相位 0 = 现行为，i=N-1 至多延一拍内差）
			# R246：分母改读 copies_n（3 副本时 i=2 相位 2/3——原 /SUMMON_COPIES 撞整拍）
			if i > 0:
				copy.cooldown_left = copy._fire_interval() * (float(i) / float(copies_n))
			_summon_copies.append(copy)
			_summon_meta_base.append(src.meta_atk_pct)   # R246：共鸣乘区基准（施放即全额继承存量层）
	_summon_left = dur
	DebugStats.count(&"summon_orbs")
	# R183 复制播报（评审：弹幕里读不出「金了哪两个」）：施放即横幅点名复制的武器
	if not _summon_copies.is_empty():
		var names: Array[String] = []
		for c in _summon_copies:
			if c != null and c.data != null:
				names.append(String(c.data.display_name))
		if skill_sublime:
			# R246 万械共鸣：横幅带层数（书厚度一眼可读）
			EventBus.emit_mechanics_intro("万械共鸣：复制了 %s（共鸣 %d 层）"
				% [" + ".join(names), _resonance_stacks])
		elif names.size() == 2 and names[0] == names[1]:
			EventBus.emit_mechanics_intro("召唤僚机：复制了 %s ×2" % names[0])
		elif not names.is_empty():
			EventBus.emit_mechanics_intro("召唤僚机：复制了 %s" % " + ".join(names))


func _make_weapon_copy(p_src: WeaponBase) -> WeaponBase:
	# 武器副本构造（R183）：同 WeaponData / 同等级 / 同局外养成修正；词条栈走
	# copy_full（比 copy_runtime 多拷逐层品级数值——R12c 混合品级 ADD 池不回落基准值）。
	# R187 复制体折减裁定表（R187 设计文档 §一「R183 区分总裁定」统一表，逐武器落点）：
	# · W1 手枪：同 lane 几何参数（copy_full 同数据默认成立）+ 独立弹幕态计时器
	#   （武器侧读 is_summon_copy 分桶计时）+ 金色染色
	# · W4 激光：副本 sub_beams 强制 0——只出主束 + 灰染
	# · W6 微导：副本 volley_eff=1（齐射折减单发）
	# · W7 集束：副本 sub_eff=min(sub,3)（集束子弹折减）
	# · W8 环绕：蓄能池以目标 uid 全局单例（enemy.charge_stacks——复制体只加速蓄能、
	#   永不复制引爆当量，本侧零折减字段）+ BASE 单环阵 + 相位偏移 45°（化身层读）
	# 折减字段统一鸭子协议 set()（武器组未落地字段静默无操作——跨组接线零冲突）
	var copy := _instantiate_weapon(p_src.data)
	if copy == null:
		return null
	copy.setup(p_src.data, self, _deps)
	copy.level = p_src.level
	copy.meta_atk_pct = p_src.meta_atk_pct \
		+ (RESONANCE_DMG_PER_STACK * float(_resonance_stacks)
			if skill_sublime else 0.0)   # R246 万械共鸣：施放即按存量层数全额继承乘区
	if p_src.trait_stack != null:
		copy.trait_stack = p_src.trait_stack.copy_full()
		# ELE 反应强化副本重注册（attach_trait 副作用不随栈拷贝——按 uid 独立注册；
		# R187 对照：W5 镜面走 make_mirror_image 单源口径，不在此注册）
		var sys: Variant = _deps.get("elemental")
		if sys is ElementalSystem:
			for mounted in copy.trait_stack.traits:
				if mounted.data != null and mounted.data.pool == GameConst.PoolClass.ELEM \
						and mounted.data.params.has("reaction_mult"):
					(sys as ElementalSystem).register_reaction_mult(copy.uid,
						maxf(float(mounted.data.value),
							float(mounted.data.params.get("reaction_mult", 1.8))))
	_apply_copy_ruling(copy, String(p_src.data.id))
	add_child(copy)
	return copy


func _apply_copy_ruling(p_copy: WeaponBase, p_src_id: String) -> void:
	# R183 复制体折减裁定表（R187 设计文档 §一「R183 区分总裁定」统一表）——
	# 与各组已落地消费口对齐：
	# · W4 激光：sub_beams_override=0（LaserWeapon 已落地类型化字段——复制体只出主束）
	#   + copy_tint=true（束色灰染 flag）
	# · W6/W7 自导：HomingWeapon 自检 _summon_copies 数组内部折减（volley_eff=1 /
	#   sub_eff=min(sub,3)），本侧零字段——副本身份由数组权威判定
	# · W8 环绕：蓄能池目标 uid 单例（enemy.charge_stacks 敌侧通道——复制体只加速
	#   蓄能、引爆当量不复制），BASE 阵/相位偏移由 W8 组读副本身份自处理
	# · W1 手枪：同 lane 参数（copy_full 同数据默认成立）+ 独立弹幕态计时（武器侧
	#   自检）；染色统一在化身层（weapon_orbit_avatars 按 src id 染——金/灰/钢蓝/橙红）
	if p_src_id == "W4_pulse_beam":
		p_copy.set("sub_beams_override", 0)      # 复制体只出主束（验收：并发束==1）
		p_copy.set("copy_tint", true)            # 灰染 flag（LaserWeapon 类型化 bool）（W8 等）


# ── R187 W5 万镜回廊：镜面军团共享侧容器/API（实体类归棱镜组） ──────────
func make_mirror_image(p_source: WeaponBase, p_prism: WeaponBase) -> WeaponBase:
	# 镜面构造（白板语义硬约束）：数据/等级/养成修正 = 源武器（沿用其出厂面板开火）、
	# 词条栈 = 棱镜自身栈 copy_full（拷贝源=棱镜——源武器词条零拷贝，「一张棱镜卡
	# =N 镜生效」）。★ELE 单源裁定：镜面只继承元素色、不注册反应乘区（对照 R183
	# 逐副本注册先例——永久件逐镜注册=×4.7^N 雪球，验收 4「注册源数==1」锁死）。
	# 返回未挂树的镜面实例（入场/重掷编排归棱镜组；玩家侧只供容器与驱动）。
	if p_source == null or not is_instance_valid(p_source) or p_source.data == null:
		return null
	var mirror := _instantiate_weapon(p_source.data)
	if mirror == null:
		return null
	mirror.setup(p_source.data, self, _deps)
	mirror.level = p_source.level
	mirror.meta_atk_pct = p_source.meta_atk_pct
	if p_prism != null and is_instance_valid(p_prism) and p_prism.trait_stack != null:
		mirror.trait_stack = p_prism.trait_stack.copy_full()   # 白板：拷贝源=棱镜自身栈
	# 镜面标记（鸭子协议——镜面实体侧字段缺失时静默无操作）：
	mirror.set("is_mirror_image", true)
	mirror.set("mirror_source_id", p_source.data.id)
	mirror.set("copy_tint", true)   # 灰染 flag（R183 通道同 :822 p_copy 口径——此前写
	                                # Color 被 LaserWeapon 类型化 bool 字段静默丢弃，
	                                # 镜面 W4 束恒玩家蓝；冰青读感由化身层 MirrorImage.TINT 承担）
	return mirror


func register_mirror(p_mirror: WeaponBase, p_cap: int = 5) -> bool:
	# 镜面入册（棱镜组入场调用）：绝对帽 5（等级 3 + MEC_MIRROR_SPLIT 2）——
	# 超帽拒绝 + mirror_rejected 计数（验收「再挂钳制在 5」）。
	if p_mirror == null or not is_instance_valid(p_mirror):
		return false
	if _mirror_images.size() >= maxi(p_cap, 0):
		DebugStats.count(&"mirror_rejected")
		return false
	_mirror_images.append(p_mirror)
	if p_mirror.get_parent() == null:
		add_child(p_mirror)
	return true


func mirror_count() -> int:
	# 在场镜数（HUD 镜面 ×N 角标数据源 + 验收断言口）
	return _mirror_images.size()


func mirror_capacity(p_prism: WeaponBase) -> int:
	# 镜数容量 = W5 laser 段 mirrors_count_levels 等级值 + MEC_MIRROR_SPLIT 词条层数，
	# 钳 [0,5]（绝对帽；prism_pointer/指向重掷消费同源）
	if p_prism == null or not is_instance_valid(p_prism) or p_prism.data == null:
		return 0
	var seg_v: Variant = p_prism.data.get("laser")
	if not (seg_v is Dictionary):
		return 0
	var seg: Dictionary = seg_v
	var base := 0
	var levels: Variant = seg.get("mirrors_count_levels", null)
	if levels is Array and not (levels as Array).is_empty():
		var idx := clampi(int(p_prism.get("level")) - 1, 0, (levels as Array).size() - 1)
		base = int((levels as Array)[idx])
	# MEC_MIRROR_SPLIT 层数直读挂载表（计数键口径：不走 add 池、豁免质变 ×1.6）；
	# §2.2.3 品质梯 value 取整 × 层数（白 +1/层 / 蓝 +2/层——卡面口径与消费端一致）
	var tstack: Variant = p_prism.get("trait_stack")
	if tstack != null and tstack.get("traits") != null:
		for tb: Variant in (tstack.get("traits") as Array):
			var td: Variant = tb.get("data")
			if td != null and StringName(str(td.get("id"))) == &"MEC_MIRROR_SPLIT":
				var tv: Variant = td.get("value")
				var per_layer := maxi(int(round(float(tv if tv != null else 1.0))), 1)
				base += per_layer * int(tb.get("layers"))
	return clampi(base, 0, 5)


func set_mirror_locked(p_locked: bool) -> void:
	# MEC_MIRROR_LOCK 挂/卸卡回调（MECH 词条消费口）：锁定后波首/读档不重掷指向
	_mirror_locked = p_locked


func deterministic_source_pick(p_mirror_index: int) -> WeaponBase:
	# 读档/波首确定性重推导（存档层冻结口径：镜面为会话态，指向按「武器槽序 +
	# 固定哈希(武器 id)」重推导——同种子逐局一致，LOCK 卡为构筑漂移的确定性出口）。
	# 排除空槽与 W5 自身；池空返回 null（镜面侧静默降级为锚束标记）。
	var pool: Array[WeaponBase] = []
	for w in weapon_slots:
		if w != null and is_instance_valid(w) and w.data != null \
				and String(w.data.id) != "W5_prism":
			pool.append(w)
	if pool.is_empty():
		return null
	var h := hash(String(pool[p_mirror_index % pool.size()].data.id)) \
		+ p_mirror_index * 2654435761                     # 固定哈希(武器 id)+槽序盐
	return pool[absi(h) % pool.size()]


func clear_mirrors() -> void:
	# 镜面回收（重开/换局收口——注意：不进 _reset_skill_temp_state，验收 2 锁定
	# 「_summon_copies 空而 _mirror_images 原样」的永久件语义）
	for mirror in _mirror_images:
		if mirror != null and is_instance_valid(mirror):
			mirror.queue_free()
	_mirror_images.clear()


func _summon_restore() -> void:
	# 僚机到期还原（R183）：复制武器回收 + 护航舰离场；换角色/重开共用收口
	_summon_left = 0.0
	for drone in _summon_drones:               # R93 护航舰到期回收
		if drone != null and is_instance_valid(drone):
			drone.queue_free()
	_summon_drones.clear()
	for copy in _summon_copies:                # R183 复制武器回收（环绕副本的力场随宿主 free）
		if copy != null and is_instance_valid(copy):
			var sys: Variant = _deps.get("elemental")
			if sys is ElementalSystem:         # 反应乘区注销（P1：不注销则全表连乘滚雪球）
				(sys as ElementalSystem).unregister_reaction_mult(copy.uid)
			copy.queue_free()
	_summon_copies.clear()


func _stomp_pulse(p_knock_r: float, p_force: float, p_clear_r: float,
		p_cap: int, p_feed: bool) -> void:
	# 震荡践踏（R246 参化重构·余震壁垒）：p_knock_r 内敌人击退 ×p_force + p_clear_r 内
	# 敌方弹清除帽 p_cap（复用 NULLIFIED 统一收束）——普通(220,280,260,24,false) /
	# 升华主震(300,380,340,40,true) / 余震(200,140,220,8,true)；p_feed=清弹转护壁。
	# Boss 免疫/精英 ×0.35 由 enemy.knockback 质量分级自动继承（:888-903 零改动）
	var grid: Variant = _deps.get("enemy_grid")
	if grid != null:
		for e in (grid as SpaceGrid).query_circle(global_position, p_knock_r):
			if e == null or bool(e.get("dead")):
				continue
			if e.has_method(&"knockback"):
				e.call(&"knockback", ((e as Node2D).global_position - global_position).normalized() * p_force)
	var bgrid: Variant = _deps.get("enemy_bullet_grid")
	if bgrid != null:
		var cleared := 0
		for b in (bgrid as SpaceGrid).query_circle(global_position, p_clear_r):
			if b is ProjectileBase and (b as ProjectileBase).team == 1:
				EventBus.emit_bullet_nullified((b as Node2D).global_position)
				(b as ProjectileBase).nullify()
				cleared += 1
			if cleared >= p_cap:
				break
		if p_feed and cleared > 0:               # R246 磐岩护壁：清弹→护壁（跨施放 min(残+得,48)）
			_stomp_barrier = minf(_stomp_barrier + cleared * STOMP_BARRIER_PER_BULLET,
				STOMP_BARRIER_CAP)


func gain_xp(p_amount: float) -> void:
	# 经验/等级：xp_gained → 升级（多级连升逐次广播，弹卡排队由 GameLoop 仲裁 E-16）
	# 升级回满血（用户反馈 2026-08-29「升级还是回满血吧」：升级即奖励，血条拉满解压）
	# 经验倍率合成：养成萃取 × 地图祝福 × AFF_XP_GAIN 词条池（R9：跨武器聚合，掉落吸收时实时求值）
	# R188 档3 连升合并（player 侧）：逐级广播语义保持（GameLoop 排队帽 ≤3 + 溢出批
	# 同分布自动抽卡的计数真源 = 本侧每次 emit_level_up）；回满血从逐级重复赋值收敛为
	# 单次应用（终态逐位一致），连升级数落遥测供探针断言。
	# R226 有意契约变更（用户拍板「肉鸽别搞上限」）：AFF_XP_GAIN 池原 +300% 叠加上限
	# 拆除——经验加成无限叠全额
	var amount := maxf(p_amount, 0.0) * (1.0 + Meta.xp_pct()) * map_xp_mult 		* (1.0 + maxf(_weapon_pool_sum(&"add_xp"), 0.0)) 		* GameConst.difficulty_reward_mult(_difficulty)   # R73 难度风险回报（E1）
	xp += amount
	EventBus.emit_xp_gained(amount)
	var levels := 0
	# R189 巨批连升内联循环：曲线参数本地化（免 4.8 万次 _xp_need_for 调用/int→float
	# 转换/maxi——爆发帧 51ms→~35ms 裕量）；公式与 _xp_need_for 逐位一致（同序浮点运算）
	var curve_base := 14.0
	var curve_power := 1.4
	if not _xp_curve_cached and GameConfig.balance != null:
		curve_base = float(GameConfig.balance.xp_curve.get("base", 14.0))
		curve_power = float(GameConfig.balance.xp_curve.get("power", 1.4))
		_xp_curve_base = curve_base
		_xp_curve_power = curve_power
		_xp_curve_cached = true
	elif _xp_curve_cached:
		curve_base = _xp_curve_base
		curve_power = _xp_curve_power
	var lv := float(level)
	var need := xp_need
	var xp_local := xp                                # R189：巨批循环全局部变量化
	var level_local := level                          #（成员访问 ~0.15µs/次 × 3 × 4.8 万级）
	while xp_local >= need:
		xp_local -= need
		level_local += 1
		lv += 1.0
		need = curve_base * pow(lv, curve_power)
		levels += 1
	xp = xp_local
	level = level_local
	xp_need = need
	if levels > 0:
		hp = max_hp
		level_burst_last = levels
		level_burst_max = maxi(level_burst_max, levels)
		if levels == 1:
			EventBus.emit_level_up(level)            # 单级：逐级广播语义保持（E-16）
		else:
			# R189 连升合并广播：巨批逐级 emit 的每级信号税（4+ 订阅者 × 4.8 万级）
			# 为爆发帧超预算主头——批级一次入账，GameLoop._on_level_up_batch 与
			# 逐级仲裁（首级弹卡/排队帽 3/溢出批计数）逐位同口径
			EventBus.emit_level_up_batch(levels)


func set_difficulty(p_d: int) -> void:
	# R73：GameLoop 开局/续档注入（经验合成式消费；金币乘区在 GameLoop 掉账侧用 _difficulty）
	_difficulty = clampi(p_d, 0, 2)


func difficulty_reward_mult() -> float:
	# R73 详情展示口（构筑详情「经验获取」行含难度加成）
	return GameConst.difficulty_reward_mult(_difficulty)


func gold_find_pct() -> float:
	# 金币寻获率（R5.12-P1 AFF_GOLD 点金：金币掉率与掉量 ×(1+Σ)，掉落侧两处乘区——
	# GameLoop._on_enemy_killed_drop_xp 消费；同 map_gold_mult 叠乘口径）
	# R226 有意契约变更（用户拍板「肉鸽别搞上限」）：原 +400% 叠加上限拆除
	return maxf(_weapon_pool_sum(&"add_gold"), 0.0)


func xp_gain_pct() -> float:
	# 经验加成总增量（R18 构筑详情展示口；与 gain_xp 合成式同源）：
	# 养成萃取 × 地图祝福经验 × 词条池（AFF_XP_GAIN 经验萃取）合成增量
	return (1.0 + Meta.xp_pct()) * map_xp_mult \
		* (1.0 + maxf(_weapon_pool_sum(&"add_xp"), 0.0)) - 1.0


func gold_gain_pct() -> float:
	# 金币加成总增量（R18 构筑详情展示口）：点金词条池 × 地图祝福金币
	return (1.0 + gold_find_pct()) * map_gold_mult - 1.0


func apply_hazard_slow(p_mult: float, p_duration: float) -> void:
	# 冰锁圈减速应用（HazardPool frost 调用；刷新式——多圈叠加取最长持续时间）
	hazard_slow_mult = clampf(p_mult, 0.2, 1.0)
	hazard_slow_left = maxf(hazard_slow_left, p_duration)


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
	unlocked_slots = GameConst.difficulty_slot_default(_difficulty)   # R183 开局默认 2/3/3
	slot_bonus = 0                              # R88 金卡解锁计数随局清零
	invuln_left = RESPAWN_INVULN_S
	clear_revive_protect()                       # E2 r2：青弧跨局清零（复活 3s 内重开/回菜单不得残留）
	clear_crystal_shield()                       # R192：晶盾纯会话态随局清零（重开不残留减伤）
	# 格挡力场复位（词条随武器重建重挂；interval 清零防上局残留——挂载时再置位）
	shield_interval = 0.0
	shield_timer = 0.0
	shield_ready = false
	shield_layers = 0                             # 二cv#1：层数随局归零（唯一卸载路径——
	                                              # attach 聚合为 0 时不回调 apply_shield_trait）
	_shield_units.clear()                         # R253：独立计时单元随局全清（真源）
	_shield_pulse_left = 0.0
	temp_shield_stacks = 0                      # 二db M4（QA BUG-1）：橙盾随局清零——重开带入满层=白嫖新局免伤
	temp_shield_left = 0.0
	_drag_accum = Vector2.ZERO
	_active_drag_index = -1                      # R194：首指锁随局清零（重开不残留上局锁权）
	skill_cd_left = 0.0
	skill_active_left = 0.0
	rof_mult = 1.0
	_reset_skill_temp_state()                   # 临时态（毒云/僚机）还原——set_character 内再收口
	clear_mirrors()                             # R187 镜面为会话态：重开随武器重建全清（不进临时态收口）
	_mirror_locked = false                      # MEC_MIRROR_LOCK 挂载态随局重置（词条随武器重建重挂）
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


func _try_revive() -> bool:
	# 应急协议/难度附赠复活：满血复活 + 无敌 5.0s（E2 r2：REVIVE_INVULN_S，每局次数 =
	# 养成等级 + 难度附赠）。演出走 revive_burst 专用通道（白闪/横幅/音效由订阅方
	# GameFeelDirector/HUD/GameLoop 消费）——不再复用 kill_blast（与敌死亡/Blink 爆同款
	# 橙红爆，无复活视觉身份）与 mechanics_intro（与波次 toast 共用唯一 Label 同帧互顶）。
	# 次数耗尽先行 return：0 命致死绝不闪复活 UI，正常走死亡仲裁 → 结算屏。
	if revives_left <= 0:
		return false
	revives_left -= 1
	hp = max_hp
	invuln_left = REVIVE_INVULN_S
	_revive_protect_left = REVIVE_INVULN_S       # 青弧倒数置位（唯一写点；哨兵 3s 技能无敌不触发——独立字段）
	_revive_protect_max = REVIVE_INVULN_S
	clear_crystal_shield()                       # R192：晶盾随生死态清零（复活不满血白嫖减伤残留）
	queue_redraw()
	_revive_clear_bullets()                      # 260px 内至多 24 颗敌弹清弹缓冲（_skill_stomp 同帽）
	EventBus.emit_revive_burst(global_position, revives_left)   # charges_left = 扣减后余量
	var tree := get_tree()
	if tree != null:
		var feel := tree.get_first_node_in_group(&"game_feel")
		if feel != null and feel.has_method(&"on_boss_death_feel"):
			feel.call(&"on_boss_death_feel")   # 120ms 顿帧 + trauma 1.0 + 色差（BOSS_DEATH 档复用，保留）
	return true


func _revive_clear_bullets() -> void:
	# 复活清弹缓冲（E2 r2）：260px 内 team==1 敌弹至多清除 24 颗——零伤害、不击退敌人，
	# 纯公平性缓冲而非清场权（防「免死+免费清场」循环，与 hp=1 类遗物复活通道叠加尤甚；
	# 与 _skill_stomp 消弹同帽先例一致，第 25 颗起保留）。每颗走既有 bullet_nullified
	# 涟漪。依赖敌弹网格为最新帧序（enemy_bullet_grid 仅帧序④重建——调用方保证）。
	var bgrid: Variant = _deps.get("enemy_bullet_grid")
	if bgrid == null:
		return
	var cleared := 0
	for b in (bgrid as SpaceGrid).query_circle(global_position, REVIVE_CLEAR_RADIUS):
		if b is ProjectileBase and (b as ProjectileBase).team == 1:
			EventBus.emit_bullet_nullified((b as Node2D).global_position)
			(b as ProjectileBase).nullify()
			cleared += 1
		if cleared >= REVIVE_CLEAR_CAP:
			break


func clear_revive_protect() -> void:
	# 复活青弧跨局收口（E2 r2 复审 M1）：清零双字段 + 重绘抹弧。respawn() 必调；
	# GameLoop._restore_run_state（continue 局）同步调用——保护演出态不入快照
	_revive_protect_left = 0.0
	_revive_protect_max = 0.0
	queue_redraw()


func grant_crystal_shield(p_dr: float, p_duration: float) -> void:
	# R192 结晶族反应（GEO+X）：晶盾减伤刷新不叠加（重复触发重置时长与幅度——
	# 纯会话态：不入 run_save 快照）。R226 有意契约变更：储存侧 0.8 上限拆除——
	# 数值无限存（爽叠口径统一）；承伤消费端 take_damage 仍钳 [0,0.8]（减伤>80% 的
	# 数学边际收益归零区，非成长上限；两条口径本就独立）
	dr_value = maxf(p_dr, 0.0)
	dr_left = maxf(p_duration, 0.0)


func clear_crystal_shield() -> void:
	# 晶盾清零（复活/死亡/重开收口——减伤不得跨生死态残留）
	dr_value = 0.0
	dr_left = 0.0


func _on_slot_unlocked_event(p_slot: int) -> void:
	unlock_slot(p_slot)


func _clamp_to_playfield() -> void:
	# E-15：位置钳制活动区（下 40% 屏）
	var size := Vector2(720.0, 1280.0)
	if GameConfig.balance != null:
		size = Vector2(GameConfig.balance.res_logic)
	global_position.x = clampf(global_position.x, hitbox_radius, size.x - hitbox_radius)
	global_position.y = clampf(global_position.y, size.y * 0.6, size.y - hitbox_radius)


var _xp_curve_base: float = 14.0              # R189：xp 曲线参数缓存（balance 静态——
var _xp_curve_power: float = 1.4              # 巨批连升 4.8 万级 × 逐次 dict 读是爆发帧主头）
var _xp_curve_cached: bool = false


func _xp_need_for(p_level: int) -> float:
	# 14 × lv^1.4（balance.xp_curve 真源；lv → lv+1 升级所需）
	# R189：曲线参数首次求值时缓存（balance 表 Boot 期加载后不变，测试无运行期改表）
	if not _xp_curve_cached:
		_xp_curve_cached = true
		if GameConfig.balance != null:
			_xp_curve_base = float(GameConfig.balance.xp_curve.get("base", 14.0))
			_xp_curve_power = float(GameConfig.balance.xp_curve.get("power", 1.4))
	return _xp_curve_base * pow(float(maxi(p_level, 1)), _xp_curve_power)


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


func _spawn_fallback_drones(p_dur: float = SUMMON_DURATION) -> void:
	# R93 护航舰：两架编队侧翼跟随 + 低强度伴随火力（12% 主武器 ATK——僚机定位=
	# 伴随输出，不抢复制武器戏），到期前 1.5s 闪烁预警，寿命尽自回收。
	# R183 起随技能常态生成（复制武器为主输出，舰体为「僚机在场」的视觉锚点）
	# R246 万械共鸣：舰数 2→3（升华）/ 寿命注入 p_dur（默认 10.0=普通版现行为；
	# 升华 16s+ 预支——拔掉 _life_left 的 10s 硬编码，舰体不先于窗自毁）；
	# 相位分母随舰数 n（3 舰 i=2 原撞整拍与 0 号舰永久同拍）
	var n := SUBLIME_SUMMON_COPIES if skill_sublime else SUMMON_COPIES
	for i in range(n):
		var drone := SummonDrone.new()
		drone.name = "NoahDrone%d" % i
		drone.side = 1 if i % 2 == 0 else -1
		# R220 刀6（折中方案）：僚机组相位错开——开火倒计时 = 节拍 × (组内序/组数)
		#（确定性推导零存档键；i=0 相位 0 = 现行为）
		if i > 0:
			drone._fire_left = SummonDrone.FIRE_INTERVAL * (float(i) / float(n))
		drone._life_left = p_dur
		add_child(drone)
		_summon_drones.append(drone)


class SummonDrone:
	# R93 真护航僚机（用户「所谓僚机就是临时环绕力场？」）：舰形贴图编队侧翼跟随
	# + 主动开火（弹道池真弹，伤害 12% 主武器 ATK）——不再是环绕接触珠。
	# 到期前 1.5s 闪烁预警，寿命尽自回收。
	# R198（P2-escort）：引擎自驱 _process 改 Player.tick 同拍 tick(p_game_delta)
	#（非虚方法名即退出引擎 _process 回调）——寿命/开火节拍/编队跟随全吃副本
	# game_delta，顿帧/暂停冻结下与主循环同步；浮动相位自累加 _anim_t 脱离
	# Time.get_ticks_msec() 墙上时钟。到期回收/预警闪烁语义逐值保持。
	extends Node2D

	const FIRE_INTERVAL := 0.55              # 开火节拍 s（R220 刀6：常量化——僚机组相位
	                                         # 错开口径与 tick 内重置同源）
	var side := 1                                # 编队侧（1 右 / -1 左）
	var _fire_left := 0.0
	var _life_left := 10.0
	var _anim_t := 0.0                           # R198：浮动相位（game_delta 自累加）
	var _sprite: Sprite2D = null

	func _ready() -> void:
		z_index = 20
		_sprite = Sprite2D.new()
		_sprite.texture = TextureFactory.ship(true)   # 剪影舰体（金色染色=僚机识别）
		_sprite.modulate = PopPalette.GOLD
		_sprite.scale = Vector2(0.4, 0.4)
		add_child(_sprite)

	func tick(p_game_delta: float) -> void:
		var host := get_parent()
		if host == null or not is_instance_valid(host):
			return
		_life_left -= p_game_delta
		if _life_left <= 0.0:
			queue_free()
			return
		_anim_t += p_game_delta
		# 编队位：侧翼 ±74px / 前突 44px + 微浮动——平滑跟随（非环绕）
		var target: Vector2 = Vector2(side * 74.0, -44.0 + sin(_anim_t * 2.2 + side) * 7.0)
		position = position.lerp(target, minf(p_game_delta * 6.0, 1.0))
		# 到期预警闪烁（末 1.5s）
		if _life_left < 1.5:
			_sprite.modulate.a = 0.4 + 0.6 * absf(sin(_life_left * 14.0))
		# 开火：0.55s 一发，最近敌 ≤340px
		_fire_left -= p_game_delta
		if _fire_left > 0.0:
			return
		_fire_left = FIRE_INTERVAL
		_fire_at_nearest(host)

	func _fire_at_nearest(p_host: Node2D) -> void:
		var deps: Variant = p_host.get("_deps")
		var grid: Variant = deps.get("enemy_grid") if deps is Dictionary else null
		var pool: Variant = deps.get("projectile_pool") if deps is Dictionary else null
		var pipeline: Variant = deps.get("pipeline") if deps is Dictionary else null
		if grid == null or pool == null or pipeline == null:
			return
		var world_pos: Vector2 = p_host.global_position + position
		var target: Node2D = grid.call(&"query_nearest", world_pos, 340.0, null)
		if target == null or bool(target.get("dead")):
			return
		# 弹伤 = 12% 主武器 ATK（僚机定位=伴随输出，不抢主武器戏）
		# R246 万械共鸣：升华 18% × (1 + 1.5% × 共鸣层)（宿主字段鸭子读——本函数现役风格）
		var slots: Array = p_host.get("weapon_slots")
		var w0: Variant = slots[0] if slots.size() > 0 else null
		var base := 10.0
		if w0 != null and w0 is WeaponBase and is_instance_valid(w0):
			base = float((w0 as WeaponBase).build_panel_snapshot().get("base_atk", 10.0))
		var sublime := bool(p_host.get("skill_sublime"))
		var pct := Player.SUBLIME_DRONE_ATK_PCT if sublime else 0.12
		if sublime:
			base *= 1.0 + Player.RESONANCE_DMG_PER_STACK * float(int(p_host.get("_resonance_stacks")))
		var dir := (target.global_position - world_pos).normalized()
		var proj: ProjectileBase = pool.call(&"acquire")
		if proj == null:
			return
		proj.spawn({
			"position": world_pos, "velocity": dir * 560.0,
			"lifetime": 1.2, "range": 400.0, "pierce": 1, "bounces": 0,
			"hitbox_radius": 7.0, "element": GameConst.Element.KIN, "attach_value": 0.0,
			"generation": 0, "weapon_uid": int(p_host.get_instance_id()),
			"panel_snapshot": {"base_atk": base * pct},
			"trait_stack": null, "team": 0,
		})
		proj.damage_pipeline = pipeline                  # 武器侧 _inject_projectile_deps 同口径
		proj.enemy_grid = grid
		proj.pool = pool
		# 朝向敌向（剪影画布朝上）
		_sprite.rotation = dir.angle() + PI * 0.5

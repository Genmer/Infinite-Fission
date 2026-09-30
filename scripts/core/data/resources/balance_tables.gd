# scripts/core/data/resources/balance_tables.gd
# §三.8 BalanceTables（全局常数，唯一 .tres：data/balance/balance_tables.tres）
# GameConfig 校验后的全局常数唯一真源；GameConfig 本体不持有业务常数（单一数据源）。
class_name BalanceTables
extends Resource

@export var res_logic: Vector2i = Vector2i(720, 1280)        # F-01 裁定；错误 → 致命（拒绝启动）
@export_range(2.0, 32.0) var cap_prod: float = 8.0           # F-16 乘区段整体钳制
@export var r_alarm_ratio: float = 500.0                     # ×500 告警线；>0
@export_range(4, 16) var cap_mul_count: int = 8              # 乘区名额上限
@export var cap_proj_traits: int = 12                        # 单投射物词条；>0
@export_range(0.001, 2.0) var flat_ratio_cap: float = 0.5    # f_flat 比例钳制
# F4 保险丝：add_atk:2.0, add_rof:1.5, add_cdr:0.6, add_crit:1.0, add_critdmg:2.0；每值 >0
@export var add_pool_caps: Dictionary = {
	"add_atk": 2.0, "add_rof": 1.5, "add_cdr": 0.6, "add_crit": 1.0, "add_critdmg": 2.0,
}
@export var cap_cdr_sum: float = 0.6                         # F-11
@export var cap_rof_per_weapon: float = 30.0                 # 性能双护栏；>0
@export var cap_crit_rate: float = 1.0
@export var decay_delta_max: float = 0.92                    # F-21 词条校验上限
@export var split_max_generation: int = 3                    # E-01 三闸之一
@export var split_max_children: int = 8                      # 三闸之二
@export var split_inherit_ratio: float = 0.5                 # 逐代 ×0.5（Q-9）
@export var projectile_soft_limit: int = 1500                # 软上限（丢弃+计数）
@export var projectile_hard_limit: int = 2000                # 硬上限（回收最老）
# 每值 >0（=0 → 致命拒绝启动）；§5.1 预热容量表：弹 640 / 敌 128 / 跳字 80 / 粒子 64 / 激光 12 / 经验 160
@export var pool_prewarm: Dictionary = {
	"projectile": 640, "enemy": 128, "popup": 80,
	"particle": 64, "laser": 12, "xp": 160,
}
@export var frame_budget_ms: float = 8.3                     # §五.4 预算锚
@export var contact_tick: float = 0.6                        # 受击无敌帧（F-35）
@export var pickup_radius: float = 120.0                     # 磁吸（Q-13）
@export var hp_growth_per_wave: float = 1.12                 # 敌成长核心锚
@export var dmg_growth_per_wave: float = 1.06                # F-27
@export var spd_growth_per_wave: float = 0.008
@export var exp_inflation_per_wave: float = 1.085
@export var xp_curve: Dictionary = {"base": 14.0, "power": 1.4}   # 值 >0
# 早期经验加速（2026-09-13 用户反馈「早期叠不起来…下个buff我一定要起飞」）：第 1 波至
# until_wave-1 波经验球面值 ×mult（掉落侧折算，同 REL_MIDAS 口径；gain_xp 曲线不受影响），
# until_wave 波起回落 1.0——构筑起步提速 +25%，中期回归标准通胀
@export var early_xp_boost: Dictionary = {"mult": 1.25, "until_wave": 6}   # mult ≥1 / until_wave ≥1
@export var rarity_weights: Dictionary = {"WHITE": 58, "BLUE": 30, "PURPLE": 10, "GOLD": 2}  # 权重和 >0
@export var category_weights: Dictionary = {"MASTERY": 12, "ADD": 40, "MULT": 18, "MECH": 14, "ELEM": 14, "RELIC": 6}
# ELEM 10→14（R192 数值三源纪律：本默认 + balance_tables.tres 运行时真源 + card_generator
# CATEGORY_WEIGHTS const 镜像，三处同批同值；单改常量运行时无效——setup() 用 .tres 逐键覆写）
@export var cd_rxn: float = 2.0                              # 反应 CD（F-34）
# FIR/ICE/LTG/HYD/ANE/GEO/DEN 比例衰减 λ（F-22；R192 扩 7 项——槽 i 对应 λ[i-1] 直索引，
# 与 validator「恰 7 项」及 elemental_system 兜底四源同批同值）
@export var element_decay_lambda: Array[float] = [0.35, 0.30, 0.40, 0.35, 0.50, 0.25, 0.30]
# 状态参数（§2.10 契约键）
@export var element_states: Dictionary = {
	"burn": {"dot_ratio": 0.15, "tick": 0.5, "duration": 3.0, "max_layers": 5},
	"freeze": {"chill_slow": 0.4, "chill_dur": 2.5, "freeze_dur": 1.2, "vuln_mult": 1.25, "vuln_dur": 3.0},
	"shock": {"chain_targets": 3, "chain_radius": 160.0, "chain_ratio": 0.35, "chain_depth": 2, "chain_decay": 0.6},
}
# 反应表（§2.4；R192 扩 20 键与 ReactionType 枚举成员一一对应——键集双射由
# DataValidator 四源闸动态守护；数值域 coef∈(0,2.0]/resist_delta∈[-0.8,0.8]/
# radius·duration·delay>0 同闸）。与 data/balance/balance_tables.tres 双源同值，
# 改键必须两处同批。
@export var reaction_table: Dictionary = {
	"RXN_FIR_ICE": {"coef": 2.0},
	"RXN_FIR_LTG": {"coef": 1.2, "radius": 90.0},
	"RXN_ICE_LTG": {"resist_delta": -0.3, "duration": 6.0},
	"RXN_FIR_HYD": {"coef": 1.5},                                   # 蒸发（即时快照 ×S_snap）
	"RXN_HYD_DEN": {"coef": 1.5, "radius": 120.0, "delay": 0.75},    # 绽放（延迟 AoE；R192-low6/R198 调参 delay 1.5→0.75——.tres 双源同批）
	"RXN_FIR_ANE": {"coef": 0.8, "radius": 120.0, "targets": 3.0},  # 扩散族 ×5（主目标直伤
	"RXN_ICE_ANE": {"coef": 0.8, "radius": 120.0, "targets": 3.0},  #   +至多 targets 敌满槽
	"RXN_LTG_ANE": {"coef": 0.8, "radius": 120.0, "targets": 3.0},  #   转移被扩元素）
	"RXN_HYD_ANE": {"coef": 0.8, "radius": 120.0, "targets": 3.0},
	"RXN_ANE_DEN": {"coef": 0.8, "radius": 120.0, "targets": 3.0},
	"RXN_ICE_HYD": {"freeze_dur": 1.2, "chill_dur": 2.5, "vuln_mult": 1.25, "vuln_dur": 3.0},   # 冻结（复用既有字段刷新不改键）
	"RXN_LTG_HYD": {},                                              # 感电（读 element_states.shock 全套；shock_chain_cd=1.0 护栏零新表键）
	"RXN_FIR_DEN": {"burn_layers_max": 5.0, "burn_dur": 3.0},       # 燃烧（立即满层点燃）
	"RXN_LTG_DEN": {"vuln_mult": 1.25, "vuln_dur": 3.0},            # 激化（复用 vuln 池刷新）
	"RXN_FIR_GEO": {"dr": 0.15, "dr_dur": 6.0},                     # 结晶族 ×6（玩家减伤
	"RXN_ICE_GEO": {"dr": 0.15, "dr_dur": 6.0},                     #   crystal_shield_request，
	"RXN_LTG_GEO": {"dr": 0.15, "dr_dur": 6.0},                     #   刷新不叠加）
	"RXN_HYD_GEO": {"dr": 0.15, "dr_dur": 6.0},
	"RXN_DEN_GEO": {"dr": 0.15, "dr_dur": 6.0},
	"RXN_ANE_GEO": {"dr": 0.15, "dr_dur": 6.0},
}   # 冰+草无成员（idContract 留白位）——图鉴降透明标注行，文案 REACTION_BLANK_NOTE
@export var event_storm_threshold: int = 128                 # §六.4
# R_rxn 反应通道独立告警线（集成包 B.6 落字段——管线 resolve_reaction 原用 r_alarm_ratio=500
# 兜底）。管线口径＝「每笔反应结算 coefficient>50 即告警」（damage_pipeline 判据不动），
# 配对数不进口径。真源推导（R192 按三处失真重写）：
# ① φ 锚过期：原注 φ=1.8 已废——ELE_REACTION_VOID 金卡 reaction_mult 金梯现为 4.68
#   （verify_feedback 锁 ×4.7 口径），单源最坏 χ=2.0（碎裂系数帽）× φ=4.68 = 9.36，
#   S_snap ≤ S×(1+add 池钳 2.0+flat 0.5)=3.5S ⇒ 单源 D ≤ 32.8×S，×50 留 ~1.5× 余量；
# ② 多源失真＝实际伤害帽：reaction_mult 多源连乘（3 金 VOID 连乘 ≈×102.5，φ=4.68³>50）
#   可达——（R192-low5/R198 注释算术修正：原注释倍数与同文件金梯 4.68 失洽，按 4.68³=102.5 更正）
#   越线后 ×50 即实际伤害帽（钳制+alarm+一局一次广播+计数），非纯理论保险丝；新反应
#   强化卡维持单源纪律（镜面先例 player.gd）；
# ③ 碎裂池基特例：碎裂为唯一池基反应（系数随点燃剩余 DOT 池缩放，不经 S_snap 基），
#   池随基缩放故同受 ×50 覆盖，失真方向偏保守（多报不漏报）。
@export var r_rxn_ratio: float = 50.0                        # >0；反应结算上界 D ≤ S_snap × 本值
@export var data_version: int = 1                            # 与 version.cfg 不匹配 → 告警（AC-13.5）
# §5.3 弹幕渲染升级路径预留位：0 = Sprite2D 池模式（默认），1 = MultiMesh 同步模式（M2 实验开关）
@export var projectile_render_mode: int = 0

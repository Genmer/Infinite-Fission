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
# v0.7.0 芯片独立乘区段整体钳（A6 §3）：Σ chip contrib 截断上限；schema 默认即合法
#（balance_tables.tres 不必改）。合法域 (0, 4]（非致命校验，超限回退默认）。
@export var cap_chip_zone: float = 1.0
@export var decay_delta_max: float = 0.92                    # F-21 词条校验上限
@export var split_max_generation: int = 3                    # E-01 三闸之一
@export var split_max_children: int = 8                      # 三闸之二
@export var split_inherit_ratio: float = 0.5                 # 逐代 ×0.5（Q-9）
@export var projectile_soft_limit: int = 1500                # 软上限（丢弃+计数）
@export var projectile_hard_limit: int = 2000                # 硬上限（回收最老）
# 每值 >0（=0 → 致命拒绝启动）；§5.1 预热容量表：弹 640 / 敌 128 / 跳字 80 / 粒子 64 / 激光 12 / 经验 160
# v0.6.0 增金币行 96（A4 §7 裁定）
@export var pool_prewarm: Dictionary = {
	"projectile": 640, "enemy": 128, "popup": 80,
	"particle": 64, "laser": 12, "xp": 160, "gold": 96,
}
@export var frame_budget_ms: float = 8.3                     # §五.4 预算锚
@export var contact_tick: float = 0.6                        # 受击无敌帧（F-35）
@export var pickup_radius: float = 120.0                     # 磁吸（Q-13）
@export var hp_growth_per_wave: float = 1.12                 # 敌成长核心锚
@export var dmg_growth_per_wave: float = 1.06                # F-27
@export var spd_growth_per_wave: float = 0.008
@export var exp_inflation_per_wave: float = 1.085
@export var xp_curve: Dictionary = {"base": 14.0, "power": 1.4}   # 值 >0
@export var rarity_weights: Dictionary = {"WHITE": 58, "BLUE": 30, "PURPLE": 10, "GOLD": 2}  # 权重和 >0
# v0.6.0：WEAPON 8 + 原五类×0.92 归一（和=100.0；与 CardGenerator.CATEGORY_WEIGHTS / .tres 三处同值，A4 §5）
@export var category_weights: Dictionary = {"MASTERY": 11.04, "ADD": 36.8, "MULT": 16.56, "MECH": 12.88, "ELEM": 9.2, "RELIC": 5.52, "WEAPON": 8.0}
@export var cd_rxn: float = 2.0                              # 反应 CD（F-34）
# FIR/ICE/LTG/WAT 比例衰减 λ（F-22；v1.2.0 尾追 WAT=0.38，A11 §1——三处同值：
# schema 默认 / balance_tables.tres / A11 §1）
@export var element_decay_lambda: Array[float] = [0.35, 0.30, 0.40, 0.38]
# 状态参数（§2.10 契约键）
@export var element_states: Dictionary = {
	"burn": {"dot_ratio": 0.15, "tick": 0.5, "duration": 3.0, "max_layers": 5},
	"freeze": {"chill_slow": 0.4, "chill_dur": 2.5, "freeze_dur": 1.2, "vuln_mult": 1.25, "vuln_dur": 3.0},
	"shock": {"chain_targets": 3, "chain_radius": 160.0, "chain_ratio": 0.35, "chain_depth": 2, "chain_decay": 0.6},
}
# 反应系数 >0（§2.4）；v1.1.0 CD 分立：各 rule 携带独立 cd（缺键回退 cd_rxn；.tres 同值镜像）
# v1.2.0 尾追水系三剧变（A11 §1/§3）：冻结（全停 2.5s + 破碎 3 直击 40%ATK）/导电（90%×3 跳
# 160px 衰减 0.6）/汽爆（60% 半径 80）
@export var reaction_table: Dictionary = {
	"RXN_FIR_ICE": {"coef": 2.0, "cd": 2.0},
	"RXN_FIR_LTG": {"coef": 1.2, "radius": 90.0, "cd": 3.0},
	"RXN_ICE_LTG": {"resist_delta": -0.3, "duration": 6.0, "cd": 6.0},
	"RXN_WAT_ICE": {"duration": 2.5, "shatter_coef": 0.4, "shatter_hits": 3, "cd": 5.0},
	"RXN_WAT_LTG": {"coef": 0.9, "chain_hops": 3, "chain_targets": 3, "chain_radius": 160.0, "chain_decay": 0.6, "cd": 4.0},
	"RXN_WAT_FIR": {"coef": 0.6, "radius": 80.0, "cd": 3.0},
}
# v0.9.0 波次赐福权重镜像（A8 §1）：与 BlessingHandler.BLESSING_WEIGHTS 同值（和=100.0）。
# 双源镜像纪律同 category_weights（改一处必改两处；.tres 不改——schema 默认即合法）。
@export var blessing_weights: Dictionary = {&"gold": 30.0, &"heal": 15.0, &"atk": 25.0, &"rof": 15.0, &"attach": 10.0, &"slot1": 4.0, &"slot2": 1.0}
@export var event_storm_threshold: int = 128                 # §六.4
# R_rxn 反应通道独立告警线（集成包 B.6 落字段——管线 resolve_reaction 原用 r_alarm_ratio=500
# 兜底）。真源推导：A3 §2.4 反应系数上限 χ=2.0（碎裂）× φ=1.8（ELE_REACTION_VOID）= 3.6，
# 快照面板 S_snap ≤ S×(1+add 池钳 2.0+flat 0.5)=3.5S ⇒ D ≤ 12.6×S；取 ×50 留 ~4× 余量，
# 与 R_alarm=×500 同为「双闸保险」语义（超线 → 审计 alarm + 一局一次广播 + 计数）。
@export var r_rxn_ratio: float = 50.0                        # >0；反应结算上界 D ≤ S_snap × 本值
@export var data_version: int = 1                            # 与 version.cfg 不匹配 → 告警（AC-13.5）
# §5.3 弹幕渲染升级路径预留位：0 = Sprite2D 池模式（默认），1 = MultiMesh 同步模式（M2 实验开关）
@export var projectile_render_mode: int = 0

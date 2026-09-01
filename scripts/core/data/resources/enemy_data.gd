# scripts/core/data/resources/enemy_data.gd
# §三.2 EnemyData（敌人：六种基础 + 3 Boss + 精英模板）
class_name EnemyData
extends Resource

@export var id: StringName = &""                    # 非空唯一
@export var display_name: String = ""
# GameConst.EnemyBehavior；M1 仅支持 CHASE/RANGED（其余告警降级为 CHASE）
@export_enum("CHASE", "RANGED", "DASHER", "ORBIT", "SENTRY") var behavior: int = 0
@export var hp_base: float = 72.0                   # >0
@export_range(0.0, 600.0) var spd_base: float = 75.0
@export_range(0.0, 200.0) var dmg_base: float = 8.0  # 接触伤害
@export var exp_base: float = 3.0                   # ≥0
@export var tp_cost: float = 1.0                    # >0（威胁点成本）
# 每项 ∈ [-0.8, 0.8]（KIN/FIR/ICE/LTG/WAT，A3 §2.3 + v1.2.0 尾追 WAT，A11 §2）
@export var resist: Array[float] = [0.0, 0.0, 0.0, 0.0, 0.0]
@export var immune_mask: int = 0                    # 已知位组合（Boss 置 IMMUNE_FREEZE，F-17）
@export var tags: int = 0                           # TAG_ELITE / TAG_BOSS 位
@export_range(0.1, 64.0) var hitbox_r: float = 14.0 # (0, 64]
# behavior=RANGED 必填 {bullet_speed, fire_cd, bullet_atk_ratio, spread}；fire_cd>0
@export var ranged: Dictionary = {}
# 精英模板 {hp:4.2, spd:0.92, dmg:1.5, exp:8.0}；仅 elite_template.tres 使用
@export var elite_mult: Dictionary = {}
# tags 含 BOSS 必填 {phases, bullet_patterns, summons, phase2_resist:0.2}
@export var boss: Dictionary = {}
# {chance, min, max}（M3 商店）
@export var gold_drop: Dictionary = {}

# scripts/core/damage/damage_audit.gd
# §2.5 遥测唯一数据源；"恒空为健康"的字段见健康线注释（A2 §2.5）
class_name DamageAudit
extends RefCounted

var clamped_add: Array[StringName] = []       # F4 触发池（正常不可达）
var clamped_flat: bool = false
var clamped_chip: bool = false                # v0.7.0：芯片段 cap_chip_zone 截断触发
var truncated_mults: Array[StringName] = []   # 名额截断（接近 0 为健康）
var compressed: bool = false                  # F9 整体钳制触发（M1 = 0，M2+ <0.5%）
var dedup_defense: Array[Dictionary] = []     # 防御层去重 [{pool_id, source_uid}]（>0 即 bug）
var alarm: bool = false                       # R_alarm 触发（=0 为健康）
var ratio: float = 0.0                        # final / base_atk（抗性前口径）
var pool_count: int = 0                       # 参与乘区数
var mult_product: float = 1.0
var chip_product: float = 1.0                 # v0.7.0：芯片段终值（审计对账）

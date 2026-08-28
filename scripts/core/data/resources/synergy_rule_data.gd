# scripts/core/data/resources/synergy_rule_data.gd
# §三.5 SynergyRuleData（独立乘区条件规则）
class_name SynergyRuleData
extends Resource

@export var id: StringName = &""                    # 非空唯一；= pool_id 的规则条目
# ∈ 乘区封闭枚举（frost_dmg / burn_dmg / bounce_dmg / pierce_dmg / fury_dmg / opening_dmg / elite_dmg / vuln …）
@export var pool_id: StringName = &""
# GameConst.ConditionId 枚举（封闭，新增需框架评审，A2 §1.9）
@export var condition_id: int = 8                   # NONE
# 条件参数（PIERCE_INDEX_GE→{min:2}；PLAYER_HP_BELOW→{pct:0.35}；TARGET_TAG_IN→{tags:[1,2]}）
@export var condition_params: Dictionary = {}
# 求值方式：白名单模板（"value" / "value * (ctx.pierce_index - 1)"）→ 编译期映射到
# ConditionId 绑定的内置求值函数（switch 分发）。Expression 类仅允许出现在开发期工具脚本。
@export var contribution_expr: String = "value"
@export var cap_pool_p: float = 1.0                 # >0 必填（F-14）
# 名额截断时的稳定排序破序键（同 (M_p−1) 降序时按 priority 决胜，保证确定性）
@export var priority: int = 0

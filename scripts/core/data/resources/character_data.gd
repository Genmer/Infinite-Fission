# scripts/core/data/resources/character_data.gd
# v0.8.0 CharacterData（A7 §V17 角色数据）：选角屏可选角色定义。
# starting_weapon_id 必须命中 registry.weapons（悬空 → 剔除宿主，validator check_references 查）；
# 数值域约束：xp_mult ∈ [0.5,2.0] / move_speed_mult ∈ [0.5,2.0] / max_hp_pct ∈ [−0.9,3.0] /
# pickup_radius_add ∈ [−100,200]（均 error 级）。
class_name CharacterData
extends Resource

@export var id: StringName = &""                    # 非空唯一
@export var display_name: String = ""
@export var description: String = ""                # 选角卡一句话风格文案
@export var starting_weapon_id: StringName = &""    # ∈ registry.weapons（悬空 → 剔除）
@export var max_hp_pct: float = 0.0                 # 生命上限加成（compute_max_hp char_pct 口径）
@export var move_speed_mult: float = 1.0            # 移速乘数（apply_character）
@export var pickup_radius_add: float = 0.0          # 磁吸半径增量 px（apply_character）
@export var xp_mult: float = 1.0                    # 经验乘子（三乘子 = 遗物×角色×(1+K_chip)）

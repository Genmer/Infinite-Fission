# scripts/core/data/resources/weapon_data.gd
# §三.1 WeaponData（武器：四形态参数重写字段集）
# 形态专属段以嵌套 Dictionary 存放（ballistic/laser/homing/melee 四段并存，按 form 取用，
# 未启用段忽略校验）——比平铺字段组更利于扩展第五形态（AC-02.1 仅新增键，不改类）。
class_name WeaponData
extends Resource

@export var id: StringName = &""                             # 非空、全局唯一；重复 → 后者剔除
@export var display_name: String = ""                        # 非空（仅告警）
@export_enum("BALLISTIC", "LASER", "HOMING", "MELEE") var form: int = 0   # GameConst.WeaponForm
@export_range(0.0, 1.0) var crit_rate: float = 0.05
@export_range(1.0, 5.0) var crit_dmg: float = 2.0            # F-30 基线 ×2.0
@export_range(0.1, 64.0) var hitbox_r: float = 6.0           # (0, 64]
@export var unlock_rarity: int = 1                           # 稀有度（卡池展示）
# 恰好 5 项（L1~L5）；每项终值校验见 DataValidator.validate_weapon
@export var upgrade_table: Array[WeaponLevelStats] = []
# 每项 {threshold_id, metric, threshold, effect_id, params}；metric ∈ 封闭枚举
@export var threshold_traits: Array[Dictionary] = []
# BALLISTIC 段：proj_speed>0；range>0；pierce≥0；pellets∈[1,16]；rof（L 表）≤30（cap_rof）
@export var ballistic: Dictionary = {
	"proj_speed": 620.0, "range": 680.0, "spread_deg": 2.0,
	"pierce": 1, "pellets": 1, "spin_up_time": 0.0, "rof_hot": 0.0,
}
# LASER 段：tick_rate∈(0,30]；scorch_max_layers∈[1,8]；refract_depth≤2（超限剔除）
@export var laser: Dictionary = {
	"beam_length": 560.0, "beam_width": 14.0, "tick_rate": 8.0,
	"scorch_max_layers": 5, "scorch_per_layer": 0.08,
	"refract_beams": 0, "refract_ratio": 0.6, "refract_depth": 2,
}
# HOMING 段：speed_max≥speed_init；turn_rate>0；blast_r∈(0,128]；sub_count∈[0,8]
@export var homing: Dictionary = {
	"proj_speed_init": 240.0, "proj_speed_max": 720.0, "accel": 900.0,
	"turn_rate": 480.0, "arm_delay": 0.15, "blast_r": 45.0, "blast_falloff": 0.6,
	"sub_count": 0, "sub_delay": 0.4,
}
# MELEE 段：arc_deg∈(0,360]；orbs∈[1,8]；hit_cd>0
@export var melee: Dictionary = {
	"orbit_radius": 90.0, "angular_speed": 240.0, "orbs": 2, "hit_cd": 0.5,
	"knockback": 40.0, "slash_radius": 150.0, "arc_deg": 120.0,
	"max_targets": 8, "nullify": false,
}

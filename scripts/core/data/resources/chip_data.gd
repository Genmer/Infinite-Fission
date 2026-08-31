# scripts/core/data/resources/chip_data.gd
# v0.7.0 ChipData（A6 §1 芯片数据）：Boss 掉落 / 商店货架的强化芯片（3 槽 × 8 种 × 4 档）。
# stat_key ∈ GameConst.CHIP_STAT_KEYS 封闭注册表（悬空 → 剔除，validator 查）；
# values 恰好 4 档（白/蓝/紫/金，下标 = rarity），全 >0 单调不减（validator error 级）。
class_name ChipData
extends Resource

@export var id: StringName = &""                    # 非空唯一
@export var display_name: String = ""
@export var description: String = ""                # 按 stat 语义写（"直击伤害独立乘区 +X%" 类）
@export var stat_key: StringName = &""              # ∈ GameConst.CHIP_STAT_KEYS
@export var values: Array[float] = []               # 恰好 4 档；全 >0 单调不减

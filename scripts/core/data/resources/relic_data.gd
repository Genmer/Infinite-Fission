# scripts/core/data/resources/relic_data.gd
# §三.4 RelicData（遗物：全局规则）
class_name RelicData
extends Resource

@export var id: StringName = &""                    # 非空唯一
@export var display_name: String = ""
@export var description: String = ""
@export var rarity: int = 3                         # 统一金；每场每件唯一
# 每项 ∈ EventBus 事件名注册表（悬空 → 剔除，AC-13.3）
@export var listen_events: Array[StringName] = []
# ∈ 遗物效果处理器注册表（包 3/4 落地）
@export var effect_id: StringName = &""
@export var params: Dictionary = {}                 # 效果参数（处理器契约校验必填键）
@export var unique: bool = true                     # 抽中后移出卡池

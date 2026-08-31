# scripts/core/data/resources/trait_data.gd
# §三.3 TraitData（词条：B_spec §2.5 注册契约；L1 守门，非法 → 剔除）
class_name TraitData
extends Resource

@export var id: StringName = &""                    # 非空唯一
@export var display_name: String = ""
@export var description: String = ""
# GameConst.PoolClass {ADD, MULT, LOCAL, MECH, ELEM}
@export_enum("ADD", "MULT", "LOCAL", "MECH", "ELEM") var pool: int = 0
# ADD/MULT/LOCAL 类必填且 ∈ 封闭枚举注册表（add_atk/…；frost_dmg/…）；MECH/ELEM 可空
@export var pool_id: StringName = &""
# 必填且 ∈ builtin 处理器注册表（包 3 落地；悬空 → 剔除，AC-13.3）
@export var effect_id: StringName = &""
@export var value: float = 0.0                      # 单层基础值 c_i；语义随 pool/effect
@export var value2: float = 0.0                     # 次数值（如分裂夹角/继承比例）
@export var params: Dictionary = {}                 # 效果参数包（effect_id 契约键）
# TraitEvent 集合；空 = 常驻
@export var event_hooks: Array[int] = []
@export var stack_max: int = 1                      # ≥1；卡牌流叠层过滤依据
# pool=ADD 必填且 ∈ (0, 0.92]（F-21 硬约束）
@export var decay_delta: float = 0.0
# pool=MULT 必填且 >0（F-14 单区硬顶）
@export var cap_pool_p: float = 0.0
# pool=LOCAL 必填且 >0（F-15）
@export var cap_local: float = 0.0
@export var inheritable: bool = false               # 分裂继承标记（分裂词条自身默认 false，E-01）
@export_range(0.001, 1.0) var proc_chance: float = 1.0   # (0, 1]
@export var cooldown: float = 0.0                   # ≥0（词条触发冷却）
@export var rarity: int = 0                         # 白/蓝/紫/金
@export var tags: int = 0                           # TAG 位（CURSE 等，F-23 净化通道占位）
# v0.6.0 武器门槛（A4 §6）：非空 = 未持有该 id 武器时候选池过滤 + apply 挂载防御拒绝
@export var required_weapon: StringName = &""
# MULT 类条件 {condition_id, params}（见 SynergyRuleData）
@export var condition: Dictionary = {}

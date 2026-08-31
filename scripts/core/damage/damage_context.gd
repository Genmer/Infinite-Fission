# scripts/core/damage/damage_context.gd
# B_spec §2.2 的实现级细化：add_ids[] 细化为 add_entries（携带层数/δ/原始贡献，
# 因 B_spec §2.3 步骤 3 的衰减职责发生在管线内，需要层数信息；语义不变）。
class_name DamageContext
extends RefCounted

var source_uid: int = 0                       # 来源实例 UID（投射物/光束/武器/反应源）
var target_uid: int = 0
# 架构类型为 Enemy（M-03，白名单 §1.3-3 窄接口载荷）；包 0 曾以 Node2D 占位——
# 集成包 B.8 第二批收紧为 Enemy（pkg1 目标夹具已迁移真实实体版本）。
var target: Enemy = null
var frame_stamp: int = 0                      # 幂等键第三元
var rng_stream_id: int = 0
# 面板段
var base_atk: float = 0.0                     # F2 结果（武器表终值 × g_global）
# 每项 {trait_id: StringName, pool_id: StringName, layer: int, contrib: float,
#      decay_delta: float, is_curse: bool}（衰减前 raw；F3 衰减职责在管线步骤 3）
var add_entries: Array[Dictionary] = []
var flat_bonus: float = 0.0
# 乘区段：每项 {pool_id: StringName, source_uid: int, contrib: float, cap_pool: float}
# （可选附加键 priority: int——名额截断决胜破序键，§三.5；乘区 contrib 已在来源侧求值）
var mult_pools: Array[Dictionary] = []
# 私有乘区段：每项 {local_id: StringName, contrib: float, cap_local: float}
var local_pools: Array[Dictionary] = []
# v0.7.0 芯片独立乘区段（A6 §3）：每项 {stat: StringName, contrib: float}——聚合在管线
# ⑥b aggregate_chip（cap_chip_zone 钳制）；仅直击通道注入（settle_aoe/DOT/反应不吃芯片段）
var chip_entries: Array[Dictionary] = []
# 暴击
var crit_chance: float = 0.0
var crit_mult: float = 2.0
# 类型与目标
var element: int = GameConst.Element.KIN
var hit_flags: int = 0                        # GameConst.HIT_* 位标志
var target_resist: float = 0.0                # 快照读取（含超导削抗后的当前值）
# 条件求值上下文快照（A2 §7.1，乘区 contrib 已在来源侧求值，此为审计/词条自评用）
var bounce_count: int = 0
var pierce_index: int = 0
var generation: int = 0
var is_first_hit_of_wave: bool = false
var player_hp_pct: float = 1.0
var pos: Vector2 = Vector2.ZERO               # 跳字锚点


static func make() -> DamageContext:
	# 工厂（测试/运行共用，字段默认值即安全值）
	return DamageContext.new()

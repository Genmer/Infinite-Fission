# scripts/combat/trait/trait_context.gd
# M-10 TraitContext（架构 §2.9.1）：事件载荷——词条自评与效果执行的全部上下文。
# 六事件宿主（projectile/beam/melee/weapon）按来源形态填充其一；ON_HIT 期 damage_ctx
# 携带结算请求（乘区 contrib 通道与条件自评输入）；split_request/attach_request 为
# 引擎侧执行请求的输出通道（M-09 在 _recycle/_on_settled 统一消费）。
class_name TraitContext
extends RefCounted

var event: int = 0                            # GameConst.TraitEvent
var projectile: ProjectileBase = null         # 六事件宿主（光束/近战时为 null）
var beam: LaserBeam = null
var melee: Node2D = null
var weapon: WeaponBase = null
var target: Node2D = null                     # Enemy（窄接口载荷，§1.3-3）
var damage_ctx: DamageContext = null          # ON_HIT 期注入乘区（contrib 通道）
var game_delta: float = 0.0
var split_request: Dictionary = {}            # ON_EXPIRE 期分裂请求输出 {count, spread_deg, inherit_ratio, echo}
var attach_request: Dictionary = {}           # 元素附着请求输出 {element, value, overrides}

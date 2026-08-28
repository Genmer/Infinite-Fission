# scripts/core/pools/xp_pool.gd
# M-13 特化池：XPPool（经验碎片；架构 §2.3/§5.1：预热 160 / 软 240 / 硬 320）
# 满池行为（§5.1）：合并为大面值碎片（数值守恒）——由调用方（Player 掉落侧）降级。
# 类型占位说明：架构原文 acquire() -> XpShard / release(x: XpShard)；XpShard 属包 2
#（scripts/entities/player/pickup.gd，extends Area2D，架构 §1.4/§2.12），包 0 以 Area2D 占位。
class_name XPPool
extends ObjectPool


func acquire() -> Area2D:
	# 经验碎片取出（满池由调用方合并为大面值碎片）
	return super.acquire() as Area2D

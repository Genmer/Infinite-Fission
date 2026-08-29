# scripts/core/pools/xp_pool.gd
# M-13 特化池：XPPool（经验碎片；架构 §2.3/§5.1：预热 160 / 软 240 / 硬 320）
# 满池行为（§5.1）：合并为大面值碎片（数值守恒）——由调用方（Player 掉落侧）降级。
# 类型收紧（集成包 B.1/B.8：XpShard 真件已落地，pkg0 池用例已迁移真实碎片场景）：
# acquire() -> XpShard（架构原文口径；GDScript 覆写允许返回值协变）。
class_name XPPool
extends ObjectPool


func acquire() -> XpShard:
	# 经验碎片取出（满池由调用方合并为大面值碎片）
	return super.acquire() as XpShard

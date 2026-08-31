# scripts/core/pools/gold_pool.gd
# M-13 特化池：GoldPool（金币；架构 §5.1 预热表 v0.6.0 扩展行：预热 96，A4 §7 裁定）。
# 满池行为（A4 §3）：合并为大面值金币（数值守恒）——由调用方（GameLoop 掉落侧）降级。
# 类型收紧（同 XPPool 口径）：acquire() -> GoldCoin（GDScript 覆写允许返回值协变）。
class_name GoldPool
extends ObjectPool


func acquire() -> GoldCoin:
	# 金币取出（满池由调用方合并为大面值金币）
	return super.acquire() as GoldCoin

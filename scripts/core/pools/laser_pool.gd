# scripts/core/pools/laser_pool.gd
# M-13 特化池：LaserBeamPool（光束段实例；架构 §2.3/§5.1：预热 12 / 软 16 / 硬 24）
# 满池行为（§5.1）：拒绝新光束段 + 计数（pool_exhausted；折射分叉的 chain_fused
# 计数由包 3 LaserWeapon 侧在收到 null 时上报——§2.1 事件表 chain_fused 发送者约束）。
# 类型占位说明：架构原文 acquire() -> LaserBeam / release(b: LaserBeam)；LaserBeam 属包 3
#（scripts/combat/weapon/laser_beam.gd），包 0 以 Node2D 占位，包 3 合入后收紧。
class_name LaserBeamPool
extends ObjectPool


func acquire() -> Node2D:
	# 光束段取出（满池拒绝 + 计数，调用方降级）
	return super.acquire() as Node2D

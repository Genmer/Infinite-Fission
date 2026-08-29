# scripts/core/pools/enemy_pool.gd
# M-13 特化池：EnemyPool（架构 §2.3/§5.1：预热 128 / 同屏软 120 / 硬 150；满池生成排队不丢弃）
# 类型收紧（集成包 B.8 第二批，pkg0 池用例已迁移真实敌实体场景）：
# acquire() -> Enemy（架构原文口径；GDScript 覆写允许返回值协变）。
class_name EnemyPool
extends ObjectPool


func acquire() -> Enemy:
	# 敌人实体取出（满池由 EnemySpawner 排队降级——不丢弃，波次不卡死）
	return super.acquire() as Enemy


func release(node: Node) -> void:
	# 架构原文签名 release(e: Enemy)；GDScript 覆写不允许参数收窄，保持 Node 签名。
	# 尸体表现完成后归还（清零含状态容器/词条/订阅——由 e._reset_state() 承担）。
	super.release(node)

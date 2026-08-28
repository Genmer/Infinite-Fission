# scripts/core/pools/enemy_pool.gd
# M-13 特化池：EnemyPool（架构 §2.3/§5.1：预热 128 / 同屏软 120 / 硬 150；满池生成排队不丢弃）
# 类型占位说明：架构原文 acquire() -> Enemy / release(e: Enemy)；Enemy 属包 2
#（scripts/entities/enemy/enemy.gd，extends Node2D），包 0 以 Node2D 占位，包 2 合入后收紧。
class_name EnemyPool
extends ObjectPool


func acquire() -> Node2D:
	# 敌人实体取出（满池由 EnemySpawner 排队降级——不丢弃，波次不卡死）
	return super.acquire() as Node2D


func release(node: Node) -> void:
	# 架构原文签名 release(e: Enemy)；GDScript 覆写不允许参数收窄，保持 Node 签名。
	# 尸体表现完成后归还（清零含状态容器/词条/订阅——由 e._reset_state() 承担）。
	super.release(node)

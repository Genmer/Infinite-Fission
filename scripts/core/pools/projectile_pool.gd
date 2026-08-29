# scripts/core/pools/projectile_pool.gd
# M-13 特化池：ProjectilePool（玩家弹 + 敌弹共用，team 区分；架构 §2.3/§5.1）
# 闸门序：软上限 1500（新弹请求丢弃 + 计数）→ 容量内懒增长 → 硬上限 2000
# （force_recycle_oldest 强制回收最老，FORCED 路径）。
# 类型收紧（集成包 B.8 第二批，pkg0 池用例已迁移真实弹体场景）：
# acquire() -> ProjectileBase（架构原文口径；GDScript 覆写允许返回值协变）。
class_name ProjectilePool
extends ObjectPool

const SOFT_LIMIT_FIELD := &"projectile_soft_limit"    # 全场软上限 1500（BalanceTables 字段键）
var soft_limit: int = 1500
var hard_limit: int = 2000                            # 硬上限（BalanceTables.projectile_hard_limit）
var forced_recycle_count: int = 0                     # FORCED 路径计数（遥测）

# 存活弹出借顺序（Dictionary 保插入序 → 取最老 O(1)；release 时 O(1) 擦除）
var _live_order: Dictionary = {}

# 活跃弹列表（包 4 帧序④：GameLoop 逐弹 tick 的数据源；acquire/release 双向维护）
var _active_list: Array[Node2D] = []


func acquire() -> ProjectileBase:
	# 类型收窄（架构原文口径）；超软上限 → null + 计数（调用方丢弃）
	if total_active() >= soft_limit:
		_register_miss()
		return null
	var node := super.acquire()
	if node == null and total_active() >= hard_limit:
		# 硬上限触达：回收最老存活弹（FORCED 路径）后重试一次
		force_recycle_oldest()
		node = super.acquire()
	if node != null:
		_live_order[node] = true
		_active_list.append(node)
	return node as ProjectileBase


func release(node: Node) -> void:
	# 架构原文签名 release(p: ProjectileBase)；GDScript 覆写不允许参数收窄，保持 Node 签名。
	# 清零契约由基类 _before_repool → p._reset_state() 承担（唯一清零入口）。
	_live_order.erase(node)
	_active_list.erase(node)
	super.release(node)


func active_projectiles() -> Array[Node2D]:
	# 活跃弹列表（包 4 GameLoop 帧序④ tick 数据源；遍历方需倒序防回收重入）
	return _active_list


func force_recycle_oldest() -> void:
	# 硬上限 2000 触达时：回收最老存活弹（FORCED 路径）。
	# 回收原因经 meta 传递，包 2 的 ProjectileBase 在 _reset_state/_recycle 统一收束时消费。
	var oldest: Node = null
	for key in _live_order:
		oldest = key
		break
	if oldest == null:
		return
	forced_recycle_count += 1
	oldest.set_meta(&"_recycle_reason", GameConst.RecycleReason.FORCED)
	release(oldest)


func total_active() -> int:
	# 全场投射物计数（软/硬闸门判据）
	return _live_count

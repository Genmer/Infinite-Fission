# scripts/core/pools/popup_pool.gd
# M-13 特化池：PopupPool（跳字；架构 §2.3/§5.1：预热 80 / 软 80 / 硬 96；满池合并降级）
# 类型占位说明：架构原文 acquire() -> DamagePopup / release(p: DamagePopup)；DamagePopup
# 属包 4（scripts/ui/damage_popup.gd），包 0 以 Node2D 占位，包 4 合入后收紧。
class_name PopupPool
extends ObjectPool


func acquire() -> Node2D:
	# 跳字取出（满池由 PopupManager 合并降级，§六.3：合并到目标已有跳字）
	return super.acquire() as Node2D

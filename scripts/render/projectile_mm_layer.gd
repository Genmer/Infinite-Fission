# scripts/render/projectile_mm_layer.gd
# R293 刀A：弹本体 MM 镜像懒挂层（ProjectileBodyMM._ensure_layer 首注册期挂 host 下——
# R269 聚合 Label「boost 关态永不建」同款懒建先例；boost 关侧本节点不存在=零成本）。
# 职责仅翻转治理（每帧变换/色同步在 TexBucketHost._process 通用环——本层零渲染）：
#   · boost 关：整体拆收（ProjectileBodyMM.teardown_mirrors——逐弹复原 sprite.visible
#     + 镜像注销 + 本层 queue_free 自拆；下个 boost 会话由首注册重新懒建）；
#   · boost 开（层首帧）：桶内追赶扫（翻转前已活弹补注册——spawn 早于层创建的遗珠）。
# R271 S7 台架短路臂共门：shortcircuit_sync 早退与 host 同拍（短路期本层零工作——
# verdict 表保真；host sync_skip_count 计数器不碰——本层非 host 环不计入）。
# 不声明 class_name（路径直引纪律同 projectile_body_mm.gd 头注）。
extends Node

const Facade := preload("res://scripts/render/projectile_body_mm.gd")

var _pending_catchup: bool = true               # 层首帧追赶扫旗（boost 开侧一次）


func _process(_delta: float) -> void:
	if TexBucketHost.shortcircuit_sync:          # R271 S7 共门（host 同拍早退）
		return
	if not PerfGovernor.boost_mode():
		Facade.teardown_mirrors()                # 关侧拆收（内含本层 queue_free + 册清——幂等）
		return
	if _pending_catchup:
		_pending_catchup = false
		Facade.catchup_sweep(get_parent())

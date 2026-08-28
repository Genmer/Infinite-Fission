# tests/fixtures/dummy_pooled.gd
# 包 0 池自测夹具：带 _reset_state 清零契约的最小池化实体原型（架构 §2.3 归还契约）
extends Node2D

var probe: int = 0          # 污染探针：实体运行态（取出后被调用方写入，_reset_state 清零）
var probe_two: int = 0

func _reset_state() -> void:
	# 唯一清零入口（E-04/E-05：清零责任在实例自身）
	probe = 0
	probe_two = 0

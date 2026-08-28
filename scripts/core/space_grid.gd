# scripts/core/space_grid.gd
# SpaceGrid：128px 哈希空间网格（架构 §2.4/§五.2，Q-15：弹-敌碰撞主路径，零 Area2D 回调）。
# GameLoop 持有两实例：enemy_grid（敌人）与 enemy_bullet_grid（敌方弹，供消弹查询）。
# 实现要点：固定桶数组预分配（无 Dictionary 哈希、无每帧分配）；每帧重建走 _occupied
# 只清用过的桶（O(used)）；查询复用 _query_buffer（零 GC 分配）；索引钳制防越界。
# 半径语义：rebuild 以保守半径（max_entity_radius）入桶——query 返回"候选"超集，
# 调用方窄相判定用实体实际 hitbox_r（§4.4 候选语义）；insert 可传实体实际半径精化。
class_name SpaceGrid
extends RefCounted

const CELL_SIZE: int = 128                    # Q-15 裁定格边

var _cols: int = 0                            # 列数（含出屏余量；720 宽 + ±192px 余量 → 9 列）
var _rows: int = 0                            # 行数（1280 高 + ±192px 余量 → 13 行）
var _buckets: Array[Array] = []               # 固定桶数组（_cols×_rows，预分配空 Array）
var _occupied: Array[int] = []                # 本帧被写过的桶索引（O(used) 清空）
var _query_buffer: Array[Node2D] = []         # 复用查询缓冲（零 GC 分配；嵌套查询需调用方自行复制）

var _origin := Vector2.ZERO                   # 网格左上角世界坐标（configure 时 = (−margin, −margin)）
var _max_entity_radius: float = 64.0          # 覆盖扩展半径（hitbox_r 上界，§三.2）
var _radii: Dictionary = {}                   # Node2D → 入桶半径（查询距离精判用）


func configure(world_size: Vector2, margin: float, p_max_entity_radius: float = 64.0) -> void:
	# 计算列行数并预分配桶（world_size 逻辑区 + 两侧 margin 出屏余量）
	_max_entity_radius = maxf(p_max_entity_radius, 0.0)
	_origin = Vector2(-margin, -margin)
	_cols = maxi(1, ceili((maxf(world_size.x, 1.0) + margin * 2.0) / float(CELL_SIZE)))
	_rows = maxi(1, ceili((maxf(world_size.y, 1.0) + margin * 2.0) / float(CELL_SIZE)))
	_buckets.clear()
	_buckets.resize(_cols * _rows)
	for i in range(_buckets.size()):
		_buckets[i] = []
	_occupied.clear()
	_radii.clear()
	_query_buffer.clear()


func rebuild(p_items: Array[Node2D]) -> void:
	# 每帧重建：按 _occupied 清桶（O(used)）→ 全量插入（O(n)）。
	# 插入半径取保守值（max_entity_radius）——候选粗筛口径，窄相判定在调用方。
	for idx in _occupied:
		_buckets[idx].clear()
	_occupied.clear()
	_radii.clear()
	for item in p_items:
		insert(item, _max_entity_radius)


func insert(item: Node2D, radius: float) -> void:
	# 增量插入（按中心坐标入桶，索引钳制防越界；供波内补插）。
	# 契约：同一节点在一次 rebuild 周期内只插入一次（重复插入会产生重复候选）。
	if item == null:
		return
	var idx := _cell_index(_pos_of(item))
	_buckets[idx].append(item)
	_radii[item] = maxf(radius, 0.0)
	if not _occupied.has(idx):
		_occupied.append(idx)


func query_circle(pos: Vector2, radius: float) -> Array[Node2D]:
	# 覆盖格扫描 + 距离精判（复用缓冲；返回值为内部缓冲引用，跨查询持有需调用方复制）
	_query_buffer.clear()
	_for_each_cell_in_range(pos, radius, func(cell: Array) -> void:
		for cand in cell:
			var c: Node2D = cand
			var rc := float(_radii.get(c, 0.0))
			var reach := radius + rc
			if _pos_of(c).distance_squared_to(pos) <= reach * reach:
				_query_buffer.append(c)
	)
	return _query_buffer


func query_nearest(pos: Vector2, radius: float, exclude: Node2D) -> Node2D:
	# 折射寻的/索敌：radius 范围内最近实体（exclude 排除原目标；空返回 null）
	var best: Node2D = null
	var best_d := INF
	for idx in _cells_in_range(pos, radius):
		for cand in _buckets[idx]:
			var c: Node2D = cand
			if c == exclude:
				continue
			var rc := float(_radii.get(c, 0.0))
			var reach := radius + rc
			var d := _pos_of(c).distance_squared_to(pos)
			if d <= reach * reach and d < best_d:
				best_d = d
				best = c
	return best


func query_arc(pos: Vector2, radius: float, dir_from: float, half_arc: float) -> Array[Node2D]:
	# 挥斩扇形：radius 圆内且相对 dir_from 的方位角 ∈ [−half_arc, +half_arc]
	_query_buffer.clear()
	for idx in _cells_in_range(pos, radius):
		for cand in _buckets[idx]:
			var c: Node2D = cand
			var rc := float(_radii.get(c, 0.0))
			var reach := radius + rc
			var cp := _pos_of(c)
			var d := cp.distance_squared_to(pos)
			if d > reach * reach:
				continue
			if d > 0.0001:
				var rel := wrapf((cp - pos).angle() - dir_from, -PI, PI)
				if absf(rel) > half_arc:
					continue
			_query_buffer.append(c)
	return _query_buffer


func _cell_index(pos: Vector2) -> int:
	# 坐标 → 桶索引（除法 + 边界钳制防越界）
	var col := clampi(int((pos.x - _origin.x) / float(CELL_SIZE)), 0, _cols - 1)
	var row := clampi(int((pos.y - _origin.y) / float(CELL_SIZE)), 0, _rows - 1)
	return row * _cols + col


func _for_each_cell_in_range(pos: Vector2, radius: float, cb: Callable) -> void:
	# 遍历覆盖格：查询圆 + 实体最大半径扩展出的外接方格所覆盖的全部桶
	for idx in _cells_in_range(pos, radius):
		cb.call(_buckets[idx])


func _cells_in_range(pos: Vector2, radius: float) -> Array[int]:
	# 覆盖格索引列表（钳制到网格边界；查询点远出网格时收缩到边缘桶）
	var reach := maxf(radius, 0.0) + _max_entity_radius
	var c0 := clampi(int((pos.x - reach - _origin.x) / float(CELL_SIZE)), 0, _cols - 1)
	var c1 := clampi(int((pos.x + reach - _origin.x) / float(CELL_SIZE)), 0, _cols - 1)
	var r0 := clampi(int((pos.y - reach - _origin.y) / float(CELL_SIZE)), 0, _rows - 1)
	var r1 := clampi(int((pos.y + reach - _origin.y) / float(CELL_SIZE)), 0, _rows - 1)
	var out: Array[int] = []
	for row in range(r0, r1 + 1):
		for col in range(c0, c1 + 1):
			out.append(row * _cols + col)
	return out


func _pos_of(node: Node2D) -> Vector2:
	# 世界坐标（树外节点回退 local position——测试/构造期安全口径）
	if node.is_inside_tree():
		return node.global_position
	return node.position

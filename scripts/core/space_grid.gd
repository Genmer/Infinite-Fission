# scripts/core/space_grid.gd
# SpaceGrid：128px 哈希空间网格（架构 §2.4/§五.2，Q-15：弹-敌碰撞主路径，零 Area2D 回调）。
# GameLoop 持有两实例：enemy_grid（敌人）与 enemy_bullet_grid（敌方弹，供消弹查询）。
# 实现要点：固定桶数组预分配（无 Dictionary 哈希、无每帧分配）；每帧重建走 _occupied
# 只清用过的桶（O(used)）；查询复用 _query_buffer（零 GC 分配）；索引钳制防越界。
# 半径语义：入桶/精判统一保守半径（max_entity_radius）——query 返回"候选"超集，
# 调用方窄相判定用实体实际 hitbox_r（§4.4 候选语义）。
# R231 刀A（读路径快照化）：桶改存 int 索引（指向 rebuild 期自有快照数组 _snap_items/
# _snap_pos），④ 相位热路径 query_circle_snap 零逐候选属性读/零 Dictionary 哈希。
# 快照语义等价锚（R231 分析 AC-1/AC-2 已证）：④ 头 rebuild 与弹 pass 之间敌不 tick，
# 活敌 live 位 ≡ 快照位；死亡-回池敌位置不变（reparent keep_global_transform+原点桶）
# 且 dead 短路兜底；击退为速度型（⑤ tick 才位移）。②/⑤ 相位查询点保持 live 读
# （_pos_of 不动，query_circle/query_nearest/query_arc 口径：桶按上一帧旧位、距离按
# live 新位），仅半径从 _radii Dictionary 取值改为常量保守口径（微基准 B 臂已证等价）。
# R239 原生第一刀（修轮 v2，GDExtension 开关门+原生镜像桥接，报告 docs/qa/2026-10-07-R239-
# 原生第一刀-报告.md）：① static 开关门 NATIVE_QUERIES 默认关=纯 GDScript 原路径零
# 扰动（默认行为逐位不变）；② 开且扩展在 ClassDB 注册时 query_circle_snap 走 C++
# 等价实现（repo/native/，逐位口径=double reach+向零截断覆盖格+float32 距离精判，
# 候选序=格行主序×桶内插入序与 GDScript 双循环一致）；③ 原生镜像桥：rebuild/insert
# 期随建 _nat_cells/_nat_pos（与 _snap_items 平行），首次原生查询前一次喂入原生对象
# feed_snapshot（惰性冲刷，一次喂入多次查询）——修轮 v2 起 C++ 侧**零持久对象引用**
# （只存几何 CSR/位置 SoA），实体数组 _snap_items 每次查询传入（COW 共享，生命周期
# 窗口=单次同步调用）；C++ 另有纯几何 indices 口（PackedInt32Array 快照索引）供对拍；
# ④ 扩展缺失/加载失败（.gdextension 未被编辑器扫描入 .godot/extension_list.cfg——
# 原生工具链探索 §5 坑）时 _native_on 恒 false 自动回落 GDScript 路径，无崩溃面。
# live 三查询（circle/nearest/arc）不走原生，口径不动。
class_name SpaceGrid
extends RefCounted

const CELL_SIZE: int = 128                    # Q-15 裁定格边


# ── R239 原生第一刀：GDExtension 开关门（static——全实例共享判定缓存） ─────────
# NATIVE_QUERIES 开且 ClassDB 注册了 FissionSpaceGrid（扩展加载成功）时新 configure 的
# 实例走原生查询；扩展缺失自动回退 GDScript 原路径（native_available 判定）。判定缓存
# 在 static（扩展加载态进程内不变——.gdextension 在引擎启动时载入，不随实例生灭）。
# vc44 A/B 轮（R239 修轮 v2 修复后翻开）：v1 崩溃根因=空喂残留 CSR 桶前缀越界（已修：
# 空喂复位/不变量闸/零持久对象引用；修轮复现用例 T6 转绿+8 套件 on 态全绿+A/B 3.73×
# 保门）；v2 修复版主控验收后翻开——真机 A/B 生死门=vc43（关）vs vc44（开）同构筑对照；
# 异常/无可感收益→单点翻回 false（fail-safe 路径保留）。
static var NATIVE_QUERIES: bool = true
static var _native_state: int = -1            # -1 未判定 / 0 扩展不可用 / 1 可用


static func native_available() -> bool:
	# ClassDB 检查（工具链文档 §5 加载方式：.gdextension → 编辑器扫描 → extension_list.cfg
	# → 引擎启动载入并注册 ClassDB；-s 与游戏模式同效）。can_instantiate 双保险。
	if _native_state == -1:
		_native_state = 1 if (ClassDB.class_exists("FissionSpaceGrid") and ClassDB.can_instantiate("FissionSpaceGrid")) else 0
	return _native_state == 1

var _cols: int = 0                            # 列数（含出屏余量；720 宽 + ±192px 余量 → 9 列）
var _rows: int = 0                            # 行数（1280 高 + ±192px 余量 → 13 行）
var _buckets: Array[Array] = []               # 固定桶数组（_cols×_rows，预分配空 Array；R231 刀A 起内层存 _snap_items 的 int 索引）
var _occupied: Array[int] = []                # 本帧被写过的桶索引（O(used) 清空）
var _occupied_stamp: Array[int] = []          # R188 档0：桶索引 → 最近写入纪戳（insert 成员判定 O(1)，替代 O(n) has 扫描）
var _stamp: int = 0                           # 纪戳计数（rebuild 递增；与 _occupied_stamp 配套）
var _snap_items: Array[Node2D] = []           # R231 刀A：rebuild 期快照实体（自有复制——④ 内击杀 active.erase 为 O(n) 移位，禁引 p_items 做索引基）
var _snap_pos: Array[Vector2] = []            # R231 刀A：与 _snap_items 平行的位置快照（成员级复用零每帧分配——R188 红线）
var _query_buffer: Array[Node2D] = []         # 复用查询缓冲（零 GC 分配；嵌套查询需调用方自行复制）
var _cells_buffer: Array[int] = []            # R188 档0：复用覆盖格索引缓冲（零分配；调用方不得跨查询持有）

var _origin := Vector2.ZERO                   # 网格左上角世界坐标（configure 时 = (−margin, −margin)）
var _max_entity_radius: float = 64.0          # 覆盖扩展半径（hitbox_r 上界，§三.2）

# ── R239 原生第一刀：原生镜像桥（实例侧） ──────────────────────────────────────
var _native_obj: Object = null                # FissionSpaceGrid 原生实例（ClassDB 动态实例化——零编译期依赖）
var _native_on: bool = false                  # 本实例实际启用原生查询（configure 时定型，实例生存期内不翻转——
                                              # 镜像与桶序一致性依赖 rebuild/insert 期同步构建）
var _nat_cells: PackedInt32Array = PackedInt32Array()    # 原生镜像：插入序 cell 索引（与 _snap_items/_snap_pos 平行同长）
var _nat_pos: PackedVector2Array = PackedVector2Array()  # 原生镜像：插入序位置（与 _snap_pos 逐位同值）
var _nat_dirty: bool = true                   # 镜像未喂原生侧（rebuild/补插置位，首次原生查询冲刷——一次喂入多次查询）


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
	_occupied_stamp.clear()
	_occupied_stamp.resize(_cols * _rows)
	# R231 刀A 修正：初值 −1（与 _stamp=0 错开）——保证 virgin-grid（未 rebuild 过）上的
	# insert 也注册占用桶。旧 fill(0) 下首插被纪戳等值吞掉 → 桶不入 _occupied → 下帧
	# rebuild 清不到它；Node2D 桶时代只是幽灵候选（无人察觉），int 索引桶则是悬挂索引
	# （快照数组收缩后 OOB——w1_volley 电池 7.7 万条 SCRIPT ERROR 实锤）。
	# 不变式：桶非空 ⇒ 索引必在 _occupied ⇒ 下次 rebuild 必清。
	_occupied_stamp.fill(-1)
	_stamp = 0
	_snap_items.clear()
	_snap_pos.clear()
	_query_buffer.clear()
	_cells_buffer.clear()
	# R239 原生第一刀：开关门在本实例定型。NATIVE_QUERIES 开且扩展可用 → 动态实例化
	# 原生对象并同步 configure（网格几何+保守半径）；任一不满足 → _native_on 恒 false
	# （全路径零原生调用，即默认态）。
	_native_on = false
	if NATIVE_QUERIES and native_available():
		if _native_obj == null:
			_native_obj = ClassDB.instantiate("FissionSpaceGrid")
		if _native_obj != null:
			_native_on = true
			_native_obj.configure(_cols, _rows, _origin.x, _origin.y, _max_entity_radius)
			_nat_cells.clear()
			_nat_pos.clear()
			_nat_dirty = true


func max_entity_radius() -> float:
	# R231 刀A 只读口：保守覆盖半径（rebuild 恒以此值入桶；查询精判统一走此口径，
	# 不硬编码——Boss/大敌 configure 传更大保守半径时粗判超集天然成立）。
	return _max_entity_radius


func is_empty() -> bool:
	# R287 空场早退口：_snap_items 为全部查询的唯一实体真源（rebuild 全量重建 +
	# insert 同步追加、原生镜像与之平行同长）——快照空 ⇒ 任何 query_* 必然零候选。
	# 逐弹查询方以此 O(1) 判空跳过整条格坐标计算+桶扫链（vc86 实测空场仍耗
	# ~5-6µs/弹/步 × 2.4 万次/秒 ≈ 10 万µs/s 纯废查——清场/弹重窗口归零）。
	return _snap_items.is_empty()


func rebuild(p_items: Array[Node2D]) -> void:
	# 每帧重建：按 _occupied 清桶（O(used)）→ 全量插入（O(n)）。
	# R231 刀A：插入同时建自有快照（_pos_of 取位，保留树外回退 position 语义）——
	# 快照在 ④ 头定型、④ 内不重写，弹 pass 全程索引稳定；外部 p_items 会被击杀链
	# active.erase（O(n) 移位）错位，禁作索引基。
	for idx in _occupied:
		_buckets[idx].clear()
	_occupied.clear()
	_stamp += 1                      # R188 档0：纪戳递增（insert 的占用判定 O(1)）
	_snap_items.clear()
	_snap_pos.clear()
	if _native_on:                   # R239：镜像随 rebuild 重建（桶序=快照序，喂入一次成型）
		_nat_cells.clear()
		_nat_pos.clear()
		_nat_dirty = true
	for item in p_items:
		insert(item, _max_entity_radius)


func insert(item: Node2D, _radius: float) -> void:
	# 增量插入（按中心坐标入桶，索引钳制防越界；供波内补插）。
	# 契约：同一节点在一次 rebuild 周期内只插入一次（重复插入会产生重复候选）。
	# R231 刀A：radius 参数保留兼容旧调用面但忽略（分析 AC-5：生产唯一调用点=rebuild
	# 自身恒传 _max_entity_radius；测试两处自定义半径入桶后 reach 只增=候选超集无害），
	# 入桶/精判半径统一走 max_entity_radius() 口径；快照两数组同步 append（补插与
	# rebuild 覆写交错不串索引）。
	if item == null:
		return
	var pos := _pos_of(item)
	_snap_items.append(item)
	_snap_pos.append(pos)
	var idx := _cell_index(pos)
	if _native_on:                   # R239：镜像随插入同步生长（与 _snap_* 平行；补插后
		_nat_cells.append(idx)       # 置脏——下次原生查询前整份重喂，CSR 一次成型）
		_nat_pos.append(pos)
		_nat_dirty = true
	_buckets[idx].append(_snap_items.size() - 1)
	# R188 档0：纪戳化占用判定（原 _occupied.has 为 O(n)，满载百敌重建时 O(n²)）
	if _occupied_stamp[idx] != _stamp:
		_occupied_stamp[idx] = _stamp
		_occupied.append(idx)


func query_circle_snap(pos: Vector2, radius: float) -> Array[Node2D]:
	# R231 刀A：④ 相位弹-敌查询专用——覆盖格 + 快照位置距离平方精判（零逐候选
	# _pos_of 属性读/零 Dictionary 哈希，微基准 C 臂口径）。命中项从 _snap_items
	# 解析 append 进复用 _query_buffer（契约同 query_circle：内部缓冲，跨查询持有需
	# 调用方复制——_check_collision 已有候选复制）。粗判 reach=radius+max_entity_radius()
	# 候选超集，最终裁定在调用方窄相（_in_reach live 读）。
	# R239 原生第一刀（修轮 v2）：开关开且实例已定型原生 → C++ 查询直返（等价口径逐位
	# 复刻：double reach+向零截断覆盖格+float32 距离精判，候选序=格行主序×桶内插入序=
	# 本函数 GDScript 双循环序）。修轮契约：C++ 侧零持久对象引用（不存 items/不解引用），
	# 实体数组 _snap_items 每次调用传入（COW 共享、调用返回即释放——生命周期窗口=单次
	# 同步调用），C++ 侧命中后就地取实体写类型化成员缓冲直返（零逐命中 GDScript 解析）。
	# 返回值契约不变=内部复用缓冲，跨查询持有调用方复制（_query_buffer 在原生路径不参与）；
	# 镜像 rebuild/insert 期随建，首次原生查询前一次喂入（惰性冲刷）。
	if _native_on:
		if _nat_dirty:
			_native_obj.feed_snapshot(_nat_cells, _nat_pos)
			_nat_dirty = false
		return _native_obj.query_circle_snap_nodes(_snap_items, pos, radius)
	_query_buffer.clear()
	var mr := max_entity_radius()
	var reach := maxf(radius, 0.0) + mr
	var reach_sq := reach * reach
	for idx in _cells_in_range(pos, radius):
		for cand in _buckets[idx]:
			var i: int = cand
			if _snap_pos[i].distance_squared_to(pos) <= reach_sq:
				_query_buffer.append(_snap_items[i])
	return _query_buffer


func query_circle(pos: Vector2, radius: float) -> Array[Node2D]:
	# 覆盖格扫描 + 距离精判（复用缓冲；返回值为内部缓冲引用，跨查询持有需调用方复制）。
	# R188 档0：去 lambda（每调用一次闭包分配）→ 直排双循环；覆盖格走共享 _cells_buffer。
	# R231 刀A：精判半径从 _radii Dictionary 取值改为常量保守口径（B 臂已证等价）；
	# 位置保持 live 读（②/⑤ 相位：桶按上一帧旧位、距离按 live 新位——语义不变）。
	_query_buffer.clear()
	var mr := max_entity_radius()
	for idx in _cells_in_range(pos, radius):
		for cand in _buckets[idx]:
			var c: Node2D = _snap_items[cand]
			var reach := radius + mr
			if _pos_of(c).distance_squared_to(pos) <= reach * reach:
				_query_buffer.append(c)
	return _query_buffer


func query_nearest(pos: Vector2, radius: float, exclude: Node2D) -> Node2D:
	# 折射寻的/索敌：radius 范围内最近实体（exclude 排除原目标；空返回 null）。
	# R231 刀A：半径常量口径同 query_circle；live 读不动。
	var best: Node2D = null
	var best_d := INF
	var mr := max_entity_radius()
	for idx in _cells_in_range(pos, radius):
		for cand in _buckets[idx]:
			var c: Node2D = _snap_items[cand]
			if c == exclude:
				continue
			var reach := radius + mr
			var d := _pos_of(c).distance_squared_to(pos)
			if d <= reach * reach and d < best_d:
				best_d = d
				best = c
	return best


func query_arc(pos: Vector2, radius: float, dir_from: float, half_arc: float) -> Array[Node2D]:
	# 挥斩扇形：radius 圆内且相对 dir_from 的方位角 ∈ [−half_arc, +half_arc]。
	# R231 刀A：半径常量口径；live 读不动（arc_slash 消弹 ② 相位口径不变）。
	_query_buffer.clear()
	var mr := max_entity_radius()
	for idx in _cells_in_range(pos, radius):
		for cand in _buckets[idx]:
			var c: Node2D = _snap_items[cand]
			var reach := radius + mr
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


func _cells_in_range(pos: Vector2, radius: float) -> Array[int]:
	# 覆盖格索引列表（钳制到网格边界；查询点远出网格时收缩到边缘桶）。
	# R188 档0：写共享 _cells_buffer（零分配）；契约同 _query_buffer——不得跨查询持有。
	_cells_buffer.clear()
	var reach := maxf(radius, 0.0) + _max_entity_radius
	var c0 := clampi(int((pos.x - reach - _origin.x) / float(CELL_SIZE)), 0, _cols - 1)
	var c1 := clampi(int((pos.x + reach - _origin.x) / float(CELL_SIZE)), 0, _cols - 1)
	var r0 := clampi(int((pos.y - reach - _origin.y) / float(CELL_SIZE)), 0, _rows - 1)
	var r1 := clampi(int((pos.y + reach - _origin.y) / float(CELL_SIZE)), 0, _rows - 1)
	for row in range(r0, r1 + 1):
		var row_base := row * _cols
		for col in range(c0, c1 + 1):
			_cells_buffer.append(row_base + col)
	return _cells_buffer


func _pos_of(node: Node2D) -> Vector2:
	# 世界坐标（树外节点回退 local position——测试/构造期安全口径）
	if node.is_inside_tree():
		return node.global_position
	return node.position

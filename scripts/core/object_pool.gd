# scripts/core/object_pool.gd
# M-13 ObjectPool 通用池基类（架构 §2.3）。
# 归还契约（E-04/E-05）：清零责任在实例自身（node._reset_state()），池在 release 前调用
# （基类 _before_repool 钩子统一分发）；清零后残留状态由 _assert_clean 拦截（push_error）。
# 池侧机械清理（visible=false + 停止处理）由 _prepare_for_pool 保证；取出后由实体自行激活。
# 满池降级（AC-14.4）：acquire() 返回 null → 调用方丢弃 + pool_exhausted 计数，不阻塞不崩溃。
# GDScript 覆写限制说明：本工程 Godot 4.3 的方法覆写仅允许返回值协变（收窄）、参数逆变（放宽），
# 故特化池不覆写带窄类型参数的 release（架构原文签名以注释保留），类型收窄由 acquire 返回值承担。
class_name ObjectPool
extends Node

signal exhausted(pool_id: StringName)         # 转发 EventBus.pool_exhausted

var pool_id: StringName = &""                 # 池标识（遥测键）
var _scene: PackedScene                       # 池化场景模板
var _free_list: Array[Node] = []              # 空闲栈
var _capacity: int = 0                        # 硬容量（= 硬上限）
var _live_count: int = 0                      # 当前在外实例数
var _hits: int = 0                            # 命中（未触发增长）计数
var _misses: int = 0                          # 满池拒绝/丢弃计数

# 遥测计数器（DebugStats 拉取采集点，§5.5 埋点表；AC-14.1/14.3 验收口径）
var runtime_instantiate_count: int = 0        # 预热期以外的 instantiate()（运行期稳态必须 = 0）
var pollution_count: int = 0                  # _assert_clean 违例累计（AC-14.3）
var rejected_release_count: int = 0           # 重复归还 / 外来节点拦截累计

# 空闲栈成员标记（重复归还/外来节点防御；meta 布尔：true = 在空闲栈内）
const _META_IN_POOL := &"_object_pool_in_free_list"


func setup(p_id: StringName, p_scene: PackedScene, p_capacity: int) -> void:
	# 绑定模板与容量（容量 ≤0 由 GameConfig 启动校验拦截；运行期钳制为 0 = 永远空池）
	pool_id = p_id
	_scene = p_scene
	_capacity = maxi(p_capacity, 0)


func prewarm(count: int) -> void:
	# 启动预热：instantiate 到 count 个入 _free_list（计数不计入运行期实例化）
	for i in range(maxi(count, 0)):
		if _free_list.size() + _live_count >= _capacity:
			break
		var node := _instantiate_node(false)
		_prepare_for_pool(node)
		node.set_meta(_META_IN_POOL, true)
		_free_list.append(node)


func acquire() -> Node:
	# 取出：空闲栈弹出 → 容量内懒增长 → 满池 null + 计数（调用方丢弃，不阻塞不崩溃）
	if not _free_list.is_empty():
		var node: Node = _free_list.pop_back()
		node.set_meta(_META_IN_POOL, false)
		_live_count += 1
		_hits += 1
		_assert_clean(node)
		return node
	if _scene != null and _free_list.size() + _live_count < _capacity:
		# 容量内懒增长（§5.1：instantiate 仅发生在预热与容量内懒增长）
		var node := _instantiate_node(true)
		_live_count += 1
		return node
	_register_miss()
	return null


func release(node: Node) -> void:
	# 归还：成员校验 → 实体清零钩子 → 机械清理 → 清洁断言 → 压回 _free_list
	if node == null:
		return
	if bool(node.get_meta(_META_IN_POOL, true)):
		# 默认值 true：外来节点（无标记）与已在空闲栈的节点（重复归还）一并拦截
		rejected_release_count += 1
		push_error("[ObjectPool:%s] 拒绝归还（重复归还或外来节点）：%s" % [pool_id, str(node.name)])
		return
	_before_repool(node)
	_prepare_for_pool(node)
	_assert_clean(node)
	node.set_meta(_META_IN_POOL, true)
	_live_count -= 1
	_free_list.append(node)


func stats() -> Dictionary:
	# {hits, misses, live, free, capacity}（DebugStats 源）；附加遥测键见注释
	return {
		"hits": _hits,
		"misses": _misses,
		"live": _live_count,
		"free": _free_list.size(),
		"capacity": _capacity,
		"runtime_instantiates": runtime_instantiate_count,
		"pollution": pollution_count,
		"rejected_releases": rejected_release_count,
	}


func _assert_clean(node: Node) -> void:
	# 开发期池污染断言（AC-14.3：取出/归还双向）；release 构建剥离（§1.3-7）
	if OS.has_feature("release"):
		return
	var problems: Array[String] = []
	var ci := node as CanvasItem
	if ci != null and ci.visible:
		problems.append("visible=true（应隐藏）")
	if node.is_processing() or node.is_physics_processing():
		problems.append("processing 未关闭（清零后词条回调拦截，E-04）")
	if not problems.is_empty():
		pollution_count += 1
		push_error("[ObjectPool:%s] 池污染（%s）：%s" % [pool_id, str(node.name), "、".join(problems)])


# ── 内部 ──────────────────────────────────────────────────────────
func _register_miss() -> void:
	# 满池丢弃 + 计数：本地信号 + 转发 EventBus.pool_exhausted（DebugStats 消费）
	_misses += 1
	exhausted.emit(pool_id)
	EventBus.emit_pool_exhausted(pool_id)


func _instantiate_node(p_count_runtime: bool) -> Node:
	var node: Node = _scene.instantiate()
	add_child(node)
	node.set_meta(_META_IN_POOL, false)
	if p_count_runtime:
		runtime_instantiate_count += 1
	return node


func _before_repool(node: Node) -> void:
	# 实体清零钩子：清零责任在实例自身（node._reset_state()），池在 release 前调用（E-04/E-05）。
	# 特化池可覆写本钩子追加处理（如粒子发射器停播）。
	if node != null and node.has_method(&"_reset_state"):
		node.call(&"_reset_state")


func _prepare_for_pool(node: Node) -> void:
	# 池侧机械清理：visible=false + 停止处理（§5.3 回收口径；取出后由实体自行激活）
	var ci := node as CanvasItem
	if ci != null:
		ci.visible = false
	node.set_process(false)
	node.set_physics_process(false)

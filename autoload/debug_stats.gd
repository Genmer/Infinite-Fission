# autoload/debug_stats.gd —— 注册名 DebugStats（不声明 class_name，§0.1-3）
# 验收测量面板（架构 §5.5；release 构建剥离，§1.3-7 口径：dev 断言开关关闭）
# 采集口径：帧时间 P50/P95/P99（60s 环形缓冲）、帧序阶段分解（§5.4 ①~⑩ 预算对账）、
# 池命中率/丢弃数（ObjectPool.stats() 聚合）、事件派发计数（EventBus 拉取）、结算计数。
extends Node

const FRAME_BUFFER_CAPACITY := 7200          # 60s @ 120Hz 逐帧序列（环形覆盖写）
const STAGE_BUFFER_CAPACITY := 7200          # 阶段耗时环形缓冲（同窗口）
const FRAME_REPORT_INTERVAL := 60            # 每 60 帧聚合一次（§5.5）

var dev_assertions: bool = true              # Dev 断言开关（release 构建自动关闭）
var _frame_times: Array[float] = []          # 环形缓冲语义（固定容量覆盖写）
var _frame_cursor: int = 0
var _stage_times: Dictionary = {}            # 帧序阶段名 -> Array[float]（环形覆盖写）
var _stage_cursors: Dictionary = {}          # 阶段名 -> 写游标
var _stage_starts: Dictionary = {}           # 阶段名 -> begin 时刻（usec）
var _counters: Dictionary = {}               # 全部计数器（池/管线/总线共用）
var _frame_count: int = 0                    # 帧计数（报表聚合节拍）


func _ready() -> void:
	# release 构建剥离（A1 §3 口径：仅开发/验收构建启用断言与采样）
	if OS.has_feature("release"):
		dev_assertions = false


func _process(delta: float) -> void:
	# 采样通道（§0.2：_process 仅用于纯表现/DebugStats 采样）
	_push_frame_time(delta)
	_frame_count += 1
	if _frame_count % FRAME_REPORT_INTERVAL == 0:
		frame_report()


# ── 帧阶段计时（GameLoop 帧序各阶段入口；§5.4 预算对账） ──────────
func begin_stage(p_stage: StringName) -> void:
	_stage_starts[p_stage] = Time.get_ticks_usec()


func end_stage(p_stage: StringName) -> void:
	var t0: int = _stage_starts.get(p_stage, 0)
	if t0 == 0:
		push_warning("[DebugStats] end_stage 无对应 begin_stage：%s" % p_stage)
		return
	_stage_starts.erase(p_stage)
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0
	if not _stage_times.has(p_stage):
		var buf: Array[float] = []
		_stage_times[p_stage] = buf
		_stage_cursors[p_stage] = 0
	var buf: Array[float] = _stage_times[p_stage]
	if buf.size() < STAGE_BUFFER_CAPACITY:
		buf.append(ms)
	else:
		var cursor: int = _stage_cursors[p_stage]
		buf[cursor] = ms
		_stage_cursors[p_stage] = (cursor + 1) % STAGE_BUFFER_CAPACITY


# ── 计数器通道（池/管线/总线共用） ─────────────────────────────────
func count(p_key: StringName, p_delta: int = 1) -> void:
	_counters[p_key] = int(_counters.get(p_key, 0)) + p_delta


func get_counter(p_key: StringName) -> int:
	return int(_counters.get(p_key, 0))


# ── 帧报表（每 60 帧聚合；p50/p95/p99 + 阶段分解 + 池/事件快照） ──
func frame_report() -> Dictionary:
	var report := {
		"p50": percentile_ms(0.50),
		"p95": percentile_ms(0.95),
		"p99": percentile_ms(0.99),
		"stage_breakdown": _stage_breakdown(),
		"pools": _pool_snapshot(),
		"events": _event_snapshot(),
		"counters": _counters.duplicate(),
	}
	return report


func percentile_ms(q: float) -> float:
	# 帧时间分位数（秒 → 毫秒）；空缓冲返回 0
	if _frame_times.is_empty():
		return 0.0
	var sorted := _frame_times.duplicate()
	sorted.sort()
	var idx: int = clampi(int(floor(q * float(sorted.size()))), 0, sorted.size() - 1)
	return sorted[idx] * 1000.0


func _stage_breakdown() -> Dictionary:
	var out := {}
	for stage in _stage_times:
		var buf: Array[float] = _stage_times[stage]
		if buf.is_empty():
			continue
		var sorted: Array[float] = buf.duplicate()
		sorted.sort()
		var total := 0.0
		for v in sorted:
			total += v
		var p95_i: int = clampi(int(floor(0.95 * float(sorted.size()))), 0, sorted.size() - 1)
		out[stage] = {
			"samples": sorted.size(),
			"mean_ms": total / float(sorted.size()),
			"p95_ms": sorted[p95_i],
		}
	return out


func _pool_snapshot() -> Dictionary:
	# 池命中率/丢弃数聚合（ObjectPool.stats() 拉取；§5.5 埋点表）
	var out := {}
	for pool in _collect_pools():
		out[pool.pool_id] = pool.stats()
	return out


func _event_snapshot() -> Dictionary:
	# 事件派发计数快照（EventBus._dispatch_count 拉取；风暴告警 + 结算计数口径）
	var tree := get_tree()
	if tree == null or tree.get_root() == null:
		return {}
	var bus: Node = tree.get_root().get_node_or_null("EventBus")
	if bus == null:
		return {}
	var counts: Dictionary = bus.get("_dispatch_count")
	var out := {}
	for key in counts:
		out[key] = counts[key]
	return out


# ── CSV 导出（模式 B 回归与验收归档） ─────────────────────────────
func export_csv(p_path: String) -> void:
	var f := FileAccess.open(p_path, FileAccess.WRITE)
	if f == null:
		push_error("[DebugStats] CSV 导出失败：%s" % p_path)
		return
	f.store_line("section,key,value")
	var rep := frame_report()
	f.store_line("frame,p50_ms,%s" % str(rep["p50"]))
	f.store_line("frame,p95_ms,%s" % str(rep["p95"]))
	f.store_line("frame,p99_ms,%s" % str(rep["p99"]))
	for stage in rep["stage_breakdown"]:
		var info: Dictionary = rep["stage_breakdown"][stage]
		f.store_line("stage,%s.p95_ms,%s" % [stage, str(info["p95_ms"])])
		f.store_line("stage,%s.mean_ms,%s" % [stage, str(info["mean_ms"])])
	for key in rep["counters"]:
		f.store_line("counter,%s,%s" % [key, str(rep["counters"][key])])
	f.close()


# ── AC 断言（验收口径；Dev 断言开关关闭时恒真） ───────────────────
func assert_zero_instantiations() -> bool:
	# AC-14.1：运行期实例化计数 = 0（10 分钟 soak）
	if not dev_assertions:
		return true
	var ok := true
	for pool in _collect_pools():
		if pool.runtime_instantiate_count > 0:
			ok = false
			push_error("[DebugStats] AC-14.1 违例：池 %s 运行期实例化 %d 次"
				% [pool.pool_id, pool.runtime_instantiate_count])
	return ok


func assert_pools_clean() -> bool:
	# AC-14.3：池污染断言（取出/归还双向清洁 + 拒绝归还拦截）
	if not dev_assertions:
		return true
	var ok := true
	for pool in _collect_pools():
		if pool.pollution_count > 0 or pool.rejected_release_count > 0:
			ok = false
			push_error("[DebugStats] AC-14.3 违例：池 %s 污染 %d 次 / 拒绝归还 %d 次"
				% [pool.pool_id, pool.pollution_count, pool.rejected_release_count])
	return ok


# ── 内部：帧缓冲与池发现 ──────────────────────────────────────────
func _push_frame_time(p_seconds: float) -> void:
	if _frame_times.size() < FRAME_BUFFER_CAPACITY:
		_frame_times.append(p_seconds)
	else:
		_frame_times[_frame_cursor] = p_seconds
	_frame_cursor = (_frame_cursor + 1) % FRAME_BUFFER_CAPACITY


func _collect_pools() -> Array[ObjectPool]:
	# 场景树扫描发现 ObjectPool 实例（DebugStats 只读拉取，池不反向依赖；§1.2 依赖矩阵）
	var out: Array[ObjectPool] = []
	var tree := get_tree()
	if tree != null:
		_walk_pools(tree.get_root(), out)
	return out


func _walk_pools(node: Node, out: Array[ObjectPool]) -> void:
	if node is ObjectPool:
		out.append(node)
	for child in node.get_children():
		_walk_pools(child, out)

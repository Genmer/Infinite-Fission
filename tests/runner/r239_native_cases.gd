# tests/runner/r239_native_cases.gd
# R239 原生第一刀用例体（入口 test_r239_native.gd 运行时 load——cases 禁 test_ 前缀
# 防电池 glob 误收，R230 教训）。覆盖任务书等价性验收面：
# T1 开关门矩阵：static 门默认关（零扰动基态）；扩展 ClassDB 判定；开启+可用→实例走
#    原生（_native_on 白盒断言）；开启+模拟扩展缺失（_native_state 白盒注入 0）→ 自动
#    回落 GDScript（_native_on=false 实证回退分支，桌面无法真卸载扩展的唯一可行覆盖）；
#    收尾恢复现场（static 门回 false、_native_state 回 1）。
# T2 off/on 两臂逐位等价 × 多组几何 × 多半径：随机布局（seed 固定）/密集重叠（300 实体
#    挤 2 格）/空网格/负半径/出网格钳制（远点收缩到边缘桶）；结果=Node2D 引用序列逐位
#    （集合+顺序双断言——命中序=弹段数据化 §5.1 现序口径，R238 验收键）。
# T3 边界恰等含入：reach²==d² 候选含入口径（R231 T4 同构——构造轴对齐恰等距实体）。
# T4 生命周期：rebuild 后波内补插（insert）两臂仍逐位；连续两帧 rebuild（不同布局）镜像
#    不串帧；同位重查确定性（原生成员缓冲复用不串查——契约=调用方跨查询持有须复制）。
# T5 live 三查询（circle/nearest/arc）off/on 两臂逐位回归——镜像接入不得扰动 live 口径。
# 夹具纪律：纯 headless 无窗口（不进场景树——树外 Node2D 走 _pos_of position 回退口径）；
# 种子固定；收尾 free 全部构造节点；static 门恢复默认关（后续电池套件零扰动）。
extends RefCounted

const GRID_SCRIPT := "res://scripts/core/space_grid.gd"
const SCREEN := Vector2(720.0, 1280.0)
const MARGIN := 192.0
const MAX_R := 64.0
const SEED := 20261006

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _sg: GDScript = null
var _keep: Array[Node2D] = []                 # 构造实体（收尾 free）


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	_sg = load(GRID_SCRIPT)
	if _sg == null:
		_check("SpaceGrid 脚本加载", false, GRID_SCRIPT)
		_report()
		return
	_test_1_gate_matrix()
	_test_2_off_on_bitwise()
	_test_3_boundary_exact()
	_test_4_lifecycle()
	_test_5_live_queries_untouched()
	_restore_and_free()
	_report()


func fail_count() -> int:
	return _fail


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("  PASS | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s（%s）" % [p_name, p_detail])
		print("  FAIL | %s（%s）" % [p_name, p_detail])


func _report() -> void:
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)
	print("验收汇总：%d/%d 通过" % [_pass, _pass + _fail])


# ── 夹具 ──────────────────────────────────────────────────────────────────────

func _make_node(p_pos: Vector2) -> Node2D:
	var n := Node2D.new()
	n.position = p_pos
	_keep.append(n)
	return n


func _make_grid(p_native: bool) -> Object:
	_sg.NATIVE_QUERIES = p_native
	var g: Object = _sg.new()
	g.configure(SCREEN, MARGIN, MAX_R)
	return g


func _snapshot_query(p_grid: Object, p_pos: Vector2, p_radius: float) -> Array:
	# query_circle_snap 返回内部复用缓冲——跨查询持有必须复制（两臂同契约，公平口径）
	return p_grid.query_circle_snap(p_pos, p_radius).duplicate()


func _arrays_identical(p_a: Array, p_b: Array) -> bool:
	if p_a.size() != p_b.size():
		return false
	for i in range(p_a.size()):
		if p_a[i] != p_b[i]:               # Node2D 引用比较
			return false
	return true


func _restore_and_free() -> void:
	_sg.NATIVE_QUERIES = false
	_sg._native_state = 1
	for n in _keep:
		n.free()
	_keep.clear()


# ── T1 开关门矩阵 ─────────────────────────────────────────────────────────────

func _test_1_gate_matrix() -> void:
	print("T1 开关门矩阵")
	_check("T1.1 static 门默认关", bool(_sg.NATIVE_QUERIES) == false, "默认值被扰动——默认态=纯 GDScript 零扰动红线")
	_check("T1.2 扩展已注册（ClassDB）", bool(_sg.native_available()), "FissionSpaceGrid 未加载——.gdextension 未被编辑器扫描（extension_list.cfg 坑）？")
	var empty: Array[Node2D] = []
	var g_off: Object = _make_grid(false)
	g_off.rebuild(empty)
	_check("T1.3 门关→实例不走原生", bool(g_off._native_on) == false, str(g_off._native_on))
	var g_on: Object = _make_grid(true)
	g_on.rebuild(empty)
	_check("T1.4 门开+扩展可用→实例走原生", bool(g_on._native_on) == true, "开关开但回落 GDScript——扩展加载失败？")
	# 模拟扩展缺失（白盒注入 static 判定缓存——桌面无法真卸载扩展的回退分支覆盖）
	_sg._native_state = 0
	var g_fb: Object = _make_grid(true)
	g_fb.rebuild(empty)
	_check("T1.5 扩展缺失→自动回落 GDScript", bool(g_fb._native_on) == false, "回退分支未生效——ClassDB 判定失效？")
	_check("T1.6 回落实例查询走 GDScript 路径且结果正确", _arrays_identical(_snapshot_query(g_fb, Vector2(100, 100), 30.0), []), "空网格应返回空")
	# T1.7 原生空结果返回也必须是类型化 Array[Node2D]（空返回走 C++ 独立分支——
	# 若返回裸 Array，SpaceGrid.query_circle_snap 的 typed return 会对每次空查询
	# 抛 SCRIPT ERROR——regression 实测锚：首轮 bench 2.6 万条错误日志）。
	var raw_empty: Variant = g_on.query_circle_snap(Vector2(100, 100), 30.0)
	_check("T1.7 原生空返回为类型化 Array[Node2D]", raw_empty is Array and raw_empty.is_typed() and raw_empty.size() == 0,
			"空返回未类型化——GDScript 侧每次空查询将抛 SCRIPT ERROR")
	_sg._native_state = 1                  # 现场恢复（T2+ 需要）
	_sg.NATIVE_QUERIES = false


# ── T2 off/on 两臂逐位等价 × 多组几何 ────────────────────────────────────────

func _test_2_off_on_bitwise() -> void:
	print("T2 off/on 两臂逐位等价（多几何×多半径×多查询点）")
	var radii: Array[float] = [0.0, 6.0, 22.3, 64.0, 300.0, -5.0]
	var empty: Array[Node2D] = []
	var geoms := {
		"随机布局120": _geom_random(),
		"密集重叠300": _geom_dense(),
		"空网格": empty,
	}
	var seed_points: Array[Vector2] = []
	# 确定性点阵（全场覆盖）
	for i in range(24):
		seed_points.append(Vector2(float(i % 8) * 110.0 - 40.0, float(i / 8) * 210.0 - 60.0))
	# 种子化随机点（含 margin 域外/格缝）
	seed(SEED)
	for i in range(16):
		seed_points.append(Vector2(randf_range(-260.0, 1000.0), randf_range(-260.0, 1560.0)))
	for geom_name in geoms:
		var items: Array[Node2D] = geoms[geom_name]
		var g_off: Object = _make_grid(false)
		var g_on: Object = _make_grid(true)
		g_off.rebuild(items)
		g_on.rebuild(items)
		if bool(g_on._native_on) != true:
			_check("T2[%s] on 臂走原生" % geom_name, false, "扩展未加载——整套件前提不成立")
			continue
		var all_ok := true
		var mismatches: Array[String] = []
		for p in seed_points:
			for r in radii:
				var a: Array = _snapshot_query(g_off, p, r)
				var b: Array = _snapshot_query(g_on, p, r)
				if not _arrays_identical(a, b):
					all_ok = false
					if mismatches.size() < 3:
						mismatches.append("pos=%s r=%s off=%d on=%d" % [str(p), str(r), a.size(), b.size()])
		_check("T2[%s] 两臂逐位（%d 点×%d 半径）" % [geom_name, seed_points.size(), radii.size()], all_ok,
				"; ".join(mismatches))
	# 非空返回类型化抽查（随机布局网格上取半径 400 保证命中）
	_sg.NATIVE_QUERIES = true
	var g_t: Object = _make_grid(true)
	g_t.rebuild(geoms["随机布局120"])
	var raw_nonempty: Variant = g_t.query_circle_snap(Vector2(360.0, 640.0), 400.0)
	_check("T2.4 原生非空返回为类型化 Array[Node2D] 且有命中", raw_nonempty is Array and raw_nonempty.is_typed() and raw_nonempty.size() > 0,
			"非空返回未类型化或零命中")


func _geom_random() -> Array[Node2D]:
	seed(SEED + 1)
	var items: Array[Node2D] = []
	for i in range(120):
		items.append(_make_node(Vector2(randf_range(-100.0, 820.0), randf_range(-100.0, 1380.0))))
	return items


func _geom_dense() -> Array[Node2D]:
	seed(SEED + 2)
	var items: Array[Node2D] = []
	# 300 实体挤 2 格内（密集重叠——候选去重/同桶多实体序压力面）
	for i in range(300):
		items.append(_make_node(Vector2(randf_range(300.0, 420.0), randf_range(600.0, 720.0))))
	return items


# ── T3 边界恰等含入 ──────────────────────────────────────────────────────────

func _test_3_boundary_exact() -> void:
	print("T3 边界恰等含入（reach²==d² 口径）")
	# radius=0 → reach=64.0；实体恰在 (64,0)/(0,64) 轴对齐距离 → d²=4096.0（float32/double
	# 双域精确值）→ 恰等含入；对照 64.5 距离实体在 reach 外排除。几何构造全轴对齐避浮点噪声。
	var items: Array[Node2D] = [
		_make_node(Vector2(300.0 + 64.0, 500.0)),
		_make_node(Vector2(300.0, 500.0 + 64.0)),
		_make_node(Vector2(300.0 + 64.5, 500.0)),
	]
	var g_off: Object = _make_grid(false)
	var g_on: Object = _make_grid(true)
	g_off.rebuild(items)
	g_on.rebuild(items)
	var a: Array = _snapshot_query(g_off, Vector2(300.0, 500.0), 0.0)
	var b: Array = _snapshot_query(g_on, Vector2(300.0, 500.0), 0.0)
	_check("T3.1 两臂恰等候选数一致", a.size() == b.size(), "off=%d on=%d" % [a.size(), b.size()])
	_check("T3.2 两臂恰等候选序逐位", _arrays_identical(a, b), "")
	_check("T3.3 恰等含入生效（2 实体）", a.size() == 2, "d²==reach² 应含入（R231 T4 口径）——实际 %d" % a.size())


# ── T4 生命周期 ──────────────────────────────────────────────────────────────

func _test_4_lifecycle() -> void:
	print("T4 生命周期（补插/多帧 rebuild/连续查询不串）")
	# T4.1 波内补插：rebuild 90 实体后 insert 6 补插（其一在查询带内）——两臂逐位
	seed(SEED + 3)
	var items: Array[Node2D] = []
	for i in range(90):
		items.append(_make_node(Vector2(randf_range(0.0, 720.0), randf_range(0.0, 1280.0))))
	var late := _make_node(Vector2(360.0, 640.0))   # 补插实体（查询点正下方）
	var g_off: Object = _make_grid(false)
	var g_on: Object = _make_grid(true)
	g_off.rebuild(items)
	g_on.rebuild(items)
	g_off.insert(late, 64.0)
	g_on.insert(late, 64.0)
	var q := Vector2(365.0, 645.0)
	var a1: Array = _snapshot_query(g_off, q, 20.0)
	var b1: Array = _snapshot_query(g_on, q, 20.0)
	_check("T4.1 补插后两臂逐位（含补插实体）", _arrays_identical(a1, b1) and not a1.is_empty(), "off=%d on=%d" % [a1.size(), b1.size()])
	# T4.2 连续两帧 rebuild（不同布局）——镜像/桶不串帧
	seed(SEED + 4)
	var items2: Array[Node2D] = []
	for i in range(60):
		items2.append(_make_node(Vector2(randf_range(100.0, 600.0), randf_range(200.0, 1100.0))))
	g_off.rebuild(items2)
	g_on.rebuild(items2)
	var mism := false
	for i in range(50):
		var p := Vector2(float(i) * 15.0, float(i) * 23.0)
		if not _arrays_identical(_snapshot_query(g_off, p, 25.0), _snapshot_query(g_on, p, 25.0)):
			mism = true
			break
	_check("T4.2 第二帧 rebuild 后两臂逐位", not mism, "镜像串帧？")
	# T4.3 连续查询确定性（同位重查结果稳定——原生成员缓冲复用不残留前查询状态）
	var q_a := Vector2(360.0, 640.0)
	var q_b := Vector2(50.0, 50.0)
	var held: Array = _snapshot_query(g_on, q_a, 300.0)          # 查 A（复制）
	var _mid: Array = _snapshot_query(g_on, q_b, 3.0)            # 查 B（清空/异集）
	var held_again: Array = _snapshot_query(g_on, q_a, 300.0)    # 同位重查 A
	_check("T4.3 同位重查结果稳定（缓冲复用不串查）", _arrays_identical(held, held_again) and not held.is_empty(), "前查残留/串查？")


# ── T5 live 三查询回归（镜像接入不得扰动 live 口径） ─────────────────────────

func _test_5_live_queries_untouched() -> void:
	print("T5 live 三查询 off/on 两臂回归")
	seed(SEED + 5)
	var items: Array[Node2D] = []
	for i in range(80):
		items.append(_make_node(Vector2(randf_range(0.0, 720.0), randf_range(0.0, 1280.0))))
	var g_off: Object = _make_grid(false)
	var g_on: Object = _make_grid(true)
	g_off.rebuild(items)
	g_on.rebuild(items)
	# live 读语义：移动节点后查询按新位（②/⑤ 相位口径——空间格不改，距离按 live）
	items[0].position = Vector2(200.0, 200.0)
	var ok_c := true
	var ok_n := true
	var ok_a := true
	for i in range(40):
		var p := Vector2(float(i) * 19.0, float(i) * 27.0)
		var c_off: Array = g_off.query_circle(p, 40.0).duplicate()
		var c_on: Array = g_on.query_circle(p, 40.0).duplicate()
		if not _arrays_identical(c_off, c_on):
			ok_c = false
		var n_off: Node2D = g_off.query_nearest(p, 200.0, items[1])
		var n_on: Node2D = g_on.query_nearest(p, 200.0, items[1])
		if n_off != n_on:
			ok_n = false
		var a_off: Array = g_off.query_arc(p, 120.0, 0.0, PI / 4.0).duplicate()
		var a_on: Array = g_on.query_arc(p, 120.0, 0.0, PI / 4.0).duplicate()
		if not _arrays_identical(a_off, a_on):
			ok_a = false
	_check("T5.1 query_circle 两臂逐位", ok_c, "live 口径被扰动？")
	_check("T5.2 query_nearest 两臂逐位", ok_n, "live 口径被扰动？")
	_check("T5.3 query_arc 两臂逐位", ok_a, "live 口径被扰动？")

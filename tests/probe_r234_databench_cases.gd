# tests/probe_r234_databench_cases.gd（R234 弹段数据化微基准用例体——入口运行时加载）
# 六臂设计（任务书三臂 A/B/C + 追加披露臂 D/E/F，全部同进程同日跑——性能结论同进程纪律）：
# · 共量纲：N=10000 实体 × FRAMES=100 测量帧（WARMUP=20 预热帧后）× ROUNDS=3 轮（轮间
#   臂序固定 A→B→C→D→E→F，报告取三轮 p50 的中位）。计时=Time.get_ticks_usec() 包每帧
#   循环本体（计时两次读数 ~0.1µs vs 每帧 ms 级，可忽略）。
# · A 臂（任务书）：for n in nodes: var g := n.global_position; n.global_position = g + DELTA
#   ——镜像 _tick_fast/_tick_fast_player 的运动核读写形状（projectile_base.gd:431/:473
#   `global_position += velocity * p_gd`）。10k Node2D 挂同一原点根 Node2D（池根/贴图桶
#   同构：原点无变换 local≡global，且在树内——global_position 语义与生产一致）。
# · B 臂（任务书）：for i in N: px[i] = px[i] + DX; py[i] = py[i] + DY（PackedFloat32Array
#   SoA——读入局部再写回，与 A 臂算术语义同形）。
# · C 臂（任务书）：for o in objs: o.x = o.x + DX; o.y = o.y + DY（RefCounted 脚本成员——
#   「数据搬出 Node2D 但仍在对象上」的中间态对照）。
# · D 臂（披露）：for n in nodes: var p := n.position; n.position = p + DELTA——Node2D local
#   通道（视觉壳阶段若保留 Node2D 壳、桶为原点无变换时的写位路径）。
# · E 臂（披露）：BenchBullet.tick_fast_clone(gd) 逐弹方法调用——现网 _tick_fast_player
#   克隆体（projectile_base.gd:447-490）：寿命减→swept 暂存→直线运动→traveled 累计→
#   range 超程→出界六步（去网格查询与命中链——纯运动学核）。全部弹恒活（寿命/射程
#   1e9、初位居中、100 帧漂移 ≤150px 不出界）→ 每帧每实体工作量确定。
# · F 臂（披露）：同语义 typed 数组批处理循环（px/py/vx/vy/lifetime/traveled/range/radius
#   全 PackedFloat32Array，单函数循环零调用零属性）——目标架构形态。swept 暂存在数据化
#   下免费（步前值=写回前的 px[i]，免存），E 臂照付（现网形状）——该差量属路线收益，披露。
# · 判读口径：A/B=属性轴系数（任务书地基数字）；E/F=快路径弹现状→数据化可投影收益对；
#   C/B=中间态参考；D=视觉壳候选写位路径参考。桌面≠真机（×0.5-2，R224 声明；R210 前科：
#   Variant/属性跨界在 ARM 放大）——系数用于路线判别，绝对 ms 不外推。
# · 夹具纪律：确定性初始位（i 公式，无 RNG 消费；SEED 常量入 meta 备查）；零测量窗分配
#   （数组/节点全部预建）；10k 节点实例化在计时窗外；测量完 queue_free 根并等两帧实释放。
extends RefCounted

const SEED := 20261006                    # 夹具无 RNG 消费——常量入 meta 备查（纪律）
const N := 10000                          # 实体数（任务书：1 万）
const FRAMES := 100                       # 测量帧数（任务书：100 帧）
const WARMUP := 20                        # 预热帧（首帧脚本/缓存热身后才计入）
const ROUNDS := 3                         # 轮数（p50 取中位）
const DT := 1.0 / 60.0                    # 步长（E/F 臂运动学口径）
const DELTA := Vector2(1.5, -0.75)        # A/D 臂每帧位移（E/F 臂速度=DELTA/DT 同量纲）
const DX := 1.5
const DY := -0.75
const SCREEN := Vector2(720.0, 1280.0)    # 逻辑分辨率（E/F 出界判定口径同现网）
const OFF_MARGIN := 102.0                 # 出界余量（fast_radius 6 + OFFSCREEN_MARGIN 96）
const JSON_PATH := "res://docs/qa/probe_r234_databench_2026-10-06.json"

# E/F 臂共用确定性初值（全部实体恒活——寿命/射程 1e9；初位散布屏中央带）
static func _pos_x(i: int) -> float:
	return 200.0 + float(i % 97) * 3.3 + float(i % 13) * 0.7


static func _pos_y(i: int) -> float:
	return 400.0 + float(i % 89) * 4.1 + float(i % 11) * 0.9


# E 臂克隆载体：现网 _tick_fast_player 形状（去网格查询/命中链——见用例体头注）
class BenchBullet:
	extends Node2D
	var velocity := Vector2.ZERO
	var lifetime_left := 1.0e9
	var range_left := 1.0e9
	var traveled := 0.0
	var fast_radius := 6.0
	var _swept_prev := Vector2.ZERO

	func tick_fast_clone(p_gd: float) -> void:
		# 逐句对应 projectile_base._tick_fast_player :464-481（去 hits clear/回收调用——
		# 回收在恒活夹具不可达，等价语义=早退 return）
		_swept_prev = global_position
		lifetime_left -= p_gd
		if lifetime_left <= 0.0:
			return
		global_position += velocity * p_gd
		traveled += velocity.length() * p_gd
		if range_left > 0.0 and traveled >= range_left:
			return
		var m := fast_radius + 102.0
		var g := global_position
		if g.x < -m or g.x > 720.0 + m or g.y < -m or g.y > 1280.0 + m:
			return


# C 臂载体：纯脚本成员（数据搬出 Node2D 的中间态）
class BenchObj:
	extends RefCounted
	var x := 0.0
	var y := 0.0


var tree: SceneTree
var _fails: int = 0
var _gate_results: Dictionary = {}
var _root: Node2D = null
var _nodes: Array = []                    # A/D 臂 Node2D（无脚本——纯 C++ 属性通道）
var _bullets: Array = []                  # E 臂 BenchBullet（脚本方法+成员+属性）
var _objs: Array = []                     # C 臂 RefCounted
var _px := PackedFloat32Array()           # B/F 臂 SoA
var _py := PackedFloat32Array()
var _vx := PackedFloat32Array()
var _vy := PackedFloat32Array()
var _lt := PackedFloat32Array()
var _tv := PackedFloat32Array()
var _rg := PackedFloat32Array()
var _rd := PackedFloat32Array()


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	print("══ R234 弹段数据化微基准：六臂 × %d 实体 × %d 帧 × %d 轮（headless 桌面口径）══" % [N, FRAMES, ROUNDS])
	_setup()
	var rounds: Array[Dictionary] = []
	for r in range(ROUNDS):
		var rd := {
			"round": r,
			"A_node2d_global": _measure(_arm_a),
			"B_packed32": _measure(_arm_b),
			"C_refobj_member": _measure(_arm_c),
			"D_node2d_local": _measure(_arm_d),
			"E_method_tick_clone": _measure(_arm_e),
			"F_batch_arrays": _measure(_arm_f),
		}
		rounds.append(rd)
		print("第 %d/%d 轮完成：A p50=%.3fms B=%.3fms C=%.3fms D=%.3fms E=%.3fms F=%.3fms"
			% [r + 1, ROUNDS, _g(rd["A_node2d_global"], "p50"), _g(rd["B_packed32"], "p50"),
				_g(rd["C_refobj_member"], "p50"), _g(rd["D_node2d_local"], "p50"),
				_g(rd["E_method_tick_clone"], "p50"), _g(rd["F_batch_arrays"], "p50")])
	var median := _median_round(rounds)
	_ratios(median)
	_gates(rounds, median)
	_store_json(rounds, median)
	await _teardown()


func fail_count() -> int:
	return _fails


func _g(p_arm: Dictionary, p_key: String) -> float:
	return float(p_arm[p_key])


# ── 夹具 ───────────────────────────────────────────────────────────

func _setup() -> void:
	_root = Node2D.new()
	_root.name = "ProbeR234DataBenchRoot"
	tree.root.add_child(_root)
	_nodes.clear()
	_bullets.clear()
	_objs.clear()
	_px.resize(N)
	_py.resize(N)
	_vx.resize(N)
	_vy.resize(N)
	_lt.resize(N)
	_tv.resize(N)
	_rg.resize(N)
	_rd.resize(N)
	for i in range(N):
		var x := _pos_x(i)
		var y := _pos_y(i)
		# A/D 臂：裸 Node2D（纯 C++ 属性通道——隔离属性语义本身，不混脚本派发成本）
		var n := Node2D.new()
		n.position = Vector2(x, y)
		_root.add_child(n)
		_nodes.append(n)
		# E 臂：脚本弹克隆体
		var b := BenchBullet.new()
		b.position = Vector2(x, y)
		b.velocity = Vector2(DX / DT, DY / DT)
		_root.add_child(b)
		_bullets.append(b)
		# C 臂
		var o := BenchObj.new()
		o.x = x
		o.y = y
		_objs.append(o)
		# B/F 臂 SoA
		_px[i] = x
		_py[i] = y
		_vx[i] = DX / DT
		_vy[i] = DY / DT
		_lt[i] = 1.0e9
		_tv[i] = 0.0
		_rg[i] = 1.0e9
		_rd[i] = 6.0
	print("夹具就绪：%d Node2d(A/D) + %d BenchBullet(E) + %d RefCounted(C) + %d 槽 SoA(B/F)"
		% [_nodes.size(), _bullets.size(), _objs.size(), _px.size()])


func _teardown() -> void:
	if _root != null:
		_root.queue_free()
	await tree.process_frame
	await tree.process_frame
	_nodes.clear()
	_bullets.clear()
	_objs.clear()


# ── 六臂循环体 ─────────────────────────────────────────────────────

func _arm_a() -> void:
	# A：Node2D global_position 读+写（任务书臂——现网运动核的属性轴）
	var d := DELTA
	for n in _nodes:
		var g: Vector2 = n.global_position
		n.global_position = g + d


func _arm_b() -> void:
	# B：PackedFloat32Array 读+写（任务书臂——目标态数据轴）
	for i in range(N):
		var x: float = _px[i]
		var y: float = _py[i]
		_px[i] = x + DX
		_py[i] = y + DY


func _arm_c() -> void:
	# C：RefCounted 成员读+写（任务书对照臂——中间态）
	for o in _objs:
		o.x = o.x + DX
		o.y = o.y + DY


func _arm_d() -> void:
	# D：Node2D local position 读+写（披露臂——视觉壳候选路径）
	var d := DELTA
	for n in _nodes:
		var p: Vector2 = n.position
		n.position = p + d


func _arm_e() -> void:
	# E：逐弹方法调用 tick 克隆（披露臂——现架构形态；恒活→每帧全实体完整工作量）
	var gd := DT
	for b in _bullets:
		b.tick_fast_clone(gd)


func _arm_f() -> void:
	# F：同语义 typed 数组批处理（披露臂——目标架构形态；与 E 逐句对应）
	var gd := DT
	var lt := _lt
	var tv := _tv
	var rg := _rg
	var px := _px
	var py := _py
	var vx := _vx
	var vy := _vy
	var rd := _rd
	for i in range(N):
		lt[i] -= gd
		if lt[i] <= 0.0:
			continue
		var ivx: float = vx[i]
		var ivy: float = vy[i]
		px[i] = px[i] + ivx * gd
		py[i] = py[i] + ivy * gd
		var sp := sqrt(ivx * ivx + ivy * ivy)
		tv[i] = tv[i] + sp * gd
		if rg[i] > 0.0 and tv[i] >= rg[i]:
			continue
		var m: float = rd[i] + OFF_MARGIN
		var cx: float = px[i]
		var cy: float = py[i]
		if cx < -m or cx > SCREEN.x + m or cy < -m or cy > SCREEN.y + m:
			continue


# ── 测量/统计 ──────────────────────────────────────────────────────

func _measure(p_fn: Callable) -> Dictionary:
	for i in range(WARMUP):
		p_fn.call()
	var times: Array[float] = []
	for i in range(FRAMES):
		var t0 := Time.get_ticks_usec()
		p_fn.call()
		times.append(float(Time.get_ticks_usec() - t0) / 1000.0)
	return _stats(times)


func _stats(p_arr: Array[float]) -> Dictionary:
	var s := p_arr.duplicate()
	s.sort()
	return {
		"n": s.size(),
		"p50": _pct(s, 0.50), "p95": _pct(s, 0.95), "mean": _mean(s), "max": s[s.size() - 1],
	}


func _pct(p_sorted: Array[float], p_p: float) -> float:
	if p_sorted.is_empty():
		return 0.0
	var i := clampi(int(float(p_sorted.size()) * p_p), 0, p_sorted.size() - 1)
	return p_sorted[i]


func _mean(p_arr: Array[float]) -> float:
	if p_arr.is_empty():
		return 0.0
	var sum := 0.0
	for v in p_arr:
		sum += v
	return sum / float(p_arr.size())


func _median_round(p_rounds: Array[Dictionary]) -> Dictionary:
	# 每臂取三轮 p50/mean/p95 的中位（轮间机器态漂移防单轮极值主导判读）
	var arms := ["A_node2d_global", "B_packed32", "C_refobj_member",
		"D_node2d_local", "E_method_tick_clone", "F_batch_arrays"]
	var out := {}
	for a in arms:
		var keys := ["p50", "mean", "p95"]
		var m := {}
		for k in keys:
			var vals: Array[float] = []
			for rd in p_rounds:
				vals.append(float((rd[a] as Dictionary)[k]))
			vals.sort()
			m[k] = vals[vals.size() / 2]
		m["n"] = int((p_rounds[0][a] as Dictionary)["n"])
		m["per_entity_us"] = float(m["p50"]) * 1000.0 / float(N)
		out[a] = m
	return out


func _ratios(p_m: Dictionary) -> void:
	var a := float((p_m["A_node2d_global"] as Dictionary)["p50"])
	var b := float((p_m["B_packed32"] as Dictionary)["p50"])
	var c := float((p_m["C_refobj_member"] as Dictionary)["p50"])
	var d := float((p_m["D_node2d_local"] as Dictionary)["p50"])
	var e := float((p_m["E_method_tick_clone"] as Dictionary)["p50"])
	var f := float((p_m["F_batch_arrays"] as Dictionary)["p50"])
	print("── 三臂（任务书）──")
	print("A Node2D global_position 读写：p50=%.3fms/帧 → %.3fµs/实体（p95=%.3f mean=%.3f）"
		% [a, a * 1000.0 / N, float((p_m["A_node2d_global"] as Dictionary)["p95"]),
			float((p_m["A_node2d_global"] as Dictionary)["mean"])])
	print("B PackedFloat32Array 读写：p50=%.3fms/帧 → %.4fµs/实体（p95=%.3f mean=%.3f）"
		% [b, b * 1000.0 / N, float((p_m["B_packed32"] as Dictionary)["p95"]),
			float((p_m["B_packed32"] as Dictionary)["mean"])])
	print("C RefCounted 成员读写：p50=%.3fms/帧 → %.3fµs/实体（p95=%.3f mean=%.3f）"
		% [c, c * 1000.0 / N, float((p_m["C_refobj_member"] as Dictionary)["p95"]),
			float((p_m["C_refobj_member"] as Dictionary)["mean"])])
	print("系数：A/B=%.1f×  A/C=%.1f×  C/B=%.1f×（属性轴 vs 数组轴——路线地基数字）"
		% [a / maxf(b, 0.0001), a / maxf(c, 0.0001), c / maxf(b, 0.0001)])
	print("── 披露臂 ──")
	print("D Node2D local position 读写：p50=%.3fms/帧 → %.3fµs/实体（A/D=%.2f——local 通道相对 global 的差价）"
		% [d, d * 1000.0 / N, a / maxf(d, 0.0001)])
	print("E 逐弹方法调用 tick 克隆（现架构形态）：p50=%.3fms/帧 → %.3fµs/实体（p95=%.3f）"
		% [e, e * 1000.0 / N, float((p_m["E_method_tick_clone"] as Dictionary)["p95"])])
	print("F typed 数组批处理同语义（目标架构形态）：p50=%.3fms/帧 → %.4fµs/实体（p95=%.3f）"
		% [f, f * 1000.0 / N, float((p_m["F_batch_arrays"] as Dictionary)["p95"])])
	print("系数：E/F=%.1f×（快路径弹「现状→数据化」运动核收益对——本路线可投影上限的实证锚）"
		% [e / maxf(f, 0.0001)])


# ── 门（硬门=样本完整性；方向性读数披露不阻塞）──────────────────────

func _gates(p_rounds: Array[Dictionary], p_m: Dictionary) -> void:
	var complete := true
	for rd in p_rounds:
		for a in ["A_node2d_global", "B_packed32", "C_refobj_member",
				"D_node2d_local", "E_method_tick_clone", "F_batch_arrays"]:
			if int((rd[a] as Dictionary)["n"]) != FRAMES:
				complete = false
	_gate("G1 样本完整：3 轮 × 6 臂 × %d 帧全部采样（n==FRAMES）" % FRAMES, complete,
		"rounds=%d" % p_rounds.size())
	var a := float((p_m["A_node2d_global"] as Dictionary)["p50"])
	var b := float((p_m["B_packed32"] as Dictionary)["p50"])
	var e := float((p_m["E_method_tick_clone"] as Dictionary)["p50"])
	var f := float((p_m["F_batch_arrays"] as Dictionary)["p50"])
	_gate_disclosed("G2* 方向读数 A>B（属性轴贵于数组轴——路线前提方向性成立）",
		a > b, "A=%.3f B=%.3f A/B=%.1f×" % [a, b, a / maxf(b, 0.0001)])
	_gate_disclosed("G3* 方向读数 E>F（方法调用形态贵于批处理形态）",
		e > f, "E=%.3f F=%.3f E/F=%.1f×" % [e, f, e / maxf(f, 0.0001)])
	# 夹具自证：E 臂与 F 臂语义等价（恒活不变式——寿命/射程 1e9 且 100 帧漂移不出界）
	var drift_x := absf(DX) * float(WARMUP + FRAMES)
	var drift_y := absf(DY) * float(WARMUP + FRAMES)
	var min_x := 200.0 - drift_x
	var max_y := 800.0 + drift_y
	var alive_invariant := min_x > -OFF_MARGIN and max_y < SCREEN.y + OFF_MARGIN
	_gate("G4 夹具自证：E/F 臂全程恒活（100+20 帧漂移后仍在界内 → 每帧全实体完整工作量）",
		alive_invariant, "min_x=%.0f max_y=%.0f 界=[%.0f,%.0f]" % [min_x, max_y,
			-OFF_MARGIN, SCREEN.y + OFF_MARGIN])


func _gate(p_label: String, p_ok: bool, p_detail: String) -> void:
	if p_ok:
		print("  PASS | %s（%s）" % [p_label, p_detail])
	else:
		print("  FAIL | %s（%s）" % [p_label, p_detail])
		_fails += 1
	_gate_results[p_label] = {"ok": p_ok, "detail": p_detail}


func _gate_disclosed(p_label: String, p_ok: bool, p_detail: String) -> void:
	if p_ok:
		print("  PASS | %s（%s）" % [p_label, p_detail])
	else:
		print("  FAIL* | %s（%s）——披露类失配不阻塞（方向性读数，非门禁）" % [p_label, p_detail])
	_gate_results[p_label] = {"ok": p_ok, "detail": p_detail, "disclosed": true}


# ── JSON 落档 ──────────────────────────────────────────────────────

func _store_json(p_rounds: Array[Dictionary], p_m: Dictionary) -> void:
	var root := {
		"meta": {
			"date": Time.get_date_string_from_system(),
			"package": "desktop-headless-microbench（R234 弹段数据化路线收益系数实证——Node2D 属性轴 vs typed 数组轴）",
			"seed": SEED,
			"seed_note": "夹具无 RNG 消费（初始位确定性公式 _pos_x/_pos_y）——种子常量入档备查",
			"engine": Engine.get_version_info().get("string", "4.3-stable"),
			"n_entities": N,
			"frames": FRAMES,
			"warmup_frames": WARMUP,
			"rounds": ROUNDS,
			"dt": DT,
			"delta_per_frame": {"x": DX, "y": DY},
			"screen": [SCREEN.x, SCREEN.y],
			"off_margin": OFF_MARGIN,
			"arm_A": "Array[Node2D]（树内、原点根、无 Sprite 子节点）读 global_position 写 global_position —— 任务书臂 A，镜像 _tick_fast 运动核属性形状",
			"arm_B": "PackedFloat32Array SoA px/py 读+写（读入局部再写回）——任务书臂 B",
			"arm_C": "RefCounted 脚本成员 x/y 读+写——任务书臂 C（中间态对照）",
			"arm_D": "Array[Node2D] local position 读+写——披露臂（视觉壳候选路径；桶原点无变换 local≡global）",
			"arm_E": "BenchBullet.tick_fast_clone 逐弹方法调用——披露臂（现架构形态；projectile_base._tick_fast_player :447-490 克隆：寿命/swept/直线/traveled/range/出界，去网格查询与命中链；恒活夹具）",
			"arm_F": "同语义 PackedFloat32Array 批处理循环——披露臂（目标架构形态；swept 暂存数据化下免费=步前值，E 臂照付）",
			"drive": "headless 紧循环（无引擎迭代穿插）；计时=Time.get_ticks_usec() 包每帧循环本体",
		},
		"rounds": p_rounds,
		"median": p_m,
		"gates": _gate_results.duplicate(),
		"disclosure": [
			"桌面≠真机（R224 声明 ×0.5-2；R210 前科：Variant/属性跨界在 ARM 代价放大 3-10×）——本系数用于路线判别，绝对 ms 不外推真机",
			"A/D 臂节点为裸 Node2D 无 Sprite2D 子节点——现网弹体带 Visual Sprite2D 子节点（变换脏标记会传导子 canvas item），A 臂读数为属性轴下界口径（生产每弹略贵于本读数）",
			"E 臂克隆体去掉了网格预检/命中链/回收（恒活不可达路径）——E/F 对只覆盖运动学核；查询链（query_circle_snap 桌面 ~4.3µs/弹）与命中/结算链（R232 已到底 37-103µs/结）不在 E/F 对内",
			"E 臂数组为无类型 Array（元素 BenchBullet 脚本类直调）；现网 _proj_pfast_buf 为 Array[Node2D] 需 cast 后调用——E 臂读数为方法轴下界口径（生产每弹调用略贵于本读数）",
			"F 臂 GDScript 批处理循环（非 GDExtension）——若路线走 C++/扩展则系数另行实测",
			"同进程同日六臂交错 3 轮取中位——机器态漂移防单轮极值主导；跨日复测按 R231 坑 3 纪律（性能前提当日同进程复测）",
		],
	}
	var a := float((p_m["A_node2d_global"] as Dictionary)["p50"])
	var b := float((p_m["B_packed32"] as Dictionary)["p50"])
	var c := float((p_m["C_refobj_member"] as Dictionary)["p50"])
	var d := float((p_m["D_node2d_local"] as Dictionary)["p50"])
	var e := float((p_m["E_method_tick_clone"] as Dictionary)["p50"])
	var f := float((p_m["F_batch_arrays"] as Dictionary)["p50"])
	root["verdict"] = {
		"a_p50_ms": a, "b_p50_ms": b, "c_p50_ms": c, "d_p50_ms": d, "e_p50_ms": e, "f_p50_ms": f,
		"a_per_entity_us": a * 1000.0 / N, "b_per_entity_us": b * 1000.0 / N,
		"c_per_entity_us": c * 1000.0 / N, "d_per_entity_us": d * 1000.0 / N,
		"e_per_entity_us": e * 1000.0 / N, "f_per_entity_us": f * 1000.0 / N,
		"ratio_a_over_b": a / maxf(b, 0.0001),
		"ratio_a_over_c": a / maxf(c, 0.0001),
		"ratio_c_over_b": c / maxf(b, 0.0001),
		"ratio_a_over_d": a / maxf(d, 0.0001),
		"ratio_e_over_f": e / maxf(f, 0.0001),
	}
	var fa := FileAccess.open(JSON_PATH, FileAccess.WRITE)
	if fa == null:
		push_warning("[probe] JSON 写入失败：%s" % JSON_PATH)
		return
	fa.store_string(JSON.stringify(root, "\t"))
	fa.close()
	print("JSON 已写：%s" % JSON_PATH)

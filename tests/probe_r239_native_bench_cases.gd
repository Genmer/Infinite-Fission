# tests/probe_r239_native_bench_cases.gd（R239 原生第一刀 A/B 基准用例体——入口运行时加载）
# 设计（性能结论同进程同日纪律；判定只认本探针 JSON）：
# · 夹具：SpaceGrid configure(Vector2(720,1280), 192, 64)（game_loop.gd:2386 生产口径，
#   9×13 格）；敌 120 深载驻场（vc42 口径）确定性聚簇布局（黄金角散布——弹幕构筑收束
#   玩家形态，无 RNG 消费）。
# · 双分布口径（同网格两套查询点生成——分布即负载，双双留档不择优）：
#   ▸ 聚簇臂（主判定，production 形态）：查询点围绕簇心黄金角散布（弹流汇聚敌簇——
#     vc42 深载弹-敌查询真实分布），半径 6/11.5/17/22.5 四档轮转（60Hz 点判定→30Hz
#     swept 带，projectile_base.gd:619-621 口径）；
#   ▸ 均匀臂（披露，稀疏最坏情形）：全场均匀点阵——大量空查询（命中稀区），入 JSON
#     披露下界，不设门（桌面 ≥3× 判据只挂聚簇臂——同负载判定的负载=生产分布）。
# · A/B 两臂：同一实体数组分别喂两实例（off=GDScript 原路径，on=原生镜像桥+ClassDB
#   FissionSpaceGrid）；查询不改动网格状态——每臂 configure+rebuild 一次后反复查询。
# · 轮内臂序交替（偶轮 off 先、奇轮 on 先）抵消漂移；WARMUP 预热；ROUNDS=5 取中位。
# · 桥接件披露臂：rebuild off/on（镜像随建成本）、on 臂首查（含 feed_snapshot CSR 建桥）
#   单独计时——桥接成本透明化，不计入查询吞吐判定。
# · 硬门：①扩展已加载且 on 臂确走原生（_native_on 白盒断言）②两臂命中数一致（同快照
#   等价抽查——全量等价归 tests/runner/test_r239_native.gd）③聚簇臂桌面加速比 ≥3.0。
extends RefCounted

const SEED := 20261006                    # 夹具无 RNG 消费——常量入 meta 备查（纪律）
const ENEMIES := 120                      # 深载敌驻场（vc42 口径）
const QUERIES := 4000                     # 每轮每臂查询数（400 弹 × 10 步量级）
const WARMUP := 400                       # 预热查询数（缓存/分支热身）
const ROUNDS := 5                         # 轮数（取中位）
const SCREEN := Vector2(720.0, 1280.0)    # 逻辑分辨率
const MARGIN := 192.0                     # 生产 configure 余量（game_loop.gd:2386）
const MAX_R := 64.0                       # 生产保守半径（configure 默认）
const JSON_PATH := "res://docs/qa/probe_r239_native.json"
const GRID_SCRIPT := "res://scripts/core/space_grid.gd"

var tree: SceneTree
var _fails: int = 0
var _grid_script: GDScript = null
var _items: Array[Node2D] = []            # 共享实体（树外 Node2D——_pos_of 回退 position 口径）
var _hits_off: int = 0                    # off 臂命中累计（等价抽查口径，聚簇臂）
var _hits_on: int = 0                     # on 臂命中累计
var _raw_off: Array[int] = []             # 每轮原始 µs（JSON 留档，聚簇臂）
var _raw_on: Array[int] = []
var _raw_off_u: Array[int] = []           # 均匀臂原始（披露）
var _raw_on_u: Array[int] = []


static func _cluster_center(c: int) -> Vector2:
	# 5 簇心（深载弹幕收束形态——敌群压向玩家半场）
	return Vector2(170.0 + float(c % 3) * 170.0, 430.0 + float(c / 3) * 200.0)


static func _enemy_pos(i: int) -> Vector2:
	# 确定性聚簇布局：5 簇 × 24 敌，簇内黄金角紧散布（簇径 ~12-67px——1-2 格密度）
	var c := i / 24
	var k := i % 24
	var ctr := _cluster_center(c)
	var ang := float(k) * 2.39996323
	var rad := 12.0 + float(k % 6) * 11.0
	return Vector2(ctr.x + cos(ang) * rad, ctr.y + sin(ang) * rad)


static func _query_pos_clustered(i: int) -> Vector2:
	# 聚簇查询点：弹流汇聚敌簇（70% 落簇周 ~180px 带，30% 全场散——途中弹）
	var ctr := _cluster_center(i % 5)
	if i % 10 < 7:
		var ang := float(i % 37) * 0.618034 * TAU
		var rad := 8.0 + float(i % 23) * 8.0
		return Vector2(ctr.x + cos(ang) * rad, ctr.y + sin(ang) * rad)
	var col := i % 20
	var row := (i / 20) % 25
	return Vector2(18.0 + float(col) * 36.0 + float(i % 7) * 4.0, 26.0 + float(row) * 51.0 + float(i % 11) * 3.0)


static func _query_pos_uniform(i: int) -> Vector2:
	# 均匀点阵（稀疏最坏情形——大量空查询）
	var col := i % 20
	var row := (i / 20) % 25
	return Vector2(18.0 + float(col) * 36.0 + float(i % 7) * 4.0, 26.0 + float(row) * 51.0 + float(i % 11) * 3.0)


static func _query_r(i: int) -> float:
	# 半径四档轮转：60Hz 点判定 6 → 30Hz swept 上带 22.5
	return 6.0 + float(i % 4) * 5.5


func fail_count() -> int:
	return _fails


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		print("  PASS | %s" % p_name)
	else:
		_fails += 1
		print("  FAIL | %s（%s）" % [p_name, p_detail])


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	print("══ R239 原生第一刀 A/B 基准：敌 %d × 查询 %d/轮 × %d 轮（headless 桌面口径）══" % [ENEMIES, QUERIES, ROUNDS])
	_grid_script = load(GRID_SCRIPT)
	if _grid_script == null:
		_check("SpaceGrid 脚本加载", false, GRID_SCRIPT)
		return
	# 开关门基态检查（进入本探针前 NATIVE_QUERIES 应为默认关）
	_check("static 门默认关", bool(_grid_script.NATIVE_QUERIES) == false, str(_grid_script.NATIVE_QUERIES))
	_check("扩展已注册（ClassDB）", bool(_grid_script.native_available()), "FissionSpaceGrid 未在 ClassDB——.gdextension 未被编辑器扫描？")
	_setup_items()

	# 两臂实例（off 先建——static 门 off 态定型；on 臂翻门后建）
	_grid_script.NATIVE_QUERIES = false
	var g_off: Object = _make_grid()
	_grid_script.NATIVE_QUERIES = true
	var g_on: Object = _make_grid()
	_check("on 臂确走原生（_native_on）", bool(g_on._native_on) == true, "开关开但实例回落 GDScript——扩展加载失败？")
	_check("off 臂不走原生", bool(g_off._native_on) == false, "默认关被扰动")

	# rebuild 成本披露臂（镜像随建成本入账；off 先行含冷启动噪声——披露不计判定）
	var t0 := Time.get_ticks_usec()
	g_off.rebuild(_items)
	var rebuild_off_us := Time.get_ticks_usec() - t0
	t0 = Time.get_ticks_usec()
	g_on.rebuild(_items)
	var rebuild_on_us := Time.get_ticks_usec() - t0
	t0 = Time.get_ticks_usec()
	g_on.query_circle_snap(_query_pos_clustered(0), 6.0)
	var feed_first_query_us := Time.get_ticks_usec() - t0

	# 聚簇臂（主判定）+ 均匀臂（披露）——各 ROUNDS 轮，轮内臂序交替
	for r in range(ROUNDS):
		var off_first := (r % 2) == 0
		var t_off := 0
		var t_on := 0
		if off_first:
			t_off = _timed_arm(g_off, false, true)
			t_on = _timed_arm(g_on, true, true)
		else:
			t_on = _timed_arm(g_on, true, true)
			t_off = _timed_arm(g_off, false, true)
		_raw_off.append(t_off)
		_raw_on.append(t_on)
	var u_off := 0
	var u_on := 0
	for r in range(ROUNDS):
		var off_first := (r % 2) == 0
		var t_off := 0
		var t_on := 0
		if off_first:
			t_off = _timed_arm(g_off, false, false)
			t_on = _timed_arm(g_on, true, false)
		else:
			t_on = _timed_arm(g_on, true, false)
			t_off = _timed_arm(g_off, false, false)
		_raw_off_u.append(t_off)
		_raw_on_u.append(t_on)
		print("  第 %d/%d 轮：聚簇 off=%.1fms on=%.1fms ｜ 均匀 off=%.1fms on=%.1fms"
			% [r + 1, ROUNDS, float(_raw_off[r]) / 1000.0, float(_raw_on[r]) / 1000.0,
			float(_raw_off_u[r]) / 1000.0, float(_raw_on_u[r]) / 1000.0])

	var off_med := _median(_raw_off)
	var on_med := _median(_raw_on)
	var off_per_q := float(off_med) / float(QUERIES)
	var on_per_q := float(on_med) / float(QUERIES)
	var speedup := 0.0
	if on_med > 0:
		speedup = float(off_med) / float(on_med)
	var off_kqps := float(QUERIES) / (float(off_med) / 1000000.0)
	var on_kqps := float(QUERIES) / (float(on_med) / 1000000.0)
	var u_speedup := 0.0
	var u_off_med := _median(_raw_off_u)
	var u_on_med := _median(_raw_on_u)
	if u_on_med > 0:
		u_speedup = float(u_off_med) / float(u_on_med)

	print("────────────────────────────────────────")
	print("聚簇臂（主判定，%d 轮中位）：off=%.2fµs/查询（%.0fK q/s） on=%.2fµs/查询（%.0fK q/s） 加速比=%.2fx"
		% [ROUNDS, off_per_q, off_kqps, on_per_q, on_kqps, speedup])
	print("均匀臂（披露，稀疏下界）：off=%.2fµs/查询 on=%.2fµs/查询 加速比=%.2fx"
		% [float(u_off_med) / float(QUERIES), float(u_on_med) / float(QUERIES), u_speedup])
	print("桥接披露：rebuild off=%.0fµs（含冷启动） on(含镜像随建)=%.0fµs on 臂首查(含 feed CSR)=%.0fµs"
		% [float(rebuild_off_us), float(rebuild_on_us), float(feed_first_query_us)])
	_check("两臂命中总数一致（等价抽查·聚簇臂）", _hits_off == _hits_on, "off=%d on=%d" % [_hits_off, _hits_on])
	_check("桌面加速比 ≥3.0（聚簇臂=生产分布）", speedup >= 3.0, "实测 %.2fx（判据：桌面 ≥3×）" % speedup)

	_write_json(off_med, on_med, off_per_q, on_per_q, off_kqps, on_kqps, speedup,
		u_off_med, u_on_med, u_speedup, rebuild_off_us, rebuild_on_us, feed_first_query_us)
	_teardown()


func _timed_arm(p_grid: Object, p_is_on: bool, p_clustered: bool) -> int:
	# 计时本体：WARMUP 预热 + QUERIES 次查询计时，命中数累计到对应臂（防死码+等价抽查）
	for w in range(WARMUP):
		var wp := _query_pos_clustered(w) if p_clustered else _query_pos_uniform(w)
		p_grid.query_circle_snap(wp, _query_r(w))
	var hits := 0
	var buf: Array = []
	var t0 := Time.get_ticks_usec()
	for i in range(QUERIES):
		var p := _query_pos_clustered(i) if p_clustered else _query_pos_uniform(i)
		buf = p_grid.query_circle_snap(p, _query_r(i))
		hits += buf.size()
	var dt := Time.get_ticks_usec() - t0
	if p_clustered:
		if p_is_on:
			_hits_on += hits
		else:
			_hits_off += hits
	return dt


func _median(arr: Array[int]) -> int:
	var sorted := arr.duplicate()
	sorted.sort()
	return sorted[sorted.size() / 2]


func _make_grid() -> Object:
	var g: Object = _grid_script.new()
	g.configure(SCREEN, MARGIN, MAX_R)
	g.rebuild(_items)
	return g


func _setup_items() -> void:
	for i in range(ENEMIES):
		var n := Node2D.new()
		n.position = _enemy_pos(i)
		_items.append(n)


func _teardown() -> void:
	for n in _items:
		n.free()
	_items.clear()
	_grid_script.NATIVE_QUERIES = false


func _write_json(off_med: int, on_med: int, off_per_q: float, on_per_q: float,
		off_kqps: float, on_kqps: float, speedup: float, u_off_med: int,
		u_on_med: int, u_speedup: float, rebuild_off_us: int,
		rebuild_on_us: int, feed_first_query_us: int) -> void:
	var vi := Engine.get_version_info()
	var off_raw: Array = []
	var on_raw: Array = []
	var off_raw_u: Array = []
	var on_raw_u: Array = []
	for r in range(_raw_off.size()):
		off_raw.append(_raw_off[r])
		on_raw.append(_raw_on[r])
		off_raw_u.append(_raw_off_u[r])
		on_raw_u.append(_raw_on_u[r])
	var data := {
		"probe": "r239_native_first_cut_ab_bench",
		"date": Time.get_datetime_string_from_system(false, true),
		"godot": "%d.%d.%d.%s" % [vi.major, vi.minor, vi.patch, str(vi.status)],
		"extension": {
			"class": "FissionSpaceGrid",
			"classdb_registered": bool(_grid_script.native_available()),
			"lib": "res://native/bin/libfission_space_grid.windows.template_debug.x86_64.dll",
		},
		"meta": {
			"seed": SEED,
			"rng_consumed": false,
			"entities": ENEMIES,
			"queries_per_round": QUERIES,
			"warmup": WARMUP,
			"rounds": ROUNDS,
			"grid": {"cell": 128, "margin": MARGIN, "max_entity_radius": MAX_R, "screen": [SCREEN.x, SCREEN.y]},
			"radii_formula": "6.0 + (i % 4) * 5.5  # 60Hz 点判定→30Hz swept 带",
			"distributions": {
				"clustered": "主判定=生产分布：70% 查询点聚簇心 ~180px 带（弹流汇聚敌簇）+30% 全场散",
				"uniform": "披露=稀疏最坏情形：全场均匀点阵（大量空查询）",
			},
			"timing": "Time.get_ticks_usec() 包整轮循环；轮内臂序交替取中位",
			"caliber": "桌面 headless 口径——真机系数另测（桌面判据 ≥3x 挂聚簇臂）",
			"concurrent_load_note": "桌面单机读数，若主控并行跑套件可能抬高双臂噪声（中位口径缓解）",
		},
		"ab_clustered": {
			"role": "主判定（生产查询分布）",
			"off_us_per_query": off_per_q,
			"on_us_per_query": on_per_q,
			"off_k_queries_per_s": off_kqps,
			"on_k_queries_per_s": on_kqps,
			"speedup_x": speedup,
			"off_median_us": off_med,
			"on_median_us": on_med,
			"off_rounds_raw_us": off_raw,
			"on_rounds_raw_us": on_raw,
			"gate_desktop": ">=3.0x",
			"gate_passed": speedup >= 3.0,
		},
		"ab_uniform": {
			"role": "披露（稀疏最坏情形——跨界开销占比放大的下界读数）",
			"off_us_per_query": float(u_off_med) / float(QUERIES),
			"on_us_per_query": float(u_on_med) / float(QUERIES),
			"speedup_x": u_speedup,
			"off_median_us": u_off_med,
			"on_median_us": u_on_med,
		},
		"bridge": {
			"rebuild_off_us": rebuild_off_us,
			"rebuild_on_with_mirror_us": rebuild_on_us,
			"on_first_query_with_feed_us": feed_first_query_us,
			"note": "镜像随建=rebuild 期 packed append；feed=首查时整份 CSR 建桥（每 rebuild 一次）；off 臂先跑含冷启动噪声",
		},
		"equivalence_spot": {
			"off_hits_total": _hits_off,
			"on_hits_total": _hits_on,
			"note": "抽查口径（聚簇臂）——全量逐位等价归 tests/runner/test_r239_native.gd",
		},
	}
	var f := FileAccess.open(JSON_PATH, FileAccess.WRITE)
	if f == null:
		print("  FAIL | JSON 写盘失败：%s" % JSON_PATH)
		_fails += 1
		return
	f.store_string(JSON.stringify(data, "\t"))
	f.close()
	print("  JSON 已写：%s" % JSON_PATH)

# scripts/diag/phase0_calib.gd —— R235 搭车④：Phase 0 六臂微基准真机校准件
# 桌面源型 tests/probe_r234_databench_cases.gd（六臂 A-F，N=1 万×100 帧×3 轮紧循环）
# → 真机随包版：规模 N=3000×40 帧（预热 8）×2 轮、_process 自驱每渲染帧跑一次臂迭代
# （120Hz 真机单臂 96 帧≈0.8s、六臂≈5s——菜单期空闲预算；夹具分帧构建防单帧尖峰）。
# 挂载：game_loop._maybe_start_phase0_calib（BOOT 后菜单停留 4s 门一次性；mobile 门+
# 测试 phase0_calib_force 注入——桌面/headless 缺省零扰动）。产出：一行「校准」记录
# 直入 DebugStats 1Hz 环形日志（diag_push_calib——用户「导出诊断日志」必然带上；
# 不写文件系统/user://，C 盘红线）。
# 口径差披露（vs 桌面紧循环档）：本件每帧一迭代=缓存冷口径（更贴生产每帧一次形态，
# 读数略高于紧循环；A/B、E/F 系数方向不变）；两轮取 p50 小轮（噪声只增不减）。
# 幂等：static 会话闩——完成后任何二次挂载自拆，不重复占日志。
# 纪律：无 test_ 前缀（电池 glob 只收 tests/runner/test_*.gd）；测量窗零分配
# （夹具全预建；计时=Time.get_ticks_usec 差分包臂调用本体）；不声明 class_name
#（§0.1-3 同款——消费方一律 preload 路径引用，防 headless -s 运行全局类缓存滞后）。
extends Node

const N := 3000                            # 实体数（任务书真机档 2000-4000 中值）
const FRAMES := 40                         # 测量迭代数（真机档 30-60 中值）
const WARMUP := 8                          # 预热迭代（不入测量）
const ROUNDS := 2                          # 轮数（每臂取两轮 p50 较小者）
const SETUP_CHUNK := 500                   # 分帧构建块（单帧 ≤500 件实例化——菜单帧预算内）
const DT := 1.0 / 60.0                     # 步长（E/F 臂运动学口径同桌面源型）
const DELTA := Vector2(1.5, -0.75)         # A/D 臂每迭代位移（E/F 臂速度=DELTA/DT 同量纲）
const DX := 1.5
const DY := -0.75
const SCREEN := Vector2(720.0, 1280.0)     # 逻辑分辨率（E/F 出界判定口径同现网）
const OFF_MARGIN := 102.0                  # 出界余量（fast_radius 6 + OFFSCREEN_MARGIN 96）

static var _session_started: bool = false  # 会话起跑闩（game_loop 挂载门读——防重挂）
static var _session_done: bool = false     # 完成闩（二次挂载自拆不占日志）
static var _mount_count: int = 0           # 挂载计数（测试观测——「触发一次后不再触发」）


static func session_started() -> bool:
	return _session_started


static func session_done() -> bool:
	return _session_done


static func mount_count() -> int:
	return _mount_count


# E/F 臂共用确定性初值（全部实体恒活——寿命/射程 1e9；初位散布屏中央带；48 迭代漂移
# ≤72px 不出界——每帧每实体工作量确定；桌面源型同公式）
static func _pos_x(i: int) -> float:
	return 200.0 + float(i % 97) * 3.3 + float(i % 13) * 0.7


static func _pos_y(i: int) -> float:
	return 400.0 + float(i % 89) * 4.1 + float(i % 11) * 0.9


# E 臂克隆载体：现网 _tick_fast_player 形状（probe_r234_databench_cases.BenchBullet
# 同源——寿命/swept/直线/traveled/range/出界六步，去网格查询与命中链）
class BenchBullet:
	extends Node2D
	var velocity := Vector2.ZERO
	var lifetime_left := 1.0e9
	var range_left := 1.0e9
	var traveled := 0.0
	var fast_radius := 6.0
	var _swept_prev := Vector2.ZERO

	func tick_fast_clone(p_gd: float) -> void:
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


# C 臂载体：纯脚本成员（数据搬出 Node2D 的中间态对照）
class BenchObj:
	extends RefCounted
	var x := 0.0
	var y := 0.0


var _phase := 0                            # 0=分帧构建 1=跑臂 2=拆夹具 3=发行 4=终态
var _built := 0                            # 已构建实体数（分帧块推进）
var _arm := 0                              # 当前臂 0-5 = A-F（固定序）
var _round := 0                            # 当前轮 0/1
var _iter := 0                             # 当前迭代（WARMUP+FRAMES 计）
var _teardown_frames := 0                  # 拆夹具等待帧计数
var _times: Array[float] = []              # 当前臂当前轮测量 µs（轮末清空复用）
var _p50s := PackedFloat32Array()          # 每臂每轮 p50 µs（[arm*ROUNDS+round]）
var _root: Node2D = null                   # 夹具根（原点无变换——local≡global 同产线）
var _nodes: Array = []                     # A/D 臂裸 Node2D（无脚本——纯 C++ 属性通道）
var _bullets: Array = []                   # E 臂 BenchBullet（脚本方法+成员+属性）
var _objs: Array = []                      # C 臂 RefCounted
var _px := PackedFloat32Array()            # B/F 臂 SoA
var _py := PackedFloat32Array()
var _vx := PackedFloat32Array()
var _vy := PackedFloat32Array()
var _lt := PackedFloat32Array()
var _tv := PackedFloat32Array()
var _rg := PackedFloat32Array()
var _rd := PackedFloat32Array()


func _ready() -> void:
	_mount_count += 1
	if _session_done:
		set_process(false)             # 幂等：完成后二次挂载自拆（不占日志）——关 _process
		queue_free()                   # 防 queue_free 延迟窗内 _process 空引用（_root 未建）
		return
	_session_started = true
	_root = Node2D.new()
	_root.name = "Phase0CalibFixtureRoot"
	add_child(_root)
	_px.resize(N)
	_py.resize(N)
	_vx.resize(N)
	_vy.resize(N)
	_lt.resize(N)
	_tv.resize(N)
	_rg.resize(N)
	_rd.resize(N)
	_p50s.resize(6 * ROUNDS)


func _process(_p_delta: float) -> void:
	# 菜单门：宿主是 GameLoop 且已离菜单 → 弃跑自拆（战斗期零打扰；无行无完成闩——
	# 会话挂载位已消费，自动通道不再来；测试/独立挂载无宿主特征不受门）
	var host := get_parent()
	if host != null and host.has_method(&"diag_counts") \
			and int(host.get("state")) != GameConst.GameStatus.MENU:
		_abort()
		return
	match _phase:
		0:
			_setup_chunk()
		1:
			_run_one()
		2:
			_teardown_step()
		3:
			_emit_line()
		4:
			pass


func _abort() -> void:
	# 离菜单弃跑：拆夹具自拆、不发行（自动触发窗口错过即错过——下局回菜单不补）
	if _root != null:
		_root.queue_free()
		_root = null
	_nodes.clear()
	_bullets.clear()
	_objs.clear()
	_phase = 4
	queue_free()


func _setup_chunk() -> void:
	# 分帧构建（确定性初位公式同桌面源型；A/D 臂裸 Node2D 隔离属性语义本身）
	var end := mini(_built + SETUP_CHUNK, N)
	for i in range(_built, end):
		var x := _pos_x(i)
		var y := _pos_y(i)
		var n := Node2D.new()
		n.position = Vector2(x, y)
		_root.add_child(n)
		_nodes.append(n)
		var b := BenchBullet.new()
		b.position = Vector2(x, y)
		b.velocity = Vector2(DX / DT, DY / DT)
		_root.add_child(b)
		_bullets.append(b)
		var o := BenchObj.new()
		o.x = x
		o.y = y
		_objs.append(o)
		_px[i] = x
		_py[i] = y
		_vx[i] = DX / DT
		_vy[i] = DY / DT
		_lt[i] = 1.0e9
		_tv[i] = 0.0
		_rg[i] = 1.0e9
		_rd[i] = 6.0
	_built = end
	if _built >= N:
		_phase = 1


func _run_one() -> void:
	# 每渲染帧一次臂迭代（缓存冷口径——头注披露）；臂序 A→F × 轮内 WARMUP+FRAMES
	var t0 := 0
	if _iter >= WARMUP:
		t0 = Time.get_ticks_usec()
	_call_arm(_arm)
	if _iter >= WARMUP:
		_times.append(float(Time.get_ticks_usec() - t0))
	_iter += 1
	if _iter < WARMUP + FRAMES:
		return
	_p50s[_arm * ROUNDS + _round] = _pct50()
	_times.clear()
	_iter = 0
	_round += 1
	if _round < ROUNDS:
		return
	_round = 0
	_arm += 1
	if _arm >= 6:
		_phase = 2


func _call_arm(p_arm: int) -> void:
	match p_arm:
		0:
			_arm_a()
		1:
			_arm_b()
		2:
			_arm_c()
		3:
			_arm_d()
		4:
			_arm_e()
		5:
			_arm_f()


func _teardown_step() -> void:
	# 拆夹具：queue_free 根 + 两帧实释放（桌面源型同规）→ 发行
	if _teardown_frames == 0 and _root != null:
		_root.queue_free()
		_root = null
		_nodes.clear()
		_bullets.clear()
		_objs.clear()
	_teardown_frames += 1
	if _teardown_frames >= 3:
		_phase = 3


func _emit_line() -> void:
	# 一次性「校准」行：每臂两轮 p50 较小者（µs/帧）+ A/B、E/F 比值 → 环形日志 + 控制台
	_phase = 4
	_session_done = true
	var best: Array[float] = []
	for a in range(6):
		best.append(minf(_p50s[a * ROUNDS], _p50s[a * ROUNDS + 1]))
	var ratio_ab := best[0] / maxf(best[1], 0.001)
	var ratio_ef := best[4] / maxf(best[5], 0.001)
	var elapsed := Time.get_ticks_msec()
	var line := "[%d:%02d 校准] Phase0六臂µs/帧（N%d×%d帧×%d轮 取p50小轮）：臂A%d 臂B%d 臂C%d 臂D%d 臂E%d 臂F%d 比A/B=%.1f 比E/F=%.1f（每帧一迭代缓存冷口径——桌面紧循环档不外推，本行=真机系数）" % [
		elapsed / 60000, (elapsed / 1000) % 60, N, FRAMES, ROUNDS,
		int(round(best[0])), int(round(best[1])), int(round(best[2])),
		int(round(best[3])), int(round(best[4])), int(round(best[5])),
		ratio_ab, ratio_ef]
	DebugStats.diag_push_calib(line)
	print("[Phase0Calib] %s" % line)
	queue_free()


func _pct50() -> float:
	# 当前 _times 的 p50（µs；拷贝排序——测量窗外一次性小分配）
	if _times.is_empty():
		return 0.0
	var s := _times.duplicate()
	s.sort()
	return s[s.size() / 2]


# ── 六臂迭代体（桌面源型逐句对应；typed 局部先于属性读——纪律） ──────

func _arm_a() -> void:
	# A：Node2D global_position 读+写（属性轴——现网运动核形状）
	var d := DELTA
	for n in _nodes:
		var g: Vector2 = n.global_position
		n.global_position = g + d


func _arm_b() -> void:
	# B：PackedFloat32Array 读+写（SoA——目标态数据轴）
	for i in range(N):
		var x: float = _px[i]
		var y: float = _py[i]
		_px[i] = x + DX
		_py[i] = y + DY


func _arm_c() -> void:
	# C：RefCounted 成员读+写（中间态对照臂）
	for o in _objs:
		o.x = o.x + DX
		o.y = o.y + DY


func _arm_d() -> void:
	# D：Node2D local position 读+写（视觉壳候选路径——桶原点无变换 local≡global）
	var d := DELTA
	for n in _nodes:
		var p: Vector2 = n.position
		n.position = p + d


func _arm_e() -> void:
	# E：逐弹方法调用 tick 克隆（现架构形态；恒活→每帧全实体完整工作量）
	var gd := DT
	for b in _bullets:
		b.tick_fast_clone(gd)


func _arm_f() -> void:
	# F：同语义 typed 数组批处理（目标架构形态；与 E 逐句对应）
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

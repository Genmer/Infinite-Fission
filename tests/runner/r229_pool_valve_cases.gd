# tests/runner/r229_pool_valve_cases.gd
# R229 用例体：弹池静载阀门（三重门触发运行期裁闲 820→448 + 裁N 诊断键）。
# 覆盖 acceptance 五点：
#   ① 注入触发（GameLoop.pool_valve_override=-3 + PerfGovernor.tier_override=2 +
#      mode_override=0）后：capacity==448 ∧ free+live==448 ∧ runtime_inst==0（懒增长
#      口仍封死）∧ ProjectilePool 子节点数==live+free（树实减——TexBuckets 常驻
#      host +1 非实体件口径）；
#   ② 裁后 550 并发 acquire：第 449 发起 miss（misses 递增）且全程 free+live 恒
#      ==capacity（无懒增长、无崩溃——AC-14.4 满池 null 降级语义）；
#   ③ 桌面零扰动：无注入 boot 后 capacity==820/free==820（r212_poolwarm CAP_TRUTH
#      七池逐位一致镜像）；
#   ④ 诊断行冻结格式：L1（触发前）与 L2/L3（触发后）既有子串（至 补%d）逐位不变、
#      仅行尾多「 裁%d」；裁N 一次性读数（触发后下一采样 >0，之后归 0）；
#      改造前真对拍（跨进程采集档比对）归 qa_r228_diagfreeze 探针留档；
#   ⑥ 门控密封：-1 真值（headless 非 mobile）/-2 强制关/tier3/特效优先 全不触发；
#      -3+tier≤2+帧率优先 触发（tier1 同样触发）；
#   ⑤ 会话内单向：新局（start_run）不恢复 820。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const PLAYER_HOME := Vector2(360.0, 900.0)
const VALVE_CAP := 448                          # game_loop.PROJ_POOL_VALVE_CAP 同值（断言锚）
const NOW_L1 := 65000                           # 同分钟三采样（时间戳逐位可比）
# 七池容量真源对账（r212_poolwarm_cases CAP_TRUTH 同款镜像——balance_tables.tres 原值）
const CAP_TRUTH: Dictionary = {
	&"projectile": 820, &"enemy": 128, &"popup": 80, &"particle": 64, &"laser": 12,
	&"xp": 160, &"homing": 24,
}

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null
var _proj_pool: ProjectilePool = null
var _proj_children_boot: int = 0                # ① 触发前池直接子节点数（820 free+1 host）
var _proj_subtree_boot: int = 0                 # ① 触发前池子树全节点数
var _homing_subtree_boot: int = 0
var _per_item_nodes: int = 0                    # 单弹树节点数（R228 对象谱 ×2 件口径实测锚）


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_boot_game_loop()
	await tree.process_frame
	await tree.process_frame
	_test_1_desktop_zero_disturbance()
	_diag_lines_part1()
	_test_2_valve_trigger_and_trim()
	_diag_lines_part2()
	await _test_3_tree_shrink()
	_test_4_acquire550_degradation()
	await _test_5_session_latch_new_run()
	_teardown_game_loop()
	await tree.process_frame
	_test_6_gate_hermeticity()
	_reset_static_overrides()
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)
	print("验收汇总：%d/%d 通过" % [_pass, _pass + _fail])


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


func _boot_game_loop() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "R229GameLoopUnderTest"
	tree.get_root().add_child(_gl)   # _ready → boot（七池全量 prewarm 同步完成）
	_proj_pool = _gl.pools[&"projectile"] as ProjectilePool


func _teardown_game_loop() -> void:
	tree.paused = false
	RunSave.clear()
	if _gl != null:
		_gl.free()
		_gl = null
	_proj_pool = null


func _reset_static_overrides() -> void:
	# 套件收尾复位（静态面用例显式管理纪律——R223 同款）
	GameLoop.pool_valve_override = -1
	PerfGovernor.tier_override = -1
	PerfGovernor.mode_override = -1


func _subtree_count(p_node: Node) -> int:
	# 递归子树节点数（含自身）
	var n := 1
	for c in p_node.get_children():
		n += _subtree_count(c)
	return n


# ── ③ 桌面零扰动：无注入 boot 后 capacity==820/free==820（CAP_TRUTH 逐位镜像） ──
func _test_1_desktop_zero_disturbance() -> void:
	print("── ③ 桌面零扰动（无注入 boot） ──")
	var pools: Dictionary = _gl.pools
	for key in CAP_TRUTH:
		var pool := pools[key] as ObjectPool
		var st: Dictionary = pool.stats()
		_check("[%s] 容量真源对账 ==%d（balance_tables.tres 原值）"
			% [String(key), int(CAP_TRUTH[key])], int(st["capacity"]) == int(CAP_TRUTH[key]),
			"cap=%d" % int(st["capacity"]))
	var st_p: Dictionary = _proj_pool.stats()
	_check("弹池 boot 后 free==820 / live==0（无注入零扰动）",
		int(st_p["free"]) == 820 and int(st_p["live"]) == 0,
		"free=%d live=%d" % [int(st_p["free"]), int(st_p["live"])])
	_check("boot 后会话闩未置位（_pool_valve_done==false）",
		bool(_gl.get(&"_pool_valve_done")) == false, "")
	_check("boot 后 proj_pool_trim 计数 ==0（阀门未触发）",
		DebugStats.get_counter(&"proj_pool_trim") == 0,
		"n=%d" % DebugStats.get_counter(&"proj_pool_trim"))
	# headless 真值门（-1）：tier/mode 注入但平台门关（非 mobile）→ 不触发
	PerfGovernor.tier_override = 2
	PerfGovernor.mode_override = 0
	for i in range(3):
		_gl._physics_process(1.0 / 60.0)
	_check("真值门密封：tier2+帧率优先（无 -3 哨兵）headless 三帧不裁",
		int(_proj_pool.stats()["capacity"]) == 820
			and DebugStats.get_counter(&"proj_pool_trim") == 0,
		"cap=%d n=%d" % [int(_proj_pool.stats()["capacity"]), DebugStats.get_counter(&"proj_pool_trim")])
	PerfGovernor.tier_override = -1
	PerfGovernor.mode_override = -1
	# 树实减基线（触发前读数）。子树口径：_subtree_count 含池根自身——实体件数 =
	# 子树 −2（弹池：池根+TexBuckets host）/ −1（homing 池：无 host）
	_proj_children_boot = _proj_pool.get_child_count()
	_proj_subtree_boot = _subtree_count(_proj_pool)
	_homing_subtree_boot = _subtree_count(_gl._homing_pool)
	_check("触发前弹池直接子节点 ==821（820 free + 1 TexBuckets host）",
		_proj_children_boot == 821, "n=%d" % _proj_children_boot)
	_per_item_nodes = (_proj_subtree_boot - 2) / 820
	_check("单弹树节点数实测 ==2（R228 对象谱 ×2 件口径）", _per_item_nodes == 2
		and (_proj_subtree_boot - 2) % 820 == 0,
		"per_item=%d subtree=%d" % [_per_item_nodes, _proj_subtree_boot])
	var family_boot: int = (_proj_subtree_boot - 2) + (_homing_subtree_boot - 1)
	_check("弹族树节点（扣池根/host）触发前 ==1688（820×2+24×2）",
		family_boot == 1688, "family=%d" % family_boot)


# ── ④a 冻结行基线：L1（触发前）采样 + 差分基线立标 ──────────────────
func _diag_lines_part1() -> void:
	print("── ④a 诊断行冻结基线（L1=触发前） ──")
	# R233 T1 迁移补丁：模N 差分状态确定性预置（消除既有 boot 时长竞态假红）——
	# DebugStats 1Hz 自然采样首拍（gl=null，不落 _diag_last_phys）后的第二拍是否在
	# part1 前到达取决于 boot 时长是否 ≥1s：<1s 时 L1 是首个 gl 挂载格式化 →
	# _diag_last_phys 仍 -1 → L1「模0」无星标 vs L2/L3「模0*」（win=65000-首拍 ms
	# 恒 >1.5s 带星标）→ 逐位对拍假红（本机复现实测）。预置一行 gl 挂载格式化使
	# _diag_last_phys 在三采样前定型（win 恒含首拍前历史 → 三行全带星标、sim 差分
	# 同步段恒 0）→ 三行逐位确定，boot 时长无关。预置行的 diag_counts 拉取=差分
	# 基线提前一拍建立，dc0/L1 读数语义不变（同步段零增量）。
	DebugStats._diag_format_line(_gl, NOW_L1 - 2000)
	var dc0: Dictionary = _gl.diag_counts()
	_check("diag_counts 出键 pool_trimmed（首拉立基线 ==0）",
		dc0.has(&"pool_trimmed") and int(dc0.get(&"pool_trimmed", -1)) == 0,
		"val=%s" % str(dc0.get(&"pool_trimmed", "?")))
	_line_l1 = _norm_fps(DebugStats._diag_format_line(_gl, NOW_L1))
	var rx_l1 := RegEx.new()
	# R235 搭车③迁移：行尾再追加「物步µsN 派µsN 渲msN.N」三键（物理服务器步本体/
	# ⑧前派发段/渲染轴秒窗读数）——物步µs/渲ms=秒窗时序读数不逐位断言（X 口径），
	# 派µs=MENU 探针关=0 确定值（同 插模拟µs 迁移纪律）
	rx_l1.compile("补0 裁0 快0 结µs0 插µs0 插模拟µs0 派deferred0 派drop0 物步µs\\d+ 派µs0 渲ms\\d+\\.\\d$")
	_check("L1 行尾段「 补0 裁0 快0 结µs0 插µs0 插模拟µs0 派deferred0 派drop0 物步µsX 派µs0 渲msX.X」（追加位在位、触发前读 0——R231 快N/R232 T1b 结µs/R233 T1 插µs/R233 修轮 插模拟µs+派deferred/派drop/R235 搭车③ 物步µs+派µs+渲ms 追加在派drop 后；预置格式化后同步零帧 → 插模拟µs0/派µs0 确定值；物步µs/渲ms=秒窗均值时序读数不断言值）",
		rx_l1.search(_line_l1) != null, "tail=%s" % _line_l1.right(64))


var _line_l1: String = ""
var _line_l2: String = ""
var _line_l3: String = ""


func _norm_fps(p_line: String) -> String:
	# fps/余 掩码（引擎平滑帧率及其导出残差——跨轮抖动面，非本刀面触碰字段）
	var out := p_line
	var rx_fps := RegEx.new()
	rx_fps.compile("fps\\d+")
	out = rx_fps.sub(out, "fpsF", true)
	var rx_left := RegEx.new()
	rx_left.compile("余\\d+ms")
	out = rx_left.sub(out, "余Fms", true)
	return out


func _strip_trim(p_line: String) -> String:
	# 去「 裁N 快N 结µsN 插µsN 插模拟µsN 派deferredN 派dropN 物步µsN 派µsN 渲msN.N」尾段
	#（既有子串（至 补%d）提取——R231 快N/R232 T1b 结µs/R233 T1 插µs/R233 修轮 插模拟µs+
	# 派deferred/派drop/R235 搭车③ 物步µs+派µs+渲ms 追加在裁N 后，同归「行尾新段」一并
	# 剥离：快N=当帧分区计数，L2/L3 并发弹读数与 L1 不同属预期；插模拟µs/物步µs/渲ms=
	# 时序读数同剥离不断言值）
	var rx := RegEx.new()
	rx.compile(" 裁\\d+ 快\\d+( 结µs\\d+)?( 插µs\\d+)?( 插模拟µs\\d+)?( 派deferred\\d+)?( 派drop\\d+)?( 物步µs\\d+)?( 派µs\\d+)?( 渲ms\\d+\\.\\d+)?$")
	var m := rx.search(p_line)
	return p_line.substr(0, m.get_start()) if m != null else ""


# ── ① 注入触发：三重门全驱 → 裁闲 820→448 ─────────────────────────
func _test_2_valve_trigger_and_trim() -> void:
	print("── ① 注入触发（-3 + tier2 + mode0）──")
	GameLoop.pool_valve_override = -3
	PerfGovernor.tier_override = 2
	PerfGovernor.mode_override = 0
	_gl._physics_process(1.0 / 60.0)             # 帧入口 _maybe_trim_pools 首帧触发
	GameLoop.pool_valve_override = -1
	PerfGovernor.tier_override = -1
	PerfGovernor.mode_override = -1
	var st: Dictionary = _proj_pool.stats()
	_check("触发后 capacity==448", int(st["capacity"]) == VALVE_CAP,
		"cap=%d" % int(st["capacity"]))
	_check("触发后 free+live==448（live==0 / free==448）",
		int(st["free"]) + int(st["live"]) == VALVE_CAP
			and int(st["live"]) == 0 and int(st["free"]) == VALVE_CAP,
		"free=%d live=%d" % [int(st["free"]), int(st["live"])])
	_check("触发后 runtime_inst==0（懒增长口仍封死——AC-14.1）",
		int(st["runtime_instantiates"]) == 0 and _proj_pool.runtime_instantiate_count == 0,
		"ri=%d" % int(st["runtime_instantiates"]))
	_check("触发过程零 miss（裁闲不是丢弃）", int(st["misses"]) == 0,
		"misses=%d" % int(st["misses"]))
	_check("proj_pool_trim 计数 ==372（820−448 裁掉件数）",
		DebugStats.get_counter(&"proj_pool_trim") == 820 - VALVE_CAP,
		"n=%d" % DebugStats.get_counter(&"proj_pool_trim"))
	_check("会话闩置位（_pool_valve_done==true）",
		bool(_gl.get(&"_pool_valve_done")) == true, "")
	for i in range(5):
		_gl._physics_process(1.0 / 60.0)
	_check("会话内单向：后续帧不再裁/不再计（counter 恒 372、free 恒 448）",
		DebugStats.get_counter(&"proj_pool_trim") == 820 - VALVE_CAP
			and int(_proj_pool.stats()["free"]) == VALVE_CAP, "")
	# 单池归因：HomingPool 24 / EnemyPool 128 / 其余池不动
	var st_h: Dictionary = (_gl.pools[&"homing"] as ObjectPool).stats()
	var st_e: Dictionary = (_gl.pools[&"enemy"] as ObjectPool).stats()
	_check("HomingPool 不动（cap==24 / free==24 / live==0）",
		int(st_h["capacity"]) == 24 and int(st_h["free"]) == 24 and int(st_h["live"]) == 0,
		"cap=%d free=%d live=%d" % [int(st_h["capacity"]), int(st_h["free"]), int(st_h["live"])])
	_check("EnemyPool 不动（cap==128 / free==128）",
		int(st_e["capacity"]) == 128 and int(st_e["free"]) == 128,
		"cap=%d free=%d" % [int(st_e["capacity"]), int(st_e["free"])])
	var others_ok := true
	for key in [&"popup", &"particle", &"laser", &"xp"]:
		var s: Dictionary = (_gl.pools[key] as ObjectPool).stats()
		if int(s["capacity"]) != int(CAP_TRUTH[key]) or int(s["free"]) != int(CAP_TRUTH[key]):
			others_ok = false
	_check("popup/particle/laser/xp 四池不动（容量与空闲原值）", others_ok, "")


# ── ④b 冻结行对拍（同轮触发前后）+ 裁N 一次性读数 ───────────────────
func _diag_lines_part2() -> void:
	print("── ④b 诊断行冻结对拍 + 裁N 一次性 ──")
	_line_l2 = _norm_fps(DebugStats._diag_format_line(_gl, NOW_L1 + 1))
	_line_l3 = _norm_fps(DebugStats._diag_format_line(_gl, NOW_L1 + 2))
	# R233 修轮：L2 插模拟µs=两采样间 6 次手动驱动帧的快照遍历（T7 无条件）秒差分
	# ——时序读数随机器速度漂移，不逐位断言（行尾六段形态 + 确定子段断言）；
	# 派deferred/派drop=MENU 无战斗派发 → 确定零。L3：L2→L3 同步零帧 → 插模拟µs0。
	# R235 搭车③迁移：行尾再追加 物步µsN 派µsN 渲msN.N（三键恒在——秒窗均值时序读数
	# 不逐位断言，X 口径；派µs MENU 探针关=0 确定值）。
	var rx_tail := RegEx.new()
	rx_tail.compile(" 裁\\d+ 快\\d+ 结µs\\d+ 插µs\\d+ 插模拟µs\\d+ 派deferred\\d+ 派drop\\d+ 物步µs\\d+ 派µs0 渲ms\\d+\\.\\d+$")
	_check("L2 行尾六段在位「 裁372 快0 结µs0 插µs0 插模拟µsX 派deferred0 派drop0 物步µsX 派µs0 渲msX.X」（裁372 触发后下一采样行 >0；X=时序读数不断言值）",
		rx_tail.search(_line_l2) != null and _line_l2.contains("裁372 快0 结µs0 插µs0")
			and _line_l2.contains("派deferred0 派drop0"), "tail=%s" % _line_l2.right(64))
	var rx_l3 := RegEx.new()
	rx_l3.compile("裁0 快0 结µs0 插µs0 插模拟µs0 派deferred0 派drop0 物步µs\\d+ 派µs0 渲ms\\d+\\.\\d$")
	_check("L3 行尾「 裁0 快0 结µs0 插µs0 插模拟µs0 派deferred0 派drop0 物步µsX 派µs0 渲msX.X」（之后归 0——一次性读数；物步µs/渲ms=秒窗均值时序读数不断言值）",
		rx_l3.search(_line_l3) != null, "tail=%s" % _line_l3.right(56))
	var s1 := _strip_trim(_line_l1)
	var s2 := _strip_trim(_line_l2)
	var s3 := _strip_trim(_line_l3)
	_check("L2 既有子串逐位不变（去 裁N 后 ==L1 同段——触发零上游泄漏）",
		s2 == s1 and s2 != "", "len=%d/%d" % [s1.length(), s2.length()])
	_check("L3 既有子串逐位不变（去 裁N 后 ==L1 同段）",
		s3 == s1 and s3 != "", "len=%d/%d" % [s1.length(), s3.length()])
	_check("diag_counts 再拉 pool_trimmed==0（一次性语义——差分已清）",
		int(_gl.diag_counts().get(&"pool_trimmed", -1)) == 0, "")
	_check("R226/R227 段原样（位图/翻/补 在 裁 之前）",
		_line_l2.contains(" 位图1 翻0 补0 裁372"), "seg=%s" % _line_l2.right(40))


# ── ①b 树实减：queue_free 落地后子节点数对账 ────────────────────────
func _test_3_tree_shrink() -> void:
	print("── ①b 树实减（queue_free 帧末摘树） ──")
	await tree.process_frame
	await tree.process_frame
	var st: Dictionary = _proj_pool.stats()
	var live: int = int(st["live"])
	var free: int = int(st["free"])
	var children: int = _proj_pool.get_child_count()
	# 子节点数==live+free（+1=TexBuckets 常驻分桶 host，R214 非实体件）
	_check("弹池子节点数 ==live+free+1（448 实体 + TexBuckets host——树实减）",
		children == live + free + 1, "children=%d live=%d free=%d" % [children, live, free])
	_check("子节点数 −372（821→449——裁掉件帧末摘树）",
		children == _proj_children_boot - (820 - VALVE_CAP),
		"boot=%d now=%d" % [_proj_children_boot, children])
	var subtree: int = _subtree_count(_proj_pool)
	var host_subtree: int = 1
	if _proj_pool.bucket_host != null:
		host_subtree = _subtree_count(_proj_pool.bucket_host)
	_check("分桶 host 子树 ==1（零桶建出——空闲件无桶悬挂，全在池根）",
		host_subtree == 1, "host_subtree=%d" % host_subtree)
	_check("子树实体件 ==live+free×单弹节点数（448×2+host+池根对账）",
		subtree == live * _per_item_nodes + free * _per_item_nodes + 2,
		"subtree=%d 期望=%d" % [subtree, (live + free) * _per_item_nodes + 2])
	var family_after: int = (subtree - 2) + (_subtree_count(_gl._homing_pool) - 1)
	var family_boot: int = (_proj_subtree_boot - 2) + (_homing_subtree_boot - 1)
	_check("弹族树节点（扣池根/host）1688→944（−744——expectedReduction 口径）",
		family_after == 944 and family_boot - family_after == 744,
		"boot=%d after=%d" % [family_boot, family_after])
	_check("树减量 ==裁掉数×单弹节点数（372×2）",
		family_boot - family_after == (820 - VALVE_CAP) * _per_item_nodes, "")


# ── ② 裁后 550 并发 acquire：AC-14.4 满池 null 降级语义 ─────────────
func _test_4_acquire550_degradation() -> void:
	print("── ② 裁后 550 并发 acquire（AC-14.4） ──")
	var cap: int = int(_proj_pool.stats()["capacity"])
	var miss0: int = int(_proj_pool.stats()["misses"])
	var got: Array[Node] = []
	var nulls: int = 0
	var first_null_at: int = -1                  # 1-based 发序
	var miss_after_449: int = -1
	var invariant_ok := true
	var crash_free := true
	for i in range(550):
		var p: Node = null
		p = _proj_pool.acquire()                 # 满池 null 降级不抛不崩（崩=用例进程死）
		if p == null:
			nulls += 1
			if first_null_at < 0:
				first_null_at = i + 1
				miss_after_449 = int(_proj_pool.stats()["misses"])
		else:
			got.append(p)
		var st: Dictionary = _proj_pool.stats()
		if int(st["free"]) + int(st["live"]) != cap:
			invariant_ok = false
	crash_free = got.size() + nulls == 550        # 循环走完即无崩溃
	_check("550 发全部返回（无崩溃——AC-14.4 降级不阻塞）", crash_free,
		"got=%d null=%d" % [got.size(), nulls])
	_check("前 448 发全命中 + 之后 102 发全 null（448 帽内/外）",
		got.size() == VALVE_CAP and nulls == 550 - VALVE_CAP,
		"got=%d null=%d" % [got.size(), nulls])
	_check("第 449 发起 miss（首个 null 落在 449 发）",
		first_null_at == VALVE_CAP + 1 and miss_after_449 - miss0 == 1,
		"first_null=%d missΔ=%d" % [first_null_at, miss_after_449 - miss0])
	_check("全程 free+live 恒==capacity（无懒增长回填）", invariant_ok, "")
	_check("550 发后 runtime_inst 仍 ==0（懒增长口封死——容量先降语义）",
		_proj_pool.runtime_instantiate_count == 0,
		"ri=%d" % _proj_pool.runtime_instantiate_count)
	_check("超帽 102 发全部计 miss（misses +102——丢弃可观测）",
		int(_proj_pool.stats()["misses"]) - miss0 == 550 - VALVE_CAP,
		"missΔ=%d" % (int(_proj_pool.stats()["misses"]) - miss0))
	# 全归还：池恢复 448 满容（循环复用零实例化）
	var release_invariant := true
	for p in got:
		_proj_pool.release(p)
		var st: Dictionary = _proj_pool.stats()
		if int(st["free"]) + int(st["live"]) != cap:
			release_invariant = false
	var st_end: Dictionary = _proj_pool.stats()
	_check("全归还后 free==448 / live==0 / 拒还 0 / 活跃表空（归还语义原样）",
		int(st_end["free"]) == VALVE_CAP and int(st_end["live"]) == 0
			and int(st_end["rejected_releases"]) == 0
			and _proj_pool.active_projectiles().size() == 0,
		"free=%d live=%d rej=%d active=%d" % [int(st_end["free"]), int(st_end["live"]),
			int(st_end["rejected_releases"]), _proj_pool.active_projectiles().size()])
	_check("归还全程 free+live 恒==capacity", release_invariant, "")
	_check("全归还后 runtime_inst 仍 ==0", _proj_pool.runtime_instantiate_count == 0, "")


# ── ⑤ 会话内单向：新局不恢复 820（恢复通道进 backlog） ──────────────
func _test_5_session_latch_new_run() -> void:
	print("── ⑤ 会话内单向（新局不恢复） ──")
	var c0: int = DebugStats.get_counter(&"proj_pool_trim")
	_gl.state = GameConst.GameStatus.MENU        # r212 同构冻结
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	_gl.start_run()
	_gl.state = GameConst.GameStatus.MENU
	_gl.player.global_position = PLAYER_HOME
	await tree.process_frame
	await tree.process_frame
	var st: Dictionary = _proj_pool.stats()
	_check("新局后 capacity 仍 ==448（闩单向——无 prewarm 回 820 恢复通道）",
		int(st["capacity"]) == VALVE_CAP, "cap=%d" % int(st["capacity"]))
	_check("新局后 proj_pool_trim 计数不增（无二次裁）",
		DebugStats.get_counter(&"proj_pool_trim") == c0,
		"n=%d" % DebugStats.get_counter(&"proj_pool_trim"))
	_check("新局后 free==448 / live==0（静止满容）",
		int(st["free"]) == VALVE_CAP and int(st["live"]) == 0,
		"free=%d live=%d" % [int(st["free"]), int(st["live"])])


# ── ⑥ 门控密封（第二实例：干净闩）── ───────────────────────────────
func _test_6_gate_hermeticity() -> void:
	print("── ⑥ 门控密封（-1/-2/tier3/特效优先 不触发） ──")
	_boot_game_loop()
	var cap0: int = int(_proj_pool.stats()["capacity"])
	_check("②GL boot 容量 820（静态 override 复位不跨实例）", cap0 == 820,
		"cap=%d" % cap0)
	# 真值门：headless 非 mobile
	PerfGovernor.tier_override = 2
	PerfGovernor.mode_override = 0
	_gl._physics_process(1.0 / 60.0)
	_check("⑥真值门（-1）headless 不触发", int(_proj_pool.stats()["capacity"]) == 820, "")
	# 强制关
	GameLoop.pool_valve_override = -2
	_gl._physics_process(1.0 / 60.0)
	_check("⑥-2 强制关不触发", int(_proj_pool.stats()["capacity"]) == 820, "")
	# -3 + tier3
	GameLoop.pool_valve_override = -3
	PerfGovernor.tier_override = 3
	_gl._physics_process(1.0 / 60.0)
	_check("⑥-3 + tier3 不触发（tier≤2 门）", int(_proj_pool.stats()["capacity"]) == 820, "")
	# -3 + 特效优先
	PerfGovernor.tier_override = 2
	PerfGovernor.mode_override = 1
	_gl._physics_process(1.0 / 60.0)
	_check("⑥-3 + 特效优先不触发（帧率优先门）", int(_proj_pool.stats()["capacity"]) == 820, "")
	# -3 + tier1 + 帧率优先 → 触发（tier≤2 含 tier1）
	PerfGovernor.mode_override = 0
	PerfGovernor.tier_override = 1
	var c0: int = DebugStats.get_counter(&"proj_pool_trim")
	_gl._physics_process(1.0 / 60.0)
	_check("⑥-3 + tier1 + 帧率优先 触发（cap 820→448）",
		int(_proj_pool.stats()["capacity"]) == VALVE_CAP
			and DebugStats.get_counter(&"proj_pool_trim") == c0 + 820 - VALVE_CAP,
		"cap=%d nΔ=%d" % [int(_proj_pool.stats()["capacity"]),
			DebugStats.get_counter(&"proj_pool_trim") - c0])
	_teardown_game_loop()

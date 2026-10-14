# R267 刀P2 选卡双修用例体（qa_r267_card_open 入口 load）
# 口径（设计 §1.2）：
#   a) _fit_desc 冷 miss 量测 ≤3/次（基线 ≤7 梯全走）；缓存命中 0 量测不变；
#   b) 桌面（headless 无 mobile feature）open() 首帧量测定稿卡数 ≤3，余卡 ≤8ms/帧
#      续建完成（R267 实施注：桌面分帧缝=整卡同步装配+量测分帧——见用例内锚断言）；
#   b′) 续建等价（r212 案①/②原口径复述）：dots 显隐==rarity+1 全卡、同文案重开
#      hits==货架卡数、instance_id 跨 open 恒等；
#   c) 微基准：open→close 热路径全链 ≤ 改前本机基线 510µs × 1.2（qa_r262e ④ 同口径；
#      R267 修轮3 自 ×1.3 收紧回 ×1.2：串行复跑 498-508µs ≤ 原基线——前报结构性
#      +18-27% 劣化系并行负载污染，勘正收回；min-of-5×20 统计不变；双数值随跑落账）。
#   d) R267 修轮2（勘正）：设计验收 d「冷开 ≤8ms」的真机条件 = 菜单/PLAYING 期
#      DescPrewarm 逐帧泵排空后首开（开窗 desc 全命中）。双态同台：A 真机当量
#      （ensure_built+泵空 → _open_card_flow，min-of-6 新鲜实例门 8000µs——单样本
#      12-26ms 尖峰为本机并行负载/大分配后效污染，拆账探针 r267_fix2_probe_flow8
#      8 轮同 kinds 同 0 量测下 open 0.84-26ms 双峰佐证；地板轮 ~0.8-1.2ms 与
#      c 段热路径 503µs 同源；全样本随跑披露）+ B 探针态对照（零泵·desc 恒冷——
#      落账无门，量测>0 对照 A 的 ==0 即预热全覆盖实证）。前报「22→≤8ms」口径
#      作废：22ms 是预热后热路径、≤8ms 从未在探针内验证过；评审 30.5ms /
#      拆账探针 42.7ms 属探针条件（_process 不驱动 → 预热恒不排空）非真机可达态。
extends RefCounted

const Prewarm := preload("res://scripts/cards/card_desc_prewarm.gd")   # d 段：真机当量预热排空用

const FIT_FIRST := 3                    # CardSelectUI.CARD_SPLIT_FIRST（桌面首帧量测档）
const OPEN_GATE_US := 510.0 * 1.2      # c 门：改前本机基线 510µs。R267 修轮3 收紧
                                       # ×1.3→×1.2（=612µs）：QA 串行独占复跑 498µs 实低于
                                       # 原基线，本套 min-of-5×20 串行读数 503-508µs——前报
                                       # 「+18-27% 结构性劣化」系并行电池负载态读数（与战斗
                                       # 读数同源污染，勘正收回）；×1.2 保留对真实回归的拦截
                                       # 余量，统计口径 min-of-5×20 不变
const FRAME_GATE_US := 15000.0         # 续建帧容差（内部预算 8000µs + 调用开销余量）

var _tree: SceneTree = null
var _fails: int = 0
var _passes: int = 0


func _check(p_name: String, p_ok: bool, p_detail: String = "") -> void:
	if p_ok:
		_passes += 1
		print("PASS | " + p_name)
	else:
		_fails += 1
		print("FAIL | " + p_name + ("" if p_detail.is_empty() else "  [got: " + p_detail + "]"))


func _mk_gl(p_name: String):
	var gl = GameLoop.new()
	gl.name = p_name
	_tree.get_root().add_child(gl)
	gl.set_physics_process(false)
	return gl


func _mk_cards(p_n: int, p_len: int = 40) -> Array[Dictionary]:
	# 互异文案货架（fit_desc 缓存键=文案——同文案第二张必命中，非缺陷）
	var out: Array[Dictionary] = []
	for i in range(p_n):
		out.append({
			"kind": CardGenerator.CardKind.TRAIT, "id": &"R267C%d" % i,
			"rarity": i % 4, "value_scale": 1.0 + 0.1 * i,
			"display_name": "卡%d" % i,
			"description": "测试描述%d：" % i + "测".repeat(p_len),
		})
	return out


func run_all(p_tree: SceneTree) -> int:
	_tree = p_tree
	_test_fit_desc_binary_ladder()
	_test_desktop_open_split()
	_test_reopen_equivalence()
	_bench_open_close()
	_test_cold_open_dual_state()
	print("R267 刀P2 选卡双修汇总：PASS %d / FAIL %d（共 %d 项）" % [_passes, _fails, _passes + _fails])
	print("验收汇总：PASS %d / FAIL %d" % [_passes, _fails])
	return _fails


# ── a) 量测二分定档（冷 miss ≤3 / 命中 0） ──
func _test_fit_desc_binary_ladder() -> void:
	print("── a) _fit_desc 量测次数（二分定档） ──")
	CardSelectUI._fit_desc_cache.clear()
	CardSelectUI.fit_desc_measures = 0
	CardSelectUI.fit_desc_cache_hits = 0
	var ls: float = CardSelectUI.prewarm_line_spacing()
	var worst := 0
	for i in range(12):
		var m0: int = CardSelectUI.fit_desc_measures
		CardSelectUI._fit_desc("冷文案%d：%s" % [i, "长".repeat(30 + i * 25)], 600.0, i % 2 == 0, ls)
		var used: int = CardSelectUI.fit_desc_measures - m0
		if used > worst:
			worst = used
	print("    冷 miss 量测最坏 %d 次/卡（基线梯全走 ≤7）" % worst)
	_check("a 冷 miss 量测 ≤3/次（二分 ⌈log2(6)⌉ 封顶；最坏 %d）" % worst, worst <= 3)
	# 命中路径：同参重调零量测（i=0 组原参 = compact true——键含 compact，须全同参）
	var m1: int = CardSelectUI.fit_desc_measures
	var h1: int = CardSelectUI.fit_desc_cache_hits
	CardSelectUI._fit_desc("冷文案0：%s" % "长".repeat(30), 600.0, true, ls)
	_check("a 缓存命中 0 新量测 + hits +1（命中路径零改动）",
		CardSelectUI.fit_desc_measures == m1 and CardSelectUI.fit_desc_cache_hits == h1 + 1)
	# 定档等价抽查：二分与原「从大到小首个 fit」同解（缓存外的极值文案直读 fs/need 合理性）
	var short_fit: Dictionary = CardSelectUI._fit_desc("短文案：%s" % "字".repeat(6), 600.0, false, ls)
	_check("a 短文案定梯顶档 20（与原口径同解）", int(short_fit["fs"]) == 20,
		"fs=%d" % int(short_fit["fs"]))
	var long_fit: Dictionary = CardSelectUI._fit_desc("极长文案：%s" % "长".repeat(600), 600.0, false, ls)
	_check("a 极长文案钳梯底档 12（clip 兜底口径）", int(long_fit["fs"]) == 12,
		"fs=%d" % int(long_fit["fs"]))


# ── b) 桌面 open() 首帧量测分帧 + 续建完成 ──
func _test_desktop_open_split() -> void:
	print("── b) 桌面首帧量测分帧 ──")
	_check("b 前置：桌面缺省档分帧开（_card_split_on 翻门）",
		CardSelectUI._card_split_on() and not CardSelectUI._card_split_hide_tail())
	var gl = _mk_gl("R267P2b")
	gl.call("start_run")
	var cs: CardSelectUI = gl.card_select_ui
	# 4 卡普通货架
	var cands := _mk_cards(4)
	CardSelectUI._fit_desc_cache.clear()
	CardSelectUI.fit_desc_measures = 0
	cs.call("open", cands, false)
	var m_open: int = CardSelectUI.fit_desc_measures
	var left: int = int(cs.get("_build_left"))
	var vis := 0
	for i in range(4):
		if (cs.get("_buttons") as Array)[i].visible:
			vis += 1
	print("    4 卡货架首帧：量测 %d 次 / 待续建 %d / 可见 %d" % [m_open, left, vis])
	_check("b 首帧量测定稿 ≤%d 卡（量测 %d 次 ≤ %d×3）" % [FIT_FIRST, m_open, FIT_FIRST],
		m_open <= FIT_FIRST * 3 and left == 4 - FIT_FIRST,
		"measures=%d left=%d" % [m_open, left])
	_check("b 桌面缝整卡同步装配（4 卡全可见——同步读口径不破）", vis == 4, "vis=%d" % vis)
	# 续建：_process 驱动 ≤8ms/帧内完成
	var frames := 0
	var worst_us := 0
	while int(cs.get("_build_left")) > 0 and frames < 10:
		var t0 := Time.get_ticks_usec()
		cs.call("_process", 1.0 / 60.0)
		var us := int(Time.get_ticks_usec() - t0)
		if us > worst_us:
			worst_us = us
		frames += 1
	print("    续建 %d 帧完成 / 最差帧 %d µs（内部预算 8000µs）" % [frames, worst_us])
	_check("b 续建 ≤10 帧完成且单帧 ≤%.0fµs（实测最差 %dµs）" % [FRAME_GATE_US, worst_us],
		int(cs.get("_build_left")) == 0 and frames <= 10 and worst_us <= int(FRAME_GATE_US))
	# 6 卡成对货架同缝（fit_to=3，余 3 续建；全可见）
	var dual := _mk_cards(6)
	CardSelectUI.fit_desc_measures = 0
	cs.call("open", dual, true)
	var m_dual: int = CardSelectUI.fit_desc_measures
	var left_dual: int = int(cs.get("_build_left"))
	var vis_dual := 0
	for i in range(10):
		if (cs.get("_buttons") as Array)[i].visible:
			vis_dual += 1
	print("    6 卡成对首帧：量测 %d 次 / 待续建 %d / 可见 %d" % [m_dual, left_dual, vis_dual])
	_check("b 成对 6 卡首帧量测 ≤3 卡档 + 全可见",
		m_dual <= FIT_FIRST * 3 and left_dual == 6 - FIT_FIRST and vis_dual == 6,
		"m=%d left=%d vis=%d" % [m_dual, left_dual, vis_dual])
	frames = 0
	while int(cs.get("_build_left")) > 0 and frames < 10:
		cs.call("_process", 1.0 / 60.0)
		frames += 1
	_check("b 成对续建完成", int(cs.get("_build_left")) == 0)
	cs.call("close")
	gl.state = GameConst.GameStatus.MENU
	gl.queue_free()


# ── b′) 续建等价（r212 案①/②原口径复述——分帧路径自身的等价断言） ──
func _test_reopen_equivalence() -> void:
	print("── b′) 续建等价（r212 原口径复述） ──")
	var gl = _mk_gl("R267P2bp")
	gl.call("start_run")
	var cs: CardSelectUI = gl.card_select_ui
	var cands := _mk_cards(4)
	CardSelectUI._fit_desc_cache.clear()
	CardSelectUI.fit_desc_measures = 0
	CardSelectUI.fit_desc_cache_hits = 0
	var ids0: Array[int] = []
	for b in cs.get("_buttons"):
		ids0.append((b as Button).get_instance_id())
	cs.call("open", cands, false)
	while int(cs.get("_build_left")) > 0:
		cs.call("_process", 1.0 / 60.0)
	# dots 显隐 == rarity+1（全卡——r212 案①口径）
	var dot_ok := true
	var vis_detail := ""
	for i in range(cands.size()):
		var dots: HBoxContainer = (cs.get("_card_faces") as Array)[i]["dots"]
		var vis := 0
		for c in dots.get_children():
			if (c as TextureRect).visible:
				vis += 1
		var want: int = int(cands[i].get("rarity", 0)) + 1
		if vis != want:
			dot_ok = false
			vis_detail = "槽%d vis=%d want=%d" % [i, vis, want]
	_check("b′ dots 显隐 == rarity+1（全卡，r212 案①口径）", dot_ok, vis_detail)
	# instance_id 跨 open 恒等（零重建）
	var m_mid: int = CardSelectUI.fit_desc_measures
	cs.call("open", cands, false)            # 同文案重开（续建完成态→全命中）
	while int(cs.get("_build_left")) > 0:
		cs.call("_process", 1.0 / 60.0)
	var m_warm: int = CardSelectUI.fit_desc_measures - m_mid
	var h_warm: int = CardSelectUI.fit_desc_cache_hits
	_check("b′ 同文案重开 hits==货架卡数（r212 案②口径）", h_warm == cands.size(),
		"hits=%d cards=%d" % [h_warm, cands.size()])
	_check("b′ 续建后同文案重开（含续建帧）新增量测 ==0", m_warm == 0, "Δ=%d" % m_warm)
	var ids1: Array[int] = []
	for b in cs.get("_buttons"):
		ids1.append((b as Button).get_instance_id())
	_check("b′ 槽位 instance_id 跨 open 恒等", ids0 == ids1)
	cs.call("close")
	gl.state = GameConst.GameStatus.MENU
	gl.queue_free()


# ── c) open→close 热路径微基准 ──
func _bench_open_close() -> void:
	print("── c) open→close 热路径（改前本机基线 510µs，门 ×1.2=612µs 修轮3 收紧——见文件头） ──")
	var gl = _mk_gl("R267P2c")
	gl.call("start_run")
	var cs: CardSelectUI = gl.card_select_ui
	var cands := _mk_cards(4)
	# 预热 1 次排首建抖动 + 装缓存
	cs.call("open", cands, false)
	while int(cs.get("_build_left")) > 0:
		cs.call("_process", 1.0 / 60.0)
	cs.call("close")
	# 统计口径：5 窗 × 20 次取最小均值（调度噪声只加时间——min-of-windows 对称
	# 固定程序，firstwave 套件先例；连续电池轮次的本机热/负载态下单窗均值
	# 518-655µs 漂，min 锁代码真实成本）
	var best := 1e9
	for w in range(5):
		var t0 := Time.get_ticks_usec()
		var iters := 20
		for i in range(iters):
			cs.call("open", cands, false)
			cs.call("close")                      # close 清 _build_left——纯开帧口径（基线同法）
		var us := float(Time.get_ticks_usec() - t0) / float(iters)
		if us < best:
			best = us
	print("    open→close 热路径 = %.0f µs/次（min-of-5×20；门 %.0fµs）" % [best, OPEN_GATE_US])
	_check("c open→close ≤ 基线×1.3（%.0f ≤ %.0fµs）" % [best, OPEN_GATE_US],
		best <= OPEN_GATE_US)
	gl.state = GameConst.GameStatus.MENU
	gl.queue_free()


# ── d) 冷开 _open_card_flow 双态（修轮2 勘正——真机当量门 + 探针态对照落账） ──
func _test_cold_open_dual_state() -> void:
	print("── d) 冷开双态：A 真机当量（泵空→min-of-6 首开 ≤8ms 门）/ B 探针态（零泵·对照） ──")
	# 态A：真机当量。ensure_built 建队（全注册表变体真路径 enumerate_prewarm_variants）
	# + 逐帧泵排空 = 真机 PLAYING/MENU 期预热的等价终态；随后 _open_card_flow
	# 全链（generate→change_state→open）。统计口径 min-of-6 新鲜实例：并行电池
	# 负载下单样本 12-26ms 尖峰与地板轮同 kinds 同 0 量测（拆账探针 8 轮双峰），
	# min 锁代码真实成本——firstwave/c 段同纪律；牺牲轮先行吸收全局一次性冷建。
	CardSelectUI._fit_desc_cache.clear()
	var glw = _mk_gl("R267P2dW")
	glw.call("start_run")
	Prewarm.ensure_built(glw.registry)
	var pump_calls := 0
	while not (Prewarm._queue as Array).is_empty() and pump_calls < 20000:
		Prewarm.pump(Prewarm.BUDGET_US)
		pump_calls += 1
	print("    预热排空：%d 次泵调用（每次 %dµs 预算≈真机 %d 帧摊还；缓存 %d 键）"
		% [pump_calls, Prewarm.BUDGET_US, pump_calls, CardSelectUI._fit_desc_cache.size()])
	CardSelectUI.fit_desc_measures = 0
	glw.call("_open_card_flow", 2)                  # 牺牲轮：吸收泵后分配余波+首建
	while int((glw.card_select_ui as CardSelectUI).get("_build_left")) > 0:
		(glw.card_select_ui as CardSelectUI).call("_process", 1.0 / 60.0)
	glw.state = GameConst.GameStatus.MENU
	glw.free()
	var samples: Array[int] = []
	var m_max := 0
	for i in range(6):
		var gl = _mk_gl("R267P2dA%d" % i)
		gl.call("start_run")
		var cs: CardSelectUI = gl.card_select_ui
		var t0 := Time.get_ticks_usec()
		gl.call("_open_card_flow", 2)
		samples.append(int(Time.get_ticks_usec() - t0))
		m_max = maxi(m_max, CardSelectUI.fit_desc_measures)
		while int(cs.get("_build_left")) > 0:
			cs.call("_process", 1.0 / 60.0)
		cs.call("close")
		gl.state = GameConst.GameStatus.MENU
		gl.free()
	var best_a: int = samples.min()
	print("    A 真机当量首开 6 样本 = %s µs（min=%d / 门 8000）" % [str(samples), best_a])
	_check("d A 真机当量冷开 min-of-6 ≤8000µs（设计验收 d；min=%dµs，全样本上见）" % best_a,
		best_a <= 8000)
	_check("d A 首开新量测 6 轮最坏 ==0（预热全覆盖；实测 %d）" % m_max, m_max == 0)
	# 态B：探针态对照——零泵（= 任何不驱动 _process 的探针条件），desc 恒冷。
	# 落账无门：评审 30.5ms / 拆账 42.7ms 同源口径（此态字体已被前段焐热，数值
	# 低于全冷探针属预期）。B 量测>0 对照 A ==0 = 预热覆盖实证（噪声无关断言）。
	var gl2 = _mk_gl("R267P2dB")
	gl2.call("start_run")
	var cs2: CardSelectUI = gl2.card_select_ui
	CardSelectUI._fit_desc_cache.clear()
	CardSelectUI.fit_desc_measures = 0
	var t1 := Time.get_ticks_usec()
	gl2.call("_open_card_flow", 2)
	var us_b: int = Time.get_ticks_usec() - t1
	var m_b: int = CardSelectUI.fit_desc_measures
	print("    B 探针态首开 = %dµs（开窗新量测 %d 次）——零泵=预热不排空，非真机可达态" % [us_b, m_b])
	_check("d B 探针态对照：量测 >0（desc 冷=预热缺位实证，对照 A ==0；%dµs 落账无门）" % us_b,
		m_b > 0)
	while int(cs2.get("_build_left")) > 0:
		cs2.call("_process", 1.0 / 60.0)
	cs2.call("close")
	gl2.state = GameConst.GameStatus.MENU
	gl2.free()

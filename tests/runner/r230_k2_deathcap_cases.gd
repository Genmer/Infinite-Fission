# tests/runner/r230_k2_deathcap_cases.gd
# R230 K2c「DeathPop/演出件并发帽」用例体（入口 test_r230_k2_deathcap.gd 运行时 load——
# -s 编译期禁引工程类名纪律）。验收锚（任务书断言面逐点）：
# ① 三重门矩阵：哨兵四态（auto -1 / 否决 -2 / 模拟 -3 / 强开 1）×（mode∧tier∧fullload）
#    8 组合映射——auto 桌面密封 / -2 压过一切 / 1 直入 / -3 按门序（含 敌<80 尾门）。
# ② 门开普通敌按帽 + 最老抢占语义：帽满后新申请→注册表队头（最老）提前收尾让位、
#    帽N 逐件计数、新建数闭环（抢占-复用零新增实例）；到期自清销册。
# ③ Boss 全保留：不占帽位、不被抢占、零帽N；精英 1/2 采样（奇数过，偶数拒并计帽N）。
# ④ PoisonSplash 同帽同册：跨类合账、抢占按创建序跨类取最老。
# ⑤ 帽N 计数正确性：DebugStats 秒差分（首拉立基线/重复拉取增量=0/钳负）+ 诊断行
#    「帽N」插入位（弃N 后、位图R 前）+ 行尾「补N 裁N」冻结断言不变位。
# ⑥ 结算零触碰（端到端）：门开最强形态下连杀 4 精英——enemy_killed 全数派发、
#    仅采样拒绝计帽N（注册表未满零抢占）；死亡链路（dead 置位/池归还）照走。
# ⑦ 负锚（逐位不变）：桌面缺省 / tier3 / 敌<80（fullload_override=0）三态门关——
#    帽+10 连发全放行、零帽N。
# ⑧ 悬空引用 purge + 源级锚（许可口/入册/销册各恰两处、甲板段零引用、绘制序不动）。
# （R231 刀B 迁移披露：诊断行尾追加「快N」段——⑤冻结断言尾锚 补N 裁N → 补N 裁N 快N，
#   帽N 插入位（弃N<帽N<位图R）不受影响。）
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const CAP := 10                               # 断言真源 = Enemy.DEATHPOP_FX_CAP（⑨ 源级核对）

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null
var _host: Node2D = null                      # 演出件宿主（与桶 host 隔离——计数不受杀敌链污染）


class DiagStub extends Node:
	# 诊断行最小桩（_diag_format_line 鸭式消费面：diag_counts + 双 probe 字典 + state）
	var state: int = 0                           # GameConst.GameStatus.BOOT（_diag_state 读 int）
	var stage_probe_us: Dictionary = {}
	var stage_probe_us_peak: Dictionary = {}

	func diag_counts() -> Dictionary:
		return {}

	func diag_reset_stage_peaks() -> void:
		pass


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_boot_game_loop()
	await tree.process_frame
	await tree.process_frame
	PerfGovernor.set_process(false)             # 引擎侧停走——tier 真值不被采样漂移（r223 先例）
	# fx_quality 显式钉高档 2（feel/r229 先例：headless 档位存 user://meta_save_test.cfg
	# 跨套件残留会让 _fx_q 门语义漂移）
	Meta.set_setting("fx_quality", 2)
	_gl.state = GameConst.GameStatus.MENU       # 静止环境（真武器零开火零自然事件）
	_host = Node2D.new()
	_host.name = "R230CapHost"
	tree.get_root().add_child(_host)
	_check("前置：套件起点演出件注册表为空", Enemy._death_fx_live.is_empty(),
		"size=%d" % Enemy._death_fx_live.size())
	_test_1_gate_sentinel_matrix()
	_test_2_cap_and_oldest_preempt()
	_test_3_boss_exempt_elite_half()
	_test_4_poison_shared_ledger()
	_test_5_capped_delta_and_diagline()
	_test_6_settlement_zero_touch()
	_test_7_negative_anchors()
	_test_8_purge_and_source_anchors()
	await _cleanup()
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
	_gl.name = "R230GameLoopUnderTest"
	tree.get_root().add_child(_gl)              # _ready → boot（池预热/事件链全环）


# ── 夹具 ──────────────────────────────────────────────────────────

func _pops() -> Array:
	# 宿主内 DeathPop 件（按类型计数——Godot 同父重名自动改名，名字计数不可靠）
	var out: Array = []
	for c in _host.get_children():
		if c is Enemy.DeathPop:
			out.append(c)
	return out


func _splashes() -> Array:
	var out: Array = []
	for c in _host.get_children():
		if c is Enemy.PoisonSplash:
			out.append(c)
	return out


func _pop_n(p_n: int, p_boss: bool = false, p_elite: bool = false) -> void:
	for i in p_n:
		Enemy.DeathPop.pop(_host, Vector2(300.0 + 10.0 * i, 600.0),
			Color.WHITE, p_boss, p_elite)


func _splash_n(p_n: int, p_boss: bool = false, p_elite: bool = false) -> void:
	for i in p_n:
		Enemy.PoisonSplash.pop(_host, Vector2(300.0 + 10.0 * i, 600.0),
			77.0, p_boss, p_elite)


func _capped() -> int:
	return DebugStats.get_counter(&"deathpop_capped")


func _drain_registry() -> void:
	# 驱动注册表内全部演出件到期自清（_process(1.0) 直驱——feel_cases 弹爆自清同款通道）
	var guard := 0
	while not Enemy._death_fx_live.is_empty() and guard < 64:
		for item in Enemy._death_fx_live.duplicate():
			if item != null and is_instance_valid(item):
				item.call("_process", 1.0)
		guard += 1


func _reset_injections() -> void:
	Enemy.deathpop_cap_override = -1
	Enemy.fullload_override = -1
	PerfGovernor.mode_override = -1
	PerfGovernor.tier_override = -1
	PerfGovernor.tier = 3


# ── ① 三重门矩阵：哨兵四态 ×（mode∧tier∧fullload）8 组合 ──────────

func _test_1_gate_sentinel_matrix() -> void:
	print("── ① 哨兵四态 + 三重门 8 组合映射（直读 _deathpop_cap_on） ──")
	_reset_injections()
	_check("①缺省 -1（真值门）：headless 非 mobile → 恒关（桌面零扰动前提）",
		Enemy._deathpop_cap_on() == false, "")
	PerfGovernor.mode_override = 0
	PerfGovernor.tier_override = 2
	_check("①真值路径 OS 门密封：-1 ∧ tier2 ∧ 帧率优先 → headless 仍关",
		Enemy._deathpop_cap_on() == false, "")
	Enemy.fullload_override = 1
	_check("①真值路径 OS 门密封（fullload=1 同置）→ 仍关（mobile 门在前）",
		Enemy._deathpop_cap_on() == false, "")
	_reset_injections()
	Enemy.deathpop_cap_override = -2
	Enemy.fullload_override = 1
	PerfGovernor.mode_override = 0
	PerfGovernor.tier_override = 2
	_check("①-2 用户否决档 → 恒关（压过 -3/tier/mode/fullload 全注入）",
		Enemy._deathpop_cap_on() == false, "")
	_reset_injections()
	Enemy.deathpop_cap_override = 1
	PerfGovernor.mode_override = 1
	PerfGovernor.tier_override = 3
	Enemy.fullload_override = 0
	_check("①1 强制开 → 恒开（探针档，压过最敌对组合 tier3/特效优先/敌<80）",
		Enemy._deathpop_cap_on() == true, "")
	# -3 模拟 mobile ×（mode0/1 × tier1/2/3 × fullload1/0）8 组合
	Enemy.deathpop_cap_override = -3
	var matrix := [
		[0, 2, 1, true],   # 帧率优先 ∧ tier2 ∧ 敌≥80 → 开
		[0, 1, 1, true],   # tier1 同门（tier≤2）→ 开
		[0, 2, 0, false],  # 敌<80（fullload 门关）→ 关（敌<80 段逐位不变）
		[0, 3, 1, false],  # tier3 → 关
		[1, 2, 1, false],  # 特效优先（mode1）→ 关
		[1, 3, 1, false],
		[1, 2, 0, false],
		[1, 3, 0, false],
	]
	for row in matrix:
		PerfGovernor.mode_override = int(row[0])
		PerfGovernor.tier_override = int(row[1])
		Enemy.fullload_override = int(row[2])
		_check("①-3 模拟 mobile：mode=%d tier=%d fullload=%d → %s" % [row[0], row[1], row[2],
			"开" if bool(row[3]) else "关"],
			Enemy._deathpop_cap_on() == bool(row[3]), "")
	_reset_injections()


# ── ② 门开普通敌按帽 + 最老抢占（override=1 强开直入，headless 可测） ──

func _test_2_cap_and_oldest_preempt() -> void:
	print("── ② 门开普通敌按帽 + 最老抢占语义 ──")
	_reset_injections()
	Enemy.deathpop_cap_override = 1
	_check("②前置：强开门开读数", Enemy._deathpop_cap_on() == true, "")
	_drain_registry()
	for c in _pops():
		c.free()
	var st0: Dictionary = Enemy.DeathPop.fx_pool_stats()
	var cap0 := _capped()
	var news0 := int(st0["news"])
	var hits0 := int(st0["hits"])
	_pop_n(1)
	var first: Node2D = _pops()[0]              # 最老件实例锚
	_pop_n(CAP - 1)
	_check("②帽内 %d 连发全放行（注册表=%d、零帽N）" % [CAP, CAP],
		Enemy._death_fx_live.size() == CAP and _capped() - cap0 == 0,
		"reg=%d capped+%d" % [Enemy._death_fx_live.size(), _capped() - cap0])
	_check("②帽内全新建实例（news+%d，复用零）" % CAP,
		int(Enemy.DeathPop.fx_pool_stats()["news"]) - news0 == CAP, "")
	Enemy.DeathPop.pop(_host, Vector2(999.0, 600.0), Color.WHITE, false, false)
	_check("②超帽第 %d 发：抢占放行（注册表仍=%d、帽N+1）" % [CAP + 1, CAP],
		Enemy._death_fx_live.size() == CAP and _capped() - cap0 == 1,
		"reg=%d capped+%d" % [Enemy._death_fx_live.size(), _capped() - cap0])
	_check("②最老先收：注册表队头=第 2 老件、队尾=被抢占后复用的最老件",
		Enemy._death_fx_live[0] == _pops()[1] and Enemy._death_fx_live[CAP - 1] == first,
		"head==first:%s tail==first:%s" % [str(Enemy._death_fx_live[0] == _pops()[0]),
			str(Enemy._death_fx_live[CAP - 1] == first)])
	_check("②抢占-复用闭环：hits+1（被抢占件让位入池即被新申请复用，news 仍=%d）" % CAP,
		int(Enemy.DeathPop.fx_pool_stats()["hits"]) - hits0 == 1
			and int(Enemy.DeathPop.fx_pool_stats()["news"]) - news0 == CAP, "")
	_pop_n(4)
	_check("②连超帽 4 发：注册表恒=%d、帽N 累计+5、新建数不增（零实例churn外溢）" % CAP,
		Enemy._death_fx_live.size() == CAP and _capped() - cap0 == 5
			and int(Enemy.DeathPop.fx_pool_stats()["news"]) - news0 == CAP,
		"reg=%d capped+%d news+%d" % [Enemy._death_fx_live.size(), _capped() - cap0,
			int(Enemy.DeathPop.fx_pool_stats()["news"]) - news0])
	_drain_registry()
	_check("②到期自清销册：注册表归零、live 归零、件全隐",
		Enemy._death_fx_live.is_empty() and int(Enemy.DeathPop.fx_pool_stats()["live"]) == 0
			and _pops().all(func(c): return not c.visible),
		"reg=%d live=%d" % [Enemy._death_fx_live.size(),
			int(Enemy.DeathPop.fx_pool_stats()["live"])])


# ── ③ Boss 全保留 + 精英 1/2 采样 ─────────────────────────────────

func _test_3_boss_exempt_elite_half() -> void:
	print("── ③ Boss 全保留 / 精英 1/2 采样 ──")
	Enemy.deathpop_cap_override = 1
	_drain_registry()
	var cap0 := _capped()
	var live0 := int(Enemy.DeathPop.fx_pool_stats()["live"])
	_pop_n(CAP)                                 # 帽打满（普通敌）
	_check("③前置：普通件帽满（注册表=%d、零帽N）" % CAP,
		Enemy._death_fx_live.size() == CAP and _capped() - cap0 == 0, "")
	_pop_n(3, true, false)
	_check("③Boss 全保留：帽满下 3 连发全过（帽N 不增）",
		_capped() - cap0 == 0, "capped+%d" % (_capped() - cap0))
	_check("③Boss 不占帽位（Boss 件不入册——注册表仍=%d、live=+%d）" % [CAP, CAP + 3],
		Enemy._death_fx_live.size() == CAP
			and int(Enemy.DeathPop.fx_pool_stats()["live"]) - live0 == CAP + 3,
		"reg=%d live+%d" % [Enemy._death_fx_live.size(),
			int(Enemy.DeathPop.fx_pool_stats()["live"]) - live0])
	_pop_n(1)                                   # 普通件超帽——抢占目标必为普通件（Boss 件不在册）
	_check("③抢占永不落 Boss 件：帽N+1（普通件让位）且 Boss 件仍全活",
		_capped() - cap0 == 1
			and int(Enemy.DeathPop.fx_pool_stats()["live"]) - live0 == CAP + 3,
		"capped+%d live+%d" % [_capped() - cap0,
			int(Enemy.DeathPop.fx_pool_stats()["live"]) - live0])
	_drain_registry()
	# 精英 1/2：相位动态对齐（_death_fx_elite_tick 跨段共享——按起点奇偶推期望过/拒数）
	var phase := Enemy._death_fx_elite_tick % 2
	var expect_pass := 0
	for k in range(8):
		if (phase + 1 + k) % 2 == 1:
			expect_pass += 1
	cap0 = _capped()
	live0 = int(Enemy.DeathPop.fx_pool_stats()["live"])
	_pop_n(8, false, true)
	_check("③精英 8 连发 → 放行 %d（1/2 采样，相位确定）" % expect_pass,
		Enemy._death_fx_live.size() == expect_pass
			and int(Enemy.DeathPop.fx_pool_stats()["live"]) - live0 == expect_pass,
		"reg=%d live+%d（期望 %d）" % [Enemy._death_fx_live.size(),
			int(Enemy.DeathPop.fx_pool_stats()["live"]) - live0, expect_pass])
	_check("③精英被采样拒发计帽N+%d（拒发可观测非静默吞）" % (8 - expect_pass),
		_capped() - cap0 == 8 - expect_pass, "capped+%d" % (_capped() - cap0))
	_drain_registry()


# ── ④ PoisonSplash 同帽同册（跨类合账、跨类按创建序抢最老） ────────

func _test_4_poison_shared_ledger() -> void:
	print("── ④ PoisonSplash 同帽同册 ──")
	Enemy.deathpop_cap_override = 1
	_drain_registry()
	var cap0 := _capped()
	_pop_n(6)                                   # 6 死亡弹爆（news，空闲池空——逐类新建）
	_splash_n(6)                                # 6 毒环（第 11/12 发超帽）
	_check("④跨类合账帽=%d（注册表恰帽值、帽N+2=两次最老抢占）" % CAP,
		Enemy._death_fx_live.size() == CAP and _capped() - cap0 == 2,
		"reg=%d capped+%d" % [Enemy._death_fx_live.size(), _capped() - cap0])
	var dp_n := 0
	var ps_n := 0
	for item in Enemy._death_fx_live:
		if item is Enemy.DeathPop:
			dp_n += 1
		elif item is Enemy.PoisonSplash:
			ps_n += 1
	_check("④抢占按创建序跨类取最老（先 6 弹爆后 6 毒环→队头 2 弹爆被收：余 4+6）",
		dp_n == 4 and ps_n == 6, "dp=%d ps=%d（期望 4/6）" % [dp_n, ps_n])
	_drain_registry()
	_check("④双池到期自清归零", Enemy._death_fx_live.is_empty()
		and int(Enemy.PoisonSplash.fx_pool_stats()["live"]) == 0, "")


# ── ⑤ 帽N 计数正确性 + 诊断行（同步块零 await——采样器不可插入） ────

func _test_5_capped_delta_and_diagline() -> void:
	print("── ⑤ 帽N 秒差分 + 诊断行插入位 ──")
	DebugStats._deathpop_capped_delta()         # 立基线（消费此前各段累计）
	DebugStats.count(&"deathpop_capped", 3)
	_check("⑤秒差分：count+3 → delta=3", DebugStats._deathpop_capped_delta() == 3, "")
	_check("⑤重复拉取增量=0（结N 同规）", DebugStats._deathpop_capped_delta() == 0, "")
	DebugStats.count(&"deathpop_capped", 1)
	var stub := DiagStub.new()
	var line: String = DebugStats._diag_format_line(stub, 65000)
	_check("⑤诊断行含「帽1」（当秒被帽演出件数）", line.contains("帽1"),
		"tail=%s" % line.right(40))
	_check("⑤帽N 插入位=弃N 之后、位图R 之前（行内序 弃N < 帽N < 位图R）",
		line.contains("帽1") and line.contains("位图0")
			and line.find("弃0") < line.find("帽1") and line.find("帽1") < line.find("位图0"),
		"tail=%s" % line.right(40))
	var rx_tail := RegEx.new()
	# R235 搭车③迁移：行尾再追加「物步µsN 派µsN 渲msN.N」三键（物理服务器步本体/⑧前
	# 派发段/渲染轴秒窗读数）——物步µs/渲ms=秒窗时序读数不逐位断言（X 口径）；DiagStub
	# 空 stage_probe_us → 派µs0 确定值（r229 L1 迁移同款纪律）
	rx_tail.compile("补0 裁0 快0 结µs0 插µs0 插模拟µs0 派deferred0 派drop0 物步µs\\d+ 派µs0 渲ms\\d+\\.\\d$")
	_check("⑤行尾「补N 裁N 快N 结µsN 插µsN 插模拟µsN 派deferredN 派dropN 物步µsX 派µs0 渲msX.X」冻结断言不变位（r229_pool_valve 断言兼容——R231 快N/R232 T1b 结µs/R233 T1 插µs/R233 修轮 插模拟µs+派deferred/派drop/R235 搭车③ 物步µs+派µs+渲ms 追加在派drop 后；DiagStub 空 counts → 新键 0 确定值）",
		rx_tail.search(line) != null, "tail=%s" % line.right(64))
	var line2: String = DebugStats._diag_format_line(stub, 65001)
	_check("⑤重复拉取行帽N=0（差分基线推进）", line2.contains("帽0") and not line2.contains("帽1"), "")
	stub.free()


# ── ⑥ 结算零触碰（端到端杀敌链，门开最强形态） ─────────────────────

func _test_6_settlement_zero_touch() -> void:
	print("── ⑥ 结算零触碰：门开连杀 4 精英——死亡链路照走 ──")
	Enemy.deathpop_cap_override = 1             # 最强形态（门开）
	_drain_registry()
	var kills := [0]
	var handler := func(_e: Node2D) -> void:
		kills[0] += 1
	EventBus.enemy_killed.connect(handler)
	var cap0 := _capped()
	var phase := Enemy._death_fx_elite_tick % 2
	var dead_flags: Array[bool] = []
	for i in range(4):
		var e: Enemy = (_gl.pools[&"enemy"] as EnemyPool).acquire()
		var data: EnemyData = _gl.registry.get_enemy(&"E1_grunt")
		e.spawn(data, 1, GameConst.TAG_ELITE)
		e.position = Vector2(400.0 + 40.0 * i, 600.0)
		_gl.spawner.active.append(e)
		e.apply_damage(999999.0)
		dead_flags.append(e.dead)
	_check("⑥4 精英击杀 → enemy_killed 全数派发（掉落/经验链零触碰）",
		kills[0] == 4, "kills=%d" % kills[0])
	_check("⑥4 击杀 dead 全置位（E-06 死亡短路照走）",
		dead_flags.all(func(d): return d), "")
	var sampled := 0
	for k in range(4):
		if (phase + 1 + k) % 2 == 0:
			sampled += 1
	_check("⑥被采样拒发的死亡演出不影响结算：帽N+%d=纯精英采样（注册表未满零抢占）" % sampled,
		_capped() - cap0 == sampled, "capped+%d（期望 %d）" % [_capped() - cap0, sampled])
	EventBus.enemy_killed.disconnect(handler)
	_drain_registry()


# ── ⑦ 负锚：门关三态逐位不变（帽+10 连发全放行、零帽N） ─────────────

func _test_7_negative_anchors() -> void:
	print("── ⑦ 负锚：桌面缺省 / tier3 / 敌<80 门关零扰动 ──")
	_reset_injections()
	var cases := [
		["桌面缺省（全真值）", -1, -1, -1, -1],
		["tier3 锚（-3+mode0+tier3+fullload1）", -3, 0, 3, 1],
		["敌<80 锚（-3+mode0+tier2+fullload0）", -3, 0, 2, 0],
	]
	for c in cases:
		Enemy.deathpop_cap_override = int(c[1])
		PerfGovernor.mode_override = int(c[2])
		PerfGovernor.tier_override = int(c[3])
		Enemy.fullload_override = int(c[4])
		_check("⑦%s：门关读数" % c[0], Enemy._deathpop_cap_on() == false, "")
		var cap0 := _capped()
		_drain_registry()
		_pop_n(CAP + 10)
		_check("⑦%s：帽+%d 连发全放行（注册表=%d 无帽）、零帽N" % [c[0], CAP + 10, CAP + 10],
			Enemy._death_fx_live.size() == CAP + 10 and _capped() - cap0 == 0,
			"reg=%d capped+%d" % [Enemy._death_fx_live.size(), _capped() - cap0])
	_drain_registry()
	_reset_injections()


# ── ⑧ 悬空引用 purge + 源级锚 ────────────────────────────────────

func _test_8_purge_and_source_anchors() -> void:
	print("── ⑧ 悬空引用 purge + 源级锚 ──")
	Enemy.deathpop_cap_override = 1
	_drain_registry()
	var junk := Node2D.new()
	tree.get_root().add_child(junk)
	junk.free()                                 # 立即释放（非 queue_free）→ 注册表悬空引用
	Enemy._death_fx_live.append(junk)
	_pop_n(1)
	_check("⑧admit 前置 purge：悬空引用出册、注册表恰 1 活件",
		Enemy._death_fx_live.size() == 1 and Enemy._death_fx_live[0] is Enemy.DeathPop,
		"reg=%d" % Enemy._death_fx_live.size())
	_drain_registry()
	_reset_injections()
	# 源级锚（r229 ⑦ 同构）
	var f := FileAccess.open("res://scripts/entities/enemy/enemy.gd", FileAccess.READ)
	var src := f.get_as_text() if f != null else ""
	if f != null:
		f.close()
	_check("⑨源级：R230 K2c 契约注释在位", src.contains("R230 K2c") \
		and src.contains("deathpop_cap_override"), "缺契约锚")
	_check("⑨源级：许可口恰两处调用（仅 DeathPop.pop/PoisonSplash.pop——甲板/护甲/结算零触碰面）",
		src.count("Enemy._death_fx_admit") == 2, "n=%d" % src.count("Enemy._death_fx_admit"))
	_check("⑨源级：入册/销册各恰两处（两内嵌类对称，ArmorPlate/甲板路径零引用）",
		src.count("Enemy._death_fx_track") == 2 and src.count("Enemy._death_fx_untrack") == 2,
		"track=%d untrack=%d" % [src.count("Enemy._death_fx_track"),
			src.count("Enemy._death_fx_untrack")])
	var seg_a := src.find("# ── R230 K2c")
	var seg_b := src.find("func _ready() -> void:")
	if seg_a >= 0 and seg_b > seg_a:
		var cap_seg := src.substr(seg_a, seg_b - seg_a)
		var code_armor := false                 # 只查代码行（契约注释文本提及 _armor 不算引用）
		for ln in cap_seg.split("\n"):
			var t := str(ln).strip_edges()
			if not t.begins_with("#") and t.contains("_armor"):
				code_armor = true
		_check("⑨源级：帽块零甲板代码引用（甲板必显红线——DEATHPOP_FX_CAP 在位）",
			cap_seg.contains("DEATHPOP_FX_CAP") and not code_armor,
			"code_armor=%s" % str(code_armor))
	var dp_at := src.find("class DeathPop")
	var ps_at := src.find("class PoisonSplash")
	if dp_at >= 0 and ps_at >= 0:
		var dp_seg := src.substr(dp_at)
		var ps_seg := src.substr(ps_at, dp_at - ps_at)
		_check("⑨源级：绘制序不动（DeathPop/PoisonSplash 段无 move_child/z_index）",
			not dp_seg.contains("move_child") and not dp_seg.contains("z_index")
			and not ps_seg.contains("move_child") and not ps_seg.contains("z_index"), "")
	var df := FileAccess.open("res://autoload/debug_stats.gd", FileAccess.READ)
	var dsrc := df.get_as_text() if df != null else ""
	if df != null:
		df.close()
	_check("⑨源级：debug_stats 帽N 键在位（秒差分助手+行插入）",
		dsrc.contains("_deathpop_capped_delta") and dsrc.contains("\"帽%d\""), "")
	_check("⑨源级：帽常量=断言真源 CAP", Enemy.DEATHPOP_FX_CAP == CAP,
		"cap=%d" % Enemy.DEATHPOP_FX_CAP)


func _cleanup() -> void:
	_drain_registry()
	for c in _pops():
		c.free()
	for c in _splashes():
		c.free()
	if _host != null:
		_host.free()
		_host = null
	_reset_injections()
	PerfGovernor.transitions = 0
	PerfGovernor._ema_inject = -1.0
	PerfGovernor._test_reset()
	PerfGovernor.set_process(true)
	Meta.set_setting("fx_quality", 2)
	tree.paused = false
	RunSave.clear()
	if _gl != null:
		_gl.free()
		_gl = null
	await tree.process_frame

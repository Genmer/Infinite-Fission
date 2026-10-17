# tests/qa_r269_bucketprobe_cases.gd
# R269 B 轨八键用例体（入口 tests/qa_r269_bucketprobe.gd 运行时 load——-s 编译期
# 禁引工程类名纪律）。覆盖设计 §5 b1-b5：
# · b1 bucket 累计器三夹具（deathfx/telegraph/bucket）→ 秒窗累计 >0 + 行含键；
# · b2 延µs 哨兵（直驱 _physics_process → deferred 冲刷 → 行尾出现）+ 秒窗复位语义；
# · b3 释N 差分（拉取立基线 / 触发增量恰 1 / 重复拉取 0）；
# · b4 行格式冻结（八键在 挡 与行尾之间、既有子串逐位）；
# · b5 敌弹N 当秒末直读 + 拒N 差分 + boost 关零拒绝；
# · b6（修1·评审中#1）反射盾 team 翻转 → team1_live 精确同步 + 实扫自愈 + 敌弹N 真值。
# 口径注：headless 直调 _diag_format_line 不复位秒窗（debug_stats._diag_reset_window_acc
# 注释同款）；涉及 await 的断言只锁 ≥0 不锁值（真实 1Hz 采样器跨 await 可能复位秒窗）。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const DT := 1.0 / 60.0

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null
var _host: Node2D = null                      # 演出/探针件宿主（与 GL 子树隔离）


class DiagStub extends Node:
	# 诊断行最小桩（_diag_format_line 鸭式消费面——r230_k2 DiagStub 同款 + counts 可注）
	var state: int = 0                           # GameConst.GameStatus.BOOT
	var stage_probe_us: Dictionary = {}
	var stage_probe_us_peak: Dictionary = {}
	var counts: Dictionary = {}

	func diag_counts() -> Dictionary:
		return counts

	func diag_reset_stage_peaks() -> void:
		pass


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_boot_game_loop()
	await tree.process_frame
	await tree.process_frame
	PerfGovernor.set_process(false)             # 引擎侧停走——tier 真值不被采样漂移（r223 先例）
	PerfGovernor.boost_override = -1            # B 轨键面默认 boost 关（b5 内显式开）
	Meta.set_setting("fx_quality", 2)           # r230 先例：档位钉高防跨套件 user:// 残留漂门
	_gl.state = GameConst.GameStatus.MENU       # 静止环境（真武器零开火零自然事件）
	_host = Node2D.new()
	_host.name = "R269ProbeHost"
	tree.get_root().add_child(_host)
	_test_b1_buckets()
	await _test_b2_sentinel()
	_test_b3_release_delta()
	_test_b4_line_format()
	_test_b5_enemy_bullets()
	_test_b6_reflect_team1_count()              # R269 修1（评审中#1）反射计数闭环
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
	_gl.name = "R269ProbeGameLoop"
	tree.get_root().add_child(_gl)              # _ready → boot（池预热/事件链全环）


func _reset_window() -> void:
	# 秒窗累计器复位（真实链路=1Hz 采样行 push 后；本套件同步块内手动复位=同语义）
	DebugStats._diag_reset_window_acc()


func _stub_line(p_counts: Dictionary = {}) -> String:
	var stub := DiagStub.new()
	stub.counts = p_counts
	var line: String = DebugStats._diag_format_line(stub, Time.get_ticks_msec())
	stub.free()
	return line


# ── b1 bucket 累计器三夹具 ─────────────────────────────────────────

func _test_b1_buckets() -> void:
	print("── b1 死µs/警µs/桶µs 三夹具（wrap 落位 → 秒窗累计 >0 + 行含键） ──")
	# 死µs：DeathPop.pop 直调（门关桌面缺省 → admit 放行 → 全程入桶）
	_reset_window()
	Enemy.deathpop_cap_override = -1
	Enemy.fullload_override = -1
	Enemy.DeathPop.pop(_host, Vector2(300.0, 600.0), Color.WHITE, false, false)
	var death_us := DebugStats.diag_bucket_window_us(&"deathfx")
	_check("b1死µs：DeathPop.pop 直调 → 秒窗累计 >0（wrap 含创建/挂树/配置全程）",
		death_us > 0, "deathfx=%dµs" % death_us)
	_check("b1死µs：行含「死µs」键（1Hz 行尾新段）",
		_stub_line().contains("死µs"), "line=%s" % _stub_line().right(48))
	# 警µs：Enemy.new 挂树 → _ready 内 TelegraphCircle 创建 wrap
	_reset_window()
	var e := Enemy.new()
	_host.add_child(e)
	var tele_us := DebugStats.diag_bucket_window_us(&"telegraph")
	_check("b1警µs：Enemy._ready（引信环创建/挂树/配置）→ 秒窗累计 >0",
		tele_us > 0, "telegraph=%dµs" % tele_us)
	_check("b1警µs：行含「警µs」键", _stub_line().contains("警µs"), "")
	# 桶µs：TexBucketHost.place 直调（含 reparent+MM 注册）
	_reset_window()
	var tbh := TexBucketHost.new()
	_host.add_child(tbh)
	tbh.setup(_host)
	var n := Node2D.new()
	tbh.place(n, ImageTexture.create_from_image(
		Image.create(2, 2, false, Image.FORMAT_RGBA8)))
	var bucket_us := DebugStats.diag_bucket_window_us(&"bucket")
	_check("b1桶µs：贴图桶 place → 秒窗累计 >0", bucket_us > 0, "bucket=%dµs" % bucket_us)
	_check("b1桶µs：行含「桶µs」键", _stub_line().contains("桶µs"), "")


# ── b2 延µs 哨兵 + 复位语义 ─────────────────────────────────────────

func _test_b2_sentinel() -> void:
	print("── b2 延µs 哨兵（物理相尾 call_deferred → 冲刷点收差值入秒窗桶） ──")
	_reset_window()
	_check("b2前置：复位后 flush 桶==0（干净起点）",
		DebugStats.diag_bucket_window_us(&"flush") == 0, "")
	_gl._physics_process(DT)                    # 真帧直驱（r268 physphase 先例）——尾哨兵入队
	await tree.process_frame
	await tree.process_frame                    # deferred 在 message_queue 冲刷点执行
	var flush_us := DebugStats.diag_bucket_window_us(&"flush")
	_check("b2延µs：直驱物理帧 + 冲刷两帧后 ≥0 出现在秒窗桶（X 口径不锁值）",
		flush_us >= 0, "flush=%dµs" % flush_us)
	_check("b2延µs：行尾含「延µs」键", _stub_line().contains("延µs"), "")
	# 复位语义：秒窗随采样重开——旧值不重复累计
	_reset_window()
	_check("b2复位：秒窗重开后 flush 桶==0（旧值清零不跨窗携带）",
		DebugStats.diag_bucket_window_us(&"flush") == 0, "")
	_gl._physics_process(DT)
	await tree.process_frame
	await tree.process_frame
	_check("b2再驱动：二次直驱后新值独立入桶 ≥0（差分基线对齐既有键口径）",
		DebugStats.diag_bucket_window_us(&"flush") >= 0, "")


# ── b3 释N 差分 ─────────────────────────────────────────────────────

func _test_b3_release_delta() -> void:
	print("── b3 释N 差分（拉取立基线 / queue_free wrap 触发 / 重复拉取 0） ──")
	var e := Enemy.new()
	_host.add_child(e)
	var ring := Telegraph.TelegraphCircle.new()   # 挂件不入树亦可 queue_free（idle 期释放）
	e._blink_ring = ring
	DebugStats._diag_dispatch_delta(&"perffx_qfree")    # 立基线（消费此前各段累计）
	e._clear_blink_ring()                               # wrap 点：queue_free + count(&"perffx_qfree")
	_check("b3释N：wrap 点触发 → 差分恰 1",
		DebugStats._diag_dispatch_delta(&"perffx_qfree") == 1, "")
	_check("b3释N：重复拉取增量=0（拉取立基线口径）",
		DebugStats._diag_dispatch_delta(&"perffx_qfree") == 0, "")
	e._clear_blink_ring()                               # ring 已 null → 零计数
	_check("b3释N：空清（无可释放件）不计数",
		DebugStats._diag_dispatch_delta(&"perffx_qfree") == 0, "")
	_check("b3释N：行含「释」键（行尾新段）", _stub_line().contains(" 释"), "")


# ── b4 行格式冻结 ───────────────────────────────────────────────────

func _test_b4_line_format() -> void:
	print("── b4 行格式冻结（既有子串逐位 / 八键插入位 挡 后行尾前） ──")
	var line := _stub_line()
	# 既有子串：挡N 之前全部旧键逐位在位（r229/r230 迁移后尾锚同款锚文本）
	_check("b4既有子串逐位：补0 裁0 快0 结µs0 插µs0 插模拟µs0 派deferred0 派drop0 在位",
		line.contains("补0 裁0 快0") and line.contains("结µs0 插µs0 插模拟µs0 派deferred0 派drop0"),
		"tail=%s" % line.right(64))
	# 八键插入位：挡 与行尾之间，键序固定
	var i_dang := line.find("挡0")
	var i_die := line.find("死µs")
	var i_jing := line.find("警µs")
	var i_tong := line.find("桶µs")
	var i_yan := line.find("延µs")
	var i_shi := line.find(" 释")
	var i_dan := line.find(" 敌弹")
	var i_ju := line.find(" 拒")
	var i_cu := line.find(" 促")
	_check("b4八键在位且序=挡 < 死µs < 警µs < 桶µs < 延µs < 释 < 敌弹 < 拒 < 促（行尾段）",
		i_dang >= 0 and i_dang < i_die and i_die < i_jing and i_jing < i_tong
			and i_tong < i_yan and i_yan < i_shi and i_shi < i_dan
			and i_dan < i_ju and i_ju < i_cu,
		"d=%d s=%d j=%d t=%d y=%d r=%d e=%d c=%d b=%d" % [i_dang, i_die, i_jing, i_tong,
			i_yan, i_shi, i_dan, i_ju, i_cu])
	_check("b4促N 缺省 0（boost 关 + boost_override -1 → boost_diag_state 单源）",
		line.contains("促0"), "tail=%s" % line.right(24))
	PerfGovernor.boost_override = 1
	_check("b4促N boost 强开 → 促1（状态键随模式翻转）",
		_stub_line().contains("促1"), "")
	PerfGovernor.boost_override = -1
	# 尾锚正则（r230_k2 :343 同款迁移后形状——八可选组自由值；R271 十一键续组 appended
	# 〔qa_r228_diagfreeze_cases.gd:152 同款迁移协议——新键位 促 后、尖峰段前，全部可选组〕）
	# R288 补迁：R286 九键（命/提/灭/回/ip/段和/弹段/网段/敌段）+ R287 六键（跳/玩/特/
	# UI/他/派段）行尾追加在 渲峰ms 后——本套件 2824fd8 后未跟迁（全电池扫出面），
	# 序列与 qa_r228_diagfreeze_cases.gd:171 逐组对齐。
	# R289 补迁：十三键（武1..武9µs/副武µs/深/武跳/弹拒）行尾追加在 派段µs 后——同
	# qa_r228 第 11 次迁移协议，全部可选组；MENU 冻结窗内十武桶/深/武跳/弹拒=0 确定值。
	var rx_tail := RegEx.new()
	rx_tail.compile("补0 裁0 快0 结µs0 插µs0 插模拟µs0 派deferred0 派drop0 物步µs\\d+ 派µs0 渲ms\\d+\\.\\d( 挡\\d+)?( 死µs\\d+)?( 警µs\\d+)?( 桶µs\\d+)?( 延µs\\d+)?( 释\\d+)?( 敌弹\\d+)?( 拒\\d+)?( 促\\d+)?( 步µs\\d+)?( 隙µs\\d+)?( 延早µs\\d+)?( 延渲µs\\d+)?( 延峰µs\\d+)?( 加\\d+)?( 摘\\d+)?( 绘µs\\d+)?( 渲帧\\d+)?( 呈帧\\d+)?( 渲峰ms\\d+\\.\\d+)?( 命µs\\d+)?( 提µs\\d+)?( 灭µs\\d+)?( 回µs\\d+)?( ipµs\\d+)?( 段和µs\\d+)?( 弹段µs\\d+)?( 网段µs\\d+)?( 敌段µs\\d+)?( 跳段µs\\d+)?( 玩段µs\\d+)?( 特段µs\\d+)?( UI段µs\\d+)?( 他段µs\\d+)?( 派段µs\\d+)?( 武1µs\\d+)?( 武2µs\\d+)?( 武3µs\\d+)?( 武4µs\\d+)?( 武5µs\\d+)?( 武6µs\\d+)?( 武7µs\\d+)?( 武8µs\\d+)?( 武9µs\\d+)?( 副武µs\\d+)?( 深\\d+)?( 武跳\\d+)?( 弹拒\\d+)?$")
	_check("b4尾锚正则全匹配（r229/r230/qa_r228/R271/R288/R289 迁移后兼容形状）",
		rx_tail.search(line) != null, "tail=%s" % line.right(96))


# ── b5 敌弹N / 拒N ─────────────────────────────────────────────────

func _test_b5_enemy_bullets() -> void:
	print("── b5 敌弹N 当秒末直读 / 拒N 差分 / boost 关零拒绝 ──")
	# 敌弹N：diag_counts.enemy_bullets_live 直读（stub 注入确定值）
	_check("b5敌弹N：注入 N=7 → 行含「敌弹7」（当秒末直读非差分）",
		_stub_line({&"enemy_bullets_live": 7}).contains("敌弹7"), "")
	_check("b5敌弹N：缺省无注入 → 敌弹0（counts 缺键兜底 0）",
		_stub_line().contains("敌弹0"), "")
	# 真源接线：diag_counts.enemy_bullets_live 改实扫真值（修1）——真取敌弹对照
	var pool := _gl._projectile_pool
	var t1_before := int(_gl.diag_counts().get(&"enemy_bullets_live", -1))
	var got := 0
	for i in 3:
		var eb := pool.acquire(1)
		if eb != null:
			eb.team = 1                     # 真实路径由调用方 spawn({"team":1}) 设置（acquire 只记账）
			got += 1
	_check("b5敌弹N 真源：acquire(1)×3 后 diag_counts.enemy_bullets_live==前值+3（实扫真值——修1 recount 口径）",
		got == 3 and int(_gl.diag_counts().get(&"enemy_bullets_live", -1)) == t1_before + 3,
		"got=%d before=%d now=%d" % [got, t1_before,
			int(_gl.diag_counts().get(&"enemy_bullets_live", -1))])
	# 拒N：独立池夹具（boost 开 ∧ team1_live ≥320 → acquire(1) 拒发计数）
	var bp := ProjectilePool.new()
	bp.name = "R269BoostCapPool"
	tree.get_root().add_child(bp)
	bp.setup(&"r269_boostcap", load("res://scenes/combat/projectiles/ballistic_projectile.tscn"), 8)
	bp.soft_limit = 1500
	DebugStats._diag_dispatch_delta(&"boost_bullet_capped")   # 立基线
	PerfGovernor.boost_override = 1
	bp.team1_live = 320
	var rej := 0
	for i in 3:
		if bp.acquire(1) == null:
			rej += 1
	_check("b5拒N：boost 开 ∧ team1_live=320 → acquire(1)×3 全拒（null）",
		rej == 3, "rej=%d" % rej)
	_check("b5拒N：差分==3（boost_bullet_capped 逐发计数）",
		DebugStats._diag_dispatch_delta(&"boost_bullet_capped") == 3, "")
	_check("b5拒N：行含「拒」键", _stub_line().contains(" 拒"), "")
	var p0 := bp.acquire(0)
	_check("b5帽只锁 team-1：boost 开 acquire(0) 正常获取（玩家弹不受敌弹帽）",
		p0 != null, "")
	DebugStats._diag_dispatch_delta(&"boost_bullet_capped")   # 立基线
	PerfGovernor.boost_override = -1            # boost 关（桌面默认路径）
	bp.team1_live = 320
	var ok := 0
	for i in 3:
		if bp.acquire(1) != null:
			ok += 1
	_check("b5boost 关同计数 320：acquire(1)×3 正常获取（门不触——关路径逐位）",
		ok == 3, "ok=%d" % ok)
	_check("b5boost 关零拒绝（拒N 恒 0）",
		DebugStats._diag_dispatch_delta(&"boost_bullet_capped") == 0, "")
	PerfGovernor.boost_override = -1
	bp.free()


# ── b6 反射盾 team 翻转计数闭环（修1·评审中#1） ─────────────────────

func _test_b6_reflect_team1_count() -> void:
	print("── b6 反射盾 team 翻转 → team1_live 精确同步 + 敌弹N 真值（修1） ──")
	PerfGovernor.boost_override = -1            # 帽关——计数口径与门无关纯验证
	var rp := ProjectilePool.new()
	rp.name = "R269ReflectPool"
	tree.get_root().add_child(rp)
	rp.setup(&"r269_reflect", load("res://scenes/combat/projectiles/ballistic_projectile.tscn"), 4)
	rp.soft_limit = 1500
	var e := Enemy.new()
	_host.add_child(e)                          # _ready（引信环等）走全
	e._reflect_cd_max = 3.0                     # 反弹盾就绪注入（spawn 期 special 同源字段）
	e._reflect_cd = 0.0
	e.dead = false
	var b: ProjectileBase = rp.acquire(0)       # 玩家弹（team 0）
	b.pool = rp                                 # 回归归属注入（ballistic_weapon:345 同款）
	_check("b6前置：反射前 team1_live==0（玩家弹不计）", rp.team1_live == 0, "")
	var bounced: bool = e.try_reflect_projectile(b)
	_check("b6翻转计数：try_reflect true → note_team1_flip +1（team1_live==1 精确同步）",
		bounced and rp.team1_live == 1, "bounced=%s live=%d" % [str(bounced), rp.team1_live])
	_check("b6真值：recount_team1 实扫==1 ∧ 写回（b.team 真翻 1——反弹后活弹计入）",
		b.team == 1 and rp.recount_team1() == 1 and rp.team1_live == 1, "")
	# 敌弹N 真值（diag_counts 实扫）：真取敌弹对照（反弹弹在 rp 池不入 GL 面——GL 池独立计数）
	var t0 := int(_gl.diag_counts().get(&"enemy_bullets_live", -1))
	var got := 0
	for i in 2:
		var eb := _gl._projectile_pool.acquire(1)
		if eb != null:
			eb.team = 1                     # 同 b5：调用方 spawn 语义（直赋同源）
			got += 1
	_check("b6敌弹N 真值：GL 池 acquire(1)×2 → diag_counts==前值+2（1Hz 实扫自愈口径）",
		got == 2 and int(_gl.diag_counts().get(&"enemy_bullets_live", -1)) == t0 + 2,
		"got=%d t0=%d now=%d" % [got, t0, int(_gl.diag_counts().get(&"enemy_bullets_live", -1))])
	# 自愈兜底：人为打脏计数器 → recount 归真（未来新翻转点漏记的保险）
	rp.team1_live = 99
	_check("b6自愈：计数器打脏 99 → recount_team1()==1 归真（兜底语义）",
		rp.recount_team1() == 1 and rp.team1_live == 1, "")
	# 冷却期对照：不翻转不再计数（既有行为逐位）
	e._reflect_cd = 1.0
	var b2: ProjectileBase = rp.acquire(0)
	b2.pool = rp
	var bounced2: bool = e.try_reflect_projectile(b2)
	_check("b6冷却期：try_reflect false → 计数不动（team1_live==1）",
		not bounced2 and rp.team1_live == 1, "bounced2=%s live=%d" % [str(bounced2), rp.team1_live])
	rp.free()


# ── 收尾 ───────────────────────────────────────────────────────────

func _cleanup() -> void:
	PerfGovernor.boost_override = -1
	PerfGovernor.set_process(true)
	PerfGovernor._test_reset()
	PerfGovernor.tier = 3
	Enemy.deathpop_cap_override = -1
	Enemy.fullload_override = -1
	Enemy._fullload_latched = false
	# 演出注册表清空（b1 DeathPop 件到期自清——r230 _drain_registry 同款通道）
	var guard := 0
	while not Enemy._death_fx_live.is_empty() and guard < 64:
		for item in Enemy._death_fx_live.duplicate():
			if item != null and is_instance_valid(item):
				item.call("_process", 1.0)
		guard += 1
	if _host != null:
		_host.free()
		_host = null
	if _gl != null:
		_gl.free()
		_gl = null

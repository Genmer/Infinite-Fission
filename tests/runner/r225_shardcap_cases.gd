# tests/runner/r225_shardcap_cases.gd
# R225 用例体：满载期 XP 碎片吸收「双帽并单帽」（刀a）——vc31 满载 dc 减半让路。
# 背景（审计定案）：R213-D 已并珠（fullload 下新掉落无条件并入最近珠，半径无限、
# 不分档）→ 候选 b/c 冗余不实施；本套件锁候选 a 契约：
#   ① 满载门内帧序②⑦共享一顶 24/帧 吸收总预算（原两独立帽最坏 48/帧 → 24/帧，
#      满载 gain_xp 链尖峰减半）；
#   ② 磁吸优先：②段段首按 ready_to_absorb 磁片数预留预算、只花盈余——磁吸收割
#      演出优先入账，预留 ≥ 总帽时圈内非磁片全冻结；
#   ③ 守恒：吸收总经验值一分不丢（gain_xp 原值入账），升级节奏不因帽序重排改变
#      （同帧吸收总量 24 封顶，逐片原值）；
#   ④ 满载解除自动恢复双帽（门关帧预算休眠：②⑦ 各自本地 24，最坏 48 原口径）；
#   ⑤ 非满载零扰动回归锁（默认门 -1 → ② 单帧恰 24、冻结语义、⑦ 单帧恰 24）。
# 坑位纪律：xp 池容量硬帽 160（夹具 130 圈内 + 30 磁吸恰满）；池化实体不 add_child、
# 单次 release；夹具 xp_need=1e12 封顶防升级选卡窗；帧边界用 _fullload_absorb_frame_open
# 显式开帽（与产品帧序两入口同源），不依赖 process 帧推进。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const PLAYER_HOME := Vector2(360.0, 900.0)
const DT := 1.0 / 60.0
const CAP := 24                                 # MAGNET_ABSORB_PER_FRAME 同口径（断言用字面量）

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_boot_game_loop()
	await tree.process_frame
	await tree.process_frame
	_test_1_fullload_single_cap_and_priority()
	_test_2_fullload_release_dual_cap_restored()
	_test_3_non_fullload_regression_lock()
	_test_4_fullload_merge_bead_conservation()
	_test_5_frame_wiring_source_anchor()
	_teardown_game_loop()
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
	_gl.name = "R225GameLoopUnderTest"
	tree.get_root().add_child(_gl)
	_gl.state = GameConst.GameStatus.MENU
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	_gl.start_run()
	_gl.state = GameConst.GameStatus.MENU
	_gl.player.global_position = PLAYER_HOME


func _teardown_game_loop() -> void:
	Enemy.fullload_override = -1                  # 覆写口复位（防跨套件泄漏）
	tree.paused = false
	RunSave.clear()
	if _gl != null:
		_gl.free()
		_gl = null


# ── 夹具：圈内非磁片 n_in 片 + 玩家贴脸磁吸片 n_mag 片（池硬帽 160 内） ──
func _fixture_shards(p_in_circle: int, p_magnet: int) -> Array:
	var pool := _gl.pools[&"xp"] as XPPool
	var shards: Array = _gl.get("active_shards")
	shards.clear()
	_gl.player.set("xp_need", 1e12)               # 坑⑦：封顶防升级选卡窗冲刷
	for i in range(p_in_circle):
		var s: XpShard = pool.acquire()
		if s == null:
			break
		s.activate(1.0, 0.0)                      # 先激活（内含一次性出生散射）
		s.global_position = _gl.player.global_position + Vector2(1.0, 0.0)   # 后落位圈内
		shards.append(s)
	for i in range(p_magnet):
		var m: XpShard = pool.acquire()
		if m == null:
			break
		m.activate(1.0, 0.0)
		m.global_position = _gl.player.global_position   # 贴脸（ready_to_absorb 恒真）
		m.force_magnet()
		shards.append(m)
	return shards


func _magnet_count(p_shards: Array) -> int:
	var n := 0
	for s in p_shards:
		if is_instance_valid(s) and (s as XpShard).is_magnet():
			n += 1
	return n


func _cleanup_shards(p_shards: Array) -> void:
	var pool := _gl.pools[&"xp"] as XPPool
	for s in (p_shards as Array).duplicate():
		if is_instance_valid(s):
			pool.release(s)
	(p_shards as Array).clear()


# ── ① 满载单帽生效 + 磁吸优先（②预留吃满→圈内全冻结；帧总量 ≤24） ──
func _test_1_fullload_single_cap_and_priority() -> void:
	print("── ① 满载单帽+磁吸优先 ──")
	Enemy.fullload_override = 1                   # headless 模拟满载（r213 覆写口先例）
	var shards: Array = _fixture_shards(130, 30)
	_check("①夹具：160 片（130 圈内非磁 + 30 贴脸磁吸）",
		shards.size() == 160 and _magnet_count(shards) == 30,
		"n=%d mag=%d" % [shards.size(), _magnet_count(shards)])
	var acc := [0.0]                              # lambda 按值捕获 → 数组容器累加
	var on_xp := func(p_amount: float) -> void: acc[0] += p_amount
	EventBus.xp_gained.connect(on_xp)
	# 帧1：② 段首预留=30 ≥ 总帽 24 → 圈内片全冻结（磁吸优先锁）
	_gl.call(&"_fullload_absorb_frame_open")      # 帧序入口开帽（产品=PLAYING ②前）
	var s0: int = shards.size()
	_gl.call(&"_tick_xp_shards", DT)
	var s1: int = shards.size()
	_gl.call(&"_tick_magnetized_shards", DT)
	var s2: int = shards.size()
	_check("①帧1：② 段零吸收（预留 30≥24 圈内全冻结，磁吸优先）", s1 == s0,
		"before=%d after=%d" % [s0, s1])
	_check("①帧1：⑦ 段恰收 24（共享帽 24 封顶）", s0 - s2 == CAP,
		"absorbed=%d" % (s0 - s2))
	_check("①帧1：帧总吸收 ≤24（单帽口径，原双帽最坏 48）", s0 - s2 <= CAP, "")
	_check("①帧1：磁吸剩 6（风暴分帧摊开）", _magnet_count(shards) == 6,
		"mag=%d" % _magnet_count(shards))
	# 帧2：② 预留=6 → 圈内恰收 18；⑦ 吃剩余 6 → 磁吸清零（优先兑现）
	_gl.call(&"_fullload_absorb_frame_open")
	var t0: int = shards.size()
	_gl.call(&"_tick_xp_shards", DT)
	var t1: int = shards.size()
	_gl.call(&"_tick_magnetized_shards", DT)
	var t2: int = shards.size()
	_check("①帧2：② 段恰收 18（总帽 24−磁吸预留 6，只花盈余）", t0 - t1 == 18,
		"absorbed=%d" % (t0 - t1))
	_check("①帧2：⑦ 段收尾 6（预留足额兑现）", t1 - t2 == 6 and _magnet_count(shards) == 0,
		"absorbed=%d mag=%d" % [t1 - t2, _magnet_count(shards)])
	_check("①帧2：帧总吸收 ≤24", t0 - t2 <= CAP, "")
	# 帧3+：磁吸清零后圈内片恢复 24/帧 消化至清场
	var frames := 0
	while not shards.is_empty() and frames < 30:
		_gl.call(&"_fullload_absorb_frame_open")
		var u0: int = shards.size()
		_gl.call(&"_tick_xp_shards", DT)
		_gl.call(&"_tick_magnetized_shards", DT)
		var absorbed_frame: int = u0 - shards.size()
		if absorbed_frame > CAP:
			_check("①帧 %d 超帽（%d>24）" % [frames + 3, absorbed_frame], false, "")
			break
		frames += 1
	EventBus.xp_gained.disconnect(on_xp)
	_check("①满载期多帧清场（帽限速下 ≤30 帧）", shards.is_empty(),
		"left=%d frames=%d" % [shards.size(), frames])
	_check("①守恒：吸收总经验 == 掉落总面值（160×1.0 一分不丢）",
		is_equal_approx(acc[0], 160.0),
		"gained=%f expect=160" % acc[0])
	_cleanup_shards(shards)


# ── ② 满载解除：门关帧预算休眠，②⑦ 双帽恢复（帧总 48 原口径） ──
func _test_2_fullload_release_dual_cap_restored() -> void:
	print("── ② 满载解除恢复双帽 ──")
	Enemy.fullload_override = -1                  # 真值门（headless 桌面=关）
	_check("②前置：门已关", not Enemy.fullload_dim(), "")
	var shards: Array = _fixture_shards(130, 30)
	var acc := [0.0]
	var on_xp := func(p_amount: float) -> void: acc[0] += p_amount
	EventBus.xp_gained.connect(on_xp)
	_gl.call(&"_fullload_absorb_frame_open")      # 产品帧序无条件开帽（门关=预算休眠）
	_gl.call(&"_tick_xp_shards", DT)
	var s1: int = shards.size()
	_gl.call(&"_tick_magnetized_shards", DT)
	var s2: int = shards.size()
	_check("②解除帧：② 段恢复本地 24（130 圈内片收 24）", 160 - s1 == CAP,
		"absorbed=%d" % (160 - s1))
	_check("②解除帧：⑦ 段恢复独立 24（磁吸 30 收 24）", s1 - s2 == CAP,
		"absorbed=%d" % (s1 - s2))
	_check("②解除帧：帧总吸收 48（双帽口径复原，单帽已不约束）", 160 - s2 == 2 * CAP,
		"absorbed=%d" % (160 - s2))
	_check("②解除帧：预算休眠（满载单帽剩余未被读扣，仍 24）",
		int(_gl.get("_fullload_absorb_left")) == CAP,
		"left=%d" % int(_gl.get("_fullload_absorb_left")))
	for f in range(30):                           # 多帧清场（监听保持——守恒全程累计）
		_gl.call(&"_tick_xp_shards", DT)
		_gl.call(&"_tick_magnetized_shards", DT)
	EventBus.xp_gained.disconnect(on_xp)
	_check("②多帧清场", shards.is_empty(), "left=%d" % shards.size())
	_check("②守恒：解除后吸收仍一分不丢（夹具 160×1.0）",
		is_equal_approx(acc[0], 160.0),
		"gained=%f expect=160" % acc[0])
	_cleanup_shards(shards)


# ── ③ 非满载零扰动回归锁（默认门，②⑦ 各自 24/帧 + 冻结语义） ──
func _test_3_non_fullload_regression_lock() -> void:
	print("── ③ 非满载回归锁 ──")
	Enemy.fullload_override = -1
	_check("③前置：真值门关（headless 桌面）", not Enemy.fullload_dim(), "")
	var shards: Array = _fixture_shards(160, 0)   # 全圈内非磁片（r215 ② 同款夹具）
	_gl.call(&"_tick_xp_shards", DT)              # 单帧（不开帽——门关预算不参与）
	var after_first: int = shards.size()
	_check("③② 段单帧恰收 24（R215 刀B 契约原样）", 160 - after_first == CAP,
		"absorbed=%d" % (160 - after_first))
	var frozen: XpShard = shards[0] as XpShard
	var f_pos: Vector2 = frozen.global_position
	_gl.call(&"_tick_xp_shards", DT)
	_check("③帽满圈内置片位置冻结（帽满不吸收不位移）",
		is_instance_valid(frozen) and frozen.global_position == f_pos, "")
	# 磁吸片独立帽：⑦ 段单帧 24（非满载不共享）
	var pool := _gl.pools[&"xp"] as XPPool
	for i in range(30):
		var m: XpShard = pool.acquire()
		if m == null:
			break
		m.activate(1.0, 0.0)
		m.global_position = _gl.player.global_position
		m.force_magnet()
		shards.append(m)
	var mag0 := _magnet_count(shards)
	_gl.call(&"_tick_magnetized_shards", DT)
	_check("③⑦ 段单帧恰收 24（独立帽原口径，② 收入不受挤占）",
		mag0 - _magnet_count(shards) == CAP,
		"absorbed=%d" % (mag0 - _magnet_count(shards)))
	for f in range(40):                           # 多帧清场
		_gl.call(&"_tick_xp_shards", DT)
		_gl.call(&"_tick_magnetized_shards", DT)
	_check("③多帧清场", shards.is_empty(), "left=%d" % shards.size())
	_cleanup_shards(shards)


# ── ④ 满载并珠回归 + 大珠经单帽吸收守恒（R213-D 契约不回归） ──
func _test_4_fullload_merge_bead_conservation() -> void:
	print("── ④ 满载并珠+大珠守恒 ──")
	Enemy.fullload_override = 1
	var shards: Array = _gl.get("active_shards")
	shards.clear()
	for i in range(50):
		_gl.call(&"_spawn_xp_shard", Vector2(100.0 + float(i), 200.0), 3.0, 4.0)
	_check("④并珠：50 次掉落只占 1 珠（R213-D 无条件最近并珠）", shards.size() == 1,
		"n=%d" % shards.size())
	var bead: XpShard = shards[0] as XpShard
	_check("④账面守恒：珠面值 == 掉落合计 150（一分不丢不改）",
		is_equal_approx(bead.value, 150.0), "v=%f" % bead.value)
	bead.global_position = _gl.player.global_position
	bead.force_magnet()
	var acc := [0.0]
	var on_xp := func(p_amount: float) -> void: acc[0] += p_amount
	EventBus.xp_gained.connect(on_xp)
	_gl.call(&"_fullload_absorb_frame_open")
	_gl.call(&"_tick_magnetized_shards", DT)      # 大珠经共享帽单帧吸收
	EventBus.xp_gained.disconnect(on_xp)
	_check("④入账守恒：并珠大珠 gain_xp 原值 150（升级节奏不因并珠漂移）",
		shards.is_empty() and is_equal_approx(acc[0], 150.0),
		"gained=%f left=%d" % [acc[0], shards.size()])
	_cleanup_shards(shards)


# ── ⑤ 帧序接线源级锚（r212 先例）：两处帧序开帽 + ⑦共享帽读取在位 ──
func _test_5_frame_wiring_source_anchor() -> void:
	print("── ⑤ 帧序接线锚 ──")
	var src := FileAccess.get_file_as_string("res://scripts/loop/game_loop.gd")
	_check("⑤PLAYING ②入口开帽在位",
		src.contains("_fullload_absorb_frame_open()     # R225 刀a：满载吸收单帽帧序开帽"), "")
	_check("⑤LEVEL_UP/PAUSED ⑦入口开帽在位",
		src.contains("② 未运行的帧序（选卡/暂停）在此开帽"), "")
	_check("⑤⑦ 段共享帽剩余读取在位", src.contains("cap = _fullload_absorb_left"), "")
	_check("⑤② 段磁吸预留计算在位", src.contains("_fullload_absorb_left - reserved"), "")
	Enemy.fullload_override = -1                  # 收尾复位（防跨套件泄漏）

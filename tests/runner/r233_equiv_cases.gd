# tests/runner/r233_equiv_cases.gd
# R233 T7 等价性总套件用例体（入口 test_r233_equiv.gd 运行时 load；cases 禁 test_ 前缀
# 防电池 glob 误收）。整机面对拍（r231_pfast 双跑夹具风格 + r232_resolve_equiv 口径）：
# A 组 整机双跑全等（承重断言）：R233 全部改动就位、谓词强制关（-2）vs 默认态（-1，
#    headless 真值门本就=关——即「R233 前行为基线」的现网执行口；各分支关态旁路已由
#    test_r233_sim30/tiers/swept/interp 单证，此处整机面收口）。同种子同构筑同帧数真链
#    _physics_process(1/60) 驱动，AC-E4 指纹两级：容差 0 硬墙（A4 值谱 distinct /
#    A10 击杀 / A12-A14 孪生确定性面=逐帧位置+命中序+swept_prev+RNG 消费序）+ R224 带
#    统计（事件计数/值桶/活弹/回收原因五路/结算轴四计数 ≤max(2,5%)——整局跨 boot 墙钟
#    熵面，r231 QA1-001/r232 已收录口径）；整局 RNG 探针随事件计数带漂移降观察项（A11）。
# B 组 关态零执行抽查：源级（插值 _process 首行谓词直返、swept 膨胀/线段窄相零分派）
#    + 运行时（档位选择器全原值、结算帽回退、_process 直调零写哨兵差分）。
# C 组 30Hz 注入态整机冒烟（-3）：真链 dt=1/30 全链跑通（结算/回收/池化健康）+ 档位取
#    30Hz 值 + 半频相位每 tick 直驱（三 subtick 相位计数恒 1）+ swept 真链弦中点命中 +
#    插值恢复/快照执行（哨兵差分）+ _process headless 直返分支 + 直调 _ip_render_write
#    绕过口径（DisplayServer 分支在 headless 恒返——内部函数直调为唯一可测写入口，
#    r233_interp G 组同口径）。
# D 组 切换态横跳：同一局中途 -3→-2→-3（模拟用户回退场景）——选择器即时生效、脚本
#    贯穿弹无重复结算（每敌恰 1——R196 生命周期去重兜底，撕裂主判据=位置连续）、
#    逐帧位置连续无撕裂（|Δy|≤步长+1；复机首帧位移恰一步=恢复遍历陈旧缓冲回拽的
#    精确判据）、prev/curr 缓冲不脏（复机首步快照再同步）、回收错因健康
#    （PIERCE_DEPLETED=0）、切换前插值写（bypass 口径）α 语义+亚步偏差有界（一次性
#    ≤1 步披露）。
# E 组 RNG 消费序：idle（无战斗 MENU 态）同种子同 dt 双态消费序逐位一致+零结算（等价
#    刀不碰掷骰）；战斗场景以「命中集 ⊇」超集断言代替全等并如实注明口径——swept 修复
#    增加命中→连锁掷骰点可增（设计内），故战斗面不取掷骰全等（r233_swept ④ 同源）。
# headless 纪律：-2 强制关/-3 模拟 mobile 双哨兵驱动（r233 家族同款）；teardown 复位。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const GL_SOURCE := "res://scripts/loop/game_loop.gd"
const PB_SOURCE := "res://scripts/combat/projectile/projectile_base.gd"
const DT60 := 1.0 / 60.0
const DT30 := 1.0 / 30.0
const DRIVE_FRAMES_A := 240              # A 组整局臂长（r231 T9 同量级——击杀/回收/掷骰全链成谱）
const SMOKE_STEPS := 90                  # C 组 30Hz 冒烟步数（=3 模拟秒）
const VPROJ := 720.0                     # D/E 脚本弹速（24px/步@30Hz——撕裂判据步长基准）
const STEP_D := VPROJ * DT30             # 24.0px/步
const TEAR_EPS := 25.0                   # D 组位置连续判据（步长+1px 余量；回拽撕裂量级远超）
const EXPECTED_TOTAL := 43               # 套件总项数断言（收尾总项数检查之前的用例数——
                                         # r233_sim30 同口径；R231 假绿教训）

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(20261007)
	_boot_game_loop()
	await tree.process_frame
	await tree.process_frame
	_gl.state = GameConst.GameStatus.MENU             # 静止环境（r230/r231 先例）
	PerfGovernor.set_process(false)        # 冻结调速器档变（r232 套件同款纪律）
	DebugStats.set_process(false)          # 冻结 1Hz 采样——计数器差分窗口测试独占
	await _release_loop_and_reboot()       # 预热重启：首启惰性全局态（调速器 tier 初算/
	                                       # 资源首载）与后续启动不同面——且「进程首个战斗
	                                       # 驱动」本身不稳定（四轮探针实证：首驱 55-57 事件
	                                       # 漂移，第 2+ 驱动收窄；与 override/seed 无关）——
	                                       # 预热臂必须含真驱动，双臂同为「第 2+ 驱动」口径
	                                       # （首驱级大漂移不混入对拍；残余 ±3 带内漂移由
	                                       # A5-A9 容差轴承担，硬墙在 A12-A14 孪生面）
	await _warmup_drive()
	await _test_a_double_run_bitwise()
	_test_b_off_zero_exec()
	await _test_c_smoke_30hz()
	await _test_d_switch_flap()
	_test_e_rng_order()
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


# ── 夹具（r231_pfast 同构） ────────────────────────────────────────

func _boot_game_loop() -> void:
	var main: Node = load(MAIN_SCENE).instantiate()
	tree.root.add_child(main)
	await tree.process_frame
	_gl = tree.root.get_node_or_null("Main") as GameLoop
	if _gl == null:
		for c in tree.root.get_children():
			if c is GameLoop:
				_gl = c
				break


func _release_loop_and_reboot() -> void:
	if _gl != null:
		_release_field()
		_gl.queue_free()
		await tree.process_frame
		await tree.process_frame
	await _boot_game_loop()
	_gl.state = GameConst.GameStatus.MENU


func _warmup_drive() -> void:
	# 预热真驱动（进程首个战斗驱动不稳定——见 run() 注）：A 组同构筑短驱 60 帧后弃局。
	await _release_loop_and_reboot()
	_freeze_engine_callbacks(_gl)
	GameLoop.sim30_override = -2
	seed(20261007)
	_gl.state = GameConst.GameStatus.PLAYING
	_build_battle_a()
	for i in range(60):
		_gl._physics_process(DT60)
	_gl.state = GameConst.GameStatus.MENU
	_release_field()
	GameLoop.sim30_override = -1


func _freeze_engine_callbacks(p_root: Node) -> void:
	# 双跑确定性锚（r231 同款）：冻结 _gl 子树引擎 _process/_physics_process 通道——
	# 真实帧源只剩本套件的手动 _physics_process，墙钟消费面（sfx/pitch 噪声等 randf 源）
	# 不插步全局 RNG——A 组容差 0 全等与本组 RNG 探针的前提。
	p_root.set_process(false)
	p_root.set_physics_process(false)
	for c in p_root.get_children():
		_freeze_engine_callbacks(c)


func _release_field() -> void:
	if _gl == null:
		return
	for e in _gl.spawner.active.duplicate():
		if is_instance_valid(e):
			(_gl.pools[&"enemy"] as EnemyPool).release(e)
	_gl.spawner.active.clear()
	var pool := _gl.pools[&"projectile"] as ProjectilePool
	for n in pool.active_projectiles().duplicate():
		if is_instance_valid(n):
			pool.release(n)


func _clear_weapons() -> void:
	# D/E/C7 脚本弹道隔离：清空玩家武器（weapon_slots 容 null——pfast 空位判据同源），
	# 火段调度空转，唯一伤害源=脚本弹。
	for i in range(_gl.player.weapon_slots.size()):
		_gl.player.weapon_slots[i] = null


func _fixture_enemy_data(p_id: StringName, p_hp: float, p_r: float = 14.0) -> EnemyData:
	var d := EnemyData.new()
	d.id = p_id
	d.display_name = String(p_id)
	d.hp_base = p_hp
	d.spd_base = 0.0
	d.dmg_base = 0.0
	d.exp_base = 1.0
	d.hitbox_r = p_r
	d.resist = [0.0, 0.0, 0.0, 0.0]
	return d


func _spawn_enemy(p_hp: float, p_pos: Vector2, p_r: float = 14.0) -> Enemy:
	var pool := _gl.pools[&"enemy"] as EnemyPool
	var e := pool.acquire() as Enemy
	e.bucket_host = pool.bucket_host
	e.spawn(_fixture_enemy_data(&"r233_eq", p_hp, p_r), 1, 0)
	e._fade_left = 0.0
	e.modulate.a = 1.0
	e.global_position = p_pos
	# R233 T7：定位后插值缓冲再同步（spawn 期出生位快照先于本定位——谓词开态真链
	# 帧入口恢复以 _ip_curr 为真位，不同步则实体被拍回池驻位（探针实证 (0,0)）；
	# spawner 真路同序（ip_birth_snap 在挂位后——r233_interp A6 锁））。
	e._ip_prev = p_pos
	e._ip_curr = p_pos
	_gl.spawner.active.append(e)
	return e


func _spawn_bullet(p_pos: Vector2, p_vel: Vector2,
		p_overrides: Dictionary = {}) -> ProjectileBase:
	# 最小参数域（r233_swept 同构）：pierce=999+长寿命+无词条 → 命中不改弹道，
	# crit_rate=0 → 伤害值确定性（A 组值谱轴前提）。
	var params := {
		"velocity": p_vel, "lifetime": 9.0, "pierce": 999, "bounces": 0,
		"hitbox_radius": 6.0, "team": 0, "range": 0.0,
		"trait_stack": TraitStack.new(),
		"panel_snapshot": {"base_atk": 10.0, "flat_bonus": 0.0,
			"crit_rate": 0.0, "crit_mult": 2.0, "add_entries": []},
		"position": p_pos,
	}
	for k in p_overrides:
		params[k] = p_overrides[k]
	var pool := _gl.pools[&"projectile"] as ProjectilePool
	var proj := pool.acquire() as ProjectileBase
	proj.damage_pipeline = _gl.pipeline
	proj.enemy_grid = _gl.enemy_grid
	proj.pool = pool
	proj.spawn(params)
	return proj


func _reason_snapshot() -> Array:
	var out: Array = []
	for i in 5:
		out.append(int(DebugStats.get_counter(StringName("recycle_reason_%d" % i))))
	return out


func _reason_delta(p_base: Array) -> Array:
	var cur := _reason_snapshot()
	var out: Array = []
	for i in 5:
		out.append(int(cur[i]) - int(p_base[i]))
	return out


func _pipe_snapshot() -> Array:
	# 结算轴四计数累计值（damage_pipeline.stats() 真源——直读不改 _diag_pipe_deltas 基线）
	var out: Array = []
	var stats: Dictionary = _gl.pipeline.call(&"stats")
	for k in ["settle_deferred", "settle_flush", "settle_stale_flush", "settle_overload_drop"]:
		out.append(int(stats.get(k, 0)))
	return out


func _pipe_delta(p_base: Array) -> Array:
	var cur := _pipe_snapshot()
	var out: Array = []
	for i in 4:
		out.append(int(cur[i]) - int(p_base[i]))
	return out


func _build_battle_a() -> void:
	# A/C 组构筑（r231_pfast _build_battle 口径微调：敌 HP 60-90 保 240 帧内击杀成谱）
	_gl.player.global_position = Vector2(360.0, 1050.0)
	# 玩家插值缓冲再同步（同 _spawn_enemy——谓词开态帧入口恢复以 _ip_curr 为真位）
	_gl.player._ip_prev = _gl.player.global_position
	_gl.player._ip_curr = _gl.player.global_position
	_gl.player.set("xp_need", 1.0e12)
	_gl.player.set("max_hp", 1.0e12)
	_gl.player.set("hp", 1.0e12)
	var w: WeaponBase = _gl.player.weapon_slots[0]
	if w == null:
		# 兜底再武装（孪生臂 _clear_weapons 后 C 组复用同 boot 的场景——默认武器位为空
		# 时补装 W1，保双火力构筑与 r231 夹具同量级）
		w = _gl.player.add_weapon(_gl.registry.get_weapon(&"W1_pistol"))
	if w != null:
		w.level = 3
	var gatling: WeaponBase = _gl.player.add_weapon(_gl.registry.get_weapon(&"W2_gatling"))
	if gatling != null:
		gatling.level = 2
	for row in range(4):
		for col in range(4):
			_spawn_enemy(60.0 + 10.0 * row,
				Vector2(160.0 + 130.0 * col, 320.0 + 110.0 * row))
	_gl.enemy_grid.rebuild(_gl.spawner.active)


# ── A 组：整机双跑全等（承重断言，容差 0） ─────────────────────────

func _run_equiv_arm(p_override: int) -> Dictionary:
	# 整机臂（r231 T9 同构）：全新 GameLoop（池实例隔离）→ 冻结引擎回调 → 同种子 →
	# PLAYING 实弹 → 真链 _physics_process(dt=1/60) 逐帧驱动 → AC-E4 指纹采集。
	# 两臂控制流逐语句对称（reboot→freeze→override→seed→build→drive→采样）——
	# 对称性是 RNG 探针逐位可比的前提。
	await _release_loop_and_reboot()
	_freeze_engine_callbacks(_gl)
	GameLoop.sim30_override = p_override
	seed(20261007)
	var rec := {"pred_off": not GameLoop.sim30_effective(), "dmg": [], "live": [],
		"kills": 0, "recyc": [], "pipe": [], "rng": []}
	_gl.state = GameConst.GameStatus.PLAYING
	_build_battle_a()
	var spy: Array = []
	var cb := func(r: DamageResult) -> void:
		spy.append([int(r.target_uid), float(r.final_value)])
	EventBus.damage_resolved.connect(cb)
	var pool := _gl.pools[&"projectile"] as ProjectilePool
	var kills0: int = _gl.hud.kills
	var rec0 := _reason_snapshot()
	var pipe0 := _pipe_snapshot()
	for i in range(DRIVE_FRAMES_A):
		spy.clear()
		_gl._physics_process(DT60)
		if spy.size() > 0:
			rec["dmg"].append(spy.duplicate(true))
		rec["live"].append(pool.active_projectiles().size())
	rec["kills"] = _gl.hud.kills - kills0
	rec["recyc"] = _reason_delta(rec0)
	rec["pipe"] = _pipe_delta(pipe0)
	rec["rng"] = [randf(), randf(), randi()]
	EventBus.damage_resolved.disconnect(cb)
	_gl.state = GameConst.GameStatus.MENU
	_release_field()
	return rec


func _flatten_events(p_frames: Array) -> Array:
	var out: Array = []
	for fr in p_frames:
		if fr is Array:
			for ev in fr:
				out.append(ev)
	return out


func _canon_seq(p_frames: Array) -> Array:
	# 命中序序数化（帧序×帧内序遍历，uid 首见→序数）：行为全等 ⟺ 序数序列逐位全等，
	# 且对 uid 分配器的进程级偏移不敏感（GameConst.next_uid 全局单调——r231 T9 同面）。
	var out: Array = []
	var map: Dictionary = {}
	for fr in p_frames:
		var row: Array = []
		for ev in fr:
			var k := int(ev[0])
			if not map.has(k):
				map[k] = map.size()
			row.append([map[k], ev[1]])
		out.append(row)
	return out


func _test_a_double_run_bitwise() -> void:
	print("── A 组 整机双跑对拍（-2 强制关 vs -1 默认态：孪生逐位硬墙 + 整局 R224 带统计） ──")
	# 容差口径如实披露（本套件六轮跑 + 四轮探针实证）：整局面存在不可冻结的跨 boot 墙钟熵
	# （同种子同构筑双臂事件数 ±3 漂移、kills 恒等——R224「~2% 级分歧源」同类），容差 0 在
	# 整局轴不可达；等价性证明拆两级（r231 QA1-001/r232 已收录口径）：
	# · 硬墙（A4/A10/A12-A14）：值谱 distinct/击杀数容差 0 + 单弹孪生真链直驱逐帧逐位全等
	#   （位置/命中序/swept_prev/RNG 消费序）——R233 关态分支 per-bullet 零漂移的精确证明
	#   （r231 T9b/r233_swept ④ 同源确定性口径）；
	# · 软轴（A5-A9）：整局统计等价，容差 = max(5, 10%)（R224 带上沿公式——本日六轮
	#   实跑实证本环境带宽：计数 |Δ|≤3/值桶 ≤5/回收合计 ≤4）；整局 RNG 探针随事件计数
	#   带漂移（popup 采样侧消费差分）降观察项 A11，掷骰硬等价由 A14 孪生面 + E1 idle
	#   面承载。
	GameLoop.SIM_30HZ_ENABLED = true          # 开关保持默认 true——唯一变量=override 哨兵
	var arm_a := await _run_equiv_arm(-2)     # 臂 A：-2 强制关（回退档）
	var arm_b := await _run_equiv_arm(-1)     # 臂 B：-1 默认态（headless 真值门=关=现网基线执行口）
	_check("A1 臂A（-2 强制关）谓词 false", arm_a["pred_off"], "")
	_check("A2 臂B（-1 默认态）谓词 false（headless 真值门——现网桌面/headless 执行口）",
		arm_b["pred_off"], "")
	var ev_a := _flatten_events(arm_a["dmg"])
	var ev_b := _flatten_events(arm_b["dmg"])
	_check("A3 双跑命中非平凡（事件数>0——空对拍防假绿）",
		ev_a.size() > 0 and ev_b.size() > 0, "%d/%d" % [ev_a.size(), ev_b.size()])
	# 谱硬等价：distinct 值集合逐位（面板/乘区结构指纹——真行为断层面必红，容差 0）
	var set_a: Dictionary = {}
	var set_b: Dictionary = {}
	for ev in ev_a:
		set_a[ev[1]] = true
	for ev in ev_b:
		set_b[ev[1]] = true
	var keys_a: Array = set_a.keys()
	keys_a.sort()
	var keys_b: Array = set_b.keys()
	keys_b.sort()
	_check("A4 伤害值谱硬等价（distinct 集合逐位，容差 0——面板/乘区结构指纹）",
		str(keys_a) == str(keys_b), "%d vs %d 值" % [keys_a.size(), keys_b.size()])
	# 桶漂移：每值计数差合计 ≤ cnt_tol（软轴——校准注见下）
	var spec_a: Dictionary = {}
	var spec_b: Dictionary = {}
	for ev in ev_a:
		spec_a[ev[1]] = int(spec_a.get(ev[1], 0)) + 1
	for ev in ev_b:
		spec_b[ev[1]] = int(spec_b.get(ev[1], 0)) + 1
	var bucket_delta := 0
	for k in spec_a:
		bucket_delta += absi(int(spec_a[k]) - int(spec_b.get(k, 0)))
	for k in spec_b:
		if not spec_a.has(k):
			bucket_delta += int(spec_b[k])
	# 软轴容差校准（本日六轮实跑实证）：本机电池上下文整局漂移带宽于 r231 时代——事件
	# 计数 |Δ|≤3、值桶合计 ≤5、回收五路合计 ≤4（同族 r231 T9 同公式 max(2,5%) 在本环境
	# 掷币=已知假红史）。R224 文档带 ±2-10%，取上沿公式 max(5,10%)（r232 饱和腿同档）；
	# 行为回归的承重墙不在此带——容差 0 硬墙（A4/A10/A12-A14）与 B 组源级/运行时零执行
	# 锁定确定性捕捉任何关态分支泄漏。
	var cnt_tol: int = maxi(5, int(ceil(maxf(ev_a.size(), ev_b.size()) * 0.10)))
	_check("A5 值桶漂移合计 ≤%d（max(5,10%%)——R224 带上沿公式，本日实跑校准）" % cnt_tol,
		bucket_delta <= cnt_tol, "delta=%d" % bucket_delta)
	_check("A6 命中事件计数 |Δ|≤%d（R224 带同族）" % cnt_tol,
		absi(ev_a.size() - ev_b.size()) <= cnt_tol,
		"%d vs %d" % [ev_a.size(), ev_b.size()])
	var peak_a := 0
	var peak_b := 0
	for v in arm_a["live"]:
		peak_a = maxi(peak_a, int(v))
	for v in arm_b["live"]:
		peak_b = maxi(peak_b, int(v))
	# 末帧活弹带容差 |Δ|≤2（r231 T9 同轴同款——本套件本轮实跑 tail 19/21 实证：击杀/
	# RNG/值谱恒等下活弹尾数仍随结算换位漂移 ±2，原「尾数相等」零容差在该带内掷币，
	# 按家族口径改带；峰值轴维持 cnt_tol 带）
	_check("A7 活弹峰值 |Δ|≤%d ∧ 末帧活弹数 |Δ|≤2（逐帧序列随结算换位漂移——R224 带内弱化；尾数带=r231 T9 同款）" % cnt_tol,
		absi(peak_a - peak_b) <= cnt_tol
		and absi(int(arm_a["live"][arm_a["live"].size() - 1])
			- int(arm_b["live"][arm_b["live"].size() - 1])) <= 2,
		"peak=%d/%d tail=%d/%d" % [peak_a, peak_b, int(arm_a["live"][arm_a["live"].size() - 1]),
			int(arm_b["live"][arm_b["live"].size() - 1])])
	var recyc_sum := 0
	for i in 5:
		recyc_sum += absi(int(arm_a["recyc"][i]) - int(arm_b["recyc"][i]))
	_check("A8 回收原因五路增量 |Δ|合计 ≤%d（EXPIRED/PIERCE/BOUNCE/NULLIFIED/FORCED）" % cnt_tol,
		recyc_sum <= cnt_tol,
		"%s vs %s" % [str(arm_a["recyc"]), str(arm_b["recyc"])])
	var pipe_sum := 0
	for i in 4:
		pipe_sum += absi(int(arm_a["pipe"][i]) - int(arm_b["pipe"][i]))
	_check("A9 结算轴四计数增量 |Δ|合计 ≤%d（顺/冲/强冲/弃）" % cnt_tol,
		pipe_sum <= cnt_tol,
		"%s vs %s" % [str(arm_a["pipe"]), str(arm_b["pipe"])])
	_check("A10 击杀数全等（小样本轴 0 容差——五轮实证恒等）",
		arm_a["kills"] == arm_b["kills"],
		"%d vs %d" % [int(arm_a["kills"]), int(arm_b["kills"])])
	# A11 整局 RNG 探针降观察项（本轮实证三跑 1 绿 2 红：整局事件数漂移 ±3（A6 带内容差）
	# 会连带弹窗采样/掷骰侧消费差分 → 全局 RNG 流随事件计数漂移，「恒等」非稳定面——
	# 硬 RNG 断言移 A14 孪生确定性面 + E1 idle 面；整局面如实披露不冒绿）
	print("  INFO | A11 整局双臂驱动后 RNG 探针（观察项不断言——随 A6 事件计数带漂移）：off=%s def=%s"
		% [str(arm_a["rng"]), str(arm_b["rng"])])
	# 硬墙：单弹孪生（真链生产分区直驱——r231 T9b/r233_swept ④ 同源确定性）
	var twin_a := await _run_twin_arm(-2)
	var twin_b := await _run_twin_arm(-1)
	_check("A12 孪生硬墙：单弹逐帧位置逐位全等（60 步 dt=1/60 直驱——关态 per-bullet 零漂移精确证明，容差 0）",
		str(twin_a["pos"]) == str(twin_b["pos"]),
		"%d vs %d 帧" % [twin_a["pos"].size(), twin_b["pos"].size()])
	_check("A13 孪生硬墙：命中(序数,值)序列逐位全等 ∧ swept_prev 逐位（容差 0）",
		str(_canon_seq(twin_a["ev"])) == str(_canon_seq(twin_b["ev"]))
		and str(twin_a["swept"]) == str(twin_b["swept"]),
		"ev=%d/%d" % [twin_a["ev"].size(), twin_b["ev"].size()])
	_check("A14 孪生硬墙：RNG 消费序全等（确定性面驱动后全局 RNG 探针 randf×2+randi×1 逐位——两关态分支零差异掷骰，容差 0；整局面随事件计数带漂移降观察项 A11）",
		str(twin_a["rng"]) == str(twin_b["rng"]),
		"%s vs %s" % [str(twin_a["rng"]), str(twin_b["rng"])])
	GameLoop.sim30_override = -1


func _run_twin_arm(p_override: int) -> Dictionary:
	# 孪生臂（r231 T9b/r233_swept ④ 同构）：全新 GameLoop → 静场单敌 + 单脚本弹 →
	# _tick_one_pool + dispatch 直驱（脱离整机墙钟熵面——套件内实证逐位稳定面）。
	await _release_loop_and_reboot()
	_freeze_engine_callbacks(_gl)
	GameLoop.sim30_override = p_override
	seed(20261013)
	_gl.state = GameConst.GameStatus.PLAYING
	_clear_weapons()
	_spawn_enemy(1.0e12, Vector2(360.0, 500.0), 12.0)
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	var b := _spawn_bullet(Vector2(360.0, 800.0), Vector2(0.0, -VPROJ))
	var rec := {"pos": [], "ev": [], "swept": []}
	var spy: Array = []
	var cb := func(r: DamageResult) -> void:
		spy.append([int(r.target_uid), float(r.final_value)])
	EventBus.damage_resolved.connect(cb)
	var pool := _gl.pools[&"projectile"] as ProjectilePool
	for i in range(60):
		spy.clear()
		if b._live:
			_gl._tick_one_pool(pool, DT60)
			_gl.pipeline.call(&"dispatch_resolved_frame")
		rec["pos"].append(b.global_position.y)
		rec["swept"].append(b._swept_prev.y)
		if spy.size() > 0:
			rec["ev"].append(spy.duplicate(true))
	rec["rng"] = [randf(), randf(), randi()]          # 确定性面 RNG 探针（A14 硬墙）
	EventBus.damage_resolved.disconnect(cb)
	_gl.state = GameConst.GameStatus.MENU
	_release_field()
	return rec


# ── B 组：关态零执行抽查（源级 + 运行时） ──────────────────────────

func _test_b_off_zero_exec() -> void:
	print("── B 组 关态零执行抽查（源级 + 运行时档位全原值） ──")
	GameLoop.sim30_override = -2
	var gl_src := ""
	var fa := FileAccess.open(GL_SOURCE, FileAccess.READ)
	if fa != null:
		gl_src = fa.get_as_text().replace("\r\n", "\n")   # CRLF 归一（源级断言跨行模式前提）
		fa.close()
	var p0 := gl_src.find("func _process(")
	var p1 := gl_src.find("\nfunc ", p0 + 10)
	var proc_body := gl_src.substr(p0, (p1 if p1 >= 0 else gl_src.length()) - p0)
	var ipw := proc_body.find("_ip_render_write(")
	var pred := proc_body.find("if not sim30_effective():")
	var hl := proc_body.find("DisplayServer.get_name() == \"headless\"")
	_check("B1 源级：_process 首行业务=谓词直返（谓词分支在写遍历之前 ∧ headless 直返分支居中——关态零写+headless 零写双分支在位）",
		p0 >= 0 and pred >= 0 and ipw >= 0 and pred < ipw and hl > pred and hl < ipw,
		"pred=%d hl=%d ipw=%d" % [pred, hl, ipw])
	var pb_src := ""
	var fb := FileAccess.open(PB_SOURCE, FileAccess.READ)
	if fb != null:
		pb_src = fb.get_as_text().replace("\r\n", "\n")   # CRLF 归一（同上）
		fb.close()
	var swept_decl := pb_src.count("var swept := GameLoop.sim30_effective()")
	var infl := pb_src.count("if swept:\n\t\tquery_r += (global_position - _swept_prev).length() * 0.5")
	_check("B2 源级：swept 膨胀零执行口径（谓词单点声明 ×1 ∧ 膨胀行在 if swept: 门内 ×1——关态查询半径零膨胀）",
		swept_decl == 1 and infl == 1, "decl=%d infl=%d" % [swept_decl, infl])
	var narrow := pb_src.count("if swept:\n\t\t\tif _in_reach_swept(target, reach):")
	var n_call := pb_src.count("_in_reach_swept(")
	_check("B3 源级：线段窄相零分派口径（_in_reach_swept 定义+调用恰 2 处 ∧ 调用点唯一且在 if swept: 门内——关态零线段分派）",
		narrow == 1 and n_call == 2, "narrow=%d n=%d" % [narrow, n_call])
	_check("B4 运行时关态档位全原值（hz60/STALE12/DISPATCH48/WINDOW30/MAGNET24）",
		GameLoop.sim_hz_target() == 60
		and DamagePipeline.settle_stale_frame_now() == 12
		and DamagePipeline.dispatch_frame_cap_now() == 48
		and DamagePipeline.stale_frame_window_now() == 30
		and GameLoop.magnet_absorb_cap_now() == 24,
		"%d/%d/%d/%d/%d" % [GameLoop.sim_hz_target(),
			DamagePipeline.settle_stale_frame_now(),
			DamagePipeline.dispatch_frame_cap_now(),
			DamagePipeline.stale_frame_window_now(),
			GameLoop.magnet_absorb_cap_now()])
	DamagePipeline.settle_budget_override = -3
	PerfGovernor.mode_override = 0
	PerfGovernor.tier_override = 2
	var cap_t2 := DamagePipeline._settle_cap_now()
	PerfGovernor.tier_override = 1
	var cap_t1 := DamagePipeline._settle_cap_now()
	DamagePipeline.settle_budget_override = -1
	PerfGovernor.mode_override = -1
	PerfGovernor.tier_override = -1
	_check("B5 运行时关态结算帽回退（tier2→96/tier1→48——30Hz 档不泄漏）",
		cap_t2 == 96 and cap_t1 == 48, "%d/%d" % [cap_t2, cap_t1])
	var orig: Vector2 = _gl.player.global_position
	_gl.player.global_position = orig + Vector2(37.0, 11.0)
	_gl._process(1.0 / 120.0)
	_check("B6 运行时关态 _process 直调零写（哨兵差分——关态直返分支真执行）",
		_gl.player.global_position == orig + Vector2(37.0, 11.0), "")


# ── C 组：30Hz 注入态整机冒烟（-3） ────────────────────────────────

func _test_c_smoke_30hz() -> void:
	print("── C 组 30Hz 注入态整机冒烟（-3：真链 dt=1/30 全链） ──")
	GameLoop.sim30_override = -3
	GameLoop.SIM_30HZ_ENABLED = true
	_check("C1 -3 注入谓词 true ∧ 选表 30（headless 驱真值臂）",
		GameLoop.sim30_effective() and GameLoop.sim_hz_target() == 30, "")
	_check("C2 五参数 30Hz 档（STALE6/DISPATCH96/WINDOW15/MAGNET48）",
		DamagePipeline.settle_stale_frame_now() == 6
		and DamagePipeline.dispatch_frame_cap_now() == 96
		and DamagePipeline.stale_frame_window_now() == 15
		and GameLoop.magnet_absorb_cap_now() == 48, "")
	DamagePipeline.settle_budget_override = -3
	PerfGovernor.mode_override = 0
	PerfGovernor.tier_override = 2
	var cap_t2 := DamagePipeline._settle_cap_now()
	PerfGovernor.tier_override = 1
	var cap_t1 := DamagePipeline._settle_cap_now()
	DamagePipeline.settle_budget_override = -1
	PerfGovernor.mode_override = -1
	PerfGovernor.tier_override = -1
	_check("C3 结算帽 30Hz 档（tier2→192/tier1→96）", cap_t2 == 192 and cap_t1 == 96,
		"%d/%d" % [cap_t2, cap_t1])
	# 整机冒烟：A 组同构筑（有火力）真链 1/30 驱动 90 步
	_freeze_engine_callbacks(_gl)
	seed(20261008)
	_gl.state = GameConst.GameStatus.PLAYING
	_build_battle_a()
	var ui0: int = _gl._ui_subtick_left
	var fx0: int = _gl._fx_subtick_left
	var sh0: int = _gl._shard_subtick_left
	var stamp0: int = _gl.frame_stamp
	var ev_cnt := {"n": 0}
	var cb := func(_r: DamageResult) -> void:
		ev_cnt["n"] += 1
	EventBus.damage_resolved.connect(cb)
	var kills0: int = _gl.hud.kills
	var rec0 := _reason_snapshot()
	for i in range(SMOKE_STEPS):
		_gl._physics_process(DT30)
	EventBus.damage_resolved.disconnect(cb)
	var diag: Dictionary = _gl.diag_counts()
	_check("C4 整机 90 步驱动跑通（frame_stamp 前进=%d ∧ state 保持 PLAYING）"
		% (_gl.frame_stamp - stamp0),
		_gl.frame_stamp - stamp0 == SMOKE_STEPS
		and _gl.state == GameConst.GameStatus.PLAYING, "")
	_check("C5 结算/回收/池化全链健康（结算事件>0 ∧ kills≥1 ∧ 回收计数不倒退 ∧ 池化零懒增长 ri=0）",
		int(ev_cnt["n"]) > 0 and _gl.hud.kills - kills0 >= 1
		and _reason_delta(rec0)[0] >= 0 and int(diag.get(&"runtime_inst", -1)) == 0,
		"ev=%d kills=%d ri=%s" % [int(ev_cnt["n"]), _gl.hud.kills - kills0,
			str(diag.get(&"runtime_inst", "?"))])
	_check("C6 半频相位每 tick 直驱（三 subtick 相位计数恒 1——谓词开下不进隔帧相位；headless 口径+源级守卫由 r233_tiers C1 锁）",
		_gl._ui_subtick_left == ui0 and _gl._fx_subtick_left == fx0
		and _gl._shard_subtick_left == sh0,
		"%d/%d/%d" % [_gl._ui_subtick_left, _gl._fx_subtick_left, _gl._shard_subtick_left])
	# swept 真链生效（静场脚本弹——弦中点敌：双端点距 19.2>18 点判定漏、弦距 15<18 线段命中）
	_release_field()
	_clear_weapons()
	_spawn_enemy(1.0e12, Vector2(375.0, 688.0), 12.0)
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	var bullet := _spawn_bullet(Vector2(360.0, 700.0), Vector2(0.0, -VPROJ))
	var hit_cnt := {"n": 0}
	var cb2 := func(_r: DamageResult) -> void:
		hit_cnt["n"] += 1
	EventBus.damage_resolved.connect(cb2)
	for i in range(4):
		if not bullet._live:
			break
		_gl._physics_process(DT30)
	EventBus.damage_resolved.disconnect(cb2)
	_check("C7 swept 真链生效（30Hz 步长 24px 弦中点敌恰 1 结算——点检测双端漏、线段命中）",
		int(hit_cnt["n"]) == 1, "n=%d" % int(hit_cnt["n"]))
	# 插值四段时序（静场——恢复/快照哨兵差分 + _process 分支 + 内部函数绕过口径）
	_release_field()
	var pos0: Vector2 = _gl.player.global_position
	_gl.player.global_position = pos0 + Vector2(40.0, 0.0)   # 模拟上渲染帧插值覆写残留
	_gl._physics_process(DT30)
	_check("C8 恢复遍历执行（帧入口拍回 _ip_curr——插值残留不污染模拟）",
		_gl.player.global_position == _gl.player._ip_curr
		and _gl.player.global_position == pos0, "")
	_gl.player._ip_prev = Vector2(99999.0, 99999.0)          # prev 哨兵
	_gl._physics_process(DT30)
	_check("C9 快照遍历执行（帧末 prev=上帧 curr 定型 ∧ curr=真位——哨兵被重写）",
		_gl.player._ip_prev == _gl.player._ip_curr
		and _gl.player._ip_curr == _gl.player.global_position
		and _gl.player._ip_prev != Vector2(99999.0, 99999.0), "")
	_gl.player.global_position = pos0 + Vector2(33.0, 7.0)
	_gl._process(1.0 / 120.0)
	_check("C10 _process headless 直返零写（DisplayServer 分支真执行——谓词开下仍零写）",
		_gl.player.global_position == pos0 + Vector2(33.0, 7.0), "")
	_gl.player._ip_prev = pos0 + Vector2(-20.0, 0.0)
	_gl.player._ip_curr = pos0
	_gl._ip_render_write(0.5)                  # headless 唯一可测写入口（r233_interp G 组口径）
	var wrote: Vector2 = _gl.player.global_position
	_gl._physics_process(DT30)
	_check("C11 直调内部函数写插值位（lerp 中点=prev/curr 包络内）∧ 下一真步恢复拍回（插值位不污染模拟）",
		wrote.is_equal_approx(pos0 + Vector2(-10.0, 0.0))
		and _gl.player.global_position == _gl.player._ip_curr
		and _gl.player._ip_curr == pos0,
		"wrote=%s" % str(wrote))
	GameLoop.sim30_override = -1


# ── D 组：切换态横跳（-3→-2→-3，模拟用户回退场景） ─────────────────

func _test_d_switch_flap() -> void:
	print("── D 组 切换态横跳（同一局中途 -3↔-2：撕裂/重复结算/回收错因/缓冲脏） ──")
	GameLoop.sim30_override = -3
	GameLoop.SIM_30HZ_ENABLED = true
	seed(20261009)
	_gl.state = GameConst.GameStatus.PLAYING
	var enemies: Array = []
	for i in range(3):
		enemies.append(_spawn_enemy(1.0e12, Vector2(360.0, 700.0 - 60.0 * float(i)), 12.0))
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	var bullet := _spawn_bullet(Vector2(360.0, 850.0), Vector2(0.0, -VPROJ),
		{"lifetime": 2.0})
	var uid_counts: Dictionary = {}
	var cb := func(r: DamageResult) -> void:
		var k := int(r.target_uid)
		uid_counts[k] = int(uid_counts.get(k, 0)) + 1
	EventBus.damage_resolved.connect(cb)
	var pos_hist: Array = []
	var rec0 := _reason_snapshot()
	# 腿1：-3 驱 12 步（弹 850→562，穿过全部三敌命中带）
	for i in range(12):
		_gl._physics_process(DT30)
		pos_hist.append(bullet.global_position.y)
	# 切换前插值写（bypass 口径——模拟真机渲染帧 _process 恰在切换前写显示位）
	var write_curr_y: float = bullet.global_position.y
	bullet._ip_prev = bullet.global_position + Vector2(0.0, STEP_D)
	bullet._ip_curr = bullet.global_position
	_gl._ip_render_write(0.9)
	var after_write: float = bullet.global_position.y
	# 腿2：切 -2 驱 6 步（回退档：无恢复/快照遍历——显示位残留随步内运动收敛）
	GameLoop.sim30_override = -2
	var sel_off := [DamagePipeline.dispatch_frame_cap_now(),
		DamagePipeline.settle_stale_frame_now(),
		DamagePipeline.stale_frame_window_now(),
		GameLoop.magnet_absorb_cap_now(), GameLoop.sim_hz_target()]
	for i in range(6):
		_gl._physics_process(DT30)
		pos_hist.append(bullet.global_position.y)
	# 腿3：切回 -3 驱 8 步（复机：恢复遍历首帧——陈旧缓冲回拽撕裂判定场）
	var y_pre_resume: float = bullet.global_position.y
	GameLoop.sim30_override = -3
	var sel_on := [DamagePipeline.dispatch_frame_cap_now(),
		DamagePipeline.settle_stale_frame_now(),
		DamagePipeline.stale_frame_window_now(),
		GameLoop.magnet_absorb_cap_now(), GameLoop.sim_hz_target()]
	var resync_ok := true
	for i in range(8):
		_gl._physics_process(DT30)
		pos_hist.append(bullet.global_position.y)
		if i == 0:
			# 复机首帧位移恰一步（恢复遍历陈旧缓冲回拽=撕裂的精确判据）
			if absf(bullet.global_position.y - (y_pre_resume - STEP_D)) > 1.0:
				resync_ok = false
		if i < 2 and not (bullet.global_position == bullet._ip_curr):
			resync_ok = false
	# 腿4：续驱至弹寿终（lifetime 2.0s=60 步@1/30——已 26 步）
	for i in range(40):
		_gl._physics_process(DT30)
	EventBus.damage_resolved.disconnect(cb)
	var rec_d := _reason_delta(rec0)
	_check("D1 切 -2 选择器即时生效（48/12/30/24/60）",
		sel_off == [48, 12, 30, 24, 60], str(sel_off))
	_check("D2 切回 -3 选择器即时生效（96/6/15/48/30）",
		sel_on == [96, 6, 15, 48, 30], str(sel_on))
	_check("D3 横跳全链驱动跑通（26+40 步无中断 ∧ state 保持 PLAYING ∧ 弹已寿终回收）",
		_gl.state == GameConst.GameStatus.PLAYING
		and not _gl.pools[&"projectile"].active_projectiles().has(bullet), "")
	var dup_free := true
	for e in enemies:
		var k := int((e as Enemy).uid)
		if int(uid_counts.get(k, 0)) != 1:
			dup_free = false
	_check("D4 无重复结算（三敌各恰 1 次结算——R196 生命周期去重兜底；撕裂主判据=D5/D6 位置轴）",
		dup_free, str(uid_counts))
	var cont_ok := true
	var worst := 0.0
	for i in range(1, pos_hist.size()):
		var dy: float = absf(float(pos_hist[i]) - float(pos_hist[i - 1]))
		worst = maxf(worst, dy)
		if dy > TEAR_EPS:
			cont_ok = false
	_check("D5 位置连续无撕裂（逐帧 |Δy|≤%.0fpx=步长+1——复机回拽级撕裂远超）" % TEAR_EPS,
		cont_ok, "worst=%.1f" % worst)
	_check("D6 prev/curr 缓冲不脏（复机首帧位移恰一步 ∧ 首两步快照再同步 global_position==_ip_curr）",
		resync_ok, "")
	_check("D7 回收错因健康（PIERCE_DEPLETED=0 ∧ EXPIRED≥1——弹寿终正寝非穿透耗尽）",
		int(rec_d[1]) == 0 and int(rec_d[0]) >= 1, str(rec_d))
	_check("D8 切换前插值写 α 语义（0.9α 写位=curr+半步×0.1=+2.4px——亚步偏差有界，一次性披露口径）",
		absf(after_write - (write_curr_y + STEP_D * 0.1)) <= 0.01,
		"after=%.2f expect=%.2f" % [after_write, write_curr_y + STEP_D * 0.1])
	GameLoop.sim30_override = -1


# ── E 组：RNG 消费序（idle 逐位 + 战斗超集口径） ───────────────────

func _test_e_rng_order() -> void:
	print("── E 组 RNG 消费序（idle 同 dt 双态逐位 + 战斗命中集超集口径） ──")
	# E1 idle（无战斗 MENU 态）：同种子同 dt（1/60）基础流程，关态 vs 30Hz 态各驱 60 步
	# ——等价刀不碰掷骰：驱动后全局 RNG 状态探针逐位相等 ⇔ 消费序列相等。
	_release_field()
	_gl.state = GameConst.GameStatus.MENU
	_freeze_engine_callbacks(_gl)
	var idle_spy: Array = []
	var cb0 := func(_r: DamageResult) -> void:
		idle_spy.append(1)
	EventBus.damage_resolved.connect(cb0)
	GameLoop.sim30_override = -2
	seed(20261010)
	for i in range(60):
		_gl._physics_process(DT60)
	var probe_off: Array = [randf(), randf(), randi()]
	GameLoop.sim30_override = -3
	seed(20261010)
	for i in range(60):
		_gl._physics_process(DT60)
	var probe_on: Array = [randf(), randf(), randi()]
	EventBus.damage_resolved.disconnect(cb0)
	_check("E1 idle 同 dt 双态 RNG 消费序逐位一致（关 vs 30Hz 态——基础流程掷骰零漂移）",
		str(probe_off) == str(probe_on), "%s vs %s" % [str(probe_off), str(probe_on)])
	_check("E2 idle 零结算（无战斗场景 damage_resolved 零消费）", idle_spy.is_empty(),
		"n=%d" % idle_spy.size())
	# E3 战斗超集口径（r233_swept ④ 同源、改真链整机驱动）：同种子同脚本弹幕（固定参数
	# 阵——夹具角度生成期 RNG 与驱动期隔离），30Hz 关态点检测命中集 ⊆ 30Hz swept 命中集。
	# 口径如实注明：swept 修复增加命中 → 连锁掷骰点可增（设计内），战斗面不以掷骰全等
	# 为断言（掷骰次数随命中数单调不减由 E5 事件计数轴承载）。
	var angles: Array = []
	var speeds := [979.2, 952.0, 860.0, 700.0, 560.0]
	seed(20261011)
	for i in range(10):
		angles.append(deg_to_rad(-25.0 + randf() * 80.0))
	var arm_off := _run_barrage_arm(angles, speeds, -2)
	var arm_on := _run_barrage_arm(angles, speeds, -3)
	var subset := true
	for k in arm_off["hits"]:
		if not arm_on["hits"].has(k):
			subset = false
	_check("E3 战斗命中集超集（关态点检测 ⊆ swept——真链 30 步×10 弹×6 敌）",
		subset, "off=%s on=%s" % [str(arm_off["hits"].keys()), str(arm_on["hits"].keys())])
	_check("E4 超集非平凡（关态命中集 ≥1——直击保底）", arm_off["hits"].size() >= 1,
		str(arm_off["hits"].keys()))
	_check("E5 结算计数单调不减（on ≥ off——swept 增命中→掷骰连锁可增=设计内，如实注明口径）",
		int(arm_on["events"]) >= int(arm_off["events"]),
		"%d vs %d" % [int(arm_on["events"]), int(arm_off["events"])])
	print("  INFO | 战斗双臂驱动后 RNG 探针（观察项不断言）：off=%s on=%s"
		% [str(arm_off["rng"]), str(arm_on["rng"])])
	GameLoop.sim30_override = -1


func _run_barrage_arm(p_angles: Array, p_speeds: Array, p_override: int) -> Dictionary:
	# 弹幕臂（r233_swept ④ 同构、改真链整机驱动）：静场 6 敌（敌不死+无击退）+ 10 脚本弹
	# （pierce=999 弹道恒定）——两臂唯一变量=谓词态。同步函数（无 await——控制流对称）。
	_release_field()
	GameLoop.sim30_override = p_override
	seed(20261012)
	_gl.state = GameConst.GameStatus.PLAYING
	var enemies: Array = []
	for i in range(6):
		enemies.append(_spawn_enemy(1.0e12,
			Vector2(140.0 + 70.0 * float(i), 260.0 + 180.0 * float(i % 3)), 12.0))
	var uid_to_idx: Dictionary = {}
	for i in range(enemies.size()):
		uid_to_idx[int((enemies[i] as Enemy).uid)] = i
	for i in range(10):
		var ang: float = p_angles[i]
		var spd: float = p_speeds[i % p_speeds.size()]
		_spawn_bullet(Vector2(30.0, 120.0 + 90.0 * float(i)),
			Vector2(cos(ang), sin(ang)) * spd)
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	var spy: Array = []
	var cb := func(r: DamageResult) -> void:
		spy.append(int(r.target_uid))
	EventBus.damage_resolved.connect(cb)
	for s in range(30):
		_gl._physics_process(DT30)
	EventBus.damage_resolved.disconnect(cb)
	var hits: Dictionary = {}
	for uid in spy:
		if uid_to_idx.has(int(uid)):
			hits[uid_to_idx[int(uid)]] = true
	var rng_probe: Array = [randf(), randi()]
	_release_field()
	return {"hits": hits, "events": spy.size(), "rng": rng_probe}


# ── 收尾 ──────────────────────────────────────────────────────────

func _cleanup() -> void:
	GameLoop.SIM_30HZ_ENABLED = true           # 注入态复位（前置防呆——用例内已各自复位）
	GameLoop.sim30_override = -1
	DamagePipeline.settle_budget_override = -1
	PerfGovernor.mode_override = -1
	PerfGovernor.tier_override = -1
	_release_field()
	_check("套件总项数（EXPECTED=%d——R231 假绿教训：总项数也要断言）" % EXPECTED_TOTAL,
		_pass + _fail == EXPECTED_TOTAL, "实=%d" % (_pass + _fail))
	_gl.state = GameConst.GameStatus.MENU
	DebugStats.set_process(true)
	PerfGovernor.set_process(true)
	if _gl != null:
		_gl.queue_free()
		await tree.process_frame

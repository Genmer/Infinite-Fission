# tests/qa_r293_simknives_cases.gd
# R293 模拟刀 B 独立验收用例体。契约来源 = 验收要求 1-4：
#   P1 关态固定 seed 逐位对照：enabled=false（恒原查询路径）vs enabled=true，同
#      seed 同场景全量 trace（索敌 uid 序列/开窗计数/冷却值/追击刀位/刀目标）逐位
#      相等——boost 关侧行为逐位不变承重墙的自证（A/B 同进程一键回退口）。
#   P2 深载守恒：lod_beats=2 + dt×2 隔帧执行语义下同样 A/B 逐位相等（lod_beats/
#      逐子拍内联开火/dt 折算语义零波及——本刀只砍查询事件率不砍模拟结果）。
#   P3 查询次数计数口下降：CountingGrid 计数桩 + 3 同位 W9 追击场（敌在 leash 外
#      1600 内——每拍双查最重态）20 帧：off = 60 nearest + 60 circle；on = 0
#      nearest + 20 circle（每帧恰 1 次 1600 圆扫，三武共享；leash 候选首武派生存
#      条、余二武命中——共享正是本刀语义）。SimQueryShare 自证口逐帧账目锁：每帧
#      恰 1 填充（scan 实查）+ 1 派生（首武 leash）+ 4 命中（2 索敌 scan 命中 +
#      2 追击 leash 命中）→ 20 帧锁 fills=20 / derives=20 / hits=80。
#   P4 r220 双锁保真 + 帧共享新为：基类路径一拍 tick 全链 query_nearest 恰 1 次
#      /栈外直调恒真查；同帧同位第二武器零实查；slash 路径 nearest 恒 0、圆扫恰 1。
#   P5 语义墙：dead 位中途翻转逐调用过滤（不假阳）；纪元轴（② 相位括号/_stamp）
#      跨相位/跨 rebuild 不陈旧；cleave 小 reach 门与 1600 条目分键（不放宽进圈判定）。
#   P6 空场早退：is_empty O(1) 短路（零网格查询 + stat_empty_skips 计数）。
# 夹具：main.tscn 真链 boot 后冻结引擎自动 process（直驱——帧号手动推进，复刻
# game_loop ①advance→②武器→④rebuild→⑤敌移 帧序）；武器全真件（OrbitWeapon/
# WeaponBase 探针子类），网格真 SpaceGrid/计数桩，管线透传桩零落血。
# 本套件不写 Meta 设置（cleanup 无 R270 erase 配方面）；收尾还原 PerfGovernor/
# WeaponBase/SimQueryShare 静态并释放全部夹具。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const DT := 1.0 / 60.0
const FRAMES := 24                              # P1/P2 场景帧数（cd 0.15 → 多轮开火周期）
# 被测助手按路径引用（headless -s 不重扫类缓存——R293 修轮根因，同 WeaponBase 侧注）
const SimQueryShare = preload("res://scripts/combat/weapon/sim_query_share.gd")


# ── 夹具 ──────────────────────────────────────────────────────────
# 判定目标桩：uid/dead/hitbox_r 协议 + 树内 position（live 读语义）
# R293 主会话修轮：改 extends Enemy——DamageContext.target 硬类型为 Enemy，原
# Node2D 桩使 build_damage_context 的 ctx.target 赋值运行期失败→函数中止返回
# Nil→arc_slash:326 读 Nil.base_atk（套件 50 条 SCRIPT ERROR 的单一根因），命中
# 结算面未被 A/B 等价覆盖。Enemy 原生 uid/hitbox_r/dead 同名同型（enemy.gd:13/23/42）
# ——桩零重声明；_exit_tree 仅减静态计数、_ready 全量组装 headless 可跑（deeprepro
# 池化同款）。挂树后补 visible=true（Enemy._ready 池内语义置 false——活口语义复位）。
class StubTarget extends Enemy:
	pass


# 透传管线桩（resolve 只算不落血——武器侧 settle 双轨口径的桩臂）
class StubPipeline extends RefCounted:
	func resolve(_p_ctx: DamageContext) -> DamageResult:
		return null


# 计数网格桩（r220 CountingGrid 同款：extends SpaceGrid 覆写计数——本套件 P3/P4/P6 读数口）
class CountingGrid extends SpaceGrid:
	var nearest_calls: int = 0
	var circle_calls: int = 0

	func query_nearest(pos: Vector2, radius: float, exclude: Node2D) -> Node2D:
		nearest_calls += 1
		return super.query_nearest(pos, radius, exclude)

	func query_circle(pos: Vector2, radius: float) -> Array[Node2D]:
		circle_calls += 1
		return super.query_circle(pos, radius)


# 基类索敌口探针（W1 族形状：has_target_now → try_fire → aim_direction 双查链）
class ProbeW1 extends WeaponBase:
	var fired: int = 0
	var acq_log: Array[int] = []

	func try_fire() -> bool:
		aim_direction()
		fired += 1
		return true

	func acquire_target() -> Node2D:
		var r := super.acquire_target()
		acq_log.append(-1 if r == null else int(r.get("uid")))
		return r


# W9 追击斩探针（slash 模式全链：索敌/追击/开窗）
class ProbeW9 extends OrbitWeapon:
	var opened: int = 0
	var acq_log: Array[int] = []

	func acquire_target() -> Node2D:
		var r := super.acquire_target()
		acq_log.append(-1 if r == null else int(r.get("uid")))
		return r

	func _open_slash(p_facing: float, p_center: Vector2) -> void:
		opened += 1
		super(p_facing, p_center)


# W13 定身巨斩探针（cleave 交战门 + 开窗）
class ProbeW13 extends OrbitWeapon:
	var opened: int = 0
	var gate_log: Array[int] = []

	func _cleave_engage_target() -> Node2D:
		var r := super._cleave_engage_target()
		gate_log.append(-1 if r == null else int(r.get("uid")))
		return r

	func _open_slash(p_facing: float, p_center: Vector2) -> void:
		opened += 1
		super(p_facing, p_center)


var tree: SceneTree
var _gl: Node = null
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _wd_counter: int = 0


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


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(293)
	await _boot()
	_p1_off_bitlock()
	_p2_deep_conservation()
	_p3_query_count_drop()
	_p4_r220_contract()
	_p5_semantic_walls()
	_p6_empty_early_exit()
	await _cleanup()


func _boot() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate()
	_gl.name = "R293SimKnives"
	tree.root.add_child(_gl)
	await tree.process_frame
	await tree.process_frame
	if not bool(_gl.get("boot_ready")):
		_check("boot 成功（main.tscn 真链）", false, str(_gl.get("boot_fatal")))
	else:
		_check("boot 成功（main.tscn 真链）", true, "")
	_gl.set_physics_process(false)               # 冻结真环（帧号/网格由本套件直驱复刻帧序）
	_gl.set_process(false)
	PerfGovernor.set_process(false)


# ── 数据夹具 ──────────────────────────────────────────────────────
func _make_melee_data(p_mode: String, p_cd: float) -> WeaponData:
	# 近战 WeaponData 桩（slash/cleave 按 mode 键——WeaponBase.melee_mode_of 单源口径）
	_wd_counter += 1
	var d := WeaponData.new()
	d.id = StringName("W_R293_%d" % _wd_counter)
	d.display_name = "R293 测试武器 %d" % _wd_counter
	d.form = GameConst.WeaponForm.MELEE
	d.crit_rate = 0.0
	d.crit_dmg = 2.0
	d.hitbox_r = 6.0
	for i in range(5):
		var ls := WeaponLevelStats.new()
		ls.base_atk = 10.0
		ls.rof = 5.0
		ls.cd = p_cd
		ls.pierce = 1
		ls.pellets = 1
		d.upgrade_table.append(ls)
	d.melee["mode"] = p_mode
	d.melee["slash_radius"] = 150.0
	d.melee["arc_deg"] = 120.0
	d.melee["max_targets"] = 8
	d.melee["orbs"] = 1
	return d


func _make_ballistic_data() -> WeaponData:
	_wd_counter += 1
	var d := WeaponData.new()
	d.id = StringName("W_R293_%d" % _wd_counter)
	d.display_name = "R293 基类索敌探针 %d" % _wd_counter
	d.form = GameConst.WeaponForm.BALLISTIC
	d.crit_rate = 0.0
	d.crit_dmg = 2.0
	d.hitbox_r = 6.0
	for i in range(5):
		var ls := WeaponLevelStats.new()
		ls.base_atk = 10.0
		ls.rof = 5.0
		ls.cd = 0.25
		ls.pierce = 1
		ls.pellets = 1
		d.upgrade_table.append(ls)
	return d


func _spawn_w9(p_grid: SpaceGrid) -> ProbeW9:
	var w := ProbeW9.new()
	w.name = "R293W9_%d" % _wd_counter
	tree.root.add_child(w)
	w.position = Vector2(360.0, 640.0)
	w.setup(_make_melee_data("slash", 0.15), null,
		{"pipeline": StubPipeline.new(), "enemy_grid": p_grid})
	return w


# ── P1/P2 共用场景：W9×2（同位——本体+副本共享面）+ W13 cleave + W1 基类探针；
#    5 敌确定性布点（含精确等距对——锁 argmin 平局取向）+ f7 后 dead 翻转 + 逐帧漂移。
#    帧序复刻 game_loop：①advance_frame → ②武器拍 → ④rebuild → ⑤敌移 ──────────
func _run_scenario(p_enabled: bool, p_deep: bool) -> Array:
	SimQueryShare.enabled = p_enabled
	SimQueryShare.reset_diag()
	var grid := SpaceGrid.new()
	grid.configure(Vector2(2000.0, 2000.0), 200.0)
	var enemies: Array[StubTarget] = []
	var layout := [
		Vector2(440.0, 640.0),                   # e0：贴身 80px（W9 追击/W13 进圈目标；f7 后 dead）
		Vector2(120.0, 760.0),                   # e1：~269px
		Vector2(1060.0, 440.0),                  # e2：~748px（leash 375 外——空候选态）
		Vector2(510.0, 550.0),                   # e3：~175px ┐ 精确等距对（漂移对称保持
		Vector2(510.0, 730.0),                   # e4：~175px ┘ 平局——锁 argmin 首个取向）
	]
	var drift := [
		Vector2(-6.0, 0.0), Vector2(0.0, 4.0), Vector2(5.0, -3.0),
		Vector2(2.0, 2.0), Vector2(2.0, -2.0),
	]
	for i in range(layout.size()):
		var t := StubTarget.new()
		t.uid = 500 + i
		tree.root.add_child(t)
		t.visible = true                  # R293 修轮：Enemy._ready 池内语义置 false——活口复位
		t.position = layout[i]
		enemies.append(t)
	var w9a := _spawn_w9(grid)
	var w9b := _spawn_w9(grid)
	var w13 := ProbeW13.new()
	w13.name = "R293W13"
	tree.root.add_child(w13)
	w13.position = Vector2(360.0, 640.0)
	w13.setup(_make_melee_data("cleave", 0.15), null,
		{"pipeline": StubPipeline.new(), "enemy_grid": grid})
	var w1p := ProbeW1.new()
	w1p.name = "R293W1"
	tree.root.add_child(w1p)
	w1p.position = Vector2(360.0, 640.0)
	w1p.setup(_make_ballistic_data(), null,
		{"pipeline": StubPipeline.new(), "enemy_grid": grid})
	var weapons: Array = [w9a, w9b, w13, w1p]
	var live: Array[Node2D] = []
	for e in enemies:
		live.append(e)
	grid.rebuild(live)                          # 首帧 ② 前已有快照（production 波首口径）
	var trace: Array = []
	for f in range(FRAMES):
		GameConfig.advance_frame()              # ① 后 ② 前（game_loop.gd:891 口径）
		var run := (not p_deep) or (f % 2 == 0)
		WeaponBase.lod_dt_doubled = run and p_deep
		WeaponBase.lod_beats = 2
		if run:
			SimQueryShare.begin_phase()            # ② 相位括号（生产写点=player.tick 武器段）
			for w in weapons:
				w.tick(DT * (2.0 if p_deep else 1.0))
			SimQueryShare.end_phase()
		else:
			pass                                   # 深载跳步帧（weapon_lod_skip——武器拍零推进）
		var rec := {
			"w9a": _snap_w9(w9a),
			"w9b": _snap_w9(w9b),
			"w13": {"gate": w13.gate_log.duplicate(), "opened": w13.opened,
				"cd": w13.cooldown_left},
			"w1": {"acq": w1p.acq_log.duplicate(), "fired": w1p.fired,
				"cd": w1p.cooldown_left},
		}
		trace.append(rec)
		grid.rebuild(live)                      # ④（当前位快照）
		for i in range(enemies.size()):         # ⑤（下一帧 ② 的 live 读位）
			enemies[i].position += drift[i]
		if f == 7:
			enemies[0].dead = true              # ② 内前序武器击杀语义（位置不变 dead 翻转）
	for w in weapons:
		w.free()
	for e in enemies:
		e.free()
	WeaponBase.lod_dt_doubled = false
	WeaponBase.lod_beats = 2
	return trace


func _snap_w9(p_w: ProbeW9) -> Dictionary:
	var knife: Array = []
	var ktgt: Array[int] = []
	if p_w.orbit_field != null and is_instance_valid(p_w.orbit_field):
		knife = p_w.orbit_field._knife_pos.duplicate()
		for t in p_w.orbit_field._knife_target:
			ktgt.append(-1 if t == null else int(t.get("uid")))
	return {"acq": p_w.acq_log.duplicate(), "opened": p_w.opened,
		"cd": p_w.cooldown_left, "knife": knife, "ktgt": ktgt,
		"seq": p_w._tick_seq}


func _deep_eq(a, b) -> bool:
	if a is Dictionary and b is Dictionary:
		var da: Dictionary = a
		var db: Dictionary = b
		if da.size() != db.size():
			return false
		for k in da:
			if not db.has(k) or not _deep_eq(da[k], db[k]):
				return false
		return true
	if a is Array and b is Array:
		var aa: Array = a
		var ab: Array = b
		if aa.size() != ab.size():
			return false
		for i in range(aa.size()):
			if not _deep_eq(aa[i], ab[i]):
				return false
		return true
	return a == b


# ── P1：关态固定 seed 逐位对照（承重墙自证——A/B 同进程一键回退口） ─────────────
func _p1_off_bitlock() -> void:
	print("── P1 关态逐位对照（enabled off vs on，全量 trace 相等） ──")
	var off_a := _run_scenario(false, false)
	var off_b := _run_scenario(false, false)
	var on_a := _run_scenario(true, false)
	_check("1a 关态同 seed 双跑确定（off/off trace 逐位相等）",
		_deep_eq(off_a, off_b), "帧差=%d" % _first_diff(off_a, off_b))
	_check("1b 关态 enabled=false vs true 全量 trace 逐位相等（承重墙）",
		_deep_eq(off_a, on_a), "帧差=%d" % _first_diff(off_a, on_a))
	_check("1c 场景有效性：W9 开窗 >0 且索敌序列非空",
		(on_a[FRAMES - 1]["w9a"].opened + on_a[FRAMES - 1]["w9b"].opened) > 0
			and on_a[FRAMES - 1]["w9a"]["acq"].size() > 0,
		"opened=%d" % (on_a[FRAMES - 1]["w9a"].opened + on_a[FRAMES - 1]["w9b"].opened))
	_check("1d 场景有效性：dead 翻转后索敌出现 -1（过滤口径触发）",
		-1 in on_a[FRAMES - 1]["w9a"]["acq"] or -1 in on_a[FRAMES - 1]["w13"]["gate"],
		"w9acq=%s" % str(on_a[FRAMES - 1]["w9a"]["acq"]).substr(0, 40))
	_check("1e 场景有效性：追击刀位非恒定（chase 推进）",
		not _deep_eq(on_a[3]["w9a"]["knife"], on_a[FRAMES - 1]["w9a"]["knife"]), "")
	var on_stats := {"fills": SimQueryShare.stat_fills, "hits": SimQueryShare.stat_hits,
		"derives": SimQueryShare.stat_leash_derives}
	_check("1f 自证口：关态 on 路径缓存已生效（fills/hits/derives >0）",
		on_stats["fills"] > 0 and on_stats["hits"] > 0 and on_stats["derives"] > 0,
		str(on_stats))


func _first_diff(a: Array, b: Array) -> int:
	for i in range(mini(a.size(), b.size())):
		if not _deep_eq(a[i], b[i]):
			return i
	if a.size() != b.size():
		return mini(a.size(), b.size())
	return -1


# ── P2：深载守恒（lod_beats=2 / dt×2 隔帧执行语义零波及） ───────────────────────
func _p2_deep_conservation() -> void:
	print("── P2 深载守恒（deep A/B 逐位 + 子拍递推零漂移） ──")
	var deep_off := _run_scenario(false, true)
	var deep_on := _run_scenario(true, true)
	_check("2a 深载 enabled=false vs true 全量 trace 逐位相等（守恒）",
		_deep_eq(deep_off, deep_on), "帧差=%d" % _first_diff(deep_off, deep_on))
	_check("2b 深载跳步语义在位（奇数帧武器拍零推进 / 偶数帧恰 1 拍——seq 锁）",
		deep_on[1]["w9a"].seq == deep_on[0]["w9a"].seq
			and deep_on[2]["w9a"].seq == deep_on[1]["w9a"].seq + 1
			and deep_on[FRAMES - 1]["w9a"].seq == FRAMES >> 1,
		"seq0=%d seq1=%d seq2=%d seqN=%d" % [deep_on[0]["w9a"].seq,
			deep_on[1]["w9a"].seq, deep_on[2]["w9a"].seq,
			deep_on[FRAMES - 1]["w9a"].seq])
	_check("2c 深载 W9 索敌拍数=执行拍数（隔帧索敌——acq 序列长度 < 帧数）",
		deep_on[FRAMES - 1]["w9a"]["acq"].size() < FRAMES
			and deep_on[FRAMES - 1]["w9a"]["acq"].size() > 0,
		"n=%d" % deep_on[FRAMES - 1]["w9a"]["acq"].size())


# ── P3：查询次数计数口下降（CountingGrid + 3 同位 W9 追击场 20 帧） ─────────────
func _p3_query_count_drop() -> void:
	print("── P3 查询计数口下降（off 120 扫 → on 20 扫） ──")
	var counts := _chase_scenario(false)
	_check("3a off 基线：20 帧 × 3 武 = nearest 60 + circle 60（每拍双查原口径）",
		counts["nearest"] == 60 and counts["circle"] == 60, str(counts))
	counts = _chase_scenario(true)
	_check("3b on：nearest 恒 0（slash 索敌 1600 圆扫派生——零 query_nearest）",
		counts["nearest"] == 0, str(counts))
	_check("3c on：circle 恰 20（每帧 1 次 1600 圆扫，三武共享）",
		counts["circle"] == 20, str(counts))
	_check("3d on：扫描总量 120 → 20（-83%，计数口下降断言）",
		counts["nearest"] + counts["circle"] == 20, str(counts))
	_check("3e 自证口：每帧恰 1 填充+1 派生+4 命中（fills=20/derives=20/hits=80——leash 条目同帧共享：首武派生存条，余二武命中不再派生）",
		SimQueryShare.stat_fills == 20 and SimQueryShare.stat_leash_derives == 20
			and SimQueryShare.stat_hits == 80,
		"fills=%d derives=%d hits=%d" % [SimQueryShare.stat_fills,
			SimQueryShare.stat_leash_derives, SimQueryShare.stat_hits])


func _chase_scenario(p_enabled: bool) -> Dictionary:
	# 3 同位 W9 + 单敌 800px（leash 375 外、1600 内）——cd 恒 0 每拍双查最重态；
	# 每帧 advance+rebuild+新相位括号（纪元推进——逐帧条目重建，20 帧恒定形态）。
	SimQueryShare.enabled = p_enabled
	SimQueryShare.reset_diag()
	var grid := CountingGrid.new()
	grid.configure(Vector2(2000.0, 2000.0), 200.0)
	var e := StubTarget.new()
	e.uid = 900
	tree.root.add_child(e)
	e.position = Vector2(1160.0, 640.0)          # 距玩家 800px
	var live: Array[Node2D] = [e]
	grid.rebuild(live)
	var w9s: Array[ProbeW9] = []
	for i in range(3):
		w9s.append(_spawn_w9(grid))
	for f in range(20):
		GameConfig.advance_frame()
		SimQueryShare.begin_phase()                # ② 相位括号（三武同相位共享一条目）
		for w in w9s:
			w.tick(DT)
		SimQueryShare.end_phase()
		grid.rebuild(live)
	for w in w9s:
		w.free()
	e.free()
	return {"nearest": grid.nearest_calls, "circle": grid.circle_calls}


# ── P4：r220 双锁保真 + 帧共享新为 ─────────────────────────────────────────────
func _p4_r220_contract() -> void:
	print("── P4 r220 契约（一拍恰 1 次 / 栈外恒真查 / 帧共享） ──")
	SimQueryShare.enabled = true
	SimQueryShare.reset_diag()
	var grid := CountingGrid.new()
	grid.configure(Vector2(2000.0, 2000.0), 200.0)
	var e := StubTarget.new()
	e.uid = 910
	tree.root.add_child(e)
	e.position = Vector2(440.0, 640.0)
	grid.rebuild([e])
	var w1 := ProbeW1.new()
	w1.name = "R293P4W1"
	tree.root.add_child(w1)
	w1.position = Vector2(360.0, 640.0)
	w1.setup(_make_ballistic_data(), null,
		{"pipeline": StubPipeline.new(), "enemy_grid": grid})
	w1.cooldown_left = 0.0
	grid.nearest_calls = 0
	SimQueryShare.begin_phase()
	w1.tick(DT)
	SimQueryShare.end_phase()
	_check("4a 基类路径：一拍 tick 全链 query_nearest 恰 1 次（R220 锁保持）",
		grid.nearest_calls == 1, "calls=%d" % grid.nearest_calls)
	w1.cooldown_left = 0.0
	w1.try_fire()                                # 栈外直调——恒真查（括号外+栈外双闸）
	_check("4b 栈外直调不共享缓存（R220 锁保持）",
		grid.nearest_calls >= 2, "calls=%d" % grid.nearest_calls)
	var w2 := ProbeW1.new()
	w2.name = "R293P4W2"
	tree.root.add_child(w2)
	w2.position = Vector2(360.0, 640.0)
	w2.setup(_make_ballistic_data(), null,
		{"pipeline": StubPipeline.new(), "enemy_grid": grid})
	var calls_before := grid.nearest_calls
	GameConfig.advance_frame()                   # 新帧纪元（帧共享跨武器、跨帧作废）
	SimQueryShare.begin_phase()
	w1.cooldown_left = 0.0
	w1.tick(DT)
	w2.cooldown_left = 0.0
	w2.tick(DT)
	SimQueryShare.end_phase()
	_check("4c 同帧同位第二武器零实查（帧共享——新帧恰 1 次 nearest）",
		grid.nearest_calls == calls_before + 1,
		"before=%d after=%d" % [calls_before, grid.nearest_calls])
	# slash 路径：一拍 tick 全链 query_nearest 恒 0、query_circle 恰 1（1600 圆扫合并）
	var w9 := _spawn_w9(grid)
	grid.nearest_calls = 0
	grid.circle_calls = 0
	SimQueryShare.begin_phase()
	w9.tick(DT)
	SimQueryShare.end_phase()
	_check("4d slash 路径：一拍 tick query_nearest 恒 0 + query_circle 恰 1（合并派生）",
		grid.nearest_calls == 0 and grid.circle_calls == 1,
		"nearest=%d circle=%d" % [grid.nearest_calls, grid.circle_calls])
	w9.free()
	w1.free()
	w2.free()
	e.free()


# ── P5：语义墙（dead 过滤 / 帧纪元双轴 / cleave 小 reach 分键） ─────────────────
func _p5_semantic_walls() -> void:
	print("── P5 语义墙（dead 过滤 / 帧纪元 / cleave 分键） ──")
	SimQueryShare.enabled = true
	SimQueryShare.reset_diag()
	# dead 翻转：前序武器击杀最近敌 → 后续武器（同帧同位）正确 null——不假阳
	#（现口径：query_nearest 不滤 dead、acquire 后置单发过滤无次近回落——帧缓存裸
	# 节点 + 逐调用过滤与原路径逐位同法）
	var grid := SpaceGrid.new()
	grid.configure(Vector2(2000.0, 2000.0), 200.0)
	var e0 := StubTarget.new()
	e0.uid = 920
	var e1 := StubTarget.new()
	e1.uid = 921
	tree.root.add_child(e0)
	tree.root.add_child(e1)
	e0.position = Vector2(420.0, 640.0)          # 60px（最近）
	e1.position = Vector2(500.0, 640.0)          # 140px（次近——不回落口径的对照位）
	grid.rebuild([e0, e1])
	var wa := _spawn_probe_w1(grid)
	var wb := _spawn_probe_w1(grid)
	SimQueryShare.begin_phase()                  # 同一 ② 相位（wa 击杀 e0 → wb 同相位索敌）
	wa.tick(DT)
	_check("5a 前序武器索敌成功（最近 e0）", wa.acq_log[-1] == 920, str(wa.acq_log))
	e0.dead = true                               # ② 内击杀语义（位置不变翻 dead）
	wb.tick(DT)                                  # 同相位——读共享裸节点 + 逐调用过滤
	SimQueryShare.end_phase()
	_check("5b dead 翻转后同相位后续武器返 null（不假阳、无次近回落——原口径逐位）",
		wb.acq_log[-1] == -1, str(wb.acq_log))
	# 纪元轴一（相位括号）：新相位条目作废 → live 新位重查生效（frame_stamp 刻意
	# 冻结、不 rebuild——隔离相位号轴独自承担失效）
	e0.dead = false
	e1.position = Vector2(380.0, 640.0)          # e1 移至 20px（新最近；陈旧条目会答 920）
	wa.cooldown_left = 0.0
	SimQueryShare.begin_phase()
	wa.tick(DT)
	SimQueryShare.end_phase()
	_check("5c 相位纪元：跨相位条目作废（live 新位重查——答新最近 e1）",
		wa.acq_log[-1] == 921, str(wa.acq_log))
	# 帧纪元轴二：headless frame_stamp 冻结下 _stamp（rebuild）独自承担失效
	var grid2 := SpaceGrid.new()
	grid2.configure(Vector2(2000.0, 2000.0), 200.0)
	var eA := StubTarget.new()
	eA.uid = 930
	var eB := StubTarget.new()
	eB.uid = 931
	tree.root.add_child(eA)
	tree.root.add_child(eB)
	eA.position = Vector2(410.0, 640.0)          # 50px
	eB.position = Vector2(500.0, 640.0)          # 140px
	grid2.rebuild([eA, eB])
	var wc := _spawn_probe_w1(grid2)
	SimQueryShare.begin_phase()
	wc.tick(DT)
	_check("5d _stamp 纪元前：最近=eA(50px)", wc.acq_log[-1] == 930, str(wc.acq_log))
	eB.position = Vector2(380.0, 640.0)          # eB 移至 20px
	grid2.rebuild([eA, eB])                      # 同相位内 rebuild 递增 _stamp（隔离该轴）
	wc.cooldown_left = 0.0
	wc.tick(DT)
	SimQueryShare.end_phase()
	_check("5e _stamp 纪元：rebuild 后条目作废（不吐陈旧 eA）",
		wc.acq_log[-1] == 931, str(wc.acq_log))
	# cleave 小 reach 门与 1600 条目分键：敌在 reach 外 1600 内 → 门关而基类索敌在
	var grid3 := SpaceGrid.new()
	grid3.configure(Vector2(2000.0, 2000.0), 200.0)
	var efar := StubTarget.new()
	efar.uid = 940
	tree.root.add_child(efar)
	efar.position = Vector2(660.0, 640.0)        # 300px：> cleave reach 172、< 1600
	grid3.rebuild([efar])
	var w13 := ProbeW13.new()
	w13.name = "R293P5W13"
	tree.root.add_child(w13)
	w13.position = Vector2(360.0, 640.0)
	w13.setup(_make_melee_data("cleave", 0.15), null,
		{"pipeline": StubPipeline.new(), "enemy_grid": grid3})
	var wd := _spawn_probe_w1(grid3)
	SimQueryShare.begin_phase()
	wd.tick(DT)                                  # 基类 1600 条目已建（敌 300px）
	w13.tick(DT)                                 # cleave 门 reach 172——独立键
	SimQueryShare.end_phase()
	_check("5f cleave 小 reach 门不被 1600 条目顶替（门关 gate=-1 而基类索敌在）",
		wd.acq_log[-1] == 940 and w13.gate_log[-1] == -1,
		"w1=%s gate=%s" % [str(wd.acq_log[-1]), str(w13.gate_log[-1])])
	wa.free()
	wb.free()
	wc.free()
	wd.free()
	w13.free()
	e0.free()
	e1.free()
	eA.free()
	eB.free()
	efar.free()


func _spawn_probe_w1(p_grid: SpaceGrid) -> ProbeW1:
	var w := ProbeW1.new()
	w.name = "R293P5W1_%d" % _wd_counter
	tree.root.add_child(w)
	w.position = Vector2(360.0, 640.0)
	w.setup(_make_ballistic_data(), null,
		{"pipeline": StubPipeline.new(), "enemy_grid": p_grid})
	return w


# ── P6：空场早退（is_empty O(1) 短路） ─────────────────────────────────────────
func _p6_empty_early_exit() -> void:
	print("── P6 空场早退（零网格查询 + 计数口） ──")
	SimQueryShare.enabled = true
	SimQueryShare.reset_diag()
	var grid := CountingGrid.new()
	grid.configure(Vector2(2000.0, 2000.0), 200.0)   # 未 rebuild——快照空
	var w := _spawn_probe_w1(grid)
	SimQueryShare.begin_phase()
	w.tick(DT)
	SimQueryShare.end_phase()
	_check("6a 空场索敌 null（原口径——无敌不开火门）", w.acq_log[-1] == -1,
		str(w.acq_log))
	_check("6b 空场零网格查询（is_empty O(1) 短路——nearest/circle 均 0）",
		grid.nearest_calls == 0 and grid.circle_calls == 0,
		"nearest=%d circle=%d" % [grid.nearest_calls, grid.circle_calls])
	_check("6c 自证口：stat_empty_skips >0", SimQueryShare.stat_empty_skips > 0,
		"skips=%d" % SimQueryShare.stat_empty_skips)
	w.free()


# ── 收尾（静态还原 + 夹具释放；本套件未写 Meta——无 R270 erase 面） ─────────────
func _cleanup() -> void:
	print("── 收尾（静态还原/夹具释放） ──")
	SimQueryShare.enabled = true
	SimQueryShare.reset_diag()
	WeaponBase.lod_dt_doubled = false
	WeaponBase.lod_beats = 2
	PerfGovernor.boost_override = -1
	PerfGovernor.deep_override = -1
	_gl.free()
	await tree.process_frame
	var total := _pass + _fail
	print("验收汇总：%d/%d 通过" % [_pass, total])
	if _fail > 0:
		print("失败明细：")
		for f in _failures:
			print("  - %s" % f)

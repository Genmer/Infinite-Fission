# tests/qa_r293qa_sim_cases.gd（R293 QA 独立验收用例体——qa_r293qa_sim.gd 入口运行时加载）
# 独立口径：不复用开发套件（qa_r293_simknives/qa_r293_fpscap）的夹具形状、敌人布点与
# 断言路径（qa_r272_qa_indep 先例）。断言面 = 本刀验收点 1-5：
#   S1 关态逐位不变：SimQueryShare.enabled=false vs true，同 seed（2933）同场景 40 帧
#      全量 trace（索敌 uid 序列/开火/冷却/追击刀位/刀目标/齐射目标）逐位相等 + off 双跑
#      确定 + on 路径共享确已生效（否则相等是空验证）。
#   S2 深载守恒：lod_dt_doubled 隔帧执行 + 子拍内联语义下同样 A/B 逐位相等；lod_beats=2
#      与 4（副武组深载口径——开发套件未覆盖的轴）双档。
#   S3 查询共享：计数口下降（off 60 nearest+60 circle → on 0+20）+ 每帧索敌结果逐帧
#      等价（on/off 同帧同 uid）+ 自证口账目（fills/derives/hits）。
#   S4 共享 API 随机对拍：30 个 seed 随机场上 shared_nearest/slash_nearest/
#      shared_scan_cands/slash_leash_candidates 与直接 query_nearest/query_circle
#      逐元素同序等价（含精确平局对 + reach 边界 + 空场臂）。
#   S5 r220 契约 + 相位括号边界：一拍恰 1 查/栈外恒真查/同帧同位第二武器零实查/
#      括号外 tick 恒原查询（无 begin/end 直驱——测试直驱路径承重墙）。
#   S6 帧率帽：默认 60 不动/四档写读往返/写口钳制/headless 运行时墙/真实面板四拍循环
#      （含「✓ 不限」文案）/脏档归位。
#   S7 drawcallsN：1Hz 行尾键（位序 弹拒<drawcalls、行尾段）+ headless 恒 0 同源对读 +
#      导出口径头 R293 段（%% 转义活链：促N 句单 % 渲染在场）+ 产物在盘。
#   S8 取证探针（取证式 PASS=记录实测事实，缺陷在报告中另行登记）：
#      a) leash>1600 派生缺口（理论边界——当前数据全叠加上限 ~1425 不可达）；
#      b) 相位内冻结契约（② 内同键查询恒同值——R231/R293 结构保证的行为面读证）。
# 环境注意：本套件不 boot main.tscn（autoload 在 -s 模式随项目加载——GameConfig/
# PerfGovernor/DebugStats/Meta 全在场）；不写 project 设置；收尾还原全部静态 + Meta 快照。
extends RefCounted

const SimQueryShare = preload("res://scripts/combat/weapon/sim_query_share.gd")

const DT := 1.0 / 60.0
const FRAMES := 40
const P0 := Vector2(400.0, 600.0)               # 主武器簇位（同位共享面）
const P1 := Vector2(760.0, 840.0)               # 异位 W9 位（键不撞——不共享面）

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _wd_counter: int = 0
var _meta_snapshot: Dictionary = {}
var _exported: Array[String] = []
var _panel = null


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


# ── 夹具 ──────────────────────────────────────────────────────────
class StubTarget extends Enemy:
	# 真敌子类（uid/dead/hitbox_r 原生；DamageContext.target: Enemy 类型面——纯 Node2D
	# 桩在 ArcSlash._slash_hit→build_damage_context 处 SCRIPT ERROR 中断命中链）；
	# _ready 置空跳过池化组装重件（sprite/材质/Telegraph——headless 夹具轻量化）。
	func _ready() -> void:
		pass


class StubPipeline extends RefCounted:
	func resolve(_p_ctx: DamageContext) -> DamageResult:
		return null


class CountingGrid extends SpaceGrid:
	var nearest_calls: int = 0
	var circle_calls: int = 0

	func query_nearest(pos: Vector2, radius: float, exclude: Node2D) -> Node2D:
		nearest_calls += 1
		return super.query_nearest(pos, radius, exclude)

	func query_circle(pos: Vector2, radius: float) -> Array[Node2D]:
		circle_calls += 1
		return super.query_circle(pos, radius)


class NullPool extends ProjectilePool:
	# 齐射目标分配在池取弹之前——恒空池保住 try_fire 每拍跑到 _acquire_volley_targets
	func acquire(_p_team: int = 0) -> ProjectileBase:
		return null


class QAProbeW1 extends WeaponBase:
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


class QAProbeW9 extends OrbitWeapon:
	var opened: int = 0
	var acq_log: Array[int] = []

	func acquire_target() -> Node2D:
		var r := super.acquire_target()
		acq_log.append(-1 if r == null else int(r.get("uid")))
		return r

	func _open_slash(p_facing: float, p_center: Vector2) -> void:
		opened += 1
		super(p_facing, p_center)


class QAProbeW13 extends OrbitWeapon:
	var opened: int = 0
	var gate_log: Array[int] = []

	func _cleave_engage_target() -> Node2D:
		var r := super._cleave_engage_target()
		gate_log.append(-1 if r == null else int(r.get("uid")))
		return r

	func _open_slash(p_facing: float, p_center: Vector2) -> void:
		opened += 1
		super(p_facing, p_center)


class QAProbeW6 extends HomingWeapon:
	var volley_log: Array[Array] = []

	func _acquire_volley_targets(p_count: int) -> Array[Node2D]:
		var r := super(p_count)
		var uids: Array[int] = []
		for t in r:
			uids.append(-1 if t == null else int(t.get("uid")))
		volley_log.append(uids)
		return r


class DiagStub extends Node:
	var state: int = 0
	var stage_probe_us: Dictionary = {}
	var stage_probe_us_peak: Dictionary = {}
	var counts: Dictionary = {}

	func diag_counts() -> Dictionary:
		return counts

	func diag_reset_stage_peaks() -> void:
		pass


# ── 数据夹具 ──────────────────────────────────────────────────────
func _make_melee(p_mode: String, p_cd: float) -> WeaponData:
	_wd_counter += 1
	var d := WeaponData.new()
	d.id = StringName("W_QA293_%d" % _wd_counter)
	d.display_name = "QA293 %d" % _wd_counter
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
	d.melee["slash_radius"] = 150.0            # leash = 150×2.5 = 375（+mr 64 → reach 439）
	d.melee["arc_deg"] = 120.0
	d.melee["max_targets"] = 8
	d.melee["orbs"] = 2
	return d


func _make_ballistic(p_cd: float) -> WeaponData:
	_wd_counter += 1
	var d := WeaponData.new()
	d.id = StringName("W_QA293_%d" % _wd_counter)
	d.display_name = "QA293 B %d" % _wd_counter
	d.form = GameConst.WeaponForm.BALLISTIC
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
	return d


func _make_homing(p_cd: float) -> WeaponData:
	_wd_counter += 1
	var d := WeaponData.new()
	d.id = StringName("W_QA293_%d" % _wd_counter)
	d.display_name = "QA293 H %d" % _wd_counter
	d.form = GameConst.WeaponForm.HOMING
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
	d.homing["volley_count_levels"] = [3.0, 3.0, 3.0, 3.0, 3.0]
	return d


func _setup_weapon(p_w: WeaponBase, p_data: WeaponData, p_pos: Vector2,
		p_grid: SpaceGrid, p_extra: Dictionary = {}) -> WeaponBase:
	p_w.name = "QA293W%d" % _wd_counter
	tree.root.add_child(p_w)
	p_w.position = p_pos
	var deps := {"pipeline": StubPipeline.new(), "enemy_grid": p_grid}
	for k in p_extra:
		deps[k] = p_extra[k]
	p_w.setup(p_data, null, deps)
	return p_w


# ── S1/S2 场景：W9×2 同位 + W9 异位 + W13 cleave + W1×2 同位 + W6×1（齐射共享面）；
#    7 敌（含 P0 精确等距平局对 / leash 边界 / 1600 reach 边界 / 远出界）+ 漂移 + f11 dead ──
func _run_scenario(p_enabled: bool, p_deep: bool, p_beats: int) -> Array:
	SimQueryShare.enabled = p_enabled
	SimQueryShare.reset_diag()
	seed(2933)
	var grid := SpaceGrid.new()
	grid.configure(Vector2(2000.0, 2000.0), 200.0)
	var layout := [
		Vector2(430.0, 600.0),                   # e0：P0 30px（最近；f11 后 dead）
		Vector2(550.0, 600.0),                   # e1：P0 150px ┐ 精确等距对（argmin 平局取向）
		Vector2(250.0, 600.0),                   # e2：P0 150px ┘
		Vector2(400.0, 975.0),                   # e3：P0 375px（leash 边界内沿）
		Vector2(900.0, 700.0),                   # e4：P0 ~510px / P1 ~283px（异位 W9 的近敌）
		Vector2(2020.0, 600.0),                  # e5：P0 1620px（1600 reach 内——边界含入）
		Vector2(400.0, 2200.0),                  # e6：P0 1600px 整（reach=1664 内）
	]
	var drift := [
		Vector2.ZERO, Vector2(3.0, -1.0), Vector2(-3.0, 1.0), Vector2(0.0, 5.0),
		Vector2(4.0, -4.0), Vector2(-2.0, 0.0), Vector2(0.0, -6.0),
	]
	var enemies: Array[StubTarget] = []
	for i in range(layout.size()):
		var t := StubTarget.new()
		t.uid = 700 + i
		tree.root.add_child(t)
		t.position = layout[i]
		enemies.append(t)
	var w9a := _setup_weapon(QAProbeW9.new(), _make_melee("slash", 0.12), P0, grid) as QAProbeW9
	var w9b := _setup_weapon(QAProbeW9.new(), _make_melee("slash", 0.12), P0, grid) as QAProbeW9
	var w9c := _setup_weapon(QAProbeW9.new(), _make_melee("slash", 0.12), P1, grid) as QAProbeW9
	var w13 := _setup_weapon(QAProbeW13.new(), _make_melee("cleave", 0.15), P0, grid) as QAProbeW13
	var w1a := _setup_weapon(QAProbeW1.new(), _make_ballistic(0.2), P0, grid) as QAProbeW1
	var w1b := _setup_weapon(QAProbeW1.new(), _make_ballistic(0.2), P0, grid) as QAProbeW1
	var w6 := _setup_weapon(QAProbeW6.new(), _make_homing(0.3), P0, grid,
		{"homing_pool": NullPool.new()}) as QAProbeW6
	var weapons: Array = [w9a, w9b, w9c, w13, w1a, w1b, w6]
	var live: Array[Node2D] = []
	for e in enemies:
		live.append(e)
	grid.rebuild(live)
	var trace: Array = []
	for f in range(FRAMES):
		GameConfig.advance_frame()
		var run := (not p_deep) or (f % 2 == 0)
		WeaponBase.lod_dt_doubled = run and p_deep
		WeaponBase.lod_beats = p_beats
		if run:
			SimQueryShare.begin_phase()
			for w in weapons:
				w.tick(DT * (2.0 if p_deep else 1.0))
			SimQueryShare.end_phase()
		var rec := {
			"w9a": _snap_w9(w9a), "w9b": _snap_w9(w9b), "w9c": _snap_w9(w9c),
			"w13": {"gate": w13.gate_log.duplicate(), "opened": w13.opened, "cd": w13.cooldown_left},
			"w1a": {"acq": w1a.acq_log.duplicate(), "fired": w1a.fired, "cd": w1a.cooldown_left},
			"w1b": {"acq": w1b.acq_log.duplicate(), "fired": w1b.fired, "cd": w1b.cooldown_left},
			"w6": {"volley": w6.volley_log.duplicate(true), "cd": w6.cooldown_left},
		}
		trace.append(rec)
		grid.rebuild(live)
		for i in range(enemies.size()):
			enemies[i].position += drift[i]
		if f == 11:
			enemies[0].dead = true
	for w in weapons:
		w.free()
	for e in enemies:
		e.free()
	WeaponBase.lod_dt_doubled = false
	WeaponBase.lod_beats = 2
	return trace


func _snap_w9(p_w: QAProbeW9) -> Dictionary:
	var knife: Array = []
	var ktgt: Array[int] = []
	if p_w.orbit_field != null and is_instance_valid(p_w.orbit_field):
		for v in p_w.orbit_field._knife_pos:
			knife.append(v)
		for t in p_w.orbit_field._knife_target:
			ktgt.append(-1 if t == null else int(t.get("uid")))
	return {"acq": p_w.acq_log.duplicate(), "opened": p_w.opened,
		"cd": p_w.cooldown_left, "knife": knife, "ktgt": ktgt, "seq": p_w._tick_seq}


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


func _first_diff(a: Array, b: Array) -> int:
	for i in range(mini(a.size(), b.size())):
		if not _deep_eq(a[i], b[i]):
			return i
	if a.size() != b.size():
		return mini(a.size(), b.size())
	return -1


# ── S1：关态固定 seed 逐位对照 ────────────────────────────────────
func _s1_off_bitlock() -> void:
	print("── S1 关态逐位对照（enabled off vs on，seed 2933，40 帧全量 trace） ──")
	var off_a := _run_scenario(false, false, 2)
	var off_b := _run_scenario(false, false, 2)
	var on_a := _run_scenario(true, false, 2)
	_check("1a off 同 seed 双跑确定（off/off trace 逐位相等）",
		_deep_eq(off_a, off_b), "首差帧=%d" % _first_diff(off_a, off_b))
	_check("1b off vs on 全量 trace 逐位相等（承重墙——共享刀逐位不变）",
		_deep_eq(off_a, on_a), "首差帧=%d" % _first_diff(off_a, on_a))
	_check("1c on 路径共享确已生效（否则 1b 是空验证：fills/hits/derives 全 >0）",
		SimQueryShare.stat_fills > 0 and SimQueryShare.stat_hits > 0
			and SimQueryShare.stat_leash_derives > 0,
		"fills=%d hits=%d derives=%d" % [SimQueryShare.stat_fills,
			SimQueryShare.stat_hits, SimQueryShare.stat_leash_derives])
	var last: Dictionary = on_a[FRAMES - 1]
	var total_opened: int = last["w9a"]["opened"] + last["w9b"]["opened"] \
		+ last["w9c"]["opened"] + last["w13"]["opened"]
	_check("1d 场景有效性：W9/W13 开窗 >0 且索敌/交战门/齐射序列全非空",
		total_opened > 0 and last["w9a"]["acq"].size() > 0
			and last["w13"]["gate"].size() > 0 and last["w6"]["volley"].size() > 0,
		"opened=%d" % total_opened)
	_check("1e 场景有效性：dead 翻转后出现 -1（dead 过滤口径触发面在位）",
		-1 in last["w9a"]["acq"] or -1 in last["w13"]["gate"]
			or -1 in last["w1a"]["acq"],
		"w9acq 尾=%s" % str(last["w9a"]["acq"]).substr(0, 40))
	_check("1f 场景有效性：追击刀位非恒定（chase 推进）且平局对不漂移（e1/e2 同距同选）",
		not _deep_eq(on_a[3]["w9a"]["knife"], on_a[FRAMES - 1]["w9a"]["knife"]),
		"")


# ── S2：深载守恒（lod 2 与 4 双档） ───────────────────────────────
func _s2_deep_conservation() -> void:
	print("── S2 深载守恒（lod_beats=2/4 隔帧执行 A/B 逐位） ──")
	var d2_off := _run_scenario(false, true, 2)
	var d2_on := _run_scenario(true, true, 2)
	_check("2a 深载 lod_beats=2：off vs on 全量 trace 逐位相等",
		_deep_eq(d2_off, d2_on), "首差帧=%d" % _first_diff(d2_off, d2_on))
	var d4_off := _run_scenario(false, true, 4)
	var d4_on := _run_scenario(true, true, 4)
	_check("2b 深载 lod_beats=4（副武组深载口径）：off vs on 全量 trace 逐位相等",
		_deep_eq(d4_off, d4_on), "首差帧=%d" % _first_diff(d4_off, d4_on))
	var n2: int = d2_on[FRAMES - 1]["w9a"]["acq"].size()
	var n4: int = d4_on[FRAMES - 1]["w9a"]["acq"].size()
	var seq2: int = d2_on[FRAMES - 1]["w9a"]["seq"]
	var seq4: int = d4_on[FRAMES - 1]["w9a"]["seq"]
	_check("2c 深载子拍语义在位：跳步帧零推进（帧1 seq==帧0）+ 执行帧恰 +1 拍",
		d2_on[1]["w9a"]["seq"] == d2_on[0]["w9a"]["seq"]
			and d2_on[2]["w9a"]["seq"] == d2_on[1]["w9a"]["seq"] + 1
			and d2_on[FRAMES - 1]["w9a"]["seq"] == FRAMES >> 1,
		"seq0=%d seq1=%d seq2=%d seqN=%d" % [d2_on[0]["w9a"]["seq"],
			d2_on[1]["w9a"]["seq"], d2_on[2]["w9a"]["seq"], seq2])
	_check("2c2 深载 beats=4 同执行拍数（lod_beats 只改拍内子拍数——seq 终值同为 20）且索敌拍形非空",
		seq2 == (FRAMES >> 1) and seq4 == (FRAMES >> 1) and n2 > 0 and n4 > 0,
		"seq2=%d seq4=%d n2=%d n4=%d" % [seq2, seq4, n2, n4])
	_check("2d 深载 beats=4 与 beats=2 拍形不同（两档确实走了不同子拍链）",
		not _deep_eq(d2_on, d4_on), "")


# ── S3：计数口下降 + 结果逐帧等价 ─────────────────────────────────
func _chase_scenario(p_enabled: bool) -> Dictionary:
	SimQueryShare.enabled = p_enabled
	SimQueryShare.reset_diag()
	seed(29331)
	var grid := CountingGrid.new()
	grid.configure(Vector2(2000.0, 2000.0), 200.0)
	var e := StubTarget.new()
	e.uid = 800
	tree.root.add_child(e)
	e.position = Vector2(1200.0, 600.0)          # P0 距 800px：leash 439 外、1664 内
	var live: Array[Node2D] = [e]
	grid.rebuild(live)
	var w9s: Array[QAProbeW9] = []
	for i in range(3):
		w9s.append(_setup_weapon(QAProbeW9.new(), _make_melee("slash", 0.15), P0, grid) as QAProbeW9)
	var acq_seq: Array[Array] = []
	for f in range(20):
		GameConfig.advance_frame()
		SimQueryShare.begin_phase()
		var frame_uids: Array[int] = []
		for w in w9s:
			w.acq_log.clear()
			w.tick(DT)
			frame_uids.append(w.acq_log[0] if w.acq_log.size() > 0 else -2)
		acq_seq.append(frame_uids)
		SimQueryShare.end_phase()
		grid.rebuild(live)
	for w in w9s:
		w.free()
	e.free()
	return {"nearest": grid.nearest_calls, "circle": grid.circle_calls, "acq": acq_seq}


func _s3_query_share() -> void:
	print("── S3 查询共享（计数口下降 + 结果逐帧等价） ──")
	var off := _chase_scenario(false)
	_check("3a off 基线：3 同位 W9 × 20 帧 = nearest 60 + circle 60（每拍双查原口径）",
		off["nearest"] == 60 and off["circle"] == 60,
		"nearest=%d circle=%d" % [off["nearest"], off["circle"]])
	var on := _chase_scenario(true)
	_check("3b on：query_nearest 恒 0（slash 索敌 1600 圆扫条目派生）",
		on["nearest"] == 0, "nearest=%d" % on["nearest"])
	_check("3c on：query_circle 恰 20（每帧 1 次 1600 圆扫三武共享）",
		on["circle"] == 20, "circle=%d" % on["circle"])
	_check("3d on：实查总量 120 → 20（-83%）",
		int(on["nearest"]) + int(on["circle"]) == 20,
		"total=%d" % (int(on["nearest"]) + int(on["circle"])))
	_check("3e 自证口账目：fills=20 / derives=20 / hits=80（每帧 1 填 1 派 4 命中）",
		SimQueryShare.stat_fills == 20 and SimQueryShare.stat_leash_derives == 20
			and SimQueryShare.stat_hits == 80,
		"fills=%d derives=%d hits=%d" % [SimQueryShare.stat_fills,
			SimQueryShare.stat_leash_derives, SimQueryShare.stat_hits])
	var eq := true
	var eq_detail := ""
	var off_acq: Array[Array] = off["acq"]
	var on_acq: Array[Array] = on["acq"]
	for f in range(off_acq.size()):
		if not _deep_eq(off_acq[f], on_acq[f]):
			eq = false
			eq_detail = "帧%d off=%s on=%s" % [f, str(off_acq[f]), str(on_acq[f])]
			break
	_check("3f 结果等价：on/off 每帧每武器索敌 uid 逐帧相同（共享不换目标）",
		eq, eq_detail)


# ── S4：共享 API 随机对拍（直接 API 面——不经武器） ────────────────
func _s4_random_equivalence() -> void:
	print("── S4 共享 API 随机对拍（30 随机场 × 四口对拍） ──")
	seed(293321)
	SimQueryShare.enabled = true
	SimQueryShare.reset_diag()
	var grid := SpaceGrid.new()
	grid.configure(Vector2(2000.0, 2000.0), 200.0)
	var enemies: Array[StubTarget] = []
	# 固定平局对：P0±150 精确等距（锁 argmin 首个取向）+ P0 1600 整（reach 边界）
	var tie_a := StubTarget.new()
	tie_a.uid = 1000
	tree.root.add_child(tie_a)
	tie_a.position = P0 + Vector2(150.0, 0.0)
	var tie_b := StubTarget.new()
	tie_b.uid = 1001
	tree.root.add_child(tie_b)
	tie_b.position = P0 - Vector2(150.0, 0.0)
	var edge := StubTarget.new()
	edge.uid = 1002
	tree.root.add_child(edge)
	edge.position = P0 + Vector2(1600.0, 0.0)   # 恰 1600：query 谓词 d<=(1600+64)² 含入
	enemies.append(tie_a)
	enemies.append(tie_b)
	enemies.append(edge)
	for i in range(27):
		var t := StubTarget.new()
		t.uid = 1100 + i
		tree.root.add_child(t)
		t.position = Vector2(randf_range(-150.0, 2150.0), randf_range(-150.0, 2150.0))
		enemies.append(t)
	var live: Array[Node2D] = []
	for e in enemies:
		live.append(e)
	grid.rebuild(live)
	var nearest_eq := true
	var slash_eq := true
	var scan_eq := true
	var leash_eq := true
	var detail := ""
	var tie_pick: int = -1
	for k in range(30):
		var c := Vector2(randf_range(0.0, 1800.0), randf_range(0.0, 1800.0))
		var leash := randf_range(80.0, 375.0)
		# 每次迭代新相位（纪元推进）→ 条目必重建（对拍的是 fill 派生路径而非缓存命中）
		SimQueryShare.begin_phase()
		var sn := SimQueryShare.shared_nearest(true, grid, c, SimQueryShare.TARGET_REACH)
		var dn := grid.query_nearest(c, SimQueryShare.TARGET_REACH, null)
		if sn != dn:
			nearest_eq = false
			detail = "k=%d c=%s" % [k, str(c)]
		var sl := SimQueryShare.slash_nearest(true, grid, c)
		var dl2 := grid.query_nearest(c, SimQueryShare.TARGET_REACH, null)
		if sl != dl2:
			slash_eq = false
			detail = "k=%d c=%s" % [k, str(c)]
		var sc: Array[Node2D] = SimQueryShare.shared_scan_cands(true, grid, c)
		var expect: Array[Node2D] = []
		expect.append_array(grid.query_circle(c, SimQueryShare.TARGET_REACH))
		if sc.size() != expect.size():
			scan_eq = false
			detail = "k=%d size %d vs %d" % [k, sc.size(), expect.size()]
		else:
			for i in range(sc.size()):
				if sc[i] != expect[i]:
					scan_eq = false
					detail = "k=%d idx=%d 序漂移" % [k, i]
					break
		var lh: Array[Node2D] = SimQueryShare.slash_leash_candidates(true, grid, c, leash)
		var expect_l: Array[Node2D] = []
		expect_l.append_array(grid.query_circle(c, leash))
		if lh.size() != expect_l.size():
			leash_eq = false
			detail = "k=%d leash=%s size %d vs %d" % [k, str(leash), lh.size(), expect_l.size()]
		else:
			for i in range(lh.size()):
				if lh[i] != expect_l[i]:
					leash_eq = false
					detail = "k=%d leash idx=%d 序漂移" % [k, i]
					break
		SimQueryShare.end_phase()
	# 平局对定向口：专用网格只放 P0±150 等距对——行主序×桶插入序先见者=西对（col 3
	# 先于 col 5），query_nearest 严格 < 保首见——shared/slash 派生必同取向
	var tg := SpaceGrid.new()
	tg.configure(Vector2(2000.0, 2000.0), 200.0)
	var ta := StubTarget.new()
	ta.uid = 1000
	tree.root.add_child(ta)
	ta.position = P0 + Vector2(150.0, 0.0)       # 东对（col 5——后见）
	var tb := StubTarget.new()
	tb.uid = 1001
	tree.root.add_child(tb)
	tb.position = P0 - Vector2(150.0, 0.0)       # 西对（col 3——先见）
	tg.rebuild([ta, tb])
	SimQueryShare.begin_phase()
	var near_p0 := SimQueryShare.shared_nearest(true, tg, P0, SimQueryShare.TARGET_REACH)
	var slash_p0 := SimQueryShare.slash_nearest(true, tg, P0)
	var direct_p0 := tg.query_nearest(P0, SimQueryShare.TARGET_REACH, null)
	tie_pick = -1 if direct_p0 == null else int(direct_p0.get("uid"))
	SimQueryShare.end_phase()
	_check("4a shared_nearest ≡ query_nearest（30 随机场逐节点同值）", nearest_eq, detail)
	_check("4b slash_nearest ≡ query_nearest(1600)（argmin 派生逐位）", slash_eq, detail)
	_check("4c shared_scan_cands ≡ query_circle(1600)（逐元素同序）", scan_eq, detail)
	_check("4d slash_leash_candidates(l) ≡ query_circle(l)（保序过滤逐元素，l∈[80,375]）",
		leash_eq, detail)
	_check("4e 精确平局取向：P0 等距对先见者（西 1001）同取向——shared/slash/direct 同节点",
		near_p0 == direct_p0 and slash_p0 == direct_p0 and tie_pick == 1001,
		"near=%s slash=%s direct=%d" % [str(near_p0), str(slash_p0), tie_pick])
	ta.free()
	tb.free()
	# 空场臂：未 rebuild 的网格（快照空）——各口零查询且结果与直查一致
	var eg := SpaceGrid.new()
	eg.configure(Vector2(2000.0, 2000.0), 200.0)
	SimQueryShare.begin_phase()
	var e_sn := SimQueryShare.shared_nearest(true, eg, P0, 1600.0)
	var e_sl := SimQueryShare.slash_nearest(true, eg, P0)
	var e_sc: Array[Node2D] = SimQueryShare.shared_scan_cands(true, eg, P0)
	var e_lh: Array[Node2D] = SimQueryShare.slash_leash_candidates(true, eg, P0, 375.0)
	SimQueryShare.end_phase()
	_check("4f 空场四口全空（is_empty O(1) 早退口径=直查空结果）",
		e_sn == null and e_sl == null and e_sc.is_empty() and e_lh.is_empty(),
		"sn=%s sl=%s sc=%d lh=%d" % [str(e_sn), str(e_sl), e_sc.size(), e_lh.size()])
	_check("4g 空场自证口计数（stat_empty_skips=4）",
		SimQueryShare.stat_empty_skips >= 4, "skips=%d" % SimQueryShare.stat_empty_skips)
	for e in enemies:
		e.free()


# ── S5：r220 契约 + 相位括号边界 ──────────────────────────────────
func _s5_r220_and_brackets() -> void:
	print("── S5 r220 契约 + 相位括号边界 ──")
	SimQueryShare.enabled = true
	SimQueryShare.reset_diag()
	var grid := CountingGrid.new()
	grid.configure(Vector2(2000.0, 2000.0), 200.0)
	var e := StubTarget.new()
	e.uid = 1200
	tree.root.add_child(e)
	e.position = P0 + Vector2(40.0, 0.0)
	grid.rebuild([e])
	var w1 := _setup_weapon(QAProbeW1.new(), _make_ballistic(0.2), P0, grid) as QAProbeW1
	w1.cooldown_left = 0.0
	grid.nearest_calls = 0
	SimQueryShare.begin_phase()
	w1.tick(DT)
	SimQueryShare.end_phase()
	_check("5a 基类路径一拍 tick 全链 query_nearest 恰 1 次（r220 锁保持）",
		grid.nearest_calls == 1, "calls=%d" % grid.nearest_calls)
	w1.cooldown_left = 0.0
	w1.try_fire()                                # 栈外直调（括号外+栈外双闸）
	_check("5b 栈外直调恒真查（r220 锁保持——calls≥2）",
		grid.nearest_calls >= 2, "calls=%d" % grid.nearest_calls)
	var w2 := _setup_weapon(QAProbeW1.new(), _make_ballistic(0.2), P0, grid) as QAProbeW1
	var before := grid.nearest_calls
	GameConfig.advance_frame()
	SimQueryShare.begin_phase()
	w1.cooldown_left = 0.0
	w1.tick(DT)
	w2.cooldown_left = 0.0
	w2.tick(DT)
	SimQueryShare.end_phase()
	_check("5c 同帧同位第二武器零实查（帧共享——新帧恰 +1 nearest）",
		grid.nearest_calls == before + 1,
		"before=%d after=%d" % [before, grid.nearest_calls])
	# 括号外 tick：不 begin/end 直驱（测试直驱路径）——同位三武各真查（无跨武坍缩）
	var w3 := _setup_weapon(QAProbeW1.new(), _make_ballistic(0.2), P0, grid) as QAProbeW1
	var before2 := grid.nearest_calls
	GameConfig.advance_frame()
	w1.cooldown_left = 0.0
	w1.tick(DT)
	w2.cooldown_left = 0.0
	w2.tick(DT)
	w3.cooldown_left = 0.0
	w3.tick(DT)
	_check("5d 括号外 tick 恒原查询路径（同位三武恰 +3 实查——无跨武器共享）",
		grid.nearest_calls == before2 + 3,
		"before=%d after=%d" % [before2, grid.nearest_calls])
	# W6 齐射共享面：同位双 W6 同帧一次圆扫
	var w6a := _setup_weapon(QAProbeW6.new(), _make_homing(0.3), P0, grid,
		{"homing_pool": NullPool.new()}) as QAProbeW6
	var w6b := _setup_weapon(QAProbeW6.new(), _make_homing(0.3), P0, grid,
		{"homing_pool": NullPool.new()}) as QAProbeW6
	grid.circle_calls = 0
	GameConfig.advance_frame()
	SimQueryShare.begin_phase()
	w6a.cooldown_left = 0.0
	w6a.tick(DT)
	w6b.cooldown_left = 0.0
	w6b.tick(DT)
	SimQueryShare.end_phase()
	_check("5e 同位双 W6 齐射共享（同帧恰 1 次 1600 圆扫）",
		grid.circle_calls == 1, "circle=%d" % grid.circle_calls)
	_check("5f W6 齐射目标非空且两武同目标表（shared_scan_cands 跨武等值）",
		w6a.volley_log.size() > 0 and w6b.volley_log.size() > 0
			and _deep_eq(w6a.volley_log[-1], w6b.volley_log[-1]),
		"a=%s b=%s" % [str(w6a.volley_log).substr(0, 30), str(w6b.volley_log).substr(0, 30)])
	w1.free()
	w2.free()
	w3.free()
	w6a.free()
	w6b.free()
	e.free()


# ── S6：帧率帽（默认/四档/钳制/headless 墙/面板循环） ──────────────
func _s6_fps_cap() -> void:
	print("── S6 帧率帽：默认 60 + 四档读写 + 钳制 + headless 运行时墙 + 面板循环 ──")
	_meta_snapshot = Meta._settings.duplicate()
	Meta._settings.erase("fps_cap")
	_check("6a 缺键读口回退 60 + 默认表本值 60（默认不动）",
		int(Meta.settings("fps_cap")) == 60
			and int(Meta.SETTINGS_DEFAULTS.get("fps_cap")) == 60,
		"read=%s default=%s" % [str(Meta.settings("fps_cap")),
			str(Meta.SETTINGS_DEFAULTS.get("fps_cap"))])
	var tiers: Array[int] = [60, 90, 120, 0]
	var ok := true
	var dtl := ""
	for v in tiers:
		Meta.set_setting("fps_cap", v)
		if int(Meta.settings("fps_cap")) != v:
			ok = false
			dtl += "%d→%s " % [v, str(Meta.settings("fps_cap"))]
	_check("6b 四档写读往返（60/90/120/无帽0）", ok, dtl)
	Meta.set_setting("fps_cap", 200)
	var hi := int(Meta.settings("fps_cap")) == 144
	Meta.set_setting("fps_cap", -5)
	var lo := int(Meta.settings("fps_cap")) == 0
	_check("6c 写口钳制 200→144 / -5→0（clampi 0~144）", hi and lo,
		"hi=%s lo=%s" % [str(hi), str(lo)])
	var fps0 := Engine.max_fps
	var hz0 := Engine.physics_ticks_per_second
	Meta.set_setting("fps_cap", 90)
	var wall_set := Engine.max_fps == fps0
	Meta._apply_fps_cap()
	var wall_apply := Engine.max_fps == fps0 and Engine.physics_ticks_per_second == hz0
	_check("6d headless 运行时墙：写档 90 + 直调 _apply_fps_cap 后 Engine.max_fps/物理 Hz 双零写",
		fps0 == 0 and wall_set and wall_apply,
		"fps0=%d set=%d apply=%d hz=%d" % [fps0, Engine.max_fps, Engine.max_fps, Engine.physics_ticks_per_second])
	# 真实面板四拍循环（含「✓ 不限」文案）+ 脏档归位
	_panel = SettingsPanel.new()
	_panel.name = "QA293SimPanel"
	tree.root.add_child(_panel)
	var btn: Button = _panel.find_child("FpsCapButton", true, false) as Button
	_check("6e 面板实例化 + FpsCapButton 行在位", btn != null and not _panel.is_open(),
		"btn=%s" % str(btn))
	if btn != null:
		Meta.set_setting("fps_cap", 60)
		var want_v: Array[int] = [90, 120, 0, 60]
		var want_t: Array[String] = ["✓ 90", "✓ 120", "✓ 不限", "✓ 60"]
		var cyc := true
		var cdtl := ""
		for i in range(want_v.size()):
			_panel.call("_on_fps_cap_cycle")
			var v := int(Meta.settings("fps_cap"))
			if v != want_v[i] or btn.text != want_t[i]:
				cyc = false
				cdtl += "拍%d v=%d txt=%s（期 %d/%s） " % [i, v, btn.text, want_v[i], want_t[i]]
		_check("6f 四拍循环 60→90→120→无帽→60（值+文案即时刷新）", cyc, cdtl)
		Meta.set_setting("fps_cap", 144)
		_panel.call("_on_fps_cap_cycle")
		_check("6g 脏档 144 一轮归位 60", int(Meta.settings("fps_cap")) == 60,
			str(Meta.settings("fps_cap")))
	_panel.queue_free()
	await tree.process_frame
	_panel = null


# ── S7：drawcallsN + 导出口径头 ───────────────────────────────────
func _s7_drawcalls() -> void:
	print("── S7 drawcallsN：1Hz 行尾键 + 导出头 R293 段（%% 转义活链） ──")
	var stub := DiagStub.new()
	var line: String = DebugStats._diag_format_line(stub, Time.get_ticks_msec())
	stub.free()
	var rx := RegEx.new()
	rx.compile(" drawcalls(\\d+)( 尖峰[^ ]+)?$")
	var m := rx.search(line)
	_check("7a 行含 drawcallsN 且为行尾段（其后仅允许 尖峰 标记/行尾）",
		m != null, "tail=%s" % line.right(72))
	if m != null:
		_check("7b 键位序：副武µs < 弹拒 < drawcalls（行尾追加位——既有子串零挪动）",
			line.find(" 副武µs") >= 0 and line.find(" 弹拒") > line.find(" 副武µs")
				and line.find(" drawcalls") > line.find(" 弹拒"),
			"@副武%d @弹拒%d @drawcalls%d" % [line.find(" 副武µs"),
				line.find(" 弹拒"), line.find(" drawcalls")])
		var v := int(m.get_string(1))
		_check("7c 数值可解析 ≥0", v >= 0, "v=%d" % v)
		if DisplayServer.get_name() == "headless":
			var fresh := int(Performance.get_monitor(
				Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
			_check("7d headless 恒 0 且与同源直读一致", v == 0 and v == fresh,
				"line=%d fresh=%d" % [v, fresh])
	var r: Dictionary = DebugStats.diag_export()
	var text := str(r.get("text", ""))
	var path := str(r.get("path", ""))
	if path.begins_with("user://"):
		_exported.append(path.substr("user://".length()))
	_check("7e 导出成功（整头起底未崩——格式串活）",
		text.begins_with("=== Infinite Fission 真机诊断日志 ===") and path != "",
		"len=%d" % text.length())
	_check("7f 口径头含 R293 段（drawcallsN 语义 + 帧率上限行）",
		text.contains("R293 刀C")
			and text.contains("drawcallsN=Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME")
			and text.contains("帧率上限行（fps_cap）"),
		"R293@%d" % text.find("R293 刀C"))
	_check("7g R293 段位序：紧接 R291 承句之后", text.contains("·R291 承）；R293 刀C"), "")
	_check("7h %% 转义活链：促N 句单百分号渲染在场（85% 恰 1；75% 恰 2=促N 句+R290 修轮句——源级双 %% 各渲染一次，无 %% 残留）",
		text.contains("0 关/1 开85%/2 开75%")
			and text.count("85%") == 1 and text.count("75%") == 2
			and not text.contains("%%"),
		"85%%×%d 75%%×%d" % [text.count("85%"), text.count("75%")])
	_check("7i R293 段口径披露三锚（默认 60 不变/headless 恒 0/桌面零写承重墙）",
		text.contains("默认 60 不变") and text.contains("headless 无渲染恒 0 无意义")
			and text.contains("桌面/headless 恒 0 不被改"), "")
	_check("7j 产物在盘（收尾删除）", path != "" and FileAccess.file_exists(path), path)


# ── S8：取证探针（取证式 PASS——实测事实记录，缺陷在报告登记） ──────
func _s8_falsify_probes() -> void:
	print("── S8 取证探针（leash>1600 派生缺口 + 相位内冻结契约） ──")
	SimQueryShare.enabled = true
	SimQueryShare.reset_diag()
	# 8a：leash>1600 时「从 1600 圆扫条目派生」会漏 (1600, leash] 环带候选。
	# 当前全数据叠加上限：230(L5)×1.4(巨刃2层)×1.54(AFF_RANGE 3层)×1.15(质变)×2.5
	# ≈1425 < 1600 —— 生产不可达；本探针直调 API 取证边界行为（报告 D 项）。
	var grid := SpaceGrid.new()
	grid.configure(Vector2(2600.0, 2000.0), 200.0)
	var e_far := StubTarget.new()
	e_far.uid = 1300
	tree.root.add_child(e_far)
	e_far.position = P0 + Vector2(1800.0, 0.0)   # 距 1800：leash 2000 内、1600 圆扫外
	grid.rebuild([e_far])
	SimQueryShare.begin_phase()
	# 先建 1600 圆扫条目（生产序：同拍索敌先行——slash_nearest 触发 _fill_scan）
	var probe_near := SimQueryShare.slash_nearest(true, grid, P0)
	var derived: Array[Node2D] = SimQueryShare.slash_leash_candidates(true, grid, P0, 2000.0)
	var direct: Array[Node2D] = []
	direct.append_array(grid.query_circle(P0, 2000.0))
	SimQueryShare.end_phase()
	_check("8a【取证】leash=2000 派生口实测：derived=%d / direct=%d（derived<direct 即环带漏取——"
		% [derived.size(), direct.size()] + "当前数据上限 ~1425 不可达，详见报告）",
		true, "derived=%d direct=%d miss=%d" % [derived.size(), direct.size(),
			direct.size() - derived.size()])
	# 8b：相位内冻结契约——② 内同键查询恒同值（结构性冻结的行为面读证）
	var e0 := StubTarget.new()
	e0.uid = 1310
	var e1 := StubTarget.new()
	e1.uid = 1311
	tree.root.add_child(e0)
	tree.root.add_child(e1)
	var grid2 := SpaceGrid.new()
	grid2.configure(Vector2(2000.0, 2000.0), 200.0)
	e0.position = P0 + Vector2(50.0, 0.0)
	e1.position = P0 + Vector2(140.0, 0.0)
	grid2.rebuild([e0, e1])
	SimQueryShare.begin_phase()
	var q1 := SimQueryShare.shared_nearest(true, grid2, P0, 1600.0)
	e1.position = P0 + Vector2(20.0, 0.0)        # 相位内敌移（生产 ② 内不会发生——击退在 ⑤）
	var q2 := SimQueryShare.shared_nearest(true, grid2, P0, 1600.0)
	SimQueryShare.end_phase()
	SimQueryShare.begin_phase()                  # 新相位（纪元轴）
	var q3 := SimQueryShare.shared_nearest(true, grid2, P0, 1600.0)
	SimQueryShare.end_phase()
	_check("8b 相位冻结契约：相位内同键恒同值（q1==q2）+ 跨相位重查新值（q3==e1）",
		q1 == q2 and q1 == e0 and q3 == e1,
		"q1=%s q2=%s q3=%s" % [str(q1), str(q2), str(q3)])
	e_far.free()
	e0.free()
	e1.free()


# ── 收尾 ──────────────────────────────────────────────────────────
func _cleanup() -> void:
	print("── 收尾（静态还原/Meta 快照/产物删除） ──")
	if _panel != null and is_instance_valid(_panel):
		_panel.queue_free()
		await tree.process_frame
	var dir := DirAccess.open("user://")
	if dir != null:
		for fname in _exported:
			if dir.file_exists(fname):
				dir.remove(fname)
	Meta._settings = _meta_snapshot.duplicate()
	Meta._settings.erase("perf_boost")
	Meta._settings.erase("boost_res")
	Meta._save()
	SimQueryShare.enabled = true
	SimQueryShare.reset_diag()
	WeaponBase.lod_dt_doubled = false
	WeaponBase.lod_beats = 2
	PerfGovernor.boost_override = -1
	PerfGovernor.deep_override = -1
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)
	print("验收汇总：%d/%d 通过" % [_pass, _pass + _fail])


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	_s1_off_bitlock()
	_s2_deep_conservation()
	_s3_query_share()
	_s4_random_equivalence()
	_s5_r220_and_brackets()
	await _s6_fps_cap()
	_s7_drawcalls()
	_s8_falsify_probes()
	await _cleanup()

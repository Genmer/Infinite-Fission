# tests/qa_r291_indep_accept_cases.gd
# R291 独立 QA 验收探针用例体。契约来源 = 验收依据 1-6（UI 定格 + 峰值四刀）：
#   点1 UI 定格：boost∧用户85∧deep∧PLAYING → 画布定格 612×1088/.85/促1；deep 切换零写；
#       用户手选 75 → 540×960/促2（手选语义在）。
#   点2 副武四分频：deep 下 40 物理步 → 主武器 20 次 dt×2 / 副武 10 次 dt×4、
#       lod_beats 主=2 副=4；40 步模拟时间守恒（副武累计 dt=40/60）；关态逐位（每步 dt 原值）。
#   点3 W9 命中帽：真 SpaceGrid + 10 活敌扇内，max_targets=8 → deep 单窗命中 4 / 关态 8。
#   点4 W9 消弹半频：deep 下 _nullify_due 恰半真；_nullify_fold p=0.25→0.4375；
#       p=1.0→1.0（W9 nullify 恒 1.0 折算不变）；关态恒真/原值。
#   点5 拖尾深载门：trail_halffreq_override=1 下 1/60×8 拍 → deep 通过 2 次（1/15s 门）/
#       关态 4 次（1/30s 门）。
#   点6 关态零位移：deep_override=0 → 上述各门全回原值；lod_beats 复位 2。
# 夹具：main.tscn 真链 boot 后冻结引擎自动 process，全部直驱；结束还原。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const DT := 1.0 / 60.0


# 主武器槽桩：计数 + dt 累计 + 捕获当拍 lod_beats（WeaponBase 子类保证槽位类型兼容）
class StubWeapon extends WeaponBase:
	var calls: int = 0
	var acc: float = 0.0
	var beats_seen: Array[int] = []

	func tick(p_game_delta: float) -> void:
		calls += 1
		acc += p_game_delta
		beats_seen.append(WeaponBase.lod_beats)


# 副武组桩（副本数组强类型 Array[WeaponBase]——同基类保类型兼容；镜像鸭子协议 tick 亦满足）
class StubSub extends WeaponBase:
	var calls: int = 0
	var acc: float = 0.0
	var beats_seen: Array[int] = []

	func tick(p_game_delta: float) -> void:
		calls += 1
		acc += p_game_delta
		beats_seen.append(WeaponBase.lod_beats)


# W9 判定宿主桩：真实 WeaponBase（trait_stack null 走跳过臂），命中管线三口全桩化零副作用
class StubJudgeHost extends WeaponBase:
	var hits: int = 0

	func build_damage_context(_p_target: Node2D) -> DamageContext:
		hits += 1
		var ctx := DamageContext.new()
		ctx.base_atk = 1.0
		return ctx

	func inject_vuln_pool(_p_ctx: DamageContext, _p_target: Node2D) -> void:
		pass

	func _element_pool() -> Array[int]:
		var pool: Array[int] = []
		return pool


# 判定目标桩：扇形候选（uid/dead 协议 + 树外 position 语义）
class StubTarget extends Node2D:
	var uid: int = 0
	var dead: bool = false


var tree: SceneTree
var _gl: Node = null
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _saved_settings: Dictionary = {}
var _saved_first_met: Dictionary = {}
var _saved_codex_weapons: Dictionary = {}
var _saved_css: Vector2i = Vector2i.ZERO
var _saved_zoom: Vector2 = Vector2.ONE
var _saved_notch: int = 0
var _saved_snotch: int = 0
var _slot0_backup: Variant = null
var _copies_backup: Array = []
var _stub: StubWeapon = null
var _sub: StubSub = null


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
	seed(291)
	_saved_settings = Meta._settings.duplicate()
	_saved_first_met = Meta.codex_first_met.duplicate()
	_saved_codex_weapons = Meta.codex_weapons.duplicate()
	await _boot()
	PerfGovernor.set_process(false)
	PerfGovernor.mode_override = -1
	PerfGovernor.tier_override = 3
	PerfGovernor.boost_override = 1
	PerfGovernor.deep_override = -1
	PerfGovernor.set_deep_active(false)
	Meta.set_setting("fx_quality", 2)
	Meta.set_setting("boost_res", 85)
	Meta.set_setting("perf_boost", 1)
	_gl.state = GameConst.GameStatus.PLAYING
	_gl.player.set("_dead", false)
	tree.paused = false
	_saved_css = _gl.get_window().content_scale_size
	_saved_zoom = _gl.camera.zoom if _gl.camera != null else Vector2.ONE
	_saved_notch = int(_gl._boost_applied_notch)
	_saved_snotch = GameLoop._s_boost_applied_notch
	_p1_ui_pin()
	_p2_sub_quarter()
	_p3_w9_hit_cap()
	_p4_nullify_halffreq()
	_p5_trail_gate()
	_p6_off_zero_drift()
	await _cleanup()


func _boot() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate()
	_gl.name = "R291IndepAccept"
	tree.root.add_child(_gl)
	await tree.process_frame
	await tree.process_frame
	if not bool(_gl.get("boot_ready")):
		_check("boot 成功（main.tscn 真链）", false, str(_gl.get("boot_fatal")))
	else:
		_check("boot 成功（main.tscn 真链）", true, "")
	_gl.set_physics_process(false)
	_gl.set_process(false)


# ── 点1：UI 定格（R291 刀1——深载不再改画布） ─────────────────────
func _p1_ui_pin() -> void:
	print("── 点1 UI 定格（deep 不改画布 / 用户档恒定 / 手选 75 语义在） ──")
	var win := _gl.get_window()
	PerfGovernor.deep_override = 0
	_gl._apply_boost_resolution()
	var css0 := win.content_scale_size
	var zoom0: Vector2 = _gl.camera.zoom
	var notch0 := int(_gl._boost_applied_notch)
	PerfGovernor.deep_override = 1
	_gl._apply_boost_resolution()
	_check("1a deep 0→1（PLAYING）→ 画布零写（css/zoom/notch 前后相等）",
		win.content_scale_size == css0 and _gl.camera.zoom.is_equal_approx(zoom0) \
			and int(_gl._boost_applied_notch) == notch0,
		"css=%s->%s notch=%d->%d" % [str(css0), str(win.content_scale_size),
			notch0, int(_gl._boost_applied_notch)])
	_check("1b deep 开 → 促键 1（用户档真值，非 2）",
		PerfGovernor.boost_diag_state() == 1, str(PerfGovernor.boost_diag_state()))
	_check("1c deep 开 → boost_world_div 用户档 .85",
		is_equal_approx(GameLoop.boost_world_div(), 0.85), str(GameLoop.boost_world_div()))
	PerfGovernor.deep_override = 0
	_gl._apply_boost_resolution()
	_check("1d deep 1→0 → 画布仍零写",
		win.content_scale_size == css0 and _gl.camera.zoom.is_equal_approx(zoom0), "")
	# 手选 75：档值来自用户——boost_res 写口仍被应用器消费
	Meta.set_setting("boost_res", 75)
	_gl._apply_boost_resolution()
	_check("1e 用户手选 75 → 540×960/.75（促2）",
		win.content_scale_size == Vector2i(540, 960) \
			and _gl.camera.zoom.is_equal_approx(Vector2(0.75, 0.75)) \
			and PerfGovernor.boost_diag_state() == 2,
		"css=%s diag=%d" % [str(win.content_scale_size), PerfGovernor.boost_diag_state()])
	PerfGovernor.deep_override = 1
	_gl._apply_boost_resolution()
	_check("1f 用户 75 ∧ deep → 仍 540×960（deep 不改用户档）",
		win.content_scale_size == Vector2i(540, 960), str(win.content_scale_size))
	Meta.set_setting("boost_res", 85)
	PerfGovernor.deep_override = 1
	_gl._apply_boost_resolution()
	_check("1g 回 85 后 deep 仍在 → 612×1088（用户档切换本身有效）",
		win.content_scale_size == Vector2i(612, 1088), str(win.content_scale_size))


# ── 点2：副武四分频（R291 刀2——执行频次 ×0.25、dt×4 守恒） ────────
func _p2_sub_quarter() -> void:
	print("── 点2 副武四分频（频次/dt/beats/守恒/关态） ──")
	_stub = StubWeapon.new()
	var slots: Array = _gl.player.weapon_slots
	if slots.is_empty():
		slots.append(_stub)
	else:
		_slot0_backup = slots[0]
		slots[0] = _stub
	_sub = StubSub.new()
	_copies_backup = _gl.player._summon_copies.duplicate()
	_gl.player._summon_copies.clear()
	_gl.player._summon_copies.append(_sub)
	Player.reset_stage_probe()
	PerfGovernor.deep_override = 1
	_gl.player._wpn_lod_phase = 0
	_gl.player._sub_lod_ctr = 0
	for _i in range(40):
		_gl.player.tick(DT, Vector2.ZERO)
	_check("2a deep 40 步 → 主武器 20 次", _stub.calls == 20, "calls=%d" % _stub.calls)
	_check("2b deep 40 步 → 副武 10 次（每 4 物理步 1 执行拍）",
		_sub.calls == 10, "calls=%d" % _sub.calls)
	_check("2c 副武执行拍 dt×4（累计 10×4/60=40/60 守恒）",
		absf(_sub.acc - 40.0 * DT) < 1.0e-5, "acc=%.6f" % _sub.acc)
	_check("2d 主武器执行拍 dt×2（累计 20×2/60=40/60 守恒）",
		absf(_stub.acc - 40.0 * DT) < 1.0e-5, "acc=%.6f" % _stub.acc)
	var main_beats_ok := true
	for b in _stub.beats_seen:
		if b != 2:
			main_beats_ok = false
	var sub_beats_ok := true
	for b in _sub.beats_seen:
		if b != 4:
			sub_beats_ok = false
	_check("2e 主武器组 lod_beats 恒 2（原语义）", main_beats_ok, str(_stub.beats_seen))
	_check("2f 副武组 lod_beats 恒 4（dt×4 配对）", sub_beats_ok, str(_sub.beats_seen))
	# 关态：每步执行、dt 原值（逐位不变）
	PerfGovernor.deep_override = 0
	_gl.player._wpn_lod_phase = 0
	_gl.player._sub_lod_ctr = 0
	var c0: int = _stub.calls
	var s0: int = _sub.calls
	var sacc0: float = _sub.acc
	for _i in range(10):
		_gl.player.tick(DT, Vector2.ZERO)
	_check("2g 关态首拍静态复位 lod_beats=2（tick 入口写点）",
		WeaponBase.lod_beats == 2, str(WeaponBase.lod_beats))
	_check("2h 关态 10 步主武器全执行", _stub.calls - c0 == 10,
		"Δ=%d" % (_stub.calls - c0))
	_check("2i 关态 10 步副武全执行（每步 dt 原值）",
		_sub.calls - s0 == 10 and absf((_sub.acc - sacc0) - 10.0 * DT) < 1.0e-5,
		"Δ=%d Δacc=%.6f" % [_sub.calls - s0, _sub.acc - sacc0])
	PerfGovernor.deep_override = -1
	# 还原夹具
	if _slot0_backup != null:
		(_gl.player.weapon_slots as Array)[0] = _slot0_backup
	_slot0_backup = null
	_gl.player._summon_copies.clear()
	for c in _copies_backup:
		if c != null:
			_gl.player._summon_copies.append(c)
	if _stub != null:
		_stub.free()
	if _sub != null:
		_sub.free()
	_stub = null
	_sub = null


# ── 点3：W9 命中帽减半（R291 刀3a） ───────────────────────────────
func _p3_w9_hit_cap() -> void:
	print("── 点3 W9 命中帽（deep ×0.5 / 关态原帽） ──")
	var grid := SpaceGrid.new()
	grid.configure(Vector2(2000.0, 2000.0), 200.0)
	var targets: Array[StubTarget] = []
	for i in range(10):
		var t := StubTarget.new()
		t.uid = 100 + i
		t.position = Vector2(50.0 + 10.0 * float(i), 0.0)
		targets.append(t)
		grid.insert(t, 20.0)
	PerfGovernor.deep_override = 1
	var host_d := StubJudgeHost.new()
	var arc_d := ArcSlash.new()
	arc_d.weapon = host_d
	arc_d.enemy_grid = grid
	arc_d.slash_radius = 400.0
	arc_d.facing = 0.0
	arc_d.arc_deg = 360.0
	arc_d.max_targets = 8
	arc_d._judge_arc(Vector2.ZERO)
	_check("3a deep ∧ max_targets=8 ∧ 10 候选 → 单窗命中 4（帽减半）",
		arc_d._struck.size() == 4, "struck=%d" % arc_d._struck.size())
	PerfGovernor.deep_override = 0
	var host_o := StubJudgeHost.new()
	var arc_o := ArcSlash.new()
	arc_o.weapon = host_o
	arc_o.enemy_grid = grid
	arc_o.slash_radius = 400.0
	arc_o.facing = 0.0
	arc_o.arc_deg = 360.0
	arc_o.max_targets = 8
	arc_o._judge_arc(Vector2.ZERO)
	_check("3b 关态同条件 → 命中 8（原帽逐位）",
		arc_o._struck.size() == 8, "struck=%d" % arc_o._struck.size())
	# 跨拍补偿（评审 L4）：帽是每拍上限非每窗硬帽——截断目标不入 _struck，同窗第二拍续命中
	PerfGovernor.deep_override = 1
	arc_d._judge_arc(Vector2.ZERO)
	_check("3c 深载同窗第二拍再命中 4（跨拍补偿——按溢出 0~50% 非每窗减半）",
		arc_d._struck.size() == 8, "struck=%d" % arc_d._struck.size())
	arc_d.free()
	arc_o.free()
	host_d.free()
	host_o.free()
	for t in targets:
		t.free()


# ── 点4：W9 消弹查询半频（R291 刀3b——概率折算） ───────────────────
func _p4_nullify_halffreq() -> void:
	print("── 点4 消弹半频（相位半真 / 折算 / W9 恒 1.0 不变） ──")
	PerfGovernor.deep_override = 1
	var arc := ArcSlash.new()
	var trues := 0
	for _i in range(100):
		if arc._nullify_due():
			trues += 1
	_check("4a deep 下 100 拍恰 50 次查询（半频）", trues == 50, "trues=%d" % trues)
	_check("4b 折算 p=0.25 → 1−0.75²=0.4375",
		absf(arc._nullify_fold(0.25) - 0.4375) < 1.0e-6, str(arc._nullify_fold(0.25)))
	_check("4b2 折算 p=0.5 → 0.75（中值）",
		absf(arc._nullify_fold(0.5) - 0.75) < 1.0e-6, str(arc._nullify_fold(0.5)))
	_check("4c 折算 p=1.0 → 1.0（W9 nullify 恒 1.0 不变）",
		absf(arc._nullify_fold(1.0) - 1.0) < 1.0e-6, str(arc._nullify_fold(1.0)))
	PerfGovernor.deep_override = 0
	var trues_off := 0
	for _i in range(100):
		if arc._nullify_due():
			trues_off += 1
	_check("4d 关态 100 拍全查询（逐位）", trues_off == 100, "trues=%d" % trues_off)
	_check("4e 关态折算原值直传（p=0.25 → 0.25）",
		absf(arc._nullify_fold(0.25) - 0.25) < 1.0e-6, str(arc._nullify_fold(0.25)))
	arc.free()


# ── 点5：弹道拖尾重绘深载门（R291 刀4） ──────────────────────────
func _p5_trail_gate() -> void:
	print("── 点5 拖尾深载门（1/15s vs 1/30s） ──")
	ProjectileBase.trail_halffreq_override = 1
	PerfGovernor.deep_override = 1
	var pb_d := ProjectileBase.new()
	var trues_d := 0
	for _i in range(8):
		if pb_d._trail_redraw_due(DT):
			trues_d += 1
	_check("5a deep 8 拍（1/60）→ 恰 2 次置脏（1/15s 门）",
		trues_d == 2, "trues=%d" % trues_d)
	PerfGovernor.deep_override = 0
	var pb_o := ProjectileBase.new()
	var trues_o := 0
	for _i in range(8):
		if pb_o._trail_redraw_due(DT):
			trues_o += 1
	_check("5b 关态 8 拍 → 4 次置脏（1/30s 门原值）",
		trues_o == 4, "trues=%d" % trues_o)
	pb_d.free()
	pb_o.free()
	ProjectileBase.trail_halffreq_override = -1


# ── 点6：关态零位移（boost 关承重墙） ────────────────────────────
func _p6_off_zero_drift() -> void:
	print("── 点6 关态零位移（boost 关 → 四刀恒不触） ──")
	PerfGovernor.boost_override = 0
	PerfGovernor.deep_override = 1
	_check("6a boost 关 → deep_load false", not PerfGovernor.deep_load(), "")
	var arc := ArcSlash.new()
	_check("6b boost 关 → 消弹逐拍恒真", arc._nullify_due() and arc._nullify_due(), "")
	_check("6c boost 关 → 折算原值直传",
		absf(arc._nullify_fold(0.25) - 0.25) < 1.0e-6, str(arc._nullify_fold(0.25)))
	arc.free()
	ProjectileBase.trail_halffreq_override = 1
	var pb := ProjectileBase.new()
	var trues := 0
	for _i in range(8):
		if pb._trail_redraw_due(DT):
			trues += 1
	_check("6d boost 关 → 拖尾门原值（4/8）", trues == 4, "trues=%d" % trues)
	pb.free()
	ProjectileBase.trail_halffreq_override = -1
	_check("6e lod_beats 默认 2", WeaponBase.lod_beats == 2, str(WeaponBase.lod_beats))
	PerfGovernor.boost_override = 1
	PerfGovernor.deep_override = -1


func _cleanup() -> void:
	print("── 收尾（设置/画布/闩/静态还原） ──")
	PerfGovernor.boost_override = -1
	PerfGovernor.deep_override = -1
	PerfGovernor.mode_override = -1
	PerfGovernor.tier_override = -1
	PerfGovernor.set_deep_active(false)
	_gl._deep_on_acc = 0.0
	_gl._deep_off_acc = 0.0
	_gl._deep_dwell_s = 0.0
	WeaponBase.lod_dt_doubled = false
	WeaponBase.lod_beats = 2
	ProjectileBase.trail_halffreq_override = -1
	_gl._boost_applied_notch = _saved_notch
	GameLoop._s_boost_applied_notch = _saved_snotch
	_gl.get_window().content_scale_size = _saved_css
	if _gl.camera != null:
		_gl.camera.zoom = _saved_zoom
	Meta._settings = _saved_settings.duplicate()
	Meta.codex_first_met = _saved_first_met.duplicate()
	Meta.codex_weapons = _saved_codex_weapons.duplicate()
	# R270 盘档毒配方：本套件写过的键显式 erase 再落盘（快照还原+落盘在「引导快照已
	# 含外来毒值」时会把毒带回盘上——erase 确保这些键只由真正的用户/后续套件重写）。
	Meta._settings.erase("perf_boost")
	Meta._settings.erase("boost_res")
	Meta._save()
	var total := _pass + _fail
	print("验收汇总：%d/%d 通过" % [_pass, total])
	if _fail > 0:
		print("失败明细：")
		for f in _failures:
			print("  - %s" % f)
	_gl.free()
	await tree.process_frame

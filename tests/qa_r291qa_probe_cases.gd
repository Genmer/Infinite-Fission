# tests/qa_r291qa_probe_cases.gd
# R291 QA 侧独立探针用例体（game-qa 自建，不触产品代码）。
# 覆盖开发方未覆盖的三项额外重点 + 点1-5 换参独立复测：
#   a) 逐子拍复刻 N=4 守恒：副本/镜面（含奏鸣 tempo）冷却间隔非整拍数（7/60、5/60）下
#      deep 480 步 vs 关态 480 步开火次数 |Δ|≤2；beats=2 路径与 git 基线（R289 HEAD
#      硬编码 2 子拍，R290 未触碰该数学）锁步 bit 等价（逐拍 cooldown_left 逐位相等
#      + 开火拍序完全一致）。
#   b) deep 闩中途翻转（on→off→on）四组残留相位（phase×ctr）下副武不长期哑火：
#      翻转后 40 步内副武执行 ≥8 次、主武 ≥20 次、副武最大执行间隙 ≤5 步。
#   c) W8 orbit_field（主组 beats=2）判定频次与 R289 语义一致：deep 40 步力场 tick
#      恰 20 次且每次 dt×2、_lod_judge 每执行拍为真、挡弹帽 ×2、公转角时间守恒
#      （40 步累计角位移 = 关态同窗）。
#   点1（真闩路径）/点3-5（换参数）独立复测。
# 夹具：main.tscn 真链 boot 后冻结引擎自动 process，全部直驱；结束还原。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const DT := 1.0 / 60.0
const STEPS := 480


# ── 桩：真实 WeaponBase.tick（不覆写 tick，只换开火三口）+ 记录钩 ──
class ProbeWeapon extends WeaponBase:
	var fires: int = 0
	var interval: float = 1.0
	var dt_log: Array[float] = []
	var beats_log: Array[int] = []
	var dbl_log: Array[bool] = []
	var cd_log: Array[float] = []

	func has_target_now() -> bool:
		return true

	func try_fire() -> bool:
		fires += 1
		return true

	func _fire_interval() -> float:
		return interval

	func _on_tick_post(p_game_delta: float) -> void:
		dt_log.append(p_game_delta)
		beats_log.append(WeaponBase.lod_beats)
		dbl_log.append(WeaponBase.lod_dt_doubled)
		cd_log.append(cooldown_left)


# 镜面桩：MirrorImage.tick 全保真（不覆写），inner/prism 用最小真件桩
class InnerStub extends WeaponBase:
	pass


class PrismStub extends WeaponBase:
	func budget_available() -> bool:
		return true

	func budget_spend(_p_shots: float) -> void:
		pass


class ProbeMirror extends MirrorImage:
	var fires: int = 0
	var interval: float = 1.0

	func has_target_now() -> bool:
		return true

	func try_fire() -> bool:
		fires += 1
		return true

	func _fire_interval() -> float:
		return interval


# W9 判定宿主桩（计数命中管线入口；三口全桩化零副作用）
class JudgeHost extends WeaponBase:
	var hits: int = 0

	func build_damage_context(_p_target: Node2D) -> DamageContext:
		hits += 1
		var ctx := DamageContext.new()
		ctx.base_atk = 1.0
		return ctx

	func inject_vuln_pool(_p_ctx: DamageContext, _p_target: Node2D) -> void:
		pass

	func _element_pool() -> Array[int]:
		return []


class GridTarget extends Node2D:
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
var _slot_backup: Variant = null
var _copies_backup: Array = []
var _mirrors_backup: Array = []


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
	seed(20261023)
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
	_gl.player.set("max_hp", 1.0e12)
	_gl.player.set("hp", 1.0e12)
	_gl.player.set("xp_need", 1.0e12)
	tree.paused = false
	_saved_css = _gl.get_window().content_scale_size
	_saved_zoom = _gl.camera.zoom if _gl.camera != null else Vector2.ONE
	_saved_notch = int(_gl._boost_applied_notch)
	_saved_snotch = GameLoop._s_boost_applied_notch
	_pa_real_latch_ui_pin()
	_pb_latch_flip()
	_pc_w8_judge()
	_a_sub_conserv()
	_bits_equivalence()
	_pts_345_recheck()
	await _cleanup()


func _boot() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate()
	_gl.name = "R291QAProbe"
	tree.root.add_child(_gl)
	await tree.process_frame
	await tree.process_frame
	if not bool(_gl.get("boot_ready")):
		_check("boot 成功（main.tscn 真链）", false, str(_gl.get("boot_fatal")))
	else:
		_check("boot 成功（main.tscn 真链）", true, "")
	_gl.set_physics_process(false)
	_gl.set_process(false)


# ── 点1 独立复测：真闩路径（不用 deep_override，走 _update_deep_load_at） ──
func _pa_real_latch_ui_pin() -> void:
	print("── 点1' 真闩路径 UI 定格（fps 驱动闩真实置位/清位） ──")
	_gl._apply_boost_resolution()
	var win := _gl.get_window()
	var css0 := win.content_scale_size
	# 低帧 2.2s → 闩真实置位
	for _i in range(132):
		_gl._update_deep_load_at(20.0, DT)
	_check("1'p 真闩置位（fps20×2.2s）", PerfGovernor.deep_active(),
		"active=%s" % str(PerfGovernor.deep_active()))
	_check("1'q 闩置位后画布仍 612×1088（零写）",
		win.content_scale_size == Vector2i(612, 1088) \
			and win.content_scale_size == css0,
		"css=%s" % str(win.content_scale_size))
	_check("1'r 闩置位后 zoom .85 / 促1 / world_div .85",
		_gl.camera.zoom.is_equal_approx(Vector2(0.85, 0.85)) \
			and PerfGovernor.boost_diag_state() == 1 \
			and is_equal_approx(GameLoop.boost_world_div(), 0.85),
		"diag=%d div=%.2f" % [PerfGovernor.boost_diag_state(), GameLoop.boost_world_div()])
	# 高帧 15.2s（驻留≥10 + off_acc≥4 + 场地安静）→ 闩真实清位
	for _i in range(912):
		_gl._update_deep_load_at(60.0, DT)
	_check("1's 真闩清位（fps60×15.2s 安静场）", not PerfGovernor.deep_active(), "")
	_check("1't 闩清位后画布零写（仍 612×1088/.85）",
		win.content_scale_size == Vector2i(612, 1088) \
			and _gl.camera.zoom.is_equal_approx(Vector2(0.85, 0.85)),
		"css=%s" % str(win.content_scale_size))
	# 用户手选 75：促2 仅来自用户档
	Meta.set_setting("boost_res", 75)
	_gl._apply_boost_resolution()
	_check("1'u 手选 75 → 540×960 / 促2",
		win.content_scale_size == Vector2i(540, 960) \
			and PerfGovernor.boost_diag_state() == 2,
		"css=%s diag=%d" % [str(win.content_scale_size), PerfGovernor.boost_diag_state()])
	for _i in range(132):
		_gl._update_deep_load_at(20.0, DT)
	_check("1'v 手选 75 ∧ 真闩置位 → 画布仍 540×960（促2=用户档）",
		PerfGovernor.deep_active() and win.content_scale_size == Vector2i(540, 960) \
			and PerfGovernor.boost_diag_state() == 2,
		"active=%s css=%s diag=%d" % [str(PerfGovernor.deep_active()),
			str(win.content_scale_size), PerfGovernor.boost_diag_state()])
	# 还原到 85 + 清闩
	Meta.set_setting("boost_res", 85)
	PerfGovernor.set_deep_active(false)
	_gl._deep_on_acc = 0.0
	_gl._deep_off_acc = 0.0
	_gl._deep_dwell_s = 0.0
	_gl._apply_boost_resolution()


# ── b) deep 闩中途翻转：四组残留相位 × on→off→on 不哑火 ──
func _pb_latch_flip() -> void:
	print("── b) 闩中途翻转（残留相位 ×4 → 副武不长期哑火） ──")
	for combo in [[0, 0], [0, 1], [1, 0], [1, 1]]:
		var phase0: int = combo[0]
		var ctr0: int = combo[1]
		var main := _make_stub(7.0 / 60.0)
		var sub := _make_stub(7.0 / 60.0)
		_install_stubs(main, sub)
		PerfGovernor.deep_override = 1
		_gl.player.set("_wpn_lod_phase", phase0)
		_gl.player.set("_sub_lod_ctr", ctr0)
		for _i in range(6):
			_gl.player.tick(DT, Vector2.ZERO)          # on：残留相位下跑 6 步
		PerfGovernor.deep_override = 0
		var off_m0: int = main.dt_log.size()
		var off_s0: int = sub.dt_log.size()
		for _i in range(6):
			_gl.player.tick(DT, Vector2.ZERO)          # off：6 步（应逐步全执行）
		var off_m: int = main.dt_log.size() - off_m0
		var off_s: int = sub.dt_log.size() - off_s0
		PerfGovernor.deep_override = 1
		var m0: int = main.dt_log.size()
		var s0: int = sub.dt_log.size()
		var sub_steps: Array[int] = []
		for i in range(40):
			_gl.player.tick(DT, Vector2.ZERO)          # 再 on：40 步观测窗
			if sub.dt_log.size() > s0:
				sub_steps.append(i)
		var sub_exec: int = sub_steps.size()
		var main_exec: int = main.dt_log.size() - m0
		var max_gap := 0
		var prev := -1
		for st in sub_steps:
			if prev >= 0:
				max_gap = maxi(max_gap, st - prev)
			prev = st
		if not sub_steps.is_empty():
			max_gap = maxi(max_gap, sub_steps[0] + 1)  # 翻转后首执行延迟
		_check("b1 相位(%d,%d) off 段主/副武逐步全执行（6/6）" % [phase0, ctr0],
			off_m == 6 and off_s == 6, "m=%d s=%d" % [off_m, off_s])
		_check("b2 相位(%d,%d) 翻转后 40 步副武执行 ≥8 次" % [phase0, ctr0],
			sub_exec >= 8, "exec=%d" % sub_exec)
		_check("b3 相位(%d,%d) 翻转后 40 步主武执行 ≥20 次" % [phase0, ctr0],
			main_exec >= 20, "exec=%d" % main_exec)
		_check("b4 相位(%d,%d) 副武最大执行间隙 ≤5 步（无长期哑火）" % [phase0, ctr0],
			max_gap <= 5, "max_gap=%d steps=%s" % [max_gap, str(sub_steps)])
		_uninstall_stubs()
	PerfGovernor.deep_override = -1
	_gl.player.set("_wpn_lod_phase", 0)
	_gl.player.set("_sub_lod_ctr", 0)


# ── c) W8 orbit_field：主组 beats=2 判定频次与 R289 语义一致 ──
func _pc_w8_judge() -> void:
	print("── c) W8 力场判定（30Hz 执行拍 / _lod_judge / 挡弹帽×2 / 公转守恒） ──")
	var w8: WeaponBase = _gl.player.add_weapon(_gl.registry.get_weapon(&"W8_orbit_field"))
	if w8 == null or w8.data == null:
		_check("c0 真实 W8_orbit_field 装入", false, str(w8))
		return
	_check("c0 真实 W8_orbit_field 装入", true, "")
	var field: OrbitField = w8.get("orbit_field")
	if field == null:
		w8.call("_ensure_orbit_field")
		field = w8.get("orbit_field")
	if field == null:
		_check("c1 力场实体存在", false, "")
		return
	_check("c1 力场实体存在", true, "")
	var speed: float = float(field.get("angular_speed"))
	# deep：40 步观测——力场 tick 次数（用 _anim_t 差分）、_lod_judge、挡弹帽、角位移
	PerfGovernor.deep_override = 1
	_gl.player.set("_wpn_lod_phase", 0)
	_gl.player.set("_sub_lod_ctr", 0)
	var tick_steps := 0
	var judge_true_steps := 0
	var block_ok := true
	var ang_total_d := 0.0
	var anim0: float = float(field.get("_anim_t"))
	var ang_prev: float = float(field.get("angle"))
	for _i in range(40):
		_gl.player.tick(DT, Vector2.ZERO)
		var anim_now: float = float(field.get("_anim_t"))
		var ang_now: float = float(field.get("angle"))
		var d_ang := ang_now - ang_prev
		if d_ang < 0.0:
			d_ang += TAU
		ang_total_d += d_ang
		ang_prev = ang_now
		if anim_now != anim0:
			tick_steps += 1
			var adv := anim_now - anim0
			if not is_equal_approx(adv, DT * 2.0):
				block_ok = false                # 记录异常（非判定断言）
			anim0 = anim_now
			if bool(field.get("_lod_judge")):
				judge_true_steps += 1
			if int(field.get("_block_left")) != OrbitField.BULLET_BLOCK_CAP_PER_TICK * 2:
				block_ok = false
	var expect_ang := deg_to_rad(speed) * 40.0 * DT
	_check("c2 deep 40 步力场 tick 恰 20 次（每执行拍 1 次）", tick_steps == 20,
		"ticks=%d" % tick_steps)
	_check("c3 每力场 tick _lod_judge 真（dt×2 执行拍）且每次推进 dt×2",
		judge_true_steps == 20, "judge=%d" % judge_true_steps)
	_check("c4 每执行拍挡弹帽 = 4×2（R289 语义 ×2 折算不变）", block_ok, "")
	_check("c5 deep 40 步公转角位移 = 40×DT×ω（时间守恒）",
		absf(ang_total_d - expect_ang) < 1.0e-6,
		"got=%.8f expect=%.8f" % [ang_total_d, expect_ang])
	# 关态对照：40 步 40 次推进、_lod_judge 假、角位移同值
	PerfGovernor.deep_override = 0
	var tick_steps_off := 0
	var ang_total_o := 0.0
	var ang_prev2: float = float(field.get("angle"))
	var anim1: float = float(field.get("_anim_t"))
	var judge_off_bad := false
	for _i in range(40):
		_gl.player.tick(DT, Vector2.ZERO)
		var ang_now: float = float(field.get("angle"))
		var d_ang := ang_now - ang_prev2
		if d_ang < 0.0:
			d_ang += TAU
		ang_total_o += d_ang
		ang_prev2 = ang_now
		var anim_now: float = float(field.get("_anim_t"))
		if anim_now != anim1:
			tick_steps_off += 1
			if bool(field.get("_lod_judge")):
				judge_off_bad = true
			anim1 = anim_now
	_check("c6 关态 40 步力场 tick 40 次（60Hz 原语义）", tick_steps_off == 40,
		"ticks=%d" % tick_steps_off)
	_check("c7 关态 _lod_judge 恒假（dt 原值）", not judge_off_bad, "")
	_check("c8 关态同窗角位移与 deep 一致（±1e-6）",
		absf(ang_total_o - ang_total_d) < 1.0e-6,
		"off=%.8f deep=%.8f" % [ang_total_o, ang_total_d])
	PerfGovernor.deep_override = -1
	_gl.player.set("_wpn_lod_phase", 0)
	_gl.player.set("_sub_lod_ctr", 0)
	# 清理 W8
	var slots: Array = _gl.player.weapon_slots
	for i in range(slots.size()):
		if slots[i] == w8:
			slots[i] = null
	w8.queue_free()


# ── a) 副武四分频长窗守恒（副本/镜面/奏鸣）+ 步序/dt/拍值精确性 ──
func _a_sub_conserv() -> void:
	print("── a) 副武长窗守恒（480 步 deep vs off，非整拍冷却） ──")
	# 步序精确性：deep 40 步，主武在奇数步（0 基）×dt2、副武在 3,7,..,39 步 ×dt4
	var main := _make_stub(7.0 / 60.0)
	var sub := _make_stub(7.0 / 60.0)
	_install_stubs(main, sub)
	PerfGovernor.deep_override = 1
	_gl.player.set("_wpn_lod_phase", 0)
	_gl.player.set("_sub_lod_ctr", 0)
	var main_at: Array[int] = []
	var sub_at: Array[int] = []
	var m_prev := 0
	var s_prev := 0
	for i in range(40):
		_gl.player.tick(DT, Vector2.ZERO)
		if main.dt_log.size() > m_prev:
			main_at.append(i)
			m_prev = main.dt_log.size()
		if sub.dt_log.size() > s_prev:
			sub_at.append(i)
			s_prev = sub.dt_log.size()
	var main_steps_ok := main_at.size() == 20
	var sub_steps_ok := sub_at.size() == 10
	for k in range(main_at.size()):
		if main_at[k] != k * 2 + 1:
			main_steps_ok = false
	for k in range(sub_at.size()):
		if sub_at[k] != k * 4 + 3:
			sub_steps_ok = false
	_check("a0a deep 40 步主武执行步序 = 1,3,..,39", main_steps_ok, str(main_at))
	_check("a0b deep 40 步副武执行步序 = 3,7,..,39（每 4 步）", sub_steps_ok, str(sub_at))
	var dt2_ok := true
	var dt4_ok := true
	for v in main.dt_log:
		if v != DT * 2.0:
			dt2_ok = false
	for v in sub.dt_log:
		if v != DT * 4.0:
			dt4_ok = false
	_check("a0c 主武每次 dt 逐位 = DT×2 / 副武逐位 = DT×4", dt2_ok and dt4_ok,
		"main_dt_ok=%s sub_dt_ok=%s" % [str(dt2_ok), str(dt4_ok)])
	_check("a0d 主武拍值恒 2 / 副武拍值恒 4",
		_main_beats_ok(main, 2) and _main_beats_ok(sub, 4), "")
	_check("a0e 主/副武 lod_dt_doubled 全真", _dbl_all(main) and _dbl_all(sub), "")
	_uninstall_stubs()

	# 长窗守恒矩阵：组别 × 间隔 × tempo
	var cases := [
		{"grp": "copy", "iv": 7.0 / 60.0, "tempo": 0.0, "tag": "副本 iv=7/60"},
		{"grp": "copy", "iv": 5.0 / 60.0, "tempo": 0.0, "tag": "副本 iv=5/60"},
		{"grp": "copy", "iv": 3.0 / 60.0, "tempo": 0.0, "tag": "副本 iv=3/60"},
		{"grp": "copy", "iv": 2.5 / 60.0, "tempo": 0.0, "tag": "副本 iv=2.5/60"},
		{"grp": "copy", "iv": 13.0 / 60.0, "tempo": 0.0, "tag": "副本 iv=13/60"},
		{"grp": "mirror", "iv": 7.0 / 60.0, "tempo": 1.0, "tag": "镜面 iv=7/60 tempo=1.0"},
		{"grp": "mirror", "iv": 5.0 / 60.0, "tempo": 2.5, "tag": "镜面 iv=5/60 tempo=2.5"},
		{"grp": "mirror", "iv": 2.5 / 60.0, "tempo": 1.6, "tag": "镜面 iv=2.5/60 tempo=1.6"},
		{"grp": "main", "iv": 7.0 / 60.0, "tempo": 0.0, "tag": "主武 iv=7/60（beats=2 对照）"},
		{"grp": "main", "iv": 5.0 / 60.0, "tempo": 0.0, "tag": "主武 iv=5/60（beats=2 对照）"},
	]
	for c in cases:
		var fires_off := _run_window(String(c["grp"]), float(c["iv"]), float(c["tempo"]), 0)
		var fires_deep := _run_window(String(c["grp"]), float(c["iv"]), float(c["tempo"]), 1)
		var delta_i: int = fires_deep - fires_off
		_check("a1 %s：deep/off 480 步开火 |Δ|≤2" % String(c["tag"]),
			absi(delta_i) <= 2, "off=%d deep=%d Δ=%d" % [fires_off, fires_deep, delta_i])
	PerfGovernor.deep_override = -1


func _run_window(p_grp: String, p_iv: float, p_tempo: float, p_deep: int) -> int:
	if p_grp == "mirror":
		var mir := ProbeMirror.new()
		mir.interval = p_iv
		var inner := InnerStub.new()
		var prism := PrismStub.new()
		mir.set("inner", inner)
		mir.set("prism", prism)
		mir.set("_tempo_mult", p_tempo)
		var mb: Array = _gl.player._mirror_images.duplicate()
		_gl.player._mirror_images.clear()
		_gl.player._mirror_images.append(mir)
		PerfGovernor.deep_override = p_deep
		_gl.player.set("_wpn_lod_phase", 0)
		_gl.player.set("_sub_lod_ctr", 0)
		for _i in range(STEPS):
			_gl.player.tick(DT, Vector2.ZERO)
		var fires: int = mir.get("fires")
		_gl.player._mirror_images.clear()
		for m in mb:
			if m != null:
				_gl.player._mirror_images.append(m)
		mir.free()
		inner.free()
		prism.free()
		return fires
	var w := _make_stub(p_iv)
	if p_grp == "main":
		_install_stubs(w, null)
	else:
		_install_stubs(null, w)
	PerfGovernor.deep_override = p_deep
	_gl.player.set("_wpn_lod_phase", 0)
	_gl.player.set("_sub_lod_ctr", 0)
	for _i in range(STEPS):
		_gl.player.tick(DT, Vector2.ZERO)
	var fires2: int = w.fires
	_uninstall_stubs()
	return fires2


var _stub_main: ProbeWeapon = null
var _stub_sub: ProbeWeapon = null
var _wdata: WeaponData = null


func _make_stub(p_iv: float) -> ProbeWeapon:
	# 真实 WeaponBase.tick 需 data!=null（tick 首行 data null 早退）——setup 真 W1 数据，
	# 开火三口全覆写（间隔/目标/开火），tick 数学全保真。
	var w := ProbeWeapon.new()
	w.interval = p_iv
	if _wdata == null:
		_wdata = _gl.registry.get_weapon(&"W1_pistol")
	w.setup(_wdata, _gl.player, {})
	return w


func _install_stubs(p_main: ProbeWeapon, p_sub: ProbeWeapon) -> void:
	var slots: Array = _gl.player.weapon_slots
	_slot_backup = slots[0]
	slots[0] = p_main
	_stub_main = p_main
	_copies_backup = _gl.player._summon_copies.duplicate()
	_gl.player._summon_copies.clear()
	_stub_sub = p_sub
	if p_sub != null:
		_gl.player._summon_copies.append(p_sub)


func _uninstall_stubs() -> void:
	var slots: Array = _gl.player.weapon_slots
	slots[0] = _slot_backup
	_slot_backup = null
	_gl.player._summon_copies.clear()
	for c in _copies_backup:
		if c != null:
			_gl.player._summon_copies.append(c)
	_copies_backup = []
	if _stub_main != null:
		_stub_main.free()
		_stub_main = null
	if _stub_sub != null:
		_stub_sub.free()
		_stub_sub = null


func _main_beats_ok(p_w: ProbeWeapon, p_expect: int) -> bool:
	for b in p_w.beats_log:
		if b != p_expect:
			return false
	return true


func _dbl_all(p_w: ProbeWeapon) -> bool:
	for b in p_w.dbl_log:
		if not b:
			return false
	return true


# ── a') beats=2 路径与 R289 基线锁步 bit 等价 ──
func _bits_equivalence() -> void:
	print("── a') beats=2 与 R289 基线锁步 bit 等价（主武/镜面含奏鸣） ──")
	WeaponBase.lod_dt_doubled = true
	WeaponBase.lod_beats = 2
	# 主武：间隔 7/60 与 5/60（W2 整数拍边界 5 拍另测）
	for iv in [7.0 / 60.0, 5.0 / 60.0, 4.0 / 60.0, 11.0 / 60.0]:
		var w := _make_stub(iv)
		var ref_cd := 0.0
		var cd_ok := true
		var fire_ok := true
		var ref_fires := 0
		for _i in range(240):                      # 240 执行拍 = 480 物理步
			w.tick(DT * 2.0)
			var r := _ref289_main(ref_cd, DT * 2.0, iv)
			ref_cd = float(r["cd"])
			ref_fires += 1 if bool(r["fired"]) else 0
			if w.cooldown_left != ref_cd:
				cd_ok = false
		if w.fires != ref_fires:
			fire_ok = false
		_check("a'1 主武 iv=%.6f：240 执行拍逐拍 cooldown_left 逐位相等" % iv, cd_ok,
			"ref=%s got=%s" % [str(ref_cd), str(w.cooldown_left)])
		_check("a'2 主武 iv=%.6f：开火次数与基线完全一致" % iv, fire_ok,
			"ref=%d got=%d" % [ref_fires, w.fires])
		w.free()
	# 镜面：tempo 1.0 / 2.5
	for tc in [[5.0 / 60.0, 1.0], [7.0 / 60.0, 2.5]]:
		var iv := float(tc[0])
		var tempo := float(tc[1])
		var mir := ProbeMirror.new()
		mir.interval = iv
		var inner := InnerStub.new()
		var prism := PrismStub.new()
		mir.set("inner", inner)
		mir.set("prism", prism)
		mir.set("_tempo_mult", tempo)
		var ref_cd := 0.0
		var cd_ok := true
		var ref_fires := 0
		for _i in range(240):
			mir.tick(DT * 2.0)
			var r := _ref289_mirror(ref_cd, DT * 2.0, iv, tempo)
			ref_cd = float(r["cd"])
			ref_fires += 1 if bool(r["fired"]) else 0
			if mir.cooldown_left != ref_cd:
				cd_ok = false
		_check("a'3 镜面 iv=%.4f tempo=%.1f：逐拍 cooldown_left 逐位相等" % [iv, tempo],
			cd_ok, "ref=%s got=%s" % [str(ref_cd), str(mir.cooldown_left)])
		_check("a'4 镜面 iv=%.4f tempo=%.1f：开火次数与基线完全一致" % [iv, tempo],
			mir.fires == ref_fires, "ref=%d got=%d" % [ref_fires, mir.fires])
		mir.free()
		inner.free()
		prism.free()
	WeaponBase.lod_dt_doubled = false
	WeaponBase.lod_beats = 2


func _ref289_main(p_cd: float, p_delta: float, p_iv: float) -> Dictionary:
	# R289 HEAD 硬编码 2 子拍递推（weapon_base.gd LOD 分支逐句复刻；目标恒在/开火恒真）
	var sub := p_delta * 0.5
	var cd := p_cd
	var fire_logical := 0
	for _k in range(2):
		if cd > 0.0:
			cd = maxf(cd - sub, 0.0)
		elif fire_logical == 0:
			fire_logical = _k + 1
	var fired := false
	if fire_logical > 0:
		fired = true
		cd = p_iv
		if fire_logical == 1:
			cd = maxf(cd - sub, 0.0)
	return {"cd": cd, "fired": fired}


func _ref289_mirror(p_cd: float, p_delta: float, p_iv: float, p_tempo: float) -> Dictionary:
	# R289 HEAD mirror_image.gd LOD 分支逐句复刻（含奏鸣扣减）
	var sub := p_delta * 0.5
	var cd := p_cd
	var fire_logical := 0
	for _k in range(2):
		if cd > 0.0:
			cd = maxf(cd - sub, 0.0)
			if p_tempo > 1.0:
				cd -= sub * (p_tempo - 1.0)
		elif fire_logical == 0:
			fire_logical = _k + 1
	var fired := false
	if fire_logical > 0:
		fired = true
		cd = p_iv
		if fire_logical == 1:
			cd = maxf(cd - sub, 0.0)
			if p_tempo > 1.0:
				cd -= sub * (p_tempo - 1.0)
	return {"cd": cd, "fired": fired}


# ── 点3/4/5 独立换参复测 ──
func _pts_345_recheck() -> void:
	print("── 点3'/4'/5' 独立换参复测 ──")
	# 点3：命中帽（max_targets=6/5/1 × deep/off）
	var grid := SpaceGrid.new()
	grid.configure(Vector2(2000.0, 2000.0), 200.0)
	var targets: Array[GridTarget] = []
	for i in range(12):
		var t := GridTarget.new()
		t.uid = 500 + i
		t.position = Vector2(40.0 + 8.0 * float(i), 0.0)
		targets.append(t)
		grid.insert(t, 20.0)
	for cap_i in [[6, 3, 6], [5, 2, 5], [1, 1, 1]]:
		var cap := int(cap_i[0])
		var want_d := int(cap_i[1])
		var want_o := int(cap_i[2])
		var struck_d := _arc_strike(grid, cap, 1)
		var struck_o := _arc_strike(grid, cap, 0)
		_check("3' 帽=%d：deep 命中 %d / off 命中 %d" % [cap, want_d, want_o],
			struck_d == want_d and struck_o == want_o,
			"deep=%d off=%d" % [struck_d, struck_o])
	for t in targets:
		t.free()
	# 点4：消弹半频相位 + 折算换参
	PerfGovernor.deep_override = 1
	var arc := ArcSlash.new()
	var seq := ""
	for _i in range(6):
		seq += "T" if arc._nullify_due() else "F"
	_check("4'a deep 相位序列 FTFTFT（隔执行拍查询）", seq == "FTFTFT", seq)
	_check("4'b 折算 p=0.5 → 0.75", absf(arc._nullify_fold(0.5) - 0.75) < 1.0e-9,
		str(arc._nullify_fold(0.5)))
	_check("4'c 折算 p=0.8 → 0.96", absf(arc._nullify_fold(0.8) - 0.96) < 1.0e-9,
		str(arc._nullify_fold(0.8)))
	_check("4'd 折算 p=1.0 → 1.0", absf(arc._nullify_fold(1.0) - 1.0) < 1.0e-9, "")
	PerfGovernor.deep_override = 0
	var seq_o := ""
	for _i in range(6):
		seq_o += "T" if arc._nullify_due() else "F"
	_check("4'e 关态恒 T / 原值直传", seq_o == "TTTTTT"
		and absf(arc._nullify_fold(0.5) - 0.5) < 1.0e-9, seq_o)
	arc.free()
	# 点5：拖尾门换窗长（16 拍 → deep 4 / off 8）
	ProjectileBase.trail_halffreq_override = 1
	PerfGovernor.deep_override = 1
	var pb_d := ProjectileBase.new()
	var trues_d := 0
	for _i in range(16):
		if pb_d._trail_redraw_due(DT):
			trues_d += 1
	_check("5'a deep 16 拍 → 4 次置脏", trues_d == 4, "trues=%d" % trues_d)
	PerfGovernor.deep_override = 0
	var pb_o := ProjectileBase.new()
	var trues_o := 0
	for _i in range(16):
		if pb_o._trail_redraw_due(DT):
			trues_o += 1
	_check("5'b 关态 16 拍 → 8 次置脏（1/30 原值）", trues_o == 8, "trues=%d" % trues_o)
	pb_d.free()
	pb_o.free()
	ProjectileBase.trail_halffreq_override = -1
	PerfGovernor.deep_override = -1


func _arc_strike(p_grid: SpaceGrid, p_cap: int, p_deep: int) -> int:
	PerfGovernor.deep_override = p_deep
	var host := JudgeHost.new()
	var arc := ArcSlash.new()
	arc.weapon = host
	arc.enemy_grid = p_grid
	arc.slash_radius = 300.0
	arc.facing = 0.0
	arc.arc_deg = 360.0
	arc.max_targets = p_cap
	arc._judge_arc(Vector2.ZERO)
	var n: int = arc._struck.size()
	arc.free()
	host.free()
	PerfGovernor.deep_override = -1
	return n


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
	# R270 盘档毒配方（R291 修轮补）：本套件写过的键显式 erase 再落盘——
	# 9 套电池中 boostmode a1 曾被本套件落盘的 perf_boost=1 毒红（跨进程）。
	Meta._settings.erase("perf_boost")
	Meta._settings.erase("boost_res")
	Meta._save()
	var total := _pass + _fail
	print("探针汇总：%d/%d 通过" % [_pass, total])
	if _fail > 0:
		print("失败明细：")
		for f in _failures:
			print("  - %s" % f)
	_gl.free()
	await tree.process_frame

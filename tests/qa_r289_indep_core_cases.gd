# tests/qa_r289_indep_core_cases.gd
# R289 独立 QA 探针核心面。契约来源（用户任务/设计背景）：
#   a) 深载滞回：fps<34 持续 2s 置位；1.99s 不置位；34..45 死区 10s 清高帧侧计时、
#      保留低帧累计（R290）；fps>45 持续 4s ∧ 驻留≥10s ∧ 场地安静（R290 负载门）清位；
#      PLAYING+tree.paused / LEVEL_UP 冻结；MENU 清位；
#      boost 关恒 false；deep_override 0/1 单谓词。
#   d) B：深载玩家弹（team0）活口帽 BOOST_DEEP_TEAM0_CAP（R290：200→120），不误伤 team1；
#      解除深载恢复可获；敌帽三态 120/90/40（boost 关 / boost 开 / boost∧deep）。
#   e) C：boost 开 + deep → 540×960 + zoom .75 + world_div .75；解除 → 612×1088/.85；
#      boost 关 → 应用器零写；用户 75 档不被深载改写。
# 夹具：main.tscn 真链 boot 后冻结引擎自动 process，全部直驱；结束恢复设置/画布/闩。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"

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
var _acquired: Array[Node] = []
var _team1_orig: Array[Node] = []


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
	seed(289)
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
	_gl.player.unlocked_slots = 6
	tree.paused = false
	_saved_css = _gl.get_window().content_scale_size
	_saved_zoom = _gl.camera.zoom if _gl.camera != null else Vector2.ONE
	_saved_notch = int(_gl._boost_applied_notch)
	_saved_snotch = GameLoop._s_boost_applied_notch
	_a_hysteresis()
	_d_bullet_cap()
	_d_enemy_cap()
	_e_render_notch()
	await _cleanup()


func _boot() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate()
	_gl.name = "R289IndepCore"
	tree.root.add_child(_gl)
	await tree.process_frame
	await tree.process_frame
	if not bool(_gl.get("boot_ready")):
		_check("boot 成功（main.tscn 真链）", false, str(_gl.get("boot_fatal")))
	else:
		_check("boot 成功（main.tscn 真链）", true, "")
	_gl.set_physics_process(false)
	_gl.set_process(false)


func _reset_deep() -> void:
	PerfGovernor.deep_override = -1
	PerfGovernor.set_deep_active(false)
	_gl._deep_on_acc = 0.0
	_gl._deep_off_acc = 0.0
	_gl._deep_dwell_s = 0.0
	tree.paused = false
	_gl.state = GameConst.GameStatus.PLAYING


func _deep_steps(p_fps: float, p_seconds: float) -> void:
	# R289 修轮迁移：生产写点对单帧 delta 钳 0.1s（后台恢复防御）——直驱也按 0.1s
	# 物理帧步进，累计语义与 _process 真链一致。
	var n := int(round(p_seconds / 0.1))
	for _i in range(n):
		_gl._update_deep_load_at(p_fps, 0.1)


# ── a：滞回边界 / 死区 / 冻结 / 清位 / boost 门 ────────────────────
func _a_hysteresis() -> void:
	print("── a 深载滞回（1.99/2.00 / 死区 / 4s / 暂停与选卡冻结 / MENU / boost 门） ──")
	PerfGovernor.boost_override = 1
	_reset_deep()
	_deep_steps(20.0, 1.9)
	_check("a1 fps20 × 1.9s 不置位", not PerfGovernor.deep_active(),
		"active=%s on_acc=%.4f" % [str(PerfGovernor.deep_active()), float(_gl._deep_on_acc)])
	_deep_steps(20.0, 0.1)
	_check("a2 累计 2.0s 置位", PerfGovernor.deep_active(),
		"active=%s on_acc=%.4f" % [str(PerfGovernor.deep_active()), float(_gl._deep_on_acc)])

	var dead_ok := true
	for _i in range(100):
		_gl._update_deep_load_at(40.0, 0.1)
		if not PerfGovernor.deep_active() or absf(float(_gl._deep_on_acc)) > 1.0e-9 \
				or absf(float(_gl._deep_off_acc)) > 1.0e-9:
			dead_ok = false
	_check("a3 34..45 死区 10s 保持置位且高帧侧计时归零", dead_ok,
		"active=%s on=%.4f off=%.4f" % [str(PerfGovernor.deep_active()),
			float(_gl._deep_on_acc), float(_gl._deep_off_acc)])

	# 死区边界 34/45（判据 <34 / >45——两端点均在死区，保持闩且计时清零）
	PerfGovernor.set_deep_active(true)
	_gl._deep_on_acc = 0.0
	_gl._deep_off_acc = 0.0
	_deep_steps(34.0, 0.1)
	var edge34_ok := PerfGovernor.deep_active() and absf(float(_gl._deep_on_acc)) < 1.0e-9 		and absf(float(_gl._deep_off_acc)) < 1.0e-9
	_deep_steps(45.0, 0.1)
	var edge45_ok := PerfGovernor.deep_active() and absf(float(_gl._deep_on_acc)) < 1.0e-9 		and absf(float(_gl._deep_off_acc)) < 1.0e-9
	_check("a3b fps=34/45 端点均属死区（保持闩+计时归零）", edge34_ok and edge45_ok,
		"34=%s 45=%s" % [str(edge34_ok), str(edge45_ok)])

	_deep_steps(60.0, 3.9)
	_check("a4 fps60 × 3.9s 仍置位（4s 门槛未到）", PerfGovernor.deep_active(),
		"off_acc=%.4f" % float(_gl._deep_off_acc))
	_deep_steps(60.0, 0.1)
	_check("a5 fps60 累计 4.0s 且驻留≥10s → 清位", not PerfGovernor.deep_active(),
		"active=%s off_acc=%.4f" % [str(PerfGovernor.deep_active()), float(_gl._deep_off_acc)])

	# R290 修轮（vc89 判读）：死区（34..45）不再清零低帧累计——真机 fps 在边界抖动期
	# 原「双侧清零」使置位长期不可达（0:16-0:23 连续 8s fps 9-23 却深0）。
	_reset_deep()
	_deep_steps(20.0, 1.9)
	_deep_steps(40.0, 2.0)
	_check("a3c 死区 2s 保留低帧累计（不清零）", not PerfGovernor.deep_active() \
		and absf(float(_gl._deep_on_acc) - 1.9) < 1.0e-6,
		"active=%s on=%.4f" % [str(PerfGovernor.deep_active()), float(_gl._deep_on_acc)])
	_deep_steps(20.0, 0.2)
	_check("a3d 死区后低帧续累计即置位（原实现下不可达）", PerfGovernor.deep_active(),
		"active=%s on=%.4f" % [str(PerfGovernor.deep_active()), float(_gl._deep_on_acc)])

	# R290 修轮：清位负载门——场地仍满载时不撤深载（vc89 0:46 空场误清 → 0:47-0:59
	# 满载 13s 裸奔）。夹具：向 spawner.active 注 35 个 Node2D 占位 → 满载；清空 → 安静。
	_reset_deep()
	_deep_steps(20.0, 2.0)
	_deep_steps(60.0, 11.0)
	_check("a3e 无载（spawner 空）高帧 4s+驻留≥10s → 清位（基线）",
		not PerfGovernor.deep_active(), "dwell=%.2f" % float(_gl._deep_dwell_s))
	_reset_deep()
	_deep_steps(20.0, 2.0)
	var _sp: Variant = _gl.get("spawner")
	var _act: Array = [] if _sp == null else (_sp.get("active") as Array)
	var _inj: Array[Node2D] = []
	if _sp != null:
		for _i in range(GameLoop.DEEP_CLEAR_QUIET_ENEMIES + 5):
			var _n := Node2D.new()
			_inj.append(_n)
			_act.append(_n)
	_deep_steps(60.0, 11.0)
	_check("a3f 场地满载（敌≥30）时高帧 4s+驻留≥10s 不撤深载（负载门）",
		PerfGovernor.deep_active() and _act.size() == GameLoop.DEEP_CLEAR_QUIET_ENEMIES + 5,
		"active=%s n=%d dwell=%.2f" % [str(PerfGovernor.deep_active()), _act.size(),
			float(_gl._deep_dwell_s)])
	if _sp != null:
		for _n in _inj:
			_act.erase(_n)
			_n.free()
	_deep_steps(60.0, 4.0)
	_check("a3g 场地清空后再高帧 4s → 撤档",
		not PerfGovernor.deep_active(), "active=%s" % str(PerfGovernor.deep_active()))

	# R289 修轮：后台恢复巨 delta 钳制 + 最小驻留（10s 内不撤）
	_reset_deep()
	_gl._update_deep_load_at(20.0, 5.0)
	_gl._update_deep_load_at(20.0, 5.0)
	_check("a5b 巨 delta×2 不置位（单帧钳 0.1s）", not PerfGovernor.deep_active(),
		"on_acc=%.4f" % float(_gl._deep_on_acc))
	_deep_steps(20.0, 2.0)
	_check("a5c 0.1s 帧步进累计 2s → 置位", PerfGovernor.deep_active(), "")
	_deep_steps(60.0, 4.0)
	_check("a5d 驻留<10s 时高帧 4s 不撤（防极限环）", PerfGovernor.deep_active(),
		"dwell=%.2f" % float(_gl._deep_dwell_s))
	_deep_steps(40.0, 4.0)
	_deep_steps(60.0, 4.0)
	_check("a5e 驻留≥10s 后高帧 4s → 撤档", not PerfGovernor.deep_active(),
		"dwell=%.2f" % float(_gl._deep_dwell_s))

	# PLAYING + tree.paused：冻结（低位不置位 / 已置位不清位）
	_reset_deep()
	tree.paused = true
	_deep_steps(20.0, 1.0)
	_check("a6 PLAYING+paused 低位不置位（冻结）", not PerfGovernor.deep_active(),
		"active=%s" % str(PerfGovernor.deep_active()))
	PerfGovernor.set_deep_active(true)
	_deep_steps(60.0, 1.0)
	_check("a7 PLAYING+paused 高位不清位（冻结）", PerfGovernor.deep_active(),
		"active=%s" % str(PerfGovernor.deep_active()))
	tree.paused = false

	# LEVEL_UP 冻结两侧
	_reset_deep()
	_gl.state = GameConst.GameStatus.LEVEL_UP
	_deep_steps(20.0, 1.0)
	_check("a8 LEVEL_UP 低位不置位（冻结）", not PerfGovernor.deep_active(), "")
	PerfGovernor.set_deep_active(true)
	_deep_steps(60.0, 1.0)
	_check("a9 LEVEL_UP 高位不清位（冻结）", PerfGovernor.deep_active(), "")
	_gl.state = GameConst.GameStatus.PLAYING

	# MENU 清位 + 计时复位
	PerfGovernor.set_deep_active(true)
	_gl._deep_on_acc = 0.7
	_gl._deep_off_acc = 0.9
	_gl.state = GameConst.GameStatus.MENU
	_gl._update_deep_load_at(20.0, 0.5)
	_check("a10 MENU 清位", not PerfGovernor.deep_active(),
		"active=%s" % str(PerfGovernor.deep_active()))
	_check("a11 MENU 双侧计时复位", absf(float(_gl._deep_on_acc)) < 1.0e-9 \
		and absf(float(_gl._deep_off_acc)) < 1.0e-9,
		"on=%.4f off=%.4f" % [float(_gl._deep_on_acc), float(_gl._deep_off_acc)])
	for st in [GameConst.GameStatus.GAME_OVER, GameConst.GameStatus.BOOT]:
		PerfGovernor.set_deep_active(true)
		_gl._deep_on_acc = 0.3
		_gl._deep_off_acc = 0.4
		_gl.state = st
		_gl._update_deep_load_at(20.0, 0.5)
		_check("a11b 状态%d → 清位+计时复位" % int(st),
			not PerfGovernor.deep_active() and absf(float(_gl._deep_on_acc)) < 1.0e-9 				and absf(float(_gl._deep_off_acc)) < 1.0e-9, "")
	_gl.state = GameConst.GameStatus.PLAYING

	# boost 关：真值恒 false，且写点清闩/计时
	PerfGovernor.boost_override = 0
	PerfGovernor.deep_override = -1
	PerfGovernor.set_deep_active(true)
	_check("a12 boost 关 → deep_load 恒 false（闩虽真）", not PerfGovernor.deep_load(),
		"active=%s" % str(PerfGovernor.deep_active()))
	_gl._deep_on_acc = 1.5
	_gl._deep_off_acc = 1.5
	_gl._update_deep_load_at(20.0, 10.0)
	_check("a13 boost 关 → 写点清闩+计时", not PerfGovernor.deep_active() \
		and absf(float(_gl._deep_on_acc)) < 1.0e-9 and absf(float(_gl._deep_off_acc)) < 1.0e-9,
		"active=%s on=%.4f off=%.4f" % [str(PerfGovernor.deep_active()),
			float(_gl._deep_on_acc), float(_gl._deep_off_acc)])
	PerfGovernor.deep_override = 1
	_check("a14 boost 关 ∧ deep_override=1 → 仍 false（boost 门优先）",
		not PerfGovernor.deep_load(), "")

	# 单谓词 deep_override
	PerfGovernor.boost_override = 1
	PerfGovernor.deep_override = 0
	PerfGovernor.set_deep_active(true)
	_check("a15 boost 开 ∧ deep_override=0 → false（压过闩）", not PerfGovernor.deep_load(), "")
	PerfGovernor.set_deep_active(false)
	PerfGovernor.deep_override = 1
	_check("a16 boost 开 ∧ deep_override=1 → true（无需闩）", PerfGovernor.deep_load(), "")
	PerfGovernor.deep_override = -1
	PerfGovernor.set_deep_active(false)


# ── d1：玩家弹（team0）BOOST_DEEP_TEAM0_CAP 帽 ────────────────────
func _d_bullet_cap() -> void:
	# R290：帽值 200→120——断言全部改符号 ProjectilePool.BOOST_DEEP_TEAM0_CAP（值变断言随动）
	var cap: int = ProjectilePool.BOOST_DEEP_TEAM0_CAP
	print("── d1 B 深载玩家弹帽（team0 %d；team1 不误伤；解除恢复） ──" % cap)
	PerfGovernor.boost_override = 1
	PerfGovernor.deep_override = 1
	PerfGovernor.set_deep_active(false)
	var pool: ProjectilePool = _gl._projectile_pool
	_clear_pool(pool)
	_check("d1 前置：弹池空（total=0 / team1=0）",
		pool.total_active() == 0 and pool.team1_live == 0,
		"total=%d team1=%d" % [pool.total_active(), pool.team1_live])

	for _i in range(30):
		var p1: ProjectileBase = pool.acquire(1)
		if p1 == null:
			break
		p1.team = 1
		_team1_orig.append(p1)
		_acquired.append(p1)
	_check("d2 注入 30 颗 team1 活弹（计数与池一致）",
		pool.team1_live == 30 and pool.total_active() == 30,
		"team1=%d total=%d" % [pool.team1_live, pool.total_active()])

	var cap0 := int(DebugStats.get_counter(&"deep_bullet_capped"))
	var got0 := 0
	for _i in range(400):
		var p0: ProjectileBase = pool.acquire(0)
		if p0 == null:
			break
		got0 += 1
		_acquired.append(p0)
	_check("d3 深载 team0 活口恰可到 %d" % cap, got0 == cap,
		"got=%d total=%d team1=%d" % [got0, pool.total_active(), pool.team1_live])
	_check("d4 帽判据不含 team1（total=%d）" % (cap + 30),
		pool.total_active() == cap + 30 and pool.team1_live == 30,
		"total=%d team1=%d" % [pool.total_active(), pool.team1_live])
	_check("d5 超帽第 %d 颗被拒（deep_bullet_capped 递增）" % (cap + 1),
		int(DebugStats.get_counter(&"deep_bullet_capped")) - cap0 > 0,
		"Δ=%d" % (int(DebugStats.get_counter(&"deep_bullet_capped")) - cap0))
	var team1_alive := true
	var live_now: Array = pool.active_projectiles()
	for p in _team1_orig:
		if p == null or not is_instance_valid(p) or not live_now.has(p):
			team1_alive = false
	_check("d6 team1 活弹未被 team0 帽回收（30 颗仍在活口表）", team1_alive,
		"team1_live=%d active=%d" % [pool.team1_live, live_now.size()])

	# team1 自身路径仍可获（不受 team0 帽影响）
	var extra1: ProjectileBase = pool.acquire(1)
	if extra1 != null:
		extra1.team = 1
		_acquired.append(extra1)
	_check("d7 team0 满帽时 acquire(1) 仍可获", extra1 != null,
		"team1_live=%d" % pool.team1_live)

	# 解除深载：同池恢复可获（帽 → 帽+1）
	PerfGovernor.deep_override = 0
	var cap1 := int(DebugStats.get_counter(&"deep_bullet_capped"))
	var p_off: ProjectileBase = pool.acquire(0)
	if p_off != null:
		_acquired.append(p_off)
	_check("d8 解除深载后可再获 team0（活口>%d）" % cap,
		p_off != null and pool.total_active() > cap,
		"total=%d" % pool.total_active())
	_check("d9 解除深载 acquire 不再计 deep_bullet_capped",
		int(DebugStats.get_counter(&"deep_bullet_capped")) == cap1, "")

	# 再开深载：帽+1 已超帽 → 拒绝
	PerfGovernor.deep_override = 1
	var p_re: ProjectileBase = pool.acquire(0)
	_check("d10 重开深载且 team0=%d → 立即拒绝" % (cap + 1), p_re == null,
		"acquire=%s" % str(p_re))

	_clear_pool(pool)
	_check("d11 归还后 total=0 / team1=0", pool.total_active() == 0 and pool.team1_live == 0,
		"total=%d team1=%d" % [pool.total_active(), pool.team1_live])


func _d_enemy_cap() -> void:
	print("── d2 B 敌帽三态（boost 关 120 / boost 开 90 / boost∧deep 40） ──")
	PerfGovernor.boost_override = 0
	PerfGovernor.deep_override = 1
	_check("d12 boost 关（deep_override=1）→ 120", EnemySpawner.max_onscreen() == 120,
		str(EnemySpawner.max_onscreen()))
	PerfGovernor.boost_override = 1
	PerfGovernor.deep_override = 0
	_check("d13 boost 开 deep 关 → 90", EnemySpawner.max_onscreen() == 90,
		str(EnemySpawner.max_onscreen()))
	PerfGovernor.deep_override = 1
	_check("d14 boost 开 deep 开 → 40", EnemySpawner.max_onscreen() == 40,
		str(EnemySpawner.max_onscreen()))
	PerfGovernor.deep_override = -1
	PerfGovernor.set_deep_active(true)
	_check("d15 真值闩 deep_active → 40", EnemySpawner.max_onscreen() == 40,
		str(EnemySpawner.max_onscreen()))
	PerfGovernor.boost_override = 0
	_check("d16 boost 关 + 闩真 → 120（boost 门优先）", EnemySpawner.max_onscreen() == 120,
		str(EnemySpawner.max_onscreen()))
	PerfGovernor.boost_override = 1
	PerfGovernor.set_deep_active(false)


# ── e：C 渲染档（R291 UI 定格后语义） ─────────────────────────────
func _e_render_notch() -> void:
	print("── e C 档（R291 UI 定格：deep 不改画布；用户档恒定；boost 关零写；用户 75 幂等） ──")
	_gl.state = GameConst.GameStatus.PLAYING
	PerfGovernor.boost_override = 1
	PerfGovernor.deep_override = 1
	Meta.set_setting("boost_res", 85)
	_gl._boost_applied_notch = 0
	GameLoop._s_boost_applied_notch = 0
	_gl._apply_boost_resolution()
	var win := _gl.get_window()
	_check("e1 85+deep（PLAYING）→ 画布定格 612×1088（R291 删自动降档）",
		win.content_scale_size == Vector2i(612, 1088), str(win.content_scale_size))
	_check("e2 85+deep → zoom .85（不降 .75）",
		_gl.camera != null and _gl.camera.zoom.is_equal_approx(Vector2(0.85, 0.85)),
		str(_gl.camera.zoom) if _gl.camera != null else "camera=null")
	_check("e3 85+deep → boost_world_div .85",
		is_equal_approx(GameLoop.boost_world_div(), 0.85), str(GameLoop.boost_world_div()))
	_check("e4 85+deep → 促键 1（用户档真值——促2 只属用户手选 75）",
		PerfGovernor.boost_diag_state() == 1, str(PerfGovernor.boost_diag_state()))

	PerfGovernor.deep_override = 0
	_gl._apply_boost_resolution()
	_check("e5 deep 解除 → 画布幂等零写（仍 612×1088）",
		win.content_scale_size == Vector2i(612, 1088), str(win.content_scale_size))
	_check("e6 deep 解除 → 促键 1（闩不再影响画布/促键）",
		PerfGovernor.boost_diag_state() == 1, str(PerfGovernor.boost_diag_state()))

	# boost 关：回 720×1280/zoom1/div1，且再次调用零写
	PerfGovernor.boost_override = 0
	PerfGovernor.deep_override = 1
	_gl._apply_boost_resolution()
	_check("e7 boost 关 → 720×1280 + zoom1 + div1",
		win.content_scale_size == Vector2i(720, 1280) \
			and _gl.camera.zoom.is_equal_approx(Vector2.ONE) \
			and is_equal_approx(GameLoop.boost_world_div(), 1.0),
		"css=%s zoom=%s div=%s" % [str(win.content_scale_size), str(_gl.camera.zoom),
			str(GameLoop.boost_world_div())])
	_check("e8 boost 关 ∧ deep_override=1 → deep_load false / 促0",
		not PerfGovernor.deep_load() and PerfGovernor.boost_diag_state() == 0, "")
	var css0 := win.content_scale_size
	var zoom0: Vector2 = _gl.camera.zoom
	var notch0 := int(_gl._boost_applied_notch)
	_gl._apply_boost_resolution()
	_check("e9 boost 关 → 应用器幂等零写（快照前后相等）",
		win.content_scale_size == css0 and _gl.camera.zoom.is_equal_approx(zoom0) \
			and int(_gl._boost_applied_notch) == notch0,
		"css=%s->%s notch=%d->%d" % [str(css0), str(win.content_scale_size),
			notch0, int(_gl._boost_applied_notch)])

	# 用户 75 档（手选语义不变）：deep 关/开均 540
	PerfGovernor.boost_override = 1
	Meta.set_setting("boost_res", 75)
	PerfGovernor.deep_override = 0
	_gl._apply_boost_resolution()
	_check("e10 用户 75 ∧ deep 关 → 540×960/.75（促2）",
		win.content_scale_size == Vector2i(540, 960) \
			and _gl.camera.zoom.is_equal_approx(Vector2(0.75, 0.75)) \
			and PerfGovernor.boost_diag_state() == 2,
		"css=%s diag=%d" % [str(win.content_scale_size), PerfGovernor.boost_diag_state()])
	PerfGovernor.deep_override = 1
	_gl._apply_boost_resolution()
	_check("e11 用户 75 ∧ deep 开 → 540×960/.75（幂等——deep 不改用户档）",
		win.content_scale_size == Vector2i(540, 960) \
			and _gl.camera.zoom.is_equal_approx(Vector2(0.75, 0.75)) \
			and PerfGovernor.boost_diag_state() == 2,
		"css=%s diag=%d" % [str(win.content_scale_size), PerfGovernor.boost_diag_state()])

	# 恢复用户 85：deep 关 → 612
	Meta.set_setting("boost_res", 85)
	PerfGovernor.deep_override = 0
	_gl._apply_boost_resolution()
	_check("e12 回用户 85 → 612×1088/.85",
		win.content_scale_size == Vector2i(612, 1088) \
			and _gl.camera.zoom.is_equal_approx(Vector2(0.85, 0.85)), "")


# ── 收尾 ─────────────────────────────────────────────────────────
func _clear_pool(pool: ProjectilePool) -> void:
	var live: Array = pool.active_projectiles().duplicate()
	for p in live:
		if p != null and is_instance_valid(p):
			pool.release(p)
	_acquired.clear()
	_team1_orig.clear()


func _cleanup() -> void:
	print("── 收尾（池/设置/画布/闩还原） ──")
	var pool: ProjectilePool = _gl._projectile_pool
	_clear_pool(pool)
	PerfGovernor.boost_override = -1
	PerfGovernor.deep_override = -1
	PerfGovernor.mode_override = -1
	PerfGovernor.tier_override = -1
	PerfGovernor.set_deep_active(false)
	_gl._deep_on_acc = 0.0
	_gl._deep_off_acc = 0.0
	_gl.set_process(true)
	_gl.set_physics_process(true)
	_gl.get_window().content_scale_size = _saved_css
	if _gl.camera != null:
		_gl.camera.zoom = _saved_zoom
	_gl._boost_applied_notch = _saved_notch
	GameLoop._s_boost_applied_notch = _saved_snotch
	tree.paused = false
	RunSave.clear()
	Meta.codex_first_met = _saved_first_met.duplicate()
	Meta.codex_weapons = _saved_codex_weapons.duplicate()
	Meta._settings = _saved_settings.duplicate()
	Meta._save()
	_gl.queue_free()
	await tree.process_frame
	print("验收汇总：%d/%d 通过" % [_pass, _pass + _fail])
	if _fail > 0:
		for f in _failures:
			print("  FAIL 项：%s" % f)

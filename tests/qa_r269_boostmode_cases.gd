# tests/qa_r269_boostmode_cases.gd
# R269 A 轨用例体（入口 tests/qa_r269_boostmode.gd 运行时 load——-s 编译期禁引工程
# 类名纪律）。覆盖设计 §5 a1-a8 + C1（§3.5）：
# · a1 boost_mode 读序三态 / 垫值纯函数 / 首启垫值路径（不重触发 _ready——EventBus
#   重复连接风险，分析师复审余项口径：直调 _boost_pad_defaults helper 同语义）；
# · a2 fx 钉 0（调速器帽 + 元素层 _fx_quality 尾分支）/ 关态旧四分支序逐位；
# · a3 跳字帽 12 vs 80/40/20；
# · a4 敌帽 90/120 + MAX_ONSCREEN const 保留 + 敌弹 320 帽注入；
# · a5 死亡帽（门开不依赖 fullload/tier/mobile / 帽值 4 / -2 否决 / DeathPop 被 fx
#   钉 0 前置门整挡 / PoisonSplash 增量面收缩 4）；
# · a6 分辨率应用器数学（纯函数 / boost_world_div / cloud 恒等 / 应用器幂等零写）；
# · a8 音效档口 _sfx_q 两口分离 + 源级四消费点；
# · C1 装饰门并 boost（谓词矩阵 / 行为隐藏复显 / fullload_flips 不增）。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const DT := 1.0 / 60.0
const ENEMY_SRC := "res://scripts/entities/enemy/enemy.gd"

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null
var _host: Node2D = null
var _saved_settings: Dictionary = {}


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_saved_settings = Meta._settings.duplicate()      # 入口快照（收尾还原——磁盘不留测试痕）
	_boot_game_loop()
	await tree.process_frame
	await tree.process_frame
	PerfGovernor.set_process(false)             # 引擎侧停走——tier 真值不被采样漂移（r223 先例）
	PerfGovernor.boost_override = -1
	PerfGovernor.mode_override = -1
	PerfGovernor.tier_override = -1
	PerfGovernor.tier = 3
	Enemy.deathpop_cap_override = -1
	Enemy.fullload_override = -1
	Meta.set_setting("fx_quality", 2)           # r230 先例：钉高防跨套件 user:// 残留漂门
	_gl.state = GameConst.GameStatus.MENU
	_host = Node2D.new()
	_host.name = "R269BoostHost"
	tree.get_root().add_child(_host)
	_test_a1_mode_and_pad()
	_test_a2_fx_pin_zero()
	_test_a3_popup_cap()
	_test_a4_density_caps()
	_test_a5_death_cap()
	_test_a6_resolution_math()
	_test_a8_sfx_gate()
	_test_c1_decor_boost()
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
	_gl.name = "R269BoostGameLoop"
	tree.get_root().add_child(_gl)              # _ready → boot（池预热/事件链全环）


func _drain_registry() -> void:
	var guard := 0
	while not Enemy._death_fx_live.is_empty() and guard < 64:
		for item in Enemy._death_fx_live.duplicate():
			if item != null and is_instance_valid(item):
				item.call("_process", 1.0)
		guard += 1


# ── a1 读序三态 + 垫值 ─────────────────────────────────────────────

func _test_a1_mode_and_pad() -> void:
	print("── a1 boost_mode 读序三态 / 垫值纯函数 / 首启垫值路径 ──")
	PerfGovernor.boost_override = -1
	_check("a1缺省（override -1 + settings 无键）→ 关",
		PerfGovernor.boost_mode() == false, "")
	_check("a1垫值纯函数：_boost_default_for(false)==0 / (true)==1（平台分叉单源）",
		Meta._boost_default_for(false) == 0 and Meta._boost_default_for(true) == 1, "")
	PerfGovernor.boost_override = 1
	_check("a1强开直通：override=1 → true（压过 settings）",
		PerfGovernor.boost_mode() == true, "")
	Meta.set_setting("perf_boost", 1)
	PerfGovernor.boost_override = 0
	_check("a1强关直通：override=0 ∧ settings=1 → false（注入最高优先）",
		PerfGovernor.boost_mode() == false, "")
	PerfGovernor.boost_override = -1
	_check("a1真值通道：settings(perf_boost)=1 ∧ override=-1 → true（写口后下一读翻转）",
		PerfGovernor.boost_mode() == true, "")
	Meta.set_setting("perf_boost", 0)
	_check("a1真值通道回落：settings=0 → false",
		PerfGovernor.boost_mode() == false, "")
	# 首启垫值路径：删键 → _boost_pad_defaults 补齐（headless 非 mobile → 0；不落盘口径
	# 由 helper 直调验证——_ready 重触发会重复连 EventBus，分析师复审余项明令避开）
	Meta._settings.erase("perf_boost")
	Meta._settings.erase("boost_res")
	Meta._boost_pad_defaults()
	_check("a1首启垫值：键缺省 → 垫值可达（headless 非 mobile → perf_boost==0 ∧ boost_res==85）",
		int(Meta._settings.get("perf_boost", -99)) == 0
			and int(Meta._settings.get("boost_res", -99)) == 85,
		"pb=%s br=%s" % [str(Meta._settings.get("perf_boost", null)), str(Meta._settings.get("boost_res", null))])
	_check("a1双注册：SETTINGS_DEFAULTS 含 perf_boost==0 / boost_res==85",
		int(Meta.SETTINGS_DEFAULTS.get("perf_boost", -99)) == 0
			and int(Meta.SETTINGS_DEFAULTS.get("boost_res", -99)) == 85, "")
	_check("a1归一化：perf_boost clampi(0,1)（7→1 / -3→0）+ boost_res 归 {85,75}（90→85 / 70→75 / 80→85 脏值归 85）",
		Meta._normalized_setting("perf_boost", 7) == 1
			and Meta._normalized_setting("perf_boost", -3) == 0
			and Meta._normalized_setting("boost_res", 90) == 85
			and Meta._normalized_setting("boost_res", 70) == 75
			and Meta._normalized_setting("boost_res", 80) == 85, "")
	_check("a1促N 单源：boost_diag_state 关=0（与诊断行/设置行文案同源）",
		PerfGovernor.boost_diag_state() == 0, "")
	PerfGovernor.boost_override = 1
	_check("a1促N 单源：强开（settings boost_res 缺省→85）→ 1",
		PerfGovernor.boost_diag_state() == 1, "")
	Meta.set_setting("boost_res", 75)
	_check("a1促N 单源：开 ∧ boost_res=75 → 2",
		PerfGovernor.boost_diag_state() == 2, "")
	PerfGovernor.boost_override = -1
	# 修3（评审中#3）：首启一次性告知——headless 垫 0 零触发 + consume 一次性语义
	_check("a1修3 零触发：headless 垫 0 → consume_boost_intro()==''（desktop 口径不动）",
		Meta.consume_boost_intro() == "", "")
	Meta._boost_intro_pending = true           # 待播注入（mobile 垫 1 逻辑臂——OS 门 headless 不可翻）
	var intro_txt := Meta.consume_boost_intro()
	_check("a1修3 待播：consume 返回白话文案 ∧ boost_intro_seen 置位（一次性标志）",
		intro_txt.contains("保帧模式") and intro_txt.contains("设置")
			and Meta.boost_intro_seen == true, "txt=%s" % intro_txt)
	_check("a1修3 一次性：二次 consume 空（勿每启重播）",
		Meta.consume_boost_intro() == "", "")
	Meta.set_setting("perf_boost", 0)
	Meta.set_setting("boost_res", 85)


# ── a2 fx 钉 0（调速器帽 + 元素层） ───────────────────────────────

func _test_a2_fx_pin_zero() -> void:
	print("── a2 fx 钉 0：fx_quality_cap boost 分支 + 元素层 _fx_quality 尾分支 ──")
	PerfGovernor.tier_override = -1
	PerfGovernor.boost_override = 1
	_check("a2调速器帽：boost 开（tier_override -1 真值路径）→ fx_quality_cap()==0",
		PerfGovernor.fx_quality_cap() == 0, "cap=%d" % PerfGovernor.fx_quality_cap())
	_check("a2 Enemy._fx_q：boost 开 → 0（桌面 fx 档 2 被钉 0）",
		Enemy._fx_q() == 0, "q=%d" % Enemy._fx_q())
	var efl := ElementalFxLayer.new()
	_check("a2元素层：boost 开 → _fx_quality()==0（预算表 [0,2,4] 落 0 档）",
		efl._fx_quality() == 0, "q=%d" % efl._fx_quality())
	efl.free()
	PerfGovernor.boost_override = -1
	# 关态旧四分支序逐位（tier_override 注入 3→2 / 2→1 / 1→0；非 mobile 无注入恒 2）
	PerfGovernor.tier_override = 3
	_check("a2关态逐位：tier_override=3 → cap 2",
		PerfGovernor.fx_quality_cap() == 2, "")
	PerfGovernor.tier_override = 2
	_check("a2关态逐位：tier_override=2 → cap 1",
		PerfGovernor.fx_quality_cap() == 1, "")
	PerfGovernor.tier_override = 1
	_check("a2关态逐位：tier_override=1 → cap 0",
		PerfGovernor.fx_quality_cap() == 0, "")
	PerfGovernor.tier_override = -1
	_check("a2关态逐位：非 mobile 无注入 → 恒 2（桌面零扰动承重墙）",
		PerfGovernor.fx_quality_cap() == 2, "")
	efl = ElementalFxLayer.new()
	_check("a2元素层关态：fx_quality 设置 2 → _fx_quality()==2（现状逐位）",
		efl._fx_quality() == 2, "q=%d" % efl._fx_quality())
	efl.free()


# ── a3 跳字帽 12 ───────────────────────────────────────────────────

func _test_a3_popup_cap() -> void:
	print("── a3 跳字帽：boost 开 12 / 关 80-40-20 逐位 ──")
	PerfGovernor.boost_override = 1
	_check("a3boost 开：max_active_for(2/1/0) 全=12（单向阀 mini）",
		PopupManager.max_active_for(2) == 12 and PopupManager.max_active_for(1) == 12
			and PopupManager.max_active_for(0) == 12, "")
	PerfGovernor.boost_override = -1
	_check("a3boost 关（桌面默认）：80/40/20 逐位（r218 ④ 锁不动）",
		PopupManager.max_active_for(2) == 80 and PopupManager.max_active_for(1) == 40
			and PopupManager.max_active_for(0) == 20, "")


# ── a4 密度帽 + 敌弹 320 帽 ────────────────────────────────────────

func _test_a4_density_caps() -> void:
	print("── a4 敌帽 90/120 + MAX_ONSCREEN 保留 + 敌弹 320 帽注入 ──")
	PerfGovernor.boost_override = 1
	_check("a4敌帽读口：boost 开 → max_onscreen()==90",
		EnemySpawner.max_onscreen() == 90, "")
	PerfGovernor.boost_override = -1
	_check("a4敌帽读口：boost 关 → max_onscreen()==120",
		EnemySpawner.max_onscreen() == 120, "")
	_check("a4const 保留：EnemySpawner.MAX_ONSCREEN==120（符号直引编译不破——r212_poolwarm:118）",
		EnemySpawner.MAX_ONSCREEN == 120, "")
	# 敌弹 320 帽：注入计数直驱（b5 同款通路——boost_bullet_capped 计数 + null 拒发）
	var bp := ProjectilePool.new()
	bp.name = "R269BoostCapPoolA4"
	tree.get_root().add_child(bp)
	bp.setup(&"r269_boostcap_a4", load("res://scenes/combat/projectiles/ballistic_projectile.tscn"), 8)
	bp.soft_limit = 1500
	DebugStats._diag_dispatch_delta(&"boost_bullet_capped")   # 立基线
	PerfGovernor.boost_override = 1
	bp.team1_live = 320
	var n1: ProjectileBase = bp.acquire(1)
	_check("a4敌弹帽：boost 开 ∧ team1_live≥320 → acquire(1) 返 null（该发未射）",
		n1 == null, "")
	_check("a4敌弹帽：boost_bullet_capped 计数 +1（拒N 源）",
		DebugStats._diag_dispatch_delta(&"boost_bullet_capped") == 1, "")
	var n0: ProjectileBase = bp.acquire(0)
	_check("a4敌弹帽只锁 team-1：acquire(0) 正常获取",
		n0 != null, "")
	PerfGovernor.boost_override = -1
	bp.team1_live = 320
	_check("a4敌弹帽关态：同计数 320 → acquire(1) 正常获取（门不触逐位）",
		bp.acquire(1) != null, "")
	_check("a4BOOST_TEAM1_CAP 常量==320（设计 §3.4 帽值锚）",
		ProjectilePool.BOOST_TEAM1_CAP == 320, "")
	bp.free()


# ── a5 死亡帽 ──────────────────────────────────────────────────────

func _test_a5_death_cap() -> void:
	print("── a5 死亡帽：门开不依赖环境 / 帽值 4 / -2 否决 / DeathPop 前置门整挡 ──")
	PerfGovernor.boost_override = 1
	PerfGovernor.mode_override = 1             # 特效优先（最敌对组合）
	PerfGovernor.tier_override = 3
	Enemy.fullload_override = 0
	Enemy.deathpop_cap_override = -1
	_check("a5门：boost 开 → _deathpop_cap_on() 真（不依赖 fullload/tier/mobile）",
		Enemy._deathpop_cap_on() == true, "")
	Enemy.deathpop_cap_override = -2
	_check("a5否决：deathpop_cap_override=-2 恒关（用户否决压过 boost）",
		Enemy._deathpop_cap_on() == false, "")
	Enemy.deathpop_cap_override = -1
	_check("a5帽值：boost 开 → _death_fx_cap_now()==4（DEATHPOP_FX_CAP 10 收缩）",
		Enemy._death_fx_cap_now() == 4, "")
	PerfGovernor.boost_override = -1
	PerfGovernor.mode_override = -1
	PerfGovernor.tier_override = -1
	_check("a5帽值：boost 关 → _death_fx_cap_now()==10（r230 哨兵四态逐位）",
		Enemy._death_fx_cap_now() == 10, "")
	# PoisonSplash 增量面：boost 开 ×6 → 注册表帽 4（最老抢占 2 次）
	PerfGovernor.boost_override = 1
	_drain_registry()
	var cap0 := DebugStats.get_counter(&"deathpop_capped")
	for i in 6:
		Enemy.PoisonSplash.pop(_host, Vector2(300.0 + 10.0 * i, 600.0), 77.0, false, false)
	_check("a5增量面：boost 开 PoisonSplash×6 → 注册表==4（帽 4 收缩 + 抢占 2）",
		Enemy._death_fx_live.size() == 4
			and DebugStats.get_counter(&"deathpop_capped") - cap0 == 2,
		"reg=%d capped+%d" % [Enemy._death_fx_live.size(),
			DebugStats.get_counter(&"deathpop_capped") - cap0])
	_drain_registry()
	# DeathPop 前置门整挡：boost 开 fx 钉 0 → _on_died 不发 DeathPop（结算链照走）
	var kills := [0]
	var handler := func(_e: Node2D) -> void:
		kills[0] += 1
	EventBus.enemy_killed.connect(handler)
	var pool_root: Node = null
	var dp_blocked := 0
	for round_i in 2:
		var boost_on := round_i == 0
		PerfGovernor.boost_override = 1 if boost_on else -1
		var e: Enemy = (_gl.pools[&"enemy"] as EnemyPool).acquire()
		var data: EnemyData = _gl.registry.get_enemy(&"E1_grunt")
		e.spawn(data, 1, 0)
		e.position = Vector2(400.0, 600.0)
		_gl.spawner.active.append(e)
		pool_root = e.get_parent()
		var before := _count_deathpops(pool_root)
		e.apply_damage(999999.0)
		if boost_on:
			dp_blocked = _count_deathpops(pool_root) - before
		else:
			_check("a5对照：boost 关（fx 档 2）击杀 → DeathPop 发射 +1（门外语义逐位）",
				_count_deathpops(pool_root) - before == 1 and e.dead,
				"Δ=%d dead=%s" % [_count_deathpops(pool_root) - before, str(e.dead)])
	_check("a5前置门整挡：boost 开击杀 → DeathPop 零发射（_fx_q()==0 门吸收——增量面确为 PoisonSplash）",
		dp_blocked == 0, "Δ=%d" % dp_blocked)
	_check("a5结算链零触碰：两击杀 enemy_killed 全数派发（掉落/经验照走）",
		kills[0] == 2, "kills=%d" % kills[0])
	EventBus.enemy_killed.disconnect(handler)
	PerfGovernor.boost_override = -1


func _count_deathpops(p_parent: Node) -> int:
	var n := 0
	for c in p_parent.get_children():
		if c is Enemy.DeathPop:
			n += 1
	return n


# ── a6 分辨率应用器数学 ────────────────────────────────────────────

func _test_a6_resolution_math() -> void:
	print("── a6 分辨率数学：纯函数 / world_div / cloud 恒等 / 应用器幂等零写 ──")
	_check("a6纯函数：_boost_target_scale 85→(612,1088,0.85) / 75→(540,960,0.75) / 关→(720,1280,1.0)",
		GameLoop._boost_target_scale(1) == Vector3(612.0, 1088.0, 0.85)
			and GameLoop._boost_target_scale(2) == Vector3(540.0, 960.0, 0.75)
			and GameLoop._boost_target_scale(0) == Vector3(720.0, 1280.0, 1.0), "")
	PerfGovernor.boost_override = -1
	Meta.set_setting("perf_boost", 0)
	_check("a6boost_world_div：关=1.0（x/1.0 浮点恒等——r195_adapt 逐位）",
		GameLoop.boost_world_div() == 1.0, "")
	var vis: Vector2 = _gl.get_viewport().get_visible_rect().size
	_check("a6cloud 恒等：vis/div == vis（div=1.0 时 float 逐位不变）",
		vis / GameLoop.boost_world_div() == vis, "vis=%s" % str(vis))
	# R270 迁移：boost_world_div/应用器改读已应用档+活战态门（MENU 态恒 1.0/零写）——
	# 夹具入 PLAYING 驱动应用器后 div 才有意义值（勿再以「设置开」直推 div）。
	_gl.state = GameConst.GameStatus.PLAYING
	PerfGovernor.boost_override = 1
	_gl._apply_boost_resolution()
	_check("a6boost_world_div：开85 → 0.85（zoom 分母——坐标空间除回可见世界域）",
		is_equal_approx(GameLoop.boost_world_div(), 0.85), "div=%s" % str(GameLoop.boost_world_div()))
	PerfGovernor.boost_override = -1
	Meta.set_setting("boost_res", 75)           # 关态写档（emit→关 notch 0 应用恢复——窗口回基线）
	PerfGovernor.boost_override = 1
	_gl._apply_boost_resolution()               # 75 档入活战态应用
	_check("a6boost_world_div：开75 → 0.75",
		is_equal_approx(GameLoop.boost_world_div(), 0.75), "")
	PerfGovernor.boost_override = -1
	Meta.set_setting("boost_res", 85)           # 关态回档（同上恢复——保 a6 后续零写断言干净起点）
	# 应用器幂等：关态首调零写（boot 后 notch 已 0——content_scale/zoom 恒不被写）
	var win := _gl.get_window()
	var css_before := win.content_scale_size
	var zoom_before := _gl.camera.zoom
	_gl._apply_boost_resolution()
	_check("a6应用器关态零写：同档重入 content_scale_size/zoom 逐位不动",
		win.content_scale_size == css_before and _gl.camera.zoom == zoom_before,
		"css=%s→%s zoom=%s→%s" % [str(css_before), str(win.content_scale_size),
			str(zoom_before), str(_gl.camera.zoom)])
	# 热切实测：boost 85 → (612,1088)+zoom 0.85；回退关 → 原值恢复
	PerfGovernor.boost_override = 1
	_gl._apply_boost_resolution()
	_check("a6应用器开85：content_scale_size==(612,1088) ∧ camera.zoom==(0.85,0.85)",
		win.content_scale_size == Vector2i(612, 1088)
			and _gl.camera.zoom == Vector2(0.85, 0.85),
		"css=%s zoom=%s" % [str(win.content_scale_size), str(_gl.camera.zoom)])
	_gl._apply_boost_resolution()
	_check("a6应用器幂等：同档二次调用零写",
		win.content_scale_size == Vector2i(612, 1088)
			and _gl.camera.zoom == Vector2(0.85, 0.85), "")
	PerfGovernor.boost_override = -1
	_gl._apply_boost_resolution()
	_check("a6应用器回退：关模式 → content_scale_size/zoom 回原值（单函数单点回滚）",
		win.content_scale_size == css_before and _gl.camera.zoom == zoom_before,
		"css=%s zoom=%s" % [str(win.content_scale_size), str(_gl.camera.zoom)])
	# R270 迁移收尾：a6 的 PLAYING 窗口关闭——回 MENU 基线（直写 state 不走 change_state
	# 迁移链；应用器已在上行回退，窗口/mirror 已是 0 档基线，无需再驱）
	_gl.state = GameConst.GameStatus.MENU


# ── a8 音效档口 _sfx_q ─────────────────────────────────────────────

func _test_a8_sfx_gate() -> void:
	print("── a8 音效档口：boost 开不受钉 0 影响 / 关态两口逐位同值 ──")
	PerfGovernor.tier_override = -1
	PerfGovernor.boost_override = 1
	Meta.set_setting("fx_quality", 2)
	_check("a8两口分离：boost 开 → _sfx_q()==2（用户设置档直读）∧ _fx_q()==0（渲染钉 0）",
		Enemy._sfx_q() == 2 and Enemy._fx_q() == 0,
		"sfx=%d fx=%d" % [Enemy._sfx_q(), Enemy._fx_q()])
	Meta.set_setting("fx_quality", 1)
	_check("a8两口分离：boost 开 → _sfx_q()==1（随用户档）∧ _fx_q()==0",
		Enemy._sfx_q() == 1 and Enemy._fx_q() == 0, "")
	Meta.set_setting("fx_quality", 0)
	_check("a8两口分离：boost 开 → _sfx_q()==0（用户关=真关，非钉 0）∧ _fx_q()==0",
		Enemy._sfx_q() == 0 and Enemy._fx_q() == 0, "")
	_check("a8源级 mobile 臂锚：_sfx_q 开模式含 mini(cache,1) mobile 降档（headless 不可翻转 OS 门——源文本锁）",
		FileAccess.get_file_as_string(ENEMY_SRC).contains(
			"return mini(_fx_quality_cache, 1) if OS.has_feature(\"mobile\") else _fx_quality_cache"), "")
	PerfGovernor.boost_override = -1
	Meta.set_setting("fx_quality", 2)
	_check("a8关态逐位：_sfx_q()==_fx_q()（档 2）",
		Enemy._sfx_q() == Enemy._fx_q() and Enemy._sfx_q() == 2, "")
	PerfGovernor.tier_override = 1
	_check("a8关态含 tier 帽语义：tier_override=1 → 两口同 0（深载 tier1 静音=既有行为）",
		Enemy._sfx_q() == 0 and Enemy._fx_q() == 0, "")
	PerfGovernor.tier_override = -1
	var src := FileAccess.get_file_as_string(ENEMY_SRC)
	var gate_count := src.count("SfxBank.I != null and _sfx_q() > 0")
	_check("a8源级四消费点：_begin_cast/_release_cast/_affix_begin/_affix_release 换读完成（×4）",
		gate_count == 4, "count=%d" % gate_count)


# ── C1 装饰门并 boost ──────────────────────────────────────────────

func _test_c1_decor_boost() -> void:
	print("── C1 装饰门并 boost：谓词矩阵 / 行为隐藏复显 / fullload_flips 不增 ──")
	Enemy.fullload_override = 0
	PerfGovernor.boost_override = -1
	_check("C1谓词：关 ∧ fullload 0 → 不隐（现状逐位）",
		Enemy._decor_hidden_now() == false, "")
	Enemy.fullload_override = 1
	_check("C1谓词：关 ∧ fullload 1 → 隐（既有满载门）",
		Enemy._decor_hidden_now() == true, "")
	Enemy.fullload_override = 0
	PerfGovernor.boost_override = 1
	_check("C1谓词：开 ∧ fullload 0 → 隐（敌<80 段也隐——boost 单向并）",
		Enemy._decor_hidden_now() == true, "")
	Enemy.fullload_override = 1
	_check("C1谓词：开 ∧ fullload 1 → 隐",
		Enemy._decor_hidden_now() == true, "")
	Enemy.fullload_override = -1
	PerfGovernor.boost_override = -1            # 谓词矩阵后复位（spawn 装饰按关态建——防夹具自带隐藏）
	# 行为：精英敌装饰（皇冠/微光粒）隐藏-复显 + 翻N 不增
	var e: Enemy = (_gl.pools[&"enemy"] as EnemyPool).acquire()
	var data: EnemyData = _gl.registry.get_enemy(&"E1_grunt")
	e.spawn(data, 1, GameConst.TAG_ELITE)
	_gl.spawner.active.append(e)
	var flips0 := DebugStats.get_counter(&"fullload_flips")
	_check("C1前置：精英敌皇冠在位且可见（want 语义建件）",
		e._crown != null and e._crown.visible,
		"crown=%s vis=%s" % [str(e._crown != null), str(e._crown.visible if e._crown != null else "n/a")])
	PerfGovernor.boost_override = 1
	e._apply_fullload_decor()
	_check("C1行为：boost 开 → 皇冠隐藏（装饰门唯一点换 _decor_hidden_now 生效）",
		e._crown != null and e._crown.visible == false, "")
	_check("C1翻N 不增：boost 翻转不写 _fullload_latched（fullload_flips 计数不动）",
		DebugStats.get_counter(&"fullload_flips") == flips0,
		"flips +%d" % (DebugStats.get_counter(&"fullload_flips") - flips0))
	PerfGovernor.boost_override = -1
	e._apply_fullload_decor()
	_check("C1行为：boost 关 → 皇冠复显（_ensure_* want 语义单源复显）",
		e._crown != null and e._crown.visible, "")
	_check("C1翻N 全程不增（boost 开关往返零计数）",
		DebugStats.get_counter(&"fullload_flips") == flips0, "")
	# 既有满载门逐位：fullload_override=1（关 boost）也隐——本体消费零波及
	Enemy.fullload_override = 1
	e._apply_fullload_decor()
	_check("C1既有满载门：fullload=1 → 皇冠隐藏（R225 语义原文保留）",
		e._crown != null and e._crown.visible == false, "")
	Enemy.fullload_override = -1
	e._apply_fullload_decor()
	_check("C1既有满载门：回落 → 复显",
		e._crown != null and e._crown.visible, "")
	# fullload_dim 本体消费点零波及：_state_fx_q 不因 boost 归 0（仍走 fullload_dim）
	_check("C1本体零波及：_state_fx_q() 不读 boost（fullload 0 → _fx_q() 现值——boost 关态档 2）",
		Enemy._state_fx_q() == 2, "sq=%d" % Enemy._state_fx_q())


# ── 收尾 ───────────────────────────────────────────────────────────

func _cleanup() -> void:
	PerfGovernor.boost_override = -1
	PerfGovernor.mode_override = -1
	PerfGovernor.tier_override = -1
	PerfGovernor.tier = 3
	PerfGovernor.set_process(true)
	PerfGovernor._test_reset()
	Enemy.deathpop_cap_override = -1
	Enemy.fullload_override = -1
	Enemy._fullload_latched = false
	_drain_registry()
	Meta._settings = _saved_settings           # 入口快照还原（磁盘不留测试痕）
	Meta.boost_intro_seen = false              # 修3：seen/待播复位（consume 落盘标志随下方 _save 冲销）
	Meta._boost_intro_pending = false
	Meta._save()
	if _host != null:
		_host.free()
		_host = null
	if _gl != null:
		_gl.free()
		_gl = null

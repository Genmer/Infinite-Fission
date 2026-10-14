# tests/qa_r270_menuscope_cases.gd
# R270 用例体（入口 tests/qa_r270_menuscope.gd 运行时 load——-s 编译期禁引工程类名纪律）。
# 覆盖：
# · m1-m10 修复①状态域矩阵：MENU/BOOT/GAME_OVER 恒全分辨率（720×1280+zoom1+div1.0）；
#   PLAYING/PAUSED/LEVEL_UP 活战态应用降档；设置热切在 MENU 态零应用；change_state
#   迁移钩子收放（真实迁移链驱动，非直调应用器）；cloud 除数与画布一致（菜单 1.0）。
# · f1-f4 修复②真路径敌弹计数：真敌 _fire_at（非夹具直调 acquire）→ team1_live/recount
#   同步 +1、bullet.team==1；帽门真路径拒绝（team1_live 注入 320 → 开火不落弹、计数不动）；
#   release 归还 −1；recount 自愈归零。定谳 vc79 真机 敌弹0/拒0=敌弹活口稀少非计数断链。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const ENEMY_SRC := "res://scripts/entities/enemy/enemy.gd"

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null
var _saved_settings: Dictionary = {}


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_saved_settings = Meta._settings.duplicate()      # 入口快照（收尾还原——磁盘不留测试痕）
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "R270MenuScopeGameLoop"
	tree.get_root().add_child(_gl)              # _ready → boot（池预热/事件链全环）
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
	Meta.set_setting("perf_boost", 1)           # 模式开（mobile 首启口径）
	Meta.set_setting("boost_res", 85)
	_test_m_menu_scope()
	await _test_s_settings_fit()
	_test_f_real_fire_path()
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


func _win_css() -> Vector2i:
	return _gl.get_window().content_scale_size


func _zoom() -> Vector2:
	return _gl.camera.zoom


# ── m1-m10 修复①：状态域分辨率矩阵（真实 change_state 迁移链驱动） ────

func _test_m_menu_scope() -> void:
	print("── m 状态域矩阵：MENU/结算全分辨率 ↔ 活战态降档 ──")
	var base := Vector2i(720, 1280)
	# m0 归位 MENU（boot 后本态；从 BOOT 只许 →MENU，直写归位同 qa_r269 先例）
	_gl.state = GameConst.GameStatus.MENU
	PerfGovernor.boost_override = 1
	_gl._apply_boost_resolution()
	_check("m1 菜单域恒全分辨率：模式开 ∧ MENU → css==(720,1280) ∧ zoom==1.0 ∧ div==1.0",
		_win_css() == base and _zoom() == Vector2.ONE
			and is_equal_approx(GameLoop.boost_world_div(), 1.0),
		"css=%s zoom=%s div=%s" % [str(_win_css()), str(_zoom()), str(GameLoop.boost_world_div())])
	var vis: Vector2 = _gl.get_viewport().get_visible_rect().size
	_check("m2 菜单域云恒等：vis/div == vis（div=1.0 浮点逐位——r195 口径在菜单域保持）",
		vis / GameLoop.boost_world_div() == vis, "vis=%s" % str(vis))
	# m3 进活战态：迁移钩子应用降档（真链 MENU→PLAYING）
	_check("m3 迁移链 MENU→PLAYING 成功（钩子路径）",
		_gl.change_state(GameConst.GameStatus.PLAYING), "state=%d" % _gl.state)
	_check("m4 活战态应用：css==(612,1088) ∧ zoom==(0.85,0.85) ∧ div≈0.85",
		_win_css() == Vector2i(612, 1088) and _zoom() == Vector2(0.85, 0.85)
			and is_equal_approx(GameLoop.boost_world_div(), 0.85),
		"css=%s zoom=%s div=%s" % [str(_win_css()), str(_zoom()), str(GameLoop.boost_world_div())])
	_check("m5 战内冻结态保持：PLAYING→LEVEL_UP → 降档不收（世界画面仍在）",
		_gl.change_state(GameConst.GameStatus.LEVEL_UP)
			and _win_css() == Vector2i(612, 1088) and _zoom() == Vector2(0.85, 0.85),
		"css=%s zoom=%s" % [str(_win_css()), str(_zoom())])
	_check("m6 收卡回战保持：LEVEL_UP→PLAYING → 仍 612×1088（幂等零写）",
		_gl.change_state(GameConst.GameStatus.PLAYING)
			and _win_css() == Vector2i(612, 1088) and _zoom() == Vector2(0.85, 0.85),
		"css=%s zoom=%s" % [str(_win_css()), str(_zoom())])
	_check("m7 结算域回全分辨率：PLAYING→GAME_OVER → css==(720,1280) ∧ zoom==1.0 ∧ div==1.0",
		_gl.change_state(GameConst.GameStatus.GAME_OVER)
			and _win_css() == base and _zoom() == Vector2.ONE
			and is_equal_approx(GameLoop.boost_world_div(), 1.0),
		"css=%s zoom=%s div=%s" % [str(_win_css()), str(_zoom()), str(GameLoop.boost_world_div())])
	_check("m8 回菜单保持全分辨率：GAME_OVER→MENU → 720×1280（主页域=回归修复目标位）",
		_gl.change_state(GameConst.GameStatus.MENU)
			and _win_css() == base and _zoom() == Vector2.ONE,
		"css=%s zoom=%s" % [str(_win_css()), str(_zoom())])
	# m9 菜单域设置热切零应用：档写 75（emit→应用器）→ 菜单域门赢，窗口不动
	Meta.set_setting("boost_res", 75)
	_check("m9 菜单域热切零应用：写 75 档 → css 仍==(720,1280)（活战态门优先于设置）",
		_win_css() == base, "css=%s" % str(_win_css()))
	# m10 再入活战态按新档应用（75）→ 出战收放闭环
	_gl.change_state(GameConst.GameStatus.PLAYING)
	_check("m10 再战按新档：入 PLAYING → css==(540,960) ∧ zoom==(0.75,0.75) ∧ div≈0.75",
		_win_css() == Vector2i(540, 960) and _zoom() == Vector2(0.75, 0.75)
			and is_equal_approx(GameLoop.boost_world_div(), 0.75),
		"css=%s zoom=%s div=%s" % [str(_win_css()), str(_zoom()), str(GameLoop.boost_world_div())])
	# m11 修P2 回归：迁移信号期除数一致——content_scale_size 赋值同步发射 size_changed
	# （cloud 铺域 handler 即时读除数），镜像必须先于视口写（晚写=信号期读旧档）。
	# lambda 捕贝坑（R68 先例）：容器变异收集，勿重绑标量。
	_gl.change_state(GameConst.GameStatus.GAME_OVER)   # 回菜单域（恢复 720×1280）
	_gl.change_state(GameConst.GameStatus.MENU)
	Meta.set_setting("boost_res", 85)
	PerfGovernor.boost_override = 1            # 菜单域零应用（m9 口径）——只待迁移写入
	var sig_div: Array = []
	var handler := func() -> void: sig_div.append(GameLoop.boost_world_div())
	var vp := _gl.get_viewport()
	vp.size_changed.connect(handler)
	_gl.change_state(GameConst.GameStatus.PLAYING)
	vp.size_changed.disconnect(handler)
	_check("m11 迁移信号期除数一致：MENU→PLAYING 尺寸信号瞬间 div≈0.85（非旧档 1.0）",
		sig_div.size() >= 1 and is_equal_approx(float(sig_div[0]), 0.85),
		"sig_div=%s" % str(sig_div))
	# 收尾归位：回菜单全分辨率 + 关模式基线（保既有套件口径）
	_gl.change_state(GameConst.GameStatus.GAME_OVER)
	_gl.change_state(GameConst.GameStatus.MENU)
	PerfGovernor.boost_override = -1
	_gl._apply_boost_resolution()               # 关模式基线（零写——已 0 档）


# ── s1-s3 修P1：设置卡降档画布适配（fit 缩放钩入果冻动画终态） ────────

func _test_s_settings_fit() -> void:
	print("── s 设置卡适配：fit=min(1, 画布宽/620, 画布高/1236) ──")
	var panel: CanvasLayer = load("res://scripts/ui/settings_panel.gd").new()
	panel.name = "R270SettingsFitProbe"
	tree.get_root().add_child(panel)           # _ready → _build_ui
	await tree.process_frame
	var card: Control = panel.get_node("SettingsRoot/SettingsCard")
	# s1 全分辨率域：fit=1.0 逐位（桌面默认/菜单域零扰动）
	PerfGovernor.boost_override = -1
	_gl.state = GameConst.GameStatus.MENU
	_gl._apply_boost_resolution()               # 关模式基线（幂等）
	panel.call("open")
	await tree.create_timer(0.45).timeout       # 果冻 0.34s 收尾后再断终态
	_check("s1 全分辨率域零扰动：open() 后卡 scale==ONE（fit=1.0）",
		card.scale == Vector2.ONE, "scale=%s" % str(card.scale))
	# s2 85 档：fit=min(612/620, 1088/1236)=0.8803（底半受限——围绕画布中心缩）；卡可视底入画
	PerfGovernor.boost_override = 1
	Meta.set_setting("boost_res", 85)
	_gl.change_state(GameConst.GameStatus.PLAYING)
	panel.call("open")
	await tree.create_timer(0.45).timeout       # 果冻 0.34s 收尾后再断终态
	var fit85 := 1088.0 / 1236.0
	_check("s2 85 档卡缩放：scale≈(%.4f,%.4f)（1088/1236 底半受限）" % [fit85, fit85],
		is_equal_approx(card.scale.x, fit85) and is_equal_approx(card.scale.y, fit85),
		"scale=%s" % str(card.scale))
	var tr85 := card.get_global_transform()
	var bottom85 := (tr85 * Rect2(Vector2.ZERO, card.size)).end.y
	var h85: float = panel.get_viewport().get_visible_rect().size.y
	_check("s2b 卡可视底入画：底 %.1f ≤ 画布高 %.1f（修P1——返回钮唯一关闭口）" % [bottom85, h85],
		bottom85 <= h85 + 0.5, "bottom=%.1f h=%.1f" % [bottom85, h85])
	# s3 75 档：fit=min(540/620, 960/1236)=0.7767（原整颗出屏=困面板档位）
	Meta.set_setting("boost_res", 75)
	_gl._apply_boost_resolution()               # 活战态热切（emit 驱动）
	panel.call("open")
	await tree.create_timer(0.45).timeout
	var fit75 := 960.0 / 1236.0
	var tr75 := card.get_global_transform()
	var bottom75 := (tr75 * Rect2(Vector2.ZERO, card.size)).end.y
	var h75: float = panel.get_viewport().get_visible_rect().size.y
	_check("s3 75 档卡缩放入画：scale≈%.4f ∧ 卡底 %.1f ≤ %.1f（960/1236）" % [fit75, bottom75, h75],
		is_equal_approx(card.scale.x, fit75) and bottom75 <= h75 + 0.5,
		"scale=%s bottom=%.1f h=%.1f" % [str(card.scale), bottom75, h75])
	# 收尾
	panel.call("close")
	panel.free()
	PerfGovernor.boost_override = -1
	Meta.set_setting("boost_res", 85)
	_gl.change_state(GameConst.GameStatus.GAME_OVER)
	_gl.change_state(GameConst.GameStatus.MENU)
	_gl._apply_boost_resolution()


# ── f1-f4 修复②：真路径敌弹计数（真敌 _fire_at——非夹具直调池） ────────

func _test_f_real_fire_path() -> void:
	print("── f 真路径敌弹计数：真敌开火 → 计数/实扫/帽门/归还 ──")
	var pool: ProjectilePool = _gl._projectile_pool
	if pool == null:
		_check("f0 前置：弹池可达（game_loop._projectile_pool）", false, "pool==null")
		return
	_check("f0 前置：弹池可达（game_loop._projectile_pool）", true, "")
	var enemy_script: GDScript = load(ENEMY_SRC)
	var e: Node2D = enemy_script.new()
	e.name = "R270FireProbeEnemy"
	e.position = Vector2(100.0, 100.0)
	tree.get_root().add_child(e)
	var dummy := Node2D.new()
	dummy.position = Vector2(320.0, 100.0)
	tree.get_root().add_child(dummy)
	e.set("projectile_pool", pool)
	e.set("bullet_speed", 240.0)
	e.set("spread_deg", 0.0)
	e.set("contact_dmg", 10.0)
	e.set("bullet_atk_ratio", 1.0)
	e.set("_aim_lead", false)
	var live0: int = pool.team1_live
	var rc0: int = pool.recount_team1()
	var active0: int = pool.active_projectiles().size()
	e.call("_fire_at", dummy)
	var bullet: Node = null
	for p in pool.active_projectiles():
		if int(p.get("team")) == 1 and not _is_probe_bullet_marked(p):
			bullet = p
	_check("f1 真路径计数：真敌 _fire_at → team1_live +1（acquire 参计数环）",
		pool.team1_live == live0 + 1, "live %d→%d" % [live0, pool.team1_live])
	_check("f2 真路径实扫：recount_team1() == rc+1（spawn 期 team=1 赋值与计数同调）",
		pool.recount_team1() == rc0 + 1, "rc %d→%d" % [rc0, pool.recount_team1()])
	_check("f3 真路径落弹：活弹 +1 且新敌弹 team==1",
		pool.active_projectiles().size() == active0 + 1 and bullet != null,
		"active %d→%d bullet=%s" % [active0, pool.active_projectiles().size(),
			str(bullet)])
	# 帽门真路径：注入 320（测试通道直写计数器——a4 同款）→ boost 开 → 开火被拒
	PerfGovernor.boost_override = 1
	pool.team1_live = pool.BOOST_TEAM1_CAP
	var live_capped: int = pool.team1_live
	var active_capped: int = pool.active_projectiles().size()
	e.call("_fire_at", dummy)
	_check("f4 帽门真路径拒绝：team1_live==320 ∧ boost 开 → 再开火零落弹且计数不动",
		pool.active_projectiles().size() == active_capped
			and pool.team1_live == live_capped,
		"active %d→%d live %d→%d" % [active_capped, pool.active_projectiles().size(),
			live_capped, pool.team1_live])
	# 归还与自愈：释放真弹 → recount 归真（注入位被实扫覆盖=自愈口径复证）
	PerfGovernor.boost_override = -1
	if bullet != null:
		pool.release(bullet)
	_check("f5 归还自愈：release 真弹 → recount_team1()==0（注入位被实扫覆盖）",
		pool.recount_team1() == 0, "rc=%d" % pool.recount_team1())
	e.queue_free()
	dummy.queue_free()


func _is_probe_bullet_marked(_p: Node) -> bool:
	return false


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
	Meta._settings = _saved_settings           # 入口快照还原（磁盘不留测试痕——qa_r269 同款）
	# R270 泄漏教训：仅快照还原不够——垫值/退出存档链会把 perf_boost 键再写回盘
	#（R269 已披露「垫值顺带落盘」行为），且本套件曾把 1 污染进盘档毒倒后续六套件
	#（boostmode a1 缺省/governor 承重墙全红）。收尾显式 erase 两键=盘面逐位回测前。
	Meta._settings.erase(&"perf_boost")
	Meta._settings.erase(&"boost_res")
	Meta.boost_intro_seen = false
	Meta._boost_intro_pending = false
	Meta._save()
	if _gl != null:
		_gl.free()
		_gl = null
	await tree.process_frame

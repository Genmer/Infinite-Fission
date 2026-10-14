extends RefCounted
# R260 QA 专项① cases（配套口 qa_r260_qa_pump.gd）——泵挂起/恢复完备性。
# 注意：D 组两条为【缺陷探针】——断言的是设计应有行为（面板已关=泵应恢复），
# FAIL 即缺陷证据（menu_screen.gd _on_map_pick/_on_daily_start 关面板不清位）。

const Prewarm := preload("res://scripts/cards/card_desc_prewarm.gd")

var _pass := 0
var _fail := 0
var _failures: Array[String] = []


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("  ok | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s %s" % [p_name, p_detail])
		print("  FAIL | %s %s" % [p_name, p_detail])


func run(p_tree: SceneTree) -> void:
	var gl_script: GDScript = load("res://scripts/loop/game_loop.gd")
	var gl = gl_script.new()
	gl.name = "GameLoopForR260QAPump"
	p_tree.get_root().add_child(gl)
	gl.set_physics_process(false)
	var waited := 0
	while not gl.boot_ready and waited < 600:
		await p_tree.process_frame
		waited += 1
	var menu = gl.menu_screen
	_check("A1 boot：菜单就绪+MENU 可见", menu != null and gl.boot_ready and menu.is_menu_visible())

	# ── A2 祝福三信号连接对账（防御收口 dismissed 没连=泵永久挂死的假设排查） ──
	var bles = gl.blessing_pick_ui
	_check("A2 祝福信号连接：confirmed/dismissed/cleared 三收口全接",
		bles.confirmed.is_connected(gl._on_blessing_confirmed)
		and bles.dismissed.is_connected(gl._on_blessing_dismissed)
		and bles.cleared.is_connected(gl._on_blessing_cleared))

	# ── B 组：六类大厅面板开合扫全（对账 _on_lobby_pressed 全 kind 置位/清位） ──
	var kinds := ["codex", "ach", "records", "char", "upgrade", "daily"]
	for kind in kinds:
		menu._on_lobby_pressed(String(kind))
		var opened_ok: bool = menu.card_desc_pump_paused()
		var codex_ok: bool = (not menu.codex_pump_paused()) if String(kind) == "codex" \
			else menu.codex_pump_paused()
		menu._on_panel_close()
		var closed_ok: bool = not menu.card_desc_pump_paused() and not menu.codex_pump_paused()
		_check("B[%s] 开=CardDesc 挂起（图鉴%s）+关=双泵恢复" % [String(kind),
				"豁免" if String(kind) == "codex" else "挂起"],
			opened_ok and codex_ok and closed_ok)

	# ── C 组：_process 实泵动态门（读真实进度而非观测口镜像） ──
	# C1 CardDesc：大厅期真消化 / 面板期真停 / 关后真恢复
	Prewarm.reset_for_tests()
	for i in range(5):
		menu._process(0.016)
	var total0: int = Prewarm.total_built()
	var rem0: int = Prewarm.remaining()
	_check("C1a CardDesc 实泵：大厅 5 帧建队+消化（total=%d rem=%d）" % [total0, rem0],
		total0 > 0 and rem0 < total0)
	menu._on_lobby_pressed("ach")
	for i in range(5):
		menu._process(0.016)
	var rem1: int = Prewarm.remaining()
	_check("C1b CardDesc 实泵：成就面板期 5 帧零消化", rem1 == rem0,
		"rem0=%d rem1=%d" % [rem0, rem1])
	menu._on_panel_close()
	for i in range(5):
		menu._process(0.016)
	_check("C1c CardDesc 实泵：回大厅 5 帧恢复消化", Prewarm.remaining() < rem1)

	# C2 图鉴泵：图鉴面板开着页缓存真增长 / 非图鉴面板期真停 / 祝福模态期真停
	menu._invalidate_codex_cache(true)
	menu._on_lobby_pressed("codex")
	var pages_open: int = menu._codex_page_cache.size()   # 开面板同步建当前页后的基线
	for i in range(60):
		menu._process(0.016)
	var pages_codex: int = menu._codex_page_cache.size()
	_check("C2a 图鉴实泵：图鉴面板开 60 帧页缓存增长（%d→%d）" % [pages_open, pages_codex],
		pages_codex > pages_open)
	menu._on_panel_close()
	menu._invalidate_codex_cache(true)
	menu._on_lobby_pressed("ach")
	var ach_pages0: int = menu._codex_page_cache.size()
	for i in range(40):
		menu._process(0.016)
	_check("C2b 图鉴实泵：成就面板期 40 帧零页产出（%d→%d）" % [ach_pages0,
			menu._codex_page_cache.size()],
		menu._codex_page_cache.size() == ach_pages0)
	menu._on_panel_close()
	menu._invalidate_codex_cache(true)
	menu.set_blessing_modal(true)
	var modal_pages0: int = menu._codex_page_cache.size()
	for i in range(40):
		menu._process(0.016)
	_check("C2c 图鉴实泵：祝福模态期 40 帧零页产出（%d→%d）" % [modal_pages0,
			menu._codex_page_cache.size()],
		menu._codex_page_cache.size() == modal_pages0)
	menu.set_blessing_modal(false)
	for i in range(60):
		menu._process(0.016)
	_check("C2d 图鉴实泵：模态收口后 60 帧恢复产出（%d→%d）" % [modal_pages0,
			menu._codex_page_cache.size()],
		menu._codex_page_cache.size() > modal_pages0)

	# ── D 组【缺陷探针】：绕过 _on_panel_close 的面板关闭路径 ──
	# D1 选关出发钮路径：_open_map_select → _on_map_pick（面板 visible=false 但不清位）
	if menu.start_map_requested.is_connected(gl._on_menu_start):
		menu.start_map_requested.disconnect(gl._on_menu_start)   # 探针隔离：阻断真实 start_run
	menu._open_map_select()
	var panel_shown: bool = menu._panel_root.visible and menu.card_desc_pump_paused()
	menu._on_map_pick(MapTable.FIRST_MAP_ID)
	var panel_hidden: bool = not menu._panel_root.visible
	var stale_flag: bool = menu.card_desc_pump_paused()
	_check("D1a【缺陷探针】选关出发后（面板已关）CardDesc 泵应恢复",
		panel_shown and panel_hidden and not stale_flag,
		"panel_shown=%s panel_hidden=%s 泵仍挂起=%s（_lobby_detail_open 残留）"
			% [str(panel_shown), str(panel_hidden), str(stale_flag)])
	# D1b 打完一局回大厅（模拟离场+回 MENU）——不清位则泵永久挂死
	menu._on_state_changed(GameConst.GameStatus.PLAYING)
	menu._on_state_changed(GameConst.GameStatus.MENU)
	_check("D1b【缺陷探针】离场再回大厅后（面板不可见）双泵应运行",
		not menu.card_desc_pump_paused() and not menu.codex_pump_paused(),
		"card=%s codex=%s（残留 _panel_kind=%s）" % [str(menu.card_desc_pump_paused()),
			str(menu.codex_pump_paused()), menu._panel_kind])
	# 收尾自愈路径取证：开任意面板再正常关闭=恢复（用户可用的绕过面）
	menu._on_lobby_pressed("ach")
	menu._on_panel_close()
	_check("D1c 缺陷可自愈：开面板+正常关=双泵恢复",
		not menu.card_desc_pump_paused() and not menu.codex_pump_paused())
	if not menu.start_map_requested.is_connected(gl._on_menu_start):
		menu.start_map_requested.connect(gl._on_menu_start)      # 还原接线

	# D2 每日出发钮路径：_on_lobby_pressed("daily") → _on_daily_start（同型漏口）
	if menu.start_daily_requested.is_connected(gl._on_menu_start_daily):
		menu.start_daily_requested.disconnect(gl._on_menu_start_daily)
	menu._on_lobby_pressed("daily")
	var daily_shown: bool = menu._panel_root.visible and menu.card_desc_pump_paused()
	menu._on_daily_start()
	_check("D2【缺陷探针】每日出发后（面板已关）CardDesc 泵应恢复",
		daily_shown and not menu._panel_root.visible and not menu.card_desc_pump_paused(),
		"面板已关但泵仍挂起=%s" % str(menu.card_desc_pump_paused()))
	menu._on_state_changed(GameConst.GameStatus.PLAYING)
	menu._on_state_changed(GameConst.GameStatus.MENU)
	menu._on_lobby_pressed("ach")
	menu._on_panel_close()
	if not menu.start_daily_requested.is_connected(gl._on_menu_start_daily):
		menu.start_daily_requested.connect(gl._on_menu_start_daily)

	# ── E 组：settings 独立屏泵态取证（大厅入口 → layer10 全屏 DIM 盖菜单） ──
	menu._on_lobby_pressed("settings")
	var settings_open: bool = gl.settings_panel != null and gl.settings_panel.is_open()
	_check("E1 settings 门（修轮 MED-1 后）：设置屏开+菜单在下可见+双泵挂起",
		settings_open and menu.is_menu_visible()
		and menu.card_desc_pump_paused() and menu.codex_pump_paused())
	if settings_open:
		gl.settings_panel.close()
	_check("E1b settings 门：设置关闭（closed 信号接线）=双泵恢复",
		not gl.settings_panel.is_open() and not menu.card_desc_pump_paused()
		and not menu.codex_pump_paused())

	# ── F 组：祝福链（真池接线口；放最后——收口会真实 start_run） ──
	Meta.codex_traits["AFF_CRIT_DMG"] = true
	Meta.codex_traits["AFF_CRIT_RATE"] = true
	var opened: bool = gl._try_open_blessing_pick()
	_check("F1 祝福链：面板开=双泵挂起（真池）",
		opened and bles.is_open() and menu.card_desc_pump_paused()
		and menu.codex_pump_paused())
	# F2 模态期二次出发（_on_menu_start 再入路径不经 set_blessing_modal——不变式：
	# _blessing_pending 真 ⇒ 模态位保持真）
	gl._on_menu_start(MapTable.FIRST_MAP_ID, 0)
	_check("F2 祝福链：模态期二次出发=面板保持开+泵保持挂起（不变式成立）",
		bles.is_open() and menu.card_desc_pump_paused() and menu.codex_pump_paused())
	# F3 防御收口：状态迁移强制 close+dismissed.emit → menu 泵恢复
	bles._on_state_changed(GameConst.GameStatus.PLAYING)
	_check("F3 祝福链：防御收口（状态迁移）=面板收+泵恢复+pending 清",
		not bles.is_open() and not menu.card_desc_pump_paused()
		and not menu.codex_pump_paused() and not gl._blessing_pending)

	# 夹具还原
	Meta.codex_traits.erase("AFF_CRIT_DMG")
	Meta.codex_traits.erase("AFF_CRIT_RATE")
	Meta._save()
	gl.free()
	print("专项①汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	for f in _failures:
		print("  FAIL | %s" % f)


func fail_count() -> int:
	return _fail

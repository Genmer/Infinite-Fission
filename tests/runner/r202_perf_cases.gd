# tests/runner/r202_perf_cases.gd
# R202 性能季·用例体（由 test_r202_perf.gd 入口在 autoload 就绪后运行时加载编译）。
# G4「帧率显示功能」（fpsFeature）验收——R202 注记断言：
#   域K 设置键契约：show_fps 双注册（SETTINGS_DEFAULTS 行 + _normalized_setting 分支，
#       缺一半静默失效——meta_manager.gd:217 口径）/ 旧档缺键回默认 false（零迁移）/
#       写口 bool 归一生效（int 1 → true，非静默丢弃）。
#   域F HUD 消费端：FpsLabel 急切创建于 _build_ui 期（boot 即在树——防 r198_hud_layout_
#       cases.gd:125-131 _toast_by_diff 按「HUD 直挂新 Label 子节点」差集误捕砸 T①~T⑧；
#       本标签挂 Root 子树本就不入该差集，双保险）/ 默认 visible=false / settings_changed
#       ("show_fps") 即时切 visible / boot 末段初值（存档 true → 二次 boot 即显示）/
#       _process 每帧刷新仅启用期挂起（关态 is_processing()==false 零每帧开销——本功能
#       的性能口径）/ 落位空带（右缘构筑面板 POS0 正下方 y470：与左上 HP/XP 簇、
#       readout(368,30)、pill 行、右上簇、底簇逐 Control 不相交 + R1 界内——G4 探针
#       probe_fps_band 实测空带）。
#   域S 设置面板行：「显示帧率」行塞卡不扩卡高（offset_bottom 618 / 卡高 968 钉死；
#       滑条行距 92→84 + 开关行距 74→66 重排）/ 行文案与 ✓/✗ 态（_refresh_toggles）/
#       pressed.emit() 键翻转（verify_feedback_cases.gd:2417-2421 先例）/ 七开关行按钮
#       互不重叠 + 末行底 ≤ hint 顶 + 关闭钮底 ≤ 卡底（行距重排的几何底线）。
# 纪律：headless 测试档隔离（meta_save_test.cfg）；快照还原走「直写 + 手动重应用」
#   （show_fps 消费端在 HUD——直写 Meta._settings 不发信号会留旧值，restore 后显式
#   调 hud._apply_show_fps() 收口，meta_manager 缺省盲区注释口径）。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	var saved_settings: Dictionary = Meta._settings.duplicate()
	# 确定性净场（写口复位）：测试档跨套件/跨轮残留 show_fps=true 会污染 F③「boot 默认
	# 隐藏」断言——入口先归零（此时尚无 GL，无消费者需重应用）
	Meta.set_setting("show_fps", false)
	_test_key_contract()                           # 域K 键契约（无 GL 依赖）
	_boot_game_loop()
	await _test_hud_consumer()                     # 域F HUD 消费端
	await _test_settings_row()                     # 域S 设置面板行
	await _test_boot_initial_value(saved_settings) # 域F boot 末段初值（二次 boot）
	_teardown_game_loop()
	# 还原（无 GL 存活——直写 + 落盘即可，无消费者需手动重应用）+ 出口净场
	#（快照本身可能携带上轮脏档的 show_fps=true——出口归零防跨套件残留传染）
	Meta._settings = saved_settings
	Meta._save()
	Meta.set_setting("show_fps", false)
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)


func fail_count() -> int:
	return _fail


func pass_count() -> int:
	return _pass


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("PASS | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s %s" % [p_name, p_detail])
		print("FAIL | %s | %s" % [p_name, p_detail])


# ═══ 域K 设置键契约（R202：show_fps 双注册——缺一半静默失效） ═════════
func _test_key_contract() -> void:
	print("── 域K show_fps 键契约（双注册/缺键回退/bool 归一） ──")
	# 本段快照（段内自还原——K⑥ 磁盘回路后须复位，否则后续 boot 初值被本段污染）
	var saved_k: Dictionary = Meta._settings.duplicate()
	_check("R202 K①：SETTINGS_DEFAULTS 含 show_fps（读侧注册）",
		Meta.SETTINGS_DEFAULTS.has("show_fps"),
		str(Meta.SETTINGS_DEFAULTS.get("show_fps")))
	_check("R202 K②：出厂默认 false（关态起步——读数不默认骚扰）",
		not bool(Meta.SETTINGS_DEFAULTS.get("show_fps")))
	# 旧档缺键：清空读口 → 默认表回退（零迁移）
	Meta._settings = {}
	_check("R202 K③：旧档缺键读口回退 false（降级不崩，零迁移）",
		not bool(Meta.settings("show_fps")))
	# 写口 bool 归一（_normalized_setting 分支——缺分支则静默丢弃读回默认 false）
	Meta.set_setting("show_fps", true)
	_check("R202 K④：写口 true 写入生效（bool 归一，非静默丢弃）",
		bool(Meta.settings("show_fps")))
	Meta.set_setting("show_fps", 1)
	_check("R202 K⑤：写口 int 1 → bool true 归一（match 分支 bool(p_value)）",
		bool(Meta.settings("show_fps")))
	# 持久化回路（settings 段加键、结构禁改——_save 档格式不动）
	Meta.set_setting("show_fps", true)
	Meta._load()
	_check("R202 K⑥：持久化（true 过 user:// 磁盘写读回路）",
		bool(Meta.settings("show_fps")))
	# 段内还原（直写 + 落盘；此时尚无 GL——无消费者需手动重应用）
	Meta._settings = saved_k
	Meta._save()


# ═══ 域F HUD 消费端（R202：急切创建 + visible 切换 + 空带落位） ═══════
func _test_hud_consumer() -> void:
	print("── 域F HUD FPS 读数（急切创建/visible 切换/空带/仅启用刷新） ──")
	var hud: HUD = _gl.hud
	# F① 急切创建：boot 后即在树（不待开关触发——懒创建会被 r198 toast 差集误捕）
	_check("R202 F①：FpsLabel 急切创建于 _build_ui 期（boot 即在树）",
		hud._fps_label != null
		and hud._hud_root.find_child("FpsLabel", true, false) == hud._fps_label)
	# F② 挂 Root 子树（非 HUD CanvasLayer 直挂——r198 _toast_by_diff 只扫直挂子件，
	#    双保险：即便日后有人改成直挂，急切创建仍保证 boot 期已在差集基线内）
	_check("R202 F②：FpsLabel 挂 HUD Root 子树（不入 toast 差集域）",
		hud._fps_label != null and hud._fps_label.get_parent() == hud._hud_root)
	# F③ 默认态：visible==false + 关态零每帧开销（set_process(false)——性能口径）
	_check("R202 F③：默认隐藏（show_fps 出厂 false → boot 末段初值收口）",
		not hud._fps_label.visible)
	_check("R202 F④：关态 is_processing()==false（_process 仅启用期挂起，零常驻开销）",
		not hud.is_processing())
	# F④ 落位空带：与全部持久 HUD 簇逐 Control 不相交（探针 probe_fps_band 实测空带：
	#    右缘构筑面板 POS0（y196-454）正下方 y470——避开左上 HP/XP 簇 r195_layout R2
	#    对与 _r187_readout(368,30)）
	var fps_rect: Rect2 = hud._fps_label.get_global_rect()
	var vis := tree.root.get_visible_rect()
	_check("R202 F⑤：R1 界内（rect ⊆ visible_rect+2px，右缘锚任意尺寸贴沿）",
		vis.grow(2.0).encloses(fps_rect), "rect=%s vis=%s" % [str(fps_rect), str(vis)])
	var neighbors: Array = [
		hud._hp_fill.get_parent(), hud._xp_fill.get_parent(), hud._revive_badge,
		hud._r187_readout, hud._kill_label, hud._time_label, hud._gold_label,
		hud._shield_panel, hud._wave_label.get_parent(), hud._pause_btn,
		hud._auto_btn, hud._auto_capsule, hud._skill_btn, hud._tb_panel,
		hud._boss_banner, hud._state_label, hud._revive_banner,
		hud._hud_root.find_child("BuildPanel", true, false),
	]
	var overlapped: Array[String] = []
	for n in neighbors:
		var c := n as Control
		if c != null and fps_rect.intersects(c.get_global_rect()):
			overlapped.append(String(c.name))
	_check("R202 F⑥：空带落位（与 %d 个持久 HUD 簇零相交，重叠=%s）"
		% [neighbors.size(), str(overlapped)],
		overlapped.is_empty(), str(overlapped))
	_check("R202 F⑦：右缘锚（anchor_l/r==1——宽视口贴沿；R208 拓宽 offset −290/−16=274px 装下 dc/o 诊断行）",
		hud._fps_label.anchor_left == 1.0 and hud._fps_label.anchor_right == 1.0
		and hud._fps_label.offset_right == -16.0 and hud._fps_label.offset_left == -290.0)
	# F⑤ 开启链：set_setting → settings_changed("show_fps") → visible 即时 true + 刷新挂起
	Meta.set_setting("show_fps", true)
	_check("R202 F⑧：settings_changed 即时切 visible（true → 显示）",
		hud._fps_label.visible)
	_check("R202 F⑨：开态 is_processing()==true（_process 每帧刷新挂起）",
		hud.is_processing())
	await tree.process_frame
	await tree.process_frame
	_check("R202 F⑩：开态 _process 刷新（text 前缀 \"FPS\"——Engine 平滑读数）",
		hud._fps_label.text.begins_with("FPS"),
		"text=%s" % hud._fps_label.text)
	# 关闭链
	Meta.set_setting("show_fps", false)
	_check("R202 F⑪：settings_changed 即时切 visible（false → 隐藏 + set_process(false)）",
		not hud._fps_label.visible and not hud.is_processing())
	# 其他键不误触（键守卫——panel_pos 等写口不切 FPS 读数）
	var vis_before: bool = hud._fps_label.visible
	Meta.set_setting("panel_pos", int(Meta.settings("panel_pos")))
	_check("R202 F⑫：非 show_fps 键不误触（panel_pos 写口零影响）",
		hud._fps_label.visible == vis_before)
	# 还原（直写盲区收口：本段写口已把 show_fps 复位 false，消费端已同步——无需手动重应用）


# ═══ 域S 设置面板行（R202：「显示帧率」塞卡不扩卡高） ═════════════════
func _test_settings_row() -> void:
	print("── 域S 设置面板「显示帧率」行（不扩卡高/行距重排/键翻转） ──")
	var sp: SettingsPanel = _gl.settings_panel
	Meta.set_setting("show_fps", false)
	sp.open()
	await tree.process_frame
	# S① 行在卡内（按钮 + 行文案）
	var row_label: Label = null
	for kid in sp._card.get_children():
		var l := kid as Label
		if l != null and l.text == "显示帧率":
			row_label = l
	_check("R202 S①：行文案「显示帧率」在卡（左标签）", row_label != null)
	_check("R202 S②：开关按钮在卡（ShowFpsToggleButton）",
		sp._show_fps_btn != null and sp._show_fps_btn.text == "✗ 关",
		"text=%s" % (sp._show_fps_btn.text if sp._show_fps_btn != null else "null"))
	# S② 卡高不扩（规格钉死：offset_bottom 618 / 卡高 968——abs 底 1258/1280 仅余 22px）
	_check("R202 S③：卡高不扩（offset_bottom==618 ∧ 卡高 968 钉死）",
		sp._card.offset_bottom == 618.0 and absf(sp._card.size.y - 968.0) < 0.01,
		"b=%s h=%s" % [str(sp._card.offset_bottom), str(sp._card.size.y)])
	# S③ hint/关闭钮原位不动（重排只动行距，不动收尾件）
	var hint: Label = null
	for kid in sp._card.get_children():
		var l2 := kid as Label
		if l2 != null and l2.text.begins_with("设置即存"):
			hint = l2
	var close_btn: Button = sp._root.find_child("SettingsCloseButton", true, false) as Button
	_check("R202 S④：hint y824 / 关闭钮 y872 原位不动（收尾件零位移）",
		hint != null and close_btn != null and absf(hint.position.y - 824.0) < 0.01
		and absf(close_btn.position.y - 872.0) < 0.01,
		"hint_y=%s close_y=%s" % [str(hint.position.y if hint != null else -1.0),
			str(close_btn.position.y if close_btn != null else -1.0)])
	# S④ 开关行布局对拍 + 末行底 ≤ hint 顶 + 关闭钮底 ≤ 卡底
	# 〔R271 追认声明式迁移〕原 S⑤「七开关行 get_rect 互不重叠」断言过期：R269 增至
	# 十一行（settings_panel.gd:143-147 布局法条：330..770 行距 44=钮标称高——设计
	# 口径贴排零重叠），而本套件自设窗 CANVAS_ITEMS×0.75（_normalize_window_for_boot）
	# 下「◉ 右上」字形光栅行高 +2px → PanelPosButton min 高钳 44→46，与 CodexReset
	# 实际 rect 重叠恰 2px。三态探针实测（同进程）：产品默认 viewport 模式
	# min=(97,44) h=44 深度=0 零重叠；CANVAS_ITEMS 0.75 窗 min=(97,46)；还原后复 44
	# ——重叠为套件量测环境的光栅伪影，非布局缺陷，产品态无遮挡（行位逐位精确）。
	# 迁移=①行布局对拍（y 表 330+44·i 逐位 + 均匀行距 44≥标称钮高 → 设计尺度零重叠
	# ——原「行距重排零重叠」语义的强形式）②实测相邻重叠深度 ≤2px（伪影有界化，
	# >2px=真布局回归）③非相邻对严格零重叠（防跨行错位遮挡）。
	var rows: Array = [sp._fx_btn, sp._fps_btn, sp._perf_mode_btn, sp._boost_btn,
		sp._shake_btn, sp._dmg_btn, sp._show_fps_btn, sp._diag_log_btn,
		sp._diag_len_btn, sp._pos_btn, sp._codex_reset_btn]
	var all_present := true
	for b in rows:
		if b == null:
			all_present = false
	var y_table_ok := true
	var spacing_ok := true
	var adj_depth_max := 0.0
	var bad_pairs: Array[String] = []
	if all_present:
		for i in range(rows.size()):
			var rc: Control = rows[i] as Control
			if absf(rc.get_rect().position.y - (330.0 + 44.0 * i)) > 0.01:
				y_table_ok = false
			if i > 0:
				var prev: Control = rows[i - 1] as Control
				var gap := rc.get_rect().position.y - prev.get_rect().position.y
				if absf(gap - 44.0) > 0.01:
					spacing_ok = false
				adj_depth_max = maxf(adj_depth_max,
					prev.get_rect().position.y + prev.get_rect().size.y
					- rc.get_rect().position.y)
			for j in range(i + 2, rows.size()):
				var ra := rows[i] as Control
				var rb := rows[j] as Control
				if ra.get_rect().intersects(rb.get_rect()):
					bad_pairs.append("%s∩%s" % [ra.name, rb.name])
	_check("R202 S⑤a：开关行布局对拍（11 行 y=330+44·i 逐位 ∧ 均匀行距 44=标称钮高贴排）",
		all_present and y_table_ok and spacing_ok,
		"y表=%s 行距均匀=%s" % [str(y_table_ok), str(spacing_ok)])
	_check("R202 S⑤b：行零重叠（设计尺度行距 44≥标称钮高；CANVAS_ITEMS×0.75 光栅伪影界 ≤2px；非相邻=%s）"
		% str(bad_pairs),
		all_present and adj_depth_max <= 2.0 + 0.01 and bad_pairs.is_empty(),
		"相邻深度=%.2f 非相邻重叠=%s" % [adj_depth_max, str(bad_pairs)])
	var last_btn: Control = rows[rows.size() - 1] as Control if not rows.is_empty() else null
	var last_bottom: float = last_btn.position.y + last_btn.size.y if last_btn != null else 9999.0
	_check("R202 S⑥：末行按钮底 %.0f ≤ hint 顶 824（8px 缝，卡内不溢）" % last_bottom,
		all_present and last_bottom <= 824.0 + 0.01,
		"bottom=%s" % str(last_bottom))
	var close_bottom: float = close_btn.position.y + close_btn.size.y if close_btn != null else -1.0
	_check("R202 S⑦：关闭钮底 940 ≤ 卡底 968（28px 底缘余量保持）",
		close_btn != null and close_bottom <= 968.0 + 0.01, "bottom=%s" % str(close_bottom))
	# S⑤ pressed.emit() 键翻转（verify_feedback_cases.gd:2417-2421 先例）
	var before: bool = bool(Meta.settings("show_fps"))
	sp._show_fps_btn.pressed.emit()
	_check("R202 S⑧：开关点击 → show_fps 翻转（true）",
		bool(Meta.settings("show_fps")) != before)
	_check("R202 S⑨：翻转后按钮 ✓ 态（✓ 开 + 薄荷绿）",
		sp._show_fps_btn.text == "✓ 开")
	sp._show_fps_btn.pressed.emit()
	_check("R202 S⑩：开关再点 → 复位原值（false）+ ✗ 态（✗ 关 + 弱化灰）",
		bool(Meta.settings("show_fps")) == before and sp._show_fps_btn.text == "✗ 关")
	# S⑥ HUD 联动（点击链已过 settings_changed → FpsLabel visible 同步）
	_check("R202 S⑪：面板点击链联动 HUD（复位 false → FpsLabel 隐藏）",
		not _gl.hud._fps_label.visible)
	sp.close()


# ═══ 域F boot 末段初值（R202：存档 true → 二次 boot 即显示） ═══════════
func _test_boot_initial_value(p_saved_settings: Dictionary) -> void:
	print("── 域F boot 末段初值（存档值 → 新 boot 即生效） ──")
	_teardown_game_loop()                          # 释第一个 GL（EventBus 单例订阅不双挂）
	Meta.set_setting("show_fps", true)             # 存档侧置 true（写即存）
	_boot_game_loop()
	_check("R202 B①：存档 true → 新 boot FpsLabel 即显示（_build_ui 末段初值收口）",
		_gl.hud._fps_label != null and _gl.hud._fps_label.visible)
	_check("R202 B②：新 boot 开态 is_processing()==true（boot 初值同样挂起刷新）",
		_gl.hud.is_processing())
	_teardown_game_loop()
	# 还原存档值（无 GL 存活——直写 + 落盘；后续 run() 尾部统一快照还原双保险）
	Meta._settings = p_saved_settings.duplicate(true)
	Meta._save()
	_boot_game_loop()                              # 复位一个 GL 供后续（对称收口）


# ── 环境引导（r198/r195 口径） ─────────────────────────────────────
func _normalize_window_for_boot() -> void:
	var win: Window = tree.root
	win.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	match String(ProjectSettings.get_setting("display/window/stretch/aspect", "keep")):
		"keep_width":
			win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP_WIDTH
		"keep_height":
			win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP_HEIGHT
		"expand":
			win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
		"ignore":
			win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_IGNORE
		_:
			win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
	win.size = Vector2i(
		int(ProjectSettings.get_setting("display/window/size/window_width_override", 540)),
		int(ProjectSettings.get_setting("display/window/size/window_height_override", 960)))


func _boot_game_loop() -> void:
	_normalize_window_for_boot()
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "R202PerfGameLoopUnderTest"
	tree.get_root().add_child(_gl)
	_check("R202 前置：Boot 进入 MENU + 致命清单空",
		_gl.boot_ready and _gl.state == GameConst.GameStatus.MENU
		and _gl.boot_fatal.is_empty(), "fatal=%s" % str(_gl.boot_fatal))


func _teardown_game_loop() -> void:
	tree.paused = false
	RunSave.clear()
	if _gl != null:
		_gl.free()
		_gl = null

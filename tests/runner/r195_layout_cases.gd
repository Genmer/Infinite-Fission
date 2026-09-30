# tests/runner/r195_layout_cases.gd
# R195 多尺寸屏适配统包用例体（由 test_r195_layout.gd 入口在 autoload 就绪后运行时加载编译）。
# 七律矩阵（A2~A8 验收；复刻 test_r194_mobile.gd 入口模式：-s 脚本模式根窗口不应用工程
# stretch → boot 前归一为引擎 boot 等价位，断言全部读 canvas 域 rect）：
#   · 尺寸 7 档 = 720×1280/1440/1560/1600/1680（16:9~21:9）+ 960×1280（3:4 平板）
#     + 540×960（桌面默认窗，EXPAND≡KEEP）
#   · UI 态 7 个 = MENU / PLAYING / PAUSED / LEVEL_UP / GAME_OVER / 商店 open / 设置 open
#     （headless 经 change_state/request_pause/start_run + 各屏公开口直达）
#   七律 = R1 界内（get_global_rect ⊆ visible_rect+2px）/ R2 无重叠（簇配对 + 白名单
#     钉死）/ R3 全宽标签横向居中（|center_x−vis.center_x|≤2px，toast 重触发后再断言）/
#     R4 底簇贴底（技能 82 / 构筑 24 恒等 offset_bottom）/ R5 spawn 不入设计域
#     （收窄口径：采样点 ∉ [0,720]×[0,1280]）/ R6 dim.size==visible_rect 逐态 /
#     R7 触控目标逐尺寸不缩水（AUTO 56×64 / 暂停 72×72）
#   · 钳制用例 = 720×1800 回落（KEEP，origin.y≈260 居中黑边）/ 720×1680 满屏（EXPAND）/
#     KEEP↔EXPAND 运行时双向可逆 / project.godot aspect=keep 回退位等价（钳制零触发）
#   · safe-area 契约 = 守卫（headless 恒零）+ 源级 grep（mobile/全屏守卫、affine_inverse
#     换算、负值钳零、延迟读、重读信号）+ 八屏接入 grep + 映射纯函数注入等价校验 +
#     combat/entities 零视口读取维持
# 时序纪律：win.size 赋值后 await ≥2 帧再断言（同帧读旧值，探针实证）；resize 后
# _show_toast 重触发再断言；末尾 _gl.free() 防泄漏（r194 口径）。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const DESIGN_DOMAIN := Rect2(0.0, 0.0, 720.0, 1280.0)   # 逻辑域（F-01 钉死，data_validator fatal）
const R1_GROW := 2.0                            # R1 界内容差（验收口径 +2px）
const CENTER_TOL := 2.0                         # R3 居中容差
const EDGE_TOL := 2.0                           # R4 贴底容差
const SKILL_BOTTOM_BAND := 82.0                 # 技能钮底带（1280−1198，锚定恒等 offset_bottom）
# R196 有意契约变更（原 BUILD_BOTTOM_BAND 24.0）：构筑面板默认落位 POS0 右上
# （hud.gd _apply_build_panel_pos：锚 t/b=0、offset_top=196）——改钉 vis 顶带
const BUILD_TOP_BAND := 196.0
const CLAMP_RATIO_MAX := 2.34                   # 超限钳制阈值（game_loop 代码常量同源钉死）

# 矩阵尺寸（label, Vector2i）——7 档
const SIZES: Array = [
	["720x1280 基准16:9", Vector2i(720, 1280)],
	["720x1440 18:9", Vector2i(720, 1440)],
	["720x1560 19.5:9", Vector2i(720, 1560)],
	["720x1600 20:9", Vector2i(720, 1600)],
	["720x1680 21:9", Vector2i(720, 1680)],
	["960x1280 3:4平板", Vector2i(960, 1280)],
	["540x960 桌面默认窗", Vector2i(540, 960)],
]

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null
# 菜单全宽标签句柄（boot 后采集一次——锚定重排不改节点身份）
var _menu_logo: Control = null
var _menu_subtitle: Label = null
var _menu_announce: Array[Label] = []
var _menu_name_tag: Label = null
var _menu_footer: Label = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_boot_game_loop()
	_collect_menu_handles()
	_test_default_window_sanity()                 # 默认窗 EXPAND≡KEEP（A2 前置）
	for entry in SIZES:
		await _visit_size(entry[0], entry[1])     # 7 尺寸 × 7 态 × 七律
	await _test_stretch_clamp()                   # 钳制/回退位/双向可逆（A7）——协程须
                                                  # await 直驱（r195_adapt:400 同款）：丢 await
                                                  # 则首帧挂起即弃，钳制①-④永不执行（死区）
	await _test_target_bar_behavior()             # R198 契约变更新增（二aw-3）：TargetBar
                                                  # 行为半边（锁定/切换/掉血/死亡/续窗）
	await _test_safe_area_contract()              # safe-area 守卫+映射+grep（A8）
	_teardown_game_loop()
	# 汇总
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)


func fail_count() -> int:
	return _fail


# ── 环境引导 ──────────────────────────────────────────────────────
func _boot_game_loop() -> void:
	_normalize_window_for_boot()
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "R195GameLoopUnderTest"
	tree.get_root().add_child(_gl)
	_check("R195 前置：Boot 进入 MENU + 致命清单空",
		_gl.boot_ready and _gl.state == GameConst.GameStatus.MENU and _gl.boot_fatal.is_empty())


func _normalize_window_for_boot() -> void:
	# -s 脚本模式根窗口不应用工程 stretch（实测 64×64 / IGNORE，r194 同款归一）：
	# aspect 读 ProjectSettings 单源 + 默认窗 = override 540×960（引擎 boot 等价位）。
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


func _collect_menu_handles() -> void:
	# 菜单全宽标签采集（R3 menu×5+ 组：Logo/副标/公告行×3/name_tag/footer——按节点名
	# 与文案真源 Lore 定位，锚定重排不改身份）
	var menu: MenuScreen = _gl.menu_screen
	_menu_logo = menu._root.find_child("Logo", true, false) as Control
	for child in menu._root.get_children():
		var label := child as Label
		if label == null:
			continue
		if label.text == Lore.SUBTITLE:
			_menu_subtitle = label
		elif label.text == "竖屏弹幕防御 · Roguelike":
			_menu_footer = label
		elif Lore.MENU_LINES.has(label.text):
			_menu_announce.append(label)
	_menu_name_tag = menu.name_tag
	_check("R195 前置：菜单全宽标签句柄齐（Logo/副标/公告行/name_tag/footer）",
		_menu_logo != null and _menu_subtitle != null and _menu_announce.size() >= 1
		and _menu_name_tag != null and _menu_footer != null,
		"announce=%d" % _menu_announce.size())


func _teardown_game_loop() -> void:
	tree.paused = false
	RunSave.clear()
	_restore_window_default()
	if _gl != null:
		_gl.free()
		_gl = null


func _restore_window_default() -> void:
	# 环境还原（boot 等价位）：默认窗尺寸 + 工程 aspect（回退位归一重放）
	_normalize_window_for_boot()


func _vis() -> Rect2:
	return tree.root.get_visible_rect()


func _resize_and_settle(p_size: Vector2i) -> void:
	# 时序纪律：size 赋值后 await ≥2 帧再断言（同帧读旧值——探针实证）
	tree.root.size = p_size
	await tree.process_frame
	await tree.process_frame


func _state_settle() -> void:
	# 弹窗卡 squash_pop 出场动画沉降（弹性过冲 ~1.18×，约 0.3s——实测 720×1280 首访问
	# SettingsCard 在过冲帧测得 731×746）。create_timer 默认 process_always=true：
	# PAUSED/LEVEL_UP 挂起态照常推进（矩阵在暂停族态测量覆盖层）。
	await tree.process_frame
	await tree.create_timer(0.5).timeout
	await tree.process_frame


# ── UI 态直达（headless 经公开口；实现以实际公开口为准） ──────────
func _enter_menu() -> void:
	if _gl.state != GameConst.GameStatus.MENU:
		_gl.change_state(GameConst.GameStatus.MENU)   # GAME_OVER→MENU 等合法迁移


func _enter_playing() -> void:
	_enter_menu()
	_gl.call(&"start_run")


func _enter_paused() -> void:
	if _gl.state != GameConst.GameStatus.PAUSED:
		_gl.call(&"request_pause")


func _enter_settings() -> void:
	_gl.settings_panel.open()                     # 大厅/暂停卡双入口（纯 UI 层）


func _leave_settings() -> void:
	_gl.settings_panel.close()


func _enter_level_up() -> void:
	_gl.call(&"request_resume")                   # PAUSED→PLAYING
	_gl.change_state(GameConst.GameStatus.LEVEL_UP)
	var empty: Array[Dictionary] = []
	_gl.card_select_ui.open(empty)                # 货架直驱（标题/dim/容器几何）


func _leave_level_up() -> void:
	_gl.card_select_ui.close()


func _enter_shop() -> void:
	_gl.shop_ui.open(_gl.player, 5, false)


func _leave_shop() -> void:
	_gl.shop_ui.close()                           # closed → request_resume（LEVEL_UP→PLAYING）


func _enter_game_over() -> void:
	_gl.change_state(GameConst.GameStatus.GAME_OVER)
	_gl.game_over_screen.cancel_auto_countdown()  # 挂机倒计时钉住（断言期不自动重开）


# ── 默认窗健全性（A2 前置：540×960 下 EXPAND≡KEEP → vis=(720,1280)） ──
func _test_default_window_sanity() -> void:
	print("── R195 默认窗（540×960）EXPAND≡KEEP ──")
	var vis := _vis()
	_check("R195 默认窗：vis==(720,1280)（scale 0.75，桌面零影响）",
		vis.size == Vector2(720, 1280) and vis.position == Vector2.ZERO, str(vis))


# ── 单尺寸访问：7 态 × 七律 ──────────────────────────────────────
func _visit_size(p_label: String, p_size: Vector2i) -> void:
	print("── R195 矩阵 @%s ──" % p_label)
	await _resize_and_settle(p_size)
	var vis := _vis()
	_check("R195 @%s：visible_rect 输出（A2 逐尺寸断言）" % p_label,
		vis.position == Vector2.ZERO and vis.size.x > 0 and vis.size.y > 0, str(vis))
	# 态序：MENU → PLAYING → PAUSED → 设置 → LEVEL_UP → 商店 → GAME_OVER
	_enter_menu()
	await tree.process_frame
	_law_r1_menu(p_label)
	_law_r2_menu(p_label)
	_law_r3_menu(p_label)
	_law_r6(find_child_dim(_gl.menu_screen._root, "MenuBg"), p_label, "MENU")
	_enter_playing()
	await tree.process_frame
	_gl.hud._show_toast("R195 矩阵")             # resize 后重触发 toast（A3 时序纪律）
	_law_r1_playing(p_label)
	_law_r2_playing(p_label)
	_law_r3_playing(p_label)
	_law_r4_playing(p_label)
	_law_r6(_gl.hud._hud_root, p_label, "PLAYING")
	_law_r7(p_label)
	_law_r5(p_label)
	_enter_paused()
	await _state_settle()
	_law_r1_pair(_gl.pause_overlay._card, p_label, "PAUSED/PauseCard")
	_law_r6(_gl.pause_overlay._root.find_child("PauseDim", true, false), p_label, "PAUSED")
	_enter_settings()
	await _state_settle()
	_law_r1_pair(_gl.settings_panel._card, p_label, "SETTINGS/SettingsCard")
	_law_r2_settings(p_label)
	_law_r6(_gl.settings_panel._root.find_child("SettingsDim", true, false), p_label, "SETTINGS")
	_leave_settings()
	_enter_level_up()
	await _state_settle()
	_law_r1_level_up(p_label)
	_law_r2_level_up(p_label)
	_law_r3(_gl.card_select_ui._title, p_label, "LEVEL_UP/选卡标题")
	_law_r6(first_color_rect(_gl.card_select_ui._root), p_label, "LEVEL_UP")
	_leave_level_up()
	_enter_shop()
	await _state_settle()
	_law_r1_shop(p_label)
	_law_r2_shop(p_label)
	_law_r6(first_color_rect(_gl.shop_ui._root), p_label, "SHOP")
	_leave_shop()
	_enter_game_over()
	await _state_settle()
	_law_r1_pair(_gl.game_over_screen._card, p_label, "GAME_OVER/ReportCard")
	_law_r6(first_color_rect(_gl.game_over_screen._root), p_label, "GAME_OVER")
	# 收束回 MENU（GAME_OVER→MENU 合法迁移；paused 由 change_state 复位）
	_enter_menu()
	await tree.process_frame


# ── R1 界内（get_global_rect ⊆ visible_rect+2px） ─────────────────
func _law_r1_menu(p_label: String) -> void:
	var menu: MenuScreen = _gl.menu_screen
	_law_r1_pair(_menu_logo, p_label, "MENU/Logo")
	_law_r1_pair(_menu_subtitle, p_label, "MENU/副标")
	_law_r1_pair(_menu_name_tag, p_label, "MENU/name_tag")
	_law_r1_pair(_menu_footer, p_label, "MENU/footer")
	_law_r1_pair(menu._root.find_child("StartButton", true, false) as Control,
		p_label, "MENU/StartButton")


func _law_r1_playing(p_label: String) -> void:
	var hud: HUD = _gl.hud
	_law_r1_pair(hud._hp_fill.get_parent() as Control, p_label, "PLAYING/HpPanel")
	_law_r1_pair(hud._revive_badge, p_label, "PLAYING/ReviveBadge")
	_law_r1_pair(hud._level_label, p_label, "PLAYING/LevelText")
	_law_r1_pair(hud._wave_label, p_label, "PLAYING/WaveText")
	_law_r1_pair(hud._kill_label, p_label, "PLAYING/KillText")
	_law_r1_pair(hud._time_label, p_label, "PLAYING/TimeText")
	_law_r1_pair(hud._gold_label, p_label, "PLAYING/GoldText")
	_law_r1_pair(hud._pause_btn, p_label, "PLAYING/PauseButton")
	_law_r1_pair(hud._auto_btn, p_label, "PLAYING/AutoToggle")
	_law_r1_pair(hud._skill_btn, p_label, "PLAYING/SkillButton")
	_law_r1_pair(hud._tb_panel, p_label, "PLAYING/TargetBar")
	_law_r1_pair(hud._boss_banner, p_label, "PLAYING/BossBanner")
	_law_r1_pair(hud._state_label, p_label, "PLAYING/StateLabel")
	_law_r1_pair(hud._revive_banner, p_label, "PLAYING/ReviveBanner")
	_law_r1_pair(hud._hud_root.find_child("BuildPanel", true, false) as Control,
		p_label, "PLAYING/BuildPanel")


func _law_r1_level_up(p_label: String) -> void:
	_law_r1_pair(_gl.card_select_ui._title, p_label, "LEVEL_UP/title")
	_law_r1_pair(_gl.card_select_ui._reroll_btn, p_label, "LEVEL_UP/reroll")


func _law_r1_shop(p_label: String) -> void:
	var shop: ShopUi = _gl.shop_ui
	_law_r1_pair(shop._root.find_child("ShopCard", true, false) as Control,
		p_label, "SHOP/ShopCard")
	_law_r1_pair(shop._root.find_child("ShopRefreshButton", true, false) as Button,
		p_label, "SHOP/refresh_btn")
	_law_r1_pair(shop._root.find_child("ShopLeaveButton", true, false) as Button,
		p_label, "SHOP/leave_btn")


func _law_r1_pair(p_ctrl: Control, p_label: String, p_tag: String) -> void:
	if p_ctrl == null:
		_check("R1 %s @%s：%s 句柄非空" % [p_tag, p_label, p_tag], false, "null")
		return
	var ok := _vis().grow(R1_GROW).encloses(p_ctrl.get_global_rect())
	_check("R1 %s @%s：界内（⊆vis+2px）" % [p_tag, p_label], ok,
		"rect=%s vis=%s" % [str(p_ctrl.get_global_rect()), str(_vis())])


# ── R2 无重叠（簇配对；白名单钉死，数量+条目写死增量须评审） ────────
## 白名单（R198 契约变更：头注重写为实盘 3 对——grep 本套件 p_whitelisted=true 配对
## 全集，与 R195_SCREEN_ADAPT.md §3.3 登记集合一致；原头注所列「卡沿徽标同族 3 对」
## 系幽灵对——全套件并无该配对断言，表述已删）。
## 全部贴纸叠贴语言非缺陷：
## · ReviveBadge∩HP 条（设计钉死，hud R186 徽标贴血条右上）
## · R187Readout∩HP 条（超设计增量：R187 引入 R187Readout 后实际需要，R198 补登评审）
## · SettingsCard∩SettingsGlyph（设计钉死，settings_panel 徽标压卡沿 (268,−40)）
func _law_r2_playing(p_label: String) -> void:
	var hud: HUD = _gl.hud
	var hp_panel := hud._hp_fill.get_parent() as Control
	var xp_panel := hud._xp_fill.get_parent() as Control
	# 左上簇（pill 行 + 血/经验条）
	_pair_law(hp_panel, xp_panel, p_label, "PLAYING", false)
	_pair_law(hud._kill_label, hud._time_label, p_label, "PLAYING", false)
	_pair_law(hud._time_label, hud._gold_label, p_label, "PLAYING", false)
	_pair_law(hud._kill_label, hud._gold_label, p_label, "PLAYING", false)
	# 右上簇（徽章/暂停/AUTO——A4 互簇矩形不相交 r188 口径）
	_pair_law(hud._pause_btn, hud._auto_btn, p_label, "PLAYING", false)
	_pair_law(hud._wave_label, hud._pause_btn, p_label, "PLAYING", false)
	_pair_law(hud._wave_label, hud._auto_btn, p_label, "PLAYING", false)
	# 白名单钉死对（不参与红/绿——存在性钉进断言，防白名单静默漂移）
	_pair_law(hud._revive_badge, hp_panel, p_label, "PLAYING", true)
	_pair_law(hud._r187_readout, hp_panel, p_label, "PLAYING", true)


func _law_r2_settings(p_label: String) -> void:
	_pair_law(_gl.settings_panel._card,
		_gl.settings_panel._root.find_child("SettingsGlyph", true, false) as Control,
		p_label, "SETTINGS", true)                # 白名单钉死：卡沿徽标


func _law_r2_level_up(p_label: String) -> void:
	_pair_law(_gl.card_select_ui._title, _gl.card_select_ui._reroll_btn,
		p_label, "LEVEL_UP", false)


func _law_r2_shop(p_label: String) -> void:
	var shop: ShopUi = _gl.shop_ui
	_pair_law(shop._root.find_child("ShopRefreshButton", true, false) as Button,
		shop._root.find_child("ShopLeaveButton", true, false) as Button,
		p_label, "SHOP", false)


func _law_r2_menu(p_label: String) -> void:
	if _menu_announce.size() >= 1:
		_pair_law(_menu_subtitle, _menu_announce[0], p_label, "MENU", false)
	if _menu_announce.size() >= 3:
		_pair_law(_menu_announce[_menu_announce.size() - 1], _menu_name_tag,
			p_label, "MENU", false)
	_pair_law(_menu_name_tag,
		_gl.menu_screen._root.find_child("StartButton", true, false) as Control,
		p_label, "MENU", false)


func _pair_law(p_a: Control, p_b: Control, p_label: String, p_state: String,
		p_whitelisted: bool) -> void:
	if p_a == null or p_b == null:
		_check("R2 %s @%s：配对句柄非空（%s/%s）" % [p_state, p_label,
			str(p_a), str(p_b)], false, "null")
		return
	var overlaps := (p_a as Control).get_global_rect().intersects((p_b as Control).get_global_rect())
	if p_whitelisted:
		# 白名单对：钉存在性（贴纸叠贴语言）——重叠消失/易位即提示复审（不红）
		_check("R2 白名单对 @%s %s：钉存在（%s∩%s，贴纸叠贴）" % [p_label, p_state,
			(p_a as Control).name, (p_b as Control).name], true,
			"overlaps=%s" % str(overlaps))
	else:
		_check("R2 %s @%s：%s 与 %s 不相交" % [p_state, p_label,
			(p_a as Control).name, (p_b as Control).name], not overlaps,
			"a=%s b=%s" % [str((p_a as Control).get_global_rect()),
				str((p_b as Control).get_global_rect())])


# ── R3 全宽标签横向居中（|center_x−vis.center_x|≤2px） ────────────
func _law_r3_menu(p_label: String) -> void:
	_law_r3(_menu_logo, p_label, "MENU/Logo")
	_law_r3(_menu_subtitle, p_label, "MENU/副标")
	for i in _menu_announce.size():
		_law_r3(_menu_announce[i], p_label, "MENU/公告%d" % i)
	_law_r3(_menu_name_tag, p_label, "MENU/name_tag")
	_law_r3(_menu_footer, p_label, "MENU/footer")


func _law_r3_playing(p_label: String) -> void:
	var hud: HUD = _gl.hud
	_law_r3(hud._boss_banner, p_label, "PLAYING/BossBanner")
	_law_r3(hud._state_label, p_label, "PLAYING/StateLabel")
	_law_r3(hud._revive_banner, p_label, "PLAYING/ReviveBanner")
	_law_r3(hud._toast_label, p_label, "PLAYING/WaveToast(重触发)")
	# boss_bar 横幅（第 11 处全宽标签；root 隐藏态 rect 布局仍生效）
	_law_r3(_gl.boss_bar._banner, p_label, "PLAYING/BossBarBanner")


func _law_r3(p_ctrl: Control, p_label: String, p_tag: String) -> void:
	if p_ctrl == null:
		_check("R3 %s @%s：句柄非空" % [p_tag, p_label], false, "null")
		return
	var rect := p_ctrl.get_global_rect()
	var delta := absf(rect.position.x + rect.size.x * 0.5 - _vis().get_center().x)
	_check("R3 %s @%s：横向居中（≤%.0fpx）" % [p_tag, p_label, CENTER_TOL],
		delta <= CENTER_TOL, "delta=%.2f center_x=%.1f" % [delta, rect.get_center().x])


# ── R4 底簇贴底（offset_bottom 恒等 82/24） ───────────────────────
func _law_r4_playing(p_label: String) -> void:
	var hud: HUD = _gl.hud
	var vis_end_y := _vis().end.y
	var skill_gap := absf((vis_end_y - hud._skill_btn.get_global_rect().end.y) - SKILL_BOTTOM_BAND)
	var build := hud._hud_root.find_child("BuildPanel", true, false) as Control
	# R196 有意契约变更（原「构筑面板贴 vis 底带 24px」）：面板默认 POS0 右上，
	# 锚 t=0/offset_top=196 → 贴 vis 顶带 196px（任意分辨率锚定恒等，同原底带口径）
	var build_gap := absf((build.get_global_rect().position.y - _vis().position.y)
		- BUILD_TOP_BAND)
	_check("R4 @%s：技能钮贴 vis 底带 82px（±2）" % p_label, skill_gap <= EDGE_TOL,
		"gap=%.2f" % skill_gap)
	_check("R4 @%s：构筑面板贴 vis 顶带 196px（±2，R196 POS0 右上默认落位）" % p_label,
		build_gap <= EDGE_TOL, "gap=%.2f" % build_gap)


# ── R5 spawn 不入设计域（收窄口径：采样点 ∉ [0,720]×[0,1280]） ─────
func _law_r5(p_label: String) -> void:
	# 真出生管线采样（verify R72 同款构造：独立 grid 隔离，采样后归还池零残留）
	var spawner := EnemySpawner.new()
	spawner.pool = _gl.pools[&"enemy"]
	spawner.registry = _gl.registry
	spawner.difficulty = GameConst.Difficulty.NORMAL
	var grid := SpaceGrid.new()
	grid.configure(Vector2(720, 1280), 192.0)
	for i in range(24):
		spawner.enqueue({"data_id": &"E1_grunt", "wave": 1, "tags": 0})
	for attempt in range(10):
		if spawner.active.size() >= 24:
			break
		spawner.tick(0.016, grid)
	var all_out := spawner.active.size() > 0
	for e in spawner.active:
		if DESIGN_DOMAIN.has_point((e as Node2D).global_position):
			all_out = false
	_check("R5 @%s：spawn 采样 %d 点全部 ∉ 设计域（expand 顶延展渐显入场合规）"
		% [p_label, spawner.active.size()], all_out,
		"spawned=%d" % spawner.active.size())
	for e in spawner.active:
		(_gl.pools[&"enemy"] as EnemyPool).release(e)
	spawner.free()                                 # EnemySpawner=Node（显式释放）
	grid = null                                    # SpaceGrid=RefCounted（禁 free——引用落空自还）


# ── R6 dim.size == visible_rect（逐态） ──────────────────────────
func _law_r6(p_dim: Control, p_label: String, p_state: String) -> void:
	if p_dim == null:
		_check("R6 %s @%s：dim 句柄非空" % [p_state, p_label], false, "null")
		return
	var delta := (p_dim.get_global_rect().size - _vis().size).length()
	_check("R6 %s @%s：dim.size==visible_rect" % [p_state, p_label], delta <= 0.5,
		"dim=%s vis=%s" % [str(p_dim.get_global_rect().size), str(_vis().size)])


# ── R7 触控目标逐尺寸不缩水（AUTO 56×64 / 暂停 72×72） ────────────
func _law_r7(p_label: String) -> void:
	var hud: HUD = _gl.hud
	_check("R7 @%s：AUTO 钮 56×64 不缩水" % p_label,
		hud._auto_btn != null and hud._auto_btn.size == Vector2(56.0, 64.0),
		str(hud._auto_btn.size if hud._auto_btn != null else Vector2.ZERO))
	_check("R7 @%s：AUTO 胶囊 56×64 不缩水" % p_label,
		hud._auto_capsule != null and hud._auto_capsule.size == Vector2(56.0, 64.0),
		str(hud._auto_capsule.size if hud._auto_capsule != null else Vector2.ZERO))
	_check("R7 @%s：暂停钮 72×72 不缩水" % p_label,
		hud._pause_btn != null and hud._pause_btn.size == Vector2(72.0, 72.0),
		str(hud._pause_btn.size if hud._pause_btn != null else Vector2.ZERO))


# ── 钳制 / 回退位 / 双向可逆（A7） ────────────────────────────────
func _test_stretch_clamp() -> void:
	print("── R195 超限钳制与回退位 ──")
	var win: Window = tree.root
	var project_aspect := String(ProjectSettings.get_setting("display/window/stretch/aspect", "keep"))
	var armed: bool = _gl.get("_stretch_clamp_armed")
	if project_aspect == "expand":
		# ── 主案分支：aspect=expand → 钳制 armed ──
		_check("钳制前置：aspect=expand → _stretch_clamp_armed==true", armed, str(armed))
		# ① 720×1800（2.5:1 > 2.34）→ 回落 KEEP 居中黑边（origin.y≈260）
		await _resize_and_settle(Vector2i(720, 1800))
		if win.content_scale_aspect != Window.CONTENT_SCALE_ASPECT_KEEP:
			_gl.apply_stretch_aspect_clamp()      # headless 事件路径兜底直驱（生产=size_changed 事件驱动）
			await tree.process_frame
		var vis := _vis()
		var tf_origin: Vector2 = win.get_final_transform().origin
		_check("钳制①：720×1800 → aspect==KEEP（超限回落）",
			win.content_scale_aspect == Window.CONTENT_SCALE_ASPECT_KEEP)
		# 4.3 headless 实探（r195_adapt A7 同款口径）：get_visible_rect() position 恒
		# (0,0)，letterbox 居中偏移的真值量纲在 final_transform origin——黑边断言读它
		_check("钳制①：vis==(720,1280) 且 origin.y≈260（居中黑边）",
			vis.size == Vector2(720, 1280) and absf(tf_origin.y - 260.0) <= 2.0,
			"vis=%s tf_origin=%s" % [str(vis), str(tf_origin)])
		# ② 720×1680（21:9≈2.333 ≤ 2.34 整档留 EXPAND）→ 满屏
		await _resize_and_settle(Vector2i(720, 1680))
		if win.content_scale_aspect != Window.CONTENT_SCALE_ASPECT_EXPAND:
			_gl.apply_stretch_aspect_clamp()
			await tree.process_frame
		_check("钳制②：720×1680 → aspect==EXPAND + vis==(720,1680) 满屏",
			win.content_scale_aspect == Window.CONTENT_SCALE_ASPECT_EXPAND
			and _vis().size == Vector2(720, 1680), str(_vis()))
		# ③ 双向可逆：1800(KEEP) → 1680(EXPAND) → 1800(KEEP)
		await _resize_and_settle(Vector2i(720, 1800))
		_gl.apply_stretch_aspect_clamp()
		var keep_ok := win.content_scale_aspect == Window.CONTENT_SCALE_ASPECT_KEEP
		await _resize_and_settle(Vector2i(720, 1680))
		_gl.apply_stretch_aspect_clamp()
		var expand_ok := win.content_scale_aspect == Window.CONTENT_SCALE_ASPECT_EXPAND
		await _resize_and_settle(Vector2i(720, 1800))
		_gl.apply_stretch_aspect_clamp()
		var keep_again_ok := win.content_scale_aspect == Window.CONTENT_SCALE_ASPECT_KEEP
		_check("钳制③：KEEP↔EXPAND 运行时双向切换可逆（KEEP→EXPAND→KEEP）",
			keep_ok and expand_ok and keep_again_ok,
			"k=%s e=%s k2=%s" % [str(keep_ok), str(expand_ok), str(keep_again_ok)])
		# ④ 直驱幂等：默认比例（720×1280）下钳制保持 EXPAND（≤2.34 不回落）
		await _resize_and_settle(Vector2i(720, 1280))
		_gl.apply_stretch_aspect_clamp()
		_check("钳制④：720×1280 直驱钳制 → 恒 EXPAND（不误回落）",
			win.content_scale_aspect == Window.CONTENT_SCALE_ASPECT_EXPAND)
	else:
		# ── 回退位分支：project.godot 改回 keep（单行整体回退）→ 钳制零触发=现状黑边 ──
		_check("回退位：aspect=keep → _stretch_clamp_armed==false（零触发）",
			not armed, str(armed))
		await _resize_and_settle(Vector2i(720, 1800))
		_gl.apply_stretch_aspect_clamp()          # 直驱验证零效果（armed 短路）
		await tree.process_frame
		var vis := _vis()
		var tf_origin: Vector2 = win.get_final_transform().origin
		_check("回退位：720×1800 → aspect 保持 KEEP（现状黑边）+ vis==(720,1280) origin.y≈260",
			win.content_scale_aspect == Window.CONTENT_SCALE_ASPECT_KEEP
			and vis.size == Vector2(720, 1280) and absf(tf_origin.y - 260.0) <= 2.0,
			"aspect=%s vis=%s tf_origin=%s" % [str(win.content_scale_aspect), str(vis),
				str(tf_origin)])
	await _resize_and_settle(Vector2i(720, 1280))


# ── R198 TargetBar 行为断言（二aw-3 契约变更新增；既有 :306 几何断言之外的行为半边。
#    W8 附着半边 moot 不做：R187 已拆除 attach 三件套（orbit_field.gd:21/orbit_weapon.gd:15
#    拆除声明），「为已不存在的新路径补断言」不成立——见 R198_BACKLOG_SWEEP.md §6）──
# 观测口=hud 公共测试位 displayed_target_uid()/displayed_target_text()/is_visible_bar()/
# displayed_pct()；驱动口=hud.tick（game_loop.gd:1895 生产同款）+ EventBus.emit_damage_resolved
# （history_cases.gd:181 先例）。夹具照同文件 R5 Stub 手法：真 spawner 显式 pos 出队
# 非 Boss 敌（uid 单调计数器与 hud 解析口同源），清场走 on_enemy_killed 真死亡归还链。
func _test_target_bar_behavior() -> void:
	print("── R198 TargetBar 行为（锁定/切换/掉血/死亡/续窗） ──")
	_enter_playing()
	await tree.process_frame                      # 引擎跑一帧真实管线（噪声由 hard_reset 清）
	var hud: HUD = _gl.hud
	var sp: EnemySpawner = _gl.spawner
	# R198 夹具清场（同 game_loop.gd _clear_battlefield 敌段先例：快照遍历 on_enemy_killed
	# ——active.erase+元素注销+池归还各恰一次）。动因：start_run 不经 _reset_run_state
	# （战场清场仅 restart_run 路径），矩阵 8 连 start_run 在真 spawner 累积在场敌至
	# MAX_ONSCREEN(120) 上限——不清场则夹具出队被上限静默折断（首跑实证）。
	for enemy in sp.active.duplicate():
		if is_instance_valid(enemy):
			sp.on_enemy_killed(enemy)
	var e_a := _tb_spawn_fixture(Vector2(200.0, 900.0))
	var e_b := _tb_spawn_fixture(Vector2(500.0, 900.0))
	if e_a == null or e_b == null:
		_check("TB 前置：夹具敌生成（真 spawner 出队 2 只）", false,
			"spawn 失败 active=%d queue=%d" % [sp.active.size(), sp.spawn_queue.size()])
		_tb_cycle_to_menu()
		await tree.process_frame
		return
	var uid_a := int(e_a.get("uid"))
	var uid_b := int(e_b.get("uid"))
	var name_a := String(e_a.get("data").get("display_name"))
	var name_b := String(e_b.get("data").get("display_name"))
	_check("TB 前置：两敌 uid 互异且均非 Boss（is_boss false——Boss 让位 BossBar 不入本条）",
		uid_a != uid_b and uid_a > 0 and uid_b > 0
		and not bool(e_a.call(&"is_boss")) and not bool(e_b.call(&"is_boss")),
		"uid_a=%d uid_b=%d" % [uid_a, uid_b])
	hud._tb_hard_reset()                          # R198 夹具：清聚合+隐藏态起步（隔离真实事件噪声）
	_check("TB① 起步：hard_reset 后条隐藏且 uid==0（HIDDEN 基线）",
		not hud.is_visible_bar() and hud.displayed_target_uid() == 0)
	# ① 锁定非 Boss 目标 → uid/text 非空
	_emit_tb_damage(uid_a, 5.0)
	hud.tick(0.016)                               # 生产驱动口：非空聚合 → 帧结算 → HIDDEN 免滞回接管
	_check("TB② 锁定：uid==首目标 ∧ text 含其名 ∧ 条可见",
		hud.displayed_target_uid() == uid_a and hud.displayed_target_text().contains(name_a)
		and hud.is_visible_bar(),
		"uid=%d text=%s" % [hud.displayed_target_uid(), hud.displayed_target_text()])
	# ①b 随切换更新：B 连续胜出满滞回 0.3s（TB_SWITCH_HYSTERESIS）→ 锁定切 B
	for i in range(10):
		_emit_tb_damage(uid_b, 7.0)
		hud.tick(0.05)                            # 10×0.05=0.5s > 0.3s 滞回
	_check("TB③ 切换：B 连续胜出满滞回后 uid==B 且 text 含 B 名",
		hud.displayed_target_uid() == uid_b and hud.displayed_target_text().contains(name_b),
		"uid=%d" % hud.displayed_target_uid())
	# ② 目标掉血 → _tb_fill 宽比例变化（hud.gd _tb_refresh_visual 写点 :1776）
	var fill_full := hud._tb_fill.size.x
	e_b.set("hp", float(e_b.get("max_hp")) * 0.5)
	hud.tick(0.016)                               # LOCKED 每帧拉模型读血 → 填充随比例重写
	_check("TB④ 掉血：fill 宽较满血收窄且比例≈0.5（displayed_pct 口径）",
		hud._tb_fill.size.x < fill_full * 0.75
		and absf(hud.displayed_pct() - 0.5) <= 0.005,
		"full=%.1f now=%.1f pct=%.3f" % [fill_full, hud._tb_fill.size.x, hud.displayed_pct()])
	# ③a 目标死亡 → 白残影收起 → 条隐藏 uid 清零
	e_b.set("dead", true)
	hud.tick(0.016)                               # 有效性三查置 dying 旗（出口交下一次帧结算裁决）
	_emit_tb_damage(uid_b, 1.0)                   # 非空聚合触发帧结算（headless 帧号冻结口径）
	hud.tick(0.016)                               # 无合格候选 → 0.25s 白残影闪白收起
	for i in range(8):
		hud.tick(0.05)                            # 0.4s > TB_KILL_FLASH 0.25s
	_check("TB⑤ 死亡：白残影收起后条隐藏且 uid 清零",
		not hud.is_visible_bar() and hud.displayed_target_uid() == 0,
		"visible=%s uid=%d" % [str(hud.is_visible_bar()), hud.displayed_target_uid()])
	# ③b 续窗耗尽（停火超 TB_RETAIN_TIME 2.5s）→ 0.3s 淡出收起
	_emit_tb_damage(uid_a, 5.0)
	hud.tick(0.016)                               # 重新锁定 A
	_check("TB⑥ 前置：A 重新锁定可见", hud.is_visible_bar()
		and hud.displayed_target_uid() == uid_a,
		"uid=%d" % hud.displayed_target_uid())
	for i in range(15):
		hud.tick(0.1)                             # 1.5s < 2.5s 续窗 → 仍在窗内
	_check("TB⑥ 续窗中：1.5s 停火仍在窗内（条保持可见）", hud.is_visible_bar())
	for i in range(35):
		hud.tick(0.1)                             # 累计 5.0s > 2.5s 续窗 + 0.3s 淡出
	_check("TB⑦ 超窗：续窗耗尽淡出后条隐藏", not hud.is_visible_bar(),
		"visible=%s" % str(hud.is_visible_bar()))
	# 夹具清场：真死亡归还链（active.erase+元素注销+pool.release 各恰一次，零二次释放）
	for e: Node2D in [e_a, e_b]:
		if is_instance_valid(e):
			sp.on_enemy_killed(e)
	_check("TB 清场：夹具敌归还后不在 active（池纪律）",
		not sp.active.has(e_a) and not sp.active.has(e_b))
	_tb_cycle_to_menu()                           # PLAYING→MENU 非法迁移（首跑实证），经 GAME_OVER 环回
	await tree.process_frame


func _tb_cycle_to_menu() -> void:
	# R198 夹具收尾：PLAYING→MENU 直迁被 change_state 拒（首跑实证「非法状态迁移 2→1」）
	# ——照矩阵逐档收束同款 GAME_OVER→MENU 合法环回
	if _gl.state != GameConst.GameStatus.GAME_OVER:
		_gl.change_state(GameConst.GameStatus.GAME_OVER)
	_gl.game_over_screen.cancel_auto_countdown()  # 挂机倒计时钉住（不自动重开）
	_enter_menu()


func _tb_spawn_fixture(p_pos: Vector2) -> Node2D:
	# R198 夹具：真 spawner 出队 1 只非 Boss 敌（显式 pos 免出生采样掷骰；走真实 spawn
	# 管线——E1_grunt 基线敌，R5 同款数据 id）
	var sp: EnemySpawner = _gl.spawner
	var before := sp.active.size()
	sp.enqueue({"data_id": &"E1_grunt", "wave": 1, "tags": 0, "pos": p_pos})
	for i in range(4):
		if sp.active.size() > before:
			break
		sp.tick(0.016, _gl.enemy_grid)
	return sp.active[before] if sp.active.size() > before else null


func _emit_tb_damage(p_uid: int, p_value: float) -> void:
	# R198 夹具：真事件管线发一笔 NORMAL 直击（popup/gamefeel 同收无碍——断言只读
	# TargetBar 观测口；DOT/HEAL 等不入聚合口径见 hud.gd _on_damage_resolved 注释）
	var r := DamageResult.new()
	r.final_value = p_value
	r.target_uid = p_uid
	r.popup_style = GameConst.PopupStyle.NORMAL
	EventBus.emit_damage_resolved(r)


# ── safe-area 契约（A8） ─────────────────────────────────────────
func _test_safe_area_contract() -> void:
	print("── R195 safe-area 契约 ──")
	# ① 守卫：headless（非 mobile/非全屏）恒不启用 → insets 恒零矩形（矩阵永不读真值）
	_check("safe①：headless 守卫 → enabled()==false", not SafeAreaHelper.enabled(tree.root))
	_check("safe②：守卫外 insets 恒零 Rect2()", SafeAreaHelper.insets(tree.root) == Rect2(),
		str(SafeAreaHelper.insets(tree.root)))
	# ③ 映射纯函数注入等价校验（helper 无 DisplayServer 注入 seam——headless 真值恒零；
	# 按契约注释的换算式逐式镜像：canvas = final_transform.affine_inverse() × raw，
	# 右/下 inset = vis.end − area.end，负值钳零）
	var to_canvas: Transform2D = tree.root.get_final_transform().affine_inverse()
	var raw := Rect2(80.0, 40.0, 560.0, 1180.0)   # 合成 display 像素域 insets
	var area := to_canvas * raw
	var v := _vis()
	var left := maxf(area.position.x, 0.0)
	var top := maxf(area.position.y, 0.0)
	var right := maxf(v.size.x - area.end.x, 0.0)
	var bottom := maxf(v.size.y - area.end.y, 0.0)
	_check("safe③：映射等价（左/上 inset=变换后原点钳零）",
		is_equal_approx(left, maxf(area.position.x, 0.0)) and left >= 0.0 and top >= 0.0,
		"l=%.1f t=%.1f" % [left, top])
	_check("safe④：映射等价（右/下 inset=vis.end−area.end）",
		is_equal_approx(right, v.size.x - area.end.x)
		and is_equal_approx(bottom, v.size.y - area.end.y),
		"r=%.1f b=%.1f" % [right, bottom])
	_check("safe⑤：负值钳零（area 越出画布 → inset 恒 ≥0）",
		right >= 0.0 and bottom >= 0.0)
	# ⑥ 源级 grep：helper 含守卫/换算/钳零/延迟读/重读信号（契约五件套在册）
	var helper_src := _read_source("res://scripts/ui/safe_area_helper.gd")
	_check("safe⑥：helper 源级守卫（mobile + 全屏模式）",
		helper_src.contains("OS.has_feature(\"mobile\")")
		and helper_src.contains("MODE_FULLSCREEN")
		and helper_src.contains("MODE_EXCLUSIVE_FULLSCREEN"))
	_check("safe⑦：helper 源级换算+钳零（affine_inverse × Rect2 + maxf）",
		helper_src.contains("affine_inverse()") and helper_src.contains("maxf("))
	_check("safe⑧：helper 源级时序（延迟 1 帧读 + size_changed/focus_entered 重读）",
		helper_src.contains("process_frame") and helper_src.contains("size_changed")
		and helper_src.contains("focus_entered"))
	# ⑦ 八屏接入 grep（七屏 UI 锚定组 + shop 商店组——只引用不复写）
	var screens := {
		"hud": "res://scripts/ui/hud.gd",
		"menu": "res://scripts/ui/menu_screen.gd",
		"shop": "res://scripts/ui/shop_ui.gd",
		"settings": "res://scripts/ui/settings_panel.gd",
		"pause": "res://scripts/ui/pause_overlay.gd",
		"game_over": "res://scripts/ui/game_over_screen.gd",
		"boss_bar": "res://scripts/ui/boss_bar.gd",
		"card_select": "res://scripts/cards/card_select_ui.gd",
	}
	var missing: Array[String] = []
	for key in screens:
		if not _read_source(screens[key]).contains("SafeAreaHelper"):
			missing.append(key)
	_check("safe⑨：八屏 FULL_RECT 根 SafeAreaHelper 接入（缺=%s）" % str(missing),
		missing.is_empty(), str(missing))
	# ⑧ combat/entities 零视口读取维持（A8：零视口读取 grep 断言）
	var zero_hit := true
	for dir_path in ["res://scripts/combat", "res://scripts/entities"]:
		for file in _list_gd_files(dir_path):
			var src := _read_source(file)
			if src.contains("get_viewport()") or src.contains("get_window()") \
					or src.contains("get_visible_rect") or src.contains("DisplayServer."):
				zero_hit = false
				print("  零视口读取违规：%s" % file)
	_check("safe⑩：combat/entities 零视口/窗口尺寸读取（逻辑域 720×1280 钉死维持）", zero_hit)
	# ⑨ 逻辑域真源互证（F-01：res_logic 钉死，data_validator fatal 不动）
	_check("safe⑪：GameConfig.balance.res_logic==(720,1280)",
		GameConfig.balance != null and Vector2(GameConfig.balance.res_logic) == Vector2(720, 1280),
		str(GameConfig.balance.res_logic if GameConfig.balance != null else Vector2.ZERO))


# ── 支撑 ──────────────────────────────────────────────────────────
func _read_source(p_path: String) -> String:
	var fa := FileAccess.open(p_path, FileAccess.READ)
	if fa == null:
		return ""
	var text := fa.get_as_text()
	fa.close()
	return text


func _list_gd_files(p_dir_path: String) -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open(p_dir_path)
	if dir == null:
		return out
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		var full := p_dir_path + "/" + name
		if dir.current_is_dir() and not name.begins_with("."):
			out.append_array(_list_gd_files(full))
		elif name.ends_with(".gd"):
			out.append(full)
		name = dir.get_next()
	dir.list_dir_end()
	return out


func first_color_rect(p_root: Control) -> Control:
	# 未命名 dim（首个 ColorRect 子节点——game_over/card_select/shop 装配序契约）
	for child in p_root.get_children():
		if child is ColorRect:
			return child
	return null


func find_child_dim(p_root: Control, p_name: String) -> Control:
	return p_root.find_child(p_name, true, false) as Control


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("PASS | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s %s" % [p_name, p_detail])
		print("FAIL | %s | %s" % [p_name, p_detail])

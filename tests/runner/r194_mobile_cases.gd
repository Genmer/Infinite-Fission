# tests/runner/r194_mobile_cases.gd
# R194 移动端统包用例体（由 test_r194_mobile.gd 入口在 autoload 就绪后运行时加载编译）。
# 覆盖（R194 orient/spawn/touch/fx/export 五方向非 noop 项验收）：
#   · 横屏修复源级断言（orient G1）：project.godot [display] 段精确行
#     window/handheld/orientation=1（int 字面量不带段前缀，全文件恰 1 处）+
#     [application] config/quit_on_go_back=false（touch 项2）+ ProjectSettings 直读互证 +
#     物理 120Hz 护栏（红线2：project.godot 全局物理时钟不破）
#   · R194 设置键契约 headless 探针（fx_opacity + fps_cap 双注册/写口钳制/持久化/旧档回退/
#     mobile 门 false 时 Engine.max_fps 零改动；测试档隔离 user://meta_save_test.cfg）
#   · fx_opacity 乘区传递（fx §5.2 三单点抽全）：elemental_fx 层根 / 粒子池发射器 /
#     DamagePopup static 折乘（tick 淡出 × f + _reset_state 带 f）+ player 本体不接入 +
#     settings_changed 订阅即时重应用 + 快照还原乘区复位
#   · boot 空表闸谓词（spawn P0-3）：零类目 manifest → enemies 空 + report.total==0
#    （闸分支本体=GameLoop._boot_check_empty_registry，boot 负态见 export_data_cases.gd T4）
#   · 采样守卫（R194 单指针锁定）：单指 1× / 仿真路 device=-1 丢弃 / 桌面 device=0 1× 基线 /
#     异 index 不累计 / 释放转锁 / 宽限期消费零 + 上升沿清锁 / 重开清锁 / hazard 乘序不变
#   · BuildPanel 松手阈值（R194）：干净点按恰发 1 次 / 位移 ≥16px 发 0 次
#   · UI 触控目标几何常量（R194）：AUTO 56×64（恰贴 r188 断言带）/ 暂停 72×72 /
#     商店购买刷新 / 菜单出发·选用·解锁·武器循环·图鉴行·升级买
#   · 首帧尖峰注入（spawn P2-10 + T7 首帧口径）：开局首帧 delta=3.0s → clamp 计数 +1 /
#     不跳波（wave 恒 1、窗口实耗 ≤0.25s）/ 不吞怪（queue+active 守恒、spawn_dropped 恒 0、
#     后续小步长 tick 怪正常出生）
# 导出数据链探针 T1-T7 见 export_data_cases.gd（本套件入口同批链接运行）。
# 确定性：GameLoop 完整 Boot（main.tscn 实例化）→ 直调 _unhandled_input/_gui_input 注入；
# 输入事件构造均为真件（InputEventScreenDrag/MouseMotion/MouseButton/ScreenTouch）。
extends RefCounted

const DT := 1.0 / 120.0                          # 120Hz 物理帧
const MAIN_SCENE := "res://scenes/main.tscn"
const PLAYER_HOME := Vector2(360.0, 1024.0)      # 下 40% 活动带中心（E-15 钳制 y≥768，
                                                 # 640 落禁带会被首 tick 抬到 768 污染位移测量）

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null                         # 共享 GameLoop（main.tscn 实例化）
var _saved_char: StringName = &""                # 角色快照（采样套件钉 sentinel 防技能位移污染）


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_ensure_autoloads()
	_boot_game_loop()
	_test_settings_key_contract()                 # R194 双键契约（fx_opacity/fps_cap）
	_test_fx_opacity_apply()                      # R194 fx_opacity 乘区传递（三单点消费位）
	_test_orientation_source()                    # R194 横屏修复源级断言（orient G1）
	_test_boot_gate_predicate()                   # R194 boot 空表闸谓词输入（spawn P0-3）
	_test_sampling_guard()                        # R194 采样守卫（锁定/仿真路/桌面基线/异指/转锁）
	_test_sampling_grace_and_reset()              # R194 宽限消费零 + 上升沿清锁 + 重开清锁
	_test_hazard_mult_order()                     # R194 hazard 乘序不变
	_test_build_panel_release()                   # R194 BuildPanel 松手阈值
	_test_ui_geometry()                           # R194 触控目标几何常量
	_test_first_frame_spike()                     # R194 首帧尖峰注入（全链最重，放末位）
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
func _ensure_autoloads() -> void:
	_check("autoload 就绪（EventBus/GameConfig/DebugStats）",
		EventBus != null and GameConfig != null and DebugStats != null)


func _boot_game_loop() -> void:
	_normalize_window_for_boot()
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "R194GameLoopUnderTest"
	tree.get_root().add_child(_gl)
	_check("R194 前置：Boot 进入 MENU + 致命清单空",
		_gl.boot_ready and _gl.state == GameConst.GameStatus.MENU and _gl.boot_fatal.is_empty())


func _normalize_window_for_boot() -> void:
	# R195：-s 脚本模式的根窗口不应用工程 stretch（实测 64×64 / aspect=IGNORE、
	# visible_rect 1280×1280）——真实 boot（main 场景启动）由引擎按 project.godot
	# [display] 应用 canvas_items + aspect + 540×960 override 窗。R195 起右上锚/底锚
	# UI（锚定分区）按画布宽 720 校准，-s 裸窗口下会算出 1280−offset 的错位。
	# 本函数只做「引擎 boot 等价」环境归一（断言零改动），矩阵/真机口径不受影响：
	# aspect 读 ProjectSettings 单源（回退 keep 时此处同步回 keep=现状黑边）。
	# 外部驱动（A9 720×1600 复跑等）已设 canvas_items + 非裸窗尺寸 → 不覆盖（尊重驱动）。
	var win: Window = tree.root
	if win.content_scale_mode == Window.CONTENT_SCALE_MODE_CANVAS_ITEMS and win.size.x > 100:
		return
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


func _teardown_game_loop() -> void:
	tree.paused = false
	RunSave.clear()
	if _saved_char != &"":
		Meta.character_id = _saved_char            # 角色快照还原
		_saved_char = &""
	if _gl != null:
		_gl.free()
		_gl = null


# ── R194 设置键契约（fx_opacity + fps_cap 双键，headless 探针） ──────
func _test_settings_key_contract() -> void:
	print("── R194 设置键契约（fx_opacity/fps_cap） ──")
	# 测试档隔离：headless 走 user://meta_save_test.cfg（meta_manager.gd _save_path 口径）；
	# 快照已存段 → 清空读口（旧档缺键语义）→ 末尾快照还原不留痕。
	var saved_settings: Dictionary = Meta._settings.duplicate()
	Meta._settings = {}
	# ① 旧档缺键：读口默认表回退（零迁移）——fx_opacity 回 1.0 / fps_cap 回 60
	_check("R194 键契约：旧档缺键读口回退 fx_opacity=1.0",
		is_equal_approx(float(Meta.settings("fx_opacity")), 1.0),
		str(Meta.settings("fx_opacity")))
	_check("R194 键契约：旧档缺键读口回退 fps_cap=60",
		int(Meta.settings("fps_cap")) == 60, str(Meta.settings("fps_cap")))
	# ② 双注册缺一不可：SETTINGS_DEFAULTS 加行（读口侧）+ set_setting 写入生效（写口侧——
	#    _normalized_setting 缺分支则静默丢弃、读回默认值）
	_check("R194 键契约：双注册读侧（SETTINGS_DEFAULTS 含 fx_opacity/fps_cap）",
		Meta.SETTINGS_DEFAULTS.has("fx_opacity") and Meta.SETTINGS_DEFAULTS.has("fps_cap"))
	Meta.set_setting("fx_opacity", 0.5)
	_check("R194 键契约：双注册写侧（fx_opacity 0.5 写入生效，非静默丢弃）",
		is_equal_approx(float(Meta.settings("fx_opacity")), 0.5))
	Meta.set_setting("fps_cap", 90)
	_check("R194 键契约：双注册写侧（fps_cap 90 写入生效）", int(Meta.settings("fps_cap")) == 90)
	# ③ 写口钳制：fx_opacity clampf(0.3,1.0) / fps_cap clampi(0,144)
	Meta.set_setting("fx_opacity", 0.29)
	_check("R194 键契约：写口下钳 0.29→0.3", is_equal_approx(float(Meta.settings("fx_opacity")), 0.3))
	Meta.set_setting("fx_opacity", 2.0)
	_check("R194 键契约：写口上钳 2.0→1.0", is_equal_approx(float(Meta.settings("fx_opacity")), 1.0))
	Meta.set_setting("fps_cap", 200)
	_check("R194 键契约：fps_cap 200→144（clampi 0~144）", int(Meta.settings("fps_cap")) == 144)
	Meta.set_setting("fps_cap", 145)
	_check("R194 键契约：fps_cap 145→144", int(Meta.settings("fps_cap")) == 144)
	Meta.set_setting("fps_cap", -5)
	_check("R194 键契约：fps_cap -5→0（0=不限）", int(Meta.settings("fps_cap")) == 0)
	# ④ headless 探针：mobile 门 false → Engine.max_fps 保持 0 不被改（桌面基准）
	_check("R194 键契约：headless 下 Engine.max_fps 恒 0（mobile 门 false 不应用）",
		Engine.max_fps == 0, "max_fps=%d" % Engine.max_fps)
	# ⑤ 持久化回路（settings 段加键、结构禁改）：写即存 → _load 磁盘回路还原
	Meta.set_setting("fx_opacity", 0.4)
	Meta._load()
	_check("R194 键契约：fx_opacity 过 user:// 磁盘写读回路（0.4）",
		is_equal_approx(float(Meta.settings("fx_opacity")), 0.4))
	# 快照还原（测试不留痕）
	Meta._settings = saved_settings
	Meta._save()


# ── R194 fx_opacity 乘区传递（设计 §5.2 三单点，抽全部三个代表消费点） ──
func _test_fx_opacity_apply() -> void:
	print("── R194 fx_opacity 乘区传递 ──")
	var saved_settings: Dictionary = Meta._settings.duplicate()
	var fx0: float = float(Meta.settings("fx_opacity"))   # 原值真源（读口归一后）
	# 写口 → settings_changed → GameLoop 单源应用器（订阅路径，非直调）
	Meta.set_setting("fx_opacity", 0.3)
	_check("R194 fx①：set_setting(0.3) → DamagePopup.fx_opacity==0.3（单源 static 写值）",
		is_equal_approx(DamagePopup.fx_opacity, 0.3), str(DamagePopup.fx_opacity))
	_check("R194 fx②：elemental_fx.modulate.a==0.3（消费点A 层根罩全层）",
		_gl.elemental_fx != null and is_equal_approx(_gl.elemental_fx.modulate.a, 0.3),
		str(_gl.elemental_fx.modulate.a if _gl.elemental_fx != null else -1.0))
	var emitters: Array = (_gl.pools[&"particle"] as ParticlePool).get_children()
	var dimmed := 0
	for emitter in emitters:
		var gp := emitter as GPUParticles2D
		if gp != null and is_equal_approx(gp.modulate.a, 0.3):
			dimmed += 1
	_check("R194 fx③：粒子池发射器全部 modulate.a==0.3（消费点B，%d/%d）"
		% [dimmed, emitters.size()],
		emitters.size() > 0 and dimmed == emitters.size())
	_check("R194 fx④：player.modulate.a==1.0（玩家本体不接入，排除清单口径）",
		is_equal_approx(_gl.player.modulate.a, 1.0), str(_gl.player.modulate.a))
	# 消费点C：跳字折乘（真件直驱——tick 淡出曲线 × f + 复位带 f，R194 alpha 写点①②）
	var pop := DamagePopup.new()
	tree.get_root().add_child(pop)
	pop.show_popup(Vector2(100.0, 100.0), 10.0, GameConst.PopupStyle.NORMAL)
	pop.tick(DamagePopup.LIFE_TIME * 0.25)        # t=0.25 → 淡出因子 1−t²=0.9375
	_check("R194 fx⑤：跳字 tick 后 modulate.a==0.3×(1−t²)（消费点C 折乘）",
		is_equal_approx(pop.modulate.a, 0.3 * (1.0 - 0.25 * 0.25)), str(pop.modulate.a))
	pop._reset_state()
	_check("R194 fx⑥：跳字 _reset_state 后 modulate.a==0.3（复位带乘区，防池复用闪帧）",
		is_equal_approx(pop.modulate.a, 0.3), str(pop.modulate.a))
	pop.free()
	# 第二跳：改值即时重应用（设置页拖动实时减淡口径，仅 fx_opacity 键短路）
	Meta.set_setting("fx_opacity", 0.5)
	_check("R194 fx⑦：订阅路径 0.5 → elemental_fx.modulate.a==0.5（settings_changed 即时）",
		_gl.elemental_fx != null and is_equal_approx(_gl.elemental_fx.modulate.a, 0.5),
		str(_gl.elemental_fx.modulate.a if _gl.elemental_fx != null else -1.0))
	# 快照还原 + 乘区复位（设计 §5.4⑤：DamagePopup.fx_opacity 复位——按原值重应用）
	Meta._settings = saved_settings
	Meta._save()
	_gl._apply_fx_opacity()
	_check("R194 fx⑧：快照还原后乘区回读口原值（f=%s）" % str(fx0),
		is_equal_approx(DamagePopup.fx_opacity, fx0)
		and is_equal_approx(_gl.elemental_fx.modulate.a, fx0))


# ── R194 横屏修复源级断言（orient G1：project.godot 源文本） ────────
func _test_orientation_source() -> void:
	print("── R194 横屏修复源级断言 ──")
	var fa := FileAccess.open("res://project.godot", FileAccess.READ)
	_check("R194 orient 前置：project.godot 可读（res:// 源文本）", fa != null)
	if fa == null:
		return
	var text := fa.get_as_text()
	fa.close()
	var disp := _cfg_section(text, "[display]")
	var disp_hits := 0
	for line in disp.split("\n"):
		if line.strip_edges() == "window/handheld/orientation=1":
			disp_hits += 1
	_check("R194 orient①：[display] 段内精确行 window/handheld/orientation=1 恰 1 处"
		+ "（G1：int 字面量、不带段前缀）", disp_hits == 1, "hits=%d" % disp_hits)
	var total_hits := 0
	for line in text.split("\n"):
		if line.strip_edges() == "window/handheld/orientation=1":
			total_hits += 1
	_check("R194 orient②：全文件该行恰 1 处（无重复键/无他段漂移）", total_hits == 1,
		"hits=%d" % total_hits)
	var app := _cfg_section(text, "[application]")
	var go_back := false
	for line in app.split("\n"):
		if line.strip_edges() == "config/quit_on_go_back=false":
			go_back = true
	_check("R194 orient③：[application] 段 config/quit_on_go_back=false（touch 项2，"
		+ "引擎级键不进 Meta.settings）", go_back)
	_check("R194 orient④：ProjectSettings 直读 display/window/handheld/orientation==1"
		+ "（引擎解析视图，pkg5 AC 同款互证）",
		int(ProjectSettings.get_setting("display/window/handheld/orientation")) == 1,
		str(ProjectSettings.get_setting("display/window/handheld/orientation")))
	_check("R194 orient⑤：物理 120Hz 源级护栏（红线2：project.godot 全局物理时钟不动）",
		int(ProjectSettings.get_setting("physics/common/physics_ticks_per_second")) == 120,
		str(ProjectSettings.get_setting("physics/common/physics_ticks_per_second")))


# ── R194 boot 空表闸谓词输入（spawn P0-3） ────────────────────────
func _test_boot_gate_predicate() -> void:
	print("── R194 boot 空表闸谓词 ──")
	# 零类目 manifest（= APK 缺 *.cfg 时 DataRegistry 终态）：load_all 仅告警不炸，
	# 产出闸分支判据输入（enemies 空 / report.total==0）。闸分支本体=GameLoop
	# ._boot_check_empty_registry（boot 全链负态=export_data_cases.gd T4 同套件覆盖）。
	var path := "user://r194_gate_empty_manifest.cfg"
	var cfg := ConfigFile.new()
	cfg.save(path)
	var reg := DataRegistry.new()
	reg.load_all(path)
	_check("R194 闸谓词：零类目 manifest → enemies 空 且 report.total==0"
		+ "（_boot_load_data 空表闸判据输入成立）",
		reg.enemies.is_empty() and int(reg.report.get("total", 0)) == 0,
		"enemies=%d total=%d" % [reg.enemies.size(), int(reg.report.get("total", 0))])
	DirAccess.remove_absolute(path)


# ── R194 采样守卫（单指针锁定 + 仿真路丢弃 + 桌面基线） ────────────
func _test_sampling_guard() -> void:
	print("── R194 采样守卫 ──")
	# 角色钉 sentinel（测试档存档可能残留游侠等位移技能角色——其技能冲刺会污染位移断言；
	# 快照于 teardown 还原）
	_saved_char = Meta.character_id
	Meta.character_id = &"sentinel"
	_gl.state = GameConst.GameStatus.MENU
	_gl.call(&"start_run")
	var p: Player = _gl.player
	p.global_position = PLAYER_HOME
	p.input_enabled = true
	p._drag_accum = Vector2.ZERO
	p._active_drag_index = -1
	# ① 单指 1×：ScreenDrag(index=0) 认领锁并累计
	var drag := InputEventScreenDrag.new()
	drag.index = 0
	drag.relative = Vector2(10.0, 0.0)
	p._unhandled_input(drag)
	_check("R194 采样①：单指 ScreenDrag(index=0,rel=(10,0)) → _drag_accum==(10,0)（1×）",
		p._drag_accum == Vector2(10.0, 0.0), str(p._drag_accum))
	# ② 仿真路丢弃：emulate_mouse_from_touch 下首指同时合成 MouseMotion(device=-1)——
	#    与 ScreenDrag 双路重复累计（≈速度×2）→ device=DEVICE_ID_EMULATION 分支丢弃
	var fake := InputEventMouseMotion.new()
	fake.device = InputEvent.DEVICE_ID_EMULATION
	fake.button_mask = MOUSE_BUTTON_MASK_LEFT
	fake.relative = Vector2(10.0, 0.0)
	p._unhandled_input(fake)
	_check("R194 采样②：仿真 MouseMotion(device=-1) 丢弃（仍 (10,0)，防双计数）",
		p._drag_accum == Vector2(10.0, 0.0), str(p._drag_accum))
	# ③ 桌面基线：真鼠标 MouseMotion(device=0) 正常累计（1× 不受影响）
	var real := InputEventMouseMotion.new()
	real.device = 0
	real.button_mask = MOUSE_BUTTON_MASK_LEFT
	real.relative = Vector2(10.0, 0.0)
	p._unhandled_input(real)
	_check("R194 采样③：桌面 MouseMotion(device=0) 累计 → (20,0)（1× 基线）",
		p._drag_accum == Vector2(20.0, 0.0), str(p._drag_accum))
	# ④ 异 index 不累计：index=0 持期内次指拖动丢弃（防多指速度叠乘）
	var second := InputEventScreenDrag.new()
	second.index = 1
	second.relative = Vector2(999.0, 0.0)
	p._unhandled_input(second)
	_check("R194 采样④：异 index=1 拖动不累计（仍 (20,0)）",
		p._drag_accum == Vector2(20.0, 0.0), str(p._drag_accum))
	# ⑤ 释放转锁：首指抬起清锁 → 次指下条拖动认领
	var lift := InputEventScreenTouch.new()
	lift.index = 0
	lift.pressed = false
	p._unhandled_input(lift)
	var claim := InputEventScreenDrag.new()
	claim.index = 1
	claim.relative = Vector2(5.0, 0.0)
	p._unhandled_input(claim)
	_check("R194 采样⑤：ScreenTouch(released,index=0) 清锁 → drag index=1 认领累计（(25,0)）",
		p._drag_accum == Vector2(25.0, 0.0) and p._active_drag_index == 1,
		"accum=%s lock=%d" % [str(p._drag_accum), p._active_drag_index])
	p.tick(0.0, Vector2.ZERO)                     # 消费清零（dt=0 零副作用）


# ── R194 宽限消费零 + 上升沿清锁 + 重开清锁 ───────────────────────
func _test_sampling_grace_and_reset() -> void:
	print("── R194 宽限/清锁 ──")
	var p: Player = _gl.player
	# ⑥ input_enabled=false（暂停恢复 0.5s 宽限期口径）：拖动被吞（消费零位移）
	p._drag_accum = Vector2.ZERO
	p._active_drag_index = -1
	p.input_enabled = false
	var drag := InputEventScreenDrag.new()
	drag.index = 2
	drag.relative = Vector2(30.0, 0.0)
	p._unhandled_input(drag)
	var pos0: Vector2 = p.global_position
	p.tick(0.0, Vector2.ZERO)
	_check("R194 采样⑥：宽限期投拖动 → tick 消费位移为零（宽限保护未破坏）",
		p.global_position == pos0 and p._drag_accum == Vector2.ZERO,
		"move=%s accum=%s" % [str(p.global_position - pos0), str(p._drag_accum)])
	# ⑦ input_enabled 上升沿清锁：恢复采样后旧指针不延续锁权
	p.input_enabled = true
	p.tick(0.0, Vector2.ZERO)
	_check("R194 采样⑦：input_enabled 上升沿 → 首指锁清（-1，由当前手指重认领）",
		p._active_drag_index == -1, str(p._active_drag_index))
	var reclaim := InputEventScreenDrag.new()
	reclaim.index = 3
	reclaim.relative = Vector2(7.0, 0.0)
	p._unhandled_input(reclaim)
	_check("R194 采样⑦b：恢复后新指认领（accum==(7,0)）",
		p._drag_accum == Vector2(7.0, 0.0) and p._active_drag_index == 3,
		"accum=%s lock=%d" % [str(p._drag_accum), p._active_drag_index])
	# ⑧ 重开清零同步：拖动累计 + 首指锁随局清零（不残留上局锁权）。
	# restart_run 合法迁移 = GAME_OVER/PAUSED → PLAYING（game_loop.gd 迁移矩阵）——
	# 置 PAUSED 走「暂停面板重新开始」口径
	p._drag_accum = Vector2(123.0, 45.0)
	p._active_drag_index = 5
	_gl.state = GameConst.GameStatus.PAUSED
	var restarted: bool = _gl.restart_run()
	_check("R194 采样⑧：重开清零（restart_run 自 PAUSED 成功 + _drag_accum 归零 + 首指锁 -1）",
		restarted and p._drag_accum == Vector2.ZERO and p._active_drag_index == -1,
		"restarted=%s accum=%s lock=%s" % [str(restarted), str(p._drag_accum), str(p._active_drag_index)])


# ── R194 hazard 乘序不变（采样→消费→钳制链路） ────────────────────
func _test_hazard_mult_order() -> void:
	print("── R194 hazard 乘序 ──")
	var p: Player = _gl.player
	p.global_position = PLAYER_HOME
	p.input_enabled = true
	p._drag_accum = Vector2.ZERO
	p._active_drag_index = -1
	p.skill_cd_left = 9999.0                      # 技能钉冷却（防自动施放位移干扰测量）
	p.hazard_slow_mult = 0.5                      # 冰锁圈外部减速（R18 P2）
	p.hazard_slow_left = 10.0
	p.tick(DT, Vector2.ZERO)                      # 冲洗帧（消耗一次性技能/残余位移）
	p.global_position = PLAYER_HOME               # 冲洗后归位再测量
	var drag := InputEventScreenDrag.new()
	drag.index = 0
	drag.relative = Vector2(10.0, 0.0)
	p._unhandled_input(drag)
	var pos0: Vector2 = p.global_position
	p.tick(DT, Vector2.ZERO)
	_check("R194 hazard：乘序路径 (10,0)×0.5 → 位移 (5,0)（先累计后乘，输入输出不变）",
		p.global_position - pos0 == Vector2(5.0, 0.0),
		str(p.global_position - pos0))
	# 还原 hazard 态（衰减至到期还原 mult=1.0）
	p.hazard_slow_left = 0.001
	p.tick(0.01, Vector2.ZERO)
	_check("R194 hazard：到期还原 mult=1.0", is_equal_approx(p.hazard_slow_mult, 1.0))


# ── R194 BuildPanel 松手阈值 ──────────────────────────────────────
func _test_build_panel_release() -> void:
	print("── R194 BuildPanel 松手判定 ──")
	var hud: HUD = _gl.hud
	var fired: Array[int] = []
	var probe := func() -> void: fired.append(1)
	hud.build_details_requested.connect(probe)
	# ① 干净点按：press → release（位移 <16px）→ 恰发 1 次
	hud._on_build_gui_input(_mouse_btn(Vector2(10.0, 10.0), true))
	hud._on_build_gui_input(_mouse_btn(Vector2(12.0, 10.0), false))
	_check("R194 BuildPanel①：press→release（位移 2px<16）→ build_details_requested 恰发 1 次",
		fired.size() == 1, "fired=%d" % fired.size())
	# ② 按住拖出阈值：press → motion 40px（解除武装）→ release → 0 次
	fired.clear()
	hud._on_build_gui_input(_mouse_btn(Vector2(100.0, 100.0), true))
	hud._on_build_gui_input(_mouse_motion(Vector2(140.0, 100.0)))
	hud._on_build_gui_input(_mouse_btn(Vector2(141.0, 100.0), false))
	_check("R194 BuildPanel②：press→motion 40px→release → 发 0 次（滑动不误判点击）",
		fired.size() == 0, "fired=%d" % fired.size())
	# ③ 失败释放后再点按：武装态复位 → 干净点按恢复发 1 次
	fired.clear()
	hud._on_build_gui_input(_mouse_btn(Vector2(50.0, 50.0), true))
	hud._on_build_gui_input(_mouse_btn(Vector2(50.0, 50.0), false))
	_check("R194 BuildPanel③：失败释放后再干净点按 → 恰发 1 次（武装态复位）",
		fired.size() == 1, "fired=%d" % fired.size())
	hud.build_details_requested.disconnect(probe)


func _mouse_btn(p_pos: Vector2, p_pressed: bool) -> InputEventMouseButton:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = p_pressed
	ev.position = p_pos
	return ev


func _mouse_motion(p_pos: Vector2) -> InputEventMouseMotion:
	var ev := InputEventMouseMotion.new()
	ev.device = 0
	ev.position = p_pos
	ev.button_mask = MOUSE_BUTTON_MASK_LEFT
	return ev


# ── R194 UI 触控目标几何常量 ──────────────────────────────────────
func _test_ui_geometry() -> void:
	print("── R194 UI 触控目标几何 ──")
	var hud: HUD = _gl.hud
	var menu: MenuScreen = _gl.menu_screen
	# ① HUD：AUTO 56×64（恰贴 r188 断言带 x∈[644,704]×y∈[126,190] 上沿，零断言改动）
	_check("R194 几何①：HUD _auto_btn.size==(56,64)",
		hud._auto_btn != null and hud._auto_btn.size == Vector2(56.0, 64.0),
		str(hud._auto_btn.size if hud._auto_btn != null else Vector2.ZERO))
	_check("R194 几何①b：HUD _auto_capsule.size==(56,64) 且 644+56≤704、126+64≤190（r188 带内）",
		hud._auto_capsule != null and hud._auto_capsule.size == Vector2(56.0, 64.0)
		and hud._auto_capsule.position == Vector2(644.0, 126.0)
		and hud._auto_capsule.position.x + hud._auto_capsule.size.x <= 704.0
		and hud._auto_capsule.position.y + hud._auto_capsule.size.y <= 190.0)
	_check("R194 几何②：HUD _pause_btn.size==(72,72)（66→72 放大）",
		hud._pause_btn != null and hud._pause_btn.size == Vector2(72.0, 72.0),
		str(hud._pause_btn.size if hud._pause_btn != null else Vector2.ZERO))
	# ② 商店：刷新钮 210×56@(211,802) + 行内购买钮 132×56@(440,16)
	# R195：刷新钮自本批起可隐藏（visible=can_refresh() 联动，禁刷原位隐藏留空）——
	# 隐藏态下 find_child 仍命中且 position/size 持久，几何契约 (211,802)210×56 不变
	_gl.shop_ui.open(_gl.player, 5, false)
	var refresh: Button = _gl.shop_ui.find_child("ShopRefreshButton", true, false) as Button
	_check("R194 几何③：商店刷新钮 (211,802) 210×56",
		refresh != null and refresh.position == Vector2(211.0, 802.0)
		and refresh.size == Vector2(210.0, 56.0))
	var buy_ok := 0
	var buy_total := 0
	var buy_first_size := Vector2.ZERO
	for row in _gl.shop_ui._list.get_children():
		if (row as Node).is_queued_for_deletion():
			continue
		for child in (row as Control).get_children():
			var btn := child as Button
			if btn != null and btn.text.ends_with("金币"):
				buy_total += 1
				if buy_total == 1:
					buy_first_size = btn.size
				# R194 触控目标验收口径：位置精确 + 尺寸 ≥ 定案下限——authoring 精确值
				# 在 shop_ui.gd「132×56」R194 行；Button 文本+stylebox 最小尺寸钳制只会
				# 放大运行时 size（实测 min 高 67>56），运行时 ≥ 定案即触控目标达标
				if btn.position == Vector2(440.0, 16.0) \
						and btn.size.x >= 132.0 and btn.size.y >= 56.0:
					buy_ok += 1
	_check("R194 几何④：商店行内购买钮 ≥132×56@(440,16)（全部 %d 个）" % buy_total,
		buy_total >= 1 and buy_ok == buy_total, "ok=%d/%d first_size=%s" % [buy_ok, buy_total, str(buy_first_size)])
	_gl.shop_ui.close()
	# ③ 菜单·角色行：先固定选择域（sentinel 选中 + veles 结晶解锁给选用钮 + fission
	#    普通通关门解锁给武器循环钮/图鉴行）→ 重建后断言 → 快照还原
	var saved_char: StringName = Meta.character_id
	var saved_unlocked: Dictionary = Meta.unlocked_characters.duplicate()
	var saved_map_records: Dictionary = Meta.map_records.duplicate()
	Meta.character_id = &"sentinel"
	Meta.unlocked_characters = {"veles": true}     # 价格门键为 String（is_character_unlocked 口径）
	Meta.map_records[String(MapTable.FIRST_MAP_ID)] = {"best_wave": \
		int(MapTable.get_map(MapTable.FIRST_MAP_ID).get("final_wave", 10))}   # normal_cleared 门
	menu.call(&"_rebuild_char_select")
	var row_ok := 0
	var row_total := 0
	var pick_btns: Array[Button] = []
	var wcycle: Button = null
	var codex_l: Label = null
	for scan_node in menu._panel_list.get_children():
		if (scan_node as Node).is_queued_for_deletion():
			continue
		var row := scan_node as Control
		if row == null or row.custom_minimum_size.y < 140.0:
			continue
		row_total += 1
		if row.custom_minimum_size == Vector2(576.0, 140.0):
			row_ok += 1
		for child in row.get_children():
			var lb := child as Label
			if lb != null and lb.text.begins_with("图鉴"):
				codex_l = lb
			var btn := child as Button
			if btn == null:
				continue
			if btn.name == "CustomWeaponCycle":
				wcycle = btn
			elif btn.text == "选用":
				pick_btns.append(btn)
	_check("R194 几何⑤：角色行 custom_minimum_size==(576,140)（全部 %d 行）" % row_total,
		row_total >= 3 and row_ok == row_total, "ok=%d/%d" % [row_ok, row_total])
	# R194 尺寸断言 ≥ 口径：Button 最小尺寸钳制只会放大（实测 min 高 61>48），authoring
	# 精确值在 menu_screen.gd「300×48」R194 行——位置精确 + 尺寸 ≥ 定案下限即达标
	_check("R194 几何⑥：初始武器循环钮 ≥300×48@(74,92)",
		wcycle != null and wcycle.size.x >= 300.0 and wcycle.size.y >= 48.0
		and wcycle.position == Vector2(74.0, 92.0),
		"size=%s pos=%s" % [str(wcycle.size if wcycle != null else Vector2.ZERO),
			str(wcycle.position if wcycle != null else Vector2.ZERO)])
	_check("R194 几何⑦：图鉴行下移 y=118（96→118 避让放大后循环钮 92-140）",
		codex_l != null and codex_l.position == Vector2(382.0, 118.0),
		str(codex_l.position if codex_l != null else Vector2.ZERO))
	# R194 尺寸断言 ≥ 口径（同几何⑥）：authoring 84×56 在 menu_screen.gd「84×56」R194 行
	_check("R194 几何⑧：选用钮 ≥84×56@(478,38)（44→56 放大）",
		not pick_btns.is_empty() and pick_btns[0].size.x >= 84.0
		and pick_btns[0].size.y >= 56.0
		and pick_btns[0].position == Vector2(478.0, 38.0),
		"size=%s pos=%s" % [str(pick_btns[0].size if not pick_btns.is_empty() else Vector2.ZERO),
			str(pick_btns[0].position if not pick_btns.is_empty() else Vector2.ZERO)])
	# 解锁钮（结晶购买门）：取首个带价角色并确保未解锁 → 重建后断言 84×56
	var priced_id: StringName = &""
	for def in CharacterTable.CHARACTERS:
		if int(def.get("unlock_price", 0)) > 0:
			priced_id = def.id
			break
	var unlock_btn: Button = null
	if priced_id != &"":
		Meta.unlocked_characters.erase(priced_id)
		menu.call(&"_rebuild_char_select")
		for node in menu._panel_list.get_children():
			if (node as Node).is_queued_for_deletion():
				continue
			for child in ((node as Control).get_children()):
				var btn := child as Button
				if btn != null and btn.text.contains("解锁"):
					unlock_btn = btn
	# R194 尺寸断言 ≥ 口径（同几何⑥；实测文本最小宽 113>84、高 64>56——只会放大）
	_check("R194 几何⑨：解锁钮 ≥84×56@(478,38)（44→56 放大）",
		unlock_btn != null and unlock_btn.size.x >= 84.0 and unlock_btn.size.y >= 56.0
		and unlock_btn.position == Vector2(478.0, 38.0),
		"size=%s pos=%s" % [str(unlock_btn.size if unlock_btn != null else Vector2.ZERO),
			str(unlock_btn.position if unlock_btn != null else Vector2.ZERO)])
	# ④ 菜单·选关行：出发钮 76×52@(486,32)
	menu.call(&"_open_map_select")
	var depart: Button = null
	for node in menu._panel_list.get_children():
		if (node as Node).is_queued_for_deletion():
			continue
		for child in ((node as Control).get_children()):
			var btn := child as Button
			if btn != null and btn.text == "出发":
				depart = btn
	# R194 尺寸断言 ≥ 口径（同几何⑥）：authoring 76×52 在 menu_screen.gd :332-333 R194 行
	_check("R194 几何⑩：出发钮 ≥76×52@(486,32)（选关行 118 内）",
		depart != null and depart.size.x >= 76.0 and depart.size.y >= 52.0
		and depart.position == Vector2(486.0, 32.0),
		"size=%s pos=%s" % [str(depart.size if depart != null else Vector2.ZERO),
			str(depart.position if depart != null else Vector2.ZERO)])
	# ⑤ 菜单·养成行：升级买 140×56@(420,6)
	menu.call(&"_rebuild_upgrades")
	var up_ok := 0
	var up_total := 0
	for node in menu._panel_list.get_children():
		if (node as Node).is_queued_for_deletion():
			continue
		for child in ((node as Control).get_children()):
			var btn := child as Button
			if btn != null and (btn.text.begins_with("升级") or btn.text == "已满级"):
				up_total += 1
				# R194 尺寸断言 ≥ 口径（同几何⑥）：authoring 140×56 在 menu_screen.gd
				# 「140×56」R194 行；实测 min 高 67>56 只会放大
				if btn.position == Vector2(420.0, 6.0) \
						and btn.size.x >= 140.0 and btn.size.y >= 56.0:
					up_ok += 1
	_check("R194 几何⑪：养成升级买 ≥140×56@(420,6)（全部 %d 个）" % up_total,
		up_total >= 1 and up_ok == up_total, "ok=%d/%d" % [up_ok, up_total])
	# 选择域快照还原
	Meta.character_id = saved_char
	Meta.unlocked_characters = saved_unlocked
	Meta.map_records = saved_map_records


# ── R194 首帧尖峰注入（首帧 delta=3s：clamp 语义 + 不跳波 + 不吞怪） ──
func _test_first_frame_spike() -> void:
	print("── R194 首帧尖峰注入 ──")
	_gl.state = GameConst.GameStatus.MENU
	_gl.call(&"start_run")                        # 真数据满注册表（w1 构成开局即入队）
	_gl.player.hp = _gl.player.max_hp
	_pin_weapons_cold()                           # 整段不开火（零击杀/零 xp/零弹升——时间主导）
	var queue0: int = _gl.spawner.queue_count() + _gl.spawner.active_count()
	_check("R194 尖峰前置：开局波构成已入队（queue+active=%d ≥10）" % queue0,
		queue0 >= 10, str(queue0))
	var dropped0: int = DebugStats.get_counter(&"spawn_dropped")
	var clamped0: int = DebugStats.get_counter(&"game_delta_clamped")
	var win0: float = _gl.wave_director.window_left
	_gl._physics_process(3.0)                     # 首帧尖峰（断点恢复/卡顿单帧补账口径）
	_check("R194 尖峰①：首帧 3.0s 被 clamp（game_delta_clamped 恰 +1）",
		DebugStats.get_counter(&"game_delta_clamped") == clamped0 + 1,
		"%d→%d" % [clamped0, DebugStats.get_counter(&"game_delta_clamped")])
	var consumed: float = win0 - _gl.wave_director.window_left
	_check("R194 尖峰②：不跳波（wave 恒 1，窗口实耗 %.4fs ≤0.25s clamp 帽）" % consumed,
		_gl.wave_director.current_wave == 1 and consumed > 0.0
		and consumed <= 0.25 + 0.0001,
		"wave=%d consumed=%.4f" % [_gl.wave_director.current_wave, consumed])
	var total_now: int = _gl.spawner.queue_count() + _gl.spawner.active_count()
	_check("R194 尖峰③：不吞怪（queue+active %d→%d 守恒，至多一批 %d 节流出队）"
		% [queue0, total_now, 8],
		total_now >= queue0 - 8 and total_now <= queue0, "now=%d" % total_now)
	_check("R194 尖峰④：spawn_dropped 恒 %d（尖峰不引发悬空丢弃）" % dropped0,
		DebugStats.get_counter(&"spawn_dropped") == dropped0,
		str(DebugStats.get_counter(&"spawn_dropped")))
	var seen_active := false
	for i in range(240):                          # 尖峰后 2s 小步长连续 tick（1/120）
		_gl.player.hp = _gl.player.max_hp
		_pin_weapons_cold()
		_gl._physics_process(1.0 / 120.0)
		if _gl.spawner.active_count() > 0:
			seen_active = true
		if _gl.state == GameConst.GameStatus.LEVEL_UP:
			_gl.card_select_ui.choose(0)          # 自爆类敌自亡弹升即选（pkg5 _drive_safe 口径）
	_check("R194 尖峰⑤：尖峰后 2s 内怪正常出生（active>0，波未被吞）", seen_active,
		"active=%d" % _gl.spawner.active_count())
	_gl.state = GameConst.GameStatus.MENU         # 直接置位（quit_to_menu 仅 PAUSED 合法）


# ── 支撑 ──────────────────────────────────────────────────────────
func _pin_weapons_cold() -> void:
	# 尖峰探针专用：每帧钉冷却 → 武器不开火（零击杀/零 xp——波次推进纯时间主导）
	for w in _gl.player.weapon_slots:
		if w != null:
			(w as WeaponBase).cooldown_left = 1.0


func _cfg_section(p_text: String, p_header: String) -> String:
	# project.godot 源文本切段：返回 p_header 段内原始行拼串（段头行不含）
	var out := ""
	var in_section := false
	for line in p_text.split("\n"):
		var t := line.strip_edges()
		if t.begins_with("[") and t.ends_with("]"):
			in_section = t == p_header
			continue
		if in_section:
			out += line + "\n"
	return out
func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("PASS | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s %s" % [p_name, p_detail])
		print("FAIL | %s | %s" % [p_name, p_detail])

# tests/qa_r293_fpscap_cases.gd（R293 刀C 独立验收用例体——入口运行时加载）
# 契约来源 = 刀C 两面：
#   A 帧率帽解锁（fps_cap 设置键）：四档 60/90/120/无帽(0) 读写 + 默认 60 不变 +
#     Engine.max_fps 接线断言。口径如实登记：本仓库 R194 已交付设置行四档循环 +
#     Meta 存档 + mobile 门内 Engine.max_fps 应用（启动读取=Meta._ready→_apply_fps_cap，
#     切档即时=settings_changed→重应用，MENU 态 60 帽/离菜单恢复用户档=R262e）——
#     桌面/headless 零写是关侧承重墙（铁律四；r194 ④/qa_r218 ①b①c/r233 C1 四处
#     既有绿锁）。故 headless 下「生效」断言=两面：①运行时墙（写档后 Engine.max_fps
#     恒 0 不被改——mobile 门 false 零写）；②源级接线锚（qa_r218 ①a/qa_r262e U3
#     同款纪律——应用器/启动/切档/菜单帽单点全在场）。
#   B drawcallsN 真机判读键：1Hz 行尾新段（追加在 弹拒N 之后、尖峰段之前——行尾
#     新段先例，既有子串逐位保持）+ 导出口径头 R293 段。源=Performance.
#     RENDER_TOTAL_DRAW_CALLS_IN_FRAME 末帧直读——R293 规格原名 RENDER_2D_DRAW_
#     CALLS_IN_FRAME 系 Godot 3 枚举、4.3 已删（tools 引擎二进制串扫定谳），4.x 的
#     Performance 帧直读通道只有 RENDER_TOTAL_*；本工程纯 2D（total≡2D）口径等价。
#     headless 无渲染恒 0 无意义（headless 门内断 0+同源直读对拍；判读只在真机行）。
#   修轮 1 补披露（缺陷 3）：90/120 档=仅解锁 Engine.max_fps 帽——物理恒 60Hz、插值
#     门=sim30_effective() 且 SIM_30HZ_ENABLED=false → 高刷上交替重复帧非顺滑；口径
#     头 R293 段新增「90/120 档体验披露」句（d7 锁锚）+ settings_panel 文案区注释。
# 夹具：SettingsPanel 真实例化（add_child 触发 _ready 全 UI 构建）+ DiagStub 诊断行
# 最小桩（qa_r269_bucketprobe DiagStub 同款）。收尾 R270 盘档毒配方：Meta 快照整字典
# 还原 + 显式 erase("perf_boost")/erase("boost_res") 再 _save；diag 导出产物用完即删。
extends RefCounted

const META_SRC := "res://scripts/meta/meta_manager.gd"
const GL_SRC := "res://scripts/loop/game_loop.gd"
const PANEL_SRC := "res://scripts/ui/settings_panel.gd"

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _saved_settings: Dictionary = {}         # Meta 快照（收尾 R270 盘档毒配方还原）
var _exported: Array[String] = []            # 本套件产出 diag 文件名（收尾删除）
var _panel: SettingsPanel = null              # B 组面板实例（收尾释放兜底——类型按
                                               # qa_r292 _menu: MenuScreen 先例取具体类，
                                               # CanvasLayer 基类会让 is_open() 静态解析失败）


class DiagStub extends Node:
	# 诊断行最小桩（_diag_format_line 鸭式消费面——qa_r269_bucketprobe DiagStub 同款）
	var state: int = 0                           # GameConst.GameStatus.BOOT
	var stage_probe_us: Dictionary = {}
	var stage_probe_us_peak: Dictionary = {}
	var counts: Dictionary = {}

	func diag_counts() -> Dictionary:
		return counts

	func diag_reset_stage_peaks() -> void:
		pass


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(293)
	_saved_settings = Meta._settings.duplicate()
	_a_settings_contract()
	await _b_panel_cycle()
	_c_diag_line_drawcalls()
	_d_export_header()
	await _cleanup()


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


# ── A：fps_cap 设置键契约（四档读写/默认 60/Engine.max_fps 生效两面） ──────────

func _a_settings_contract() -> void:
	print("── A 帧率帽解锁：fps_cap 四档读写 + 默认 60 + Engine.max_fps 接线 ──")
	# a1 默认 60 不变：缺键读口默认表回退 + 默认表本值（r194 ① 同款面）
	Meta._settings.erase("fps_cap")
	_check("a1 缺键读口回退 fps_cap=60（默认保持 60 不变）",
		int(Meta.settings("fps_cap")) == 60, str(Meta.settings("fps_cap")))
	_check("a1 默认表本值 fps_cap==60（SETTINGS_DEFAULTS）",
		int(Meta.SETTINGS_DEFAULTS.get("fps_cap")) == 60,
		str(Meta.SETTINGS_DEFAULTS.get("fps_cap")))
	# a2 四档读写（60/90/120/无帽0——写即存写口往返）
	var tiers: Array[int] = [60, 90, 120, 0]
	var roundtrip := true
	var rt_detail := ""
	for v in tiers:
		Meta.set_setting("fps_cap", v)
		if int(Meta.settings("fps_cap")) != v:
			roundtrip = false
			rt_detail += "%d→%s " % [v, str(Meta.settings("fps_cap"))]
	_check("a2 四档写读往返（60/90/120/无帽0——0=无帽语义档）", roundtrip, rt_detail)
	# a3 写口钳制复核（clampi 0~144：r194 ③ 既有契约零位移）
	Meta.set_setting("fps_cap", 200)
	var clamp_hi := int(Meta.settings("fps_cap")) == 144
	Meta.set_setting("fps_cap", -5)
	var clamp_lo := int(Meta.settings("fps_cap")) == 0
	_check("a3 写口钳制 200→144 / -5→0（clampi 0~144 既有契约）",
		clamp_hi and clamp_lo, "hi=%s lo=%s" % [str(clamp_hi), str(clamp_lo)])
	# a4 运行时墙（headless/desktop：mobile 门 false 零写——r194 ④/qa_r218 ①c 同款；
	# 铁律四关侧承重墙的断言面）
	var fps0 := Engine.max_fps
	var hz0 := Engine.physics_ticks_per_second
	Meta.set_setting("fps_cap", 90)
	var wall_set := Engine.max_fps == fps0
	Meta._apply_fps_cap()
	var wall_apply := Engine.max_fps == fps0 and Engine.physics_ticks_per_second == hz0
	_check("a4 入口 Engine.max_fps==0（headless 缺省不动）", fps0 == 0, "max_fps=%d" % fps0)
	_check("a4 写档 90 后 Engine.max_fps 恒 0（mobile 门 false 零写——关侧承重墙）",
		wall_set, "max_fps=%d" % Engine.max_fps)
	_check("a4 直调 _apply_fps_cap 后 Engine.max_fps/physics_ticks 双零写（r233 C1 同款）",
		wall_apply, "fps=%d hz=%d→%d" % [Engine.max_fps, hz0, Engine.physics_ticks_per_second])
	# a5 源级接线锚（headless 测不到 mobile 分支——照 qa_r218 ①a/qa_r262e U3 源锚纪律：
	# 应用器单点/启动读取/切档即时/MENU 帽单点+离菜单恢复/双入口接线全在场）
	# 换行归一：仓库源码 CRLF，FileAccess.get_file_as_string 不做换行翻译（原样字节）——
	# 跨行门序列锚以 \n 缝合前必须先规整（首轮红根因：python 文本读自动 CRLF→LF 掩蔽）
	var meta_src := FileAccess.get_file_as_string(META_SRC).replace("\r\n", "\n")
	var gl_src := FileAccess.get_file_as_string(GL_SRC).replace("\r\n", "\n")
	_check("a5 应用器在场：meta_manager 含 Engine.max_fps = int(settings(\"fps_cap\")) 且恰 1 处",
		meta_src.count("Engine.max_fps = int(settings(\"fps_cap\"))") == 1,
		"count=%d" % meta_src.count("Engine.max_fps = int(settings(\"fps_cap\"))"))
	_check("a5 mobile 门内应用（门守卫→应用器直连序列在场）",
		meta_src.contains("if not OS.has_feature(\"mobile\"):\n\t\treturn\n\tEngine.max_fps = int(settings(\"fps_cap\"))"),
		"gate→apply 序列缺位")
	_check("a5 启动读取+切档即时：_apply_fps_cap() 恰 3 处（定义+_ready+settings_changed）",
		meta_src.count("_apply_fps_cap()") == 3,
		"count=%d" % meta_src.count("_apply_fps_cap()"))
	_check("a5 MENU 帽 60 单点 + 离菜单恢复用户档（game_loop R262e——qa_r262e U3 同锚）",
		gl_src.count("Engine.max_fps = 60") == 1
			and gl_src.contains("Engine.max_fps = int(Meta.settings(\"fps_cap\"))"),
		"cap60=%d restore=%s" % [gl_src.count("Engine.max_fps = 60"),
			str(gl_src.contains("Engine.max_fps = int(Meta.settings(\"fps_cap\"))"))])
	_check("a5 大厅+暂停卡双入口接线（menu/pause settings_requested 双 connect 同一面板）",
		gl_src.contains("menu_screen.settings_requested.connect")
			and gl_src.contains("pause_overlay.settings_requested.connect"),
		"game_loop 双入口 connect 缺位")


# ── B：设置面板行（真实例化——四档循环/无帽文案/脏档归位） ─────────────────────

func _b_panel_cycle() -> void:
	print("── B 设置面板「帧率上限」行：四档循环 + 无帽文案 + 脏档归位 ──")
	_panel = SettingsPanel.new()
	_panel.name = "R293FpsCapPanel"
	tree.root.add_child(_panel)               # _ready 同步全 UI 构建
	var btn: Button = _panel.find_child("FpsCapButton", true, false) as Button
	_check("b1 面板实例化 + FpsCapButton 行在位（大厅/暂停卡共用的同一面板类）",
		btn != null and not _panel.is_open(), "btn=%s" % str(btn))
	if btn == null:
		return
	# b2 四拍循环：60 → 90 → 120 → 无帽(0) → 60（写即存 + 按钮文案即时刷新）
	Meta.set_setting("fps_cap", 60)
	var expect_vals: Array[int] = [90, 120, 0, 60]
	var expect_txts: Array[String] = ["✓ 90", "✓ 120", "✓ 不限", "✓ 60"]
	var cycle_ok := true
	var cycle_detail := ""
	for i in range(expect_vals.size()):
		_panel.call("_on_fps_cap_cycle")
		var v := int(Meta.settings("fps_cap"))
		if v != expect_vals[i] or btn.text != expect_txts[i]:
			cycle_ok = false
			cycle_detail += "拍%d: v=%d txt=%s（期 %d/%s） " % [i, v, btn.text,
				expect_vals[i], expect_txts[i]]
	_check("b2 四拍循环 60→90→120→无帽→60（档值+文案含「✓ 不限」=无帽档即时刷新）",
		cycle_ok, cycle_detail)
	# b3 脏档归位：非循环值（手改 144）一轮归位 60（r194 ① 注释口径）
	Meta.set_setting("fps_cap", 144)
	_panel.call("_on_fps_cap_cycle")
	_check("b3 脏档 144 一轮归位 60（find 不到归位首档）",
		int(Meta.settings("fps_cap")) == 60, str(Meta.settings("fps_cap")))
	# b4 源锚：循环档序表与行名（行为断言的静态对照面——面板源级核实；换行归一同 a5）
	var panel_src := FileAccess.get_file_as_string(PANEL_SRC).replace("\r\n", "\n")
	_check("b4 源锚：档序 [60, 90, 120, 0]（无帽=0 尾档）+ 行名「帧率上限」",
		panel_src.contains("var order: Array[int] = [60, 90, 120, 0]")
			and panel_src.contains("\"帧率上限\""), "")
	_panel.queue_free()
	await tree.process_frame
	_panel = null


# ── C：drawcallsN 键（1Hz 行尾——DiagStub 鸭式直调 _diag_format_line） ─────────

func _c_diag_line_drawcalls() -> void:
	print("── C drawcallsN：1Hz 行尾新段（弹拒N 后、尖峰段前；headless 恒 0） ──")
	var stub := DiagStub.new()
	var line: String = DebugStats._diag_format_line(stub, Time.get_ticks_msec())
	stub.free()
	var rx_draw := RegEx.new()
	rx_draw.compile(" drawcalls(\\d+)( 尖峰[^ ]+)?$")
	var m := rx_draw.search(line)
	_check("c1 行含 drawcallsN 键且为行尾段（其后仅允许 尖峰 标记/行尾）",
		m != null, "tail=%s" % line.right(64))
	if m == null:
		return
	_check("c2 键位序：副武µs < 弹拒 < drawcalls（追加在 弹拒N 之后——既有子串零挪动）",
		line.find(" 副武µs") >= 0 and line.find(" 弹拒") > line.find(" 副武µs")
			and line.find(" drawcalls") > line.find(" 弹拒"),
		"副武@%d 弹拒@%d drawcalls@%d" % [line.find(" 副武µs"), line.find(" 弹拒"),
			line.find(" drawcalls")])
	var v := int(m.get_string(1))
	_check("c3 数值可解析且 ≥0（Performance 监视器整形口径）", v >= 0, "v=%d" % v)
	if DisplayServer.get_name() == "headless":
		var fresh := int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
		_check("c4 headless 恒 0 且与同源直读一致（无渲染=口径无意义，判读只在真机行）",
			v == 0 and v == fresh, "line=%d fresh=%d" % [v, fresh])


# ── D：导出口径头 R293 段（diag_export 真链 + 产物用完即删） ────────────────────

func _d_export_header() -> void:
	print("── D 导出口径头：R293 段在场 + 整头未崩（R287 百分号教训回归面） ──")
	var r: Dictionary = DebugStats.diag_export()
	var text := str(r.get("text", ""))
	var path := str(r.get("path", ""))
	if path.begins_with("user://"):
		_exported.append(path.substr("user://".length()))
	_check("d1 导出成功（整头起底未崩——R287 格式串整头炸的回归面）",
		text.begins_with("=== Infinite Fission 真机诊断日志 ===") and path != "",
		"len=%d path=%s" % [text.length(), path])
	_check("d2 口径头含 R293 段（刀C 双面：drawcallsN + 帧率上限行）",
		text.contains("R293 刀C") and text.contains("drawcallsN=Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME")
			and text.contains("帧率上限行（fps_cap）"),
		"R293@%d" % text.find("R293 刀C"))
	_check("d3 R293 段追加位：紧接 R291 承句之后（口径头段序 R220→…→R291→R293）",
		text.contains("·R291 承）；R293 刀C"), "")
	_check("d4 R293 段口径披露：默认 60 不变 + headless 无意义声明 + mobile 门/桌面零写承重墙",
		text.contains("默认 60 不变") and text.contains("headless 无渲染恒 0 无意义")
			and text.contains("桌面/headless 恒 0 不被改"),
		"默认@%d headless@%d 零写@%d" % [text.find("默认 60 不变"),
			text.find("headless 无渲染恒 0 无意义"), text.find("桌面/headless 恒 0 不被改")])
	_check("d7 R293 修轮 1 体验披露：90/120 档=仅解锁 max_fps 帽（物理恒 60Hz/插值门关→交替重复帧）+ 第二批必做决策在场",
		text.contains("90/120 档体验披露") and text.contains("交替重复帧")
			and text.contains("第二批必做决策"),
		"披露@%d 重复帧@%d 决策@%d" % [text.find("90/120 档体验披露"),
			text.find("交替重复帧"), text.find("第二批必做决策")])
	_check("d5 百分号纪律回归面：R269 促N 句单百分号渲染在场（源码双百分号转义链路活——R287 整头崩教训）",
		text.contains("0 关/1 开85%/2 开75%"), "促N 句缺失")
	_check("d6 产物在盘（user:// 文件——收尾统一删除）",
		path != "" and FileAccess.file_exists(path), path)


# ── 收尾（R270 盘档毒配方 + 产物清理） ─────────────────────────────────────────

func _cleanup() -> void:
	print("── 收尾（Meta 还原/R270 毒配方/产物删除） ──")
	if _panel != null and is_instance_valid(_panel):
		_panel.queue_free()
		await tree.process_frame
	var dir := DirAccess.open("user://")
	if dir != null:
		for fname in _exported:
			if dir.file_exists(fname):
				dir.remove(fname)
	# R270 盘档毒配方：快照整字典还原 + 本套件可致写面显式 erase 再落盘
	Meta._settings = _saved_settings.duplicate()
	Meta._settings.erase("perf_boost")
	Meta._settings.erase("boost_res")
	Meta._save()
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)
	print("验收汇总：%d/%d 通过" % [_pass, _pass + _fail])

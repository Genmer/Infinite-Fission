# tests/probe_r244_menu.gd（R244 修A 端到端验证探针：菜单物理窗预热迁轴 只读入口）
# 跑法（窗口跑——物理计时才有意义；跑完自退，全程静音）：
#   APPDATA="E:/Code/Agent/Infinite-Fission/.qa_sandbox_r244" \
#   E:/Code/Agent/Infinite-Fission/tools/Godot_v4.3-stable_win64_console.exe \
#     --path E:/Code/Agent/Infinite-Fission/repo --rendering-method gl_compatibility \
#     --audio-driver Dummy -s tests/probe_r244_menu.gd
# 目的：修A（R244）把 MENU 态贴图预热从 _physics_process 物理窗迁 _process 渲染轴。
# 验证三点（vc53 真机菜单行 物步µs 45-77ms 的桌面端到端复验）：
#   ① 全队列（含 boss 双面 14 项——R215 实测单项 88-245ms）在渲染轴消化清空；
#   ② 消化全程物理窗 TIME_PHYSICS_PROCESS 恒平底（阈值门：max ≤12ms 桌面——修前
#      boss 项必在物理窗打出 88-245ms 尖峰；12ms=引擎空物理块桌面余量界，非紧界）；
#   ③ 渲染轴如实吸收重项成本（max render 帧披露——R222 占空还账下低频出现，不入门）。
# 留档：docs/qa/probe_r244_menu.json。
# 纪律：-s 入口编译期先于 autoload 注册——入口零工程类名直引（全鸭子运行时取）；
#   只读不改游戏代码（重建队调用产品公开 boot 口）；无 test_ 前缀不入电池；watchdog
#   兜底 quit()；窗口跑必须 APPDATA 沙箱（user:// 真档零接触）。
extends SceneTree

const MAIN_SCENE := "res://scenes/main.tscn"
const OUT_JSON := "res://docs/qa/probe_r244_menu.json"
const WATCHDOG_S := 120.0
const RUN_FRAMES := 1300                     # ~20s@60vsync（实测全队 167 项远在窗内清完）
const PHYS_MAX_US_GATE := 12000              # ② 门：物理窗平底界（桌面）
const RENDER_DISCLOSE_MS := 300.0            # ③ 披露界：渲染帧 max（不入门，打印披露）


func _initialize() -> void:
	set_auto_accept_quit(false)
	var wd := create_timer(WATCHDOG_S)
	wd.timeout.connect(func() -> void:
		print("WATCHDOG | 探针 %ds 未收尾，强制退出（退出码 2）" % int(WATCHDOG_S))
		quit(2))
	_run()


func _run() -> void:
	await process_frame
	await process_frame
	print("══ R244 修A 验证：菜单预热迁渲染轴（物理窗平底 / 渲染轴清队）══")
	var fails := 0
	# boot（沙箱档：auto_select_on 默认关——挂机自动出口零扰动）
	var meta_autoload: Object = get_root().get_node_or_null(^"/root/Meta")
	if meta_autoload != null:
		meta_autoload.call(&"begin_persist_defer")
	var scene: PackedScene = load(MAIN_SCENE)
	var gl: Node = scene.instantiate()
	gl.name = "ProbeR244Menu"
	get_root().add_child(gl)
	await process_frame
	await process_frame
	if not (bool(gl.get("boot_ready")) and int(gl.get("state")) == 1):  # 1=MENU（GameConst.GameStatus 枚举序：BOOT0/MENU1）
		print("PROBE FAIL | boot 未达 MENU（boot_ready=%s state=%s）"
			% [str(gl.get("boot_ready")), str(gl.get("state"))])
		quit(1)
		return
	# 重建全量预热队列（产品公开 boot 口；boot 期菜单帧可能已消化部分——重建=满队含 boss）
	gl.call(&"_boot_prewarm_textures")
	var queue: Array = gl.get("_tex_prewarm_queue")
	var queue0: int = queue.size()
	# 采样窗：每渲染帧保 dwell=99（boss 挂机门恒开——测的是消化路径不是门）；物理活跃帧
	# 读 TIME_PHYSICS_PROCESS（帧间不复位判重——debug_stats 同口径）；渲染 delta 计时。
	var phys_us_max: int = 0
	var phys_us_sum: int = 0
	var phys_samples: int = 0
	var render_ms_max: float = 0.0
	var last_pf := -1
	var t_last := Time.get_ticks_usec()
	for i in range(RUN_FRAMES):
		gl.set("_menu_dwell_s", 99.0)
		await process_frame
		var pf := Engine.get_physics_frames()
		if pf != last_pf:
			last_pf = pf
			var mon := int(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000000.0)
			phys_us_max = maxi(phys_us_max, mon)
			phys_us_sum += mon
			phys_samples += 1
		var now := Time.get_ticks_usec()
		render_ms_max = maxf(render_ms_max, float(now - t_last) / 1000.0)
		t_last = now
	var queue_left: int = (gl.get("_tex_prewarm_queue") as Array).size()
	# ① 清队门（渲染轴消化全队列）
	var g1: bool = queue_left == 0
	if not g1:
		fails += 1
	print("  %s | ① 渲染轴清队（%d → 0）" % ["PASS" if g1 else "FAIL", queue0])
	# ② 物理窗平底门
	var g2: bool = phys_us_max <= PHYS_MAX_US_GATE
	if not g2:
		fails += 1
	print("  %s | ② 物理窗平底（max=%dµs ≤ %dµs；均值=%dµs 样本=%d）"
		% ["PASS" if g2 else "FAIL", phys_us_max, PHYS_MAX_US_GATE,
			phys_us_sum / maxi(phys_samples, 1), phys_samples])
	# ③ 渲染轴披露（重项如实吸收——预期 max≈88-300ms 低频出现，非门）
	print("  披露 | ③ 渲染帧 max=%.1fms（界 %.0fms 内=%s——重项成本迁轴后的落点，不入门）"
		% [render_ms_max, RENDER_DISCLOSE_MS, str(render_ms_max <= RENDER_DISCLOSE_MS)])
	# JSON 留档
	var root := {
		"meta": {"date": "2026-10-08", "purpose": "R244 修A：MENU 预热迁渲染轴端到端验证",
			"adapter_api": RenderingServer.get_video_adapter_api_version(),
			"headless": DisplayServer.get_name() == "headless",
			"user_dir": OS.get_user_data_dir()},
		"queue0": queue0, "queue_left": queue_left,
		"phys_us_max": phys_us_max, "phys_us_mean": phys_us_sum / maxi(phys_samples, 1),
		"phys_samples": phys_samples, "render_ms_max": render_ms_max,
		"gate_phys_max_us": PHYS_MAX_US_GATE,
		"gates": {"queue_drained": g1, "phys_flat": g2},
	}
	var f := FileAccess.open(OUT_JSON, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(root, "\t"))
		f.close()
		print("留档：%s" % OUT_JSON)
	gl.queue_free()
	await process_frame
	await process_frame
	# Meta 挂起保持到进程退出（probe_r237 同款——零 user:// 写）
	if fails > 0:
		print("PROBE 汇总：%d 项门未过" % fails)
		quit(1)
	else:
		print("PROBE 汇总：硬门全过（修A 菜单物理窗平底实证）")
		quit(0)

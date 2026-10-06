# tests/probe_r237_renderattr.gd（R237 战斗期渲染轴归因探针 只读入口）
# 跑法（窗口=真渲染器；会弹真窗口，跑完自退；全程静音）：
#   APPDATA="E:/Code/Agent/Infinite-Fission/.qa_sandbox_r237" \
#   E:/Code/Agent/Infinite-Fission/tools/Godot_v4.3-stable_win64_console.exe \
#     --path E:/Code/Agent/Infinite-Fission/repo --rendering-method gl_compatibility \
#     --audio-driver Dummy -s tests/probe_r237_renderattr.gd
# 短窗烟测（boot+菜单臂+战斗臂+M2+三快刀臂 缩短窗走通管线，不落 JSON）：
#   … 同上命令，末尾追加  --  --smoke
# 目的（R237 归因轮·渲染轴）：真机 vc40 深载（敌120/弹200-400/dc 600-1010）渲ms
#   13-17ms vs 菜单 8.4ms——进战斗渲染轴翻倍独占 60fps 预算线。本探针复用/更新
#   R230 dcscan 夹具（13 族 dc 谱 + RS 层族掩码望远镜），叠加 R237 物理相归因的
#   自然驱动定标（60Hz 帽 + 敌血×1.0，敌 115-120 常驻、弹 280-350——勿复踩 120Hz
#   崩帧与敌血 0.3 弹股级联两坑），产出：
#   M1 十三族 dc 谱 + 桶遥测 + 渲ms 同式键（战斗 vs 菜单增量份额排序）；
#   M2 断批归因（桶计数 vs dc 相关性 + 敌桶穿插件逐件 dc——R228 口径）；
#   M3 三把快刀独立 A/B（跳字帽 8 / 敌装饰全隐 / fx 层全关——测量证非叠加出刀）。
# 纪律：-s 入口编译期先于 autoload 注册——入口零工程类名直引（全鸭子），用例体运行时
#   加载（qa_r230 同构）；只读不改游戏代码；无 test_ 前缀不入电池；watchdog 兜底任何
#   路径最终 quit()（不留窗口僵尸进程）；窗口跑必须 APPDATA 沙箱（user:// 真档零接触）。
extends SceneTree

const CASES_PATH := "res://tests/probe_r237_renderattr_cases.gd"
const WATCHDOG_S := 2400.0                      # 菜单~50s+战斗(饱和暖≤150+基40+谱~30)+四刀臂×(settle+40+40)≈12-15min；40min 硬帽纯兜底


func _initialize() -> void:
	# 任何路径保证 quit：含用例体脚本错误挂起——watchdog 引擎侧定时器独立于协程，
	# 超时强退退出码 2（跑后主控照例 tasklist 查杀残留 Godot 进程）。窗口 X/系统关窗
	# 请求不再直接退进程——退出唯一出口=本脚本显式 quit（qa_r230 同款）。
	set_auto_accept_quit(false)
	var wd := create_timer(WATCHDOG_S)
	wd.timeout.connect(func() -> void:
		print("WATCHDOG | 探针 %ds 未收尾，强制退出（退出码 2——查窗口僵尸/夹具卡死）" % int(WATCHDOG_S))
		quit(2))
	_run()


func _run() -> void:
	await process_frame
	await process_frame
	# 渲染法：4.3 引擎自吞已识别旗标（--rendering-method 不出现在 get_cmdline_args）→
	# 工程设置读数仅回退默认；实际生效渲染器以显卡 API 版本侧写（OpenGL 3.3.x=
	# gl_compatibility 生效；Vulkan 版本串=forward_plus）——qa_r230/probe_r237 同款
	var rmethod := str(ProjectSettings.get_setting_with_override(
		&"rendering/renderer/rendering_method"))
	var args := OS.get_cmdline_args()
	for i in range(args.size() - 1):
		if String(args[i]) == "--rendering-method":
			rmethod = String(args[i + 1])
	print("RENDERATTR 环境头：rendering(project/旗标扫)=%s adapter_api=%s headless=%s user_dir=%s phys_hz=%d" % [
		rmethod, RenderingServer.get_video_adapter_api_version(),
		str(DisplayServer.get_name() == "headless"), OS.get_user_data_dir(),
		Engine.physics_ticks_per_second])
	var body: GDScript = load(CASES_PATH)
	if body == null or not body.can_instantiate():
		print("PROBE FAIL | 用例体加载失败：%s" % CASES_PATH)
		quit(1)
		return
	var cases: Object = body.new()
	await cases.run(self)
	var fails: int = int(cases.call(&"fail_count"))
	if fails > 0:
		print("PROBE 汇总：%d 项硬门未过（见上 FAIL 行；FAIL*=披露类失配不计数）" % fails)
		quit(1)
	else:
		print("PROBE 汇总：硬门全过（数字已留档 docs/qa/probe_r237_renderattr.json）")
		quit(0)

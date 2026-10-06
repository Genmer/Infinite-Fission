# tests/probe_r237_deferattr.gd（R237 延迟冲刷桶 suppression 三臂归因 只读入口）
# 跑法（窗口=与 physattr 同构深载；跑完自退，全程静音）：
#   APPDATA="E:/Code/Agent/Infinite-Fission/.qa_sandbox_r237" \
#   E:/Code/Agent/Infinite-Fission/tools/Godot_v4.3-stable_win64_console.exe \
#     --path E:/Code/Agent/Infinite-Fission/repo --rendering-method gl_compatibility \
#     --audio-driver Dummy -s tests/probe_r237_deferattr.gd
# 若窗口起不来（无显示器会话等）允许降级 headless 并在 JSON meta.headless 如实标注
#（去 APPDATA 前缀 + 加 --headless——headless 走 *_test.cfg 惯例档无需沙箱）。
# 短窗烟测（D0/D1/D2/D3 缩短窗走通管线，不落 JSON）：
#   … 同上命令，末尾追加  --  --smoke
# 目的（R237 归因轮·第三棒）：物理相归因（probe_r237_physattr）已裁定 H2——物理空间
# 无罪，真嫌疑=物理块内 message_queue flush 执行的延迟调用桶（桌面深载 resid_alt
# 18-19ms/步）。本探针对发射源做 suppression 三臂差分，给桶构成饼：
#   D0 基线（现状深载）/ D1 popup 抑制（damage_numbers_on 哨兵关——popup 链份额）/
#   D2 死亡表现抑制（DeathPop 发射归零——死亡链份额）/ D3 fx 抑制（fx 层隐藏+色差
#   RS 隐藏+fx_opacity 地板——fx 份额）+ D0B 基线复跑（漂移带钉——差值可信度界）。
# 判读：三臂差值合计 vs D0 残差 → 饼（popup/死亡链/fx/其他）；<30% 则「其他」大头
# 嫌疑=引擎步本体或 queue_free/桶place 等未覆盖延迟调用，如实披露。
# 纪律：-s 入口编译期先于 autoload 注册——入口零工程类名直引（全鸭子），用例体运行时
#   加载（probe_r237_physattr/renderattr 同构）；只读不改游戏代码；无 test_ 前缀不入
#   电池；watchdog 兜底任何路径最终 quit()（不留窗口僵尸进程）；窗口跑必须 APPDATA
#   沙箱（user:// 真档零接触）。
extends SceneTree

const CASES_PATH := "res://tests/probe_r237_deferattr_cases.gd"
const WATCHDOG_S := 1080.0                       # 5 臂×(预热+≥40s 测量)+boot ≈7-9min；18min 硬帽纯兜底


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
	# 渲染法：4.3 引擎自吞已识别旗标 → 工程设置读数仅回退默认；实际生效渲染器以显卡
	# API 版本侧写（OpenGL 3.3.x=gl_compatibility 生效）
	var rmethod := str(ProjectSettings.get_setting_with_override(
		&"rendering/renderer/rendering_method"))
	var args := OS.get_cmdline_args()
	for i in range(args.size() - 1):
		if String(args[i]) == "--rendering-method":
			rmethod = String(args[i + 1])
	print("DEFERATTR 环境头：rendering(project/旗标扫)=%s adapter_api=%s headless=%s user_dir=%s phys_hz=%d" % [
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
		print("PROBE 汇总：硬门全过（四臂数字已留档 docs/qa/probe_r237_deferattr.json）")
		quit(0)

# tests/probe_r237_physattr.gd（R237 物理相归因 A/B 探针 只读入口）
# 跑法（窗口=真渲染压力，物理计时才有意义；跑完自退，全程静音）：
#   APPDATA="E:/Code/Agent/Infinite-Fission/.qa_sandbox_r237" \
#   E:/Code/Agent/Infinite-Fission/tools/Godot_v4.3-stable_win64_console.exe \
#     --path E:/Code/Agent/Infinite-Fission/repo --rendering-method gl_compatibility \
#     --audio-driver Dummy -s tests/probe_r237_physattr.gd
# 若窗口起不来（无显示器会话等）允许降级 headless 并在 JSON meta.headless 如实标注
#（去 APPDATA 前缀 + 加 --headless——headless 走 *_test.cfg 惯例档无需沙箱）。
# 短窗烟测（CAL0+boot+A0/A1/A2 缩短窗走通管线，不落 JSON）：
#   … 同上命令，末尾追加  --  --smoke
# 目的（R237 归因轮）：真机 vc40 深载「物步µs」= 引擎物理相 15-64ms/物理活跃渲染帧
#（菜单基线 1.2-1.7ms），而物理空间成员仅 敌 HitArea Area2D×120 + 玩家 Area2D。
# 两假设裁定：
#   H1 = 物理空间真有未知大成本（Area2D 同步/broadphase/信号）→ 清退刀成立；
#   H2 = 扣减公式伪影（段和未覆盖 GameLoop 全部成本 → 残差被记进 物步µs）→ 先修账。
# 四臂（A0 基线 / A1 敌双监测关 / A2 +玩家双监测关 / A3 敌数 30/60/120 梯度）+
#   CAL0 引擎监视器语义标定（TIME_PHYSICS_PROCESS=整帧物理块和 vs 仅末步——同构
#   Godot 4.3 实证，归因公式判读前置）。数字落 docs/qa/probe_r237_physattr.json。
# 纪律：-s 入口编译期先于 autoload 注册——入口零工程类名直引（全鸭子），用例体运行时
#   加载（probe_r224/qa_r230 同构）；只读不改游戏代码；无 test_ 前缀不入电池；watchdog
#   兜底任何路径最终 quit()（不留窗口僵尸进程）；窗口跑必须 APPDATA 沙箱（user:// 真档
#   零接触——RunSave 波次边界写档全部进沙箱）。
extends SceneTree

const CASES_PATH := "res://tests/probe_r237_physattr_cases.gd"
const WATCHDOG_S := 900.0                        # 6 臂×(预热+≥40s 测量)+boot ≈6-7min；15min 硬帽纯兜底


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
	# 渲染法：4.3 引擎自吞已识别旗标（--rendering-method 不出现在 get_cmdline_args，
	# 实测 ARGS=["-s", ...]）→ 工程设置读数仅是回退默认；实际生效渲染器以显卡 API 版本
	# 侧写（OpenGL 3.3.x=gl_compatibility 生效；Vulkan 版本串=forward_plus）
	var rmethod := str(ProjectSettings.get_setting_with_override(
		&"rendering/renderer/rendering_method"))
	var args := OS.get_cmdline_args()
	for i in range(args.size() - 1):
		if String(args[i]) == "--rendering-method":
			rmethod = String(args[i + 1])
	print("PHYSATTR 环境头：rendering(project/旗标扫)=%s adapter_api=%s headless=%s user_dir=%s phys_hz=%d" % [
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
		print("PROBE 汇总：硬门全过（四臂数字已留档 docs/qa/probe_r237_physattr.json）")
		quit(0)

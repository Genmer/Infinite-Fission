# tests/runner/test_r202_perf.gd
# R202 性能季·自测入口（SceneTree 脚本：godot --headless --path <工程>
#   -s tests/runner/test_r202_perf.gd）。
# G4「帧率显示功能」（fpsFeature）：show_fps 键契约 / HUD FpsLabel 急切创建+空带落位+
# 仅启用期 _process 刷新 / 设置面板「显示帧率」行塞卡不扩卡高。
# 结构说明（同 test_r195_adapt/test_r198）：-s 脚本模式下入口脚本编译早于 autoload
# 全局名注册，入口只做引导；用例体 r202_perf_cases.gd 经运行时 load 编译。
extends SceneTree

const CASES_PATH := "res://tests/runner/r202_perf_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R202 性能季（G4 帧率显示）自测 ══════════")
	# 等引擎注册的 autoload 完成 add_child + _ready（EventBus→GameConfig→DebugStats→Meta）
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	if cases_script == null or not cases_script.can_instantiate():
		# 用例体编译失败（load 已打印解析错误）——立即失败退出（防 -s 套件悬挂电池）
		print("FAIL | 用例体加载失败（cases=%s）" % str(cases_script))
		print("验收汇总：0/1 通过")
		quit(1)
		return
	var cases = cases_script.new()
	await cases.run(self)
	var pass_count: int = cases.pass_count()
	var fail_count: int = cases.fail_count()
	print("验收汇总：%d/%d 通过" % [pass_count, pass_count + fail_count])
	if fail_count > 0:
		quit(1)
	else:
		quit(0)

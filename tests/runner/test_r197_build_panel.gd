# tests/runner/test_r197_build_panel.gd
# R197 构筑面板竖排两列·QA 补强自测入口（SceneTree 脚本：godot --headless --path <工程>
#   -s tests/runner/test_r197_build_panel.gd）
# 覆盖：r196_growth ③竖两列断言的宝石列空转缺口（真实词条夹具）+ 左列几何/锁槽居中/
#   断触零 STOP/内容出界/签名驱动重建与防抖。
# 结构说明（同 pkg/r195/r196）：-s 脚本模式下入口脚本编译早于 autoload 全局名注册，
# 入口只做引导；用例体经运行时 load 编译——此时 autoload 已就绪。
extends SceneTree

const CASES_PATH := "res://tests/runner/r197_build_panel_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R197 构筑面板竖排两列·QA 补强验证 ══════════")
	# 等引擎注册的 autoload 完成 add_child + _ready（EventBus→GameConfig→DebugStats→Meta）
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	if cases_script == null or not cases_script.can_instantiate():
		# 用例体编译失败（load 已打印解析错误）——立即失败退出（防 -s 套件悬挂电池；
		# 解析错 load 返回非 null 但不可实例化的 GDScript，须 can_instantiate 复查）
		print("FAIL | 用例体加载失败（cases=%s）" % str(cases_script))
		print("验收汇总：0/1 通过")
		quit(1)
		return
	var cases = cases_script.new()
	await cases.run(self)
	var fail_count: int = cases.fail_count()
	if fail_count > 0:
		quit(1)
	else:
		quit(0)

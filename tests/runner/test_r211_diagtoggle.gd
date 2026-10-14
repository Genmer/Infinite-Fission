# tests/runner/test_r211_diagtoggle.gd
# R211 诊断日志采样开关自测入口（SceneTree 脚本：godot --headless --path <工程>
#   -s tests/runner/test_r211_diagtoggle.gd）
# 覆盖：默认开不突变（旧档缺键回退 true）+ Meta 双注册（默认表+bool 归一分支）
#   + 采样门（关=停采不停表、已存缓冲保留、重开即恢复）+ 导出/清空不受影响
#   + 持久化（meta_save_test.cfg settings/values 落盘与 _load 重读）
#   + 主菜单「记录日志」按钮（✓/✗ 态 + pressed 即时翻转采样行为）。
extends SceneTree

const CASES_PATH := "res://tests/runner/r211_diagtoggle_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R211 诊断日志采样开关验收 ══════════")
	# 等引擎注册的 autoload 完成 add_child + _ready（EventBus→GameConfig→DebugStats→Meta）
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	if cases_script == null or not cases_script.can_instantiate():
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

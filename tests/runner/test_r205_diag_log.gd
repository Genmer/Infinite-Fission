# tests/runner/test_r205_diag_log.gd
# R205 真机诊断日志四件套自测入口（SceneTree 脚本：godot --headless --path <工程>
#   -s tests/runner/test_r205_diag_log.gd）
# 覆盖：版本真源（config/version 烤入）+ 1Hz 环形缓冲 + 行格式（无/有 GameLoop 两态）
#   + mobile 探针开关注 + diag_counts + diag_export（文件/头字段）+ 剪贴板 headless 门
#   + 主菜单「导出日志」按钮与对话框 + EventBus 风暴告警节流（计数口径不变）。
extends SceneTree

const CASES_PATH := "res://tests/runner/r205_diag_log_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R205 真机诊断日志验收 ══════════")
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

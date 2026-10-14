# tests/runner/test_r212_diaglog2.gd
# R212 诊断日志升级自测入口（SceneTree 脚本：godot --headless --path <工程>
#   -s tests/runner/test_r212_diaglog2.gd）
# 覆盖（用户三诉求）：①「记录日志」开关从主菜单底带迁入设置页 +「日志长度」档位行
#   60/120/240/360 默认 240；②LEVEL_UP 选卡期不采样（节拍不消费、已存行保留、退出
#   补采）；③容量设置驱动（diag_log_len 双注册/缩容保留最新 N 条/封顶不增长/扩容
#   转正/导出头「采样 1Hz × N 行环形」动态化）+ 迁移断言（菜单按钮已移除）。
extends SceneTree

const CASES_PATH := "res://tests/runner/r212_diaglog2_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R212 诊断日志升级验收 ══════════")
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

# tests/runner/test_r194_mobile.gd
# R194 移动端统包入口（SceneTree 脚本：godot --headless --path <工程> -s tests/runner/test_r194_mobile.gd）
# 结构同 pkg0~pkg5：-s 模式下入口脚本编译早于 autoload 全局名注册 → 入口只做引导；
# 用例体经运行时 load 编译（此时 autoload 已就绪）。
# 链接两份用例体（R194 同一变更集，id r194_mobile 全局唯一）：
#   · r194_mobile_cases.gd —— 采样守卫 / BuildPanel 松手阈值 / UI 几何 / 设置键契约
#   · export_data_cases.gd —— 导出数据链探针 T1-T7（收编 disc1/disc5 草探针；无独立 -s 入口）
extends SceneTree

const CASES_PATH := "res://tests/runner/r194_mobile_cases.gd"
const EXPORT_CASES_PATH := "res://tests/runner/export_data_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R194 移动端统包 ══════════")
	# 等引擎注册的 autoload 完成 add_child + _ready（EventBus→GameConfig→DebugStats）
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	var export_script: GDScript = load(EXPORT_CASES_PATH)
	if cases_script == null or export_script == null:
		# 用例体编译失败（load 已打印解析错误）——立即失败退出（防 -s 套件悬挂电池）
		print("FAIL | 用例体加载失败（cases=%s export=%s）" % [str(cases_script), str(export_script)])
		print("验收汇总：0/1 通过")
		quit(1)
		return
	var cases = cases_script.new()
	cases.run(self)
	var export_cases = export_script.new()
	export_cases.run(self)
	# 双用例体聚合计数（get("_pass") 读脚本成员——用例体只暴露 fail_count()，
	# 通过数经 Object.get 取，零接口侵入）
	var total_pass: int = int(cases.get("_pass")) + int(export_cases.get("_pass"))
	var total_fail: int = cases.fail_count() + export_cases.fail_count()
	print("验收汇总：%d/%d 通过" % [total_pass, total_pass + total_fail])
	if total_fail > 0:
		quit(1)
	else:
		quit(0)

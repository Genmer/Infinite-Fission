# tests/runner/test_r190b_tips.gd
# R190b tips 详情卡/tooltip 自测入口（godot --headless --path <工程根>
# -s tests/runner/test_r190b_tips.gd）。真源：R191 G2「tips 详情卡」七项定案。
# 用例体：r190b_tips_cases.gd（A. theme() Tooltip 全局条目 / B. 详情卡机制句逐字 /
# C. 无武器空态不崩）。
extends SceneTree

const CASES_PATH := "res://tests/runner/r190b_tips_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R190b tips（tooltip 全局样式 + 详情卡机制句）自测 ══════════")
	await process_frame
	await process_frame
	# 看门狗：用例体脚本错误中止协程时强制退出（防挂死——电池调度按退出码仲裁）
	var watchdog: SceneTreeTimer = create_timer(240.0)
	watchdog.timeout.connect(_on_watchdog)
	var cases_script: GDScript = load(CASES_PATH)
	var cases = cases_script.new()
	cases.run(self)
	var fail_count: int = cases.fail_count()
	if fail_count > 0:
		quit(1)
	else:
		quit(0)


func _on_watchdog() -> void:
	print("[watchdog] 套件超时/协程中止——强制退出（3）")
	quit(3)

# tests/runner/test_w5_mirror.gd
# R187 W5「万镜回廊」棱镜镜面军团自测入口（godot --headless --path <工程>
# -s tests/runner/test_w5_mirror.gd）。真源：R187_WEAPON_REWORK §2.2 五方向定案。
# 用例体：w5_mirror_cases.gd（验收 1-9 映射 + 数据真删/激光镜帽/会话态语义）。
extends SceneTree

const CASES_PATH := "res://tests/runner/w5_mirror_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · W5 万镜回廊（棱镜镜面军团）自测 ══════════")
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

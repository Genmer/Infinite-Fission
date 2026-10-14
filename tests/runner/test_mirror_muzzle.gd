# tests/runner/test_mirror_muzzle.gd
# R191#2 镜面枪口锚点 + 镜面火花自测入口（godot --headless --path <工程>
# -s tests/runner/test_mirror_muzzle.gd）。真源：R191 用户反馈 #2
# 「枪口不在镜子也不在复制出的加特林身上」（锚点经外层 MirrorImage 别名查册 +
# 镜面开火冰晶火花读感）。用例体：mirror_muzzle_cases.gd。
extends SceneTree

const CASES_PATH := "res://tests/runner/mirror_muzzle_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R191#2 镜面枪口锚点自测 ══════════")
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

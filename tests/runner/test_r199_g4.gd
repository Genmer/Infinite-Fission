# tests/runner/test_r199_g4.gd
# R199 G4 武器数据与面板文案组 自测入口（godot --headless --path <工程根>
# -s tests/runner/test_r199_g4.gd）。真源：docs/design/R199_RELEASE_SWEEP.md §二 G4。
# 用例体：r199_g4_cases.gd
#   A. N02 W3 霰弹枪 L3 pellets 9→8 真值回修（A3 §3.3 对齐，L3→L4 恢复真实增益）
#   B. N05+F08 暂停面板词条总值弃用 stacked_add_total → aggregate_panel 超帽 ×0.7 口径
#   C. N06 十武器 note 文案卫生（玩家可读，零开发行话/内部 id）+ 渲染链实捕
#   D. P08 拖动教学文案真源（GameConst）+ lore 菜单行 + HUD 战斗内首局一次性提示
extends SceneTree

const CASES_PATH := "res://tests/runner/r199_g4_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R199 G4（武器数据与面板文案）自测 ══════════")
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

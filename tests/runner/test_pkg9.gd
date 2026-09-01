# tests/runner/test_pkg9.gd
# v0.9.0 验收入口（SceneTree 脚本：godot --headless --path <工程> -s tests/runner/test_pkg9.gd）
# 覆盖（A8_v0.9.0_design.md 冻结方案 pkg9 用例组；两段式同 pkg0~pkg8：入口只做引导，
# 用例体运行时 load——autoload 未注册阶段不编译用例）：
#   G1 数据镜像 / G2 可用池 / G3 加权 roll / G4 出牌过滤 / G5 效果（套装隔离）/
#   G6 时序门控 / G7 排空竞态 / G8 UI 契约 / G9 ChipHandler 扩展。
extends SceneTree

const CASES_PATH := "res://tests/runner/pkg9_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · v0.9.0 波次赐福 + 芯片槽位扩展 验收 ══════════")
	# 等引擎注册的 autoload 完成 add_child + _ready（EventBus→GameConfig→DebugStats）
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	var cases = cases_script.new()
	cases.run(self)
	var fail_count: int = cases.fail_count()
	if fail_count > 0:
		quit(1)
	else:
		quit(0)

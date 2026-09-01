# tests/runner/test_pkg8.gd
# v0.8.0 自测入口（SceneTree 脚本：godot --headless --path <工程> -s tests/runner/test_pkg8.gd）
# 覆盖（A7_v0.8.0_design.md 增量，按 V 任务分节、逐步累计）：
#   V14 副词条（独立流/roll_substats/equip 三参/聚合）· V15 套装 ×1.10 · V6 诅咒运行时 ·
#   V9 词条移除/净化 · V10/11 商店扩容 · V1~V4 事件链 · V17~V19 角色 · V21/22 冲刺 ·
#   V5/8/12/16/20/23 收口段。
#
# 结构说明（同 pkg0~pkg7）：-s 脚本模式下入口脚本编译早于 autoload 全局名注册，
# 入口只做引导；用例体 pkg8_cases.gd 经运行时 load 编译——此时 autoload 已就绪。
extends SceneTree

const CASES_PATH := "res://tests/runner/pkg8_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · v0.8.0 自测 ══════════")
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

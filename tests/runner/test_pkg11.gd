# tests/runner/test_pkg11.gd
# v1.1.0 自测入口（元素反应二期：增幅双轨/精通/CD 分立；两段式同 pkg0~pkg10：
#   godot --headless --path <工程> -s tests/runner/test_pkg11.gd）
# 覆盖冻结方案 pkg11 用例组 V25~V40（A10_v1.1.0_design.md；每恰 1 断言）：
#   V25 恒等护栏 / V26 融化 / V27 蒸发 / V28 排除面 / V29 穿透独立 / V30 管线 veto
#   V31 top-8 截断 / V32 联合钳 / V33 精通注册 / V34 φ 聚合 / V35 CD 分立
#   V36 遥测分键 / V37 popup 后缀 / V38 HUD MP / V39 拼写回归 / V40 gauge 残留
extends SceneTree

const CASES_PATH := "res://tests/runner/pkg11_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · v1.1.0 元素反应二期自测（pkg11 V25~V40） ══════════")
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

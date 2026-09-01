# tests/runner/test_pkg12.gd
# v1.2.0 自测入口（元素三期：WAT 基建 / ELE_TIDE / 三剧变 / 增幅升格 / 元素盾 / 表现六反；
# 两段式同 pkg0~pkg11：godot --headless --path <工程> -s tests/runner/test_pkg12.gd）
# 覆盖冻结方案 pkg12 用例组 V41~V56（A11_v1.2.0_design.md；每恰 1 断言）：
#   V41 WAT 基建 / V42 TIDE / V43 冻结触发 / V44 冻结全停 / V45 破碎
#   V46 导电 / V47 汽爆 / V48 淬火 / V49 升格 / V50 盾数据 / V51 盾运行期 / V52 盾环
#   V53 表现面 / V54 管线 veto / V55 双基线 / V56 收尾
extends SceneTree

const CASES_PATH := "res://tests/runner/pkg12_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · v1.2.0 元素三期自测（pkg12 V41~V56） ══════════")
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

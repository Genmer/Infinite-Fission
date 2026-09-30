# tests/runner/test_market_supply.gd
# R188-1 黑市供给回归自测入口（godot --headless --path <工程> -s tests/runner/test_market_supply.gd）
# 真源：R188-1「黑市后期还是会卖完」结构修——A 口径对齐扩池（展示=实挂）+ B 保底/谓词
#（buyable_count()/has_stock()/金卡行/终兜底常青货）+ C 刷新置灰窄口径。
# 两段式入口：本文件零全局名引用（autoload/全局类编译期零依赖），用例体运行期 load。
extends SceneTree

const CASES_PATH := "res://tests/runner/market_supply_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R188-1 黑市供给回归 ══════════")
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

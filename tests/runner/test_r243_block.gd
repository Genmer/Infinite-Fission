# tests/runner/test_r243_block.gd
# R243 挡弹成长卡（w3-block）专项套件入口：MEC_BULLET_PARRY 新卡（§3.3）+
# 近战/法器挡弹机制全链集成验收（§9.1 test_r243_block ①~⑧ + 表现口径 ③）。
# 契约：headless、退出码判据（0 过 / 1 挂）；「共 N 项」总数断言与用例数一致
#（R231 假绿教训）。与 w3-trait / w3-element 文件集零交集。
# 纪律：-s 入口编译期先于 autoload 注册——零工程类名直引；用例体运行时 load。
extends SceneTree

const CASES_PATH := "res://tests/runner/r243_block_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R243（挡弹成长卡 w3-block） 专项套件 ══════════")
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	if cases_script == null or not cases_script.can_instantiate():
		print("FAIL | 用例体加载失败（cases=%s）" % str(cases_script))
		print("验收汇总：0/1 通过")
		quit(1)
		return
	var cases = cases_script.new()
	await cases.run(self)
	var fail_count: int = cases.fail_count()
	if fail_count > 0:
		quit(1)
	else:
		quit(0)

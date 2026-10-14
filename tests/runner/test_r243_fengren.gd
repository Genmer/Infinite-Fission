# tests/runner/test_r243_fengren.gd
# R243 法器·旋风刀战斗内弯刀化（w2-fengren）专项套件入口：
# blade_tint/blade_style 参数化 + saber 深弯月/greatsword 宽刃双式 + 弧光强化 +
# 掷骰挡弹（block_chance 两极）+ 元素附着钩子 + 子斩结构（atk_mult/generation）+
# 击退 spawn 快照。
# 契约：headless、退出码判据（0 过 / 1 挂）；「共 N 项」总数断言与用例数一致
#（R231 假绿教训）。
# 纪律：-s 入口编译期先于 autoload 注册——零工程类名直引；用例体运行时 load。
extends SceneTree

const CASES_PATH := "res://tests/runner/r243_fengren_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R243（法器·旋风刀 w2-fengren） 专项套件 ══════════")
	# 等引擎注册的 autoload 完成 add_child + _ready（EventBus→GameConfig→DebugStats）
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

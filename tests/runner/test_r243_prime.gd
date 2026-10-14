# tests/runner/test_r243_prime.gd
# R243 五武器 Lv5 质变形态（w4-prime）专项套件入口：WeaponBase.transcended 机制 +
# 五武器行为差/贴图差（碧涛旋舞/万剑诀/崩山击/苍狼啸月/裂地斩）。
# 契约：headless、退出码判据（0 过 / 1 挂）；「共 N 项」总数断言与用例数一致
#（R231 假绿教训）。覆盖：验收 ①~⑦（§7.1 机制置位/幂等/milestone/atk 单咽喉、
# W9 弧 200°/半径 ×1.15/同心回斩 0.18s×0.5、W11 万剑诀 3 剑 ±10°/单剑 31.5、
# W12 半径 ×1.25/外环 1.6×0.4 幂等分流/双环臂、W8 orbs+2/引爆 6.5/半径 ×1.1/白银狼头、
# W13 弧 270°/ATK 126/击退 180/黑金加宽、图标链 static func 与质变选键门）。
# 纪律：-s 入口编译期先于 autoload 注册——零工程类名直引；用例体运行时 load。
extends SceneTree

const CASES_PATH := "res://tests/runner/r243_prime_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R243（五武器 Lv5 质变 w4-prime） 专项套件 ══════════")
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

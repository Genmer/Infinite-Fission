# tests/runner/test_rcv_sanctuary.gd
# 二cv#6 近战敌贴脸豁免（贴脸保护）回归入口。
# 契约：追击型（CHASE）非 Boss 敌与玩家距离落入「已装备近战武器补刀刃圈」
# （player.melee_sanctuary_r）→ 接触伤害整体豁免；无近战武器恒 0=守卫惰性零扰动。
# 作用域：RANGED/BLINK 行为与 Boss 豁免本规则；E4 引爆等独立通道不受影响。
# 纪律：-s 入口编译期先于 autoload 注册——零工程类名直引；用例体运行时 load。
extends SceneTree

const CASES_PATH := "res://tests/runner/rcv_sanctuary_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · 二cv#6（近战敌贴脸豁免） 回归 ══════════")
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

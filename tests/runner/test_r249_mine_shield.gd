# tests/runner/test_r249_mine_shield.gd
# R249 二db「地雷降频+躲雷橙盾」自测入口（godot --headless --path <工程> -s 本文件）
# 验收锚：A) trapper 词缀 cd 9→13 降频锁；B) 地雷到期未伤人 → mine_dodged → 玩家
# 橙盾 +1 层（10s）；C) 叠层至上限 5（刷新 10s）；D) 寿命归零层清；E) 吸收=整击吞下
# 且先于蓝盾；F) 炸到玩家不发 dodge；G) 未 arm 静默清不授盾；H) 源码锚（信号/橙条/
# 调色板/吸收顺序）；I) HUD 橙条随层显隐 + 「N·Xs」读数。
extends SceneTree

const CASES_PATH := "res://tests/runner/r249_mine_shield_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R249 地雷降频+躲雷橙盾自测 ══════════")
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

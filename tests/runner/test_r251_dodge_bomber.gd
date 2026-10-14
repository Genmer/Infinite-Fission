# tests/runner/test_r251_dodge_bomber.gd
# R251 需求①「躲爆授盾扩展」自测入口（godot --headless --path <工程> -s 本文件）
# 验收锚（设计 §1.6）：
# A1 volatile 躲爆 → mine_dodged 恰 1 + 橙盾 +1；A2 命中 → 0 发全额掉血 20；
# A3 击退打断 → 0 发可再引导；A4 未接触被杀 → 0 发；A5 blink 躲爆 → 恰 1 + +1 层；
# A6 blink 命中 → 0 发掉 18；A7 blink 打断双路 → 0 发且 _blink_threat 清零；
# A8 读条期/引信期被杀 → 0 发；A9 blink 池复用锁存不残留；A10 法术圈外 0 伤 1 发 /
# 圈内掉血 0 发；A11 BossMine 回归（r249 套件复跑承担）；A12 授盾数值
#（帽 5 / 刷新 10s / 橙先于蓝）。
# host=null 驱动：boot main.tscn 真实 GameLoop（MENU 态、不 start_run——零波次干扰），
# 手动 spawn E4/E24/E28 直驱 e.tick 全生命周期。
extends SceneTree

const CASES_PATH := "res://tests/runner/r251_dodge_bomber_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R251 躲爆授盾扩展自测 ══════════")
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

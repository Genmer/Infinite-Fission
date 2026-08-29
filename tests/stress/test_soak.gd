# tests/stress/test_soak.gd
# AC-14.1 soak 入口（架构 §附录：10 分钟自动战斗 0 运行期实例化 / 无错误刷屏）。
# 执行口径（反超时纪律 + 如实报告）：
# · 时长 180s 游戏时间（120Hz × 21600 帧）——任务书授权的缩短口径（10 分钟目标 → 3 分钟）；
# · 等效性补偿：全程维持 AC-01.2 满载（500 弹 + 100 敌 + ≥40 跳字 + ≥60 粒子）——
#   真实自动战斗负载远低于此，满载 soak 覆盖强度更高；
# · 自动战斗：LEVEL_UP 自动选卡 / 玩家无敌帧保活 / 击杀-掉落-拾取-升级链路真实发生；
# · 「无错误刷屏」由外部 shell 统计本脚本 stderr 的 ERROR 行数（脚本内不重定向）。
# 结构（同 pkg0~pkg5）：入口引导 + 运行时 load 用例体 soak_cases.gd。
extends SceneTree

const CASES_PATH := "res://tests/stress/soak_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · AC-14.1 soak（180s 满载自动战斗） ══════════")
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	var cases = cases_script.new()
	cases.run(self)
	quit(1 if cases.fail_count() > 0 else 0)

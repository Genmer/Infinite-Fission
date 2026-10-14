# tests/stress/test_perf_800p100e.gd
# R187 压测扩锚入口（共享组）：800 活跃投射物 + 100 活跃敌人 + ≥40 跳字 + ≥60 粒子，
# headless 手动驱动逻辑帧 60s 游戏时间（120Hz × 7200 帧），判定 P95 < 8.3ms。
# 结构（同 test_perf_500p100e.gd）：-s 脚本模式下入口只做引导；用例体经运行时 load 编译。
extends SceneTree

const CASES_PATH := "res://tests/stress/perf_800p100e_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R187 压测扩锚（800弹+100敌） ══════════")
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	var cases = cases_script.new()
	cases.run(self)
	quit(1 if cases.fail_count() > 0 else 0)

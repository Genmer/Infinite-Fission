# tests/probe_r202_bench.gd
# R202 基准探针入口（godot --headless --path <工程> -s tests/probe_r202_bench.gd）。
# 仿 test_mirror_muzzle.gd 入口模式：-s 脚本编译期 autoload 全局名与工程类名均不可直名
# （依赖链编译早于 autoload 就绪——perf_500p100e_cases.gd:2 同因），故入口零工程类引用，
# 用例体 probe_r202_bench_cases.gd 在 autoload 就绪后运行时加载编译。
# 口径/输出契约见用例体头部注释：BENCH N=<n> AVG=<x.xx>ms 四行，正常退出码 0。
extends SceneTree

const CASES_PATH := "res://tests/probe_r202_bench_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ R202 基准探针 · 静态夹具敌 × W2 加特林命中压力 ══════════")
	await process_frame
	await process_frame
	# 看门狗：用例体脚本错误中止协程时强制退出（防挂死——test_mirror_muzzle.gd:20 先例）
	var watchdog: SceneTreeTimer = create_timer(600.0)
	watchdog.timeout.connect(_on_watchdog)
	var cases_script: GDScript = load(CASES_PATH)
	if cases_script == null:
		print("[probe] 用例体加载失败——强制退出（2）")
		quit(2)
		return
	var cases = cases_script.new()
	cases.run(self)
	var fail_count: int = cases.fail_count()
	if fail_count > 0:
		quit(1)
	else:
		quit(0)


func _on_watchdog() -> void:
	print("[watchdog] 探针超时/协程中止——强制退出（3）")
	quit(3)

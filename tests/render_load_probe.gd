# tests/render_load_probe.gd
# 渲染侧负载侦查探针入口（探索B）：-s 模式下入口编译早于 autoload 全局名注册，
# 用例体 render_load_probe_cases.gd 经运行时 load 编译（同 tests/stress/ 套件先例）。
# 运行：Godot_console --headless --path repo -s tests/render_load_probe.gd
extends SceneTree

const CASES_PATH := "res://tests/render_load_probe_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · 渲染侧负载侦查探针 ══════════")
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	var cases = cases_script.new()
	cases.run(self)
	quit(0)

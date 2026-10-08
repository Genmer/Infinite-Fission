# tests/probe_reroll_zorder.gd
# R202 验证探针入口（勿用 test_ 前缀——不入电池 glob）。-s 脚本编译早于 autoload
# 注册，入口只做引导；用例体 probe_reroll_zorder_body.gd 经运行时 load 编译。
extends SceneTree


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	await process_frame
	var body: GDScript = load("res://tests/probe_reroll_zorder_body.gd")
	var probe = body.new()
	await probe.run(self)
	quit(0)

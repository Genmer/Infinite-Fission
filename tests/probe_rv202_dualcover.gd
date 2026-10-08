# tests/probe_rv202_dualcover.gd
# 复审探针入口（勿用 test_ 前缀——不入电池 glob）。-s 脚本编译早于 autoload 注册，
# 入口只做引导；用例体 probe_rv202_dualcover_body.gd 经运行时 load 编译
# （同 probe_reroll_cover.gd 惯例）。
extends SceneTree


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	await process_frame
	var body: GDScript = load("res://tests/probe_rv202_dualcover_body.gd")
	if body == null or not body.can_instantiate():
		print("PROBE BODY LOAD FAIL")
		quit(1)
		return
	var probe = body.new()
	await probe.run(self)
	quit(0)

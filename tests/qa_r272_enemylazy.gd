# tests/qa_r272_enemylazy.gd
# R272 V-C2 敌/xp 池惰性归位接线验收入口（qa_r272_enemylazy_cases.gd 用例体）。
# 纪律：-s 入口编译期先于 autoload 注册——零工程类名直引；用例体运行时 load
#（照 tests/qa_r271_deeprepro.gd 结构；套件落 tests/ 根）。
extends SceneTree


const CASES_PATH := "res://tests/qa_r272_enemylazy_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R272 V-C2 敌/xp 池惰性归位（boost 开留桶/复用零树进出/关态逐位回退） ══════════")
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

# tests/qa_r272_qa_indep.gd
# R272 V-C2 QA 独立挖掘套件入口（qa_r272_qa_indep_cases.gd 用例体）——独立于开发的
# qa_r272_enemylazy，从 V-C2 语义另提测试点：产品路径死亡归还链/尸体看门狗口/
# MM 镜像幂等/真实战斗 soak/trim_free_to 留桶交互。
# 纪律：-s 入口编译期先于 autoload 注册——零工程类名直引；用例体运行时 load。
extends SceneTree


const CASES_PATH := "res://tests/qa_r272_qa_indep_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("════════ Infinite Fission · R272 V-C2 QA 独立挖掘（产品路径归还链/看门狗/MM 幂等/soak/trim 交互） ════════")
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

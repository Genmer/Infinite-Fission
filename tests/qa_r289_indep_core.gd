# tests/qa_r289_indep_core.gd
# R289 独立 QA 探针（核心面：深载滞回 / B 双帽 / C 应急档）——入口。
# 独立于开发套件 qa_r289_weaponlod*：断言从设计契约重新表述，不照抄开发用例。
extends SceneTree


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ R289 独立 QA · 深载核心面（滞回/双帽/应急档） ══════════")
	await process_frame
	await process_frame
	var cs: GDScript = load("res://tests/qa_r289_indep_core_cases.gd")
	if cs == null or not cs.can_instantiate():
		print("FAIL | 用例体加载失败")
		print("验收汇总：0/1 通过")
		quit(1)
		return
	var cases = cs.new()
	await cases.run(self)
	var fails: int = cases.fail_count()
	quit(1 if fails > 0 else 0)

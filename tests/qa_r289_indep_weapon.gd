# tests/qa_r289_indep_weapon.gd
# R289 独立 QA 探针（A 真武器节流守恒 / 逐武器键记账 / 关态正对照）——入口。
extends SceneTree


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ R289 独立 QA · A 真武器节流守恒 + 键记账 ══════════")
	await process_frame
	await process_frame
	var cs: GDScript = load("res://tests/qa_r289_indep_weapon_cases.gd")
	if cs == null or not cs.can_instantiate():
		print("FAIL | 用例体加载失败")
		print("验收汇总：0/1 通过")
		quit(1)
		return
	var cases = cs.new()
	await cases.run(self)
	var fails: int = cases.fail_count()
	quit(1 if fails > 0 else 0)

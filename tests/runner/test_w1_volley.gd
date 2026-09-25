# tests/runner/test_w1_volley.gd
# R187 §2.4 手枪「并行弹幕 × 跳弹增值」自测入口（SceneTree 脚本：
# godot --headless --path <工程> -s tests/runner/test_w1_volley.gd）
# 覆盖验收①面板锚点 ②并排几何确定性 ③跳弹/黄金弹 ④弹幕态 ⑤上限阀 ⑥回响绕门负例 ⑦validator。
extends SceneTree

const CASES_PATH := "res://tests/runner/w1_volley_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · W1 并行弹幕/跳弹增值自测 ══════════")
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	var cases = cases_script.new()
	cases.run(self)
	var fail_count: int = cases.fail_count()
	if fail_count > 0:
		quit(1)
	else:
		quit(0)

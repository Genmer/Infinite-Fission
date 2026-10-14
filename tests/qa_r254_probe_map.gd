# tests/qa_r254_probe_map.gd — QA 探针入口（只读产品代码）
# 目的：复现 R254-2「困难-第三关-出发，回到主页」——四象限钉死用户撞的路径：
#   Q1 困难档未通 frost（分档未解锁）：UI 锁定行有无出发钮 + 直调 _on_menu_start 终态
#   Q2 困难档已通 frost + 祝福池空：应直达 PLAYING
#   Q3 同 Q2 + 图鉴解锁紫词条：面板弹 → confirm → PLAYING
#   Q4 同 Q3 → dismiss（不选祝福）→ PLAYING
# 纪律：-s 入口编译期 autoload 未注册——入口零工程类直引，逻辑全在 cases 体运行时加载。
extends SceneTree

const CASES_PATH := "res://tests/qa_r254_probe_map_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	await process_frame
	var body: GDScript = load(CASES_PATH)
	if body == null or not body.can_instantiate():
		print("PROBE FAIL | 用例体加载失败：%s" % CASES_PATH)
		quit(1)
		return
	var cases: Object = body.new()
	await cases.run(self)
	quit(0)

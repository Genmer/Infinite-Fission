# tests/qa_r259_panel_cache.gd — R259 三面板行缓存行为验收（成就/选人/选关）
# 验收面：①缓存复用（同实例直挂）②成就 desc 进度轻刷+done 翻转重建 ③选人签名
# 变化重建（换角色选中标记移动）④选关分档缓存+map_records_changed 失效重建。
# 纪律：-s 入口零工程类直引，逻辑全在 cases 体运行时加载。
extends SceneTree

const CASES_PATH := "res://tests/qa_r259_panel_cache_cases.gd"


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
	var fails: int = int(cases.call("fail_count"))   # R259-D2：红时退出码置 1（电池/CI 依赖退出码）
	quit(1 if fails > 0 else 0)

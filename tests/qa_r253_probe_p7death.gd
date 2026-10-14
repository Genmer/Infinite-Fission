# tests/qa_r253_probe_p7death.gd — QA 探针入口（只读产品代码）
# 目的：复现 r188_idle §P/P7 消化循环中玩家在 hp=1e6/invuln=9999 下死亡（GAME_OVER）
# 的根因——逐 300 帧快照 state/hp/max_hp/invuln/敌数，死亡帧即停打印末态。
# 纪律：-s 入口编译期 autoload 未注册——入口零工程类直引，逻辑全在 cases 体运行时加载。
extends SceneTree

const CASES_PATH := "res://tests/qa_r253_probe_p7death_cases.gd"


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

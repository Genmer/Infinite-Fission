# tests/runner/test_pool_wiring.gd
# 全量加成生效审计自测入口（godot --headless --path <工程> -s tests/runner/test_pool_wiring.gd）
# 真源：用户点名「全部检查一遍所有加成是否真的生效，别加了个寂寞」——
# 每个 ADD 池：真卡上架 → 真挂卡 → 消费点可观测值断言（攻/攻速/射速/冷却/暴击/爆伤/
# 穿透/弹数/弹速/体积/磁吸/生命/技能CD/经验/金币/击退）。
extends SceneTree

const CASES_PATH := "res://tests/runner/pool_wiring_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · 加成生效全量审计 ══════════")
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

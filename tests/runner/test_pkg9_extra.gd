# tests/runner/test_pkg9_extra.gd
# v0.9.0 验收补充入口（独立复核 + 补漏；两段式同 pkg0~pkg9：
#   godot --headless --path <工程> -s tests/runner/test_pkg9_extra.gd）
# 覆盖（tester 独立验收补漏，A8 冻结方案外的加固用例）：
#   X1 排空序全链实测（LEVEL_UP→赐福→商店，pkg9 G7 未含升级先位）
#   X2 BlessingHandler reset 全归零（遥测+种子）
#   X3 赐福 atk 端到端：真件芯片×2 套装 + 赐福 → ⑥b 管线 fixed-seed 手算对照
#     （(0.24+0.26)×1.10+0.04=0.59 → joint=min(M×1.59,8)）+ ⑥b 段 cap 钳
#   X4 gold 臂经 _add_gold 吃 K_gold 路由强化
#   X5 slot2 门 capacity<=4 边界（capacity==4 恰含 slot2）
#   X6 EVENT_NAMES ↔ EventBus 脚本信号 双源运行时对账（23 恰等）
#   X7 set_chip_slots 3/5/6 档渲染（locked 未解锁灰显计数）
extends SceneTree

const CASES_PATH := "res://tests/runner/pkg9_extra_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · v0.9.0 验收补充（tester 独立复核+补漏） ══════════")
	# 等引擎注册的 autoload 完成 add_child + _ready（EventBus→GameConfig→DebugStats）
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

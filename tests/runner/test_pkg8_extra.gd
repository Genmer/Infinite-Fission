# tests/runner/test_pkg8_extra.gd
# v0.8.0 验收补漏入口（tester 独立验收；SceneTree 脚本：godot --headless --path <工程> -s tests/runner/test_pkg8_extra.gd）
# 覆盖（pkg8 未覆盖的验收点增量；两段式同 pkg0~pkg8：入口只做引导，用例体运行时 load）：
#   V13/V14 chips=12/characters=3 文件系统对账 + 4 变体 stat_key 镜像 + 副词条条数 ±3pt 独立门值 /
#   V15 max_hp 套装第 2 枚 equip 的 player.max_hp 增量 + hp 同步 /
#   V6 诅咒 3 层受击手算（×1.24）+ compute_max_hp 四参数手算对照 /
#   V1~V4 w9/19/29 商店间隙零事件 + 40% 种子注入 0/1 边界 + 事件期战斗冻结帧序 +
#        祭坛 HP 钳 ≥1 不致死 + 紫卡 rarity floor /
#   V18/V19 goto_menu 仅 GAME_OVER（四态拒绝）+ 选角→开局全链零 rejected_transitions /
#   V21/22 冲刺无敌 0.15s 边界（0.1417s 免伤 / 0.1583s 可受伤）+ 活动区钳制 + 顿帧冻结 /
#   V24 version=0.8.0 + PROGRESS §7 基线 1257 + A7 假设清单含 R8（文档面独立核对）。
extends SceneTree

const CASES_PATH := "res://tests/runner/pkg8_extra_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · v0.8.0 验收补漏（tester 独立） ══════════")
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

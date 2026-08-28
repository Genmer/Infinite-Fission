# tests/runner/test_pkg2.gd
# 包 2 实体基座自测入口（SceneTree 脚本：godot --headless --path <工程> -s tests/runner/test_pkg2.gd）
# 覆盖：六大事件派发序=挂载序、回收五路径收束（OnExpire→清零→归还）、帧聚合去重（E-03）、
# 穿透计数/反弹反射角镜像、Homing 角速度 clamp/二段延时/重索敌/AOE、波次 TP 公式与表驱动
# 一致 + 单帧 ≤8 + 同屏 ≤120、玩家相对拖动/边界钳制/无敌帧、池零实例化复用、透传桩公式。
# 结构同 pkg0：-s 模式下入口脚本编译早于 autoload 全局名注册，入口只做引导；用例体在
# pkg2_cases.gd 经运行时 load 编译——此时 autoload 已就绪（已实测验证）。
extends SceneTree

const CASES_PATH := "res://tests/runner/pkg2_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · 包 2 实体基座自测 ══════════")
	# 等引擎注册的 autoload 完成 add_child + _ready（EventBus→GameConfig→DebugStats）
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	var cases = cases_script.new()
	await cases.run(self)
	var fail_count: int = cases.fail_count()
	if fail_count > 0:
		quit(1)
	else:
		quit(0)

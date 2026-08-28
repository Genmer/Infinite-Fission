# tests/runner/test_pkg3.gd
# 包 3 武器/词缀/元素自测入口（SceneTree 脚本：godot --headless --path <工程> -s tests/runner/test_pkg3.gd）
# 覆盖（PROGRESS §4 包 3 要点 1~10）：四形态武器开火参数重写、TraitStack 挂载/复制/分裂继承
# （copy_for_split）、六事件派发序=挂载序（真件栈）、链式深度 3 熔断、体积极限质变 ≥3.0× 冲击波、
# 分裂三重闸门（代数≤3/单次≤8/全场软上限）、反弹增伤乘区、点燃/冰冻/感电附着-衰减-反应
# （碎裂×2.0/过载 120%ATK/超导全抗−30%/反应 CD 2s）、激光叠层与折射分叉深度 2、
# 环绕周期判定/弧斩消弹格挡。
# 结构同 pkg0/pkg1/pkg2：-s 模式下入口脚本编译早于 autoload 全局名注册，入口只做引导；
# 用例体 pkg3_cases.gd 经运行时 load 编译——此时 autoload 已就绪（已实测验证）。
extends SceneTree

const CASES_PATH := "res://tests/runner/pkg3_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · 包 3 武器/词缀/元素自测 ══════════")
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

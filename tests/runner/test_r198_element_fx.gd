# tests/runner/test_r198_element_fx.gd
# R198 组1「元环表现」自测入口（SceneTree 脚本：godot --headless --path <工程>
#   -s tests/runner/test_r198_element_fx.gd）
# 覆盖：R192-low1 结算臂硬默认缺键告警 / R192-low2 冻结臂 IMMUNE_CHILL 检位 /
#   R192-low6 绽放 delay 0.75 双源锁 / R192-low7 卡名消歧 / R192-low9 四卡箭头式 /
#   R192-low10 popup 分桶映射 / R192-low3 燃烧层数口径 / r195-5 confetti 世界域 /
#   r195-6 迸裂池 20 槽（用例体 r198_element_fx_cases.gd）。
# 结构说明（同 pkg/r195/r196/r197）：-s 脚本模式下入口脚本编译早于 autoload 全局名注册，
# 入口只做引导；用例体经运行时 load 编译——此时 autoload 已就绪。
extends SceneTree

const CASES_PATH := "res://tests/runner/r198_element_fx_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R198 组1 元环表现验证 ══════════")
	# 等引擎注册的 autoload 完成 add_child + _ready（EventBus→GameConfig→DebugStats→Meta）
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	if cases_script == null or not cases_script.can_instantiate():
		# 用例体编译失败（load 已打印解析错误）——立即失败退出（防 -s 套件悬挂电池；
		# 解析错 load 返回非 null 但不可实例化的 GDScript，须 can_instantiate 复查）
		print("FAIL | 用例体加载失败（cases=%s）" % str(cases_script))
		print("验收汇总：0/1 通过")
		quit(1)
		return
	var cases = cases_script.new()
	await cases.run(self)
	var fail_count: int = cases.fail_count()
	if fail_count > 0:
		quit(1)
	else:
		quit(0)

# tests/runner/test_r195_adapt.gd
# R195 整案验收套件入口（SceneTree 脚本：godot --headless --path <工程> -s tests/runner/test_r195_adapt.gd）
# 仿 test_history.gd 的 SceneTree 模式（_initialize → _run + 用例体运行时 load + 聚合计数 +
# exit 码）。覆盖定案 docs/design/R195_SCREEN_ADAPT.md 全部非 noop 项（tracker 套件名
# r195_adapt）：域A 商店刷新钮（can_refresh 三口径合一/原位隐藏/价签同步/几何原值/价曲线
# 不回归）＋域B 激光穿透（预算口径 hit=1+贯穿数/无逐目标衰减/副束门）＋域C 多尺寸矩阵
# （7 尺寸 × 7 态 × 七律 + 超限钳制 + safe-area 契约）＋域D 设置键契约（无新增键/钳制常量/
# 存档兼容）。全过 exit 0，否则 exit 1；结尾打印「验收汇总：X/Y 通过」。
# 结构同 test_r195_layout.gd：-s 模式下入口脚本编译早于 autoload 全局名注册 → 入口只做
# 引导；用例体 r195_adapt_cases.gd 经运行时 load 编译（此时 autoload 已就绪）。
extends SceneTree

const CASES_PATH := "res://tests/runner/r195_adapt_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R195 整案验收（r195_adapt）══════════")
	# 等引擎注册的 autoload 完成 add_child + _ready（EventBus→GameConfig→DebugStats→Meta）
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	if cases_script == null:
		# 用例体编译失败（load 已打印解析错误）——立即失败退出（防 -s 套件悬挂电池）
		print("FAIL | 用例体加载失败（cases=%s）" % str(cases_script))
		print("验收汇总：0/1 通过")
		quit(1)
		return
	var cases = cases_script.new()
	await cases.run(self)
	var pass_count: int = cases.pass_count()
	var fail_count: int = cases.fail_count()
	print("验收汇总：%d/%d 通过" % [pass_count, pass_count + fail_count])
	if fail_count > 0:
		quit(1)
	else:
		quit(0)

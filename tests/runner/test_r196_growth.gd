# tests/runner/test_r196_growth.gd
# R196 成长与体验五连修 + 三定案自测入口（SceneTree 脚本：godot --headless --path <工程>
#   -s tests/runner/test_r196_growth.gd）
# 覆盖：R196_GROWTH_FIXES 五组（范围词条/超质变叠层/面板三选+断触/经验四色档/图鉴锁）
#   + wunlock 武器准入门 + pistol_trait_family 修复后契约 + apk_menu_no_icons 图标审计。
# 结构说明（同 pkg0~pkg5/r195）：-s 脚本模式下入口脚本编译早于 autoload 全局名注册，
# 入口只做引导；用例体经运行时 load 编译——此时 autoload 已就绪。
extends SceneTree

const CASES_PATH := "res://tests/runner/r196_growth_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R196 成长与缺陷批次验收 ══════════")
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

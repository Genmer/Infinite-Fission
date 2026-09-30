# tests/runner/test_r195_layout.gd
# R195 多尺寸屏适配矩阵入口（SceneTree 脚本：godot --headless --path <工程> -s tests/runner/test_r195_layout.gd）
# 覆盖：7 尺寸（720×1280/1440/1560/1600/1680、960×1280、540×960）× 7 UI 态七律矩阵
# （R1 界内 / R2 无重叠白名单钉死 / R3 全宽标签居中 / R4 底簇贴底 / R5 spawn 不入设计域 /
# R6 dim==visible_rect / R7 触控目标）+ 超限钳制（720×1800 回落 / 720×1680 满屏 /
# KEEP↔EXPAND 双向可逆 / keep 回退位零触发）+ safe-area 契约（守卫/映射/grep）。
# 结构同 test_r194_mobile.gd：-s 模式下入口脚本编译早于 autoload 全局名注册 → 入口只做
# 引导；用例体 r195_layout_cases.gd 经运行时 load 编译（此时 autoload 已就绪）。
# 矩阵与 project.godot aspect=expand 同 commit 落地（默认窗 540×960 下 EXPAND≡KEEP，
# 只跑默认窗=全绿假象——矩阵必须跨尺寸）。
extends SceneTree

const CASES_PATH := "res://tests/runner/r195_layout_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R195 多尺寸适配矩阵 ══════════")
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
	var fail_count: int = cases.fail_count()
	if fail_count > 0:
		quit(1)
	else:
		quit(0)

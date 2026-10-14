# tests/runner/test_r245_diff_star.gd
# R245「选关星标分档」验收自测入口（SceneTree 脚本：godot --headless --path <工程>
#   -s tests/runner/test_r245_diff_star.gd）
# 覆盖（真源：FEEDBACK_TRACKER 二cq——用户「只通关普通，困难/地狱却全显示通关」）：
#   G1 Meta.is_map_cleared_at 分档口径（普/困/狱各查 map_records 分档键）
#   G2 选关面板星标随所选难度联动（切档重建地图行）
#   G3 分档对称（仅困/狱有记录时普通不亮星）
#   G4 R88 难度解锁门回归（普通通关才开放困难/地狱）
#   G5 零记录边缘（三档全「可挑战」，无误亮）
# 结构说明（同 test_r198 套件）：-s 脚本模式下入口脚本编译早于 autoload 全局名注册，
# 入口只做引导；用例体经运行时 load 编译——此时 autoload 已就绪。
# 夹具：MenuScreen 裸实例 + DataRegistry 裸载（零 GameLoop——菜单域自足）。
extends SceneTree

const CASES_PATH := "res://tests/runner/r245_diff_star_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R245 选关星标分档验收 ══════════")
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

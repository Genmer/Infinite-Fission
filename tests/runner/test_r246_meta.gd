# tests/runner/test_r246_meta.gd
# R246/R247「meta 泳道回归」验收自测入口（SceneTree 脚本：godot --headless --path <工程>
#   -s tests/runner/test_r246_meta.gd）
# 覆盖（meta 泳道申报套件缺失，R247 集成终修补建；样板 test_r245_diff_star 双文件式）：
#   M1 角色表完整性（13 角色 / id 唯一 / 必备键 / cd==120 全表 / 门型互斥 / has_skill 契约）
#   M2 新角色条目（medic/vortex/reaper 数值与解锁门——R247 落表）
#   M3 升华键 × 掷卡可用性一致性（R247 终修：_sublime_available 判据收紧回归锁）
#   M4 无尽深度成就门（endless_depth 四档族 / best_endless_depth 聚合 / 计数口一致）
#   M5 解锁判定链（13 角色门型矩阵：通关/分档/深度/击杀/成就/购买 + 门-成就同步）
# 结构说明（同 test_r245 套件）：-s 脚本模式下入口脚本编译早于 autoload 全局名注册，
# 入口只做引导；用例体经运行时 load 编译——此时 autoload 已就绪。
# 夹具：纯 Meta 域零场景零 add_child（r247_endless_channel 同式）+ 首尾快照还原。
extends SceneTree

const CASES_PATH := "res://tests/runner/r246_meta_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R246/R247 meta 泳道回归验收 ══════════")
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

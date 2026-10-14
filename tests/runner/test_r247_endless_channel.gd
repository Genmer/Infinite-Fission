# tests/runner/test_r247_endless_channel.gd
# R247「渠道矩阵扩充」验收自测入口（SceneTree 脚本：godot --headless --path <工程>
#   -s tests/runner/test_r247_endless_channel.gd）
# 覆盖（真源：docs/design/sublime/_channels.md §7 + FEEDBACK_TRACKER 二cr #5）：
#   G1 表结构：13 角色（+medic/vortex/reaper）+ 10 角色 sublime 两键 + endless_depth 成就族
#   G2 聚合读口：best_endless_depth 跨键（无后缀/#1/#2）取最大；空表/缺键/脏值 → 0
#   G3 角色门：unlock_endless_depth 19/20/49/50 阈值边界 + #1/#2 分档驱动 + reaper 不随深度
#   G4 结算全链：wave_started+GAME_OVER → 深度落账/阶梯成就/50 档 +100 结晶；每日局分流
#   G5 购买门：reaper 240 三拒（不足/已购/无价格）+ 扣费解锁
#   G6 旧档兼容：无新键旧档读 0 门锁 + 存档段结构零新增键
# 结构说明（同 test_r245 套件）：-s 脚本模式下入口脚本编译早于 autoload 全局名注册，
# 入口只做引导；用例体经运行时 load 编译——此时 autoload 已就绪。
# 夹具：纯 Meta 域（零场景零 GameLoop零 add_child——本套件不触 UI/池化节点）。
extends SceneTree

const CASES_PATH := "res://tests/runner/r247_endless_channel_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R247 无尽渠道矩阵验收 ══════════")
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

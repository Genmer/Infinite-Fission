# tests/runner/test_r246_sublime.gd
# R246「红色传说·技能升华卡 + 品质第 5 档」验收自测入口（SceneTree 脚本：
#   godot --headless --path <工程> -s tests/runner/test_r246_sublime.gd）
# 覆盖（真源：docs/design/sublime/_card_system.md §7 测试契约 T1~T10 + cards 泳道
# game_loop 接线 S 组；用户原话「buff里多一个红色（传说级）buff就是升华角色技能，
# 爆率只有0.001%」——FEEDBACK_TRACKER R246 #2）：
#   T1 品质表第 5 档（palette 单源：色/名/钳制安全）
#   T2 掷率字面 0.001% + 定种两态（掷中出卡 / 掷不中不出）
#   T3 豁免面（保底/重随/诅咒/槽位替换永不侵蚀红卡——T3 硬契约）
#   T4 替换规则（末位非保底替换 / 全保底批不上架不补偿）
#   T5 apply_choice 拾取生效（enable_sublime 鸭子守卫 + 播报 + 遥测 + 幂等）
#   T6 fission 两态（表无键掷中不上架 / 表有键上架读表文案）
#   T7 卡面数据面（卡 dict 字段 + 概率文案 + 预热键=实拼键）
#   T8 挂机必选（AutoIdleStrategy 998 特判）
#   T9 预热零 rng（enumerate_prewarm_variants 升华变体 + 三流 state 不变）
#   T10 RNG 纪律（独立掷流不扰动主 rng/_slot_rng 确定性序列）
#   S 组 game_loop 接线（sublime 随档序列化/回填 + 每日定种/常规·继续 randomize）
# 结构说明（r245 同式）：-s 脚本模式下入口脚本编译早于 autoload 全局名注册，入口只做
# 引导；用例体经运行时 load 编译——此时 autoload 已就绪。
extends SceneTree

const CASES_PATH := "res://tests/runner/r246_sublime_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R246 红色传说升华卡（cards 泳道）验收 ══════════")
	# 等引擎注册的 autoload 完成 add_child + _ready（EventBus→GameConfig→DebugStats→Meta）
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	if cases_script == null or not cases_script.can_instantiate():
		# 用例体编译失败（load 已打印解析错误）——立即失败退出（防 -s 套件悬挂）
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

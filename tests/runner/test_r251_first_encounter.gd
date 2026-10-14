# tests/runner/test_r251_first_encounter.gd
# R251 需求③ 首遇卡片系统 + 需求② 咒术师降频 验收自测入口（SceneTree 脚本：
#   godot --headless --path <工程> -s tests/runner/test_r251_first_encounter.gd）
# 覆盖（真源：docs/design/2026-10-10-R251-design.md §3.5 C1~C10 / §2.5 B1~B3）：
#   C1 敌卡：出队首遇弹卡（首次遭遇+咒术师+法术圈+enemy 域）恰 1 次，二次不弹
#   C2 敌卡持久化：codex_first_met 落账（套件首尾快照-清场-还原）
#   C3 Boss 卡 + E1 卡：补文案后 Boss/旧怪首遇同样弹卡（旧怪零打扰契约废止）
#   C4 武器上架卡：候选定稿路径弹「【新武器】回旋刃」（同窗二次定稿静默）
#   C5 武器获取回退卡：add_weapon 与上架同键互斥（烧键静默 / erase 后单弹）
#   C6 反应卡：真反应首触发弹卡（name+recipe 要点），reaction_seen 幂等零变化
#   C7 队列：至多 1 张可见、4.5s 自动消散、点击即关、上限 4 丢最旧
#   C8 卫生：新 UI 源码零 >0xFFFF 码点（r196 ⑧ 同款闸门）
#   C9 频率段 B1~B3：E28 fire_cd==4.8 / 单只施法间隔 4.8s / 织入份额三档分波
#   （B4/B5 与 C10 = verify_feedback E5/G8 迁移断言 + R72/法术圈原锁，归
#     test_verify_feedback 复跑覆盖——设计 §5.2 复跑清单）
# 结构（r246 同式）：-s 脚本模式下入口脚本编译早于 autoload 全局名注册，入口只做
# 引导；用例体经运行时 load 编译——此时 autoload 已就绪。
extends SceneTree

const CASES_PATH := "res://tests/runner/r251_first_encounter_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R251 首遇卡片系统 + 咒术师降频 验收 ══════════")
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

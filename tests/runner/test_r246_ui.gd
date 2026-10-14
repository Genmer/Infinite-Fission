# tests/runner/test_r246_ui.gd
# R246「升华卡 UI 呈现」验收自测入口（SceneTree 脚本：godot --headless --path <工程>
#   -s tests/runner/test_r246_ui.gd）
# 覆盖（真源：docs/design/sublime/_card_system.md §5.1 ui 泳道清单 + _channels.md §3/§4）：
#   G1 品质表扩档（palette：红档 [4]=传说 / 金档 [3] 改辉煌 / clamp 安全）
#   G2 升华卡卡面（KIND_NAMES 第 7 位 / 类别行「升华 · 传说」/ 红顶带 / 5 圆珠）
#   G3 挂机描金跳描（D11：rarity==4 槽位不描金、仅记录槽位；金卡描金不回归）
#   G4 类型圆章 + 技能图标（type_icon kind6 红环菱 ≠ 灰菱前科；medic/vortex/reaper）
#   G5 HUD 升华红环（skill_sublime 态读口 has_method 守卫 / 无技能置灰不动）
#   G6 选人卡（ACH_TYPE_CATEGORY 显式 endless_depth / _locked_hint 新门文案与链序 /
#      P2「·新」角标订阅 achievements_changed）
# 结构说明（同 test_r245 套件）：-s 脚本模式下入口脚本编译早于 autoload 全局名注册，
# 入口只做引导；用例体经运行时 load 编译——此时 autoload 已就绪。
# 夹具：MenuScreen / CardSelectUI / HUD 裸实例（零 GameLoop——UI 域自足）。
extends SceneTree

const CASES_PATH := "res://tests/runner/r246_ui_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R246 升华卡 UI 呈现验收 ══════════")
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

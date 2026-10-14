# tests/runner/test_rcu_faqi.gd
# 二cu「灵剑/法器表现重构」验收自测入口（SceneTree 脚本：godot --headless --path <工程>
#   -s tests/runner/test_rcu_faqi.gd）
# 覆盖（真源：FEEDBACK_TRACKER 二cu #1~#6——用户「一道道剑光刺过去…斜着的剑痕」「图标+
#   环绕的武器都重新弄好点」「旋风刀这套实现很可以，另外俩都按这个标准做」「阔剑应该是
#   dnf 巨剑那种形象，目前的阔剑给灵剑（再细点，发点光即可）」）：
#   G1 W11 剑光弹体（flight_tex 64px 双版 + 放大/拖尾常量锚）
#   G2 命中剑痕事件（EventBus.sword_mark 发点：命中敌位 + 来速角；无命中零发点）
#   G3 FX 剑痕池（ElementalFxLayer 池化落位：斜置 45° + 可见 + 寿命后隐藏 + 质量分档口）
#   G4 法器合一·化身出击（player 委托口 + 出击态机：出段→回段→归位；W11/W12 开火自动触发）
#   G5 出膛口=化身（W11/W12 muzzle 在化身环带——R25「发射口和武器对上」纪律延伸）
#   G6 W13 DNF 巨剑直刃（等宽刃身 + saber 原值不变 + 图标双版）
#   G7 灵剑继承旧阔剑轮廓（源锚：外辉光 ×1.9 / 剑光 streak / DNF 直刃注释）
# 结构说明（同 test_r245 套件）：-s 脚本模式下入口脚本编译早于 autoload 全局名注册，
# 入口只做引导；用例体经运行时 load 编译——此时 autoload 已就绪。
extends SceneTree

const CASES_PATH := "res://tests/runner/rcu_faqi_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · 二cu 灵剑/法器表现重构验收 ══════════")
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

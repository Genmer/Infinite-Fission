# tests/runner/test_r198_menu_meta.gd
# R198 组4「菜单成长」验收自测入口（SceneTree 脚本：godot --headless --path <工程>
#   -s tests/runner/test_r198_menu_meta.gd）
# 覆盖（真源：R198_BACKLOG_SWEEP.md §4 组4 WorkItems）：
#   A 二aw-4 养成 revive desc「3s 无敌」（真值 REVIVE_INVULN_S=3.0 对齐）
#   B 二aw-5 skill_icon 10 角色两两互异（像素采样哈希）+ fission/echo 非默认星
#   C 二aw-6 echo_unlocked 边沿恰发一次 + 大厅「·新」角标 + fission 旧边沿不回退
#   D 二aw-7 fission 锁定句压缩（≤406px）+ name_l autowrap 兜底
#   E r195-4 LobbyScroll 横向居中锚（720 域恒等 28..620 + 宽画布居中生效）
#   F R192-low8 RxnMult autowrap + 高 34（绽放三段串折行）
#   G P2-skillcopy noah skill_desc 12% 伴随火力（表 + 选人行 + 技能行换行区）
# 结构说明（同 test_r197 等套件）：-s 脚本模式下入口脚本编译早于 autoload 全局名注册，
# 入口只做引导；用例体经运行时 load 编译——此时 autoload 已就绪。
# 夹具：MenuScreen 裸实例 + DataRegistry 裸载（零 GameLoop——菜单/结算/大厅几何域自足）。
extends SceneTree

const CASES_PATH := "res://tests/runner/r198_menu_meta_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R198 菜单成长组验收 ══════════")
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

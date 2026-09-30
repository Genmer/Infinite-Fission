# tests/runner/test_r188_idle.gd
# R188 整案验收入口（godot --headless --path <工程> -s tests/runner/test_r188_idle.gd）
# 真源：docs/design/R188_IDLE_PERF.md 定案——四项仲裁全部 implement（无 noop 项），
# 本套件把全部非 noop 项验收标准收敛为一个 headless 门：
# · R188-1 黑市供给（§1.7 五断言 + 口径抽查）
# · R188-2 高位叠层回归（§2.5「叠层引擎本体正常」口径锁死——十组断言，无论 verdict 落库）
# · R188-3 挂机全链路（§3.9 A 设置/B 开关/C 选卡/D 商店/E 结算/F soak）
# · R188-4 性能纵深（§4.8 套件内可达口径：门控/HUD 脏标记/敌段 LOD/w233 建波/高水位/
#   连升合并/池预热扩容；双压测与 soak 长锚归 tests/stress 专项入口，不在本套件复压）
# 两段式入口（仿 test_history.gd / test_buff_audit.gd 先例）：-s 模式入口编译早于 autoload
# 注册——本入口零 autoload 编译期引用（仅 extends SceneTree + 运行期 load()），
# process_frame 两帧（autoload 就绪）后再加载用例体执行。
# 结尾打印「验收汇总：X/Y 通过」；全过 exit 0，否则 exit 1。
extends SceneTree

const CASES_PATH := "res://tests/runner/r188_idle_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R188 整案验收（market·buffs·idle·perf） ══════════")
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	var cases = cases_script.new()
	cases.run(self)
	var failed: int = cases.fail_count()
	var total: int = cases.total_count()
	print("══════════════════════════════════════════════════")
	print("验收汇总：%d/%d 通过" % [total - failed, total])
	quit(0 if failed == 0 else 1)

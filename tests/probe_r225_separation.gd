# tests/probe_r225_separation.gd（R225 弹段双组成分离测量探针入口）
# 跑法：cd E:/Code/Agent/Infinite-Fission && tools/Godot_v4.3-stable_win64_console.exe \
#         --headless --path E:/Code/Agent/Infinite-Fission/repo -s tests/probe_r225_separation.gd
# 目的（R224 报告 §四读数二遗留收口——「每结算 ~300-500µs 是上界口径且对刀不敏感
#   =混组成」）：把深载弹段（grid_projectile 段）成本拆成「结算(settle/resolve)」与
#   「弹tick(移动/宽相/窄相)」两个组成部分，三臂分离测量 × 同日两轮取中位数：
#   RES 臂 = r224 S1 同配置（override=-3 帽96@60Hz）——结算臂弹段与 结/步；
#   TICK 臂 = 同 RES 但 override=-4（全弃档，separate_drop 计数）——纯 tick 弹段；
#   MICRO 臂 = 绕开投射物直驱管线合成结算（对真敌构建 ctx，批 48/96/192）——每结算 µs 权威。
# 推导口径：结算归属弹段占比=(RES弹段−TICK弹段)/RES弹段×100；每弹tickµs=TICK弹段÷
#   活弹p50；对账比=TICK separate_drop/s ÷（RES 结/步×60）。
# 纪律：-s 入口编译期先于 autoload 注册——入口零工程类名直引（全鸭子），用例体运行时
# 加载（probe_r224_deepload 同构）；无 test_ 前缀不入电池；基线 JSON 写 docs/qa/
# （跨代轮转 _prev1 只留一代；同日 runs[] 累积最近两轮）。
extends SceneTree

const CASES_PATH := "res://tests/probe_r225_separation_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	await process_frame
	var body: GDScript = load(CASES_PATH)
	if body == null or not body.can_instantiate():
		print("PROBE FAIL | 用例体加载失败：%s" % CASES_PATH)
		quit(1)
		return
	var cases: Object = body.new()
	await cases.run(self)
	var fails: int = int(cases.call(&"fail_count"))
	if fails > 0:
		print("PROBE 汇总：%d 项硬门未过（见上 FAIL 行；FAIL*=披露类失配不计数）" % fails)
		quit(1)
	else:
		print("PROBE 汇总：硬门全过（FAIL*=披露类失配如实记录不冒充通过；基线 JSON 已写+跨代轮转）")
		quit(0)

# tests/probe_r234_overkill.gd（R234 探索：overkill 封顶 只读探针入口）
# 跑法：cd E:/Code/Agent/Infinite-Fission && tools/Godot_v4.3-stable_win64_console.exe \
#         --headless --path E:/Code/Agent/Infinite-Fission/repo -s tests/probe_r234_overkill.gd
# 目的：深载（敌120 驻场 + W2 L5 五词条构筑，r224 夹具逐位同构）下定量实证 overkill
#   需求构成——①一击致死率 ②同帧同目标重复命中分布 ③白打命中占提交需求比例，
#   为 R234「提交前合并/拦截」需求侧砍刀提供实测降幅输入。留档 JSON：
#   docs/qa/probe_r234_overkill_baseline.json（全参数入 meta）。
# 纪律：-s 入口编译期先于 autoload 注册——入口零工程类名直引（全鸭子），用例体运行时
#   加载（probe_r224 同构）；只读不改游戏代码；无 test_ 前缀不入电池。
extends SceneTree

const CASES_PATH := "res://tests/probe_r234_overkill_cases.gd"


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
		print("PROBE 汇总：%d 项硬门未过（见上 FAIL 行）" % fails)
		quit(1)
	else:
		print("PROBE 汇总：硬门全过（①②③ 实测数见上；留档 probe_r234_overkill_baseline.json）")
		quit(0)

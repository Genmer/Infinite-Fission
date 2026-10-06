# tests/probe_r233_stepsize.gd（R233 T8 30Hz 步长 A/B 配对探针入口）
# 跑法：cmd /c "E:/Code/Agent/Infinite-Fission/tools/Godot_v4.3-stable_win64_console.exe \
#         --headless --path E:/Code/Agent/Infinite-Fission/repo -s tests/probe_r233_stepsize.gd"
#       （超时 300s 防卡死配方）
# 目的（R233 分析 Q2 门禁实验——帽值定稿 T3 的前置数据）：
#   同种子同构筑同流程双臂配对——A 臂 dt=1/60 现状步长（-3 哨兵=tier2 帽96），
#   B 臂 dt=1/30 目标步长（override=192 强制帽=帽重标目标态；T3 选表未实施的现网
#   可测口）。headless 手动驱动 _physics_process(dt)，不依赖 Engine.physics_ticks_
#   per_second（电池口径零扰动，引擎物理侧差分不在窗内——披露）。
#   测量：整步墙钟（每步 _physics_process 调用耗时，含全部管线段）≥60s 模拟时长/臂，
#   分稳态窗统计 p50/p95/p99；关键附加读数=结算轴（settle_us_total 逐步差分）、
#   弹段（stage_probe grid_projectile）、结N/提交量/顺N/弃N/派发顺延每秒。
#   门禁：B 臂稳态窗整步墙钟 p95 ≤ 34ms（分析 Q2/AC-1 步耗条款）。
# 纪律：A/B 同进程当日跑（性能结论当日同进程）；探针只读不改产品代码；-s 入口编译期
#   先于 autoload 注册——入口零工程类名直引（全鸭子），用例体运行时加载
#   （probe_r224_deepload 同构）；无 test_ 前缀不入电池；产物 JSON 写 docs/qa/。
extends SceneTree

const CASES_PATH := "res://tests/probe_r233_stepsize_cases.gd"


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
		print("PROBE 汇总：硬门全过（FAIL*=披露类失配如实记录不冒充通过；JSON 已写 docs/qa/）")
		quit(0)

# tests/probe_r234_databench.gd（R234 弹段数据化微基准——Node2D 属性 vs typed 数组 收益系数实证）
# 跑法：cmd /c "E:/Code/Agent/Infinite-Fission/tools/Godot_v4.3-stable_win64_console.exe \
#         --headless --path E:/Code/Agent/Infinite-Fission/repo -s tests/probe_r234_databench.gd"
#       （超时给足 300s；全绝对路径）
# 目的（R234 路线探索：弹段数据导向化 + MultiMesh 渲染）：
#   假设「模拟数据搬 typed 数组 → tick 单函数批处理（零虚调用零属性读写）→ GDScript 内
#   2-4×」——本探针实证该系数，不引用。六臂：
#   A（任务书必测）= Array[Node2D] 循环读 global_position 写 global_position（1 万实体×100 帧）
#   B（任务书必测）= PackedFloat32Array 读写同规模（SoA px/py）
#   C（任务书必测）= RefCounted 对象成员变量读写（对照组——数据留在脚本对象上的中间态）
#   D（追加披露臂）= Array[Node2D] 读写 local position（视觉壳阶段候选路径：桶为原点无变换
#                    local≡global，position 少一次父变换矩阵合成）
#   E（追加披露臂）= 逐弹方法调用 tick_fast_player 克隆体（现架构形态：调用+成员+属性读写
#                    ——寿命/swept 暂存/直线/range 超程/出界五断言，除网格查询）
#   F（追加披露臂）= 同语义批处理 typed 数组循环（目标架构形态——E/F 即快路径弹
#                    「现状→数据化」的可投影收益对）
#   产出：六臂每帧 ms（p50/mean/p95，3 轮取中位）+ 每实体 µs + A/B、C/B、E/F 系数。
# 纪律：种子固定（本夹具无 RNG 消费——初始位用确定性公式，种子入 meta 备查）；探针只读
#   不改产品代码；-s 入口编译期先于 autoload 注册——入口零工程类名直引（全鸭子），用例体
#   运行时加载（probe_r233_stepsize 同构）；无 test_ 前缀不入电池；产物 JSON 写 docs/qa/。
extends SceneTree

const CASES_PATH := "res://tests/probe_r234_databench_cases.gd"


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
		print("PROBE 汇总：硬门全过（六臂微基准数字+JSON 已写 docs/qa/——桌面口径，真机系数须另测）")
		quit(0)

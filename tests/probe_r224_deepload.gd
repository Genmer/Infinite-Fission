# tests/probe_r224_deepload.gd（R224 深载复现基准 只读探针入口）
# 跑法：cd E:/Code/Agent/Infinite-Fission && tools/Godot_v4.3-stable_win64_console.exe \
#         --headless --path E:/Code/Agent/Infinite-Fission/repo -s tests/probe_r224_deepload.gd
# 目的（二q #7 复现点题——用户「波次给你了…是你复现不出来吗」）：
#   翡翠树海(world_grove) 普通 无尽16 构成、敌 120 常驻、深构筑近似（W2 加特林 L5+
#   五词条满叠〔穿透/多重/边界反弹/死亡新星/分裂〕，无棱镜——弹带定标），整帧
#   _physics_process 手动驱动 @60Hz，采集：
#   ① 稳态十五段 stage_probe_us 逐帧分布（P50/P95/均值；card_open 仅开窗帧存在=常缺）；
#   ② 结算三轴（结/顺/冲/弃）每秒差分 → 每步提交需求/实付/丢弃（饱和度账）；
#   ③ 驻场/弹/自导/跳字活口曲线；
#   ④ 两情景对照：S0 预算关（-2）=无刀基线 / S1 模拟真机 tier2（-3）=vc30 深载态；
#   ⑤ 校准门：负载规模与饱和结构与 vc30 真机读数对上（绝对 ms 桌面≠真机——系数声明）。
# 纪律：-s 入口编译期先于 autoload 注册——入口零工程类名直引（全鸭子），用例体运行时
# 加载（probe_r202_bench 同构）；只读不改游戏代码；无 test_ 前缀不入电池。
extends SceneTree

const CASES_PATH := "res://tests/probe_r224_deepload_cases.gd"


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
		print("PROBE 汇总：硬门全过（若有 FAIL*=披露类失配，已如实记录不冒充通过；基线 JSON 已写+旧档轮转）")
		quit(0)

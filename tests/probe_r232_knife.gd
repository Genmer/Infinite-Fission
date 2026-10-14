# tests/probe_r232_knife.gd（R232 结算链瘦身 刀0 四臂测量探针入口）
# 跑法：cd E:/Code/Agent/Infinite-Fission && tools/Godot_v4.3-stable_win64_console.exe \
#         --headless --path E:/Code/Agent/Infinite-Fission/repo -s tests/probe_r232_knife.gd
# 四臂（用例体 probe_r232_knife_cases.gd；boot 构筑与 r225 同指纹）：
#   STEP  = resolve 逐段打点（12 段+子项披露）——只做构成占比，绝不与 MICRO 绝对值对拍
#           （打点开销 ≈+3-11% 自污染，R232 分析 AC-1 裁定三条之一）；
#   FULL  = 全链口径 ①ctx 构建+②词条预聚合+④resolve（真 12 词条 runtime 栈+遗物合成
#           夹具；ON_HIT 效果派发=直调链裁剪排除窗外——AC-1 裁定；附 FULL-M 变体=
#           MULT×4 词条夹具量 ② 段主体上界）；
#   CHURN = override=8 强制帽直达饱和顺延——每顺延入队/同对累积/帧末维护扫描/冲刷
#           单项 µs（刀2 判读输入，判据=churn 占结算轴 >5% 才立刀）；
#   MICRO = r225 同构复刻（合成 ctx 批 48/96/192，窗外预构建，零打点）——每结算 µs 权威。
# A/B 纪律：同进程两轮 × 开关双臂（A=CTX_REUSE/TRAIT_PRECACHE off=改前路径，B=on=改后）
#   ——AC-P1/P2 判定只对同轮次同进程 A/B；r225 档案 50.1µs 为跨日披露参照（R231 教训：
#   跨日微基准不可立项）。
# 纪律：-s 入口编译期先于 autoload 注册——入口零工程类名直引（全鸭子），用例体运行时
#   加载（probe_r225_separation 同构）；无 test_ 前缀不入电池；基线 JSON 写 docs/qa/
#   （跨代轮转 _prev1 只留一代；同日 runs[] 累积最近两轮）。
extends SceneTree

const CASES_PATH := "res://tests/probe_r232_knife_cases.gd"


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

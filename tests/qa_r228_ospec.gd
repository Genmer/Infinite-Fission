# tests/qa_r228_ospec.gd（R228 对象谱清点 只读探针入口）
# 跑法（会话根执行）：
#   cd E:/Code/Agent/Infinite-Fission && tools/Godot_v4.3-stable_win64_console.exe \
#     --headless --path repo -s tests/qa_r228_ospec.gd
# 目的（vc33 深载段 o 2100-2700 之谜）：真机深载 o≈2500 中可见实体仅约 500
#   （敌120+弹40-370+跳24），其余 ~2000 项 canvas item 构成不明——本探针复用
#   probe_r224_deepload(+cases) 的深载构成（翡翠树海 w16、敌120 驻场、W2 L5
#   五词条满叠〔穿透×3/多重×2/边界反弹×3/死亡新星×2/分裂×2〕，无棱镜）跑到
#   深载稳态，遍历整棵场景树按家族清点 CanvasItem 派生节点：
#   敌本体/敌子件（own visible=true/false 分开数）/弹/碎片/跳字/网/磁/UI/玩家/
#   粒子发射器/贴图桶/预警件/其他——每家族给典型节点路径样例与构成明细。
# 真机深载态对齐（R223/R225/R227 override 哨兵先例——headless 不误触产品门）：
#   PerfGovernor 冻结+tier_override=2+mode_override=0（帧率优先）；Enemy.fullload_
#   override=1（满载敌装饰隐藏=vc33「翻1 后稳态」）；DamagePopup.bitmap_override=1
#   （跳字位图化=vc33「全程位图1/补0」，start_run 内 ensure_runstart_bake 兜底烤图）；
#   DamagePipeline.settle_budget_override=-3（tier2 帽96@60Hz——r224 S1 同款）。
# 口径声明（桌面 headless vs 真机）：清点=场景树 CanvasItem 节点数（占树位口径，
#   含 visible=false 池内闲置件）；真机 o=RenderingServer TOTAL_OBJECTS_IN_FRAME
#   （渲染提交对象——语义不同：树清点≥o 的可见子集，且 headless 无渲染面读数恒 0，
#   不可复现——r224 同款披露）。对照可达度以「总量带 + 家族构成」为口径。
# 纪律：-s 入口编译期先于 autoload 注册——入口零工程类名直引（全鸭子），用例体
#   运行时加载（probe_r224_deepload 同构）；只读不改游戏代码；无 test_ 前缀不入
#   电池；留档勿删。
extends SceneTree

const CASES_PATH := "res://tests/qa_r228_ospec_cases.gd"


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
		print("PROBE 汇总：硬门全过——对象谱构成表见上（3 次独立运行取稳定值，跑法见文件头注）")
		quit(0)

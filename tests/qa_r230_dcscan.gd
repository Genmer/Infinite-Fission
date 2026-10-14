# tests/qa_r230_dcscan.gd（R230「高峰 dc 根治轮」dc 分族扫描 只读探针入口）
# 跑法（窗口=真渲染器；会弹真窗口，跑完自退——cwd 无关，绝对路径均可；
#   --audio-driver Dummy=无声驱动静音跑〔R230 二cb：用户反馈窗口测试吵〕）：
#   APPDATA="E:/Code/Agent/Infinite-Fission/.qa_sandbox_r230" \
#   E:/Code/Agent/Infinite-Fission/tools/Godot_v4.3-stable_win64_console.exe \
#     --path E:/Code/Agent/Infinite-Fission/repo --rendering-method gl_compatibility \
#     --audio-driver Dummy -s tests/qa_r230_dcscan.gd
# 短窗口 smoke（content v2 fork 验证臂：boot+SA 基线+注入门+P1 13 族闭环，不落 JSON——
#   完整 3 跑基线留 post-merge 统一阶段；同样必须带 APPDATA 沙箱前缀）：
#   … 同上命令，末尾追加  --  --smoke
# K2c 否决臂（post-merge 统一验证：deathpop_cap_override=-2 帽关 SA P1，对照磁盘当前
#   基线 SA=纯 K2c 刀效；落独立档 docs/qa/qa_r230_dcscan_k2c_veto.json 不入轮转链；
#   须先跑完权威 3 跑全扫——对照源=末跑基线；同样必须带 APPDATA 沙箱前缀）：
#   … 同上命令，末尾追加  --  --k2c_veto
# headless 对照臂（FG0 半边：dc 恒 0=RS 短路证明；headless 走 *_test.cfg 惯例档，
# 无需 APPDATA 重定向）：
#   … 同命令去 APPDATA 前缀、加 --headless。
# ★ content_version=2（2026-10-04 FG4 fork）：首跑 SA 基线 240/258/263 全 <500 裁定
#   走设计 §1.6 fork——缺口=内容差非渲染器。用例体升级注入：敌方远程弹（E7_spitter
#   射手切片+精英 affix_ring+弹池注入补出生管线缺环）+ 棱镜（W5_prism L5 镜5）+
#   分类器 12→13 族（F13 敌弹=team1）；JSON schema 加 content_version 字段，旧档=1
#   FG2 拒比。详见用例体头注 FG4 条目。
# ★ APPDATA 沙箱红线说明：窗口模式（非 headless）下产品波次边界会写 RunSave（
#   user://run_save.cfg 真档）——违反「user:// 不写」红线。本探针强制要求窗口跑以
#   APPDATA 环境变量把 user:// 根重定向到仓内沙箱（E 盘），用例体自检
#   OS.get_user_data_dir() 含沙箱标记，未生效则 FAIL 中止（不硬闯）；Meta 侧另有
#   begin_persist_defer 全程挂起双保险（_save 直接短路）。读档随之沙箱化=出厂默认态
#   +哨兵内存注入钉键（fx_quality/damage_numbers_on/fx_opacity——复审节修正口径，
#   禁 Meta.set_setting 写即存口）。
# 目的（设计 §1 夹具浪）：PC 窗口化 gl_compatibility 渲染夹具把真机深载 dc 700-990
#   分解到 12 族（S-A 深载驻场 / S-A' 阀全关锚档 / S-B 弹幕带 × P1 累积关断 /
#   P2 单独可见 / P3 逆序复跑），FG0-FG5 门 + 基线 JSON 落 docs/qa/（R224 轮转先例）。
# 纪律：-s 入口编译期先于 autoload 注册——入口零工程类名直引（全鸭子），用例体运行
#   时加载（probe_r224_deepload 同构）；只读不改游戏代码；无 test_ 前缀不入电池；
#   watchdog 兜底任何路径最终 quit()（不留窗口僵尸进程——FG0 要求）。
extends SceneTree

const CASES_PATH := "res://tests/qa_r230_dcscan_cases.gd"
const WATCHDOG_S := 1200.0                       # 全程 <3 分钟/跑，20 分钟硬帽纯兜底


func _initialize() -> void:
	# 任何路径保证 quit（FG0）：含用例体脚本错误挂起——watchdog 引擎侧定时器独立于
	# 协程，超时强退退出码 2（导出前主控照例查杀残留 Godot 进程——红线 §3.6）。
	# set_auto_accept_quit(false)：窗口 X/系统关窗请求不再直接退进程（T3 实测一跑
	# 被外部关窗截断——exit 0 无脚本错误无汇总=典型关窗形态）；退出唯一出口=本脚本
	# 显式 quit（正常/看门狗两路都在）。
	set_auto_accept_quit(false)
	var wd := create_timer(WATCHDOG_S)
	wd.timeout.connect(func() -> void:
		print("WATCHDOG | 探针 %ds 未收尾，强制退出（退出码 2——查窗口僵尸/夹具卡死）" % int(WATCHDOG_S))
		quit(2))
	_run()


func _run() -> void:
	await process_frame
	await process_frame
	# 渲染法：CLI --rendering-method 旗标不落 ProjectSettings（get_setting_with_override
	# 读不到）——直接扫命令行旗标，缺省回退工程设置；4.3 无 get_current_rendering_method
	var rmethod := str(ProjectSettings.get_setting_with_override(
		&"rendering/renderer/rendering_method"))
	var args := OS.get_cmdline_args()
	for i in range(args.size() - 1):
		if String(args[i]) == "--rendering-method":
			rmethod = String(args[i + 1])
	print("DCSCAN 环境头：rendering=%s headless=%s user_dir=%s" % [
		rmethod, str(DisplayServer.get_name() == "headless"), OS.get_user_data_dir()])
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
		print("PROBE 汇总：硬门全过（若有 FAIL*=披露类失配，已如实记录不冒充通过）")
		quit(0)

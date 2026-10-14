# tests/_tmp_r231_pfastab.gd
# R231 刀B 同进程开关 A/B 仲裁（临时文件，勿入电池）。
# 背景：本机跨进程探针墙钟噪声 ±30-40% 实证（同代码两跑 totals p50 22.8 vs 40.5）——
# 单跑/跨进程对比不具分辨力。本脚本在同一进程内以探针 S0 口径（预算关 override=-2）
# 跑两臂：A=PLAYER_BULLET_FAST_PATH true（刀B 激活）→ B=false（全慢路径），同 seed
# 20261003 重播、同 GameLoop 顺序驱动（臂间 300 帧预热重暖缓存）；两臂 grid_projectile
# /grid_rebuild 段 p50 + 快N 覆盖率 + 结算/击杀指纹对读——同进程对的差值为权威。
# 复用 probe_r224_deepload_cases 夹具（_boot/_scenario/_teardown 直调——场景构建与
# RNG 消费序与正式探针逐位一致；场景键 "S0" 落基线 JSON 会被后续正式跑覆写，链式
# 轮转属探针设计行为）。入口零工程类名直引（-s 编译期先于 autoload——探针同款纪律），
# 开关切换单例静态成员走鸭子 set/get（cases._gl 解析后）。
extends SceneTree

const CASES := "res://tests/probe_r224_deepload_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	await process_frame
	var body: GDScript = load(CASES)
	var cases: Object = body.new()
	cases.set("tree", self)
	print("══ R231 刀B 同进程开关 A/B 仲裁（S0 口径 full 测量窗） ══")
	if not (cases.call(&"_boot") as bool):
		print("AB FAIL | 引导失败")
		quit(1)
		return
	var loop: Object = cases.get("_gl")
	# 臂 A：刀B 激活
	loop.set("PLAYER_BULLET_FAST_PATH", true)
	seed(20261003)
	cases.call(&"_scenario", "S0_A_fast(刀B激活)", -2)
	# 臂 B：全慢路径（开关关——同 seed 重播）
	loop.set("PLAYER_BULLET_FAST_PATH", false)
	seed(20261003)
	cases.call(&"_scenario", "S0_B_slow(全慢路径)", -2)
	cases.call(&"_teardown")
	loop.set("PLAYER_BULLET_FAST_PATH", true)
	print("══ A/B 完成——判读：两臂 grid_projectile p50 差值=刀B 同进程收益（权威）；快N=覆盖率 ══")
	quit(0)

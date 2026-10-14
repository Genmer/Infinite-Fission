# tests/qa_r255_play_entry.gd — R255 完整对局试玩探针入口（两段式，先例 qa_r254_probe_map.gd）
# 玩法纪律：
#   · 全程真实 UI 链路——只 emit 按钮 pressed 信号 / 走面板开合，不直调内部状态跳 UI；
#   · 战斗走位 = Input.parse_input_event(InputEventScreenDrag)（player._unhandled_input 自采同链）；
#   · 不碰 hp/伤害（无无敌无锁血）；选卡允许 auto_select_on 快选（任务书口径）；
#   · Meta 只读真档；困难第三关解锁用内存直改 map_records 分档键（不落盘，收尾还原）。
# 纪律：-s 入口编译期 autoload 未注册——入口零工程类直引，逻辑全在 cases 体运行时加载。
# 用法：Godot --path repo -s tests/qa_r255_play_entry.gd -- a|b   （a=普通草原局 b=困难第三关局）
extends SceneTree

const CASES := {
	"a": "res://tests/qa_r255_play_a.gd",
	"b": "res://tests/qa_r255_play_b.gd",
}


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	await process_frame
	var pick := "a"
	for arg in OS.get_cmdline_user_args():
		var a := String(arg).strip_edges().to_lower()
		if CASES.has(a):
			pick = a
	var body: GDScript = load(CASES[pick])
	if body == null or not body.can_instantiate():
		print("PROBE FAIL | 用例体加载失败：%s" % CASES[pick])
		quit(1)
		return
	print("[entry] 局=%s cases=%s" % [pick, CASES[pick]])
	var cases: Object = body.new()
	await cases.run(self)
	quit(0)

# tests/qa_r255_play_menu.gd — R255 玩家大厅漫游探针入口（只读产品代码）
# 目的：真实 UI 链路走完 大厅全漫游（主菜单 → 出发/选关面板[三难度切换+锁定态]
#   → 图鉴五页 → 成就 → 历史记录 → 选人 → 局外养成 → 每日挑战 → 设置），
#   逐界面截图到 docs/qa/r255-play/menu-XX.png。
# 纪律（同 qa_r254_probe_map 先例）：-s 入口编译期 autoload 未注册——入口零工程类
# 直引，逻辑全在 cases 体运行时加载。点击全部走 Button.pressed 信号（按钮信号/
# 面板开合），不直调面板内部方法跳过 UI；不点任何写档按钮（选用/解锁/升级/设置
# 开关/出发类）。外层另做 user:// 存档快照还原兜底。
extends SceneTree

const CASES_PATH := "res://tests/qa_r255_play_menu_cases.gd"


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
	quit(0)

# tests/runner/test_pkg10.gd
# v1.0.0 自测入口（局外成长 Meta + 存档层；两段式同 pkg0~pkg9：
#   godot --headless --path <工程> -s tests/runner/test_pkg10.gd）
# 覆盖冻结方案 pkg10 用例组 M1~M24（A9_v1.0.0_design.md；每恰 1 断言）：
#   M1 存档往返恒等 / M2 损坏文件 / M3 save_version=99 拒降读 / M4 缺键 / M5 越界钳制
#   M6 定价序列（逐级迭代 100/160/256/410/656）/ M7 purchase 成功落盘 / M8 拒绝三态
#   M9 wipe / M10 写失败内存保留 / M11 死亡结转一次闸 / M12 best_wave 不回退
#   M13 hpg 注入手算 / M14 meta flat 与商店 flat 共存 / M15 atk 注入
#   M16 greed 合并段 / M17 开局金不被 greed 放大 / M18 xp 第 4 因子（fixed-seed）
#   M19 meta 跨局存活 / M20 面板开闭 / M21 购买仲裁 / M22 布局契约
#   M23 全 0 级与 v0.9.0 恒等锚 / M24 settle 降级（meta_store 缺失 → 结晶 +0）
extends SceneTree

const CASES_PATH := "res://tests/runner/pkg10_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · v1.0.0 局外成长自测（pkg10 M1~M24） ══════════")
	# 等引擎注册的 autoload 完成 add_child + _ready（EventBus→GameConfig→DebugStats）
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	var cases = cases_script.new()
	cases.run(self)
	var fail_count: int = cases.fail_count()
	if fail_count > 0:
		quit(1)
	else:
		quit(0)

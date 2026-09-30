# scripts/ui/safe_area_helper.gd
# R195 适配底座：安全区（刘海/挖孔/圆角）单点 static 工具类——各屏（UI 锚定组七屏 +
# 商店组 shop_ui 根 FULL_RECT）只引用不复写。
# 契约（R195 仲裁定案）：
# · 守卫：仅 mobile 平台 或 全屏窗口（FULLSCREEN/EXCLUSIVE_FULLSCREEN）读真值——
#   窗口化桌面 get_safe_area 返回整台显示器矩形（inset 可达 +1933px 实证）、headless
#   返回恒零矩形，守卫外 insets 恒零（矩阵套件永不读真值，headless 全绿≠真机已验证）。
# · 换算：DisplayServer 窗口像素域 → canvas 域 =
#   root.get_final_transform().affine_inverse() × Rect2(safe_area)；负值钳零。
# · 时序：窗口 realize 后延迟 ≥1 帧再读（首帧查询为未 realize 真值）；重读时机 =
#   size_changed + 窗口重获焦点（WM_WINDOW_FOCUS_IN 语义；static 工具类不便挂 Node
#   通知，统一走 Window.focus_entered 信号等价口）。
# · 返回口径：Rect2 position=(左/上 inset)、size=(右/下 inset)，单位=canvas px——
#   消费式：根 Control offset_left=+左 / offset_top=+上 / offset_right=−右 /
#   offset_bottom=−下。手势条 insets 引擎不报，首版不垫盲值常量（R195 定案）。
class_name SafeAreaHelper
extends RefCounted


static func enabled(p_window: Window) -> bool:
	# 守卫：mobile 平台或全屏窗口才读真值；其余（桌面窗口化/headless）恒零=无 inset
	if p_window == null:
		return false
	if OS.has_feature("mobile"):
		return true
	var mode := p_window.get_mode()
	return mode == Window.MODE_FULLSCREEN or mode == Window.MODE_EXCLUSIVE_FULLSCREEN


static func insets(p_window: Window) -> Rect2:
	# 安全区内边距（canvas px）：position=(左,上) / size=(右,下)；守卫外恒零 Rect2。
	# 4.3 API=DisplayServer.get_display_safe_area()（display 级 Rect2i；无 window 级接口）
	# ——返回 display 像素坐标：全屏守卫下窗口原点==display 原点，坐标域一致可直乘；
	# 这正是守卫排除窗口化桌面的第二重原因（窗口位置偏移无 window 级 API 可校正）
	if not enabled(p_window):
		return Rect2()
	var raw := Rect2(DisplayServer.get_display_safe_area())
	if raw.size.x <= 0.0 or raw.size.y <= 0.0:
		return Rect2()                         # headless/未 realize：恒零矩形兜底
	var to_canvas: Transform2D = p_window.get_final_transform().affine_inverse()
	var area: Rect2 = to_canvas * raw
	var vis := p_window.get_visible_rect()
	# 负值钳零（安全区越出画布的超扫场景 defensively 归零）
	return Rect2(
		Vector2(maxf(area.position.x, 0.0), maxf(area.position.y, 0.0)),
		Vector2(maxf(vis.size.x - area.end.x, 0.0), maxf(vis.size.y - area.end.y, 0.0)))


static func read_deferred(p_window: Window) -> Rect2:
	# realize 后延迟 ≥1 帧再读（协程口：消费方 await 本函数取值）
	if p_window == null:
		return Rect2()
	await p_window.get_tree().process_frame
	return insets(p_window)


static func bind_reread(p_window: Window, p_on_change: Callable) -> void:
	# 重读时机接线：size_changed + 重获焦点 → 消费方回调内重读 insets() 再应用
	#（只加信号连接不轮询——R188：适配层禁每帧分配/扫描）
	if p_window == null or not p_on_change.is_valid():
		return
	p_window.size_changed.connect(p_on_change)
	p_window.focus_entered.connect(p_on_change)

# qa_r203_probe.gd — R203 QA 只读探针（不改被测代码；跑完即弃）
# 目的：
# ① headless 下 OS.has_feature("mobile") 取值（A① 桌面/headless 路径零变化的实证前提）
# ② stretch mode viewport vs canvas_items 运行期切换下的窗口/画布尺寸语义对照（D 漏网排查）
# ③ Lv10 / ×2 / ×9 @16pt 实测字宽（B 几何契约：38 / 28 承载判据）
extends SceneTree


func _dump(tag: String) -> void:
	var win := root
	print("[%s] window.size=%s content_scale_size=%s factor=%.3f mode=%d aspect=%d" % [
		tag, win.size, win.content_scale_size, win.content_scale_factor,
		win.content_scale_mode, win.content_scale_aspect])
	print("[%s] visible_rect=%s final_transform=%s screen_transform=%s" % [
		tag, win.get_visible_rect(), win.get_final_transform(),
		win.get_screen_transform()])


func _initialize() -> void:
	print("=== A1 feature tags ===")
	print("OS.get_name()=%s mobile=%s headless=%s web=%s" % [
		OS.get_name(), OS.has_feature("mobile"), OS.has_feature("headless"),
		OS.has_feature("web")])
	print("=== D size semantics: current (project=viewport/expand) ===")
	_dump("viewport")
	# 模拟超长窗（expand 延伸域）——r195 七尺寸矩阵同思路
	root.size = Vector2i(600, 1280)
	_dump("viewport-600x1280")
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	_dump("canvas_items-600x1280")
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_VIEWPORT
	root.size = Vector2i(540, 960)
	print("=== B string metrics @16pt (StickerTheme.font) ===")
	var f := StickerTheme.font()
	for s: String in ["Lv10", "Lv9", "×2", "×9", "+9"]:
		var m := f.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, 16)
		print("'%s' @16pt -> %s" % [s, m])
	# 引擎 Label min-width 口径（r198_hud_layout R⑤ 判据复核）
	var l := Label.new()
	l.text = "×9"
	l.add_theme_font_size_override("theme_override_font_sizes/font_size", 16)
	root.add_child(l)
	print("Label('×9',16pt) min size = %s" % l.get_combined_minimum_size())
	l.queue_free()
	print("=== PROBE DONE ===")
	quit(0)

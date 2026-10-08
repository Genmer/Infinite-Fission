# R203 评审探针（只读取证）：viewport vs canvas_items 字体锐度对比截图
extends SceneTree

var _main: Node = null

func _initialize() -> void:
	_run()

func _run() -> void:
	await process_frame
	root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
	root.size = Vector2i(1440, 2560)
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_VIEWPORT
	await process_frame
	_main = load("res://scenes/main.tscn").instantiate()
	root.add_child(_main)
	for i in range(50):
		await process_frame
	var cv := CanvasLayer.new()
	cv.name = "ReviewLayer"
	_main.add_child(cv)
	var texts := {"A_14pt": 14, "B_16pt": 16, "C_18pt": 18}
	var y := 900.0
	for k in texts:
		var l := Label.new()
		l.name = k
		l.text = "BUFF测试x9Lv10 %dpt" % texts[k]
		l.add_theme_font_size_override("font_size", texts[k])
		l.position = Vector2(40.0, y)
		y += 40.0
		cv.add_child(l)
	for i in range(10):
		await process_frame
	_shot("user://r203_menu_viewport.png")
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	for i in range(10):
		await process_frame
	_shot("user://r203_menu_canvas_items.png")
	print("PROBE_DONE")
	quit(0)

func _shot(p_path: String) -> void:
	var img := root.get_texture().get_image()
	img.save_png(p_path)
	print("SAVED ", p_path, " ", img.get_width(), "x", img.get_height())

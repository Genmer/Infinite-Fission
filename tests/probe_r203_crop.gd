extends SceneTree
func _initialize() -> void:
	_run()
func _run() -> void:
	var base := OS.get_user_data_dir().path_join("../Infinite Fission/")
	var vp_png: Image = Image.load_from_file(base + "r203_menu_viewport.png")
	var ci_png: Image = Image.load_from_file(base + "r203_menu_canvas_items.png")
	if vp_png == null or ci_png == null:
		print("LOAD_FAIL"); quit(1); return
	# viewport 截图为 720×1280 缓冲（即上采样源）；canvas_items 截图为 1440×2560 原生。
	# 同一设计区 (30,880)-(490,1030)：vp 直接裁，ci 裁 2x 区域后缩回同尺寸 → 同窗对比。
	var crop_v: Image = vp_png.get_region(Rect2i(30, 880, 460, 150))
	crop_v.resize(1380, 450, Image.INTERPOLATE_NEAREST)
	crop_v.save_png(OS.get_user_data_dir() + "/r203_crop_viewport.png")
	var crop_c: Image = ci_png.get_region(Rect2i(60, 1760, 920, 300))
	crop_c.resize(1380, 450, Image.INTERPOLATE_NEAREST)
	crop_c.save_png(OS.get_user_data_dir() + "/r203_crop_canvas_items.png")
	print("CROP_OK")
	quit(0)

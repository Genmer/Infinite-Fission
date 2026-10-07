extends SceneTree
# R240-B1 翻转修复像素对拍探针（必须窗口渲染器跑——headless Dummy 不落地像素）：
# 同一非对称贴图，Sprite2D 与 MultiMesh(ArrayMesh UV-up) 单实例同变换渲染，
# viewport 截图逐像素对拍——修复达标=direct diff≈0 且 vflipped diff 显著>0
# （对照臂：若仍翻转，direct 大 / vflipped≈0，正是评审 BLOCKER 复现口径）。
# 贴图取 grunt（珊瑚怪脸）+ volatile_scared（惊恐脸）双证（评审实证用例）。
# 运行：APPDATA=<沙箱> godot --path repo -s tests/probe_r240_uvfix.gd（无 --headless）

const TEX_KEYS := [&"grunt", &"volatile_scared"]
const P_SPRITE := Vector2(120, 120)
const P_MM := Vector2(360, 120)
const DIRECT_PASS := 0.012   # 均值 diff 阈（亚像素滤波/半像素采样余量）
const VFLIP_MIN := 0.05      # 非对称贴图翻转应显著可见（贴图有效性自检）

var _host: Node2D = null


func _initialize() -> void:
	_boot()


func _boot() -> void:
	await process_frame
	await process_frame
	var out := {"display": DisplayServer.get_name(),
		"direct": {}, "vflipped": {}, "pass": true}
	# tex_bucket_host 无场景实例亦可：_quad_mesh_uv_up 是 static（仅用贴图尺寸）
	for tk in TEX_KEYS:
		var tex: Texture2D = TextureFactory.enemy_tex(tk)
		var d: Dictionary = await _compare(tex)
		out["direct"][String(tk)] = d.direct
		out["vflipped"][String(tk)] = d.vflipped
		var ok: bool = float(d.direct) <= DIRECT_PASS and float(d.vflipped) >= VFLIP_MIN
		out["pass"] = out["pass"] and ok
		print("[%s] direct=%.4f vflipped=%.4f → %s" % [String(tk), d.direct, d.vflipped,
			"PASS" if ok else "FAIL"])
	var f := FileAccess.open("res://docs/qa/probe_r240_uvfix.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(out, "  "))
	f.close()
	print("PROBE %s (display=%s)" % ["PASS" if out["pass"] else "FAIL", out["display"]])
	quit(0 if out["pass"] else 1)


func _compare(p_tex: Texture2D) -> Dictionary:
	if _host != null:
		_host.queue_free()
		await process_frame
	_host = Node2D.new()
	root.add_child(_host)
	var spr := Sprite2D.new()
	spr.texture = p_tex
	spr.position = P_SPRITE
	_host.add_child(spr)
	var mmi := MultiMeshInstance2D.new()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_2D
	mm.use_colors = true
	mm.mesh = TexBucketHost._quad_mesh_uv_up(p_tex)
	mm.custom_aabb = AABB(Vector3(-1e7, -1e7, -1.0), Vector3(2e7, 2e7, 2.0))
	mm.instance_count = 1
	mm.set_instance_transform_2d(0, Transform2D(0.0, Vector2(1, 1), 0.0, P_MM))
	mm.set_instance_color(0, Color.WHITE)
	mmi.multimesh = mm
	mmi.texture = p_tex
	_host.add_child(mmi)
	await process_frame
	await process_frame
	await process_frame   # 双缓冲呈现余量
	var img := root.get_texture().get_image()
	var sz := p_tex.get_size()
	var r1 := Rect2i((P_SPRITE - sz * 0.5).round(), sz.round())
	var r2 := Rect2i((P_MM - sz * 0.5).round(), sz.round())
	var direct := _mean_diff(img, r1, img, r2, false)
	var vflip := _mean_diff(img, r1, img, r2, true)
	return {"direct": direct, "vflipped": vflip}


static func _mean_diff(p_a: Image, p_ra: Rect2i, p_b: Image, p_rb: Rect2i, p_flip_b: bool) -> float:
	var n := 0
	var acc := 0.0
	for y in range(p_ra.size.y):
		for x in range(p_ra.size.x):
			var ca := p_a.get_pixel(p_ra.position.x + x, p_ra.position.y + y)
			var yb := (p_rb.size.y - 1 - y) if p_flip_b else y
			var cb := p_b.get_pixel(p_rb.position.x + x, p_rb.position.y + yb)
			acc += absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b)
			n += 1
	return acc / float(n * 3) if n > 0 else 1.0

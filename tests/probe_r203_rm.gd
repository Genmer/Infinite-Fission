extends SceneTree
func _initialize() -> void:
	var k := "rendering/renderer/rendering_method.mobile"
	print("HAS_KEY=", ProjectSettings.has_setting(k))
	print("VAL=", str(ProjectSettings.get_setting(k, "<absent>")))
	print("BASE=", str(ProjectSettings.get_setting("rendering/renderer/rendering_method", "<absent>")))
	quit(0)

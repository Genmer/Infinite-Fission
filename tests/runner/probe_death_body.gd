extends RefCounted
var tree: SceneTree
func run(p_tree: SceneTree) -> void:
	tree = p_tree
	var scene: PackedScene = load("res://scenes/main.tscn")
	var gl: GameLoop = scene.instantiate() as GameLoop
	tree.get_root().add_child(gl)
	await tree.process_frame
	Meta.maps_cleared = {}
	gl.state = GameConst.GameStatus.MENU
	gl.current_map_id = MapTable.FIRST_MAP_ID
	gl._on_menu_start(MapTable.FIRST_MAP_ID)
	await tree.process_frame
	print("fq=", Meta.settings("fx_quality"))
	var e: Enemy = (gl.pools[&"enemy"] as EnemyPool).acquire()
	var data: EnemyData = gl.registry.get_enemy(&"E1_grunt")
	e.spawn(data, 1, 0)
	e.position = Vector2(500.0, 700.0)
	print("parent=", e.get_parent(), " parent_class=", e.get_parent().get_class())
	var names_before := []
	for c in e.get_parent().get_children():
		names_before.append(String(c.name))
	e.apply_damage(999999.0)
	var names_after := []
	for c in e.get_parent().get_children():
		names_after.append(String(c.name))
	print("before=", names_before)
	print("after=", names_after)
	tree.quit(0)

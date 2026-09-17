extends SceneTree
var _body
func _initialize():
	_run()
func _run():
	await process_frame
	await process_frame
	_body = load("res://tests/runner/probe_death_body.gd").new()
	_body.run(self)

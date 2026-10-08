# tests/_tmp_qa_r231_boundary.gd
# R231 QA1 边界复核入口（临时——_tmp 前缀不入电池 glob）。用例体：_tmp_qa_r231_boundary_cases.gd
extends SceneTree

const CASES_PATH := "res://tests/_tmp_qa_r231_boundary_cases.gd"

func _initialize() -> void:
    _run()

func _run() -> void:
    print("==== R231 QA1 boundary re-check ====")
    await process_frame
    await process_frame
    var cs: GDScript = load(CASES_PATH)
    if cs == null or not cs.can_instantiate():
        print("FAIL | cases load failed")
        quit(1)
        return
    var cases = cs.new()
    await cases.run(self)
    quit(1 if cases.fail_count() > 0 else 0)

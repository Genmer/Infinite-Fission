# tests/probe_r246_ranger_blink_body.gd（R246 探针用例体）
# 判读口径：全部为「已修」期望值——瞬步落点与移动同口径活动区钳制
# （y∈[size.y*0.6, size.y-hitbox_radius]，hitbox_radius=16）。核心门=「施放后 y
# 与下一帧 y 差 <1px」（旧实现全屏界放行 y=540 → 下一帧活动区拉回 768，差 228px）。
extends RefCounted

const DT := 1.0 / 120.0
const MAIN_SCENE := "res://scenes/main.tscn"
const BLINK_DIST := 260.0
const HITBOX_RADIUS := 16.0

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: Object = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	Meta.set_setting("fx_quality", 2)
	_boot_game_loop()
	_test_upward_blink_no_rebound()
	_test_upward_midzone_full_distance()
	_test_downward_blink_unaffected()
	_test_lateral_blink_unaffected()
	_teardown_game_loop()
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)


func fail_count() -> int:
	return _fail


func _boot_game_loop() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate()
	_gl.name = "GameLoopUnderTest"
	tree.get_root().add_child(_gl)
	_gl.state = GameConst.GameStatus.MENU
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	_gl.start_run()
	var p: Object = _gl.player
	p.set("max_hp", 1000000.0)
	p.set("hp", 1000000.0)
	Meta.unlocked_characters["ranger"] = true      # 解锁门直开（verify 同口径；沙箱存档隔离）
	p.call(&"set_character", &"ranger")


func _teardown_game_loop() -> void:
	tree.paused = false
	RunSave.clear()
	if _gl != null:
		_gl.free()


func _logic_size() -> Vector2:
	# 与 player._clamp_to_playfield 同源取法（balance 优先，缺省 720×1280）
	if GameConfig.balance != null:
		return Vector2(GameConfig.balance.res_logic)
	return Vector2(720.0, 1280.0)


func _blink(p_dir: Vector2) -> void:
	# 定向瞬步：直写取向 + 冷却归零再施放（等效 CDR 堆满后的再触发）
	_gl.player.set("_last_move_dir", p_dir)
	_gl.player.set("skill_cd_left", 0.0)
	_gl.player.call(&"activate_skill")


func _tick_one_frame() -> void:
	_gl.player.call(&"tick", DT, Vector2.ZERO)


func _pos() -> Vector2:
	return (_gl.player as Node2D).global_position


func _check(p_cond: bool, p_msg: String, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("  PASS | %s" % p_msg)
	else:
		_fail += 1
		_failures.append("%s %s" % [p_msg, p_detail])
		print("  FAIL | %s %s" % [p_msg, p_detail])


func _test_upward_blink_no_rebound() -> void:
	print("── ① 上向瞬步：停在活动区上界 + 下一帧零回弹 ──")
	var size := _logic_size()
	var top: float = size.y * 0.6                     # 活动区上界（720×1280 → 768）
	(_gl.player as Node2D).global_position = Vector2(size.x * 0.5, top + 32.0)
	var y0: float = _pos().y
	_blink(Vector2.UP)
	var y1: float = _pos().y
	_check(absf(y1 - top) < 1.0, "施放后 y=活动区上界 %.0f（同口径钳制；旧实况 540）" % top,
		"y=%.1f" % y1)
	_check(absf((y0 - y1) - (y0 - top)) < 1.0, "净位移=到上界全距 %.0fpx（承诺内最大化）" % (y0 - top),
		"net=%.1f" % (y0 - y1))
	_tick_one_frame()
	var y2: float = _pos().y
	_check(absf(y2 - y1) < 1.0, "下一帧 y 差 <1px（无回弹；旧实况拉回 768 抖 228px）",
		"|Δy|=%.1f" % absf(y2 - y1))
	_check(float(_gl.player.get("invuln_left")) > 0.5, "瞬步无敌窗保持（>0.5s）")


func _test_upward_midzone_full_distance() -> void:
	print("── ② 活动区中段上向瞬步：260px 全额兑现 ──")
	var size := _logic_size()
	var top: float = size.y * 0.6
	(_gl.player as Node2D).global_position = Vector2(size.x * 0.5, top + 300.0)
	var y0: float = _pos().y
	_blink(Vector2.UP)
	var y1: float = _pos().y
	_check(absf((y0 - y1) - BLINK_DIST) < 1.0, "中段上向净位移=260px 全额（落点未越活动区）",
		"net=%.1f" % (y0 - y1))
	_tick_one_frame()
	_check(absf(_pos().y - y1) < 1.0, "下一帧零回弹（落点本就在活动区内）",
		"|Δy|=%.1f" % absf(_pos().y - y1))


func _test_downward_blink_unaffected() -> void:
	print("── ③ 下向瞬步：不受影响（越界时钳下界 + 零回弹） ──")
	var size := _logic_size()
	var bottom: float = size.y - HITBOX_RADIUS        # 活动区下界（1280−16=1264）
	(_gl.player as Node2D).global_position = Vector2(size.x * 0.5, bottom - 100.0)
	var y0: float = _pos().y
	_blink(Vector2.DOWN)
	var y1: float = _pos().y
	_check(absf(y1 - bottom) < 1.0, "下越界钳活动区下界 %.0f" % bottom, "y=%.1f" % y1)
	_tick_one_frame()
	_check(absf(_pos().y - y1) < 1.0, "下一帧零回弹", "|Δy|=%.1f" % absf(_pos().y - y1))
	# 中段下向：260px 全额
	(_gl.player as Node2D).global_position = Vector2(size.x * 0.5, bottom - 400.0)
	y0 = _pos().y
	_blink(Vector2.DOWN)
	_check(absf(_pos().y - (y0 + BLINK_DIST)) < 1.0, "中段下向净位移=260px 全额",
		"net=%.1f" % (_pos().y - y0))


func _test_lateral_blink_unaffected() -> void:
	print("── ④ 横向瞬步：位移幅度保持（verify 既有断言语义） ──")
	var size := _logic_size()
	(_gl.player as Node2D).global_position = Vector2(size.x * 0.5, size.y * 0.8)
	var pos0: Vector2 = _pos()
	_blink(Vector2.RIGHT)
	_check((_pos() - pos0).length() > 200.0, "横向瞬步位移 >200px（360→620 未越界）",
		"len=%.1f" % (_pos() - pos0).length())
	_tick_one_frame()
	_check(absf(_pos().y - pos0.y) < 1.0, "横向瞬步 y 不漂移", "|Δy|=%.1f" % absf(_pos().y - pos0.y))
	# 右缘越界：钳 x 右界（size.x−hitbox_radius）且零回弹
	(_gl.player as Node2D).global_position = Vector2(size.x - 40.0, size.y * 0.8)
	_blink(Vector2.RIGHT)
	var x1: float = _pos().x
	_check(absf(x1 - (size.x - HITBOX_RADIUS)) < 1.0, "右缘越界钳活动区右界 %.0f（同口径）" % (size.x - HITBOX_RADIUS),
		"x=%.1f" % x1)
	_tick_one_frame()
	_check(absf(_pos().x - x1) < 1.0, "右缘下一帧零回弹", "|Δx|=%.1f" % absf(_pos().x - x1))

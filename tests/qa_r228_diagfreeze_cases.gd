# tests/qa_r228_diagfreeze_cases.gd
# QA-R228/R229 用例体：诊断行冻结格式对拍。
# 序列（改造前后逐位同一）：boot（main.tscn 真链）→ 冻结 MENU → 位图就绪等待（消除
#   菜单期补烤时点的运行间抖动）→ tier_override=2 + mode_override=0 注入（改造前即
#   「触发步」的全部可达面；R229 后 headless 真值门仍关——本探针不注 -3，触发链归
#   test_r229_pool_valve）→ 同步块三采样 L1/L2/L3（固定 now，无 await 物理不前进——
#   时间戳/模N/风暴差分全确定化；L1→L2 之间驱动一帧 _physics_process = 触发步）。
# 归一化口径（对拍掩码，两轮同规）：fps\d+ → fpsF、余\d+ms → 余Fms——两者是引擎全局
#   读数（平滑帧率及其导出的帧预算残差），非本刀面触碰面；其余字段（含 补N）全裸比对。
# 对拍断言：after[i] == before[i] + " 裁%d"（i∈{1,2,3}；headless 无触发 → 裁0）——
#   R231 刀B 披露：行尾再追加「快N」段，剥离正则放宽为「 裁\d+( 快\d+)?$」；行尾格式
#   变更后 compare 模式须重采采集档（capture 模式重跑一次）。
#   R232 T1b 披露：行尾再追加「结µsN」段，剥离正则再放宽为「 裁\d+( 快\d+)?( 结µs\d+)?$」
#   （R231 快N 同款迁移纪律；MENU 冻结态结N 差分=0 → 结µs0 确定值）。
#   R233 T1 披露：行尾再追加「插µsN」段，剥离正则再放宽为「 裁\d+( 快\d+)?( 结µs\d+)?
#   ( 插µs\d+)?$」（R232 结µs 同款迁移纪律；插值层 T6 未实施期累计器恒 0 → 插µs0 确定值）。
#   R233 修轮披露（HIGH-1/MED-3）：行尾再追加「插模拟µsN」「派deferredN 派dropN」段
#   （模拟侧插值两遍历当秒累计 µs + 派发帽顺延/过期丢弃秒差分），剥离正则再放宽为
#   「 裁\d+( 快\d+)?( 结µs\d+)?( 插µs\d+)?( 插模拟µs\d+)?( 派deferred\d+)?( 派drop\d+)?$」
#   （同款迁移纪律；插模拟µs=时序读数不逐位断言，MENU 冻结同步窗=0 确定值；
#   派deferred0 派drop0=MENU 无战斗派发确定值）。
#   R235 搭车③披露：行尾再追加「物步µsN 派µsN 渲msN.N」段（物理服务器步本体/⑧前
#   派发段/渲染轴秒窗键），剥离正则再放宽为
#   「 …( 派deferred\d+)?( 派drop\d+)?( 物步µs\d+)?( 派µs\d+)?( 渲ms\d+\.\d+)?( 挡\d+)?$」
#   （R238 挡N 追加可选组；同款迁移纪律；物步µs/渲ms=秒窗均值时序读数不逐位断言；派µs=探针关=0 确定值；
#   行尾格式变更后 compare 模式须重采采集档——capture 模式重跑一次）。
#   R269 B 轨披露（§0.2 预声明迁移点）：行尾再追加「死µsN 警µsN 桶µsN 延µsN 释N 敌弹N
#   拒N 促N」八键段（物理残差逐桶归因+team-1 观测面+模式状态键），剥离正则再放宽为
#   「 …( 挡\d+)?( 死µs\d+)?( 警µs\d+)?( 桶µs\d+)?( 延µs\d+)?( 释\d+)?( 敌弹\d+)?( 拒\d+)?( 促\d+)?$」
#   （同款迁移纪律；MENU 冻结同步窗内 死µs/警µs/桶µs/延µs/释N/敌弹N/拒N=0 确定值；
#   促0=保帧模式关态确定值；行尾格式变更后 compare 模式须重采采集档）。
#   R271 P 轨披露（§0.2 预声明迁移点，设计 §3.1-键落位）：行尾再追加「步µsN 隙µsN
#   延早µsN 延渲µsN 延峰µsN 加N 摘N 绘µsN 渲帧N 呈帧N 渲峰msN.N」十一键段（步闭环
#   四分账+三哨兵+树进出计数+自绘计时+渲帧面——追加在 促N 之后、尖峰段之前），剥离
#   正则再放宽为十一可选组（同款迁移纪律；MENU 冻结窗内 延渲µs/绘µs=0 确定值，
#   步µs/隙µs/延早µs/延峰µs=时序读数不逐位断言，加N/摘N=同步窗 add/remove 计数，
#   渲帧N/呈帧N/渲峰ms=时序读数；对拍断言仍=去尾后与改造前行逐位相等——R271 键
#   全部在剥离区内，基线档免重采）。
#   既证明「旧行全部既有子串（至 补%d）逐位不变」，又证明「仅行尾多 裁%d」。
#   采集档为 Windows 控制台重定向产物（CRLF）——读档剥 \r（重定向痕迹非行内容）。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const NOW_L1 := 65000                          # 同分钟三采样（[1:05 …] 戳逐位可比）

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: Node = null


func run(p_tree: SceneTree, p_mode: String, p_before_path: String) -> void:
	tree = p_tree
	seed(42)
	_boot_game_loop()
	_gl.state = GameConst.GameStatus.MENU      # 冻结环境（r212 同构）
	await _wait_glyph_ready()                   # 位图就绪稳定门（补N/位图R 运行间抖动消除）
	var lines: Array[String] = []
	PerfGovernor.tier_override = 2              # 「触发步」注入（改造前后同序列）
	PerfGovernor.mode_override = 0
	lines.append(_norm(DebugStats._diag_format_line(_gl, NOW_L1)))
	_gl._physics_process(1.0 / 60.0)            # 触发步（改造前=等价最近序列）
	lines.append(_norm(DebugStats._diag_format_line(_gl, NOW_L1 + 1)))
	lines.append(_norm(DebugStats._diag_format_line(_gl, NOW_L1 + 2)))
	PerfGovernor.tier_override = -1
	PerfGovernor.mode_override = -1
	_teardown()
	for i in lines.size():
		print("L%d|%s" % [i + 1, lines[i]])
	if p_mode == "compare":
		_compare_with_before(lines, p_before_path)
	else:
		print("MODE=capture（本轮为采集；对拍请以 compare=<采集档> 重跑）")
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)
	print("验收汇总：%d/%d 通过" % [_pass, _pass + _fail])


func fail_count() -> int:
	return _fail


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("  PASS | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s（%s）" % [p_name, p_detail])
		print("  FAIL | %s（%s）" % [p_name, p_detail])


func _boot_game_loop() -> void:
	var main: Node = load(MAIN_SCENE).instantiate()
	tree.root.add_child(main)
	_gl = tree.root.get_node_or_null("Main")
	if _gl == null:
		for c in tree.root.get_children():
			if c != null and c.has_method("diag_counts"):
				_gl = c
				break


func _wait_glyph_ready() -> void:
	# PopupGlyphAtlas 菜单期补烤完成门（就绪后位图R=1、补N 差分归零——三采样窗口内
	# 不再发生补烤，消除跨轮时点抖动；上限 240 帧防挂死）
	for i in range(240):
		if PopupGlyphAtlas.ready():
			break
		await tree.process_frame
	await tree.process_frame
	await tree.process_frame


func _norm(p_line: String) -> String:
	# fps/余 掩码（引擎全局读数，两轮同规——见文件头注）
	var out := p_line
	var rx_fps := RegEx.new()
	rx_fps.compile("fps\\d+")
	out = rx_fps.sub(out, "fpsF", true)
	var rx_left := RegEx.new()
	rx_left.compile("余\\d+ms")
	out = rx_left.sub(out, "余Fms", true)
	return out


func _compare_with_before(p_after: Array[String], p_before_path: String) -> void:
	print("── 对拍（before=%s） ──" % p_before_path)
	var f := FileAccess.open(p_before_path, FileAccess.READ)
	if f == null:
		_check("采集档可读", false, "path=%s" % p_before_path)
		return
	var before: Array[String] = []
	while not f.eof_reached():
		var row := f.get_line().replace("\r", "").strip_edges()
		if row.begins_with("L1|") or row.begins_with("L2|") or row.begins_with("L3|"):
			before.append(row.substr(3))
	f.close()
	_check("采集档三行齐全（L1/L2/L3）", before.size() == 3, "size=%d" % before.size())
	if before.size() != 3:
		return
	var rx := RegEx.new()
	# R233 T1 迁移（R232 结µs 先例）：行尾再追加「插µsN」段——正则放宽为
	# 「 裁\d+( 快\d+)?( 结µs\d+)?( 插µs\d+)?$」（头注披露同步；插值层未实施期
	# ip_write_us_total 恒 0 → 插µs0 确定值）。
	# R233 修轮再迁移（HIGH-1/MED-3）：行尾再追加「插模拟µsN」「派deferredN 派dropN」
	# 段——正则再放宽（头注披露同步；插模拟µs=时序读数，MENU 冻结同步窗=0；
	# 派deferred0 派drop0=MENU 无战斗派发确定值）。
	# R235 搭车③再迁移：行尾再追加「物步µsN 派µsN 渲msN.N」段——正则再放宽（头注披露
	# 同步；物步µs/渲ms=秒窗均值时序读数不逐位断言；派µs=MENU 探针关=0 确定值）。
	# R269 B 轨再迁移（§0.2 预声明迁移点）：行尾再追加「死µsN 警µsN 桶µsN 延µsN 释N
	# 敌弹N 拒N 促N」八键段（追加在 挡N 之后、尖峰段之前）——正则再放宽为八可选组
	#（头注披露同步；MENU 冻结同步窗内 死µs/警µs/桶µs/延µs/释N/敌弹N/拒N=0 确定值；
	# 促0=保帧模式关态确定值）。
	# R271 P 轨再迁移（§0.2 预声明迁移点，tests/ 根本文件 :152）：行尾再追加十一键段
	# 「步µsN 隙µsN 延早µsN 延渲µsN 延峰µsN 加N 摘N 绘µsN 渲帧N 呈帧N 渲峰msN.N」
	#（追加在 促N 之后、尖峰段之前）——正则再放宽为十一可选组（头注披露同步；时序
	# 读数不逐位断言、剥离区内基线档免重采）。
	# R286 诊断收口再迁移（R285 p0c 移交项收口）：行尾再追加九键段「命µsN 提µsN
	# 灭µsN 回µsN ipµsN 段和µsN 弹段µsN 网段µsN 敌段µsN」（R285 四分键+ip 桶上墙 +
	# 段窗和四键；追加在 渲峰ms 之后、尖峰段之前）——正则再放宽为九可选组（同款
	# 迁移纪律；MENU 冻结同步窗内五桶/段窗全 0 确定值、剥离区内基线档免重采）。
	# R287 深载分键再迁移：行尾再追加六键段「跳段µsN 玩段µsN 特段µsN UI段µsN 他段µsN
	# 派段µsN」（popup/player/fx/ui/other/dispatch 六段秒窗分键；追加在 敌段µs 之后、
	# 尖峰段之前）——正则再放宽为 +6 可选组（同款迁移纪律第 10 次；MENU 冻结同步窗内
	# 六段窗全 0 确定值、剥离区内基线档免重采）。
	# R289 深载三刀再迁移：行尾再追加十三键段「武1µsN..武9µsN 副武µsN 深N 武跳N 弹拒N」
	#（逐武器族秒窗和 + 深载闩/跳步/弹拒自证键；追加在 派段µs 之后、尖峰段之前）——
	# 正则再放宽为 +13 可选组（同款迁移纪律第 11 次；MENU 冻结同步窗内十武桶全 0、
	# 深/武跳/弹拒=0 确定值、剥离区内基线档免重采）。
	# R293 刀C 再迁移：行尾再追加「drawcallsN」键（Performance.RENDER_TOTAL_DRAW_
	# CALLS_IN_FRAME 末帧直读——渲染合批刀生效真机自证键；追加在 弹拒N 之后、尖峰段
	# 之前）——正则再放宽为 +1 可选组（同款迁移纪律第 12 次；headless 无渲染恒 0
	# 确定值，剥离区内基线档免重采）。
	rx.compile(" 裁\\d+( 快\\d+)?( 结µs\\d+)?( 插µs\\d+)?( 插模拟µs\\d+)?( 派deferred\\d+)?( 派drop\\d+)?( 物步µs\\d+)?( 派µs\\d+)?( 渲ms\\d+\\.\\d+)?( 挡\\d+)?( 死µs\\d+)?( 警µs\\d+)?( 桶µs\\d+)?( 延µs\\d+)?( 释\\d+)?( 敌弹\\d+)?( 拒\\d+)?( 促\\d+)?( 步µs\\d+)?( 隙µs\\d+)?( 延早µs\\d+)?( 延渲µs\\d+)?( 延峰µs\\d+)?( 加\\d+)?( 摘\\d+)?( 绘µs\\d+)?( 渲帧\\d+)?( 呈帧\\d+)?( 渲峰ms\\d+\\.\\d+)?( 命µs\\d+)?( 提µs\\d+)?( 灭µs\\d+)?( 回µs\\d+)?( ipµs\\d+)?( 段和µs\\d+)?( 弹段µs\\d+)?( 网段µs\\d+)?( 敌段µs\\d+)?( 跳段µs\\d+)?( 玩段µs\\d+)?( 特段µs\\d+)?( UI段µs\\d+)?( 他段µs\\d+)?( 派段µs\\d+)?( 武1µs\\d+)?( 武2µs\\d+)?( 武3µs\\d+)?( 武4µs\\d+)?( 武5µs\\d+)?( 武6µs\\d+)?( 武7µs\\d+)?( 武8µs\\d+)?( 武9µs\\d+)?( 副武µs\\d+)?( 深\\d+)?( 武跳\\d+)?( 弹拒\\d+)?( drawcalls\\d+)?$")
	for i in 3:
		var m := rx.search(p_after[i])
		_check("L%d 行尾恰一个「 裁N」段" % [i + 1], m != null, "tail=%s" % p_after[i].right(32))
		if m == null:
			continue
		var stripped := p_after[i].substr(0, m.get_start())
		var pos := _first_diff(before[i], stripped)
		_check("L%d 既有子串逐位不变（去 裁N 后 == 改造前行）" % [i + 1],
			pos < 0,
			"first_diff@%d（before.len=%d after.len=%d）\n    before=%s\n    after =%s" % [pos, before[i].length(), stripped.length(), before[i], stripped])


func _first_diff(p_a: String, p_b: String) -> int:
	# 首个不一致字符下标（-1=全等）；诊断用
	var n: int = mini(p_a.length(), p_b.length())
	for i in n:
		if p_a.unicode_at(i) != p_b.unicode_at(i):
			return i
	if p_a.length() != p_b.length():
		return n
	return -1


func _teardown() -> void:
	tree.paused = false
	RunSave.clear()
	if _gl != null:
		_gl.free()
		_gl = null

# tests/runner/r252_menu_perf_cases.gd
# R252 需求④菜单性能 + 图鉴「祝福」页签 用例体（由 test_r252_menu_perf.gd 入口在
# autoload 就绪后运行时加载编译；两段式入口照 pkg0 模式）。
# 覆盖（设计 §4.5 M0-M7 + P2/P3 直测）：
#   M0 基线对比（修前/修后探针 JSON 留档对比）/ M1 首建上限（贴图预热排空后 ≤50ms、
#   二建 ≤15ms、选人 ≤15ms）/ M2 六处 rebuild 无双布局（同帧行数==目标行数，动态取
#   registry 与扩容解耦）/ M3 委托臂成品缓存（同 id 直调第二次 ≤1ms）/ M4 双预热预算
#   （BUDGET_US==4000 + game_loop 源码锚 + 两泵单帧合计 ≤8000µs）/ M5 写盘收口
#   （大厅面板批落盘 + 设置面板 closed 联动 + 面板外直调立即落盘 + EXIT_TREE 收口）/
#   M6 页签无条件重建回归（防 no-op 守卫复发；P2 缓存不得影响此语义；R254-QA1 增
#   M6e-h 缓存生命周期：六面板互切复用/闲时泵边界/失效双态销毁/_panel_list null 守卫）/ M7 页签改名
#   （5 枚含「祝福」不含「词条」；祝福页行数==traits；锁定态文案含「开局祝福」）。
#   P2 测量缓存（二次重建零新增键）/ P3 boot 建队含图鉴域 op:7（weapon 项==武器数）。
# 探针 JSON：tests/runner/_probe_r252_menu_perf_pre.json（修前）/_post.json（修后），
# 由 probe_r252_menu_perf.gd 生成后改名留档——缺失时 M0 组 FAIL（环境不完整披露）。
extends RefCounted

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _menu = null                              # MenuScreen（duck 类型）

const PRE_JSON := "res://tests/runner/_probe_r252_menu_perf_pre.json"
const POST_JSON := "res://tests/runner/_probe_r252_menu_perf_post.json"
const GL_SRC := "res://scripts/loop/game_loop.gd"
const CD_SRC := "res://scripts/cards/card_desc_prewarm.gd"
const MS_SRC := "res://scripts/ui/menu_screen.gd"
const MENU_SRC := "res://scripts/ui/menu_screen.gd"


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	_test_m7_blessing_tab()
	_test_m2_no_double_layout()
	_test_m1_first_build_budget()
	_test_m3_delegate_cache()
	_test_m6_rebuild_semantics()
	_test_m6_cache_lifecycle()               # R254-QA1：面板互切/闲时泵/失效双态
	_test_p2_measure_cache()
	_test_p3_codex_prewarm_queue()
	_test_m4_budgets()
	_test_m5_persist_defer()
	_test_m0_probe_baseline()
	_summary()


func fail_count() -> int:
	return _fail


# ── 支撑 ──────────────────────────────────────────────────────────
func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("PASS | %s" % p_name)
	else:
		_fail += 1
		_failures.append(p_name)
		print("FAIL | %s | %s" % [p_name, p_detail])


func _summary() -> void:
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  失败项：%s" % f)


func _t(p_cb: Callable) -> int:
	var us0 := int(Time.get_ticks_usec())
	p_cb.call()
	return int(Time.get_ticks_usec()) - us0


func _mk_gl(p_name: String):
	# GameLoop 实例化（-s 模式 cases 运行时编译——autoload 全局名已就绪；rxn_codex 同式）
	var gl = GameLoop.new()
	gl.name = p_name
	tree.get_root().add_child(gl)
	gl.set_physics_process(false)
	return gl


func _codex_trait_rows(p_registry) -> int:
	# R262b L14 口径：祝福页行源滤阈值型镜像词条（TH_* 永不可抽不进行）——与
	# menu_screen._make_codex_entry_row 行源同公式，73−7=66
	var n: int = 0
	for tid_v: Variant in p_registry.traits.keys():
		var td = p_registry.get_trait(tid_v)
		if td != null and not bool(td.params.get("threshold_only", false)):
			n += 1
	return n


func _live_rows(p_list: Node) -> Array:
	# queue_free 已挂未销毁的行不计（rxn_codex _live_rows 同口径）
	var out: Array = []
	for c in p_list.get_children():
		if not c.is_queued_for_deletion():
			out.append(c)
	return out


func _live_count(p_list: Node) -> int:
	return _live_rows(p_list).size()


func _drain_prewarm(gl) -> void:
	# 排空贴图预热队列（M1 口径=「贴图预热完成后」的首建；dwell 拉满绕 boss 3s 挂机门）
	gl.set("_menu_dwell_s", 99.0)
	var guard := 0
	while gl._tex_prewarm_queue.size() > 0 and guard < 800:
		gl._process_tex_prewarm(40000)
		guard += 1


func _read_json(p_path: String) -> Dictionary:
	if not FileAccess.file_exists(p_path):
		return {}
	var f := FileAccess.open(p_path, FileAccess.READ)
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	return parsed if parsed is Dictionary else {}


func _disk_crystals() -> int:
	var cfg := ConfigFile.new()
	cfg.load(Meta.save_path())
	return int(cfg.get_value("meta", "crystals", -2147483648))


func _disk_settings() -> Dictionary:
	var cfg := ConfigFile.new()
	cfg.load(Meta.save_path())
	var v: Variant = cfg.get_value("settings", "values", {})
	return v if v is Dictionary else {}


func _flush_meta() -> void:
	# 强制结清落盘（begin+end 对——end 在深度归零时 _check_achievements+_save）
	Meta.begin_persist_defer()
	Meta.end_persist_defer()


# ── M7 页签改名（需求②：图鉴「词条」→「祝福」） ──────────────────
func _test_m7_blessing_tab() -> void:
	print("── M7 页签改名：祝福（原词条）/ 行数 / 锁定态文案 ──")
	var gl = _mk_gl("GameLoopR252M7")
	_menu = gl.menu_screen
	var tab_keys: Array = _menu._codex_tabs.keys()
	_check("M7a 图鉴页签恰 5 枚含「祝福」不含「词条」（怪物/武器/祝福/反应/遗物）",
		tab_keys.size() == 5 and tab_keys.has("怪物") and tab_keys.has("武器")
		and tab_keys.has("祝福") and tab_keys.has("反应") and tab_keys.has("遗物")
		and not tab_keys.has("词条"),
		str(tab_keys))
	_menu._on_lobby_pressed("codex")
	_menu._on_codex_tab("祝福")
	var traits_rows: int = _codex_trait_rows(_menu.registry)
	_check("M7b 「祝福」页行数 == 全量−阈值型（%d，R262b L14 滤 TH_*）" % traits_rows,
		_live_count(_menu._panel_list) == traits_rows,
		"live=%d" % _live_count(_menu._panel_list))
	# 锁定态文案（清 codex_traits → 全行锁定；行 children 序：icon/name/desc）
	var traits0: Dictionary = Meta.codex_traits.duplicate()
	Meta.codex_traits.clear()
	_menu._invalidate_codex_cache()          # R254-1 页缓存：解锁态变=行文案源变，失效再切
	_menu._on_codex_tab("祝福")
	var desc_text := ""
	var rows := _live_rows(_menu._panel_list)
	if rows.size() > 0 and rows[0].get_child_count() >= 3:
		desc_text = (rows[0].get_child(2) as Label).text
	_check("M7c 锁定态文案含「开局祝福」", desc_text.contains("开局祝福"),
		"txt=%s" % desc_text)
	Meta.codex_traits = traits0                # 还原（var 赋值不落盘——内存态自洽）
	_menu._on_panel_close()
	gl.free()
	_menu = null


# ── M2 无双布局（P1 六处先离树再释放） ────────────────────────────
func _test_m2_no_double_layout() -> void:
	print("── M2 六处 rebuild 同帧行数 == 目标行数（动态取 registry） ──")
	var gl = _mk_gl("GameLoopR252M2")
	_menu = gl.menu_screen
	var traits_n: int = _codex_trait_rows(_menu.registry)   # R262b L14：滤 TH_* 口径
	var relics_n: int = _menu.registry.relics.size()
	var enemies_n: int = _menu.registry.enemies.size()
	var weapons_n: int = _menu.registry.weapons.size()
	var rxn_n: int = GameConst.ReactionType.size()
	_menu._on_lobby_pressed("codex")
	_check("M2a 怪物页 rebuild 后同帧行数 == registry.enemies（%d）" % enemies_n,
		_menu._panel_list.get_child_count() == enemies_n,
		"kids=%d" % _menu._panel_list.get_child_count())
	_menu._on_lobby_pressed("codex")
	_check("M2a' 怪物页二次重建不翻倍（P1 离树生效——修前基线 29→58）",
		_menu._panel_list.get_child_count() == enemies_n,
		"kids=%d" % _menu._panel_list.get_child_count())
	for tab_def in [["武器", weapons_n], ["祝福", traits_n], ["遗物", relics_n]]:
		_menu._on_codex_tab(String(tab_def[0]))
		_check("M2b %s页 rebuild 后同帧行数 == %d" % [String(tab_def[0]), int(tab_def[1])],
			_menu._panel_list.get_child_count() == int(tab_def[1]),
			"kids=%d" % _menu._panel_list.get_child_count())
		_menu._on_codex_tab(String(tab_def[0]))
		_check("M2b' %s页二次重建不翻倍" % String(tab_def[0]),
			_menu._panel_list.get_child_count() == int(tab_def[1]),
			"kids=%d" % _menu._panel_list.get_child_count())
	_menu._on_codex_tab("反应")
	_check("M2c 反应页行数 == 枚举全键（+1 冰草留白标注行至多）",
		_menu._panel_list.get_child_count() == rxn_n
		or _menu._panel_list.get_child_count() == rxn_n + 1,
		"kids=%d" % _menu._panel_list.get_child_count())
	_menu._on_codex_tab("反应")
	_check("M2c' 反应页二次重建不翻倍",
		_menu._panel_list.get_child_count() == rxn_n
		or _menu._panel_list.get_child_count() == rxn_n + 1,
		"kids=%d" % _menu._panel_list.get_child_count())
	# 其余三处 rebuild：成就（分页页容量 24）/ 记录（6+图数+1）/ 升级（1+8轨+1）/ 选人
	_menu._on_lobby_pressed("ach")
	var ach_rows: Array = _menu._ach_filtered()
	_check("M2d 成就页 rebuild 后行数 == min(全量, 页容量24)（%d/%d）" % [ach_rows.size(), 24],
		_menu._panel_list.get_child_count() == mini(ach_rows.size(), 24),
		"kids=%d filtered=%d" % [_menu._panel_list.get_child_count(), ach_rows.size()])
	_menu._on_lobby_pressed("ach")
	_check("M2d' 成就页二次重建不翻倍",
		_menu._panel_list.get_child_count() == mini(ach_rows.size(), 24),
		"kids=%d" % _menu._panel_list.get_child_count())
	var records_expect := 6 + MapTable.count() + 1
	_menu._on_lobby_pressed("records")
	_check("M2e 记录页 rebuild 后行数 == 6+图数+1（%d）" % records_expect,
		_menu._panel_list.get_child_count() == records_expect,
		"kids=%d" % _menu._panel_list.get_child_count())
	_menu._on_lobby_pressed("records")
	_check("M2e' 记录页二次重建不翻倍",
		_menu._panel_list.get_child_count() == records_expect,
		"kids=%d" % _menu._panel_list.get_child_count())
	var upgrades_expect := 1 + 1 + Meta.UPGRADES.size() + 1   # R263：+1 星尘行（结晶头下）
	_menu._on_lobby_pressed("upgrade")
	_check("M2f 升级页 rebuild 后行数 == 1 表头+1 星尘+轨数+1 尾注（%d）" % upgrades_expect,
		_menu._panel_list.get_child_count() == upgrades_expect,
		"kids=%d" % _menu._panel_list.get_child_count())
	_menu._on_lobby_pressed("upgrade")
	_check("M2f' 升级页二次重建不翻倍",
		_menu._panel_list.get_child_count() == upgrades_expect,
		"kids=%d" % _menu._panel_list.get_child_count())
	var char_n: int = CharacterTable.count()
	_menu._on_lobby_pressed("char")
	_check("M2g 选人页 rebuild 后行数 == CharacterTable.count()（%d）" % char_n,
		_menu._panel_list.get_child_count() == char_n,
		"kids=%d" % _menu._panel_list.get_child_count())
	_menu._on_lobby_pressed("char")
	_check("M2g' 选人页二次重建不翻倍",
		_menu._panel_list.get_child_count() == char_n,
		"kids=%d" % _menu._panel_list.get_child_count())
	# 选关与每日（行数动态——只锁不翻倍语义）
	_menu._open_map_select()
	var map_kids: int = _menu._panel_list.get_child_count()
	_menu._open_map_select()
	_check("M2h 选关页二次重建不翻倍（难度行+地图行）",
		_menu._panel_list.get_child_count() == map_kids,
		"kids=%d→%d" % [map_kids, _menu._panel_list.get_child_count()])
	_menu._on_lobby_pressed("daily")
	var daily_kids: int = _menu._panel_list.get_child_count()
	_menu._on_lobby_pressed("daily")
	_check("M2i 每日页二次重建不翻倍",
		_menu._panel_list.get_child_count() == daily_kids,
		"kids=%d→%d" % [daily_kids, _menu._panel_list.get_child_count()])
	_menu._on_panel_close()
	gl.free()
	_menu = null


# ── M1 首建上限（贴图预热排空后；P1+P2+P3/P4 合力） ───────────────
# 上限口径（§4.5-M1 分档回调条款落地——修后复跑实测披露，禁止虚改测量）：
#   设计主值 50/15/15 在「反应页首建 81.8ms / 祝福二建 37.4ms / 遗物二建 17.5ms /
#   选人 21.9ms」处不可达——反应页主嫌是 _make_codex_reaction_row 预览字型排版
#  （P2 测量缓存不覆盖该行构造，P1-P7 无对应刀，设计把反应页归因到 _make_codex_row
#   测量系误判）；二建超标=行构建固有成本（~0.5ms/行，分帧建行在设计缓办项）。
#   回调值 = 实测 ×1.2 余量取整，全表随 notes 披露（§4.5.1 附录）。
# D1（QA 第 1 轮）：headless 时序噪声下单发 ×1.2 余量不足——复核 F1 三次实跑
#   FAIL 9→2→2 且失败项轮换（怪物二建 25739µs vs 档 15000、选人 29634µs vs 档
#   25000、反应首建 81.8~93.8ms 对 100ms 档余量仅 ~6%）。改统计口径：同用例采样
#   5 次取中位数比档——测量降噪而非虚改测量、不放宽预算常量（QA 丙-1 统一口径）；
#   根治靠反应页排版缓存刀落地后回归设计主值（§8 缓办）。
const FIRST_BUDGET := {
	"怪物": 50000, "武器": 50000, "遗物": 50000, "祝福": 65000, "反应": 100000,
}
const SECOND_BUDGET := {
	"怪物": 15000, "武器": 15000, "遗物": 25000, "祝福": 45000, "反应": 40000,
}
const M1_SAMPLE_RUNS := 5                       # D1：中位数采样次数（奇数取正中位）

func _t_median(p_cb: Callable, p_runs: int = M1_SAMPLE_RUNS) -> int:
	# D1：同口径采样 p_runs 次取中位数（sort 后取正中位）——页签重建是无条件全量
	# 语义（M6 承载面），重复调用即重复测量，逐次同口径可比
	var samples: Array[int] = []
	for i in range(p_runs):
		samples.append(_t(p_cb))
	samples.sort()
	return samples[p_runs / 2]

func _test_m1_first_build_budget() -> void:
	print("── M1 首建上限（headless 预热排空口径；5 次中位数比档，D1 测量降噪） ──")
	var gl = _mk_gl("GameLoopR252M1")
	_menu = gl.menu_screen
	_drain_prewarm(gl)
	_check("M1- 预热队列已排空（P3 建队 + 泵消化全链路）",
		gl._tex_prewarm_queue.size() == 0,
		"left=%d" % gl._tex_prewarm_queue.size())
	var us_open: int = _t_median(func() -> void: _menu._on_lobby_pressed("codex"))
	_check("M1a 怪物页首建 ≤50ms（5 次中位数；设计主值）", us_open <= 50000, "med=%d" % us_open)
	for tab in ["武器", "祝福", "反应", "遗物", "怪物"]:
		var us_first: int = _t_median(func() -> void: _menu._on_codex_tab(tab))
		_check("M1b %s页首建 ≤%dµs（5 次中位数·分档）" % [tab, int(FIRST_BUDGET[tab])],
			us_first <= int(FIRST_BUDGET[tab]), "med=%d" % us_first)
		var us_second: int = _t_median(func() -> void: _menu._on_codex_tab(tab))
		_check("M1c %s页二建 ≤%dµs（5 次中位数·分档）" % [tab, int(SECOND_BUDGET[tab])],
			us_second <= int(SECOND_BUDGET[tab]), "med=%d" % us_second)
	var us_char: int = _t_median(func() -> void: _menu._on_lobby_pressed("char"))
	_check("M1d 选人页 ≤25ms（5 次中位数；修前 257ms 冷生成已由 P3 预热消除，残=行构建）",
		us_char <= 25000, "med=%d" % us_char)
	var us_map: int = _t_median(func() -> void: _menu._open_map_select())
	_check("M1e 选关面板 ≤20ms（5 次中位数；r245_diff_star 重建面同源）", us_map <= 20000, "med=%d" % us_map)
	_menu._on_panel_close()
	gl.free()
	_menu = null


# ── M3 委托臂成品缓存（P4-② 直调口径） ───────────────────────────
func _test_m3_delegate_cache() -> void:
	print("── M3 委托臂成品缓存：同武器 id 第二次直调 _delegate_weapon_icon ≤1ms ──")
	var gl = _mk_gl("GameLoopR252M3")
	_menu = gl.menu_screen
	_drain_prewarm(gl)                          # 武器页贴图经队列已生成（成品缓存已写）
	var tf_script: GDScript = load("res://scripts/ui/texture_factory.gd")
	var wid := StringName("W11_spirit_sword")
	tf_script._delegate_weapon_icon(wid, false)     # 首调（缓存命中路径预热）
	var us: int = _t(func() -> void:
		tf_script._delegate_weapon_icon(wid, false))
	_check("M3a 同 id 第二次直调 ≤1ms（P4-② 成品缓存命中）", us <= 1000, "us=%d" % us)
	tf_script._delegate_weapon_icon(wid, true)      # t2 首调（预热队列只入队基图——t2 成品冷生成在此完成）
	var us_t2: int = _t(func() -> void:
		tf_script._delegate_weapon_icon(wid, true))
	_check("M3b t2 变体同式第二次直调 ≤1ms", us_t2 <= 1000, "us=%d" % us_t2)
	var tex: ImageTexture = tf_script._delegate_weapon_icon(wid, false)
	_check("M3c 成品缓存返回同实例（非重生成）",
		tex == tf_script._delegate_weapon_icon(wid, false) and tex != null)
	# 未委托 id：null 缓存防重探测（同 ≤1ms）
	var us_null: int = _t(func() -> void:
		tf_script._delegate_weapon_icon(StringName("W1_pistol"), false))
	tf_script._delegate_weapon_icon(StringName("W1_pistol"), false)
	var us_null2: int = _t(func() -> void:
		tf_script._delegate_weapon_icon(StringName("W1_pistol"), false))
	_check("M3d 未委托 id null 缓存（第二次直调 ≤1ms 防反复探测）", us_null2 <= 1000,
		"first=%d second=%d" % [us_null, us_null2])
	gl.free()
	_menu = null


# ── M6 页签无条件重建回归（防 no-op 守卫复发） ────────────────────
func _test_m6_rebuild_semantics() -> void:
	print("── M6 同页签重复 _on_codex_tab 必须刷新行内容（rxn_codex :395-402 语义承载） ──")
	var gl = _mk_gl("GameLoopR252M6")
	_menu = gl.menu_screen
	_menu._on_lobby_pressed("codex")
	_menu._on_codex_tab("反应")
	var rt: Dictionary = GameConfig.balance.reaction_table
	var coef0: float = float(rt["RXN_FIR_ICE"]["coef"])
	rt["RXN_FIR_ICE"]["coef"] = 3.5
	_menu._on_codex_tab("武器")                   # 切走
	_menu._invalidate_codex_cache()              # R254-1 页级行缓存：改表=行文案源变，先失效
	_menu._on_codex_tab("反应")                   # 失效后重切必重建读新表（no-op 守卫仍破此断言）
	var mult_l: Label = null
	var rows := _live_rows(_menu._panel_list)
	if rows.size() >= GameConst.ReactionType.size():
		mult_l = rows[0].get_node_or_null("RxnMult") as Label
	_check("M6a 改表→失效缓存→重切页→文本刷新（coef=3.5 可见；no-op 守卫必破此断言）",
		mult_l != null and mult_l.text.contains("3.5"),
		"txt=%s" % (mult_l.text if mult_l != null else "-"))
	rt["RXN_FIR_ICE"]["coef"] = coef0             # 还原（防进程内表污染）
	_menu._on_codex_tab("武器")
	_menu._invalidate_codex_cache()              # R254-1：同上——还原后失效再断言复原
	_menu._on_codex_tab("反应")
	rows = _live_rows(_menu._panel_list)
	mult_l = null
	if rows.size() >= GameConst.ReactionType.size():
		mult_l = rows[0].get_node_or_null("RxnMult") as Label
	_check("M6b 还原 coef 后倍率复原（含 2.0 不含 3.5）",
		mult_l != null and mult_l.text.contains("2.0")
		and not mult_l.text.contains("3.5"),
		"txt=%s" % (mult_l.text if mult_l != null else "-"))
	# ── R254-1 页级行缓存契约 ──
	# M6c 切走再切回：缓存行实例复用（同一 Control 引用直挂——全量重建语义已废）
	var rows_r: Array = _live_rows(_menu._panel_list)
	var first_id: int = rows_r[0].get_instance_id() if not rows_r.is_empty() else 0
	_menu._on_codex_tab("武器")
	var rows_w: Array = _live_rows(_menu._panel_list)
	_check("M6c 切走后反应行离树（缓存 detach 不 free）",
		not rows_w.is_empty() and not rows_w[0].name.begins_with("RxnRow_"),
		"first=%s" % (rows_w[0].name if not rows_w.is_empty() else "-"))
	_menu._on_codex_tab("反应")
	var rows_r2: Array = _live_rows(_menu._panel_list)
	var first_id2: int = rows_r2[0].get_instance_id() if not rows_r2.is_empty() else 0
	_check("M6c 切回=缓存行实例复用（同 id 直挂，不重建）",
		first_id != 0 and first_id == first_id2,
		"id %d→%d" % [first_id, first_id2])
	# M6d 失效口：invalidate 后切页=新实例（旧行 free 前仍可查 id）
	_menu._invalidate_codex_cache()
	_menu._on_codex_tab("反应")
	var rows_r3: Array = _live_rows(_menu._panel_list)
	var first_id3: int = rows_r3[0].get_instance_id() if not rows_r3.is_empty() else 0
	_check("M6d 失效后重建=新行实例（缓存真失效非 no-op）",
		first_id3 != 0 and first_id3 != first_id2,
		"id %d→%d" % [first_id2, first_id3])
	_menu._on_panel_close()
	gl.free()
	_menu = null


# ── P2 行高测量缓存 ──────────────────────────────────────────────
func _test_p2_measure_cache() -> void:
	print("── P2 测量缓存：二次重建零新增测量键（全命中）+ 行为不变形 ──")
	var gl = _mk_gl("GameLoopR252P2")
	_menu = gl.menu_screen
	var ms_script: GDScript = load(MENU_SRC)
	_menu._on_lobby_pressed("codex")
	_menu._on_codex_tab("祝福")                   # 首建（73 行锁定句测量 1 次 + 已解锁 desc 各 1 次）
	var cache: Dictionary = ms_script._row_measure
	var size0: int = cache.size()
	_check("P2a 首建后缓存非空（测量已入缓存）", size0 > 0, "size=%d" % size0)
	_menu._on_codex_tab("祝福")                   # 重建——全部命中
	_check("P2b 二次重建零新增键（P2 缓存全命中，不改写同页重建语义）",
		ms_script._row_measure.size() == size0,
		"size=%d→%d" % [size0, ms_script._row_measure.size()])
	# 缓存键含描述全文：不同 desc 各自入键（跨页重复句命中同一键）
	_menu._on_codex_tab("遗物")
	_check("P2c 跨页建行走缓存（遗物页后键集不减——命中不删键）",
		ms_script._row_measure.size() >= size0,
		"size=%d" % ms_script._row_measure.size())
	_menu._on_panel_close()
	gl.free()
	_menu = null


# ── P3 boot 建队含图鉴域 ─────────────────────────────────────────
func _test_p3_codex_prewarm_queue() -> void:
	print("── P3 boot 建队：图鉴域 op:7 入队（weapon 项==武器数；boss 门语义不变） ──")
	var gl = _mk_gl("GameLoopR252P3")             # add_child 同步完成 _ready 建队（_process 未跑）
	var q: Array = gl._tex_prewarm_queue
	var op7 := 0
	var w7 := 0
	var s7 := 0
	for job in q:
		if int(job.get(&"op", 0)) == 7:
			op7 += 1
			if String(job.get(&"tex", &"")) == "weapon":
				w7 += 1
			elif String(job.get(&"tex", &"")) == "skill":
				s7 += 1
	_check("P3a boot 建队含图鉴域 op:7 项（非空）", op7 > 0, "op7=%d total=%d" % [op7, q.size()])
	_check("P3b op:7 weapon 项数 == registry 武器数（%d）" % gl.menu_screen.registry.weapons.size(),
		w7 == gl.menu_screen.registry.weapons.size(), "w7=%d" % w7)
	_check("P3c op:7 skill 项数 == CharacterTable.count()（%d）" % CharacterTable.count(),
		s7 == CharacterTable.count(), "s7=%d" % s7)
	# boss 门语义不变：dwell<3s 时队首若为 boss 项则整队暂停（op7 排 boss 段后同受门控
	# ——门前的字形/共享/常规敌段照常消化，队列停在 boss 首项）
	gl.set("_menu_dwell_s", 0.0)
	var op7_before := 0
	for job in gl._tex_prewarm_queue:
		if int(job.get(&"op", 0)) == 7:
			op7_before += 1
	gl._process_tex_prewarm(12000)
	var op7_after := 0
	for job in gl._tex_prewarm_queue:
		if int(job.get(&"op", 0)) == 7:
			op7_after += 1
	var head: Dictionary = gl._tex_prewarm_queue[0] if gl._tex_prewarm_queue.size() > 0 else {}
	var head_is_boss: bool = int(head.get(&"op", 0)) == 0 \
		and String(head.get(&"kind", &"")).begins_with("boss")
	_check("P3d 图鉴域项受 boss 挂机门同序约束（dwell=0 消化后 op:7 项零消耗且队列停在 boss 首项）",
		op7_after == op7_before and head_is_boss,
		"op7 %d→%d headBoss=%s" % [op7_before, op7_after, str(head_is_boss)])
	gl.free()
	_menu = null


# ── M4 双预热预算 ────────────────────────────────────────────────
func _test_m4_budgets() -> void:
	print("── M4 预算：BUDGET_US==4000 + game_loop 源码锚 + 两泵单帧合计 ≤8000µs ──")
	var cd_script: GDScript = load(CD_SRC)
	_check("M4a card_desc_prewarm.BUDGET_US == 4000", int(cd_script.BUDGET_US) == 4000,
		"v=%s" % str(cd_script.BUDGET_US))
	var gl_src := FileAccess.get_file_as_string(GL_SRC)
	var consume_at: int = gl_src.count("_process_tex_prewarm(4000)")
	_check("M4b game_loop MENU 态 tex 预热调用参数 == 4000（源码锚 count==1 且在 _process 内）",
		consume_at == 1
		and gl_src.find("_process_tex_prewarm(4000)") > gl_src.find("func _process(")
		and gl_src.find("_process_tex_prewarm(4000)") < gl_src.find("func _physics_process("),
		"count=%d" % consume_at)
	# 两泵单帧实测（轻项夹具——行为锁不锁成本；预算语义=停在项边界单项可超）
	var gl = _mk_gl("GameLoopR252M4")
	_drain_prewarm(gl)
	gl._tex_prewarm_queue.append({&"op": 4})
	gl._tex_prewarm_queue.append({&"op": 4})
	var t0 := int(Time.get_ticks_usec())
	gl._process_tex_prewarm(4000)
	var tex_us: int = int(Time.get_ticks_usec()) - t0
	cd_script.reset_for_tests()
	cd_script.ensure_built(gl.menu_screen.registry)
	t0 = int(Time.get_ticks_usec())
	cd_script.pump(4000)
	var cd_us: int = int(Time.get_ticks_usec()) - t0
	# R254 修轮#3b：MENU 态现为三泵并存（tex 4000 + carddesc 4000 + 图鉴行级泵 4000
	# =名目 12ms < 16.6ms）；图鉴泵实测分帧由 M6f 系钉（≤4ms/帧+行级原子）
	_check("M4c 三泵单帧合计 ≤12000µs（tex %d + carddesc %d + 图鉴泵名目 4000）" % [tex_us, cd_us],
		tex_us + cd_us + 4000 <= 12000, "sum=%d" % (tex_us + cd_us + 4000))
	# R262b S1 定谳残留值锁：图鉴泵预算此前是 menu_screen 内联字面量无锁（tex/carddesc
	# 已有 M4a/b 锁）——源码锚锁「< 4000」循环条件唯一且在 _process 内，调参即红
	var menu_src := FileAccess.get_file_as_string(MS_SRC)
	var codex_budget_at: int = menu_src.count("Time.get_ticks_usec() - t0 < 4000")
	_check("M4d 图鉴泵预算字面量 4000（menu_screen 源码锚 count==1 且在 _process 内）",
		codex_budget_at == 1
		and menu_src.find("Time.get_ticks_usec() - t0 < 4000") > menu_src.find("func _process("),
		"count=%d" % codex_budget_at)
	cd_script.reset_for_tests()                   # 清队复位（防跨用例泄漏）
	gl.free()
	_menu = null


# ── M5 点击路径写盘收口 ──────────────────────────────────────────
func _test_m5_persist_defer() -> void:
	print("── M5 写盘收口：面板作用域批落盘 / 设置 closed 联动 / 面板外立即落盘 ──")
	var gl = _mk_gl("GameLoopR252M5")
	_menu = gl.menu_screen
	_flush_meta()                                 # 起点结清（磁盘=内存）
	var crystals0: int = Meta.crystals
	var upgrades0: Dictionary = Meta.upgrades.duplicate()
	var base_disk: int = _disk_crystals()
	# —— 大厅详情面板包络：3 次 buy_upgrade 批内不落盘、close 统一落盘 ——
	Meta.upgrades.clear()
	Meta.crystals = 1000
	_menu._on_lobby_pressed("upgrade")            # R252D P6：begin
	var bought := 0
	for i in range(3):
		if Meta.buy_upgrade(&"life"):
			bought += 1
	var mid_disk: int = _disk_crystals()
	_check("M5a 面板作用域内 3 次 buy_upgrade 不落盘（磁盘 crystals==旧值）",
		mid_disk == base_disk and bought == 3 and Meta.crystals == 1000 - 120,
		"bought=%d disk=%d base=%d mem=%d" % [bought, mid_disk, base_disk, Meta.crystals])
	_menu._on_panel_close()                       # R252D P6：end 统一落盘
	var end_disk: int = _disk_crystals()
	_check("M5b _on_panel_close 后统一落盘（磁盘==880==内存；1000 起点扣 life 三级 120）",
		end_disk == Meta.crystals and end_disk == 1000 - 120,
		"disk=%d mem=%d base=%d" % [end_disk, Meta.crystals, base_disk])
	# —— 设置面板作用域：closed 信号联动 end ——
	var sfx0: Variant = Meta.settings("sfx_volume")
	gl._on_settings_open_defer()                  # begin（is_open 守卫）
	Meta.set_setting("sfx_volume", 0.77)
	var mid_set: Dictionary = _disk_settings()
	_check("M5c 设置滑条写口即时应用、落盘被 defer 抑制",
		absf(float(Meta.settings("sfx_volume")) - 0.77) < 0.001
		and (not mid_set.has("sfx_volume")
			or absf(float(mid_set.get("sfx_volume", 0.0)) - 0.77) >= 0.001),
		"mem=%s disk=%s" % [str(Meta.settings("sfx_volume")), str(mid_set.get("sfx_volume", "-"))])
	gl.settings_panel.close()                     # closed → GameLoop 接线 end → 落盘
	var end_set: Dictionary = _disk_settings()
	_check("M5d 设置面板 close 后 closed 信号联动 end 落盘",
		end_set.has("sfx_volume")
		and absf(float(end_set.get("sfx_volume", 0.0)) - 0.77) < 0.001,
		"disk=%s" % str(end_set.get("sfx_volume", "-")))
	# —— 面板外直调写口：仍立即落盘（r211 写即存语义回归） ——
	Meta.set_setting("sfx_volume", 0.88)
	var out_set: Dictionary = _disk_settings()
	_check("M5e 面板外直调 set_setting 仍立即落盘（深度 0 路径零迁移）",
		out_set.has("sfx_volume")
		and absf(float(out_set.get("sfx_volume", 0.0)) - 0.88) < 0.001,
		"disk=%s" % str(out_set.get("sfx_volume", "-")))
	# —— EXIT_TREE 收口：带开包络销毁 → 强制结清（抑制态不带出） ——
	_menu._on_lobby_pressed("codex")              # begin（不 close）
	Meta.crystals = 555
	gl.free()                                     # NOTIFICATION_EXIT_TREE → _panel_end_defer
	var exit_disk: int = _disk_crystals()
	_check("M5f 带开包络 free 触发 EXIT_TREE 收口落盘（crystals==555）",
		exit_disk == 555, "disk=%d" % exit_disk)
	# —— 还原（前后档自洽） ——
	Meta.crystals = crystals0
	Meta.upgrades = upgrades0
	if sfx0 == null:
		Meta.set_setting("sfx_volume", 0.8)       # 默认档还原（SETTINGS_DEFAULTS 同值）
	else:
		Meta.set_setting("sfx_volume", float(sfx0))
	_flush_meta()
	_menu = null


# ── M0 基线对比（探针 JSON 留档；修前 _pre / 修后 _post） ─────────
func _test_m0_probe_baseline() -> void:
	print("── M0 基线对比：修前/修后探针 JSON（handler 耗时 / 同帧行数 / 委托臂） ──")
	var pre: Dictionary = _read_json(PRE_JSON)
	var post: Dictionary = _read_json(POST_JSON)
	_check("M0- 探针留档齐备（修前 _pre + 修后 _post）",
		not pre.is_empty() and not post.is_empty(),
		"pre=%s post=%s" % [str(not pre.is_empty()), str(not post.is_empty())])
	if pre.is_empty() or post.is_empty():
		return
	var pre_us: Dictionary = pre.get("handlers_us", {})
	var post_us: Dictionary = post.get("handlers_us", {})
	var pre_kids: Dictionary = pre.get("children_same_frame", {})
	var post_kids: Dictionary = post.get("children_same_frame", {})
	# ① 同帧双布局消除：修前二建后 child_count 翻倍（29→58），修后 == 单轮行数
	_check("M0a 修前二建同帧行数翻倍（29→58 双布局证据）",
		int(pre_kids.get("codex_open_second", 0)) == 2 * int(pre_kids.get("codex_open_first", -1)),
		"pre first=%s second=%s" % [str(pre_kids.get("codex_open_first", "-")),
			str(pre_kids.get("codex_open_second", "-"))])
	_check("M0b 修后二建同帧行数 == 单轮（怪物 %s）" % str(post.get("registry", {}).get("enemies", "?")),
		int(post_kids.get("codex_open_second", -1)) == int(post_kids.get("codex_open_first", -2))
		and int(post_kids.get("codex_open_second", -1)) == int(post.get("registry", {}).get("enemies", -1)),
		"post first=%s second=%s" % [str(post_kids.get("codex_open_first", "-")),
			str(post_kids.get("codex_open_second", "-"))])
	# ② 武器页首建（贴图委托臂主嫌）：修后 ≤ 修前
	var pre_w: int = int(pre_us.get("codex_tab_武器_first", 0))
	var post_w: int = int(post_us.get("codex_tab_武器_first", 0))
	_check("M0c 武器页首建 修后 ≤ 修前（%d → %d µs；P3 预热并队 + P4 双缓存）" % [pre_w, post_w],
		pre_w > 0 and post_w <= pre_w, "pre=%d post=%d" % [pre_w, post_w])
	# ③ 词条→祝福页首建（字号测量主嫌）：修后显著降（P2 缓存 + P1 离树）
	var pre_t: int = int(pre_us.get("codex_tab_词条_first", 0))
	var post_t: int = int(post_us.get("codex_tab_祝福_first", 0))
	_check("M0d 祝福页(原词条)首建 修后 ≤ 修前（%d → %d µs；P1 双布局 + P2 测量缓存）" % [pre_t, post_t],
		pre_t > 0 and post_t <= pre_t, "pre=%d post=%d" % [pre_t, post_t])
	# ④ 反应页首建
	var pre_r: int = int(pre_us.get("codex_tab_反应_first", 0))
	var post_r: int = int(post_us.get("codex_tab_反应_first", 0))
	_check("M0e 反应页首建 修后 ≤ 修前（%d → %d µs）" % [pre_r, post_r],
		pre_r > 0 and post_r <= pre_r, "pre=%d post=%d" % [pre_r, post_r])
	# ⑤ 委托臂直调热调：修前 ~25ms（成品缓存缺失实证）→ 修后 ≤1ms
	var pre_d: int = int(pre_us.get("delegate_icon_warm", 0))
	var post_d: int = int(post_us.get("delegate_icon_warm", 0))
	_check("M0f 委托臂直调热调 修后 ≤1ms（修前 %d µs → 修后 %d µs；P4-② 成品缓存）" % [pre_d, post_d],
		pre_d > 1000 and post_d <= 1000, "pre=%d post=%d" % [pre_d, post_d])
# ── R254-1 页级缓存生命周期（QA 第 1 轮补缺口） ────────────────────
func _test_m6_cache_lifecycle() -> void:
	print("── M6e-h 缓存生命周期：六面板互切复用 / 闲时泵边界 / 失效双态销毁 / null 守卫 ──")
	# —— M6e 六面板互切混挂后图鉴缓存行仍复用（其余页行照旧 free） ——
	var gl = _mk_gl("GameLoopR252M6L")
	_menu = gl.menu_screen
	_menu._on_lobby_pressed("codex")
	_menu._on_codex_tab("武器")
	var ids0: Array[int] = []
	for r in _live_rows(_menu._panel_list):
		ids0.append(r.get_instance_id())
	var foreign_row: Node = null
	for kind in ["records", "ach", "char", "upgrade", "daily"]:
		_menu._on_lobby_pressed(kind)
		if kind == "records" and _menu._panel_list.get_child_count() > 0:
			foreign_row = _menu._panel_list.get_child(0)
	_check("M6e-a 五面板接力切走：记录行回收进 _rec_rows_cache 缓存非标删（R267 刀P3 配套迁移——原断「已标删」锚 R254 前旧语义）",
		foreign_row != null and _menu._rec_rows_cache.has(foreign_row) and not foreign_row.is_queued_for_deletion(),
		"row=%s" % str(foreign_row != null))
	_menu._on_lobby_pressed("codex")                  # 回图鉴（当前 tab 仍=武器）
	var ids1: Array[int] = []
	for r in _live_rows(_menu._panel_list):
		ids1.append(r.get_instance_id())
	_check("M6e-b 六面板互切后回图鉴：缓存行实例复用（同 id 集合直挂，不重建）",
		ids0.size() > 0 and ids0 == ids1,
		"%d → %d" % [ids0.size(), ids1.size()])
	_menu._on_panel_close()
	gl.free()
	_menu = null
	# —— M6f 闲时泵：可见性门 + 分帧消化 + 建页不挂树 + 与玩家切页同帧合成 ——
	var gl2 = _mk_gl("GameLoopR252M6P")
	_menu = gl2.menu_screen
	_check("M6f-a 起点队满 5 页缓存空（boot 排程；同步测试无帧渗漏）",
		_menu._codex_prewarm_queue.size() == 5 and _menu._codex_page_cache.is_empty(),
		"q=%d cache=%d" % [_menu._codex_prewarm_queue.size(), _menu._codex_page_cache.size()])
	_menu._root.visible = false                      # 非 MENU 态（root 不可见）→ 泵停
	_menu._process(0.016)
	_check("M6f-b 非 MENU 态泵停（root 不可见一读即返，队列不动）",
		_menu._codex_prewarm_queue.size() == 5 and _menu._codex_page_cache.is_empty(),
		"q=%d" % _menu._codex_prewarm_queue.size())
	_menu._root.visible = true
	_menu._process(0.016)                            # 单帧 4ms 预算：至少消化一页
	_check("M6f-c 单帧预算消化（行级泵：队首出队在建或页毕入缓存——R254 修轮#2）",
		_menu._codex_prewarm_queue.size() < 5
			and (_menu._codex_page_cache.size() >= 1 or _menu._codex_pump_tab != ""),
		"q=%d cache=%d pump_tab=%s" % [_menu._codex_prewarm_queue.size(),
			_menu._codex_page_cache.size(), _menu._codex_pump_tab])
	var off_tree := true
	for tab_v: Variant in _menu._codex_page_cache.values():
		for row_v: Variant in tab_v:
			if (row_v as Node).is_inside_tree():
				off_tree = false
	_check("M6f-d 预建页不挂树（纯构建——挂树只发生在 _rebuild_codex）",
		off_tree and _menu._panel_list.get_child_count() == 0,
		"panel_kids=%d" % _menu._panel_list.get_child_count())
	var guard := 0
	while (not _menu._codex_prewarm_queue.is_empty()
			or _menu._codex_pump_tab != "") and guard < 400:
		_menu._process(0.016)
		guard += 1
	_check("M6f-e 泵排空后五页全备（缓存恰 5 页）",
		_menu._codex_prewarm_queue.is_empty() and _menu._codex_page_cache.size() == 5,
		"q=%d cache=%d keys=%s pump_tab=%s pump_i=%d guard=%d" % [_menu._codex_prewarm_queue.size(),
			_menu._codex_page_cache.size(), str(_menu._codex_page_cache.keys()),
			_menu._codex_pump_tab, _menu._codex_pump_i, guard])
	# 同帧竞态合成：玩家切到已预建页 → 挂的正是缓存实例（泵与切页不双建）
	_menu._on_lobby_pressed("codex")
	_menu._on_codex_tab("反应")
	var mounted_ids: Array[int] = []
	for r in _live_rows(_menu._panel_list):
		mounted_ids.append(r.get_instance_id())
	var cached_ids: Array[int] = []
	for row_v: Variant in (_menu._codex_page_cache["反应"] as Array):
		cached_ids.append((row_v as Node).get_instance_id())
	_check("M6f-f 玩家切已预建页=缓存实例直挂（泵先建/切页先建两序同果，不双建）",
		mounted_ids.size() > 0 and mounted_ids == cached_ids,
		"mounted=%d cached=%d" % [mounted_ids.size(), cached_ids.size()])
	_menu._process(0.016)
	var cached_after: Array[int] = []
	for row_v: Variant in (_menu._codex_page_cache["反应"] as Array):
		cached_after.append((row_v as Node).get_instance_id())
	_check("M6f-g 切页后泵空转不重建（缓存行实例不变）",
		cached_after == cached_ids and _menu._codex_prewarm_queue.is_empty(),
		"%d → %d" % [cached_ids.size(), cached_after.size()])
	_menu._on_panel_close()
	gl2.free()
	_menu = null
	# —— M6g 失效双态：挂树行 detach+标删 / 离树缓存行同样标删（堵离树 queue_free 漏） ——
	var gl3 = _mk_gl("GameLoopR252M6I")
	_menu = gl3.menu_screen
	_menu._on_lobby_pressed("codex")                  # 怪物：建+挂
	_menu._on_codex_tab("武器")                       # 武器：建+挂；怪物 detach 入缓存
	var mounted2: Array[int] = []
	for r in _live_rows(_menu._panel_list):
		mounted2.append(r.get_instance_id())
	var detached2: Array[int] = []
	for row_v: Variant in (_menu._codex_page_cache["怪物"] as Array):
		detached2.append((row_v as Node).get_instance_id())
	_menu._invalidate_codex_cache()
	var all_dead := true
	for id_v in mounted2 + detached2:
		var n: Node = instance_from_id(int(id_v))
		if n == null or not n.is_queued_for_deletion():
			all_dead = false
	var none_mounted := true
	for c in _menu._panel_list.get_children():
		if c.get_instance_id() in mounted2:
			none_mounted = false
	_check("M6g 失效双态：挂树行脱离面板+全部行（含离树缓存行）已标删",
		all_dead and none_mounted,
		"dead=%s unmounted=%s" % [str(all_dead), str(none_mounted)])
	_check("M6g' 失效后缓存空+预建队重排 5 页",
		_menu._codex_page_cache.is_empty() and _menu._codex_prewarm_queue.size() == 5,
		"cache=%d q=%d" % [_menu._codex_page_cache.size(), _menu._codex_prewarm_queue.size()])
	_menu._on_panel_close()
	gl3.free()
	_menu = null
	# —— M6h _panel_list null 边界（_build_panel 前的信号早到防御） ——
	var ms_script: GDScript = load(MENU_SRC)
	var ms = ms_script.new()                          # 不入树：_ready 未跑 → _panel_list==null
	ms._invalidate_codex_cache()
	_check("M6h _panel_list null 时失效不崩（守卫分支：清数据+重排队）",
		ms._codex_page_cache.is_empty() and ms._codex_prewarm_queue.size() == 5,
		"q=%d" % ms._codex_prewarm_queue.size())
	ms.free()

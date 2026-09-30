# tests/runner/r195_adapt_cases.gd
# R195 整案验收套件用例体（tracker 套件名 r195_adapt；由 test_r195_adapt.gd 入口在
# autoload 就绪后运行时 load 编译——-s 模式入口脚本编译早于全局名注册，同 pkg0~pkg5 口径）。
# 覆盖定案 docs/design/R195_SCREEN_ADAPT.md 全部非 noop 项（三方向均 implement）：
#   域A 商店刷新钮（§1）：can_refresh() 三口径合一单源谓词（金不够/无真货两态→隐藏、
#       可刷→复显）、disabled 写点删净（禁「既灰又藏」）、价签无条件同步（隐藏期保新价）、
#       几何三件套原值、金量门不升级（§1.4）、can_refresh 纯只读、market_supply 刷新价
#       曲线 15×market_mult(wave,9)×1.5ⁿ 不回归、黑市/战前补给双态一致（谓词零 _pre_boss）。
#   域B 激光穿透（§2，直驱范式沿用 pkg3/r195_laser_pierce_cases：weapon(100,640) 沿 +X，
#       E1/E2/E3=(260/420/580,640) 同轴 beam_length=560 内，E4=(700,640) t=600 超程对照，
#       beam.tick(0.26)=2 跳）：预算口径主束命中数=1+贯穿数（N=pierce：1 首目标+N−1 贯穿，
#       R195 有意变更契约——否决 1+pierce 旧案与旧单目标口径）、无逐目标衰减（f=1）+
#       pierce_index 序数池（SYN ×(1+value×(index−1)) 与弹体同式）、副束口径恒 1（三重门
#       depth==0 ∧ ¬sub_beam ∧ ¬overlap_fallback）、last_hit_uid/_pierce_count/AFF_PIERCE
#       形态门数据契约。
#   域C 多尺寸矩阵（§3.6）：7 尺寸（720×1280/1440/1560/1600/1680 + 960×1280 + 540×960）
#       × 7 UI 态，七律 R1 界内/R2 无重叠（白名单钉死）/R3 全宽标签居中/R4 底簇贴底/
#       R5 spawn 不入设计域/R6 dim==visible_rect/R7 触控目标不缩水 + 锚定恒等
#       （左上 (24,24)、右上贴沿 16/134/20——§3.3 分区表形式化）+ 超限钳制（720×1800 回落
#       KEEP origin.y≈260、720×1680 满屏、双向可逆）+ safe-area/域边界线契约 + combat
#       零视口读取 + res_logic 钉死。
#   域D 设置键（§6）：无新增运行时设置键（SETTINGS_DEFAULTS 键集逐位钉死）、aspect=expand
#       为唯一项目设置改值（单行可回退）、钳制阈值 2.34 为代码常量、读口缺键回默认/
#       未知键拒写（存档兼容）、既有键写口钳制机制不回归。
# 时序纪律：win.size 赋值后 await ≥2 帧再断言（同帧读旧值）；resize 后 _show_toast 重触发；
# 弹窗卡 squash_pop 沉降 0.5s 再测；末尾 _gl.free() 防泄漏（r194 口径）。
# 「显示不能乱」硬底线：任一尺寸任一律红即本套件 FAIL（宁可 aspect=keep 黑边回退）。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const BALLISTIC_SCENE := "res://scenes/combat/projectiles/ballistic_projectile.tscn"
const HOMING_SCENE := "res://scenes/combat/projectiles/homing_projectile.tscn"
const LASER_SCENE := "res://scenes/combat/lasers/laser_beam.tscn"
const ENEMY_SCENE := "res://scenes/combat/enemies/enemy.tscn"
const GAME_LOOP_SRC := "res://scripts/loop/game_loop.gd"
const SHOP_UI_SRC := "res://scripts/ui/shop_ui.gd"

# 域C 矩阵常量（与 r195_layout_cases / 定案 §3.6 同源钉死）
const DESIGN_DOMAIN := Rect2(0.0, 0.0, 720.0, 1280.0)   # 逻辑域（F-01 钉死，data_validator fatal）
const R1_GROW := 2.0                            # R1 界内容差（验收口径 +2px）
const CENTER_TOL := 2.0                         # R3 居中容差
const EDGE_TOL := 2.0                           # R4 贴底容差
const ANCHOR_TOL := 2.0                         # 锚定恒等容差
const SKILL_BOTTOM_BAND := 82.0                 # 技能钮底带（1280−1198）
# R196 有意契约变更（原 BUILD_BOTTOM_BAND 24.0）：构筑面板默认落位 POS0 右上
# （hud.gd _apply_build_panel_pos：锚 t/b=0、offset_top=196）——改钉 vis 顶带
const BUILD_TOP_BAND := 196.0
const CLAMP_RATIO_MAX := 2.34                   # 超限钳制阈值（game_loop 代码常量同源）
# 右上锚恒等 inset（§3.3 #2：offset_right=720−右沿：徽章 704→16 / 暂停 586→134 / AUTO 700→20）
const BADGE_RIGHT_INSET := 16.0
const PAUSE_RIGHT_INSET := 134.0
const AUTO_RIGHT_INSET := 20.0
# 左上锚恒等位（§3.3 #1：HP 面板 (24,24)）
const HP_PANEL_POS := Vector2(24.0, 24.0)

# 矩阵尺寸（label, window Vector2i, 期望 visible_rect size）——7 档
const SIZES: Array = [
	["720x1280 基准16:9", Vector2i(720, 1280), Vector2(720, 1280)],
	["720x1440 18:9", Vector2i(720, 1440), Vector2(720, 1440)],
	["720x1560 19.5:9", Vector2i(720, 1560), Vector2(720, 1560)],
	["720x1600 20:9", Vector2i(720, 1600), Vector2(720, 1600)],
	["720x1680 21:9", Vector2i(720, 1680), Vector2(720, 1680)],
	["960x1280 3:4平板", Vector2i(960, 1280), Vector2(960, 1280)],
	["540x960 桌面默认窗", Vector2i(540, 960), Vector2(720, 1280)],
]

# 域D：R195 前既有的 9 个运行时设置键（§6 无新增——键集逐位钉死，新键须评审）
# R196 有意契约变更（原 9 键）：panel_pos 构筑面板位置三选入设置面
# （meta_manager.gd SETTINGS_DEFAULTS + _normalized_setting 双注册；存档 values
# 字典加键，旧档缺键回默认 0——R196_GROWTH_FIXES.md §1.1）
const EXPECTED_SETTING_KEYS: Array[String] = [
	"auto_restart_mode", "auto_select_on", "bgm_volume", "damage_numbers_on",
	"fps_cap", "fx_opacity", "fx_quality", "panel_pos", "shake_on", "sfx_volume",
]

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null

# 域B 轴向探针几何（pkg3 直驱同款：束原点沿 +X，E1-E3 同轴 560 内，E4 超程对照）
const WEAPON_POS := Vector2(100.0, 640.0)       # 束原点（+X 轴向）
const E1_POS := Vector2(260.0, 640.0)           # t=160（首目标，最近）
const E2_POS := Vector2(420.0, 640.0)           # t=320（贯穿 2）
const E3_POS := Vector2(580.0, 640.0)           # t=480（贯穿 3 / B6 金丝雀）
const E4_POS := Vector2(700.0, 640.0)           # t=600 > 560 超程对照（恒不命中）
const AXIS_ENEMIES: Array[Vector2] = [E1_POS, E2_POS, E3_POS, E4_POS]

# 域B 直驱夹具（pkg3 同款）
var _proj_pool: ProjectilePool
var _homing_pool: ProjectilePool
var _laser_pool: LaserBeamPool
var _enemy_pool: EnemyPool
var _grid: SpaceGrid
var _pipeline: DamagePipelineStub
var _alive_enemies: Array[Node2D] = []
var _wd_counter: int = 0

# 域C 菜单全宽标签句柄（boot 后采集一次——锚定重排不改节点身份）
var _menu_logo: Control = null
var _menu_subtitle: Label = null
var _menu_announce: Array[Label] = []
var _menu_name_tag: Label = null
var _menu_footer: Label = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_normalize_window_for_boot()
	_test_shop_refresh_gate()                      # 域A 商店刷新钮（§1）
	_test_laser_pierce()                           # 域B 激光穿透（§2）
	await _test_adapt_matrix()                     # 域C 多尺寸矩阵（§3）
	_test_settings_keys()                          # 域D 设置键契约（§6）
	# 环境还原（boot 等价位）
	tree.paused = false
	RunSave.clear()
	_normalize_window_for_boot()
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)


func fail_count() -> int:
	return _fail


func pass_count() -> int:
	return _pass


# ═══════════════════════ 域A 商店刷新钮（定案 §1） ═══════════════════════
func _test_shop_refresh_gate() -> void:
	print("── 域A 商店刷新钮：can_refresh 三口径合一 + 原位隐藏 ──")
	# A0 静态契约：disabled 写点删净（全仓 0 命中——disabled 与 visible 不并存，
	# 防「既灰又藏」混合态；needle 拼接构造避免本文件自命中）。R195 有意契约变更：
	# 置灰→原位隐藏（verify_feedback:3188 断言已同步改 not visible）。
	var needle := "refresh_btn" + ".disabled"
	var hits := _scan_dir("res://scripts").count(needle) + _scan_dir("res://tests").count(needle)
	# 断言名不含连续 needle（防本文件自命中——写点删净断言自身即源文本）
	_check("A0①：刷新钮 disabled 写点全仓（scripts+tests）0 命中（写点删净，禁「既灰又藏」）",
		hits == 0, "hits=%d" % hits)
	var src := _read_source(SHOP_UI_SRC)
	_check("A0②：can_refresh() 恰 1 处定义（单源谓词，无第二口径）",
		src.count("func can_refresh") == 1, "defs=%d" % src.count("func can_refresh"))
	var body := _strip_comments(_func_body(src, "func can_refresh"))
	_check("A0③：谓词体（剥注释）= 金价层 + has_stock()（R71/R188-C/R189 逐位同源）"
		+ "且零 _pre_boss 分支（注释按 §1.1 可提及，代码不分叉）",
		body.contains("refresh_cost()") and body.contains("has_stock()")
		and not body.contains("_pre_boss"), body.strip_edges())
	_check("A0④：_refresh() 唯一联动写点 refresh_btn.visible = can_refresh()",
		src.count("refresh_btn.visible = can_refresh()") == 1,
		"wires=%d" % src.count("refresh_btn.visible = can_refresh()"))
	# A1 几何三件套原值（§1.3：刷新钮 210×56@(211,802)、出击钮 210×60@(211,868)——
	# 仅 visible 翻转，position/size 不变；R194_MOBILE_PLAY §4.2 几何契约不破）
	_boot_game_loop()
	var shop: ShopUi = _gl.shop_ui
	var refresh_btn: Button = shop._root.get_node("ShopCard/ShopRefreshButton") as Button
	var leave_btn: Button = shop._root.get_node("ShopCard/ShopLeaveButton") as Button
	_check("A1①：刷新钮几何原值 (211,802) 210×56（visible 翻转不动几何）",
		refresh_btn != null and refresh_btn.position == Vector2(211.0, 802.0)
		and refresh_btn.size == Vector2(210.0, 56.0),
		"pos=%s size=%s" % [str(refresh_btn.position if refresh_btn != null else Vector2.ZERO),
			str(refresh_btn.size if refresh_btn != null else Vector2.ZERO)])
	_check("A1②：出击钮几何原值 (211,868) 210×60（原位隐藏留空版面不重排）",
		leave_btn != null and leave_btn.position == Vector2(211.0, 868.0)
		and leave_btn.size == Vector2(210.0, 60.0))
	if refresh_btn == null:
		_teardown_game_loop()
		return
	# T1 不可刷态一：金币不足 → visible==false（R195 有意变更：置灰→隐藏，留空）
	_gl.player.set("hp", 1.0)                      # 压低血量 → 维修包行真货（has_stock 确定性）
	_gl.player.set("gold", 0)
	shop.open(_gl.player, 7, false)
	_check("A2①：前置 has_stock()==true（0 金但货真价实——隔离金价层）", shop.has_stock())
	_check("A2②：金不够 → 刷新钮 visible==false 且 can_refresh()==false（不给刷就别显示）",
		not refresh_btn.visible and not shop.can_refresh(),
		"visible=%s can=%s" % [str(refresh_btn.visible), str(shop.can_refresh())])
	# T2 复显双向锁：回金 ≥ refresh_cost() + _refresh() → visible==true
	var c0: int = shop.refresh_cost()
	_gl.player.set("gold", c0)
	shop._refresh()
	_check("A3①：回金 ≥refresh_cost() → visible==true 且 can_refresh()==true（可刷恢复）",
		refresh_btn.visible and shop.can_refresh())
	_check("A3②：价签同步——钮面文本含当前刷新价 %d（隐藏/复显均保新价，不闪旧价）" % c0,
		refresh_btn.text.contains(str(c0)), "tag=%s" % refresh_btn.text)
	# T3 真链按压：扣金 + 计数 +1 + 价签随 1.5ⁿ 曲线同步 + 仍可刷（金留足）
	_gl.player.set("gold", c0 * 10)
	shop._on_refresh_pressed()
	var c1: int = shop.refresh_cost()
	_check("A4①：真链刷新扣金（gold −c0，金量门现语义）",
		int(_gl.player.get("gold")) == c0 * 10 - c0,
		"gold=%d expect=%d" % [int(_gl.player.get("gold")), c0 * 10 - c0])
	_check("A4②：_refresh_count==1（曲线推进）", shop.refresh_count_used() == 1,
		"used=%d" % shop.refresh_count_used())
	_check("A4③：价签同步——刷新后钮面含新价 %d（15×mult×1.5¹）" % c1,
		refresh_btn.text.contains(str(c1)), "tag=%s cost=%d" % [refresh_btn.text, c1])
	_check("A4④：刷新后仍可刷 → visible 保持 true（三入口全状态覆盖）", refresh_btn.visible)
	# T4 不可刷态二：无真货（金足）——满血维修包行 = 唯一行且非真货 → has_stock()==false
	_gl.player.set("hp", float(_gl.player.get("max_hp")))
	shop.close()
	_gl.player.set("gold", 9999)
	shop.open(_gl.player, 7, false)
	var dead_wares: Array[Dictionary] = [{"kind": "heal", "base": 30.0, "mult": 1.0, "rarity": 0}]
	shop._wares = dead_wares                       # 直驱构造死架（满血 heal：非真货行）
	shop._refresh()
	_check("A5①：前置 has_stock()==false（无真货：满血维修包行）", not shop.has_stock())
	_check("A5②：金足但无真货 → visible==false（R188-C/R189 口径：死架禁刷=隐藏）",
		not refresh_btn.visible and not shop.can_refresh(),
		"visible=%s" % str(refresh_btn.visible))
	_check("A5③：隐藏期价签仍无条件同步（含当前价 %d——重显不闪旧价红线）" % shop.refresh_cost(),
		refresh_btn.text.contains(str(shop.refresh_cost())), "tag=%s" % refresh_btn.text)
	# T5 金量门不升级（§1.4 裁决四：_on_refresh_pressed 保留 gold-only，不加 has_stock 门
	# ——四处测试直调真链依赖现语义；R195 有意保留契约）
	var gold_before: int = int(_gl.player.get("gold"))
	var cost_at_press: int = shop.refresh_cost()
	shop._on_refresh_pressed()
	_check("A6：无真货 + 金足按压 → 仍按 gold-only 门扣金重掷（守卫不升级，R195 保留）",
		shop.refresh_count_used() == 1
		and int(_gl.player.get("gold")) == gold_before - cost_at_press,
		"used=%d gold=%d" % [shop.refresh_count_used(), int(_gl.player.get("gold"))])
	# T6 can_refresh 纯只读（不扣金、不重掷、无副作用——连调 3 次状态零位移）
	shop._refresh()                                # 重建成货架 + 联动可见性（_refresh_count 不动）
	var pure_gold: int = int(_gl.player.get("gold"))
	var pure_wares: int = shop._wares.size()
	var pure_count: int = shop.refresh_count_used()
	for i in range(3):
		shop.can_refresh()
	_check("A7：can_refresh()×3 纯只读（金/货架/刷新计数零位移）",
		int(_gl.player.get("gold")) == pure_gold and shop._wares.size() == pure_wares
		and shop.refresh_count_used() == pure_count)
	# T7 黑市/战前补给双态一致（谓词零 _pre_boss 分支实证：同口径下战前补给同样隐藏）
	_gl.player.set("gold", 0)
	shop.open(_gl.player, 7, true)
	_check("A8①：战前补给态 0 金 → visible==false（与黑市同口径）",
		refresh_btn != null and not refresh_btn.visible)
	_check("A8②：标题「战前补给」（_pre_boss 仅标题分叉，谓词不分叉）",
		shop._title != null and shop._title.text == "战前补给",
		"title=%s" % str(shop._title.text if shop._title != null else ""))
	shop.close()
	# T8 刷新价曲线不回归（market_supply 口径：15×market_mult(wave,9)×1.5ⁿ 逐点相等）
	shop.open(_gl.player, 7, false)
	var curve_ok := true
	for n in [0, 1, 2]:
		shop.set("_refresh_count", n)
		var expect := int(ceil(15.0 * shop.market_mult(7, 9) * pow(1.5, float(n))))
		if int(shop.refresh_cost()) != expect:
			curve_ok = false
	_check("A9①：刷新价曲线不回归——n∈{0,1,2} 逐点 == 15×market_mult(7,9)×1.5ⁿ", curve_ok)
	shop.set("_refresh_count", 0)
	var curve_c0: int = shop.refresh_cost()
	shop.set("_refresh_count", 2)
	_check("A9②：倍率语义 c2/c0 ≈ 2.25（1.5²，窄口径只藏钮不动价）",
		absf(float(shop.refresh_cost()) / float(curve_c0) - 2.25) < 0.2,
		"c0=%d c2=%d" % [curve_c0, shop.refresh_cost()])
	shop.close()
	shop.open(_gl.player, 7, false)                # 关店重开归零（R7 契约）
	_check("A9③：关店重开 _refresh_count 归零 + 价回基准",
		shop.refresh_count_used() == 0 and int(shop.refresh_cost()) == curve_c0,
		"used=%d cost=%d c0=%d" % [shop.refresh_count_used(), shop.refresh_cost(), curve_c0])
	shop.close()
	_teardown_game_loop()


# ═══════════════════════ 域B 激光穿透（定案 §2） ═══════════════════════
func _test_laser_pierce() -> void:
	print("── 域B 激光穿透：预算口径 hit=N + 无逐目标衰减 + 副束门 ──")
	# B0 数据契约（§2.2）：AFF_PIERCE 形态门打开（required_forms 含 LASER=1）——激光可购
	# 穿透，L 表 pierce=1 不动（平衡非目标）。R195 有意变更契约：AFF_PIERCE 激光 0→可上架。
	var aff := _load_trait("res://resources/traits/AFF_PIERCE.tres")
	_check("B0①：AFF_PIERCE.tres 直载非空", aff != null)
	if aff != null:
		var forms: Array = aff.params.get("required_forms", [])
		_check("B0②：required_forms 含 LASER(1)（形态门 [0]→[0,1]，激光可上架）",
			forms.has(GameConst.WeaponForm.LASER), "forms=%s" % str(forms))
		_check("B0③：stack_max==2 / value==1.45（F3 衰减聚合 add_pierce 数据原值）",
			aff.stack_max == 2 and is_equal_approx(aff.value, 1.45),
			"stack=%d value=%s" % [aff.stack_max, str(aff.value)])
	_setup_laser_world()
	# B1 基线 N=1 零位移（与旧单目标口径逐位同构——pkg3 已知数不回归的根）
	var p1 := _run_axis_probe(1, [], AXIS_ENEMIES)
	var b1: LaserBeam = p1["beam"]
	var e1s: Array[Node2D] = p1["enemies"]
	_check("B1 前置：beam.pierce==1（L 表缺省=预算缺省）", b1.pierce == 1, str(b1.pierce))
	_check("B1①：N=1 主束命中==1（=1+0 贯穿）——仅 E1 结算（hp<1000）",
		(e1s[0] as Enemy).hp < 999.999, "hp=%s" % str((e1s[0] as Enemy).hp))
	var b1_rest := true
	for i in range(1, 4):
		if not _approx((e1s[i] as Enemy).hp, 1000.0, 0.001):
			b1_rest = false
	_check("B1②：E2/E3/E4 满血（单目标口径，零贯穿）", b1_rest)
	_check("B1③：束端==E1（首/最近目标）",
		_beam_end_global(b1).distance_to((e1s[0] as Node2D).global_position) <= 0.5,
		"end=%s" % str(_beam_end_global(b1)))
	(p1["weapon"] as LaserWeapon).free()
	_clear_enemies()
	# B2 预算口径 N=2：主束命中数 = 1 + 贯穿数 1 = 2（R195 有意变更：否决 1+pierce 旧案）
	var p2 := _run_axis_probe(2, [], AXIS_ENEMIES)
	var b2: LaserBeam = p2["beam"]
	var e2s: Array[Node2D] = p2["enemies"]
	_check("B2①：N=2 恰 E1+E2 结算（主束命中=1+1 贯穿=2；预算截断）",
		(e2s[0] as Enemy).hp < 999.999 and (e2s[1] as Enemy).hp < 999.999
		and _approx((e2s[2] as Enemy).hp, 1000.0, 0.001),
		"e1=%s e2=%s e3=%s" % [str((e2s[0] as Enemy).hp), str((e2s[1] as Enemy).hp),
			str((e2s[2] as Enemy).hp)])
	_check("B2②：E4 恒满血（t=600>560 超程对照——贯穿不越 beam_length）",
		_approx((e2s[3] as Enemy).hp, 1000.0, 0.001), "e4=%s" % str((e2s[3] as Enemy).hp))
	_check("B2③：结算节拍 settle==4（2 目标 × tick(0.26) 2 跳）", b2.settle_count == 4,
		"settle=%d" % b2.settle_count)
	_check("B2④：束端==末贯穿目标 E2（t 最大者）",
		_beam_end_global(b2).distance_to((e2s[1] as Node2D).global_position) <= 0.5)
	(p2["weapon"] as LaserWeapon).free()
	_clear_enemies()
	# B3 N=3：命中=1+2 贯穿=3（一列 3+ 敌人逐位结算，超程者除外）
	var p3 := _run_axis_probe(3, [], AXIS_ENEMIES)
	var e3s: Array[Node2D] = p3["enemies"]
	var b3_first := true
	for i in range(3):
		if _approx((e3s[i] as Enemy).hp, 1000.0, 0.001):
			b3_first = false
	_check("B3①：N=3 恰 E1-E3 结算（主束命中=1+2 贯穿=3）", b3_first)
	_check("B3②：E4 恒满血（超程对照零位移）",
		_approx((e3s[3] as Enemy).hp, 1000.0, 0.001), "e4=%s" % str((e3s[3] as Enemy).hp))
	(p3["weapon"] as LaserWeapon).free()
	_clear_enemies()
	# B4 无逐目标衰减（仲裁三 f=1：每跳同 base_atk 只扣计数；增减伤只走 pierce_index 池）
	var p4 := _run_axis_probe(2, [], [E1_POS, E2_POS])
	var e4s: Array[Node2D] = p4["enemies"]
	var d1 := 1000.0 - (e4s[0] as Enemy).hp
	var d2 := 1000.0 - (e4s[1] as Enemy).hp
	_check("B4①：N=2 同拍 E1/E2 伤害相等（无 ×0.6^(n-1) 逐目标衰减）", _approx(d1, d2, 0.001),
		"d1=%.3f d2=%.3f" % [d1, d2])
	_check("B4②：单跳已知数 21.6（2 跳 ×10×1.08 灼焦 1 层——pkg3 同源零位移）",
		_approx(d1, 21.6, 0.01), "d1=%.3f" % d1)
	(p4["weapon"] as LaserWeapon).free()
	_clear_enemies()
	# B5 pierce_index 序数池（仲裁四：第 k 目标 index=k+1，SYN ×(1+value×(index−1))
	# 与弹体同式——「逐目标衰减正确」的唯一合法通道；R195 有意变更：SYN 激光 0→生效）
	var syn: Array[String] = ["res://resources/traits/SYN_PIERCE_EVO.tres"]
	var p5 := _run_axis_probe(2, syn, [E1_POS, E2_POS])
	var e5s: Array[Node2D] = p5["enemies"]
	var s1 := 1000.0 - (e5s[0] as Enemy).hp
	var s2 := 1000.0 - (e5s[1] as Enemy).hp
	_check("B5①：E1 index=2 → ×1.2 ×灼焦1.08 → 2 跳 25.92", _approx(s1, 25.92, 0.01),
		"d=%.4f" % s1)
	_check("B5②：E2 index=3 → ×1.4 ×灼焦1.08 → 2 跳 30.24", _approx(s2, 30.24, 0.01),
		"d=%.4f" % s2)
	_check("B5③：逐目标伤害比 == 1.4/1.2（区内累进同弹体，cap 1.6 内）",
		_approx(s2 / s1, 1.4 / 1.2, 0.001), "ratio=%.4f" % (s2 / s1))
	(p5["weapon"] as LaserWeapon).free()
	_clear_enemies()
	# B6 副束口径（仲裁五：仅主束吃穿透——depth==0 ∧ ¬sub_beam ∧ ¬overlap_fallback 三重门；
	# W4 棱镜副束同列只结算锁定 1 目标，主束 N 不传导）
	LaserBeam.scorch_pool_reset()
	var w6 := _make_weapon(_make_weapon_data(1, {"refract_beams": 0, "beam_length": 560.0}))
	var prism_ok := true
	for path in ["res://resources/traits/AFF_PIERCE.tres",
			"res://resources/traits/MEC_SPLIT_PRISM.tres"]:
		var td := _load_trait(path)
		if td == null or not w6.attach_trait(td):
			prism_ok = false
	_check("B6 前置：AFF_PIERCE+MEC_SPLIT_PRISM 真卡挂载", prism_ok)
	_check("B6 前置：主束 _pierce_count()==2（L1+AFF_PIERCE 1.45→round 1）",
		w6._pierce_count() == 2, str(w6._pierce_count()))
	var c1 := _spawn_enemy(_make_enemy_data("E_B6A"), E1_POS)
	var c2 := _spawn_enemy(_make_enemy_data("E_B6B"), E2_POS)
	var c3 := _spawn_enemy(_make_enemy_data("E_B6C"), E3_POS)
	_check("B6 前置：try_fire 出主束+副束", w6.try_fire() and w6.active_beams.size() == 2,
		"beams=%d" % w6.active_beams.size())
	if w6.active_beams.size() == 2:
		var main: LaserBeam = w6._main_beam
		var sub: LaserBeam = w6._alive_sub_beams()[0]
		_check("B6①：副束 pierce==1 ∧ 主束 pierce==2（_hit_budget 三重门：穿透不传导副束）",
			sub.pierce == 1 and main.pierce == 2,
			"sub=%d main=%d" % [sub.pierce, main.pierce])
		main.tick(0.26)
		sub.tick(0.26)
		_check("B6②：主束 N=2 结算 E1+E2（均 <1000）",
			(c1 as Enemy).hp < 999.999 and (c2 as Enemy).hp < 999.999,
			"e1=%s e2=%s" % [str((c1 as Enemy).hp), str((c2 as Enemy).hp)])
		_check("B6③：同轴 E3 金丝雀恒满血（副束只结算锁定 1 目标，吃穿透即穿）",
			_approx((c3 as Enemy).hp, 1000.0, 0.001), "e3=%s" % str((c3 as Enemy).hp))
	else:
		_check("B6①：副束存在", false, "beams=%d" % w6.active_beams.size())
	_check("B6④：契约 last_hit_uid==E1（R91 主束锁定首目标，多目标不漂移）",
		w6._main_beam == null or w6._main_beam.last_hit_uid == int((c1 as Node2D).get("uid")),
		"last=%s e1=%s" % [str(w6._main_beam.last_hit_uid if w6._main_beam != null else -1),
			str(int((c1 as Node2D).get("uid")))])
	w6.free()
	_teardown_laser_world()


# ═══════════════════════ 域C 多尺寸矩阵（定案 §3.6） ═══════════════════════
func _test_adapt_matrix() -> void:
	print("── 域C 多尺寸适配矩阵：7 尺寸 × 7 态 × 七律 ──")
	_boot_game_loop()                              # 已归一窗口 boot（boot_ready/fatal 前置在内）
	_collect_menu_handles()
	_check("C0：默认窗归一后 visible_rect==(720,1280)（540×960 下 EXPAND≡KEEP）",
		_vis().size == Vector2(720, 1280) and _vis().position == Vector2.ZERO, str(_vis()))
	for entry in SIZES:
		await _visit_size(String(entry[0]), Vector2i(entry[1]), Vector2(entry[2]))
	await _test_stretch_clamp()                    # 超限钳制/回退位/双向可逆（A7）
	_test_safe_area_contract()                     # safe-area + 域边界线 + 零视口读取（A8）
	_teardown_game_loop()


func _visit_size(p_label: String, p_size: Vector2i, p_expect_vis: Vector2) -> void:
	print("── C 矩阵 @%s ──" % p_label)
	await _resize_and_settle(p_size)
	var vis := _vis()
	_check("矩阵 @%s：visible_rect 输出（expand 延展画布）" % p_label,
		vis.position == Vector2.ZERO and vis.size == p_expect_vis, str(vis))
	# 态序：MENU → PLAYING → PAUSED → 设置 → LEVEL_UP → 商店 → GAME_OVER → MENU
	_enter_menu()
	await tree.process_frame
	_law_r1_menu(p_label)
	_law_r2_menu(p_label)
	_law_r3_menu(p_label)
	_law_r6(_gl.menu_screen._root.find_child("MenuBg", true, false), p_label, "MENU")
	_enter_playing()
	await tree.process_frame
	_gl.hud._show_toast("R195 adapt 矩阵")         # resize 后重触发 toast（时序纪律）
	_law_r1_playing(p_label)
	_law_r2_playing(p_label)
	_law_r3_playing(p_label)
	_law_r4_playing(p_label)
	_law_anchors(p_label)
	_law_r6(_gl.hud._hud_root, p_label, "PLAYING")
	_law_r7(p_label)
	_law_r5(p_label)
	_enter_paused()
	await _state_settle()
	_law_r1(_gl.pause_overlay._card, p_label, "PAUSED/PauseCard")
	_law_r6(_gl.pause_overlay._root.find_child("PauseDim", true, false), p_label, "PAUSED")
	_enter_settings()
	await _state_settle()
	_law_r1(_gl.settings_panel._card, p_label, "SETTINGS/SettingsCard")
	_law_r2_settings(p_label)
	_law_r6(_gl.settings_panel._root.find_child("SettingsDim", true, false), p_label, "SETTINGS")
	_leave_settings()
	_enter_level_up()
	await _state_settle()
	_law_r1(_gl.card_select_ui._title, p_label, "LEVEL_UP/title")
	_law_r1(_gl.card_select_ui._reroll_btn, p_label, "LEVEL_UP/reroll")
	_pair_law(_gl.card_select_ui._title, _gl.card_select_ui._reroll_btn, p_label, "LEVEL_UP", false)
	_law_r3(_gl.card_select_ui._title, p_label, "LEVEL_UP/选卡标题")
	_law_r6(first_color_rect(_gl.card_select_ui._root), p_label, "LEVEL_UP")
	_leave_level_up()
	_enter_shop()
	await _state_settle()
	_law_r1(_gl.shop_ui._root.find_child("ShopCard", true, false) as Control, p_label,
		"SHOP/ShopCard")
	_law_r1(_gl.shop_ui._root.find_child("ShopRefreshButton", true, false) as Button, p_label,
		"SHOP/refresh_btn")
	_law_r1(_gl.shop_ui._root.find_child("ShopLeaveButton", true, false) as Button, p_label,
		"SHOP/leave_btn")
	_pair_law(_gl.shop_ui._root.find_child("ShopRefreshButton", true, false) as Button,
		_gl.shop_ui._root.find_child("ShopLeaveButton", true, false) as Button,
		p_label, "SHOP", false)
	_law_r6(first_color_rect(_gl.shop_ui._root), p_label, "SHOP")
	_leave_shop()
	_enter_game_over()
	await _state_settle()
	_law_r1(_gl.game_over_screen._card, p_label, "GAME_OVER/ReportCard")
	_law_r6(first_color_rect(_gl.game_over_screen._root), p_label, "GAME_OVER")
	_enter_menu()
	await tree.process_frame


# ── R1 界内（get_global_rect ⊆ visible_rect+2px——「显示不能乱」第一律） ──
func _law_r1_menu(p_label: String) -> void:
	var menu: MenuScreen = _gl.menu_screen
	_law_r1(_menu_logo, p_label, "MENU/Logo")
	_law_r1(_menu_subtitle, p_label, "MENU/副标")
	_law_r1(_menu_name_tag, p_label, "MENU/name_tag")
	_law_r1(_menu_footer, p_label, "MENU/footer")
	_law_r1(menu._root.find_child("StartButton", true, false) as Control, p_label,
		"MENU/StartButton")


func _law_r1_playing(p_label: String) -> void:
	var hud: HUD = _gl.hud
	_law_r1(hud._hp_fill.get_parent() as Control, p_label, "PLAYING/HpPanel")
	_law_r1(hud._kill_label, p_label, "PLAYING/KillText")
	_law_r1(hud._time_label, p_label, "PLAYING/TimeText")
	_law_r1(hud._gold_label, p_label, "PLAYING/GoldText")
	_law_r1(hud._level_label, p_label, "PLAYING/LevelText")
	_law_r1(hud._pause_btn, p_label, "PLAYING/PauseButton")
	_law_r1(hud._auto_btn, p_label, "PLAYING/AutoToggle")
	_law_r1(hud._skill_btn, p_label, "PLAYING/SkillButton")
	_law_r1(hud._tb_panel, p_label, "PLAYING/TargetBar")
	_law_r1(hud._boss_banner, p_label, "PLAYING/BossBanner")
	_law_r1(hud._state_label, p_label, "PLAYING/StateLabel")
	_law_r1(hud._revive_banner, p_label, "PLAYING/ReviveBanner")
	_law_r1(hud._hud_root.find_child("BuildPanel", true, false) as Control, p_label,
		"PLAYING/BuildPanel")


func _law_r1(p_ctrl: Control, p_label: String, p_tag: String) -> void:
	if p_ctrl == null:
		_check("R1 %s @%s：句柄非空" % [p_tag, p_label], false, "null")
		return
	var ok := _vis().grow(R1_GROW).encloses(p_ctrl.get_global_rect())
	_check("R1 %s @%s：界内（⊆vis+2px）" % [p_tag, p_label], ok,
		"rect=%s vis=%s" % [str(p_ctrl.get_global_rect()), str(_vis())])


# ── R2 无重叠（簇配对；白名单钉死——贴纸叠贴语言非缺陷，条目增量须评审） ──
func _law_r2_menu(p_label: String) -> void:
	if _menu_announce.size() >= 1:
		_pair_law(_menu_subtitle, _menu_announce[0], p_label, "MENU", false)
	if _menu_announce.size() >= 3:
		_pair_law(_menu_announce[_menu_announce.size() - 1], _menu_name_tag, p_label,
			"MENU", false)
	_pair_law(_menu_name_tag,
		_gl.menu_screen._root.find_child("StartButton", true, false) as Control,
		p_label, "MENU", false)


func _law_r2_playing(p_label: String) -> void:
	var hud: HUD = _gl.hud
	var hp_panel := hud._hp_fill.get_parent() as Control
	_pair_law(hud._kill_label, hud._time_label, p_label, "PLAYING", false)
	_pair_law(hud._time_label, hud._gold_label, p_label, "PLAYING", false)
	_pair_law(hud._kill_label, hud._gold_label, p_label, "PLAYING", false)
	_pair_law(hud._pause_btn, hud._auto_btn, p_label, "PLAYING", false)
	_pair_law(hud._wave_label.get_parent() as Control, hud._pause_btn, p_label, "PLAYING", false)
	_pair_law(hud._wave_label.get_parent() as Control, hud._auto_btn, p_label, "PLAYING", false)
	# 白名单钉死对（R198 契约变更：注释对齐 §3.3 登记全集 3 对——ReviveBadge∩HP 条
	# 设计钉死 + R187Readout∩HP 条（超设计增量，R198 补登评审）+ Settings 设置卡沿徽标；
	# 本函数钉前两对，第三对见 _law_r2_settings）——钉存在性防漂移
	_pair_law(hud._revive_badge, hp_panel, p_label, "PLAYING", true)
	_pair_law(hud._r187_readout, hp_panel, p_label, "PLAYING", true)


func _law_r2_settings(p_label: String) -> void:
	# 白名单钉死对（§3.3 第 3 对：设置卡沿徽标 settings_panel.gd:83 (268,−40) 压卡沿；
	# R198 注释对齐——全集=ReviveBadge∩HP 条、R187Readout∩HP 条、本对）
	_pair_law(_gl.settings_panel._card,
		_gl.settings_panel._root.find_child("SettingsGlyph", true, false) as Control,
		p_label, "SETTINGS", true)


func _pair_law(p_a: Control, p_b: Control, p_label: String, p_state: String,
		p_whitelisted: bool) -> void:
	if p_a == null or p_b == null:
		_check("R2 %s @%s：配对句柄非空（%s/%s）" % [p_state, p_label, str(p_a), str(p_b)],
			false, "null")
		return
	var overlaps: bool = p_a.get_global_rect().intersects(p_b.get_global_rect())
	if p_whitelisted:
		_check("R2 白名单对 @%s %s：钉存在（%s∩%s，贴纸叠贴语言）" % [p_label, p_state,
			p_a.name, p_b.name], true, "overlaps=%s" % str(overlaps))
	else:
		_check("R2 %s @%s：%s 与 %s 不相交" % [p_state, p_label, p_a.name, p_b.name],
			not overlaps, "a=%s b=%s" % [str(p_a.get_global_rect()), str(p_b.get_global_rect())])


# ── R3 全宽标签横向居中（|center_x−vis.center_x|≤2px；11 处逐个点名） ──
func _law_r3_menu(p_label: String) -> void:
	_law_r3(_menu_logo, p_label, "MENU/Logo")
	_law_r3(_menu_subtitle, p_label, "MENU/副标")
	for i in _menu_announce.size():
		_law_r3(_menu_announce[i], p_label, "MENU/公告%d" % i)
	_law_r3(_menu_name_tag, p_label, "MENU/name_tag")
	_law_r3(_menu_footer, p_label, "MENU/footer")


func _law_r3_playing(p_label: String) -> void:
	var hud: HUD = _gl.hud
	_law_r3(hud._boss_banner, p_label, "PLAYING/BossBanner")
	_law_r3(hud._state_label, p_label, "PLAYING/StateLabel")
	_law_r3(hud._revive_banner, p_label, "PLAYING/ReviveBanner")
	_law_r3(hud._toast_label, p_label, "PLAYING/WaveToast(重触发)")
	_law_r3(_gl.boss_bar._banner, p_label, "PLAYING/BossBarBanner")   # 第 11 处全宽标签


func _law_r3(p_ctrl: Control, p_label: String, p_tag: String) -> void:
	if p_ctrl == null:
		_check("R3 %s @%s：句柄非空" % [p_tag, p_label], false, "null")
		return
	var rect := p_ctrl.get_global_rect()
	var delta := absf(rect.position.x + rect.size.x * 0.5 - _vis().get_center().x)
	_check("R3 %s @%s：横向居中（≤%.0fpx）" % [p_tag, p_label, CENTER_TOL],
		delta <= CENTER_TOL, "delta=%.2f" % delta)


# ── R4 底簇贴底（offset_bottom 恒等 82/24——§3.3 #3 下锚） ────────────
func _law_r4_playing(p_label: String) -> void:
	var hud: HUD = _gl.hud
	var vis_end_y := _vis().end.y
	var skill_gap := absf((vis_end_y - hud._skill_btn.get_global_rect().end.y)
		- SKILL_BOTTOM_BAND)
	var build := hud._hud_root.find_child("BuildPanel", true, false) as Control
	# R196 有意契约变更（原「构筑面板贴 vis 底带 24px」）：面板默认 POS0 右上，
	# 锚 t=0/offset_top=196 → 贴 vis 顶带 196px（任意分辨率锚定恒等，同原底带口径）
	var build_gap := absf((build.get_global_rect().position.y - _vis().position.y)
		- BUILD_TOP_BAND)
	_check("R4 @%s：技能钮贴 vis 底带 %.0fpx（±%d）" % [p_label, SKILL_BOTTOM_BAND, int(EDGE_TOL)],
		skill_gap <= EDGE_TOL, "gap=%.2f" % skill_gap)
	_check("R4 @%s：构筑面板贴 vis 顶带 %.0fpx（±%d，R196 POS0 右上默认落位）" % [p_label, BUILD_TOP_BAND, int(EDGE_TOL)],
		build_gap <= EDGE_TOL, "gap=%.2f" % build_gap)


# ── 锚定恒等（§3.3 #1/#2 形式化：左上 (24,24)、右上贴沿 16/134/20 逐尺寸不变） ──
func _law_anchors(p_label: String) -> void:
	var hud: HUD = _gl.hud
	var vis := _vis()
	var hp := hud._hp_fill.get_parent() as Control
	var d_left := absf(hp.get_global_rect().position.x - (vis.position.x + HP_PANEL_POS.x))
	var d_top := absf(hp.get_global_rect().position.y - (vis.position.y + HP_PANEL_POS.y))
	_check("锚定 @%s：HP 面板左上锚恒等 (24,24)±2" % p_label,
		d_left <= ANCHOR_TOL and d_top <= ANCHOR_TOL,
		"d=(%.2f,%.2f)" % [d_left, d_top])
	var badge := hud._wave_label.get_parent() as Control
	var d_badge := absf((vis.end.x - badge.get_global_rect().end.x) - BADGE_RIGHT_INSET)
	var d_pause := absf((vis.end.x - hud._pause_btn.get_global_rect().end.x)
		- PAUSE_RIGHT_INSET)
	var d_auto := absf((vis.end.x - hud._auto_btn.get_global_rect().end.x)
		- AUTO_RIGHT_INSET)
	_check("锚定 @%s：右上贴沿恒等（徽章 16/暂停 134/AUTO 20，±2）" % p_label,
		d_badge <= ANCHOR_TOL and d_pause <= ANCHOR_TOL and d_auto <= ANCHOR_TOL,
		"badge=%.2f pause=%.2f auto=%.2f" % [d_badge, d_pause, d_auto])


# ── R5 spawn 不入设计域（§3.2 收窄口径：采样点 ∉ [0,720]×[0,1280]） ─────
func _law_r5(p_label: String) -> void:
	var spawner := EnemySpawner.new()
	spawner.pool = _gl.pools[&"enemy"]
	spawner.registry = _gl.registry
	spawner.difficulty = GameConst.Difficulty.NORMAL
	var grid := SpaceGrid.new()
	grid.configure(Vector2(720, 1280), 192.0)
	for i in range(24):
		spawner.enqueue({"data_id": &"E1_grunt", "wave": 1, "tags": 0})
	for attempt in range(10):
		if spawner.active.size() >= 24:
			break
		spawner.tick(0.016, grid)
	var all_out := spawner.active.size() > 0
	for e in spawner.active:
		if DESIGN_DOMAIN.has_point((e as Node2D).global_position):
			all_out = false
	_check("R5 @%s：spawn 采样 %d 点全部 ∉ 设计域（expand 顶延展渐显入场合规）"
		% [p_label, spawner.active.size()], all_out, "spawned=%d" % spawner.active.size())
	for e in spawner.active:
		(_gl.pools[&"enemy"] as EnemyPool).release(e)
	spawner.free()                                 # EnemySpawner=Node（显式释放）
	grid = null                                    # SpaceGrid=RefCounted（禁 free——引用落空自还）


# ── R6 dim.size == visible_rect（逐态） ──────────────────────────────
func _law_r6(p_dim: Control, p_label: String, p_state: String) -> void:
	if p_dim == null:
		_check("R6 %s @%s：dim 句柄非空" % [p_state, p_label], false, "null")
		return
	var delta: float = (p_dim.get_global_rect().size - _vis().size).length()
	_check("R6 %s @%s：dim.size==visible_rect" % [p_state, p_label], delta <= 0.5,
		"dim=%s vis=%s" % [str(p_dim.get_global_rect().size), str(_vis().size)])


# ── R7 触控目标逐尺寸不缩水（AUTO 56×64 / 暂停 72×72） ───────────────
func _law_r7(p_label: String) -> void:
	var hud: HUD = _gl.hud
	_check("R7 @%s：AUTO 钮 56×64 不缩水" % p_label,
		hud._auto_btn != null and hud._auto_btn.size == Vector2(56.0, 64.0),
		str(hud._auto_btn.size if hud._auto_btn != null else Vector2.ZERO))
	_check("R7 @%s：AUTO 胶囊 56×64 不缩水" % p_label,
		hud._auto_capsule != null and hud._auto_capsule.size == Vector2(56.0, 64.0),
		str(hud._auto_capsule.size if hud._auto_capsule != null else Vector2.ZERO))
	_check("R7 @%s：暂停钮 72×72 不缩水" % p_label,
		hud._pause_btn != null and hud._pause_btn.size == Vector2(72.0, 72.0),
		str(hud._pause_btn.size if hud._pause_btn != null else Vector2.ZERO))


# ── 超限钳制 / KEEP 回退位 / 双向可逆（A7） ──────────────────────────
func _test_stretch_clamp() -> void:
	print("── C 超限钳制与回退位 ──")
	var win: Window = tree.root
	var project_aspect := String(ProjectSettings.get_setting(
		"display/window/stretch/aspect", "keep"))
	var armed: bool = _gl.get("_stretch_clamp_armed")
	if project_aspect == "expand":
		_check("钳制前置：aspect=expand → _stretch_clamp_armed==true", armed, str(armed))
		# ① 720×1800（2.5:1 > 2.34）→ 回落 KEEP 居中黑边（黑边偏移实证在
		# get_final_transform().origin≈(0,260)——4.3 headless 实探：get_visible_rect()
		# position 恒 (0,0)（画布内容域），letterbox 偏移在 final_transform；
		# 「最次上下黑边」底线断言按引擎真值口径）
		await _resize_and_settle(Vector2i(720, 1800))
		if win.content_scale_aspect != Window.CONTENT_SCALE_ASPECT_KEEP:
			_gl.apply_stretch_aspect_clamp()       # headless 事件路径兜底直驱
			await tree.process_frame
		var vis := _vis()
		var tf_origin: Vector2 = win.get_final_transform().origin
		_check("钳制①：720×1800 → aspect==KEEP（>2.34 超限回落）",
			win.content_scale_aspect == Window.CONTENT_SCALE_ASPECT_KEEP)
		_check("钳制①：vis==(720,1280) 且黑边居中 final_tf.origin.y≈260（不越界不错位）",
			vis.size == Vector2(720, 1280) and absf(tf_origin.y - 260.0) <= 2.0,
			"vis=%s tf_origin=%s" % [str(vis), str(tf_origin)])
		# ② 720×1680（21:9≈2.3333 ≤ 2.34 整档留 EXPAND）→ 满屏
		await _resize_and_settle(Vector2i(720, 1680))
		if win.content_scale_aspect != Window.CONTENT_SCALE_ASPECT_EXPAND:
			_gl.apply_stretch_aspect_clamp()
			await tree.process_frame
		_check("钳制②：720×1680 → EXPAND 满屏 vis==(720,1680)",
			win.content_scale_aspect == Window.CONTENT_SCALE_ASPECT_EXPAND
			and _vis().size == Vector2(720, 1680), str(_vis()))
		# ③ 双向可逆：1800(KEEP) → 1680(EXPAND) → 1800(KEEP)
		await _resize_and_settle(Vector2i(720, 1800))
		_gl.apply_stretch_aspect_clamp()
		var keep_ok := win.content_scale_aspect == Window.CONTENT_SCALE_ASPECT_KEEP
		await _resize_and_settle(Vector2i(720, 1680))
		_gl.apply_stretch_aspect_clamp()
		var expand_ok := win.content_scale_aspect == Window.CONTENT_SCALE_ASPECT_EXPAND
		await _resize_and_settle(Vector2i(720, 1800))
		_gl.apply_stretch_aspect_clamp()
		var keep_again := win.content_scale_aspect == Window.CONTENT_SCALE_ASPECT_KEEP
		_check("钳制③：KEEP↔EXPAND 运行时双向切换可逆",
			keep_ok and expand_ok and keep_again,
			"k=%s e=%s k2=%s" % [str(keep_ok), str(expand_ok), str(keep_again)])
		# ④ 基准比例直驱钳制恒 EXPAND（不误回落）
		await _resize_and_settle(Vector2i(720, 1280))
		_gl.apply_stretch_aspect_clamp()
		_check("钳制④：720×1280 直驱钳制 → 恒 EXPAND（≤2.34 不回落）",
			win.content_scale_aspect == Window.CONTENT_SCALE_ASPECT_EXPAND)
	else:
		# 回退位分支（project.godot 单行改回 keep → 钳制零触发=现状黑边交付）
		_check("回退位：aspect=keep → _stretch_clamp_armed==false（零触发）", not armed,
			str(armed))
		await _resize_and_settle(Vector2i(720, 1800))
		_gl.apply_stretch_aspect_clamp()
		await tree.process_frame
		var vis := _vis()
		_check("回退位：720×1800 → KEEP 现状黑边 vis==(720,1280) 黑边居中 origin.y≈260",
			win.content_scale_aspect == Window.CONTENT_SCALE_ASPECT_KEEP
			and vis.size == Vector2(720, 1280)
			and absf(win.get_final_transform().origin.y - 260.0) <= 2.0,
			"aspect=%s vis=%s tf_origin=%s" % [str(win.content_scale_aspect), str(vis),
				str(win.get_final_transform().origin)])
	await _resize_and_settle(Vector2i(720, 1280))


# ── safe-area / 域边界线 / 零视口读取 / 逻辑域钉死（A8） ─────────────
func _test_safe_area_contract() -> void:
	print("── C safe-area 契约 ──")
	_check("safe①：headless 守卫 → enabled()==false（矩阵永不读真值）",
		not SafeAreaHelper.enabled(tree.root))
	_check("safe②：守卫外 insets 恒零 Rect2()", SafeAreaHelper.insets(tree.root) == Rect2(),
		str(SafeAreaHelper.insets(tree.root)))
	# 换算纯函数等价（契约式：canvas = final_transform.affine_inverse() × raw，负值钳零）
	var to_canvas: Transform2D = tree.root.get_final_transform().affine_inverse()
	var raw := Rect2(80.0, 40.0, 560.0, 1180.0)
	var area := to_canvas * raw
	var v := _vis()
	var right := maxf(v.size.x - area.end.x, 0.0)
	var bottom := maxf(v.size.y - area.end.y, 0.0)
	_check("safe③：负值钳零（右/下 inset=vis.end−area.end 恒 ≥0）",
		right >= 0.0 and bottom >= 0.0 and is_equal_approx(right, v.size.x - area.end.x),
		"r=%.1f b=%.1f" % [right, bottom])
	var helper_src := _read_source("res://scripts/ui/safe_area_helper.gd")
	_check("safe④：helper 源级守卫（mobile + 全屏两模式）",
		helper_src.contains("OS.has_feature(\"mobile\")")
		and helper_src.contains("MODE_FULLSCREEN")
		and helper_src.contains("MODE_EXCLUSIVE_FULLSCREEN"))
	_check("safe⑤：helper 源级换算+钳零+延迟读+重读信号（affine_inverse/maxf/process_frame/"
		+ "size_changed/focus_entered 五件套）",
		helper_src.contains("affine_inverse()") and helper_src.contains("maxf(")
		and helper_src.contains("process_frame") and helper_src.contains("size_changed")
		and helper_src.contains("focus_entered"))
	# 八屏根 FULL_RECT 接入（§3.5：七屏 UI 锚定组 + shop 商店组——只引用不复写）
	var screens := {
		"hud": "res://scripts/ui/hud.gd",
		"menu": "res://scripts/ui/menu_screen.gd",
		"shop": "res://scripts/ui/shop_ui.gd",
		"settings": "res://scripts/ui/settings_panel.gd",
		"pause": "res://scripts/ui/pause_overlay.gd",
		"game_over": "res://scripts/ui/game_over_screen.gd",
		"boss_bar": "res://scripts/ui/boss_bar.gd",
		"card_select": "res://scripts/cards/card_select_ui.gd",
	}
	var missing: Array[String] = []
	for key in screens:
		if not _read_source(screens[key]).contains("SafeAreaHelper"):
			missing.append(key)
	_check("safe⑥：八屏 SafeAreaHelper 接入（缺=%s）" % str(missing), missing.is_empty(),
		str(missing))
	# 域边界线（§3.4.4 必做：PlayfieldOutline 纯读 res_logic，size_changed 才 queue_redraw）
	var outline_src := _read_source("res://scripts/ui/playfield_outline.gd")
	_check("safe⑦：域边界线落位（playfield_outline 存在 + 纯读 res_logic + 按需重绘）",
		not outline_src.is_empty() and outline_src.contains("res_logic")
		and outline_src.contains("queue_redraw"))
	# combat/entities 零视口读取维持（战斗逻辑零改动红线：逻辑域钉死）
	var zero_hit := true
	for dir_path in ["res://scripts/combat", "res://scripts/entities"]:
		for file in _list_gd_files(dir_path):
			var fsrc := _read_source(file)
			if fsrc.contains("get_viewport()") or fsrc.contains("get_window()") \
					or fsrc.contains("get_visible_rect") or fsrc.contains("DisplayServer."):
				zero_hit = false
				print("  零视口读取违规：%s" % file)
	_check("safe⑧：combat/entities 零视口/窗口尺寸读取（适配层不越战斗域）", zero_hit)
	_check("safe⑨：GameConfig.balance.res_logic==(720,1280)（F-01 钉死，data_validator fatal 不动）",
		GameConfig.balance != null and Vector2(GameConfig.balance.res_logic) == Vector2(720, 1280),
		str(GameConfig.balance.res_logic if GameConfig.balance != null else Vector2.ZERO))


# ═══════════════════════ 域D 设置键契约（定案 §6） ═══════════════════════
func _test_settings_keys() -> void:
	print("── 域D 设置键：无新增键 + 钳制常量 + 存档兼容 ──")
	# D1 项目设置：唯一改值 aspect keep→expand（单行可回退），mode/viewport/override 原值
	_check("D1①：display/window/stretch/mode==canvas_items（原值不动）",
		String(ProjectSettings.get_setting("display/window/stretch/mode", "")) == "canvas_items",
		str(ProjectSettings.get_setting("display/window/stretch/mode", "")))
	_check("D1②：display/window/stretch/aspect==expand（R195 唯一项目设置改值）",
		String(ProjectSettings.get_setting("display/window/stretch/aspect", "")) == "expand",
		str(ProjectSettings.get_setting("display/window/stretch/aspect", "")))
	_check("D1③：viewport 720×1280 + override 540×960 原值（逻辑域/桌面默认窗钉死）",
		int(ProjectSettings.get_setting("display/window/size/viewport_width", 0)) == 720
		and int(ProjectSettings.get_setting("display/window/size/viewport_height", 0)) == 1280
		and int(ProjectSettings.get_setting("display/window/size/window_width_override", 0)) == 540
		and int(ProjectSettings.get_setting("display/window/size/window_height_override", 0)) == 960)
	# D2 无新增运行时设置键（§6：安全区走代码 helper、钳制阈值代码常量、手势条盲垫不进首版
	# ——SETTINGS_DEFAULTS 键集逐位钉死，新增键必须评审）
	var actual_keys: Array[String] = []
	for key in Meta.SETTINGS_DEFAULTS.keys():
		actual_keys.append(String(key))
	actual_keys.sort()
	var expected_keys: Array[String] = EXPECTED_SETTING_KEYS.duplicate()
	expected_keys.sort()
	# R196 有意契约变更（原「恰 9 键」）：panel_pos 构筑面板位置键入面（双注册齐，
	# DataValidator 口径 + 存档兼容——settings 段 values 字典加键允许、结构禁改）
	_check("D2①：SETTINGS_DEFAULTS 恰 10 键且键集与 R196 后逐位一致（panel_pos 为唯一新增键）",
		actual_keys == expected_keys,
		"actual=%s" % str(actual_keys))
	var no_new := true
	for key in actual_keys:
		if key.contains("aspect") or key.contains("stretch") \
				or key.contains("safe") or key.contains("clamp"):
			no_new = false
	_check("D2②：键集无 aspect/stretch/safe/clamp 族新键（钳制不扩散设置面）", no_new,
		str(actual_keys))
	# D3 钳制阈值是代码常量不是设置键（§3.1 裁定 b：阈值以 game_loop 内常量钉死）
	var gl_src := _read_source(GAME_LOOP_SRC)
	_check("D3：game_loop 源级钳制常量 STRETCH_ASPECT_RATIO_MAX := 2.34（不设设置键）",
		gl_src.contains("STRETCH_ASPECT_RATIO_MAX := 2.34")
		and not Meta.SETTINGS_DEFAULTS.has("aspect_ratio_max"))
	# D4 存档兼容：读口缺键回默认（旧档无 settings 段自动出厂值）、未知键拒写（防脏写穿档）
	var unknown_before: Variant = Meta.settings("r195_noop_key")
	Meta.set_setting("r195_noop_key", 1)
	_check("D4①：未知键读 null 且写被拒（写后仍 null——白名单外静默丢弃）",
		unknown_before == null and Meta.settings("r195_noop_key") == null)
	var saved := {}
	for key in Meta.SETTINGS_DEFAULTS.keys():
		saved[String(key)] = Meta.settings(String(key))
	Meta._settings.clear()                         # 模拟旧档无 settings 段
	_check("D4②：缺键读口回默认（fx_quality=2 / sfx_volume=0.8 出厂值，降级不崩）",
		int(Meta.settings("fx_quality")) == 2 and is_equal_approx(float(Meta.settings("sfx_volume")), 0.8),
		"fx=%s sfx=%s" % [str(Meta.settings("fx_quality")), str(Meta.settings("sfx_volume"))])
	# D5 既有键写口钳制机制不回归（fx_quality clampi 0~2 / fx_opacity clampf 0.3~1.0）
	Meta.set_setting("fx_quality", 9)
	var fx_clamped: int = int(Meta.settings("fx_quality"))
	Meta.set_setting("fx_opacity", 5.0)
	var fo_clamped: float = float(Meta.settings("fx_opacity"))
	_check("D5：既有键写口钳制不回归（fx_quality→2 / fx_opacity→1.0）",
		fx_clamped == 2 and is_equal_approx(fo_clamped, 1.0),
		"fx=%d fo=%.2f" % [fx_clamped, fo_clamped])
	# 还原（内存直写 + 两个被钳键经写口回存，user:// 不残留）
	Meta._settings = saved.duplicate(true)
	Meta.set_setting("fx_quality", int(saved["fx_quality"]))
	Meta.set_setting("fx_opacity", float(saved["fx_opacity"]))


# ── 域A/C 环境引导（main.tscn boot + 窗口归一） ──────────────────────
func _normalize_window_for_boot() -> void:
	# -s 脚本模式根窗口不应用工程 stretch（r194 同款归一）：aspect 读 ProjectSettings
	# 单源 + 默认窗 = override 540×960（引擎 boot 等价位）
	var win: Window = tree.root
	win.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	match String(ProjectSettings.get_setting("display/window/stretch/aspect", "keep")):
		"keep_width":
			win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP_WIDTH
		"keep_height":
			win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP_HEIGHT
		"expand":
			win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
		"ignore":
			win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_IGNORE
		_:
			win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
	win.size = Vector2i(
		int(ProjectSettings.get_setting("display/window/size/window_width_override", 540)),
		int(ProjectSettings.get_setting("display/window/size/window_height_override", 960)))


func _boot_game_loop() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "R195AdaptGameLoopUnderTest"
	tree.get_root().add_child(_gl)
	_check("前置：Boot 进入 MENU + 致命清单空（data_validator fatal 不动）",
		_gl.boot_ready and _gl.state == GameConst.GameStatus.MENU
		and _gl.boot_fatal.is_empty(), "fatal=%s" % str(_gl.boot_fatal))


func _teardown_game_loop() -> void:
	tree.paused = false
	RunSave.clear()
	if _gl != null:
		_gl.free()
		_gl = null


func _vis() -> Rect2:
	return tree.root.get_visible_rect()


func _resize_and_settle(p_size: Vector2i) -> void:
	# 时序纪律：size 赋值后 await ≥2 帧再断言（同帧读旧值）
	tree.root.size = p_size
	await tree.process_frame
	await tree.process_frame


func _state_settle() -> void:
	# 弹窗卡 squash_pop 出场动画沉降（~0.3s 弹性过冲；create_timer 默认
	# process_always=true：PAUSED 等挂起态照常推进）
	await tree.process_frame
	await tree.create_timer(0.5).timeout
	await tree.process_frame


func _enter_menu() -> void:
	if _gl.state != GameConst.GameStatus.MENU:
		_gl.change_state(GameConst.GameStatus.MENU)


func _enter_playing() -> void:
	_enter_menu()
	_gl.call(&"start_run")


func _enter_paused() -> void:
	if _gl.state != GameConst.GameStatus.PAUSED:
		_gl.call(&"request_pause")


func _enter_settings() -> void:
	_gl.settings_panel.open()


func _leave_settings() -> void:
	_gl.settings_panel.close()


func _enter_level_up() -> void:
	_gl.call(&"request_resume")                   # PAUSED→PLAYING
	_gl.change_state(GameConst.GameStatus.LEVEL_UP)
	var empty: Array[Dictionary] = []
	_gl.card_select_ui.open(empty)


func _leave_level_up() -> void:
	_gl.card_select_ui.close()


func _enter_shop() -> void:
	_gl.shop_ui.open(_gl.player, 5, false)


func _leave_shop() -> void:
	_gl.shop_ui.close()                           # closed → request_resume


func _enter_game_over() -> void:
	_gl.change_state(GameConst.GameStatus.GAME_OVER)
	_gl.game_over_screen.cancel_auto_countdown()  # 挂机倒计时钉住（断言期不自动重开）


func _collect_menu_handles() -> void:
	# 菜单全宽标签采集（按节点名与 Lore 文案真源定位——UI 文案不手抄）
	var menu: MenuScreen = _gl.menu_screen
	_menu_logo = menu._root.find_child("Logo", true, false) as Control
	for child in menu._root.get_children():
		var label := child as Label
		if label == null:
			continue
		if label.text == Lore.SUBTITLE:
			_menu_subtitle = label
		elif label.text == "竖屏弹幕防御 · Roguelike":
			_menu_footer = label
		elif Lore.MENU_LINES.has(label.text):
			_menu_announce.append(label)
	_menu_name_tag = menu.name_tag
	_check("C 前置：菜单全宽标签句柄齐（Logo/副标/公告行/name_tag/footer）",
		_menu_logo != null and _menu_subtitle != null and _menu_announce.size() >= 1
		and _menu_name_tag != null and _menu_footer != null,
		"announce=%d" % _menu_announce.size())


# ── 域B 直驱夹具（pkg3/r195_laser_pierce_cases 同款：确定性零掷骰） ───
func _setup_laser_world() -> void:
	_proj_pool = ProjectilePool.new()
	_proj_pool.name = "R195AdaptProjPool"
	tree.get_root().add_child(_proj_pool)
	_proj_pool.setup(&"r195_adapt_test", load(BALLISTIC_SCENE), 16)
	_homing_pool = ProjectilePool.new()
	_homing_pool.name = "R195AdaptHomingPool"
	tree.get_root().add_child(_homing_pool)
	_homing_pool.setup(&"r195_adapt_homing", load(HOMING_SCENE), 8)
	_laser_pool = LaserBeamPool.new()
	_laser_pool.name = "R195AdaptLaserPool"
	tree.get_root().add_child(_laser_pool)
	_laser_pool.setup(&"r195_adapt_laser", load(LASER_SCENE), 16)
	var ep := EnemyPool.new()
	ep.name = "R195AdaptEnemyPool"
	tree.get_root().add_child(ep)
	ep.setup(&"r195_adapt_enemy", load(ENEMY_SCENE), 32)
	_enemy_pool = ep
	_grid = SpaceGrid.new()
	_grid.configure(Vector2(720, 1280), 192.0)
	_pipeline = DamagePipelineStub.new()
	_alive_enemies.clear()


func _teardown_laser_world() -> void:
	_alive_enemies.clear()
	if _proj_pool != null:
		_proj_pool.free()
		_proj_pool = null
	if _homing_pool != null:
		_homing_pool.free()
		_homing_pool = null
	if _laser_pool != null:
		_laser_pool.free()
		_laser_pool = null
	if _enemy_pool != null:
		_enemy_pool.free()
		_enemy_pool = null
	_grid = null
	_pipeline = null


func _merge_dict(p_base: Dictionary, p_over: Dictionary) -> Dictionary:
	var out := p_base.duplicate(true)
	for key in p_over:
		out[key] = p_over[key]
	return out


func _make_weapon_data(p_pierce: int, p_segment: Dictionary) -> WeaponData:
	_wd_counter += 1
	var d := WeaponData.new()
	d.id = StringName("W_R195A_%d" % _wd_counter)
	d.display_name = "R195 adapt 测试武器 %d" % _wd_counter
	d.form = GameConst.WeaponForm.LASER
	d.crit_rate = 0.0                             # 零掷骰（确定性）
	d.crit_dmg = 2.0
	d.hitbox_r = 6.0
	for i in range(5):
		var ls := WeaponLevelStats.new()
		ls.base_atk = 10.0
		ls.rof = 8.0                              # 跳频 8/s → tick(0.26) 恰 2 跳
		ls.cd = 0.5
		ls.pierce = p_pierce                      # L 表 pierce（预算口径直驱）
		ls.pellets = 1
		d.upgrade_table.append(ls)
	d.laser = _merge_dict(d.laser, p_segment)
	return d


func _make_weapon(p_data: WeaponData) -> LaserWeapon:
	var w := LaserWeapon.new()
	w.name = "R195AdaptWeapon_%d" % _wd_counter
	tree.get_root().add_child(w)
	w.position = WEAPON_POS
	w.setup(p_data, null, {
		"pipeline": _pipeline,
		"projectile_pool": _proj_pool,
		"enemy_grid": _grid,
		"laser_pool": _laser_pool,
		"homing_pool": _homing_pool,
		"elemental": null,
	})
	return w


func _make_enemy_data(p_id: String, p_hp: float = 1000.0, p_hitbox_r: float = 14.0) -> EnemyData:
	var d := EnemyData.new()
	d.id = StringName(p_id)
	d.display_name = p_id
	d.hp_base = p_hp
	d.spd_base = 0.0                              # 静止敌（几何确定性）
	d.dmg_base = 8.0
	d.exp_base = 3.0
	d.tp_cost = 1.0
	d.hitbox_r = p_hitbox_r
	return d


func _spawn_enemy(p_data: EnemyData, p_pos: Vector2) -> Enemy:
	var e := _enemy_pool.acquire() as Enemy
	e.spawn(p_data, 1, 0)
	e.position = p_pos
	_alive_enemies.append(e)
	_grid.rebuild(_alive_enemies)
	return e


func _clear_enemies() -> void:
	# 探针间清场（同坐标复用防残血串扰；池归还 + 网格重建）
	for e in _alive_enemies:
		if is_instance_valid(e):
			_enemy_pool.release(e)
	_alive_enemies.clear()
	_grid.rebuild(_alive_enemies)


func _load_trait(p_path: String) -> TraitData:
	var res: Variant = load(p_path)
	return res as TraitData


## 轴向探针：N=pierce 武器 + POSITIONS 敌位 → try_fire → 每束 tick(0.26)×ticks 拍。
func _run_axis_probe(p_pierce: int, p_trait_paths: Array[String], p_positions: Array[Vector2],
		p_ticks: int = 1) -> Dictionary:
	var w := _make_weapon(_make_weapon_data(p_pierce, {"refract_beams": 0,
		"beam_length": 560.0}))
	for path in p_trait_paths:
		var td := _load_trait(path)
		_check("探针前置：真卡挂载（%s）" % path, td != null and w.attach_trait(td))
	var enemies: Array[Node2D] = []
	for i in p_positions.size():
		enemies.append(_spawn_enemy(_make_enemy_data("E_R195A_%d" % i), p_positions[i]))
	_check("探针前置：try_fire 维持主束", w.try_fire() and w.active_beams.size() >= 1)
	var beam := w.active_beams[0]
	for t in p_ticks:
		beam.tick(0.26)
	return {"weapon": w, "beam": beam, "enemies": enemies}


func _beam_end_global(p_beam: LaserBeam) -> Vector2:
	return p_beam.to_global(p_beam._line.get_point_position(1))


func _approx(p_a: float, p_b: float, p_tol: float = 0.001) -> bool:
	return absf(p_a - p_b) <= p_tol


# ── 支撑（源级 grep / 通用） ─────────────────────────────────────────
func _read_source(p_path: String) -> String:
	var fa := FileAccess.open(p_path, FileAccess.READ)
	if fa == null:
		return ""
	var text := fa.get_as_text()
	fa.close()
	return text


func _func_body(p_src: String, p_sig: String) -> String:
	# 提取函数体（sig 起至下一个顶层 func 前）——谓词体契约源级断言用
	var start := p_src.find(p_sig)
	if start < 0:
		return ""
	var next := p_src.find("\nfunc ", start + p_sig.length())
	if next < 0:
		next = p_src.length()
	return p_src.substr(start, next - start)


func _strip_comments(p_src: String) -> String:
	# 剥行注释（# 起至行尾）——谓词「零 _pre_boss 分支」按代码断言，注释文本不参与
	#（定案 §1.1 本就要求注释写明「零 _pre_boss 分支」字样）
	var out := ""
	for line in p_src.split("\n"):
		var hash_pos := line.find("#")
		out += (line.substr(0, hash_pos) if hash_pos >= 0 else line) + "\n"
	return out


func _list_gd_files(p_dir_path: String) -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open(p_dir_path)
	if dir == null:
		return out
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		var full := p_dir_path + "/" + name
		if dir.current_is_dir() and not name.begins_with("."):
			out.append_array(_list_gd_files(full))
		elif name.ends_with(".gd"):
			out.append(full)
		name = dir.get_next()
	dir.list_dir_end()
	return out


func _scan_dir(p_dir_path: String) -> String:
	# 目录下全部 .gd 源拼接（源级 grep 断言用）
	var out := ""
	for file in _list_gd_files(p_dir_path):
		out += _read_source(file)
	return out


func first_color_rect(p_root: Control) -> Control:
	# 未命名 dim（首个 ColorRect 子节点——game_over/card_select/shop 装配序契约）
	for child in p_root.get_children():
		if child is ColorRect:
			return child
	return null


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("PASS | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s %s" % [p_name, p_detail])
		print("FAIL | %s | %s" % [p_name, p_detail])

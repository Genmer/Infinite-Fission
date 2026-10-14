# tests/runner/export_data_cases.gd
# R194 导出数据链探针用例体（无独立 -s 入口文件——由 test_r194_mobile.gd 同套件链接运行）。
# 收编草探针用例价值（草稿文件按整案裁定 #6 于重导出前删除）：
#   · disc1_wave_probe_cases.gd A 组 → T2（缺 manifest 空注册表负路径节奏）
#   · disc1_wave_probe_cases.gd B 组 → T3②（有请求对照：构成非空 + 早清语义）
#   · tests/disc5_wave_rhythm_cases.gd / disc5_wave_rhythm_probe.gd → T6/T7 全链口径
# 覆盖（spawn 方案 P0 探针 T1/T2/T3/T4/T6/T7）：
#   T1 remap 三态正路径（纯 .tres / remap 独占判别态 / 真实+壳去重态 load_all）
#   T2 缺 manifest 负路径节奏（终态口径：零请求守卫走满窗+缓冲，区间断言）
#   T3 零请求守卫回归（window_left 不被钳 0.8 + 空构成计数——R198 r194-1 单源化：
#   wave_empty_composition 归 tick 守卫侧单源 / wave_composition_registry_empty 归回退分支）+ 有请求对照
#   T4 boot 空表闸双态（空 enemies → boot_fatal 停留 BOOT；满注册表 → MENU）
#   T6 横屏视口模拟（root 2400×1080 + 真数据 → 2s 内敌入逻辑域）
#   T7 时序鲁棒（1/144 节奏 + 零 delta 帧 + 3s 卡顿 → 波号偏差 ≤1；巨 delta clamp 语义）
extends RefCounted

const DT := 1.0 / 120.0                          # 120Hz 物理帧（游戏时钟步长）
const MAIN_SCENE := "res://scenes/main.tscn"
const ENEMY_SCENE := "res://scenes/combat/enemies/enemy.tscn"
const FULL_WINDOW_W1 := 18.4                     # w1 满窗（pkg2 锚定 18+0.4×1；空表公式路径）
const INTER_WAVE_BUFFER_S := 1.8                 # R26 波间缓冲 0.6 + 拾取缓冲 1.2

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null                         # 共享 GameLoop（main.tscn 实例化）
var _probe_dir: WaveDirector = null              # 组件级探针装配（T2/T3；成员变量承载——
var _probe_spawner: EnemySpawner = null          # GDScript 对象参数传引用值，out 参重绑不回传）
var _probe_birth: Array[int] = []


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_ensure_autoloads()
	_boot_game_loop()
	_test_t1_remap_dual_state()                   # T1（纯 registry 夹具，user:// 落盘）
	_test_t2_missing_manifest_rhythm()            # T2（组件级直驱）
	_test_t3_zero_request_guard()                 # T3（组件级 + 真池对照）
	_test_t4_boot_gate()                          # T4（负态子类 boot）
	_test_t6_landscape_viewport()                 # T6（GL 全链）
	_test_t7_timing_robustness()                  # T7（GL 全链，最重放末位）
	_teardown_game_loop()
	# 汇总
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)


func fail_count() -> int:
	return _fail


# ── 环境引导 ──────────────────────────────────────────────────────
func _ensure_autoloads() -> void:
	_check("autoload 就绪（EventBus/GameConfig/DebugStats）",
		EventBus != null and GameConfig != null and DebugStats != null)


func _boot_game_loop() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "R194ExportGameLoopUnderTest"
	tree.get_root().add_child(_gl)
	_check("前置：满注册表 Boot 进入 MENU + 致命清单空",
		_gl.boot_ready and _gl.state == GameConst.GameStatus.MENU and _gl.boot_fatal.is_empty())


func _teardown_game_loop() -> void:
	tree.paused = false
	RunSave.clear()
	if _gl != null:
		_gl.free()
		_gl = null


# ── T1：remap 三态正路径（spawn RC2 收编；修复环改为判别夹具） ──────
func _test_t1_remap_dual_state() -> void:
	print("── T1 remap 三态正路径 ──")
	var dir_plain := "user://r194_t1_plain"
	var dir_remap := "user://r194_t1_remap"
	var dir_payload := "user://r194_t1_payload"
	_wipe_dir(dir_plain)
	_wipe_dir(dir_remap)
	_wipe_dir(dir_payload)
	# validator 全绿字段（resist 恰 4 项 / hp>0 / tp>0 / hitbox_r∈(0,64]）
	var data := EnemyData.new()
	data.id = &"E_R194_T1"
	data.display_name = "E_R194_T1"
	data.hp_base = 100.0
	data.spd_base = 75.0
	data.dmg_base = 8.0
	data.exp_base = 3.0
	data.tp_cost = 1.0
	data.hitbox_r = 14.0
	data.resist = [0.0, 0.0, 0.0, 0.0]
	# ① 纯 .tres 态（编辑器态）：目录扫描 → load → 入表
	DirAccess.make_dir_recursive_absolute(dir_plain)
	var err := ResourceSaver.save(data, dir_plain + "/e1.tres")
	_check("T1 前置：夹具 .tres 落盘（ResourceSaver）", err == OK, "err=%d" % err)
	var reg_a := DataRegistry.new()
	reg_a.load_all(_write_enemy_manifest("user://r194_t1_manifest_a.cfg", dir_plain))
	_check("T1① 纯 .tres 目录 load_all → enemies ≥1 且 id 可查",
		reg_a.enemies.size() >= 1 and reg_a.get_enemy(&"E_R194_T1") != null,
		"size=%d" % reg_a.enemies.size())
	# ② remap 独占态（设备真形：目录内零 .tres、仅 X.tres.remap——旧包审计 .tres=0/
	#    .remap=350）。R194 修复环改判别夹具：修前「真实 .tres+壳并存」两态（剥壳在位/
	#    缺失）终态相同=对 RC2 回归永真；本态剥壳缺失时 .remap 名不过 .tres 过滤被整体
	#    跳过 → size 0，剥壳在位时 load(逻辑路径) 经 ResourceLoader .remap 透明回退
	#    （user:// 同样生效，探针实测）命中扫描域外载荷 → 入表。RC2 剥壳回归判别点。
	DirAccess.make_dir_recursive_absolute(dir_remap)
	DirAccess.make_dir_recursive_absolute(dir_payload)
	var err2 := ResourceSaver.save(data, dir_payload + "/e1.tres")
	_check("T1 前置：载荷 .tres 落盘（扫描域外）", err2 == OK, "err=%d" % err2)
	var rf := FileAccess.open(dir_remap + "/e1.tres.remap", FileAccess.WRITE)
	rf.store_string("[remap]\n\npath=\"%s/e1.tres\"\n" % dir_payload)
	rf.close()
	var reg_b := DataRegistry.new()
	reg_b.load_all(_write_enemy_manifest("user://r194_t1_manifest_b.cfg", dir_remap))
	_check("T1② remap 独占目录（零 .tres）load_all → enemies ≥1 且 id 可查"
		+ "（RC2 判别：剥壳缺失=.remap 跳过=size 0）",
		reg_b.enemies.size() >= 1 and reg_b.get_enemy(&"E_R194_T1") != null,
		"size=%d" % reg_b.enemies.size())
	_check("T1③ remap 独占恰 1 条（不重复入表）",
		reg_b.enemies.size() == 1, "size=%d" % reg_b.enemies.size())
	# ④ 剥壳+去重复合态（真实 .tres 与同 id 壳并存）：剥离→.tres 过滤→同 id 后者剔除，
	#    恰 1 条（钉去重路径：壳文件化后不得双入表）
	ResourceSaver.save(data, dir_remap + "/e1.tres")
	var reg_c := DataRegistry.new()
	reg_c.load_all(_write_enemy_manifest("user://r194_t1_manifest_c.cfg", dir_remap))
	_check("T1④ 真实 .tres+同 id 壳并存 → 恰 1 条（剥离后同 id 后者剔除）",
		reg_c.enemies.size() == 1 and reg_c.get_enemy(&"E_R194_T1") != null,
		"size=%d" % reg_c.enemies.size())
	_wipe_dir(dir_plain)
	_wipe_dir(dir_remap)
	_wipe_dir(dir_payload)
	DirAccess.remove_absolute("user://r194_t1_manifest_a.cfg")
	DirAccess.remove_absolute("user://r194_t1_manifest_b.cfg")
	DirAccess.remove_absolute("user://r194_t1_manifest_c.cfg")


# ── T2：缺 manifest 负路径节奏（组件级直驱，收编 disc1 A 组） ───────
func _test_t2_missing_manifest_rhythm() -> void:
	print("── T2 缺 manifest 负路径节奏 ──")
	# R194 契约变更注（勿回抄修前口径）：修前此路径 0.8s 早清 + 1.8s 缓冲 ≈ 315±3 步/波
	# 静默狂涨（disc1 探针实测 6.5s 爬 ≥3 波零怪）；修后 P0-5 零请求守卫禁用早清钳 →
	# 走满窗（w1=18.4s=2208 步）+ 波间缓冲 1.8s=216 步 ≈ 2424 步/波。区间断言按终态满窗带。
	var reg_empty := DataRegistry.new()           # 空注册表（= APK 缺 manifest.cfg 下游终态）
	_setup_components(reg_empty)
	var dir := _probe_dir
	var spawner := _probe_spawner
	var birth_steps := _probe_birth
	dir.start_wave(1)
	var ever_nonzero := false
	var last_wave := 1
	for i in range(780):                          # 6.5s 游戏时（disc1 A 组同口径）
		dir.tick(DT)
		if spawner.queue_count() + spawner.active_count() > 0:
			ever_nonzero = true
		if dir.current_wave != last_wave:
			last_wave = dir.current_wave
			birth_steps.append(i + 1)
	_check("T2① 全程零怪（queue+active 恒 0，降级不崩溃）", not ever_nonzero)
	_check("T2② 6.5s 波次不再狂涨（终态 ≤2；修前该路径 ≥3）", dir.current_wave <= 2,
		"wave=%d" % dir.current_wave)
	# 续驱至首个换波 → 稳态波间隔（满窗 + 缓冲 ≈ 2424 步，区间 ±21）
	var guard := 0
	while dir.current_wave < 2 and guard < 3000:
		dir.tick(DT)
		guard += 1
		if dir.current_wave != last_wave:
			birth_steps.append(780 + guard)
	var gap := birth_steps[birth_steps.size() - 1] if birth_steps.size() > 0 else -1
	var expected_gap := int(round((FULL_WINDOW_W1 + INTER_WAVE_BUFFER_S) / DT))
	_check("T2③ 零请求波走满窗+缓冲（步差 %d ∈ [%d, %d]，非 315 早清带）"
		% [gap, expected_gap - 21, expected_gap + 21],
		gap >= expected_gap - 21 and gap <= expected_gap + 21, "gap=%d" % gap)
	_teardown_components()


# ── T3：零请求守卫回归 + 有请求对照（R92 语义原样） ────────────────
func _test_t3_zero_request_guard() -> void:
	print("── T3 零请求守卫 + 有请求对照 ──")
	# ① 零请求波：早清钳禁用（走满窗）+ 计数（R198 r194-1 单源化改写，契约变更）
	_setup_components(DataRegistry.new())
	var dir := _probe_dir
	var spawner := _probe_spawner
	var counter0: int = DebugStats.get_counter(&"wave_empty_composition")
	var counter_reg0: int = DebugStats.get_counter(&"wave_composition_registry_empty")
	dir.start_wave(1)
	for i in range(30):                           # 0.25s：修前此时 window 已被钳到 0.8
		dir.tick(DT)
	_check("T3① 零请求波 window_left 不被钳 0.8（≥ 满窗−驱动时 0.25）",
		dir.window_left >= FULL_WINDOW_W1 - 0.3,
		"window_left=%.3f" % dir.window_left)
	# R198 契约变更（r194-1 空波计数单源化）：本场景 = 空注册表 → 公式回退分支
	# （WaveDirector._roll_composition 注册表无敌人）+ tick 零请求守卫两条观察点。
	# 修前回退分支复用 wave_empty_composition 与守卫双写同名计数器——本窗口内该计数
	# +2/波；修后回退分支改独立计数器 wave_composition_registry_empty，单源证为：
	# ①回退分支计数 ≥1（走 :250 分支实锚）；②wave_empty_composition 恰 +1（守卫侧
	# 每波一次旗生效，回退分支不再复写——修前该窗口内为 +2）。
	_check("T3①b wave_composition_registry_empty 计数 ≥1（回退分支独立观察点，R198 单源化）",
		DebugStats.get_counter(&"wave_composition_registry_empty") >= counter_reg0 + 1,
		"%d→%d" % [counter_reg0, DebugStats.get_counter(&"wave_composition_registry_empty")])
	_check("T3①c wave_empty_composition 恰 +1（守卫侧单源每波一次，修前双写 +2）",
		DebugStats.get_counter(&"wave_empty_composition") == counter0 + 1,
		"%d→%d" % [counter0, DebugStats.get_counter(&"wave_empty_composition")])
	_teardown_components()
	# ② 有请求对照：合法敌数据 + 真实敌池 → 构成入队 → 秒清 → 早清仍钳 0.8s（R92 原样）
	var reg := DataRegistry.new()
	reg.enemies[&"E_R194_T3"] = _make_enemy_data(&"E_R194_T3", 10.0, 1.0)
	_setup_components(reg)
	var dir2 := _probe_dir
	var spawner2 := _probe_spawner
	var pool := EnemyPool.new()
	pool.name = "R194T3EnemyPool"
	tree.get_root().add_child(pool)
	pool.setup(&"r194_t3", load(ENEMY_SCENE), 64)
	spawner2.pool = pool
	dir2.start_wave(1)
	_check("T3② 有请求波构成入队（E1 注入 → queue ≥10，公式 14+3.2×1 口径）",
		spawner2.queue_count() >= 10, "queue=%d" % spawner2.queue_count())
	var spawn_guard := 0
	while (not spawner2.queue_empty() or spawner2.active_count() == 0) and spawn_guard < 120:
		dir2.tick(DT)                             # 8/帧节流出队 → 在场敌就位
		spawn_guard += 1
	_check("T3②b 请求全部生成（queue 空 + 在场 ≥1）",
		spawner2.queue_empty() and spawner2.active_count() >= 1,
		"queue=%d active=%d" % [spawner2.queue_count(), spawner2.active_count()])
	# 组件级世界无 GL 池归属——先摘除 GL spawner 的 enemy_killed 监听（防其把本探针
	# 外来敌释放进 GL 真池——拒绝归还告警噪音），用毕即复接
	EventBus.enemy_killed.disconnect(Callable(_gl.spawner, "_on_enemy_killed"))
	for e in spawner2.active.duplicate():         # 秒清（R92 口径：波内全清）
		if is_instance_valid(e):
			(e as Enemy).apply_damage(999999.0)   # enemy_killed → 归还 + active 清
	dir2.tick(DT)
	EventBus.enemy_killed.connect(Callable(_gl.spawner, "_on_enemy_killed"))
	_check("T3③ 有请求波秒清 → 早清仍钳 ≤0.8s（R92 语义原样，R194 守卫不误伤）",
		dir2.window_left <= 0.81 and dir2.window_left > 0.6,
		"window_left=%.3f" % dir2.window_left)
	_teardown_components()
	pool.free()


# ── T4：boot 空表闸双态（spawn RC3 收编；修复环改闸方法直驱） ────────
func _test_t4_boot_gate() -> void:
	print("── T4 boot 空表闸双态 ──")
	# ① 正态：满注册表 → 正常 boot 到 MENU（共享 GL 已 boot，复核）
	_check("T4① 满注册表 → 正常 boot 到 MENU（boot_fatal 空）",
		_gl.state == GameConst.GameStatus.MENU and _gl.boot_fatal.is_empty())
	# ② 负态：boot 空表闸真实触发。修前探针以动态子类覆写 _scan_category 拦截扫描——
	# 死路双症：_scan_category 属 DataRegistry（game_loop.gd 无此函数 → 子类源码
	# Parse Error），且 _boot_load_data 直 DataRegistry.new() 构造 → 覆写永不可达；
	# s.new() 返 null 致负态断言零执行、run() 继续跑（套件可假绿）。R194 修复环改为
	# 闸方法直驱（game_loop.gd _boot_check_empty_registry 抽方法，语义不变）：输入用
	# 真实扫描终态（零类目 manifest → 空注册表，谓词口径同 r194_mobile_cases 闸谓词），
	# 裸 GameLoop.new() 不入树（_ready 全链 boot 不需要，类头自测口径）→ 闸置位
	# boot_fatal + 建 boot_error 屏 + 计数，状态停留 BOOT。
	var gl2: GameLoop = GameLoop.new()
	gl2.name = "R194BootGateUnderTest"
	var manifest := "user://r194_t4_empty_manifest.cfg"
	var cfg := ConfigFile.new()
	cfg.save(manifest)                            # 零类目 manifest（= 数据全缺下游客态）
	var reg_empty := DataRegistry.new()
	reg_empty.load_all(manifest)
	gl2.registry = reg_empty
	gl2._boot_check_empty_registry()
	var st: int = gl2.state
	var fatal: Array = gl2.boot_fatal
	_check("T4② 空 enemies → boot_fatal 非空 + 停留 BOOT（拒绝入局，唯一合法迁移不可达）",
		st == GameConst.GameStatus.BOOT and not fatal.is_empty(),
		"state=%d fatal=%s" % [st, str(fatal)])
	_check("T4③ boot_empty_registry 计数 ≥1（DebugStats 诊断）",
		DebugStats.get_counter(&"boot_empty_registry") >= 1,
		str(DebugStats.get_counter(&"boot_empty_registry")))
	gl2.free()
	DirAccess.remove_absolute(manifest)


# ── T6：横屏视口模拟（root 2400×1080，收编 disc5 全链口径） ────────
func _test_t6_landscape_viewport() -> void:
	print("── T6 横屏视口模拟 ──")
	_gl.state = GameConst.GameStatus.MENU
	_gl.call(&"start_run")                        # 真数据（满注册表）
	var sz0: Vector2i = tree.root.size
	tree.root.size = Vector2i(2400, 1080)         # 横屏屏比（letterbox 观感降级≠机制破坏）
	var inside := 0
	var outside := 0
	for i in range(240):                          # 2s 游戏时
		_gl.player.hp = _gl.player.max_hp          # 每帧回血（排除接触伤害死亡干扰）
		_gl._physics_process(DT)
		if _gl.state == GameConst.GameStatus.LEVEL_UP:
			_gl.card_select_ui.choose(0)           # 击杀残余 xp 弹升即选（pkg5 _drive_safe 口径）
	var logic_rect := Rect2(0.0, 0.0, 720.0, 1280.0)
	var tolerance := logic_rect.grow(50.0)        # 生成点屏外余量 40px 带（SPAWN_OFFSCREEN）
	for e in _gl.spawner.active:
		var pos: Vector2 = (e as Node2D).global_position
		if logic_rect.has_point(pos):
			inside += 1
		if not tolerance.has_point(pos):
			outside += 1
	_check("T6① 横屏 2400×1080 下敌人入场（active>0）", _gl.spawner.active_count() > 0,
		"active=%d" % _gl.spawner.active_count())
	_check("T6② 2s 内敌入逻辑域 (0,0)-(720,1280)（%d/%d 在域内）"
		% [inside, _gl.spawner.active_count()], inside >= 1, "inside=%d" % inside)
	_check("T6③ 全员在逻辑域±50px 生成余量带内（spawn 全在 res_logic 空间，零窗口几何读）",
		outside == 0, "outside=%d" % outside)
	tree.root.size = sz0                          # 视口还原
	_gl.state = GameConst.GameStatus.MENU         # 直接置位（quit_to_menu 仅 PAUSED 合法）


# ── T7：时序鲁棒 + 巨 delta clamp（收编 disc5 节奏探针） ───────────
func _test_t7_timing_robustness() -> void:
	print("── T7 时序鲁棒 + 巨 delta clamp ──")
	# 不可击杀化：注册表敌人 hp ×1e6 → 杀伤/早清路径退出，波次推进唯一驱动 = 硬帽台阶
	#（时间主导 → 匀速 vs 抖动基线偏差可确定断言）；用例末还原。
	var saved_hp: Dictionary = {}
	for id in _gl.registry.enemies:
		var ed := _gl.registry.enemies[id] as EnemyData
		saved_hp[id] = ed.hp_base
		ed.hp_base = ed.hp_base * 1000000.0
	var wd: WaveDirector = _gl.wave_director
	var hard_cap := _window_for_wave(wd, 1) + WaveDirector.HARD_CAP_BONUS
	var run_frames := int(ceil((hard_cap + 1.0) / DT))   # 基线恰好越过首个硬帽台阶
	# ① 基线：1/120 匀速手驱。零杀伤确定性：每帧钉住武器冷却（不开火→零击杀→零 xp→
	# 零 LEVEL_UP）——波次推进唯一驱动 = 硬帽台阶（纯时间主导，两节奏可确定对比）
	_gl.state = GameConst.GameStatus.MENU
	_gl.call(&"start_run")
	for i in range(run_frames):
		_gl.player.hp = _gl.player.max_hp
		_pin_weapons_cold()
		_gl._physics_process(DT)
		if _gl.state == GameConst.GameStatus.LEVEL_UP:
			_gl.card_select_ui.choose(0)           # 自爆/闪现类敌自亡掉落的 xp 弹升即选（防冻结劫持）
	var wave_uniform: int = wd.current_wave
	_check("T7① 匀速基线越过硬帽台阶（wave ≥2，hard_cap=%.1fs）" % hard_cap, wave_uniform >= 2,
		"wave=%d state=%d win=%.2f" % [wave_uniform, _gl.state, wd.window_left])
	# ② 零 delta 帧：推进为零（窗口/波号均不动）
	var wave_z: int = wd.current_wave
	var win_z: float = wd.window_left
	for i in range(5):
		_gl.player.hp = _gl.player.max_hp
		_pin_weapons_cold()
		_gl._physics_process(0.0)
	_check("T7② 零 delta 帧 ×5 → 波号/窗口零推进",
		wd.current_wave == wave_z and is_equal_approx(wd.window_left, win_z),
		"dwave=%d dwin=%.4f" % [wd.current_wave - wave_z, wd.window_left - win_z])
	_gl.state = GameConst.GameStatus.MENU
	_gl.call(&"start_run")
	# ③ 抖动：1/144 手动节奏 + 中途单帧 3.0s 卡顿（clamp 语义：至多消耗 0.25s）
	var clamped0: int = DebugStats.get_counter(&"game_delta_clamped")
	var wave_before_hitch := -1
	var wave_after_hitch := -1
	var hitched := false
	var consumed := -1.0
	for i in range(run_frames):
		_gl.player.hp = _gl.player.max_hp
		_pin_weapons_cold()
		if i == int(run_frames / 2.0) and not hitched:
			hitched = true
			wave_before_hitch = wd.current_wave
			var win_before: float = wd.window_left
			_gl._physics_process(3.0)              # 3s 卡顿单帧（P2-10 clamp 消耗 ≤0.25s）
			consumed = win_before - wd.window_left
			wave_after_hitch = wd.current_wave
			continue
		_gl._physics_process(1.0 / 144.0)
		if _gl.state == GameConst.GameStatus.LEVEL_UP:
			_gl.card_select_ui.choose(0)           # 弹升即选（与基线同口径）
	var wave_jagged: int = wd.current_wave
	_check("T7③ 巨 delta clamp：单帧 3.0s 实耗 ≤0.25s（window 差 %.4f，P2-10）" % consumed,
		consumed > 0.0 and consumed <= 0.25 + 0.0001, "consumed=%.4f" % consumed)
	_check("T7④ game_delta_clamped 计数 ≥1（%d→%d）"
		% [clamped0, DebugStats.get_counter(&"game_delta_clamped")],
		DebugStats.get_counter(&"game_delta_clamped") >= clamped0 + 1)
	_check("T7⑤ hitch 单帧至多叠 1 波（%d→%d）" % [wave_before_hitch, wave_after_hitch],
		hitched and wave_after_hitch - wave_before_hitch <= 1,
		"hitched=%s dw=%d" % [str(hitched), wave_after_hitch - wave_before_hitch])
	_check("T7⑥ 抖动（1/144+零帧+3s 卡顿）波号与匀速基线偏差 ≤1（%d vs %d）"
		% [wave_jagged, wave_uniform], absi(wave_jagged - wave_uniform) <= 1,
		"jagged=%d uniform=%d" % [wave_jagged, wave_uniform])
	# 还原注册表（本套件末位用例，防共享资源残留）
	for id in saved_hp:
		(_gl.registry.enemies[id] as EnemyData).hp_base = saved_hp[id]
	_gl.state = GameConst.GameStatus.MENU         # 直接置位（quit_to_menu 仅 PAUSED 合法）


func _pin_weapons_cold() -> void:
	# T7 专用：每帧钉冷却 → 武器整段不开火（零击杀/零 xp/零弹升，时间主导节拍）
	for w in _gl.player.weapon_slots:
		if w != null:
			(w as WeaponBase).cooldown_left = 1.0


# ── 组件级装配/拆卸（disc1 探针同构：WaveDirector + EnemySpawner 直驱） ──
func _setup_components(p_registry: DataRegistry) -> void:
	var sp := EnemySpawner.new()
	sp.name = "R194ProbeSpawner_%d" % tree.get_root().get_child_count()
	tree.get_root().add_child(sp)
	var wd := WaveDirector.new()
	wd.name = "R194ProbeDirector_%d" % tree.get_root().get_child_count()
	tree.get_root().add_child(wd)
	wd.spawner = sp
	wd.registry = p_registry
	sp.registry = p_registry                      # spawner 侧解析同注入（漏注 → 请求全弃）
	_probe_dir = wd
	_probe_spawner = sp
	_probe_birth = []


func _teardown_components() -> void:
	# 立即 free（非 queue_free）——套件内无帧迭代，queue_free 件保持 EventBus 监听
	# 存活到套件尾，会污染后续探针（上波 director 重入 start_wave 等）
	if _probe_dir != null and is_instance_valid(_probe_dir):
		_probe_dir.free()
	if _probe_spawner != null and is_instance_valid(_probe_spawner):
		_probe_spawner.free()
	_probe_dir = null
	_probe_spawner = null


func _window_for_wave(p_wd: WaveDirector, p_wave: int) -> float:
	return float(p_wd.call(&"_window_for_wave", p_wave))


func _make_enemy_data(p_id: StringName, p_hp: float, p_tp: float) -> EnemyData:
	# 字段口径同 pkg2_cases.gd _make_enemy_data（validator 全绿）
	var e := EnemyData.new()
	e.id = p_id
	e.display_name = String(p_id)
	e.hp_base = p_hp
	e.spd_base = 75.0
	e.dmg_base = 8.0
	e.exp_base = 3.0
	e.tp_cost = p_tp
	e.hitbox_r = 14.0
	e.resist = [0.0, 0.0, 0.0, 0.0]
	return e


func _write_enemy_manifest(p_path: String, p_dir: String) -> String:
	var cfg := ConfigFile.new()
	cfg.set_value("directories", "enemies", p_dir)
	cfg.save(p_path)
	return p_path


func _wipe_dir(p_dir: String) -> void:
	var d := DirAccess.open(p_dir)
	if d == null:
		DirAccess.remove_absolute(p_dir)
		return
	for f in d.get_files():
		DirAccess.remove_absolute(p_dir + "/" + String(f))
	DirAccess.remove_absolute(p_dir)


# ── 支撑 ──────────────────────────────────────────────────────────
func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("PASS | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s %s" % [p_name, p_detail])
		print("FAIL | %s | %s" % [p_name, p_detail])

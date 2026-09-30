# R191 整案设计：构筑可读性 + 镜面/棱镜修复 + 元素反应通道 + 图鉴反应页 + 成就扩展 + 回旋尺寸

- 日期：2026-09-26
- 来源：R191 用户反馈七项（FEEDBACK_TRACKER.md:391「二bb、R191 登记」），经七路并行探索与仲裁后由方案统合策划收敛为整案
- 工程根：`repo/`（Godot 4.3；引擎二进制在工作区根 `tools/Godot_v4.3-stable_win64_console.exe`）
- 本文路径约定：除特别说明外，文件路径均相对 `repo/`；headless 命令均从工作区根执行，形如
  `tools/Godot_v4.3-stable_win64_console.exe --headless --path repo -s tests/runner/<suite>.gd`

---

## 0. 统合结论（TL;DR）

七项定案 **全部 implement，无 noop**。七项分属七个互不重叠的文件域，仅五处共享文件
（theme.gd / hud.gd / menu_screen.gd / verify_feedback_cases.gd / FEEDBACK_TRACKER.md）收拢进一个共享组，
另加 game_const.gd（反应文案单源）与其配套新测试并入共享组。跨组联动共五条，全部写进对应组任务
（见 §6）。全批共享系统改动四条（见 §3），其中「texture_factory 小棱镜纹理」经复核判定**本批不需要**
（muzzle 复用现成 `TextureFactory.ice_shard()`）。

本统合在会话内实跑/实读验证的关键事实（其余均转抄自各仲裁并逐条给出锚点，见 §9）：
- `tools/Godot_v4.3-stable_win64_console.exe --headless --path repo -s tests/runner/test_mech_gate.gd`
  → **PASS 33 / FAIL 0，EXIT=0**（本机工具链可用，与 rxn 仲裁基线一致）。
- `qa_arb_w10_baseline.log` 尾部：**PASS 619 / FAIL 2（共 621 项）**，两处 FAIL 恰为既知
  「感电：垂直落雷挂件就位」「点燃：余烬光晕 + 火苗 ×4」视觉件（回旋刃项基线成立）。
- 全部 26 个既有涉改文件逐一 `ls` 存在；8 个新增测试文件确认**尚不存在**（待建）。
- 关键代码锚点逐一 grep 复核：theme.gd:55 `theme()`、:110 `panel_style`、:166 `label_sticker`；
  hud.gd:1248-1249 `_sticker_panel(..., p_tip)`、:1251 R10 注释、10 个调用点 :853/899/946/967/985/995/1057/1089/1121/1178；
  pause_overlay.gd:370 `_make_weapon_section`；game_const.gd:78 `weapon_note`、:140 `ReactionType`（恰 3 成员）；
  weapon_orbit_avatars.gd:16 `MUZZLE_REACH`、:118 `_entries_of`、:139 `avatar_global`、:155 枪口前伸返回式；
  ballistic_weapon.gd:46 `is_mirror_image` 字段、:65 `_show_muzzle_flash`；
  laser_weapon.gd:170 `tick_atk: get_current_atk()`（裸 L 表值实锤）；
  mirror_image.gd:68 `apply_state`；mirror_weapon.gd:39 `setup`；
  player.gd:845 `mirror.set("copy_tint", Color(0.82,0.92,1.0))`（Color→bool no-op 实锤；:822 存在 `p_copy.set("copy_tint", true)` bool 先例）；
  projectile_base.gd:870/:873 回旋刃 `×3.4` 实锤；
  trait_effect_elemental.gd:17-20 ON_SPAWN 无条件整写、:25-37 `_emit_attach_request` 单槽整写实锤；
  menu_screen.gd:515 现行 tabs 表 `[["怪物",36],["武器",244],["词条",452]]`、tab.size(160,54)（反应页任务按
  126 宽重排后末沿 486+126=612 保持不变）；
  meta_manager.gd:26 `const ACHIEVEMENTS`、:598 `_build_ach_buckets`、:617 `_counter_value`、:671 `_check_achievements`；
  verify_feedback_cases.gd:758-759 成就行数断言实文；
  r187_rework_cases.gd 非类型化 `[]` 实参实测在 **:2268/:2271/:2273**（仲裁原文 :2266/2270/2272 有 1-2 行漂移，缺陷本身属实）。
- FEEDBACK_TRACKER.md:391 R191 登记表 #1~#7 全部 ⬜，落点描述与七项定案一一对应。

---

## 1. 用户反馈 ↔ 定案映射

| R191# | 用户原话摘要 | 定案 | verdict | 核心落点 |
|---|---|---|---|---|
| 1 | 点武器没显示武器说明；外面透明黑底字看不清 | tips | implement | StickerTheme 全局 tooltip 样式 + 构筑详情卡补机制句 + hud 删 `_sticker_panel` 死路径 |
| 2 | 棱镜复制加特林枪口不在镜子/加特林身上；发射口要有小棱镜火花 | muzzle | implement | `avatar_global` 父链别名查册 + 镜面开火冰渣火花 |
| 3 | 棱镜复制激光是正常的吗 | mirror_laser | implement | 束伤补 meta 轴 + 七张 W4 束卡锁 W4 + 缓存失效 + 束染修复 + 测试脚本修复 |
| 4 | 选了火和电没反应（普通难度没开？）；只有超导生效 | rxn | implement | 附着双覆写根因修复（来源侧）+ 近战死卡上架门 + 文案澄清 |
| 5 | 图鉴开元素反应展示页（反应/效果/字体，丰富点） | codex_rxn | implement | 图鉴第 4 页签「反应」+ `GameConst.reaction_note` 单源 + 反应字体预览 |
| 6 | 成就也搞个几千种？ | achv | implement | 裁定 ~128 条（硬区间 120~200）阶梯架构 + 写风暴/UI/ 三修 |
| 7 | 回旋武器太小快看不见 | boomerang | implement | 表现层单杠杆 ×3.4→×5.0，命中盒不变 |

用户问题「普通难度没开？」为**误判**（rxn 仲裁实证：结算核每帧无条件运行，唯一门是大关门且只收口卡架来源侧——
详见 §4.4）；「几千种成就」为**规模裁减**（achv 仲裁：~128 条 + 500 条架构预留，见 §4.6）。

---

## 2. 互不冲突性（文件矩阵）

七项涉改文件交集核查（统合时逐一比对）：

| 文件 | tips | muzzle | mirror_laser | rxn | codex_rxn | achv | boomerang | 归组 |
|---|---|---|---|---|---|---|---|---|
| scripts/ui/theme.gd | 改 | | | | | | | G1 共享 |
| scripts/ui/hud.gd | 改 | | | | | 改 | | G1 共享 |
| scripts/ui/menu_screen.gd | | | | | 改 | 改 | | G1 共享 |
| scripts/core/game_const.gd | | | | | 改 | | | G1 共享 |
| tests/runner/verify_feedback_cases.gd | | | | | | 改 | 改(新增断言) | G1 共享 |
| FEEDBACK_TRACKER.md | | 改(勾选) | | | 改(勾选) | | | G1 共享 |
| scripts/ui/pause_overlay.gd | 改 | | | | | | | G2 tips |
| scripts/entities/player/weapon_orbit_avatars.gd | | 改 | | | | | | G3 muzzle |
| scripts/combat/weapon/ballistic_weapon.gd | | 改 | | | | | | G3 muzzle |
| scripts/combat/weapon/laser_weapon.gd | | | 改 | | | | | G4 mirror_laser |
| scripts/combat/weapon/mirror_weapon.gd | | | 改 | | | | | G4 mirror_laser |
| scripts/combat/weapon/mirror_image.gd | | | 改 | | | | | G4 mirror_laser |
| scripts/entities/player/player.gd | | | 改(:845) | | | | | G4 mirror_laser |
| resources/traits/MEC_*.tres ×7 | | | 改 | | | | | G4 mirror_laser |
| tests/runner/r187_rework_cases.gd | | | 改 | | | | | G4 mirror_laser |
| tests/runner/w5_mirror_cases.gd | | | 改 | | | | | G4 mirror_laser |
| scripts/combat/trait/builtin/trait_effect_elemental.gd | | | | 改 | | | | G5 rxn |
| resources/traits/ELE_*.tres ×4 | | | | 改 | | | | G5 rxn |
| scripts/meta/meta_manager.gd | | | | | | 改 | | G6 achv |
| scripts/combat/projectile/projectile_base.gd | | | | | | | 改 | G7 boomerang |
| 新增 8 个测试文件 | 2 | 2 | — | 2 | 2 | — | — | 随各行为主组 |

说明：muzzle 与 mirror_laser 同属镜面域但文件零交集（化身册/弹道闪光 vs 激光/棱镜壳/玩家染源），
可并行；G3、G4 各自回归都跑 `test_w5_mirror.gd`，合并序上后跑者以先跑者落地后状态为准（顺序见 §6）。
muzzle 只**读** player.gd:589-599（回退语义），不改；G4 的 player.gd 改动仅 :845 一行——两者无写冲突。

---

## 3. 共享系统改动（sharedChanges）

1. **StickerTheme tooltip 全局样式**（tips 改1 → theme.gd）：`theme()` 内补 `TooltipPanel`/`TooltipLabel`
   全局条目。取色只经 PopPalette，取样式只经现成 `panel_style(10.0, 2, true)` 工厂（theme.gd:110）。
   一处生效、全 UI 自动继承：今日可见变化面仅 hud.gd:777/797 与 menu_screen.gd:855 三处活 tooltip；
   未来新增 tooltip_text 控件（含图鉴反应页若加 hover 说明）零成本继承。
2. **texture_factory 小棱镜纹理：判定不需要**。muzzle 镜面火花复用现成
   `TextureFactory.ice_shard()`（texture_factory.gd:1193-1204，惰性缓存零新增贴图）；真冰青激光束色需
   LaserBeam 增 tint 通道，属独立打磨项，本批不做（mirror_laser 缺陷④只修 bool 灰染通道）。
   本批 texture_factory.gd 与 weapon_orbit_avatars.gd 的 W10 图标链零改动（boomerang 验收含此断言）。
3. **图鉴 tab 重排 4 页签**（codex_rxn → menu_screen.gd:515-523）：`[["怪物",36],["武器",186],["词条",336],["反应",486]]`、
   tab.size 宽 160→126；末沿 486+126=612 与右距 36 均不变；显隐（:462-463）与高亮（:719-723）字典遍历自动继承零改动。
4. **成就面板类别页签 + 分页**（achv → menu_screen.gd）：复用图鉴 `_codex_tabs` 按钮先例，页容量 24，
   行构建复用现有 :732-759 逻辑不动。

---

## 4. 分项定案

### 4.1 tips｜构筑可读性三改（R191 #1）

**结论 implement。** 两处用户实测缺陷均在代码证实：
- 缺陷①：构筑详情卡武器段 `_make_weapon_section`（pause_overlay.gd:370-510）零 `GameConst.weapon_note`
  调用——全仓 weapon_note 消费点仅 player.gd:374 / hud.gd:767 / menu_screen.gd:592,853。
- 缺陷②：`StickerTheme.theme()`（theme.gd:55-70）仅 Button/Label/default_font 条目，全仓无
  TooltipPanel/TooltipLabel 覆盖，project.godot 无 [gui] 自定义主题 → 引擎 tooltip 走默认样式
  （黑底小字对比度差）。仓库侧前提已核实：3 处活 tooltip 全在挂主题子树内（hud.gd:777/797 →
  content:734-739 → BuildPanel:1081-1088 → root themed:893；menu_screen.gd:855 → _panel_list →
  _panel_root themed:489）。引擎侧「弹层并入被悬停控件主题链」机制依据探索组对 4.3 upstream
  viewport.cpp/theme_owner.cpp 的源码阅读（本机无 Godot 源码树，未运行复核；工程级生效由验收 1 兜底）。

**改动设计：**
- 改1（theme.gd）：`theme()` 在 `_theme=t`（:69）前补 `var tsb := panel_style(10.0, 2, true)`
  （白实底 PANEL + 藏青描边 2px + 投影），显式补内容边距 left/right=12.0、top=6.0、bottom=8.0
  （panel_style 不设内容边距，不补则文字贴边）；随后
  `t.set_stylebox("panel","TooltipPanel",tsb)`、`t.set_color("font_color","TooltipLabel",PopPalette.INK)`、
  `t.set_font("font","TooltipLabel",font())`、`t.set_font_size("font_size","TooltipLabel",20)`、
  `t.set_constant("outline_size","TooltipLabel",0)`（对齐 Label 条目 outline 0 口径 :68）。
  无需 project.godot（gui/theme/custom 需磁盘 .tres，与全代码构建主题不符），无需 set_type_variation。
- 改2（pause_overlay.gd）：`_make_weapon_section` 内 wdata（:372）取得后
  `var note := GameConst.weapon_note(String(wdata.get("id")) if wdata != null else "")`
  （照抄 hud.gd:767 防御口径）；head（:378）custom_minimum_size 576×78 → note 非空 576×100、空则维持 78
  （未知 id/自定义武器不加行，同 hud.gd:769 空句护栏）；head 内 wstats（y40-60）下方新增一行
  Label（label_sticker 12pt PopPalette.INK_SOFT），text=note 原句，position (58,62)、size (508,34)、
  autowrap_mode=AUTOWRAP_WORD_SMART、mouse_filter IGNORE——最长句 W10≈27 全角字符≈330px@12pt < 508px
  单行足用，两行预算防溢出；布局代价 ≤7×22px≈154px 由 DetailsScroll 576×712（:198-208）纵滚容纳。
  文案逐字取 `GameConst.weapon_note`（game_const.gd:78-103）真源，禁止 UI 手抄改写——
  r187_rework_cases.gd:320/425 已把 W5/W8 读感锁死在源上。
- 改3（hud.gd）：`_sticker_panel` p_tip 参数与分支（hud.gd:1248-1262）整段删除——:1257-1259 设
  tooltip_text+MOUSE_FILTER_STOP 后被 :1260 无条件 IGNORE 覆盖 → 永不触发的死路径；10 个调用点
  （:853/899/946/967/985/995/1057/1089/1121/1178）全 4 参，签名收缩零调用点改动；同步删 :1251 R10 过时注释。
  否决「修顺序让 STOP 生效」备选——无调用方传 tip，全局样式重做后留永不触发的假活口反而误导。

**边界（不做）**：①HUD R13 自绘 HoverCard（hud.gd:1102-1118）不动——另一套系统、实底已可读；
  ②不改 tooltip 触发行为/延迟；③零新增数据键/ID，DataValidator 不涉及，存档层不动，既有断言不放宽。
**探索组口径更正**：主题挂载 card_select_ui.gd 实际路径为 scripts/cards/card_select_ui.gd:239
  （scripts/ui/ 下无此文件）；全局生效结论不变（10 处挂载全用同一 Theme 单例）。

### 4.2 muzzle｜镜面开火枪口锚点 + 镜面火花（R191 #2）

**结论 implement。** 根因（复核证实）：镜面开火经 inner.try_fire → `muzzle_position` →
`_avatar_muzzle`（weapon_base.gd:316-321）→ `player.weapon_muzzle_global`（player.gd:589-599）→
`avatar_global` 用 `entries.find(p_weapon)`（weapon_orbit_avatars.gd:148-150）。`_entries_of`
（:118-136）只收 weapon_slots+_summon_copies+_mirror_images（**外层包装体**），inner 是外层 child
（mirror_image.gd:52）不入册 → find 恒 -1 返 null → 回退 inner.global_position=静态菱形标记位
（mirror_image.gd:62），而可见化身在旋转环（weapon_orbit_avatars.gd:55-63）——两环两角永不合拢。
avatar_global 全厂唯一消费方就是 weapon_muzzle_global（weapon_base.gd:319-320 与
weapon_orbit_cases.gd:146 两处，grep 证实），波及面精确。

**改动设计：**
- 修①（weapon_orbit_avatars.gd avatar_global :139-155）：`entries.find(p_weapon)<0` 时沿
  `p_weapon.get_parent()`（=外层 MirrorImage 包装体）再查一次 entries；命中即返回该包装体化身枪口
  `a.global_position + from_angle(facing)×MUZZLE_REACH`（:16,:155，facing 沿用既有 blade 还原分支）。
  两级落空维持 null（player.gd:599 回退菱形）。效果：镜面弹道/自导出膛点=镜面化身枪口；aim_direction
  同锚（weapon_base.gd:266,277）故弹道方向与出膛点同源自洽。**不改** LaserWeapon/OrbitWeapon：全厂
  muzzle_position 定义仅 ballistic:82/homing:32/base:283 三处；激光束原点与近战力场中心为持续锚，
  维持镜面本体——锚到公转化身会随 orbit+bob 抖动；R191 #3 激光镜审计归 mirror_laser 项独立处理。
  player.gd:598 的 [12,size−12] clamp 照常生效（既有口径，不扩 scope）。
- 修②（ballistic_weapon.gd `_show_muzzle_flash` :65-79）：加 `is_mirror_image` 分支（字段已存在 :46，
  make_mirror_image 置位 player.gd:843）——镜面时 texture=`TextureFactory.ice_shard()`、
  modulate=`MirrorImage.TINT`（mirror_image.gd:20 单源常量；class_name 静态引用无环）、
  scale=randf_range(0.5,0.8)、`_muzzle_timer=0.09`（比本体 0.05 略长，读出「镜面在开火」）；
  本体分支 `star(40,PopPalette.XP)`/0.05s 不变。位置 :75 `to_local(muzzle_position())` 自动跟随修①锚点。
  fx_quality≤0 整关门（:73-74）与自熄路径（:187-190）零新增。**禁走 ParticleDirector/ParticlePool**：
  全池共享敌向珊瑚红渐隐材质且发射器帽 64（balance_tables.tres:23；particle_pool.gd:22-45）——
  5 镜×rof 钳 30/s≈150 火花/s 必挤兑战斗粒子；常驻 Sprite 全场新增 ≤5 个（MIRROR_CAP=5，mirror_weapon.gd:26）零池压。
  覆盖面：弹道镜面（W1/W2/W3 复制，用户点名加特林）；自导镜面无 flash 基建本期不加（修①已覆盖其出膛口）；
  激光/近战镜面为持续锚无逐发开火语义。读感依据：_resolve_visual_variant 中 W2_gatling 曳光判定先于
  is_mirror_image（projectile_base.gd:834-838）→ 镜面加特林弹与本弹同贴图，发射口火花是唯一读感区分。

**测试口径**：新增独立套件，不动既有 73 项。test_mirror_muzzle.gd 薄壳入口 + mirror_muzzle_cases.gd
RefCounted 用例体，照 w5 模式（extends SceneTree 零全局类类型化引用、MENU 冻结+world_grove+满 HP+
_wipe_weapons、夹具敌、_drive 手动 player.tick）。headless 无树级 _process：先逐拍显式
`orbit_avatars._process(1/60)` 2-3 拍确保镜面化身已建且 visible 再进入开火驱动；弹体出生点出生即采集
（MENU 冻结 30 帧位移 <0.01px 前提断言）；归因键 weapon_uid==inner.uid（ballistic_weapon.gd:152）；
加特林预热采样窗 ≥240 帧@120Hz；同帧采样 spawn 与 avatar_global（化身公转随 _process 推进）；
玩家固定屏中心防 clamp。容差标定：修复前出生点=菱形与化身枪口错位 ~108px（两组探索探针实测 82~112px），
修复后重合位 0.00px 级，≤2.0px 纯浮点余量。

### 4.3 mirror_laser｜棱镜复制激光五缺陷（R191 #3）

**结论 implement。** 链路四环中三环半正常：束体生成✓、副激光词条栈（copy_full 传导）✓、共焦拓扑✓、
束归属/绘制/回收✓；唯独伤害结算✗。五缺陷：

- 缺陷①（功能性，laser_weapon.gd）：`_spawn_beam` 出束 `tick_atk=get_current_atk()` 裸 L 表值（:170），
  LaserBeam 结算 ctx.base_atk=tick_atk×dmg_mult×focus_mult、panel_snapshot 只取 flat_bonus/crit/add_entries
  （laser_beam.gd:432-439）→ meta_atk_pct 在激光伤害路径零消费。镜面内壳
  meta_atk_pct=(1+源meta)×ratio−1（mirror_image.gd:79）对束伤无效 → 镜面 W4 按 100% 源强度出伤，
  违背 R187 设计「镜面伤害=源面板×mirror_ratio（0.40~0.60）」。对照：弹道路径
  ctx.base_atk=panel_snapshot.base_atk（projectile_base.gd:446）→ 弹道镜 0.4 生效、激光镜不生效的不一致实锤。
  **修法**：:170 改 `get_current_atk()*(1.0+meta_atk_pct)`（提 `_tick_atk()` 小助手两处共用）；并在
  `_on_tick_post` 主束存活分支（:109-122）逐拍回写 `_main_beam.tick_atk`=同式——常驻束 lifetime=0 不会重建，
  而镜面 ratio 会 mid-run 变化（MEC_MIRROR_SPLIT→TH_MIRROR_CHOIR→apply_state 重缩放），动态刷新先例=
  同函数 tick_rate 回写（:304-305）。既有测试全先置 meta_atk_pct=0（r187_rework_cases.gd:137/856/1495/1582），
  数值断言零位移。
- 缺陷②（载体互斥破口）：MEC_SPLIT_PRISM.tres:15 仅 required_forms=[1] 无 required_weapon，W5_prism
  可作宿主（card_generator.gd:462-520/:789-798）→ 直挂即时 _refresh_sub_beams（mirror_weapon.gd:48-55→
  laser_weapon.gd:255-261）→ 锚束 1+N 段，违背 R187 doc 载体互斥硬分界与池账（laser 池 12，棱镜直挂时
  4+4+2×4=16>12）。W5 五卡全有 required_weapon=[&"W5_prism"]，唯 W4 束族七卡只有 required_forms=[1]。
  **修法（数据侧必改）**：七卡 params 各加 `"required_weapon": [&"W4_pulse_beam"]`（既有键，
  MEC_ORBIT_LINK/MEC_CHAIN_DETONATE 先例；data_validator 无 required_weapon 校验——grep 零命中，无需扩白名单；
  pool_wiring_cases.gd:280-292 拓扑门断言宿主是干净 W4，直挂 attach_trait 不经门，回归安全）。
  **修法（引擎侧防御）**：MirrorWeapon.setup 尾补 `sub_beams_override = 0`（mirror_weapon.gd:39-45）——
  硬保证「W5 束段指纹=1」，与 laser_weapon.gd:237 注释既有假设一致。
  **裁定**：锁 W4 后「棱镜→镜面吃副激光」通道消失——该通道是 copy_full 的设计外涌现而非文档承诺
  （W5 成长轴=镜数/强度/指向/节奏/涂装，不含束数），不保留；拓扑三卡+LAG+SPECTRA 挂棱镜本就惰性，
  一并锁定防死卡占卡槽。
- 缺陷③（面板缓存陈旧）：apply_state（mirror_image.gd:68-85）重赋 inner.meta_atk_pct 并整体换栈，但
  `_invalidate_panel` 于 mirror_image.gd+mirror_weapon.gd 零命中；缓存真源 build_panel_snapshot/
  _panel_cache（weapon_base.gd:157-179），失效点仅 setup:53/质变:108/挂卡:113/升级:328 → 复用镜位或源
  升级漂移后挂 crit/add 卡，束结算恒旧值。**修法**：apply_state 尾补 `inner._invalidate_panel()` 与
  `_invalidate_panel()`（两者皆 WeaponBase 公有方法，is_instance_valid 守卫沿用文件内风格）。
- 缺陷④（束染 no-op，读感类）：player.gd:845 `mirror.set("copy_tint", Color(0.82,0.92,1.0))` 写
  LaserWeapon 类型化 bool 字段（laser_weapon.gd:58），Color→bool 静默丢弃 → 镜面 W4 束恒玩家蓝，
  R183 灰染通道不生效。**修法**：改 `mirror.set("copy_tint", true)`（1 行，复用 R183 灰染通道；
  :822 p_copy 同形先例）。注意：mirror_image.gd:61 外壳同款 set 是已文档化既定 no-op
  （r187_rework_cases.gd:1784-1786 注释+验收 9 断言钉死）——**不是缺陷，不改**。置 true 后
  _emit_subbeam_spawned 归属报 COPY（laser_weapon.gd:201-202），缺陷②锁卡后镜面无副束、该遥测不触发。
  真冰青束色需 LaserBeam 增 tint 通道，独立打磨项非本批。
- 缺陷⑤（测试脚本中断）：_test_review1_fixes 内三处 `call("_nearest_unhit", …, [])` 传非类型化 [] 给
  Array[int] 形参 → SCRIPT ERROR 中断，评审R2/R5 及其后检查静默未执行（分账仍计 224/224，覆盖虚高）。
  **修法**：`var excl: Array[int] = []` 后传入（实测行号 :2268/:2271/:2273；仲裁原文 :2266/2270/2272 有
  1-2 行漂移），不动任何断言。

**测试补齐**（w5_mirror_cases.gd 新端到端）：现状 w5 套件只断言选镜数量与 form（:526-552），
「W4 源镜面」端到端零覆盖。补：棱镜+W4 源建镜→驱动 MirrorImage.tick（有敌夹具）断言
①共享 laser 池活束数 +1、束 origin=镜位；②beam.tick_atk≈源同等级 base_atk×0.40±1e-6（meta=0 夹具）；
③先开火→棱镜挂 crit 类卡+sync_mirrors(true)→inner.build_panel_snapshot() 反映新栈；④棱镜直挂
SPLIT_PRISM 后活束仍==1 + mount_gate 门断言（七束卡对 W5_prism 全 false/对 W4 全 true）；
⑤inner.get("copy_tint")==true 且出束 gray_tint==true。

**基线（本 ask 实跑）**：test_w5_mirror → PASS 73 / FAIL 0 exit=0；test_r187_rework → PASS 224 / FAIL 0
exit=0（含缺陷⑤静默中断）。

### 4.4 rxn｜元素反应通道修复（R191 #4）

**设计裁定·普通难度反应开放（证伪用户猜测）**：反应无难度/等级/双武器门，普通难度全额结算——
难度函数面仅 HP/伤害/奖励/结晶/复活/双选/槽位（game_const.gd:17-60，grep difficulty 于
elemental_system/elemental_state/mechanic_gate/card_generator 零命中）；唯一门=大关门且只收口卡架来源侧
（mechanic_gate.gd:12-13 注释『门只设来源侧，不动 ElementalSystem 结算核』、:30-46、:68-88），结算核每帧
无条件检测（elemental_system.gd:130-152）。第 1-2 关选不到雷卡→火+电组合第 3 关前物理凑不齐，是卡池节奏设计
（MAP_INTROS，mechanic_gate.gd:22-27），非难度锁。基线自查全绿：pkg3 128/0、mech_gate 33/0、buff_audit 24/0、
w4_prism 69/0、w8_charge 54/0（mech_gate 本统合复跑证实 PASS 33/FAIL 0 EXIT=0）。

**根因实锤（仲裁自跑探针证实）**：「选了火和电没反应」机制根因=同武器双 ELE 卡通道两处覆写，
第二元素永远附着不上：①ON_SPAWN 覆写——spawn 参数已带每发随机元素（ballistic_weapon.gd:149 /
homing_weapon.gd:76,129 调 _shot_element()），但 trait_effect_elemental.gd:17-20 对每个 ELEM 词条无条件
整写 projectile.element→挂载序末位胜出；②ON_HIT 覆写——attach_request 单槽字典（trait_context.gd:18）
被 :37 整写，同栈派发共享 ctx（trait_stack.gd:71-72）→末位词条胜出。探针实测（IGNITE+SHOCK 同栈、
E-03 帧闸推进后）：spawn 显式 FIR → ON_SPAWN 后 final_element=3(LTG)（3/3 试次）。故该武器火槽恒 0→
has_both 恒 false（elemental_state.gd:112-114）→过载结构性零触发。违背 R26 设计真源
weapon_base.gd:289-291『弹体配色/伤害元素/附着统一；多元素共存→每发随机取一』——三腿只实现了两腿。
「只有超导生效」体感=超导全局−30% 抗 6s+专属文字标签（popup_manager.gd:186-197）、过载仅 1.2×快照小数字
（elemental_system.gd:186-195）、碎裂需燃烧在场否则 0 伤清槽（elemental_state.gd:123-128；双槽条件系
B_spec §2.4 设计真源且 pkg3_cases.gd:1315-1329 在册锁定『三槽齐备仅碎裂』）+紫晶魔域 53% 火免怪拒火附着
+ ELE_ARC_SURGE 被误当电元素卡（MULT 条件乘区、不附着雷，ELE_ARC_SURGE.tres:10-14,26）。

**修复方案（全部来源侧，遵守『不动结算核』纪律）**：
- Fix A（trait_effect_elemental.gd）：①ON_SPAWN 分支（:17-20）加 KIN 守卫——仅当
  `p_ctx.projectile.element == GameConst.Element.KIN` 时才写元素；②`_emit_attach_request`（:25-37）
  加宿主元素守卫——host_el 取 projectile.element→beam.element→KIN，host_el 非 KIN 且 != 本词条 element
  时 return 不发请求。效果：单元素武器行为逐字节不变；弹道/自导双元素武器每发只附当发元素→双槽交替→
  反应可达；激光随束元素（主束 dominant laser_weapon.gd:195、SPECTRA 副束轮转 :383-403）。
- Fix B（近战死卡上架门，数据侧走既有 R187 键）：ELE_IGNITE/ELE_SHOCK/ELE_FREEZE.tres params 加
  `required_forms = [0, 1, 2]`（排除 MELEE=3：W8 附着 R186 有意拆除且被 w8_charge 间谍负向锁死；
  W9 派发 ON_HIT 但全工程无 attach_request 消费点 arc_slash.gd:114）。门已被三处消费：
  card_generator.gd:450,462-476、relic_handler.gd:523、shop_ui.gd:238；同键先例 AFF_AREA.tres:15。
  ELE_REACTION_VOID 与 ELE_ARC_SURGE 不加键、全形态保留。直挂 attach_trait 不经门（r187 直挂用例不受扰）。
  W9 附着接线属新特性，不在本项。
- Fix C（文案澄清）：ELE_ARC_SURGE.tres description 追加『（不附着雷元素）』，文案留在 .tres 真源不进 UI。

**明确非目标（设计如此，有据）**：碎裂 0 基数触发/清槽/进 CD；过载 1.2×快照数值、CD 2s、优先级
碎裂>过载>超导、一帧一反应；超导专属标签与 fx_quality 档位门（fx_quality=0 静音反应音/火星——向用户
核对特效档即可，不改代码）；ballistic_weapon.gd:150 attach_value=0 死载荷键不动；元素免疫拒附着。

**测试缺口补法**（既有套件全走 apply_attach 直注，词条通道零覆盖）：新增 test_rxn_channel.gd +
rxn_channel_cases.gd（入口只引导+运行时 load 用例体，先例 test_mech_gate.gd:5-7 头注）：①双元素通道
端到端（交替注入 spawn 参数→ON_SPAWN 不覆写→ON_HIT 按当发元素发请求→真件 ElementalSystem 双槽成对→
RXN_FIR_LTG 触发，含 _bump_frame 推进 E-03——帧闸在 trait_base.gd:75-76，真实游戏每弹 spawn/命中不同帧
不受影响）；②单元素回归逐字节一致；③mount_gate 形态门四向断言；④registry 数据断言。
工程纪律：既有断言零放宽零删除；无新 id、无存档层改动；时序注意 spawn():125 先赋 element、:174 才派发
ON_SPAWN，守卫读的是已赋值字段。

### 4.5 codex_rxn｜图鉴「反应」页（R191 #5）

**裁定一（rxn 项必答）普通难度反应开放，全难度一致**——见 §4.4；⇒ 页面禁止出现任何难度门文案，
条件文案必须写代码真条件。
**裁定二·解锁口径=全量可见**：不设 codex 门、不新增存档键。依据：①反应是固定 3 条常量集合
（game_const.gd:140 ReactionType 恰 3 成员），无 registry 可枚举清单，收集感收益≈0；②页面目的是回应
「别让玩家再猜」（FEEDBACK_TRACKER.md:398），而现有锁行模式（menu_screen.gd:581/596/610）连配方都不给，
与教学目的正面冲突；③MechanicGate 拿来当页门是假门（菜单无局态恒全开，:30-33）；④「见过即解锁」事件缝
有污染：reaction_triggered 三处派发语义不一（碎裂/过载走 damage_pipeline.gd:117、超导走
elemental_system.gd:205、燎原传火 :348 也借 RXN_FIR_ICE 广播会混计），且 Meta 仅 codex_kills/first_met/
weapons/traits 四通道（meta_manager.gd:41-44），需新增存档键，与纪律冲突面大收益小。大厅角标
codex_total（menu_screen.gd:436-437）维持不动。

**页面信息结构**：菜单文案元素命名用「火/冰/雷」（对齐 ELE_*.tres description；用户原话「电」=「雷」）。
每反应条目=一枚高行五段：①配方（两枚 `TextureFactory.ring_tex(DamagePopup.ELEMENT_COLORS[元素],36)`+
「+」，texture_factory.gd:1046-1053，无元素专属图标故用色环组合）；②名称；③效果句；④条件/解锁句；
⑤倍率行。三反应内容真源：碎裂（火+冰）=×2.0×点燃剩余DOT（balance_tables.gd:56 + elemental_state.gd:123-128，
结算清双槽+燃尽 elemental_system.gd:177-185）；过载（火+雷）=120%最近附着ATK快照·半径90px爆炸
（balance_tables.gd:57 + elemental_state.gd:41 + elemental_system.gd:186-195）；超导（冰+雷）=全抗−30% 6s
纯减益无伤害（balance_tables.gd:58 + elemental_system.gd:196-206）；金卡「元素裂变」全部混合反应×1.8
（ELE_REACTION_VOID.tres:9）可在效果句提及。条件句统一真源口径：双槽附着量均>0 即触发无需满槽
（elemental_state.gd:112-114；满槽 100 反而触发单元素状态并清槽 :52-56）·同反应每敌 2s CD
（balance_tables.gd:45）·同帧每敌至多一反应、优先级碎裂>过载>超导（elemental_system.gd:13-17,:145-152）·
元素免疫怪拒附着（:88-93）。解锁句按 MechanicGate 来源侧节奏：碎裂需火/冰卡（第 2 关「寒霜冰原」起）、
过载/超导需感电卡（第 3 关「紫晶魔域」起）——真源 MechanicGate.MAP_INTROS（mechanic_gate.gd:21-27）+:37-46。

**文案单源**：新增 `GameConst.reaction_note(p_rxn_id: String) -> Dictionary`（键 "RXN_FIR_ICE"/
"RXN_FIR_LTG"/"RXN_ICE_LTG"；字段 name/recipe/effect/unlock；weapon_note 先例同形同纪律注释）。
倍率数值不进 note、不硬编码：menu 侧运行时读 `GameConfig.balance.reaction_table`（autoload 已注册）
格式化。代码内静态文案表不触 DataValidator（其仅校验 registry/balance 资源，data_registry.gd:149-150）。

**字体预览**：纯 Label 静态复刻，不碰池/PopupManager/动画：照抄 `DamagePopup._apply_reaction_look`
五项 override（damage_popup.gd:254-259）=font_color=look.fill / font_outline_color=look.outline /
outline_size=12 / font=StickerTheme.font_reaction(look.variant) / font_size=54；数据全取 const
DamagePopup.REACTION_LOOKS（:64-83）+PopPalette.RXN_*（palette.gd:32-37）+StickerTheme.font_reaction
（theme.gd:36-51）。**不走 label_sticker**（theme.gd:166-178 会覆写 font 为 bold；预览 Label 直接
new Label+五项 override+MOUSE_FILTER_IGNORE）。样张：碎裂「1284」/过载「976」（Arial Black 展示体）、
超导用「超导」二字（实战即纯文字标签 REACTION_LOOKS.text，:81）。白底可读性由双色深描边设计保证
（palette.gd:30-31）。
**R192 修订（样张句按 docs/design/R192_ELEMENT_MATRIX.md §8.1/§13.1 翻转）**：REACTION_LOOKS 删
"text" 键、重构为 {name, fill, outline, variant, fmt}（name 单源 GameConst.REACTION_NAMES；跳字=
「中文名+数字」纯函数）；图鉴样张改单源 `reaction_note.sample` 字段（碎裂「1284」/过载「976」/
超导「超导」逐字保留，R192 新反应 20 键全配），不再读 look.text；预览 Label 加
`DamagePopup.CODEX_PREVIEW_SCALE=0.5` + pivot 居中适配 140×78 格（不改字号、不加宽格子）。
R192 后落地测试见 rxn_codex_cases.gd（样张断言 == note.sample、C5 翻 name/fmt 口径）。

**布局**：页签 4 枚重排（见 §3.3）。行构建器新增 `_make_codex_reaction_row`（既有 _make_codex_row
576×64 装不下 54px+12px 描边，:684-716）：576×约150 高行 Panel、MOUSE_FILTER_IGNORE 同既有纪律；
左配方图标区、中文案区（名称 17px bold + effect/条件/解锁 13px INK_SOFT 多行，label_sticker 无 autowrap
故用 \n 分行并给足行高，先例=武器页 \n 副文案 :593）、右侧 54px 预览 Label 垂直居中。

**测试口径**：对齐 test_mech_gate.gd 先例新增 test_rxn_codex.gd+rxn_codex_cases.gd；断言形移植工作区
探针 qa_rxn6_codex_probe.gd（A5=落地句柄 `_codex_tabs.has("反应") and _live(_panel_list)==3`；B/C/D 三组
数值/字体/条件断言全部有源）。落地后该 repo 外探针 A1（三页签基线）翻转 FAIL、A5 转绿——实现组顺手把
A1 基线更新为 4 页签，探针退出码容忍恰 1 项仍为 0。既有测试无页签数=3 断言（verify_feedback_cases.gd:749-756
已核），不破。**注**：codex_rxn 仲裁环境无 Godot 二进制未实跑（`where godot` 无结果）；本统合已证实二进制在
工作区根 tools/ 下并以 test_mech_gate 实跑 33/0 证实工具链，其验收命令可正常执行。

### 4.6 achv｜成就扩展与三修（R191 #6）

**目标数量级裁定：否决「几千种」**。本批交付 ~128 条（硬区间 120~200），架构按 500 条零劣化预留；
超 500 须先做 UI 虚拟化/阶梯指针化，本批不做。依据：①体裁天花板——Brotato Steam 179 项/HoloCure 168 项
（探索组 web 调研），「几千」超体裁最密例 10-20 倍；②经济硬约束——成就奖励现 395💎（meta_manager.gd:26-38
实算）vs 全消耗池仅 2100💎（升级满级 1860💎+角色 240💎），均值 35.9💎/条外推 900 条=15×全池；
③UI 墙——面板全量重建每行 4 Control（menu_screen.gd:727-760），ScrollContainer 592×812 无虚拟化
（:528-538），探索组实测 5011 行=1572ms 冻结；④结算写风暴——_check_achievements 循环内逐解锁 _save
（:691），实测 5011 条批量补发 8375ms vs 收口单落 0.9-2.7ms；⑤内容池 29 敌/11 武器/66 词条撑起的
多样性上限即数百条。

**架构（定义表驱动+程序化阶梯生成器）**：
- ACHIEVEMENTS 由 const 改启动期构建 var（名字不变，下游零改动兼容；_ready 构建顺序
  `_expand_achievements()→_load()→_build_ach_buckets()`）。
- 保留现 11 条手写定义原 id/原 reward 逐字不动（存档兼容+noah 门引用 character_table.gd:72）。
- 新增 const 阶梯模板表启动期展开：a) 全局 7 族扩档 ≈+22 条（total_kills +5000/10000/25000/50000、
  run_wave +40/50、run_level +25/35、run_weapons_drawn +4/6、run_traits_drawn +16/24、boss_slain
  +10/25/50/100/250、total_runs +25/50/100/200）；b) 单敌击杀阶梯 29 敌×[50,250,1000]=87 条
  （计数源 codex_kills 已有，def 加 enemy 子键，type=enemy_kills）；c) 收集族武器图鉴 [5,11]+词条图鉴
  [20,45,66]=5 条（type=codex_weapons/codex_traits）；d) 地图通关族 cleared_count [1,3,5]=3 条
  （type=maps_cleared）。合计 ≈11+117=128 条。
- 生成 id 规则 `<type>[_<enemy>]_<target>`；与手写撞档跳过生成档、手写 id 优先（防旧档 kill_500 与
  新生成条目同 target 双发）；id 全局唯一由断言守。
- 全部生成条目显式写 reward 键（0 也写），堵 `get("reward",10)` 隐性通胀口（:642/:689 及 hud.gd:589
  兜底默认同步改 0；手写 11 条均有显式值不受影响）。
- 击杀热路径保持 R189 分桶（:598-614），enemy_kills 桶并入击杀事件桶查数组（:482-484 改
  `[&"total_kills",&"enemy_kills"]`+boss 分支），不做「下一未解锁档指针」（500+ 规模预留）。
- `_counter_value`（:617-633）加 enemy_kills/codex_weapons/codex_traits/maps_cleared 四分支；接线三处：
  _on_enemy_killed 桶查、_on_card_chosen 两分支桶查加收集族、mark_map_cleared 后查 maps_cleared 桶；
  _check_achievements 的 counters 字典（:674-682）改为覆盖全部新族，防漏检。

**经济**：阶梯奖励曲线=中间档 0💎（解锁仍记 achievements_done+toast 无金额文案），每链仅终档发结晶
10~100💎（全局族终档 60~100、单敌/收集/地图族终档 10~30）；全表合计 ≤1500💎（对 2100💎 池 +71%）；
开新消耗口（如黑市等级列）为后续项不阻塞本批。旧档高计数玩家首启批量回填属一次性幂等补发
（achievements_done 已有 id 不重发），不构成持续通胀。

**性能三修**：①`_check_achievements`（:671-691）循环内 `_save`（:691）移到循环后函数尾一次——三收口路径
从 K 次写盘变 1 次；_try_unlock（:636-645）单条路径语义不动。②成就面板类别页签（全部/猎杀/进阶/收集）
+分页（页容量 24，上一页/下一页），行构建复用现 :732-759 逻辑不动。③HUD toast 同帧合批：
_on_achievement_toast（hud.gd:583-603）改 pending 收集+call_deferred 一帧后 flush 单条聚合文案
（「🏆 成就达成 ×N：名1、名2…（+X💎）」，reward=0 不显示金额）——同位叠放只剩最后一条的问题一并消除。

**兼容与纪律**：存档层结构零改动（achievements/done 仍是 id 数组，:703/:730-731 不动）；旧档手写 id 全
保留；noah 门 wave_20 不变；既有断言不放宽不删除——verify_feedback_cases.gd:758-759 行数断言为**结构适配**
（非放宽）：改写为等强度三断言「默认页行数==min(24,N)」「页签×翻页遍历累加行数==N」「id 去重后 size 不变」。
成就名/描述为定义表自有字段，不涉 GameConst 武器/词条文案手抄。

**数据口径说明**：探索组 headless bench 数据（批量补发 5011 条 8375ms vs 收口 0.9-2.7ms、UI 5011 行
1572ms、存档 5000 条全解锁 126KB/3.3ms、阶梯展开 139 条 0.14ms、击杀热路径与规模无关）本统合未复跑，
实现组验收时以 acceptance 探针为准。

### 4.7 boomerang｜回旋刃尺寸上调（R191 #7）

**结论 implement：纯表现层单杠杆 ×3.4→×5.0，机制零触碰。** 视觉链三环确认：①贴图 44×44 金新月
（texture_factory.gd:1100-1124，刃体最厚仅 ~6.5px 画布）；②缩放 scale_f=effective_radius()/(TEX_SIZE 64×0.5)
（projectile_base.gd:809,88）×3.4（:873，:870 注释「命中盒不变」，全仓唯一消费点）；③碰撞半径
=hitbox_r×size_mult=7.0×1.0（W10_boomerang.tres:58）与视觉倍率完全解耦。实跑换算：×3.4 下可见月牙
22.3px/厚 4.8px；×5.0 下 32.8px/厚 7.1px（≈1.17×敌人体表 28px），视觉:命中比 2.34 与 W7 导弹 ×4.6 的
~2.2 同档（先例 :877）。×5.0 时 44px 画布上屏 48.1px≈1.09×原生光栅——接近 1:1 无发糊风险，
故「贴图画布 44→64」备选无需做。

R77/R78 定距甩满零冲突（读码+实跑双证）：翻转 distance_to(_boom_origin)>=_boom_range（:251）、返航回收
<=28px（:261）、接触内冷 0.4s（:28,:349-357）、命中不耗穿透（:501-505）、超射程豁免
（ballistic_projectile.gd:37）全为位置距离/碰撞半径判定，不读 sprite scale；sprite centered=true（:95）
对称放大不偏移。基线实跑（qa_arb_w10_baseline.log，本统合复核）：**PASS 619 / FAIL 2**（exit 1），
两处 FAIL 为既有「感电：垂直落雷挂件就位」「点燃：余烬光晕 + 火苗 ×4」视觉件，与本项无关；
G4/R78/G6/G11/G8 全部 W10 断言 PASS。R188 缓存不受影响：量化对象是 scale_f（:810 floorf(scale_f*32)），
改常量不改缓存语义。

**禁改项**：hitbox_r（TH_SIZE_NOVA metric=size_mult 阈值 3.0 联动，tres:60-62）、TEX_SIZE=64（:88 全弹体
变体共享分母）、boomerang_tex 画布、返航回收半径 28px。**图标一致性**：弹体贴图消费仅 :871 一处；武器图标
56px 画布金新月（texture_factory.gd:1372-1383）与化身 weapon_icon×AVATAR_SCALE 0.62
（weapon_orbit_avatars.gd:15,51,171）为独立绘制链零改动；化身无 per-weapon 持久缩放先例（W9 :198 ×1.25
仅挥斩瞬间），化身偏小属设计内，若用户再点名化身另开小项。文案/存档/数据键零涉及。

---

## 5. 实现分组（文件互斥）

| 组 | 名称 | 独占文件 | 说明 |
|---|---|---|---|
| G1 | 共享 UI 与账本 | theme.gd、hud.gd、menu_screen.gd、game_const.gd、verify_feedback_cases.gd、FEEDBACK_TRACKER.md、test_rxn_codex.gd、rxn_codex_cases.gd | 五处跨项共享文件全部收拢于此，另含 codex_rxn 的 UI+文案单源+测试 |
| G2 | tips 详情卡 | pause_overlay.gd、test_r190b_tips.gd、r190b_tips_cases.gd | tips 改2 与其测试；theme 断言依赖 G1 先行 |
| G3 | muzzle 镜面锚点 | weapon_orbit_avatars.gd、ballistic_weapon.gd、test_mirror_muzzle.gd、mirror_muzzle_cases.gd | R191#2 |
| G4 | mirror_laser 棱镜 | laser_weapon.gd、mirror_weapon.gd、mirror_image.gd、player.gd、MEC_*.tres ×7、r187_rework_cases.gd、w5_mirror_cases.gd | R191#3 |
| G5 | rxn 元素通道 | trait_effect_elemental.gd、ELE_IGNITE/SHOCK/FREEZE/ARC_SURGE.tres、test_rxn_channel.gd、rxn_channel_cases.gd | R191#4 |
| G6 | achv 核心层 | meta_manager.gd | R191#6 引擎侧 |
| G7 | boomerang 表现 | projectile_base.gd | R191#7 |

组间零文件交集（§2 矩阵已核）。G2 依赖 G1 的 theme.gd 落地；G1 的成就分页/行数断言适配依赖 G6 的展开结果；
G7 的新增断言写在 G1 的 verify_feedback_cases.gd；G4 的束染 Color→bool 修复后，镜面束呈 RARITY_NORMAL
灰、G3 镜面火花为冰蓝（MirrorImage.TINT 同色系）——读感分层一致，无需对齐改动。

---

## 6. 跨组联动与实施顺序

1. **G1(theme.tooltip) → G2**：G2 的 test_r190b_tips 断言 theme() 四类条目，须在 G1 的 theme.gd 改动
   合入后运行；建议 G1 与 G2 同批合并、测试在全批合入后统一跑。
2. **G6 → G1(成就分页/断言适配)**：menu 分页页容量 24 与 verify_feedback_cases 三断言适配都以
   `Meta.ACHIEVEMENTS`（var 化后）为准；G6 先行或同批合并，断言在全批合入后验证。
3. **G5(审计结论) → G1(反应页文案)**：图鉴反应页条件句/解锁句采用 rxn 组审计结论——无难度门；
   条件=双槽附着>0 即触发 + 同敌 2s CD + 同帧优先级碎裂>过载>超导 + 元素免疫拒附；解锁句按
   MechanicGate 来源侧节奏（火/冰第 2 关、感电第 3 关）。数值倍率不写死，运行时读 reaction_table。
4. **G1(tips tooltip) → G1(反应页)**：StickerTheme 全局 tooltip 样式先行，图鉴反应页行如后续加
   tooltip_text 自动继承（本批反应页不强制加 hover，行内全量可见已是裁定口径）。
5. **G3 ∥ G4 回归共享 test_w5_mirror.gd**：两组都要求该套件全绿；合并序后跑者以先跑者落地后状态为准。
   G4 修①（束伤 meta 轴）与 G3 修①（出膛锚点）互补不冲突——激光束 origin 维持镜位
   （laser_weapon.gd:110 逐帧跟随），G3 明确不改 LaserWeapon，两者保持一致。
6. **FEEDBACK_TRACKER 批末统一勾选（G1）**：R191 #2 由 G3 供落点摘要（锚点修复+镜面火花）、#4/#5 由
   codex_rxn/rxn 供结论互引；#1/#3/#6/#7 随各组合并统一按 repo 惯例勾选回写。

建议合并顺序：G1 → G2 → G3 → G4 → G5 → G6 → G7（文件零交集，理论可全并行；顺序仅服务于共享测试的
最终统一回归）。

---

## 7. 回归与验收总表

统一命令形式（工作区根执行）：`tools/Godot_v4.3-stable_win64_console.exe --headless --path repo -s tests/runner/<suite>.gd`

| 套件 | 基线（来源） | 本批预期 |
|---|---|---|
| test_mech_gate | 33/0（rxn 仲裁；本统合复跑证实 EXIT=0） | FAIL 0（rxn Fix B 不动结算核） |
| test_pkg3 | 128/0（rxn 仲裁） | FAIL 0（三槽仅碎裂/0 基数原样） |
| test_buff_audit | 24/0（rxn 仲裁） | FAIL 0（双元素 60 采样修复后真交替） |
| test_w4_prism | 69/0（rxn/mirror_laser 仲裁） | FAIL 0（meta=0 路径数值不变） |
| test_w8_charge | 54/0（rxn 仲裁） | FAIL 0（apply_attach 零调用间谍不破） |
| test_r187_rework | 224/0（mirror_laser 仲裁实跑，含缺陷⑤静默中断） | FAIL 0 且评审R2/R5 PASS 行恢复、无 SCRIPT ERROR |
| test_w5_mirror | 73/0（mirror_laser/muzzle 仲裁实跑） | FAIL 0 + 新增 W4 源镜面用例 |
| test_pool_wiring | 绿（mirror_laser 仲裁） | FAIL 0（七卡 required_weapon 门） |
| test_weapon_orbit / test_gatling_orbit | 绿（muzzle 仲裁） | EXIT=0（avatar_global 波及面） |
| test_verify_feedback | PASS 619 / FAIL 2（qa_arb_w10_baseline.log，本统合复核） | 不劣化：PASS≥619、FAIL≤2 且仅限既知感电/点燃两件；含新 G4 scale 断言与成就三断言 |
| test_r190b_tips（新） | — | EXIT=0（theme 四类条目+详情卡 note 原句） |
| test_mirror_muzzle（新） | — | EXIT=0（锚点 ≤2.0px/≥52px 双负例；火花 ice_shard/自熄/零回归） |
| test_rxn_channel（新） | — | FAIL 0（双元素端到端/单元素回归/门四向/数据断言） |
| test_rxn_codex（新） | — | EXIT=0（4 页签/行数==3/倍率跟随表值/预览五项 override/可见性/无存档键） |
| pkg0~pkg5 | 720 项口径（PROGRESS.md:29） | 全 PASS（achv 批末全量电池） |

grep 类验收：`grep -c "p_tip" scripts/ui/hud.gd == 0`；`grep -c "weapon_note" scripts/ui/pause_overlay.gd >= 1`；
`grep -n "\[gui\]" project.godot` 无命中且无新增 .tres 主题；`grep -rn "TooltipPanel\|TooltipLabel" scripts/ --include="*.gd"`
仅 theme.gd 命中；七张 MEC_*.tres params 均含 required_weapon=[&"W4_pulse_beam"]；
`grep -n "BOOM_VIS_MULT" scripts/combat/projectile/projectile_base.gd` 命中常量+消费两处、
`grep -rn "p_scale_f \* 3\.4" scripts/` 零命中；W10_boomerang.tres `hitbox_r = 7.0` 不变。

---

## 8. 工程纪律自查（整案）

- **代码风格与 §九纪律**：全部改动沿用各文件既有范式（StickerTheme 工厂、R189 分桶、R187 required_* 键、
  w5/test_mech_gate 测试范式）。
- **DataValidator 口径**：新增数据仅「七张 MEC 卡加既有键 required_weapon」（validator 无该校验、grep 零命中，
  无需扩白名单）与「三张 ELE 卡加既有键 required_forms」（AFF_AREA 先例）；reaction_note 为代码内静态文案表
  同 weapon_note 先例，不触 validator；成就新条目为启动期程序化展开非资源文件，不触 validator。
  涉 .tres 改动后复跑 pool_wiring+r187 审计。
- **新 id 全局唯一**：成就生成 id 规则 `<type>[_<enemy>]_<target>` + 撞档跳过 + 断言守；无其他新 id
  （反应键 RXN_* 为既有 reaction_table 键）。
- **存档层结构零改动**：achievements/done 仍是 id 数组；codex 反应页不新增 Meta 键；settings 段无改动。
- **既有断言零放宽零删除**：唯一改动点 verify_feedback_cases.gd:758-759 为等强度结构适配（三断言），
  已在任务与验收中明示；r187 缺陷⑤修复仅改传参类型不动断言。
- **文案真源**：详情卡机制句=GameConst.weapon_note；反应页=GameConst.reaction_note + reaction_table
  运行时读数；ARC_SURGE 澄清留 .tres description。UI 零手抄。
- **类型化赋值时序**：rxn 守卫读 spawn 已赋值字段（:125 先赋 element、:174 派发）；r187 测试
  `var excl: Array[int] = []` 显式类型化；achv var 化后 _ready 构建顺序 _expand→_load→_build_ach_buckets。

---

## 9. 本统合验证记录

**实跑（本会话内执行）**：
1. `tools/Godot_v4.3-stable_win64_console.exe` 路径确认（工作区根 tools/，非 repo/tools/）。
2. `tools/Godot_v4.3-stable_win64_console.exe --headless --path repo -s tests/runner/test_mech_gate.gd`
   → 汇总 PASS 33 / FAIL 0（共 33 项），EXIT=0。
3. `grep -c PASS qa_arb_w10_baseline.log` = 620（619 判定 PASS 行+汇总行）；FAIL 行恰两条
   「感电：垂直落雷挂件就位（去圆球化）」「点燃：余烬光晕 + 火苗 ×4（燃烧可见性）」；
   尾行「验收汇总：PASS 619 / FAIL 2（共 621 项）」。
4. 26 个既有涉改文件逐一 `ls` 存在（§2 矩阵全部路径）；8 个新增测试文件 `ls` 确认不存在（待建）。
5. 关键锚点 grep/sed 复核（清单见 §0）；FEEDBACK_TRACKER.md:391 R191 表 #1~#7 读取核对。
6. docs/design/ 目录存在（repo/docs/design/ 有 R187_WEAPON_REWORK.md、R188_IDLE_PERF.md 先例），
   本文写入 repo/docs/design/R191_CODEX_REACTION.md（工作区根 docs/design/ 留有同内容副本）。

**未复跑（如实声明，依据为各仲裁在其会话内实跑或静态复核）**：
- test_w5_mirror 73/0、test_r187_rework 224/0、test_pkg3 128/0、test_buff_audit 24/0、test_w4_prism 69/0、
  test_w8_charge 54/0、test_pool_wiring、test_weapon_orbit、test_gatling_orbit、test_verify_feedback
  PASS 619/FAIL 2 的**完整重跑**——统合阶段不重复执行，全部列入 §7 验收表由实现/QA 组在改动落地后执行。
- 引擎侧 tooltip 主题链机制（viewport.cpp/theme_owner.cpp upstream 源码阅读）无法在本机复核——以
  工程 theme() 条目断言（test_r190b_tips）作工程级兜底。
- 探索组 achv 性能 bench（5011 条补发 8375ms 等）未复跑——以 acceptance 探针为准。
- codex_rxn 仲裁环境「无 Godot」系其环境事实；本统合已证实工具链可用，其验收命令可直接执行。

# R194 移动端整案（横屏 / 无怪 / 操作 / 特效 / 重导出）· 设计文档

> 状态：**五方向（orient / spawn / touch / fx / export）仲裁收敛稿**。本文件是 R194 的 **idContract 唯一真源**：
> 新增设置键 `fx_opacity` / `fps_cap` 的键名、类型、默认值、范围、存档兼容口径均以本文 §7 为准，实现组逐字遵守、禁自创别名。
> 新测试套件 id 固定 **`r194_mobile`**（全局唯一，仅有此一份）。
> 工程纪律沿用 A 架构 §九 + 各方向在案红线；既有断言零放宽零删除，本批有意变更的契约在断言注释写明 R194。
>
> 基线声明：本整案为仲裁收敛稿（本文档为唯一计划落盘产物）。统合轮实跑核验见 §13；
> 各方向标注「本人实跑」的证据（javap 常量解析、4.3 引擎源码 curl 下载核对、python zipfile APK 审计、
> 门禁全链路彩排、headless 探针）为**方向转引**，统合轮未复跑，采纳其结论并在引用处标注来源方向。
> **修复环实现期**对本文做过带「修复环 supersede」标注的增量（include_filter 收窄 `data/*.cfg`、
> 门禁脚本调用形态、A7 负断言）；统合次轮重写全文**保留并对齐**这些增量（仲裁 #10），
> 落地状态与次轮实跑核验见 §13.5；未验证项（统合轮无真机、未跑电池）在 §14 如实声明，不写入机制结论。

---

## 0. 范围与总体结构

**用户需求**（FEEDBACK_TRACKER.md:391-400 R194 登记）：①手机操作优化 ②特效等级/透明度设置 ③修横屏 bug
④修「无怪+波次狂涨」bug ⑤重新打包交付。

**五方向定案**（全部 implement，本文 §2-§6 逐方向展开）：

| 方向 | verdict | 一句话定案 |
|---|---|---|
| orient | implement | 横屏根因=项目设置 `display/window/handheld/orientation` 缺省落默认 0（横屏），预设 `screen/orientation` 是 4.3 从不读取的 3.x 死键；单点修复+分级验收，零游戏代码改动 |
| spawn | implement | 无怪根因=导出管线从不打包 data/*.cfg（RC1）+ 导出环境 `.tres.remap` 扫描漏文件（RC2）+ 全链 push_warning 静默降级（RC3）；P0 五件同一变更集，五原始假设全证伪 |
| touch | implement | 落地 4 项纯操作优化（采样双计数修复+平台配置两行+触控目标放大+BuildPanel 松手判定），灵敏度/摇杆/全屏拖动等全部裁掉或入第二批 |
| fx | implement | 新增 fx_opacity 观感旋钮（诚实口径：≈零帧收益，提帧唯一杠杆=降 fx_quality 档）；乘区三单点+单源应用器；fx_quality 不扩档 |
| export | implement | 门禁四步采纳且已全链路真跑彩排（副本 exit0 / 13.46s）；导出前置五改+四步门禁字面量+移动端配置七项定案 |

**六实现组**（文件所有权互斥，详表 §8）：移动配置 / 设置底座 / 交互UI / 战斗核 / 表现 / 测试统包。

**里程碑阶梯**（每级全绿再进下一级）：

| 里程碑 | 内容 | 参与组 |
|---|---|---|
| M0 底座先行 | `fx_opacity` + `fps_cap` 双键双注册（settings 底座）；DamagePopup.fx_opacity static helper（表现） | 组2 + 组5 |
| M1 机制/交互批 | 战斗核：remap 感知 + 早清守卫 + 双诊断计数 + boot 空表闸 + delta clamp + fx 应用器接线（game_loop.gd）；交互UI：采样修复 + 触控放大 + BuildPanel 松手 + 设置页两行 | 组4 + 组3 |
| M2 配置/测试批 | 移动配置：project.godot 两行 + 预设六改 + 图标 + B_spec；测试统包：r194_mobile 新套件 + export_data_cases + pkg5/verify 增补 + 草探针收编删除 | 组1 + 组6 |
| M3 重导出门禁批 | 门禁脚本对旧包 FAIL 留痕 → 重导出 → 四步门禁全绿 → tracker #3/#5 收口 | 组1（依赖组6 草稿删除先行） |
| M4 收口 | 全量电池 + R194 存档 + 交付指引 | 组6 + 组1 |

---

## 1. 统合仲裁记录（分歧 → 裁定 → 依据）

| # | 分歧 / 冲突 | 裁定 | 依据 |
|---|---|---|---|
| 1 | `export_presets.cfg` 死键：orient **删除**（独立 commit）vs export 验收「screen/orientation 行**未被改动**」 | **采 orient 删除案**：独立 commit，message 注明「Godot 4.3 Android 导出器无 screen/orientation 选项（3.x 遗留死键，删除无行为影响；真实开关=项目设置 display/window/handheld/orientation）」。export 方向验收行相应翻转为「已按 orient 方案独立 commit 删除」 | orient 实证：4.3-stable export_plugin.cpp 全文件 grep "screen/orientation" 零命中（选项注册段 ≈:1878-1882 仅 screen/immersive_mode + screen/support_*），该键从未被读取；保留必被未来按预设键回改 + bisect 归因污染。两方向对机制结论完全一致，仅处置相反；删除零行为影响且消灭歧义源。**落地状态：已删（§13.5，grep 零命中）** |
| 2 | 导出门禁形态：spawn 的 `tools/export_artifact_gate.py`（zipfile+AXML）vs export 四步门禁（aapt2/apksigner/python 单行直跑，已彩排验证） | **合并为一条流水线**：ZIP 级断言全部收进组1 持有的 `tools/export_artifact_gate.py`；aapt2 xmltree/badging 与 apksigner 按 export 彩排字面量直跑，并**吸收 orient G2-G4 基线断言**（configChanges=0x00001ff0、resizeableActivity=true、versionCode/minSdk/targetSdk）。aapt2 一律取仓内 `android_export/android-sdk/build-tools/34.0.0/aapt2.exe` | export 彩排已验证 aapt2/apksigner 路径与行格式（统合轮本人复跑 aapt2 dump 现包：screenOrientation=0/configChanges=0x1ff0/resizeableActivity=true/versionCode=1 全吻合）；python 内做 AXML 解析是重复造轮子。spawn 的核心增量——**三 .cfg 在包断言**（export 原门禁④不查，是真实缺口）——并入脚本。**落地状态：脚本已在 repo/tools/（§13.5，argparse 实证）** |
| 3 | `game_loop.gd` 四方争用（spawn boot 闸+clamp、fx 应用器、touch 注释修正） | **归组4·战斗核独占**，四处改动同一组一次落地；fx 的乘区 helper（static var）落组5·表现 damage_popup.gd，组4 只写值——符合「乘区 helper 先落表现组、他组只引用」 | 文件组间零重叠是硬约束；boot 空表闸是 P0 机制修复须随 loop 域同组；应用器为机械接线（fx 方案已逐字给定落点与代码形态），跨组执行风险低 |
| 4 | `meta_manager.gd` 双方争用（fx_opacity vs fps_cap）；`settings_panel.gd` 双方争用（透明度滑条 vs 帧率上限行），布局各给 780/790 | **meta_manager.gd 归组2·设置底座**：双键同批双注册。**settings_panel.gd 归组3·交互UI**：两行同批、一次布局重排，卡高 700→**约 820**（两方向并集口径；各自 780/790 视为下界参考），硬约束=行禁重叠 + abs 底 ≤1280 + headed 自检不遮挡 | 同文件同段（SETTINGS_DEFAULTS/_normalized_setting/行位分配）拆两次改必冲突；设置页无几何断言（verify_feedback_cases.gd:2401-2417 只锁按钮名/写口/开合，统合轮实读 :100-216 结构吻合），布局自由度充足 |
| 5 | bug#4（HyperOS 无怪）归因：touch「疑与横屏同根」、export「头号嫌疑仍是横屏 aspect」vs orient「假设①被零几何读取 grep 证伪」vs spawn「RC1/RC2 定案」 | **全批统一口径=spawn 定案**：无怪根因=RC1（导出不打包 data/*.cfg）+RC2（.tres.remap 扫描漏）+RC3（全链静默降级）；横屏对 spawn 零机制影响（orient 全库 grep 零窗口几何/朝向读取 + spawn 五原始假设全部证伪），横屏仅 letterbox 观感降级（2400×1080 横持 scale≈0.84 vs 竖屏≈1.5）。touch/export 的「同根」猜测作废；FEEDBACK_TRACKER #4 由组1 按 RC 口径登记 | spawn 的 RC1 链条有 APK zipfile 审计 + 代码全链 + 两份独立 headless 探针（315 物理步/波 ≈2.6s）三重证据，是五方向中唯一同时解释「无怪」与「狂涨」的机制；orient 的静态 grep 与其互证 |
| 6 | 草探针处置：spawn「收编进套件后删除」vs export「直接删（防漏包）」 | **收编后删除，且必须先于重导出**：组6 把 disc1_wave_probe*.gd、tests/disc5_* 的用例价值移植进 tests/runner/export_data_cases.gd 后删除五份草稿；组1 的重导出排在删除之后，否则门禁④「包内零 disc1_wave_probe 条目」必拦截 | export 的 diff 实证草稿会以 .gdc+.remap 漏进新包（repo 根文件不受 exclude_filter="tests/*" 保护）；spawn 的收编保证节奏签名（315±3 步）等探针资产不丢失。**落地状态：草稿已删、新包零 probe 条目（§13.5）** |
| 7 | `quit_on_go_back=false`（touch 项2）与 orientation 行的落点 | 两行都落 project.godot，**由组1·移动配置统一落地**（touch 方案提供键名与理由）；`[display]` 段加精确键 `window/handheld/orientation=1`（int 不引号、不带段前缀），`[application]` 段加 `config/quit_on_go_back=false` | 三方向（orient/touch/export）对 orientation 键名、值、段位完全一致；quit_on_go_back 是引擎级 project settings，不进 Meta.settings、存档零改动（不触 DataValidator 口径——统合轮实核 data_validator.gd 全文无 settings 白名单，grep 零命中）。**落地状态：两行已在盘（§13.5，:33/:13）** |
| 8 | spawn P2-11 可选加固（敌淡入 raw 兜底/dot maxf/位移步长钳） | **本批不排期**（可选、不阻塞），结论留档 §15 第二批候选；touch 第二批四候选同批留档 | 方向自身标注「不阻塞本 bug」；整案纪律=可选加固不与 P0 修复混批，避免归因污染 |
| 9 | versionCode：export 裁定 1→2、批内多次重导出不重复加 | 采纳，全批统一；orient G4「与现包一致」的 versionCode 基线断言相应改为 **=2**（重导出后口径） | export 已彩排 versionCode(0x0101021b)=2 行格式；首包=1（统合轮 aapt2 实跑留底）。**落地状态：preset=2（§13.5，:42），新包 04:53** |
| 10 | **修复环 supersede**：include_filter 初案 `"*.cfg"` 通配全仓 | **收窄为 `include_filter="data/*.cfg"`**（export_presets.cfg:15）+ 门禁 A7 负断言（包内零 export_presets.cfg 条目，§6.2-④） | 修复环 zipfile 审计实测：`*.cfg` 通配把**根级 export_presets.cfg（含 release keystore 三键）打包为 assets/export_presets.cfg 泄露进交付 APK**；`.godot/global_script_class_cache.cfg` 由导出管线自加入包不依赖本过滤（首包 include_filter 空串时唯一 .cfg 即它，实证）。RC1 目标三件全在 `res://data/` 下，`data/*.cfg` 恰好覆盖。统合次轮全文对齐此收窄 |

---

## 2. 横屏根因与修复（orient 方向）

### 2.1 根因链（orient 方向本人实跑，统合轮抽核吻合）

1. **清单现状**：aapt2 dump 现包 `out/InfiniteFission.apk`：GodotApp activity `screenOrientation(0x0101001e)=0`（横屏，全清单唯一出现）、`configChanges=0x00001ff0`、`resizeableActivity=true`；badging 含 2 行 landscape（uses-feature + uses-implied-feature）。**统合轮复跑同命令，四项全吻合**（§13 核验 #2）。
2. **引擎行为**（4.3-stable 源码）：`export_plugin.cpp:1003-1004` 清单 orientation 只读项目设置 `GLOBAL_GET("display/window/handheld/orientation")`（同函数 version_code 等走 p_preset->get，orientation **不走预设**）；`:1123-1124` 命中 activity screenOrientation 时 encode_uint32 写入；`:1015/:1131-1132` resizeableActivity 同为项目设置；选项注册段（≈:1878-1882）grep "screen/orientation" 零命中 ⇒ `export_presets.cfg` 的 `screen/orientation=1` 行（修复前 :58）是 **4.3 从不读取的 3.x 遗留死键**——解释预设设 1 仍横屏。
3. **默认值**：`main/main.cpp:2366` `GLOBAL_DEF_BASIC("display/window/handheld/orientation", SCREEN_LANDSCAPE)`；repo/project.godot [display] 段（修复前 :20-27）仅 6 键无任何 handheld 键 ⇒ 落默认 0=横屏。行为闭环自洽。
4. **枚举序与映射**：display_server.h:350-356 `LANDSCAPE=0/PORTRAIT=1/REVERSE_LANDSCAPE=2/REVERSE_PORTRAIT=3/SENSOR_LANDSCAPE=4/SENSOR_PORTRAIT=5/SENSOR=6`；gradle_export_util.cpp:35-53 `PORTRAIT→Android 1、LANDSCAPE/default→0` ⇒ 项目设置=1 ⟹ 清单 screenOrientation=1=Android portrait，**修复值 1 正确**。

### 2.2 横屏连带影响（职责③④，静态实核）

- 全库 grep（repo/scripts + repo/autoload）`get_visible_rect|viewport_rect|get_window()|screen_get_|safe_area|DisplayServer` 仅 2 命中且均为 headless 存档路径切换（meta_manager.gd:23、run_save.gd:16）——**零窗口几何/朝向读取**；逻辑域钉死 720×1280（data_validator.gd:368-370 非 720×1280 即 fatal，统合轮 grep 实核 fatal 文案在 :370）；spawn 全在 res_logic 空间（enemy_spawner.gd:216-226：顶边 60% + 左右上 20%、-40px 屏外）；输入为相对拖动累加（player.gd:276-281 `_drag_accum += event.relative`，不读绝对坐标）；存档无朝向/分辨率字段 ⇒ **曾横屏进入的旧存档修后完全兼容，无需迁移**。
- pkg5_cases.gd:831-835 AC-01.1（720×1280 + canvas_items/keep）与 orientation 键正交不受影响（统合轮实读 :828-840）。
- **结论：横屏进入仅 letterbox 观感降级（2400×1080 横持 scale≈0.84 vs 竖屏≈1.5），零机制破坏，无代码加固必要。**
- 系统强横屏场景（HyperOS 后台锁横屏 app 内打开）：清单 screenOrientation=1 是 activity 级硬锁，按 Android 平台语义由该属性覆盖，行为=竖屏 letterbox，天然鲁棒，无需改码。

### 2.3 configChanges=0x1ff0 裁定（争议收口）

讨论员4 正确、2/3/5 告诫撤回。javap 实解仓内 SDK `android_export/android-sdk/platforms/android-34/android.jar` 的 `android.content.pm.ActivityInfo` 常量：KEYBOARD=16｜KEYBOARD_HIDDEN=32｜NAVIGATION=64｜ORIENTATION=128｜SCREEN_LAYOUT=256｜UI_MODE=512｜SCREEN_SIZE=1024｜**SMALLEST_SCREEN_SIZE=2048(0x800)**｜DENSITY=4096(0x1000)，求和=8176=0x1FF0 精确吻合；0x2000 实为 CONFIG_LAYOUT_DIRECTION=8192，不在 0x1ff0 内。⇒ 引擎已声明自行处理 smallest-screen-size 变化，「分屏/折叠改 DP 档→Activity 重建丢局」告诫**不成立**；未覆盖的重建触发仅剩 mcc/mnc/locale（0x0007，SIM/语言切换），与本修复无关，仅留档。

### 2.4 行号修正

以 4.3-stable 实测为准：读 1003-1004／写 1123-1124／枚举 350-356／映射 35-53／默认 main.cpp:2366。主控与 FEEDBACK_TRACKER.md:397 所引 **export_plugin.cpp:1027 需修正**（组1 任务）。

### 2.5 精确改法与验收门禁（G1-G5）

- **改法**：repo/project.godot [display] 段内加一行 `window/handheld/orientation=1`——int 字面量不加引号、键名不带 display/ 段前缀、段位必须是 [display]；除此之外 [display] 段与全项目其余设置一字不动（[application] 另加 touch 项2 的 `config/quit_on_go_back=false`，见 §4.2）。
- **死键清理**：删 export_presets.cfg 的 `screen/orientation=1` 行，独立 commit（message 口径见仲裁 #1）。
- **G1** 源断言：`grep -q '^window/handheld/orientation=1$' repo/project.godot`（统合轮实跑：修复前缺失 grep -c=0 / exit=1；**落地后已在盘 :33，§13.5**）。
- **G2** APK 清单断言：`aapt2 dump xmltree --file AndroidManifest.xml <apk> | grep -qE 'screenOrientation\(0x0101001e\)=1$'`——**锚定式必须含行尾 $**：宽松 `screenOrientation.*=1` 对 =13 假通过已实证，禁用；首包实跑 exit=1（正确拦截）；属性全清单唯一已实测。
- **G3** badging 断言：`aapt2 dump badging <apk> | grep -ic landscape` == 0（首包=2；修后 implied 特性变为 screen.portrait 属预期，**禁止断言「不含 portrait」**防误判回归）。
- **G4** 基线不回退（同一 dump）：configChanges=0x00001ff0、resizeableActivity=true、package/versionCode（重导出后=2，仲裁 #9）与基线一致；resizeableActivity 模板 false→导出 true 的补丁管线不得破坏。
- **G5** 引擎套件：pkg5 全过，AC-01.1 原样保持，另新增断言 `int(ProjectSettings.get_setting("display/window/handheld/orientation"))==1`（注释标 R194，新增不放宽）。
- 门禁三断言须**成对执行**：仅源断言过≠APK 已重导出，仅 APK 断言过≠未改死键假修复。

---

## 3. 无怪（HyperOS bug#4）根因判定与探针设计（spawn 方向）

### 3.1 根因判定（按置信度排序，方向本人实跑）

- **RC1（主因，≈确定）**：APK 导出管线从不打包 data/*.cfg。`export_filter="all_resources"`（export_presets.cfg）只收 Resource，.cfg 非 Resource，仅 include_filter（修复前空串）能带上。python zipfile 审计首包（804 项，构建 2026-09-29 00:02:31）：唯一 .cfg=assets/.godot/global_script_class_cache.cfg，`assets/data/manifest.cfg` 缺失（global_constants.cfg/version.cfg 同缺，game_config.gd:57/:66 静默回退默认值——设备数值已漂移）。后果链：DataRegistry.load_all 的 cfg.load 失败仅 push_warning（data_registry.gd:26-27，统合轮实读）→ 类目目录未声明跳过（:87-89）→ enemies={} → `_roll_composition` 回退 `_cheapest_enemy()=null` → 空构成仅 push_warning（wave_director.gd:228-231）→ 队列恒空+场上恒 0 → R92 早清窗钳 0.8s（wave_director.gd:132-135，EARLY_CLEAR_WINDOW=0.8 :49）+ 波间缓冲 1.8s（:165，INTER_WAVE_BUFFER 0.6+LOOT_BUFFER 1.2，R26）→ 每≈2.6s 自动涨一波、零怪——与「无怪+波次狂涨」完全吻合。headless 佐证：空注册表波起始步号 [0,315,630]，恒 315 物理步≈2.625s/波（disc1_probe_out.log）；disc5_probe_out.log w1-w9 每波恒 2.62s。板上签名：Boss 波早清被 `not _boss_wave` 门控（:134），空表下 w10 走满窗 22s+1.8≈23.8s 停顿（w9 后仍弹战前补给商店，观测需剔除商店停留）。
- **RC2（第二层，必须同改）**：即使补打包 manifest.cfg，扫描仍空表——导出环境 DirAccess 列出的是 `*.tres.remap` 文件名（.tres=0、.remap=350、.res=158 审计），data_registry.gd:96 与 :127 的 `ends_with(".tres")` 过滤把全部数据文件漏掉。反证 ResourceLoader 对固定路径 remap 透明：balance_tables.tres.remap 在包内且菜单正常。**两层任缺其一 bug 原样复发——必须同一变更集落地。**
- **RC3（静默失败放大器）**：全链降级仅 push_warning（data_registry.gd:27、wave_director.gd:230、enemy_spawner.gd:69，统合轮实读后两处吻合），设备上不可见；boot 加载无空表闸（game_loop.gd:1216-1219 `_boot_load_data` 直接返回）；headless 电池全绿是盲区本体：pkg2_cases.gd≈:845-857 直接内存注入 registry.enemies，从不走导出文件系统加载路径。
- **RC4（产物漂移，发布卫生非根因）**：首包横屏锁定（screenOrientation=0，统合轮 aapt2 实跑留底）vs 仓库预设竖屏——首包（2026-09-29 00:02 构建）非当前预设导出。修复=按当前预设重导出+产物门禁。

### 3.2 五个原始假设全部证伪（代码证据，转引 spawn）

①横屏 spawn 偏移：出生点唯一来源 GameConfig.balance.res_logic=720×1280（enemy_spawner.gd:215-226），相机静态 res_logic*0.5 无 zoom（game_loop.gd:1491-1495），stretch=canvas_items+keep（project.godot）→ 横竖屏世界可见域恒同，无机制。②高刷帧率依赖：波次唯一驱动 `wave_director.tick(gd)`，gd=raw×time_scale（game_loop.gd:1003-1005，统合轮实读），raw 恒 1/120（project.godot:31），time_scale clamp[0,1] 只慢不快。③首帧 delta 尖峰：物理步 delta 恒定、catch-up 帽 8 步≈66.7ms，且 start_wave 每波重置窗口/硬帽（wave_director.gd:101-103）→ 结构上不成立。④ETC2/ASTC：APK 唯一贴图=未被引用的 design_sheet.ctex，全部视觉运行时 TextureFactory 生成，压缩格式杀不到。⑤Vulkan mobile 可见性分支：全项目无平台渲染分支，敌 flash 失败呈品红非隐形；「隐形通道」（enemy.gd:388 modulate.a=0 + :400-402 fade 由 Enemy.tick 消费）与 wave_director.tick 同一 gd 通道——gd 断供则波次同步停，解释不了「无怪+狂涨」，仅列独立次级隐患。

### 3.3 修复方案（P0 五件必须同一变更集，缺一复发）

1. export_presets.cfg include_filter 显式入包（**修复环 supersede：最终落地 `include_filter="data/*.cfg"`，export_presets.cfg:15**——初案 `"*.cfg"` 通配全仓会把**根级 export_presets.cfg（含 release keystore 三键）打包为 assets/export_presets.cfg 泄露进交付 APK**（zipfile 审计实测，已复现并回退收窄）；`.godot/global_script_class_cache.cfg` 由导出管线自加入包不依赖本过滤（首包 include_filter 空串时唯一 .cfg 即它，实证）；门禁 A7 负断言钉死（§6.2-④）。救 manifest.cfg/global_constants.cfg/version.cfg 三件（落组1）。
2. data_registry.gd:96/:127 remap 感知：列举文件名以 .remap 结尾先剥壳再做 .tres 过滤，load() 调用不动（ResourceLoader 对 .tres 路径 remap 透明，编辑器/导出两态通用）——剥壳方案，否决固定路径表（落组4）。
3. boot 空表闸：game_loop._boot_load_data 加载后 registry.enemies 为空（或 report.total==0）→ 并入既有 config_fatal/boot_error 致命集（game_loop.gd:137-140/:2033 机制现成，统合轮实读）拒绝入局——射击游戏零怪爬波比拒绝启动更劣；头部套件内存注入路径不经 boot 不受影响（契约变更断言注释注明 R194）（落组4）。
4. 双诊断计数：`WaveDirector._roll_composition` 空输出分支计数 `wave_empty_composition`、`EnemySpawner._resolve_data` null 丢弃分支（:66-71）计数 `spawn_dropped`——两点都要（单点计数与另一失败同签名会误判）（落组4）。
5. 早清守卫：wave_director.gd:132-135 加「本波入队请求=0 → 不钳 0.8s、走满窗+计数+一次 push_error」——保留有怪快清正宗语义，R92/R26 常量一律不动（2.62s 空转是降级症状，禁调 pacing 常量掩盖）（落组4）。

P1：按当前预设重导出+产物门禁（§6，落组1）；用户侧零成本判别（图鉴 0/0 角标=menu_screen.gd _refresh_lobby_counts 读 registry.enemies.size()；节奏判别≈2.6s/波+w10≈24s 台阶=本链，~26s 均匀+怪在场=硬帽叠波路径 wave_director.gd:150-151 需重启排查，~2.8s 均匀=请求全弃路径 enemy_spawner.gd:66-71）。

P2：`_game_delta` 结果 clamp ≤0.25s + `DebugStats.count(game_delta_clamped)`（game_loop.gd:1003-1005；正常局上限 8×1/120≈66.7ms 不受影响，契约变更 R194 注明，落组4）。P2-11 可选加固不排期（仲裁 #8）。

### 3.4 探针设计（T1-T8，归组6，全 headless 可自动化；T1-T5 修复验收必需，T6-T7 锁定证伪防回归）

- **T1** remap 正路径：fixture 目录放 X.tres.remap 命名文件 → DataRegistry.load_all → 断言 enemies.size()≥1；同套件断言纯 .tres 目录（编辑器态）照常加载——双态覆盖，封 pkg2 内存注入盲区。
- **T2** 缺 manifest 负路径：无 manifest 构造 registry → 组件级直驱 tick（绕开 boot 闸）6.5s 游戏时 → 断言 wave≥3、queue+active 恒 0、稳态波间隔 **315±3 物理步**（区间断言，勿抄单值 312——实测 314-315 含相位过渡 tick）。
- **T3** 零请求守卫回归：注册表在但构成空（cheapest=null 桩）→ 断言 window_left 不被钳 0.8（≥满窗）、wave_empty_composition≥1；对照组：有≥1 请求时早清仍 0.8s（pkg2 既有 R92 断言原样绿）。
- **T4** boot 闸：空 enemies → config_fatal/boot_error 态可达断言；满注册表 → 正常 boot 到 MENU。
- **T5** 产物门禁脚本：= §6 之 tools/export_artifact_gate.py（组1 持有），对旧包 FAIL / 重导出新包 PASS 双跑留痕（**落地状态：gate_evidence/gate_old_pkg_R194_pre.log + gate_new_pkg_R194_post.log 双证据已在盘，§13.5**）。
- **T6** 横屏视口模拟：窗口 root size=(2400,1080)+真数据 → 2s 内断言敌进入逻辑可见域 (0,0)-(720,1280)——锁①证伪。
- **T7** 时序鲁棒：手动 _physics_process 按 1/144 节奏+零 delta 帧+卡顿注入（8×1/120 后跳 3s）→ 断言波号与匀速基线一致（至多 +1 波）；巨 delta 注入按 clamp 后语义断言——锁②③证伪。
- **T8** 收编：repo/disc1_wave_probe*.gd、tests/disc5_* 三份草探针用例化并入套件后删除草稿文件（先于重导出，仲裁 #6；**落地状态：草稿已删，§13.5**）。

---

## 4. 操作优化落地清单与不做清单（touch 方向）

### 4.1 事实基座（方向亲验，统合轮抽核吻合）

采样链 player.gd:274-281（统合轮实读）：`_unhandled_input` 对 InputEventScreenDrag 无条件累计（无 index 过滤）、对左键 MouseMotion 无 device 过滤累计；消费侧 :244-257 input_enabled 宽限吞拖动 → _drag_accum 每 tick 清零 → hazard_slow_mult 乘序 → 钳制 :1180-1186（x 全宽、y∈[768,1264] 下 40%）；重开清零 :1080。game_loop.gd:164-174 仅置 input_enabled+透传零向量（统合轮实读 :164-176 吻合），:1786-1804 只处理 Esc/P 键。**双计数根因**：project.godot 无 [input_devices] 段 → emulate_mouse_from_touch 默认 true；Godot 4.3 input.cpp 仅首指收养仿真鼠标，被收养指的 ScreenDrag 同时合成 MouseMotion → 单指主路径两路都进 ≈速度×2；次指只有裸 ScreenDrag；InputEvent.DEVICE_ID_EMULATION=-1（4.3 docs）。player.gd:275 与 game_loop.gd:164 的「E-15 单指针锁定由 GameLoop 承担」注释失实（grep 无实现）。

### 4.2 本批 4 项

- **项1·采样修复**（player.gd，落组3）：(a) `var _active_drag_index := -1`（声明处初始化，类型化赋值时序红线）；ScreenDrag 分支首指锁定（-1 时收养 index，异 index return）；(b) InputEventScreenTouch 分支：released 且 index==_active_drag_index 时清锁；(c) MouseMotion 分支 `mm.device == InputEvent.DEVICE_ID_EMULATION` 时 return（丢 Android 仿真路；桌面真实鼠标 device 0 不受影响）；(d) input_enabled false→true 上升沿清锁（_prev_input_enabled 镜像，防暂停期漏收 released 后锁死新手指）；(e) :1080 重开清零处同步清锁；(f) 修正 player.gd:275 与 game_loop.gd:164-165 失实注释（锁定落点=Player 采样层；game_loop.gd 侧注释由组4 落地）。红线：采样→tick 消费→钳制链路、hazard 乘序、0.5s 宽限、每 tick 清零语义全部不动；不新增分配、O(1)；**禁关 emulate_mouse_from_touch**（全 UI 触屏点击依赖仿真鼠标）。修后真机单指位移预期≈÷2。
- **项2·平台配置两行**（落组1，仲裁 #7）：project.godot [display] `window/handheld/orientation=1` + [application] `config/quit_on_go_back=false`（引擎级键，不进 Meta.settings、存档零改动）；后者全局生效=大厅/子面板 Android 返回不再退游戏（各面板已有 UI 返回按钮），列入真机回归清单。HyperOS 无怪 bug 归因口径按仲裁 #5。
- **项3·触控目标放大**（7 控件 3 文件，纯数值+落位联动，落组3）：hud.gd AUTO `_auto_capsule`(:1211)/`_auto_btn`(:1218-1219) (56,30)→**(56,64)**（y126 不动，恰贴 r188 断言带上沿 190——统合轮实读 r188_idle_cases.gd:1253-1259 断言式 `pos.x+size.x<=704 and pos.y+size.y<=190`，56×64 恰好零断言改动）；暂停钮 `_pause_btn`(:1193-1194) (66,66)→(72,72)（514+72=586<徽章左沿 598、26+72=98<AUTO 顶 126）。shop_ui.gd：购买 :561-562 (440,22)120×44→**(440,16)132×56**（行 min 86 内，desc 右沿 x416<440）；刷新 :454-455 (211,806)210×48→**(211,802)210×56**（出击 y868 不动，纵距 12px）。menu_screen.gd：出发 :332-333 (486,39)76×40→**(486,32)76×52**（note_l 顶 y94 上方）；选用/解锁 :1192-1193 与 :1205-1206 (478,38)84×44→**84×56**；CustomWeaponCycle :1164-1165 (74,92)300×24→**(74,92)300×48** 且角色行 :1090 custom_minimum_size (576,118)→(576,140)（ScrollContainer 吸收）、codex_l :1183 y96→118；升级买 :1302-1303 (420,14)140×42→**(420,6)140×56**（行 68 内 6..62）。红线：只动 size/position/custom_minimum_size，不碰 mouse_filter 语义、不动 tooltip/hover 通道、不引入新输入路径；难度三档 50/页签 54/继续 48 等 borderline 档本批不动。
- **项4·BuildPanel 松手判定**（hud.gd:664-668，落组3）：左键按下记录 `_build_press_pos` 并置 armed；armed 期 MouseMotion 位移 >16px 解除；左键 released 且 armed 才 emit `build_details_requested`（GameLoop :668-681 仲裁零改动）。效果=拖动起手落在左下面板不再误暂停+弹详情；新增两会话态变量 ~12 行。面板内武器图标 STOP 死区本批不动（归第二批）。
- **R195 补注**（跨批防误判）：shop 刷新钮自 R195 起可隐藏（visible=can_refresh() 联动，置灰→原位隐藏），本批几何契约 (211,802)210×56 不变。

### 4.3 明确不做（本批裁掉，结论留档）

灵敏度设置/系数（三方参照官方版均无先例；1:1 相对拖动乘系数≡改 move_speed；必须先有项1 修复后的真机 1× 基线再议）；扩活动区/全屏可拖（下 40% 钳制是 E-15 玩法几何；res_logic=720×1280 致命锁 data_validator.gd:369-371）；虚拟摇杆/拖动-摇杆双模式/自定义布局（过度设计，Brotato 竖屏单手+自动开火同构印证现状合理）；边缘手势 inset/系统手势排除 rect 原生插件（OEM 兼容差不成比例，待竖屏包真机实测后再议）；第二指按钮防御（引擎源码实证次指不驱动仿真鼠标→按钮不可达，白做）；触摸吞吐优化（输入路径 O(1) 零分配，帧头在网格/敌 tick R189c）。

**第二批候选**（记入 tracker，不在本批）：①首局拖动教学浮层+活动区分界淡显+出生位屏中（需复核 game_loop.gd:818-828 单 Label toast 后到覆写互顶错峰——统合轮实读注释「直发多条会互相吞」；文案走 GameConst 真源；复用 mark_first_met 先例 meta_manager.gd:547；新增说明禁依赖 tooltip/hover——触屏不可达）②构筑面板图标 STOP 死区与 hover 信息层触屏化③设置滑条触控条放大（与 fx 透明度滑条同文件，已并入本批行位规划）④灵敏度（真机基线后若有诉求）。

---

## 5. 特效设置契约与透明度接入方案（fx 方向）

### 5.1 前提修正（方向亲验）

「特效等级 UI 缺失」不成立：settings_panel.gd:105 已有「特效质量」三档循环钮（FxQualityButton，写口 :236-240 clampi(0,2)，✓高/◐中/✗低），双入口大厅 menu_screen + 暂停卡 pause_overlay.gd:136 经 game_loop.gd:1509-1510 接线（统合轮实读 :1505-1512 吻合）。**只补提示文案，命名保持「特效质量」不改名**（9 文件术语单源，改名纯 churn）。主任务=新增 fx_opacity 观感旋钮。**诚实口径**：乘 modulate.a 不减 draw call/节点/粒子模拟（全池预建+visible 显隐，object_pool.gd:49-64），≈零帧收益；提帧唯一杠杆=降 fx_quality 档（档0=跳字80→20+普命中粒子全关+色差整关 game_feel_director.gd:235-236）。**全部文案/文档禁止把透明度当提帧卖点**。fx_quality 不扩档（写口 clampi(0,2)、三元素档表、roundtrip 锁 fx_quality_cases.gd:63-73）。

### 5.2 键契约与乘区（详见 §7 idContract）

key=`fx_opacity`，float，默认 1.0，clampf(0.3,1.0)。**双注册缺一不可**（SETTINGS_DEFAULTS + _normalized_setting，否则写口静默丢弃——set_setting 未知键 return null，统合轮实读 meta_manager.gd 吻合）。旧档缺键经读口回默认零迁移；headless 测试档隔离（meta_manager.gd:20-24 save_path headless 分支，统合轮实读）。

**乘区=三单点，单源应用器落 game_loop.gd（组4 执行，fx 方案逐字）**：`_boot_build_presentation` 尾部（:1395 后，池已满量预热 game_loop.gd:1268-1274）初次应用 + `Meta.settings_changed` 订阅（仿 sfx_bank.gd:74-80 先例；GameLoop 释放自动断连，测试多 GameLoop.new() 安全）。应用体：A) `elemental_fx.modulate.a=f`——一行罩全层（ElementalFxLayer extends Node2D，统合轮实读 scripts/gamefeel/elemental_fx_layer.gd:13；全部池件为 Node2D/Line2D/Sprite2D 直接子嗣，子件渐隐动画与根 alpha 引擎级相乘）；B) `for emitter in (pools[&"particle"]).get_children(): emitter.modulate.a=f`（:1375 预热循环同款遍历，统合轮实读；满量预热后容量内懒增长不可达，无需增长钩子）；C) DamagePopup 折乘：`static var fx_opacity:=1.0`（static var 先例 elemental_system.gd:82），tick :314 改 `modulate.a=fx_opacity×clampf(1.0-t*t,0,1)`，_reset_state :343 改 `modulate.a=fx_opacity`（防池复用取出首帧全 alpha 闪帧）——helper 落组5·表现 damage_popup.gd，应用器写该 static（仲裁 #3）。**只乘 alpha 永不写 visible**（四层爆 visible==4 锁 fx_quality_cases.gd:399-406）；禁碰跳字 _label.self_modulate/theme/position/scale（fx_quality_cases.gd:143、elem_immune_cases.gd:206、verify_feedback_cases.gd:1897-1899 锁）。

### 5.3 排除清单（勿接入，范围写进提示文案）

枪口星闪/镜面火花（ballistic_weapon.gd:83 modulate=MirrorImage.TINT；mirror_muzzle_cases.gd:400-401、r191_rework_cases.gd:731-734 精确锁）；弹体 _draw 拖尾（projectile_base.gd:705-717 内联 draw_line）；DeathPop（enemy.gd:738-739 挂敌父容器=gameplay 层）与敌附着感电弧/落雷/火苗（enemy.gd:2266-2371）；HUD 复活白闪（hud.gd:1614-1628）；CloudBackdrop（主题整写 game_loop.gd:847/:851-853/:1621-1622 + 整 Color 相等断言 verify_feedback_cases.gd:883-884，v1 排除）；色差链（game_feel_director.gd:33-34/:201-238，pkg4 锁 0.004 起跳）。**禁** GameLoop 根 modulate/CanvasModulate/后处理（池容器 plain Node 不可达且误伤玩家/敌/confetti）；**禁** ObjectPool 基类 Node→Node2D；禁逐系统散改。

### 5.4 UI 与断言

settings_panel.gd（组3）仿音量行加「特效透明度」行：`_make_sticker_slider` 加可选参 `p_min:=0.0`（修复前 :183 硬编码 slider.min_value=0.0，音量两行零改动——统合实读），min 0.3/max 1.0/step 0.05，值显示 "100%" 口径同音量；写口 `_on_fx_opacity_changed` 走 Meta.set_setting+守卫 _syncing，_sync_from_meta 加回填。布局与帧率行合并重排见仲裁 #4（卡高 700→约 820，行序参考：现有五行→帧率上限(~508)→特效透明度 label(~546)/滑条(~582)→提示(~644)→返回(~706)；设置页无几何断言，实现可等价压行距， headed 自检不遮挡）。提示行改「设置即存 · 立即生效（特效质量=跳字/粒子/元素特效总量；卡顿时优先调低特效质量）」+透明度范围口径（战斗特效层/粒子/跳字变淡）。文案按面板现况内联字面量（settings_panel.gd 现行风格；GameConst 单源纪律适用于反应名等域不适用本面板）。

verify_feedback_cases.gd（组6）_test_settings 增补 R194 断言块：①默认 1.0／写口钳制 0.29→0.3、2.0→1.0／持久化回路／旧档缺键回 1.0；②滑条联动 sp._fx_opacity_slider.value=0.5→Meta.settings≈0.5；③应用生效：fx_opacity=0.3 时 _gl.elemental_fx.modulate.a≈0.3 且 _gl.player.modulate.a==1.0、发射器 modulate.a≈0.3、起跳字 tick 后 modulate.a≈0.3×(1-t²)、开火后 _muzzle_flash.modulate==MirrorImage.TINT 不变；④提示行含「卡顿时」引导且不含提帧暗示；⑤快照还原 + DamagePopup.fx_opacity 复位 1.0。

**运行时冒烟门**：modulate 沿 CanvasItem 链逐级相乘出自 4.3 源码文本（方向探索探针未跑通，非运行时实证）；层根级联已静态闭合（§5.2），**实现须 headed/真机冒烟一次**：fx_opacity=0.3 时层内特效变淡而玩家/敌本体不变。

**基线口径**（fx 方向亲跑，HEAD 全绿）：test_fx_quality PASS 32/FAIL 0、test_verify_feedback PASS 630/FAIL 0、test_mirror_muzzle PASS 32/FAIL 0（命令 `tools/Godot_v4.3-stable_win64_console.exe --headless --path . -s tests/runner/test_X.gd`）。r191 127/127、pkg4 108/0、rxn_codex 44/0、perf P95=4.693ms 为探索员所跑未复跑——实现后全部亲验。

---

## 6. 移动端配置与重导出门禁命令序列（export 方向）

### 6.1 门禁前置五改（不落地则门禁必挂/漏；全部落组1）

- **P1** project.godot [display] 补 `window/handheld/orientation=1`——唯一修口（彩排实证：加此行后 xmltree screenOrientation 0→1）。
- **P2** export_presets.cfg：version/code=1→**2**；`exclude_filter="tests/*"`（彩排实证剔除恰 204 条=201 tests+3 条 fixtures 重建物，music 16 条等游戏资源零误伤）；launcher_icons 三键填 res://assets/icons/icon_192.png / icon_fg_432.png / icon_bg_432.png（res:// 路径彩排实证可用）；删除 package/app_category=2（成品实测 appCategory=0 纯 no-op，删键防交付文案虚假承诺）；**include_filter 按 spawn RC1 显式入包，最终值=`"data/*.cfg"`（修复环 supersede，仲裁 #10——`*.cfg` 通配泄露根级预设连 keystore，已实测回退收窄）**；删 screen/orientation 死键（orient，独立 commit）——统合合并，详表见 §8 组1 任务。
- **P3** 新增 repo/tools/make_icon.py（PIL 12.3.0 已装）：出三图到 repo/assets/icons/——192 主图 + 432 前景（图案限中心 264px 安全圆）+ 432 纯藏青(50,81,107)背景；藏青底+白玩家圆+轨道蓝点。
- **P4** 删除 repo 根残留探索脚本 disc1_wave_probe.gd / disc1_wave_probe_cases.gd——diff 实证会以 .gdc+.remap 漏进新包，grep 全仓零引用（**由组6 收编后删除，先于重导出**，仲裁 #6）。
- **P5** 交付指引：`adb install -r` 覆盖安装（同包名+code≥已装+同签名三条件全满足）；INSTALL_FAILED_UPDATE_INCOMPATIBLE 才 uninstall 兜底（retain_data_on_uninstall=false 卸载清档）；android_export/keystore/debug.keystore 是异指纹陷阱钥匙（DE:BA:F9…），配置与文案永禁引用。

### 6.2 重导出门禁字面量（四步；①写成品；统合轮已复跑首包 aapt2 基线）

1. **导出**：`android_export/Godot_v4.3-stable_win64.exe --headless --path E:/Code/Agent/Infinite-Fission/repo --export-release Android E:/Code/Agent/Infinite-Fission/android_export/out/InfiniteFission.apk --log-file E:/Code/Agent/Infinite-Fission/android_export/out/export_last.log`，timeoutMs 900000，断言 exitCode==0。**禁 tools/ 副本**（无 ._sc_ 会从 C 盘播种 jdk1.8，tracker 坑①）。彩排实测 13.5s；失败先读 log，重试预算 2 次。
2. **清单**：`android_export/android-sdk/build-tools/34.0.0/aapt2.exe dump xmltree --file AndroidManifest.xml <APK>`，对 stdout 正则断言（行格式实测）：`/android:screenOrientation\(0x0101001e\)=1$/`、`/android:versionCode\(0x0101021b\)=2$/`、`/android:versionName\(0x0101021c\)="0.1.0"/`、`/android:minSdkVersion\(0x0101020c\)=21$/`、`/android:targetSdkVersion\(0x01010270\)=34$/`，**外加 orient G4 基线**：configChanges=0x00001ff0、resizeableActivity=true。附跑 `dump badging`：负断言 stdout 不含 screen.landscape（G3：grep -ic landscape==0）；application-icon-640 行仅信息性不断言（防假绿）。
3. **验签**：`E:/Code/Env/jdk17/bin/java.exe -jar android_export/android-sdk/build-tools/34.0.0/lib/apksigner.jar verify --print-certs <APK>`，断言 exit 0 且 stdout 含 `c940adaf0d0ad196b6f9aee7aeb923fe1d3824b5b9a7ab818621c6ff16f4ae63`。jdk 路径实测 E:/Code/Env/jdk17 存在（E:/Code/Agent/Env/jdk17 不存在 exit 127）。指纹漂移=keystore 被换，一票否决。
4. **包体**：`C:/Python314/python.exe tools/export_artifact_gate.py <APK>`，断言 exit 0（模板 APK 走 `--template` 选项或省略——脚本默认 `DEFAULT_TEMPLATE` 即 `android_export/editor_data/export_templates/4.3.stable/android_release.apk`；**勿作第二位置参数**，脚本仅一个位置实参，多传必 `unrecognized arguments` exit 2——修复环修正：初稿文档误把模板当位置参数，实跑用默认形态）。脚本判定（谓词均实测）：**assets/data/manifest.cfg、assets/data/balance/global_constants.cfg、data/version.cfg 在包（spawn RC1 验收，export 原门禁缺口已补）**；abis==["arm64-v8a"]；assets/tests/ 条目==0；包内无 disc1_wave_probe 条目；**包内零 export_presets.cfg 条目（A7，修复环新增——include_filter 通配 `*.cfg` 曾把根级预设连 keystore 配置打进包，已收窄 `data/*.cfg`）**；25165824≤size≤50331648（24-48MiB 带，彩排骨架 32,658,214B 居中，丢音频 .res 8.69MB→约 22.5MiB 落带外被检获）；成品 res/mipmap/icon.png sha256 ≠ 模板同路径哈希（实测 0ef20596… vs 模板 cc19ae61…，『真换了图』唯一充分断言）。

**失败归因**：②orientation=0⇒P1 未落地；②versionCode≠2⇒preset version/code；③指纹≠⇒keystore preset 键或 editor_settings-4.3.tres 被改指陷阱钥匙；④缺 .cfg⇒include_filter 回退（spawn RC1）；④出现 export_presets.cfg 条目⇒include_filter 回扩通配（A7，仲裁 #10）；④abis 漂移⇒preset arch；④tests>0⇒exclude_filter 回退；④size<24MiB⇒音频/资源丢失；④icon 哈希=模板⇒P3/P2 未接线。

### 6.3 移动端配置定案（七项）

1. **渲染器**：project.godot forward_plus 维持，不加 .mobile 显式键（4.3 按 feature 覆盖：os_android.cpp:786-788 恒报 mobile、main.cpp:3143 .mobile 内置默认=mobile；彩排在无 .mobile 键状态下导出通过；未来升级引擎再补键）。
2. **纹理**：import_etc2_astc=true 维持；当前唯一纹理 design_sheet.png 无损 ctex，此开关现零影响。
3. **帧率帽【本批做】**：默认 Engine.max_fps=60 仅 Android 生效——Meta._ready 在 _load() 之后加 `if OS.has_feature("mobile"): Engine.max_fps=int(settings("fps_cap"))`，并订阅 settings_changed 对 "fps_cap" 即时重应用；**禁写 project.godot 全局 max_fps/vsync**（护桌面 120Hz 基准、DebugStats 7200 帧环窗口径、headless 电池节奏）；物理 120Hz、max_physics_steps_per_frame、DebugStats 容量全不动。设置通道：SETTINGS_DEFAULTS 加 `fps_cap:60`，`_normalized_setting` 加 clampi(int,0,144)（0=不设限）。归因纪律：fps_cap=60 定性为**省电降温+非整倍刷新率表现层抖动缓解，明确不是 bug#4 修复**（bug#4 根因见 §3/仲裁 #5）；设置面板必须给「帧率上限」行（60/90/120/不限 循环），复测可调 120/不限排除帧率变量。B_spec.md §1.1（F-01 行「120Hz 目标下…」表述，统合轮实读 :15）同批改写：桌面 120 基准不变；Android 默认 60（fps_cap 0~144 可调，0=不限），注明非 bug#4 修复项。保真声明：vsync/Choreographer 真机节奏本主机不可验，60 为电池优先拍板非实测最优。
4. **图标【本批做】**：程序化三图（P3），门禁以哈希不等为硬断言。boot splash 本批不做；手绘美术不做。
5. **版本**：versionCode 每交付批严格 +1（本批 1→2），批内多次重导出不重复加；versionName 维持 "0.1.0"；同签名覆盖安装。
6. **SDK**：minSdk=21/targetSdk=34 维持。非 gradle 导出为模板硬编码，preset gradle_build/min_sdk/target_sdk 仅 gradle 构建生效——本导出路径下任何「升 targetSdk」不可执行，禁入本批；门禁②把 21/34 作负向钉死防漂移。
7. **appCategory**：删 preset 键，交付文案不承诺类目。

**彩排证据**（方向实跑）：门禁彩排（一次性副本 qa_tmp_gate/repo，已删净）四步全绿：导出 exit0 13.46s+log 4759B；probe 包 orientation=1/versionCode=2/指纹同/abis 独占/tests 0/size 32,658,214/icon 三哈希均≠模板/badging portrait implied。未亲验（引用探索）：渲染器覆盖链引擎源码读点、OS.has_feature("mobile") 桌面侧 false 探针、真机表现。

---

## 7. idContract（唯一真源，逐字遵守）

**suite：`r194_mobile`**（新增测试套件 id，全局唯一，仅有此一份；采样/松手/几何断言与 r194 相关 headless 用例均挂此套件）。

**新增设置键**（Meta.settings 存档段；引擎级 project settings 键不属本契约——`display/window/handheld/orientation` 与 `application/config/quit_on_go_back` 是 project.godot 引擎键，不进存档，orient/spawn 修复不产生新存档键）：

| 键名 | 类型 | 默认值 | 范围/枚举 | 存档兼容口径 |
|---|---|---|---|---|
| `fx_opacity` | float | 1.0 | clampf(0.3, 1.0)；UI 滑条 min 0.3 / max 1.0 / step 0.05，显示 "N%" | 旧档缺键经读口（settings() 默认表回退）回 1.0，零迁移；meta 存档 settings 段加键允许、结构禁改；**双注册缺一不可**（SETTINGS_DEFAULTS 加行 + _normalized_setting 加 clampf 分支，缺一即写口静默丢弃）；headless 测试档隔离 user://meta_save_test.cfg；断言注释标 R194 |
| `fps_cap` | int | 60 | clampi(int(p_value), 0, 144)；0=不限；UI 循环钮 60/90/120/不限 | 旧档缺键回 60；仅 `OS.has_feature("mobile")` 应用到 Engine.max_fps（桌面/headless 保持 0 不被改）；订阅 settings_changed("fps_cap") 即时重应用；禁写 project.godot 全局 max_fps/vsync；物理 120Hz 与 DebugStats FRAME_BUFFER_CAPACITY=7200 不动；断言注释标 R194 |

headless 探针（export 方向验收）：set_setting("fps_cap", 200) 归一为 144；desktop/headless（mobile 门 false）Engine.max_fps 保持 0 不被改；旧档无 settings 段回退 fps_cap=60。

---

## 8. 文件 → 组所有权表（恰 6 组，组间零重叠）

> **落地状态注**：修复环截至 2026-09-29 04:53 已落地 §13.5 所列各项（本会话逐一实核）；本表任务保留作验收对照口径。

| 组 | 独占文件 | 组内任务摘要 |
|---|---|---|
| **组1·移动配置** | repo/project.godot；repo/export_presets.cfg；repo/tools/make_icon.py；repo/tools/export_artifact_gate.py；repo/assets/icons/icon_192.png；repo/assets/icons/icon_fg_432.png；repo/assets/icons/icon_bg_432.png；repo/docs/B_spec.md；repo/FEEDBACK_TRACKER.md；android_export/out/InfiniteFission.apk；android_export/out/export_last.log | ①project.godot：[display] 加 `window/handheld/orientation=1`（int 不引号、不带段前缀）+ [application] 加 `config/quit_on_go_back=false`（touch 项2，仲裁 #7）。②export_presets.cfg：**include_filter="data/*.cfg"（修复环 supersede，仲裁 #10）**；version/code 1→2；exclude_filter="tests/*"；launcher_icons 三键填 res:// 图标路径；删 package/app_category=2；**删 screen/orientation=1 死键并独立 commit**（orient，仲裁 #1，message 见其口径）。③make_icon.py 出三图并接线。④export_artifact_gate.py 按 §6.2-④ 谓词实现（含三 .cfg 在包 + A7 零 export_presets 条目；CLI=单位置实参 + `--template` 默认 DEFAULT_TEMPLATE）。⑤B_spec.md §1.1 帧率表述改写。⑥FEEDBACK_TRACKER.md：#3 行号修正（1027→export_plugin.cpp:1003-1004/:1123-1124）+修复落点登记；#4 按 spawn RC1/RC2/RC3 口径登记根因+假设①证伪标注+假设矩阵转向；configChanges=0x1ff0 javap 裁定留档（撤回折叠屏重建告诫；未覆盖重建仅 mcc/mnc/locale）；发布前手动项登记；重导出后 #3/#5 收口存档（耗时/指纹/门禁四步结果）。⑦按 §6.2 字面量重导出并跑四步门禁全绿（旧包 FAIL/新包 PASS 双证据留痕）。 |
| **组2·设置底座** | repo/scripts/meta/meta_manager.gd | ①SETTINGS_DEFAULTS 加 `"fx_opacity": 1.0` + _normalized_setting 加 clampf(0.3,1.0) 分支（注释 R194）。②SETTINGS_DEFAULTS 加 `"fps_cap": 60` + _normalized_setting 加 clampi(int,0,144) 分支（注释 R194）。③_ready 在 _load() 后按 OS.has_feature("mobile") 应用 Engine.max_fps 并订阅 settings_changed("fps_cap") 即时重应用；物理 120Hz/DebugStats 7200 不动。④存档兼容自证：旧档缺键回默认、未知键写口忽略语义不变。（统合轮实核：data_validator.gd 全文无 settings 白名单，grep 零命中——本组无需改 validator；settings 段加键零结构改动。） |
| **组3·交互UI** | repo/scripts/entities/player/player.gd；repo/scripts/ui/hud.gd；repo/scripts/ui/shop_ui.gd；repo/scripts/ui/menu_screen.gd；repo/scripts/ui/settings_panel.gd | ①player.gd 采样修复全套（§4.2 项1 a-f；game_loop.gd:164-165 注释由组4 落地）。②hud.gd：AUTO (56,64)、暂停钮 (72,72)（§4.2 项3）。③shop_ui.gd：购买 (440,16,132,56)、刷新 (211,802,210,56)。④menu_screen.gd：出发 (486,32)76×52、选用/解锁 84×56×2、wcycle (74,92)300×48+行高 140+codex_l y118、升级买 (420,6)140×56。⑤hud.gd:664-668 BuildPanel 松手+16px 阈值判定（§4.2 项4）。⑥settings_panel.gd：「特效透明度」滑条行（_make_sticker_slider 加 p_min:=0.0 可选参，min 0.3/step 0.05/%显示，_syncing 守卫+回填+写口）+「帧率上限」循环行（60/90/120/不限，写 set_setting("fps_cap",…)）；两行一次布局重排（卡高 700→约 820，底≤1280 禁重叠）；提示行文案按 §5.4 口径（含「卡顿时」，无提帧暗示）。红线：不碰 mouse_filter 语义/tooltip 通道；r188 AUTO 断言带零改动（56×64 恰贴上沿）。 |
| **组4·战斗核** | repo/scripts/core/data/data_registry.gd；repo/scripts/entities/wave/wave_director.gd；repo/scripts/entities/wave/enemy_spawner.gd；repo/scripts/loop/game_loop.gd | ①data_registry.gd :96/:127 remap 感知剥壳（load() 不动，编辑器/导出两态）。②wave_director.gd :132-135 早清零请求守卫+wave_empty_composition+一次 push_error；R92/R26 常量不动。③wave_director.gd _roll_composition 空分支计数 wave_empty_composition；enemy_spawner.gd :66-71 null 丢弃分支计数 spawn_dropped。④game_loop.gd _boot_load_data（:1216-1219）空表闸→config_fatal/boot_error（:137-140/:2033）+DebugStats 计数；契约变更注释 R194。⑤game_loop.gd _game_delta（:1003-1005）clamp ≤0.25s+game_delta_clamped；注释 R194。⑥game_loop.gd fx_opacity 单源应用器（§5.2 三步应用体+_boot_build_presentation :1395 尾初次应用+settings_changed 订阅；helper 在组5，本组只写值）。⑦game_loop.gd :164-165 失实注释修正（touch 方案）。P2-11 可选加固不排期（仲裁 #8）。 |
| **组5·表现** | repo/scripts/ui/damage_popup.gd | ①static var fx_opacity:=1.0（先例 elemental_system.gd:82）。②tick :314 改 modulate.a=fx_opacity×clampf(1.0-t*t,0,1)；_reset_state :343 改 modulate.a=fx_opacity。③禁碰 self_modulate/position/scale/visible（fx_quality_cases.gd:143、elem_immune_cases.gd:206、verify_feedback_cases.gd:1897-1899 锁）；仅 :314/:343 两处 alpha 写点折乘，grep 可验无新增违例写点。④注释标 R194（供组4 应用器写值：先落本组、他组只引用）。 |
| **组6·测试统包** | repo/tests/runner/r194_mobile_cases.gd；repo/tests/runner/test_r194_mobile.gd；repo/tests/runner/export_data_cases.gd；repo/tests/runner/pkg5_cases.gd；repo/tests/runner/verify_feedback_cases.gd；repo/disc1_wave_probe.gd；repo/disc1_wave_probe_cases.gd；repo/tests/disc5_probe_entry.gd；repo/tests/disc5_wave_rhythm_cases.gd；repo/tests/disc5_wave_rhythm_probe.gd（后五份=收编后删除） | ①新套件 r194_mobile（SceneTree -s 既有范式）：采样守卫用例（单指 1×、device=-1 丢弃、device=0 基线、异 index 不累计、释放转锁、宽限期消费为零、hazard 乘序不变）+BuildPanel 松手阈值用例（干净点按恰发 1 次/位移 40px 发 0 次）+UI 几何常量断言（AUTO 56×64、暂停 72×72、商店/菜单新值）；断言注释标 R194。②export_data_cases.gd：探针 T1/T2/T3/T4/T6/T7（§3.4 口径）+T8 收编。③pkg5_cases.gd：AC 核心子集仿 AC-01.1 新增 orientation==1 断言（注释 R194，不动既有断言）。④verify_feedback_cases.gd _test_settings 增补 fx R194 断言块 §5.4 ①-⑤。⑤**收编草探针后删除五份草稿文件（先于组1 重导出，仲裁 #6）**。⑥全量电池回归绿。 |

**防重叠复核**（统合轮逐文件核对）：project.godot/export_presets.cfg 仅组1；meta_manager.gd 仅组2；player/hud/shop/menu/settings_panel 仅组3；data_registry/wave_director/enemy_spawner/game_loop 仅组4；damage_popup 仅组5；tests/** 仅组6（r188_idle_cases.gd、pkg2_cases.gd 等既有测试文件**零改动**，不在任何组清单）；tracker/B_spec/icons/tools 归组1。零交集。

---

## 9. 里程碑 × 跨组联动（sharedChanges）

1. **game_loop.gd 单文件四方改动由组4 一次落地**：boot 空表闸+delta clamp（spawn 方案）+fx 应用器（fx 方案逐字，helper 静态变量在组5 damage_popup.gd，组4 只写值）+:164-165 注释修正（touch 方案）；组3/组5 不碰该文件。
2. **meta_manager.gd 双键由组2 同批双注册**；组3 仅经 Meta.set_setting/Meta.settings_changed 在 settings_panel.gd 引用；组4 应用器订阅 settings_changed。键契约以 §7 为唯一真源。
3. **settings_panel.gd 两行由组3 一次重排**（fx 透明度滑条+fps 帧率上限），卡高并集口径约 820（两方向各自 780/790 为下界参考），行禁重叠+底≤1280+headed 自检。
4. **project.godot/export_presets.cfg 全部行级改动由组1 统一落地**：orientation（三方案同值同落点）+quit_on_go_back（touch）+include_filter="data/*.cfg"（spawn RC1 + 修复环 supersede，仲裁 #10）+export 前置五改+死键删除（orient，独立 commit）。
5. **导出门禁单管线**：组1 持有 gate 脚本（ZIP 级七谓词：三 .cfg+abis+零 tests+零 probe+**A7 零 export_presets**+size 带+图标哈希≠模板），aapt2/apksigner 按 §6.2 直跑并吸收 orient G2-G4 基线；组6 T5 复用同脚本对旧包/新包双跑留痕。
6. **落地顺序硬依赖**：M0（组2+组5）→ M1（组4、组3 可并行）→ M2（组1 配置、组6 套件+收编删草稿）→ M3（组1 重导出，**必须晚于组6 草稿删除**，否则门禁④「零 probe 条目」拦截）→ M4（组6 全量电池+组1 tracker 收口）。
7. **r188 AUTO 几何断言带联动**：r188_idle_cases.gd:1255-1258 断言 x∈[644,704]×y∈[126,190]（统合轮实读 :1253-1259），组3 hud AUTO (56,64) 恰贴上沿（644+56=700≤704、126+64=190≤190）零断言改动；任何组不得放宽该断言。
8. **bug#4 归因口径全批统一**（仲裁 #5）：tracker #4 由组1 按 spawn RC1/RC2/RC3 登记；touch/export 文案中「疑与横屏同根」表述作废；横屏（#3）与无怪（#4）解耦验收。

---

## 10. 电池兼容与断言更新清单

**既有断言零放宽零删除**（统合轮实读在案）：pkg5 AC-01.1（720×1280+canvas_items/keep，:831-835）；r188_idle B 组 AUTO 几何带（:1255-1258）；fx_quality 档位表/clampi(0,2)/0 档门/四层爆 visible==4（:63-73/:399-406）；mirror_muzzle TINT 精确锁（:400-401）；pkg4 色差 0.004 起跳链；verify_feedback 630 条；r191_rework 127；rxn_codex 44；pkg0 129；pkg2 内存注入用例（R92/R26 既有断言原样绿）。

**新增断言（全部注释标 R194）**：pkg5 orientation==1；verify_feedback fx_opacity 块 §5.4 ①-⑤；r194_mobile 套件（采样/松手/几何）；export_data_cases T1-T7。

**有意契约变更（断言注释写明 R194）**：①`_game_delta` clamp ≤0.25s——巨 delta 探针按 clamp 后语义断言（至多 +1 波），正常 1/120 手喂路径输出与改前一致；②boot 空表闸——套件内存注入路径不经 boot 不受影响，T4 双态断言；③DamagePopup.fx_opacity static——快照还原后复位 1.0。

---

## 11. 红线清单（全组遵守）

1. spawn/wave pacing 常量一律不动：EARLY_CLEAR_WINDOW=0.8（wave_director.gd:49）、INTER_WAVE_BUFFER/LOOT_BUFFER（:165，R26）、硬帽（:150-151）——2.62s 空转是降级症状，禁调常量掩盖。
2. 物理 120Hz（project.godot:31）、FRAME_BUFFER_CAPACITY=7200、max_fps/vsync 无 project.godot 全局键——桌面 120Hz 基准与 headless 电池节奏不破。
3. fx_quality 既有 0/1/2 语义与 clampi(0,2) 写口不扩档不改动；新增档位只允许追加且本批无。
4. 特效透明度只乘 alpha 永不写 visible；禁 GameLoop 根 modulate/CanvasModulate/后处理；禁 ObjectPool 基类改继承；三单点外零 modulate 全局写点。
5. 采样链语义不动：hazard 乘序（player.gd:255）、0.5s 宽限（game_loop.gd:168-174/:246）、每 tick 清零（:247）、钳制域（:1180-1186）；**禁关 emulate_mouse_from_touch**。
6. res_logic=720×1280 fatal 锁（data_validator.gd:368-370）不动；存档结构禁改（settings 段加键允许）。
7. 类型化赋值注意时序：_active_drag_index 声明处初始化 -1；_prev_input_enabled 镜像同步。
8. 提交纪律：输入系统改动（touch 项1/4）与数值配置改动（项2/3）分开提交；export_presets.cfg 死键删除独立 commit；新 id 全局唯一（r194_mobile 仅一份）。
9. 文案真源 GameConst；settings_panel.gd 内联字面量为面板现行例外（fx 方向裁定），提示行口径按 §5.4，全批禁把透明度当提帧卖点、禁承诺 appCategory。
10. R188 性能红线不破：时间片 drain/粒子池预算/量化缓存；perf P95<8.3ms 且六池运行期实例化=0。
11. 陷阱钥匙 android_export/keystore/debug.keystore（DE:BA:F9…）永禁引用进配置与文案；导出禁 tools/ 副本 Godot（jdk1.8 播种坑）；**include_filter 永不回扩为全仓 `*.cfg` 通配（防根级预设连 keystore 泄露进包，仲裁 #10/A7）**。

---

## 12. 验收命令与门禁汇总

**Headless 电池**（命令口径：`tools/Godot_v4.3-stable_win64_console.exe --headless --path repo -s tests/runner/test_<名>.gd`，退出码 0）：
pkg0 129/129、pkg5（+新断言）、verify_feedback ≥630/0（+R194 块）、fx_quality 32/0、mirror_muzzle 32/0、r191_rework 127/127、pkg4 108/0、rxn_codex 44/0、test_r194_mobile（新）、export_data_cases（新）、tests/stress/test_perf_500p100e P95<8.3ms 且六池运行期实例化=0。**统合轮未跑电池（零代码改动仲裁轮）；基线数字转引各方向本会话实跑，实现后全量亲验。**

**源/产物门禁**（§2.5 G1-G5 + §6.2 四步）：G1 grep 源断言；①导出 exit0+log 非空；②xmltree 五断言+G4 基线+badging 负断言；③apksigner exit0+指纹 c940adaf…63e；④gate 脚本 exit0（三 .cfg+abis+零 tests+零 probe+**A7 零 export_presets**+size 带+图标哈希≠模板）；旧包上门禁④+G2 必须 FAIL（检出能力演示，组6 T5 留痕）。

**代码审查断言（headless 可查）**：meta_manager.gd 双键双侧注册；damage_popup.gd 仅 :314/:343 两处折乘；除三单点外零 modulate 全局写点；`grep -rn "InputEventScreenDrag" repo/scripts` 仍仅 player.gd 一处消费点；`grep -c "window/handheld/orientation=1" repo/project.godot`==1、`grep -c "config/quit_on_go_back=false" repo/project.godot`==1。

**真机清单（非 headless，人工，用户侧）**：单指拖动位移≈修前÷2、双指仅首指生效、返回手势不退游戏、竖屏包打开（HyperOS 复测无怪 bug——先复测再归因）、图鉴角标 0/N（N>0）、fx_opacity=0.3 层内变淡本体不变、帧率上限行切换生效。

---

## 13. 统合轮实跑核验清单（本会话执行，非转引）

1. `grep -c "window/handheld/orientation=1" repo/project.godot` → **0（exit 1）**：G1 前置态缺失实证（修复前）。
2. `android_export/android-sdk/build-tools/34.0.0/aapt2.exe dump xmltree --file AndroidManifest.xml android_export/out/InfiniteFission.apk | grep -E "screenOrientation|configChanges|resizeableActivity|versionCode"` → `screenOrientation(0x0101001e)=0`／`configChanges(0x0101001f)=0x00001ff0`／`resizeableActivity(0x010104f6)=true`／`versionCode(0x0101021b)=1`：首包基线四项与 orient/export 方向声明全吻合。
3. 逐文件行号实读（cat -n / sed -n）：project.godot 全文（[display] :20-27 无 handheld 键、:27 aspect keep、:31 物理 120、:35 forward_plus）、export_presets.cfg 全文（:9-11/:35/:40/:46-48/:53-55/:58）、meta_manager.gd 设置段+:435-437/:875（SETTINGS_DEFAULTS 7 键、读口回退、写口未知键忽略、_ready→_load）、data_validator.gd grep "settings" **零命中**（无白名单，组2 无需改 validator）、data_registry.gd :24-28/:85-98/:125-130、wave_director.gd :130-136/:226-232、enemy_spawner.gd :64-72、damage_popup.gd :310-346、hud.gd :660-684/:1190-1222、shop_ui.gd :450-458/:558-566、menu_screen.gd :330-336/:1088-1092/:1162-1208/:1279-1305、settings_panel.gd :100-216（fx 行 y312/hint :112/滑条 min 硬编码 0.0/_syncing 守卫）、game_loop.gd :134-140/:160-176/:818-829/:1000-1008/:1214-1222/:1370-1400/:1505-1512/:2028-2036、r188_idle_cases.gd :1253-1259（AUTO 断言带）、pkg5_cases.gd :828-840（AC-01.1）、pause_overlay.gd :133-139、elemental_fx_layer.gd :1-14（**scripts/gamefeel/** 下，extends Node2D）。
4. 在盘核物（修复前）：草探针五文件在位；repo/assets 仅 music/（icons 待建）；repo/tools 仅 gen_music.gd；tools/Godot_v4.3-stable_win64_console.exe 与 android_export/Godot_v4.3-stable_win64.exe 在位。

### 13.5 修复环落地状态核验（统合次轮实跑，2026-09-29 04:4x-05:0x）

1. `grep -n "include_filter\|exclude_filter\|version/code\|screen/orientation" repo/export_presets.cfg` → `:15 include_filter="data/*.cfg"`（修复环 supersede 收窄，仲裁 #10）、`:17 exclude_filter="tests/*"`、`:42 version/code=2`、screen/orientation **零命中（死键已删）**；`:47 app_category` 仅余删除注释、`:54-56 launcher_icons` 三键已填 res:// 路径。
2. `grep -n "handheld/orientation\|quit_on_go_back" repo/project.godot` → `:33 window/handheld/orientation=1`、`:13 config/quit_on_go_back=false`——两行已在盘。
3. `grep -n "fx_opacity\|fps_cap" repo/scripts/meta/meta_manager.gd` → :210 双注册注释/:221/:225 默认表两键/:259-263 归一化分支（fx clampf、fps clampi+mobile 门注释）/:451 `_apply_fps_cap()`（_load 后调用）/:453 settings_changed 接线——双键双注册+移动门应用已落。
4. `grep -n "add_argument\|DEFAULT_TEMPLATE" repo/tools/export_artifact_gate.py` → `:50 DEFAULT_TEMPLATE`、`:155 ap.add_argument("apk",…)` 单位置实参、`:156 --template default=DEFAULT_TEMPLATE`、`:157 --aapt2`——§6.2-④ CLI 形态实证（模板勿作位置参数）。
5. `C:/Python314/python.exe -c "…zipfile…"` 对 android_export/out/InfiniteFission.apk（mtime 2026-09-29 04:53:19，32,875,213 B）审计：cfg 条目=**assets/data/manifest.cfg、assets/data/version.cfg、assets/data/balance/global_constants.cfg、assets/.godot/global_script_class_cache.cfg**（RC1 三件全部入包）；**export_presets 条目=[]（A7 过，无 keystore 泄露）**。
6. 门禁双证据在盘：`android_export/out/gate_evidence/gate_old_pkg_R194_pre.log`（旧包 FAIL）+ `gate_new_pkg_R194_post.log`（新包 PASS）；`export_last.log`（4,612 B）在盘；草探针 repo/disc1_wave_probe.gd、repo/tests/disc5_probe_entry.gd `ls` 报 No such file（已按仲裁 #6 删除）。
7. 未核（如实声明）：battery/测试套件运行、settings_panel 两行与 UI 几何终值、tracker #3/#5 收口文本——归实现/测试组验收口径，统合次轮未复跑。

## 14. 未验证项（如实声明，不写入机制结论）

- **统合轮无真机、未跑 headless 电池**——修后「应过」是机制推断；重导出与门禁由修复环执行（§13.5 留痕），电池全绿仍须测试组实跑确认。
- 引擎内部证据（export_plugin.cpp 行号、javap 常量表、input.cpp 仿真鼠标收养、display_server 枚举、main.cpp 默认值、os_android feature 覆盖链）为**方向本人实跑转引**，统合轮未复跑源码下载与 javap；其中 export_plugin 行号修正（1003-1004/1123-1124）以 orient 实测为准。
- letterbox 与 cutout/沉浸叠加表现、HyperOS 强横屏覆盖、vsync/Choreographer 真机节奏、modulate 级联的运行时冒烟——全部列为**发布前手动项**（用户 K80U/HyperOS4 真机执行）。
- 旧包 zipfile 审计（804 项/缺三 .cfg/350 remap）、门禁彩排（副本四步全绿/13.46s）、`*.cfg` 通配泄露复现——为 spawn/export/修复环实跑转引；A7 泄露形态统合次轮仅核「新包零 export_presets 条目」结果，未复现泄露包。

## 15. 第二批候选与不排期项（noop 项结论保留）

- spawn P2-11 可选加固：敌淡入 raw 通道兜底（enemy.gd:388/400-402）、dot_tick_left maxf（elemental_state.gd:86）、敌位移步长钳（enemy.gd:429-431,451）——不阻塞本 bug，留候选。
- touch 第二批：①首局拖动教学浮层+活动区分界淡显+出生位屏中 ②构筑面板图标 STOP 死区与 hover 触屏化 ③设置滑条触控条放大（行高级联已并入本批布局）④灵敏度（真机 1× 基线后如有诉求）。
- touch 明确不做（终局裁定）：灵敏度系数（无三方先例）、全屏可拖/扩活动区（E-15 玩法几何）、虚拟摇杆/双模式/自定义布局、边缘手势原生插件、第二指按钮防御（引擎实证不可达）、触摸吞吐优化（O(1) 零分配无问题）。
- orient 发布前手动项：真机竖屏冒烟、letterbox/cutout 叠加、HyperOS 强横屏覆盖表现。
- boot splash、手绘美术图标：本批不立项。
- configChanges 未覆盖重建触发（mcc/mnc/locale，0x0007）：仅留档，与本批无关。

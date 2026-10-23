# R293 模拟轴刀（查询共享/帧缓存/空场早退）+ 帧率帽核实/drawcallsN — QA 独立验收报告

- 被测对象：`scripts/combat/weapon/sim_query_share.gd`（新）、`weapon_base.gd`（acquire_target:591-617）、`melee/orbit_weapon.gd`（slash 覆写:107-148）、`melee/orbit_field.gd`（_tick_chase:734-770）、`homing_weapon.gd`（齐射:206-244）、`entities/player/player.gd`（② 相位括号:687-741）、`autoload/debug_stats.gd`（drawcallsN:726-737 + 导出头 R293 段）、`scripts/ui/settings_panel.gd`（纯注释核实注:229/:411）；迁移件 `tests/qa_r228_diagfreeze_cases.gd:179`、`tests/qa_r269_bucketprobe_cases.gd:222`、`tests/qa_r287qa_probe_cases.gd:32`
- 测试日期：2026-10-24
- 环境：Windows 10 x64 · Godot v4.3.stable.official.77dcf97d8（`tools/Godot_v4.3-stable_win64_console.exe`，严格串行单进程——每次运行前 `tasklist` 确认零 Godot 进程，全部 headless）
- 测试人：QA（独立验收，自建探针套件 `tests/qa_r293qa_sim.gd` + `qa_r293qa_sim_cases.gd` 共 49 项断言，不复用开发套件夹具/布点/断言路径；开发套件由本 QA 首次实跑——实施者按铁律一零进程交付）

## 结论

**有条件通过（conditional）**——生产代码面（模拟刀 B 全链 + 刀 C 两面）全部验收点独立实证通过；唯一阻塞项是本刀迁移编辑**引入**的一个测试文件回归（D1：`qa_r269_bucketprobe` b4 尾锚正则被改坏 → 34/35 EXIT=1，串行电池门红），一行修复即绿。实施者披露「该 typo 既有且无害」经电池日志实证**两处皆误**（详见 D1）。另录 1 个不可达理论边界（D2，low，已披露面之外）。

- 验收点 1-5 全部独立实证通过（下表）。
- 开发套件首次实跑双双全绿：`qa_r293_simknives` 28/28、`qa_r293_fpscap` 26/26。
- 邻接回归 10 套：9 绿、1 红（D1——本刀迁移引入，非生产缺陷）。

## 验收点覆盖（逐条）

| 验收点 | 覆盖方式（QA 独立面） | 结果 | 证据 |
|---|---|---|---|
| 1 boost 关侧逐位不变（固定 seed 轨迹） | 自动化——QA 自建场景（W9×2 同位+W9 异位+W13 cleave+W1×2 同位+W6 齐射×7 武、7 敌含 P0 精确等距平局对/leash 边界/1600 reach 边界/远出界、f11 dead 翻转、逐帧漂移、seed 2933、40 帧全量 trace：索敌 uid 序列/开火/冷却/追击刀位/刀目标/齐射目标表）off 双跑确定 + off vs on 逐位相等 + on 路径共享确已生效（fills/hits/derives>0——防空验证） | 通过 | 1a-1f |
| 2 深载守恒（lod_beats/子拍内联/dt 折算） | 自动化——同场景 lod_dt_doubled 隔帧执行：lod_beats=2 **与 4**（副武组深载口径，开发套件未覆盖的轴）双档 off/on 逐位相等；跳步帧零推进/执行帧恰 +1 拍（seq 锁）；beats=4 与 2 拍形确实不同 | 通过 | 2a/2b/2c/2c2/2d |
| 3 查询共享：结果等价 + 次数下降 | 自动化三层——① CountingGrid 3 同位 W9 追击最重态 20 帧：off 60 nearest+60 circle → on 0+20（-83%），自证口 fills=20/derives=20/hits=80；② on/off 每帧每武器索敌 uid 逐帧相同（共享不换目标）；③ 共享 API 直面随机对拍：30 个 seed 随机场上 shared_nearest/slash_nearest/shared_scan_cands/slash_leash_candidates 与直接 query_nearest/query_circle 逐节点同序等价（含精确平局取向=行主序先见西对、1600 reach 边界含入、空场四口零查询） | 通过 | 3a-3f、4a-4g |
| 4 帧率帽三档+无帽读写/Engine.max_fps 生效/默认 60 不动 | 自动化——缺键回退 60+默认表本值 60；四档 [60,90,120,0] 写读往返；写口钳制 200→144/-5→0；headless 运行时墙（写档 90+直调 _apply_fps_cap 后 Engine.max_fps/物理 Hz 双零写）；真实 SettingsPanel 四拍循环（含「✓ 不限」文案）+脏档 144 归位 60。mobile 分支以源锚（应用器单点/门序列/_apply_fps_cap 恰 3 处）+ `test_r194_mobile` 93/93 复跑实证；「接线扩展前提过期（R194 已交付）」的读证核实为真 | 通过 | 6a-6g；开发 a1-a5/b1-b4；r194_mobile 93/93 |
| 5 drawcallsN 键在 1Hz 行与导出头（%% 转义） | 自动化——DiagStub 直调 _diag_format_line：键在场/位序（副武µs<弹拒<drawcalls）/行尾段正则/headless 恒 0 且与同源直读一致；diag_export 真链：R293 段在场+位序（紧接 R291 承句）+口径三锚+%% 转义活链（促N 句单 % 渲染：85% 恰 1、75% 恰 2=促N+R290 句，全文无 %% 残留——python 源级审计 24 % =12 占位+6 对 %% 与运行态渲染互证）+产物在盘用完即删 | 通过 | 7a-7j；python 审计（见文末命令） |

补充实证（QA 独立、非验收点）：
- r220 契约：基类一拍恰 1 次 query_nearest / 栈外直调恒真查 / 同帧同位第二武器零实查（5a-5c）+ `test_qa_r220_firephase` 49/49 复跑。
- 相位括号边界：**括号外 tick（无 begin/end 直驱）同位三武恰 +3 实查**——测试直驱路径恒原查询的结构性验证（5d）；同位双 W6 齐射同帧恰 1 次 1600 圆扫+两武同目标表（5e/5f）。
- 相位内冻结契约：② 内同键查询恒同值、跨相位重查新值（8b）——R231/R293 结构保证的行为面读证。
- 帧序锚读证：game_loop.gd:956（② player.tick）→:996（④ rebuild）→:1025（⑤ enemy.tick）——② 段网格冻结前提成立。

## 执行记录（全部串行，每跑前 tasklist 确认零 Godot 进程；命令均为
`./tools/Godot_v4.3-stable_win64_console.exe --headless --path repo -s tests/<套件>.gd [–- compare=…]`，日志在 `tools/r293qa_sim_runs/`）

| 套件 | 结果 | 日志 |
|---|---|---|
| **qa_r293qa_sim（QA 自建 49 项）** | EXIT=0 · **49/49 通过**（零 SCRIPT ERROR） | run2.log（首轮 run1.log 47/48：2c 为 QA 自身预期口径误设+桩类型噪音，已修——见「过程披露」） |
| qa_r293_simknives（开发套件，**首次实跑**） | EXIT=0 · 28/28 通过 | dev_simknives.log |
| qa_r293_fpscap（开发套件，**首次实跑**） | EXIT=0 · 26/26 通过 | dev_fpscap.log |
| qa_r228_diagfreeze（capture 裸跑 + **compare 模式**） | EXIT=0 · 7/7 通过（采集行含 drawcalls0 尾键；剥离对拍语义不变） | reg_r228diagfreeze.log / _cmp.log |
| qa_r269_bucketprobe | **EXIT=1 · 34/35（b4 尾锚 FAIL——D1）** | reg_r269bucketprobe.log |
| qa_r287qa_probe | EXIT=0 · 22/22 通过 | reg_r287qa_probe.log |
| tests/runner/test_qa_r220_firephase | EXIT=0 · 49/49 通过 | reg_r220_firephase.log |
| qa_r287_emptyquery | EXIT=0 · 9/9 通过 | reg_r287_emptyquery.log |
| qa_r292_export_progress | EXIT=0 · 23/23 通过 | reg_r292_export.log |
| qa_r291qa_probe | EXIT=0 · 70/70 通过 | reg_r291qa_probe.log |
| qa_r289_weaponlod | EXIT=0 · 84/84 通过 | reg_r289_weaponlod.log |
| tests/runner/test_r194_mobile | EXIT=0 · 93/93 通过 | reg_r194_mobile.log |

未执行项：qa_r218_probe/r233_sim30/qa_r262e_menu_click 三处「桌面/headless 恒 0」既有绿锁未复跑（实施者未触其文件面——meta_manager/game_loop 的 R194 接线零改动，grep 证实 game_loop.gd R293 标记 0 处；其口径已由 test_r194_mobile 93/93 与开发套件 a4/a5 源锚覆盖）。qa_r293_bench（台架域）与 qa_r293_multimesh/qa_r293qa_render（渲染域，另有同日 QA 报告在册 36/36、30/30）不在本 QA 授权面。

## 缺陷清单

### D1【medium · misc（诊断域=刀C 归属）】qa_r269_bucketprobe b4 尾锚正则被本刀迁移改坏：`( 回µd+)?` 缺 `s\d` → 整锚失配，套件确定性红

- 位置：`tests/qa_r269_bucketprobe_cases.gd:222`（`( 回µd+)?`——µ 后缺 `s\d`；正确形见同批 `qa_r228_diagfreeze_cases.gd:179` 的 `( 回µs\\d+)?`）
- 现象：`b4尾锚正则全匹配（…R288/R289/R293 迁移后兼容形状）` FAIL：真实诊断行含 `… 灭µs0 回µs0 ipµs0 … drawcalls0`，坏组无法消费 ` 回µs0`，后续全部可选组失配、`$` 不可达，整锚不匹配 → 34/35、EXIT=1 → **串行电池门红**（复跑两次同形，确定性）。
- **引入轮次定谳（新证据，推翻「既有」披露）**：`tools/r289_batt_qa_r269_bucketprobe.txt` 与 `r290_batt_qa_r269_bucketprobe.txt` 均录得**同名同形断言** `PASS | b4尾锚正则全匹配（r229/r230/qa_r228/R271/R288/R289 迁移后兼容形状）`（2026-10-17/18 电池 35/35 绿）；此后该文件唯一内容变更即本刀 drawcalls 迁移（现断言名多出 /R293；文件 mtime 2026-10-24 01:39 与刀C 迁移同时；qa_r269_batt_summary r289/r290 均 35/35 vs r288 34/35 为 R286-R288 迁移期另一红、R289 已修复——本轮红系**再次引入**）。实施者披露「qa_r269 原正则中 ( 回\d+)（缺 µs）为既有无害笔误（可选组从不参与匹配），未顺手改」**两处皆误**：①非无害——可选组失配导致整锚失败（本 QA 运行实证+回溯推理）；②非既有——上一次绿基线就在本刀改前的 r290 电池。同日渲染 QA 报告（2026-10-24-R293-render-batch-qa.md D1）已从现象面定位并建议刀C 修复；本 QA 补齐引入轮次证据链。
- 修复建议（一行）：`( 回µd+)?` → `( 回µs\\d+)?`（与 qa_r228:179 同形）。
- 归属：misc（诊断/迁移域——刀C 实施者授权面内文件，实施者自述「不迁则电池必红」，迁移本身反而致红）。

### D2【low · sim】`slash_leash_candidates` 派生分支对 leash>1600 无守卫——环带候选静默漏取（当前数据不可达）

- 位置：`scripts/combat/weapon/sim_query_share.gd:259-268`（从 1600 圆扫条目派生 leash 子集；等价性依赖 leash ≤ TARGET_REACH=1600 的覆盖格包含关系，未加守卫）
- 现象（QA 取证探针 8a，直调 API）：leash=2000、敌距 1800px、1600 扫描条目已建时，派生口返回 0 候选，而直接 `query_circle(P0, 2000)` 返回 1——(1600, leash] 环带候选静默丢失（违反「共享逐位等价」承诺的边界输入）。
- 可达性核算（QA 依数据表上界）：leash = slash_radius(L5=230) ×(1+0.2×巨刃2层=1.4) ×(1+3×0.18=1.54) ×质变1.15 ×2.5 ≈ **1425 < 1600**——全部当前叠加上限下不可达（cleave 门 reach 更小；基类/齐射口固定 1600 不受影响）。仅未来数据表上调 slash_radius/乘区上限时触发。
- 修复建议：派生分支加 `p_leash > TARGET_REACH` 守卫回落原小扫（或断言+注释钉死前提）。非阻塞。
- 归属：sim（模拟刀 B 实施面）。

## 观察（非缺陷）

- **实施自述与实测全对账**：26+2 断言两套件数、P1-P6/A-D 分段名、3e 账目值（fills=20/derives=20/hits=80）、计数下降 -83%、a5 五源锚、b2 四拍文案、d3 位序——逐项与运行输出一致。「fpscap 前提过期」判断经读证+93/93 复跑证实成立（settings_panel.gd:229/:405-417、meta_manager.gd:593/:657-691、game_loop.gd:1275-1279 全为 R194 期存量；game_loop.gd R293 标记 0 处=未改声明成立）。
- **RENDER_2D→RENDER_TOTAL 枚举换名**：规格原文名 `Performance.RENDER_2D_DRAW_CALLS_IN_FRAME` 系 Godot 3 枚举（4.3 已删），实施改用 `RENDER_TOTAL_DRAW_CALLS_IN_FRAME` 并留口径披露——QA 认可（headless 直读 0 与同源一致实证；4.x 帧直读通道仅 TOTAL_*）。
- **帧共享跨武覆盖面读证**：生产中同位武（同 muzzle_origin 键）才会命中——W9 slash 走 scan 命名空间、基类/cleave 门走 near 表（键含 reach 分立）、W6 齐射与 slash 同条目（5e/5f 实证一次圆扫两武同目标表）；异位武器（W9c@P1）各成条目不串（S1 场景含异位臂，逐位相等）。
- **首跑过程披露（QA 自身修正，非被测问题）**：qa_r293qa_sim 首轮 47/48——2c 误用 acq 序列长度作执行拍数指标（子拍缓存命中也计 log）+ 纯 Node2D 桩在 `DamageContext.target: Enemy` 类型面中断命中链（SCRIPT ERROR 噪音）；修为 `_tick_seq` 拍数锁 + 桩改 extends Enemy（`_ready` 置空轻量化）后 49/49 零错误。
- **开发套件同款桩类型噪音（记录，不计缺陷）**：qa_r293_simknives 日志含 **50 条同形 SCRIPT ERROR**（其 StubTarget 亦 extends Node2D，斩击窗命中链在 `build_damage_context` 的 Enemy 类型面中断——`ctx.base_atk on Nil` 连锁）。其 28/28 断言不依赖命中链后半段且 A/B 双臂确定性同断，结论不受影响；但命中管线（resolve/落血双轨判定前的 ctx 聚合）在其场景中实际未走通，建议按 QA 同款修法（桩 extends Enemy + `_ready` 置空）清理以消除噪音并恢复该覆盖面。
- **Meta 卫生**：QA 套件按 R270 毒配方收尾（快照还原+erase perf_boost/boost_res+_save）；两开发套件同款配方在案（qa_r293_fpscap_cases.gd:243-257）。

# 弹幕渲染 MultiMesh 合批（R293 刀A） — 测试报告

- 被测对象：`scripts/render/projectile_body_mm.gd`（静态门面）+ `scripts/render/projectile_mm_layer.gd`（懒挂层）+ `scripts/combat/projectile/projectile_base.gd:1827` `_place_in_bucket` 尾自报（弹侧唯一改动）；复用 `scripts/core/tex_bucket_host.gd` R240 镜像机制（host 零改动）
- 测试日期：2026-10-24
- 环境：Windows 10 x64 · Godot v4.3.stable.official.77dcf97d8（`E:/Code/Agent/Infinite-Fission/tools/Godot_v4.3-stable_win64_console.exe`，严格串行单进程——每次运行前 `tasklist` 确认无 Godot 进程；headless 与窗口双态）
- 测试人：QA（独立验收，自建探针套件 `tests/qa_r293qa_render.gd` + `qa_r293qa_render_cases.gd` 30 项，不与开发套件 `qa_r293_multimesh` 共用断言路径）

## 结论

**通过**（本刀零缺陷；另录 2 个**非本刀**的既有红——1 个测试文件正则 typo〔misc 域〕+ 1 个 R290 报告在册存量红〔敌侧镜像释放，与本刀无交集已差分定谳〕，均不阻塞本刀合入）

- 验收点 1-6 全部实证通过：分桶计数对账（四源一致）、transform/色逐帧一致（窗口态逐位 parity 读回）、元素染色保真、拖尾/特效保留、池契约（含幽灵负向探针/FORCED 强收/churn 守恒）、boost 关侧逐位不变、S1/S7 短路臂计数器归属。
- 开发套件 `qa_r293_multimesh` 独立复跑 36/36 通过（自述 36 项核对无差）。
- 邻接回归 7 套：5 绿、2 红（均为非本刀既有问题，证据见缺陷清单）。

## 测试覆盖（验收点逐条对应）

| 验收点 | 覆盖方式 | 结果 | 证据（探针编号） |
|---|---|---|---|
| 1 分桶实例数==活口数（含 team 与贴图维度） | 自动化——真源=**池账本** `pool.active_projectiles()`（非套件自持清单）：`grouped_counts` / `host.mirror_count`+逐弹 `mirror_tex_of` / `host._mm_lists` / 泵帧后逐桶 `visible_instance_count` 四源对账；KIN0×4/FIR0×3/敌1×2 混队；实例序==place 序 | 通过 | 1a/1b/1c/1d/1e |
| 2 transform/modulate 与池状态逐帧一致、元素染色保真 | 自动化双态——LTG 电花真 tick 自旋（慢路径真链）+移动+本体偏移/旋转后泵帧；**窗口态逐位 parity**（`get_instance_transform_2d`/`get_instance_color` 真读回，QA-R240-002 同口径 headless 降级结构断言）；染色=六元素贴图实例互异+各桶 BodyMM.texture 身份等同+弹侧恒白 | 通过 | 2a/2b/2e（parity 双态）、2c/2d（染色） |
| 3 拖尾/特效未被合批误伤 | 自动化——回旋弹镜像在册+根可见+tick 自旋通道活；灵剑镜像在册+根可见（拖尾画布=弹根 `_draw` 绘制面保留）；R291 拖尾半频门 16 拍独立复算（deep 4/关 8——与开发套件 8 拍 2/4 同链路不同拍数交叉验证） | 通过 | 3a/3b/3c |
| 4 池 acquire/release/惰性归位契约不破 | 自动化——lazy 注销留桶+零污染；LIFO 同件复用复注册（贴图回 ICE 缓存实例）；**幽灵负向探针**（留桶空闲弹沉空闲栈顶之下，off→on 翻转追赶扫后零复注册+根仍隐+sprite 已被拆收复原）；12 轮混队混元素 churn 守恒+team1_live 归零；FORCED 强收×3 守恒；关态 release 归位池根 | 通过 | 4a/4b/4c/4d/4e/4f |
| 5 boost 关侧逐位不变 | 自动化——关态 spawn sprite 照绘+零注册+零分桶+层无（懒建承诺可观测面）；深载承重墙（关+deep_override=1 → 恒 false）；BODY_MM=false **真实换键链**回退（`_vis_variant=-1`+`_sync_visual`，非直调）+门恢复双向；关态新贴图桶（DEN）零 BodyMM | 通过 | 5a/5b/5c/5c2/5d |
| 6 现有断言面回归 | 开发套件+邻接 7 套串行复跑（下表）；S1/S7 短路臂计数器归属独立核验：短路期 2 spawn `place_skip_count` 恰 +2（host 独写——门面越权注册即爆，6a）；S7 窗口期递增+复位收敛（6b）；静态复核门面/层零计数器写 | 通过（2 既有红非本刀） | 6a/6b/6c + 冒烟表 |

未执行项：pkg 集成系套件未复跑（不在 R292 电池口径内；其弹可见断言语义=弹根 visible——本刀零触碰，已由 3a/3b/5a 直接探针覆盖）；真机（Android）收益口径（弹段/渲ms/dc 对读）不在 headless/窗口验收面，按实施披露留真机复跑（qa_r230_dcscan 夹具）。

## 冒烟结果（全部串行，每跑前 tasklist 确认零 Godot 进程）

| 命令（repo 目录下，控制台 exe 同一） | 结果 | 日志 |
|---|---|---|
| `--headless -s tests/qa_r293qa_render.gd`（**本 QA 探针**） | EXIT=0 · **30/30 通过** | `tools/r293qa_runs/qa_r293qa_render_headless.log` |
| `-s tests/qa_r293qa_render.gd`（**窗口态**——2a/2b/2e 实跑 MM 实例 transform/色读回 parity 分支） | EXIT=0 · **30/30 通过** | `tools/r293qa_runs/qa_r293qa_render_window.log` |
| `--headless -s tests/qa_r293_multimesh.gd`（开发套件复跑对账） | EXIT=0 · 36/36 通过 | `tools/r293qa_runs/qa_r293_multimesh_rerun.log` |
| `--headless -s tests/qa_r271_deeprepro.gd`（S1-S7 短路 verdict 台架） | EXIT=0 · 22/22 通过 | `tools/r293qa_runs/qa_r271_deeprepro_rerun.log` |
| `--headless -s tests/qa_r272_qa_indep.gd`（零树进出/敌池独立 host） | EXIT=1 · 41/43（q6.3/q6.7=**R290 在册存量红**，见 D2） | `tools/r293qa_runs/qa_r272_qa_indep_rerun.log`、`_rerun2.log`、`_diff_no_notify.log` |
| `--headless -s tests/qa_r269_bucketprobe.gd`（桶 µs/诊断行锚） | EXIT=1 · 34/35（b4=**套件正则 typo**，见 D1） | `tools/r293qa_runs/qa_r269_bucketprobe_rerun.log` |
| `--headless -s tests/qa_r291qa_probe.gd`（R291 深载门 QA 探针） | EXIT=0 · 70/70 通过 | `tools/r293qa_runs/qa_r291qa_probe_rerun.log` |
| `--headless -s tests/qa_r271_flushcut.gd`（host.place 直连面） | EXIT=0 · 24/24 通过（6 SKIP 桌面态跳过） | `tools/r293qa_runs/qa_r271_flushcut_rerun.log` |

差分实验记录（QA 诊断，非修复）：为定谳 q6.3/q6.7 归属，曾临时注释 `projectile_base.gd:1827` 的 `ProjBodyMM.notify_place(...)`（本刀唯一生产改动）复跑 `qa_r272_qa_indep` —— 结果**逐字相同 41/43**，证明两红与本刀无关；跑后已按备份恢复，`md5sum` 复核与原文件一致（`ab3939e95fae7e9b25ef3c2d9fd9de50`）。

## 缺陷清单

### D1【low · misc】qa_r269_bucketprobe b4 尾锚正则 typo：`回µd+` 应为 `回µs\d+`（测试文件缺陷，非本刀）

- 位置：`tests/qa_r269_bucketprobe_cases.gd:222`（该文件与 `autoload/debug_stats.gd` 最后一次改动均为 2026-10-24 01:39，即本批刀C「诊断 drawcalls 键」迁移；typo 具体引入轮次无版本史可考——R288/R289 迁移或刀C 迁移）
- 现象：b4「尾锚正则全匹配」确定性 FAIL（34/35）。真实诊断行含 `灭µs0 回µs0 ipµs0`（R286 九键），正则组写作 `( 回µd+)?`（µ 后缺 `s\d`）——后续可选组全部无法消费 `回µs0`，整锚失配。
- 定谳证据（QA 一次性 A/B 探针，真链 boot 后以 DiagStub 直调 `_diag_format_line` 取完整行对拍）：`REGEX_ORIG_MATCH=false` / `REGEX_FIXED_MATCH=true`（修正形全匹配）。
- 影响与归属：非生产行为、非本刀（弹幕合批未触 `debug_stats.gd`/诊断行/该套件）；但 b4 是诊断行尾锚的迁移协议哨兵，持续红会掩蔽后续键迁移的真失配。建议刀C（misc/诊断域）一行修正。历史绿基线：2026-10-15 R271 电池 35/35（`docs/qa/_r271_qa_batt/bucketprobe.log`，typo 引入前的正则形状）。

### D2【low · 空串=无人认领】qa_r272_qa_indep q6.3/q6.7：敌侧死亡释放镜像回册（R290 在册存量红，2026-10-18 起非绿，非本刀）

- 现象：q6.3「带闪死亡释放镜像不回册」（`mirror=<ImageTexture#…> mm_on=true`）与 q6.7「非 grunt 释放镜像不回册」确定性 FAIL（两次复跑逐字同形）。
- 非本刀证据（三重）：①差分实验——摘除本刀唯一生产改动后复跑结果逐字相同 41/43；②静态——本刀零触碰 `enemy.gd`/敌池/敌 host（enemy.gd mtime 2026-10-17，早于本批）；③在册——`docs/qa/2026-10-18-R290-保帧三刀-测试报告.md:82` 已记录「qa_r272_qa_indep 41/43 已复现｜镜面释放存量，与本改动无交集」，R291 报告（:86）列为在册存量红未复跑。
- 影响与归属：R272 敌侧 dead 门域（enemy.gd `_restore_flash_tex`/`_mm_on` 链），早于本批三个刀的授权面——无人认领，建议主会话按存量红流程另行立项；对本刀验收无影响（本刀弹侧注销链经 4a/4c/4d/4e/1e 五向独立验证零泄漏）。

## 观察（非缺陷）

- **O1 追赶扫一帧迟滞（设计披露确认）**：boost 重开时被追赶扫补注册的弹，其 MM 实例变换在下一帧才同步（层为 host 子节点，`_process` 晚于 host 同拍）——翻转边界单帧、视觉无感，与「追赶扫」语义一致；开发套件 6f 与本套 4c 均验证注册面正确。
- **O2 池内空闲弹 sprite 复原依赖拆收链**：boost 开态 release 的弹 `_sprite.visible` 保持 false（根已隐不可绘、且已注销无 MM 实例——无幽灵），跨 boost 关翻转由 `teardown_mirrors` 统一复原（4c 已证），复用时 `notify_place` 不合格分支亦有幂等复原（5c 已证真实换键链）。三重复原面闭环。
- **O3 门面静态单例假设**：`ProjectileBodyMM._host_ref` 为静态单值——生产弹池唯一 host 下无问题；多 GameLoop 并存（仅测试形态）时后注册覆盖前值，属测试环境边界（本套单 boot 未触），备案不立项。
- **O4 收益口径**：本报告覆盖结构/行为等价；逐 canvas-item 提交成本收益（dc/弹段/渲ms）需真机对读（实施披露已声明换轨口径），不在本验收面。

## 附：探针套件清单（tests/qa_r293qa_render_cases.gd，30 项）

点0 夹具 0a/0b；点1 1a-1e（四源对账+实例序+释放回基线）；点2 2a/2b/2e（双态 parity）+2c/2d（染色）；点3 3a/3b/3c；点4 4a-4f（含幽灵负向探针与 FORCED 强收）；点5 5a/5b/5c/5c2/5d；点6 6a/6b/6c（S1/S7 计数器归属）；⑧ 总项数假绿防线。收尾按 R270 盘档毒配方（快照还原+erase perf_boost/boost_res+`Meta._save`+`RunSave.clear`），静态注入口（boost_override/deep_override/trail_halffreq_override/BODY_MM/shortcircuit 双臂）全部复位；零 user:// 产物、零 Meta 残留写。

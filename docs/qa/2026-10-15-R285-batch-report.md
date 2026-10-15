# R285 批次终验汇总报告：弹侧物理相成本根治批（T1 网格命中 sweep 化 + T2 物面守门 + T3 死亡链冲刷批量化 + P0 二轮分键）

- 批次：R285（终验收口，2026-10-16）。设计：docs/design/2026-10-15-R285-projectile-perf-design.md（v3，含实施收口轮修订）。
- 证据源：QA 报告 docs/qa/2026-10-15-R285-qa-report.md（qa-r285 独立测试轮）；评审报告 docs/review/2026-10-15-R285-review.md（reviewer-r285，有条件放行）；实施摘要；台架输出 tools/r285_deeprepro_archive.log 及各轮 tools/r285_*.log。本文只写实际发生的事；每处数字标注其所属跑次。
- **批次判定：放行（评审「有条件放行」的唯一 major 条件 #1 出包号已修并复跑留痕，#2/#3/#4 按 v3 修订节处置在案）。**

## ① 结论：本批交付了什么，刀前后数字对照

**交付面**（工作树改动：projectile_base.gd +72 / enemy.gd +27 / game_loop.gd +152 / qa_r271_deeprepro_cases.gd +49 / 新套件 qa_r285_gridhit(+_cases) 922 行——评审报告 §首实测口径）：

1. **T1 弹命中 sweep 化**：boost 门内命中从「逐弹 tick 槽内即时查询+即时结算」改为「逐弹收集命中对、④ 尾按弹 tick 序×格行主序统一提交」（run_serial 序守卫防 FRACTAL 子代节点复用幻影对）。
2. **T2 物面守门**：零产品代码的断言刀（弹场景零物理件/Area2D 白名单/CONTACT_RADIAL 旗语义锁/boost 两态逐位），充当 vc83「弹×弹 overlap」假说的结构性证伪键。
3. **T3 死亡链冲刷批量化**：`_on_died` 拆分（dead 旗+marks 清零保持 inline；DeathPop/毒溅/元素释放/击杀广播四件搬 `_death_fanout`），boost 态入队、三冲刷点（④尾/⑤尾/帧末兜底）快照计数制统一执行。
4. **P0 二轮分键**：命/结/死/回/ip 五桶键（复用 R269 桶器，未改 debug_stats.gd——比设计更小，评审 §四认可）+ deeprepro G0/G1/G2/S8 四臂 + `-- archive=1` 拒写分支实跑闭合（R272 防覆写教训）。
5. **架构门（定死）**：`grid_hit_override/death_flush_override` 三态 + ④ 相头每帧恰一次求值的帧级缓存（〔v2·M2〕）——boost 关（桌面/headless/测试默认）走现状路径零执行，pkg4 116 项 RNG 零位移由此保住。

**台架刀前后数字对照**（深载台架：敌 90 驻场+弹 448 顶格+boost 促 1，600 物理帧/臂）：

| 口径 | 读数 | 来源 |
|---|---|---|
| 病根账（vc83，上游未复测） | 拟合 448 弹顶格=717ms/s=30Hz 档 33.3ms 步预算的 96%（弹系数 1.6ms/s/弹=敌×500） | FEEDBACK_TRACKER.md:2009-2011（设计 §1.1 转引） |
| 刀前基线（R271 postcut，上游） | BASE 883.6k 步µs/s；S6 全弹清空塌缩 77% | docs/qa/2026-10-14-R271-deeprepro-postcut.md（设计 §1.4 转引） |
| 本批 BASE（实施员归档跑 20/20，基线漂移 23% 容差内） | BASE 921.5k / BASE2 复测 926.3k / **G0 强关 943.2k** | tools/r285_deeprepro_archive.log verdict 表 |
| **刀后臂（同一跑）** | **G1 网格命中 936.0k（对 G0 差 0.8%）/ G2 死亡冲刷 930.6k（1.3%）/ S8 ip 短路 924.3k（±0）**；四臂 M4=过（敌≥85/弹≥420） | 同上 |
| 评审独立复跑（第二跑） | G0 929.3k / G1 926.4k / G2 914.6k / S8 928.0k——同样全不塌缩；**S6 对照 219.4k（塌缩 77%——复现 R271 铁证，台架有效性锚未失效）** | docs/review/2026-10-15-R285-review.md §一 |
| 红的一项（如实登记） | 实施员归档跑里 S6 只有 482.7k（步µs 口径塌缩 ~48%、延口径 33%），弱于 R271 postcut 的 77%——同跑其余臂正常、M4 过；评审第二跑 77% 补回了有效性锚 | 两跑日志对照 |

**诚实判读（两跑一致，写死不翻案）**：headless 台架 G1/G2/S8 全不塌缩 → 弹系数主体在更深层（节点树存在性簿记/渲轴/真机 GDScript 调用开销放大）。**本批交付的是机制+对拍+关态零位移，不冒充性能数字；T1/T3 步µs 收益定谳归 vc85 真机（P0 五键首读入账），不设 headless 不可证的 fps 承诺**——与设计 §1.4 前供（S4≈0%）自洽。G1 臂加/摘 N 升（2994→5568/s，归档跑）=击杀时点帧内后移致 spawner 补位动力学变化，观察项登记、M4 不翻红。

## ② 刀面账：落点与语义对拍结论

**T1（收集-冲刷两段式命中）**
- 落点：projectile_base.gd——`run_serial`（:19，spawn 递增 :227，_reset_state 不清单调）；尾部分流（:472 慢路径 `team==0 and GameLoop.grid_hit_frame → _collect_hit_pairs()` else `_check_collision()` 现状逐字；:585 快路径同款）；`_collect_hit_pairs`（:726-769——三守卫 team1/_flight_axe/enemy_grid null 与 _check_collision :775-782 同序同判定、同 query_r 式 :752-756、`_in_reach(_in_reach_swept)` 窄相本体复用 :763-767、候选不复制就地消费、RNG 契约声明全文头注 :733-742）。game_loop.gd——三态门+帧级缓存（:78-110、④ 相头 :912-926）、三平行对缓冲（:4070-4073，帧头清零分配）、`_flush_hit_pairs`（:4084-4109——快照 n0+序守卫三重 is_instance_valid∧_live∧serial :4101）。
- 语义对拍结论：**冲刷序 ≡ 关态结算序**（评审 §二.7 构造性复核+实测）；t1c2 五 seed（11/23/37/41/53）跨 override dmg/settles/kills **逐 seed 逐位相等**（如 seed=11 关[378/41/14]=开[378/41/14]）——实际强于设计 ±2% 统计带；t1c3/t1d 单弹单敌三态 A≡B≡C 全项逐位（关态真值/强关压 boost/网格真值开）；QA qJ 补 sim30 swept 口径两态逐位（高速弹弦判定，实施员 t1c3 只跑 60Hz）；t1e 掷斧零命中对+敌弹撞玩家时序两态逐位；穿透/反弹预算（QA qB：bounces_left==2 命中后不动）/E-03 去重（QA qA2：同敌三弹独立结算 settles==3）/附着面（QA qB：FIR gauge>0 两态逐位）全部实证。

**T2（物面守门，零产品代码）**
- 落点：全部并入 tests/qa_r285_gridhit_cases.gd（三套件并一件，设计 v3·② 修订留痕）——p1 弹场景零物理件运行期锁、p2 全树 Area2D ⊆ {敌 HitArea, 玩家本体}+mask=2+layer=3、p3 CONTACT_RADIAL 无产品写口源锁+A2K 重挂清退刀态（probe_r237 同款二次 boot）、p4 boost 两态集合逐位。
- 结论：弹×弹不检测在真机构建中结构性恒真（弹无物理体）；敌侧 HitArea×玩家对按敌数计、归敌系数不归弹系数（设计 §1.3/§9-7 口径）；**T2 性能预期=0 如实登记**（设计 §1.3）。

**T3（死亡链冲刷批量化）**
- 落点：enemy.gd——`_on_died` 拆分（:1284-1296：dead=true+`_reset_marks` 保持 inline；:1293 入队门读静态 bool `death_flush_frame`）；`_death_fanout`（:1299-1325 四件逐字搬移+同帧多杀连锁读数漂移声明④头注 :1303-1310）。game_loop.gd——三冲刷点：①④ 尾（:936-939，_flush_hit_pairs 之后）覆盖命中杀、②⑤ 尾（:962-964，elemental.tick+detect_reactions+分离之后）覆盖 DOT/反应杀、③帧末 pipeline.end_frame 同位兜底（:1129-1131）；`_flush_deaths` 快照计数制（:4117-4137：n0 快照+is_instance_valid∧dead∧in-pool 三重复验 :4126-4128+冲刷中再入队残段留尾当帧吸收 :4131-4137）。
- 语义对拍结论：t3a 批量化 FIFO/快照（冲刷点前 emit==0→冲刷后==3、死亡序=派发序、spawner 收窄在冲刷点、再入队残段当帧闭合 4 杀队空）；t3b inline 面不动（apply_damage 返回即 dead==true，穿透不浪费——死亡短路 projectile_base.gd:916-922 先于穿透）；t3c 关态 fan-out 即时逐位；t3d 200 帧兜底排空+中途 free 敌零崩溃；t3e 燎原声明带（关=点燃/开=被 :698-701 dead 过滤跳过、方向锁开≤关单向收窄）；QA qE 补燃烧 DOT 杀实证——死帧末 emit==1∧队空∧spawner 已收窄，**⑤ 尾冲刷点同帧闭合、DOT 死零跨帧滞留**，两态死帧序逐位；QA qC2/qD1 补池交互守卫面（先归池敌零 fan-out、free 弹残对零结算）。

## ③ 测试账

**终验电池逐行（编排终验口径，原样照录）**：

```
tests/qa_r285_gridhit.gd 51/51 exit=0
```

终验电池仅此一行。**如实说明：pkg4/verify_feedback/r269/stepacct/deeprepro 不在终验电池行内**——它们的最近实跑分属下列三轮，各自日志在案，本文按归属转述，不冒充终验重跑：

| 轮次 | 套件与结果（全部 exit 0） | 日志 |
|---|---|---|
| 实施轮（实施摘要自证） | pkg4 116/0、r214_bucket 26/0、r214_extra 19/0、boostmode 69/0、enemylazy 28/0、**verify_feedback 685/0 零迁移**、stepacct 18/0、flushcut 24/0（6 SKIP 既有口径）、gridhit 51/0 连跑两遍、deeprepro `-- archive=1` 20/20（拒写分支实跑留痕） | 实施摘要转述，归档跑日志 tools/r285_deeprepro_archive.log 我读过原文 |
| 评审轮（reviewer 实测） | pkg4 116/0、vf 685/0 零迁移、r269 69/0、gridhit 51/0、deeprepro 20/0（归档 md5 未动）、stepacct 18/0 | tools/r285_review_*.log（评审报告 §一） |
| QA 轮（qa-r285 亲手） | **qa_r285_qa_gridqa 32/32 连跑两遍**（独立探针：同帧多弹/反弹/元素附着/sim30 swept/时序边界/池交互/DOT 闭合/盘档卫生）、**pkg4 116/0、verify_feedback 685/0、gridhit 51/51 独立复跑** | tools/r285_qa_gridqa_run2/run3.log、r285_qa_pkg4.log、r285_qa_verify_feedback.log、r285_qa_gridhit_recheck.log |
| vc85 修正后（评审 #1 复跑要求） | pkg4 116/0、version_probe 1/1 | tools/r285_pkg4_vc85.log、r285_version_probe.log（**读证非 QA 亲跑**） |

**评审 verdict 与缺陷处置**（docs/review/2026-10-15-R285-review.md，判定有条件放行；处置经设计 v3 修订节+文件读证核对）：

| # | 严重度 | 问题 | 处置（读证） |
|---|---|---|---|
| 1 | **major** | 出包号撞号：预写 code=84/vc84 已被 R284 包 InfiniteFission_v0.1.82_vc84.apk 占用 | **已修**：export_presets.cfg version/code=85、project.godot config/version="v0.1.83_vc85"（两文件带「R285 评审 #1 修」注释）；pkg4 复跑 116/0 留痕（上表末行）；设计 v3·④ 留痕 |
| 2 | minor | p0c 未落 stepacct 五键格式断言 | 按「设计文档登记移交」选项处置：设计 v3·①（五键在账已由 gridhit p0 组+G 臂 effect check 双覆盖；stepacct 18/0 未迁移）；stepacct 文件 grep 五键=0 处与登记一致 |
| 3 | minor | 三套件并一件与设计 §8 不一致 | 设计 v3·② 修订注记（断言面 p1-p4/t1a-t1e/t3a-t3e/P0 无损，51/51 绿，不拆回） |
| 4 | low | death_flush_on 零调用/t1d 进程内 A≡B 非 git stash 法/t1b 300 帧 vs 600 | 设计 v3·③ 登记（覆盖实际达成且更强：pkg4 116 项即刀前冻结基线；death_flush_on 留作诊断口） |

**QA verdict 与缺陷处置**（docs/qa/2026-10-15-R285-qa-report.md，判定放行，无 blocking/major/minor）：

| 级别 | 项 | 处置 |
|---|---|---|
| low | O1 门翻转残队×R66 看门狗复合边界（death 残队遇用户翻关：fan-out 滞留→看门狗强归还→复开冲刷 in-pool 守卫跳过→该杀 emit 永失） | 登记。**当前产品不可达**（无 ⑤ 尾后杀源，残队仅测试直驱可构造）；加固建议（门翻关转帧排空残队/看门狗归还前补 fan-out）供主会话酌定 |
| low | O2 deaths_flushed 计数语义（快照段计数，守卫跳过也 +1，game_loop.gd:4130——G2 臂 effect check 极端下可假阳） | 登记：vc85 若以该键定谳死冲份额，先改「实际执行 fan-out 数」口径 |
| low | O3 夹具纪律（Enemy 夹具直 spawn+挂位须调 ip_birth_snap()，enemy.gd:843——仅 sim30 注入套件显形，qJ 踩坑实录） | 登记为后续 sim30 型套件夹具模板要求 |

盘档卫生终态：QA 实测套件全程 meta_save_test.cfg 字节逐位不变、收尾 settings 段逐位、套件外读证终态 perf_boost=0/fx_quality=2 无残留；评审六跑后 git status 无盘档类变更、deeprepro 归档 md5 未动。

## ④ RNG 契约变更声明（boost 开侧帧级偏移的可感度评估）

**声明制合规**（照 R226 拆帽/R268 P1 先例）：声明全文三处落盘——projectile_base.gd:733-742（_collect_hit_pairs 头注：允许①hp_pct/波首杀条件读先后序漂移②homing 同帧 AOE 重索敌时点漂移③死亡 fan-out 全局 rng 交错序漂移④同帧多杀击杀连锁读数漂移；承诺不变面=单体结算链数值/命中率统计期望/穿透反弹预算/E-03·R196 去重/六大生命周期派发序）、enemy.gd:1303-1310（燎原收窄单向声明）、设计 §3.1.5。**关态零位移双锚**：构造（两门唯一求值点 ④ 相头，热路径仅静态 bool 读，无 RNG 触点——评审 §三 grep+实读）+ 实证（pkg4 seed=42 116/0，QA 轮独立复跑同读数）。

**可感度评估**（采信评审 §六+QA 两态对拍实证）：
- **boost 关（桌面/headless/测试默认态）**：零观感零手感（pkg4/vf/r269 三门实跑+QA qA/qB/qJ/qE 关态臂逐位）。
- **boost 开（mobile 保帧 30Hz）**：命中结算与击杀 fan-out 全部**同帧内**后移，帧内上界 ≈1 槽（≤33.3ms）=30Hz 单帧抖动量级；跳字当帧起跳不变（派发仍在 ⑧ 前）、DeathPop/掉宝同帧出现；t1e 敌弹撞玩家时序两态逐位实证无 30Hz 相位错位——**无可感面**。
- **唯一可感平衡面=声明④**：ELE_IGNITE 层 2 质变构筑在 mobile 的燎原 DOT 收益**单向收窄**+连杀狂热/精英首杀/回声·共鸣叠层乘区读数漂移。t3e 断言把漂移做成可回归面（关=点燃/开=跳过+方向锁开≤关），按统计带验收（§4 ±2% 初始带）；实测对拍（t1c2 五 seed+QA qA/qB/qJ/qE 两态）伤害数值/命中率/死帧序**全部逐位零漂移**，好于带要求。
- 弹帽类应急阀确认未混入（设计 §7 明确不做；评审 diff 复核无拒发/挤弹面）。

## ⑤ 诚实边界与遗留

1. **headless 台架不能证 T1/T3 步µs 收益**：G1/G2 塌缩 ≈1% 量级（两跑一致），与设计 §1.4 自己的 S4≈0% 前供相符——弹系数主体在更深层（节点树簿记/渲轴/真机调用开销放大）。**收益定谳归 vc85 真机**（P0 五键首读入账、步µs 深载行回落、fps≥30）；若真机未达标，不得归咎 T1 落空（设计 §9-2 诚实账）。
2. **终验电池覆盖面**：编排终验仅重跑 gridhit 一行（51/51）。pkg4/vf/r269/stepacct/deeprepro 的绿色读数分属实施/评审/QA/vc85 修正后四轮实跑（各日志在案），非终验同批重放；其中池面（r214_bucket/r214_extra/enemylazy）与 flushcut 仅实施轮单轮实跑，评审与 QA 轮未复跑。
3. **台架单跑读数口径**：G 臂数值来自单跑（实施员归档跑+评审复跑各一次，未做同会话重复采样）；S6 有效性锚在归档跑中塌缩仅 ~48%（步µs 口径）、评审复跑 77%——跨跑漂移在 23% 基线容差口径内，深载数值一律按单跑读数看待，vc85 以 P0 键连续采样定谳。
4. **遗留（有归属，非本批未竟）**：①p0c stepacct 五键格式断言随下批补（设计 v3·①登记）；②tracker R285 节随 vc85 出包时点补（评审 #1 建议原文口径——现 FEEDBACK_TRACKER.md 尚无 R285 节，与「出包未发生」一致）；③vc85 出包与真机判读未发生（本批边界）；④QA O1 加固（门翻关转帧排空残队）与 O2 计数口径修正待主会话酌定是否随下批。
5. **批次红线终态**：pkg4 116/0（QA 独立复跑+vc85 修正后复跑双留痕）；verify_feedback 685/0 零迁移（QA 独立复跑）；R269 保帧关态逐位（r269 69/0+t2.p4）；模式关不写盘档（QA 字节级实测）；RNG 声明三处落盘（读证）。**零违反。**

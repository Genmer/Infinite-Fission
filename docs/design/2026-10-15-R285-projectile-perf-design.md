# R285 设计文档：弹侧物理相成本根治批——T1 网格命中 sweep 化 + T2 物面守门 + T3 死亡链冲刷批量化

- 批次：R285（设计轮，2026-10-15）。
- 修订：**v2（分析师修轮，2026-10-15）**——分析师对照代码判「不放行」，3 必改经本设计轮 Read 亲证后逐条落实（修订点以「〔v2〕」标注）：**M1** T3 增补「同帧多杀击杀连锁读数漂移」声明——燎原 `_on_enemy_killed_spread_burn` 的 dead 过滤目标集较关态收窄（elemental_system.gd:698-701〔实证〕），T3 下 B（同帧稍后才死）被跳过=燎原 DOT 系统性漂移，入 §0.2 迁移点④/§3.1.5 声明④/§5-t3e/§6；**M2** 门读改帧级缓存——`grid_hit_on()` 每弹读会在关态热路径付 448×60Hz≈2.7 万次/s 的 `Meta.settings` 字典查（perf_governor.gd:60 → scripts/meta/meta_manager.gd:344-348〔实证〕），与 §0.3「不进热循环内层」自相矛盾——改 ④ 相头一次求值入静态 bool 缓存，弹侧零字典查（§3.0/§3.1.6）；**M3** T3 冲刷排空语义定死=快照计数+兜底点吸收，`emit_enemy_killed` 全订阅者清单代核（12 文件 18 连接点，无即时杀路径；§3.3），t3a/t3e 断言依赖此选型。
- 修订：**v3（实施收口轮，2026-10-16，评审报告 docs/review/2026-10-15-R285-review.md #2/#3/#4 留痕）**——①**p0c 移交下批**（§5-P0c 二选一之「设计文档登记」选项）：五键在账功能面已由 qa_r285_gridhit p0 组（命/结/死/回/ip >0+短路归零，51 项内）与 deeprepro G1/G2 臂 effect check 双覆盖，stepacct 18/0 实跑绿未迁移；stepacct 键格式断言（键存在/行序冻结）随下批补。②**三套件并一件**（§5/§8 与实施事实的差异修订）：gridhit/physface/deathflush 三独立套件按任务书固定命名合并为 `tests/qa_r285_gridhit.gd(+_cases)` 一套（T2 物面守门与 T3 死亡冲刷断言全数并入；断言面 p1-p4/t1a-t1e/t3a-t3e/P0 无损，51/51 绿）——不拆回。③**覆盖口径差异登记**（评审 #4）：t1d 关态逐位实现为进程内 A≡B 对拍（关态真值 vs 强关压 boost 同夹具全项逐位——pkg4 116 项即刀前冻结基线，覆盖强于设计的 git stash 双跑法）；t1b 驱动 300 帧（设计写 600——逐帧无滞留断言下同语义）；`death_flush_on()` 独立读口保留不删（④ 头实际用共享求值 match 派生，本口=诊断/QA 直读面，全库零调用如实登记）。④**出包号修正**（评审 #1，major）：本批 versionCode 84/vc84 已被 R284 包占用（InfiniteFission_v0.1.82_vc84.apk），按 R194 契约改 85/v0.1.83_vc85——export_presets.cfg version/code=85、project.godot config/version="v0.1.83_vc85"。
- 上游输入：①vc83 真机判读（FEEDBACK_TRACKER.md:2009-2011，R284-B/C 节）：分离行（敌 1-9 只、弹 448 顶格）步µs 仍 560-745k/s；两点线性拟合「步µs ≈ 3.2µs/s/敌 + 1.6ms/s/弹（弹系数=敌×500）」，448 弹顶格=717ms/s=30Hz 降载档 33.3ms 步预算的 96%；②R284-C 候选刀清单（同上 :2011）：弹命中改敌网格查询／弹碰撞层精简／弹死亡链冲刷批量化／玩家弹帽（**已被用户否决**）；③用户拍板：「详细修复，不是临时」——拒绝玩家弹帽类应急阀，T1/T2/T3 立刀；④R271 已交付面（勿重做）：弹池惰性归位（object_pool lazy_bucket_release + tex_bucket_host unplace_lazy）、R272 敌/xp 池同款+满载 dead 门——敌侧桶链已归零；⑤R271 deeprepro 台架 postcut 数据（docs/qa/2026-10-14-R271-deeprepro-postcut.md，S 臂矩阵）。
- 路径口径：本文路径均相对 `repo/`；测试命令 `E:/Code/Agent/Infinite-Fission/tools/Godot_v4.3-stable_win64_console.exe --headless --path E:/Code/Agent/Infinite-Fission/repo -s tests/<套件>.gd`；判读「验收汇总：PASS n / FAIL m」行 + exit code。
- 实证标记：标〔实证〕者为本设计轮（2026-10-15 会话）Read/grep 亲证（含行号）；标〔上游〕者为任务书/tracker/postcut 材料引用，本会话未复测。拿不准处集中在 §9。

## 0. 硬红线（全批通用，违反任一即回退该刀）

1. **pkg4 seed=42 rng 流零位移（116/0）**：桌面/headless/测试默认 boost 关 → 全部新代码走现状路径零执行（§3.0 门伪代码保证「关态零调用」而非「关态同结果」）。实施后 pkg4 必复跑。
2. **verify_feedback 685 断言除声明迁移点外零改动，实跑为准不信 grep**（R269 §0.2 教训承接）。本批**预声明迁移点**（全部 boost 开侧限定，关态逐位）：①同帧多杀时「波首杀位/玩家血量百分比」条件读取时点随 T3 死亡冲刷后移（ctx.is_first_hit_of_wave / ctx.player_hp_pct 消费序）；②homing 同帧 AOE 击杀下的重索敌时点随 T1 收集段前移（§3.1.5）；③若 verify_feedback 存在锚定「击杀 fan-out 即时序」（xp 掉落序/死亡弹爆先于后续命中）的用例，boost 开侧随包裁定迁移；〔v2·M1〕④**同帧多杀击杀连锁读数漂移**：T3 下 dead 旗全部在对提交段置位、先于任何 fan-out 执行 → 燎原 `_on_enemy_killed_spread_burn` 的 dead 过滤目标集较关态**收窄**（elemental_system.gd:698-701〔实证〕——关态 A 死时同帧稍后才死的 B 仍活、可被满槽点燃，T3 下 B 已 dead 被跳过=燎原 DOT 伤害系统性漂移）；同族：连杀狂热/精英首杀/回声·共鸣叠层（relic_handler.gd:447-461、player.gd:1716-1741〔实证〕）在后续命中乘区的读数漂移。除此之外零改动。
3. **模式关/桌面默认路径逐位不变**：T1/T3 全部形如「boost 开 → 新路径；boost 关 → 原调用逐字原位」。〔v2·M2〕关态可执行新增面=④ 相头一次 `PerfGovernor.boost_mode()` 求值（perf_governor.gd:53-62〔实证〕，每帧恰一次，含 Meta.settings 字典查）+ 两个静态 bool 的写/读——**弹/敌热路径零字典查零门调用**（§3.0/§3.1.6），不进任何热循环内层。
4. **RNG 契约变更声明制**（照 R226 拆帽/R268 P1 先例）：boost 开侧命中时点允许帧级偏移；伤害数值分布与命中率统计不变（§3.1.5 声明全文，须落入代码注释与本文档 §6）。
5. **模式关不写任何盘档**：新套件 cleanup=Meta._settings 快照整字典还原 + Meta._save() 落盘（R272 两度盘档毒事故教训；headless 存档走 meta_save_test.cfg）；台架落盘参化 `-- archive=1`（已存在归档即拒写继续跑，防覆写证据链）。
6. **R220 拆解契约 §2.1 冻结面零触碰**：PerfGovernor 既有静态口零改动（只读 boost_mode()）；结算帽/派发帽/池阀/物理频率不动（R269 §0.8 承接）。
7. **SpaceGrid 与 R239 原生桥零触碰**：T1 复用既有 query_circle_snap（含原生 query_circle_snap_nodes 路径），不新增 SpaceGrid 方法、不改桶序/快照语义（§3.1.1 论证）。
8. **新套件双文件结构**（入口 `extends SceneTree` + 用例体运行时 `load`，零工程类名直引——tests -s 入口编译期先于 autoload 注册）；每套件独立进程；新代码零全局 rng；注释中文行内 `#` 带「R285：」锚。
9. **物步µs/渲ms/延µs 既有键口径零破坏**（R271 §0.9 承接）：P0 新键独立累计（debug_stats.gd 既有秒窗器同款），仅 stage_probe_enabled 门内计时。
10. **跑测试前确认无残留 Godot 进程（勿双开）**；日志落 `E:/Code/Agent/Infinite-Fission/tools/`，文件名 `r285_` 前缀防互踩。

## 1. 病根账与前提供核（本设计轮最重要的一节——两处原文措辞与代码事实冲突，已核实并重定义刀面）

### 1.1 vc83 病根账〔上游，未复测〕

- 深载 fps 19-37 主源=弹满场的物理相成本；448 弹顶格=717ms/s=30Hz 档步预算 96%。
- R284-C 自记「弹 53µs/只/步构成**待二轮分键**（弹段仅 4ms，大头在『余』段=引擎物理步 Area2D overlap+死亡链冲刷执行——R237 桌面排除过 broadphase，真机未证）」——即：**弹侧成本构成在 vc83 时点并未定谳**，T1/T2/T3 是按假说拍板的刀面。

### 1.2 前提供核一：弹命中**不存在** Area2D overlap 路径（T1 原文措辞证伪）

| # | 事实 | 证据 |
|---|---|---|
| a | 弹基类自 M-09/Q-15 起为纯 Node2D，明确「弹-敌碰撞走 SpaceGrid 自管查询——不用 Area2D 回调」 | scripts/combat/projectile/projectile_base.gd:3、:11-12〔实证〕 |
| b | 慢路径命中=逐弹 tick 尾主动查网格：`_check_collision` → `enemy_grid.query_circle_snap` 粗判 + `_in_reach` 窄相 + `_submit_hit` | projectile_base.gd:710-756、:758-771〔实证〕 |
| c | 玩家弹快路径同款：`_tick_fast_player` 尾 `query_circle_snap` 预检非空回落 `_check_collision(true)`（R235 4b） | projectile_base.gd:571-579〔实证〕 |
| d | 弹场景=裸 Node2D+脚本，无任何 CollisionObject2D/CollisionShape2D | scenes/combat/projectiles/ballistic_projectile.tscn、homing_projectile.tscn〔实证，cat 全文 5 行〕 |
| e | 全工程唯一 Area2D 对=敌 HitArea(mask=2)×玩家本体(layer=3)——接触伤害通道，非弹通道。**且 R271 V-A（CONTACT_RADIAL boost 翻旗清退）设计后未实施**：产品侧对该旗零写口（grep 全工程仅 tests/ 写），postcut 判单明记「V-A=未触发（登记）」（S2 臂塌缩 33%<60% 门，postcut :38）——现网桌面与 boost 态都保留 90 监控 HitArea×玩家对 | enemy.gd:230、:676-695；player.gd:369-379；docs/qa/2026-10-14-R271-deeprepro-postcut.md:38〔实证：grep CONTACT_RADIAL 全库仅 enemy.gd 声明+tests 写点〕 |

**结论**：「弹命中从 Area2D overlap 事件驱动改为敌网格查询轮询」按字面实施=**no-op**（现状已是网格轮询）。本设计将 T1 重定义为该意图下唯一有实质内容的形态：**帧级 sweep 化**（逐弹即时查询+即时结算 → 逐弹收集命中对、④ 尾按确定性序统一提交），详见 §3.1。此重定义已保留拍板三要素：boost 门架构、网格命中新路径、RNG 声明制。**需主会话确认知悉此措辞修正**（§9-Q1）。

### 1.3 前提供核二：弹×弹检测**不存在**（T2 原文措辞证伪→转为守门刀）

- 弹无物理体（§1.2-d），「弹×弹不检测」在真机构建中本就恒真；碰撞层/掩码全集=敌 HitArea mask=2 + 玩家 layer=3（R235 搭车①已收敛，enemy.gd:679 注记〔实证〕）。
- T2 重定义为**物面守门刀**（§3.2）：断言锁现状（弹场景零物理件/掩码对唯一/V-A 旗语义与「产品无写口」事实锁），零产品代码改动、零性能预期——同时作为 vc83「引擎物理步 Area2D overlap」假说中**弹侧分量的结构性证伪键**（弹侧无物可 overlap；敌侧 HitArea×玩家对仍在场且按敌数计，归敌系数不归弹系数，见 §9-7）。

### 1.4 已在案的 headless 证据（deeprepro postcut，docs/qa/2026-10-14-R271-deeprepro-postcut.md:20-31〔上游，本会话未复跑〕）

| 臂 | 步µs/s | 塌缩 | 判读 |
|---|---|---|---|
| BASE（448+ 活弹） | 883.6k | — | 基线 |
| S4 弹 tick 短路（tick 早退，弹仍活仍可见） | 859.4k | **≈0%** | ④ 查询/结算/运动段**不是** headless 步成本主体 |
| S6 全弹清空（release 全部活弹） | 198.9k | **77%** | 弹的**存在性与下游级联**（命中链/死亡链/跳字/xp/树周转/ip 遍历）才是大头 |

**推论（本设计轮分析，非定谳）**：S4 与 S6 的差值 (~660k/s) 指向「弹存在×每步引擎/我方遍历+命中-死亡级联」，而非查询本体。候选构成：①`_ip_restore_pass`/`_ip_snapshot_pass` 帧首帧末双遍历（game_loop.gd:799/:1076〔实证〕，448 弹×2 遍历×30-60Hz 与 1.6ms/s/弹量级吻合——假说，P0 定谳）；②命中链（_submit_hit 词条/管线/结算）与死亡 fan-out（enemy.gd:1284-1298〔实证〕）；③弹节点树存在性的引擎侧每步簿记。**因此本批增加 P0 二轮分键先行件（§3.4）**，并把 T1 的收益预期显式押在「真机 GDScript 调用开销放大 + 为 T3 批量结算铺路 + 命中时序统一」上，**不设 headless 不可证的硬 fps 承诺**（§4 预算表按「可指名」口径列账）。

## 2. 核心循环（本批的「为什么有趣」）

- **玩家体验循环**：vc83 深载 448 弹顶格行步预算 96% 被弹侧吃满 → 本批把弹侧命中/死亡两条热链改为 boost 门内批量形态 → 真机深载步µs 从 560-808k/s 显著回落（P0 键可指名每一段的去向）→ 30Hz 保帧档 fps 回稳 ≥30，玩家弹满场的割草爽感**不减配**（拒绝弹帽=火力上限不动）。
- **诊断-取刀循环**：R271/R272 两轮证明「先分键后砍刀」纪律有效（vc83 敌桶刀方向正确但被弹成本掩盖）。本批把「弹侧 53µs/只/步待二轮分键」的遗留账在**同一批内**闭合：P0 分键先行合入 → 台架 G/S 臂定谳各段份额 → T1/T3 刀口与 P0 读数互为印证 → vc85 真机判读时每毫秒可指名。不再交付「砍了但不知为何」的刀。

## 3. 机制细节

### 3.0 boost 门总架构图

```
            PerfGovernor.boost_mode()（perf_governor.gd:53-62）——④ 相头每帧一次求值→帧级静态缓存〔v2·M2〕
                                    │
        ┌──────── false（桌面/headless/测试默认）────────────┼──────── true（mobile 保帧/真机深载）────────┐
        ▼                                                    ▼
  ④ 现状路径（逐字逐位，零新增调用）                          ④ boost 网格命中路径（R285 新增）
  ├ enemy_grid.rebuild(spawner.active)                       ├ enemy_grid.rebuild(...)（共用，语义不动）
  ├ enemy_bullet_grid.rebuild(...)                           ├ enemy_bullet_grid.rebuild(...)（共用）
  ├ _tick_one_pool 三缓冲分区（game_loop.gd:4004）            ├ _tick_one_pool 三缓冲分区（共用）
  │   慢路径 tick() → 尾部 _check_collision()                │   慢/快路径尾部命中步替换为 _collect_hit_pairs()
  │   pfast _tick_fast_player → 预检+回落 _check_collision   │   （运动/寿命/出界/词条 ON_TICK/回旋 ICD 全不动，
  │   efast _tick_fast → 撞玩家直判（team1 不改）             │    仅「敌网格命中」一步改收集；team1 敌弹不改）
  │   命中→_submit_hit 即时结算（弹槽内）                     ├ _flush_hit_pairs()：④ 尾按「弹 tick 序×格行主序×
  │   击杀→apply_damage→_on_died fan-out 即时执行            │   桶内插入序」统一提交 _submit_hit（T1）
  │                                                          ├ _flush_hit_deaths()：死亡 fan-out 队列统一冲刷
  │                                                          │   （T3；⑤ 尾二次冲刷点覆盖 DOT 死）
  ▼                                                          ▼
  RNG 契约：pkg4 116/0 零位移（关侧零执行保住）               RNG 契约变更声明：命中时点帧级偏移允许；
                                                            伤害数值分布与命中率统计不变（§3.1.5/§6）
```

门伪代码（game_loop.gd ④ 相，唯一决策点；〔v2·M2〕帧级缓存制）：

```gdscript
# game_loop.gd（R285）：boost 门静态注入口（R223 pool_valve_override / R235 PLAYER_BULLET_FAST_PATH 先例）
static var grid_hit_override: int = -1      # -1=真值（跟 boost_mode）/ 0=强关（A/B 对拍臂）/ 1=强开（QA 直驱路径）
static var death_flush_override: int = -1   # 同款三态（T1/T3 可独立裁定）
# 〔v2·M2〕帧级缓存：④ 相头求值一次，弹/敌热路径只读静态 bool（照 GameLoop.sim30_effective()
# 静态读先例，projectile_base.gd:730 同款消费形态）。成本依据：boost_mode() 每读走
# Meta.settings 字典查（perf_governor.gd:60 → scripts/meta/meta_manager.gd:344-348
# Dictionary.has+get）——逐弹读=关态 448×60Hz≈2.7 万次/s 热路径纯税，帧级缓存后
# 关态唯一新增=④ 头 1 次/帧求值 + 1 次静态 bool 写（零行为面，§0.3 口径如实披露）。
static var grid_hit_frame: bool = false     # 当帧网格命中路径开关（④ 相头写，帧内只读）
static var death_flush_frame: bool = false  # 当帧死亡冲刷开关（同上）

static func grid_hit_on() -> bool:          # 仅 ④ 相头调用（每帧恰一次，非热路径）
    if grid_hit_override == 0: return false
    if grid_hit_override == 1: return true
    return PerfGovernor.boost_mode()
# death_flush_on() 同构。boost 关：两帧级缓存恒 false → ④ 相执行序与现网逐字相同。
# ④ 相头（_physics_process ④ 段入口，网格 rebuild 前）：
#     grid_hit_frame = grid_hit_on(); death_flush_frame = death_flush_on()
# 帧内设置翻转语义：boost 写口翻转最早已下一帧生效（帧级缓存明示口径——设置变更
# 本就跨帧事件，无帧内翻转场景；QA 注入口翻转后须过帧界再断言）。
```

### 3.1 T1 详案：弹命中 sweep 化（收集-冲刷两段式）

#### 3.1.1 enemy_grid 查询接口（复用声明，零新增）

- **查询口**：`SpaceGrid.query_circle_snap(pos, radius)`（space_grid.gd:163-190〔实证〕）——覆盖格 + 快照位置距离平方粗判，reach=radius+max_entity_radius(64) 保守超集；返回内部复用缓冲（R5 别名纪律：不得跨查询持有）。R239 原生开时走 C++ 等价实现（候选序=格行主序×桶内插入序，与 GDScript 双循环逐位一致）。
- **窄相口**：`ProjectileBase._in_reach / _in_reach_swept`（projectile_base.gd:758-791〔实证〕）——`global_position.distance_squared_to(target.global_position) ≤ (er + enemy.hitbox_r)²`（30Hz 态为步前位→步末位线段距），enemy.hitbox_r live 读。
- **不改 SpaceGrid 的理由**：sweep 的收益在「结算时点统一 + 缓冲复制消除 + 为 T3 铺路」，不在查询算法本身（查询已是 O(覆盖格) 快照读）；新增批量接口会同时动 GDScript 桶序与 R239 原生镜像桥两套等价面，风险/收益不成立。原生桥 NATIVE_QUERIES 开关面零触碰。
- **收集段调用口径与现状逐字相同**：`er=effective_radius()`；`query_r = er + (30Hz 时 |global_position−_swept_prev|×0.5)`（projectile_base.gd:729-742 同式）；差异仅两处——①查询结果**不复制**进 `_candidates`（R235 4b 的 append_array 复制消除：收集段在候选缓冲上就地窄相，窄相通过的（弹,敌）才落对缓冲）；②**不即时 `_submit_hit`**。

#### 3.1.2 时序对齐（一帧内两段，无跨帧延迟）

- 现状：弹 i 在其 tick 槽内「运动→查询→窄相→结算」一次完成；击杀 fan-out 也在该槽内执行。
- R285 boost 态：**收集段**=弹 i 的 tick 槽内「运动→…→查询→窄相→落对缓冲」（每弹每帧至多一轮，与现状同槽）；**冲刷段**=④ 尾（`_tick_projectiles` 返回后、⑤ 敌 tick 前）`_flush_hit_pairs()` 一次性提交全部命中对。收集与结算同帧完成，命中时点相对现状后移 ≤（帧内剩余弹槽数），**无跨帧偏移、无 30Hz 相位错位**（swept 判定沿用 `_swept_prev`，30Hz 谓词 `GameLoop.sim30_effective()` 不动）。
- 为何可后移而不失真（等价性三锚，全部既有实证）：①④ 头 rebuild 与弹 pass 之间敌不 tick，活敌 live 位≡快照位（space_grid.gd:10-11 R231 等价锚〔实证〕）；②击退为速度型，⑤ tick 才位移（space_grid.gd:12〔实证〕）→ ④ 内敌位置全程冻结；③死亡敌 dead 旗在 `apply_damage` 内**即时置位**（enemy.gd:1029-1038〔实证〕），`_submit_hit` 死亡短路（projectile_base.gd:856-859）在冲刷段同序生效。

#### 3.1.3 命中判定的 hitbox_r 距离判等价性（构造性成立）

- 收集段窄相**逐字复用** `_in_reach/_in_reach_swept` 本体（同一函数、同参、同 live 读），不重写距离式 → 判等价性=构造性成立，无需数值论证。
- 粗判超集语义不变：query_circle_snap 的 64px 保守半径保证「凡窄相可达者必在候选集内」；收集段候选集与现状 `_candidates` 同源同口径。
- 唯一实现纪律：候选缓冲在窄相循环内消费完即弃（不落对、不持跨查询）——R5 别名纪律（提交链内 AOE/重索敌查询会复用同一内部缓冲）。

#### 3.1.4 同帧多弹命中序（定义，与关态逐位同序）

- **冲刷序 = 弹 tick 序 × 组序**：对缓冲按收集自然序排列（收集发生在各弹 tick 槽内），而 `_tick_one_pool` 组序=慢组（倒序）→ 敌弹快组 → 玩家弹快组（game_loop.gd:4045-4072〔实证〕）——与关态结算序完全一致。
- **组内候选序 = 格行主序 × 桶内插入序**（query_circle_snap 双循环序，原生路径同序承诺见 space_grid.gd:169-173）——与关态一致。
- **同弹多敌（穿透）**：冲刷按对序逐提交；pierce 预算耗尽 `_recycle(PIERCE_DEPLETED)` 后，该弹剩余对按「序守卫」跳过（等价关态 `_check_collision` 的 `if not _live: break`，projectile_base.gd:744-746）。
- **同敌多弹**：各自独立结算（现状语义——每弹自己的 hits_this_frame/生命周期去重表，E-03/R196 FIX-2 契约不动），先后序=冲刷序。
- **序守卫（新增，防节点复用幻影对）**：命中对落缓冲时记录 `(proj, target, proj.run_serial)`；`run_serial: int` 为弹上新字段，`spawn()` 递增。冲刷时 `pair.serial != proj.run_serial or not proj._live` → 跳过该弹剩余对。场景：穿透弹在冲刷中段耗尽预算回收 → FRACTAL 子代 `request_split`→`pool.acquire` 可能复用同一节点实例（projectile_base.gd:1230-1238）→ 无 serial 守卫则该弹剩余幻影对会以「子代身份」误结算。关态无此问题（回收即 break，无缓冲存活）。
- 冲刷段以冲刷开始时的对数快照为准（段内理论上不会再落对——击杀爆 AOE 走 settle_aoe 直结算不入对；防御口）。

#### 3.1.5 RNG 流序声明（正式文本，随代码注释落盘）

> **R285 RNG 契约变更声明（boost 开侧限定；照 R226 拆帽/R268 P1 先例）**
> boost 开启时，玩家弹-敌命中结算时点从「各弹 tick 槽内即时」改为「④ 尾统一冲刷」，死亡 fan-out 时点从「击杀即时」改为「冲刷点」（T3）。由此允许：①同帧内 `ctx.player_hp_pct`（ poison 溅射等死亡反伤先于后续命中）/`ctx.is_first_hit_of_wave`（波首杀位标记）条件读取的先后序漂移；②homing 弹在「同帧 AOE 击杀原目标」场景下的重索敌时点漂移（收集段先于冲刷段）；③死亡 fan-out 内全局 rng 消费（`_death_element_discharge` 的 randf_range，enemy.gd:1359）相对管线结算法（DamagePipeline 独立流，damage_pipeline.gd:811-821/:1041-1043）的交错序漂移；〔v2·M1〕④**同帧多杀击杀连锁读数漂移**——dead 旗全部在对提交段置位、先于任何 fan-out：燎原 `_on_enemy_killed_spread_burn` 的 dead 过滤目标集较关态收窄（elemental_system.gd:698-701——关态下 A 死时同帧稍后才死的 B 仍活可被满槽点燃，T3 下 B 被跳过，燎原 DOT 伤害分布系统性收窄漂移）；同族：连杀狂热/精英首杀/回声·共鸣叠层（relic_handler.gd:447-461、player.gd:1716-1741）在后续命中乘区的读数漂移。**承诺不变面（限定口径）**：单体结算链数值（乘区/暴击概率/抗性九步管线零改动）、命中率统计期望（命中判定距离式零改动）、穿透/反弹预算语义、E-03/R196 去重契约、六大生命周期事件派发序（挂载序）——**④ 项击杀连锁读数漂移明示不在承诺内**，按统计带验收（§5-t3e）。boost 关侧零执行、pkg4 零位移。QA 对拍口径=多 seed 统计带（§5-t1c3/t3e），非逐位。

#### 3.1.6 落点文件与伪代码

- `scripts/combat/projectile/projectile_base.gd`：①`run_serial` 字段+spawn 递增+`_reset_state` 不清（单调）；②tick() 尾与 `_tick_fast_player` 尾的命中步分流：

```gdscript
# tick() 尾（原 _check_collision() 调用位）：
if team == 0 and GameLoop.grid_hit_frame:   # 〔v2·M2〕静态 bool 帧级缓存——非 boost_mode()
    _collect_hit_pairs()      # R285：查询+窄相同口径，窄相通过者落 game_loop 帧对缓冲
else:
    _check_collision()        # 现状逐字（含 team1 分流/_flight_axe 守卫/网格 null 守卫）
# _collect_hit_pairs 内部：team1/_flight_axe/enemy_grid==null 三守卫先置（与 _check_collision
# :713-719 逐字同序），随后 query_circle_snap 同口径查询→遍历候选→_in_reach(_swept)→
# 通过者 game_loop.append_hit_pair(self, target)。不复制候选缓冲、不提交结算。
# 关态热路径成本面（〔v2·M2〕§0.3 口径）：新增可执行物=一次静态 bool 读 + 一次布尔分支
# ——零字典查、零函数调用链（boost_mode() 的 Meta.settings 字典查只发生在 ④ 头每帧
# 一次的求值点，见 §3.0）；enemy.gd _on_died 入队判定同读 death_flush_frame 静态 bool。
```

- `scripts/loop/game_loop.gd`：①两静态门+`append_hit_pair()`（三平行成员缓冲 `_hp_proj: Array[ProjectileBase]`/`_hp_target: Array[Node2D]`/`_hp_serial: PackedInt32Array`，帧头 clear 复用零分配——R188 档0 纪律）；②④ 相 boost 分支尾 `_flush_hit_pairs()`：按序遍历→序守卫→`proj._submit_hit(target)`（**提交链零改动**：帧聚合/生命周期去重/反弹盾/回旋 ICD/词条/管线/暴击/附着/穿透/回收全在原函数内）；③关态两缓冲 clear 后零遍历。

### 3.2 T2 短案：物面守门刀（断言刀，零产品代码）

- **机制**：把「弹×弹不检测/弹无物理体」的现状固化为可回归断言，同时充当 vc83「引擎物理步 Area2D overlap」假说中弹侧分量的结构性证伪键（敌侧对仍在场——§9-7，归敌系数面）。
- **断言面（新套件 `tests/qa_r285_physface.gd(+_cases)`）**：
  - p1：实例化 ballistic/homing 两场景 → 深扫子树，`CollisionObject2D`/`CollisionShape2D` 计数==0（场景文件 5 行裸 Node2D 的运行期锁）。
  - p2：满配 boot → 全树 `Area2D` 集合 ⊆ {敌 HitArea, 玩家本体}；敌 HitArea `collision_mask==2`；玩家 `collision_layer==3`（R235 搭车① 现状锁，enemy.gd:679-683/player.gd:369-378 口径）。
  - p3：旗语义锁（R237 预置清退刀仍可用）：boot 前置 `Enemy.CONTACT_RADIAL=true`（probe_r237 A2K 手法，tests/probe_r237_physattr_cases.gd:125-150 同款）→ 新构敌 `_hit_area==null` + 玩家 `monitoring==false ∧ monitorable==false ∧ layer==0`；**并断言产品现状=旗恒 false 无产品写口**（V-A 未实施的事实锁——若未来实施 V-A，本断言按其随包裁定迁移）。
  - p4：boost 关态逐位（p2 集合与 mask/layer 与 boost 关基线逐位；独立进程直跑）。
- **落点**：仅 tests/。**性能预期=0，如实登记**（§1.3）。

### 3.3 T3 短案：死亡链冲刷批量化（boost 门内）

- **机制**：命中造成的敌亡 fan-out（`_on_died` 内 DeathPop/毒溅/元素释放/`emit_enemy_killed`→spawner 收尸+xp，enemy.gd:1284-1298〔实证〕）不再在结算槽内即时执行：dead 旗与 marks 清零**保持 inline**（死亡短路/E-06 一次性语义不动），四件 fan-out 移入帧队列，冲刷点统一执行。
- **门与拆分**：`_on_died` 拆为 `_on_died_mark()`（inline：dead=true+`_reset_marks`）与 `_death_fanout()`（可延迟段，函数体=现 :1289-1298 逐字搬移）；入队判定 `if GameLoop.death_flush_frame: GameLoop.enqueue_death(self) else: _death_fanout()`（〔v2·M2〕静态 bool 帧级缓存，与弹侧同款）——关态调用序与现网逐字相同。
- **冲刷点**：①④ 尾 `_flush_hit_pairs()` 之后（覆盖弹命中杀）；②⑤ 尾（elemental.tick+detect_reactions+分离之后、⑥ 前）二次冲刷（覆盖 DOT/反应杀——DOT 是否经 take_result→apply_damage 到 `_on_died`，实现期核对，两种结果都已覆盖：经 take_result 则入队随②冲刷，直调 apply_damage 则本刀不涉）；③帧末兜底冲刷（pipeline.end_frame 同位，防 ⑥⑦ 段意外入队跨帧滞留——同帧内执行，无跨帧语义）。
- **〔v2·M3〕冲刷排空语义（定死）：快照计数冲刷 + 兜底点吸收**。冲刷循环只处理「冲刷开始时已在队」的快照段（记 `n0` 后 `for i in range(n0)`），冲刷期间新入队（防御面）不顺延执行、留给下一冲刷点（⑤尾）或帧末兜底点吸收——同帧闭合由兜底点保证，循环有界、t3a 读数确定。选型理由：`while` 排空在「冲刷内再入队」场景下界不定（连锁 fan-out 理论可长链），且 t3a 的「冲刷后==3」断言需稳定终点；快照制下新入队最迟帧末兜底处理，仍在同帧内（无跨帧语义）。
- **〔v2·M3〕`emit_enemy_killed` 全订阅者清单（本设计轮代核，grep `enemy_killed.connect` 全库=12 文件 18 连接点；结论：今日无「冲刷内再入队」路径，快照制为防御性语义而非必需）**：
  - 结算面（与声明④相关，只读/点燃/叠层，无即时杀）：elemental_system.gd:171→`_on_enemy_killed_spread_burn`（:683-714——燎原，`apply_attach` 满槽点燃=延后 DOT，:698-701 dead 过滤）；relic_handler.gd:326→`_on_enemy_killed`（:447-461——REL_HARVEST 回血/精英首杀保底/连杀狂热叠层，零杀）；player.gd:45/431/432/433/1233/1549→击杀账本、回声叠响、共鸣×2、时停、过载（:1716-1741 为叠层+乘区回写，零杀）。
  - 收尸/生成面（零杀）：enemy_spawner.gd:38→`_on_enemy_killed`（:229——归还+active 收窄）；game_loop.gd:3194→`_on_enemy_killed_drop_xp`（掉宝）；wave_director.gd:88（波事件）。
  - 表现/计数面（零杀）：game_feel_director.gd:83、game_loop.gd:3234（Boss BGM）/:3339（lambda）、meta_manager.gd:596（图鉴/成就）、boss_bar.gd:47、confetti.gd:31、hud.gd:223。
  - 原三员复核保留：毒溅伤玩家≠敌杀；`_death_element_discharge` 纯表现（enemy.gd:1343-1360 注记〔实证〕）。
- **队列基础语义**：队列序=死亡发生序（FIFO）；逐敌 `is_instance_valid ∧ dead` 复验后执行 fan-out（防看门狗/其他路径先行归还）。
- **弹自身死亡链不在本刀面**：弹回收 `_recycle`→release 已由 R271 惰性归位批量化（留桶不 reparent，O(1) swap-remove，projectile_pool.gd:118-141〔实证〕），无新增动作——文档声明即可。
- **落点**：enemy.gd（拆分+入队门）、game_loop.gd（队列成员+两冲刷点+兜底）。

### 3.4 P0 先行件：二轮分键（R284-C 遗留账，本批内闭合）

- **四分键**（debug_stats.gd 新秒窗键，stage_probe_enabled 门内计时，只加不改）：`命µs`（收集段查询+窄相）/`结µs`（_flush_hit_pairs 提交链）/`死µs`（死亡 fan-out 冲刷段）/`回µs`（弹 _recycle→release 链）+`ipµs`（_ip_restore/_ip_snapshot 双遍历合计）。关态「命/结」键自然为 0（段不存在），「死/回/ip」键关态也累计（现状路径计时——零行为）。
- **deeprepro 新臂**（tests/qa_r271_deeprepro_cases.gd 增臂，落盘参化 `-- archive=1` 语义沿用）：
  - G0 现状臂（grid_hit_override=0 强关，即使 boost 开）——刀后关态基线；
  - G1 网格命中臂（override=1 强开）——T1 单独 A/B；
  - G2 死亡冲刷臂（death_flush_override=1、grid 关）——T3 单独 A/B；
  - S8 ip 短路臂（`GameLoop.shortcircuit_ip_pass` static 注入口，默认 false——R271 S 臂同款纪律）：ip 双遍历早退 → ipµs 份额定谳（§1.4 假说①的裁决臂）。
- **判读规则**：某臂塌缩 ≥60% → 对应段坐实主源；全不塌缩 → 弹系数主体在更深层（如实登记，候选移交：节点树存在性簿记/渲轴），**不许硬编归因**。

## 4. 数值框架（初始值，均待调参）

| 参数 | 初始值 | 依据 |
|---|---|---|
| 命中对缓冲容量 | 复用缓冲无上限（帧内自然上界≈活弹×pierce） | 零分配纪律；448 弹实测对数由 G1 臂读数回填 |
| 命中率统计对拍容差带 | ±2%（多 seed 聚合） | §3.1.5 声明「统计不变」的可测化；vc85 真机校准 |
| 30Hz 档步预算 | 33.3ms（现状） | vc83 拟合口径；本批目标=弹侧份额显著回落 |
| 弹侧步µs 目标带 | 717k/s → **≤350k/s**（boost 态，P0 四分键合计口径） | 对应 30Hz 步预算占比 96%→≤47%；预期构成=T3 死亡冲刷+结µs 批量化收益；**达不达成都按 P0 键指名**（不设不可证硬承诺） |
| vc85 真机判读锚 | 步µs 深载行回落、命/结/死/回/ip 五键首读入账、fps 深载 ≥30 | R272 判读指引同款格式（tracker :2007） |

## 5. 验收标准（headless 可跑断言面；QA 直接转用例）

跑法模板（每套件独立进程；跑前确认无残留 Godot 进程；日志 `tools/r285_*.log`）：
`E:/Code/Agent/Infinite-Fission/tools/Godot_v4.3-stable_win64_console.exe --headless --path E:/Code/Agent/Infinite-Fission/repo -s tests/<套件>.gd [-- archive=1]`

**T1（`tests/qa_r285_gridhit.gd(+_cases)` 新套件）**：
- t1a 序守卫：穿透弹（pierce=1）两敌同帧候选 → 冲刷只结第一对、第二对跳过、无幻影结算（serial 复用场景：FRACTAL 母弹回收同帧子代 acquire 复用节点——夹具直驱）。
- t1b 收集/冲刷同帧：boost 态 600 帧驱动，断言帧 N 收集的对在帧 N 冲刷完毕（跨帧滞留计数==0）；关态两缓冲恒空。
- t1c 命中对拍台架（声明验收）：seed 固定小场景（1 武器+驻场敌+600 帧）×override 0/1 各跑两遍——①同 override 两遍全指标逐位相等（确定性锁）；②跨 override 多 seed（≥5）聚合 hits/kills/damage（含燎原 DOT 面〔v2·M1〕）差 ≤±2%（§4 容差带）；③单弹单敌受控夹具逐项对拍表（§5.1）全等。
- t1d 关态逐位：override=0 且 boost_override=1（强关压过 boost）→ pkg4 关键路径夹具（W1 三线/W2 曳光/回旋 ICD/跳弹贴边）行为读数与刀前基线逐位（git stash 双跑对拍法：stash 刀后提交跑 A、取回跑 B，pkg4+本套件双绿即证）。
- t1e 掷斧/敌弹不受扰：_flight_axe 弹零命中对；team1 敌弹撞玩家时序读数两态相等。

**T2（qa_r285_physface）**：p1-p4 如 §3.2（全部可跑断言，无性能断言）。

**T3（`tests/qa_r285_deathflush.gd(+_cases)` 新套件）**：
- t3a 批量化（〔v2·M3〕快照语义）：boost 态单帧 3 杀 → `emit_enemy_killed` 计数在冲刷点前==0、冲刷后==3（快照计数冲刷，读数确定）；死亡序=FIFO；spawner.active 收窄发生在冲刷点（关态=即时）；冲刷中人为再入队（夹具直调 `enqueue_death`）→ 当帧兜底点吸收排空（帧末队空断言），无跨帧滞留。
- t3b inline 面不动：dead 旗在 apply_damage 时点即置位（冲刷前后续命中被死亡短路——穿透不浪费断言）；marks/引信清零时点不变。
- t3c 关态逐位：death_flush 关 → fan-out 即时执行（死亡弹爆/毒溅/收尸时序与刀前基线读数逐位）。
- t3d 兜底：帧末兜底冲刷后队列恒空（长跑 600 帧断言）；is_instance_valid 复验（夹具中途 free 一敌不崩）。
- t3e 燎原连锁读数〔v2·M1〕（§3.1.5 声明④的验收面）：ELE_IGNITE 层 2 质变构筑+双敌同帧双杀 fixture（A 先死、B 在同帧对提交段稍后死）→①各 override 侧跑两遍「燎原点燃目标数」逐位相等（每侧确定性锁）；②关/开侧目标数差∈声明带（多 seed 聚合统计；漂移方向单向=开侧收窄——B 类目标被 :699 dead 过滤跳过，按声明迁移**不设逐位门**）；③关态燎原面逐位（fan-out 即时、dead 过滤时序与刀前一致）。

**P0（deeprepro 扩臂 + stepacct 复跑）**：
- p0a deeprepro 增 G0/G1/G2/S8 四臂跑通、verdict 表新行打印、`-- archive=1` 已存在归档拒写且 exit 0（拒写分支本轮**必须实跑一次**留痕——R272 遗留「未整跑实测」项顺带闭账）；缺省复跑态只写 postcut。
- p0b M4 有效性门在 G 臂下不翻红（敌 ≥85/弹 ≥420/量级键带内）；若 G1 刀致既有数值断言翻红=**声明迁移（非删除）**，迁移点逐条登记进本档 §6。
- p0c 四分键+ipµs 在 stepacct 套件补格式断言（键存在/秒窗累计>0/行序冻结），qa_r271_stepacct 全绿不迁移。

**全局门（全绿 exit 0）**：pkg4 **116/0**（seed=42 零位移）、verify_feedback **685/0 实跑**（除 §0.2 预声明迁移点）、qa_r269_boostmode 69、qa_r272_enemylazy 28、qa_r271_deeprepro（扩臂后全绿）、qa_r271_stepacct 18、qa_r271_flushcut 24、qa_r268_physphase、qa_r228_diagfreeze、r237 物理面（T2 p3 交叉）、r214/r212/r229 池面全套、r202 接触面。

**5.1 语义对拍表（T1 关态路径 ↔ boost 网格命中路径，逐项；「≡」=构造性同函数/同序；「偏移」=帧级偏移，§3.1.5 声明制覆盖）**

| 语义项 | 关态现状路径 | boost 网格命中路径 | 等价性裁定 |
|---|---|---|---|
| 命中判定 | tick 槽内 query_circle_snap+`_in_reach(_swept)` 即时结算 | 同查询同窄相，④ 尾提交 | ≡（§3.1.1-3；t1c3） |
| 穿透 | 命中即 `pierce_left--`，耗尽 `_recycle(PIERCE_DEPLETED)` | 冲刷段同链，序守卫跳剩余对 | ≡（t1a） |
| 反弹 | 敌命中不改反弹预算（R15 跳弹=墙反弹，贴边带预检不动） | 同左（反弹面零触碰） | ≡（t1d 夹具） |
| 元素附着/反应 | `_apply_elemental` 结算后提交；⑤ `detect_reactions` 帧末检测 | 提交时点④尾，仍在 ⑤ 检测前 → 同帧反应面不变 | ≡（t1c3 附着计数） |
| 词条 OnHit 注入 | `_prepare_hit_traits` 槽内派发（挂载序） | 冲刷段同一函数同一派发序 | ≡（t1c3 派发计数） |
| 暴击 | pipeline 流 rng 逐命中 roll（独立流） | 提交序≡关态结算序 → 流序同；分布断言带内 | ≡序/统计（t1c2） |
| E-03/R196 去重 | hits_this_frame/`_hit_uids` | 零改动（冲刷走同一 `_submit_hit`） | ≡ |
| 击杀 fan-out | apply_damage 即时 `_on_died` 全链 | T3：mark inline+fan-out 冲刷点 | 帧级偏移（§0.2 迁移点；t3a-c） |
| hp_pct/波首杀条件读 | 击杀 fan-out 后的命中读到新值 | 冲刷段先于 fan-out 读旧值 | 帧级偏移（§3.1.5 ①；t1c2 统计带） |
| homing 重索敌 | 同帧 AOE 杀后重索敌读到新目标 | 收集段先于冲刷 → 当帧沿用原目标 | 帧级偏移（§3.1.5 ②；登记观察项） |

## 6. 游戏性影响披露与回滚

- **T1/T3（boost 开侧）**：命中与击杀反馈时点帧内后移（≤1 槽/至冲刷点，同帧内肉眼不可辨）；死亡弹爆/毒溅/掉宝相对同帧后续命中的先后序漂移（§3.1.5 声明）；〔v2·M1〕同帧多杀的击杀连锁读数漂移——燎原点燃目标集收窄（ELE_IGNITE 层 2 构筑的 DOT 收益小幅带内波动、方向单向收窄）与连杀狂热/精英首杀/回声·共鸣叠层的乘区读数漂移；跳字当帧起跳不变（派发段仍在 ⑧ 前）。**boost 关侧（桌面/headless/测试）零观感零行为变化**。
- **T2**：零行为（纯断言套件）。
- **总回滚**：`grid_hit_override=0`/`death_flush_override=0` 单点强关即回现状（无需回滚代码）；设置面零新增（不暴露用户开关——mobile 保帧模式沿用既有 perf_boost 总闸语义，本批两门跟随它）。

## 7. 范围（必做/可选/明确不做）

**必做**：P0 四分键+ipµs+deeprepro G0/G1/G2/S8 臂（先行合入）；T1 sweep（收集-冲刷+序守卫+对拍台架）；T2 守门套件；T3 死亡冲刷（两冲刷点+兜底）；三新套件+全局门全绿；vc85 出包与判读锚表。
**可选**（P0 verdict 门控，本批不默认做）：ip-pass 量化/暂存刀（仅当 S8 臂坐实 ipµs 份额 ≥60%——**属新刀面，需主会话追认授权**）；SpaceGrid 批量查询接口（仅当 G1 臂证查询段仍为主源且原生桥改造收益成立）。
**明确不做（本批砍，防范围蔓延）**：玩家弹帽/任何拒发-挤弹类应急阀（用户拍板否决）；弹运动模型/插值层（R233 T5/T6）重写；SpaceGrid 桶序/快照语义/R239 原生桥接口变更；team1 敌弹命中面（撞玩家直判不动）；敌侧再优化（R272 已收口）；结算帽/派发帽/池阀/物理频率（R269 §0.8 承接）；桌面关态性能提升（本批目标绑定 boost 档）；渲轴（绘µs/dc/填充率——B 轴另批）；Area2D 回迁任何面。

## 8. 任务拆解与文件归属

- **P0 实施员**（先行）：debug_stats.gd（五新键）、game_loop.gd（shortcircuit_ip_pass+四分键探点+G 臂 override）、tests/qa_r271_deeprepro_cases.gd（四臂）、tests/qa_r271_stepacct_cases.gd（键格式断言）——与 T1 实施员在 game_loop.gd 的交叠=④ 相同函数面，**串行**（P0 先合入）。
- **T1 实施员**：projectile_base.gd（run_serial/_collect_hit_pairs/尾部分流）、game_loop.gd（两门+对缓冲+_flush_hit_pairs）、tests/qa_r285_gridhit.gd(+_cases)。
- **T3 实施员**：enemy.gd（_on_died 拆分+入队门）、game_loop.gd（死亡队列+冲刷点）、tests/qa_r285_deathflush.gd(+_cases)。
- **T2 实施员**：tests/qa_r285_physface.gd(+_cases)（零产品面，可与任一并行）。
- 实施序：P0 → T1 → T3 → T2（并行）→ 全局门 → vc85 出包 → 真机判读（§4 锚）。工作量估算：P0 0.5 天、T1 1-1.5 天、T3 0.5-1 天、T2 0.5 天、回归 0.5-1 天，合计 **3-4.5 天**。

## 9. 假设与开放问题

1. **T1 措辞重定义待主会话确认**：原文「从 Area2D overlap 改网格轮询」与代码事实冲突（§1.2 五条实证）——本设计已按「帧级 sweep+统一结算」重构 T1；若主会话本意另有所指（如确指某条我未发现的 Area2D 弹路径），需在实施前纠正本文档。
2. **弹系数 1.6ms/s/弹 构成未定谳**（R284-C 自记待二轮分键）：headless 证据（S4≈0%/S6=77%）指向命中/死亡级联与存在性成本而非查询本体——T1 收益不设硬 fps 承诺，P0 键 vc85 裁定；若 P0 显示 T1 份额 <5%，vc85 判读不得把 fps 未达标归咎 T1 落空（诚实账）。
3. **「余」段主嫌=ip 双遍历+级联**（§1.4 假说①②）：若 S8 臂坐实，追加 ip 刀面需主会话追认（§7 可选项）——当前未授权，本批不做。
4. **DOT 死亡路径归属**：元素烧灼/毒环残效的杀是否经 take_result→apply_damage 未核实（本设计轮未读 elemental_system.gd 结算尾）——实现期核对，T3 两冲刷点设计两种结果均已覆盖，不影响刀面成立。
5. **命中率统计容差带 ±2% 为初始拍板值**：homing 同帧 AOE 重索敌偏移（§3.1.5 ②）与燎原 DOT 漂移（〔v2·M1〕§3.1.5 ④，方向单向收窄）在极端构筑下可能放大单 seed 离散度——vc85 真机若超带，先分键（homing 子群/燎原构筑单列）再议带宽或收窄声明面，不得静默放宽。
6. **boost 态既有套件面**：qa_r269_boostmode/qa_r272 等以 boost_override=1 跑行的套件，刀后将自然走新路径——QA 须核对其断言是否锚定命中/死亡时序（预期否：它们锚 fx/桶/装饰面）；若有锚定=按 §0.2 迁移制随包裁定。
7. **V-A 未实施的事实与 vc83「Area2D overlap」假说的关系**：敌侧 90 监控 HitArea×玩家对仍在物理空间（桌面与 boost 同，产品侧 CONTACT_RADIAL 零写口，§1.2-e）——但该面成本按**敌数**计（R271 S2 臂实测其份额 ≤33%，延∪隙∪物步并集口径；拟合敌系数 3.2µs/s/敌 vs 分离行 1-9 敌仍 560-745k/s），不足以解释弹系数。本批不动该面；若 vc85 P0 分键后敌侧物理面仍被指名，R237 预置清退刀（翻旗+应用点补置位，R271 §3.3-V-A 全套设计在案，含 M2-R 反向重建教训）是现成低成本候选——**需另行拍板，不在本批刀面**。

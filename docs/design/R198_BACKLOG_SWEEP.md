# R198 · 待办池总清账——统合执行方案（R198_BACKLOG_SWEEP）

> 来源：二bi 登记（FEEDBACK_TRACKER.md「R198 登记」行）——3 路盘点探索产出 33 条核实结果，本文统合为可执行分组方案。
> 硬约束：分 5 个实现组，**文件所有权零交集**（FEEDBACK_TRACKER.md 只归「收尾销账」组）；每个 todo 项必须有 WorkItem（id 对上盘点 id）；done-unlogged 走销账写回；user-side 只登记不动手。
> 纪律模板见 §8。**游戏桌面实例正在运行——功能套件可跑，性能基准类（r188 性能三跑/风暴 bench）禁跑。**

---

## 1. 核实汇总表（33 条盘点 → 处置去向）

| id | 判定 | 处置去向 | 证据锚（简） |
|---|---|---|---|
| 二aw-1 | todo | 组2 WorkItem | serialize_run 17 键无 relics（game_loop.gd:1695-1714，本轮复核确认）；continue_run 无 relic 恢复（:1717-1830） |
| 二aw-2 | todo | 组2 WorkItem | on_attack_fired 每开火恒计 cdp=0.01（relic_handler.gd:371-391，复核确认）；tick 回充/存款帽 :404-411/:489-496 |
| 二aw-3 | todo | 组5 WorkItem（W8 半边 moot，见 §7 skipped） | 全 tests 树无 TargetBar 锁定/血量/续窗行为断言；W8 附着三件套 R187 已拆除 |
| 二aw-4 | todo | 组4 WorkItem | meta_manager.gd:206 写「2s 无敌」vs player.gd REVIVE_INVULN_S=3.0（本轮复核确认 :206） |
| 二aw-5 | todo | 组4 WorkItem | texture_factory.gd:1395-1492 skill_icon match 仅 8 case，`_:` 默认通用星（复核确认） |
| 二aw-6 | todo | 组4 WorkItem | meta_manager 仅 fissioner_unlocked 信号（:18/:780，复核确认）；echo 解锁=派生谓词 unlock_hard_clear（character_table.gd:91→meta_manager.gd:357-358）无解锁事件 |
| 二aw-7 | todo | 组4 WorkItem | menu_screen.gd:1292-1296 长解锁句 + :1310-1312 name_l 406×28 单行无 autowrap（复核确认） |
| 二aw-8 | done-unlogged | unloggedDone + 组5 销账行 | orbit_field.gd R188 档0 三件套在码；tracker 二aw 流程行（:527）与 R188-4 行（:499）未回写 |
| 二aw-9 | done-unlogged | unloggedDone + 组5 销账行 | hud.gd:110-115 脏标记/同帧合并、:208-210 事件驱动+1Hz、:234-237 build 签名全在码 |
| 二aw-10 | done-unlogged | unloggedDone + 组5 销账行 | MEC_KNOCK.tres:17 required_forms=[0,2,3]（含 form3=W8） |
| 二aw-11 | done-unlogged | unloggedDone + 组5 销账行 | R187 拆除 attach 三件套，数据键全落 melee 段——所指路径不存在，moot(supersede) |
| R191-low1 | todo | 组4 WorkItem | meta_manager.gd:66-67 boss_slain [3,5,8]/[0,0,60]/单局 desc 已与 R191 口径一致且单局化在码（:185/:683/:813/:854）——改排无痕迹；本批落自洽锁（口径 11） |
| R191-low2 | done-unlogged | unloggedDone + 组5 销账行 | 探针实测 0 命中（44/44 绿）；修复本体=menu_screen mult_fmt token 格式化器 |
| R191-low3 | done-unlogged | unloggedDone + 组5 销账行 | hud.gd:620-652 成就 toast 已整体重写，旧文案不存在（moot） |
| R192-low1 | todo | 组1 WorkItem | damage_popup.gd:215-235 落空静默返回空串（复核确认）；elemental_system 结算臂 rule.get 硬默认无告警 |
| R192-low2 | todo | 组1 WorkItem | elemental_system.gd:302-312 冻结臂仅查 IMMUNE_FREEZE，chill/vuln 无条件写（复核确认）；附着段 IMMUNE_CHILL 检位先例 elemental_state.gd:250-256 |
| R192-low3 | todo | 组1 WorkItem | 实现侧 game_const.gd:252-253 + damage_popup.gd:233-234 出「燃烧5层」；设计文档 R192_ELEMENT_MATRIX.md:236 仍写 stat 型无数——按口径 4 文档就文件 |
| R192-low4 | todo | 组2 WorkItem | damage_pipeline.gd:21-22 双闸、:113-117 置位仅记审计（复核确认）；全仓无复位点，pipeline 进程级单实例 |
| R192-low5 | todo | 组1 WorkItem | balance_tables.gd:90 注释 ×205 vs 同文件 :87-88 金梯 φ=4.68（4.68³≈102.5，复核确认） |
| R192-low6 | todo | 组1 WorkItem | balance_tables.gd:66 delay=1.5（复核确认）；**r192_element_cases.gd:28 夹具钉死 delay 1.5 需按 R198 契约变更同步改写** |
| R192-low7 | todo | 组1 WorkItem | ELE_SHOCK.tres:8 display_name=「感电」与 game_const.gd:379 RXN_LTG_HYD 反应名同名（复核确认）；卡族命名风格=主题名（潮湿/草种/风域/岩铠） |
| R192-low8 | todo | 组4 WorkItem | menu_screen.gd:1018-1025 RxnMult 148×18 单行右对齐无 autowrap（复核确认）；绽放 mult_fmt（game_const.gd:172）估宽超格 |
| R192-low9 | todo | 组1 WorkItem | 四卡 desc 三种配对口径并存（ELE_*.tres:9，复核确认） |
| R192-low10 | todo | 组1 WorkItem | popup_manager.gd:9-10 头注桶枚举漏 bucket 4；_style_bucket :263-270 CHARGE_BURST→4（复核确认） |
| P2-escort | todo | 组2 WorkItem | player.gd:1334-1354 SummonDrone._process(p_delta) 自驱（复核确认）；player.tick(p_game_delta,...) 在码（:201）可挂 |
| P2-lockglyph | done-unlogged | unloggedDone + 组5 销账行 | 🔒 字面量全仓清零；ui_lock 贴纸替代；真机残余已并入 R196 收口行真机清单（:427） |
| P2-skillcopy | todo | 组4 WorkItem | character_table.gd:70 诺亚 skill_desc 未提 12% 伴随火力（复核确认；火力实存 player.gd:1304-1306/:1317/:1356-1364） |
| 二az-1 | user-side | §7 userSide（不动手） | tracker :489 用户撤回留档行 |
| 二ax-7 | user-side | §7 userSide（不动手） | tracker :514 用户撤回不改行 |
| r195-1 | todo | 组2 WorkItem | laser_beam.gd:501 `ctx.pierce_index = p_ordinal + 1` 无差别写入（复核确认）；主束门控谓词现成在码（:392-399 `depth == 0 and not sub_beam and not overlap_fallback`） |
| r195-2 | todo | 组5 WorkItem | 设计真源只钉 2 对（R195_SCREEN_ADAPT.md:318-321）；两套件各白名单 3 对 + layout 套件头注漂移 |
| r195-3 | todo | 组3 WorkItem | hud.gd 四处 toast 720 设计域死坐标；活宽范式 hud.gd:1502-1507（复核确认） |
| r195-4 | todo | 组4 WorkItem | menu_screen.gd:709-722 LobbyScroll 横向钉卡左缘（复核确认）；父卡 720 域宽 648，锚 0.5=324，±296=28..620 逐位恒等 |
| r195-5 | todo | 组1 WorkItem | confetti.gd:67-70 rain_w 取 viewport 实宽（复核确认），piece 坐标属世界 720 逻辑域——量纲错配 |
| r195-6 | todo | 组1 WorkItem | elemental_fx_layer.gd:29 IMPACT_COUNT=10、:619 轮转取槽；高射速×穿透下欠配 ~2× |
| r195-7 | todo | **并入 工具-bump**（口径 6） | export_apk_versioned.py bump 先落盘后检查/导出/门禁 |
| r196-1 | todo | **并入 账面-r196套件命名**（口径 6） | 覆盖实证在 r196_growth_cases.gd ⑥/⑧；引用仅 tracker 4 处 |
| r196-2 | todo | **并入 工具-a12-emoji**（口径 6） | export_artifact_gate.py 无字节探针；A12 定案口径已实证（compression.zstd 可解 99/99） |
| r197-1 | todo | 组3 WorkItem | hud.gd:960 `range(mini(gems.size(), 7))` 静默截断（复核确认） |
| r197-2 | todo | 组3 WorkItem | hud.gd:972 字号 9 / :913 Lv 字号 10，540×960 桌面窗 0.75 缩放难读 |
| r197-3 | todo | 组3 WorkItem | hud.gd:974-975 cnt 24 宽 @x100 → 右沿 124 > content 120（hud.gd:866，复核确认 :960-976 区域） |
| r194-1 | todo | 组2 WorkItem | wave_director.gd:148（tick 守卫旗）与 :250（回退分支）写同名计数器（复核确认）；断言 export_data_cases.gd:197-199 仅 ≥1 恒绿 |
| r194-2 | todo | 组3 WorkItem | hud.gd:1342-1351 暂停钮 72×72 y26..98 × 金币 pill y92..128 → 6px 重叠带（复核确认 :1338-1352） |
| 工具-bump | todo | 组5 WorkItem（含 r195-7） | 最小改法=快照回滚式 try/finally（详见 WorkItem） |
| 工具-a12-emoji | todo | 组5 WorkItem（含 r196-2） | A12 断言组落 export_artifact_gate.py + 导出器 gate() 轻量镜像 |
| 账面-r196套件命名 | todo | 组5 WorkItem（含 r196-1） | tracker 四处指向改写（内容锚定，本轮复核实际行 = :395/:401/:406/:427） |

---

## 2. 口径决策（已拍板，逐字落进对应 WorkItem.how）

1. **激光副束/折射束序数**：序数加成仅主束——副束/折射束 pierce 序数贡献归零（SYN_PIERCE_EVO 对副束 (pierce_index-1)=0），代码按实情实现（如 _settle_one_tick 加主束标记或序数置 0），注释注明 R198 口径，断言锁死副束贡献=0。
2. **r196_wunlock_cases/r196_icon_cases 命名债**：账面修正（tracker 行与 R196 设计文档相关句改指向 r196_growth_cases.gd 实际覆盖节），不建重复套件；除非盘点发现真覆盖缺口（盘点已证实无缺口——P2 归 A12、gen_music.gd 盲区同由 A12 字节级扫描覆盖）。
3. **R196 定案文档卡片**：由工作流脚本用 artifact.markdown 直发（勿写进任何 WorkItem）。
4. **R192 文案项**：按 tracker 行内既有建议方向落，具体措辞以 GameConst 现有口径为准（燃烧=保留实现文案、设计文档就文件；感电=卡名让位反应名，REACTION_NAMES 不动）。
5. **暂停钮压金币 pill 6px**：优先微调暂停钮 y 或尺寸（触控目标不小于 66px 口径不回退，72×72 保留），次选金币 pill 让位——按实码定（实码复核：暂停钮上移 6px 即零重叠，取微调 y）。
6. **同源归并**：r195-7≡工具-bump、r196-2≡工具-a12-emoji、r196-1≡账面-r196套件命名——各并为一枚 WorkItem（id 取后者），盘点 id 在 §1 标注「并入」，不重复实施。
7. **FEEDBACK_TRACKER.md 编辑权只归组5**：组1-4 修复项对应的 tracker 登记行由组5 在收尾位统一回写；行号一律以内容锚定为准（盘点行号存在 ±6 漂移，本轮已按内容重锚，见销账 WorkItem）。
8. **新套件按组建制**：r198_element_fx / r198_flow_weapon / r198_hud_layout / r198_menu_meta 四个新套件各归各组独占（避免跨组共写同一新文件）；r195_layout / r195_adapt 等「只跑不改」回归套件不进组文件所有权清单。
9. **二aw-2 慢速武器补偿口径**：`cdp_eff = cd_per_attack × clampf(开火间隔 × rate_per_sec, 1.0, fire_mult_max)`，fire_mult_max 为 REL_ATTACK_CDR.tres 新参数（默认 10.0）；预算回充与存款帽口径不变——每秒 CDR 收益在预算内与射速解耦，爆发仍受存款帽约束。开火间隔实码现成：weapon_base.gd 开火咽喉已记 `_last_interval`。
10. **R192-low6 拍板值**：绽放 delay 1.5→0.75（balance_tables.gd 与 data/balance/balance_tables.tres **双源同批**，设计文档同步；r192_element_cases.gd:28 夹具行按 R198 契约变更改写）。**R192-low7 拍板措辞**：ELE_SHOCK display_name「感电」→「雷引」（对齐卡族主题名风格；反应名「感电」单源不动）。
11. **R191-low1 处置**：实码复核 boss_slain 档 [3,5,8]/[0,0,60]/单局 desc 与 _run_boss_slain 每局重置链已自洽（核实证实）——本批补自洽契约断言防回退 + 销账；仅复核发现失洽时才做包络内改排。

---

## 3. 分组表（文件所有权零交集）

| 组 | 条目 | 独占文件 | 自测套件 |
|---|---|---|---|
| **组1 元环表现** | R192-low1/2/3/5/6/7/9/10、r195-5、r195-6 | scripts/combat/elemental/elemental_system.gd、scripts/ui/damage_popup.gd、scripts/core/game_const.gd、scripts/core/data/resources/balance_tables.gd、data/balance/balance_tables.tres、scripts/ui/popup_manager.gd、scripts/gamefeel/elemental_fx_layer.gd、scripts/ui/confetti.gd、docs/design/R192_ELEMENT_MATRIX.md、resources/traits/ELE_SHOCK.tres、resources/traits/ELE_HYDRO.tres、resources/traits/ELE_DENDRO.tres、resources/traits/ELE_ANEMO.tres、resources/traits/ELE_GEO.tres、tests/runner/r198_element_fx_cases.gd(新)、tests/runner/test_r198_element_fx.gd(新) | r198_element_fx(新)、rxn_codex、r192_element、elem_smoke、elem_immune、fx_quality |
| **组2 战斗流程** | 二aw-1、二aw-2、R192-low4、r194-1、P2-escort、r195-1 | scripts/loop/game_loop.gd、scripts/meta/run_save.gd、scripts/loop/relic_handler.gd、scripts/combat/weapon/weapon_base.gd、resources/relics/REL_ATTACK_CDR.tres、scripts/core/damage/damage_pipeline.gd、scripts/entities/wave/wave_director.gd、scripts/entities/player/player.gd、scripts/combat/weapon/laser_beam.gd、tests/runner/r195_laser_pierce_cases.gd、tests/runner/buff_audit_cases.gd、tests/runner/export_data_cases.gd、tests/runner/r198_flow_weapon_cases.gd(新)、tests/runner/test_r198_flow_weapon.gd(新) | r198_flow_weapon(新)、r195_laser_pierce、w4_prism、w5_mirror、buff_audit、r194_mobile、pkg0、pkg2 |
| **组3 HUD** | r195-3、r194-2、r197-1、r197-2、r197-3 | scripts/ui/hud.gd、tests/runner/r197_build_panel_cases.gd、tests/runner/r198_hud_layout_cases.gd(新)、tests/runner/test_r198_hud_layout.gd(新) | r198_hud_layout(新)、r197_build_panel、r195_layout(只跑)、r195_adapt(只跑)、r194_mobile、r196_growth |
| **组4 菜单成长** | 二aw-4、二aw-5、二aw-6、二aw-7、R191-low1、P2-skillcopy、r195-4、R192-low8 | scripts/ui/menu_screen.gd、scripts/ui/texture_factory.gd、scripts/meta/meta_manager.gd、scripts/meta/character_table.gd、scripts/ui/theme.gd、tests/runner/r191_rework_cases.gd、tests/runner/r198_menu_meta_cases.gd(新)、tests/runner/test_r198_menu_meta.gd(新) | r198_menu_meta(新)、r191_rework、rxn_codex、mech_gate、r196_growth、r195_layout(只跑)、r195_adapt(只跑) |
| **组5 收尾账面工具** | 二aw-3、r195-2、账面-r196套件命名、工具-bump、工具-a12-emoji、销账-回写 | FEEDBACK_TRACKER.md、docs/design/R195_SCREEN_ADAPT.md、tests/runner/r195_layout_cases.gd、tests/runner/r195_adapt_cases.gd、tools/export_apk_versioned.py、tools/export_artifact_gate.py | r195_layout、r195_adapt（+Python 探针两条，见 WorkItem 验收） |

交集自查：game_loop.gd 仅组2；menu_screen.gd 仅组4；hud.gd 仅组3；damage_popup.gd 仅组1；meta_manager.gd 仅组4；FEEDBACK_TRACKER.md 仅组5；tools/* 仅组5；各测试文件各归一组；四个新套件文件名互异。**零交集成立。**

---

## 4. WorkItem 明细

### 组1 元环表现（元素反应文案/注释/表现池）

**R192-low1 结算臂级硬默认补告警**
- files: scripts/ui/damage_popup.gd, scripts/combat/elemental/elemental_system.gd
- how: ①damage_popup.gd:221-235 reaction_stat_text——`rule.is_empty()`（表缺键/枚举错位）时 push_warning 后仍返回 ""；**感电/扩散族等合法无统计段保持静默**（:220 注释口径，不得误报）。②elemental_system.gd 结算臂（:296 coef/:306 freeze_dur/:326 burn_layers_max 等 rule.get 硬默认）——各臂取键前 rule.has() 检查，缺键 push_warning（会话一次闸，照 wave_director.gd:43 `_empty_comp_errored` 先例），仍用默认值不中断结算。
- acceptance: r198_element_fx 新断言：构造缺键 rule → 告警路径触发且结算不崩；合法无统计段反应（RXN_LTG_HYD）reaction_stat_text=="" 且零告警。rxn_codex/r192_element 全绿。

**R192-low2 冻结臂补 IMMUNE_CHILL 检位**
- files: scripts/combat/elemental/elemental_system.gd
- how: elemental_system.gd:302-312 RXN_ICE_HYD 臂：freeze 门（:305 IMMUNE_FREEZE）不动；:307-309 chill_timer/vuln_mult/vuln_timer 三写前置 `(p_state.immune_mask & GameConst.IMMUNE_CHILL) != 0` 整段跳过——**镜像附着段先例**（elemental_state.gd:250-256「冰免疫怪整段不吃寒滞/易伤/冻结」）；:310-312 clear_element 与 reaction_triggered 广播保持无条件。注释注明 R198 口径（与附着段同族）。
- acceptance: r198_element_fx 断言：IMMUNE_CHILL 目标吃冻结反应 → freeze 不发生（IMMUNE_FREEZE 半边语义不变）且 chill_timer==0/vuln_mult 不变；非免疫目标行为逐值不变（冻结 1.2s/寒滞 2.5s/易伤 ×1.25 3s）。elem_immune 全绿。

**R192-low3 燃烧「5层」设计文档回写**
- files: docs/design/R192_ELEMENT_MATRIX.md
- how: 口径 4：实现侧文案（game_const.gd:252-253 mult_fmt「至多 {burn_layers_max:.0f} 层」+ sample「燃烧」、damage_popup.gd:233-234「%d层」）是事实口径，**零代码改动**；设计文档 :236 一带把 stat 型「感电/燃烧/扩散·X」无数描述改为「燃烧=至多 N 层（读表 burn_layers_max）」，其余 stat 型表述核对后如实用词。注明 R198 回写。
- acceptance: 设计文档与实机跳字/图鉴口径一致（燃烧带层数、超导/激化/结晶带百分比、感电/扩散无统计段）；grep 全仓「燃烧」设计描述无残留 stat 型无数表述。rxn_codex 全绿（图鉴样张单源未动）。

**R192-low5 告警线注释算术修正**
- files: scripts/core/data/resources/balance_tables.gd
- how: :90 注释「3 金 VOID 连乘 ≈×205>50」→「≈×102.5（φ=4.68³）>50」，与 :87-88 金梯 4.68 自洽。纯注释，零行为。
- acceptance: grep balance_tables.gd 无「×205」残留；语义复核 4.68³=102.5>50 结论不变（越线后 ×50 仍为实际伤害帽）。

**R192-low6 绽放延迟调参**
- files: scripts/core/data/resources/balance_tables.gd, data/balance/balance_tables.tres, docs/design/R192_ELEMENT_MATRIX.md, tests/runner/r192_element_cases.gd
- how: 口径 10：delay 1.5→0.75——balance_tables.gd:66 与 data/balance/balance_tables.tres **双源同批**（:58-60 注释明令改键两处同批）；设计文档 R192_ELEMENT_MATRIX.md:101 同值同步；**tests/runner/r192_element_cases.gd:28 夹具行 delay 1.5→0.75，注明「R198 契约变更」**；改断言前全仓 grep `delay.*1.5`/`HYD_DEN` 同名副本（rxn_channel_cases 等逐一核对）。
- acceptance: r192_element、rxn_codex、rxn_channel 全绿；validator 双源同值闸不红；绽放触发→爆开延迟实感 0.75s（行为断言锁表值）。

**R192-low7 感电卡名消歧**
- files: resources/traits/ELE_SHOCK.tres
- how: 口径 10：display_name「感电」→「雷引」（对齐卡族主题名风格：潮湿/草种/风域/岩铠）；description 不动（其内文无「感电」字样，已复核）；REACTION_NAMES（game_const.gd:379）反应名「感电」**单源不动**。改前全仓 grep display_name 断言副本（图鉴页/卡面测试）；mech_gate_cases 的「感电」系反应解锁机制表述，不属卡名断言，勿误改。
- acceptance: 全仓 `display_name = "感电"` 零命中；r192_element/rxn_codex/mech_gate 全绿；图鉴元素卡行显「雷引」、反应跳字仍「感电+数字」。

**R192-low9 新卡配对措辞统一**
- files: resources/traits/ELE_HYDRO.tres, resources/traits/ELE_DENDRO.tres, resources/traits/ELE_ANEMO.tres, resources/traits/ELE_GEO.tres
- how: 统一箭头式主干（水/草两卡既有口径）：风卡改「（火→扩散 · 冰→扩散 · 雷→扩散 · 水→扩散 · 草→扩散，反应名带·元素后缀；岩→结晶·风）」，岩卡改「（任意元素→结晶，玩家减伤护体）」——反应名一律引 GameConst.REACTION_NAMES 既有词（扩散·X/结晶·X），描述本体机制句保持不改；desc 为自由文本不影响 validator 双射闸。措辞宽度与卡面排版自检（各卡 desc 单元格有 autowrap 兜底，R191 收口2 先例）。
- acceptance: 四卡 desc 配对枚举全部为「X→反应名」同构口径；grep 无「遇…即」列表式残留；r192_element/rxn_codex 全绿。

**R192-low10 桶注释漂移修正**
- files: scripts/ui/popup_manager.gd
- how: :9-10 头注桶枚举补全为「直击 0 / 反应 1 / 其余 2 / 文字 3 / 引爆 4（CHARGE_BURST，R187）」，与 _style_bucket（:263-270）逐值对齐。纯注释。
- acceptance: grep popup_manager.gd 头注含 bucket 4；无行为变化（feel/pkg 相关套件不受影响，抽跑 feel）。

**r195-5 confetti 落雨世界域修正**
- files: scripts/ui/confetti.gd
- how: :67-70 rain_w 删除 viewport 读取，恒用世界设计域宽 720（同 cloud_backdrop DESIGN_CANVAS 口径）；:64-66 注释更正——ConfettiBurst 挂 GameLoop 世界（game_loop.gd:1366-1368），piece 坐标属 720×1280 逻辑域，R195 的「活宽」口径在此不适用（get_visible_rect 是画布域，与世界域量纲错配，同 R195 收口教训 final_transform 同源）；爆发/叮字钳制段不动。
- acceptance: r198_element_fx（或 fx_quality）断言：rain piece 初始 x ∈ [0,720]；3:4 画布（960 宽）下世界可见带 [-120,840] ⊇ 落雨带全覆盖。纯表现，零玩法断言回归。

**r195-6 beam_impact 迸裂池扩容**
- files: scripts/gamefeel/elemental_fx_layer.gd
- how: IMPACT_COUNT 10→20（:29；每槽仍为预建 Node2D 组 3-4 sprite 静态池，零运行期实例化，_impact_idx 轮转取槽 :619 不动）；注释注明推导管：需求槽 ≈ tick_rate×目标数×IMPACT_LIFE×并行束数（8×4×0.16×主+3 副 ≈ 20）。
- acceptance: r198_element_fx 断言：池槽总数==20 且预建（_impacts.size()==20、无 add_child 于 tick 路径）；fx_quality 全绿（表现层契约不放宽）。

### 组2 战斗流程（存档恢复/告警复位/诊断计数/僚机 tick/激光序数/遗物调参）

**二aw-1 遗物随继续局恢复**
- files: scripts/loop/game_loop.gd, scripts/meta/run_save.gd, scripts/loop/relic_handler.gd
- how: ①serialize_run()（:1678-1714）键集追加 `"relics"`：`for r in relic_handler.owned: relics.append({"id": String(r.id)})`（纯基本类型容器，RunSave ConfigFile 透传，run_save.gd 头注结构表同步补键）。②continue_run/_restore_run_state（:1773-1837）恢复段：武器/数值覆写完成后 `for entry in data.get("relics", []): relic_handler.activate(StringName(entry.id))`——activate 幂等（has_relic 拒重）且 _apply_passive 自拉满每击谐振预算（relic_handler.gd:94-105/:36 注释），旧档无键 = 空表兼容零分支。③注意 _reset_run_state 已清 owned（relic_handler.reset_run），恢复须在其后。tracker :527 登记行回写归组5。
- acceptance: r198_flow_weapon 断言：局内 activate 遗物 → serialize_run 含同 id 集 → load+continue 后 relic_handler.owned id 集一致且常驻位生效（如 xp_mult>1）；无 relics 键旧档 continue 不崩且 owned 空。pkg0 全绿（存档结构变更过校验）。

**二aw-2 每击谐振慢速武器补偿**
- files: scripts/loop/relic_handler.gd, scripts/combat/weapon/weapon_base.gd, resources/relics/REL_ATTACK_CDR.tres
- how: 口径 9：①weapon_base.gd 开火咽喉（try_fire 成功位）改 `relic_handler.on_attack_fired(_last_interval)`（:60-74 区段，_last_interval 在同块已赋值）。②relic_handler.on_attack_fired(p_fire_interval: float)（:371-391）：守卫链不变；`var cdp_eff := cdp * clampf(p_fire_interval * rate, 1.0, fire_mult_max)`（rate=rate_per_sec、fire_mult_max=params 新键默认 10.0）；预算守卫仍 `< cdp` 丢整击，扣减 `snappedf(_atk_cdr_budget - cdp_eff, cdp)` 网格仍按 cdp（防浮点漂移，原 :376-377 语义保持），attack_cdr_seconds += cdp_eff。③REL_ATTACK_CDR.tres params 增 `"fire_mult_max": 10.0`，description 改写（口径 9 语义：「每次攻击 −0.01s×开火间隔折算（慢速武器按比例补足，上限 ×10）；每秒计费预算与存款帽不变」——最终措辞以描述单元格宽度自检）。④注释注明 R198 调参口径。
- acceptance: r198_flow_weapon 断言：间隔 0.5s 武器单击 cdp_eff=0.1s、间隔 0.1s 武器单击 0.02s（每秒收益均 ≈0.2s 预算封顶）；间隔 5s 武器 cdp_eff 触顶 0.1s（×10 帽）；fast 武器收益不低于改前（clampf 下限 1.0）。pkg0 全绿（.tres 过 validator）。

**R192-low4 r_rxn 告警跨局复位**
- files: scripts/core/damage/damage_pipeline.gd, scripts/loop/game_loop.gd
- how: ①damage_pipeline.gd 新增 `func reset_run_alarms() -> void:`（清 `_alarm_emitted`/`_rxn_alarm_emitted`，:21-22 双闸——R_alarm 同样跨局残留，一并复位）；注释注明「一局一次」语义以局为界（原注释「一局一次」实为进程一次的失实一并更正）。②game_loop.gd 在 start_run（:791）与 continue_run（:1717）两条进局路径调用（pipeline 成员实码定位——_boot_build_actors :1336 建立的单例）；restart_run 经 start_run 天然覆盖。
- acceptance: r198_flow_weapon 断言：首局触发告警广播 → reset → 次局同条件再触发仍广播（告警计数两局各 +1）；未 reset 对照组仅首局广播。pkg2 全绿（告警线契约不放宽）。

**r194-1 空波计数单源化**
- files: scripts/entities/wave/wave_director.gd, tests/runner/export_data_cases.gd
- how: 保留 tick 守卫侧 :148 每波一次计数（`_empty_comp_counted` 旗，:104 重臂）；:250 回退分支改独立计数器 `DebugStats.count(&"wave_composition_registry_empty")`（DebugStats.count 直创计数器，无预声明面——已复核），push_warning 保留；:151 诊断文案不变（其指 tick 守卫侧）。**export_data_cases.gd:197-199 T3①b 改写（注明 R198 契约变更）**：该场景走 :250 回退分支（空注册表）——断言 `wave_composition_registry_empty` ≥1 且 `wave_empty_composition` 计数不变（单源证）；改前全仓 grep `wave_empty_composition` 副本（本轮 grep 仅 wave_director + export_data_cases 两处）。
- acceptance: r194_mobile 全绿；空数据波单波计数恰 +1（不再 2/波）；合法表空 composition 场景走 tick 守卫侧仍计 wave_empty_composition 一次。

**P2-escort 护航舰吃副本 game_delta**
- files: scripts/entities/player/player.gd
- how: SummonDrone（:1315-1354）：`_process(p_delta)` 改名 `tick(p_game_delta)`（引擎不再自驱——非虚方法名即退出 _process 回调），_life_left/_fire_left/position.lerp 全吃 p_game_delta；浮动相位 `Time.get_ticks_msec()` 改自累加 `_anim_t += p_game_delta`（脱离墙上时钟，顿帧/暂停期同步冻结）。player.tick（:201）末尾追加 `for drone in _summon_drones: if is_instance_valid(drone): drone.tick(p_game_delta)`（**类型化判空先于 is_instance_valid 纪律照 **`_summon_drones: Array[Node2D]`** 现状**）。到期回收/预警闪烁语义逐值保持。
- acceptance: r198_flow_weapon 断言：驱动 player.tick(dt)（不经引擎帧）→ _life_left 递减、开火节拍推进、到期回收；时间缩放/暂停冻结下僚机与主循环同步（不独走）。gatling_orbit/weapon_orbit 抽跑绿。

**r195-1 激光副束序数加成归零**
- files: scripts/combat/weapon/laser_beam.gd, tests/runner/r195_laser_pierce_cases.gd, tests/runner/buff_audit_cases.gd
- how: 口径 1：:501 改主束门控 `ctx.pierce_index = (p_ordinal + 1) if (depth == 0 and not sub_beam and not overlap_fallback) else 1`——谓词与 _hit_budget（:392-399）逐字同源；:497-500 注释补一段「R198 口径：序数加成仅主束——副束/折射束/重叠回退束永不贯穿（恒预算 1），白吃 SYN_PIERCE_EVO 首跳 ×1.2 系序数口径缺口，贡献归零」。断言锁死：r198_flow_weapon 新增「副束（sub_beam）首目标 ctx.pierce_index==1 → SYN_PIERCE_EVO 贡献==0」；复跑 r195_laser_pierce **S4 主束断言必须原样绿（不改）**；buff_audit_cases 全量 grep `pierce_index`/`SYN_PIERCE` 数值断言副本，若有副束加成断言按 R198 契约变更改写并注明。弹体路径（projectile_base.gd:481）不动。
- acceptance: r195_laser_pierce 55/55 全绿（主束断言零改动）、w4_prism/w5_mirror 全绿（棱镜副束/折射束回归）、buff_audit 全绿；新断言副束贡献==0。

### 组3 HUD（toast 活宽/暂停钮让位/构筑面板三连）

**r195-3 四处 toast 活宽锚**
- files: scripts/ui/hud.gd
- how: 四处临时 toast（镜面 :560-561、质变 :583-584、刷新次数 :603-604、成就合批 :662-663——盘点行号，实码以「position=Vector2(150,300)/(90,360)」内容锚定）按 :1502-1507 活宽范式改：删固定 position.x，改 `anchor_left=0/anchor_right=1、offset_left=0/offset_right=0`（父域满宽拉伸），y 保持设计位（300/360），文本已 HORIZONTAL_ALIGNMENT_CENTER 照抄波次 toast 口径；size.x 固定值删除（拉伸锚下由父域决定）。720×1280 逐位不变。
- acceptance: r198_hud_layout 断言：四 toast 挂载后 offset_left==0 ∧ anchor_right==1 ∧ 水平居中；720 域 x 覆盖与旧值等价。r195_layout/r195_adapt 只跑不红（无该四区几何断言，盘点已 grep 证实）。

**r194-2 暂停钮上移 6px 脱金币 pill**
- files: scripts/ui/hud.gd
- how: 口径 5：微调暂停钮 y（触控目标 72×72 不回退）——:1342 position.y 26→20、:1350 offset_top 26→20、:1351 offset_bottom 98→92（:1344-1345 锚注释区段的「y26..98」表述同步）；底缘 y=92 恰接金币 pill（:1223 y92..128）顶沿零重叠。AUTO 胶囊 y126..190 与波次徽章（x598..）不在影响域（盘点已核）。
- acceptance: r198_hud_layout 断言：_pause_btn 底缘 ≤ 金币 pill 顶缘（92 ≤ 92）、尺寸仍 72×72（R195 R7 触控目标律）；复跑 r195_layout/r195_adapt R1/R7 与 (_wave_label,_pause_btn) 配对断言全绿、r194_mobile 全绿。

**r197-1 宝石溢出 +N 提示**
- files: scripts/ui/hud.gd
- how: :960-976 截断循环后追加：`gems.size() > 7` 时补 Label（节点名 "GemOverflow" 非 Gem* 前缀——**不破坏 r197 套件 B③「Gem0..Gem6 恰 7 枚」节点契约**），`label_sticker(Label.new(), 10, PopPalette.INK_SOFT)`，text "+%d" % (gems.size()-7)，position (74, 214)，size (40,12)（214+12=226 ≤ content 高 228）。
- acceptance: r198_hud_layout 断言：8 词条 → GemOverflow.text=="+1"、第 8 枚无 Gem7 节点；r197_build_panel 全套复跑绿（B③/A⑤ 零改动）。

**r197-2 宝石层数/Lv 字号 +1**
- files: scripts/ui/hud.gd
- how: :972 ×层数贴纸 label_sticker 字号 9→10；:913 武器 Lv 字号 10→11。承载宽复核（同组 r197-3 若取 cnt 宽 24→20 需联调：「×10」@10pt 需实测 ≥22px，超则本条与 r197-3 一并在实码定夺宽度，两个 WorkItem 同组联调）。不引入按窗宽缩放补偿（超范围，登记原文口径=桌面窗可读性微调）。
- acceptance: r198_hud_layout 断言：cnt/lv 字号 override 为 10/11；r197_build_panel A⑤/C④（只断 x 位）全绿；540×960 截目测项登记真机清单（归组5 销账行转用户侧观察项）。

**r197-3 ×N 贴纸右沿收敛**
- files: scripts/ui/hud.gd, tests/runner/r197_build_panel_cases.gd
- how: 取方案一（cnt 宽收敛，A⑤ x=100 断言不动）：:974 `cnt.size = Vector2(20.0, 12.0)` 且文本右对齐（horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT）——右沿恰 120 == content 宽（hud.gd:866）；「×10」@10pt 实测超 20px 时与 r197-2 联调放宽到 22（仍在 120 内：100+22=122>120 不行——则改用方案二 content 宽 120→124（hud.gd:866，面板内 134<140 E 律不动，A⑤ 仍绿），两案均保 A⑤，实码实测后二选一， chosen 案注释注明）。r197_build_panel_cases.gd 如需补「右沿 ≤ content 宽」契约断言，注明 R198 契约变更并 grep 副本。
- acceptance: r197_build_panel 全套绿（A⑤ x=100 原样）；r198_hud_layout 断言 cnt 右沿 ≤ content 右沿。

### 组4 菜单成长（文案过期/图标/角标/溢出/自洽锁/居中/图鉴行）

**二aw-4 养成面板复活文案更新**
- files: scripts/meta/meta_manager.gd
- how: :206 revive desc「每局可复活 1 次/级（满血复活 + 2s 无敌）」→「…（满血复活 + 3s 无敌）」（REVIVE_INVULN_S=3.0 为真值，player.gd:104）；grep 全仓「2s 无敌」副本确保无第二处。
- acceptance: 全仓 grep 无「2s 无敌」；r198_menu_meta 断言养成项表内 revive desc 含 "3s"；mech_gate/r196_growth 抽跑绿。

**二aw-5 fission/echo 专属技能图标**
- files: scripts/ui/texture_factory.gd
- how: skill_icon()（:1395-1492）match 增两 case（程序贴纸口径与既有 case 一致：_poly_sd/_ring_at/_circle_at/_box_at，64px 画布，缓存键既有 "skill_icon_%s"）：`"echo"`=双生回响（双菱镜/镜像双星——两枚相对小菱形 + 中间连线，色 PLAYER×SHOCK 混合）；`"fission"`=初始武装自定义（中央星 + 两侧槽位短杠或扳手形，色 PLAYER×GOLD）。`_:` 默认分支保留（防未来新角色裸奔）。fission 无技能（no_skill 契约），其图标仅消费于选人卡 skill_ico（menu_screen.gd:1274 统一走此函数），HUD 技能键对 echo 自动生效。
- acceptance: r198_menu_meta 断言：skill_icon 对 10 角色 id 两两互异（Image 取像素采样哈希比较）+ fission/echo 非默认星（与 `_: `_star_pts(16.0,7.0) 产物不等）；r196_growth（echo 池/图标审计）全绿。

**二aw-6 echo 解锁角标 + toast**
- files: scripts/meta/meta_manager.gd, scripts/ui/menu_screen.gd
- how: ①meta_manager 增 `signal echo_unlocked()`；在结算落 map_records 的写点（fissioner_unlocked.emit :780 同区——普通通关兑现处）做边沿检测：本局困难/地狱通关落档前 `hard_cleared()==false`（:575）且落档后为 true → `echo_unlocked.emit()`（恰发一次，同 :780 注释口径；每日分流语义与 fission 对齐——难度分档记录照实兑现）。②menu_screen（:72 连接处）增 `Meta.echo_unlocked.connect(_on_fissioner_unlocked)`（复用同处理器置 :54 `_char_new_badge`+toast——角标语义「角色 ·新」对两新角色统一）；打开选人面板清除逻辑（:572）不变。
- acceptance: r198_menu_meta 断言：硬通关结算前无档 → echo_unlocked 发射且 badge 置位；已困难通关存档重复结算不重发（边沿一次）；fission 旧行为不回退（mech_gate 抽跑绿）。

**二aw-7 fission 锁定句溢出收敛**
- files: scripts/ui/menu_screen.gd
- how: ①:1292-1296 fission unlock_hint 压缩到 20pt 单行 406px 内：「　通关普通难度解锁（首关需 %d 波）」（≈19 全角 ≈380px；删「任一地图常规局 · 当前最佳 %d 波」段——当前最佳波次已由记录/成就面可见，注释注明取舍）。②name_l（:1310-1312）补 `autowrap_mode = TextServer.AUTOWRAP_WORD_SMART` 兜底（高度 28 不变，防未来文案漂移裁字；theme.gd label_sticker 默认不加 autowrap——调用点显式设，避免全站涟漪）。③echo 分支 hint（:1298）较短不动。
- acceptance: r198_menu_meta 断言：fission 行 name_l.text 以「通关普通难度解锁」开头且估宽 ≤406px（按 20pt×全角数断言）；autowrap_mode 已设；r195_layout/r195_adapt 只跑绿、r196_growth 全绿。

**R191-low1 boss_slain 档自洽锁**
- files: scripts/meta/meta_manager.gd, tests/runner/r191_rework_cases.gd
- how: 口径 11：复核 :66-67 targets [3,5,8]/rewards [0,0,60]/desc「单局击败 %d 个 Boss」与 _run_boss_slain 链（:185 声明/:683 递增/:813 每局重置/:854 成就读取/:913 结算导出）——本轮已证实自洽；在 r191_rework_cases（F 区成就段）补契约断言（注明 R198 契约变更新增）：boss_slain 档 desc 含「单局」、targets==[3,5,8]、_run_boss_slain 在局重置后归零、跨局不累加。**仅复核发现失洽才动数值（包络内改排）**，销账归组5。
- acceptance: r191_rework 全绿（新断言 + 既有 127 项零回退）；F17 run_reactions 族不回退。

**P2-skillcopy 诺亚技能描述补伴随火力**
- files: scripts/meta/character_table.gd
- how: :70 noah skill_desc 尾补括注：「…10 秒后离场（舰体伴随火力 = 主武器 ATK 的 12%）」——12% 实存（player.gd:1304-1306/:1317/:1356-1364，本轮复核）；文案宽度自检（技能行有换行区）。grep 「skill_desc」断言副本（verify_feedback 遍历全角色断言 cd==120 与 desc 无涉，已核 fission cd 注释先例——desc 断言如有按 R198 契约变更改写）。
- acceptance: 全仓 grep 「12%」与 noah skill_desc 同现；r196_growth/r191_rework 抽跑绿。

**r195-4 大厅滚动列横向居中**
- files: scripts/ui/menu_screen.gd
- how: LobbyScroll（:709-722）横向改居中锚：`anchor_left = anchor_right = 0.5`、`offset_left = -296.0`、`offset_right = 296.0`（父卡 720 设计域宽 648、锚 0.5=324 → 324±296=28..620 **逐位恒等**；宽卡下居中，消除 ~268px 右侧留白）；纵向锚（:715-716/:719-720）与注释区段表述同步。720×1280 零变化；图鉴 4 页签/选关/记录三屏共用此滚动列（_panel_list 单实例）自动受益。
- acceptance: r198_menu_meta 断言：960 宽画布域下滚动列左缘 > 卡左缘+200（居中生效）、720 域 offset 恒等 28..620；r195_layout/r195_adapt 只跑全绿（盘点证实无该滚动区几何断言）。

**R192-low8 图鉴绽放倍率行折行**
- files: scripts/ui/menu_screen.gd
- how: mult_l（:1018-1025）补 `autowrap_mode = TextServer.AUTOWRAP_WORD_SMART` + size 高 18→34（宽 148 不变、右对齐保持；绽放 mult_fmt（game_const.gd:172）三段串折两行；其余反应单段串单行不受影响）。**不动 game_const.gd 文案**（口径 4：文案真源在 GameConst，UI 侧承宽）；与 R191 收口2 desc_l autowrap（:1007）同族。
- acceptance: r198_menu_meta 断言：mult_l.autowrap_mode 已设且 size.y==34；rxn_codex 全绿（图鉴行建/预览断言不放宽；如 rxn_codex 有行高几何断言冲突，按 R198 契约变更改写并注明 + grep 副本）。

### 组5 收尾账面工具（测试账面/登记销账/发布工具链）

**二aw-3 TargetBar 行为断言补齐**
- files: tests/runner/r195_layout_cases.gd, tests/runner/r195_adapt_cases.gd
- how: W8 附着半边 **不实施**（R187 拆除该路径，moot——见 §7 skipped）。TargetBar 半边：在 r195_layout_cases（既有 hud._tb_panel 几何断言 :306 同文件）追加行为断言（注明 R198 契约变更新增），走 hud 公共观测口 displayed_target_uid()（:1517）/displayed_target_text()（:1522）+ 驱动目标切换/掉血/续窗路径：①锁定非 Boss 目标 → uid/text 非空且随切换更新；②目标掉血 → _tb_fill 宽比例变化（:1776 写点）；③目标死亡/超窗 → 显示清空（_tb_root.visible false）。夹具照同文件既有 Stub 手法。
- acceptance: r195_layout 全绿（新增断言 + 既有 510 项零回退）；r195_adapt 只跑绿。

**r195-2 R2 白名单账实对齐**
- files: tests/runner/r195_layout_cases.gd, tests/runner/r195_adapt_cases.gd, docs/design/R195_SCREEN_ADAPT.md
- how: ①R195_SCREEN_ADAPT.md §3.3 白名单表（:318-321 现钉 2 对）补登第 3 对「R187Readout∩HP 条」，注明「超设计增量（R187 引入 R187Readout 后实际需要），R198 补登评审」。②r195_layout_cases.gd :339-342 头注重写为实际白名单 3 对（ReviveBadge∩HP 条、R187Readout∩HP 条、Settings 设置卡沿徽标）——删除不存在的 PauseCard∩PauseGlyph/DetailsCard∩DetailsGlyph/ReportCard∩face 表述（盘点 grep 证实全套件仅 3 处 true 配对）。③r195_adapt_cases.gd :533-541 同构白名单核对，如头注/注释同有漂移一并对齐。
- acceptance: grep 两套件 true 配对集合 == 设计文档 §3.3 登记集合（3 对）；头注无幽灵对；r195_layout/r195_adapt 全绿（零断言改动，纯注释+文档）。

**账面-r196套件命名（含 r196-1）**
- files: FEEDBACK_TRACKER.md
- how: 口径 2/6：不建重复套件，四处改写（行号以内容锚定，本轮复核实锚）——①:395 尾段「…零污染）落 r196_wunlock_cases.gd 统包阶段」→「…零污染）已落 r196_growth_cases.gd ⑥ 节（定案时拟名 r196_wunlock_cases.gd 未按名落建，R198 登记漂移收口）」；②:401 「P1 源码扫描门 + P2 APK 字节探针落 r196_icon_cases.gd 统包阶段」→「P1 源码扫描门已落 r196_growth_cases.gd ⑧ 节；P2 APK 字节探针转 Python 侧 export_artifact_gate.py A12 断言组（拟名 r196_icon_cases.gd 不落建，R198 登记漂移收口）」；③:406 未做清单「r196_wunlock_cases/r196_icon_cases 新套件未建（统包阶段）」追加「（R198 收口裁定：不再按名补建——覆盖实证在 r196_growth_cases.gd ⑥/⑧，P2 归 A12）」；④:427 R197 收口行遗留 backlog ① 标注「（账面已收口：指向 r196_growth_cases.gd ⑥/⑧ + A12）」。R196_GROWTH_FIXES.md 已 grep 证实零套件引用，不改。
- acceptance: 全仓 grep `r196_wunlock_cases|r196_icon_cases` 仅剩带「收口/不落建」注记的表述；无第 5 处新增引用。

**工具-bump（含 r195-7）--bump 快照回滚式提交**
- files: tools/export_apk_versioned.py
- how: 口径 6 + 盘点定案（168 行已通读）：①main() 内 :146 读盘后留存 `orig_text = text`；--bump 分支照旧 :149 写盘（注释标注「导出期临时态」）。②导出+门禁包进 try/finally，`committed = False`：export_with_retry 成功 **且** gate() 全绿才 `committed=True` 并 return 0。③finally 中「--bump 且 not committed」→ `PRESETS.write_text(orig_text, encoding="utf-8")` 回滚 + 打印「版本号已回滚，下次 --bump 重取同号」。口径四点：a) 重试不二跳=失败 run 收尾 presets 归位 N，下次 --bump 仍取 N+1，文件名相同直接覆盖旧产物（.idsig 同名同覆写）；b) finally 语义使 :155 工具链缺失 SystemExit、导出异常/Ctrl+C、门禁红三种失败统一回滚（顺带修掉工具链缺失烧号）；c) Defender 重试环不动（4 次重试共用临时态版本，presets 每 run 写一次/回滚一次，不进重试内层）；d) 可选加固：提交前链全量门禁 `run([sys.executable, REPO/"tools"/"export_artifact_gate.py", out_apk])`（最小版以本脚本 gate() 为准）。docstring :11-12「重试不迭代」升级为回滚保证。presets 读写沿用现行 utf-8。
- acceptance: ①静态：脚本含 orig_text 快照 + finally 回滚分支；②失败演练（不真导出）：以错误工具链路径跑 `--bump` → 脚本失败退出且 repo/export_presets.cfg 内容与跑前逐字节一致、输出含回滚提示；③连续两次失败 run 后 presets 版本号不变（杜绝跳号）。

**工具-a12-emoji（含 r196-2）A12 零 emoji 字节探针**
- files: tools/export_artifact_gate.py, tools/export_apk_versioned.py
- how: 盘点定案（探针已实证：C:/Python314/python.exe 3.14.4 带 compression.zstd；.gdc=「GDSC」+uint32 version=100+uint32 解压尺寸+标准 zstd 帧，99/99 可解；**F0 9F [80-BF]{2}（U+1F000–U+1FFFF 全 emoji 块）绿包 0 命中 0 假阳，可直接硬断言；F0 A0+ 半边在 float32 Variant 载荷有纯二进制假阳（F0 B6 B6 B6 370 命中）**）：①export_artifact_gate.py 模块顶 `import compression.zstd`（ImportError → A12 记 FAIL，对齐 A6「模板缺失=FAIL」硬锚先例 :176-184，禁 WARN 跳过）；check_zip() 的 with zipfile 块（:105 起）追加 A12：遍历 `assets/**/*.gdc` → raw.find(b"\x28\xb5\x2f\xfd") → zstd.decompress → 断言头第 3 个 uint32==len(解压)（完整性）→ 正则 `b"\xf0\x9f[\x80-\xbf]{2}"` 命中数必须 0；注释写明 F0 A0+ 二进制假阳证据（首版只做 F0 9F——已覆盖 💎U+1F48E/🔒U+1F512/🏆U+1F3C6 与 U+1FA70+ 全部历史案发码位段）。②export_apk_versioned.py gate() 按 A8/A10 轻量子集先例（:127-136）镜像：只扫 GATED_GDC_CHAIN 五生成链 .gdc。③副产物收益入注释：P1 源码扫描盲区 tools/gen_music.gd（打包为 assets/tools/gen_music.gdc）由 A12 字节级全量扫描天然补齐。
- acceptance: ①`C:/Python314/python.exe tools/export_artifact_gate.py android_export/out/InfiniteFission_v0.1.4_vc5.apk` → A12 PASS、总门禁 GREEN exit=0（99 文件全量解压+扫描）；②负样：构造含 `F0 9F 9F 98` 字节序列的假 .gdc 打入临时 zip → A12 FAIL exit=1；③F0 A0 探针（无护栏上下文）确认不纳入必红断言（注释留证）。

**销账-回写（收尾位：依赖组1-4 验收绿后执行）**
- files: FEEDBACK_TRACKER.md
- how: 逐行以内容锚定（盘点行号 ±6 漂移，本轮已重锚）：①**done-unlogged 七条销账**：二aw 流程行（:527）11 项 backlog 逐项标注——遗物恢复/慢速武器调参/TargetBar 断言/2s 文案/技能图标/echo 角标/文案溢出→「✅ R198（指向本文 §4 对应 WorkItem）」；orbit_field tick 热点与 refresh_stats 高频刷→「✅ 已在码（R188 档0/R188-perf），R198 销账（二aw-8/9）」并同步在 R188 #4 行（:499）与 R188 收口行（:501）补注两件套落地；MEC_KNOCK required_forms→「✅ 已在码 [0,2,3]（二aw-10 销账）」；W8 attach_mult→「moot：R187 拆除 attach 三件套，数据键全落 melee 段（二aw-11 销账）」。R191 收口行（:482）5 low——改排→「✅ R198 自洽锁」、噪声→「✅ 已清零（探针 0 命中，修复本体 mult_fmt token 格式化器）」、#6→「moot：R196 G1 覆写」。R192 收口行（:468）10 low→「✅ R198（R192-low1~10 逐项）」。R194 流程行（:449）2 low→「✅ R198」。R195 收口行（:437）low ①~⑦→「✅ R198（⑦ 归工具-bump 回滚式）」。R197 行（:426）遗留 ②（+N）③（字号）→「✅ R198」（④ 未入 APK 由 R198 收口 --bump v0.1.5_vc6 一并打包，不用销账）。P2-lockglyph→二aw 前后锁字符项标「moot：🔒 字面量已清零，R196 ui_lock 贴纸替代；真机残余在 R196 收口行真机清单（:427）」。②**todo 行收尾回写**：R191-low1/R192-low1~10/r194-1/2/r195-1~6/r197-1~3/P2-escort/P2-skillcopy/二aw-1~7 各自归属 tracker 行状态列补「✅ R198」。③若某组未验收，该行保留原状并在本条验收记录列「待回写」清单。
- acceptance: 上述 tracker 行逐行核对与实码/本文处置一致；grep 「二aw」流程行无未标注的遗留项；全部销账行含「R198」批次标注。

---

## 5. 验收矩阵（汇总）

| 组 | 命令（全部先落日志再取退出码，禁管道后 `$?`） | 判据 |
|---|---|---|
| 组1 | `E:/Code/Agent/Infinite-Fission/tools/Godot_v4.3-stable_win64_console.exe --headless --path E:/Code/Agent/Infinite-Fission/repo -s tests/runner/test_r198_element_fx.gd`（新） | 「汇总：PASS N / FAIL 0」exit=0 |
| 组1 | 同上换 `-s tests/runner/test_rxn_codex.gd` / `test_r192_element.gd` / `test_elem_smoke.gd` / `test_elem_immune.gd` / `test_fx_quality.gd` | 全绿；r192_element 夹具 delay 已按 R198 契约变更改写 |
| 组2 | `-s tests/runner/test_r198_flow_weapon.gd`（新） | 全绿；含 relics 恢复/慢速武器补偿/告警复位/空波单源/僚机 tick/副束序数=0 六组断言 |
| 组2 | `test_r195_laser_pierce.gd`（55 项原样）、`test_w4_prism.gd`、`test_w5_mirror.gd`、`test_buff_audit.gd`、`test_r194_mobile.gd`、`test_pkg0.gd`、`test_pkg2.gd` | 全绿；r195_laser_pierce 主束断言零改动 |
| 组3 | `-s tests/runner/test_r198_hud_layout.gd`（新） | 全绿；含 toast 活宽/暂停钮 92/`+N`/字号/右沿五组断言 |
| 组3 | `test_r197_build_panel.gd`、`test_r195_layout.gd`、`test_r195_adapt.gd`、`test_r194_mobile.gd`、`test_r196_growth.gd` | 全绿；r197 A⑤/B③ 原样 |
| 组4 | `-s tests/runner/test_r198_menu_meta.gd`（新） | 全绿；含图标互异/echo 角标边沿/文案宽/居中锚/图鉴折行五组断言 |
| 组4 | `test_r191_rework.gd`、`test_rxn_codex.gd`、`test_mech_gate.gd`、`test_r196_growth.gd`、`test_r195_layout.gd`、`test_r195_adapt.gd` | 全绿；r191 F 组既有断言零回退 |
| 组5 | `test_r195_layout.gd`、`test_r195_adapt.gd` | 全绿（二aw-3 新断言含内） |
| 组5 | `C:/Python314/python.exe tools/export_artifact_gate.py android_export/out/InfiniteFission_v0.1.4_vc5.apk` | A12 PASS、门禁 GREEN exit=0（+负样 FAIL 演练） |
| 组5 | `C:/Python314/python.exe tools/export_apk_versioned.py --bump`（错误工具链路径演练，不真导出） | 失败退出且 export_presets.cfg 逐字节还原 |

新套件骨架照 `tests/runner/test_r197_build_panel.gd` + `r197_build_panel_cases.gd` 既有模式（extends SceneTree + `_initialize`/`_run` + cases 文件 `_check`），汇总行打「汇总：PASS N / FAIL N（共 N 项）」口径。

---

## 6. 不做清单（user-side / skipped）

**user-side（只登记不动手）**
- **二az-1**：R190 #1「改造者点选武器没反应」——tracker :489 用户撤回留档行（⬜ 刻意留档非待办）；其关切已被相邻 ✅ 行 R190 #2（GameConst.weapon_note 三处落地）覆盖大半。
- **二ax-7**：R187 #7「存档不放 C 盘」——tracker :514 用户撤回不改（user:// 存档保留，已动存档代码全量还原并回归验证）；撤回即终态。
- **真机/用户观察项承接**：r197-2 字号观感（540×960 桌面窗）、R196 收口行真机清单（图标贴纸位/断触/面板三落位等）继续由用户真机复测，本批不动。

**skipped（核实后确认不做）**
- **二aw-3 之 W8 附着断言半边**：盘点证实附着三件套已被 R187 拆除（orbit_field.gd:21 / orbit_weapon.gd:15 拆除声明），「为已不存在的新路径补断言」不成立——该半边随路径消亡，仅实施 TargetBar 半边（见组5 WorkItem）。
- **r195-7 / r196-1 / r196-2 独立立项**：与工具-bump / 账面-r196套件命名 / 工具-a12-emoji 同一实现（口径 6 归并），不重复建 WorkItem。

---

## 7. 统一纪律（各组必须遵守）

1. **headless 命令**一律：`E:/Code/Agent/Infinite-Fission/tools/Godot_v4.3-stable_win64_console.exe --headless --path E:/Code/Agent/Infinite-Fission/repo -s tests/runner/test_<套件名>.gd`（绝对路径；判 exit code + 「汇总/验收汇总」行；exe 先 ls 验真身）。**游戏桌面实例在运行——功能套件可跑，性能基准类（r188 性能三跑/风暴 bench/P95）禁跑。**
2. **bash 判真伪**先落日志文件再取退出码（管道后 `$?` 是 tail 的）。
3. **改断言必须注明批次（R198 契约变更）**；旧断言全仓 grep 同名副本（历史教训：同一合同断言常有多处副本，R192 收口2、R196 契约同步均踩过）。
4. **池化对象测试**勿 add_child/勿二次 release；SpaceGrid=RefCounted 禁 free；类型化赋值先于 is_instance_valid。
5. **emoji 字面量禁入 UI 字符串**（R196 规约）；文案真源 GameConst；视觉锚一律 TextureFactory 贴纸。
6. **文件所有权**按 §3 清单，零交集；「只跑」套件（r195_layout/r195_adapt 对组3/组4）可运行不可改。
7. 无法满足的验收/互相矛盾的指令 → 升级说明，勿硬凑、勿假绿。
8. 销账回写（组5「销账-回写」）为收尾位：组1-4 全部验收绿后执行；行号一律内容锚定。

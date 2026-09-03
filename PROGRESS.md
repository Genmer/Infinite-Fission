# ⚡ INFINITE FISSION · 开发进度与交接文档（PROGRESS）

> **本文档是跨工具/跨会话交接的唯一入口。新会话/新工具接手后：先读完本文 → 按 §5「下一步行动」顺序执行。**
> 最后更新：2026-09-01 ｜ 更新人：编码 Agent（ZCode 会话：v1.4.0 Meta 二期——图鉴与成就，C1~C5 全部完成）
> 远程仓库：`https://github.com/Genmer/Infinite-Fission.git`（main 分支）

---

## 1. 项目一句话

竖屏高刷（120Hz）Roguelike 弹幕防御游戏，Godot 4.3 / GDScript。核心是**多乘区伤害公式 + 词缀协同（Synergy）系统 + 对象池海量弹幕**。当前交付物 = 可运行的游戏核心系统（M1 战斗闭环 + M2 词缀协同 + M3 卡牌数值的大部分）。

## 2. 当前状态一览（快照）

| 阶段 | 内容 | 状态 |
|---|---|---|
| A 需求/数值/数字（3 路并行） | A1 需求分析 / A2 数值框架 / A3 具体数值表 | ✅ 完成，已融合 |
| B 融合规格书 | 36 项裁定固化为单一事实源 | ✅ `docs/B_spec.md` |
| C 架构设计 | 19 模块/类骨架/Resource schema/九步管线/5 编码包派发边界 | ✅ `docs/C_architecture.md`（~2190 行） |
| D-包0 基座 | EventBus/池×6/SpaceGrid/ModifierStack/10 Resource 类/启动校验 | ✅ 自测 129/129 PASS |
| D-包1 伤害结算管线 | 九步 resolve/反应通道/幂等/审计/固定种子 | ✅ 自测 108/108 PASS |
| D-包2 实体基座 | ProjectileBase 六事件/Enemy/Player/WaveDirector/透传桩 | ✅ 自测 140/140 PASS |
| **D-包3 武器/词缀/元素/内容** | 四形态武器+TraitStack+内置词条+ElementalSystem+全部内容 .tres | ✅ 完成（自测 128/128 + 内容 66 资源 0 剔除） |
| D-包4 GameLoop/GameFeel/UI/卡牌流 | 主循环/打击感/HUD/三选一 | ✅ 完成（自测 98/98；4 笔待确认转集成包） |
| D-集成包 | main.tscn 组装/全链验收/压力 soak | ✅ 完成（pkg5 自测 98/98；扫尾 8 项全落；压力 P95=5.62ms PASS；soak 180s 满载 0 实例化；详见 §5.6） |
| E 审查+测试（并行） | 独立代码审查 + 运行验证（两轮） | ✅ 完成（一轮：1C+3I 修复；二轮：可交付判定，720/720 终验 PASS） |
| F 交付报告 | 汇总判定+关键决策清单 | ✅ 完成（判定 = 可交付；见 §5.8 与 §4 裁定记录） |

**v0.6.0 增量（2026-08-31，T0~T8）：商店（Boss 前夜 w9/w19/w29）/ 金币经济（掉落+磁吸+HUD）/ 武器卡（CardKind.WEAPON）/ 武器门槛词条（required_weapon）/ Boss 弹幕三形态+召唤 / HUD 720×1280 全量重排+波次横幅。数值与裁定真源 = `docs/analysis/A4_v0.6.0_design.md`；自测 = `tests/runner/test_pkg6.gd`（115 项）。提交序：T1 38ad7ef → T4 a18770d → T3 2db7455 → T5 b7984c7 → T2 57b742f → T6 f7d3f8a → T7 cffa4f5 → T8 本笔。**

**v0.7.0 增量（2026-09-01，U1~U15）：芯片系统（ChipData×8 / ChipHandler 3 槽 / 管线 ⑥b 独立乘区段 cap_chip_zone / 商店芯片货架+槽位面板 / Boss 芯片掉落）/ 金币狂欢关（w6/16/26，0.4×血 rush + 掉落覆写 + 波末比例奖励）/ 双 Boss 修复（w10/20/30 composition 清空）/ 召唤独立计数（summon_active_count 闸）/ 附着环 ElementRing + 反应粒子三预设 + 打击感分级 / 反应统计与结算行 / 首件武器保底（weapon_weight_mult ×2）/ 受击红闪 / 文本跳字通道。数值与裁定真源 = `docs/analysis/A6_v0.7.0_design.md`；自测 = `tests/runner/test_pkg7.gd`（172 项；审查后新增槽位门控 2 项 + U11 段武器 id 笔误 W2_smg→W2_gatling 修复后漏计 3 项归位）。提交序：U1 a9573ab → U2 a6377c1 → U3 22465f6 → U12-14 a920214 → U5 cf68ab3 → U4+U7 e74328b → U6 3753072 → U8-10 375dcf9 → U11 f184dac → U15 5dec3f4。**审查后修复批（fix-review）：芯片定价恢复裁定 60/110/180/300（coder 曾擅改卡架同梯度 40/70/120/220——已推翻）；free_slots()=unlocked−equipped 槽位门控真实生效（原为无语义死状态）；heal 预禁用在 maxhp/CHIP_HP 购买后回写；_gold_add_sum 帧缓存试做后回退（帧号失效对同帧 attach 词条路径返回脏数据，pkg6 冻结用例拦截——正确钩子见 §11）；粒子 burst null 守卫恢复；元素环无附着零分配；商店芯片槽满态购买后同步。**

**v0.8.0 增量（2026-08-31，V1~V24）：芯片变体 4 枚（ATK2/ROF2/CRIT2/HP2，chips 8→12）/ 副词条（独立流 seed 4243，条数 {0:50%,1:35%,2:15%}，7 键无放回固定小值，offer 预随所见即所得 + Boss grant roll）/ 套装（主属性同键 ≥2 枚查询时 ×1.10）/ 诅咒运行时（CurseHandler 0~5 层：受伤×(1+0.08n)/掉率+0.15n/max_hp×(1−0.04n)，compute_max_hp 公式唯一真源 + curse_changed 第 22 号信号 + 卡流 cursed 卡同步加层）/ 词条移除与净化（TraitStack peek/detach_last/detach_by_id + is_curse_trait 单源；商店移除 60 金/净化 80 金/深渊契约 +1 层换 120 金，均店限 1）/ 商店 utility 扩容行2 + 三 setter 回写 + dim STOP / 事件系统（WaveDirector w4 起 40% 独立流 seed 777；EventUI 复用 SHOP 态；EventDirector 四事件：血色祭坛/命运赌桌 seed 888/深渊商人/寂静神龛，金币全走 _add_gold 吃 K_gold 文案带「基础值」；排空序冻结 _drain_overlays_after_resume）/ 角色系统（CharacterData×3：信使/重装/学者，registry characters 类目 + 悬空首发武器剔除；MenuScreen 选角卡；start_run 空参读菜单 + 角色感知重排经 _reset_run_state；goto_menu + GameOver 双按钮；xp 三乘子 = 遗物×角色×(1+K_chip)）/ 冲刺（Player try_dash 四门 fail-fast + 0.18s/220px/独立 0.15s 无敌通道 + Shift；HUD DashButton tap 判定 ×2 + 冷却灰显 + 诅咒标签 (612,64) 紫）。数值与裁定真源 = `docs/analysis/A7_v0.8.0_design.md`（含假设清单 R1~R10 与事件面额自拟值表）；自测 = `tests/runner/test_pkg8.gd`（160 项）。提交序：V13 1e76b2b → V14 e2bea0c → V15 c6bdfb5 → V6 105ad9f → V9 fd566d5 → V10/11 2ee5a50 → V1-4 89a9b3e → V17 bdd9a27 → V18/19 98cdc72 → V21/22 2d578ed → V23 ef61d34 → V24 本笔。**

**v0.9.0 增量（2026-09-01，W1~W7）：波次赐福三选一（BlessingHandler seed 999 + BlessingUI 复用 SHOP 态；wave_cleared w>=2 开门，出牌时过滤 slot1 仅 capacity<6 / slot2 仅 capacity<=4 / heal 仅 hp<max_hp；权重表 gold30/heal15/atk25/rof15/attach10/slot1 4/slot2 1 双源镜像 BalanceTables.blessing_weights；金币包 20+3w 基础值 / heal 15%max / atk +4% / rof +3% / attach +5% / 槽位 +1/+2； blessing_granted 第 23 号信号；排空序扩展 升级→赐福→商店→事件；硬上限叠波直调 start_wave 不派发 wave_cleared = 天然无赐福）/ 芯片槽位扩展 3→6（CHIP_SLOT_CAP=6 + bonus_slots 赐福位 + slot_capacity()=mini(unlock+bonus,6)；slot_snapshot 恒 6 格 locked 语义；商店槽位面板 6 槽盒 90x120 + 未解锁灰显）/ stat 三键 Option A（ChipHandler.blessing_stats 在套装 ×1.10 之后加和——只加和不参与 ≥2 判定不被放大，不占 TraitStack 不可 strip，atk 随 ⑥b 段共享 cap_chip_zone）。数值与裁定真源 = `docs/analysis/A8_v0.9.0_design.md`（含 Option A 裁定/时序图/假设清单 H1~H8）；自测 = `tests/runner/test_pkg9.gd`（59 项 G1~G9）。提交序：W1 0578963 → W2 0135114 → W3a f8eaa51 → W3b eb8b4ce → W4 bf2b04e → W6/W7 本笔。授权更新：pkg7（EVENT_NAMES 23 / capacity+bonus 维度 / 快照 6 格 locked / 槽盒 90 宽锚点）、pkg5/pkg6/pkg7_extra（wave_cleared 新订阅夹具排险）、pkg8_extra V24（version/基线推进）。**

**v1.0.0 增量（2026-09-01，M1~M7）：局外成长 Meta + 存档层（MetaStore：结晶货币 + 五条目封闭表 hpg/atk/greed/seed_gold/xp + 累计战绩，ConfigFile `user://meta_save.cfg` SAVE_VERSION=1 + 完整损坏判定树全回退不写回；定价 100 起逐级 ×1.6 round——★非 pow，round(655.36)=655≠冻结 656；序列 100/160/256/410/656 + seed_gold 100/160/256）/ 死亡结转（GameLoop._settle_run 一次闸 _settled_this_run：本局金币全额折结晶 + record_run + save；降级路径 meta_store 缺失 → 结晶 +0）/ 注入四通道（① hpg→CurseHandler.meta_hp_flat 先于 reset 注入；② atk/greed→ChipHandler.meta_stats——★reset_run 不清由 run 开始 set_meta_stats 覆盖，stat_bonus 赐福段后加和同 ⑥b 共享 cap_chip_zone；③ seed_gold 直注入 gold 不经 _add_gold——greed 不放大开局金；④ xp 链第 4 因子 meta_store.xp_mult 与芯片 xp_gain 分立防双算）/ compute_max_hp 增第 5 参 p_meta_flat（默认 0 恒等）/ MetaPanel（MENU 态宿主不占状态机；dim STOP 遮挡开始钮互斥实现；layout_rects 6 项）+ MenuScreen 统计行/入口钮 + GameOver 结晶行。核心红线：全 0 级与 v0.9.0 行为逐位恒等（pkg10 M23 锚定）。数值与裁定真源 = `docs/analysis/A9_v1.0.0_design.md`（含注入四通道契约/假设清单 A9-1~A9-6）；自测 = `tests/runner/test_pkg10.gd`（24 项 M1~M24 恰额）。提交序：M1 b8892b7 → M2-5 348ab4d → M6-7 本笔。授权更新：project.godot version 1.0.0、pkg8_extra V24（version/基线推进）。**

**v1.1.0 增量（2026-09-01，E1~E5）：元素反应二期（数值与裁定真源 = `docs/analysis/A10_v1.1.0_design.md`）。增幅双轨（融化 = ICE 附着+FIR 直击 ×1.5 / 蒸发 = FIR 附着+ICE 直击 ×2.0；amplify 乘区池经弹侧 `_build_damage_ctx` 注入 + 三插点幂等消耗——projectile 主路径/homing 主目标/homing 次级，均「结算成功且未 dead」后置；KIN/光束/近战/settle_aoe/DOT/连锁跳天然排除；穿透链各目标独立；融→蒸同帧连段合法）/ 元素精通（ELE_MASTERY.tres：step 0.25、stack_max 3、hooks 常驻；register_mastery 跨武器注册 + mastery_layers 全局封顶 3 唯一裁定点；reaction_mult 改写 = ∏VOID × (1+step×层)，仅 VOID 恒等 1.8 零冲击；HUD Build 串增 MP）/ 反应 CD 分立（reaction_table 三 rule 携带 cd 2/3/6 双源镜像，缺键回退 cd_rxn；validator cd≤0 告警；pkg3 超导 CD 断言授权更新 2s→6s）/ 顺手项（超导拼写 superconduct、碎裂昵称清理「碎裂≠融化」、damage_pipeline.gd 注释现状化——唯一授权管线 diff，pkg11 V30 源码守卫）/ 跳字 ‼ 后缀 + amplify_melt/vapor 遥测分键。三剧变（碎裂/过载/超导）触发条件与结算通道零语义变更。提交序：E1 b23b9e2 → E2 11c5b5d → E3 4185267 → E4 229b4d4 → E5 本笔。授权更新：project.godot version 1.1.0、pkg8_extra V24（version/基线推进）、pkg6_extra T1（注册资源 83→84 / traits 30→31）、pkg3（超导 CD/拼写四处）。**

**仓库当前可编译（0 解析错误），回归全 PASS（pkg0 129 + pkg1 108 + pkg2 140 + pkg3 128 + pkg4 98 + pkg5 118 + pkg6 115，基线口径 836；另有 pkg6_extra 33 项验收补充 / pkg7 175 项 v0.7.0 增量自测（v0.9.0 +3 授权更新）/ pkg7_extra 60 项验收补充（v1.2.0 +3 授权更新）/ pkg8 160 项 v0.8.0 增量自测 / pkg8_extra 31 项验收补充 / pkg9 59 项 v0.9.0 增量自测 / pkg9_extra 34 项验收补充 / pkg10 24 项 v1.0.0 增量自测 / pkg10_extra 9 项验收补充 / pkg11 16 项 v1.1.0 增量自测 / pkg11_extra 7 项验收补充 / pkg12 20 项 v1.2.0 增量自测 / pkg12_extra 8 项验收补充 / pkg13 22 项 v1.3.0 增量自测，不计入 836 基线口径；全 runner 合计 1494（v1.3.0 实测对账：1464 旧口径 + pkg12_extra 8 + pkg13 22）。压力场景（500 弹+100 敌，headless 逻辑帧口径）P95 与 soak 见 §7 v1.3.0 行）。**

**v1.2.0 增量（2026-09-01，W0~W10）：元素三期（数值与裁定真源 = `docs/analysis/A11_v1.2.0_design.md`；damage_pipeline.gd 本版一笔不碰——pkg12 V54 源码守卫小写不含 "shield"）。WAT 基建（Element 尾追 WAT=4 旧序零变；gauges/resist/λ 三处 5 位镜像 λ_WAT=0.38；8 敌 .tres resist 手改 5 位；ELEMENT_COLORS/ElementRing 4 扇区）/ ELE_TIDE 潮汐弹药（WAT 附着 22，层 2 ×1.5=33，traits 32）/ 三剧变（冻结 RXN_WAT_ICE：全停 2.5s + 破碎 3 直击 40%ATK 帧末结算 + immune 拦截零广播，CD 5s；导电 RXN_WAT_LTG：主 90%×φ + BFS 3 跳衰减 0.6 × _uid_conduct 分流，CD 4s；汽爆 RXN_WAT_FIR：主 60% + 半径 80 扩散，CD 3s；优先级 碎裂>过载>超导>冻结>导电>汽爆）/ 增幅升格三轨（BalanceTables amp_melt/vapor/quench 三因子 + _amp_factor 缺键回退；FIR 直击双查 ICE 优先 melt → elif WAT quench ×1.5；amplify_quench 分键；pkg11 恒等 16/0）/ 元素盾（EnemyData.shield + validator 双键域校验；E6_boss2 雷盾 0.30 / E6_boss3 水盾 0.30 / E5_elite 冰盾 0.25；SHIELD_COUNTER 克环 FIR↔ICE WAT↔LTG ×2.0；take_result 拦截层——REACTION 不判克制/无溢出穿透/不扣血不闪白；召唤 strip_shield；ShieldRing 程序化盾环 + 破盾 flash 余韵）/ 表现六反（REACTION_SCENE_IDS/PRESETS 三新键 + RXN_FEEL_SCALE 三档 0.9/0.7/0.75 + HUD 六槽 clamp(0,5) + 结算屏六名）。提交序：W0 d55607c → W1 1c84ec5 → W2 7610df7 → W3a 1b64923 → W3b c0913df → W4 74cc3d0 → W5/W6 30bcb20 → W7 742955e → W8 97c7930 → W9/W10 本笔。授权更新：pkg7_extra（RING_COLORS 3→4 + 新三映射字面 +3 断言）、pkg6_extra（traits 32/全表 85）、pkg7（REACTION_SCENE_IDS 六键 + scales 六档）、pkg8_extra V24（version/基线推进 1433→1464）、project.godot version 1.2.0。**

**v1.3.0 增量（2026-09-01，R1~R6）：元素收尾与打磨（数值与裁定真源 = `docs/analysis/A12_v1.3.0_design.md`，含假设清单 H1~H3；damage_pipeline.gd 本版一笔不碰——pkg13 V78 源码守卫小写不含 "resonance" 且不含 "crystal"）。R1 元素共鸣+全量重算收口（≥2 把同元素附着 ×1.25 / ≥3 把反应 ×1.15；单源扫描器 weapon_element_counts 每武器恰计 1 元素 tie 后挂胜；rebuild_registries 三表清空重建统一收口 attach_trait/装机/strip/重开四处，register_* 直调通道原样保留；消费点三处——apply_attach chip 后追加、四伤害臂+破碎 (WAT,ICE) 双元素连乘、_amplify_snapshot 三返回 ×命中元素共鸣；HUD Build 行尾追「 共鸣:火×2」；★无共鸣 ×1.0 逐位恒等 pkg3/pkg11/pkg12 全绿零数值更新，仅三处 null-player 注册夹具补 stub 宿主）/ R2 元素水晶（w≥8 非 Boss 40% seed1001 独立流 + Crystal 非池化同屏 1 颗五分支击破 FIR-AOE 0.8 / ICE·WAT 半径附着 50 / LTG 雷击连锁 base=当跳伤害？？面板 / KIN 弱 AOE 0.4；弹侧 _check_crystal_hit 不耗穿透继续飞 + last_hit_damage 基数；消散三出口波末/清场/顶替 + GAME_OVER 不清）/ R3 赐福跳过补偿 15 金币基础值（经 _add_gold 吃 K_gold + 跳字 + 文案；六处 skip 夹具审计零更新）/ R4 MetaStore._int_or 类型守卫（INT 直用/FLOAT 整数值 |v|<2^53 收整/脏型单键回退不整档不写回，四处替换）/ R5 pkg13 22 项（V57~V78 恰额）+ version 1.3.0 + A12 留痕。提交序：R1 d6645c6 → R2 f4f76f6 → R3 c2de539 → R4 391d3ae → R5 本笔 → R6 基线对齐。授权更新：pkg8_extra V24（version/基线推进 1464→1494）、pkg12 V56（version 1.2.0→1.3.0 随版本推进）、PROGRESS §2/§7（实测 1494）。**

**阶段 E 关键战果（审查/测试发现并修复）：**
- 一轮审查 1C+3I：重开不清场（残留战场秒杀重生）→ `_clear_battlefield` 清场序 + respawn 1.5s 无敌；GameFeel 订阅晚于 Spawner 清 tags（Boss 击杀打击感永不触发）→ early_bind；Boss 波伴随怪流水锁死 wave_cleared → `_boss_ref` 存活闸；TH_CRIT_SHARD 全武器声明零实现 + 校验器空承诺 → 补 `trait_effect_crit_shard.gd` + check_references ② 落地
- coder 实现中发现的**双落血 bug 族 5 处**（settle_aoe/投射物直击/激光/环绕/弧斩：真件管线 9b 内部落血 + 调用方再落血 = 实际游戏全部伤害 ×2）→ 全部改双轨口径（`is DamagePipeline` 真件不落血/桩落血），pkg2/3 桩口径用例原样全绿验证；连带修 laser_beam._recycle 归还恒短路池泄漏
- pkg5 偶发抖动（randomize 漂移卡牌流）→ card_generator rng 定种子 42 + 遗物用例幂等化

**v1.4.0 增量（2026-09-01，C1~C5）：Meta 二期·图鉴与成就（数值与裁定真源 = `docs/analysis/A13_v1.4.0_design.md`，含假设清单 H1~H4；★零新 EventBus 信号/MenuScreen 零改动/管线弹幕零触碰）。C1 MetaStore 扩展（图鉴三册存档段 [seen] chips/relics/reactions + [achievements] 节，save_version=1 双向兼容旧档缺节静默空/脏键逐键过滤；REACTIONS 13 键封闭表（剧变6→增幅3→共鸣4）+ ACHIEVEMENTS 10 条封闭表 + RESONANCE_SEEN_KEYS 映射；mark_chip/relic/reaction_seen 首见即存 + unlock_achievement 幂等 + static convert_gold 结算软上限 ≤500 全额/超出 ×0.5）/ C2 追踪接线（AchievementTracker 判定器——本地信号 achievement_unlocked 非总线；Boss 三档四层守卫精确匹配 E6_boss1/2/3、波次三档 ≥10/20/30、芯片 max_main_count≥2/满配≥6、武器有效槽≥5、累计击杀≥1000 五站点；chip/relic/elemental 图鉴收录——★反应收录在 _trigger_reaction 入口位含 Boss 免疫早退、增幅三分支、共鸣+武器槽 rebuild_registries 函数尾（早退不含）；GameLoop boot 铁律 6：tracker setup 订阅先于掉落侧与 spawner）/ C3 结算改造（_settle_run 结晶入账改 convert_gold 软上限 + on_run_settled ★先于取清单 + GameOverScreen 新成就行 y660「新成就：A · B」+ 成就解锁跳字「成就达成：×××」玩家上方 -64 + reset_run 随局清清单）/ C4 MetaPanel tab 化（0 强化/1 图鉴/2 成就三 tab + 图鉴三册芯片12格/遗物11格 String 升序/反应13行表序（数值段 balance 闸统一——未就绪不附无数值无字面量兜底）+ 成就10行 + 清档两击流「清除存档」→「确认清除？」→ wipe_requested 仲裁 + layout_rects 新口径 tab0=10/芯片册=19/遗物册=18/反应册=20/成就页=14 隐藏页不入列）/ C5 收尾（pkg14 24 项 C1~C24 恰额 + version 1.4.0 + 本档对账 + A13 留痕）。提交序：C1 ffae1c6 → C2 3e7298a → C3 01a2525 → C4 b2887ba → C5 本笔。授权更新：pkg10 M22（layout_rects 6→10 tab0 口径留痕）、pkg10_extra E7（存档恰 3 节→4 节+[seen] 三键，无解锁不建 [achievements]）、pkg8_extra V24/pkg12 V56/pkg13 V78（version 随版本推进 1.3.0→1.4.0）、project.godot version 1.4.0。**

**v1.5.0 增量（2026-09-02/03，K1~K9）：TTK 复校与平衡回收（数值与工装真源 = `docs/analysis/A14_v1.5.0_design.md`；tests/sim/ 七件仿真工装——真件管线只读复用+直击时序复刻+P20 五文件源码守卫；对齐门 61 锚逐位 ==；360 行跑批+五点判定：p1/p2/p5 DRIFT 仅记录、p3/p4 RED 归因锚口径错配（静态构筑 vs 成长假设；V_max 1.5 旧锚）——★本版零调参，提案 PR-1~3 待用户拍板；Boss 映射/p5 复合锚两处工装复核修正（w10 误用 boss2 的 112s 伪影→修正后 36s 贴合 32s 设计锚）；K7 结算双写盘去重（加法式 p_defer_save）；pkg15 20 项（12 格帧基线冻结+自检翻红）；damage_pipeline 等五文件零改动）。**

## 3. 开发流水线（自创，非标准流水线）

```
阶段A（3 路并发：需求/数值框架/具体数字） → 自查 →
阶段B（主控融合成 B_spec 单一事实源） →
阶段C（架构师子代理 → C_architecture.md） → 主控自查 →
阶段D（编码，包间按依赖分波）：
    波1: 包0 基座（串行先行）
    波2: 包1 ∥ 包2（并行）
    波3: 包3（依赖 0/1/2）
    波4: 包4（依赖 0/2）—— 理论上可与包3 并行
    波5: 集成包（依赖全部）
阶段E（审查 ∥ 测试 并行把关） → 阶段F（汇总交付）
```
每阶段强制自查；子代理只写自己包的文件，跨包契约全部冻结在 C_architecture.md。

## 4. 包 3 当前态（代码+自测已完成，剩内容资源）

**磁盘上已有的包 3 文件（全部编译通过 + 128 项自测全绿）：**
- `scripts/combat/weapon/`：weapon_base.gd、ballistic_weapon.gd、homing_weapon.gd、laser_weapon.gd、laser_beam.gd、melee/{orbit_weapon.gd, orbit_field.gd, arc_slash.gd}
- `scripts/combat/trait/`：trait_base.gd、trait_context.gd、trait_stack.gd、synergy_rules.gd、builtin/（trait_effect.gd + stat/size/fractal/bounce/elemental/mech 六类内置词条）
- `scripts/combat/elemental/`：elemental_system.gd、elemental_state.gd
- `scenes/combat/lasers/laser_beam.tscn`
- `tests/runner/test_pkg3.gd` + `pkg3_cases.gd`（128 项断言，覆盖 §4 原 10 个测试要点全绿）
- `resources/`：weapons×9（含 5 级 upgrade_table + 四通用质变阈值）、traits×28（ADD12/MULT6/MECH6/ELEM4）、relics×11、enemies×8（E1~E5+三 Boss）、waves/wave_table_main（30 波）、synergies×8 —— **DataRegistry 加载 66 资源、rejected=0**

**内容侧已裁决的口径（docs 矛盾按 C_architecture > B_spec > A3 链裁定，2026-08-28）：**
- W5 L5 refract_depth=3 → 取 2（引擎 MAX_REFRACT_DEPTH=2 + 校验器双硬闸，.tres note 留痕）
- 精英 HP 取波表口径（单一 E5 模板 = grunt 基底 ×4.2；A3 §2.2 与 §2.4 矛盾时从波表），精英类型差异延后
- ADD 词条 decay_delta=0.85（架构示例值；A3 §9.1「3 层=+45%」线性假设在 F-21 衰减框架 δ≤0.92 下不可达）
- HOMING/MELEE 等级表 rof 列 A3 未给 → 填 1/cd 等效值；W4/W5/W8 的 cd 填 1.0 轮询占位（仅影响轮询节拍）
- **转包 4 的新遗留**：爆虫自爆机制（半径 110/1.2s 引爆/警示圈，EnemyData schema 无字段）；Boss 波伴随怪差异（A3：w20 伴 R、w30 混合怪×1/2s 场上≤14；现 WaveDirector 硬编码最便宜敌 ×1/2.5s ≤12）

**本次会话（ZCode）修复的 4 个业务 bug（tester 发现 → coder 修复 → 测试翻转全绿）：**
1. `elemental_state.gd`：gauges 3 槽越界（元素枚举 KIN=0/FIR=1/ICE=2/LTG=3，LTG 恒 Out of bounds）→ **改 4 槽按枚举直索引**（KIN 槽弃用），tick 衰减 λ 取 `lambdas[i-1]`（λ 真源恰 3 项 [FIR,ICE,LTG]）
2. 投射物路径 `TraitContext.weapon` 恒 null（TH_SIZE_NOVA/MEC 系效果引擎侧不可达）→ **spawn 契约增量可选键 `weapon_ref`**（见 §8.1 附注），projectile 缓存 + 分裂继承 + 池化复位清零 + 效果侧 is_instance_valid 守卫；连带 `settle_aoe` 增加可选主目标排除参数（冲击波不重复结算直击目标）
3. 激光折射链第二环断裂（父束命中集误传成子束排除集，子束首触即短路）→ `_on_beam_refracted` 改传「追加当前目标前」的命中集快照，depth 2 可达，MAX=2 硬闸不变
4. `orbit_weapon.gd` `_ensure_orbit_field` 漏注入 `orbit_field.weapon = self` → 周期弧斩从死代码变可用
- 次生修复：`elemental_system._spread_reaction` 补窄相收窄（粗筛在网格、窄相在调用方口径）

**包 3 遗留（全部已在集成包落地，2026-08-29）：**
1. ~~包 3 收紧位~~ ✅ 两批全完成：第一批（enemy.elemental 直调、validator effect_id 剔除、Player.add_weapon 工厂）；第二批 6 处（三池 acquire() 收窄返回值、weapon_slots→Array[WeaponBase]、equip_weapon(WeaponBase)、tick 直调、DamageContext.target→Enemy）——锁定用例已迁移为真实实体夹具，断言数不变（129/140/108）
2. ~~遗留小项~~ ✅ 全部落地：R_rxn 独立告警线、易伤注入去重（has_mult_pool 守卫）、is_first_hit_of_wave、敌间分离力 E-10（SpaceGrid 邻域）、RANGED 敌弹池注入、xp 经验链路、遗物运行时处理器（relic_handler）

## 5. 下一步行动（按序执行）

1. ~~跑基线确认 377 PASS~~ ✅（本会话已做，见 §7 现基线 505）
2. ~~补包 3 自测 test_pkg3.gd~~ ✅（128/128 全 PASS，顺带修复 4 个业务 bug，见 §4）
3. ~~补包 3 内容 .tres~~ ✅（66 资源 0 剔除；pkg0 两条占位断言翻转为正向断言；裁决记录见 §4） ← **已过，当前断点在 4**
4. ~~收紧 duck-typing 恢复点~~ ✅ 第一批完成（第二批 6 处转包 4/集成期，清单见 §4）
5. ~~派发包 4~~ ✅（GameLoop/GameFeel/HUD/卡牌流/爆虫/Boss 伴随怪；自测 98/98；提交 3c43634，push 待网络恢复重试）
6. ~~集成包~~ ✅（2026-08-29，两段接力：前任智能体完成 A/B/D 后跑 soak 超时被中断，续作智能体盘点补缺。main.tscn 全链可跑；扫尾 8 项全落；压力 P95=5.62ms<8.3ms + soak 180s 满载 0 实例化；pkg5 98/98。**续作额外修 3 bug**：game_feel_director.on_player_hit 双参信号签名、enemy._reset_state 归还置 dead=true（防二次死亡广播）、GameLoop spawner/wave_director 入树序（F-19 Boss 击杀解锁失效））
7. ~~阶段 E~~ ✅ 两轮：一轮（reviewer 1C+3I ∥ tester 全量复现通过）→ coder 修复（1f7d3db/ff9240d，含双落血族 5 处 + 2 项追加裁定）→ 二轮（reviewer 判可交付 ∥ tester 720/720 终验 + 专项 24/24）
8. ~~阶段 F~~ ✅ 交付判定：**可交付**。关键决策清单 = §4 全部裁定条目 + §2 阶段 E 战果 + §8.1 weapon_ref 增量契约；后续改进清单见 §11
9. 每完成一个包：**git commit + push**（纪律！全程遵守，HEAD = ff9240d 已推）

## 11. 后续改进清单（不阻塞交付，下轮迭代）

1. **release 模板真跑复测**：压力/soak 均为 headless debug 逻辑帧代理口径，M1 交付前用 release 模板真跑一次（架构允许，进 CI）
2. **soak 10 分钟版**：脚本就绪（SOAK_FRAMES 常量），10 分钟口径跑一次（~12 分钟实际，须后台+轮询）
3. particle_pool.gd:43 `is_connected` 未绑 Callable 检查恒 false → 复用重复 connect 靠池守卫兜底刷 push_error，统一为 bound callable 检查
4. game_feel_director.gd:79 `p_enemy.get("tags")` 直接 `int()`，探针/异常实体喂 null 报 SCRIPT ERROR（生产路径无影响），加类型守卫
5. pkg2/pkg5 退出泄漏三元组（ObjectDB leaked WARNING + resources in use）为测试入口基建既有现象，核对一次测试退出释放
6. W5 L5 refract_depth=3（A3）与引擎 MAX=2 双硬闸矛盾、爆虫自爆 EnemyData schema 字段化、精英敌类型差异（速度/行为）、Boss 波伴随怪构成差异全量表达——均已按裁定从波表/常量口径实现，正式美术/数值迭代时统一回收
7. PopupPool/LaserBeamPool acquire() 返回值仍是 Node2D（第二批收紧未授权的两处）
8. **w10 双 Boss 既有 bug**：波表 w10 composition 含无 TAG_BOSS 的 E6_boss1 + `_spawn_boss` 再入队带标 Boss = 每轮实刷两只（一只无 Boss 逻辑）；pkg2 冻结用例依赖现行为，修复需同步授权改 pkg2 断言（v0.6.0 coder 发现，A5-D1）
9. Boss3 召唤被伴随流水压制：BOSS_SUMMON_ACTIVE_CAP=12 用 spawner 总活跃数，w30+ 伴随 cap=14 时 Boss3 召唤几乎不触发——改召唤单位独立计数（A5-E1，reviewer Q1）
10. `_gold_add_sum` 每击杀对每武器重建 aggregate_panel 字典——击杀潮分配频率上升，按帧缓存（A5-E2，当前规模无实测压力）
11. ShopUI heal 满血不禁用（点击后才被仲裁拒绝）；卡面 kind 中文名在 card_select_ui/shop_ui 两处重复维护（A5-E3/E4）
12. v0.6.0 defer 项：Boss3 charge/laser_sweep 未消费（laser 依赖 §11.7 收紧+新预警通道，A5-D2/D3）；金币经济数值不干预待试玩回收（A4 §8 假设清单）
13. **玩法迭代池与元素反应长期课题**：`docs/analysis/A5_v0.6.x_exploration.md`（开局武器三选一/首件武器保底✅v0.7.0/冲刺/金币关✅v0.7.0/利息/武器专属词条扩容/元素反应三期路线：表现✅v0.7.0→双轨数值→第 4 元素+破盾）
14. **_gold_add_sum 聚合缓存（v0.7.0 试做回退）**：帧号失效口径对"同帧 attach 词条后击杀"返回脏数据；正确失效钩子 = EventBus.card_chosen / TraitStack attach 信号（覆盖直挂与卡流两路），待实测压力出现（当前 P95 5.5~6.2ms 远离 8.3ms 线）再做

## 6. 关键文档地图（全部在工作区 docs/）

| 文档 | 作用 |
|---|---|
| `docs/00_user_requirement.md` | 用户原始需求（最终依据，一切冲突以它为准） |
| `docs/B_spec.md` | **单一事实源**：36 项融合裁定 + 全局常量 + 伤害管线契约 + 里程碑验收 |
| `docs/C_architecture.md` | **架构真源**：19 模块依赖图、类骨架签名、8 类 Resource schema、九步管线映射、性能预案、失败路径、5 编码包派发边界（§七） |
| `docs/analysis/A1_requirements.md` | 需求分析：M-01~M-19 模块清单、60+ 条可执行验收 AC、边界风险 E-01~E-17 |
| `docs/analysis/A2_numeric_framework.md` | 数值框架：公式 F1~F29、五层防崩护栏 |
| `docs/analysis/A3_numbers.md` | **数字真源**：9 武器/28 词条/11 遗物/敌表/波表/掉卡规则 |
| `docs/briefs/` | 各子代理派发单（过程档案） |

## 7. 环境与测试命令

- **Godot 二进制**：`/Users/genmer/Documents/Codes/Tools/godot/Godot.app/Contents/MacOS/Godot`（4.3-stable universal，已装好）
- 导入：`"$G" --headless --path "<项目根>" --import`
- 跑测试：`"$G" --headless --path "<项目根>" -s tests/runner/test_pkg0.gd`（pkg1/pkg2/pkg3 同理）
- 注意：`-s` 模式下入口脚本编译早于 autoload 注册，测试用「入口引导 + 运行时 load 用例体」两段式（pkg0~pkg3 都是这个模式，新测试照抄）
- 当前基线：**pkg0 129 / pkg1 108 / pkg2 140 / pkg3 128 / pkg4 98 / pkg5 118 / pkg6 115，全 PASS（共 836 基线口径；另有 pkg6_extra 33 / pkg7 175 / pkg7_extra 60 / pkg8 160 / pkg8_extra 31 / pkg9 59 / pkg9_extra 34 / pkg10 24 / pkg10_extra 9 / pkg11 16 / pkg11_extra 7 / pkg12 20 / pkg12_extra 8 / pkg13 22 / pkg13_extra 13 / pkg14 24 / pkg15 20，独立 runner；v1.5.0 实测对账全 runner 合计 1551（1531 + pkg15 20）全 PASS）**
- v0.6.0 压力复测：**P95 = 5.559ms**（avg 2.191 / P50 1.791 / P99 6.968，判定线 8.3ms PASS）
- v0.7.0 压力复测：**P95 = 5.714ms**（avg 2.302 / P50 1.912 / P99 6.515，判定线 8.3ms PASS；六池 0 运行期实例化 / 污染 0）
- v0.8.0 压力复测：**P95 = 5.924ms**（avg 2.419 / P50 1.998 / P99 7.144 / MAX 12.625，判定线 8.3ms PASS；六池 0 运行期实例化 / 污染 0 / 非法归还 0）
- v0.9.0 压力复测：**P95 = 5.764ms**（avg 2.348 / P50 1.953 / P99 6.813 / MAX 11.626，判定线 8.3ms PASS；六池 0 运行期实例化 / 污染 0 / 非法归还 0）
- v1.0.0 压力复测：**P95 = 5.784ms**（avg 2.297 / P50 1.925 / P99 6.514 / MAX 13.190，判定线 8.3ms PASS；六池 0 运行期实例化 / 污染 0 / 非法归还 0）
- v1.1.0 压力复测：**P95 = 5.895ms**（avg 2.461 / P50 2.013 / P99 7.233 / MAX 12.610，判定线 8.3ms PASS；六池 0 运行期实例化 / 污染 0 / 非法归还 0）
- v1.3.0 压力复测：**P95 = 6.127ms**（avg 2.793 / P50 2.340 / P99 7.294 / MAX 13.562，判定线 8.3ms 与参考线 7.3ms 双 PASS；六池 0 运行期实例化 / 污染 0 / 非法归还 0）
- v1.4.0 压力复测：**P95 = 6.635/6.705ms 两轮**（avg 3.117/3.099，判定线 8.3 与参考线 7.3 双 PASS；六池 0 运行期实例化 / 污染 0；soak 180s：RSS +0.95% / 0 实例化 / 终局波 7 / 0 ERROR）——审查 D2 补录（mark 首见即存 ≤46 次/档非稳态成本，抬升归因机器噪声）
- v0.8.0 soak：**180s 满载自动战斗 PASS**（窗口帧均 2.735ms；六池 0 运行期实例化 / 池污染 0 / 非法归还 0；RSS 181.0→182.6 MB 增幅 0.88% < 3%；0 ERROR）
- v0.9.0 soak：**180s 满载自动战斗 PASS**（窗口帧均 2.810ms；六池 0 运行期实例化 / 池污染 0 / 非法归还 0；RSS 181.4→183.0 MB 增幅 0.88% < 3%；0 ERROR；终局波次 7）
- v1.0.0 soak：**180s 满载自动战斗 PASS**（窗口帧均 2.586ms；六池 0 运行期实例化 / 池污染 0 / 非法归还 0；RSS 181.9→183.5 MB 增幅 0.87% < 3%；0 ERROR；终局波次 7）
- v1.1.0 soak：**180s 满载自动战斗 PASS**（窗口帧均 3.000ms；六池 0 运行期实例化 / 池污染 0 / 非法归还 0；RSS 182.2→183.8 MB 增幅 0.86% < 3%；0 ERROR；终局波次 7）
- v1.3.0 soak：**180s 满载自动战斗 PASS**（窗口帧均 3.126ms；六池 0 运行期实例化 / 池污染 0 / 非法归还 0；RSS 184.5→186.1 MB 增幅 0.86% < 3%；0 ERROR；终局波次 7）
- v1.3.0 真机窗口实测清单（表现项，headless 不覆盖，见 A12 §10）：① 水晶紫晶渲染与 z 层级（敌上玩家下）+ 击破消散观感；② 赐福跳字「跳过 · +15 金币（基础值）」与跳过按钮/描述新文案；③ HUD Build 行共鸣后缀（≥2 同元素）；④ w≥8 水晶出现频率体感（40%）与 Boss 波/金币关表现
- 压力/soak：`tests/stress/test_perf_500p100e.gd`（AC-01.2，headless 逻辑帧口径）与 `tests/stress/test_soak.gd`（AC-14.1，SOAK_FRAMES 常量控时长；10 分钟版预计 ~12 分钟实际，长跑须后台+轮询防会话超时）

## 8. 冻结契约速查（跨包接口，改动需全包评估）

1. **spawn(params) 参数字典**（武器→投射物）：基础键 velocity/lifetime/pierce/bounces/hitbox_radius/element/attach_value/generation/weapon_uid/panel_snapshot/trait_stack/team；Homing 追加 8 键（target_uid/turn_rate/speed_init/speed_max/accel/arm_delay/blast_radius/blast_falloff）；完整定义见包 2 交付报告与 projectile_base.gd 头注释。**〔增量裁定 2026-08-28〕追加可选键 `weapon_ref`（WeaponBase 实例，修复 TH_SIZE_NOVA/MEC 系效果引擎侧不可达）；projectile 分裂继承、池化复位清零；缺失时行为同旧版（ctx.weapon=null），向后兼容**
2. **DamagePipeline 接口**：`resolve(ctx)->DamageResult`（九步）/ `resolve_reaction(snapshot_atk, coefficient, ctx)` / `begin_frame()/end_frame()` / `set_rng_seed()`；透传桩 `damage_pipeline_stub.gd` 同接口，`get_pipeline()` 工厂自动切换
3. **六大生命周期事件**：OnSpawn/OnTick/OnHit/OnPierce/OnBounce/OnExpire，派发顺序=挂载顺序；回收五路径统一收束 `_recycle`（OnExpire→清零→归还，顺序不可变）
4. **池 API**：`acquire()/release(node: Node)`，特化池收窄返回值；满池丢弃+计数，不阻塞
5. **SpaceGrid**：`rebuild()/query_circle()/query_nearest()/query_arc()`，128px 桶，弹-敌碰撞主路径（不用 Area2D 回调）
6. **数值红线**：乘区段整体钳 8.0、×500 保险钳+一局一次告警、δ≤0.92、链式深度≤3、分裂代数≤3/单次≤8/软 1500 硬 2000、单武器射速≤30/s
7. **顿帧实现**：GameLoop 手动 `game_delta = raw × time_scale` 双时间通道，**禁止写 Engine.time_scale**（架构 §2.17 裁定）

### 8.1 v0.6.0 增量裁定（冻结契约变更清单，详见 A4_v0.6.0_design.md）

1. **GameStatus.SHOP 枚举**：尾部追加值 6（零重编号）；TRANSITIONS 增 PLAYING→SHOP 边与
   SHOP:[PLAYING, GAME_OVER] 行；SHOP 与 PAUSED/LEVEL_UP 同帧分支（tree.paused=true，仅⑦⑧）。
2. **spawn enqueue 增量可选键 `hp_override`**（EnemySpawner）：>0 → spawn 后 max_hp=hp=maxf(v,1)；
   Boss split 召唤由 Enemy._summon_allies 折算 max_hp × hp_ratio 入队。
3. **EventBus 增信号 `gold_changed(total:int)`** + emit_gold_changed 包装（DataValidator.EVENT_NAMES
   镜像同步 +1）；金币余额唯一写入口 = GameLoop._add_gold。
4. **pool_prewarm 增 "gold":96**（BalanceTables 默认 + .tres 双处；池×6→池×7，pkg4/pkg5 断言授权更新）。
5. **DataValidator.ADD_POOL_IDS 扩项**：+&"add_gold_drop" / +&"add_gold_value"（不入 LINEAR_ADD_POOLS，
   走 F3 衰减）；validate_enemy 增 warning 级 gold_drop 结构校验（chance∈[0,1]、min≥0、min≤max）。
6. **CardGenerator.CATEGORY_WEIGHTS 新值**：WEAPON 8.0 + 原五类×0.92 归一（和=100.0；三处同值：
   常量 / BalanceTables 默认 / balance_tables.tres，pkg6 锁定）；CardKind 尾部追加 WEAPON=4；
   generate_candidates 增可选 context 键 `shop_exclude_weapon`。
7. **WaveDirector 增 `shop_requested(wave, black_market)` 信号 + `queue_extra_shop()` /
   `reset_extra_shop()`**；BUFFER 间隙开店语义 = **当前刚清空的波**（该波清空后、下一波 Boss 前），
   单间隙单店闸 `_shop_gapped`（start_wave 复位）；波表迁移 w5/w15/w25→w9/w19/w29 events=[SHOP]。
8. **TraitData 增字段 `required_weapon:StringName`**（A4 §6）：候选过滤 + apply 挂载防御拒绝；
   首个消费者 MEC_ORBIT_LINK → W8_orbit_field。
9. **Enemy 增 Boss 弹幕/召唤契约**：bullet_patterns/summons 快照（duplicate）+ 半冷却计时 +
   fan/ring/spiral 三形态（P2 键 count_phase2 / speed_mult_phase2）；伤害只走
   panel_snapshot.base_atk → take_contact_damage 单点（禁 DamagePipeline/settle_aoe）；
   BOSS_SUMMON_ACTIVE_CAP=12；Boss3 charge/phase3/laser_sweep defer 不消费。

**变更摘要 v0.6.0**：新增 GoldCoin/GoldPool/ShopUI 三个类与 gold_coin.tscn 场景；GameLoop 状态机
+金币+商店仲裁；WaveDirector 商店间隙调度；Enemy Boss 弹幕；CardGenerator 武器卡与门槛词条；
HUD 720×1280 重排（金币/描边/波次横幅/layout_rects 契约）；测试新增 pkg6（115 项）并授权更新
pkg0（ADD 池计数 14）/pkg4（池×7）/pkg5（池×7 + 黑市桥接契约）。

### 8.2 v0.7.0 增量契约（详见 A6_v0.7.0_design.md §13）

1. **EventBus +2 信号**：`chip_slot_unlocked(slot)` / `gold_rush_started(wave)` + emit 包装；
   DataValidator.EVENT_NAMES 19 → **21**（双源镜像同步）。
2. **DamageContext +chip_entries**；**ModifierStack +chip_product / aggregate_chip()**；
   **DamageResult +chip_product**；**DamageAudit +clamped_chip / chip_product**；
   DamagePipeline resolve 增 ⑥b 芯片段；`_finalize` 终值改 `raw = S × min(M×chip, cap_prod) × L × C × V`
   （chip_product=1.0 时与 v0.6.0 恒等，fixed-seed 回归共证）。
   ★ **settle_aoe/DOT/反应不吃芯片 ATK 段**（反应 chip_product 恒 1.0）。
3. **BalanceTables +cap_chip_zone**（默认 1.0，合法域 (0,4]，.tres 不必改）；validate_balance 非致命同步。
4. **EnemySpawner.enqueue 可选键 +`gold_rush:bool` / +`summon:bool`**；+`summon_active_count`
   观测口；Boss 召唤闸改独立计数（原 active_count() 含普通敌——U13 修复）。
5. **Enemy +字段/接口**：is_summon / gold_rush（spawn 默认 false、_reset_state 清零）、
   spawn_wave()、static projected_max_hp(data, wave)（HP 成长唯一真源，金币关 0.4×血同源）、
   ring_visible() / ring_progress(element)（U8 附着环）。
6. **ShopUI**：open() 五参签名不变（兼容）；+set_chip_shelf / set_chip_slots / set_player_full_hp /
   layout_rects（11 项）；shelf_state +chips/chip_purchased/chip_free_slots；mark_purchased 扩 0~5；
   purchase_requested 语义扩 index 4~5（芯片五查仲裁）。
7. **ParticlePool.burst 返回值** void → GPUParticles2D（可 null，源兼容）——ParticleDirector
   重指反应预设材质用（每次重指防串色）。
8. **DamagePopup.show_popup 增可选第 5 参 p_text**；PopupManager +show_text_popup(pos, text)
   （target_uid=0，不入合并注册表）。
9. **GameConst**：+CHIP_STAT_KEYS（8 键封闭注册表）、+static card_kind_name(kind)（kind 中文名
   单源——card_select_ui/shop_ui 两处数组字面量收束）。
10. **CardGenerator**：+static rarity_weights_for(wave)（稀有度权重单一真源提取，ChipHandler 复用）；
    generate_candidates 增可选 context 键 **weapon_weight_mult**（首件武器保底 ×2；仅调用点
    duplicate 改 WEAPON 键，静态表与三处镜像零改动）。
11. **波表**：w6/16/26 events=[GOLD_RUSH]（金币关）；w10/20/30 composition=[]（**U12 双 Boss
    修复**——原 composition+BOSS 事件双路径生成两只 Boss）。
12. **ChipHandler（新类）**：MAX_CHIP_SLOTS=3 / CHIP_RNG_SEED=4242 / CHIP_PRICES{40,70,120,220} /
    CONVERT_RATIO=0.5；GameLoop 组装序 = relic_handler 之后、spawner add_child 之前；
    player.setup deps 增键 `"chip_handler"`。

### 8.3 v0.8.0 增量契约（详见 A7_v0.8.0_design.md §11 假设清单 R1~R10）

1. **EventBus +1 信号**：`curse_changed(count:int, max_hp:float)` + emit 包装；
   DataValidator.EVENT_NAMES 21 → **22**（双源镜像同步）。
2. **WaveDirector +`event_requested(wave, event_index)` 信号** + `reset_event_state()`；
   常量 EVENT_START_WAVE=4 / EVENT_CHANCE=0.40 / EVENT_KINDS=4 / EVENT_RNG_SEED=777；
   BUFFER 事件闸在商店分支之后（非商店间隙显式排除 _is_shop_wave；黑市 pending>0 整闸跳过
   不消耗 roll；一间隙一 roll 未中也消耗 _event_gapped 闸，**闸随 start_wave 复位**——
   审查 Critical 修复：初版漏复位=每局限一次 roll，40% 的局零事件房）。
3. **ChipHandler**：+SUBSTAT_RNG_SEED=4243 / SET_BONUS_MULT=1.10 / SUBSTAT_VALUES（8 键固定
   小值）/ SUBSTAT_DIST={0:0.50,1:0.85}；+`roll_substats(main_key)`；`equip(chip_id, rarity,
   substats:=[])` 三参（旧调用恒等兼容）；equipped 条目带 `substats` 键；stat_bonus =
   Σ主值+Σ副词条同键，主键 ≥2 枚 ×1.10（查询时聚合）；roll_shop_offers/grant_boss_chip
   预随 substats（所见即所得）；max_hp 键走 CurseHandler.recompute_max_hp 通道（null 兜底旧
   加法路径）；+curse_handler 注入键。
4. **Player**：+static `compute_max_hp(char_pct, chip_sum, flat, curse_layers)`（max_hp 公式
   唯一真源）；+`apply_character(CharacterData)`（move_speed/pickup_radius/引用；max_hp 不直改
   ——respawn 公式承载）；+`char_max_hp_pct()/character_xp_mult()`（null 兜底 0.0/1.0）；
   +`try_dash()`（四门 fail-fast）+ DASH_TIME/DISTANCE/INVULN/CD 常量 + dash_left/dash_cd_left/
   dash_invuln_left/_last_move_dir 字段；受击判定 = invuln OR dash_invuln（互不覆盖）；
   受伤 ×(1+0.08n)（deps.curse_handler，null → 1.0）；+max_hp_bonus_flat 池；
   respawn 清 flat/冲刺计时/方向。
5. **CurseHandler（新类）**：MAX_CURSE_LAYERS=5 / 0.08/0.15/0.04 每层三乘区；add/remove 钳边
   返实际增量；recompute_max_hp(heal_delta:=0.0) 运行期 max_hp 唯一写入口；GameLoop 组装序 =
   chip_handler 之后、player.setup 前（player deps +`"curse_handler"`、chip_handler deps 同）。
6. **TraitStack**：+static `is_curse_trait(data)`（ADD 池负值；params.is_curse 退役装饰）；
   +`peek_last(skip_curse)` / `detach_last(skip_curse)` / `detach_by_id(id, layers:=1)`
   （共用 _detach_at；调用方负责 invalidate_panel）。
7. **ShopUI**：open() 五参签名不变；+utility 行2（strip 60/purify 80/contract 120，均店限 1）；
   布局 (60,790) 行2 / 面板 (60,884) / 离开 (60,1064)；layout_rects 11 → **14**；
   +set_strip_available(p_ok, p_preview:="") / set_purify_available / set_contract_available；
   shelf_state +strip/purify/contract_used；dim mouse_filter IGNORE→STOP。
8. **EventUI（新类）/ EventDirector（新类）**：事件复用 SHOP 态（TRANSITIONS 零改动）；
   EventUI 选项 (60,520)/(60,650) + 离开 (60,800)；EventDirector rng seed 888 赌桌专用；
   四事件面额表见 A7 §7（自拟值真源）；事件金币全走 _add_gold（吃 K_gold）文案「基础值」。
9. **GameLoop**：`start_run(p_character_id:=&"")`（空参读菜单选中；序 = PLAYING →
   _reset_run_state → start_wave(1)，角色应用/首发武器并入 _reset_run_state）；+`goto_menu()`
   （GAME_OVER→MENU）；+_starting_weapon_id() 单点（boot/reset 两处）；xp 三乘子 =
   遗物×角色×(1+K_chip)；+_drain_overlays_after_resume()（弹卡→开店→开事件，_close_shop/
   _on_card_choice/_close_event 共用）；cursed 卡两接入点 add_curse(1)；金币掉率 chance 追加
   curse_handler.gold_drop_bonus()。
10. **registry/validator**：+characters 类目（manifest 增行）；+validate_character（数值域
    error 级）；check_references ④ starting_weapon_id 悬空剔除宿主；CharacterData（新 Resource）。
11. **MenuScreen**：+setup(registry)/selected_character_id()/set_selection（id 字符串字典序
    排序——StringName 直排按指针序不稳定）；布局 标题 y200/副标题 y260/角色卡×3
    (48,340)/(264,340)/(480,340) 192x240/开始 (280,640)「开始出击」；start_requested 无参签名
    不变。
12. **GameOverScreen**：单按钮 → 双按钮「再次出击」(100,560) 220x52（restart_requested 语义
    零改动）/「返回选角」(400,560) 220x52（+menu_requested → goto_menu）。
13. **HUD**：+诅咒标签 (612,64) f14 紫（curse_changed 驱动，n=0 隐藏）；+DashButton 内嵌类 ×2
    (24,1152)/(576,1152) 120x104 STOP（tap<0.3s 且位移 ≤14px → try_dash；冷却 modulate.a=0.35；
    非 PLAYING 隐藏）；layout_rects 8 → **11**。

### 8.4 v0.9.0 增量契约（详见 A8_v0.9.0_design.md，假设清单 H1~H8）

1. **EventBus +1 信号**：`blessing_granted(kind:StringName, wave:int)` + emit 包装；
   DataValidator.EVENT_NAMES 22 → **23**（双源镜像同步）。
2. **BlessingHandler（新类）**：seed 999 独立流；BLESSING_WEIGHTS{gold30/heal15/atk25/rof15/
   attach10/slot1 4/slot2 1}≡BalanceTables.blessing_weights 双源镜像（.tres 不改）；
   `gold_amount(w)=20+3w` / `available_pool(w)`（出牌时过滤：slot1 仅 capacity<6、slot2 仅
   capacity<=4、heal 仅 hp<max_hp，gold/atk/rof/attach 恒入）/ `roll_offers(w)`（加权无放回
   恰 3 项 {kind,label,detail}）/ `apply(kind,wave)->bool`（slot 臂 got<=0 → false 不派发）/
   `count_skip()`（仅 DebugStats 遥测）。GameLoop 组装序 = presentation 段 popup_manager/hud
   之后；`EventBus.wave_cleared` 订阅固定在金币关之后（连接序=派发序）。
3. **BlessingUI（新类）**：复用 SHOP 态（TRANSITIONS 零改动）；标题 y300 f26 / 描述 (60,360)
   600x48 / 三选项 (60,440)/(60,564)/(60,688) 600x110 / 跳过 (60,820) 600x70；
   layout_rects 4 项两两无交集；dim STOP；GAME_OVER/MENU 强制收起；空 option 防御 disabled+"-"。
4. **ChipHandler**：+CHIP_SLOT_CAP=6（MAX_CHIP_SLOTS=3 保留）；+bonus_slots / blessing_stats；
   +`slot_capacity()=mini(unlocked_slots+bonus_slots, 6)` / `add_bonus_slots(n)->实际增量`
   （负值钳 0）/ `add_blessing_stat(key, delta)` / `invalidate_panels()`；free_slots 改
   `slot_capacity()−equipped`；stat_bonus 套装 ×1.10 **之后**加 blessing_stats 加和（Option A
   ——只加和不参与 ≥2 判定不被放大）；slot_snapshot 恒 **6 格**（容量外 `{"locked":true}`）；
   reset_run 归零 bonus_slots+blessing_stats。
5. **GameLoop**：+blessing_handler/blessing_ui/_deferred_blessing；四方法
   `_on_wave_cleared_blessing(w>=2 才弹)` / `_open_blessing_flow`（四重守卫：非 PLAYING ∥
   shop.is_open ∥ event.is_open ∥ blessing.is_open → 暂存）/ `_on_blessing_choice` /
   `_on_blessing_skip` + `_close_blessing`；_drain_overlays_after_resume 排空序扩展
   **升级→赐福→商店→事件**；_reset_run_state 追加 blessing_ui.close() + 暂存清零 +
   blessing_handler.reset_run()。硬上限叠波直调 start_wave 不派发 wave_cleared = 天然无赐福。
6. **ShopUI**：SLOT_SIZE 188x120 → **90x120**；SLOT_POSITIONS 3 → **6 项**（8/105/205/305/405/505,
   36）；_refresh_slots + locked 分支（"未解锁" 灰显 0.45,0.45,0.5）；面板 (60,884) 600x168
   与离开 (60,1064) 不动；layout_rects 仍 14 项数值不变（槽盒嵌套不入列）。

### 8.5 v1.0.0 增量契约（详见 A9_v1.0.0_design.md，假设清单 A9-1~A9-6）

1. **MetaStore（新类，无 autoload）**：SAVE_VERSION=1 / DEFAULT_SAVE_PATH `user://meta_save.cfg` /
   UPGRADES 五条目封闭表（hpg/atk/greed/seed_gold/xp）；存档键布局 [meta] save_version+crystal /
   [levels] String(id)×5 / [stats] total_runs+total_kills+best_wave；损坏判定树全回退【不写回】；
   save 失败 push_warning+false 内存保留；wipe 本无档静默；purchase 三拒（未知/满级/余额不足）
   不扣款。**组装序 = GameLoop._boot_build_actors 首位**（boot 即 load_save）。
2. **定价序列冻结**：100 起逐级 ×1.6 后 round（★逐级迭代非 pow——round(655.36)=655≠冻结 656）；
   hpg/atk/greed/xp = 100/160/256/410/656，seed_gold = 100/160/256；满级 price=-1。
3. **compute_max_hp 增第 5 参 `p_meta_flat:=0.0`**（公式唯一真源 prescale 加 + meta_flat；
   默认 0 → respawn 及全部既有调用零改动恒等）。
4. **CurseHandler +meta_hp_flat**（run 开始注入，recompute 每次算入；不存 player 字段
   respawn 不清）；**ChipHandler +meta_stats +set_meta_stats**（★reset_run 不清——与
   blessing_stats 关键差异；run 开始由 GameLoop 显式载入覆盖；stat_bonus 赐福段之后加和，
   atk 随 ⑥b 段共享 cap_chip_zone）；meta_stats_snapshot 仅 {atk_pct, gold_gain} 二键防双算。
5. **GameLoop**：+_settle_run 死亡结转单点（一次闸 _settled_this_run，_on_player_died 内
   change_state 前调用；gain=maxi(gold,0)；meta_store 缺失 → set_crystal_gain(0) 降级）；
   _reset_run_state 注入序冻结 = curse reset **前**注 meta_hp_flat → _add_gold(-gold) 后
   ①set_meta_stats（先载入覆盖残留）②seed_gold>0 **直注入** gold+emit（★不经 _add_gold——
   greed 不放大开局金）→ 尾部 _settled_this_run=false；xp 链第 4 因子 value×=xp_mult()
   （chip 行后、_spawn 前）；_boot_build_presentation 组装 MetaPanel（menu_screen 之后
   add_child→同层绘制在上）+ 四方法 _on_meta_requested/_on_meta_purchase/_close_meta_panel/
   _refresh_menu_meta（购买仲裁仅 MENU+面板开）。
6. **UI**：MenuScreen +meta_requested 信号 + 统计行 (0,712) f14「最佳波次 %d · 总局数 %d ·
   累计击杀 %d · 结晶 %d」+ 入口钮 (280,752) 160x56（setup/start_requested 签名零改动）；
   GameOverScreen +结晶行 (0,624) f16 + set_crystal_gain/crystal_text（summary/reaction/
   双按钮零改动）；MetaPanel 布局 = 标题 y96 f28 / 余额行 y152 f18 / 行钮×5 (60,
   200/320/440/560/680) 600x110（行序=UPGRADES 表序）+ 返回 (60,1084) 600x80 + dim
   (0.06,0.07,0.12,0.96) STOP（遮挡开始钮=与 MenuScreen 互斥实现）；layout_rects 6 项
   两两无交集；state_changed 非 MENU 强制 close；is_open 语义 = _opened + is_open()。
7. **核心红线**：全 0 级与 v0.9.0 行为逐位恒等（pkg10 M23 锚定：max_hp 100 / _add_gold 无
   缩放 / 快照 0.0 / xp fixed-seed 基线）；测试档隔离 pkg10 = 独立档 boot 后首件事
   set_save_path+wipe，收尾恢复默认路径再 wipe。

### 8.6 v1.1.0 增量契约（详见 A10_v1.1.0_design.md，假设清单 E-AMP-1~E-AMP-4）

1. **ElementalSystem +增幅双轨**：`try_amplify_factor(target, hit_element)->float`（只读快照：
   FIR 直击+ICE gauge → ×1.5×φ / ICE 直击+FIR gauge → ×2.0×φ / 其余 1.0；immune_mask 不查）；
   `consume_amplify(target, hit_element)`（重判同条件幂等 → clear 反向全清 + 分键遥测）；
   常量 AMP_MELT_FACTOR/AMP_VAPOR_FACTOR/MASTERY_LAYER_CAP（待升格 BalanceTables，E-AMP-2）。
2. **ProjectileBase._build_damage_ctx 注入**：element∈{FIR,ICE} 且 elemental!=null 且
   factor>1.0 → mult_pools += `{"pool_id": &"amplify", "source_uid": uid, "contrib":
   factor−1, "cap_pool": factor−1, "priority": 0}`（字段对齐 vuln 池）；**damage_pipeline.gd
   零代码改动**（V30 源码守卫：不含 "amplify"）。消费插点三处（projectile._on_settled /
   homing 主目标 / homing 次级循环），均在结算成功且目标未 dead 后、附着前。
3. **BalanceTables.reaction_table 三 rule +cd 键**（2.0/3.0/6.0；.tres 显式同值镜像）；
   detect_reactions 触发前 `rule.get("cd", cd_fallback)`（cd_fallback=cd_rxn，字段保留）；
   `ElementalSystem.reaction_key(rxn)` 唯一映射口；validator 增非致命告警 cd≤0。
4. **ELE_MASTERY 词条**（.tres：step 0.25 / stack_max 3 / hooks 常驻 / rarity 2；
   traits 28→31 家族第 5 枚，注册资源 83→84）；`WeaponBase.attach_trait` 扩展
   mastery_step 注册分支 + `_trait_layers(id)`；`register_mastery(uid, layers, step)`
   （layers≤0 或 step≤0 不收；step 后写覆盖；无注销通道 E-AMP-1）；
   `mastery_layers()=mini(Σ跨武器, 3)` 唯一裁定点；`reaction_mult()` = ∏VOID ×
   (1+step×层数)——剧变系数与增幅因子同源同乘；仅 VOID 恒等 1.8（pkg3 零冲击）。
5. **UI/遥测**：`DamagePopup.show_popup` 增可选第 6 参 `p_suffix`（数值模式拼接、
   merge 保留、文本模式不变、归还清空）；`PopupManager.on_damage_resolved` 仅
   breakdown 含 &"amplify" 的新跳字加 ‼；DebugStats 新分键 `amplify_melt`/`amplify_vapor`；
   HUD `_build_summary` → `"Build  W:%d T:%d MP:%d"`（MP 跨武器封顶 3、0 恒显；
   layout_rects 11 项不变）。
6. **语义边界**：三剧变零语义变更；KIN/光束/近战/settle_aoe/DOT/连锁跳不触发增幅；
   穿透链各目标独立判定与消耗；融→蒸同帧连段合法（E-AMP-4）；截断不标注（E-AMP-3）。
   自测 = `tests/runner/test_pkg11.gd`（16 项 V25~V40 恰额）。

## 9. 工程铁律（全程有效）

- 不修改 `docs/` 下任何文件；发现文档矛盾以 C_architecture > B_spec > 用户需求链裁决并记录
- GDScript 静态类型全覆盖；无 TODO 桩；Godot 4.3 API（无 abstract/无泛型/无类型化 Dictionary）；autoload 不声明 class_name
- 窄参数覆写非法（仅返回值协变）；`Dictionary.get()` 返回 Variant 需显式类型标注（本次中断就是它）
- 不用外部插件；美术全用程序化占位（纯色/PrimitiveShape），正式美术后续迭代
- 测试全绿才允许合入下一包；每包完成必须 git commit + push

## 10. Git 约定

- 远程：`origin = https://github.com/Genmer/Infinite-Fission.git`，主分支 `main`
- `.gitignore`：`.godot/`、`.DS_Store`（Godot 导入缓存不入库）
- 提交信息格式：`<包号>: <一句话>`（如 `pkg3: weapon/trait/elemental core + builtin traits`）

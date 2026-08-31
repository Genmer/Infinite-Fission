# ⚡ INFINITE FISSION · 开发进度与交接文档（PROGRESS）

> **本文档是跨工具/跨会话交接的唯一入口。新会话/新工具接手后：先读完本文 → 按 §5「下一步行动」顺序执行。**
> 最后更新：2026-08-29 ｜ 更新人：主控 Agent（ZCode 会话：包 3 自测+修复、内容 .tres、duck 收紧、包 4、集成包两段接力，全部完成；当前在阶段 E 把关）
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

**仓库当前可编译（0 解析错误），回归 836/836 全 PASS（pkg0 129 + pkg1 108 + pkg2 140 + pkg3 128 + pkg4 98 + pkg5 118 + pkg6 115，另有 pkg6_extra 32 项验收补充 / pkg7 172 项 v0.7.0 增量自测 / pkg7_extra 56 项验收补充，不计入 836 基线口径；全 runner 合计 1096）。压力场景（500 弹+100 敌，headless 逻辑帧口径）P95≈5.5~6.2ms < 8.3ms；soak 180s 满载自动战斗 0 运行期实例化 / 0 池污染 / 无错误日志。**

**v0.6.0 增量（2026-08-31，T0~T8）：商店（Boss 前夜 w9/w19/w29）/ 金币经济（掉落+磁吸+HUD）/ 武器卡（CardKind.WEAPON）/ 武器门槛词条（required_weapon）/ Boss 弹幕三形态+召唤 / HUD 720×1280 全量重排+波次横幅。数值与裁定真源 = `docs/analysis/A4_v0.6.0_design.md`；自测 = `tests/runner/test_pkg6.gd`（115 项）。提交序：T1 38ad7ef → T4 a18770d → T3 2db7455 → T5 b7984c7 → T2 57b742f → T6 f7d3f8a → T7 cffa4f5 → T8 本笔。**

**v0.7.0 增量（2026-09-01，U1~U15）：芯片系统（ChipData×8 / ChipHandler 3 槽 / 管线 ⑥b 独立乘区段 cap_chip_zone / 商店芯片货架+槽位面板 / Boss 芯片掉落）/ 金币狂欢关（w6/16/26，0.4×血 rush + 掉落覆写 + 波末比例奖励）/ 双 Boss 修复（w10/20/30 composition 清空）/ 召唤独立计数（summon_active_count 闸）/ 附着环 ElementRing + 反应粒子三预设 + 打击感分级 / 反应统计与结算行 / 首件武器保底（weapon_weight_mult ×2）/ 受击红闪 / 文本跳字通道。数值与裁定真源 = `docs/analysis/A6_v0.7.0_design.md`；自测 = `tests/runner/test_pkg7.gd`（172 项；审查后新增槽位门控 2 项 + U11 段武器 id 笔误 W2_smg→W2_gatling 修复后漏计 3 项归位）。提交序：U1 a9573ab → U2 a6377c1 → U3 22465f6 → U12-14 a920214 → U5 cf68ab3 → U4+U7 e74328b → U6 3753072 → U8-10 375dcf9 → U11 f184dac → U15 5dec3f4。**审查后修复批（fix-review）：芯片定价恢复裁定 60/110/180/300（coder 曾擅改卡架同梯度 40/70/120/220——已推翻）；free_slots()=unlocked−equipped 槽位门控真实生效（原为无语义死状态）；heal 预禁用在 maxhp/CHIP_HP 购买后回写；_gold_add_sum 帧缓存试做后回退（帧号失效对同帧 attach 词条路径返回脏数据，pkg6 冻结用例拦截——正确钩子见 §11）；粒子 burst null 守卫恢复；元素环无附着零分配；商店芯片槽满态购买后同步。**

**阶段 E 关键战果（审查/测试发现并修复）：**
- 一轮审查 1C+3I：重开不清场（残留战场秒杀重生）→ `_clear_battlefield` 清场序 + respawn 1.5s 无敌；GameFeel 订阅晚于 Spawner 清 tags（Boss 击杀打击感永不触发）→ early_bind；Boss 波伴随怪流水锁死 wave_cleared → `_boss_ref` 存活闸；TH_CRIT_SHARD 全武器声明零实现 + 校验器空承诺 → 补 `trait_effect_crit_shard.gd` + check_references ② 落地
- coder 实现中发现的**双落血 bug 族 5 处**（settle_aoe/投射物直击/激光/环绕/弧斩：真件管线 9b 内部落血 + 调用方再落血 = 实际游戏全部伤害 ×2）→ 全部改双轨口径（`is DamagePipeline` 真件不落血/桩落血），pkg2/3 桩口径用例原样全绿验证；连带修 laser_beam._recycle 归还恒短路池泄漏
- pkg5 偶发抖动（randomize 漂移卡牌流）→ card_generator rng 定种子 42 + 遗物用例幂等化

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
- 当前基线：**pkg0 129 / pkg1 108 / pkg2 140 / pkg3 128 / pkg4 98 / pkg5 118 / pkg6 115，全 PASS（共 836；pkg6 为 v0.6.0 增量自测；另有 pkg6_extra 32 项验收补充用例独立 runner 与 pkg7 167 项 v0.7.0 增量自测，不计入 836 基线口径）**
- v0.6.0 压力复测：**P95 = 5.559ms**（avg 2.191 / P50 1.791 / P99 6.968，判定线 8.3ms PASS）
- v0.7.0 压力复测：**P95 = 5.714ms**（avg 2.302 / P50 1.912 / P99 6.515，判定线 8.3ms PASS；六池 0 运行期实例化 / 污染 0）
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

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

**仓库当前可编译（0 解析错误），回归 720/720 全 PASS（pkg0 129 + pkg1 108 + pkg2 140 + pkg3 128 + pkg4 98 + pkg5 117）。压力场景（500 弹+100 敌，headless 逻辑帧口径）P95≈5.5~5.8ms < 8.3ms；soak 180s 满载自动战斗 0 运行期实例化 / 0 池污染 / 无错误日志。全部已推送（HEAD = ff9240d）。**

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

**〔用户反馈落地 2026-08-29，art/daylight-pop 分支〕**：①特效三连修——W8 环绕力场去占位圆（光球+虚线轨道+扫掠残辉+命中冲击环）、点燃火苗 ×2.2 + 余烬光晕、感电改紫色电环 + 双错相电弧（电弧周期 0.5s→0.26s、存活 0.08s→0.13s）、超导雾圈去「球」感（压暗 + 旋转虚线电环）、连锁闪电中点 soft_dot 球改四角星爆闪 + 落点电花池；②数值三连调——卡牌稀有度数值倍率 {白1.0/蓝1.4/紫1.9/金2.6}（原口径稀有度只改颜色不改数值）+ 紫金精通连升 2 级、升级回满血、怪经验梯度拉开（E2 4→7 / E3 10→20 / E4 5→10 / E5 3→12×8 / Boss 200→600/750/900）；③长线规划成文 `META_ROADMAP.md`（大厅/成就/分图记录/图鉴三件套/股市/局外养成，docs/ 冻结不动、文档置于根目录）。

**〔用户反馈二轮 2026-08-29〕**：①感电彻底去圆球——垂直落雷（天降锯齿 0.9s 周期 + 命中点四角星闪）替代电环、超导只留雾圈 + 电弧双倍频率；②冰冻可见性——冰晶 ×1.8 放大 + 冰蓝封冻重染色 + 加厚冰壳呼吸圈；③后期元素可见性——死亡元素释放（点燃→余烬火星 / 冰系→青色碎裂涟漪 / LTG 槽≥60→感电残弧 1~2 跳，全部复用既有表现广播零新增信号）；④爆炸残留修复——ParticlePool 寿命表兜底回收（finished 信号偶发不触发的发射器 lifetime×1.3+0.25s 强制归还，GameFeelDirector.tick 驱动）；⑤**新武器获取链补全（核心）**——原版 equip_weapon 全工程零调用点（玩家永远只有手枪、W8 力场根本拿不到）：卡池新增 WEAPON 类别（权重 10，未持有 + 有空槽才上架，应用 = equip_weapon 首空槽）；⑥金卡率 2%→6% 基础 + 波次成长加强（pkg4 分布界 40→55 同步）；⑦新词条 MEC_HIT_BURST「命中迸裂」（EF_HIT_BURST 新处理器，命中落点范围迸裂 35%ATK/半径80，2 层 45%/100；双镜像注册表同步）；⑧新敌 E7 喷吐者（首个 RANGED 行为敌，专属贴图，弹速 240/2.4s/360 射程）织入 w6/9/11/12，tp 同步；⑨Boss 巨大化（视觉 1.9→2.3）+ 满屏弹幕（扇 8/12→14/22@4.6s、环 16→26@4.0s、螺旋 20→32@3.2s）；⑩力场底部数值标注（环绕 ×N · 单击伤害）+ 轨道呼吸辉光带。回归 731/731 PASS。

**〔大厅/图鉴/成就实装 2026-08-30，art/daylight-pop 分支〕**：META_ROADMAP M4+M6 首批从规划转实装——①`scripts/meta/meta_manager.gd`（autoload `Meta`，user://meta_save.cfg 持久化；击杀侧不落盘防 IO 风暴，局结算/成就/图鉴解锁时落盘）；②图鉴三件套（怪物=击杀解锁+累计计数 / 武器=获得解锁 / 词条=抽取解锁，未解锁显示剪影+？？？）；③成就 11 条（定义表驱动：累计击杀/单局波次/单局等级/持枪/词条/Boss/局数）；④历史最高记录（波次/击杀/等级 + 累计局数/击杀）；⑤大厅 UI（主菜单出发按钮下方三入口带完成度角标 → 全屏详情面板：图鉴三页签/成就清单/记录页）。新增验收套件 `tests/runner/test_verify_feedback.gd`（64 项行为级验收：升级回满血/武器装配链/稀有度缩放/精通连升/命中迸裂/E7 开火/死亡元素释放/详情面板/粒子兜底/表现件/数值落位/图鉴成就记录全链）64/64 PASS，回归 731/731 PASS。

**〔多地图+新怪实装 2026-08-30，art/daylight-pop 分支〕**：META_ROADMAP M2 从规划转实装（用户反馈「多种类型地图配合多种类型的怪，第一大关通关后打后面的」）——①新怪 ×4（全部专属程序化贴图）：E8 恶魔小鬼（紫晶魔域·高速追击）/ E9 冰霜仔（寒霜冰原·ICE 抗 60%+冻结免疫，resist[2] 口径）/ E10 林间飞雀（翡翠树海·复用 dart 疾冲走位）/ E11 水泡怪（远程 RANGED 弹）；②新地图 ×3（20 波表，Boss@10/20，`resources/maps/` 旁路波表）：寒霜冰原（冰+水系）/ 紫晶魔域（恶魔+爆虫）/ 翡翠树海（飞雀+疾行者+重甲）；③`scripts/meta/map_table.gd` 静态地图表（id/名/描述/波表路径/最终波/云层主题色）；④GameLoop：`start_map_requested` 选图信号 + 未解锁拒绝 + 波表按图注入 + 分图云色调 + HUD「图名 · 第 X 波」；⑤Meta：maps_cleared 通关存档（解锁链 = 上一关通关，wave_cleared ≥ 最终波判定）+ map_records 分图记录；⑥大厅：「出发！」改出选关面板（4 卡：状态 = 已通关★/可挑战/🔒），记录面板加分图最佳与通关进度；⑦图鉴自动收录新怪（图标映射补 E8~E11）。验收套件扩至 85 项（85/85 PASS），回归 731/731 PASS。

**〔怪物品级体系 2026-08-30，art/daylight-pop 分支〕**（用户反馈「不同风格的怪要有各自等级的小怪/大怪/多种精英/Boss/最终Boss」）——①新增 TAG_FINAL_BOSS=4 标签位；②精英巨大化：TAG_ELITE 敌视觉 ×1.55（戴皇冠的「很大的」大怪；碰撞盒不变——弹幕游戏判定小于视觉为惯例口径），E2/E3/E4 补 elite_mult（此前仅 E5 有数值载体）；③Boss 1/4 屏：BOSS_VISUAL_MULT 2.3→3.8（视觉半径 152px/竖屏 1280 ≈ 24%）；④最终 Boss 1/3 屏：FINAL_BOSS_VISUAL_MULT 5.0（半径 200px ≈ 31%），四张波表最终波 Boss 打 tags=6（BOSS|FINAL）；⑤四图编入多种族精英（composition 支持 "tags" 键直通）：草原 w16 爆虫精英×2、冰原 w12 冰霜仔精英/w16 水泡怪精英×2、魔域 w12 恶魔精英×2/w16 爆虫精英×2、树海 w12 飞雀精英×2/w16 重甲精英×1，tp 同步。验收 89/89 PASS，回归 731/731 PASS。

**〔沼泽生态+远程密度 2026-08-30，art/daylight-pop 分支〕**（用户反馈「多设计装甲/触手/翅膀，加深绿色沼泽毒系地图，按近战/远程/突击/护盾设计，远程十几波没见到」）——①远程可见性根因=密度太低：主表 E7 喷吐者从 4 波×2~3 只扩到 7 波（w6/8/9/11/12/14/17，总量 16 只）；②新怪 ×5（全专属贴图+机制）：E12 毒泡史莱姆（近战·**死亡毒爆**：110px 内玩家吃 contact×0.6 + 绿毒环残效 PoisonSplash 自消表现件）/ E13 毒沼喷手（远程 RANGED 350 射程）/ E14 沼泽卫士（**护盾装甲**：全抗 40% + 320 血慢速 + 厚盾板贴图）/ E15 毒跳蛙（**突击**：复用 dart 疾冲走位）/ E16 沼泽巨口（**触手坦克**：5 触手+独眼+尖牙圈，300 血慢速重压）；③新地图第 5 关「翠毒沼泽」（20 波，w10 Boss2/w20 Boss3 最终，w12 巨口精英、w16 卫士+史莱姆精英，云层深绿主题）；④图鉴图标映射补 E12~E16。验收扩至 99 项（99/99 PASS），回归 731/731 PASS。

**〔角色系统+局外养成 2026-08-30，art/daylight-pop 分支〕**（用户反馈「不同角色不同技能、局外养成」）——①角色系统一期：`scripts/meta/character_table.gd` 三角色（哨兵-9 均衡·紧急护盾 3s 无敌 / 裂变者·薇拉 血45攻+25%·过载咆哮 4s 射速×2 / 堡垒·磐 血95攻-15%·震荡践踏 220px 击退+消弹），大厅选人持久化，HUD 右下角技能键（冷却置灰倒计时）；②局外养成一期：裂变结晶（局结算=波次×1.5+击杀/25）+ 4 永久升级（装甲/火力/磁力/超频），大厅养成面板购买，开局自动应用（血/攻/磁吸/技能CD 动态注入武器面板——修复了面板定格导致买养成不生效的真 bug）；③残留球修复：经验珠超时回归 8s→4.5s（大面值珠「不消失」观感）。测试隔离：pkg4 引导重置 Meta 状态。验收 114 项全 PASS，回归 731/731 PASS。全部未做项已入册 META_ROADMAP §5.8。

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
- 当前基线：**pkg0 129 / pkg1 108 / pkg2 140 / pkg3 128 / pkg4 98 / pkg5 117，全 PASS（共 720）**
- 压力/soak：`tests/stress/test_perf_500p100e.gd`（AC-01.2，headless 逻辑帧口径）与 `tests/stress/test_soak.gd`（AC-14.1，SOAK_FRAMES 常量控时长；10 分钟版预计 ~12 分钟实际，长跑须后台+轮询防会话超时）

## 8. 冻结契约速查（跨包接口，改动需全包评估）

1. **spawn(params) 参数字典**（武器→投射物）：基础键 velocity/lifetime/pierce/bounces/hitbox_radius/element/attach_value/generation/weapon_uid/panel_snapshot/trait_stack/team；Homing 追加 8 键（target_uid/turn_rate/speed_init/speed_max/accel/arm_delay/blast_radius/blast_falloff）；完整定义见包 2 交付报告与 projectile_base.gd 头注释。**〔增量裁定 2026-08-28〕追加可选键 `weapon_ref`（WeaponBase 实例，修复 TH_SIZE_NOVA/MEC 系效果引擎侧不可达）；projectile 分裂继承、池化复位清零；缺失时行为同旧版（ctx.weapon=null），向后兼容**
2. **DamagePipeline 接口**：`resolve(ctx)->DamageResult`（九步）/ `resolve_reaction(snapshot_atk, coefficient, ctx)` / `begin_frame()/end_frame()` / `set_rng_seed()`；透传桩 `damage_pipeline_stub.gd` 同接口，`get_pipeline()` 工厂自动切换
3. **六大生命周期事件**：OnSpawn/OnTick/OnHit/OnPierce/OnBounce/OnExpire，派发顺序=挂载顺序；回收五路径统一收束 `_recycle`（OnExpire→清零→归还，顺序不可变）
4. **池 API**：`acquire()/release(node: Node)`，特化池收窄返回值；满池丢弃+计数，不阻塞
5. **SpaceGrid**：`rebuild()/query_circle()/query_nearest()/query_arc()`，128px 桶，弹-敌碰撞主路径（不用 Area2D 回调）
6. **数值红线**：乘区段整体钳 8.0、×500 保险钳+一局一次告警、δ≤0.92、链式深度≤3、分裂代数≤3/单次≤8/软 1500 硬 2000、单武器射速≤30/s
7. **顿帧实现**：GameLoop 手动 `game_delta = raw × time_scale` 双时间通道，**禁止写 Engine.time_scale**（架构 §2.17 裁定）

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

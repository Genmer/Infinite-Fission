# R246 交付文档 —— 红色传说「技能升华」全链路 × 渠道矩阵 ×3 新角色

> 范围：FEEDBACK_TRACKER.md「二cr」表 #2~#5（升华卡系统 / 全角色两套技能 / 现有角色修复 / 渠道矩阵+新角色）。
> 编排：CreateWorkflow `dwfrun-0480c5cc`（~29 子代理）：侦查×4 → 修复员+回归门禁 → 设计师×12 并发 → 设计总监终审拆泳道 → 实施员×4 互斥泳道（skills/meta/cards/ui）→ 集成冒烟修障 → QA×3+评审×2 → 修复轮+终修 1 轮 → 本文档。
> 设计真源：本目录 12 份文档（10 角色 + `_card_system.md` + `_channels.md`）。
> 「本轮实测」= 2026-10-08 交付日·**终修后复验**实跑（命令与结果见 §7；18 套件 1815 断言全绿）。

---

## 1. 背景与用户需求

登记真源：`FEEDBACK_TRACKER.md:1339-1342`（「二cr」表 #2~#5 行）。

| # | 用户需求原话 | 落点 |
|---|---|---|
| #2 | 「buff里多一个红色（传说级）buff就是升华角色技能，爆率只有0.001%」——抽到后本局技能升级为升华版 | 升华卡系统（§4），设计 `_card_system.md`，cards+ui 泳道 |
| #3 | 全角色两套技能：普通版+升华版（强化数值+贴合原技能的新机制，「非简单数值」）；点名「10个不同设计人员」并发；fission 无技能出替代设计 | 10 份角色设计文档 + skills/meta 泳道（§3） |
| #4 | 现有角色问题先修复再设计新（诺亚叠层 R244 已诊断随本轮首修） | 修复清单（§2），✅ R246 Phase2 |
| #5 | 渠道可维持；扩充新角色；渠道含成就解锁（条件必须显示，例「无尽通关 10/20/30/50」阶梯）、关卡解锁、直购 | 渠道矩阵+3 新角色+成就阶梯（§5），设计 `_channels.md`，R247 meta+ui |

平衡总约束（总监终审）：升华版战力 **1.6~2.2×** 普通版；CD 120s 基准不例外（fission 无 CD 概念为例外，见 `fission.md` §5.3）。

---

## 2. 现有角色修复清单（先修后设计）

### ① 诺亚效果期内再施放无帽叠层（high）— 已修 ✅

- 根因（R244 诊断）：`_skill_summon_orbs()` 旧实现 append 不清旧批，效果期内再施放（手动/R241 自动施法同病）副本/护航舰 2→4→6 无帽叠层。
- 修法：入口先 `_summon_restore()`（player.gd:1933 起，R246 注释引 R244 诊断；回收函数定义 :2150，含 `is_instance_valid` 守卫 + ElementalSystem `unregister_reaction_mult`，对空幂等）——旧副本/护航舰先回收再重掷，语义=「刷新时长」（`_summon_left` 重置），与全角色幂等口径对齐。
- 验证：探针 `tests/probe_r244_skill_stack.gd`（入口）+ `probe_r244_skill_stack_body.gd`（用例体头部判读口径已声明为「已修」期望：施放 2/3 次恒 `copies==2 && drones==2`、首批实例 `queue_free` 落账；③⑤ 为回收链/幂等对照）——**本轮实测 20/20 PASS，exit 0**。
- 终修补强：QA low 未竟项「舰弹数值断言」已补——`r246_skills_cases` G8m/n 真池拦截断言升华舰弹 18%×(1+1.5%×12 层) 三乘区与普通版 12% 零回归（计入 §7 skills 139 断言）。

### ② 游侠上向瞬步越界回弹（medium）— 已修 ✅

- 根因：瞬步落点走全屏界 `_clamp_to_playfield_pos`（y≥24），下一帧 tick 的 `_clamp_to_playfield()`（活动区 y≥size.y×0.6=768）拉回——修复前实测 800→540→768，承诺 260px 实兑 32px+一帧回弹。
- 修法：瞬步落点改与移动同口径活动区钳制（player.gd:1575「活动区钳制单一真源」）——上向瞬步停活动区上界、零回弹。
- 验证：`tests/probe_r246_ranger_blink.gd`（含负验证：临时还原旧实现 5 项翻红实锤回弹）——**本轮实测 13/13 PASS，exit 0**。

### ③ 击杀派发序 bug（skills 泳道自查发现）— 已修 ✅

- 根因：玩家 Boot 序晚于 EnemySpawner 入树（game_loop.gd:2440/:2451），实例侧 `enemy_killed` 订阅派发位恒后于 spawner 死亡归还（`enemy.gd _reset_state` 清 tags/elemental）——zero 凝滞 / fission 分档 / mank 喂层读尸身恒空。
- 修法：`player.gd:26 static _static_init()` 脚本加载期抢订击杀快照账本（环形 64 条 uid→{tags,freeze}，早于全部 Boot 连接）+ `player.gd:43 _kill_snap()` 统一读口（账本 miss 回退尸身直读），三处消费点接线（引擎探针实证 static 内 autoload 访问可行）。
- 验证：`test_r246_skills.gd` 真派发击杀含账本路径断言——**本轮实测 139/139 PASS**。

> 修复链结论：①②（tracker #4 双刀）+③（skills 自查）在修复轮收口；QA/评审阶段（技能 pass/0 项失败、卡池 fix-needed、解锁 pass、玩法 needs-work、终审 needs-work）经**终修 1 轮**（tracker :1344 ✅ R247 终修，五项清单见 §6「终修」行）后：卡池 pass、复验门禁全绿（§7）、**终审 deliverable**；玩法 QA 的 low 级未消化项转 §8 遗留。

---

## 3. 十角色升华技能一览

角色/技能名以 `scripts/meta/character_table.gd` 表为准（sublime_name 落键 :34/:43/:52/:61/:70/:79/:88/:99/:114/:127，sublime_desc 同步；数值出典各角色文档）。普通版逐位零回归（各套件 G1 断言锁定）。

| id | 角色 | 普通版要点 | 升华版（技能名） | 新机制（升华独有） | 文档 |
|---|---|---|---|---|---|
| sentinel | 哨兵-9 | 紧急护盾 · 3s 无敌 | **绝对屏障** | 5s 力场；0.5s 相位反冲（15%ATK+220 击退）；吞伤回充 CD−2s（0.5s 节流、单施放帽 20s） | `sentinel.md` |
| veles | 裂变者·薇拉 | 过载咆哮 · 4s 射速×2.0 | **临界过载** | 5s 爬坡 2.0→3.2（0.25s/档）；余热层 4%×5 帽（窗内击杀积累）；1.2s/层渐冷软着陆 | `veles.md` |
| bulwark | 堡垒·磐 | 震荡践踏 · 220px 击退+清弹（零伤害） | **余震壁垒** | 主震参化 (300,380,340,40)；余震 3 跳×(200,140,220,8)@1s；磐岩护壁清弹 1.5HP/弹帽 48；保持零伤害 | `bulwark.md` |
| ranger | 游侠·岚 | 影袭瞬步 · 260px+1s 无敌 | **百影穿袭** | 340+30/层位移；1.8s 无敌；路径结算 240%+40%/层（56px 步进 uid 去重）；双残影爆（150px 120%+160 击退+110px 拂弹帽 6/影）；潜影 12s×4 帽 | `ranger.md` |
| zero | 演算者·零 | 时滞力场 · 2.5s 全场冻结 | **时滞奇点** | 3.5s 直写绕免疫；0.25s 持续力场覆盖新入场敌；凝滞击杀延展 +0.15s/杀帽 0.9（三计时同步）；唯我演算 rof×1.2 | `zero.md` |
| mank | 腐化者·莽 | 毒沼绽放 · 全屏 150%ATK | **万毒噬界** | 基线 210%+2%/层帽 30（满 270%）；精华按 tags 分档喂层（普1/精2/Boss5）；腐沼爆裂 140px 50%（深度 1、合成 UID 防撞键） | `mank.md` |
| vera | 毒系学者·薇拉 | 毒云领域 · 300px/6s/8%×0.5s 跳+减速 | **毒理学终章** | 7s 窗；半径 300→390 线性滋生；毒蚀层 12 帽（跳伤+6%/层、减速+1.5pp/层）；催化解离每层 3%ATK（错帧 pending 防幂等吞跳） | `vera.md` |
| noah | 召唤师·诺亚 | 召唤僚机 · 2 副本+2 舰 10s | **万械共鸣** | 3 副本 3 舰 16s+存量预支；舰体寿命绑窗；共鸣层 40 帽即时乘区 1.5%/层（施放全额继承+快照幂等回写）；恋战延时跨 5 层 +1s 帽 8s（三处同帧同涨） | `noah.md` |
| echo | 回响·伊可 | 双生回响 · 5s 射速+50% | **无尽回响** | 双生和弦：同款 1.90+横幅/异款 1.80（双武器同款 P≈1/9 高光）；回声层 6 帽（异款 +2%/层帽 1.92）；渐弱余韵 ×1.35 · 0.5\|0.6s/层帽 3.0\|3.6 | `echo.md` |
| fission | 改造者·枢 | 无技能（自选首发+CDR 折算帽 +30%） | **本命同调**（纯被动） | 同调层 500 帽 0.13%/层；抽卡即时糖 8%；Ω 五档改装件；CDR 折算 0.5→0.65/帽 0.30→0.45；追溯回填本局击杀×0.5 | `fission.md` |

设计文档索引（本目录）：角色真源 ×10（上表末列）+ 系统真源 ×2（`_card_system.md` / `_channels.md`）。

跨角色统一契约（总监裁定）：升华位 `skill_sublime: bool`（`player.gd:91`）；唯一置位入口 `enable_sublime()`（幂等，`player.gd:1473`）；HUD 红环读口 `player.get("skill_sublime")`（`hud.gd:304-311` has_method 守卫）；存档单键 `"sublime": {on, fission_layers}`（`game_loop.gd:2798` 序列化、`:2938` 回填）——暂停续档升华位不蒸发。

三新角色（渠道产物，非升华对象，§5）：medic 战地医师·苏「应急修复」/ vortex 坍缩者·汐「奇点坍缩」/ reaper 处刑者·刈「处决时刻」——skills 泳道已落 activate_skill 分支与三档着色（`test_r246_skills.gd` G11-G13 锁定；表行不带 sublime 键，**不掷升华卡**，见 §4.3 终修收口）。

---

## 4. 升华卡系统要点

设计真源 `_card_system.md`（决策表 D1~D11）。实现主体：`card_generator.gd` + `game_loop.gd` + `auto_idle_strategy.gd` + ui 域五文件。

### 4.1 红品质（D1/D2/D3/D11）

- 档位：`rarity=4` 排金(3)之上；`RARITY_NAMES=[普通,稀有,史诗,辉煌,传说]`（金改「辉煌」只换字，色值 #ffc93c/缩放/顺序零动，`palette.gd:108-109`）；色值独立常量 `PopPalette.RARITY_SUBLIME = Color("ff2e63")`（`palette.gd:102`，三重避让 ENEMY/ENEMY_DEEP/碎裂描边）。
- 缩放域不扩档（D3）：`RARITY_VALUE_SCALE` 保持 4 档，`_roll_rarity` 永不返回 4——红品质只属于升华卡，r220 四档硬锁/预热契约天然保持。
- 卡面：`CardKind.SUBLIME=6` 尾追（`card_generator.gd:17`，只追加不重排）；类别行「升华 · 传说」；5 圆珠全红（`card_select_ui.gd` range(5)）；挂机预选描金对 rarity==4 跳过（D11）。

### 4.2 0.001% 掷率（D4）

- 字面精确：`SUBLIME_CHANCE := 0.00001`（`card_generator.gd:27`），独立掷流 `_sublime_rng`（:23，构造定种 20261008=R88 `_slot_rng` 同式，:28；`reseed_sublime()` 注入口 :54）——不与主 rng/`_slot_rng` 混流，pkg4 分布锁零扰动（T10 百批 A/B state 相等实证）。
- 每批一次掷（R185 金卡槽同型先例）：期望 10 万批一遇；掷中替换末位向前第一张非 FALLBACK/SLOT_BONUS 卡（WEAPON 可被替换）；全保底批放弃上架，掷中即耗不补偿——出现率恒 ≤ 名义值。
- 三处显式豁免（0.001% 被 100% 保底顶穿=设计破洞）：fixed_rarities 循环 / min_rarity_floor 语句各加 SUBLIME continue/!=；slot 替换行 :125 双保险；`curse_last` 收紧为仅 TRAIT——红/诅咒撞色结构性消除。
- 定种：每日局 `reseed_sublime(daily_seed)` 全服同日同批、常规/继续局 randomize（`game_loop.gd:1557/:1561/:2833`，S4/S5 锁）。
- 概率显示：卡面描述尾句「本局技能升级为升华版 · 爆率 0.001%（红色传说）」=全仓首个品级概率文案。

### 4.3 fission 方案与掷卡判据（D7 + `fission.md` 替代设计；终修 P0 收口）

- **判据（终修后唯一口径）**：掷点守卫链 `card_generator.gd:176-180`（鸭子 `enable_sublime` 守卫 + `_sublime_available`）→ `_sublime_available`（:919）**唯一判据 = 表 `sublime_desc` 非空**。终修撤除旧「has_skill 恒放行」分支——medic/vortex/reaper 有技能无 sublime 键，旧判据会掷出「空文案+零行为」破洞卡（QA 双报+评审 high，tracker :1344 ①）；收紧后与 fission 判据统一：表有键（含 fission 替代升华）→ 掷；表无键 → 不掷。回归锁：`r246_sublime_cases` T6 变体（三新角色掷中不上架+源级锚）+ `r246_meta_cases` M3（升华键×掷卡一致性）。
- 替代升华=纯被动：`no_skill` 契约不破（HUD 置灰/自动施放链/遗物门/激活短路四处置零回归）；`_reson_layers` 0..500 + 追溯回填（抽卡瞬间本局已击杀 ×0.5，`_reson_kill_count` run 作用域原始计数器先计数后折算）+ Ω 五档改装件（200/300/400/500 走 extern_buffs + 弹匣 8%atk 走 meta）+ CDR 折算参数化（`player.gd:1014-1015`）。
- 存档：`resonance_snapshot()/restore_resonance()`（`player.gd:1740/:1745`，clampi 0..500 防脏档）；`game_loop.gd` 序列化走同构口（终修②，§6）经 `"sublime"{on,fission_layers}` 单键随档。
- 文档勘误（终修③）：`fission.md` §6.2 回填补 `int()→int(round())`（实现 round 进位：5 杀→3 层）+ 注明零参签名/内部计数器 `_reson_kill_count` 实现口径（语义等价）——设计文档与实现逐位对齐。

### 4.4 生效与生态（D5/D6/D8/D9/D10）

- 单卡通用（D5）：一张「技能升华」卡，效果=升华当前角色；卡面文案动态读表（抽到即显示当前角色升华预告）——卡系统只提供触发器，角色系统自解释。
- 拾取生效（D6）：`apply_choice` SUBLIME 分支鸭子守卫 `enable_sublime()`（幂等、本局语义）+ 横幅「红色传说 · 技能已升华！（本局有效）」+ `DebugStats.count(sublime_card_chosen)`；增益窗中的普通版不中途切态，下次施放起生效。
- 挂机必选（D8）：`AutoIdleStrategy.score` 首行特判返 998.0（`auto_idle_strategy.gd`；> 金词条上限 9.8、与诅咒域 −999 不相交；clampi 本体不动）。
- 黑市不上架（D9）：不进金币经济，黑市链零改动。保底/替代获取不做（D10）：tracker #6 ❓用户裁定，`_card_system.md` §9 记开放问题。
- 预热：`enumerate_prewarm_variants` ④段升华变体（表有 sublime_desc 角色各 1+通用兜底 1，零 rng 单源，T9 锁——与终修判据同口径）。

---

## 5. 渠道矩阵（10 存量 + 3 新 + 无尽深度阶梯）

设计真源 `_channels.md`；实现 R247 meta+ui 泳道。**存量 10 行渠道零改动**（用户明示「可维持」；verify_feedback 672/672 回归绿）。

解锁判定链 `Meta.is_character_unlocked`（meta_manager.gd，if/elif 固定次序）与文案链 `menu_screen.gd _locked_hint()`（:1544 单源）同位同序；新门型 `unlock_endless_depth` 插 hard_clear 之后、kills 之前（:1564-1573）。

| # | id | 角色 | 渠道类型 | 判定键 | 选人卡锁定文案 |
|---|---|---|---|---|---|
| 1 | sentinel | 哨兵-9 | 初始免费 | unlock_map:空 | （恒解锁） |
| 2 | veles | 裂变者·薇拉 | 关卡通关 | unlock_map:world_grass | 「通关『晴空草原』解锁」 |
| 3 | bulwark | 堡垒·磐 | 关卡通关 | unlock_map:world_frost | 「通关『寒霜冰原』解锁」 |
| 4 | mank | 腐化者·莽 | 关卡通关 | unlock_map:world_swamp | 「通关『翠毒沼泽』解锁」 |
| 5 | fission | 改造者·枢 | 关卡通关（分档） | unlock_normal_clear | 「通关普通难度解锁（首关10 波）」 |
| 6 | echo | 回响·伊可 | 关卡通关（分档） | unlock_hard_clear | 「任意地图·困难难度通关解锁」 |
| 7 | vera | 毒系学者·薇拉 | 挑战（击杀） | unlock_kills:500 | 「图鉴累计击杀 500 解锁」 |
| 8 | noah | 召唤师·诺亚 | 成就 | unlock_achievement:wave_20 | 「成就『深入敌阵』解锁」 |
| 9 | ranger | 游侠·岚 | 直购 | unlock_price:80 | 「结晶解锁 80（当前 N）」 |
| 10 | zero | 演算者·零 | 直购 | unlock_price:160 | 「结晶解锁 160（当前 N）」 |
| 11 | **medic（新）** | 战地医师·苏 | **成就·无尽深度** | **unlock_endless_depth:20** | 「任意无尽模式深入 20 层解锁（当前 M）」 |
| 12 | **vortex（新）** | 坍缩者·汐 | **成就·无尽深度（终局）** | **unlock_endless_depth:50** | 「任意无尽模式深入 50 层解锁（当前 M）」 |
| 13 | **reaper（新）** | 处刑者·刈 | **直购** | **unlock_price:240** | 「结晶解锁 240（当前 N）」 |

- M=`Meta.best_endless_depth()` 实时值；N=`Meta.crystals` 余额。渠道类型覆盖：成就 ✓（noah+medic/vortex）、关卡 ✓（×5）、直购 ✓（ranger/zero+reaper）、挑战 ✓（vera）、免费 ✓（sentinel）。
- 三新角色生态位（`_channels.md` §1，各取未占用位）：medic=全表首个治疗/减伤（回复 30% max_hp+4s 减伤 ×0.5 与无敌独立）；vortex=聚怪（3s 320px 向心 70 冲量每 2 物理帧+窗尽 220px 120% 末爆）；reaper=伤害轴增益窗（6s extern atk+50% 启停遍历失效面板）。表行实落 `character_table.gd:133/:141/:149`（cd 120 全留，verify 遍历锁覆盖）。
- 门-成就同步：深度 20 落账 ⇔ `endless_depth_20` 达成 ⇔ medic 解锁（同源同阈值，`r246_meta_cases` M5m 锁）。

### 5.1 无尽深度成就阶梯（4 档）

- 计数器：`Meta.best_endless_depth()`（`meta_manager.gd:618`）——跨地图×跨 #1/#2 难度分档键取最大，顺手根治「困/狱局无尽深度对读口不可见」盲区（旧分图读口 `endless_depth()` 保留，测试锚定不迁移）。
- 阶梯（`meta_manager.gd` ACH_TIER_TABLE 表尾，id 走 `<type>_<target>` 展开器与手写 11 条零交集）：

| 档位 | id | 名称 | 奖励 | 分配 |
|---|---|---|---|---|
| 10 层 | endless_depth_10 | 初窥深渊 | 0 | 纯成就档（入门路标） |
| 20 层 | endless_depth_20 | 渊底回声 | 0 | **解锁 战地医师·苏**（与角色门同源同阈值） |
| 30 层 | endless_depth_30 | 噬渊而行 | 0 | 纯成就档（中段里程碑） |
| 50 层 | endless_depth_50 | 深渊尽头 | 100 | **解锁 坍缩者·汐** + 链终 100 结晶 |

- 预算与容量：全表成就奖励 1465→**1565**（G1l 锚定）、封顶注释 1500→**1600** 同步；全表条数 **135**（G1k 锚定）；成就三处注册全落（模板行/_counter_value/_check_achievements counters——漏一即永久漏检）。
- UI：成就墙归类 `endless_depth:"进阶"`（menu_screen.gd:57）；「·新」角标订阅 achievements_changed 对 {20,50} 档置位；存档零新增键（门=派生谓词+既有键；reaper 复用 unlocked_characters）。

---

## 6. 实现落点（泳道 × 文件）

四实施员互斥泳道（总监拆解），跨泳道接口先行定义、集成阶段校验对齐；终修轮（tracker :1344）五项收口单列：

| 泳道 | 文件 | 落点摘要 |
|---|---|---|
| skills | `scripts/entities/player/player.gd` | `skill_sublime` 位（:91）+ `enable_sublime()`（:1473，fission 分支含追溯回填 ×0.5 帽 500）；十角色升华分支（照设计文档逐档数值）；三新角色 activate_skill+三档着色；`_static_init()` 击杀账本（:26）+ `_kill_snap()`（:43）；`resonance_snapshot/restore_resonance`（:1740/:1745）；set_character 复位区清位+extern 还原 |
| | `scripts/combat/weapon/weapon_base.gd` | `extern_buffs` 字段+四读点（rof/spd/size 尾乘+atk/crit 面板乘区）——非升华恒空零位移 |
| | `scripts/gamefeel/elemental_fx_layer.gd` | `_on_poison_cloud_cast` 追加 p_dur 缺省 6.0（升华 7s 窗 fx 同步） |
| | `autoload/event_bus.gd`（跨泳道先行） | `poison_cloud_cast` 信号+第 3 参 dur（信号参数不可带缺省，缺省放 emit 包装 6.0，全仓两参调用兼容） |
| meta | `FEEDBACK_TRACKER.md` | 先登记（#5 行原地更新不删行）：R247 落地明细+验证口径 |
| | `scripts/meta/character_table.gd` | 10 角色 sublime 两键全量落表；CHARACTERS 尾部 +3 新角色（:133-153）；头注解锁矩阵补新门型+直购 ×2→×3+升华键契约注 |
| | `scripts/meta/meta_manager.gd` | 六处：best_endless_depth()（:618）/ACH_TIER_TABLE +endless_depth 族/成就三处注册/is_character_unlocked 加 elif/预算注释 1565 封顶 1600/容量注释 135 |
| | `tests/runner/test_r247_endless_channel.gd`（+cases） | 新套件（§7） |
| | 存量锁同步 | `verify_feedback_cases.gd` count 10→13+文案；`r191_rework_cases.gd` ≤1500→≤1600 |
| cards | `scripts/cards/card_generator.gd` | CardKind.SUBLIME=6（:17）；`_sublime_rng`（:23）+SUBLIME_CHANCE（:27）+reseed_sublime()（:54）；_make/_build_sublime_card（读表拼文案）；掷点守卫链（:176-180）+`_sublime_available`（:919，**终修①判据收紧为仅 sublime_desc 非空**）；generate_candidates 尾段注入+三处豁免+curse_last 收紧；apply_choice SUBLIME 分支；enumerate_prewarm_variants ④段；D3 缩放域零改动 |
| | `scripts/loop/game_loop.gd` | serialize_run 单键 "sublime"（:2798，**终修②走 `player.resonance_snapshot()` 同构口** :2769-2770，duck 手组兜底保留）；_restore_run_state set_character 后回填（:2938，clamp 0..500）；start/continue reseed_sublime（:1557/:1561/:2833） |
| | `scripts/loop/auto_idle_strategy.gd` | score 首行 SUBLIME 特判 998.0（挂机必选） |
| | `tests/runner/test_r246_sublime.gd`（+cases） | 新套件（§7；终修+T6 变体 68→72 断言） |
| ui | `scripts/ui/palette.gd` | RARITY_SUBLIME #ff2e63（:102）+RARITY_COLORS 扩 [4]+五档名（:108-109） |
| | `scripts/cards/card_select_ui.gd` | KIND_NAMES 追加「升华」（类别行自动「升华 · 传说」）；圆珠 range(4)→range(5)；highlight 对 rarity==4 跳过描金（D11） |
| | `scripts/ui/texture_factory.gd` | type_icon 加 kind 6 分支（红环菱形，勿重蹈 R185 kind5 灰菱前科）；skill_icon 加 medic/vortex/reaper 三 case |
| | `scripts/ui/hud.gd` | 技能键 `skill_sublime` 态读口（:304-311 has_method 守卫）→ 独立红环覆盖层 SkillSublimeRing（不占 fg modulate 状态机；无技能角色置灰不动） |
| | `scripts/ui/menu_screen.gd` | ACH_TYPE_CATEGORY 登记 "endless_depth":"进阶"（:57）；`_locked_hint()`（:1544）单源+unlock_endless_depth elif（:1564-1573，与 meta 判定链同位同序）；「·新」角标订阅 |
| | `tests/runner/test_r246_ui.gd`（+cases） | 新套件（§7） |
| 修复轮 | `player.gd` | 诺亚 `_skill_summon_orbs` 入口先 `_summon_restore()`（:1933）；游侠瞬步改活动区钳制（:1575）——§2 ①② |
| 终修 | tracker :1344 五项 | ①card_generator `_sublime_available` 判据收紧（P0 破洞卡）；②game_loop serialize 走 resonance_snapshot() 同构口（快照双源）；③`fission.md` §6.2 两处口径勘误（int(round())+计数器口径）；④诺亚舰弹数值断言补全（G8m/n）；⑤meta 泳道回归套件补建 `test_r246_meta.gd`（36 断言）+ r246_sublime T6 变体 |
| 集成 | `tests/runner/r212_carddigest_cases.gd` | dots 预建 4→5 存量锁同步（ui 泳道 notes 钦定口径；本轮复跑 41/41） |

跨泳道接口对齐：cards→skills `enable_sublime()` 零参签名一致；game_loop 快照/回填与 skills `resonance_snapshot()/restore_resonance()` 口径对齐（终修②后为同构单源）；ui HUD 红环读口 `skill_sublime` 与 skills 字段名一致（四泳道零撞名）。

---

## 7. 测试证据（强门禁 · 终修后复验全绿）

引擎命令（exit 0=全过；探针另加 `APPDATA=E:/Code/Agent/Infinite-Fission/.qa_sandbox_r243` 沙箱，照探针头部注释口径）：

```
E:\Code\Agent\Infinite-Fission\android_export\Godot_v4.3-stable_win64.exe --headless ^
  --path E:\Code\Agent\Infinite-Fission\repo -s tests/runner/<套件>.gd
```

### 7.0 QA/评审结论与终修链路

- **终修前**（QA×3+评审×2 并发）：技能 **pass（0 项失败）**；卡池 **fix-needed**——QA 双报+评审 high「三新角色破洞升华卡」（P0）+ 评审 low「快照双源」+ QA/评审 low「fission.md 口径勘误」；解锁 **pass**；玩法 **needs-work**（低优项见 §8）；终审 **needs-work**。
- **终修 1 轮**（tracker :1344 ✅ R247 终修）：上述可修项五项全收口（§6「终修」行；另补 QA low 未竟项诺亚舰弹断言、meta 泳道回归套件补建）。
- **终修后复验门禁（本轮 2026-10-08 交付日实跑，下两表）**：18 套件 **1815 断言全绿、exit 全 0** → 卡池转 **pass**，终审 **deliverable**；玩法 QA 低优未消化项转 §8 遗留（均为 low 级跟进、非缺陷）。

### 7.1 新套件与修复探针（本轮实跑）

| 套件 / 探针 | 断言 | 结果 | exit | 覆盖 |
|---|---|---|---|---|
| `test_r246_skills.gd`（skills） | 139 | **139/139 PASS** | 0 | G0 契约+十角色两态 G1-G10+新角色 G11-G13+诺亚舰弹 G8m/n（终修④）；真 GameLoop 夹具；量值断言直调技能函数；真派发击杀含账本路径 |
| `test_r246_sublime.gd`（cards） | 72 | **72/72 PASS** | 0 | T1-T10 照 `_card_system.md` §7+S 组 game_loop 接线；0.001% 复现用定种流扫描命中位消耗法；T6 变体=三新角色掷中不上架+源级锚（终修⑤） |
| `test_r246_ui.gd`（ui） | 41 | **41/41 PASS** | 0 | G1 品质表/G2 卡面/G3 跳描/G4 图标/G5 HUD 红环/G6 选人卡全路径锁定行 |
| `test_r247_endless_channel.gd`（meta） | 40 | **40/40 PASS** | 0 | G1 表结构 13 项/G2 聚合读口含脏档守卫/G3 门阈值边界+分档/G4 结算全链+结晶对账/G5 购买 240 三拒/G6 旧档兼容+零新增键 |
| `test_r246_meta.gd`（终修⑤补建） | 36 | **36/36 PASS** | 0 | M1 表完整性/M2 新角色条目/M3 升华键×掷卡一致性（终修①回归锁）/M4 无尽深度成就门/M5 13 角色解锁矩阵+门-成就同步 |
| `tests/probe_r244_skill_stack.gd`（诺亚修复） | 20 | **20/20 PASS** | 0 | ①②④ 已修期望+③⑤ 回收链/幂等对照（§2 ①） |
| `tests/probe_r246_ranger_blink.gd`（游侠修复） | 13 | **13/13 PASS** | 0 | 上向停上界零回弹/中段 260px 全额/下向横向不受影响+负验证（§2 ②） |

新套件小计 **361 断言全绿**（328 套件+33 探针）。

### 7.2 存量回归清单（各泳道 notes 留待集成阶段统一复跑——本轮全部实跑）

| 存量套件 | 断言 | 结果 | exit | 锁定内容 |
|---|---|---|---|---|
| `test_verify_feedback.gd` | 672 | **672/672 PASS** | 0 | 品质口径锁+角色表 count==13+全角色 cd==120 遍历 |
| `test_pkg4.gd` | 116 | **116/116 PASS** | 0 | 金 500 抽分布锁（升华掷流零扰动） |
| `test_r220_cardprewarm.gd` | 32 | **32/32 PASS** | 0 | 4 档 scale 硬锁（D3 不扩档——已保持） |
| `test_r212_carddigest.gd` | 41 | **41/41 PASS** | 0 | 卡面复用/dots 显隐（dots 预建 4→5 存量锁同步后口径） |
| `test_qa_r220_mode.gd` | 67 | **67/67 PASS** | 0 | 卡池模式基线 |
| `test_market_supply.gd` | 25 | **25/25 PASS** | 0 | 黑市/供给链（D9 零改动应保持绿） |
| `test_r191_rework.gd` | 131 | **131/131 PASS** | 0 | 成就整案（奖励总账 ≤1600 封顶同步后口径） |
| `test_r187_rework.gd` | 232 | **232/232 PASS** | 0 | 技能重做锁（player.gd 大改后回归，修复轮点名复跑） |
| `test_qa_r220_firephase.gd` | 49 | **49/49 PASS** | 0 | 开火相位/节拍锁（veles/echo/zero rof 曲线相关） |
| `test_high_stack.gd` | 46 | **46/46 PASS** | 0 | 叠层链（noah 共鸣层/mank 精华层相关） |
| `test_mirror_muzzle.gd` | 43 | **43/43 PASS** | 0 | 镜面/枪口（副本/镜面与 rof 通道正交性） |

回归小计 **1454 断言全绿**。**合计本轮实跑 18 套件 1815 断言全绿、exit 全 0。**

> **r212_carddigest 同步注记**：集成首跑（终修前）40/41——唯一 FAIL 为「dots 预建 4 珠」存量硬锁（r212_carddigest_cases.gd:146/150）被圆珠 range(4)→range(5) 扩珠打破，按 ui 泳道 notes 钦定口径同步 4→5 后收口；本轮复跑 41/41 exit 0。功能面无缺陷（红卡 5 珠显隐由 r246_ui G2 正向锁定）。
>
> **已知无害告警**：GameLoop 夹具类套件退出时恒挂 1 个引擎侧 GDScriptFunctionState（ObjectDB leak WARNING）——本轮复跑同状（skills/verify_feedback/r187/r191/r212/qa_r220_firephase/high_stack/mirror_muzzle/market_supply/probe_r244 等日志可见），test_cd_pace 全量复跑同状先例，非本轮引入；不影响 exit 0 判定。

---

## 8. 遗留项与建议（P0=下轮先做，P2=可选）

1. **【已收口·原 P0】三新角色升华卡破洞**：终修①`_sublime_available` 判据收紧为仅表 `sublime_desc` 非空（撤 has_skill 放行），medic/vortex/reaper 不再掷出空卡——r246_sublime T6 变体+r246_meta M3 双回归锁。若后续为三新角色补升华设计，落表 sublime 两键即自动纳入掷池（判据数据驱动，零代码改动）。
2. **【P1·用户裁定】0.001% 保底/替代获取**（tracker #6 ❓）：纯字面=期望 10 万批一遇。设计侧已留开放问题（`_card_system.md` §9：软保底/成就补偿/结晶直购三案）；同案：金档改名「辉煌」的用户确认（回退方案红档改「神话」单行反转）。
3. **【P1·数值校准】fission 满层时点为估算**：500 层帽按「20 波局 600~900 杀、第 15 波≈450 杀」估算；实测若中位击杀 <450，按 `fission.md` §5.2 预置刀口改 400 层帽（每层 +0.163%）保持 +65% 终值。同类：ranger 路径命中数假设（均 4 敌）建议用 DebugStats `shadow_dash_sweep` 遥测校准。
4. **【P2·QA/评审低优未消化项】**（tracker :1344「不修项」，玩法 QA needs-work 的全部残余，均 low 级跟进、非缺陷）：①AoE `query_circle` 粗判触达（全仓引擎惯例，独立工单）；②GameLoop 夹具 ObjectDB 告警（引擎侧先例，§7 注记）；③weapon_base.gd 跨泳道改动（总监 files list 外，审计线索已在 skills 泳道 notes 声明）；④磐岩护壁 HUD 可视化（P2 登记）；⑤0.001% 保底与「放弃批」遥测（同 #6 用户裁定挂起）；⑥升华机制同向趋势（多角色升华均为「越打越强」型，设计观察项，待用户反馈）；⑦qa_r247_channel_probe.gd（核实全仓已不存在，无需删）。
5. **【P2·独立工单】balance_tables.tres 僵尸镜像清理**：`rarity_weights` 全仓零消费 + `data_validator.gd:409-412` 按 `int()` 截断累加——红档概率走代码常量已定案，僵尸键接线或删除留独立工单（`_card_system.md` §8）。
6. **【P2·表现层可选】bulwark 三 EventBus 信号未落**：`stomp_pulse/stomp_barrier_gained/stomp_barrier_soak` 不在总监 files list，护栏无消费者不缺；fx 层需「余震扩散环/护壁碎屑」再补。
7. **【P2·自定值登记】vortex 牵引参数**：320px/冲量 70/每 2 物理帧一拉为规格未给定处的自定值（spec 只给「向心牵引+末爆 220px 120%」），建议实测后回归 `_channels.md` §1.2。
8. **【P2·测试口径备忘】**：①skills 套件名取 `test_r246_skills.gd`（与 cards `test_r246_sublime.gd` 不冲突）；②`-s` 入口编译早于 autoload 的项目坑在全部新套件遵守（入口只 load cases 体）；③11 个存量套件为集成阶段统一复跑口径（泳道硬约束禁跑他人套件），终修后已全量补跑全绿（§7.2）。
9. **【P2·统计可选】图鉴/局外统计**：`Meta.sublime_total` 跨局累计、红卡图鉴条目、「错过红卡」遥测（`sublime_card_rolled`）均设计预留未实现（`_card_system.md` §6，不进首版验收）。

---

*R246 交付文档 · 2026-10-08 · 终修后复验以 §7 本轮实跑为准（18 套件 1815 断言全绿 exit 0；终审 deliverable）。*

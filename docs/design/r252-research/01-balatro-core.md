# Balatro 核心机制调研——为《Infinite Fission》机制向遗物供料

**摘要**：Balatro 的构筑深度不在单卡数值，而在「加算池 → 乘算池 → 条件触发」的三层结算结构——每张小丑牌都在回答"往哪一层、以什么条件注入价值"。它的 build-around 中心件大多不提供数值，而是改写规则本身或复制/吞并其他构筑件，让零散词条产生共振，这正是"困难难度词条堆不动"最直接的解法方向。本文 13 条机制均对照过本作 `listen_events + effect_id + params` 遗物骨架，多数只需在 `relic_handler` 增加消费点，个别需要新的交互系统。

## 调研口径
- 在线调研（2026-10-10）：balatrowiki.org `/jokers` 与 `/economy` 两轮原文抓取；Balatro Wiki Fandom 激活顺序案例；WebSearch 汇总（计分公式、排序经验法则、ante 曲线）。
- 本作现状：下列引用均为本会话实读的仓库文件。

## 本作现状速览（适配落点参照）
- 遗物骨架：`RelicData`（`resources/relics/*.tres`）字段 `id / display_name / description / rarity / listen_events / effect_id / params / unique`，现有 18 件（例 `resources/relics/REL_ATTACK_CDR.tres`）。
- 事件消费点：`scripts/loop/relic_handler.gd:225-230` 绑定 `wave_started / wave_cleared / enemy_killed / player_hit / damage_resolved / card_chosen`，effect 分支 41 处；`_on_damage_resolved` 收 `DamageResult`（同文件 :444）。
- 数值护栏：五层防御纵深 + `pool_class ∈ {ADD, MULT, LOCAL, REACTION, MECHANIC, ELEMENTAL}`、pool_id 封闭枚举（`docs/analysis/A2_numeric_framework.md:27,197`），同池多实例加算合并（:151）。
- 词条条件门：`required_forms / required_weapon / requires_trait / exclusive_group`（`scripts/cards/card_generator.gd:435-500`）。
- 武器族节拍：五武器定位两两不重叠（`docs/design/R187_WEAPON_REWORK.md`）——W1 手枪跳弹增值、W4 激光聚焦/灼焦、W5 棱镜白板复制、W6 导弹引信标记、W7 集束引爆（W6 引信需 W7 引爆＝天然双件连携）、W8 环绕附着。

---

## 1. 双池结算与乘区层级（Chips × Mult 的层级感）
- 原作规则：得分 = Chips × Mult，小丑从左到右依次结算，+Chips/+Mult 先累积、XMult 后放大，顺序改变结果（Fandom 激活顺序案例：40 × ((4+4)×2) = 640 vs 反向 480）。
- 构筑价值：层级感就是构筑语言——加算件是地基、乘算件是天花板，玩家能读懂自己引擎有几层、瓶颈在哪层；"+Mult 放左、XMult 放右"是可习得的最优解知识（基础 10、+20 与 ×2：先加后乘 60 vs 先乘后加 40）。顺序本身就是决策。
- 本作适配改造：本作已有 ADD/MULT 池分层（A2 框架），缺口是**稀缺的终盘条件乘区**与"层间转化件"：设计一类遗物把本武器族某条加算词条「转写」为条件乘区（如"对灼焦层≥3 的敌人，该族 flat 池产出并入乘区池结算一次"），让加算堆积产生质变；同时像原作一样把乘区类遗物数量压到极少数，保住稀缺层级。
- 实现代价预估：需新消费点（`scripts/core/damage/modifier_stack.gd` 暴露"池转化声明"的读取口；池分层数据可直接走 params）。

## 2. 条件触发计费引擎（按牌型/花色/时机计费）
- 原作规则：小丑普遍不给无条件数值，而是"每打出一张红桃 +Mult""每打出同花 XMult"式的条件计费（balatrowiki.org 卡池原文通例）。
- 构筑价值：条件即构筑语法——玩家为"让条件高频成立"重组打法（堆花色、换牌型），而非无脑叠数值；条件本身定义 build 身份，同一数值换个触发条件就是两条完全不同的构筑轴。
- 本作适配改造：把弹幕事件整理成"计费语法"：按武器族命中（W4 灼焦层挂上时）、按元素反应类型结算时、按暴击/跳弹末段命中、按敌人精英词缀标签击杀。例遗物「同调谐振」：`damage_resolved` 携带反应类型时叠层、切换武器族清零——玩家为喂条件而绑定武器搭配（消费入口 `relic_handler.gd:444`）。
- 实现代价预估：需新消费点（`DamageResult` 需补 reaction_type / crit / bounce 末端等语义字段；事件订阅骨架现成）。

## 3. 规则改写中心件（Four Fingers / Smeared Joker）
- 原作规则：Four Fingers「同花与顺子可由 4 张成牌」；Smeared Joker「红桃与方片算同一花色、黑桃与梅花算同一花色」（balatrowiki.org 原文）。
- 构筑价值：不改任何数值、改**判定规则本身**——一件卡让一批原本不达标的条件集体达标，是全卡池最强的 build-around 中心件："变废为宝"瞬间产生的构筑感最强，且天然鼓励二周目重玩（围绕新规则重排全部词条）。
- 本作适配改造：设计"规则补丁"遗物：①「同源并流」——W6 引信标记不再要求 W7 引爆、任意爆炸事件可引爆（改写 `R187_WEAPON_REWORK.md` 的双武器连携约束）；②「宽口径」——`required_weapon` 数组放宽为"任意武器族"或 `required_forms` 放宽一档（消费点即 `card_generator.gd:435-500` `_form_allows`）；③「满层降阶」——某 MECHANIC 词条满层质变所需层数 −1。
- 实现代价预估：需新消费点（词条装配判定处增加 rule_patch 读取；规则声明仍可用 params 数据驱动）。

## 4. 复制件粘合剂（Blueprint / Brainstorm）
- 原作规则：Blueprint「复制右侧小丑的能力」；Brainstorm「复制最左侧小丑的能力」（balatrowiki.org 原文）。
- 构筑价值：自身零数值、纯结构件——把"遗物摆放/获取顺序"变成构筑决策；它是所有成型 build 的万用胶水，也是抽到重复件的天然答案，成局率最高的一类卡。
- 本作适配改造：「镜面残像」——激活时复制"已持有遗物中最新一件"的 `effect_id + params` 快照（或复制最左槽位）。与 W5 棱镜"复制武器"的心智对称（R187：白板镜面军团）；与现有 `REL_ECHO`（选卡后 25% 把该卡复制到随机武器）区分：ECHO 复制的是一张卡，本条复制一件已生效遗物的完整逻辑。
- 实现代价预估：需新系统（effect 代理：relic_handler 需支持以 A 遗物身份调用 B 遗物的 effect 分支，并隔离 `_owned_effect` 查询）。

## 5. 成长-重置引擎（Ride the Bus / Green Joker）
- 原作规则：Ride the Bus「连续打出无头像牌则 +1 Mult，一旦打出即重置」；Green Joker「每打一手 +1 Mult，每次弃牌 −1」（balatrowiki.org 原文）。
- 构筑价值：成长自带**破坏条件**＝内建的风险契约：奖励承诺一种打法纪律（不打头像/不弃牌），玩家在"纪律收益"与"自由度"间实时取舍；重置同时是无数值平衡阀——成长上限由玩家自己维持。
- 本作适配改造：把破坏条件设计为"构筑自发行为"而非惩罚：①「无伤引擎」——不受伤每击杀 25 敌叠 +1 层乘区、受击清零（`enemy_killed`/`player_hit` 均已接入 `relic_handler.gd:227-228`）；②「不换装引擎」——同场不切换武器族每波叠层、切族清零（制造对五武器族的承诺粘性）。与 `REL_KILL_FRENZY`（击杀后 3 秒窗口、上限 5 层）区分：FRENZY 是短窗缓存，本条是整局成长＋破坏重置。
- 实现代价预估：纯数据驱动（事件/层数/清零均可 params 表达，先例 REL_KILL_FRENZY、REL_MOMENTUM）。

## 6. 重触发结算（Hack / Sock and Buskin）
- 原作规则：Hack「重触发打出的 2/3/4/5」；Sock and Buskin「重触发全部打出的头像牌」（balatrowiki.org 原文）。
- 构筑价值：重触发不产生新倍率，而是**把既有结算流程再跑一遍**——收益与你已建成的整个引擎成正比：前期废卡、成型后放大器；"什么被重触发"决定它喂哪个 build（Hack 喂低牌流、Sock 喂头像流），天然分流构筑。
- 本作适配改造：「回响弹头」——命中为本弹幕对同一敌人的最后一跳时（W1 跳弹收束／W4 激光灼焦终段），把本次命中的**词条加算段**重结算一次；只重触发加算与触发型词条、不重触发反应与乘区（防乘区平方爆炸，需硬护栏）。这是把 W1"跳弹增值"定位轴机制化。
- 实现代价预估：需新消费点（`scripts/core/damage/damage_pipeline.gd` 的"重入结算"开关＋跳数语义字段；注意全仓唯一 `inject_relic_pools` 调用点在 `projectile_base.gd:310`，激光路径需同步）。

## 7. 场上滞留物暗价值（Baron / Shoot the Moon 的 held-in-hand）
- 原作规则：Baron「手中每张 K 给 X1.5 Mult」；Shoot the Moon「手中每张 Q 给 +13 Mult」——价值发生在**未打出的牌**上（balatrowiki.org 原文）。
- 构筑价值：把"留在手里的资源"从死库存变成引擎燃料，催生囤积流：为 K 留手而牺牲出牌节奏——收益结构与主玩法（打出）错位，构成加算/乘算之外的第三条构筑轴。
- 本作适配改造：把"手牌"映射为弹幕场的滞留物：①「殉爆尸潮」——敌人残骸每具存场 +0.5% 乘区、波末清零（囤不捡 vs 收割的节奏抉择）；②「存场弹」——W8 环绕球每球常驻 +1% 乘区（与 W8 等级联动，球数据在武器内现成）。
- 实现代价预估：需新消费点（残骸/滞留物需要周期统计事件；先做 W8 环绕球版本则接近纯数据驱动）。

## 8. 牌型等级的纵向承诺（Planet 星球卡）
- 原作规则：星球卡永久提升某一牌型的基础 Chips×Mult 档位，整局持续；Supernova「该牌型本局打出次数计入 Mult」、Constellation「每次使用星球卡 +X0.1 Mult」都建立在这套承诺系统上（balatrowiki.org 原文）。
- 构筑价值：把"我用什么牌型"从每次选牌的战术选择升格为**整局战略承诺**——等级只回馈被反复使用的牌型，投入越集中回报越陡，制造"早锁轴"与"留后路"的核心抉择。
- 本作适配改造：「族谱烙印」——某武器族命中累计满阈值后该族"族级 +1"，提升该族基础节拍参数；走 `scripts/combat/weapon/laser_weapon.gd:173-178` 已有的 `_leveled_param` 通道（各武器参数本就有 levels 表惯例）；族级仅对单一已烙印族生效，换主轴即废。
- 实现代价预估：需新消费点（族级存档字段＋命中累计统计；参数读取通道现成）。

## 9. 结余利息经济（$5 结余 +$1／波，上限 $5）
- 原作规则：回合结算时「每持有 $5 得 $1、每回合上限 $5」，盲种派息 $3/$4/$5/$8，另有 Golden Joker「每回合结束 +$4」等经济件（balatrowiki.org `/economy` 原文）。
- 构筑价值：利息把"延迟满足"正式机制化：金币从购物货币升格为**可成长的第二资源池**，催生攒钱波/爆发波节奏与"先攒利息后换引擎"的经济流构筑；上限 $5 保证它永远只是侧轴。
- 本作适配改造：本作商店/金卡已存在（`REL_BLACK_MARKET.tres`：金卡价 260、`listen_events=[wave_cleared]`），补「低息存款」遗物：波末按金币结余给利息（上限封死），与既有波末奖励错位竞争，制造"这波吃利息还是吃补给"的抉择。
- 实现代价预估：纯数据驱动（wave_cleared 已监听、金币结余可读；预算/上限 params 先例见 REL_ATTACK_CDR）。

## 10. 吞并-献祭契约（Ceremonial Dagger / Madness）
- 原作规则：Ceremonial Dagger「选定 Blind 时摧毁右侧小丑，把其双倍卖价永久加为本卡 Mult」；Madness「小/大盲开始时 +X0.5 Mult 并摧毁一件随机小丑」（balatrowiki.org 原文）。
- 构筑价值：最强风险契约形态——**以构筑收缩换指数成长**：摧毁不可逆，"吃谁"本身就是最大决策；随机版（Madness）则制造"带它上场就接受残缺阵容"的赌性。献祭让"删卡"从损失变成资源转化。
- 本作适配改造：①「熔炉契约」——激活时吞噬玩家自选的一件已持有遗物，按其稀有度折算为永久乘区层数；②「血祭」——每波开始 +1 层乘区、随机移除一个词条卡位（持有上限 −1）。现有 `REL_GAMBLER`（四选一但第 4 张带诅咒）是低配风险契约，本条推到"不可逆献祭"档。
- 实现代价预估：需新系统（遗物/词条移除生命周期：owned 列表删除＋常驻位反激活＋`scripts/meta/run_save.gd` 存档快照迁移）。

## 11. 单次结算的高风险乘区（Glass 牌）
- 原作规则：玻璃牌「得分时 X2 Mult，但 1/4 概率被销毁」；Glass Joker「每张玻璃牌被毁 +X0.75 Mult」——销毁本身又成为另一件卡的条件燃料（balatrowiki.org 原文）。
- 构筑价值：风险被压到**每次结算的粒度**而非整局属性：玩家主动决定何时打出玻璃牌（危机时刻 vs 平时），且"销毁"不是纯损失而是另一件卡的燃料——风险与收益在同一次掷骰里纠缠，链式成构筑。
- 本作适配改造：与现有 `REL_GLASS_CANNON`（全局 +40% 伤／−25% 生命的静态契约）区分，做**事件粒度**版本：「玻璃弹头」——暴击乘区翻倍、但该次暴击有概率使遗物碎裂（层数损耗或永久失效）；配套「碎裂收藏家」每碎一次叠成长。决策点落在"何时让暴击走玻璃弹头"。
- 实现代价预估：需新消费点（遗物自我损耗生命周期；概率掷骰先例 `REL_ECHO` 的 25% 复制已存在）。

## 12. 规则反转检查点（Boss Blind）
- 原作规则：Boss Blind 在数值压力之上叠加**规则反转**（禁用花色、强制手牌数等直接针对你的构筑 debuff）；小/大盲只有纯分数要求（balatrowiki.org；WebSearch 汇总"Boss blinds debuff your build"）。
- 构筑价值：把检查点从"数值够不够"变成"构筑有没有第二轴"：玩家输得明白（知道该补哪类件）、赢波靠"绕过规则"而非"堆数值"——对"困难难度构筑不起来"最直接的答案：给构筑以"被考验"而非"被碾压"的体验。
- 本作适配改造：困难波/Boss 走"反转"而非"膨胀"：①禁用某元素反应（逼换元素轴）；②精英词缀免疫本局使用率最高的词条池；③"仅 W1 族/仅 W4 族增伤"并给足补偿。本作已有 elite_affix 与 boss_themes 数据面（qa_r15_elite_affix／boss_themes 测试存在），反转规则作 params 挂进波次/词缀配置。
- 实现代价预估：纯数据驱动～需新消费点（免疫/禁用判定需在 damage_pipeline 与词缀系统各开一个读取口）。

## 13. Ante 断层曲线与引擎更替窗口
- 原作规则：分数要求随 Ante 指数级抬升，而加算类构筑是线性积累——曲线强制玩家在 ante 中段把"平价小丑"整体替换为"指数引擎"（WebSearch 汇总 ante-scaling 压力）。
- 构筑价值：换引擎是 Balatro 中期最大的决策快感来源：断层制造"旧构筑必然失效"的确定性危机，配合卖件回收让"推倒重来"成为策略而非失败——构筑寿命被曲线显式分段。
- 本作适配改造：把困难难度波次血量做成"乘区断层"（`resources/waves` 配置面已有）：某波起血量跳档使纯加算词条 DPS 明显不足；断层波前插入"重掷窗口"——商店刷新折价、遗物回收价上浮，给玩家正式的"换轴仪式"。断层位置由 waves params 配置，普通/困难分档。
- 实现代价预估：纯数据驱动（waves 与商店配置；回收折价若缺商店钩子则加一个 wave_cleared 分支）。

---

## 素材来源
- balatrowiki.org `/jokers`：Four Fingers、Smeared Joker、Vampire、Ceremonial Dagger、Ride the Bus、Green Joker、Hack、Sock and Buskin、Blueprint、Brainstorm、Baron、Shoot the Moon、Supernova、Constellation、Glass Joker、Madness、Campfire 等原文规则（2026-10-10 抓取）。
- balatrowiki.org `/economy`：利息 $5→$1、每回合上限 $5、盲种派息 $3/$4/$5/$8、Golden Joker +$4（2026-10-10 抓取）。
- Balatro Wiki Fandom「Guide: Activation Sequence」：40 × ((4+4)×2)=640 vs 480 顺序案例；WebSearch 汇总：Chips×Mult 公式、"+Mult 左 / XMult 右"经验法则、ante 指数曲线。
- 本作现状均为本会话实读：`resources/relics/*.tres`、`scripts/loop/relic_handler.gd`、`scripts/cards/card_generator.gd`、`scripts/combat/projectile/projectile_base.gd`、`scripts/combat/weapon/laser_weapon.gd`、`docs/analysis/A2_numeric_framework.md`、`docs/design/R187_WEAPON_REWORK.md`。

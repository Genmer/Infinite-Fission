# R252 调研：吸血鬼幸存者 —— 进化链/超武合成/金币树 的机制素材

三句话摘要：吸血鬼幸存者的构筑可预期性来自「满级武器 + 指定被动 + 精英宝箱」的进化契约，每条超武链把一个看似无关的被动变成催化剂，玩家从第一分钟就知道终点是什么。机制向遗物的直接原型是 Arcana 塔罗（Gemini 镜像、Waltz of Pearls 弹跳、Twilight Requiem 到期引爆×Curse 倍率、Sarabande of Healing 治疗转伤害），而 Torrona's Box 第 9 级与 Banish/Seal 展示了「风险契约 + 随机操纵层」如何让高难玩家自己校准难度。金币树用「同节点越买越贵」的价格曲线把局外成长压成广度优先的漏斗，并把双戒指/Metaglio 这类局外遗物反哺进局内作为顶级超武材料，形成局外-局内资源闭环。

> 调研方法：WebSearch 检索 VS Wiki（Fandom / vampire.survivors.wiki）、Steam 社区进化表、IGN PowerUp 指南等（详见文末来源）；本作适配部分对照了仓库实况：`repo/scripts/core/data/resources/relic_data.gd`（遗物 listen_events + effect_id + params 契约）、`repo/scripts/combat/trait/builtin/trait_effect.gd:11-18`（内置效果 ID：EF_STAT/EF_SIZE/EF_FRACTAL/EF_BOUNCE/EF_ELEMENTAL/EF_MECH/EF_CRIT_SHARD/EF_HIT_BURST，及 :42 register_custom 扩展点）、`repo/autoload/event_bus.gd:14-53`（事件表）、`repo/scripts/core/data/resources/weapon_data.gd:10`（武器 form 枚举）。个别标注「游戏常识」的细节未单独搜证。

---

## 1. 进化契约：满级武器 + 指定被动 + 精英宝箱
- 原作规则：武器升到满级 8 级、包内持有指定被动（任意等级），再开精英掉落的宝箱即触发进化，三者缺一不可（来源：Fandom Evolution 页 + Steam 进化表）。
- 构筑价值：**可预期构筑路径**的教科书——玩家在选武器那一刻就知道终局形态；「满级」与「宝箱」两个门槛把构筑拉成三幕剧（拿武器→养满级→杀精英兑现），困难难度的挫败感被分解为可逐个击破的子目标。
- 本作适配改造：做「超武契约」类遗物——params 填 `{weapon_id, catalyst_trait_id, trigger_event: "boss_spawned"}`，监听 `boss_spawned`/`elite` 击杀事件，条件满足时武器形态升级（如弹道族 → 贯穿弹幕形态）。正好回应「困难难度构筑不起来」：给每个武器族一条可见的终点线。武器侧需在 `weapon_data.gd` 增加 evolved_form 字段。
- 实现代价预估：**需新系统**（武器进化/双形态状态机）+ 需新消费点（精英宝箱）。是本列表里唯一的大系统，但它是其余条目的地基。

## 2. 催化剂被动：进化的「身份错位」材料
- 原作规则：每条进化链绑定一个功能上与该武器无关的被动——Whip+Hollow Heart（血上限）→ Bloody Tear、Santa Water+Attractorb（磁铁）→ La Borra、Runetracer+Armor（护甲）→ NO FUTURE（来源：Bluestacks/Wiki 进化表）。
- 构筑价值：**构筑粘合剂**——为了 La Borra 你必须忍受一个看似无用的磁铁，被动因此获得第二身份（素材 vs 功能），选卡时的每一步都变成「这条链还缺什么」的谜题；错位感本身制造构筑记忆点。
- 本作适配改造：遗物 params 增加 `catalyst_for: StringName`，描述写成两层（本义 + 「可作某武器族的超武催化剂」）；没有进化系统前可先做弱化版——「持有本遗物时，X 武器族的 Y 词条达到满层质变（`trait_milestone`，event_bus.gd:41）后追加形态变化」。
- 实现代价预估：**纯数据驱动**起步（catalyst_for 标记 + 文案），完整形态依赖条目 1 的进化系统。

## 3. 槽位经济与「进化腾位」：被动被进化消耗
- 原作规则：武器/被动各有 6 格上限，进化时作为催化剂的被动被**消耗掉**，腾出一个被动格，玩家可继续捡新被动再养下一条链（来源：Fandom Evolution 页）。
- 构筑价值：**资源转化 + 取舍引擎**——6 格上限逼玩家在中期做减法；「进化返还格子」则把超武从终点变成中转站，一局可以串 2-3 条链，后期成长曲线在格子上自然续命。
- 本作适配改造：词条栏/遗物格设上限，超武契约触发时「燃烧」催化剂遗物腾位；掉落流维持供给。配合已有 `slot_unlocked` 事件（event_bus.gd:29）做节奏提示。
- 实现代价预估：**需新消费点**（「消耗型遗物」生命周期：燃烧动画、格位回收、卡池再注入）。

## 4. Union：跨武器联合进化
- 原作规则：两条进化完成的武器 + 第三件材料可再合成更高阶形态，如 Bloody Tear + Soul Eater + Vento Sacro → Fuwalafuwaloo（来源：VS Wiki/社区进化讨论）。
- 构筑价值：**终局第二幕**——超武不是终点而是下一条链的原料，给高水平玩家一个「贪婪到底」的长线目标；要求双满级+特定材料，天然只在高难长局出现，正好是困难难度的奖励出口。
- 本作适配改造：两族超武 + 特定遗物 → 隐藏合体形态（如激光族超武 + 环域族超武 + 「棱镜核」遗物 → 折射光网）。作为彩蛋级内容，图鉴占位但不写明配方，靠社区解谜传播。
- 实现代价预估：**需新系统**（依赖条目 1，且合体形态本身是新武器资产）；建议排最后。

## 5. 局外遗物入局：双戒指/Metaglio 作合成材料
- 原作规则：Infinite Corridor = Clock Lancet + 金戒指 + 银戒指（满级）、Crimson Shroud = Laurel + Metaglio Left/Right（满级），戒指与 Metaglio 是局外解锁/地图拾取的特殊遗物，需在局内升满并开箱兑现，且不受普通进化的时间门槛限制（来源：vampire.survivors.wiki Evolution 页 + Steam 进化表）。
- 构筑价值：**局外-局内资源转化的天花板**——局外树买的不是数值而是「入场券资产」，入场券在局内还要养满级才能兑现，局外投资与局内操作被串成一条线；且这两件超武的能力（时间冻结/锁血）本身就是规则改写器，是「机制向遗物」设计语言的极致。
- 本作适配改造：局外解锁的「信物」类遗物可在局内作为契约材料拾取升级；顶级遗物效果不走数值，走规则改写（如「Boss 登场时全场弹幕减速 2 秒」「受到致命伤改为锁血 1 秒」）。
- 实现代价预估：**需新系统**（局外资产 → 局内生成桥 + 持久化解锁状态）；效果本体若是规则改写类则各需专属处理器。

## 6. Arcana·Gemini：起始武器镜像复制
- 原作规则：Gemini (I) 给角色的起始武器及列表武器生成一个「对应体」镜像武器，等于整条武器翻倍，多把同名只算一把（来源：Fandom Gemini 页）。
- 构筑价值：**build-around 乘区**——它不吃攻击词条，吃的是「你开场选了谁」；镜像只复制起始武器，逼玩家围绕角色定义构筑，与翻倍数量协同的词条全部升值。
- 本作适配改造：遗物「镜像装置」：复制角色初始武器族的投射物/触发（params：`{copy_source: "starting_weapon", copy_mult: 1.0}`）。本作已有 mirror_image.gd 武器与 EF_FRACTAL 处理器，复制语义有现成积木。
- 实现代价预估：接近**纯数据驱动**（复用 EF_FRACTAL/镜像生成；需验证处理器是否支持「按起始武器动态取源」）。

## 7. Arcana·Waltz of Pearls：投射物弹跳
- 原作规则：Waltz of Pearls (XI) 让列表武器投射物获得最多 3 次反弹，在敌群间来回折射（来源：Fandom Arcanas 页）。
- 构筑价值：**条件引擎**——反弹不提高单发伤害，而是把「弹道寿命」变成新的乘区维度；与穿透、范围、弹速词条互相放大，弹幕密度型构筑的黏合剂。
- 本作适配改造：几乎白送的机制遗物——本作已有 EF_BOUNCE 处理器（trait_effect.gd:14）与 `bullet_bounced` 事件（event_bus.gd:50）。可加一层 VS 式联动：每次反弹挂一层元素标记，凑满触发 `reaction_triggered`（event_bus.gd:30），让弹跳接入元素反应体系。
- 实现代价预估：**纯数据驱动**（EF_BOUNCE + params 调 bounce 次数/元素标记）。

## 8. Arcana·Twilight Requiem：到期引爆 × Curse 倍率闭环
- 原作规则：Twilight Requiem (II) 让列表武器投射物在消失瞬间发生爆炸，爆炸伤害随 Curse（诅咒）属性缩放（来源：Fandom Twilight Requiem 页）。
- 构筑价值：**双引擎耦合**的范本——「弹丸消亡」被定义成新的伤害事件（弹幕的边角料变成第二段输出），而其倍率挂在 Curse 这个自增难度的词条上：风险词条第一次从代价变成了燃料，与条目 10 形成闭环。
- 本作适配改造：遗物「星陨挽歌」：监听弹丸消亡事件（本作缺这个钩子，是唯一缺口），在消亡点引爆范围伤害，params 把倍率绑定到「侵蚀/诅咒」类风险层数（呼应本作条件乘区词条）；与高弹量族（弹道/追踪）天然成build-around。
- 实现代价预估：**需新消费点**（弹丸 on-despawn 事件 + 范围爆炸处理器 `register_custom` 即可挂，trait_effect.gd:42）。

## 9. Arcana·Sarabande of Healing：治疗转伤害脉冲
- 原作规则：Sarabande of Healing 让一切治疗事件（吸血、食物、治疗圈）向周围放出伤害脉冲（来源：Steam 社区 Arcana 组合讨论）。
- 构筑价值：**资源转化**——防御资源被兑换成进攻引擎，吸血/回复词条从「生存保险」升格为 build-around 核心；越肉越痛，构筑语义反转。
- 本作适配改造：遗物「血宴回响」：监听治疗结算事件在玩家位置放元素脉冲（可复用 `kill_blast` 的表现层模式，event_bus.gd:48），脉冲可挂点燃/感电进反应体系。本作 EventBus 目前没有治疗信号（已核对 event_bus.gd 全表），需先补 `heal_resolved`。
- 实现代价预估：**需新消费点**（heal_resolved 事件 + 脉冲处理器；表现层可复用现有爆炸广播）。

## 10. Torrona's Box：分级风险契约 + 可拒绝的末级
- 原作规则：Torrona's Box 前 8 级只给 Omni（全能加成），第 9 级追加 +100% Curse（敌人速度/血量/数量/频率翻倍），且满级是 Victory Sword→Sole Solution 进化的前置；玩家可以用 Banish 把第 9 级从升级选项里放逐掉（来源：Fandom Torrona's Box 页）。
- 构筑价值：**风险契约 + 玩家自选难度旋钮**——同一个道具，贪婪者吃满 Omni 并接超武链，保守者吃到 8 级停手或直接放逐末级；难度由构筑选择内生地产生，而不是外部开关，这正是「困难难度构筑不起来」的反面教材：让高风险路线自带补偿性引擎。
- 本作适配改造：遗物「匣中之物」params 分 9 档，前 8 档给条件乘区类增益（如全武器族触发率），第 9 档切换为「敌方 ALL+X% 但全队获得诅咒 fueled 词条全效」并成为某超武契约的材料；选卡界面若支持「跳过此档」则完整复刻 Banish 交互。
- 实现代价预估：**纯数据驱动**为主（多档 params + 风险侧挂波次生成参数）；「拒绝末级」依赖条目 11 的 skip 消费点。

## 11. Reroll/Skip/Banish/Seal：四层随机操纵层
- 原作规则：局外金币树出售 Reroll（刷新选项）、Skip（跳过）、Banish（本局放逐某项，每级 2 次）、Seal（跨局永久封印某项，不能封遗物），操纵有 10% 概率不消耗次数，部分 Arcana 再 +3 次（来源：IGN PowerUp 指南 + Fandom Seal 页）。
- 构筑价值：**构筑确定性的分级救生索**——Reroll 治标、Banish 治本、Seal 把个人优化写进存档；「10% 保留」给操纵行为本身加了一点爽点。VS 构筑之所以撑得起高难，这层是隐形功臣：玩家永远不会被卡池的随机性彻底背刺。
- 本作适配改造：本作已有 reroll（`reroll_granted`，event_bus.gd:40），缺 Skip/Banish/Seal——遗物「逐客令」（本局 Banish 次数 +2，params 驱动次数）、局外成就解锁「封印栏」（开局前封 3 个词条）。困难难度下这是第一优先级：构筑不起来的最大原因往往是关键词条被卡池稀释。
- 实现代价预估：**需新系统**（选卡管线的操纵层：放逐集维护 + 局外封印持久化）；Reroll 地基已有。

## 12. 金币树递增价格曲线：广度优先的局外漏斗
- 原作规则：PowerUp 树用金币购买永久强化，同一节点每买一档价格上扬，天然把玩家推向「先买满便宜节点、再啃贵的」的广度优先路线；Reroll/Skip/Banish/Seal 也在这棵树上用递增价格出售（来源：IGN PowerUp 指南 + 搜索确认的递增档价设计）。
- 构筑价值：**成长曲线即教学**——价格梯度本身就是引导（便宜的功能性节点 = 新手必修课，贵数值 = 肝度天花板）；递增曲线让每个节点的边际收益可见，肝金永不空转，且把「局外买的是能力上限、局内拼的是组合」这条原则钉死。
- 本作适配改造：若已有局外树，把价格公式参数化：`price = base × (1 + bought)^k`（params：base/k）；节点设计按本条目 11 的操纵类优先、数值类殿后。若局外树未建，则本条目降级为远期参考。
- 实现代价预估：**纯数据驱动**（树上已有则只是价格公式 params 化）；若树未建则**需新系统**（局外货币 + 持久化 + 节点图 UI）——本作局外树现状未在本次调研中核实，落地前需先确认。

---

## 迁移结论（对「困难难度构筑不起来」）
按性价比排序的落地顺序：**(1)** 条目 11 的 Banish/Seal 操纵层——最便宜、直接治「卡池稀释」；**(2)** 条目 7/6/8/9 的机制向遗物——纯数据驱动或单个消费点，立刻让词条之间产生化学反应而非平行叠加；**(3)** 条目 1+2 的进化契约——一次系统投入，换来「每局有可见终点」的结构性修复；**(4)** 条目 10 的风险契约让困难难度由玩家自选；条目 3/4/5/12 是长线框架件。

## 参考来源
- [Evolution | Vampire Survivors Wiki - Fandom](https://vampire-survivors.fandom.com/wiki/Evolution)
- [Steam Community: Item Evolution Cheat Sheet (1.16 + DLCs)](https://steamcommunity.com/sharedfiles/filedetails)
- [Evolution | vampire.survivors.wiki](https://vampire.survivors.wiki/Evolution)
- [Torrona's Box | Vampire Survivors Wiki - Fandom](https://vampire-survivors.fandom.com/wiki/Torrona%27s_Box)
- [Gemini (I) | Vampire Survivors Wiki](https://vampire-survivors.fandom.com/wiki/Gemini_(I))
- [Arcanas | Vampire Survivors Wiki - Fandom](https://vampire-survivors.fandom.com/wiki/Arcanas)
- [Seal | Vampire Survivors Wiki - Fandom](https://vampire-survivors.fandom.com/wiki/Seal)
- [IGN: Vampire Survivors Power-Up Order Guide](https://www.ign.com/articles/vampire-survivors-power-up-order-guide)
- [BlueStacks: All Weapon Evolutions Guide](https://www.bluestacks.com)
- Steam 社区 Arcana 组合讨论（Divine Bloodline / Sarabande of Healing / Gemini 组合帖）

# R262 批次报告（祝福体系批 · 2026-10-12 · R2 修订）

> R2 修订说明：按独立读意见重写了拧巴答句（原「不一样」）、黑话句（口径/仲裁/对账）、未解释代号（F3/pp/M1/M2/里程碑语义），补齐关键计数成员枚举与逐条证据（白6/蓝17/紫11/金4、金档 4 条逐条过门依据、紫池 26 位次），新增「⑥ 读者追问速答」，并把读者点名的两个套件（qa_r262_bless_tier、r252_blessing）在本报告批**实际复跑**为一手结果。四题事实结论零变更。

本批范围：①祝福面板武器混淆 ②品级签+去锁档（池扩全档） ③困难档看不到近战/法器祝福 ④护盾转应急强化。四题探索定谳复核均为「证实」，实施+测试+出包已完成，包 `InfiniteFission_v0.1.69_vc70.apk`。

先解释三个贯穿全文的词：
- **祝福池**：每次点「出发」弹出的祝福面板里能选到的词条清单。它**不是随机刷的**——是按词条 id 字典序排好的静态列表（零 rng），「没刷到」从来不存在运气成分。
- **适配门**：「这个词条挂到当前首发武器上到底生不生效」的判定。词条文件里可以声明适配条件（`required_weapon` 绑定武器 / `required_forms` 绑定形态 / `required_class` 绑定近战·法器类别等六个键），不满足的词条挂上去就是**死卡**（占格子、零效果）。
- **12 格构筑帽**：单把武器最多挂 **12 种**不同词条的宽度上限（scripts/combat/trait/trait_stack.gd:18，层数不算、只算种类）——第 4 题还会用到。

---

## ① 四题结论（人话版）

### 1. 武器混淆：根因=祝福池漏滤「首发武器适配」，本批补了这道门

**现象**：手枪局的祝福面板会刷出「巨刃」这类近战专属祝福，选了进局变死卡。

**根因（定谳 bug）**：祝福池 `_blessing_pool` 原来只过滤四个条件——①品级==当前难度档 ②非阈值型 ③无前置词条 ④图鉴解锁（旧 scripts/loop/game_loop.gd:1890-1920，对应 :1911/:1913/:1915/:1917 四行）——**没有「这个词条适不适配当前首发武器」这一条**。全仓 23 个词条带 `required_weapon`（如巨刃 MEC_GIANT_BLADE 绑定 W8/W9/W11/W12/W13 五把近战/法器，resources/traits/MEC_GIANT_BLADE.tres:7-15），只要品级对档+图鉴解锁就进池。而挂载侧 `_apply_start_blessing` 早就有适配门+死卡横幅（旧 :2003-2026）——设计意图本来就是「祝福应适配武器」，面板侧漏拦，所以「面板能选、进局失效」。

**本批修法**：池侧补第五条件。新增静态适配门 `_blessing_fits_start_weapon`（scripts/loop/game_loop.gd:1940，:1934 调用），照 card_generator.mount_gate_allows（scripts/cards/card_generator.gd:676-791）的数据键口径复刻**六键**：required_weapon（数组/单值双口径）、required_forms、required_class、excluded_weapons、requires_projectile、requires_weapon_keys。

「首发武器是哪一把」怎么判：复用现成函数 `_starting_weapon_id`（game_loop.gd:1519-1533，本批不新写）——非 fission 角色**恒手枪 W1_pistol**；fission 角色的自定义武器**须过该武器的难度解锁门**；自定义武器 id 为空或无效（写错/已删除）一律兜底回手枪。之所以不直接读玩家设置里的自定义武器字段（「裸读」）：那个字段可能是空的或失效 id，直接读会把首发判错（比如地狱解锁近战作 custom 首发时，裸读反而会误滤掉适配的巨刃类祝福）。而祝福面板弹出的时机是主菜单点「出发」瞬间（game_loop.gd:1867 → :2014），战斗还没真正开局——场景里的武器对象是启动期预装的、可能不是最终那把（要到 start_run game_loop.gd:1677 才校正），所以面板期拿不到可靠的武器对象，适配判定只能拿「词条文件里声明的条件」对照「武器文件里的形态/类别」做**纯数据比对**，不能调用需要武器实例的 mount_gate_allows。

验收：qa_r262_bless_tier T2（手枪池不含巨刃/激光滞留/环绕三件等；fission·W13 阔剑臂池含巨刃不含 W5/W6/W7/W10 绑定项）——本报告批复跑全绿（见 ③）。

### 2. 品级签：类别签退役，默认签=当前难度档，全部解锁词条可见可选

- **顶签换了**：从「伤害类别签」（全部/加算/乘算/局部/机制/元素，按 td.pool 筛）改成**品级签**「全部/白/蓝/紫/金」（按 td.rarity 筛，用户口径文案，scripts/ui/blessing_pick_ui.gd:477；签钮字色随档色）。
- **池扩全档**：删掉 R252 的「普通蓝/困难紫/地狱金」锁档——`_blessing_pool(p_tier=-1)` 全池开放，p_tier 保留为测试/诊断探针（game_loop.gd:1890）。全池=图鉴解锁+过首发适配门的全部词条。**任何难度都能选任何档**。
- **手枪全解锁池 38 条的成员枚举**（命令与输出见文末核验记录；`grep -h "^rarity = " resources/traits/*.tres | sort | uniq -c` 实跑=白6/蓝26/紫28/金13，全仓 73 个词条文件）：
  - **白 6**：AFF_ATK_UP / AFF_CRIT_RATE / AFF_HP_UP / AFF_PICKUP / AFF_PROJ_SPD / AFF_ROF_UP（`grep -l "^rarity = 0"` 实跑，无一携带适配键）。
  - **蓝 17**（r1 共 26，滤 9）：6 个无任何适配键直通（AFF_CRIT_DMG / AFF_GOLD / AFF_SKILL_HASTE / AFF_XP_GAIN / MEC_KILL_BLAST / MEC_SHIELD）+ 11 个适配键含手枪形态过门（AFF_AREA / AFF_PIERCE / MEC_KNOCK / MEC_PARALLEL_CAL + ELE_ANEMO / ELE_DENDRO / ELE_FREEZE / ELE_GEO / ELE_HYDRO / ELE_IGNITE / ELE_SHOCK）；滤掉的 9 = 6 个武器绑定（MEC_BEAM_LAG→W4 激光、MEC_HIVE_RACK→W6、MEC_MIRROR_SPLIT→W5、MEC_ORBIT_LINK→W8/W9/W11/W12/W13、MEC_SLASH_TEMPO→W9/W13、MEC_THROW_RANGE→W10）+ 3 个形态/类别门（AFF_CDR forms[1,2,3]、AFF_RANGE forms[3]、MEC_BULLET_PARRY forms[3]+required_class=melee——手枪 form=0、非近战，全不过）。
  - **紫 11**（r2 共 28，滤 17）：滤 requires_trait 2（MEC_RICOCHET_HALL / SYN_BOUNCE_SPEC，前置 MEC_BOUNCE）+ 滤武器绑定 15（MEC_BEAM_COFOCUS/BEAM_FAN/BEAM_TRACK→W4、MEC_PHASE_SYNC/SPLIT_PRISM→W4、MEC_MIRROR_LOCK/TEMPO/WEIGHT→W5、MEC_FUSE_COAT→W6、MEC_FUSE_DETONATE→W7、MEC_CHAIN_DETONATE/MEC_ORBIT_AXE/MEC_ORBIT_BOLT/MEC_ORBIT_SWORD→W8、MEC_GIANT_BLADE→W8/W9/W11/W12/W13）；剩 AFF_MULTI / ELE_ARC_SURGE / MEC_BOUNCE / MEC_HIT_BURST / MEC_OVERKILL / MEC_SIZE_STACK / SYN_BULWARK / SYN_BURN_DEVOUR / SYN_FROST_EXEC / SYN_LOWHP_FURY / SYN_PIERCE_EVO。
  - **金 4**（r3 共 13=6 非阈值+7 个 TH_* 阈值型，阈值型恒不进池）：6 件非阈值里 MEC_BEAM_SPECTRA（required_forms=[1]+required_weapon=[W4_pulse_beam]）、MEC_CRITICAL_MASS（required_weapon=[W8_orbit_field]）被滤（两文件 ：15 实查），剩 ELE_REACTION_VOID / MEC_CRIT_SHARD / MEC_FRACTAL / SYN_FIRST_STRIKE——前三个无任何适配键直通，MEC_FRACTAL 仅 required_forms=[0,2,3]（MEC_FRACTAL.tres:15），手枪 form=0（W1_pistol.tres:55）在列→过门。
  - 四档计数 {6,17,11,4} 与逐项过门已由 r252_blessing B1 断言组一手复跑实证（「B1 池容量：全池==38 且分档 {6,17,11,4}」「B1 逐项自洽：全池每项过 _blessing_fits_start_weapon」均 ok，见 ③）。
- **默认签=当前难度档**（普通→蓝、困难→紫、地狱→金，scripts/core/game_const.gd:49-53 blessing_rarity_tier），每次打开面板重置（blessing_pick_ui.gd:103）；默认档签在池内缺席时（如只解锁过白/蓝词条却打地狱）自动回退「全部」，防空列表死胡同（:108-116）。
- **跨档合法生效**：R252 的跨难度挂载门（跨档祝福进局不挂载+横幅「与本难度档位不符」）拆除（game_loop.gd:2091）——保留它会变成「UI 可选、进局失效」的自相矛盾陷阱。R252 §2.1-8「跨难度回落=不挂载不预选」定案随去锁档需求作废。
- **配套交互迁移**（M1/M2 是 R261 起的两个面板防线代号，FEEDBACK_TRACKER R261 节：**M1**=「保留/默认的签在池内缺席→回退全部」防空列表死胡同；**M2**=「预选的记忆项被当前签挡住→自动跳到它所在的签+页」）：M1 键改 rarity（:108-116）、M2 跳签键改 rarity（blessing_pick_ui.gd:125-126）；行按下色按行自身品级色（全档混屏可辨识）；副标题改「难度【×】· ×级祝福（全档可选）——选定后每次出发默认携带」，删掉已成假话的「跨难度出战不生效」（:140）。
- **图鉴解锁守卫不变**：写记忆键仍只守图鉴解锁（scripts/meta/meta_manager.gd set_blessing_trait :806 仅注释更新，写口/落盘零改动）。

### 3. 困难档看不到近战/法器祝福：定谳=vc68 版本限制为主因+图鉴未解锁放大，不是 bug 也基本不怪运气

照探查 verdict：祝福面板**不是随机刷的**（零 rng 静态列表、按 id 字典序）——「没刷到」不存在运气成分。

- **证据要点（成员与位次均为一手 grep 枚举，见文末核验记录）**：困难档紫池候选 26 个=r2 全部 28 个滤掉 2 个 requires_trait（MEC_RICOCHET_HALL/SYN_BOUNCE_SPEC）。26 个候选按 id 字典序里只有 **5 个**近战/法器绑定词条：**链式引爆 MEC_CHAIN_DETONATE 第 7 位、巨刃 MEC_GIANT_BLADE 第 10 位、环绕·裂空斧/雷霆/裂空剑 MEC_ORBIT_AXE/BOLT/SWORD 第 15/16/17 位**——vc68 真机（ScrollContainer 触摸拖动被行按钮吞、只有前 7 行可见）永远看不到第 10/15/16/17 位；唯一挤进第 7 位的「链式引爆」还必须先在局内抽到过那张卡（图鉴解锁门）才进池。所以用户面板上大概率一个近战/法器词条都没有，与「运气不好」无关。
- **消解路径（已全部落地）**：vc69（R261）分页+页签让全部词条可翻可达；本批再加全解锁池（不依赖抽卡史）+品级签（紫档一键定位）+首发适配门（只显示适配词条），此问题彻底消解。
- **用户自查法**：大厅→图鉴→「祝福」页，对照五个近战/法器词条名——**链式引爆 / 巨刃 / 环绕·裂空斧 / 环绕·雷霆 / 环绕·裂空剑**——看哪些仍是「？？？未解锁」（解锁条件=局内抽到过该词条卡），即知图鉴缺口；装 vc70 后在困难祝福面板切「紫」签逐页核对 5 个是否全部出现。注：真机解锁状态存在设备存档（user://）里，本仓无法代查。

> **【R263 勘误（2026-10-12，只增不删）】** 本题定谳所引「紫池 26 候选含 5 近战/法器词条」是**第 1 题适配门加入前**的池快照；两题合读即见矛盾——适配门按首发（普通角色恒手枪 W1）过滤后，这 5 个近战/法器词条（required_weapon=W8 族/required_class=melee）**全部出池**，第 34-35 行过门枚举（蓝 17/紫 11）里零武器绑定词条可为证。因此「切紫签逐页核对 5 个是否出现」在手枪首发下**永不可能出现**；vc73 用户反馈「开局祝福依旧没有武器」即此（FEEDBACK_TRACKER R263 节，探针 qa_r263_wpnpool_probe：普通角色×困难全池 38 项武器专属 0；fission+W8 环绕×困难含近战队 8 项过门——门逻辑本身正常，唯一看到路径=改造者自定义近战/法器首发且过难度门）。修复方向待拍板。

### 4. 护盾/应急强化：正常机制，不是 bug（shieldBug=false，只解释不修）

> 支撑说明：本批**未改护盾任何代码**（只解释），故无本批新测试；下述行号本报告批已 grep/Read 实查（文末核验记录），行为断言引自既有测试组 r238_shieldfix（tests/runner/r238_shieldfix_cases.gd:170-174，双单元独立计时实证）。

**护盾（格挡力场）的作用与叠层**：
- 格挡力场是机制类蓝卡词条（MEC_SHIELD，rarity=1，resources/traits/MEC_SHIELD.tres:24/:17），周期性给护盾条充能：1 层 8 秒一充，同武器挂第 2 张缩到 5.5 秒（MEC_SHIELD.tres:15 `interval_s=8.0, interval_lv2=5.5`）。
- **可叠 2 层**：R226 起全词条无限叠层。`stack_max=2` 现在只剩两个用途——①成就/里程碑判定 ②统计上报（超帽时仅 DebugStats 计一次 trait_attach_overcap 遥测，trait_stack.gd:152-153 注释明写「R226 起全额放行」）——**不再拦截叠层**。已有 1 层（甚至 2 层满）时再选护盾卡都正常叠层成功。
- 不同武器各挂一张=R253 独立计时各充各的，护盾条层数=两者之和（tests/runner/r238_shieldfix_cases.gd:170-174 实证）。

**「词条栏已满：格挡力场 转为应急强化」横幅的唯一触发条件**：这张卡在货架上生成时随机绑定的目标武器（卡面【武器名】前缀就是提示，card_generator.gd:561/938/947）已经挂满 **12 种**不同词条（12 格构筑帽，见篇首定义；trait_stack.gd:18/:167-169 是保留下来的唯一拒绝线）——**与护盾层数完全无关**。

**应急强化（FALLBACK_ATK）=挂载失败保底卡**（R189c 设计：「找有空位的武器挂 FALLBACK_ATK；全满员才放弃」card_generator.gd:494-505）。数值：
- 固定**白卡**（rarity=0）「攻击力 +5%」（FALLBACK_ATK_PCT=0.05，card_generator.gd:80 与 :1066）；
- **stack_max=99，可无限叠**（card_generator.gd:1069）；
- 收益逐层递减：衰减公式（内部代号 F3，trait_stack.gd:392-401）为「累计收益 = 5% × (1−0.85ⁿ)/0.15」，等价于**每多一层，新增收益打 0.85 折**——第 1 层 +5%，第 2 层再 +4.25 个百分点（累计约 +9.25%），第 3 层再 +3.6 个百分点（累计约 +12.9%）。（pp=百分点，percentage points。）

**「同品级转化的应急强化一样吗」——按代码事实回答：全都一样，没有品级之分。** 转化通道（card_generator.gd:496-505）根本不读被转卡的 rarity/数据，直接调 `_fallback_stat_card()` **零参数固定构造**（:1055-1077）——金护盾转出来、紫卡转出来，都是同一张白卡「+5% 攻击」。而且**全游戏三个产口出的是同一张卡**：①挂载失败转化（:496-505）②货架补位（:130/139）③黑市终兜底（scripts/ui/shop_ui.gd:380-405），全部走 `_fallback_stat_card()` 同一构造——id=FALLBACK_ATK、白卡、+5% 攻击、可无限叠、F3 递减。

**自查**：想复核当时为什么转化，看卡面【武器名】前缀所指武器的构筑面板词条种类数是否已满 12。

---

## ② 改动清单（impl 方案 changes → 实施结果）

实施轮盘上核验：三个源码文件 mtime 2026-10-12 04:34-04:35、新套件 04:49/04:50（ls 实查）；关键锚点 grep 实证见下表。

| # | 文件 | 改动要点 | 实施结果 |
|---|---|---|---|
| 1 | scripts/loop/game_loop.gd | ① `_blessing_pool(:1890)` 签名改 `p_tier: int = -1` 全池开放（p_tier>=0 保留分档探针；生产三调用点改全池）；② 循环外求首发判定 `_starting_weapon_id`(:1910)+`registry.get_weapon`；③ :1934 第五条件适配门；④ 新增 `_blessing_fits_start_weapon`(:1940) 六键静态判定（required_weapon 双口径/required_forms/required_class/excluded_weapons/requires_projectile/requires_weapon_keys 直读版）；⑤ `_apply_start_blessing` 删跨档回落分支(:2091)+死卡兜底改拒挂(:2104-2107)；⑥ `_try_open_blessing_pick` 池空改全池+DebugStats 文案「祝福池空（图鉴解锁词条均不适配当前首发或未解锁）」；⑦ `_on_blessing_confirmed` 注释「R262 全档合法」。挂载搜索/生效横幅/每日种子守卫零位移 | ✅ 落地（mtime 04:34；:1890/:1910/:1934/:1940/:2091/:2104-2107 grep 实证） |
| 2 | scripts/ui/blessing_pick_ui.gd | `_filter_pool`→`_filter_rarity`(:45，键域 -1/0/1/2/3)；open 头重置默认签=_tier(:103)+M1 缺席回退「全部」(:108-116)；M2 预选跳签键改 rarity(:125-126)；_apply_filter 比较键 td.rarity(:165)；_rows_sig(:177)；副标题「全档可选」(:140)；签钮五枚 `{-1:全部,0:白,1:蓝,2:紫,3:金}`(:477)+签钮字色=rarity_color；行按下色两处按行自身品级；头部契约注释品级语义；行图标类别章保留 | ✅ 落地（mtime 04:35；:45/:103/:125/:140/:165/:477 grep 实证） |
| 3 | scripts/meta/meta_manager.gd | set_blessing_trait 仅注释更新（R262 起全档合法——守卫仅图鉴解锁不变）；写口守卫/落盘零改动 | ✅ 落地（mtime 04:35） |
| 4 | FEEDBACK_TRACKER.md | 末尾追加 R262 节：需求定案三行+修刀+裁定记录+强度注记+测试账（实施轮写入 :1790-1825）；本报告批补「复跑与出包」小节+出包行（只增不删） | ✅ 实施轮已写；出包行本批补 |
| 5 | tests/qa_r262_bless_tier.gd + qa_r262_bless_tier_cases.gd | 新建验收壳+断言体（T1 池扩/T2 适配门+fission 臂/T3 默认签/T4 缺席回退/T5 品级签切换/T6 预选跳签/T7 记忆键适配拒挂+对照/T8 跨档记忆生效/T9 池空退化/T10 行色随行品级/T11 副标题/T12 每日隔离） | ✅ 落地（mtime 04:49/04:50；本报告批复跑 26/26） |
| 6 | tests/runner/r252_blessing_cases.gd | B1 全池 38+分档探针 {6,17,11,4}+逐项过门自洽新增 1 断言；B2 全池空+直达战斗臂保留；B4 跨档生效反向迁移；B6 适配拒挂反向迁移；B11/B14/B17/B18/B21 探针零迁移 | ✅ 落地（本报告批复跑 70/70，原 69+新增 1） |
| 7 | tests/qa_r261_bles_filter_cases.gd | 19 断言品级签迁移：夹具全池+「≥8」→「≥30」；默认签分页按蓝档子集动态统计；预选跳页臂改蓝档尾项 MEC_SHIELD；乘算签→蓝档签；空签隐藏 get(4)→get(3)；M2 白签保留+预选紫项跳紫签；M1 pool_no_blue 错位触发；H1 段零迁移（P3 裁决：AFF_AREA 实查 r1+显式切全部签） | ✅ 落地（实施轮实跑 19/19） |
| 8 | tests/qa_r261_probe_deep_cases.gd | 30 断言迁移：夹具 T1/T2=17/11；a 组紫档取项+对照组「跳签后子集 idx」口径（P4）；b 组金签 4 项/紫签 2 页/末页「2/2」（P5）；c 组 pool_all+序列重排（P5）；b 补默认档缺席回退；f 组 diag 实跑取值 | ✅ 落地（实施轮实跑 3 红后修夹具全档解锁→30/30） |
| 9 | tests/qa_r260_qa_rows_cases.gd | R1 夹具两处加 `_blessing_fits_start_weapon` 过滤（防净档 pool_a=1 项 FAIL/R5 越界崩套件）；R7 extra_id 过门条件+全解锁档恒 skip 臂披露；R8 行色随行 rarity | ✅ 落地（实施轮实跑 10/10） |
| 10 | tests/qa_r260_bles_anim_cases.gd | pool2 第二项改 AFF_GOLD（r1 同蓝档；P1 撤 AFF_MULTI r2 误判）；⑤段快照清空+组合臂临时解锁（全池口径下泵恢复前提适配） | ✅ 落地（实施轮实跑 23/23） |
| 11 | tests/qa_r255_play_a.gd / qa_r255_play_b.gd | 截图文案「普通蓝池/困难紫池」提示级订正（非断言，不阻塞门禁） | ✅ 落地（mtime 04:30 窗口内） |
| — | export_presets.cfg | version/code=70（出包版本号） | ✅ 实查 :45 `version/code=70` |

---

## ③ 测试账

**口径说明（回应「七套件」计数）**：「七套件」=实施轮复跑矩阵的**七项**，其中第 7 项「邻接抽跑」是一组、含 3 个套件文件——所以实际执行了 **9 个套件**。合计 351 断言 = 前六项 26+19+30+10+23+70=**178** + 邻接三件 93+41+39=**173**。另有 3 个 print 探针（qa_r254_probe_map / qa_r257_probe_journey / qa_r261_probe_dump）exit 0，非断言套件不计入。

| 套件 | 结果 | 支撑 |
|---|---|---|
| qa_r262_bless_tier（新套件） | **26/26** | ✅ **本报告批一手复跑**（命令与汇总见下）；静态值 38={白6,蓝17,紫11,金4} 与 grep 推演零偏差 |
| r252_blessing | **70/70** | ✅ **本报告批一手复跑**；B1 池容量/逐项自洽/金档探针 4 项/B4 跨档生效/B6 适配拒挂全 ok（原 69+B1 新增 1） |
| qa_r261_bles_filter | 19/19 | 转引实施轮（FEEDBACK_TRACKER.md:1825） |
| qa_r261_probe_deep | 30/30 | 转引（实施轮曾 3 红，修夹具全档解锁后全绿） |
| qa_r260_qa_rows | 10/10 | 转引 |
| qa_r260_bles_anim | 23/23 | 转引（⑤段 R262 适配：出发直达战斗=泵恢复前提需 codex 空） |
| 邻接：r194_mobile / r245_content / r246_ui | 93/93 · 41/41 · 39/39 | 转引 |
| 探针 ×3 | exit 0 | 转引 |

**本报告批一手复跑记录**（2026-10-12，Godot 4.3 headless，命令逐字如下，两套件结果与实施轮记录一致）：

```
cd E:/Code/Agent/Infinite-Fission
./tools/Godot_v4.3-stable_win64_console.exe --headless --path repo -s tests/qa_r262_bless_tier.gd
  → 「验收汇总：PASS 26 / FAIL 0（共 26 项）」，退出码 0
./tools/Godot_v4.3-stable_win64_console.exe --headless --path repo -s tests/runner/test_r252_blessing.gd
  → 「验收汇总：PASS 70 / FAIL 0（共 70 项）」，退出码 0
```

其余 7 个套件（19+30+10+23+93+41+39=255 断言）本报告批**未复跑**，结论转引自实施轮记录（FEEDBACK_TRACKER.md:1825「R262 实跑校准声明」）；如需全量一手复验，复跑命令同上格式逐套件执行即可。

**出包门禁**：
- 包：`E:\Code\Agent\Infinite-Fission\android_export\out\InfiniteFission_v0.1.69_vc70.apk`（36,614,440 字节，2026-10-12 05:01——本批 `ls -la` 实查存在；export_presets.cfg:45 `version/code=70` 实查）。
- export_versioned.log：105 步导出+apksigner 签名+校验完成（「Signed」「export: end」）——本批 tail 实查。
- **验收门：过；回归：全绿**（其中 2 套件已本批一手复跑实证，其余转引实施轮记录，见上表）。

---

## ④ 强度风险披露（跨档可选金卡）

拆锁档+池扩后，普通局可以带金档开局祝福。要点：

1. **实际可达面比探查口径更小，且逐条可复核**：手枪首发下金档可达恰 **4 条**——ELE_REACTION_VOID（无适配键）、MEC_CRIT_SHARD（无适配键）、SYN_FIRST_STRIKE（无适配键）、MEC_FRACTAL（仅 required_forms=[0,2,3]，手枪 form=0 过门，MEC_FRACTAL.tres:15+W1_pistol.tres:55 实查）。R252-design:95 六件列名中 MEC_BEAM_SPECTRA（required_forms=[1]+required_weapon=[W4_pulse_beam]，:15）与 MEC_CRITICAL_MASS（required_weapon=[W8_orbit_field]，:15）被首发适配门滤掉。六件逐一 `grep -c` 适配键实跑输出 0/1/1/0/1/0（文末核验记录）；r252_blessing B1「金档探针 4 项」断言一手复跑 ok。回退阀强度评估按 4 条口径。
2. **这 4 条是机制级强词条**，普通敌人数值乘区不变→普通局带金祝福≈白嫖地狱开局增益，前期滚雪球风险。
3. **图鉴门不设防跨档**：卡池金卡权重与难度无关（card_generator.gd:1222-1233，基线 6.0、w≥10 成长 6×(1+0.06w)），普通局抽到金词条卡即解锁对应金档祝福——**勿指望图鉴门兜底强度**。
4. **爬梯激励消失**：R252「普蓝→困紫→狱金」难度爬梯激励不复存在；残余形态=默认签引导（默认亮当前难度档签，跨档需主动切签）。
5. **池收窄说明**：首发适配门使手枪全解锁池 38/73（73=全仓词条 .tres 总数，`ls resources/traits | wc -l` 与 rarity 计数 6+26+28+13 实查）——只滤「对当前首发不适配」词条，与挂载门语义对齐（面板可选=进局可挂自洽），属**修复非削弱**。
6. **回退阀与决策状态**：回退阀**没有自动触发条件，是人工决策项**——去锁档本身是用户需求②明文拍板（「去 rarity==tier 锁档」+品级签+默认签=当前难度档），本批按拍板实施并把风险在此披露；是否回退由用户试玩 vc70 后裁定。若强度不可接受，最小回退=恢复 game_loop `_apply_start_blessing` 挂载门（原 :1998 跨档回落分支）+副标题/M2 恢复跨档提示——局部化两文件（game_loop.gd + blessing_pick_ui.gd）。

---

## ⑤ 性能项

- **真机诊断日志正文未提供，本批未诊断。** 本批为祝福体系批（功能/定谳/测试/出包），性能三线（逐帧负载 / 泵与预算体系 / 合批与绘制热点）未在本批展开。
- **请把真机「导出诊断日志」的日志正文贴全文（或放到工作区任意路径并告知路径）**，拿到后即可做：1Hz 帧耗时行逐帧负载分析、模态期泵挂起行为核对、合批与绘制热点定位。
- 参考：大厅「导出诊断日志」导出的文本即为所需材料；先例 R258 凭用户发回的真机 diag 日志四行即定罪祝福面板被菜单层遮挡，日志越全文越好定位。

---

## ⑥ 读者追问速答

**Q1：这份报告的测试结论是你自己跑的吗？**
不全是，现在一半是。读者点名的两个套件本报告批已**实际复跑**：qa_r262_bless_tier 26/26、r252_blessing 70/70（命令与输出见 ③，与实施轮记录一致）——这两个恰好覆盖了本批全部核心行为（池 38 分档/适配门/默认签/跳签/拒挂/跨档生效/每日隔离）。其余 7 个套件（255 断言）仍是实施轮转引，本批未复跑，已在 ③ 逐项标注。

**Q2：普通局能带金卡开局祝福，游戏玩坏了吗？该不该装 vc70？**
这是**设计取舍不是缺陷**，且「去锁档」是需求里用户自己的明文拍板（品级签+全档可选），本批照拍板实施并在此披露风险（④）。实际暴露面有限：手枪普通局金档恰 4 条（④-1 逐条依据）。vc70 相对 vc69 还带着 bug 修复（面板不再出巨刃类死卡）——不升级则继续遇到原问题。装不装、要不要回退，等试玩后人工裁定，回退方案已备好（④-6，两文件局部改动）。

**Q3：拒挂横幅说「可在出发前重选」，入口在哪？**
主菜单选关界面点「出发」时弹出的**祝福面板**就是入口（每次出发都会尝试弹出，game_loop.gd:1867 → _try_open_blessing_pick:2014）。面板上三个按钮三种语义（blessing_pick_ui.gd:27-29 + game_loop.gd:2033-2059 实查）：**改选另一词条后点「出发」**=覆盖记忆键（下次默认带新的）；**「不选祝福」**=本局不带、但记忆保留（下次出发仍默认带上原记忆，game_loop.gd:2047 注释「不覆盖记忆键——设计 §2.4-4」）；**「清除记忆」**=永久退出默认携带（game_loop.gd:2056-2059 调 Meta.clear_blessing_trait()；无记忆时该按钮禁用，blessing_pick_ui.gd:135）。

**Q4：应急强化是不是全游戏就同一张白卡？**
是。转化、货架补位、黑市兜底三个产口全部走 `_fallback_stat_card()` 同一零参数构造（card_generator.gd:496-505/:130/:139 + shop_ui.gd:380-405，构造体 :1055-1077）——同一张 FALLBACK_ATK 白卡「+5% 攻击」，可无限叠（stack_max=99），逐层 F3 递减。与被转词条的品级无关，三个产口之间也无差别。

**Q5：vc68「触摸滚动被吞、只有前 7 行可见」只影响祝福面板吗？vc70 修了吗？**
根因注释只存在于祝福面板（blessing_pick_ui.gd:11「ScrollContainer 退役——触摸拖动被行 Button 吞」、:54-55、:95-96），R261（vc69）已把该面板滚动壳**连根拔改分页 7 行/页**，vc70 沿用分页——vc70 的祝福面板不存在滚动问题。其他界面有各自滚动实现，无同类用户报告，本批也未改动。

**Q6：图鉴那 5 个近战/法器词条只能靠局内抽卡解锁吗？有没有办法提高概率？**
解锁途径**只有一条**：局内抽到并应用该词条卡（meta_manager.gd:930 `codex_traits[String(p_card_id)] = true` 是唯一运行时写口；:1302 是读档回填不是解锁途径；无商店购买/任务等其他开关）。概率层面没有定向手段——金卡权重与难度无关（基线 6.0，card_generator.gd:1222-1233），能做的就是多打局多抽卡，每次词条三选一都是一次机会。

---

## 报告批核验记录（本报告撰写/修订时实跑）

| 命令 | 结果 |
|---|---|
| `./tools/Godot_v4.3-stable_win64_console.exe --headless --path repo -s tests/qa_r262_bless_tier.gd` | 「验收汇总：PASS 26 / FAIL 0（共 26 项）」，EXIT=0（一手） |
| `./tools/Godot_v4.3-stable_win64_console.exe --headless --path repo -s tests/runner/test_r252_blessing.gd` | 「验收汇总：PASS 70 / FAIL 0（共 70 项）」，EXIT=0（一手；B1 池容量 38={6,17,11,4}/逐项自洽/金档探针/B4/B6 全 ok） |
| `grep -h "^rarity = " resources/traits/*.tres \| sort \| uniq -c` | 6 / 26 / 28 / 13（合计 73） |
| `grep -l "^rarity = 0/3" resources/traits/*.tres` | 白 6 名单；金 13=6 非阈值+7×TH_* |
| `grep -l "^rarity = 1" …` + 逐文件适配键 grep | 蓝 17=6 无键+11 有键过门；滤 9 名单如 ①-2 |
| `grep -l "^rarity = 2" …` + 绑定键/requires_trait grep | 紫 11 推导（28−2−15）；26 候选位次 #7/#10/#15/#16/#17 |
| 六金卡逐个 `grep -cE '"required_weapon"\|"required_forms"\|…'` | ELE_REACTION_VOID=0 / BEAM_SPECTRA=1 / CRITICAL_MASS=1 / CRIT_SHARD=0 / FRACTAL=1 / FIRST_STRIKE=0（FRACTAL 键=required_forms[0,2,3]，手枪 form=0 过门） |
| `grep -n "form"` W1_pistol.tres | :55 `form = 0` |
| `grep -n "clear_blessing_trait\|不选祝福"` game_loop.gd / blessing_pick_ui.gd | :2033-2059 三按钮语义；blessing_pick_ui.gd:27-29/:135/:217 |
| `grep -n "ScrollContainer\|触摸"` blessing_pick_ui.gd | :11/:54-55/:95-96（面板专属根因注释） |
| `grep -n "codex_traits\[" meta_manager.gd` | :930（唯一运行时解锁写口）/:1302（读档回填） |
| `ls -la android_export/out/` | InfiniteFission_v0.1.69_vc70.apk 36,614,440 字节 2026-10-12 05:01 |
| `grep -n "version/code" export_presets.cfg` | :45 `version/code=70` |
| `ls -la` 三源码文件+新套件 | game_loop.gd 04:34 / meta_manager.gd 04:35 / blessing_pick_ui.gd 04:35；qa_r262 两文件 04:49/04:50 |
| `grep -n "_blessing_fits_start_weapon\|func _blessing_pool\|_starting_weapon_id(Meta"` game_loop.gd | :1890/:1910/:1934/:1940 |
| `grep -n "与当前首发武器不适配\|R262"` game_loop.gd | :2091 拆门注释/:2104-2107 拒挂横幅 |
| `grep -n "_filter_rarity\|全档可选\|filter_names"` blessing_pick_ui.gd | :45/:103/:125/:140/:165/:477 |
| `sed -n '76,82p;1055,1078p'` + grep FALLBACK card_generator.gd | FALLBACK_ATK_PCT=0.05(:80)/白卡 rarity=0/stack_max=99(:1069)/decay 0.85(:1067)；转化横幅 :505；货架补位 :130/:139 |
| `grep -n interval_s` MEC_SHIELD.tres | :15 interval_s=8.0/interval_lv2=5.5；:17 stack_max=2；:24 rarity=1 |
| `tail -40 export_versioned.log` | 签名+校验完成（Signed / export: end） |

测试结果 19/30/10/23/93/41/39 与探针 exit 0 **转引自实施轮记录（FEEDBACK_TRACKER.md:1825）与批材料**，本报告批未复跑；qa_r262 26/26 与 r252 70/70 为本报告批一手复跑；盘上改动产物与代码锚点均为本批实查。

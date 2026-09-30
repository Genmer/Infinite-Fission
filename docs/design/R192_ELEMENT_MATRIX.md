# R192 七元素反应大矩阵 · 整案设计文档

> 状态：**四方向（elem / matrix / visual / wire）仲裁收敛稿**。本文件是 R192 的 **idContract 唯一真源**：
> Element 枚举、新卡 id、21 配对反应 id/数值/优先级/解锁关均以本文 §3 为准，实现组逐字遵守、禁自创别名。
> 工程纪律沿用 A 架构 §九 + 各方向在案红线；文案一律取真源（GameConst.reaction_note / REACTION_NAMES），UI 不手抄。
>
> 基线声明：本整案为仲裁轮（零代码改动），未复跑测试电池；基线数字转引四方向本回合 headless 实跑记录
> （命令 `tools/Godot_v4.3-stable_win64_console.exe --headless --path repo -s tests/runner/test_<名>.gd`）：
> rxn_channel 37/0、elem_immune 22/0、mech_gate 33/0、rxn_codex 41/0、pkg5 139/0、feel 17/0、
> r191_rework 120/120、verify_feedback 630/0、pkg3 128/0、pkg0 129/0、history 13/0、fx_quality 29/0。
> 探索轮「本机无 Godot」不成立（二进制在 tools/ 下，多方向实跑）。R188 性能基线：500p/800p 三跑中位 P95<8.3ms。

---

## 0. 范围与总体结构

**目标**：元素 4→8（KIN/FIR/ICE/LTG + 新四元素），反应 3→20 键 + 1 留白（C(7,2)=21 配对全表），
跳字「中文名+数字」、七色单源、图鉴/成就/卡池接线，全部内容做成「数据驱动 + 机器守护」（validator 键集双射）。

**落地分段（里程碑阶梯，每级全绿再进下一级）**：

| 里程碑 | 内容 | 参与组 |
|---|---|---|
| M0 还账 | 超导削抗账本不对称修复 + reaction_cd 到期 erase | 战斗核 + 测试统包 |
| M1 文案单源/动态化批 | REACTION_NAMES + note.mult_fmt/sample + 图鉴 rid 无关化 + validator 四源双射闸（先在 3==3==3==3 落闸）+ card_generator 泛化 + run_reactions 成就 + 跳字「名+数字」（3 反应口径）| 底座 + UI内容 + 表现 + 战斗核(popup_manager) + 统包 |
| M2 元素扩容批（集成窗） | Element 4→8 + 免疫位 + gauges 8 槽 + 满槽钳制 + λ 四源 + validator 恰7/白名单 + 4 张卡 .tres + 门控显式分支 + MAP_INTROS + 七色表 + 散落色收敛 | 底座 + 战斗核 + 表现 + UI内容 + 统包（**枚举/门/卡必须同提交**） |
| M3 反应闭环原子翻转 | ReactionType 3→20 + reaction_table 20 键双源 + 结算核 20 臂 + 绽放延迟 + 扩散/结晶 + REACTION_LOOKS 20 + RXN_* 色 + 图鉴标注行 + 全部断言翻转 | 五组同批（validator 双射使半接线启动期报红） |
| M4 收口 | 全量 46 入口电池 + r188 性能三跑 + storm bench + FEEDBACK_TRACKER 回填 | 统包 |

---

## 1. 统合仲裁记录（分歧 → 裁定 → 依据）

| # | 分歧 | 裁定 | 依据 |
|---|---|---|---|
| 1 | 元素命名/序：elem `HYD/ANE/GEO/DEN=4/5/6/7` vs matrix `WAT/DEN/WND/GEO=4/5/6/7` | **采 HYD(水)=4 / ANE(风)=5 / GEO(岩)=6 / DEN(草)=7**（整案口径点名）；matrix 的 21 配对算术（7 参反应元素、KIN 不附着槽 0 弃用）与族模板**全部采纳**，仅按本序改名重排 id | `elemental_state.gd:48-49` apply 拒 FIR..LTG 外、槽 0 恒 0；ask 产出要求 §2 明示 HYD/ANE/GEO/DEN |
| 2 | 反应范围：elem PR-2 仅 4 旗舰对 vs matrix 全 21 | **全 21 表**（20 键 + 冰草留白）；elem 旗舰对 = 第 4 关批次切片 | 整案产出要求 §2 点名 21 配对全表 |
| 3 | 新元素解锁关：elem 水风@第4/岩草@第5 vs matrix 水@第4/草风岩@第5 | **matrix 案：水@第4关(idx≥3)，风/岩/草@第5关(idx≥4)**——水系三反应（蒸发/冻结/感电）全为新×旧配对，第 4 关单元素教学节奏干净；族反应（扩散/结晶）+草系具名聚拢第 5 关播报 | matrix ⑨ MAP_INTROS 文案已成稿；mechanic_gate.gd:21-27 既有 5 行结构只需改 2 行 |
| 4 | 新元素满槽语义：elem「钳制 GAUGE_MAX 不清零」vs matrix「无 _trigger 臂=静默清槽（有意）」 | **采 elem 钳制案**：`p_element>=HYD` 满槽钳在 GAUGE_MAX、不清零不触发，aura 存续为反应燃料。matrix 的静默清槽与其自身扩散族「满槽转移燃料」（`apply_attach(cand,X,GAUGE_MAX)` 后须被后续配对元素消费）自相矛盾，不采。分支按**元素身份**（p_element>=HYD）非 TRIGGER_NONE 返回码——:183/:202/:217 免疫与 :188-189 层满同样返回 TRIGGER_NONE，按返回码分支会腐化旧元素语义 | `elemental_state.gd:52-56` 先清零后 _trigger（旧三元素契约逐字节保留）；elem 一手复核 |
| 5 | 衰减 λ 值：elem「0.30~0.45 实现组定」vs matrix 逐元素值 | **matrix 逐元素值映射本序**：水 0.35 / 风 0.50 / 岩 0.25 / 草 0.30 → `element_decay_lambda = [0.35,0.30,0.40,0.35,0.50,0.25,0.30]`。0.50/0.25 出 elem 区间系有意（风衰减最快防扩散燃料滞留、岩最慢稳结晶垫），实现组不再自由裁量 | `elemental_state.gd:63-67` 槽 i−1 直索引，欠长静默兜底 0.35 |
| 6 | ELEM 卡池权重：elem A 档 10 不动 + B 档 20 兜底 vs wire 立即 10→14 | **wire 案 10→14 立即落地**（池 4→8 员，w=10 时每卡获取 −52% 过狠，w=14 → −32%）；elem B 档 20 保留为实测劣化（20 波 0 获取）升级路径。**三源同改**：`card_generator.gd:43` const + `balance_tables.gd:44` 默认 + `data/balance/balance_tables.tres:33`（运行时真源，`card_generator.gd:64-70` setup() 逐键覆写 const——单改 const 运行时无效，已验） | wire 数学 + card_generator.gd:42-45/:64-70 实读 |
| 7 | REACTION_LOOKS "text" 键：wire 保键（C5 锁不动）vs visual 删键（重构 {name,fill,outline,variant,fmt}） | **visual 案删键**——「中文名+数字」跳字必须由 name+数字纯函数装配，静态 text 键无法承载；C5 断言按纪律③翻转为 name/fmt 口径（非放宽）。wire「跳字格式归 visual」的自认管辖亦同 | `damage_popup.gd:64-83/:260-264` 实读；用户需求「名称后面跟同色数字」 |
| 8 | 图鉴样张：visual 运行时拼装 vs wire note.sample 单源 | **wire 案**：reaction_note 增 `sample` 字段（"1284"/"976"/"超导"→20 键全配），删 menu_screen :867-870 if/else；页面样张与跳字文案分源（sample=页面、look=跳字），注释注明 | `menu_screen.gd:865-883` 实读 |
| 9 | 冰+草：留白 | **留白 + 图鉴降透明标注行**（21 格唯一空配对；R191#4「选了火没反应」误报教训→把空白变规则）。无枚举成员/无表键/无门；标注行在图鉴循环后单独追加，文案走 GameConst 新常量 | matrix/多方向一致 |
| 10 | 测试锁「恰 3 反应」 | 一律改**动态口径**（行数==reaction_table 行数、键集合来自枚举），既有断言禁放宽禁删（纪律③） | wire 行源裁决 + elem ⑧ |

---

## 2. 七元素定义表

| 枚举 id | 序 | 中文名 | 卡 id | 色值（PopPalette.ELEMENT_COLORS） | 衰减 λ | 状态映射 | 解锁关 |
|---|---|---|---|---|---|---|---|
| KIN | 0 | 物理 | — | `Color(1,1,1)` 白（槽 0 恒 0 弃用，无位） | —（槽弃用） | 无附着 | — |
| FIR | 1 | 火 | ELE_IGNITE（既有） | `#ef7938` | 0.35 | burn（点燃 DOT，IMMUNE_BURN） | 第 2 关（既有） |
| ICE | 2 | 冰 | ELE_FREEZE（既有） | `#9fd6e3` | 0.30 | chill/freeze/vuln（IMMUNE_CHILL/FREEZE） | 第 2 关（既有） |
| LTG | 3 | 雷 | ELE_SHOCK（既有） | SHOCK=`#af8ec1`（本批改色；RARITY_EPIC #8b5dff 独立常量不动） | 0.40 | shock 连锁（IMMUNE_SHOCK） | 第 3 关（既有） |
| HYD | 4 | 水 | **ELE_HYDRO**（新） | `#4cc2f1` | 0.35 | **纯反应载体**：潮湿=谓词 gauges[HYD]>0（照 :108 LTG 先例），无持久状态键 | **第 4 关（idx≥3）** |
| ANE | 5 | 风 | **ELE_ANEMO**（新） | `#74c2a8` | 0.50 | **纯反应载体**：扩散族触发器，无持久状态键 | **第 5 关（idx≥4）** |
| GEO | 6 | 岩 | **ELE_GEO**（新） | `#fab632` | 0.25 | **纯反应载体**：结晶族触发器（玩家侧晶盾），无持久状态键 | **第 5 关（idx≥4）** |
| DEN | 7 | 草 | **ELE_DENDRO**（新） | `#a5c83b` | 0.30 | **纯反应载体**：燃烧/激化/绽放燃料，无持久状态键 | **第 5 关（idx≥4）** |

- 新四元素**不新增 element_states 键**（validator :417-418 为「必含 burn/freeze/shock」非封闭集，零改）；
  状态全由反应承载（matrix：水=附着垫料、草/风/岩状态全由反应承载，按设计）。
- 免疫位：`ELEM_IMMUNE_HYD=16 / ELEM_IMMUNE_ANE=32 / ELEM_IMMUNE_GEO=64 / ELEM_IMMUNE_DEN=128`
  （`game_const.gd:200-202` 注释明言 bit = 1 << Element；`enemy.gd:552-554` 通用式 `elem_immune & (1<<p_element)` 自动继承）。
- `Enemy.resist` 4→8 槽（`enemy.gd:24`）：29 份敌 .tres 全 4 项，`get_resist` 越界回 0.0 = 新元素 0 抗中性，
  **26+ 份敌 .tres 零改动**；`enemy_spawner.gd:161-164` r[2] 有 `r.size()>2` 守卫，追加序下标 2 恒 ICE，零改动。

---

## 3. idContract（唯一真源，逐字遵守）

### 3.1 Element 枚举全序（`game_const.gd:7` 尾部追加，禁重排禁删除）

```
KIN=0, FIR=1, ICE=2, LTG=3, HYD=4, ANE=5, GEO=6, DEN=7
```

### 3.2 新元素卡 id（resources/traits/，逐字段照 ELE_IGNITE.tres 模板）

```
ELE_HYDRO   （水，params.element=4，第 4 关）
ELE_ANEMO   （风，params.element=5，第 5 关）
ELE_GEO     （岩，params.element=6，第 5 关）
ELE_DENDRO  （草，params.element=7，第 5 关）
```

四卡统一：`pool=4 / pool_id=&"" / effect_id=&"EF_ELEMENTAL" / value=22.0 / event_hooks=[0,2] /
stack_max=2 / rarity=1 / condition={} / params={"element":4..7,"required_forms":[0,1,2]}`；
lv2 质变键仅用既有封闭四键（dot_ratio/chain_targets/chain_decay/spread_radius_lv2）；
**禁 threshold_only=true**（card_generator.gd:446-447 永不上架）；id 全局唯一（现存仅
ELE_IGNITE/ELE_FREEZE/ELE_SHOCK/ELE_REACTION_VOID/ELE_ARC_SURGE）；目录扫描自动入册
（data_registry.gd:88-112），重复后者剔除。

### 3.3 反应 21 配对全表（id 沿用「低枚举序元素在前」；现役 3 键原样保留）

| # | id | 中文名 | 配方 | 类型 | 数值（reaction_table 表键） | CD | 优先级 | 解锁关 | 族 |
|---|---|---|---|---|---|---|---|---|---|
| 1 | RXN_FIR_ICE | 碎裂 | 火+冰 | DOT 引爆 | `coef:2.0` ×点燃剩余 DOT 池 | 2.0s | 1 | 第 2 关 | 现役 |
| 2 | RXN_FIR_HYD | 蒸发 | 火+水 | 即时快照 | `coef:1.5` ×S_snap | 2.0s | 2 | 第 4 关 | 具名 |
| 3 | RXN_HYD_DEN | 绽放 | 水+草 | 延迟 AoE | `coef:1.5 / radius:120.0 / delay:0.75`（R198 调参：delay 1.5→0.75，双源同批见 balance_tables.gd/.tres） | 2.0s | 3 | 第 5 关 | 具名 |
| 4 | RXN_FIR_LTG | 过载 | 火+雷 | AoE 快照 | `coef:1.2 / radius:90.0` | 2.0s | 4 | 第 3 关 | 现役 |
| 5 | RXN_FIR_ANE | 扩散·火 | 风+火 | 族模板·扩散 | `coef:0.8 / radius:120.0 / targets:3` | 2.0s | 5 | 第 5 关 | 扩散族 |
| 6 | RXN_ICE_ANE | 扩散·冰 | 风+冰 | 族模板·扩散 | 同模板（转移冰） | 2.0s | 6 | 第 5 关 | 扩散族 |
| 7 | RXN_LTG_ANE | 扩散·雷 | 风+雷 | 族模板·扩散 | 同模板（转移雷） | 2.0s | 7 | 第 5 关 | 扩散族 |
| 8 | RXN_HYD_ANE | 扩散·水 | 风+水 | 族模板·扩散 | 同模板（转移水） | 2.0s | 8 | 第 5 关 | 扩散族 |
| 9 | RXN_ANE_DEN | 扩散·草 | 风+草 | 族模板·扩散 | 同模板（转移草） | 2.0s | 9 | 第 5 关 | 扩散族 |
| 10 | RXN_ICE_HYD | 冻结 | 冰+水 | 硬控 | `freeze_dur:1.2 / chill_dur:2.5 / vuln_mult:1.25 / vuln_dur:3.0`（复用既有 freeze/chill/vuln 字段，刷新语义不改键） | 2.0s | 10 | 第 4 关 | 具名 |
| 11 | RXN_LTG_HYD | 感电 | 雷+水 | 连锁 | 读 `element_states.shock` 全套（3 目标/160px/35%/深 2）+ `shock_chain_cd=1.0` 护栏（零新字段） | 2.0s | 11 | 第 4 关 | 具名 |
| 12 | RXN_FIR_DEN | 燃烧 | 火+草 | DOT 强化 | `burn_layers_max:5 / burn_dur:3.0`（立即满层点燃，快照=last_attach_snapshot；无 χ 不进管线） | 2.0s | 12 | 第 5 关 | 具名 |
| 13 | RXN_LTG_DEN | 激化 | 雷+草 | 纯减益 | `vuln_mult:1.25 / vuln_dur:3.0`（复用 vuln_timer/vuln_mult 池刷新；无 χ） | 2.0s | 13 | 第 5 关 | 具名 |
| 14 | RXN_ICE_LTG | 超导 | 冰+雷 | 纯减益 | `resist_delta:-0.3 / duration:6.0` | 2.0s | 14 | 第 3 关 | 现役 |
| 15 | RXN_FIR_GEO | 结晶·火 | 岩+火 | 族模板·结晶 | `dr:0.15 / dr_dur:6.0`（无 χ） | 2.0s | 15 | 第 5 关 | 结晶族 |
| 16 | RXN_ICE_GEO | 结晶·冰 | 岩+冰 | 族模板·结晶 | 同模板 | 2.0s | 16 | 第 5 关 | 结晶族 |
| 17 | RXN_LTG_GEO | 结晶·雷 | 岩+雷 | 族模板·结晶 | 同模板 | 2.0s | 17 | 第 5 关 | 结晶族 |
| 18 | RXN_HYD_GEO | 结晶·水 | 岩+水 | 族模板·结晶 | 同模板 | 2.0s | 18 | 第 5 关 | 结晶族 |
| 19 | RXN_DEN_GEO | 结晶·草 | 岩+草 | 族模板·结晶 | 同模板 | 2.0s | 19 | 第 5 关 | 结晶族 |
| 20 | RXN_ANE_GEO | 结晶·风 | 风+岩 | 族模板·结晶 | 同模板（原神风不扩散岩，归结晶单占） | 2.0s | 20 | 第 5 关 | 结晶族 |
| — | （无反应） | 留白 | 冰+草 | 留白 | 无枚举成员/无表键/无门/无解锁；图鉴追加 1 条降透明标注行，文案走 GameConst 新常量 | — | — | — | 留白 |

**族账目**：「2 模板 12 实例」系名义双记——风族名义 6 + 岩族名义 6，{ANE,GEO} 一对只能归一家（归结晶），
去重后 5 扩散 + 6 结晶 = 11 族实例。总账：3 现役 + 6 具名 + 11 族 + 1 留白 = 21 ✓。
ReactionType 枚举 3→20（`game_const.gd:178` 追加保序）、reaction_table 20 键双源、RXN_ORDER 20 项。
**按 12 实例落表会出重复臂 + 同帧双结算，禁止。**

**优先级层化口径**：T1 伤害转化（χ>0）> T3 减益/工具（无 χ）；同层按 控场 > 连锁 > DOT > 易伤 > 削抗 > 护体。
碎裂(1)>过载(4)>超导(14) 头部相对位保持——pkg3「三槽齐备仅碎裂」与 rxn_channel CD 剩余秒锁不动；
FIR+ICE+LTG 三槽时新反应无一对双槽齐备 → D4 锁行为不变。

---

## 4. 反应实现规格（锚点均一手实读）

- **现役 3 臂**（`elemental_system.gd:176-207`）行为逐字节不变；`rule.get` 硬兜底默认
  （:178 `{"coef":2.0}` / :188 / :198）删除——表键缺失 = validator 报警 + 结算侧走 _nf 告警，不静默默认值。
- **蒸发**：`_settle_reaction(p_enemy, last_attach_snapshot, coef×rm, RXN_FIR_HYD)` + 清双槽（照过载主目标路径 :192）。
- **绽放**：写 `bloom_timer/bloom_snapshot_atk`（ElementalState 新增 2 字段）+ 清双槽；tick 到期消费
  （照 `consume_superconduct_expired` :139-144 模式）→ 到期 AoE `χ1.5 r120` 快照结算；
  `_spread_reaction` 加 `p_rxn` 参数去 :250 硬编码。
- **冻结**：写既有 freeze/chill/vuln 字段（`freeze_timer=1.2 / chill_timer=2.5 / vuln_timer=3.0`），
  与冰二次满槽冻结同名同义，双源叠加只刷新不漂移；IMMUNE_FREEZE/CHILL 照 _trigger 既有位检查。
- **感电**：调既有 `_shock_chain(origin, last_attach_snapshot, targets)`（:279 签名现成）+
  `shock_chain_cd = 1.0` 护栏（照 :106 二次防抖先例），零新字段。
- **燃烧**：`burn_layers=5 / burn_timer=3.0 / burn_snapshot_atk=last_attach_snapshot`（复用既有燃烧字段；无 χ 不进管线）。
- **激化**：`vuln_timer=3.0 / vuln_mult=1.25` 池刷新。
- **扩散族**（新增 `_spread_attach`，同构 `_spread_reaction` :235-250）：主目标直伤 χ0.8×S_snap +
  半径 120 内至多 3 敌满槽转移被扩元素 X（照燎原传火口径 `apply_attach(cand, X, GAUGE_MAX, {snapshot})`；
  **候选必须 append_array 拷贝**——满槽雷触发 _shock_chain 嵌套 query_circle 复用内部缓冲，
  space_grid.gd:74 明示返回引用）+ 清双槽。
- **结晶族**：发 `crystal_shield_request` 信号（§7）+ 清双槽；无 χ 不进管线。
- **调度不变式（禁改）**：一帧一反应/敌 break（:145-152）、单 `_uid_reaction` 幂等键（:26,216）、
  全清双槽契约、反应检测在帧末⑤（game_loop.gd:205-206 tick→detect）、cd_rxn=2.0 每反应独立键（:38,146,150）。
- **检测扩容形态**：per-host 非 KIN 槽位掩码 → 启动期预展开 2^7 位掩码 → 有序候选短表，只验掩码命中候选
  （线性 21 检/宿主/帧在 R189 P95 余量 0.45-0.65ms 下是被禁形态）；掩码表 k≤1 宿主零候选。
  「掩码表稳态≈现状」是推演非实测，动工后必须实测定验收（M4 r188 三跑）。

---

## 5. 底座技术裁定

1. **枚举只追加不重排**（一手复核全链）：免疫位通用式（enemy.gd:552-554）+ bit=1<<Element 注释
   （game_const.gd:200-202）；λ 按槽 i−1 直索引（elemental_state.gd:63-67）；resist 按枚举下标 +
   get_resist 越界回 0.0；spawner r[2] 尺寸守卫；ConditionId 裸 int 落 .tres、词条存档仅 {id,layers}；
   codex/traits 按 id 字符串裸读写（meta_manager.gd:838-839/:864-866）——**既有 5 个 ELE_* id 与成就 id 不可改名不可删**。
2. **λ 四源同步**：`balance_tables.gd:47` 默认 + `balance_tables.tres:35` + `data_validator.gd:414` 恰 3→恰 7 +
   `elemental_system.gd:114` 硬编码兜底 [0.35,0.30,0.40,0.35,0.50,0.25,0.30]——**同批落地**，漏改 = 整字段静默回退仅 push_warning。
3. **校验闸分级**：:163 resist 恰 4 项与 :167-168 免疫位白名单是 _err（整只剔除）→ :167 **必须补 4 新位**
   （白名单拓宽非绕过，防未来免疫数据被静默剔除）；:163/:417 与 26+ 份敌 .tres **零改动**；
   :414 与 λ 数据同批；:419-424 反应闸升级：`coef∈(0,2.0]`（有 coef 键时）、`resist_delta∈[-0.8,0.8]`
   （对齐运行时钳 elemental_system.gd:394）、`duration/radius/delay>0`、reaction_table 键集合==ReactionType
   成员 id 集（动态断言非硬编码）——全部非致命字段级回退口径。
4. **四源键集双射闸（wire 核心守护产出，M1 先行落闸）**：`ReactionType 键集 == reaction_table 键集 ==
   reaction_note 可枚举键集 == REACTION_LOOKS 整型键集`，且每键 note 必填 7 字段非空
   （name/recipe/elements/effect/unlock/mult_fmt/sample）、`mult_fmt` token 键 ⊆ rule 键、
   `elements.size()==2`；缺项走 _nf 报告通道。**枚举先扩表未补 → A5/X3/D0/validator 同红，半接线不可静默。**
5. **门控两处 fall-through（同批显式登记，禁兜底）**：`mechanic_gate.gd:76-81` ELEM match 仅 FIR/ICE/LTG，
   新元素落 :81 兜底 `return shock_unlocked()` = 第 3 关静默全上架（探针实测 map2 起 8 卡全出）；
   MULT 池 :82-88 未登记 condition_id fall-through :88 return true = 第 1 关死卡。新门函数：
   `water_unlocked()`（idx≥3）/ `final_elem_unlocked()`（idx≥4）；ELEM match 显式补
   HYD→water、ANE/GEO/DEN→final_elem 分支。TARGET_WET 类条件卡未登记齐
   （ConditionId 插 NONE 前 + MULT_POOL_IDS + 门分支 + is_state_active 增槽量口径）前**禁上**（后置 v2）。
6. **附着通道零改动（已验）**：R191 双守卫纯 int 比较（trait_effect_elemental.gd:26-29/:40-46）、
   `_shot_element`/dominant_element 通用 int（weapon_base.gd:288-313）、SPECTRA 轮转、EF_ELEMENTAL
   按 params["element"] 输出——新元素卡零代码继承。接收端唯一堵点 `elemental_state.gd:48-49` 硬区间 +
   gauges 4 槽（:20 声明/:155 reset 字面量）——**两处同步扩 8，缺一即越界崩溃或静默丢弃**；
   :48 守卫改按枚举界（`p_element<=KIN 或 >=Element.size()` 拒绝）。
7. **ARC_SURGE 不附着三重结构保持**（pool=1 MULT / params 无 element 键 / condition_id=2；
   trait_effect_elemental.gd:19 非 ELEM 池早退；weapon_base.gd:288-301 要求 params.has("element")）——零改动。
   新条件乘区卡保持同构（MULT 池 + 无 element 键）。
8. **存档零结构改动**：run_save 仅 {id,layers}、settings 白名单 7 键无元素交集、图鉴页零存档键、
   新卡 id 只事后追加 codex_weapons/codex_traits（无白名单遍历）。结晶减伤为纯会话态不进存档。

---

## 6. 前置还账（M0，先还旧账再扩容）

1. **超导账本不对称修复**（现症：未到期重触 −0.3×N、到期仅 +0.3×1 → 净削抗永驻）：
   `apply_superconduct` 记 `superconduct_delta` 字段（elemental_state.gd:147-150）、激活期重触只刷新
   superconduct_left 不重复扣、到期 consume 后按记录 delta 恢复一次（elemental_system.gd:397-399
   `_restore_resist` 去硬编码 +0.3）。**先修再上任何第二条减益反应（激化/结晶）。**
2. **reaction_cd 到期 erase**（elemental_state.gd:80-81 现只减不删，21 反应长局每敌膨胀 ≤20 键）。

---

## 7. 结晶玩家侧规格

- `EventBus` 新增 `crystal_shield_request` 信号（ElementalSystem 无 player 引用 :19-26）。
- `Player` 新增 `dr_left/dr_value` 字段 + grant/clear API；`take_contact_damage` 减伤闸插在
  **无敌帧/格挡闸后、HP 直减前**（player.gd:297-319 唯一漏斗，9 调用点已核）；
  tick 衰减 + 复活/死亡清零；纯会话态零存档迁移。
- 数值：15% 减伤 6s，刷新不叠加。完整吸收池晶盾（全工程无数值吸收通道，MEC_SHIELD 是整挡格挡）排二期。

---

## 8. 跳字规范（批 1 文本 → 批 2 色，每批独立五套件全绿再进下一批）

### 8.1 文本批（M1 内的 visual 批 1）

- **单 Label 同行、无空格拼接**：「碎裂1284」「过载976」「超导-30%」（负号 ASCII '-'，`%d%%` 口径）。
  整串共用 look.fill/look.outline 双色通道 + 同 font_reaction(variant) 字型桶。
  如实陈述：Windows 雅黑仅 Regular/Bold 真字重（theme.gd:40-41 自注），中文名与 Arial Black 数字非真同款
  字形；实机不可接受时只降 theme.gd 参数（表结构与缓存不动）。
- **REACTION_LOOKS 三行重构**：`{name, fill, outline, variant, fmt}`，删除 "text" 键；
  `name` 单源 `GameConst.REACTION_NAMES`（枚举键→中文名；reaction_note 的 name 字段同引此 const，
  const 交叉引用先例 damage_popup.gd:65）。
- **文本 = 纯函数 f(look, merged_value, rxn_stat)**：`_apply_reaction_look` 废除 :260-264 gate；
  fmt 派生文案，merge/upgrade 只改数值、R189 tick 每帧一次 _refresh_label 不变。
- **纯功能反应数字口径**（新反应通盘）：
  | 型 | 反应 | 跳字 | 口径 |
  |---|---|---|---|
  | dmg | 碎裂/过载/蒸发/绽放（主目标） | 名 + `int(round(merged_value))` | 伤害结算值 |
  | stat | 超导 | 「超导{resist_delta_pc:.0f}%」→ -30% | 起字时读表一次性格式化，merged_value 恒 0.0 |
  | stat | 激化 | 「激化+{vuln_add_pc:.0f}%」→ +25% | (vuln_mult−1)×100 |
  | stat | 结晶·X | 「结晶·X-{dr_pc:.0f}%」→ -15% | dr×100 |
  | stat | 冻结 | 「冻结{freeze_dur:.1f}s」→ 1.2s | 时长 |
  | stat | 燃烧 | 「燃烧{burn_layers_max:.0f}层」→ 5层 | 读表 burn_layers_max（R198 回写：实现侧跳字/图鉴实带层数——game_const.gd mult_fmt「至多 {burn_layers_max:.0f} 层」+ damage_popup.gd「%d层」，非「无数」） |
  | stat | 感电/扩散·X | 「感电」「扩散·X」 | 无数（链伤/转移各走自身通道，另跳数字——合法无统计段，纯名） |
  - 超导 `-30%` 在 on_reaction_triggered 起字时读 `reaction_table["RXN_ICE_LTG"]["resist_delta"]`
    一次性格式化（roundi(delta*100)；缺键兜底 -0.3，同 menu_screen.gd:900 先例），经 DamagePopup
    新字段 `rxn_stat` 传入（_reset_state/_clear_reaction_overrides 同步清空，防池复用串文案）。
    **禁把数值写进 const 文案表**；**禁显「实时总削减」**（存量不对称 bug 由 M0 修复，显示口径=本次触发削抗幅度）。
  - 文本标签门（popup_manager :196-197）由单 id 扩为集合：{超导, 激化, 结晶×6, 扩散×5, 冻结, 感电, 燃烧}。
- **R2c 防叠补缺口**：`_reaction_host_alive`（popup_manager.gd:312-322）只查 bucket1 →
  扩判据 bucket1 OR bucket3（「超导-30%」248px 宽一倍多，直击小字 +20px 下移对文字桶同样生效）；
  TEXT_LABEL_OFFSET 不动。
- **图鉴预览同步**：样张单源 `note.sample`（删 :867-870 if/else）；预览 Label 加
  `DamagePopup.CODEX_PREVIEW_SCALE=0.5` + `pivot_offset=size*0.5` 适配 140×78 格
  （实测 241~257px×0.5≤140、73×0.5≤78）；不改字号（必破五项对位断言）、不加宽格子。
- **字体**：复用 theme.gd 3 桶零改动（variant 是表现族维度非反应维度；扩 variant 必须同步 theme.gd:12/:42
  否则静默落桶 0；字型 variant 复用 0/1/2 钳制，不加字型资产）。

### 8.2 色批（M2 内的 visual 批 2）

- **PopPalette 新增 `ELEMENT_COLORS`（键=Element 序 int，七键）**：KIN 白 / FIR `#ef7938` / ICE `#9fd6e3` /
  LTG=SHOCK（SHOCK 同批 `#8b5dff`→`#af8ec1`；RARITY_EPIC `#8b5dff` 独立常量不动）/
  HYD `#4cc2f1` / ANE `#74c2a8` / GEO `#fab632` / DEN `#a5c83b`。四色对藏青描边 `#22254a`
  对比 5.21/9.22/5.21，贴纸字机制不破坏。palette.gd:30-31 避让注释按新火重写；RXN_* 六常量值不动。
- `damage_popup.gd` 删本地 ELEMENT_COLORS（:53-58），:228-229 改读 PopPalette.ELEMENT_COLORS；
  `menu_screen.gd:818` 同步改引（改表即跳字 + 图鉴环自动跟随）。
- **散落副本收敛**（base 换表色、派生 lerp/渐变结构保留）：laser_beam.gd:136/:138；
  orbit_field.gd:864/:866（FIR 已漂移 0.55≠表 0.6）；projectile_base.gd:858-860（:901 SHOCK 派生自动跟随）；
  weapon_orbit_avatars.gd:92-97（:88 W7 橙红是武器身份不动）；enemy.gd:759-763 + :2461 寒滞冰蓝；
  elemental_fx_layer.gd:296/:322/:324/:327/:855/:1016-1019（flash/smoke/ember 渐变停留）。
- **坏 ID 兜底**（damage_popup.gd:249-250 / menu_screen.gd:862-864）由静默落碎裂改
  `push_error` + 落首键 look（禁静默；rxn8 探针措辞同步）。
- 「反应色随主元素」降 R192 后续（本批 RXN_* 不动则对位断言原样过）；附着量表可视化不在本批。

---

## 9. 解锁节奏、卡池权重与播报

- 门函数：`water_unlocked()`（idx≥3）/ `final_elem_unlocked()`（idx≥4）；ELEM match 显式分支
  （HYD→water；ANE/GEO/DEN→final_elem），消除 :81 fall-through。
- MAP_INTROS（mechanic_gate.gd:21-27）第 1-3 行不动，第 4 行改「满层质变｜**水元素卡**｜新反应：蒸发 · 冻结 · 感电」，
  第 5 行改「诅咒博弈｜**草 / 风 / 岩元素卡**｜新反应：燃烧 · 激化 · 绽放 · 扩散族 · 结晶族」
  （保留原主题词 + 追加段）；播报走既有 `mechanics_intro` 通道（零新事件，防回环双增；每局恰一次）。
- 卡池权重：`category_weights` ELEM **10→14**（三源同改：card_generator.gd:43 + balance_tables.gd:44 +
  balance_tables.tres:33；校验只查和>0 自动过）；elem B 档触发指标（实测终局 8 卡 20 波新元素卡 0 次获取）
  → 14→20，写 PR 描述备用。
- card_generator 泛化：`if p_data.params.has("reaction_mult"): return _replace_first(desc, "×%.1f"%float(params.reaction_mult), "×%.1f"%(value*p_scale))`
  ——ELE_REACTION_VOID params 本就含该键（.tres 实读），金卡 value 4.68/卡面「×4.7」逐字节不变
  （verify_feedback:2953-2957 锁）；**禁按「×N 字样」分流**（_scaled_description 会按 1+(N−1)×scale 错印直乘卡）。
- 成就接线（run 作用域）：`_run_reactions` 计数 + `_ready` 订阅 `reaction_triggered` + handler +
  ACH_TIER_TABLE +1 条（type=run_reactions, targets=[10,25,50], rewards=[0,0,30]；全表 1435+30=1465≤1500💎、
  条数 131∈[120,200]）+ `_counter_value` 臂 + `_reset_run_counters` 行 + `_check_achievements` counters 字典键
  （**后两者缺一即永久漏检**）。achievements_changed 通道零改动。

---

## 10. 告警线与 χ 纪律

- `r_rxn_ratio=50` **值不变**；管线告警与钳制按「每笔结算 coefficient>50」判（damage_pipeline.gd:103-108），
  配对数结构性不进口径。新矩阵伤害反应（蒸发 1.5/绽放 1.5/过载 1.2/扩散 0.8）全用快照基且 χ≤1.5——
  单源金 φ4.68 时最高 coef=7.02，×50 余量 7.1×，不误报。
- **禁止新增 DOT 池基反应**（碎裂是唯一池基例外：snapshot 传参即 DOT 池本身 elemental_system.gd:179-181，
  ×50 对它非 |D|/S 绝对上界——失真现网已在，本批不改行为只补注释）。
- `balance_tables.gd:61-64` 推导注释重写三处失真：①φ 锚 1.8 过期（weapon_base.gd:122-127 改读
  data.value × card_generator.gd:56 金梯 2.6→4.68）；②reaction_mult 多源连乘（elemental_system.gd:80-85）
  3 金 VOID≈205>50 可达——写明「×50 在多源构筑下即实际伤害帽」，新反应强化卡维持单源纪律
  （镜面先例 player.gd:829-830），不新增第二注册源；③碎裂池基特例注明。
- **χ≤2.0 红线**：若引入更大倍率必须先复算告警线并落注释。

---

## 11. 文件 → 组所有权表（恰 5 组，组间零重叠）

| 组 | 独占文件 | 要点 |
|---|---|---|
| **数据底座** | scripts/core/game_const.gd；scripts/core/data/resources/balance_tables.gd；data/balance/balance_tables.tres；scripts/core/data/data_validator.gd；resources/traits/ELE_HYDRO.tres；ELE_ANEMO.tres；ELE_GEO.tres；ELE_DENDRO.tres | 枚举/常量/双源数值/校验闸/新卡数据——**新枚举值、新表键、新常量、新函数签名的唯一产地** |
| **战斗核** | scripts/combat/elemental/elemental_state.gd；elemental_system.gd；scripts/entities/enemy/enemy.gd；scripts/entities/player/player.gd；autoload/event_bus.gd；scripts/meta/mechanic_gate.gd；scripts/ui/popup_manager.gd；scripts/gamefeel/elemental_fx_layer.gd；scripts/loop/game_loop.gd；scripts/combat/weapon/laser_beam.gd；scripts/combat/weapon/melee/orbit_field.gd；scripts/combat/projectile/projectile_base.gd；scripts/entities/player/weapon_orbit_avatars.gd | 状态容器/结算核/门控/玩家结晶/反应 FX/SFX/散落色收敛/popup_manager 起字 |
| **表现** | scripts/ui/damage_popup.gd；scripts/ui/palette.gd | REACTION_LOOKS/跳字纯函数/七色单源表 |
| **UI内容** | scripts/ui/menu_screen.gd；scripts/cards/card_generator.gd；scripts/meta/meta_manager.gd | 图鉴动态化/token 格式化器/卡面泛化/成就接线 |
| **测试统包** | tests/runner/rxn_codex_cases.gd；r191_rework_cases.gd；mech_gate_cases.gd；rxn_channel_cases.gd；elem_immune_cases.gd；fx_quality_cases.gd；pkg3_cases.gd；pkg5_cases.gd；test_elem_smoke.gd（新）；elem_smoke_cases.gd（新）；qa_rxn6_codex_probe.gd；docs/design/R191_CODEX_REACTION.md；FEEDBACK_TRACKER.md | **tests/** 全部单组认领（R191 夹具教训）；断言翻转/新增/收口电池 |

不触碰（零改动面）：enemy_spawner.gd、trait_effect_elemental.gd、weapon_base.gd、laser_weapon.gd、
theme.gd、run_save.gd、data/manifest.cfg、26+ 份敌 .tres、tests/runner 其余套件（pkg0/pkg1/pkg2/pkg4/
pool_wiring/p1_polish/verify_feedback/history/feel 等只跑不改）。
elem 方向原拟 docs/design/ELEMENT_SEVEN_EXPANSION.md **不再另立**（本文件即唯一设计文档，防双源）。

---

## 12. 里程碑 × 跨组联动（sharedChanges）

1. **idContract 唯一真源**：所有组只引用 GameConst 枚举与 §3 表，禁自创别名；新枚举值/新表键/新函数签名
   先落数据底座组，其余组只引用不自建。
2. **M1 顺序**：底座（REACTION_NAMES/note.mult_fmt+sample/validator 双射闸在 3==3==3==3 时落闸）→
   UI内容（menu_screen rid 无关化 + card_generator 泛化 + 成就）+ 表现（look 重构）+ 战斗核（popup_manager
   rxn_stat/R2c）+ 统包（动态断言翻转）——此时全绿（仍 3 反应）。
3. **M2 集成窗原子性**：Element 枚举（底座）+ mechanic_gate 显式门分支（战斗核）+ 门/冒烟测试（统包）
   **同一提交**；枚举先行而门未落 = 第 3 关 fall-through 静默上架。PopPalette.ELEMENT_COLORS（表现）
   先于战斗核散落色收敛引用。λ 四源同批。
4. **M3 原子翻转**：底座（ReactionType/reaction_table/note 20）+ 战斗核（RXN_ORDER/_condition/_trigger/
   _spread_attach/bloom/crystal）+ 表现（REACTION_LOOKS 20 + RXN_* 色）+ UI内容（标注行）+
   统包（三源 size 动态断言）**同批**；validator 双射使半接线启动报红。
5. **数值双源/三源**：λ、reaction_table、category_weights ELEM 均 .tres+.gd 同批同值
   （setup() 用 .tres 逐键覆写常量——单改常量运行时无效，已验）。
6. **播报唯一通道** mechanics_intro；MAP_INTROS 行文本战斗核改，mech_gate_cases :145-148「每图 intro 非空」保持。
7. **M0 超导修复**先于任何第二条减益反应（激化/结晶）落地。
8. **红线全组遵守**（§14）。

---

## 13. 电池兼容与断言更新清单

### 13.1 本批有意变更（按新矩阵口径改动态断言，禁放宽语义）

| 文件 | 变更 |
|---|---|
| rxn_codex_cases.gd | :89-92 note 闭集 5→7 字段 + has_all(mult_fmt/sample)；:116-118 B1 保字面序 0/1/2、size==3 → ==reaction_table.size()；:120-122 B2 恰 3 → 表键集==枚举键集；:134-135 B7 → LOOKS 键集==枚举值集；:152-154 C5 改 name/fmt 断言；:248 D0 → 动态；:249-253 keys/fills/lines 与 :255-320 循环 mini(...,3) 表驱动；:285-293 样张 → ==note.sample；:338/:347 rows.size()==3 → 动态；:356-375 存档零写入**原文保留** |
| r191_rework_cases.gd | :341-342 B2 闭集 5→7；:344-361 三名/优先级句按新序；:1122-1124 keys/fills/lines、:1127 X4 循环、:1168-1169 rows==3 → 动态；X7:1184-1197 存档零写入**原文保留**；F 组**新增** run_reactions 用例（直调 Meta._on_reaction_triggered 至 10 → 解锁、crystals 仅终档 +30、结算复位、F16/F1/F15 续绿） |
| mech_gate_cases.gd | 集成窗后 ADD：idx0/1/2 新元素卡全 false；idx3 仅 ELE_HYDRO true；idx4 全 8 卡 true；MAP_INTROS[3]/[4] 含新反应名；播报一次（既有 :104-111/:145-148/:172-185 原文保留） |
| fx_quality_cases.gd | :138→「碎裂12」、:166→「过载20」、:191→「超导-30%」；新增：merge 后 text==名+新值、超导 merged_value==0.0 且 bucket3 拒值并入仍过、直击遇存活 bucket3 offset==(0,20)、预览 scale==0.5 |
| elem_immune_cases.gd | :168-173 期望色改新七色值（保持硬编码防漂移，0.03 容差）；反应环计数(:219,:227)独立分段清场；新增 elem_immune=16 拒附着 |
| rxn_channel_cases.gd | **新增** 7 类行为用例：蒸发结算值/冻结时长/感电链/燃烧满层/激化 vuln/绽放延迟爆发/扩散转移+结晶减伤；附着段：HYD 累积、满槽钳制不清零、FIR 满槽旧语义不变、HYD+LTG has_both、λ 新槽衰减；CD 到期 erase（字典 size 回落）；444-473 既有 3 反应数值锁**原文保留** |
| pkg5_cases.gd | B.6 扩反应矩阵告警线（20 反应逐条注入 coef>50 → 钳至 S_snap×50+alarm+一局一次；coef≤50 最大构筑 7.02 不钳）；:349-351 r_rxn=50.0 原文保留 |
| pkg3_cases.gd | 「三槽齐备仅碎裂」原用例**不改仍过**（:1253-1319 保留） |
| 新增 | tests/runner/test_elem_smoke.gd + elem_smoke_cases.gd：Element.size()==8、序数 0..7、免疫位 16/32/64/128、ReactionType 演进口径、λ .tres 与 .gd 逐位一致、validator 3 项 λ 输入告警回退；validator 键集探针（进程内删表键→报告含 error；reaction_mult=2.2 假卡金品质→卡面 ×5.7 且 VOID 仍 ×4.7）；「仅带旧 3 键 reaction_table 的 .tres 加载→仅告警不拒启」 |
| 其他 | qa_rxn6_codex_probe.gd:72-73 措辞；docs/design/R191_CODEX_REACTION.md:328-335 样张句 |

### 13.2 必须保持（原样绿，禁放宽禁删）

存档零写入双断言（rxn_codex:356-375 + r191 X7）；F15/F16/F1（r191:887/:1089-1092/:1094-1100）；
pkg3 三槽仅碎裂；rxn_channel:444-473 与 test_formula_pipeline.gd:687-718 既有 3 反应行为数值
（coef 2.0/1.2、resist -0.3/dur 6、cd_rxn 2.0）；pkg5:349-351 r_rxn=50.0；verify_feedback:2953-2957
VOID 金卡 4.68/×4.7；A5（rxn_codex:198-199）/X3（r191:1120-1121）==ReactionType.size()（不变式成立时恒真）；
枚举只追加（rxn_codex:390-414 字面量元素 1/3、gauges 直索引）；pkg0:668 ADD==16；p1_polish:163-164
WEAPON=14；pool_wiring 零 ELEM 锁；F11 fired_families 免改（:981-985 门控 + 测试窗零反应）；
「第 1 关 ELEM 候选空」既有断言。

---

## 14. 红线清单（两批通用，全组遵守）

1. Element/ReactionType/ConditionId/MULT_POOL_IDS/ELEM_IMMUNE_*/IMMUNE_* 只追加不重排不删除。
2. 既有 5 个 ELE_* 词条 id、3 条反应键、成就 id 永不改名不删（存档裸读写零校验）。
3. 存档层零结构改动（run_save 仅 {id,layers}、settings 白名单不触；结晶纯会话态）。
4. 旧三元素行为逐字节不变（满槽清零→_trigger、R191 双守卫、_shot_element 交替、rxn_channel 既有断言保绿）。
5. ARC_SURGE 不附着三重结构保持。
6. 新 id 全局唯一；新数据键/新词条过 DataValidator 口径；先改 validator 闸再落数据。
7. 解锁播报走 mechanics_intro 既有通道（防回环双增）。
8. χ≤2.0（超限先复算 r_rxn_ratio=50 推导并落注释）；禁新增 DOT 池基反应。
9. 起字点冻结现 3 处（damage_pipeline.gd:117+120/:259、elemental_system.gd:205-206）禁第 4 处；
   popup_manager :196-197 碎裂/过载禁经 reaction_triggered 起字（settle 已广播，二次必翻倍）。
10. popup 契约不动：R4c ≤0.5 短路（:131-132）、REACTION_FRAME_CAP[1,2,3]（:50）、_mkey=uid*8+bucket
    （:251-253）、bucket3 拒值（:287-291）、池 80/同屏上限/窗 0.12、merge 只置脏 + tick 每帧一次（:156-158）。
11. 色只经 const+override/modulate，禁运行期喂 TextureFactory（ring_tex 缓存键含色 hex :1046-1050）。
12. 风暴消费链放大 ≤2.5× 门不松；一帧一反应/单 _uid_reaction 幂等键/全清双槽契约/反应检测帧末⑤禁改。
13. 网格查询拷贝纪律（append_array）照旧；E-03 帧闸照旧。
14. 调度性能：M4 必须交付 r188 同口径 500p/800p 各 3 跑中位 P95<8.3ms（随扩容同包，不得后补）。

---

## 15. 验收命令与基线

```
tools/Godot_v4.3-stable_win64_console.exe --headless --path repo -s tests/runner/test_rxn_channel.gd    # 基线 37/0 → 扩后 FAIL 0（含新用例）
tools/Godot_v4.3-stable_win64_console.exe --headless --path repo -s tests/runner/test_elem_immune.gd   # 22/0
tools/Godot_v4.3-stable_win64_console.exe --headless --path repo -s tests/runner/test_mech_gate.gd     # 33/0
tools/Godot_v4.3-stable_win64_console.exe --headless --path repo -s tests/runner/test_rxn_codex.gd     # 41/0（size 锁已翻动态）
tools/Godot_v4.3-stable_win64_console.exe --headless --path repo -s tests/runner/test_pkg5.gd          # 139/0（B.6 扩）
tools/Godot_v4.3-stable_win64_console.exe --headless --path repo -s tests/runner/test_feel.gd          # 17/0 零改
tools/Godot_v4.3-stable_win64_console.exe --headless --path repo -s tests/runner/test_r191_rework.gd   # 120/120
tools/Godot_v4.3-stable_win64_console.exe --headless --path repo -s tests/runner/test_verify_feedback.gd # 630/0
tools/Godot_v4.3-stable_win64_console.exe --headless --path repo -s tests/runner/test_pkg3.gd          # 128/0（三槽仅碎裂不改仍过）
tools/Godot_v4.3-stable_win64_console.exe --headless --path repo -s tests/runner/test_pkg0.gd          # 129/0
tools/Godot_v4.3-stable_win64_console.exe --headless --path repo -s tests/runner/test_history.gd       # 13/0
tools/Godot_v4.3-stable_win64_console.exe --headless --path repo -s tests/runner/test_elem_smoke.gd    # 新增
tools/Godot_v4.3-stable_win64_console.exe --headless --path repo -s tests/runner/test_r188_idle.gd     # 500p/800p 各 3 跑中位 P95<8.3ms
# 收口：tests/runner + tests/stress 全部 -s 入口（46 个）逐个 exit=0
# grep 验收：旧色字面量 0 残留；ELEMENT_COLORS 唯一定义于 palette.gd；REACTION_LOOKS 无 "text" 键；
#   menu_screen.gd 反应 per-rid 分支清零；card_generator.gd 无 "ELE_REACTION_VOID" 字面量
```

关键行为断言（M3 后）：FIR+HYD 双槽→落血==S_snap×1.5×φ、双槽清空、不掷暴击；ICE+HYD→freeze_timer==1.2；
LTG+HYD→连锁跳伤>0 且 shock_chain_cd>0；FIR+DEN→burn_layers==5/burn_timer==3.0；LTG+DEN→vuln_timer==3.0；
HYD+DEN→1.5s 后 r120 副目标落血、主目标双槽已清；WND+X→主目标 χ0.8、至多 3 敌 gauges[X]==GAUGE_MAX；
GEO+X→玩家 dr_value≈0.15/dr_left==6.0、接触伤害 ×0.85、到期/复活失效；四槽共存 FIR+ICE+HYD→仅蒸发相干
序结算、幂等缓存吸收同帧第二次；超导修复后持续期重触 2 次到期净恢复 0。

---

*本文档由方案统合策划（四方向定案收敛）产出；行号锚点为 2026-09-26 实读快照，实现期若有漂移以符号名为准。*

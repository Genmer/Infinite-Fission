# R188 整案设计文档：黑市供给 · 叠层审计 · 挂机全链路 · 性能纵深

> 状态：统合定案（四项仲裁全部 implement，无 noop 项）
> 日期：2026-09-25
> 工程根：`repo/`（本仓库全部路径均相对工程根）
> 证据基线：本文所有行号均为本轮统合会话亲读核实；性能基线数字为仲裁会话实跑所得。

---

## 0. 综述与四项裁定

| 项 | verdict | 一句话结论 | 核心产出 |
|---|---|---|---|
| market | implement | 「黑市后期卖完」= 结构性必然（null 目标门 + 武器满级断供 + 遗物售罄 + 满血禁购四链叠加），口径对齐扩池 + 保底谓词站稳 | shop_ui.gd 调用侧重构 + 两公开谓词 + 回归套件 |
| buffs | implement | 叠层引擎本体全部正常（硬帽真实、线性无饱和、钳制均为设计内显式），但有三脚注：存档读回路有损（明令不修，须立项）、详情面板正则显示损坏（一行修）、modifier_stack 注释过期（一行修） | 高位叠层十组断言落库 + 两处一行修 |
| idle | implement | 右上角 AUTO 开关 + 挂机全链路一次做齐三处阻塞出口（选卡/商店/GAME_OVER），设置 2 键一次建好 | auto_idle_strategy.gd + GameLoop 驱动器 + HUD 开关 + 结算倒计时 |
| perf | implement | 「下降 99% 计算需求」按字面不可达，改写为四条可达极限；四档纵深：零行为变更 → 敌段 LOD → 表现收口挂 fx_quality → 深层无尽结构钳制 | 13 类优化点按收益排序 + 新基准锚入库 |

**项间联动（实现顺序约束）**：
1. market 的 `buyable_count()/has_stock()` 谓词是 idle 项二期「自动购买」的硬前置——一期挂机商店固定「自动跳过」只依赖既有 `is_shop_visible()`/`close()`，但谓词必须随 market 本轮站稳，供二期直接调用不需逆向解析 `_wares`。
2. `scripts/ui/hud.gd` 与 `scripts/loop/game_loop.gd` 被 idle 与 perf 双项需要，归入唯一共享组串行落地（先 perf 脏标记等零行为改动，后 idle 开关与驱动器，见 §5 组1）。
3. perf 档3（波次钳制/spawn 高水位/连升合并）是数值规则变更，实现前须过设计确认；其中「连升合并」与 idle 项的自动选卡共享 `pending_level_ups` 队列，合并后溢出等级自动抽卡不弹窗，自动选卡计时器对合并批只消化一次——两组在共享组内同一处落地，防双改冲突。
4. buffs 项显示断言（第 ⑧ 组）依赖 pause_overlay 正则一行修先行合入；该文件归 buffs 组独占，无跨组依赖。

---

## 1. market｜黑市供给结构性修复（implement）

### 1.1 结论与枯竭链（全部亲读复核）

「黑市后期卖完」不是偶发，是四条枯竭链的结构性必然，五议席一致『值得动』：

1. **null 目标门**：`scripts/ui/shop_ui.gd:65` 以空目标调 `_trait_candidates(category, _player, [])`，`mount_gate_allows`（`scripts/cards/card_generator.gd:455-515`，其中 :470-504 空目标恒拒）把全部带 `required_forms/required_weapon/requires_trait` 的词条挡在货架外。逐条实扫 66 个 `resources/traits/*.tres`（Python 复刻 R37 玩家侧 + TH_* + 挂载门全过滤链）：现状可售仅 23 ID / 37 层（ADD 4/10、MULT 8/10、MECH 7/10、ELEM 4/7）；null 目标另走 `card_generator.gd:421` + :764-779 全武器合计计层、:437 满 `stack_max` 永久移出，且与升级卡共池。
2. **weapon_up 兜底断供**：`shop_ui.gd:99-102` break，`MAX_LEVEL=5`（`weapon_base.gd:14`）后全武器无货可补。
3. **遗物售罄**：18 枚 unique（`shop_ui.gd:113-119`）。
4. **终态 0 可购行**：只剩维修包且满血禁购（`shop_ui.gd:342-344`）；刷新置灰只查金币（`shop_ui.gd:275-276`），死架可纯烧金。

**定案 = 两先两后**：先做 A 口径对齐扩池 + B 保底/谓词站稳（挂机项二期硬前置）；循环供给/叠层重置、黑市等级（Meta 新表）、无尽波表补 SHOP 事件二期另议，本项一律不碰。

### 1.2 A. 口径对齐扩池（只改 shop_ui.gd 调用侧）

- **禁改** `card_generator`/`trait_stack` 本体。
- `_reroll_wares` 对 ADD/MULT/MECH/ELEM 各类目先 roll 一把已持武器为 target，调 `_trait_candidates(category, _player, [], target)`——对齐卡流 `card_generator.gd:392-394` 现成口径；计层自动切 :422-429 单武器分支，无需改共享过滤链。
- ware 的展示 target（现 `shop_ui.gd:81` 与 roll 脱钩）与售卡同源化：选 tid 后在『能挂该 tid 的已持武器』中定 target（**容量感知** = 过 `mount_gate_allows` 且该武器栈同 ID 层 < `stack_max` 或栈内条目 < 12；容量感知为必需，见原型实证），无则换下一 tid，全不行该类目 continue。
- `_buy` 的 card dict 补 `target_weapon` 键透传（`card_generator.gd:343-345` 已支持），同修『展示武器 ≠ 实挂宿主』错位。
- 预期池 23→40+ ID / 37→76+ 层（Python 实扫保守数，`required_weapon`/`requires_trait` 可满足时更多）。

### 1.3 B. 保底不变式 + 机器可读谓词（挂机门禁）

- shop_ui 暴露公开 `buyable_count()`（口径 = 金价可付 + 非 heal 或 heal 未满血 + trait 行按同口径可挂载）；`has_stock()` 不含金价层，供挂机判『有无货』。
- `_reroll_wares` 末尾若 `buyable_count()==0`，上架 1 件终兜底常青货：黑市版应急强化（**运行期构造** TraitData、`stack_max=99` 的 +5% 攻击类，仿 `card_generator.gd:674-696` `_fallback_stat_card` 先例；E-08 口径：不落盘、不进注册表）——无条件保证每次开店可购 ≥1。
- 兑现 `REL_BLACK_MARKET.tres` 承诺：持有该遗物时上架『随机金卡』行，价读 `params.gold_card_price=260`（全工程现零消费点，grep 实证），经 `CardKind.SLOT_BONUS` 通道（`card_generator.gd:649-659` + `apply_choice` :352-355 现成分支），仅当 `unlocked_slots < 难度帽` 时上架（满槽幂等失败不收钱）。

### 1.4 C. 死架防烧金（窄口径）

刷新钮 disabled 增加『`_wares` 全为空行时置灰』一档（不动金价口径 `15×market_mult(wave,9)×1.5^n`，`shop_ui.gd:177`；保留有货可掷场景）。

### 1.5 D. 测试

- 探针转正为 `tests/runner/test_market_supply.gd` + `market_supply_cases.gd`（两段式，入口禁引用全局名，仿 `tests/runner/test_buff_audit.gd:1-25` 先例）。
- `tests/runner/history_cases.gd:136-139` 恒真断言（`==c0 or >0` 右支永真，本轮亲读确认）收紧为 `==c0`（收紧非放宽）。

### 1.6 纪律红线与原型实证

- 红线：不动 `MAX_LEVEL=5`、不动 `stack_max` 与 slot 帽 5/6/6、不动 R37 过滤、不运行时改共享 `.tres`、不碰 `_trait_candidates/_used_trait_layers/mount_gate_allows` 本体（8 处测试调用点锁 R187）、既有断言零放宽零删除。
- 原型实证：① R71 兼容性已实证——Fix-A 下 test_verify_feedback 620/621 与基线逐位一致、R71 六断言全 PASS（`verify_feedback_cases.gd:2988-3025` 原文保留）；② `qa_tmp_arb2/repo` 留有可运行原型（A 案简化版 + `arb_probe_entry.gd` 探针，四套件全绿）可对照，正式实现须补容量感知与保底（原型未含）；③ 黑市 roll 现走全局 `randi()`（`shop_ui.gd:77/117/138`）不进每日种子，建议顺手收编进 `card_generator.rng`（独立小改，验收 = 四套件仍绿；若引起波动拆出单独做）。

### 1.7 验收

1. `tools/Godot_v4.3-stable_win64_console.exe --headless --path . -s tests/runner/test_market_supply.gd` exit 0，至少覆盖五断言：
   - ① 真终局（全武器 Lv5 + 遗物售罄 + 满血 + 词条 null 口径叠满，配方 = `verify_feedback_cases.gd:2950-2988` 枯竭循环）开店 `buyable_count() >= 1`；
   - ② 词条枯竭态开店有非 heal 词条行，购买后该词条 id 落在该行展示 target 的 trait_stack 上（展示 = 实挂）；
   - ③ 以挂满 12 条不同词条的武器为 target 的行，购买不扣金且词条未挂（拒买）；
   - ④ 持 REL_BLACK_MARKET 开店出现金卡行、价 = 260（读 .tres params）、购买后 `unlocked_slots+1`，满槽时金卡行不上架；
   - ⑤ 人为清空 `_wares` 后 open 立即补保底常青行且可购。
2. 既有四锁全绿且零放宽：test_verify_feedback = PASS 620 / FAIL 1（唯一 FAIL 仍为既有 R72 链隙电弧 c=0.00，与本项无关）；test_history = 13/13；test_p1_polish = 17/17；test_pkg5 = 139/139。
3. 改动面核查：`scripts/cards/card_generator.gd` 与 `scripts/combat/trait/trait_stack.gd` 零改动；改动收敛于 `scripts/ui/shop_ui.gd` + tests/runner 两个新文件 + `history_cases.gd:138-139` + `FEEDBACK_TRACKER.md`。
4. `buyable_count()/has_stock()` 为 ShopUi 公开方法，headless 断言与逐行按钮 disabled+金价口径一致、heal 满血行不计入、`has_stock()` 不受金价影响——供挂机项（R188-3）直接调用。
5. 行为口径抽查（并入 test_market_supply）：付费刷新价曲线不变（`15×market_mult(wave,9)×1.5^n`）；购买即下架、关店 `_refresh_count` 归零；R37 玩家侧 5 池词条仍不出现在黑市货架。

---

## 2. buffs｜高位叠层审计落库 + 两处一行修（implement）

### 2.1 主结论：叠层引擎本体全部正常

① 层数硬帽真实——`TraitStack.attach` 同 ID 至 `stack_max` 拒绝（`scripts/combat/trait/trait_stack.gd:30-32`），66 张 `resources/traits/*.tres` `stack_max` 分布 27×1/28×2/8×3/2×4/1×5 全部 ≤5；唯一准无限载体 = 运行期构造卡 FALLBACK_ATK/GAMBLER_CURSE `stack_max=99`（`scripts/cards/card_generator.gd:688,712`）。
② 聚合高位逐层线性生效无隐藏饱和——R14 每层全额（`trait_stack.gd:150-153`），全部饱和点均为设计内显式钳制（F4 池钳 `balance_tables` add_atk=2.0 → `scripts/core/damage/modifier_stack.gd:35-40`、乘区 top-8/cap_prod 8.0、crit≤1.0、cdr≤0.6、rof≤30、终值钳 base×500），千层实测误差 <1e-9、无溢出/NaN。
③ R186 预算网格（snappedf 60 击帽 + 20/s 回充）与 R183 注册表（uid 键控注销 + 局清）经多路议员实跑健康。
④ 每帧成本有 `_panel_cache` 缓存不随层数劣化，未缓存路径线性且生产帽内 <0.25% 帧预算。

### 2.2 三个脚注（两个修、一个立项）

1. **存档读回路有损（真实缺陷，本轮明令不修）**：`serialize_run` 每词条只存 `{id,layers}`（`scripts/loop/game_loop.gd:1300`），恢复按 registry 白板 .tres 重挂（`game_loop.gd:1418-1422`）——混品级 layer_values 降白（金 0.39→0.15）、FALLBACK/GAMBLER_CURSE 运行期卡 get_trait 返 null 整条静默蒸发、遗物完全不入档（续局丢 R186）。工程纪律明令「禁止改存档层结构（`scripts/meta/` 的 RunSave 与 user:// 口径冻结）」，`serialize_run` 的 `traits[{id,layers}]` 正是该冻结口径（`scripts/meta/run_save.gd:8-10`）——须专门立项（先解冻口径 + 版本键 + 旧档回退分支，再动 game_loop 读写双端）。本项测试第 ⑩ 组只落现版即绿断言，不把有损值写成 golden、不落常红断言破坏套件门禁；混品级降白/FALLBACK 蒸发作为已知缺陷记录于用例注释，待存档立项时同一波落「读档后==存档前」无损断言翻绿。
2. **详情面板叠层生效值显示损坏（一行修，本轮修）**：`scripts/ui/pause_overlay.gd:524` 正则 `\+\d(\.\d)?%?` 只匹配单数字位（本轮亲读确认），+15%×2 层渲染「+0.35%」（真值 +30%）、+25×4 层渲染「+1005」（真值 +100）——已在 Godot 4.3 引擎内实跑对比验证：修复版六组两位数/单数词条全对、单数字词条零回归、负值与 1 层不改写行为不变（探针 `qa_tmp_arb/regex_probe.gd` fails=0）。修法：`\+\d(\.\d)?%?` → `\+\d+(\.\d+)?%?`（仅此一行）。
3. **modifier_stack.gd:37 注释过期（一行修，本轮修）**：「F4 池级保险丝（正常游玩不可达，触发即记审计）」已因 `stack_max=99` 过期（40 层起 add_atk 饱和，41~99 层边际归零但面板仍显未钳总和）——更正为如实描述运行期 stack_max=99 卡（FALLBACK_ATK/GAMBLER_CURSE）约 40 层起可达、触发即记审计。仅注释，不改钳制逻辑。

### 2.3 A. 高位叠层自动化测试落库（用户硬要求，现 tests/runner/ 无任何高位用例——本轮 ls 核实）

新建 `tests/runner/test_high_stack.gd` + `high_stack_cases.gd`。入口严格仿 `tests/runner/test_buff_audit.gd:1-25` 两段式：`extends SceneTree`、`_initialize` 内 `await process_frame` 两帧后运行期 `load()` cases 载荷、`fail_count>0 → quit(1)` 否则 `quit(0)`（入口零 autoload 编译期引用，否则外部脚本解析不到 GameConfig 全链编译失败）。断言十组（现版全部即绿）：

1. **千层线性**——合成 TraitData `stack_max≥1000` 或直改 mounted.layers/layer_values 注入 100/1000 层，aggregate_panel 精确等于逐层和（±1e-9），第 N+1 层增量恰为该层值；
2. **attach 门封顶**——attach×1000 次仅落 stack_max 层且后续拒绝；
3. **F4 池钳**——1000 条 add_entries 入管线 add_atk 钳至 2.0 且 audit.clamped_add 含 add_atk，FALLBACK 99 层 dmg(40)==dmg(99)==3×base 饱和口径；
4. **诅咒全额**——99/1000 层负贡献线性不衰减、管线终值钳 0、无 NaN；
5. **乘区护栏**——千条同源乘区经 cap_pool/top-8/cap_prod 8.0、crit≤1.0、cdr≤0.6、rof≤30；
6. **R186 网格**——满存款 0.6s 恰 60 击用尽、61 击拒付、tick 回充 20/s 触帽、技能就绪不计费、同帧 120 击恰计费 60，另补 120Hz 帧粒度 refill/spend 交错 soak（≥120k tick 断言 budget∈[0,0.6] 且计费率 ≤20/s）；
7. **R183 循环**——1000 次 register/unregister 循环后 reaction_mult()==1.0 且注册表空、同 uid 覆写不叠乘、局清空归 1.0；
8. **显示**——按 :524 修复后正则断言：+15%×2 层渲染含「+30%」且不含「+0.3」、+25×4 层含「+100」且不含「1005」、+8%×3 层含「+24%」、+1×2 层含「+2」、1 层与负值描述不改写（断言逻辑照仲裁已验证的 `qa_tmp_arb/regex_probe.gd` 的 _rewrite 镜像，或直接调 `_trait_desc_bbcode`）；
9. **成本标度**——aggregate_panel 1000 层/100 层耗时比值 ∈[5,15]（线性标度断言，禁写死绝对 µs 防机器差异误杀）+ copy_full 混品级 layer_values 保真（`trait_stack.gd:94-95` 已正确，锁死防回归）；
10. **存档口径现版绿断言**——layers 整数 serialize→RunSave 往返保真、注入 layers=1000 的合成 payload 经恢复循环后层数==stack_max（受 attach 门钳）、恢复后满层 value_mult==1.6 自然重建。

可搬运资产（repo 外，搬时改 `res://` 路径与 repo 内命名）：`qa_tmp_buffs16/probe_buffs16.gd`（47 项已跑绿）、`qa_tmp_buffaudit3/stack_audit_cases.gd`（55 项已跑绿）、`qa_tmp_buffaudit2/stack_probe_cases.gd`（57 项已跑绿）。

### 2.4 明确不做（实现组不得顺手做）

① 存档回路无损化（见 §2.2-1，纪律红线）。② F4 饱和显示诚实化（面板未钳 4.95 vs 管线 2.0 分叉、「已饱和」标注）——显示语义属设计决策，记录为已知问题。③ 放开 F4 钳/抬 stack_max——性能议员实测 218 层×6 武器已占 5.18% 帧预算、假设 1000 层达 17.3% 超警戒，且后期 DPS 失衡。④ copy_runtime 补 layer_values（`trait_stack.gd:225-231` 现丢）——现无克隆栈聚合消费口、不可达，仅第 ⑨ 组锁 copy_full 保真。⑤ HUD 大数 M 档、R186 存款 UI 读数、超导削抗不对称（`elemental_system.gd:193` vs :389-391）——记录为已知问题。

### 2.5 验收

1. `tools/Godot_v4.3-stable_win64_console.exe --headless --path repo -s tests/runner/test_high_stack.gd` 输出汇总 FAIL 0、退出码 0，用例覆盖十组断言。
2. 显示修复断言全绿：+15% 2 层含「+30%」且不含「+0.3」；最大生命 +25 4 层含「+100」且不含「1005」；暴击率 +8% 3 层含「+24%」；弹丸数 +1 2 层含「+2」；1 层描述与负值（-10%）描述逐字不变。
3. 回归零破坏：headless 分别跑 `test_buff_audit.gd`、`test_pkg3.gd`、`test_pkg5.gd`、`test_verify_feedback.gd` 均 FAIL 0 exit=0（基线 test_buff_audit 24/24 仲裁会话已实跑核对）；pause_overlay 与 modifier_stack 改动不改任何既有断言对象的行为口径。
4. 范围红线核查：`scripts/meta/run_save.gd` 零改动、`game_loop.gd` 的 serialize_run/_restore_run_state 段零改动、F4 钳值/stack_max/cap_prod 等平衡数值零改动、无新增常红断言。
5. `modifier_stack.gd:37` 注释不再声称「正常游玩不可达」（纯注释变更，钳制行为与钳前值零变化）。

---

## 3. idle｜右上角 AUTO 开关 + 挂机全链路（implement）

### 3.1 仲裁前提（本轮亲核）

- Godot 二进制确认存在 `tools/Godot_v4.3-stable_win64_console.exe`，亲跑 `--headless --path repo -s tests/runner/test_fx_quality.gd` → PASS 29 / FAIL 0——「本机无 Godot」的探索结论作废，所有验收可真跑。
- 设置白名单双处口径：`scripts/meta/meta_manager.gd:87-94` SETTINGS_DEFAULTS 现 5 键（本轮亲读：sfx_volume/bgm_volume/shake_on/damage_numbers_on/fx_quality）；:115-124 `_normalized_setting` match，bool 照 "shake_on"/clampi 照 "fx_quality"；:85-86「4 项」注释已过期（亲读确认）。
- 阻塞点全集 = LEVEL_UP（选卡 `game_loop.gd:875-902` + 商店三源汇于 `_on_shop_requested:335-341`，tree.paused :241-243 无超时）与 GAME_OVER（通关 :376-398 / 死亡 :841-847）；复活是自动非模态（player.gd），无需覆盖。
- 程序化出口全为既有契约：`card_select_ui.choose(p_index)`（`card_select_ui.gd:69-89`，_dual 槽 4~9 映射整行，choose(0..3) 在 _dual 下静默无效）、`shop_ui.close()`（:48-50 →closed→request_resume:1151）、`restart_run`（:789-807，GAME_OVER→PLAYING 合法迁移 :45）、`continue_endless`（:401-419，自拒每日局）。
- LEVEL_UP/PAUSED raw 分支（`game_loop.gd:212-228`，本轮亲读）在树暂停期仍每物理帧跑 = 自动驱动天然挂点；`_on_card_choice` 末尾 pending 同步续弹（:949-951）实证自动钩子**严禁在 open() 栈内同步 choose**。
- `Meta.is_run_daily()` 为公开口（`game_loop.gd:390` 已用），每日局判定无需私有字段。
- GAME_OVER 态战斗帧序走 match 的 `_:` pass（:228，本轮亲读）——重开倒计时须在帧序 match 新增 GAME_OVER 分支。

### 3.2 决策一（设置键，2 键一次建好）

`auto_select_on: false`（bool 总开关默认关）+ `auto_restart_mode: 0`（int clampi 0~2：0=停结算屏/1=死亡自动重开/2=通关自动无尽+死亡自动重开）。两键同入 SETTINGS_DEFAULTS 与 `_normalized_setting`（缺一即写读双侧静默丢弃），顺手修 :85-86 过期注释。旧档缺键经读口回默认，零迁移。**不做商店策略键**：商店一期固定「自动跳过」（close 零损失），因 `_buy` 只查金币无满血守卫（`shop_ui.gd:142-171`）、刷新价 15×1.5ⁿ 几何烧金（:174-177）、三议员评估一期自动买风险>收益——二期若做须先把满血门收进 `_buy` 数据层 + 预算帽 + 禁自动刷新，并吃 market 项 `buyable_count()` 新供给规则。

### 3.3 决策二（死亡后行为：默认停结算 + auto_restart_mode 可配混合案）

mode 0 停结算（出厂态=现状，同类游戏通例）；mode 1 死亡 ~3s 后走 restart_run（结算已即时落账无双记，total_runs 恰 +1）；mode 2 通关屏 ~3s 后 continue_endless（保构筑，结晶并入死亡结算=既有 R62 语义）+ 死亡后 restart_run。mode 1/2 在每日局一律回退停结算（`Meta.is_run_daily()` 判定；防无限重刷当日 + total_runs 虚增）。倒计时期间点按任一结算按钮或开关切回 mode 0/关总开关 → 取消。已知既有缺口如实放大但不扩大：难度附赠复活仅 start_run 发放（`game_loop.gd:650`），restart_run 不补——维持现状，不在本项修。

### 3.4 决策三（HUD 开关落位）

落位 x644-704 × y126-190（波次徽章下缘 122 之下、金币行右缘 596 之右、Boss 相位点 x≤642 之外、Boss 横幅 y210 之上——全状态唯一整块空闲带），56×30 开关胶囊 + AUTO 字样，OFF 弱灰/ON 金色（照设置页 ✓/✗ 语汇）。弃 (444,26) 案（R187 读数右伸 x≈480 视觉相接风险）。可见态 = PLAYING+LEVEL_UP（自动开关恰在 LEVEL_UP 期工作，不能照抄暂停钮仅 PLAYING 规则 `hud.gd:347`，本轮亲读确认该行只判 PLAYING）；PAUSED/GAME_OVER/MENU 隐藏。读写走 `Meta.set_setting`/`settings` 单一真源（不做缓存 bool，防与设置页失同步）；悬停说明走 `_add_hover`。模态期可点性依据：各模态 dim/root 均 MOUSE_FILTER_IGNORE（`card_select_ui.gd:186-193`/`shop_ui.gd:199-204`/`game_over_screen.gd:124-129`）+ HUD `process_mode=ALWAYS`（`hud.gd:126`，本轮亲读确认）；落位带内与模态仅可能重叠 Label（Godot Label 默认 mouse_filter=IGNORE 不拦截），验收含模态期可点断言。开/关瞬时小 toast 一次（(150,300) 通道，仿成就先例）；逐次自动选卡禁走 toast（该通道并发互叠）。

### 3.5 决策四（自动驱动器，全部挂 GameLoop）

`_tick_auto_idle` 挂 LEVEL_UP raw 分支（:212-228 处调用，p_raw_delta 计时）；GAME_OVER 倒计时在帧序 match 新增 GAME_OVER 分支（零战斗成本）。分流：`card_select_ui.is_open` → 选卡；`shop_ui.is_shop_visible()` → 商店；`state==GAME_OVER` → 重开倒计时。

- **选卡**：进 LEVEL_UP 后延迟 0.5s 展示窗（欲选卡顶带描金高亮，成对模式双卡同亮；窗内玩家手点=玩家优先，choice_made 后 is_open=false 计时自然作废）→ 走 `choose()` 真链（保 choice_made→apply_choice→card_chosen→图鉴/成就口径）；成对模式必须 `choose(4+row*2)`（槽 4~9，一次带走整行两张）；v1 永不自动重掷。
- **商店**：延迟 0.8s（给玩家看清货架+手动购买窗口）→ `shop_ui.close()`，金币零变动。
- **重开**：倒计时 3s → `restart_run()`（mode 1；mode 2 通关屏改调 `continue_endless()`，死亡屏仍 restart_run）。
- 防重入门：choose 无效时每帧重试需决策计数帽；选卡展示窗计时器在 is_open 翻 false（玩家手选/换一批/连升续弹）时自动重置重排。

### 3.6 决策五（选卡策略 = 独立纯函数文件）

`scripts/loop/auto_idle_strategy.gd`，static，脱 UI 直测。输入 candidates(Array[Dictionary])+is_dual → 输出普通模式 index 或成对模式槽位。评分 `score = rarity*value_scale + (milestone?2.0:0.0) − (cursed?999.0:0.0)`，同分取低 index（确定性）；成对模式按行评分（行内两张 rarity*value_scale+milestone 合计），含 cursed 行行分 −999。**硬不变量（写死非启发式）**：永不输出含 cursed 的卡/行——GAMBLER 每批恰 1 张诅咒恒 out[3]（`card_generator.gd:132`），普通模式恒有安全卡、成对三行恒有 2 条安全行；FALLBACK 保底卡恒在货架，最坏损失=选到次优合法卡（apply_choice 即时生效无撤销，此为可控下界）。字段真源：rarity/value_scale(1.0/1.4/1.9/2.6)/milestone/cursed/target_weapon 均在货架 dict（`card_generator.gd:56,132,148,600-627`）。

### 3.7 决策六（表现反馈最小集）

开关 ON/OFF 态 + 开关 toast；自动选卡 = 0.5s 高亮 + 既有 LevelBurst 金环/coin 音/构筑面板刷新（`game_loop.gd:943-947` 既有确认反馈，不新增通道）；商店自动关店不加音技；死亡/通关倒计时 Label 放结算卡面内（HUD `_toast_label` 在 GAME_OVER 被强制收起 `hud.gd:350-352`，禁用），文案「N 秒后自动再来一局 · 点按取消」，置于 RestartButton/EndlessContinueButton(y322) 与 MenuButton(y400) 之间卡面空位，任一按钮 pressed 或 restart_requested/endless_continue_requested/menu_requested 信号即取消（三信号 `game_over_screen.gd:10-12` 本轮亲读确认）。升级自动选卡保留 0.5s 展示窗同时保住 pkg4 锁定断言 "LEVEL UP - choose a card"（`pkg4_cases.gd:296-297`，本轮亲读确认）。

### 3.8 成本与纪律

代码约 350 行（meta ~15 / hud ~60 / strategy ~80 / game_loop ~130 / card_select 高亮 ~20 / game_over 倒计时 ~45）+ 测试套件约 400 行，中改。工程纪律：不改存档层结构（settings 段加键属允许范围）；全部经既有程序化出口，无新状态迁移（GAME_OVER→PLAYING 已合法）；既有断言零放宽；类型化赋值注意 `card_select_ui.open` 在 change_state 之后调用（现状 :901-902 顺序保持）。

### 3.9 验收

1. `cd E:/Code/Agent/Infinite-Fission && tools/Godot_v4.3-stable_win64_console.exe --headless --path repo -s tests/runner/test_auto_idle.gd` → 全 PASS、EXIT=0（A 设置段/B 开关/C 选卡/D 商店/E 结算/F soak 六组齐全）。
2. 设置双接线：`set_setting("auto_select_on",true)` 后 `settings("auto_select_on")==true`；`Meta._load()` 磁盘回路回读 true；`set_setting("auto_restart_mode",9)` 归一为 2；`set_setting("auto_pick_unknown",1)` 后 `settings()` 返回 null（未知键静默丢弃口径不变）；快照还原后 `_settings` 与进套件前一致。
3. 出厂默认：清档后 `auto_select_on==false` 且 `auto_restart_mode==0`（旧档缺键回默认，零迁移）。
4. 自动选卡真链：auto ON 下 _drive 触发升级，0.6s 内 choice_made 恰 1 次、Meta card_chosen 图鉴口径恰 +1、state 回 PLAYING；双级连升（pending_level_ups=1）两次各选 1 次后回 PLAYING。
5. 诅咒硬不变量：≥200 个 seed 扫描含 GAMBLER 诅咒局面（含成对 6 卡），策略输出恒指向非诅咒卡/非诅咒行。
6. 成对槽位协议：_dual 货架下策略返回值 ∈[4,9]，choose 后 pair.size()==2；普通模式 choose(index) 单张。
7. 商店零损失：auto ON 经 `_on_shop_requested` 开店，0.8s 后 `is_shop_visible()==false`、state==PLAYING、gold 前后相等（三源汇总口断言+战前补给源至少各一例）。
8. 死亡重开闭环：mode 1 死亡进 GAME_OVER，倒计时期间按 RestartButton → 取消且不自动重开；不干预则 ~3s 后 state==PLAYING 且 Meta total_runs 恰 +1（无双记）。
9. mode 2 通关自动无尽：非每日局通关屏 ~3s 后 state==PLAYING 且 `wave_director.current_wave>final_wave`；每日局 mode 1/2 → 5s 后仍 GAME_OVER（停结算回退）。
10. 全链 soak：全开+mode 2 驱动 ≥3000 帧，state 周期性回 PLAYING（无任何 >10s 连续停留 LEVEL_UP/GAME_OVER）、波次计数单调不减——未来新增模态漏接自动出口在此 FAIL。
11. 既有套件零回归：pkg4/pkg5/fx_quality/p3/verify_feedback/soak 跑分与基线一致（fx_quality 29/0 亲跑基线；pkg4 108/0、pkg5 139/0、p3 18/0 引回归议员基线；verify_feedback 仅既有 1 个确定性 FAIL 不新增）；`pkg4_cases.gd:296` LEVEL_UP 文案断言通过。

---

## 4. perf｜性能纵深四档（implement）

### 4.1 目标改写（五议员共识 + 基准证伪）

「下降 99% 计算需求」按字面不可达：满载逻辑帧 avg≈3.0~3.6ms，砍 99% 剩 0.03ms 等于没有游戏（仲裁实跑 avg=2.893ms 佐证）。改写为**四条可达极限**：

1. 满载稳态逻辑帧持续双线 PASS、超阈帧→趋零；
2. 每帧常量税与每帧分配清零（尖峰 MAX 30~108ms 与 RSS 缓升的根源）；
3. 敌段（超阈帧最大头）降频；
4. 深层无尽结构性失控修复——w41+ 建波 O(count) 无钳（探索实测 w233=41ms / w293=221.7ms 单帧 + RSS+165MB）、spawn_queue 无界、连升 4.8 万张选卡冻结，字面 99%+ 在这里。

用户痛点「怪多很卡」= ②③④ 叠加渲染面（3400+ 节点、每敌独立 ShaderMaterial、全屏色差近常开，headless 测不到）。**汇报口径对用户讲「满载稳 60 帧/尖峰消除/后期不卡死」，不讲百分比。**

### 4.2 基线数字（仲裁实跑 + 用户附基线）

- 仲裁实跑：`tools/Godot_v4.3-stable_win64_console.exe --headless --path ./repo -s tests/stress/test_perf_500p100e.gd` → avg=2.893 P50=2.543 P95=5.644 P99=6.753 MAX=43.709ms，双线 PASS，超阈 19 帧(0.3%)，enemy 阶段均值 7.36ms 居首、player 峰值 40.07ms（升级链尖峰），六池 0 运行期实例化，峰值节点 3426，RSS+1.43%，EXIT=0。
- 用户附基线（7200 帧）：avg=3.032 P50=2.724 P95=5.582 P99=6.545 MAX=44.972ms，P95<8.3 与 <7.3 双线 PASS，超阈 8 帧(0.1%)，阶段均值 enemy=5.20 / player=7.22，峰值 player=42.24。
- 微观数字引自 ask 所附探索材料（未逐一复测）：EventBus 扫描 664~733µs/帧 ≈21% 均帧、HUD 全量刷 87~100µs/次、w293=221.72ms、gain_xp(1e12)=47,959 级/412ms、暴力碰撞回归 34.6 vs 14.19ms、零分配原型 -57~58%、P95 同代码散布 5.5~10.2ms。
- 34 套件本次统合会话未全跑（零改动无回归面），仅 verify_feedback 存量 1 FAIL（R72 链隙电弧 c=0.00）两条探索路径独立复现过。

**目标**：500p 锚 P95<8.3 持续 PASS 且 3 跑中位不劣于基线中位、超阈帧不增；超阈帧内 enemy 阶段均值较基线（7.36ms）降 ≥30%；w233 建波单帧 ≤5ms / spawn_queue ≤600 / 选卡排队 ≤3 / 无 >50ms 单帧；每帧常量税（EventBus 门控）开关两态均值差 ≥90%；八百弹锚真压 800 弹（live=800）。

### 4.3 优化点清单（按预期收益排序）

| # | 档 | 优化点 | 预期收益依据 |
|---|---|---|---|
| 1 | 档3 | 深层无尽结构钳制：波次 count≤200+超出转 HP/攻乘区（变强不变多）；spawn_queue 高水位 600；连升合并 pending_level_ups≤3 | w293 单帧 221.7ms→结构性消除；字面 99%+ 所在 |
| 2 | 档1 | 敌段 LOD：调用位（`game_loop.gd:173-178`）frame%2 跳普通敌 tick，enemy.tick 本体零改动 | 超阈帧 enemy 均值 5~8ms，N=2 近半 |
| 3 | 档2 | 表现收口挂 fx_quality：全屏色差、ElementalFxLayer 三池、CRIT 顿帧密集场 | 渲染面大头（headless 测不到），真机收益 |
| 4 | 档0 | EventBus.end_frame 门控（dev 断言开关化） | 664~733µs/帧 ≈21% 均帧（release 兑现） |
| 5 | 档0 | 每帧分配清扫：SpaceGrid 零分配、弹 tick 候选缓冲、orbit_field 治理、小分配项、一次性表现件入池 | 零分配原型 -57~58%、尖峰 30~108ms 根源 |
| 6 | 档0 | HUD 脏标记（事件回调→置脏→帧末同帧 flush） | 87~100µs/次 × 每事件直调 → 同帧 1 次 |
| 7 | 档0 | ON_TICK 空词条直通（跳 payload dict+TraitContext） | 每弹每帧构造（与 :527 注释不符，亲读确认） |
| 8 | 档0 | 800 弹锚扩容（pool_prewarm.projectile 640→≥820） | 基准保真（探索证实 live=640 free=0） |

### 4.4 可减特效的降级策略（挂 fx_quality 档位，照 R19 先例加档内开关，禁改档位数值/缺省 fx_quality=2，test_fx_quality 29~31 项锁定）

- **全屏色差接 fx_quality**（`game_feel_director.gd:195-242` + `data/gamefeel/game_feel_config.tres:19` ca_enabled=true，本轮亲读确认）：低档(0)关、中档(1)缩窗、高档(2)保持——后期暴击构筑下近常开一遍 720×1280 后处理是渲染大头。
- **ElementalFxLayer 13 表现池接档**：DOT 火星（:236-254）、连锁闪电（:150-166）、kill_blast（:795-838），照火苗 [0,2,4] 预算先例（`enemy.gd:2357`）。
- **CRIT 顿帧密集场自动关**：敌 >N 自动关、Boss/精英在场保留（`game_feel_director.gd:73-136`）。正确性红线：只加档内开关，不减既有断言。

### 4.5 分档定案（实现组按序执行，每档收口跑全量门）

**档0 零行为变更（先做，各项半天级）**：
1. 基线先 commit——105 个未提交文件（本轮 `git rev-parse` 确认 HEAD=6f453f0）无法归因回归，之后同机静默 3 跑双基准记录基线中位。
2. EventBus.end_frame 门控（`autoload/event_bus.gd:295-298`，本轮亲读确认 `_check_node_subscribers` 无门控）：挂 dev 断言开关（复用 DebugStats.dev_assertions 或项目设置级 dev 键），release/常规跑跳过；风暴计数 `_track_dispatch`（:285-294）与 assert_subscription_baseline（:308）保留不动——pkg0_cases.gd:238-271 锁定风暴恰好一次与 E-12 拦截，pkg0 内直调 end_frame 处保证测试内开关打开。
3. HUD 脏标记（`scripts/ui/hud.gd:305/309/315/329`）：事件回调改置 `_stats_dirty`，tick/帧末同帧同步 flush；1Hz 兜底（:244-250，本轮亲读确认）保留；铁律：displayed_* 文本口径（:286-300）锁定勿改，pkg4 结算后立即断言 → flush 必须同帧，禁降频到 1Hz。
4. ON_TICK 空词条直通（`projectile_base.gd:526-554`，本轮亲读确认 :526 无条件 `_build_trait_ctx` 与 :527「无词条零开销直通」注释不符）：trait_stack 为 TraitStack 且无词条且 _traits_cache 为空时跳过 payload dict+TraitContext 构造；先审计 `_dispatch_event` 返回值全部消费点保语义。
5. orbit_field 治理：`_gain_cd` 衰减到 0 即擦（scratch 缓冲两相擦除，勿遍历中改字典），封无尽局死键无界增长；`_draw` 内 build_panel_snapshot/网格查询/读数（:887,:899-913）按可见性+降频节流（读数是表现验收项不可删，只降频）；tick 末 queue_redraw（:223）改有变化才重绘；保 reset_detonate_gates（:489-494）测试收口。配新增 OrbitField 微基准夹具（现 500/800 锚不激发 orbit_field——基线盲区）。
6. SpaceGrid 零分配（`space_grid.gd`）：`_cells_in_range` 改成员缓冲复用（:127-138）、query_circle 去 lambda 改直接遍历（:62-73）、`_occupied.has` 线扫（:58，本轮亲读确认）改纪戳。红线：`_query_buffer` 共享缓冲契约（:17，本轮亲读确认「嵌套查询需调用方自行复制」）与 `projectile_base.gd:273-276` 候选复制（本轮亲读确认承重墙注释）必须保留——正确改法是「复制进调用方复用成员缓冲」而非删复制；删除复制=连锁/分裂/AOE/重索敌时候选集被清空的静默错杀，且 34 套件多为单发命中断言抓不住（全员最大做崩点）；同时审计 orbit_field.gd:229/252/407/444 append_array 别名持有。
7. 弹 tick 分配清扫：candidates 成员缓冲复用（`projectile_base.gd:275`）、`_in_reach` 平方距离+窄相收窄（:284-290）、`_sync_visual` 脏标记+阈值缓存（:186,809-815 的 get_threshold 逐帧扫）。
8. 小分配项：ParticleDirector.burst 双 stats() 改计数器直读（`scripts/gamefeel/particle_director.gd:51-55`→`object_pool.gd:84-95`）；elemental detect_reactions order 数组外提+空宿主早退（`scripts/combat/elemental/elemental_system.gd:125-144`）。
9. 一次性表现件入池：DeathPop（`enemy.gd:726-734,2726-2747`）、MissileBlastFx（`scripts/gamefeel/elemental_fx_layer.gd:781-792`）、PoisonSplash 套七池既有模式，基准池对账口径同步扩展。
10. 800 弹锚扩容（`data/balance/balance_tables.tres:23` pool_prewarm.projectile 640→≥820，本轮亲读确认 640）：仅预热容量，软上限 1500/硬 2000 不动——否则 800 锚实际只压 640 弹（探索多路径 live=640 free=0 证实），锚持续失真。

**档1 敌段 LOD（最大单杠杆，超阈帧 enemy 均值 5~8ms）**：只做在调用位 `game_loop.gd:173-178`——frame%2 跳过普通敌 tick（等效 60Hz），enemy.tick 本体零改动（直调敌 tick 的 pkg4/verify_feedback/elite_affix 对调用位 LOD 免疫）；豁免 Boss/精英 tags、RANGED/BLINK 施法态、引信态（pkg4 锁逐帧引信计数）；照分离力 10Hz 先例（`game_loop.gd:29`）留 frame%N 相位遥测供基准归因。数值（N=2 起）按 enemy 阶段 P95 实测回调。

**档2 表现收口**：见 §4.4。

**档3 深层无尽结构（数值规则变更，实现前过设计确认，默认提案如下）**：
- 波次 count 钳制（`wave_director.gd:224-226`，本轮亲读确认 `count := int(tp_budget / maxf(cheapest.tp_cost, 0.01))` 无钳）：count≤200（无尽公式 110×1.03^(w−30) 约 w52 触顶），超出 TP 预算按比例转敌 HP/攻乘区——「变强不变多」，波总威胁预算不变；xp 产出随只数下降的补偿由设计确认（提案：被转化的 TP 同比加成单只经验）。
- spawn_queue 高水位（`enemy_spawner.gd:36-38`，本轮亲读确认 enqueue 无界 append）：上限 600（≈5 波量），触顶拒收+DebugStats 计数+一次告警。
- 连升合并（`player.gd:960-972` + `game_loop.gd:869-870`，本轮亲读确认 while 逐级 emit_level_up）：pending_level_ups 队位上限 3，溢出等级自动按当前卡池同分布抽卡应用（不弹窗、等级/回血/经验曲线照常），消除 47,957 张选卡排队冻结。**联动**：与 idle 项自动选卡在共享组（组1 game_loop.gd）同一处落地，合并后溢出批不产生选卡窗，自动选卡计时器只消化真实弹窗批。

### 4.6 明确不做（本轮）

暴力 O(n×m) 碰撞（800 敌 34.6 vs 14.19ms 回归）；MultiMesh 合批/物理插值 120→60Hz（渲染与 AC 口径 DT=1/120 冻结契约，需重立项）；WorkerThreadPool（实体 tick 触场景树/EventBus 非线程安全）；敌 tick 内部 LOD/帧序重排（`game_loop.gd:131` 禁止）/跨帧伤害缓存/倒计时帧戳化（顿帧冻结语义）；池容量扩至软上限 1500（等弹幕化玩法立项）；不改存档层结构与 settings 既有键。

### 4.7 测量纪律

同代码 P95 实测散布 5.5~10.2ms（并行会话争用）：一切收益结论=同机静默、同命令、≥3 跑取中位，单次涨跌不作数；verify_feedback 存量 1 FAIL 先复现记录在案防误判；headless 不含渲染与物理提交，真机 release 复测另记（PROGRESS.md §11.1 自认从未做），本轮不阻塞。

### 4.8 验收

1. `tools/Godot_v4.3-stable_win64_console.exe --headless --path repo -s tests/stress/test_perf_500p100e.gd` EXIT=0 且 P95<8.3 PASS；同机静默 3 跑中位 P95 不劣于基线中位、超阈帧数不增。
2. 同法 `-s tests/stress/test_perf_800p100e.gd` EXIT=0，且池对账 projectile live=800（扩容后锚真压 800 弹，不再 640 封顶）。
3. 31 个 tests/runner/test_*.gd 入口逐个 headless -s 全 EXIT=0（本轮 `ls | wc` 实数 31 runner + 3 stress = 34 入口）；test_verify_feedback 允许恰好 1 个存量 FAIL（R72 链隙电弧 c=0.00）且 FAIL 数 ≤1。
4. test_pkg0 EXIT=0（门控后风暴计数与 E-12 断言仍被覆盖）；开关两态微探针：关闭态 end_frame 计时（1000 次均值）较开启态下降 ≥90%。
5. test_pkg4 EXIT=0（HUD 脏标记同帧 flush 后 displayed_hp_text/displayed_kills 等口径不变）；测试钩子计数断言：同帧 10 次 enemy_killed 触发的全量 refresh_stats 执行次数=1。
6. 新增 OrbitField 微基准 EXIT=0：1200 帧后 `_gain_cd` 键数 ≤ 活跃目标数×2（无死键无界增长）且 tick 均耗较改前同机 A/B 下降。
7. 敌段 LOD 后：500p 基准超阈帧内 enemy 阶段均值较基线（7.36ms）下降 ≥30%，且 test_pkg4/test_w8_charge/test_elite_affix EXIT=0。
8. 新增风暴档基准 EXIT=0：≥300 次 damage_resolved/帧 形态下 P95<8.3ms（补现锚测不出扇出的盲区）。
9. 新增 w233 建波探针 EXIT=0：start_wave 单帧 ≤5ms、spawn_queue 长度 ≤600；gain_xp(1e12) 探针断言选卡排队 ≤3 且全程无单帧 >50ms。
10. 180s `-s tests/stress/test_soak.gd` EXIT=0：RSS 增幅 <3%，末 30s 节点数与前一窗口差 ≤ 基线 +10（平台期断言）；全程七池 runtime_instantiates=0/pollution=0/rejected_releases=0。

---

## 5. 实现分组（组间文件绝不重叠）

> 跨项共享文件（hud.gd / game_loop.gd / shop_ui.gd / meta_manager.gd）全部收敛进**组1 共享系统接缝组**，其余组不得碰这四个文件。market 项在 shop_ui.gd 的全部工作、idle 项在 hud/game_loop/meta 的全部工作、perf 项在 hud/game_loop 的全部工作均在组1 串行落地。

### 组1 共享系统接缝组（market×idle×perf 三项交集 + market 的 shop_ui 主战场）

文件（独占）：`scripts/ui/hud.gd`、`scripts/loop/game_loop.gd`、`scripts/meta/meta_manager.gd`、`scripts/ui/shop_ui.gd`

任务（按序）：
1. 【market】shop_ui.gd A 口径对齐扩池（类目级 roll 已持武器 target、容量感知选货选宿主、展示/售卡 target 同源）+ `_buy` 补 `target_weapon` 透传与买前同口径复验（不可挂不扣金按钮置灰，堵 :149 先扣金+attach 静默拒的付费空买链）+ 保底常青货与 REL_BLACK_MARKET 金卡行 + `buyable_count()/has_stock()` 公开谓词 + 刷新钮空行置灰。
2. 【perf→hud】refresh_stats 脏标记化（hud.gd:305/309/315/329 事件回调改置脏+帧末同帧 flush，1Hz 兜底保留，displayed_* 口径零改动）。
3. 【perf→game_loop】敌段 LOD 调用位（:173-178 frame%2 跳普通敌，豁免 Boss/精英/施法态/引信态，enemy.tick 零改动，留 frame%N 相位遥测）。
4. 【idle】meta_manager.gd 两设置键（SETTINGS_DEFAULTS + `_normalized_setting` 双接线，bool 照 "shake_on" 行、clampi(0,2) 照 "fx_quality" 行，修 :85-86「4 项」过期注释，_save/_load 零改动）。
5. 【idle→hud】右上角 AUTO 开关（56×30 胶囊，(644,126) 附近，可见态 PLAYING+LEVEL_UP，读写走 Meta 单一真源，_add_hover 说明，开关 toast 一次）——与 perf 的显隐联动在既有 state_changed 处扩展，注意与脏标记改动同文件合序。
6. 【idle→game_loop】`_tick_auto_idle` 挂 LEVEL_UP/PAUSED raw 分支（:212-228 处）+ 帧序 match 新增 GAME_OVER 分支跑重开倒计时（选卡 0.5s 展示窗→choose 真链、商店 0.8s→close、重开 3s→restart_run/continue_endless，玩家手动操作即时取消挂起计时）。
7. 【联动】idle 商店自动跳过吃 shop_ui 既有 `is_shop_visible()/close()`（market 的 `buyable_count()/has_stock()` 谓词为二期自动购买硬前置，一期不消费但必须随组1 第 1 步站稳）；perf 档3 连升合并的 game_loop 侧（:869-870 pending_level_ups≤3）与 idle 自动选卡计时器同处落地（合并批不弹窗，计时器只消化真实弹窗批）。

### 组2 黑市供给回归组（market 独占）

文件（独占）：`tests/runner/test_market_supply.gd`、`tests/runner/market_supply_cases.gd`、`tests/runner/history_cases.gd`、`FEEDBACK_TRACKER.md`

任务：新建两段式测试入口与五断言（§1.7-1）+ 行为口径抽查（§1.7-5）；`history_cases.gd:136-139` 恒真右支移除收紧为 `==c0`（test_history 仍 13/13）；FEEDBACK_TRACKER.md 记 R188-1 落地。

### 组3 叠层审计组（buffs 独占）

文件（独占）：`tests/runner/test_high_stack.gd`、`tests/runner/high_stack_cases.gd`、`scripts/ui/pause_overlay.gd`、`scripts/core/damage/modifier_stack.gd`

任务：两段式入口 + 十组断言落库（§2.3）；pause_overlay.gd:524 正则一行修；modifier_stack.gd:37 注释一行修；回归 test_buff_audit/test_pkg3/test_pkg5/test_verify_feedback 全绿。

### 组4 挂机策略与结算表现组（idle 独占）

文件（独占）：`scripts/loop/auto_idle_strategy.gd`、`scripts/cards/card_select_ui.gd`、`scripts/ui/game_over_screen.gd`、`tests/runner/test_auto_idle.gd`、`tests/runner/auto_idle_cases.gd`

任务：策略纯函数（§3.6 硬不变量）；card_select_ui `highlight_candidate`（复用 :136-138 每次 open 重上色机制，成对同行双亮，close 清除）；game_over_screen 倒计时 Label（y≈470，MenuButton 下方）+ `set_auto_countdown/cancel_auto_countdown` + 既有按钮 pressed 通知取消；A~F 六段测试（§3.9-1）。

### 组5 性能纵深组（perf 独占）

文件（独占）：`autoload/event_bus.gd`、`scripts/combat/projectile/projectile_base.gd`、`scripts/core/space_grid.gd`、`scripts/combat/weapon/melee/orbit_field.gd`、`scripts/combat/elemental/elemental_system.gd`、`scripts/gamefeel/particle_director.gd`、`scripts/gamefeel/elemental_fx_layer.gd`、`scripts/gamefeel/game_feel_director.gd`、`scripts/core/object_pool.gd`、`scripts/entities/enemy/enemy.gd`、`scripts/entities/wave/wave_director.gd`、`scripts/entities/wave/enemy_spawner.gd`、`scripts/entities/player/player.gd`、`data/balance/balance_tables.tres`、`data/gamefeel/game_feel_config.tres`、`tests/runner/test_pkg0.gd`、`tests/stress/test_orbit_field_bench.gd`、`tests/stress/orbit_field_bench_cases.gd`、`tests/stress/test_storm_bench.gd`、`tests/storm_cases.gd`（若拆则放 tests/stress/storm_cases.gd）、`tests/stress/test_deep_wave_probe.gd`、`tests/stress/deep_wave_probe_cases.gd`

任务：档0-2 EventBus 门控 + pkg0 测试内开关保证；档0-4~9 分配清扫与入池（§4.5 档0 第 4~9 条，含 `_query_buffer` 契约与候选复制语义保留红线）；档0-10 平衡表预热扩容 640→≥820；档2 表现收口档内开关（§4.4 三处，禁改档位数值/缺省）；档3-11/12 波次钳制与 spawn 高水位（player.gd 侧连升合并：pending_level_ups 上限 3 + 溢出同分布自动抽卡，game_loop 侧归组1）；新增锚入库（OrbitField 微基准、风暴档、w233 建波/连升探针、soak 平台期断言）；全量回归门 34 入口逐 -s headless 全绿，每档收口重跑双压测，收益 A/B 同机静默 ≥3 跑取中位。

**组间重叠核查**：四组独占文件清单与组1 四文件无交集；`scripts/meta/run_save.gd` 无任何组触碰（存档冻结）；`scripts/cards/card_generator.gd`、`scripts/combat/trait/trait_stack.gd` 无任何组触碰（market 红线）。

---

## 6. 共享系统改动清单（sharedChanges）

1. **HUD 右上角开关与「自动」角标**：AUTO 胶囊（idle）；结算卡面倒计时 Label「N 秒后自动再来一局 · 点按取消」；选卡 0.5s 展示窗描金高亮（成对双亮）。HUD 事件回调脏标记化（perf）不改任何可见文本口径。
2. **settings 段新键白名单**：`auto_select_on`(bool,false)、`auto_restart_mode`(int 0~2,0) 双接线（SETTINGS_DEFAULTS + `_normalized_setting`）；DataValidator 口径 = 未知键静默丢弃、bool/clampi 归一、旧档缺键回默认零迁移；修 meta_manager.gd:85-86 过期注释。
3. **卡池/词条改动**：黑市扩池只改 shop_ui 调用侧，`card_generator.gd`/`trait_stack.gd` 本体零改动；保底常青货运行期构造不落 `.tres` 不进注册表（E-08 口径）；66 词条 `.tres` 与平衡数值零改动。
4. **DataValidator**：新设置键经 `_normalized_setting` 白名单（即项目 validator 口径）；REL_BLACK_MARKET 金卡价读 `.tres` params（数据驱动，无硬编码价）；balance_tables.tres 仅 `pool_prewarm.projectile` 预热容量一处变更。
5. **图鉴/帮助文案**：AUTO 开关 hover 说明（含三档 mode 语义）；开关联动 toast 文案；结算倒计时文案；FEEDBACK_TRACKER.md 记 R188 落地。

---

## 7. 全局纪律红线（四项合并）

- 沿用 repo 现有代码风格与 §九纪律；新数据键/新设置键过白名单与 DataValidator 口径；新 id 全局唯一。
- **禁止改存档层结构**（`scripts/meta/` 的 RunSave 与 user:// 口径冻结；settings 段加键允许）——buffs 第 ⑩ 组断言与 market/idle 均遵守。
- **既有断言不许放宽或删除**（唯一例外形态：history_cases.gd:138-139 恒真右支移除属收紧）。
- 类型化赋值注意时序（`card_select_ui.open` 在 change_state 之后、组1 合序先 perf 零行为改动后 idle 开关）。
- 平衡数值零改动（F4 钳/stack_max/cap_prod/MAX_LEVEL/slot 帽 5/6/6/R37 过滤），档3 数值规则变更须设计确认后实施。
- 汇报口径对用户讲「满载稳 60 帧/尖峰消除/后期不卡死」，不讲百分比。

---

## 8. 回归门汇总（合入前全量门）

| 套件 | 基线 | 门 |
|---|---|---|
| test_verify_feedback | PASS 620 / FAIL 1（R72 链隙电弧，存量） | FAIL 数 ≤1 且不新增 |
| test_history | 13/13 | 全绿（含 :138-139 收紧后） |
| test_p1_polish | 17/17 | 全绿 |
| test_pkg5 | 139/139 | 全绿 |
| test_pkg4 | 108/0 | 全绿（HUD 脏标记 flush 同帧 + LEVEL_UP 文案） |
| test_pkg0 | 全绿 | 全绿（门控后风暴/E-12 仍覆盖） |
| test_fx_quality | 29/0（本轮亲跑） | 全绿（档内开关零减断言） |
| test_buff_audit | 24/24（仲裁亲跑） | 全绿 |
| test_pkg3 / p3 | 全绿 / 18/0 | 全绿 |
| test_market_supply / test_high_stack / test_auto_idle | 新增 | 全 PASS EXIT=0 |
| 双压测 500p/800p + soak | §4.2 基线 | §4.8-1/2/10 |
| 34 入口逐 -s headless | 31 runner + 3 stress（本轮实数） | 全 EXIT=0（verify_feedback 允许恰 1 存量 FAIL） |

---

## 9. 本文档证据清单（本轮统合会话亲读/实跑）

亲读核实：`scripts/ui/shop_ui.gd:59/65/95-103/142/147-152/175-178/273-277/340-345`；`scripts/meta/meta_manager.gd:80-126`；`scripts/ui/pause_overlay.gd:520-528`；`scripts/core/damage/modifier_stack.gd:33-41`；`scripts/ui/hud.gd:124-128/244-251/344-350`；`scripts/loop/game_loop.gd:210-230/335-342`；`scripts/entities/player/player.gd:958-973`；`scripts/entities/wave/wave_director.gd:222-227`；`scripts/entities/wave/enemy_spawner.gd:8-10/35-39`；`scripts/cards/card_select_ui.gd:42/69`；`scripts/ui/game_over_screen.gd:10-12/185-198`；`autoload/event_bus.gd:295-300`；`scripts/combat/projectile/projectile_base.gd:271-277/524-530`；`scripts/core/space_grid.gd:15-18/56-60`；`data/balance/balance_tables.tres:23`；`data/gamefeel/game_feel_config.tres:19`；`tests/runner/history_cases.gd:136-140`；`tests/runner/pkg4_cases.gd:294-298`；`tests/runner/test_buff_audit.gd:1-26`。实跑核实：`ls` 目录结构（repo/docs/design 先例、tests/runner 61 文件含 31 test 入口、tests/stress 3 入口）；`git rev-parse --short HEAD` → 6f453f0。其余性能微观数字与四项探索证据引自本 ask 所附仲裁材料，已在文中逐处标注「引自探索材料（未逐一复测）」。

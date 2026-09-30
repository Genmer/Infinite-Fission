# R196 成长与体验五连修（GROWTH FIXES）设计文档

日期：2026-09-30 ｜ 前置批次：R192（元素矩阵/反应解锁关）、R194（移动端拖动采样）、R195（屏幕适配，已改 hud/menu/shop/laser——本文所有落位/行号均以现码为准）

## 0. 需求与组派生

五项明确需求 → 4 个文件互斥直改组（tests/** 归测试统包，后续阶段处理）：

| # | 需求 | 归组 |
|---|------|------|
| ① | 环绕/挥砍武器「武器范围」buff（登记+数值+进池+UI 说明；orbit 半径/slash 范围消费端） | G3 成长数值 |
| ② | 构筑面板位置三选（默认右上）+ 面板吃 ScreenDrag 断触修复 | G1 面板交互 |
| ③ | 经验面值四档白/绿/金/七彩（球体+拾取表现面） | G4 经验表现 |
| ④ | 图鉴未触发反应条目锁定（首次触发解锁+持久化） | G1（meta 侧 API/存档）+ G2（图鉴 UI 消费） |
| ⑤ | 超质变叠层（超帽层 ×0.7 加算，词条卡注明） | G3 成长数值 |

关键既有事实（本会话逐一读码核实）：
- 经验通胀锚：`balance_tables.gd:37` `exp_inflation_per_wave = 1.085`；敌侧应用在 `enemy.gd:292-297`（`exp_value = data.exp_base × 1.085^(w-1)`）。参考面值：E1_grunt exp_base=3.0、E5_elite=12.0、E6_boss1=600.0。
- 反应触发信号**已存在**：`event_bus.gd:30` `signal reaction_triggered(rxn: int, pos: Vector2, target_uid: int)`，且 `meta_manager.gd:459` 已订阅（`_on_reaction_triggered` 做反应族成就计数，每反应恰 1 发、双计防护在总线发点侧）——**④ 无需改 event_bus.gd、零战斗代码改动**。
- 反应解锁关文案**已存在且含关数**：`game_const.gd` `reaction_note().unlock`（如「解锁：雷元素卡（感电）第 3 关起入手」）——④ 锁定提示单源复用，零新文案。
- 拖动采样现口径：`player.gd:283-304` `_unhandled_input` 累计 `ScreenDrag.relative` + R194 首指锁。断触根因 = `hud.gd:1192` `build_root.mouse_filter = MOUSE_FILTER_STOP` 吃掉面板区域拖动事件。**player.gd 本批零改动**。
- ⑤ 现帽：`trait_stack.gd:30` attach 至 stack_max 拒绝；满层质变 ×1.6（`weapon_base.gd:16` MILESTONE_VALUE_MULT，`weapon_base.gd:97-113` 幂等触发）；卡池过滤 `card_generator.gd:471`；黑市同门 `shop_ui.gd:275`；暂停详情「N/M 层」`pause_overlay.gd:539-548`。
- 设置键双注册纪律（`meta_manager.gd:207-227` 注释原文）：SETTINGS_DEFAULTS 缺行则读口回 null、_normalized_setting 缺分支则写口静默丢弃——新键**两处同批**。
- 存档口径：settings 段 = `cfg.set_value("settings","values",_settings)` 字典加键允许、结构禁改；codex 段按 weapons/traits 先例存 `keys()` 数组，旧档缺键回默认（降级不崩）。

---

## 1. G1 面板交互（② + ④ 的 meta 侧）

**文件**：`scripts/meta/meta_manager.gd`、`scripts/ui/settings_panel.gd`、`scripts/ui/hud.gd`

### 1.1 meta_manager.gd
1. **新设置键 `panel_pos`**（逐字）：
   - `SETTINGS_DEFAULTS` 加行：`"panel_pos": 0,   # R196 构筑面板位置（0=右上 1=右下 2=左下；右上=默认落位）`
   - `_normalized_setting` 加分支：`"panel_pos": return clampi(int(p_value), 0, 2)`
   - 存档兼容：settings 段 values 字典内加键，旧档缺键 → 读口回默认 0；结构禁改。
2. **新存档字典 `reaction_seen`**：
   - `var reaction_seen: Dictionary = {}`（键 = `GameConst.ReactionType` 成员 id 字符串，如 `"RXN_FIR_ICE"` → true；默认空）。
   - `_save()` 加 `cfg.set_value("codex", "reaction_seen", reaction_seen.keys())`；`_load()` 加 `for rid in cfg.get_value("codex", "reaction_seen", []): reaction_seen[String(rid)] = true`（旧档缺键 → 空表，存档兼容）。
   - API（逐字签名）：
     - `func is_reaction_seen(p_rxn_id: StringName) -> bool:` → `reaction_seen.has(String(p_rxn_id))`
     - `func mark_reaction_seen(p_rxn_id: StringName) -> bool:` → 幂等（已见返 false）；首见写入 + `codex_changed.emit()` + `_persist_defer_depth == 0` 时 `_save()`（defer 期由 `end_persist_defer` 收口统一落盘——`_save` 全量写含本键，口径同成就 R191 批收口）。
   - 标记接线（零战斗改动）：既有 `_on_reaction_triggered(_rxn, _pos, _target_uid)`（`meta_manager.gd:682`）首行加 `mark_reaction_seen(StringName(String(GameConst.ReactionType.find_key(_rxn))))`（坏 rxn → find_key 为 null → String() 得 "<null>" 不入有效键集，is 口恒 false，降级不崩）。**不改 event_bus.gd**。

### 1.2 settings_panel.gd
- 新循环行（复用 `_add_toggle_row`，行文案沿本文件本地标签先例——该文件既有行文案均不入 GameConst 文案段）：
  `_add_toggle_row("PanelPosButton", "构筑面板位置", 680.0, _on_panel_pos_cycle)`
- 循环序：`右上(0) → 右下(1) → 左下(2)`；按钮文案 `"◉ 右上" / "◉ 右下" / "◉ 左下"`；写口 `Meta.set_setting("panel_pos", v)`（写即存）。
- **布局重排（显示不能乱）**：现卡 rows 384/458/532/606 + hint 676 + 关闭钮 724、卡高 820（offset −350..+470，abs 290..1110）。并入新行后一次重排：hint 676→750、关闭钮 724→798、`_card.offset_bottom 470.0 → 544.0`（卡高 894，abs 底 1184 ≤1280，余量与 R194「1110 ≤1280」同口径）。行距 74 与现三循环行一致，零重叠。
- `_sync_from_meta` 回填 + `_refresh_toggles` 刷按钮文案（守卫位 `_syncing` 口径不变）。

### 1.3 hud.gd
1. **位置三选**：新增 `_apply_build_panel_pos()`，`_build_ui()` 末尾与 `Meta.settings_changed`（key 守卫 `"panel_pos"`）双驱动；`_build_panel` 尺寸恒 252×132，仅改锚/offset（默认窗逐位恒等原则只对「左下」档成立）：

   | 档 | 锚 (l/r/t/b) | offset (l/t/r/b) | 绝对落位 (720×1280) |
   |----|--------------|------------------|----------------------|
   | 0 右上（默认） | 1/1/0/0 | −276 / 196 / −24 / 328 | x444-696, y196-328 |
   | 1 右下 | 1/1/1/1 | −452 / −156 / −200 / −24 | x268-520, y1124-1256 |
   | 2 左下（原位） | 0/0/1/1 | 24 / −156 / 276 / −24 | x24-276, y1124-1256 |

   右上落位核实（现码 hud.gd）：暂停钮 x514-586×y26-98（:1266-1275）、金币 pill x464-596×y92-128（:1153）、AUTO x644-704×y126-190（:1298-1317）、波次徽章 y16-122（:1052-1057）、BossBar y112-184（TB 注释 :128）——全部在 y<196，**持久元素零冲突**；toast 带 y392+ 在下方。已核对 `boss_banner` y210-256（:1169-1175）为 Boss 出场 ~2.2s 瞬态 IGNORE 标签，面板（后 add_child 压其上）会短暂遮其文案尾部——瞬态可接受，注释写明。右下档为避开技能键 x610-696×y1112-1198（:1101-1108）左移至 x268-520。
2. **断触修复**：`hud.gd:1192` `build_root.mouse_filter` `MOUSE_FILTER_STOP → MOUSE_FILTER_PASS`（R196 注释：面板底放行 ScreenDrag → `player.gd:288` `_unhandled_input` 相对拖动链不断；gui_input 仍收到点击，R194 松手判定 `_on_build_gui_input` 16px slop 原样防拖动误触）。`build_bg` 保持 PASS（:1199）；面板内**交互子件**（现无、未来按钮）保持默认 STOP——「仅按钮等交互子件过滤」。

---

## 2. G2 图鉴锁（④ UI 侧，只消费 API）

**文件**：`scripts/ui/menu_screen.gd`

- `_make_codex_reaction_row(p_rxn)`（:929）行尾加锁定态：`if not Meta.is_reaction_seen(StringName(rid)):`（rid 即 :934 已有的 `String(GameConst.ReactionType.find_key(p_rxn))`）：
  1. `row.modulate.a = 0.55`（降透明读感——与 `_make_codex_blank_row` :1074 同族手法）；
  2. 预览格右上加 🔒 徽标 Label（22px、position (536,6)、mouse_filter IGNORE）+ 12px「未触发」小字（x520,y110 附近，宽 56 内，不压 RxnMult :985-992）；
  3. 解锁关提示：**单源复用**既有 `RxnUnlock` 行（:978-984，`note.unlock` 已含「第 N 关起」）——零新文案、零 GameConst 改动。
- 行随页签重建 queue_free（:1021 既有契约）→ 战斗内首次触发后，下次进图鉴自然解锁展示；持久化在 Meta（G1）。
- 行数口径不变：全枚举 20 行 + 冰+草留白行（A5/D0/X3 断言域不动，锁定只改样式不改行集合）。

---

## 3. G3 成长数值（① + ⑤）

**文件**：`scripts/core/data/data_validator.gd`、`scripts/core/game_const.gd`、`scripts/combat/trait/trait_stack.gd`、`scripts/combat/weapon/melee/orbit_weapon.gd`、`scripts/cards/card_generator.gd`、`scripts/ui/shop_ui.gd`、`scripts/ui/pause_overlay.gd`、**新文件** `resources/traits/AFF_RANGE.tres`

### 3.1 ① 武器范围词条
1. **登记**：`data_validator.gd:16-19` `ADD_POOL_IDS` 追加 `&"add_range"`（第 16 员，追加不重排）。
2. **数值+UI 说明（新 .tres，逐字）**——pattern 同 `AFF_AREA.tres`/`MEC_GIANT_BLADE.tres`；描述数值=value×层数口径（×0.18），文案按 .tres description 先例（词条文案真源在 .tres，非 GameConst 文案段）：

```
[gd_resource type="Resource" script_class="TraitData" load_steps=2 format=3]

[ext_resource type="Script" path="res://scripts/core/data/resources/trait_data.gd" id="1_td"]

[resource]
script = ExtResource("1_td")
id = &"AFF_RANGE"
display_name = "广域印刻"
description = "环绕轨道半径与挥砍范围 +18%（近战武器场域铺得更开），可叠 3 层"
pool = 0
pool_id = &"add_range"
effect_id = &"EF_STAT"
value = 0.18
value2 = 0.0
params = {"required_forms": [3]}
event_hooks = [0]
stack_max = 3
decay_delta = 0.85
cap_pool_p = 0.0
cap_local = 0.0
inheritable = false
proc_chance = 1.0
cooldown = 0.0
rarity = 1
tags = 0
condition = {}
```

   校验域自洽：pool=ADD→decay_delta 0.85∈(0,0.92] ✓；effect_id EF_STAT∈TECH_EFFECT_IDS ✓；required_forms [3]=MELEE 经 `mount_gate_allows`（card_generator.gd:489）只上近战架 ✓；进池走 ADD 类目权重，零新代码。
3. **消费端**（`orbit_weapon.gd`）：
   - 新私有 `func _range_mult() -> float:` → `1.0 + float(trait_stack.aggregate_panel().get("add_range", 0.0))`（trait_stack 判空返 1.0——`_proj_size_mult` :368-373 同式）；
   - `effective_slash_radius()`（:158-161）末尾 `* _range_mult()`（W9 判定半径 + 追击 leash :263 同源联动）；
   - `_orbit_params()`（:196 赋值后、copy 分支之后）`orbit_radius *= _range_mult()`——复制体（:204 基线直读）同样吃到（复制体带全量词条栈 copy_full，R183 只锁「等级成长不带入」，词条不锁）；
   - `attach_trait` 覆写（:88-95）刷新条件追加 `or p_trait.pool_id == &"add_range"` → 挂卡即 `refresh_orbit_field()` 重铺（挂卡即时口径，同 knife_scale 先例）。

### 3.2 ⑤ 超质变叠层
1. **trait_stack.gd** 新常量（逐字）：
   - `const OVERCAP_VALUE_MULT := 0.7`（R196 超帽层收益乘子：按常规 ×0.7 **加算**，不叠乘）
   - `const OVERCAP_EXT_MAX := 5`（超帽延伸层上限：可叠至 stack_max+5，防失控护栏）
   - `attach()`（:24-50）：仅 `p_data.pool == GameConst.PoolClass.ADD` 时帽放宽为 `mounted.layers >= p_data.stack_max + OVERCAP_EXT_MAX` 才拒绝（超帽拒绝计数沿用 `trait_attach_rejected_stack`，超帽成功挂载新增 `DebugStats.count(&"trait_attach_overcap")`）；非 ADD 池保持 `>= stack_max` 拒绝（MULT 取优/MECH/ELEM 语义不变）。
   - 聚合三路按「前 stack_max 层全额 + 超帽层 ×0.7」改写（`aggregate_panel` :141-161 / `aggregate_add_entries` :164-183；`value_mult` 满层质变 ×1.6 仍乘在每层终值上——超帽层 = value×0.7×1.6，质变值口径兼容）：
     - layer_values 逐层路：`k < stack_max` 全额、`k ≥ stack_max` ×OVERCAP_VALUE_MULT；
     - LINEAR_ADD_POOLS（add_pierce/add_pellets）整数路：`value×(stack_max + 0.7×(layers−stack_max))`；
     - decay_sum 路：`T(stack_max) + 0.7×(T(layers)−T(stack_max))`。
   - 注释标注：R196 有意契约变更（原「至 stack_max 拒绝」），测试阶段断言改动写 R196 注释、不放宽删除既有断言。
2. **兼容核实（零改动点）**：满层质变里程碑 `weapon_base.gd:97-113`（触发于 layers 达 stack_max 的那次 attach，`is_equal_approx(value_mult,1.0)` 幂等——超帽续挂不重触）；`MAX_TRAITS=12`、`MAX_LEVEL=5`、Lv 帽与槽帽全不动。
3. **进池/货架**：`card_generator.gd:471` 叠层过滤改 `used_layers.get(tid,0) >= t.stack_max + TraitStack.OVERCAP_EXT_MAX`（仅 ADD 池；非 ADD 保持原帽）；`shop_ui.gd:261-275` 黑市栈容量门同式放宽（ADD 池同口径）。
4. **卡面注明（文案真源 GameConst）**：`game_const.gd` 文案段加（逐字）：
   `const OVERCAP_NOTE := "超出质变等级的层数收益降低 30%"`（R196 用户口径原文）
   `card_generator._make_trait_card`（:622-667）加 `card["overcap"]`（bool：目标武器现有层 ≥ stack_max 且 ADD 池），为真时卡描述尾追加 `"\n" + GameConst.OVERCAP_NOTE`——**同时写 card["description"] 与 data.description**（milestone note :661-666 同款双写，防 `_apply_rarity_values` :207 从 data.description 重写时丢注）。注册表基描述保持干净（duplicate 落卡，E-08）。描述随选卡 UI/黑市/详情自动带出，`card_select_ui.gd` 零改动。
5. **暂停详情显示**：`pause_overlay.gd:539-548` 层数文案超帽时改 `"%d/%d+%d 层" % [layers, stack_max, layers - stack_max]`（防「6/3 层」显示乱）。

---

## 4. G4 经验表现（③）

**文件**：`scripts/loop/game_loop.gd`、`scripts/entities/player/pickup.gd`、`scripts/ui/palette.gd`

- **分档公式（阈值挂经验曲线，零新表键）**：基线 `baseline(w) = p_enemy.data.exp_base × exp_inflation_per_wave^(w−1)`（通胀真源 `balance_tables.gd:37`，与敌侧 `enemy.gd:297` 同式）→ 档 = 面值/基线比：`<3 白(0) / <8 绿(1) / <20 金(2) / ≥20 七彩(3)`。校准锚（wave1）：杂兵珠=1×白、精英珠=4×绿、Boss 珠≈200×七彩；满池合并珠随面值爬档。阈值/初值常量落 pickup.gd，调参只动一处。
  - `pickup.gd` 逐字：`const XP_TIER_THRESHOLDS: Array[float] = [3.0, 8.0, 20.0]` + `static func xp_tier_of(p_value: float, p_baseline: float) -> int`（baseline≤0 → 恒 0 白档，降级不崩）。
  - `pickup.gd`：`var _baseline` + `activate(p_value: float, p_baseline: float = 0.0)`（可选参，旧调用零破坏）+ `merge_value(p_extra: float, p_baseline: float = 0.0)`（baseline 取 max 后随 `_sync_visual` 重分档）；`_reset_state` 清零。
  - `game_loop.gd`：`_on_enemy_killed_drop_xp`（:1932-1939）算 baseline（wave 取 `wave_director.current_wave`，null→1；pow 每击一次，非每帧路径，R188 红线不涉）→ `_spawn_xp_shard(p_pos, p_value, p_baseline)`（新可选参 :2105）→ `shard.activate(p_value, p_baseline)`；满池合并分支 :2113 传同 baseline。
- **球体+拾取表现面**：
  - `palette.gd`（PopPalette 单源）加：`const XP_TIER_COLORS: Array[Color] = [Color("fff1b8"), Color("2ed573"), Color("ffc93c"), Color("ffffff")]`（白=淡柠檬白近现行 XP 观感、绿=薄荷 SUCCESS 同值、金=现行经验柠檬金、[3] 仅为类型占位不被直读）+ `static func xp_tier_color(p_tier: int) -> Color`（clamp 越界安全，`rarity_color` :106 同式）。
  - `pickup.gd` `_sync_visual`（:229-234）：`_sprite.modulate = PopPalette.xp_tier_color(tier)`（非七彩档一次性着色）；`_tick_visual_anim`（:184-210，本就逐帧活跃碎片）尾部仅七彩档走 `Color.from_hsv(fmod(_anim_t * 0.35, 1.0), 0.7, 1.0)` 色相回环（Color 值类型零堆分配，活跃七彩碎片有界——R188「禁每帧分配」合规）；磁吸/追踪期沿用现提亮臂，档色经 modulate 叠加=拾取飞行全程可见分档。
  - 面值越大越醒目的 `_value_scale`（:233）保留；XP 跳字样式（damage_popup.gd PopupStyle.XP 仅配色表项，全工程无发点）**不动**——「拾取表现」落在球体本体，不新开跳字源。

---

## 5. 纪律与集成

- **跨组 API**（同批落地，集成顺序无约束但 G2 编译依赖 G1）：G2 → `Meta.is_reaction_seen`；组内自洽外无新跨组符号。G4 只读既有 `GameConfig.balance.exp_inflation_per_wave`。
- **存档兼容**：settings 段 values 字典加键（`panel_pos`）、codex 段加 `reaction_seen`——均为缺键回默认，结构禁改 ✓；headless 测试档（`save_path()` :20-24）自动隔离。
- **类型化赋值时序**：`hud._apply_build_panel_pos` 在 `_build_ui` 内调用时 Meta autoload 已就绪（autoload 先于场景，§九）；`reaction_seen` 读取口在 menu 构行期（菜单态，Meta 已 `_load`）。
- **性能红线**：七彩色相循环为 Color 值类型逐帧赋值（活跃七彩碎片有界）；baseline pow 逐击一次；其余全部事件驱动——R188 禁每帧分配不破。
- **R195 现码口径**：hud/settings/shop 本批改动全部基于 R195 后现码（hud.gd:1180-1206 面板/1260-1317 右上带、settings_panel.gd R194 行布局、shop_ui.gd R195 口径）；laser 系本批零涉。
- **断言纪律**：本批有意契约变更清单（测试阶段逐条落 R196 注释，不放宽/不删除既有断言）：①attach 超帽不再拒绝（ADD 池）；②聚合超帽层 ×0.7；③`_spawn_xp_shard/activate/merge_value` 增可选参；④`build_root.mouse_filter` STOP→PASS；⑤构筑面板默认落位右上（左下档位几何逐位保持原值）；⑥图鉴反应行新增锁定态样式（行集合不变）。tests/** 全部留测试统包，本批不触碰。

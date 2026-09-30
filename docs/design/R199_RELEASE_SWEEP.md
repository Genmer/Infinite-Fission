# R199 发布清扫 · 统合修复规划

- 日期：2026-10-01
- 来源：六路体检（玩法 / 代码 / 数值 / buff / 搭配 / 历史反馈）确认问题 110 条（其中 2 条 unconfirmed；1 条为同根因重复上报已并入）
- 取舍口径（主控拍板）：
  1. high 全修；medium 逐条评估——发布前值得修的进修复组，纯打磨/内容扩展进 deferred 并说明；low 全部 deferred。
  2. 与「登记待真机项」重叠的交互不主动改，进 deferred 注明待真机。
  3. 修复组文件所有权零交集；**FEEDBACK_TRACKER.md 归收口组专用，各修复组不得动**。
  4. 本文档含：问题总表、分组表、deferred 清单与理由、发布判定。
- 结论速览：**修 43 项（8 high + 35 medium）分 8 组并行；66 项 deferred**；修复组全部完成且定向套件全绿后可发布。

---

## 〇、实盘核验记录（本规划跑过的检查）

- 套件清单：`ls tests/runner/test_*.gd` → 53 个套件实盘（下文套件名均出自此清单）。
- 锚点抽查（grep -n 命中）：
  - `scripts/loop/game_loop.gd`：:837/:1780 `difficulty_revives` 赋予、:976 `func restart_run`、:1155 `min_rarity_floor: -1`（另有 :1124 同口径注释行）、:1168 `func _on_card_choice`、:1267 boot_fatal 空表闸、:2017 `data.gold_drop` 无判空。
  - `scripts/entities/wave/wave_director.gd`：:117 `_spawn_boss(p_wave)`（表行入队后无守卫）、:168 `_hard_cap_left <= 0.0` 跳波、:238 `_apply_difficulty_weave` 唯一调用、:263 fallback 挂 `TAG_ELITE`、:354 `_is_boss_wave`。
  - `scripts/entities/enemy/enemy.gd`：:282-285 精英模板以 `elite_mult` 非空为门、:293 `max_hp = data.hp_base * pow(hp_growth, w - 1.0) * e_hp`。
  - `scripts/combat/weapon/laser_beam.gd`：:187 tick_rate 出束定格、:476 `_settle_one_tick`、:541 `"hit_damage": 0.0`；`weapon_base.gd`：:212 `is_first_hit_of_wave`（仅近战写）、:317 `dominant_element`。
  - `scripts/combat/weapon/melee/orbit_weapon.gd`：:165/:276 `_giant_blade_layers` 硬编码 0.2/0.25；`laser_weapon.gd`：:49/:467 `LAG_TICK_PER_SUB` 常数。
  - `scripts/ui/shop_ui.gd`：:137 调 `card_generator._scaled_description`（无 `_rarity_desc_mech`）、:566 「金卡 · 武器槽 +1」。
  - `scripts/cards/card_generator.gd`：:250 `_rarity_desc_mech`、:504 required_forms 门、:569 `_weapon_candidates`。
  - **路径修正 1 处**：机制门实际在 `scripts/meta/mechanic_gate.gd`（非 scripts/core/，体检清单未带目录）。
  - `scripts/meta/mechanic_gate.gd` 存在；`scripts/combat/elemental/elemental_system.gd`：:178/:202 `_hosts.duplicate()`、:404 `_settle_reaction`、燎原传火注释 :97/:451；`player.gd`：:618 `ctx.element = GameConst.Element.FIR`、:118-122 毒云常量、:237 毒云 tick 发射；`meta_manager.gd`：:728 `_on_reaction_triggered`、:737「本口不滤」；`elemental_fx_layer.gd`：:78/:102-103/:125 毒云表现；`autoload/event_bus.gd`：:43-44 毒云双信号。
  - `pause_overlay.gd`：:472 note 渲染、:585 `stacked_add_total()`；`card_select_ui.gd`：:396/:400 desc 58px+clip_text；`boss_bar.gd`：:258 `_sync_phase` 定义行；`tests/runner/r188_idle_cases.gd`：:1020/:1078/:1099-1112 `_enemy_lod*` 调用仍在（游戏侧已拆除）。
  - 资源实盘：`resources/weapons/` 恰 10 把（W1~W10）；`MEC_GIANT_BLADE/BEAM_LAG/MIRROR_TEMPO/ORBIT_AXE/ORBIT_BOLT/ORBIT_SWORD/PARALLEL_CAL/RICOCHET_HALL/KILL_BLAST/KNOCK` 等 tres 全部在盘；`resources/maps/wave_table_swamp.tres` 在盘。
- 未跑：任何 headless 套件与探针（本规划只读+写本文；套件由各修复组修后跑）。

---

## 一、问题总表（110 条）

> 列：编号 | 路 | 位置 | 严重度 | 修否。修否=「G1~G8」表示进对应修复组；「defer」表示不修（理由见第三节）。F08 与 N05 同根因，随 N05 修。

| 编号 | 路 | 位置 | 严重度 | 修否 |
|---|---|---|---|---|
| P01 | 玩法 | game_loop.gd:976-999 restart_run 无 difficulty_revives 补授（唯一赋予点 :837）+ player.gd:486 | high | **G1** |
| P02 | 玩法 | game_loop.gd:1071-1075/:1196-1197/:1472 商店期升级选卡挂账、局终静默丢 | low | defer |
| P03 | 玩法 | game_loop.gd:2148-2156 连杀跳字被旧 toast 淡出截断 | low | defer |
| P04 | 玩法 | hud.gd:26/:442-444 map_name 死变量、无波次进度常驻 | low | defer |
| P05 | 玩法 | card_select_ui.gd:393-400 卡面描述 58px+clip_text，82% 词条被裁 | medium | **G7** |
| P06 | 玩法 | card_select_ui.gd:243-244+:396-398 成对抉择 ⇄ 提示整行落裁切段 | medium | **G7** |
| P07 | 玩法 | menu_screen.gd:960-966 图鉴词条描述单行 500×22 截断（14/71 条） | medium | **G7** |
| P08 | 玩法 | player.gd:288-309 输入仅相对拖动 + lore.gd:10-15 全游戏无「拖动移动」提示 | medium | **G4** |
| P09 | 玩法 | shop_ui.gd:585-591 货架行 desc 400×34 溢出被面板盖、无悬停兜底 | low | defer |
| P10 | 玩法 | game_const.gd:360 + menu_screen.gd:452/:480-483 难度副文案行话+两行塞单行标签 | low | defer |
| P11 | 玩法 | hud.gd:409-415 LEVEL UP/PAUSED/GAME OVER 英文（锁定断言 pkg4:300/auto_idle:295/r188_idle:1359） | low | defer |
| P12 | 玩法 | hud.gd:275/:705/:1873 等 9 种 BMP 符号字面量，安卓字体链未验 | low(unc) | defer（待真机） |
| P13 | 玩法 | meta_manager.gd:494-498/:675-694 对照 :756-761 每日局进度/成就/通关照常落盘 | low | defer |
| P14 | 玩法 | card_generator.gd:586-601 自定义首发非手枪时卡池仍出「新武器：手枪」 | low | defer |
| P15 | 玩法 | meta_manager.gd:18-19 注释承诺解锁 toast + game_over_screen.gd:91-101 无揭示 | low | defer |
| P16 | 玩法 | meta_manager.gd:634-647 重置图鉴不清 custom_weapon_id + game_loop.gd:714-719 | low | defer |
| P17 | 玩法 | menu_screen.gd:1238-1260 成就面板无逐条进度 | low | defer |
| P18 | 玩法 | game_loop.gd:1194 选卡收口直迁无输入宽限、拖动残留全额落位（对照 :697-705/:1472） | medium | **G1** |
| P19 | 玩法 | sfx_bank.gd:135 skill 音色死流 + player.gd:707 | low | defer |
| P20 | 玩法 | player.gd:354 + sfx_bank.gd:131-165 玩家受击无音效 | low | defer |
| P21 | 玩法 | hurt_indicator.gd:24-44 受击红弧用「最近活敌」近似方向 | low | defer |
| P22 | 玩法 | E6_boss1.tres:21 + wave_table_main/frost/grove :80-81 三图 w10 同一只 Boss | medium | defer（内容扩展） |
| P23 | 玩法 | wave_table_main.tres:241 + map_table.gd:26 终 Boss E6_boss3 剧情线遇不到 | medium | defer（内容设计） |
| P24 | 玩法 | wave_table_main.tres:81 草原 w10 收官 Boss 无 TAG_FINAL_BOSS（3.8x 非 5.0x） | low | defer |
| P25 | 玩法 | game_loop.gd:867/:1770 + cloud_backdrop.gd:1-6/:26-28 分图仅云层染色 | low | defer |
| P26 | 玩法 | game_loop.gd:887/:561 + mechanic_gate 每日锁第一关、无后期玩法 | low | defer |
| P27 | 玩法 | wave_table_demon.tres:24 + wave_director.gd:296-301 E24 闪现怪仅投放 2 只 | low | defer |
| P28 | 玩法 | wave_table_frost.tres:8 起 + wave_director.gd:252-266 主题图 74% 是草原 grunt | low | defer |
| C01 | 代码 | game_loop.gd:2017 `data.gold_drop` 无判空（同函数 :1988 已有守卫漏此处） | low | defer（建议下批优先） |
| C02 | 代码 | verify_feedback_cases.gd:3505-3508 调不存在的 `_enemy_attack_note`，2 条断言静默丢失、假绿 | low | defer（建议下批优先） |
| C03 | 代码 | hud.gd:741/:1217 注释漂移（y26-98→20-92；W-200→W-136） | low | defer |
| C04 | 代码 | weapon_base.gd:127-133 add_hp 直挂未乘满层质变 ×1.6 | low | defer |
| C05 | 代码 | elemental_system.gd:178/:202 每帧 `_hosts.duplicate()` | low | defer |
| C06 | 代码 | laser_weapon.gd:142 / popup_manager.gd:388 / game_loop.gd:628 / projectile_base.gd:196 每帧分配 4 处 | low | defer |
| C07 | 代码 | game_loop.gd:631 `_boss_summons` 池复用后条目滞留（复用节点死亡归还后才清） | low | defer |
| C08 | 代码 | event_bus.gd:176-177/:180-181/:254-255 三 emit 直发不过 _track_dispatch | low | defer |
| C09 | 代码 | enemy.gd:872-887 法术读条 SceneTreeTimer 越死亡/池归还/回菜单 | low | defer |
| C10 | 代码 | game_loop.gd:1266-1274 boot 空表闸只护 enemies/total，weapons 丢失不拦（R194 同族） | medium | **G1** |
| C11 | 代码 | data_validator.gd:274 relic effect_id 只校验非空、无处理器注册表对账 | low | defer |
| C12 | 代码 | data_validator.gd:396 validate_balance 回退对伪 field 空转、告警文案失实 | low | defer |
| C13 | 代码 | meta_manager.gd:965 ConfigFile.save 返回值丢弃 | low | defer |
| C14 | 代码 | event_bus.gd:18/:108-110 damage_alarm 成品包零消费者 | low | defer |
| C15 | 代码 | boss_bar.gd:258 `_sync_phase` 全仓零调用、未连 boss_phase_changed，相位点恒空心 | medium | **G7** |
| C16 | 代码 | orbit_field.gd:717-729 `_fire_hit_fx` 全仓零调用，命中反馈链全死 | medium | **G3** |
| C17 | 代码 | enemy.gd:680 等 5 处「注释宣称有消费方」的死函数 | low | defer |
| C18 | 代码 | trait_base.gd:117 等 9 处纯死访问器 | low | defer |
| C19 | 代码 | hud.gd:492 + menu_screen.gd:414 假「测试观测口」 | low | defer |
| C20 | 代码 | enemy.gd:234 复制粘贴死注释 | low | defer |
| N01 | 数值 | enemy.gd:293 Boss 血量被双重波次成长（hp_base 已含 1.12^(w-1)，spawn 再乘一层） | high | **G2** |
| N02 | 数值 | W3_shotgun.tres L3/L4 五项数值全同，L3→L4 精通零增益 | medium | **G4** |
| N03 | 数值 | W7/W8 tres 内置 DPS 备注与自身数值失洽 | low | defer |
| N04 | 数值 | player.gd:1070-1079 + pause_overlay.gd:347-353 面板 %漏乘难度回报系数 | low | defer |
| N05 | 数值 | pause_overlay.gd:585 `stacked_add_total()` 未按超帽 ×0.7 折算（真值源 trait_stack.gd:157-209） | medium | **G4**（F08 并入） |
| N06 | 数值 | pause_overlay.gd:472/:490 + hud.gd:803-815 渲染武器 note 开发行话（R187 §2.4/p1_polish/内部 id） | medium | **G4** |
| N07 | 数值 | wave_director.gd:238 唯一织入调用在表驱动分支，公式 fallback（:241-266）断供 | medium | **G2** |
| N08 | 数值 | wave_table_swamp.tres 无尽段拷贝拼装：w31 立即复打终 Boss、w32-36 TP 倒退复刻 | medium | **G2** |
| N09 | 数值 | wave_director.gd:262-263 fallback 精英波给最便宜 grunt 挂 TAG_ELITE（无 elite_mult 模板）=假精英 | medium | **G2** |
| N10 | 数值 | wave_table_swamp.tres:155-161 剧情 w30 Boss 漏 tags=6（1/4 屏而非 1/3 屏收官） | medium | **G2** |
| N11 | 数值 | wave_director.gd:354-359 + wave_table_main 主图无尽 w36-49 连续 14 波无 Boss | low | defer |
| N12 | 数值 | enemy.gd:1407-1422 等 Boss 弹幕/雷区/扫线伤害平值不随波/难度成长 | low | defer（既定口径） |
| N13 | 数值 | game_loop.gd:1155 换一批写死 min_rarity_floor:-1，超频核心保底被洗掉（:1116 首 roll 消费即焚） | medium | **G1** |
| N14 | 数值 | enemy_spawner.gd:131-154 双词缀第二词缀按池序取首个合法，20 组合塌缩成 5 | low | defer |
| N15 | 数值 | damage_pipeline.gd:23/:242/:348-354 + trait_base.gd:37-38 暴击/触发概率流从不重随机 | low | defer |
| F01 | buff | orbit_weapon.gd:276/:165/:176-185 巨刃金卡 +65% 实发恒 +25%/层（value 无消费点） | medium | **G3** |
| F02 | buff | laser_weapon.gd:49/:463-467 分光延迟金卡 +1.3 实发恒 +0.5，第二层零效果 | medium | **G3** |
| F03 | buff | mirror_image.gd:24/:174-183 镜面奏鸣金卡 +39%/层实发恒 +15% | medium | **G3** |
| F04 | buff | orbit_weapon.gd:236-248 + card_generator.gd:318-331 环绕三选一金卡数字集体失真（tres value=0.0） | medium | **G3** |
| F05 | buff | card_generator.gd:309-317/:334-344 ×N 重写把二值机制说明「×2」改写为「×3.6」 | low | defer |
| F06 | buff | card_generator.gd:47 const ADD 36 vs balance_tables ADD 40 三源镜像漂移 | low | defer |
| F07 | buff | card_generator.gd:241-247 契约注释 vs 武器 tres：4/11 阈值 id 无注册表镜像 | low | defer |
| F08 | buff | 同 N05（pause_overlay.gd:585,596-601 显示虚标 + 整数池显示小数），上报重复 | medium | 并入 **N05/G4** |
| F09 | buff | ballistic_weapon.gd:263/:271 + laser_weapon.gd:507 穿透/多重超帽层 int(round) 凑整抹平 ×0.7 | low | defer |
| F10 | buff | weapon_base.gd:195-218（近战）+ laser_beam.gd:480-530（激光自建 ctx）不写 player_hp_pct，背水/壁垒断供或反向失真 | high | **G3** |
| F11 | buff | laser_beam.gd:480-530 激光跳伤自建 ctx 恒不写 is_first_hit_of_wave，先手协议 ×3.0 永不生效 | high | **G3** |
| F12 | buff | shop_ui.gd:130-137 黑市词条行缺 `_rarity_desc_mech` 特化重写（对照 card_generator.gd:250-289） | high | **G7** |
| F13 | buff | shop_ui.gd:135-137 黑市 MULT 词条 cap_pool_p 不随品质缩放（对照 card_generator.gd:177-178） | high | **G7** |
| F14 | buff | shop_ui.gd:275-279/:130-142 黑市放行超帽层但永不追加 OVERCAP_NOTE/◆ 预告 | medium | **G7** |
| F15 | buff | card_select_ui.gd:393-400 描述区承载不足：满层质变+超帽+品质尾注叠 3-4 行被裁 | medium | **G7** |
| F16 | buff | hud.gd:984-992 构筑面板宝石无悬停说明、同池不可分辨 | low | defer |
| F17 | buff | elemental_system.gd:590 燎原传火广播 reaction_triggered(RXN_FIR_ICE) + meta_manager.gd:728-740 消费口不过滤 | medium | **G6** |
| F18 | buff | elemental_system.gd:346-352 激化臂不检 IMMUNE_CHILL（对照 :316-321 冻结臂） | low | defer |
| F19 | buff | elemental_system.gd:348 + elemental_state.gd:129-130 激化复用 vuln 池误激活冰渊裁决 | low | defer |
| F20 | buff | elemental_system.gd:479-493 + game_loop.gd:217-218 + damage_pipeline.gd:340-345 绽放延迟爆发同帧吞第二反应 | low | defer |
| D01 | 搭配 | MEC_PARALLEL_CAL.tres:15 + card_generator.gd:494-543 + ballistic_weapon.gd:340-350 平行校准在 W2/W3/W10 上零效果死卡 | medium | **G5** |
| D02 | 搭配 | MEC_RICOCHET_HALL.tres:9/:15 + projectile_base.gd:691 回廊弹幕仅 W1 编队弹生效 | medium | **G5** |
| D03 | 搭配 | MEC_KILL_BLAST.tres:15 + trait_effect_mech.gd:27 死亡新星上架激光/近战永不触发 | medium | **G5** |
| D04 | 搭配 | MEC_KNOCK.tres:15-18 + arc_slash.gd:23/:36 动能冲击上架 W9 零消费 | medium | **G5** |
| D05 | 搭配 | W10_boomerang.tres:60-67 缺 TH_FRACTAL_ECHO，几何分裂终环节不可达 | low | defer |
| D06 | 搭配 | relic_handler.gd:386-388 每击谐振对无技能角色恒早退死遗物（mechanic_gate.gd:112-116 无角色门） | medium | **G5** |
| D07 | 搭配 | REL_GLASS_CANNON.tres:9 + elemental_system.gd:505-516/:616-627/:408-423 + player.gd:614-625/:764-771 玻璃大炮 DOT/反应/技能通道不注入 | medium | **G6** |
| D08 | 搭配 | card_generator.gd:134-136 + card_select_ui.gd 赌徒第 4 张诅咒卡零标记 | low | defer |
| D09 | 搭配 | relic_handler.gd:444-451 暴击谐振横幅无条件播「技能冷却已重置」 | low | defer |
| D10 | 搭配 | relic_handler.gd:287/:450 + game_loop.gd:1503 ⚡ emoji 违反 R196 规约（P1 闸只拦 >0xFFFF） | low | defer |
| D11 | 搭配 | REL_GAMBLER.tres:13 curse_atk_pct 死参（真值走 card_generator.gd:757/:766/:773-774 const） | low | defer |
| D12 | 搭配 | REL_BLACK_MARKET.tres:9 + shop_ui.gd:303-321/:564-567 「随机金卡」实为固定槽+1 一口价 | low | defer |
| D13 | 搭配 | laser_weapon.gd:117-150/:194-196/:325 + laser_beam.gd:187 激光 tick_rate 出束定格，射速 buff 对 W4/W5 零收益 | medium | **G3** |
| D14 | 搭配 | player.gd:618/:770 毒沼绽放/毒云走 FIR 通道，火免疫敌（E4/E8）恒 0 伤 | medium | **G6** |
| D15 | 搭配 | orbit_weapon.gd:119-125/:198-262 + orbit_field.gd:112-125 射速增益不作用 W8 主伤害环 | low | defer |
| D16 | 搭配 | laser_beam.gd:537-543 attach 传 hit_damage:0.0 → elemental_system.gd:163-167/:521-556 雷引激光连锁恒 0 | high | **G3** |
| D17 | 搭配 | laser_weapon.gd:215 + weapon_base.gd:317-326 + trait_effect_elemental.gd:44-46 激光第二元素卡结构性死卡 | medium | **G5** |
| D18 | 搭配 | wave_director.gd:111-117 表行入队后无守卫再 _spawn_boss → 每图 Boss 波实刷 2 只满血 Boss（对照 :244-245 公式路有守卫） | high | **G2** |
| D19 | 搭配 | wave_director.gd:167-177 硬上限跳波静默跳过该波商店（消费口 game_loop.gd:1479-1481） | medium | **G2** |
| D20 | 搭配 | card_generator.gd:51-52/:119-121 前期保底武器卡 wave<5 且 level≤3 的 AND 截短 | low | defer |
| H01 | 历史 | elemental_fx_layer.gd:816 每跳把毒圈 left 重置 6.0 → 技能结束后全亮滞留 4.0s+渐隐 1.5s | medium | **G6** |
| H02 | 历史 | hud.gd:1208-1226 技能键无 tooltip/无 _add_hover（8 处 hover 注册均无它） | low | defer |
| H03 | 历史 | texture_factory.gd:1019-1043 SLOT_BONUS(k=5) 落灰菱兜底章无专属图形 | low | defer |
| H04 | 历史 | r188_idle_cases.gd:1086-1123 敌段 LOD 死组（游戏侧 R189c 已拆）每次运行脚本报错中断，P4 3 条断言静默消失 | medium | **G8** |
| H05 | 历史 | r188 P7「连升爆发帧 ≤50ms」时敏断言跨跑 20.4↔72.1ms | low(unc) | defer（待真机/安静环境） |
| H06 | 历史 | menu_screen.gd:1030/:1035 绽放反应倍率行折两行出框 8px | low | defer |
| H07 | 历史 | damage_pipeline.gd:31-33、game_loop.gd:800-801、hud.gd:741、confetti.gd:64、hud.gd:996、R198_BACKLOG_SWEEP.md:192 注释/账面漂移 | low | defer |

统计：110 条 = 修 44 行（43 个独立问题，F08 并入 N05）+ defer 66 行（含 2 条 unconfirmed）。

---

## 二、修复分组（8 组，文件所有权零交集）

> 通用纪律（对每组生效）：
> - 套件命令：`E:/Code/Agent/Infinite-Fission/tools/Godot_v4.3-stable_win64_console.exe --headless --path E:/Code/Agent/Infinite-Fission/repo -s tests/runner/test_<套件名>.gd`，绝对路径；**先落日志文件再取退出码**，判 exit code + 日志「汇总/验收汇总」行。游戏桌面实例在运行：功能套件可跑，**r188 性能三跑类基准禁跑**。
> - 行为变更导致既有断言过时的：随修更新该断言，注明 R199，**全仓 grep 同名断言副本一起改**（历史踩坑）；仅限被本次行为变更直接判定过时的断言，不得顺手修 deferred 项。
> - 需新增自测用例时，写入本组专属新文件 `tests/runner/test_r199_<组名缩写>.gd`，禁止多组同改一个共享 runner（r188_idle_cases.gd 归 G8 独占；verify_feedback_cases.gd 如需改断言归 G7）。
> - SpaceGrid=RefCounted 禁 free；池化对象勿 add_child/勿二次 release；**emoji 禁入 UI 字符串**；新增文案真源一律进 GameConst（game_const.gd，归 G4）。
> - 跨文件只读引用允许（如 G7 调 card_generator 的静态/实例方法不改其源码）；若复核发现必须改其它组独占文件，**升级主控裁决，勿越界改**。

### G1 局内循环组
- **独占文件**：`repo/scripts/loop/game_loop.gd`
- **问题与修法**：
  - **P01（high）restart_run 丢难度复活**：`restart_run`（:976）补授 `GameConst.difficulty_revives(_difficulty)`，复用 start_run :837 / continue_run :1780 同款路径与注释口径；不改 player.gd（归 G6）。若复核发现必须动 player.gd → 升级。验证可复用体检探针 `E:/Code/Agent/Infinite-Fission/tmp_probe_coreloop.gd` A1/A2 段口径。
  - **P18（medium）选卡收口瞬移**：`_on_card_choice`（:1168 一带，:1194 直迁 PLAYING）改走 :697-705 `request_resume` 同款宽限（RESUME_GRACE_S + input_enabled=false，进 PLAYING 后吞首段拖动）；`:1472` shop closed 已有宽限可对齐。`continue_endless`（:576）同类直迁一并接宽限（体检 evidence 点名备注）。不改 player.gd。
  - **C10（medium）boot 闸漏 weapons**：:1266-1274 空表闸谓词扩为 enemies/total/**weapons** 同判（对齐 R194 口径注释 :1256-1257），weapons 缺失时 boot_fatal 置位拒绝入 MENU。
  - **N13（medium）换一批洗掉保底**：:1116 首 roll 消费 `take_rarity_floor()` 后，把该值存入本局选卡流（如 reroll 上下文成员变量），:1155 换一批 context 改传真实保底值而非 -1（card_generator.gd:126-128 抬升逻辑已存在，不改其文件）；注意 :1124 WORDS_TIDE 自动重随路径口径勿回归。
- **定向套件**：`pkg4`、`pkg5`、`history`、`r194_mobile`（boot 闸）、`verify_feedback`

### G2 波次与 Boss 数值组
- **独占文件**：`repo/scripts/entities/wave/wave_director.gd`、`repo/scripts/entities/enemy/enemy.gd`、`repo/resources/maps/wave_table_swamp.tres`
- **问题与修法**：
  - **D18（high）Boss 双生成**：`start_wave` 表行 for+enqueue（:111-117 一带）与 `_spawn_boss` 二选一：表行已含 Boss 实体时不再 `_spawn_boss`，或表行入队跳过 Boss 位（对齐公式回退路 :244-245 的 `if _boss_wave: return out` 守卫语义）。注意保持掉槽/`TAG_BOSS` 语义落在保留的那只上（体检 evidence：表行入队 Boss tags=0）。
  - **N01（high）Boss 血量双成长**：:293 对带 `TAG_BOSS`/`TAG_FINAL_BOSS` 的敌不再全额乘 `pow(hp_growth, w-1)`——Boss `hp_base` 已是设计出场血量，改为 `hp_base × pow(1.12, 实际波 − 设计出场波)`；设计出场波取波表首次登场位（boss1=w10、boss2=demon w10、boss3=w30、E17=frost w15、E18=demon w20、E19=grove w25、E20=swamp w30），无尽轮换位（如 E6_boss1@w35）按差值缩放才不失真。普通敌路径零改动（体检对照组：grunt/elite 全波恒 ×1.20 在带内）。验证可复用 `E:/Code/Agent/Infinite-Fission/ttka_probe.gd`。
  - **N07（medium）fallback 难度织入断供**：公式 fallback 分支（:241-266）在 return 前补 `_apply_difficulty_weave(out, p_wave)`（:290）。
  - **N09（medium）fallback 假精英**：:262-263 不再给 `_cheapest_enemy()` 直挂 `TAG_ELITE`——改用带 `elite_mult` 模板的真精英（E5_elite）入列，或去掉该挂标（与表内精英波强度对齐的方案二选一，倾向前者保精英节奏）。
  - **N08（medium）沼泽无尽段重排**：wave_table_swamp.tres endless_entries 去重（w31 不再复打 E20 终 Boss、w33 不再复刻 E6_boss2 主体段位），w32-36 TP 由 73~90 倒退改为沿主段末段（w28 tp≈97）递进；数值主张最小改动、语义正确优先。
  - **N10（medium）沼泽 w30 补收官规格**：WaveEntryData_w30boss 补 `tags=6`（TAG_FINAL_BOSS），对齐 main:241/frost:120/demon:160/grove:160 四图终波。
  - **D19（medium）硬上限跳波丢商店**：:167-177 硬上限跳波时记录「欠账商店行」，下一次自然 wave_cleared 一并补发 shop_requested/SHOP 事件（波表 SHOP 行与战前补给两条口都覆盖）；消费口 game_loop.gd:1479-1481 预期零改动（归 G1，勿动），若复核确需动 → 升级。
- **定向套件**：`p3`、`boss_themes`、`elite_affix`、`r196_growth`、`market_supply`、`verify_feedback`（R72 织入段）
- **风险**：N01 改变 Boss TTK——若撞出既有锁定断言按通用纪律更新并注明 R199（体检已证无一套断言 Boss 血量标定，预期零撞）。

### G3 武器词条消费与激光上下文组
- **独占文件**：`repo/scripts/combat/weapon/laser_weapon.gd`、`laser_beam.gd`、`weapon_base.gd`、`melee/orbit_weapon.gd`、`melee/orbit_field.gd`、`mirror_image.gd`；`resources/traits/MEC_GIANT_BLADE.tres`、`MEC_BEAM_LAG.tres`、`MEC_MIRROR_TEMPO.tres`、`MEC_ORBIT_AXE.tres`、`MEC_ORBIT_BOLT.tres`、`MEC_ORBIT_SWORD.tres`
- **问题与修法**：
  - **F10（high）背水/壁垒血线断供**：近战 `weapon_base.gd:195-218` ctx 补写 `player_hp_pct`（`player.hp/player.max_hp`，默认 1.0 见 damage_context.gd:37）；激光 `laser_beam.gd:480-530` 自建 ctx 同步补写该字段。判真源 synergy_rules.gd:39-42/56-60 零改动。
  - **F11（high）先手协议对激光失效**：`laser_beam.gd` 自建 ctx 补写 `is_first_hit_of_wave`（与 weapon_base.gd:212 同源 `is_wave_first_hit()`）。
  - **D16（high）雷引激光连锁 0 伤**：`laser_beam.gd:537-543` apply_attach 的 `"hit_damage": 0.0` 改传真实跳伤（对齐 projectile_base.gd:540-547 传 `p_result.final_value` 的口径）；elemental_system.gd:163-167 消费侧零改动（归 G6，勿动）。参照体检探针 `probe_rxn_wpn4_boot.gd` 口径自验（S1 连锁邻居承伤>0）。
  - **F01（medium）巨刃按 value 生效**：`orbit_weapon.gd:276` 刀体 `0.25*_giant_blade_layers()` 改 `MEC_GIANT_BLADE.value×层数`（:165 的 +0.2 范围项体检判为准确、保持不动）。
  - **F02（medium）分光延迟按 value×层生效**：`laser_weapon.gd:463-467` `_lag_bonus` 改 `MEC_BEAM_LAG.value × 层数`（stack_max=2 第二层真实生效），替代 `LAG_TICK_PER_SUB` 存在性判断。
  - **F03（medium）镜面奏鸣按 value 生效**：`mirror_image.gd:174-183` `TEMPO_PER_LAYER` 常数改读 `MEC_MIRROR_TEMPO.value × 层`。
  - **F04（medium）环绕三选一数字失真**：`orbit_weapon.gd:236-248` 三形态硬编码乘区改读对应 tres `value`（AXE/BOLT/SWORD tres 的 value 从 0.0 落真实基准 0.25/0.50/0.25），品质缩放沿用既有 value×scale 链路（参照 MEC_GIANT_BLADE 金卡重写正确的前例）；双数字词条（范围+体积等）的次数字保持 params/固定值，卡面重写若必须动 card_generator.gd 的 ×N 分支（归 G5）→ 升级。
  - **D13（medium）激光射速定格**：rof 变更时对常驻束（lifetime=0）回刷 `tick_rate`（laser_beam.gd:187 spawn 定格 → 增设 refresh 路径，对齐 :325 仅 BEAM_LAG 回写的先例），使薇拉/伊可/CDR 折算的射速增益覆盖 W4/W5。
  - **C16（medium）环绕球命中反馈接线**：在 orb 命中结算点调用 `orbit_field.gd:717` `_fire_hit_fx`（当前全仓零调用，`_orb_punch`/`_hit_flashes` 唯一写点在函数内）。
- **定向套件**：`r198_flow_weapon`、`rxn_channel`、`w4_prism`、`weapon_orbit`、`high_stack`、`formula_pipeline`
- **风险**：B 族数值变更可能撞 `test_buff_audit` 类锁定断言——随修更新并注明 R199 + 全仓 grep 副本。

### G4 武器数据与面板文案组
- **独占文件**：`repo/resources/weapons/`（W1_pistol~W10_boomerang 全部 10 个 .tres）、`repo/scripts/ui/pause_overlay.gd`、`repo/scripts/ui/hud.gd`、`repo/scripts/core/game_const.gd`、`repo/scripts/ui/lore.gd`
- **问题与修法**：
  - **N02（medium）W3 L4 零增益**：W3_shotgun.tres 按 A3 §3.3 真源回修——L3 pellets 9→8（L4 保持 9），使 L3→L4 有真实增益（面板 DPS 140.8→158.4）；复核 W3 无其它字段被此回修波及。
  - **N05+F08（medium）暂停面板词条总值虚标**：`pause_overlay.gd:585` 弃用 `stacked_add_total()`（trait_base.gd:42-48 全额累加），改走 R196 真值聚合（trait_stack.gd `aggregate_panel` 口径，玩家侧先例 player.gd:519-527）；不改 trait_base/trait_stack（无主认领，如必须改先确认与其它组无交叠再动，属本组延伸需在提交说明声明）。整数池显示小数（F09）不在本项范围（deferred）。
  - **N06（medium）开发行话出卡面**：10 把武器 tres 的 `note` 重写为玩家可读文案（剥离 R187 §2.4/p1_polish/「旧 note…过期修正」/内部词条 id 等行话；数值事实保留、provenance 弃入 git 历史）；pause_overlay.gd:472/:490 与 hud.gd:803-815 渲染逻辑零改动（数据驱动即愈）。
  - **P08（medium）拖动教学缺位**：lore.gd:10-15 菜单行补「战斗内拖动屏幕移动角色」操作说明；hud.gd 战斗内首局一次性提示（沿用既有 toast/hint 展示通道，Meta 记一次性标志）；新文案真源进 game_const.gd。不新增交互、不改输入（登记待真机项不碰）。
- **定向套件**：`r196_growth`、`high_stack`、`r197_build_panel`、`r190b_tips`、`verify_feedback`
- **风险**：note 重写后 `probe_note_entry` 类文案卫生探针应转 PASS；如有断言锁 note 原文按通用纪律更新。

### G5 卡池与遗物门禁组
- **独占文件**：`repo/scripts/cards/card_generator.gd`、`repo/scripts/meta/mechanic_gate.gd`；`resources/traits/MEC_PARALLEL_CAL.tres`、`MEC_RICOCHET_HALL.tres`、`MEC_KILL_BLAST.tres`、`MEC_KNOCK.tres`
- **问题与修法**（统一思路：**不合格武器不再上架**，gate 在上架侧收紧而非战斗侧兼容）：
  - **D01 平行校准**：gate 新增能力键（如 `requires_weapon_keys: ["lateral_gap_levels"]`），card_generator.gd:494-543 校验候选 WeaponData 实有该键（全仓仅 W1 有，ballistic_weapon.gd:342-344 消费实证）；MEC_PARALLEL_CAL.tres:15 落该键。
  - **D02 回廊弹幕**：同上能力键（requires_trait=MEC_BOUNCE 之上再要求编队键），MEC_RICOCHET_HALL.tres:15 补齐；卡面「散弹变回廊弹幕」随上架消失不再失实。
  - **D03 死亡新星**：gate 新增 `requires_projectile` 语义（仅弹道/自导等携带 projectile 上下文的形态），MEC_KILL_BLAST.tres:15 收窄（对照 trait_effect_mech.gd:27 的 projectile null 早退）。
  - **D04 动能冲击**：MEC_KNOCK.tres `required_forms` 去掉 3（近战追击者 W9 零击退设计，orbit_weapon.gd:255-259 注释自证）；纯数据修。
    - **R199 执行口径 supersede（升级仲裁批准）**：W8_orbit_field.tres:55 与 W9_arc_slash.tres:55 同 form=3，「去 3」会连带下架击退真实消费方 W8（orbit_field.gd:583；w8_charge_cases.gd:424「40+60」功能锁定）并打红 pool_wiring_cases.gd:306 / r187_rework_cases.gd:460/:2095 三处 R187 锁定断言。改保留 `required_forms [0,2,3]` 原样 + gate 新增 `excluded_weapons` 键，MEC_KNOCK.tres 落 `["W9_arc_slash"]` 精确下架 W9；mech_gate 补 W9 不含 / W8 仍含货架正反断言锁死口径（证据链见升级记录）。
  - **D06 每击谐振**：`mechanic_gate.gd:112-116` `relic_allowed` 增加角色门（无技能角色不上架 REL 每击谐振；角色 has_skill 判定对照 player.gd:676-677）；不改 relic_handler.gd（无主认领，如确需动在提交说明声明）。
  - **D17 激光双元素死卡**：card_generator 上架侧收窄——激光形态武器已持有元素词条时不再上架第二张元素词条卡（读 owned traits + form 判定；设计语境 W4 主束单元素定案，laser_beam.gd:14-15）；不改 combat 侧文件（weapon_base/trait_effect_elemental 若确需动归 G3 → 升级）。
- **定向套件**：`pkg3`、`mech_gate`、`elite_affix`、`w1_volley`、`verify_feedback`

### G6 元素与技能通道组
- **独占文件**：`repo/scripts/combat/elemental/elemental_system.gd`、`repo/scripts/entities/player/player.gd`、`repo/scripts/meta/meta_manager.gd`、`repo/scripts/gamefeel/elemental_fx_layer.gd`、`repo/autoload/event_bus.gd`
- **问题与修法**：
  - **D07（medium）玻璃大炮全伤害承诺**：elemental_system.gd 三处 bare `DamageContext.make()`（:505-516 DOT、:616-627 连锁、:404-423 反应）与 player.gd 毒沼绽放（:614-625）/毒云（:764-771）结算前统一注入遗物乘区（`inject_relic_pools`，管线消费先例 projectile_base.gd:440/laser_beam.gd:528/weapon_base.gd:217）。猎首者/连杀狂热/双重节拍同通道自动受益。
  - **D14（medium）毒技能误走 FIR**：player.gd:618/:770 `ctx.element = GameConst.Element.FIR` 改无元素/KIN 通道（毒系技能不被 E4/E8 的 FIR 免疫拦零；damage_pipeline.gd:288-296 免疫判据零改动）。
  - **F17（medium）燎原假反应**：燎原传火不再冒用 `reaction_triggered(RXN_FIR_ICE)`——event_bus.gd 增加独立传火表现信号（或 reaction_triggered 加来源参数），elemental_system.gd:590 改发新通道，meta_manager.gd:728-740 消费口保持只认真反应；图鉴/成就计数口径随之矫正（对照 :737「本口不滤」注释一并更新）。
  - **H01（medium）毒云特效滞留**：elemental_fx_layer.gd:816 每跳重置 `left=6.0` 改为剩余时长语义（fx 层本地计时，或 event_bus.gd 增 `poison_cloud_end` 信号由 player.gd:231-237 云结束时发射；两案取一，推荐后者语义最准），结束后即入渐隐。
- **定向套件**：`rxn_channel`、`rxn_codex`、`elem_immune`、`r192_element`、`r198_element_fx`
- **风险**：rxn_codex 可能锁定「燎原点亮图鉴」的现行为——按通用纪律随修更新并注明 R199。

### G7 界面可读性与商店组
- **独占文件**：`repo/scripts/cards/card_select_ui.gd`、`repo/scripts/ui/menu_screen.gd`、`repo/scripts/ui/shop_ui.gd`、`repo/scripts/ui/boss_bar.gd`；（如需改断言）`repo/tests/runner/verify_feedback_cases.gd`
- **问题与修法**：
  - **P05/P06/F15（medium×3，同根因一次修）**：card_select_ui.gd:393-400 描述区扩容——`size=(cw-36,58)+clip_text` 改为自适应高度 autowrap（按 StickerTheme 行高估行数，承载描述+品质注记+满层质变+超帽+成对 ⇄ 尾注 3-4 行；参照体检行高实测 18pt≈54px 宿主相关，用实测而非拍值），保证 ⇄ 成对提示与品质注记整行可见。文案内容零改动（源在 tres/GameConst）。
  - **P07（medium）图鉴描述换行**：menu_screen.gd:960-966 `_make_codex_row` desc_l 加 autowrap 并按内容扩高（71 条中最长风域 1263px 需完整可读）。
  - **F12（high）黑市特化重写**：shop_ui.gd:130-137 对词条行对齐卡架的 `_rarity_desc_mech` 口径（可只读引用 card_generator.gd:250-289 的实现，不改其文件）——计数型/护盾/死亡新星/元素裂变四族品质数字与实际生效一致（MEC_SHIELD 除法间隔语义、KILL_BLAST 42%/78%、VOID ×2.52/×4.68 全对齐）。
  - **F13（high）黑市 cap 缩放**：shop_ui.gd:135-137 补 `cap_pool_p × scale`（对照 card_generator.gd:177-178），紫/金 MULT 词条合并上限如实展示。
  - **F14（medium）黑市超帽注记**：黑市放行超帽层（:275-279）时货架行追加 `GameConst.OVERCAP_NOTE` 与满层质变 ◆ 预告（双写对齐卡架 card_generator.gd:682-689 口径）。
  - **C15（medium）BossBar 相位点点亮**：boss_bar.gd 连接 `boss_phase_changed`（发信点 enemy.gd:1015/:1018/:1040；全仓唯一 connect 现仅 game_loop.gd:1525 音效侧）并在 `tick()`（:69-113）内调 `_sync_phase`（:258）；`_on_boss_spawned` 置 `_last_phase=-1` 后的首次刷新随之生效。
- **定向套件**：`verify_feedback`（F3 断言在本组文件，如涉及可见性断言随修注明 R199）、`p3`（BossBar）、`market_supply`、`r198_menu_meta`、`r198_hud_layout`
- **纪律提醒**：只改几何/包装/接线，不改交互行为（登记待真机项不碰）；D08 诅咒卡标记属 deferred 不做。

### G8 测试套件修复组
- **独占文件**：`repo/tests/runner/r188_idle_cases.gd`
- **问题与修法**：
  - **H04（medium）LOD 死组清账**：删除 :1086-1123 敌段 LOD 断言组（游戏侧 R189c 已整体拆除 `_enemy_lod*`，:1020/:1078/:1099-1112 调用即脚本报错源），P4 组 3 条性能守卫断言或随 LOD 移除注销、或改写为不依赖已拆接口的等价守卫；总账数同步更新。删除/改写注明 R199。**不得顺手改任何游戏侧文件**。
  - H05（P7 时敏）不在本组修：保留断言，注明其对环境敏感，判定以功能断言为准、P7 超预算记录不拦截（纪律：r188 性能三跑禁跑，单跑套件验证允许）。
- **定向套件**：`r188_idle`（单跑；先落日志再取退出码）

---

## 三、Deferred 清单与理由（66 项）

**A. 内容/设计扩展，需策划拍板或新资源（不阻塞发布）**
- P22 三图 w10 同一只 Boss——需新 Boss 资源与差异化设计，属内容扩展非缺陷。
- P23 终 Boss E6_boss3 剧情线缺席——投放位置是设计决策（无尽专属 vs 剧情彩蛋），需策划拍板。
- P24 草原 w10 收官无 TAG_FINAL_BOSS——low；与 N10 同族一键修，G2 改沼泽波表时若顺手可同批（不强制、不阻塞）。
- P25 分图仅云层染色、P26 每日锁图、P27 E24 闪现怪仅 2 只、P28 主题图 grunt 占 74%、N11 无尽 w36-49 Boss 真空——均为内容丰富度问题，留给内容版本。
- P15 通关解锁角色无 toast、P17 成就无进度、P04 HUD 无进度常驻——新功能，非发布阻断。

**B. 文案/视觉打磨批（建议 R200 统一批，真源 GameConst）**
- P10 难度副文案行话、P11 LEVEL UP 英文（改则须同批改 pkg4:300/auto_idle:295/r188_idle:1359 三处锁定断言）、D09 暴击谐振横幅失真播报、D10 ⚡ emoji 违规（建议与 P11 同批清，P1 闸门升级 BMP 拦截一并做）、D12 黑市准入文案、N03 W7/W8 备注漂移、H03 槽位专属章、H06 绽放行出框 8px、F16 宝石 tooltip、H02 技能键 tooltip。
- P19 技能音效、P20 受击音效——需音频资产，非代码可修。

**C. 交互/观感待真机（含登记项，按口径不主动改）**
- P12 9 种 BMP 符号安卓字体链未验（unconfirmed）——待真机字体验收。
- H05 r188 P7 时敏断言（unconfirmed）——待安静环境/真机定谳。
- P21 受击红弧方向——机制为读码确定，错向观感需真机复核后再改。
- 登记待真机项（面板底部两档误触、全面屏铺满、激光手感等）维持不动，本规划未将其列入任何修复组。

**D. 代码卫生批（无玩家可见影响或低当量，建议独立卫生批；C01/C02 建议下批优先）**
- C01 gold_drop 判空（触发时脚本报错+该杀金币丢失，low 但建议下批优先——一行守卫）。
- C02 验收假绿（`_enemy_attack_note` 不存在致 2 条断言静默丢失，low 但测试完整性问题，建议下批优先；修时全仓 grep 同名断言副本）。
- C03/H07 注释与账面漂移（R198 移交项，纯文档）。
- C04 add_hp 直挂不乘 ×1.6（失诺但 low；修时注意 :121 等量回补口径同步）。
- C05/C06 每帧分配残留（R188 红线低当量漏网）、C07 _boss_summons 滞留（phase 门恒拦无误召唤）、C08 EventBus 三处直发、C09 法术 timer 越状态、C11 relic effect_id 无对账、C12 balance 回退空转、C13 save 返回值丢弃、C14 damage_alarm 无消费者、C17 五个死函数、C18 九个死访问器、C19 假观测口、C20 复制注释。

**E. 数值/机制低优（现网数据干净或方向玩家有利或既定口径）**
- N04 面板 %漏乘难度系数（纯展示低估）、N12 Boss 弹幕平值（enemy_data.gd:32 既定口径）、N14 双词缀塌缩、N15 概率流不重随机（统计无偏）、F05 ×3.6 文字误伤、F06 类别权重三源漂移（当前无玩家可见影响）、F07 TH 镜像缺口 4/11（运行时零影响）、F09 穿透凑整抹平 ×0.7（玩家多得）、F18 激化不检 IMMUNE_CHILL（方向玩家有利）、F19 冰渊语义漂移（方向玩家有利）、F20 绽放同帧吞反应（触发面窄）、D05 W10 缺 TH_FRACTAL_ECHO（一键数据修，可随内容批顺带）、D08 诅咒卡零标记（挂机策略已避；修需跨 G5/G7 文件，留内容批统一做）、D11 curse_atk_pct 死参、D15 射速不作用 W8 主环（部分补偿存在）、D20 前期保底截短、P02 商店期选卡挂账、P03 连杀跳字截断、P09 黑市行溢出、P13 每日进度泄漏（设计口径需拍板）、P14 W1 手枪卡（与 G5 门禁族同类，low 故 defer）、P16 图鉴重置不彻底、W22/W23 见 A 类。

---

## 四、发布判定

- **当前判定：不满足发布条件。** 依据：8 项 high 全部未修——P01（重开局复活缩水）、N01（Boss 血量超设计 3.3~32 倍）、D18（每图 Boss 双倍血池/弹幕）、F10/F11（背水/壁垒/先手对近战+激光死卡）、F12/F13（黑市品质数字系统性失实）、D16（雷引激光连锁 0 伤）；另有多项 medium「选了就废卡/数字失实」直接影响付费/选卡决策。
- **放行门槛（全部满足方可发布）**：
  1. G1~G8 全部完成，43 项修复落地，且各组定向套件 headless 全绿（先落日志再取退出码，判「汇总/验收汇总」行）；
  2. 8 项 high 逐项有修复后验证记录（P01 复用 tmp_probe_coreloop 口径、N01 复用 ttka_probe 口径、D18 复用 Boss 双生成探针口径、D16 复用 probe_rxn_wpn4 口径）；
  3. r188_idle 单跑功能断言绿（P4 死组清账后总账更新；P7 时敏超预算记录不拦截）；
  4. 全仓无新增 emoji 字面量、无 SpaceGrid/池化纪律违例；
  5. FEEDBACK_TRACKER.md 由收口组统一登记（修复组未触碰）。
- **不阻塞发布但须公示**：deferred 66 项（其中 P12/H05 待真机验收；C01/C02 建议进下批首批）。

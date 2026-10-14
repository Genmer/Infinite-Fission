# 二cu / 二cv 交付文档（灵剑/法器表现重构 + HUD/法器/近战交互与帧率批）

- 交付日期：2026-10-09
- 需求真源：`FEEDBACK_TRACKER.md`「二cu」「二cv」两节（状态列已由本轮收尾更新为 ✅，含遗留标注）
- 编排：workflow-flash（实现/QA heal/评审并发，收尾员归档）
- 证据口径：标注〔实证〕的文件行号为收尾员本轮读码逐处核实；「18 套件回归」为本轮收尾员实跑复验（命令与结果见 §5）；QA heal 数字同时与仓库根日志（`_qaheal_*` / `_qa_cv8_*`）对拍核实；「探针已删除」为上游 workflow 报告声明，收尾员未验证其历史存在。

---

## 1. 批次总览

| 批 | 项数 | 结论 |
|---|---|---|
| 二cu 灵剑/法器表现重构 | 6 | 全部 ✅（#3 为无独立落点的同级化目标，经 #1/#5 拉齐，遗留真机读感确认） |
| 二cv HUD/法器/近战交互与帧率批 | 8+1 收尾 | 全部 ✅（#2/#3/#4/#5/#8 各带评审 low 遗留标注） |

- QA heal：heal r1 全部修复，无 heal 残留。
- 回归：18 套件全绿（上游口径与收尾员本轮实跑一致，见 §5）。
- 出包：出包门禁属上游 workflow 环节，本收尾轮未执行出包，未复验。

## 2. 二cu 各项（灵剑/法器表现重构）

### 二cu#1 灵剑攻击表现：剑光刺出 + 目标斜剑痕
- **实现摘要**：弹体贴图弃火箭式拉长，改细长光刃剑光（`flight_tex` 去护手/剑柄；`SWORD_VIS_MULT=3.2` 拉长、`SWORD_TRAIL_LEN=42` 拖尾加长）〔实证 projectile_base.gd:40-42、:1684 经 `FlyingSwordWeapon.flight_tex` 取图〕。命中反馈：`projectile_base._submit_hit` 在 `_flight_sword` 时于敌位、按来速角发点 `emit_sword_mark`〔实证 projectile_base.gd:865〕；`EventBus` 新增 `sword_mark` 表现层专用信号〔实证 autoload/event_bus.gd:60、:227-228〕；`ElementalFxLayer` 建剑痕池：16 槽并发、斜置 +PI/4、按 `SWORD_MARK_BUDGET`（低档关/中档主痕/高档主+副）质量分档〔实证 elemental_fx_layer.gd:61、:65、:1210 `_build_marks`、:1235 `_on_sword_mark`、:1250 `_tick_marks`〕。
- **改动文件**：scripts/combat/projectile/projectile_base.gd；autoload/event_bus.gd；scripts/gamefeel/elemental_fx_layer.gd；scripts/combat/weapon/melee/flying_sword_weapon.gd。
- **测试证据**：rcu_faqi G1（flight_tex 64px 双版互异 + 常量锚）、G2（sword_mark 直连计数：命中敌位 <20px、角≈来速角、无命中零发点）、G3（16 槽/斜置 45°/寿命隐藏/低档关且还原档位）；r243_lingjian 38/38。

### 二cu#2 灵剑图标 + 环绕化身重做
- **实现摘要**：图标 = 旧阔剑轮廓细版 ×0.6 + 外辉光（`weapon_icon_tex`，56px 画布朝上 -Y，双质变版）〔实证 flying_sword_weapon.gd:22 头注、:276〕；环绕化身贴图与剑光同源（flight_tex 细长光刃），去旧「火箭/阔剑」读感。
- **改动文件**：scripts/combat/weapon/melee/flying_sword_weapon.gd；scripts/combat/projectile/projectile_base.gd。
- **测试证据**：rcu_faqi G6（W13/W11 图标 56px 双版互异族断言）；r243_lingjian 38/38。

### 二cu#3 法器特效表现同级化
- **实现摘要**：本项无独立代码落点——本批仅经 #1（W11 剑光+剑痕重画）与 #5（W13 巨剑三面重画）拉齐两个短板；W8 引爆/W9 刀形抡击/W12 裂地特效沿用 R243 既有水平。「特效同级」为视觉主观判读，代码内无「二cu#3」专门注记与测试锚。
- **改动文件**：无独立落点（见 #1/#5）。
- **测试证据**：无专门锚。
- **遗留**：W8/W9/W12 特效未重画，建议真机确认读感后另立需求（评审 low）。

### 二cu#4 法器表现合一：环绕化身=攻击体
- **实现摘要**：W11/W12 出膛口 `muzzle_position()` → `_avatar_muzzle()`（化身剑尖/斧刃出膛）〔实证 flying_sword_weapon.gd:45-47、ground_axe_weapon.gd:122-124〕；`try_fire` 后经 `player.weapon_avatar_sortie(武器, 目标位)` 委托〔实证 flying_sword_weapon.gd:125-130、ground_axe_weapon.gd:116-117、player.gd:1285〕→ `WeaponOrbitAvatars.begin_sortie` 出击态机（`SORTIE_OUT_S=0.16` quad-in 快扑 → `SORTIE_BACK_S=0.30` quad-out 回环）〔实证 weapon_orbit_avatars.gd:26-27、:279-280、:299 `_tick_sortie`〕——W10 回旋刃出击读感为标杆，去除原地抽风形象。
- **改动文件**：scripts/combat/weapon/melee/flying_sword_weapon.gd；scripts/combat/weapon/melee/ground_axe_weapon.gd；scripts/entities/player/player.gd；scripts/entities/player/weapon_orbit_avatars.gd。
- **测试证据**：rcu_faqi G4（player 委托口 + W11/W12 开火→`_sorties` 槽 active + 出段→回段→归位态机手驱 + 无口环境零副作用）、G5（muzzle 距玩家 40~130px 化身环带且 ≠ 本体位）；r243_lingjian、test_weapon_orbit 49/49。

### 二cu#5 阔剑（W13）重画为 DNF 巨剑形象
- **实现摘要**：`_blade_polygon` 直刃顶点表（greatsword 分支平行等宽厚重直刃 + 长斜角巨尖，poly[1]=(118.0, 9.0×w)，w=1.6 时即 (118,14.4)）＋ `_draw_blade` 直线刃口/刀背描线〔实证 arc_slash.gd:561-573，头注明写「二cu 重画」〕；化身/图标同步 DNF 巨剑重画：平行等宽刃 + 双侧金刃口 + 宽护手，暗黑刃身 + 金刃口，质变 ×1.3 加宽 + 金裂纹〔实证 orbit_weapon.gd:587、:610-621 `_icon_layers`〕。
- **改动文件**：scripts/combat/weapon/melee/arc_slash.gd；scripts/combat/weapon/melee/orbit_weapon.gd。
- **测试证据**：rcu_faqi G6（greatsword poly[1]≈(118,14.4) + saber 原表回归锁 + W13 图标 56px 双版互异）；r243_melee 47/47。

### 二cu#6 现阔剑轮廓转给灵剑：再细 + 发光
- **实现摘要**：与 #1/#2 同链——W11 flight_tex 细长光刃继承现 W13 宽刃轮廓细版，银蓝辉光（图标外辉光、弹体 streak 拖尾）〔实证 flying_sword_weapon.gd 图标头注「银蓝小剑」、projectile_base.gd:40-42 常量〕。
- **改动文件**：同 #1/#2。
- **测试证据**：rcu_faqi G7（源码锚：外辉光/二cu/×1.9/streak）；r243_lingjian 38/38。

## 3. 二cv 各项（HUD/法器/近战交互与帧率批）

### 二cv#1 多层护盾层数显示「X N」
- **实现摘要**：① `player.gd` 新增 `var shield_layers: int = 0`〔实证 player.gd:202〕，`apply_shield_trait` 内 `shield_layers = p_layers`（重复挂载即刷新为最新聚合总层数）〔实证 player.gd:801〕，`respawn()` 清零段同步归零〔实证 player.gd:2323〕——grep 证实 `apply_shield_trait` 唯一调用点 weapon_base.gd:343 为聚合 >0 才回调、无 detach 词条路径，故 respawn 是唯一归零口〔实证 weapon_base.gd:333-343〕。② `hud.gd` 护盾条上叠 StickerTheme 白色 14px Label（pos 108,8，护盾 SOFT 标签右侧）〔实证 hud.gd:50、:1673-1675〕，每帧在 shield_interval>0 块内 typeof 显式判型刷「X N」（有几层显示几层），条本体可见性逻辑未动〔实证 hud.gd:267-269〕。
- **改动文件**：scripts/entities/player/player.gd；scripts/ui/hud.gd。
- **测试证据**：verify_feedback_cases.gd 护盾链 case 补断言「2 层 → shield_layers=2」〔实证 verify_feedback_cases.gd:1365-1367〕；test_verify_feedback 684/684；test_pkg5 145/145。

### 二cv#2 近战范围虚线显示
- **实现摘要**：`ArcSlash._draw` 分流：窗口外本体槽画 `_draw_range_dash`——半径=slash_radius（判定真值；W13 加宽倍率是刀形视觉轴不改虚线半径）、扇区=arc_deg（W13 质变 270° 随槽位字段）、分段短弧 draw_arc（dash 12px/gap 8px/α0.35/色=实时 tint 提亮）；`_range_dash_active` 限定本体槽（`weapon.arc_slash==self` 防多刀池/幻影斩叠影）+ generation==0 + `_fx_quality()>0`；tick 待机锚随宿主 muzzle、`queue_redraw` 仅切换帧去重；窗口内刀本体照扫不画；无新节点〔实证 arc_slash.gd:189-197 tick 分支、:438-444 分流、:494 `_range_dash_active`、:527-536 `_draw_range_dash`〕。
- **改动文件**：scripts/combat/weapon/melee/arc_slash.gd。
- **测试证据**：probe_rcv_melee 12/12（虚线门/锚跟随/本体槽限定，探针已删除不留文件——上游声明）；rcu_faqi、r243_melee 回归绿。
- **遗留**（评审 low）：首斩前待机虚线半径 = spawn 逐级基值快照（arc_slash.gd:111），装备成长词条后与 `melee_sanctuary_r`（恒 effective_slash_radius，player.gd:624-633）暂不同值，首次攻击后自愈——显示真值口径缝隙，建议注释如实标注或待机半径改读 effective 值。

### 二cv#3 法器环绕分层
- **实现摘要**：新增 `RING_STEP=30` 与 `RITUAL_IDS` 精确五 id 集合（W8_orbit_field/W9_arc_slash/W11_spirit_sword/W12_ground_axe/W13_great_sword）〔实证 weapon_orbit_avatars.gd:15-16〕；新增 `_ring_layers()` 层号表——法器按 entries 序记 0,1,2…，非法器/data 缺失恒层 0，僚机副本/镜面跟序不豁免〔实证 weapon_orbit_avatars.gd:165-184〕；`_process` 化身半径改 `RING_R + 层号×RING_STEP`〔实证 :52、:77-79〕；`_tick_blade` 贴弧基准 `maxf(slash_radius+10, 本槽环位+26)` 使外层 W9 挥斩不内跳（现状 160 恒大于各层基准，行为零变化）；`_tick_sortie` 签名加 `p_home_r`，出击回环落回本槽自己的层〔实证 :299-322〕；`begin_sortie` 本身无半径计算（from=当前位、to=目标位）、`avatar_global` 用化身实际位前伸——均自动跟随，确认无需改。
- **改动文件**：scripts/entities/player/weapon_orbit_avatars.gd。
- **测试证据**：rcu_faqi G4/G5 按 `_ring_layers` 同式现算半径适配（化身槽位经 `_entries_of().find` 动态定位不假设排布）；test_weapon_orbit 49/49。
- **遗留**（评审 low ×2）：① 分层按法器装备序（第 i 把第 i 层），非「旋风恒第一层」严格读法，建议真机确认读感；② `_ring_layers` 每次 `_process` 新建并返回 `Array[int]`，落在常驻逐帧路径，与本仓「每帧分配=常量税」纪律相悖（量级小非阻断），建议成员缓冲原地填充或 entries 脏变时重算；同族 `_entries_of` 逐帧建 Array 属 R183 既有路径可一并收口。

### 二cv#4 旋风刀（W9）5 级后卡帧
- **实现摘要**：源码审查结论：用户点名的三个嫌疑（池槽重铺/化身图标/缓存键）均已覆盖——池槽重铺 `orbit_weapon._on_transcend→_respawn_slash_pool` 带 transcended 键（prime③ 锁定）；化身图标 weapon_orbit_avatars.gd:61-66 每帧按 `get(transcended)` 选 base/t2；TextureFactory 缓存键已分版 `weapon_icon_<id>` vs `<id>_t2`。找到并修两个真实的「质变后不刷新」缺口：A) `_open_child_slash` 子斩/回斩 spawn 键缺 transcended——质变后子窗恒画基础形（W9 回斩无加深/无双旋臂残影、W13 幻影斩无 1.3× 加宽金裂纹），补传继承〔实证 arc_slash.gd:375 及 :42 头注〕；B) 化身扫弧 `_tick_blade` 只读逐级表 arc_deg，缺质变 `arc_bonus_deg`（W9 质变 200° 时化身仍扫 160°），并入 `p_w._tc_mult("arc_bonus_deg", 0.0)`〔实证 weapon_orbit_avatars.gd:255-257〕。
- **改动文件**：scripts/combat/weapon/melee/arc_slash.gd；scripts/entities/player/weapon_orbit_avatars.gd。
- **测试证据**：probe_rcv_melee 12/12（#4-A 子代继承 transcended 且 echo 不递归、#4-B 源码断言——探针已删除，上游声明）；r243_melee 47/47、r243_prime 65/65。
- **遗留**（评审 low）：「有一帧贴图一直卡着」的真机症状无法在 headless 复现验证，修复为「质变切换路径贴图态旁路」诊断的两处落点、诊断自洽，是否根除需真机复验。

### 二cv#5 阔剑选元素后不变色
- **实现摘要**：根因 = spawn 处 blade_tint 仅快照（`_resolve_blade_tint`），槽体常驻不重铺 → 选元素后不变色、重进主菜单重建武器才变（与用户描述逐字吻合）。修法取改动面小者：绘制期实时取色 `_live_blade_tint()`——宿主元素池非 KIN 时逐帧读 `blend_element_color()`，空池/无宿主回落快照；`_t2_fill` 与虚线色消费之〔实证 arc_slash.gd:45 头注、:515-524、:551-556〕。blade_tint 字段与 spawn 解析层级保留（fengren ①③⑩ 读回口零位移），`_blade_polygon` 顶点表未动，greatsword 暗黑底+金刃口分支结构原样（tint 仍只进渐变插值）。
- **改动文件**：scripts/combat/weapon/melee/arc_slash.gd。
- **测试证据**：probe_rcv_melee 12/12（#5 建槽后 attach 火卡即时取色/快照字段保留——探针已删除，上游声明）；r243_fengren 31/31、r243_elem 33/33、r243_melee 47/47。
- **遗留**（评审 low）：追补「选卡即变色」让待机虚线分支逐 tick 调 `_live_blade_tint()`（arc_slash.gd:197）与上帧 `_dash_tint` 比色，内部走 `weapon._element_pool()`（weapon_base.gd:512-523 每次新建 `Array[int]`）——待机期每 tick 一次小数组分配、挥斩窗 `_t2_fill` 每次重绘同源分配；去重意图正确（只挡重绘不挡取色），建议缓存元素池或改比对 dominant_element()/trait 世代脏标（R225 armed 快照同先例）。

### 二cv#6 近战敌人近身不生效（近身豁免）
- **实现摘要**：按分析定案 (a) 落地近身豁免：`enemy.gd` 接触结算口（原 :824-831）前置守卫——CHASE 行为 + 非 Boss + 玩家距离² ≤ `melee_sanctuary_r²` → 跳过结算，CONTACT_RADIAL on/off 两分支共用同一条守卫，命中且「本会结算」（重叠成立）时 `DebugStats.count(&"melee_enemy_suppressed")`（防 60Hz 膨胀只在结算位计数）〔实证 enemy.gd:825-854〕。`player.gd` 新增 `melee_sanctuary_r` 字段（hitbox_radius 旁）〔实证 player.gd:160〕并在 tick 既有 weapon_slots 循环内零新增遍历逐帧折算 = 已装备 MELEE 形态武器最大 effective_slash_radius（has_method 鸭子守卫，W11/W12 出击型无此方法不贡献），无近战武器恒 0 = 规则完全惰性〔实证 player.gd:624-633〕。实际语义：持近战武器时追击型近战敌贴身磨血整体豁免（接触距离 ≈30px 恒 ⊂ 刃圈 ≥150px）；Boss 冲锋（同走接触通道，enemy.gd `_tick_boss_charge` :1880 附近注释实读确认）与 E4 引爆/E12 毒爆/法术圈/闪现引爆独立通道全部不在守卫面。
- **改动文件**：scripts/entities/enemy/enemy.gd；scripts/entities/player/player.gd；tests/runner/rcv_sanctuary_cases.gd（新建）；tests/runner/verify_feedback_cases.gd。
- **测试证据**：新建语义锁定套件 test_rcv_sanctuary（18 项：惰性锚/豁免生效+off 态信号通道孪生/RANGED 对照/Boss 对照/E4 通道隔离/半径同源对拍+max 语义+190 表值锚/旗复位+总项数）——本轮实跑 18/18 通过；verify_feedback_cases.gd 尾部补 `_test_rcv6_sanctuary` 规则断言（贴脸 hp 不动 + 抑制计数>0，含共享态复位）〔实证 verify_feedback_cases.gd:97、:5099〕，套件 684/684。

### 二cv#7 超频核心紫金同色
- **实现摘要**：主修 `card_generator._make_relic_card`（:934-950）：遗物卡 rarity 从纯按波 roll 改为 `maxi(_roll_rarity(p_wave), tres_rarity)`，`tres_rarity=clampi(int(r.rarity),0,4)`（.tres 缺省 3）〔实证 card_generator.gd:943-947〕——品质下限单源 RelicData.rarity，18 件遗物全 rarity=3（金档 #ffc93c=RARITY_LEGEND），假紫 roll 不复存在，超频核心恒金档，卡面顶带/类别行/圆珠经既有 card_select_ui.rarity_color 链自动变金。保留 `_roll_rarity` 调用是刻意的：它是选卡确定性流（seed=42 定种）的流锚，去掉一次 rng 消费会让后续类别 roll 整体位移。接线补点：`shop_ui.gd:152-161` 黑市遗物货 rarity 写死 2 → 读同一 RelicData.rarity（同式钳制）〔实证 shop_ui.gd:154-160〕；`shop_ui.gd:591-593` 行名取色条件增补 `or kind == "relic"`〔实证 shop_ui.gd:591-593〕——商店行名与卡面同品质色。未给 RELIC 加 RARITY_VALUE_SCALE 缩放（遗物=全局规则一次性件，遵分析方案）。
- **改动文件**：scripts/cards/card_generator.gd；scripts/ui/shop_ui.gd。
- **测试证据**：test_pkg3 129/129（含子代 hitbox 4.2 锁定的既有断言族未破）。

### 二cv#8 帧率诊断（vc48 真机日志）
- **实现摘要**：三处缓解 + 口径更新（详见 §6）：① `card_select_ui` mobile 门内开窗分帧——首帧只装配窗体+前 3 张卡（`CARD_SPLIT_FIRST=3`），余卡 `_process` 预算闸（8µs×1000=R212 刀4 同形）内续建，close 清计数防悬空；choose/highlight 读 `_cards` 数据面、R188 自动窗 0.5s ≫ 续建 1-2 帧，真链零感知；新增 `card_split_override` 哨兵（-3 模拟 mobile / -2 强制关，pool_valve_override 先例），headless 默认门关逐位零扰动〔实证 card_select_ui.gd:61-77、:120〕。② `damage_pipeline._settle_cap_now` tier3 并档 tier2 同帽（60Hz 96 / 30Hz 192，:444-469 + 门控注释同步）——tier3 冻结态削峰器不再缺席〔实证 damage_pipeline.gd:394-395、:463-465〕。③ `texture_factory` 新增 `_img_cache` CPU 旁表（键同 enemy 基图键，不改共享键空间语义），`_render_keep` 烤图期留 Image 引用，`enemy_tex_flash` 优先读旁表（像素逐位同源）免 GL→CPU 回读，旁表缺席兜底回落旧路径；像素混白算式零触碰〔实证 texture_factory.gd:13、:115-116、:133、:1855-1866〕。④ `debug_stats.gd:492` 头注同步 顺/冲/弃 判读口径（tier1-3 生效、帽表含 tier3）〔实证〕。所有改动注释标「二cv#8 帧率」。
- **改动文件**：scripts/cards/card_select_ui.gd；scripts/core/damage/damage_pipeline.gd；scripts/ui/texture_factory.gd；autoload/debug_stats.gd。
- **测试证据**：test_r223_settlebudget 48/48（「tier3→帽96」断言随改后绿）；test_pkg5 145/145；_qa_cv8_r223_run1.log / _qaheal_pkg5_run4.log 同数对拍。
- **遗留**（评审 low）：vc48 诊断中的物步µs 尖峰（38-53k，R237 延迟冲刷桶嫌疑）本批未见对应改动，帧率是否达标待真机复测（见 §6）。

## 4. 二cv#9 收尾项（测试套件 + 全量回归 + 出包）
- **实现摘要**：按入口 `test_rcu_faqi.gd` 头注 G1~G7 写全用例体（30 断言 + `EXPECTED_TOTAL=32` 总项数防假绿）〔实证 rcu_faqi_cases.gd:6-13、:23、:56-57〕，结构仿 r245_diff_star_cases（_check/fail_count/总项数断言），夹具仿 r243_lingjian_cases（GameLoop 装配 + 桩敌 + crit=0 探针）。分组：G1 剑光弹体常量锚 / G2 命中剑痕发点直连计数 / G3 FX 剑痕池手驱 / G4 化身出击态机 / G5 出膛口=化身环带 / G6 W13 直刃与图标 / G7 源码锚。适配了并行同事二cv#3 环绕分层对 weapon_orbit_avatars.gd 的在途改动（`_tick_sortie` 新增 `p_home_r` 参数，测试按 `_ring_layers` 同式现算半径）；化身槽位经 `_entries_of().find` 动态定位不假设排布。
- **改动文件**：tests/runner/test_rcu_faqi.gd；tests/runner/rcu_faqi_cases.gd。
- **测试证据**：本轮实跑 32/32 通过（G1~G7 全分组命中，见 §5）。

## 5. 测试证据汇总（收尾员本轮实跑）

命令（逐套执行，exit 0 且 FAIL 0 为绿）：
`"E:/Code/Agent/Infinite-Fission/android_export/Godot_v4.3-stable_win64.exe" --headless --path . -s tests/runner/<套件>.gd`

| # | 套件 | 结果 |
|---|---|---|
| 1 | test_rcu_faqi | 32/32 通过 |
| 2 | test_rcv_sanctuary | 18/18 通过 |
| 3 | test_verify_feedback | PASS 684 / FAIL 0 |
| 4 | test_pkg3 | PASS 129 / FAIL 0 |
| 5 | test_pkg5 | PASS 145 / FAIL 0 |
| 6 | test_r223_settlebudget | 48/48 通过 |
| 7 | test_r243_lingjian | 38/38 通过 |
| 8 | test_r243_melee | 47/47 通过 |
| 9 | test_r243_base | 46/46 通过 |
| 10 | test_r243_boom | 31/31 通过 |
| 11 | test_r243_block | 32/32 通过 |
| 12 | test_r243_trait | 43/43 通过 |
| 13 | test_r243_liedifu | 32/32 通过 |
| 14 | test_r243_fengren | 31/31 通过 |
| 15 | test_r243_prime | 65/65 通过 |
| 16 | test_r243_elem | 33/33 通过 |
| 17 | test_weapon_orbit | PASS 49 / FAIL 0 |
| 18 | test_w8_charge | PASS 54 / FAIL 0 |

**18/18 套件全绿，全部 FAIL 0**——与上游「回归=18/18」口径一致（套件清单为本收尾员按本批触碰面选定；上游未附清单，无法逐套对名）。上游 heal 轮数字与仓库根日志对拍一致：`_qaheal_test_rcu_faqi_rev.log`（32/32）、`_qaheal_test_verify_feedback_rev.log`（684/684）、`_qaheal_test_pkg5_rev.log`（145/145）、`_qa_cv8_rcufaqi_run1.log`（31/31，heal 前版）、`_qa_cv8_r223_run1.log`（48/48）、`_qa_cv8_pkg3_run1.log`（129/129）。注：套件 stdout 末尾常见 Godot 资源清理 ERROR 行（resources still in use at exit），系引擎退出清理噪音，与本仓历轮 QA 判绿口径相同，不影响 exit 0 判定。

## 6. 帧率分析结论（二cv#8）

**分析员 summary（vc48 真机日志）**：fps 27-45 震荡（对比游走态 84-120）；物步µs 尖峰 38-53k；派µs 尖峰至 2585；渲ms 恒 ~16.5（vsync 60）——**模拟轴顿挫，非渲染轴饱和**。物步µs 大值嫌疑 = R237 延迟冲刷桶（debug_stats.gd:492 口径声明原文：「R237 A/B 已排除物理空间 broadphase/配对/信号大头——大值嫌疑=延迟冲刷桶」；该键语义=引擎物理步 + 物理块 message_queue flush 执行的延迟调用〔⑧popup/敌死亡链 DeathPop/Telegraph/桶 place/queue_free/⑦b fx〕+ 其他节点物理相成本）。

**落地方案（本批三刀 + 口径刀，全部已落码〔实证〕）**：
1. **选卡开窗分帧**（card_select_ui.gd:58-161）：mobile 门内首帧只装配窗体+前 `CARD_SPLIT_FIRST=3` 张卡，余卡 `_process` 预算闸（8µs×1000）内续建——砍开窗瞬时装配尖峰；`card_split_override`（-3 模拟 mobile/-2 强制关）供 headless 测试注入口，默认门关零扰动。
2. **tier3 并档削峰器**（damage_pipeline.gd:444-469）：`_settle_cap_now` tier3 并入 tier2 同帽（60Hz 96 / 30Hz 192）——vc48 全程调3 时深载削峰器曾恒缺席，现 tier1-3 全档在场；预算=DPS 守恒 FIFO 顺延，r223 断言随改（tier3→帽96）48/48 绿。
3. **敌基图 CPU 旁缓存**（texture_factory.gd:13、:115-133、:1855-1866）：`_img_cache` 键同 enemy 基图键（不改共享 TextureFactory 缓存键语义），`enemy_tex_flash` 免 GL→CPU 回读，像素逐位同源、缺席兜底旧路径。
4. **判读口径同步**（debug_stats.gd:492）：顺/冲/弃 = tier1-3 生效（tier3 并档注记）、帽表含 tier3，结N≈帽×模N 为预期稳态。

**结论与残留**：本批为缓解刀，非根因刀。vc48 的物步µs 尖峰（38-53k，R237 延迟冲刷桶嫌疑）本批无对应改动；帧率是否达标**待真机复测**——建议同一 vc 口径采新真机日志，对拍 fps 震荡幅度、物步µs 峰值、顺N/冲N/弃N 三键与调N 档位，再决定是否立 R237 冲刷桶专项。

## 7. 遗留清单（全量，均为评审 low；QA heal 无残留）

| # | 落点 | 内容 | 关联项 |
|---|---|---|---|
| 1 | 二cu#3 | 特效同级化无独立落点，W8/W9/W12 沿用 R243 水平，视觉判读待真机确认 | 二cu#3 |
| 2 | arc_slash.gd:111 vs player.gd:624-633 | 首斩前虚线半径=基值快照，与 melee_sanctuary_r 暂不同值（首次攻击后自愈），口径注释建议如实化 | 二cv#2/#6 |
| 3 | weapon_orbit_avatars.gd:165-184 | 分层按装备序非「旋风恒第一层」严格读法，待真机读感确认 | 二cv#3 |
| 4 | weapon_orbit_avatars.gd:165-184 | `_ring_layers` 每帧新建 Array[int]（逐帧分配），建议成员缓冲/脏变重算收口；`_entries_of` 同族 R183 既有 | 二cv#3 |
| 5 | arc_slash.gd:197/:515-524/:551-558 | 待机虚线/挥斩窗逐 tick 经 `_element_pool` 新建小数组，建议缓存或 trait 世代脏标 | 二cv#5 |
| 6 | arc_slash.gd:375 + weapon_orbit_avatars.gd:255-257 | W9 卡帧两缺口已修但真机症状无法 headless 复现，需真机复验根除与否 | 二cv#4 |
| 7 | vc48 物步µs 尖峰 | 38-53k 尖峰（R237 延迟冲刷桶嫌疑）本批未动，帧率达标待真机复测 | 二cv#8 |

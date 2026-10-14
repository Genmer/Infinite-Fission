# 二cw 交付文档（频繁问题复审与错误/性能再规划批 · 审计报告全文 + 修复簇落地）

- 交付日期：2026-10-09
- 需求真源：用户「检查下，之前我频繁说的问题还有没有存在」「错误和性能，都再规划看看」＋ `FEEDBACK_TRACKER.md` 全部历史轮次（~1445 行基线，二cu/二cv 为上一刚完成批）
- 编排：workflow-flash（审计→四簇修复并发→QA heal→收尾员归档）
- **编排说明**：本轮 c9（帧率/性能）在编排时拆为两路子审计——**c9a=性能深挖**（物理相延迟冲刷/物步µs 尖峰，产出性能四案）、**c9b=逐帧分配扫描**（专查 `_process/_draw/tick` 热路径逐帧新建 Array/Dictionary/String/Callable，范围=weapon_orbit_avatars/player/hud/arc_slash/elemental_fx_layer/projectile_base/enemy/damage_popup，明确排除上一批已收口三处：`_ring_buf` 层号表、`_tint_gen` tint 缓存、虚线半径）。编号为本轮运行内口径，tracker/docs 无此定义属预期（主控裁定口径）。
- **证据口径**：标注〔实证〕的文件行号为收尾员本轮读码/实跑逐处核实（grep/读文件/跑套件）；「簇N 实施申报」指任务材料中上游修复簇的申报内容（收尾员抽样核实锚点、未逐项复跑）；「上游申报」指 QA heal 与 18 套件回归口径，收尾员未逐套复跑，仅实跑 3 个与本文直接相关的套件（见 §5）。

---

## 1. 审计总表：每类判定 + 证据 + 复核结论

### c4 反馈吞没（用户反复点名类，最高优先）
- **审计判定**：四项残留成立——①graze 掠过无反馈（0.6s 无敌/死亡窗静默吞没接触与敌弹的轻反馈）；②敌弹饱和时挤占玩家弹配额（`acquire()` 无队伍区分，玩家弹可被敌弹挤到 null）；③非 CHASE 精英词缀金冠死卡（RANGED/BLINK 精英 tick 从不推进词缀，投放面 `enemy_spawner._elite_affix_roll` 本就无 behavior 过滤）；④BossMine 宿主失效静默清（宿主 queue_free 后已 arm 的雷无任何爆炸读感）。
- **证据**〔实证〕：`projectile_pool.gd:30`（`acquire(p_team: int = 0)` 缺省参数）、`:64`（`_force_recycle_oldest_of_team`）、`enemy.gd:818-828`（match 块后独立段，注释自证「RANGED/BLINK 精英的金冠词缀 tick 从未推进」）、`enemy.gd:3329-3344`（`_done` 旗 + `_explode(null)` 原地引爆臂）、`event_bus.gd:36/:203-205`（graze 信号与包装）、`player.gd:226/:742-743`（GRAZE_FEEDBACK_CD=0.25 节流发点）、`game_loop.gd:1091/:2576`（订阅→池化微光）、`debug_stats.gd:44`（graze_hits 计数键）。
- **复核结论**：①②③④ 全部由簇1 收口（零数值刀路径：graze 只发信号不动数值；敌弹配额用缺省参数保全部旧调用点逐位不变）。新套件 test_r248_feedfix 60/60〔实证，见 §5〕。缓办：c4① 数值刀（contact_tick 0.6→0.35）、c4⑥ 遗物 value、c4⑦ 护盾聚合语义——均待评审/用户裁定（见 §3）。

### c8 卡面品质（用户反复点名类）
- **审计判定**：四项残留成立——①五死数字卡特例臂缺失（HIT_BURST/CRITICAL_MASS/FRACTAL/BOUNCE/FUSE_DETONATE 卡面数字≠运行值）；②二元卡假尾注（value≈1.0 的二元卡被拼「品质加成 ×N」假话行）；③PHASE_SYNC 卡面「×2」与运行不符；④ELE lv2 白名单过窄（新 lv2 键不随品质缩放）。
- **证据**〔实证〕：`card_generator.gd:316`（`_rarity_desc_mech`）及五 id 臂区段 `:361`（HIT_BURST）/:368（CRITICAL_MASS）/:374（FRACTAL）/:386（FUSE_DETONATE）、`:424`（二元卡「（品质不影响效果）」尾注）；`card_select_ui.gd:565`（`compose_desc_text`）/:577（同一字样判同跳过假话行——单源标记，预热键天然一致）；`MEC_HIT_BURST.tres` 描述已无用户反馈泄漏字样、`MEC_PHASE_SYNC.tres` 描述已去「×2」〔实证，两 .tres 全文读验〕。
- **复核结论**：按「卡面=运行值」硬要求落地，白卡逐字节回退。套件同 test_r248_feedfix（五卡蓝/金卡面=运行值+白卡回退+10 张二元卡尾注+ELE 三键+E-08 不写穿断言）60/60〔实证〕。

### R188 逐帧分配纪律（先例 R188/R225：「_process/_draw/tick 热路径禁新建数组/字典/字符串拼接」）
- **审计判定**：⑪ 闪白窗逐帧 `_body_tex_spec()` 每衰减帧新建 Array(2)+String 的分配税成立；其余十条热路径逐帧分配残留成立。
- **证据**〔实证〕：⑪=`enemy.gd:176-179`（`_body_kind/_body_angry` 规格缓存成员）、`:2772`（`_refresh_body_spec` 写点）、`:2102-2103`（池复用归位 grunt）、`:2703-2706`（衰减帧读成员，注释自证「原每闪帧新建」）；十条=簇4 实施申报：`weapon_orbit_avatars.gd:33/:35`（_entries_buf/_slot_cache）、`weapon_base.gd:43-48/:130-133`（_blend_gen 世代缓存，桩不写缓存——bool(null) 纪律合规）、`hud.gd:75/:77/:959/:1981-1986`（_tb_cand_buf/HP 量化缓存/FPS 双锚）、`arc_slash.gd:110/:114/:116/:239-243/:319-322/:502`（候选拷贝成员化——query_arc 内部缓冲不得跨查询持有的 R5 别名契约保持）、`elemental_fx_layer.gd:21/:232/:241`（每雷槽 pts 缓冲复用）。
- **复核结论**：⑪ 归簇1、十条归簇4，全部零语义变更；簇4 回归门禁 8 套件全绿〔簇4 实施申报：test_rcu_faqi 32/32、test_weapon_orbit 49/49、test_r243_prime 65/65、test_r243_fengren 31/31、test_r243_base 46/46、test_r243_melee 47/47、test_r195_layout 527/527、test_r198_element_fx 36/36，exit 0——收尾员未逐套复跑〕。

### c2 元素弹体染色
- **审计判定**：三处活口成立——①W6/W7 导弹弹体不染元素色；②镜面复制体弹体恒 PLAYER 银白；③W11 飞剑/W12 掷斧 `flight_tex` 无色参（R243 漏登记项）。
- **证据**〔实证〕：`texture_factory.gd:1197`（`missile_tex(p_fill: Color = Color(0.78, 0.84, 0.95))` 缺省=原弹体浅灰蓝字面保 KIN 观感）；`projectile_base.gd:1598-1600`（导弹接线，注释自证「KIN 走原浅灰蓝字面……_plain_fill 对 KIN 返 PLAYER≠原弹体灰蓝，不能直接二参」）、`:1618-1619`（镜面 `mirror_bead` 接线，R187 禁金染天然保持）、`:1684`（`_flight_form_tex`）；`flying_sword_weapon.gd:326`（`flight_tex(p_transcended, p_fill = PopPalette.PLAYER)`）、`ground_axe_weapon.gd:496/:499/:510`（`FLIGHT_STEEL` 常量 + 质变门 `tainted = p_transcended and p_fill == FLIGHT_STEEL`＝元素优先）。
- **复核结论**：三处活口全部收口（簇2）；W6/W7/镜面/flight_tex 三笔缺口已增登记入 tracker「补充登记·簇2」节〔实证：FEEDBACK_TRACKER.md:1447-1453，既有行零删改〕。新套件 test_r248_elemvisual 19/19〔实证，见 §5〕。缓办：混色 HSV 真机目测（见 §3）。

### c5 分档守卫
- **审计判定**：唯一残留成立——每日挑战局 `mark_map_cleared` 误喂普通分档键（二cs 加难度档时漏的每日守卫）。
- **证据**〔实证〕：`meta_manager.gd:608`（第三参 `p_feed_tiered: bool = true`，缺省保全部旧调用点）、`:620`（`if p_feed_tiered:` 包住分档键写入，maps_cleared 置位+地图族成就桶保留包裹外=通关解锁链不回退）、`:564`（`mark_map_cleared(_run_map, _run_difficulty, not _run_daily)`，与结算侧每日早退分流同源）。
- **复核结论**：簇3 落地；r245_diff_star 套件（含 G7④ 每日不喂分档键+解锁链仍置位）31/31〔实证，见 §5〕。顺带 `:218` 陈旧注释锚改指 REVIVE_INVULN_S=5.0〔簇3 实施申报〕。缓办：na 跨档 alpha 真机目测（见 §3）。

### c9a 性能深挖（本轮运行内编号）
- **审计判定**：四案成立但全部需真机/产品决策，本轮缓办——①闪白窗定格（tick 侧锁存）；②enemy_tex_flash 预热补烤；③BlastStarFx/GroundShockFx/ArcSlash 池化（照 DeathPop 协议）；④SpellRing 收编宿主 tick。
- **证据**：缓办理由=④需先定产品口径「施法者读条中被打死=死亡即爆/死亡取消」（现设计宿主无关引爆，玩家可感行为变化）；③回归需真机深载物步µs 标定（debug_stats.gd:492 物步口径含 message_queue 残差），headless 不可测；①②文件集与本批四簇硬撞。缓解：其最大分配税源（闪白窗逐帧 `_body_tex_spec`）已由 R188⑪ 收编〔实证 enemy.gd:2703-2706〕。
- **复核结论**：缓办有据，下批回归清单已备（见 §3）。

### c9b 逐帧分配扫描（本轮运行内编号）
- **审计判定**：partial——上批三处收口（`_ring_buf`/`_tint_gen`/虚线半径）之后，热路径仍有逐帧分配残留（范围八文件，见头部编排说明）。
- **证据**：处置=簇4 清扫十条收口（落点=R188 纪律其余十条，与上表 R188 行同锚〔实证〕；enemy.gd 侧另由簇1 R188⑪ 覆盖）。
- **复核结论**：本轮收口，零语义变更；既有内容/顶点/混色断言即回归锁（簇4 门禁 8 套件全绿〔簇4 实施申报〕）。

---

## 2. 本轮修复簇落地摘要（上游实施申报，收尾员抽样核实锚点如上）

### 簇1 · 反馈吞没与卡面品质收口（c4①②③④ + c8①②③④ + R188⑪，用户反复点名类最高优先）
- **files**：repo/autoload/event_bus.gd、repo/scripts/entities/player/player.gd、repo/scripts/loop/game_loop.gd、repo/scripts/core/pools/projectile_pool.gd、repo/autoload/debug_stats.gd、repo/scripts/entities/enemy/enemy.gd、repo/scripts/cards/card_generator.gd、repo/scripts/cards/card_select_ui.gd、repo/resources/traits/MEC_HIT_BURST.tres、repo/resources/traits/MEC_PHASE_SYNC.tres、repo/tests/runner/test_r248_feedfix.gd、repo/tests/runner/test_r248_feedfix_cases.gd
- **summary**：簇1 全部 13 项落地完毕（改动只落在独占文件集内）：①c4① graze 掠过反馈——event_bus.gd 新增 signal graze+emit_graze（照既有包装形态）；player.gd take_contact_damage 无敌/死亡早退分支内 0.25s 节流发信号+DebugStats graze_hits（GRAZE_FEEDBACK_CD 常量、_graze_fb_left float 成员在 tick 既有衰减段递减，零数值刀）；game_loop.gd 订阅 graze→_on_graze_feedback：headless 仅计数（graze_fx），有显示时走既有 ParticlePool/ParticleDirector 一次性 AMBIENT 档发射（复用 boot 组装的同一 director，零逐帧分配）。②c4② 敌弹保留配额——projectile_pool.acquire(p_team:=0) 缺省参数保全部旧调用点逐位不变；p_team==1 超软上限时沿 _live_order 插入序 _force_recycle_oldest_of_team(0)（FORCED meta 同硬上限口径）挤掉最老玩家弹后重试一次，腾位失败仍 _register_miss+null+enemy_bullet_dropped 计数；enemy.gd 两处敌弹发射点（_fire_at/_spawn_boss_bullet，含词缀 ring/sniper 经由路径）改 acquire(1)，玩家侧零改动。③c4③ 非 CHASE 精英词缀复活——enemy.gd tick 的 match 块后追独立段（behavior!=CHASE 且词缀非空→硬直停摆口径与 CHASE 同款），RANGED/BLINK 金冠词缀 tick 恢复推进（投放面 enemy_spawner._elite_affix_roll 本就无 behavior 过滤）。④c4④ BossMine 宿主失效——已 arm（_t≥telegraph+arm）时 _done 旗防重入 + _explode(null) 原地引爆一次（爆炸环/接触伤害照走），HazardPool 在宿主已失效时传 host=null 让其走完 life_s（否则首帧自毁无读感）；未 arm 维持静默清。⑤c8④ ELE lv2 白名单泛化——value_lv2 之外扩 dot_ratio_lv2/chain_decay_lv2（同乘 scale）与 chain_targets_lv2（int(round(x×scale)) 计数键），params 深复制防线保留（E-08 不写穿 .tres），spread_radius_lv2/radius_lv2 维持像素口径不缩放。⑥c8① 五死数字卡特例臂——_rarity_desc_mech 追 5 个 id 臂（循 MEC_SHIELD/MEC_KILL_BLAST 先例；运行消费点全部按 id 判定，params 语义键无运行读取方故不加）：HIT_BURST 层1=round(value×scale×100)%/层2=round(value×scale×ratio_lv2×100)%（运行=value×ratio_lv2，任务书速记缺 value 因子，按「卡面=运行值」硬要求实现，白 35%/45% 逐字节回退）；CRITICAL_MASS 5+round(value×scale×2)×（白 7×/蓝 8×/紫 9×/金 10×，=orbit_field 5+value×layers 运行式——任务书「金=7×」与其自给公式矛盾，金按公式=10×、7× 系白档，已在套件按运行值锁定）；FRACTAL 层1=round(value×scale)/层2=maxi(count_lv2,层1+1)（先换层2 锚再换层1 锚防撞串；审计 fixHint 只盖层1 的旧病两段全修）；BOUNCE int(round(value×scale))（修蓝卡显示 +2.8≠运行 3，定向替换保护「反弹谱变×1.4」「≥5 次」）；FUSE_DETONATE 0.5×scale=%.1f/层；MEC_HIT_BURST.tres 卡面泄漏「（用户反馈 2026-08-29…）」清除。⑦c8② 二元卡假尾注——value≈1.0 且 stack_max==1（恰 9 张+PHASE_SYNC）在 _scaled_description 无数字分支改追加「（品质不影响效果）」，card_select_ui.compose_desc_text 按同一字样判同跳过「品质加成 ×N」假话行（单源标记，产品与预热器 desc 同源故预热键天然逐位一致，未动 _roll_rarity 消费序列与 card_desc_prewarm.gd）。⑧c8③ PHASE_SYNC 方案B——.tres 描述去「×2」（改「聚焦爬坡翻倍（15%/s→30%/s，封顶 3.35s 即满）」），运行侧零改动，经 value=1.0/stack_max=1 自动并入尾注抑制。⑨R188⑪ 闪白窗逐帧分配税——新增 _body_kind/_body_angry 成员+_refresh_body_spec() 写点（_sync_visual/_set_volatile_face/_tick_boss/_reset_state 四写点维护，池复用归位 grunt）；_apply_flash p>0 衰减帧改读成员不再每帧 _body_tex_spec() 新建 Array(2)+String；_body_tex_spec boss 前缀判定改 boss1~7 StringName 集合 == 比较。⑩c5 顺带 player.gd 复活注释 3.0s→5.0s（真源 REVIVE_INVULN_S）。⑪新套件 test_r248_feedfix.gd+cases（SceneTree 入口+cases 双文件纪律）60 项断言：graze 节流三态+表现侧锁步、敌弹配额默认路径逐位/挤老弹/无可挤三态、RANGED 精英词缀 ring 释放 8 发、BossMine 已 arm 落 HazardPool+_done 防重入+未 arm 静默清、五卡蓝/金卡面=运行值+白卡逐字节回退、10 张二元卡尾注+compose 判同+数值卡对照、PHASE_SYNC 去×2、ELE lv2 三键+E-08 不写穿+像素键不缩放。测试修红两处（均在本簇文件内收口）：(a) test_pkg0 E-12 恰+1 计数被 player.gd 静态击杀账本 lambda 每帧误计打红（headless 探针实证：单独 load player.gd 该 lambda get_object()=<GDScript>、is_node=false、单帧 delta=1，与 Oct-1 存档后引入的该 lambda 相关）——event_bus.gd _check_node_subscribers 对 Script 本体订阅者豁免（脚本随全局类缓存长生，非 RefCounted 强引用泄漏；RefCounted 实例拦截口径不变），pkg0 复绿 129/129；(b) enemy.gd _apply_flash 满载门块曾处于错误缩进（嵌在 material-if 下/退化为 return 后死码两态），已恢复文档化结构（fullload 门 1 层、FLASH_TEX 与 material-if 同级、R188⑪ 成员读为唯一语义差异），r237_flashtex 35/35、qa_r217_probe 45/45、r217_batchfix 24/24 全绿〔本段除注〔实证〕锚外为簇1 实施申报〕。

### 簇2 · 元素弹体染色收口（c2 三处活口 + W11/W12 缺口登记）
- **files**：repo/scripts/ui/texture_factory.gd、repo/scripts/combat/projectile/projectile_base.gd、repo/scripts/combat/weapon/melee/flying_sword_weapon.gd、repo/scripts/combat/weapon/melee/ground_axe_weapon.gd、repo/FEEDBACK_TRACKER.md、repo/tests/runner/test_r248_elemvisual.gd、repo/tests/runner/r248_elemvisual_cases.gd
- **summary**：簇2 三处活口全部收口，9 套件全绿（含新回归 19/19）。【c2-① W6/W7 导弹染色】texture_factory.gd:1197 missile_tex 参数化 missile_tex(p_fill: Color = Color(0.78, 0.84, 0.95))——缺省用原弹体浅灰蓝字面（非 PopPalette.INK 深藏青，保 KIN 全族原观感）；缓存键改 "missile_tex_%s" % p_fill.to_html()，Lambda 内 body_col := p_fill，nose/fin/尾焰色未动；旧无色键退役前已 grep 证实全库消费点仅 projectile_base.gd 一处、game_loop.gd 无预烤键。projectile_base.gd:1598 接线 missile_tex(_plain_fill() if element != KIN else Color(0.78,0.84,0.95))，注释写明 KIN 不能直接二参的原因（_plain_fill 对 KIN 返 PLAYER≠原灰蓝）。【c2-② 镜面弹体】projectile_base.gd:1618 _VIS_MIRROR 改 mirror_bead(_plain_fill() if element != KIN else PopPalette.PLAYER, TEX_SIZE)，TextureFactory 零改动（mirror_bead(p_fill,p_size) 带色键与非 PLAYER 混冰青现成）；旧注释已改写为镜面内壳=is_mirror_image BallisticWeapon 副本、弹 element 自带棱镜栈元素、弹侧自读单源的新口径；R187 禁金染天然保持（_plain_fill 永不返 GOLD）。【c2-③ W11/W12 飞剑/掷斧】flying_sword_weapon.gd:326 flight_tex(p_transcended, p_fill = PopPalette.PLAYER)、ground_axe_weapon.gd:498 flight_tex(p_transcended, p_fill = FLIGHT_STEEL)（新增类级 const FLIGHT_STEEL=Color(0.62,0.68,0.78)，缺省参与质变门同源防漂移）；本地缓存键由 "t2"/"base" 三元化为 "%s|%s" % [键, p_fill.to_html()]，且质变有效性 tainted = p_transcended and p_fill==缺省——元素染时 t2 键归并 base（同色 t2/base 共享同贴图实例，桶合批友好，并使「FIRE+t2 不落鎏金/岩纹」可做同实例最强断言）；剑/斧刃色 var 改挂 p_fill；鎏金/土岩岩纹两处质变分支均改挂 tainted=仅 KIN 未染时生效（元素优先，二cm/R241② 口径）。projectile_base.gd:1686 _flight_form_tex 接线：元素附魔传 _host_transcended()+_plain_fill()，KIN 一参回落保原蓝/原钢（避免 _plain_fill 对 KIN 返 PLAYER 烤出蓝斧破 r243_base 锚）。【tracker 只增登记】FEEDBACK_TRACKER.md 1445→1453 行，末尾追加「补充登记·簇2」节 3 条（W6/W7 导弹←R211 报告遗留#3、镜面银白←遗留#5、R243 flight_tex 无色参漏登记项），附日期与落点行号（行号按改动后实 grep 校正），状态列标注归并留收尾员；既有行零删改〔实证：现 :1447-1453〕。【新回归套件】test_r248_elemvisual.gd + r248_elemvisual_cases.gd 双文件（SceneTree 入口 + RefCounted cases，纯 static 贴图断言免装配 GameLoop）19 断言：M1 导弹（FIRE≠缺省键互异/各白实例/缺省像素=原灰蓝 body_col/FIRE 像素=表色）、R1 镜面（FIRE 同色同实例/与 KIN 珠实例互异/KIN 珠心=PLAYER.lerp(WHITE,0.62) 银白锚/FIRE 珠心=表色混冰青）、F1 剑与 F2 斧（双参 FIRE≠缺省/一参缺省调用同实例/FIRE+t2 与 FIRE 基础版同实例=元素优先不落鎏金岩纹/≠质变实例/KIN 两态互异保持）。像素断言容差 PX_EPS=0.004——首跑 0.002 容差红 3 项，实测定位 set_pixel 量化为截断（0.78→198/255），误差最大近 1/255=0.00392，修容差后全绿。

### 簇3 · 每日局分档守卫（c5 唯一残留：每日挑战误喂分档键）
- **files**：repo/scripts/meta/meta_manager.gd、repo/tests/runner/r245_diff_star_cases.gd
- **summary**：c5-① mark_map_cleared 加第三参 p_feed_tiered: bool = true，分档键写入块以 if p_feed_tiered: 包裹；maps_cleared 置位+地图族成就桶 _check_achievements_of 保留包裹外（通关解锁链/角色 unlock_map 口径不回退）；changed/_save 照旧（仅 maps_cleared 变更的每日局也落盘）。c5-② _on_wave_cleared 改 mark_map_cleared(_run_map, _run_difficulty, not _run_daily)，与结算侧每日早退分流同源，修掉二cs 加难度档时漏的每日局守卫（每日达线不再误写普通分档键）〔实证 :564/:608/:620〕。c5-③ r245_diff_star_cases.gd G7 尾部追加场景④：清基线 → set_run_map(m0)/set_run_difficulty(0)/set_run_daily(true) → _on_wave_cleared(final_wave) → 断言 not is_map_cleared_at(m0,0) 且 not is_map_cleared_at(m0,1)（分档键不喂）+ maps_cleared.has(String(m0))（解锁链仍置位）→ set_run_daily(false) 还原；夹具 _snapshot_meta/_restore_meta 原样覆盖，零新基建。c5-④ 陈旧注释锚点改「REVIVE_INVULN_S=5.0（player.gd:224）」——已核 player.gd:224 真值 const REVIVE_INVULN_S := 5.0；desc 本体零改。调用点影响面实测：全仓 grep mark_map_cleared 共生产 1 处（已改）+ 测试 14 处（均 1-2 参走缺省 true 路径逐位不变）——任务书说测试 9 处，实测 14 处，缺省参数下同样零破坏。

### 簇4 · 逐帧分配清扫（R188 纪律其余十条 + c9b 处置，零语义变更）
- **files**：repo/scripts/entities/player/weapon_orbit_avatars.gd、repo/scripts/combat/weapon/weapon_base.gd、repo/scripts/ui/hud.gd、repo/scripts/combat/weapon/melee/arc_slash.gd、repo/scripts/gamefeel/elemental_fx_layer.gd
- **summary**：R188 纪律其余十条逐帧分配清扫全部落地（只动独占文件集 5 个文件，零语义变更）：①weapon_orbit_avatars._entries_of 改成员 _entries_buf clear+append 原地重建；②weapon_base.blend_element_color 加实例级 _blend_gen/_blend_cache 世代缓存（gen 取 trait_stack.runtime_generation，守卫 is TraitStack 判型——桩走 _blend_compute 原体不写缓存，bool(null) 纪律合规；setup 复位 -1 防复用件新旧世代撞号吐陈旧色）；③weapon_orbit_avatars 删 StringName(String(data.id)) 双转换直用 wb.data.id（id 原生 StringName）＋删 String(d.id) 中转改 d.id in RITUAL_IDS（跨型哈希命中经临时探针实证后已删探针）；③④新增 _slot_cache 槽位解析缓存 {w,t2,is_blade,icon,src_id} 仅实例/质变位变化才重解析（is_blade 严格保持原 W9 前缀单口径）；⑤hud._tb_settle 候选改成员 _tb_cand_buf 原地重建（keys() 中转组+assign 双分配消除）；⑥TB HP 文本量化显示缓存 _tb_hp_q/_tb_mh_q/_tb_hp_text_last + static _tb_num_quantized（量化相等即文本相等）；⑦FPS 行改 _fps_last+diag_changed 双锚（诊断 15 帧节流段变化帧强制刷防吞）；⑧arc_slash._judge_arc/_nullify_enemy_bullets 候选拷贝改成员 _cand_buf/_bullet_buf clear+append_array（query_arc 返回内部缓冲不得跨查询持有——R5 别名复制契约保持）；⑨_blade_polygon 按 (style×transcended) 四键 static _poly_cache（PackedVector2Array 值语义 COW 读回口不动）、tip 弧光改成员 _tip_buf resize+下标赋值、刃口/刀背/裂纹/护手/柄顶点表升 static _blade_lines(w) 缓存（w 恰三档，draw_* 拷贝进 canvas item 共享安全）；⑩elemental_fx_layer 每雷槽 pts 缓冲入 _bolts 条目复用，_layout_bolt resize(BOLT_SEGMENTS+1)+下标赋值（core/glow.points 赋值仍引擎侧 COW 拷贝不动），注释改如实描述。回归门禁 8 套件全跑全绿（exit 0，逐套 PASS/FAIL=0，日志零 SCRIPT ERROR）：test_rcu_faqi 32/32、test_weapon_orbit 49/49、test_r243_prime 65/65、test_r243_fengren 31/31、test_r243_base 46/46、test_r243_melee 47/47、test_r195_layout 527/527、test_r198_element_fx 36/36〔簇4 实施申报，收尾员未逐套复跑〕。无新增断言义务——既有内容/顶点/混色断言即回归锁，全部原样通过。

---

## 3. 缓办清单（原样归档，均为下批输入）

1. **【c9a 全部四案（性能·需真机/产品决策，留待下批）】**①闪白窗定格（tick 侧锁存，enemy.gd 闪白窗中段渐变消失换 3 次 reparent/mirror 换键省除）②enemy_tex_flash 预热补烤（game_loop.gd 队列+四处兜底口）③BlastStarFx/GroundShockFx/ArcSlash 池化（照 DeathPop 协议）④SpellRing 收编宿主 tick——跳过理由：(a) 文件集与本批四簇硬撞；(b) ④需先定产品口径「施法者读条中被打死=死亡即爆/死亡取消」（现设计宿主无关引爆，与 R244④ 同族玩家可感行为变化）；(c) 回归需真机深载物步µs 标定（debug_stats.gd:492 物步口径含 message_queue 残差），headless 不可测。缓解：其最大分配税源（闪白窗逐帧 _body_tex_spec）已由簇1 R188⑪ 收编。下批回归清单备用：qa_r217_probe+r213_fullload+qa_r214_extra+r202_g3+r225+r237_flashtex+r217_batchfix+真机物步µs。
2. **【c4① 数值刀 contact_tick 0.6→0.35】**game_config.gd:21 + balance_tables.tres 同步——须过数值评审并重校无敌窗时序锚（pkg2_cases.gd:304、r202_g3_enemyhot_cases.gd:295-302；data_validator.gd:400 仅要求>0，无自动护栏）。本批只落簇1 graze 信号反馈（零数值风险首选方案）。
3. **【c4⑥ 遗物 value 机制】**relic_data.gd 无 value、relic_handler.gd 按 id 丢品质、18 件统一金——方案 A（统一金不 roll，≈0.5 天）vs 方案 B（RelicData 加 value+激活链传品质+18 件定梯，≈3-5 天另立项）待用户裁定后另批落地。
4. **【c4⑦ 多武器护盾聚合共享单盾 vs 每武器独立计时】**player.gd 单全局 shield_interval/timer/ready + weapon_base.gd Σ层数聚合——与用户预期「独立计时」不符，语义裁定挂起，报用户拍板后再动（R238 已修面勿回退）。
5. **【c5 na·跨档 alpha 回落】**pickup.gd 档内归一（跨档升档 alpha 回落≈0.5）+三级量化——纯观感 headless 不可测，维持待真机目测；不达标再改 xp_tier_alpha 全局单调。
6. **【c2 na·混色 HSV 真机目测】**火+冰=饱和橙（weapon_base.gd 门限/保底）维持待真机验收；不达标再调门限。

---

## 4. QA 与回归口径

- **QA heal**：heal r1 全部修复，无 heal 残留〔上游申报〕。其中测试修红两处的收口（event_bus Script 本体订阅者豁免、enemy.gd _apply_flash 满载门缩进恢复）详见 §2 簇1 summary ⑪。
- **回归**：18/18 套件全绿〔上游申报，收尾员未逐套复跑；套件清单上游未附，无法逐套对名〕。
- **收尾员本轮实跑**（命令＝`"E:/Code/Agent/Infinite-Fission/android_export/Godot_v4.3-stable_win64.exe" --headless --path . -s tests/runner/<套件>.gd`，cwd=repo，2026-10-09）：

| # | 套件 | 结果 | 关联 |
|---|---|---|---|
| 1 | test_r248_feedfix | 汇总：PASS 60 / FAIL 0（共 60 项），exit 0 | 簇1（c4/c8/R188⑪） |
| 2 | test_r248_elemvisual | 汇总：PASS 19 / FAIL 0（共 19 项），exit 0 | 簇2（c2 三活口） |
| 3 | test_r245_diff_star | 汇总：PASS 31 / FAIL 0（共 31 项），exit 0 | 簇3（G7④ 每日分档守卫） |

- 注：套件 stdout 末尾常见 Godot 资源清理行（CanvasItem RID leaked / resources still in use at exit），系引擎退出清理噪音，与本仓历轮 QA 判绿口径相同，不影响 exit 0 判定。

---

## 5. tracker 登记落点

- `FEEDBACK_TRACKER.md` 末尾追加「## 二cw、频繁问题复审与错误/性能再规划（2026-10-09 · workflow-flash）」节（分隔线 :1455、节标题 :1457、表格 :1459-1467，紧随 :1447-1453「补充登记·簇2」节之后；全文件 1453→1467 行），表格列（# | 项 | 判定 | 证据 | 状态），逐类一行（c4/c8/R188/c2/c5/c9a/c9b 共 7 行=审计判定+本轮处置）；既有行零删改〔实证：追加前对既有 1453 行取 md5=533326fef74a9ea935ae768502c4201c，追加后重取同值；全文件 UTF-8 解码零替换符〕。
- 遗留注记：「补充登记·簇2」三行状态列标注「归并留收尾员」，因本轮任务硬约束「不动任何既有行」未归并，留下一轮 tracker 触碰时处理。

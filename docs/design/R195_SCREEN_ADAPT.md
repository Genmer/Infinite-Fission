# R195 整案：商店刷新钮隐藏 · 激光穿透 · 多尺寸屏适配

> 状态：三方向定案已由统合仲裁收敛为整案（三方向均为 **implement**，无 noop 项）。
> 套件名（tracker 流程登记）：**r195_adapt**。
> 实现分组 5 组，文件所有权互斥，见 §5 所有权表。
> 行号漂移警示：本文所引行号为仲裁会话静态读码快照，实现时**一律按内容定位**（已知漂移例：
> tracker:395 引 shop_ui.gd:497 现为 `_make_ware_row`；laser_beam.gd `sub_beam`/`overlap_fallback`
> 字段实际在 :42/:45；data_validator.gd 真实路径为 `scripts/core/data/data_validator.gd`）。

---

## 0. 总览

| 方向 | 键 | verdict | 一句话定案 |
|---|---|---|---|
| 商店刷新钮 | shop_btn | implement | 刷新钮不可刷时 `visible=false` 原位隐藏（留空），三口径合一为 `can_refresh()` 单源谓词；disabled 与 visible 不并存 |
| 激光穿透 | laser | implement | 激光多目标贯穿（预算口径 N=pierce），AFF_PIERCE 开形态门，无逐目标衰减，pierce_index 弹体同式，主束门三重 |
| 屏幕适配 | adapt | implement | aspect keep→expand + 运行时超限回落钳制（>2.34 回 KEEP）+ 全面板锚定恒等校准 + 安全区 helper + 七尺寸×七态验收矩阵 |

三方向互不冲突；唯一的文件级交叠是 `shop_ui.gd`（商店组独占，同时承担刷新钮隐藏与该面板锚定适配）
与测试文件（测试统包组独占），见 §4。

---

## 1. 商店刷新钮隐藏契约（shop_btn｜implement）

### 1.1 裁决一：`can_refresh()` 谓词签名

`shop_ui.gd` 谓词区（`has_stock()` 之后、`_ware_stocked` 之前）新增：

```gdscript
func can_refresh() -> bool:
	return _player != null \
		and int(_player.get("gold")) >= refresh_cost() \
		and has_stock()
```

- 注释写明 **R195：三口径合一**（与 R71/R188-C/R189 置灰口径逐位同源）、**纯只读**
  （不扣金、不重掷、无副作用）、**黑市/战前补给共用**（零 `_pre_boss` 分支）。
- `_player != null` 相对 `has_stock()` 内部 null 兜底是显式冗余，**保留自文档化**
  （禁止以此为由再精简）。
- `can_refresh` 全仓零命中（本仲裁 grep 实证）＝净新增名，无撞名风险。

### 1.2 裁决二：可见性联动点

- `_refresh()` 内原 disabled 三行赋值（shop_ui.gd:492-494，全仓唯一 `refresh_btn.disabled`
  写点，grep 实证）**整段替换**为：

  ```gdscript
  refresh_btn.visible = can_refresh()
  ```

- disabled 写点**删净**：全仓不得再出现任何 `refresh_btn.disabled`（防双可用口径漂移，
  禁止「既灰又藏」混合态）。
- :484-491 的 R71/R188-C/R189 注释块**改写续写 R195 演进**（置灰→隐藏；tracker:395 用户
  原话「不给刷就别显示」）。
- 价签 :483「刷新货架 (%d)」**保持无条件刷新**——隐藏期也保新价，重显不闪旧价。
- 可见性随 `_refresh()` 三入口（open / _buy / _on_refresh_pressed）全状态覆盖；
  黑市/战前补给两态构造性一致（两开店源全汇 `game_loop.gd:394 _on_shop_requested`，
  `_pre_boss` 仅标题分叉）。

### 1.3 裁决三：版面取舍＝原位隐藏留空

- **出击钮 868 不动，上移案否决。** 依据：card 是 Panel（非容器）全子节点绝对定位零
  reflow，`visible=false` 留空天然安全；上移须把出击钮坐标变成 `_refresh()` 状态依赖写入
  ——开店期金币单调不增（金写点仅 `_buy`/刷新两处且均尾调 `_refresh()`），首次购买跌破
  刷新价即确定性瞬移 66px，违背 R194 固定触控目标纪律。
- 留空后 scroll 底边 816→出击钮顶 868 之间 52px 为卡底背景空缺，安静可接受；该带输入
  落空无害（root/dim/card `mouse_filter` IGNORE）。
- **几何三件套全部原值**：scroll 576×700@(28,116)、刷新钮 210×56@(211,802)（仅 visible
  翻转，position/size 不变）、出击钮 210×60@(211,868)。R194_MOBILE_PLAY.md §4.2 几何契约
  不破。

### 1.4 裁决四：`_on_refresh_pressed` 金量门不升级

:393-394 的 gold-only 守卫**逐字保留**，不加 has_stock 门。理由：

1. 四处测试直调真链依赖现语义（market_supply:158 / r188_idle:246 的重掷重试环中途一次
   全枯竭即按压空转→断言概率性红；verify:1186 刷新扣费、verify:3190 无副作用同押现语义）；
2. 按钮隐藏后玩家 UI 路径到不了该处理器，货量复验零用户收益纯风险；
3. R195 是表现层需求，不得夹带行为语义变更。

### 1.5 裁决五：断言改动清单（唯一必改＋新增）

- **必改**：`verify_feedback_cases.gd:3188` 改断 `not refresh_btn.visible`，`_check` 文案
  同步（如「R71→R195：金币不足刷新按钮隐藏」）；:3184 注释注明 R195 有意契约变更
  （置灰→隐藏）。同函数 :3190-3192 无副作用断言与 :1186-1187 刷新扣费断言**原样保留**。
- **新增（就地扩展 `_test_r71_shop_fallback`，:3194 close 之前，不建新套件）**：
  - a) 0 金黑市→`not visible`（即 :3188 改造点）；
  - b) 复显双向锁：回金 ≥refresh_cost()＋`_refresh()`→`visible`——若已买走 weapon_up 行
    后货架可能 `has_stock()==false`，用确定性强保证：关店重开（R188-1 开店 buyable≥1 兜底
    保证有货）或回金前 set hp 低于上限激活维修包行，两法任一；
  - c) 双态一致：set 金<refresh_cost→`shop.open(player, wave, true)`→断 `not visible` 且
    `_title.text=="战前补给"`（谓词无 `_pre_boss` 分支的实证断言）；
  - d) 新断言若扫 `_list` 行区须带 `is_queued_for_deletion` 防护（r194:444-446 先例）。
- **零改**：r194_mobile_cases.gd:438-440 几何③逐字保留（可补一行 R195 注释说明钮可隐藏）；
  market/r188/history/p1_polish 全不动。

### 1.6 红线（零改动清单）

`refresh_cost()` 公式与 open() 归零；`_on_refresh_pressed` 金量门；价签 :483 无条件刷新；
三入口 `_refresh()` 调用不动；几何三件套原值；黑市/战前补给禁止 `_pre_boss` 分支；
战斗逻辑零改动；R188 性能红线不触及（`_refresh()` 内一次布尔比较，非每帧路径）；价签
文案格式「刷新货架 (%d)」保持现源（无测试断言、不入 GameConst，禁止顺手重构文案管线）。

### 1.7 知情取舍（仲裁显式确认接受）

- 金不足期按钮（唯一读价点 :483）随钮同隐，玩家失去 15×1.5ⁿ 攒钱目标信号——置灰派保留
  常驻价签正为此；用户已点名隐藏（tracker:395），评审若翻案改回置灰零阻力（verify:3188
  本就断 disabled）。
- 残留低风险：autoload/道具侧若存在开店态金币回调则可见性陈旧至下次 `_refresh` 自愈
  ——未审计到实例，接受。
- 未运行声明：shop_btn 仲裁会话无 godot 二进制（其环境 PATH 无 godot；本仓二进制实际在
  `tools/Godot_v4.3-stable_win64_console.exe`，统合席已确认存在），该方向结论为静态
  grep/read；「find_child 命中隐藏节点」「隐藏不破 r194 几何」为 Godot 4 引擎语义静态
  判断，实现落地后必须以 headless 套件实证，不得以仲裁背书替代。

---

## 2. 激光穿透语义与探针（laser｜implement）

### 2.0 定性（真断链，三层矛盾全修）

- 引擎层 `laser_beam.gd` 全链单目标：`tick` 只结算 `_first_hit` 的单 best_t，
  `_tick_settle` 每拍只落该目标；束路径从不写 `ctx.pierce_index`（damage_context.gd 缺省 0）
  → 可上架的 SYN_PIERCE_EVO（condition_id=4 PIERCE_INDEX_GE min 2）在激光上贡献恒 0＝
  真「花钱买寂寞」。
- W4/W5 L 表 pierce=1 是激光侧零消费的死数据（全仓唯一消费点 ballistic_weapon.gd）。
- 面板恒显「穿透 0 名」（pause_overlay.gd:568 恒渲染该行，:566 `has_method("_pierce_count")`
  对 LaserWeapon 落空）。数据说 1、UI 说 0、实战锁第一敌。

### 2.1 仲裁一：穿透语义＝预算口径，贯穿数 N=pierce（否决 1+pierce）

```
N = LaserWeapon._pierce_count()
  = maxi(int(get_stat(&"pierce")) + int(round(aggregate_panel().get("add_pierce", 0.0))), 0)
```

逐字镜像 ballistic_weapon.gd `_pierce_count()`。证据：弹体 `pierce_left` 即可命中总数
（递减耗尽回收；pkg2_cases 锁 pierce=3→恰 3 命中后回收）；weapon_level_stats 夹具默认
pierce=1——预算口径下全部合成夹具每拍仍恰 1 目标零扰动（pkg3 已知数 955.2/16 settles/
8 popups 不动，仲裁席亲跑基线 PASS 128/FAIL 0）。1+pierce 会让合成夹具静默多打 1 目标且
面板「穿透 1 名」实际打 2（跨形态语义分裂），四讨论员共识否决。探针五的 SPEC-1
（hit=1+pierce=3）按预算口径改写为 hit=N。

### 2.2 仲裁二：修复可见性＝开 AFF_PIERCE 形态门（否决改 L 表）

- L 表 pierce 保持 1：改 1→2 是 W4/W5 对群 DPS 近翻倍的平衡变更（.tres 逐级 DPS 预算
  注释均只含 tick_atk×rof 无穿透因子），不得由 bug 修复方向顺手带走，留给平衡评审。
- 可见性走数据半边：`AFF_PIERCE.tres` `required_forms [0]→[0,1]`（params 内），激光可购
  穿透（stack_max=2、value=1.45 经 F3 衰减聚合，add_pierce 进入 `_pierce_count` 与弹体
  同式）；description 同步改形态中立（现文案「子弹命中敌人后仍不消失」对激光不真；真源
  即 .tres description 字段，UI 直读无手抄）。
- 附带收益：card_generator `_pick_attach_target`「全不适配退主武器不复查门」的旁路对本
  词条变为门内合法——泄漏被消费面修复中和。旁路本身收口不在本方向（货架卡携带已过门
  target、黑市兜底宿主复验门、存档恢复仅重挂已持词条，无实锤活玩家路径）。

### 2.3 仲裁三：衰减＝无逐目标衰减（f=1）

弹体真口径：每跳同 base_atk，只扣计数。逐目标增减伤只走现成
`pierce_index→pierce_dmg` 池（SYN_PIERCE_EVO value×(pierce_index−1)，cap 1.6，
data_validator 白名单在册）。否决 ×0.6^(n-1) 案：其引的三处 0.6 是折射折价/感电连锁/
AOE 边缘 falloff，无一是「同一发贯穿多目标」同构；引入系数需 laser 段新键过 validator
闭合域且无数值锚。→ **零新数据键、零 validator 改动**。

### 2.4 仲裁四：pierce_index 口径＝弹体同式复制

第 k 个目标（1 基）`ctx.pierce_index = k+1`（首目标=2）、`hit_flags |= GameConst.HIT_AFTER_PIERCE`
——镜像 projectile_base 的 `_pierce_hits+=1` 先于 ctx / `=_pierce_hits+1` 写入序。
`HIT_AFTER_PIERCE` 全仓零消费者（仅定义＋弹体写入），写入纯为口径统一。
效果：SYN_PIERCE_EVO 在激光首目标即贡献 value×(2−1)＝+0.2/跳——与弹体同紫卡首跳同数值，
杜绝跨形态分裂。

### 2.5 仲裁五：主束门与折射经济

- **仅主束吃穿透**，门＝`depth == 0 and not sub_beam and not overlap_fallback`
  （`is_refraction` 蕴含于 depth==0，可加作第四重防御）。
- 实证：`_spawn_beam` 全仓恰 3 个调用点——try_fire 主束、`_refresh_sub_beams` 副束
  （depth 恒 0 ＋ sub_beam:true，单 depth 门必漏；target_uid==0 门被否：fan 副束
  target=0）、`_on_beam_refracted` 折射（depth≥1）。
- 折射分叉仍仅由每束首个（最近）目标首次命中触发一次（`_on_hit_target` 现语义不动：仅
  新目标 refract），贯穿目标不触发新分叉，防 W5 分叉×穿透连乘。
- 贯穿目标照常经 `_on_hit_target` 入 `_hit_exclusions`（语义＝已命中目标，防子束回烧；
  子束寻的读它）——与「`_first_hit` 候选选择继续不查排除集」（主束锁定持续照射语义保留）
  不冲突：入集只影响子束寻的，主束选择不读它。

### 2.6 仲裁六：灼焦/跳字/表现归属

- 灼焦 B 案：贯穿目标全量同叠（`_scorch_pool` 按 target_uid 键控天然多目标；重叠回退束
  「不叠灼焦不附着」既有定案不破——其本不吃穿透）。
- 逐目标结算**必须复用 `_settle_one_tick` 单口**：15Hz/目标跳字闸（popup_due 按 uid 键）、
  emit_beam_impact 逐目标迸裂、ELE 附着、relic 注入自动逐目标生效，**禁旁路另起简化结算**。
- 表现：end_pos＝末贯穿目标（t 最大者）位置，无命中画满 beam_length（现行为）；W4 束长
  560 < 逻辑屏 720×1280 不穿屏；共线中间目标被两点线几何穿过（`_sync_line` 不改结构）；
  超程（t>beam_length）恒不命中。跳字逐目标经现管道（每次结算→PopupManager 按 target_uid
  分桶），零新机制。

### 2.7 实现要点（实现组照做）

1. `laser_beam.gd`：新增 `var pierce:int=1`，spawn() 读 `p_params.get("pierce",1)`，
   `_reset_state` 归 1；`_first_hit` 扩为 `_hits_along_ray(dir, budget)->Array[Node2D]`
   按 t 升序（判定式逐字保留：dead 短路 / t∈[0,beam_length] / perp≤half_w+hitbox_r）；
   tick 内 budget＝pierce if 主束门 else 1；每拍（beat）对选中列表逐目标
   `_on_hit_target`＋结算（选中一次算定，同拍内前目标死亡不移除后目标）；`last_hit_uid`
   仅随首目标写（副束单目标行为不变——r187「主束锁定最近敌」与 cd_pace R91 聚焦换目标
   契约是硬红线）；tick 内候选数组复用防每帧分配（R188）。
2. `laser_weapon.gd`：新增 `_pierce_count()`（逐字镜像 ballistic）；`_spawn_beam` spawn
   字典传 pierce（主束＝`_pierce_count()`，副束/折射传 1）；主束每拍回写
   `beam.pierce = _pierce_count()`（仿 R191 tick_atk 逐拍回写先例——运行中买卡即时生效）。
3. `pause_overlay` 零改动（has_method 守卫自动转正）。
4. 平衡非目标：L 表 1→2 明确不做。

### 2.8 探针设计（headless 自动化，S1-S9）

新建 `tests/runner/r195_laser_pierce_cases.gd` ＋ `test_r195_laser_pierce.gd`，直驱范式
沿用 pkg3_cases（weapon(100,640) 沿 +X，E1/E2/E3=(260/420/580,640) 同轴在
beam_length=560 内，E4=(700,640) t=600 超程对照，beam.tick(0.26) 节拍）。断言（预算口径
SPEC）：

| # | 断言 |
|---|---|
| S1 | 基线零位移——无词条 hit=1 仅 E1 结算，E2/E3/E4 满血、束端=E1 |
| S2 | 挂 AFF_PIERCE（N=2）→ E1+E2 结算、E3/E4 满血；N=3 → E1..E3、E4 恒满血 |
| S3 | 无衰减——N=2 时 E1/E2 同拍单跳伤害相等 |
| S4 | SYN 激活——挂 SYN_PIERCE_EVO 后 E1 单跳 ×(1+value×1)、E2 ×(1+value×2)（pierce_index=2/3，cap 1.6），与弹体同式 |
| S5 | 灼焦——N=2 持续照射 E1/E2 各自 scorch_layers_of>0、E3=0 |
| S6 | 束端点==末贯穿目标（Line2D 末点几何断言） |
| S7 | 副束门——W4+MEC_SPLIT_PRISM 副束（depth 0＋sub_beam）同列仍只结算其锁定 1 目标 |
| S8 | 折射——W5 主束 N≥2 分叉数不变（仅首目标触发一次）且贯穿目标 ∈ hit_exclusions() |
| S9 | 契约——last_hit_uid==E1、`_pierce_count()==get_stat+round(add_pierce)`、面板行非 0 |

### 2.9 性能/纪律

- R188：主束 N 上界＝1+round(add_pierce)（AFF_PIERCE 满层 F3 衰减聚合下 N≤4），副束不吃
  穿透无乘法；逐目标全结算链线性有界放大，tick 路径禁每帧分配。
- 显示底线：束端＝末目标恒 ≤beam_length<1280 不穿屏；逻辑域 720×1280 与 data_validator
  fatal 不动。
- 本批有意变更契约（R195 注释标注）：①激光面板穿透列 0→真值；②SYN_PIERCE_EVO 激光上
  0→+0.2/跳起；③AFF_PIERCE 激光可上架；④既有用例若断言「AFF_PIERCE 不上激光/面板恒 0」
  须 R195 注记而非放宽删除。
- 未做声明：仲裁席只亲跑了 test_pkg3 基线（PASS 128/FAIL 0）；其余套件回归、探针实现与
  执行属实现组职责（仓外探针 qa_laser5_pierce_probe.gd 可作夹具参考，其 SPEC-1 期望值须
  按预算口径改写）。

---

## 3. 多尺寸屏适配（adapt｜implement）

### 3.0 仲裁前提（全部逐条实读/实跑复核）

- project.godot:24-29＝viewport 720×1280 ＋ override 540×960 ＋ stretch canvas_items ＋
  aspect keep（统合席本席实读复核一致）——黑边根因成立。
- data_validator.gd（`scripts/core/data/data_validator.gd:369-370`）＝`res_logic !=
  Vector2i(720,1280)` 即 fatal——逻辑域钉死不许动。
- 零视口读取（scripts+autoload grep）：仅 game_loop set_input_as_handled、
  meta_manager/run_save 的 `DisplayServer.get_name`（headless 存档路径），纯表现层前提成立。
- spawn/钳制：enemy_spawner 只读 res_logic（顶 y=-40 / 左 x=-40 / 右 x=760，SPAWN_OFFSCREEN=40
  注释「配合入场渐显」）；player 钳制只读 res_logic；相机＝res_logic×0.5。
- 基线：`tools/Godot_v4.3-stable_win64_console.exe --headless --path repo -s
  tests/runner/test_r194_mobile.gd` → 「验收汇总：89/89 通过」（适配席实跑；统合席本批
  复跑结果见 §8）。

### 3.1 stretch 定案（本席自跑探针实证，官方 4.3-stable headless）

**主案＝aspect keep→expand（project.godot `window/stretch/aspect`）＋ 运行时超限回落钳制
＋ KEEP 永久回退分支。**

实跑数据：keep@720×1680→vis=(720,1280) origin(0,200)（现状黑边）；同窗运行时切
EXPAND→vis=(720,1680) origin(0,0)（同帧级切换可行、可逆）；EXPAND 矩阵：
720×{1280,1440,1560,1600,1680}→vis 同高 origin(0,0) 满屏、960×1280 平板→vis=(960,1280)
横向满屏、540×960 桌面→vis=(720,1280) scale 0.75 origin(0,0)（**EXPAND≡KEEP，桌面零
影响**）；720×1800(2.5:1)→vis=(720,1800) 仍延伸；KEEP 回落@720×1800→vis=(720,1280)
origin(0,260) 居中黑边；IGNORE@720×1560→ft.scale=(1,1.21875) 各向异性变形实证禁用；
FULL_RECT 根 Control 全程同步 vis。

三裁定：

- a) **KEEP_WIDTH 否决为主案**——探针实证 keep_width@720×1600→vis=(720,1600) 与 EXPAND
  全同（竖屏 UI 悬空分毫未解），仅 960×1280→vis=(720,1280) origin(120,0) 把平板从满屏
  变左右黑边，是产品降级不是省工捷径。
- b) **超限阈值＝窗口高宽比 >2.34 回落 KEEP**（21:9=1680/720≈2.3333 整档留 EXPAND；
  >21:9 极端长屏回落居中黑边＝「最次上下黑边」底线）。阈值以 game_loop 内常量钉死，
  **不设新设置键**（避免设置面扩散；回退＝project.godot 单行改回 keep）。
- c) IGNORE 与 INTEGER 两档写死禁用（前者变形、后者 540×960 画布超窗裁切）。

回退链：expand 主案→任意时刻 project.godot 改回 keep＝现状黑边（单行整体回退），钳制
函数本身 keep 下自动不触发。

### 3.2 R5 口径裁决（spawn 不入设计域）

断言口径＝**spawn 点 ∉ res_logic 域 [0,720]×[0,1280]**。实证恒真：spawn 全由 res_logic
派生，任何视口尺寸下设计域断言不变绿→红。扩轴可见域内的渐显入场（20:9 下世界 y∈[-160,1440]
可见 spawn y=-40）裁定为合规过渡行为：SPAWN_OFFSCREEN 注释自证渐显设计，加深出生点＝敌人
入场节奏变化＝玩法改动（违反战斗零改动红线），spawn 读视口＝破坏确定性红线——两路都禁，
故唯一自洽口径就是收窄。矩阵 R5 按设计域断言，不设豁免条款、不改 enemy_spawner。

### 3.3 逐面板锚定分区表

改造纪律：**偏移一律按 720×1280 位恒等校准＝offset=现值−锚点设计位，父相对子件零改动
→ r188/r191/r194 默认窗断言值逐位不变**；弹窗卡竖直中心非 640 的以现位为准保恒等。

| # | 文件 | 元素（现位） | 锚定方案 |
|---|---|---|---|
| 1 | hud.gd（根 FULL_RECT :942 不动） | HP(24,24)340×30、击杀(24,92)、计时(184,92)、护盾(306,92)、金币(464,92)、Lv(356,60)、TargetBar(TB_POS_Y 136/Boss 让位 190，常量 :126-128) | 顶带左上锚 |
| 2 | hud.gd | 波次徽章(598,16)106×106、暂停(514,26)72×72、AUTO(644,126)56×64 | 顶带右上锚（offset_right=720−右沿：徽章16/暂停134/AUTO20） |
| 3 | hud.gd | 构筑(24,1124)252×132、技能(610,1112)86×86 | 底带下锚（offset_bottom=1280−底沿：构筑24/技能82） |
| 4 | hud.gd | BossBanner 720×46@y210、WaveToast 720×44@y392、StateLabel 720×44@y212、ReviveBanner 720×52@y316 | 全宽标签拉伸锚（anchor_l=0/anchor_r=1，y 不变） |
| 5 | hud.gd | hover 钳制 :302-303、toast 重定位 :1331（每次 _show_toast 重设 720 宽） | 运行期硬编码活化＝改 visible_rect 界/活宽 |
| 6 | menu_screen.gd（根 :96/底色 :104/云 :107-110 不动） | logo/副标/公告行/name_tag/footer | 全宽拉伸锚，footer 另下锚（offset_bottom=44） |
| 7 | menu_screen.gd | 大厅卡(36,96)648×1080 | 左右居中锚（inset 36 恒等）＋顶部 96 上锚＋内部滚动列表区纵向拉伸＋底行下锚——全案最大交互回归面（滚动/翻页/继续热区），矩阵静态矩形之外必须补交互用例 |
| 8 | pause_overlay.gd | 暂停卡(120,378)480×524（:100-101）、构筑详情卡(44,120)632×1000（:164-165） | 弹窗卡整体居中锚（PRESET_CENTER，offset=卡位−设计中心(360,640)，卡内父相对零改动） |
| 9 | game_over_screen.gd | 结算卡(70,404)580×470（:177-178） | 同上居中锚 |
| 10 | settings_panel.gd | 设置卡(50,290)620×820（:74-75，中心 y=700≠640） | offset_top=−350/bottom=+470 保持 +60 下偏恒等 |
| 11 | shop_ui.gd | 黑市卡(44,150)632×950（:421-422） | 居中锚（**归商店组执行**，见 §5） |
| 12 | card_select_ui.gd | 标题(0,148)720×46（:251-252）拉伸锚；卡栈按设计位整体居中锚（CARD_TOP=264/CARD_STEP=196(:26-27) 及 DUAL_* 父相对恒等，reroll 钮同栈内相对） | |
| 13 | boss_bar.gd（根 FULL_RECT :135 不动） | banner 720×46@y336（:221-222） | 拉伸锚（探索2「10 处全宽标签」漏计此处，实为 11 处：hud×4+menu×5+card_select×1+boss_bar×1） |

R2 白名单新增需按居中锚新位复审 BossBanner(y210)/TargetBar(y136) 相对关系（居中锚后卡顶
y≥578@1280，实算无交叠，白名单条目钉死进断言）。现有白名单（R198 契约变更：登记集合
对齐实盘 3 对——两套件 grep p_whitelisted=true 配对全集）：ReviveBadge∩HP 条
（hud.gd:967-975）、R187Readout∩HP 条（超设计增量：R187 引入 R187Readout 后实际需要，
R198 补登评审）、设置卡沿徽标（settings_panel.gd:83，(268,−40) 压卡沿）——白名单
数量＋条目写死增量须评审。

### 3.4 战场延展方案

1. **底色零成本定案**：清屏色 #EEF3FF 全库单写点 cloud_backdrop.gd:24
   （RenderingServer.set_default_clear_color）自动铺满延展区，无缝亮底；首版**禁加全幅
   tint ColorRect**（防两源写底分叉：game_loop 只染 _backdrop.modulate 云层、map_table
   注释 tint=云层 modulate；日后若加大难度染色反差，须把底色并入 CloudBackdrop 统一
   modulate 路径——列设计待办不进本批）。
2. **cloud_backdrop.gd:14 SCREEN 常量→活画布尺寸**（监听 size_changed；spawn x 域、
   y 带、回绕全随实宽实高），战场（game_loop 装配）与菜单两实例同修，单文件 ~15 行。
3. **confetti.gd:66 顶部全宽落雨 x∈[0,720]→活宽**；其叮字钳制 :96-97（x 20~700/y 260~1120）
   **有意保留设计域内不活化**（弹幕主区内避让 HUD）。
4. **域边界线（必做，~15 行）**：1px 低透明四边描出 res_logic 域，Node2D `_draw` 纯读
   res_logic、仅 size_changed 时 queue_redraw（适配层禁每帧分配）；动因＝expand 后平板
   x 延展区可见世界反弹沿（960 画布下反弹线落 x=840 屏内为探针几何实证），16:9 下贴屏
   缘不可见零副作用。
5. 暗角/装饰带＝二期选配（TextureFactory 径向渐变缓存先例），不进本批。
6. 相机 game_loop 不动（仍 res_logic×0.5，世界绕中心对称外扩）。

### 3.5 安全区口径

1. **单点 helper（static 工具类 safe_area_helper.gd，归适配底座组，各组只引用）**：
   守卫＝`OS.has_feature("mobile")` 或 `window_get_mode()∈{FULLSCREEN,EXCLUSIVE_FULLSCREEN}`，
   否则 insets 恒零——窗口化桌面 get_display_safe_area 返回整台显示器、inset 可达
   +1933px（探索席实证），守卫即 540×960 零回归的硬保证；headless 恒零矩形→矩阵不读真值。
2. 换算＝`root.get_final_transform().affine_inverse() × Rect2(safe_area)`，负值钳零；
   realize 后延迟 ≥1 帧再读（首帧 transform 未定型）；重读时机＝
   NOTIFICATION_WM_WINDOW_FOCUS_IN＋size_changed。
3. 应用＝各屏 FULL_RECT 根 offset_*（八处，dim FULL_RECT 全部不动→keep 黑边区天然免疫）：
   hud.gd:942 / menu_screen.gd:96 / **shop_ui.gd:410（归商店组）** / settings_panel.gd:57 /
   pause_overlay.gd:84 / game_over_screen.gd:163 / boss_bar.gd:135 / card_select_ui.gd:240。
4. **手势条裁决**：引擎不报手势 insets（dex 反汇编无 SystemGesture insets 调用；现役
   sticky immersive 下系统条默认隐藏）→ 首版不垫 40-48px 盲值常量，底带下锚 offset 维持
   恒等 24px/82px；真机回归若证实遮挡→把构筑面板 offset_bottom 24→~48 并在断言注释 R195。
5. **真机项**（挖孔真值/HyperOS 手势条/MIUI 偏差/折叠屏分屏 resize/manifest 无
   windowLayoutInDisplayCutoutMode）单列回归项，headless 全绿**不得标注为已验证**。

### 3.6 多尺寸验收矩阵（新套件 test_r195_layout.gd + r195_layout_cases.gd）

复刻 test_r194_mobile.gd 入口模式：SceneTree _initialize→_run＋await 2 帧＋运行时 load
cases 双件＋「验收汇总」聚合计数＋末尾 _gl.free() 防泄漏。

- **尺寸 7 档**＝720×1280 / 1440 / 1560 / 1600 / 1680（16:9~21:9）、960×1280（3:4 平板）、
  540×960（桌面默认窗）。
- **UI 态 7 个**＝MENU / PLAYING / PAUSED / LEVEL_UP / GAME_OVER / 商店 open / 设置 open
  （headless 经 change_state/request_pause/start_run 直达，实现以实际公开口为准）。
- **七律**：
  - R1 界内：get_global_rect ⊆ visible_rect+2px；
  - R2 无重叠（按簇配对，白名单钉死进断言，见 §3.3）；
  - R3 全宽标签横向居中 |center_x−vis.center_x|≤2px（11 处逐个点名）；
  - R4 底簇贴底（技能/构筑 offset_bottom 恒等贴 vis 底）；
  - R5 spawn 不入设计域（收窄口径见 §3.2）；
  - R6 dim.size==visible_rect 逐态；
  - R7 触控目标逐尺寸不缩水（AUTO 56×64/暂停 72×72）。
- **时序纪律**：root.size 赋值后 await≥2 帧再断言（同帧读旧值实证）；resize 后重触发
  运行期定位点（toast/hover）再断言。
- **钳制用例**＝720×1800→vis=(720,1280) origin.y≈260、720×1680→vis=(720,1680)、aspect
  双向切换可逆；safe-area 用例＝mock insets 注入测「insets→根 offset」映射纯函数＋守卫
  存在性源级 grep（仿 r194 G1 口径）。
- **落地纪律**：矩阵必须与 aspect=expand 同 commit（headless 默认窗 540×960 下
  EXPAND≡KEEP 实证→只跑默认窗＝全绿假象）；既有套件＝默认窗 test_r194 89/89 零改动全绿
  ＋r188/r191 全绿，另在 720×1600 复跑 r188/r191/r194 确认无几何断言误伤，仅按锚定语义
  更新期望值且断言注释标 R195，不放宽容差不删断言。
- **「显示不能乱」为硬验收**：任一尺寸七律红＝打回，打不动即整体回退 aspect=keep 黑边
  交付。

### 3.7 探索结论勘误（均已按实读修正）

探索1 data_validator 行号误（真针 `scripts/core/data/data_validator.gd:369-370`）；
探索2 漏 boss_bar.gd:221 第 11 处全宽标签、漏 toast :1331 第四处硬编码、构筑详情卡行号
误标（实在 pause_overlay.gd:164-165）；探索2/5「10 处/45 元素」计数以本分区表为准。

---

## 4. 整案收敛：跨方向冲突消解

| 冲突点 | 消解 |
|---|---|
| shop_ui.gd 双方向触碰（刷新钮隐藏 × 黑市卡锚定/安全区） | 全文件归**商店组**独占，同组先后执行两项职责（先 R195 刷新钮契约，再 §3.3 #11 锚定＋§3.5 安全区），杜绝跨组同文件 |
| 测试文件三方向都要动 | tests/** 全部归**测试统包组**单组认领（R71 断言改造、r194 注释、激光探针、布局矩阵、回归收口） |
| 「战斗逻辑零改动」红线 vs 激光方向改 combat 脚本 | 两条红线不同域：adapt 红线＝适配层不碰 combat/entities/wave 且 game_loop 只做表现层装配；laser 是本批**显式授权的战斗行为变更**，带 R195 契约注释与探针兜底。两者不冲突，实现时不得互相越界 |
| game_loop.gd 多处触碰（钳制/装配/云实例） | 归**适配底座组**独占；改动限定表现层（size_changed 钩子、playfield 装配、钳制函数），禁触战斗逻辑 |
| 商店钮隐藏 vs R194 几何契约 | 只翻 visible，position/size 原值；r194 几何③断言零改动通过（find_child 命中隐藏节点为 Godot 4 语义，headless 实证收口） |
| 商店方向「本环境无 godot 二进制」 | 该仲裁环境 PATH 无 godot；本仓二进制实证存在于 `tools/Godot_v4.3-stable_win64_console.exe`，实现组统一用它跑 headless（adapt/laser 验收口径已按此写） |
| 价签文案「刷新货架 (%d)」vs 文案真源 GameConst 纪律 | 该文案保持现源不动（无断言、不新增 GameConst 键），禁止顺手重构文案管线 |

---

## 5. 文件→组所有权表（互斥，恰 5 组）

| 组 | 文件 | 职责摘要 |
|---|---|---|
| ① 适配底座 | repo/project.godot、repo/scripts/loop/game_loop.gd、repo/scripts/ui/cloud_backdrop.gd、repo/scripts/ui/confetti.gd、repo/scripts/ui/safe_area_helper.gd（新增）、repo/scripts/ui/playfield_outline.gd（新增） | aspect=expand；超限钳制；云/彩带活画布；域边界线；safe-area helper 落地；game_loop 表现层装配 |
| ② UI 锚定 | repo/scripts/ui/hud.gd、repo/scripts/ui/menu_screen.gd、repo/scripts/ui/pause_overlay.gd、repo/scripts/ui/game_over_screen.gd、repo/scripts/ui/settings_panel.gd、repo/scripts/ui/boss_bar.gd、repo/scripts/cards/card_select_ui.gd | §3.3 分区表 #1-#10/#12-#13 锚定改造＋七屏安全区接入（shop 除外）＋hover/toast 活尺寸 |
| ③ 商店 | repo/scripts/ui/shop_ui.gd、repo/FEEDBACK_TRACKER.md、repo/docs/design/R194_MOBILE_PLAY.md | R195 刷新钮契约（§1 全部）＋黑市卡居中锚＋shop 根安全区＋R194 文档 §4.2 补注＋tracker:395 勾销与行号勘误 |
| ④ 激光 | repo/scripts/combat/weapon/laser_beam.gd、repo/scripts/combat/weapon/laser_weapon.gd、repo/resources/traits/AFF_PIERCE.tres | §2 全部（多目标贯穿、_pierce_count、AFF_PIERCE 形态门） |
| ⑤ 测试统包 | repo/tests/runner/verify_feedback_cases.gd、repo/tests/runner/r194_mobile_cases.gd、repo/tests/runner/r195_laser_pierce_cases.gd（新增）、repo/tests/runner/test_r195_laser_pierce.gd（新增）、repo/tests/runner/test_r195_layout.gd（新增）、repo/tests/runner/r195_layout_cases.gd（新增） | §1.5 断言改动、r194 几何③注释、S1-S9 探针、七尺寸×七态矩阵、全量回归收口 |

跨组依赖（sharedChanges）：

1. `safe_area_helper.gd` 先落**适配底座组**，UI 锚定组（七屏）与商店组（shop 根）只引用
   不复写；
2. `playfield_outline` 由底座组在 game_loop 表现层装配（z 压云不压弹幕）；
3. 激光组 AFF_PIERCE.tres / _pierce_count 契约先于/同步于测试统包的 S1-S9 探针（探针按
   预算口径直驱）；
4. 商店组 `can_refresh()` 谓词先于测试统包的 R71/R195 断言改造；
5. **矩阵套件与 aspect=expand 同 commit 落地**（防默认窗全绿假象）；布局矩阵收口须等
   ②③组锚定全部就位；
6. 全部组共用纪律：断言注释 R195 标注有意变更；类型化赋值注意时序；适配层禁每帧分配
   （R188）。

---

## 6. 设置键/套件契约（idContract，实现组逐字遵守）

- 新增运行时设置键（Meta.settings/settings_panel）：**无**（安全区走代码 helper、钳制
  阈值 2.34 为代码常量、手势条盲垫不进首版）。
- 项目设置改动（非新增键，改值）：
  `display/window/stretch/aspect | String | "expand"（原 "keep"） | Godot 枚举
  keep/expand/keep_width/keep_height/ignore（本批用 expand；运行期窗口高宽比>2.34 由
  game_loop 钳制回落 keep） | 项目设置不入玩家存档、无迁移；整体回退＝单行改回 "keep"
  即现状黑边；headless 默认窗 540×960 下 EXPAND≡KEEP（适配席探针实证）`
- tracker 套件名：**r195_adapt**。

---

## 7. 验收清单汇总

**商店（headless，tools/Godot_v4.3-stable_win64_console.exe --headless --path repo -s …）**

1. 静态：`grep -rn "refresh_btn.disabled" repo/scripts repo/tests` 输出 0 行；
2. 静态：`grep -n "can_refresh" repo/scripts/ui/shop_ui.gd` 恰 2 处（1 定义＋1 调用），
   谓词体内无 `_pre_boss` 字样；
3. 静态：几何红线原值（刷新钮 (211,802)210×56、出击钮 (211,868)210×60、scroll 576×700、
   refresh_cost() 公式一字未动）；
4. test_verify_feedback.gd 全 PASS，含 R195 新断言（0 金隐藏、回金复显、战前补给态隐藏＋
   标题「战前补给」）且 R71 无副作用断言仍 PASS；
5. test_r194_mobile.gd 全 PASS——几何③零改动通过；
6. test_market_supply / test_r188_idle / test_history / test_p1_polish 零改动全绿；
7. 集成收口 46 套件电池全绿（43 基线 + 本批 r195_adapt/r195_laser_pierce/r195_layout
   三新套件；按 tracker 流程）。

**激光**

1. test_r195_laser_pierce.gd exit 0 全绿：基线仅 E1、N=2 恰 E1+E2、N=3 恰 E1-E3、超程
   E4 恒满血（hit=N）；
2. N=2 无 SYN 时 E1/E2 同拍伤害相等；挂 SYN 后逐目标伤害比＝1+value×(pierce_index−1)
   （E1 ×1.2、E2 ×1.4，cap 1.6）且与弹体同式；
3. 灼焦归属（E1/E2>0、E3==0）；Line2D 末点==末贯穿目标；无敌时束长==beam_length；
4. 副束门（W4 副束只结算 1 目标）；折射分叉数与 N=1 基线相同且贯穿目标 ∈
   hit_exclusions()；last_hit_uid 恒==首目标 uid；
5. `_pierce_count()` 镜像式断言（基线=1、挂 AFF_PIERCE 后>1）；pause 面板穿透行输出真值；
6. 回归零位移：test_pkg3 → PASS 128/FAIL 0（激光段 955.2/16/8 不变）；test_pkg2/pkg4/
   w4_prism/w5_mirror/r187_rework/cd_pace/market_supply 全绿；DataRegistry.load_all 对
   改后 AFF_PIERCE.tres 校验零新增 error；
7. 工程红线：laser tick 路径无每帧新增 Dictionary/Array 分配；laser 段零新数据键、
   data_validator.gd 无改动；束端恒 t≤beam_length<1280 不穿屏。

**适配**

- A1 默认窗零回归：test_r194_mobile → 89/89 且断言零改动；test_r188_idle、
  test_r191_rework 全绿；
- A2 新矩阵门禁：test_r195_layout 全绿；7 尺寸×7 态，逐尺寸断言输出 visible_rect；
- A3 R3 居中：720×1600 与 960×1280 下 11 处全宽标签 |center_x−vis.center_x|≤2px（toast
  经 _show_toast 重触发后再断言）；
- A4 R4+R7：底簇贴底恒等；AUTO 56×64、暂停 72×72 逐尺寸不缩水；
- A5 R1+R2+R6：逐尺寸逐态界内/无重叠（白名单两条钉死）/dim==visible_rect；
- A6 R5：spawn 采样点 ∉ [0,720]×[0,1280]；
- A7 钳制回退：720×1800 居中黑边、720×1680 满屏、KEEP↔EXPAND 双向可逆、keep 回退位等价
  校验（钳制函数零触发）；
- A8 安全区契约：mock insets→八屏根 offset 映射（负值钳零）；helper 守卫源级 grep；
  combat/entities/wave 零视口读取维持；
- A9 非默认尺寸回归：r188/r191/r194 @720×1600 全绿（期望值更新处均有 R195 注释，无放宽
  无删除）。

---

## 8. 统合席本批实证记录（2026-09-30）

- 静态复核（grep/read，全部通过）：refresh_btn.disabled 全仓恰 1 写点＋1 断言；
  can_refresh 零命中；_pierce_count 定义 ballistic_weapon.gd:256；HIT_AFTER_PIERCE 仅
  game_const.gd:395 定义＋projectile_base 写入；shop_ui.gd 几何三件套/disabled 写点
  :492-494/refresh_cost :378-381/_shelves_empty :384-389 死码/AFF_PIERCE.tres
  required_forms [0]；verify_feedback_cases.gd:3188 断 disabled、:3190-3193 无副作用断言、
  :3194 close；r194_mobile_cases.gd:437-440 几何③无 visible 子句、:444-446
  is_queued_for_deletion 防护；data_validator 真实路径 scripts/core/data/data_validator.gd
  fatal :369-370；laser_beam.gd 字段 depth:35/is_refraction:41/sub_beam:42/
  overlap_fallback:45、tick 单目标、_first_hit、_on_hit_target 仅新目标 refract、
  last_hit_uid 于 _settle_one_tick 写入；laser_weapon.gd try_fire 主束 :90、_on_tick_post
  R191 tick_atk 回写 :113-114、_refresh_sub_beams sub_beam:true；tools/
  Godot_v4.3-stable_win64_console.exe 存在。
- 动态复核：headless 跑 `tools/Godot_v4.3-stable_win64_console.exe --headless --path repo
  -s tests/runner/test_r194_mobile.gd` → exit 0，「验收汇总：89/89 通过」（统合席本批复跑
  实证，与适配席基线一致；A1 默认窗零回归口径成立）。
- 未运行：46 套件电池、pkg3 基线、激光探针、布局矩阵——属实现组/测试统包组职责。

# INFINITE FISSION · Agent 工程规范（AGENTS.md）

> 本文件是 Agent 会话的自动加载上下文：本项目技术栈、分层、铁律、测试与提交纪律。
> 版本事实源 = `PROGRESS.md`；数值与契约真源 = `docs/analysis/A6_v0.7.0_design.md`（v0.7.0）。

## 技术栈

- Godot **4.3** stable / GDScript；竖屏 **720×1280**（120Hz 逻辑帧）、Forward+ 渲染
- 弹幕 Roguelike：多乘区伤害公式 + 词缀协同 + 对象池海量弹幕
- autoload×3（顺序即就绪序）：`EventBus` → `GameConfig` → `DebugStats`（均不声明 class_name）
- 无外部插件；美术全程序化占位（纯色 / draw_* 程序化绘制）

## 分层

```
autoload/        EventBus(事件总线) GameConfig(配置/数值降级) DebugStats(遥测)
scripts/core/    池(ObjectPool+特化池×7)/SpaceGrid/ModifierStack/DamagePipeline/GameConst
scripts/core/data/    DataRegistry/DataValidator/BalanceTables + resources/*(Resource schema)
scripts/combat/  weapon 四形态 / projectile / elemental / trait
scripts/entities/ enemy / player / wave(WaveDirector/EnemySpawner)
scripts/loop/    GameLoop(状态机+固定帧序) / relic_handler / chip_handler
scripts/ui/      HUD/ShopUI/CardSelectUI/GameOverScreen/PopupManager/DamagePopup
scripts/cards/   CardGenerator/CardSelectUI   scripts/gamefeel/ 顿帧/震屏/色差/粒子
tests/           runner(pkg0~pkg7 两段式) / stress(perf/soak) / formula / fixtures
```

## 工程铁律（违反即返工）

1. **GDScript 静态类型全覆盖**；无 TODO 桩；`Dictionary.get()` 返回 Variant 必须显式类型标注
2. **不写 `Engine.time_scale`**——顿帧走 GameLoop 双时间通道（game_delta = raw × time_scale）
3. 数值红线：乘区整体钳 **8.0**（cap_prod）、δ ≤ **0.92**、射速 ≤ **30/s**、弹软 **1500** 硬 **2000**
4. `docs/` 既有文件不可改；新文档只建 `docs/analysis/`（A 系列设计留痕）
5. 池纪律：运行期零实例化（池循环）；归还清零责任在实体 `_reset_state`；E-04 顺序断言
6. **连接序 = 派发序**：一切 `enemy_killed` 订阅（xp/gold/relic/chip 掉落、GameFeel）必须在
   `EnemySpawner` add_child 之前连接——死亡掉落侧读 tags/字段必须先于归还清零
7. 幂等键 = (source_uid, target_uid, frame_stamp)；死亡短路 E-06；一帧一目标一条 E-03
8. 管线九步顺序禁止重排；同输入必同输出（fixed-seed 回归是契约不是运气）
9. 表现改动（UI 布局/粒子/横幅）必须真机窗口实测 headless 之外的效果；headless 只验逻辑
10. 静态权重表（CATEGORY_WEIGHTS 等）与镜像（BalanceTables/.tres）三处同值，改一处必改三处

## 测试命令

```bash
G=/Users/genmer/Documents/Codes/Tools/godot/Godot.app/Contents/MacOS/Godot
"$G" --headless --path . --import                              # 新增 .tres/class_name 后必跑
"$G" --headless --path . -s tests/runner/test_pkg0.gd          # pkg0~pkg7 逐 runner
"$G" --headless --path . -s tests/runner/test_pkg6_extra.gd    # 独立验收补充 runner
"$G" --headless --path . -s tests/stress/test_perf_500p100e.gd # 压力（P95<8.3ms 判定线）
"$G" --headless --path . -s tests/stress/test_soak.gd          # soak（长跑后台+轮询）
```

- 测试入口两段式：`-s` 脚本只做引导（autoload 未注册），用例体 `pkgN_cases.gd` 运行时 load
- **新增 class_name 脚本后必须重跑 `--import`**，否则全局类缓存过期 → 解析失败且进程挂起
- 测试全绿才 commit；每任务一笔 `feat: U<N> <一句话>`；push 由主控统一执行
- 提交范围只含相关文件；测试文件、AI 生成的分析文档、本地配置不入库（docs/analysis 的
  A 系列设计文档是项目事实源，**要**入库）

## 项目特定契约（改动需全量评估，详见 PROGRESS §8）

- EventBus 信号注册表与 DataValidator.EVENT_NAMES **双源镜像**（v0.7.0 = 21 信号），加信号必同步
- 芯片独立乘区段：仅直击通道注入 chip_entries；**settle_aoe / DOT / 反应不吃芯片 ATK 段**
- Boss 掉落芯片 / 商店芯片货架共用 ChipHandler（3 槽、wave 1/10/20 解锁、同 id 唯一）
- 金币关（w6/16/26）：0.4×血量 rush 敌 + 掉率≥0.5/面值×2 覆写 + 波末按剩余时间比例奖励
- UI 全量坐标表 720×1280 见 shop_ui.gd / hud.gd 类头；`layout_rects()` 两两无交集是断言口

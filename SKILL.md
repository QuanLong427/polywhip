---
name: polywhip
version: 0.8.0
description: "PolyWhip: whipflow DSL expert for executing .whip workflow scripts. Use this skill when the user mentions polywhip or wants to run Polymarket weather high-temperature prediction arbitrage. Trigger on: 'polymarket weather high-temperature prediction arbitrage', 'run the scan/trade/monitor/report workflow', 'execute xxx.whip'."
author: Hermes Agent + Teknium
license: MIT
metadata:
  hermes:
    tags: [polymarket, weather, arbitrage, trading, whipflow]
    related_skills: [polymarket, prediction-market-trading]
---

# PolyWhip Skill

WhipFlow 是该skill内置的工作流 DSL，用于编排多步骤 AI agent 任务。
在`./workflows`目录下，文件扩展名 `.whip`，通过 `./bin/whip` 二进制执行。

## 路径约定与环境变量

运行时有两个独立的路径上下文：

| 上下文         | 位置                                                         | 说明                                          |
| -------------- | ------------------------------------------------------------ | --------------------------------------------- |
| **Skill 目录** | 不固定（hermes/openclaw 加载该skill的目录/该skill安装的目录） | `bin/`、`workflows/`、`scripts/`              |
| **运行时目录** | `/home/trader/`（固定）                                      | 输出 `skill_result/`、配置 `.polywhip_config` |

**加载 Skill 时必须设置的环境变量:** 

由于工作流中启动的子agent可能不知道该skill的目录在哪，无法找到该skill目录下面的资源执行。

所以母 agent（hermes/openclaw）加载本 skill 时，根据 skill 安装路径设置以下环境变量：

```bash
# 假设 skill 安装在 /home/trader/.claude/skills/polywhip
export POLY_SKILL_DIR="/home/trader/.claude/skills/polywhip"
export POLY_SKILL_BIN="${POLY_SKILL_DIR}/bin"
export POLY_SKILL_SCRIPTS="${POLY_SKILL_DIR}/scripts"
export POLY_SKILL_WORKFLOWS="${POLY_SKILL_DIR}/workflows"
```

> `.whip` 工作流通过 `$POLY_SKILL_BIN`、`$POLY_SKILL_SCRIPTS` 引用 skill 内部资源，无需硬编码 skill 绝对路径。
> 运行时目录（`/home/trader/skill_result/`、`/home/trader/.polywhip_config`）在 .whip 内使用绝对路径。

## 配置文件

这是运行.whip工作流的前提条件。

若找不到`/home/trader/.polywhip_config`该配置文件，则使用`$POLY_SKILL_DIR/references/polywhip_config_template`为模板，引导用户进行填写参数，然后生成文件`/home/trader/.polywhip_config`。

## 可用工作流

可执行的工作流在`$POLY_SKILL_WORKFLOWS`目录下面，目前有：

| 工作流  | 文件           | 功能                                      |
| ------- | -------------- | ----------------------------------------- |
| scan    | `scan.whip`    | 扫描天气预测市场，计算 edge，筛选交易机会 |
| trade   | `trade.whip`   | 根据 opportunities.json 执行 CLOB 下单    |
| monitor | `monitor.whip` | 监控持仓盈亏，触发止盈止损                |
| report  | `report.whip`  | 生成交易日报/周报                         |
| setup   | `setup.whip`   | 初始化配置（API keys、钱包等）            |

## 执行工作流

```bash
# 以 trader 用户执行工作流（whip 拒绝 root/sudo）
su - trader -c "$POLY_SKILL_BIN/whip run $POLY_SKILL_WORKFLOWS/scan.whip"
```

## 输出文件

工作流产生的数据文件统一写入 `/home/trader/skill_result/`：

```bash
# 确保输出目录存在
mkdir -p /home/trader/skill_result
```

- `/home/trader/skill_result/markets-filtered.json` — 预过滤的市场数据
- `/home/trader/skill_result/forecasts.json` — 集合预报概率分布
- `/home/trader/skill_result/opportunities.json` — 交易机会列表
- `/home/trader/skill_result/positions.json` — 当前持仓
- `/home/trader/skill_result/trades.json` — 历史成交记录

## 你的任务

1. 根据用户描述，**执行 `.whip` 文件**。
2. 如果用户还需要**启动 Dashboard**（可视化展示），则按照`Web Dashboard（独立可视化）`启动Dashboard。
3. 始终输出完整文件，不要省略内容。

## 运行规则

- **不要使用 TodoWrite**：用户指定了 .whip 文件或 polywhip 正在运行时，workflow 本身就是任务追踪，直接调用 whip 执行，不需要先记录任何 todo
- 用户已提供 `.whip` 文件路径时，直接执行
description: "PolyWhip: whipflow DSL expert for executing .whip workflow scripts. Use this skill when the user mentions polywhip or wants to run Polymarket weather high-temperature prediction arbitrage. Trigger on: 'polymarket weather high-temperature prediction arbitrage', 'run the scan/trade/monitor/report workflow', 'execute xxx.whip'."
---

## Web Dashboard（独立可视化）

Dashboard 是一个自包含的 HTTP 服务，读取 `/home/trader/skill_result/` 下的 JSON 数据文件，渲染为可视化页面。任何 agent（claude、hermes、openclaw）都可以启动和访问。

### 启动 Dashboard

```bash
# 启动 HTTP 服务（默认端口 8099）
$POLY_SKILL_BIN/dashboard

# 自定义端口
$POLY_SKILL_BIN/dashboard 9090

# 后台运行
nohup $POLY_SKILL_BIN/dashboard > /dev/null 2>&1 &
```

访问 `http://localhost:8099` 查看 Dashboard。

### Dashboard 功能

- **Risk Status**：熔断状态、日亏损、告警列表
- **Opportunities**：交易机会列表（edge、P(model)、P(market)、仓位大小）
- **Open Positions**：当前持仓及浮动 PnL
- **Markets**：市场概览（城市、日期、bin 概率、流动性）
- **Forecasts**：集合预报（最高概率区间、ensemble spread）
- **Recent Trades**：最近交易记录（状态、PnL）
- 页面每 30 秒自动刷新

### 在工作流中使用

scan.whip 执行完毕后自动刷新 Dashboard 数据。要手动触发：

```bash
# 启动 dashboard 后，任何新数据写入 /home/trader/skill_result/ 都会自动反映
curl http://localhost:8099/health  # 检查服务状态
```


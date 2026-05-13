# PolyWhip

Polymarket 天气最高温预测套利系统。基于集合天气预报模型计算温度概率分布，与 Polymarket 天气市场定价对比，自动寻找 edge 并交易。

## 工作原理

```
Open-Meteo 集合预报 (39 members)          Polymarket 天气市场
         ↓                                        ↓
    温度概率分布                              市场隐含概率
         ↓                                        ↓
         └──────── edge = P_model - P_market ────────┘
                          ↓
                   Kelly 仓位计算
                          ↓
                   CLOB 自动下单
```

1. **Scan** — 从 Gamma API 拉取天气市场，从 Open-Meteo 获取 39 个集合预报成员的温度分布，计算每个温度区间的 edge
2. **Trade** — 对 edge 达标的合约执行 CLOB 下单
3. **Monitor** — 监控持仓盈亏，触发止盈止损
4. **Report** — 生成交易日报/周报

## 架构

基于 [WhipFlow](https://github.com/npc-live/whipflow) DSL 的多 agent 工作流：

- **母 agent**（Hermes / OpenClaw）加载 skill，设置环境变量，调度工作流
- **`.whip` 工作流**编排多个 session，每个 session 启动一个独立 LLM agent
- **子 agent** 执行具体任务（数据拉取、概率计算、edge 分析、下单）

## 目录结构

```
polywhip/
├── SKILL.md                    # Skill 定义（Hermes/OpenClaw 加载入口）
├── bin/
│   ├── whip                    # WhipFlow DSL 执行引擎（Go 二进制）
│   └── dashboard               # Web Dashboard 服务（Go 二进制）
├── workflows/
│   ├── scan.whip               # 扫描 + 计算 edge
│   ├── trade.whip              # CLOB 下单
│   ├── monitor.whip            # 持仓监控
│   ├── report.whip             # 交易报告
│   └── setup.whip              # 初始化配置
├── scripts/
│   └── filter-markets.sh       # Gamma API 市场数据预过滤
├── references/
│   └── polywhip_config_template # 配置文件模板
└── README.md
```

## 环境要求

- Linux（whip 二进制为 linux/amd64）
- [Polymarket](https://polymarket.com) 账户 + API Key + 钱包私钥
- 代理（用于访问 Gamma API，部分地区需要）

## 安装

### 1. 创建 trader 用户

```bash
id trader 2>/dev/null || sudo useradd -m -s /bin/bash trader
```

### 2. 放置 skill

将 `polywhip/` 目录放到 agent 的 skills 目录下，例如：

```bash
# Hermes
cp -r polywhip/ /root/.hermes/skills/polymarket/polywhip/

# 或 OpenClaw / Claude
cp -r polywhip/ /home/trader/.claude/skills/polywhip/
```

### 3. 设置环境变量

母 agent 加载 skill 时必须设置：

```bash
export POLY_SKILL_DIR="/path/to/polywhip"
export POLY_SKILL_BIN="${POLY_SKILL_DIR}/bin"
export POLY_SKILL_SCRIPTS="${POLY_SKILL_DIR}/scripts"
export POLY_SKILL_WORKFLOWS="${POLY_SKILL_DIR}/workflows"
```

### 4. 初始化配置

```bash
# 复制模板
cp references/polywhip_config_template /home/trader/.polywhip_config

# 编辑配置（必须填写 WALLET_ADDRESS 和 POLY_API_KEY）
vim /home/trader/.polywhip_config
```

### 5. 确保 trader 用户可执行

```bash
# whip 拒绝 root/sudo，必须以 trader 用户执行
chmod +x bin/whip bin/dashboard
chown -R trader:trader /home/trader/skill_result
```

## 配置

配置文件位于 `/home/trader/.polywhip_config`，KEY=VALUE 格式，shell 可 source，LLM 可直接读取。

### 必填项

| 参数 | 说明 |
|------|------|
| `WALLET_ADDRESS` | Polymarket 钱包地址 |
| `POLY_API_KEY` | Polymarket CLOB API Key |

### 策略参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `MIN_EDGE` | 0.05 | 最低 edge 门槛 |
| `MIN_EDGE_PRECIP` | 0.15 | 降水合约最低 edge |
| `SUMMER_MIN_EDGE` | 0.12 | 夏季上海最低 edge |
| `HIGH_SPREAD_MIN_EDGE` | 0.10 | 高 spread 时最低 edge |
| `SKIP_EDGE_LOW` | 0.30 | 跳过过度自信区间下限 |
| `SKIP_EDGE_HIGH` | 0.40 | 跳过过度自信区间上限 |

### 仓位管理

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `CORRELATION_DISCOUNT` | 0.65 | 同城市已有仓位的相关性折扣 |
| `MAX_POSITION_PCT` | 0.10 | 单仓最大占初始资金比例 |
| `MAX_POSITIONS` | 3 | 最大同时持仓数 |
| `MAX_EXPOSURE_PCT` | 0.80 | 总敞口上限 |
| `MIN_ORDER_USDC` | 5 | CLOB 最小下单金额 |

### 风控

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `DAILY_LOSS_LIMIT_PCT` | 0.05 | 日亏损熔断比例 |
| `ENSEMBLE_SPREAD_LIMIT` | 4.0 | spread 上限（超过不交易） |
| `HIGH_SPREAD_THRESHOLD` | 2.5 | 高 spread 阈值 |
| `LOW_SPREAD_THRESHOLD` | 1.5 | 低 spread 阈值 |

## 使用

### 执行工作流

```bash
# 扫描交易机会
su - trader -c "$POLY_SKILL_BIN/whip run $POLY_SKILL_WORKFLOWS/scan.whip"

# 执行交易
su - trader -c "$POLY_SKILL_BIN/whip run $POLY_SKILL_WORKFLOWS/trade.whip"

# 监控持仓
su - trader -c "$POLY_SKILL_BIN/whip run $POLY_SKILL_WORKFLOWS/monitor.whip"

# 生成报告
su - trader -c "$POLY_SKILL_BIN/whip run $POLY_SKILL_WORKFLOWS/report.whip"
```

### 通过 Agent 调用

直接对 Hermes/OpenClaw 说：

```
run the scan workflow
```

或

```
polymarket weather high-temperature prediction arbitrage
```

### 启动 Dashboard

```bash
# 前台运行（默认端口 8099）
$POLY_SKILL_BIN/dashboard

# 后台运行
nohup $POLY_SKILL_BIN/dashboard > /dev/null 2>&1 &
```

访问 `http://localhost:8099` 查看可视化面板。

## 数据文件

所有输出写入 `/home/trader/skill_result/`：

| 文件 | 说明 |
|------|------|
| `markets-filtered.json` | 预过滤的市场数据（城市、日期、bin 概率） |
| `forecasts.json` | 集合预报概率分布（39 members → bin 概率） |
| `opportunities.json` | 交易机会（edge、仓位大小、rationale） |
| `positions.json` | 当前持仓 |
| `trades.json` | 历史成交记录 |

## 策略细节

### Edge 计算

```
edge = P_model(bin) - P_market(bin)
```

- **P_model** — Open-Meteo 39 个集合预报成员落入该温度区间的比例
- **P_market** — Polymarket 市场价格（隐含概率）

### 仓位计算

```
full_kelly = edge / (1 - P_market)
half_kelly = 0.5 * full_kelly
half_kelly *= (1 - CORRELATION_DISCOUNT)    # 同城市折扣
half_kelly *= spread_discount               # 高 spread 折扣
max_position = min(half_kelly * capital, capital * MAX_POSITION_PCT)
下单金额 = max(MIN_ORDER_USDC, min(max_position, 可用余额))
```

### 风控规则

- 单仓不超过总资金的 `MAX_POSITION_PCT`
- 总敞口不超过 `MAX_EXPOSURE_PCT`
- 最多同时持有 `MAX_POSITIONS` 个仓位
- 日亏损超过 `DAILY_LOSS_LIMIT_PCT` 触发熔断
- ensemble spread 超过 `ENSEMBLE_SPREAD_LIMIT` 跳过不交易
- edge 在 30%-40% 区间跳过（市场可能已反映信息）

## 支持城市

上海、首尔、多伦多、纽约、伦敦、东京、新加坡、深圳

## License

MIT

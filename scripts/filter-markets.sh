#!/bin/bash
# filter-markets.sh — 从 Gamma API 拉取天气温度市场并按城市/日期过滤
# 输出：${DATA_DIR}/markets-filtered.json
# 用法：bash scripts/filter-markets.sh [proxy] [target_date]
#   proxy       代理地址（覆盖配置文件）
#   target_date 目标日期 YYYY-MM-DD，默认今明两天

set -euo pipefail

# 加载全局配置
CONFIG="/home/trader/.polywhip_config"
if [ -f "$CONFIG" ]; then
  source "$CONFIG"
fi

PROXY="${1:-${PROXY:-http://192.168.232.1:7897}}"
DATA_DIR="${DATA_DIR:-/home/trader/skill_result}"
OUTPUT="${DATA_DIR}/markets-filtered.json"
mkdir -p "$DATA_DIR"

# 目标日期：默认今明两天
TODAY=$(LC_ALL=en_US.UTF-8 date -u +%Y-%m-%d)
TOMORROW=$(LC_ALL=en_US.UTF-8 date -u -d "+1 day" +%Y-%m-%d)

# 日期格式转换：YYYY-MM-DD → "Month D" (如 "May 7"，不带年份)
format_date() {
  local d="$1"
  local m=$(LC_ALL=en_US.UTF-8 date -d "$d" +%B)
  local day=$(LC_ALL=en_US.UTF-8 date -d "$d" +%-d)
  echo "${m} ${day}"
}

# 构建日期匹配模式（用 | 分隔，jq 用 test 匹配）
TODAY_TITLE=$(format_date "$TODAY")
TOMORROW_TITLE=$(format_date "$TOMORROW")
DATE_PATTERN="${TODAY_TITLE}|${TOMORROW_TITLE}"

# 目标城市映射：workflow 城市名 → Polymarket 标题中的城市名
declare -A CITY_MAP=(
  ["shanghai"]="Shanghai"
  ["seoul"]="Seoul"
  ["toronto"]="Toronto"
  ["nyc"]="NYC"
  ["london"]="London"
  ["tokyo"]="Tokyo"
  ["singapore"]="Singapore"
  ["shenzhen"]="Shenzhen"
  ["hongkong"]="Hong Kong"
)

echo "目标日期: 今明两天 (${TODAY_TITLE} / ${TOMORROW_TITLE})"

# 拉取事件 — 必须用 order=endDate&ascending=false 才能拿到最新事件
# 默认排序只返回旧数据（已知 API bug）
echo "拉取 Gamma API (tag_id=103040, order=endDate)..."
RAW=$(curl -s --proxy "$PROXY" \
  "https://gamma-api.polymarket.com/events?limit=500&tag_id=103040&order=endDate&ascending=false")

# 按城市和日期过滤，提取温度 bin 市场（预解析格式，节省 LLM token）
echo "$RAW" | jq --arg date "$DATE_PATTERN" '
  # 城市匹配表
  {
    "Shanghai": "shanghai", "Seoul": "seoul", "Toronto": "toronto",
    "NYC": "nyc", "London": "london", "Tokyo": "tokyo",
    "Singapore": "singapore", "Shenzhen": "shenzhen", "Hong Kong": "hongkong"
  } as $city_map |

  # 解析 group_item_title 为 forecast bin 格式 {low, high}
  # forecast bin 用右闭 (N, N+1]，market "X°C" 对应 bin (X-1, X]
  # 华氏度范围如 "56-57°F" 先转为摄氏度再解析
  def f2c: (. - 32) * 5 / 9 | . * 10 | round / 10;
  def parse_bin:
    if test("or below") and test("°F") then
      # 华氏度 "51°F or below" → 转摄氏度
      { low: null, high: (. | gsub("[^0-9.]"; "") | tonumber | f2c) }
    elif test("or below") then
      # 摄氏度 "17°C or below"
      { low: null, high: (. | gsub("[^0-9.]"; "") | tonumber) }
    elif test("or higher") and test("°F") then
      # 华氏度 "65°F or higher" → 转摄氏度
      { low: (. | gsub("[^0-9.]"; "") | tonumber | f2c), high: null }
    elif test("or higher") then
      # 摄氏度 "32°C or higher"
      { low: (. | gsub("[^0-9.]"; "") | tonumber), high: null }
    elif test("-") and test("°F") then
      # 华氏度范围 "56-57°F" → 先转摄氏度，再做右闭 binning
      (. | gsub("[^0-9.-]"; "") | split("-") | map(tonumber)) as $range |
      { low: (($range[0] | f2c) - 1 | . * 10 | round / 10), high: ($range[1] | f2c) }
    elif test("°F") then
      # 单个华氏度 "65°F" → 先转摄氏度，再做右闭 binning
      (. | gsub("[^0-9.]"; "") | tonumber) as $f |
      { low: (($f | f2c) - 1 | . * 10 | round / 10), high: ($f | f2c) }
    else
      # 摄氏度单值 "27°C" → (26, 27]
      { low: ((. | gsub("[^0-9.]"; "") | tonumber) - 1), high: (. | gsub("[^0-9.]"; "") | tonumber) }
    end;

  [ .[] |
    select(.title | test($date)) |

    (.title | ltrimstr("Highest temperature in ") | ltrimstr("Lowest temperature in ") | split(" on ")[0]) as $city_name |
    select($city_map[$city_name] != null) |

    (if .title | test("^Highest") then "highest" else "lowest" end) as $temp_type |
    select($temp_type == "highest") |

    . + { city: $city_map[$city_name], city_name: $city_name, temp_type: $temp_type }
  ] | {
    scan_date: (now | todate),
    target_date: "'"$TODAY"' / '"$TOMORROW"'",
    total_events: length,
    markets: [
      .[] | {
        city,
        date: (.title | split(" on ")[1] | split("?")[0]),
        event_id: .id,
        liquidity: .liquidity,
        bins: [
          .markets[] |
          select(.active == true) |
          select(.volumeNum >= 1000) |
          (.groupItemTitle | parse_bin) as $bin |
          {
            market_id: .id,
            label: .groupItemTitle,
            low: $bin.low,
            high: $bin.high,
            market_prob: ((.outcomePrices | fromjson)[0] // 0),
            token_id: ((.clobTokenIds | fromjson)[0]),
            volume: .volumeNum,
            liquidity: .liquidityNum
          }
        ]
      }
    ]
  }
' > "$OUTPUT"

COUNT=$(jq '.markets | length' "$OUTPUT")
echo "过滤完成: ${COUNT} 个城市事件写入 ${OUTPUT}"

# 输出摘要
jq -r '.markets[] | "\(.city) | \(.date) | bins: \(.bins | length) | liquidity: $\(.liquidity | floor)"' "$OUTPUT"

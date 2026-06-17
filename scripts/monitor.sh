#!/bin/bash
#
# QuotaMonitor GitHub 仓库监控脚本
# 用法：./scripts/monitor.sh
#   - 查 stars / forks / watchers / open issues
#   - 查最近 14 天 views / clones
#   - 查 Release 资产下载次数
#   - 查 Top 引用来源 + Top 访问路径
#   - 查最近 issues / PRs
#

set -e

REPO="cuichaoing/QuotaMonitor"

cd "$(dirname "$0")/.."

echo "=========================================="
echo "  QuotaMonitor GitHub 监控报告"
echo "  仓库: $REPO"
echo "  时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo "=========================================="
echo ""

# 1. 仓库基本信息
echo "[1/8] 仓库基本信息"
gh api repos/$REPO --jq '{
  stars: .stargazers_count,
  forks: .forks_count,
  watchers: .subscribers_count,
  open_issues: .open_issues_count,
  size_kb: .size,
  language: .language,
  created: .created_at,
  updated: .updated_at,
  default_branch: .default_branch
}'
echo ""

# 2. Traffic 浏览量
echo "[2/8] Traffic 浏览量（最近 14 天）"
gh api repos/$REPO/traffic/views --jq '{
  total_views: .count,
  unique_visitors: .uniques,
  daily_breakdown: [.views[] | "  \(.timestamp): \(.count) views, \(.uniques) 独立"]
}'
echo ""

# 3. Traffic 克隆
echo "[3/8] Traffic 克隆（最近 14 天）"
gh api repos/$REPO/traffic/clones --jq '{
  total_clones: .count,
  unique_cloners: .uniques,
  daily_breakdown: [.clones[] | "  \(.timestamp): \(.count) clones, \(.uniques) 独立"]
}'
echo ""

# 4. Release 下载次数
echo "[4/8] Release 资产下载次数"
gh api repos/$REPO/releases --jq '.[] | "Release \(.name) (tag: \(.tag_name)):"' 2>/dev/null
gh api repos/$REPO/releases --jq '.[] | .assets[] | "  - \(.name): \(.download_count) downloads"' 2>/dev/null
echo ""

# 5. Top 引用来源
echo "[5/8] Top 引用来源（referrers）"
gh api repos/$REPO/traffic/popular/referrers --jq '.[] | "  - \(.referrer): \(.count) views"' 2>/dev/null | head -10
echo ""

# 6. Top 访问路径
echo "[6/8] Top 访问路径"
gh api repos/$REPO/traffic/popular/paths --jq '.[] | "  - \(.path): \(.count) views"' 2>/dev/null | head -10
echo ""

# 7. Stars 用户
echo "[7/8] Stars 用户列表"
STAR_COUNT=$(gh api repos/$REPO/stargazers --jq 'length' 2>/dev/null)
if [ "$STAR_COUNT" = "0" ]; then
    echo "  (无 star)"
else
    gh api repos/$REPO/stargazers --jq '.[] | "  - \(.login) (\(.html_url))"' 2>/dev/null
fi
echo ""

# 8. Issues / PRs
echo "[8/8] 最近 issues / PRs"
ISSUE_COUNT=$(gh issue list --limit 100 --json number 2>/dev/null | jq 'length' 2>/dev/null || echo "0")
if [ "$ISSUE_COUNT" = "0" ]; then
    echo "  (无 issue / PR)"
else
    gh issue list --limit 5 --json number,title,state,author,createdAt --jq '.[] | "  #\(.number) [\(.state)] \(.title) - by \(.author.login) at \(.createdAt)"' 2>/dev/null
fi
echo ""

echo "=========================================="
echo "  监控完毕"
echo "=========================================="

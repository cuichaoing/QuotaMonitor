#!/bin/bash
#
# QuotaMonitor 发版脚本
# 用法：./scripts/release.sh 1.0.3
#   - bump Info.plist 版本号
#   - 更新 CHANGELOG.md（手动）
#   - 跑测试确认全过
#   - 提交 + 打 tag + 推送
#   - GitHub Actions 自动 build + 产 dmg + 发 Release
#

set -e

VERSION=$1

if [ -z "$VERSION" ]; then
    echo "用法: $0 <version>"
    echo "示例: $0 1.0.3"
    exit 1
fi

# 移除前导 v（如果有）
VERSION=${VERSION#v}
TAG="v$VERSION"

cd "$(dirname "$0")/.."

echo "=========================================="
echo "  发布 QuotaMonitor $TAG"
echo "=========================================="
echo ""

# 1. 跑测试
echo "[1/5] 跑 swift test..."
swift test 2>&1 | tail -3

# 2. 检查 working tree 干净
echo ""
echo "[2/5] 检查 git working tree..."
if [ -n "$(git status --porcelain)" ]; then
    echo "✗ working tree 不干净，先 commit 或 stash："
    git status --short
    exit 1
fi
echo "✓ clean"

# 3. 更新 Info.plist 版本号
echo ""
echo "[3/5] 更新 Info.plist 版本号到 $VERSION..."
PLIST="build/QuotaMonitor.app/Contents/Info.plist"
if [ -f "$PLIST" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
    BUILD=$(git rev-list --count HEAD)
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PLIST"
    echo "✓ CFBundleShortVersionString=$VERSION, CFBundleVersion=$BUILD"
else
    echo "⚠ $PLIST 不存在，跳过"
fi

# 4. commit + tag + push
echo ""
echo "[4/5] commit + tag + push..."
git add -A
if [ -n "$(git status --porcelain)" ]; then
    git commit -m "chore(release): $TAG"
fi
git tag -a "$TAG" -m "Release $TAG"
git push origin main --follow-tags
echo "✓ pushed"

# 5. watch release workflow
echo ""
echo "[5/5] watch release workflow..."
sleep 5
RUN_ID=$(gh run list --workflow=release.yml --limit=1 --json databaseId --jq '.[0].databaseId' 2>/dev/null || echo "")
if [ -n "$RUN_ID" ]; then
    echo "Watching run $RUN_ID..."
    gh run watch "$RUN_ID" --exit-status
    echo ""
    echo "✓ Release 已发布到 GitHub："
    echo "  https://github.com/$(gh repo view --json owner,name --jq '.owner.login + "/" + .name')/releases/tag/$TAG"
else
    echo "⚠ 找不到 release run ID，请手动查看："
    echo "  https://github.com/$(gh repo view --json owner,name --jq '.owner.login + "/" + .name')/actions"
fi

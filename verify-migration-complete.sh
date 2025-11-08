#!/usr/bin/env bash

# ============================================================================
# Aonsoku Electron Forge 迁移 - 完整性检查脚本
# ============================================================================
# 用途：验证所有迁移文件是否正确就位
# 使用：bash verify-migration-complete.sh
# ============================================================================

set -e

echo "🔍 Aonsoku Electron Forge 迁移 - 完整性检查"
echo "=========================================="
echo ""

# 颜色定义
GREEN='\\033[0;32m'
RED='\\033[0;31m'
YELLOW='\\033[1;33m'
NC='\\033[0m' # No Color

# 计数器
total_checks=0
passed_checks=0
failed_checks=0

# 检查函数
check_file() {
  local file=$1
  local description=$2
  total_checks=$((total_checks + 1))
  
  if [ -f "$file" ]; then
    echo -e "${GREEN}✓${NC} $description"
    echo "  📍 $file"
    passed_checks=$((passed_checks + 1))
  else
    echo -e "${RED}✗${NC} $description"
    echo "  📍 $file (缺失)"
    failed_checks=$((failed_checks + 1))
  fi
}

echo "1️⃣  检查核心文件..."
echo "=================================="
check_file "forge.config.ts" "Electron Forge 配置"
check_file "electron/main/core/updateManager.ts" "自动更新管理器"
check_file ".env.forge.example" "环境变量模板"
check_file "scripts/verify-forge-migration.sh" "迁移验证脚本"
echo ""

echo "2️⃣  检查文档文件..."
echo "=================================="
check_file "ELECTRON_FORGE_MIGRATION.md" "完整迁移指南"
check_file "MIGRATION_CHECKLIST.md" "迁移清单"
check_file "FORGE_MIGRATION_SUMMARY.md" "迁移总结"
check_file "MIGRATION_COMPLETE.md" "完成报告"
check_file "CHANGELOG_FORGE_MIGRATION.md" "变更日志"
check_file "QUICK_REFERENCE.md" "快速参考"
check_file "FINAL_REPORT.md" "最终报告"
check_file "README_MIGRATION.md" "文档索引"
echo ""

echo "3️⃣  检查更新的代码文件..."
echo "=================================="
check_file "package.json" "项目配置"
check_file "electron/main/index.ts" "主进程"
check_file "electron/preload/index.ts" "预加载脚本"
check_file "electron/preload/types.ts" "类型定义"
check_file ".gitignore" "Git 忽略规则"
check_file ".github/workflows/release.yml" "GitHub Actions"
echo ""

echo "4️⃣  检查依赖项..."
echo "=================================="

# 检查 package.json 中的关键依赖
check_dependency() {
  local dep=$1
  local desc=$2
  total_checks=$((total_checks + 1))
  
  if grep -q "\"$dep\"" package.json; then
    echo -e "${GREEN}✓${NC} $desc"
    passed_checks=$((passed_checks + 1))
  else
    echo -e "${RED}✗${NC} $desc"
    failed_checks=$((failed_checks + 1))
  fi
}

check_dependency "@electron-forge/cli" "Electron Forge CLI"
check_dependency "@electron-forge/maker-squirrel" "Windows 打包工具"
check_dependency "@electron-forge/maker-dmg" "macOS DMG 打包工具"
check_dependency "@electron-forge/maker-rpm" "Linux RPM 打包工具"
check_dependency "@electron-forge/maker-deb" "Linux DEB 打包工具"
check_dependency "@electron-forge/publisher-github" "GitHub 发布工具"
check_dependency "electron-updater" "自动更新库"
echo ""

echo "5️⃣  检查构建脚本..."
echo "=================================="

check_script() {
  local script=$1
  local desc=$2
  total_checks=$((total_checks + 1))
  
  if grep -q "\"$script\":" package.json; then
    echo -e "${GREEN}✓${NC} $desc"
    passed_checks=$((passed_checks + 1))
  else
    echo -e "${RED}✗${NC} $desc"
    failed_checks=$((failed_checks + 1))
  fi
}

check_script "make" "npm 脚本: make"
check_script "publish" "npm 脚本: publish"
check_script "build:mac" "npm 脚本: build:mac"
check_script "build:win" "npm 脚本: build:win"
check_script "build:linux" "npm 脚本: build:linux"
echo ""

# 总结
echo "=========================================="
echo "📊 检查结果总结"
echo "=========================================="
echo -e "总检查项：$total_checks"
echo -e "${GREEN}通过：$passed_checks${NC}"
echo -e "${RED}失败：$failed_checks${NC}"
echo ""

if [ $failed_checks -eq 0 ]; then
  echo -e "${GREEN}✅ 所有检查通过！迁移已完成。${NC}"
  echo ""
  echo "📋 后续步骤："
  echo "1. 复制 .env.forge.example 到 .env.local"
  echo "2. 编辑 .env.local 填入实际值"
  echo "3. 运行 'pnpm install' 安装依赖"
  echo "4. 运行 'pnpm electron:dev' 进行测试"
  echo "5. 参考文档进行构建和发布"
  echo ""
  echo "📚 推荐阅读："
  echo "- QUICK_REFERENCE.md (快速参考)"
  echo "- ELECTRON_FORGE_MIGRATION.md (完整指南)"
  echo "- README_MIGRATION.md (文档索引)"
  exit 0
else
  echo -e "${RED}❌ 检查失败！请检查上述缺失的文件。${NC}"
  exit 1
fi

#!/bin/bash

# Electron Forge 迁移验证脚本

set -e

echo "🔍 Electron Forge 迁移验证"
echo "================================"
echo ""

# 检查必要的文件
echo "✅ 检查必要的文件..."

files_to_check=(
  "forge.config.ts"
  "electron/main/core/updateManager.ts"
  "ELECTRON_FORGE_MIGRATION.md"
  ".env.forge.example"
)

for file in "${files_to_check[@]}"; do
  if [ -f "$file" ]; then
    echo "  ✓ $file"
  else
    echo "  ✗ $file - 缺失！"
    exit 1
  fi
done

echo ""
echo "✅ 检查 package.json 依赖..."

# 检查 Electron Forge 依赖
required_deps=(
  "@electron-forge/cli"
  "@electron-forge/maker-squirrel"
  "@electron-forge/maker-dmg"
  "@electron-forge/maker-rpm"
  "@electron-forge/maker-deb"
  "@electron-forge/maker-zip"
  "@electron-forge/publisher-github"
  "@electron-forge/plugin-fuses"
)

for dep in "${required_deps[@]}"; do
  if grep -q "\"$dep\"" package.json; then
    echo "  ✓ $dep"
  else
    echo "  ✗ $dep - 缺失！"
    exit 1
  fi
done

echo ""
echo "✅ 检查构建脚本..."

scripts_to_check=(
  "make"
  "publish"
  "build:mac"
  "build:win"
  "build:linux"
)

for script in "${scripts_to_check[@]}"; do
  if grep -q "\"$script\":" package.json; then
    echo "  ✓ npm script: $script"
  else
    echo "  ✗ npm script: $script - 缺失！"
    exit 1
  fi
done

echo ""
echo "✅ 检查构建输出目录..."

if [ ! -d "out" ]; then
  echo "  ⚠️  ./out 目录不存在 (首次构建时会创建)"
else
  echo "  ✓ ./out 目录存在"
fi

echo ""
echo "================================"
echo "✅ 验证完成！所有必要的文件和配置都已就位。"
echo ""
echo "📋 后续步骤："
echo "1. 复制 .env.forge.example 到 .env.local 并填入实际的值"
echo "2. 运行 'pnpm install' 安装新的依赖"
echo "3. 运行 'pnpm make' 构建应用程序"
echo "4. 详见 ELECTRON_FORGE_MIGRATION.md"
echo ""

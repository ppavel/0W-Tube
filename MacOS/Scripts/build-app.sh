#!/bin/bash
set -e

APP_NAME="0W-Tube"
BUILD_DIR=".build/release"
BUNDLE_DIR="Build/$APP_NAME.app"

echo "🛠 Собираем релизный бинарник..."
swift build -c release

echo "📦 Создаем .app bundle..."
rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/Contents/MacOS"
mkdir -p "$BUNDLE_DIR/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$BUNDLE_DIR/Contents/MacOS/"
cp "Resources/Info.plist" "$BUNDLE_DIR/Contents/"

echo "🔏 Подписываем приложение (ad-hoc)..."
codesign --force --deep --sign - "$BUNDLE_DIR"

echo "✅ Готово! Запустить: open $BUNDLE_DIR"

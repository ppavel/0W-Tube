#!/bin/bash
set -e

APP_NAME="0W-Tube"
BUILD_DIR=".build/release"
BUNDLE_DIR="Build/$APP_NAME.app"
MACOS_MIN="12.0"   # должно совпадать с platforms в Package.swift

echo "🛠 Собираем релизный бинарник..."

# SwiftPM работает только при установленном Xcode: он безусловно запрашивает
# `xcrun --sdk macosx --show-sdk-platform-path`, а Command Line Tools такой
# путь отдать не могут. Поэтому при неудаче собираем компилятором напрямую.
if swift build -c release 2>/dev/null; then
    echo "   (собрано через SwiftPM)"
else
    echo "⚠️  SwiftPM недоступен (нет Xcode) — собираем через swiftc..."

    SDK="$(xcrun --sdk macosx --show-sdk-path)"
    TARGET="$(uname -m)-apple-macosx$MACOS_MIN"

    mkdir -p "$BUILD_DIR"
    swiftc \
        -sdk "$SDK" \
        -target "$TARGET" \
        -O \
        $(find Sources/App -name '*.swift') \
        -o "$BUILD_DIR/$APP_NAME"
fi

echo "📦 Создаем .app bundle..."
rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/Contents/MacOS"
mkdir -p "$BUNDLE_DIR/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$BUNDLE_DIR/Contents/MacOS/"
cp "Resources/Info.plist" "$BUNDLE_DIR/Contents/"

echo "🔏 Подписываем приложение (ad-hoc)..."
codesign --force --deep --sign - "$BUNDLE_DIR"

echo "✅ Готово! Запустить: open $BUNDLE_DIR"

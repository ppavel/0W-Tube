#!/bin/bash
set -e

APP_NAME="0W-Tube"
ARCHS=(arm64 x86_64)          # universal: Apple Silicon + Intel
OUT_DIR=".build/universal"    # сюда кладем склеенный lipo бинарник
BUNDLE_DIR="Build/$APP_NAME.app"
MACOS_MIN="12.0"   # должно совпадать с platforms в Package.swift и LSMinimumSystemVersion
MODULE_CACHE="$HOME/Library/Caches/0W-Tube/ModuleCache"

mkdir -p "$OUT_DIR"
SLICES=()

# SwiftPM умеет собирать только под одну архитектуру за раз: флаг --arch требует
# xcbuild из полного Xcode, которого при голых Command Line Tools нет. Поэтому
# гоняем сборку по разу на архитектуру через --triple и склеиваем сами.
for ARCH in "${ARCHS[@]}"; do
    TRIPLE="$ARCH-apple-macosx$MACOS_MIN"
    SLICE="$OUT_DIR/$APP_NAME-$ARCH"

    echo "🛠 Собираем релизный бинарник для $ARCH..."

    if swift build -c release --triple "$TRIPLE" 2>/dev/null; then
        echo "   (собрано через SwiftPM)"
        cp ".build/$ARCH-apple-macosx/release/$APP_NAME" "$SLICE"
    else
        echo "⚠️  SwiftPM недоступен (нет Xcode) — собираем через swiftc..."

        SDK="$(xcrun --sdk macosx --show-sdk-path)"
        NUM_CORES=$(sysctl -n hw.ncpu)

        swiftc \
            -sdk "$SDK" \
            -target "$TRIPLE" \
            -O \
            -wmo \
            -num-threads "$NUM_CORES" \
            -module-cache-path "$MODULE_CACHE" \
            $(find Sources/App -name '*.swift') \
            -Xfrontend -warn-long-function-bodies=50 \
            -Xfrontend -warn-long-expression-type-checking=50 \
            -o "$SLICE"
    fi

    SLICES+=("$SLICE")
done

echo "🔗 Склеиваем universal binary (${ARCHS[*]})..."
lipo -create -output "$OUT_DIR/$APP_NAME" "${SLICES[@]}"
lipo -info "$OUT_DIR/$APP_NAME"

echo "📦 Создаем .app bundle..."
rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/Contents/MacOS"
mkdir -p "$BUNDLE_DIR/Contents/Resources"

cp "$OUT_DIR/$APP_NAME" "$BUNDLE_DIR/Contents/MacOS/"
cp "Resources/Info.plist" "$BUNDLE_DIR/Contents/"

echo "🔏 Подписываем приложение (ad-hoc)..."
codesign --force --deep --sign - "$BUNDLE_DIR"

echo "✅ Готово! Запустить: open $BUNDLE_DIR"

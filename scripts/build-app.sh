#!/bin/bash
# Copyright © 2026 Alex Felizardo. Licença MIT: ver LICENSE.
# Gera dist/Toth.app (+ dist/Toth-<versão>.zip). Só precisa das Command Line Tools (sem Xcode).
#
# Variáveis opcionais:
#   VERSION=1.0.0  BUILD=1  BUNDLE_ID=io.github.lestatpirate.toth
#   SIGN_IDENTITY="Developer ID Application: …"   (por omissão: a identidade local "Toth Release Signing", se existir; senão "ad hoc")
#   Uma identidade estável (mesmo sendo própria, sem conta de programador) faz o macOS reconhecer a app entre versões e
#   manter a permissão de gravação de ecrã nas atualizações; com "ad hoc" cada versão pede-a de novo. Ver docs/DEVELOPMENT.md.
#   NOTARY_PROFILE=nome-do-perfil                  (só com Developer ID: notariza com `xcrun notarytool`)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.3.0}"
BUILD="${BUILD:-32}"
BUNDLE_ID="${BUNDLE_ID:-io.github.lestatpirate.toth}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"   # vazio: escolhe-se mais abaixo (identidade local, senão ad hoc)
APP="dist/Toth.app"

echo "==> 1/5 Compilar (release)"
if swift build -c release --arch arm64 --arch x86_64 >/dev/null 2>build-universal.log; then
  BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
  echo "    binário universal (Apple Silicon + Intel)"
else
  echo "    (universal indisponível, a compilar só para esta arquitetura; ver build-universal.log)"
  swift build -c release
  BIN_DIR="$(swift build -c release --show-bin-path)"
fi
rm -f build-universal.log
BIN="$BIN_DIR/Toth"
[ -x "$BIN" ] || { echo "Executável não encontrado em $BIN_DIR"; exit 1; }
lipo -archs "$BIN" | sed 's/^/    arquiteturas: /'

echo "==> 2/5 Montar $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Toth"
cp docs/brand/Toth.icns "$APP/Contents/Resources/Toth.icns"
cp Sources/CaptureApp/Resources/toth-logo.png "$APP/Contents/Resources/toth-logo.png"
cp LICENSE LICENSE.pt.md TRADEMARKS.md PRIVACY.md THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>pt</string>
  <key>CFBundleLocalizations</key><array><string>pt</string><string>en</string></array>
  <key>CFBundleExecutable</key><string>Toth</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleName</key><string>Toth</string>
  <key>CFBundleDisplayName</key><string>Toth</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>Toth</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.graphics-design</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>${BUNDLE_ID}.capture</string>
      <key>UTTypeDescription</key><string>Captura do Toth</string>
      <key>UTTypeConformsTo</key><array><string>public.data</string></array>
      <key>UTTypeIconFile</key><string>Toth.icns</string>
      <key>UTTypeTagSpecification</key>
      <dict>
        <key>public.filename-extension</key><array><string>capture</string></array>
        <key>public.mime-type</key><string>application/x-toth-capture</string>
      </dict>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Captura do Toth</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Owner</string>
      <key>LSItemContentTypes</key><array><string>${BUNDLE_ID}.capture</string></array>
      <key>CFBundleTypeIconFile</key><string>Toth</string>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Imagem</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.png</string><string>public.jpeg</string><string>public.tiff</string>
        <string>public.heic</string><string>com.compuserve.gif</string><string>com.microsoft.bmp</string>
      </array>
    </dict>
  </array>
  <key>NSMicrophoneUsageDescription</key><string>O Toth só grava o microfone quando liga essa opção na gravação de vídeo. / Toth only records the microphone when you turn that option on while recording video.</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 Alex Felizardo. Licença MIT.</string>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist"

# Identidade de assinatura: a indicada; senão a local "Toth Release Signing" (keychain própria, fora do repositório); senão ad hoc.
SIGN_KEYCHAIN=""
if [ -z "${SIGN_IDENTITY:-}" ]; then
  KC="$HOME/Library/Keychains/toth-signing.keychain-db"
  SIGN_IDENTITY="-"
  if [ -f "$KC" ] && security unlock-keychain -p "${TOTH_SIGN_KEYCHAIN_PASSWORD:-tothkc}" "$KC" 2>/dev/null; then
    FOUND="$(security find-identity -p codesigning "$KC" 2>/dev/null || true)"   # (sem `grep -q` num pipe: o pipefail falharia)
    case "$FOUND" in *"Toth Release Signing"*) SIGN_IDENTITY="Toth Release Signing"; SIGN_KEYCHAIN="$KC" ;; esac
  fi
fi
echo "==> 3/5 Assinar (${SIGN_IDENTITY/#-/ad hoc})"
if [ "$SIGN_IDENTITY" = "-" ]; then
  codesign --force --deep --options runtime --entitlements scripts/Toth.entitlements --sign - "$APP"
elif [ -n "$SIGN_KEYCHAIN" ]; then
  codesign --force --deep --options runtime --entitlements scripts/Toth.entitlements --keychain "$SIGN_KEYCHAIN" --sign "$SIGN_IDENTITY" "$APP"
else
  codesign --force --deep --options runtime --entitlements scripts/Toth.entitlements --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --deep --strict "$APP" && echo "    assinatura válida"

echo "==> 4/5 Comprimir"
ZIP="dist/Toth-${VERSION}.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

if [ -n "${NOTARY_PROFILE:-}" ] && [ "$SIGN_IDENTITY" != "-" ]; then
  echo "==> Notarizar"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"; ditto -c -k --keepParent "$APP" "$ZIP"
fi

echo "==> 5/5 Resultado"
shasum -a 256 "$ZIP" | tee "dist/Toth-${VERSION}.zip.sha256"
du -sh "$APP" "$ZIP"

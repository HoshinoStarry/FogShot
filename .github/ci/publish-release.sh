#!/usr/bin/env bash
set -euo pipefail

cd "$1"
assets=(
  FogShot-windows-x64.zip
  FogShot-windows-arm64.zip
  FogShot-linux-x64.tar.gz
  FogShot-linux-arm64.tar.gz
  FogShot-macos-universal.dmg
  FogShot-ios-arm64-unsigned.ipa
  FogShot-android-armeabi-v7a.apk
  FogShot-android-arm64-v8a.apk
  FogShot-android-x86_64.apk
)
for asset in "${assets[@]}"; do
  if [[ ! -s "$asset" ]]; then
    printf 'Release is missing %s\n' "$asset" >&2
    exit 1
  fi
done

case "$GITHUB_REF" in
  refs/heads/main)
    tag="build-${GITHUB_SHA:0:12}"
    title="FogShot ${tag#build-}"
    options=(--prerelease --target "$GITHUB_SHA")
    ;;
  refs/tags/v*)
    tag="$GITHUB_REF_NAME"
    title="FogShot $tag"
    options=(--verify-tag)
    ;;
  *)
    printf 'Ref is ineligible for publication: %s\n' "$GITHUB_REF" >&2
    exit 1
    ;;
esac

repo="$GITHUB_REPOSITORY"
if is_draft="$(gh release view "$tag" --repo "$repo" --json isDraft --jq .isDraft 2>/dev/null)"; then
  if [[ "$is_draft" == false ]]; then
    printf '%s is already published.\n' "$tag"
    exit 0
  fi
  test "$is_draft" = true
  gh release upload "$tag" "${assets[@]}" --repo "$repo" --clobber
else
  notes="$(mktemp)"
  trap 'rm -f -- "$notes"' EXIT
  cat > "$notes" <<EOF
构建提交 $GITHUB_SHA · [Actions 记录]($GITHUB_SERVER_URL/$repo/actions/runs/$GITHUB_RUN_ID)

- macOS 通用 DMG 内含 FogShot.app 与 Applications 快捷入口。
- iOS IPA 为未签名的 ARM64 真机包，安装前需要签名。
- Android 提供 ARMv7、ARM64 和 x86_64 APK。CI 使用调试签名。
EOF
  gh release create "$tag" "${assets[@]}" --repo "$repo" --draft \
    --title "$title" --notes-file "$notes" "${options[@]}"
fi

gh release edit "$tag" --repo "$repo" --draft=false

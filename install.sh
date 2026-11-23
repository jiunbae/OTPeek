#!/usr/bin/env sh
# OTPeek CLI installer — downloads the `otpeek` binary from GitHub Releases.
#
#   curl -fsSL https://raw.githubusercontent.com/jiunbae/OTPeek/main/install.sh | sh
#
# Environment overrides:
#   OTPEEK_VERSION   release tag to install         (default: latest)
#   OTPEEK_BIN_DIR   install directory              (default: $HOME/.local/bin)
#
# Supports Linux and macOS on x86_64 / aarch64. Windows users: install the app,
# or build from source (`cargo install --path core/crates/otpeek-cli`).
set -eu

REPO="jiunbae/OTPeek"
BIN="otpeek"
VERSION="${OTPEEK_VERSION:-latest}"
BIN_DIR="${OTPEEK_BIN_DIR:-$HOME/.local/bin}"

err()  { printf 'otpeek-install: error: %s\n' "$1" >&2; exit 1; }
info() { printf 'otpeek-install: %s\n' "$1" >&2; }

command -v curl >/dev/null 2>&1 || err "curl is required"
command -v tar  >/dev/null 2>&1 || err "tar is required"

if command -v sha256sum >/dev/null 2>&1; then
  set -- sha256sum
elif command -v shasum >/dev/null 2>&1; then
  set -- shasum -a 256
else
  err "sha256sum or shasum is required"
fi

os="$(uname -s)"
arch="$(uname -m)"

case "$os" in
  Linux)  os_t="unknown-linux-gnu" ;;
  Darwin) os_t="apple-darwin" ;;
  *) err "unsupported OS '$os' — Linux and macOS only (Windows: use the app or build from source)" ;;
esac

case "$arch" in
  x86_64|amd64)   arch_t="x86_64" ;;
  aarch64|arm64)  arch_t="aarch64" ;;
  *) err "unsupported architecture '$arch'" ;;
esac

target="${arch_t}-${os_t}"
asset="${BIN}-${target}.tar.gz"

if [ "$VERSION" = "latest" ]; then
  base="https://github.com/${REPO}/releases/latest/download"
else
  base="https://github.com/${REPO}/releases/download/${VERSION}"
fi
url="${base}/${asset}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

info "downloading ${asset} (${VERSION})"
curl -fsSL "$url" -o "$tmp/$asset" \
  || err "download failed: $url — is there a published release with this asset?"

info "verifying checksum"
curl -fsSL "${url}.sha256" -o "$tmp/$asset.sha256" \
  || err "checksum download failed: ${url}.sha256"
expected="$(awk -v asset="$asset" '
  NR == 1 && NF == 2 && ($2 == asset || $2 == "*" asset) &&
      length($1) == 64 && $1 !~ /[^0-9a-fA-F]/ { digest = tolower($1) }
  END { if (NR != 1 || digest == "") exit 1; print digest }
' "$tmp/$asset.sha256")" || err "invalid checksum for $asset"
actual="$("$@" "$tmp/$asset")" || err "could not compute checksum for $asset"
[ "${actual%% *}" = "$expected" ] || err "checksum mismatch for $asset"

tar -xzf "$tmp/$asset" -C "$tmp"
src="$tmp/${BIN}-${target}/${BIN}"
[ -f "$src" ] || src="$(find "$tmp" -type f -name "$BIN" 2>/dev/null | head -n1)"
[ -n "${src:-}" ] && [ -f "$src" ] || err "binary '$BIN' not found in archive"

mkdir -p "$BIN_DIR"
if install -m 0755 "$src" "$BIN_DIR/$BIN" 2>/dev/null; then
  :
else
  cp "$src" "$BIN_DIR/$BIN" && chmod 0755 "$BIN_DIR/$BIN"
fi

info "installed to $BIN_DIR/$BIN"
"$BIN_DIR/$BIN" --version 2>/dev/null || true

case ":$PATH:" in
  *":$BIN_DIR:"*) : ;;
  *)
    info "note: $BIN_DIR is not on your PATH. Add it, e.g.:"
    info "  echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> ~/.profile && exec \$SHELL"
    ;;
esac

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

# Verify the SHA-256 sum when the release ships one (it always does via CI).
if curl -fsSL "${url}.sha256" -o "$tmp/$asset.sha256" 2>/dev/null; then
  info "verifying checksum"
  if command -v shasum >/dev/null 2>&1; then
    ( cd "$tmp" && shasum -a 256 -c "$asset.sha256" >/dev/null 2>&1 ) || err "checksum mismatch"
  elif command -v sha256sum >/dev/null 2>&1; then
    ( cd "$tmp" && sha256sum -c "$asset.sha256" >/dev/null 2>&1 ) || err "checksum mismatch"
  else
    info "no shasum/sha256sum available — skipping checksum verification"
  fi
fi

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

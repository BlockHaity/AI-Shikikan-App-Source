#!/usr/bin/env bash
set -euo pipefail

# 把 package-modules.sh 产出的系统包组织成可直接使用的软件源:
#   apt     dists/stable + pool/main
#   rpm     rpm/<arch>/repodata
#   pacman  pacman/<arch>/ai-shikikan.db.tar.gz
#
# 环境变量:
#   DIST      系统包目录 (默认 <repo>/dist)
#   PUBLIC    静态源输出目录 (默认 <repo>/public)
#   PAGES_URL GitHub Pages 地址, 用于生成 index.html 中的安装说明
#   VERSION   当前版本 (仅用于页面展示)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="${DIST:-$ROOT/dist}"
PUBLIC="${PUBLIC:-$ROOT/public}"
PAGES_URL="${PAGES_URL:-}"
VERSION="${VERSION:-}"

# 相对路径按仓库根解析; docker -v 需要绝对路径
case "$DIST"   in /*) ;; *) DIST="$ROOT/$DIST" ;; esac
case "$PUBLIC" in /*) ;; *) PUBLIC="$ROOT/$PUBLIC" ;; esac

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()  { err "$*"; exit 1; }

[ -d "$DIST" ] || die "系统包目录不存在: $DIST"
command -v dpkg-scanpackages >/dev/null || die "缺少 dpkg-scanpackages (apt-get install dpkg-dev)"
command -v createrepo_c >/dev/null || die "缺少 createrepo_c (apt-get install createrepo-c)"

rm -rf "$PUBLIC"
mkdir -p "$PUBLIC"/dists/stable/main/binary-{amd64,arm64}

# ---------- apt ----------
info "== 生成 apt 源 =="
for deb in "$DIST"/*.deb; do
    [ -e "$deb" ] || continue
    name="$(dpkg-deb -f "$deb" Package)"
    mkdir -p "$PUBLIC/pool/main/$name"
    cp "$deb" "$PUBLIC/pool/main/$name/"
done

release_block() {
    local label="$1" rel
    shift
    echo "$label:"
    for rel in "$@"; do
        [ -f "$PUBLIC/dists/stable/$rel" ] || continue
        printf ' %s %s %s\n' \
            "$(md5sum "$PUBLIC/dists/stable/$rel" | cut -d' ' -f1)" \
            "$(stat -c%s "$PUBLIC/dists/stable/$rel")" "$rel"
    done
}
sha1_block() {
    local label="$1" rel
    shift
    echo "$label:"
    for rel in "$@"; do
        [ -f "$PUBLIC/dists/stable/$rel" ] || continue
        printf ' %s %s %s\n' \
            "$(sha1sum "$PUBLIC/dists/stable/$rel" | cut -d' ' -f1)" \
            "$(stat -c%s "$PUBLIC/dists/stable/$rel")" "$rel"
    done
}
sha256_block() {
    local label="$1" rel
    shift
    echo "$label:"
    for rel in "$@"; do
        [ -f "$PUBLIC/dists/stable/$rel" ] || continue
        printf ' %s %s %s\n' \
            "$(sha256sum "$PUBLIC/dists/stable/$rel" | cut -d' ' -f1)" \
            "$(stat -c%s "$PUBLIC/dists/stable/$rel")" "$rel"
    done
}

for arch in amd64 arm64; do
    dir="$PUBLIC/dists/stable/main/binary-$arch"
    ( cd "$PUBLIC" && dpkg-scanpackages --arch "$arch" pool/main /dev/null > "$dir/Packages" )
    gzip -9 -c "$dir/Packages" > "$dir/Packages.gz"

    {
        echo "Origin: AI-Shikikan"
        echo "Label: AI-Shikikan"
        echo "Suite: stable"
        echo "Codename: stable"
        echo "Date: $(date -Ru)"
        echo "Architectures: $arch"
        echo "Components: main"
        echo "Description: AI-Shikikan package repository"
        release_block MD5Sum "main/binary-$arch/Packages" "main/binary-$arch/Packages.gz"
        sha1_block SHA1Sum "main/binary-$arch/Packages" "main/binary-$arch/Packages.gz"
        sha256_block SHA256Sum "main/binary-$arch/Packages" "main/binary-$arch/Packages.gz"
    } > "$dir/Release"
done

{
    echo "Origin: AI-Shikikan"
    echo "Label: AI-Shikikan"
    echo "Suite: stable"
    echo "Codename: stable"
    echo "Date: $(date -Ru)"
    echo "Architectures: amd64 arm64"
    echo "Components: main"
    echo "Description: AI-Shikikan package repository"
    release_block MD5Sum main/binary-amd64/Packages main/binary-amd64/Packages.gz main/binary-arm64/Packages main/binary-arm64/Packages.gz
    sha1_block SHA1Sum main/binary-amd64/Packages main/binary-amd64/Packages.gz main/binary-arm64/Packages main/binary-arm64/Packages.gz
    sha256_block SHA256Sum main/binary-amd64/Packages main/binary-amd64/Packages.gz main/binary-arm64/Packages main/binary-arm64/Packages.gz
} > "$PUBLIC/dists/stable/Release"
ok "apt: dists/stable"

# ---------- rpm ----------
info "== 生成 rpm 源 =="
mkdir -p "$PUBLIC/rpm"/{x86_64,aarch64}
for rpm in "$DIST"/*.rpm; do
    [ -e "$rpm" ] || continue
    case "$rpm" in
        *.x86_64.rpm)   cp "$rpm" "$PUBLIC/rpm/x86_64/" ;;
        *.aarch64.rpm)  cp "$rpm" "$PUBLIC/rpm/aarch64/" ;;
        *) err "未知 rpm 架构: $rpm"; exit 1 ;;
    esac
done
for arch in x86_64 aarch64; do
    if compgen -G "$PUBLIC/rpm/$arch/*.rpm" >/dev/null; then
        createrepo_c "$PUBLIC/rpm/$arch" >/dev/null
        ok "rpm:  rpm/$arch/repodata"
    fi
done

# ---------- pacman ----------
info "== 生成 pacman 源 =="
mkdir -p "$PUBLIC/pacman"/{x86_64,aarch64}
for pkg in "$DIST"/*.pkg.tar.zst; do
    [ -e "$pkg" ] || continue
    case "$pkg" in
        *-x86_64.pkg.tar.zst)  cp "$pkg" "$PUBLIC/pacman/x86_64/" ;;
        *-aarch64.pkg.tar.zst) cp "$pkg" "$PUBLIC/pacman/aarch64/" ;;
        *) err "未知 pacman 架构: $pkg"; exit 1 ;;
    esac
done
for arch in x86_64 aarch64; do
    dir="$PUBLIC/pacman/$arch"
    compgen -G "$dir/*.pkg.tar.zst" >/dev/null || continue
    command -v docker >/dev/null || die "缺少 docker (pacman 数据库需要 repo-add)"
    docker run --rm -v "$dir:/repo" archlinux:latest \
        bash -c 'cd /repo && repo-add --quiet ai-shikikan.db.tar.gz *.pkg.tar.zst'
    ok "pacman: pacman/$arch/ai-shikikan.db.tar.gz"
done

# ---------- 首页 ----------
cat > "$PUBLIC/index.html" <<EOF
<!doctype html>
<html lang="zh-CN">
<meta charset="utf-8">
<title>AI-Shikikan 软件源</title>
<style>body{font:15px/1.6 system-ui,sans-serif;max-width:760px;margin:40px auto;padding:0 16px}code,pre{background:#f2f2f2;border-radius:6px}pre{padding:12px;overflow:auto}</style>
<h1>AI-Shikikan 软件源</h1>
<p>当前版本: <code>${VERSION}</code></p>
<h2>Debian / Ubuntu</h2>
<pre>echo "deb [trusted=yes] ${PAGES_URL}/ stable main" | sudo tee /etc/apt/sources.list.d/ai-shikikan.list
sudo apt update
sudo apt install ai-shikikan-gui</pre>
<h2>Fedora / RHEL</h2>
<pre>[ai-shikikan]
name=AI-Shikikan
baseurl=${PAGES_URL}/rpm/\$basearch
enabled=1
gpgcheck=0</pre>
<h2>Arch Linux / Manjaro</h2>
<pre>[ai-shikikan]
Server = ${PAGES_URL}/pacman/\$arch</pre>
<p>模块依赖: <code>ai-shikikan-gui</code> → <code>ai-shikikan-core</code> → <code>ai-shikikan-worker</code></p>
</html>
EOF
ok "index.html"

info "软件源输出: $PUBLIC"

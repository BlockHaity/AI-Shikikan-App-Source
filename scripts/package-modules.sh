#!/usr/bin/env bash
set -euo pipefail

# 按主仓库发布的 index.json, 把 dotnet 变体的完整应用归档拆成三个独立系统包:
#   ai-shikikan-worker  基础包: worker/ 可执行树
#   ai-shikikan-core    依赖 worker: AIShikikan.Core.dll
#   ai-shikikan-gui     依赖 core: GUI 主体 + 桌面入口
#
# 之所以只用 dotnet 变体: AOT 会把 Core 静态链接进可执行文件, 没有可独立
# 拆分的 Core.dll, 拆包只会得到空包; Linux 归档也不再提供 selfcontained 变体,
# 运行时统一由系统包依赖 (dotnet-runtime) 提供。
#
# 环境变量:
#   VERSION     必填, 如 1.0.0-vibe
#   INDEX       必填, 主仓库发布资产 index.json
#   APP_DIR     必填, 某一 RID 的完整应用归档解压目录
#   RID         必填, linux-x64 / linux-arm64
#   OUT_DIR     默认 dist
#   FORMATS     默认 "deb rpm pacman"
#   HOMEPAGE / MAINTAINER 可选
#
# 用法:
#   VERSION=1.0.0-vibe INDEX=downloads/index.json APP_DIR=app/linux-x64 RID=linux-x64 \
#     ./scripts/package-modules.sh

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSETS="$ROOT/assets"

PKG="ai-shikikan"
DESC="AI-Shikikan is an Agent commander: it orchestrates terminal AI agents such as Claude Code, OpenCode, Codex CLI and Gemini CLI to complete complex tasks."
DEFAULT_HOMEPAGE="https://github.com/BlockHaity/AI-Shikikan"
DEFAULT_MAINTAINER="BlockHaity <blockhaity@users.noreply.github.com>"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()  { err "$*"; exit 1; }

VERSION="${VERSION:-}"
INDEX="${INDEX:-}"
APP_DIR="${APP_DIR:-}"
RID="${RID:-}"
OUT_DIR="${OUT_DIR:-$ROOT/dist}"
FORMATS="${FORMATS:-deb rpm pacman}"
HOMEPAGE="${HOMEPAGE:-$DEFAULT_HOMEPAGE}"
MAINTAINER="${MAINTAINER:-$DEFAULT_MAINTAINER}"

[ -n "$VERSION" ] || die "缺少 VERSION"
[ -f "$INDEX" ]   || die "缺少 INDEX (index.json): $INDEX"
[ -d "$APP_DIR" ] || die "缺少 APP_DIR (归档解压目录): $APP_DIR"

case "$RID" in
    linux-x64)   DEB_ARCH=amd64;  PKG_ARCH=x86_64 ;;
    linux-arm64) DEB_ARCH=arm64;  PKG_ARCH=aarch64 ;;
    *) die "不支持的 RID '$RID' (只支持 linux-x64 / linux-arm64)" ;;
esac

# Debian 版本不允许下划线, '-' 换成 '~' 是预发布惯例
DEB_VER="${VERSION//-/\~}"
# rpm / pacman 的 Version 不允许 '-', 换成 '_'
PVER="${VERSION//-/_}"

[[ "$DEB_VER" =~ ^[0-9A-Za-z.+~:-]+$ ]] || die "非法 DEB_VER='$DEB_VER'"
[[ "$PVER" =~ ^[0-9A-Za-z._+]+$ ]]      || die "非法 PVER='$PVER'"

mkdir -p "$OUT_DIR"
OUT_ABS="$(cd "$OUT_DIR" && pwd)"

WORK_TMP="$(mktemp -d)"
cleanup() { rm -rf "$WORK_TMP"; }
trap cleanup EXIT

# ---------- 从 index.json 取出该 RID 的模块文件清单 ----------
python3 - "$INDEX" "$RID" "$WORK_TMP" <<'PY'
import json, os, sys
index_path, rid, outdir = sys.argv[1], sys.argv[2], sys.argv[3]
index = json.load(open(index_path, encoding="utf-8"))
candidates = [
    a for a in index.get("artifacts", [])
    if a.get("rid") == rid and a.get("variant") == "dotnet" and a.get("configuration") in (None, "Release")
]
if not candidates:
    sys.exit(f"index.json 中没有 {rid} 的 dotnet 归档, 无法拆分模块包")
art = candidates[0]
for mod in ("worker", "core", "gui"):
    files = art.get("moduleFiles", {}).get(mod, [])
    with open(os.path.join(outdir, f"{mod}.list"), "w", encoding="utf-8") as f:
        f.write("\n".join(files))
        if files:
            f.write("\n")
    print(f"  {mod}: {len(files)} 个文件 (来自 {art['file']})")
PY

[ -s "$WORK_TMP/core.list" ] || die "index.json 中 core 模块没有文件 (需要 dotnet 变体归档才能拆出独立的 Core.dll)"

# ---------- 暂存目录 ----------
# 所有模块文件都落到 <prefix>/lib/ai-shikikan 下, worker 保持 worker/ 子目录布局,
# 与主仓库 GUI 的 WorkerLocator 候选 3 一致。
stage_tree() {
    local module="$1"
    local tree="$WORK_TMP/tree-$module"
    local rel
    mkdir -p "$tree/usr/lib/$PKG"
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        [ -f "$APP_DIR/$rel" ] || die "归档缺少文件: $APP_DIR/$rel"
        install -Dm644 "$APP_DIR/$rel" "$tree/usr/lib/$PKG/$rel"
    done < "$WORK_TMP/$module.list"
    find "$tree/usr/lib/$PKG" -name '*.pdb' -delete
    chmod 755 "$tree/usr/lib/$PKG/AIShikikan.Gui" 2>/dev/null || true
    chmod 755 "$tree/usr/lib/$PKG/worker/AIShikikan.Worker" 2>/dev/null || true
    echo "$tree"
}

# ---------- 运行时依赖 ----------
DEB_X11="libx11-6, libxcursor1, libxrandr2, libxrender1, libxext6, libxfixes3, libxi6, libice6, libsm6, libxkbcommon0, libgl1, libglib2.0-0t64 | libglib2.0-0, libfontconfig1, libfreetype6"
DEB_ICU="libicu78 | libicu76 | libicu75 | libicu74 | libicu73 | libicu72 | libicu71 | libicu70 | libicu69 | libicu68 | libicu67 | libicu66"
# .NET 运行时包名: Linux 归档不带运行时, 由包管理器按这里的名称安装。
# 升级 .NET 大版本时同步修改这三处 (Debian/RHEL 用版本化包名, Arch 用元包)。
DEB_RUNTIME="dotnet-runtime-10.0"

RPM_X11="libX11, libXcursor, libXrandr, libXrender, libXext, libXfixes, libXi, libICE, libSM, libxkbcommon, mesa-libGL, glib2, fontconfig, freetype"
RPM_ICU="libicu"
RPM_RUNTIME="dotnet-runtime-10.0"

PAC_X11=("libx11" "libxcursor" "libxrandr" "libxrender" "libxext" "libxfixes" "libxi" "libice" "libsm" "libxkbcommon" "libglvnd" "mesa" "fontconfig" "glib2")
PAC_ICU="icu"
PAC_RUNTIME="dotnet-runtime"

# ---------- deb ----------
build_deb() {
    local module="$1" tree="$2"
    local name="$PKG-$module"
    local debroot="$tree"
    local depends="$3" recommends="$4"

    mkdir -p "$debroot/usr/share/doc/$name"
    install -Dm644 "$ROOT/LICENSE" "$debroot/usr/share/doc/$name/copyright"

    local size
    size="$(du -sk "$debroot" | cut -f1)"
    mkdir -p "$debroot/DEBIAN"
    {
        echo "Package: $name"
        echo "Version: $DEB_VER"
        echo "Architecture: $DEB_ARCH"
        echo "Maintainer: $MAINTAINER"
        echo "Installed-Size: $size"
        [ -n "$depends" ] && echo "Depends: $depends"
        [ -n "$recommends" ] && echo "Recommends: $recommends"
        echo "Section: utils"
        echo "Priority: optional"
        echo "Homepage: $HOMEPAGE"
        echo "Description: AI Agent commander desktop app ($module module)"
        echo " $DESC"
    } > "$debroot/DEBIAN/control"
    printf '\n' >> "$debroot/DEBIAN/control"

    dpkg-deb --build --root-owner-group "$debroot" "$OUT_ABS/${name}_${DEB_VER}_${DEB_ARCH}.deb" >/dev/null
    ok "deb:   ${name}_${DEB_VER}_${DEB_ARCH}.deb"
}

# ---------- rpm ----------
build_rpm() {
    local module="$1" tree="$2"
    local name="$PKG-$module"
    local requires="$3" recommends="$4"

    mkdir -p "$HOME/rpmbuild"/{BUILD,RPMS,SPECS,SOURCES,SRPMS}
    rm -rf "$HOME/rpmbuild"/RPMS/*
    local spec="$HOME/rpmbuild/SPECS/$name.spec"

    {
        cat <<EOF
%global debug_package %{nil}
%undefine _missing_build_ids_terminate_build

Name:     $name
Version:  $PVER
Release:  1
Summary:  AI Agent commander desktop app ($module module)
License:  MIT
URL:      $HOMEPAGE
AutoReqProv: no
EOF
        [ -n "$requires" ] && echo "Requires: $requires"
        [ -n "$recommends" ] && echo "Recommends: $recommends"
        cat <<EOF

%description
$DESC

%install
rm -rf %{buildroot}
mkdir -p %{buildroot}
cp -a $tree/. %{buildroot}/

%files
EOF
        find "$tree" \( -type f -o -type l \) -printf '/%P\n' | sort
    } > "$spec"

    rpmbuild -bb --target "$PKG_ARCH" "$spec" >/dev/null
    local r
    for r in "$HOME"/rpmbuild/RPMS/*/*.rpm; do
        [ -e "$r" ] || continue
        cp -f "$r" "$OUT_ABS/${r##*/}"
        ok "rpm:   ${r##*/}"
    done
}

# ---------- pacman ----------
build_pacman() {
    local module="$1" tree="$2"
    local name="$PKG-$module"
    local depends=()
    if [ "$#" -gt 2 ]; then depends=("${@:3}"); fi

    local pkgsize
    pkgsize="$(du -sb "$tree" | cut -f1)"
    {
        echo "# Generated by app-source/scripts/package-modules.sh"
        echo "pkgname = $name"
        echo "pkgver = $PVER-1"
        echo "pkgdesc = AI Agent commander desktop app ($module module)"
        echo "url = $HOMEPAGE"
        echo "builddate = $(date +%s)"
        echo "packager = GitHub Actions"
        echo "size = $pkgsize"
        echo "arch = $PKG_ARCH"
        echo "license = MIT"
        local d
        for d in "${depends[@]}"; do
            [ -n "$d" ] && echo "depend = $d"
        done
    } > "$tree/.PKGINFO"

    tar --zstd -cf "$OUT_ABS/${name}-${PVER}-1-${PKG_ARCH}.pkg.tar.zst" \
        -C "$tree" .PKGINFO usr
    ok "pacman: ${name}-${PVER}-1-${PKG_ARCH}.pkg.tar.zst"
}

# ---------- 主流程 ----------
info "版本: $VERSION (deb=$DEB_VER, rpm/pacman=$PVER)"
info "RID:  $RID (deb=$DEB_ARCH, rpm/pacman=$PKG_ARCH)"
info "输入: $APP_DIR (按 $INDEX 拆分)"
info "输出: $OUT_ABS"

TREE_WORKER="$(stage_tree worker)"
TREE_CORE="$(stage_tree core)"
TREE_GUI="$(stage_tree gui)"

# GUI 的桌面入口与图标只属于 gui 包
mkdir -p "$TREE_GUI/usr/bin"
ln -sf "/usr/lib/$PKG/AIShikikan.Gui" "$TREE_GUI/usr/bin/$PKG"
install -Dm644 "$ASSETS/ai-shikikan.desktop" "$TREE_GUI/usr/share/applications/$PKG.desktop"
convert "$ASSETS/logo.jpg" -resize 256x256 "$WORK_TMP/$PKG.png"
install -Dm644 "$WORK_TMP/$PKG.png" "$TREE_GUI/usr/share/icons/hicolor/256x256/apps/$PKG.png"

for format in $FORMATS; do
    case "$format" in
        deb)
            # 运行时依赖挂在基础包 worker 上, gui → core → worker 的链式依赖即可覆盖
            build_deb worker "$TREE_WORKER" "$DEB_RUNTIME" ""
            build_deb core   "$TREE_CORE"   "$PKG-worker (= $DEB_VER)" ""
            build_deb gui    "$TREE_GUI"    "$PKG-core (= $DEB_VER), $DEB_X11" "$DEB_ICU"
            ;;
        rpm)
            build_rpm worker "$TREE_WORKER" "$RPM_RUNTIME" ""
            build_rpm core   "$TREE_CORE"   "$PKG-worker = $PVER" ""
            build_rpm gui    "$TREE_GUI"    "$PKG-core = $PVER, $RPM_X11" "$RPM_ICU"
            ;;
        pacman)
            build_pacman worker "$TREE_WORKER" "$PAC_RUNTIME"
            build_pacman core   "$TREE_CORE"   "$PKG-worker"
            build_pacman gui    "$TREE_GUI"    "$PKG-core" "${PAC_X11[@]}" "$PAC_ICU"
            ;;
        *) die "未知包格式 '$format' (合法值: deb / rpm / pacman)" ;;
    esac
done

ok "模块包构建完成"

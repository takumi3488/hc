#!/bin/sh
# Install a released hc binary without changing shell profiles or requiring sudo.
set -eu

repository=https://github.com/takumi3488/hc

fail() {
    printf 'hc installer: %s\n' "$*" >&2
    exit 1
}

unsupported_platform() {
    fail "cannot select an unambiguous released target for uname -s='$system' uname -m='$machine'; set HC_TARGET to an available release triple"
}

linux_libc() {
    libc_info=
    if command -v getconf >/dev/null 2>&1; then
        libc_info=$(getconf GNU_LIBC_VERSION 2>/dev/null || :)
    fi
    case "$libc_info" in
        'glibc '*) printf gnu; return 0 ;;
        'musl '*) printf musl; return 0 ;;
    esac
    if command -v ldd >/dev/null 2>&1; then
        libc_info=$(ldd --version 2>&1 || :)
        case "$libc_info" in
            *musl*) printf musl; return 0 ;;
            *GLIBC*|*'GNU libc'*) printf gnu; return 0 ;;
        esac
    fi
    return 1
}

require_linux_libc() {
    expected_libc=$1
    if ! host_libc=$(linux_libc); then
        fail "cannot determine the Linux libc ABI for uname -m='$machine'; set HC_TARGET explicitly"
    fi
    if [ "$host_libc" != "$expected_libc" ]; then
        fail "native Linux libc is '$host_libc', but target '$target' requires '$expected_libc'; set HC_TARGET explicitly only if you intend to install a non-native binary"
    fi
}

if [ -n "${HC_TARGET:-}" ]; then
    target=$HC_TARGET
else
    if ! system=$(uname -s) || ! machine=$(uname -m); then
        fail 'could not determine the native operating system and CPU; set HC_TARGET to an available release triple'
    fi
    case "$system" in
        Darwin)
            case "$machine" in
                x86_64|amd64) target=x86_64-macos-none ;;
                aarch64|arm64) target=aarch64-macos-none ;;
                *) unsupported_platform ;;
            esac
            ;;
        Linux)
            case "$machine" in
                x86_64|amd64) target=x86_64-linux-musl ;;
                aarch64|arm64) target=aarch64-linux-musl ;;
                aarch64_be) target=aarch64_be-linux-gnu; require_linux_libc gnu ;;
                hexagon) target=hexagon-linux-gnu; require_linux_libc gnu ;;
                loongarch32) target=loongarch32-linux-gnu; require_linux_libc gnu ;;
                loongarch64) target=loongarch64-linux-gnu; require_linux_libc gnu ;;
                mips) target=mips-linux-gnu; require_linux_libc gnu ;;
                mipsel) target=mipsel-linux-gnu; require_linux_libc gnu ;;
                mips64) target=mips64-linux-gnu; require_linux_libc gnu ;;
                mips64el) target=mips64el-linux-gnu; require_linux_libc gnu ;;
                powerpc|ppc) target=powerpc-linux-musleabi; require_linux_libc musl ;;
                powerpc64|ppc64) target=powerpc64-linux-musl ;;
                powerpc64le|ppc64le) target=powerpc64le-linux-musl ;;
                riscv32) target=riscv32-linux-gnu; require_linux_libc gnu ;;
                riscv64) target=riscv64-linux-gnu; require_linux_libc gnu ;;
                s390x) target=s390x-linux-gnu; require_linux_libc gnu ;;
                sparc64) target=sparc64-linux-gnu; require_linux_libc gnu ;;
                i386|i486|i586|i686|x86) target=x86-linux-gnu; require_linux_libc gnu ;;
                arm|armv*|armeb|armeb*|thumb|thumbeb)
                    fail "Linux ARM byte order or float ABI is not unambiguously reported by uname -m='$machine'; set HC_TARGET to the exact published ARM triple"
                    ;;
                *) unsupported_platform ;;
            esac
            ;;
        FreeBSD)
            case "$machine" in
                aarch64|arm64) target=aarch64-freebsd ;;
                arm) target=arm-freebsd ;;
                powerpc64|ppc64) target=powerpc64-freebsd ;;
                powerpc64le|ppc64le) target=powerpc64le-freebsd ;;
                riscv64) target=riscv64-freebsd ;;
                x86_64|amd64) target=x86_64-freebsd ;;
                i386|i486|i586|i686|x86) target=x86-freebsd ;;
                *) unsupported_platform ;;
            esac
            ;;
        NetBSD)
            case "$machine" in
                aarch64|arm64) target=aarch64-netbsd ;;
                aarch64_be) target=aarch64_be-netbsd ;;
                armeb) target=armeb-netbsd ;;
                arm) target=arm-netbsd ;;
                powerpc|ppc|macppc) target=powerpc-netbsd ;;
                mips) target=mips-netbsd ;;
                mipsel) target=mipsel-netbsd ;;
                mips64) target=mips64-netbsd ;;
                mips64el) target=mips64el-netbsd ;;
                riscv32) target=riscv32-netbsd ;;
                riscv64) target=riscv64-netbsd ;;
                x86_64|amd64) target=x86_64-netbsd ;;
                i386|i486|i586|i686|x86) target=x86-netbsd ;;
                *) unsupported_platform ;;
            esac
            ;;
        OpenBSD)
            case "$machine" in
                aarch64|arm64) target=aarch64-openbsd ;;
                arm) target=arm-openbsd ;;
                mips64) target=mips64-openbsd ;;
                mips64el) target=mips64el-openbsd ;;
                powerpc|ppc|macppc) target=powerpc-openbsd ;;
                powerpc64|ppc64) target=powerpc64-openbsd ;;
                riscv64) target=riscv64-openbsd ;;
                x86_64|amd64) target=x86_64-openbsd ;;
                i386|i486|i586|i686|x86) target=x86-openbsd ;;
                *) unsupported_platform ;;
            esac
            ;;
        DragonFly)
            case "$machine" in
                x86_64|amd64) target=x86_64-dragonfly ;;
                *) unsupported_platform ;;
            esac
            ;;
        Haiku)
            case "$machine" in
                aarch64|arm64) target=aarch64-haiku ;;
                arm) target=arm-haiku ;;
                riscv64) target=riscv64-haiku ;;
                x86_64|amd64) target=x86_64-haiku ;;
                i386|i486|i586|i686|x86) target=x86-haiku ;;
                *) unsupported_platform ;;
            esac
            ;;
        Serenity|SerenityOS|serenity|serenityos)
            case "$machine" in
                aarch64|arm64) target=aarch64-serenity ;;
                riscv64) target=riscv64-serenity ;;
                x86_64|amd64) target=x86_64-serenity ;;
                *) unsupported_platform ;;
            esac
            ;;
        SunOS|illumos)
            if [ "$system" = SunOS ]; then
                if ! kernel_version=$(uname -v); then
                    unsupported_platform
                fi
                case "$kernel_version" in
                    *illumos*|joyent_*) ;;
                    *) unsupported_platform ;;
                esac
            fi
            if [ "$machine" = i86pc ]; then
                if ! machine=$(isainfo -n); then
                    unsupported_platform
                fi
            fi
            case "$machine" in
                x86_64|amd64) target=x86_64-illumos ;;
                i386|i486|i586|i686|x86) target=x86-illumos ;;
                *) unsupported_platform ;;
            esac
            ;;
        MINGW*|MSYS*|CYGWIN*)
            case "$machine" in
                x86_64|amd64) target=x86_64-windows-gnu ;;
                aarch64|arm64) target=aarch64-windows-gnu ;;
                i386|i486|i586|i686|x86) target=x86-windows-gnu ;;
                *) unsupported_platform ;;
            esac
            ;;
        *) unsupported_platform ;;
    esac
fi

case "$target" in
    *-*) ;;
    *) fail "HC_TARGET must be a published architecture-OS target with an optional ABI: '$target'" ;;
esac
case "$target" in
    *[!A-Za-z0-9._+-]*) fail "HC_TARGET contains characters not allowed in a release target triple: '$target'" ;;
esac

if ! command -v curl >/dev/null 2>&1; then
    fail 'curl is required to download the release'
fi
if [ -n "${HC_VERSION:-}" ] && [ "$HC_VERSION" != latest ]; then
    version=$HC_VERSION
    case "$version" in
        *[!A-Za-z0-9._+-]*) fail "HC_VERSION contains characters not allowed in a release tag: '$version'" ;;
    esac
else
    if ! latest_url=$(curl --proto '=https' --proto-redir '=https' -fsSL -o /dev/null -w '%{url_effective}' "$repository/releases/latest"); then
        fail 'could not resolve the latest GitHub release'
    fi
    case "$latest_url" in
        "$repository/releases/tag/"*) version=${latest_url##*/} ;;
        *) fail "could not determine the latest release tag from '$latest_url'" ;;
    esac
    case "$version" in
        ''|*[!A-Za-z0-9._+-]*) fail "latest release returned an invalid tag: '$version'" ;;
    esac
fi

if [ -z "${HC_INSTALL_DIR:-}" ]; then
    if [ -z "${HOME:-}" ]; then
        fail 'HOME is unset; set HC_INSTALL_DIR to choose an installation directory'
    fi
    install_dir=$HOME/.local/bin
else
    install_dir=$HC_INSTALL_DIR
fi
case "$install_dir" in
    /*|./*|../*) ;;
    *) install_dir=./$install_dir ;;
esac

case "$target" in
    *-windows-*) binary=hc.exe ;;
    *) binary=hc ;;
esac
archive_name=hc-$target.tar.gz
release_url=$repository/releases/download/$version
hash_tool=
if command -v sha256sum >/dev/null 2>&1; then
    hash_tool=sha256sum
elif command -v shasum >/dev/null 2>&1; then
    hash_tool=shasum
elif command -v sha256 >/dev/null 2>&1; then
    hash_tool=sha256
else
    fail 'no SHA-256 utility found (need sha256sum, shasum, or sha256)'
fi
if ! command -v tar >/dev/null 2>&1; then
    fail 'tar is required to unpack the release archive'
fi

work_dir=
install_tmp=
if ! work_dir=$(mktemp -d "${TMPDIR:-/tmp}/hc-install.XXXXXX"); then
    fail 'could not create a private temporary directory'
fi
cleanup() {
    if [ -n "$install_tmp" ]; then
        rm -f "$install_tmp" || :
    fi
    if [ -n "$work_dir" ]; then
        rm -rf "$work_dir" || :
    fi
}
trap cleanup 0
trap 'exit 1' HUP INT TERM

if ! curl --proto '=https' --proto-redir '=https' -fsSL "$release_url/SHA256SUMS" -o "$work_dir/SHA256SUMS"; then
    fail "could not download SHA256SUMS for release '$version'"
fi
if ! curl --proto '=https' --proto-redir '=https' -fsSL "$release_url/$archive_name" -o "$work_dir/$archive_name"; then
    fail "release '$version' has no downloadable asset '$archive_name' for target '$target'; see the release target report for its availability"
fi
archive=$work_dir/$archive_name
if ! expected_hash=$(awk -v wanted="$archive_name" '
    {
        name = $2
        if (substr(name, 1, 1) == "*") name = substr(name, 2)
        if (name == wanted) {
            count++
            candidate = $1
        }
    }
    END {
        if (count != 1 || length(candidate) != 64 || candidate ~ /[^0123456789abcdefABCDEF]/) exit 1
        print tolower(candidate)
    }
' "$work_dir/SHA256SUMS"); then
    fail "SHA256SUMS has no unique valid checksum for '$archive_name'"
fi
case "$hash_tool" in
    sha256sum)
        if ! actual_hash=$(sha256sum "$archive"); then fail "could not hash '$archive_name'"; fi
        ;;
    shasum)
        if ! actual_hash=$(shasum -a 256 "$archive"); then fail "could not hash '$archive_name'"; fi
        ;;
    sha256)
        if ! actual_hash=$(sha256 -q "$archive"); then fail "could not hash '$archive_name'"; fi
        ;;
esac
actual_hash=${actual_hash%% *}
if [ "$actual_hash" != "$expected_hash" ]; then
    fail "SHA-256 verification failed for '$archive_name'"
fi

if ! entries=$(tar -tzf "$archive"); then
    fail "could not read archive '$archive_name'"
fi
if [ "$entries" != "$binary" ]; then
    fail "unsafe archive '$archive_name': expected only root entry '$binary'"
fi
if ! verbose_entries=$(tar -tvzf "$archive"); then
    fail "could not inspect archive '$archive_name'"
fi
if ! printf '%s\n' "$verbose_entries" | awk -v wanted="$binary" '
    NR == 1 && substr($0, 1, 1) == "-" && $NF == wanted { valid = 1 }
    END { exit !(NR == 1 && valid) }
'; then
    fail "unsafe archive '$archive_name': entry must be a regular root file named '$binary'"
fi
if ! mkdir "$work_dir/extract"; then
    fail 'could not create a private archive extraction directory'
fi
if ! tar -xzf "$archive" -C "$work_dir/extract"; then
    fail "could not extract archive '$archive_name'"
fi
staged_binary=$work_dir/extract/$binary
if [ ! -f "$staged_binary" ] || [ -L "$staged_binary" ]; then
    fail "unsafe archive '$archive_name': '$binary' is not a regular file"
fi

if ! mkdir -p "$install_dir"; then
    fail "could not create install directory '$install_dir'"
fi
install_path=$install_dir/$binary
if [ -d "$install_path" ]; then
    fail "cannot install over directory '$install_path'"
fi
if ! install_tmp=$(mktemp "$install_dir/.hc.XXXXXX"); then
    fail "could not create a temporary installer file in '$install_dir'"
fi
if ! cat "$staged_binary" > "$install_tmp"; then
    fail "could not copy binary into '$install_dir'"
fi
if ! chmod 755 "$install_tmp"; then
    fail "could not make installed binary executable in '$install_dir'"
fi
if ! mv -f "$install_tmp" "$install_path"; then
    fail "could not atomically install '$install_path'"
fi
install_tmp=
printf 'Installed hc %s (%s) to %s\n' "$version" "$target" "$install_path"

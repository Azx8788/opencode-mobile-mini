/// Shell prologue the setup runs share.
const termuxSetupBaseScript = r'''set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
if command -v proot-distro >/dev/null 2>&1 &&
   proot-distro login opencode-ubuntu -- /bin/true >/dev/null 2>&1; then exit 0; fi
apt-get update
apt-get -y --no-remove -o Dpkg::Options::="--force-confold" --fix-broken install
apt-get -y --no-remove -o Dpkg::Options::="--force-confold" install proot-distro curl openssl
case "$(uname -m)" in
  aarch64|arm64) arch=arm64; sha=a91d5a93010193712d346d761372b7c9db6dfcf093893161c64ca107f05914f2 ;;
  arm|armv7l|armv8l) arch=armhf; sha=4fcee4d278f1c5232e085a021a85e4c6cef3853557a88d98ff380b5e5d5841bb ;;
  x86_64|amd64) arch=amd64; sha=e77b6f10c2590cef872b33ee9f635a0e3fd1f57fb074c0e52b5c7f56147a0c86 ;;
  *) exit 64 ;;
esac
mkdir -p "$HOME/.oc/setup-v2"
archive="$HOME/.oc/setup-v2/ubuntu-base.tar.gz"
root="$PREFIX/var/lib/proot-distro/installed-rootfs/opencode-ubuntu"
# Never erase an existing container, including one from an interrupted setup.
# A damaged extraction needs explicit recovery rather than risking projects.
[ ! -d "$root" ] &&
  [ ! -d "$PREFIX/var/lib/proot-distro/containers/opencode-ubuntu/rootfs" ] || exit 65
curl --fail --location --retry 5 --connect-timeout 20 \
  "https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.5-base-$arch.tar.gz" -o "$archive"
printf '%s  %s\n' "$sha" "$archive" | sha256sum -c -
proot-distro install "$archive" --name opencode-ubuntu
proot-distro login opencode-ubuntu -- /bin/true
rm -f "$archive"
''';

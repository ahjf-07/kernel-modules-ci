#!/bin/bash
# config-bpf.sh (V8 - Fix Netfilter & Tracing Tests)
# 1. Base: x86_64_defconfig
# 2. Merge: tools/testing/selftests/bpf/config
# 3. Merge: CI overrides (Fixes NF, Cookie, BTF)
set -eu

usage() {
  cat <<USAGE
usage: $0 [-l|-g] [-c] [-m] [-r linux_root] [-o outdir]
  -l            use LLVM/clang (default)
  -g            use gcc
  -c            wipe O= (rm -rf) before config
  -m            mrproper in O= before config (forces re-config)
  -r linux_root kernel source tree root (default: pwd)
  -o outdir     explicit build output dir (O=)
USAGE
  exit 1
}

LLVM=1
CLEAN=0
MRPROPER=0
LINUX_ROOT=""
O=""

while getopts "lgr:o:cmh" opt; do
  case "$opt" in
    l) LLVM=1 ;;
    g) LLVM=0 ;;
    c) CLEAN=1 ;;
    m) MRPROPER=1 ;;
    r) LINUX_ROOT="$OPTARG" ;;
    o) O="$OPTARG" ;;
    h|*) usage ;;
  esac
done

[ -n "$LINUX_ROOT" ] || LINUX_ROOT=$(pwd)
HOST_LINUX_ROOT=$(realpath -e "$LINUX_ROOT")

ARCH=$(uname -m)
case "$ARCH" in
  x86_64) KARCH=x86 ;;
  aarch64|arm64) KARCH=arm64 ;;
  *) echo "Unsupported arch: $ARCH" >&2; exit 1 ;;
esac

if [ -z "$O" ]; then
  if [ "$LLVM" -eq 1 ]; then
    O="../out/full-clang-${KARCH}"
  else
    O="../out/full-gcc-${KARCH}"
  fi
fi
O=$(realpath -m "$O")

echo "[cfg] root=$HOST_LINUX_ROOT"
echo "[cfg] out =$O"

# --- 0. Check Pahole ---
need_pahole=122
pahole_num() {
  pahole --version 2>/dev/null | head -n1 \
    | sed -n 's/^v\([0-9]\+\)\.\([0-9]\+\).*$/\1\2/p'
}
p="$(command -v pahole 2>/dev/null || true)"
[ -z "$p" ] && echo "[err] pahole not found in PATH" >&2 && exit 2
pv="$(pahole_num)"
if [ "$pv" -lt "$need_pahole" ]; then
  echo "[err] pahole too old: $p, need >= v1.22" >&2; exit 2
fi
echo "[cfg] pahole=$p ver=$(pahole --version | head -n1)" >&2

# --- 1. Prepare Output Dir ---
if [ "$MRPROPER" -eq 1 ]; then
  echo "[cfg] cleaning (mrproper) $O..."
  rm -rf "$O"
  mkdir -p "$O"
elif [ "$CLEAN" -eq 1 ]; then
  echo "[cfg] cleaning (rm files) $O..."
  rm -rf "$O"/*
  mkdir -p "$O"
else
  mkdir -p "$O"
fi

# --- 2. Base Config ---
if [ ! -f "$O/.config" ]; then
  echo "[cfg] generating defconfig..."
  ARGS="O=$O"
  [ "$LLVM" -eq 1 ] && ARGS="$ARGS LLVM=1 LLVM_IAS=1"
  make -C "$HOST_LINUX_ROOT" $ARGS defconfig >/dev/null
else
  echo "[cfg] using existing .config"
fi

# --- 3. Merge Official Selftests Config ---
SELFTEST_CONFIG="$HOST_LINUX_ROOT/tools/testing/selftests/bpf/config"
SELFTEST_NET_CONFIG="$HOST_LINUX_ROOT/tools/testing/selftests/net/config"

echo "[cfg] merging official selftests configs..."
if [ -f "$SELFTEST_CONFIG" ]; then
    "$HOST_LINUX_ROOT/scripts/kconfig/merge_config.sh" \
        -m -r -O "$O" "$O/.config" "$SELFTEST_CONFIG" >/dev/null
fi
if [ -f "$SELFTEST_NET_CONFIG" ]; then
    "$HOST_LINUX_ROOT/scripts/kconfig/merge_config.sh" \
        -m -r -O "$O" "$O/.config" "$SELFTEST_NET_CONFIG" >/dev/null
fi

# --- 4. Merge CI-Specific Overrides ---
FRAG="$O/bpf_ci_override.config"
cat <<EOF > "$FRAG"
# == CI Enforcements ==
CONFIG_DEBUG_INFO=y
CONFIG_DEBUG_INFO_BTF=y
CONFIG_DEBUG_INFO_BTF_MODULES=y
CONFIG_MODULE_ALLOW_BTF_MISMATCH=y
CONFIG_PAHOLE_HAS_SPLIT_BTF=y
CONFIG_DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT=y
CONFIG_BPF_JIT_ALWAYS_ON=y
CONFIG_BPF_LSM=y
CONFIG_IKHEADERS=y

# 解决 cgroup_iter_memcg.c 等新测试的依赖
CONFIG_MEMCG=y
CONFIG_MEMCG_KMEM=y
CONFIG_CGROUPS=y

# == nftables flowtable (for xdp_flowtable selftest) ==
CONFIG_NETFILTER=y
CONFIG_NF_TABLES=y
CONFIG_NF_FLOW_TABLE=y
CONFIG_NF_FLOW_TABLE_INET=y
CONFIG_NFT_FLOW_OFFLOAD=y

# == Netfilter / Conntrack Dependencies (Fixes bpf_nf tests) ==
CONFIG_NETFILTER=y
CONFIG_NF_CONNTRACK=y
CONFIG_NF_NAT=y
CONFIG_NF_CONNTRACK_EVENTS=y
CONFIG_NF_CONNTRACK_MARK=y
CONFIG_NF_CONNTRACK_PROCFS=y
CONFIG_NF_CONNTRACK_LABELS=y
CONFIG_NF_CT_NETLINK=y
CONFIG_NETFILTER_XT_TARGET_LOG=y
CONFIG_NETFILTER_XT_MATCH_CONNTRACK=y

# == Tracing / Perf Dependencies (Fixes bpf_cookie tests) ==
CONFIG_PERF_EVENTS=y
CONFIG_BPF_EVENTS=y
CONFIG_KPROBES=y
CONFIG_KPROBE_EVENTS=y
CONFIG_UPROBES=y
CONFIG_UPROBE_EVENTS=y
CONFIG_DYNAMIC_FTRACE=y
CONFIG_FUNCTION_TRACER=y

# == Tunneling Protocols ==
CONFIG_VXLAN=y
CONFIG_GENEVE=y
CONFIG_LWTUNNEL=y
CONFIG_IP_GRE=y
CONFIG_IPV6_GRE=y
CONFIG_MPLS=y
CONFIG_MPLS_ROUTING=y
CONFIG_MPLS_IPTUNNEL=y

# == Ensure Crypto/CRC is enabled ==
CONFIG_CRYPTO_CRC32=y
CONFIG_CRC32=y
EOF

echo "[cfg] merging CI overrides..."
"$HOST_LINUX_ROOT/scripts/kconfig/merge_config.sh" \
    -m -r -O "$O" "$O/.config" "$FRAG" >/dev/null

# --- 4.1 Force critical options (merge_config -r may drop unmet symbols) ---
"$HOST_LINUX_ROOT/scripts/config" --file "$O/.config" -e NF_TABLES
"$HOST_LINUX_ROOT/scripts/config" --file "$O/.config" -e NF_FLOW_TABLE
"$HOST_LINUX_ROOT/scripts/config" --file "$O/.config" -e NF_FLOW_TABLE_INET
"$HOST_LINUX_ROOT/scripts/config" --file "$O/.config" -e NFT_FLOW_OFFLOAD

# --- 5. Finalize ---
echo "[cfg] finalizing .config..."
ARGS="O=$O"
[ "$LLVM" -eq 1 ] && ARGS="$ARGS LLVM=1 LLVM_IAS=1"
make -C "$HOST_LINUX_ROOT" $ARGS olddefconfig >/dev/null

echo "[cfg] done. Output in $O/.config"

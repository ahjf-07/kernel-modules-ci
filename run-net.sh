#!/bin/bash
set -eu

O_DIR=""; CPUS=8; MEM=8G; SCOPE="full"

while getopts "o:p:m:S:h" opt; do
    case "$opt" in
        o) O_DIR="$OPTARG" ;;
        p) CPUS="$OPTARG" ;;
        m) MEM="$OPTARG" ;;
        S) SCOPE="$OPTARG" ;; # full/fast/ffast
    esac
done

ARCH=$(uname -m)
[ "$ARCH" = "x86_64" ] && IMG="$O_DIR/arch/x86/boot/bzImage" || IMG="$O_DIR/arch/arm64/boot/Image"

GUEST=".kselftest-out/guest-net.sh"
cat <<GEOF >"$GUEST"
ulimit -n 65536
#!/bin/sh
cd tools/testing/selftests/net
if [ "$SCOPE" = "ffast" ]; then
    tests="fib_trie.sh fib_tests.sh"
elif [ "$SCOPE" = "fast" ]; then
    tests=\$(ls *.sh | grep -vE "config|settings|pmtu|forwarding")
else
    tests=\$(ls *.sh | grep -vE "config|settings")
fi
bins=\$(find . -maxdepth 1 -type f -executable ! -name "*.*")
TOTAL=\$(( \$(echo "\$tests" | wc -w) + \$(echo "\$bins" | wc -w) ))
CUR=0
for f in \$tests \$bins; do
    CUR=\$((CUR + 1))
    printf "\r\033[K[ %d / %d ] Net CI ($SCOPE): %s" "\$CUR" "\$TOTAL" "\$(basename "\$f")"
    case "\$(basename "\$f")" in "fin_ack_lat"|"tcp_mmap"|"udpgso_bench_rx"|"so_rcv_listener") continue ;; esac
    timeout 60s "./\$f" >> ../../../../.kselftest-out/net.selftests.log 2>&1
done
echo -e "\n=== Done ==="
GEOF
chmod +x "$GUEST"

vng --run "$IMG" --cpus "$CPUS" --memory "$MEM" --rw --cwd . \
    --exec "sh $GUEST" 2> >(grep -v "Slirp: external icmpv6" >&2)

#!/bin/sh
# Build + functional test for the TONER-AUTH v2 signature reference code.
#
# Usage:
#   ./run_tests.sh                            # system cc + system OpenSSL
#   EXTRA="-I<incdir> -L<libdir>" LIBS=-lcrypto ./run_tests.sh
#
# Requires: cc and OpenSSL 1.0.2..3.x with libcrypto headers/libs.
# On OpenSSL 1.1+/3.x the build adds -Wno-deprecated-declarations
# automatically (classic EC_KEY/ECDSA APIs; see file headers).
#
# A throwaway password and test keys are generated at runtime in a private
# temporary directory; none of them is intended for manufacturing.
set -u

DIR=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d /tmp/toner-auth-test.XXXXXXXX) || exit 1
case "$WORK" in
    /tmp/toner-auth-test.*) ;;
    *) echo "測試目錄不安全，已停止執行" >&2; exit 1 ;;
esac
trap 'case "$WORK" in /tmp/toner-auth-test.*) rm -r -- "$WORK" ;; esac' EXIT
CC=${CC:-cc}
EXTRA=${EXTRA:-}
LIBS=${LIBS:--lcrypto}

# Locate OpenSSL automatically when libssl-dev is not installed: use a
# locally extracted libssl-dev under /tmp/ssldev/pkg if present, e.g.
#   mkdir -p /tmp/ssldev && cd /tmp/ssldev && apt-get download libssl-dev \
#       && dpkg-deb -x libssl-dev*.deb pkg
if [ ! -e /usr/include/openssl/ec.h ] && [ -d /tmp/ssldev/pkg/usr/include ]; then
    EXTRA="$EXTRA -I/tmp/ssldev/pkg/usr/include -L/tmp/ssldev/pkg/usr/lib/$(uname -m)-linux-gnu"
fi

DEPFLAG=
if openssl version 2>/dev/null | grep -q 'OpenSSL 3'; then
    DEPFLAG=-Wno-deprecated-declarations
fi

fail=0
pass=0

echo "== 編譯（cc = $($CC --version | head -1)）=="
$CC -std=c11 -Wall -Wextra -Werror $DEPFLAG $EXTRA \
    "$DIR/keygen.c" -o "$WORK/keygen" $LIBS || exit 1
$CC -std=c11 -Wall -Wextra -Werror $DEPFLAG $EXTRA \
    "$DIR/sign.c" "$DIR/record.c" -o "$WORK/sign" $LIBS || exit 1
$CC -std=c11 -Wall -Wextra -Werror $DEPFLAG $EXTRA \
    "$DIR/verify.c" "$DIR/record.c" -o "$WORK/verify" $LIBS || exit 1
$CC -std=c11 -Wall -Wextra -Werror $DEPFLAG $EXTRA \
    "$DIR/record_test.c" "$DIR/record.c" -o "$WORK/record_test" $LIBS || exit 1
echo "編譯通過（無警告）"

expect() {  # expect <want_exit> <cmd...>
    want=$1; shift
    "$@" >"$WORK/out" 2>"$WORK/err"
    got=$?
    if [ "$got" = "$want" ]; then
        pass=$((pass + 1))
        echo "通過（退出碼 $got）：$*"
        return 0
    else
        fail=$((fail + 1))
        echo "失敗（實際退出碼 $got，預期 $want）：$*"
        sed 's/^/    | /' "$WORK/err" "$WORK/out" 2>/dev/null
        return 1
    fi
}

: "${TONER_DEMO_KEY_PASSWORD:=$(head -c 24 /dev/urandom | base64)}"
export TONER_DEMO_KEY_PASSWORD
SN=0123AABBCCDDEEFFEE
SKU=AV-TONER
CAP=HC-6500

echo "== 標準化紀錄黃金測試向量 =="
expect 0 "$WORK/record_test" || exit 1

echo "== 產生測試金鑰 =="
mkdir "$WORK/keys" "$WORK/wrong-keys" "$WORK/revoked-keys"
expect 0 "$WORK/keygen" "$WORK/k1.priv" "$WORK/keys/key-01.pem" || exit 1
expect 0 "$WORK/keygen" "$WORK/k2.priv" "$WORK/keys/key-02.pem" || exit 1
cp "$WORK/keys/key-02.pem" "$WORK/wrong-keys/key-01.pem"

echo "== 建立簽章並驗證有效案例 =="
expect 0 "$WORK/sign" "$WORK/k1.priv" 01 "$SN" "$SKU" K "$CAP" "$WORK/sig.bin" || exit 1
expect 0 "$WORK/verify" "$WORK/keys" 01 "$SN" "$SKU" K "$CAP" "$WORK/sig.bin" || exit 1
if grep -q '^驗證通過$' "$WORK/out"; then
    pass=$((pass + 1)); echo "通過：驗章輸出為「驗證通過」"
else
    fail=$((fail + 1)); echo "失敗：驗章輸出不是「驗證通過」"
fi

echo "== 驗章拒絕遭竄改的紀錄欄位（退出碼 2）=="
expect 2 "$WORK/verify" "$WORK/keys" 02 "$SN" "$SKU" K "$CAP" "$WORK/sig.bin"
expect 2 "$WORK/verify" "$WORK/keys" 01 0123AABBCCDDEEFFEF "$SKU" K "$CAP" "$WORK/sig.bin"
expect 2 "$WORK/verify" "$WORK/keys" 01 "$SN" AV-TONEX K "$CAP" "$WORK/sig.bin"
expect 2 "$WORK/verify" "$WORK/keys" 01 "$SN" "$SKU" C "$CAP" "$WORK/sig.bin"
expect 2 "$WORK/verify" "$WORK/keys" 01 "$SN" "$SKU" K HC-9999 "$WORK/sig.bin"

echo "== 驗章拒絕錯誤公鑰與無效簽章（退出碼 2）=="
expect 2 "$WORK/verify" "$WORK/wrong-keys" 01 "$SN" "$SKU" K "$CAP" "$WORK/sig.bin"
expect 2 "$WORK/verify" "$WORK/keys" 03 "$SN" "$SKU" K "$CAP" "$WORK/sig.bin"
expect 2 "$WORK/verify" "$WORK/revoked-keys" 01 "$SN" "$SKU" K "$CAP" "$WORK/sig.bin"
dd if=/dev/zero of="$WORK/zero.bin" bs=64 count=1 2>/dev/null
expect 2 "$WORK/verify" "$WORK/keys" 01 "$SN" "$SKU" K "$CAP" "$WORK/zero.bin"
head -c 64 /dev/urandom >"$WORK/rand.bin"
expect 2 "$WORK/verify" "$WORK/keys" 01 "$SN" "$SKU" K "$CAP" "$WORK/rand.bin"
head -c 63 "$WORK/sig.bin" >"$WORK/t63.bin"
expect 2 "$WORK/verify" "$WORK/keys" 01 "$SN" "$SKU" K "$CAP" "$WORK/t63.bin"
cp "$WORK/sig.bin" "$WORK/s65.bin"
printf '\000' >>"$WORK/s65.bin"
expect 2 "$WORK/verify" "$WORK/keys" 01 "$SN" "$SKU" K "$CAP" "$WORK/s65.bin"

echo "== 格式錯誤的輸入 =="
expect 2 "$WORK/verify" "$WORK/keys" 01 0123 "$SKU" K "$CAP" "$WORK/sig.bin"
expect 2 "$WORK/verify" "$WORK/keys" 01 "$SN" "AV TONER" K "$CAP" "$WORK/sig.bin"
expect 2 "$WORK/verify" "$WORK/keys" 00 "$SN" "$SKU" K "$CAP" "$WORK/sig.bin"
expect 2 "$WORK/verify" "$WORK/keys" 01 "$SN" "$SKU" KK "$CAP" "$WORK/sig.bin"
expect 1 "$WORK/sign" "$WORK/k1.priv" 00 "$SN" "$SKU" K "$CAP" "$WORK/x.bin"
expect 1 "$WORK/verify" "$WORK/keys" 01 "$SN" "$SKU" K "$CAP" "$WORK/missing.bin"

echo "== 拒絕覆寫既有檔案 =="
expect 1 "$WORK/sign" "$WORK/k1.priv" 01 "$SN" "$SKU" K "$CAP" "$WORK/sig.bin"
expect 1 "$WORK/keygen" "$WORK/k1.priv" "$WORK/k3.pub"

echo
echo "結果：$pass 項通過，$fail 項失敗"
[ "$fail" -eq 0 ]

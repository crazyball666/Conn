#!/usr/bin/env bash
# verify.sh - prove the Spike S1 environment itself is sound BEFORE we blame any
# client library. For every container we exercise the four auth paths with the
# host's own OpenSSH CLI and print a PASS/FAIL matrix.
#
# Auth paths tested per host:
#   pw(deploy)   password auth as deploy
#   pw(root)     password auth as root
#   ed25519      public-key auth (unencrypted ed25519)
#   rsa          public-key auth (4096-bit RSA)
#   ed25519+pw   public-key auth with a PASSPHRASE-protected key (passphrase=testpass)
#
# Passwords/passphrases are fed non-interactively via SSH_ASKPASS_REQUIRE=force
# (OpenSSH >= 8.4). No sshpass required.
set -u
cd "$(dirname "$0")"
KEYS="$(pwd)/keys"

PASS="conntest123"
KPASS="testpass"
BASE_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
           -o ConnectTimeout=10 -o LogLevel=ERROR)

green() { printf '\033[32m%s\033[0m' "$1"; }
red()   { printf '\033[31m%s\033[0m' "$1"; }
mark()  { [ "$1" -eq 0 ] && green "PASS" || red "FAIL"; }

askpass_run() {   # $1=secret ; rest=ssh args
  local secret="$1"; shift
  local ap; ap="$(mktemp)"
  printf '#!/bin/sh\necho "%s"\n' "$secret" > "$ap"; chmod +x "$ap"
  SSH_ASKPASS="$ap" SSH_ASKPASS_REQUIRE=force DISPLAY=":0" \
    ssh "$@" >/dev/null 2>&1
  local rc=$?; rm -f "$ap"; return $rc
}

try_pw() {        # port user
  askpass_run "$PASS" -p "$1" "${BASE_OPTS[@]}" \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    -o NumberOfPasswordPrompts=1 "$2@127.0.0.1" true
}

try_key() {       # port user keyfile
  ssh -p "$1" "${BASE_OPTS[@]}" -i "$KEYS/$3" -o IdentitiesOnly=yes \
      -o PreferredAuthentications=publickey -o BatchMode=yes \
      "$2@127.0.0.1" true >/dev/null 2>&1
}

try_key_pass() {  # port user keyfile
  askpass_run "$KPASS" -p "$1" "${BASE_OPTS[@]}" -i "$KEYS/$3" \
    -o IdentitiesOnly=yes -o PreferredAuthentications=publickey \
    "$2@127.0.0.1" true
}

wait_port() {     # port
  for _ in $(seq 1 30); do
    if nc -z -G2 127.0.0.1 "$1" 2>/dev/null; then return 0; fi
    sleep 1
  done
  return 1
}

# name  port
MATRIX=(
  "conn-ubuntu22 2201"
  "conn-ubuntu24 2202"
  "conn-debian12 2203"
  "conn-centos7  2204"
  "conn-alpine   2205"
  "conn-bastion  2206"
)

echo "=================================================================================="
echo " conn Spike S1 - environment verification (host ssh: $(ssh -V 2>&1))"
echo "=================================================================================="
printf '%-15s %-6s %-11s %-11s %-9s %-7s %-12s\n' \
  HOST PORT "pw(deploy)" "pw(root)" ed25519 rsa "ed25519+pw"
echo "----------------------------------------------------------------------------------"

overall=0
for row in "${MATRIX[@]}"; do
  set -- $row; name="$1"; port="$2"
  if ! wait_port "$port"; then
    printf '%-15s %-6s %s\n' "$name" "$port" "$(red 'PORT NOT OPEN')"
    overall=1; continue
  fi
  try_pw "$port" deploy;              r_pd=$?
  try_pw "$port" root;                r_pr=$?
  try_key "$port" deploy id_ed25519;  r_ed=$?
  try_key "$port" deploy id_rsa;      r_rsa=$?
  try_key_pass "$port" deploy id_ed25519_pw; r_edp=$?
  for rc in $r_pd $r_pr $r_ed $r_rsa $r_edp; do [ "$rc" -ne 0 ] && overall=1; done
  printf '%-15s %-6s %-20s %-20s %-18s %-16s %-12s\n' \
    "$name" "$port" "$(mark $r_pd)" "$(mark $r_pr)" "$(mark $r_ed)" \
    "$(mark $r_rsa)" "$(mark $r_edp)"
done

echo "----------------------------------------------------------------------------------"
echo
echo "=== Focus test: RSA on the MODERN server (conn-ubuntu24, port 2202) ==="
# Default: client is free to use rsa-sha2-512/256 -> expected PASS.
try_key 2202 deploy id_rsa; d=$?
echo "  RSA key, default signature algs (rsa-sha2-*) : $(mark $d)"
# Force legacy ssh-rsa (SHA-1) only -> expected FAIL on OpenSSH >= 8.8 default.
ssh -p 2202 "${BASE_OPTS[@]}" -i "$KEYS/id_rsa" -o IdentitiesOnly=yes \
    -o PreferredAuthentications=publickey -o BatchMode=yes \
    -o PubkeyAcceptedKeyTypes=ssh-rsa \
    deploy@127.0.0.1 true >/dev/null 2>&1; f=$?
echo "  RSA key, forced legacy ssh-rsa (SHA-1)       : $(mark $f)  (FAIL here is CORRECT)"

echo
echo "  NOTE: legacy ssh-rsa (SHA-1) USER-auth is refused by *every* server here,"
echo "        because none advertise ssh-rsa in server-sig-algs (even CentOS 7.4"
echo "        only offers rsa-sha2-*). A modern client therefore never sends it."
echo

echo "=== Focus test: legacy algorithms - OLD (centos7) vs MODERN (ubuntu24) ==="
# ed25519 user-key auth, but force a single legacy algo each time. centos7 was
# explicitly configured to support these; ubuntu24 (default) rejects them.
legacy_probe() {  # label  option  expect_old_ok(0/1)
  local label="$1" opt="$2"
  ssh -p 2204 "${BASE_OPTS[@]}" -i "$KEYS/id_ed25519" -o IdentitiesOnly=yes \
      -o BatchMode=yes $opt deploy@127.0.0.1 true >/dev/null 2>&1; local co=$?
  ssh -p 2202 "${BASE_OPTS[@]}" -i "$KEYS/id_ed25519" -o IdentitiesOnly=yes \
      -o BatchMode=yes $opt deploy@127.0.0.1 true >/dev/null 2>&1; local uo=$?
  # old must accept (co=0), modern must reject (uo!=0)
  local verdict=1; { [ $co -eq 0 ] && [ $uo -ne 0 ]; } && verdict=0
  printf '  %-34s centos7=%s  ubuntu24=%s  => %s\n' \
    "$label" "$(mark $co)" "$(mark $uo)" "$(mark $verdict)"
  [ $verdict -ne 0 ] && overall=1
}
legacy_probe "ssh-rsa HOST KEY (SHA-1)"  "-o HostKeyAlgorithms=ssh-rsa"
legacy_probe "KEX diffie-hellman-grp14-sha1" "-o KexAlgorithms=diffie-hellman-group14-sha1"
legacy_probe "cipher aes256-cbc"         "-o Ciphers=aes256-cbc"
echo "  (verdict PASS = old server accepts the legacy algo AND modern one rejects it)"

echo
echo "=== Jump chain: host --> conn-bastion(2206) --> conn-internal (no host port) ==="
# -o options do NOT propagate to -J's implicit ProxyCommand, so we hand the jump
# its settings via a throwaway -F config (applies to every hop).
JCFG="$(mktemp)"
cat > "$JCFG" <<EOF
Host *
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  IdentityFile $KEYS/id_ed25519
  IdentitiesOnly yes
  BatchMode yes
  ConnectTimeout 10
EOF
if ssh -F "$JCFG" -J deploy@127.0.0.1:2206 \
       deploy@conn-internal 'echo REACHED $(hostname)' 2>/dev/null | grep -q REACHED; then
  echo "  ssh -J via bastion to conn-internal          : $(green PASS)"
else
  echo "  ssh -J via bastion to conn-internal          : $(red FAIL)"; overall=1
fi
# Negative control: internal must NOT be reachable directly from the host.
if ssh -F "$JCFG" -o ConnectTimeout=5 deploy@conn-internal true >/dev/null 2>&1; then
  echo "  direct host -> conn-internal (must FAIL)      : $(red 'UNEXPECTED PASS')"; overall=1
else
  echo "  direct host -> conn-internal blocked          : $(green PASS)"
fi
rm -f "$JCFG"

echo
[ "$overall" -eq 0 ] && green "ALL ENVIRONMENT CHECKS PASSED" || red "SOME CHECKS FAILED (see above)"
echo
exit $overall

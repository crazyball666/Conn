# Spike S1 — Algorithm Support Matrix

Per-distro algorithm inventory for the SSH matrix. This is one of the core
outputs of Spike S1: it tells the Conn SSH engine exactly which KEX / host-key /
pubkey / cipher algorithms it must implement to talk to real-world servers.

- **Source of truth:** `sshd -T` run *inside* each container = the algorithms the
  server actually has **enabled** (effective config). For dropbear (no `sshd -T`)
  the values are taken from the server's live `SSH2_MSG_KEXINIT` proposal captured
  with `ssh -vvv`.
- `ssh -Q …` (also shown) is the *build capability* of that distro's OpenSSH — a
  superset of what is enabled. It is listed for reference only.
- Captured 2026-07-21 on Docker 28.5.1, Apple Silicon (centos7 via Rosetta/amd64).

Host software versions:

| Container | Port | SSH server | Arch |
|---|---|---|---|
| conn-ubuntu22 | 2201 | OpenSSH **8.9p1** (`1:8.9p1-3ubuntu0.16`) | arm64 |
| conn-ubuntu24 | 2202 | OpenSSH **9.6p1** (`1:9.6p1-3ubuntu13.18`) | arm64 |
| conn-debian12 | 2203 | OpenSSH **9.2p1** (`1:9.2p1-2+deb12u10`) | arm64 |
| conn-centos7  | 2204 | OpenSSH **7.4p1** (`7.4p1-23.el7_9`) | amd64 (Rosetta) |
| conn-alpine   | 2205 | **dropbear 2026.91** (BusyBox, non-OpenSSH) | arm64 |
| conn-bastion  | 2206 | OpenSSH 9.6p1 (= ubuntu24) | arm64 |
| conn-internal | —    | OpenSSH 9.6p1 (= ubuntu24) | arm64 |

---

## 1. Quick-read: legacy-algorithm support (the part that matters)

"Legacy" = the SHA-1 / CBC family a client library needs for old boxes.

| Algorithm class | ubuntu22 | ubuntu24 | debian12 | **centos7** | alpine (dropbear) |
|---|:---:|:---:|:---:|:---:|:---:|
| `ssh-rsa` host key (RSA + **SHA-1**) | ❌ | ❌ | ❌ | ✅ | ❌ |
| `ssh-rsa` pubkey **user auth** (SHA-1) | ❌ | ❌ | ❌ | ⚠️ cfg-enabled but not advertised¹ | ❌ |
| `rsa-sha2-256/512` (RSA + SHA-2) | ✅ | ✅ | ✅ | ✅ | ✅ (256 only) |
| `ssh-dss` (DSA) | ❌ | ❌ | ❌ | ✅ | ❌ |
| KEX `diffie-hellman-group14-sha1` | ❌ | ❌ | ❌ | ✅ | ❌ |
| KEX `diffie-hellman-group1-sha1` | ❌ | ❌ | ❌ | ✅ | ❌ |
| Cipher `aes256-cbc` / `3des-cbc` (CBC) | ❌ | ❌ | ❌ | ✅ | ❌ |
| MAC `hmac-sha1` | ✅ | ✅ | ✅ | ✅ | ❌ (sha2-256 only) |
| ed25519 host key + user key | ✅ | ✅ | ✅ | ✅ | ✅ |
| Post-quantum KEX (sntrup761 / mlkem768) | ✅ (sntrup) | ✅ (sntrup) | ✅ (sntrup) | ❌ | ✅ (both) |

¹ CentOS 7 is *configured* to accept `ssh-rsa` for user auth (`PubkeyAcceptedKeyTypes
+ssh-rsa`, confirmed in `sshd -T`), **but** its OpenSSH 7.4 only advertises
`server-sig-algs=rsa-sha2-256,rsa-sha2-512`. A modern client (OpenSSH ≥ 8.8) honours
that list and therefore never even offers a SHA-1 signature — so end-to-end SHA-1
*user auth* cannot be exercised here. SHA-1 is still fully demonstrable on centos7
via the **host key**, **KEX**, and **cipher** rows above (all verified working).

---

## 2. Effective server config (`sshd -T`, i.e. what is actually enabled)

### conn-ubuntu22 — OpenSSH 8.9p1
```
kexalgorithms          curve25519-sha256, curve25519-sha256@libssh.org, ecdh-sha2-nistp256/384/521,
                       sntrup761x25519-sha512@openssh.com, diffie-hellman-group-exchange-sha256,
                       diffie-hellman-group16-sha512, diffie-hellman-group18-sha512, diffie-hellman-group14-sha256
hostkeyalgorithms      ssh-ed25519, ecdsa-sha2-nistp256/384/521, rsa-sha2-512, rsa-sha2-256   (+ *-cert-v01)
pubkeyacceptedalgorithms  (same set as hostkeyalgorithms) — NO ssh-rsa
ciphers                chacha20-poly1305@openssh.com, aes128/192/256-ctr, aes128/256-gcm@openssh.com
macs                   umac-64/128(-etm), hmac-sha2-256/512(-etm), hmac-sha1(-etm)
```

### conn-ubuntu24 — OpenSSH 9.6p1  (MODERN reference)
```
kexalgorithms          sntrup761x25519-sha512@openssh.com, curve25519-sha256, curve25519-sha256@libssh.org,
                       ecdh-sha2-nistp256/384/521, diffie-hellman-group-exchange-sha256,
                       diffie-hellman-group16-sha512, diffie-hellman-group18-sha512, diffie-hellman-group14-sha256
hostkeyalgorithms      ssh-ed25519, ecdsa-sha2-nistp256/384/521, rsa-sha2-512, rsa-sha2-256   (+ *-cert-v01)
pubkeyacceptedalgorithms  (same) — NO ssh-rsa, NO ssh-dss
ciphers                chacha20-poly1305@openssh.com, aes128/192/256-ctr, aes128/256-gcm@openssh.com   (NO CBC)
macs                   umac-64/128(-etm), hmac-sha2-256/512(-etm), hmac-sha1(-etm)
```

### conn-debian12 — OpenSSH 9.2p1
```
kexalgorithms          sntrup761x25519-sha512, sntrup761x25519-sha512@openssh.com, curve25519-sha256,
                       curve25519-sha256@libssh.org, ecdh-sha2-nistp256/384/521,
                       diffie-hellman-group-exchange-sha256, group16-sha512, group18-sha512, group14-sha256
hostkeyalgorithms      ssh-ed25519, ecdsa-sha2-nistp256/384/521, rsa-sha2-512, rsa-sha2-256   (+ *-cert-v01)
pubkeyacceptedalgorithms  (same) — NO ssh-rsa
ciphers                chacha20-poly1305@openssh.com, aes128/192/256-ctr, aes128/256-gcm@openssh.com   (NO CBC)
```

### conn-centos7 — OpenSSH 7.4p1  (OLD server, legacy explicitly enabled)
```
kexalgorithms          curve25519-sha256(+@libssh.org), ecdh-sha2-nistp256/384/521,
                       diffie-hellman-group-exchange-sha256, group16-sha512, group18-sha512,
                       >> diffie-hellman-group-exchange-sha1, group14-sha256,
                       >> diffie-hellman-group14-sha1, diffie-hellman-group1-sha1     (SHA-1 KEX enabled)
hostkeyalgorithms      ecdsa-sha2-nistp256/384/521, ssh-ed25519, rsa-sha2-512, rsa-sha2-256,
                       >> ssh-rsa, ssh-dss     (+ *-cert-v01)                          (ssh-rsa/DSA enabled)
pubkeyacceptedkeytypes ecdsa-*, ssh-ed25519, rsa-sha2-512, rsa-sha2-256,
                       >> ssh-rsa, ssh-dss                                            (ssh-rsa user key enabled)
ciphers                chacha20-poly1305@openssh.com, aes128/192/256-ctr, aes128/256-gcm,
                       >> aes128/192/256-cbc, blowfish-cbc, cast128-cbc, 3des-cbc      (CBC enabled)
macs                   umac-64/128(-etm), hmac-sha2-256/512(-etm), hmac-sha1(-etm)
```
(`>>` marks the legacy algorithms added by the S1 old-server profile.)

### conn-alpine — dropbear 2026.91  (non-OpenSSH; live KEXINIT proposal)
```
kex algorithms         sntrup761x25519-sha512(+@openssh.com), mlkem768x25519-sha256, curve25519-sha256,
                       curve25519-sha256@libssh.org, ecdh-sha2-nistp256/384/521,
                       diffie-hellman-group14-sha256, kexguess2@matt.ucc.asn.au
host key algorithms    ssh-ed25519, ecdsa-sha2-nistp256, rsa-sha2-256        (NO ssh-rsa/SHA-1)
ciphers                chacha20-poly1305@openssh.com, aes256-ctr, aes128-ctr (NO CBC)
macs                   hmac-sha2-256                                          (NO hmac-sha1)
user-auth sig algs     ssh-ed25519, ecdsa-sha2-nistp256/384/521, rsa-sha2-256
```
Note: this dropbear build is *modern* — it advertises post-quantum KEX and refuses
legacy SHA-1/CBC, same as the OpenSSH 9.x boxes. It is the "different implementation"
sample, not an "old" sample.

---

## 3. Build capability (`ssh -Q`, superset — reference only)

`ssh -Q` lists what the distro's OpenSSH *can* do if configured; it is wider than
the enabled set in §2. Highlights of what appears in `-Q` but is **disabled** by
default on the modern boxes:

| `ssh -Q` field | ubuntu22 / 24 / debian12 build includes | centos7 (7.4) build includes |
|---|---|---|
| `kex` | `diffie-hellman-group1-sha1`, `-group14-sha1`, `-group-exchange-sha1` (all disabled at runtime) | same + `gss-*-sha1-` |
| `key` | `ssh-rsa`, `ssh-dss` (disabled at runtime on ubuntu/debian) | `ssh-rsa`, `ssh-dss` (enabled at runtime) |
| `cipher` | `3des-cbc`, `aes128/192/256-cbc` (disabled at runtime) | same + `blowfish-cbc`, `cast128-cbc`, `arcfour*`, `rijndael-cbc@lysator.liu.se` |

Take-away: every OpenSSH build here *contains* the SHA-1/CBC code; the modern
distros simply don't **enable** it. Only centos7 turns it back on.

---

## 4. Implications for the Conn SSH engine

1. **RSA keys are fine everywhere — but only with SHA-2 signatures.** The engine
   MUST implement `rsa-sha2-256` / `rsa-sha2-512` (RFC 8332) and honour
   `server-sig-algs`. An engine that can only produce legacy `ssh-rsa` (SHA-1)
   signatures will fail against ubuntu22/24, debian12, and dropbear.
2. **ed25519 works against 100% of the matrix** (incl. dropbear) — safe default.
3. **To support genuinely old servers** (the centos7 profile) the engine also needs:
   `ssh-rsa` host-key verification, `diffie-hellman-group14-sha1` (and ideally
   `group1-sha1`), and CBC ciphers (`aes*-cbc`, `3des-cbc`). These are opt-in / rare.
4. **Non-OpenSSH interop:** dropbear negotiates cleanly with OpenSSH; nothing
   special required beyond the modern algorithm set + `rsa-sha2-256`.

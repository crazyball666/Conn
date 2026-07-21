# Spike S1 — Multi-distro sshd test matrix

A set of Docker containers running different SSH servers, used to validate the
**Conn** iOS SSH client library against real-world server behaviour (algorithms,
auth methods, jump hosts). Everything here is disposable and local.

> Ports **2201–2210** only (host 8080 / 8501 are used by other apps — never touched).
> CentOS 7 is amd64-only and runs under Rosetta on Apple Silicon — expected.

## Container matrix

| Port | Container | Base image | Server | Role |
|---|---|---|---|---|
| 2201 | conn-ubuntu22 | ubuntu:22.04 | OpenSSH 8.9p1 | Baseline |
| 2202 | conn-ubuntu24 | ubuntu:24.04 | OpenSSH 9.6p1 | **Modern server** (default config; legacy ssh-rsa off) |
| 2203 | conn-debian12 | debian:12 | OpenSSH 9.2p1 | Common production distro |
| 2204 | conn-centos7 | centos:7 | OpenSSH 7.4p1 | **Old server** (ssh-rsa / SHA-1 KEX / CBC enabled) |
| 2205 | conn-alpine | alpine + dropbear | dropbear 2026.91 | **Non-OpenSSH** implementation |
| 2206 | conn-bastion | ubuntu:24.04 | OpenSSH 9.6p1 | Jump host (first hop) |
| — | conn-internal | ubuntu:24.04 | OpenSSH 9.6p1 | Jump target — **no host port, reachable only via bastion** |

## Credentials (all containers)

| | value |
|---|---|
| Users | `root` and `deploy` |
| Password (both users) | `conntest123` |
| Pubkeys in `authorized_keys` | `id_ed25519.pub`, `id_rsa.pub` (4096), `id_ed25519_pw.pub` |
| Both password **and** public-key auth | enabled everywhere |

### Test keys (`keys/`, no-passphrase unless noted)

| File | Type | Passphrase |
|---|---|---|
| `id_ed25519` / `.pub` | ed25519 | — |
| `id_rsa` / `.pub` | RSA 4096 | — |
| `id_ed25519_pw` / `.pub` | ed25519 | `testpass` |
| `authorized_keys` | the three `.pub` above, concatenated | — |

## Usage

```bash
# bring the whole matrix up (idempotent — safe to re-run)
docker compose up -d --build

# prove the environment is healthy (auth matrix + RSA focus + jump chain)
./verify.sh

# tear everything down (containers + network + volumes)
./teardown.sh
./teardown.sh --images     # also delete the built images
```

`docker compose up -d` is idempotent: re-running it recreates nothing if configs
are unchanged. `teardown.sh` is safe to run repeatedly.

## Connecting by hand

Always disable host-key persistence for these throwaway hosts:

```bash
SSHOPTS='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'

# password auth (you'll be prompted for conntest123)
ssh $SSHOPTS -p 2202 deploy@127.0.0.1

# ed25519 key
ssh $SSHOPTS -p 2202 -i keys/id_ed25519 deploy@127.0.0.1

# RSA key (negotiates rsa-sha2-512 automatically)
ssh $SSHOPTS -p 2202 -i keys/id_rsa deploy@127.0.0.1

# passphrase-protected key (passphrase: testpass)
ssh $SSHOPTS -p 2202 -i keys/id_ed25519_pw deploy@127.0.0.1

# old server: force a legacy algorithm to confirm centos7 supports it
ssh $SSHOPTS -p 2204 -i keys/id_ed25519 -o HostKeyAlgorithms=ssh-rsa deploy@127.0.0.1
ssh $SSHOPTS -p 2204 -i keys/id_ed25519 -o KexAlgorithms=diffie-hellman-group14-sha1 deploy@127.0.0.1
ssh $SSHOPTS -p 2204 -i keys/id_ed25519 -o Ciphers=aes256-cbc deploy@127.0.0.1

# dropbear
ssh $SSHOPTS -p 2205 -i keys/id_ed25519 deploy@127.0.0.1
```

### Jump chain (host → bastion → internal)

`conn-internal` has **no published port**; reach it only through the bastion.
Note: `-o` flags do NOT propagate to `-J`'s implicit proxy, so give the jump its
settings via a config file (or use an ssh-agent):

```bash
cat > /tmp/jump.cfg <<EOF
Host *
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  IdentityFile $PWD/keys/id_ed25519
  IdentitiesOnly yes
EOF

ssh -F /tmp/jump.cfg -J deploy@127.0.0.1:2206 deploy@conn-internal hostname
# -> prints the internal container's hostname (via direct-tcpip through bastion)
```

## Layout

```
S1-ssh-matrix/
├── docker-compose.yml     # the 7-container matrix (idempotent)
├── verify.sh              # auth matrix + RSA/legacy focus tests + jump chain
├── teardown.sh            # clean removal (add --images to drop images too)
├── ALGORITHMS.md          # per-distro algorithm inventory (core S1 output)
├── README.md              # this file
├── keys/                  # generated test keypairs + authorized_keys
└── build/
    ├── apt/Dockerfile     # ubuntu22/24, debian12, bastion, internal (BASE arg)
    ├── apt/sshd_extra.conf
    ├── centos7/Dockerfile # vault.centos.org repos + legacy sshd profile
    └── alpine/Dockerfile  # dropbear
```

## Notes / gotchas

- **CentOS 7 is EOL** — its Dockerfile repoints yum at `vault.centos.org` (the live
  mirrors are dead). The `centos:7` image itself still pulls fine from Docker Hub.
- **Modern OpenSSH + RSA:** an RSA *key* still authenticates against ubuntu24 — the
  client just signs with `rsa-sha2-512`, not the legacy `ssh-rsa` (SHA-1) algorithm.
  See `ALGORITHMS.md` §4 and the verify.sh "RSA focus" output. This is the single
  most important finding for SSH-engine selection.
- **Docker pulls slow on first run:** the host routes Docker through a local proxy;
  the very first manifest fetch can take a while, then it is fast. Not an error.

# Uniform Dockerfile for apt-based distros (Ubuntu / Debian).
# BASE is passed per-service from docker-compose.yml.
# Build context is the S1-ssh-matrix root, so COPY paths are repo-relative.
ARG BASE=ubuntu:24.04
FROM ${BASE}

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends openssh-server ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# root password + a normal "deploy" user with password.
RUN mkdir -p /run/sshd \
 && echo 'root:conntest123' | chpasswd \
 && useradd -m -s /bin/bash deploy \
 && echo 'deploy:conntest123' | chpasswd

# authorized_keys (ed25519 + RSA) for BOTH root and deploy.
COPY keys/authorized_keys /root/.ssh/authorized_keys
COPY keys/authorized_keys /home/deploy/.ssh/authorized_keys
RUN chmod 700 /root/.ssh /home/deploy/.ssh \
 && chmod 600 /root/.ssh/authorized_keys /home/deploy/.ssh/authorized_keys \
 && chown -R deploy:deploy /home/deploy/.ssh

# Drop-in that wins (00- sorts first). Enables BOTH password + pubkey auth.
# NOTE: we deliberately do NOT touch HostKeyAlgorithms / PubkeyAcceptedKeyTypes,
# so these hosts keep the modern OpenSSH default (legacy ssh-rsa / SHA-1 disabled).
COPY build/apt/sshd_extra.conf /etc/ssh/sshd_config.d/00-conn.conf

EXPOSE 22
CMD ["/usr/sbin/sshd", "-D", "-e"]

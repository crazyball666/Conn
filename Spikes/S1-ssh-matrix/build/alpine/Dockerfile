# Alpine + dropbear = the NON-OpenSSH sample (BusyBox userland, dropbear server).
FROM alpine:latest

RUN apk add --no-cache dropbear dropbear-ssh shadow

# root + deploy user, both with passwords. (shadow provides useradd/chpasswd.)
RUN echo 'root:conntest123' | chpasswd \
 && useradd -m -s /bin/ash deploy \
 && echo 'deploy:conntest123' | chpasswd \
 && mkdir -p /root/.ssh /home/deploy/.ssh /etc/dropbear

# dropbear reads the same authorized_keys format (ed25519 + rsa both supported).
COPY keys/authorized_keys /root/.ssh/authorized_keys
COPY keys/authorized_keys /home/deploy/.ssh/authorized_keys
RUN chmod 700 /root/.ssh /home/deploy/.ssh \
 && chmod 600 /root/.ssh/authorized_keys /home/deploy/.ssh/authorized_keys \
 && chown -R deploy:deploy /home/deploy/.ssh

# Pre-generate dropbear host keys (ed25519 + rsa).
RUN dropbearkey -t ed25519 -f /etc/dropbear/dropbear_ed25519_host_key \
 && dropbearkey -t rsa -s 4096 -f /etc/dropbear/dropbear_rsa_host_key

EXPOSE 22
# -F foreground, -E log to stderr, -R auto-gen missing host keys, -p port.
# Password auth + root login are enabled by default in dropbear.
CMD ["dropbear", "-F", "-E", "-R", "-p", "22"]

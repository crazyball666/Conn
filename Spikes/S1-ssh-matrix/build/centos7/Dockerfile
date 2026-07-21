# CentOS 7 = the "old server" sample. OpenSSH 7.4, amd64-only (runs via Rosetta).
# CentOS 7 is EOL: the mirror.centos.org mirrorlists are dead, so we repoint
# yum at vault.centos.org before installing anything.
FROM centos:7

# Redirect all repos to the frozen vault.
RUN sed -i \
      -e 's|^mirrorlist=|#mirrorlist=|g' \
      -e 's|^#\s*baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' \
      /etc/yum.repos.d/CentOS-*.repo \
 && yum -y --disablerepo='*' --enablerepo=base --enablerepo=updates install openssh-server openssh-clients \
 && yum clean all

# root + deploy user, both with passwords.
RUN echo 'root:conntest123' | chpasswd \
 && useradd -m -s /bin/bash deploy \
 && echo 'deploy:conntest123' | chpasswd \
 && mkdir -p /root/.ssh /home/deploy/.ssh

COPY keys/authorized_keys /root/.ssh/authorized_keys
COPY keys/authorized_keys /home/deploy/.ssh/authorized_keys
RUN chmod 700 /root/.ssh /home/deploy/.ssh \
 && chmod 600 /root/.ssh/authorized_keys /home/deploy/.ssh/authorized_keys \
 && chown -R deploy:deploy /home/deploy/.ssh

# Generate host keys (rsa/ecdsa/ed25519).
RUN /usr/bin/ssh-keygen -A

# OpenSSH 7.4 has no sshd_config.d Include => append directly.
# Explicitly (re)enable the legacy SHA-1 algorithms so this is a genuine
# "old server" that offers ssh-rsa to clients.
RUN { \
      echo ''; \
      echo '# --- conn Spike S1: old-server profile ---'; \
      echo 'PermitRootLogin yes'; \
      echo 'PasswordAuthentication yes'; \
      echo 'PubkeyAuthentication yes'; \
      echo 'UsePAM yes'; \
      echo 'HostKeyAlgorithms +ssh-rsa'; \
      echo 'PubkeyAcceptedKeyTypes +ssh-rsa'; \
      echo 'KexAlgorithms +diffie-hellman-group14-sha1,diffie-hellman-group1-sha1'; \
      echo 'Ciphers +aes256-cbc,aes128-cbc,3des-cbc'; \
    } >> /etc/ssh/sshd_config

EXPOSE 22
CMD ["/usr/sbin/sshd", "-D", "-e"]

#!/bin/bash
set -e
touch /etc/cloud/cloud-init.disabled 2>/dev/null || true
id ubuntu &>/dev/null || useradd -m -s /bin/bash ubuntu
usermod -s /bin/bash -aG sudo ubuntu 2>/dev/null || true
echo "ubuntu ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-juju
chmod 440 /etc/sudoers.d/90-juju
KEY="${JUJU_CLIENT_PUBKEY:-}"
[ -n "$KEY" ] || { echo "JUJU_CLIENT_PUBKEY is required" >&2; exit 1; }
for home in /home/ubuntu /root; do
  install -d -m 700 "$home/.ssh"
  touch "$home/.ssh/authorized_keys"
  grep -qxF "$KEY" "$home/.ssh/authorized_keys" || printf '%s\n' "$KEY" >> "$home/.ssh/authorized_keys"
  chmod 600 "$home/.ssh/authorized_keys"
done
chown -R ubuntu:ubuntu /home/ubuntu/.ssh
systemctl enable --now ssh >/dev/null 2>&1 || true
systemctl enable --now snapd snapd.socket >/dev/null 2>&1 || true
if command -v snap >/dev/null 2>&1; then
  for i in $(seq 1 30); do snap list >/dev/null 2>&1 && break; sleep 2; done
fi
echo "INIT-OK $(hostname) $(hostname -I) snapd=$(snap version 2>/dev/null | grep -w snap | head -1 | awk "{print \$2}")"

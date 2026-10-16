# shellcheck shell=bash
# Shared setup of the integration tests, sourced after NAME (the container
# and image name) is set: a throwaway Ubuntu with systemd in a privileged
# local container, reachable as $HOST over ssh with root_key, then admin_key
# once vps-init has run. Everything is removed on exit.
#
# The real ~/.ssh/config is never read or written: an `ssh` shim first in PATH
# adds -F with a config of its own.

NAME=${NAME:?set NAME before sourcing integration_lib.sh}
HERE="$(cd "$(dirname "$0")" && pwd)"
# Used by the sourcing scripts.
# shellcheck disable=SC2034
SKILL="${HERE%/scripts}"
HOST=dtest
W=$(mktemp -d)
FAILED=0
PIDS=()

cleanup() {
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
  docker rm -f -v "$NAME" >/dev/null 2>&1 || true
  docker image rm "$NAME:latest" >/dev/null 2>&1 || true
  rm -rf "$W"
}
trap cleanup EXIT

say() { printf '\n=== %s\n' "$*"; }
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }
check() { local name=$1; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }
no_warn() { ! grep -q '^  WARN  ' <<<"$1"; }
finish() {
  echo
  if [[ $FAILED -ne 0 ]]; then echo "$FAILED failed"; exit 1; fi
  echo "all passed"
}

# --- keys, ssh config, shim -----------------------------------------------
mkdir -p "$W/bin" "$W/tmp" "$W/image"
ssh-keygen -q -t ed25519 -N '' -C it-root -f "$W/root_key"
ssh-keygen -q -t ed25519 -N '' -C it-admin -f "$W/admin_key"
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
cat > "$W/ssh_config" <<EOF
Host $HOST
  HostName 127.0.0.1
  Port $PORT
  IdentityFile $W/admin_key
  IdentityFile $W/root_key
  IdentitiesOnly yes
  UserKnownHostsFile $W/known_hosts
  StrictHostKeyChecking accept-new
EOF
printf '#!/bin/sh\nexec /usr/bin/ssh -F %s "$@"\n' "$W/ssh_config" > "$W/bin/ssh"
chmod +x "$W/bin/ssh"
export PATH="$W/bin:$PATH" TMPDIR="$W/tmp"
# Settings of the scripts under test; the real ~/.config/devops/env is never read.
export DEVOPS_CONFIG=/dev/null DEVOPS_ADMIN=ops DEVOPS_PUBKEY_FILE="$W/admin_key.pub" \
  DEVOPS_REGISTRY=git.example.com DEVOPS_REGISTRY_USER=ops
# The remote commands are assembled here on purpose, with local values in them.
# shellcheck disable=SC2029
admin() { ssh "$DEVOPS_ADMIN@$HOST" "$@"; }

# --- the server -----------------------------------------------------------
say "server image"
cp "$W/root_key.pub" "$W/image/root_key.pub"
cat > "$W/image/Dockerfile" <<'EOF'
FROM ubuntu:24.04
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y \
      systemd systemd-sysv openssh-server sudo curl ca-certificates iproute2 iptables python3 \
    && systemctl enable ssh && mkdir -p -m 700 /root/.ssh
COPY root_key.pub /root/.ssh/authorized_keys
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
EOF
docker build -q -t "$NAME:latest" "$W/image" >/dev/null
docker run -d --name "$NAME" --privileged --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw -v /var/lib/docker -v /var/lib/containerd \
  -p "127.0.0.1:$PORT:22" "$NAME:latest" >/dev/null
for _ in $(seq 60); do ssh -o BatchMode=yes "root@$HOST" true 2>/dev/null && break; sleep 1; done

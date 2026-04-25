#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

. "$PROJECT_ROOT/lib/init-launcher.sh"

AGENT="claude"
OPT_BASE_HASH=""
OPT_TOOL_HASH=""
OPT_AGENT_HASH=""
FORCE_PULL=""
BASE_IMAGE=""
MACHINE_CPUS=""
MACHINE_MEMORY=""
MACHINE_DISK_SIZE=""
ALLOW_DNF=""
while [ $# -gt 0 ]; do
  case "$1" in
    --agent)       AGENT="$2"; shift 2 ;;
    --base-hash)   OPT_BASE_HASH="$2"; shift 2 ;;
    --tool-hash)   OPT_TOOL_HASH="$2"; shift 2 ;;
    --agent-hash)  OPT_AGENT_HASH="$2"; shift 2 ;;
    --force-pull)  FORCE_PULL=1; shift ;;
    --image)       BASE_IMAGE="$2"; shift 2 ;;
    --cpus)        MACHINE_CPUS="$2"; shift 2 ;;
    --memory)      MACHINE_MEMORY="$2"; shift 2 ;;
    --disk-size)   MACHINE_DISK_SIZE="$2"; shift 2 ;;
    --allow-dnf)   ALLOW_DNF=1; shift ;;
    --log-level)
      case "$2" in
        I|i) LOG_LEVEL=I ;;
        W|w) LOG_LEVEL=W ;;
        E|e) LOG_LEVEL=E ;;
        *) log E launcher arg-parse "invalid --log-level: $2 (want I, W, or E)"; exit 1 ;;
      esac
      shift 2
      ;;
    *) log E launcher arg-parse "unknown option: $1"; exit 1 ;;
  esac
done
: "${LOG_LEVEL:=W}"
MACHINE_ARGS=""
[ -n "$MACHINE_CPUS" ]      && MACHINE_ARGS="$MACHINE_ARGS --cpus $MACHINE_CPUS"
[ -n "$MACHINE_MEMORY" ]    && MACHINE_ARGS="$MACHINE_ARGS --memory $MACHINE_MEMORY"
[ -n "$MACHINE_DISK_SIZE" ] && MACHINE_ARGS="$MACHINE_ARGS --disk-size $MACHINE_DISK_SIZE"
[ -n "$BASE_IMAGE" ]        && MACHINE_ARGS="$MACHINE_ARGS --image $BASE_IMAGE"

MACHINE_NAME=""
trap '
  if [ -n "$MACHINE_NAME" ]; then
    log I vm teardown "$MACHINE_NAME"
    podman machine stop "$MACHINE_NAME" 2>/dev/null || true
    _i=0
    while [ "$_i" -lt 3 ]; do
      podman machine rm -f "$MACHINE_NAME" 2>/dev/null || true
      podman machine inspect "$MACHINE_NAME" >/dev/null 2>&1 || break
      _i=$((_i + 1))
      sleep 1
    done
    if podman machine inspect "$MACHINE_NAME" >/dev/null 2>&1; then
      log E vm leak "$MACHINE_NAME still present after 3 rm attempts; manual cleanup required (check ~/.local/share/containers/podman/machine/ and ~/.config/containers/podman/machine/)"
    fi
  fi
' EXIT

init_launcher

# The VM backend runs the agent as the FCOS 'core' user (see
# bin/bootstrap-agent-user.sh for why a separate uid 24368 isn't
# viable on virtiofs). For agents without a config-dir env var
# (gemini), agent_load anchored AGENT_SANDBOX_DIR at /home/agent —
# re-anchor against /home/core so the mount target matches the
# agent's actual $HOME inside the VM. Env-based agents (claude/codex)
# mount at /usr/local/etc/agent-sandbox/<agent>, independent of $HOME
# (the env var, baked into agent-manifest.sh, points there) — leave
# them untouched.
if [ -z "$AGENT_SANDBOX_ENV" ]; then
  _default=$(agent_get .configDir.default)
  case "$_default" in
    '$HOME'*) AGENT_SANDBOX_DIR="/home/core${_default#\$HOME}" ;;
    *)        AGENT_SANDBOX_DIR="$_default" ;;
  esac
fi

# ── Runtime VM ──

# Podman supports only one running machine per host (the VM backend
# binds a fixed gvproxy port). Stop any *other* running machine so this
# launcher can start its own — but warn loudly so the user knows their
# unrelated work was interrupted. The current machine has already been
# stopped above, so any remaining "Running" entries are someone else's.
stop_all_machines() {
  podman machine list --format '{{.Name}} {{.Running}}' --noheading 2>/dev/null \
    | sed 's/\*//' \
    | while read -r _name _running; do
        [ "$_running" = "true" ] || continue
        log W vm stop-other "stopping running machine '$_name' (podman allows one running machine at a time)"
        podman machine stop "$_name" 2>/dev/null || true
      done
}

# 128-bit MD5 of $PWD encoded as 22 base62 chars (zero-padded). With the
# `sandbox-` prefix the name is exactly 30 chars, the macOS Podman cap
# (driven by the AF_UNIX socket-path budget). bc is required because
# 128-bit ints exceed POSIX shell arithmetic; awk does the digit→char
# mapping in the same pipeline so the encoder is a single 3-process
# pipeline (bc | awk under one $(…)) rather than a per-digit fork loop.
command -v bc >/dev/null 2>&1 || {
  log E launcher missing-dep "bc not found; required for machine-name encoding (install via: brew install bc / dnf install bc)"
  exit 1
}
_hex=$(md5 "$PWD" | tr 'a-f' 'A-F')
case "$_hex" in
  [0-9A-F]*[0-9A-F]) ;;
  *) log E launcher hash-fail "md5(\"\$PWD\") returned no/garbage hex (got: '$_hex'); check ulimit -n (need >256)"; exit 1 ;;
esac
WORKDIR_HASH=$(bc <<EOF | awk '
BEGIN { b62 = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"; out = "" }
      { out = substr(b62, $1 + 1, 1) out }
END   { while (length(out) < 22) out = "0" out; print out }
'
ibase=16
n=$_hex
ibase=A
while (n > 0) { n % 62; n = n / 62 }
EOF
)
case "$WORKDIR_HASH" in
  0000000000000000000000)
    log E launcher hash-fail "encoder produced all-zero hash (bc/awk pipeline failed silently); check ulimit -n"
    exit 1 ;;
esac
MACHINE_NAME="sandbox-$WORKDIR_HASH"

podman machine stop "$MACHINE_NAME" 2>/dev/null || true
podman machine rm -f "$MACHINE_NAME" 2>/dev/null || true
stop_all_machines

log I vm init "$MACHINE_NAME"
podman machine init "$MACHINE_NAME" $MACHINE_ARGS \
  --volume "$PWD:/var/workdir"
log I vm start "$MACHINE_NAME"
podman machine start "$MACHINE_NAME"

# Stage log.sh to the canonical in-sandbox path (baked into the image on
# container/WSL backends; absent on Fedora CoreOS — must be installed here
# before any bin/*.sh that sources it runs).
log I vm setup "installing log.sh"
cat "$PROJECT_ROOT/lib/log.sh" | podman machine ssh "$MACHINE_NAME" \
  'sudo install -d -m 0755 /usr/local/lib/agent-sandbox && sudo tee /usr/local/lib/agent-sandbox/log.sh >/dev/null && sudo chmod 0644 /usr/local/lib/agent-sandbox/log.sh'

log I mounts assemble "$AGENT_SANDBOX_DIR"
cat "$PROJECT_ROOT/bin/setup-system-mounts.sh" | podman machine ssh "$MACHINE_NAME" \
  'cat > /tmp/setup-system-mounts.sh && chmod +x /tmp/setup-system-mounts.sh'

# Encode each file list as base64 of NUL-delimited UTF-8 so filenames
# with quotes/spaces/newlines/metachars survive both the SSH command-
# string interpolation AND the receiver's iteration. Empty arrays
# produce an empty string (printf '%s\0' with zero args still emits a
# NUL on bash, so we guard with ${#arr[@]}).
_encode_nul_b64() {
  if [ "$#" -eq 0 ]; then printf ''; else printf '%s\0' "$@" | base64 | tr -d '\n'; fi
}
_CF_B64=$(_encode_nul_b64 ${CONFIG_FILES[@]+"${CONFIG_FILES[@]}"})
_RF_B64=$(_encode_nul_b64 ${RO_FILES[@]+"${RO_FILES[@]}"})
_RD_B64=$(_encode_nul_b64 ${RO_DIRS[@]+"${RO_DIRS[@]}"})
podman machine ssh "$MACHINE_NAME" \
  "sudo /tmp/setup-system-mounts.sh \
     --log-level ${LOG_LEVEL:-W} \
     --workdir /var/workdir \
     --project-dir '$AGENT_PROJECT_DIR' \
     --target '$AGENT_SANDBOX_DIR' \
     --config-files '$_CF_B64' \
     --ro-files '$_RF_B64' \
     --ro-dirs '$_RD_B64'"

log I archive inject "base+tool+$AGENT tarballs"
cat "$PROJECT_ROOT/bin/setup-tools.sh" | podman machine ssh "$MACHINE_NAME" \
  'cat > /tmp/setup-tools.sh && chmod +x /tmp/setup-tools.sh'
_ARCHIVE_ARGS=""
for _archive in "$BASE_ARCHIVE" "$TOOL_ARCHIVE" "$AGENT_ARCHIVE"; do
  _name=$(basename "$_archive")
  cat "$_archive" | podman machine ssh "$MACHINE_NAME" "cat > /tmp/$_name"
  _ARCHIVE_ARGS="$_ARCHIVE_ARGS /tmp/$_name"
done
podman machine ssh "$MACHINE_NAME" "/tmp/setup-tools.sh --log-level ${LOG_LEVEL:-W}$_ARCHIVE_ARGS"

# Install enable-dnf + the per-user bootstrap sudoers rule. Container/
# WSL backends bake these into the image (Containerfile lines 18-24);
# FCOS gets a fresh stock VM each launch, so we install here. The
# per-user sudoers rule survives the strip-sudo step below — group
# membership and per-user rules are independent in sudoers.
log I vm install-dnf "enable-dnf + sudoers rule for core"
cat "$PROJECT_ROOT/bin/enable-dnf.sh" | podman machine ssh "$MACHINE_NAME" \
  'sudo tee /usr/local/lib/agent-sandbox/enable-dnf >/dev/null && sudo chmod 0755 /usr/local/lib/agent-sandbox/enable-dnf'
sed 's|__USER__|core|g' "$PROJECT_ROOT/config/sudoers-enable-dnf.tmpl" | podman machine ssh "$MACHINE_NAME" \
  'sudo tee /etc/sudoers.d/core-enable-dnf >/dev/null && sudo chmod 0440 /etc/sudoers.d/core-enable-dnf && sudo visudo -cf /etc/sudoers.d/core-enable-dnf'

# Strip core of sudo/wheel group membership so the agent (which runs
# as core for /var/workdir uid parity) cannot escalate. MUST happen
# AFTER all sudo-requiring setup steps and BEFORE the launch SSH
# session — the launch session opens fresh and PAM reads the updated
# /etc/group at login. The per-user sudoers rule installed above
# stays in effect (sudoers per-user rules don't depend on group).
log I vm strip-sudo "dropping core from sudo/wheel"
cat "$PROJECT_ROOT/bin/bootstrap-agent-user.sh" | podman machine ssh "$MACHINE_NAME" \
  'cat > /tmp/bootstrap-agent-user.sh && chmod +x /tmp/bootstrap-agent-user.sh && sudo /tmp/bootstrap-agent-user.sh'

# ── Launch ──

# Two inspect calls so an IdentityPath containing a space (custom
# machine dir) round-trips intact — the joined format would silently
# truncate at the first space.
SSH_PORT=$(podman machine inspect "$MACHINE_NAME" --format '{{.SSHConfig.Port}}')
SSH_KEY=$(podman machine inspect "$MACHINE_NAME" --format '{{.SSHConfig.IdentityPath}}')

# A fresh SSH session: PAM reads /etc/group at login, so this session
# sees core after the strip-sudo step — no sudo/wheel membership, no
# escalation path. `exec` replaces the SSH shell with the agent so
# there's no parent shell remaining for a TTY hijack (TIOCSTI) on
# agent exit; ssh closes when the agent process does.
_ENV=""
[ -n "$ALLOW_DNF" ] && _ENV="$_ENV SANDBOX_ALLOW_DNF=1"
log I run launch "ssh -tt core@localhost (machine $MACHINE_NAME, agent $AGENT)"
ssh -tt -p "$SSH_PORT" -i "$SSH_KEY" \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
  core@localhost \
  "cd /var/workdir && exec env $_ENV \$HOME/.local/bin/$AGENT_BINARY --log-level ${LOG_LEVEL:-W}"

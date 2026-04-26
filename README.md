# CRATE

**CRATE Runs Agents in Temporary Environments.**

Run an AI coding agent — [Claude Code](https://github.com/anthropics/claude-code), [Gemini CLI](https://github.com/google-gemini/gemini-cli), or [OpenAI Codex](https://github.com/openai/codex) — inside a disposable sandbox (a Podman container, a throwaway Podman VM, or a throwaway WSL distro) so the agent's "skip all permission prompts" mode can be used without giving it access to your host.

The current working directory is mounted into the sandbox at `/var/workdir` and becomes the agent's scratch space. Everything else on the host is invisible.

## Why

`claude --dangerously-skip-permissions`, `gemini --yolo`, and `codex --dangerously-bypass-approvals-and-sandbox` all skip tool-use prompts. That is convenient but gives the agent unrestricted shell access to whatever it can reach. Running it inside a fresh, short-lived sandbox contains the blast radius: the agent sees only the project directory you mounted and a minimal pre-baked toolchain, and the sandbox is discarded at exit.

## Supported agents

Selected with `--agent NAME` (default: `claude`). Each agent is defined declaratively in `agent/<name>/manifest.json` — no per-agent shell code.

| Agent | `--agent` value | Project dir | Host config dir |
|-------|-----------------|-------------|-----------------|
| Claude Code  | `claude` (default) | `.claude`  | `$CLAUDE_CONFIG_DIR` or `~/.claude`  |
| Gemini CLI   | `gemini`           | `.gemini`  | `~/.gemini`                          |
| OpenAI Codex | `codex`            | `.codex`   | `$CODEX_HOME` or `~/.codex`          |

## What you get inside the sandbox

A user `agent` with `$HOME/.local/bin` on `PATH` containing:

- `node` (Node.js LTS)
- `rg` (ripgrep)
- `micro` (editor, set as `$EDITOR`)
- `pnpm`
- `uv`, `uvx`
- The chosen agent under its native command name (`claude` / `gemini` / `codex`), implemented as a wrapper that execs the real binary with the agent's permission-skip flags and env vars baked in.

Optional: pass `--allow-dnf` (POSIX) or `-AllowDnf` (PowerShell) to enable `sudo dnf` inside the sandbox for installing extra packages during a session. This flag must be provided at sandbox startup; if omitted, the bootstrap permission is revoked before the agent starts to prevent autonomous privilege escalation. Requires a Fedora-based image (the default). Supported on the container and WSL backends only — `podman-machine.sh` runs Fedora CoreOS, which uses `rpm-ostree` instead of dnf, so the flag is a no-op there.

## Sandbox backends

Four launcher scripts, same flags, same result — pick whichever matches your host:

| Script                        | Host            | Isolation                                                                         |
| ----------------------------- | --------------- | --------------------------------------------------------------------------------- |
| `script/podman-container.sh`  | Linux / macOS   | Podman container, rootless, `--userns=keep-id`                                    |
| `script/podman-machine.sh`    | Linux / macOS   | Fresh Podman VM per workdir, destroyed on exit                                    |
| `script/podman-container.ps1` | Windows (WSL 2) | Podman container via Podman Desktop / WSL backend                                 |
| `script/wsl.ps1`              | Windows (WSL 2) | Fresh WSL distro per workdir imported from the Podman image, unregistered on exit |

## Usage

From the directory you want to expose to the agent:

```sh
# Linux / macOS — container (default agent: claude)
/path/to/crate/script/podman-container.sh

# Same, but pick a different agent
/path/to/crate/script/podman-container.sh --agent gemini
/path/to/crate/script/podman-container.sh --agent codex

# Linux / macOS — fresh VM per session
/path/to/crate/script/podman-machine.sh --agent claude

# Windows — container
& C:\path\to\crate\script\podman-container.ps1 -Agent gemini

# Windows — fresh WSL2 distro per session
& C:\path\to\crate\script\wsl.ps1 -Agent codex
```

All scripts accept:

| Flag (sh)         | Flag (ps1)      | Meaning                                                         |
| ----------------- | --------------- | --------------------------------------------------------------- |
| `--agent NAME`    | `-Agent NAME`   | Which agent to launch: `claude` (default), `gemini`, `codex`    |
| `--base-hash H`   | `-BaseHash H`   | Pin Tier-1 archive to a cached hash prefix (skip version fetch) |
| `--tool-hash H`   | `-ToolHash H`   | Pin Tier-2 archive                                              |
| `--agent-hash H`  | `-AgentHash H`  | Pin Tier-3 (agent) archive                                      |
| `--force-pull`    | `-ForcePull`    | Ignore caches, re-download and rebuild                          |
| `--image IMG`     | `-Image IMG`    | Override base OS image (default `fedora:latest`)                |
| `--allow-dnf`     | `-AllowDnf`     | Grant `agent` passwordless `sudo dnf` inside the sandbox        |
| `--log-level LVL` | `-LogLevel LVL` | Logging threshold: `I` (verbose info), `W` (warn+error, default), `E` (error only). Default keeps successful launches quiet — pass `--log-level I` for full progress output. Forwarded to every child process via explicit `--log-level` args. |

`podman-machine.sh` additionally takes `--cpus`, `--memory`, `--disk-size` and forwards them to `podman machine init`.

## How it works

### Three-tier tool cache

`lib/tools.sh` and `lib/Tools.ps1` build three content-addressed `.tar.xz` archives under `$XDG_CACHE_HOME/crate/tools/` (or `%LOCALAPPDATA%\.cache\crate\tools\` on Windows). Compression is xz level 0 multi-threaded (`-0 -T0`) — `-0` is the smallest preset that still enables threaded LZMA2, trading a few MB of extra size for a ~5-10× pack speedup vs `-6`/`-9` while still beating gzip `-9` on ratio:

1. **base** — `node` + `rg` + `micro`. Hash keyed on each tool version. Shared across all agents.
2. **tool** — `pnpm` + `uv` + `uvx`. Hash keyed on their versions. Shared across all agents.
3. **`<agent>`** — the selected agent's binary (platform binary unpacked from npm, or a node-bundle shim that execs the main JS via `node`), plus the generic `agent-wrapper` under the agent's command name, plus a baked `agent-manifest.sh` that sources the agent's launch flags and env vars. Hash keyed on the agent name, npm version, arch, manifest contents, and wrapper source.

Archive filenames: `base-<hash>.tar.xz`, `tool-<hash>.tar.xz`, `<agent>-<hash>.tar.xz`. Cache is reusable across sessions; `--force-pull` rebuilds and `--{base,tool,agent}-hash` pins to an existing cached hash prefix so you can freeze a known-good toolchain without network access.

Tier 3 uses the same npm `optionalDependencies` platform-sub-package pattern that esbuild pioneered, so **all three agents share one fetch path**. Claude and Codex publish platform-specific tarballs containing an ELF binary; Gemini publishes a JS bundle consumed via `node`. The manifest's `executable.type` (`platform-binary` / `node-bundle`) selects the post-extract path; `tarballUrl` is a template with `{arch}`, `{triple}`, and `{version}` placeholders.

### Declarative agent manifests

Each agent's shape is described in `agent/<name>/manifest.json`:

- `projectDir` — per-agent staging dir (`.claude`, `.gemini`, `.codex`). The sandbox's system-scope config lives in `$PWD/<projectDir>/.system/`.
- `configDir` — where the agent reads its config on the host (respecting env-var overrides like `CLAUDE_CONFIG_DIR` / `CODEX_HOME`).
- `files.rw` / `files.ro` / `files.roDirs` — which host files hardlink into the sandbox vs. copy read-only.
- `credential.strategy` — selects an OAuth refresh handler (`oauth-anthropic`, `oauth-google`, or `oauth-openai`), wired through `lib/cred/<strategy>.sh` and its PowerShell mirror.
- `executable` — npm package name, tarball URL template, bin/entry path inside the tarball.
- `launch.flags` / `launch.env` — baked into the tier-3 archive as `agent-manifest.sh`, sourced by the wrapper at startup.

Adding a fourth agent is a matter of dropping a new `agent/<name>/` directory with a manifest and a matching `lib/cred/<strategy>.sh` if the OAuth flow is new.

### Sandbox bootstrap

`Containerfile` builds a minimal Fedora image with an `agent` user, `sudo`, and a guarded `enable-dnf` helper. It does not bake any tooling or agent into the image. Instead, its `ENTRYPOINT` invokes `bin/setup-tools.sh`, which extracts the three archives mounted at `/tmp/{base,tool,agent}.tar.xz` into `$HOME/.local/bin` (with node-bundle `<agent>-pkg/` dirs relocated to `$HOME/.local/lib/`), sources the baked `agent-manifest.sh` to learn which agent to exec, and launches the wrapper. The same script is used by the VM and WSL2 backends to set up the toolchain after archive injection.

This keeps the image itself small, stable, and agent-agnostic — toolchain and agent upgrades happen in the cache, not in the image.

### Credentials and global config

`lib/ensure-credential.sh` / `lib/Ensure-Credential.ps1` are thin dispatchers that source the agent's OAuth strategy from `lib/cred/<strategy>.sh` (or `.ps1`). Each strategy reads the agent's auth file, refreshes if near expiry, and writes the updated tokens back in-place — so the hardlink in the rw/ bucket propagates the new tokens to the sandbox without needing to restart.

| Agent | Auth file | Refresh endpoint | Strategy |
|-------|-----------|------------------|----------|
| Claude | `~/.claude/.credentials.json` | `platform.claude.com/v1/oauth/token` | `oauth-anthropic` |
| Gemini | `~/.gemini/oauth_creds.json`  | `oauth2.googleapis.com/token`        | `oauth-google`    |
| Codex  | `~/.codex/auth.json`          | `auth.openai.com/oauth/token`        | `oauth-openai`    |

All three strategies use the same shape: a live GET probe (Anthropic's `claude_cli/roles`, Google's `oauth2/v3/userinfo`, OpenAI's `auth.openai.com/oauth/userinfo`) — 200 = valid, 401 = refresh. This tolerates host-clock skew and avoids timestamp math. Codex's `tokens.id_token` is stored on disk as the raw JWT string (Codex parses the struct fields out of it at load time per `codex-rs/login/src/token_data.rs`), so we write the new JWT verbatim — no re-decoding.

If an auth file is missing, you are told to run the agent's native login command (`claude`, `gemini`, `codex login`) on the host once to authenticate.

### Config staging

`lib/init-config.sh` / `lib/Init-Config.ps1` read the file lists from the selected manifest and stage them into the project, under `$PWD/<projectDir>/.system/`. The staging dir has four buckets:

- `ro/` — **copies** of read-only files and directories from the manifest's `files.ro` and `files.roDirs` (recursively). Wiped + re-copied on every launch, so any in-session tampering is undone and upstream deletions propagate. Even if the read-only mount were bypassed, writes cannot reach the host because the copies are independent inodes.
- `rw/` — **hardlinks** to writable files from the manifest's `files.rw`. They share an inode with the agent's config dir on the host, so in-place writes inside the sandbox propagate back immediately. Refreshed with `ln -f` every launch.
- `cr/` — **created at runtime by the agent**: persists across launches as per-project session history. No speculative subdirs are pre-created — the agent `mkdir`s whatever it needs on demand under the cr/-as-base bind mount. The only entries we touch in `cr/` are mount-target placeholders for the per-file/per-subdir overlays.
- `.mask/` — an empty dir, used purely as the bind source that masks `.system/` from project scope inside the sandbox.

**Inside the sandbox** the launchers assemble all four buckets at the agent's in-sandbox config dir. The path depends on whether the agent honors a config-dir env var:

| Agent | In-sandbox path | How the agent finds it |
|-------|-----------------|------------------------|
| Claude | `/usr/local/etc/crate/claude` | wrapper exports `CLAUDE_CONFIG_DIR` |
| Codex  | `/usr/local/etc/crate/codex`  | wrapper exports `CODEX_HOME` |
| Gemini | `/home/agent/.gemini`         | hard-coded default (no env var supported) |

The env-var route keeps `/home/agent` clean of agent-specific state and makes the sandbox path identical across the container (agent user) and podman-machine (core user) backends. Gemini doesn't expose a config-dir env var, so its staging is bind-mounted directly at the hard-coded `~/.gemini` path (rewritten to `/home/core/.gemini` on the VM backend).

Assembly is the same in both cases:

1. `cr/` is bind-mounted as the base of the target (rw — runtime writes land back in the project's `cr/`)
2. each writable file in `rw/` is bind-mounted on top per-file, so the path becomes a mount point — `rename()`/`unlink()` give EBUSY and the agent's atomic-replace code path falls back to in-place `writeFileSync()`, which preserves the host hardlink and syncs changes immediately
3. each `ro/` file and subdir is bind-mounted on top read-only via `mount --bind` + `mount -o remount,bind,ro`
4. `.mask/` is bind-mounted (read-only) on top of `/var/workdir/<projectDir>/.system` so the system bucket is **invisible from project scope**: anything reading under `/var/workdir/<projectDir>/` sees an empty `.system/` while the agent's config dir continues to serve real content.

The atomic-rename → writeFileSync fallback matters because rename semantics differ across drvfs (WSL2), virtiofs (Podman machine), and overlayfs/bind mounts — EBUSY forces a code path that is portable everywhere.

- **Container scripts** assemble everything directly via podman `-v` flag stacking — no in-container privileges required.
- **podman-machine.sh** mounts only the workdir into the VM, then runs `bin/setup-system-mounts.sh` as root over SSH to do steps 1–4.
- **wsl.ps1** mounts only the workdir via `drvfs`, then runs `bin/setup-system-mounts.sh` as root (baked into `/usr/local/libexec/crate/setup-system-mounts.sh` during the import block).

The agent itself is launched as the unprivileged user `agent` — sudo is used solely for the mount syscalls on the VM/WSL backends. The wrapper exports each agent's config-dir env var (baked into the tier-3 `agent-manifest.sh`) so the binary reads from `/usr/local/etc/crate/<agent>` — except for Gemini, which has no such env var and reads from the `~/.gemini` default mount.

> **Supported hosts:** Linux, macOS, and Windows.

The single `$PWD → /var/workdir` mount on the VM/WSL backends is what avoids the macOS vfkit virtio-fs bug where a `mount --bind` whose target sits under a `mount -o remount,ro,bind` virtio-fs parent makes `open()` return EACCES for non-root processes (containers/podman#24725, FB16008360). All binds in this layout have source and target on the same device.

> **Tip:** add `<projectDir>/.system/` to your project `.gitignore` (e.g. `.claude/.system/` when running Claude, `.gemini/.system/` for Gemini, `.codex/.system/` for Codex). That bucket contains your hardlinked credentials and per-project session history — none of it belongs in commits. The launcher warns if the relevant pattern is missing.

Concurrent runs of different agents in the same project do not collide — each agent's `.system/` is independent.

### Lifecycle

- **Container scripts** — `podman run --rm` with the three archives, the workdir, and the per-file/per-subdir `-v` mounts assembling the agent's config dir. Dies with the session; the project's `<projectDir>/.system/` persists by design.
- **podman-machine.sh** — hashes `$PWD` to derive a machine name (`sandbox-<hash>`), inits a fresh VM with a single `$PWD → /var/workdir` virtio-fs volume, runs `bin/setup-system-mounts.sh` over SSH, injects the three tool archives, runs `bin/setup-tools.sh`, then execs the agent as `core`. An `EXIT` trap stops and removes the machine no matter how the session ends.
- **wsl.ps1** — hashes `$PWD` to derive a distro name (`sandbox-<hash>`), imports the Podman base image as a WSL tarball, runs `bin/setup-tools.sh` via `wsl -u root`, bakes `setup-system-mounts.sh` into the distro at a stable path, installs `config/wsl.conf`, mounts the workdir via `drvfs`, runs the in-distro mount setup, and execs the agent. Every launch imports a fresh distro; a `finally` block unregisters it on exit so no state persists between sessions.

## Requirements

- **Linux/macOS:** `podman`, `curl`, `jq`, `rg` (ripgrep), `tar` (GNU ≥ 1.22 or bsdtar), `xz` (XZ Utils ≥ 5.2 for `-T0` multi-threaded compression), `sha256sum` (or `shasum`). For `podman-machine.sh`, a working `podman machine` provider (qemu/applehv/hyperv).
- **Windows:** PowerShell 7+, `podman` (Podman Desktop is fine), `tar.exe` (ships with modern Windows — bsdtar with liblzma), and WSL2 for `wsl.ps1`.
- A prior login on the host for the agent you plan to use, so its auth file exists (`~/.claude/.credentials.json`, `~/.gemini/oauth_creds.json`, or `~/.codex/auth.json`).

## Caveats

- The agent's permission-skip mode is still dangerous *inside* the sandbox — the agent can freely trash `/var/workdir`, which is your real project directory. Commit or stash first if that matters to you.
- Only `linux/amd64` and `linux/arm64` tool archives are built.
- `podman-machine.sh` stops every other running podman machine on launch (Podman supports only one VM at a time) and does not restart them on exit — you'll need to `podman machine start <name>` your previous machine yourself afterward.
- The Gemini CLI has started moving OAuth tokens into the OS keychain on systems where one is available. This sandbox only understands the file-based `~/.gemini/oauth_creds.json` path; if your Gemini install stores tokens in the keychain instead, refresh will fail and you'll need to run `gemini` on the host first to populate the file.

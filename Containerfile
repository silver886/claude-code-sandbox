ARG BASE_IMAGE=fedora:latest
FROM $BASE_IMAGE

RUN (id claude >/dev/null 2>&1 || useradd -m claude) && dnf install -y sudo && dnf clean all
RUN mkdir -p /var/workdir /home/claude/.claude && chown -R claude:claude /var/workdir /home/claude/.claude
RUN mkdir -p /usr/local/lib/claude-code-sandbox && \
    printf '#!/bin/sh\nif [ "$(id -u)" -eq 0 ]; then\n  printf '"'"'claude ALL=(root) NOPASSWD: /usr/bin/dnf\\n'"'"' > /etc/sudoers.d/claude-dnf\n  chmod 0440 /etc/sudoers.d/claude-dnf\n  echo "DNF access enabled for claude"\nelse\n  echo "Run as: sudo /usr/local/lib/claude-code-sandbox/enable-dnf" >&2\n  exit 1\nfi\n' > /usr/local/lib/claude-code-sandbox/enable-dnf && \
    chmod 0755 /usr/local/lib/claude-code-sandbox/enable-dnf && \
    ln /usr/local/lib/claude-code-sandbox/enable-dnf /usr/local/bin/enable-dnf && \
    printf 'claude ALL=(root) NOPASSWD: /usr/local/lib/claude-code-sandbox/enable-dnf\n' > /etc/sudoers.d/claude-enable-dnf && \
    chmod 0440 /etc/sudoers.d/claude-enable-dnf && \
    visudo -cf /etc/sudoers.d/claude-enable-dnf

ENV PATH=/home/claude/.local/bin:$PATH
USER claude
WORKDIR /var/workdir
ENTRYPOINT ["sh", "-c", "\
  mkdir -p $HOME/.local/bin && \
  tar -xJf /tmp/base.tar.xz -C $HOME/.local/bin/ && \
  tar -xJf /tmp/tool.tar.xz -C $HOME/.local/bin/ && \
  tar -xJf /tmp/claude.tar.xz -C $HOME/.local/bin/ && \
  chmod +x $HOME/.local/bin/* && \
  mv $HOME/.local/bin/claude $HOME/.local/bin/claude-bin && \
  mv $HOME/.local/bin/claude-wrapper $HOME/.local/bin/claude && \
  exec $HOME/.local/bin/claude --dangerously-skip-permissions"]

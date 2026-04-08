ARG BASE_IMAGE=fedora:latest
FROM $BASE_IMAGE

RUN id claude >/dev/null 2>&1 || useradd -m claude
RUN mkdir -p /var/workdir /home/claude/.claude && chown -R claude:claude /var/workdir /home/claude/.claude
RUN ln -sf /home/claude/.local/bin/claude-wrapper /usr/local/bin/claude

USER claude
WORKDIR /var/workdir
ENTRYPOINT ["sh", "-c", "\
  mkdir -p $HOME/.local/bin && \
  tar -xzf /tmp/base.tar.gz -C $HOME/.local/bin/ && \
  tar -xzf /tmp/tool.tar.gz -C $HOME/.local/bin/ && \
  tar -xzf /tmp/claude.tar.gz -C $HOME/.local/bin/ && \
  chmod +x $HOME/.local/bin/* && \
  exec $HOME/.local/bin/claude-wrapper --dangerously-skip-permissions"]

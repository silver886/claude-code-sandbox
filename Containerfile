ARG BASE_IMAGE=fedora:latest
FROM $BASE_IMAGE

RUN (id claude >/dev/null 2>&1 || useradd -m claude) && dnf install -y sudo && dnf clean all
RUN mkdir -p /var/workdir /usr/local/lib/claude-code-sandbox /usr/local/libexec/claude-code-sandbox /etc/claude-code-sandbox && \
    chown -R claude:claude /var/workdir /etc/claude-code-sandbox
COPY bin/enable-dnf.sh /usr/local/lib/claude-code-sandbox/enable-dnf
COPY bin/setup-tools.sh /usr/local/libexec/claude-code-sandbox/setup-tools.sh
COPY config/sudoers-claude-enable-dnf /etc/sudoers.d/claude-enable-dnf
RUN chmod 0755 /usr/local/lib/claude-code-sandbox/enable-dnf /usr/local/libexec/claude-code-sandbox/setup-tools.sh && \
    ln /usr/local/lib/claude-code-sandbox/enable-dnf /usr/local/bin/enable-dnf && \
    chmod 0440 /etc/sudoers.d/claude-enable-dnf && \
    visudo -cf /etc/sudoers.d/claude-enable-dnf

ENV PATH=/home/claude/.local/bin:$PATH
USER claude
WORKDIR /var/workdir
ENTRYPOINT ["/usr/local/libexec/claude-code-sandbox/setup-tools.sh", "--exec", "/tmp/base.tar.xz", "/tmp/tool.tar.xz", "/tmp/claude.tar.xz"]

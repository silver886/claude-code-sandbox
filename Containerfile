ARG BASE_IMAGE=fedora:latest
FROM $BASE_IMAGE

# Pin the agent user/group to a high, stable UID/GID (24368) so it will
# not collide with typical host UIDs (1000-range) that keep-id remaps.
# The USER directive below uses the UID numerically, so even if an
# alternative base image has a pre-existing 'agent' at a different UID,
# the container still starts at 24368 and matches keep-id's mapping.
RUN (id agent >/dev/null 2>&1 || (groupadd -g 24368 agent && useradd -m -u 24368 -g 24368 agent)) && \
    dnf install -y sudo && dnf clean all
RUN mkdir -p /var/workdir \
             /usr/local/lib/agent-sandbox \
             /usr/local/libexec/agent-sandbox \
             /usr/local/etc/agent-sandbox && \
    chown -R agent:agent /var/workdir && \
    chmod 0755 /usr/local/etc/agent-sandbox
COPY lib/log.sh /usr/local/lib/agent-sandbox/log.sh
COPY bin/enable-dnf.sh /usr/local/lib/agent-sandbox/enable-dnf
COPY bin/setup-tools.sh /usr/local/libexec/agent-sandbox/setup-tools.sh
COPY config/sudoers-enable-dnf.tmpl /tmp/sudoers-enable-dnf.tmpl
RUN sed 's|__USER__|agent|g' /tmp/sudoers-enable-dnf.tmpl > /etc/sudoers.d/agent-enable-dnf && \
    rm /tmp/sudoers-enable-dnf.tmpl && \
    chmod 0755 /usr/local/lib/agent-sandbox/enable-dnf /usr/local/libexec/agent-sandbox/setup-tools.sh && \
    chmod 0644 /usr/local/lib/agent-sandbox/log.sh && \
    chmod 0440 /etc/sudoers.d/agent-enable-dnf && \
    visudo -cf /etc/sudoers.d/agent-enable-dnf

ENV PATH=/home/agent/.local/bin:$PATH
USER 24368
WORKDIR /var/workdir
ENTRYPOINT ["/usr/local/libexec/agent-sandbox/setup-tools.sh", "--exec", "/tmp/base.tar.xz", "/tmp/tool.tar.xz", "/tmp/agent.tar.xz"]

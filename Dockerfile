FROM node:22

ENV DSH_PORT=3080
ENV DSH_VERSION=0.1.1-rc.2
ENV PNPM_VERSION=11.24.0
ENV LAN_ACCESS_PLUGIN_SPEC=git+https://github.com/mahmut-Abi/dsh-lan-access.git#57d8b393b61101834ae3a741c54ab34c5f7acaf9
ENV DSH_PUBLIC_HOST=
ENV DSH_TRUSTED_HOSTS=

# Aliyun apt mirror for Debian bookworm
RUN sed -i 's|http://deb.debian.org/debian|https://mirrors.aliyun.com/debian|g' \
      /etc/apt/sources.list.d/debian.sources \
    && sed -i 's|http://deb.debian.org/debian-security|https://mirrors.aliyun.com/debian-security|g' \
      /etc/apt/sources.list.d/debian.sources

# Install dependencies + supervisor
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3-pip git curl iproute2 supervisor \
    && rm -rf /var/lib/apt/lists/*

# China mirrors
RUN printf 'registry=https://registry.npmmirror.com\n' > /root/.npmrc \
    && python3 -m pip config set global.index-url https://pypi.tuna.tsinghua.edu.cn/simple \
    && python3 -m pip config set global.trusted-host pypi.tuna.tsinghua.edu.cn

# Install dsh from npm
RUN npm install -g "pnpm@$PNPM_VERSION" "@deepseek-ai/dsh@$DSH_VERSION"

# Install the LAN access plugin from the fork commit that carries the deployment fix.
RUN dsh plugin --profile web add "$LAN_ACCESS_PLUGIN_SPEC"

# Pre-enable LAN access so the plugin rebinds at first boot
RUN mkdir -p /root/.dsh \
    && printf 'lan-access:\n  enabled: true\n' > /root/.dsh/settings.yaml

WORKDIR /app

# Clean up task-board lock
RUN rm -f /root/.dsh/task-board/ledger-v2.lock

# Keep a profile seed for fresh bind mounts and named volumes.
RUN mkdir -p /opt/dsh-home-seed \
    && cp -a /root/.dsh/. /opt/dsh-home-seed/

# Supervisor config
COPY supervisord.conf /etc/supervisor/conf.d/dsh.conf
COPY docker-entrypoint.sh /usr/local/bin/dsh-docker-entrypoint
COPY docker-dsh-web.sh /usr/local/bin/dsh-web-supervised

EXPOSE 3080

ENTRYPOINT ["/bin/sh", "/usr/local/bin/dsh-docker-entrypoint"]

# The official Pelican wine yolk: tini, STOPSIGNAL SIGINT, winehq-staging and Xvfb.
FROM ghcr.io/pelican-eggs/yolks:wine_staging

LABEL org.opencontainers.image.source=https://github.com/geofmigliacci/egg-bannerlord-coop

# The yolk sets WINEPREFIX, WINEDEBUG, WINEDLLOVERRIDES, DISPLAY and XVFB already.
ENV WINEARCH=win64 LANG=C.UTF-8

# The read-only player-count endpoint uses Python's standard library.
USER root
RUN apt-get update && apt-get install -y --no-install-recommends python3 && \
    rm -rf /var/lib/apt/lists/*

# Smoke test in a throwaway prefix: the real one is per-server in the volume.
# Do NOT use `wineserver -w` here, it never returns under xvfb-run and hangs the build.
RUN export WINEPREFIX=/tmp/winecheck; xvfb-run -a wineboot -i && wineserver -k; \
    test -f /tmp/winecheck/system.reg && rm -rf /tmp/winecheck

# git on Windows stores the script 0644, so --chmod sets the exec bit at copy time.
COPY --chmod=755 start.sh /usr/local/bin/start.sh
COPY player_count_api.py /usr/local/bin/player_count_api.py

# No CMD or ENTRYPOINT: the yolk's tini and /entrypoint.sh are inherited, and
# /entrypoint.sh evals the panel's STARTUP command.

# Wings overrides this with its own uid. It matters for plain compose.
USER container

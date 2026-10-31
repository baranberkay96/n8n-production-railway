# n8n Worker for Railway: the n8n queue worker and the n8n task runner launcher
# (JavaScript + Python Code nodes) in one container, so Railway replicas of this service
# add workers and their runners together.
#
# Both parts come from n8n's official images of the same tag: the n8n image is the base,
# and the launcher, the JavaScript runner, the Python runner and the Python interpreter
# it was built for are copied from n8nio/runners. Both images are Alpine 3.24 (same musl,
# OpenSSL and gcompat). N8N_IMAGE_TAG is a service variable referenced from n8n Main;
# Railway passes it as a build argument.
ARG N8N_IMAGE_TAG=2.45.7

FROM n8nio/runners:${N8N_IMAGE_TAG} AS runners
USER root
# Collect the runner files into /export. Paths are derived from the image itself (the
# Python venv's interpreter), so a newer Python in a later runners image still works.
RUN set -eu; \
    out=/export; \
    mkdir -p "$out/usr/local/bin" "$out/usr/local/lib" "$out/opt" "$out/etc" "$out/pylibs" "$out/licenses"; \
    py="$(readlink -f /opt/runners/task-runner-python/.venv/bin/python)"; \
    case "$py" in /usr/local/bin/python3.*) ;; *) echo "unexpected Python interpreter: $py" >&2; exit 1 ;; esac; \
    pyname="$(basename "$py")"; \
    cp -a "$py" "$out/usr/local/bin/"; \
    cp -a /usr/local/lib/lib"$pyname".so* /usr/local/lib/libpython3.so "$out/usr/local/lib/"; \
    cp -a /usr/local/lib/"$pyname" "$out/usr/local/lib/"; \
    cp -a /usr/local/bin/task-runner-launcher "$out/usr/local/bin/"; \
    cp -a /usr/local/bin/LICENSE.md /usr/local/bin/LICENSE_EE.md "$out/licenses/" 2>/dev/null || true; \
    cp -a /opt/runners "$out/opt/"; \
    cp /etc/n8n-task-runners.json "$out/etc/n8n-task-runners.json"; \
    for lib in $(scanelf --needed --nobanner --format '%n#p' --recursive "$py" /usr/local/lib/libpython3* /usr/local/lib/"$pyname"/lib-dynload | tr ',' '\n' | awk '{print $1}' | sort -u); do \
      for dir in /usr/lib /lib; do \
        if [ -e "$dir/$lib" ]; then \
          cp -a "$dir/$lib" "$out/pylibs/"; \
          real="$(readlink -f "$dir/$lib")"; \
          [ "$real" = "$dir/$lib" ] || cp -a "$real" "$out/pylibs/"; \
          break; \
        fi; \
      done; \
    done; \
    ls -l "$out/pylibs"

FROM n8nio/n8n:${N8N_IMAGE_TAG}
USER root

COPY --from=runners /export/usr/local/ /usr/local/
COPY --from=runners /export/opt/runners /opt/runners
COPY --from=runners /export/etc/n8n-task-runners.json /etc/n8n-task-runners.json
COPY --from=runners /export/licenses/ /usr/share/licenses/n8n-task-runner-launcher/
COPY --from=runners /export/pylibs/ /tmp/pylibs/
# 755, not 644: BuildKit gives the directory it creates the same mode (unreadable for non-root users).
COPY --chmod=755 worker-supervisor.cjs /usr/local/lib/railway/worker-supervisor.cjs

# - Add only the shared libraries the Python build needs and the n8n image lacks
#   (libffi, libsqlite3, libuuid, readline ...); existing n8n libraries stay untouched.
# - A separate "runner" user (as in n8nio/runners) runs the launcher and the Code nodes,
#   so they cannot read the worker's environment (database, Redis, encryption key).
# - Fail the build if Python, its extension modules or the launcher cannot load.
RUN set -eu; \
    for f in /tmp/pylibs/*; do \
      [ -e "$f" ] || [ -L "$f" ] || continue; \
      name="$(basename "$f")"; \
      if [ ! -e "/usr/lib/$name" ] && [ ! -e "/lib/$name" ]; then cp -a "$f" /usr/lib/; fi; \
    done; \
    rm -rf /tmp/pylibs; \
    addgroup -S -g 1001 runner; \
    adduser -S -D -u 1001 -G runner -h /home/runner -s /sbin/nologin runner; \
    mkdir -p /home/runner; \
    chown runner:runner /home/runner; \
    chmod 700 /home/runner; \
    /opt/runners/task-runner-python/.venv/bin/python -c "import asyncio, ctypes, hashlib, json, multiprocessing, sqlite3, ssl, uuid, zlib, urllib3, websockets; print('python runner imports ok')"; \
    node --check /opt/runners/task-runner-javascript/dist/start.js; \
    rc=0; out="$(task-runner-launcher 2>&1)" || rc=$?; \
    case "$out" in *"Missing runner-type"*) echo "task-runner-launcher loads (exit $rc as expected)" ;; *) echo "task-runner-launcher failed to start: $out" >&2; exit 1 ;; esac; \
    node /usr/local/lib/railway/worker-supervisor.cjs --self-test

# The supervisor starts as root only to launch the worker as "node" and the launcher as
# "runner"; it runs no user code itself. Railway's podman-init is PID 1; tini forwards
# signals to the supervisor, which drains the worker before stopping the runners.
ENTRYPOINT ["tini", "--", "node", "/usr/local/lib/railway/worker-supervisor.cjs"]

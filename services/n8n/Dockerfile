# n8n Main and n8n Webhook for Railway, built on the official n8n image.
#
# N8N_IMAGE_TAG is a service variable on n8n Main (the other n8n services reference it);
# Railway passes it to this build as a build argument, so changing that one variable
# rebuilds every n8n service on the same version. Use a tag from n8n's `stable` channel.
ARG N8N_IMAGE_TAG=2.45.7
FROM n8nio/n8n:${N8N_IMAGE_TAG}

# Role switch (main | webhook) and the boot-time bcrypt hash of the owner password.
COPY --chmod=755 railway-n8n.sh /usr/local/bin/railway-n8n
# 755, not 644: BuildKit gives the directory it creates the same mode, and 644 locks USER node out.
COPY --chmod=755 hash-owner-password.cjs /usr/local/lib/railway/hash-owner-password.cjs

# Fail the build early if the image no longer ships the bcrypt library n8n logs in with.
RUN node /usr/local/lib/railway/hash-owner-password.cjs --self-test

# The image keeps USER node and tini; Railway's podman-init is PID 1 and tini forwards
# signals to n8n, which shuts down gracefully (N8N_GRACEFUL_SHUTDOWN_TIMEOUT).
ENTRYPOINT ["tini", "--", "/usr/local/bin/railway-n8n"]

# n8n Gateway for Railway: the only public service. Production webhooks, forms, chat and
# MCP triggers go to the n8n Webhook processor; the editor, REST API, push connection and
# test endpoints go to n8n Main (the routing n8n documents for queue mode behind a load
# balancer). It also keeps /metrics private and refuses web-based owner setup.
FROM nginx:1.30.6-alpine

# 15-local-resolvers.envsh exports NGINX_LOCAL_RESOLVERS from /etc/resolv.conf (IPv6-aware).
# The envsubst filter keeps nginx runtime variables ($host, $http_upgrade, ...) untouched.
ENV NGINX_ENTRYPOINT_LOCAL_RESOLVERS=1 \
    NGINX_ENVSUBST_FILTER="^(PORT|N8N_GW_|NGINX_)" \
    PORT=8080 \
    NGINX_CLIENT_MAX_BODY_SIZE=200M \
    NGINX_PROXY_TIMEOUT=3600s

RUN rm -f /etc/nginx/conf.d/default.conf
COPY snippets/ /etc/nginx/snippets/
COPY templates/ /etc/nginx/templates/

EXPOSE 8080

FROM node:24-alpine

WORKDIR /app
COPY server.mjs armory.mjs ./
RUN mkdir -p /data && chown node:node /data
ENV NODE_ENV=production NODE_NO_WARNINGS=1 DATA_DIR=/data PORT=3000
# /data is a bind mount owned by the host user luna (uid 1000) = node user in this image
USER node
EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD wget -q --spider http://127.0.0.1:3000/healthz || exit 1

CMD ["node", "server.mjs"]

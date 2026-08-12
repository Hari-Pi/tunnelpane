FROM node:22-alpine

WORKDIR /app
COPY --chown=node:node server.js /app/server.js
COPY --chown=node:node client.zsh client.ps1 /app/
COPY --chown=node:node assets /app/assets

USER node
EXPOSE 3000
CMD ["node", "/app/server.js"]

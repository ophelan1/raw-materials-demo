FROM node:22-alpine
# Alpine's Chromium; puppeteer-core drives it without downloading its own.
RUN apk add --no-cache chromium
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev
COPY visitors.js .
ENV CHROMIUM_PATH=/usr/bin/chromium-browser
CMD ["node", "visitors.js"]

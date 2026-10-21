FROM node:22-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
# Baked into the bundle at build time. The Front-end API key is public by
# design; the revision ties browser errors to the deployed commit.
ARG VITE_APPSIGNAL_FRONTEND_API_KEY=""
ARG VITE_APP_REVISION="dev"
ENV VITE_APPSIGNAL_FRONTEND_API_KEY=$VITE_APPSIGNAL_FRONTEND_API_KEY VITE_APP_REVISION=$VITE_APP_REVISION
RUN npm run build

FROM nginx:1.27-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist /usr/share/nginx/html

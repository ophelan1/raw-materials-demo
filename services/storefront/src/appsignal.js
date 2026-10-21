// AppSignal for Browser: front-end errors, breadcrumbs and web vitals, plus
// distributed tracing into the Ruby back end. Must be the first import in
// main.jsx so it sees errors from everything that loads after it.
import { init } from "@appsignal/browser";

const key = import.meta.env.VITE_APPSIGNAL_FRONTEND_API_KEY;

init({
  key,
  endpoint: "https://appsignal-endpoint.net",
  active: import.meta.env.PROD && Boolean(key),
  appVersion: import.meta.env.VITE_APP_REVISION,
  // API calls carry a traceparent header, so orders-web and payments-api
  // continue the trace the browser starts. Matched against host + pathname.
  tracePropagationTargets: [`${window.location.host}/api/**`],
  serviceName: "storefront",
});

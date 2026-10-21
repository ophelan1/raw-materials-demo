import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  build: { sourcemap: true },
  server: {
    // Local `npm run dev`: forward API calls to the cluster (localhost:8080).
    proxy: { "/api": "http://localhost:8080" },
  },
});

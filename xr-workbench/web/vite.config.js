import { iwsdkDev } from "@iwsdk/vite-plugin-dev";
import { defineConfig } from "vite";

export default defineConfig({
  plugins: [iwsdkDev()],
  server: {
    host: "0.0.0.0",
    port: 8081,
    open: false,
    proxy: {
      "/api": {
        target: "http://127.0.0.1:8766",
        changeOrigin: true,
        configure(proxy) {
          proxy.on("proxyReq", (proxyRequest, request) => {
            const origin = request.headers.origin;
            try {
              if (origin && new URL(origin).host === request.headers.host) {
                proxyRequest.setHeader("origin", "http://127.0.0.1:8766");
              }
            } catch {
              // The bridge performs the authoritative Host and Origin checks.
            }
          });
        },
      },
    },
  },
  build: {
    outDir: "dist",
    sourcemap: process.env.NODE_ENV !== "production",
    target: "esnext",
    rollupOptions: { input: "./index.html" },
  },
  esbuild: { target: "esnext" },
  optimizeDeps: {
    exclude: ["@babylonjs/havok"],
    esbuildOptions: { target: "esnext" },
  },
  publicDir: "public",
  base: "/",
});

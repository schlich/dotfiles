import { iwsdkDev } from "@iwsdk/vite-plugin-dev";
import { defineConfig } from "vite";

// Loopback HTTP is a secure browser context for desktop previews. Never expose
// this mode on the LAN; Quest Browser continues to use the default HTTPS mode.
const httpPreview = process.env.FIELDWORK_HTTP_PREVIEW === "1";

export default defineConfig({
  plugins: [iwsdkDev({ https: !httpPreview })],
  server: {
    host: httpPreview ? "127.0.0.1" : "0.0.0.0",
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
    rollupOptions: { input: ["./index.html", "./mcp.html"] },
  },
  esbuild: { target: "esnext" },
  optimizeDeps: {
    exclude: ["@babylonjs/havok"],
    esbuildOptions: { target: "esnext" },
  },
  publicDir: "public",
  base: "/",
});

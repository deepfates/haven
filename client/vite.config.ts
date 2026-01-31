import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

export default defineConfig({
  plugins: [react(), tailwindcss()],
  server: {
    port: 8080,
    host: true,
    hmr: true,
    proxy: {
      "/ws": {
        target: "http://localhost:8090",
        ws: true,
        changeOrigin: true,
        configure: (proxy) => {
          proxy.on("error", (err) => {
            console.log("[proxy] error:", err.message);
          });
        },
      },
    },
  },
});

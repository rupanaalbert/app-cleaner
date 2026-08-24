import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import tailwindcss from '@tailwindcss/vite';

export default defineConfig({
  plugins: [react(), tailwindcss()],
  server: {
    // Dev-only: proxies same-origin /v1 calls to a local API so api.js's
    // default `BASE = '/v1'` just works without setting
    // window.__SPARKLE_API_BASE__. Point ADMIN_API_PROXY_TARGET at the real
    // backend (npm run dev in ../backend) or a fixture server.
    proxy: {
      '/v1': {
        target: process.env.ADMIN_API_PROXY_TARGET || 'http://localhost:8080',
        changeOrigin: true,
      },
    },
  },
});

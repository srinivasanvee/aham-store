import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  // Relative base so assets resolve correctly when served from a GCS bucket subfolder.
  // Without this, /assets/... paths 404 because GCS serves from a non-root path.
  base: './',
  server: {
    port: 5173,
    proxy: {
      // Proxy /api calls to the Spring Boot API during local development
      '/api': {
        target: process.env.VITE_API_URL || 'http://localhost:8080',
        changeOrigin: true,
      },
    },
  },
})

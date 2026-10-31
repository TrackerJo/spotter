import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

// https://vite.dev/config/
export default defineConfig({
  plugins: [react()],
  // Custom-domain Pages deployments serve assets from the domain root.
  base: '/',
  build: {
    rollupOptions: {
      input: ['index.html', 'support/index.html', 'privacy/index.html'],
    },
  },
})

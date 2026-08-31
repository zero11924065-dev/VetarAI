import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
export default defineConfig({
  plugins: [react()],
  base: './',  // ← 关键：用相对路径，electron file:// 能加载
});

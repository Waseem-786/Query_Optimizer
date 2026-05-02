import type { Config } from "tailwindcss";

// Tailwind v4 reads design tokens from @theme blocks in globals.css.
// This config is kept minimal for Tailwind plugins / content scanning only.
const config: Config = {
  content: [
    "./pages/**/*.{js,ts,jsx,tsx,mdx}",
    "./components/**/*.{js,ts,jsx,tsx,mdx}",
    "./app/**/*.{js,ts,jsx,tsx,mdx}",
  ],
  theme: { extend: {} },
  plugins: [],
};
export default config;

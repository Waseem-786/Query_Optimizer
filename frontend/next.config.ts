import type { NextConfig } from "next";
import path from "node:path";

// Pin Turbopack's workspace root. Without this, Next.js auto-detects the
// root by walking up looking for a lockfile — when the repo root happens
// to have a stray `package-lock.json` (very easy to create accidentally by
// running `npm install` from the wrong cwd), Turbopack picks THAT as the
// root and then fails to resolve every dependency in `frontend/node_modules`
// ("Can't resolve 'tailwindcss' in <repo-root>") in an infinite loop that
// eventually OOMs Node. Pinning to cwd removes the ambiguity.
//
// `npm run dev` / `next dev` always run from this directory (next reads
// `package.json` from cwd), so `process.cwd()` is the correct root.
// Avoids the `import.meta.url` / `__dirname` ESM-vs-CJS dance that breaks
// next.config.ts compilation in Next 16.
const PROJECT_ROOT = path.resolve(process.cwd());

const nextConfig: NextConfig = {
  serverExternalPackages: ["oracledb"],
  turbopack: {
    root: PROJECT_ROOT,
  },
};

export default nextConfig;

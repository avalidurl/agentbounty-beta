import { defineConfig } from "astro/config";
import react from "@astrojs/react";
import sitemap from "@astrojs/sitemap";

import cloudflare from "@astrojs/cloudflare";

export default defineConfig({
  site: "https://beta.agentbounty.dev",
  trailingSlash: "ignore",

  build: {
    format: "directory",
    inlineStylesheets: "always",
  },

  integrations: [react(), sitemap()],

  markdown: {
    shikiConfig: {
      theme: "github-light",
      wrap: true,
    },
  },

  vite: {
    define: {
      "process.env.NODE_ENV": JSON.stringify(process.env.NODE_ENV ?? "production"),
    },
  },

  adapter: cloudflare()
});
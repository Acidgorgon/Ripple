import { defineConfig } from 'vitepress'
import { family } from './theme/family'
import rippleGrammar from './ripple.tmLanguage.json'

const shared = family('ripple', '/Ripple/')

export default defineConfig({
  ...shared.config,

  lang: 'en-US',
  title: 'Ripple',
  description: 'Schema-first state replication for Roblox: write plain tables, send only what changed.',

  markdown: {
    ...shared.config.markdown,
    languages: [rippleGrammar as any],
  },

  themeConfig: {
    ...shared.themeConfig,

    nav: [
      { text: 'Guide', link: '/guide/getting-started', activeMatch: '^/guide/' },
      { text: 'Reference', link: '/reference/schema', activeMatch: '^/reference/' },
      { text: 'Benchmarks', link: '/benchmarks' },
      shared.nav,
      {
        text: 'v0.1.0',
        items: [{ text: 'Releases', link: 'https://github.com/Acidgorgon/Ripple/releases' }],
      },
    ],

    sidebar: [
      {
        text: 'Guide',
        items: [
          { text: 'Why Ripple', link: '/guide/why' },
          { text: 'Getting started', link: '/guide/getting-started' },
          { text: 'Writing state (server)', link: '/guide/server' },
          { text: 'Reading state (client)', link: '/guide/client' },
          { text: 'Vide', link: '/guide/vide' },
          { text: 'Saving with Anchor / ProfileStore', link: '/guide/saving' },
          { text: 'Riding on Current', link: '/guide/current' },
          { text: 'Security', link: '/guide/security' },
        ],
      },
      {
        text: 'Reference',
        items: [
          { text: 'Schema language', link: '/reference/schema' },
          { text: 'Server API', link: '/reference/server-api' },
          { text: 'Client API', link: '/reference/client-api' },
          { text: 'Wire format', link: '/reference/wire-format' },
        ],
      },
      { text: 'Benchmarks', items: [{ text: 'Results', link: '/benchmarks' }] },
    ],

    socialLinks: [{ icon: 'github', link: 'https://github.com/Acidgorgon/Ripple' }],

    editLink: {
      pattern: 'https://github.com/Acidgorgon/Ripple/edit/main/docs/:path',
      text: 'Edit this page on GitHub',
    },
  },
})

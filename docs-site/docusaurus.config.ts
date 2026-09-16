import {themes as prismThemes} from 'prism-react-renderer';
import type {Config} from '@docusaurus/types';
import type * as Preset from '@docusaurus/preset-classic';

// Blueforce fleet documentation site. Content source: ../docs/*.md.
const config: Config = {
  title: 'Blueforce Docs',
  tagline: 'Fleet runbooks and architecture',
  url: 'http://docs.blueforce.intranet',
  baseUrl: '/',
  onBrokenLinks: 'throw',
  i18n: { defaultLocale: 'tr', locales: ['tr'] },
  markdown: {
    mermaid: true,
    hooks: { onBrokenMarkdownLinks: 'warn' },
  },
  themes: ['@docusaurus/theme-mermaid', '@easyops-cn/docusaurus-search-local'],
  presets: [
    ['classic', {
      docs: { path: 'docs', routeBasePath: '/', sidebarPath: './sidebars.js' },
      blog: false,
      theme: { customCss: './src/css/custom.css' },
    } satisfies Preset.Options],
  ],
  themeConfig: {
    colorMode: { defaultMode: 'dark', disableSwitch: false, respectPrefersColorScheme: false },
    navbar: { title: 'Blueforce Docs', items: [{ type: 'docSidebar', sidebarId: 'docs', position: 'left', label: 'Docs' }] },
  } satisfies Preset.ThemeConfig,
};
export default config;
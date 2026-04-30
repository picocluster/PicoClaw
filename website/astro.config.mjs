// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

// https://astro.build/config
export default defineConfig({
	site: 'https://picocluster-claw.com',

	integrations: [
		starlight({
			title: 'PicoCluster Claw',
			description:
				'Private AI appliance — OpenClaw agents, local LLM inference, ThreadWeaver chat. Runs on your desk, under $2/month.',
			logo: {
				src: './src/assets/ctxone-wordmark.svg',
				replacesTitle: true,
			},
			social: [
				{
					icon: 'github',
					label: 'GitHub',
					href: 'https://github.com/picocluster/picocluster-claw',
				},
			],
			customCss: ['./src/styles/global.css', './src/styles/theme.css'],
			sidebar: [
				{
					label: 'Getting started',
					items: [
						{ label: 'Quickstart', slug: 'getting-started/quickstart' },
						{ label: 'FAQ', slug: 'getting-started/faq' },
						{ label: 'Access guide', slug: 'getting-started/access' },
					],
				},
				{
					label: 'Reference',
					items: [
						{ label: 'MCP tools', slug: 'reference/mcp-tools' },
						{ label: 'Benchmarks', slug: 'reference/benchmarks' },
						{ label: 'Storage options', slug: 'reference/storage' },
					],
				},
				{
					label: 'Operating',
					items: [
						{ label: 'Examples', slug: 'operating/examples' },
						{ label: 'Deployment', slug: 'operating/deployment' },
						{ label: 'Roadmap', slug: 'operating/roadmap' },
					],
				},
			],
			favicon: '/favicon.svg',
			head: [
				{
					tag: 'meta',
					attrs: {
						property: 'og:image',
						content: 'https://picocluster-claw.com/og-image.png',
					},
				},
				{
					tag: 'meta',
					attrs: {
						name: 'twitter:card',
						content: 'summary_large_image',
					},
				},
			],
		}),
	],
});

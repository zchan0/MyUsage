// Build site/dist/llms-full.txt — a single concatenated Markdown file
// containing every docs + blog page, for LLM crawlers that prefer one
// fetch over many. Per the llms.txt convention, this complements
// /llms.txt (the overview) with the full content.
//
// Runs after `astro build` (chained via `npm run build`). Reads the
// raw Markdown from src/content/{docs,blog}/, prepends each with a
// canonical URL header, writes the bundle into dist/.

import { promises as fs } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, '..');
const SITE_BASE = 'https://zchan0.github.io/MyUsage';

async function readMarkdownDir(dir, urlPrefix) {
  let entries = [];
  try {
    entries = await fs.readdir(dir, { withFileTypes: true });
  } catch (e) {
    if (e.code === 'ENOENT') return [];
    throw e;
  }
  const files = [];
  for (const entry of entries) {
    if (entry.isFile() && /\.(md|mdx)$/.test(entry.name)) {
      const slug = entry.name.replace(/\.(md|mdx)$/, '');
      const filePath = path.join(dir, entry.name);
      const raw = await fs.readFile(filePath, 'utf8');
      const stripped = stripFrontmatter(raw);
      files.push({ slug, url: `${urlPrefix}/${slug}`, body: stripped });
    }
  }
  return files.sort((a, b) => a.slug.localeCompare(b.slug));
}

function stripFrontmatter(md) {
  // Remove a leading YAML frontmatter block (--- ... ---) if present.
  if (md.startsWith('---')) {
    const close = md.indexOf('\n---', 3);
    if (close !== -1) return md.slice(close + 4).replace(/^\n+/, '');
  }
  return md;
}

const docs = await readMarkdownDir(
  path.join(ROOT, 'src/content/docs'),
  `${SITE_BASE}/docs`
);
const blog = await readMarkdownDir(
  path.join(ROOT, 'src/content/blog'),
  `${SITE_BASE}/blog`
);

let out = '';
out += '# MyUsage — Full content bundle\n\n';
out += `> Concatenated docs + blog content for LLM crawlers. Generated at build time. For the navigable site, see ${SITE_BASE}/.\n\n`;
out += '---\n\n';

if (docs.length) {
  out += '## Documentation\n\n';
  for (const f of docs) {
    out += `### ${f.url}\n\n${f.body}\n\n---\n\n`;
  }
}

if (blog.length) {
  out += '## Blog\n\n';
  for (const f of blog) {
    out += `### ${f.url}\n\n${f.body}\n\n---\n\n`;
  }
}

const distPath = path.join(ROOT, 'dist/llms-full.txt');
await fs.mkdir(path.dirname(distPath), { recursive: true });
await fs.writeFile(distPath, out, 'utf8');

const sizeKb = (Buffer.byteLength(out, 'utf8') / 1024).toFixed(1);
console.log(`✓ Wrote dist/llms-full.txt (${docs.length} docs + ${blog.length} blog posts, ${sizeKb} KB)`);

// Per-page Markdown alternate sources. Each docs/blog page in the site
// carries a `<link rel="alternate" type="text/markdown" href="/<route>.md">`
// that points here, so retrieval crawlers (Claude Code, Cursor, etc.) and
// LLM citation pipelines can grab a clean MD copy via content negotiation.
async function writePerPageMarkdown(files, distSubdir) {
  for (const f of files) {
    const target = path.join(ROOT, 'dist', distSubdir, `${f.slug}.md`);
    await fs.mkdir(path.dirname(target), { recursive: true });
    await fs.writeFile(target, f.body, 'utf8');
  }
}
await writePerPageMarkdown(docs, 'docs');
await writePerPageMarkdown(blog, 'blog');
console.log(`✓ Wrote ${docs.length + blog.length} per-page .md alternates`);

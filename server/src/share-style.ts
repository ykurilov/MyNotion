// Стили опубликованной страницы: похоже на редактор MyNotion, тема — по системе, узкий экран — без потерь.

export const SHARE_STYLESHEET = `
:root {
  color-scheme: light dark;
  --text: #37352f;
  --muted: #787774;
  --faint: #e9e9e7;
  --hover: rgba(55, 53, 47, 0.06);
  --page: #ffffff;
  --code-bg: #f7f6f3;
  --link: #37352f;
  --accent: #2383e2;
  --c-gray: #787774; --c-brown: #9f6b53; --c-orange: #d9730d; --c-yellow: #cb912f; --c-green: #448361;
  --c-blue: #337ea9; --c-purple: #9065b0; --c-pink: #c14c8a; --c-red: #d44c47;
  --bg-gray: #f1f1ef; --bg-brown: #f4eeee; --bg-orange: #fbecdd; --bg-yellow: #fbf3db; --bg-green: #edf3ec;
  --bg-blue: #e7f3f8; --bg-purple: #f6f3f9; --bg-pink: #faf1f5; --bg-red: #fdebec;
}
@media (prefers-color-scheme: dark) {
  :root {
    --text: rgba(255, 255, 255, 0.86);
    --muted: rgba(255, 255, 255, 0.46);
    --faint: rgba(255, 255, 255, 0.11);
    --hover: rgba(255, 255, 255, 0.06);
    --page: #191919;
    --code-bg: #202020;
    --link: rgba(255, 255, 255, 0.86);
    --c-gray: #9b9b9b; --c-brown: #ba856f; --c-orange: #c77d48; --c-yellow: #ca9849; --c-green: #529e72;
    --c-blue: #5e87c9; --c-purple: #9d68d3; --c-pink: #d15796; --c-red: #df5452;
    --bg-gray: #252525; --bg-brown: #2e2724; --bg-orange: #36291f; --bg-yellow: #372e20; --bg-green: #242b26;
    --bg-blue: #1f282d; --bg-purple: #2a2430; --bg-pink: #2e2328; --bg-red: #332523;
  }
}
* { box-sizing: border-box; }
html { -webkit-text-size-adjust: 100%; }
body {
  margin: 0;
  background: var(--page);
  color: var(--text);
  font: 16px/1.5 ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
  overflow-wrap: break-word;
}
body.small-text { font-size: 14px; }
a { color: var(--link); text-decoration: underline; text-decoration-color: var(--muted); text-underline-offset: 2px; }
a:hover { text-decoration-color: var(--text); }

.cover { height: 30vh; max-height: 280px; min-height: 120px; overflow: hidden; position: relative; }
.cover img { width: 100%; height: 100%; object-fit: cover; display: block; }
.cover-grid { position: absolute; inset: -40px; display: grid; filter: blur(28px); }
.cover-grid i { display: block; }

.page { max-width: 708px; margin: 0 auto; padding: 72px 24px 120px; }
.full-width .page { max-width: none; padding-left: 96px; padding-right: 96px; }
.page.has-cover { padding-top: 24px; }
.page.has-cover.has-icon .page-icon-large { margin-top: -62px; position: relative; }
.page-icon-large { font-size: 78px; line-height: 1.1; margin-bottom: 8px; }
.page-title { font-size: 40px; line-height: 1.2; font-weight: 700; margin: 0 0 16px; }
.breadcrumbs { font-size: 14px; color: var(--muted); margin-bottom: 24px; display: flex; flex-wrap: wrap; gap: 4px; }
.breadcrumbs a { color: var(--muted); text-decoration: none; }
.breadcrumbs a:hover { color: var(--text); }
.crumb-gap { opacity: 0.5; }

.page-body > *, .column > *, .callout-body > *, details > *:not(summary) { margin-top: 2px; margin-bottom: 2px; }
.block { margin: 2px 0; }
p.block { min-height: 1.5em; padding: 3px 2px; }
h1.heading1, h2.heading2, h3.heading3 { font-weight: 600; margin: 0; }
h1.heading1 { font-size: 1.875em; line-height: 1.3; }
h2.heading2 { font-size: 1.5em; line-height: 1.3; }
h3.heading3 { font-size: 1.25em; line-height: 1.3; }
h1.block { margin-top: 1.4em; padding: 3px 2px; }
h2.block { margin-top: 1.1em; padding: 3px 2px; }
h3.block { margin-top: 1em; padding: 3px 2px; }

ul, ol { margin: 2px 0; padding-left: 1.6em; }
li { padding: 3px 0; }
li > ul, li > ol, li > .block { margin-top: 2px; }
ul.bulleted ul.bulleted { list-style-type: circle; }
ul.bulleted ul.bulleted ul.bulleted { list-style-type: square; }
ol.numbered ol.numbered { list-style-type: lower-alpha; }
ol.numbered ol.numbered ol.numbered { list-style-type: lower-roman; }
ul.todos { list-style: none; padding-left: 0; }
ul.todos ul.todos { padding-left: 1.6em; }
li.todo { position: relative; padding-left: 1.6em; }
li.todo .box {
  position: absolute; left: 0; top: 0.42em; width: 16px; height: 16px;
  border: 1.5px solid var(--text); border-radius: 3px;
}
li.todo.checked > .box { background: var(--accent); border-color: var(--accent); }
li.todo.checked > .box::after {
  content: ""; position: absolute; left: 4px; top: 0; width: 4px; height: 9px;
  border: solid #fff; border-width: 0 2px 2px 0; transform: rotate(45deg);
}
li.todo.checked > .todo-text { color: var(--muted); text-decoration: line-through; }

details > summary { cursor: pointer; list-style: none; padding: 3px 2px 3px 1.4em; position: relative; }
details > summary::-webkit-details-marker { display: none; }
details > summary::before {
  content: ""; position: absolute; left: 0.35em; top: 0.75em;
  border-style: solid; border-width: 0.32em 0 0.32em 0.5em; border-color: transparent transparent transparent currentColor;
  transition: transform 0.15s;
}
details[open] > summary::before { transform: rotate(90deg); }
details > *:not(summary) { margin-left: 1.4em; }
details.heading-fold > summary::before { top: 50%; margin-top: -0.32em; }
details.heading-fold > summary > h1, details.heading-fold > summary > h2, details.heading-fold > summary > h3 { display: inline; }
details.heading-fold { margin-top: 1em; }
details.heading-fold > *:not(summary) { margin-left: 0; }

blockquote.quote { border-left: 3px solid currentColor; padding: 3px 14px; margin: 6px 0; font-size: 1.1em; }
.callout { display: flex; gap: 10px; padding: 14px 16px 14px 12px; border-radius: 4px; border: 1px solid var(--faint); margin: 4px 0; }
.callout[class*="bg-"] { border-color: transparent; }
.callout-icon { font-size: 1.3em; line-height: 1.2; flex: none; }
.callout-body { min-width: 0; flex: 1; }
hr.divider { border: none; border-top: 1px solid var(--faint); margin: 12px 0; }
pre.code {
  background: var(--code-bg); border-radius: 4px; padding: 28px 24px 24px; overflow-x: auto; position: relative;
  font: 14px/1.5 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; tab-size: 4; white-space: pre;
}
pre.code::before { content: attr(data-language); position: absolute; top: 6px; left: 12px; font: 12px/1 ui-sans-serif, -apple-system, sans-serif; color: var(--muted); }
code { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: 0.85em; }
p code, li code, td code, summary code, blockquote code, h1 code, h2 code, h3 code {
  background: var(--code-bg); color: var(--c-red); padding: 0.2em 0.4em; border-radius: 4px;
}
.equation { text-align: center; padding: 8px; overflow-x: auto; }
code.equation { color: var(--text) !important; }

.mention { text-decoration: none; font-weight: 500; }
.mention-icon { margin-right: 0.2em; }
.mention.locked, .locked { color: var(--muted); }
.date { color: var(--muted); }

figure.image { margin: 8px 0; max-width: 100%; }
figure.image img { max-width: 100%; height: auto; display: block; border-radius: 3px; }
figure.image figcaption { font-size: 14px; color: var(--muted); padding-top: 6px; }
.missing-file { color: var(--muted); font-size: 14px; padding: 12px; border: 1px dashed var(--faint); border-radius: 4px; }
a.file { display: flex; align-items: center; gap: 8px; padding: 6px 8px; border-radius: 4px; text-decoration: none; }
a.file:hover, a.page-link:hover, a.bookmark:hover { background: var(--hover); }
.file-size { color: var(--muted); font-size: 13px; }
video.video { width: 100%; border-radius: 4px; background: #000; }
a.video-link { display: block; position: relative; border-radius: 4px; overflow: hidden; background: var(--code-bg); text-decoration: none; min-height: 56px; }
a.video-link img { display: block; width: 100%; height: auto; }
.video-play { position: absolute; left: 12px; bottom: 12px; background: rgba(0, 0, 0, 0.7); color: #fff; padding: 6px 12px; border-radius: 4px; font-size: 14px; }
a.video-link:not(:has(img)) .video-play { position: static; display: inline-block; margin: 12px; }
a.bookmark { display: flex; border: 1px solid var(--faint); border-radius: 4px; overflow: hidden; text-decoration: none; margin: 4px 0; }
.bookmark-text { flex: 1; min-width: 0; padding: 12px 14px; display: flex; flex-direction: column; gap: 4px; }
.bookmark-title { font-size: 14px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.bookmark-description { font-size: 12px; color: var(--muted); display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
.bookmark-url { font-size: 12px; display: flex; align-items: center; gap: 6px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.bookmark-favicon { width: 16px; height: 16px; }
.bookmark-image { flex: 0 0 33%; max-width: 220px; }
.bookmark-image img { width: 100%; height: 100%; object-fit: cover; display: block; }
a.page-link, div.page-link { display: flex; align-items: center; gap: 6px; padding: 3px 2px; border-radius: 4px; text-decoration: none; }
a.page-link .page-title-text { text-decoration: underline; text-decoration-color: var(--faint); text-underline-offset: 3px; font-weight: 500; }

.columns { display: flex; gap: 32px; margin: 4px 0; }
.column { min-width: 0; }
.table-wrap { overflow-x: auto; margin: 6px 0; -webkit-overflow-scrolling: touch; }
table { border-collapse: collapse; font-size: 14px; }
table.table td, table.table th, table.database td, table.database th {
  border: 1px solid var(--faint); padding: 7px 9px; text-align: left; vertical-align: top; min-width: 80px;
}
table.table th, table.database th { background: var(--code-bg); font-weight: 600; }
table.database th { color: var(--muted); font-weight: 500; }
table.database td a { font-weight: 500; }
.database-block { margin: 12px 0; }
.database-title { font-size: 1.25em; margin: 0 0 6px; }
nav.toc { display: flex; flex-direction: column; padding: 4px 0; }
nav.toc a { color: var(--muted); padding: 3px 2px; text-decoration: none; }
nav.toc a:hover { color: var(--text); background: var(--hover); }
nav.toc .toc-2 { padding-left: 24px; }
nav.toc .toc-3 { padding-left: 48px; }

.not-found { text-align: center; padding-top: 20vh; color: var(--muted); }
.not-found .page-title { color: var(--text); }

.c-gray { color: var(--c-gray); } .c-brown { color: var(--c-brown); } .c-orange { color: var(--c-orange); }
.c-yellow { color: var(--c-yellow); } .c-green { color: var(--c-green); } .c-blue { color: var(--c-blue); }
.c-purple { color: var(--c-purple); } .c-pink { color: var(--c-pink); } .c-red { color: var(--c-red); }
.bg-gray { background: var(--bg-gray); } .bg-brown { background: var(--bg-brown); } .bg-orange { background: var(--bg-orange); }
.bg-yellow { background: var(--bg-yellow); } .bg-green { background: var(--bg-green); } .bg-blue { background: var(--bg-blue); }
.bg-purple { background: var(--bg-purple); } .bg-pink { background: var(--bg-pink); } .bg-red { background: var(--bg-red); }

@media (max-width: 720px) {
  .page, .full-width .page { padding: 40px 16px 80px; }
  .page.has-cover { padding-top: 16px; }
  .page-icon-large { font-size: 56px; }
  .page.has-cover.has-icon .page-icon-large { margin-top: -44px; }
  .page-title { font-size: 30px; }
  .cover { height: 22vh; }
  .columns { flex-direction: column; gap: 4px; }
  .column { flex: none !important; }
  pre.code { padding: 28px 14px 16px; font-size: 13px; }
  .bookmark-image { display: none; }
  .callout { padding: 12px; }
}
`;

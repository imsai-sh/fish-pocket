---
name: browser-cli
description: Use the workbench browser for interactive sites, forms, tabs, screenshots, downloads and PDFs.
---

Run `browser` through `bash`. Use `browser --help` for the installed actions and `browser help ACTION` for their arguments. Use `web_fetch` for public page text.

`browser open URL` and `browser read` return numbered controls. Use the latest numbers with `browser click 4`, `browser type 7 'some text'` or `browser select 2 'an option'`. Use `browser evaluate 'return document.title'` to inspect the page. A subagent uses its parent conversation's browser. A Bot keeps its tabs across chat parts. Check `browser tabs` before opening another page; `browser select_tab t2` brings a tab to the front. Let the user handle sign-ins and payment details.

`browser screenshot` returns an image to an image-capable model. Use `browser screenshot --out page.jpg` for a workspace file. Use `browser pdf --path page.pdf` to save a PDF and `browser upload 3 '["report.pdf"]'` to attach workspace files to a numbered field. Arrays and objects are quoted JSON arguments. File results include their saved path.

import MarkdownIt from 'markdown-it'

export const md = new MarkdownIt({
  html: false, // mockup READMEs author plain markdown only
  linkify: true,
  breaks: true,
})

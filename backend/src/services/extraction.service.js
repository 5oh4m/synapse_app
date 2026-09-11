// Real server-side extraction.
//
// Defect fixed: the previous code advertised a POST /extract endpoint that did
// not exist, "counted pages" by counting `endobj` occurrences (a one-page PDF
// contains 40+ objects, so it reported 40+ pages), and tried to regex `<a:t>`
// out of raw .pptx bytes — which are DEFLATE-compressed, so the pattern can
// never match. Nothing here pretends: PDFs go through pdf-parse (pdf.js under
// the hood, so numpages comes from the page tree), PPTX is actually unzipped
// and its slide XML parsed, and images return needs_text because no OCR is
// bundled.
import JSZip from 'jszip';
import { XMLParser } from 'fast-xml-parser';
import { validation } from '../errors.js';
import { log } from '../log.js';

export const SOURCE_TYPES = ['pdf', 'pptx', 'image', 'text'];

const EXT_TO_TYPE = {
  pdf: 'pdf',
  pptx: 'pptx',
  ppt: 'pptx',
  png: 'image',
  jpg: 'image',
  jpeg: 'image',
  gif: 'image',
  webp: 'image',
  heic: 'image',
  bmp: 'image',
  txt: 'text',
  md: 'text',
  markdown: 'text',
  csv: 'text',
};

const MIME_TO_TYPE = {
  'application/pdf': 'pdf',
  'application/vnd.openxmlformats-officedocument.presentationml.presentation': 'pptx',
  'application/vnd.ms-powerpoint': 'pptx',
  'text/plain': 'text',
  'text/markdown': 'text',
  'text/csv': 'text',
};

/** Best guess at a source type from the upload metadata. */
export function detectSourceType({ fileName, mimeType }) {
  if (mimeType) {
    if (MIME_TO_TYPE[mimeType]) return MIME_TO_TYPE[mimeType];
    if (mimeType.startsWith('image/')) return 'image';
    if (mimeType.startsWith('text/')) return 'text';
  }
  const ext = String(fileName || '').split('.').pop()?.toLowerCase();
  return EXT_TO_TYPE[ext] || null;
}

/** Enough text to be worth sending to a generator. */
const MIN_USEFUL_CHARS = 120;

const squash = (s) =>
  String(s || '')
    .replace(/\r\n?/g, '\n')
    .replace(/[ \t ]+/g, ' ')
    .replace(/\n{3,}/g, '\n\n')
    .trim();

/**
 * @returns {{status:'ready'|'needs_text'|'failed', text:string, pageCount:number,
 *            sourceType:string, message:string|null, error:string|null}}
 */
export async function extract({ buffer, fileName, mimeType, sourceType }) {
  const type = sourceType || detectSourceType({ fileName, mimeType });
  if (!type) {
    return fail('text', `Unsupported file type${fileName ? ` for "${fileName}"` : ''}. Upload a PDF, a PPTX, or paste the text.`);
  }
  if (!SOURCE_TYPES.includes(type)) {
    throw validation(`source_type must be one of: ${SOURCE_TYPES.join(', ')}.`, 'source_type');
  }

  try {
    switch (type) {
      case 'pdf':
        return await extractPdf(buffer);
      case 'pptx':
        return await extractPptx(buffer);
      case 'image':
        // Honest refusal. No OCR is bundled, so nothing is claimed.
        return {
          status: 'needs_text',
          text: '',
          pageCount: 1,
          sourceType: 'image',
          message:
            'This build does not include OCR, so text cannot be read out of an image. Paste the text from the slide or photo and it will be used as-is.',
          error: null,
        };
      case 'text':
      default:
        return finishText(squash(buffer?.toString('utf8') ?? ''), 'text', 1);
    }
  } catch (err) {
    log.warn('extraction failed', { source_type: type, file_name: fileName, message: err.message });
    return fail(type, `Could not read that ${type.toUpperCase()} file: ${err.message}`);
  }
}

function fail(sourceType, error) {
  return { status: 'failed', text: '', pageCount: 0, sourceType, message: null, error };
}

function finishText(text, sourceType, pageCount) {
  if (text.length < MIN_USEFUL_CHARS) {
    return {
      status: 'needs_text',
      text,
      pageCount,
      sourceType,
      message:
        `Only ${text.length} characters of text came out of this file, which is not enough to write questions from. ` +
        'It is probably a scan or an image-only export. Paste the text instead.',
      error: null,
    };
  }
  return { status: 'ready', text, pageCount, sourceType, message: null, error: null };
}

// ------------------------------------------------------------------- PDF -----

async function extractPdf(buffer) {
  if (!buffer || buffer.length === 0) throw new Error('the file was empty');
  // pdf-parse v2 wraps pdf.js. `total`/`numpages` is the real page-tree count.
  const { PDFParse } = await import('pdf-parse');
  const parser = new PDFParse({ data: new Uint8Array(buffer) });
  try {
    const result = await parser.getText();
    const pageCount =
      Number(result?.total) ||
      Number(result?.numpages) ||
      (Array.isArray(result?.pages) ? result.pages.length : 0) ||
      0;
    const text = squash(
      result?.text ||
        (Array.isArray(result?.pages) ? result.pages.map((p) => p.text || '').join('\n\n') : ''),
    );
    return finishText(text, 'pdf', pageCount);
  } finally {
    await parser.destroy?.();
  }
}

// ------------------------------------------------------------------ PPTX -----

const xml = new XMLParser({
  ignoreAttributes: false,
  attributeNamePrefix: '@_',
  textNodeName: '#text',
  // Keep whitespace-only runs: a:t nodes separate words.
  trimValues: false,
  parseTagValue: false,
  isArray: (name) => ['p:sp', 'a:p', 'a:r', 'a:t'].includes(name),
});

/** Depth-first collect of every <a:t> text run under a parsed slide tree. */
function collectRuns(node, out) {
  if (node === null || node === undefined) return;
  if (typeof node === 'string') return;
  if (Array.isArray(node)) {
    for (const n of node) collectRuns(n, out);
    return;
  }
  if (typeof node !== 'object') return;
  for (const [key, value] of Object.entries(node)) {
    if (key === 'a:t') {
      const runs = Array.isArray(value) ? value : [value];
      for (const r of runs) {
        const t = typeof r === 'object' && r !== null ? r['#text'] : r;
        if (typeof t === 'string' && t.length) out.push(t);
      }
      continue;
    }
    if (key.startsWith('@_') || key === '#text') continue;
    collectRuns(value, out);
  }
}

/** Numeric suffix of slideN.xml / notesSlideN.xml, for stable ordering. */
const slideNumber = (path) => {
  const m = /(\d+)\.xml$/.exec(path);
  return m ? Number(m[1]) : Number.MAX_SAFE_INTEGER;
};

async function extractPptx(buffer) {
  if (!buffer || buffer.length === 0) throw new Error('the file was empty');
  let zip;
  try {
    zip = await JSZip.loadAsync(buffer);
  } catch {
    throw new Error('it is not a valid .pptx (a .pptx is a zip archive; a legacy .ppt will not work)');
  }

  const slidePaths = Object.keys(zip.files)
    .filter((p) => /^ppt\/slides\/slide\d+\.xml$/.test(p))
    .sort((a, b) => slideNumber(a) - slideNumber(b));

  if (slidePaths.length === 0) {
    throw new Error('no slides were found in ppt/slides/ — is this really a PowerPoint file?');
  }

  const notePaths = new Map(
    Object.keys(zip.files)
      .filter((p) => /^ppt\/notesSlides\/notesSlide\d+\.xml$/.test(p))
      .map((p) => [slideNumber(p), p]),
  );

  const blocks = [];
  for (const path of slidePaths) {
    const n = slideNumber(path);
    const runs = [];
    collectRuns(xml.parse(await zip.file(path).async('string')), runs);
    const body = squash(runs.join(' ').replace(/ {2,}/g, ' '));

    const notesPath = notePaths.get(n);
    let notes = '';
    if (notesPath) {
      const noteRuns = [];
      collectRuns(xml.parse(await zip.file(notesPath).async('string')), noteRuns);
      // PowerPoint stamps the slide number into the notes placeholder; drop a
      // run that is just that number.
      notes = squash(
        noteRuns
          .filter((r) => r.trim() !== String(n))
          .join(' ')
          .replace(/ {2,}/g, ' '),
      );
    }

    const parts = [`[Slide ${n}]`];
    if (body) parts.push(body);
    if (notes) parts.push(`Speaker notes: ${notes}`);
    if (body || notes) blocks.push(parts.join('\n'));
  }

  return finishText(squash(blocks.join('\n\n')), 'pptx', slidePaths.length);
}

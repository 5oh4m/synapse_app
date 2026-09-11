// Builds the extraction fixtures at test time, so no binaries are committed.
//
//  - two-page.pdf : a hand-written, valid 2-page PDF. It deliberately contains
//    far more `endobj` markers than pages, which is what made the old
//    "count endobj" page counter report 40+ pages for a 1-page file.
//  - deck.pptx    : a real OOXML package (a zip), so the slide text only comes
//    out if the server actually unzips it and parses ppt/slides/slideN.xml.
//    A regex over the raw bytes cannot find it, because the XML is deflated.
import fs from 'node:fs/promises';
import path from 'node:path';
import JSZip from 'jszip';

export const FIXTURES_DIR = path.dirname(new URL(import.meta.url).pathname);

const PAGE_TEXT = [
  'Photosynthesis converts light energy into chemical energy stored in glucose.',
  'The light dependent reactions happen in the thylakoid membranes of a chloroplast.',
  'Water is split by photolysis, which releases oxygen as a by product.',
];
const PAGE_TWO_TEXT = [
  'The Calvin cycle takes place in the stroma and fixes carbon dioxide.',
  'RuBisCO attaches carbon dioxide to ribulose bisphosphate.',
  'Light intensity, carbon dioxide and temperature all limit the rate.',
];

/** Escapes a string for a PDF literal. */
const pdfString = (s) => s.replace(/([\\()])/g, '\\$1');

function contentStream(lines) {
  const body = [
    'BT',
    '/F1 14 Tf',
    '72 720 Td',
    '18 TL',
    ...lines.map((l) => `(${pdfString(l)}) Tj T*`),
    'ET',
  ].join('\n');
  return body;
}

/**
 * Assembles a minimal but structurally valid PDF 1.4 with a correct xref
 * table. Objects: catalog, pages, 2 x page, 2 x content, font, plus padding
 * objects so `endobj` outnumbers pages by a wide margin.
 */
export function buildTwoPagePdf() {
  const objects = [];
  const push = (body) => {
    objects.push(body);
    return objects.length; // 1-based object number
  };

  // Reserve numbers in a fixed order so references are known up front.
  const catalogNum = 1;
  const pagesNum = 2;
  const page1Num = 3;
  const page2Num = 4;
  const content1Num = 5;
  const content2Num = 6;
  const fontNum = 7;

  push(`<< /Type /Catalog /Pages ${pagesNum} 0 R >>`);
  push(`<< /Type /Pages /Kids [${page1Num} 0 R ${page2Num} 0 R] /Count 2 >>`);
  push(
    `<< /Type /Page /Parent ${pagesNum} 0 R /MediaBox [0 0 612 792] ` +
      `/Resources << /Font << /F1 ${fontNum} 0 R >> >> /Contents ${content1Num} 0 R >>`,
  );
  push(
    `<< /Type /Page /Parent ${pagesNum} 0 R /MediaBox [0 0 612 792] ` +
      `/Resources << /Font << /F1 ${fontNum} 0 R >> >> /Contents ${content2Num} 0 R >>`,
  );

  const s1 = contentStream(PAGE_TEXT);
  push(`<< /Length ${Buffer.byteLength(s1)} >>\nstream\n${s1}\nendstream`);
  const s2 = contentStream(PAGE_TWO_TEXT);
  push(`<< /Length ${Buffer.byteLength(s2)} >>\nstream\n${s2}\nendstream`);
  push('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>');

  // 40 inert objects. A page counter that counts `endobj` now reports 47.
  for (let i = 0; i < 40; i += 1) {
    push(`<< /Type /Metadata /Subtype /XML /Note (padding object ${i}) >>`);
  }

  let pdf = '%PDF-1.4\n%âãÏÓ\n';
  const offsets = [];
  for (let i = 0; i < objects.length; i += 1) {
    offsets.push(Buffer.byteLength(pdf, 'latin1'));
    pdf += `${i + 1} 0 obj\n${objects[i]}\nendobj\n`;
  }

  const xrefOffset = Buffer.byteLength(pdf, 'latin1');
  pdf += `xref\n0 ${objects.length + 1}\n`;
  pdf += '0000000000 65535 f \n';
  for (const off of offsets) {
    pdf += `${String(off).padStart(10, '0')} 00000 n \n`;
  }
  pdf += `trailer\n<< /Size ${objects.length + 1} /Root ${catalogNum} 0 R >>\n`;
  pdf += `startxref\n${xrefOffset}\n%%EOF\n`;

  return Buffer.from(pdf, 'latin1');
}

const SLIDES = [
  {
    title: 'Photosynthesis overview',
    bullets: [
      'Light energy becomes chemical energy in glucose',
      'Happens in the chloroplast, driven by chlorophyll',
    ],
    notes: 'Remind the class that chlorophyll reflects green light.',
  },
  {
    title: 'The Calvin cycle',
    bullets: [
      'Takes place in the stroma',
      'RuBisCO fixes carbon dioxide onto ribulose bisphosphate',
    ],
    notes: 'RuBisCO is the most abundant enzyme on Earth.',
  },
  {
    title: 'Limiting factors',
    bullets: ['Light intensity', 'Carbon dioxide concentration', 'Temperature'],
    notes: '',
  },
];

const xmlEscape = (s) =>
  String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

function slideXml({ title, bullets }) {
  const para = (text, idx) =>
    `<p:sp><p:nvSpPr><p:cNvPr id="${idx + 2}" name="Text ${idx}"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>` +
    `<p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/>` +
    `<a:p><a:r><a:rPr lang="en-GB" dirty="0"/><a:t>${xmlEscape(text)}</a:t></a:r></a:p>` +
    `</p:txBody></p:sp>`;
  return (
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
    '<p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" ' +
    'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" ' +
    'xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">' +
    '<p:cSld><p:spTree>' +
    '<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>' +
    para(title, 0) +
    bullets.map((b, i) => para(b, i + 1)).join('') +
    '</p:spTree></p:cSld><p:clrMapOvr><a:overrideClrMapping/></p:clrMapOvr></p:sld>'
  );
}

function notesXml(text, slideNumber) {
  return (
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
    '<p:notes xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" ' +
    'xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">' +
    '<p:cSld><p:spTree>' +
    '<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>' +
    // The slide-number placeholder PowerPoint always writes.
    `<p:sp><p:nvSpPr><p:cNvPr id="2" name="Slide Number Placeholder"/><p:cNvSpPr/>` +
    `<p:nvPr><p:ph type="sldNum" sz="quarter"/></p:nvPr></p:nvSpPr><p:spPr/>` +
    `<p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:rPr lang="en-GB"/>` +
    `<a:t>${slideNumber}</a:t></a:r></a:p></p:txBody></p:sp>` +
    `<p:sp><p:nvSpPr><p:cNvPr id="3" name="Notes Placeholder"/><p:cNvSpPr/>` +
    `<p:nvPr><p:ph type="body" idx="1"/></p:nvPr></p:nvSpPr><p:spPr/>` +
    `<p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:rPr lang="en-GB"/>` +
    `<a:t>${xmlEscape(text)}</a:t></a:r></a:p></p:txBody></p:sp>` +
    '</p:spTree></p:cSld></p:notes>'
  );
}

export async function buildDeckPptx() {
  const zip = new JSZip();

  zip.file(
    '[Content_Types].xml',
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
      '<Default Extension="xml" ContentType="application/xml"/>' +
      '<Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>' +
      SLIDES.map(
        (_, i) =>
          `<Override PartName="/ppt/slides/slide${i + 1}.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>`,
      ).join('') +
      '</Types>',
  );

  zip.file(
    '_rels/.rels',
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/>' +
      '</Relationships>',
  );

  zip.file(
    'ppt/presentation.xml',
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
      '<p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" ' +
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><p:sldIdLst>' +
      SLIDES.map((_, i) => `<p:sldId id="${256 + i}" r:id="rId${i + 1}"/>`).join('') +
      '</p:sldIdLst></p:presentation>',
  );

  SLIDES.forEach((slide, i) => {
    zip.file(`ppt/slides/slide${i + 1}.xml`, slideXml(slide));
    if (slide.notes) {
      zip.file(`ppt/notesSlides/notesSlide${i + 1}.xml`, notesXml(slide.notes, i + 1));
    }
  });

  // DEFLATE, exactly like PowerPoint, so a byte-level regex cannot see <a:t>.
  return zip.generateAsync({ type: 'nodebuffer', compression: 'DEFLATE' });
}

export async function ensureFixtures() {
  const pdfPath = path.join(FIXTURES_DIR, 'two-page.pdf');
  const pptxPath = path.join(FIXTURES_DIR, 'deck.pptx');
  await fs.writeFile(pdfPath, buildTwoPagePdf());
  await fs.writeFile(pptxPath, await buildDeckPptx());
  return { pdfPath, pptxPath };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const out = await ensureFixtures();
  console.log(out);
}

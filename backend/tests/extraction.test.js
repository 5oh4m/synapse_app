import test, { before, beforeEach, after, describe } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { resetDb, shutdown, makeUser } from './helpers.js';
import { extract, detectSourceType } from '../src/services/extraction.service.js';
import { ensureFixtures, FIXTURES_DIR } from './fixtures/make-fixtures.js';

before(async () => {
  await ensureFixtures();
  await resetDb();
});
beforeEach(resetDb);
after(shutdown);

const pdfPath = () => path.join(FIXTURES_DIR, 'two-page.pdf');
const pptxPath = () => path.join(FIXTURES_DIR, 'deck.pptx');

describe('PDF extraction is real', () => {
  test('page count comes from the page tree, not from counting endobj', async () => {
    const buffer = await fs.readFile(pdfPath());
    const endobjCount = (buffer.toString('latin1').match(/endobj/g) || []).length;

    const result = await extract({ buffer, fileName: 'two-page.pdf' });

    assert.equal(result.status, 'ready');
    assert.equal(result.pageCount, 2, `expected 2 pages, got ${result.pageCount}`);
    assert.ok(
      endobjCount > 40,
      `the fixture should contain many objects to make the point (had ${endobjCount})`,
    );
    assert.notEqual(
      result.pageCount,
      endobjCount,
      'the page count still tracks the endobj count, which is the old bug',
    );
  });

  test('the text of both pages is actually extracted', async () => {
    const result = await extract({ buffer: await fs.readFile(pdfPath()), fileName: 'x.pdf' });
    assert.match(result.text, /Photosynthesis converts light energy/);
    assert.match(result.text, /thylakoid membranes/);
    assert.match(result.text, /Calvin cycle/, 'page 2 text is missing');
    assert.match(result.text, /RuBisCO/);
    assert.ok(result.text.length > 300);
  });

  test('a corrupt PDF fails honestly instead of reporting success', async () => {
    const result = await extract({
      buffer: Buffer.from('%PDF-1.4\nthis is not really a pdf'),
      fileName: 'broken.pdf',
    });
    assert.equal(result.status, 'failed');
    assert.ok(result.error);
    assert.equal(result.text, '');
  });
});

describe('PPTX extraction is real', () => {
  test('slide text and speaker notes come out of the zipped XML', async () => {
    const buffer = await fs.readFile(pptxPath());

    // The whole point: the XML is deflated, so a regex over the raw bytes —
    // which is what the previous implementation did — cannot possibly match.
    assert.ok(
      !/<a:t>/.test(buffer.toString('latin1')),
      'the fixture is not compressed, so it would not prove anything',
    );

    const result = await extract({ buffer, fileName: 'deck.pptx' });
    assert.equal(result.status, 'ready');
    assert.equal(result.pageCount, 3, 'slide count should be the number of slideN.xml parts');
    assert.match(result.text, /Photosynthesis overview/);
    assert.match(result.text, /RuBisCO fixes carbon dioxide/);
    assert.match(result.text, /Limiting factors/);
    assert.match(result.text, /Speaker notes: Remind the class/, 'speaker notes were not read');
    assert.match(result.text, /\[Slide 1\][\s\S]*\[Slide 2\][\s\S]*\[Slide 3\]/, 'slides out of order');
  });

  test('a legacy .ppt (not a zip) is refused with a useful message', async () => {
    const result = await extract({
      buffer: Buffer.from('\xD0\xCF\x11\xE0 old OLE compound file', 'latin1'),
      fileName: 'legacy.ppt',
    });
    assert.equal(result.status, 'failed');
    assert.match(result.error, /zip archive|legacy/i);
  });

  test('a zip with no slides is refused', async () => {
    const JSZip = (await import('jszip')).default;
    const zip = new JSZip();
    zip.file('hello.txt', 'not a presentation');
    const result = await extract({
      buffer: await zip.generateAsync({ type: 'nodebuffer' }),
      fileName: 'notadeck.pptx',
    });
    assert.equal(result.status, 'failed');
    assert.match(result.error, /no slides/i);
  });
});

describe('images are refused honestly (no OCR is bundled)', () => {
  test('status is needs_text with a message that says why', async () => {
    const result = await extract({
      buffer: Buffer.from([0x89, 0x50, 0x4e, 0x47]),
      fileName: 'slide-photo.png',
      mimeType: 'image/png',
    });
    assert.equal(result.status, 'needs_text');
    assert.equal(result.text, '', 'text was invented for an image');
    assert.match(result.message, /OCR/);
    assert.match(result.message, /paste/i);
    assert.equal(result.error, null);
  });
});

describe('source type detection', () => {
  test('mime type wins, extension is the fallback', () => {
    assert.equal(detectSourceType({ mimeType: 'application/pdf' }), 'pdf');
    assert.equal(detectSourceType({ fileName: 'deck.pptx' }), 'pptx');
    assert.equal(detectSourceType({ fileName: 'notes.PDF' }), 'pdf');
    assert.equal(detectSourceType({ fileName: 'photo.jpeg' }), 'image');
    assert.equal(detectSourceType({ mimeType: 'image/heic' }), 'image');
    assert.equal(detectSourceType({ fileName: 'notes.txt' }), 'text');
    assert.equal(detectSourceType({ fileName: 'archive.zip' }), null);
  });
});

describe('POST /content/upload and /content/extract over HTTP', () => {
  test('a PDF upload creates a ready library item with the true page count', async () => {
    const educator = await makeUser({ role: 'educator' });
    const res = await educator
      .post('/api/content/upload')
      .field('title', 'Photosynthesis notes')
      .field('subject', 'Biology')
      .attach('file', pdfPath());

    assert.equal(res.status, 201);
    assert.equal(res.body.status, 'ready');
    assert.equal(res.body.source_type, 'pdf');
    assert.equal(res.body.page_count, 2);
    assert.match(res.body.extracted_text, /Calvin cycle/);
    assert.equal(res.body.owner_id, educator.id);
  });

  test('a PPTX upload reports the slide count', async () => {
    const educator = await makeUser({ role: 'educator' });
    const res = await educator.post('/api/content/upload').attach('file', pptxPath());
    assert.equal(res.status, 201);
    assert.equal(res.body.source_type, 'pptx');
    assert.equal(res.body.page_count, 3);
    assert.match(res.body.extracted_text, /Speaker notes/);
    assert.equal(res.body.title, 'deck');
  });

  test('POST /content/extract parses without persisting', async () => {
    const educator = await makeUser({ role: 'educator' });
    const res = await educator.post('/api/content/extract').attach('file', pdfPath());
    assert.equal(res.status, 200);
    assert.equal(res.body.page_count, 2);
    assert.ok(res.body.characters > 300);

    const library = await educator.get('/api/content');
    assert.equal(library.body.length, 0, '/content/extract must not create a library item');
  });

  test('an image upload lands as needs_text, not as ready with empty text', async () => {
    const educator = await makeUser({ role: 'educator' });
    const res = await educator
      .post('/api/content/upload')
      .attach('file', Buffer.from([0x89, 0x50, 0x4e, 0x47]), {
        filename: 'board.png',
        contentType: 'image/png',
      });
    assert.equal(res.status, 201);
    assert.equal(res.body.status, 'needs_text');
    assert.match(res.body.message, /OCR/);
  });

  test('a student cannot upload content', async () => {
    const student = await makeUser({ role: 'student' });
    const res = await student.post('/api/content/upload').attach('file', pdfPath());
    assert.equal(res.status, 403);
  });

  test('content is owner-scoped: another educator gets 404', async () => {
    const owner = await makeUser({ role: 'educator' });
    const other = await makeUser({ role: 'educator' });
    const created = await owner.post('/api/content/upload').attach('file', pdfPath());

    assert.equal((await other.get(`/api/content/${created.body.id}`)).status, 404);
    assert.equal((await other.del(`/api/content/${created.body.id}`)).status, 404);
    assert.equal((await owner.get(`/api/content/${created.body.id}`)).status, 200);
  });

  test('pasted text that is too short is needs_text, never a false "ready"', async () => {
    const educator = await makeUser({ role: 'educator' });
    const res = await educator
      .post('/api/content')
      .send({ title: 'Thin notes', source_type: 'text', raw_text: 'Too short.' });
    assert.equal(res.status, 201);
    assert.equal(res.body.status, 'needs_text');
  });

  test('an upload with no file is a field-level 422', async () => {
    const educator = await makeUser({ role: 'educator' });
    const res = await educator.post('/api/content/upload').field('title', 'Nothing');
    assert.equal(res.status, 422);
    assert.equal(res.body.error.field, 'file');
  });
});

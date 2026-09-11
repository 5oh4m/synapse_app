import { Router } from 'express';
import multer from 'multer';
import { config } from '../config.js';
import { many, one, query } from '../db/pool.js';
import { requireAuth, requireRole } from '../middleware/auth.js';
import { notFound, validation, badRequest } from '../errors.js';
import { contentJson } from '../util/serialize.js';
import { str, oneOf, assertUuid, rejectIdentityFields } from '../util/validate.js';
import { extract, detectSourceType, SOURCE_TYPES } from '../services/extraction.service.js';

export const contentRoutes = Router();

const upload = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: config.uploadLimitBytes, files: 1 },
});

const COLS = `id, owner_id, title, subject, source_type, status, extracted_text,
              page_count, file_name, error, created_at`;

/** Owner-scoped read: a non-owner gets 404, never 403. */
async function ownedContent(id, ownerId) {
  assertUuid(id, 'id');
  const row = await one(`SELECT ${COLS} FROM content_items WHERE id = $1 AND owner_id = $2`, [
    id,
    ownerId,
  ]);
  if (!row) throw notFound('Content not found.');
  return row;
}

contentRoutes.get('/', requireAuth, requireRole('educator'), async (req, res) => {
  const rows = await many(
    `SELECT ${COLS} FROM content_items WHERE owner_id = $1 ORDER BY created_at DESC`,
    [req.user.sub],
  );
  res.json(rows.map(contentJson));
});

contentRoutes.post('/', requireAuth, requireRole('educator'), async (req, res) => {
  rejectIdentityFields(req.body);
  const title = str(req.body, 'title', { required: true, max: 200 });
  const subject = str(req.body, 'subject', { max: 120 }) ?? null;
  const source_type = oneOf(req.body, 'source_type', SOURCE_TYPES, { def: 'text' });
  const raw_text = str(req.body, 'raw_text', { max: 2_000_000, trim: false }) ?? '';
  const file_name = str(req.body, 'file_name', { max: 260 }) ?? null;

  // Pasted text needs no parsing, but it still goes through the same status
  // rules so the UI never shows "ready" over an empty body.
  const result = await extract({
    buffer: Buffer.from(raw_text, 'utf8'),
    sourceType: source_type === 'image' ? 'image' : 'text',
    fileName: file_name,
  });

  const row = await one(
    `INSERT INTO content_items
       (owner_id, title, subject, source_type, status, extracted_text, page_count, file_name, error)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
     RETURNING ${COLS}`,
    [
      req.user.sub,
      title,
      subject,
      source_type,
      result.status,
      result.text,
      result.pageCount,
      file_name,
      result.error ?? result.message ?? null,
    ],
  );
  res.status(201).json(contentJson(row));
});

/**
 * Real extraction. PDF -> pdf-parse (true page count), PPTX -> unzip + slide
 * XML, image -> needs_text with an honest message.
 */
contentRoutes.post(
  '/upload',
  requireAuth,
  requireRole('educator'),
  upload.single('file'),
  async (req, res) => {
    rejectIdentityFields(req.body);
    if (!req.file) throw validation('Attach a file in the "file" field.', 'file');

    const fileName = req.file.originalname || 'upload';
    const declared = req.body?.source_type;
    if (declared && !SOURCE_TYPES.includes(declared)) {
      throw validation(`source_type must be one of: ${SOURCE_TYPES.join(', ')}.`, 'source_type');
    }
    const sourceType = declared || detectSourceType({ fileName, mimeType: req.file.mimetype });
    if (!sourceType) {
      throw validation(
        `"${fileName}" is not a supported file type. Upload a PDF or PPTX, or paste the text.`,
        'file',
      );
    }

    const result = await extract({
      buffer: req.file.buffer,
      fileName,
      mimeType: req.file.mimetype,
      sourceType,
    });

    const title =
      str(req.body, 'title', { max: 200 }) || fileName.replace(/\.[^.]+$/, '') || 'Untitled';

    const row = await one(
      `INSERT INTO content_items
         (owner_id, title, subject, source_type, status, extracted_text, page_count, file_name, error)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
       RETURNING ${COLS}`,
      [
        req.user.sub,
        title,
        str(req.body, 'subject', { max: 120 }) ?? null,
        result.sourceType,
        result.status,
        result.text,
        result.pageCount,
        fileName,
        result.error ?? result.message ?? null,
      ],
    );

    res.status(201).json({
      ...contentJson(row),
      // Surfaced separately so the UI can show the honest note without
      // treating it as a hard failure.
      message: result.message,
      characters: result.text.length,
    });
  },
);

/**
 * Stateless extraction: parse a file and hand back the text without creating a
 * library item. The previous build's UI called an endpoint like this that never
 * existed on the server.
 */
contentRoutes.post(
  '/extract',
  requireAuth,
  requireRole('educator'),
  upload.single('file'),
  async (req, res) => {
    if (!req.file) throw validation('Attach a file in the "file" field.', 'file');
    const fileName = req.file.originalname || 'upload';
    const result = await extract({
      buffer: req.file.buffer,
      fileName,
      mimeType: req.file.mimetype,
      sourceType: req.body?.source_type || undefined,
    });
    res.json({
      status: result.status,
      source_type: result.sourceType,
      file_name: fileName,
      page_count: result.pageCount,
      characters: result.text.length,
      extracted_text: result.text,
      message: result.message,
      error: result.error,
    });
  },
);

contentRoutes.get('/:id', requireAuth, async (req, res) => {
  res.json(contentJson(await ownedContent(req.params.id, req.user.sub)));
});

contentRoutes.delete('/:id', requireAuth, async (req, res) => {
  await ownedContent(req.params.id, req.user.sub);
  await query('DELETE FROM content_items WHERE id = $1 AND owner_id = $2', [
    req.params.id,
    req.user.sub,
  ]);
  res.status(204).end();
});

/** Multer's own errors (file too large, wrong field) mapped to the API shape. */
export function multerErrorHandler(err, _req, _res, next) {
  if (err && err.name === 'MulterError') {
    const message =
      err.code === 'LIMIT_FILE_SIZE'
        ? `That file is larger than the ${Math.round(config.uploadLimitBytes / (1024 * 1024))} MB upload limit.`
        : `Upload rejected: ${err.message}.`;
    return next(badRequest(message, err.field || 'file'));
  }
  return next(err);
}

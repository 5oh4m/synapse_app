// Demo data so a fresh checkout has something to show:
//   educator  demo.educator@quizzle.app / demo-password-1
//   student   demo.student@quizzle.app  / demo-password-1
// plus one library item and one published 5-question quiz.
//
// Idempotent: run it twice and it updates rather than duplicating.
import { assertConfig, config } from '../src/config.js';
import { pool, one, withTransaction, closePool } from '../src/db/pool.js';
import { hashPassword } from '../src/services/auth.service.js';

const EDUCATOR = {
  name: 'Dr Amara Okafor',
  email: 'demo.educator@quizzle.app',
  password: 'demo-password-1',
  role: 'educator',
};
const STUDENT = {
  name: 'Priya Raman',
  email: 'demo.student@quizzle.app',
  password: 'demo-password-1',
  role: 'student',
};
const EXTRA_STUDENTS = [
  { name: 'Tom Beckett', email: 'demo.student2@quizzle.app' },
  { name: 'Wei Zhang', email: 'demo.student3@quizzle.app' },
];

const SOURCE_TEXT = `
[Slide 1]
Photosynthesis converts light energy into chemical energy stored in glucose. It takes place in the
chloroplasts of plant cells, where the pigment chlorophyll absorbs light most strongly in the blue
and red parts of the visible spectrum.
Speaker notes: Stress that chlorophyll reflects green light, which is why leaves look green.

[Slide 2]
The light-dependent reactions occur in the thylakoid membranes. Water is split in a process called
photolysis, releasing oxygen as a by-product and supplying electrons to the electron transport
chain. The products are ATP and NADPH.

[Slide 3]
The Calvin cycle takes place in the stroma and does not require light directly. The enzyme RuBisCO
fixes carbon dioxide onto ribulose bisphosphate, and ATP and NADPH from the light reactions reduce
the result to triose phosphate, from which glucose is built.

[Slide 4]
Three factors limit the rate of photosynthesis: light intensity, carbon dioxide concentration and
temperature. Each shows a plateau once another factor becomes limiting, and the rate falls above
about 40 degrees Celsius as enzymes denature.
`.trim();

const QUESTIONS = [
  {
    question_text: 'Where in a plant cell do the light-dependent reactions take place?',
    options: ['The thylakoid membranes', 'The stroma', 'The cell wall', 'The mitochondrial matrix'],
    correct_index: 0,
    explanation: 'The light-dependent reactions occur in the thylakoid membranes of the chloroplast.',
    difficulty: 'easy',
    source_reference: 'Slide 2',
    time_limit_seconds: 15,
  },
  {
    question_text: 'Which gas is released as a by-product of photolysis?',
    options: ['Oxygen', 'Carbon dioxide', 'Nitrogen', 'Hydrogen'],
    correct_index: 0,
    explanation: 'Splitting water releases oxygen and supplies electrons to the transport chain.',
    difficulty: 'easy',
    source_reference: 'Slide 2',
    time_limit_seconds: 15,
  },
  {
    question_text: 'Which enzyme fixes carbon dioxide in the Calvin cycle?',
    options: ['RuBisCO', 'Chlorophyll', 'ATP synthase', 'Catalase'],
    correct_index: 0,
    explanation: 'RuBisCO fixes CO2 onto ribulose bisphosphate in the stroma.',
    difficulty: 'medium',
    source_reference: 'Slide 3',
    time_limit_seconds: 20,
  },
  {
    question_text: 'Why do leaves appear green?',
    options: [
      'Chlorophyll reflects green light',
      'Chlorophyll absorbs green light most strongly',
      'Green light carries the most energy',
      'The stroma contains a green pigment',
    ],
    correct_index: 0,
    explanation: 'Chlorophyll absorbs blue and red light and reflects green, so leaves look green.',
    difficulty: 'medium',
    source_reference: 'Slide 1',
    time_limit_seconds: 20,
  },
  {
    question_text: 'Above roughly 40 degrees Celsius the rate of photosynthesis falls. Why?',
    options: [
      'Enzymes denature',
      'Chlorophyll stops reflecting green light',
      'Carbon dioxide becomes insoluble',
      'The Calvin cycle starts requiring light',
    ],
    correct_index: 0,
    explanation: 'Above about 40 C the enzymes involved denature, so the rate drops.',
    difficulty: 'hard',
    source_reference: 'Slide 4',
    time_limit_seconds: 30,
  },
];

async function upsertUser({ name, email, password, role }) {
  const password_hash = await hashPassword(password);
  return one(
    `INSERT INTO users (name, email, password_hash, role)
     VALUES ($1,$2,$3,$4)
     ON CONFLICT (email) DO UPDATE
       SET name = EXCLUDED.name, password_hash = EXCLUDED.password_hash, role = EXCLUDED.role
     RETURNING id, name, email, role`,
    [name, email, password_hash, role],
  );
}

export async function seed({ silent = false } = {}) {
  const say = (m) => {
    if (!silent) console.log(m);
  };

  const educator = await upsertUser(EDUCATOR);
  const student = await upsertUser(STUDENT);
  const others = [];
  for (const s of EXTRA_STUDENTS) {
    others.push(await upsertUser({ ...s, password: STUDENT.password, role: 'student' }));
  }
  say(`  educator  ${educator.email}  (password: ${EDUCATOR.password})`);
  say(`  student   ${student.email}  (password: ${STUDENT.password})`);
  say(`  students  ${others.map((o) => o.email).join(', ')}`);

  const { quiz, created } = await withTransaction(async (client) => {
    const existing = await client.query(
      `SELECT id FROM quizzes WHERE owner_id = $1 AND title = $2`,
      [educator.id, 'Photosynthesis: light, carbon and limits'],
    );
    if (existing.rows[0]) {
      return { quiz: existing.rows[0], created: false };
    }

    const { rows: contentRows } = await client.query(
      `INSERT INTO content_items
         (owner_id, title, subject, source_type, status, extracted_text, page_count, file_name)
       VALUES ($1,$2,$3,'pptx','ready',$4,4,'photosynthesis.pptx')
       RETURNING id`,
      [educator.id, 'Photosynthesis lecture deck', 'Biology', SOURCE_TEXT],
    );

    const { rows: quizRows } = await client.query(
      `INSERT INTO quizzes (owner_id, title, subject, description, content_id, status)
       VALUES ($1,$2,'Biology',$3,$4,'published')
       RETURNING id`,
      [
        educator.id,
        'Photosynthesis: light, carbon and limits',
        'Five questions covering the light reactions, the Calvin cycle and limiting factors.',
        contentRows[0].id,
      ],
    );
    const quizId = quizRows[0].id;

    for (let i = 0; i < QUESTIONS.length; i += 1) {
      const q = QUESTIONS[i];
      await client.query(
        `INSERT INTO questions
           (quiz_id, question_text, options, correct_index, explanation, difficulty,
            source_reference, order_index, time_limit_seconds)
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)`,
        [
          quizId,
          q.question_text,
          JSON.stringify(q.options),
          q.correct_index,
          q.explanation,
          q.difficulty,
          q.source_reference,
          i,
          q.time_limit_seconds,
        ],
      );
    }
    return { quiz: { id: quizId }, created: true };
  });

  say(
    created
      ? `  quiz      published, 5 questions  (${quiz.id})`
      : `  quiz      already seeded  (${quiz.id})`,
  );
  return { educator, student, others, quizId: quiz.id };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  assertConfig();
  console.log(`seeding ${config.databaseUrl}`);
  seed()
    .then(() => closePool())
    .then(() => process.exit(0))
    .catch(async (err) => {
      console.error(`seed failed: ${err.message}`);
      await closePool().catch(() => {});
      process.exit(1);
    });
}

export { pool };

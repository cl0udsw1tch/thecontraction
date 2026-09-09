# tc — Architecture Overview

A personal TeX article archive. Write TeX, it compiles (unified + KaTeX) into
static HTML, served to readers. This doc captures the current shape of the
system after several pivots (Oracle → AWS, Supabase → self-hosted, Redis
queue → Lambda invoke) so future-you doesn't have to reconstruct the reasoning
from scratch.

## Repos

| Repo | Responsibility |
|---|---|
| `tc-web` | Next.js frontend. Talks to `tc-api` over HTTP. Never touches Postgres directly. |
| `tc-api` | Fastify backend. Owns auth, article CRUD, and triggering renders. |
| `tc-render` | The compile pipeline (unified + KaTeX). Runs as an AWS Lambda in production, and as a local Docker service (`dev-render`) in development. |

No monorepo — each is independently deployable. Justified here because the
render step is genuinely decoupled (fire-and-forget invoke), so there's little
cross-repo coupling to manage.

## Infrastructure

- **Compute**: one AWS EC2 `t3.micro` running Postgres and `tc-api` as
  separate processes (not isolated onto separate VMs — accepted trade-off at
  this scale; see "Open questions" below).
- **Database**: self-hosted Postgres on that VM, private subnet, no public
  IP. Only reachable from `tc-api` (same box) and Lambda (via a security
  group rule scoped to Lambda's SG, not an IP range).
- **Render compute**: AWS Lambda (`tc-render`), VPC-attached to reach
  Postgres, with a free **S3 Gateway VPC Endpoint** so it can reach S3
  without a NAT Gateway (NAT would cost ~$32+/month just to exist — avoided
  entirely since S3 is the only outside-VPC thing Lambda needs).
- **Storage**: S3 bucket for rendered HTML output.
- **Frontend hosting**: not yet decided — Vercel is the default lean (zero
  config for Next.js) unless a reason to stay AWS-native comes up.

Real monthly cost at this scale, once free-tier/credit windows lapse:
roughly the price of one `t3.micro` (~$7.59) + EBS storage (~$2) + the
public IPv4 charge (~$3.60) ≈ **$13–14/month**. Lambda and S3 stay
effectively free at this traffic level (S3's 5GB free tier is 12-months-only,
then pennies).

## The write → render → read pipeline

1. Client sends `POST /articles` (or `PUT /articles/:id`, or
   `POST /articles/:id/render` to re-trigger without editing content) with a
   valid `Authorization: Bearer <jwt>`.
2. `tc-api`'s `articles` module validates input (Zod), writes/reads the row
   in Postgres via Prisma, and asynchronously invokes the render step —
   passing only the `articleId`, not the TeX content itself.
3. The render step re-reads `texSource` from Postgres (decoupled from the
   original request — it doesn't matter how much later this runs), compiles
   it with `unified` + `rehype-katex` (`output: 'mathml'` — see "KaTeX output
   mode" below), writes the resulting HTML to S3 (prod) or local disk (dev),
   and writes `status` + `s3Url` back to the same Postgres row.
4. `tc-web` reads article metadata + status through `tc-api` (Postgres is
   private, `tc-web` can't reach it directly), and fetches rendered HTML
   directly from the stored URL — `tc-api` tells the frontend *where* the
   content lives, it doesn't proxy the content itself.

Why Postgres is in the loop at all, given it might look like just a hop
between the API and S3: it's the only durable store for the TeX source
itself (the HTTP request body doesn't persist), it's what lets the render
step be decoupled/async (re-read by ID rather than passed inline), and it's
the single source of truth for status/metadata that both `tc-api` and any
future reader need to query.


## Modules inside `tc-api`

Structured as service modules (controller → service → repository →
schema), not a single flat router. `auth` and `articles` are separate
modules on purpose — auth is a cross-cutting concern (every future module
will need "who is this, are they allowed"), and mixing it into `articles`
would mean re-deriving or importing auth logic into every new module
instead of depending on one shared guard.

### `auth`
- `POST /auth/signup`, `POST /auth/login` — bcrypt password hashing, JWT
  issuance (`sub` claim = user id, 7-day expiry).
- `guard.ts` exports `requireAuth`, a Fastify `preHandler` other modules
  import — verifies the bearer token, attaches `userId` to the request.
- Deliberately returns the same error for "no such email" and "wrong
  password" (`INVALID_CREDENTIALS`) to avoid leaking which emails have
  accounts.

### `articles`
- `POST /articles`, `PUT /articles/:id`, `GET /articles`,
  `GET /articles/:id`, `DELETE /articles/:id`, `POST /articles/:id/render`.
- **Every route in this module is guarded, including GETs** — registered
  once via `app.addHook('preHandler', requireAuth)` at the top of the
  controller, so it's not possible to forget the guard on an individual
  route.
- Ownership is checked separately from authentication (`getOwnedArticle`):
  a valid token proves *who you are*, not that you own the specific
  article being requested. Returns `404`, not `403`, when the article
  exists but belongs to someone else — a `403` would leak that the ID is
  valid.
- Slug collisions are checked explicitly (`findBySlug` before `create`) and
  return `409`, rather than letting Prisma's raw `P2002` unique-constraint
  error bubble up as an ugly `500`.
- Holds no compile logic — that all lives in `tc-render`. This module's job
  is CRUD + orchestration (validate, persist, trigger), not rendering.

## Dev / prod split

The same `tc-api` code runs in both environments; behavior branches on
`env.NODE_ENV`.

|  | Local dev | Production |
|---|---|---|
| Postgres | Docker Compose (`tc_dev`) | Self-hosted on EC2 |
| Render trigger | HTTP POST to `dev-render` (Docker, port 4000) | `InvokeCommand` to the real Lambda |
| Render output | Written to local disk (`tc-render/local-output/`) | Uploaded to S3 |
| `JWT_SECRET` | Separate value from prod | Separate value from dev |

**Why two separate JWT secrets:** a token signed in one environment
shouldn't be valid in the other. Sharing the secret means a leak in either
environment compromises both.

**Why the render trigger is swappable rather than the Lambda being
"smart" about which DB to use:** Lambda can only reach what's inside its
VPC. The local dev Postgres runs on a laptop with no public address, so
making the *deployed* Lambda reach it would mean exposing a dev database to
the internet just for convenience — a real security trade not worth
making. Instead, the actual render logic (`renderArticle` in `tc-render`)
is written once and shared: `handler.ts` (Lambda) and `dev-server.ts`
(local Docker service) both call it, each supplying their own DB connection
string and a `writeOutput` function (S3 upload vs. local file write).

`tc-render`'s repo root, alongside `tc-web` and `tc-api`, holds a
`docker-compose.yml` for local dev — Postgres + `dev-render`. It is
**not part of any single repo** on purpose (it's orchestration across all
three, not code belonging to one of them); if it needs to survive a fresh
clone of the repos onto another machine, it'd need its own small git repo
at the parent directory level.

## KaTeX output mode

`rehype-katex`'s `output` option has three settings, easy to get backwards:

- `'htmlAndMathml'` (default) — both a styled-HTML and a MathML rendering
  of every expression. Without KaTeX's CSS loaded, both show up as visible
  duplicated text.
- `'html'` — styled spans only, but they're inert without `katex.min.css`
  loaded on the page (positioning, fractions, roots all depend on that
  stylesheet).
- `'mathml'` — pure `<math>` markup. **This is what's currently used.**
  Modern browsers (Chrome 109+, Firefox, Safari) natively render MathML
  without any external CSS or font dependency — genuinely self-contained
  output, no CDN reliance. Trade-off: no graceful degradation on very old
  or unusual browsers without MathML support. Acceptable for a personal
  project.

## Open questions / things intentionally punted

- **API/DB isolation**: `tc-api` and Postgres currently share one VM. A
  second VM (with the DB in a private subnet, only reachable from the
  API's security group) is the more idiomatic separation, and worth doing
  if resource contention becomes real or as a deliberate networking
  exercise — not done yet because it roughly doubles compute cost for a
  personal project's actual traffic.
- **Frontend hosting**: not yet chosen (see "Infrastructure" above).
- **Rendered-page styling/embedding**: the S3/local HTML output hasn't
  been embedded into an actual `tc-web` viewer page yet — no decisions made
  yet about templating, layout, or whether to move off MathML-only output
  later for stylistic reasons.
- **Signup partial-failure**: if `authService.signup` fails after the DB
  write but before token issuance (has happened once, from a missing env
  var), the user row exists with no token ever returned. Recoverable via a
  normal login. Worth wrapping in a transaction if `signup` ever grows more
  steps.

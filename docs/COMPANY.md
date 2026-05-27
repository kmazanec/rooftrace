# CompanyCam — Company Brief for RoofTrace

> Companion to the project brief at `../BRIEF.md`. This file informs every
> downstream design decision: what stack to mirror, what brand voice to match,
> what stretch features earn respect. Anything tagged **[verify]** should be
> re-checked before being quoted aloud to the CTO. Anything **[confirmed]** has
> a source we trust.

## Who they are

- **Product:** photo-first documentation/collaboration SaaS for trades contractors
  (roofing, exteriors, restoration, HVAC, solar). "From first walkthrough to
  final payment." Crews capture jobsite photos that auto-organize by project,
  GPS, and timestamp, then sync to the office and customers.
  [confirmed — companycam.com, partner brief]
- **Founded:** 2015, Lincoln NE, by **Luke Hansen** — domain founder (sales/
  marketing operator at his family's roofing business, **White Castle Roofing**),
  not an engineer. [confirmed — [frontlines.io](https://www.frontlines.io/podcasts/luke-hansen/), Crunchbase]
- **Stage:** private, late-stage. **~$415M raise in Aug 2025 led by B Capital
  at a $2B post-money valuation** — largest single equity round in Nebraska
  history. [confirmed — [Flatwater Free Press](https://flatwaterfreepress.org/nebraska-startup-companycam-now-valued-at-2-billion-a-first-in-state-history/),
  [1011now](https://www.1011now.com/2025/11/25/nebraska-startup-companycam-now-valued-2-billion-first-state-history/),
  PitchBook]
- **Scale:** ~200–500 employees, ~51–100 engineers. Photo corpus measured in
  the hundreds of millions to (likely) billions of geotagged jobsite photos.
  [confirmed — partner brief; corpus magnitude is the **strategically loaded
  number** — re-verify exact phrasing before quoting]
- **Earlier funding:** $30M Series B led by Insight Partners; cap table also
  includes JMI Equity, Nelnet, Blueprint Equity, WndrCo, Decades Holdings.
  [confirmed]

### The $2B raise thesis (load-bearing for this project)

The 2025 raise is **explicitly aimed at AI-driven transformation of the
contractor workflow** — winning customers, getting paid faster, system-of-
record for the job. Translation for us: leadership is actively shopping for AI
features that bundle into the seat price and reduce wallet leakage to vendors
like EagleView and Hover. **RoofTrace is exactly the shape of feature that
thesis is buying.** [confirmed — partner brief]

## Business model

- Per-user/seat SaaS. Tiered plans. Pricing is in the ~$24–$50/user/mo range
  for paid tiers; enterprise quoted. [verify exact tiers/prices at
  companycam.com/pricing before quoting]
- **SMB vertical SaaS economics:** higher structural churn than enterprise,
  CAC payback 6–12 months at ~3:1 LTV:CAC. Net revenue retention and logo
  churn are the make-or-break metrics. Word-of-mouth in tight trade
  communities historically kept CAC low — preserving that as they scale
  post-mega-round is a core strategic tension. [confirmed — partner brief,
  [Optifai churn benchmarks](https://optif.ai/learn/questions/b2b-saas-churn-rate-benchmark/)]
- **Expansion levers:** seats, integrations (estimating/CRM/insurance), and
  **AI features that justify price increases + deepen workflow lock-in.**
  RoofTrace lives in that third lever.

## Competitive landscape (memorize these names)

| Bucket | Names | Relationship to CompanyCam |
|---|---|---|
| Field-service / job-mgmt suites | ServiceTitan, Buildertrend, Jobber, JobNimbus, Procore | Adjacent / partial overlap; CC integrates rather than competes head-on |
| Photo-doc competitors | Raken, PlanGrid/Fieldwire, regional clones | Direct on the photo wedge; CC wins on crew-friendliness + scale |
| **Measurement vendors (relevant to RoofTrace)** | **EagleView, Hover, GAF QuickMeasure, Roofr (resells EagleView), Nearmap AI, CAPE Analytics, IMGING** | **Wallet-share competitors** — every $25–$90 report a CC contractor buys today is leakage. **No deep platform partnerships known with the top three.** [verify CC integrations page] |

**Strategic implication for the RoofTrace pitch:** this is **not** a "compete
with EagleView" play (that's a 10-year R&D program). It is a **"capture the
$25–$90 per roof currently leaking to vendors"** play. Frame it as bundling
into the seat price, not displacement. The CTO has heard the displacement
pitch and discounts it.

## Tech stack

### High confidence

- **Backend:** Ruby on Rails. The dominant language in their stack.
  [confirmed — partner brief: "Ruby-primary platform"; their own briefs
  encourage Rails + Solid Queue + ActionCable for AI projects]
- **Mobile:** Swift (native iOS) **and** React Native. The "and" suggests
  a legacy native iOS app plus a newer RN effort, or a hybrid shell — exact
  split unknown. **No Flutter, no Kotlin-first.** [confirmed — partner brief
  + project-3 brief stack listing]
- **Database:** PostgreSQL. [confirmed — partner brief]
- **Cloud:** AWS (the only sane answer for a Rails shop at petabyte photo
  scale). [confirmed directionally — partner brief mentions AWS and S3
  tiering; Keith's prior experience there is a portfolio fit]
- **LLM tooling:** **RubyLLM** ([github.com/crmne/ruby_llm](https://github.com/crmne/ruby_llm))
  is the preferred AI client. Their internal AI strategy is to **keep
  inference in Rails and call out to provider APIs** (OpenAI, Anthropic,
  Gemini) — *not* to operate a separate Python ML service tier for LLM
  features. [confirmed — their own briefs explicitly encourage RubyLLM]
- **Async jobs:** Sidekiq today, likely migrating toward Rails 8 **Solid
  Queue**. [inferred but defensible]
- **Image pipeline:** ActiveStorage + S3 with custom transcoding, EXIF/GPS
  extraction, perceptual-hash dedup. Storage tiering (Standard → IA →
  Glacier) + CloudFront CDN. [inferred — partner brief]

### CV / ML

- An ML-Engineer-Computer-Vision role is live in their portal → there is an
  **internal CV team or active investment area**. [confirmed — partner brief]
- Geospatial/PostGIS work is **likely greenfield for them** — RoofTrace is a
  new surface area. **Leverage, not a liability:** we get to bring domain
  depth they don't have. [inferred]

### Cultural / engineering values to respect

- **Rails-monolith-pragmatist, DHH-aligned.** Boring on purpose. They prefer
  Postgres-over-SeparateVectorDB, Solid Queue-over-Redis-stack, RubyLLM-over-
  LangChain-Python. Microservices need to justify themselves.
- **Crew-first product instinct.** Any decision evaluated against "does it
  survive a roofer with muddy gloves in November rain?" Anything assuming
  good connectivity, clean inputs, or office-grade UX will get pushback.
- **Honest-uncertainty UX.** Confidence-aware: "≈2,847 sq ft ± 4% — methodology
  here" beats "AI says 2,847." Their own project-2 brief uses this exact tone.
- **Pragmatism over hype.** Luke Hansen's public voice is "help contractors
  do good work," not "AI transformation." Match that register.

### What they will push back on

- **Microservices without a load-bearing reason** (it fragments their
  monolith).
- **Python-first AI architecture for LLM features** (use RubyLLM unless you
  have a *specific numerics/library* reason — RoofTrace does, for the
  geospatial pipeline, and we should be explicit about that boundary).
- **Cloud architectures that assume connectivity** (their users work on metal
  roofs with one bar).
- **Generic LLM-wrapper plays with no moat.**

## Founders & technical leadership

- **Luke Hansen — Founder & CEO** [confirmed]. Domain founder, ex-roofer-by-
  marriage, customer-obsessed, anti-hype operator. Yellow flag: non-technical
  founder + huge recent raise can mean top-down product pressure and
  aggressive AI mandates — probe how engineering balances modernization
  against the AI feature push.
- **VP/Director of Engineering** — **not publicly identified in the partner
  brief.** **TODO before any conversation:** 30 minutes on LinkedIn
  "People" tab filtered to eng leadership; check RailsConf/RubyConf YouTube
  for "CompanyCam" talks; check `github.com/companycam` org for active
  maintainers; check Remote Ruby / Code with Jason podcast back-catalog.
  Walking into a CTO conversation without their name is an own-goal.

## Brand & voice (the design contract)

> This section serves as the design/brand contract for the build stage. If
> a screen we ship doesn't satisfy this, it isn't done.

### Visual identity

- **Primary brand color: a saturated, slightly-warm construction-cone orange**
  — deliberately PPE / hi-viz adjacent, not soft tech-startup orange (Stripe,
  Algolia). [verify exact hex on companycam.com — they have a public brand]
- **Palette:** monochrome + orange. Charcoal/near-black for body & UI chrome;
  off-white / pure-white surfaces; neutral grays for secondary. Minimal
  additional accent colors.
- **Typography:** clean, geometric sans-serif. Workmanlike, not quirky.
  Wordmark uses a clean sans. [verify exact font face on site]
- **Density:** moderate-to-high. Professional users live in the app daily and
  want information density, not whitespace-as-luxury. Big tappable controls
  for field use; dense photo grids for office review.
- **Motion:** minimal, functional. No flashy hero animations. Responsiveness
  over polish.
- **Photography:** **real crews on real jobsites.** Mud, hi-viz vests,
  ladders, framed houses. Not stock-photo office people. The visual signal
  everywhere is "we work where you work."

### Voice / copy

- Direct, plainspoken, contractor-respectful. **Trade-magazine register**,
  not Bay Area SaaS marketing.
- Specific over abstract: *"Take a photo. We organize it. The office sees
  it instantly."* — not *"Streamline your project documentation lifecycle."*
- The crew is the hero. Features framed as making the crew's day easier, the
  owner's revenue safer, the customer's experience better — in that order.
  **Never** "AI-powered transformation."
- Honest about being a tool, not a religion. Surface model uncertainty
  rather than hiding it: *"≈3.2 cubic yards — does this look right?"*
- Lincoln, NE Midwest sensibility. Calm, useful, no oversell.

### Concrete design guidance for RoofTrace surfaces

- **Color use:** orange as the primary CTA / action-state color only — *not*
  decorative washes. Body UI is neutral. Measurement values are charcoal on
  white. Confidence indicators use muted grays unless an actual alarm is
  warranted.
- **Map / 3D viz:** the satellite + LiDAR overlay should feel like a
  **measurement instrument**, not a video game. Reference aesthetic: Mapbox
  Light, Carto Positron, topographic-survey style. **Not** Google Earth
  consumer eye-candy.
- **PDF export:** look like a **construction document or insurance
  supplement** — orange header bar with the CompanyCam wordmark, sober
  monospace measurements table, methodology footnote, signature line.
  Adjusters need to file it; it should look filed-ready.
- **Mobile capture UX:** large tap targets, high contrast (works in direct
  sun), voice-prompt option, forgives bad input.
- **Confidence UX:** show methodology source on every number ("from LiDAR" /
  "from imagery" / "from your photo capture") so the contractor knows how
  hard to defend it.

## Domain insight — workflows beyond taking photos

CompanyCam users don't just snap photos. They:

- Live inside the **Project timeline** view — chronological photo feed of a
  job, the daily-opened surface.
- Use **before/after pinned pairs** for marketing, customer reports, and
  insurance evidence. High strategic relevance to RoofTrace.
- Apply **annotations and markups** on photos — notes, tags, damage
  callouts. Natural surface for AI-detected roof features.
- Generate **CompanyCam Reports** — polished PDF/web reports from project
  photos. **The natural integration target for RoofTrace measurements.**
- Sync into **CRMs and quoting tools** — JobNimbus, AccuLynx, Roofr, Leap,
  Buildertrend, ServiceTitan. [verify exact partner list]
- Share **public links** to project photo timelines with homeowners and
  insurance adjusters as evidence packets.
- Rely on **EXIF + geotagging** for crew accountability and dispute defense.

## Stretch-feature candidate pool (informs Step-3 stretch round)

Rank-ordered for strategic resonance with CompanyCam:

1. **"Measurement attaches to the Project."** RoofTrace output lives inside
   an existing CompanyCam Project alongside the photo timeline — not as a
   standalone artifact. Back-link to dated jobsite photos. **This is the
   architectural framing the CTO will care about more than measurement
   accuracy.**
2. **Insurance-claim-ready PDF.** Roof diagram + facet table + methodology
   + dated jobsite photos as supporting evidence + GPS-verified visit
   timestamps. We're not selling measurement, we're selling
   **claim-defensibility.**
3. **AR overlay onto existing project photos.** Project the LiDAR-derived
   roof facets onto a photo the crew already took. Reuses the corpus; high
   visual wow.
4. **Render measurement into CompanyCam Reports.** As a section in the
   contractor's existing branded Report template.
5. **Auto-trigger on first jobsite photo at an address.** Background-fetch
   satellite/LiDAR the moment a crew arrives. By the time they're back in
   the truck, the measurement is waiting. Native-feeling workflow.
6. **Cross-pollinate with damage detection** (their project-2 brief). Roof
   facet geometry + per-photo damage detections → automatic "damaged
   shingles per facet" counts → Xactimate line items. Mention even if not
   built, to show you see the whole strategic surface.
7. **Voice-guided fallback capture** in the field when satellite/LiDAR are
   poor (per their project-3 brief). Uses the capture habit the crew
   already has.
8. **Comparison over time.** Re-measure on every visit; surface deltas.
   Unique to CompanyCam — no one else has the repeated-visit photo
   timeline for the same address.

## Pre-CTO-conversation verification checklist [TODO before quoting]

- [ ] **Current CTO / VP Eng name and bio.** LinkedIn → People filtered to
  Engineering. Single highest-leverage 30 minutes of prep.
- [ ] **Exact valuation, raise size, lead investor.** Crunchbase /
  PitchBook. Partner brief says $415M / $2B / B Capital — confirm phrasing.
- [ ] **Exact pricing tiers and prices.** companycam.com/pricing.
- [ ] **Current homepage tagline.** companycam.com.
- [ ] **Integrations partner list.** companycam.com/integrations — verify
  JobNimbus, AccuLynx, Roofr, Buildertrend, ServiceTitan, Leap presence.
- [ ] **github.com/companycam** activity — what they open-source tells you
  what they value.
- [ ] **Engineering blog / talks** — search "site:companycam.com blog" and
  "CompanyCam" on the RailsConf YouTube channel.
- [ ] **Photo corpus magnitude** — re-verify "hundreds of millions" vs
  "billions" before quoting.

## Sources

- `/Users/keith/dev/gauntlet/partners/companycam.md` — Keith's prior partner
  brief, the strongest local source.
- `/Users/keith/dev/gauntlet/companycam/01-precision-roof-measurement.md` —
  Keith's prior analysis of this exact project.
- [Flatwater Free Press: CompanyCam at $2B valuation](https://flatwaterfreepress.org/nebraska-startup-companycam-now-valued-at-2-billion-a-first-in-state-history/)
- [Insight Partners: $30M Series B](https://www.insightpartners.com/ideas/companycam-raises-30m-in-series-b-funding-round-to-help-contractors-document-jobs-communicate-with-crews-and-cover-their-butts/)
- [frontlines.io podcast: Luke Hansen](https://www.frontlines.io/podcasts/luke-hansen/)
- [CompanyCam founder story](https://companycam.com/resources/blog/companycam-founders-story)
- [RubyLLM gem](https://github.com/crmne/ruby_llm) — their preferred LLM client

---

*Synthesized from the partner brief (Nov 2025) and adjacent project research.
The model could not fresh-fetch companycam.com during this research session;
items tagged **[verify]** must be re-checked before being quoted to the CTO.*

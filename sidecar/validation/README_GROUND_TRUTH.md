# Ground-truth controls — collection protocol

The accuracy report (ADR-017) computes MAPE on total roof area against three
independent ground-truth controls. **Collecting this data is manual human work**
— the harness code does not (and cannot) automate it. The builder commits the
structure (`ground_truth.yaml` with `todo: true` placeholders); a human fills it.

## The three controls

### 1. EagleView Premium report (~$80, 1–2 business days)

- Buy one EagleView Premium report on a roof with **confirmed USGS 3DEP
  coverage** (so it is also in `test_addresses.yaml`).
- Hand-transcribe `total_area_sq_ft`, `per_facet_areas`, and
  `predominant_pitch_ratio` into `ground_truth.yaml` under `eagleview`.
- EagleView reports **pitched (3D) area** — the same quantity the pipeline
  reports — so it is the strongest control.
- **Licensing:** commit the PDF to `validation/ground_truth/` only if
  redistribution is permitted by the EagleView license. Otherwise reference it
  by report id in `source_url` and keep the PDF out of the repo.

### 2. Tape-measured roof (DIY, ~1–2 h)

- Tape-measure one **simple** roof (the candidate's or a friend's house).
- Draw a facet sketch, record each facet's dimensions and pitch.
- Commit the sketch to `validation/ground_truth/` and fill the
  `tape_measured` entry.
- Caveat: human measurement error is a few percent; pitch is measured with a
  level/app, not surveyed.

### 3. County-assessor record (free, online)

- Pull one parcel's assessor record; record the URL and extracted square
  footage in the `county_assessor` entry.
- **Caveat:** assessor square footage is usually **floor/footprint** area
  (planimetric), *not* pitched roof area. Treat it as a loose sanity bound, not
  a precise reference. The `caveats` field must say so.

## Why hand-transcription, not a parser

There is no committed EagleView PDF parser: the formats are proprietary and a
one-off transcription of three numbers is cheaper and more auditable than a
brittle parser. The transcribed values + the `source_url`/`caveats` provenance
are the audit trail.

## Once filled

`tests/test_validation_config.py` enforces, for every non-`todo` control, that
its `address` exists in `test_addresses.yaml`, its area is positive, and its
pitch ratio is non-negative. Removing `todo: true` flips the gate on.

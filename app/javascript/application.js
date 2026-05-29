// Entry point for the Hotwire (Turbo + Stimulus) pages. Importing turbo-rails
// activates Turbo Drive AND the `<turbo-cable-stream-source>` element that
// `turbo_stream_from` renders — without this, the job status page's live Turbo
// Stream updates (status broadcasts over ActionCable, ADR-013) never connect and
// the page stays frozen on its server-rendered state.
//
// The React report-viewer island is NOT loaded here — it is a separate esbuild
// bundle included only on the report page (ADR-013).
import "@hotwired/turbo-rails";
import "controllers";

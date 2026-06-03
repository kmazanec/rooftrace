// Register Stimulus controllers pinned under "controllers/*" by the importmap
// (pin_all_from in config/importmap.rb).
//
// `viewer_controller` is deliberately NOT registered here: per ADR-013 the React
// report-viewer island's live mount path is the self-mounting esbuild bundle
// (app/javascript/viewer/bootstrap.ts), loaded only on the report page. Letting
// Stimulus also register viewer_controller would double-mount the island (and
// try to import the React entry through the importmap, where it isn't pinned).
// viewer_controller.js remains the documented drop-in replacement for that day.
import { application } from "controllers/application";

import StatusReconcileController from "controllers/status_reconcile_controller";
application.register("status-reconcile", StatusReconcileController);

import AddressAutocompleteController from "controllers/address_autocomplete_controller";
application.register("address-autocomplete", AddressAutocompleteController);

import FacetHighlightController from "controllers/facet_highlight_controller";
application.register("facet-highlight", FacetHighlightController);

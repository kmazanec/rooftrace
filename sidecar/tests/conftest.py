import os

# Set a deterministic test secret BEFORE importing the app so auth.require_bearer's
# eager check passes when /skeleton is hit.
os.environ.setdefault("SIDECAR_SHARED_SECRET", "test-shared-secret")

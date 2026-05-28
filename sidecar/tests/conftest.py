import os

# Force a deterministic test secret BEFORE app.main (and thus app.auth, which
# reads SIDECAR_SHARED_SECRET once at import) is imported. Use `=`, NOT
# setdefault: CI sets SIDECAR_SHARED_SECRET=ci-shared-secret in the job env, and
# setdefault would leave that in place while the test's bearer header is the
# fixed value — a guaranteed 401. Owning the secret here makes the suite
# independent of the ambient env.
os.environ["SIDECAR_SHARED_SECRET"] = "test-shared-secret"

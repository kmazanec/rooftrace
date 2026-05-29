# syntax=docker/dockerfile:1
# check=error=true

# This Dockerfile is designed for production, not development. Use with Kamal or build'n'run by hand:
# docker build -t f_01_walking_skeleton .
# docker run -d -p 80:80 -e RAILS_MASTER_KEY=<value from config/master.key> --name f_01_walking_skeleton f_01_walking_skeleton

# For a containerized dev environment, see Dev Containers: https://guides.rubyonrails.org/getting_started_with_devcontainer.html

# Make sure RUBY_VERSION matches the Ruby version in .ruby-version
ARG RUBY_VERSION=4.0.1
# Node toolchain for the JS bundling step (jsbundling-rails + esbuild). Named
# stage so we can COPY the binaries into the build stage (--from doesn't expand
# build-args inline). Keep in sync with the local node/yarn used in CI.
ARG NODE_VERSION=22.17.1
FROM docker.io/library/node:$NODE_VERSION-slim AS node
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

# Rails app lives here
WORKDIR /rails

# Install base packages. The roof-report PDF path (ADR-014) runs Grover, which
# drives a Puppeteer-managed headless Chromium — that Chromium needs a set of
# system libraries (fonts, nss, X/GTK shims, libgbm) present at runtime.
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      curl libjemalloc2 libvips postgresql-client \
      ca-certificates fonts-liberation libnss3 libnspr4 libatk1.0-0 \
      libatk-bridge2.0-0 libcups2 libdrm2 libxkbcommon0 libxcomposite1 \
      libxdamage1 libxfixes3 libxrandr2 libgbm1 libpango-1.0-0 libcairo2 \
      libasound2 libatspi2.0-0 libx11-6 libxcb1 libxext6 libxi6 && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Set production environment variables and enable jemalloc for reduced memory usage and latency.
ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development" \
    LD_PRELOAD="/usr/local/lib/libjemalloc.so"

# Throw-away build stage to reduce size of final image
FROM base AS build

# Puppeteer downloads its managed Chromium here; the directory is copied into
# the final image so Grover finds the browser at runtime.
ENV PUPPETEER_CACHE_DIR="/usr/local/puppeteer"

# Install packages needed to build gems (plus Node.js + npm for Puppeteer, which
# Grover uses to render the report PDF — ADR-014).
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      build-essential git libpq-dev libvips libyaml-dev pkg-config nodejs npm && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Install Node + Corepack-managed Yarn from the `node` stage. jsbundling-rails
# enhances `assets:precompile` to depend on `javascript:build` (-> `yarn build`),
# which bundles the React report-viewer island (ADR-013) into app/assets/builds.
# So the build stage MUST have Node/Yarn and the JS deps installed BEFORE
# assets:precompile, or precompile fails (or ships a viewer with no JS).
# The same Yarn install also pulls puppeteer + its managed Chromium for the
# Grover-driven report PDF render (ADR-014) — both JS toolchains share one
# package.json / yarn.lock, so there is a single install step (below) rather
# than a separate `npm ci`.
COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm && \
    ln -s /usr/local/lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx && \
    ln -s /usr/local/lib/node_modules/corepack/dist/corepack.js /usr/local/bin/corepack && \
    corepack enable

# Install application gems
COPY vendor/* ./vendor/
COPY Gemfile Gemfile.lock ./

RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    # -j 1 disable parallel compilation to avoid a QEMU bug: https://github.com/rails/bootsnap/issues/495
    bundle exec bootsnap precompile -j 1 --gemfile

# Copy application code
COPY . .

# Install JS deps for the esbuild viewer bundle AND puppeteer's managed Chromium
# (Yarn Berry, node-modules linker per .yarnrc.yml). --immutable fails the build
# if yarn.lock would change, matching CI. Must run before assets:precompile's
# javascript:build hook. PUPPETEER_CACHE_DIR (set above) is where puppeteer's
# postinstall downloads Chromium so Grover finds it at runtime (ADR-014).
RUN corepack prepare --activate && yarn install --immutable

# Precompile bootsnap code for faster boot times.
# -j 1 disable parallel compilation to avoid a QEMU bug: https://github.com/rails/bootsnap/issues/495
RUN bundle exec bootsnap precompile -j 1 app/ lib/

# Precompiling assets for production without requiring secret RAILS_MASTER_KEY.
# jsbundling-rails runs `yarn build` here, emitting app/assets/builds/viewer.js.
RUN SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile




# Final stage for app image
FROM base

# Puppeteer's managed Chromium lives here (copied from the build stage); Grover
# resolves the browser from PUPPETEER_CACHE_DIR (ADR-014).
ENV PUPPETEER_CACHE_DIR="/usr/local/puppeteer"

# Grover renders the report PDF by shelling out to `node` (which drives the
# Puppeteer-managed Chromium) at REQUEST time — so the runtime stage needs the
# Node executable + npm modules, not just the Chromium cache. The build stage
# had Node (for assets:precompile / yarn build) but the final stage is a fresh
# FROM base; without copying Node here, production PDF downloads fail with
# "No such file or directory - node" even though the image built clean (ADR-014).
# These COPY/ln steps write into root-owned /usr/local, so they MUST run before
# the USER switch below — a non-root user cannot symlink into /usr/local/bin.
COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm

# Run and own only the runtime files as a non-root user for security. Done AFTER
# the root-owned /usr/local writes above so they don't hit EPERM.
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash
USER 1000:1000

# Copy built artifacts: gems, application, the Node puppeteer module + its
# Chromium download.
COPY --chown=rails:rails --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --chown=rails:rails --from=build /usr/local/puppeteer /usr/local/puppeteer
COPY --chown=rails:rails --from=build /rails /rails

# Entrypoint prepares the database.
ENTRYPOINT ["/rails/bin/docker-entrypoint"]

# Start server via Thruster by default, this can be overwritten at runtime
EXPOSE 80
CMD ["./bin/thrust", "./bin/rails", "server"]

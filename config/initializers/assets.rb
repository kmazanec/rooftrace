# Be sure to restart your server when you modify this file.

# Version of your assets, change this if you want to expire all your assets.
Rails.application.config.assets.version = "1.0"

# Add additional assets to the asset load path.
# Rails.application.config.assets.paths << Emoji.images_path

# jsbundling-rails adds app/javascript to the Propshaft load path so the React
# island's TypeScript SOURCE would otherwise be indexed and shipped. The browser
# only ever needs the compiled bundle in app/assets/builds, so keep the .ts/.tsx
# source out of the asset pipeline entirely.
Rails.application.config.assets.excluded_paths << Rails.root.join("app/javascript")

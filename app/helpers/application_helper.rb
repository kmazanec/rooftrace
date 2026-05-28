module ApplicationHelper
  # Whether a Propshaft asset with the given logical name is resolvable. Lets a
  # view defensively skip an esbuild-built bundle (app/assets/builds/*) that may
  # be absent in an environment where `yarn build` has not run yet, instead of
  # raising Propshaft::MissingAssetError on the page.
  def asset_available?(logical_name)
    Rails.application.assets.load_path.find(logical_name).present?
  rescue StandardError
    false
  end
end

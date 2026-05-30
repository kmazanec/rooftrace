# Single source of truth for the DigitalOcean Spaces (S3-compatible) client
# config. Every service that talks directly to Spaces delegates here so the
# five ENV keys and options live in one place.
#
# Usage (injectable test seam, lazy construction):
#
#   def client
#     @client ||= SpacesClient.build
#   end
#
# or (eager default parameter, as in SpacesHealth):
#
#   def initialize(client: SpacesClient.build, ...)
#
# Pass a pre-built client in tests: SpacesClient.build(client: stub_client)
# returns the stub unchanged, preserving each class's existing client: kwarg seam.
module SpacesClient
  def self.build(client: nil)
    client || Aws::S3::Client.new(
      access_key_id:     ENV.fetch("STORAGE_ACCESS_KEY"),
      secret_access_key: ENV.fetch("STORAGE_SECRET_KEY"),
      endpoint:          ENV.fetch("STORAGE_ENDPOINT"),
      region:            ENV.fetch("STORAGE_REGION", "us-east-1"),
      force_path_style:  false
    )
  end
end

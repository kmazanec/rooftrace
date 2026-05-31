require "aws-sdk-s3"

# Shared signing core for ArtifactUrlMinter and ImageryUrlMinter.
#
# Each minter is a separate public class with its own Error constant and its own
# ALLOWED_KEY_PREFIX / DEFAULT_EXPIRES_IN. This module provides the identical
# presigning implementation so that shared logic lives in one place while the
# public API of each class — the class name, .call signature, and ::Error
# constant — is fully preserved for existing callers and specs.
#
# Usage: `extend SpacesMinter` in a class that defines ALLOWED_KEY_PREFIX,
# DEFAULT_EXPIRES_IN, and a local Error constant. The class-level `.call` and
# the instance-level `#call` / private helpers are mixed in.
module SpacesMinter
  def self.extended(base)
    base.instance_eval do
      def call(object_key:, expires_in: self::DEFAULT_EXPIRES_IN)
        new.call(object_key: object_key, expires_in: expires_in)
      end
    end
    base.include(InstanceMethods)
  end

  module InstanceMethods
    def initialize(client: nil, bucket: nil)
      @client = client
      @bucket = bucket || SpacesClient::BUCKET
    end

    def call(object_key:, expires_in: self.class::DEFAULT_EXPIRES_IN)
      raise self.class::Error, "object_key is blank" if object_key.to_s.strip.empty?

      prefix = self.class::ALLOWED_KEY_PREFIX
      unless object_key.start_with?(prefix)
        raise self.class::Error,
              "object_key must be under the #{prefix} prefix, got: #{object_key.inspect}"
      end

      presigner.presigned_url(
        :get_object,
        bucket: @bucket,
        key: object_key,
        expires_in: expires_in.to_i
      )
    end

    private

    def presigner
      @presigner ||= Aws::S3::Presigner.new(client: client)
    end

    def client
      @client ||= SpacesClient.build
    end
  end
end

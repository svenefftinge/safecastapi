# frozen_string_literal: true

module DeviceStory
  class Device < ApplicationRecord
    self.table_name = 'device_story_devices'

    validates :device_urn, presence: true, uniqueness: true
    validates :metadata, presence: true

    before_save :update_from_metadata

    private

    def update_from_metadata
      self.device_id = metadata['device']
      points = metadata.values_at('last_lon', 'last_lat')
      self.last_location = "POINT(#{points.join(' ')})" if points.all?(&:present?)
      self.last_values = metadata['last_values']
    end
  end
end

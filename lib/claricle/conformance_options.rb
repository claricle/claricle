# frozen_string_literal: true

module Claricle
  # Validates and normalizes the profile/level pair shared by the module
  # API and Image. A format is optional because batch calls reject global
  # typos before opening files, then Image checks each concrete pairing.
  module ConformanceOptions
    module_function

    def normalize(profile, level, format: nil)
      profile = profile_name(profile)
      raise InvocationError, "level requires a profile" if profile.nil? && !level.nil?

      check_format(profile, format) if profile && format
      [profile, level_name(profile, level)]
    end

    def profile_name(profile)
      return if profile.nil?

      wanted = profile.to_sym
      return wanted if Registry.profiles.include?(wanted)

      raise InvocationError, "no format defines a profile named #{profile.inspect}"
    end

    def check_format(profile, format)
      accepted = Registry.profiles_for(format)
      raise UnsupportedProfile.new(format, profile, accepted) unless accepted.include?(profile)
    end

    def level_name(profile, level)
      return if level.nil?

      accepted = Registry.levels_for_profile(profile)
      raise InvocationError, "profile #{profile} does not take a level" unless accepted

      normalized = level.to_s.downcase.to_sym
      return normalized if accepted.include?(normalized)

      raise InvocationError,
            "profile #{profile} does not define level #{level.inspect}; choose #{accepted.join(", ")}"
    end

    private_class_method :profile_name, :check_format, :level_name
  end

  private_constant :ConformanceOptions
end

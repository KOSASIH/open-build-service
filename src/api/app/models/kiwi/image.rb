module Kiwi
  class Image < ApplicationRecord
    #### Includes and extends

    #### Constants
    DEFAULT_KIWI_BODY = '<?xml version="1.0" encoding="utf-8"?>
  <image schemaversion="6.2" name="suse-13.2-live">
    <description type="system">
    </description>
    <preferences>
      <type image="oem" primary="true" boot="oemboot/suse-13.2"/>
    </preferences>
  </image>
  '.freeze

    #### Self config
    #### Attributes

    #### Associations macros (Belongs to, Has one, Has many)
    has_one :package, foreign_key: 'kiwi_image_id', class_name: '::Package', dependent: :nullify, inverse_of: :kiwi_image
    has_one :description, inverse_of: :image, dependent: :destroy
    has_one :preference_type, inverse_of: :image, dependent: :destroy
    has_many :repositories, -> { order(order: :asc) }, dependent: :destroy, index_errors: true
    has_many :package_groups, -> { order(:id) }, dependent: :destroy, index_errors: true
    has_many :kiwi_packages, -> { where(kiwi_package_groups: { kiwi_type: Kiwi::PackageGroup.kiwi_types[:image] }) },
             through: :package_groups, source: :packages, inverse_of: :kiwi_image

    #### Callbacks macros: before_save, after_save, etc.

    #### Scopes (first the default_scope macro if is used)

    #### Validations macros
    validates :name, presence: true
    validate :check_use_project_repositories
    validate :check_package_groups
    validates :preference_type, presence: true
    accepts_nested_attributes_for :preference_type, reject_if: proc { |attributes|
      attributes['containerconfig_name'].blank? && attributes['containerconfig_tag'].blank?
    }
    accepts_nested_attributes_for :description
    accepts_nested_attributes_for :repositories, allow_destroy: true
    accepts_nested_attributes_for :package_groups, allow_destroy: true
    accepts_nested_attributes_for :kiwi_packages, allow_destroy: true

    #### Class methods using self. (public and then private)

    #### To define class methods as private use private_class_method
    #### private

    #### Instance methods (public and then protected/private)

    #### Alias of methods
    def self.build_from_xml(xml_string, md5)
      Kiwi::Image::XmlParser.new(xml_string, md5).parse
    end

    def to_xml
      Kiwi::Image::XmlBuilder.new(self).build
    end

    def write_to_backend
      return false unless package

      Package.transaction do
        file_name = package.kiwi_image_file || "#{package.name}.kiwi"
        package.save_file({ filename: file_name, file: to_xml })
        self.md5_last_revision = package.kiwi_file_md5
        save!
      end
    end

    def outdated?
      return false unless package

      package.kiwi_image_outdated?
    end

    def default_package_group
      package_groups.type_image.first || package_groups.create(kiwi_type: :image, pattern_type: 'onlyRequired')
    end

    def self.find_binaries_by_name(query, project, repositories, options = {})
      finder = /\A#{Regexp.quote(query)}/
      binaries_available(project, options[:use_project_repositories], repositories).select { |package, _| finder.match(package.to_s) }
    end

    def self.binaries_available(project, use_project_repositories, repositories)
      Rails.cache.fetch("kiwi_image_binaries_available_#{project}_#{use_project_repositories}_#{repositories}", expires_in: 5.minutes) do
        if use_project_repositories
          Backend::Api::BuildResults::Binaries.available_in_project(project)
        else
          return [] if repositories.blank?
          obs_repository_paths = repositories.select { |url| url.starts_with?("obs://")}.map {|url| url[6..-1] }
          non_obs_repository_urls = repositories.reject { |url| url.starts_with?("obs://")}
          Backend::Api::BuildResults::Binaries.available_in_repositories(project, non_obs_repository_urls, obs_repository_paths)
        end
      end
    end

    # This method is for parse the error messages and group them to make them more understandable.
    # The nested errors messages are like `Model[0] attributes` and this is not easy to understand.
    def parsed_errors(title, packages)
      message = { title: title }
      message["Image Errors:"] = errors.messages[:base] if errors.messages[:base].present?

      { repository: repositories, package: packages }.each do |key, records|
        records.each do |record|
          if record.errors.present?
            message["#{key.capitalize}: #{record.name}"] ||= []
            message["#{key.capitalize}: #{record.name}"] << record.errors.messages.values
            message["#{key.capitalize}: #{record.name}"].flatten!
          end
        end
      end

      message
    end

    def kiwi_body
      if package
        kiwi_file = package.kiwi_image_file
        return nil unless kiwi_file
        package.source_file(kiwi_file)
      else
        Kiwi::Image::DEFAULT_KIWI_BODY
      end
    end

    private

    def check_use_project_repositories
      return unless use_project_repositories? && repositories.present?

      errors.add(:base,
                 "A repository with source_path \"obsrepositories:/\" has been set. If you want to use it, please remove the other repositories.")
    end

    def check_package_groups
      return if package_groups.group_by(&:kiwi_type).select { |_key, value| value.count > 1 }.keys.empty?

      errors.add(:base, "Multiple package groups with same type are not allowed.")
    end
  end
end

# == Schema Information
#
# Table name: kiwi_images
#
#  id                       :integer          not null, primary key
#  name                     :string(255)
#  md5_last_revision        :string(32)
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#  use_project_repositories :boolean          default(FALSE)
#

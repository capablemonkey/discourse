class ThemeField < ActiveRecord::Base

  COMPILER_VERSION = 5

  belongs_to :theme

  def transpile(es6_source, version)
    template  = Tilt::ES6ModuleTranspilerTemplate.new {}
    wrapped = <<PLUGIN_API_JS
Discourse._registerPluginCode('#{version}', api => {
  #{es6_source}
});
PLUGIN_API_JS

    template.babel_transpile(wrapped)
  end

  def process_html(html)
    errors = nil

    doc = Nokogiri::HTML.fragment(html)
    doc.css('script[type="text/x-handlebars"]').each do |node|
      name = node["name"] || node["data-template-name"] || "broken"
      is_raw = name =~ /\.raw$/
      if is_raw
        template = "require('discourse-common/lib/raw-handlebars').template(#{Barber::Precompiler.compile(node.inner_html)})"
        node.replace <<COMPILED
          <script>
            (function() {
              Discourse.RAW_TEMPLATES[#{name.sub(/\.raw$/, '').inspect}] = #{template};
            })();
          </script>
COMPILED
      else
        template = "Ember.HTMLBars.template(#{Barber::Ember::Precompiler.compile(node.inner_html)})"
        node.replace <<COMPILED
          <script>
            (function() {
              Ember.TEMPLATES[#{name.inspect}] = #{template};
            })();
          </script>
COMPILED
      end

    end

    doc.css('script[type="text/discourse-plugin"]').each do |node|
      if node['version'].present?
        begin
          code = transpile(node.inner_html, node['version'])
          node.replace("<script>#{code}</script>")
        rescue MiniRacer::RuntimeError => ex
          node.replace("<script type='text/discourse-js-error'>#{ex.message}</script>")
          errors ||= []
          errors << ex.message
        end
      end
    end

    [doc.to_s, errors&.join("\n")]
  end


  def self.html_fields
    %w(body_tag head_tag header footer after_header)
  end

  def self.scss_fields
    %w(scss embedded_scss)
  end


  def ensure_baked!
    if ThemeField.html_fields.include?(self.name)
      if !self.value_baked || compiler_version != COMPILER_VERSION

        self.value_baked, self.error = process_html(self.value)
        self.compiler_version = COMPILER_VERSION

        if self.value_baked_changed? || compiler_version.changed? || self.error_changed?
          self.update_columns(value_baked: value_baked,
                              compiler_version: compiler_version,
                              error: error)
        end
      end
    end
  end

  def ensure_scss_compiles!
    if ThemeField.scss_fields.include?(self.name)
      begin
        Stylesheet::Compiler.compile("@import \"theme_variables\"; @import \"theme_field\";",
                                     "theme.scss",
                                     theme_field: self.value.dup)
        self.error = nil unless error.nil?
      rescue SassC::SyntaxError => e
        self.error = e.message
      end

      if error_changed?
        update_columns(error: self.error)
      end

    end
  end

  def target_name
    Theme.targets.invert[target].to_s
  end

  before_save do
    if value_changed? && !value_baked_changed?
      self.value_baked = nil
    end
  end

  after_commit do
    ensure_baked!
    ensure_scss_compiles!

    Stylesheet::Manager.clear_theme_cache! if self.name.include?("scss")

    # TODO message for mobile vs desktop
    MessageBus.publish "/header-change/#{theme.key}", self.value if theme && self.name == "header"
    MessageBus.publish "/footer-change/#{theme.key}", self.value if theme && self.name == "footer"
  end
end

# == Schema Information
#
# Table name: theme_fields
#
#  id               :integer          not null, primary key
#  theme_id         :integer          not null
#  target           :integer          not null
#  name             :string           not null
#  value            :text             not null
#  value_baked      :text
#  created_at       :datetime
#  updated_at       :datetime
#  compiler_version :integer          default(0), not null
#  error            :string
#
# Indexes
#
#  index_theme_fields_on_theme_id_and_target_and_name  (theme_id,target,name) UNIQUE
#

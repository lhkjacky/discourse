# frozen_string_literal: true

require 'yaml'

#
# 2 different formats are accepted:
#
# == JSON format
#
# bin/rake themes:install -- '--{"discourse-something": "https://github.com/discourse/discourse-something"}'
# OR
# bin/rake themes:install -- '--{"discourse-something": {"url": "https://github.com/discourse/discourse-something", default: true}}'
#
# == YAML file formats
#
# theme_name: https://github.com/example/theme.git
# OR
# theme_name:
#   url: https://github.com/example/theme_name.git
#   branch: "master"
#   private_key: ""
#   default: false
#   add_to_all_themes: false  # only for components - install on every theme
#
# In the first form, only the url is required.
#
desc "Install themes & theme components"
task "themes:install" => :environment do |task, args|
  theme_args = (STDIN.tty?) ? '' : STDIN.read
  use_json = theme_args == ''

  theme_args = begin
                 use_json ? JSON.parse(ARGV.last.gsub('--', '')) : YAML::safe_load(theme_args)
               rescue
                 puts use_json ? "Invalid JSON input. \n#{ARGV.last}" : "Invalid YML: \n#{theme_args}"
                 exit 1
               end

  log, counts = ThemesInstallTask.install(theme_args)

  puts log

  puts
  puts "Results:"
  puts " Installed: #{counts[:installed]}"
  puts " Updated:   #{counts[:updated]}"
  puts " Errors:    #{counts[:errors]}"
  puts " Skipped:   #{counts[:skipped]}"

  if counts[:errors] > 0
    exit 1
  end
end

def update_themes
  Theme.where(auto_update: true, enabled: true).find_each do |theme|
    begin
      if theme.remote_theme.present?
        puts "Updating '#{theme.name}' for '#{RailsMultisite::ConnectionManagement.current_db}'..."
        theme.remote_theme.update_from_remote
        theme.save!
        unless theme.remote_theme.last_error_text.nil?
          puts "Error updating '#{theme.name}': #{theme.remote_theme.last_error_text}"
          exit 1
        end
      end
    rescue => e
      STDERR.puts "Failed to update '#{theme.name}'"
      STDERR.puts e
      STDERR.puts e.backtrace
      exit 1
    end
  end
end

desc "Update themes & theme components"
task "themes:update" => :environment do
  if ENV['RAILS_DB'].present?
    update_themes
  else
    RailsMultisite::ConnectionManagement.each_connection do
      update_themes
    end
  end
end

desc "List all the installed themes on the site"
task "themes:audit" => :environment do
  components = Set.new
  puts "Selectable themes"
  puts "-----------------"

  Theme.where("(enabled OR user_selectable) AND NOT component").each do |theme|
    puts theme.remote_theme&.remote_url || theme.name
    theme.child_themes.each do |child|
      if child.enabled
        repo = child.remote_theme&.remote_url || child.name
        components << repo
      end
    end
  end

  puts
  puts "Selectable components"
  puts "---------------------"
  components.each do |repo|
    puts repo
  end
end

desc "Run QUnit tests of a theme/component"
task "themes:qunit", :type, :value do |t, args|
  type = args[:type]
  value = args[:value]
  if !%w(name url id).include?(type) || value.blank?
    raise <<~MSG
      Wrong arguments type:#{type.inspect}, value:#{value.inspect}"
      Usage:
        `bundle exec rake "themes:qunit[url,<theme_url>]"`
        OR
        `bundle exec rake "themes:qunit[name,<theme_name>]"`
        OR
        `bundle exec rake "themes:qunit[id,<theme_id>]"`
    MSG
  end
  ENV["THEME_#{type.upcase}"] = value.to_s
  ENV["QUNIT_RAILS_ENV"] ||= 'development' # qunit:test will switch to `test` by default
  Rake::Task["qunit:test"].reenable
  Rake::Task["qunit:test"].invoke(1200000, "/theme-qunit")
end

desc "Install a theme/component on a temporary DB and run QUnit tests"
task "themes:isolated_test" => :environment do |t, args|
  # This task can be called in a production environment that likely has a bunch
  # of DISCOURSE_* env vars that we don't want to be picked up by the Unicorn
  # server that will be spawned for the tests. So we need to unset them all
  # before we proceed.
  # Make this behavior opt-in to make it very obvious.
  if ENV["UNSET_DISCOURSE_ENV_VARS"] == "1"
    ENV.keys.each do |key|
      next if !key.start_with?('DISCOURSE_')
      next if ENV["DONT_UNSET_#{key}"] == "1"
      ENV[key] = nil
    end
  end

  redis = TemporaryRedis.new
  redis.start
  $redis = redis.instance # rubocop:disable Style/GlobalVars
  db = TemporaryDb.new
  db.start
  db.migrate
  ActiveRecord::Base.establish_connection(
    adapter: 'postgresql',
    database: 'discourse',
    port: db.pg_port,
    host: 'localhost'
  )

  seeded_themes = Theme.pluck(:id)
  Rake::Task["themes:install"].invoke
  themes = Theme.pluck(:name, :id)

  ENV["PGPORT"] = db.pg_port.to_s
  ENV["PGHOST"] = "localhost"
  ENV["QUNIT_RAILS_ENV"] = "development"
  ENV["DISCOURSE_DEV_DB"] = "discourse"
  ENV["DISCOURSE_REDIS_PORT"] = redis.port.to_s

  count = 0
  themes.each do |(name, id)|
    if seeded_themes.include?(id)
      puts "Skipping seeded theme #{name} (id: #{id})"
      next
    end
    puts "Running tests for theme #{name} (id: #{id})..."
    Rake::Task["themes:qunit"].reenable
    Rake::Task["themes:qunit"].invoke("id", id)
    count += 1
  end
  raise "Error: No themes were installed" if count == 0
ensure
  db&.stop
  db&.remove
  redis&.remove
end

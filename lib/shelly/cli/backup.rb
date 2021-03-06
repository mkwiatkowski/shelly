require "shelly/cli/command"
require "shelly/backup"
require "shelly/download_progress_bar"

module Shelly
  module CLI
    class Backup < Command
      namespace :backup
      include Helpers

      before_hook :logged_in?, :only => [:list, :get, :create, :restore]

      class_option :cloud, :type => :string, :aliases => "-c", :desc => "Specify cloud"

      method_option :all, :type => :boolean, :aliases => "-a",
        :desc => "Show all backups"
      desc "list", "List available database backups"
      def list
        app = multiple_clouds(options[:cloud], "backup list")
        backups = app.database_backups
        if backups.present?
          limit = -1
          unless options[:all] || backups.count < (Shelly::Backup::LIMIT + 1)
            limit = Shelly::Backup::LIMIT - 1
            say "Limiting the number of backups to #{Shelly::Backup::LIMIT}."
            say "Use --all or -a option to list all backups."
          end
          to_display = [["Filename", "|  Size", "|  State"]]
          backups[0..limit].each do |backup|
            to_display << [backup.filename, "|  #{backup.human_size}", "|  #{backup.state.humanize}"]
          end

          say "Available backups:", :green
          say_new_line
          print_table(to_display, :ident => 2)
        else
          say "No database backups available"
        end
      end

      desc "get [FILENAME]", "Download database backup"
      long_desc %{
        Download given database backup to current directory.
        If filename is not specyfied, latest database backup will be downloaded.
      }
      def get(handler = "last")
        app = multiple_clouds(options[:cloud], "backup get #{handler}")

        backup = app.database_backup(handler)
        bar = Shelly::DownloadProgressBar.new(backup.size)
        backup.download(bar.progress_callback)

        say_new_line
        say "Backup file saved to #{backup.filename}", :green
      rescue Client::NotFoundException => e
        raise unless e.resource == :database_backup
        say_error "Backup not found", :with_exit => false
        say "You can list available backups with `shelly backup list` command"
      end

      desc "create [DB_KIND]", "Create backup of given database"
      long_desc %{
        Create backup of given database.
        If database kind is not specified, Cloudfile must be present to backup all configured databases.
      }
      def create(kind = nil)
        app = multiple_clouds(options[:cloud], "backup create [DB_KIND]")
        cloudfile = Cloudfile.new
        unless kind || cloudfile.present?
          say_error "Cloudfile must be present in current working directory or specify database kind with:", :with_exit => false
          say_error "`shelly backup create DB_KIND`"
        end
        app.request_backup(kind || cloudfile.backup_databases(app))
        say "Backup requested. It can take up to several minutes for " +
          "the backup process to finish.", :green
      rescue Client::ValidationException => e
        e.each_error { |error| say_error error, :with_exit => false }
        exit 1
      rescue Client::ConflictException => e
        say_error e[:message]
      end

      desc "restore FILENAME", "Restore database to state from given backup"
      def restore(filename)
        app = multiple_clouds(options[:cloud], "backup restore FILENAME")
        backup = app.database_backup(filename)
        say "You are about restore database #{backup.kind} for cloud #{backup.code_name} to state from #{backup.filename}"
        say_new_line
        ask_to_restore_database
        app.restore_backup(filename)
        say_new_line
        say "Restore has been scheduled. Wait a few minutes till database is restored.", :green
      rescue Client::NotFoundException => e
        raise unless e.resource == :database_backup
        say_error "Backup not found", :with_exit => false
        say "You can list available backups with `shelly backup list` command"
      rescue Client::ConflictException => e
        say_error e[:message]
      end
    end
  end
end

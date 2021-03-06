# encoding: utf-8
require "shelly/cli/command"
require "shelly/cli/user"
require "shelly/cli/backup"
require "shelly/cli/deploys"
require "shelly/cli/config"
require "shelly/cli/files"

module Shelly
  module CLI
    class Main < Command
      include Thor::Actions

      register(User, "user", "user <command>", "Manage collaborators")
      register(Backup, "backup", "backup <command>", "Manage database backups")
      register(Deploys, "deploys", "deploys <command>", "View deploy logs")
      register(Config, "config", "config <command>", "Manage application configuration files")
      register(Files, "files", "files <command>", "Upload and download files to and from persistent storage")

      check_unknown_options!(:except => :rake)

      # FIXME: it should be possible to pass single symbol, instead of one element array
      before_hook :logged_in?, :only => [:add, :status, :list, :start, :stop, :logs, :delete, :info, :ip, :logout, :execute, :rake, :setup, :console, :dbconsole]
      before_hook :inside_git_repository?, :only => [:add, :setup, :check]

      map %w(-v --version) => :version
      desc "version", "Display shelly version"
      def version
        say "shelly version #{Shelly::VERSION}"
      end

      desc "register [EMAIL]", "Register new account"
      def register(email = nil)
        user = Shelly::User.new
        say "Registering with email: #{email}" if email
        user.email = (email || ask_for_email)
        user.password = ask_for_password
        ask_for_acceptance_of_terms
        user.register
        if user.ssh_key_exists?
          say "Uploading your public SSH key from #{user.ssh_key_path}"
        else
          say_error "No such file or directory - #{user.ssh_key_path}", :with_exit => false
          say_error "Use ssh-keygen to generate ssh key pair, after that use: `shelly login`", :with_exit => false
        end
        say "Successfully registered!", :green
        say "Check you mailbox for email address confirmation", :green
      rescue Client::ValidationException => e
        e.each_error { |error| say_error "#{error}", :with_exit => false }
        exit 1
      end

      desc "login [EMAIL]", "Log into Shelly Cloud"
      def login(email = nil)
        user = Shelly::User.new
        raise Errno::ENOENT, user.ssh_key_path unless user.ssh_key_exists?
        user.email = email || ask_for_email
        user.password = ask_for_password(:with_confirmation => false)
        user.login
        say "Login successful", :green
        user.upload_ssh_key
        say "Uploading your public SSH key"
        list
      rescue Client::ValidationException => e
        e.each_error { |error| say_error "#{error}", :with_exit => false }
      rescue Client::UnauthorizedException => e
        say_error "Wrong email or password", :with_exit => false
        say_error "You can reset password by using link:", :with_exit => false
        say_error e[:url]
      rescue Errno::ENOENT => e
        say_error e, :with_exit => false
        say_error "Use ssh-keygen to generate ssh key pair"
      end

      method_option "code-name", :type => :string, :aliases => "-c",
        :desc => "Unique code-name of your cloud"
      method_option :databases, :type => :array, :aliases => "-d",
        :banner => Shelly::App::DATABASE_CHOICES.join(', '),
        :desc => "List of databases of your choice"
      method_option :size, :type => :string, :aliases => "-s",
        :desc => "Server size [large, small]"
      method_option "redeem-code", :type => :string, :aliases => "-r",
        :desc => "Redeem code for free credits"
      desc "add", "Add a new cloud"
      def add
        check_options(options)
        return unless check(verbose = false)
        app = Shelly::App.new
        app.code_name = options["code-name"] || ask_for_code_name
        app.databases = options["databases"] || ask_for_databases
        app.size = options["size"] || "large"
        app.redeem_code = options["redeem-code"]
        app.create

        if overwrite_remote?(app)
          say "Adding remote #{app} #{app.git_url}", :green
          app.add_git_remote
        else
          say "You have to manually add git remote:"
          say "`git remote add NAME #{app.git_url}`"
        end

        say "Creating Cloudfile", :green
        app.create_cloudfile
        if app.trial?
          say_new_line
          say "Billing information", :green
          say "Cloud created with #{app.credit} Euro credit."
          say "Remember to provide billing details before trial ends."
          say app.edit_billing_url
        end

        info_adding_cloudfile_to_repository
        info_deploying_to_shellycloud(app)

      rescue Client::ValidationException => e
        e.each_error { |error| say_error error, :with_exit => false }
        say_new_line
        say_error "Fix erros in the below command and type it again to create your cloud" , :with_exit => false
        say_error "shelly add --code-name=#{app.code_name.downcase.dasherize} --databases=#{app.databases.join(',')} --size=#{app.size}"
      end

      map "status" => :list
      desc "list", "List available clouds"
      def list
        user = Shelly::User.new
        apps = user.apps
        unless apps.empty?
          say "You have following clouds available:", :green
          apps_table = apps.map do |app|
            state = app["state"]
            msg = if state == "deploy_failed" || state == "configuration_failed"
              " (deployment log: `shelly deploys show last -c #{app["code_name"]}`)"
            end
            [app["code_name"], "|  #{state.humanize}#{msg}"]
          end
          print_table(apps_table, :ident => 2)
        else
          say "You have no clouds yet", :green
        end
      end

      map "ip" => :info
      method_option :cloud, :type => :string, :aliases => "-c", :desc => "Specify cloud"
      desc "info", "Show basic information about cloud"
      def info
        app = multiple_clouds(options[:cloud], "info")
        msg = if app.state == "deploy_failed" || app.state == "configuration_failed"
          " (deployment log: `shelly deploys show last -c #{app}`)"
        end
        say "Cloud #{app}:", msg.present? ? :red : :green
        print_wrapped "State: #{app.state}#{msg}", :ident => 2
        say_new_line
        print_wrapped "Deployed commit sha: #{app.git_info["deployed_commit_sha"]}", :ident => 2
        print_wrapped "Deployed commit message: #{app.git_info["deployed_commit_message"]}", :ident => 2
        print_wrapped "Deployed by: #{app.git_info["deployed_push_author"]}", :ident => 2
        say_new_line
        print_wrapped "Repository URL: #{app.git_info["repository_url"]}", :ident => 2
        print_wrapped "Web server IP: #{app.web_server_ip}", :ident => 2
        say_new_line
        if app.statistics.present?
          print_wrapped "Statistics:", :ident => 2
          app.statistics.each do |stat|
            print_wrapped "#{stat['name']}:", :ident => 4
            print_wrapped "Load average: 1m: #{stat['load']['avg01']}, 5m: #{stat['load']['avg05']}, 15m: #{stat['load']['avg15']}", :ident => 6
            print_wrapped "CPU: #{stat['cpu']['wait']}%, MEM: #{stat['memory']['percent']}%, SWAP: #{stat['swap']['percent']}%", :ident => 6
          end
        end
      rescue Client::GatewayTimeoutException
        say_error "Server statistics temporarily unavailable"
      end

      desc "start", "Start the cloud"
      method_option :cloud, :type => :string, :aliases => "-c", :desc => "Specify cloud"
      def start
        app = multiple_clouds(options[:cloud], "start")
        app.start
        say "Starting cloud #{app}.", :green
        say "This can take up to 10 minutes."
        say "Check status with: `shelly list`"
      rescue Client::ConflictException => e
        case e[:state]
        when "running"
          say_error "Not starting: cloud '#{app}' is already running"
        when "deploying", "configuring"
          say_error "Not starting: cloud '#{app}' is currently deploying"
        when "no_code"
          say_error "Not starting: no source code provided", :with_exit => false
          say_error "Push source code using:", :with_exit => false
          say       "`git push #{app} master`"
        when "deploy_failed", "configuration_failed"
          say_error "Not starting: deployment failed", :with_exit => false
          say_error "Support has been notified", :with_exit => false
          say_error "Check `shelly deploys show last --cloud #{app}` for reasons of failure"
        when "not_enough_resources"
          say_error %{Sorry, There are no resources for your servers.
We have been notified about it. We will be adding new resources shortly}
        when "no_billing"
          say_error "Please fill in billing details to start #{app}.", :with_exit => false
          say_error "Visit: #{app.edit_billing_url}", :with_exit => false
        when "payment_declined"
          say_error "Not starting. Invoice for cloud '#{app}' was declined."
        end
        exit 1
      end

      desc "setup", "Set up git remotes for deployment on Shelly Cloud"
      long_desc %{
        Set up git remotes for deployment on Shelly Cloud.

        When an application is cloned from a git repository (for example from Github)
        shelly setup will set up git remotes needed for deployment on Shelly Cloud.

        Application must have Cloudfile in the repository.
      }
      method_option :cloud, :type => :string, :aliases => "-c", :desc => "Specify cloud"
      def setup
        app = multiple_clouds(options[:cloud], "setup")
        say "Setting up #{app} cloud", :green
        app.git_url = app.attributes["git_info"]["repository_url"]
        if overwrite_remote?(app)
          say "git remote add #{app} #{app.git_url}"
          app.add_git_remote
          say "git fetch #{app}"
          app.git_fetch_remote
          say "git checkout -b #{app} --track #{app}/master"
          app.git_add_tracking_branch
        else
          say "You have to manually add remote:"
          say "`git remote add #{app} #{app.git_url}`"
          say "`git fetch production`"
          say "`git checkout -b #{app} --track #{app}/master`"
        end

        say_new_line
        say "Your application is set up.", :green
      end

      desc "stop", "Shutdown the cloud"
      method_option :cloud, :type => :string, :aliases => "-c", :desc => "Specify cloud"
      def stop
        app = multiple_clouds(options[:cloud], "stop")
        ask_to_stop_application
        app.stop
        say_new_line
        say "Cloud '#{app}' stopped"
      rescue Client::NotFoundException => e
        raise unless e.resource == :cloud
        say_error "You have no access to '#{app}' cloud defined in Cloudfile"
      end

      desc "delete", "Delete the cloud"
      method_option :cloud, :type => :string, :aliases => "-c", :desc => "Specify cloud"
      def delete
        app = multiple_clouds(options[:cloud], "delete")
        say "You are about to delete application: #{app}."
        say "Press Control-C at any moment to cancel."
        say "Please confirm each question by typing yes and pressing Enter."
        say_new_line
        ask_to_delete_files
        ask_to_delete_database
        ask_to_delete_application
        app.delete
        say_new_line
        say "Scheduling application delete - done"
        if App.inside_git_repository?
          app.remove_git_remote
          say "Removing git remote - done"
        else
          say "Missing git remote"
        end
      end

      desc "logs", "Show latest application logs"
      method_option :cloud, :type => :string, :aliases => "-c", :desc => "Specify cloud"
      method_option :limit, :type => :numeric, :aliases => "-n", :desc => "Amount of messages to show"
      method_option :from, :type => :string, :desc => "Time from which to find the logs"
      method_option :source, :type => :string, :aliases => "-s", :desc => "Limit logs to a single source, e.g. nginx"
      method_option :tail, :type => :boolean, :aliases => "-f", :desc => "Show new logs automatically"
      def logs
        cloud = options[:cloud]
        app = multiple_clouds(cloud, "logs")
        limit = options[:limit].to_i <= 0 ? 100 : options[:limit]
        query = {:limit => limit, :source => options[:source]}
        query.merge!(:from => options[:from]) if options[:from]

        logs = app.application_logs(query)
        print_logs(logs)

        if options[:tail]
          loop do
            logs = app.application_logs(:from => logs['range']['last'],
              :source => options[:source])
            print_logs(logs)
            sleep 0.5
          end
        end
      rescue Client::APIException => e
        raise e unless e.status_code == 416
        say_error "You have requested too many log messages. Try a lower number."
      end

      desc "logout", "Logout from Shelly Cloud"
      def logout
        user = Shelly::User.new
        say "Your public SSH key has been removed from Shelly Cloud" if user.delete_ssh_key
        say "You have been successfully logged out" if user.delete_credentials
      end

      desc "rake TASK", "Run rake task"
      method_option :cloud, :type => :string, :aliases => "-c", :desc => "Specify cloud"
      def rake(task = nil)
        task = rake_args.join(" ")
        app = multiple_clouds(options[:cloud], "rake #{task}")
        app.rake(task)
      rescue Client::ConflictException
        say_error "Cloud #{app} is not running. Cannot run rake task."
      end

      desc "dbconsole", "Run rails dbconsole"
      method_option :cloud, :type => :string, :aliases => "-c", :desc => "Specify cloud"
      def dbconsole(task = nil)
        app = multiple_clouds(options[:cloud], "dbconsole")
        app.dbconsole
      rescue Client::ConflictException
        say_error "Cloud #{app} is not running. Cannot run dbconsole."
      end

      desc "redeploy", "Redeploy application"
      method_option :cloud, :type => :string, :aliases => "-c",
        :desc => "Specify which cloud to redeploy application for"
      def redeploy
        app = multiple_clouds(options[:cloud], "redeploy")
        app.redeploy
        say "Redeploying your application for cloud '#{app}'", :green
      rescue Client::ConflictException => e
        case e[:state]
        when "deploying", "configuring"
          say_error "Your application is being redeployed at the moment"
        when "no_code", "no_billing", "turned_off"
          say_error "Cloud #{app} is not running", :with_exit => false
          say "Start your cloud with `shelly start --cloud #{app}`"
          exit 1
        else raise
        end
      end

      desc "open", "Open application page in browser"
      method_option :cloud, :type => :string, :aliases => "-c", :desc => "Specify cloud"
      def open
        app = multiple_clouds(options[:cloud], "open")
        app.open
      end

      desc "console", "Open application console"
      method_option :cloud, :type => :string, :aliases => "-c", :desc => "Specify cloud"
      def console
        app = multiple_clouds(options[:cloud], "console")
        app.console
      rescue Client::ConflictException
        say_error "Cloud #{app} is not running. Cannot run console."
      end

      desc "check", "Check if application fulfills Shelly Cloud requirements"
      # Public: Check if application fulfills shelly's requirements
      #         and print them
      # verbose - when true all requirements will be printed out
      #           together with header and a summary at the end
      #           when false only not fulfilled requirements will be
      #           printed
      # When any requirements is not fulfilled header and summary will
      # be displayed regardless of verbose value
      def check(verbose = true)
        structure = Shelly::StructureValidator.new

        if verbose or structure.invalid? or structure.warnings?
          say "Checking Shelly Cloud requirements\n\n"
        end

        print_check(structure.gemfile?, "Gemfile is present",
          "Gemfile is missing in git repository",
          :show_fulfilled => verbose)

        print_check(structure.gemfile_lock?, "Gemfile.lock is present",
          "Gemfile.lock is missing in git repository",
          :show_fulfilled => verbose)

        print_check(structure.gem?("shelly-dependencies"),
          "Gem 'shelly-dependencies' is present",
          "Gem 'shelly-dependencies' is missing, we recommend to install it\n    See more at https://shellycloud.com/documentation/requirements#shelly-dependencies",
          :show_fulfilled => verbose || structure.warnings?, :failure_level => :warning)

        print_check(structure.gem?("thin"), "Gem 'thin' is present",
          "Gem 'thin' is missing in the Gemfile", :show_fulfilled => verbose)

        print_check(structure.gem?("rake"), "Gem 'rake' is present",
          "Gem 'rake' is missing in the Gemfile", :show_fulfilled => verbose)

        print_check(structure.config_ru?, "File config.ru is present",
          "File config.ru is missing",
          :show_fulfilled => verbose)

        print_check(!structure.gem?("mysql") && !structure.gem?("mysql2"),"",
          "mysql driver present in the Gemfile (not supported on Shelly Cloud)",
          :show_fulfilled => false)

        if structure.valid?
          if verbose
            say "\nGreat! Your application is ready to run on Shelly Cloud"
          end
        else
          say "\nFix points marked with #{red("✗")} to run your application on the Shelly Cloud"
          say "See more about requirements on https://shellycloud.com/documentation/requirements"
        end

        structure.valid?
      rescue Bundler::BundlerError => e
        say_new_line
        say_error e.message, :with_exit => false
        say_error "Try to run `bundle install`"
      end

      # FIXME: move to helpers
      no_tasks do
        # Returns valid arguments for rake, removes shelly gem arguments
        def rake_args(args = ARGV)
          skip_next = false
          [].tap do |out|
            args.each do |arg|
              case arg
              when "rake", "--debug"
              when "--cloud", "-c"
                skip_next = true
              else
                out << arg unless skip_next
                skip_next = false
              end
            end
          end
        end

        def check_options(options)
          unless options.empty?
            if !valid_size?(options["size"]) or !valid_databases?(options["databases"])
              say_error "Try `shelly help add` for more information"
            end
          end
        end

        def valid_size?(size)
          return true unless size.present?
          sizes = Shelly::App::SERVER_SIZES
          sizes.include?(size)
        end

        def valid_databases?(databases)
          return true unless databases.present?
          kinds = Shelly::App::DATABASE_CHOICES
          databases.all? { |kind| kinds.include?(kind) }
        end

        def overwrite_remote?(app)
          git_remote = app.git_remote_exist?
          !git_remote or (git_remote and yes?("Git remote #{app} exists, overwrite (yes/no): "))
        end

        def ask_for_password(options = {})
          options = {:with_confirmation => true}.merge(options)
          loop do
            say "Password: "
            password = echo_disabled { $stdin.gets.strip }
            say_new_line
            return password unless options[:with_confirmation]
            say "Password confirmation: "
            password_confirmation = echo_disabled { $stdin.gets.strip }
            say_new_line
            if password.present?
              return password if password == password_confirmation
              say_error "Password and password confirmation don't match, please type them again"
            else
              say_error "Password can't be blank"
            end
          end
        end

        def ask_for_code_name
          default_code_name = Shelly::App.guess_code_name
          code_name = ask("Cloud code name (#{Shelly::App.guess_code_name} - default):")
          code_name.blank? ? default_code_name : code_name
        end

        def ask_for_databases
          kinds = Shelly::App::DATABASE_CHOICES
          databases = ask("Which database do you want to use #{kinds.join(", ")} (postgresql - default):")
          begin
            databases = databases.split(/[\s,]/).reject(&:blank?)
            valid = valid_databases?(databases)
            break if valid
            databases = ask("Unknown database kind. Supported are: #{kinds.join(", ")}:")
          end while not valid

          databases.empty? ? ["postgresql"] : databases
        end

        def info_adding_cloudfile_to_repository
          say_new_line
          say "Project is now configured for use with Shell Cloud:", :green
          say "You can review changes using", :green
          say "  git status"
        end

        def info_deploying_to_shellycloud(remote)
          say_new_line
          say "When you make sure all settings are correct please issue following commands:", :green
          say "  git add ."
          say '  git commit -m "Application added to Shelly Cloud"'
          say "  git push"
          say_new_line
          say "Deploy to your cloud using:", :green
          say "  git push #{remote} master"
          say_new_line
        end
      end
    end
  end
end

module Shelly
  class User < Model
    attr_accessor :email, :password

    def initialize(email = nil, password = nil)
      @email = email
      @password = password
    end

    def apps
      shelly.apps
    end

    def register
      ssh_key = File.read(ssh_key_path) if ssh_key_exists?
      shelly.register_user(email, password, ssh_key)
      save_credentials
    end

    def login
      client = Client.new(email, password)
      # test if credentials are valid
      # if not RestClient::Unauthorized will be raised
      client.token
      save_credentials
    end

    def token
      shelly.token["token"]
    end

    def send_invitation(cloud, email)
      shelly.send_invitation(cloud, email)
    end

    def delete_collaboration(cloud, email)
      shelly.delete_collaboration(cloud, email)
    end

    def load_credentials
      return unless credentials_exists?
      @email, @password = File.read(credentials_path).split("\n")
    end

    def save_credentials
      FileUtils.mkdir_p(config_dir) unless credentials_exists?
      File.open(credentials_path, 'w') { |file| file << "#{email}\n#{password}" }
      set_credentials_permissions
    end

    def delete_credentials
      File.delete(credentials_path) if credentials_exists?
    end

    def delete_ssh_key
      shelly.logout(File.read(ssh_key_path)) if ssh_key_exists?
    end

    def ssh_key_exists?
      File.exists?(ssh_key_path)
    end

    def ssh_key_path
      File.expand_path("~/.ssh/id_rsa.pub")
    end

    def self.guess_email
      @@guess_email ||= IO.popen("git config --get user.email").read.strip
    end

    def config_dir
      File.expand_path("~/.shelly")
    end

    def upload_ssh_key
      key = File.read(ssh_key_path).strip
      shelly.add_ssh_key(key)
    end

    protected
      def credentials_path
        File.join(config_dir, "credentials")
      end

      def credentials_exists?
        File.exists?(credentials_path)
      end

      def set_credentials_permissions
        FileUtils.chmod(0700, config_dir)
        FileUtils.chmod(0600, credentials_path)
      end
    end
end


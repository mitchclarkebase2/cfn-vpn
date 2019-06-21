require 'thor'
require 'fileutils'
require 'cfnvpn/cloudformation'
require 'cfnvpn/certificates'
require 'cfnvpn/cfhighlander'
require 'cfnvpn/cloudformation'
require 'cfnvpn/log'
require 'cfnvpn/clientvpn'

module CfnVpn
  class Init < Thor::Group
    include Thor::Actions
    include CfnVpn::Log

    argument :name

    class_option :profile, aliases: :p, desc: 'AWS Profile'
    class_option :region, aliases: :r, default: ENV['AWS_REGION'], desc: 'AWS Region'
    class_option :verbose, desc: 'set log level to debug', type: :boolean

    class_option :server_cn, required: true, desc: 'server certificate common name'
    class_option :client_cn, desc: 'client certificate common name'

    class_option :subnet_id, required: true, desc: 'subnet id to associate your vpn with'
    class_option :cidr, default: '10.250.0.0/16', desc: 'cidr from which to assign client IP addresses'

    def self.source_root
      File.dirname(__FILE__)
    end

    def set_loglevel
      Log.logger.level = Logger::DEBUG if @options['verbose']
    end

    def create_build_directory
      @build_dir = "#{ENV['HOME']}/.cfnvpn/#{@name}"
      Log.logger.debug "creating directory #{@build_dir}"
      FileUtils.mkdir_p(@build_dir)
    end

    def initialize_config
      @config = {}
      @config['subnet_id'] = @options['subnet_id']
      @config['cidr'] = @options['cidr']
    end

    def stack_exist
      @cfn = CfnVpn::Cloudformation.new(@options['region'],@name)
      if @cfn.does_cf_stack_exist()
        Log.logger.error "#{@name}-cfnvpn stack already exists in this account in region #{@options['region']}"
        exit 1
      end
    end

    # create certificates
    def generate_server_certificates
      Log.logger.info "Generating certificates using openvpn easy-rsa"
      cert = CfnVpn::Certificates.new(@build_dir,@name)
      @client_cn = @options['client_cn'] ? @options['client_cn'] : "#{@name}.#{@options['server_cn']}"
      Log.logger.debug cert.generate(@options['server_cn'],@client_cn)
    end

    def upload_certificates
      cert = CfnVpn::Certificates.new(@build_dir,@name)
      @config['server_cert_arn'] = cert.upload_certificates(@options['region'],'server','server',@options['server_cn'])
      @config['client_cert_arn'] = cert.upload_certificates(@options['region'],@client_cn,'client')
      cert.store_certificate(@options['region'],"#{@client_cn}.crt")
      cert.store_certificate(@options['region'],"#{@client_cn}.key")
    end

    def deploy_vpn
      template('templates/cfnvpn.cfhighlander.rb.tt', "#{@build_dir}/#{@name}.cfhighlander.rb", @config)
      Log.logger.debug "Generating cloudformation from #{@build_dir}/#{@name}.cfhighlander.rb"
      cfhl = CfnVpn::CfHiglander.new(@options['region'],@name,@config,@build_dir)
      template_path = cfhl.render()
      Log.logger.debug "Cloudformation template #{template_path} generated and validated"
      Log.logger.info "Launching cloudformation stack #{@name}-cfnvpn in #{@options['region']}"
      cfn = CfnVpn::Cloudformation.new(@options['region'],@name)
      change_set, change_set_type = cfn.create_change_set(template_path)
      cfn.wait_for_changeset(change_set.id)
      cfn.execute_change_set(change_set.id)
      cfn.wait_for_execute(change_set_type)
      Log.logger.debug "Changeset #{change_set_type} complete"
    end

    def finish
      vpn = CfnVpn::ClientVpn.new(@name,@options['region'])
      @endpoint_id = vpn.get_endpoint_id()
      Log.logger.info "Client VPN #{@endpoint_id} created. Run `cfn-vpn config #{@name}` to setup the client config"
    end

  end
end

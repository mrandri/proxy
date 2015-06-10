require 'aws-sdk'
require 'securerandom'
require 'pathname'
require 'fileutils'

module Proxy
  class Deploy
    DEPLOY_ID_FILE = Pathname.new("./.deploy")
    DEPLOY_TAG = "proxy_deploy_id"

    def initialize
      if DEPLOY_ID_FILE.exist?
        @id = DEPLOY_ID_FILE.read
      else
        @id = SecureRandom.uuid
      end

      region = "us-east-1"

      # Assumes credentials in ENV or ~/.aws/credentials
      @elb = Aws::ElasticLoadBalancing::Client.new(region: region)
      @elb_name = "proxy-elb"

      @ec2 = Aws::EC2::Client.new(region: region)
      @security_group = "proxy"
      @ami = "ami-d05e75b8"
      @count = 1
      @instance_type = "m3.medium"
      @key_name = "Zach"
    end

    def deploy
      clean_up_if_necessary

      instance_ids_to_kill = current_instance_ids

      DEPLOY_ID_FILE.write(@id)
      instance_ids = boot_new_instances

      configure_all(instance_ids)

      puts "Waiting for new instances to become healthy..."
      wait_for_healthy(instance_ids)

      puts "Killing old instances..."
      kill_instances(instance_ids_to_kill)
      DEPLOY_ID_FILE.unlink

      puts "Deploy successful."
    end

    def configure_all(ids)
      puts "Configuring new instances..."

      unless create_tar
        exit(1)
      end

      pages = @ec2.describe_instances(instance_ids: ids).to_a
      hosts = pages.map do |page|
        page.reservations.map do |reservation|
          reservation.instances.map(&:public_dns_name)
        end
      end.flatten

      hosts.each do |host|
        puts "Waiting for SSH to become available at #{host}..."
        while !system("ssh -o StrictHostKeyChecking=no ubuntu@#{host} echo hi  > /dev/null 2>&1"); end

        system("scp #{tar_name} ubuntu@#{host}:~") or exit(1)
        system("ssh ubuntu@#{host} '#{ssh_script}'") or exit(1)
      end

      puts "Instances configured"

      FileUtils.rm(tar_name)
    end

    def ssh_script
      <<-SHELL.split("\n").map(&:strip).join(" && ")
        mkdir proxy
        tar xjf #{tar_name} -C proxy
        $HOME/proxy/backend/bin/setup
        sudo $HOME/proxy/backend/bin/proxy-install production
      SHELL
    end

    def create_tar
      files = `git ls-files`.split("\n") + %w(certs/key.pem certs/cert.pem config.production.yml)
      system("tar cjf #{tar_name} #{files.join(' ')}")
    end

    def tar_name
      "proxy-#{@id}.tar.bz2"
    end

    def boot_new_instances
      print "Booting new instances... "

      pages = @ec2.run_instances(
        client_token: @id,
        image_id: @ami,
        min_count: @count,
        max_count: @count,
        key_name: @key_name,
        security_groups: [@security_group],
        instance_type: @instance_type
      ).to_a

      ids = pages.map do |page|
        page.instances.map(&:instance_id)
      end.flatten

      puts "booted: #{ids.join(", ")}"

      @ec2.create_tags(
        resources: ids,
        tags: [{key: DEPLOY_TAG, value: @id}]
      )

      print "Waiting for instances to be ready... "

      @ec2.wait_until(:instance_running, instance_ids: ids)

      puts "ready"

      ids
    end

    def current_instance_ids
      print "Finding currently running instances... "

      pages = @elb.describe_load_balancers({ load_balancer_names: [@elb_name] }).to_a

      ids = pages.map do |page|
        page.load_balancer_descriptions.map do |lb|
          lb.instances.map(&:instance_id)
        end
      end.flatten

      puts "found #{ids.empty? ? "None" : ids.join(", ")}"

      ids
    end

    def clean_up_if_necessary
      if DEPLOY_ID_FILE.exist?
        puts "Last deploy failed to complete. Cleaning up..."
        ids = kill_all_with_uuid(DEPLOY_ID_FILE.read)
        if ids.empty?
          puts "No clean up required."
        else
          puts "Destroyed the following instances: #{ids}"
        end
      end
    end

    def kill_all_with_uuid(uuid)
      []
    end
  end
end
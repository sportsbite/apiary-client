# encoding: utf-8
require 'rest-client'
require 'rack'
require 'ostruct'
require 'json'

require 'apiary/agent'
require 'apiary/helpers'
require 'apiary/exceptions'

module Apiary::Command
  class Styleguide
    include Apiary::Helpers

    attr_reader :options

    def initialize(opts)
      @options = OpenStruct.new(opts)
      @options.fetch        ||= false
      @options.add          ||= '.'
      @options.functions    ||= '.'
      @options.rules        ||= '.'
      @options.api_key      ||= ENV['APIARY_API_KEY']
      @options.proxy        ||= ENV['http_proxy']
      @options.api_host     ||= 'api.apiary.io'
      @options.vk_url       ||= 'https://voight-kampff-aws.apiary-services.com/production/validate'
      @options.headers      ||= {
        content_type: :json,
        accept: :json,
        user_agent: Apiary.user_agent
      }
      @options.failedOnly = !@options.full_report
    end

    def execute
      check_api_key
      if @options.fetch
        fetch
      else
        validate
      end
    end

    def fetch
      begin
        assertions = fetch_from_apiary
        assertions = JSON.parse(assertions)
      rescue => e
        abort "Error: Can not fetch rules and functions: #{e}"
      end

      begin
        File.write("./#{default_functions_file_name}", assertions['functions']['functions'])
        File.write("./#{default_rules_file_name}", JSON.pretty_generate(assertions['rules']['rules']))
        puts "`./#{default_functions_file_name}` and `./#{default_rules_file_name}` has beed succesfully created"
      rescue => e
        abort "Error: Can not write into the rules/functions file: #{e}"
      end
    end

    def validate
      token = jwt

      begin
        token = JSON.parse(token)['jwt']
      rescue JSON::ParserError => e
        abort "Can not authenticate: #{e}"
      end

      begin
        load
      rescue StandardError => e
        abort "Error: #{e.message}"
      end

      data = {
        functions: @functions,
        rules: @rules,
        add: @add,
        failedOnly: @options.failedOnly
      }.to_json

      headers = @options.headers.clone
      headers[:Authorization] = "Bearer #{token}"

      result = call_resource(@options.vk_url, data, headers, :post)

      begin
        puts JSON.pretty_generate(JSON.parse(result))
      rescue
        abort "Error: Can not parse result: #{result}"
      end
    end

    def default_rules_file_name
      'rules.json'
    end

    def default_functions_file_name
      'functions.js'
    end

    def call_apiary(path, data, headers, method)
      call_resource("https://#{@options.api_host}/#{path}", data, headers, method)
    end

    def call_resource(url, data, headers, method)
      RestClient.proxy = @options.proxy

      method = :post unless method

      begin
        response = RestClient::Request.execute(method: method, url: url, payload: data, headers: headers)
      rescue RestClient::Exception => e
        begin
          err = JSON.parse e.response
        rescue JSON::ParserError
          err = {}
        end

        message = 'Error: Apiary service responded with:'

        if err.key? 'message'
          abort "#{message} #{e.http_code} #{err['message']}"
        else
          abort "#{message} #{e.message}"
        end
      end

      response
    end

    def jwt
      path = 'styleguide-cli/get-token/'
      headers = @options.headers.clone
      headers[:authentication] = "Token #{@options.api_key}"
      call_apiary(path, {}, headers, :get)
    end

    def check_api_key
      unless @options.api_key && @options.api_key != ''
        abort 'Error: API key must be provided through environment variable APIARY_API_KEY. \Please go to https://login.apiary.io/tokens to obtain it.'
      end
    end

    def load
      @add_path = api_description_source_path(@options.add)
      @add = api_description_source(@add_path)
      @functions = get_functions(@options.functions)
      @rules = get_rules(@options.rules)
    end

    def fetch_from_apiary
      path = 'styleguide-cli/get-assertions/'
      headers = @options.headers.clone
      headers[:authentication] = "Token #{@options.api_key}"
      call_apiary(path, {}, headers, :get)
    end

    def get_rules(path)
      JSON.parse get_file_content(get_path(path, 'rules'))
    end

    def get_functions(path)
      get_file_content(get_path(path, 'functions'))
    end

    def get_path(path, type)
      raise "`#{path}` not found" unless File.exist? path

      return path if File.file? path

      file =  case type
              when 'rules'
                default_rules_file_name
              else
                default_functions_file_name
              end

      path = File.join(path, file)

      return path if File.file? path
      raise "`#{path}` not found"
    end

    def get_file_content(path)
      source = nil
      File.open(path, 'r:bom|utf-8') { |file| source = file.read }
      source
    end
  end
end

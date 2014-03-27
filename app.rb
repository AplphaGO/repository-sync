require 'sinatra/base'
require 'json'
require 'fileutils'
require 'git'

class RepositorySync < Sinatra::Base
  set :root, File.dirname(__FILE__)

  # "Thin is a supremely better performing web server so do please use it!"
  set :server, %w[thin webrick]

  before do
    # trim trailing slashes
    request.path_info.sub! %r{/$}, ''
    # keep some important vars
    @token = params[:token]
    @payload = JSON.parse params[:payload]
    @originating_repo = "#{@payload["repository"]["owner"]["name"]}/#{@payload["repository"]["name"]}"
    @destination_repo = params[:dest_repo]
  end

  get "/" do
    "I think you misunderstand how to use this."
  end

  post "/update_public" do
    check_params params

    in_tmpdir do |tmpdir|
      clone_repo(tmpdir)
      update_repo(tmpdir)
    end

    "Hey, you did it!"
  end

  helpers do

    def check_params(params)
      return halt 500, "Tokens didn't match!" unless valid_token?(params[:token])
      return halt 500, "Missing `dest_repo` argument" if params[:dest_repo].nil?

      return halt 406, "Payload was not for master, aborting." unless master_branch?(@payload)
    end

    def valid_token?(token)
      return true if Sinatra::Base.development?
      params[:token] == ENV["REPOSITORY_SYNC_TOKEN"]
    end

    def master_branch?(payload)
      payload["ref"] == "refs/heads/master"
    end

    def in_tmpdir
      path = File.expand_path "#{Dir.tmpdir}/repository-sync/repos/#{Time.now.to_i}#{rand(1000)}/"
      FileUtils.mkdir_p path
      puts "Directory created at: #{path}"
      yield path
    ensure
      FileUtils.rm_rf( path ) if File.exists?( path ) && !Sinatra::Base.development?
    end

    def clone_repo(tmpdir)
      Dir.chdir "#{tmpdir}" do
        puts "Cloning #{@destination_repo}..."
        @git_dir = Git.clone(clone_url_with_token(@destination_repo), @destination_repo)
      end
    end

    def update_repo(tmpdir)
      Dir.chdir "#{tmpdir}" do
        remotename = "otherrepo-#{Time.now.to_i}"
        branchname = "update-#{Time.now.to_i}"

        @git_dir.add_remote(remotename, clone_url_with_token(@originating_repo))
        puts "Fetching #{@originating_repo}..."
        @git_dir.remote(remotename).fetch
        @git_dir.branch(branchname).checkout

        # lol can't merge --squash with the git lib.
        puts "Merging #{remotename}/master..."
        merge_command = IO.popen(["git", "merge", "--squash", "#{remotename}/master"])
        print_blocking_output(merge_command)

        @git_dir.commit('Squashing and merging an update')

        # not sure why push isn't working here
        puts "Pushing to origin..."
        merge_command = IO.popen(["git", "push", "origin", branchname])
        print_blocking_output(merge_command)
      end
    end

    def print_blocking_output(command)
      while (line = command.gets) # intentionally blocking call
        print line
      end
    end

    def clone_url_with_token(repo)
      "https://#{@token}:x-oauth-basic@github.com/#{repo}.git"
    end
  end
end

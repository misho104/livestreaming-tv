require 'json'
require 'sinatra'
require 'twitter'
require 'tempfile'
require 'yaml'

module LiveStreamingTV
  class Controller < Sinatra::Base
    configure do
      set :config, YAML::load_file('config/config.yaml')
      set :ffmpeg, FFmpeg.new(settings.config)
      set :controller, BonDriverController.new(settings.config)
      set :database, ActiveRecord::Base.establish_connection(YAML::load_file('config/database.yaml'))
      settings.ffmpeg.start

      client = Twitter::REST::Client.new do |config|
        config.consumer_key        = ENV['CONSUMER_KEY']
        config.consumer_secret     = ENV['CONSUMER_SECRET']
        config.access_token        = ENV['ACCESS_TOKEN']
        config.access_token_secret = ENV['ACCESS_TOKEN_SECRET']
      end
      set :twitter_client, client
    end

    get '/' do
      File.read(File.join('public', 'index.html'))
    end

    get '/channels' do
      content_type :json
      Model::Ch2.all.to_json
    end

    get '/channels/current' do
      c = settings.controller.channel
      ch2 = LiveStreamingTV::Model::Ch2.find_by(tuning_space: c[0], channel_number: c[1])
      if channel
        content_type :json
        ch2.to_json
      else
        404
      end
    end

    get '/programmes' do
      content_type :json
      LiveStreamingTV::Model::Programme.where('stop > ?', Time.now).limit(30).to_json
    end

    post '/channels/select' do
      ch = params[:ch].to_i
      settings.controller.channel(ch)
      200
    end

    post '/tweet' do
      img = params[:url].sub(/^data:image\/png;base64,/, '').unpack('m').first
      Tempfile.create("#{rand(256**16).to_s(16)}.png") do |png|
        open(png, 'wb') {|f| f.write img }
        open(png) do |f|
          settings.twitter_client.update_with_media(' ', f)
        end
      end
      201
    end
  end
end


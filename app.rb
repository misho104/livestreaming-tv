# Windows 

require 'open3'
require 'time'
require 'sinatra'
require 'm3u8'

RECTEST_PATH    = 'C:/tv/TVTest/RecTest.exe'
RECTEST_PORT    = 3456
FFMPEG_PATH     = 'C:/tv/ffmpeg/bin/ffmpeg.exe'
HLS_PATH        = 'public/hls'
M3U8_FILENAME   = 'playlist.m3u8'

TS_FPS           = 24
HLS_SEGMENT_TIME = 2

module LiveStreamingTV
  class RecTest
    def initialize
      @pid = 0
    end

    def restart(ch = 0)
      stop
      start ch
    end

    def stop
      if @pid > 0
        Process.kill('KILL', @pid)
        @pid = 0
      end
    end

    def start(ch = 0)
      return if @pid > 0

      Thread.start do 
        puts "start rectest (ch = #{ch})"
        if ch > 0
          Open3.popen3(RECTEST_PATH, '/rch', ch.to_s, '/udp', '/udpport', RECTEST_PORT.to_s) do |i, o, e, w|
            @pid = w.pid
          end
        else
          Open3.popen3(RECTEST_PATH, '/udp', '/udpport', RECTEST_PORT.to_s) do |i, o, e, w|
            @pid = w.pid
          end
        end
        @pid = 0
      end
    end

    def running?
      @pid > 0
    end
  end

  class FFmpeg
    def initialize
      @pid = 0
    end

    def restart
      stop
      start
    end

    def stop
      if @pid > 0
        Process.kill('KILL', @pid)
        @pid = 0
      end
    end

    def start
      return if @pid > 0

      Thread.start do
        puts "start ffmpeg"
        delete_temp_files
        now = Time.now.to_i
        Open3.popen3(FFMPEG_PATH,
                     '-i', "udp://127.0.0.1:#{RECTEST_PORT}?pkt_size=262144^&fifo_size=1000000^&overrun_nonfatal=1",
                     '-f', 'mpegts',
                     '-threads', 'auto',
                     '-map', '0:0', '-map', '0:1',
                     '-acodec', 'libvo_aacenc', '-ar', '44100', '-ab', '128k', '-ac', '2',
                     '-vcodec', 'libx264', '-s', '1280x720', '-aspect', '16:9', '-vb', '2m',
                     '-r', TS_FPS.to_s,
                     '-g', "#{TS_FPS * HLS_SEGMENT_TIME}",
                     '-force_key_frames', "expr:(t/#{HLS_SEGMENT_TIME})",
                     '-f', 'segment',
                     '-segment_format', 'mpegts',
                     '-segment_time', HLS_SEGMENT_TIME.to_s,
                     '-segment_list', "#{HLS_PATH}/#{now}_#{M3U8_FILENAME}",
                     '-segment_list_flags', 'live',
                     '-segment_wrap', '50',
                     '-segment_list_size', '5',
                     '-break_non_keyframes', '1',
                     "#{HLS_PATH}/#{now}_stream%d.ts") do |i, o, e, w|
                       puts "ffmpeg is running (pid = #{w.pid})"
                       @pid = w.pid
                       e.each {|l| puts l}
                     end
        puts "ffmpeg is dead"
        @pid = 0
      end
    end

    def delete_temp_files
      playlists = Dir.glob("#{HLS_PATH}/*.m3u8").sort do |a, b|
        File.basename(a) <=> File.basename(b)
      end
      if playlists.size > 1
        prefix = File.basename(playlists[0]).match(/^\d+/)[0]
        File.delete playlists[0]
        Dir.glob("#{HLS_PATH}/#{prefix}_*.ts").each do |f|
          File.delete f
        end
      end
    end

    def running?
      @pid > 0
    end
  end

  class Controller < Sinatra::Base
    configure do
      set :rectest, RecTest.new
      set :ffmpeg, FFmpeg.new
      settings.rectest.start
      settings.ffmpeg.start
    end

    get '/' do
      File.read(File.join('public', 'index.html'))
    end

    get '/hls/playlist.m3u8' do
      playlists = []

      Dir.glob("#{HLS_PATH}/*.m3u8").sort do |a, b|
        File.basename(a) <=> File.basename(b)
      end.each do |file|
        time = File.basename(file).match(/^\d+/)[0].to_i
        File.open(file, 'r') do |f|
          playlists << {:time => time, :m3u8 => M3u8::Playlist.read(f.read)}
	end
      end

      if playlists.size == 0
        404
      elsif playlists.size == 1
	playlists[0][:m3u8].sequence = playlists[0][:m3u8].sequence + playlists[0][:time]
	playlists[0][:m3u8].to_s.gsub('#EXT-X-ENDLIST', '')
      else
        playlists[0][:m3u8].items.concat(playlists[1][:m3u8].items)
        playlists[0][:m3u8].items.shift(playlists[1][:m3u8].items.size)
	playlists[0][:m3u8].sequence = playlists[1][:m3u8].sequence + playlists[1][:time] + playlists[1][:m3u8].items.size
	playlists[0][:m3u8].to_s.gsub('#EXT-X-ENDLIST', '')
      end
    end

    get '/hls/*.ts' do |filename|
      File.read(File.join('public', "#{filename}.ts"))
    end

    post '/select_channel' do
      ch = params['ch'].to_i
      puts "select ch = #{ch}"
      settings.rectest.restart ch
      settings.ffmpeg.restart
      200
    end
  end
end

#
## ftpd.rb
## a simple ruby ftp server
#
# version: 2 (2006-02-02)
#
# author:  chris wanstrath // chris@ozmm.org
# site:    http://rubyforge.org/projects/ftpd/
#
# license: MIT License // http://www.opensource.org/licenses/mit-license.php
# copyright: (c) two thousand six chris wanstrath
#
# tested on: ruby 1.8.4 (2005-12-24) [powerpc-darwin8.4.0]
#
# special thanks:
#   - Peter Harris for his ftpd.py (Jacqueline FTP) script
#   - RFC 959 (ftp)
#
# get started:  
#  $ ruby ftpd.rb --help
#

require 'socket'
require 'logger'
require 'optparse'
require 'yaml'

Thread.abort_on_exception = true

class FTPServer < TCPServer

  PROGRAM      = "ftpd.rb"  
  VERSION      = 2
  AUTHOR       = "Chris Wanstrath"
  AUTHOR_EMAIL = "chris@ozmm.org"
  
  LBRK = "\r\n" # ftp protocol says this is a line break
  
  # commands supported
  COMMANDS = %w[QUIT TYPE USER RETR STOR PORT CDUP CWD DELE RMD PWD LIST SIZE
                SYST SITE MKD]
  
  # setup a TCPServer instance and house our main loop
  def initialize(config)
    host = config[:host]
    port = config[:port]

    @config  = config
    @logger  = Logger.new(STDOUT)
    @logger.progname = "ftpd.rb"
    @logger.level = config[:debug] ? Logger::DEBUG : Logger::ERROR
    @threads = []
    
    begin
      server = super(host, port)
    rescue Errno::EACCES
      fatal "The port you have chosen is already in use or reserved."
      return
    end
    
    @status  = :alive

    notice "Server started successfully at ftp://#{host}:#{port} " + \
              "[PID: #{Process.pid}]"
    
    while (@status == :alive)
      begin
        sock = server.accept
        clients = 0
        @threads.each { |t| clients += 1 if t.alive? }
        if clients >= @config[:clients]
          sock.print "530 Too many connections" + LBRK
          sock.close
        else
          @threads << Thread.new(sock) do |socket|
            Thread.current[:socket] = socket
            Thread.current[:mode]   = :binary
            info = socket.peeraddr
            remote_port, remote_ip = info[1], info[3]
            Thread.current[:addr]  = [remote_ip, remote_port]
            debug "Got connection"
            response "200 #{host}:#{port} FTP server (#{PROGRAM}) ready."
            while socket.nil? == false and socket.closed? == false
              request = socket.gets
              response handler(request)
            end
          end
        end
      rescue Interrupt
        @status = :dead
      rescue Exception => ex
        @status = :dead
        fatal "#{ex.class}: #{ex.message} - #{request}\n\t#{ex.backtrace[0]}"
      end
    end
    
    notice "Shutting server down..."
    
    # clean up anything we've still got open
    @threads.each do |t|
      next if t.alive? == false
      sk = t[:socket]
      sk.close unless sk.nil? or sk.closed? or sk.is_a?(Socket) == false
      t[:socket] = sk = nil
      t.kill
    end
    server.close
  end
  
  private
  
  # send a message to the client
  def response(msg)
    sock = Thread.current[:socket]
    sock.print msg + LBRK unless msg.nil? or sock.nil? or sock.closed?
  end
  
  # deals with the user input
  def handler(request)
    return if request.nil? or request.to_s == ''
    begin
      command = request[0,4].downcase.strip
      rqarray = request.split
      message = rqarray.length > 2 ? rqarray[1..rqarray.length] : rqarray[1]
      debug "Request: #{command}(#{message})"
      __send__ command, message
    rescue Errno::EACCES, Errno::EPERM
      "553 Permission denied"
    rescue Errno::ENOENT
      "553 File doesn't exist" 
    rescue Exception => e
      debug "Request: #{request}"
      fatal "Error: #{e.class} - #{e.message}\n\t#{e.backtrace[0]}"
      exit!
    end
  end
  
  #
  # logging functions
  #
  def debug(msg)
    @logger.debug("#{remote_addr} - #{msg} (threads: #{show_threads})")
  end
  
  # a bunch of wrappers for Logger methods
  %w[warn info error fatal].each do |meth|
    define_method( meth.to_sym ) { |msg| @logger.send(meth.to_sym, msg) }
  end
  
  # always show
  def notice(msg); STDOUT << "=> #{msg}\n"; end;
  
  # where the user's from
  def remote_addr; Thread.current[:addr].join(':'); end
  
  # thread count
  def show_threads
    threads = 0
    @threads.each { |t| threads += 1 if t.alive? }
    threads
  end
  
  # command not understood
  def method_missing(name, *params)
    arg = (params.is_a? Array) ? params.join(' ') : params
    if @config[:debug]
      "500 I don't understand " + name.to_s + "(" + arg + ")"
    else
      "500 Sorry, I don't understand #{name.to_s}"
    end
  end
  
  #
  # actions a user can perform
  #
  # all of these methods are expected to return a string
  # which will then be sent to the client.
  #
  
  # login
  def user(msg)
    return "502 Only anonymous user implemented" if msg != 'anonymous'
    debug "User #{msg} logged in."
    Thread.current[:user] = msg
    "230 OK, password not required"
  end
  
  # open up a port / socket to send data
  def port(msg)
    nums = msg.split(',')
    port = nums[4].to_i * 256 + nums[5].to_i
    host = nums[0..3].join('.')
    if Thread.current[:datasocket]
      Thread.current[:datasocket].close
      Thread.current[:datasocket] = nil
    end
    Thread.current[:datasocket] = TCPSocket.new(host, port)
    debug "Opened passive connection at #{host}:#{port}"
    "200 Passive connection established (#{port})"
  end
  
  # listen on a port
  def pasv(msg)
    "500 pasv not yet implemented"
  end
  
  # retrieve a file
  def retr(msg)
    response "125 Data transfer starting"
    send_data(File.new(msg, 'r'))
    "226 Closing data connection, sent #{bytes} bytes"      
  end
  
  # upload a file
  def stor(msg)
    file = File.new(msg, 'w')
    response "125 Data transfer starting"
    data = Thread.current[:datasocket].recv(1024)
    bytes = data.length
    file.write data
    debug "#{Thread.current[:user]} created file #{Dir::pwd}/#{msg}"
    "200 OK, received #{bytes} bytes"    
  end
  
  # make directory
  def mkd(msg)
    return "521 \"#{msg}\" already exists" if File.directory? msg
    Dir::mkdir(msg)
    debug "#{Thread.current[:user]} created directory #{Dir::pwd}/#{msg}"
    "257 \"#{msg}\" created"
  end
  
  # crazy site command
  def site(msg)
    command = (msg.is_a?(Array) ? msg[0] : msg).downcase
    case command
      when 'chmod'
        File.chmod(msg[1].oct, msg[2])
        return "200 CHMOD of #{msg[2]} to #{msg[1]} successful"
    end
    "502 Command not implemented"
  end
  
  # wrapper for rmd
  def dele(msg); rmd(msg); end
  
  # delete a file / dir
  def rmd(msg)
    if File.directory? msg
      Dir::delete msg
    elsif File.file? msg
      File::delete msg
    end
    debug "#{Thread.current[:user]} deleted #{Dir::pwd}/#{msg}"
    "200 OK, deleted #{msg}"
  end
  
  # file size in bytes
  def size(msg)
    bytes = File.size(msg)
    "#{msg} #{bytes}"
  end
  
  # report the name of the server
  def syst(msg)
    "215 UNIX #{PROGRAM} v#{VERSION} "
  end
  
  # list files in current directory
  def list(msg)
    response "125 Opening ASCII mode data connection for file list"
    send_data(`ls -l`.split("\n").join(LBRK) + LBRK)
    "226 Transfer complete"
  end
  
  # crazy tab nlst command
  def nlst(msg)
    Dir["*"].join " "   
  end
  
  # print the current directory
  def pwd(msg)
    "257 \"#{Dir.pwd}\" is the current directory"
  end
  
  # change directory
  def cwd(msg)
    begin
      Dir.chdir(msg)
    rescue Errno::ENOENT
      "550 Directory not found"
    else 
      "250 Directory changed to " + Dir.pwd
    end
  end
  
  # go up a directory, really just an alias
  def cdup(msg)
    cwd('..')
  end
  
  # ascii / binary mode
  def type(msg)
    if msg == "A"
       Thread.current[:mode] == :ascii
      "200 Type set to ASCII"
    elsif msg == "I"
      Thread.current[:mode] == :binary  
#      "200 Type set to binary"
      "502 Binary mode not yet implemented"
    end
  end
  
  # quit the ftp session
  def quit(msg = false)
    Thread.current[:socket].close
    Thread.current[:socket] = nil
    debug "User #{Thread.current[:user]} disconnected."
    "221 Laterz"
  end
  
  # help!
  def help(msg)
    commands = COMMANDS
    commands.sort!
    response "214-"
    response "  The following commands are recognized."
    i   = 1
    str = "  "
    commands.each do |c|
      str += "#{c}"
      str += "\t\t"
      str += LBRK + "  " if (i % 3) == 0      
      i   += 1
    end
    response str
    "214 Send comments to #{AUTHOR_EMAIL}"
  end
  
  # no operation
  def noop(msg); "200 "; end

  # send data over a connection
  def send_data(data)
    bytes = 0
    begin
      # this is where we do ascii / binary modes, if we ever get that far
      data.each do |line|
        Thread.current[:datasocket].send(line, 0)
        bytes += line.length
      end
    rescue Errno::EPIPE
      debug "#{Thread.current[:user]} aborted file transfer"  
      return quit
    else
      debug "#{Thread.current[:user]} got #{bytes} bytes"
    ensure
      Thread.current[:datasocket].close
      Thread.current[:datasocket] = nil    
    end
  end

  #
  # graveyard -- non implemented features with no plans
  #
  def mode(msg)
    "202 Stream mode only supported"
  end
  
  def stru(msg)
    "202 File structure only supported"
  end

end

class FTPConfig
  
  #
  # command line option business
  #
  def self.parse_options(args)
    config = Hash.new
    config[:d]            = Hash.new    # the defaults
    config[:d][:host]     = "127.0.0.1"
    config[:d][:port]     = 21
    config[:d][:clients]  = 5
    config[:d][:yaml_cfg] = "ftpd.yml"
    config[:d][:debug]    = false
    
    opts = OptionParser.new do |opts|
      opts.banner = "Usage: #{FTPServer::PROGRAM} [options]"

      opts.separator ""
      opts.separator "Specific options:"

      opts.on("-h", "--host HOST", 
              "The hostname or ip of the host to bind to " + \
              "(default 127.0.0.1)") do |host|
        config[:host] = host
      end
      
      opts.on("-p", "--port PORT", 
              "The port to listen on (default 21)") do |port|
        config[:port] = port
      end
      
      opts.on("-c", "--clients NUM", Integer,
              "The number of connections to allow at once (default 5)") do |c|
        config[:clients] = c
      end
      
      opts.on("--config FILE", "Load configuration from YAML file") do |file|
        config[:yaml_cfg] = file
      end
      
      opts.on("--sample", "See a sample YAML config file") do
        sample = Hash.new
        config[:d].each do |k, v| 
          sample = sample.merge(k.to_s => v) unless k == :yaml_cfg
        end
        puts YAML::dump( sample )
        exit
      end
      
      opts.on("-d", "--debug", "Turn on debugging mode") do
        config[:debug] = true
      end

      opts.separator ""
      opts.separator "Common options:"

      opts.on_tail("--help", "Show this message") do
        puts opts
        exit
      end

      opts.on_tail("-v", "--version", "Show version") do
        puts "#{FTPServer::PROGRAM} FTP server v#{FTPServer::VERSION}"
        exit
      end  
    end
    opts.parse!(args)
    config
  end
  
end

#
# config
#
if $0 == __FILE__ 
  # gather config options
  config = FTPConfig.parse_options(ARGV)

  # try and get name for yaml config file from command line or defaults
  config_file = config[:yaml_cfg] || config[:d][:yaml_cfg]

  # if file exists, override default options with arguments from it
  if File.file? config_file
    yaml = YAML.load(File.open(config_file, "r"))
    yaml.each { |k,v| config[k.to_sym] ||= v }
  end

  # now fill in missing config options from the default set
  config[:d].each { |k,v| config[k.to_sym] ||= v }

  #
  # run the daemon
  #
  server = FTPServer.new(config)
end

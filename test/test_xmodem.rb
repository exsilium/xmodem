#make sure the relevant folder with our libraries is in the require path
lib_path=File.expand_path(File.dirname(__FILE__)+"//..//lib")
  $:.unshift(lib_path) unless $:.include?(lib_path)

require 'versioncheck'
require 'xmodem/version'

rb_vc = VersionCheck.rubyversion
if !rb_vc.have_version?(2,1)
  require 'simplecov'
  SimpleCov.command_name 'MiniTest'
  SimpleCov.start
end

if ENV['TRAVIS'] == "true" && ENV['CI'] =="true"
  require 'coveralls'
  Coveralls.wear!
end

require 'minitest/autorun'
require 'minitest/reporters'

MiniTest::Reporters.use!

require 'xmodem'
require 'socket'
require 'stringio'

Thread.abort_on_exception = true

XMODEM::logger.outputters = Outputter.stdout

XMODEM::timeout_seconds=0.4 #so we don't wait so long for retransmissions

LOCAL_PORT=9999

module CorruptIn
 attr_accessor :real_getc,:corruption_frequency

  def getc
    @char_count=0 if @char_count.nil?

    raise "real_getc not initialised"  if @real_getc.nil?
    b=@real_getc.call
    @char_count+=1
    if ((@char_count % @corruption_frequency)==0) then
      corrupted_char=0xff-b.ord
      $stdout.puts "corrupting : 0x%02x -> 0x%02x" % [b.ord,corrupted_char]
      b=corrupted_char.chr
    end
    return b
  end

end

module CorruptOut
 attr_accessor :real_putc,:corruption_frequency

  def putc (b)
    @char_count=0 if @char_count.nil?

    raise "real_putc not initialised"  if @real_putc.nil?
    @char_count+=1
    if ((@char_count % @corruption_frequency)==0) then
      corrupted_char=0xff-b
      $stdout.puts "corrupting : 0x%02x -> 0x%02x" % [b,corrupted_char]
      b=corrupted_char
    end
      @real_putc.call(b)

  end
end


module DropIn
 attr_accessor :real_getc,:drop_frequency

  def getc
    @char_count=0 if @char_count.nil?

    raise "real_getc not initialised"  if @real_getc.nil?
    b=@real_getc.call
    @char_count+=1
    if ((@char_count % @drop_frequency)==0) then
        $stdout.puts "dropping : 0x%02x " % [b.ord]
        @real_getc.call
    end
    return b
  end
end

module DropOut
 attr_accessor :real_putc,:drop_frequency

  def putc (b)
    @char_count=0 if @char_count.nil?

    raise "real_putc not initialised"  if @real_putc.nil?
    @char_count+=1
    if ((@char_count % @drop_frequency)==0) then
        $stdout.puts "dropping : 0x%02x " % [b]
     else
      @real_putc.call(b)
    end
  end
end

class XmodemTests < MiniTest::Test

  @@server=nil
  @@unix_socket = "/tmp/xmodem-test.sock"

  def sendfile(file)
    if @@server.nil? then
      if ENV['OS'] != "Windows_NT"
        File.delete( @@unix_socket ) if FileTest.exists?( @@unix_socket )
        @@server = UNIXServer.new(@@unix_socket)
      else
        @@server = TCPServer.new(LOCAL_PORT)
      end
    else
      puts "reusing existing server"
    end
    session = @@server.accept
    session.sync=true
    puts "Connected (sendfile)"
    XMODEM::send(session,file)
    session.close
  end

  def acceptfile(file,error_type=nil,error_frequency=nil,rx_options=nil)
    if ENV['OS'] != "Windows_NT"
      socket = UNIXSocket.open(@@unix_socket)
    else
      socket = TCPSocket.new('localhost', LOCAL_PORT)
    end
    socket.sync=true
    puts "Connected (acceptfile)"
    if !error_frequency.nil? then
      real_getc=socket.method(:getc)

      case error_type
        when :corruption_in
          real_getc=socket.method(:getc)
          socket.extend(CorruptIn)
          socket.corruption_frequency=error_frequency
          socket.real_getc=real_getc
        when :packet_loss_in
          real_getc=socket.method(:getc)
          socket.extend(DropIn)
          socket.drop_frequency=error_frequency
          socket.real_getc=real_getc
        when :packet_loss_out
          real_putc=socket.method(:putc)
          socket.extend(DropOut)
          socket.drop_frequency=error_frequency
          socket.real_putc=real_putc
        when :corruption_out
          real_putc=socket.method(:putc)
          socket.extend(CorruptOut)
          socket.corruption_frequency=error_frequency
          socket.real_putc=real_putc
        else
          raise "unknown error_type #{error_type}"
      end
      file.flush
    end
    XMODEM::receive(socket,file,rx_options)
    loop {Thread.pass} until socket.closed?

  end

  def do_test(tx_file,rx_file,error_type=nil,error_frequency=nil,rx_options=nil)
    test_description="test type: #{error_type}"
    test_description+=" (freq=#{error_frequency})" unless error_frequency.nil?
    made_tx = false
    made_rx = false
    if !(tx_file.respond_to?(:getc))
      tx_filename=tx_file
      tx_file=File.new(tx_filename,"rb")
      made_tx = true
    else
      tx_filename=tx_file.class
      tx_file.rewind
    end


    if !(rx_file.respond_to?(:putc))
      rx_filename=rx_file
      rx_file=File.new(rx_filename,"wb+")
      made_rx = true
    else
      rx_filename=rx_file.class
      rx_file.rewind
    end
    puts "#{test_description} : #{tx_filename}->#{rx_filename}"


    tx_thread=Thread.new {sendfile(tx_file)}
    sleep(0.1) # Time for the socket to be opened
    rx_thread=Thread.new {acceptfile(rx_file,error_type,error_frequency,rx_options)}
    loop do
      break unless tx_thread.alive?
      break unless rx_thread.alive?
      sleep(0.01)  #wake up occasionally to get keyboard input, so we break on ^C
    end
    tx_file.rewind
    rx_file.rewind
    rx_filecontents=rx_file.read
    tx_filecontents=tx_file.read
    assert_equal(tx_filecontents.length,rx_filecontents.length,"file length correct after round trip")
    assert_equal(tx_filecontents,rx_filecontents,"file contents correct after round trip")

    tx_file.close if made_tx
    rx_file.close if made_rx

    File.delete(rx_filename) if made_rx
  end

  ##
  # Teardown
  def teardown
    unless ENV['OS'] == "Windows_NT"
      File.delete( @@unix_socket ) if FileTest.exist?( @@unix_socket )
    end
  end

  # Test cases
  def test_version
    assert_equal("0.1.1", ::XMODEM::VERSION)
  end

  def test_checksum
    assert_equal(0, XMODEM::checksum( "\000"*128))
    assert_equal(128, XMODEM::checksum("\001"*128))
    assert_equal(0, XMODEM::checksum("\002"*128))
    assert_equal(128, XMODEM::checksum("\003"*128))
  end

  def test_all
    sample_text_file="sample.test.txt"
    sample_bin_file="sample.test.bin"
    f=File.new(sample_text_file,"w")
    f<<File.new(__FILE__,"r").read
    f.close

    f = File.new(sample_bin_file,"wb")
    2000.times { |i| f << (i % 0x100).chr}
    f.close

    txstring_io=StringIO.new("this is a test string")
    rxstring_io=StringIO.new("")

    do_test(sample_text_file, "crc-simple.test.txt", nil, nil, {:mode=>:crc})
    do_test(sample_bin_file, "crc-simple.test.bin", nil, nil, {:mode=>:crc})
    do_test(txstring_io,rxstring_io)
    do_test(sample_text_file,"corrupt-crc.test.txt",:corruption_in,700,{:mode=>:crc})

    do_test(txstring_io,rxstring_io)
    do_test(sample_text_file,rxstring_io)
    do_test(sample_text_file,"simple.test.txt")
    do_test(sample_bin_file,"corrupt_out.test.bin",:corruption_out,4)
    do_test(sample_text_file,"packet_loss_out.test.txt",:packet_loss_out,3)
    do_test(sample_text_file,"packet_loss_in.test.txt",:packet_loss_in,200)

    do_test(sample_text_file,"corrupt.test.txt",:corruption_in,700)
    do_test(sample_text_file,"very_corrupt.test.txt",:corruption_in,200)

    do_test(sample_bin_file,"simple.test.bin")
    do_test(sample_bin_file,"corrupt.test.bin",:corruption_in,700)

    bigstring=""
    512.times {|i| bigstring<<((i%0x100).chr*128)}
    do_test(StringIO.new(bigstring),"bigfile.test.txt")

    File.delete(sample_text_file, sample_bin_file)

  end

end

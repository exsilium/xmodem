# Author::    Jonno Downes (jonno@jamtronix.com)
# Contrib::   Sten Feldman (exile@chamber.ee)
#
# License::   Mozilla Public License 1.1
#
# Doesn't seem to work for me using Ruby 2.0 - BORKEN unless fixed
#
# Public interface changes:
# - ModemProtocols renamed to XMODEM
# - xmodem_tx renamed to send
# - xmodem_rx renamed to receive
# - Logger outputs reflect the actors sender/receiver

require 'log4r'
include Log4r

module XMODEM

  XMODEM_BLOCK_SIZE = 128  #how many bytes (ecluding header & checksum) in each block?
  XMODEM_MAX_TIMEOUTS = 5  #how many timeouts in a row before the sender gives up?
  XMODEM_MAX_ERRORS = 10   #how many errors on a single block before the receiver gives up?

  XMODEM_CRC_ATTEMPTS = 3  #how many times should receiver attempt to use CRC?
  LOG_NAME='XModem'
  @timeout_seconds = 5.0  #default timeout period

  #how long does the protocol wait before giving up?
  def XMODEM::timeout_seconds
    @timeout_seconds
  end

  def XMODEM::timeout_seconds=(val)
    @timeout_seconds=val
  end

  # receive a file using XMODEM protocol (block size = 128 bytes)
  # remote:: must be an IO object connected to an XMODEM sender
  # local:: must be an IO object - the inbound file (trimmed of any final padding) will be written to this
  # options:: hash of options. options are: values :crc (use 16bit CRC instead of 8 bit checksum)
  # - :mode=> :crc or :checksum (default is 8 bit checksum)
  #
  def XMODEM::receive(remote,local,options=nil)

    mode = ( (options.nil?) || options[:mode].nil? ) ? :checksum : options[:mode]

    logger.debug "receiver: XMODEM - #{mode}"
    #flush the input buffer
    loop do
      break if (select([remote],nil,nil,0.01).nil?)
      remote.getc
    end

    #trigger sending
    case mode
      when :crc
        XMODEM_CRC_ATTEMPTS.times do |attempt|
          remote.putc('C')
          break unless (select([remote],nil,nil,timeout_seconds).nil?)
          #if we don't get a response, fall back to checksum mode
          if attempt==XMODEM_CRC_ATTEMPTS-1 then
            logger.warn "receiver: crc-16 request failed, falling back to checksum mode"
            remote.putc(NAK)
            mode=:checksum
          end
        end
      else
        remote.putc(NAK)
    end

    expected_block = 1
    error_count = 0
    last_block = ""
    data = ""
    loop do

        begin
        rx_cmd = receive_getbyte(remote).ord

        if rx_cmd == EOT then
          remote.putc(ACK)
          trimmed_block=last_block.sub(/(\x1A+)\Z/,'')
          local<< trimmed_block#trim any trailing FILLER characters in last block
          break
        end

        if rx_cmd!=SOH then
          logger.warn "receiver: expected SOH (0x#{SOH}) got 0x#{"%x" % rx_cmd}  - pos = #{remote.pos}"
          next
        end

        data=""
        block= receive_getbyte(remote).ord
        block_check = receive_getbyte(remote).ord
        validity = :valid
        validity = :invalid unless (block_check + block)==0xFF

        logger.debug "receiver: #{validity} block number 0x#{"%02x" % block} / block number check 0x#{"%02x" % block_check}"
        logger.debug "receiver: receiving block #{block} / expected block #{expected_block}"

        raise RXSynchError if block != expected_block && block != ((expected_block-1) % 0x100)

        if (block==expected_block) && (validity==:valid) then
          local<<last_block
          last_block=""
        end
        XMODEM_BLOCK_SIZE.times do
          b=(receive_getbyte(remote))
          data<<b
          Thread.pass
        end

        check_ok=false

        case mode
          when :crc
            rx_crc = ( receive_getbyte(remote).ord<<8) + receive_getbyte(remote).ord
            crc = ccitt16_crc(data)
            check_ok = (crc==rx_crc)
            if !check_ok then
              logger.warn "receiver: invalid crc-16 for block #{block}: calculated 0x#{'%04x' % crc}, got 0x#{'%02x' %  rx_crc}"
            end
          else
            rx_checksum = receive_getbyte(remote).ord
            checksum = XMODEM::checksum(data)
            check_ok = (checksum == rx_checksum)
            if !check_ok then
              logger.warn "receiver: invalid checksum for block #{block}: calculated 0x#{'%02x' % checksum}, got 0x#{'%02x' %  rx_checksum}"
            end
          end

          if (check_ok) then
              last_block = data
              logger.debug "receiver: #{mode} test passed for block #{block}"
              remote.putc(ACK)
            if (block == expected_block) then
              expected_block = ((expected_block+1) % 0x100)
              error_count=0 #reset the error count
            end
          else
            remote.putc(NAK)
            error_count+=1
            logger.warn "receiver: checksum error # #{error_count} / max #{XMODEM_MAX_ERRORS}"
            raise RXChecksumError.new("too many receive errors on block #{block}") if error_count>XMODEM_MAX_ERRORS
          end
      rescue RXTimeout
        error_count+=1
        logger.warn "receiver: timeout error # #{error_count} / max #{XMODEM_MAX_ERRORS}"
        raise RXTimeout("too many receive errors on block #{block}").new if error_count>XMODEM_MAX_ERRORS
      end
    end

    logger.info "receive complete"
  end

  # send a file using standard XMODEM protocol (block size = 128 bytes)
  # will use CRC mode if requested by sender, else use 8-bit checksum
  # remote:: must be an IO object connected to an XMODEM receiver
  # local:: must be an IO object containing the data to be sent
  def XMODEM::send(remote,local)
    block_number=1
    current_block=""
    sent_eot=false

    XMODEM_BLOCK_SIZE.times do
      b=(local.eof? ?  FILLER : local.getc)
      current_block<<b.chr
      Thread.pass
    end
    checksum = XMODEM::checksum(current_block)
    mode=:checksum
    loop do
      logger.info "sender: waiting for ACK/NAK/CAN (eot_sent: #{sent_eot})"
      if select([remote],nil,nil,timeout_seconds*XMODEM_MAX_TIMEOUTS).nil? then
        raise RXTimeout.new("timeout waiting for input on tx (#{timeout_seconds*XMODEM_MAX_TIMEOUTS} seconds)") unless sent_eot
        logger.info "sender: timeout waiting for ACK of EOT"
        return
      end
      if remote.eof? then
        logger.warn "sender: unexpected eof on input"
        break
      end
      tx_cmd=remote.getc.ord
      logger.debug "sendder: got 0x#{"%x" % tx_cmd}"
      if tx_cmd==ACK then
        if sent_eot then
          logger.debug "sender: got ACK of EOT"
          break
        end

        if local.eof? then
          remote.putc(EOT)
          logger.debug "sender: got ACK of last block"
          sent_eot=true
          next
        end
        block_number=((block_number+1)%0x100)
        current_block=""
        XMODEM_BLOCK_SIZE.times do
          b=(local.eof? ?  FILLER : local.getc)
          current_block<<b
          Thread.pass
        end

      elsif (block_number==1) && (tx_cmd==CRC_MODE) then
        mode=:crc
        logger.debug "sender: using crc-16 mode"
      end

      next unless [ACK,NAK,CRC_MODE].include?(tx_cmd.ord)
      logger.info "sender: sending block #{block_number}"
      remote.putc(SOH)     #start of block
      remote.putc(block_number)    #block number
      remote.putc(0xff-block_number)    #1's complement of block number
      current_block.each_byte {|b| remote.putc(b)}
      case mode
        when :crc then
          crc = ccitt16_crc (current_block)
          remote.putc(crc >> 8) #crc hi byte
          remote.putc(crc & 0xFF) #crc lo byte
          logger.debug "sender: crc-16 for block #{block_number}:#{ "%04x" % crc}"
        else
          checksum = XMODEM::checksum(current_block)
          remote.putc(checksum)
          logger.debug "sender: checksum for block #{block_number}:#{ "%02x" % checksum}"
      end

    end
    logger.info "sending complete (eot_sent: #{sent_eot})"
  end

  #calculate an 8-bit XMODEM checksum
  #this is just the sum of all bytes modulo 0x100
  def XMODEM::checksum(block)
    raise RXChecksumError.new("checksum requested of invalid block {size should be #{XMODEM_BLOCK_SIZE}, was #{block.length}") unless block.length==XMODEM_BLOCK_SIZE
    checksum=0
    block.each_byte do |b|
      checksum = (checksum+b) % 0x100
    end
    checksum
  end

  #calculate a 16-bit  CRC
  def XMODEM::ccitt16_crc(block)
    # cribbed from http://www.hadermann.be/blog/32/ruby-crc16-implementation/
    raise RXChecksumError.new("checksum requested of invalid block {size should be #{XMODEM_BLOCK_SIZE}, was #{block.length}") unless block.length==XMODEM_BLOCK_SIZE
    crc=0
    block.each_byte{|x| crc = ((crc<<8) ^ CCITT_16[(crc>>8) ^ x])&0xffff}
    crc
  end

  private

  SOH = 0x01
  STX = 0x02
  EOT = 0x04
  ACK = 0x06
  NAK = 0x15
  CAN = 0x18
  CRC_MODE = 0x43 #'C'
  FILLER = 0x1A

  CCITT_16 = [
    0x0000, 0x1021, 0x2042, 0x3063, 0x4084, 0x50A5, 0x60C6, 0x70E7,
    0x8108, 0x9129, 0xA14A, 0xB16B, 0xC18C, 0xD1AD, 0xE1CE, 0xF1EF,
    0x1231, 0x0210, 0x3273, 0x2252, 0x52B5, 0x4294, 0x72F7, 0x62D6,
    0x9339, 0x8318, 0xB37B, 0xA35A, 0xD3BD, 0xC39C, 0xF3FF, 0xE3DE,
    0x2462, 0x3443, 0x0420, 0x1401, 0x64E6, 0x74C7, 0x44A4, 0x5485,
    0xA56A, 0xB54B, 0x8528, 0x9509, 0xE5EE, 0xF5CF, 0xC5AC, 0xD58D,
    0x3653, 0x2672, 0x1611, 0x0630, 0x76D7, 0x66F6, 0x5695, 0x46B4,
    0xB75B, 0xA77A, 0x9719, 0x8738, 0xF7DF, 0xE7FE, 0xD79D, 0xC7BC,
    0x48C4, 0x58E5, 0x6886, 0x78A7, 0x0840, 0x1861, 0x2802, 0x3823,
    0xC9CC, 0xD9ED, 0xE98E, 0xF9AF, 0x8948, 0x9969, 0xA90A, 0xB92B,
    0x5AF5, 0x4AD4, 0x7AB7, 0x6A96, 0x1A71, 0x0A50, 0x3A33, 0x2A12,
    0xDBFD, 0xCBDC, 0xFBBF, 0xEB9E, 0x9B79, 0x8B58, 0xBB3B, 0xAB1A,
    0x6CA6, 0x7C87, 0x4CE4, 0x5CC5, 0x2C22, 0x3C03, 0x0C60, 0x1C41,
    0xEDAE, 0xFD8F, 0xCDEC, 0xDDCD, 0xAD2A, 0xBD0B, 0x8D68, 0x9D49,
    0x7E97, 0x6EB6, 0x5ED5, 0x4EF4, 0x3E13, 0x2E32, 0x1E51, 0x0E70,
    0xFF9F, 0xEFBE, 0xDFDD, 0xCFFC, 0xBF1B, 0xAF3A, 0x9F59, 0x8F78,
    0x9188, 0x81A9, 0xB1CA, 0xA1EB, 0xD10C, 0xC12D, 0xF14E, 0xE16F,
    0x1080, 0x00A1, 0x30C2, 0x20E3, 0x5004, 0x4025, 0x7046, 0x6067,
    0x83B9, 0x9398, 0xA3FB, 0xB3DA, 0xC33D, 0xD31C, 0xE37F, 0xF35E,
    0x02B1, 0x1290, 0x22F3, 0x32D2, 0x4235, 0x5214, 0x6277, 0x7256,
    0xB5EA, 0xA5CB, 0x95A8, 0x8589, 0xF56E, 0xE54F, 0xD52C, 0xC50D,
    0x34E2, 0x24C3, 0x14A0, 0x0481, 0x7466, 0x6447, 0x5424, 0x4405,
    0xA7DB, 0xB7FA, 0x8799, 0x97B8, 0xE75F, 0xF77E, 0xC71D, 0xD73C,
    0x26D3, 0x36F2, 0x0691, 0x16B0, 0x6657, 0x7676, 0x4615, 0x5634,
    0xD94C, 0xC96D, 0xF90E, 0xE92F, 0x99C8, 0x89E9, 0xB98A, 0xA9AB,
    0x5844, 0x4865, 0x7806, 0x6827, 0x18C0, 0x08E1, 0x3882, 0x28A3,
    0xCB7D, 0xDB5C, 0xEB3F, 0xFB1E, 0x8BF9, 0x9BD8, 0xABBB, 0xBB9A,
    0x4A75, 0x5A54, 0x6A37, 0x7A16, 0x0AF1, 0x1AD0, 0x2AB3, 0x3A92,
    0xFD2E, 0xED0F, 0xDD6C, 0xCD4D, 0xBDAA, 0xAD8B, 0x9DE8, 0x8DC9,
    0x7C26, 0x6C07, 0x5C64, 0x4C45, 0x3CA2, 0x2C83, 0x1CE0, 0x0CC1,
    0xEF1F, 0xFF3E, 0xCF5D, 0xDF7C, 0xAF9B, 0xBFBA, 0x8FD9, 0x9FF8,
    0x6E17, 0x7E36, 0x4E55, 0x5E74, 0x2E93, 0x3EB2, 0x0ED1, 0x1EF0
]

  def XMODEM::receive_getbyte(remote)

    if (select([remote],nil,nil,timeout_seconds).nil?) then
      remote.putc(NAK)
      raise RXTimeout
    end

    raise RXSynchError if remote.eof?
    remote.getc
  end


  def XMODEM::logger
    Logger.new(LOG_NAME) if Logger[LOG_NAME].nil?
    Logger[LOG_NAME]
  end

  class RXTimeout < RuntimeError
  end

  class RXChecksumError < RuntimeError
  end

  class RXSynchError < RuntimeError
  end

end

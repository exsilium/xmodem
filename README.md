## Synopsis

A pure XMODEM implementation in Ruby for sender and receiver. Compatible with Ruby 1.9.3+

## Code Example

To send a file within an IO socket:
```
myFile = File.new("file_to_send.txt","rb")
XMODEM::send(IOsocket, myFile);
myFile.close
```

Receive a file:
```
myFile = File.new("file_to_write.txt","wb+")
XMODEM::receive(IOsocket, myFile)
myFile.close
```

Please also see `test/test_xmodem.rb` for basic file transfers executed via local socket.

## Motivation

XMODEM is still widely used in embedded systems due to ease of implementation and requirements from the target system. The motivation grew out from [ruby-xbee](https://github.com/exsilium/ruby-xbee) project where non-standard 64 byte payload XMODEM protocol is needed for Over-The-Air application firmware updates in Programmable XBee modules by Digi. This project is forked from [modem_protocols](https://rubygems.org/gems/modem_protocols) as it seemed to be forgotten by time and fixed to work with modern Ruby. The naming change was motivated by scoping this gem to only include XMODEM implementation with possible variants in use.

## Installation

Get started by installing the gem: `gem install xmodem` or cloning this repo.

## API Reference

For now, see the code example and read the source.

## Tests

Run the tests suite by `rake test`

## Contributors

Please feel free to fork and send pull requests or just file an issue.

## License

Mozilla Public License 1.1
